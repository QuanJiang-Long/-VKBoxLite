-- test_cmd_tx.lua —— 应答【发送路径】的单测 (2026-11-10)
--
-- 背景: 128 点排障时现场报
--   RET:FAIL:handler error:cmd.lua:100: not enough memory for buffer allocation
-- 那一线是 reply_json 里的 table.concat —— jencode 已经产出 3919B 应答体,
-- concat 还要同样大的【连续块】, Lua 池贴着天花板时切不出来。
-- 改成逐段 uart.write 后, 发送峰值从 2 倍应答体降到 1 倍。
--
-- 这里钉住两件事, 缺一不可:
--   1) 串口上的字节【一字没变】: 前端 main.js 和产线 serial_port.py 都按
--      \r\n 切行, 拆包对它们透明 —— 但前提是拆完重新拼回去还得跟原来一样,
--      而且每行结尾必须带着 \r\n。少一个换行, 下一条应答就粘到这一条上。
--   2) 真的没再抄一份: 一次发送期间的净分配必须远小于应答体。
--      这条就是这次改动的全部收益, 退回 concat 就该被它抓住。
--
-- 顺带钉 R:MEM 的应答长度(现场日志只打前 80 字节, 超了就看不见)。
--
-- 跑法: tools\run_lua_tests.bat test_cmd_tx.lua

local writes, logs = {}, {}
local BODY = '{"v":1}' -- 应答体: 预生成后全程复用, 测量里不含"编码本身"的分配

