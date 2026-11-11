-- test_cmd_ctrace.lua —— W:CFG 分阶段内存采样的单测 (2026-11-11)
--
-- 背景: 128 点卡在【内存峰值】这道门上, 而厂家给的那张峰值表是估的。要在
-- 真机上把"解码/归一化/落盘各吃多少、峰究竟在哪一步"量出来, 只有靠进出口
-- 各采一次样 —— 而这条路径正好是保存配置那条, 测错了会连带把结论带歪。
-- 所以这个探针要钉死的不是"数字对不对", 而是三件结构性的事:
--   1) 采样点【夹住】被测操作: norm 那一次必须在 normalize_poll 返回之后、
--      放开 t 之前(那一刻 t 和 n 同时在堆上, 就是这条路径的峰); decoded 必须
--      在解码之后。采样点错一个位置, 整张表就是错的结论。
--   2) used 抓不到的【瞬时峰】由 max 抓到: 落盘时 jencode 那份整串 JSON 返回
--      即消失, used 一路不变、max 会涨 —— 用例里 saved 段必须 max > used。
--   3) 发布版一个字节都不许多走: DEBUG 关掉以后不注册 R:CTRACE、一次 meminfo
--      都不问、一次额外 GC 都不做(采样里那次 collectgarbage 是给 freed 用的,
--      不能变成保存配置的新停顿), 该 >4096B 才做的那次入口 GC 原样保留。
-- 另外钉住失败路径: 保存失败时那条采样必须还在(失败那次才最值钱, 不能被下一次
-- 保存挤掉), 且段数停在死掉的那一步上 —— 现场读出来的就是"死在第几步"。
--
-- 跑法: tools\run_lua_tests.bat test_cmd_ctrace.lua
--   或 firmware\> lua ..\tests\lua\test_cmd_ctrace.lua

local writes, events = {}, {}
local mem = { total = 307192, used = 100000, max = 100000, calls = 0 }
local gc_calls = 0
local decode_ok, norm_ok, save_ok = true, true, true -- 三个闸门逐个往下走失败
local norm_regs = 8             -- 归一化结果里的点数(报给 regs= 字段)
local has_rtos = true
-- 每个操作【结束时】堆上实际剩多少 / 内部冒过又立刻还掉的瞬时峰
local after = { decode = 150000, norm = 190000, save = 190000, apply = 200000 }
local peak_save = 195000

