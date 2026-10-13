local util = require "util"
local cfg = require "core/config"
local log = util.log()

local uart = util.get("uart")
local gpio = util.try("gpio")
local sys = util.try("sys")

local mbus = require "bus/mbus"
local collector = require "data/collector"

local M = {}

local running, gen = false, 0
local rxbuf = ""
local pendingReqs, lastReqs = {}, {}
local lastRx, lastBaud = 0, nil
-- 识别中标记: true = 正在扫 21 个候选, 业务视为未就绪; M.stop() 会清
local detecting, detectGen = false, 0
-- 进 sniff 时的配置参数(可能和现场不符)。识别失败要把串口还原成它,
-- 否则扫空后串口停在最后候选(1200 8O1), 真流量全成乱码
local bootCfg = nil
-- 两轮识别间隔。3s 足够等到稀疏主机冒流量, 高频重扫白耗电
local DETECT_RETRY_MS = 3000
-- 每 fc 最多留 4 条待配对请求。能进 push_req 的 fc 只有 3/5/15 三个
-- (parse_frame 是白名单 + 强制 CRC, 其余 fc 到不了这里), 所以
-- pendingReqs 总共 ≤ 12 条 —— 改 decode_frame 的 kind 判断时记得复核这条
local MAX_PENDING_PER_FC = 4
-- lastReqs 的键是 "slave:qty", 键空间上千万且只增不减。sniff 挂在异常总线上
-- 会单调增长, 两千条左右就吃掉大半 Lua 堆, 而 iot 的 OOM 兜底 trim_cache()
-- 根本清不到它 —— 所以这里自己封顶。超了整表作废重来, 不逐条 FIFO:
-- guess_last_req 本来只认 10 秒内的条目, 丢掉的都是更旧的, 配对结果不变
local MAX_LAST_REQ = 64
local PAIR_TIMEOUT_MS = 250
local stat = { frames = 0, reqs = 0, rsps = 0, errs = 0, paired = 0, orphans = 0,
               detect_round = 0, detect_fail = 0 }

local function key(slave, qty) return tostring(slave) .. ":" .. tostring(qty) end

