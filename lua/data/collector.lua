local cfg = require "core/config"

local M = {}

local dataCache = {}
local frames = {}
local framePool = {}   -- 12-fix-5: 复用的帧表(见 take_frame)
local ring, ringIdx = {}, 0
local updateCbs = {}
local stat = { pushed = 0, frames = 0, raw = 0 }
-- dataCache 必须封顶, 且只能封在这里: poll 档靠配置的寄存器数天然有界
-- (MAX_REGS), sniff 档旁听的地址集却不可预知 -- 主站读到哪就从机吐到哪,
-- 几百个不同地址就能吃穿 203K 的 Lua 堆。而 OOM 兜底 trim_cache() 只清
-- frames/ring, 碰不到 dataCache, 等它涨高再救就晚了。超限按插入序淘汰最旧
local MAX_DATA_POINTS = cfg.MAX_REGS
local dataOrder = {}

-- ⚠️ 12-fix-7 (2026-10-28): "reg<addr>" 这个 alias 串【缓存】下来。
--   原来 mon.push_rsp_value / pickDtype 每帧每槽都现拼一次 "reg" .. (addr+i)
--   (现场 52 帧/秒 × 10 槽 = 520 次/秒)。
--   ⚠️ 实测结论(别再拿"省内存"当理由): 短串拼接【不分配堆】——
--   Lua 的 luaV_concat 对 ≤256 字节的结果走栈缓冲, 再 intern 进短串表。
--   所以这一项的 churn 本来就是 0 (tests/lua/test_churn.lua 实测
--   pick_dtype 改前 29.5 字节/次、改后 29.9 字节/次, 纹丝不动)。
--   缓存的真实收益是省掉每次的 intern 查表(CPU 级, 很小),
--   保留它是为了"一个地址一个串对象"这条约定(dataCache 的 key 与
--   推断表/上报里的 alias 指向同一个串), 代价 = 一张小表。
local aliasCache = {}
local aliasCacheN = 0
local ALIAS_CACHE_MAX = 256

-- 返回该地址的规范 alias("reg<addr>")。**返回的是缓存里的同一个串对象**,
--   调用方可以放心留着它(不要再改 —— 字符串不可变 ✓)。
function M.alias_of(addr)
    local a = aliasCache[addr]
    if not a then
        a = "reg" .. tostring(addr)
        -- 地址空间有 65536 个, 缓存必须有上限(异常总线能刷出上万个地址)
        if aliasCacheN >= ALIAS_CACHE_MAX then
            aliasCache = {}
            aliasCacheN = 0
        end
        aliasCache[addr] = a
        aliasCacheN = aliasCacheN + 1
    end
    return a
end

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
-- ⚠️ 12-fix-5 (2026-10-28): 连【开发版】也不写了, 改成显式打开。
--   12-fix-4 当时留的"开发版就写"有个坑: 现场排障用的就是开发版, 于是
--   push_data 80 次/秒 + push_frame 48 次/秒 + push_raw_rx 48 次/秒
--   = 176 个 string.format/秒 ≈ 8KB/秒的垃圾, 而 M.get_ring() 至今
--   【没有任何调用者】—— 写进去的东西根本没人看。300KB 的堆, 8KB/秒
--   相当于每 40 秒把堆刷一遍, 碎片化就是这么来的。
--   现在默认全关; 现场真要环形调试缓冲, 用 W:RING=1 打开, R:RING 打印。
--
--   ⚠️ 拼接必须写在 if 里面 —— Lua 的实参是先求值再调用的,
--      写成 ring_add_dbg(string.format(...)) 的话 format 照样每次都跑。
local RING_ON = false

-- 开关(W:RING=1/0 用)。true = 开始记录, false = 停
function M.ring_enable(v)
    RING_ON = v and true or false
    return RING_ON
end

local function fire(cbs, ...)
    for _, cb in ipairs(cbs) do
        pcall(cb, ...)
    end
end

