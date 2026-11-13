local util = require "util"
local log = util.log()

local uart = util.get("uart")
local sys = util.try("sys")
local fskv = util.try("fskv")
local rtos = util.try("rtos")

local M = {}

local DATA_BITS, STOP_BITS, PARITY = 8, 1, 0
local BAUD = 115200




local MAX_BUF = 16384

local UART_ID = uart.VUART_0
if UART_ID == nil then UART_ID = 4 end







local rx_buf, rx_parts, rx_len = "", {}, 0

local rx_lost
local cb_registered, loop_started = false, false

local loop_crashes = 0




local sn_busy = false
function M.busy() return sn_busy end

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
if not sn().set_lock() then return reply("RET:FAIL:lock not persisted") end
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

local function trim(s)

local f = s:byte(1)
if f and f > 32 then
local l = s:byte(-1)
if l and l > 32 then return s end
end
return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function dispatch(line)



if #line > 80 then
log.debug("prov", "cmd:", #line, "B:", line:sub(1, 80))
else
log.debug("prov", "cmd:", line)
end

local is_sn_cmd = false
local warg = line:match("^W:SN=(.+)$")
if warg then
is_sn_cmd = true
if not M.write_enable then return reply("RET:FAIL:write disabled") end
local s, force = warg:match("^([^,]*),?(.*)$")
sn_busy = true
local ok, err = sn().write(trim(s), { force = force:upper() == "FORCE" })
if ok then reply("RET:OK") else reply("RET:FAIL:" .. tostring(err)) end
sn_busy = false
return
end
local swarg = line:match("^W:SNEN=(.+)$")
if swarg then
is_sn_cmd = true
local name, val, persist = swarg:match("^%s*([^,]+)%s*,%s*([^,]+)%s*,?%s*(%a*)%s*$")
if not name or not val then return reply("RET:FAIL:SNEN:bad args") end
local on = (trim(val) == "1" or trim(val):upper() == "ON" or trim(val):upper() == "TRUE")
sn_busy = true
local ok, err = M.set_switch(trim(name):lower(), on, trim(persist):upper() == "P")
if ok then reply("RET:OK") else reply("RET:FAIL:" .. tostring(err)) end
sn_busy = false
return
end
local fn = CMDS[line]
if fn then

is_sn_cmd = line:match(":SN") or line == "R:ID" or line == "R:SNEN" or line == "C:SN"
if is_sn_cmd then sn_busy = true end
fn()
if is_sn_cmd then sn_busy = false end
return
end
if type(_G.vcom_handle) == "function" and _G.vcom_handle(line) then return end
log.debug("prov", "unknown cmd, ignored:", line)
end



local function cat2(a, b) return a .. b end









local function why_and_pool(e)
local s = tostring(e):gsub("[\r\n]", " ")
if #s > 96 then s = s:sub(1, 96) end
local pool = ""
if rtos then
local ok, total, used = pcall(rtos.meminfo, "lua")
if ok and type(total) == "number" and type(used) == "number" then
pool = " pool " .. math.floor(used) .. "/" .. math.floor(total)
end
end
return s .. pool
end

local function rx_merge()
if #rx_parts == 0 then return end
local has_line = false
for i = 1, #rx_parts do
if rx_parts[i]:find("\n", 1, true) then has_line = true break end
end
if not has_line then return true end







local joined
if #rx_parts == 1 then
joined = rx_parts[1]
else
local ok, s = pcall(table.concat, rx_parts)
if not ok or type(s) ~= "string" then
local bytes = rx_len
rx_parts, rx_len = {}, 0
return false, why_and_pool(s) .. ", drop " .. bytes .. "B"
end
joined = s
end
rx_parts, rx_len = {}, 0

if rx_buf == "" then
rx_buf = joined
return true
end
local ok2, nb = pcall(cat2, rx_buf, joined)
if not ok2 or type(nb) ~= "string" then


return false, why_and_pool(nb) .. ", drop " .. #joined .. "B"
end
rx_buf = nb
return true
end








local function take_line_raw()
local nl = rx_buf:find("\n", 1, true)
if not nl then return nil end
local end_pos = nl - 1

if end_pos > 0 and rx_buf:byte(end_pos) == 13 then end_pos = end_pos - 1 end
local line = rx_buf:sub(1, end_pos)
rx_buf = rx_buf:sub(nl + 1)
return trim(line)
end



local function take_line()
local ok, line = pcall(take_line_raw)
if not ok then return false, nil, why_and_pool(line) end
return line ~= nil, line, nil
end




local take_fail = 0

function M.poll()
local n = 0
while n < 8 do



local okr, why = rx_merge()
if not okr then rx_lost = why end
local has, line, wfail = take_line()
if wfail then
take_fail = take_fail + 1
if take_fail == 1 then
log.error("prov", "line take fail:", wfail)
pcall(collectgarbage, "collect")
break
end


local bytes = #rx_buf
rx_buf, rx_parts, rx_len = "", {}, 0
local note = "take fail x" .. take_fail .. ", drop " .. bytes .. "B (" .. wfail .. ")"
rx_lost = rx_lost and (rx_lost .. " + " .. note) or note
break
end
take_fail = 0
if not has then break end
if #line > 0 then




local pok, perr = pcall(dispatch, line)
if not pok then
log.error("prov", "cmd crashed:", line:sub(1, 40), tostring(perr))
pcall(reply, "RET:FAIL:internal error")
end
n = n + 1
end
end



if rx_lost then
log.error("prov", "rx lost:", rx_lost)
pcall(reply, "RET:FAIL:rx 丢弃, 请重发")
rx_lost = nil
end
return n
end



local function rx_push(data)
rx_parts[#rx_parts + 1] = data
rx_len = rx_len + #data
if rx_len + #rx_buf > MAX_BUF then




rx_lost = "oversize, drop " .. (rx_len + #rx_buf) .. "B > " .. MAX_BUF
rx_parts, rx_len, rx_buf = {}, 0, ""
end
end



function M._rx_feed(s) rx_push(s) end

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
rx_push(data)
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








local ok, err = pcall(M.poll)
if ok then
loop_crashes = 0
else
loop_crashes = loop_crashes + 1
if loop_crashes <= 2 or loop_crashes % 250 == 0 then
pcall(log.error, "prov", "poll crashed x" .. loop_crashes .. ":", tostring(err))
end
end
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
