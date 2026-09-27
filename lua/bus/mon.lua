local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local uart = corelib.get("uart")
local gpio = corelib.try("gpio")
local sys = corelib.try("sys")

local mbus = require "bus/mbus"
local collector = require "data/collector"
local cfgstore = require "cfg"
local store = corelib.try("data/store")

local M = {}

local running, gen = false, 0
local rxbuf = ""
local pendingReqs, lastReqs = {}, {}
local stat = { frames = 0, reqs = 0, rsps = 0, errs = 0, paired = 0, orphans = 0 }

local function key(slave, qty) return slave .. ":" .. tostring(qty) end

local function pending_push(f)
    local q = pendingReqs[f.fc]
    if not q then q = {}; pendingReqs[f.fc] = q end
    while #q >= 4 do table.remove(q, 1) end
    q[#q + 1] = { slave = f.slave, addr = f.addr, qty = f.qty or 1, t = os.time() }
end

local function pending_pop(f)
    local q = pendingReqs[f.fc]
    if not q or #q == 0 then return nil end
    local now = os.time()
    while #q > 0 and now - q[1].t > 1 do table.remove(q, 1) end
    for i = #q, 1, -1 do
        local p = q[i]
        if p.slave == f.slave and (p.qty == f.qty or f.qty == nil) then
            table.remove(q, i)
            return p
        end
    end
    table.remove(q, 1)
    return nil
end

local function process_frame(s)
    local f = mbus.decode_frame(s)
    stat.frames = stat.frames + 1
    if f.kind == "err" then
        stat.errs = stat.errs + 1
    elseif f.kind == "rsp" then
        stat.rsps = stat.rsps + 1
        if not pending_pop(f) then
            local k = key(f.slave, f.qty or 1)
            local p = lastReqs[k]
            if p and os.time() - p.t < 10 then
                stat.paired = stat.paired + 1
            else
                stat.orphans = stat.orphans + 1
            end
        else
            stat.paired = stat.paired + 1
        end
    elseif f.kind == "req" then
        stat.reqs = stat.reqs + 1
        pending_push(f)
        lastReqs[key(f.slave, f.qty or 1)] = { t = os.time() }
    end
    if store then store.begin_round() end
    collector.push_frame(f)
    pcall(uart.write, mbus.VUART_DEBUG, "RX485:" .. f.hex)
end

local function on_receive(id, len)
    if id ~= mbus.UART_ID then return end
    if type(len) ~= "number" or len <= 0 then return end
    while true do
        local ok, data = pcall(uart.read, id, 512)
        if not ok then return end
        if type(data) ~= "string" or #data == 0 then break end
        rxbuf = rxbuf .. data
        if #rxbuf > 512 then rxbuf = rxbuf:sub(-256) end
    end
end

local function task()
    while running do
        local n = mbus.try_extract_len(rxbuf)
        if n and #rxbuf >= n then
            local s = rxbuf:sub(1, n)
            rxbuf = rxbuf:sub(n + 1)
            process_frame(s)
        elseif #rxbuf > 0 then
            rxbuf = rxbuf:sub(2)
        elseif sys then
            sys.wait(20)
        end
    end
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
    log.info("mon", "sniff stopped")
    return true
end

function M.is_running() return running end
function M.get_gen() return gen end

function M.status()
    local st = {}
    for k, v in pairs(stat) do st[k] = v end
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
