-- test_cfg_kv.lua —— fskv 落盘失败必须如实回报 (2026-11-10, P0-1)
--
-- 起因 (128 点保存现场): 80 点时日志明明打了
--   E/fskv value too big 5199 max 4096
-- 前端却收到 RET:CFG=OK。根因在 cfg.lua 的 kv_set: 它只看 pcall 的 ok,
-- 而 fskv.set 超限/内存不足时【不 raise, 只返回 false】→ 假成功 →
-- poll.start() 回头读 fskv 里的旧值/空表 → regs=0。
--
-- 跑法(仓库根目录): lua tests/lua/test_cfg_kv.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;' .. package.path

local FSKV_MAX = 4096

local store, set_calls, set_ret, blob_len = {}, 0, true, 24

package.preload['fskv'] = function()
  return {
    init = function() end,
    get = function(k) return store[k] end,
    set = function(k, v)
      set_calls = set_calls + 1
      if set_ret == 'raise' then error('not enough memory for buffer allocation') end
      if set_ret ~= true then return set_ret end
      store[k] = v
      return true
    end,
    save = function() end,
    del = function(k) store[k] = nil end,
  }
end
package.preload['json'] = function()
  return {
    -- 长度可控的假 JSON: 本测试只关心"多长的值能不能落盘", 不关心内容
    encode = function() return string.rep('a', blob_len) end,
    decode = function() return {} end,
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
    print(string.format('FAIL: %s (原因里该有 %q, 实际 %q)', what, sub, tostring(s)))
    fails = fails + 1
  end
end

-- 正常路径
blob_len, set_ret = 24, true
local ok, err = cfg.save_poll({ slave = 1, regs = { { addr = 100, name = 'a', dtype = 'uint16' } } })
eq(ok, true, '小配置能存')
eq(err, nil, '成功时不带原因')
eq(set_calls, 1, '落盘调用一次')
eq(store['ds_poll'], string.rep('a', 24), '值真进了 fskv')
eq(cfg.poll_src(), 'fskv', 'poll_src 认出已保存过')

-- 上限边界: 正好 4096 该放过去, 超一个字节必须在进 fskv 之前拦下
blob_len = FSKV_MAX
ok = cfg.save_poll({ slave = 1, regs = {} })
eq(ok, true, '正好 4096B 允许写')
eq(set_calls, 2, '4096B 真的发给了 fskv')

blob_len = FSKV_MAX + 1
local v_before = cfg.version()
ok, err = cfg.save_poll({ slave = 1, regs = {} })
eq(ok, false, '4097B 必须失败')
has(err, '4096', '失败原因带单值上限')
has(err, '4097', '失败原因带实际字节数')
eq(set_calls, 2, '超限的值根本没送到 fskv (不浪费一次 flash 擦写)')
eq(cfg.version(), v_before, '写失败不得涨配置版本号 (缓存白失效)')

-- fskv 明确返回 false (60 点那次的 not enough memory): 不能再报成功
blob_len = 3900   -- 低于 4096, 拦不住, 只能看返回值
set_ret = false
v_before = cfg.version()
ok, err = cfg.save_poll({ slave = 1, regs = {} })
eq(ok, false, 'fskv 返回 false 必须判失败')
has(err, '拒写', '失败原因说明是被 fskv 拒的')
eq(cfg.version(), v_before, '同样的失败不触发缓存失效')

-- 某版 bsp 成功时不返值: 只认【明确的 false】, 这条守住不能把正常保存判死
set_ret = nil
ok, err = cfg.save_poll({ slave = 1, regs = {} })
eq(ok, true, 'fskv.set 无返回值时按成功处理 (不能误伤所有保存)')

-- C 层 raise 也不能把整条 W:CFG 打崩
set_ret = 'raise'
ok, err = cfg.save_poll({ slave = 1, regs = {} })
eq(ok, false, 'fskv.set 抛错时返回失败而不是冒泡')
has(err, '拒写', '抛错也走同一条失败原因')

-- 其它槽共用同一个闸: ds_infer(sniff 推断表)一样会超 4096
set_ret = true
blob_len = 6000
ok, err = cfg.save_infer({ slave = 1, regs = {} })
eq(ok, false, '推断表同样受 4096 闸约束')
has(err, '4096', '推断表的失败原因也带上限')

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print('PASS: cfg.kv_set —— 假成功已封死 (超限拦截 + 返回值判定 + 不误伤无返回值固件)')
