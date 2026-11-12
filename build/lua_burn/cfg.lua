local util = require "util"
local cfg = require "core/config"
local log = util.log()

local fskv = util.try("fskv")
local json = util.try("json")

local M = {}




local MODE_MANUAL, MODE_PLATFORM, MODE_IDLE, MODE_SNIFF = "manual", "platform", "idle", "sniff"

local K_POLL, K_SYS = "ds_poll", "ds_sys"




local K_PULL = "ds_pull"
local K_INFER = "ds_infer"





local K_ALIAS = "ds_alias"

local function num(v, d)
    if v == nil then return d end
    return tonumber(v) or d
end

local function str(v, d)
    if type(v) ~= "string" or v == "" then return d end
    return v
end




local function brief(v, n)
    local s = tostring(v):gsub("[\r\n]", " ")
    n = n or 80
    if #s > n then s = s:sub(1, n) end
    return s
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







local FSKV_VALUE_MAX = 4096

local function kv_set(k, s)
    if not fskv then return false, "no fskv" end
    local n = type(s) == "string" and #s or 0
    if n > FSKV_VALUE_MAX then
        log.warn("cfg", "value too big", k, n, "max", FSKV_VALUE_MAX)
        return false, "配置 " .. n .. "B 超 fskv 单值上限 " .. FSKV_VALUE_MAX .. "B"
    end
    local ok, ret = pcall(fskv.set, k, s)
    if not ok or ret == false then
        log.warn("cfg", "fskv.set failed:", k, n .. "B", brief(ret))



        return false, "fskv.set 拒写(值 " .. n .. "B): " .. brief(ret)
    end


    json_cache[k] = nil   -- 12-fix-3: 写盘了, 解码缓存必须失效
    cfg_ver = cfg_ver + 1 -- 12-fix-9: 版本号跟着涨(别名映射缓存靠它失效)
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





    if not ok then return false, "encode fail: " .. brief(s) end
    if not s then return false, "encode fail(无返回)" end





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


M.default_infer = {
    baud = cfg.BAUD,
    databits = cfg.DATABITS,
    stopbits = cfg.STOPBITS,
    parity = cfg.PARITY,
    slave = cfg.SLAVE_ADDR,
    regs = {},
}



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
                            if #out.regs > MAX_ALIAS then return nil, "别名条数过多" end
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





local function normalize_reg(r, reuse)
    if type(r) ~= "table" then return nil, "not table" end

    local ok, why = util.validate_reg(r)
    if not ok then return nil, why end
    local addr, count = num(r.addr), num(r.count, 1)
    local dtype, name = str(r.dtype, "uint16"), r.name
    local alias = str(r.alias, r.name)
    if not reuse then
        return { addr = addr, count = count, dtype = dtype, name = name, alias = alias }
    end
    for k in pairs(r) do r[k] = nil end
    r.addr, r.count, r.dtype, r.name, r.alias = addr, count, dtype, name, alias
    return r
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








function M.normalize_poll(c, inplace)

    local baud = math.floor(num(c.baud, M.default_poll.baud))
    local databits = math.floor(num(c.databits, M.default_poll.databits))
    local stopbits = math.floor(num(c.stopbits, M.default_poll.stopbits))
    local parity = math.floor(num(c.parity, M.default_poll.parity))
    local slave = math.floor(num(c.slave, M.default_poll.slave))
    local interval = math.floor(num(c.interval_ms, M.default_poll.interval_ms))
    local timeout


    if c.timeout_ms ~= nil then
        timeout = math.floor(num(c.timeout_ms, M.default_poll.timeout_ms))
    end
    local regs = c.regs
    if slave < 1 or slave > 247 then return nil, "bad slave" end
    if interval < 100 then return nil, "bad interval" end
    if timeout and (timeout < 50 or timeout > 500) then
        return nil, "响应上限越界(50~500ms)"
    end
    local out = inplace and c or {}
    if inplace then
        for k in pairs(c) do c[k] = nil end
    end
    out.baud, out.databits, out.stopbits, out.parity = baud, databits, stopbits, parity
    out.slave = slave
    out.interval_ms = interval
    out.timeout_ms = timeout
    local is_list = (type(regs) == "table")
    local dst = (inplace and is_list) and regs or {}
    local seen = {}
    local kept = 0
    if is_list then
        local cnt = #regs
        for i, r in ipairs(regs) do
            local nr, err = normalize_reg(r, inplace)
            if not nr then return nil, err end
            if kept > cfg.MAX_REGS then return nil, "too many regs" end



            if not seen[nr.addr] then
                seen[nr.addr] = true
                kept = kept + 1
                dst[kept] = nr
                if inplace and kept < i then regs[i] = nil end
            end
        end

        if inplace then
            for i = kept + 1, cnt do regs[i] = nil end
        end
    end
    out.regs = dst
    return out
