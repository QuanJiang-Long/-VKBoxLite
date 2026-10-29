-- test_heapsize.lua —— 量"我们的 Lua 代码到底占多少常驻堆"
--
-- 为什么需要这个测试 (2026-10-28):
--   设备现场 idle 档 collectgarbage("count") ≈ 190 (LuatOS 这个接口返回 KB),
--   而 Lua 堆总量只有 307192 字节 = 300KB。也就是说【代码本身】就吃掉
--   六成以上的堆, 留给嗅探工作负载的只剩 ~110KB, 碎片化之后连 3.4KB 的
--   R:STAT JSON 都切不出来 → 分配失败 → VM 退出重启。
--   仿真器实测: 19 个模块编译完 = 275KB(基线 50KB 是 LuatOS 自己的库)。
--
--   这个测试的作用是【红线】: 代码体积是这轮 OOM 的根因之一, 别让它
--   再悄悄涨上去。超线就 os.exit(1)。
--
--   跑法: tools\run_lua_tests.bat test_heapsize.lua
--   注: build/lua_burn/ 只有在 prep_burn.ps1 跑过、且仿真器工程里拷进去
--       才读得到(仿真器会按 require 依赖裁剪脚本), 读不到就跳过那一轮。

local MODS = {
    "util", "util/mqtt_util", "core/config", "data/collector", "bus/mbus",
    "iot/pubsched", "iot/mqttcfg", "iot/pullcfg", "iot/topo", "bus/mon", "bus/poll",
    "bus/ctrl", "iot/iot", "svc/cmd", "svc/guard", "sn/sn", "sn/prov",
    "lbsLoc2", "cfg", "_build_flag",
}

-- 红线: 我们自己的代码在 Lua 堆里最多占这么多 KB(设备堆才 300KB)
local LIMIT_KB = 320

local function count() return collectgarbage("count") end

-- collectgarbage("count") 在 LuatOS 返回 KB(不是字节)。这里两种口径都打,
-- 免得以后有人按标准 Lua 的"字节"去理解这些数字。
local function snap(tag)
    collectgarbage("collect")
    collectgarbage("collect")
    local c = count()
    print(string.format("%-28s count=%-10s", tag, tostring(c)))
    return c
end

-- 读文件: 优先 io.open(直接读磁盘, 不受仿真器"依赖裁剪"影响, 因为
-- build/lua_burn/ 下的文件没被 require 过, 会被裁掉); 读不到再退回 loadfile
local function read_file(path)
    local f = io.open(path, "rb")
    if f then
        local s = f:read("*a")
        f:close()
        return s
    end
    return nil
end

local function compile_file(path)
    local src = read_file(path)
    if src then
        local chunk, err = load(src, "@" .. path)
        src = nil
        if chunk then return chunk end
        return nil, err
    end
    return loadfile(path)
end

local function measure(root, label, verbose)
    print("")
    print(string.format("===== %s (%s) =====", label, root))
    local base0 = snap(label .. " baseline")
    local base = base0
    local keep = {}
    local loaded, failed = 0, {}
    for _, m in ipairs(MODS) do
        local path = root .. "/" .. m:gsub("%.", "/") .. ".lua"
        local chunk, err = compile_file(path)
        if chunk then
            keep[#keep + 1] = chunk
            loaded = loaded + 1
            local now = snap("compiled:" .. m)
            if verbose then
                print(string.format("      delta=%s", tostring(now - base)))
            end
            base = now
        else
            failed[#failed + 1] = m .. " (" .. tostring(err) .. ")"
        end
    end
    local total = base - base0
    print(string.format("== %s: %d/%d 个模块, 我们自己的代码占 %.1f KB", label, loaded, #MODS, total))
    if #failed > 0 then
        print("!! 读不出来: " .. table.concat(failed, ", "))
    end
    return loaded, total
end

-- 设备实际烧的是去注释版, 先量它(读不到就量仓库原样, 结论一样)
local n1, kb1 = measure("build/lua_burn", "BURN(设备实际)", false)
if n1 == 0 then
    print("(build/lua_burn 不可读 —— 跑过 prep_burn.ps1 并拷进仿真器工程才有; 改量 lua/)")
    n1, kb1 = measure("lua", "SRC(仓库原样)", true)
end
if n1 == 0 then
    print("FAIL: 一个模块都读不出来")
    os.exit(1)
end

print("")
if kb1 > LIMIT_KB then
    print(string.format("FAIL: 代码占 %.1f KB, 超过红线 %.1f KB (设备堆才 300KB)", kb1, LIMIT_KB))
    os.exit(1)
end
print(string.format("PASS: 代码占 %.1f KB (红线 %.1f KB)", kb1, LIMIT_KB))
