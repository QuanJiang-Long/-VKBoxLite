-- test_cfg_shard.lua —— 寄存器表分片存储 (2026-11-12, 刀2)
--
-- 钉的是这一件事: 【任何一次分配的字节数都不许超过设备实测给得出的连续块】。
-- 现场实测(2026-11-12, boot_mode=manual, 56 行在跑):
--   lua:293064/307192  max:2048 fail:3072   —— 连续 3072B 都切不出来
-- 而老写法下这些动作每一个都要"一整块 = 整份配置的字节数":
--   读配置(fskv.get 回一整块 JSON) / 写配置(json.encode 出一整块) /
--   清配置(fskv.get 读 header 才能知道清没写过) —— 56 行那一整块实测 3791B。
-- 所以换介质(littlefs)无效: 探针在高水位连自己的 string.rep("x",8192) 都失败。
-- 唯一的出路是让每一次分配都待在一格里 —— 段宽 1024、段内最多 16 行。
--
-- 顺带钉 11-12 那两个假话再犯的机会:
--   1) "读不出来"必须和"没配过"分开报(见用例 6/8)
--   2) 提交前断电的分片配置【读不得】(用例 3) —— 拿半套寄存器表起轮询比
--      直接报错更坏: 用户看见设备在采一批他没配的地址
--
-- 本文件的 json 是一枚真编解码器(不是 test_cfg_kv 那种定长假 blob):
--   12-fix 那一轮的教训就是【替身不像, 测试全绿、现场全红】—— 老的
--   test_cmd_fs 把 io 当普通表来 fake, 于是字段查不到、测试照样过。
--   分片这段代码的正确性全在"编出来的字节怎么切、怎么拼回去", blob 长度
--   固定的假 json 一行都验不了。
-- 跑法: tools\run_lua_tests.bat test_cfg_shard.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;' .. package.path

local FSKV_MAX = 4096   -- fskv 单值硬顶(C 层), 与 cfg.lua 的常量同值

local store = {}        -- fskv 的"flash": key -> 存进去的那串
local set_log = {}      -- 本次保存的写序, 用来验两阶段提交
local LIMIT = math.huge -- 模拟"当前还能切出多大的连续块"; 现场最坏 = 2048
local PEAK = 0          -- 本用例内成功分配过的最大尺寸(= 真机上的 alloc 请求)
local COMMIT_FAIL = false

-- ===== 一次"分配": 超上限就抛, 和 C 层那句一模一样 =====
local function alloc(s)
  if #s > LIMIT then error('not enough memory for buffer allocation') end
  if #s > PEAK then PEAK = #s end
  return s
end

-- ===== 真 JSON(够覆盖配置里出现的类型: 表/数组/字符串/数字) =====
local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function enc_str(s)
  return '"' .. (tostring(s):gsub('[%c"\\]', function(c)
    return ESC[c] or string.format('\\u%04x', c:byte())
  end)) .. '"'
end

local encode
local function is_array(v)
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  if n == 0 then return true end -- 空表当数组(配置里的空 regs 就是这么来的)
  for k in pairs(v) do
    if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 or k > n then return false end
  end
  return true
end

