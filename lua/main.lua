--[[
main.lua - 启动编排
顺序: guard(看门狗地基) -> sn(产线优先) -> 协议/数据/配置 -> 485(idle) -> MQTT -> cmd(前端)
注意: 一行只写一个 require, 同行绝不再出现引号字符串(Luatools 静态扫描贪婪匹配)
      绝不要拼 package.path (LuatOS 里是 nil, 拼了 VM 启动即崩)
]]

PROJECT = "VKBoxLite"
VERSION = "2.0.1"
BUILD_ID = "2026-10-01-new"
-- 发布版开关: true=发布, false=开发。改 lua/_build_flag.lua 即可切版本。
_G.BUILD_RELEASE = require "_build_flag"
_G.DEBUG = not _G.BUILD_RELEASE

local _raw_require = require
local _pkg_ok = (type(package) == "table" and type(package.loaded) == "table")
local _req_miss = {}
-- 自定义 require: 子目录 fallback (bus/mbus → mbus) + 缓存, 防无限重试
-- 任意 require 成功(即使 chunk 返回 nil)都缓存成 true, 否则二次 require
-- 走 pcall → fallback → 报 "module not found" (踩过: probe_exmodbus 不
-- return 时第二次 require 同名模块崩)
require = function(name)
    if type(name) ~= "string" then return _raw_require(name) end
    local sub, base = string.match(name, "^([%a_][%w_]*)/([%a_][%w_]*)$")
    if not sub then return _raw_require(name) end
    if _pkg_ok and package.loaded[name] ~= nil then return package.loaded[name] end
    if _req_miss[name] then return _raw_require(name) end
    local ok, m = pcall(_raw_require, name)
    if ok then
        if _pkg_ok and package.loaded[name] == nil then
            package.loaded[name] = (m == nil) and true or m
        end
        return m
    end
    local ok2, m2 = pcall(_raw_require, base)
    if ok2 then
        if _pkg_ok and package.loaded[name] == nil then
            package.loaded[name] = (m2 == nil) and true or m2
        end
        return m2
    end
    _req_miss[name] = true
    error(string.format("module %q not found", name), 2)
end

local util = require "util"
local sys = util.get("sys")
local log = util.log()
local mbus = require "bus/mbus"

local function mod(name, ok, m)
    if ok then
        log.info("main", "  [OK] " .. name)
        return m
    end
    log.warn("main", "  [SKIP] " .. name .. ": " .. tostring(m))
    return nil
end

log.info("main", "boot " .. PROJECT .. " v" .. VERSION .. " build=" .. BUILD_ID)

-- stage 1: 看门狗(地基)
log.info("main", "[1/6] guard")
local guard = mod("svc/guard", pcall(require, "svc/guard"))
if guard then pcall(guard.init) end

-- stage 2: SN(产线优先)
log.info("main", "[2/6] sn")
local snc = mod("sn/sn", pcall(require, "sn/sn"))
if snc then
    pcall(snc.init)
    pcall(snc.identity_init)
    log.info("main", string.format("  sn state=%s sn=%s", snc.state(),
        tostring(_G.get_device_sn and _G.get_device_sn())))
    if type(snc.on_change) == "function" then
        pcall(snc.on_change, function(sn, state)
            if state ~= "ready" or sn == nil then return end
            local okm, mgr = pcall(require, "iot/iot")
            if not okm or not mgr then return end
            if type(mgr.is_running) == "function" and mgr.is_running() then return end
            local ok2, err2 = pcall(mgr.start)
            if ok2 then
                log.info("main", "SN burned, MQTT auto-started, id=" .. tostring(sn))
            else
                log.warn("main", "MQTT auto-start fail: " .. tostring(err2))
            end
        end)
    end
end

-- stage 3: 协议/数据/配置
log.info("main", "[3/6] bus/data/cfg")
local collector = mod("data/collector", pcall(require, "data/collector"))
local cfgstore = mod("cfg", pcall(require, "cfg"))

-- stage 4: 485 子系统(默认 idle)
log.info("main", "[4/6] 485")
local pollmod = mod("bus/poll", pcall(require, "bus/poll"))
local monmod = mod("bus/mon", pcall(require, "bus/mon"))
local ctrl = mod("bus/ctrl", pcall(require, "bus/ctrl"))
local gpio = util.try("gpio")
if gpio then
    pcall(gpio.setup, mbus.DE_PIN, 0)
    pcall(gpio.set, mbus.DE_PIN, 0)
end
if ctrl then
    local sysc = cfgstore and cfgstore.load_sys()
    local boot = sysc and sysc.boot_mode or "idle"
    -- 三种主动模式都能开机自启。漏一个的症状很隐蔽: 开机模式选了它,
    -- 日志打"485 idle"但设备其实没起来, 用户只会以为"开机启动坏了"
    -- 记录 3 回归修: 这里历史漏改过, 原来写的是 "poll"/"pollpull", 但
    -- e0d0bf3 commit 已经把全项目 poll/pollpull 改成 manual/platform,
    -- 开机路径漏了一处, 设备启动时 fskv 读到 "manual"/"platform" 走 else,
    -- 用户看到的现象是 W:BOOTMODE=manual 重启后不进 manual。
    if boot == "manual" or boot == "platform" or boot == "sniff" then
        local ok, msg = ctrl.switch_mode(boot)
        log.info("main", "  boot_mode=" .. boot .. " -> " .. tostring(msg))
    else
        log.info("main", "  boot_mode=" .. tostring(boot) .. " (485 idle, 等前端命令 W:MODE=manual|platform|sniff|stop)")
    end
end

-- stage 5: MQTT
log.info("main", "[5/6] iot")
local iot = mod("iot/iot", pcall(require, "iot/iot"))
if iot then
    pcall(iot.init)
    local sn = _G.get_device_sn and _G.get_device_sn()
    if sn and #tostring(sn) > 0 then
        pcall(iot.start)
    else
        log.warn("main", "  未烧 SN, MQTT 不建连")
    end
end
if snc and type(snc.start_warn_monitor) == "function" then
    pcall(snc.start_warn_monitor, 600)
end

-- stage 6: 前端指令层 + 产线通道
log.info("main", "[6/6] cmd/prov")
local cmd = mod("svc/cmd", pcall(require, "svc/cmd"))
if cmd then pcall(cmd.init) end
local prov = mod("sn/prov", pcall(require, "sn/prov"))
if prov then
    pcall(prov.init)
    sys.taskInit(function()
        log.info("main", "  VUART task: 等待 USB 枚举...")
        local ok, ready = pcall(prov.wait_ready, 30000)
        if ok and ready then
            log.info("main", "  VUART ready COM" .. tostring(prov.uart_id()))
        else
            log.error("main", "  VUART 30s 内未就绪")
        end
    end)
end

log.info("main", "boot complete, entering sys.run() build=" .. BUILD_ID)

sys.run()
