local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local uart = corelib.get("uart")
local gpio = corelib.try("gpio")
local json = corelib.try("json")
local rtos = corelib.try("rtos")
local mobile = corelib.try("mobile")

local sn = require "sn/sn"
local ctrl = require "bus/ctrl"
local poll = require "bus/poll"
local mon = require "bus/mon"
local mbus = require "bus/mbus"
local collector = require "data/collector"
local store = require "data/store"
local cfgstore = require "cfg"
local mqtt_cfg = require "iot/mqttcfg"
local iot = corelib.try("iot/iot")
local guard = corelib.try("svc/guard")

local M = {}

local UART_ID = uart.VUART_0
if UART_ID == nil then UART_ID = 4 end

local g_cmds = {}

function M.reply(s)
    log.debug("cmd", "tx:", s)
    pcall(uart.write, UART_ID, s .. "\r\n")
end

local function device_id_str()
    local ok, snc = pcall(require, "sn/sn")
    if ok and snc and snc.state() == "ready" then
        return _G.get_device_sn and _G.get_device_sn()
    end
    return nil
end

function M.reg(cmd, fn) g_cmds[cmd] = fn end

function M.uart_id() return UART_ID end

local function num(v, d)
    if v == nil then return d end
    return tonumber(v) or d
end

local function jencode(t)
    if not json then return "{}" end
    local ok, s = pcall(json.encode, t)
    return ok and s or "{}"
end

local function jdecode(s)
    if not json then return nil end
    local ok, t = pcall(json.decode, s)
    return ok and t or nil
end

local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