local function ev(name) events[#events + 1] = name end
local function rise(v)
    mem.used = v
    if v > mem.max then mem.max = v end
end

package.preload["util"] = function()
    local L = {}
    for _, lv in ipairs({ "debug", "info", "warn", "error" }) do L[lv] = function() end end
    local libs = {
        uart = { VUART_0 = 4,
                 write = function(_, s) writes[#writes + 1] = s return #s end,
                 read = function() return "" end, on = function() end },
        json = {
            encode = function() return "{}" end,
            decode = function()
                ev("decode")
                if not decode_ok then return nil end
                rise(after.decode)
                return { regs = {} }, true
            end,
        },
    }
    if has_rtos then
        libs.rtos = { meminfo = function(k)
            if k ~= "lua" then return 203040, 67940, 70000 end
            mem.calls = mem.calls + 1
            return mem.total, mem.used, mem.max
        end }
    end
    return { log = function() return L end,
             get = function(n) return libs[n] end,
             try = function(n) return libs[n] end }
end
package.preload["core/config"] = function() return { BAUD = 9600 } end
package.preload["sn/sn"] = function()
    return { state = function() return "empty" end, info_line = function() return "" end }
end
package.preload["bus/ctrl"] = function()
    return { get_mode = function() return "manual" end,
             status = function() return { mode = "manual" } end }
end
package.preload["bus/mon"] = function() return { is_detecting = function() return false end } end
package.preload["data/collector"] = function() return { stats = function() return {} end } end
package.preload["cfg"] = function()
    return {
        load_poll = function() return { regs = {} } end,
        poll_src = function() return "poll" end,
        load_sys = function() return { boot_mode = "idle" } end,
        normalize_poll = function()
            ev("norm")
            if not norm_ok then return nil, "bad slave" end
            rise(after.norm)
            local regs = {}
            for i = 1, norm_regs do regs[i] = { addr = i } end
            return { regs = regs }
        end,
        save_poll_norm = function()
            ev("save")
            if not save_ok then return false, "value too big" end
            -- used 不变(那份 JSON 字符串返回即还掉), 只有 max 涨 ——
            -- 这就是"采样点看不见、这一步确实发生过的瞬时峰"
            rise(after.save)
            if peak_save > mem.max then mem.max = peak_save end
            return true
        end,
        save_pull_norm = function() return true end,
    }
end
package.preload["bus/poll"] = function()
    return {
        needs_restart = function() return false end,
        is_running = function() return true end,
        stop = function() end,
        start = function() end,
        apply_cfg = function()
            ev("apply")
            rise(after.apply)
        end,
    }
end
package.preload["iot/mqttcfg"] = function() return {} end

local real_gc = collectgarbage
_G.collectgarbage = function() gc_calls = gc_calls + 1 return 0 end

local failed, checked = 0, 0
local function check(name, ok, detail)
    checked = checked + 1
    if ok then
        print(string.format("ok   %s", name))
    else
        failed = failed + 1
        print(string.format("FAIL %s: %s", tostring(detail or ""), name))
    end
end

-- 换 DEBUG 要连 util 一起重载: cmd 顶部 rtos = util.try("rtos") 是加载期取的,
-- 只重载 svc/cmd 会拿到缓存的 util, has_rtos 就永远关不掉
local function load_cmd(debug_on)
    _G.DEBUG = debug_on or nil
    package.loaded["svc/cmd"] = nil
    package.loaded["util"] = nil
    local m = require "svc/cmd"
    m.init()
    return m
end

-- 发一条 W:CFG, 返回拼回去的串口字节(拼接只在测试里做, 被测路径不做)
local function send_cfg(mod, body)
    writes, events = {}, {}
    mod.handle("W:CFG=" .. body)
    return table.concat(writes, "")
end

-- R:CTRACE 的 #tag 那一行(两条采样分两行发, 混在一起读会串)
local function tag_line(mod, tag)
    writes = {}
    assert(mod.handle("R:CTRACE"), "R:CTRACE 没注册")
    local out = table.concat(writes, "")
    for ln in (out .. "\r\n"):gmatch("([^\r]*)\r\n") do
        if ln:find("RET:CTRACE=" .. tag, 1, true) then return ln end
    end
    return nil
end

local function nlines(mod)
    writes = {}
    mod.handle("R:CTRACE")
    local out = table.concat(writes, "")
    local n = select(2, out:gsub("RET:CTRACE=", ""))
    return n, out
end

local function stages(line)
    if not line then return "<没有这一行>" end
    local out = {}
    for w in line:gmatch("| (%a+) %-?%d+/%-?%d+") do out[#out + 1] = w end
    return table.concat(out, ",")
end

local BODY = '{"baud":9600,"regs":[{"addr":1}]}' -- 小配置: 不触发入口那次 GC

------------------------------------------------------------------
-- ① 开发版: 七段齐全, 每段夹在正确的操作之间
------------------------------------------------------------------
local dev = load_cmd(true)
local out = send_cfg(dev, BODY)
check("① 小配置保存成功", out == "RET:CFG=OK\r\n", out)
check("① 小配置只多了 freed 那一次 GC", gc_calls == 1, gc_calls)
local l2 = tag_line(dev, "#2")
check("① 七段全在且顺序对",
    stages(l2) == "enter,gc,decoded,norm,freed,saved,done", l2)
check("① 头报了命令行长度/点数/池大小",
    l2:find("arg=" .. #BODY .. " regs=" .. norm_regs .. " tot=307192", 1, true) ~= nil, l2)
-- 采样点位置 = 结论对不对的命门: 每段读到的 used 是【那个时刻】的量,
-- 早一步晚一步都会读到上一个操作留下的数
check("① decoded 段在解码之后(读到解码后的水位)", l2:find("decoded 150000/", 1, true) ~= nil, l2)
check("① norm 段在归一化之后、放开 t 之前(峰就落在这个采样点上)",
    l2:find("norm 190000/", 1, true) ~= nil, l2)
check("① freed 段 max 还没涨(证明 save 的峰不是提前冒的)",
    l2:find("freed 190000/190000", 1, true) ~= nil, l2)
check("① saved 段用 max 抓住 used 抓不到的瞬时峰",
    l2:find("saved 190000/195000", 1, true) ~= nil, l2)
check("① done 段在重启轮询之后", l2:find("done 200000/", 1, true) ~= nil, l2)
check("① 操作顺序本身也钉一遍", table.concat(events, ",") == "decode,norm,save,apply",
    table.concat(events, ","))
check("① 每段一次 meminfo + 头一次拿池大小", mem.calls == 8, mem.calls)

------------------------------------------------------------------
-- ② 失败路径: 采样停在死掉的那一步, 而且不被下一次保存挤掉
------------------------------------------------------------------
local function one_case(ok_dec, ok_norm, ok_save)
    decode_ok, norm_ok, save_ok = ok_dec, ok_norm, ok_save
    local r = send_cfg(dev, BODY)
    decode_ok, norm_ok, save_ok = true, true, true
    return r
end

local r = one_case(false, true, true)
check("② 坏 JSON 照实回失败", r == "RET:FAIL:CFG:bad json\r\n", r)
check("② 坏 JSON 的采样停在 decoded", stages(tag_line(dev, "#2")) == "enter,gc,decoded")

r = one_case(true, false, true)
check("② 归一化失败回原因", r == "RET:FAIL:CFG:bad slave\r\n", r)
local t2 = tag_line(dev, "#2")
check("② 归一化失败的采样停在 norm", stages(t2) == "enter,gc,decoded,norm", t2)
check("② 归一化失败时点数报 -1 而不是冒充 0", t2:find(" regs=-1", 1, true) ~= nil, t2)

r = one_case(true, true, false)
check("② 落盘失败回原因", r == "RET:FAIL:CFG:value too big\r\n", r)
t2 = tag_line(dev, "#2")
check("② 落盘失败的采样停在 saved(128 点就是这个签名)",
    stages(t2) == "enter,gc,decoded,norm,freed,saved", t2)
check("② 落盘失败没碰轮询", table.concat(events, ",") == "decode,norm,save",
    table.concat(events, ","))
-- 失败那条值不值钱, 看的是"再存一次成功的"之后它还在不在
send_cfg(dev, BODY)
t2 = tag_line(dev, "#1")
check("② 再存一次成功的, 上次落盘失败那条还在(#1)",
    stages(t2) == "enter,gc,decoded,norm,freed,saved", t2)

------------------------------------------------------------------
-- ③ 只保最近两条: #1=上一条, #2=最新一条
------------------------------------------------------------------
send_cfg(dev, BODY)
send_cfg(dev, BODY)
local n, all = nlines(dev)
check("③ 只发两行", n == 2, n .. " " .. all)
check("③ 每行各自以 CRLF 结尾", all:sub(-2) == "\r\n" and select(2, all:gsub("\r\n", "")) == 2, all)

------------------------------------------------------------------
-- ④ 没有 rtos 库: 不许崩, 也不许拿 0 冒充水位(0/0 会被读成"池子空着")
------------------------------------------------------------------
has_rtos = false
local bare = load_cmd(true)
has_rtos = true
local ok_run = pcall(send_cfg, bare, BODY)
local l4 = ok_run and tag_line(bare, "#2") or nil
check("④ 没有 rtos 不崩", ok_run)
check("④ 没有 rtos 仍给七段", stages(l4) == "enter,gc,decoded,norm,freed,saved,done", l4)
check("④ 采样缺数据时报 -1", l4:find("enter -1/-1", 1, true) ~= nil, l4)
check("④ 池大小也报 -1", l4:find("tot=-1", 1, true) ~= nil, l4)

------------------------------------------------------------------
-- ⑤ 发布版(DEBUG 关): 一个字节都不许多走
------------------------------------------------------------------
local rel = load_cmd(false)
gc_calls, mem.calls = 0, 0
local r5 = send_cfg(rel, BODY)
check("⑤ 发布版保存行为不变", r5 == "RET:CFG=OK\r\n", r5)
check("⑤ 发布版一次 meminfo 都不问", mem.calls == 0, mem.calls)
check("⑤ 发布版不注册 R:CTRACE", rel.handle("R:CTRACE") == false)
check("⑤ 发布版小配置零 GC(采样那次没漏进发布版)", gc_calls == 0, gc_calls)

-- 大配置的入口 GC 是本来就在的(83847fe), 不能被采样改动
local big = string.rep(" ", 5000)
gc_calls = 0
local r6 = send_cfg(rel, big)
check("⑤ 发布版 >4096B 仍做一次入口 GC", gc_calls == 1, gc_calls)
check("⑤ 发布版大配置照样存进去", r6 == "RET:CFG=OK\r\n", r6)

gc_calls = 0
send_cfg(dev, big)
check("⑤ 开发版大配置 = 入口 GC + freed 那次, 不多做", gc_calls == 2, gc_calls)

_G.collectgarbage = real_gc

if failed > 0 then
    print(string.format("test_cmd_ctrace: %d/%d 失败", failed, checked))
    os.exit(1)
end
print(string.format("test_cmd_ctrace: %d 个断言全部通过", checked))
