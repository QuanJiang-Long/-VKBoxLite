-- test_prov_rx.lua —— 生产串口(vuart)命令收包切行的单测 (2026-11-10)
--
-- 背景: 现场保存 90/128 点寄存器表时, W:CFG 一整行有 5~12.7KB, 而 Lua 堆
--   池总共才 300KB、地板(活对象)就有 253KB —— 见 test_gc_pressure.lua 的
--   结论。老收包代码每收 1024 字节就 `rx_buf = rx_buf .. data`, 一条 12KB
--   的命令要连抄十几次(1+2+…+12KB ≈ 78KB 垃圾), 在最紧的地方白扔几十 KB。
--   现在改成先攒分片、只在真攒出完整一行时并一次, 单分片时一次都不抄。
--
-- 这个改动动的是 SN 烧写工具的通道, 切错一行就是烧错 SN / 存错配置,
-- 所以钉住下面这些事实:
--   1) 分包到达的大命令逐字节还原, 没凑齐整行前【绝不】派活
--   2) 一片里塞两行 / \r\n 的 \r 和 \n 正好被切开, 都不能错位
--   3) 处理期间的yield(W:CFG 重启轮询要 sys.wait(500))里新到的字节
--      不丢、不乱序 —— 这条是 re-entrancy, 最容易改坏
--   4) 超过 MAX_BUF 整批丢, 之后来了完整一行照样能解析
--
-- 跑法: tools\run_lua_tests.bat test_prov_rx.lua

-- prov.lua 只要 util 这一个入口碰到 LuatOS, 拿假 util 换掉就能在纯 Lua 里跑
local fed = {}        -- vcom_handle 收到的整行
local uart_writes = {}
local logs = {}

