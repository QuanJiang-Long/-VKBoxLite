local util = require "util"
local cfg = require "core/config"
local log = util.log()

local sys = util.try("sys")  -- try 而非 get: 早于 sys 挂载也能加载 (单测可调)
local rtos = util.try("rtos")
local wdt = util.try("wdt")

local M = {}

local ticks, last_alive = 0, 0

local was_running, was_mode = false, ""

local function wdt_ok()
if not wdt then return false end
return type(wdt.feed) == "function"
end

function M.alive()
last_alive = ticks
end

local function feed_loop()
while true do
if wdt_ok() then pcall(wdt.feed) end
if sys then sys.wait(cfg.WDT_FEED_MS) end
end
end

local function tick_loop()
while true do
ticks = ticks + 1
if sys then sys.wait(1000) end
end
end

local function cur_mode()
local ok, ctrl = pcall(require, "bus/ctrl")
if ok and ctrl then return ctrl.get_mode() end
return "idle"
end




local function is_active_mode(mode)
return mode == "manual" or mode == "poll" or mode == "platform" or mode == "sniff"
end

M.is_active_mode = is_active_mode

















local function collector_running(mode)
local mod = (mode == "sniff") and "bus/mon" or "bus/poll"
local ok, m = pcall(require, mod)
if not ok or not m or type(m.is_running) ~= "function" then return false end
return m.is_running() and true or false
end








local function sync_running(mode)
local r = collector_running(mode)
if r and (not was_running or mode ~= was_mode) then last_alive = ticks end
was_running, was_mode = r, mode
return r
end


local function stall_of(mode)
if not is_active_mode(mode) then return nil end
if not sync_running(mode) then return nil end
return ticks - last_alive
end

M.stall_of = stall_of

















function M.sweep()
if not rtos then return false end
local ok, total, used = pcall(rtos.meminfo, "lua")
if not ok or type(total) ~= "number" or type(used) ~= "number" then return false end
if total - used > cfg.GC_FUSE_FREE then return false end
pcall(collectgarbage, "collect")
local ok2, t2, u2 = pcall(rtos.meminfo, "lua")
if ok2 and type(t2) == "number" and type(u2) == "number" then
log.warn("guard", string.format("lua 池剩 %d, 扫一轮 %d->%d 剩 %d",
total - used, used, u2, t2 - u2))
else
log.warn("guard", string.format("lua 池剩 %d, 扫一轮", total - used))
end
return true
end

local function monitor()
local mode = cur_mode()


M.sweep()


local is_manual = mode == "manual" or mode == "poll"
local stall = stall_of(mode)
local parts = {
string.format("uptime=%ds mode=%s feed=%d", ticks, mode, math.floor(cfg.WDT_FEED_MS / 1000)),
}
if stall then parts[#parts + 1] = string.format("stall=%ds", stall) end

if is_manual or mode == "platform" then
local okp, poll = pcall(require, "bus/poll")
if okp and poll then
local ps = poll.status()
parts[#parts + 1] = string.format("poll_round=%d ok=%d timeout=%d werr=%d",
ps.rounds or 0, ps.ok or 0, ps.timeout or 0, ps.werr or 0)
end
end
if rtos then
local total, used = rtos.meminfo("sys")
if type(used) == "number" then
parts[#parts + 1] = string.format("mem=%d/%d", used, total or 0)
end
end
log.info("guard", table.concat(parts, " "))
if stall and stall > cfg.STALL_LIMIT_S then
log.error("guard", "collector stalled!")
if cfg.AUTO_REBOOT and rtos and rtos.reboot then pcall(rtos.reboot) end
end
end

function M.status()
return {
uptime = ticks,
feed = cfg.WDT_FEED_MS,
stall = stall_of(cur_mode()),
wdt_to = cfg.WDT_TIMEOUT,
}
end

function M.init()
if wdt_ok() then
local pok, ret = false, nil
if type(wdt.init) == "function" then
pok, ret = pcall(wdt.init, cfg.WDT_TIMEOUT)
end
if pok and ret then
log.info("guard", "wdt init " .. cfg.WDT_TIMEOUT .. "ms")
else
log.info("guard", "wdt.init 无效(Air780EP 无软件看门狗, AON WDT 由固件托管), 仅 feed 有效")
end
else
log.warn("guard", "wdt unavailable")
end
if sys then
sys.taskInit(feed_loop)
sys.taskInit(tick_loop)
sys.timerLoopStart(monitor, cfg.MONITOR_MS)
end
log.info("guard", "ready")
return true
end

return M
