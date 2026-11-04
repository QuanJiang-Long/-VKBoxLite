local util = require "util"
local cfg = require "core/config"
local log = util.log()

local fskv = util.try("fskv")
local json = util.try("json")

local M = {}

local K_CFG = "mqtt_cfg"











M.default = {
    host = "dz.voltkun.com",
    port = 1883,
    user = "",
    pass = "",




    pub_topic = "",
    sub_topic = "",
    ssl = false,
    client_id = "",
    interval_s = cfg.MQTT_INTERVAL_S,
    qos = cfg.MQTT_QOS,
    keep_session = false,



    auto = { pass = "" },
    manual_on = false,
}

local function num(v, d)
    if v == nil then return d end
    return tonumber(v) or d
end




local function norm_topic(v, d)
    if type(v) ~= "string" then return d end
    v = v:gsub("^%s*(.-)%s*$", "%1")
    if v == "" then return d end
    return v:sub(1, 128)
end



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

    if host == "" then host = d.host end
    if host == "" or #host > 128 then return nil, "bad host" end
    local port = math.floor(num(c.port, d.port))
    if port < 1 or port > 65535 then return nil, "bad port" end


    local user = c.user
    if type(user) ~= "string" then user = "" end
    user = user:sub(1, 64)




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
        keep_session = c.keep_session and true or false,
        auto = norm_auto(c, d),
        manual_on = c.manual_on and true or false,
    }
    if out.interval_s < 0 or out.interval_s > 86400 then return nil, "bad interval_s" end
    if out.qos < 0 or out.qos > 2 then return nil, "bad qos" end






    if not out.manual_on then
        out.user, out.pass, out.client_id = "", "", ""
    end
    return out
end

local function kv_flush()
    if fskv and fskv.save then pcall(fskv.save) end
end










local load_cache = nil
local load_cache_src = "default"

function M.load()
    if load_cache then return load_cache, load_cache_src end


    local d = M.normalize({})
    if not fskv or not json then
        load_cache, load_cache_src = d, "default"
        return load_cache, load_cache_src
    end
    local ok, s = pcall(fskv.get, K_CFG)
    if not ok or type(s) ~= "string" or s == "" then
        load_cache, load_cache_src = d, "default"
        return load_cache, load_cache_src
    end
    local okd, t = pcall(json.decode, s)
    if not okd or type(t) ~= "table" then
        log.warn("mqtt_cfg", "decode fail, use default")
        load_cache, load_cache_src = d, "default"
        return load_cache, load_cache_src
    end
    local n, err = M.normalize(t)
    if not n then
        log.warn("mqtt_cfg", "normalize fail:", tostring(err))
        load_cache, load_cache_src = d, "default"
        return load_cache, load_cache_src
    end
    load_cache, load_cache_src = n, "fskv"
    return load_cache, load_cache_src
end

function M.save(c)






    if c and not (type(c.auto) == "table" and type(c.auto.pass) == "string" and c.auto.pass ~= "") then
        if not (type(c.auto_pass) == "string" and c.auto_pass ~= "") then
            local prev = M.load()
            if prev and prev.auto and prev.auto.pass and prev.auto.pass ~= "" then
                c.auto = c.auto or {}
                c.auto.pass = prev.auto.pass
            end
        end
    end
    local n, err = M.normalize(c)
    if not n then return false, err end
    if not json then return false, "no json lib" end
    local oke, s = pcall(json.encode, n)
    if not oke or not s then return false, "encode fail" end


    if #s > 2048 then return false, "too large" end
    if not fskv then return false, "no fskv" end
    fskv.set(K_CFG, s)
    kv_flush()
    load_cache = nil      -- 12-fix-4: 落盘了, 缓存必须失效
    load_cache_src = "default"
    return true
end









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
        local p = resolve(c.pub_topic, did)
        return {
            user = c.user, pass = c.pass,
            pub = p,
            sub = resolve(c.sub_topic, did),

            pub_topics = p and { p } or {},
        }
    end
    local pub = fmt_const(cfg.PLATFORM_PUB_TOPIC, did)
    return {
        user = "", pass = c.auto.pass,
        pub = pub,
        sub = fmt_const(cfg.PLATFORM_GET_TOPIC, did),



        pub_topics = pub and { pub .. "-1" } or {},
    }
end


function M.effective()
    local c = M.load()
    local p = M.profile()
    return {
        cfg = c,
        err = p.err, ready = p ~= nil,
    }
end





















function M.clear_manual()
    local c = M.load()


    if not c.manual_on then return true, nil, false end
    c.manual_on = false
    c.user, c.pass, c.client_id = "", "", ""
    c.pub_topic, c.sub_topic = "", ""
    local ok, err = M.save(c)
    return ok, err, ok
end

return M
