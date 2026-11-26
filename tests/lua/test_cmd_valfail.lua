-- test_cmd_valfail.lua —— R:VAL 不许把"应答拼不出来"说成"设备里没有数据" (2026-11-13)
--                            + 60 点改流式 (2026-11-26)
--
-- 11-12 现场那两句互相打架:
--   E/mem  memory allocation failed total 307192, used 304848, alloc 4023
--   前端:  暂无数据: 设备可能未进入轮询模式
-- 真相是轮询【在跑】, 60 行数据都在缓存里, 只是 json.encode 那一步在池子见底
-- 时分配不出来 —— 而 jencode 的兜底是"回一坨 {}", 于是 RET:VAL={} 被读成"缓存
-- 空着"。两件事在应答里长一个样, 人就照着假的结论走了一轮。
--
-- 11-26 真机又踩到同一处的另一半: 60 点 manual 档下 snapshot() 复制 60 张
--   5 字段表(≈11KB)再整段 encode, 18KB 余量时 RET:FAIL:handler error:
--   not enough memory, 前端每秒重试。现在改成 each_by_addr() 迭代 + 逐行
--   encode + tx_stream 流式写, 内存与点数无关 —— 本文件钉住这个新契约:
--   1) 行编码失败 → RET:FAIL:VAL:<真错误 池水位>, 一个字的 RET:VAL= 都不多发
--   2) 缓存确实是空的 → 仍回 RET:VAL=[] (新设备/没轮询就是这个样子)
--   3) 原因里不许有换行(应答是一整行的, 带 \n 会把后面所有帧的解析搅乱)
--   4) 60 行要发得出来, 且是流式(中间会分几次 uart.write)
--
-- 跑法: tools\run_lua_tests.bat test_cmd_valfail.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;' .. package.path

local writes = {}
local ROWS = {}        -- collector 里的行(扁表: addr/value/ts/dtype/name)
local ENC_FAIL = nil   -- 非 nil = json.encode 在这一步抛, 值就是 C 层那句话
local USED = 293544

