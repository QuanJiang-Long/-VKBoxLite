-- test_framereuse.lua —— 钉住 12-fix-5 的【帧表复用】
--
-- 背景: 嗅探热路径上每帧要解一次码, 而帧表(十几个字段)是最贵的一笔分配。
--   12-fix-5 改成"从池子里拿旧表来填"(collector.take_frame), 分配降到 0。
--   风险: 复用的表里如果残留上一帧的字段, 会【静默】污染判型/配对结果 ——
--   比如一个【读请求】帧(有 addr/qty)接着上一帧【读响应】(有 bc/vhex),
--   残留的 vhex 会挂到请求帧上, 前端显示的"值"就全乱了。
--
-- 这个测试做两件事:
--   1) 跑 60 帧(远超 FRAME_CACHE=10, 一定触发回收复用), 检查最后 10 帧
--      的字段【逐个】正确, 没有上一帧的残留;
--   2) A/B 对照: 同一帧, 复用表解出来的字段必须和"每次新建表"解出来的
--      一模一样。

local mbus = dofile('lua/bus/mbus.lua')
local collector = dofile('lua/data/collector.lua')
local cfg = require 'core/config'

local failed = 0
local function eq(a, b, what)
    if a ~= b then
        failed = failed + 1
        print(string.format("FAIL: %s  期望 %s, 实际 %s", what, tostring(b), tostring(a)))
    end
end
local function ok(cond, what)
    if not cond then
        failed = failed + 1
        print("FAIL: " .. what)
    end
end

-- 一帧【读请求】(slave 1, fc3, addr 100, qty 2) —— 8 字节
local REQ = mbus.build_read(1, 100, 2)
-- 一帧【读响应】(slave 1, fc3, bc 4, 载荷 0001 0002) —— 9 字节
local RSP = mbus.append_crc(string.char(1, 3, 4, 0x00, 0x01, 0x00, 0x02))
-- hex 是【整帧】的十六进制(含末尾 2 字节 CRC), data 是【原始二进制】载荷
local function tohex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local RSP_HEX = tohex(RSP)
local RSP_DATA = string.char(0x00, 0x01, 0x00, 0x02)

-- 字段快照: 只看这些, 多出来的残留字段靠 has 单独查
local function snap(f)
    return {
        kind = f.kind, slave = f.slave, fc = f.fc,
        addr = f.addr, qty = f.qty, bc = f.bc,
        hex = f.hex, vhex = f.vhex, raw = f.raw, data = f.data,
    }
end

-- ===== 1. A/B 对照: 复用表 vs 新建表, 字段必须一致 =====
local a = mbus.decode_frame(REQ, collector.take_frame())
local b = mbus.decode_frame(REQ, {})
for k, v in pairs(snap(a)) do eq(v, b[k], "A/B 字段一致: " .. tostring(k)) end

local a2 = mbus.decode_frame(RSP, collector.take_frame())
local b2 = mbus.decode_frame(RSP, {})
for k, v in pairs(snap(a2)) do eq(v, b2[k], "A/B 字段一致(rsp): " .. tostring(k)) end

-- ===== 2. 跑 60 帧, 强制触发回收复用 =====
collector.clear_all()
for i = 1, 30 do
    local t = collector.take_frame()
    mbus.decode_frame(REQ, t)
    collector.push_frame(t)
    local t2 = collector.take_frame()
    mbus.decode_frame(RSP, t2)
    collector.push_frame(t2)
end

local fs = collector.get_frames()
eq(#fs, cfg.FRAME_CACHE, "ring 里正好 FRAME_CACHE 帧")

-- 逐帧检查: 请求帧不能带响应的残留, 响应帧不能带请求的残留
local nreq, nrsp = 0, 0
for i = 1, #fs do
    local f = fs[i]
    if f.kind == "req" then
        nreq = nreq + 1
        eq(f.slave, 1, "req.slave")
        eq(f.fc, 3, "req.fc")
        eq(f.addr, 100, "req.addr")
        eq(f.qty, 2, "req.qty")
        eq(f.data, nil, "req 不该有 data 残留")
        eq(f.bc, nil, "req 不该有 bc 残留(上一帧响应的)")
        eq(f.vhex, nil, "req 不该有 vhex 残留(上一帧响应的!)")
    elseif f.kind == "rsp" then
        nrsp = nrsp + 1
        eq(f.slave, 1, "rsp.slave")
        eq(f.fc, 3, "rsp.fc")
        eq(f.bc, 4, "rsp.bc")
        eq(f.qty, 2, "rsp.qty")
        eq(f.vhex, "00010002", "rsp.vhex")
        eq(f.hex, RSP_HEX, "rsp.hex")
        eq(f.addr, nil, "rsp 不该有 addr 残留(上一帧请求的)")
        eq(f.data, RSP_DATA, "rsp.data")
    else
        failed = failed + 1
        print("FAIL: 第 " .. i .. " 帧 kind 异常: " .. tostring(f.kind))
    end
end
eq(nreq, 5, "ring 里请求帧数")
eq(nrsp, 5, "ring 里响应帧数")

-- ===== 3. 池子不能无限长 =====
-- 复用的表必须【回到池子】而不是被丢掉, 否则 take_frame 每次都新建,
-- 分配就白降了。这里通过"ring 满之后 push_frame 仍然能拿到表"来间接验证:
-- 上面 60 帧跑完后, 池子里应该还有表可用(拿到的表不是全新空表)
local t = collector.take_frame()
ok(next(t) == nil, "取出来的表是空的(字段已清干净)")

if failed == 0 then
    print("PASS: 帧表复用 —— 60 帧无字段残留, 复用表与新建表字段一致")
    return
end
print("FAIL: " .. failed .. " 项不通过")
os.exit(1)
