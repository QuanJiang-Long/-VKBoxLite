--[[
@module  test/prov_uart_test.lua
@brief   COM4 产线指令通道单测（mock uart，不依赖硬件）

@detail  真机语义对齐：
            · uart.on("receive", cb) 的 cb 第二参数是长度，数据要 uart.read 取
              （mock 的 uart.fire 按同样语义传 #data）
            · 回调只搬字节进缓冲，分发/应答由 prov.poll() 驱动
              （真机上由 start_loop() 的任务循环驱动）

          所有 SN 用 VS("标签") 生成，规则变了只改 run_all.lua 的 VS()。
]]

-- R:SN 空态
test("R:SN 空态 -> RET:SN=EMPTY", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "R:SN\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:SN=EMPTY\r\n")
end)

-- 写入 + 读回
test("W:SN 写入 -> RET:OK，R:SN 读回一致", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    local sn = VS("SN20260101001")
    uart.fire(4, "W:SN=" .. sn .. "\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:OK\r\n")
    _G.uart_out = {}
    uart.fire(4, "R:SN\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:SN=" .. sn .. "\r\n")
end)

-- R:ID 产线探测
test("R:ID -> RET:ID= 含 imei/uid/sn/state/lock 五个字段", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "R:ID\r\n")
    prov.poll()
    local out = table.concat(_G.uart_out)
    eq(out:sub(1, 7), "RET:ID=")
    truthy(out:find("imei:", 1, true),  "缺 imei 字段")
    truthy(out:find("uid:", 1, true),   "缺 uid 字段")
    truthy(out:find("sn:", 1, true),    "缺 sn 字段")
    truthy(out:find("state:empty", 1, true), "state 应为 empty")
    truthy(out:find("lock:0", 1, true), "lock 应为 0")
end)

test("R:ID 在已烧号+上锁后反映真实状态", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    local sn = VS("SNIDPROBE0001")
    uart.fire(4, "W:SN=" .. sn .. "\r\n")
    prov.poll()
    uart.fire(4, "LOCK:SN\r\n")
    prov.poll()
    _G.uart_out = {}
    uart.fire(4, "R:ID\r\n")
    prov.poll()
    local out = table.concat(_G.uart_out)
    truthy(out:find("state:ready", 1, true), "state 应为 ready")
    truthy(out:find("lock:1", 1, true),      "lock 应为 1")
    truthy(out:find("sn:" .. sn, 1, true),   "sn 字段应是刚烧的值")
end)

-- 非法输入
test("非法字符 SN -> RET:FAIL:char invalid", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "W:SN=bad sn!1234567890\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:FAIL:char invalid\r\n")
end)

test("超长 SN -> RET:FAIL:length invalid", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "W:SN=" .. string.rep("A", 33) .. "\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:FAIL:length invalid\r\n")
end)

test("校验位错误的 SN -> RET:FAIL:checksum invalid", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    local bad = VS("SNCKSUM000001"):sub(1, -2) .. "9"
    uart.fire(4, "W:SN=" .. bad .. "\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:FAIL:checksum invalid\r\n")
end)

-- 唯一性防呆
test("已有 SN 时异值写入 -> RET:FAIL:sn exists", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "W:SN=" .. VS("SNAAA000001") .. "\r\n")
    prov.poll()
    _G.uart_out = {}
    uart.fire(4, "W:SN=" .. VS("SNBBB000001") .. "\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:FAIL:sn exists\r\n")
    eq(get_device_sn(), VS("SNAAA000001"))
end)

test("W:SN=xxx,FORCE 覆盖写 -> RET:OK", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "W:SN=" .. VS("SNOLD000001") .. "\r\n")
    prov.poll()
    _G.uart_out = {}
    uart.fire(4, "W:SN=" .. VS("SNNEW000001") .. ",FORCE\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:OK\r\n")
    eq(get_device_sn(), VS("SNNEW000001"))
end)

-- 半包 / 分片
test("半包分片送达：半包不应答，拼整后正常执行", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    local sn = VS("SNSPLIT00001")
    uart.fire(4, "W:SN=" .. sn:sub(1, 8))
    prov.poll()
    eq(#_G.uart_out, 0)
    uart.fire(4, sn:sub(9) .. "\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:OK\r\n")
    eq(get_device_sn(), sn)
end)

test("一次送达多行指令：逐行解析", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "R:SN\r\nR:SN\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:SN=EMPTY\r\nRET:SN=EMPTY\r\n")
end)

