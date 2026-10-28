-- test_pubsched.lua —— 统一上报调度的单测 (2026-10-28, 12-fix-4)
--
-- 背景: 2026-10-28 现场 sniff 档跑到 5 分钟崩了 —— 堆被碎片化,
--   连 send_meta 里 table.concat 拼 600 字节都失败(还剩 31KB 空闲)。
--   根因是上报频率: published 从 112 涨到 213(126 秒发了 101 次 = 0.8 次/秒),
--   因为 S.dirty 被当成了"立刻发"。用户拍板: 统一上报调度, 最小间隔 30 秒。
--
-- 本测试验的正是"节流真的挡住了", 因为这是整件事的核心:
--   内容一直在变(changed 每秒都调) → 但 30 秒内不该发第二次。
--
-- 跑法(仓库根目录):  tools\run_lua_tests.bat test_pubsched.lua

local fails = 0
local function eq(a, b, what)
  if a ~= b then
    print(string.format('FAIL: %s (期望 %s, 实际 %s)', what, tostring(b), tostring(a)))
    fails = fails + 1
  end
end
local function ok(c, what)
  if not c then
    print('FAIL: ' .. what)
    fails = fails + 1
  end
end

local pubsched = require "iot/pubsched"

-- 假时钟: 秒级单调 + 墙钟, 两个都可注入
local fake = 1000.0        -- os.clock() 口径
local fake_wall = 1700000000
pubsched._set_clock(function() return fake end, function() return fake_wall end)
local function advance(sec)
  fake = fake + sec
  fake_wall = fake_wall + sec
end

-- 1) 第一次: 脏了就该立刻发(闸门不能把第一次也挡住)
pubsched.reset()
pubsched.changed("prop")
eq(pubsched.due("prop", 0), true, "刚置脏就能发(第一次不受闸门限制)")
pubsched.sent("prop")
eq(pubsched.due("prop", 0), false, "发完不脏了就不该再发")

-- 2) ★ 核心: 内容一直变, 但 30 秒内只能发一次
pubsched.changed("prop")
eq(pubsched.due("prop", 0), false, "刚发完又变了 → 闸门未到, 不发")
advance(10)
pubsched.changed("prop")
eq(pubsched.due("prop", 0), false, "过了 10 秒仍不到 30 秒 → 不发")
advance(19)
pubsched.changed("prop")
eq(pubsched.due("prop", 0), false, "过了 29 秒还不到 30 秒 → 不发")
advance(1)
eq(pubsched.due("prop", 0), true, "过了 30 秒 → 放行")

-- 3) 闸门被"消费": due 返回 true 之后, 立刻再问一次就不该再发
pubsched.sent("prop")
pubsched.changed("prop")
eq(pubsched.due("prop", 0), false, "sent() 之后闸门重新计时")

-- 4) 内容没变 → 不发(不管过多久), 直到兜底周期到
--    ⚠️ 用 sent() 而不是 reset() 来表示"刚发过、内容没再变" ——
--    reset() 会把各通道【置脏】(重连后要重新报一遍), 不是"清脏"
pubsched.reset()
pubsched.sent("prop")
advance(1000)
eq(pubsched.due("prop", 0), false, "内容没变 → 不发")
eq(pubsched.due("prop", 120), true, "兜底周期(interval_s=120)到了 → 发(哪怕没变)")

-- 5) 兜底不影响最小间隔: 兜底到点就发, 不看闸门
pubsched.reset()
pubsched.sent("prop")
advance(5)
eq(pubsched.due("prop", 0), false, "发了之后还没到兜底 → 不发")
advance(120)
eq(pubsched.due("prop", 120), true, "兜底到了 → 发")

-- 6) ready(): 纯时间闸门, 跟脏标记无关(拓扑用这个)
pubsched.reset()
eq(pubsched.ready("topo"), true, "ready 第一次就放行")
eq(pubsched.ready("topo"), false, "ready 消费掉闸门后立刻再问 → 不放行")
advance(29)
eq(pubsched.ready("topo"), false, "29 秒 → 还没到")
advance(1)
eq(pubsched.ready("topo"), true, "30 秒 → 放行")

-- 7) 三个通道互不干扰
pubsched.reset()
pubsched.changed("prop")
pubsched.changed("meta")
eq(pubsched.due("prop", 0), true, "prop 通道放行")
eq(pubsched.due("meta", 0), true, "meta 通道独立放行")

-- 8) reset() 让下一次能立刻发(重连场景), 并且把各通道置脏(重连要重新报一遍)
--    ⚠️ 必须先 reset: 上面 #7 的 due() 已经【消费】了 prop 通道的闸门
--    (due 返回 true 就把时间窗占了 —— 发送失败时不立刻重试, 正是设计意图:
--     OOM 时每秒重试只会把堆压得更碎)
pubsched.reset()
pubsched.changed("prop")
eq(pubsched.due("prop", 0), true, "第一次放行")
pubsched.sent("prop")
pubsched.changed("prop")
eq(pubsched.due("prop", 0), false, "闸门生效")
pubsched.reset()
eq(pubsched.due("prop", 0), true, "reset() 后立刻能发(重连场景)")
eq(pubsched.dirty("meta"), true, "reset() 把各通道置脏(重连要重新报一遍)")

-- 9) status(): 计数要对
local st = pubsched.status()
ok(st.prop ~= nil, "status 有 prop 通道")
ok(st.prop.sent >= 1, "status 记了发送次数")
ok(st.prop.blocked >= 1, "status 记了被闸门挡住的次数")
eq(st.prop.min_ms, 30000, "最小间隔 = 30 秒")

-- 10) ⚠️ 关键回归: 模拟现场 —— 内容每秒都变, 30 秒内只该发一次
pubsched.reset()
local sent_count = 0
for i = 1, 30 do
  pubsched.changed("prop")
  if pubsched.due("prop", 0) then
    sent_count = sent_count + 1
    pubsched.sent("prop")
  end
  advance(1)
end
eq(sent_count, 1, "30 秒内持续置脏 → 只发 1 次(原来会发 30 次)")

pubsched._set_clock(nil, nil)   -- 还原真时钟

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print("PASS: 上报调度 —— 30 秒闸门挡住高频 / 兜底独立 / 通道互不干扰 / reset 放行")
