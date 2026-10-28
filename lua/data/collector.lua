local cfg = require "core/config"

local M = {}

local dataCache = {}
local frames = {}
local ring, ringIdx = {}, 0
local updateCbs = {}
local stat = { pushed = 0, frames = 0, raw = 0 }
-- dataCache 必须封顶, 且只能封在这里: poll 档靠配置的寄存器数天然有界
-- (MAX_REGS), sniff 档旁听的地址集却不可预知 -- 主站读到哪就从机吐到哪,
-- 几百个不同地址就能吃穿 203K 的 Lua 堆。而 OOM 兜底 trim_cache() 只清
-- frames/ring, 碰不到 dataCache, 等它涨高再救就晚了。超限按插入序淘汰最旧
local MAX_DATA_POINTS = cfg.MAX_REGS
local dataOrder = {}

local function ring_add(s)
    ringIdx = (ringIdx % cfg.RING_SIZE) + 1
    ring[ringIdx] = s
end

-- ⚠️ 12-fix-4 (2026-10-28): ring 改成"调试期才写"。
--   现场实测(多寄存器设备, 279 秒): push_data 被调 22375 次 = 80 次/秒,
--   每次都 string.format 一条 "data reg123=456" 再丢进 ring; push_frame
--   另有 ~43 次/秒。也就是每秒白造 ~120 个字符串。
--   而 ring 只留 RING_SIZE(24) 条、且【全项目没有任何一处读它】——
--   白造白扔, 而这正是热路径上最大的一笔碎片来源。
--   现在: 发布版(非 DEBUG)不写 ring; 调试期要看用新增的 M.get_ring()。
--
--   ⚠️ 拼接必须写在 if 里面 —— Lua 的实参是先求值再调用的,
--      写成 ring_add_dbg(string.format(...)) 的话 format 照样每次都跑。
local RING_ON = (_G.DEBUG and true) or false

local function fire(cbs, ...)
    for _, cb in ipairs(cbs) do
        pcall(cb, ...)
    end
end

function M.push_data(addr, alias, hex, value, ts, dtype, conf, status)
    if value == nil then return false end
    if not alias or alias == "" then alias = "r" .. addr end
    if not ts then ts = os.time() end
    -- 新 key 才记账, 老 key 更新值不挪位; 超限就把最旧的连记账一起丢
    if not dataCache[alias] then
        dataOrder[#dataOrder + 1] = alias
        while #dataOrder > MAX_DATA_POINTS do
            dataCache[table.remove(dataOrder, 1)] = nil
        end
    end
    dataCache[alias] = {
        addr = addr, hex = hex, value = value, ts = ts,
        dtype = dtype, conf = conf, status = status,
    }
    stat.pushed = stat.pushed + 1
    -- ⚠️ 12-fix-4: 原来这里每次都 string.format 一条再丢进 ring(80 次/秒),
    --   而 ring 没有任何读者。现在调试期才拼(见 RING_ON 上面的说明)。
    if RING_ON then ring_add(string.format("data %s=%s", alias, tostring(value))) end
    fire(updateCbs, alias, value, ts, addr)
    return true
end

function M.push_frame(f)
    stat.frames = stat.frames + 1
    frames[#frames + 1] = f
    while #frames > cfg.FRAME_CACHE do table.remove(frames, 1) end
    -- 落盘 schema 与原工程保持一致: {ts, kind, slave, fc, mkind, addr, qty, hex}
    -- (mkind = 原工程的 kind 字段, 用于区分 req/rsp/echo/err)
    local tag = f.kind == "req" and "REQ" or (f.kind == "rsp" and "RSP" or (f.kind == "err" and "ERR" or "FRM"))
    if RING_ON then
        ring_add(string.format("%s slave=%s fc=%s addr=%s", tag, tostring(f.slave), tostring(f.fc), tostring(f.addr or 0)))
    end
end

function M.push_raw_rx(hex)
    stat.raw = stat.raw + 1
    -- 发布版不写 ring: hex dump 纯开发调试, B 类指令 R:FRAMES 已禁用
    if not _G.BUILD_RELEASE then ring_add("rx " .. hex) end
end

function M.get_all_latest()
    return dataCache
end

-- 12-fix-4: ring 的读者(原来没有)。ring 只在调试期写(见 RING_ON),
--   所以发布版这里返回空表。
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
        out[#out + 1] = { name = alias, addr = d.addr, value = d.value, hex = d.hex, ts = d.ts, dtype = d.dtype }
    end
    table.sort(out, function(a, b) return (a.addr or 0) < (b.addr or 0) end)
    return out
end

function M.on_update(cb) updateCbs[#updateCbs + 1] = cb end

function M.trim_cache()
    local n = #frames + #ring
    frames, ring, ringIdx = {}, {}, 0
    -- dataOrder 是 dataCache 的记账表, 必须跟着一起清, 否则两边不同步,
    -- 下次 push_data 的淘汰会拿着一个不存在 dataCache 里的 key 白删
    dataOrder = {}
    return n
end

-- 全量清缓存: dataCache(值/dtype/conf) + 记账表 + frames + ring。
-- sniff 换参数/重新识别时用: 旧参数下的值/dtype/帧都不能留(会污染新推断)
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
