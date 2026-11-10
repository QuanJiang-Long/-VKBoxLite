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
-- 2026-11-10 加了【stall 时钟重定基】的用例 (见 sync_running): 128 点配置
--   落盘失败那台设备, poll 于 uptime=1117 起来, uptime=1120 的 monitor 算出
--   stall=611s 直接重启 —— 用户看到"改完配置 3 秒后设备自己重启"。
--
-- 跑法(仓库根目录):  lua tests/lua/test_guard_modes.lua
--   也可以走 tools/run_lua_tests.bat (它会先把 firmware/ 挂进 package.path)

if package and package.path then
  package.path = 'firmware/?.lua;firmware/?/init.lua;' .. package.path
end

-- ---- 假环境: 只喂 guard 用到的那几个入口 ----
-- engine_running 模拟 poll/mon 的 is_running(); mode_now 模拟 ctrl.get_mode();
-- sys 用协程假跑, 这样测试能自己推进 ticks (guard 里 ticks 是模块私有局部,
-- 没有别的办法让它走起来 —— status().uptime==1 那条断言就是保证这套
-- 桩真的接上了, 用例不会悄悄变成空跑)
local engine_running = false
local mode_now = 'manual'
local rebooted = 0
local tasks, timers = {}, {}

local function stub(name, t) package.preload[name] = function() return t end end
stub('bus/poll', {
  is_running = function() return engine_running end,
  status = function() return { rounds = 1, ok = 1, timeout = 0, werr = 0 } end,
})
stub('bus/mon', { is_running = function() return engine_running end })
stub('bus/ctrl', { get_mode = function() return mode_now end })
stub('rtos', {
  meminfo = function() return 307192, 1000 end,
  reboot = function() rebooted = rebooted + 1 end,
})
stub('sys', {
  wait = function() coroutine.yield() end,
  taskInit = function(fn)
    local co = coroutine.create(fn)
    tasks[#tasks + 1] = co
    coroutine.resume(co)
  end,
  timerLoopStart = function(fn) timers[#timers + 1] = fn end,
})

-- guard.init() 起了两个循环: tasks[1]=feed_loop tasks[2]=tick_loop。
-- 每 resume 一轮, tick_loop 往前一跳(1 秒)
local function advance(n)
  for _ = 1, n do
    for i = 1, #tasks do coroutine.resume(tasks[i]) end
  end
end

local guard = dofile('firmware/svc/guard.lua')

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

-- 12-fix (2026-10-27): stall 判据除了"档位"还要看"采集引擎是否在跑"。
-- 起因: manual 档但寄存器表是空的 → poll 没起 → 没人喂心跳 → stall 一路
-- 涨到 120 → AUTO_REBOOT 自动重启 (现场踩过, 设备看着好好的却自己重启)。
-- 判据: 引擎没起 = 没有采集任务, 心跳停是正常状态, 不判 stall;
--       引擎起了但卡死 = is_running() 仍为 true, stall 照常累积, 看门狗不退化。
eq(guard.stall_of('idle'), nil, 'idle 档不判 stall')
eq(guard.stall_of('manual'), nil, 'manual 档但采集引擎没起 → 不判 stall')
eq(guard.stall_of('platform'), nil, 'platform 档但采集引擎没起 → 不判 stall')
eq(guard.stall_of('sniff'), nil, 'sniff 档但旁听没起 → 不判 stall')

-- ============ stall 时钟重定基 (2026-11-10) ============
guard.init()
eq(guard.status().uptime, 1, '假 sys 能把 ticks 推起来 (本段用例的前提)')

-- 引擎停着 610 秒(现场是从 uptime=509 一直停到 1117), 这段时间不判 stall
mode_now = 'manual'
engine_running = false
advance(610)
eq(guard.stall_of('manual'), nil, '引擎停 610s 期间不判 stall')

-- 引擎重新起来的那一刻: 必须从 0 开始, 不能拿停机期间的陈旧 last_alive 算差值
engine_running = true
eq(guard.stall_of('manual'), 0, '引擎刚起来那一拍 stall=0 (修前是 611)')
rebooted = 0
timers[1]()
eq(rebooted, 0, '引擎刚起来那一拍 monitor 不得重启')

-- 看门狗没退化: 引擎在跑但一直不喂心跳, 超过 STALL_LIMIT_S 照样自愈重启
advance(121)
eq(guard.stall_of('manual') >= 121, true, '引擎在跑但不喂 → stall 照常累积')
rebooted = 0
timers[1]()
eq(rebooted >= 1, true, 'stall 超 120s 仍然自愈重启 (判据收紧不等于放松)')

-- 喂一次心跳就归零
guard.alive()
eq(guard.stall_of('manual'), 0, 'alive() 喂过之后 stall 归零')

-- 换档也要重定基: ctrl 切档是 stop→start, is_running 不一定被 monitor 采样到
-- 中间的 false, 所以按 (档位, 运行) 这个组合的跳变来判, 而不只看运行位
advance(5)
eq(guard.stall_of('manual'), 5, '同档连续拍: stall 正常按秒累积')
mode_now = 'platform'
eq(guard.stall_of('platform'), 0, '切档那一拍也重定基')

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print('PASS: guard stall 判据 —— 档位覆盖 manual/poll/platform/sniff、引擎没起不判、'
  .. '起停/换档时时钟重定基、不喂心跳超 120s 照常自愈 (22 个断言通过)')
