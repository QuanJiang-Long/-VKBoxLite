





















local M = {}

local jstr = require("util/mqtt_util").jstr







function M.prop(id, name, dtype, slave, addr, count)
    return string.format(
        '{"id":%s,"name":%s,"dataType":%s,"unit":"","modbus":{"slave":%d,"address":%d,"quantity":%d,"dataType":%s}}',
        jstr(id), jstr(name), jstr(dtype), slave, addr, count, jstr(dtype))
end




function M.node_parts(out, idx, slave, serial_json, tsl_name, props)
    out[#out + 1] = '{"nodeIndex":' .. idx .. ',"slaveId":' .. slave ..
        ',"kind":"RTU","serial":' .. serial_json ..
        ',"model":{"tslName":' .. jstr(tsl_name) .. ',"properties":['
    for i = 1, #props do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = props[i]
    end
    out[#out + 1] = ']}}'
end


function M.len(parts)
    local n = 0
    for i = 1, #parts do n = n + #parts[i] end
    return n
end










function M.sig(parts)




    local h = 0
    local MOD = 2147483647
    for i = 1, #parts do
        local s = parts[i]
        local n = #s
        for j = 1, n do
            h = (h * 131 + s:byte(j)) % MOD
        end
    end


    return tostring(#parts) .. ":" .. tostring(h)
end

return M
