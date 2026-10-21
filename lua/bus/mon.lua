local util = require "util"
local cfg = require "core/config"
local log = util.log()

local uart = util.get("uart")
local gpio = util.try("gpio")
local sys = util.try("sys")

local mbus = require "bus/mbus"
local collector = require "data/collector"

local M = {}

local running, gen = false, 0
local rxbuf = ""
local pendingReqs, lastReqs = {}, {}
local lastRx, lastBaud = 0, nil
-- 识别中标记: true = 正在扫 21 个候选, 业务视为未就绪; M.stop() 会清
local detecting, detectGen = false, 0
-- sniff-2 fix: forceStop 标志, mon.stop() 立刻设 true, auto_detect 内部
--   每次 sys.wait 醒来 check, 立即 return. 否则 sys.wait(2000) 期间切档
--   静默跑完剩余 baud, 还会调 uart.setup 改分频, 破坏 mon.stop 已经关闭
--   的 uart.on("receive", nil) 效果 (用户实测 16:07:35.965 切 idle 后
--   16:07:36.780 还在 Uart_ChangeBR)
local forceStop = false
-- 进 sniff 时的配置参数(可能和现场不符)。识别失败要把串口还原成它,
-- 否则扫空后串口停在最后候选(1200 8O1), 真流量全成乱码
local bootCfg = nil
-- 两轮识别间隔。3s 足够等到稀疏主机冒流量, 高频重扫白耗电
local DETECT_RETRY_MS = 3000
-- 每 fc 最多留 4 条待配对请求。能进 push_req 的 fc 只有 3/5/15 三个
-- (parse_frame 是白名单 + 强制 CRC, 其余 fc 到不了这里), 所以
-- pendingReqs 总共 ≤ 12 条 —— 改 decode_frame 的 kind 判断时记得复核这条
local MAX_PENDING_PER_FC = 4

-- sniff-2 fix: 替代 sys.wait, 每 20ms 醒来 check forceStop, 切档时
--   最迟 20ms 内退出, 不让后台 auto_detect 在 sys.wait(2000) 中跑完
--   剩余 baud. forceStop 标志在 mon.stop 里立刻设 true
local function sniff_wait(ms)
    local t = 0
    while t < ms do
        if forceStop or not running then return false end
        if sys then sys.wait(20) end
        t = t + 20
    end
    return not forceStop and running
end
-- lastReqs 的键是 "slave:qty", 键空间上千万且只增不减。sniff 挂在异常总线上
-- 会单调增长, 两千条左右就吃掉大半 Lua 堆, 而 iot 的 OOM 兜底 trim_cache()
-- 根本清不到它 —— 所以这里自己封顶。超了整表作废重来, 不逐条 FIFO:
-- guess_last_req 本来只认 10 秒内的条目, 丢掉的都是更旧的, 配对结果不变
local MAX_LAST_REQ = 64
local PAIR_TIMEOUT_MS = 250
-- 推断展开的上限 (2026-10 加, 修 OOM 崩溃):
--   一次请求的 qty 来自【请求帧的 2 字节】, 可以是 0..65535, 跟实际回了多少
--   字节无关。总线上出现一个异常 qty 的请求(别的协议的帧/脏帧), 下面那个
--   "while j < f.qty" 就会展开 6 万多项 —— 每个一项一个表 + 一个字符串 key,
--   几十 MB, Lua 堆(203K)直接爆: "not enough memory for buffer allocation"
--   → VM 退出 → 设备重启。现场表现就是"跑着跑着莫名重启, 重启后又好了"。
--   Modbus 规范 FC03/FC04 一次最多读 125 个寄存器(0x7D), 取 256 留余量;
--   推断表总共也封顶(多从机 × 多地址的组合), 超了不再新增行。
--   qty 的封顶逻辑在 util.clamp_qty (能单测), 这里只留总行数上限
local MAX_INFER_ROWS = 512
local stat = { frames = 0, reqs = 0, rsps = 0, errs = 0, paired = 0, orphans = 0,
               detect_round = 0, detect_fail = 0, infer_clamped = 0 }

local function key(slave, qty) return tostring(slave) .. ":" .. tostring(qty) end

