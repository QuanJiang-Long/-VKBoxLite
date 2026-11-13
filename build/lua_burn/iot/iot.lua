local util = require "util"
local cfg = require "core/config"
local log = util.log()

local sys = util.get("sys")
local json = util.try("json")
local mqtt = util.try("mqtt")
local rtos = util.try("rtos")
local mobile = util.try("mobile")
local socket = util.try("socket")




for _, lib in ipairs({"sys", "socket", "mobile", "json", "bit", "zbuff", "pack"}) do
local m = util.try(lib)
if m and _G[lib] == nil then _G[lib] = m end
end



local lbsLoc2 = util.try("lbsLoc2")
if lbsLoc2 then
log.info("iot", "lbs lib: loaded, version=", lbsLoc2.version and lbsLoc2.version() or "?")
else

local ok, err = pcall(require, "lbsLoc2")
log.info("iot", "lbs lib: MISSING, require:", ok, err)
end

local mqttcfg = require "iot/mqttcfg"
local pubsched = require "iot/pubsched"   -- 12-fix-4: 统一上报调度(节奏都在那管)
local collector = require "data/collector"
local cfgstore = require "cfg"
local mon = require "bus/mon"
local MqttUtil = require "util/mqtt_util"




local topo = require "iot/topo"







local pullcfg_mod
local function get_pullcfg()
if pullcfg_mod == nil then
local ok, p = pcall(require, "iot/pullcfg")
pullcfg_mod = (ok and p) or false
end
return pullcfg_mod or nil
end





local U4_CHUNK_PTS = 16
local U4_WHOLE_MAX = 64






local BIG_ALLOC_KB = 200




local poll
local function get_poll()
if not poll then
local ok, p = pcall(require, "bus/poll")
poll = ok and p or false
end
return poll or nil
end







local ctrl_mod
local function get_mode()
if ctrl_mod == nil then
local ok, p = pcall(require, "bus/ctrl")
ctrl_mod = ok and p or false
end
return (ctrl_mod and ctrl_mod.get_mode()) or "idle"
end





local function poll_slot()








local m = get_mode()
if m == "platform" then return "pull"
elseif m == "manual" then return "poll"
else return nil end
end








local function active_cfg()
local f = (poll_slot() == "pull") and cfgstore.load_pull or cfgstore.load_poll
local ok, c = pcall(f)
return (ok and c) or nil
end

local M = {}



function M.pullcfg_loaded()
return pullcfg_mod ~= nil and pullcfg_mod ~= false
end

local S = {}















local function reclaim_if_high()
local kb = collectgarbage("count")
if kb > BIG_ALLOC_KB then
collectgarbage("collect")
S.reclaim_n = (S.reclaim_n or 0) + 1
log.warn("iot", string.format("reclaim before big alloc: lua=%.1fKB -> collected", kb))
return true
end
return false
end


local function reset_state()
S = {
want_run = false, connected = false, subscribed = false,
client = nil, dirty = false, backoff = 1,
published = 0, failed = 0, replied = 0, kick_flag = false,



build_fail = 0, reclaim_n = 0,
recv_pending = nil, pub = nil, sub = nil, subs = nil, device_id = nil,
last_pub = 0, last_err = nil, client_id = nil, user = nil,
reject_reason = nil,
pull = {
state = "idle", msg = "", result = nil, deadline = 0,
msg_id = nil, replied = false,



src = nil,
seen = 0,              -- OS time，收到这份配置的时间
},
pull_payload = nil,



push_n = 0, push_err = nil,
autosaved = false, autosave_at = 0, autosave_regs = 0,




meta_sig = nil, topo_sig = nil, res_at = 0,





topo_at = -1e9,



topo_sent_at = nil,



topo_fail_at = nil,
topo_fail_n = 0,



topo_ack_props = nil,




topo_sent_props = nil,
topo_prop_sig = nil,
topo_sent_sig = nil,



census_at = -1e9,


gc_at = -1e9, gc_trig = 0,

census_prev = nil,
busy_s = 0, span_s = 0,



hello_at = 0,

lbs = nil, lbs_at = 0,
}
end

local function device_id()
local ok, snc = pcall(require, "sn/sn")
if ok and snc and snc.state() == "ready" then
return _G.get_device_sn and _G.get_device_sn()
end
return nil
end





local function default_client_id(did)
if not did or did == "" then return did end
return did .. "_"
end

local function get_topic()
local did = device_id()
if not did or did == "" then return nil end
return string.format(cfg.PLATFORM_GET_TOPIC, did)
end










local alias_map_cache = nil
local alias_map_key = nil
local function alias_map(c)
local key = tostring(cfgstore.version()) .. ":" .. tostring(poll_slot())
if alias_map_cache and alias_map_key == key then return alias_map_cache end
c = c or active_cfg()
local m = {}
if c and c.regs then
for _, r in ipairs(c.regs) do m[r.name] = r.alias or r.name end
end
alias_map_cache = m
alias_map_key = key
return m
end




function M.drop_alias_cache()
alias_map_cache, alias_map_key = nil, nil
end




















function M.attach_names(inf)
if type(inf) ~= "table" or type(inf.regs) ~= "table" then return inf end
local amap = alias_map()
local smap = cfgstore.alias_map()   -- sniff 别名表 (用户起的名字)
local names = {}
for _, a in ipairs(inf.regs) do
local k = "reg" .. tostring(a.addr or "")
local id, name

local rowName = a.name or ""
local rowId = a.id or ""
if rowName ~= "" or rowId ~= "" then
id = (rowId ~= "") and rowId or k
name = (rowName ~= "") and rowName or id
else

local sa = smap[k]
if sa then
local sid = sa.id or ""
local snm = sa.name or ""
id = (sid ~= "") and sid or k
name = (snm ~= "") and snm or id
else
id = k
name = amap[k] or k   -- 没配 alias 时 = 本身, 与 U4 上报完全一致
end
end

if id ~= k or name ~= k then
names[k] = { id = id, name = name }
end
end

local out = {}
for k, v in pairs(inf) do out[k] = v end
out.regs = inf.regs   -- 同一个数组, 不复制
out.names = names
return out
end





local function pub(topic, body, qos)
if not S.client or not S.connected then return false, "未连接" end






local ok, result = pcall(S.client.publish, S.client, topic, body, qos or 1)
if not ok then return false, tostring(result) end
if result == false then return false, "mqtt publish returned false" end
return true
end


local function cur_did()
local d = S.device_id or device_id()
return (d and d ~= "") and d or nil
end




