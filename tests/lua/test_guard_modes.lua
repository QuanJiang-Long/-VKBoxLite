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
-- 2026-11-13 加了【Lua 池保险丝】的用例 (见 gc_fuse): 没烧 SN 的设备 iot 不
--   启动, 而所有完整回收都挂在 iot 那边 → 60 点跑到 used 302528/307192 时
--   一次回收都没跑过, 一个 672B 分配失败把 VM 打死。保险丝搬到 monitor 上。
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
-- 假 Lua 池读数 (2026-11-13 保险丝用例要改它): meminfo('lua') 的顺序是
-- total, used, 峰值
local lua_used_now = 1000
local lua_meminfo_fails = false

local function stub(name, t) package.preload[name] = function() return t end end
stub('bus/poll', {
  is_running = function() return engine_running end,
  status = function() return { rounds = 1, ok = 1, timeout = 0, werr = 0 } end,
})
stub('bus/mon', { is_running = function() return engine_running end })
stub('bus/ctrl', { get_mode = function() return mode_now end })
stub('rtos', {
  meminfo = function(what)
    if what == 'lua' and lua_meminfo_fails then error('not enough memory') end
    return 307192, lua_used_now, 307192
  end,
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

-- 抓 guard 打的日志行(保险丝那句话是给现场读的, 内容要钉住)。
--   util.log() 取的是【全局 log】, 所以必须在 dofile guard 之前挂好
local logs = {}
local function log_rec(tag, ...)
    local t = { tag }
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        t[#t + 1] = type(v) == 'string' and v or tostring(v)
    end
    logs[#logs + 1] = table.concat(t, ' ')
end
_G.log = { debug = log_rec, info = log_rec, warn = log_rec, error = log_rec }

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

-- ============ Lua 池保险丝 (2026-11-13) ============
-- 起因: 现场那台 SN 为空的设备, 60 点第一轮采集后 used 302528/307192, 一个
--   672 字节的分配拿不到 → prov.poll 抛 not enough memory → Lua VM exit,
--   15 秒后整机重启。全仓库的 collectgarbage("collect") 保险丝原先都在 iot
--   那边(reclaim_if_high / 12-fix-5), 而 main.lua 只在烧了 SN 才 iot.start()
--   —— 那台设备从头到尾一次完整回收都没跑过。保险丝搬到 guard 的心跳上:
--   它由定时器驱动, 和 SN/MQTT/档位都无关, 是唯一必然在跑的周期任务。
local collects = 0
local real_cg = collectgarbage
collectgarbage = function(op, ...)
    if op == 'collect' then collects = collects + 1 end
    return real_cg(op, ...)
end
local FUSE = require('core/config').GC_FUSE_FREE

local function find_line(pat)
    for i = #logs, 1, -1 do
        if logs[i]:find(pat, 1, true) then return logs[i] end
    end
    return nil
end

-- 剩余充足: 一次都不扫(常态零开销, 每拍都扫会把毫秒级停顿变成日常)
logs = {}
lua_used_now = 307192 - FUSE - 1
local before = collects
timers[1]()
eq(collects, before, '剩余 > GC_FUSE_FREE 不扫水')
eq(find_line('扫一轮'), nil, '没到水位不占日志')

-- 压到水位以下: 11-13 崩之前那一拍正是 used 302528 (剩 4664B)
lua_used_now = 302528
timers[1]()
eq(collects, before + 1, '剩 4664B(<=GC_FUSE_FREE) 扫一轮')
timers[1]()
eq(collects, before + 2, '还在水位以下就每拍都扫, 不是一次性放弃')

-- 那句话必须带【回收前后两个数】: 现场就靠这两个数判剩下的到底是垃圾还是
--   活对象 —— 差不多就是"下一刀砍常驻", 差得多就是"砍分配次数"。
--   (12-fix-8 早证过 GC 切不出连续大块, 光说"扫过了"没有决策价值)
local sweep_line = find_line('扫一轮')
eq(sweep_line ~= nil, true, '扫水打了一行日志')
eq(sweep_line and sweep_line:find('剩 4664', 1, true) ~= nil, true, '日志说了剩多少字节')
eq(sweep_line and sweep_line:find('302528->302528', 1, true) ~= nil, true,
    '日志带了回收前后的已用量')

-- meminfo 自己抛(池子见底时它真会抛): 保险丝不许把整拍心跳一起带走
lua_meminfo_fails = true
local mok = pcall(timers[1])
eq(mok, true, 'meminfo 抛异常时心跳照常跑完')
lua_meminfo_fails = false
lua_used_now = 1000

-- 阈值本身钉住: 判据必须是 rtos.meminfo('lua') 的真实字节。
--   照 collectgarbage('count') 定阈值等于在最需要的那一段永不触发(少报约 1/3)
eq(type(FUSE) == 'number' and FUSE >= 16384 and FUSE <= 65536, true, 'GC_FUSE_FREE 是个合理的字节数')

collectgarbage = real_cg

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print('PASS: guard stall 判据 —— 档位覆盖 manual/poll/platform/sniff、引擎没起不判、'
  .. '起停/换档时时钟重定基、不喂心跳超 120s 照常自愈; '
  .. '外加 Lua 池保险丝按真实剩余字节扫水、扫完打出前后水位 (31 个断言通过)')
