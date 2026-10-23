--[[
@module  test/report_test.lua
@brief   上行报文统一注入层单测
]]

-- chip_uid 现为大写十六进制，见 identity.lua 的 to_hex_uid
local UID_HEX = "55494430313233343536373839414243444546"

test("空态上报：注入 sn_status=unset、chip_uid", function()
    local identity = require "identity"
    local sn_core  = require "sn_core"
    identity.init()
    sn_core.init()
    local p = require("report").attach({ temp = 25.0 })
    eq(p.temp, 25.0)
    eq(p.sn, "")
    eq(p.sn_status, "unset")
    eq(p.chip_uid, UID_HEX)
end)

test("就绪态上报：注入正确 SN 与 normal", function()
    local identity = require "identity"
    local sn_core  = require "sn_core"
    identity.init()
    sn_core.write(VS("SNREP000001"))
    local p = require("report").attach({ temp = 25.0 })
    eq(p.sn, VS("SNREP000001"))
    eq(p.sn_status, "normal")
end)

test("注入不破坏业务字段，返回同一张表", function()
    local identity = require "identity"
    local sn_core  = require "sn_core"
    identity.init()
    sn_core.init()
    local origin = { a = 1, b = "x" }
    local p = require("report").attach(origin)
    eq(p, origin)
    eq(p.a, 1)
    eq(p.b, "x")
end)
