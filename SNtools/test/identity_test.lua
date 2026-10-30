--[[
@module  test/identity_test.lua
@brief   设备身份降级链单测

注意：chip_uid 现在统一是大写十六进制（见 identity.lua 的 to_hex_uid）。
mcu.unique_id() 返回原始二进制，直接拼文本协议会把控制字符带出去，
PC 端显示乱码且 0x00 会截断 C 字符串，所以设备端就转成 hex。
mock 里 unique_id 返回 "UID0123456789ABCDEF"，转 hex 后是下面这个值。
]]

local UID_HEX = "55494430313233343536373839414243444546"

test("SN 就绪：clientid = 软 SN", function()
    local identity = require "identity"
    local sn_core  = require "sn_core"
    identity.init()
    sn_core.write(VS("SNID0000001"))
    local t = identity.get()
    eq(t.clientid, VS("SNID0000001"))
    eq(t.sn, VS("SNID0000001"))
    eq(t.sn_status, "normal")
    eq(t.chip_uid, UID_HEX)
end)

test("SN 空 + 有 IMEI：clientid = pending_ + IMEI", function()
    local identity = require "identity"
    local sn_core  = require "sn_core"
    _G.mobile_imei = "460001234567890"
    identity.init()
    sn_core.init()
    local t = identity.get()
    eq(t.sn, "")
    eq(t.sn_status, "unset")
    eq(t.clientid, "pending_460001234567890")
    eq(t.imei, "460001234567890")
end)

test("SN 空 + 无 IMEI：降级到芯片 UID", function()
    local identity = require "identity"
    local sn_core  = require "sn_core"
    _G.mobile_imei = nil
    identity.init()
    sn_core.init()
    local t = identity.get()
    eq(t.clientid, "pending_" .. UID_HEX)
    eq(t.chip_uid, UID_HEX)
end)

test("mobile.sn 优先于 imei", function()
    local identity = require "identity"
    local sn_core  = require "sn_core"
    _G.mobile_sn   = "MODSN12345"
    _G.mobile_imei = "460001234567890"
    identity.init()
    sn_core.init()
    eq(identity.get().clientid, "pending_MODSN12345")
end)

test("mobile.sn API 缺失时安全降级，不崩溃", function()
    local identity = require "identity"
    local sn_core  = require "sn_core"
    local saved = mobile.sn
    mobile.sn = nil
    _G.mobile_imei = "460009999999999"
    identity.init()
    sn_core.init()
    eq(identity.get().clientid, "pending_460009999999999")
    mobile.sn = saved
end)

test("身份结构字段完整（含 fw 版本）", function()
    local identity = require "identity"
    local sn_core  = require "sn_core"
    _G.VERSION = "1.0.2"
    identity.init()
    sn_core.init()
    local t = identity.get()
    eq(t.fw, "1.0.2")
    eq(t.sn_status, "unset")
    truthy(type(t.clientid) == "string" and #t.clientid > 0)
end)
