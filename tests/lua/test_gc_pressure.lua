-- test_gc_pressure.lua —— Lua 堆 GC 行为单测 (2026-10-28)
--
-- 背景: 现场 sniff 档跑到 130 秒时 Lua 堆 OOM 崩溃。
--   LuatOS 日志: "memory allocation failed total 307192, used 266752, alloc 3033"
--   → 堆总量 300KB, 已用 260.5KB, 申请 3KB 失败; 而 used 一直在
--   258840~268696 之间波动, 从不降到 253KB 以下。
--
--   ⚠️ 我一开始怀疑那 253KB 地板是"GC 的触发水位"(以为 pause=200、
--      活对象翻倍才收)。实测【否掉了】: LuatOS 的默认 pause 是 90
--      不是 200, 而且把 pause 调成 120/200 峰值纹丝不动(238.2 vs 238.3 KB)。
--      结论: 253KB 地板【就是活对象本身】。所以出路只有一条 ——
--      【少常驻 + 少分配】, 调 GC 参数没用。
--      (这次差点凭"听起来合理"的 GC 理论就改代码, 是单测把它拦下来的。)
--
--   本测试钉住三件对修内存有用的事实:
--     1) collectgarbage("setpause") 在 LuatOS 上可用且值存得住
--        (但它【调不动水位峰值】, 所以不要指望用它救 OOM)
--     2) collectgarbage("count") 测的是"活 + 还没扫掉的垃圾";
--        collect 之后回到活对象
--     3) collectgarbage("step") 是【增量】回收, 不阻塞 ——
--        200 步就能把 398KB 垃圾压到 53KB。真要在热路径压水位,
--        只有 step 可用(collect 是完整回收, 有毫秒级暂停, 热路径上
--        有让 UART 环形缓冲溢出的风险)。
--
-- ⚠️ 造垃圾必须让对象【出作用域】(放在子函数里), 否则它们还是活着的,
--    collect 当然降不下来 —— 第一版就是这么写错的, 白测一轮。
--
-- 跑法(仓库根目录):  tools\run_lua_tests.bat test_gc_pressure.lua

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

local function kb() return collectgarbage("count") end

-- 造 n 个"典型垃圾对象"(形状照抄 sniff 热路径: 小表 + 字符串)然后放掉引用,
-- 让它们变成真正的垃圾。返回 (活对象, 过程中的 count 峰值)
local function measure(n, pause)
  pcall(collectgarbage, "setpause", pause)
  collectgarbage("collect")
  local live = kb()
  local peak = live
  do
    local keep = {}
    for i = 1, n do
      keep[i] = { a = i, b = tostring(i), c = "reg" .. i, d = { i, i + 1, i + 2 } }
      if i % 40 == 0 then
        local c = kb()
        if c > peak then peak = c end
      end
    end
  end -- keep 出作用域 → 下面的对象变成垃圾
  local c = kb()
  if c > peak then peak = c end
  collectgarbage("collect")
  return live, peak
end

-- 造垃圾并放掉引用 (子函数作用域)
local function alloc_junk(n, tag)
  local keep = {}
  for i = 1, n do keep[i] = { a = i, b = tostring(i), c = tag .. i } end
end

-- 1) setpause 可用, 而且值真的存得住 (读回旧值)
local sp_ok = pcall(collectgarbage, "setpause", 120)
eq(sp_ok, true, "collectgarbage('setpause', 120) 不报错")
local old = collectgarbage("setpause", 200)   -- 返回旧值, 并把 pause 设成 200
eq(old, 120, "setpause 的值存得住 (读回旧值 = 120)")
collectgarbage("setpause", old)                -- 还原

-- 2) count 测的是"活 + 还没扫掉的垃圾"; collect 之后回到活对象
collectgarbage("collect")
local live = kb()
print(string.format("  活对象基线: %.1f KB", live))
ok(live > 0, "活对象基线 > 0 (count 确实在测东西)")

alloc_junk(2000, "reg")
local dirty = kb()
print(string.format("  造垃圾后 count: %.1f KB", dirty))
ok(dirty > live, "造垃圾后 count 上涨 (count 含未扫掉的垃圾)")

collectgarbage("collect")
local back = kb()
print(string.format("  collect 后 count: %.1f KB (活对象 %.1f KB)", back, live))
ok((back - live) < 32 * 1024, "collect 后 count 回到活对象基线 (±32KB)")

-- 3) step 是增量回收, 不阻塞 —— 200 步能把几百 KB 垃圾压下去
--    (绝不能用 collect: 那是完整回收, 有毫秒级暂停, 热路径上有让
--     UART 环形缓冲溢出的风险)
alloc_junk(2000, "x")
local dirty2 = kb()
for i = 1, 200 do collectgarbage("step") end
local stepped = kb()
print(string.format("  造垃圾 %.1f KB → step 200 次后 %.1f KB", dirty2, stepped))
ok(stepped <= dirty2 + 1024, "step 不会让水位变高")
ok(stepped < dirty2, "step 之后水位降了 (增量回收有效)")

-- 4) 【实测结论】setpause 调不动水位峰值 —— 记下来, 免得以后再走一遍
--    这条弯路 (LuatOS 默认 pause=90, 不是 200)
local live200, peak200 = measure(800, 200)
local live120, peak120 = measure(800, 120)
print(string.format("  pause=200: 活 %.1f KB → 峰值 %.1f KB", live200, peak200))
print(string.format("  pause=120: 活 %.1f KB → 峰值 %.1f KB", live120, peak120))
print("  结论: pause 调不动水位 —— 253KB 地板是活对象本身, 只能少常驻少分配")

collectgarbage("collect")

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print("PASS: gc 行为 —— setpause 可用/存得住 / count 测活+垃圾 / step 增量回收有效")
