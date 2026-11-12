



local M = {}


function M.imei(mobile)
if not mobile then return "" end
local f = mobile.imei
if type(f) ~= "function" then return "" end
local ok, v = pcall(f)
return ok and tostring(v) or ""
end



function M.mcall(mobile, k)
if not mobile then return nil end
local f = mobile[k]
if type(f) ~= "function" then return nil end
local ok, v = pcall(f)
return ok and v or nil
end


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

return M
