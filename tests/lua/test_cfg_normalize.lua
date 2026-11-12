-- test_cfg_normalize.lua —— 原地归一化必须和新建路径【逐字段等价】(2026-11-12)
--
-- 起因: W:CFG 为了砍掉现场量到的那 +13KB"归一化第二张表"(56 点 CTRACE:
--   decoded +15112 / norm +13048, 一次保存的入场费 28KB), normalize_poll 多了
--   个 inplace 参数。设计前提是"校验规则一条没改, 只是不再新建表", 这句得
--   有测试钉住:
--     ①两条路径的键集合/值/行数逐项相同 —— 原地那份落进 fskv 的 JSON 不能
--       比新建那份长(长一点就可能把 59 点顶过 4096);
--     ②不传 inplace 时仍是【纯函数】—— load_poll/load_pull 拿的是 12-fix-3
--       那张解码缓存里的 raw, 改它等于把缓存污染给后面每一个读者
--       (poll.lastCfg 就长期持有 load_poll() 的结果)。
--
-- 跑法(仓库根目录): lua tests/lua/test_cfg_normalize.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;' .. package.path

-- 假 fskv: 值原样存进内存表
local store = {}
package.preload['fskv'] = function()
  return { init = function() end,
           get = function(k) return store[k] end,
           set = function(k, v) store[k] = v return true end,
           save = function() end, del = function(k) store[k] = nil end }
end

-- 假 json: encode 只关心"能不能落盘", decode 每次返回【同一张表】——
--   这正是 cfg.lua 缓存里那份 raw 的地位, 用它验证归一化没改动缓存
local FLASH_RAW = nil
package.preload['json'] = function()
  return { encode = function() return 'x' end,
           decode = function() return FLASH_RAW end }
end

local cfg = dofile('firmware/cfg.lua')
local CC = require 'core/config'   -- MAX_REGS 在 core/config 里, 不在 cfg 模块上

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

