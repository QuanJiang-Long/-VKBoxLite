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
--   5) 2026-11-12: 并串那一步【自己】分配失败时不许打死 VM, 而且必须如实
--      回一条 RET:FAIL —— 现场那次是 "prov.lua:190: not enough memory for
--      buffer allocation" 直接 Lua VM exit, 整机 15 秒后重启
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

-- ===== 6) 并串时内存不足: 【不许打死 VM】, 而且要说清这条没进去 =====
-- 现场那次(prov.lua:190)是真的整机重启:
--   E/mem memory allocation failed total 307192, used 292688, alloc ...
--   prov.lua:190: not enough memory for buffer allocation
--   Lua VM exit!! reboot in 15000ms
-- 老代码把 rx_merge 放在 dispatch 那层 pcall 【之外】, 而 table.concat 正是
--   最可能抛的那一步 —— 保护点漏在了最该保护的地方。这里把 table.concat
--   换成"一定抛"来复现 raise 的落点(真机上抛的是 C 层的分配失败, 位置一样)
do
    reset()
    local real = table.concat
    -- 只对【大请求】抛, 和小请求分不开 —— 真机上就是这样: max:2048 时
    --   要 6KB 的那次失败, 要 40B 的照常成功。把 concat 全换成"一定抛"
    --   会连测试自己的日志拼接一起打断, 那就是替身不像了
    table.concat = function(t, ...)
        local sz = 0
        for i = 1, #t do if type(t[i]) == "string" then sz = sz + #t[i] end end
        if sz > 2048 then error("not enough memory for buffer allocation") end
        return real(t, ...)
    end
    local big = string.rep("1,", 1500)   -- 3000B 一片
    prov._rx_feed('W:CFG={"regs":[' .. big)
    prov._rx_feed(big .. '0]}\r\n')
    local pok, perr = pcall(prov.poll)   -- 必须是"调用返回", 不是"整个进程死掉"
    table.concat = real
    check("并串失败不冒到外面(以前这条打死 VM)", pok, tostring(perr))
    check("并串失败不派活", #fed == 0, "派了 " .. table.concat(fed, ","))
    local rep = table.concat(uart_writes, "")
    check("如实回了 RET:FAIL(前端不用干等超时)",
        rep:find("RET:FAIL", 1, true) ~= nil, string.format("%q", rep))
    check("一轮只回一次(不逐片刷串口)", #uart_writes == 1,
        "写了 " .. #uart_writes .. " 段: " .. string.format("%q", rep))
    local errs = 0
    for _, l in ipairs(logs) do if l:find("rx lost", 1, true) then errs = errs + 1 end end
    check("设备日志留下一句查得到的话", errs == 1, "找到 " .. errs .. " 条")
    -- 丢完之后设备必须还能干活(分片已经清空, 不是卡在半个缓冲里)
    reset()
    feed_lines("R:STAT")
    check("并串失败后下一行照常收", fed[1] == "R:STAT", tostring(fed[1]))
end

if failed > 0 then
    print(string.format("%d FAIL", failed))
    os.exit(1)
end
print("all prov rx checks passed")
