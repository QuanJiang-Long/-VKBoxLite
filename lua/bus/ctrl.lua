local corelib = require "core/corelib"
local log = corelib.log()
local sys = corelib.try("sys")

local poll = require "bus/poll"
local mon = require "bus/mon"

local M = {}

local SWITCH_DELAY_MS = 50

local function switch_delay()
    if not sys then return end
    local ok = pcall(sys.wait, SWITCH_DELAY_MS)
    if ok then return end
    pcall(sys.taskInit, function()
        pcall(sys.wait, SWITCH_DELAY_MS)
    end)
end

function M.switch_mode(mode)
    if mode == "poll" then
        if mon.is_running() then
            mon.stop()
            switch_delay()
        end
        if poll.is_running() then poll.stop() end
        if poll.start() then return true, "OK poll started" end
        return false, "FAIL poll start"

    elseif mode == "sniff" then
        if poll.is_running() then
            poll.stop()
            switch_delay()
        end
        if mon.is_running() then mon.stop() end
        if mon.start() then return true, "OK sniff started" end
        return false, "FAIL sniff start"

    elseif mode == "idle" or mode == "stop" then
        if poll.is_running() then poll.stop() end
        if mon.is_running() then mon.stop() end
        return true, "OK idle (bus released)"

    else
        return false, "FAIL unknown mode (use poll/sniff/idle)"
    end
end

function M.get_mode()
    if poll.is_running() then return "poll" end
    if mon.is_running() then return "sniff" end
    return "idle"
end

function M.is_busy()
    return poll.is_running() or mon.is_running()
end

function M.status()
    return {
        mode = M.get_mode(),
        busy = M.is_busy(),
        poll = poll.status(),
        mon = mon.status(),
        write = poll.write_status(),
    }
end

log.info("ctrl", "mode arbiter ready, default=idle")

return M
