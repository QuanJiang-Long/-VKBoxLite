--[[
@module  test/mock/env.lua
@brief   PC 单测最小硬件环境 mock
@detail  模拟 fskv（含 commit-on-save 语义，可模拟写失败）、
          uart（可向接收回调灌数据）、mobile、mcu、log、sys。
          用法：lua run_all.lua / luajit run_all.lua
]]

local M = {}

M.logs = {}

--=====================================================================
-- log
--=====================================================================
local function mklog(level)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(i, ...)))
        end
        M.logs[#M.logs + 1] = level .. ": " .. table.concat(parts, " ")
    end
end

log = { info = mklog("INFO"), warn = mklog("WARN"), error = mklog("ERROR") }

--=====================================================================
-- fskv：set 先进待写区，save() 才真正提交（贴近真实 flash 语义）
--   fault = true 时 save() 丢弃待写数据 -> 用于测"写后回读失败"
--=====================================================================
fskv = {
    save_count = 0,
    fault      = false,
    _c         = {},   -- 已提交
    _p         = nil,  -- 待写（false 表示删除）
}

function fskv.get(k) return fskv._c[k] end

function fskv.set(k, v)
    fskv._p = fskv._p or {}
    fskv._p[k] = v
end

function fskv.del(k)
    fskv._p = fskv._p or {}
    fskv._p[k] = false
end

function fskv.save()
    fskv.save_count = fskv.save_count + 1
    if fskv.fault then fskv._p = nil return end
    for k, v in pairs(fskv._p or {}) do
        if v == false then fskv._c[k] = nil else fskv._c[k] = v end
    end
    fskv._p = nil
end

--=====================================================================
-- uart
--=====================================================================
uart = {
    PAR_NONE = 0,
    STOP_1   = 1,
    -- Air780EP 上 COM4 = USB CDC 虚拟串口；硬件 UART4 是另一个口
    VUART_0  = 0,
}

function uart.setup(id, baud, databits, stopbits, parity)
    _G.uart_setup = { id = id, baud = baud, databits = databits, stopbits = stopbits, parity = parity }
end

function uart.write(id, data)
    _G.uart_out[#_G.uart_out + 1] = data
end

function uart.on(id, event, cb)
    _G.uart_cb[id] = cb
end

--- 测试辅助：模拟串口收到数据（第二参数按真机语义传长度）
--   未注册回调 = 数据不到达（对应真机上没 uart.on 时字节不进入 Lua 层）
function uart.fire(id, data)
    if not _G.uart_cb[id] then return end
    _G.uart_rx[id] = (_G.uart_rx[id] or "") .. data
    _G.uart_cb[id](id, #data)
end

--- 真机语义：read(id, len) 取出 len 字节，取完即从缓冲移除
function uart.read(id, len)
    local s = _G.uart_rx[id] or ""
    if #s == 0 then return "" end
    local out = s:sub(1, len)
    _G.uart_rx[id] = s:sub(len + 1)
    return out
end

--=====================================================================
-- mobile / mcu
--=====================================================================
mobile = {
    sn   = function() return _G.mobile_sn   end,
    imei = function() return _G.mobile_imei end,
}

mcu = {
    unique_id = function() return _G.chip_uid end,
}

--=====================================================================
-- sys
--=====================================================================
sys = {
    taskInit = function(f) f() end,
    timerLoopStart = function(fn, ms)
        _G.timers[#_G.timers + 1] = { fn = fn, ms = ms }
    end,
}

--- 测试辅助：触发所有周期定时器 n 次
function sys.fire_timers(n)
    for _, t in ipairs(_G.timers) do
        for _ = 1, n do t.fn() end
    end
end

--=====================================================================
-- 模块注册
-- 被测代码与设备端一致，用 require 获取 LuatOS 库；
-- PC 侧把这些库名映射到上面的全局 mock。
--=====================================================================
package.preload = package.preload or {}
package.preload["sys"]    = function() return sys    end
package.preload["log"]    = function() return log    end
package.preload["uart"]   = function() return uart   end
package.preload["fskv"]   = function() return fskv   end
package.preload["mobile"] = function() return mobile end
package.preload["mcu"]    = function() return mcu    end
package.preload["json"]   = function() return { encode = function(t) return t end } end

--=====================================================================
-- 每个用例前的环境重置
--=====================================================================
function M.reset()
    M.logs = {}
    fskv._c, fskv._p, fskv.save_count, fskv.fault = {}, nil, 0, false
    _G.uart_out, _G.uart_cb, _G.uart_setup, _G.uart_rx = {}, {}, nil, {}
    _G.mobile_imei, _G.mobile_sn = nil, nil
    _G.chip_uid = "UID0123456789ABCDEF"
    _G.timers = {}
end

M.reset()

return M