-- ⚠️ 12-fix-5 (2026-10-28): 老 key 就【原地改字段】, 不再每次新建一张表。
--   原来每次 push_data 都 new 一张 7 字段表 (56 + 7*16 = 168 字节 + 表头),
--   实测 192 字节/次 (tests/lua/test_churn.lua)。现场 sniff 80 点/秒
--   = 15KB/秒的垃圾, 是碎片化的第二大来源。
--   原地改安全: 全项目没有任何地方跨帧持有这张表的引用 ——
--   iot.build_items 每次现取现读 (iot.lua:269), mon.infer 同理 (mon.lua:482),
--   collector.snapshot() 另建新表。
-- ⚠️ 12-fix-9 (2026-10-29): 【不再存 hex】。
--   hex 参数还留着(调用点不用改), 但不再挂到数据点上 —— 那一行挂着的是
--   【整帧的十六进制串】, 每个地址各留一份引用, 现场 64 个地址就是 64 个
--   不同的帧串常驻(每个 ~56 字节, 合计 ~3.6KB; 128 个地址 ~7.2KB)。
--   而它只有一个读者: collector.snapshot() 的 R:VAL(前端只用 name/addr/
--   value, 不用 hex —— 报文卡那儿的 hex 更全)。总线报文卡里本来就有 hex。
--   现场 300KB 的堆现在每一 KB 都要算: 64 个地址已经占 290KB(95.8%)。
function M.push_data(addr, alias, hex, value, ts, dtype, conf, status)
    if value == nil then return false end
    if not alias or alias == "" then alias = "r" .. addr end
    if not ts then ts = os.time() end
    -- 新 key 才记账, 老 key 更新值不挪位; 超限就把最旧的连记账一起丢
    local d = dataCache[alias]
    if d == nil then
        dataOrder[#dataOrder + 1] = alias
        while #dataOrder > MAX_DATA_POINTS do
            dataCache[table.remove(dataOrder, 1)] = nil
        end
        d = {
            addr = addr, value = value, ts = ts,
            dtype = dtype, conf = conf, status = status,
        }
        dataCache[alias] = d
    else
        d.addr = addr
        d.value = value
        d.ts = ts
        d.dtype = dtype
        d.conf = conf
        d.status = status
    end
    stat.pushed = stat.pushed + 1
    -- ⚠️ 12-fix-4: 原来这里每次都 string.format 一条再丢进 ring(80 次/秒),
    --   而 ring 没有任何读者。现在调试期才拼(见 RING_ON 上面的说明)。
    if RING_ON then ring_add(string.format("data %s=%s", alias, tostring(value))) end
    fire(updateCbs, alias, value, ts, addr)
    return true
end

-- ⚠️ 12-fix-5 (2026-10-28): 帧表【复用】, 不再每帧新建一张。
--   帧表有十几个字段(slave/fc/kind/addr/qty/bc/hex/vhex/pair_*...),
--   一张就是 288 字节 + 哈希段从 4 扩到 16 的三次扩容(合计 ~450 字节)。
--   现场 48 帧/秒 → 光这一项 21KB/秒的垃圾, 是碎片化的头号来源。
--   现在: push_frame 把【最旧那张】回收进池子, 下次解码直接拿来填 ——
--   字段集合稳定 → 哈希段不再扩容 → 分配降到 0。
--   ⚠️ 复用安全吗: 帧表只被【同步】读, 没有谁跨帧持有引用 ——
--      R:FRAMES 是在命令处理函数里当场编码(不 yield), mon.infer 也是
--      当场读当场算。回收发生在【10 帧之后】, 那时早就读完了。
function M.take_frame()
    local t = framePool[#framePool]
    if t then
        framePool[#framePool] = nil
        -- 清空(留哈希段大小, 这样下次填字段不会再扩容)
        for k in pairs(t) do t[k] = nil end
        return t
    end
    return {}
end

function M.push_frame(f)
    stat.frames = stat.frames + 1
    while #frames >= cfg.FRAME_CACHE do
        -- 最旧的帧表回收进池子(不是丢掉): 见 take_frame 上面的说明
        local old = table.remove(frames, 1)
        framePool[#framePool + 1] = old
    end
    frames[#frames + 1] = f
    -- 落盘 schema 与原工程保持一致: {ts, kind, slave, fc, mkind, addr, qty, hex}
    -- (mkind = 原工程的 kind 字段, 用于区分 req/rsp/echo/err)
    local tag = f.kind == "req" and "REQ" or (f.kind == "rsp" and "RSP" or (f.kind == "err" and "ERR" or "FRM"))
    if RING_ON then
        ring_add(string.format("%s slave=%s fc=%s addr=%s", tag, tostring(f.slave), tostring(f.fc), tostring(f.addr or 0)))
    end
end

function M.push_raw_rx(hex)
    stat.raw = stat.raw + 1
    -- ring 默认不写(见 RING_ON 上面的说明): hex dump 纯开发调试
    if RING_ON then ring_add("rx " .. hex) end
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
        -- 12-fix-9: 不再带 hex(数据点上不存了, 见 push_data 的说明)
        out[#out + 1] = { name = alias, addr = d.addr, value = d.value, ts = d.ts, dtype = d.dtype }
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