package.preload["util"] = function()
    local L = {}
    for _, lv in ipairs({ "debug", "info", "warn", "error" }) do L[lv] = function() end end
    local libs = {
        uart = { VUART_0 = 4,
                 write = function(_, s) writes[#writes + 1] = s return #s end,
                 read = function() return "" end, on = function() end },
        json = { encode = function(v)
            -- error(msg, 0): 真机上 json.encode 是 C 函数, 抛出来的就是那句
            --   原话、前面不带 "文件:行号:"。level 0 是替身必须像的地方
            if ENC_FAIL then error(ENC_FAIL, 0) end
            -- 行对象带 addr → 用它当标记, 便于数"到底发出去几行";
            --   #v 只数数组部分, 对哈希表恒为 0, 不能拿来当标记
            if type(v) == "table" and v.addr then return '{"a":' .. tostring(v.addr) .. '}' end
            return '{"n":' .. #v .. '}'
        end, decode = function() return {} end },
        rtos = { meminfo = function(k)
            if k == "lua" then
                -- USED<0 = 这一版拿不到水位(pcall 里直接抛), 用来验"取不到就
                --   整段不追加", 而不是回个 0 让人读成"池子空着"
                if USED < 0 then error("meminfo 不可用", 0) end
                return 307192, USED, 307192
            end
            return 198000, 76000, 90000
        end },
    }
    return { log = function() return L end,
             get = function(n) return libs[n] end,
             try = function(n) return libs[n] end }
end
package.preload["core/config"] = function() return { BAUD = 9600 } end
package.preload["sn/sn"] = function()
    return { state = function() return "empty" end, imei = function() return "" end,
             uid = function() return "" end, locked = function() return false end }
end
package.preload["bus/ctrl"] = function()
    return { get_mode = function() return "manual" end, status = function() return {} end }
end
package.preload["bus/mon"] = function() return { is_detecting = function() return false end } end
-- collector: 真机那侧就两个入口 —— snapshot()(老) 和 each_by_addr()(新流式)。
--   这里把 each_by_addr 做成和真身同形状的闭包, 行数据不复制(返回引用)。
package.preload["data/collector"] = function()
    return {
        snapshot = function() return ROWS end,
        each_by_addr = function()
            local i = 0
            return function()
                i = i + 1
                local r = ROWS[i]
                if not r then return nil end
                return r.name or ("R" .. i), r
            end
        end,
        stats = function() return {} end,
    }
end
package.preload["iot/mqttcfg"] = function() return { load = function() return {} end } end
package.preload["cfg"] = function()
    return { load_poll = function() return { regs = {} } end,
             load_pull = function() return { regs = {} } end,
             poll_src = function() return "fskv" end,
             pull_src = function() return "fskv" end,
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

-- ask 返回 { text = 拼起来的整条, writes = 每次 uart.write 的段 }
local function ask(line)
    writes = {}
    cmd.handle(line)
    return { text = table.concat(writes, ""), writes = writes }
end

local function mkrows(n)
    local rows = {}
    for i = 1, n do
        rows[i] = { addr = 100 + i, value = i, dtype = "uint16", name = "点" .. i, ts = 1700000000 + i }
    end
    return rows
end

-- ===== 1) 现场那一次: 60 行在缓存里, 应答编码不出来 =====
ROWS, ENC_FAIL, USED = mkrows(60), "not enough memory for buffer allocation", 293544
local r1 = ask("R:VAL")
check("① 改回 RET:FAIL:VAL:", r1.text:sub(1, 13) == "RET:FAIL:VAL:", string.format("%q", r1.text))
check("① 带的是 C 层那句原话", r1.text:find("not enough memory", 1, true) ~= nil, string.format("%q", r1.text))
check("① 带池水位(分清【拼不出来】和【没有数据】)",
    r1.text:find("pool 293544/307192", 1, true) ~= nil, string.format("%q", r1.text))
check("① 一个字的假 RET:VAL= 都没发", r1.text:find("RET:VAL=", 1, true) == nil, string.format("%q", r1.text))
check("① 仍然是一整行", r1.text:sub(-2) == "\r\n" and not r1.text:sub(1, -3):find("\n", 1, true),
    string.format("%q", r1.text))
-- M.reply = tx_frags{s, "\r\n"} 两段 → 2 次 write。多一次就说明流式那侧已经
--   往串口写过半张表了(那是绝对不能出现的)
check("① 一行都没编码成功 => 只有 FAIL 那两段, 没写过半张表", #r1.writes == 2, #r1.writes)

-- ===== 2) 原因太长/带换行: 截断且不搅乱后面的帧 =====
ROWS, ENC_FAIL = mkrows(60), 'line1\r\n' .. string.rep("x", 200)
local r2 = ask("R:VAL")
check("② 原因里的换行被换成空格", not r2.text:sub(1, -3):find("\n", 1, true), string.format("%q", r2.text))
check("② 原因被截断(80B 原文 + 行号前缀 + 池水位)",
    #r2.text <= 200, #r2.text)

-- ===== 3) 拿不到 meminfo: 少了水位这一段, 而不是拿 0 冒充 =====
ROWS, ENC_FAIL, USED = mkrows(60), "not enough memory for buffer allocation", -1
local r3 = ask("R:VAL")
check("③ 失败原因照样回", r3.text:sub(1, 13) == "RET:FAIL:VAL:", string.format("%q", r3.text))
check("③ 取不到水位就整段不报(不许用 0 冒充池子空着)",
    r3.text:find("pool", 1, true) == nil, string.format("%q", r3.text))

-- ===== 4) 缓存真的是空的: 不许报失败 =====
ROWS, ENC_FAIL = {}, nil
local r4 = ask("R:VAL")
check("④ 空缓存回 RET:VAL=[] (新设备本来就是这样)", r4.text == "RET:VAL=[]\r\n", string.format("%q", r4.text))

-- ===== 5) 编码成功: 数据在, 应答就在; 60 行要能整条发出来 =====
ROWS = mkrows(60)
local r5 = ask("R:VAL")
local body5 = r5.text:sub(1, -3)
local n5 = 0
for _ in body5:gmatch('{"a":%d+}') do n5 = n5 + 1 end
check("⑤ 60 行一条不落", n5 == 60, "数到 " .. n5)
check("⑤ 开头结尾像一条数组", body5:sub(1, 9) == "RET:VAL=[" and body5:sub(-1) == "]", string.format("%q", body5:sub(1, 20)))
check("⑤ 一整行(中间没有换行)", not body5:find("\n", 1, true), string.format("%q", body5))
check("⑤ 确实是流式: 分多次写出去", #r5.writes >= 2, #r5.writes)
check("⑤ 每次写的段都不大(峰值 = 一个 512B 缓冲)",
    (function() for _, s in ipairs(r5.writes) do if #s > 1024 then return false end end return true end)(),
    "有超过 1024B 的段")

-- ===== 6) 没有 snapshot() 也能跑 (行数据不复制) =====
package.loaded["data/collector"].snapshot = nil
local r6 = ask("R:VAL")
check("⑥ 只靠 each_by_addr 就能出应答(不再依赖 snapshot 的副本)",
    r6.text:sub(1, 9) == "RET:VAL=[" and #r6.text > 100, string.format("%q", r6.text:sub(1, 20)))

if failed > 0 then
    print(string.format("FAIL: %d 条不过 (%d 条)", failed, checked))
    os.exit(1)
end
print("PASS: R:VAL —— 流式出应答; 拼不出来就直说, 空缓存才叫没有数据")
