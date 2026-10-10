local util = require "util"
local cfg = require "cfg"
local log = util.log()

local sys = util.get("sys")
local json = util.try("json")
local mqtt = util.try("mqtt")
local rtos = util.try("rtos")
local mobile = util.try("mobile")
local socket = util.try("socket")

local collector = require "data/collector"
local pullcfg = require "iot/pullcfg"
local mon = require "bus/mon"
-- 惰性 require, 避免 main.lua 初始化时把 uart 未 setup 的 poll 提前拖起来
local poll
local function get_poll()
    if not poll then
        local ok, p = pcall(require, "bus/poll")
        poll = ok and p or false
    end
    return poll or nil
end

-- 问 ctrl, 拿不到当 idle (宁可少订也不能给未接任务乱订)
local ctrl_mod
local function get_mode()
    if ctrl_mod == nil then
        local ok, p = pcall(require, "bus/ctrl")
        ctrl_mod = ok and p or false
    end
    return (ctrl_mod and ctrl_mod.get_mode()) or "idle"
end

local function poll_slot()
    local p = get_poll()
    return (p and p.slot()) or "poll"
end

-- ⚠️ 不能写死 load_poll: 平台按 ds_pull 里的寄存器表下发 id, 拿 ds_poll
--    解析会全部静默失败 (只有一行 write item unresolvable 日志)。
--    alias_map 同理: 上报 name 也要按在用的那份映射
local function active_cfg()
    local f = (poll_slot() == "pull") and cfg.load_pull or cfg.load_poll
    local ok, c = pcall(f)
    return (ok and c) or nil
end

local M = {}

local S = {}

local function reset_state()
    S = {
        want_run = false, connected = false, subscribed = false,
        client = nil, dirty = false, backoff = 1,
        published = 0, failed = 0, replied = 0, kick_flag = false,
        recv_pending = nil, pub = nil, sub = nil, subs = nil, device_id = nil,
        last_pub = 0, last_err = nil, client_id = nil, user = nil,
        reject_reason = nil,
        pull = {
            state = "idle", msg = "", result = nil, deadline = 0,
            msg_id = nil, replied = false,
            -- src = "pull"/"push": 谁给的这份结果, 提示语不同
            src = nil,
            seen = 0,   -- OS time, 收到这份配置的时间
        },
        pull_payload = nil,
        push_n = 0, push_err = nil,
        autosaved = false, autosave_at = 0, autosave_regs = 0,
        meta_sig = nil, topo_sig = nil, res_at = 0,
        busy_s = 0, span_s = 0,
        -- ⚠️ hello_at = 连接内最后一次 hello 成功发送时间 (非上电时间)
        --    置 0 表示还没发过 hello, 30min 重发计时不起跑
        hello_at = 0,
    }
end

local function device_id()
    return _G.get_device_sn and _G.get_device_sn()
end

-- 平台签发凭证是 "SN_" (下划线后空), 不带 ProductId, 写死对不上
local function default_client_id(did)
    if not did or did == "" then return did end
    return did .. "_"
end

local function get_topic()
    local did = device_id()
    if not did or did == "" then return nil end
    return string.format(cfg.PLATFORM_GET_TOPIC, did)
end

local function mcall(k)
    if not mobile then return nil end
    local f = mobile[k]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f)
    return ok and v or nil
end

local function imei()
    local v = mcall("imei")
    return v and tostring(v) or ""
end

local function alias_map()
    local c = active_cfg()
    if not c or not c.regs then return {} end
    local m = {}
    for _, r in ipairs(c.regs) do m[r.name] = r.alias or r.name end
    return m
end

-- 5 个 helper alias (各起一行因 check_lua local 收集只处理 2 元)
local pad = util.pad
local int_str = util.int_str
local ms_of = util.ms_of
local jstr = util.jstr
local jnum = util.jnum

-- 7 个发送点共用: 判连接 + pcall, 同时是连接闸门
local function pub(topic, body, qos)
    if not S.client or not S.connected then return false, "未连接" end
    local ok, e = pcall(function() S.client:publish(topic, body, qos or 1) end)
    if not ok then return false, tostring(e) end
    return true
end

local function cur_did()
    local d = S.device_id or device_id()
    return (d and d ~= "") and d or nil
end

