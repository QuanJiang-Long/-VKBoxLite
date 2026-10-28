-- test_u4_split.lua —— U4 降级分包的单测 (2026-10-28, 12-fix-7)
--
-- 背景(现场, 2026-10-28 16:54, 上一版固件 e284035):
--   设备跑到 41 分钟, U4 主题突然不报了, sniff 业务没崩、没死机:
--
--   W/user.iot build_items failed, skip publish: iot.lua:302:
--       not enough memory for buffer allocation
--   W/user.iot topo_sig failed, skip this round: iot.lua:525:
--       not enough memory for buffer allocation
--   I/user.iot census lua=222.0KB points=77 ... pub=60/0 ... gc=1
--
-- 行号对得上代码: iot.lua:302 = table.concat(77 个点 ≈ 6KB),
--   iot.lua:525 = 拓扑 props 的 table.concat(≈1.2KB)。
--   ⚠️ 关键: 拓扑那条只要 1.2KB 也失败 —— 所以不是"包太大",
--   是 300KB 的池子被 churn 切碎了, 连 1.2KB 的连续块都切不出来。
--
-- 修法(本轮 A+B+C+D):
--   A 砍 churn: alias 串走缓存(每帧每槽少一次 concat)
--   B 整包分配失败时降级分包: 每块 25 个点(≈2KB), 同一 topic 分几条发
--   C 拼大包前按水位回收一次(>200KB 才回收)
--   D census 加 bfail= 计数 —— 之前 pub=60/0 完全看不出"上报已经瘸了"
--
-- 本测试钉住 B 的切法: 不丢点、不重复、顺序不变。
--
-- 跑法(仓库根目录):  tools\run_lua_tests.bat test_u4_split.lua

local fails = 0
local function eq(a, b, what)
  if a ~= b then
    print(string.format('FAIL: %s (期望 %s, 实际 %s)', what, tostring(b), tostring(a)))
    fails = fails + 1
  end
end
local function ok(c, what)
  if not c then
    print('FAIL: ' .. what)
    fails = fails + 1
  end
end

local iot = require "iot/iot"
local collector = require "data/collector"

local split = iot._test_split_points

-- 1) 现场那个规模: 77 个点按 25 一块
local pts = {}
for i = 1, 77 do pts[i] = 'p' .. i end
local parts = split(pts, 25)
eq(#parts, 4, '77 个点按 25 一块 → 4 块')
eq(#parts[1], 25, '第 1 块 25 个')
eq(#parts[2], 25, '第 2 块 25 个')
eq(#parts[3], 25, '第 3 块 25 个')
eq(#parts[4], 2, '最后一块 2 个')

-- 2) 不丢点、不重复、顺序不变(平台按 id 覆盖, 但顺序变了没法排查)
local all = {}
for _, p in ipairs(parts) do for _, v in ipairs(p) do all[#all + 1] = v end end
eq(#all, 77, '拆完点数不变')
local same = true
for i = 1, 77 do if all[i] ~= pts[i] then same = false break end end
ok(same, '拆完内容和顺序都不变')

-- 3) 边界
eq(#split({}, 25), 0, '空表 → 0 块')
eq(#split(pts, 1000), 1, '块比点多 → 1 块')
eq(#split(pts, 1), 77, '每块 1 个 → 77 块')
eq(#split(pts, 0), 77, '块大小 0 → 兜底成 1 个/块(不能死循环)')

-- 4) alias 缓存(12-fix-7 的 A): 内容对、同一地址拿到同一个串
eq(collector.alias_of(100), 'reg100', 'alias 串内容对')
eq(collector.alias_of(101), 'reg101', '不同地址是不同串')
eq(collector.alias_of(100), collector.alias_of(100), '同一地址拿到同一个串')
-- 缓存有上限: 地址空间 65536 个, 不能让它无限长
for i = 0, 400 do collector.alias_of(i) end
eq(collector.alias_of(0), 'reg0', '缓存上限触发后照样能用')

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print('PASS: U4 降级分包 —— 77 点切 4 块 / 不丢点不乱序 / 边界 / alias 缓存')
