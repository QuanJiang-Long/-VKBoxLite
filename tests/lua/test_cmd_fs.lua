-- test_cmd_fs.lua —— W:FS 文件系统探针的单测 (2026-11-11)
--
-- 背景: 128 点配置整份 8271B，撞 fskv 单值 4096B 硬顶。唯一的出路是把整份
-- 配置写进 littlefs(开机日志 D/sfd.lfs init ok + fs 128kbyte)，但"Lua 侧到底
-- 能不能打开它"从没实测过 —— README 早年那句"本机型没有可写文件系统"查的是
-- fs 库和 rtos.fsinfo，合宙指出那是查错了函数名(io 库才是现役 API)。
-- W:FS 就是用来把这一句之争一次结掉的，所以它的判定必须可信:
--   1) 没探到不能假装探到 —— io/fsstat/open 任一层缺失都要如实报 nil/no-lib
--   2) B:YES 只能由"真写进去 8192B 并且读回 8192B"得出，写成功但读回不齐
--      必须掉到 B?，否则会把一条坏路径说成好消息
--   3) 临时文件必须删干净(它是真机上的 8KB，删不掉就是占死 128K 区的 1/16)
--   4) io.fsstat 返回几个值各版固件说法不一，两种口径都要能算出可用空间
--
-- 跑法: tools\run_lua_tests.bat test_cmd_fs.lua

local writes = {}

