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



















local function tx_frags(frags)
    local n = 0
    for i = 1, #frags do n = n + #frags[i] end

    local head = ""
    for i = 1, #frags do
        if #head >= 80 then break end
        head = head .. frags[i]:sub(1, 80 - #head)
    end
    log.debug("cmd", "tx:", n, "B:", head)
    for i = 1, #frags do
        if #frags[i] > 0 then pcall(uart.write, UART_ID, frags[i]) end
    end
end

function M.reply(s)
    tx_frags({ s, "\r\n" })
end


local function reply_big(key, payload)
    tx_frags({ key, payload, "\r\n" })
end












local function json_reply_frags(key, val)
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
    return t
end
local function json_reply_str(key, val)
    return table.concat(json_reply_frags(key, val))
end
local function reply_json(key, val)
    tx_frags(json_reply_frags(key, val))
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

    local prov = package.loaded["sn/prov"]
    if prov and prov.busy and prov.busy() then
        log.debug("cmd", "skip INFER_PUSH: SN busy")
        return false
    end
    local off, n = mon.infer_view()
    local ok, inf = pcall(mon.infer_page, off, n)
    if not ok or type(inf) ~= "table" then return false end

    if iot and iot.attach_names then inf = iot.attach_names(inf) end
    reply_big("RET:INFER_PUSH=", jencode(inf))
    return true
end


















local TR_ON, TR, TR_LAST = false, nil, nil

local function trc_sample(stage)
    if not TR then return end
    local used, mx = -1, -1
    if rtos then
        local ok, _, u, m = pcall(rtos.meminfo, "lua")
        if ok then
            if type(u) == "number" then used = u end
            if type(m) == "number" then mx = m end
        end
    end
    local s = TR.s
    s[#s + 1] = string.format("%s %d/%d", stage, used, mx)
end

local function trc_begin(nbytes)
    if not TR_ON then return end


    if TR then TR_LAST = TR end
    TR = { arg = nbytes, regs = -1, tot = -1, s = {} }
    if rtos then
        local ok, t = pcall(rtos.meminfo, "lua")
        if ok and type(t) == "number" then TR.tot = t end
    end
    trc_sample("enter")
end







local function trc_freed()
    if not TR then return end
    collectgarbage("collect")
    trc_sample("freed")
end

local function trc_regs(n)
    if not TR then return end
    TR.regs = (type(n) == "table") and #(n.regs or {}) or -1
end




local function trc_line(tr, tag)
    if not tr then return nil end
    local p = { string.format("%s arg=%d regs=%d tot=%d", tag, tr.arg, tr.regs, tr.tot) }
    for i = 1, #tr.s do p[#p + 1] = tr.s[i] end
    return table.concat(p, " | ")
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
            imsi = mval("imsi"),
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



        local loader = (slot == SLOT_PULL) and cfgstore.load_pull or cfgstore.load_poll
        local cfg, lerr = loader()




        if lerr then return M.reply("RET:FAIL:CFG:" .. lerr) end




        local src = (slot == SLOT_PULL) and cfgstore.pull_src() or cfgstore.poll_src()
        reply_json("RET:CFG=", jencode({ cfg = cfg, slot = slot, src = src }))
    end)

    M.reg("W:CFG", function(arg)
        if blocked_while_detecting("CFG") then return end
        trc_begin(#arg)






        if #arg > 4096 then collectgarbage("collect") end
        trc_sample("gc")
        local t = jdecode(arg)
        trc_sample("decoded")
        if not t then return M.reply("RET:FAIL:CFG:bad json") end





        local n, err = cfgstore.normalize_poll(t, true)

        trc_sample("norm")


        if not n then return M.reply("RET:FAIL:CFG:" .. tostring(err)) end
        trc_regs(n)
        trc_freed()
        local cur_mode = ctrl.get_mode()
        local slot = (cur_mode == "platform") and SLOT_PULL or SLOT_POLL
        local ok, serr


        if slot == SLOT_PULL then ok, serr = cfgstore.save_pull_norm(n)
        else ok, serr = cfgstore.save_poll_norm(n) end

        trc_sample("saved")
        if not ok then return M.reply("RET:FAIL:CFG:" .. tostring(serr)) end





        local in_poll_mode = cur_mode == "manual" or cur_mode == "platform"

        local poll = pollmod(true)
        if not poll then return M.reply("RET:FAIL:CFG:bus/poll 不可用") end
        if poll.needs_restart(n) then
            if poll.is_running() then
                poll.stop()
                poll.apply_cfg(n)


                poll.start(slot, n)
            else
                poll.apply_cfg(n)
                if in_poll_mode then poll.start(slot, n) end
            end
        else
            poll.apply_cfg(n)
            if in_poll_mode and not poll.is_running() then




                poll.start(slot, n)
            end
        end
        if iot and iot.reply_config then pcall(iot.reply_config) end




        trc_sample("done")
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




    M.reg("W:CLRINFER", function()
        if not cfgstore then return M.reply("RET:FAIL:CLRINFER:cfgstore 不可用") end
        local ok, err, wrote = cfgstore.clear_infer()
        if not ok then return M.reply("RET:FAIL:CLRINFER:" .. tostring(err)) end
        log.info("cmd", string.format("W:CLRINFER cleared=%s", tostring(wrote)))
        if wrote then return M.reply("RET:CLRINFER=OK;cleared:sniff 推断表")
        else return M.reply("RET:CLRINFER=OK;cleared:") end
    end)




    M.reg("W:CLRPOLL", function()
        if not cfgstore then return M.reply("RET:FAIL:CLRPOLL:cfgstore 不可用") end
        local ok, err, wrote = cfgstore.clear_poll()
        if not ok then return M.reply("RET:FAIL:CLRPOLL:" .. tostring(err)) end
        log.info("cmd", string.format("W:CLRPOLL cleared=%s", tostring(wrote)))
        if wrote then return M.reply("RET:CLRPOLL=OK;cleared:manual 配置")
        else return M.reply("RET:CLRPOLL=OK;cleared:") end
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


    M.reg("R:NET", function()
        if not mobile then return M.reply("RET:NET=mobile unavailable") end
        local st = mobile.status() or -1
        local c = (st==1 or st==5) and mobile.scell() or nil
        M.reply(string.format("RET:NET=iccid:%s;imsi:%s;imei:%s;num:%s;status:%d;csq:%s;rsrp:%s;rsrq:%s;snr:%s;band:%s;tac:%s;eci:%s;ip:%s",
            tostring(mobile.iccid()), tostring(mobile.imsi()), tostring(mobile.imei()),
            tostring(mobile.number()), st,
            tostring(mobile.csq()), tostring(mobile.rsrp()), tostring(mobile.rsrq()),
            tostring(mobile.snr()),
            tostring(c and c.band), tostring(c and c.tac), tostring(c and c.eci),
            tostring(socket.localIP() or "-")))
    end)


    M.reg("R:IOT", function()
        if not iot then return M.reply("RET:IOT=iot unavailable") end
        local s = iot.status()
        M.reply(string.format("RET:IOT=want:%d;conn:%d;sub:%d;sn:%s;host:%s:%s;manual:%d;pub:%s;subt:%s;ok:%d;fail:%d;bo:%d;err:%s;last:%s",
            s.want_run and 1 or 0, s.connected and 1 or 0, s.subscribed and 1 or 0,
            tostring(s.device_id), tostring(s.host), tostring(s.port),
            s.manual_on and 1 or 0, tostring(s.pub), tostring(s.sub),
            s.published or 0, s.failed or 0, s.backoff or 0,
            tostring(s.last_err or s.reject_reason or "-"), tostring(s.last_pub or "-")))
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
        local m = trim(arg):lower()
        local ok, err = cfgstore.save_sys({ boot_mode = m })
        if not ok then return M.reply("RET:FAIL:BOOTMODE:" .. tostring(err)) end

        local cleared = {}
        if m == MODE_MANUAL then

            local ok1, _, w1 = cfgstore.clear_pull()
            if ok1 and w1 then cleared[#cleared + 1] = "platform" end
            local ok2, _, w2 = cfgstore.clear_infer()
            if ok2 and w2 then cleared[#cleared + 1] = "sniff" end
        elseif m == MODE_PLATFORM then

            local ok1, _, w1 = cfgstore.clear_poll()
            if ok1 and w1 then cleared[#cleared + 1] = "manual" end
            local ok2, _, w2 = cfgstore.clear_infer()
            if ok2 and w2 then cleared[#cleared + 1] = "sniff" end
        elseif m == MODE_SNIFF then

            local ok1, _, w1 = cfgstore.clear_poll()
            if ok1 and w1 then cleared[#cleared + 1] = "manual" end
            local ok2, _, w2 = cfgstore.clear_pull()
            if ok2 and w2 then cleared[#cleared + 1] = "platform" end
        end

        if #cleared > 0 then
            M.reply("RET:BOOTMODE=OK;cleared:" .. table.concat(cleared, "+"))
        else
            M.reply("RET:BOOTMODE=OK")
        end
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

        local addr = tonumber(key:match("^reg(%d+)$"))
        if addr and mon.update_row_name then
            pcall(mon.update_row_name, addr, s(t.name), s(t.id), s(t.dtype))
        end
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

            if cfgstore and cfgstore.clear_infer then pcall(cfgstore.clear_infer) end
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
    TR_ON = true                   -- 打开 W:CFG 的分阶段采样(见文件顶部说明)
    M.reg("W:GC", function()
        collector.trim_cache()
        collectgarbage("collect")
        collectgarbage("collect")
        if iot then iot.kick() end
        M.reply("RET:GC=OK")
    end)













    M.reg("R:MEM", function()
        local p = {}
        p[#p + 1] = string.format("lua:%dK", math.floor(collectgarbage("count")))
        if rtos then


            for _, k in ipairs({ "lua", "sys" }) do
                local ok, total, used = pcall(rtos.meminfo, k)
                if ok and type(total) == "number" and type(used) == "number" then
                    p[#p + 1] = string.format("%s:%d/%d", k, used, total)
                end
            end
        end
        local last_ok, first_fail = 0, 0
        local steps = { 1024, 2048, 3072, 4096, 6144, 8192, 12288, 16384 }
        for i = 1, #steps do
            local n = steps[i]
            collectgarbage("collect")
            local ok, s = pcall(string.rep, "x", n)
            if ok and type(s) == "string" and #s == n then
                last_ok = n
            else
                first_fail = n
                break
            end
        end
        p[#p + 1] = string.format("max:%d fail:%d", last_ok, first_fail)
        M.reply("RET:MEM=" .. table.concat(p, " "))
    end)


















    M.reg("W:FS", function()
        local p, verdict = {}, "?"












        local ENV = _ENV or _G -- 5.1 上没有 _ENV(取到 nil), 退回 _G
        local function env_get(n)
            local ok, v = pcall(function() return ENV[n] end)
            if not ok then return nil, "raise" end
            return v, type(v)
        end
        local function look(n)
            local _, t = env_get(n)
            local tr = util.try(n)
            return n .. "(env:" .. t .. " raw:" .. type(rawget(ENV, n))
                .. " try:" .. type(tr) .. ")"
        end
        p[#p + 1] = look("io")
        p[#p + 1] = look("os")
        local io_lib = (env_get("io"))
        local os_lib = (env_get("os"))

        local function is_lib(t)
            return type(t) == "table" or type(t) == "userdata"
        end
        local function fn(t, n)
            if not is_lib(t) then return "no-lib" end

            local ok, v = pcall(function() return t[n] end)
            if not ok then return "index-raise" end
            return tostring(type(v))
        end
        p[#p + 1] = "open:" .. fn(io_lib, "open")
        p[#p + 1] = "fsstat:" .. fn(io_lib, "fsstat")
        p[#p + 1] = "exist:" .. fn(io_lib, "exists")
        p[#p + 1] = "fsize:" .. fn(io_lib, "fileSize")
        p[#p + 1] = "rm:" .. fn(io_lib, "remove")
        p[#p + 1] = "ren:" .. fn(os_lib, "rename")
        if rtos then p[#p + 1] = "rtos.fsinfo:" .. tostring(type(rtos.fsinfo)) end



        local function nums(t)
            local out = {}
            for i = 1, #t do
                if type(t[i]) == "number" then out[#out + 1] = t[i] end
            end
            return out
        end
        local space = "?"
        if fn(io_lib, "fsstat") == "function" then
            local pack = { pcall(io_lib.fsstat, "/") }
            local n = nums(pack)
            if #pack >= 1 and pack[1] and #n >= 2 then


                local tot, free
                if #n >= 3 then
                    tot, free = n[1] * n[3], (n[1] - n[2]) * n[3]
                else
                    tot, free = n[1], n[1] - n[2]
                end
                if free < 0 then free = -1 end
                space = string.format("%dK/%dK", math.floor(free / 1024),
                    math.floor(tot / 1024))
                local raw = {}
                for i = 1, #n do raw[i] = tostring(n[i]) end
                p[#p + 1] = "fs=" .. table.concat(raw, ",")
            else
                space = "stat-fail"
            end
        end
        p[#p + 1] = "free:" .. space


        local blob = nil
        if fn(io_lib, "open") ~= "function" then


            p[#p + 1] = "blob:skip"
            verdict = "B:NO(没有io.open)"
        else
            local ok, s = pcall(string.rep, "x", 8192)
            if ok and type(s) == "string" and #s == 8192 then blob = s end
            if not blob then
                p[#p + 1] = "blob:FAIL-8K"
                verdict = "B:NO-MEM(8KB申请不到)"
            else
                local done, open_nil = false, false
                for _, tmp in ipairs({ "/vk_probe.tmp", "vk_probe.tmp" }) do
                    if not done then
                        local bin = tmp:gsub("tmp$", "bin")
                        local r = { path = tmp:sub(1, 1) }
                        local f = io_lib.open(tmp, "wb")
                        if not f then
                            r.w = "open-nil"
                            open_nil = true
                        else
                            local wok = f:write(blob)
                            f:close()
                            r.w = wok and "ok" or "write-fail"
                            local sz = io_lib.fileSize and io_lib.fileSize(tmp) or -1
                            r.wsz = tostring(sz)
                            if fn(os_lib, "rename") == "function" then
                                r.ren = tostring(os_lib.rename(tmp, bin))
                            else
                                r.ren = "no-rename"
                            end
                            local g = io_lib.open(bin, "rb")
                            if g then
                                local got = g:read("*a") or ""
                                g:close()
                                r.rsz = tostring(#got)
                            else
                                r.rsz = "read-fail"
                            end
                            if io_lib.remove then
                                io_lib.remove(bin)
                                io_lib.remove(tmp)
                            end
                            if io_lib.exists then
                                r.left = tostring(io_lib.exists(tmp) or io_lib.exists(bin))
                            end



                            done = (r.w == "ok" and r.rsz == "8192")
                        end
                        local q = {}
                        for k, v in pairs(r) do q[#q + 1] = k .. "=" .. v end
                        table.sort(q)
                        p[#p + 1] = "probe:" .. table.concat(q, " ")
                    end
                end
                if done then
                    verdict = "B:YES"
                elseif open_nil then
                    verdict = "B:NO(open返回nil)"
                else
                    verdict = "B?:写了没读回8192"
                end
            end
        end
        log.info("fs", "probe", verdict, space)
        M.reply("RET:FS=" .. table.concat(p, " ") .. " =>" .. verdict)
    end)








    M.reg("R:CTRACE", function()
        if not TR then return M.reply("RET:CTRACE=empty (还没发过 W:CFG)") end
        local one = trc_line(TR_LAST, "#1")
        if one then M.reply("RET:CTRACE=" .. one) end
        M.reply("RET:CTRACE=" .. trc_line(TR, "#2"))
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






    local eq = line:find("=", 1, true)
    local fn, arg
    if eq then
        fn = g_cmds[line:sub(1, eq - 1)]
        if fn then arg = line:sub(eq + 1) end
    else
        fn = g_cmds[line]
        arg = line
    end
    if not fn then return false end
    local ok, err = pcall(fn, arg)
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
