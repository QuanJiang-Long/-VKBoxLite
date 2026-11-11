-- test_poll_merge.lua —— 连续地址合并读计划的单测 (2026-11-10)
--
-- 背景: poll_task 原来一行一帧, 128 点连续地址要发 128 帧; 仪表不在线时
--   每帧白等 500ms → 一轮 64 秒。改成把【严格相邻】的行并成一帧。
--
-- 这里钉住的是最容易改坏的两件事:
--   1) 合并边界: 有空隙/重叠/超 MAX_BLOCK_QTY(现 96) 字必须断块。错并一帧, 仪表回 Illegal
--      Data Address 就是整块点位本轮全丢 —— 比不合并更糟, 而且前端看不出来。
--   2) 行偏移切片: 合并块里每行取到的字节必须和"单独读那一行"一字不差
--      (值的个数、hex 串、push 的 addr 序列)。前端和 R:VAL 只认 addr→值,
--      切片错一格就是显示错值。
--
-- ⚠️ 不排序入参 regs: 点位表顺序是前端显示和上报的次序, 只能排计划。
--
-- 跑法: tools\run_lua_tests.bat test_poll_merge.lua
--   纯 Lua 5.1 跑, 所以 mbus 用桩 —— 桩只复刻 uint16 的大端取字,
--   被测的是 poll 里的切片/合并逻辑, 不是 mbus 解码本身。

local pushed = {}
local stub_mb = {}

package.preload["util"] = function()
    return {
        log = function()
            local L = {}
            for _, lv in ipairs({ "debug", "info", "warn", "error" }) do
                L[lv] = function() end
            end
            return L
        end,
        get = function()
            return { VUART_0 = 4, read = function() return "" end,
                     write = function() return 0 end, on = function() end }
        end,
        try = function() return nil end,
    }
end
package.preload["core/config"] = function()
    return { POLL_INTERVAL_MS = 5000, TIMEOUT_MS = 500, SLAVE_ADDR = 1,
             BAUD = 115200, DATABITS = 8, STOPBITS = 1, PARITY = 0 }
end
package.preload["cfg"] = function()
    return { load_poll = function() return nil end, load_pull = function() return nil end }
end
package.preload["data/collector"] = function()
    return { push_data = function(addr, alias, hex, value, ts, dtype)
        pushed[#pushed + 1] = { addr = addr, alias = alias, hex = hex,
                                value = value, dtype = dtype }
        return true end }
end
package.preload["bus/mbus"] = function() return stub_mb end

local poll = require "bus/poll"

-- ==== mbus 桩: 与真实现同形的 TYPE_WIDTH + uint16 大端取字 ====
stub_mb.TYPE_WIDTH = { uint16 = 1, int16 = 1, uint32 = 2, int32 = 2, float32 = 2 }
stub_mb.parse_value = function(data, off, dtype)
    local w = stub_mb.TYPE_WIDTH[dtype]
    if not w then return nil end
    local p = off * 2
    if #data < p + 2 then return nil end
    return data:byte(p + 1) * 256 + data:byte(p + 2)
end

local failed = 0
local function check(name, ok, detail)
    if ok then
        print(string.format("ok   %s", name))
    else
        failed = failed + 1
        print(string.format("FAIL %s%s", name, detail and (": " .. tostring(detail)) or ""))
    end
end

