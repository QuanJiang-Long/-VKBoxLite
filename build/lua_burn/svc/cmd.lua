local util = require "util"
local cfg = require "core/config"
local log = util.log()

local uart = util.get("uart")
local json = util.try("json")
local rtos = util.try("rtos")
local mobile = util.try("mobile")

local sn = require "sn/sn"
local ctrl = require "bus/ctrl"
local mon = require "bus/mon"
local collector = require "data/collector"
local cfgstore = require "cfg"
local mqtt_cfg = require "iot/mqttcfg"
local iot = util.try("iot/iot")
local guard = util.try("svc/guard")

local M = {}





local poll_mod
local poll_tried = false
local function pollmod(load)
    if load then
        if not poll_tried then
            poll_tried = true
            local ok, p = pcall(require, "bus/poll")
            poll_mod = ok and p or nil
            if not poll_mod then log.warn("cmd", "bus/poll 加载失败") end
        end
        return poll_mod
    end
    if not poll_tried then return nil end
    return poll_mod
end


function M.poll_loaded()
    return poll_mod ~= nil
end




local MODE_MANUAL, MODE_PLATFORM, MODE_IDLE, MODE_SNIFF = "manual", "platform", "idle", "sniff"

local SLOT_POLL, SLOT_PULL = "poll", "pull"

local UART_ID = uart.VUART_0
if UART_ID == nil then UART_ID = 4 end

local g_cmds = {}