local function uart_stub()
    return { VUART_0 = 4,
             write = function(_, s) writes[#writes + 1] = s return #s end,
             read = function() return "" end, on = function() end }
end
local function json_stub()
    return { encode = function() return BODY end,
             decode = function(s) return { _raw = s }, true end }
end
local function rtos_stub()
    return { meminfo = function(k)
        if k == "lua" then return 307192, 306768, 306900 end
        return 203040, 67940, 70000
    end }
end
local function guard_stub()
    return { status = function() return { uptime = 10 } end }
end

package.preload["util"] = function()
    local L = {}
    for _, lv in ipairs({ "debug", "info", "warn", "error" }) do
        L[lv] = function(_, key, a, b, c)
            if lv == "debug" then logs[#logs + 1] = { key, a, b, c } end
        end
    end
    local libs = { uart = uart_stub(), json = json_stub(), rtos = rtos_stub(),
                   ["svc/guard"] = guard_stub() }
    return {
        log = function() return L end,
        get = function(n)
            if libs[n] then return libs[n] end
            error("no lib " .. tostring(n))
        end,
        try = function(n) return libs[n] end,
    }
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
package.preload["data/collector"] = function()
    return { stats = function() return { ok = 1 } end }
end
package.preload["cfg"] = function()
    return { load_poll = function() return { regs = {} } end,
             poll_src = function() return "poll" end,
             load_sys = function() return { boot_mode = "idle" } end }
end
package.preload["iot/mqttcfg"] = function() return {} end

_G.DEBUG = true -- 注册调试组(R:MEM 在里面), 与开发版一致
local cmd = require "svc/cmd"
cmd.init()

local failed = 0
local checked = 0
local function check(name, ok, detail)
    checked = checked + 1
    if ok then
        print(string.format("ok   %s", name))
    else
        failed = failed + 1
        print(string.format("FAIL %s: %s", tostring(detail or ""), name))
    end
end

-- 发一条指令, 返回【拼回去】的串口字节(拼接只在本测试里做, 被测路径不做)
local function ask(line)
    writes = {}
    logs = {}
    local ok = cmd.handle(line)
    return ok, table.concat(writes)
end

-- ===== 1) 应答体 3919B: 串口上的字节必须和整行发送完全一致 =====
BODY = string.rep("x", 3919)
local ok, out = ask("R:CFG")
check("R:CFG 有应答", ok and out ~= "", "没发出东西")
check("拼回去和整行一字不差", out == "RET:CFG=" .. BODY .. "\r\n",
    string.format("长度 %d / 期望 %d", #out, #BODY + 12))
check("行尾带 \\r\\n", out:sub(-2) == "\r\n", string.format("%q", out:sub(-4)))
local segs = #writes
local longest = 0
for i = 1, segs do if #writes[i] > longest then longest = #writes[i] end end
check("拆成了多段", segs == 3, "段数=" .. segs)
check("没有哪一段装着整行", longest < #out,
    string.format("最长段 %d / 整行 %d", longest, #out))
check("最长段恰好是应答体", longest == #BODY, "最长段 " .. longest)

-- ===== 2) 净分配: 一次发送不该再抄出第二份应答体 =====
local function net_bytes(fn)
    collectgarbage("collect") collectgarbage("collect")
    local c0 = collectgarbage("count")
    fn()
    return (collectgarbage("count") - c0) * 1024
end
local dirty = net_bytes(function()
    writes = {}
    logs = {}
    cmd.handle("R:CFG")
end)
print(string.format("R:CFG(应答体 %dB) 一次发送净分配 %d 字节", #BODY, math.floor(dirty)))
check("净分配不超过半份应答体", dirty < #BODY * 0.5,
    string.format("净分配 %d / 应答体 %d", math.floor(dirty), #BODY))

-- ===== 3) 多段 JSON(R:STAT)的结构没被拆坏 =====
BODY = '{"v":1}'
local _, s2 = ask("R:STAT")
check("R:STAT 以 RET:STAT={ 开头", s2:sub(1, 10) == "RET:STAT={", s2:sub(1, 60))
check("R:STAT 行尾带 \\r\\n", s2:sub(-2) == "\r\n", string.format("%q", s2:sub(-4)))
check("R:STAT 没有 ,,", not s2:find(",,", 1, true), s2)
check("R:STAT 没有 ,}", not s2:find(",}", 1, true), s2)
check("R:STAT 没有 {,", not s2:find("{,", 1, true), s2)
local depth, minv = 0, 0
for i = 1, #s2 do
    local c = s2:sub(i, i)
    if c == "{" then depth = depth + 1 elseif c == "}" then depth = depth - 1 end
    if depth < minv then minv = depth end
end
check("R:STAT 花括号配平", depth == 0 and minv >= 0,
    string.format("结束=%d 最低=%d", depth, minv))
check("R:STAT 顶层字段齐", s2:find('"mode":', 1, true) and s2:find('"data":', 1, true)
    and s2:find('"guard":', 1, true), s2:sub(1, 120))

-- ===== 4) 短应答(M.reply)也带着换行 =====
local _, s3 = ask("R:BOOTMODE")
check("R:BOOTMODE 内容没变", s3:gsub("\r\n$", "") == "RET:BOOTMODE=idle", s3)
check("R:BOOTMODE 行尾带 \\r\\n", s3:sub(-2) == "\r\n", string.format("%q", s3:sub(-4)))

-- ===== 5) 日志里的长度/预览 = 串口上的实际字节 =====
ask("R:CFG")
local total = 0
for i = 1, #writes do total = total + #writes[i] end
local logged, preview
for i = 1, #logs do
    if logs[i][1] == "tx:" then logged, preview = logs[i][2], logs[i][4] end
end
check("日志长度 = 实发字节数", logged == total,
    string.format("日志 %s / 实发 %d", tostring(logged), total))
check("预览掐在 80 字节内", preview and #preview <= 80,
    preview and #preview or "没有预览")
check("预览带着应答头", preview and preview:sub(1, 8) == "RET:CFG=",
    string.format("%q", tostring(preview and preview:sub(1, 40))))

-- ===== 6) R:MEM: 现场日志只留前 80 字节, 应答必须压进去 =====
-- 调试组只在 _G.DEBUG 下注册(发布版整组不进注册表), 拿不到就跳过而不是判失败
local has_mem = cmd.handle("R:MEM") ~= false
local _, s4 = ask("R:MEM")
if not has_mem then
    print("  (跳过 R:MEM 用例: 调试组未注册)")
else
    check("R:MEM 有应答", s4:sub(1, 8) == "RET:MEM=", s4:sub(1, 40))
    check("R:MEM 不超过 80 字节", #s4 - 2 <= 80, string.format("%d 字节: %s", #s4 - 2, s4))
    check("R:MEM 报了 Lua 水位", s4:find("lua:%d+K", 1) ~= nil, s4)
    check("R:MEM 报了 Lua 池", s4:find("lua:%d+/%d+", 1) ~= nil, s4)
    check("R:MEM 报了系统池", s4:find("sys:%d+/%d+", 1) ~= nil, s4)
    check("R:MEM 报了最大连续块", s4:find("max:%d+ fail:%d+", 1) ~= nil, s4)
    local mx = tonumber(s4:match("max:(%d+)"))
    check("试探至少给出 4096", mx and mx >= 4096, "max=" .. tostring(mx))
end

if failed > 0 then
    print(string.format("FAIL: %d/%d 项不通过", failed, checked))
    os.exit(1)
end
print(string.format("test_cmd_tx: %d 个断言全部通过", checked))
