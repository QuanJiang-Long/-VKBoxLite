-- test_cfg_reason.lua —— 保存/读取配置的失败必须【说清真原因】(2026-11-12)
--
-- 起因是复测-日志 4 那两次保存。就地归一化(29432b4)把 norm 段从 +13048 打到
-- +1288 之后, 失败点挪到了上一格, 而应答上看不见:
--   第二次保存(切 idle 又切回 manual 之后) RET:FAIL:CFG:encode fail ——
--   同一毫秒设备日志 E/mem memory allocation failed total 307192,
--   used 298576, alloc 3791。json.encode 要的那块 3791B 连续内存没拿到,
--   可 save_json 把 pcall 的第二返回值扔了, 只回一句 encode fail。
--   这和刚修掉的 kv_set 是同一个毛病: 真原因只进设备日志, 前端看不见。
--
--   同一条日志里还有一句 W/user.cfg poll normalize fail, use default ——
--   那是 R:CFG 的读路径: 池子只剩 1KB 时归一化里连 160B 都分配不出来,
--   pcall 拿到的是【异常】不是"配置非法", 代码却一样回 default,
--   前端于是显示一张空表, 用户以为他填的 56 行没了。
--
-- 所以这个文件钉两件事:
--   1) encode 失败的原因(内存不足那句)必须进应答, 且"encode fail"这个前缀
--      一个字不能动(上位机 sn-tools/pc_tool 按它认这条失败)。
--   2) load_* 分清【归一化判非法】和【归一化抛异常】: 两个原因话不一样,
--      但第一个返回值【必须还是表】—— main.lua 靠它起机, 这里回 nil
--      等于把设备弄得起不来。
--
-- 跑法: tools\run_lua_tests.bat test_cfg_reason.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;' .. package.path

local store = {}
local DECODED = {}          -- 假 json.decode 的返回物, 每个用例换一张
local ENC, ENC_MSG, BLOB = 'ok', 'not enough memory for buffer allocation', 'J'

package.preload['fskv'] = function()
  return {
    init = function() end,
    get = function(k) return store[k] end,
    set = function(k, v) store[k] = v return true end,
    save = function() end,
    del = function(k) store[k] = nil end,
  }
end

package.preload['json'] = function()
  return {
    encode = function()
      if ENC == 'raise' then error(ENC_MSG) end
      if ENC == 'nil' then return nil end
      return BLOB
    end,
    decode = function() return DECODED end,
  }
end

local cfg = dofile('firmware/cfg.lua')

local fails = 0
local function eq(a, b, what)
  if a ~= b then
    print(string.format('FAIL: %s (期望 %s, 实际 %s)', what, tostring(b), tostring(a)))
    fails = fails + 1
  end
end
local function has(s, sub, what)
  if type(s) ~= 'string' or not s:find(sub, 1, true) then
    print(string.format('FAIL: %s (该含 %q, 实际 %q)', what, sub, tostring(s)))
    fails = fails + 1
  end
end
local function oneline(s, what)
  if type(s) ~= 'string' then
    print(string.format('FAIL: %s 不是字符串: %s', what, tostring(s))); fails = fails + 1; return
  end
  -- 应答是【一整行】: 原因里混进 \r 或 \n 会把后面所有帧的解析搅乱
  if s:find('\r', 1, true) or s:find('\n', 1, true) then
    print(string.format('FAIL: %s 带换行: %q', what, s)); fails = fails + 1
  end
end

-- ===== 1) json.encode 抛异常: 真原因必须进应答 =====
ENC = 'raise'
local ok, err = cfg.save_poll({ slave = 1, regs = { { addr = 100, name = 'a', dtype = 'uint16' } } })
eq(ok, false, 'encode 抛异常时保存判失败')
has(err, 'encode fail', '前缀 encode fail 原样保留(上位机按它认这条)')
has(err, 'not enough memory', 'C 层那句内存不足跟着回应答')
oneline(err, 'encode 失败原因')

