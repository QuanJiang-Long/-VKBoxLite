-- test_cmd_reg.lua —— R:REG 应答: 逐行编码 + 流式发送 (2026-11-18)
--
-- 为什么单独钉: 前端「读取配置」会连着发 R:CFG + R:REG(cfg.js readCfg)。
--   60 点在真机上存完只剩 6.7KB, R:CFG 已经因为"整条应答要一块连续内存"
--   失败过(见 test_cmd_cfgfail.lua); R:REG 返回的是同一张 60 行的表, 整表
--   encode(约 7KB)是同一个死法, 所以一起改成【逐行 encode + 流式写】。
--
-- 这个文件钉四条:
--   1) 60 行回来仍是合法 JSON 数组, 行内容不串位
--   2) 单次 encode 的产物 < 512B, 串口上是分多次写的(峰值 = 一个缓冲)
--   3) 一行都编不出来(重试也失败) → RET:FAIL:REG:<原因 池水位>, 不发半张表
--   4) 空表 → RET:REG=[](前端两种都认, 不能回 "配置读失败")
--
-- 跑法: tools\run_lua_tests.bat test_cmd_reg.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;tests/lua/?.lua;' .. package.path

local mock = require "mock_json"

local writes = {}
local USED = 300520
local FAIL_ON = {}
local CALLS = 0
local MAXOUT = 0
local ERRMSG = "not enough memory for buffer allocation"

local real_encode = mock.encode
local function enc(v)
    CALLS = CALLS + 1
    if FAIL_ON[CALLS] then error(ERRMSG, 0) end
    local s = real_encode(v)
    if #s > MAXOUT then MAXOUT = #s end
    return s
end

local function rows(n)
    local t = {}
    for i = 1, n do
        t[i] = { addr = 100 + i, count = 1, name = "R" .. i,
                 alias = "规模测试点" .. i, dtype = "uint16" }
    end
    return t
end

local REGS = rows(60)

package.preload["util"] = function()
    local L = {}
    for _, lv in ipairs({ "debug", "info", "warn", "error" }) do L[lv] = function() end end
    local libs = {
        uart = { VUART_0 = 4,
                 write = function(_, s) writes[#writes + 1] = s return #s end,
                 read = function() return "" end, on = function() end },
        json = { encode = enc, decode = mock.decode },
        rtos = { meminfo = function(k)
                     if k == "lua" then return 307192, USED, 307192 end
                     return 198000, 76000, 90000
                 end },
    }
    return { log = function() return L end,
             get = function(n) return libs[n] end,
             try = function(n) return libs[n] end }
end
package.preload["core/config"] = function() return { BAUD = 9600 } end
package.preload["sn/sn"] = function()
    return { state = function() return "ready" end, imei = function() return "" end,
             uid = function() return "" end, locked = function() return false end }
end
package.preload["bus/ctrl"] = function()
    return { get_mode = function() return "manual" end, status = function() return {} end }
end
package.preload["bus/mon"] = function() return { is_detecting = function() return false end } end
-- R:REG 走 pollmod(false): 必须先由某条指令把 bus/poll 拉进来(真机开机就会)
package.preload["bus/poll"] = function()
    return { get_regs = function() return REGS end,
             probe_raw = function() return nil, "mock" end,
             is_running = function() return true end,
             status = function() return {} end }
end
package.preload["data/collector"] = function()
    return { snapshot = function() return {} end, stats = function() return {} end }
end
package.preload["iot/mqttcfg"] = function() return { load = function() return {} end } end
package.preload["cfg"] = function()
    return { load_poll = function() return { regs = {} } end,
             load_pull = function() return { regs = {} } end,
             load_alias = function() return { regs = {} } end,
             poll_src = function() return "poll" end,
             pull_src = function() return "pull" end,
             drop_cache = function() return 0 end,
             load_sys = function() return { boot_mode = "manual" } end }
end

_G.DEBUG = true
local cmd = require "svc/cmd"
cmd.init()

local failed, checked = 0, 0
local function check(name, ok, detail)
    checked = checked + 1
    if ok then
        print(string.format("ok   %s", name))
    else
        failed = failed + 1
        print(string.format("FAIL %s: %s", name, tostring(detail or "")))
    end
end

local function ask(line)
    writes = {}
    CALLS, MAXOUT = 0, 0
    cmd.handle(line)
    return table.concat(writes, "")
end

-- 把 bus/poll 拉进来: 真机开机起轮询时就有, 单测里借 W:RAWTEST 触发一次
--   (它只调 pollmod(true), 应答内容与本用例无关)
FAIL_ON = {}
cmd.handle("W:RAWTEST")
check("前提: bus/poll 已加载", cmd.poll_loaded() == true, "poll 没被拉进来")

-- ===== 1) 正常路径: 合法 JSON 数组, 60 行 =====
local out = ask("R:REG")
check("1 起头是 RET:REG=[", out:sub(1, 9) == "RET:REG=[", string.format("%q", out:sub(1, 30)))
check("1 一整行(中间没有换行)", out:sub(-2) == "\r\n" and not out:sub(1, -3):find("\n", 1, true),
    string.format("%q", out:sub(-6)))
