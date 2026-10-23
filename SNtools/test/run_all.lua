--[[
@module  test/run_all.lua
@brief   PC 单测入口
@detail 用法：
           cd test
           lua run_all.lua       （或 luajit run_all.lua）

         覆盖：SN 校验、状态机迁移、唯一性防呆、写后回读、烧录锁、
               串口半包/超长缓冲、指令分发、clientid 降级链、上报注入。
]]

local dir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = table.concat({
    dir .. "/?.lua",
    dir .. "/mock/?.lua",
    dir .. "/../?.lua",
    package.path,
}, ";")

local env = require "env"

local MODULES = {
    "sn_core", "sn_store_fskv", "sn_prov_uart", "identity", "report", "mqtt_demo", "corelib",
}

local passed, failed = 0, 0
local failures = {}

local function eq(a, b)
    if a ~= b then
        error(string.format("expected [%s], got [%s]", tostring(b), tostring(a)), 2)
    end
end

local function truthy(v, msg)
    if not v then error(msg or "assertion failed", 2) end
end

_G.eq, _G.truthy = eq, truthy

--=====================================================================
-- VS(label)：把测试用的短标签转成【符合当前 rules 的合法 SN】
--   SN 规则演进过（早期 1~32 任意字符，现在 17 位纯数字 + Luhn 校验位），
--   测试里到处写死具体 SN 值，每改一次规则就要改几十处。
--   用 VS() 派生后，规则再变只改这一个函数，测试代码不动。
--   派生是确定性的：同一标签永远得到同一 SN，且不同标签必得不同 SN。
--=====================================================================
_G.VS = function(label)
    if type(label) ~= "string" or #label == 0 then error("VS: bad label") end
    local h = 7
    for i = 1, #label do h = (h * 31 + label:byte(i)) % 100000000 end
    local body = string.format("%08d%08d", h, #label)   -- 16 位主体
    return require("sn_luhn").make(body)
end

-- 每个用例：重置模块缓存 + 重置 mock 环境，保证用例间零污染
_G.test = function(name, fn)
    for _, m in ipairs(MODULES) do package.loaded[m] = nil end
    env.reset()
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  PASS  " .. name)
    else
        failed = failed + 1
        failures[#failures + 1] = name
        print("  FAIL  " .. name .. "\n        --> " .. tostring(err))
    end
end

require "sn_luhn_test"
require "sn_core_test"
require "prov_uart_test"
require "identity_test"
require "report_test"

print(string.format("\n%d passed, %d failed, %d total", passed, failed, passed + failed))
if failed > 0 then
    print("failed: " .. table.concat(failures, " | "))
    os.exit(1)
end
os.exit(0)
