--[[
main.lua - 启动编排
顺序: guard(看门狗地基) -> sn(产线优先) -> 协议/数据/配置 -> 485(idle) -> MQTT -> cmd(前端)
注意: 一行只写一个 require, 同行绝不再出现引号字符串(Luatools 静态扫描贪婪匹配)
      绝不要拼 package.path (LuatOS 里是 nil, 拼了 VM 启动即崩)
]]

PROJECT = "vkbox_485_collect"
VERSION = "2.0.0"
BUILD_ID = "2026-10-01-new"

local _raw_require = require
local _pkg_ok = (type(package) == "table" and type(package.loaded) == "table")
local _req_miss = {}
require = function(name)
    if type(name) ~= "string" then return _raw_require(name) end
    local sub, base = string.match(name, "^([%a_][%w_]*)/([%a_][%w_]*)$")
    if not sub then return _raw_require(name) end
    if _pkg_ok and package.loaded[name] ~= nil then return package.loaded[name] end
    if _req_miss[name] then return _raw_require(name) end
    local ok, m = pcall(_raw_require, name)
    if ok and m ~= nil then
        if _pkg_ok then package.loaded[name] = m end
        return m
    end
    local ok2, m2 = pcall(_raw_require, base)
    if ok2 and m2 ~= nil then
        if _pkg_ok then package.loaded[name] = m2 end
        return m2
    end
    _req_miss[name] = true
    error(string.format("module %q not found", name), 2)
end

local corelib = require "core/corelib"
local sys = corelib.get("sys")
local log = corelib.log()
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
local store = mod("data/store", pcall(require, "data/store"))
if store and collector then
    local ok, err = pcall(store.init)
    if not ok then
        log.warn("main", "  store init: " .. tostring(err))
    else
        collector.on_store(function(rec) store.push(rec) end)
        log.info("main", "  collector -> store 已挂接")
    end
end

-- stage 4: 485 子系统(默认 idle)
log.info("main", "[4/6] 485")
local pollmod = mod("bus/poll", pcall(require, "bus/poll"))
local monmod = mod("bus/mon", pcall(require, "bus/mon"))
local ctrl = mod("bus/ctrl", pcall(require, "bus/ctrl"))
local gpio = corelib.try("gpio")
if gpio then
    pcall(gpio.setup, mbus.DE_PIN, 0)
    pcall(gpio.set, mbus.DE_PIN, 0)
end
if ctrl then
    local sysc = cfgstore and cfgstore.load_sys()
    local boot = sysc and sysc.boot_mode or "idle"
    if boot == "poll" or boot == "sniff" then
        local ok, msg = ctrl.switch_mode(boot)
        log.info("main", "  boot_mode=" .. boot .. " -> " .. tostring(msg))
    else
        log.info("main", "  485 idle, 等前端命令 W:MODE=poll|sniff|stop")
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

log.info("main", "boot complete, entering sys.run()")
print("[main] boot complete, entering sys.run() build=" .. BUILD_ID)

sys.run()
