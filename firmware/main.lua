--[[
main.lua - 启动编排
顺序: guard(看门狗地基) -> sn(产线优先) -> 协议/数据/配置 -> 485(idle) -> MQTT -> cmd(前端)
注意: 一行只写一个 require, 同行绝不再出现引号字符串(Luatools 静态扫描贪婪匹配)
      绝不要拼 package.path (LuatOS 里是 nil, 拼了 VM 启动即崩)
]]

PROJECT = "VKBoxLite"
VERSION = "1.0.2"
BUILD_ID = "2026-10-30-v1.0.2"
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

-- V2 日志优化 (2026-11-06): 单行化 + 耗时 + 堆 + R:BOOT 快照
local _t0 = os.clock()
local _t, _n = _t0, 0
local BOOT_LINES = {}

local function mod(name, ok, m, extra)
    _n = _n + 1
    local now = os.clock()
    local res = ok and (m and "SKIP" or "OK  ") or "FAIL"
    local line = string.format("%d/6 %-16s %s %5dms lua=%3dK %s",
        _n, name, res, math.floor((now - _t) * 1000),
        math.floor(collectgarbage("count")), extra or "")
    _t = now
    log.info("boot", line)
    BOOT_LINES[#BOOT_LINES + 1] = line
    if not ok then log.error("boot", "  " .. name .. " -> " .. tostring(m)) end
    return m
end

log.info("boot", "===== VKBoxLite v" .. VERSION .. " (" .. BUILD_ID .. ")  Air780EP =====")

-- stage 1: 看门狗 (地基)
local ok, guard = pcall(require, "svc/guard")
guard = mod("guard", ok, guard, "wdt 由 AON 托管")
if guard then pcall(guard.init) end

-- stage 2: SN (产线优先)
local ok, snc = pcall(require, "sn/sn")
snc = mod("sn", ok, snc,
    snc and snc.state() == "ready" and ("sn=" .. tostring(_G.get_device_sn())) or "empty")
if snc then
    pcall(snc.init)
    pcall(snc.identity_init)
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
local ok, collector = pcall(require, "data/collector")
collector = mod("data+cfg", ok, collector, "maxregs=" .. (cfg and cfg.MAX_REGS or "?"))
local ok, cfgstore = pcall(require, "cfg")
cfgstore = mod("cfg", ok, cfgstore, nil)

-- stage 4: 485 子系统 (默认 idle)
local ok, monmod = pcall(require, "bus/mon")
monmod = mod("485 mon+ctrl", ok, monmod, nil)
local ok, ctrl = pcall(require, "bus/ctrl")
ctrl = mod("bus/ctrl", ok, ctrl, nil)
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
        log.info("boot", "  mode=" .. boot .. " -> " .. tostring(msg))
    else
        local ok, msg = ctrl.switch_mode("idle", true)
        log.debug("ctrl", "idle(boot): preserving config")
    end
end

-- stage 5: MQTT (预载于 stage 4, 这里只是确认)
local ok, iot = pcall(require, "iot/iot")
iot = mod("iot", ok, iot, "stage4 已预载")
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
local ok, cmd = pcall(require, "svc/cmd")
cmd = mod("cmd+prov", ok, cmd, nil)
if cmd then pcall(cmd.init) end
local ok, prov = pcall(require, "sn/prov")
prov = mod("sn/prov", ok, prov, nil)
if prov then
    pcall(prov.init)
    sys.taskInit(function()
        local ok, ready = pcall(prov.wait_ready, 30000)
        if ok and ready then
            log.info("boot", "  vuart=COM" .. tostring(prov.uart_id()))
        else
            log.error("boot", "  VUART 30s 内未就绪")
        end
    end)
end

-- V2 日志优化：开机摘要 + 4G netlog + R:BOOT 快照
local function boot_report()
    if cfgstore then
        local poll = cfgstore.load_poll()
        local pull = cfgstore.load_pull()
        local infer = cfgstore.load_infer()
        log.info("boot", string.format("cfg  poll=%s(%d) pull=%s(%d) infer=%s(%d)",
            cfgstore.poll_src and cfgstore.poll_src() or "?", (poll and poll.regs and #poll.regs) or 0,
            cfgstore.pull_src and cfgstore.pull_src() or "?", (pull and pull.regs and #pull.regs) or 0,
            cfgstore.infer_src and cfgstore.infer_src() or "?", (infer and infer.regs and #infer.regs) or 0))
        if poll then
            log.info("boot", string.format("bus  uart1 %d %d%s%d de=%d slave=%d poll=%dms timeout=%dms",
                poll.baud or 9600, poll.databits or 8,
                ({[0]="N",[1]="E",[2]="O"})[poll.parity or 0] or "N", poll.stopbits or 1,
                mbus.DE_PIN, poll.slave or 1, poll.interval_ms or 5000, poll.timeout_ms or 500))
        end
    end
    if mobile then
        local st = mobile.status() or -1
        log.info("boot", string.format("4G   iccid=%s sim=rdy(%.2fs) net=%s csq=%s",
            tostring(mobile.iccid() or "-"), os.clock() - _t0,
            ({[0]="未注册",[1]="已注册",[2]="搜网中",[3]="被拒绝",[5]="漫游"})[st] or "?",
            tostring(mobile.csq() or "-")))
    end
    if iot then
        local s = iot.status()
        log.info("boot", string.format("iot  want=%d conn=%d mode=%s manual=%d host=%s:%s",
            s.want_run and 1 or 0, s.connected and 1 or 0, s.mode or "?",
            s.manual_on and 1 or 0, tostring(s.host or "-"), tostring(s.port or "-")))
    end
end

-- 4G netlog: 变化驱动打点 (SIM 就绪/注网/驻网/掉网)
local ST_NAME = {[0]="未注册",[1]="已注册",[2]="搜网中",[3]="被拒绝",
                 [4]="未知",[5]="漫游已注册",[6]="仅 SMS",[7]="仅 SMS 漫游",[8]="仅紧急"}
local t0 = os.clock()
local last_st, last_csq = nil, nil

local function rssi_line(tag)
    local st = mobile.status() or -1
    local csq, rsrp, snr = mobile.csq(), mobile.rsrp(), mobile.snr()
    local s = string.format("%-9s [%5.2fs] status=%d(%s) csq=%s rsrp=%s snr=%s",
        tag, os.clock() - t0, st, ST_NAME[st] or "?", tostring(csq),
        tostring(rsrp), tostring(snr))
    if st == 1 or st == 5 then
        local c = mobile.scell()
        if c then s = s .. string.format(" %s%s band=%s tac=%s eci=%s",
            tostring(c.mcc), tostring(c.mnc), tostring(c.band),
            tostring(c.tac), tostring(c.eci)) end
    end
    log.info("net", s)
end

sys.taskInit(function()
    -- SIM 就绪
    while not mobile.simPin() do sys.wait(500) end
    log.info("net", string.format("[%5.2fs] SIM ready iccid=%s imsi=%s num=%s",
        os.clock() - t0, tostring(mobile.iccid()), tostring(mobile.imsi()),
        tostring(mobile.number())))

    -- 状态变化驱动
    local reg_at = nil
    while true do
        local st = mobile.status() or -1
        local csq = mobile.csq()
        local chg = (st ~= last_st)
            or (type(csq)=="number" and type(last_csq)=="number"
                and math.abs(csq-last_csq) >= 2 and csq < 99)
        if chg then
            if st == 3 then
                log.warn("net", string.format("[%5.2fs] 注册被拒! 网络侧不允许本卡接入", os.clock()-t0))
                rssi_line("REG-DENY")
                log.warn("net", "  → 查机卡绑定/区域限制/欠费; iccid=" .. tostring(mobile.iccid()))
            elseif st == 1 or st == 5 then
                reg_at = reg_at or os.clock()
                rssi_line("REG-OK")
                log.info("net", string.format("[%5.2fs] 驻网成功 耗时 %.2fs ip=%s",
                    os.clock()-t0, os.clock()-reg_at,
                    tostring(socket.localIP() or "-")))
            else
                rssi_line("NET")
            end
            last_st, last_csq = st, csq
        end
        sys.wait(1000)
    end
end)

-- 注册 R:BOOT 快照指令
if cmd then
    cmd.reg("R:BOOT", function() boot_report() end)
end

log.info("boot", string.format("===== done %dms  lua=%d/%dK =====",
    math.floor((os.clock() - _t0) * 1000),
    math.floor(collectgarbage("count")),
    math.floor(collectgarbage("count") * 1024 / 300)))

sys.run()
