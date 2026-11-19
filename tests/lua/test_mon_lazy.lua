-- test_mon_lazy.lua — bus/mon 惰性加载 (2026-11-19)
--
-- 为什么单独钉: bus/mon 是嗅探专用模块, 23.3KB 源码 / 实测加载进 Lua 堆约 23KB。
--   manual/platform 档从 header 到尾都不碰嗅探, 但顶层 require 让它常驻 ——
--   manual 基线因此从 264K 抬到 287K, 60 点配置(行表 20K+)当场存不进
--   (真机: 第 3/4 片 "解码结果为空 pool 306912/307192")。
--   改成惰性后必须守住两条, 缺一条就白改:
--     1) manual/platform 路径【一次都不许】把它拉进来 —— 包括"问一句在不在跑"
--        这种看似无害的判断(blocked_while_detecting / is_busy / R:MODE);
--     2) sniff 真要用时必须还能加载并正常工作 —— 不能为了省内存把嗅探做瘸。
--
-- 这个文件钉六条:
--   1) require svc/cmd(连带 bus/ctrl)之后 mon 没被加载
--   2) R:MODE / ctrl.status() 在 mon 没加载时给出空壳(running=false), 且不加载
--   3) ctrl.is_busy() 不加载、返回 false
--   4) switch_mode("manual") / ("idle") 不加载
--   5) R:AUTODETECT 在没 sniff 时如实回 not in sniff mode, 且不加载
--   6) W:INFERWATCH=0 走 sniff 专用路径时确实加载, 之后 R:FRAMES / switch_mode
--      ("sniff") 照常工作(mon_loaded() 变 true)
--
-- 跑法: tools\run_lua_tests.bat test_mon_lazy.lua

package.path = 'firmware/?.lua;firmware/?/init.lua;tests/lua/?.lua;' .. package.path

local mockjson = require "mock_json"

local checked, failed = 0, 0
local function check(name, ok, detail)
    checked = checked + 1
    if ok then
        print("ok   " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(detail or ""))
    end
end

-- ---- 假环境 ----
local writes = {}
local mon_loads = 0
local mon_started, mon_stopped = 0, 0
local poll_started = 0

local MON
MON = {
    is_running = function() return mon_started > mon_stopped end,
    is_detecting = function() return false end,
    start = function() mon_started = mon_started + 1 return true end,
    stop = function() mon_stopped = mon_stopped + 1 end,
    request_detect = function() end,
    start_auto_save = function() end,
    load_infer = function() end,
    status = function()
        return { running = mon_started > mon_stopped, detecting = false, gen = 3,
                 baud = 19200, frames = 7, rsps = 5, reqs = 2, errs = 0,
                 infer_rows = 4, hist_aliases = 2 }
    end,
    set_infer_watch = function(v) MON._watch = v end,
    infer_watch = function() return MON._watch == true end,
    take_infer_dirty = function() return false end,
    recent_frames = function() return { { hex = "010300000001" } } end,
    infer_view = function() return 0, 32 end,
    infer_page = function() return { regs = {} } end,
    set_infer_view = function() end,
}

local function stub(name, t)
    package.preload[name] = function() return t end
end

package.preload['bus/mon'] = function()
    mon_loads = mon_loads + 1
    return MON
end

stub('bus/poll', {
    is_running = function() return false end,
    stop = function() end,
    start = function() poll_started = poll_started + 1 return true end,
    status = function() return { running = false, regs = 0 } end,
    write_status = function() return {} end,
    apply_cfg = function() end,
    cur_slot = function() return "poll" end,
})

local cfgstore = {
    load_sys = function() return { boot_mode = "manual" } end,
    has_poll_cfg = function() return true end,
    has_infer_cfg = function() return nil end,
    load_infer = function() return nil end,
    clear_alias = function() end,
    clear_infer = function() end,
    pull_src = function() return nil end,
    alias_map = function() return {} end,
    load_poll = function() return { regs = {} } end,
    load_pull = function() return nil end,
    normalize_poll = function(c) return c end,
    reset_user = function() return {}, {} end,
    drop_cache = function() return 0 end,
    set_alias = function() return true end,
}
stub('cfg', cfgstore)

stub('core/config', { BAUD = 9600 })
stub('sn/sn', { state = function() return "ready" end })
stub('data/collector', {
    snapshot = function() return {} end, stats = function() return {} end,
    clear_all = function() end, trim_cache = function() end,
})
stub('iot/mqttcfg', { load = function() return {} end, clear_manual = function() return true, nil, false end })
stub('iot/iot', {
    set_manual = function() end, pull_start = function() end, hello = function() end,
    pull_status = function() return {} end, attach_names = function(v) return v end,
})
stub('svc/guard', { alive = function() end })

local uart_writes = writes
stub('util', (function() return (function()
    local L = {}
    for _, lv in ipairs({ "debug", "info", "warn", "error" }) do L[lv] = function() end end
    local libs = {
        uart = { VUART_0 = 4, write = function(_, s) uart_writes[#uart_writes + 1] = s return #s end,
                 read = function() return "" end, on = function() end, setup = function() end,
                 close = function() end },
        json = { encode = mockjson.encode, decode = mockjson.decode },
        rtos = { meminfo = function(k)
                     if k == "lua" then return 307192, 270000, 307192 end
                     return 198000, 76000, 90000
                 end },
        mobile = {},
    }
    return { log = function() return L end,
             get = function(n) return libs[n] end,
             try = function(n) return libs[n] end }
end)() end)())

-- ---- 1) 加载 cmd(连带 ctrl), mon 不许被拉进来 ----
local cmd = require "svc/cmd"
cmd.init()
local ctrl = require "bus/ctrl"

