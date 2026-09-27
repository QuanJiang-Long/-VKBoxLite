local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local M = {}

local dataCache = {}
local frames = {}
local ring, ringIdx = {}, 0
local updateCbs, storeCbs = {}, {}
local stat = { pushed = 0, frames = 0, raw = 0 }

local function ring_add(s)
    ringIdx = (ringIdx % cfg.RING_SIZE) + 1
    ring[ringIdx] = s
end

local function fire(cbs, ...)
    for _, cb in ipairs(cbs) do
        pcall(cb, ...)
    end
end

function M.push_data(addr, alias, hex, value, ts, dtype, eps)
    if value == nil then return false end
    if not alias or alias == "" then alias = "r" .. addr end
    if not ts then ts = os.time() end
    dataCache[alias] = { addr = addr, hex = hex, value = value, ts = ts, dtype = dtype, eps = eps }
    stat.pushed = stat.pushed + 1
    ring_add(string.format("data %s=%s", alias, tostring(value)))
    fire(updateCbs, alias, value, ts, addr)
    fire(storeCbs, { alias = alias, addr = addr, hex = hex, value = value, ts = ts, dtype = dtype, eps = eps })
    return true
end

function M.push_frame(f)
    stat.frames = stat.frames + 1
    frames[#frames + 1] = f
    while #frames > cfg.FRAME_CACHE do table.remove(frames, 1) end
    ring_add(string.format("frame %s fc=%s", tostring(f.kind), tostring(f.fc)))
    fire(storeCbs, {
        kind = "frame",
        alias = f.slave and ("s" .. f.slave) or "?",
        addr = f.addr or 0,
        hex = f.hex,
        value = f.value,
        ts = os.time(),
        fc = f.fc,
    })
end

function M.push_raw_rx(hex)
    stat.raw = stat.raw + 1
    ring_add("rx " .. hex)
end

function M.get_all_latest()
    return dataCache
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
    for _, d in pairs(dataCache) do out[#out + 1] = { name = d.name, addr = d.addr, value = d.value, hex = d.hex, ts = d.ts, dtype = d.dtype } end
    for alias, d in pairs(dataCache) do
        out[#out + 1] = { name = alias, addr = d.addr, value = d.value, hex = d.hex, ts = d.ts, dtype = d.dtype }
    end
    table.sort(out, function(a, b) return (a.addr or 0) < (b.addr or 0) end)
    return out
end

function M.on_update(cb) updateCbs[#updateCbs + 1] = cb end
function M.on_store(cb) storeCbs[#storeCbs + 1] = cb end

function M.clear()
    dataCache, frames, ring, ringIdx = {}, {}, {}, 0
    stat = { pushed = 0, frames = 0, raw = 0 }
end

function M.trim_cache()
    local n = #frames + #ring
    frames, ring, ringIdx = {}, {}, 0
    return n
end

return M
