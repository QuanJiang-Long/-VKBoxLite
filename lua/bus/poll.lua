local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local uart = corelib.get("uart")
local gpio = corelib.try("gpio")
local sys = corelib.try("sys")

local mbus = require "bus/mbus"
local collector = require "data/collector"
local cfgstore = require "cfg"
local guard = corelib.try("svc/guard")
local store = corelib.try("data/store")
local logctl = corelib.try("svc/logctl")

local M = {}

local running, gen = false, 0
local regs, interval = {}, cfg.POLL_INTERVAL_MS
local writeQ = {}
local writeTaskRun = false
local respFlag, respData = false, nil
local reqSlave, reqFc = nil, nil
local lastCfg = nil
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

local function poll_reg(reg)
    local slave = lastCfg.slave or cfg.SLAVE_ADDR
    local frame, err = mbus.build_read(slave, reg.addr, reg.count or 1)
    if not frame then
        log.warn("poll", "build fail", reg.addr, tostring(err))
        return
    end
    local f = do_transaction(frame, lastCfg and lastCfg.timeout or cfg.TIMEOUT_MS, slave, 3)
    if not f then
        stat.timeout = stat.timeout + 1
        -- 前若干次超时把原始回字节打出来, 便于区分"完全没回"与"回了但解析不了"
        if stat.timeout <= 3 then
            local hex = respData or ""
            hex = #hex > 0 and (hex:gsub(".", function(c) return string.format("%02x", c:byte()) end)) or "(无字节)"
            log.warn("poll", string.format("timeout #%d addr=%d rx=%s", stat.timeout, reg.addr, hex))
        end
        return
    end
    if f.err then
        stat.werr = stat.werr + 1
        return
    end
    local vals, hex = mbus.parse_regs(f.data, reg.dtype or "uint16", reg.byteOrder, reg.wordOrder)
    if not vals then return end
    stat.ok = stat.ok + 1
    for i, v in ipairs(vals) do
        collector.push_data(reg.addr + i - 1, reg.name or ("r" .. reg.addr), hex, v, nil, reg.dtype, reg.eps)
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
    local f = do_transaction(frame, lastCfg and lastCfg.timeout or cfg.TIMEOUT_MS,
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

local function drain_write_queue(mygen)
    while #writeQ > 0 do
        if gen ~= mygen or not running then return end
        local w = table.remove(writeQ, 1)
        do_write(w)
    end
end

local function mon_running()
    local ok, ctrl = pcall(require, "bus/ctrl")
    if ok and ctrl and ctrl.get_mode() == "sniff" then return true end
    return false
end

local function worker()
    writeTaskRun = true
    local mygen = gen
    while #writeQ > 0 do
        if gen ~= mygen then break end
        local w = table.remove(writeQ, 1)
        if mon_running() then break end
        do_write(w)
    end
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
        if store then store.begin_round() end
        for _, reg in ipairs(regs) do
            if gen ~= mygen or not running then break end
            if #writeQ > 0 then drain_write_queue(mygen) end
            poll_reg(reg)
            if guard then guard.alive() end
            if sys then sys.wait(5) end
        end
        drain_write_queue(mygen)
        stat.rounds = stat.rounds + 1
        if stat.ok == okBefore then
            stat.zero = stat.zero + 1
            if stat.zero == 1 or stat.zero % 20 == 0 then
                log.warn("poll", "round " .. stat.rounds .. " 无有效响应 timeout=" .. stat.timeout ..
                    " werr=" .. stat.werr .. " (查从机地址/波特率/校验位/AB线/DE极性)")
            end
        else
            stat.zero = 0
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

function M.probe_raw(slave, addr, qty, timeout_ms)
    slave = slave or (lastCfg and lastCfg.slave) or cfg.SLAVE_ADDR
    addr = addr or 0
    qty = qty or 1
    timeout_ms = timeout_ms or (lastCfg and lastCfg.timeout) or cfg.TIMEOUT_MS
    local frame, err = mbus.build_read(slave, addr, qty)
    if not frame then return nil, tostring(err) end
    if not running then
        local ok, e = pcall(uart.setup, mbus.UART_ID, lastCfg and lastCfg.baud or cfg.BAUD,
            lastCfg and lastCfg.databits or cfg.DATABITS,
            lastCfg and lastCfg.stopbits or cfg.STOPBITS,
            mbus.parity_to_uart(lastCfg and lastCfg.parity or cfg.PARITY))
        if not ok then return nil, "uart setup fail: " .. tostring(e) end
        if gpio then pcall(gpio.setup, mbus.DE_PIN, 0) end
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
    local waited = 0
    while waited < timeout_ms do
        if #rawCap > 0 and mbus.parse_frame(rawCap) then break end
        if sys then sys.wait(5) end
        waited = waited + 5
    end
    local cap = rawCap or ""
    rawCap = nil
    if running then pcall(uart.on, mbus.UART_ID, "receive", on_receive) end
    return {
        tx_ok = txok,
        tx_err = txok and "" or tostring(txerr),
        tx_hex = (frame:gsub(".", function(c) return string.format("%02x", c:byte()) end)),
        rx_len = #cap,
        rx_hex = #cap > 0 and (cap:gsub(".", function(c) return string.format("%02x", c:byte()) end)) or "",
        parsed = mbus.parse_frame(cap) ~= nil,
        slave = slave, addr = addr, qty = qty,
    }
end

function M.reload_cfg()
    local c = cfgstore.load_poll()
    if c then
        regs = c.regs or {}
        interval = c.interval_ms or cfg.POLL_INTERVAL_MS
        lastCfg = c
    end
    return lastCfg
end

function M.apply_cfg(c)
    if not c then return false end
    regs = c.regs or regs
    interval = c.interval_ms or interval
    lastCfg = c
    return true
end

function M.set_regs(r) regs = r or {} end
function M.set_interval(ms) interval = ms or cfg.POLL_INTERVAL_MS end
function M.get_regs() return regs end
function M.get_cfg() return lastCfg end

function M.needs_restart(c)
    if not lastCfg then return true end
    return (c.baud or cfg.BAUD) ~= (lastCfg.baud or cfg.BAUD)
        or (c.parity or cfg.PARITY) ~= (lastCfg.parity or cfg.PARITY)
        or (c.slave or cfg.SLAVE_ADDR) ~= (lastCfg.slave or cfg.SLAVE_ADDR)
end

function M.enqueue_write(w)
    if #writeQ >= cfg.WRITEQ_MAX then return false, "queue full" end
    wstat.queued = wstat.queued + 1
    writeQ[#writeQ + 1] = w
    if not running then ensure_worker() end
    return true
end

function M.enqueue_write_multi(w)
    return M.enqueue_write(w)
end

function M.write_status()
    local st = {}
    for k, v in pairs(wstat) do st[k] = v end
    st.queue = #writeQ
    return st
end

function M.set_frame_log(on)
    M.frame_log = on and true or false
end

function M.frame_log_status() return M.frame_log end

function M.status()
    local st = {}
    for k, v in pairs(stat) do st[k] = v end
    st.regs = #regs
    st.interval = interval
    return st
end

function M.start()
    if running then return true end
    M.reload_cfg()
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
    log.info("poll", string.format("started, regs=%d slave=%d baud=%d parity=%d timeout=%dms",
        #regs, lastCfg and lastCfg.slave or cfg.SLAVE_ADDR,
        lastCfg and lastCfg.baud or cfg.BAUD, lastCfg and lastCfg.parity or cfg.PARITY,
        lastCfg and lastCfg.timeout or cfg.TIMEOUT_MS))
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
function M.get_gen() return gen end

return M
