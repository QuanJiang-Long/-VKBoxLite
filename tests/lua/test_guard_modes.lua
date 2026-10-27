-- test_guard_modes.lua —— guard stall 判定的模式覆盖单元测试 (2026-10)
--
-- 背景: guard.monitor 的 stall 判据 (心跳停喂 > STALL_LIMIT_S 后报错,
--   AUTO_REBOOT=true 时自愈重启) 原本只覆盖 manual/poll 两档。实际:
--   platform 档也在跑 poll 循环 (poll.lua 一直在喂心跳), sniff 档的
--   mon.task/auto_detect 原本根本不喂 —— 旁听卡死 guard 发现不了。
--   修法: is_active_mode 把 manual/poll/platform/sniff 全部纳入,
--   sniff 循环接入 guard.alive() 心跳; idle/stop 不算 (无采集在跑,
--   心跳停是正常状态, 不能当 stall)。
--
-- 跑法(仓库根目录):  lua tests/lua/test_guard_modes.lua

package.path = 'lua/?.lua;' .. package.path
local guard = dofile('lua/svc/guard.lua')

local fails = 0
local function eq(a, b, what)
  if a ~= b then
    print(string.format('FAIL: %s (期望 %s, 实际 %s)', what, tostring(b), tostring(a)))
    fails = fails + 1
  end
end

-- 参与心跳判定的档位: 四个都不能漏
eq(guard.is_active_mode('manual'), true, 'manual 档纳入 stall 判定')
eq(guard.is_active_mode('poll'), true, 'poll (历史别名) 纳入')
eq(guard.is_active_mode('platform'), true, 'platform 档纳入 (平台档同样跑 poll 循环)')
eq(guard.is_active_mode('sniff'), true, 'sniff 档纳入 (旁听循环喂心跳)')

-- 不该误判成活动的档位: idle/stop 下设备没有采集在跑,
-- 心跳自然是停的, 若纳入判定会在设备一停下来就误触重启
eq(guard.is_active_mode('idle'), false, 'idle 不算活动 (未采集, 心跳停是正常)')
eq(guard.is_active_mode('stop'), false, 'stop 不算活动')
eq(guard.is_active_mode(''), false, '空串不算活动')
eq(guard.is_active_mode(nil), false, 'nil 不算活动')

-- 模块在纯 Lua 环境能整体加载且 status() 可调用 (无 hard 依赖泄漏)
local ok, st = pcall(guard.status)
eq(ok, true, 'guard.status() 无环境依赖可调')

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print('PASS: guard.is_active_mode —— stall 判定覆盖 manual/poll/platform/sniff, idle/stop 不误判 (9 个断言通过)')
