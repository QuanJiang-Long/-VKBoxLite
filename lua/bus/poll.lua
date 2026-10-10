local util = require "util"
local cfg = require "cfg"
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

local function de_high()
    if gpio then pcall(gpio.set, mbus.DE_PIN, 1) end
end

local function de_low()
    if gpio then pcall(gpio.set, mbus.DE_PIN, 0) end
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
local function ensure_uart()
    if not lastCfg then M.reload_cfg() end
    local ok, e = pcall(uart.setup, mbus.UART_ID, lastCfg and lastCfg.baud or cfg.BAUD,
        lastCfg and lastCfg.databits or cfg.DATABITS,
        lastCfg and lastCfg.stopbits or cfg.STOPBITS,
        mbus.parity_to_uart(lastCfg and lastCfg.parity or cfg.PARITY))
    if not ok then return false, "uart setup fail: " .. tostring(e) end
    if gpio then pcall(gpio.setup, mbus.DE_PIN, 0) end
    return true
end

local function on_receive(id, len)
    if id ~= mbus.UART_ID then return end
    if type(len) ~= "number" or len <= 0 then return end
    while true do
        local ok, data = pcall(uart.read, id, 512)
        if not ok then return end
        if type(data) ~= "string" or #data == 0 then break end
        if respFlag then
            respData = (respData or "") .. data
            if #respData > 512 then respData = respData:sub(-256) end
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
    de_high()
    pcall(uart.write, mbus.UART_ID, frame)
    local hold = mbus.calc_de_hold_ms(#frame, lastCfg and lastCfg.baud or cfg.BAUD)
    if sys then sys.wait(hold) end
    de_low()
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
    log.info("poll", string.format("Tx s%d fc3 addr=%d len=%d %s", slave, reg.addr, cnt, alias))
    local f = do_transaction(frame, lastCfg and lastCfg.timeout_ms or cfg.TIMEOUT_MS, slave, 3)
    if not f then
        stat.timeout = stat.timeout + 1
        log.warn("poll", string.format("Rx timeout addr=%d %s rx=%s", reg.addr, alias, hexs(respData or "")))
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
    de_low()
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
    de_high()
    local hold = mbus.calc_de_hold_ms(#frame, lastCfg and lastCfg.baud or cfg.BAUD)
    if sys then sys.wait(hold) end
    de_low()
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
    if running then pcall(uart.on, mbus.UART_ID, "receive", on_receive) end
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

-- 裸发一串 hex 字节(前端 W:TX), 抓回原始响应, 返回 rx_len/rx_hex/parsed
function M.tx_raw(hex, timeout_ms)
    if type(hex) ~= "string" then return nil, "bad hex" end
    local bytes = {}
    for h in hex:gmatch("%x%x") do
        local v = tonumber(h, 16)
        if not v then return nil, "bad hex" end
        bytes[#bytes + 1] = string.char(v)
    end
    if #bytes == 0 then return nil, "empty hex" end
    local r, err = raw_tx(table.concat(bytes), timeout_ms)
    if not r then return nil, err end
    r.tx_hex = hex        -- 原样回显前端发的串, 免得 format 后再解析对不上
    return r
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
function M.slot() return curSlot end

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
    local ok, err = pcall(uart.setup, mbus.UART_ID, lastCfg and lastCfg.baud or cfg.BAUD,
        lastCfg and lastCfg.databits or cfg.DATABITS,
        lastCfg and lastCfg.stopbits or cfg.STOPBITS,
        mbus.parity_to_uart(lastCfg and lastCfg.parity or cfg.PARITY))
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
    if not running then return true end
    running = false
    gen = gen + 1
    de_low()
    log.info("poll", "stopped")
    return true
end

function M.is_running() return running end

return M