-- 超长/带换行的原因: 压成一行并截断(现场那句 E/mem 是一整行, 但别的 bsp 未必)
ENC_MSG = 'memory allocation failed total 307192,\r\n used 298576, alloc 3791 ' .. string.rep('x', 200)
ok, err = cfg.save_poll({ slave = 1, regs = {} })
eq(ok, false, '超长原因同样失败')
oneline(err, '超长原因')
-- 80 是 brief 的默认上限, 整条应答 = 前缀 + 最多 80 字节
if #err > #'encode fail: ' + 80 then
  print(string.format('FAIL: 原因没截断, 应答 %d 字节', #err)); fails = fails + 1
end

-- ===== 2) json.encode 不抛异常只回 nil: 分开报, 但前缀还在 =====
ENC, ENC_MSG = 'nil', ''
ok, err = cfg.save_poll({ slave = 1, regs = {} })
eq(ok, false, 'encode 无返回也判失败')
has(err, 'encode fail', '无返回同样带 encode fail 前缀')
has(err, '无返回', '无返回和抛异常说得开')

-- ===== 3) 落盘这一步仍然正常(前缀改动没把成功路径带歪) =====
ENC = 'ok'
ok, err = cfg.save_poll({ slave = 1, regs = { { addr = 100, name = 'a', dtype = 'uint16' } } })
eq(ok, true, '小配置照样存得下')
eq(err, nil, '成功时一个原因都不带')

-- 换一个场景: 把 fskv 里的值和解码缓存重新灌一遍。
-- kv_set 成功后才清缓存, 这里借一次正常保存把 ds_poll 的解码缓存顶掉, 再换 DECODED
local function reseed(t)
  ENC = 'ok'; BLOB = 'J'
  cfg.save_poll({ slave = 1, regs = {} })
  DECODED = t
  return t
end

-- ===== 4) 正常路径: 第二个返回值必须是 nil =====
reseed({ slave = 5, interval_ms = 1000, regs = { { addr = 1, name = 'a', dtype = 'uint16' } } })
local c, why = cfg.load_poll()
eq(type(c), 'table', '正常配置读出来是表')
eq(c.slave, 5, '读到的是存进去的那份')
eq(why, nil, '成功时 load_poll 不许带原因')

-- ===== 5) 归一化【判非法】: 回默认表 + 原因原文 =====
reseed({ slave = 999, regs = {} })
c, why = cfg.load_poll()
eq(type(c), 'table', '配置非法时起机路径仍要拿到一张表')
eq(c.slave, cfg.default_poll.slave, '非法时回的是默认配置')
has(why, 'bad slave', '原因用的是归一化自己那句话')
if why:find('内存', 1, true) then
  print(string.format('FAIL: 内容非法被说成内存问题: %q', why)); fails = fails + 1
end

-- ===== 6) 归一化【抛异常】(池子不够): 必须和上面分开 =====
-- 现场那次是 used 304848/307192 时读一个字段就要 160B 拿不到, 这里用 __index
-- 抛错来复现"归一化中途 raise", 而不是让它返回 nil
reseed(setmetatable({}, { __index = function()
  error('not enough memory for buffer allocation')
end }))
c, why = cfg.load_poll()
eq(type(c), 'table', '内存不足时也仍要拿到一张表(设备要能起机)')
has(why, '内存/内部异常', '异常和非法分开报, 这句一眼看得出不是配置坏')
has(why, 'not enough memory', 'C 层那句跟着回来, 读日志的人不用猜')
oneline(why, '异常原因')

-- ===== 7) 空槽不许被误报 =====
-- ds_pull 从头到尾没写过: load_json 给的是空表, 归一化通过, 没有原因。
-- 这条要是挂了, R:CFG 就会在出厂新设备上回 RET:FAIL —— 比原来那个假话更难查
local p2, w2 = cfg.load_pull()
eq(type(p2), 'table', '没配置时 load_pull 回默认表')
eq(w2, nil, '空槽不是失败, load_pull 不许带原因')

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print('PASS: cfg 失败原因 —— encode fail 带真原因, 内存异常不再冒充"配置坏了"')
