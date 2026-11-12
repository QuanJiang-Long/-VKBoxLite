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








local function kv_read(k)
    if not fskv then return nil, nil end
    local ok, v = pcall(fskv.get, k)
    if not ok then return nil, "读不出来: " .. brief(v) end
    if v == nil or v == "" then return nil, nil end
    return v, nil
end

local function kv_get(k)
    return (kv_read(k))
end




local json_cache = {}   -- fskv key -> 解码后的原始表




local cfg_ver = 0

function M.version() return cfg_ver end







local FSKV_VALUE_MAX = 4096

local function kv_set(k, s, noflush)
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


    if fskv.save and not noflush then pcall(fskv.save) end
    return true
end










































local SHARD_ROWS = 16
local SHARD_MAX = 1024
local SHARD_VER = 1
local SHARD_W, SHARD_R = "w", "r"

local function shard_key(k, i) return k .. "." .. i end

local function dec_json(s)
    if not s or not json then return nil end
    local ok, t = pcall(json.decode, s)
    if ok and type(t) == "table" then return t end
    return nil
end



local function shard_of(h)
    if type(h) ~= "table" or h.v ~= SHARD_VER then return nil end
    local n = tonumber(h.n)
    if not n then return nil end
    return math.floor(n), tostring(h.st)
end



local function shards_load(k, t)
    local n, st = shard_of(t)
    if st ~= SHARD_R then
        return nil, "分片未提交(应有 " .. n .. " 段, st=" .. st .. ")"
    end
    if not fskv then return nil, "fskv 不可用, 段取不到" end
    local rows = {}
    for i = 1, n do



        local ok, cs = pcall(fskv.get, shard_key(k, i))
        if not ok then return nil, "分片" .. i .. "读不出来: " .. brief(cs) end
        if cs == nil or cs == "" then return nil, "分片不全(" .. (i - 1) .. "/" .. n .. ")" end
        local ct = dec_json(cs)
        if ct == nil then return nil, "分片" .. i .. "解码失败" end
        for j = 1, #ct do rows[#rows + 1] = ct[j] end
    end
    t.regs = rows
    return t
end

local function put_json(k, v, noflush)
    local ok, s = pcall(json.encode, v)
    if not ok then return false, "encode fail: " .. brief(s) end
    if not s then return false, "encode fail(无返回)" end
    if #s > FSKV_VALUE_MAX then
        return false, "段 " .. #s .. "B 超 fskv 单值上限 " .. FSKV_VALUE_MAX .. "B"
    end
    return kv_set(k, s, noflush)
end



