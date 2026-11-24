-- test_cfg_compact.lua —— 紧凑寄存器行 (2026-11-19)
--
-- 为什么要有这个测试:
--   寄存器行从"5 个字符串键的哈希表"(真机实测 ~350B/行)改成"定长数组"
--   (~165B/行), 60 点从 21KB 降到 ~10KB —— 这是"60 点存得进、读得回"的
--   那一半底牌(A0 现场 60 点死在 第 4/5 片 rx 丢弃, used 289232/94%)。
--   改法靠 __index/__newindex 让所有读侧代码(r.addr / r.name ...)不用动,
--   代价是**两个必须钉死的坑**:
--     1) json.encode(紧凑行) 会把它编成数组 [101,1,"uint16","R1","reg101"]
--        —— 所以所有编码出口必须先过 cfg.row_out()。落盘分片里必须是
--        {"addr":...} 这样的对象, 不是数组。
--     2) 读盘/分片暂存要在"攒起来"的那一刻折成紧凑行, 不然攒 60 行哈希行
--        (~21KB)就把内存吃回去了。
--
-- 跑法: tools\run_lua_tests.bat test_cfg_compact.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;tests/lua/?.lua;' .. package.path

local store = {}
package.preload['fskv'] = function()
  return { init = function() end,
           get = function(k) return store[k] end,
           set = function(k, v) store[k] = v return true end,
           save = function() end, del = function(k) store[k] = nil end }
end

-- 真编码器(mock_json 走 pairs/is_array 判数组) —— 这正是要钉的那个坑:
--   紧凑行如果没折成普通对象, 这里会编出 [..] 而不是 {..}
local mock = require 'mock_json'
package.preload['json'] = function()
  return { encode = mock.encode, decode = mock.decode }
end

local cfg = dofile('firmware/cfg.lua')

local fails = 0
local function ok(cond, what)
  if not cond then print('FAIL: ' .. what) fails = fails + 1 end
end
local function eq(a, b, what)
  if a ~= b then
    print(string.format('FAIL: %s (期望 %s, 实际 %s)', what, tostring(b), tostring(a)))
    fails = fails + 1
  end
end

local function hash_row(addr, name)
  return { addr = addr, count = 1, dtype = 'uint16', name = name, alias = '点' .. addr }
end

-- ===== 1. 归一化产物是紧凑行 =====
local c = cfg.normalize_poll({ slave = 1, interval_ms = 1000,
  regs = { hash_row(100, 'R100'), hash_row(101, 'R101') } })
ok(cfg.is_row(c.regs[1]), 'normalize_poll 产出的行是紧凑行')
eq(c.regs[1].addr, 100, '紧凑行 addr 读得出来')
eq(c.regs[1].name, 'R100', '紧凑行 name 读得出来')
eq(c.regs[1].alias, '点100', '紧凑行 alias 读得出来')
eq(c.regs[2].count, 1, '紧凑行 count 读得出来')
eq(c.regs[1].dtype, 'uint16', '紧凑行 dtype 读得出来')
-- 后面这一条是"行没有多余字段"的判据: 哈希行会是 5, 紧凑行也是 5 个数组槽
local n = 0
for _ in pairs(c.regs[1]) do n = n + 1 end
eq(n, 5, '紧凑行只有 5 个槽, 没有哈希节点')

-- ===== 2. off 写进第 6 槽(不新增对象/字段) =====
c.regs[1].off = 7
eq(c.regs[1].off, 7, 'off 写得进读得出')
local n2 = 0
for _ in pairs(c.regs[1]) do n2 = n2 + 1 end
eq(n2, 6, 'off 占的是第 6 槽, 不是新键')

-- ===== 3. row_out: 紧凑行 → 普通对象; 其它表原样返回 =====
local o = cfg.row_out(c.regs[1])
eq(o.addr, 100, 'row_out 带出 addr')
eq(o.alias, '点100', 'row_out 带出 alias')
ok(o ~= c.regs[1], 'row_out 是临时副本(不动原行)')
eq(o.off, nil, 'row_out 不带轮询偏移(存储格式里没有这个字段)')
local plain = { addr = 1, count = 1, dtype = 'uint16', name = 'X', alias = 'X' }
ok(cfg.row_out(plain) == plain, '非紧凑表原样返回(推断表/别名表行不受影响)')

