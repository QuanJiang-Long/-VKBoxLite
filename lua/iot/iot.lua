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

local M = {}

local S = {}

local function reset_state()
    S = {
        want_run = false, connected = false, subscribed = false,
        client = nil, dirty = false, backoff = 1,
        published = 0, failed = 0, kick_flag = false,
        recv_pending = nil, pub = nil, sub = nil, device_id = nil,
        last_pub = 0,
    }
end

local function device_id()
    local ok, snc = pcall(require, "sn/sn")
    if ok and snc and snc.state() == "ready" then
        return _G.get_device_sn and _G.get_device_sn()
    end
    return nil
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
    if payload == "[]" and not force then return false end
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
        S.subscribed = true
        S.backoff = 1
        if S.sub then
            pcall(function() cli:subscribe(S.sub, mqttcfg.load().qos) end)
        end
        log.info("iot", "conack ok, subscribed")
    elseif event == "recv" then
        S.recv_pending = { topic = data, payload = payload }
    elseif event == "disconnect" or event == "error" then
        S.connected = false
        S.subscribed = false
        log.warn("iot", event, tostring(data))
    end
end

local function destroy_client()
    if S.client then
        pcall(function() S.client:disconnect() end)
        pcall(function() S.client:close() end)
        S.client = nil
    end
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
    local c = mqttcfg.load()
    local did = device_id()
    if not did or did == "" then
        if not c.allow_no_sn then return false, "no sn" end
        did = "unknown"
    end
    S.device_id = did
    local pub, sub, terr = mqttcfg.resolve_topics(did)
    if not pub then return false, terr end
    S.pub, S.sub = pub, sub
    local cid = c.client_id ~= "" and c.client_id or did
    local cli, err = mqtt.create(nil, c.host, c.port, c.ssl)
    if not cli then return false, "create fail" end
    S.client = cli
    pcall(function() cli:auth(cid, c.user, c.pass, not c.keep_session) end)
    pcall(function() cli:keepalive(60) end)
    pcall(function() cli:autoreconn(false) end)
    cli:on(on_mqtt)
    local ok = cli:connect()
    if not ok then
        destroy_client()
        return false, "connect fail"
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
        for _, r in ipairs(regs) do
            if r.name == k or r.alias == k then return r.addr end
        end
        local lk = k:lower()
        for _, r in ipairs(regs) do
            if r.name:lower() == lk or (r.alias and r.alias:lower() == lk) then return r.addr end
        end
        return nil
    end
    local nok, nfail = 0, 0
    for _, it in ipairs(items) do
        local dkey = it.id or it.name or it.key or it.regName or it.reg_name
        local addr = tonumber(it.addr or it.address or it.reg or it.register or it.offset)
        if not addr then addr = resolve_addr(dkey) end
        local slave = tonumber(it.slave or it.dev or it.device or it.slaveId or it.slave_id)
        if not slave and dkey then slave = tonumber(dkey) end
        if not slave then
            local okp, pc = pcall(cfgstore.load_poll)
            slave = okp and pc and pc.slave or cfg.SLAVE_ADDR
        end
        if it.values and type(it.values) == "table" and addr then
            local vals = {}
            for _, v in ipairs(it.values) do vals[#vals + 1] = tonumber(v) end
            local okw = poll.enqueue_write({ slave = slave, addr = addr, values = vals })
            if okw then nok = nok + 1 else nfail = nfail + 1 end
        elseif addr and (it.value or it.val or it.data) then
            local v = tonumber(it.value or it.val or it.data)
            local okw = poll.enqueue_write({ slave = slave, addr = addr, value = v })
            if okw then nok = nok + 1 else nfail = nfail + 1 end
        else
            nfail = nfail + 1
            log.warn("iot", "write item unresolvable:", tostring(dkey))
        end
    end
    return nok, nfail
end

function M.handle_downlink(topic, payload)
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
                        if not is_oom then
                            S.backoff = math.min(S.backoff * 2, 60)
                        else
                            collector.trim_cache()
                        end
                        wait_kickable(wait_s * 1000)
                    end
                end
            else
                if sys then sys.wait(10000) end
            end
        else
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
        connected = S.connected,
        device_id = S.device_id,
        client_id = c.client_id,
        pub = S.pub,
        sub = S.sub,
        interval_s = c.interval_s,
        qos = c.qos,
        published = S.published,
        failed = S.failed,
        backoff = S.backoff,
        dirty = S.dirty,
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
