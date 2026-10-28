-- test_churn.lua —— 量"嗅探热路径每处理一帧到底造多少字节垃圾"
--
-- 为什么需要 (2026-10-28 现场崩溃复盘):
--   设备在 300KB 的 Lua 堆里跑 sniff, 现场两次崩在
--   mon.pick_dtype -> mbus.parse_value, 崩前 E/mem 报
--   "used 282488, alloc 3471 失败" —— 堆还有 24KB 空闲却切不出 3.4KB
--   连续块 = 碎片化。而碎片是【垃圾 churn】的直接后果: 每秒几十 KB 的
--   短命小对象把空闲区打成碎洞, 大请求就没地方落。
--
--   怎么量准 (踩过的坑):
--     Lua 5.3 的 collectgarbage("stop") 只关【紧急回收】, 增量 GC 照跑!
--     所以"跑 N 次看 count 增量"量到的是【净增长】(GC 跟得上就是 0),
--     不是真实分配量。必须让 N 次的分配量【低于 GC 的启动阈值】
--     (≈ 活对象 × 1.9), 期间 GC 一次都不会启动, 增量才是真实分配量。
--     N=50 × 1KB = 50KB, 远低于阈值。分辨率 = 0.1KB/50 = 2 字节/次。
--   校准: (ctl)new table 必须报 ~56 字节, (ctl)noop 必须报 ~0, 否则量法坏了。
--
--   跑法: tools\run_lua_tests.bat test_churn.lua
--   判据: 每项的 "字节/次" 不得超过上限, 超了 os.exit(1)。
--   上限是【回归红线】, 不是性能目标: 现场 48 帧/秒, 每帧 1.2KB 就是
--   58KB/s 的 churn, 300KB 的堆几分钟就碎。

local mbus = require "bus/mbus"
local mon = require "bus/mon"
local collector = require "data/collector"

-- 每项的上限(字节/次)。改动热路径后如果超了, 说明又造垃圾了。
local LIMITS = {
    pick_dtype = 60,        -- 一个 16bit 槽位的判型 (改前 632)
    decode_frame = 500,     -- 解一帧(新建表; 现场已不走这条, poll 走 parse_frame)
    decode_frame_reuse = 230,-- 解一帧(复用表, 现场真正走的路; 改前 450×2)
    push_data = 20,         -- 存一个点 (改前 192)
    alias_of = 1,           -- 取规范 alias(12-fix-7: 缓存命中 → 0 字节)
}

local N = 50

-- 分配量测量: 一次 collect 复位 -> 跑 N 次(不触发 GC 周期) -> 量增量
local function measure(name, fn)
    collectgarbage("collect")
    collectgarbage("collect")
    local c0 = collectgarbage("count")
    for _ = 1, N do fn() end
    local c1 = collectgarbage("count")
    collectgarbage("collect")
    local per = (c1 - c0) * 1024 / N
    print(string.format("%-22s %8.1f 字节/次", name, per))
    return per
end

-- 造一帧真实形状的 fc3 响应: slave=1 fc=3 bc=20 (10 个寄存器) + crc
local payload = ""
for i = 1, 20 do payload = payload .. string.char((i * 7) % 256) end
local rsp = string.char(1, 3, 20) .. payload
rsp = mbus.append_crc(rsp)
-- 造一帧读请求: slave=1 fc=3 addr=0 qty=10
local req = mbus.append_crc(string.char(1, 3, 0, 0, 0, 10))

print("== 校准 (量法对不对就看这两行) ==")
local ctl_noop = measure("(ctl)noop", function() end)
local ctl_tab = measure("(ctl)new table", function() local t = {} end)
if ctl_noop > 20 then
    print(string.format("FAIL: noop 都量到 %.1f 字节, 量法不对(GC 没停干净?)", ctl_noop))
    os.exit(1)
end
if ctl_tab < 20 or ctl_tab > 200 then
    print(string.format("FAIL: new table 量到 %.1f 字节, 量法不对", ctl_tab))
    os.exit(1)
end
print(string.format("   量法 OK: noop=%.1f, 空表=%.1f", ctl_noop, ctl_tab))

print("")
print("== 嗅探热路径分配量 ==")
local bad = 0
local function check(name, per, lim)
    local flag = "ok  "
    if per > lim then flag = "OVER"; bad = bad + 1 end
    print(string.format("%-22s %8.1f 字节/次   上限=%-4s %s", name, per, tostring(lim), flag))
end

-- ⚠️ 设备上 dtypeHistory[alias] 是【存在】的(push_rsp_value 每帧都调
--   pushHistory 建好了), 所以 calcContinuity/score 里的
--   "dtypeHistory[alias] or {}" 不会建空表。这里必须先 seed 一次,
--   否则量到的是"alias 不存在"这个假象, 比现场高一大截。
mon.seed_history("reg0", { "uint16" })

check("pick_dtype", measure("pick_dtype", function()
    mon.pick_dtype(payload, 0, 10, 0, 1, nil)
end), LIMITS.pick_dtype)

check("decode_frame", measure("decode_frame", function()
    mbus.decode_frame(rsp)
end), LIMITS.decode_frame)

-- 复用帧表的解帧路径(现场真正走的那条): 表从池子里拿, 不新建
check("decode_frame(复用)", measure("decode_frame(复用)", function()
    local t = collector.take_frame()
    mbus.decode_frame(rsp, t)
    collector.push_frame(t)
end), LIMITS.decode_frame_reuse)

check("push_data", measure("push_data", function()
    collector.push_data(1, "reg1", "aabb", 123, os.time(), "uint16", 90, "ok")
end), LIMITS.push_data)

-- ⚠️ 12-fix-7: alias 串走缓存。实测结论: 短串拼接【本来就不分配堆】
--   (Lua 的 luaV_concat 对 ≤256 字节的结果走栈缓冲), 所以这一项的
--   churn 改前改后都是 0 —— 缓存省的是 intern 查表(CPU 级)。
--   这里钉住"命中缓存时 0 字节", 免得以后有人把它改回现拼还自以为在省内存。
collector.alias_of(12345)      -- 先把 12345 建进缓存
check("alias_of", measure("alias_of(命中缓存)", function()
    collector.alias_of(12345)
end), LIMITS.alias_of)

-- decode_frame 的内部拆解: 想知道剩下的字节花在哪
local function hexold(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
measure("(sub)crc_ok", function() mbus.crc_ok(rsp) end)
measure("(sub)parse_frame", function() mbus.parse_frame(rsp) end)
measure("(sub)gsub+format hex", function() hexold(rsp) end)
measure("(sub)parse_frame req", function() mbus.parse_frame(req) end)

print("")
print(string.format("一帧响应(10 寄存器)总 churn ≈ %.0f 字节",
    (LIMITS.pick_dtype + LIMITS.decode_frame + LIMITS.push_data) * 10))

if bad > 0 then
    print(string.format("FAIL: %d 项超过上限", bad))
    os.exit(1)
end
print("PASS: 分配量在红线内")
