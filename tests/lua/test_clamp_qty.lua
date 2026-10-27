-- test_clamp_qty.lua —— 推断 qty 封顶的单元测试 (2026-10, 防 OOM 崩溃)
--
-- 背景: 旁听推断按请求帧里的 qty 展开寄存器行, 而 qty 是 2 字节最大 65535。
--   总线上来一个异常 qty 的帧 → 展开 6 万多项 → Lua 堆(203K)爆 →
--   "not enough memory for buffer allocation" → VM 退出 → 设备重启。
--   修法: util.clamp_qty 把 qty 收敛到 Modbus 合理的范围。
--
-- 跑法(仓库根目录):  lua tests/lua/test_clamp_qty.lua  (本机 5.1 即可, 不依赖 mbus)

if package and package.path then package.path = 'lua/?.lua;' .. package.path end
local util = dofile('lua/util.lua')

local fails = 0
local function eq(a, b, what)
  if a ~= b then
    print(string.format('FAIL: %s (期望 %s, 实际 %s)', what, tostring(b), tostring(a)))
    fails = fails + 1
  end
end

-- 正常值原样返回
eq(util.clamp_qty(1), 1, 'qty=1 原样')
eq(util.clamp_qty(2), 2, 'qty=2 原样')
eq(util.clamp_qty(125), 125, 'qty=125 原样(Modbus 规范上限)')
eq(util.clamp_qty(256), 256, 'qty=256 原样(本工程上限)')

-- 超上限截断
eq(util.clamp_qty(257), util.MAX_INFER_QTY, 'qty=257 截到上限')
eq(util.clamp_qty(1000), util.MAX_INFER_QTY, 'qty=1000 截到上限')
eq(util.clamp_qty(0xFFFF), util.MAX_INFER_QTY, 'qty=65535 截到上限 (崩溃元凶)')

-- 非法输入
eq(util.clamp_qty(nil), 0, 'nil → 0')
eq(util.clamp_qty(-1), 0, '负数 → 0')
eq(util.clamp_qty('abc'), 0, '非数字 → 0')

-- 上限本身不能太大(否则封顶等于没封)
if util.MAX_INFER_QTY > 1024 then
  print('FAIL: MAX_INFER_QTY 太大, 封顶失去意义')
  fails = fails + 1
end

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print(string.format('PASS: util.clamp_qty —— qty 封顶 %d, 异常 qty 不再展开成几万项 (10 个断言通过)', util.MAX_INFER_QTY))