function encode(v)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then return tostring(v) end
  if t == 'string' then return enc_str(v) end
  if t ~= 'table' then error('encode: 不支持的类型 ' .. t) end
  local parts = {}
  if is_array(v) then
    for i = 1, #v do parts[i] = encode(v[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  for k, val in pairs(v) do
    parts[#parts + 1] = enc_str(k) .. ':' .. encode(val)
  end
  table.sort(parts) -- 定序: 让"逐字节相同"这类断言写得出来
  return '{' .. table.concat(parts, ',') .. '}'
end

-- 递归下降解码。只认配置里会出现的语法, 但也【不认】错的语法(严格度对齐
-- 真 json: 解析失败必须 raise, cfg.lua 那边靠 pcall 兜)
local function decode(s)
  local i = 1
  local value -- forward decl
  local function ws()
    while i <= #s do
      local c = s:sub(i, i)
      if c == ' ' or c == '\t' or c == '\n' or c == '\r' then i = i + 1 else break end
    end
  end
  local function err(m) error('json decode: ' .. m .. ' @' .. i) end
  function value()
    ws()
    local c = s:sub(i, i)
    if c == '{' then
      local o = {}
      i = i + 1
      ws()
      if s:sub(i, i) == '}' then i = i + 1 return o end
      while true do
        ws()
        if s:sub(i, i) ~= '"' then err('expect key') end
        local k = value()
        ws()
        if s:sub(i, i) ~= ':' then err('expect colon') end
        i = i + 1
        o[k] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == '}' then break end
        if d ~= ',' then err('expect comma or brace') end
      end
      return o
    end
    if c == '[' then
      local a = {}
      i = i + 1
      ws()
      if s:sub(i, i) == ']' then i = i + 1 return a end
      while true do
        a[#a + 1] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == ']' then break end
        if d ~= ',' then err('expect comma or bracket') end
      end
      return a
    end
    if c == '"' then
      i = i + 1
      local buf = {}
      while true do
        local ch = s:sub(i, i)
        if ch == '' then err('unterminated string') end
        if ch == '\\' then
          local nx = s:sub(i + 1, i + 1)
          if nx == 'u' then
            buf[#buf + 1] = string.char(tonumber(s:sub(i + 2, i + 5), 16))
            i = i + 6
          else
            buf[#buf + 1] = ({ ['"'] = '"', ['\\'] = '\\', ['/'] = '/', n = '\n',
              r = '\r', t = '\t', b = '\b', f = '\f' })[nx] or nx
            i = i + 2
          end
        elseif ch == '"' then
          i = i + 1
          return table.concat(buf)
        else
          buf[#buf + 1] = ch
          i = i + 1
        end
      end
    end
    if c == 't' then
      if s:sub(i, i + 3) ~= 'true' then err('bad literal') end
      i = i + 4 return true
    end
    if c == 'f' then
      if s:sub(i, i + 4) ~= 'false' then err('bad literal') end
      i = i + 5 return false
    end
    if c == 'n' then
      if s:sub(i, i + 3) ~= 'null' then err('bad literal') end
      i = i + 4 return nil
    end
    local num = s:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', i)
    if not num or num == '' then err('bad value, got ' .. tostring(c)) end
    i = i + #num
    return tonumber(num)
  end
  local v = value()
  return v
end

-- ===== fskv / json 替身 =====
package.preload['fskv'] = function()
  return {
    init = function() end,
    get = function(k)
      local v = store[k]
      if v == nil or v == '' then return nil end
      return alloc(v) -- C 层要把整块搬进 Lua 字符串: 尺寸不够就抛
    end,
    set = function(k, v)
      -- "提交失败"这一步 = 同一把键在本次保存里被写第二次(header 先 st=w、
      --   段写完后提交 st=r)。用 set_log 数, 别用 store 里有没有值: 上一个
      --   用例留下的值会把第一笔 header 写也拦掉, 那就测不到提交这一步
      if COMMIT_FAIL then
        for i = 1, #set_log do
          if set_log[i] == k then return false end
        end
      end
      set_log[#set_log + 1] = k
      if type(v) ~= 'string' then return false end
      if #v > FSKV_MAX then return false end -- 超限: 只返 false, 不抛
      if #v > LIMIT then error('not enough memory for buffer allocation') end
      store[k] = v
      return true
    end,
    save = function() end,
    del = function(k) store[k] = nil end,
  }
end
package.preload['json'] = function()
  return {
    encode = function(v) return alloc(encode(v)) end, -- encode 的【产物】也要能装下
    decode = function(s) return decode(s) end,
  }
end

-- cfg.lua 里 json_cache/cfg_ver 是模块级状态, 换用例要拿一份干净的实例;
--   flash 也一起清空, 否则上一例的值会串进这一例(用例 5/6 自己要 seed 就在
--   fresh 之后写 store)
local function fresh()
  for k in pairs(store) do store[k] = nil end
  PEAK, LIMIT, COMMIT_FAIL = 0, math.huge, false
  set_log = {}
  return dofile('firmware/cfg.lua')
end

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
local function ok_(v, what)
  if v then print('FAIL: ' .. what .. ' (不该发生)') fails = fails + 1 end
end

-- 造 n 行寄存器。name 用满 16 字符, 让每行尺寸贴近现场(名字越短段越少,
--   拿短名字测出来的段数偏乐观)
local function rows(n, base)
  local r = {}
  for i = 1, n do
    r[i] = { addr = (base or 0) + i, count = 1, dtype = 'int32',
             name = 'Reg' .. i .. string.rep('x', 12 - #tostring(i)),
             alias = 'reg' .. ((base or 0) + i) }
  end
  return r
end

-- 数一下 flash 里实际【还写着】的键, 并回最大值。
--   空串 = 没写过(fskv 的语义, cfg.lua 通篇按这条判), 所以空串不算段
local function keys_of(k)
  local n, maxsz = 0, 0
  for key, v in pairs(store) do
    if v ~= '' and (key == k or key:sub(1, #k + 1) == k .. '.') then
      if #v > maxsz then maxsz = #v end
      if key ~= k then n = n + 1 end
    end
  end
  return n, maxsz
end

-- ===== 1) 56 行往返: 现场那个尺寸 =====
do
  local cfg = fresh()
  LIMIT = 2048 -- 现场最坏水位: 连续块只给得出 2048
  local ok, err = cfg.save_poll({ slave = 3, baud = 9600, interval_ms = 2000, regs = rows(56, 100) })
  eq(ok, true, '56 行在 max:2048 的水位上存得下: ' .. tostring(err))
  local seg, maxsz = keys_of('ds_poll')
  eq(type(seg) == 'number' and seg >= 3, true, '56 行确实切成多段(实得 ' .. seg .. ' 段)')
  if maxsz > 2048 then
    print(string.format('FAIL: 段尺寸顶破了设备给得出的块 (%d > 2048)', maxsz)); fails = fails + 1
  end
  if PEAK > 2048 then
    print(string.format('FAIL: 保存过程里申请过一块 %dB 的连续内存(> 2048)', PEAK)); fails = fails + 1
  end
  eq(store['ds_poll'] ~= nil, true, 'header 在')

  local c, why = cfg.load_poll()
  ok_(why, '56 行读回来不该带原因: ' .. tostring(why))
  eq(c and #c.regs or -1, 56, '读回来还是 56 行')
  eq(c and c.slave or -1, 3, '串口参数跟着 header 存住了')
  eq(c and c.interval_ms or -1, 2000, '轮询间隔存住了')
  eq(c and c.regs and c.regs[1] and c.regs[1].addr or -1, 101, '第 1 行是第 1 行')
  eq(c and c.regs and c.regs[56] and c.regs[56].addr or -1, 156, '第 56 行没串位')
  eq(c and c.regs and c.regs[56] and c.regs[56].name or '?', 'Reg56xxxxxxxxxx', '名字逐字节回来')
  if PEAK > 2048 then
    print(string.format('FAIL: 读取过程申请过 %dB 的块(> 2048)', PEAK)); fails = fails + 1
  end
end

-- ===== 2) 128 行(V2 的目标尺寸): 段数与峰值仍然都在一格里 =====
do
  local cfg = fresh()
  LIMIT = 2048
  local ok, err = cfg.save_poll({ slave = 1, regs = rows(128, 1) })
  eq(ok, true, '128 行存得下: ' .. tostring(err))
  local seg, maxsz = keys_of('ds_poll')
  if seg < 5 then
    print(string.format('FAIL: 128 行只切了 %d 段, 段宽闸门没生效', seg)); fails = fails + 1
  end
  if maxsz > 2048 or PEAK > 2048 then
    print(string.format('FAIL: 128 行的最大一次分配 %dB(段内最大 %dB), 顶破 2048', PEAK, maxsz))
    fails = fails + 1
  end
  local c, why = cfg.load_poll()
  ok_(why, '128 行读回来不该带原因')
  eq(c and #c.regs or -1, 128, '128 行原样读回')
end

-- ===== 3) 两阶段提交: "提交"失败的那一份【读不得】 =====
-- 断电停在 header(st=w) 与各段之间、或停在提交那一下, 结果都是 st 还是 w。
--   读侧必须拒绝, 并把原因交回去 —— 老写法会拿一份 regs 空着的 header 起轮询
do
  local cfg = fresh()
  COMMIT_FAIL = true -- 第二次写同一个键(= 提交)时 fskv 拒绝
  local ok, err = cfg.save_poll({ slave = 1, regs = rows(8, 1) })
  eq(ok, false, '提交失败必须判整次保存失败')
  has(err, '提交', '失败原因说清是提交这一步')

  -- 换一份干净的 cfg 实例(缓存归零), 模拟"设备重启后读到这份半成品"
  local cfg2 = dofile('firmware/cfg.lua')
  local c, why = cfg2.load_poll()
  has(why, '未提交', '半成品读不出来时, 原因是"分片未提交"')
  eq(type(c), 'table', '即便如此第一个返回值仍是表(设备要能起机)')
  eq(c == cfg2.default_poll, true, '回的是默认表, 不是那份半截配置')
  local hc, hwhy = cfg2.has_poll_cfg()
  eq(hc, false, '半成品不算"有配置可轮询"')
  has(hwhy, '未提交', 'has_poll_cfg 把原因传出去(不许读成"没配过")')
end

-- ===== 4) 缩表: 段数变少时旧残段必须清掉, 不能白占 fskv =====
do
  local cfg = fresh()
  cfg.save_poll({ slave = 1, regs = rows(56, 1) })
  local seg_before = keys_of('ds_poll')
  local ok = cfg.save_poll({ slave = 1, regs = rows(5, 1) })
  eq(ok, true, '缩表保存成功')
  local seg_after = keys_of('ds_poll')
  if seg_after >= seg_before then
    print(string.format('FAIL: 5 行只该 1 段, 段数没降(%d -> %d)', seg_before, seg_after)); fails = fails + 1
  end
  -- 残段: 序号比现在的 n 大的那些键, 内容必须是"没写过"(nil 或空串)
  local stale = 0
  for k, v in pairs(store) do
    local i = tonumber(k:match('^ds_poll%.(%d+)$'))
    if i and i > seg_after and v ~= '' then stale = stale + 1 end
  end
  eq(stale, 0, '多出来的残段清干净了')
  local c = cfg.load_poll()
  eq(c and #c.regs or -1, 5, '缩表后读回来是 5 行(残段没混进来)')
end

-- ===== 5) 老格式(整份 JSON 一个键)照样能读, 下一次保存自然迁成分片 =====
-- 迁移期最长一次保存, 所以不做双写兼容层: 这条钉的就是"读到就用"
do
  local cfg = fresh()
  store['ds_poll'] = encode({ slave = 7, interval_ms = 3000,
    regs = { { addr = 201, count = 1, dtype = 'uint16', name = 'Old1', alias = 'reg201' } } })
  local c, why = cfg.load_poll()
  ok_(why, '老格式读出来不该带原因')
  eq(c and c.slave or -1, 7, '老格式的参数读得出来')
  eq(c and #c.regs or -1, 1, '老格式的寄存器读得出来')
  cfg.save_poll({ slave = 7, regs = rows(20, 1) })
  local seg = keys_of('ds_poll')
  if seg < 1 then print('FAIL: 保存后没变成分片') fails = fails + 1 end
  local c2 = cfg.load_poll()
  eq(c2 and #c2.regs or -1, 20, '迁移后照样读得回')
end

-- ===== 6) 11-12 那个假话: 整块读不出来时, 不许说成"从没配过" =====
-- 老固件留下的就是这一大坨(实测 3791B); 池子只给得出 2048 时 fskv.get 抛的
--   是【异常】而不是 nil。以前的 kv_get 把两者都变成 nil, 于是
--   has_poll_cfg 回 false、log 打"poll 槽空, 暂不起轮询"、R:CFG 回默认表
do
  local cfg = fresh()
  store['ds_poll'] = '{' .. string.rep('a', 3700) .. '}' -- 一整块 3700B, 尺寸像就够
  LIMIT = 2048
  eq(cfg.poll_src(), 'read-fail', '整块读不出来时 src 不冒充 fskv/default')
  local hc, why = cfg.has_poll_cfg()
  eq(hc, false, '读不出来时不算有配置')
  has(why, '读不出来', 'has_poll_cfg 报的是"读不出来"')
  has(why, 'not enough memory', 'C 层那句跟着回来')
  local c, why2 = cfg.load_poll()
  eq(type(c), 'table', '仍然回一张表(开机路径不能拿到 nil)')
  has(why2, '读不出来', 'load_poll 同样如实报')
  -- 关键: 这次的失败【没被固化进缓存】。水位回到原样后同一条读要能成功
  local cfg2 = dofile('firmware/cfg.lua')
  store['ds_poll'] = encode({ slave = 4, regs = { { addr = 9, name = 'A', dtype = 'uint16' } } })
  local c2, w2 = cfg2.load_poll()
  ok_(w2, '换一份内容后重读不该带原因: ' .. tostring(w2))
  eq(c2 and c2.slave or -1, 4, '重读拿到的是 flash 里现在这份')
end

-- ===== 7) 清配置连段一起清, 清完是"真没写过"(不是"读不出来") =====
do
  local cfg = fresh()
  cfg.save_poll({ slave = 1, regs = rows(40, 1) })
  cfg.save_pull({ slave = 1, regs = rows(12, 1) })
  local cleared, failed = cfg.reset_user()
  eq(#(failed or {}), 0, '复位一个失败都没有: ' .. table.concat(failed or {}, ','))
  eq(cleared and #cleared or 0, 2, '两个 485 槽都报清掉了')
  for k in pairs(store) do
    if k:match('^ds_poll') or k:match('^ds_pull') then
      if store[k] ~= '' then
        print(string.format('FAIL: %s 还留着 %dB', k, #store[k])); fails = fails + 1
      end
    end
  end
  eq(cfg.poll_src(), 'default', '清完 src 认得出"没写过"')
  local hc, why = cfg.has_poll_cfg()
  eq(hc, false, '清完没有可轮询的配置')
  ok_(why, '清完是真没写过, 不许带"读不出来"这类原因: ' .. tostring(why))
end

-- ===== 8) 高水位下的清配置: 分片读得出, 老格式读不出但要说清真原因 =====
-- 这条就是 11-12 那次"切 idle 回了 RET:MODE=OK;cleared:mqtt_manual, 而 flash 里
--   那 56 行一个字没少"的两个分支: 修完之后, 分片该成功, 老格式该【失败且报原因】,
--   两种都不许静默报成功
do
  local cfg = fresh()
  cfg.save_poll({ slave = 1, regs = rows(56, 1) })
  LIMIT = 2048 -- header 只有一两百字节, 段根本不用读 —— 清得掉
  local cleared, failed = cfg.reset_user()
  eq(#cleared, 1, '分片配置在高水位下照样清掉')
  eq(#(failed or {}), 0, '不该有失败: ' .. table.concat(failed or {}, ','))
  eq(cfg.poll_src(), 'default', '真清干净了(不是假装清)')

  -- 换回老格式那一大坨: 这一步 fskv.get 就要 3791B, 给不出
  local cfg2 = dofile('firmware/cfg.lua')
  store['ds_poll'] = '{' .. string.rep('a', 3700) .. '}'
  LIMIT = 2048
  local cl2, fl2 = cfg2.reset_user()
  eq(#cl2, 0, '读不出来的老配置不许算"已清掉"')
  eq(#fl2, 1, '如实报回一个失败')
  has(fl2[1], 'manual', '失败清单里说清是哪个槽(用的是给用户看的友好名)')
  has(fl2[1], '读不出来', '原因是读不出来, 不是"没写过"')
end

-- ===== 9) 写序: header(st=w) 一定在各段之前, 提交头一定在最后 =====
do
  local cfg = fresh()
  cfg.save_poll({ slave = 1, regs = rows(24, 1) })
  local first, last = set_log[1], set_log[#set_log]
  eq(first, 'ds_poll', '第一笔写的是 header(先立 st=w)')
  eq(last, 'ds_poll', '最后一笔也是 header(提交 st=r)')
  eq(store['ds_poll']:find('"st":"r"', 1, true) ~= nil, true, '落盘的 header 是已提交状态')
  eq(store['ds_poll']:find('"st":"w"', 1, true), nil, '已提交的 header 里不该再有 st=w')
end

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print('PASS: cfg 分片 —— 每次分配都在一格内, 半成品读不得, 读不出来不冒充没配过')