package.preload["util"] = function()
    local L = {}
    for _, lv in ipairs({ "debug", "info", "warn", "error" }) do
        L[lv] = function() end
    end
    local libs = {
        uart = { VUART_0 = 4,
                 write = function(_, s) writes[#writes + 1] = s return #s end,
                 read = function() return "" end, on = function() end },
        json = { encode = function() return "{}" end, decode = function() return {}, true end },
        rtos = { meminfo = function() return 307192, 50000, 60000 end },
    }
    return { log = function() return L end,
             -- 与真 util.get/try 同一条口径: 先【索引】_G(会走 __index 惰性加载),
             -- 再 require 兜底。探针原来用的是 rawget, 那条路看不见 __index
             get = function(n)
                 local v = libs[n] or _G[n]
                 if not v then error("no lib " .. tostring(n)) end
                 return v
             end,
             try = function(n) return libs[n] or _G[n] end }
end
package.preload["core/config"] = function() return { BAUD = 9600 } end
package.preload["sn/sn"] = function()
    return { state = function() return "empty" end, info_line = function() return "" end }
end
package.preload["bus/ctrl"] = function()
    return { get_mode = function() return "manual" end,
             status = function() return { mode = "manual" } end }
end
package.preload["bus/mon"] = function() return { is_detecting = function() return false end } end
package.preload["data/collector"] = function() return { stats = function() return {} end } end
package.preload["cfg"] = function()
    return { load_poll = function() return { regs = {} } end,
             poll_src = function() return "poll" end,
             load_sys = function() return { boot_mode = "idle" } end }
end
package.preload["iot/mqttcfg"] = function() return {} end

_G.DEBUG = true
local cmd = require "svc/cmd"
cmd.init()

local real_io, real_os = _G.io, _G.os

------------------------------------------------------------------
-- 假 io：opts 控制每种"缺什么"，files 记真实写入内容(长度可信)
------------------------------------------------------------------
local function make_io(opts)
    opts = opts or {}
    local files = {}
    local io = {}
    if opts.no_io_table then return nil end
    if not opts.no_open then
        io.open = function(path, mode)
            if opts.open_nil then return nil end
            if mode == "rb" then
                if files[path] == nil then return nil end
                local d = files[path]
                return { read = function() return d end, close = function() end }
            end
            if opts.readonly_root and path:sub(1, 6) == "/luadb" then return nil end
            local buf = {}
            return {
                write = function(_, s) buf[#buf + 1] = s return true end,
                close = function() files[path] = table.concat(buf) return true end,
            }
        end
    end
    if not opts.no_helpers then
        io.exists = function(p) return files[p] ~= nil end
        io.fileSize = function(p) return files[p] and #files[p] or nil end
        io.remove = function(p) files[p] = nil return true end
    end
    if not opts.no_fsstat then
        -- 合宙给的口径: ok, total_block, used_block, block_size
        if opts.fsstat_bytes then io.fsstat = function() return true, 131072, 16384 end
        else io.fsstat = function() return true, 32, 4, 4096 end end
    end
    io._files = files
    return io
end

local function run(opts)
    writes = {}
    local io = make_io(opts)
    local os_t = { rename = function(a, b)
        if opts.no_rename or io == nil then return nil end
        if io._files[a] == nil then return nil end
        io._files[b] = io._files[a]; io._files[a] = nil
        return true
    end }
    local gm = getmetatable(_G)
    if opts.lazy then
        -- 11-12 现场那台的形状: 库【没有 rawset 进 _G】, 只有 _G 的 __index
        -- 惰性提供 —— 于是 rawget(_G,"io") 什么都看不见, 六个字段齐刷刷 no-lib,
        -- 连每轮都在用的 os 也报成"没有库"。探针必须在这种固件上照样给出结论。
        _G.io, _G.os = nil, nil
        setmetatable(_G, { __index = function(_, k)
            if k == "io" then return io end
            if k == "os" then return os_t end
            return nil
        end })
    else
        -- io 库也可能是 userdata(带 __index 的库对象), 不能只认 table
        _G.io = opts.io_userdata and real_io.stdout or io
        _G.os = os_t
    end
    local ok = pcall(cmd.handle, "W:FS")
    local out = table.concat(writes, "")
    setmetatable(_G, gm)
    _G.io, _G.os = real_io, real_os
    return ok, out, io
end

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

------------------------------------------------------------------
-- ① 一切可用: 必须给 B:YES，并报出 112K 可用
------------------------------------------------------------------
local ok, out = run({})
check("① 正常路径不崩", ok, out)
check("① 判定 B:YES", out:find("=>B:YES", 1) ~= nil, out)
check("① 按块算出可用 112K/128K", out:find("free:112K/128K", 1) ~= nil, out)
check("① 写了 8192 也读回 8192",
    out:find("wsz=8192", 1) ~= nil and out:find("rsz=8192", 1) ~= nil, out)
check("① 改名后仍能读回(说明 rename 真生效)", out:find("ren=true", 1) ~= nil, out)
check("① 临时文件删干净 left=false", out:find("left=false", 1) ~= nil, out)
check("① 应答单行且带 CRLF",
    out:sub(-2) == "\r\n" and out:find("\r\n", 1) == #out - 1, out)

------------------------------------------------------------------
-- ② io.fsstat 返回的是字节数而不是块数：同样要算对
------------------------------------------------------------------
ok, out = run({ fsstat_bytes = true })
check("② 字节口径也算出 112K/128K", out:find("free:112K/128K", 1) ~= nil, out)

------------------------------------------------------------------
-- ③ 缺什么就要报什么，不许含糊
------------------------------------------------------------------
ok, out = run({ no_fsstat = true })
check("③ 没有 fsstat 仍能给结论", ok and out:find("=>B", 1) ~= nil, out)
check("③ 没有 fsstat 时报 stat 缺失", out:find("fsstat:nil", 1) ~= nil, out)

ok, out = run({ open_nil = true })
check("③ open 返回 nil → 不报 B:YES", ok and out:find("=>B:YES", 1) == nil, out)
check("③ open 返回 nil → 报 open-nil", out:find("open%-nil", 1) ~= nil, out)

ok, out = run({ no_open = true })
check("③ 没有 open → 不崩", ok, out)
check("③ 没有 open → 不报 B:YES", out:find("=>B:YES", 1) == nil, out)
check("③ 没有 open → 报 open:nil", out:find("open:nil", 1) ~= nil, out)

-- 缺 exists/fileSize/remove 这几个辅助函数: 探针不能因此崩掉(真机上
-- io 库是残缺版的可能性完全存在, 缺函数不等于缺文件系统)
ok, out = run({ no_helpers = true })
check("③ 只有 io.open → 不崩", ok, out)
check("③ 辅助函数缺失时报 nil", out:find("rm:nil", 1) ~= nil, out)
check("③ 辅助函数缺失时仍写出并读回", out:find("rsz=8192", 1) ~= nil, out)

ok, out = run({ no_io_table = true })
check("③ io 整个不存在 → 不崩", ok, out)
check("③ io 不存在 → 报 no-lib", out:find("no%-lib", 1) ~= nil, out)

------------------------------------------------------------------
-- ④ 写进去但读回不齐 = 不能说好消息
------------------------------------------------------------------
local io4
ok, out, io4 = run({ no_rename = true })
check("④ rename 失败不崩", ok, out)
check("④ rename 失败 → 不给 B:YES", out:find("=>B:YES", 1) == nil, out)
check("④ rename 失败 → 读不回", out:find("rsz=read%-fail", 1) ~= nil, out)
check("④ 失败也要清 tmp(不留半个文件)", io4._files["/vk_probe.tmp"] == nil)

------------------------------------------------------------------
-- ⑤ 现场那台的形状: 库挂在 _G 的 __index 上, rawget 什么都看不见
--    这条是 11-12 那条 W:FS 的回归测试 —— 当时六个字段齐刷刷 no-lib
--    (连每轮都在用的 os 也算"没有库"), 拿它判路线 B 生死是假阴性。
------------------------------------------------------------------
ok, out = run({ lazy = true })
check("⑤ 只有 __index 能取到库 → 不崩", ok, out)
check("⑤ 照样判出 B:YES", out:find("=>B:YES", 1) ~= nil, out)
check("⑤ open 探得到(不是 no-lib)", out:find("open:function", 1) ~= nil, out)
check("⑤ os 也探得到(六个 no-lib 的签名不能复现)", not out:find("no%-lib", 1), out)
check("⑤ 三口径如实报出 raw 与 env 的差别",
    out:find("io%(env:table raw:nil try:table%)", 1) ~= nil, out)

------------------------------------------------------------------
-- ⑥ 库是 userdata(带 __index 的库对象)时也不能说成"没有库"
------------------------------------------------------------------
ok, out = run({ io_userdata = true })
check("⑥ userdata 不崩", ok, out)
check("⑥ userdata 不报 no-lib", not out:find("no%-lib", 1), out)

if failed > 0 then
    print(string.format("test_cmd_fs: %d/%d 失败", failed, checked))
    os.exit(1)
end
print(string.format("test_cmd_fs: %d 个断言全部通过", checked))
