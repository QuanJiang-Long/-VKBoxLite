-- test_poll_slave.lua —— 485 总线级测试: 真 bus/poll + 真 bus/mbus + 假 485 从站
--
-- 为什么要有它 (2026-11-11):
--   128 点位要过四道门, 第三道是【总线时间】(每点一帧 vs 合并读)。前两道
--   (落盘 / 内存峰值)只能在设备上量, 靠 W:FS 和 R:CTRACE; 这道门不需要硬件,
--   而现场暂时没有从站设备(2026-11-10 用户确认), 所以把 poll.lua 和 mbus.lua
--   都换成【真的】, 只假 uart 和从站 —— 128 个点真的排帧、真的发 CRC 帧、
--   真的按字节数定帧、真的解码。PC 仿真器那条路走不通(UDP-UART 桥不 bind),
--   进程内从站是唯一今天就能跑的办法。
--
-- ⚠️ 只在 Lua >= 5.3 执行: bus/mbus.lua 用了 5.3 的 `//` 和 `~`(设备固件同为 5.3)。
--   tools/run_lua_tests.bat 默认挑的是 5.1, 所以本文件第一行判版本就 SKIP。
--   同时整份文件必须能被 5.1 【解析】(不出现 // ~ goto), 否则连 SKIP 都打不出来,
--   测试会算 FAIL。
--
-- 时间模型(只算总线, 不算操作系统调度):
--   主站发 N 字节   = ceil(N * (1+8+parity+stopbits) * 1000 / baud)
--   从站启动延迟    = delay_ms (规范是 3.5 字符, 便宜表计实际 5~50ms)
--   从站回 M 字节   = 同上公式
--   poll 每帧之间 sys.wait(5)、每轮 sys.wait(interval) —— 都真的等, 都计入
--   所以"轮耗时"就是固件在设备上会花掉的墙钟时间(减去 OS 调度抖动)。
--
-- 跑法 (repo root):
--   lua -e "package.path='firmware/?.lua;firmware/?/init.lua;'..package.path; dofile('tests/lua/test_poll_slave.lua')"
--   或用 5.3/5.4 的解释器; 5.1 下只打 SKIP。

local minor = tonumber((_VERSION or ""):match("5%.(%d+)")) or 0
if minor < 3 then
    print(string.format("SKIP %s (需要 Lua >= 5.3, 当前 %s: bus/mbus.lua 用了 // 和 ~)", _VERSION, _VERSION))
    os.exit(0)
end

-- ============================================================ 假总线 / 假从站

local BUS = {
    now = 0, baud = 9600, databits = 8, stopbits = 1, parity = 0,
    rx = "", pending = {}, cb = nil, tasks = {},
    tx_frames = 0, tx_bytes = 0, rx_bytes = 0,
}

local pushed, push_map, logs, alive = {}, {}, {}, 0
local slave = nil
local CURCFG = nil

local function byte_ms(n)
    local bits = 1 + BUS.databits + BUS.stopbits + (BUS.parity > 0 and 1 or 0)
    return math.ceil(n * bits * 1000 / BUS.baud)
end

local function due(t, data) BUS.pending[#BUS.pending + 1] = { t = t, data = data } end

local function flush(target)
    -- 写入是串行的(每帧必等应答), 所以 pending 天然按时间升序
    while #BUS.pending > 0 and BUS.pending[1].t <= target do
        local e = table.remove(BUS.pending, 1)
        BUS.rx = BUS.rx .. e.data
        BUS.rx_bytes = BUS.rx_bytes + #e.data
        if BUS.cb then BUS.cb(1, #e.data) end
    end
    BUS.now = target
end

local function bus_reset()
    BUS.rx = ""
    BUS.pending = {}
end

local mbus                -- 赋 _G.uart 之后才 require(见 uart_stub 下面), 下面是上值

local function exc_resp(fc, code)
    return mbus.append_crc(string.char(slave.addr, fc + 128, code))
end

-- 从站收到一帧请求 → 该回的响应字节(不模拟"半帧", 一次回完整帧)
local function slave_reply(req)
    local s = slave
    if not s then return nil end
    if s.offline then s.n_drop = s.n_drop + 1 return nil end
    if #req < 8 then return nil end
    if not mbus.crc_ok(req) then s.n_badcrc = s.n_badcrc + 1 return nil end
    if req:byte(1) ~= s.addr then return nil end          -- 不是点名的, 真从站静默
    local fc = req:byte(2)
    if fc ~= 3 then return exc_resp(fc, 1), s.delay_ms end -- 本从站只实现 fc3
    local a = req:byte(3) * 256 + req:byte(4)
    local qty = req:byte(5) * 256 + req:byte(6)
    s.n_req = s.n_req + 1
    if qty > s.peak_qty then s.peak_qty = qty end
    local q = qty
    if q > s.max_qty then
        if s.over == "exc" then return exc_resp(3, 3), s.delay_ms end
        if s.over == "trunc" then q = s.max_qty end
        -- over == "ignore": 守 125 上限的规范从站, 照量回
    end
    local d = {}
    for i = 0, q - 1 do
        local v = s.regs[a + i]
        if v == nil then
            if s.unmapped == "exc" then return exc_resp(3, 2), s.delay_ms end
            v = 0
        end
        d[#d + 1] = string.char(math.floor(v / 256) % 256, v % 256)
    end
    s.n_rsp = s.n_rsp + 1
    return mbus.append_crc(string.char(s.addr, 3, q * 2 % 256) .. table.concat(d)), s.delay_ms
end

local uart_stub = { NONE = 0, EVEN = 1, ODD = 2 }
function uart_stub.setup(id, baud, db, sb, parity)
    if baud then BUS.baud = baud end
    BUS.databits = db or 8
    BUS.stopbits = sb or 1
    BUS.parity = parity or 0
    return true
end
function uart_stub.close(id) bus_reset() return true end
function uart_stub.on(id, ev, cb)
    if ev == "receive" then BUS.cb = cb end
    return true
end
function uart_stub.write(id, s)
    if type(s) ~= "string" or #s == 0 then return 0 end
    BUS.tx_frames = BUS.tx_frames + 1
    BUS.tx_bytes = BUS.tx_bytes + #s
    local resp, dly = slave_reply(s)
    if resp then
        due(BUS.now + byte_ms(#s) + (dly or 5) + byte_ms(#resp), resp)
    end
    return #s
end
function uart_stub.read(id, n)
    n = n or 4096
    local d = BUS.rx:sub(1, n)
    BUS.rx = BUS.rx:sub(#d + 1)
    return d
end
_G.uart = uart_stub

local sys_stub = {}
function sys_stub.taskInit(fn)
    BUS.tasks[#BUS.tasks + 1] = { co = coroutine.create(fn) }
end
function sys_stub.wait(ms)
    flush(BUS.now + (ms or 0))
    if coroutine.isyieldable and coroutine.isyieldable() then coroutine.yield(ms) end
    return true
end
_G.sys = sys_stub

do
    local L = {}
    for _, k in ipairs({ "debug", "info", "warn", "error" }) do
        L[k] = function(...)
            if k ~= "debug" then
                local p = {}
                for i = 1, select("#", ...) do p[i] = tostring(select(i, ...)) end
                logs[#logs + 1] = k .. " " .. table.concat(p, " ")
            end
        end
    end
    _G.log = L
end

-- 固件模块: util / core/config / bus/mbus / bus/poll 全用真的
mbus = require "bus/mbus"   -- _G.uart 已就位, mbus 加载时 util.try("uart") 拿得到桩

package.preload["cfg"] = function()
    return { load_poll = function() return CURCFG end, load_pull = function() return nil end }
end
package.preload["data/collector"] = function()
    return { push_data = function(addr, alias, hx, value, ts, dtype)
        pushed[#pushed + 1] = { addr = addr, alias = alias, hex = hx, value = value, dtype = dtype }
        push_map[addr] = value
        return true end }
end
package.preload["svc/guard"] = function()
    return { alive = function() alive = alive + 1 end }
end

local poll = require "bus/poll"

-- ============================================================ 断言 / 已知缺陷

local failed, bugpin = 0, 0
local function check(name, ok, detail)
    if ok then
        print(string.format("ok   %s", name))
    else
        failed = failed + 1
        print(string.format("FAIL %s%s", name, detail and (": " .. tostring(detail)) or ""))
    end
end

-- 钉住【当前固件的缺陷】: 缺陷还在 → 打 KNOWN BUG(不算失败);
-- 缺陷被修好 → 这里 FAIL, 提醒把这条改成正常 check, 别让它悄悄变成回归。
local function known_bug(name, still_there, detail)
    if still_there then
        bugpin = bugpin + 1
        print(string.format("KNOWN BUG %s%s", name, detail and (" -- " .. tostring(detail)) or ""))
    else
        failed = failed + 1
        print(string.format("FAIL %s: 缺陷已修, 请把这条 known_bug 改成 check (%s)", name,
            tostring(detail)))
    end
end

local function hex_of(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- ============================================================ 场景工具

local function R(addr, count, dtype)
    return { addr = addr, count = count or 1, dtype = dtype or "uint16", name = "v" .. addr }
end

-- 从站寄存器填充: 确定性公式, 断言用的期望值也从这里独立算
local function fill_words(a0, a1)
    for a = a0, a1 do slave.regs[a] = (a * 7 + 13) % 65536 end
end
local function w16(a) return slave.regs[a] or 0 end
local function wu32(a) return w16(a) * 65536 + w16(a + 1) end

-- 把一个 float 按大端 IEEE754 塞进字表 (string.pack 5.3+, 5.1 走不到这里)
local function put_f32(a, v)
    local b1, b2, b3, b4 = string.pack(">f", v):byte(1, 4)
    slave.regs[a] = b1 * 256 + b2
    slave.regs[a + 1] = b3 * 256 + b4
end

local function new_slave(o)
    o = o or {}
    slave = {
        addr = o.addr or 1, regs = {}, max_qty = o.max_qty or 125,
        over = o.over or "ignore",       -- qty 超上限: ignore 照回 / trunc 少回 / exc 异常码3
        unmapped = o.unmapped or "gap0", -- 未映射地址: gap0 回 0 / exc 异常码2
        delay_ms = o.delay_ms or 5, offline = o.offline or false,
        n_req = 0, n_rsp = 0, n_drop = 0, n_badcrc = 0, peak_qty = 0,
    }
    return slave
end

local function drive(target_rounds)
    for _ = 1, 400000 do
        if poll.status().rounds >= target_rounds then return true end
        local ran = false
        for i = 1, #BUS.tasks do
            local t = BUS.tasks[i]
            if coroutine.status(t.co) == "suspended" then
                ran = true
                local ok, err = coroutine.resume(t.co)
                if not ok then return false, "poll_task 抛错: " .. tostring(err) end
            end
        end
        if not ran then return false, "没有可运行的采集任务(轮询没起来?)" end
    end
    return false, "drive 步数超限(死循环?)"
end

-- 跑满 rounds 轮, 返回这一轮的账: 帧数 / 各计数增量 / 总线耗时 / push 条数
local function run_round(cfg_tbl, rounds)
    rounds = rounds or 1
    CURCFG = cfg_tbl
    if poll.is_running() then poll.stop() end
    bus_reset()
    pushed, push_map, logs = {}, {}, {}
    local s0 = poll.status()
    local n0tx = BUS.tx_frames
    if not poll.start() then return nil, "poll.start 失败" end
    local t0 = BUS.now
    local okd, derr = drive(s0.rounds + rounds)
    local ms = BUS.now - t0
    local s1 = poll.status()
    poll.stop()
    if not okd then return nil, derr end
    return {
        rounds = s1.rounds - s0.rounds, frames = BUS.tx_frames - n0tx, ms = ms,
        ok = s1.ok - s0.ok, timeout = s1.timeout - s0.timeout, werr = s1.werr - s0.werr,
        pushes = #pushed, plan = s1.frames or 0, regs = s1.regs,
    }
end

local function cfg_of(rs, o)
    o = o or {}
    return { regs = rs, interval_ms = o.interval or 0, timeout_ms = o.timeout or 300,
             slave = 1, baud = o.baud or 9600, databits = 8, stopbits = 1, parity = 0 }
end

-- 地址表生成: n 点, 每块 blk 个连续点, 块之间留 1 个空地址(逼计划断块)
local function regs_blocked(n, base, blk)
    local rs, a = {}, base
    for i = 1, n do
        rs[#rs + 1] = R(a)
        a = a + 1
        if i % blk == 0 then a = a + 1 end
    end
    return rs
end

-- ============================================================ 场景

print(string.format("== 485 总线级测试 (%s, 真 poll + 真 mbus)", _VERSION))

-- S0 冒烟: 单点单帧, 真 CRC 走一个来回
do
    new_slave({ max_qty = 125 })
    fill_words(100, 100)
    local m = run_round(cfg_of({ R(100) }), 1)
    check("S0 单点: 1 帧 1 值", m and m.frames == 1 and m.pushes == 1, m and
        string.format("帧=%d 值=%d", m.frames, m.pushes))
    check("S0 单点: 值 = 从站寄存器", m and push_map[100] == w16(100), m and push_map[100])
    check("S0 单点: ok=1 timeout=0", m and m.ok == 1 and m.timeout == 0 and m.werr == 0,
        string.format("%s", m and (m.ok .. "/" .. m.timeout .. "/" .. m.werr)))
end

-- S1 定帧上限: fc3 响应的 byte_count 多大就切不出帧 (直接问 mbus, 不经 poll)
do
    local function rsp(bc)
        local d = {}
        for i = 1, bc do d[i] = string.char(i % 256) end   -- bc 是【字节数】= 2 * qty
        return mbus.append_crc(string.char(1, 3, bc) .. table.concat(d))
    end
    local f_ok244, f_bad246 = rsp(244), rsp(246)
    check("S1 bc=244(qty122) 能定帧", mbus.try_extract_len(f_ok244) == #f_ok244,
        mbus.try_extract_len(f_ok244))
    check("S1 bc=246(qty123) 定不了帧", mbus.try_extract_len(f_bad246) == nil,
        tostring(mbus.try_extract_len(f_bad246)))
    check("S1 bc=250(qty125, 规范上限) 定不了帧", mbus.try_extract_len(rsp(250)) == nil)
    print(string.format("     定帧上限: bc<=244 → qty<=122; 而 build_read/MAX_BLOCK_QTY 允许 qty=125"))
end

-- S2 128 点连续(正好 125+3): 首块 125 字 → 定帧门拒收 → 该块每轮全丢
do
    new_slave({ max_qty = 125, over = "ignore" })
    local rs = {}
    for i = 1, 128 do rs[i] = R(40000 + i) end
    fill_words(40001, 40128)
    local plan = poll._build_plan(rs)
    check("S2 计划把 128 点并成 2 帧(125+3)", #plan == 2 and plan[1].qty == 125 and plan[2].qty == 3,
        plan and string.format("%d+%d", plan[1].qty, plan[2].qty))
    local m = run_round(cfg_of(rs), 1)
    known_bug("S2 125 字合并块每轮超时(缺陷①: try_extract_len 的 bc 上限 244 卡死规范上限帧)",
        m and m.timeout == 1 and m.ok == 1 and m.pushes == 3,
        m and string.format("帧=%d ok=%d timeout=%d 值=%d/128", m.frames, m.ok, m.timeout, m.pushes))
    check("S2 后一块(qty=3)的 3 个值正确", m and push_map[40126] == w16(40126)
        and push_map[40128] == w16(40128), m and push_map[40128])
end

-- S3 128 点分 2 块 x 64 字(绕开缺陷①): 全表 128 值一个不差
do
    new_slave({ max_qty = 125, over = "ignore" })
    fill_words(41001, 41130)
    local rs = regs_blocked(128, 41001, 64)
    local plan = poll._build_plan(rs)
    local m = run_round(cfg_of(rs), 1)
    check("S3 128 点 → 2 帧", m and m.frames == 2 and #plan == 2,
        string.format("帧=%d 计划=%d", m and m.frames, #plan))
    check("S3 128 个值全部采到", m and m.pushes == 128, m and m.pushes)
    local bad, first = 0, nil
    for i = 1, #rs do
        local r = rs[i]
        if push_map[r.addr] ~= w16(r.addr) then
            bad = bad + 1
            first = first or string.format("addr=%d 期望=%s 实得=%s", r.addr,
                tostring(w16(r.addr)), tostring(push_map[r.addr]))
        end
    end
    check("S3 128 个值逐个等于从站内容", bad == 0, first)
    check("S3 无超时无异常", m and m.ok == 2 and m.timeout == 0 and m.werr == 0,
        m and string.format("ok=%d to=%d err=%d", m.ok, m.timeout, m.werr))
    check("S3 合并块里每行 hex 只含自己的字",
        (function()
            for _, p in ipairs(pushed) do
                if p.addr == 41010 and p.hex ~= hex_of(string.char(math.floor(w16(41010) / 256) % 256, w16(41010) % 256)) then
                    return false
                end
            end
            return push_map[41010] ~= nil
        end)(), "hex 切片不对")
    print(string.format("     总线时间: 128 点 / 2 帧 / %d ms @9600 (间隔 0, 纯总线)", m and m.ms))
end

-- S4 混合宽度(通用点位表): 30x uint16 + 20x uint32 + 15x float32 = 100 字 1 帧
do
    new_slave({ max_qty = 125, over = "ignore" })
    fill_words(41001, 41100)
    local rs, floats = {}, {}
    for i = 0, 29 do rs[#rs + 1] = R(41001 + i) end                       -- 30 字
    for i = 0, 19 do rs[#rs + 1] = R(41031 + i * 2, 2, "uint32") end      -- 40 字
    for i = 0, 14 do
        local a = 41071 + i * 2
        rs[#rs + 1] = R(a, 2, "float32")
        local v = 1.5 + i * 0.25
        floats[a] = v
        put_f32(a, v)
    end                                                                   -- 30 字
    local plan = poll._build_plan(rs)
    local m = run_round(cfg_of(rs), 1)
    check("S4 65 点(100 字)并成 1 帧", m and m.frames == 1 and #plan == 1 and plan[1].qty == 100,
        string.format("帧=%d 计划%d qty=%d", m and m.frames, #plan, plan[1].qty))
    check("S4 65 个值全部采到", m and m.pushes == 65, m and m.pushes)
    local bad = 0
    for _, r in ipairs(rs) do
        local want = r.dtype == "uint16" and w16(r.addr)
            or r.dtype == "uint32" and wu32(r.addr) or floats[r.addr]
        local got = push_map[r.addr]
        if not got or (r.dtype == "float32" and math.abs(got - want) > 1e-5) or
            (r.dtype ~= "float32" and got ~= want) then bad = bad + 1 end
    end
    check("S4 混合宽度取值全对(uint16/uint32/float32 各按大端)", bad == 0, bad .. " 项不对")
    check("S4 float32 解码与 string.pack 一致(交叉验证 bytes_to_float)",
        (function()
            local g = push_map[41071]
            return g and math.abs(g - 1.5) < 1e-6
        end)(), push_map[41071])
end

-- S5 从站单帧只肯回 16 字(over=trunc): 少回字被当成成功 (缺陷②)
do
    new_slave({ max_qty = 16, over = "trunc" })
    fill_words(41001, 41130)
    local rs = regs_blocked(128, 41001, 64)
    local m = run_round(cfg_of(rs), 1)
    check("S5 请求确实是 64 字(从站被问到超上限)", m and slave.peak_qty == 64, slave.peak_qty)
    known_bug("S5 从站少回字被记成 ok、不报错(缺陷②: poll_block 不校验 bc == 2*qty)",
        m and m.ok == 2 and m.timeout == 0 and m.werr == 0 and m.pushes == 32,
        m and string.format("ok=%d timeout=%d werr=%d 值=%d/128", m.ok, m.timeout, m.werr, m.pushes))
    check("S5 每块只有前 16 点有值(后 48 点本轮没数据)",
        (function()
            return push_map[41001] ~= nil and push_map[41016] ~= nil
                and push_map[41017] == nil and push_map[41064] == nil
        end)(), "边界不是 16/17")
    print("     现场含义: 前端看到 128 行都在, 后 96 行还是上一轮的旧值, 日志一条不报")
end

-- S6 同一件事从站改用异常码回答: 计数看得见
do
    new_slave({ max_qty = 16, over = "exc" })
    fill_words(41001, 41130)
    local rs = regs_blocked(128, 41001, 64)
    local m = run_round(cfg_of(rs), 1)
    check("S6 超上限 → 2 帧全异常, 计数进 werr", m and m.werr == 2 and m.ok == 0 and m.pushes == 0,
        m and string.format("werr=%d ok=%d 值=%d", m.werr, m.ok, m.pushes))
end

-- S7 从站未映射地址回异常码2: 跨空隙合并 = 整块丢 (为什么只合严格相邻)
do
    new_slave({ max_qty = 125, over = "ignore", unmapped = "exc" })
    slave.regs[41001] = 11
    slave.regs[41003] = 13                       -- 41002 故意不映射
    local rs = { R(41001), R(41003) }
    local plan = poll._build_plan(rs)
    check("S7 有空隙就不并(2 帧)", #plan == 2, plan and (#plan .. " 帧"))
    local m = run_round(cfg_of(rs), 1)
    check("S7 相邻规则保住了两个值(没有跨空隙整块作废)",
        m and m.pushes == 2 and m.werr == 0 and m.timeout == 0,
        m and string.format("值=%d werr=%d to=%d", m.pushes, m.werr, m.timeout))
    -- 反面对照: 一格点位跨住未映射的 41002, 从站整帧拒绝 → 三个点全丢
    local cross = { { addr = 41001, count = 3, dtype = "uint16", name = "x41001" } }
    local m2 = run_round(cfg_of(cross), 1)
    check("S7 跨未映射地址整帧 → 异常码2, 三个字全丢", m2 and m2.werr == 1 and m2.pushes == 0,
        m2 and string.format("werr=%d 值=%d", m2.werr, m2.pushes))
end

-- S8 离线从站: 合并读把超时成本从 128 帧降到 2 帧 (总线时间这道门的下半段)
do
    new_slave({ max_qty = 125, over = "ignore", offline = true })
    fill_words(41001, 41130)
    local rs_each = regs_blocked(128, 41001, 1)
    local rs_merge = regs_blocked(128, 41001, 64)
    local a = run_round(cfg_of(rs_each, { timeout = 300 }), 1)
    local alive_each = alive
    local b = run_round(cfg_of(rs_merge, { timeout = 300 }), 1)
    check("S8 仪表不在线: 每点一帧 = 128 次超时", a and a.timeout == 128 and a.frames == 128,
        a and string.format("帧=%d 超时=%d", a.frames, a.timeout))
    check("S8 仪表不在线: 合并读 = 2 次超时", b and b.timeout == 2 and b.frames == 2,
        b and string.format("帧=%d 超时=%d", b.frames, b.timeout))
    check("S8 合并读把一轮的空等时间压到 1/60 以下",
        a and b and b.ms * 60 < a.ms, a and b and string.format("%d ms vs %d ms", a.ms, b.ms))
    print(string.format("     离线一轮: 每点一帧 %d ms (%.1f s), 合并 %d ms; TIMEOUT_MS=500 时分别是 %.0f s / %.1f s",
        a and a.ms, (a and a.ms or 0) / 1000, b and b.ms,
        128 * 500 / 1000, 2 * 500 / 1000))
    check("S8 每帧都喂了看门狗心跳(guard.alive)", alive_each > 128 and alive > alive_each,
        string.format("alive=%d", alive))
end

-- S9 轮耗时随块大小: 128 点这一道门的完整账 (在线从站)
do
    fill_words(41001, 41140)
    print("     块大小 → 128 点一轮总线时间 @9600 8N1, 从站延迟 5ms, 轮间隔算 0:")
    local rows = { { 1, "每点一帧" }, { 8, "8 字/块" }, { 16, "16 字/块" },
                   { 64, "64 字/块" }, { 122, "122 字/块(定帧上限)" }, { 125, "125 字/块(规范上限)" } }
    local res = {}
    for _, it in ipairs(rows) do
        local blk = it[1]
        new_slave({ max_qty = 125, over = "ignore", delay_ms = 5 })
        fill_words(41001, 41140)
        local rs = regs_blocked(128, 41001, blk)
        local m = run_round(cfg_of(rs), 1)
        res[#res + 1] = { name = it[2], blk = blk, m = m }
        if m then
            print(string.format("       %-22s 帧=%3d  轮=%5d ms  值=%3d/128  ok=%d timeout=%d",
                it[2], m.frames, m.ms, m.pushes, m.ok, m.timeout))
        end
    end
    local function ms_of(name)
        for _, r in ipairs(res) do if r.name == name then return r.m and r.m.ms end end
    end
    check("S9 合并读比每点一帧快 3 倍以上", ms_of("每点一帧") and ms_of("64 字/块")
        and ms_of("64 字/块") * 3 < ms_of("每点一帧"),
        string.format("%s vs %s", tostring(ms_of("每点一帧")), tostring(ms_of("64 字/块"))))
    check("S9 122 字/块能采满 128 点(把 MAX_BLOCK_QTY 收到 122 即可用)",
        (function()
            for _, r in ipairs(res) do
                if r.blk == 122 then return r.m and r.m.pushes == 128 and r.m.timeout == 0 end
            end
            return false
        end)(), "122 字/块没采满")
    known_bug("S9 125 字/块采不满(同一缺陷①的另一面)",
        (function()
            for _, r in ipairs(res) do
                if r.blk == 125 then return r.m and r.m.pushes < 128 and r.m.timeout == 1 end
            end
            return false
        end)(), "见 S9 表格 timeout 列")
end

-- S10 波特率账: 9600 vs 115200 下 128 点合并一轮
do
    new_slave({ max_qty = 125, over = "ignore", delay_ms = 5 })
    fill_words(41001, 41130)
    local rs = regs_blocked(128, 41001, 64)
    local a = run_round(cfg_of(rs, { baud = 9600 }), 1)
    new_slave({ max_qty = 125, over = "ignore", delay_ms = 5 })
    fill_words(41001, 41130)
    local b = run_round(cfg_of(rs, { baud = 115200 }), 1)
    check("S10 高波特率下字节时间被从站延迟主导(不是波特率)", a and b and b.ms <= a.ms,
        string.format("9600=%dms 115200=%dms", a and a.ms, b and b.ms))
    print(string.format("     128 点/2 帧: 9600 = %d ms, 115200 = %d ms (差值就是字节时间, 剩下是 5ms 从站延迟 + poll 的 5ms 步进)",
        a and a.ms, b and b.ms))
end

print(string.format("== 结论: %d 项断言失败, %d 条已知缺陷被钉住", failed, bugpin))
if failed > 0 then
    print(string.format("%d poll slave check(s) FAILED", failed))
    os.exit(1)
end
print("all poll slave checks passed")
os.exit(0)
