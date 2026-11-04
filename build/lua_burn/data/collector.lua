local cfg = require "core/config"

local M = {}

local dataCache = {}
local frames = {}
local framePool = {}   -- 12-fix-5: 复用的帧表(见 take_frame)
local ring, ringIdx = {}, 0
local updateCbs = {}
local stat = { pushed = 0, frames = 0, raw = 0 }




local MAX_DATA_POINTS = cfg.MAX_REGS
local dataOrder = {}














function M.alias_of(addr)
    return "reg" .. tostring(addr)
end

local function ring_add(s)
    ringIdx = (ringIdx % cfg.RING_SIZE) + 1
    ring[ringIdx] = s
end



















local RING_ON = false


function M.ring_enable(v)
    RING_ON = v and true or false
    return RING_ON
end

local function fire(cbs, ...)
    for _, cb in ipairs(cbs) do
        pcall(cb, ...)
    end
end
























function M.push_data(addr, alias, hex, value, ts, dtype, conf, status)
    if value == nil then return false end
    if not alias or alias == "" then alias = "r" .. addr end
    if not ts then ts = os.time() end

    local d = dataCache[alias]
    if d == nil then
        dataOrder[#dataOrder + 1] = alias
        while #dataOrder > MAX_DATA_POINTS do
            dataCache[table.remove(dataOrder, 1)] = nil
        end
        d = {
            addr = addr, value = value, ts = ts,
            dtype = dtype,
        }
        dataCache[alias] = d
    else
        d.addr = addr
        d.value = value
        d.ts = ts
        d.dtype = dtype
    end
    stat.pushed = stat.pushed + 1


    if RING_ON then ring_add(string.format("data %s=%s", alias, tostring(value))) end
    fire(updateCbs, alias, value, ts, addr)
    return true
end










function M.take_frame()
    local t = framePool[#framePool]
    if t then
        framePool[#framePool] = nil

        for k in pairs(t) do t[k] = nil end
        return t
    end
    return {}
end

function M.push_frame(f)
    stat.frames = stat.frames + 1
    while #frames >= cfg.FRAME_CACHE do

        local old = table.remove(frames, 1)
        framePool[#framePool + 1] = old
    end
    frames[#frames + 1] = f


    local tag = f.kind == "req" and "REQ" or (f.kind == "rsp" and "RSP" or (f.kind == "err" and "ERR" or "FRM"))
    if RING_ON then
        ring_add(string.format("%s slave=%s fc=%s addr=%s", tag, tostring(f.slave), tostring(f.fc), tostring(f.addr or 0)))
    end
end

function M.push_raw_rx(hex)
    stat.raw = stat.raw + 1

    if RING_ON then ring_add("rx " .. hex) end
end

function M.get_all_latest()
    return dataCache
end



function M.get_ring()
    local out = {}
    local n = math.min(ringIdx, cfg.RING_SIZE)
    for i = 1, n do
        local idx = ((ringIdx - i) % cfg.RING_SIZE) + 1
        out[#out + 1] = ring[idx]
    end
    return out
end

function M.get_frames()
    return frames
end

function M.stats()
    return {
        pushed = stat.pushed,
        frames = stat.frames,
        raw = stat.raw,
        points = (function()
            local n = 0
            for _ in pairs(dataCache) do n = n + 1 end
            return n
        end)(),
    }
end

function M.snapshot()
    local out = {}
    for alias, d in pairs(dataCache) do

        out[#out + 1] = { name = alias, addr = d.addr, value = d.value, ts = d.ts, dtype = d.dtype }
    end
    table.sort(out, function(a, b) return (a.addr or 0) < (b.addr or 0) end)
    return out
end

function M.on_update(cb) updateCbs[#updateCbs + 1] = cb end

function M.trim_cache()
    local n = #frames + #ring
    frames, ring, ringIdx = {}, {}, 0


    dataOrder = {}
    return n
end



function M.clear_all()
    local n = #dataCache + #frames
    dataCache = {}
    dataOrder = {}
    frames = {}
    ring, ringIdx = {}, 0
    stat.pushed, stat.frames = 0, 0
    return n
end

return M
