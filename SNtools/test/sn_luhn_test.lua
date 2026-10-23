--[[
@module  test/sn_luhn_test.lua
@brief   Luhn 校验位算法单测
@detail  与 PC 端 pc_tool/sn_rule.py 是同一套算法的两份实现，
           两边必须给出一致结果，否则设备会拒收工装生成的号。
           所以这里把「已知向量」钉死，PC 端用同一批向量对拍。
]]

local luhn = require "sn_luhn"

--=====================================================================
-- 1. 已知向量（check_digit）
--    前两条是"标准定义"锚点：完整号码按标准 Luhn 校验必须 VALID。
--    改算法必须先改这里，且两条路径必须同时成立。
--=====================================================================
test("check_digit 已知向量", function()
    eq(luhn.check_digit("1180202609020001"), "7")   -- 方案确认的那条
    eq(luhn.check_digit("7992739871"), "3")          -- 维基百科样例的 payload
    eq(luhn.check_digit("0"), "0")
    eq(luhn.check_digit("1"), "8")
    eq(luhn.check_digit("18"), "2")
    eq(luhn.check_digit("123456789012"), "8")
end)

test("verify 锚点：维基百科样例必须 VALID", function()
    eq(luhn.verify("79927398713"), true)   -- 教科书样例，算法错了这里就挂
    eq(luhn.verify("18"), true)
end)

test("verify 接受正确校验位", function()
    eq(luhn.verify("11802026090200017"), true)
    eq(luhn.verify("18"), true)
end)

test("verify 拒绝错误校验位", function()
    local ok, err = luhn.verify("11802026090200014")  -- 末位 4 应为 7
    eq(ok, false)
    eq(err, "checksum invalid")
end)

test("自洽性：make() 出来的号码 verify() 必须全过", function()
    -- 这条是双实现互证：check_digit 从 payload 正推，verify 按标准定义反推。
    -- 历史上两条路径同时犯错过（偶数位 payload 翻倍奇偶性反转），
    -- 所以这里对奇/偶/长/短各长度都跑一遍。
    local bodies = {
        "0", "1", "18", "123456789012",
        "1180202609020001",                    -- 16 位偶数
        "7992739871",                          -- 10 位偶数
        "79927398713",                         -- 11 位奇数
        string.rep("9", 17), string.rep("9", 18),
        "1000000000000000", "9999999999999999",
    }
    for _, b in ipairs(bodies) do
        local full, err = luhn.make(b)
        truthy(full, err)
        eq(luhn.verify(full), true)
        -- 且完整号码长度 = 主体 + 1
        eq(#full, #b + 1)
    end
end)

test("verify 能查出单位错", function()
    -- 任意改一位都必须验不过（Luhn 的核心保证）
    local good = "11802026090200017"
    for i = 1, #good do
        local c = good:sub(i, i)
        local d = (c == "9") and "8" or (tostring(tonumber(c) + 1))
        local bad = good:sub(1, i - 1) .. d .. good:sub(i + 1)
        if bad ~= good then
            eq(luhn.verify(bad), false)
        end
    end
end)

test("make 拼出主体+校验位", function()
    eq(luhn.make("1180202609020001"), "11802026090200017")
    eq(luhn.make("7992739871"), "79927398713")
end)

test("非数字输入被拒，不崩", function()
    eq(luhn.check_digit("VK2609"), nil)
    eq(luhn.check_digit(""), nil)
    eq(luhn.check_digit(nil), nil)
    eq(luhn.verify("VK260900000042"), false)
    eq(luhn.verify("1"), false)          -- 太短
    eq(luhn.make("VK2609"), nil)
end)

--=====================================================================
-- 2. 与 sn_core 规则联动
--=====================================================================
test("sn_core.validate 启用 luhn 后拒收错校验位", function()
    local sn_core = require "sn_core"
    sn_core.rules.checksum = "luhn"
    local ok, err = sn_core.validate("11802026090200014")
    eq(ok, false)
    eq(err, "checksum invalid")
    eq(sn_core.validate("11802026090200017"), true)
end)

test("含字母的历史号不做 Luhn，只过字符/长度规则", function()
    local sn_core = require "sn_core"
    sn_core.rules.checksum = "luhn"
    -- 老数据是字母数字混合，不能因开启校验位就被判脏数据；
    -- 长度仍要满足当前规则，所以用 17 位
    local ok, err = sn_core.validate("SNREWORK0001ABCDEF")
    eq(ok, true)
end)

test("关闭 checksum 后纯长度/字符规则仍生效", function()
    local sn_core = require "sn_core"
    sn_core.rules.checksum = nil
    eq(sn_core.validate("11802026090200014"), true)     -- 不校验位就放过
    eq(sn_core.validate("bad sn!1234567890"), false)    -- 字符规则仍在
end)
