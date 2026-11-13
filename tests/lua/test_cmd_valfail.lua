-- test_cmd_valfail.lua —— R:VAL 不许把"应答拼不出来"说成"设备里没有数据" (2026-11-13)
--
-- 11-12 现场那两句互相打架:
--   E/mem  memory allocation failed total 307192, used 304848, alloc 4023
--   前端:  暂无数据: 设备可能未进入轮询模式
-- 真相是轮询【在跑】, 60 行数据都在缓存里, 只是 json.encode 那一步在池子见底
-- 时分配不出来 —— 而 jencode 的兜底是"回一坨 {}", 于是 RET:VAL={} 被读成"缓存
-- 空着"。两件事在应答里长一个样, 人就照着假的结论走了一轮(用户当时的判断是
-- "设备没进轮询", 而 R:MODE 明明显示 manual 档在轮询)。
--
-- 这个文件钉三条:
--   1) 编码失败 → RET:FAIL:VAL:<真错误 池水位>, 一个字的 RET:VAL= 都不许多发
--   2) 编码成功但确实是空的 → 仍然回 RET:VAL={} (新设备/没轮询就是这个样子,
--      不许把空缓存也说成失败)
--   3) 原因里不许有换行(应答是一整行的, 带 \n 会把后面所有帧的解析搅乱)
--
-- 跑法: tools\run_lua_tests.bat test_cmd_valfail.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;' .. package.path

local writes = {}
local SNAP = {}        -- collector.snapshot() 替身的返回值
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
package.preload["data/collector"] = function()
    return { snapshot = function() return SNAP end, stats = function() return {} end }
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

local function ask(line)
    writes = {}
    cmd.handle(line)
    return table.concat(writes, "")
end

-- ===== 1) 现场那一次: 60 行在缓存里, 应答编码不出来 =====
local rows = {}
for i = 1, 60 do rows[i] = { addr = 100 + i, value = i, dtype = "uint16" } end
SNAP, ENC_FAIL, USED = rows, "not enough memory for buffer allocation", 293544
local out = ask("R:VAL")
check("① 改回 RET:FAIL:VAL:", out:sub(1, 13) == "RET:FAIL:VAL:", string.format("%q", out))
check("① 带的是 C 层那句原话", out:find("not enough memory", 1, true) ~= nil, string.format("%q", out))
check("① 带池水位(分清【拼不出来】和【没有数据】)",
    out:find("pool 293544/307192", 1, true) ~= nil, string.format("%q", out))
check("① 一个字的假 RET:VAL= 都没发", out:find("RET:VAL=", 1, true) == nil, string.format("%q", out))
check("① 仍然是一整行", out:sub(-2) == "\r\n" and not out:sub(1, -3):find("\n", 1, true),
    string.format("%q", out))

-- ===== 2) 原因太长/带换行: 截断且不搅乱后面的帧 =====
SNAP, ENC_FAIL = rows, 'line1\r\n' .. string.rep("x", 200)
local out2 = ask("R:VAL")
check("② 原因里的换行被换成空格", not out2:sub(1, -3):find("\n", 1, true), string.format("%q", out2))
check("② 原因被截到 80 字节以内", #out2 <= #"RET:FAIL:VAL:" + 80 + 32 + 4, #out2)

-- ===== 3) 拿不到 meminfo: 少了水位这一段, 而不是拿 0 冒充 =====
SNAP, ENC_FAIL, USED = rows, "not enough memory for buffer allocation", -1
local out3 = ask("R:VAL")
check("③ 失败原因照样回", out3:sub(1, 13) == "RET:FAIL:VAL:", string.format("%q", out3))
check("③ 取不到水位就整段不报(不许用 0 冒充池子空着)",
    out3:find("pool", 1, true) == nil, string.format("%q", out3))

-- ===== 4) 缓存真的是空的: 不许报失败 =====
SNAP, ENC_FAIL = {}, nil
local out4 = ask("R:VAL")
check("④ 空缓存仍回 RET:VAL=(新设备本来就是这样)", out4 == 'RET:VAL={"n":0}\r\n', string.format("%q", out4))

-- ===== 5) 编码成功: 数据在, 应答就在 =====
SNAP = rows
local out5 = ask("R:VAL")
check("⑤ 60 行编码得出就照原样发", out5 == 'RET:VAL={"n":60}\r\n', string.format("%q", out5))

if failed > 0 then
    print(string.format("FAIL: %d 条不过 (%d 条)", failed, checked))
    os.exit(1)
end
print("PASS: R:VAL —— 拼不出来就直说, 空缓存才叫没有数据")