local function push_req(f)
    local q = pendingReqs[f.fc]
    if not q then q = {}; pendingReqs[f.fc] = q end
    q[#q + 1] = { fc = f.fc, slave = f.slave, addr = f.addr, qty = f.qty, ts = os.clock() }
    while #q > MAX_PENDING_PER_FC do table.remove(q, 1) end
    lastReqs[key(f.slave, f.qty)] = { fc = f.fc, slave = f.slave, addr = f.addr, qty = f.qty, ts = os.clock() }
    -- 封顶, 理由见 MAX_LAST_REQ。pairs 数键数不再养计数器: 65 项
    -- 表每帧多走几十次迭代, 换来少一个要跟 stop() 同步的状态
    local n = 0
    for _ in pairs(lastReqs) do n = n + 1 end
    if n > MAX_LAST_REQ then lastReqs = {} end
end

local function guess_last_req(fc, slave, qty)
    if not qty then return nil end
    local r = lastReqs[key(slave, qty)]
    if not r or r.fc ~= fc then return nil end
    if (os.clock() - r.ts) > 10 then return nil end
    return r
end

-- 从 pendingReqs[fc] 里找最晚一条同 slave 同 qty 的在途请求。
-- ⚠️ 只能命中才 table.remove: 原来是"边删边比"(remove 写在校验前面),
--    于是任何一次不匹配都会把整队清空 -- 一个 rsp 打飞全部在途请求,
--    之后同 fc 的其他 rsp 只能全 orphan。这也是 paired 恒 0 的直接原因。
-- ⚠️ 必须比 slave: 总线上同时有两台从机、qty 又撞上时(现场 s1 读 qty=2、
--    s11 也读 qty=2), 不比从机会把 s11 的请求配给 s1 的响应。
local function pop_req(fc, slave, qty, now)
    local q = pendingReqs[fc]
    if not q then return nil end
    while #q > 0 and (now - q[1].ts) > (PAIR_TIMEOUT_MS / 1000) do
        table.remove(q, 1)
    end
    for i = #q, 1, -1 do
        local r = q[i]
        if r.slave == slave and r.qty == qty then
            table.remove(q, i)
            return r
        end
    end
    return nil
end

-- B1: 配对成功就把旁听到的值写进 collector, 让 iot 现成的 dirty->publish
-- 链路自己把数据发上平台。sniff 自己不发请求, 不写这里 dataCache 永远空,
-- build_items 为空、publish 直接 return, 上报链路整个空转。
-- 别名 s<从机>_r<地址>, 与前端 R:INFER 的行键保持一致。
-- 默认按 uint16 逐寄存器拆开（4 字节也可能是 2 个独立 uint16，不能假设跨寄存型）。
-- 仅在位模式铁证 (NaN/Inf / 值超 2^31) 时合并成 float32/uint32。
local function push_rsp_value(slave, addr, f)
    if not f.data or not addr then return end
    local total = math.floor(#f.data / 2)
    local i = 0
    while i < total do
        local remaining = total - i
        if remaining >= 2 then
            local b1, b2 = f.data:byte(i * 2 + 1), f.data:byte(i * 2 + 2)
            local b3, b4 = f.data:byte(i * 2 + 3), f.data:byte(i * 2 + 4)
            local e = (b1 % 128) * 2 + math.floor(b2 / 128)
            if e == 255 then
                local v = mbus.parse_value(f.data, i, "float32")
                collector.push_data(addr + i, "s" .. slave .. "_r" .. (addr + i),
                    f.hex, v, nil, "float32")
                i = i + 2
            else
                local u = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
                if u >= 2147483648 then
                    local v = mbus.parse_value(f.data, i, "uint32")
                    collector.push_data(addr + i, "s" .. slave .. "_r" .. (addr + i),
                        f.hex, v, nil, "uint32")
                    i = i + 2
                else
                    collector.push_data(addr + i, "s" .. slave .. "_r" .. (addr + i),
                        f.hex, b1 * 256 + b2, nil, "uint16")
                    i = i + 1
                end
            end
        else
            local b1, b2 = f.data:byte(i * 2 + 1), f.data:byte(i * 2 + 2)
            collector.push_data(addr + i, "s" .. slave .. "_r" .. (addr + i),
                f.hex, b1 * 256 + b2, nil, "uint16")
            i = i + 1
        end
    end
end

local function process_frame(s)
    local f = mbus.decode_frame(s)
    stat.frames = stat.frames + 1
    local pair_state, paired_addr = nil, nil
    if f.kind == "err" then
        stat.errs = stat.errs + 1
        pair_state = "err"
    elseif f.kind == "rsp" then
        stat.rsps = stat.rsps + 1
        -- pop_req 命中不了再退 guess_last_req(靠 lastReqs 兜 10 秒内的旧请求),
        -- 两条路都通到同一个 paired 处理, 别再抄一遍
        local hit = pop_req(f.fc, f.slave, f.qty, os.clock()) or guess_last_req(f.fc, f.slave, f.qty)
        if hit then
            stat.paired = stat.paired + 1
            pair_state, paired_addr = "paired", hit.addr
            push_rsp_value(f.slave, hit.addr, f)
        else
            stat.orphans = stat.orphans + 1
            pair_state = "orphan"
        end
    elseif f.kind == "req" then
        stat.reqs = stat.reqs + 1
        push_req(f)
        pair_state = "req"
    end
    f.pair_state = pair_state
    f.paired_addr = paired_addr
    f.paired_qty = f.qty
    collector.push_raw_rx(f.hex)
    collector.push_frame(f)
end

local function on_receive(id, len)
    if id ~= mbus.UART_ID then return end
    if type(len) ~= "number" or len <= 0 then return end
    while true do
        local ok, data = pcall(uart.read, id, 512)
        if not ok then return end
        if type(data) ~= "string" or #data == 0 then break end
        rxbuf = rxbuf .. data
        lastRx = os.time()
        if #rxbuf > 256 then rxbuf = rxbuf:sub(-128) end
    end
end

-- CRC 试探法切帧: 逐偏移找第一个 CRC 合法且长度自洽的帧;
-- 找不到丢 1 字节继续找。fc3/4 8 字节请求由 mbus.decode_frame 认
local function next_frame()
    for off = 1, #rxbuf do
        local s = rxbuf:sub(off)
        local n = mbus.try_extract_len(s)
        if n and #s >= n then
            local f = mbus.decode_frame(s:sub(1, n))
            if f then
                rxbuf = s:sub(n + 1)
                return s:sub(1, n)
            end
        end
    end
    return nil
end

local function task()
    local mygen = gen
    while running and gen == mygen do
        local s = next_frame()
        if s then
            process_frame(s)
        elseif #rxbuf > 0 then
            -- 可能是半帧: 已声明长度但数据没到齐, 此时丢首字节会把帧打碎。
            -- try_extract_len 需要至少 5 字节才能判定, 不足 5 字节只等待
            if #rxbuf < 5 then
                if sys then sys.wait(20) end
            else
                rxbuf = rxbuf:sub(2)
            end
        elseif sys then
            sys.wait(20)
        end
    end
end

-- 静默侦听总线 ms 毫秒, 返回期间解译出的帧数(R:SNIFF 用)
-- 从旁听 REQ 反推轮询表(R:INFER), 按 slave+addr+qty+fc 聚合命中次数
function M.infer()
    local fs = collector.get_frames()
    -- 健康度: 见到 RSP 的从机才算在线。主机轮询一个没接线的从机时只见请求不见
    -- 应答(实测 slave=11 三项 req、零 rsp), 那种 req 列进轮询表只会误导 ——
    -- 用户会照着配一个根本不存在的从机。必须单独走一遍: RSP 可能排在对应 req
    -- 后面, 边扫边判会漏掉刚扫过的那批
    local online = {}
    for _, f in ipairs(fs) do
        if f.kind == "rsp" and f.slave then online[f.slave] = true end
    end
    local agg, slaves, ignored = {}, {}, 0
    -- dtype 汇总: 每聚合项从 collector.dataCache 查每个寄存器的 dtype
    -- push_rsp_value (e4dbc30) 在 NaN/Inf→float32 / ≥2^31→uint32 时合并,
    -- 多数情况同 dtype (uint16×count), 少数情况不同
    local cache = collector.get_all_latest()
    for _, f in ipairs(fs) do
        if f.kind == "req" and f.addr ~= nil and f.qty then
            if online[f.slave] then
                local key = f.slave .. ":" .. f.addr .. ":" .. f.qty .. ":" .. f.fc
                local a = agg[key]
                if not a then
                    local dtypes = {}
                    for j = 0, f.qty - 1 do
                        local alias = "s" .. f.slave .. "_r" .. (f.addr + j)
                        local e = cache[alias]
                        dtypes[#dtypes + 1] = (e and e.dtype) or "uint16"
                    end
                    a = {
                        slave = f.slave, addr = f.addr, count = f.qty, fc = f.fc,
                        hits = 0,
                        dtype_summary = table.concat(dtypes, ","),
                    }
                    agg[key] = a
                    slaves[f.slave] = true
                end
                a.hits = a.hits + 1
            else
                ignored = ignored + 1
            end
        end
    end
    local regs = {}
    for _, a in pairs(agg) do regs[#regs + 1] = a end
    -- 先按从机再按地址排, 前端 R:INFER 直接按这个顺序显示
    table.sort(regs, function(x, y)
        if x.slave ~= y.slave then return x.slave < y.slave end
        return x.addr < y.addr
    end)
    local sl = {}
    for s in pairs(slaves) do sl[#sl + 1] = s end
    table.sort(sl)
    return {
        regs = regs,
        slaves = sl,
        -- 健康度过滤掉的请求条数, 前端据此提示"轮询没人应答"的地址
        ignored = ignored,
        stat = stat,
    }
end

function M.sniff_count(ms)
    ms = ms or 3000
    if ms < 100 then ms = 100 end
    if ms > 30000 then ms = 30000 end
    if not running then
        local ok = M.start()
        if not ok then return 0 end
    end
    local before = stat.frames
    local waited = 0
    while waited < ms do
        if sys then sys.wait(100) end
        waited = waited + 100
    end
    return math.max(0, stat.frames - before)
end

function M.start(c)
    if running then return true end
    -- 没有 sniff 持久槽: 参数由 auto_detect() 试出来只存本次会话;
    -- 调用方不传 c 时用编译期默认(原空槽的 9600 8N1)
    c = c or { baud = cfg.BAUD, databits = cfg.DATABITS, stopbits = cfg.STOPBITS, parity = cfg.PARITY }
    if gpio then
        pcall(gpio.setup, mbus.DE_PIN, 0)
        pcall(gpio.set, mbus.DE_PIN, 0)
    end
    local ok, err = pcall(uart.setup, mbus.UART_ID, c.baud or cfg.BAUD,
        c.databits or cfg.DATABITS, c.stopbits or cfg.STOPBITS,
        mbus.parity_to_uart(c.parity or cfg.PARITY))
    if not ok then
        log.error("mon", "setup failed:", tostring(err))
        return false
    end
    bootCfg = c
    lastBaud = c.baud or cfg.BAUD
    pcall(uart.on, mbus.UART_ID, "receive", on_receive)
    running = true
    gen = gen + 1
    if sys then sys.taskInit(task) end
    log.info("mon", "sniff started")
    return true
end

-- iot 的 OOM 兜底调它: collector.trim_cache() 清不到 mon 的局部表
function M.trim_reqs() lastReqs = {} end

-- 扫空一轮后还原进 sniff 时的参数。不还原则串口停在最后候选(1200 8O1),
-- 接下来 3s 真流量全成乱码, 下一轮又从 9600 重新开始, 看着像"时好时坏"
local function restore_params()
    local c = bootCfg or { baud = cfg.BAUD, databits = cfg.DATABITS, stopbits = cfg.STOPBITS, parity = cfg.PARITY }
    pcall(uart.setup, mbus.UART_ID, c.baud or cfg.BAUD,
        c.databits or cfg.DATABITS, c.stopbits or cfg.STOPBITS,
        mbus.parity_to_uart(c.parity or cfg.PARITY))
    pcall(uart.on, mbus.UART_ID, "receive", on_receive)
    lastBaud = c.baud or cfg.BAUD
end

-- 21 候选 = 7 baud × 3 parity, parity 外层: 8N1 占绝大多数,
-- 先扫 7 个 8N1 baud 再碰 E/O, 常见 1~7s 命中, 全落空才走满 21s。
-- databits/stopbits 固定 8/1 —— ModbusRTU 事实标准。
--
-- 判定不新写校验, 借 task() 现有 CRC 试探切帧, 只数 stat.frames 增量:
-- CRC 16 位单帧误判 ~1/65536, 所以要 DETECT_HITS(2) 帧才算命中。
--
-- ⚠️ 结果只存本次会话不写 fskv, poll/sniff 两套配置必须隔离(见 README)
function M.auto_detect()
    if not sys then return nil, "no sys" end
    if not running and not M.start() then return nil, "start fail" end
    -- sniff 启动后等 5s: 142 设备 UART 从 poll 切到 sniff 可能错乱,
    -- 等它稳定再切 baud. 之前 0 帧就是 142 设备 UART 没准备好
    log.info("mon", "auto_detect: wait 5s for 142 UART stable")
    sys.wait(5000)
    for _, p in ipairs({ 0, 1, 2 }) do
        for _, b in ipairs(cfg.DETECT_BAUDS) do
            -- ★ 完整复位 (合宙 Q1 修法): close + wait500 + setup + on
            -- 在已打开的 485 口上 uart.setup 走 Uart_ChangeBR 快路径,
            -- 只改分频不复位 RX/DE, 需 close+wait500 强制重开.
            pcall(uart.close, mbus.UART_ID)
            if sys then sys.wait(500) end
            rxbuf = ""
            local ok = pcall(uart.setup, mbus.UART_ID, b, 8, 1, mbus.parity_to_uart(p))
            if ok then
                pcall(uart.on, mbus.UART_ID, "receive", on_receive)
                -- 高 baud 切完多等 200ms (跟之前 D2 v5 一致, 142 设备 19200
                -- t3.5=1.82ms 太早到 RX FIFO 接不住, 给驱动恢复窗口)
                if b >= 19200 then sys.wait(200) end
                local probe = mbus.build_read(1, 142, 1)
                if probe then
                    if gpio then pcall(gpio.set, mbus.DE_PIN, 1) end
                    pcall(uart.write, mbus.UART_ID, probe)
                    if sys then sys.wait(mbus.calc_de_hold_ms(#probe, b)) end
                    if gpio then pcall(gpio.set, mbus.DE_PIN, 0) end
                    log.info("mon", "probe sent len=" .. #probe .. " baud=" .. b .. " p=" .. p)
                end
                local before_paired = stat.paired
                -- ★ 600ms 固定 wait (不能跟 #rxbuf 联动: 字节已进 FIFO
                -- 但 task() 协程还没跑 process_frame, paired=0 假阴性)
                local t = 0
                while t < 600 do
                    if sys then sys.wait(20) end
                    t = t + 20
                end
                log.info("mon", "check baud=" .. b .. " p=" .. p
                    .. " frames=" .. tostring(stat.frames)
                    .. " paired=" .. tostring(stat.paired)
                    .. " orphans=" .. tostring(stat.orphans)
                    .. " rxbuf=" .. tostring(#rxbuf)
                    .. " last_rx=" .. tostring(lastRx))
                if stat.paired > before_paired then
                    lastBaud = b
                    log.info("mon", "detect ok: baud=" .. b .. " parity=" .. p)
                    return { baud = b, databits = 8, stopbits = 1, parity = p }
                end
            end
            if not running then return nil, "stopped" end
        end
    end
    restore_params()
    log.warn("mon", "detect fail: 21 candidates no hit")
    return nil, "no hit"
end

-- 识别循环: 扫一轮, 不中就还原参数/等 3s/再扫一轮, 直到命中或 mon.stop()。
-- 不回 idle: 模式必须停在 sniff, 否则前端看到掉回 idle 会以为设备重启了
-- mydgen 和 task.mygen 一样: 「重新识别」加 detectGen, 旧循环悄悄退出,
-- 否则两循环会同时抢串口, 先完成那个可能覆盖后一个的结果
local function detect_loop()
    local mydgen = detectGen
    while running and detectGen == mydgen do
        detecting = true
        stat.detect_round = stat.detect_round + 1
        local r = M.auto_detect()
        if detectGen ~= mydgen or not running then return end
        if r then
            detecting = false
            _G.mon_detect_result = r
            log.info("mon", "detect ok, sniff ready")
            return
        end
        stat.detect_fail = stat.detect_fail + 1
        log.warn("mon", "detect round " .. stat.detect_round .. " no hit, retry in "
            .. DETECT_RETRY_MS .. "ms")
        if sys then sys.wait(DETECT_RETRY_MS) end
    end
end

-- 请求开始/重来一轮识别。已在识别中就把 detectGen 加一作废当前轮, 由新任务从
-- 第一个候选重新扫 —— 这就是前端「重新识别」按钮的语义
function M.request_detect()
    if not running then return false, "not running" end
    detectGen = detectGen + 1
    _G.mon_detect_result = nil
    if sys then sys.taskInit(detect_loop) end
    return true
end

function M.is_detecting() return detecting end

function M.detect_result() return _G.mon_detect_result end

function M.stop()
    if not running then return true end
    -- detecting 必须在这里清: W:MODE=idle 是识别中唯一逃生口,
    -- 少了这行 cmd 的 BUSY 闸门会一直把后续命令挡在外面
    detecting = false
    running = false
    gen = gen + 1
    if gpio then pcall(gpio.set, mbus.DE_PIN, 0) end
    pcall(uart.on, mbus.UART_ID, "receive", nil)
    rxbuf = ""
    pendingReqs, lastReqs = {}, {}
    log.info("mon", "sniff stopped")
    return true
end

function M.is_running() return running end

function M.status()
    local st = {}
    for k, v in pairs(stat) do st[k] = v end
    st.running = running
    st.gen = gen
    st.baud = lastBaud or cfg.BAUD
    -- 前端要靠它显示"正在识别(第N轮/已失败M次)", 也要靠它判断能不能点重新识别
    st.detecting = detecting
    st.detected = _G.mon_detect_result
    st.pending = (function()
        local n = 0
        for _, q in pairs(pendingReqs) do n = n + #q end
        return n
    end)()
    st.last_rx = lastRx
    st.buf = #rxbuf
    return st
end

function M.recent_frames(n)
    local fs = collector.get_frames()
    local out = {}
    for i = math.max(1, #fs - (n or 10) + 1), #fs do out[#out + 1] = fs[i] end
    return out
end

return M
