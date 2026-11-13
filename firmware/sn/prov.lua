local util = require "util"
local log = util.log()

local uart = util.get("uart")
local sys = util.try("sys")
local fskv = util.try("fskv")
local rtos = util.try("rtos")

local M = {}

local DATA_BITS, STOP_BITS, PARITY = 8, 1, 0
local BAUD = 115200
-- 单行命令上限。W:CFG 一次下发整个 poll 配置(含全部寄存器),
-- 128 条寄存器最坏约 12.7KB, 所以给 16KB。
-- 超限只能整缓冲丢弃(命令以 \n 结尾, 半行丢了也没法补), 但正常情况下
-- 前端发多少接多少, 到不了这个值
local MAX_BUF = 16384

local UART_ID = uart.VUART_0
if UART_ID == nil then UART_ID = 4 end

-- 收包缓冲: rx_buf = 已拼好、待切行的字节; rx_parts = 还没拼的分片。
--   原来 on_receive 每收一片就 rx_buf = rx_buf .. data —— 一条 12KB 的
--   W:CFG(128 点最坏 12.7KB)要连抄十几次(1+2+…+12KB ≈ 78KB 垃圾), 而 Lua
--   堆总共才 300KB。2026-11-10 现场保存 90 点时池子 used 306712/307192,
--   再抄一份 5KB 就 not enough memory。分片攒着, 只在真攒出完整一行时并
--   一次, 单分片时一次都不抄。
local rx_buf, rx_parts, rx_len = "", {}, 0
-- 这一批被丢掉的原因(超限/OOM), 由 M.poll 取走并如实回一次, 不静默吞
local rx_lost
local cb_registered, loop_started = false, false

-- V1-1 修复 (2026-11-06): SN 烧写期间暂停 INFER_PUSH 推送
-- 烧写工具在 W:SN 后紧跟 R:SN 回读校验，期间如果收到 RET:INFER_PUSH
-- 会被当成意外应答，导致校验失败、自动上锁不成功
local sn_busy = false
function M.busy() return sn_busy end

local function load_switch(key, default)
    if fskv then
        local v = fskv.get(key)
        if v == "1" or v == 1 then return true end
        if v == "0" or v == 0 then return false end
    end
    return default
end

M.write_enable = load_switch("sn_en_write", true)
M.clear_enable = load_switch("sn_en_clear", true)
M.lock_enable = load_switch("sn_en_lock", true)
M.unlock_enable = load_switch("sn_en_unlock", true)

function M.set_switch(name, on, persist)
    local field = name .. "_enable"
    if M[field] == nil then return false, "unknown switch" end
    M[field] = on and true or false
    if persist then
        if not fskv then return false, "fskv unavailable" end
        fskv.set("sn_en_" .. name, on and "1" or "0")
        if fskv.save then pcall(fskv.save) end
    end
    log.info("prov", "switch", name, tostring(on))
    return true
end

function M.switch_status()
    return {
        write = M.write_enable,
        clear = M.clear_enable,
        lock = M.lock_enable,
        unlock = M.unlock_enable,
    }
end

local function reply(s)
    log.debug("prov", "tx:", s)
    pcall(uart.write, UART_ID, s .. "\r\n")
end

local function sn() return require "sn/sn" end

local CMDS = {}

-- R:SN: 产线烧写软件(pc_tool/device.py read_sn)的回读校验通道。
-- burner.py 写入 W:SN 后必须用 R:SN 回读比对，比对不过就不上锁、直接判失败。
-- 曾按"前端零调用"删过它，结果产线卡在校验步：设备只打一行 debug 日志不回应答，
-- PC 端等超时报"设备无响应"，SN 实际已写入但锁没上。
-- ⚠️ 这条指令的调用方不在本仓库，删前必须确认产线工具还在不在用
CMDS["R:SN"] = function()
    local st = sn().state()
    if st == "ready" then reply("RET:SN=" .. tostring(_G.get_device_sn()))
    elseif st == "invalid" then reply("RET:SN=INVALID")
    else reply("RET:SN=EMPTY") end
end

CMDS["R:ID"] = function()
    reply("RET:ID=" .. sn().info_line())
end

