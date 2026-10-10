-- MQTT 上行 JSON / 字段构造工具。从 iot.lua 抽出:
--   - 大数拼串 (ms_of/int_str/pad) —— 防 32 位固件 ts*1000 回绕/科学计数法
--   - IMEI 取号 (imei/mcall) —— mobile 库不存在时返回空/nil, 不编假值
--   - JSON 字串/数值字段拼装 (jstr/jnum) —— 平台要求 ts=秒级整数
local M = {}

-- imei 取号。mobile 不存在/取失败一律空串, 不塞假值
function M.imei(mobile)
    if not mobile then return "" end
    local f = mobile.imei
    if type(f) ~= "function" then return "" end
    local ok, v = pcall(f)
    return ok and tostring(v) or ""
end

-- mobile.* 取号。全是无参函数, 塞引用不调用会让下游拿到函数体
-- 取不到返回 nil, 让调用方决定"留空"还是"整个字段不发"
function M.mcall(mobile, k)
    if not mobile then return nil end
    local f = mobile[k]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f)
    return ok and v or nil
end

-- 0 补齐。jnum/ms_of 共用
function M.pad(v, n)
    local s = tostring(v)
    while #s < n do s = "0" .. s end
    return s
end

-- 32 位整数转串。v<1e9 直接 tostring, 否则分两段拼避免大数科学计数法
function M.int_str(v)
    v = math.floor(v)
    if v < 1e9 then return tostring(v) end
    local high = math.floor(v / 1000000000)
    local low = v - high * 1000000000
    return tostring(high) .. M.pad(low, 9)
end

-- ts(秒) -> 13 位毫秒串。32 位固件上 ts*1000 会回绕, 用 split + pad 拼
function M.ms_of(ts)
    if type(ts) ~= "number" or ts ~= ts or ts < 0 then return "0" end
    local sec = math.floor(ts)
    local ksec = math.floor(sec / 1000)
    local rsec = sec - ksec * 1000
    local tail = rsec * 1000
    if ksec <= 0 then return tostring(tail) end
    return tostring(ksec) .. M.pad(tail, 6)
end

-- JSON 字符串字段: 转义 " \ 控制符
function M.jstr(s)
    s = tostring(s)
    return '"' .. (s:gsub('[%c"\\]', function(c)
        local b = c:byte()
        if c == '"' then return '\\"'
        elseif c == "\\" then return "\\\\"
        else return string.format("\\u%04x", b) end
    end)) .. '"'
end

-- JSON 数值字段: NaN/Inf 拒, 整数走 int_str 防科学计数法, 浮点 tostring
function M.jnum(v)
    if type(v) ~= "number" then return nil end
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    if v == math.floor(v) and math.abs(v) < 1e15 then return M.int_str(v) end
    return tostring(v)
end

return M
