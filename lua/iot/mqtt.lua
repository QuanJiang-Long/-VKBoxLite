local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local fskv = corelib.try("fskv")
local json = corelib.try("json")

local M = {}

local K_CFG = "mqtt_cfg"

M.default = {
    host = "test.mosquitto.org",
    port = 1883,
    user = "",
    pass = "",
    ssl = false,
    client_id = "",
    pub_topic = "vkbox/{id}/up",
    sub_topic = "vkbox/{id}/down",
    interval_s = cfg.MQTT_INTERVAL_S,
    qos = cfg.MQTT_QOS,
    allow_no_sn = cfg.MQTT_ALLOW_NO_SN,
    keep_session = false,
}

local function num(v, d)
    if v == nil then return d end
    return tonumber(v) or d
end

function M.normalize(c)
    c = c or {}
    local d = M.default
    local host = c.host
    if type(host) ~= "string" then host = "" end
    host = host:gsub("^%s*(.-)%s*$", "%1")
    if host == "" or #host > 128 then return nil, "bad host" end
    local port = math.floor(num(c.port, d.port))
    if port < 1 or port > 65535 then return nil, "bad port" end
    local user, pass = "", ""
    if type(c.user) == "string" then user = c.user:sub(1, 64) end
    if type(c.pass) == "string" then pass = c.pass:sub(1, 64) end
    local cid = ""
    if type(c.client_id) == "string" then cid = c.client_id:gsub("^%s*(.-)%s*$", "%1"):sub(1, 128) end
    local pub = c.pub_topic
    if type(pub) ~= "string" or pub == "" or #pub > 128 then return nil, "bad pub_topic" end
    local sub = c.sub_topic
    if type(sub) ~= "string" or sub == "" or #sub > 128 then return nil, "bad sub_topic" end
    local interval = math.floor(num(c.interval_s, d.interval_s))
    if interval < 0 or interval > 86400 then return nil, "bad interval_s" end
    local qos = math.floor(num(c.qos, d.qos))
    if qos < 0 or qos > 2 then return nil, "bad qos" end
    return {
        host = host, port = port, user = user, pass = pass,
        ssl = c.ssl and true or false,
        client_id = cid,
        pub_topic = pub, sub_topic = sub,
        interval_s = interval, qos = qos,
        allow_no_sn = c.allow_no_sn and true or false,
        keep_session = c.keep_session and true or false,
    }
end

local function kv_flush()
    if fskv then pcall(fskv.save) end
end

function M.load()
    if not fskv or not json then return M.default, "default" end
    local ok, s = pcall(fskv.get, K_CFG)
    if not ok or type(s) ~= "string" or s == "" then return M.default, "default" end
    local okd, t = pcall(json.decode, s)
    if not okd or type(t) ~= "table" then
        log.warn("mqtt_cfg", "decode fail, use default")
        return M.default, "default"
    end
    local n, err = M.normalize(t)
    if not n then
        log.warn("mqtt_cfg", "normalize fail:", tostring(err))
        return M.default, "default"
    end
    return n, "fskv"
end

function M.save(c)
    local n, err = M.normalize(c)
    if not n then return false, err end
    if not json then return false, "no json lib" end
    local oke, s = pcall(json.encode, n)
    if not oke or not s then return false, "encode fail" end
    if #s > 512 then return false, "too large" end
    if not fskv then return false, "no fskv" end
    fskv.set(K_CFG, s)
    kv_flush()
    return true
end

function M.reset()
    if fskv then
        pcall(fskv.del, K_CFG)
        kv_flush()
    end
    return M.default
end

function M.resolve_topics(device_id)
    local c = M.load()
    local need = c.pub_topic:find("{id}", 1, true) or c.sub_topic:find("{id}", 1, true)
    if need and (not device_id or device_id == "") then
        return nil, nil, "topic has {id} but no SN"
    end
    local gsub_id = function(s)
        if not device_id then return s end
        return (s:gsub("{id}", device_id))
    end
    return gsub_id(c.pub_topic), gsub_id(c.sub_topic)
end

function M.effective(device_id)
    local c = M.load()
    local pub, sub, err = M.resolve_topics(device_id)
    return { cfg = c, pub = pub, sub = sub, err = err, ready = pub ~= nil }
end

return M
