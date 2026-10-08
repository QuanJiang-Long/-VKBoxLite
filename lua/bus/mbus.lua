local corelib = require "core/corelib"
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

-- CRC 按数字比较: crc16 返回 number, 与帧尾两字节拼成的 number 比。
-- ⚠️ 不能写成 crc16(x) == s:sub(a, b): number == string 在 Lua 恒为 false,
--    会让 try_extract_len 永远返回 nil, 表现就是"收到合法帧却全 timeout"
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
    -- fc16 请求: slave fc addr_hi addr_lo qty_hi qty_lo byte_count data...
    -- qty 是 2 字节, byte_count 是 1 字节, 少一个字节从机就解析不了
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
        -- fc3/4 响应 = slave(1)+fc(1)+bc(1)+data(bc)+crc(2) = 5 + bc
        if #s ~= 5 + bc then return nil end
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
        if #s ~= 5 + bc then return nil end
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

local function bytes_to_float(b, is_double)
    if is_double then
        if #b ~= 8 then return nil end
        local sign = math.floor(b[1] / 128)
        local e = math.floor(b[1] % 128) * 16 + math.floor(b[2] / 16)
        -- 尾数 52 位 = b[2] 低 4 位 + b[3..8]; 漏掉 b[2] 低 4 位会全解错
        local m = b[2] % 16
        for i = 3, 8 do m = m * 256 + b[i] end
        if e == 2047 then return nil end
        if e == 0 then
            if m == 0 then return 0.0 end
            return (sign == 1 and -1 or 1) * m * 2^(1 - 1023 - 52)
        end
        return (sign == 1 and -1 or 1) * (2^52 + m) * 2^(e - 1023 - 52)
    end
    if #b ~= 4 then return nil end
    local sign = math.floor(b[1] / 128)
    local e = math.floor(b[1] % 128) * 2 + math.floor(b[2] / 128)
    local m = math.floor(b[2] % 128) * 65536 + b[3] * 256 + b[4]
    if e == 255 then return nil end
    if e == 0 then
        if m == 0 then return 0.0 end
        return (sign == 1 and -1 or 1) * m * 2^(1 - 127 - 23)
    end
    return (sign == 1 and -1 or 1) * (2^23 + m) * 2^(e - 127 - 23)
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

-- 按数据类型直接解释。Modbus 标准是大端, 不再支持 LE:
-- 前端界面已去掉字节序/字序选择, 保留 LE 分支就是死代码
function M.parse_value(data, offset, dtype)
    local w = M.TYPE_WIDTH[dtype]
    if not w then return nil, "bad dtype" end
    local nbytes = w * 2
    local raw = data:sub(offset * 2 + 1, offset * 2 + nbytes)
    if #raw < nbytes then return nil, "short data" end
    local b = {}
    for i = 1, nbytes do b[i] = raw:byte(i) end
    if dtype == "float32" then
        return bytes_to_float({ b[1], b[2], b[3], b[4] }, false)
    elseif dtype == "float64" then
        return bytes_to_float({ b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8] }, true)
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

-- 批量解释: 固定大端, 按 dtype 直接解
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
    return math.ceil(bits * 1000 / baud) + 2
end

-- CRC 试探法定帧长: Modbus RTU 无长度字段, 只能按功能码猜结构 + 验 CRC
-- 每个候选长度都验 CRC, 猜错就不会返回错误长度
function M.try_extract_len(buf)
    if type(buf) ~= "string" or #buf < 5 then return nil end
    local fc = buf:byte(2)

    -- fc 1-6: 请求/写回显 8 字节定长
    if fc >= 1 and fc <= 6 and #buf >= 8 then
        if crc_at(buf, 6) then return 8 end
    end
    -- fc 1-4: 读响应 5 + byte_count
    if fc >= 1 and fc <= 4 and #buf >= 5 then
        local bc = buf:byte(3)
        if bc and bc >= 1 and bc <= 0xF4 then
            local total = bc + 5
            if #buf >= total then
                if crc_at(buf, 3 + bc) then return total end
            end
        end
    end
    -- fc 15/16: 既可能是 8 字节回显(slave fc addr(2) qty(2) crc(2)),
    --           也可能是 9 + bc 的写多寄存器请求, 两种都试
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
    -- fc 0x80+: 异常响应 5 字节
    if fc >= 0x80 and #buf >= 5 then
        if crc_at(buf, 3) then return 5 end
    end
    return nil
end

-- sniff 专用帧解析: fc3/4 的 8 字节形态(读请求)也算合法帧。
-- 那 8 字节是 slave fc addr(2) qty(2) crc(2), 第 3 字节是地址高字节不是
-- byte_count, parse_frame 按 5+bc 算必然拒收 -- 于是旁听只能看到应答看不到
-- 查询, REQ/RSP 配不上对(pair_state 全 orphan), R:INFER 推不出轮询表,
-- R:AUTODETECT 也因解不出帧而 21 连空。
--
-- ⚠️ 为什么不直接改 parse_frame: 那个函数被 poll 的 try_resp 用着, 它的匹配
-- 条件只看 slave/fc 不看请求还是响应。总线上别的主站(或另一台网关)发来的
-- fc3 查询帧 slave/fc 与在途请求相同, 会被误收成响应, 而查询帧没有 data
-- 字段, poll_reg 接着调 mbus.parse_regs(f.data) 就是 parse_regs(nil),
-- #nil 直接抛错把 poll_task 打断(表现为轮询突然不再打 round 日志)。
-- 所以只在这里兜底, parse_frame 一行不动, poll 行为零变化。
local function sniff_req_frame(s)
    if #s ~= 8 then return nil end
    local fc = s:byte(2)
    if fc ~= 3 and fc ~= 4 then return nil end
    if not M.crc_ok(s) then return nil end
    return {
        slave = s:byte(1), fc = fc,
        addr = s:byte(3) * 256 + s:byte(4),
        qty = s:byte(5) * 256 + s:byte(6),
        raw = s,
    }
end

function M.decode_frame(s)
    local f = M.parse_frame(s)
    if not f then f = sniff_req_frame(s) end
    if not f then
        return { kind = "other", hex = (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)), raw = s }
    end
    f.hex = (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    if f.err then
        f.kind = "err"
    elseif f.fc == 3 or f.fc == 4 then
        if f.data then f.kind = "rsp" else f.kind = "req" end
    elseif f.fc == 6 or f.fc == 16 then
        f.kind = "echo"
    else
        f.kind = "req"
    end
    -- parse_frame 的读响应分支只给 data, 不给 bc/qty/vhex。三种后果:
    --   ① 前端读 f.bc 得 nil, 显示成"字节数 0 值 []", 明明 bc=4 却说没数据
    --   ② pop_req/guess_last_req 都按 qty 配对, rsp 没 qty 就永远配不上 ->
    --      paired 恒 0、rsp 全 orphan; 而 pop_req 又是边删边比, 每进一个
    --      rsp 就把 pendingReqs 整队抽空, 之后主机的查询也再配不上
    --   ③ guess_last_req 开头 if not qty then return nil 直接放弃
    -- 按字节数反推: fc3/4 是寄存器(2 字节/个), fc1/2 是位(8 位/字节)
    if f.data and not f.qty then
        f.bc = #f.data
        f.qty = (f.fc == 3 or f.fc == 4) and math.floor(#f.data / 2) or (#f.data * 8)
        f.vhex = f.data:gsub(".", function(c) return string.format("%02x", c:byte()) end)
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
