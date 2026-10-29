-- test_infer_mem.lua —— 推断地址的【常驻内存】账 (2026-10-29, 12-fix-9)
--
-- 背景: 现场 (2026-10-29 09:14~09:19, SN VL20261019001) 64 个地址就把
--   300KB 的 Lua 池吃到 95.8% → "alloc 8147 failed" → json encode out of
--   memory → RET:INFER={} → "E/uart system is out of memory!!!" → 整机卡死。
--   堆是碎片化的, 但碎片化之前得先问: 每多一个地址, 常驻堆到底涨多少?
--
-- 本测试量【每个地址的常驻增量】= 累加器行 + dtype 判型历史 + 数据点
--   (现场 64 个地址 → 池 290KB, 约 770 B/地址)。
--
-- 12-fix-9 动过的三处(PC 模拟器实测, 同一份量法):
--   旧 13304dc: 64 个地址 42.63 KB = 682 B/地址
--   新 12-fix-9: 64 个地址 34.69 KB = 555 B/地址  (-127 B/地址, -18.6%)
--     ① 腾挪1: dtypeHistory 从"5 个字符串的表"改成"打包成一个数"  ≈ -96 B
--     ② 腾挪2: 数据点不再存 hex(那一行挂着整帧的十六进制串)      ≈ -31 B
--     ③ B3:    attach_names 不再复制行 —— 不涨常驻, 但省瞬时垃圾
--   (B3 的真正价值在瞬时: 一次 R:INFER 少造 ~50KB 短命垃圾,
--    现场就是被这种垃圾把 300KB 的堆打碎的)
--   现场还量到 770 B/地址(含帧环/lastReqs 等别的开销), 口径比这里宽。
--
-- 跑法(仓库根目录):  tools\run_lua_tests.bat test_infer_mem.lua

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

local mon = require "bus/mon"
local collector = require "data/collector"

local N = 64          -- 现场就是 64 个地址
local PER_LIMIT = 600 -- 每地址常驻上限(字节) —— 12-fix-9 之后的目标

-- 干净起点
mon.test_reset_acc()
if collector.clear_data then collector.clear_data() end
collectgarbage("collect")
collectgarbage("collect")
local kb0 = collectgarbage("count")

for i = 0, N - 1 do
  local addr = i * 10
  -- ① 累加器行: 请求 + 应答
  mon.test_note_req(1, addr, 1, 3)
  mon.test_note_rsp(1, addr, i, 'uint16', 100)
  -- ② dtype 判型历史: 走 pushHistory(单测钩子)。现场每帧每个地址都推一次,
  --    推满 5 帧就是"这个地址最近 5 帧都是这个类型"
  for _ = 1, 5 do mon.test_push_history('reg' .. addr, 'uint16') end
  -- ③ 数据点: hex 每个地址都不一样(现场每帧的 hex 都不同)
  local hex = string.format('02 03 02 %02X %02X', i, i + 1)
  collector.push_data(addr, 'reg' .. addr, hex, i, 1700000000 + i, 'uint16', 100, 'ok')
end

collectgarbage("collect")
collectgarbage("collect")
local kb1 = collectgarbage("count")
local used_kb = kb1 - kb0
local per = used_kb * 1024 / N
print(string.format('  %d 个地址的常驻增量 %.2f KB (每地址 %.0f 字节)', N, used_kb, per))

-- ① 行的数量
local inf = mon.infer(true)
eq(#inf.regs, N, N .. ' 个地址都在累加器里')

-- ② 红线: 每地址的常驻增量不能超 PER_LIMIT
--   (旧实现 682 B/地址 → 128 个地址就 85KB; 12-fix-9 之后 555 B/地址,
--    同样的地址数省 16KB —— 堆只有 300KB, 这 16KB 是实打实的余量)
ok(per <= PER_LIMIT, string.format('每地址常驻 %.0f 字节 ≤ %d', per, PER_LIMIT))

-- ③ 腾挪2 生效: 数据点里不再有 hex 字段
local snap = collector.snapshot()
eq(#snap, N, '快照里有 ' .. N .. ' 个数据点')
local has_hex = false
for _, s in ipairs(snap) do
  if s.hex ~= nil then has_hex = true end
end
eq(has_hex, false, '数据点不再存 hex (12-fix-9 腾挪2)')

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print(string.format('PASS: 推断地址常驻内存 —— %d 个地址 %.2f KB (每地址 %.0f 字节 ≤ %d)',
  N, used_kb, per, PER_LIMIT))