local function shards_save(k, t)
    local rows = (type(t.regs) == "table") and t.regs or {}
    local segs, cur, cur_sz = {}, {}, 2
    local function close_seg()
        if #cur == 0 then return true end
        segs[#segs + 1] = cur
        cur, cur_sz = {}, 2
        return true
    end
    for i = 1, #rows do
        local ok, e = pcall(json.encode, rows[i])



        if not ok then return false, "encode fail: " .. brief(e) end
        if not e then return false, "encode fail(无返回)" end

        if #cur > 0 and (cur_sz + #e + 1 > SHARD_MAX or #cur >= SHARD_ROWS) then
            close_seg()
        end
        cur[#cur + 1] = rows[i]
        cur_sz = cur_sz + #e + (#cur > 1 and 1 or 0)
    end
    close_seg()

    local n = #segs
    local head = {}
    for key, val in pairs(t) do
        if key ~= "regs" then head[key] = val end
    end


    local old_n = 0
    local oh = dec_json(kv_get(k))
    if oh then
        local on = shard_of(oh)
        if on and on > 0 then old_n = on end
    end

    head.v, head.n, head.st = SHARD_VER, n, SHARD_W
    local ok1, err1 = put_json(k, head, true)
    if not ok1 then return false, err1 end
    for i = 1, n do
        local ok2, err2 = put_json(shard_key(k, i), segs[i], true)
        if not ok2 then
            return false, "分片" .. i .. "/" .. n .. "写入失败: " .. tostring(err2)
        end
    end
    head.st = SHARD_R
    local ok3, err3 = put_json(k, head) -- 提交: 只有这一次 flush
    if not ok3 then return false, "分片提交失败: " .. tostring(err3) end



    for i = n + 1, old_n do pcall(fskv.set, shard_key(k, i), "") end
    return true
end

local function load_json(k, default, shard)
    local cached = json_cache[k]
    if cached ~= nil then return cached end
    local s, rerr = kv_read(k)
    if rerr then


        return nil, rerr
    end
    if not s or not json then
        json_cache[k] = default
        return default
    end
    local t = dec_json(s)
    if t == nil then
        log.warn("cfg", "decode fail", k)
        json_cache[k] = default
        return default
    end






    local pok, c, perr = pcall(function()
        if not shard or not shard_of(t) then return t end
        return shards_load(k, t)
    end)
    if not pok then


        return nil, "内存/内部异常: " .. brief(c)
    end
    if c == nil then return nil, perr end
    json_cache[k] = c
    return c
end

local function save_json(k, t, shard)
    if not json then return false, "no json lib" end
    if shard then return shards_save(k, t) end
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
    poll = { key = K_POLL, norm = M.normalize_poll, default = M.default_poll, shard = true },
    pull = { key = K_PULL, norm = M.normalize_poll, default = M.default_poll, shard = true },
    sys = { key = K_SYS, norm = M.normalize_sys, default = M.default_sys },
    alias = { key = K_ALIAS, norm = M.normalize_alias, default = M.default_alias },
    infer = { key = K_INFER, norm = M.normalize_infer, default = M.default_infer, shard = true },
}

for name, sec in pairs(SECTIONS) do
    M["load_" .. name] = function()
        local raw, serr = load_json(sec.key, {}, sec.shard)
        if serr then





            log.error("cfg", name, "read fail:", brief(serr))
            return sec.default, brief(serr)
        end
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
        return save_json(sec.key, n, sec.shard)
    end




    M["save_" .. name .. "_norm"] = function(n)
        return save_json(sec.key, n, sec.shard)
    end
end







local function src_of(k)
    local v, why = kv_read(k)
    if why then return "read-fail", why end
    if not v then return "default" end
    return "fskv"
end


function M.poll_src() return (src_of(K_POLL)) end



function M.pull_src() return (src_of(K_PULL)) end


function M.infer_src() return (src_of(K_INFER)) end












function M.has_poll_cfg()
    local src, why = src_of(K_POLL)
    if src == "default" then return false end
    if src ~= "fskv" then return false, why end
    local c, w2 = M.load_poll()
    if w2 then return false, w2 end
    return c and #(c.regs or {}) > 0
end

function M.has_pull_cfg()
    local src, why = src_of(K_PULL)
    if src == "default" then return false end
    if src ~= "fskv" then return false, why end
    local c, w2 = M.load_pull()
    if w2 then return false, w2 end
    return c and #(c.regs or {}) > 0
end


function M.has_infer_cfg()
    local src, why = src_of(K_INFER)
    if src == "default" then return false end
    if src ~= "fskv" then return false, why end
    local c, w2 = M.load_infer()
    if w2 then return false, w2 end
    return c and #(c.regs or {}) > 0
end


local SHARDED = {}
for _, sec in pairs(SECTIONS) do SHARDED[sec.key] = sec.shard end













local function slot_clear(k, shard)
    local ok, v = pcall(fskv.get, k)
    if not ok then return false, "读不出来: " .. brief(v) end
    if v == nil or v == "" then return false, nil end
    local n = 0
    if shard then
        local h = dec_json(v)
        local hn = h and shard_of(h)
        if hn and hn > 0 then n = hn end
    end
    local sok, serr = pcall(fskv.set, k, "")
    if not sok then return false, "清不掉: " .. brief(serr) end
    json_cache[k] = nil   -- 12-fix-3: 绕过了 kv_set, 缓存要手动失效
    cfg_ver = cfg_ver + 1 -- 12-fix-9: 版本号也要涨(别名映射缓存靠它失效)
    for i = 1, n do
        pcall(fskv.set, shard_key(k, i), "")
        json_cache[shard_key(k, i)] = nil
    end
    return true
end


















local RESET_SLOTS = {
    { "manual 配置", K_POLL },
    { "platform 配置", K_PULL },
    { "sniff 推断表", K_INFER },  -- 2026-11: 切 idle 时一起清
}



function M.reset_user()
    local cleared, failed = {}, {}
    if not fskv then return cleared, failed end
    for _, s in ipairs(RESET_SLOTS) do
        local name, k = s[1], s[2]


        local wrote, why = slot_clear(k, SHARDED[k])
        if wrote then
            cleared[#cleared + 1] = name
        elseif why then
            failed[#failed + 1] = name .. ":" .. why
        end
    end
    if #cleared > 0 and fskv.save then pcall(fskv.save) end
    return cleared, failed
end





function M.clear_pull()
    if not fskv then return false, "fskv 不可用", false end
    local wrote, why = slot_clear(K_PULL, SHARDED[K_PULL])
    if why then return false, "清 ds_pull 失败: " .. why, false end
    if wrote and fskv.save then pcall(fskv.save) end
    return true, nil, wrote
end




function M.clear_infer()
    if not fskv then return false, "fskv 不可用", false end
    local wrote, why = slot_clear(K_INFER, SHARDED[K_INFER])
    if why then return false, "清 ds_infer 失败: " .. why, false end
    if wrote and fskv.save then pcall(fskv.save) end
    return true, nil, wrote
end




function M.clear_poll()
    if not fskv then return false, "fskv 不可用", false end
    local wrote, why = slot_clear(K_POLL, SHARDED[K_POLL])
    if why then return false, "清 ds_poll 失败: " .. why, false end
    if wrote and fskv.save then pcall(fskv.save) end
    return true, nil, wrote
end

return M
