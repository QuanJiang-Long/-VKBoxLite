-- test_codesize.lua —— 量每个模块的【常驻堆成本】(2026-10-28, 12-fix-7 配套诊断)
--
-- 为什么需要: 现场(2026-10-28 16:54) U4 停发, 根因是 300KB 的 Lua 堆
--   被 churn 切碎 + 常驻太高(222KB/300KB)。常驻里最大的一块不是数据,
--   是【代码】—— 现场 idle 基线就有 ~190KB, 而 sniff 用不到的东西
--   (轮询引擎 bus/poll、平台配置拉取 iot/pullcfg)照样常驻。
--
-- 量法: require 之前 collectgarbage("collect") 两次, require 之后量 count 增量。
--   ⚠️ 两个偏差, 看数时心里有数:
--     1) 依赖会被先加载的模块"预热" —— 谁第一个 require 谁付全款,
--        所以列表顺序决定了这个数落在谁头上(ctrl 那一行 109KB 就是
--        它顺手把 iot/mqttcfg 拉进来了, 不是 ctrl 自己有 109KB)。
--     2) Lua 的 chunk 会保留【源文件字符串】(报错信息要用), 所以
--        模拟器上的数 ≈ 源码 + 字节码 + 常量, 比设备(.lc 无源码)偏大。
--   结论用【相对大小】看: 谁大谁小, 谁在 sniff 档用不到。
--
-- ⚠️ 12-fix-8 (2026-10-28): 加了【启动路径回归断言】——
--   现场崩溃(18:28:35 VM exit)的根因之一是常驻太高: Lua 堆 307192 字节,
--   idle 基线就 186KB, 池用满 98.6% 时连协程栈都分配不出来。
--   bus/poll + iot/pullcfg 改成惰性 require 之后, sniff 档的启动路径
--   绝不能把这两个模块拉进来 —— 一旦有人写回无条件 require, 这条断言
--   会立刻炸, 而不是等到现场烧上去才发现。
--
-- 跑法: tools\run_lua_tests.bat test_codesize.lua

local STARTUP = {
    "core/config",
    "util",
    "util/mqtt_util",
    "bus/mbus",
    "data/collector",
    "cfg",
    "bus/mon",
    "bus/ctrl",
    "iot/pubsched",
    "iot/iot",
    "svc/cmd",
    "svc/guard",
    "sn/sn",
    "sn/prov",
}

-- ===== 第一段: 启动路径断言 (12-fix-8) =====
collectgarbage("collect")
collectgarbage("collect")
local c0 = collectgarbage("count")
for _, m in ipairs(STARTUP) do
    local ok, err = pcall(require, m)
    if not ok then
        print(string.format("[FAIL] 启动路径加载 %s 失败: %s", m, tostring(err)))
    end
end
collectgarbage("collect")
collectgarbage("collect")
local c1 = collectgarbage("count")

print(string.format("启动路径(%d 个模块)常驻: %.1f KB", #STARTUP, c1 - c0))

-- sniff 档绝对不该加载的两个。
-- ⚠️ 模拟器的 package 表里没有 loaded 字段(LuatOS 精简过), 没法从外面查,
--    所以由 bus/ctrl / svc/cmd / iot/iot 自己报"我到底加载没加载 poll/pullcfg"。
local ctrl = require "bus/ctrl"
local cmd = require "svc/cmd"
local iot = require "iot/iot"

local bad = {}
if ctrl.poll_loaded() then bad[#bad + 1] = "bus/ctrl 拉起了 bus/poll" end
if cmd.poll_loaded() then bad[#bad + 1] = "svc/cmd 拉起了 bus/poll" end
if iot.pullcfg_loaded() then bad[#bad + 1] = "iot/iot 拉起了 iot/pullcfg" end
if #bad > 0 then
    print(string.format("[FAIL] 启动路径不该加载却加载了: %s", table.concat(bad, "; ")))
else
    print("[PASS] 启动路径没有拉起 bus/poll / iot/pullcfg (sniff 档白占的常驻堆)")
end

-- ===== 第二段: 逐模块量常驻成本 =====
local MODS = {
    "core/config",
    "util",
    "util/mqtt_util",
    "bus/mbus",
    "data/collector",
    "cfg",
    "bus/mon",
    "bus/poll",
    "bus/ctrl",
    "iot/pubsched",
    "iot/pullcfg",
    "iot/iot",
    "svc/cmd",
    "svc/guard",
    "sn/sn",
    "sn/prov",
}

local total = 0
local rows = {}
for _, m in ipairs(MODS) do
    collectgarbage("collect")
    collectgarbage("collect")
    local b0 = collectgarbage("count")
    local ok = pcall(require, m)
    collectgarbage("collect")
    collectgarbage("collect")
    local b1 = collectgarbage("count")
    if ok then
        local kb = b1 - b0
        total = total + kb
        rows[#rows + 1] = { m = m, kb = kb }
        print(string.format("%-16s %8.1f KB", m, kb))
    else
        print(string.format("%-16s   (加载失败)", m))
    end
end

table.sort(rows, function(a, b) return a.kb > b.kb end)
print("")
print("== 按大小排序 ==")
for _, r in ipairs(rows) do
    print(string.format("%-16s %8.1f KB", r.m, r.kb))
end
print(string.format("\n合计 %.1f KB (设备上代码 + 常量 ≈ 这个量级)", total))

-- sniff 档用不到却常驻的: 轮询引擎 + 平台配置拉取
local sniff_unused = 0
for _, r in ipairs(rows) do
    if r.m == "bus/poll" or r.m == "iot/pullcfg" then
        sniff_unused = sniff_unused + r.kb
    end
end
print(string.format("sniff 档用不到却常驻的: %.1f KB (12-fix-8 起已改成惰性 require)", sniff_unused))
