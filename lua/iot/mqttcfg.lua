local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local fskv = corelib.try("fskv")
local json = corelib.try("json")

local M = {}

local K_CFG = "mqtt_cfg"

-- host/port/ssl/client_id/interval_s/qos/allow_no_sn/keep_session 是【共用】
-- 参数, 自动档和手动档建连都读这份。user/pass/pub_topic/sub_topic 是【手动档】
-- 独有, 只有 manual_on 为真时才用。manual_on 为假时改用下面 auto 那套:
-- 用户名固定 SN, 密码是首页填的 MQTT凭证密码, topic 用默认模板自动拼。
-- hello/服务调用/属性设置/属性查询 4 条已按"代码精简"从配置项删除, 设备改走
-- core/config.lua 的 PLATFORM_HELLO/FUNC/PSET/PGET_TOPIC 固定常量。
M.default = {
    host = "dz.voltkun.com",
    port = 1883,
    user = "",
    pass = "",
    ssl = false,
    client_id = "",
    pub_topic = "/sys/thing/node/property/post/{sn}",
    sub_topic = "/sys/thing/gw/config/get/{sn}",
    interval_s = cfg.MQTT_INTERVAL_S,
    qos = cfg.MQTT_QOS,
    allow_no_sn = cfg.MQTT_ALLOW_NO_SN,
    keep_session = false,
    -- 【自动档】首页「MQTT 服务器」面板: 用户名列只读显示 SN, 密码框就是
    -- 这里这个 pass。它与手动档那个密码是两份独立的值, 互不影响。
    auto = { pass = "VKBOXGW2026KEY" },
    manual_on = false,
}

-- topic 字段统一表驱动。只剩发布/订阅两条可配(见上面 default 注释):
-- 长度校验与默认值回退逻辑完全一样, 逐个手写会漏改
local TOPIC_KEYS = {
    pub_topic = "pub_topic", sub_topic = "sub_topic",
}

local function num(v, d)
    if v == nil then return d end
    return tonumber(v) or d end

-- 自动档密码。两种来源: c.auto.pass 是已落盘的表, c.auto_pass 是前端
-- W:MQTT 下发的新键(与手动档的 pass 区分, 否则前端无法表达"改哪个密码")
local function norm_auto(c, d)
    local p
    if type(c.auto) == "table" and type(c.auto.pass) == "string" then p = c.auto.pass end
    if type(c.auto_pass) == "string" then p = c.auto_pass end
    if type(p) ~= "string" then p = "" end
    p = p:sub(1, 64)
    if p == "" then p = d.auto.pass end
    return { pass = p }
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
    -- 手动档用户名缺字段时回退到 d.user(默认空): 空 = 用设备 SN 兜底
    -- (见 mqttcfg.profile / iot.try_connect)
    local user = c.user
    if type(user) ~= "string" then user = "" end
    user = user:sub(1, 64)
    -- 手动档密码缺字段时回退到 d.pass(默认空): 空 = 匿名连, 由平台决定
    -- 放不放行。自动档密码不在这条链上, 走 norm_auto。
    -- 不能把两个密码混成一个键: 两档是两份独立的凭证, 混了就会"改一个
    -- 冲另一个", 前端也就没法表达"这次改的是哪一档"
    local pass = c.pass
    if type(pass) ~= "string" then pass = "" end
    pass = pass:sub(1, 64)
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
        auto = norm_auto(c, d),
        manual_on = c.manual_on and true or false,
    }
    if out.interval_s < 0 or out.interval_s > 86400 then return nil, "bad interval_s" end
    if out.qos < 0 or out.qos > 2 then return nil, "bad qos" end
    for _, k in pairs(TOPIC_KEYS) do
        local v = c[k]
        if type(v) ~= "string" or v == "" then v = d[k] end
        if #v > 128 then return nil, "bad " .. k end
        out[k] = v
    end
    -- 手动档写入 = "先清后写", 不是合并。
    -- 整条 out 都是从这次的 W:MQTT payload 加默认值重建的, 没有任何字段
    -- 从 fskv 旧值里搬过来。这条性质是故意的: 保存手动档时设备必须先把
    -- 自动拼的那套 topic/凭证丢掉, 再整体换成用户填的。若做成"缺字段保留
    -- 现值", 用户清空某个 topic 想让它回落默认, 实际会留下上一次的值,
    -- 表现为"我怎么改都改不掉"
    if not out.manual_on then
        out.user, out.pass = "", ""
        out.pub_topic, out.sub_topic = d.pub_topic, d.sub_topic
    end
    return out
end

local function kv_flush()
    if fskv and fskv.save then pcall(fskv.save) end
end

function M.load()
    -- 每条 early-exit 都过一遍 normalize: 一是给调用方一份干净拷贝(否则
    -- 拿到的是 M.default 本体, 谁改一下 auto 子表就把默认值污染了),
    -- 二是保证 auto/manual_on 这几个新键在"从没存过配置"时也存在
    local d = M.normalize({})
    if not fskv or not json then return d, "default" end
    local ok, s = pcall(fskv.get, K_CFG)
    if not ok or type(s) ~= "string" or s == "" then return d, "default" end
    local okd, t = pcall(json.decode, s)
    if not okd or type(t) ~= "table" then
        log.warn("mqtt_cfg", "decode fail, use default")
        return d, "default"
    end
    local n, err = M.normalize(t)
    if not n then
        log.warn("mqtt_cfg", "normalize fail:", tostring(err))
        return d, "default"
    end
    return n, "fskv"
