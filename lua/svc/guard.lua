local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local sys = corelib.get("sys")
local rtos = corelib.try("rtos")
local wdt = corelib.try("wdt")

local M = {}

local ticks, last_alive = 0, 0

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

local function monitor()
    local mode = cur_mode()
    local stall = mode == "poll" and (ticks - last_alive) or nil
    local parts = {
        string.format("uptime=%ds feed=%d", ticks, cfg.WDT_FEED_MS // 1000),
    }
    if stall then parts[#parts + 1] = string.format("stall=%ds", stall) end
    local ok, store = pcall(require, "data/store")
    if ok and store then
        local st = store.stats()
        parts[#parts + 1] = string.format("queue=%d pushed=%d saved=%d dropped=%d failed=%d",
            store.depth(), st.pushed or 0, st.saved or 0, st.dropped or 0, st.failed or 0)
    end
    if rtos then
        local total, used = rtos.meminfo("sys")
        if type(used) == "number" then
            parts[#parts + 1] = string.format("mem=%d/%d", used, total or 0)
        end
    end
    print("[guard] " .. table.concat(parts, " "))
    if stall and stall > cfg.STALL_LIMIT_S then
        log.error("guard", "collector stalled!")
        if cfg.AUTO_REBOOT and rtos and rtos.reboot then pcall(rtos.reboot) end
    end
end

function M.status()
    return {
        uptime = ticks,
        feed = cfg.WDT_FEED_MS,
        stall = cur_mode() == "poll" and (ticks - last_alive) or nil,
        wdt_to = cfg.WDT_TIMEOUT,
    }
end

function M.init()
    if wdt_ok() then
        local ok = false
        if type(wdt.init) == "function" then
            ok = pcall(wdt.init, cfg.WDT_TIMEOUT)
        end
        if ok then
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
