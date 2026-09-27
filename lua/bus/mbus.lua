local corelib = require "core/corelib"
local log = corelib.log()
local uart = corelib.try("uart")

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
    local body = string.char(slave, 16, addr // 256 % 256, addr % 256, n, n * 2)
    for i = 1, n do
        local v = values[i] % 65536
        body = body .. be16(v)
    end
    return M.append_crc(body)
end

function M.parse_frame(s)
    if #s < 4 then return nil end
    if not M.crc_ok(s) then return nil end
    local slave, fc = s:byte(1), s:byte(2)
    if fc >= 0x80 then
        if #s ~= 5 then return nil end
        return { slave = slave, fc = fc - 0x80, err = s:byte(3), raw = s }
    end
    if fc == 3 or fc == 4 then
        if #s < 5 then return nil end
        local bc = s:byte(3)
        if #s ~= 4 + bc then return nil end
        return { slave = slave, fc = fc, data = s:sub(4, 3 + bc), raw = s }
    end
    if fc == 6 then
        if #s ~= 8 then return nil end
        return {
            slave = slave, fc = fc,
            addr = s:byte(3) * 256 + s:byte(4),
            value = s:byte(5) * 256 + s:byte(6),
            raw = s,
        }
    end
    if fc == 16 then
        if #s ~= 8 then return nil end
        return {
            slave = slave, fc = fc,
            addr = s:byte(3) * 256 + s:byte(4),
            qty = s:byte(5) * 256 + s:byte(6),
            raw = s,
        }
    end
    if fc == 1 or fc == 2 then
        if #s < 5 then return nil end
        local bc = s:byte(3)
        if #s ~= 4 + bc then return nil end
        return { slave = slave, fc = fc, data = s:sub(4, 3 + bc), raw = s }
    end
    if fc == 5 or fc == 15 then
        if #s ~= 8 then return nil end
        return {
            slave = slave, fc = fc,
            addr = s:byte(3) * 256 + s:byte(4),
            value = s:byte(5) * 256 + s:byte(6),
            raw = s,
        }
    end
    return nil
end

M.TYPE_WIDTH = {
    uint16 = 1, int16 = 1,
    uint32 = 2, int32 = 2, float32 = 2,
    uint64 = 4, int64 = 4, float64 = 4,
}

local function swap_pairs(b, byte_order)
    if byte_order == "LE" then
        local n = #b
        local out = {}
        for i = 1, n, 2 do
            out[i] = b:byte(i + 1)
            out[i + 1] = b:byte(i)
        end
        return out
    end
    local out = {}
    for i = 1, #b do out[i] = b:byte(i) end
    return out
end

local function bytes_to_float(b)
    local b1, b2, b3, b4 = b[1], b[2], b[3], b[4]
    local sign = b1 >= 128 and -1 or 1
    local exp = (b1 % 128) * 2 + (b2 >= 128 and 1 or 0)
    local mant = (b2 % 128) * 65536 + b3 * 256 + b4
    if exp == 0 and mant == 0 then return 0.0 end
    if exp == 255 then return mant == 0 and sign * math.huge or (0 / 0) end
    return sign * (1 + mant / 8388608.0) * 2.0 ^ (exp - 127)
end

local function to_u64(b)
    local v = 0
    for i = 1, #b do v = v * 256 + b[i] end
    return v
end

local function to_i64(b)
    local v = to_u64(b)
    if b[1] >= 128 then v = v - 18446744073709551616.0 end
    return v
end

function M.parse_value(data, offset, dtype, byte_order, word_order)
    local w = M.TYPE_WIDTH[dtype]
    if not w then return nil, "bad dtype" end
    local nbytes = w * 2
    local raw = data:sub(offset * 2 + 1, offset * 2 + nbytes)
    if #raw < nbytes then return nil, "short data" end
    local b = swap_pairs(raw, byte_order)
    if w > 1 and word_order == "LE" then
        local rev = {}
        for wi = w, 1, -1 do
            rev[#rev + 1] = b[(wi - 1) * 2 + 1]
            rev[#rev + 1] = b[(wi - 1) * 2 + 2]
        end
        b = rev
    end
    if dtype == "float32" then
        return bytes_to_float({ b[1], b[2], b[3], b[4] })
    elseif dtype == "float64" then
        return bytes_to_float({ b[1], b[2], b[3], b[4] }) * 4294967296.0 + bytes_to_float({ b[5], b[6], b[7], b[8] })
    elseif dtype == "uint16" then
        return b[1] * 256 + b[2]
    elseif dtype == "int16" then
        local v = b[1] * 256 + b[2]
        return v >= 32768 and v - 65536 or v
    elseif dtype == "uint32" then
        return b[1] * 16777216 + b[2] * 65536 + b[3] * 256 + b[4]
    elseif dtype == "int32" then
        local v = b[1] * 16777216 + b[2] * 65536 + b[3] * 256 + b[4]
        return v >= 2147483648 and v - 4294967296 or v
    elseif dtype == "uint64" then
        return to_u64(b)
    elseif dtype == "int64" then
        return to_i64(b)
    end
    return nil, "bad dtype"
end

function M.parse_regs(data, dtype, byte_order, word_order)
    local w = M.TYPE_WIDTH[dtype]
    if not w then return nil, "bad dtype" end
    local out, hex = {}, {}
    local n = #data // 2
    for off = 0, n - w, w do
        local v = M.parse_value(data, off, dtype, byte_order, word_order)
        if v == nil then break end
        out[#out + 1] = v
    end
    for i = 1, #data, 2 do hex[#hex + 1] = string.format("%02x", data:byte(i)) end
    return out, table.concat(hex)
end

function M.calc_de_hold_ms(nbytes, baud)
    local bits = nbytes * (8 + 1 + 1)
    return math.ceil(bits * 1000 / baud) + 2
end

local FIXED_LEN = {
    [1] = 8, [2] = 8, [3] = 8, [4] = 8, [5] = 8, [6] = 8,
}

function M.try_extract_len(s)
    if #s < 4 then return nil end
    local fc = s:byte(2)
    if fc >= 0x80 then return 5 end
    if fc == 1 or fc == 2 then
        if #s < 5 then return nil end
        return 5 + s:byte(3)
    end
    if fc == 3 or fc == 4 then
        if #s < 5 then return nil end
        return 5 + s:byte(3)
    end
    if fc == 15 or fc == 16 then
        if #s < 7 then return nil end
        return 9 + s:byte(6)
    end
    if FIXED_LEN[fc] then return FIXED_LEN[fc] end
    return nil
end

function M.decode_frame(s)
    local f = M.parse_frame(s)
    if not f then
        return { kind = "other", hex = (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)), raw = s }
    end
    f.hex = (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    if f.err then
        f.kind = "err"
    elseif f.fc == 3 then
        if f.data then f.kind = "rsp" else f.kind = "req" end
    elseif f.fc == 6 or f.fc == 16 then
        f.kind = "echo"
    else
        f.kind = "req"
    end
    return f
end

function M.parity_to_uart(p)
    if not uart then return p == 1 and 1 or (p == 2 and 2 or 0) end
    if p == 1 then return uart.EVEN or uart.Even end
    if p == 2 then return uart.ODD or uart.Odd end
    return uart.NONE or uart.None
end

function M.to_hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

return M
