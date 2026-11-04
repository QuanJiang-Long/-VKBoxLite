local util = require "util"
local cfg = require "core/config"
local log = util.log()

local fskv = util.get("fskv")
local sys = util.try("sys")

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

local function flush()
    if fskv and fskv.save then pcall(fskv.save) end
end

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

-- notify 必须定义在 clear/write 之前: 两者都要调它, local 是词法作用域,
-- 声明在后会变成全局查找拿不到 changeCbs, 烧号后主程序补启 MQTT 就失效
local function notify(sn, st)
    for _, cb in ipairs(changeCbs) do pcall(cb, sn, st) end
end

-- erase 已内联: 清号就是删 fskv 里的 SN 键, 单次调用不值得单开一个导出函数
function M.clear()
    -- 已锁但当前是 INVALID(非法号)时允许清: 否则返工必须先 UNLOCK 再 C,
    -- 产线多一步操作(与原工程一致)
    if M.locked() and state ~= M.STATE.INVALID then return false, "locked" end
    pcall(fskv.del, K_SN)
    flush()
    sn_cache, state = nil, M.STATE.EMPTY
    notify(nil, state)
    return true
end

function M.set_lock()
    fskv.set(K_LOCK, "1")
    flush()
end

function M.clear_lock()
    pcall(fskv.del, K_LOCK)
    flush()
end

-- 格式 VL+YYYYMMDD+NNN。日期范围 2000-2099, 月 01-12, 日 01-31。
-- 13 位时日期 8 位 + 流水 3 位; 14-32 位留给扩展(流水超 999 / 字母段)。
-- 日期段超出位置(月份/日 非数字 或 范围非法)直接拒, 省得产线烧个
-- "VL2026A009010" 设备读起来静默用错日期
function M.validate(sn)
    if type(sn) ~= "string" then return false, "not string" end
    if #sn < cfg.SN_MIN_LEN or #sn > cfg.SN_MAX_LEN then return false, "bad length" end
    if sn:sub(1, #cfg.SN_PREFIX) ~= cfg.SN_PREFIX then return false, "bad prefix" end
    -- 日期段: VL 之后 8 位必须全数字, 年 2000-2099, 月 01-12, 日 01-31
    local d = sn:sub(#cfg.SN_PREFIX + 1, #cfg.SN_PREFIX + 8)
    if not d:match("^%d+$") then return false, "bad date" end
    local yr = tonumber(d:sub(1, 4))
    local mo = tonumber(d:sub(5, 6))
    local dy = tonumber(d:sub(7, 8))
    if yr < 2000 or yr > 2099 then return false, "bad year" end
    if mo < 1 or mo > 12 then return false, "bad month" end
    if dy < 1 or dy > 31 then return false, "bad day" end
    if not sn:match("^%w+$") then return false, "bad char" end
    return true
end

function M.on_change(cb) changeCbs[#changeCbs + 1] = cb end

function M.state() return state end

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
    local mobile = util.try("mobile")
    local mcu = util.try("mcu")
    if not imei_cache then imei_cache = grab(mobile, "imei") end
    if not uid_cache then uid_cache = grab(mcu, "unique_id") end
    return imei_cache and uid_cache
end

function M.imei() return imei_cache end
function M.uid() return uid_cache end

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
        imei_cache or "", uid_cache or "",
        sn_cache or "", state, M.locked() and 1 or 0)
end

return M
