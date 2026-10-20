local util = require "util"
local cfg = require "core/config"
local log = util.log()

local uart = util.get("uart")
local json = util.try("json")
local rtos = util.try("rtos")
local mobile = util.try("mobile")

local sn = require "sn/sn"
local ctrl = require "bus/ctrl"
local poll = require "bus/poll"
local mon = require "bus/mon"
local collector = require "data/collector"
local cfgstore = require "cfg"
local mqtt_cfg = require "iot/mqttcfg"
local iot = util.try("iot/iot")
local guard = util.try("svc/guard")

local M = {}

-- 4 种工作模式提到模块顶部
-- 记录 3: 删 MODE_POLL/MODE_PULL (历史别名)。项目测试阶段, 没正式发布,
-- 不存在老 fskv 兼容场景, normalize_sys 限 4 值直接拒。
local MODE_MANUAL, MODE_PLATFORM, MODE_IDLE, MODE_SNIFF = "manual", "platform", "idle", "sniff"
-- 内部 cfgstore 槽名常量 (跟 boot_mode 历史别名不同, 是项目内部 API, 保留)
local SLOT_POLL, SLOT_PULL = "poll", "pull"

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

    -- R:MODE: 前端 renderHome 读 st.mode/st.busy/st.poll/st.mon
    M.reg("R:MODE", function()
        M.reply("RET:MODE=" .. jencode(ctrl.status()))
    end)

    M.reg("W:MODE", function(arg)
        local v = trim(arg):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if v == "stop" then v = MODE_IDLE end
        -- 记录 3: 软切删了。"poll"/"pollpull" 现在直接被 ctrl.switch_mode
        -- 走下游拒掉, 不会翻译成 manual/platform。
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
        local slot = (ctrl.get_mode() == "platform") and SLOT_PULL or SLOT_POLL
        local cfg = (slot == SLOT_PULL) and cfgstore.load_pull() or cfgstore.load_poll()
        -- src 必须反映本次 cfg 实际所在槽: pollpull 档下 ds_poll 空着但
        -- ds_pull 已被平台覆盖的情况很常见 (老用户从 poll 切到 pollpull),
        -- 之前这里写 poll_src() 永远查 K_POLL, 前端拿 src='default' 误判
        -- "平台没下发", 实际 ds_pull 已经有平台配置. 用 slot 决定查哪个 src
        local src = (slot == SLOT_PULL) and cfgstore.pull_src() or cfgstore.poll_src()
        M.reply("RET:CFG=" .. jencode({ cfg = cfg, slot = slot, src = src }))
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
        -- 34-fix: 进入 polling 档 (manual/platform) 时, 如果 poll 因为空配置
        --   没起来 (34-fix 的副作用, 之前一定起来), 现在 W:CFG 写完要把
        --   poll 启起来, 否则用户添了表保存后什么都看不到
        -- idle/sniff 档: poll 本来就不该起, 即便 get_mode() 算出 SLOT_POLL
        --   也不在这两档起 (前端不会在这两档发 W:CFG, 这层防御是兜底)
        local in_poll_mode = cur_mode == "manual" or cur_mode == "platform"
        if poll.needs_restart(n) then
            if poll.is_running() then
                poll.stop()
                poll.apply_cfg(n)
                -- ⚠️ 必须带槽: poll.start() 不传 src 会把 curSlot 强制置成 "poll"
                poll.start(slot)
            else
                poll.apply_cfg(n)
                if in_poll_mode then poll.start(slot) end
            end
        else
            poll.apply_cfg(n)
            if in_poll_mode and not poll.is_running() then
                -- 34-fix: needs_restart 不成立但 poll 没起来 (例如:
                --   manual 档进入时空 ds_poll → 34-fix 不起 → 用户添
                --   寄存器表但 baud/slave 没动 → needs_restart=false →
                --   之前没人调 poll.start). 补起
                poll.start(slot)
            end
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

    -- 38-fix: W:CLRPULL 清空 ds_pull. 场景: 前端从 platform 切 manual/sniff
    --   时弹窗, 默认勾选清空平台拉取配置. 设备收到后只擦 ds_pull (不动
    --   ds_poll / mqtt_manual / mqtt auto 凭证). 留个"已清空"应答, 前端
    --   能区分"设备端正常清掉了"和"命令丢失 / 设备忙".
    M.reg("W:CLRPULL", function()
        if not cfgstore then return M.reply("RET:FAIL:CLRPULL:cfgstore 不可用") end
        -- 不能在 platform 档正在拉取中清: 拉取链路可能正在写 ds_pull
        if iot and iot.pulling() then
            return M.reply("RET:FAIL:CLRPULL:平台正在拉取中, 稍后重试")
        end
        local ok, err, wrote = cfgstore.clear_pull()
        if not ok then return M.reply("RET:FAIL:CLRPULL:" .. tostring(err)) end
        -- wrote=false 时 ds_pull 本来就是空, 也回 ok 不报错, 避免前端
        -- 出现"没清成功"的误提示
        log.info("cmd", string.format("W:CLRPULL cleared=%s", tostring(wrote)))
        if wrote then return M.reply("RET:CLRPULL=OK;cleared:platform 配置")
        else return M.reply("RET:CLRPULL=OK;cleared:") end
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

    M.reg("R:BOOTMODE", function()
        -- 读开机默认模式 (fskv ds_sys.boot_mode)。前端 "运行状态总览" 卡片
        -- 用, 跟 W:BOOTMODE 配对: 改了 selBootMode 但没保存, 设备值跟本地
        -- 值不一致, 提示 dirty
        local sysc = cfgstore and cfgstore.load_sys()
        M.reply("RET:BOOTMODE=" .. (sysc and sysc.boot_mode or "idle"))
    end)

    -- ===== 2026-10 转正: 以下 3 条原在 B 类调试组 (发布版不注册) =====
    -- 但它们已是 sniff 档前端的正式依赖:
    --   R:AUTODETECT = 识别通讯参数的唯一入口 (切档自动识别/手动重识别全走它)
    --   R:INFER      = 推断轮询表 (识别成功自动推 / 最新值/参数名称两列都在它)
    --   R:FRAMES     = 总线报文卡的 2s 轮询 + 手动刷新
    -- 留在调试组的话, _build_flag=true 的发布固件里这仨查无此键:
    -- 平台上报不受影响 (设备内部 mon 照常跑), 但上位机三个诊断面板全灭,
    -- 且报错文案 ("21 组候选都没解出") 引导排查往 AB 线上去 = 误导现场。
    -- 所以挪进正式组。真要减表的瘦身面, 瘦的是 UI 入口而不是指令注册;
    -- 闭包只捕获 mon/iot, 开销可忽略。剩下确属探针/诊断的 4 条仍留 B 组
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

    -- R:INFER: 从旁听帧反推轮询表 (attach_names 给每行补 name 字段, 与
    --   U4 上报的 name 同一套映射, 前端推断表"参数名称"列直接显示)
    M.reg("R:INFER", function()
        M.reply("RET:INFER=" .. jencode(iot.attach_names(mon.infer())))
    end)

    -- R:AUTODETECT: 非阻塞, 由前端轮询; 带 =restart 参数则强制作废上一轮
    --   结果并重扫 (前端「重新识别通讯参数」按钮用)。裸发时若已有 last
    --   结果设备会直接回旧值 —— 用户点"重新识别"结果只是复读旧参数,
    --   设备根本没重新扫 (2026-10 定性); 所以重扫必须显式走 restart,
    --   这与 request_detect 的语义一致: 清 detect_result + 重启 detect_loop
    M.reg("R:AUTODETECT", function(arg)
        if arg and tostring(arg) ~= "" then
            if not mon.is_running() then
                return M.reply("RET:FAIL:AUTODETECT:not in sniff mode")
            end
            mon.request_detect()
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
            return M.reply("RET:AUTODETECT=" .. jencode({
                baud = last.baud, databits = last.databits,
                stopbits = last.stopbits, parity = last.parity,
                fallback = last.fallback or false,  -- Q2: 区分命中 vs 兜底 cfg.BAUD
            }))
        end
        mon.request_detect()
        M.reply("RET:AUTODETECT=BUSY")
    end)
end

-- B 类：仅开发调试用的 4 条指令。发布版整个函数不调用,
-- 键 + 闭包 + 闭包内捕获的 poll/iot 等 upvalue 全部不进注册表,
-- 出厂固件更小、也不接受任何探针/总线诊断入口。
-- 注: R:NET/R:MEM 信息已合并到 R:STAT 的 iot/guard 段, 这里
-- 留独立指令仅供现场外挂调试工具(PC 串口)调, 产线/前端均不调
-- (R:FRAMES/R:INFER/R:AUTODETECT 已转正进 reg_cmds, 见上面的说明)
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
    -- 发布版: 调试组 4 条 (R:NET/R:MEM/W:GC/W:RAWTEST) 整组不注册;
    -- R:FRAMES/R:INFER/R:AUTODETECT 已转正在 reg_cmds, 发布版仍可用
    if _G.DEBUG then reg_debug_cmds() end
    local names = {}
    for k in pairs(g_cmds) do names[#names + 1] = k end
    table.sort(names)
    log.info("cmd", "ready on VUART via prov hook, cmds:", table.concat(names, " "))
    return true
end

_G.vcom_handle = function(line) return M.handle(line) end

return M
