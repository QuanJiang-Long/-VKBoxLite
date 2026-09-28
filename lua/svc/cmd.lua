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
    -- R:INFO: 前端打开串口读设备信息用的第一条指令
    -- ⚠️ mobile.iccid / mobile.csq / mobile.rsrp 是【函数】, 必须调用取号,
    --    直接塞函数引用会让 json.encode 整表失败 -> 返回 "{}" -> 前端全空
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
        M.reply("RET:INFO=" .. jencode({
            project = _G.PROJECT,
            version = _G.VERSION,
            sn = _G.get_device_sn and _G.get_device_sn(),
            sn_state = sn.state(),
            lock = sn.locked() and 1 or 0,
            imei = sn.imei(),
            iccid = mval("iccid"),
            csq = mval("csq"),
            rsrp = mval("rsrp"),
            server = mq and mq.host or nil,
            baud = pc and pc.baud or cfg.BAUD,
            slave = pc and pc.slave or cfg.SLAVE_ADDR,
            regs = pc and #(pc.regs or {}) or 0,
        }))
    end)

    -- R:MODE: 前端 renderHome 读 st.mode/st.busy/st.poll/st.mon
    M.reg("R:MODE", function()
        M.reply("RET:MODE=" .. jencode(ctrl.status()))
    end)

    M.reg("W:MODE", function(arg)
        local v = trim(arg):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if v == "stop" then v = "idle" end
        local ok, msg = ctrl.switch_mode(v)
        if ok then M.reply("RET:MODE=OK") else M.reply("RET:FAIL:MODE:" .. tostring(msg)) end
    end)

    M.reg("R:CFG", function()
        M.reply("RET:CFG=" .. jencode({ cfg = cfgstore.load_poll(), src = cfgstore.poll_src() }))
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
        M.reply("RET:SNIFFCFG=" .. jencode({ cfg = cfgstore.load_sniff(), src = "fskv" }))
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

    -- R:STAT: 前端 renderHome 读
    -- R:STAT: 前端 readHome 读四段 mode/data/guard/mqtt
    --   ⚠️ mode 段必须是【对象】(与 R:MODE 同形: {mode,busy,poll,mon,write}),
    --     不能是字符串。前端 readHome 里 S.modeStat = r.data.mode 后
    --     renderMode 会取 st.mode, 字符串没有 .mode -> undefined -> 'idle',
    --     表现为一切换模式就被打回 idle。
    --   ⚠️ 段名必须是 data(前端读 full.data.points), 不是 collector
    M.reg("R:STAT", function()
        local st = {
            mode = ctrl.status(),
            data = collector.stats(),
            guard = guard and guard.status() or nil,
        }
        local it = iot and iot.status() or nil
        st.iot = it
        st.mqtt = it               -- 前端 readHome 读 r.data.mqtt
        M.reply("RET:STAT=" .. jencode(st))
    end)

    -- 平台配置拉取: W 发起(立即应答), R 轮询状态。
    -- 握手在 iot 的 task_main 协程里跑, 这里不能阻塞等待 MQTT 回包。
    M.reg("W:PULLCFG", function()
        if not iot then return M.reply("RET:FAIL:PULLCFG:iot 不可用") end
        local ok, err = iot.pull_start()
        if not ok then return M.reply("RET:FAIL:PULLCFG:" .. tostring(err)) end
        M.reply("RET:PULLCFG=started")
    end)

    M.reg("R:PULLCFG", function()
        if not iot then return M.reply("RET:FAIL:PULLCFG:iot 不可用") end
        M.reply("RET:PULLCFG=" .. jencode(iot.pull_status()))
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

    -- R:MQTT: 前端读 r.cfg / r.pub / r.sub / r.ready / r.err / r.stat
    M.reg("R:MQTT", function()
        local e = mqtt_cfg.effective(device_id_str())
        M.reply("RET:MQTT=" .. jencode({
            cfg = e.cfg,
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

    M.reg("R:REPORT", function()
        if not iot then return M.reply("RET:FAIL:REPORT:no iot") end
        iot.report_now()
        M.reply("RET:REPORT=OK")
    end)

    -- R:IOTSTAT: 前端 MQTT 页读 connected/published/failed/last_err
    M.reg("R:IOTSTAT", function()
        if not iot then return M.reply("RET:FAIL:IOTSTAT:no iot") end
        local s = iot.status()
        M.reply("RET:IOTSTAT=" .. jencode({
            connected = s.connected,
            published = s.published,
            failed = s.failed,
            last_err = s.last_err,
            last_pub = s.last_pub,
            subscribed = s.subscribed,
            backoff = s.backoff,
        }))
    end)

    -- R:NET / R:MEM: 网络与内存诊断(并入 R:STAT, 保留独立指令便于现场排查)
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

    M.reg("W:RAWTEST", function(arg)
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

    -- R:FRAMES[=n]  n 取 1..50, 默认 20(与原工程一致)
    M.reg("R:FRAMES", function(arg)
        local n = 20
        if arg then
            local v = tonumber(arg)
            if v then n = math.floor(v) end
        end
        if n < 1 then n = 1 end
        if n > 50 then n = 50 end
        M.reply("RET:FRAMES=" .. jencode(mon.recent_frames(n)))
    end)

    -- R:INFER: 从旁听帧反推轮询表
    M.reg("R:INFER", function()
        M.reply("RET:INFER=" .. jencode(mon.infer()))
    end)

    -- W:APPLYINFER: 把推断结果写入 poll 配置
    M.reg("W:APPLYINFER", function()
        local ok, err = mon.apply_infer()
        if ok then M.reply("RET:APPLYINFER=OK") else M.reply("RET:FAIL:APPLYINFER:" .. tostring(err)) end
    end)

    -- R:SNIFF=ms: 静默侦听总线 ms 毫秒, 返回帧数
    M.reg("R:SNIFF", function(arg)
        local ms = 3000
        if arg then
            local v = tonumber(arg)
            if v then ms = math.floor(v) end
        end
        local n = mon.sniff_count(ms)
        M.reply("RET:SNIFF=" .. tostring(n))
    end)

    -- W:TX=hex: 裸发一串字节(前端总线诊断)
    M.reg("W:TX", function(arg)
        if not arg or arg == "" then return M.reply("RET:FAIL:TX:empty hex") end
        local r, err = poll.tx_raw(arg)
        if not r then return M.reply("RET:FAIL:TX:" .. tostring(err)) end
        M.reply(string.format("RET:TX=OK tx_ok=%s rx_len=%d parsed=%s rx=%s",
            tostring(r.tx_ok), r.rx_len, tostring(r.parsed),
            r.rx_hex == "" and "(空)" or r.rx_hex))
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
