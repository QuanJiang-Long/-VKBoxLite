local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local uart = corelib.get("uart")
local gpio = corelib.try("gpio")
local sys = corelib.try("sys")

local mbus = require "bus/mbus"
local collector = require "data/collector"
local cfgstore = require "cfg"

local M = {}

local running, gen = false, 0
local rxbuf = ""
local pendingReqs, lastReqs = {}, {}
local lastRx, lastBaud = 0, nil
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
local stat = { frames = 0, reqs = 0, rsps = 0, errs = 0, paired = 0, orphans = 0 }

local function key(slave, qty) return tostring(slave) .. ":" .. tostring(qty) end

local function push_req(f)
    local q = pendingReqs[f.fc]
    if not q then q = {}; pendingReqs[f.fc] = q end
    q[#q + 1] = { fc = f.fc, slave = f.slave, addr = f.addr, qty = f.qty, ts = os.clock() }
    while #q > MAX_PENDING_PER_FC do table.remove(q, 1) end
    lastReqs[key(f.slave, f.qty)] = { fc = f.fc, slave = f.slave, addr = f.addr, qty = f.qty, ts = os.clock() }
    -- 封顶, 理由见 MAX_LAST_REQ。走一遍 pairs 数键数而不再养一个计数器:
    -- 表最多 65 项, 每帧多走几十次迭代, 换来少一个要和 stop() 同步的状态
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

local function pop_req(fc, slave, qty, now)
    local q = pendingReqs[fc]
    if not q or #q == 0 then return nil end
    while #q > 0 do
        if (now - q[1].ts) <= (PAIR_TIMEOUT_MS / 1000) then break end
        table.remove(q, 1)
    end
    if #q == 0 then return nil end
    for i = #q, 1, -1 do
        local r = q[i]
        table.remove(q, i)
        if fc >= 3 then
            if r.qty == qty then return r end
        else
            return r
        end
    end
    return nil
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
        local now = os.clock()
        local hit = pop_req(f.fc, f.slave, f.qty, now)
        if hit then
            stat.paired = stat.paired + 1
            pair_state, paired_addr = "paired", hit.addr
        else
            local g = guess_last_req(f.fc, f.slave, f.qty)
            if g then
                stat.paired = stat.paired + 1
                pair_state, paired_addr = "paired", g.addr
            else
                stat.orphans = stat.orphans + 1
                pair_state = "orphan"
            end
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
        if #rxbuf > 512 then rxbuf = rxbuf:sub(-256) end
    end
end

-- CRC 试探法切帧: 逐个偏移找第一个 CRC 合法且长度自洽的帧,
-- 与 poll 同一套策略; 找不到才丢 1 字节继续找
local function next_frame()
    for off = 1, #rxbuf do
        local s = rxbuf:sub(off)
        local n = mbus.try_extract_len(s)
        if n and #s >= n then
            local f = mbus.parse_frame(s:sub(1, n))
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

-- 静默侦听总线 ms 毫秒, 返回期间解译出的帧数(前端 R:SNIFF 用)
-- 若嗅探任务已在跑, 直接统计窗口期内的增量; 否则临时起一个窗口
-- 从旁听到的 REQ 帧反推轮询表(前端 R:INFER)
-- 按 slave+addr+qty+fc 聚合命中次数
function M.infer()
    local agg, slaves = {}, {}
    for _, f in ipairs(collector.get_frames()) do
        if f.kind == "req" and f.addr ~= nil and f.qty then
            local key = f.slave .. ":" .. f.addr .. ":" .. f.qty .. ":" .. f.fc
            local a = agg[key]
            if not a then
                a = { slave = f.slave, addr = f.addr, count = f.qty, fc = f.fc, hits = 0 }
                agg[key] = a
                slaves[f.slave] = true
            end
            a.hits = a.hits + 1
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
        -- 统计段原样带出, 前端据此判断"旁听到的帧够不够多、配出来可不可信"
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
    c = c or cfgstore.load_sniff()
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

-- sniff 通讯参数自动识别(前端 R:AUTODETECT)。
-- 21 个候选 = 7 baud × 3 parity，parity 放外层：8N1 占现场绝大多数，先把
-- 8N1 整个扫完再碰 E/O，常见情况 1~7s 命中，全落空才走满 21s。
-- databits/stopbits 固定 8/1 —— ModbusRTU 事实标准，7 位/2 停止位极少见，
-- 为它们再加 3 倍候选不划算。
--
-- 判定不新写校验，直接借 task() 现有的 CRC 试探切帧，只数 stat.frames 增量：
-- 参数错 → 字节乱 → CRC 不过 → 一帧都解不出。CRC 是 16 位校验，单帧误判
-- 率 ~1/65536，所以要 DETECT_HITS(2) 帧才算命中。
--
-- ⚠️ 结果只存本次会话，不写 fskv。poll/sniff 两套配置必须隔离，识别出的
-- 参数不该悄悄改掉任何一侧(见 lua/README.md「poll / sniff 配置隔离」)
function M.auto_detect()
    if not sys then return nil, "no sys" end
    if not running and not M.start() then return nil, "start fail" end
    for _, p in ipairs({ 0, 1, 2 }) do
        for _, b in ipairs(cfg.DETECT_BAUDS) do
            -- 上一个候选的残留字节必须作废: 那是错参数解出来的乱码，
            -- 不清就会在下一个候选的窗口里被误当成新参数的帧
            rxbuf = ""
            local ok = pcall(uart.setup, mbus.UART_ID, b, 8, 1,
                mbus.parity_to_uart(p))
            if ok then
                -- ⚠️ uart.setup 会重置 receive callback，必须重新绑。
                -- 少了这行，从这个候选开始一个字节都收不到，全部候选都会
                -- 假阴性(原工程 VKBox_Lite(1) 的 Q-Fix 8 踩过这个坑)
                pcall(uart.on, mbus.UART_ID, "receive", on_receive)
                local before = stat.frames
                sys.wait(cfg.DETECT_WIN_MS)
                if stat.frames - before >= cfg.DETECT_HITS then
                    lastBaud = b
                    log.info("mon", "detect ok: baud=" .. b .. " parity=" .. p)
                    return { baud = b, databits = 8, stopbits = 1, parity = p }
                end
            end
        end
    end
    log.warn("mon", "detect fail: 21 candidates no hit")
    return nil, "no hit"
end

function M.stop()
    if not running then return true end
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
