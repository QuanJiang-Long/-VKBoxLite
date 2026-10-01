local corelib = require "core/corelib"
local cfg = require "core/config"
local cfgstore = require "cfg"
local mqttcfg = require "iot/mqttcfg"
local log = corelib.log()
local json = corelib.try("json")

local M = {}

local function num(v)
    if type(v) == "number" then return math.floor(v) end
    if type(v) == "string" then return math.floor(tonumber(v) or 0) end
    return nil
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function pick_comm(snap)
    for _, ci in ipairs(snap.commInterfaces or {}) do
        if type(ci) == "table" and ci.enable and ci.type == "mbRTUClient" and type(ci.param) == "table" then
            return ci.param
        end
    end
    return nil
end

local function comm_to_poll(p, slave)
    local d = {
        baud = cfg.BAUD, databits = cfg.DATABITS,
        stopbits = cfg.STOPBITS, parity = cfg.PARITY,
    }
    if not p then return d end
    local b = num(p.baudRate)
    if b then d.baud = b end
    local db = num(p.dataBits)
    if db == 7 or db == 8 then d.databits = db end
    local sb = num(p.stopBits)
    if sb == 1 or sb == 2 then d.stopbits = sb end
    local pa = cfg.PULL_PARITY[trim(p.parity):lower()]
    if pa then d.parity = pa end
    d.slave = slave
    return d
end

-- U+FFFD 的 UTF-8 编码。平台若把 GBK 按 UTF-8 解码再重新编码发出，坏字节会
-- 变成一串 EF BFBD —— 结构上是合法 UTF-8，只按结构校验会漏过去，把 "??ѹ"
-- 当正常中文收下。正常参数名不可能含 U+FFFD，见到就拒
local REPL = "\239\191\189"

-- 判字符串是不是合法 UTF-8。
-- 现场实测：平台把中文 name 按 GBK 下发（"电压" → 字节 B5 E7 D1 B9，按
-- UTF-8 弱解码正好是 "??ѹ"，与 MQTTX/前端看到的完全一致）。MQTTX 是独立
-- 订阅方、不经我们设备，它也看到同样乱码 → 字节在到达任何读取方之前就已经
-- 坏了，与读取方是谁无关，是平台的编码问题。
-- 这里只校验不转码：GBK→UTF-8 要 1.4 万条映射表（~70KB），塞不进 300KB 的 Lua 堆。
local function utf8_ok(s)
    if type(s) ~= "string" or s == "" then return true end
    if s:find(REPL, 1, true) then return false end
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        if b < 0x80 then
            i = i + 1
        elseif b <= 0xC1 then            -- 孤立延续字节 / 超长序列头，必非法
            return false
        elseif b <= 0xDF then            -- 2 字节序列
            if i + 1 > n then return false end
            local c = s:byte(i + 1)
            if c < 0x80 or c > 0xBF then return false end
            i = i + 2
        elseif b <= 0xEF then            -- 3 字节序列（中文落在这里）
            if i + 2 > n then return false end
            for k = 1, 2 do
                local c = s:byte(i + k)
                if c < 0x80 or c > 0xBF then return false end
            end
            i = i + 3
        elseif b <= 0xF4 then            -- 4 字节序列
            if i + 3 > n then return false end
            for k = 1, 3 do
                local c = s:byte(i + k)
                if c < 0x80 or c > 0xBF then return false end
            end
            i = i + 4
        else
            return false
        end
    end
    return true
end

-- 平台 modbus.dataType 有裸类型(ushort)与带字节序后缀(long-ABCD)两种形态。
-- 本框架字节序/字序已从全链路删除、解码固定大端(即 ABCD)，所以只有 -ABCD
-- 与裸类型能收；-CDAB/-BADC/-DCBA 一律拒收 —— 按错的字节序解出来的值看起来
-- 合理但是错的，比直接报"不支持"危险得多。
local function map_dtype(raw)
    local s = trim(raw):lower()
    if s == "" then return nil, "dataType 为空" end
    local base, order = s:match("^([%w]+)%-(%a+)$")
    if base and order then
        if not cfg.PULL_ORDER_OK[order] then
            return nil, "dataType 后缀 -" .. order:upper() .. " 字节序不支持(本框架固定 ABCD)"
        end
        s = base
    end
    local d = cfg.PULL_DTYPE[s]
    if not d then return nil, nil end
    return d, nil
end

-- 原始字节 hex。只用于日志：报平台侧故障时必须说清收到的到底是什么，
-- 只说"中文乱码"对方没法定位
local function hex(s)
    local t = {}
    for i = 1, #s do t[i] = string.format("%02X", s:byte(i)) end
    return table.concat(t, " ")
end

-- 乱码成因判据。两种情形在 MQTTX / 前端 / 本日志的 alias 上看起来完全一样
-- （都是 "??ѹ"），但可修复性相反，报障时说错方向会让平台改错地方：
--   未见 EFBFBD = 平台把 GBK 原始字节塞进 JSON（序列化选错 charset）。
--                 汉字本身没坏，平台侧把序列化改成 UTF-8 就彻底好。
--   含 EFBFBD   = 平台已把 GBK 按 UTF-8 解码再编码发出，坏字节变成一串
--                 U+FFFD。原始汉字已丢失，要平台从数据库源头修
local function enc_note(s)
    if s:find(REPL, 1, true) then
        return "含 EFBFBD(平台已做有损转码, 原始汉字已丢失, 需从数据源修复)"
    end
    return "未见 EFBFBD(GBK 原样字节, 数据未损, 平台序列化改用 UTF-8 即可)"
