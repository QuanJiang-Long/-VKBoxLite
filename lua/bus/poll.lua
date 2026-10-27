local util = require "util"
local cfg = require "core/config"
local log = util.log()

local uart = util.get("uart")
local gpio = util.try("gpio")
local sys = util.try("sys")

local mbus = require "bus/mbus"
local collector = require "data/collector"
local cfgstore = require "cfg"
local guard = util.try("svc/guard")

local M = {}

local running, gen = false, 0
local regs, interval = {}, cfg.POLL_INTERVAL_MS
local writeQ = {}
local writeTaskRun = false
local respFlag, respData = false, nil
local reqSlave, reqFc = nil, nil
local lastCfg = nil
-- 配置槽: "poll" = 手配, "pull" = 平台拉取。默认 poll 保持旧调用点行为
local curSlot = "poll"
local stat = { rounds = 0, ok = 0, timeout = 0, werr = 0, zero = 0 }
local wstat = { queued = 0, done = 0, wfail = 0 }

-- 16-fix-1: DE 由内核 485 自动控制, 这两个函数保留为 noop
--   (留作万一要回滚到手动 DE 模式时用, 当前没有任何调用)
local function de_high()
    -- 16-fix-1: noop, 内核 485 在 uart.write 时自动拉高 DE
end

local function de_low()
    -- 16-fix-1: noop, 内核 485 在 tx-done 中断里自动拉低 DE
end

local function drain()
    if not sys then return end
    for _ = 1, 16 do
        local ok, d = pcall(uart.read, mbus.UART_ID, 256)
        if not ok or type(d) ~= "string" or #d == 0 then break end
    end
end

-- 串口初始化。轮询没跑时 first transaction 会走到这里 —— MQTT 下行写和
-- 前端 W:WRITE 都可能在 idle/sniff 档到来，而 setup 原先只在 M.start() 和
-- raw_tx() 里做，那条路上 uart.write 等于发到空气里。
-- 波特率没变时重复 setup 不打断在途事务，所以不必判 running
--
-- 🎯 修法 (19200+ 高波特率, W:CFG 改 baud 路径):
--   合宙 FAQ #32: 重新 uart.setup 会重置 RX 缓冲和驱动上下文.
--   19200/38400/115200 应答比 9600 早到 (19200 t3.5≈1.82ms, 6ms 内到),
--   BSP 在 "刚 setup 状态" 没恢复, 应答字节进不了 RX FIFO → fire=0.
--   第 2 次 setup 之前先 uart.close(1) + sys.wait(500) 让驱动完全复位,
--   让"软重启 485"独立出来, 不影响 VUART / 前端交互.
--   第 1 次 setup (boot 启动) 不需要 close, 加快启动.
local _setup_n = 0
local function ensure_uart()
    if not lastCfg then M.reload_cfg() end
    if _setup_n >= 1 then
        log.warn("poll", "第 2 次 setup, uart.close + wait 500ms 软重启 485")
        pcall(uart.close, mbus.UART_ID)
        if sys then sys.wait(500) end
    end
    local ok, e = pcall(uart.setup, mbus.UART_ID, lastCfg and lastCfg.baud or cfg.BAUD,
        lastCfg and lastCfg.databits or cfg.DATABITS,
        lastCfg and lastCfg.stopbits or cfg.STOPBITS,
        mbus.parity_to_uart(lastCfg and lastCfg.parity or cfg.PARITY),
        -- 16-fix-1: 开启内核 485 (第 6-10 参)
        --   合宙 demo 用内核 485 通 4096, 软件 hold 14/64ms 是根因(DE 霸占总线)
        --   内核在 tx-done 中断里自动拉高/拉低 DE (μs 级精度)
        nil,  -- 6: flow control (none)
        1024, -- 7: buff_size
        mbus.DE_PIN, -- 8: rs485_gpio
        0,    -- 9: rs485_dir_rx_level (DE=0 时接收)
        math.floor(20000 * 9600 / (lastCfg and lastCfg.baud or cfg.BAUD)))  -- 10: rs485_delay (按 baud 调整)
    _setup_n = _setup_n + 1
    if not ok then return false, "uart setup fail: " .. tostring(e) end
    if gpio then pcall(gpio.setup, mbus.DE_PIN, 0) end
    return true