local function plan_str(pl)
    local t = {}
    for i, b in ipairs(pl) do t[i] = string.format("%d+%d(%d行)", b.addr, b.qty, #b.rows) end
    return table.concat(t, " ")
end
local function offs_str(b)
    local t = {}
    for i, it in ipairs(b.rows) do t[i] = it.r.addr .. "@" .. it.off end
    return table.concat(t, ",")
end
local function R(addr, count, dtype)
    return { addr = addr, count = count or 1, dtype = dtype or "uint16", name = "p" .. addr }
end

-- 1. 单行
local p = poll._build_plan({ R(100) })
check("单行 → 1 帧", #p == 1 and p[1].addr == 100 and p[1].qty == 1, plan_str(p))

-- 2. 严格相邻 3 行
p = poll._build_plan({ R(100), R(101), R(102) })
check("相邻 3 行 → 1 帧 qty=3", #p == 1 and p[1].qty == 3, plan_str(p))
check("行偏移 0/1/2", offs_str(p[1]) == "100@0,101@1,102@2", offs_str(p[1]))

-- 3. 有空隙必须断块
p = poll._build_plan({ R(100), R(102) })
check("100,102 有空隙 → 2 帧", #p == 2 and p[2].qty == 1, plan_str(p))

-- 4. 重叠必须断块 (重叠时并帧会让两行读到同一个字, 后 push 覆盖前 push)
p = poll._build_plan({ R(100), R(100) })
check("100,100 重叠 → 2 帧", #p == 2, plan_str(p))
p = poll._build_plan({ R(100, 2), R(101) })
check("100(count2) 与 101 重叠 → 2 帧", #p == 2, plan_str(p))

-- 5. 乱序输入 → 计划按地址升序, 且相邻照样并
p = poll._build_plan({ R(102), R(100), R(101) })
check("乱序 3 行 → 1 帧从 100 起", #p == 1 and p[1].addr == 100 and p[1].qty == 3, plan_str(p))

-- 6. 混合宽度: uint32 count=2 占两字, 下一行从 +2 起算相邻
p = poll._build_plan({ R(100, 2, "uint32"), R(102, 1, "uint16") })
check("100(2字)+102 相邻 → 1 帧 qty=3", #p == 1 and p[1].qty == 3, plan_str(p))
check("第二行偏移=2", offs_str(p[1]) == "100@0,102@2", offs_str(p[1]))

-- 7. 96 字上限 (11-11 从 125 收到 96: 不贴定帧门跑留余量; mbus 门本身已放到 0xFA=125, 见 poll.lua 常量处说明)
local big = {}
for i = 1, 200 do big[i] = R(2000 + i - 1) end
p = poll._build_plan(big)
check("200 连续 → 96+96+8 三帧",
    #p == 3 and p[1].qty == 96 and p[2].qty == 96 and p[3].qty == 8, plan_str(p))
check("第二帧从 2096 起", p[2].addr == 2096, plan_str(p))
local exactly = {}
for i = 1, 96 do exactly[i] = R(300 + i - 1) end
p = poll._build_plan(exactly)
check("恰好 96 → 1 帧", #p == 1 and p[1].qty == 96, plan_str(p))
local over = {}
for i = 1, 97 do over[i] = R(500 + i - 1) end
p = poll._build_plan(over)
check("97 → 96+1 两帧(超一个也要另起)",
    #p == 2 and p[1].qty == 96 and p[2].qty == 1, plan_str(p))

-- 8. 128 点连续表: 就是 V2 的场景
local v2 = {}
for i = 1, 128 do v2[i] = R(40000 + i - 1) end
p = poll._build_plan(v2)
check("128 点连续 → 2 帧(128→2)", #p == 2, plan_str(p))

-- 9. count 缺省当 1
p = poll._build_plan({ { addr = 50 }, { addr = 51 } })
check("count 缺省 = 1 且相邻可并", #p == 1 and p[1].qty == 2, plan_str(p))

-- 10. 空表
p = poll._build_plan({})
check("空表 → 0 帧", #p == 0, plan_str(p))

-- 11. ⚠️ 不许改入参顺序 (前端点位表次序)
local tbl = { R(103), R(101), R(102) }
poll._build_plan(tbl)
check("入参 regs 顺序没被动", tbl[1].addr == 103 and tbl[2].addr == 101 and tbl[3].addr == 102,
    string.format("%d,%d,%d", tbl[1].addr, tbl[2].addr, tbl[3].addr))

-- ==== 12. 切片等价: 单独读 101 vs 在 3 字块里读 101 ====
--   单独读时从机回的 data 只有它自己那一字, 所以基准要用 2 字节的 data
local function hex_of(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local data = string.char(0, 10, 0, 20, 0, 30)   -- 100=10, 101=20, 102=30

pushed = {}
poll._extract_row(string.char(0, 20), 0, R(101, 1, "uint16"))   -- 单行读
local solo = pushed[1]
pushed = {}
local blk = poll._build_plan({ R(100), R(101), R(102) })[1]
for _, it in ipairs(blk.rows) do
    poll._extract_row(data, it.off, it.r)
end
local inblk = nil
for _, x in ipairs(pushed) do if x.addr == 101 then inblk = x end end
local merged = pushed   -- 下面还要往 pushed 里塞别的用例, 先留住这块的结果
check("块里 101 解出的值 = 单独读的值", inblk and inblk.value == solo.value and inblk.value == 20,
    inblk and inblk.value or "没 push")
check("块里 101 的 hex = 单独读的 hex", inblk and inblk.hex == solo.hex and inblk.hex == hex_of(string.char(0, 20)),
    string.format("块内=%s 单读=%s", inblk and inblk.hex or "-", solo.hex))
check("单行读仍取整段 data 的 hex",
    (function()
        pushed = {}
        poll._extract_row(string.char(0, 20, 0, 21), 0, R(101, 2, "uint16"))
        return pushed[1].hex == hex_of(string.char(0, 20, 0, 21))
    end)(), "单行 hex 变了")
check("块里 3 行各 push 一次", #merged == 3, #merged)
check("块里 addr 序列 100/101/102", merged[1].addr == 100 and merged[2].addr == 101
    and merged[3].addr == 102, plan_str(blk))
check("块里每行 hex 只有自己的字", merged[3].hex == hex_of(string.char(0, 30)), merged[3].hex)

-- ==== 13. 32 位跨字: 100(uint32,count2) + 101 相邻 → 不该并(重叠) ====
pushed = {}
data = string.char(0, 0, 1, 0)                      -- 100..101 = 0x00000100 的 highs/lows
local n = poll._extract_row(data, 0, R(100, 2, "uint32"))
check("uint32 count=2 解出 1 个值", n == 1, n)
check("32 位值 push 在起始 addr", pushed[1] and pushed[1].addr == 100,
    pushed[1] and pushed[1].addr)

-- ==== 14. 仪表少回字: 块要 3 字只回 2 字 → 前两行有值, 第三行不 push ====
pushed = {}
data = string.char(0, 7, 0, 8)
blk = poll._build_plan({ R(100), R(101), R(102) })[1]
for _, it in ipairs(blk.rows) do poll._extract_row(data, it.off, it.r) end
check("少回字时解出 2 个值不越界", #pushed == 2, #pushed)
check("越界那行不脏数据", pushed[2].addr == 101 and pushed[2].value == 8,
    pushed[2] and pushed[2].addr)

-- ==== 15. 坏 dtype: 返回 nil, 不 push (和今天 parse_regs 返回 nil 一致) ====
pushed = {}
n = poll._extract_row(string.char(0, 1), 0, { addr = 9, count = 1, dtype = "wat" })
check("坏 dtype 返回 nil", n == nil, n)
check("坏 dtype 不 push", #pushed == 0, #pushed)

print(failed == 0 and "all poll merge checks passed"
    or string.format("%d poll merge check(s) FAILED", failed))
os.exit(failed == 0 and 0 or 1)
