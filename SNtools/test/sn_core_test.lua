--[[
@module  test/sn_core_test.lua
@brief   sn_core 单测：规则校验、状态机、唯一性防呆、回读、锁、回调

@detail  SN 一律用 VS("标签") 生成，不写死具体值——
          规则（长度/字符/校验位）演进时只改 run_all.lua 里的 VS()，
          测试代码不用动。详见 run_all.lua 的 VS 说明。
]]

-- 写入合法 SN -> ready 态并落盘
test("写入合法 SN -> ready 态并落盘", function()
    local sn_core = require "sn_core"
    sn_core.init()
    local sn = VS("SN20260101001")
    local ok, err = sn_core.write(sn)
    truthy(ok, err)
    eq(sn_core.state(), "ready")
    eq(get_device_sn(), sn)
    eq(require("sn_store_fskv").load(), sn)
    eq(sn_core.report_status(), "normal")
    eq(sn_core.meta().burn, 1)
end)

-- 规则校验
test("拒绝非法字符 / 超长 / 非字符串", function()
    local sn_core = require "sn_core"
    sn_core.init()
    local ok1, e1 = sn_core.write("bad sn!1234567890")     -- 17 字节但含非法字符
    local ok2, e2 = sn_core.write(string.rep("A", 33))
    local ok3, e3 = sn_core.write(12345)
    local ok4, e4 = sn_core.write(VS("SN20260101001"):sub(1, -2) .. "9")  -- 校验位改错
    eq(ok1, false); eq(e1, "char invalid")
    eq(ok2, false); eq(e2, "length invalid")
    eq(ok3, false); eq(e3, "not string")
    eq(ok4, false); eq(e4, "checksum invalid")
    eq(sn_core.state(), "empty")
end)

-- 边界：最短合法（17 位含校验位）
test("长度边界：17 位合法，16 位被拒", function()
    local sn_core = require "sn_core"
    sn_core.init()
    truthy(sn_core.write(VS("SNBOUND000001")))
    sn_core.clear()
    -- 16 位纯数字但差一位 -> length invalid
    eq(sn_core.write("118020260902000"), false)
end)

-- 持久化 / 重启恢复
test("重启后从 FSKV 恢复 ready", function()
    local sn_core = require "sn_core"
    sn_core.init()
    local sn = VS("SNRESTORE001")
    sn_core.write(sn)
    -- 模拟重启：清掉模块缓存重新加载
    package.loaded["sn_core"] = nil
    package.loaded["sn_store_fskv"] = nil
    sn_core = require "sn_core"
    sn_core.init()
    eq(sn_core.state(), "ready")
    eq(get_device_sn(), sn)
    eq(sn_core.meta().burn, 1)
end)

-- 脏数据
test("Flash 脏数据 -> invalid 态，且可被覆盖写", function()
    local sn_core = require "sn_core"
    fskv.set("dev_sn", "bad sn!")   -- 绕过写接口直接塞脏数据
    fskv.save()
    sn_core.init()
    eq(sn_core.state(), "invalid")
    eq(get_device_sn(), nil)
    eq(sn_core.report_status(), "unset")
    local ok, err = sn_core.write(VS("SNFIX000001"))
    truthy(ok, err)
    eq(sn_core.state(), "ready")
    eq(get_device_sn(), VS("SNFIX000001"))
end)

-- 唯一性防呆
test("唯一性防呆：已有 SN 时异值默认拒绝", function()
    local sn_core = require "sn_core"
    sn_core.init()
    sn_core.write(VS("SNUNIQ00001"))
    local ok, err = sn_core.write(VS("SNUNIQ00002"))
    eq(ok, false)
    eq(err, "sn exists")
    eq(get_device_sn(), VS("SNUNIQ00001"))
end)

-- 幂等
test("同值重复写：幂等，完全不碰 Flash", function()
    local sn_core = require "sn_core"
    sn_core.init()
    local sn = VS("SNIDEM00001")
    sn_core.write(sn)
    local before = fskv.save_count
    local ok, err = sn_core.write(sn)
    truthy(ok, err)
    eq(err, "same")
    eq(fskv.save_count, before)     -- 没有落盘
    eq(sn_core.meta().burn, 1)      -- 烧录次数没涨
end)