local function keys_of(t)
  local k = {}
  for x in pairs(t) do k[#k + 1] = x end
  table.sort(k, function(a, b) return tostring(a) < tostring(b) end)
  return k
end

-- 递归比较: 键集合、每个键的值、数组有没有空洞/长度差
local function diff(a, b, path, out)
  if type(a) ~= 'table' or type(b) ~= 'table' then
    if a ~= b then
      out[#out + 1] = string.format('%s: %s ~= %s', path, tostring(a), tostring(b))
    end
    return
  end
  for _, k in ipairs(keys_of(a)) do
    if b[k] == nil then out[#out + 1] = path .. '.' .. tostring(k) .. ' 只在第一份里有' end
    diff(a[k], b[k], path .. '.' .. tostring(k), out)
  end
  for _, k in ipairs(keys_of(b)) do
    if a[k] == nil then out[#out + 1] = path .. '.' .. tostring(k) .. ' 只在第二份里有' end
  end
  local na, nb = #a, #b
  if na ~= nb then out[#out + 1] = string.format('%s 数组长度 %d ~= %d', path, na, nb) end
  local n = na < nb and na or nb
  for i = 1, n do
    if (a[i] == nil) ~= (b[i] == nil) then
      out[#out + 1] = path .. '[' .. i .. '] 一边是洞'
    elseif a[i] then
      diff(a[i], b[i], path .. '[' .. i .. ']', out)
    end
  end
end

local function report(d, what)
  eq(#d, 0, what .. (d[1] and (': ' .. table.concat(d, ' | ')) or ''))
end

local function clone(t)
  if type(t) ~= 'table' then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = clone(v) end
  return o
end

local function row(addr, name, extra)
  local r = { addr = addr, count = 1, dtype = 'uint16', name = name }
  if extra then for k, v in pairs(extra) do r[k] = v end end
  return r
end

-- 现场表的形状: addr 是字符串、每行多带前端导表的列(fc/desc)、alias 另给
local function sample(n)
  local regs = {}
  for i = 1, n do
    regs[i] = row(tostring(i), 'A' .. i, { alias = 'V' .. i, fc = 3, desc = '第' .. i .. '个' })
  end
  return { baud = 9600, databits = 8, stopbits = 1, parity = 0,
           slave = '3', interval_ms = '2000', timeout_ms = 300, regs = regs, note = '前端塞的' }
end

-- ①正常路径: 逐字段等价 + 原地返回的就是入参
local pure = cfg.normalize_poll(sample(8))
local raw2 = sample(8)
local ip = cfg.normalize_poll(raw2, true)
ok(type(pure) == 'table', '新建路径要成功')
ok(type(ip) == 'table', '原地路径要成功')
local d = {}
diff(pure, ip, 'root', d)
report(d, '两条路径必须逐字段相同')
eq(table.concat(keys_of(pure), ','), table.concat(keys_of(ip), ','), '顶层键集合')
ok(ip == raw2, '原地路径返回的就是入参那张表')
ok(ip.regs == raw2.regs, '寄存器表也是原地复用, 没新建')
ok(ip.regs[1] == raw2.regs[1], '每一行也是原地改, 没新建')
for i, r in ipairs(ip.regs) do
  ok(r.desc == nil and r.fc == nil, '第 ' .. i .. ' 行的多余键必须清掉')
  eq(#keys_of(r), 5, '第 ' .. i .. ' 行只剩 addr/count/dtype/name/alias 五个键')
end
eq(ip.slave, 3, 'slave 字符串照样转成数字')
eq(ip.interval_ms, 2000, 'interval_ms 同上')
eq(ip.regs[1].addr, 1, 'addr 转成数字(和旧代码一致: 只 tonumber, 不 floor)')
eq(ip.regs[1].alias, 'V1', 'alias 用传入的')
ok(pure.regs[1].desc == nil, '新建路径也不许把 desc 带进结果')

-- 没有 alias 时补 name(两条路径同一条规则)
local noalias_p = cfg.normalize_poll({ slave = 1, interval_ms = 1000, regs = { row(9, 'B9') } })
local noalias_i = cfg.normalize_poll({ slave = 1, interval_ms = 1000, regs = { row(9, 'B9') } }, true)
eq(noalias_p.regs[1].alias, 'B9', '新建路径 alias 补 name')
eq(noalias_i.regs[1].alias, 'B9', '原地路径 alias 补 name')

-- ②timeout_ms 缺省时两条路径都不能出现这个键
d = {}
diff(cfg.normalize_poll({ slave = 1, interval_ms = 1000, regs = {} }),
     cfg.normalize_poll({ slave = 1, interval_ms = 1000, regs = {} }, true),
     'no_timeout', d)
report(d, '缺省 timeout_ms 也要等价')

-- ③重复 addr 只留首条, 原地压缩后不能留空洞
local dup = { slave = 1, interval_ms = 1000, regs = {
  row(100, 'a'), row(200, 'b'), row(100, 'a2'), row(300, 'c'), row(200, 'b2') } }
local dup_p = cfg.normalize_poll(clone(dup))
local dup_i = cfg.normalize_poll(dup, true)
eq(#dup_p.regs, 3, '新建路径去重后 3 行')
eq(#dup_i.regs, 3, '原地路径去重后 3 行')
local walked = 0
for _, r in ipairs(dup_i.regs) do
  walked = walked + 1
  ok(type(r) == 'table', '去重后第 ' .. walked .. ' 行不能是洞')
end
eq(walked, 3, 'ipairs 走到的行数要等于 #(留洞的话前端 R:CFG 读出来短一截)')
eq(dup_i.regs[1].name, 'a', '去重留首条')
eq(dup_i.regs[2].name, 'b', '第二行还是 200 的首条')
eq(dup_i.regs[3].name, 'c', '第三行是搬上来的 300')
d = {}
diff(dup_p, dup_i, 'dup', d)
report(d, '去重结果也要等价')

-- ④校验规则一条没改: 同样的输入两条路径报同样的错
local bad_cases = {
  { c = { slave = 0,   interval_ms = 1000, regs = {} },                    why = 'bad slave' },
  { c = { slave = 248, interval_ms = 1000, regs = {} },                    why = 'bad slave' },
  { c = { slave = 1,   interval_ms = 99,   regs = {} },                    why = 'bad interval' },
  { c = { slave = 1,   interval_ms = 1000, timeout_ms = 49,  regs = {} },  why = '响应上限越界(50~500ms)' },
  { c = { slave = 1,   interval_ms = 1000, timeout_ms = 501, regs = {} },  why = '响应上限越界(50~500ms)' },
  { c = { slave = 1,   interval_ms = 1000, regs = { row(1, 'a', { dtype = 'int24' }) } }, why = 'bad dtype' },
  { c = { slave = 1,   interval_ms = 1000, regs = { row(1, '名字超过十六个字符就不合法') } }, why = 'bad name' },
  { c = { slave = 1,   interval_ms = 1000, regs = { row(70000, 'a') } },   why = 'bad addr' },
}
for _, tc in ipairs(bad_cases) do
  local a, ea = cfg.normalize_poll(clone(tc.c))
  local b, eb = cfg.normalize_poll(tc.c, true)
  ok(a == nil, tc.why .. ': 新建路径要失败')
  ok(b == nil, tc.why .. ': 原地路径要失败')
  eq(ea, tc.why, tc.why .. ': 新建路径的错名')
  eq(eb, tc.why, tc.why .. ': 原地路径的错名')
end

-- ⑤行数上限口径也要一致(旧代码是 append 前判 #out.regs > MAX_REGS,
--   所以 MAX_REGS+1 行收得下、MAX_REGS+2 行才拒 —— 原地路径不能改这个数)
local function nrows(n)
  local r = {}
  for i = 1, n do r[i] = row(i, 'a' .. i) end
  return { slave = 1, interval_ms = 1000, regs = r }
end
local lim_p, lim_perr = cfg.normalize_poll(nrows(CC.MAX_REGS + 1))
local lim_i, lim_ierr = cfg.normalize_poll(nrows(CC.MAX_REGS + 1), true)
ok(type(lim_p) == 'table', 'MAX_REGS+1 行新建路径要收(旧口径), 实际 ' .. tostring(lim_perr))
ok(type(lim_i) == 'table', 'MAX_REGS+1 行原地路径也要收, 实际 ' .. tostring(lim_ierr))
if type(lim_i) == 'table' then eq(#lim_i.regs, CC.MAX_REGS + 1, 'MAX_REGS+1 行的行数') end
local over_p, over_perr = cfg.normalize_poll(nrows(CC.MAX_REGS + 2))
local over_i, over_ierr = cfg.normalize_poll(nrows(CC.MAX_REGS + 2), true)
eq(over_perr, 'too many regs', '超限新建路径报那个词')
eq(over_ierr, 'too many regs', '超限原地路径报同一个词')

-- ⑥纯函数路径(缓存靠它)成功/失败都不许碰入参
local keep = sample(4)
local snap = clone(keep)
local r_a = cfg.normalize_poll(keep)
ok(type(r_a) == 'table', '正常表归一化成功')
d = {}
diff(snap, keep, 'input', d)
report(d, '不传 inplace 时入参一个字都不许动')
-- 失败点故意放在【寄存器行中间】: 那种情况下最容易顺手改到入参
local keep2 = { slave = 1, interval_ms = 1000,
                regs = { row(1, 'a', { dtype = 'nope', desc = 'z' }) } }
local snap2 = clone(keep2)
ok(cfg.normalize_poll(keep2) == nil, '坏 dtype 要失败')
d = {}
diff(snap2, keep2, 'fail-input', d)
report(d, '失败时也不许动入参')

-- ⑦load_poll 走的是 SECTIONS 里 pcall(sec.norm, raw) —— 只有一个参数,
--   拿到的是【缓存 raw】: 归一化必须没污染它, 且每次调用各得一张新表
FLASH_RAW = { slave = '5', interval_ms = '1200', regs = {
  row('42', 'x', { alias = 'VX', fc = 3, desc = '导表列' }),
  row('42', 'x2'), row('43', 'y') } }
local before = clone(FLASH_RAW)
eq(cfg.save_poll({ slave = 5, interval_ms = 1200, regs = { row(42, 'x') } }), true, 'save_poll 落盘')
local p1 = cfg.load_poll()
eq(p1.slave, 5, 'load_poll 的 slave')
eq(#p1.regs, 2, '缓存 raw 去重后 2 行')
eq(p1.regs[1].alias, 'VX', 'alias 取传入的')
local p2 = cfg.load_poll()
ok(p1 ~= p2, '两次 load 返回两张不同的表(归一化每次新建, 缓存只存 raw)')
ok(p1.regs[1] ~= p2.regs[1], '连寄存器行都是各自独立的一份')
d = {}
diff(before, FLASH_RAW, 'cached-raw', d)
report(d, '缓存里那份 raw 没被归一化改过')
eq(#p2.regs, 2, '第二次 load 行数一样(raw 若被改脏, 这里就对不上)')

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print('PASS: normalize_poll(inplace) —— 与新建路径逐字段等价, 默认路径仍是纯函数')
