local util = require "util"
local cfg = require "core/config"
local log = util.log()

local uart = util.try("uart")  -- try 而非 get: 纯 Lua 环境也能加载 (单测); start 时判空
local gpio = util.try("gpio")
local sys = util.try("sys")

local guard = util.try("svc/guard")

local mbus = require "bus/mbus"
local collector = require "data/collector"

local M = {}

local running, gen = false, 0
local rxbuf = ""
local pendingReqs, lastReqs = {}, {}
local lastRx, lastBaud = 0, nil

local detecting, detectGen = false, 0





local forceStop = false


local bootCfg = nil

local DETECT_RETRY_MS = 3000



local MAX_PENDING_PER_FC = 4




local function sniff_wait(ms)
local t = 0
while t < ms do
if forceStop or not running then return false end


if guard then guard.alive() end
if sys then sys.wait(20) end
t = t + 20
end
return not forceStop and running
end




local MAX_LAST_REQ = 64
local PAIR_TIMEOUT_MS = 250






















local MAX_INFER_ROWS = 128
local stat = { frames = 0, reqs = 0, rsps = 0, errs = 0, paired = 0, orphans = 0,
detect_round = 0, detect_fail = 0, infer_clamped = 0, rx_bytes = 0 }












local infer_acc = {}
local infer_order = {}
local infer_dirty = false
local infer_watch = false


local merged_addrs = {}




local try_baud = nil
local try_parity = nil






local tried = {}

local function key(slave, qty) return tostring(slave) .. ":" .. tostring(qty) end









local function acc_row(slave, addr, fc)
local sl = infer_acc[slave]
if not sl then sl = {}; infer_acc[slave] = sl end
local a = sl[addr]
if a then
if a.fc == nil and fc then a.fc = fc end
return a
end
if #infer_order >= MAX_INFER_ROWS then
stat.infer_clamped = stat.infer_clamped + 1
return nil
end

