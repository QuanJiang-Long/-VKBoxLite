-- test_infer_acc.lua —— 推断表常驻累加器的单测 (2026-10-28, 12-fix-6)
--
-- 背景: 老 infer() 每次拿 collector 的【最后 10 帧】重建整张表 —— 总线上一圈
--   轮询的地址有几十个(现场 48 个), 10 帧只够看见 5 个请求, 表在两组地址
--   之间来回跳: 前端每刷新一次看到的都不一样(用户 2026-10-28 反馈),
--   拓扑签名跟着每 30 秒变一次, 平台每 30 秒重建一次模型。
--   现在改成常驻累加器: 请求里出现过的地址只进不出, 序号按【发现顺序】发。
--
-- 本测试钉住这几条:
--   ① 地址只增不减, 新的追加在后面, 老的不动
--   ② hits 真累计(老表每次重建都归 1)
--   ③ 没应答的地址也进表, 标 no_rsp
--   ④ 行数封顶 128 (MAX_INFER_ROWS)
--   ⑤ 行集合变了能通知前端(dirty), watch 开关管住推不推
--
-- 跑法(仓库根目录):  tools\run_lua_tests.bat test_infer_acc.lua

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

local mon = require "bus/mon"

-- 1) 干净起点
mon.test_reset_acc()
local inf = mon.infer(true)
eq(#inf.regs, 0, '一开始没有行')
eq(inf.ignored, 0, '一开始没有"没应答"的地址')

-- 2) 请求里的地址进表, 命中次数累计
mon.test_note_req(1, 100, 3, 3)      -- 主站读 100/101/102
inf = mon.infer(true)
eq(#inf.regs, 3, '3 个 slot → 3 行')
eq(inf.regs[1].addr, 100, '第一行是 100')
eq(inf.regs[3].addr, 102, '第三行是 102')
eq(inf.regs[1].hits, 1, '命中 1 次')
eq(inf.regs[1].answered, false, '还没应答')
eq(inf.ignored, 3, '3 个地址都没应答')

mon.test_note_req(1, 100, 3, 3)      -- 同一段再被读一次
inf = mon.infer(true)
eq(inf.regs[1].hits, 2, '同一个地址再被请求一次 → hits 累加(老表永远归 1)')
eq(#inf.regs, 3, '行数不变(不重复建行)')

-- 3) 应答回填: 值/类型/置信度/状态
mon.test_note_rsp(1, 100, 1234, 'uint16', 100)
inf = mon.infer(true)
eq(inf.regs[1].value, 1234, '值回填')
eq(inf.regs[1].dtype, 'uint16', '类型回填')
eq(inf.regs[1].conf, 100, '置信度回填')
eq(inf.regs[1].answered, true, '标成已应答')
eq(inf.ignored, 2, '还剩 2 个地址没应答')

-- 4) ★ 核心: 新地址【追加】在后面, 老地址【不动】
mon.test_note_req(1, 500, 1, 3)
inf = mon.infer(true)
eq(#inf.regs, 4, '多了 1 行')
eq(inf.regs[4].addr, 500, '新地址排在最后(发现顺序)')
eq(inf.regs[1].addr, 100, '老地址还在原来的位置(序号不变)')
eq(inf.regs[1].hits, 2, '老地址的命中次数不受影响')

-- 5) 序号 = 行在表里的位置(= 发现顺序), 设备不单独存 seq 字段
eq(inf.regs[1].addr, 100, '序号 1 = 最早发现的 100')
eq(inf.regs[4].addr, 500, '序号 4 = 最后发现的 500')
eq(inf.regs[1].seq, nil, '设备不存 seq 字段(省哈希槽, 序号按位置算)')