end

-- 同 hexs, 但字节间加空格便于肉眼看.
-- 加 n= 是排查用: 单看 raw 分不清 "0200017984" 是 5 字节还是
-- 10 个 hex 字符模糊拼起来. 排查 Rx timeout 时 n 是关键信息
-- (用 sscom 抓包对照, n 决定到底缺了几字节)
--
-- ⚠️ 必须定义在 on_receive 之前 (11-fix, 2026-10-27):
--   on_receive 的 respFlag=false 分支要用它, 而 local function 是词法作用域,
--   定义在后面的 local 对前面的代码【不可见】—— 那条分支里的 hexspaced 会
--   解析成全局 nil, 一旦走到就是 "attempt to call a nil value", 把 7/8-fix
--   最关键的那条诊断日志(收到的原始字节)连同整个 on_receive 回调一起掀掉。
--   check_lua.py 的前向引用规则能抓到这个问题, 别把定义挪回去。
local function hexspaced(s)
    if not s or #s == 0 then return "-" end
    return (s:gsub(".", function(c) return string.format("%02x ", c:byte()) end)):gsub(" $", "")
end

local function on_receive(id, len)
    if id ~= mbus.UART_ID then return end
    if type(len) ~= "number" or len <= 0 then return end
    while true do
        local ok, data = pcall(uart.read, id, 512)
        if not ok then return end
        if type(data) ~= "string" or #data == 0 then break end
        -- 7-fix 诊断: 每次 UART 接收都打 log, 看是不是根本没收到字节
        --   (UART 中断触发了, 但 read 0 字节 = rx buf 真的是空的, 硬件没收到)
        --   或 UART 中断都没触发 (这个 log 不会出现)
        log.debug("poll", string.format("on_receive id=%d len=%d n=%d flag=%s", id, len, #data, tostring(respFlag)))
        if respFlag then
            respData = (respData or "") .. data
            if #respData > 512 then respData = respData:sub(-256) end
        else
            -- 7-fix 诊断: 收到字节但 respFlag=false, 说明 poll 不在等响应
            --   (可能 mon/iomux 等别的模块占用了 UART, 或上次事务没清干净)
            log.warn("poll", string.format("on_receive id=%d got %d bytes but respFlag=false (raw=[%s])",
                id, #data, hexspaced(data)))
        end
    end
end

-- CRC 试探法切帧: 从头逐个偏移找第一个 CRC 合法且长度自洽的帧,
-- 并校验 slave/fc 与在途请求一致(多从机/噪声下防错配他从机响应);
-- 容忍响应前的杂字节(DE 拉毛刺/总线噪声); 找不到就继续等
local function try_resp()
    if not respData or #respData == 0 then return false end
    for off = 1, #respData do
        local s = respData:sub(off)
        local n = mbus.try_extract_len(s)
        if n and #s >= n then
            local f = mbus.parse_frame(s:sub(1, n))
            if f then
                if f.slave == reqSlave and (f.fc == reqFc or (f.err and f.fc == reqFc)) then
                    respData = s:sub(n + 1)
                    respFlag = false
                    return f
                end
            end
        end
    end
    return false
end

local function do_transaction(frame, timeout_ms, exp_slave, exp_fc)
    -- timeout_ms=nil = 早返回模式: 默认上限兜底, 命中即返回(不会等满)
    if timeout_ms == nil then timeout_ms = cfg.TIMEOUT_MS end
    -- 写队列 worker 可能在轮询没起时被拉起(MQTT 下行/W:WRITE),
    -- 串口是裸的; 轮询在跑时这里是空操作
    if not running then pcall(ensure_uart) end
    drain()                                  -- 先清残留, 避免杂字节顶掉真响应
    respFlag, respData = true, nil
    reqSlave, reqFc = exp_slave, exp_fc
    -- 16-fix-1: 删除 de_high()/de_low(), 依赖内核 485 自动控制 DE
    --   内核在 tx-done 中断里自动拉高/拉低 DE (μs 级精度)
    log.debug("poll", string.format("write n=%d (kernel 485 auto DE)", #frame))
    pcall(uart.write, mbus.UART_ID, frame)
    log.debug("poll", string.format("等待响应 timeout=%d", timeout_ms))
    local waited = 0
    while waited < timeout_ms do
        local f = try_resp()
        if f then return f end
        if sys then sys.wait(5) end
        waited = waited + 5
    end
    respFlag = false
    reqSlave, reqFc = nil, nil
    return nil
end

local function hexs(s)
    return #s > 0 and (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) or "-"
end

local function poll_reg(reg)
    local slave = lastCfg.slave or cfg.SLAVE_ADDR
    local cnt = reg.count or 1
    local alias = reg.alias or reg.name or ("r" .. reg.addr)
    local frame, err = mbus.build_read(slave, reg.addr, cnt)
    if not frame then
        log.warn("poll", "build fail", reg.addr, tostring(err))
        return
    end
    log.info("poll", string.format("Tx s%d fc3 addr=%d len=%d %s raw=[%s]", slave, reg.addr, cnt, alias, hexspaced(frame)))
    local f = do_transaction(frame, lastCfg and lastCfg.timeout_ms or cfg.TIMEOUT_MS, slave, 3)
    if not f then
        stat.timeout = stat.timeout + 1
        -- 排查: Tx raw + Rx n + Rx raw 都打, 跟 sscom 抓包对比
        -- - Tx raw 不对: build_read 出错 (极罕见, build fail 已拦)
        -- - Rx n=0: DE 没切到收, 或仪表没响应
        -- - Rx n 缺前几字节 (1~3): DE 拉低太慢, 响应首字节丢了
        -- - Rx n 缺后几字节 (1~2): timeout 到了, CRC 没收完 (3.5 字符间隔超时)
        -- - Rx n 含乱字节 (如 f8): 总线噪声, AB 接反, 或 DE 切换时毛刺
        log.warn("poll", string.format("Rx timeout addr=%d %s Tx raw=[%s] Rx n=%d raw=[%s]",
            reg.addr, alias, hexspaced(frame), #(respData or ""), hexspaced(respData or "")))
        return
    end
    if f.err then
        stat.werr = stat.werr + 1
        log.warn("poll", string.format("Rx err fc=%02x code=%d addr=%d %s", f.fc or 0, f.code or 0, reg.addr, alias))
        return
    end
    local vals, hex = mbus.parse_regs(f.data, reg.dtype or "uint16")
    if not vals then
        log.warn("poll", string.format("Rx parse fail addr=%d %s hex=%s", reg.addr, alias, hex))
        return
    end
    stat.ok = stat.ok + 1
    log.info("poll", string.format("Rx s%d addr=%d len=%d %s hex=%s val=%s",
        slave, reg.addr, cnt, alias, hex, table.concat(vals, ",")))
    for i, v in ipairs(vals) do
        collector.push_data(reg.addr + i - 1, reg.name or ("r" .. reg.addr), hex, v, nil, reg.dtype)
    end
end

local function do_write(w)
    local frame, err
    if w.values then
        frame, err = mbus.build_write_multi(w.slave, w.addr, w.values)
    else
        frame, err = mbus.build_write_single(w.slave, w.addr, w.value)
    end
    if not frame then
        wstat.wfail = wstat.wfail + 1
        return false
    end
    local f = do_transaction(frame, lastCfg and lastCfg.timeout_ms or cfg.TIMEOUT_MS,
        w.slave, w.values and 16 or 6)
    if not f or f.err then
        wstat.wfail = wstat.wfail + 1
        return false
    end
    if f.addr == w.addr then
        wstat.done = wstat.done + 1
        return true
    end
    wstat.wfail = wstat.wfail + 1
    return false
end

local function mon_running()
    local ok, ctrl = pcall(require, "bus/ctrl")
    if ok and ctrl and ctrl.get_mode() == "sniff" then return true end
    return false
end

-- 排空写队列。mygen ~= gen 立即返回(stop/切模式会 bump gen)。
-- sniff_yield=true 时旁听接管总线就停手(两模式共用一条物理串口,
-- 抢着发会让旁听帧里混进写请求)。
-- ⚠️ 故意不判 running: poll_task 专用排空, worker 闸门别加这里
local function drain_write_queue(mygen, sniff_yield)
    while #writeQ > 0 do
        if gen ~= mygen then return end
        if sniff_yield and mon_running() then return end
        do_write(table.remove(writeQ, 1))
    end
end

-- 写队列的独立执行体, 与 poll_task 分开。
-- MQTT 下行写可能落在轮询没跑时(idle/sniff 档), enqueue_write 拉起本任务。
-- 以前判 running, idle 档 running=false 任务刚启动就 return,
-- 写请求静静躺队列(iot 记 ok=1 总线没发), 直到切 poll 才被顺带发出去
-- (陈旧写指令延后生效, 比不生效更危险)。
-- running 只是 poll_task 生命周期, 管不到本任务, 用自己 gen 守卫
local function worker()
    writeTaskRun = true
    drain_write_queue(gen, true)
    -- 16-fix-1: 删除 de_low(), 依赖内核 485 自动控制 DE
    writeTaskRun = false
end

local function ensure_worker()
    if writeTaskRun then return end
    if not sys then return end
    sys.taskInit(worker)
end

local function poll_task()
    local mygen = gen
    local okBefore = stat.ok
    while gen == mygen and running do
        for _, reg in ipairs(regs) do
            if gen ~= mygen or not running then break end
            drain_write_queue(mygen)      -- 空队列时立刻返回, 不必先判长度
            poll_reg(reg)
            if guard then guard.alive() end
            if sys then sys.wait(5) end
        end
        drain_write_queue(mygen)
        stat.rounds = stat.rounds + 1
        -- 每轮打一行汇总: 既证明轮询在周期跑, 又便于对比 ok/timeout
        if stat.ok == okBefore then
            stat.zero = stat.zero + 1
            log.warn("poll", string.format("round %d 无新增 ok=%d timeout=%d werr=%d (查从机地址/波特率/校验位/AB线/DE极性)",
                stat.rounds, stat.ok, stat.timeout, stat.werr))
        else
            stat.zero = 0
            log.info("poll", string.format("round %d ok=%d timeout=%d werr=%d",
                stat.rounds, stat.ok, stat.timeout, stat.werr))
        end
        okBefore = stat.ok
        if sys then sys.wait(interval) end
    end
end

-- 总线裸探针: 发一帧原始请求, 抓回所有原始字节(不做 CRC 判定),
-- 用于现场区分"没发出去/从机没回"与"回了但参数不匹配"
local rawCap = nil
local function raw_on_receive(id, len)
    if id ~= mbus.UART_ID then return end
    if type(len) ~= "number" or len <= 0 then return end
    while true do
        local ok, data = pcall(uart.read, id, 512)
        if not ok then return end
        if type(data) ~= "string" or #data == 0 then break end
        if rawCap then
            rawCap = rawCap .. data
            if #rawCap > 256 then rawCap = rawCap:sub(1, 256) end
        end
    end
end

-- 裸发一帧抓回原始字节。W:RAWTEST 与 W:TX 完全共用(DE 时序/极性/收发窗口/
-- 恢复 on_receive 一样, 只差"帧从哪来"和回显字段)。返回 {tx_ok, tx_err,
-- tx_hex, rx_len, rx_hex, parsed, ...}; 失败 nil, 原因
local function raw_tx(frame, timeout_ms, extra)
    if not running then
        local ok, err = ensure_uart()
        if not ok then return nil, err end
    end
    drain()
    rawCap = ""
    pcall(uart.on, mbus.UART_ID, "receive", raw_on_receive)
    local txok, txerr = pcall(uart.write, mbus.UART_ID, frame)
    txok = txok and true or false
    -- 16-fix-1: 删除 de_high()/de_low(), 依赖内核 485 自动控制 DE
    timeout_ms = timeout_ms or (lastCfg and lastCfg.timeout_ms or cfg.TIMEOUT_MS)
    local waited = 0
    while waited < timeout_ms do
        -- 只要出现一个 CRC 自洽的帧就算收够了: 现场要看的是"有没有回、回得对不对"
        if #rawCap > 0 and mbus.parse_frame(rawCap) then break end
        if sys then sys.wait(5) end
        waited = waited + 5
    end
    local cap = rawCap or ""
    rawCap = nil
    -- 轮询在跑就把接收回调还回去, 否则轮询从此收不到响应(表现为全 timeout)
    -- ⚠️ 12-fix (2026-10-27): 不 running 时【必须解绑】。原来不 running 就
    --   什么都不做 —— raw_on_receive 会永久留在 UART 上, 变成第二个常驻
    --   回调, 跟 poll.stop() 那个 bug 同一类。W:RAWTEST 在 idle 档就能触发。
    if running then
        pcall(uart.on, mbus.UART_ID, "receive", on_receive)
    else
        pcall(uart.on, mbus.UART_ID, "receive", nil)
        -- 12-fix: 不在轮询态就顺手把串口也关了 —— raw_tx 开头为了发帧
        --   调过 ensure_uart() 把串口打开了, 测完不关等于 idle 档还占着
        --   485 口。下次 poll.start()/mon.start() 自己会 setup。
        pcall(uart.close, mbus.UART_ID)
    end
    local out = {
        tx_ok = txok,
        tx_err = txok and "" or tostring(txerr),
        tx_hex = hexs(frame),
        rx_len = #cap,
        rx_hex = hexs(cap),
        parsed = mbus.parse_frame(cap) ~= nil,
    }
    if extra then
        for k, v in pairs(extra) do out[k] = v end
    end
    return out
end

-- 总线裸探针: 发帧抓原始字节, 区分"没发出去/从机没回"与"回了但参数不匹配"
function M.probe_raw(slave, addr, qty, timeout_ms)
    slave = slave or (lastCfg and lastCfg.slave) or cfg.SLAVE_ADDR
    addr = addr or 0
    qty = qty or 1
    timeout_ms = timeout_ms or (lastCfg and lastCfg.timeout_ms) or cfg.TIMEOUT_MS
    local frame, err = mbus.build_read(slave, addr, qty)
    if not frame then return nil, tostring(err) end
    return raw_tx(frame, timeout_ms, { slave = slave, addr = addr, qty = qty })
end

function M.reload_cfg(src)
    -- src="pull" 读平台 ds_pull, 其他读手配 ds_poll。两槽同构, 只换 load
    local c = (src == "pull") and cfgstore.load_pull() or cfgstore.load_poll()
    if c then
        regs = c.regs or {}
        interval = c.interval_ms or cfg.POLL_INTERVAL_MS
        lastCfg = c
    end
    return lastCfg
end

-- 当前在跑哪个槽。iot 的平台推送据此判断要不要立即生效
function M.cur_slot() return curSlot end

function M.apply_cfg(c)
    if not c then return false end
    regs = c.regs or regs
    interval = c.interval_ms or interval
    lastCfg = c
    return true
end

function M.get_regs() return regs end

function M.needs_restart(c)
    if not lastCfg then return true end
    return (c.baud or cfg.BAUD) ~= (lastCfg.baud or cfg.BAUD)
        or (c.parity or cfg.PARITY) ~= (lastCfg.parity or cfg.PARITY)
        or (c.slave or cfg.SLAVE_ADDR) ~= (lastCfg.slave or cfg.SLAVE_ADDR)
end

-- 入队即返回 true，执行是异步的：轮询在跑就由 poll_task 在两条寄存器事务
-- 之间优先排空，没在跑就由 worker 兜着发(所以 idle 档也能写，不必先切
-- poll)。调用方只能知道"进队了"，不能知道"发出去了"—— 写结果看
-- write_status() 的 done/wfail
function M.enqueue_write(w)
    if #writeQ >= cfg.WRITEQ_MAX then return false, "queue full" end
    wstat.queued = wstat.queued + 1
    writeQ[#writeQ + 1] = w
    if not running then ensure_worker() end
    return true
end

function M.write_status()
    local st = {}
    st.queued = #writeQ                  -- 队列里待写的条数
    st.qmax = cfg.WRITEQ_MAX
    st.done = wstat.done
    st.fail = wstat.wfail                -- 前端读 w.fail
    return st
end

function M.status()
    local st = {}
    for k, v in pairs(stat) do st[k] = v end
    st.running = running
    st.gen = gen
    st.regs = #regs
    st.interval = interval
    st.slave = lastCfg and lastCfg.slave or cfg.SLAVE_ADDR
    st.baud = lastCfg and lastCfg.baud or cfg.BAUD
    st.timeout_ms = lastCfg and lastCfg.timeout_ms or cfg.TIMEOUT_MS
    return st
end

function M.start(src)
    if running then return true end
    curSlot = (src == "pull") and "pull" or "poll"
    M.reload_cfg(curSlot)
    if gpio then
        pcall(gpio.setup, mbus.DE_PIN, 0)
        pcall(gpio.set, mbus.DE_PIN, 0)
    end
    -- 走 ensure_uart 而不是直接 uart.setup: 修法 (19200+) 在 ensure_uart
    -- 里加了第 2 次 setup 之前的 uart.close + sys.wait(500) 软重启, 绕过
    -- 合宙 FAQ #32 "重新 setup 重置 RX 缓冲" 的 19200 fire=0 问题.
    -- M.start 是 W:CFG 改 baud 的入口 (M.stop + M.start), 必须触发修法
    local ok, err = ensure_uart()
    if not ok then
        log.error("poll", "setup failed:", tostring(err))
        return false
    end
    pcall(uart.on, mbus.UART_ID, "receive", on_receive)
    running = true
    gen = gen + 1
    if sys then sys.taskInit(poll_task) end
    log.info("poll", string.format("started(%s), regs=%d slave=%d baud=%d parity=%d timeout=%dms",
        curSlot, #regs, lastCfg and lastCfg.slave or cfg.SLAVE_ADDR,
        lastCfg and lastCfg.baud or cfg.BAUD, lastCfg and lastCfg.parity or cfg.PARITY,
        lastCfg and lastCfg.timeout_ms or cfg.TIMEOUT_MS))
    return true
end

function M.stop()
    local was_running = running
    running = false
    gen = gen + 1
    -- 36-fix: 清空 regs/lastCfg/interval. 切 idle 时 ctrl.reset_user 已经擦掉
    --   fskv 里的 ds_poll/ds_pull, 但 poll 模块内部的 regs 是另外存的,
    --   stop() 不清就导致切回 manual 时 R:REG 还返回上次的寄存器表 (ds_poll
    --   实际是空的). 让 stop 顺手清, 下次 start() 会从 fskv 重新 load
    regs, interval, lastCfg = {}, cfg.POLL_INTERVAL_MS, nil
    -- 16-fix-1: 删除 de_low(), 依赖内核 485 自动控制 DE
    --
    -- ⚠️ 12-fix (2026-10-27): 必须解绑 UART 接收回调并关串口, 与 mon.stop()
    --   对齐 (mon.lua 的 M.stop 里有 uart.on(...,nil) + uart.close)。
    --   原来这里只置 running=false, 回调一直挂在 UART 上 —— 切 idle 之后,
    --   总线上外部主站(PLC/上位机)的每个字节都被本模块读走并打 warn,
    --   日志以 ~500ms 周期刷屏, 还白白吃 CPU/内存。
    --   现场日志: W:MODE=idle 明确成功 (RET:MODE=OK, R:MODE/R:STAT 都报 idle)
    --   之后, poll.on_receive 仍持续输出 —— 根因就是这里不解绑。
    --   无条件做 (不再只在 running 时做): 只跑过 mon 没跑过 poll 时,
    --   is_running() 守卫会让这个清理根本不执行, UART 留在开着状态。
    --   不影响任何启动路径: poll.start() 会 ensure_uart() + 重新绑定,
    --   mon.start() 自己也 setup + 绑定。ensure_uart 的"第 2 次 setup"本来
    --   就 close+wait500, 关不关串口都一样, 不会多出等待。
    pcall(uart.on, mbus.UART_ID, "receive", nil)
    pcall(uart.close, mbus.UART_ID)
    if was_running then log.info("poll", "stopped") end
    return true
end

function M.is_running() return running end

return M
