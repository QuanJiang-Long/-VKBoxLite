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

local curSlot = "poll"
local stat = { rounds = 0, ok = 0, timeout = 0, werr = 0, zero = 0 }
local wstat = { queued = 0, done = 0, wfail = 0 }



local function de_high()

end

local function de_low()

end

local function drain()
    if not sys then return end
    for _ = 1, 16 do
        local ok, d = pcall(uart.read, mbus.UART_ID, 256)
        if not ok or type(d) ~= "string" or #d == 0 then break end
    end
end













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



        log.debug("poll", string.format("on_receive id=%d len=%d n=%d flag=%s", id, len, #data, tostring(respFlag)))
        if respFlag then
            respData = (respData or "") .. data
            if #respData > 512 then respData = respData:sub(-256) end
        else


            log.warn("poll", string.format("on_receive id=%d got %d bytes but respFlag=false (raw=[%s])",
                id, #data, hexspaced(data)))
        end
    end
end




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

    if timeout_ms == nil then timeout_ms = cfg.TIMEOUT_MS end


    if not running then pcall(ensure_uart) end
    drain()                                  -- 先清残留, 避免杂字节顶掉真响应
    respFlag, respData = true, nil
    reqSlave, reqFc = exp_slave, exp_fc


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





local function drain_write_queue(mygen, sniff_yield)
    while #writeQ > 0 do
        if gen ~= mygen then return end
        if sniff_yield and mon_running() then return end
        do_write(table.remove(writeQ, 1))
    end
end







local function worker()
    writeTaskRun = true
    drain_write_queue(gen, true)

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

    timeout_ms = timeout_ms or (lastCfg and lastCfg.timeout_ms or cfg.TIMEOUT_MS)
    local waited = 0
    while waited < timeout_ms do

        if #rawCap > 0 and mbus.parse_frame(rawCap) then break end
        if sys then sys.wait(5) end
        waited = waited + 5
    end
    local cap = rawCap or ""
    rawCap = nil




    if running then
        pcall(uart.on, mbus.UART_ID, "receive", on_receive)
    else
        pcall(uart.on, mbus.UART_ID, "receive", nil)



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

    local c = (src == "pull") and cfgstore.load_pull() or cfgstore.load_poll()
    if c then
        regs = c.regs or {}
        interval = c.interval_ms or cfg.POLL_INTERVAL_MS
        lastCfg = c
    end
    return lastCfg
end


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




    regs, interval, lastCfg = {}, cfg.POLL_INTERVAL_MS, nil














    pcall(uart.on, mbus.UART_ID, "receive", nil)
    pcall(uart.close, mbus.UART_ID)
    if was_running then log.info("poll", "stopped") end
    return true
end

function M.is_running() return running end

return M
