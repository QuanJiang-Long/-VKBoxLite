local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local sys = corelib.get("sys")
local fskv = corelib.try("fskv")
local json = corelib.try("json")

local M = {}

local rounds, cur, round_seq = {}, nil, 0
local lastVal, pending = {}, 0
local enable = cfg.STORE_ENABLE
local stats = { pushed = 0, saved = 0, dropped = 0, filtered = 0, failed = 0 }

local function num_or(v, d)
    if v == nil then return d end
    local n = tonumber(v)
    return n or d
end

local function encode_rec(rec)
    if json then
        local ok, s = pcall(json.encode, rec)
        if ok and s then return s end
    end
    local parts = {}
    for k, v in pairs(rec) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    return table.concat(parts, ";")
end

local function decode_line(line)
    if json then
        local ok, t = pcall(json.decode, line)
        if ok and type(t) == "table" then return t end
    end
    local rec = {}
    for kv in line:gmatch("[^;]+") do
        local k, v = kv:match("^([^=]+)=(.*)$")
        if k then rec[k] = v end
    end
    return rec
end

local function keep_rounds()
    while #rounds > cfg.KEEP_ROUNDS do
        table.remove(rounds, 1)
        stats.dropped = stats.dropped + 1
    end
end

function M.begin_round()
    if cur and #cur.recs > 0 then rounds[#rounds + 1] = cur end
    keep_rounds()
    round_seq = round_seq + 1
    cur = { r = round_seq, ts = os.time(), recs = {} }
    return round_seq
end

local function changed(rec)
    if rec.kind == "frame" then return true end
    if rec.value == nil then return false end
    local eps = rec.eps or cfg.CHANGE_EPS or 0
    if eps <= 0 then return true end
    local last = lastVal[rec.alias]
    if last == nil then
        lastVal[rec.alias] = rec.value
        return true
    end
    if math.abs(rec.value - last) >= eps then
        lastVal[rec.alias] = rec.value
        return true
    end
    return false
end

function M.push(rec)
    if not enable then return false end
    stats.pushed = stats.pushed + 1
    if not cur then M.begin_round() end
    if not changed(rec) then
        stats.filtered = stats.filtered + 1
        return false
    end
    rec.r = cur.r
    cur.recs[#cur.recs + 1] = rec
    pending = pending + 1
    while #cur.recs > cfg.FLUSH_BATCH do
        table.remove(cur.recs, 1)
        stats.dropped = stats.dropped + 1
    end
    if pending >= cfg.FLUSH_EVERY then M.flush() end
    return true
end

function M.flush()
    local all = {}
    for _, rd in ipairs(rounds) do
        for _, rec in ipairs(rd.recs) do all[#all + 1] = encode_rec(rec) end
    end
    if cur then
        for _, rec in ipairs(cur.recs) do all[#all + 1] = encode_rec(rec) end
    end
    local ok, f = pcall(io.open, cfg.DATA_FILE, "w")
    if not ok or not f then
        stats.failed = stats.failed + 1
        return 0
    end
    local wok, werr = pcall(function()
        f:write(table.concat(all, "\n"))
        f:close()
    end)
    if not wok then
        stats.failed = stats.failed + 1
        return 0
    end
    stats.saved = stats.saved + #all
    pending = 0
    return #all
end

local function load_file()
    local ok, f = pcall(io.open, cfg.DATA_FILE, "r")
    if not ok or not f then return end
    local rok, data = pcall(function() return f:read("*a") end)
    pcall(f.close, f)
    if not rok or not data then return end
    for line in data:gmatch("[^\n]+") do
        local rec = decode_line(line)
        local r = num_or(rec.r)
        if not cur or cur.r ~= r then
            if cur and #cur.recs > 0 then rounds[#rounds + 1] = cur end
            keep_rounds()
            cur = { r = r, ts = num_or(rec.ts, os.time()), recs = {} }
            if r > round_seq then round_seq = r end
        end
        cur.recs[#cur.recs + 1] = rec
        if rec.alias and rec.value ~= nil then lastVal[rec.alias] = rec.value end
    end
    if cur and #cur.recs > 0 then rounds[#rounds + 1] = cur end
    keep_rounds()
    cur = nil
end

function M.depth()
    local n = cur and #cur.recs or 0
    for _, rd in ipairs(rounds) do n = n + #rd.recs end
    return n
end

function M.stats()
    local st = {}
    for k, v in pairs(stats) do st[k] = v end
    st.enable = enable
    st.rounds = #rounds
    return st
end

function M.set_enable(on, persist)
    enable = on and true or false
    if persist and fskv then
        fskv.set("ds_enable", enable and "1" or "0")
        if fskv.save then pcall(fskv.save) end
    end
    return true
end

function M.clear()
    rounds, cur, round_seq = {}, nil, 0
    lastVal, pending = {}, 0
    stats = { pushed = 0, saved = 0, dropped = 0, filtered = 0, failed = 0 }
    pcall(os.remove, cfg.DATA_FILE)
end

function M.init()
    if fskv then
        if fskv.init then pcall(fskv.init) end
        local v = fskv.get("ds_enable")
        if v ~= nil then enable = (v == "1" or v == 1) end
        local b = fskv.get("ds_boots")
        b = num_or(b, 0) + 1
        fskv.set("ds_boots", b)
        if fskv.save then pcall(fskv.save) end
    end
    load_file()
    if M.depth() > 0 then M.flush() end
    sys.timerLoopStart(function()
        if pending > 0 then M.flush() end
    end, cfg.FLUSH_MS)
    return true
end

return M
