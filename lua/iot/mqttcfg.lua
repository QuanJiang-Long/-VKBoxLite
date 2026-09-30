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
    -- 默认与平台 topic 对齐: 上报走 node/property/post, 下行走 gw/config/get。
    -- {sn} 会替换成设备 SN。前端两个输入框留空时就用这两个值。
    -- 注意: sub_topic 默认与 PLATFORM_GET_TOPIC 同形, 所以 iot.lua 的
    -- 订阅列表会去重, 且下行分流只在拉取状态机等待时才当配置包收。
    pub_topic = "/sys/thing/node/property/post/{sn}",
    sub_topic = "/sys/thing/gw/config/get/{sn}",
    -- hello topic: 拉取配置时向平台自述身份用的发布 topic。
    -- 与上报 topic 分开——一个是控制面, 一个是数据面, 平台两侧按不同
    -- 前缀解析, 混用会导致指令/数据都进错队列
    hello_topic = "/sys/thing/gw/config/hello/{sn}",
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
    -- 缺字段回退默认值: W:MQTT 只改 host/port 时不应因缺 topic 而失败
    if host == "" then host = d.host end
    if host == "" or #host > 128 then return nil, "bad host" end
    local port = math.floor(num(c.port, d.port))
    if port < 1 or port > 65535 then return nil, "bad port" end
    local user, pass = "", ""
    if type(c.user) == "string" then user = c.user:sub(1, 64) end
    if type(c.pass) == "string" then pass = c.pass:sub(1, 64) end
    local cid = ""
    if type(c.client_id) == "string" then cid = c.client_id:gsub("^%s*(.-)%s*$", "%1"):sub(1, 128) end
    local pub = c.pub_topic
    if type(pub) ~= "string" or pub == "" then pub = d.pub_topic end
    if #pub > 128 then return nil, "bad pub_topic" end
    local sub = c.sub_topic
    if type(sub) ~= "string" or sub == "" then sub = d.sub_topic end
    if #sub > 128 then return nil, "bad sub_topic" end
    local hello = c.hello_topic
    if type(hello) ~= "string" or hello == "" then hello = d.hello_topic end
    if #hello > 128 then return nil, "bad hello_topic" end
    local interval = math.floor(num(c.interval_s, d.interval_s))
    if interval < 0 or interval > 86400 then return nil, "bad interval_s" end
    local qos = math.floor(num(c.qos, d.qos))
    if qos < 0 or qos > 2 then return nil, "bad qos" end
    return {
        host = host, port = port, user = user, pass = pass,
        ssl = c.ssl and true or false,
        client_id = cid,
        hello_topic = hello, pub_topic = pub, sub_topic = sub,
        interval_s = interval, qos = qos,
        allow_no_sn = c.allow_no_sn and true or false,
        keep_session = c.keep_session and true or false,
    }
end

local function kv_flush()
    if fskv and fskv.save then pcall(fskv.save) end
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

-- {sn} 与 {id} 等价(都替换成设备 SN)。{sn} 是新默认模板用的写法,
-- {id} 保留是为了兼容 fskv 里已存过的旧配置, 否则老配置会把字面 {id} 发出去
local function has_sn_ph(s)
    return s:find("{sn}", 1, true) ~= nil or s:find("{id}", 1, true) ~= nil
end

local function sub_sn(s, did)
    if not did then return s end
    return (s:gsub("{sn}", did):gsub("{id}", did))
end

function M.resolve_topics(device_id)
    local c = M.load()
    -- hello_topic 也要一起判: 它含 {sn} 却无 SN 时 try_connect 会放行,
    -- 但拉取时 hello 发不出去, 报错点离现场太远
    if (has_sn_ph(c.pub_topic) or has_sn_ph(c.sub_topic) or has_sn_ph(c.hello_topic))
        and (not device_id or device_id == "") then
        return nil, nil, "topic has {sn} but no SN"
    end
    return sub_sn(c.pub_topic, device_id), sub_sn(c.sub_topic, device_id)
end

-- hello topic 单独解: 拉取状态机发 hello 时用, 无 SN 返回 nil(调用方报错)
function M.resolve_hello(device_id)
    local c = M.load()
    if has_sn_ph(c.hello_topic) and (not device_id or device_id == "") then return nil end
    return sub_sn(c.hello_topic, device_id)
end

function M.effective(device_id)
    local c = M.load()
    local pub, sub, err = M.resolve_topics(device_id)
    return { cfg = c, pub = pub, sub = sub, err = err, ready = pub ~= nil }
end

return M