function M.reply(s)






    log.debug("cmd", "tx:", #s, "B:", s:sub(1, 80))
    pcall(uart.write, UART_ID, s .. "\r\n")
end





local function reply_big(key, payload)
    local s = table.concat({ key, payload, "\r\n" })
    log.debug("cmd", "tx:", #s, "B:", s:sub(1, 80))
    pcall(uart.write, UART_ID, s)
end









local function json_reply_str(key, val)
    local t
    if type(val) == "table" then
        t = { key, "{" }
        for i = 1, #val do
            if i > 1 then t[#t + 1] = "," end
            t[#t + 1] = val[i]
        end
        t[#t + 1] = "}"
    else
        t = { key, val }
    end
    t[#t + 1] = "\r\n"
    return table.concat(t)
end
local function reply_json(key, val)
    local s = json_reply_str(key, val)
    log.debug("cmd", "tx:", #s, "B:", s:sub(1, 80))
    pcall(uart.write, UART_ID, s)
end




function M._json_reply_str(key, val)
    return json_reply_str(key, val)
end


local function blocked_while_detecting(cmd)
    if not mon.is_detecting() then return false end
    M.reply("RET:FAIL:" .. cmd .. ":BUSY: 正在识别通讯参数, 完成后自动开始旁"
        .. "听(或先 W:MODE=idle 放弃)")
    return true
end

local function device_id_str()
    local ok, snc = pcall(require, "sn/sn")
    if ok and snc and snc.state() == "ready" then
        return _G.get_device_sn and _G.get_device_sn()
    end
    return nil
end

function M.reg(cmd, fn) g_cmds[cmd] = fn end

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












function M.push_infer()
    if not mon then return false end
    local off, n = mon.infer_view()
    local ok, inf = pcall(mon.infer_page, off, n)
    if not ok or type(inf) ~= "table" then return false end

    if iot and iot.attach_names then inf = iot.attach_names(inf) end
    reply_big("RET:INFER_PUSH=", jencode(inf))
    return true
end


local function reg_cmds()


    M.reg("R:INFO", function()
        local function mval(k)
            if not mobile then return nil end
            local v = mobile[k]
            if type(v) == "function" then
                local ok, r = pcall(v)
                return ok and r or nil
            end
            return v
        end
        local okc, c = pcall(cfgstore.load_poll)
        local pc = okc and c or nil
        local okm, mc = pcall(mqtt_cfg.load)
        local mq = okm and mc or nil
        reply_json("RET:INFO=", jencode({
            project = _G.PROJECT,
            version = _G.VERSION,
            sn = _G.get_device_sn and _G.get_device_sn(),
            sn_state = sn.state(),
            lock = sn.locked() and 1 or 0,
            imei = sn.imei(),
            uid = sn.uid(),
            iccid = mval("iccid"),
            csq = mval("csq"),
            rsrp = mval("rsrp"),
            server = mq and mq.host or nil,
            baud = pc and pc.baud or cfg.BAUD,
            slave = pc and pc.slave or cfg.SLAVE_ADDR,
            regs = pc and #(pc.regs or {}) or 0,
        }))
    end)


    M.reg("R:MODE", function()
        reply_json("RET:MODE=", jencode(ctrl.status()))
    end)

    M.reg("W:MODE", function(arg)
        local v = trim(arg):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if v == "stop" then v = MODE_IDLE end


        local ok, msg, cleared = ctrl.switch_mode(v)
        if not ok then return M.reply("RET:FAIL:MODE:" .. tostring(msg)) end


        if cleared and #cleared > 0 then
            M.reply("RET:MODE=OK;cleared:" .. table.concat(cleared, "+"))
        else
            M.reply("RET:MODE=OK")
        end
    end)

    M.reg("R:CFG", function()

        local slot = (ctrl.get_mode() == "platform") and SLOT_PULL or SLOT_POLL
        local cfg = (slot == SLOT_PULL) and cfgstore.load_pull() or cfgstore.load_poll()




        local src = (slot == SLOT_PULL) and cfgstore.pull_src() or cfgstore.poll_src()
        reply_json("RET:CFG=", jencode({ cfg = cfg, slot = slot, src = src }))
    end)

    M.reg("W:CFG", function(arg)
        if blocked_while_detecting("CFG") then return end
        local t = jdecode(arg)
        if not t then return M.reply("RET:FAIL:CFG:bad json") end
        local n, err = cfgstore.normalize_poll(t)
        if not n then return M.reply("RET:FAIL:CFG:" .. tostring(err)) end
        local cur_mode = ctrl.get_mode()
        local slot = (cur_mode == "platform") and SLOT_PULL or SLOT_POLL
        local ok, serr
        if slot == SLOT_PULL then ok, serr = cfgstore.save_pull(t)
        else ok, serr = cfgstore.save_poll(t) end
        if not ok then return M.reply("RET:FAIL:CFG:" .. tostring(serr)) end





        local in_poll_mode = cur_mode == "manual" or cur_mode == "platform"

        local poll = pollmod(true)
        if not poll then return M.reply("RET:FAIL:CFG:bus/poll 不可用") end
        if poll.needs_restart(n) then
            if poll.is_running() then
                poll.stop()
                poll.apply_cfg(n)

                poll.start(slot)
            else
                poll.apply_cfg(n)
                if in_poll_mode then poll.start(slot) end
            end
        else
            poll.apply_cfg(n)
            if in_poll_mode and not poll.is_running() then




                poll.start(slot)
            end
        end
        if iot and iot.reply_config then pcall(iot.reply_config) end
        M.reply("RET:CFG=OK")
    end)

    M.reg("R:REG", function()

        local pm = pollmod(false)
        local regs = pm and pm.get_regs() or nil
        reply_json("RET:REG=", jencode(regs or {}))
    end)

    M.reg("R:VAL", function()
        reply_json("RET:VAL=", jencode(collector.snapshot()))
    end)



    local function stat_parts()
        local parts = {}
        local m = ctrl.status()
        if m then parts[#parts + 1] = '"mode":' .. jencode(m) end
        local d = collector.stats()
        if d then parts[#parts + 1] = '"data":' .. jencode(d) end
        if guard then parts[#parts + 1] = '"guard":' .. jencode(guard.status()) end
        local it = iot and iot.status() or nil
        if it then







            local j = jencode(it)
            parts[#parts + 1] = '"mqtt":' .. j
        end
        return parts
    end


    M.reg("R:STAT", function()




        reply_json("RET:STAT=", stat_parts())
    end)


    function M._stat_reply()
        local parts = stat_parts()
        return parts, json_reply_str("RET:STAT=", parts)
    end


    M.reg("W:PULLCFG", function()
        if not iot then return M.reply("RET:FAIL:PULLCFG:iot 不可用") end
        if iot.pulling() then return M.reply("RET:PULLCFG=BUSY") end
        local ok, err = iot.pull_start()
        if not ok then return M.reply("RET:FAIL:PULLCFG:" .. tostring(err)) end
        M.reply("RET:PULLCFG=started")
    end)

    M.reg("R:PULLCFG", function()
        if not iot then return M.reply("RET:FAIL:PULLCFG:iot 不可用") end
        reply_json("RET:PULLCFG=", jencode(iot.pull_status()))
    end)





    M.reg("W:CLRPULL", function()
        if not cfgstore then return M.reply("RET:FAIL:CLRPULL:cfgstore 不可用") end

        if iot and iot.pulling() then
            return M.reply("RET:FAIL:CLRPULL:平台正在拉取中, 稍后重试")
        end
        local ok, err, wrote = cfgstore.clear_pull()
        if not ok then return M.reply("RET:FAIL:CLRPULL:" .. tostring(err)) end


        log.info("cmd", string.format("W:CLRPULL cleared=%s", tostring(wrote)))
        if wrote then return M.reply("RET:CLRPULL=OK;cleared:platform 配置")
        else return M.reply("RET:CLRPULL=OK;cleared:") end
    end)


    M.reg("R:MQTT", function()
        local e = mqtt_cfg.effective(device_id_str())
        reply_json("RET:MQTT=", jencode({
            cfg = e.cfg,
            auto_pass = e.cfg.auto and e.cfg.auto.pass or "",
            manual_on = e.cfg.manual_on,
            pub = e.pub,
            sub = e.sub,
            ready = e.ready,
            err = e.err,
            stat = iot and iot.status() or nil,
        }))
    end)

    M.reg("W:MQTT", function(arg)
        if not iot then return M.reply("RET:FAIL:MQTT:no iot") end
        local t = jdecode(arg)
        if not t then return M.reply("RET:FAIL:MQTT:bad json") end
        local ok, err = iot.apply_cfg(t)
        if ok then M.reply("RET:MQTT=OK") else M.reply("RET:FAIL:MQTT:" .. tostring(err)) end
    end)


    M.reg("W:MQTTRC", function()
        if not iot then return M.reply("RET:FAIL:MQTTRC:no iot") end
        iot.kick()
        M.reply("RET:MQTTRC=OK")
    end)

    M.reg("R:REPORT", function()
        if not iot then return M.reply("RET:FAIL:REPORT:no iot") end
        iot.report_now()
        M.reply("RET:REPORT=OK")
    end)

    M.reg("W:BOOTMODE", function(arg)
        local m = trim(arg)
        local ok, err = cfgstore.save_sys({ boot_mode = m })
        if not ok then return M.reply("RET:FAIL:BOOTMODE:" .. tostring(err)) end
        M.reply("RET:BOOTMODE=OK")
    end)


    M.reg("R:SALIAS", function()
        reply_json("RET:SALIAS=", jencode(cfgstore.load_alias()))
    end)


    M.reg("W:SALIAS", function(arg)
        local t = jdecode(arg)
        if not t then return M.reply("RET:FAIL:SALIAS:bad json") end
        local function s(v) if type(v) == "string" then return v end return "" end
        local key = s(t.key)
        if not key:match("^reg%d+$") then
            return M.reply("RET:FAIL:SALIAS:bad key(要 reg<addr>)")
        end
        local ok, err = cfgstore.set_alias(key, s(t.id), s(t.name))
        if not ok then return M.reply("RET:FAIL:SALIAS:" .. tostring(err)) end
        M.reply("RET:SALIAS=OK")
    end)

    M.reg("R:BOOTMODE", function()



        local sysc = cfgstore and cfgstore.load_sys()
        M.reply("RET:BOOTMODE=" .. (sysc and sysc.boot_mode or "idle"))
    end)












    M.reg("R:FRAMES", function(arg)
        local n = 20
        if arg then
            local v = tonumber(arg)
            if v then n = math.floor(v) end
        end
        if n < 1 then n = 1 end
        if n > 50 then n = 50 end
        reply_json("RET:FRAMES=", jencode(mon.recent_frames(n)))
    end)











    M.reg("R:INFER", function(arg)
        local off, n = 0, nil
        if arg and arg ~= "" then
            local a, b = arg:match("^(%d*)%s*,%s*(%d*)")
            if a then
                off = tonumber(a) or 0
                n = tonumber(b)
            else
                local v = tonumber(arg)
                if v then off = v end
            end
        end

        mon.set_infer_view(off, n)
        reply_big("RET:INFER=", jencode(iot.attach_names(mon.infer_page(off, n))))
    end)







    M.reg("W:INFERWATCH", function(arg)
        local on = (arg == "1" or arg == "on" or arg == "true")
        mon.set_infer_watch(on)
        M.reply("RET:INFERWATCH=" .. tostring(on))
    end)








    M.reg("R:AUTODETECT", function(arg)
        if arg == "restart" then
            if not mon.is_running() then
                return M.reply("RET:FAIL:AUTODETECT:not in sniff mode")
            end


            if cfgstore and cfgstore.clear_alias then pcall(cfgstore.clear_alias) end
            local ok, err = mon.restart_detect()
            if not ok then
                return M.reply("RET:FAIL:AUTODETECT:" .. tostring(err))
            end
            return M.reply("RET:AUTODETECT=BUSY")
        end
        if not mon.is_running() then
            return M.reply("RET:FAIL:AUTODETECT:not in sniff mode")
        end
        if mon.is_detecting() then
            return M.reply("RET:AUTODETECT=BUSY")
        end
        local last = mon.detect_result()
        if last then
            return reply_json("RET:AUTODETECT=", jencode({
                baud = last.baud, databits = last.databits,
                stopbits = last.stopbits, parity = last.parity,
                fallback = last.fallback or false,  -- Q2: 区分命中 vs 兜底 cfg.BAUD
            }))
        end
        mon.request_detect()
        M.reply("RET:AUTODETECT=BUSY")
    end)
end









local function reg_debug_cmds()
    M.reg("W:GC", function()
        collector.trim_cache()
        collectgarbage("collect")
        collectgarbage("collect")
        if iot then iot.kick() end
        M.reply("RET:GC=OK")
    end)

    M.reg("W:RAWTEST", function(arg)
        if blocked_while_detecting("RAWTEST") then return end
        local poll = pollmod(true)
        if not poll then return M.reply("RET:FAIL:RAWTEST:bus/poll 不可用") end
        local a, b, c = arg:match("^%s*(%d*)%s*,?%s*(%d*)%s*,?%s*(%d*)%s*$")
        local r, err = poll.probe_raw(
            a ~= "" and tonumber(a) or nil,
            b ~= "" and tonumber(b) or nil,
            c ~= "" and tonumber(c) or nil)
        if not r then return M.reply("RET:FAIL:RAWTEST:" .. tostring(err)) end
        M.reply(string.format("RET:RAWTEST tx_ok=%s tx=%s rx_len=%d parsed=%s rx=%s",
            tostring(r.tx_ok), r.tx_hex, r.rx_len, tostring(r.parsed),
            r.rx_hex == "" and "(空)" or r.rx_hex))
        if not r.tx_ok then
            log.warn("cmd", "RAWTEST uart.write 失败:", r.tx_err)
        elseif r.rx_len == 0 then
            log.warn("cmd", "RAWTEST 无任何回字节: 查 AB线/从机地址/波特率/DE极性/从机是否上电")
        elseif not r.parsed then
            log.warn("cmd", "RAWTEST 有字节但 CRC 不过: 查 波特率/校验位/停止位/AB线序")
        end
    end)

    M.reg("W:RING", function(arg)


        local on = (arg == "1" or arg == "on" or arg == "true")
        collector.ring_enable(on)
        M.reply("RET:RING=" .. tostring(on))
    end)

    M.reg("R:RING", function()
        local out = collector.get_ring()
        reply_json("RET:RING=", jencode(out))
    end)

end -- R:FRAMES/R:INFER/R:AUTODETECT 已转正到 reg_cmds (2026-10, 见上面说明)

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




    _G.cmd_push_infer = M.push_infer


    if _G.DEBUG then reg_debug_cmds() end
    local names = {}
    for k in pairs(g_cmds) do names[#names + 1] = k end
    table.sort(names)
    log.info("cmd", "ready on VUART via prov hook, cmds:", table.concat(names, " "))
    return true
end

_G.vcom_handle = function(line) return M.handle(line) end

return M
