-- 拓扑(U2)拼串的单测。2026-10-29 (12-fix-11) 新增。
--
-- 为什么要有这个测试: 拓扑帧是平台建档/建物模型的唯一输入, 平台的契约是
-- "一个字段都不能多、不能少"(多一个字段平台可能整包拒收)。以前这段拼串
-- 埋在 iot.lua 两千多行里, 改坏了只有烧到现场才知道 —— 现场一帧没发出去
-- 的症状是"用户只看到一部分数据", 极难定位。
--
-- 这里干两件事:
--   ① 【逐字节对比】新模块(iot/topo.lua)拼出来的东西, 必须跟【老逻辑的
--      格式串】一个字节不差。老逻辑的格式串原样抄在下面当基准。
--   ② 指纹的性质: 同样的内容 → 同样的指纹; 内容变一个字节 → 指纹必须变。
--
-- 跑法: tools\run_lua_tests.bat test_topo.lua

local topo = require "iot/topo"
local MqttUtil = require "util/mqtt_util"

local failed = 0
local function check(name, ok, detail)
    if ok then
        print(string.format("ok   %s", name))
    else
        failed = failed + 1
        print(string.format("FAIL %s: %s", tostring(detail or ""), name))
    end
end

-- ===== 基准: 老逻辑的格式串(从 12-fix-11 之前的 iot.lua 原样抄过来) =====
local function old_prop(id, name, dt, slave, addr, count)
    return string.format(
        '{"id":%s,"name":%s,"dataType":%s,"unit":"","modbus":{"slave":%d,"address":%d,"quantity":%d,"dataType":%s}}',
        MqttUtil.jstr(id), MqttUtil.jstr(name), MqttUtil.jstr(dt), slave, addr, count, MqttUtil.jstr(dt))
end

local function old_node(idx, slave, serial_json, tsl_name, props)
    return string.format(
        '{"nodeIndex":%d,"slaveId":%d,"kind":"RTU","serial":%s,"model":{"tslName":%s,"properties":[%s]}}',
        idx, slave, serial_json, MqttUtil.jstr(tsl_name), table.concat(props, ","))
end

-- ===== ① property 片段: 逐字节一致 =====
local cases = {
    { id = "reg230", name = "reg230", dt = "uint16", slave = 1, addr = 230, count = 1 },
    { id = "A相电流", name = "A相电流", dt = "float32", slave = 2, addr = 40001, count = 2 },
    { id = "CT1", name = "CT1 电流", dt = "int32", slave = 247, addr = 65535, count = 125 },
    -- 带引号/反斜杠/控制符的 id: 必须跟老逻辑一样转义
    { id = 'a"b\\c', name = "tab\there", dt = "uint16", slave = 1, addr = 0, count = 1 },
}
for i, c in ipairs(cases) do
    local got = topo.prop(c.id, c.name, c.dt, c.slave, c.addr, c.count)
    local want = old_prop(c.id, c.name, c.dt, c.slave, c.addr, c.count)
    check(string.format("prop#%d 逐字节一致", i), got == want,
        string.format("\n  新: %s\n  老: %s", got, want))
end

-- ===== ② 节点: 逐字节一致 =====
local serial = '{"port":"/dev/ttyS1","baudRate":9600,"dataBits":8,"stopBits":1,"parity":"N"}'
local props = {
    topo.prop("reg100", "reg100", "uint16", 1, 100, 1),
    topo.prop("reg101", "A相电流", "uint16", 1, 101, 1),
}
local out = {}
topo.node_parts(out, 1, 1, serial, "sniff_s1", props)
local got_node = table.concat(out)
local want_node = old_node(1, 1, serial, "sniff_s1", {
    old_prop("reg100", "reg100", "uint16", 1, 100, 1),
    old_prop("reg101", "A相电流", "uint16", 1, 101, 1),
})
check("node 逐字节一致", got_node == want_node,
    string.format("\n  新: %s\n  老: %s", got_node, want_node))

-- 空 properties: 老逻辑也是空数组
local out2 = {}
topo.node_parts(out2, 3, 7, serial, "sniff_s7", {})
check("空 properties", table.concat(out2) ==
    old_node(3, 7, serial, "sniff_s7", {}), table.concat(out2))

