local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local fskv = corelib.get("fskv")
local sys = corelib.try("sys")

local M = {}

M.STATE = { EMPTY = "empty", INVALID = "invalid", READY = "ready" }

local K_SN, K_LOCK, K_BURN, K_BTIME = "dev_sn", "dev_sn_lock", "dev_sn_burn", "dev_sn_btime"

local state, sn_cache = M.STATE.EMPTY, nil
local changeCbs = {}

local function kv_get(k)
    local ok, v = pcall(fskv.get, k)
    if ok and v ~= nil and v ~= "" then return v end
    return nil
end

local function flush() pcall(fskv.save) end

function M.locked()
    return kv_get(K_LOCK) == "1"
end

function M.meta()
    return { burn = tonumber(kv_get(K_BURN)) or 0, btime = tonumber(kv_get(K_BTIME)) or 0 }
end

function M.load()
    return kv_get(K_SN)
end

function M.save(sn)
    fskv.set(K_SN, sn)
    local m = M.meta()
    fskv.set(K_BURN, m.burn + 1)
    if m.btime == 0 then fskv.set(K_BTIME, os.time()) end
    flush()
end

function M.erase()
    pcall(fskv.del, K_SN)
    flush()
end

function M.set_lock()
    fskv.set(K_LOCK, "1")
    flush()
end

function M.clear_lock()
    pcall(fskv.del, K_LOCK)
    flush()
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

function M.validate(sn)
    if type(sn) ~= "string" then return false, "not string" end
    if #sn < cfg.SN_MIN_LEN or #sn > cfg.SN_MAX_LEN then return false, "bad length" end
    if not sn:match("^%w+$") then return false, "bad char" end
    if sn:match("^%d+$") and not luhn_verify(sn) then return false, "luhn fail" end
    return true
end

local function notify(sn, st)
    for _, cb in ipairs(changeCbs) do pcall(cb, sn, st) end
end

function M.on_change(cb) changeCbs[#changeCbs + 1] = cb end

function M.state() return state end

function M.report_status()
    return state == M.STATE.READY and "normal" or "unset"
end

function M.init()
    if fskv.init then pcall(fskv.init) end
    local sn = M.load()
    if not sn or sn == "" then
        state = M.STATE.EMPTY
        log.warn("sn", "empty, burn via W:SN=")
    else
        local ok, err = M.validate(sn)
        if ok then
            state, sn_cache = M.STATE.READY, sn
        else
            state = M.STATE.INVALID
            log.error("sn", "invalid:", sn, tostring(err))
        end
    end
    _G.get_device_sn = function() return sn_cache end
    return true
end

function M.write(new_sn, opts)
    opts = opts or {}
    if M.locked() and state ~= M.STATE.INVALID then return false, "locked" end
    local ok, err = M.validate(new_sn)
    if not ok then return false, err end
    if state == M.STATE.READY then
        if new_sn == sn_cache then return true, "same" end
        if not opts.force then return false, "sn exists" end
    end
    M.save(new_sn)
    if M.load() ~= new_sn then return false, "verify fail" end
    sn_cache, state = new_sn, M.STATE.READY
    log.info("sn", "burned, burn=" .. M.meta().burn)
    notify(new_sn, state)
    return true
end

function M.clear()
    if M.locked() then return false, "locked" end
    M.erase()
    sn_cache, state = nil, M.STATE.EMPTY
    notify(nil, state)
    return true
end

function M.start_warn_monitor(period)
    if not sys then return end
    sys.timerLoopStart(function()
        if state ~= M.STATE.READY then
            log.warn("sn", "no sn! burn via W:SN=xxx")
        end
    end, (period or cfg.SN_WARN_PERIOD_S) * 1000)
end

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

local imei_cache, uid_cache = nil, nil

local function try_identity()
    local mobile = corelib.try("mobile")
    local mcu = corelib.try("mcu")
    if not imei_cache then imei_cache = grab(mobile, "imei") end
    if not uid_cache then uid_cache = grab(mcu, "unique_id") end
    return imei_cache and uid_cache
end

function M.imei() return imei_cache end
function M.chip_uid() return uid_cache end

function M.identity_init()
    try_identity()
    if not sys then return end
    sys.taskInit(function()
        for _ = 1, 60 do
            if try_identity() then return end
            sys.wait(500)
        end
        log.warn("sn", "identity timeout, imei/uid may be empty")
    end)
end

function M.info_line()
    return string.format("imei:%s;uid:%s;sn:%s;state:%s;lock:%d",
        tostring(imei_cache), tostring(uid_cache),
        tostring(sn_cache), state, M.locked() and 1 or 0)
end

return M