-- 6) 多从机: 同名地址在不同从机上是不同的行
mon.test_note_req(2, 100, 1, 3)
inf = mon.infer(true)
eq(#inf.regs, 5, '另一个从机的同名地址是另一行')
eq(#inf.slaves, 2, '2 个从机')

-- 7) 上限: MAX_INFER_ROWS = 128 (超出不再建行, 但要计数)
mon.test_reset_acc()
for i = 0, 200 do mon.test_note_req(1, i, 1, 3) end
inf = mon.infer(true)
eq(#inf.regs, 128, '行数封顶在 128')
eq(mon.status().infer_rows, 128, 'status 里的行数也是 128')
ok(mon.status().infer_clamped > 0, '超上限的行有计数(clamped)')

-- 8) dirty: 行集合变了要能通知前端
mon.test_reset_acc()
eq(mon.take_infer_dirty(), false, '一开始没有变化')
mon.test_note_req(1, 1, 1, 3)
eq(mon.take_infer_dirty(), true, '多了新地址 → dirty')
eq(mon.take_infer_dirty(), false, '取过就没了(不重复推)')
mon.test_note_req(1, 1, 1, 3)        -- 老地址再被请求: 行集合没变
eq(mon.take_infer_dirty(), false, '老地址重复出现不算变化(不推)')
mon.test_note_req(1, 2, 1, 3)        -- 新地址
eq(mon.take_infer_dirty(), true, '又多了新地址 → 再推')

-- 9) watch 开关: 前端面板关着就别推
eq(mon.infer_watch(), false, '默认不推')
mon.set_infer_watch(true)
eq(mon.infer_watch(), true, '打开 watch')
eq(mon.take_infer_dirty(), true, '打开 watch 时补推一次当前表(表里可能已经有东西)')
mon.set_infer_watch(false)
eq(mon.infer_watch(), false, '关掉 watch')

-- 10) 复位: 一轮 sniff 的表不能串到下一轮
mon.test_reset_acc()
mon.test_note_req(1, 7, 2, 3)
eq(#mon.infer(true).regs, 2, '复位前有 2 行')
mon.test_reset_acc()
eq(#mon.infer(true).regs, 0, '复位后清空(新 sniff 从零开始)')
eq(mon.infer(true).regs[1], nil, '复位后没有残留行')

-- 11) 内存账: 现场的 48 个地址, 累加器占多少堆
--   12-fix-5/6 的教训: 堆只有 307KB, 常驻结构每 1KB 都是从余量里抠的。
--   现场 sniff 实测活对象 ~213KB, 所以这 48 行必须控制在 12KB 以内。
mon.test_reset_acc()
collectgarbage("collect")
local kb0 = collectgarbage("count")
for i = 0, 47 do
  mon.test_note_req(1, i * 10, 1, 3)
  mon.test_note_rsp(1, i * 10, i, 'uint16', 100)
end
collectgarbage("collect")
local kb1 = collectgarbage("count")
local used_kb = kb1 - kb0
print(string.format('  累加器 48 行占 %.1f KB (每行 %.0f 字节)', used_kb, used_kb * 1024 / 48))
ok(used_kb > 0.5, '48 行确实占了堆(测出了)')
ok(used_kb < 12, '48 行的累加器占用在 12KB 以内')

-- 11b) ⚠️ 字段数 ≤8 的红线: Lua 表的哈希槽按 2 的幂走, 第 9 个字段就把
--   8 槽撑成 16 槽 —— 每行 203 → 363 字节(实测), 48 行多占 8KB 堆。
--   以后谁给推断行加字段, 这个断言会先炸。
local nf = 0
for _ in pairs(mon.infer(true).regs[1]) do nf = nf + 1 end
ok(nf <= 8, '推断行的字段数 ≤ 8 (现在 ' .. nf .. ' 个)')

-- 12) ⚠️ attach_names 必须【复制】而不是就地改: 就地改会给活着的行加
--   id/name → 第 9/10 个字段 → 哈希槽 8 → 16 → 每行 203 → 363 字节
--   (实测), 现场的 48 行就是 +7.7KB 常驻堆。
local ok_iot, iot = pcall(require, "iot/iot")
if ok_iot then
  mon.test_reset_acc()
  mon.test_note_req(1, 100, 1, 3)
  mon.test_note_rsp(1, 100, 7, 'uint16', 90)
  local live = mon.infer(true)
  local named = iot.attach_names(live)
  local nf = 0
  for _ in pairs(live.regs[1]) do nf = nf + 1 end
  ok(nf <= 8, 'attach_names 之后活着的行还是 ≤8 字段 (现在 ' .. nf .. ' 个)')
  eq(live.regs[1].id, nil, '活着的行没被就地加 id')
  eq(named.regs[1].id, 'reg100', '复制出来的那份带上了 id')
  eq(named.regs[1].name, 'reg100', '复制出来的那份带上了 name')
  eq(named.regs[1].value, 7, '复制出来的那份值没丢')
else
  print('  (跳过 attach_names 用例: iot/iot 在本环境装不上)')
end

if fails > 0 then
  print(string.format('FAIL: %d 个断言不过', fails))
  os.exit(1)
end
print('PASS: 推断表累加器 —— 只增不减 / hits 累计 / no_rsp 标记 / 128 封顶 / dirty+watch')
