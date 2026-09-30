local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local fskv = corelib.try("fskv")
local json = corelib.try("json")

local M = {}

local K_CFG = "mqtt_cfg"

M.default = {
    -- 默认指向本项目的 V3 平台。原先默认 test.mosquitto.org 是联调期
    -- 留下的: 它导致"清配置/新设备"会连到 mosquitto 测试盘而不是自己
    -- 平台(明文且无需认证, 静默连上就开始上报, 现场很难发现)。
    -- 平台地址是公开信息, 与 user/pass 分开 —— 账号密码按约定不进默认值,
    -- 需要每台在「MQTT配置」页填一次并存 fskv。
    host = "dz.voltkun.com",
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
    -- 另外 3 条下行订阅(V3 契约 gw 前缀)。原先写死在 iot.build_subs() 里,
    -- 页面改不了; 挪到这里由前端一并配置, 语义与 hello/pub/sub 完全相同
    func_topic = "/sys/thing/gw/function/get/{sn}",
    pset_topic = "/sys/thing/gw/property/set/{sn}",
    pget_topic = "/sys/thing/gw/property/get/{sn}",
    interval_s = cfg.MQTT_INTERVAL_S,
    qos = cfg.MQTT_QOS,
    allow_no_sn = cfg.MQTT_ALLOW_NO_SN,
    keep_session = false,
}

-- topic 字段统一表驱动: 6 条 topic 的长度校验与默认值回退逻辑完全一样,
-- 逐个手写会重复 6 遍且容易漏改
local TOPIC_KEYS = {
    hello_topic = "hello_topic", func_topic = "func_topic",
    pub_topic = "pub_topic", sub_topic = "sub_topic",
    pset_topic = "pset_topic", pget_topic = "pget_topic",
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
    local out = {
        host = host, port = port, user = user, pass = pass,
        ssl = c.ssl and true or false,
        client_id = cid,
        interval_s = math.floor(num(c.interval_s, d.interval_s)),
        qos = math.floor(num(c.qos, d.qos)),
        allow_no_sn = c.allow_no_sn and true or false,
        keep_session = c.keep_session and true or false,
    }
    if out.interval_s < 0 or out.interval_s > 86400 then return nil, "bad interval_s" end
    if out.qos < 0 or out.qos > 2 then return nil, "bad qos" end
    for _, k in pairs(TOPIC_KEYS) do
        local v = c[k]
        if type(v) ~= "string" or v == "" then v = d[k] end
        if #v > 128 then return nil, "bad " .. k end
        out[k] = v
    end
    return out
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
    -- 上限 2048。原 512 根本不够: host 最长 128 + clientId 最长 128 时,
    -- 光是 3 条 topic 就已经 532B(实测), 加满 6 条到 673B。16.3KB 是
    -- cfgstore 的 json 硬限, 2048 对 6 topic + 最长字段仍有 3 倍余量
    if #s > 2048 then return false, "too large" end
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
    -- 任一条 topic 含 {sn} 却无 SN 时都要报错。原先只查 pub/sub/hello 三条,
    -- 补齐 6 条后漏查的会让 user/前端看到字面 {sn} 被当 SN 用
    for _, k in pairs(TOPIC_KEYS) do
        if has_sn_ph(c[k]) and (not device_id or device_id == "") then
            return nil, nil, "topic has {sn} but no SN"
        end
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
    return {
        cfg = c,
        pub = pub, sub = sub,
        hello = M.resolve_hello(device_id),
        -- 补齐的 3 条下行订阅也要回显成品，前端自动模式下填只读框
        func  = sub_sn(c.func_topic, device_id),
        pset  = sub_sn(c.pset_topic, device_id),
        pget  = sub_sn(c.pget_topic, device_id),
        err = err, ready = pub ~= nil,
    }
end

return M