local function reg_cmds()
    M.reg("R:INFO", function()
        M.reply("RET:INFO=" .. jencode({
            project = _G.PROJECT,
            version = _G.VERSION,
            imei = sn.imei(),
            chip_uid = sn.chip_uid(),
            sn = _G.get_device_sn and _G.get_device_sn(),
            sn_state = sn.state(),
            locked = sn.locked(),
            iccid = mobile and mobile.iccid,
            csq = mobile and mobile.csq,
        }))
    end)

    M.reg("R:MODE", function()
        M.reply("RET:MODE=" .. ctrl.get_mode())
    end)

    M.reg("W:MODE", function(arg)
        local v = trim(arg):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if v == "stop" then v = "idle" end
        local ok, msg = ctrl.switch_mode(v)
        if ok then M.reply("RET:MODE=OK") else M.reply("RET:FAIL:MODE:" .. tostring(msg)) end
    end)

    M.reg("R:CFG", function()
        M.reply("RET:CFG=" .. jencode(cfgstore.load_poll()))
    end)

    M.reg("W:CFG", function(arg)
        local t = jdecode(arg)
        if not t then return M.reply("RET:FAIL:CFG:bad json") end
        local n, err = cfgstore.normalize_poll(t)
        if not n then return M.reply("RET:FAIL:CFG:" .. tostring(err)) end
        local ok, serr = cfgstore.save_poll(t)
        if not ok then return M.reply("RET:FAIL:CFG:" .. tostring(serr)) end
        if poll.needs_restart(n) then
            if poll.is_running() then
                poll.stop()
                poll.apply_cfg(n)
                poll.start()
            else
                poll.apply_cfg(n)
            end
        else
            poll.apply_cfg(n)
        end
        M.reply("RET:CFG=OK")
    end)

    M.reg("R:SNIFFCFG", function()
        M.reply("RET:SNIFFCFG=" .. jencode(cfgstore.load_sniff()))
    end)

    M.reg("W:SNIFFCFG", function(arg)
        local t = jdecode(arg)
        if not t then return M.reply("RET:FAIL:SNIFFCFG:bad json") end
        local ok, err = cfgstore.save_sniff(t)
        if not ok then return M.reply("RET:FAIL:SNIFFCFG:" .. tostring(err)) end
        if mon.is_running() then
            mon.stop()
            mon.start()
        end
        M.reply("RET:SNIFFCFG=OK")
    end)

    M.reg("R:REG", function()
        M.reply("RET:REG=" .. jencode(poll.get_regs()))
    end)

    M.reg("W:REG", function(arg)
        local t = jdecode(arg)
        if not t or type(t) ~= "table" then return M.reply("RET:FAIL:REG:bad json") end
        local c = cfgstore.load_poll()
        c.regs = t
        local n, err = cfgstore.normalize_poll(c)
        if not n then return M.reply("RET:FAIL:REG:" .. tostring(err)) end
        local ok, serr = cfgstore.save_poll(c)
        if not ok then return M.reply("RET:FAIL:REG:" .. tostring(serr)) end
        poll.apply_cfg(n)
        M.reply("RET:REG=OK")
    end)

    M.reg("R:VAL", function()
        M.reply("RET:VAL=" .. jencode(collector.snapshot()))
    end)

    M.reg("R:STAT", function()
        local st = ctrl.status()
        st.collector = collector.stats()
        st.guard = guard and guard.status() or nil
        st.store = store.stats()
        st.iot = iot and iot.status() or nil
        M.reply("RET:STAT=" .. jencode(st))
    end)

    M.reg("W:WRITE", function(arg)
        local slave, addr, value = arg:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%-?%d+)%s*$")
        if not slave then return M.reply("RET:FAIL:WRITE:use <slave>,<addr>,<value>") end
        local ok, err = poll.enqueue_write({
            slave = tonumber(slave), addr = tonumber(addr), value = tonumber(value),
        })
        if ok then M.reply("RET:WRITE=OK") else M.reply("RET:FAIL:WRITE:" .. tostring(err)) end
    end)

    M.reg("W:WRITEJ", function(arg)
        local t = jdecode(arg)
        if not t or type(t) ~= "table" then return M.reply("RET:FAIL:WRITEJ:bad json") end
        local items = t[1] and t or { t }
        local nok, nfail = 0, 0
        for _, it in ipairs(items) do
            local addr = tonumber(it.addr or it.address or it.reg)
            local slave = tonumber(it.slave) or (cfgstore.load_poll().slave or cfg.SLAVE_ADDR)
            if it.values and type(it.values) == "table" then
                local vals = {}
                for _, v in ipairs(it.values) do vals[#vals + 1] = tonumber(v) end
                if poll.enqueue_write({ slave = slave, addr = addr, values = vals }) then nok = nok + 1 else nfail = nfail + 1 end
            elseif addr and (it.value or it.val) then
                if poll.enqueue_write({ slave = slave, addr = addr, value = tonumber(it.value or it.val) }) then nok = nok + 1 else nfail = nfail + 1 end
            else
                nfail = nfail + 1
            end
        end
        M.reply(string.format("RET:WRITEJ=OK:%d:%d", nok, nfail))
    end)

    M.reg("R:MQTT", function()
        M.reply("RET:MQTT=" .. jencode(mqtt_cfg.effective(device_id_str())))
    end)

    M.reg("W:MQTT", function(arg)
        if not iot then return M.reply("RET:FAIL:MQTT:no iot") end
        local t = jdecode(arg)
        if not t then return M.reply("RET:FAIL:MQTT:bad json") end
        local ok, err = iot.apply_cfg(t)
        if ok then M.reply("RET:MQTT=OK") else M.reply("RET:FAIL:MQTT:" .. tostring(err)) end
    end)

    M.reg("R:REPORT", function()
        if not iot then return M.reply("RET:FAIL:REPORT:no iot") end
        iot.report_now()
        M.reply("RET:REPORT=OK")
    end)

    M.reg("R:NET", function()
        M.reply("RET:NET=" .. jencode(iot and iot.net_state() or {}))
    end)

    M.reg("R:MEM", function()
        local st = {}
        if rtos then
            local t1, u1 = rtos.meminfo("sys")
            local t2, u2 = rtos.meminfo("lua")
            if type(u1) == "number" then st.sys = { total = t1, used = u1 } end
            if type(u2) == "number" then st.lua = { total = t2, used = u2 } end
        end
        M.reply("RET:MEM=" .. jencode(st))
    end)

    M.reg("W:GC", function()
        collector.trim_cache()
        collectgarbage("collect")
        collectgarbage("collect")
        if iot then iot.kick() end
        M.reply("RET:GC=OK")
    end)

    M.reg("R:DISK", function()
        local ok, f = pcall(io.open, cfg.DATA_FILE, "r")
        local size = 0
        if ok and f then
            local rok, d = pcall(function() return f:read("*a") end)
            if rok and type(d) == "string" then size = #d end
            pcall(f.close, f)
        end
        M.reply(string.format("RET:DISK=file=%s bytes=%d", cfg.DATA_FILE, size))
    end)

    M.reg("W:STORE", function(arg)
        local v, persist = arg:match("^%s*([01])%s*,?%s*(%a*)%s*$")
        if not v then return M.reply("RET:FAIL:STORE:use 0|1[,P]") end
        store.set_enable(v == "1", trim(persist):upper() == "P")
        M.reply("RET:STORE=OK")
    end)

    M.reg("R:FRAMES", function()
        M.reply("RET:FRAMES=" .. jencode(mon.recent_frames(10)))
    end)

    M.reg("R:POLL", function()
        M.reply("RET:POLL=" .. jencode(poll.status()))
    end)

    M.reg("W:BOOTMODE", function(arg)
        local m = trim(arg)
        local ok, err = cfgstore.save_sys({ boot_mode = m })
        if not ok then return M.reply("RET:FAIL:BOOTMODE:" .. tostring(err)) end
        M.reply("RET:BOOTMODE=OK")
    end)

    M.reg("W:RST", function()
        cfgstore.reset()
        mqtt_cfg.reset()
        collector.clear()
        store.clear()
        if poll.is_running() then
            poll.stop()
            poll.start()
        end
        M.reply("RET:RST=OK")
    end)
end

function M.handle(line)
    if type(line) ~= "string" then return false end
    line = line:gsub("[\r\n]", "")
    local fn = g_cmds[line]
    if not fn then
        local cmd, arg = line:match("^%s*([%w:]+)%s*=%s*(.-)%s*$")
        if cmd then fn = g_cmds[cmd]; line = arg end
    end
    if not fn then return false end
    local ok, err = pcall(fn, line)
    if not ok then
        M.reply("RET:FAIL:handler error:" .. tostring(err))
    end
    return true
end

function M.init()
    reg_cmds()
    local names = {}
    for k in pairs(g_cmds) do names[#names + 1] = k end
    table.sort(names)
    log.info("cmd", "ready on VUART via prov hook, cmds:", table.concat(names, " "))
    return true
end

_G.vcom_handle = function(line) return M.handle(line) end

return M
