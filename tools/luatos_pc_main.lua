-- LuatOS PC 引擎单测壳 (tools/run_lua_tests.bat 会把它摆到仿真器工程根当 main.lua):
-- 读 LUA_TEST 环境变量, 跑 tests/ 下同名文件; 设备模块的 require 补 fs 兜底
-- (LuatOS 的 require 是 ROM fs 加载, 没有 package.path, 所以必须兜 loadfile)
local sys = require "sys"
local raw_require = require
local cache = {}
require = function(name)
    if cache[name] ~= nil then return cache[name] end
    local ok, m = pcall(raw_require, name)
    if ok and m ~= nil then cache[name] = m return m end
    local chunk = loadfile('lua/' .. name:gsub('%.', '/') .. '.lua')
    if chunk then
        local mo = chunk(name)
        cache[name] = mo
        return mo
    end
    return nil
end
local t = os.getenv("LUA_TEST")
sys.taskInit(function()
    if not t then
        print("FAIL: no LUA_TEST env")
    else
        print("== run " .. tostring(t))
        local ok, err = pcall(dofile, 'tests/' .. t)
        if not ok then print("FAIL: " .. tostring(err)) end
    end
    os.exit(0)
end)
sys.run()
