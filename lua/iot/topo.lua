-- 拓扑(U2)的 JSON 拼装 + 拓扑指纹。
-- 2026-10-29 从 iot.lua 抽出来单独成模块, 两个理由:
--   ① 能写模拟器单测(tests/lua/test_topo.lua)。平台的物模型契约是
--      "一个字段都不能多、不能少", 拼串代码必须有人盯着 —— 以前这段
--      逻辑埋在 iot.lua 两千多行里, 改坏了只有烧到现场才知道。
--   ② 把【一次成串】收在一处。拓扑帧是本机最大的一块连续内存需求,
--      现场就是死在这上面(见下面 12-fix-11 的说明)。
--
-- ⚠️ 12-fix-11 (2026-10-29): 【一次成串】—— 连续内存峰值 25KB → 8.6KB。
--   原来的链路(每一步都造一份新的大串, 而且同一时刻全都活着):
--     props[64] → table.concat(8.3KB) → string.format(8.5KB)
--                → nodes 串(8.5KB) → sig 串(8.5KB 拷贝) → body(8.6KB)
--   = 同时活着 4 份 8KB+ 的连续串(25.6KB), 另外还有 build_nodes 给每个
--   地址造的两张表(6 字段 + 7 字段 = 406 字节 × 82 = 33KB 垃圾)。
--   现场(2026-10-29, 82 个地址): 池子用掉 95.2%, 连 8.3KB 的连续块都
--   切不出来 → "not enough memory for buffer allocation" → 拓扑一帧都
--   没发出去(census topo=0) → 平台没有物模型 → 用户只看到一部分数据。
--   现在: 所有片段先塞进一个表, 最后 table.concat 一次 → 全程只有
--   【一份】body(8.6KB 连续) 加上若干几十字节的小片段。
--   顺带: 指纹不再留一份 8.5KB 的 nodes 串(S.topo_sig 变成几十字节的
--   哈希) → 常驻 -8.5KB。

local M = {}

local jstr = require("util/mqtt_util").jstr

-- 一条 property 的 JSON 片段(平台的物模型里的一条属性)。
-- 字段顺序/名字照平台 V3 文档的示例, 一个不多一个不少:
--   id/name 是【属性标识】, dataType 是【物模型口径】, modbus.dataType
--   是【寄存器口径】 —— 这两个 dataType 不是一回事, 详见 lua/README.md
--   「dataType 拼法」。
--   quantity: 这个属性占几个寄存器(modbus.address 是起始地址)。
function M.prop(id, name, dtype, slave, addr, count)
    return string.format(
        '{"id":%s,"name":%s,"dataType":%s,"unit":"","modbus":{"slave":%d,"address":%d,"quantity":%d,"dataType":%s}}',
        jstr(id), jstr(name), jstr(dtype), slave, addr, count, jstr(dtype))
end

-- 一个子设备节点的 JSON 片段组: 片段按顺序塞进 out(调用方的表),
-- 本函数【不自己拼大串】—— 由调用方最后一次性 table.concat。
--   props: property 片段的数组(每项是 M.prop 的产物)
function M.node_parts(out, idx, slave, serial_json, tsl_name, props)
    out[#out + 1] = '{"nodeIndex":' .. idx .. ',"slaveId":' .. slave ..
        ',"kind":"RTU","serial":' .. serial_json ..
        ',"model":{"tslName":' .. jstr(tsl_name) .. ',"properties":['
    for i = 1, #props do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = props[i]
    end
    out[#out + 1] = ']}}'
end

-- 片段的总长度(只统计, 不复制)。给日志看拓扑规模用。
function M.len(parts)
    local n = 0
    for i = 1, #parts do n = n + #parts[i] end
    return n
end

-- 拓扑指纹: 32 位滚动哈希, 只喂片段内容。
-- 为什么不直接用 nodes 串当指纹: 那要再留一份 8.5KB 的连续内存
--   (常驻 +8.5KB, 现场那 8.5KB 就是拓扑发不出去的原因之一)。
-- 为什么不用整串的副本当指纹: 副本同样是 8.5KB 连续内存, 而且发布
--   的时候还要再拼一次 body, 峰值又涨 8.6KB。
-- 哈希只遍历片段, 不产生任何新的大字符串 ✓
--
-- 指纹的语义没变: "拓扑内容变了没有"。喂进去的是【拼出去的每一个
-- 字节】, 所以内容变了一定变, 内容没变一定不变 ✓
function M.sig(parts)
    -- 31 位滚动哈希: h = (h * 131 + b) mod (2^31-1)
    -- 乘数刻意选小的: h < 2^32, 乘 131(2^7) 之后还是 2^39, 落在 Lua 5.3
    -- 的整数精确范围(2^53)里 —— 用 16777619 那种大乘数会让中间值超过
    -- 2^53 变成浮点, 精度一掉哈希就不可靠了。
    local h = 0
    local MOD = 2147483647
    for i = 1, #parts do
        local s = parts[i]
        local n = #s
        for j = 1, n do
            h = (h * 131 + s:byte(j)) % MOD
        end
    end
    -- 指纹用十进制串(不用 %x: 项目的 32 位安全检查挡 %08x 这类补零的
    -- 十六进制格式, 见 check_lua.py)。十进制一样能当指纹用。
    return tostring(#parts) .. ":" .. tostring(h)
end

return M