CMDS["C:SN"] = function()
    if not M.clear_enable then return reply("RET:FAIL:clear disabled") end
    local ok, err = sn().clear()
    if ok then reply("RET:OK") else reply("RET:FAIL:" .. tostring(err)) end
end

CMDS["LOCK:SN"] = function()
    if not M.lock_enable then return reply("RET:FAIL:lock disabled") end
    if sn().state() ~= "ready" then return reply("RET:FAIL:no sn") end
    if not sn().set_lock() then return reply("RET:FAIL:lock not persisted") end
    reply("RET:OK")
end

CMDS["UNLOCK:SN"] = function()
    if not M.unlock_enable then return reply("RET:FAIL:unlock disabled") end
    if not sn().locked() then return reply("RET:FAIL:not locked") end
    sn().clear_lock()
    log.warn("prov", "SN lock cleared (rework)")
    reply("RET:OK")
end

CMDS["R:SNEN"] = function()
    local st = M.switch_status()
    reply(string.format("RET:SNEN=write=%d clear=%d lock=%d unlock=%d",
        st.write and 1 or 0, st.clear and 1 or 0, st.lock and 1 or 0, st.unlock and 1 or 0))
end

local function trim(s)
    -- 快速路径: 命令首尾无空白时零分配（大 JSON 命令避免 gsub 二次分配）
    local f = s:byte(1)
    if f and f > 32 then
        local l = s:byte(-1)
        if l and l > 32 then return s end
    end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function dispatch(line)
    -- 同 cmd.M.reply 的 12-fix-9 规矩: 整条命令别交给日志模块格式化。
    --   128 点的 W:CFG 有 12.7KB, 打全行 = 又一份同尺寸分配 + 同尺寸串口输出,
    --   正好压在最紧的地方。短命令照旧打全(排查够用), 长行只打长度 + 头 80 字节
    if #line > 80 then
        log.debug("prov", "cmd:", #line, "B:", line:sub(1, 80))
    else
        log.debug("prov", "cmd:", line)
    end
    -- V1-1 修复 (2026-11-06): SN 操作期间暂停 INFER_PUSH，避免烧写工具收到意外应答
    local is_sn_cmd = false
    local warg = line:match("^W:SN=(.+)$")
    if warg then
        is_sn_cmd = true
        if not M.write_enable then return reply("RET:FAIL:write disabled") end
        local s, force = warg:match("^([^,]*),?(.*)$")
        sn_busy = true
        local ok, err = sn().write(trim(s), { force = force:upper() == "FORCE" })
        if ok then reply("RET:OK") else reply("RET:FAIL:" .. tostring(err)) end
        sn_busy = false
        return
    end
    local swarg = line:match("^W:SNEN=(.+)$")
    if swarg then
        is_sn_cmd = true
        local name, val, persist = swarg:match("^%s*([^,]+)%s*,%s*([^,]+)%s*,?%s*(%a*)%s*$")
        if not name or not val then return reply("RET:FAIL:SNEN:bad args") end
        local on = (trim(val) == "1" or trim(val):upper() == "ON" or trim(val):upper() == "TRUE")
        sn_busy = true
        local ok, err = M.set_switch(trim(name):lower(), on, trim(persist):upper() == "P")
        if ok then reply("RET:OK") else reply("RET:FAIL:" .. tostring(err)) end
        sn_busy = false
        return
    end
    local fn = CMDS[line]
    if fn then
        -- R:SN, C:SN, LOCK:SN, UNLOCK:SN, R:ID, R:SNEN 都是 SN 相关
        is_sn_cmd = line:match(":SN") or line == "R:ID" or line == "R:SNEN" or line == "C:SN"
        if is_sn_cmd then sn_busy = true end
        fn()
        if is_sn_cmd then sn_busy = false end
        return
    end
    if type(_G.vcom_handle) == "function" and _G.vcom_handle(line) then return end
    log.debug("prov", "unknown cmd, ignored:", line)
end

-- 把攒下的分片并进 rx_buf —— 但只在【确实攒出了完整一行】时才并, 否则
-- 继续攒着(大命令逐片到达, 提前并等于白抄一遍)
local function cat2(a, b) return a .. b end

-- 失败原因里带上真实报错 + Lua 池水位。
--   ⚠️ 为什么不能再写死 "concat fail": 11-12 那两次 rx lost 只有这五个字,
--   而附近【没有】E/mem 行, 于是"到底是 OOM 还是 table.concat 换了别的说法"
--   整轮没法判。11-13 补了水位之后当场对上 ——
--     E/mem used 293544, alloc 4089  ← 正好是那一整行 4072B + 一点点
--     E/user.prov rx lost: concat fail, drop 4072B
--   现在把 pcall 的第二返回值原样带出来, 下次再看见 rx lost 第一件事就该是
--   "它说的是哪句话", 不用再去猜
local function why_and_pool(e)
    local s = tostring(e):gsub("[\r\n]", " ")
    if #s > 96 then s = s:sub(1, 96) end
    local pool = ""
    if rtos then
        local ok, total, used = pcall(rtos.meminfo, "lua")
        if ok and type(total) == "number" and type(used) == "number" then
            pool = " pool " .. math.floor(used) .. "/" .. math.floor(total)
        end
    end
    return s .. pool
end

local function rx_merge()
    if #rx_parts == 0 then return end
    local has_line = false
    for i = 1, #rx_parts do
        if rx_parts[i]:find("\n", 1, true) then has_line = true break end
    end
    if not has_line then return true end
    -- ⚠️ 并串这一步【自己】就是最容易 OOM 的地方: 一条 128 点的 W:CFG 是十几
    --   KB 一整串, 池子高水位时 table.concat 直接抛 "not enough memory for
    --   buffer allocation"。11-12 现场那条异常就是从 M.poll 的 while 顶上跑出去
    --   打死整个 VM 的(prov.lua:190 → E/mem → Lua VM exit!! reboot in 15000ms),
    --   而紧下面调 dispatch 那行是 pcall 保护的 —— 保护点恰好漏在了最该保护的
    --   那步之外。现在并不动就整批丢掉并如实回报, 别让 VM 陪葬。
    --   丢的只是【还没并进来的分片】, rx_buf 里已有的行不受影响。
    local joined
    if #rx_parts == 1 then
        joined = rx_parts[1]
    else
        local ok, s = pcall(table.concat, rx_parts)
        if not ok or type(s) ~= "string" then
            local bytes = rx_len
            rx_parts, rx_len = {}, 0
            return false, why_and_pool(s) .. ", drop " .. bytes .. "B"
        end
        joined = s
    end
    rx_parts, rx_len = {}, 0
    -- rx_buf 非空时这次拼接又是一整份拷贝, 同样会抛
    if rx_buf == "" then
        rx_buf = joined
        return true
    end
    local ok2, nb = pcall(cat2, rx_buf, joined)
    if not ok2 or type(nb) ~= "string" then
        -- rx_buf 那份是已经在手上的, 不该跟着陪葬: 只丢并进不来的 joined,
        -- 里面那条命令丢了就丢了, 由上面的如实回报告诉前端重发
        return false, why_and_pool(nb) .. ", drop " .. #joined .. "B"
    end
    rx_buf = nb
    return true
end

function M.poll()
    local n = 0
    while n < 8 do
        -- 每轮都先并进新分片: 派活(dispatch)期间 handler 可能让出 CPU 很久
        --   (W:CFG 重启轮询要 sys.wait(500)), 那期间到的字节就躺在 rx_parts 里,
        --   并进来才能和老代码一样在同一轮 poll 里接着切下一行
        local okr, why = rx_merge()
        if not okr then rx_lost = why end
        local nl = rx_buf:find("\n", 1, true)
        if not nl then break end
        local end_pos = nl - 1
        -- \r\n 行尾: 跳过 \r, 避免 gsub 对大字符串二次分配
        if end_pos > 0 and rx_buf:byte(end_pos) == 13 then end_pos = end_pos - 1 end
        local line = rx_buf:sub(1, end_pos)
        rx_buf = rx_buf:sub(nl + 1)
        line = trim(line)
        if #line > 0 then
            -- ⚠️ 吞掉错误会掩盖整类故障: 2026-11-10 情况1 整条 90 点 W:CFG
            --   收到了、日志也打了, 却一个应答都没有 —— 因为分配失败发生在
            --   cmd.M.handle 里 pcall(fn) 【之外】的 gsub, 一路冒到这里的
            --   pcall 被无声吃掉。必须打出来, 至少让人知道命令崩在哪
            local pok, perr = pcall(dispatch, line)
            if not pok then
                log.error("prov", "cmd crashed:", line:sub(1, 40), tostring(perr))
                pcall(reply, "RET:FAIL:internal error")
            end
            n = n + 1
        end
    end
    -- 一轮只报一次: 分片已经丢掉, 逐片刷应答会把串口堵死。如实报的价值在于
    --   前端当场就知道"这条没进去、重发", 不用再干等到超时(11-12 那次崩之前
    --   现场看到的正是"发了没回")
    if rx_lost then
        log.error("prov", "rx lost:", rx_lost)
        pcall(reply, "RET:FAIL:rx 丢弃, 请重发")
        rx_lost = nil
    end
    return n
end

-- 收到一片字节就先【攒着】, 不拼串 —— 拼串的活儿在 rx_merge 里, 见上面
-- rx_parts 的注释(一条 128 点的 W:CFG 逐片到达, 边收边拼要白抄几十 KB)
local function rx_push(data)
    rx_parts[#rx_parts + 1] = data
    rx_len = rx_len + #data
    if rx_len + #rx_buf > MAX_BUF then
        -- 超限只能整批丢: 命令以 \n 结尾, 留着半行也没法补
        -- ⚠️ 丢掉这件事【必须让用户知道】(和上面并串失败同一个道理):
        --   以前静默丢完, 前端只看见"发了没回", 一路等到超时。11-10 那次
        --   90 点 W:CFG 就是这么被读成"设备不理人了"
        rx_lost = "oversize, drop " .. (rx_len + #rx_buf) .. "B > " .. MAX_BUF
        rx_parts, rx_len, rx_buf = {}, 0, ""
    end
end

-- 单测入口: 等价于 uart 收到一片字节 (tests/lua/test_prov_rx.lua)。
--   模拟器里 uart 是只读表、换不掉 read, 所以留这个口子让测试直接喂
function M._rx_feed(s) rx_push(s) end

local function on_receive(id, len)
    if id ~= UART_ID then return end
    if type(len) ~= "number" or len <= 0 then return end
    while true do
        local ok, data = pcall(uart.read, id, 1024)
        if not ok then
            log.error("prov", "uart.read err:", tostring(data))
            return
        end
        if type(data) ~= "string" or #data == 0 then break end
        rx_push(data)
    end
end

function M.init(id)
    if id ~= nil then UART_ID = id end
    local ok, err = pcall(uart.setup, UART_ID, BAUD, DATA_BITS, STOP_BITS,
        uart.NONE or uart.None or 0)
    if not ok then
        log.error("prov", "uart.setup failed! id =", UART_ID, tostring(err))
        return false
    end
    local st = M.switch_status()
    log.info("prov", string.format("COM%d setup ok, switch: write=%d clear=%d lock=%d unlock=%d",
        UART_ID, st.write and 1 or 0, st.clear and 1 or 0, st.lock and 1 or 0, st.unlock and 1 or 0))
    return true
end

function M.register_callback()
    if cb_registered then return true end
    local ok, err = pcall(uart.on, UART_ID, "receive", on_receive)
    if not ok then
        log.error("prov", "uart.on failed! id =", UART_ID, tostring(err))
        return false
    end
    cb_registered = true
    log.info("prov", "COM" .. UART_ID .. " ready")
    return true
end

function M.start_loop()
    if loop_started then return true end
    if not sys then return false end
    loop_started = true
    sys.taskInit(function()
        while true do
            M.poll()
            sys.wait(20)
        end
    end)
    log.info("prov", "cmd loop started")
    return true
end

function M.wait_ready(timeout_ms)
    if timeout_ms == nil then timeout_ms = 30000 end
    if timeout_ms < 0 then timeout_ms = 0 end
    local tries = math.floor(timeout_ms / 100) + 1
    for i = 1, tries do
        if not cb_registered then
            pcall(uart.setup, UART_ID, BAUD, DATA_BITS, STOP_BITS, uart.NONE or uart.None or 0)
            M.register_callback()
        end
        if cb_registered then
            M.start_loop()
            return true
        end
        if i < tries and sys then sys.wait(100) end
    end
    return false
end

function M.uart_id() return UART_ID end

return M
