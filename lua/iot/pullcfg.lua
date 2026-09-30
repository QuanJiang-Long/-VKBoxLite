local corelib = require "core/corelib"
local cfg = require "core/config"
local cfgstore = require "cfg"
local mqttcfg = require "iot/mqttcfg"
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

-- 平台 tsl.properties -> 本框架寄存器表
local function props_to_regs(props, limit)
    local regs, skipped = {}, {}
    for i, pr in ipairs(props or {}) do
        if type(pr) ~= "table" or type(pr.modbus) ~= "table" then
            skipped[#skipped + 1] = "第" .. i .. "条缺少 modbus 段"
        else
            local mb = pr.modbus
            local id = trim(pr.id)
            local dt = cfg.PULL_DTYPE[trim(mb.dataType):lower()]
            local addr = num(mb.address)
            local qty = num(mb.quantity)
            if id == "" then
                skipped[#skipped + 1] = "第" .. i .. "条 id 为空"
            elseif not id:match("^%w+$") or #id > 16 then
                skipped[#skipped + 1] = "第" .. i .. "条 id「" .. id .. "」含非字母数字或超 16 字符"
            elseif not dt then
                skipped[#skipped + 1] = id .. "：不支持的 dataType「" .. tostring(mb.dataType) .. "」"
            elseif not addr or addr < 0 or addr > 65535 then
                skipped[#skipped + 1] = id .. "：address 非法"
            elseif not qty or qty < 1 or qty > 125 then
                skipped[#skipped + 1] = id .. "：quantity 非法"
            elseif #regs >= limit then
                skipped[#skipped + 1] = id .. "：超过 " .. limit .. " 个上限，已截断"
            else
                local alias = trim(pr.name)
                regs[#regs + 1] = {
                    addr = addr, count = qty, name = id,
                    alias = alias ~= "" and alias or id,
                    dtype = dt,
                }
            end
        end
    end
    return regs, skipped
end

-- 拉取成功后回给前端展示的三个 topic，都是设备按 SN 拼好的成品。
-- hello 走 mqttcfg.resolve_hello：用户可能在 MQTT 页改过 hello topic，
-- 就得按改的拼，不能退回写死的平台常量。
-- pub 走 PLATFORM_POST_TOPIC（node 前缀 + {index}）：数据上报面。
-- sub 走 PLATFORM_GET_TOPIC（gw 前缀）：平台下发面。
--   原来是 PLATFORM_FUNC_TOPIC(node/function/get/-1)，两处都不对：
--   doc「平台下发恒用 gw 前缀」（node 是子设备上行专用），而且我们真正
--   订阅的主下行通道就是 config/get。订阅清单全量见 iot.build_subs()。
local function topics(sn)
    if not sn or sn == "" then return nil, nil, nil end
    return mqttcfg.resolve_hello(sn),
        string.format(cfg.PLATFORM_POST_TOPIC, sn),
        string.format(cfg.PLATFORM_GET_TOPIC, sn)
end
M.topics = topics

-- 解析平台下发的整包 JSON。
-- 只提取 commInterfaces 与 tsl.properties; 不写 fskv, 不重启轮询。
function M.parse(payload)
    if not json then return nil, "no json lib" end
    if type(payload) ~= "string" or payload == "" then return nil, "empty payload" end
    local ok, t = pcall(json.decode, payload)
    if not ok or type(t) ~= "table" then return nil, "json 解析失败" end
    local snap = t.configSnapshot
    if type(snap) ~= "table" then return nil, "缺少 configSnapshot" end

    local dev = (snap.devices or {})[1]
    local slave = dev and num(dev.addr) or nil
    if not slave or slave < 1 or slave > 247 then return nil, "devices[0].addr 非法" end

    local props = type(snap.tsl) == "table" and snap.tsl.properties or nil
    if type(props) ~= "table" or #props == 0 then return nil, "tsl.properties 为空" end

    local regs, skipped = props_to_regs(props, cfg.MAX_REGS)
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

    return { poll = poll, skipped = skipped, msg_id = msg_id }, nil
end

return M