end

function M.save(c)
    local n, err = M.normalize(c)
    if not n then return false, err end
    if not json then return false, "no json lib" end
    local oke, s = pcall(json.encode, n)
    if not oke or not s then return false, "encode fail" end
    -- 上限 2048。原 512 根本不够: host 128 + clientId 128 + 两条 topic
    -- 各 128 就 512B, 再加三段密码直接超。2048 对最长字段仍有 3 倍余量
    if #s > 2048 then return false, "too large" end
    if not fskv then return false, "no fskv" end
    fskv.set(K_CFG, s)
    kv_flush()
    return true
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

-- 设备实际建连要用的那套凭证和 topic, 由 manual_on 决定:
--   手动档 = 前端「MQTT 配置」页填的 user/pass + 手动 topic 模板
--   自动档 = 用户名留空(iot 兜底填 SN) + 首页那份 MQTT凭证密码 + 默认模板
-- 返回 nil + 原因: topic 含 {sn} 却没有 SN(无 SN + allow_no_sn 才会走到)
function M.profile(device_id)
    local c = M.load()
    local user, pass, pub_t, sub_t
    if c.manual_on then
        user, pass = c.user, c.pass
        pub_t, sub_t = c.pub_topic, c.sub_topic
    else
        user, pass = "", c.auto.pass
        pub_t, sub_t = M.default.pub_topic, M.default.sub_topic
    end
    if (has_sn_ph(pub_t) or has_sn_ph(sub_t))
        and (not device_id or device_id == "") then
        return nil, "topic has {sn} but no SN"
    end
    return {
        user = user, pass = pass,
        pub = sub_sn(pub_t, device_id),
        sub = sub_sn(sub_t, device_id),
    }
end

-- hello topic 走固定平台常量(不再可配)。无 SN 返回 nil, 调用方据此报错:
-- 这时候发出去会把不带 SN 的 topic 发给平台, 表现为"发过去了但没人收"
function M.resolve_hello(device_id)
    if not device_id or device_id == "" then return nil end
    return string.format(cfg.PLATFORM_HELLO_TOPIC, device_id)
end

-- 给前端 R:MQTT 用: cfg 是原值(表单回填), pub/sub 是当前档次实际生效的成品
function M.effective(device_id)
    local c = M.load()
    local p, err = M.profile(device_id)
    return {
        cfg = c,
        pub = p and p.pub, sub = p and p.sub,
        err = err, ready = p ~= nil,
    }
end

-- 切回 idle 时的 MQTT 复位: 只清手动档, 首页配好的平台连接原样留着。
--
-- 保留(首页「MQTT 服务器」面板能改的, 属"首页写入的内容"):
--   host / port / ssl / client_id / interval_s / qos / allow_no_sn / keep_session
--   以及 auto.pass(首页那份 MQTT凭证密码, 与手动档的 pass 是两份独立的值)
--   ⚠️ ssl 尤其必须留: 同一个 host 的 1883 明文和 8883 TLS 是两条路, 只保
--      host+port 不保 ssl 会把走 TLS 的用户打回明文, 表现是"切回来就连不上了"
--
-- 清掉: user / pass / pub_topic / sub_topic(手动档凭证与 topic), 回落默认模板。
--      置空即可, normalize 缺字段回退默认, manual_on=false 时还会强制把两条
--      topic 打回默认模板(见 normalize 末尾), 不用在这里拼默认值。
--
-- ⚠️ manual_on 必须和"清值"在同一个 save 里完成: normalize 在 manual_on=true 时
--    【使用】user/pass/topic。只清值不换档的话, 设备会拿空凭证匿名连平台 ——
--    表现是"切回 idle 后再没连上过 MQTT", 且前端 MQTT 页显示成手动档。
--    拆成两步(先存空值再换档)中间任何一次失败都会留在那个失联状态
-- 返回 ok, err, wrote: wrote=false 表示本来就是干净态, 没动 fskv。
-- 调用方要拿 wrote 决定"清过了"要不要报给用户 —— 从来没配过手动档的设备
-- 每切一次空闲都回一句"已清空 MQTT 手动档"是谎报
function M.clear_manual()
    local c = M.load()
    -- 已经是干净态就别写: 每次切空闲都白写一次 fskv + save, 而 flash
    -- 擦写次数是有限的。判据只看 manual_on —— normalize 在它为 false 时
    -- 已强制把 user/pass 清空、两条 topic 打回默认模板(见 normalize 末尾),
    -- 所以这四项不可能"单独脏"
    if not c.manual_on then return true, nil, false end
    c.manual_on = false
    c.user, c.pass = "", ""
    c.pub_topic, c.sub_topic = ""
    local ok, err = M.save(c)
    return ok, err, ok
end

return M
