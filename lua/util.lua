-- util: 公共 helper. 合并 core/corelib + core/app_log + util/collect_table_util
-- + iot/iot.lua 内的 jstr/jnum/pad/int_str/ms_of.
-- 命名空间: util.get / util.try / util.log / util.jstr / util.jnum /
--          util.ms_of / util.pad / util.int_str / util.validate_reg

local M = {}

local function is_lib(m)
    local t = type(m)
    return t == "table" or t == "userdata"
end

function M.get(name)
    local m = _G[name]
    if is_lib(m) then return m end
    local ok, mod = pcall(require, name)
    if ok and is_lib(mod) then return mod end
    error("util: library not available -> " .. tostring(name), 2)
end

function M.try(name)
    local ok, m = pcall(M.get, name)
    if ok and is_lib(m) then return m end
    return nil
end

-- 推断展开的 qty 上限 (2026-10, 防 OOM 崩溃)
--   请求帧里的 qty 是 2 字节, 最大 0xFFFF=65535, 跟从机实际回了多少字节无关。
--   旁听推断按 qty 逐个展开成寄存器行, 一个 qty=0xFFFF 的异常帧就会展开
--   6 万多项 → 每项一个表 + 一个字符串 key → 几十 MB → Lua 堆(203K)爆:
--   "not enough memory for buffer allocation" → VM 退出 → 设备重启。
--   现场表现: 跑着跑着莫名重启, 重启后又好了(偶发, 看总线上什么时候冒出
--   异常 qty 的帧)。Modbus 规范 FC03/FC04 一次最多读 125 个寄存器(0x7D),
--   取 256 留余量。
M.MAX_INFER_QTY = 256

-- 把请求里的 qty 收敛到合法范围: 非数字/负数 → 0; 超过上限 → 截到上限
-- (返回截断后的值; 调用方想知道被截过可以自己比原值)
function M.clamp_qty(qty)
    if type(qty) ~= "number" then return 0 end
    if qty < 0 then return 0 end
    if qty > M.MAX_INFER_QTY then return M.MAX_INFER_QTY end
    return qty
end

-- 日志 fallback. _G.log 不可用时降级 print
local fallback
local function log_fallback()
    if fallback then return fallback end
    local mk = function(tag)
        return function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
            print("[" .. tag .. "]", table.concat(parts, " "))
        end
    end
    fallback = { debug = mk("D"), info = mk("I"), warn = mk("W"), error = mk("E") }
    return fallback
end

function M.log()
    local m = _G.log
    if is_lib(m) and type(m.info) == "function" and type(m.debug) == "function" then return m end
    if is_lib(m) and type(m.info) == "function" then
        return {
            debug = function() end,
            info = m.info,
            warn = type(m.warn) == "function" and m.warn or m.info,
            error = type(m.error) == "function" and m.error or m.info,
        }
    end
    return log_fallback()
end

-- 数字/时间 helper
function M.pad(v, n)
    local s = tostring(v)
    while #s < n do s = "0" .. s end
    return s
end

function M.int_str(v)
    v = math.floor(v)
    if v < 1e9 then return tostring(v) end
    local high = math.floor(v / 1000000000)
    local low = v - high * 1000000000
    return tostring(high) .. M.pad(low, 9)
end

function M.ms_of(ts)
    if type(ts) ~= "number" or ts ~= ts or ts < 0 then return "0" end
    local sec = math.floor(ts)
    local ksec = math.floor(sec / 1000)
    local rsec = sec - ksec * 1000
    local tail = rsec * 1000
    if ksec <= 0 then return tostring(tail) end
    return tostring(ksec) .. M.pad(tail, 6)
end

-- JSON helper
function M.jstr(s)
    s = tostring(s)
    return '"' .. (s:gsub('[%c"\\]', function(c)
        local b = c:byte()
        if c == '"' then return '\\"'
        elseif c == "\\" then return "\\\\"
        else return string.format("\\u%04x", b) end
    end)) .. '"'
end

function M.jnum(v)
    if type(v) ~= "number" then return nil end
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    if v == math.floor(v) and math.abs(v) < 1e15 then return M.int_str(v) end
    return tostring(v)
end

-- 采集表校验. 错误消息保持英文短词以兼容前端翻译表
local DTYPE_OK = {
    uint16 = 1, int16 = 1, uint32 = 1, int32 = 1,
    float32 = 1, uint64 = 1, int64 = 1, float64 = 1,
}

function M.validate_reg(r)
    if type(r) ~= "table" then return false, "not table" end
    local addr = tonumber(r.addr)
    if not addr or addr < 0 or addr > 65535 then return false, "bad addr" end
    local count = tonumber(r.count) or 1
    if count < 1 or count > 125 then return false, "bad count" end
    if not DTYPE_OK[r.dtype] then return false, "bad dtype" end
    local name = r.name
    if type(name) ~= "string" or #name == 0
        or #name > 16 or not name:match("^%w+$") then
        return false, "bad name"
    end
    return true
end

return M
