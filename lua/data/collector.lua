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
    -- 落盘字段用 name(与原工程一致), 同时保留 alias 供 store 的 eps 过滤查询
    fire(storeCbs, { name = alias, alias = alias, addr = addr, hex = hex, value = value, ts = ts, dtype = dtype, eps = eps })
    return true
end

function M.push_frame(f)
    stat.frames = stat.frames + 1
    frames[#frames + 1] = f
    while #frames > cfg.FRAME_CACHE do table.remove(frames, 1) end
    -- 落盘 schema 与原工程保持一致: {ts, kind, slave, fc, mkind, addr, qty, hex}
    -- (mkind = 原工程的 kind 字段, 用于区分 req/rsp/echo/err)
    fire(storeCbs, {
        ts = os.time(),
        kind = "frame",
        slave = f.slave,
        fc = f.fc,
        mkind = f.kind,
        addr = f.addr,
        qty = f.qty,
        hex = f.hex,
    })
    local tag = f.kind == "req" and "REQ" or (f.kind == "rsp" and "RSP" or (f.kind == "err" and "ERR" or "FRM"))
    ring_add(string.format("%s slave=%s fc=%s addr=%s", tag, tostring(f.slave), tostring(f.fc), tostring(f.addr or 0)))
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
