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
local MAX_PENDING_PER_FC = 4
local PAIR_TIMEOUT_MS = 250
local stat = { frames = 0, reqs = 0, rsps = 0, errs = 0, paired = 0, orphans = 0 }

local function key(slave, qty) return tostring(slave) .. ":" .. tostring(qty) end

local function push_req(f)
    local q = pendingReqs[f.fc]
    if not q then q = {}; pendingReqs[f.fc] = q end
    q[#q + 1] = { fc = f.fc, slave = f.slave, addr = f.addr, qty = f.qty, ts = os.clock() }
    while #q > MAX_PENDING_PER_FC do table.remove(q, 1) end
    lastReqs[key(f.slave, f.qty)] = { fc = f.fc, slave = f.slave, addr = f.addr, qty = f.qty, ts = os.clock() }
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
    pcall(uart.write, mbus.VUART_DEBUG, "RX485:" .. f.hex .. "\r\n")
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
    local agg = {}
    local slaves = {}
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
    table.sort(regs, function(x, y)
        if x.slave ~= y.slave then return x.slave < y.slave end
        return x.addr < y.addr
    end)
    local sl = {}
    for s in pairs(slaves) do sl[#sl + 1] = s end
    table.sort(sl)
    local st = stat
    return {
        regs = regs,
        slaves = sl,
        stat = {
            frames = st.frames, reqs = st.reqs, rsps = st.rsps,
            errs = st.errs, paired = st.paired, orphans = st.orphans,
        },
    }
end

-- 把推断结果写成轮询配置(前端 W:APPLYINFER)
function M.apply_infer()
    local inf = M.infer()
    if #inf.regs == 0 then return false, "no req frames" end
    local regs = {}
    for _, a in ipairs(inf.regs) do
        regs[#regs + 1] = {
            name = "s" .. a.slave .. "_r" .. a.addr,
            alias = "s" .. a.slave .. "_r" .. a.addr,
            addr = a.addr, count = a.count, dtype = "uint16",
            byteOrder = "BE", wordOrder = "BE",
        }
    end
    local c = cfgstore.load_poll()
    c.regs = regs
    local n, err = cfgstore.normalize_poll(c)
    if not n then return false, err end
    local ok, serr = cfgstore.save_poll(c)
    if not ok then return false, serr end
    return true, #regs
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
function M.get_gen() return gen end

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
