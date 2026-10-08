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

local UART_ID = uart.VUART_0
if UART_ID == nil then UART_ID = 4 end

local g_cmds = {}

function M.reply(s)
    log.debug("cmd", "tx:", s)
    pcall(uart.write, UART_ID, s .. "\r\n")
end

-- 识别期间挡住会动串口的命令。识别正在 21 个候选间反复 uart.setup, 此时写配置
-- 或裸发字节会跟它抢同一条串口, 出来的结果不可信。
-- 返回 true 表示已挡掉(调用方直接 return), false 表示放行。
-- 只读命令和 W:MODE 不走这里: W:MODE 的闸门在 ctrl.switch_mode 里, 且它必须
-- 放行 idle 当逃生口
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
        local ok, msg, cleared = ctrl.switch_mode(v)
        if not ok then return M.reply("RET:FAIL:MODE:" .. tostring(msg)) end
        -- 切回 idle 会顺带复位配置。用 k:v 而不是 k=v: protocol.js 的 kv 解析
        -- (decode 末尾那段)要求整段里同时有 ';' 和 ':' 才拆键值对,
        -- 写成 cleared=... 前端只会拿到一整条字符串, 取不出清了什么
        if cleared and #cleared > 0 then
            M.reply("RET:MODE=OK;cleared:" .. table.concat(cleared, "+"))
        else
            M.reply("RET:MODE=OK")
        end
    end)

    M.reg("R:CFG", function()
        -- 按当前运行模式取对应的配置槽: 手动配置看 ds_poll, 拉取配置看 ds_pull。
        -- 不这么分的话, 拉取档下表单显示的仍是手配那份寄存器表, 用户改了半天
        -- 存的还是手配槽, 和"正在采的那份"对不上(见 lua/README.md 配置来源隔离)
        local slot = (ctrl.get_mode() == "pollpull") and "pull" or "poll"
        local cfg = (slot == "pull") and cfgstore.load_pull() or cfgstore.load_poll()
        M.reply("RET:CFG=" .. jencode({ cfg = cfg, slot = slot, src = cfgstore.poll_src() }))
    end)

    M.reg("W:CFG", function(arg)
        if blocked_while_detecting("CFG") then return end
        local t = jdecode(arg)
        if not t then return M.reply("RET:FAIL:CFG:bad json") end
        local n, err = cfgstore.normalize_poll(t)
        if not n then return M.reply("RET:FAIL:CFG:" .. tostring(err)) end
        -- 按当前运行模式选槽保存, 与 R:CFG 的选槽规则同一套:
        -- 拉取档写 ds_pull, 其余写 ds_poll。
        -- 不这么分的话, 实测会撞上三个去向三个语义: 改 baud/slave 时重启且
        -- poll.start() 不传槽会把 curSlot 翻成 "poll", 界面自己跳回手动配置卡;
        -- 只改 interval/regs 时不重启, 下次进拉取档又读回 ds_pull 的旧值。
        -- 用户无法预期自己改的到底存在哪、采的是哪份
        local slot = (ctrl.get_mode() == "pollpull") and "pull" or "poll"
        local ok, serr
        if slot == "pull" then ok, serr = cfgstore.save_pull(t)
        else ok, serr = cfgstore.save_poll(t) end
        if not ok then return M.reply("RET:FAIL:CFG:" .. tostring(serr)) end
        if poll.needs_restart(n) then
            if poll.is_running() then
                poll.stop()
                poll.apply_cfg(n)
                -- ⚠️ 必须带槽: poll.start() 不传 src 会把 curSlot 强制置成
                -- "poll"(见 poll.lua 的 start), 拉取档下保存等于静默切档
                poll.start(slot)
            else
                poll.apply_cfg(n)
            end
        else
            poll.apply_cfg(n)
        end
        -- 手动保存也是应用确认，回一次 U6。与自动保存那条路径共用 reply_config，
        -- 里面按 msgId + replied 去重，所以两份都走到也不会重发
        if iot and iot.reply_config then pcall(iot.reply_config) end
        M.reply("RET:CFG=OK")
    end)

    -- R:SNIFFCFG / W:SNIFFCFG / W:WRITE / W:WRITEJ / R:IOTSTAT / R:POLL /
    -- W:RST / W:REG 已删除：前端零调用，且分别被 MQTT 下行写 /
    -- R:STAT 的各段完全覆盖。写结果看 R:STAT 的 write 段，不另立指令。
    -- ⚠️ W:REG 是被 W:CFG 覆盖的：前端「保存配置」把 regs 并进 cfg 一起发
    -- (app.js 的 collectCfg + cfg.regs = regs)，所以单独一条写寄存器表的
    -- 指令从来没人调

    M.reg("R:REG", function()
        M.reply("RET:REG=" .. jencode(poll.get_regs()))
    end)

    M.reg("R:VAL", function()
        M.reply("RET:VAL=" .. jencode(collector.snapshot()))
    end)

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

    -- R:MQTT: 前端读 r.cfg(手动档表单) / r.auto_pass(首页凭证密码) /
    -- r.manual_on(当前档次) / r.pub / r.sub(实际生效成品) / r.ready / r.err / r.stat
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

    -- W:MQTTRC: 只重连，不写配置。等价于 iot.kick()：销毁 client 后
    -- backoff 归 1，task_main 下一轮立刻重连（wait_kickable 会被 kick_flag 打断）
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

    -- R:AUTODETECT: 非阻塞。识别最坏 21s 且失败会一直重试, 同步等会把命令
    -- 分发循环堵死(前端所有指令一起卡), 所以这里只回当前状态, 由前端轮询。
    --   BUSY              = 正在扫, 过会儿再问
    --   RET:AUTODETECT=…  = 上一轮已识别出的参数(刷新页面后也拿得到)
    --   RET:FAIL:…        = 没进 sniff 模式
    -- 注意不自动帮用户进 sniff: 一条查询指令不该有切模式的副作用
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
        -- 没在扫也没有结果: 现在起一轮(前端「重新识别」按钮走这里)
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

    -- W:TX=hex: 裸发一串字节(前端总线诊断)
    M.reg("W:TX", function(arg)
        if blocked_while_detecting("TX") then return end
        if not arg or arg == "" then return M.reply("RET:FAIL:TX:empty hex") end
        local r, err = poll.tx_raw(arg)
        if not r then return M.reply("RET:FAIL:TX:" .. tostring(err)) end
        M.reply(string.format("RET:TX=OK tx_ok=%s rx_len=%d parsed=%s rx=%s",
            tostring(r.tx_ok), r.rx_len, tostring(r.parsed),
            r.rx_hex == "" and "(空)" or r.rx_hex))
    end)

    M.reg("W:BOOTMODE", function(arg)
        local m = trim(arg)
        local ok, err = cfgstore.save_sys({ boot_mode = m })
        if not ok then return M.reply("RET:FAIL:BOOTMODE:" .. tostring(err)) end
        M.reply("RET:BOOTMODE=OK")
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