-- ===== ③ 指纹 =====
local s1 = topo.sig(out)
local s2 = topo.sig(out)
check("同样的内容 → 同样的指纹", s1 == s2, s1 .. " vs " .. s2)

-- 改一个字节 → 指纹必须变
local out3 = {}
for i = 1, #out do out3[i] = out[i] end
local hit = 0
for i = 1, #out3 do
    if out3[i]:find("reg100", 1, true) then out3[i] = (out3[i]:gsub("reg100", "reg999")); hit = i break end
end
check("改的是真的改到了", hit > 0, "没找到含 reg100 的片段")
check("内容变 → 指纹变", topo.sig(out3) ~= s1, topo.sig(out3) .. " vs " .. s1)

-- 指纹本身要短(不能又是一份大串)
check("指纹很短(<64 字节)", #s1 < 64, #s1)

-- 指纹不能因为"片段顺序"而漏判
local out4 = {}
for i = #out, 1, -1 do out4[#out4 + 1] = out[i] end
check("片段顺序变了 → 指纹变", topo.sig(out4) ~= s1, topo.sig(out4) .. " vs " .. s1)

-- 指纹的输入是【拼出去的每一个字节】: 逐字节验证
local flat = {}
for i = 1, #out do flat[#flat + 1] = out[i] end
check("len() 统计的是内容总长", topo.len(out) == #table.concat(flat),
    tostring(topo.len(out)) .. " vs " .. tostring(#table.concat(flat)))

-- ===== ④ 实测: 新链路 vs 老链路的分配量 =====
--   现场(2026-10-29, 82 个地址): 拓扑一帧都没发出去, 因为要 8.3KB 的
--   连续内存, 而池子已经用掉 95.2%。老链路同时活着 4 份 8KB+ 的连续串
--   (25.6KB), 另有 33KB 的每行小表垃圾。
--   这里把老链路原样复刻一遍, 两边用同一把尺子量(collectgarbage count
--   的增量), 钉住"新链路必须明显更省"。
local NPROPS = 64
local function rows(n)
    local t = {}
    for i = 1, n do t[i] = { addr = i * 2, count = nil, name = nil, alias = nil, dtype = "uint16" } end
    return t
end

-- 老链路: 每行造两张表 + 四层 concat
local function old_build(n)
    local at, by = {}, {}
    local function put(slave, r)
        local k = slave .. ":" .. r.addr
        local p = at[k]
        if p then
            p.count, p.name, p.alias, p.dtype = r.count, r.name, r.alias, r.dtype or "uint16"
            return
        end
        p = { addr = r.addr, count = r.count, name = r.name, alias = r.alias, dtype = r.dtype or "uint16",
              pid = r.pid, pname = r.pname }
        at[k] = p
        by[slave] = by[slave] or {}
        by[slave][#by[slave] + 1] = p
    end
    for _, r in ipairs(rows(n)) do put(1, { addr = r.addr, count = r.count, dtype = "uint16" }) end
    local nodes = {}
    for _, s in ipairs({ 1 }) do
        local props = {}
        for _, r in ipairs(by[s]) do
            if #props >= 64 then break end
            local dt = r.dtype or "uint16"
            local id = "reg" .. r.addr
            props[#props + 1] = string.format(
                '{"id":%s,"name":%s,"dataType":%s,"unit":"","modbus":{"slave":%d,"address":%d,"quantity":%d,"dataType":%s}}',
                MqttUtil.jstr(id), MqttUtil.jstr(id), MqttUtil.jstr(dt), 1, r.addr, r.count or 1, MqttUtil.jstr(dt))
        end
        nodes[#nodes + 1] = string.format(
            '{"nodeIndex":%d,"slaveId":%d,"kind":"RTU","serial":%s,"model":{"tslName":%s,"properties":[%s]}}',
            1, 1, serial, MqttUtil.jstr("sniff_s1"), table.concat(props, ","))
    end
    local nodes_str = table.concat(nodes, ",")
    local sig = tostring(#nodes_str) .. ":" .. nodes_str
    -- ⚠️ ts 这里用 1750000000(秒级), 不是 os.time()*1000:
    --   32 位固件上 os.time()*1000 会整数回绕成负数(实测 -2036609728),
    --   老的 %d 和新的 tostring 拿到的都是那个回绕值 —— 逐字节一致 ✓。
    --   回绕的 ts 本身是个真 bug(平台的 U2 ts 是错的), 但改它等于改平台
    --   契约(数字 vs 字符串), 单独一次改, 不混在内存优化里。
    local body = string.format('{"vendor":%s,"model":%s,"fwVersion":%s,"ts":%d,"nodes":[%s]}',
        MqttUtil.jstr("VKBox"), MqttUtil.jstr("VKBox_Lite"), MqttUtil.jstr("0.0.1"), 1750000000, nodes_str)
    return #body, #sig
end

-- 新链路: 每行直接变成 property 片段, 最后一次 concat
local function new_build(n)
    local parts = {}
    local g_addrs, g_props = {}, {}
    for _, r in ipairs(rows(n)) do
        local id = "reg" .. r.addr
        g_addrs[#g_addrs + 1] = r.addr
        g_props[#g_props + 1] = topo.prop(id, id, "uint16", 1, r.addr, 1)
    end
    topo.node_parts(parts, 1, 1, serial, "sniff_s1", g_props)
    local sig = topo.sig(parts)
    local b = { '{"vendor":', MqttUtil.jstr("VKBox"), ',"model":', MqttUtil.jstr("VKBox_Lite"),
        ',"fwVersion":', MqttUtil.jstr("0.0.1"), ',"ts":', tostring(1750000000), ',"nodes":[' }
    for i = 1, #parts do b[#b + 1] = parts[i] end
    b[#b + 1] = ']}'
    local body = table.concat(b)
    return #body, #sig
end

local function measure(fn)
    collectgarbage("collect")
    collectgarbage("collect")
    local c0 = collectgarbage("count")
    fn()
    local c1 = collectgarbage("count")
    collectgarbage("collect")
    return (c1 - c0) * 1024
end

local old_bytes = measure(function() old_build(NPROPS) end)
local new_bytes = measure(function() new_build(NPROPS) end)
print(string.format("拓扑构建(%d 条属性)的总分配: 老链路 %d 字节, 新链路 %d 字节, 省 %d 字节(%.0f%%)",
    NPROPS, old_bytes, new_bytes, old_bytes - new_bytes,
    old_bytes > 0 and (old_bytes - new_bytes) * 100 / old_bytes or 0))
check("新链路的总分配明显更少(至少省 30%)", new_bytes < old_bytes * 0.7,
    string.format("老 %d / 新 %d", old_bytes, new_bytes))

-- 【同时活着的连续大串】才是现场真正卡住的地方:
--   老链路拼 body 那一刻, nodes 串(8.5KB)、指纹串(8.5KB)、body(8.6KB)
--   三份连续大串同时活着(现场池子 95% 时, 这 25KB 根本放不下);
--   新链路拼 body 时只有几十个小片段, 大串只出来一份(body)。
--   这个"同时活着的字节数"没法直接量(中间垃圾在 GC 之前也算占位),
--   所以这里只钉住总量, 大串的那部分在代码里一眼能看出来
--   (老: 4 次大 concat; 新: 1 次)。
-- ===== ⑤ ts: 32 位固件的整数回绕(12-fix-11 修掉的真 bug) =====
local ms = MqttUtil.ms_of(os.time())
check("ms_of 给的是 13 位毫秒串", #ms == 13 and ms:match("^%d+$") ~= nil, ms)
if math.maxinteger and math.maxinteger < 2 ^ 40 then
    -- 32 位固件: os.time()*1000 会整数回绕, 拿到的不是毫秒时间
    local wrapped = os.time() * 1000
    check("32 位机上 os.time()*1000 确实是错的(所以必须用 ms_of)",
        tostring(wrapped) ~= ms, tostring(wrapped) .. " vs " .. ms)
end

if failed > 0 then
    print(string.format("FAIL: %d 项不通过", failed))
    os.exit(1)
end
print("test_topo: 全部通过")
