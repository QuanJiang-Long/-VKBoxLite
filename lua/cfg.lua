-- cfg: 全部配置 + 全局常量 + SN + MQTT 凭证
-- 合并: 原 cfg.lua + core/config.lua + iot/mqttcfg.lua + sn/sn.lua
-- 命名: cfg.xxx (常量/工具), cfg.mqtt_xxx (凭证), cfg.sn_xxx (SN)

local util = require "util"
local log = util.log()
local fskv = util.try("fskv")
local json = util.try("json")

local M = {}

-- ===== 全局常量 (from core/config.lua) =====

M.BAUD = 9600
M.DATABITS = 8
M.STOPBITS = 1
M.PARITY = 0

M.SLAVE_ADDR = 1
M.POLL_INTERVAL_MS = 5000
M.TIMEOUT_MS = 500
M.REG_DEFAULT = {}
M.MAX_REGS = 128

M.WDT_TIMEOUT = 9000
M.WDT_FEED_MS = 3000
M.MONITOR_MS = 10000
M.STALL_LIMIT_S = 120
M.AUTO_REBOOT = false

M.SN_MIN_LEN = 17
M.SN_MAX_LEN = 32
M.SN_WARN_PERIOD_S = 600

M.MQTT_INTERVAL_S = 60
M.MQTT_QOS = 1
M.MQTT_ALLOW_NO_SN = false

M.PLATFORM_VENDOR = "VKBoxLite"
M.PLATFORM_MODEL = "VKBox-Lite"
M.PLATFORM_GET_TOPIC = "/sys/thing/gw/config/get/%s"
M.PLATFORM_REPLY_TOPIC = "/sys/thing/gw/config/reply/%s"
M.PLATFORM_HELLO_TOPIC = "/sys/thing/gw/config/hello/%s"
M.PLATFORM_PUB_TOPIC = "/sys/thing/node/property/post/%s"
M.PLATFORM_INFO_TOPIC = "/sys/thing/gw/info/post/%s"
M.PLATFORM_RES_TOPIC = "/sys/thing/gw/property/post/%s"
M.PLATFORM_FPOST_TOPIC = "/sys/thing/gw/function/post/%s"
M.PLATFORM_FUNC_TOPIC = "/sys/thing/gw/function/get/%s"
M.PLATFORM_PSET_TOPIC = "/sys/thing/gw/property/set/%s"
M.PLATFORM_PGET_TOPIC = "/sys/thing/gw/property/get/%s"
M.PULL_TIMEOUT_MS = 15000
M.PULL_CONNECT_MS = 20000
M.HELLO_RE_S = 1800
M.HELLO_BACKOFF_S = { 1, 3, 9 }
M.PULL_DTYPE = {
    ushort = "uint16", uint16 = "uint16",
    short = "int16", int16 = "int16",
    ulong = "uint32", uint32 = "uint32",
    long = "int32", int32 = "int32",
    float = "float32", float32 = "float32",
    double = "float64", float64 = "float64",
}
M.PULL_ORDER_OK = { abcd = true }
M.PULL_PARITY = { none = 0, even = 1, odd = 2 }

M.FRAME_CACHE = 10
M.RING_SIZE = 12
M.WRITEQ_MAX = 8

M.DETECT_BAUDS = { 9600, 4800, 2400, 1200 }
M.DETECT_WIN_MS = 1000
M.DETECT_HITS = 2

-- ===== 模式常量 (from cfg.lua) =====
local MODE_POLL, MODE_PULL, MODE_IDLE, MODE_SNIFF = "poll", "pull", "idle", "sniff"
local K_POLL, K_SYS = "ds_poll", "ds_sys"
local K_PULL = "ds_pull"

-- ===== 工具 (from cfg.lua) =====
local function num(v, d)
    if v == nil then return d end
    return tonumber(v) or d
end
local function str(v, d)
    if type(v) ~= "string" or v == "" then return d end
    return v
end
local function kv_get(k)
    if not fskv then return nil end
    local ok, v = pcall(fskv.get, k)
    if ok and type(v) == "string" and v ~= "" then return v end
    return nil
end
local function kv_set(k, s)
    if not fskv then return false end
    fskv.set(k, s)
    if fskv.save then pcall(fskv.save) end
    return true
end
local function load_json(k, default)
    local s = kv_get(k)
    if not s or not json then return default end
    local ok, t = pcall(json.decode, s)
    if ok and type(t) == "table" then return t end
    log.warn("cfg", "decode fail", k)
    return default
