-- test_dtype_band.lua —— dtype 启发式"量级带"判据的锁定测试 (2026-10)
--
-- 背景: 现场 2054 (RSP 4 寄存器 436bb333 00000000) 实际是 float32
--   (≈235.8 / 0.0, 与 2048 的 436b3fb0≈235.1 同族), 但自发推断判成 uint32。
--   根因: ① dtypeHistory 连续性权重跨会话不清, 早期污染滚雪球粘死;
--   ② float32 值域只挡 NaN/Inf, 荒谬量级照拿满分; ③ uint32 大数无惩罚。
--   修法: mon.start 清 dtypeHistory + float32 值域带 [1e-3,1e7] (0 豁免)
--   + int32/uint32 解出 >1e7 的边界分重罚 ≤30 + FIFO 深度 8→5。
--   二轮回归: 2048 的 436ad800 (float≈234.9) 被判 int32 —— 同根因的另一帧。
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
eq(mon.calc_range('float32', 0), 100, 'float32 恰好 0 也是合法通道值 (2026-10 二轮豁免)')
eq(mon.calc_range('float32', 7e-6), 0, 'float32 过小(7e-6)不给分 —— 整数被按浮点误读')
eq(mon.calc_range('float32', 1e-30), 0, 'float32 denormal 0 分')
eq(mon.calc_range('float32', 1e30), 0, 'float32 过大(1e30)不给分')
eq(mon.calc_range('float32', 0/0), 0, 'float32 NaN 0 分')
eq(mon.calc_range('float32', 1/0), 0, 'float32 +Inf 0 分')

-- ===== 二、uint32/int32 千万级大数衰减 (两类型同罚) =====
eq(mon.calc_range('uint32', 950997611), 100, 'uint32 值域本身仍满分 (范围判定不变)')
local b_big = mon.calc_boundary('uint32', 950997611)
if b_big > 30 then
  print(string.format('FAIL: uint32 亿级大数边界分应 ≤30, 实际 %d', b_big))
  fails = fails + 1
end
total = total + 1
local b_i32 = mon.calc_boundary('int32', 1131031720)
if b_i32 > 30 then
  print(string.format('FAIL: int32 千万级大数边界分应 ≤30, 实际 %d', b_i32))
  fails = fails + 1
end
total = total + 1
-- 边界分语义 = "离 2^31 中点的距离", 65535/123 距中点 ~1.0 → 上限 99 (floor 截断)
eq(mon.calc_boundary('uint32', 65535), 99, 'uint32 正常计数值(65535)边界 ≈ 上限(不受衰减)')
-- int32 的中点 = 0, 正常小值离中点近 → 边界分天然就低 (这是行为本身, 加上衰减后
-- int32 小值合计 25+30+0=55, 只会比 uint32 更难抢位, 正合预期)
eq(mon.calc_boundary('int32', 300), 0, 'int32 小值(300)离中点 0 近, 边界分天然为 0')

-- ===== 三、端到端: 现场那两帧 (2026-10 二轮) =====
-- 帧 A: RSP addr=2054 qty=4 数据 436bb333 00000000 (旧轮实测)
-- 帧 B: RSP addr=2048 qty=2 数据 436ad800 (新轮的错判帧, 实义 float32 ≈234.9)
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
total = total + 1

-- 帧 B: 2048 的 4 字节 (0x436AD800 → float 234.9 / int32 11.3 亿) 应判 float32
mon.clear_history()
d = mon.pick_dtype(string.char(0x43, 0x6a, 0xd8, 0x00), 0, 2, 2048, 1)
eq(d, 'float32', '冷启动: 2048 的 436ad800 应判 float32 (int32 解=11.3 亿无意义)')

-- 错位字垃圾帧 ([75 43 6a 2c], f32 解析无效) 也不给 int32 抢位种子
mon.clear_history()
d = mon.pick_dtype(string.char(0x75, 0x43, 0x6a, 0x2c), 0, 2, 2048, 1)
if d == 'int32' then
  print('FAIL: 垃圾帧不应让 int32 种子滚进史 (边界重罚后 int32 应输给 int16)')
  fails = fails + 1
end
total = total + 1

-- 轻度历史污染 (历史里 2 个 int32/uint32): float32 连续性占优, 仍应守住 float32
mon.clear_history()
mon.seed_history('reg2049', { 'float32', 'float32', 'float32', 'float32',
                              'int32', 'uint32', 'int32', 'uint32' })
d = mon.pick_dtype(string.char(0x43, 0x6b, 0xb3, 0x33), 0, 2, 2049, 1)
eq(d, 'float32', '污染史 (2/8 int 系) 下 float32 仍胜出 (大数衰减压低 int 系)')

-- ===== 四、零值段不被误伤 (插码注释 2054 第 2 段 0x00000000 的坑) =====
mon.clear_history()
local d0 = mon.pick_dtype(string.char(0x00, 0x00), 0, 1, 2056, 1)
eq(d0, 'uint16', '纯零 16bit 段仍按 uint16 拆 (uint32=0 不衰减也不抢走, 维持 16bit+5 现状)')

-- ===== 五、mon.start 清历史的行为保障 =====
mon.clear_history()
mon.seed_history('reg2054', { 'int32', 'int32', 'int32', 'int32',
                              'int32', 'int32', 'int32', 'int32' })
mon.clear_history()
d = mon.pick_dtype(data, 0, 4, 2054, 1)
eq(d, 'float32', '清历史后同样的帧回到 float32 (重进 sniff 不再被旧判绑死)')

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print(string.format('PASS: dtype 量级带 —— 带内才满分(0 豁免) / int32+uint32 千万级衰减 / 现场两帧端到端判 float32 (%d 个断言通过)', total))
