local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local fskv = corelib.try("fskv")
local json = corelib.try("json")

local M = {}

local K_CFG = "mqtt_cfg"

-- host/port/ssl/client_id/interval_s/qos/allow_no_sn/keep_session 是【共用】
-- 参数, 自动档和手动档建连都读这份。user/pass 是【手动档】独有, 只有
-- manual_on 为真时才用。manual_on 为假时改用下面 auto 那套: 用户名留空
-- (iot 兜底填 SN) + 首页那份 MQTT凭证密码。
-- pub_topic/sub_topic 也是【手动档】独有: 手动档连的是用户自己的 broker 和
-- 自己的 topic 命名, 这两条由用户填。自动档不用它们, 直接走
-- core/config.lua 的 PLATFORM_* 固定常量(见 profile)。
M.default = {
    host = "dz.voltkun.com",
    port = 1883,
    user = "",
    pass = "",
    pub_topic = "/sys/thing/node/property/post/{sn}",
    sub_topic = "/sys/thing/gw/config/get/{sn}",
    ssl = false,
    client_id = "",
    interval_s = cfg.MQTT_INTERVAL_S,
    qos = cfg.MQTT_QOS,
    allow_no_sn = cfg.MQTT_ALLOW_NO_SN,
    keep_session = false,
    -- 【自动档】首页「MQTT 服务器」面板: 用户名列只读显示 SN, 密码框就是
    -- 这里这个 pass。它与手动档那个密码是两份独立的值, 互不影响。
    auto = { pass = "VKBOXGW2026KEY" },
    manual_on = false,
}

local function num(v, d)
    if v == nil then return d end
    return tonumber(v) or d
end

-- topic 模板校验: 截断到 128, 去掉首尾空格。{sn} 是占位符, 由
-- profile() 代。空串 = 用默认模板
local function norm_topic(v, d)
    if type(v) ~= "string" then return d end
    v = v:gsub("^%s*(.-)%s*$", "%1")
    if v == "" then return d end
    return v:sub(1, 128)
end

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
    -- 缺字段回退默认值: W:MQTT 只改 host/port 时不应因缺字段而失败
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
        pub_topic = norm_topic(c.pub_topic, d.pub_topic),
        sub_topic = norm_topic(c.sub_topic, d.sub_topic),
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
    -- 手动档写入 = "先清后写", 不是合并。
    -- 整条 out 都是从这次的 W:MQTT payload 加默认值重建的, 没有任何字段
    -- 从 fskv 旧值里搬过来。这条性质是故意的: 保存手动档时设备必须先把
    -- 自动档那套凭证丢掉, 再整体换成用户填的。若做成"缺字段保留现值",
    -- 用户清空用户名想让它回落 SN 兜底, 实际会留下上一次的值,
    -- 表现为"我怎么改都改不掉"
    if not out.manual_on then
        out.user, out.pass = "", ""
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
    -- 上限 2048。原 512 根本不够: host 128 + clientId 128 + 两段密码 +
    -- 两条 topic(各 128) 直接超。2048 对最长字段仍有 2 倍余量
    if #s > 2048 then return false, "too large" end
    if not fskv then return false, "no fskv" end
    fskv.set(K_CFG, s)
    kv_flush()
    return true
end

-- 设备实际建连要用的那套凭证, 由 manual_on 决定:
--   手动档 = 前端「MQTT 配置」页填的 user/pass/pub_topic/sub_topic
--   自动档 = 用户名留空(iot 兜底填 SN) + 首页那份 MQTT凭证密码,
--            topic 用 PLATFORM_* 固定常量(默认模板与常量同形, 见 M.default)
-- {sn} 占位符在这里代, 调用方拿到的是成品 topic。
-- did 为空(未烧号)时两档都返回 nil: 手动档的 resolve 和自动档的 format
-- 都不做兜底 —— string.format("%s", nil) 在 Lua 5.1 下直接报错, 而
-- "没有 SN 的设备连上去也没有意义", 让调用方自己判空更清楚
local function resolve(tpl, did)
    if not did or did == "" then return nil end
    return (tpl:gsub("{sn}", did))
end

local function fmt_const(tpl, did)
    if not did or did == "" then return nil end
    return string.format(tpl, did)
end

function M.profile(did)
    local c = M.load()
    if c.manual_on then
        return {
            user = c.user, pass = c.pass,
            pub = resolve(c.pub_topic, did),
            sub = resolve(c.sub_topic, did),
        }
    end
    return {
        user = "", pass = c.auto.pass,
        pub = fmt_const(cfg.PLATFORM_PUB_TOPIC, did),
        sub = fmt_const(cfg.PLATFORM_GET_TOPIC, did),
    }
end

-- 给前端 R:MQTT 用: cfg 是原值(表单回填), ready 表示当前档次凭证齐了能连
function M.effective()
    local c = M.load()
    local p = M.profile()
    return {
        cfg = c,
        err = p.err, ready = p ~= nil,
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
-- 清掉: user / pass / pub_topic / sub_topic(手动档凭证与 topic)。
--      置空即可, normalize 在 manual_on=false 时会强制把它们清空
--      (见 normalize 末尾), 不用在这里拼默认值。
--
-- ⚠️ manual_on 必须和"清值"在同一个 save 里完成: normalize 在 manual_on=true 时
--    【使用】user/pass。只清值不换档的话, 设备会拿空凭证匿名连平台 ——
--    表现是"切回 idle 后再没连上过 MQTT", 且前端 MQTT 页显示成手动档。
--    拆成两步(先存空值再换档)中间任何一次失败都会留在那个失联状态
-- 返回 ok, err, wrote: wrote=false 表示本来就是干净态, 没动 fskv。
-- 调用方要拿 wrote 决定"清过了"要不要报给用户 —— 从来没配过手动档的设备
-- 每切一次空闲都回一句"已清空 MQTT 手动档"是谎报
function M.clear_manual()
    local c = M.load()
    -- 已经是干净态就别写: 每次切空闲都白写一次 fskv + save, 而 flash
    -- 擦写次数是有限的。判据只看 manual_on —— normalize 在它为 false 时
    -- 已强制把 user/pass/pub/sub 清空, 所以这几项不可能"单独脏"
    if not c.manual_on then return true, nil, false end
    c.manual_on = false
    c.user, c.pass = "", ""
    c.pub_topic, c.sub_topic = "", ""
    local ok, err = M.save(c)
    return ok, err, ok
end

return M