end



local function normalize_infer_reg(r)
    if type(r) ~= "table" then return nil end
    local addr = num(r.addr, nil)
    if not addr or addr < 0 or addr > 65535 then return nil end
    local count = num(r.count, 1)
    if count < 1 or count > 125 then count = 1 end
    local fc = num(r.fc, 3)
    if fc ~= 3 and fc ~= 4 then fc = 3 end
    return {
        addr = math.floor(addr),
        count = math.floor(count),
        fc = math.floor(fc),
        dtype = str(r.dtype, "uint16"),
        name = str(r.name, ""),
        id = str(r.id, ""),
    }
end

function M.normalize_infer(c)
    c = c or {}
    local out = normalize_common(c, M.default_infer)
    out.slave = math.floor(num(c.slave, M.default_infer.slave))
    if out.slave < 1 or out.slave > 247 then return nil, "bad slave" end
    out.regs = {}
    local seen = {}
    local regs = c.regs
    if type(regs) == "table" then
        for _, r in ipairs(regs) do
            local nr = normalize_infer_reg(r)
            if nr then
                local key = nr.addr
                if not seen[key] then
                    seen[key] = true
                    out.regs[#out.regs + 1] = nr
                    if #out.regs > MAX_ALIAS then break end
                end
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
    infer = { key = K_INFER, norm = M.normalize_infer, default = M.default_infer },
}

for name, sec in pairs(SECTIONS) do
    M["load_" .. name] = function()
        local raw = load_json(sec.key, {})
        local ok, c, err = pcall(sec.norm, raw)
        if ok and c then return c end








        if not ok then
            log.error("cfg", name, "normalize raised:", brief(c))
            return sec.default, "内存/内部异常: " .. brief(c)
        end
        log.warn("cfg", name, "normalize fail, use default")
        return sec.default, tostring(err)
    end
    M["save_" .. name] = function(c)
        local n, err = sec.norm(c)
        if not n then return false, err end
        return save_json(sec.key, n)
    end




    M["save_" .. name .. "_norm"] = function(n)
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


function M.has_infer_cfg()
    if M.infer_src() ~= "fskv" then return false end
    local c = M.load_infer()
    return c and #(c.regs or {}) > 0
end


function M.infer_src()
    if not fskv then return "default" end
    local v = fskv.get(K_INFER)
    if v == nil or v == "" then return "default" end
    return "fskv"
end


















local RESET_SLOTS = {
    { "manual 配置", K_POLL },
    { "platform 配置", K_PULL },
    { "sniff 推断表", K_INFER },  -- 2026-11: 切 idle 时一起清
}

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




function M.clear_infer()
    if not fskv then return false, "fskv 不可用", false end
    local ok, v = pcall(fskv.get, K_INFER)
    if not ok then return false, "读 ds_infer 失败: " .. tostring(v), false end
    if v == nil or v == "" then return true, nil, false end
    fskv.set(K_INFER, "")
    json_cache[K_INFER] = nil
    cfg_ver = cfg_ver + 1
    if fskv.save then pcall(fskv.save) end
    return true, nil, true
end




function M.clear_poll()
    if not fskv then return false, "fskv 不可用", false end
    local ok, v = pcall(fskv.get, K_POLL)
    if not ok then return false, "读 ds_poll 失败: " .. tostring(v), false end
    if v == nil or v == "" then return true, nil, false end
    fskv.set(K_POLL, "")
    json_cache[K_POLL] = nil
    cfg_ver = cfg_ver + 1
    if fskv.save then pcall(fskv.save) end
    return true, nil, true
end

return M