-- ===== 4. 落盘: 分片里必须是对象, 不是数组 =====
local big = { slave = 1, interval_ms = 1000, regs = {} }
for i = 1, 60 do big.regs[i] = hash_row(1000 + i, 'P' .. i) end
local n60 = cfg.normalize_poll(big)
eq(#n60.regs, 60, '60 行归一化后还是 60 行')
ok(cfg.is_row(n60.regs[60]), '最后一行也是紧凑行')

local okw, werr = cfg.save_poll_norm(n60)
ok(okw, 'save_poll_norm 成功: ' .. tostring(werr))

local shards = 0
for k, v in pairs(store) do
  if k:match('^ds_poll%.%d+$') then
    shards = shards + 1
    ok(type(v) == 'string' and #v > 0, '分片 ' .. k .. ' 非空')
    -- 判据: 数组里的第一行必须是 {"addr": 开头, 不能是 [1000,1,"uint16"...
    ok(v:sub(1, 8) == '[{"addr"' or v:sub(1, 7) == '{"addr"',
       '分片 ' .. k .. ' 落的是对象不是数组: ' .. v:sub(1, 24))
  end
end
ok(shards >= 2, '60 行切成多片(实得 ' .. shards .. ' 片)')

-- ===== 5. 读回: load_poll 拿到的是紧凑行, 值一个不少 =====
cfg.drop_cache()
local back, berr = cfg.load_poll()
ok(back ~= nil, 'load_poll 读得回: ' .. tostring(berr))
eq(#(back and back.regs or {}), 60, '读回 60 行')
ok(cfg.is_row(back.regs[1]), '读盘路径也产出紧凑行(不是把哈希行攒着)')
eq(back.regs[1].addr, 1001, '读回首行 addr')
eq(back.regs[1].alias, '点1001', '读回首行 alias')
eq(back.regs[60].name, 'P60', '读回末行 name')
eq(back.slave, 1, '读回 slave')

-- ===== 6. 分片上传暂存口: 收一片就折一片 =====
local nr, nerr = cfg.row_norm({ addr = 7, count = 1, dtype = 'uint16', name = 'R7', alias = '点7' })
ok(nr ~= nil, 'row_norm 收下合法行: ' .. tostring(nerr))
ok(cfg.is_row(nr), 'row_norm 产出紧凑行')
local bad, bwhy = cfg.row_norm({ addr = 70000, count = 1, dtype = 'uint16', name = 'R7' })
ok(bad == nil, 'row_norm 挡住非法行')
eq(bwhy, 'bad addr', 'row_norm 如实报原因')

-- ===== 7. 旧格式(带多余字段/缺 alias)的行仍然收得住 =====
local legacy = cfg.normalize_poll({ slave = 1, interval_ms = 1000,
  regs = { { addr = '9', count = '1', dtype = 'uint16', name = 'Old', fc = 3, desc = '多余' } } })
ok(cfg.is_row(legacy.regs[1]), '旧格式行归一化后也是紧凑行')
eq(legacy.regs[1].alias, 'Old', '缺 alias 时退回 name')
eq(legacy.regs[1].addr, 9, 'addr 字符串转数字')
ok(legacy.regs[1].desc == nil and legacy.regs[1].fc == nil, '多余字段被丢掉')

-- ===== 8. 就地归一化必须幂等且复用行对象 (模式切换路径靠这条不复制 60 行)=====
--   11-24 真机: W:MODE=manual 在 60 点时"FAIL poll start" —— 根因是模式切换
--   连做两次"归一化出一整份新表"(每份 60 行 ≈ 12KB), 池子只剩 13KB 时把
--   uart.setup 的 1KB 接收缓冲挤掉。现在 ctrl 改成 normalize_poll(cfg, true)
--   并把结果直接交给 poll.start(slot, n), 所以这条性质必须钉住:
--   同一个表、同一批行对象, 一个都不许新造。
local c8 = cfg.normalize_poll({ slave = 1, interval_ms = 1000, regs = {
  { addr = 1, count = 1, dtype = 'uint16', name = 'A', alias = 'a' },
  { addr = 2, count = 1, dtype = 'uint16', name = 'B', alias = 'b' },
} })
local r8a, r8b = c8.regs[1], c8.regs[2]
local c8b = cfg.normalize_poll(c8, true)
ok(c8b == c8, '就地归一化返回同一个表')
ok(c8b.regs[1] == r8a and c8b.regs[2] == r8b, '就地归一化复用原来的行对象(不造第二份 60 行)')
eq(#c8b.regs, 2, '就地归一化行数不变')
eq(c8b.slave, 1, '就地归一化保留配置值')

if fails > 0 then
  print(string.format('FAIL: %d 个检查点不过', fails))
  os.exit(1)
end
print('PASS: cfg 紧凑行 —— 60 行落盘是对象不是数组, 读回逐字段一致, 旧格式收得住')
