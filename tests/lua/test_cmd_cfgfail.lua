-- test_cmd_cfgfail.lua —— R:CFG / R:REG 不许把"应答拼不出来"说成"设备里没有配置"
-- (2026-11-18, 真机 32 点)
--
-- 现场那一幕:
--   W:CFINISH → RET:CFINISH=OK                 (确实存进去了)
--   R:CFG     → RET:CFG={}                     (jencode 兜底的"一坨空对象")
--   R:MEM     → lua:296536/307192 max:3072     (池子见底, 编码那 2KB 分配不出来)
-- 前端把 {} 读成"0 个寄存器", 用户以为配置丢了 —— 再点一次保存就把设备清空了。
-- 这和 11-12 的 R:VAL 是同一类谎话, 只是换了一条命令; R:VAL 当时改成了
-- jencode_err, R:CFG / R:REG 还留着 jencode 的 "{}" 兜底。
--
-- 这个文件钉五条:
--   1) 两次编码都失败 → RET:FAIL:CFG:<C 层原话 池水位>, 一个字的 RET:CFG=
--      都不许多发, 且失败前真的丢过解码缓存
--   2) 第一次失败、丢缓存 + GC 之后成功 → 照常回数据(说明重试真的在跑)
--   3) 编码正常 → 一次就成, 不白丢缓存
--   4) 原因里带换行 → 换成空格, 仍然是一整行
--   5) R:REG 同一个规矩(它也是"表内容", {} 一样会被读成"没有寄存器")
--
-- 跑法: tools\run_lua_tests.bat test_cmd_cfgfail.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;' .. package.path

local writes = {}
local ENC_FAIL_MSG = "not enough memory for buffer allocation"
local USED = 296536
-- 每次 json.encode 消费一条: true = 这一次抛(模拟池子见底), 队列空 = 正常编码
local FAIL_PLAN = {}
local drop_called = 0

local rows60 = {}
for i = 1, 60 do rows60[i] = { addr = 100 + i, count = 1, name = "R" .. i } end

package.preload["util"] = function()
    local L = {}
    for _, lv in ipairs({ "debug", "info", "warn", "error" }) do L[lv] = function() end end
    local libs = {
        uart = { VUART_0 = 4,
                 write = function(_, s) writes[#writes + 1] = s return #s end,
                 read = function() return "" end, on = function() end },
        json = { encode = function(v)
                     -- level 0: 真机上 json.encode 是 C 函数, 抛的就是那句原话
                     if table.remove(FAIL_PLAN, 1) then error(ENC_FAIL_MSG, 0) end
                     return '{"rows":' .. #v .. '}'
                 end,
                 decode = function() return {} end },
        rtos = { meminfo = function(k)
                     if k == "lua" then
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
    return { state = function() return "ready" end, imei = function() return "" end,
             uid = function() return "" end, locked = function() return false end }
end
package.preload["bus/ctrl"] = function()
    return { get_mode = function() return "manual" end, status = function() return {} end }
end
package.preload["bus/mon"] = function() return { is_detecting = function() return false end } end
package.preload["bus/poll"] = function()
    return { get_regs = function() return rows60 end,
             is_running = function() return true end,
             status = function() return {} end }
end
package.preload["data/collector"] = function()
    return { snapshot = function() return {} end, stats = function() return {} end }
end
package.preload["iot/mqttcfg"] = function() return { load = function() return {} end } end
package.preload["cfg"] = function()
    return { load_poll = function() return { regs = rows60, baud = 9600 } end,
             load_pull = function() return { regs = {}, baud = 9600 } end,
             poll_src = function() return "fskv" end,
             pull_src = function() return "pull" end,
             drop_cache = function() drop_called = drop_called + 1 return 3 end,
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

-- ===== 1) 两次编码都失败: 必须如实报, 不许回 {} =====
FAIL_PLAN = { true, true }
drop_called = 0
local out = ask("R:CFG")
check("1 改回 RET:FAIL:CFG:", out:sub(1, 13) == "RET:FAIL:CFG:", string.format("%q", out))
check("1 带的是 C 层那句原话", out:find("not enough memory", 1, true) ~= nil, string.format("%q", out))
check("1 带池水位(分清【拼不出来】和【没有配置】)",
    out:find("pool 296536/307192", 1, true) ~= nil, string.format("%q", out))
check("1 一个字的假 RET:CFG= 都没发", out:find("RET:CFG=", 1, true) == nil, string.format("%q", out))
check("1 失败前真的丢了解码缓存(重试路径在跑)", drop_called >= 1, tostring(drop_called))
check("1 仍然是一整行", out:sub(-2) == "\r\n" and not out:sub(1, -3):find("\n", 1, true),
    string.format("%q", out))

-- ===== 2) 第一次失败, 丢缓存 + GC 之后成功: 照常回数据 =====
FAIL_PLAN = { true }
drop_called = 0
local out2 = ask("R:CFG")
check("2 重试成功后回的是数据, 不是 FAIL", out2 == 'RET:CFG={"rows":0}\r\n', string.format("%q", out2))
check("2 重试前丢过缓存", drop_called >= 1, tostring(drop_called))

-- ===== 3) 编码正常: 一次就成, 不必丢缓存 =====
FAIL_PLAN = {}
drop_called = 0
local out3 = ask("R:CFG")
check("3 正常路径回数据", out3 == 'RET:CFG={"rows":0}\r\n', string.format("%q", out3))
check("3 正常路径不白丢缓存", drop_called == 0, tostring(drop_called))

-- ===== 4) 原因里带换行: 换掉换行, 不搅乱后面的帧 =====
ENC_FAIL_MSG = 'line1\r\n' .. string.rep("x", 200)
FAIL_PLAN = { true, true }
local out4 = ask("R:CFG")
check("4 原因里的换行被换成空格", not out4:sub(1, -3):find("\n", 1, true), string.format("%q", out4))
check("4 仍然从 RET:FAIL:CFG: 起头", out4:sub(1, 13) == "RET:FAIL:CFG:", string.format("%q", out4))
ENC_FAIL_MSG = "not enough memory for buffer allocation"

-- ===== 5) R:REG 同一个规矩 =====
FAIL_PLAN = { true, true }
local out5 = ask("R:REG")
check("5 R:REG 也如实报", out5:sub(1, 13) == "RET:FAIL:REG:", string.format("%q", out5))
check("5 R:REG 也不许回空壳", out5:find("RET:REG=", 1, true) == nil, string.format("%q", out5))
FAIL_PLAN = {}
local out6 = ask("R:REG")
-- 本替身没走过 commit_config, poll 模块没被拉进来(pollmod(false) → nil),
--   所以正常路径回的是空表 —— 这里只钉"不许变成 FAIL"
check("5 R:REG 正常路径照旧", out6 == 'RET:REG={"rows":0}\r\n', string.format("%q", out6))

if failed > 0 then
    print(string.format("FAIL: %d 条不过 (%d 条)", failed, checked))
    os.exit(1)
end
print("PASS: R:CFG / R:REG —— 拼不出来就直说, 空配置才叫没有配置")
