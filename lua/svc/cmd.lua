local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local uart = corelib.get("uart")
local json = corelib.try("json")
local rtos = corelib.try("rtos")
local mobile = corelib.try("mobile")

local sn = require "sn/sn"
local ctrl = require "bus/ctrl"
local poll = require "bus/poll"
local mon = require "bus/mon"
local collector = require "data/collector"
local cfgstore = require "cfg"
local mqtt_cfg = require "iot/mqttcfg"
local iot = corelib.try("iot/iot")
local guard = corelib.try("svc/guard")

local M = {}

-- 4 种工作模式提到模块顶部
local MODE_POLL, MODE_PULL, MODE_IDLE, MODE_SNIFF = "poll", "pull", "idle", "sniff"

local UART_ID = uart.VUART_0
if UART_ID == nil then UART_ID = 4 end

local g_cmds = {}

function M.reply(s)
    log.debug("cmd", "tx:", s)
    pcall(uart.write, UART_ID, s .. "\r\n")
end

-- 识别期间挡住会动串口的命令
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

-- A 类：上位软件业务必需的 16 条指令
local function reg_cmds()
    -- R:INFO: 前端打开串口读设备信息用的第一条指令
    -- ⚠️ mobile.iccid / mobile.csq / mobile.rsrp 是【函数】, 必须调用取号
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
        if v == "stop" then v = MODE_IDLE end
        local ok, msg, cleared = ctrl.switch_mode(v)
        if not ok then return M.reply("RET:FAIL:MODE:" .. tostring(msg)) end
        -- 切回 idle 会顺带复位配置。用 k:v 而不是 k=v: protocol.js 的 kv 解析
        -- 要求整段里同时有 ';' 和 ':' 才拆键值对
        if cleared and #cleared > 0 then
            M.reply("RET:MODE=OK;cleared:" .. table.concat(cleared, "+"))
        else
            M.reply("RET:MODE=OK")
        end
    end)

    M.reg("R:CFG", function()
        -- 按当前运行模式取对应的配置槽
        local slot = (ctrl.get_mode() == "pollpull") and MODE_PULL or MODE_POLL
        local cfg = (slot == MODE_PULL) and cfgstore.load_pull() or cfgstore.load_poll()
        M.reply("RET:CFG=" .. jencode({ cfg = cfg, slot = slot, src = cfgstore.poll_src() }))
    end)

    M.reg("W:CFG", function(arg)
        if blocked_while_detecting("CFG") then return end
        local t = jdecode(arg)
        if not t then return M.reply("RET:FAIL:CFG:bad json") end
        local n, err = cfgstore.normalize_poll(t)
        if not n then return M.reply("RET:FAIL:CFG:" .. tostring(err)) end
        local slot = (ctrl.get_mode() == "pollpull") and MODE_PULL or MODE_POLL
        local ok, serr
        if slot == MODE_PULL then ok, serr = cfgstore.save_pull(t)
        else ok, serr = cfgstore.save_poll(t) end
        if not ok then return M.reply("RET:FAIL:CFG:" .. tostring(serr)) end
        if poll.needs_restart(n) then
            if poll.is_running() then
                poll.stop()
                poll.apply_cfg(n)
                -- ⚠️ 必须带槽: poll.start() 不传 src 会把 curSlot 强制置成 "poll"
                poll.start(slot)
            else
                poll.apply_cfg(n)
            end
        else
            poll.apply_cfg(n)
        end
        if iot and iot.reply_config then pcall(iot.reply_config) end
        M.reply("RET:CFG=OK")
    end)

    M.reg("R:REG", function()
        M.reply("RET:REG=" .. jencode(poll.get_regs()))
    end)

    M.reg("R:VAL", function()
        M.reply("RET:VAL=" .. jencode(collector.snapshot()))
    end)

    -- R:STAT: 前端 readHome 读 mode/data/guard/mqtt 段
    M.reg("R:STAT", function()
        local st = {
            mode = ctrl.status(),
            data = collector.stats(),
            guard = guard and guard.status() or nil,
        }
        local it = iot and iot.status() or nil
        st.iot = it
        st.mqtt = it
        M.reply("RET:STAT=" .. jencode(st))
    end)

    -- 平台配置拉取: W 发起, R 轮询状态
    M.reg("W:PULLCFG", function()
        if not iot then return M.reply("RET:FAIL:PULLCFG:iot 不可用") end
        if iot.pulling() then return M.reply("RET:PULLCFG=BUSY") end
        local ok, err = iot.pull_start()
        if not ok then return M.reply("RET:FAIL:PULLCFG:" .. tostring(err)) end
        M.reply("RET:PULLCFG=started")
    end)

    M.reg("R:PULLCFG", function()
        if not iot then return M.reply("RET:FAIL:PULLCFG:iot 不可用") end
        M.reply("RET:PULLCFG=" .. jencode(iot.pull_status()))
    end)

    -- R:MQTT: 前端读 cfg / auto_pass / manual_on / pub / sub
    M.reg("R:MQTT", function()
        local e = mqtt_cfg.effective(device_id_str())
        M.reply("RET:MQTT=" .. jencode({
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

    -- W:MQTTRC: 只重连, 不写配置
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
end

-- B 类：仅开发调试用的 9 条指令。发布版整个函数不调用,
-- 9 个字符串键 + 9 个闭包 + 闭包内捕获的 mon/poll/iot 等 upvalue
-- 全部不进注册表, 出厂固件更小、也不接受任何探针/总线诊断入口。
-- 注: R:NET/R:MEM 信息已合并到 R:STAT 的 iot/guard 段, 这里
-- 留独立指令仅供现场外挂调试工具(PC 串口)调, 产线/前端均不调
local function reg_debug_cmds()
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
        if blocked_while_detecting("RAWTEST") then return end
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

    -- R:FRAMES[=n]  n 取 1..50, 默认 20
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

    -- R:AUTODETECT: 非阻塞, 由前端轮询
    M.reg("R:AUTODETECT", function()
        if not mon.is_running() then
            return M.reply("RET:FAIL:AUTODETECT:not in sniff mode")
        end
        if mon.is_detecting() then
            return M.reply("RET:AUTODETECT=BUSY")
        end
        local last = mon.detect_result()
        if last then
            return M.reply("RET:AUTODETECT=" .. jencode({
                baud = last.baud, databits = last.databits,
                stopbits = last.stopbits, parity = last.parity,
            }))
        end
        mon.request_detect()
        M.reply("RET:AUTODETECT=BUSY")
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

    -- W:TX=hex: 裸发一串字节
    M.reg("W:TX", function(arg)
        if blocked_while_detecting("TX") then return end
        if not arg or arg == "" then return M.reply("RET:FAIL:TX:empty hex") end
        local r, err = poll.tx_raw(arg)
        if not r then return M.reply("RET:FAIL:TX:" .. tostring(err)) end
        M.reply(string.format("RET:TX=OK tx_ok=%s rx_len=%d parsed=%s rx=%s",
            tostring(r.tx_ok), r.rx_len, tostring(r.parsed),
            r.rx_hex == "" and "(空)" or r.rx_hex))
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
    -- 发布版: 9 条 B 类调试指令整组不注册
    if _G.DEBUG then reg_debug_cmds() end
    local names = {}
    for k in pairs(g_cmds) do names[#names + 1] = k end
    table.sort(names)
    log.info("cmd", "ready on VUART via prov hook, cmds:", table.concat(names, " "))
    return true
end

_G.vcom_handle = function(line) return M.handle(line) end

return M
