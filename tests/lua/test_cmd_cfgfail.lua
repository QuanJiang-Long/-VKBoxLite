-- test_cmd_cfgfail.lua —— R:CFG 应答: 逐行拼、拼不出来就如实报 (2026-11-18)
--
-- 现场那两幕(真机, COM4):
--   32 点:  W:CFINISH → OK,  R:CFG → RET:CFG={}      ← jencode 兜底, 前端读成 0 行
--   60 点:  R:CFG → RET:FAIL:CFG:内存/内部异常: not enough memory
--   当时 R:MEM = lua:300520/307192 —— 整条应答要一次 encode 出 ~4KB,
--   encode 内部还要临时串, 池子拿不出来。
--
-- 这个文件钉五条:
--   1) 正常路径: 应答是【合法 JSON】, 60 行一行不少, 字段/slot/src 都对
--   2) 而且【不许整表 encode】: 单次 encode 的最大产物必须远小于整条应答
--      (一行 ~100B)。这是这次修复的核心 —— 峰值和行数无关
--   3) 某一行 encode 不出来(重试也失败) → RET:FAIL:CFG:<原因 池水位>,
--      一个字的 RET:CFG= 都不许多发(绝不发"少了半张表"的配置)
--   4) 第一次失败、丢缓存 + GC 之后成功 → 照常回完整数据
--   5) 原因里的换行要换掉(应答是一整行), R:REG 仍是正常 JSON
--
-- 跑法: tools\run_lua_tests.bat test_cmd_cfgfail.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;tests/lua/?.lua;' .. package.path

local mock = require "mock_json"

local writes = {}
local USED = 300520           -- 真机 60 点存完那一刻的水位
local DROP = 0                -- cfg.drop_cache 被叫了几次
local FAIL_ON = {}            -- 第 N 次 json.encode 抛(true) —— 键是调用序号
local CALLS = 0               -- 本次用例里 encode 被调了几次
local MAXOUT = 0              -- 单次 encode 产物的最大字节数
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

local CFG = {
    baud = 9600, databits = 8, stopbits = 1, parity = 0,
    slave = 1, interval_ms = 5000, timeout_ms = 200,
    regs = rows(60),
}

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
package.preload["bus/poll"] = function()
    return { get_regs = function() return CFG.regs end,
             is_running = function() return true end,
             status = function() return {} end }
end
package.preload["data/collector"] = function()
    return { snapshot = function() return {} end, stats = function() return {} end }
end
package.preload["iot/mqttcfg"] = function() return { load = function() return {} end } end
package.preload["cfg"] = function()
    return { load_poll = function() return CFG end,
             load_pull = function() return { regs = {} } end,
             poll_src = function() return "fskv" end,
             pull_src = function() return "pull" end,
             drop_cache = function() DROP = DROP + 1 return 3 end,
             load_sys = function() return { boot_mode = "idle" } end,
             load_infer = function() return { regs = {} } end,
             load_alias = function() return {} end }
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

-- ===== 1) 正常路径: 一条合法 JSON, 60 行一行不少 =====
FAIL_ON = {}
DROP = 0
local out = ask("R:CFG")
check("1 起头是 RET:CFG=", out:sub(1, 9) == "RET:CFG={", string.format("%q", out:sub(1, 40)))
check("1 一整行(以 \\r\\n 收尾, 中间没有换行)",
    out:sub(-2) == "\r\n" and not out:sub(1, -3):find("\n", 1, true),
    string.format("%q", out:sub(-6)))
