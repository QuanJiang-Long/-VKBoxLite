local util = require "util"
local cfg = require "core/config"
local log = util.log()

local fskv = util.try("fskv")
local json = util.try("json")

local M = {}




local MODE_MANUAL, MODE_PLATFORM, MODE_IDLE, MODE_SNIFF = "manual", "platform", "idle", "sniff"

local K_POLL, K_SYS = "ds_poll", "ds_sys"



local K_PULL = "ds_pull"




local K_ALIAS = "ds_alias"

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




local json_cache = {}   -- fskv key -> 解码后的原始表




local cfg_ver = 0

function M.version() return cfg_ver end

local function kv_set(k, s)
    if not fskv then return false end
    json_cache[k] = nil   -- 12-fix-3: 写盘了, 解码缓存必须失效
    cfg_ver = cfg_ver + 1 -- 12-fix-9: 版本号跟着涨(别名映射缓存靠它失效)
    fskv.set(k, s)
    if fskv.save then pcall(fskv.save) end
    return true
end

















local function load_json(k, default)
    local cached = json_cache[k]
    if cached ~= nil then return cached end
    local s = kv_get(k)
    if not s or not json then
        json_cache[k] = default
        return default
    end
    local ok, t = pcall(json.decode, s)
    if ok and type(t) == "table" then
        json_cache[k] = t
        return t
    end
    log.warn("cfg", "decode fail", k)
    json_cache[k] = default
    return default
end

local function save_json(k, t)
    if not json then return false, "no json lib" end
    local ok, s = pcall(json.encode, t)
    if not ok or not s then return false, "encode fail" end





    if #s > 16384 then return false, "too large" end
    return kv_set(k, s)
end

M.default_poll = {
    baud = cfg.BAUD,
    databits = cfg.DATABITS,
    stopbits = cfg.STOPBITS,
    parity = cfg.PARITY,
    slave = cfg.SLAVE_ADDR,
    interval_ms = cfg.POLL_INTERVAL_MS,
    timeout_ms = cfg.TIMEOUT_MS,
    regs = cfg.REG_DEFAULT,
}

M.default_sys = { boot_mode = MODE_IDLE }



local MAX_ALIAS = 128

M.default_alias = { regs = {} }



function M.normalize_alias(c)
    c = c or {}
    local out = { regs = {} }
    local seen = {}
    local regs = c.regs
    if type(regs) == "table" then
        for _, r in ipairs(regs) do
            if type(r) == "table" then
                local key = str(r.key, "")
                if key:match("^reg%d+$") then
                    local id = str(r.id, "")
                    local nm = str(r.name, "")
                    if id ~= "" or nm ~= "" then
                        if #id > 64 then return nil, "alias id 太长(64 字符内)" end
                        if #nm > 64 then return nil, "alias name 太长(64 字符内)" end
                        if not seen[key] then
                            seen[key] = true
                            out.regs[#out.regs + 1] = { key = key, id = id, name = nm }
                            if #out.regs >= MAX_ALIAS then return nil, "别名条数过多" end
                        end
                    end
                end
            end
        end
    end
    return out
end









local alias_map_cache = nil
local alias_map_ver = -1

function M.alias_map()
    local v = cfg_ver
    if alias_map_cache and alias_map_ver == v then return alias_map_cache end
    local m = {}
    local c = M.load_alias()
    for _, r in ipairs((c and c.regs) or {}) do
        m[r.key] = { id = r.id, name = r.name }
    end
    alias_map_cache = m
    alias_map_ver = v
    return m
end


function M.set_alias(key, id, name)
    local c = M.load_alias()
    local out = { regs = {} }
    local found = false
    for _, r in ipairs((c and c.regs) or {}) do
        if r.key == key then
            found = true
            if id ~= "" or name ~= "" then
                out.regs[#out.regs + 1] = { key = key, id = id, name = name }
            end
        else
            out.regs[#out.regs + 1] = r
        end
    end
    if not found and (id ~= "" or name ~= "") then
        out.regs[#out.regs + 1] = { key = key, id = id, name = name }
    end
    return M.save_alias(out)
end





function M.clear_alias()
    local c = M.load_alias()
    if not c or not c.regs or #c.regs == 0 then return true end
    return M.save_alias({ regs = {} })
end

local function normalize_reg(r)
    if type(r) ~= "table" then return nil, "not table" end

    local ok, why = util.validate_reg(r)
    if not ok then return nil, why end
    return {
        addr = num(r.addr), count = num(r.count, 1),
        dtype = str(r.dtype, "uint16"),
        name = r.name,
        alias = str(r.alias, r.name),
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
            if #out.regs >= cfg.MAX_REGS then return nil, "too many regs" end



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


    if mode ~= MODE_IDLE and mode ~= MODE_MANUAL and mode ~= MODE_PLATFORM and mode ~= MODE_SNIFF then
        return nil, "bad boot_mode"
    end
    return { boot_mode = mode }
end




local SECTIONS = {
    poll = { key = K_POLL, norm = M.normalize_poll, default = M.default_poll },
    pull = { key = K_PULL, norm = M.normalize_poll, default = M.default_poll },
    sys = { key = K_SYS, norm = M.normalize_sys, default = M.default_sys },
    alias = { key = K_ALIAS, norm = M.normalize_alias, default = M.default_alias },
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







function M.has_poll_cfg()
    if M.poll_src() ~= "fskv" then return false end
    local c = M.load_poll()
    return c and #(c.regs or {}) > 0
end

function M.has_pull_cfg()
    if M.pull_src() ~= "fskv" then return false end
    local c = M.load_pull()
    return c and #(c.regs or {}) > 0
end


















local RESET_SLOTS = { { "manual 配置", K_POLL }, { "platform 配置", K_PULL } }

function M.reset_user()
    local cleared = {}
    if not fskv then return cleared end
    for _, s in ipairs(RESET_SLOTS) do
        local name, k = s[1], s[2]


        local ok, v = pcall(fskv.get, k)
        if ok and v ~= nil and v ~= "" then
            fskv.set(k, "")
            json_cache[k] = nil   -- 12-fix-3: 绕过了 kv_set, 缓存要手动失效
            cfg_ver = cfg_ver + 1 -- 12-fix-9: 版本号也要涨(别名映射缓存靠它失效)
            cleared[#cleared + 1] = name
        end
    end
    if #cleared > 0 and fskv.save then pcall(fskv.save) end
    return cleared
end





function M.clear_pull()
    if not fskv then return false, "fskv 不可用", false end
    local ok, v = pcall(fskv.get, K_PULL)
    if not ok then return false, "读 ds_pull 失败: " .. tostring(v), false end
    if v == nil or v == "" then return true, nil, false end
    fskv.set(K_PULL, "")
    json_cache[K_PULL] = nil   -- 12-fix-3: 绕过了 kv_set, 缓存要手动失效
    cfg_ver = cfg_ver + 1     -- 12-fix-9: 版本号也要涨(别名映射缓存靠它失效)
    if fskv.save then pcall(fskv.save) end
    return true, nil, true
end

return M