end
local function save_json(k, t)
    if not json then return false, "no json lib" end
    local ok, s = pcall(json.encode, t)
    if not ok or not s then return false, "encode fail" end
    if #s > 16384 then return false, "too large" end
    return kv_set(k, s)
end

-- ===== poll/pull/sys 三套配置 (from cfg.lua) =====
M.default_poll = {
    baud = M.BAUD, databits = M.DATABITS, stopbits = M.STOPBITS, parity = M.PARITY,
    slave = M.SLAVE_ADDR, interval_ms = M.POLL_INTERVAL_MS, timeout_ms = M.TIMEOUT_MS,
    regs = M.REG_DEFAULT,
}
M.default_sys = { boot_mode = MODE_IDLE }

local function normalize_reg(r)
    if type(r) ~= "table" then return nil, "not table" end
    local ok, why = util.validate_reg(r)
    if not ok then return nil, why end
    return {
        addr = num(r.addr), count = num(r.count, 1),
        dtype = str(r.dtype, "uint16"),
        name = r.name, alias = str(r.alias, r.name),
    }
end
local function normalize_common(c, d)
    c = c or {}
    return {
        baud = math.floor(num(c.baud, d.baud)),
        databits = math.floor(num(c.databits, d.databits)),
        stopbits = math.floor(num(c.stopbits, d.stopbits)),
        parity = math.floor(num(c.parity, d.parity)),
    }
