-- test_dtype_band.lua —— dtype 启发式"量级带"判据的锁定测试 (2026-10)
--
-- 背景: 现场 2054 (RSP 4 寄存器 436bb333 00000000) 实际是 float32
--   (≈235.8 / 0.0, 与 2048 的 436b3fb0≈235.1 同族), 但自发推断判成 uint32。
--   根因: ① dtypeHistory 连续性权重跨会话不清, 早期污染滚雪球粘死;
--   ② float32 值域只挡 NaN/Inf, 荒谬量级照拿满分; ③ uint32 大数无惩罚。
--   修法: mon.start 清 dtypeHistory + float32 值域带 [1e-3,1e7] + uint32
--   解出 >1e7 的大数时边界分重罚 ≤30。
--
-- 跑法: Lua 5.3+ 引擎 (mbus 的 CRC 用了 5.3 位运算 // 与 ~)。
--   用 Luatools 自带 LuatOS PC 引擎跑, 见 tools/run_lua_tests.bat
if package and package.path then
    package.path = 'lua/?.lua;' .. package.path
end
local mon = dofile('lua/bus/mon.lua')

local fails = 0
local total = 0
local function eq(a, b, what)
  total = total + 1
  if a ~= b then
    print(string.format('FAIL: %s (期望 %s, 实际 %s)', what, tostring(b), tostring(a)))
    fails = fails + 1
  end
end

-- ===== 一、float32 值域合理性带 =====
eq(mon.calc_range('float32', 235.83), 100, 'float32 带内值满分 (235.8, 温度量级)')
eq(mon.calc_range('float32', 5.0), 100, 'float32 带内值满分 (5.0)')
eq(mon.calc_range('float32', 1e5), 100, 'float32 带上界内满分 (1e5 累计量)')
eq(mon.calc_range('float32', 7e-6), 0, 'float32 过小(7e-6)不给分 —— 整数被按浮点误读')
eq(mon.calc_range('float32', 1e-30), 0, 'float32 denormal 0 分')
eq(mon.calc_range('float32', 1e30), 0, 'float32 过大(1e30)不给分')
eq(mon.calc_range('float32', 0/0), 0, 'float32 NaN 0 分')
eq(mon.calc_range('float32', 1/0), 0, 'float32 +Inf 0 分')

-- ===== 二、uint32 亿级大数衰减 =====
eq(mon.calc_range('uint32', 950997611), 100, 'uint32 值域本身仍满分 (范围判定不变)')
local b_big = mon.calc_boundary('uint32', 950997611)
if b_big > 30 then
  print(string.format('FAIL: uint32 亿级大数边界分应 ≤30, 实际 %d', b_big))
  fails = fails + 1
end
total = total + 1
-- 边界分语义 = "离 2^31 中点的距离", 65535/123 距中点 ~1.0 → 上限 99 (floor 截断)
eq(mon.calc_boundary('uint32', 65535), 99, 'uint32 正常计数值(65535)边界 ≈ 上限(不受衰减)')
eq(mon.calc_boundary('uint32', 123), 99, 'uint32 小计数值边界 ≈ 上限(不受衰减)')

-- ===== 三、端到端: 现场那帧 (RSP addr=2054 qty=4, 数据 436bb333 00000000) =====
-- 冷启动 (dtypeHistory 无污染 -- 对应 mon.start 清零后的新会话)
mon.clear_history()
local data = string.char(0x43, 0x6b, 0xb3, 0x33, 0x00, 0x00, 0x00, 0x00)
local d, v, c, merged = mon.pick_dtype(data, 0, 4, 2054, 1)
eq(d, 'float32', '冷启动: 2054 这帧应判 float32 (原逻辑判 uint32/int16)')
eq(merged, true, '冷启动: 2054 应按 32bit 合并 (占 2 个 16bit 位置)')
if v == nil or not (v > 230 and v < 240) then
  print(string.format('FAIL: float32 解读值应 ≈235.8, 实际 %s', tostring(v)))
  fails = fails + 1
end

-- 轻度历史污染 (8 帧里 2 帧 uint32): float32 连续性占优, 仍应守住 float32
mon.clear_history()
mon.seed_history('reg2054', { 'float32', 'float32', 'float32', 'float32',
                              'float32', 'float32', 'uint32', 'uint32' })
d = mon.pick_dtype(data, 0, 4, 2054, 1)
eq(d, 'float32', '轻度污染 (2/8 uint32) 下 float32 仍胜出 (大数衰减压低 uint32)')

-- ===== 四、零值段不被误伤 (插码注释 2054 第 2 段 0x00000000 的坑) =====
mon.clear_history()
local d0 = mon.pick_dtype(string.char(0x00, 0x00), 0, 1, 2056, 1)
eq(d0, 'uint16', '纯零 16bit 段仍按 uint16 拆 (uint32=0 不衰减也不抢走, 维持 16bit+5 现状)')

-- ===== 五、mon.start 清历史的行为保障 =====
mon.clear_history()
mon.seed_history('reg2054', { 'uint32', 'uint32', 'uint32', 'uint32',
                              'uint32', 'uint32', 'uint32', 'uint32' })
mon.clear_history()
d = mon.pick_dtype(data, 0, 4, 2054, 1)
eq(d, 'float32', '清历史后同样的帧回到 float32 (重进 sniff 不再被旧判绑死)')

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print(string.format('PASS: dtype 量级带 —— float32 带内才满分 / uint32 亿级衰减 / 2054 现场帧端到端判 float32 (%d 个断言通过)', total))