check("1 require svc/cmd + bus/ctrl 之后 mon 未被加载", mon_loads == 0,
    "mon_loads=" .. tostring(mon_loads))
check("1 cmd.mon_loaded() == false", cmd.mon_loaded() == false)
check("1 cmd.poll_loaded() == false", cmd.poll_loaded() == false)

local function ask(line)
    writes = {}
    uart_writes = writes
    cmd.handle(line)
    return table.concat(writes, "")
end

-- ---- 2) R:MODE / ctrl.status() 不加载, 且给空壳 ----
local st = ctrl.status()
check("2 status().mon 是空壳(running=false)", st.mon and st.mon.running == false,
    tostring(st.mon and st.mon.running))
check("2 status().mon 字段齐全(baud/infer_view_n)",
    st.mon and st.mon.baud == 9600 and st.mon.infer_view_n == 32,
    tostring(st.mon and st.mon.baud))
local out = ask("R:MODE")
check("2 R:MODE 应答里 mon.running=false", out:find('"mon":{', 1, true) ~= nil
    and out:find('"running":false', 1, true) ~= nil, out:sub(1, 60))
check("2 R:MODE / status() 之后 mon 仍未加载", mon_loads == 0,
    "mon_loads=" .. tostring(mon_loads))

-- ---- 3) is_busy 不加载 ----
check("3 ctrl.is_busy() == false", ctrl.is_busy() == false, tostring(ctrl.is_busy()))
check("3 is_busy 之后 mon 仍未加载", mon_loads == 0, "mon_loads=" .. tostring(mon_loads))

-- ---- 4) manual / idle 切档不加载 ----
local okm, msgm = ctrl.switch_mode("manual")
check("4 switch_mode(manual) 成功", okm == true, tostring(msgm))
check("4 manual 档 mon 仍未加载", mon_loads == 0, "mon_loads=" .. tostring(mon_loads))
local oki = ctrl.switch_mode("idle")
check("4 switch_mode(idle) 成功", oki == true, "ok=" .. tostring(oki))
check("4 idle 档(含 stop_sniff 早退) mon 仍未加载", mon_loads == 0,
    "mon_loads=" .. tostring(mon_loads))

-- ---- 5) R:AUTODETECT 不加载, 如实回 not in sniff ----
local out5 = ask("R:AUTODETECT")
check("5 R:AUTODETECT 回 not in sniff mode",
    out5:find("RET:FAIL:AUTODETECT:not in sniff mode", 1, true) ~= nil, out5)
local out5b = ask("R:AUTODETECT=restart")
check("5 R:AUTODETECT=restart 也回 not in sniff mode",
    out5b:find("RET:FAIL:AUTODETECT:not in sniff mode", 1, true) ~= nil, out5b)
check("5 R:AUTODETECT 之后 mon 仍未加载", mon_loads == 0,
    "mon_loads=" .. tostring(mon_loads))

-- ---- 6) sniff 专用路径才加载, 且加载后照常工作 ----
local out6 = ask("W:INFERWATCH=0")
check("6 W:INFERWATCH 应答正常", out6:find("RET:INFERWATCH=", 1, true) ~= nil, out6)
check("6 W:INFERWATCH 之后 mon 已加载", mon_loads == 1,
    "mon_loads=" .. tostring(mon_loads))
check("6 cmd.mon_loaded() == true", cmd.mon_loaded() == true)
check("6 W:INFERWATCH 把开关传给了 mon", MON._watch == false, tostring(MON._watch))

local out6b = ask("R:FRAMES")
check("6 R:FRAMES 仍能取到报文", out6b:find("RET:FRAMES=", 1, true) ~= nil, out6b)
check("6 已加载后不再重复 require", mon_loads == 1, "mon_loads=" .. tostring(mon_loads))

local oks, msgs = ctrl.switch_mode("sniff")
check("6 switch_mode(sniff) 成功", oks == true, tostring(msgs))
check("6 sniff 之后 mon.start 被调用", mon_started >= 1, "started=" .. tostring(mon_started))
local st2 = ctrl.status()
check("6 sniff 之后 status().mon 是真实状态(baud=19200)",
    st2.mon and st2.mon.baud == 19200, tostring(st2.mon and st2.mon.baud))
check("6 sniff 之后 is_busy() == true", ctrl.is_busy() == true, tostring(ctrl.is_busy()))

local okd = ctrl.switch_mode("idle")
check("6 从 sniff 切 idle 成功", okd == true, "ok=" .. tostring(okd))
check("6 切 idle 时 mon.stop 被调用", mon_stopped >= 1, "stopped=" .. tostring(mon_stopped))

if failed > 0 then
    print(string.format("FAIL: %d 条不过 (%d 条)", failed, checked))
    os.exit(1)
end
print("PASS: bus/mon 惰性加载 —— manual/platform 不加载, sniff 照常工作")
