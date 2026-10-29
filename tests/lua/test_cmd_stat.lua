-- R:STAT 应答的单测。2026-10-29 (12-fix-11) 新增。
--
-- 为什么要有: R:STAT 是前端每 5 秒问一次的主通道, 它的应答格式一坏,
-- 前端整块面板就空了 —— 而现场最难查的故障之一就是"前端只显示一部分数据"。
-- 12-fix-11 把它的拼法从"三次拷贝"改成"一次拼接", 这种改动必须有测试钉住
-- 输出的结构没变(前端还在按老格式解析)。
--
-- 模拟器里 uart 是 C 库的只读表, 换不掉 write, 截不到串口上的东西 ——
-- 所以命令模块把"拼"这一步单独露成 M._stat_reply() / M._json_reply_str()。
--
-- 跑法: tools\run_lua_tests.bat test_cmd_stat.lua

local cmd = require "svc/cmd"
cmd.init()

local failed = 0
local function check(name, ok, detail)
    if ok then
        print(string.format("ok   %s", name))
    else
        failed = failed + 1
        print(string.format("FAIL %s: %s", tostring(detail or ""), name))
    end
end

local parts, out = cmd._stat_reply()
out = out or ""

check("有应答", out ~= "", "没拼出内容")
check("以 RET:STAT={ 开头", out:sub(1, 10) == "RET:STAT={", out:sub(1, 40))
check("以 } 加换行结尾", out:sub(-3) == "}\r\n" or out:sub(-2) == "}\n",
    "结尾: " .. string.format("%q", out:sub(-6)))
-- 拼接错位最常见的三种坏法
check("没有 ,, (段之间漏了逗号)", not out:find(",,", 1, true), "有 ,, ")
check("没有 ,} (多了个逗号)", not out:find(",}", 1, true), "有 ,} ")
check("没有 {, (多了个逗号)", not out:find("{,", 1, true), "有 {, ")

-- 花括号要配平(多一层少一层都会让前端 JSON 解析失败)
local depth, minv = 0, 0
for i = 1, #out do
    local c = out:sub(i, i)
    if c == "{" then depth = depth + 1 elseif c == "}" then depth = depth - 1 end
    if depth < minv then minv = depth end
end
check("花括号配平", depth == 0 and minv >= 0, string.format("结束深度=%d 最低=%d", depth, minv))

-- 顶层字段: 前端按这几个 key 取, 少一个就少一块面板
check("有 mode 段", out:find('"mode":', 1, true) ~= nil, out:sub(1, 200))
check("有 data 段", out:find('"data":', 1, true) ~= nil, out:sub(1, 200))
check("有 guard 段", out:find('"guard":', 1, true) ~= nil, out:sub(1, 200))

-- 片段表本身: 每段都是 "key":json 的形状
local ok_shape = #parts > 0
for i = 1, #parts do
    if not parts[i]:match('^"[^"]+":') then ok_shape = false end
end
check("每段都是 \"key\":json 的形状", ok_shape, table.concat(parts, " | "):sub(1, 200))

-- ===== 分配量: 12-fix-11 之前是三份拷贝(key+body / body / body+\r\n) =====
--   现在只拼一次。这里量"拼一次"造了多少字节, 钉住红线。
local function measure(fn)
    collectgarbage("collect")
    collectgarbage("collect")
    local c0 = collectgarbage("count")
    fn()
    local c1 = collectgarbage("count")
    collectgarbage("collect")
    return (c1 - c0) * 1024
end

local bytes = measure(function() cmd._json_reply_str("RET:STAT=", parts) end)
print(string.format("R:STAT 拼一次(不含编码): %d 字节 (整行 %d 字节)", bytes, #out))
-- 拼一次只该造出一份整行(多出来的是 table.concat 的中间开销)
check("拼一次的分配量不超过 1.5 份整行", bytes < #out * 1.5 + 1024,
    string.format("分配 %d / 整行 %d", bytes, #out))

if failed > 0 then
    print(string.format("FAIL: %d 项不通过", failed))
    os.exit(1)
end
print("test_cmd_stat: 全部通过")
