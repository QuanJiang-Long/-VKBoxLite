






PROJECT = "VKBoxLite"
VERSION = "1.0.2"
BUILD_ID = "2026-10-30-v1.0.2"

_G.BUILD_RELEASE = require "_build_flag"
_G.DEBUG = not _G.BUILD_RELEASE

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


log.info("main", "[1/6] guard")
local guard = mod("svc/guard", pcall(require, "svc/guard"))
if guard then pcall(guard.init) end


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


log.info("main", "[3/6] bus/data/cfg")
local collector = mod("data/collector", pcall(require, "data/collector"))
local cfgstore = mod("cfg", pcall(require, "cfg"))


log.info("main", "[4/6] 485")




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






    if boot == "manual" or boot == "platform" or boot == "sniff" then



        local ok, msg = ctrl.switch_mode(boot, true)
        log.info("main", "  boot_mode=" .. boot .. " -> " .. tostring(msg))
    else


        local ok, msg = ctrl.switch_mode("idle", true)
        log.info("main", "  boot_mode=" .. tostring(boot) .. " -> " .. tostring(msg))
    end
end


log.info("main", "[5/6] iot")
local iot = mod("iot/iot", pcall(require, "iot/iot"))
if iot then
    pcall(iot.init)
    local sn = _G.get_device_sn and _G.get_device_sn()
    if sn and #tostring(sn) > 0 then
        pcall(iot.start)
    else

        log.warn("main", "  未烧 SN, MQTT 不建连 (烧 SN 后能建连)")
    end
end
if snc and type(snc.start_warn_monitor) == "function" then
    pcall(snc.start_warn_monitor, 600)
end


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