local function push_req(f)
    local q = pendingReqs[f.fc]
    if not q then q = {}; pendingReqs[f.fc] = q end
    q[#q + 1] = { fc = f.fc, slave = f.slave, addr = f.addr, qty = f.qty, ts = os.clock() }
    while #q > MAX_PENDING_PER_FC do table.remove(q, 1) end
    lastReqs[key(f.slave, f.qty)] = { fc = f.fc, slave = f.slave, addr = f.addr, qty = f.qty, ts = os.clock() }
    -- 封顶, 理由见 MAX_LAST_REQ。pairs 数键数不再养计数器: 65 项
    -- 表每帧多走几十次迭代, 换来少一个要跟 stop() 同步的状态
    local n = 0
    for _ in pairs(lastReqs) do n = n + 1 end
    if n > MAX_LAST_REQ then lastReqs = {} end
end

local function guess_last_req(fc, slave, qty)
    if not qty then return nil end
    local r = lastReqs[key(slave, qty)]
    if not r or r.fc ~= fc then return nil end
    if (os.clock() - r.ts) > 10 then return nil end
    return r
end

-- 从 pendingReqs[fc] 里找最晚一条同 slave 同 qty 的在途请求。
-- ⚠️ 只能命中才 table.remove: 原来是"边删边比"(remove 写在校验前面),
--    于是任何一次不匹配都会把整队清空 -- 一个 rsp 打飞全部在途请求,
--    之后同 fc 的其他 rsp 只能全 orphan。这也是 paired 恒 0 的直接原因。
-- ⚠️ 必须比 slave: 总线上同时有两台从机、qty 又撞上时(现场 s1 读 qty=2、
--    s11 也读 qty=2), 不比从机会把 s11 的请求配给 s1 的响应。
local function pop_req(fc, slave, qty, now)
    local q = pendingReqs[fc]
    if not q then return nil end
    while #q > 0 and (now - q[1].ts) > (PAIR_TIMEOUT_MS / 1000) do
        table.remove(q, 1)
    end
    for i = #q, 1, -1 do
        local r = q[i]
        if r.slave == slave and r.qty == qty then
            table.remove(q, i)
            return r
        end
    end
    return nil
end

-- B1: 配对成功就把旁听到的值写进 collector, 让 iot 现成的 dirty->publish
-- 链路自己把数据发上平台。sniff 自己不发请求, 不写这里 dataCache 永远空,
-- V2.3_3 dtype 启发式打分: 3 维度 (连续性 50% + 值域 30% + 边界 20%)
-- 默认按 modbus 标准 16bit 拆 (qty=N = N 个独立 uint16/int16 寄存器)
-- 32bit 合并候选: 16bit conf<80 时试 32bit, 32bit conf>16bit+5 才合并
-- 合并时 2 个 16bit alias 都标同 dtype (reg<addr> + reg<addr+1> 都是 float32)
-- 跨帧一致 +5% 加成. conf cap 100
local dtypeHistory = {}  -- alias -> { d1, d2, ..., d8 } FIFO 最近 8 帧 dtype

local function pushHistory(alias, dtype)
    local h = dtypeHistory[alias] or {}
    h[#h + 1] = dtype
    if #h > 8 then table.remove(h, 1) end
    dtypeHistory[alias] = h
end

-- 连续性: 跟历史 dtype 一致率 (本帧 + 历史 7 帧 FIFO)
local function calcContinuity(alias, cand)
    local h = dtypeHistory[alias] or {}
    if #h == 0 then return 50 end  -- 首帧不给满分也不给 0, 中性
    local same = 0
    for _, d in ipairs(h) do if d == cand then same = same + 1 end end
    return math.floor(same / #h * 100)
end

-- 值域: 类型范围内给高分, 超出给 0
local function calcRange(dtype, v)
    if v == nil then return 0 end
    if dtype == "int16" and v >= -32768 and v <= 32767 then return 100
    elseif dtype == "uint16" and v >= 0 and v <= 65535 then return 100
    elseif dtype == "int32" and v >= -2147483648 and v <= 2147483647 then return 100
    elseif dtype == "uint32" and v >= 0 and v <= 4294967295 then return 100
    elseif dtype == "float32" and v == v and v ~= 1/0 and v ~= -1/0 then return 100  -- 非 NaN/Inf
    end
    return 0  -- 超出类型范围, 排除
end

-- 边界: 远离极值高分, 接近极值衰减
local function calcBoundary(dtype, v)
    if v == nil then return 0 end
    if dtype == "float32" then return 80 end  -- float 不强求, 不跟整数边界同分
    local lo, hi, av
    if dtype == "int16" then lo, hi, av = -32768, 32767, 0
    elseif dtype == "uint16" then lo, hi, av = 0, 65535, 32767
    elseif dtype == "int32" then lo, hi, av = -2147483648, 2147483647, 0
    elseif dtype == "uint32" then lo, hi, av = 0, 4294967295, 2147483647
    else lo, hi, av = 0, 0, 0 end
    local range = hi - lo
    local dist = math.abs(v - av) / (range / 2)
    if dist > 1 then dist = 1 end
    return math.floor(dist * 100)
end

-- 候选打分 (16bit 或 32bit 候选), 返回 (dtype, value, conf)
local function score(data, off, dtype, word_swap, alias)
    local v = mbus.parse_value(data, off, dtype, word_swap)
    local range = calcRange(dtype, v)
    if range == 0 then return nil, nil, 0 end
    local cont = calcContinuity(alias, dtype)
    local bnd = calcBoundary(dtype, v)
    local conf = math.floor(cont * 0.5 + range * 0.3 + bnd * 0.2)
    local h = dtypeHistory[alias] or {}
    if #h > 0 and h[#h] == dtype then conf = conf + 5 end
    if conf > 100 then conf = 100 end
    return dtype, v, conf
end

-- 默认 16bit 拆 + 候选 32bit 合并, 选 conf 最高的 dtype
-- 16bit 永远 +5 加成 (modbus 标准优先), 32bit 合并要显著高才覆盖
local function pickDtype(data, off, remaining, addr, slave, f)
    local alias = "reg" .. (addr + off)  -- 不带 s<slave>_ 前缀
    -- 16bit 候选 (永远跑, modbus 标准)
    local bestD, bestV, bestC = "uint16", 0, 0
    for _, d in ipairs({ "int16", "uint16" }) do
        local _, v, c = score(data, off, d, nil, alias)
        if c > bestC then bestD, bestV, bestC = d, v, c + 5 end  -- 16bit +5 优先
    end
    if bestC > 100 then bestC = 100 end
    -- 32bit 合并候选 (remaining>=2 时试 1 个 32bit 占 2 个 16bit 位置)
    if remaining >= 2 then
        local c32 = 0
        local d32, v32 = "uint32", 0
        for _, d in ipairs({ "int32", "uint32", "float32" }) do
            for _, ws in ipairs({ false, true }) do
                local _, v, c = score(data, off, d, ws, alias)
                if c > c32 then c32, d32, v32 = c, d, v end
            end
        end
        -- 32bit conf > 16bit+5 conf 即合并 (16bit 已 +5 加成, 公平比较)
        if c32 > bestC then
            return d32, v32, c32, true  -- 第 4 个参数 true = 32bit 合并
        end
    end
    return bestD, bestV, bestC, false
end

local function push_rsp_value(slave, addr, f)
    if not f.data or not addr then return end
    local total = math.floor(#f.data / 2)
    local i = 0
    -- v5: 32bit 合并赢时锁定 dtype, 后续段强制同 dtype 合并 (modbus 寄存器连续
    -- 32bit 是工业标准, 不会中间夹 16bit). 解决 2054 第 2 段 0x00000000 被
    -- 启发式判 16bit 拆 (uint16=0 c=75 跟 uint32=0 c=75 一样, 16bit+5 加成让
    -- 16bit 拆抢走 32bit 合并). 强制延续让 0x00000000 跟第 1 段 float32 一致.
    local lastMergedDtype = nil
    while i < total do
        local remaining = total - i
        if lastMergedDtype and remaining >= 2 then
            -- v5: 强制 32bit 合并, dtype = lastMergedDtype (跟上一段一致)
            local alias0 = "reg" .. (addr + i)
            local alias1 = "reg" .. (addr + i + 1)
            local v = mbus.parse_value(f.data, i, lastMergedDtype, false)
            local lo16 = 0
            if v ~= nil and lastMergedDtype ~= "float32" then
                lo16 = v % 65536
                if lo16 < 0 then lo16 = lo16 + 65536 end
            end
            -- 强制合并 conf=100 (跟上一段对齐, status=ok)
            collector.push_data(addr + i, alias0, f.hex, v, nil,
                lastMergedDtype, 100, "ok")
            collector.push_data(addr + i + 1, alias1, f.hex, lo16, nil,
                lastMergedDtype, 100, "ok")
            pushHistory(alias0, lastMergedDtype)
            pushHistory(alias1, lastMergedDtype)
            i = i + 2
        else
            local dtype, v, conf, merged32 = pickDtype(f.data, i, remaining, addr, slave, f)
            local alias0 = "reg" .. (addr + i)
            local status
            if conf >= 80 then status = "ok"
            elseif conf >= 60 then status = "review"
            else status = "uncertain" end
            collector.push_data(addr + i, alias0, f.hex, v, nil, dtype, conf, status)
            pushHistory(alias0, dtype)
            if merged32 then
                -- 32bit 合并: 2 个 16bit alias 都标同 dtype, 第 2 个 value = 低 16bit
                local alias1 = "reg" .. (addr + i + 1)
                local lo16 = 0
                if v ~= nil then
                    -- 32bit value 拆 2 个 16bit: 高 16bit 跟低 16bit
                    if dtype == "float32" then
                        -- float32 拆 2 个 uint16 (大端)
                        lo16 = 0  -- 简化: float32 不再拆 16bit, 第 2 个 alias 留空
                    else
                        lo16 = v % 65536
                        if lo16 < 0 then lo16 = lo16 + 65536 end
                    end
                end
                collector.push_data(addr + i + 1, alias1, f.hex, lo16, nil, dtype, conf, status)
                pushHistory(alias1, dtype)
                -- v5: 锁定 dtype, 后续段强制同 dtype 合并
                lastMergedDtype = dtype
                i = i + 2
            else
                -- v5: 16bit 拆打断 lastMergedDtype 锁定, 下一段重新 pickDtype
                lastMergedDtype = nil
                i = i + 1
            end
        end
    end
end

local function process_frame(s)
    local f = mbus.decode_frame(s)
    stat.frames = stat.frames + 1
    local pair_state, paired_addr = nil, nil
    if f.kind == "err" then
        stat.errs = stat.errs + 1
        pair_state = "err"
    elseif f.kind == "rsp" then
        stat.rsps = stat.rsps + 1
        -- pop_req 命中不了再退 guess_last_req(靠 lastReqs 兜 10 秒内的旧请求),
        -- 两条路都通到同一个 paired 处理, 别再抄一遍
        local hit = pop_req(f.fc, f.slave, f.qty, os.clock()) or guess_last_req(f.fc, f.slave, f.qty)
        if hit then
            stat.paired = stat.paired + 1
            pair_state, paired_addr = "paired", hit.addr
            push_rsp_value(f.slave, hit.addr, f)
        else
            stat.orphans = stat.orphans + 1
            pair_state = "orphan"
        end
    elseif f.kind == "req" then
        stat.reqs = stat.reqs + 1
        push_req(f)
        pair_state = "req"
    end
    f.pair_state = pair_state
    f.paired_addr = paired_addr
    f.paired_qty = f.qty
    collector.push_raw_rx(f.hex)
    collector.push_frame(f)
end

local function on_receive(id, len)
    if id ~= mbus.UART_ID then return end
    if type(len) ~= "number" or len <= 0 then return end
    while true do
        local ok, data = pcall(uart.read, id, 512)
        if not ok then return end
        if type(data) ~= "string" or #data == 0 then break end
        rxbuf = rxbuf .. data
        lastRx = os.time()
        if #rxbuf > 256 then rxbuf = rxbuf:sub(-128) end
    end
end

-- CRC 试探法切帧: 逐偏移找第一个 CRC 合法且长度自洽的帧;
-- 找不到丢 1 字节继续找。fc3/4 8 字节请求由 mbus.decode_frame 认
local function next_frame()
    for off = 1, #rxbuf do
        local s = rxbuf:sub(off)
        local n = mbus.try_extract_len(s)
        if n and #s >= n then
            local f = mbus.decode_frame(s:sub(1, n))
            if f then
                rxbuf = s:sub(n + 1)
                return s:sub(1, n)
            end
        end
    end
    return nil
end

local function task()
    local mygen = gen
    while running and gen == mygen do
        local s = next_frame()
        if s then
            process_frame(s)
        elseif #rxbuf > 0 then
            -- 可能是半帧: 已声明长度但数据没到齐, 此时丢首字节会把帧打碎。
            -- try_extract_len 需要至少 5 字节才能判定, 不足 5 字节只等待
            if #rxbuf < 5 then
                if sys then sys.wait(20) end
            else
                rxbuf = rxbuf:sub(2)
            end
        elseif sys then
            sys.wait(20)
        end
    end
end

-- 静默侦听总线 ms 毫秒, 返回期间解译出的帧数(R:SNIFF 用)
-- 从旁听 REQ 反推轮询表(R:INFER), 按 slave+addr+qty+fc 聚合命中次数
function M.infer()
    local fs = collector.get_frames()
    -- 健康度: 见到 RSP 的从机才算在线。主机轮询一个没接线的从机时只见请求不见
    -- 应答(实测 slave=11 三项 req、零 rsp), 那种 req 列进轮询表只会误导 ——
    -- 用户会照着配一个根本不存在的从机。必须单独走一遍: RSP 可能排在对应 req
    -- 后面, 边扫边判会漏掉刚扫过的那批
    local online = {}
    for _, f in ipairs(fs) do
        if f.kind == "rsp" and f.slave then online[f.slave] = true end
    end
    local agg, slaves, ignored = {}, {}, 0
    local agg_count = 0   -- agg 的条目数 (封顶用, 见 MAX_INFER_ROWS)
    -- V2.3_3 dtype 启发式 + v6 表格 alias 拆分: 每 alias 各自 1 行, key = slave:alias.
    -- 16bit 拆 2 个 alias 出 2 行 (98/99), 32bit 合并 2 个 alias 出 2 行 (2054/2055).
    -- conf 来自 push_rsp_value 多候选打分 (连续性 50% + 值域 30% + 边界 20% + 跨帧一致 +5%)
    -- status: ok (>=80) / review (60-80) / uncertain (<60)
    local cache = collector.get_all_latest()
    for _, f in ipairs(fs) do
        if f.kind == "req" and f.addr ~= nil and f.qty then
            -- addr 也要合法 (0..65535): 越界的地址会让 alias 变成 "reg70000"
            -- 这种怪 key, 推断表里出现看不懂的行
            if f.addr < 0 or f.addr > 65535 then
                stat.infer_clamped = stat.infer_clamped + 1
            elseif online[f.slave] then
                -- ⚠️ qty 必须封顶 (util.clamp_qty, 见 util.lua 注释): 请求帧里的
                --   qty 是 2 字节, 可以到 65535, 展开下去就是几万项 → 堆爆 → 重启
                local qty = util.clamp_qty(f.qty)
                if qty ~= f.qty then
                    stat.infer_clamped = stat.infer_clamped + 1
                end
                -- v8: 按 dtype 宽度遍历, 32bit 合并 1 个 32bit 寄存器 = 1 行
                -- (跳过 alias1), 16bit 拆 1 个 16bit 寄存器 = 1 行. count 字段
                -- 反映"占几个 modbus 16bit 位置" (uint16=1, float32=2).
                local j = 0
                while j < qty do
                    local alias = "reg" .. (f.addr + j)
                    local e = cache[alias]
                    local dtype = (e and e.dtype) or "uint16"
                    local width = mbus.TYPE_WIDTH[dtype] or 1
                    local key = f.slave .. ":" .. alias
                    local a = agg[key]
                    if not a then
                        -- 推断表总行数也封顶 (MAX_INFER_ROWS): 多从机 × 多地址
                        -- 的组合照样能把堆吃光, 超了不再新增行(hits 照常累加)
                        if agg_count >= MAX_INFER_ROWS then
                            stat.infer_clamped = stat.infer_clamped + 1
                            break
                        end
                        agg_count = agg_count + 1
                        a = {
                            slave = f.slave,
                            addr = f.addr + j,  -- 起始地址
                            count = width,      -- 占几个 16bit 位置
                            fc = f.fc,
                            hits = 0,
                            dtype = dtype,
                            conf = (e and e.conf) or 0,
                            status = (e and e.status) or "uncertain",
                            -- 最新值: 旁听应答解析出的最后一次 value (该地址
                            -- 没被解出过时为 nil, 前端推断表显示 --)
                            value = (e and e.value) or nil,
                        }
                        agg[key] = a
                        slaves[f.slave] = true
                    end
                    a.hits = a.hits + 1
                    -- 值保持最新: e 逐次请求查缓存, 后到的应答把旧值顶上去
                    if e and e.value ~= nil then a.value = e.value end
                    j = j + width  -- 32bit 跳 2, 16bit 跳 1
                end
            else
                ignored = ignored + 1
            end
        end
    end
    local regs = {}
    for _, a in pairs(agg) do regs[#regs + 1] = a end
    -- 先按从机再按地址排, 前端 R:INFER 直接按这个顺序显示
    table.sort(regs, function(x, y)
        if x.slave ~= y.slave then return x.slave < y.slave end
        return x.addr < y.addr
    end)
    local sl = {}
    for s in pairs(slaves) do sl[#sl + 1] = s end
    table.sort(sl)
    return {
        regs = regs,
        slaves = sl,
        -- 健康度过滤掉的请求条数, 前端据此提示"轮询没人应答"的地址
        ignored = ignored,
        stat = stat,
    }
end

function M.start(c)
    if running then return true end
    -- 2026-10: 进 sniff 先清上一轮的值/帧/旧识别结果(旧参数下的东西不能混进这一轮)
    collector.clear_all()
    _G.mon_detect_result = nil
    -- sniff-2 fix: 重新进 sniff 时清 forceStop, 否则上次的 stop 标志会让
    --   auto_detect 立刻 return "stopped" (detect_loop 也会跟着退)
    forceStop = false
    -- 没有 sniff 持久槽: 参数由 auto_detect() 试出来只存本次会话;
    -- 调用方不传 c 时用编译期默认(原空槽的 9600 8N1)
    c = c or { baud = cfg.BAUD, databits = cfg.DATABITS, stopbits = cfg.STOPBITS, parity = cfg.PARITY }
    if gpio then
        pcall(gpio.setup, mbus.DE_PIN, 0)
        pcall(gpio.set, mbus.DE_PIN, 0)
    end
    local ok, err = pcall(uart.setup, mbus.UART_ID, c.baud or cfg.BAUD,
        c.databits or cfg.DATABITS, c.stopbits or cfg.STOPBITS,
        mbus.parity_to_uart(c.parity or cfg.PARITY))
    if not ok then
        log.error("mon", "setup failed:", tostring(err))
        return false
    end
    bootCfg = c
    lastBaud = c.baud or cfg.BAUD
    pcall(uart.on, mbus.UART_ID, "receive", on_receive)
    running = true
    gen = gen + 1
    if sys then sys.taskInit(task) end
    log.info("mon", "sniff started")
    return true
end

-- iot 的 OOM 兜底调它: collector.trim_cache() 清不到 mon 的局部表
function M.trim_reqs() lastReqs = {} end

-- 扫空一轮后还原进 sniff 时的参数。不还原则串口停在最后候选(1200 8O1),
-- 接下来 3s 真流量全成乱码, 下一轮又从 9600 重新开始, 看着像"时好时坏"
local function restore_params()
    local c = bootCfg or { baud = cfg.BAUD, databits = cfg.DATABITS, stopbits = cfg.STOPBITS, parity = cfg.PARITY }
    pcall(uart.setup, mbus.UART_ID, c.baud or cfg.BAUD,
        c.databits or cfg.DATABITS, c.stopbits or cfg.STOPBITS,
        mbus.parity_to_uart(c.parity or cfg.PARITY))
    pcall(uart.on, mbus.UART_ID, "receive", on_receive)
    lastBaud = c.baud or cfg.BAUD
end

-- 21 候选 = 7 baud × 3 parity, parity 外层: 8N1 占绝大多数,
-- 先扫 7 个 8N1 baud 再碰 E/O, 常见 1~7s 命中, 全落空才走满 21s。
-- databits/stopbits 固定 8/1 —— ModbusRTU 事实标准。
--
-- 判定不新写校验, 借 task() 现有 CRC 试探切帧, 只数 stat.frames 增量:
-- CRC 16 位单帧误判 ~1/65536, 所以要 DETECT_HITS(2) 帧才算命中。
--
-- ⚠️ 结果只存本次会话不写 fskv, poll/sniff 两套配置必须隔离(见 README)
function M.auto_detect()
    if not sys then return nil, "no sys" end
    if not running and not M.start() then return nil, "start fail" end
    -- sniff-2 fix: mon.start 后强制清 forceStop, 否则上次的 stop 标志
    --   会让本轮 auto_detect 立即 return "stopped"
    forceStop = false
    -- sniff 启动后等 5s: 142 设备 UART 从 poll 切到 sniff 可能错乱,
    -- 等它稳定再切 baud. 之前 0 帧就是 142 设备 UART 没准备好
    log.info("mon", "auto_detect: wait 5s for 142 UART stable")
    if not sniff_wait(5000) then return nil, "stopped" end
    for _, p in ipairs({ 0, 1, 2 }) do
        for _, b in ipairs(cfg.DETECT_BAUDS) do
            -- 完整复位 (合宙 Q1 修法): close + wait500 + setup + on
            -- 在已打开的 485 口上 uart.setup 走 Uart_ChangeBR 快路径,
            -- 只改分频不复位 RX/DE, 需 close+wait500 强制重开.
            pcall(uart.close, mbus.UART_ID)
            if not sniff_wait(500) then return nil, "stopped" end
            rxbuf = ""
            local ok = pcall(uart.setup, mbus.UART_ID, b, 8, 1, mbus.parity_to_uart(p))
            if ok then
                pcall(uart.on, mbus.UART_ID, "receive", on_receive)
                -- 高 baud 切完多等 200ms (跟之前 D2 v5 一致, 142 设备 19200
                -- t3.5=1.82ms 太早到 RX FIFO 接不住, 给驱动恢复窗口)
                if b >= 19200 then
                    if not sniff_wait(200) then return nil, "stopped" end
                end
                -- ★ Q2: 静默监听 cfg.DETECT_WIN_MS (默认 2000ms), 不主动发探针.
                -- 之前主动发 8 字节 modbus 请求会让 142 passive 设备响应, 但
                -- 也占用 485 总线跟其他 master 冲突. 静默监听切 baud 后看 RX
                -- 有没有 CRC 合法帧即可, 总线上有其他 master 在轮询就能命中.
                -- 142 设备场景无 master 时永远 0 帧, 由 cfg.BAUD 兜底 (见下).
                local before_frames = stat.frames
                if not sniff_wait(cfg.DETECT_WIN_MS) then return nil, "stopped" end
                log.info("mon", "check baud=" .. b .. " p=" .. p
                    .. " frames=" .. tostring(stat.frames)
                    .. " paired=" .. tostring(stat.paired)
                    .. " rxbuf=" .. tostring(#rxbuf)
                    .. " last_rx=" .. tostring(lastRx))
                -- ★ Q2: 命中条件改 any CRC 合法帧 (原来要 req+rsp 配对, 静默监听
                -- 收不到 master 的 rsp 时会漏检). 1 帧 CRC 误判 ~1/65536, 可接受.
                if stat.frames > before_frames then
                    lastBaud = b
                    log.info("mon", "detect ok: baud=" .. b .. " parity=" .. p)
                    return { baud = b, databits = 8, stopbits = 1, parity = p }
                end
            end
            if not running or forceStop then return nil, "stopped" end
        end
    end
    -- ★ Q2: 兜底 cfg.BAUD (restore_params 已经做了). 142 设备等 passive
    -- 从机场景没有其他 master 轮询, 静默监听永远 0 帧, 必须 user 配
    -- cfg.BAUD 才能 work. 返回 {..., fallback=true} 让 detect_loop 知道是兜底.
    restore_params()
    log.warn("mon", "detect silent fail: 21 candidates no hit, fallback cfg.BAUD=" .. cfg.BAUD)
    return { baud = cfg.BAUD, databits = cfg.DATABITS,
             stopbits = cfg.STOPBITS, parity = cfg.PARITY,
             fallback = true }
end

-- 识别循环: 扫一轮, 不中就还原参数/等 3s/再扫一轮, 直到命中或 mon.stop()。
-- 不回 idle: 模式必须停在 sniff, 否则前端看到掉回 idle 会以为设备重启了
-- mydgen 和 task.mygen 一样: 「重新识别」加 detectGen, 旧循环悄悄退出,
-- 否则两循环会同时抢串口, 先完成那个可能覆盖后一个的结果
local function detect_loop()
    local mydgen = detectGen
    while running and detectGen == mydgen do
        detecting = true
        stat.detect_round = stat.detect_round + 1
        local r = M.auto_detect()
        if detectGen ~= mydgen or not running then return end
        if r then
            detecting = false
            _G.mon_detect_result = r
            -- ★ Q2: 兜底 cfg.BAUD 也算"就绪", 但 log 跟命中区分, 不再 3s 重试循环
            if r.fallback then
                log.warn("mon", "detect silent fail, sniff running with cfg.BAUD fallback")
            else
                log.info("mon", "detect ok, sniff ready")
            end
            return
        end
        stat.detect_fail = stat.detect_fail + 1
        log.warn("mon", "detect round " .. stat.detect_round .. " no hit, retry in "
            .. DETECT_RETRY_MS .. "ms")
        -- sniff-2 fix: 用 sniff_wait 替代 sys.wait, 切档时不再闷头等
        if not sniff_wait(DETECT_RETRY_MS) then return end
    end
end

-- 请求开始/重来一轮识别。已在识别中就把 detectGen 加一作废当前轮, 由新任务从
-- 第一个候选重新扫 —— 这就是前端「重新识别」按钮的语义
function M.request_detect()
    if not running then return false, "not running" end
    detectGen = detectGen + 1
    _G.mon_detect_result = nil
    if sys then sys.taskInit(detect_loop) end
    return true
end

-- 2026-10: 「重新识别」= 先清旧帧旧值旧结果, 再重扫
function M.restart_detect()
    if not running then return false, "not running" end
    collector.clear_all()
    return M.request_detect()
end

function M.is_detecting() return detecting end

function M.detect_result() return _G.mon_detect_result end

function M.stop()
    if not running then return true end
    -- detecting 必须在这里清: W:MODE=idle 是识别中唯一逃生口,
    -- 少了这行 cmd 的 BUSY 闸门会一直把后续命令挡在外面
    detecting = false
    running = false
    gen = gen + 1
    -- sniff-2 fix: 立刻设 forceStop, auto_detect 内部最迟 20ms 内退出
    forceStop = true
    -- sniff-2 fix: 立刻关 UART. 不让后台的 auto_detect 后续 uart.setup
    --   改分频破坏 mon.stop 已关闭的 uart.on 回调. 下次进 sniff (mon.start)
    --   或 manual/platform (poll.start -> ensure_uart) 会重新 uart.setup
    if gpio then pcall(gpio.set, mbus.DE_PIN, 0) end
    pcall(uart.on, mbus.UART_ID, "receive", nil)
    pcall(uart.close, mbus.UART_ID)
    rxbuf = ""
    pendingReqs, lastReqs = {}, {}
    -- 2026-10: 退出 sniff 也清干净(值/帧/识别结果; 识别参数是会话级的,
    -- 不清的话下次进 sniff 前端会把上次的旧参数当成"已识别"显示)
    collector.clear_all()
    _G.mon_detect_result = nil
    log.info("mon", "sniff stopped")
    return true
end

function M.is_running() return running end

function M.status()
    local st = {}
    for k, v in pairs(stat) do st[k] = v end
    st.running = running
    st.gen = gen
    st.baud = lastBaud or cfg.BAUD
    -- 前端要靠它显示"正在识别(第N轮/已失败M次)", 也要靠它判断能不能点重新识别
    st.detecting = detecting
    st.detected = _G.mon_detect_result
    st.pending = (function()
        local n = 0
        for _, q in pairs(pendingReqs) do n = n + #q end
        return n
    end)()
    st.last_rx = lastRx
    st.buf = #rxbuf
    return st
end

function M.recent_frames(n)
    local fs = collector.get_frames()
    local out = {}
    for i = math.max(1, #fs - (n or 10) + 1), #fs do out[#out + 1] = fs[i] end
    return out
end

return M