end

-- 平台 tsl.properties -> 本框架寄存器表
-- 第三返回值 renamed = 因平台编码问题把 alias 退回 id 的条目名单，
-- 前端要提示用户「平台别名不可用」，否则用户只会看到 alias 莫名变成了 id
local function props_to_regs(props, limit)
    local regs, skipped, renamed = {}, {}, {}
    for i, pr in ipairs(props or {}) do
        if type(pr) ~= "table" or type(pr.modbus) ~= "table" then
            skipped[#skipped + 1] = "第" .. i .. "条缺少 modbus 段"
        else
            local mb = pr.modbus
            local id = trim(pr.id)
            local dt, dtwhy = map_dtype(mb.dataType)
            local addr = num(mb.address)
            local qty = num(mb.quantity)
            if id == "" then
                skipped[#skipped + 1] = "第" .. i .. "条 id 为空"
            elseif not id:match("^%w+$") or #id > 16 then
                skipped[#skipped + 1] = "第" .. i .. "条 id「" .. id .. "」含非字母数字或超 16 字符"
            elseif not dt then
                skipped[#skipped + 1] = id .. "：" .. (dtwhy or ("不支持的 dataType「" .. tostring(mb.dataType) .. "」"))
            elseif not addr or addr < 0 or addr > 65535 then
                skipped[#skipped + 1] = id .. "：address 非法"
            elseif not qty or qty < 1 or qty > 125 then
                skipped[#skipped + 1] = id .. "：quantity 非法"
            elseif #regs >= limit then
                skipped[#skipped + 1] = id .. "：超过 " .. limit .. " 个上限，已截断"
            else
                local alias = trim(pr.name)
                -- 非 UTF-8(GBK 乱码)时 alias 退回 id。有两个好处：参数表不显示
                -- 乱码；也不会被 build_payload 当 name 原样发回平台，把坏字节
                -- 循环发上去。平台哪天改用 UTF-8，这条自动失效
                if not utf8_ok(alias) then
                    alias = ""
                    renamed[#renamed + 1] = id
                    log.info("pullcfg", "alias 非 UTF-8(平台编码问题), 退回 id: " .. id)
                    -- 原始字节 + 成因判据：同一份配置手动下发正常、hello 触发乱码时，
                    -- 靠这行确定是"GBK 原样"还是"已被有损转码"——两者显示一模一样
                    log.info("pullcfg", string.format("  name 原始字节 %s (%dB) %s",
                        hex(pr.name or ""), #tostring(pr.name or ""), enc_note(tostring(pr.name or ""))))
                end
                regs[#regs + 1] = {
                    addr = addr, count = qty, name = id,
                    alias = alias ~= "" and alias or id,
                    dtype = dt,
                }
            end
        end
    end
    return regs, skipped, renamed
end

-- 拉取成功后回给前端展示的两个 topic 成品，取当前档次实际生效的那两条
-- （手动档 = 前端填的模板，自动档 = 默认模板），不是写死的平台常量。
-- hello 与另外 3 条下行订阅都是设备端固定常量，不随配置变，前端也没有
-- 对应输入框，所以都不回显。
local function topics(sn)
    if not sn or sn == "" then return nil end
    local prof = mqttcfg.profile(sn)
    if not prof then return nil end
    return { pub = prof.pub, sub = prof.sub }
end
M.topics = topics

-- 解析平台下发的整包 JSON。
-- 只提取 commInterfaces 与 tsl.properties; 不写 fskv, 不重启轮询。
-- 返回 {poll, skipped, renamed, msg_id}；失败返回 nil, 原因
function M.parse(payload)
    if not json then return nil, "no json lib" end
    if type(payload) ~= "string" or payload == "" then return nil, "empty payload" end
    local ok, t = pcall(json.decode, payload)
    if not ok or type(t) ~= "table" then return nil, "json 解析失败" end
    local snap = t.configSnapshot
    if type(snap) ~= "table" then return nil, "缺少 configSnapshot" end
    return M.parse_snap(t, snap)
end

-- 与 parse() 同一套逻辑，只是吃已解好的表。
-- 拆开是为了让 handle_downlink 复用同一次 json.decode 的结果：
-- 堆只有 300KB，同一份 payload 解两遍纯属浪费
function M.parse_snap(t, snap)
    if type(snap) ~= "table" then return nil, "缺少 configSnapshot" end

    local dev = (snap.devices or {})[1]
    local slave = dev and num(dev.addr) or nil
    if not slave or slave < 1 or slave > 247 then return nil, "devices[0].addr 非法" end

    local props = type(snap.tsl) == "table" and snap.tsl.properties or nil
    if type(props) ~= "table" or #props == 0 then return nil, "tsl.properties 为空" end

    local regs, skipped, renamed = props_to_regs(props, cfg.MAX_REGS)
    if #regs == 0 then return nil, "没有可用的寄存器条目" end

    local base = cfgstore.load_poll()
    local poll = comm_to_poll(pick_comm(snap), slave)
    poll.interval_ms = base.interval_ms
    poll.timeout_ms = base.timeout_ms
    poll.regs = regs

    -- msgId 原样带出去：U6 回执必须回同一个值，平台据此核销。
    -- 取不到就记 "unknown"（老平台/自测不带 msgId），回执照样发得出去
    local msg_id = t.msgId
    if type(msg_id) ~= "string" or msg_id == "" then msg_id = "unknown" end

    return { poll = poll, skipped = skipped, renamed = renamed, msg_id = msg_id }, nil
end

return M