-- id 兜底 "unknown": 平台核销指令的键, 缺了平台对不上是哪一条
local function items_json(list, ts)
    local out = {}
    for _, it in ipairs(list) do
        local v = jnum(it.value) or "null"
        out[#out + 1] = ts
            and string.format('{"id":%s,"value":%s,"ts":%s}', jstr(it.id or "unknown"), v, ts)
            or string.format('{"id":%s,"value":%s}', jstr(it.id or "unknown"), v)
    end
    return "[" .. table.concat(out, ",") .. "]"
end

local function net_registered(csq)
    return not (type(csq) == "number" and csq == 0)
end

-- sniff key "s{slave}_r{addr}" 带从机号, 轮询 key 不带 (一份配置 1 个 slave).
-- 少了 -{n} 后缀, 平台无法把数据归属到子设备
local function build_items()
    local amap = alias_map()
    local c = active_cfg()
    local cfg_slave = c and c.slave or nil
    local by_slave, order = {}, {}
    for k, d in pairs(collector.get_all_latest()) do
        local vs = jnum(d.value)
        if vs then
            local slave = tonumber(k:match("^s(%d+)_r%d+$")) or cfg_slave
            if slave then
                if not by_slave[slave] then
                    by_slave[slave] = {}
                    order[#order + 1] = slave
                end
                by_slave[slave][#by_slave[slave] + 1] =
                    string.format('{"id":%s,"name":%s,"value":%s,"ts":%s}',
                        jstr(k), jstr(amap[k] or k), vs, ms_of(d.ts))
            end
        end
    end
    table.sort(order)
    local items = {}
    for n, slave in ipairs(order) do
        items[#items + 1] = {
            idx = n, slave = slave,
            body = "[" .. table.concat(by_slave[slave], ",") .. "]",
        }
    end
    return items
end

-- 自动档按 V3 拼 -{n} (平台认子设备用), 手动档原样用 (用户 broker 不认后缀)
local function publish()
    if not S.client or not S.connected then return false end
    local items = build_items()
    if #items == 0 then return false end
    local base = S.pub or ""
    if base == "" then return false end
    local manual = cfg.mqtt_load().manual_on
    local any = false
    for _, it in ipairs(items) do
        local topic = manual and base or (base .. "-" .. it.idx)
        local ok, err = pcall(function()
            S.client:publish(topic, it.body, cfg.mqtt_load().qos)
        end)
        if ok then
            S.published = S.published + 1
            any = true
        else
            S.failed = S.failed + 1
            log.warn("iot", string.format("publish fail sub %d (slave %d): %s",
                it.idx, it.slave, tostring(err)))
        end
    end
    if any then
        S.dirty = false
        S.last_pub = os.time()
    end
    return any
end

-- ===== U2 拓扑上报 / U3 网关资源 / U7 指令回执 =====

local function heap_info()
    if not rtos or type(rtos.meminfo) ~= "function" then return nil, nil end
    local ok, a, b = pcall(rtos.meminfo, "sys")
    if not ok or type(a) ~= "number" then return nil, nil end
    return a, b
end

local PARITY_LETTER = { [0] = "N", [1] = "E", [2] = "O" }

local function serial_json(c)
    c = c or {}
    return string.format('{"port":"/dev/ttyS1","baudRate":%d,"dataBits":%d,"stopBits":%d,"parity":%s}',
        c.baud or cfg.BAUD, c.databits or cfg.DATABITS,
        c.stopbits or cfg.STOPBITS, jstr(PARITY_LETTER[c.parity or cfg.PARITY] or "N"))
end

-- ⚠️ nodeIndex 必须和 U4 的 -{n} 同一套序号, 否则建档的子设备和
--    上报的数据对不上, 症状是"拓扑发成功了但数据不进去"
local function node_json(idx, slave, c, regs)
    local props = {}
    for _, r in ipairs(regs) do
        local dt = r.dtype or "uint16"
        local id
        if r.name and r.name ~= "" and not r.name:match("^r%d+$") then
            id = r.alias or r.name
        else
            -- 嗅探模式: 跟 U4 上报 collector key (s{slave}_r{addr}) 对齐
            -- 平台按 id 匹配 property, id 跟 U4 key 一致才能归属
            id = "s" .. slave .. "_r" .. r.addr
        end
        local name = r.alias or id
        props[#props + 1] = string.format(
            '{"id":%s,"name":%s,"dataType":%s,"unit":"","modbus":{"slave":%d,"address":%d,"quantity":%d,"dataType":%s}}',
            jstr(id), jstr(name), jstr(dt), slave, r.addr, r.count or 1, jstr(dt))
    end
    return string.format(
        '{"nodeIndex":%d,"slaveId":%d,"kind":"RTU","serial":%s,"model":{"tslName":%s,"properties":[%s]}}',
        idx, slave, serial_json(c), jstr("sniff_s" .. slave), table.concat(props, ","))
end

-- ⚠️ sniff 的 serial 必须用 mon.status().detected 而不是 active_cfg():
--    实测识别出 2400 却发了 9600, 平台照错的波特率建配置,
--    拿这份配置去轮询一帧都收不到
local function poll_regs()
    local c = active_cfg()
    if c and c.regs and #c.regs > 0 then
        return { [c.slave] = c.regs }
    end
    return nil
end
local function poll_serial() return active_cfg() end

local MODE = {
    sniff = {
        regs = function()
            local at, by = {}, {}
            local function put(slave, r)
                local k = slave .. ":" .. r.addr
                local p = at[k]
                if p then
                    p.count, p.name, p.alias, p.dtype = r.count, r.name, r.alias, r.dtype or "uint16"
                    return
                end
                p = { addr = r.addr, count = r.count, name = r.name, alias = r.alias, dtype = r.dtype or "uint16" }
                at[k] = p
                by[slave] = by[slave] or {}
                by[slave][#by[slave] + 1] = p
            end
            for _, r in ipairs(mon.infer().regs or {}) do
                put(r.slave, { addr = r.addr, count = r.count, fc = r.fc, dtype = "uint16" })
            end
            local pc = cfg.load_pull()
            for _, r in ipairs((pc and pc.regs) or {}) do
                put(pc.slave, r)
            end
            return by
        end,
        serial = function()
            local st = mon.status()
            local d = st.detected
            return {
                baud = (d and d.baud) or st.baud,
                databits = (d and d.databits) or 8,
                stopbits = (d and d.stopbits) or 1,
                parity = (d and d.parity) or 0,
            }
        end,
        err = "还没识别到在线的从机",
    },
    poll = { regs = poll_regs, serial = poll_serial, err = "没有可用的寄存器表" },
    manual = { regs = poll_regs, serial = poll_serial, err = "没有可用的寄存器表" },
}

local function build_nodes()
    local m = MODE[get_mode()] or MODE.poll
    local by = m.regs()
    if not by or not next(by) then return nil, m.err end
    local ser = m.serial()
    local sl = {}
    for s in pairs(by) do sl[#sl + 1] = s end
    table.sort(sl)
    local nodes = {}
    for i, s in ipairs(sl) do
        nodes[#nodes + 1] = node_json(i, s, ser, by[s])
    end
    return table.concat(nodes, ",")
end

local function topo_sig()
    local nodes = build_nodes()
    if not nodes then return nil end
    return tostring(#nodes) .. ":" .. nodes
end

-- U2 双重用途: 带 nodes = 子设备建档, 不带 nodes = 网关元数据上报. 拆两帧不合成

-- fwVersion 平台侧是 BigDecimal, 传字符串会【整帧被丢】(用户确认)
local function fw_num()
    local v = _G.VERSION or ""
    local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)")
    if not a then return 0 end
    return tonumber(a) * 10000 + tonumber(b) * 100 + tonumber(c)
end

local function send_meta()
    local did = cur_did()
    if not did then return false, "无 SN" end
    local csq = mcall("csq")
    if type(csq) ~= "number" then csq = nil end
    local v = _G.VERSION or "0.0.0"
    -- [name, value, is_str] 数组. is_str=true 用 jstr, false 直接拼 (数字)
    local p = {
        {"vendor", "VKBox", true},
        {"model", cfg.PLATFORM_MODEL, true},
        {"fwVersion", v, true},
        {"sn", did, true},
        {"deviceSn", did, true},
        {"imei", imei(), true},
        {"iccid", tostring(mcall("iccid") or ""), true},
        {"fw", "v" .. v, true},
        {"firmwareVersion", fw_num(), false},
        {"hw", cfg.PLATFORM_MODEL, true},
        {"capabilities", '["modbus","mqtt"]', false},  -- 已是 JSON 数组, 不加引号
        {"deviceName", "VKBOX-" .. did, true},
        {"serialNumber", did, true},
    }
    if csq then p[#p + 1] = {"csq", csq, false} end
    p[#p + 1] = {"netRegister", tostring(net_registered(csq)), false}
    p[#p + 1] = {"networkAddress", cfg.mqtt_load().host, true}
    p[#p + 1] = {"isShadow", 0, false}
    p[#p + 1] = {"summary", "VKBox Bootstrap", true}
    p[#p + 1] = {"deviceType", 3, false}
    p[#p + 1] = {"locationWay", 0, false}
    p[#p + 1] = {"ts", os.time() * 1000, false}
    local parts = {}
    for i, x in ipairs(p) do
        parts[i] = x[3] and string.format('"%s":%s', x[1], jstr(x[2]))
                              or string.format('"%s":%s', x[1], tostring(x[2]))
    end
    return pub(string.format(cfg.PLATFORM_INFO_TOPIC, did), "{" .. table.concat(parts, ",") .. "}", 1)
end

local function send_topo()
    local did = cur_did()
    if not did then return false, "无 SN" end
    local nodes, err = build_nodes()
    if not nodes then return false, err end
    return pub(string.format(cfg.PLATFORM_INFO_TOPIC, did),
        string.format('{"vendor":%s,"model":%s,"fwVersion":%s,"ts":%d,"nodes":[%s]}',
            jstr("VKBox"), jstr(cfg.PLATFORM_MODEL), jstr(_G.VERSION or "0.0.0"),
            os.time() * 1000, nodes), 1)
end

local function meta_sig()
    local csq = mcall("csq")
    return string.format("%s|%s|%s|%s", imei(),
        tostring(mcall("iccid") or ""), tostring(type(csq) == "number" and csq or ""),
        tostring(cfg.mqtt_load().host or ""))
end

-- U3 口径: ram_percent = rtos.meminfo 已用/总量, 真实系统内存
--   uptime_sec = os.clock() 开机起算, 不受 NTP 跳变
--   cpu_percent = 主循环忙碌占比 (实测, 非 MCU CPU). 平台按 90% 做 CPU 告警需知此口径
local function send_gw_res()
    local did = cur_did()
    if not did then return false end
    local total, used = heap_info()
    local ts = ms_of(os.time())
    local ram = 0
    if total and total > 0 then
        ram = math.floor(used * 1000 / total) / 10
    end
    local cpu = 0
    if S.busy_s and S.span_s and S.span_s > 0 then
        cpu = math.min(100, math.max(0, math.floor(S.busy_s * 1000 / S.span_s) / 10))
    end
    local ok = pub(string.format(cfg.PLATFORM_RES_TOPIC, did),
        items_json({
            { id = "ram_percent", value = ram },
            { id = "uptime_sec", value = math.floor(os.clock()) },
            { id = "cpu_percent", value = cpu },
        }, ts), 1)
    if not ok then return false end
    S.res_at = os.time()
    S.busy_s, S.span_s = 0, 0
    return true
end

-- U7: 入队成功回原值, 拒绝回 null. 但"入队成功 != 已发到总线" (enqueue_write 异步)
local function func_reply(rs)
    if not rs or #rs == 0 then return false end
    local did = cur_did()
    if not did then return false end
    local ok, e = pub(string.format(cfg.PLATFORM_FPOST_TOPIC, did),
        items_json(rs, nil), 1)
    if not ok then
        log.warn("iot", "func reply fail:", tostring(e))
        return false
    end
    return true
end

-- 除 idle 外都订 4 条 gw 平台前缀 (config/get + func/pset/pget) + 用户 sub_topic
-- ⚠️ manual 必须订 sub_topic, 不订用户那条 = 用户配的下行永远收不到
-- ⚠️ sniff 进时沿用切入前清单, 会少订 4 条平台 topic, 平台下发全丢
local function build_subs()
    local subs = {}
    local function add(t)
        if not t or t == "" then return end
        for _, x in ipairs(subs) do
            if x == t then return end
        end
        subs[#subs + 1] = t
    end
    if get_mode() == "idle" then return subs end
    local did = S.device_id
    if not did or did == "" then return subs end
    add(string.format(cfg.PLATFORM_GET_TOPIC, did))
    add(string.format(cfg.PLATFORM_FUNC_TOPIC, did))
    add(string.format(cfg.PLATFORM_PSET_TOPIC, did))
    add(string.format(cfg.PLATFORM_PGET_TOPIC, did))
    add(S.sub)
    return subs
end

-- ⚠️ 必须在 on_mqtt 之前定义 (local 词法作用域, 否则 error 分支调时取 nil)
local function destroy_client()
    if S.client then
        -- 先关自动重连再断开, 否则断开后库仍会自行重连, 留下僵尸 client 占十几 KB
        pcall(function() S.client:autoreconn(false) end)
        pcall(function() S.client:disconnect() end)
        pcall(function() S.client:close() end)
        S.client = nil
    end
    S.connected = false
    S.subscribed = false
    collectgarbage("collect")
end

local function on_mqtt(cli, event, data, payload)
    if event == "conack" then
        S.connected = true
        S.backoff = 1
        S.reject_reason = nil
        -- 重置 hello_at 让 task_main 在新连接上重新发一次 hello
        S.hello_at = 0
        local subs = build_subs()
        S.subs = subs
        S.subscribed = false
        local qos = cfg.mqtt_load().qos
        for _, t in ipairs(subs) do
            local sok, serr = pcall(function() cli:subscribe(t, qos) end)
            if not sok then log.warn("iot", "subscribe fail:", t, tostring(serr)) end
            S.subscribed = S.subscribed or sok
        end
        log.info("iot", string.format("conack ok, subscribed=%s, topics=[%s]",
            tostring(S.subscribed), table.concat(subs, " ")))
    elseif event == "recv" then
        S.recv_pending = { topic = data, payload = payload }
    elseif event == "disconnect" or event == "error" then
        S.connected = false
        S.subscribed = false
        -- CONACK 0x05 = 平台拒(未授权), LuatOS C 库只打日志不到 Lua 层, 单独记 reject_reason
        -- ⚠️ 不能塞 last_err: try_connect 满 15s 后会覆盖成 "conack timeout", 原因丢了
        -- ⚠️ 必须只让 conack 错误覆盖: 一次被拒会连收两条 (error conack, error other),
        --    后者是拆 socket 时补发, 语义更弱, 覆盖会把"被拒"变成"连不上"
        if event == "error" then
            local d = tostring(data)
            if d == "conack" or not S.reject_reason then
                if d == "conack" then
                    S.reject_reason = "平台拒绝连接(CONACK 0x05 未授权), 检查地址/端口或补用户名密码"
                else
                    S.reject_reason = "连不上服务器(" .. d .. "): 域名解析不到或端口不通, 核对 host 拼写"
                end
            end
            -- ⚠️ 立刻销毁: broker 拒绝是毫秒级结论, 等满 15s 让 backoff 叠加, 现场多等一轮才生效
            destroy_client()
        end
        log.warn("iot", event, tostring(data))
    end
end

-- 能否建连: mobile 库缺失时返回 true (没有依据就不能拦着连接)
local function net_ready()
    return net_registered(mcall("csq"))
end

local function try_connect()
    if not mqtt then return false, "mqtt 库不可用(需 sysplus/mqtt 组件)" end
    if type(mqtt.create) ~= "function" then return false, "mqtt.create 不可用" end
    local c = cfg.mqtt_load()
    local did = device_id()
    if not did or did == "" then
        if not c.allow_no_sn then return false, "no sn" end
        did = "unknown"
    end
    S.device_id = did
    local prof, terr = cfg.mqtt_profile(did)
    if not prof then return false, terr end
    S.pub, S.sub = prof.pub, prof.sub
    -- B 模型: clientId = "SN_", username = 裸 SN, 密码 = 平台签发凭证
    local cid = c.client_id ~= "" and c.client_id or default_client_id(did)
    S.client_id = cid
    local user = prof.user ~= "" and prof.user or did
    S.user = user
    -- Air780EP Lua 堆约 300KB, mqtt.create 需要连续块; 建连前先 GC
    collectgarbage("collect")
    local h1, h2 = heap_info()
    log.info("iot", "create mqtt", c.host, c.port, "heap total=" .. tostring(h1) .. " used=" .. tostring(h2))
    -- ⚠️ 这行是现场排查 CONACK 0x05 的关键: 看到就知道 clientId/用户名发了什么
    log.info("iot", string.format("connect: host=%s port=%d ssl=%s clientId=%s user=%s clean=%s",
        c.host, c.port, tostring(c.ssl), cid, user, tostring(not c.keep_session)))
    local okc, cli = pcall(mqtt.create, nil, c.host, c.port, c.ssl)
    if not okc or not cli then return false, "mqtt.create 失败: " .. tostring(cli) end
    S.client = cli
    -- user 在上面兜底成 SN, 必然非空. 平台拒空 username 的坑 (EMQX/NanoMQ) 走不到
    pcall(function() cli:auth(cid, user,
                              prof.pass ~= "" and prof.pass or nil, not c.keep_session) end)
    pcall(function() cli:keepalive(60) end)
    pcall(function() cli:autoreconn(false) end)
    local okon, eon = pcall(cli.on, cli, on_mqtt)
    if not okon then
        destroy_client()
        return false, "on 失败: " .. tostring(eon)
    end
    local ok, e = pcall(cli.connect, cli)
    if not ok or not e then
        destroy_client()
        return false, "connect 失败: " .. tostring(e)
    end
    -- ⚠️ 拒是毫秒级结论, 立即返回真实原因, 不要等满 15s (会叠加 backoff)
    local waited = 0
    while waited < 15000 do
        if S.connected then return true end
        if not S.client then break end
        if sys then sys.wait(100) end
        waited = waited + 100
    end
    if not S.connected then
        destroy_client()
        return false, S.reject_reason or "conack timeout"
    end
    return true
end

local function wait_kickable(ms)
    local waited = 0
    while waited < ms do
        if not S.want_run then return end
        if S.kick_flag then S.kick_flag = false; return end
        if sys then sys.wait(200) end
        waited = waited + 200
    end
end

local function downlink_write(items)
    local ok, poll = pcall(require, "bus/poll")
    if not ok or not poll then
        log.error("iot", "downlink write: bus/poll 不可用")
        return 0, 0
    end
    -- ⚠️ 必须按当前在用的槽取寄存器表和默认从机地址, 不能写死 ds_poll:
    --    拉取档在采的是 ds_pull, 平台的 id 是按那份表下发的。拿 ds_poll 解析
    --    会全部落到 write item unresolvable, 从机地址也可能取错
    local c = active_cfg()
    local regs = (c and c.regs) or {}
    local dslave = (c and c.slave) or cfg.SLAVE_ADDR
    local function resolve_addr(k)
        if not k then return nil end
        if type(k) ~= "string" then
            if type(k) == "number" then return math.floor(k) end
            return nil
        end
        for _, r in ipairs(regs) do
            if r.name == k or r.alias == k then return r.addr end
        end
        local lk = k:lower()
        for _, r in ipairs(regs) do
            if r.name:lower() == lk or (r.alias and r.alias:lower() == lk) then return r.addr end
        end
        return nil
    end
    local function dnum(v)
        if v == nil then return nil end
        return tonumber(v)
    end
    -- 每条结果给 U7 指令回执: value = 入队成功原值, nil = 拒绝
    local results = {}
    local nok, nfail = 0, 0
    for _, it in ipairs(items) do
        local dkey = it.id or it.name or it.key or it.regName or it.reg_name
        local addr = dnum(it.addr or it.address or it.reg or it.register or it.offset)
        if not addr then addr = resolve_addr(dkey) end
        local slave = dnum(it.slave or it.dev or it.device or it.slaveId or it.slave_id)
        if not slave then slave = dslave end
        local rid = dkey
        if type(rid) ~= "string" or rid == "" then rid = "r" .. tostring(addr or 0) end
        if it.values and type(it.values) == "table" and addr then
            local vals = {}
            for _, v in ipairs(it.values) do
                local n = dnum(v)
                if not n then n = 0 end
                vals[#vals + 1] = n
            end
            local okw = poll.enqueue_write({ slave = slave, addr = addr, values = vals })
            if okw then nok = nok + 1 else nfail = nfail + 1 end
            results[#results + 1] = { id = rid, value = okw and #vals or nil }
        elseif addr then
            local v = dnum(it.value or it.val or it.data)
            if v then
                local okw = poll.enqueue_write({ slave = slave, addr = addr, value = v })
                if okw then nok = nok + 1 else nfail = nfail + 1 end
                results[#results + 1] = { id = rid, value = okw and v or nil }
            else
                nfail = nfail + 1
                results[#results + 1] = { id = rid, value = nil }
                log.warn("iot", "write item bad value:", tostring(dkey))
            end
        else
            nfail = nfail + 1
            results[#results + 1] = { id = rid, value = nil }
            log.warn("iot", "write item unresolvable:", tostring(dkey))
        end
    end
    log.info("iot", string.format("downlink write: queued=%d rejected=%d", nok, nfail))
    return results
end

-- SN 归属过滤: 下行 topic 末段必须等于本机 SN 或 {gwSn}-{n}
-- ⚠️ 不过滤就是拿别人的指令写本地寄存器 (同 broker 上多台网关)
-- 例外: 无 SN (allow_no_sn) / 非 /sys/thing/ 命名空间 (用户自配 topic)
local function claim_ok(topic)
    if type(topic) ~= "string" then return true end
    if topic:sub(1, 11) ~= "/sys/thing/" then return true end
    local did = cur_did()
    if not did then return true end
    local last = topic:match("([^/]+)$")
    if not last then return false end
    if last == did then return true end
    -- 子设备形态：{gwSn}-{nodeIndex}，如 11802026092600016-1
    return last:sub(1, #did + 1) == (did .. "-")
end

-- ⚠️ 必须定义在 handle_downlink 之前 (local 词法作用域, 否则引用取 nil 崩)
local function pulling()
    local st = S.pull.state
    return st == "connecting" or st == "helloing" or st == "waiting"
end

-- 平台主动重推: payload 含 configSnapshot (D1 独有字段, REPORT/WRITE 不会误判)
-- 落设备侧而非前端, 前端不在线也生效
-- 三道安全边界: ① normalize_poll 不过不落盘 ② interval/timeout 取设备当前值 ③ 前后对比日志
local function auto_apply(r)
    if not r or not r.poll then return false, "无可应用的配置" end
    local n, nerr = cfg.normalize_poll(r.poll)
    if not n then return false, "配置不合法: " .. tostring(nerr) end
    -- 平台不给轮询节奏：保留设备自己的 interval/timeout。base 取 ds_pull
    -- 而不是 ds_poll —— 平台配置落自己的槽，手动配的那份寄存器表不许被
    -- 覆盖掉(两个模式各用各的，见 lua/README.md 配置来源隔离)
    local base = cfg.load_pull()
    n.interval_ms = base.interval_ms
    n.timeout_ms = base.timeout_ms

    local before = { slave = base.slave, baud = base.baud, regs = #(base.regs or {}) }
    local ok, serr = cfg.save_pull(n)
    if not ok then return false, "落盘失败: " .. tostring(serr) end

    local pe = get_poll()
    if pe then
        -- 只有拉取档才让平台配置立即生效. 跑手动档时 ds_pull 只是存着备用,
        -- 一旦 apply_cfg/start, 手配的那套就被顶掉
        if poll_slot() == "pull" then
            -- 串口参数变了才值得重启轮询任务; 只换寄存器表时 apply_cfg 就够
            if pe.needs_restart(n) then
                if pe.is_running() then
                    pe.stop()
                    pe.apply_cfg(n)
                    pe.start("pull")
                else
                    pe.apply_cfg(n)
                end
            else
                pe.apply_cfg(n)
            end
        end
    end

    S.autosaved = true
    S.autosave_at = os.time()
    S.autosave_regs = #n.regs
    log.info("iot", string.format(
        "pullcfg 自动保存并生效: 寄存器 %d->%d, slave %d->%d, baud %d->%d, msgId=%s",
        before.regs, #n.regs, before.slave or 0, n.slave or 0,
        before.baud or 0, n.baud or 0, tostring(S.pull.msg_id)))
    return true
end

-- U6 应用回执. ⚠️ 必须声明在 recv_push/auto_apply/pull_step 之前
-- (pcall 传已声明的函数对象, 声明在后 = 捕获 nil, 平台一直重推且无报错)
local function reply_config()
    local p = S.pull
    if p.replied then return true end
    if not p.msg_id or p.msg_id == "" then return true end
    if not S.connected or not S.client then return false, "MQTT 未连接" end
    local did = cur_did()
    if not did then return false, "无 SN" end
    local topic = string.format(cfg.PLATFORM_REPLY_TOPIC, did)
    -- 用拉取结果里的话: 空快照写 "config applied" 是撒谎
    local body = string.format(
        '{"msgId":%s,"code":200,"message":%s,"status":"ok","appliedTs":%d}',
        jstr(p.msg_id), jstr(p.msg ~= "" and p.msg or "config applied"), os.time())
    log.info("iot", "config/reply " .. topic .. " " .. body)
    local ok, err = pub(topic, body, 1)
    if not ok then return false, err end
    p.replied = true
    S.replied = S.replied + 1
    return true
end
M.reply_config = reply_config

-- REPORT/WRITE/裸值都不带 configSnapshot, 不可能误判
local function recv_push(t, payload)
    local r, err = pullcfg.parse_snap(t, t.configSnapshot)
    if not r then
        S.push_err = tostring(err)
        log.warn("iot", "push parse fail: " .. tostring(err) .. " body=" .. tostring(payload))
        return false
    end
    S.push_err = nil
    -- 空快照 = 平台侧无配置 (sniff 互斥守卫), 按成功算 + 回执. 不回执平台每 1s 重推
    if r.empty then
        S.pull.state = "done"
        S.pull.src = "push"
        S.pull.seen = os.time()
        S.pull.msg = "平台未下发配置，本地嗅探自建生效"
        S.pull.result = nil
        S.pull.msg_id = r.msg_id
        S.pull.replied = false
        pcall(reply_config)
        S.push_n = S.push_n + 1
        log.info("iot", "push recv empty snapshot, 平台无配置, msgId=" .. r.msg_id)
        return true
    end
    S.pull.state = "done"
    S.pull.src = "push"
    S.pull.seen = os.time()
    S.pull.msg = "平台重新下发"
    S.pull.result = r
    S.pull.msg_id = r.msg_id
    S.pull.replied = false
    local aok, aerr = auto_apply(r)
    if aok then
        S.pull.msg = "平台配置已自动保存生效"
        pcall(reply_config)
        S.push_n = S.push_n + 1
        log.info("iot", string.format("push recv msgId=%s regs=%d skipped=%d (已自动保存)",
            r.msg_id, #(r.poll.regs or {}), #(r.skipped or {})))
    else
        S.push_err = "自动保存失败: " .. tostring(aerr)
        S.push_n = S.push_n + 1
        log.warn("iot", string.format("push recv msgId=%s 但自动保存失败: %s", r.msg_id, tostring(aerr)))
    end
    return aok
end

local function handle_downlink(topic, payload)
    if not claim_ok(topic) then
        log.info("iot", "downlink dropped, not ours: " .. tostring(topic))
        return
    end
    -- 配置下发与业务指令共用 /sys/thing/gw/config/get/{sn}, 不能一见就当配置
    -- (REPORT/WRITE 会被吞). 只有 pull 状态机 waiting 时当配置包
    if type(topic) == "string" and topic:find("/gw/config/get/", 1, true) then
        if S.pull.state == "waiting" then
            log.info("iot", string.format("pullcfg recv topic=%s len=%d body=%s",
                topic, #tostring(payload), tostring(payload)))
            S.pull_payload = payload
            return
        end
        log.info("iot", "downlink on get topic, pull idle -> parse as cmd")
    end
    if not json then return end
    local ok, t = pcall(json.decode, payload)
    if not ok or type(t) ~= "table" then return end
    -- 平台手动重推: 含 configSnapshot = 新快照, 走 recv_push
    if type(t.configSnapshot) == "table" then
        if pulling() then
            -- 握手中到达: 寄存等 waiting 时消费, 直接当 push 会掐握手
            S.pull_payload = payload
            log.info("iot", string.format("push during handshake(%s), parked len=%d",
                S.pull.state, #tostring(payload)))
            return
        end
        recv_push(t, payload)
        return
    end
    local cmd = t.cmd and t.cmd:upper() or nil
    if cmd == "REPORT" or cmd == "READALL" then
        S.dirty = true
        return
    end
    -- 4 种下行分支: WRITE/items 数组/单条. 每个都要回执, 漏一个就停在"已下发未执行"
    if cmd == "WRITE" and type(t.items) == "table" then
        func_reply(downlink_write(t.items))
        return
    end
    if t[1] and type(t[1]) == "table" then
        func_reply(downlink_write(t))
        return
    end
    if t.items and type(t.items) == "table" then
        func_reply(downlink_write(t.items))
        return
    end
    if t.value or t.values or t.val or t.data then
        func_reply(downlink_write({ t }))
        return
    end
    log.warn("iot", "downlink unrecognized, no action: " .. tostring(payload))
end

-- 拉取状态机: W:PULLCFG 只置状态, 握手跑 task_main 协程 (那里才能 sys.wait)
local function pull_active() return pulling() end

-- 拉取是否正在进行. 导出给 W:PULLCFG 判重 (pull_start 复用旧的就分不出新一轮)
function M.pulling() return pulling() end

-- ⚠️ destroy+kick: build_subs 挂在 conack 上, 不重连已连的 client 不会重读清单,
-- 切档后还订旧清单会像"手动配置没生效"
function M.set_manual(on)
    on = on and true or false
    local c = cfg.mqtt_load()
    -- 档位没变就不必断开重连 (白丢心跳, 还可能撞上正在进行的拉取握手)
    if not not c.manual_on == on then return false end
    c.manual_on = on
    if on then
        -- 手动<-自动: 不用动 broker. host/port 是两档共用
        local ok, err = cfg.mqtt_save(c)
        if not ok then return false, err end
    else
        -- 自动<-手动: 平台地址必须归位. auto.pass 要带过去 (用户设的平台凭证)
        local d = cfg.mqtt_default
        local ok, err = cfg.mqtt_save({
            host = d.host, port = d.port, ssl = d.ssl,
            manual_on = false,
            auto = { pass = c.auto and c.auto.pass or "" },
        })
        if not ok then return false, err end
    end
    destroy_client()
    M.kick()
    log.info("iot", "mqtt manual_on ->", tostring(on))
    return true
end

function M.pull_start()
    -- 已在拉取中直接当成功 (ctrl.switch_mode 不该因重复请求判失败)
    if pull_active() then return true end
    if not get_topic() then return false, "无 SN" end
    local c = cfg.mqtt_load()
    if not c.host or c.host == "" then return false, "请先配置 MQTT 服务器地址" end
    if not c.port or c.port < 1 or c.port > 65535 then return false, "请先配置 MQTT 端口" end
    S.pull = {
        state = "connecting", msg = "", result = nil,
        deadline = os.time() + math.floor(cfg.PULL_CONNECT_MS / 1000),
        msg_id = nil, replied = false,
        -- 一轮拉取结束 hello_try 跟着作废, 不会把上轮失败计数带给下轮
        hello_try = 0,
    }
    -- 未连上时打断退避等待, 让 task_main 立刻重连
    if not S.connected then M.kick() end
    return true
end

function M.pull_status()
    local p = S.pull
    local r = { state = p.state, msg = p.msg }
    if p.result then
        r.poll = p.result.poll
        r.skipped = p.result.skipped
        r.renamed = p.result.renamed
        -- 只带 pub/sub 给前端回显 (3 条 gw 订阅是设备端固定常量, 前端没输入框)
        local prof = cfg.mqtt_profile(device_id())
        r.mqtt = {
            pub = prof and prof.pub, sub = prof and prof.sub,
        }
    end
    -- msg_id/replied: 前端提示"已回执"还是"平台还在重推"
    r.msg_id = p.msg_id
    r.replied = p.replied
    -- src/seen/autosaved: 前端据此换提示语 + 显示来源和落地时间
    r.src = p.src or "pull"
    r.seen = p.seen
    r.autosaved = S.autosaved
    r.autosave_at = S.autosave_at
    r.autosave_regs = S.autosave_regs
    r.push_n = S.push_n
    r.push_err = S.push_err
    return r
end

-- U1 hello. 两调用方: pull_step 握手 + task_main pollpull 30min 周期重发
local function send_hello()
    if not S.client or not S.connected then return false, "未连接" end
    local did = device_id()
    if not did or did == "" then return false, "无 SN" end
    local topic = string.format(cfg.PLATFORM_HELLO_TOPIC, did)
    -- topicFormat 固定 v3: 消除"平台硬编码旧版 / 固件烧新版"漂移 (指令全丢且无报错)
    -- onboardingMode 报告 sniff/platform/manual, 平台据此决定要不要推 ConfigSnapshot
    local m = get_mode()
    local onboard = m == "sniff" and "sniff" or m == "pollpull" and "platform" or "manual"
    -- deviceId 取 IMEI, 取不到 "unknown" (空串被平台校验为缺字段, 会拒 hello)
    local dv = imei()
    if dv == "" then dv = "unknown" end
    local body = string.format(
        '{"vendor":%s,"model":%s,"fwVersion":%s,"deviceId":%s,"topicFormat":"v3","onboardingMode":%s}',
        jstr(cfg.PLATFORM_VENDOR), jstr(cfg.PLATFORM_MODEL), jstr(_G.VERSION or "0.0.0"),
        jstr(dv), jstr(onboard))
    log.info("iot", string.format("pullcfg hello topic=%s sn=%s imei=%s mode=%s body=%s",
        topic, did, imei(), onboard, body))
    -- ⚠️ 失败不能记 hello_at: 那是"本连接最后一次成功发送"时间,
    -- 记了失败这次, 30min 重发会从假起点起算
    local ok, err = pub(topic, body, 1)
    if not ok then return false, err end
    S.hello_at = os.time()
    return true, onboard
end

-- 手动档用: ctrl 进 poll 档时调, 不进拉取状态机 (不等 configSnapshot)
-- 失败不回滚切模式, task_main "连接后补发"分支会负责
function M.hello()
    if not S.client or not S.connected then return false, "未连接" end
    return send_hello()
end

local function pull_finish(state, msg, result)
    S.pull.state = state
    S.pull.msg = msg
    S.pull.result = result
    if state == "done" then
        S.push_err = nil
    end
    log.info("iot", "pullcfg", state, msg)
end

local function pull_step()
    local p = S.pull
    if p.state == "connecting" then
        -- 实际建连由 task_main 常规分支做, 这里只等 (避免两处建连建出 2 个 client)
        if S.connected then
            -- ⚠️ deadline 必须清零: 不清的话 helloing 分支"退避中就等着"
            -- 会把第一次 hello 也当成退避期跳过
            p.deadline = 0
            p.hello_try = 0
            p.state = "helloing"
        elseif os.time() >= p.deadline then
            local why = S.reject_reason or S.last_err or "超时"
            pull_finish("fail", "MQTT 连接失败: " .. tostring(why))
        end
    elseif p.state == "helloing" then
        -- ⚠️ 不能假定 S.client 还在: refresh_subs 发现模式变了就 destroy_client
        -- 抽走, 下一轮 state 已是 helloing, 索引 nil 直接崩. 退回 connecting 重等
        if not S.client or not S.connected then
            p.state = "connecting"
            p.deadline = os.time() + math.floor(cfg.PULL_CONNECT_MS / 1000)
            return
        end
        -- 退避中就等着, 不重发
        if p.deadline > os.time() then return end
        local ok, onboard, err = send_hello()
        if not ok then
            -- 1s/3s/9s 退避重发, 不立即判死 (发送失败多是连接刚被抽走, 下一轮就好)
            p.hello_try = (p.hello_try or 0) + 1
            local bo = cfg.HELLO_BACKOFF_S[p.hello_try]
            if not bo then
                return pull_finish("fail", "hello 发送失败: " .. tostring(err))
            end
            p.deadline = os.time() + bo
            log.warn("iot", string.format("hello 发送失败(%d/3), %ds 后重发: %s",
                p.hello_try, bo, tostring(err)))
            return
        end
        p.hello_try = 0
        -- sniff 平台明确不会推配置快照, 干等 PULL_TIMEOUT_MS 只显示假故障
        -- 这里也不回 U6: 没有 D1 没有 msgId 可核销
        if onboard == "sniff" then
            return pull_finish("done", "sniff 模式平台不下发配置，寄存器表用本地嗅探结果")
        end
        p.state = "waiting"
        p.deadline = os.time() + math.floor(cfg.PULL_TIMEOUT_MS / 1000)
    elseif p.state == "waiting" then
        if S.pull_payload then
            local payload = S.pull_payload
            S.pull_payload = nil
            local r, err = pullcfg.parse(payload)
            if not r then
                log.warn("iot", "pull parse fail: " .. tostring(err) .. " body=" .. tostring(payload))
                return pull_finish("fail", tostring(err))
            end
            p.src = "pull"
            p.seen = os.time()
            p.msg_id = r.msg_id
            p.replied = false
            -- 空快照按成功收尾: 不回执平台每 1s 重推
            if r.empty then
                p.result = nil
                p.msg = "平台未下发配置，本地嗅探自建生效"
                pcall(reply_config)
                return pull_finish("done", p.msg)
            end
            -- 拉取成功即自动保存 (落盘失败报 fail, 平台会继续重推)
            local aok, aerr = auto_apply(r)
            if not aok then
                return pull_finish("fail", "自动保存失败: " .. tostring(aerr))
            end
            pcall(reply_config)
            return pull_finish("done", "已自动保存生效" .. (#r.skipped > 0 and ("，忽略 " .. #r.skipped .. " 条") or ""), r)
        end
        if os.time() >= p.deadline then pull_finish("fail", "平台未下发配置(超时)") end
    end
end

-- ⚠️ 必须放在循环里, 不只在 conack 算: 切模式时设备已连, build_subs 不会重读
-- ctrl 先切凭证再 poll.start(), set_manual 触发重连那一刻 get_mode() 还是旧值
local function subs_same(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function refresh_subs()
    if not S.client or not S.connected then return end
    local want = build_subs()
    if subs_same(want, S.subs) then return end
    -- 先记账再断开: 让 on_mqtt conack 和这里看到同一份诉求 (避免来回重连)
    S.subs = want
    destroy_client()
    M.kick()
    log.info("iot", "subs changed by mode, reconnect: [" .. table.concat(want, " ") .. "]")
end

local function task_main()
    S.want_run = true
    while S.want_run do
        -- 拉取状态机要在未连接时也能跑 (connecting 态就是等连接), 放分支外
        if pull_active() then pcall(pull_step) end
        if not S.connected then
            if net_ready() then
                local ok, err = try_connect()
                if not ok then
                    if err == "no sn" then
                        log.warn("iot", "no sn, skip")
                        if sys then sys.wait(10000) end
                    else
                        local is_oom = type(err) == "string" and err:lower():find("memory") ~= nil
                        local wait_s = is_oom and 30 or S.backoff
                        if is_oom then
                            -- ⚠️ mon.trim_reqs() 不能省: lastReqs 是 mon 局部表,
                            -- collector.trim_cache() 碰不到它, 少了这步清了缓存照样 OOM
                            collector.trim_cache()
                            mon.trim_reqs()
                            collectgarbage("collect")
                            local h1, h2 = heap_info()
                            log.warn("iot", "oom, trim+gc done, heap total=" .. tostring(h1) .. " used=" .. tostring(h2))
                        else
                            S.backoff = math.min(S.backoff * 2, 60)
                        end
                        S.last_err = err
                        wait_kickable(wait_s * 1000)
                    end
                end
            else
                wait_kickable(10000)
            end
        else
            -- cpu_percent 忙碌占比: 每轮量干活耗时(不含 sys.wait), 攒到 U3 算占比
            -- os.clock() 当秒级单调时钟用, 不是 CPU 时间
            local t0 = os.clock()
            if S.recv_pending then
                local rp = S.recv_pending
                S.recv_pending = nil
                pcall(handle_downlink, rp.topic, rp.payload)
            end
            refresh_subs()
            local c = cfg.mqtt_load()
            local due = false
            if c.interval_s > 0 then
                due = (os.time() - S.last_pub) >= c.interval_s
            else
                due = S.dirty
            end
            if S.dirty then due = true end
            if due then publish() end
            if (os.time() - (S.res_at or 0)) >= c.interval_s then send_gw_res() end
            -- ⚠️ span 与 busy 必须同一轮清零, 否则占比会越算越小
            S.busy_s = (S.busy_s or 0) + (os.clock() - t0)
            S.span_s = (S.span_s or 0) + (os.clock() - t0) + 1.0
            -- U2 两帧按自己指纹发, 不做定时兜底:
            --   元数据(无 nodes) 按内容变化发; 平台只更新属性不重建模型
            --   拓扑(带 nodes) 签名没变就不重建 (实测 60s 兜底会和平台回推
            --   形成"我们发 → 平台推 → 我们再发"闭环, 难查)
            local msig = meta_sig()
            if msig and msig ~= S.meta_sig then
                local ok, e = send_meta()
                if ok then
                    S.meta_sig = msig
                    log.info("iot", "gw meta posted: " .. msig)
                else
                    log.info("iot", "gw meta skip: " .. tostring(e))
                end
            end
            -- detect 完前不发拓扑: serial 还用上一轮默认值, 按错波特率建模型白推一次配置
            local sig = nil
            if not mon.status().detecting then sig = topo_sig() end
            if sig and sig ~= S.topo_sig then
                local ok, e = send_topo()
                if ok then
                    S.topo_sig = sig
                    log.info("iot", "topology posted: " .. sig)
                else
                    log.info("iot", "topology skip: " .. tostring(e))
                end
            end
            if sys then sys.wait(1000) end
            -- hello 时机: ① 连接后补发 ② pollpull 档 30min 周期重发
            -- ① 所有非 idle 都要 (平台靠 hello + 拓扑/数据帧 auto-provision 补建档案)
            -- ② 只 pollpull 重发 (sniff 发完就完成, manual 不等 configSnapshot)
            if S.hello_at == 0 and get_mode() ~= "idle" and not pulling() then
                log.info("iot", "hello on connect, mode=" .. get_mode())
                pcall(send_hello)
            elseif S.hello_at and S.hello_at > 0 and get_mode() == "pollpull"
                and not pulling()
                and (os.time() - S.hello_at) >= cfg.HELLO_RE_S then
                log.info("iot", "hello re-send (30min), mode=pollpull")
                pcall(send_hello)
            end
        end
    end
end

function M.init()
    collector.on_update(function()
        S.dirty = true
    end)
    return true
end

function M.start()
    if S.want_run then
        log.warn("iot", "already started")
        return false
    end
    reset_state()
    S.want_run = true
    if sys then sys.taskInit(task_main) end
    log.info("iot", "started")
    return true
end

function M.is_running() return S.want_run end

function M.report_now()
    return publish()
end

function M.kick()
    destroy_client()
    S.backoff = 1
    S.kick_flag = true
end

function M.apply_cfg(c)
    local ok, err = cfg.mqtt_save(c)
    if not ok then return false, err end
    M.kick()
    return true
end

function M.status()
    local c = cfg.mqtt_load()
    -- 未建连时按当前档次兜底算一份 (与 try_connect 同源, 建连前 status 不空)
    local prof = cfg.mqtt_profile(device_id())
    return {
        want_run = S.want_run,
        connected = S.connected,
        subscribed = S.subscribed,
        device_id = S.device_id,
        client_id = S.client_id or (c.client_id ~= "" and c.client_id or default_client_id(device_id())),
        user = S.user or ((prof and prof.user ~= "" and prof.user) or device_id()),
        pub = S.pub or (prof and prof.pub),
        sub = S.sub or (prof and prof.sub),
        keep_session = c.keep_session,
        manual_on = c.manual_on,
        host = c.host,
        port = c.port,
        interval_s = c.interval_s,
        qos = c.qos,
        published = S.published,
        failed = S.failed,
        replied = S.replied,
        subs = S.subs,
        backoff = S.backoff,
        dirty = S.dirty,
        last_pub = S.last_pub,
        last_err = S.last_err,
        reject_reason = S.reject_reason,
        -- push_n/push_err/push_seen: 平台主动改过的记录 (R:STAT 5s 轮询)
        -- autosaved: 前端知道改动已落盘, 不再提示去保存
        push_n = S.push_n,
        push_seen = S.pull.seen,
        push_err = S.push_err,
        autosaved = S.autosaved,
        autosave_at = S.autosave_at,
        autosave_regs = S.autosave_regs,
        sn = _G.get_device_sn and tostring(_G.get_device_sn()) or nil,
        heap = (function() local a, b = heap_info(); return { total = a, used = b } end)(),
    }
end

function M.net_state()
    local st = {}
    if not mobile then return st end
    local function g(k)
        local v = mobile[k]
        if type(v) == "function" then
            local ok, r = pcall(v)
            return ok and r or nil
        end
        return v
    end
    st.csq = g("csq")
    st.rsrp = g("rsrp")
    st.rsrq = g("rsrq")
    st.pci = g("pci")
    st.reg = g("status")
    st.imei = g("imei")
    st.iccid = g("iccid")
    if socket then
        local ok, r = pcall(socket.isReady)
        st.socket_ready = ok and r or nil
    end
    return st
end

reset_state()

return M