local ok1, arr = pcall(mock.decode, out:sub(9, -3))
check("1 能解成 JSON 数组", ok1 and type(arr) == "table" and #arr == 60, tostring(arr))
check("1 第 60 行的 addr=160(没串位)", ok1 and arr[60] and arr[60].addr == 160,
    ok1 and arr[60] and arr[60].addr or "?")
check("1 中文别名没被写坏", ok1 and arr[60] and arr[60].alias == "规模测试点60",
    ok1 and tostring(arr[60] and arr[60].alias))
-- 峰值与行数无关: 单次 encode 只是一行
check("1 单次 encode 的产物 < 512B(没整表 encode)", MAXOUT < 512,
    string.format("最大一次 %dB, 整条应答 %dB", MAXOUT, #out))
local maxw, nw = 0, #writes
for _, w in ipairs(writes) do if #w > maxw then maxw = #w end end
check("1 分多次写、单次 <= 700B(没攒成整条再发)", nw >= 5 and maxw <= 700,
    string.format("%d 次, 最大 %dB", nw, maxw))

-- ===== 2) 编不出来(重试也失败) → 如实报, 不发半张表 =====
FAIL_ON = { [1] = true, [2] = true }
local out2 = ask("R:REG")
check("2 改成 RET:FAIL:REG:", out2:sub(1, 13) == "RET:FAIL:REG:", string.format("%q", out2))
check("2 带 C 层那句原话", out2:find(ERRMSG, 1, true) ~= nil, string.format("%q", out2))
check("2 带池水位", out2:find("pool 300520/307192", 1, true) ~= nil, string.format("%q", out2))
check("2 一个字的假 RET:REG= 都没发", out2:find("RET:REG=", 1, true) == nil, string.format("%q", out2))

-- ===== 3) 第一次失败、GC 之后成功 → 完整 60 行 =====
FAIL_ON = { [1] = true }
local out3 = ask("R:REG")
local ok3, arr3 = pcall(mock.decode, out3:sub(9, -3))
check("3 重试成功后回完整 60 行", ok3 and arr3 and #arr3 == 60,
    ok3 and (arr3 and #arr3 or "?") or tostring(arr3))

-- ===== 4) 空表: 仍是合法应答, 不是失败 =====
FAIL_ON = {}
local saved = REGS
REGS = {}
local out4 = ask("R:REG")
check("4 空表回 RET:REG=[]", out4 == "RET:REG=[]\r\n", string.format("%q", out4))
REGS = saved

if failed > 0 then
    print(string.format("FAIL: %d 条不过 (%d 条)", failed, checked))
    os.exit(1)
end
print("PASS: R:REG 逐行编码 + 流式发送 —— 峰值与行数无关")