local function items_json(list, ts)
local out = {}
for _, it in ipairs(list) do
local v = MqttUtil.jnum(it.value) or "null"
out[#out + 1] = ts
and string.format('{"id":%s,"value":%s,"ts":%s}', MqttUtil.jstr(it.id or "unknown"), v, ts)
or string.format('{"id":%s,"value":%s}', MqttUtil.jstr(it.id or "unknown"), v)
end
return "[" .. table.concat(out, ",") .. "]"
end




local function net_registered(csq)
return not (type(csq) == "number" and csq == 0)
end




local function split_points(pts, chunk)
local out = {}
local n = #pts
if n == 0 then return out end
chunk = chunk or U4_CHUNK_PTS
if chunk < 1 then chunk = 1 end
local i = 1
while i <= n do
local last = math.min(i + chunk - 1, n)
local part = {}
for j = i, last do part[#part + 1] = pts[j] end
out[#out + 1] = part
i = last + 1
end
return out
end

M._test_split_points = split_points








local function build_items()



pcall(collector.trim_cache)
pcall(mon.trim_reqs)
collectgarbage("collect")
collectgarbage("collect")


local c = active_cfg()
local amap = alias_map(c)
local cfg_slave = c and c.slave or nil








local sniff_mode = get_mode() == "sniff"
local allowed
if not sniff_mode and c and c.regs then
allowed = {}
for _, r in ipairs(c.regs) do allowed[r.name] = true end
end
local by_slave, order = {}, {}

local smap = cfgstore.alias_map()





local ack = sniff_mode and S.topo_ack_props or nil
if sniff_mode and not ack then

return {}
end
for k, d in pairs(collector.get_all_latest()) do
local vs = MqttUtil.jnum(d.value)
if vs then


local slave
if sniff_mode then
local infer_data = mon.infer and mon.infer()
slave = (infer_data and infer_data.slave) or 1
else
slave = cfg_slave
end
if slave and (sniff_mode or allowed == nil or allowed[k]) then

local sa = smap[k]
local pid = (sa and sa.id ~= "" and sa.id) or k




if not ack or ack[pid] then
if not by_slave[slave] then
by_slave[slave] = {}
order[#order + 1] = slave
end
local pname = (sa and sa.name ~= "" and sa.name)
or (sa and sa.id ~= "" and sa.id)
or amap[k] or k
by_slave[slave][#by_slave[slave] + 1] =
string.format('{"id":%s,"name":%s,"value":%s,"ts":%s}',
MqttUtil.jstr(pid), MqttUtil.jstr(pname), vs, MqttUtil.ms_of(d.ts))
end
end
end
end
table.sort(order)

local items = SHARED_BUF.u4_items
for i = 1, #items do items[i] = nil end
for n, slave in ipairs(order) do
local pts = by_slave[slave]

if #pts > U4_WHOLE_MAX then
local chunks = 0
for _, part in ipairs(split_points(pts, U4_CHUNK_PTS)) do
local cok, cbody = pcall(function()
return "[" .. table.concat(part, ",") .. "]"
end)
if cok then
items[#items + 1] = { idx = n, slave = slave, body = cbody }
chunks = chunks + 1
end
end
log.info("iot", "u4 split " .. #pts .. " points into " .. chunks .. " chunks (>64)")
else






local ok, body = pcall(function()
return "[" .. table.concat(pts, ",") .. "]"
end)
if ok then
items[#items + 1] = { idx = n, slave = slave, body = body }
else
local chunks = 0
for _, part in ipairs(split_points(pts, U4_CHUNK_PTS)) do
local cok, cbody = pcall(function()
return "[" .. table.concat(part, ",") .. "]"
end)
if cok then
items[#items + 1] = { idx = n, slave = slave, body = cbody }
chunks = chunks + 1
end
end
S.build_fail = (S.build_fail or 0) + 1
log.warn("iot", "u4 body alloc failed, split " .. #pts .. " points into "
.. chunks .. " chunks")
end
end
end
return items
end



local function pub_blocked()
if get_mode() ~= "sniff" then return false end
local st = mon.status()
if st.detecting then return true end
local d = st.detected
if not d or d.baud == nil then return true end
if d.fallback then return true end
return false
end







local function publish()
if not S.client or not S.connected then return false end

if pub_blocked() then return false end


if get_mode() == "idle" then return false end




reclaim_if_high()
local ok, items = pcall(build_items)
if not ok then
S.build_fail = (S.build_fail or 0) + 1
log.warn("iot", "build_items failed, skip publish: " .. tostring(items))
return false
end
if #items == 0 then return false end
local base = S.pub or ""
if base == "" then return false end


local mc = mqttcfg.load()
local manual = mc.manual_on
local qos = mc.qos
local any = false
for _, it in ipairs(items) do
local topic = manual and base or (base .. "-" .. it.idx)



local ok, result = pcall(S.client.publish, S.client, topic, it.body, qos)
if ok and result ~= false then
S.published = S.published + 1
any = true
else
S.failed = S.failed + 1
local reason = ok and "mqtt publish returned false" or tostring(result)
log.warn("iot", string.format("publish fail sub %d (slave %d): %s",
it.idx, it.slave, reason))
end



collectgarbage("collect")
end
if any then

pubsched.sent("prop")
S.dirty = false
S.last_pub = os.time()
end
return any
end






















local function census()
local cs = collector.stats()
local ms = mon.status()
local ps = pubsched.status()

local fps, push = 0, 0
local prev = S.census_prev
local now = os.clock()
if prev and prev.clock then
local dt = now - prev.clock
if dt > 0 then
fps = math.floor(((cs.frames or 0) - (prev.frames or 0)) / dt)
push = math.floor(((cs.pushed or 0) - (prev.pushed or 0)) / dt)
end
end
S.census_prev = { frames = cs.frames or 0, pushed = cs.pushed or 0, clock = now }










local topoago = -1
if S.topo_sent_at and S.topo_sent_at > 0 then
topoago = math.floor(os.clock() - S.topo_sent_at)
end

local tack = 0
if S.topo_ack_props then
for _ in pairs(S.topo_ack_props) do tack = tack + 1 end
end
log.info("iot", string.format(
"census lua=%.1fKB points=%d frames=%d aliases=%d rows=%d pub=%d/%d meta=%d topo=%d blk=%d fps=%d push=%d gc=%d bfail=%d rc=%d err=%d aerr=%d toposig=%s topoago=%ds tfail=%d tack=%d",
collectgarbage("count"),
cs.points or 0, cs.frames or 0,
ms.hist_aliases or 0, ms.infer_rows or 0,
S.published or 0, S.failed or 0,
(ps.meta and ps.meta.sent) or 0, (ps.topo and ps.topo.sent) or 0,
((ps.prop and ps.prop.blocked) or 0) + ((ps.meta and ps.meta.blocked) or 0),
fps, push, S.gc_trig or 0,



S.build_fail or 0,

S.reclaim_n or 0,



ms.errs or 0, ms.alloc_err or 0,
tostring(S.topo_sig or "nil"), topoago,


S.topo_fail_n or 0,



tack))
end









local function heap_info()
if not rtos or type(rtos.meminfo) ~= "function" then return nil, nil end
local ok, a, b = pcall(rtos.meminfo, "sys")
if not ok or type(a) ~= "number" then return nil, nil end
return a, b
end


























local function lua_kb()
return collectgarbage("count")
end




local PARITY_LETTER = { [0] = "N", [1] = "E", [2] = "O" }



local function serial_json(c)
c = c or {}
return string.format('{"port":"/dev/ttyS1","baudRate":%d,"dataBits":%d,"stopBits":%d,"parity":%s}',
c.baud or cfg.BAUD, c.databits or cfg.DATABITS,
c.stopbits or cfg.STOPBITS, MqttUtil.jstr(PARITY_LETTER[c.parity or cfg.PARITY] or "N"))
end





















local MAX_PROPS = 128






local TOPO_BATCH_SIZE = 20





local TOPO_BUF_SIZE = 128  -- 最大属性数（与 MAX_INFER_ROWS 对齐）
local U4_BUF_SIZE = 64     -- U4 分包上限
local SLAVE_BUF_SIZE = 4   -- 最多 4 个从机

local SHARED_BUF = {

topo_parts = {},      -- 128 槽（property 片段）
topo_prop_ids = {},   -- 128 槽（属性 ID）


u4_items = {},        -- 64 槽（U4 分包）
u4_by_slave = {},     -- 4 槽（从机分组）
}


for i = 1, TOPO_BUF_SIZE do
SHARED_BUF.topo_parts[i] = nil
SHARED_BUF.topo_prop_ids[i] = nil
end
for i = 1, U4_BUF_SIZE do
SHARED_BUF.u4_items[i] = nil
end
for i = 1, SLAVE_BUF_SIZE do
SHARED_BUF.u4_by_slave[i] = nil
end







local function prop_id_name(r)
local id
if r.pid and r.pid ~= "" then
id = r.pid
elseif r.name and r.name ~= "" and not r.name:match("^r%d+$") then
id = r.alias or r.name
else
id = "reg" .. tostring(r.addr or "")
end
local nm = (r.pname and r.pname ~= "" and r.pname) or r.alias or id
return id, nm
end







































local function build_topo(only_ids, max_props, skip_ids)
local mode = get_mode()

local parts = SHARED_BUF.topo_parts
local prop_ids = SHARED_BUF.topo_prop_ids

for i = 1, #parts do parts[i] = nil end
for i = 1, #prop_ids do prop_ids[i] = nil end

local pos = {}
if mode == "sniff" then


local smap = cfgstore.alias_map()

local groups, gorder = {}, {}
local function group_of(slave)
local g = groups[slave]
if not g then
g = { addrs = {}, props = {} }
groups[slave] = g
gorder[#gorder + 1] = slave
end
return g
end

for _, r in ipairs((mon.infer() or {}).regs or {}) do
local g = group_of(r.slave)

local id, nm
if r.id and r.id ~= "" then
id = r.id
nm = (r.name and r.name ~= "") and r.name or id
else
local sa = smap["reg" .. tostring(r.addr or "")]
if sa then
id = (sa.id ~= "" and sa.id) or ("reg" .. tostring(r.addr or ""))
nm = (sa.name ~= "" and sa.name) or id
else
id = "reg" .. tostring(r.addr or "")
nm = id
end
end











if only_ids and not only_ids[id] then

elseif skip_ids and skip_ids[id] then

elseif max_props and #prop_ids >= max_props then

else
g.addrs[#g.addrs + 1] = r.addr
g.props[#g.props + 1] = topo.prop(id, nm, "uint16", r.slave, r.addr, 1)
prop_ids[#prop_ids + 1] = id  -- topo-ack-filter: 记录属性 ID
pos[r.addr] = #prop_ids  -- V2: 记录位置
end
end

local pc = cfgstore.load_pull()
for _, r in ipairs((pc and pc.regs) or {}) do
local g = group_of(pc.slave)
local id, nm = prop_id_name(r)
local prop = topo.prop(id, nm, r.dtype or "uint16", pc.slave, r.addr, r.count or 1)

local hit = pos[r.addr] or 0
if hit > 0 then


if only_ids and not only_ids[id] then

elseif skip_ids and skip_ids[id] then

elseif max_props and #prop_ids >= max_props then

else
g.props[hit] = prop
prop_ids[hit] = id  -- V2: 用 pos 定位，覆盖正确的 ID
end
else


if only_ids and not only_ids[id] then

elseif skip_ids and skip_ids[id] then

elseif max_props and #prop_ids >= max_props then

else
g.addrs[#g.addrs + 1] = r.addr
g.props[#g.props + 1] = prop
prop_ids[#prop_ids + 1] = id  -- topo-ack-filter: 新增 ID
end
end
end
local st = mon.status()
local d = st.detected
local ser = {
baud = (d and d.baud) or st.baud,
databits = (d and d.databits) or 8,
stopbits = (d and d.stopbits) or 1,
parity = (d and d.parity) or 0,
}
table.sort(gorder)
for i, s in ipairs(gorder) do
local g = groups[s]
local props = g.props
if #props > MAX_PROPS then
local cut = {}
for j = 1, MAX_PROPS do cut[j] = props[j] end
props = cut
end
topo.node_parts(parts, i, s, serial_json(ser), "sniff_s" .. s, props)
end
return parts, prop_ids, "还没识别到在线的从机"
end

local c = active_cfg()
if not (c and c.regs and #c.regs > 0) then
return nil, nil, "没有可用的寄存器表"
end
local props = {}
for _, r in ipairs(c.regs) do
if #props >= MAX_PROPS then break end
local id, nm = prop_id_name(r)


if only_ids and not only_ids[id] then

elseif skip_ids and skip_ids[id] then

else
props[#props + 1] = topo.prop(id, nm, r.dtype or "uint16", c.slave, r.addr, r.count or 1)
prop_ids[#prop_ids + 1] = id  -- topo-ack-filter: 记录属性 ID
end
end
topo.node_parts(parts, 1, c.slave, serial_json(c), "sniff_s" .. c.slave, props)
return parts, prop_ids
end


















local function topo_sig(only_ids)





pcall(collector.trim_cache)
pcall(mon.trim_reqs)
collectgarbage("collect")
collectgarbage("collect")
reclaim_if_high()
local parts, prop_ids = build_topo(only_ids)
if not parts then return nil end
return topo.sig(parts), parts, prop_ids
end











local function fw_num()
local v = _G.VERSION or ""
local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)")
if not a then return 0 end
return tonumber(a) * 10000 + tonumber(b) * 100 + tonumber(c)
end







local function send_meta()
local did = cur_did()
if not did then return false, "无 SN" end

if pub_blocked() then return false, "识别未完成" end
local csq = MqttUtil.mcall(mobile, "csq")
if type(csq) ~= "number" then csq = nil end
local p = {}


p[#p + 1] = string.format('"sn":%s', MqttUtil.jstr(did))
p[#p + 1] = string.format('"deviceSn":%s', MqttUtil.jstr(did))
p[#p + 1] = string.format('"imei":%s', MqttUtil.jstr(MqttUtil.imei(mobile)))
p[#p + 1] = string.format('"iccid":%s', MqttUtil.jstr(tostring(MqttUtil.mcall(mobile, "iccid") or "")))
p[#p + 1] = string.format('"fw":%s', MqttUtil.jstr("v" .. (_G.VERSION or "0.0.0")))
p[#p + 1] = string.format('"firmwareVersion":%d', fw_num())
p[#p + 1] = string.format('"hw":%s', MqttUtil.jstr(cfg.PLATFORM_MODEL))
p[#p + 1] = string.format('"capabilities":[%s]', '"modbus","mqtt"')

local mode = get_mode()
if mode == "manual" or mode == "platform" then
p[#p + 1] = string.format('"deviceName":%s', MqttUtil.jstr(""))
else
p[#p + 1] = string.format('"deviceName":%s', MqttUtil.jstr("VKBOXLite-" .. did))
end
p[#p + 1] = string.format('"serialNumber":%s', MqttUtil.jstr(did))
if csq then p[#p + 1] = string.format('"csq":%d', csq) end
p[#p + 1] = string.format('"netRegister":%s', tostring(net_registered(csq)))
p[#p + 1] = string.format('"networkAddress":%s', MqttUtil.jstr(mqttcfg.load().host))
p[#p + 1] = string.format('"isShadow":0')
p[#p + 1] = string.format('"summary":%s', MqttUtil.jstr("VKBoxLite Bootstrap"))

p[#p + 1] = '"deviceType":3'
p[#p + 1] = '"locationWay":' .. (S.lbs and "2" or "0")


if S.lbs then
p[#p + 1] = string.format('"latitude":%.6f', S.lbs.lat)
p[#p + 1] = string.format('"longitude":%.6f', S.lbs.lng)
end








p[#p + 1] = string.format('"ts":%s', MqttUtil.ms_of(os.time()))
return pub(string.format(cfg.PLATFORM_INFO_TOPIC, did), "{" .. table.concat(p, ",") .. "}", 1)
end
















local function send_topo(parts_in, empty)
local did = cur_did()
if not did then return false, "无 SN" end


if pub_blocked() then return false, "识别未完成" end
local parts = parts_in
if not parts and not empty then
local p, err = build_topo()
if not p then return false, err end
parts = p
end
local b = {
'{"vendor":', MqttUtil.jstr("VKBox"),
',"model":', MqttUtil.jstr(cfg.PLATFORM_MODEL),
',"fwVersion":', MqttUtil.jstr(_G.VERSION or "0.0.0"),




',"ts":"', MqttUtil.ms_of(os.time()), '"',
',"nodes":[',
}
if parts then
for i = 1, #parts do b[#b + 1] = parts[i] end
end
b[#b + 1] = ']}'
local body = table.concat(b)
return pub(string.format(cfg.PLATFORM_INFO_TOPIC, did), body, 1)
end












local function meta_sig()
local lbs_lat = S.lbs and S.lbs.lat or 0
local lbs_lng = S.lbs and S.lbs.lng or 0
return string.format("%s|%s|%s|%.6f|%.6f", MqttUtil.imei(mobile),
tostring(MqttUtil.mcall(mobile, "iccid") or ""),
tostring(mqttcfg.load().host or ""), lbs_lat, lbs_lng)
end





local function lbs_request()
if not lbsLoc2 or not mobile then return nil end

pcall(mobile.reqCellInfo, 15)
if sys and type(sys.waitUntil) == "function" then
sys.waitUntil("CELL_INFO_UPDATE", 3000)
end
local ok, r1, r2 = pcall(lbsLoc2.request, 5000)
if not ok then log.warn("iot", "lbs request err:", r1); return nil end
if r1 == nil or r2 == nil then return nil end
local lat, lng = tonumber(r1), tonumber(r2)
if type(lat) ~= "number" or type(lng) ~= "number" then return nil end
log.info("iot", "lbs got:", lat, lng)
return { lat = lat, lng = lng }
end









local EVENT_THRESHOLD = { ram = 85, cpu = 90, disk = 90 }



local function disk_used_pct()
if not rtos or type(rtos.fsinfo) ~= "function" then return nil end
local ok, total, used = pcall(rtos.fsinfo, "/")
if not ok or type(total) ~= "number" or total <= 0 then return nil end
return math.floor(used * 1000 / total) / 10
end


local function send_event(subtype, value, threshold)
local did = cur_did()
if not did then return false end
local body = string.format(
'{"sn":%s,"type":"resource_alarm","subtype":%s,'
.. '"level":"warn","value":%s,"threshold":%s,"ts":%d}',
MqttUtil.jstr(did), MqttUtil.jstr(subtype),
tostring(value), tostring(threshold), os.time())
return pub(string.format(cfg.PLATFORM_EVENT_TOPIC, did), body, 1)
end




local function check_event_threshold(ram_pct, cpu_pct)
S.event_state = S.event_state or { ram = false, cpu = false, disk = false }
S.event_at = S.event_at or 0
local now = os.time()
if (now - S.event_at) < 30 then return end
local disk = disk_used_pct()
local resources = {
ram  = { value = ram_pct, threshold = EVENT_THRESHOLD.ram },
cpu  = { value = cpu_pct, threshold = EVENT_THRESHOLD.cpu },
}
if disk then
resources.disk = { value = disk, threshold = EVENT_THRESHOLD.disk }
end
for sub, r in pairs(resources) do
local crossed = r.value >= r.threshold
if crossed and not S.event_state[sub] then
send_event(sub, r.value, r.threshold)
S.event_state[sub] = true
S.event_at = now
elseif not crossed and S.event_state[sub] then
S.event_state[sub] = false
end
end
end

local function send_gw_res()
local did = cur_did()
if not did then return false end



if pub_blocked() then return false end
local total, used = heap_info()
local ts = MqttUtil.ms_of(os.time())
local ram = 0
if total and total > 0 then
ram = math.floor(used * 1000 / total) / 10
end
local cpu = 0
if S.busy_s and S.span_s and S.span_s > 0 then
cpu = math.min(100, math.max(0, math.floor(S.busy_s * 1000 / S.span_s) / 10))
end
local ok = pub(string.format(cfg.PLATFORM_RES_TOPIC, did),
items_json({
{ id = "ram_percent", value = ram },
{ id = "uptime_sec", value = math.floor(os.clock()) },
{ id = "cpu_percent", value = cpu },
{ id = "IMEI", value = MqttUtil.imei(mobile) },
{ id = "ICCID", value = tostring(MqttUtil.mcall(mobile, "iccid") or "") },
}, ts), 1)

S.res_at = os.time()
if not ok then return false end


S.busy_s, S.span_s = 0, 0

check_event_threshold(ram, cpu)
return true
end






local function func_reply(rs)
if not rs or #rs == 0 then return false end
local did = cur_did()
if not did then return false end
local ok, e = pub(string.format(cfg.PLATFORM_FPOST_TOPIC, did),
items_json(rs, nil), 1)
if not ok then
log.warn("iot", "func reply fail:", tostring(e))
return false
end
return true
end





























local function node_invoke_topics(did)
local topics = {}

topics[1] = string.format(cfg.PLATFORM_FUNC_NODE_TOPIC, did) .. "-1"
return topics
end

local function build_subs()
local subs = {}
local function add(t)
if not t or t == "" then return end
for _, x in ipairs(subs) do
if x == t then return end
end
subs[#subs + 1] = t
end
if get_mode() == "idle" then return subs end
local did = S.device_id
if not did or did == "" then return subs end

if not mqttcfg.load().manual_on then
add(string.format(cfg.PLATFORM_GET_TOPIC, did))


add(string.format(cfg.PLATFORM_FUNC_TOPIC, did))
for _, t in ipairs(node_invoke_topics(did)) do
add(t)
end
add(string.format(cfg.PLATFORM_PSET_TOPIC, did))
add(string.format(cfg.PLATFORM_PGET_TOPIC, did))
end
add(S.sub)
return subs
end



local function should_pub_platform()
if get_mode() == "idle" then return false end
if mqttcfg.load().manual_on then return false end
return true
end





local function should_pub_topo()
return get_mode() == "sniff"
end






local function should_pub_meta()
local m = get_mode()
if m == "idle" then return false end
return true
end



local function destroy_client()
if S.client then

pcall(function() S.client:autoreconn(false) end)
pcall(function() S.client:disconnect() end)
pcall(function() S.client:close() end)
S.client = nil
end
S.connected = false
S.subscribed = false
collectgarbage("collect")
end

local function on_mqtt(cli, event, data, payload)
if event == "conack" then
S.connected = true
S.backoff = 1
S.reject_reason = nil


pubsched.reset()




S.hello_at = 0



S.meta_sig = nil
local subs = build_subs()
S.subs = subs
S.subscribed = false

local qos = mqttcfg.load().qos
for _, t in ipairs(subs) do
local sok, serr = pcall(function() cli:subscribe(t, qos) end)

if not sok then log.warn("iot", "subscribe fail:", t, tostring(serr)) end
S.subscribed = S.subscribed or sok
end
log.info("iot", string.format("conack ok, subscribed=%s, topics=[%s]",
tostring(S.subscribed), table.concat(subs, " ")))
elseif event == "recv" then
S.recv_pending = { topic = data, payload = payload }
elseif event == "disconnect" or event == "error" then
S.connected = false
S.subscribed = false















if event == "error" then
local d = tostring(data)
if d == "conack" or not S.reject_reason then
if d == "conack" then
S.reject_reason = "平台拒绝连接(CONACK 0x05 未授权), 检查地址/端口或补用户密码/凭证密码"
else
S.reject_reason = "连不上服务器(" .. d .. "): 域名解析不到或端口不通, 核对 host 拼写"
end
end





destroy_client()
end
log.warn("iot", event, tostring(data))
end
end



local function net_ready()
return net_registered(MqttUtil.mcall(mobile, "csq"))
end

local function try_connect()
if not mqtt then return false, "mqtt 库不可用(需 sysplus/mqtt 组件)" end
if type(mqtt.create) ~= "function" then return false, "mqtt.create 不可用" end
local c = mqttcfg.load()
local did = device_id()

if not did or did == "" then return false, "no sn" end
S.device_id = did



local prof, terr = mqttcfg.profile(did)
if not prof then return false, terr end
S.pub, S.sub = prof.pub, prof.sub



local cid = c.client_id ~= "" and c.client_id or default_client_id(did)
S.client_id = cid
local user = prof.user ~= "" and prof.user or did
S.user = user

collectgarbage("collect")
local h1, h2 = heap_info()
log.info("iot", "create mqtt", c.host, c.port, "heap total=" .. tostring(h1) .. " used=" .. tostring(h2))


log.info("iot", string.format("connect: host=%s port=%d ssl=%s clientId=%s user=%s clean=%s",
c.host, c.port, tostring(c.ssl), cid, user, tostring(not c.keep_session)))
local okc, cli = pcall(mqtt.create, nil, c.host, c.port, c.ssl)
if not okc or not cli then return false, "mqtt.create 失败: " .. tostring(cli) end
S.client = cli





pcall(function() cli:auth(cid, user,
prof.pass ~= "" and prof.pass or nil, not c.keep_session) end)
pcall(function() cli:keepalive(60) end)
pcall(function() cli:autoreconn(false) end)
local okon, eon = pcall(cli.on, cli, on_mqtt)
if not okon then
destroy_client()
return false, "on 失败: " .. tostring(eon)
end
local ok, e = pcall(cli.connect, cli)
if not ok or not e then
destroy_client()
return false, "connect 失败: " .. tostring(e)
end



local waited = 0
while waited < 15000 do
if S.connected then return true end
if not S.client then break end
if sys then sys.wait(100) end
waited = waited + 100
end
if not S.connected then
destroy_client()

return false, S.reject_reason or "conack timeout"
end
return true
end

local function wait_kickable(ms)
local waited = 0
while waited < ms do
if not S.want_run then return end
if S.kick_flag then S.kick_flag = false; return end
if sys then sys.wait(200) end
waited = waited + 200
end
end

local function downlink_write(items)
local ok, poll = pcall(require, "bus/poll")
if not ok or not poll then
log.error("iot", "downlink write: bus/poll 不可用")
return 0, 0
end



local c = active_cfg()
local regs = (c and c.regs) or {}

local dslave = (c and c.slave) or cfg.SLAVE_ADDR
local function resolve_addr(k)
if not k then return nil end
if type(k) ~= "string" then

if type(k) == "number" then return math.floor(k) end
return nil
end
for _, r in ipairs(regs) do
if r.name == k or r.alias == k then return r.addr end
end
local lk = k:lower()
for _, r in ipairs(regs) do
if r.name:lower() == lk or (r.alias and r.alias:lower() == lk) then return r.addr end
end
return nil
end

local function dnum(v)
if v == nil then return nil end
local n = tonumber(v)
return n
end


local results = {}
local nok, nfail = 0, 0
for _, it in ipairs(items) do
local dkey = it.id or it.name or it.key or it.regName or it.reg_name
local addr = dnum(it.addr or it.address or it.reg or it.register or it.offset)
if not addr then addr = resolve_addr(dkey) end
local slave = dnum(it.slave or it.dev or it.device or it.slaveId or it.slave_id)
if not slave then slave = dslave end


local rid = dkey
if type(rid) ~= "string" or rid == "" then rid = "r" .. tostring(addr or 0) end
if it.values and type(it.values) == "table" and addr then
local vals = {}
for _, v in ipairs(it.values) do
local n = dnum(v)
if not n then n = 0 end
vals[#vals + 1] = n
end
local okw = poll.enqueue_write({ slave = slave, addr = addr, values = vals })
if okw then nok = nok + 1 else nfail = nfail + 1 end
results[#results + 1] = { id = rid, value = okw and #vals or nil }
elseif addr then
local v = dnum(it.value or it.val or it.data)
if v then
local okw = poll.enqueue_write({ slave = slave, addr = addr, value = v })
if okw then nok = nok + 1 else nfail = nfail + 1 end
results[#results + 1] = { id = rid, value = okw and v or nil }
else
nfail = nfail + 1
results[#results + 1] = { id = rid, value = nil }
log.warn("iot", "write item bad value:", tostring(dkey))
end
else
nfail = nfail + 1
results[#results + 1] = { id = rid, value = nil }
log.warn("iot", "write item unresolvable:", tostring(dkey))
end
end




log.info("iot", string.format("downlink write: queued=%d rejected=%d", nok, nfail))
return results
end






local function claim_ok(topic)
if type(topic) ~= "string" then return true end
if topic:sub(1, 11) ~= "/sys/thing/" then return true end
local did = cur_did()
if not did then return true end
local last = topic:match("([^/]+)$")
if not last then return false end
if last == did then return true end

return last:sub(1, #did + 1) == (did .. "-")
end




local function pulling()
local st = S.pull.state
return st == "connecting" or st == "helloing" or st == "waiting"
end











local function auto_apply(r)
if not r or not r.poll then return false, "无可应用的配置" end
local n, nerr = cfgstore.normalize_poll(r.poll)
if not n then return false, "配置不合法: " .. tostring(nerr) end



local base = cfgstore.load_pull()
n.interval_ms = base.interval_ms
n.timeout_ms = base.timeout_ms

local before = { slave = base.slave, baud = base.baud, regs = #(base.regs or {}) }
local ok, serr = cfgstore.save_pull(n)
if not ok then return false, "落盘失败: " .. tostring(serr) end

local pe = get_poll()
if pe then



if poll_slot() == "pull" then


if pe.needs_restart(n) then
if pe.is_running() then
pe.stop()
pe.apply_cfg(n)
pe.start("pull")
else



pe.apply_cfg(n)
pe.start("pull")
end
else
pe.apply_cfg(n)



if not pe.is_running() then pe.start("pull") end
end
end
end

S.autosaved = true
S.autosave_at = os.time()
S.autosave_regs = #n.regs
log.info("iot", string.format(
"pullcfg 自动保存并生效: 寄存器 %d->%d, slave %d->%d, baud %d->%d, msgId=%s",
before.regs, #n.regs, before.slave or 0, n.slave or 0,
before.baud or 0, n.baud or 0, tostring(S.pull.msg_id)))
return true
end






local function reply_config()
local p = S.pull
if p.replied then return true end
if not p.msg_id or p.msg_id == "" then return true end
if not S.connected or not S.client then return false, "MQTT 未连接" end
local did = cur_did()
if not did then return false, "无 SN" end
local topic = string.format(cfg.PLATFORM_REPLY_TOPIC, did)


local body = string.format(
'{"msgId":%s,"code":200,"message":%s,"status":"ok","appliedTs":%d}',
MqttUtil.jstr(p.msg_id), MqttUtil.jstr(p.msg ~= "" and p.msg or "config applied"), os.time())
log.info("iot", "config/reply " .. topic .. " " .. body)
local ok, err = pub(topic, body, 1)
if not ok then return false, err end
p.replied = true
S.replied = S.replied + 1
return true
end
M.reply_config = reply_config




local function recv_push(t, payload)
local pc = get_pullcfg()
if not pc then
S.push_err = "pullcfg 未加载(该档位不应收到配置推送)"
log.warn("iot", "push ignored: pullcfg not loaded")
return false
end
local r, err = pc.parse_snap(t, t.configSnapshot)
if not r then
S.push_err = tostring(err)


log.warn("iot", "push parse fail: " .. tostring(err) .. " body=" .. tostring(payload))
return false
end
S.push_err = nil


if r.empty then
S.pull.state = "done"
S.pull.src = "push"
S.pull.seen = os.time()
S.pull.msg = "平台未下发配置，本地嗅探自建生效"
S.pull.result = nil
S.pull.msg_id = r.msg_id
S.pull.replied = false
pcall(reply_config)
S.push_n = S.push_n + 1
log.info("iot", "push recv empty snapshot, 平台无配置, msgId=" .. r.msg_id)
return true
end
S.pull.state = "done"
S.pull.src = "push"
S.pull.seen = os.time()
S.pull.msg = "平台重新下发"
S.pull.result = r
S.pull.msg_id = r.msg_id
S.pull.replied = false


local aok, aerr = auto_apply(r)
if aok then
S.pull.msg = "平台配置已自动保存生效"
pcall(reply_config)
S.push_n = S.push_n + 1
log.info("iot", string.format("push recv msgId=%s regs=%d skipped=%d (已自动保存)",
r.msg_id, #(r.poll.regs or {}), #(r.skipped or {})))
else
S.push_err = "自动保存失败: " .. tostring(aerr)
S.push_n = S.push_n + 1
log.warn("iot", string.format("push recv msgId=%s 但自动保存失败: %s", r.msg_id, tostring(aerr)))
end
return aok
end


local function handle_downlink(topic, payload)
if not claim_ok(topic) then
log.info("iot", "downlink dropped, not ours: " .. tostring(topic))
return
end




if type(topic) == "string" and topic:find("/gw/config/get/", 1, true) then
if S.pull.state == "waiting" then
log.info("iot", string.format("pullcfg recv topic=%s len=%d body=%s",
topic, #tostring(payload), tostring(payload)))
S.pull_payload = payload
return
end
log.info("iot", "downlink on get topic, pull idle -> parse as cmd")
end
if not json then return end
local ok, t = pcall(json.decode, payload)
if not ok or type(t) ~= "table" then return end



if type(t.configSnapshot) == "table" then
if pulling() then




S.pull_payload = payload
log.info("iot", string.format("push during handshake(%s), parked len=%d",
S.pull.state, #tostring(payload)))
return
end
recv_push(t, payload)
return
end
local cmd = t.cmd and t.cmd:upper() or nil
if cmd == "REPORT" or cmd == "READALL" then
S.dirty = true
pubsched.changed("prop")   -- 12-fix-4: 平台点名要数据 → 置脏(节奏仍走闸门)
return
end



if cmd == "WRITE" and type(t.items) == "table" then
func_reply(downlink_write(t.items))
return
end
if t[1] and type(t[1]) == "table" then
func_reply(downlink_write(t))
return
end
if t.items and type(t.items) == "table" then
func_reply(downlink_write(t.items))
return
end
if t.value or t.values or t.val or t.data then
func_reply(downlink_write({ t }))
return
end


log.warn("iot", "downlink unrecognized, no action: " .. tostring(payload))
end



local function pull_active() return pulling() end




function M.pulling() return pulling() end












function M.set_manual(on)
on = on and true or false
local c = mqttcfg.load()

if not not c.manual_on == on then return false end
c.manual_on = on
if on then


local ok, err = mqttcfg.save(c)
if not ok then return false, err end
else






local d = mqttcfg.default
local ok, err = mqttcfg.save({
host = d.host, port = d.port, ssl = d.ssl,
manual_on = false,
auto = { pass = c.auto and c.auto.pass or "" },
})
if not ok then return false, err end
end
destroy_client()
M.kick()
log.info("iot", "mqtt manual_on ->", tostring(on))
return true
end

function M.pull_start()


if pull_active() then return true end
if not get_topic() then return false, "无 SN" end
local c = mqttcfg.load()
if not c.host or c.host == "" then return false, "请先配置 MQTT 服务器地址" end
if not c.port or c.port < 1 or c.port > 65535 then return false, "请先配置 MQTT 端口" end
S.pull = {
state = "connecting", msg = "", result = nil,
deadline = os.time() + math.floor(cfg.PULL_CONNECT_MS / 1000),
msg_id = nil, replied = false,



hello_try = 0,
}

if not S.connected then M.kick() end
return true
end

function M.pull_status()
local p = S.pull
local r = { state = p.state, msg = p.msg }
if p.result then
r.poll = p.result.poll
r.skipped = p.result.skipped
r.renamed = p.result.renamed


local prof = mqttcfg.profile(device_id())
r.mqtt = {
pub = prof and prof.pub, sub = prof and prof.sub,
}
end

r.msg_id = p.msg_id
r.replied = p.replied


r.src = p.src or "pull"
r.seen = p.seen
r.autosaved = S.autosaved
r.autosave_at = S.autosave_at
r.autosave_regs = S.autosave_regs
r.push_n = S.push_n
r.push_err = S.push_err
return r
end





local function send_hello()
if not S.client or not S.connected then return false, "未连接" end
local did = device_id()
if not did or did == "" then return false, "无 SN" end


local topic = string.format(cfg.PLATFORM_HELLO_TOPIC, did)









local m = get_mode()

local onboard = m == "sniff" and "sniff" or (m == "platform" or m == "pollpull") and "platform" or "manual"


local dv = MqttUtil.imei(mobile)
if dv == "" then dv = "unknown" end




local hello_nodes = nil
local hello_prop_ids = nil
if m == "sniff" then


local parts, pids = build_topo(nil, TOPO_BATCH_SIZE)  -- 最多 TOPO_BATCH_SIZE 个 property
if parts and pids and #pids > 0 then
hello_nodes = parts
hello_prop_ids = pids
end
end





if m == "sniff" and not hello_nodes then
return false, "sniff 档等待寄存器推断完成"
end
local body_parts = {
'{"vendor":', MqttUtil.jstr(cfg.PLATFORM_VENDOR),
',"model":', MqttUtil.jstr(cfg.PLATFORM_MODEL),
',"fwVersion":', MqttUtil.jstr(_G.VERSION or "0.0.0"),
',"deviceId":', MqttUtil.jstr(dv),
',"topicFormat":', MqttUtil.jstr("v3"),
',"onboardingMode":', MqttUtil.jstr(onboard),
}

if hello_nodes then
body_parts[#body_parts + 1] = ',"nodes":['
for i = 1, #hello_nodes do
body_parts[#body_parts + 1] = hello_nodes[i]
end
body_parts[#body_parts + 1] = ']'
end
body_parts[#body_parts + 1] = '}'
local body = table.concat(body_parts)
log.info("iot", string.format("pullcfg hello topic=%s sn=%s imei=%s mode=%s body=%s",
topic, did, MqttUtil.imei(mobile), onboard, body))


local ok, err = pub(topic, body, 1)
if not ok then return false, err end


S.hello_at = os.time()

if hello_prop_ids then
S.topo_sent_props = S.topo_sent_props or {}



S.topo_ack_props = S.topo_ack_props or {}
for _, id in ipairs(hello_prop_ids) do
S.topo_sent_props[id] = true
S.topo_ack_props[id] = true
end
end
return true, onboard
end






function M.hello()
if not S.client or not S.connected then return false, "未连接" end
return send_hello()
end

local function pull_finish(state, msg, result)
S.pull.state = state
S.pull.msg = msg
S.pull.result = result

if state == "done" then
S.push_err = nil
end
log.info("iot", "pullcfg", state, msg)
end

local function pull_step()
local p = S.pull
if p.state == "connecting" then


if S.connected then



p.deadline = 0
p.hello_try = 0
p.state = "helloing"
elseif os.time() >= p.deadline then
local why = S.reject_reason or S.last_err or "超时"
pull_finish("fail", "MQTT 连接失败: " .. tostring(why))
end
elseif p.state == "helloing" then







if not S.client or not S.connected then
p.state = "connecting"
p.deadline = os.time() + math.floor(cfg.PULL_CONNECT_MS / 1000)
return
end

if p.deadline > os.time() then return end





local ok, res = send_hello()
if not ok then



p.hello_try = (p.hello_try or 0) + 1
local bo = cfg.HELLO_BACKOFF_S[p.hello_try]
if not bo then
return pull_finish("fail", "hello 发送失败: " .. tostring(res))
end
p.deadline = os.time() + bo
log.warn("iot", string.format("hello 发送失败(%d/3), %ds 后重发: %s",
p.hello_try, bo, tostring(res)))
return
end
p.hello_try = 0




if res == "sniff" then
return pull_finish("done", "sniff 模式平台不下发配置，寄存器表用本地嗅探结果")
end
p.state = "waiting"
p.deadline = os.time() + math.floor(cfg.PULL_TIMEOUT_MS / 1000)
elseif p.state == "waiting" then
if S.pull_payload then
local payload = S.pull_payload
S.pull_payload = nil
local pc = get_pullcfg()
if not pc then
return pull_finish("fail", "pullcfg 未加载")
end
local r, err = pc.parse(payload)
if not r then
log.warn("iot", "pull parse fail: " .. tostring(err) .. " body=" .. tostring(payload))
return pull_finish("fail", tostring(err))
end
p.src = "pull"
p.seen = os.time()
p.msg_id = r.msg_id
p.replied = false


if r.empty then
p.result = nil
p.msg = "平台未下发配置，本地嗅探自建生效"
pcall(reply_config)
return pull_finish("done", p.msg)
end







local aok, aerr = auto_apply(r)
if not aok then
return pull_finish("apply_fail", "拉取成功但配置不适用: " .. tostring(aerr))
end

pcall(reply_config)
return pull_finish("done", "已自动保存生效" .. (#r.skipped > 0 and ("，忽略 " .. #r.skipped .. " 条") or ""), r)
end
if os.time() >= p.deadline then pull_finish("fail", "平台未下发配置(超时)") end
end
end








local function subs_same(a, b)
if not a or not b or #a ~= #b then return false end
for i = 1, #a do
if a[i] ~= b[i] then return false end
end
return true
end

local function refresh_subs()
if not S.client or not S.connected then return end
local want = build_subs()
if subs_same(want, S.subs) then return end


S.subs = want
destroy_client()
M.kick()
log.info("iot", "subs changed by mode, reconnect: [" .. table.concat(want, " ") .. "]")
end

local function task_main()
S.want_run = true
while S.want_run do










if mon.infer_watch() and mon.take_infer_dirty() then
local push = _G.cmd_push_infer
if push then pcall(push) end
end
if pull_active() then pcall(pull_step) end
if not S.connected then
if net_ready() then
local ok, err = try_connect()
if not ok then
if err == "no sn" then
log.warn("iot", "no sn, skip")
if sys then sys.wait(10000) end
else
local is_oom = type(err) == "string" and err:lower():find("memory") ~= nil
local wait_s = is_oom and 30 or S.backoff
if is_oom then




collector.trim_cache()
mon.trim_reqs()
collectgarbage("collect")
local h1, h2 = heap_info()
log.warn("iot", "oom, trim+gc done, heap total=" .. tostring(h1) .. " used=" .. tostring(h2))
else
S.backoff = math.min(S.backoff * 2, 60)
end
S.last_err = err
wait_kickable(wait_s * 1000)
end
end
else
wait_kickable(10000)
end
else



local t0 = os.clock()



























if (os.clock() - (S.gc_at or -1e9)) >= 10 then
local kb = collectgarbage("count")
if kb > 160 then
collectgarbage("collect")
S.gc_at = os.clock()
S.gc_trig = (S.gc_trig or 0) + 1
end
end



if (os.clock() - (S.trim_at or -1e9)) >= 15 then
pcall(collector.trim_cache)
pcall(mon.trim_reqs)
collectgarbage("collect")
collectgarbage("collect")
S.trim_at = os.clock()
local h1, h2 = heap_info()
log.info("iot", "periodic trim+gc, heap total=" .. tostring(h1) .. " used=" .. tostring(h2))
end
if S.recv_pending then
local rp = S.recv_pending
S.recv_pending = nil
pcall(handle_downlink, rp.topic, rp.payload)
end
refresh_subs()
local c = mqttcfg.load()
local pub_platform = should_pub_platform()
local pub_meta = should_pub_meta()
local pub_topo = should_pub_topo()














if pubsched.due("prop", c.interval_s) then publish() end


S.busy_s = (S.busy_s or 0) + (os.clock() - t0)
S.span_s = (S.span_s or 0) + (os.clock() - t0) + 1.0








if pub_meta then
local msig = meta_sig()




if msig and msig ~= S.meta_sig then pubsched.changed("meta") end
if pubsched.due("meta", c.interval_s) then
local ok, e = send_meta()
if ok then
S.meta_sig = msig
S.meta_at = os.time()
pubsched.sent("meta")
log.info("iot", "gw meta posted: " .. (msig or "due " .. c.interval_s))
else
log.info("iot", "gw meta skip: " .. tostring(e))
end
end
end

if pub_meta and (os.time() - (S.res_at or 0)) >= c.interval_s then
send_gw_res()
end

if pub_platform then




if S.hello_at == 0 and not pulling() then
log.info("iot", "hello on connect, mode=" .. get_mode())
pcall(send_hello)
elseif S.hello_at and S.hello_at > 0 and get_mode() == "platform"
and not pulling()
and (os.time() - S.hello_at) >= cfg.HELLO_RE_S then
log.info("iot", "hello re-send (30min), mode=platform")
pcall(send_hello)
end











local sig = nil
local nodes_json = nil
local prop_ids = nil  -- topo-ack-filter: 拓扑里的属性 ID 列表























if pub_topo and not pub_blocked() then
if pubsched.ready("topo") then

local cur_pids = {}
local cur_slaves = {}  -- V2: 收集从机 ID
local smap = cfgstore.alias_map()
local mode = get_mode()
if mode == "sniff" then
for _, r in ipairs((mon.infer() or {}).regs or {}) do
local sa = smap["reg" .. tostring(r.addr or "")]
local id = (sa and sa.id ~= "" and sa.id) or "reg" .. tostring(r.addr or "")
cur_pids[id] = true
if r.slave then cur_slaves[r.slave] = true end  -- V2
end
local pc = cfgstore.load_pull()
for _, r in ipairs((pc and pc.regs) or {}) do
local id, _ = prop_id_name(r)
cur_pids[id] = true
if pc.slave then cur_slaves[pc.slave] = true end  -- V2
end
else
local c = active_cfg()
if c and c.regs then
for _, r in ipairs(c.regs) do
local id, _ = prop_id_name(r)
cur_pids[id] = true
end
if c.slave then cur_slaves[c.slave] = true end  -- V2
end
end
local pid_list = {}
for id in pairs(cur_pids) do pid_list[#pid_list + 1] = id end
table.sort(pid_list)

local slave_list = {}
for s in pairs(cur_slaves) do slave_list[#slave_list + 1] = tostring(s) end
table.sort(slave_list)
local prop_sig = table.concat(pid_list, ",") .. "|slave=" .. table.concat(slave_list, ",")

log.info("iot", "topo check: cur=" .. #pid_list .. " cached_sig=" .. tostring(S.topo_prop_sig and "yes" or "no") .. " sent_sig=" .. tostring(S.topo_sent_sig and "yes" or "no"))
local need_rebuild = true
if prop_sig == S.topo_prop_sig and S.topo_sent_sig then
sig = S.topo_sent_sig
prop_ids = S.topo_prop_ids
need_rebuild = false
log.info("iot", "topo skip: sig unchanged (cur=" .. #pid_list .. ")")
else
log.info("iot", "topo rebuild: sig changed (cur=" .. #pid_list .. ")")
end
if need_rebuild then



local new_props = {}
local has_new = false
if S.topo_sent_props then
for _, id in ipairs(pid_list) do
if not S.topo_sent_props[id] then
new_props[id] = true
has_new = true
end
end
else

for _, id in ipairs(pid_list) do
new_props[id] = true
end
has_new = true
end
if has_new then
local ok, s, n, pids = pcall(topo_sig, new_props)
if ok then
sig = s
nodes_json = n
prop_ids = pids
S.topo_at = os.clock()

S.topo_prop_ids = prop_ids
log.info("iot", "topo rebuilt: props=" .. #pids .. " sig=" .. tostring(s))



local new_list = {}
for id in pairs(new_props) do new_list[#new_list + 1] = id end
table.sort(new_list)  -- 排序保证分批顺序稳定
local total_new = #new_list
local batch_start = 1
local batch_num = 0
local all_batches_ok = true
while batch_start <= total_new do
batch_num = batch_num + 1
local batch_end = math.min(batch_start + TOPO_BATCH_SIZE - 1, total_new)
local batch_ids = {}
for i = batch_start, batch_end do
batch_ids[new_list[i]] = true
end

local batch_parts, batch_pids
local ok2, s2, n2, p2 = pcall(topo_sig, batch_ids)
if ok2 then
batch_parts = n2
batch_pids = p2
else
log.warn("iot", "batch " .. batch_num .. " topo_sig failed: " .. tostring(s2))
all_batches_ok = false
break
end
if batch_parts then
local pok, sent, e = pcall(send_topo, batch_parts)
if pok and sent then
S.topo_sent_props = S.topo_sent_props or {}
for _, id in ipairs(batch_pids) do
S.topo_sent_props[id] = true
end

S.topo_ack_props = S.topo_ack_props or {}
for _, id in ipairs(batch_pids) do
S.topo_ack_props[id] = true
end
log.info("iot", "topology posted (batch " .. batch_num
.. "): parts=" .. #batch_parts
.. " bytes=" .. topo.len(batch_parts)
.. " props=" .. #batch_pids
.. "/" .. total_new)
else
S.topo_fail_at = os.clock()
S.topo_fail_n = (S.topo_fail_n or 0) + 1
all_batches_ok = false
log.info("iot", "topology batch " .. batch_num .. " failed: "
.. tostring(e or sent))
break  -- 本批失败，停止后续批次
end
end

collectgarbage("collect")
batch_start = batch_end + 1

if batch_start <= total_new and sys then
sys.wait(2000)
end
end

if all_batches_ok then
S.topo_sig = sig
S.topo_sent_at = os.clock()
S.topo_fail_at = nil
S.topo_fail_n = 0
S.topo_sent_sig = sig
S.topo_prop_sig = prop_sig  -- V2: 全部批次成功后才更新签名
pubsched.sent("topo")
end
else
S.build_fail = (S.build_fail or 0) + 1
log.warn("iot", "topo_sig failed, skip this round: " .. tostring(s))
end
else

need_rebuild = false
end
end
end
end
local backoff = math.min(10 * (3 ^ ((S.topo_fail_n or 1) - 1)), 60)
if S.topo_fail_at and (os.clock() - S.topo_fail_at) > backoff then
log.info("iot", "topology retry after " .. backoff
.. "s backoff (fail_n=" .. (S.topo_fail_n or 0) .. ")")
S.topo_sig = nil
S.topo_fail_at = nil
end
end  -- if pub_platform end






if should_pub_topo() and mqttcfg.load().manual_on then
if pubsched.due("topo", cfg.TOPO_REBUILD_MS / 1000) then
local sig, parts, pids = topo_sig()
if sig and sig ~= S.topo_sig then
local pok, sent, e = pcall(send_topo, parts)
if pok and sent then
S.topo_ack_props = S.topo_ack_props or {}
for _, id in ipairs(pids) do
S.topo_ack_props[id] = true
end
S.topo_sent_at = os.clock()
log.info("iot", "topo posted (manual mqtt): props=" .. #pids)
else
S.topo_fail_at = os.clock()
S.topo_fail_n = (S.topo_fail_n or 0) + 1
end
end
end
end



if get_mode() ~= "idle" and pubsched.due("topo_keepalive", c.interval_s) then
local pok, sent, e = pcall(send_topo, nil, true)
if pok and sent then
pubsched.sent("topo_keepalive")
log.info("iot", "topo keepalive posted (empty)")
else
log.warn("iot", "topo keepalive failed: " .. tostring(e))
end
end

if (os.clock() - (S.census_at or -1e9)) >= 30 then
S.census_at = os.clock()
local cok, cerr = pcall(census)
if not cok then log.warn("iot", "census failed: " .. tostring(cerr)) end
end
if sys then sys.wait(1000) end



if lbsLoc2 and (os.time() - (S.lbs_at or 0)) >= 1800 then
local r = lbs_request()
S.lbs_at = os.time()
if r then S.lbs = r end
end





























end
end
end

function M.init()
collector.on_update(function()





S.dirty = true
pubsched.changed("prop")
end)
return true
end

function M.start()
if S.want_run then
log.warn("iot", "already started")
return false
end
reset_state()
S.want_run = true
if sys then











sys.taskInit(function()
while true do
local want = S.want_run
local ok, err = pcall(task_main)
if ok then break end          -- 正常退出(want_run=false)
log.warn("iot", "task_main error, restart: " .. tostring(err))
S.want_run = want              -- 恢复用户原本的意图
if not want then break end
pcall(collector.trim_cache)
pcall(mon.trim_reqs)
collectgarbage("collect")
if sys then sys.wait(1000) end
end
end)
end
log.info("iot", "started")
return true
end

function M.is_running() return S.want_run end



function M.is_connected() return S.connected == true end

function M.report_now()
return publish()
end

function M.kick()
destroy_client()
S.backoff = 1
S.kick_flag = true
end

function M.apply_cfg(c)
local ok, err = mqttcfg.save(c)
if not ok then return false, err end
M.kick()
return true
end

function M.status()
local c = mqttcfg.load()


local prof = mqttcfg.profile(device_id())
return {
want_run = S.want_run,
connected = S.connected,
subscribed = S.subscribed,
device_id = S.device_id,
client_id = S.client_id or (c.client_id ~= "" and c.client_id or default_client_id(device_id())),
user = S.user or ((prof and prof.user ~= "" and prof.user) or device_id()),






pub = (S.pub and S.pub ~= "") and S.pub or (prof and prof.pub),
sub = (S.sub and S.sub ~= "") and S.sub or (prof and prof.sub),



pub_topics = prof and prof.pub_topics,







sub_list = build_subs(),
keep_session = c.keep_session,
manual_on = c.manual_on,
host = c.host,
port = c.port,
interval_s = c.interval_s,
qos = c.qos,
published = S.published,
failed = S.failed,
replied = S.replied,
subs = S.subs,
backoff = S.backoff,
dirty = S.dirty,



pub = pubsched.status(),
last_pub = S.last_pub,
last_err = S.last_err,
reject_reason = S.reject_reason,




push_n = S.push_n,
push_seen = S.pull.seen,
push_err = S.push_err,
autosaved = S.autosaved,
autosave_at = S.autosave_at,
autosave_regs = S.autosave_regs,
sn = _G.get_device_sn and tostring(_G.get_device_sn()) or nil,
heap = (function() local a, b = heap_info(); return { total = a, used = b } end)(),





lua_kb = lua_kb(),
}
end

reset_state()

return M
