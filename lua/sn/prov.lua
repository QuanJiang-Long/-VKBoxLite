local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local uart = corelib.get("uart")
local sys = corelib.try("sys")
local fskv = corelib.try("fskv")

local M = {}

local DATA_BITS, STOP_BITS, PARITY = 8, 1, 0
local BAUD = 115200
local MAX_BUF = 2048

local UART_ID = uart.VUART_0
if UART_ID == nil then UART_ID = 4 end

local rx_buf = ""
local cb_registered, loop_started = false, false

local function load_switch(key, default)
    if fskv then
        local v = fskv.get(key)
        if v == "1" or v == 1 then return true end
        if v == "0" or v == 0 then return false end
    end
    return default
end

M.write_enable = load_switch("sn_en_write", true)
M.clear_enable = load_switch("sn_en_clear", true)
M.lock_enable = load_switch("sn_en_lock", true)
M.unlock_enable = load_switch("sn_en_unlock", true)

function M.set_switch(name, on, persist)
    local field = name .. "_enable"
    if M[field] == nil then return false, "unknown switch" end
    M[field] = on and true or false
    if persist then
        if not fskv then return false, "fskv unavailable" end
        fskv.set("sn_en_" .. name, on and "1" or "0")
        if fskv.save then pcall(fskv.save) end
    end
    log.info("prov", "switch", name, tostring(on))
    return true
end

function M.switch_status()
    return {
        write = M.write_enable,
        clear = M.clear_enable,
        lock = M.lock_enable,
        unlock = M.unlock_enable,
    }
end

local function reply(s)
    log.debug("prov", "tx:", s)
    pcall(uart.write, UART_ID, s .. "\r\n")
end

local function sn() return require "sn/sn" end

local CMDS = {}

CMDS["R:SN"] = function()
    local st = sn().state()
    if st == "ready" then reply("RET:SN=" .. tostring(_G.get_device_sn()))
    elseif st == "invalid" then reply("RET:SN=INVALID")
    else reply("RET:SN=EMPTY") end
end

CMDS["R:ID"] = function()
    reply("RET:ID=" .. sn().info_line())
end

CMDS["C:SN"] = function()
    if not M.clear_enable then return reply("RET:FAIL:clear disabled") end
    local ok, err = sn().clear()
    if ok then reply("RET:OK") else reply("RET:FAIL:" .. tostring(err)) end
end

CMDS["LOCK:SN"] = function()
    if not M.lock_enable then return reply("RET:FAIL:lock disabled") end
    if sn().state() ~= "ready" then return reply("RET:FAIL:no sn") end
    sn().set_lock()
    reply("RET:OK")
end

CMDS["UNLOCK:SN"] = function()
    if not M.unlock_enable then return reply("RET:FAIL:unlock disabled") end
    if not sn().locked() then return reply("RET:FAIL:not locked") end
    sn().clear_lock()
    log.warn("prov", "SN lock cleared (rework)")
    reply("RET:OK")
end

CMDS["R:SNEN"] = function()
    local st = M.switch_status()
    reply(string.format("RET:SNEN=write=%d clear=%d lock=%d unlock=%d",
        st.write and 1 or 0, st.clear and 1 or 0, st.lock and 1 or 0, st.unlock and 1 or 0))
end

local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

local function dispatch(line)
    log.debug("prov", "cmd:", line)
    local warg = line:match("^W:SN=(.+)$")
    if warg then
        if not M.write_enable then return reply("RET:FAIL:write disabled") end
        local s, force = warg:match("^([^,]*),?(.*)$")
        local ok, err = sn().write(trim(s), { force = force:upper() == "FORCE" })
        if ok then reply("RET:OK") else reply("RET:FAIL:" .. tostring(err)) end
        return
    end
    local swarg = line:match("^W:SNEN=(.+)$")
    if swarg then
        local name, val, persist = swarg:match("^%s*([^,]+)%s*,%s*([^,]+)%s*,?%s*(%a*)%s*$")
        if not name or not val then return reply("RET:FAIL:SNEN:bad args") end
        local on = (trim(val) == "1" or trim(val):upper() == "ON" or trim(val):upper() == "TRUE")
        local ok, err = M.set_switch(trim(name):lower(), on, trim(persist):upper() == "P")
        if ok then reply("RET:OK") else reply("RET:FAIL:" .. tostring(err)) end
        return
    end
    local fn = CMDS[line]
    if fn then return fn() end
    if type(_G.vcom_handle) == "function" and _G.vcom_handle(line) then return end
    log.debug("prov", "unknown cmd, ignored:", line)
end

function M.poll()
    local n = 0
    while n < 8 do
        local nl = rx_buf:find("\n", 1, true)
        if not nl then break end
        local line = rx_buf:sub(1, nl - 1)
        rx_buf = rx_buf:sub(nl + 1)
        line = (line:gsub("[\r\n]", ""))
        line = trim(line)
        if #line > 0 then
            pcall(dispatch, line)
            n = n + 1
        end
    end
    return n
end

local function on_receive(id, len)
    if id ~= UART_ID then return end
    if type(len) ~= "number" or len <= 0 then return end
    while true do
        local ok, data = pcall(uart.read, id, 1024)
        if not ok then
            log.error("prov", "uart.read err:", tostring(data))
            return
        end
        if type(data) ~= "string" or #data == 0 then break end
        rx_buf = rx_buf .. data
        if #rx_buf > MAX_BUF then rx_buf = "" end
    end
end

function M.init(id)
    if id ~= nil then UART_ID = id end
    local ok, err = pcall(uart.setup, UART_ID, BAUD, DATA_BITS, STOP_BITS,
        uart.NONE or uart.None or 0)
    if not ok then
        log.error("prov", "uart.setup failed! id =", UART_ID, tostring(err))
        return false
    end
    local st = M.switch_status()
    log.info("prov", string.format("COM%d setup ok, switch: write=%d clear=%d lock=%d unlock=%d",
        UART_ID, st.write and 1 or 0, st.clear and 1 or 0, st.lock and 1 or 0, st.unlock and 1 or 0))
    return true
end

function M.register_callback()
    if cb_registered then return true end
    local ok, err = pcall(uart.on, UART_ID, "receive", on_receive)
    if not ok then
        log.error("prov", "uart.on failed! id =", UART_ID, tostring(err))
        return false
    end
    cb_registered = true
    log.info("prov", "COM" .. UART_ID .. " ready")
    return true
end

function M.start_loop()
    if loop_started then return true end
    if not sys then return false end
    loop_started = true
    sys.taskInit(function()
        while true do
            M.poll()
            sys.wait(20)
        end
    end)
    log.info("prov", "cmd loop started")
    return true
end

function M.wait_ready(timeout_ms)
    if timeout_ms == nil then timeout_ms = 30000 end
    if timeout_ms < 0 then timeout_ms = 0 end
    local tries = math.floor(timeout_ms / 100) + 1
    for i = 1, tries do
        if not cb_registered then
            pcall(uart.setup, UART_ID, BAUD, DATA_BITS, STOP_BITS, uart.NONE or uart.None or 0)
            M.register_callback()
        end
        if cb_registered then
            M.start_loop()
            return true
        end
        if i < tries and sys then sys.wait(100) end
    end
    return false
end

function M.uart_id() return UART_ID end

return M