a = { slave = slave, addr = addr, fc = fc,
hits = 0, answered = false,
dtype = "uint16", conf = 0, value = nil,
name = "", id = "reg" .. tostring(addr) }
sl[addr] = a
infer_order[#infer_order + 1] = a
infer_dirty = true
return a
end





local function acc_note_req(slave, addr, qty, fc)
local j = 0
while j < qty do
local a = acc_row(slave, addr + j, fc)
if not a then break end   -- 超上限: 不再展开(免得死循环)
a.hits = a.hits + 1
j = j + 1
end
end





local function acc_note_rsp(slave, addr, v, dtype, conf)
local a = acc_row(slave, addr, nil)
if not a then return end
a.answered = true
a.value = v
a.dtype = dtype
a.conf = conf
end

local function push_req(f)
local q = pendingReqs[f.fc]
if not q then q = {}; pendingReqs[f.fc] = q end
q[#q + 1] = { fc = f.fc, slave = f.slave, addr = f.addr, qty = f.qty, ts = os.clock() }
while #q > MAX_PENDING_PER_FC do table.remove(q, 1) end
lastReqs[key(f.slave, f.qty)] = { fc = f.fc, slave = f.slave, addr = f.addr, qty = f.qty, ts = os.clock() }


local n = 0
for _ in pairs(lastReqs) do n = n + 1 end
if n > MAX_LAST_REQ then lastReqs = {} end


if f.addr ~= nil and f.qty then
acc_note_req(f.slave, f.addr, util.clamp_qty(f.qty), f.fc)
end
end

local function guess_last_req(fc, slave, qty)
if not qty then return nil end
local r = lastReqs[key(slave, qty)]
if not r or r.fc ~= fc then return nil end
if (os.clock() - r.ts) > 10 then return nil end
return r
end







local function pop_req(fc, slave, qty, now)
local q = pendingReqs[fc]
if not q then return nil end
while #q > 0 and (now - q[1].ts) > (PAIR_TIMEOUT_MS / 1000) do
table.remove(q, 1)
end
for i = #q, 1, -1 do
local r = q[i]
if r.slave == slave and r.qty == qty then
table.remove(q, i)
return r
end
end
return nil
end






















local DT_CODE = { int16 = 1, uint16 = 2, int32 = 3, uint32 = 4, float32 = 5 }
local HIST_DEPTH = 5
local HIST_MASK = 16 ^ HIST_DEPTH      -- 1048576 (16^5) —— pushHistory 的窗口



local HIST_SEED_MOD = 16 ^ 8            -- 4294967296 (double 里精确)
local dtypeHistory = {}  -- alias -> 打包数(最近 5 帧的 dtype 码)








local MAX_HIST_ALIAS = 128
local histOrder = {}   -- alias 的插入顺序, 用来淘汰最旧的

local function pushHistory(alias, dtype)
local code = DT_CODE[dtype]
if not code then return end          -- 不认识的 dtype 不进历史
local old = dtypeHistory[alias]

dtypeHistory[alias] = ((old or 0) * 16 + code) % HIST_MASK
if old == nil then

histOrder[#histOrder + 1] = alias
while #histOrder > MAX_HIST_ALIAS do
dtypeHistory[table.remove(histOrder, 1)] = nil
end
end
end







local function clear_history()
dtypeHistory = {}
histOrder = {}
end




local function calcContinuity(alias, cand)
local h = dtypeHistory[alias]
if not h or h == 0 then return 50 end  -- 首帧不给满分也不给 0, 中性
local code = DT_CODE[cand]
if not code then return 0 end           -- 不认识的类型: 跟旧实现一样算 0 命中
local same, total = 0, 0
local t = h
while t > 0 do
local d = t % 16
total = total + 1
if d == code then same = same + 1 end
t = math.floor(t / 16)
end
if total == 0 then return 50 end
return math.floor(same / total * 100)
end


local function calcRange(dtype, v)
if v == nil then return 0 end
if dtype == "int16" and v >= -32768 and v <= 32767 then return 100
elseif dtype == "uint16" and v >= 0 and v <= 65535 then return 100
elseif dtype == "int32" and v >= -2147483648 and v <= 2147483647 then return 100
elseif dtype == "uint32" and v >= 0 and v <= 4294967295 then return 100
elseif dtype == "float32" then



if v == v and v ~= 1/0 and v ~= -1/0
and (v == 0 or (math.abs(v) >= cfg.DTYPE_FLOAT_MIN and math.abs(v) <= cfg.DTYPE_FLOAT_MAX)) then
return 100
end
return 0
end
return 0  -- 超出类型范围, 排除
end


local function calcBoundary(dtype, v)
if v == nil then return 0 end
if dtype == "float32" then return 80 end  -- float 不强求, 不跟整数边界同分
local lo, hi, av
if dtype == "int16" then lo, hi, av = -32768, 32767, 0
elseif dtype == "uint16" then lo, hi, av = 0, 65535, 32767
elseif dtype == "int32" then lo, hi, av = -2147483648, 2147483647, 0
elseif dtype == "uint32" then lo, hi, av = 0, 4294967295, 2147483647
else lo, hi, av = 0, 0, 0 end
local range = hi - lo
local dist = math.abs(v - av) / (range / 2)
if dist > 1 then dist = 1 end
local b = math.floor(dist * 100)




if (dtype == "uint32" or dtype == "int32") and math.abs(v) > cfg.DTYPE_INT32_SUSPECT then
if b > 30 then b = 30 end
end
return b
end


local function score(data, off, dtype, word_swap, alias)
local v = mbus.parse_value(data, off, dtype, word_swap)
local range = calcRange(dtype, v)
if range == 0 then return nil, nil, 0 end
local cont = calcContinuity(alias, dtype)
local bnd = calcBoundary(dtype, v)
local conf = math.floor(cont * 0.5 + range * 0.3 + bnd * 0.2)

local h = dtypeHistory[alias]
if h and h ~= 0 and (h % 16) == DT_CODE[dtype] then conf = conf + 5 end
if conf > 100 then conf = 100 end
return dtype, v, conf
end









local CAND16 = { "int16", "uint16" }
local CAND32 = { "int32", "uint32", "float32" }
local CANDWS = { false, true }



local function pickDtype(data, off, remaining, addr, slave, f)
local alias = collector.alias_of(addr + off)  -- 不带 s<slave>_ 前缀(12-fix-7: 缓存串)

local bestD, bestV, bestC = "uint16", 0, 0
for _, d in ipairs(CAND16) do
local _, v, c = score(data, off, d, nil, alias)
if c > bestC then bestD, bestV, bestC = d, v, c + 5 end  -- 16bit +5 优先
end
if bestC > 100 then bestC = 100 end

if remaining >= 2 then
local c32 = 0
local d32, v32 = "uint32", 0
for _, d in ipairs(CAND32) do
for _, ws in ipairs(CANDWS) do
local _, v, c = score(data, off, d, ws, alias)
if c > c32 then c32, d32, v32 = c, d, v end
end
end

if c32 > bestC then
return d32, v32, c32, true  -- 第 4 个参数 true = 32bit 合并
end
end
return bestD, bestV, bestC, false
end




M.calc_range = calcRange
M.calc_boundary = calcBoundary
M.pick_dtype = pickDtype
M.clear_history = clear_history
M.seed_history = function(alias, list)


if type(list) == "number" then
dtypeHistory[alias] = list % HIST_SEED_MOD
return
end
local h = 0
if type(list) == "table" then
for _, d in ipairs(list) do
local c = DT_CODE[d]
if c then h = (h * 16 + c) % HIST_SEED_MOD end
end
end
dtypeHistory[alias] = h
end

local function push_rsp_value(slave, addr, f)
if not f.data or not addr then return end
local total = math.floor(#f.data / 2)
local i = 0




local lastMergedDtype = nil
while i < total do
local remaining = total - i
if lastMergedDtype and remaining >= 2 then

local alias0 = collector.alias_of(addr + i)
local v = mbus.parse_value(f.data, i, lastMergedDtype, false)


collector.push_data(addr + i, alias0, f.hex, v, nil,
lastMergedDtype, 100, "ok")

acc_note_rsp(slave, addr + i, v, lastMergedDtype, 100)
pushHistory(alias0, lastMergedDtype)
merged_addrs[addr + i + 1] = true
i = i + 2
else
local dtype, v, conf, merged32 = pickDtype(f.data, i, remaining, addr, slave, f)
local alias0 = collector.alias_of(addr + i)
local status
if conf >= 80 then status = "ok"
elseif conf >= 60 then status = "review"
else status = "uncertain" end
collector.push_data(addr + i, alias0, f.hex, v, nil, dtype, conf, status)
acc_note_rsp(slave, addr + i, v, dtype, conf)
pushHistory(alias0, dtype)
if merged32 then


lastMergedDtype = dtype
merged_addrs[addr + i + 1] = true
i = i + 2
else

lastMergedDtype = nil
i = i + 1
end
end
end
end







local function process_frame(f)
stat.frames = stat.frames + 1
local pair_state, paired_addr = nil, nil
if f.kind == "err" then
stat.errs = stat.errs + 1
pair_state = "err"
elseif f.kind == "rsp" then
stat.rsps = stat.rsps + 1


local hit = pop_req(f.fc, f.slave, f.qty, os.clock()) or guess_last_req(f.fc, f.slave, f.qty)
if hit then
stat.paired = stat.paired + 1
pair_state, paired_addr = "paired", hit.addr
push_rsp_value(f.slave, hit.addr, f)
else
stat.orphans = stat.orphans + 1
pair_state = "orphan"
end
elseif f.kind == "req" then
stat.reqs = stat.reqs + 1
push_req(f)
pair_state = "req"
end
f.pair_state = pair_state
f.paired_addr = paired_addr
f.paired_qty = f.qty
collector.push_raw_rx(f.hex)






f.data = nil
f.raw = nil
collector.push_frame(f)
end

local function on_receive(id, len)
if id ~= mbus.UART_ID then return end
if type(len) ~= "number" or len <= 0 then return end
while true do
local ok, data = pcall(uart.read, id, 512)
if not ok then return end
if type(data) ~= "string" or #data == 0 then break end
rxbuf = rxbuf .. data
lastRx = os.time()






stat.rx_bytes = stat.rx_bytes + #data
if #rxbuf > 256 then rxbuf = rxbuf:sub(-128) end
end
end








local function next_frame()
for off = 1, #rxbuf do
local s = rxbuf:sub(off)
local n = mbus.try_extract_len(s)
if n and #s >= n then
local raw = s:sub(1, n)
local f = mbus.decode_frame(raw, collector.take_frame())
if f then
rxbuf = s:sub(n + 1)
return f
end
end
end
return nil
end

local function task()
local mygen = gen
while running and gen == mygen do

if guard then guard.alive() end
local s = next_frame()
if s then






local ok, err = pcall(process_frame, s)
if not ok then
stat.errs = (stat.errs or 0) + 1
stat.alloc_err = (stat.alloc_err or 0) + 1

if not stat.alloc_err_logged then
stat.alloc_err_logged = true
log.warn("mon", "frame process failed (堆不足?), 丢帧继续: " .. tostring(err))
end
end
elseif #rxbuf > 0 then


if #rxbuf < 5 then
if sys then sys.wait(20) end
else
rxbuf = rxbuf:sub(2)
end
elseif sys then
sys.wait(20)
end
end
end









local infer_cache = nil
local infer_cache_at = 0
local INFER_CACHE_S = 2

function M.infer(force)
if not force and infer_cache and (os.clock() - infer_cache_at) < INFER_CACHE_S then
return infer_cache
end











local regs, slaves, ignored = {}, {}, 0
for _, a in ipairs(infer_order) do

if not merged_addrs[a.addr] then
if not a.answered then ignored = ignored + 1 end
slaves[a.slave] = true
regs[#regs + 1] = a
end
end
local sl = {}
for s in pairs(slaves) do sl[#sl + 1] = s end
table.sort(sl)
local result = {
regs = regs,
slaves = sl,

ignored = ignored,
stat = stat,
}
infer_cache = result
infer_cache_at = os.clock()
return result
end















local INFER_PAGE_MAX = 32


local infer_view_off = 0
local infer_view_n = INFER_PAGE_MAX

function M.set_infer_view(off, n)
off = tonumber(off) or 0
n = tonumber(n) or INFER_PAGE_MAX
if off < 0 then off = 0 end
off = math.floor(off)
if n < 1 then n = 1 end
if n > INFER_PAGE_MAX then n = INFER_PAGE_MAX end
infer_view_off = off
infer_view_n = n
end

function M.infer_view()
return infer_view_off, infer_view_n
end




function M.infer_page(off, n)
off = tonumber(off) or 0
n = tonumber(n) or INFER_PAGE_MAX
if off < 0 then off = 0 end
off = math.floor(off)
if n < 0 then n = 0 end
n = math.floor(n)
if n == 0 then n = INFER_PAGE_MAX end
if n > INFER_PAGE_MAX then n = INFER_PAGE_MAX end
local total = #infer_order

local valid_order = {}
for i = 1, total do
local a = infer_order[i]
if not merged_addrs[a.addr] then
valid_order[#valid_order + 1] = a
end
end
total = #valid_order
if off > total then off = total end
local last = off + n
if last > total then last = total end
local regs, slaves = {}, {}
local ignored = 0


for i = 1, total do
local a = valid_order[i]
if not a.answered then ignored = ignored + 1 end
slaves[a.slave] = true
end
for i = off + 1, last do
regs[#regs + 1] = valid_order[i]
end
local sl = {}
for s in pairs(slaves) do sl[#sl + 1] = s end
table.sort(sl)
local pages = 1
if total > 0 then pages = math.ceil(total / n) end
return {
regs = regs,
slaves = sl,
ignored = ignored,
stat = stat,
total = total,
off = off,
n = n,
pages = pages,
page = (n > 0) and (math.floor(off / n) + 1) or 1,
}
end

function M.start(c)
if running then return true end
if not uart then return nil, "no uart" end  -- uart 弱加载后的判空 (设备恒有)


clear_history()

collector.clear_all()
infer_cache = nil   -- 12-fix: 缓存是上一轮帧推断出来的, 新一轮必须重算



infer_acc = {}
infer_order = {}
infer_dirty = true

merged_addrs = {}

infer_view_off = 0
infer_view_n = INFER_PAGE_MAX
_G.mon_detect_result = nil




tried = {}

pendingReqs, lastReqs = {}, {}


forceStop = false


c = c or { baud = cfg.BAUD, databits = cfg.DATABITS, stopbits = cfg.STOPBITS, parity = cfg.PARITY }
if gpio then
pcall(gpio.setup, mbus.DE_PIN, 0)
pcall(gpio.set, mbus.DE_PIN, 0)
end
local ok, err = pcall(uart.setup, mbus.UART_ID, c.baud or cfg.BAUD,
c.databits or cfg.DATABITS, c.stopbits or cfg.STOPBITS,
mbus.parity_to_uart(c.parity or cfg.PARITY))
if not ok then
log.error("mon", "setup failed:", tostring(err))
return false
end
bootCfg = c
lastBaud = c.baud or cfg.BAUD
pcall(uart.on, mbus.UART_ID, "receive", on_receive)
running = true
gen = gen + 1
if sys then sys.taskInit(task) end
log.info("mon", "sniff started")
return true
end


function M.trim_reqs() lastReqs = {} end



local function restore_params()
local c = bootCfg or { baud = cfg.BAUD, databits = cfg.DATABITS, stopbits = cfg.STOPBITS, parity = cfg.PARITY }
pcall(uart.setup, mbus.UART_ID, c.baud or cfg.BAUD,
c.databits or cfg.DATABITS, c.stopbits or cfg.STOPBITS,
mbus.parity_to_uart(c.parity or cfg.PARITY))
pcall(uart.on, mbus.UART_ID, "receive", on_receive)
lastBaud = c.baud or cfg.BAUD
end









function M.auto_detect()
if not sys then return nil, "no sys" end
if not running and not M.start() then return nil, "start fail" end


forceStop = false




log.info("mon", "auto_detect: wait " .. tostring(cfg.DETECT_SETTLE_MS)
.. "ms for 142 UART stable")
if not sniff_wait(cfg.DETECT_SETTLE_MS) then return nil, "stopped" end
for _, p in ipairs({ 0, 1, 2 }) do
for _, b in ipairs(cfg.DETECT_BAUDS) do




local ckey = tostring(b) .. ":" .. tostring(p)
if not tried[ckey] then
tried[ckey] = true



pcall(uart.close, mbus.UART_ID)
if not sniff_wait(500) then return nil, "stopped" end
rxbuf = ""
local ok = pcall(uart.setup, mbus.UART_ID, b, 8, 1, mbus.parity_to_uart(p))
if ok then
pcall(uart.on, mbus.UART_ID, "receive", on_receive)

try_baud, try_parity = b, p


if b >= 19200 then
if not sniff_wait(200) then return nil, "stopped" end
end





local before_frames = stat.frames
local before_bytes = stat.rx_bytes
if not sniff_wait(cfg.DETECT_WIN_MS) then return nil, "stopped" end




log.info("mon", "check baud=" .. b .. " p=" .. p
.. " frames=" .. tostring(stat.frames - before_frames)
.. " bytes=" .. tostring(stat.rx_bytes - before_bytes)
.. " paired=" .. tostring(stat.paired)
.. " rxbuf=" .. tostring(#rxbuf)
.. " last_rx=" .. tostring(lastRx))


if stat.frames > before_frames then
lastBaud = b
try_baud, try_parity = nil, nil
log.info("mon", "detect ok: baud=" .. b .. " parity=" .. p)
return { baud = b, databits = 8, stopbits = 1, parity = p }
end
end
if not running or forceStop then return nil, "stopped" end
end
end
end



try_baud, try_parity = nil, nil
restore_params()
log.warn("mon", "detect silent fail: all candidates tried, fallback cfg.BAUD=" .. cfg.BAUD)
return { baud = cfg.BAUD, databits = cfg.DATABITS,
stopbits = cfg.STOPBITS, parity = cfg.PARITY,
fallback = true }
end





local function detect_loop()
local mydgen = detectGen
while running and detectGen == mydgen do
detecting = true
stat.detect_round = stat.detect_round + 1
local r = M.auto_detect()
if detectGen ~= mydgen or not running then return end
if r then
detecting = false
_G.mon_detect_result = r

if r.fallback then
log.warn("mon", "detect silent fail, sniff running with cfg.BAUD fallback")
else
log.info("mon", "detect ok, sniff ready")
end
return
end
stat.detect_fail = stat.detect_fail + 1
log.warn("mon", "detect round " .. stat.detect_round .. " no hit, retry in "
.. DETECT_RETRY_MS .. "ms")

if not sniff_wait(DETECT_RETRY_MS) then return end
end
end



function M.request_detect()
if not running then return false, "not running" end
detectGen = detectGen + 1
_G.mon_detect_result = nil
if sys then sys.taskInit(detect_loop) end
return true
end


function M.restart_detect()
if not running then return false, "not running" end
collector.clear_all()
tried = {}   -- 12-fix-2: 用户主动重来 = 从头扫, 候选记忆清零

infer_acc = {}
infer_order = {}
infer_dirty = true
merged_addrs = {}
_G.mon_detect_result = nil
return M.request_detect()
end

function M.is_detecting() return detecting end

function M.detect_result() return _G.mon_detect_result end

function M.stop()
if not running then return true end


detecting = false
running = false
gen = gen + 1

forceStop = true



if gpio then pcall(gpio.set, mbus.DE_PIN, 0) end
pcall(uart.on, mbus.UART_ID, "receive", nil)
pcall(uart.close, mbus.UART_ID)
rxbuf = ""
pendingReqs, lastReqs = {}, {}
infer_cache = nil   -- 12-fix: 帧都清了, 缓存的推断结果必须一起作废

infer_acc = {}
infer_order = {}
infer_dirty = true

merged_addrs = {}

infer_view_off = 0
infer_view_n = INFER_PAGE_MAX
clear_history()     -- 12-fix-3: dtype 判型历史也清(原来只有 start 清)
try_baud, try_parity = nil, nil   -- 12-fix-2: 别把"在试什么"留在状态里
tried = {}                        -- 12-fix-2: 候选记忆也作废


collector.clear_all()
_G.mon_detect_result = nil
log.info("mon", "sniff stopped")
return true
end

function M.is_running() return running end

function M.status()
local st = {}
for k, v in pairs(stat) do st[k] = v end
st.running = running
st.gen = gen
st.baud = lastBaud or cfg.BAUD

st.detecting = detecting
st.detected = _G.mon_detect_result
st.pending = (function()
local n = 0
for _, q in pairs(pendingReqs) do n = n + #q end
return n
end)()
st.last_rx = lastRx
st.buf = #rxbuf



st.try_baud = try_baud
st.try_parity = try_parity


st.rx_bytes = stat.rx_bytes





st.hist_aliases = #histOrder


st.infer_rows = #infer_order

st.infer_view_off = infer_view_off
st.infer_view_n = infer_view_n
return st
end










function M.set_infer_watch(on)
infer_watch = on and true or false


if infer_watch then infer_dirty = true end
return infer_watch
end

function M.infer_watch() return infer_watch end



function M.take_infer_dirty()
if not infer_dirty then return false end
infer_dirty = false
return true
end



M.test_note_req = acc_note_req
M.test_note_rsp = acc_note_rsp



M.test_push_history = pushHistory
M.test_reset_acc = function()
infer_acc = {}
infer_order = {}
infer_dirty = false
stat.infer_clamped = 0
infer_view_off = 0
infer_view_n = INFER_PAGE_MAX
end

function M.recent_frames(n)
local fs = collector.get_frames()
local out = {}
for i = math.max(1, #fs - (n or 10) + 1), #fs do out[#out + 1] = fs[i] end
return out
end



function M.load_infer(regs, slave)
if type(regs) ~= "table" then return end
slave = tonumber(slave) or 1

infer_acc = {}
infer_order = {}
infer_dirty = true
merged_addrs = {}

for _, r in ipairs(regs) do
if type(r) == "table" and r.addr then
local a = acc_row(slave, r.addr, r.fc)
if a then
a.dtype = r.dtype or "uint16"
a.name = r.name or ""
a.id = r.id or ""
a.conf = 100  -- 持久化的是已确认的数据
a.answered = true
a.hits = 1

local count = r.count or 1
if count >= 2 then
for j = 1, count - 1 do
merged_addrs[r.addr + j] = true
end
end
end
end
end
log.info("mon", "loaded infer table from persist, slave=" .. slave .. " rows=" .. #infer_order)
end


function M.update_row_name(addr, name, id, dtype)
for _, a in ipairs(infer_order) do
if a.addr == addr then
a.name = name or ""
a.id = id or ""
if dtype and dtype ~= "" then a.dtype = dtype end
infer_dirty = true
return true
end
end
return false
end


local auto_save_timer = nil
local AUTO_SAVE_INTERVAL_MS = 30000  -- 30 秒


local function do_save_infer()
if not running or #infer_order == 0 then return end
local cfgstore = require "cfg"
if not cfgstore then return end
local detect_result = _G.mon_detect_result
if not detect_result then return end

local save_data = {
baud = detect_result.baud,
databits = detect_result.databits or 8,
stopbits = detect_result.stopbits or 1,
parity = detect_result.parity or 0,
slave = 1,  -- 默认值，下面会从 infer_order 里取实际值
regs = {},
}

if #infer_order > 0 and infer_order[1].slave then
save_data.slave = infer_order[1].slave
end
for _, r in ipairs(infer_order) do
if not merged_addrs[r.addr] then
save_data.regs[#save_data.regs + 1] = {
addr = r.addr,
count = 1,  -- 32 位合并的在 merged_addrs 里, 这里只存主地址
fc = r.fc or 3,
dtype = r.dtype or "uint16",
name = r.name or "",
id = r.id or "",
}
end
end
if #save_data.regs > 0 then
local ok, err = cfgstore.save_infer(save_data)
if ok then
log.info("mon", "auto-saved infer table, regs=" .. #save_data.regs)
else
log.warn("mon", "auto-save ds_infer failed: " .. tostring(err))
end
end
end


function M.start_auto_save()
if auto_save_timer then return end
local sys = require "sys"
if not sys then return end
auto_save_timer = sys.taskInit(function()
while running do
sys.wait(AUTO_SAVE_INTERVAL_MS)
if running then
pcall(do_save_infer)
end
end
end)
log.info("mon", "auto-save timer started")
end


function M.stop_auto_save()
auto_save_timer = nil

log.info("mon", "auto-save timer stopped")
end

return M
