local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local fskv = corelib.try("fskv")
local json = corelib.try("json")

local M = {}

local K_POLL, K_SNIFF, K_SYS = "ds_poll", "ds_sniff", "ds_sys"

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
    if #s > 512 then return false, "too large" end
    return kv_set(k, s)
end

M.default_poll = {
    baud = cfg.BAUD,
    databits = cfg.DATABITS,
    stopbits = cfg.STOPBITS,
    parity = cfg.PARITY,
    slave = cfg.SLAVE_ADDR,
    interval_ms = cfg.POLL_INTERVAL_MS,
    timeout = cfg.TIMEOUT_MS,
    regs = cfg.REG_DEFAULT,
}

M.default_sniff = {
    baud = cfg.BAUD,
    databits = cfg.DATABITS,
    stopbits = cfg.STOPBITS,
    parity = cfg.PARITY,
}

M.default_sys = { boot_mode = "idle" }

local function normalize_reg(r)
    if type(r) ~= "table" then return nil, "not table" end
    local addr = num(r.addr)
    if not addr or addr < 0 or addr > 65535 then return nil, "bad addr" end
    local count = num(r.count, 1)
    if count < 1 or count > 125 then return nil, "bad count" end
    local dtype = str(r.dtype, "uint16")
    if not ({ uint16 = 1, int16 = 1, uint32 = 1, int32 = 1, float32 = 1, uint64 = 1, int64 = 1, float64 = 1 })[dtype] then
        return nil, "bad dtype"
    end
    local name = str(r.name)
    if not name or #name > 16 or not name:match("^%w+$") then return nil, "bad name" end
    local bo = str(r.byteOrder, "BE")
    local wo = str(r.wordOrder, "BE")
    if bo ~= "BE" and bo ~= "LE" then return nil, "bad byteOrder" end
    if wo ~= "BE" and wo ~= "LE" then return nil, "bad wordOrder" end
    local eps = num(r.eps, 0)
    if eps < 0 then return nil, "bad eps" end
    return {
        addr = addr, count = count, dtype = dtype, name = name,
        alias = str(r.alias, name), byteOrder = bo, wordOrder = wo, eps = eps,
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
    out.timeout = math.floor(num(c.timeout, M.default_poll.timeout))
    if out.timeout < 50 or out.timeout > 10000 then return nil, "bad timeout" end
    out.regs = {}
    local regs = c.regs
    if type(regs) == "table" then
        for _, r in ipairs(regs) do
            local nr, err = normalize_reg(r)
            if not nr then return nil, err end
            out.regs[#out.regs + 1] = nr
        end
    end
    return out
end

function M.normalize_sniff(c)
    return normalize_common(c, M.default_sniff)
end

function M.normalize_sys(c)
    c = c or {}
    local mode = str(c.boot_mode, "idle"):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if mode ~= "idle" and mode ~= "poll" and mode ~= "sniff" then return nil, "bad boot_mode" end
    return { boot_mode = mode }
end

function M.load_poll()
    local raw = load_json(K_POLL, {})
    local ok, c = pcall(M.normalize_poll, raw)
    if not ok or not c then
        log.warn("cfg", "poll normalize fail, use default")
        return M.default_poll
    end
    return c
end

function M.load_sniff()
    local raw = load_json(K_SNIFF, {})
    local ok, c = pcall(M.normalize_sniff, raw)
    if not ok or not c then return M.default_sniff end
    return c
end

function M.load_sys()
    local raw = load_json(K_SYS, {})
    local ok, c = pcall(M.normalize_sys, raw)
    if not ok or not c then return M.default_sys end
    return c
end

function M.save_poll(c)
    local n, err = M.normalize_poll(c)
    if not n then return false, err end
    return save_json(K_POLL, n)
end

function M.save_sniff(c)
    local n, err = M.normalize_sniff(c)
    if not n then return false, err end
    return save_json(K_SNIFF, n)
end

function M.save_sys(c)
    local n, err = M.normalize_sys(c)
    if not n then return false, err end
    return save_json(K_SYS, n)
end

function M.effective_timeout()
    return M.load_poll().timeout or cfg.TIMEOUT_MS
end

function M.reset()
    for _, k in ipairs({ K_POLL, K_SNIFF, K_SYS }) do
        if fskv then
            pcall(fskv.del, k)
            if fskv.save then pcall(fskv.save) end
        end
    end
end

return M
