-- test_cmd_cfgfail.lua —— R:CFG 不许把"读不出来"说成"设备里没有配置" (2026-11-12)
--
-- 起因是复测-日志 4 里的两句:
--   E/mem memory allocation failed total 307192, used 304848, alloc 160
--   W/user.cfg poll normalize fail, use default
-- 池子只剩 2KB 时, 配置【归一化读到一半抛了异常】, cfg.lua 按老规矩回出厂默认表,
-- R:CFG 却照样回 RET:CFG= —— 那张默认表 regs 是空的, 前端就显示成"设备里没有配置"。
-- 用户那一头看到的是: 我刚保存的 56 行没了。实际 fskv 里一个字都没少。
--
-- 这个文件钉的是 cmd.lua 那一格: load_* 带回来第二个返回值(原因)时,
-- R:CFG 必须改回 RET:FAIL, 且串口上一个字节的假配置都不许多发。
--
-- 跑法: tools\run_lua_tests.bat test_cmd_cfgfail.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;' .. package.path

local writes = {}
local LOAD = { poll = { { regs = {} }, nil }, pull = { { regs = {} }, nil } }
local MODE = 'manual'
local BODY = '{"cfg":{"regs":{}},"slot":"poll","src":"fskv"}'

package.preload["util"] = function()
    local L = {}
    for _, lv in ipairs({ "debug", "info", "warn", "error" }) do L[lv] = function() end end
    local libs = {
        uart = { VUART_0 = 4,
                 write = function(_, s) writes[#writes + 1] = s return #s end,
                 read = function() return "" end, on = function() end },
        json = { encode = function() return BODY end, decode = function() return {} end },
        rtos = { meminfo = function(k)
            if k == "lua" then return 307192, 100000, 100000 end
            return 203040, 67940, 70000
        end },
    }
    return { log = function() return L end,
             get = function(n) return libs[n] end,
             try = function(n) return libs[n] end }
end
package.preload["core/config"] = function() return { BAUD = 9600 } end
package.preload["sn/sn"] = function()
    return { state = function() return "empty" end, info_line = function() return "" end,
             imei = function() return "" end, uid = function() return "" end,
             locked = function() return false end }
end
package.preload["bus/ctrl"] = function()
    return { get_mode = function() return MODE end,
             status = function() return { mode = MODE } end }
end
package.preload["bus/mon"] = function() return { is_detecting = function() return false end } end
package.preload["data/collector"] = function() return { stats = function() return {} end } end
package.preload["iot/mqttcfg"] = function() return { load = function() return {} end } end
package.preload["cfg"] = function()
    return {
        -- cfg.lua 的 load_* 现在是【两张返回值】: (表, 原因)。原因非 nil 就说明
        -- 这张表是出厂默认表, 不是设备里那份
        load_poll = function() return LOAD.poll[1], LOAD.poll[2] end,
        load_pull = function() return LOAD.pull[1], LOAD.pull[2] end,
        poll_src = function() return "fskv" end,
        pull_src = function() return "fskv" end,
        load_sys = function() return { boot_mode = "idle" } end,
        load_infer = function() return { regs = {} } end,
        load_alias = function() return {} end,
    }
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
        print(string.format("FAIL %s: %s", tostring(detail or ""), name))
    end
end

local function ask(line)
    writes = {}
    local ok = cmd.handle(line)
    return ok, table.concat(writes, "")
end

-- ===== 1) 正常路径: 一个字节都不许多发, 也一个字都不许多报 =====
LOAD.poll = { { regs = {} }, nil }
MODE = 'manual'
local ok, out = ask("R:CFG")
check("① 读得出配置时照旧回 RET:CFG=", out == "RET:CFG=" .. BODY .. "\r\n", string.format("%q", out))

-- ===== 2) 归一化判非法: 原因原样回, 假配置一个字都不发 =====
LOAD.poll = { { regs = {} }, "bad slave" }
local _, out2 = ask("R:CFG")
check("② 非法时改回 RET:FAIL:CFG:bad slave", out2 == "RET:FAIL:CFG:bad slave\r\n", string.format("%q", out2))
check("② 不再回那张默认表", not out2:find("RET:CFG=", 1, true), string.format("%q", out2))

-- ===== 3) 现场那一次: 归一化【抛异常】, 说的是内存不足 =====
LOAD.poll = { { regs = {} }, "内存/内部异常: not enough memory for buffer allocation" }
local _, out3 = ask("R:CFG")
check("③ 应答里有 内存/内部异常", out3:find("内存/内部异常", 1, true) ~= nil, string.format("%q", out3))
check("③ C 层那句跟着回来", out3:find("not enough memory", 1, true) ~= nil, string.format("%q", out3))
check("③ 一个字节的假配置都没发", not out3:find(BODY, 1, true), string.format("%q", out3))
check("③ 仍然是一整行", out3:sub(-2) == "\r\n" and not out3:sub(1, -3):find("\n", 1, true),
    string.format("%q", out3))

-- ===== 4) 平台槽一样: pull 那份读不出来也不能回假配置 =====
MODE = 'platform'
LOAD.pull = { { regs = {} }, "内存/内部异常: not enough memory for buffer allocation" }
local _, out4 = ask("R:CFG")
check("④ platform 档走的是 load_pull", out4:find("内存/内部异常", 1, true) ~= nil, string.format("%q", out4))
check("④ 同样没回假配置", not out4:find("RET:CFG=", 1, true), string.format("%q", out4))

-- ===== 5) 空槽不是失败: 出厂新设备仍然要能读到配置 =====
-- (load_* 对空 fskv 回的是默认表且不带原因 —— 见 test_cfg_reason.lua 第 7 节,
--  这一条钉的是 cmd 侧不能自己再判一次"regs 空 = 失败", 否则新设备直接读不到)
MODE = 'manual'
LOAD.poll = { { regs = {} }, nil }
local _, out5 = ask("R:CFG")
check("⑤ 空配置(无原因)仍回 RET:CFG=, 新设备读得到", out5 == "RET:CFG=" .. BODY .. "\r\n", string.format("%q", out5))

if failed > 0 then
    print(string.format("FAIL: %d 条不过 (%d 条)", failed, checked))
    os.exit(1)
end
print(string.format("PASS: R:CFG —— 读不出来就回 RET:FAIL, 不再用出厂默认表冒充设备配置"))
