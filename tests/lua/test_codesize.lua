-- test_codesize.lua —— 量每个模块的【常驻堆成本】(2026-10-28, 12-fix-7 配套诊断)
--
-- 为什么需要: 现场(2026-10-28 16:54) U4 停发, 根因是 300KB 的 Lua 堆
--   被 churn 切碎 + 常驻太高(222KB/300KB)。常驻里最大的一块不是数据,
--   是【代码】—— 现场 idle 基线就有 ~190KB, 而 sniff 用不到的东西
--   (轮询引擎 bus/poll、平台配置拉取 iot/pullcfg、SN 烧录 sn/sn)照样常驻。
--
-- 量法: require 之前 collectgarbage("collect") 两次, require 之后量 count 增量。
--   ⚠️ 两个偏差, 看数时心里有数:
--     1) 依赖会被先加载的模块"预热" —— 谁第一个 require 谁付全款,
--        所以列表顺序决定了这个数落在谁头上(ctrl 那一行 118KB 就是
--        它顺手把 iot/mqttcfg 拉进来了, 不是 ctrl 自己有 118KB)。
--     2) Lua 的 chunk 会保留【源文件字符串】(报错信息要用), 所以
--        模拟器上的数 ≈ 源码 + 字节码 + 常量, 比设备(.lc 无源码)偏大。
--   结论用【相对大小】看: 谁大谁小, 谁在 sniff 档用不到。
--
-- 跑法: tools\run_lua_tests.bat test_codesize.lua

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
    local c0 = collectgarbage("count")
    local ok = pcall(require, m)
    collectgarbage("collect")
    collectgarbage("collect")
    local c1 = collectgarbage("count")
    if ok then
        local kb = c1 - c0
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

-- sniff 档用不到的三个: 轮询引擎 / 平台配置拉取 / SN 烧录
local sniff_unused = 0
for _, r in ipairs(rows) do
    if r.m == "bus/poll" or r.m == "iot/pullcfg" or r.m == "sn/sn" then
        sniff_unused = sniff_unused + r.kb
    end
end
print(string.format("sniff 档用不到却常驻的: %.1f KB", sniff_unused))
