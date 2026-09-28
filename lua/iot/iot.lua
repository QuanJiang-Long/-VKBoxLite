local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local sys = corelib.get("sys")
local json = corelib.try("json")
local mqtt = corelib.try("mqtt")
local rtos = corelib.try("rtos")
local mobile = corelib.try("mobile")
local socket = corelib.try("socket")

local mqttcfg = require "iot/mqttcfg"
local collector = require "data/collector"
local cfgstore = require "cfg"
local pullcfg = require "iot/pullcfg"

local M = {}

local S = {}

local function reset_state()
    S = {
        want_run = false, connected = false, subscribed = false,
        client = nil, dirty = false, backoff = 1,
        published = 0, failed = 0, kick_flag = false,
        recv_pending = nil, pub = nil, sub = nil, device_id = nil,
        last_pub = 0, last_err = nil, client_id = nil,
        pull = { state = "idle", msg = "", result = nil, deadline = 0 },
        pull_payload = nil,
    }
end

local function device_id()
    local ok, snc = pcall(require, "sn/sn")
    if ok and snc and snc.state() == "ready" then
        return _G.get_device_sn and _G.get_device_sn()
    end
    return nil
end

local function get_topic()
    local did = device_id()
    if not did or did == "" then return nil end
    return string.format(cfg.PLATFORM_GET_TOPIC, did)
end

local function imei()
    if not mobile then return "" end
    local f = mobile.imei
    if type(f) ~= "function" then return "" end
    local ok, v = pcall(f)
    return ok and tostring(v) or ""
end

local function alias_map()
    local ok, c = pcall(cfgstore.load_poll)
    if not ok or not c or not c.regs then return {} end
    local m = {}
    for _, r in ipairs(c.regs) do m[r.name] = r.alias or r.name end
    return m
end

local function pad(v, n)
    local s = tostring(v)
    while #s < n do s = "0" .. s end
    return s
end

local function int_str(v)
    v = math.floor(v)
    if v < 1e9 then return tostring(v) end
    local high = math.floor(v / 1000000000)
    local low = v - high * 1000000000
    return tostring(high) .. pad(low, 9)
end

local function ms_of(ts)
    if type(ts) ~= "number" or ts ~= ts or ts < 0 then return "0" end
    local sec = math.floor(ts)
    local ksec = math.floor(sec / 1000)
    local rsec = sec - ksec * 1000
    local tail = rsec * 1000
    if ksec <= 0 then return tostring(tail) end
    return tostring(ksec) .. pad(tail, 6)
end

local function jstr(s)
    s = tostring(s)
    return '"' .. (s:gsub('[%c"\\]', function(c)
        local b = c:byte()
        if c == '"' then return '\\"'
        elseif c == "\\" then return "\\\\"
        else return string.format("\\u%04x", b) end
    end)) .. '"'
end

local function jnum(v)
    if type(v) ~= "number" then return nil end
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    if v == math.floor(v) and math.abs(v) < 1e15 then return int_str(v) end
    return tostring(v)
end

local function build_payload()
    local amap = alias_map()
    local parts = {}
    for k, d in pairs(collector.get_all_latest()) do
        local vs = jnum(d.value)
        if vs then
            parts[#parts + 1] = string.format('{"id":%s,"name":%s,"value":%s,"ts":%s}',
                jstr(k), jstr(amap[k] or k), vs, ms_of(d.ts))
        end
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function publish(force)
    if not S.client or not S.connected then return false end
    local payload = build_payload()
    if payload == "[]" then return false end
    local ok, err = pcall(function()
        S.client:publish(S.pub, payload, mqttcfg.load().qos)
    end)
    if ok then
        S.published = S.published + 1
        S.dirty = false
        S.last_pub = os.time()
        return true
    end
    S.failed = S.failed + 1
    log.warn("iot", "publish fail:", tostring(err))
    return false
end
M.publish = publish

