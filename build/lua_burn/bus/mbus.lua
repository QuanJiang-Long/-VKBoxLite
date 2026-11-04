local util = require "util"
local uart = util.try("uart")

local M = {}

M.UART_ID = 1
M.DE_PIN = 8

local CRC_TABLE = {}
do
    local poly = 0xA001
    for i = 0, 255 do
        local crc = i
        for _ = 1, 8 do
            if crc % 2 == 1 then
                crc = (crc // 2) ~ poly
            else
                crc = crc // 2
            end
        end
        CRC_TABLE[i] = crc
    end
end

function M.crc16(s)
    local crc = 0xFFFF
    for i = 1, #s do
        local b = s:byte(i)
        crc = (crc // 256) ~ CRC_TABLE[(crc % 256) ~ b]
    end
    return crc
end

function M.append_crc(s)
    local crc = M.crc16(s)
    return s .. string.char(crc % 256, crc // 256)
end

function M.crc_ok(s)
    if #s < 3 then return false end
    local body = s:sub(1, -3)
    return M.crc16(body) == s:byte(-2) + s:byte(-1) * 256
end




local function crc_at(buf, blen)
    return M.crc16(buf:sub(1, blen)) == buf:byte(blen + 1) + buf:byte(blen + 2) * 256
end

local function be16(v) return string.char(v // 256 % 256, v % 256) end

function M.build_read(slave, addr, qty)
    if slave < 1 or slave > 247 then return nil, "bad slave" end
    if addr < 0 or addr > 65535 then return nil, "bad addr" end
    if qty < 1 or qty > 125 then return nil, "bad qty" end
    return M.append_crc(string.char(slave, 3, addr // 256 % 256, addr % 256, qty // 256 % 256, qty % 256))
end

function M.build_write_single(slave, addr, value)
    if slave < 1 or slave > 247 then return nil, "bad slave" end
    if addr < 0 or addr > 65535 then return nil, "bad addr" end
    if value < 0 or value > 65535 then return nil, "bad value" end
    return M.append_crc(string.char(slave, 6, addr // 256 % 256, addr % 256, value // 256 % 256, value % 256))
end

function M.build_write_multi(slave, addr, values)
    if slave < 1 or slave > 247 then return nil, "bad slave" end
    if addr < 0 or addr > 65535 then return nil, "bad addr" end
    local n = #values
    if n < 1 or n > 123 then return nil, "bad count" end


    local body = string.char(slave, 16,
        addr // 256 % 256, addr % 256,
        n // 256 % 256, n % 256,
        n * 2 % 256)
    for i = 1, n do
        local v = values[i] % 65536
        body = body .. be16(v)
    end
    return M.append_crc(body)
end






function M.parse_frame(s, f)
    if #s < 4 then return nil end
    if not M.crc_ok(s) then return nil end
    f = f or {}
    local slave, fc = s:byte(1), s:byte(2)
    if fc >= 0x80 then
        if #s ~= 5 then return nil end
        f.slave, f.fc, f.err, f.raw = slave, fc - 0x80, s:byte(3), s
        return f
    end
    if fc == 3 or fc == 4 then
        if #s < 5 then return nil end
        local bc = s:byte(3)

        if #s ~= 5 + bc then return nil end
        f.slave, f.fc, f.data, f.raw = slave, fc, s:sub(4, 3 + bc), s
        return f
    end
    if fc == 6 then
        if #s ~= 8 then return nil end
        f.slave, f.fc = slave, fc
        f.addr = s:byte(3) * 256 + s:byte(4)
        f.value = s:byte(5) * 256 + s:byte(6)
        f.raw = s
        return f
    end
    if fc == 16 then
        if #s ~= 8 then return nil end
        f.slave, f.fc = slave, fc
        f.addr = s:byte(3) * 256 + s:byte(4)
        f.qty = s:byte(5) * 256 + s:byte(6)
        f.raw = s
        return f
    end
    if fc == 1 or fc == 2 then
        if #s < 5 then return nil end
        local bc = s:byte(3)
        if #s ~= 5 + bc then return nil end
        f.slave, f.fc, f.data, f.raw = slave, fc, s:sub(4, 3 + bc), s
        return f
    end
    if fc == 5 or fc == 15 then
        if #s ~= 8 then return nil end
        f.slave, f.fc = slave, fc
        f.addr = s:byte(3) * 256 + s:byte(4)
        f.value = s:byte(5) * 256 + s:byte(6)
        f.raw = s
        return f
    end
    return nil
end

M.TYPE_WIDTH = {
    uint16 = 1, int16 = 1,
    uint32 = 2, int32 = 2, float32 = 2,
    uint64 = 4, int64 = 4, float64 = 4,
}



















local function bytes_to_float(b1, b2, b3, b4, b5, b6, b7, b8, is_double)
    if is_double then
        local sign = math.floor(b1 / 128)
        local e = math.floor(b1 % 128) * 16 + math.floor(b2 / 16)

        local m = b2 % 16
        m = m * 256 + b3
        m = m * 256 + b4
        m = m * 256 + b5
        m = m * 256 + b6
        m = m * 256 + b7
        m = m * 256 + b8
        if e == 2047 then return nil end
        if e == 0 then
            if m == 0 then return 0.0 end
            return (sign == 1 and -1 or 1) * m * 2^(1 - 1023 - 52)
        end
        return (sign == 1 and -1 or 1) * (2^52 + m) * 2^(e - 1023 - 52)
    end
    local sign = math.floor(b1 / 128)
    local e = math.floor(b1 % 128) * 2 + math.floor(b2 / 128)
    local m = math.floor(b2 % 128) * 65536 + b3 * 256 + b4
    if e == 255 then return nil end
    if e == 0 then
        if m == 0 then return 0.0 end
        return (sign == 1 and -1 or 1) * m * 2^(1 - 127 - 23)
    end
    return (sign == 1 and -1 or 1) * (2^23 + m) * 2^(e - 127 - 23)
end

local function bytes_to_u64(b1, b2, b3, b4, b5, b6, b7, b8)
    local v = b1
    v = v * 256 + b2
    v = v * 256 + b3
    v = v * 256 + b4
    v = v * 256 + b5
    v = v * 256 + b6
    v = v * 256 + b7
    v = v * 256 + b8
    return v
end

local function bytes_to_i64(b1, b2, b3, b4, b5, b6, b7, b8)
    local v = bytes_to_u64(b1, b2, b3, b4, b5, b6, b7, b8)
    if b1 >= 128 then v = v - 18446744073709551616.0 end
    return v
end



function M.parse_value(data, offset, dtype, word_swap)
    local w = M.TYPE_WIDTH[dtype]
    if not w then return nil, "bad dtype" end
    local nbytes = w * 2
    local p = offset * 2
    if p + nbytes > #data then return nil, "short data" end

    local b1, b2, b3, b4, b5, b6, b7, b8 = data:byte(p + 1, p + 8)

    if word_swap and w == 2 then
        b1, b2, b3, b4 = b3, b4, b1, b2
    end
    if dtype == "float32" then
        return bytes_to_float(b1, b2, b3, b4, b5, b6, b7, b8, false)
    elseif dtype == "float64" then
        return bytes_to_float(b1, b2, b3, b4, b5, b6, b7, b8, true)
    elseif dtype == "uint16" then
        return b1 * 256 + b2
    elseif dtype == "int16" then
        local v = b1 * 256 + b2
        return v >= 32768 and v - 65536 or v
    elseif dtype == "uint32" then
        return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    elseif dtype == "int32" then
        local v = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        return v >= 2147483648 and v - 4294967296 or v
    elseif dtype == "uint64" then
        return bytes_to_u64(b1, b2, b3, b4, b5, b6, b7, b8)
    elseif dtype == "int64" then
        return bytes_to_i64(b1, b2, b3, b4, b5, b6, b7, b8)
    end
    return nil, "bad dtype"
end


function M.parse_regs(data, dtype)
    local w = M.TYPE_WIDTH[dtype]
    if not w then return nil, "bad dtype" end
    local out, hex = {}, {}
    local n = #data // 2
    for off = 0, n - w, w do
        local v = M.parse_value(data, off, dtype)
        if v == nil then break end
        out[#out + 1] = v
    end
    for i = 1, #data do hex[#hex + 1] = string.format("%02x", data:byte(i)) end
    return out, table.concat(hex)
end










function M.calc_de_hold_ms(nbytes, baud)
    local bits = nbytes * (8 + 1 + 1)
    return math.ceil(bits * 1000 / baud) + 5
end



function M.try_extract_len(buf)
    if type(buf) ~= "string" or #buf < 5 then return nil end
    local fc = buf:byte(2)


    if fc >= 1 and fc <= 6 and #buf >= 8 then
        if crc_at(buf, 6) then return 8 end
    end

    if fc >= 1 and fc <= 4 and #buf >= 5 then
        local bc = buf:byte(3)
        if bc and bc >= 1 and bc <= 0xF4 then
            local total = bc + 5
            if #buf >= total then
                if crc_at(buf, 3 + bc) then return total end
            end
        end
    end


    if fc == 15 or fc == 16 then
        if #buf >= 8 and crc_at(buf, 6) then
            return 8
        end
        if #buf >= 9 then
            local bc = buf:byte(7)
            if bc and bc >= 1 and bc <= 246 then
                local total = 9 + bc
                if #buf >= total then
                    if crc_at(buf, 7 + bc) then return total end
                end
            end
        end
    end

    if fc >= 0x80 and #buf >= 5 then
        if crc_at(buf, 3) then return 5 end
    end
    return nil
end






local function hex_one(c) return string.format("%02x", c:byte()) end













local function sniff_req_frame(s, f)
    if #s ~= 8 then return nil end
    local fc = s:byte(2)
    if fc ~= 3 and fc ~= 4 then return nil end
    if not M.crc_ok(s) then return nil end
    f = f or {}
    f.slave, f.fc = s:byte(1), fc
    f.addr = s:byte(3) * 256 + s:byte(4)
    f.qty = s:byte(5) * 256 + s:byte(6)
    f.raw = s
    return f
end


function M.decode_frame(s, into)
    local f = M.parse_frame(s, into)
    if not f then f = sniff_req_frame(s, into) end
    if not f then
        f = into or {}
        f.kind = "other"
        f.hex = (s:gsub(".", hex_one))
        f.raw = s
        return f
    end
    f.hex = (s:gsub(".", hex_one))
    if f.err then
        f.kind = "err"
    elseif f.fc == 3 or f.fc == 4 then
        if f.data then f.kind = "rsp" else f.kind = "req" end
    elseif f.fc == 6 or f.fc == 16 then
        f.kind = "echo"
    else
        f.kind = "req"
    end







    if f.data and not f.qty then
        f.bc = #f.data
        f.qty = (f.fc == 3 or f.fc == 4) and math.floor(#f.data / 2) or (#f.data * 8)






        f.vhex = f.hex:sub(7, 6 + 2 * f.bc)
    end
    return f
end

function M.parity_to_uart(p)
    if not uart then return p == 1 and 1 or (p == 2 and 2 or 0) end
    if p == 1 then return uart.EVEN or uart.Even end
    if p == 2 then return uart.ODD or uart.Odd end
    return uart.NONE or uart.None
end

return M