test("缓冲超长自动清空，之后仍可正常工作", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, string.rep("X", 200))
    prov.poll()
    eq(#_G.uart_out, 0)
    uart.fire(4, "R:SN\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:SN=EMPTY\r\n")
end)

-- 量产安全
test("C:SN 量产默认关闭 -> 无任何响应，SN 不被擦", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "W:SN=" .. VS("SNCLR000001") .. "\r\n")
    prov.poll()
    _G.uart_out = {}
    uart.fire(4, "C:SN\r\n")
    prov.poll()
    eq(#_G.uart_out, 0)
    eq(get_device_sn(), VS("SNCLR000001"))
end)

test("LOCK:SN 上锁后写入被拒", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "W:SN=" .. VS("SNLOCK00001") .. "\r\n")
    prov.poll()
    _G.uart_out = {}
    uart.fire(4, "LOCK:SN\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:OK\r\n")
    _G.uart_out = {}
    uart.fire(4, "W:SN=" .. VS("SNEVIL00001") .. ",FORCE\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:FAIL:locked\r\n")
    eq(get_device_sn(), VS("SNLOCK00001"))
end)

test("UNLOCK:SN 解锁后可 FORCE 改写，SN 值不被清", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "W:SN=" .. VS("SNLOCK00002") .. "\r\n")
    prov.poll()
    uart.fire(4, "LOCK:SN\r\n")
    prov.poll()
    _G.uart_out = {}

    -- 未解锁：拒绝
    uart.fire(4, "W:SN=" .. VS("SNREWORK0002") .. ",FORCE\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:FAIL:locked\r\n")

    -- 解锁
    _G.uart_out = {}
    uart.fire(4, "UNLOCK:SN\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:OK\r\n")

    -- 解锁后 SN 仍在（只摘锁不清值）
    eq(get_device_sn(), VS("SNLOCK00002"))

    -- 解锁后异值不带 FORCE 仍被拒（防顺手改号）
    _G.uart_out = {}
    uart.fire(4, "W:SN=" .. VS("SNREWORK0002") .. "\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:FAIL:sn exists\r\n")

    -- 带 FORCE 才能改写
    _G.uart_out = {}
    uart.fire(4, "W:SN=" .. VS("SNREWORK0002") .. ",FORCE\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:OK\r\n")
    eq(get_device_sn(), VS("SNREWORK0002"))
end)

test("UNLOCK:SN 在未上锁时返回 not locked", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "UNLOCK:SN\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:FAIL:not locked\r\n")
end)

-- 脏数据态
test("Flash 脏数据态 R:SN -> RET:SN=INVALID", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    fskv.set("dev_sn", "bad sn!")
    fskv.save()
    sn_core.init()
    uart.fire(4, "R:SN\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:SN=INVALID\r\n")
end)

-- 未知指令
test("未知指令被忽略，不崩溃", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "HELLO\r\n")
    prov.poll()
    eq(#_G.uart_out, 0)
end)

-- 延后注册（VUART_0 / USB CDC 场景）
test("init() 不注册回调，register_callback() 之后才收得到", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    sn_core.init()
    uart.fire(4, "R:SN\r\n")            -- 未注册回调：收不到，不应答
    prov.poll()
    eq(#_G.uart_out, 0)
    prov.register_callback()
    uart.fire(4, "R:SN\r\n")
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:SN=EMPTY\r\n")
end)

test("register_callback() 幂等，重复调用不重复注册", function()
    local prov = require "sn_prov_uart"
    prov.init(4)
    eq(prov.register_callback(), true)
    eq(prov.register_callback(), true)
end)

test("默认 UART ID 解析为 VUART_0(USB CDC)，显式传参才覆盖", function()
    local prov = require "sn_prov_uart"
    prov.init(4)
    eq(prov.uart_id(), 4)               -- 显式传 4 生效
end)

test("回调只搬字节不应答：数据没进 poll 就不产生输出", function()
    local sn_core = require "sn_core"
    local prov    = require "sn_prov_uart"
    prov.init(4)
    prov.register_callback()
    sn_core.init()
    uart.fire(4, "R:SN\r\n")            -- 只进缓冲
    eq(#_G.uart_out, 0)                 -- 未 poll：不应答（真机上由循环驱动）
    prov.poll()
    eq(table.concat(_G.uart_out), "RET:SN=EMPTY\r\n")
end)
