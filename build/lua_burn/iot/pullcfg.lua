local util = require "util"
local cfg = require "core/config"
local cfgstore = require "cfg"
local log = util.log()
local json = util.try("json")

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




local REPL = "\239\191\189"







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



local function hex(s)
local t = {}
for i = 1, #s do t[i] = string.format("%02X", s:byte(i)) end
return table.concat(t, " ")
end







local function enc_note(s)
if s:find(REPL, 1, true) then
return "含 EFBFBD(平台已做有损转码, 原始汉字已丢失, 需从数据源修复)"
end
return "未见 EFBFBD(GBK 原样字节, 数据未损, 平台序列化改用 UTF-8 即可)"
end




local function props_to_regs(props, limit)
local regs, skipped, renamed = {}, {}, {}
for i, pr in ipairs(props or {}) do
if type(pr) ~= "table" then
skipped[#skipped + 1] = "第" .. i .. "条不是 table"
else




local mb = pr.modbus or pr
local id = trim(pr.id)
local dt, dtwhy = map_dtype(mb.dataType)
local addr = num(mb.address)
local qty = num(mb.quantity)

local vok, vwhy = util.validate_reg({
addr = addr, count = qty, name = id, dtype = dt,
})
if not vok then



local zh = ({
["bad addr"]  = "address 非法",
["bad count"] = "quantity 非法",
["bad dtype"] = dtwhy or ("不支持的 dataType「" .. tostring(mb.dataType) .. "」"),
["bad name"]  = "id「" .. id .. "」含非字母数字或超 16 字符",
})[vwhy] or vwhy
if id == "" and vwhy == "bad name" then
skipped[#skipped + 1] = "第" .. i .. "条 id 为空"
elseif id == "" then
skipped[#skipped + 1] = "第" .. i .. "条" .. zh
else
skipped[#skipped + 1] = id .. "：" .. zh
end
elseif #regs >= limit then
skipped[#skipped + 1] = id .. "：超过 " .. limit .. " 个上限，已截断"
else
local alias = trim(pr.name)



if not utf8_ok(alias) then
alias = ""
renamed[#renamed + 1] = id
log.info("pullcfg", "alias 非 UTF-8(平台编码问题), 退回 id: " .. id)


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





function M.parse(payload)
if not json then return nil, "no json lib" end
if type(payload) ~= "string" or payload == "" then return nil, "empty payload" end
local ok, t = pcall(json.decode, payload)
if not ok or type(t) ~= "table" then return nil, "json 解析失败" end
local snap = t.configSnapshot
if type(snap) ~= "table" then return nil, "缺少 configSnapshot" end
return M.parse_snap(t, snap)
end




function M.parse_snap(t, snap)
if type(snap) ~= "table" then return nil, "缺少 configSnapshot" end



local msg_id = t.msgId
if type(msg_id) ~= "string" or msg_id == "" then msg_id = "unknown" end







local nd = type(snap.devices) == "table" and #snap.devices or 0
local np = type(snap.tsl) == "table" and type(snap.tsl.properties) == "table"
and #snap.tsl.properties or 0
local nc = type(snap.commInterfaces) == "table" and #snap.commInterfaces or 0
if nd == 0 and np == 0 and nc == 0 then
return { empty = true, msg_id = msg_id }, nil
end

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

return { poll = poll, skipped = skipped, renamed = renamed, msg_id = msg_id }, nil
end

return M