local okp, payload = pcall(mock.decode, out:sub(9, -3))
check("1 能解成 JSON", okp and type(payload) == "table", tostring(payload))
check("1 cfg.regs 是 60 行", okp and payload.cfg and #(payload.cfg.regs or {}) == 60,
    okp and payload.cfg and #(payload.cfg.regs or {}) or "?")
check("1 行内容没串位(第 60 行的 addr=160)",
    okp and payload.cfg.regs[60] and payload.cfg.regs[60].addr == 160,
    okp and payload.cfg.regs[60] and payload.cfg.regs[60].addr or "?")
check("1 中文别名没被写坏",
    okp and payload.cfg.regs[60] and payload.cfg.regs[60].alias == "规模测试点60",
    okp and tostring(payload.cfg.regs[60] and payload.cfg.regs[60].alias))
check("1 串口参数都在", okp and payload.cfg.baud == 9600 and payload.cfg.slave == 1
    and payload.cfg.interval_ms == 5000 and payload.cfg.timeout_ms == 200, "字段缺失")
check("1 slot/src 都在", okp and payload.slot == "poll" and payload.src == "fskv",
    okp and (tostring(payload.slot) .. "/" .. tostring(payload.src)))
check("1 正常路径不白丢缓存", DROP == 0, tostring(DROP))
-- 这一条是本次修复的核心: 峰值和行数无关
check("1 单次 encode 的产物 < 512B(证明没整表 encode)", MAXOUT < 512,
    string.format("最大一次 %dB, 整条应答 %dB", MAXOUT, #out))
check("1 整条应答确实 > 4KB(60 行)", #out > 4096, tostring(#out))
-- 流式发送: 串口上是分多次写的, 单次不超过一个发送缓冲(512B + 一次 add 的余量)
local maxw, nw = 0, #writes
for _, w in ipairs(writes) do if #w > maxw then maxw = #w end end
check("1 分多次写、单次 <= 640B(证明没攒成整条再发)", nw >= 10 and maxw <= 640,
    string.format("%d 次, 最大 %dB", nw, maxw))

-- ===== 2) 某一行编码不出来(重试也失败): 必须如实报, 不发半张表 =====
-- 前两次 encode 都失败: 第一次是首轮, 第二次是"重试从头发起"的第一个 encode
FAIL_ON = { [1] = true, [2] = true }
DROP = 0
local out3 = ask("R:CFG")
check("2 改成 RET:FAIL:CFG:", out3:sub(1, 13) == "RET:FAIL:CFG:", string.format("%q", out3))
check("2 带 C 层那句原话", out3:find(ERRMSG, 1, true) ~= nil, string.format("%q", out3))
check("2 带池水位(分清【拼不出来】和【没有配置】)",
    out3:find("pool 300520/307192", 1, true) ~= nil, string.format("%q", out3))
check("2 一个字的假 RET:CFG= 都没发", out3:find("RET:CFG=", 1, true) == nil, string.format("%q", out3))
check("2 失败前真的丢过缓存(重试路径在跑)", DROP >= 1, tostring(DROP))
check("2 仍然是一整行", out3:sub(-2) == "\r\n" and not out3:sub(1, -3):find("\n", 1, true),
    string.format("%q", out3))

-- ===== 3) 第一次失败, 丢缓存 + GC 之后成功: 完整数据照回 =====
FAIL_ON = { [1] = true }
DROP = 0
local out4 = ask("R:CFG")
local ok4, p4 = pcall(mock.decode, out4:sub(9, -3))
check("3 重试成功后回的是完整数据", ok4 and p4 and #(p4.cfg.regs or {}) == 60,
    ok4 and (p4.cfg and #(p4.cfg.regs or {}) or "?") or tostring(p4))
check("3 重试前丢过缓存", DROP >= 1, tostring(DROP))

-- ===== 4) 原因里带换行: 换掉, 不搅乱后面的帧 =====
ERRMSG = "line1\r\n" .. string.rep("x", 300)
FAIL_ON = { [1] = true, [2] = true }
local out5 = ask("R:CFG")
check("4 原因里的换行被换成空格", not out5:sub(1, -3):find("\n", 1, true), string.format("%q", out5))
check("4 仍然从 RET:FAIL:CFG: 起头", out5:sub(1, 13) == "RET:FAIL:CFG:", string.format("%q", out5))
ERRMSG = "not enough memory for buffer allocation"

-- ===== 5) regs 为空/缺字段: 仍然是合法 JSON(空配置 != 失败) =====
FAIL_ON = {}
local saved_regs = CFG.regs
CFG.regs = {}
local out6 = ask("R:CFG")
local ok6, p6 = pcall(mock.decode, out6:sub(9, -3))
check("5 空 regs 照样是合法 JSON, 不是 FAIL",
    ok6 and p6 and p6.cfg and type(p6.cfg.regs) == "table" and #p6.cfg.regs == 0,
    string.format("%q", out6:sub(1, 60)))
CFG.regs = saved_regs

if failed > 0 then
    print(string.format("FAIL: %d 条不过 (%d 条)", failed, checked))
    os.exit(1)
end
print("PASS: R:CFG 逐行拼应答 —— 峰值与行数无关, 拼不出来就直说")