-- FORCE 覆盖
test("FORCE 覆盖写：允许，burn 追溯 +1", function()
    local sn_core = require "sn_core"
    sn_core.init()
    sn_core.write(VS("SNOLD000001"))
    local ok, err = sn_core.write(VS("SNNEW000001"), { force = true })
    truthy(ok, err)
    eq(get_device_sn(), VS("SNNEW000001"))
    eq(sn_core.meta().burn, 2)
end)

-- 烧录锁
test("烧录锁：锁定后拒绝写入与清除", function()
    local sn_core = require "sn_core"
    sn_core.init()
    sn_core.write(VS("SNLOCK00001"))
    require("sn_store_fskv").set_lock()
    local ok, err = sn_core.write(VS("SNEVIL00001"), { force = true })
    eq(ok, false); eq(err, "locked")
    eq(sn_core.clear(), false)
    eq(get_device_sn(), VS("SNLOCK00001"))
end)

-- ⚠️ 这条是真机踩出来的死局：规则演进后老 SN 变成 invalid，而设备又是锁着的。
--   锁的语义是"防止有效 SN 被改成另一个"，不是"把坏数据焊死在设备里"。
test("invalid + locked 不是死局：允许修复写入", function()
    local sn_core = require "sn_core"
    -- 塞一个不合当前规则的脏数据，并上锁，复刻真机现场状态
    fskv.set("dev_sn", "SNREWORK0001")     -- 11 位，低于 min_len 17
    fskv.save()
    require("sn_store_fskv").set_lock()
    sn_core.init()
    eq(sn_core.state(), "invalid")
    eq(get_device_sn(), nil)

    -- 修复写入必须放行（不需要 UNLOCK）
    local ok, err = sn_core.write(VS("SNFIX000002"))
    truthy(ok, err)
    eq(sn_core.state(), "ready")
    eq(get_device_sn(), VS("SNFIX000002"))
end)

test("ready + locked 仍然拒绝改写（锁本身没被削弱）", function()
    local sn_core = require "sn_core"
    sn_core.init()
    sn_core.write(VS("SNLOCK00003"))
    require("sn_store_fskv").set_lock()
    local ok, err = sn_core.write(VS("SNEVIL00002"), { force = true })
    eq(ok, false); eq(err, "locked")       -- 有效 SN 照样锁死
    eq(sn_core.clear(), false)
end)

test("invalid + locked 允许 clear 清掉脏数据", function()
    local sn_core = require "sn_core"
    fskv.set("dev_sn", "SNREWORK0001")
    fskv.save()
    require("sn_store_fskv").set_lock()
    sn_core.init()
    eq(sn_core.state(), "invalid")
    eq(sn_core.clear(), true)
    eq(sn_core.state(), "empty")
end)

-- 写后回读
test("写后回读失败 -> verify fail 且不污染缓存", function()
    local sn_core = require "sn_core"
    sn_core.init()
    fskv.fault = true               -- mock: set 之后 load 返回 nil，模拟写丢
    local ok, err = sn_core.write(VS("SNVERI00001"))
    eq(ok, false); eq(err, "verify fail")
    eq(get_device_sn(), nil)        -- 缓存没被改
    eq(sn_core.state(), "empty")
    fskv.fault = false
    truthy(sn_core.write(VS("SNVERI00002")))
    eq(get_device_sn(), VS("SNVERI00002"))
end)

-- clear
test("clear 后回到 empty，burn 追溯保留", function()
    local sn_core = require "sn_core"
    sn_core.init()
    sn_core.write(VS("SNCLR000001"))
    sn_core.clear()
    eq(sn_core.state(), "empty")
    eq(get_device_sn(), nil)
    eq(sn_core.meta().burn, 1)      -- 追溯信息不丢
end)

-- on_change
test("on_change：烧录成功触发回调", function()
    local sn_core = require "sn_core"
    sn_core.init()
    local fired = nil
    sn_core.on_change(function(sn, st) fired = { sn = sn, st = st } end)
    local sn = VS("SNCB0000001")
    sn_core.write(sn)
    eq(fired.sn, sn)
    eq(fired.st, "ready")
end)