package.preload["util"] = function()
    return {
        log = function()
            local L = {}
            local function rec(level, tag, ...)
                local t = { level, tag }
                for i = 1, select("#", ...) do
                    local v = select(i, ...)
                    t[#t + 1] = type(v) == "string" and v or tostring(v)
                end
                logs[#logs + 1] = table.concat(t, " ")
            end
            for _, lv in ipairs({ "debug", "info", "warn", "error" }) do
                L[lv] = function(...) rec(lv, ...) end
            end
            return L
        end,
        get = function(name)
            assert(name == "uart", "prov 只该 get uart, 收到 " .. tostring(name))
            return {
                VUART_0 = 4,
                read = function() return "" end,
                write = function(_, s) uart_writes[#uart_writes + 1] = s; return s:len() end,
            }
        end,
        try = function() return nil end,
    }
end

local prov = require "sn/prov"

local failed = 0
local function check(name, ok, detail)
    if ok then
        print(string.format("ok   %s", name))
    else
        failed = failed + 1
        print(string.format("FAIL %s: %s", name, tostring(detail or "")))
    end
end

-- 派活钩子: prov 把非 SN 命令一律转给 _G.vcom_handle
_G.vcom_handle = function(line)
    fed[#fed + 1] = line
    return true
end

local function reset() fed = {}; logs = {}; uart_writes = {} end

local function feed_lines(...)   -- 一次喂若干完整行
    for _, l in ipairs({ ... }) do prov._rx_feed(l .. "\r\n") end
    return prov.poll()
end

-- ===== 1) 分包的大命令: 逐字节还原 + 没凑齐整行不派活 =====
do
    reset()
    -- 造一条 128 点的 W:CFG(前端 protocol.js 就是 'W:CFG=' + JSON.stringify)
    local regs = {}
    for i = 1, 128 do
        regs[#regs + 1] = string.format(
            '{"addr":%d,"count":1,"name":"%d","alias":"寄存器%d","dtype":"uint16"}', i, i, i)
    end
    local body = 'W:CFG={"baud":9600,"slave":1,"interval_ms":5000,"timeout_ms":500,"regs":['
        .. table.concat(regs, ",") .. "]}"
    check("命令够大(能体现抄串代价)", #body > 4000, "实际 " .. #body .. " 字节")

    local got = 0
    for i = 1, #body, 1024 do
        prov._rx_feed(body:sub(i, math.min(i + 1023, #body)))
        got = prov.poll()
        if got > 0 then break end          -- 半行就被派活了
    end
    check("分片期间不提前派活", got == 0, "提前收到 " .. got .. " 条")
    check("半行时一次都没派活", #fed == 0, "已经派了 " .. #fed .. " 条")

    prov._rx_feed("\r\n")
    local n = prov.poll()
    check("补齐换行后派出 1 条", n == 1 and #fed == 1, "n=" .. n .. " fed=" .. #fed)
    check("128 点整行逐字节还原", fed[1] == body,
        string.format("期望 %d 字节, 实际 %d 字节", #body, #(fed[1] or "")))
end

-- ===== 2) 一行一片(最常见): 必须原样、且不多不少派一次 =====
do
    reset()
    local n = feed_lines("R:STAT")
    check("单行派出 1 条", n == 1 and #fed == 1, "n=" .. n .. " fed=" .. #fed)
    check("去掉行尾 \\r\\n", fed[1] == "R:STAT", string.format("%q", fed[1] or ""))

    reset()
    prov._rx_feed("R:VAL\n")               -- 裸 \n 行尾
    prov.poll()
    check("裸 \\n 行尾也认", fed[1] == "R:VAL", string.format("%q", fed[1] or ""))

    reset()
    prov._rx_feed("  R:CFG  \r\n")          -- 前后空格
    prov.poll()
    check("首尾空白被 trim", fed[1] == "R:CFG", string.format("%q", fed[1] or ""))

    reset()
    prov._rx_feed("R:A\r\nR:B\r\nR:C\r\n") -- 一片塞三行
    local n3 = prov.poll()
    check("一片三行按序派三次", n3 == 3 and fed[1] == "R:A" and fed[2] == "R:B" and fed[3] == "R:C",
        "n=" .. n3 .. " " .. table.concat(fed, ","))

    reset()
    prov._rx_feed("R:HEAD\r")               -- \r 落在这一片末尾
    prov._rx_feed("\nR:TAIL\r\n")           -- \n 落在下一片开头
    prov.poll()
    check("\\r\\n 被切片切开也不错位", fed[1] == "R:HEAD" and fed[2] == "R:TAIL",
        table.concat(fed, "|") .. " (期望 R:HEAD|R:TAIL)")
end

-- ===== 3) 派活期间又来了新字节(prov 的 poll 里 handler 会让出 CPU) =====
--   W:CFG 重启轮询要走 uart.close + sys.wait(500ms), 这 500ms 里前端/烧写
--   工具的下一条指令照样进串口。分片被 rx_merge 清空过, 所以残留行和新行
--   的先后顺序必须仍然保得住。
do
    reset()
    local reentrant = nil
    _G.vcom_handle = function(line)
        fed[#fed + 1] = line
        if line:sub(1, 6) == "W:CFG=" then
            -- 模拟 handler 在 yield 期间收到了对端的新命令
            prov._rx_feed("R:STAT\r\n")
            reentrant = true
        end
        return true
    end
    prov._rx_feed('W:CFG={"regs":[{"addr":1}]}')
    prov._rx_feed("\r\nR:MODE\r\n")
    prov.poll()
    check("yield 期间的新字节不丢", reentrant and #fed == 3, "fed=" .. #fed)
    check("顺序: 整条 W:CFG 先于后面两行",
        fed[1] == 'W:CFG={"regs":[{"addr":1}]}' and fed[2] == "R:MODE" and fed[3] == "R:STAT",
        table.concat(fed, " / "))
    _G.vcom_handle = function(line) fed[#fed + 1] = line; return true end
end

-- ===== 4) 超 MAX_BUF: 整批丢, 但设备得能自己活过来 =====
do
    reset()
    prov._rx_feed(string.rep("x", 20000))   -- 单片就超 16KB
    prov.poll()
    check("超限不派活(整批丢弃)", #fed == 0, "派了 " .. #fed .. " 条")
    feed_lines("R:STAT")
    check("丢完之后下一行照常", fed[1] == "R:STAT", string.format("%q", tostring(fed[1])))
end

-- ===== 5) 空行不派活, 也不吞掉后面的命令 =====
do
    reset()
    prov._rx_feed("\r\n   \r\nR:BOOTMODE\r\n")
    local n = prov.poll()
    check("空行/纯空白行跳过", n == 1 and fed[1] == "R:BOOTMODE",
        "n=" .. n .. " " .. table.concat(fed, ","))
end

if failed > 0 then
    print(string.format("%d FAIL", failed))
    os.exit(1)
end
print("all prov rx checks passed")