end
function M.normalize_poll(c)
    local out = normalize_common(c, M.default_poll)
    out.slave = math.floor(num(c.slave, M.default_poll.slave))
    if out.slave < 1 or out.slave > 247 then return nil, "bad slave" end
    out.interval_ms = math.floor(num(c.interval_ms, M.default_poll.interval_ms))
    if out.interval_ms < 100 then return nil, "bad interval" end
    if c.timeout_ms == nil then
        out.timeout_ms = nil
    else
        local t = math.floor(num(c.timeout_ms, M.default_poll.timeout_ms))
        if t < 50 or t > 500 then return nil, "响应上限越界(50~500ms)" end
        out.timeout_ms = t
    end
    out.regs = {}
    local seen = {}
    local regs = c.regs
    if type(regs) == "table" then
        for _, r in ipairs(regs) do
            local nr, err = normalize_reg(r)
            if not nr then return nil, err end
            if #out.regs >= M.MAX_REGS then return nil, "too many regs" end
            if not seen[nr.addr] then
                seen[nr.addr] = true
                out.regs[#out.regs + 1] = nr
            end
        end
    end
    return out
end
function M.normalize_sys(c)
    c = c or {}
    local mode = str(c.boot_mode, MODE_IDLE):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if mode ~= MODE_IDLE and mode ~= MODE_POLL and mode ~= "pollpull" and mode ~= MODE_SNIFF then
        return nil, "bad boot_mode"
    end
    return { boot_mode = mode }
end
local SECTIONS = {
    poll = { key = K_POLL, norm = M.normalize_poll, default = M.default_poll },
    pull = { key = K_PULL, norm = M.normalize_poll, default = M.default_poll },
    sys = { key = K_SYS, norm = M.normalize_sys, default = M.default_sys },
}
for name, sec in pairs(SECTIONS) do
    M["load_" .. name] = function()
        local raw = load_json(sec.key, {})
        local ok, c = pcall(sec.norm, raw)
        if not ok or not c then
            log.warn("cfg", name, "normalize fail, use default")
            return sec.default
        end
        return c
    end
    M["save_" .. name] = function(c)
        local n, err = sec.norm(c)
        if not n then return false, err end
        return save_json(sec.key, n)
    end
end

function M.poll_src()
    if not fskv then return "default" end
    local v = fskv.get(K_POLL)
    if v == nil or v == "" then return "default" end
    return "fskv"
end
function M.pull_src()
    if not fskv then return "default" end
    local v = fskv.get(K_PULL)
    if v == nil or v == "" then return "default" end
    return "fskv"
end

local RESET_SLOTS = { { MODE_POLL, K_POLL }, { MODE_PULL, K_PULL } }
function M.reset_user()
    local cleared = {}
    if not fskv then return cleared end
    for _, s in ipairs(RESET_SLOTS) do
        local name, k = s[1], s[2]
        local ok, v = pcall(fskv.get, k)
        if ok and v ~= nil and v ~= "" then
            fskv.set(k, "")
            cleared[#cleared + 1] = name
        end
    end
    if #cleared > 0 and fskv.save then pcall(fskv.save) end
    return cleared
end

-- ===== MQTT 凭证 (from iot/mqttcfg.lua) =====
local K_MQTT = "mqtt_cfg"
M.mqtt_default = {
    host = "dz.voltkun.com",
    port = 1883,
    user = "",
    pass = "",
    pub_topic = "/sys/thing/node/property/post/{sn}",
    sub_topic = "/sys/thing/gw/config/get/{sn}",
    ssl = false,
    client_id = "",
    interval_s = M.MQTT_INTERVAL_S,
    qos = M.MQTT_QOS,
    allow_no_sn = M.MQTT_ALLOW_NO_SN,
    keep_session = false,
    auto = { pass = "VKBOXGW2026KEY" },
    manual_on = false,
}
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
function M.mqtt_normalize(c)
    c = c or {}
    local d = M.mqtt_default
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
        allow_no_sn = c.allow_no_sn and true or false,
        keep_session = c.keep_session and true or false,
        auto = norm_auto(c, d),
        manual_on = c.manual_on and true or false,
    }
    if out.interval_s < 0 or out.interval_s > 86400 then return nil, "bad interval_s" end
    if out.qos < 0 or out.qos > 2 then return nil, "bad qos" end
    if not out.manual_on then
        out.user, out.pass = "", ""
    end
    return out
end
local function kv_flush()
    if fskv and fskv.save then pcall(fskv.save) end
end
function M.mqtt_load()
    local d = M.mqtt_normalize({})
    if not fskv or not json then return d, "default" end
    local ok, s = pcall(fskv.get, K_MQTT)
    if not ok or type(s) ~= "string" or s == "" then return d, "default" end
    local okd, t = pcall(json.decode, s)
    if not okd or type(t) ~= "table" then
        log.warn("mqtt_cfg", "decode fail, use default")
        return d, "default"
    end
    local n, err = M.mqtt_normalize(t)
    if not n then
        log.warn("mqtt_cfg", "normalize fail:", tostring(err))
        return d, "default"
    end
    return n, "fskv"
end
function M.mqtt_save(c)
    local n, err = M.mqtt_normalize(c)
    if not n then return false, err end
    if not json then return false, "no json lib" end
    local oke, s = pcall(json.encode, n)
    if not oke or not s then return false, "encode fail" end
    if #s > 2048 then return false, "too large" end
    if not fskv then return false, "no fskv" end
    fskv.set(K_MQTT, s)
    kv_flush()
    return true
end
function M.mqtt_clear_manual()
    local c = M.mqtt_load()
    if not c.manual_on then return true, nil, false end
    c.manual_on = false
    c.user, c.pass = "", ""
    c.pub_topic, c.sub_topic = "", ""
    local ok, err = M.mqtt_save(c)
    return ok, err, ok
end

-- {sn} 占位符在这里代, 调用方拿到的是成品 topic
local function resolve_topic(tpl, did)
    if not did or did == "" then return nil end
    return (tpl:gsub("{sn}", did))
end

-- 设备实际建连要用的那套凭证, 由 manual_on 决定
function M.mqtt_profile(did)
    local c = M.mqtt_load()
    if c.manual_on then
        return {
            user = c.user, pass = c.pass,
            pub = resolve_topic(c.pub_topic, did),
            sub = resolve_topic(c.sub_topic, did),
        }
    end
    return {
        user = "", pass = c.auto.pass,
        pub = string.format(M.PLATFORM_PUB_TOPIC, did),
        sub = string.format(M.PLATFORM_GET_TOPIC, did),
    }
end

-- ===== SN 管理 (from sn/sn.lua, 不含 init) =====
local K_SN, K_LOCK, K_BURN, K_BTIME = "dev_sn", "dev_sn_lock", "dev_sn_burn", "dev_sn_btime"
M.SN_STATE = { EMPTY = "empty", INVALID = "invalid", READY = "ready" }
local sn_state, sn_cache = M.SN_STATE.EMPTY, nil
local changeCbs = {}
function M.sn_locked()
    local ok, v = pcall(fskv.get, K_LOCK)
    if ok then return v == "1" end
    return false
end
function M.sn_meta()
    local function g(k) local ok, v = pcall(fskv.get, k); return ok and v or nil end
    return { burn = tonumber(g(K_BURN)) or 0, btime = tonumber(g(K_BTIME)) or 0 }
end
function M.sn_load()
    local ok, v = pcall(fskv.get, K_SN)
    if ok and v ~= nil and v ~= "" then return v end
    return nil
end
function M.sn_save(sn)
    fskv.set(K_SN, sn)
    local m = M.sn_meta()
    fskv.set(K_BURN, m.burn + 1)
    if m.btime == 0 then fskv.set(K_BTIME, os.time()) end
    kv_flush()
end
function M.sn_set_lock()
    fskv.set(K_LOCK, "1")
    kv_flush()
end
function M.sn_clear_lock()
    pcall(fskv.del, K_LOCK)
    kv_flush()
end
local function notify(sn, st)
    for _, cb in ipairs(changeCbs) do pcall(cb, sn, st) end
end
function M.sn_clear()
    if M.sn_locked() and sn_state ~= M.SN_STATE.INVALID then return false, "locked" end
    pcall(fskv.del, K_SN)
    kv_flush()
    sn_cache, sn_state = nil, M.SN_STATE.EMPTY
    notify(nil, sn_state)
    return true
end
local function luhn_verify(s)
    if #s < 2 then return false end
    local sum, dbl = 0, false
    for i = #s, 1, -1 do
        local c = s:sub(i, i)
        if c < "0" or c > "9" then return false end
        local d = c:byte() - 48
        if dbl then
            d = d * 2
            if d > 9 then d = d - 9 end
        end
        sum = sum + d
        dbl = not dbl
    end
    return sum % 10 == 0
end
function M.sn_validate(sn)
    if type(sn) ~= "string" then return false, "not string" end
    if #sn < M.SN_MIN_LEN or #sn > M.SN_MAX_LEN then return false, "bad length" end
    if not sn:match("^%w+$") then return false, "bad char" end
    if sn:match("^%d+$") and not luhn_verify(sn) then return false, "luhn fail" end
    return true
end
function M.sn_on_change(cb) changeCbs[#changeCbs + 1] = cb end
function M.sn_get_state() return sn_state end
function M.sn_write(new_sn, opts)
    opts = opts or {}
    if M.sn_locked() and sn_state ~= M.SN_STATE.INVALID then return false, "locked" end
    local ok, err = M.sn_validate(new_sn)
    if not ok then return false, err end
    if sn_state == M.SN_STATE.READY then
        if new_sn == sn_cache then return true, "same" end
        if not opts.force then return false, "sn exists" end
    end
    M.sn_save(new_sn)
    if M.sn_load() ~= new_sn then return false, "verify fail" end
    sn_cache, sn_state = new_sn, M.SN_STATE.READY
    log.info("sn", "burned, burn=" .. M.sn_meta().burn)
    notify(new_sn, sn_state)
    return true
end
function M.sn_init()
    if fskv.init then pcall(fskv.init) end
    local sn = M.sn_load()
    if not sn or sn == "" then
        sn_state = M.SN_STATE.EMPTY
        log.warn("sn", "empty, burn via W:SN=")
    else
        local ok, err = M.sn_validate(sn)
        if ok then
            sn_cache, sn_state = sn, M.SN_STATE.READY
        else
            sn_state = M.SN_STATE.INVALID
            log.error("sn", "invalid:", sn, tostring(err))
        end
    end
    _G.get_device_sn = function() return sn_cache end
    return true
end

local imei_cache, uid_cache = nil, nil
local function grab(lib, key)
    if not lib then return nil end
    local v = lib[key]
    if type(v) == "function" then
        local ok, r = pcall(v)
        if ok and r and r ~= "" then return r end
        return nil
    end
    if type(v) == "string" and v ~= "" then return v end
    return nil
end
function M.sn_imei_init()
    local mobile = util.try("mobile")
    local mcu = util.try("mcu")
    if not imei_cache then imei_cache = grab(mobile, "imei") end
    if not uid_cache then uid_cache = grab(mcu, "unique_id") end
    return imei_cache and uid_cache
end
function M.sn_imei() return imei_cache end
function M.sn_imei_wait()
    local sys = util.try("sys")
    M.sn_imei_init()
    if not sys then return end
    sys.taskInit(function()
        for _ = 1, 60 do
            if M.sn_imei_init() then return end
            sys.wait(500)
        end
        log.warn("sn", "identity timeout, imei/uid may be empty")
    end)
end
function M.sn_info_line()
    return string.format("imei:%s;uid:%s;sn:%s;state:%s;lock:%d",
        imei_cache or "", uid_cache or "",
        sn_cache or "", sn_state, M.sn_locked() and 1 or 0)
end
function M.sn_warn_monitor(period)
    local sys = util.try("sys")
    if not sys then return end
    sys.timerLoopStart(function()
        if sn_state ~= M.SN_STATE.READY then
            log.warn("sn", "no sn! burn via W:SN=xxx")
        end
    end, (period or M.SN_WARN_PERIOD_S) * 1000)
end

return M