local function on_mqtt(cli, event, data, payload)
    if event == "conack" then
        S.connected = true
        S.backoff = 1
        local subs = {}
        if S.sub then subs[#subs + 1] = S.sub end
        local gtopic = get_topic()
        if gtopic then subs[#subs + 1] = gtopic end
        S.subscribed = false
        for _, t in ipairs(subs) do
            local sok, serr = pcall(function() cli:subscribe(t, mqttcfg.load().qos) end)
            -- 订阅成功才算已订阅, 否则 status 失真
            if not sok then log.warn("iot", "subscribe fail:", t, tostring(serr)) end
            S.subscribed = S.subscribed or sok
        end
        log.info("iot", "conack ok, subscribed=" .. tostring(S.subscribed))
    elseif event == "recv" then
        S.recv_pending = { topic = data, payload = payload }
    elseif event == "disconnect" or event == "error" then
        S.connected = false
        S.subscribed = false
        log.warn("iot", event, tostring(data))
    end
end

-- Lua 堆信息: 返回 total, used; 取不到返回 nil, nil
-- Air780EP 堆约 300KB, mqtt.create 需要连续块, 建连前打印便于定位 OOM
local function heap_info()
    if not rtos or type(rtos.meminfo) ~= "function" then return nil, nil end
    local ok, a, b = pcall(rtos.meminfo, "sys")
    if not ok or type(a) ~= "number" then return nil, nil end
    return a, b
end

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

local function net_ready()
    if not mobile then return true end
    local csq = mobile.csq
    if type(csq) == "function" then
        local ok, v = pcall(csq)
        csq = ok and v or nil
    end
    if type(csq) == "number" and csq == 0 then return false end
    return true
end

local function try_connect()
    if not mqtt then return false, "mqtt 库不可用(需 sysplus/mqtt 组件)" end
    if type(mqtt.create) ~= "function" then return false, "mqtt.create 不可用" end
    local c = mqttcfg.load()
    local did = device_id()
    if not did or did == "" then
        if not c.allow_no_sn then return false, "no sn" end
        did = "unknown"
    end
    S.device_id = did
    -- 无 SN 时把 "unknown" 视作无 id: topic 含 {id} 会被拒, 不会把字面
    -- unknown 拼进 topic(与原工程一致)
    local pub, sub, terr = mqttcfg.resolve_topics(did == "unknown" and nil or did)
    if not pub then return false, terr end
    S.pub, S.sub = pub, sub
    local cid = c.client_id ~= "" and c.client_id or did
    S.client_id = cid
    -- Air780EP Lua 堆约 300KB, mqtt.create 需要连续块; 建连前先 GC + 记录堆
    collectgarbage("collect")
    local h1, h2 = heap_info()
    log.info("iot", "create mqtt", c.host, c.port, "heap total=" .. tostring(h1) .. " used=" .. tostring(h2))
    local okc, cli = pcall(mqtt.create, nil, c.host, c.port, c.ssl)
    if not okc or not cli then return false, "mqtt.create 失败: " .. tostring(cli) end
    S.client = cli
    pcall(function() cli:auth(cid, c.user, c.pass, not c.keep_session) end)
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
    local waited = 0
    while waited < 15000 do
        if S.connected then return true end
        if sys then sys.wait(100) end
        waited = waited + 100
    end
    destroy_client()
    return false, "conack timeout"
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
    if not ok or not poll then return 0, 0 end
    local okc, c = pcall(cfgstore.load_poll)
    local regs = okc and c and c.regs or {}
    local function resolve_addr(k)
        if not k then return nil end
        if type(k) ~= "string" then
            -- 纯数字直接当地址, 避免对 number 调 :lower()
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
    -- 安全取数: 下行 JSON 字段可能缺失或类型不对, 统一走 tonumber 兜底
    local function dnum(v)
        if v == nil then return nil end
        local n = tonumber(v)
        return n
    end
    local nok, nfail = 0, 0
    for _, it in ipairs(items) do
        local dkey = it.id or it.name or it.key or it.regName or it.reg_name
        local addr = dnum(it.addr or it.address or it.reg or it.register or it.offset)
        if not addr then addr = resolve_addr(dkey) end
        local slave = dnum(it.slave or it.dev or it.device or it.slaveId or it.slave_id)
        if not slave then
            local okp, pc = pcall(cfgstore.load_poll)
            slave = okp and pc and pc.slave or cfg.SLAVE_ADDR
        end
        if it.values and type(it.values) == "table" and addr then
            local vals = {}
            for _, v in ipairs(it.values) do
                local n = dnum(v)
                if not n then n = 0 end
                vals[#vals + 1] = n
            end
            local okw = poll.enqueue_write({ slave = slave, addr = addr, values = vals })
            if okw then nok = nok + 1 else nfail = nfail + 1 end
        elseif addr then
            local v = dnum(it.value or it.val or it.data)
            if v then
                local okw = poll.enqueue_write({ slave = slave, addr = addr, value = v })
                if okw then nok = nok + 1 else nfail = nfail + 1 end
            else
                nfail = nfail + 1
                log.warn("iot", "write item bad value:", tostring(dkey))
            end
        else
            nfail = nfail + 1
            log.warn("iot", "write item unresolvable:", tostring(dkey))
        end
    end
    log.info("iot", "downlink write: ok=" .. nok .. " fail=" .. nfail)
    return nok, nfail
end

function M.handle_downlink(topic, payload)
    -- 平台配置下发: 与指令下行共用 recv 通道, 按 topic 前缀区分
    if type(topic) == "string" and topic:find("/gw/config/get/", 1, true) then
        if S.pull.state == "waiting" then S.pull_payload = payload end
        return
    end
    if not json then return end
    local ok, t = pcall(json.decode, payload)
    if not ok or type(t) ~= "table" then return end
    local cmd = t.cmd and t.cmd:upper() or nil
    if cmd == "REPORT" or cmd == "READALL" then
        S.dirty = true
        return
    end
    if cmd == "WRITE" and type(t.items) == "table" then
        downlink_write(t.items)
        return
    end
    if t[1] and type(t[1]) == "table" then
        downlink_write(t)
        return
    end
    if t.items and type(t.items) == "table" then
        downlink_write(t.items)
        return
    end
    if t.value or t.values or t.val or t.data then
        downlink_write({ t })
    end
end

-- 平台配置拉取状态机。
-- W:PULLCFG 只置状态并立即应答; 握手跑在 task_main 协程里(那里才能 sys.wait)。
function M.pull_start()
    if S.pull.state == "helloing" or S.pull.state == "waiting" then
        return false, "正在拉取中"
    end
    if not S.client or not S.connected then return false, "MQTT 未连接" end
    if not get_topic() then return false, "无 SN" end
    S.pull = { state = "helloing", msg = "", result = nil, deadline = 0 }
    return true
end

function M.pull_status()
    local p = S.pull
    local r = { state = p.state, msg = p.msg }
    if p.result then
        r.poll = p.result.poll
        r.skipped = p.result.skipped
        local pub, sub = pullcfg.topics(device_id())
        r.mqtt = { pub = pub, sub = sub }
    end
    return r
end

local function pull_finish(state, msg, result)
    S.pull.state = state
    S.pull.msg = msg
    S.pull.result = result
    log.info("iot", "pullcfg", state, msg)
end

local function pull_step()
    local p = S.pull
    if p.state == "helloing" then
        local body = string.format('{"vendor":%s,"model":%s,"fwVersion":%s,"deviceId":%s}',
            jstr(cfg.PLATFORM_VENDOR), jstr(cfg.PLATFORM_MODEL), jstr(_G.VERSION or "0.0.0"), jstr(imei()))
        local ok, err = pcall(function()
            S.client:publish(string.format(cfg.PLATFORM_HELLO_TOPIC, device_id()), body, 1)
        end)
        if not ok then return pull_finish("fail", "hello 发送失败: " .. tostring(err)) end
        p.state = "waiting"
        p.deadline = os.time() + math.floor(cfg.PULL_TIMEOUT_MS / 1000)
    elseif p.state == "waiting" then
        if S.pull_payload then
            local payload = S.pull_payload
            S.pull_payload = nil
            local r, err = pullcfg.parse(payload)
            if not r then return pull_finish("fail", tostring(err)) end
            return pull_finish("done", #r.skipped > 0 and ("已忽略 " .. #r.skipped .. " 条") or "", r)
        end
        if os.time() >= p.deadline then pull_finish("fail", "平台未下发配置(超时)") end
    end
end

local function task_main()
    S.want_run = true
    while S.want_run do
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
                            -- 堆不足: 清帧缓存 + 强制 GC, 固定等 30s 再试
                            collector.trim_cache()
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
            if S.pull.state == "helloing" or S.pull.state == "waiting" then
                pcall(pull_step)
            end
            if S.recv_pending then
                local rp = S.recv_pending
                S.recv_pending = nil
                pcall(M.handle_downlink, rp.topic, rp.payload)
            end
            local c = mqttcfg.load()
            local due = false
            if c.interval_s > 0 then
                due = (os.time() - S.last_pub) >= c.interval_s
            else
                due = S.dirty
            end
            if S.dirty then due = true end
            if due then publish(false) end
            if sys then sys.wait(1000) end
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

function M.stop()
    S.want_run = false
    destroy_client()
end

function M.is_running() return S.want_run end

function M.report_now()
    return publish(true)
end

function M.kick()
    destroy_client()
    S.backoff = 1
    S.kick_flag = true
end

function M.apply_cfg(c)
    local ok, err = mqttcfg.save(c)
    if not ok then return false, err end
    M.kick()
    return true
end

function M.status()
    local c = mqttcfg.load()
    return {
        want_run = S.want_run,
        connected = S.connected,
        subscribed = S.subscribed,
        device_id = S.device_id,
        client_id = S.client_id or c.client_id,
        keep_session = c.keep_session,
        pub = S.pub,
        sub = S.sub,
        interval_s = c.interval_s,
        qos = c.qos,
        published = S.published,
        failed = S.failed,
        backoff = S.backoff,
        dirty = S.dirty,
        last_pub = S.last_pub,
        last_err = S.last_err,
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
