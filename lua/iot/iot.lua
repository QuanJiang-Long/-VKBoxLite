local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local sys = corelib.get("sys")
local json = corelib.try("json")
local mqtt = corelib.try("mqtt")
local rtos = corelib.try("rtos")
local mobile = corelib.try("mobile")
local socket = corelib.try("socket")

local mqttcfg = require "iot/mqttcfg"
local collector = require "data/collector"
local cfgstore = require "cfg"
local pullcfg = require "iot/pullcfg"
local mon = require "bus/mon"
-- 轮询引擎：拉取成功后自动落盘要能就地重启/热更轮询任务。
-- 惰性 require（用时才取）而不是顶层，避免 main.lua 的初始化顺序
-- 把 uart 还没 setup 的 poll 提前拖起来
local poll
local function get_poll()
    if not poll then
        local ok, p = pcall(require, "bus/poll")
        poll = ok and p or false
    end
    return poll or nil
end

-- 当前运行模式(idle/poll/pollpoll/sniff)。问 ctrl 要, 和 poll_slot() 一样
-- 走惰性 require: 依赖图已确认无环(全工程没有任何文件 require "iot/iot"),
-- 但顶层 require 会把 iot 的加载时机提前到 main.lua 初始化序列里, 保持
-- 惰性最稳。拿不到就当 idle -- 宁可少订也不能给未接任务的状态乱订
local ctrl_mod
local function get_mode()
    if ctrl_mod == nil then
        local ok, p = pcall(require, "bus/ctrl")
        ctrl_mod = ok and p or false
    end
    return (ctrl_mod and ctrl_mod.get_mode()) or "idle"
end

-- 当前轮询引擎用的是哪个配置槽("poll"=手动 / "pull"=拉取)。
-- 平台推送落地时据此决定要不要立即生效: 跑手动档就只存 ds_pull 备着，
-- 不许把手配的寄存器表顶掉。问 poll 而不是问 ctrl 是为了不引入
-- ctrl -> mon/poll -> iot 这条环
local function poll_slot()
    local p = get_poll()
    return (p and p.slot()) or "poll"
end

-- 当前在用的那份轮询配置: 拉取档读 ds_pull, 其余读 ds_poll。
-- ⚠️ 不能写死 load_poll: 平台是按 ds_pull 里的寄存器表下发的(报文里的 id
--    就是那边的 name/alias), 拿 ds_poll 去解析必然找不到地址 —— 而 ds_poll
--    在拉取档下通常是空的(从没手配过), 于是每条按名字下发的写指令都静默失败,
--    只有一行 write item unresolvable 日志, 平台那头看不出任何异常。
--    alias_map 同理: 上报的 name 字段也要按在用的那份映射, 否则平台上看到的
--    名称和用户配的不是一套
local function active_cfg()
    local f = (poll_slot() == "pull") and cfgstore.load_pull or cfgstore.load_poll
    local ok, c = pcall(f)
    return (ok and c) or nil
end

local M = {}

local S = {}

local function reset_state()
    S = {
        want_run = false, connected = false, subscribed = false,
        client = nil, dirty = false, backoff = 1,
        published = 0, failed = 0, replied = 0, kick_flag = false,
        recv_pending = nil, pub = nil, sub = nil, subs = nil, device_id = nil,
        last_pub = 0, last_err = nil, client_id = nil, user = nil,
        reject_reason = nil,
        pull = {
            state = "idle", msg = "", result = nil, deadline = 0,
            msg_id = nil, replied = false,
            -- src = "pull"/"push"：这份结果是谁给的。
            -- "push" = 平台主动重新下发，前端没点过拉取。二者走同一套
            -- done+回执链路，只是横幅提示语不同
            src = nil,
            seen = 0,              -- OS time，收到这份配置的时间
        },
        pull_payload = nil,
        -- 平台主动下发、刚落地的配置（push_n/push_err/push_seen）。
        -- 前端靠 R:STAT 5s 轮询发现它（R:PULLCFG 只在用户点拉取时才查），
        -- 所以必须单独挂在 status 段。autosaved 系列告诉前端"这次改动已落盘"
        push_n = 0, push_err = nil,
        autosaved = false, autosave_at = 0, autosave_regs = 0,
        -- U2/U3 的节流状态: meta_sig = 已发出去的网关元数据指纹(不带 nodes 那帧),
        -- topo_sig = 已发出去的拓扑指纹(带 nodes 那帧)。res_at = 上次发 U3
        -- 资源的时间(OS time)。cpu_percent 的两个累加量也在这里, reset 时归零,
        -- 否则重连后会拿上一个生命周期的残留算占比
        meta_sig = nil, topo_sig = nil, res_at = 0,
        busy_s = 0, span_s = 0,
        -- hello_at 是【连接生命周期内最后一次 hello 成功发送】的时间(OS time),
        -- 不是上电时间 —— task_main 靠它算 pollpull 档 30min 重发。置 0 表示
        -- 这个连接还没发过 hello, 重发计时不起跑(否则开机就白发一次)
        hello_at = 0,
    }
end

local function device_id()
    local ok, snc = pcall(require, "sn/sn")
    if ok and snc and snc.state() == "ready" then
        return _G.get_device_sn and _G.get_device_sn()
    end
    return nil
end

-- clientId 留空时的默认值: 设备 SN 加一个下划线。
-- 平台签发的凭证就是 "SN_" 这个形状(下划线后面是空的), 不带 ProductId ——
-- 产品不同那段就不同, 写死必然对不上。username 则是裸 SN, 见 try_connect。
-- 填了 client_id 就用手填值, 这里只兜空值。
local function default_client_id(did)
    if not did or did == "" then return did end
    return did .. "_"
end

local function get_topic()
    local did = device_id()
    if not did or did == "" then return nil end
    return string.format(cfg.PLATFORM_GET_TOPIC, did)
end

local function imei()
    if not mobile then return "" end
    local f = mobile.imei
    if type(f) ~= "function" then return "" end
    local ok, v = pcall(f)
    return ok and tostring(v) or ""
end

-- mobile.* 取号。全是无参函数, 塞引用不调用会让下游拿到函数体。
-- 取不到返回 nil, 让调用方决定"留空"还是"整个字段不发", 不编假值
local function mcall(k)
    if not mobile then return nil end
    local f = mobile[k]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f)
    return ok and v or nil
end

local function alias_map()
    local c = active_cfg()
    if not c or not c.regs then return {} end
    local m = {}
    for _, r in ipairs(c.regs) do m[r.name] = r.alias or r.name end
    return m
end

local function pad(v, n)
    local s = tostring(v)
    while #s < n do s = "0" .. s end
    return s
end

local function int_str(v)
    v = math.floor(v)
    if v < 1e9 then return tostring(v) end
    local high = math.floor(v / 1000000000)
    local low = v - high * 1000000000
    return tostring(high) .. pad(low, 9)
end

local function ms_of(ts)
    if type(ts) ~= "number" or ts ~= ts or ts < 0 then return "0" end
    local sec = math.floor(ts)
    local ksec = math.floor(sec / 1000)
    local rsec = sec - ksec * 1000
    local tail = rsec * 1000
    if ksec <= 0 then return tostring(tail) end
    return tostring(ksec) .. pad(tail, 6)
end

local function jstr(s)
    s = tostring(s)
    return '"' .. (s:gsub('[%c"\\]', function(c)
        local b = c:byte()
        if c == '"' then return '\\"'
        elseif c == "\\" then return "\\\\"
        else return string.format("\\u%04x", b) end
    end)) .. '"'
end

local function jnum(v)
    if type(v) ~= "number" then return nil end
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    if v == math.floor(v) and math.abs(v) < 1e15 then return int_str(v) end
    return tostring(v)
end

-- ===== 收拢重复样板的 helper =====
-- 上行帧的 7 个发送点(send_meta/send_topo/send_gw_res/func_reply/reply_config/
-- send_hello/claim_ok 的 did 解析)原来各写一遍"判连接 + pcall + tostring(e)",
-- 抄 7 遍必然改一处漏一处。pub 同时是连接闸门: 未连接就返回 false, "未连接"
local function pub(topic, body, qos)
    if not S.client or not S.connected then return false, "未连接" end
    local ok, e = pcall(function() S.client:publish(topic, body, qos or 1) end)
    if not ok then return false, tostring(e) end
    return true
end

-- 当前网关 SN, 取不到返回 nil。7 个调用点都要它, 各自判空后报不同的错
local function cur_did()
    local d = S.device_id or device_id()
    return (d and d ~= "") and d or nil
end

-- U3/U7 共用的 [{id,value,ts}] 数组。ts 传 nil 则不带该字段(U7 不要 ts)
-- id 兜底 "unknown": downlink_write 已保证 rid 非空, 但这是平台核销指令的
-- 键, 缺了平台对不上是哪一条, 代价只是一行 or
local function items_json(list, ts)
    local out = {}
    for _, it in ipairs(list) do
        local v = jnum(it.value) or "null"
        out[#out + 1] = ts
            and string.format('{"id":%s,"value":%s,"ts":%s}', jstr(it.id or "unknown"), v, ts)
            or string.format('{"id":%s,"value":%s}', jstr(it.id or "unknown"), v)
    end
    return "[" .. table.concat(out, ",") .. "]"
end

-- csq 为 0 即未注册。全项目只此一处定义 —— send_meta 的 netRegister 字段和
-- net_ready 的建连判据原本是两套同形算法, 口径一旦漂移, 平台看到的注册状态
-- 和设备实际能否建连就对不上, 且两边都不报错
local function net_registered(csq)
    return not (type(csq) == "number" and csq == 0)
end

-- U4 按子设备逐条上报: /sys/thing/node/property/post/{gwSn}-{n}。
-- n = 子设备序号, 按从机地址升序排(同一份配置只有一个 slave, 所以轮询档
-- 恒为 1; sniff 档才可能有多个从机)。从机地址从 key 里取:
--   sniff 的 key 是 "s{slave}_r{addr}"(见 bus/mon.lua push_rsp_value), 带从机号
--   轮询的 key 是配置里的 name 或 "r{addr}"(见 bus/poll.lua), 不带从机号
--   —— 一份轮询配置只有一个 slave(cfg.normalize_poll), 直接取那份的
-- 少了 -{n} 这个后缀, 平台无法把数据归属到子设备, 上报等于白发
local function build_items()
    local amap = alias_map()
    local c = active_cfg()
    local cfg_slave = c and c.slave or nil
    local by_slave, order = {}, {}
    for k, d in pairs(collector.get_all_latest()) do
        local vs = jnum(d.value)
        if vs then
            local slave = tonumber(k:match("^s(%d+)_r%d+$")) or cfg_slave
            if slave then
                if not by_slave[slave] then
                    by_slave[slave] = {}
                    order[#order + 1] = slave
                end
                by_slave[slave][#by_slave[slave] + 1] =
                    string.format('{"id":%s,"name":%s,"value":%s,"ts":%s}',
                        jstr(k), jstr(amap[k] or k), vs, ms_of(d.ts))
            end
        end
    end
    table.sort(order)
    local items = {}
    for n, slave in ipairs(order) do
        items[#items + 1] = {
            idx = n, slave = slave,
            body = "[" .. table.concat(by_slave[slave], ",") .. "]",
        }
    end
    return items
end

-- U4 子设备数据上报。topic = profile 出的 base 加 -{n} 后缀:
--   手动档 = 用户填的 pub_topic(连自己的 broker, 用自己的命名)
--   自动档 = PLATFORM_PUB_TOPIC 固定常量
-- {gwSn} 是网关 SN(顶层网关自己的设备号), -{n} 是子设备序号。少了 -{n}
-- 平台认不出数据归属哪个子设备, 上报等于白发
local function publish()
    if not S.client or not S.connected then return false end
    local items = build_items()
    if #items == 0 then return false end
    local base = S.pub or ""
    if base == "" then return false end
    local any = false
    for _, it in ipairs(items) do
        local ok, err = pcall(function()
            S.client:publish(base .. "-" .. it.idx, it.body, mqttcfg.load().qos)
        end)
        if ok then
            S.published = S.published + 1
            any = true
        else
            S.failed = S.failed + 1
            log.warn("iot", string.format("publish fail sub %d (slave %d): %s",
                it.idx, it.slave, tostring(err)))
        end
    end
    if any then
        S.dirty = false
        S.last_pub = os.time()
    end
    return any
end

-- ===== U2 拓扑上报 / U3 网关资源 / U7 指令回执 =====
-- 三条都是"发布", 与订阅清单无关(broker 负责路由, 见 build_subs 上头那段)。
-- body 字段名/结构照平台文档 V3 的示例, 一个不多一个不少 —— 少字段平台解析
-- 不出, 多字段平台可能按未知字段整包拒收

-- Lua 堆/系统内存信息: 返回 total, used; 取不到返回 nil, nil
-- Air780EP 堆约 300KB, mqtt.create 需要连续块, 建连前打印便于定位 OOM。
-- 只依赖 rtos(第 8 行就 require 了), 所以放这么前: U3 要用它算 ram_percent
local function heap_info()
    if not rtos or type(rtos.meminfo) ~= "function" then return nil, nil end
    local ok, a, b = pcall(rtos.meminfo, "sys")
    if not ok or type(a) ~= "number" then return nil, nil end
    return a, b
end

-- 内部 parity 0/1/2 -> 平台单字母。PULL_PARITY(core/config.lua)是正方向
-- "none/even/odd"->0/1/2, 这里是它的逆; 单独写死而不是反查 PULL_PARITY,
-- 免得为一次反查把整表遍历一遍
local PARITY_LETTER = { [0] = "N", [1] = "E", [2] = "O" }

-- U2 的 serial 段。port 固定 /dev/ttyS1: 485 走 uart1(日志 Uart_ChangeBR
-- 一路都是 uart1), 平台侧也按这个名字认串口
local function serial_json(c)
    c = c or {}
    return string.format('{"port":"/dev/ttyS1","baudRate":%d,"dataBits":%d,"stopBits":%d,"parity":%s}',
        c.baud or cfg.BAUD, c.databits or cfg.DATABITS,
        c.stopbits or cfg.STOPBITS, jstr(PARITY_LETTER[c.parity or cfg.PARITY] or "N"))
end

-- U2 的一个子设备。两个来源, 保真度差很远:
--   poll/pollpull: active_cfg() —— 平台下发的正经配置, id/name/dtype 全是真的
--   sniff: mon.infer() —— 旁听推断, 只有 slave/addr/count/fc, 没有名字和类型,
--          id/name 只能按地址现造("r"+addr), dtype 默认 uint16。平台上看到
--          的名字会是地址而不是中文别名, 想看得顺眼得让用户配一份轮询表
-- ⚠️ nodeIndex 必须和 U4 的 -{n} 同一套序号(都按从机地址升序), 否则平台把
--    建档的子设备和上报的数据对不上, 症状是"拓扑发成功了但数据不进去"
local function node_json(idx, slave, c, regs)
    local props = {}
    for _, r in ipairs(regs) do
        local dt = r.dtype or "uint16"
        props[#props + 1] = string.format(
            '{"id":%s,"name":%s,"dataType":%s,"modbus":{"slave":%d,"address":%d,"quantity":%d,"dataType":%s}}',
            jstr(r.name), jstr(r.alias or r.name), jstr(dt), slave, r.addr, r.count or 1, jstr(dt))
    end
    return string.format(
        '{"nodeIndex":%d,"slaveId":%d,"kind":"RTU","serial":%s,"model":{"tslName":%s,"properties":[%s]}}',
        idx, slave, serial_json(c), jstr("node_" .. idx), table.concat(props, ","))
end

-- U2 的 nodes[]。返回 nil+原因表示拓扑还没成形(从机没识别出来/没配寄存器表)
-- sniff 档的 RegisterData[] = 旁听推断 ∪ 平台下发配置, 同名同址以配置覆盖:
-- 平台是按我们上报的拓扑来建设备和生成配置的(用户确认), 只报推断那几条,
-- 平台就只认那几条; 配置落地后带真名(CT1/A相电流)的寄存器必须补进去才不缺项。
-- 因为 topo_sig 拿本函数产物当指纹, 配置一落地签名就变, 会自动补发一次 ——
-- 实测过的时序坑: 拓扑比配置落盘早 1 秒发(报的是推断出的 2 条裸名), 之后
-- 签名不变就再也不补发, 平台上建的物模型和数据面对不上
-- sniff 的 serial 参数必须用探测到的那几个值: active_cfg() 在 sniff 下返回的
-- 是 ds_poll 手工档的默认 9600, 而总线的波特率是自动识别出来的。拿错的
-- 波特率上报, 平台就照它建配置 —— 实测识别出 2400 却发了 9600, 平台回的
-- 建设配置 baud 就是 9600, 拿这份配置去轮询一帧都收不到
local function build_nodes()
    local mode = get_mode()
    local nodes, err = {}, nil
    if mode == "sniff" then
        local at, by = {}, {}
        local function put(slave, r)
            local k = slave .. ":" .. r.addr
            local p = at[k]
            if p then
                p.count, p.name, p.alias, p.dtype = r.count, r.name, r.alias or r.name, r.dtype or "uint16"
                return
            end
            -- 不记 slave: 分组已经由 by[] 的键承载, node_json 拿的是循环
            -- 变量 s, 再存一份是只写不读
            p = { addr = r.addr, count = r.count, name = r.name, alias = r.alias or r.name, dtype = r.dtype or "uint16" }
            at[k] = p
            by[slave] = by[slave] or {}
            by[slave][#by[slave] + 1] = p
        end
        for _, r in ipairs(mon.infer().regs or {}) do
            put(r.slave, { addr = r.addr, count = r.count, name = "r" .. r.addr, dtype = "uint16" })
        end
        local pc = cfgstore.load_pull()
        for _, r in ipairs((pc and pc.regs) or {}) do
            put(pc.slave, r)
        end
        local st = mon.status()
        local d = st.detected
        local ser = {
            baud = (d and d.baud) or st.baud,
            databits = (d and d.databits) or 8,
            stopbits = (d and d.stopbits) or 1,
            parity = (d and d.parity) or 0,
        }
        local sl = {}
        for s in pairs(by) do sl[#sl + 1] = s end
        table.sort(sl)
        for i, s in ipairs(sl) do
            nodes[#nodes + 1] = node_json(i, s, ser, by[s])
        end
        err = "还没识别到在线的从机"
    else
        -- 一份轮询配置只有一个 slave(cfg.normalize_poll), 所以轮询档恒一个节点
        local c = active_cfg()
        if c and c.regs and #c.regs > 0 then
            nodes[#nodes + 1] = node_json(1, c.slave, c, c.regs)
        end
        err = "没有可用的寄存器表"
    end
    if #nodes == 0 then return nil, err end
    return table.concat(nodes, ",")
end

-- 拓扑签名: 拿 build_nodes 的产物本身做指纹。不另造一套字段遍历是因为
-- node_json 已经把从机/寄存器/串口参数全拼进去了, 那串字符串变了就是拓扑
-- 真变了。重新 build 一次的代价是一次字符串拼接, 每秒一次可以忽略 —— 比
-- 自己去遍历两套来源(poll 的 regs 表 / mon.infer 的 regs 表)要短得多
local function topo_sig()
    local nodes = build_nodes()
    if not nodes then return nil end
    return tostring(#nodes) .. ":" .. nodes
end

-- U2 是【双重用途】, 靠 body 里有没有 nodes[] 区分语义(用户确认):
--   带 nodes[]    → 子设备拓补建档(建子设备 + 绑定 + 物模型)
--   不带 nodes[]  → 上报网关元数据(imei/iccid/信号/经纬度)
-- 所以拆成两个函数各发一帧, 不合成一帧 —— 合成会让平台拿不准这帧该干嘛。
-- 两帧共用 topic 和 qos, 用 pcall 包 publish, 失败只回 false 不抛

-- 把 "2.0.0" 变成 20000 这种纯数字。平台侧 firmwareVersion 是 BigDecimal,
-- 传字符串会【整帧被丢】(用户确认), 而我们全程只有字符串版本号, 必须转。
-- 取 major*10000 + minor*100 + patch, 与文档示例 v0.4.0 -> 400 同口径;
-- 解析不出就退回 0, 不留字符串也不编一个大数
local function fw_num()
    local v = _G.VERSION or ""
    local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)")
    if not a then return 0 end
    return tonumber(a) * 10000 + tonumber(b) * 100 + tonumber(c)
end

-- 不带 nodes 的那帧: 网关元数据。字段名/类型照平台 V3 文档示例, 一个不多一个
-- 不少 —— 少字段平台解析不出, 多字段可能按未知字段整包拒收。
-- 无源的字段(imei/iccid/经纬度)按注释留空或整项不发, 不编假值
local function send_meta()
    local did = cur_did()
    if not did then return false, "无 SN" end
    local csq = mcall("csq")
    if type(csq) ~= "number" then csq = nil end
    local p = {}
    p[#p + 1] = string.format('"sn":%s', jstr(did))
    p[#p + 1] = string.format('"deviceSn":%s', jstr(did))
    p[#p + 1] = string.format('"imei":%s', jstr(imei()))
    p[#p + 1] = string.format('"iccid":%s', jstr(tostring(mcall("iccid") or "")))
    p[#p + 1] = string.format('"fw":%s', jstr("v" .. (_G.VERSION or "0.0.0")))
    p[#p + 1] = string.format('"firmwareVersion":%d', fw_num())
    p[#p + 1] = string.format('"hw":%s', jstr(cfg.PLATFORM_MODEL))
    p[#p + 1] = string.format('"capabilities":[%s]', '"modbus","mqtt"')
    p[#p + 1] = string.format('"deviceName":%s', jstr("VKBOX-" .. did))
    p[#p + 1] = string.format('"serialNumber":%s', jstr(did))
    if csq then p[#p + 1] = string.format('"csq":%d', csq) end
    p[#p + 1] = string.format('"netRegister":%s', tostring(net_registered(csq)))
    p[#p + 1] = string.format('"networkAddress":%s', jstr(mqttcfg.load().host))
    p[#p + 1] = string.format('"isShadow":0')
    p[#p + 1] = string.format('"summary":%s', jstr("VKBox Bootstrap"))
    -- ts 用秒: 文档示例 1721884800 是 10 位。毫秒会让平台按 1970 年解析
    p[#p + 1] = string.format('"ts":%d', os.time())
    return pub(string.format(cfg.PLATFORM_INFO_TOPIC, did), "{" .. table.concat(p, ",") .. "}", 1)
end

-- 带 nodes[] 的那帧: 子设备拓补建档。只带网关标识 + 拓扑, 自述性字段
-- (fw/firmwareVersion/imei/...) 归 send_meta, 不在这儿重复发一遍
local function send_topo()
    local did = cur_did()
    if not did then return false, "无 SN" end
    local nodes, err = build_nodes()
    if not nodes then return false, err end
    return pub(string.format(cfg.PLATFORM_INFO_TOPIC, did),
        string.format('{"sn":%s,"deviceSn":%s,"ts":%d,"nodes":[%s]}',
            jstr(did), jstr(did), os.time(), nodes), 1)
end

-- 元数据指纹: 只挑会变的字段(imei/iccid/csq/主机名), 版本和型号是常量不必算。
-- 拿这几个字段拼串当指纹, 变了就重发, 和 topo_sig 同一套路
local function meta_sig()
    local csq = mcall("csq")
    return string.format("%s|%s|%s|%s", imei(),
        tostring(mcall("iccid") or ""), tostring(type(csq) == "number" and csq or ""),
        tostring(mqttcfg.load().host or ""))
end

-- U3: 网关自身资源。口径要说清, 否则平台拿阈值做告警会定错:
--   ram_percent  = rtos.meminfo("sys") 已用/总量, 真实系统内存(比 Lua 堆全)
--   uptime_sec   = os.clock() 秒级单调计数, 开机起算, 不受 NTP 跳变影响
--   cpu_percent  = 本框架主循环的忙碌占比(真实测量, 不是 MCU 的 CPU 占用率)。
--                 LuatOS 没有 OS 级 CPU 接口(README 记过 fsinfo/fs 都不存在),
--                 与其编一个 0 骗平台, 不如报一个能测的量。平台若按 90% 做
--                 CPU 告警, 得知道这个口径 —— U5 告警本次不做(已确认)
local function send_gw_res()
    local did = cur_did()
    if not did then return false end
    local total, used = heap_info()
    local ts = ms_of(os.time())
    local ram = 0
    if total and total > 0 then
        ram = math.floor(used * 1000 / total) / 10
    end
    local cpu = 0
    if S.busy_s and S.span_s and S.span_s > 0 then
        cpu = math.min(100, math.max(0, math.floor(S.busy_s * 1000 / S.span_s) / 10))
    end
    local ok = pub(string.format(cfg.PLATFORM_RES_TOPIC, did),
        items_json({
            { id = "ram_percent", value = ram },
            { id = "uptime_sec", value = math.floor(os.clock()) },
            { id = "cpu_percent", value = cpu },
        }, ts), 1)
    if not ok then return false end
    -- 占用比是"上一个区间"的值, 发完就归零重新攒。不清的话 busy 一直涨而
    -- span 涨得更快, 占比会越算越小, 平台看到的是个单调下降的假曲线
    S.res_at = os.time()
    S.busy_s, S.span_s = 0, 0
    return true
end

-- U7: 指令回执。粒度只到"入队/拒绝": poll.enqueue_write 是异步的, 真正上
-- 总线的结果只有 write_status() 的汇总 done/fail, 分不出是哪一条。所以
-- 入队成功的 value 回原值, 拒绝的(地址解析不出/值非法/队列满)回 null ——
-- 这正是文档"失败项 value 回 null"里的失败项, 但【不等于已写到总线】。
-- 要精确到总线结果得给 poll 的写队列加 per-item 回调, 本次不做
local function func_reply(rs)
    if not rs or #rs == 0 then return false end
    local did = cur_did()
    if not did then return false end
    local ok, e = pub(string.format(cfg.PLATFORM_FPOST_TOPIC, did),
        items_json(rs, nil), 1)
    if not ok then
        log.warn("iot", "func reply fail:", tostring(e))
        return false
    end
    return true
end

-- conack 时的订阅清单。文档"订阅关系"明确下行 topic 三路同（sniff/platform/
-- manual 都是 /sys/thing/gw/function/get/{target} 等 4 条），所以除 idle 外
-- 所有档都订同一份，不再按模式分流：
--
-- idle：什么都不订。idle 是"未接任务"的原始态，此时 MQTT 连接可以是通的
--   （凭证、broker 都与模式无关），但订阅意味着接收平台下行，而拉取配置
--   (config/get) 和下行写 (property/set 系列) 都只在 poll/pollpull/sniff
--   下才有意义。idle 订着 = 设备还没开始采数就先挂在平台的接收侧，
--   看着像已经接了任务，实际一个字节都不会用上。
--
-- 其余三档：4 条 gw 平台前缀，一条都不能少：
--   ① D1(/gw/config/get/{sn}) 是"拉取配置"链路唯一的入口
--   ② function/get + property/set + property/get 是平台侧另外三类下行，
--      不订就收不到服务调用/属性设置/全量查询，且无报错
--   这 4 条是 core/config.lua 的平台常量，不随配置变
--
-- ⚠️ 手动档额外还要订用户填的 sub_topic：手动档连的是用户自己的 broker，
--    平台那套 /sys/thing/gw/{sn} 拼出来也没人往那儿发。不订用户那条 =
--    用户配的下行永远收不到。自动档的 sub 与 config/get 同形，上面已去重
-- ⚠️ 曾按 manual_on 分流过，导致 sniff 沿用切入前那份清单：从 idle 进 sniff
--    会是空的，从手动配置进 sniff 又少订 4 条平台 topic，平台下发到设备全丢。
local function build_subs()
    local subs = {}
    local function add(t)
        if not t or t == "" then return end
        for _, x in ipairs(subs) do
            if x == t then return end
        end
        subs[#subs + 1] = t
    end
    if get_mode() == "idle" then return subs end
    local did = S.device_id
    if not did or did == "" then return subs end
    add(string.format(cfg.PLATFORM_GET_TOPIC, did))
    add(string.format(cfg.PLATFORM_FUNC_TOPIC, did))
    add(string.format(cfg.PLATFORM_PSET_TOPIC, did))
    add(string.format(cfg.PLATFORM_PGET_TOPIC, did))
    add(S.sub)
    return subs
end

-- 销毁 client。on_mqtt 的 error 分支也要调, 所以必须定义在它之前
-- (local function 是词法作用域, 写在后面会让 on_mqtt 里那个名字解析到全局 nil)
local function destroy_client()
    if S.client then
        -- 先关自动重连再断开, 否则断开后库仍会自行重连, 留下僵尸 client 占十几 KB
        pcall(function() S.client:autoreconn(false) end)
        pcall(function() S.client:disconnect() end)
        pcall(function() S.client:close() end)
        S.client = nil
    end
    S.connected = false
    S.subscribed = false
    collectgarbage("collect")
end

local function on_mqtt(cli, event, data, payload)
    if event == "conack" then
        S.connected = true
        S.backoff = 1
        S.reject_reason = nil
        -- 每个新连接都要重新报到。reset_state 只在 start() 时跑, 不断线重连
        -- 不会清 hello_at —— 不清的话重连后 task_main 的"连接后补发"分支
        -- (判 hello_at == 0)永远不成立, 平台那头看到的是设备中途消失再回来,
        -- 而没有任何 hello
        S.hello_at = 0
        local subs = build_subs()
        S.subs = subs
        S.subscribed = false
        -- qos 只取一次: mqttcfg.load 要读 fskv 解 JSON, 挂在循环里等于每个 topic 解一遍
        local qos = mqttcfg.load().qos
        for _, t in ipairs(subs) do
            local sok, serr = pcall(function() cli:subscribe(t, qos) end)
            -- 订阅成功才算已订阅, 否则 status 失真
            if not sok then log.warn("iot", "subscribe fail:", t, tostring(serr)) end
            S.subscribed = S.subscribed or sok
        end
        log.info("iot", string.format("conack ok, subscribed=%s, topics=[%s]",
            tostring(S.subscribed), table.concat(subs, " ")))
    elseif event == "recv" then
        S.recv_pending = { topic = data, payload = payload }
    elseif event == "disconnect" or event == "error" then
        S.connected = false
        S.subscribed = false
        -- CONACK 0x05 = 平台拒绝(未授权)。LuatOS C 库只打日志, 码值到不了
        -- Lua 层, 这里单独记一个 reject_reason。
        -- 不能塞进 last_err: try_connect 等满 15s 后会把它覆盖成
        -- "conack timeout", 拒绝原因就丢了(线上正是如此)。
        --
        -- 凡是 error 事件都记一条, 不能只认 conack: 域名解析失败 / TCP
        -- 建连失败同样只给事件不给码值(实测 data = "connect")。
        -- 两者混成一句 "conack timeout" 的后果是现场把"域名写错"当成
        -- "平台拒了", 照着 README 去补账号密码, 排查方向整个反了。
        --
        -- conack 来了就不再被别的 error 覆盖: 一次被拒会连收两条
        -- (先 error conack, 再 error other —— 线上实测如此), 后者是
        -- 库在拆 socket 时补发的, 语义上更弱。若让它覆盖, 页面上
        -- "平台拒绝"就变成了"连不上", 排查方向又反了。
        -- conack 成功和 reset_state 都会清掉 reject_reason, 不留残影。
        if event == "error" then
            local d = tostring(data)
            if d == "conack" or not S.reject_reason then
                if d == "conack" then
                    S.reject_reason = "平台拒绝连接(CONACK 0x05 未授权), 检查地址/端口或补用户名密码"
                else
                    S.reject_reason = "连不上服务器(" .. d .. "): 域名解析不到或端口不通, 核对 host 拼写"
                end
            end
            -- 立刻销毁 client, 不要再等 try_connect 满 15s:
            -- broker 拒绝是毫秒级就给出结论的(实测 293ms 回 CONACK 0x05),
            -- 而 autoreconn(false) 已设、库不会重连, 留着它纯占十几 KB 堆,
            -- 还让"被拒"看起来像"没响应" —— 现场改完配置要多等一轮 15s 才生效。
            -- S.client 置 nil 同时是 try_connect 等待循环的失败判据
            destroy_client()
        end
        log.warn("iot", event, tostring(data))
    end
end

-- 能否建连: 只有"明确知道没注册"才算不能。mobile 库缺失时返回 true ——
-- 没有依据就不能拦着连接, 那是把"测不出"当成"连不上"
local function net_ready()
    return net_registered(mcall("csq"))
end

local function try_connect()
    if not mqtt then return false, "mqtt 库不可用(需 sysplus/mqtt 组件)" end
    if type(mqtt.create) ~= "function" then return false, "mqtt.create 不可用" end
    local c = mqttcfg.load()
    local did = device_id()
    if not did or did == "" then
        if not c.allow_no_sn then return false, "no sn" end
        did = "unknown"
    end
    S.device_id = did
    -- 凭证和 topic 都按 manual_on 取: 手动档用前端填的 user/pass/pub_topic/
    -- sub_topic, 自动档用户名留空(iot 兜底填 SN) + 首页那份 MQTT凭证密码,
    -- topic 用 PLATFORM_* 固定常量(见 mqttcfg.profile)
    local prof, terr = mqttcfg.profile(did)
    if not prof then return false, terr end
    S.pub, S.sub = prof.pub, prof.sub
    -- B 模型: clientId = "SN_"(见 default_client_id), username = 裸 SN,
    -- 密码是平台签发的凭证密码。
    -- 填了 client_id/user 才用手填值, 否则一律按平台格式兜底
    local cid = c.client_id ~= "" and c.client_id or default_client_id(did)
    S.client_id = cid
    local user = prof.user ~= "" and prof.user or did
    S.user = user
    -- Air780EP Lua 堆约 300KB, mqtt.create 需要连续块; 建连前先 GC + 记录堆
    collectgarbage("collect")
    local h1, h2 = heap_info()
    log.info("iot", "create mqtt", c.host, c.port, "heap total=" .. tostring(h1) .. " used=" .. tostring(h2))
    -- 连之前把 CONNECT 关键参数打全。平台回 CONACK 0x05(未授权)时,
    -- 现场直接对照这行看 clientId/用户名发了什么, 不用猜
    log.info("iot", string.format("connect: host=%s port=%d ssl=%s clientId=%s user=%s clean=%s",
        c.host, c.port, tostring(c.ssl), cid, user, tostring(not c.keep_session)))
    local okc, cli = pcall(mqtt.create, nil, c.host, c.port, c.ssl)
    if not okc or not cli then return false, "mqtt.create 失败: " .. tostring(cli) end
    S.client = cli
    -- 空串要传 nil: auth() 只判指针非空就认为"有用户名", 会把零长
    -- 用户名字段塞进 CONNECT 包, 部分平台(EMQX/NanoMQ)据此判未授权,
    -- 回 CONACK 0x05。绝大多数平台只认地址+端口, 不能白送一个空用户名。
    -- 但本平台(B 模型)必须带 username = {sn}, 所以 user 在上面已经兜底成 SN,
    -- 到这里必然非空, 不会触发上面那个坑
    pcall(function() cli:auth(cid, user,
                              prof.pass ~= "" and prof.pass or nil, not c.keep_session) end)
    pcall(function() cli:keepalive(60) end)
    pcall(function() cli:autoreconn(false) end)
    local okon, eon = pcall(cli.on, cli, on_mqtt)
    if not okon then
        destroy_client()
        return false, "on 失败: " .. tostring(eon)
    end
    local ok, e = pcall(cli.connect, cli)
    if not ok or not e then
        destroy_client()
        return false, "connect 失败: " .. tostring(e)
    end
    -- 等 CONNACK。client 被销毁即已失败(on_mqtt 的 error 分支会立刻销毁),
    -- 这时要立即返回真实原因: 拒绝是毫秒级结论, 等满 15s 只会让 backoff
    -- 叠加上去, 现场改完配置慢一轮才生效, last_err 还会被假写成超时
    local waited = 0
    while waited < 15000 do
        if S.connected then return true end
        if not S.client then break end
        if sys then sys.wait(100) end
        waited = waited + 100
    end
    if not S.connected then
        destroy_client()
        -- 有 reject_reason 就用它, 它比这句兜底准确得多
        return false, S.reject_reason or "conack timeout"
    end
    return true
end

local function wait_kickable(ms)
    local waited = 0
    while waited < ms do
        if not S.want_run then return end
        if S.kick_flag then S.kick_flag = false; return end
        if sys then sys.wait(200) end
        waited = waited + 200
    end
end

local function downlink_write(items)
    local ok, poll = pcall(require, "bus/poll")
    if not ok or not poll then
        log.error("iot", "downlink write: bus/poll 不可用")
        return 0, 0
    end
    -- ⚠️ 必须按当前在用的槽取寄存器表和默认从机地址, 不能写死 ds_poll:
    --    拉取档在采的是 ds_pull, 平台的 id 是按那份表下发的。拿 ds_poll 解析
    --    会全部落到 write item unresolvable, 从机地址也可能取错
    local c = active_cfg()
    local regs = (c and c.regs) or {}
    -- 默认从机地址只读一次: 挂在循环里等于每条缺 slave 的下行都重读一次 fskv+JSON
    local dslave = (c and c.slave) or cfg.SLAVE_ADDR
    local function resolve_addr(k)
        if not k then return nil end
        if type(k) ~= "string" then
            -- 纯数字直接当地址, 避免对 number 调 :lower()
            if type(k) == "number" then return math.floor(k) end
            return nil
        end
        for _, r in ipairs(regs) do
            if r.name == k or r.alias == k then return r.addr end
        end
        local lk = k:lower()
        for _, r in ipairs(regs) do
            if r.name:lower() == lk or (r.alias and r.alias:lower() == lk) then return r.addr end
        end
        return nil
    end
    -- 安全取数: 下行 JSON 字段可能缺失或类型不对, 统一走 tonumber 兜底
    local function dnum(v)
        if v == nil then return nil end
        local n = tonumber(v)
        return n
    end
    -- 每条的结果, 给 U7 指令回执用: value = 入队成功的原值, nil = 拒绝。
    -- 只能到这个粒度, 理由见 func_reply 上头那段
    local results = {}
    local nok, nfail = 0, 0
    for _, it in ipairs(items) do
        local dkey = it.id or it.name or it.key or it.regName or it.reg_name
        local addr = dnum(it.addr or it.address or it.reg or it.register or it.offset)
        if not addr then addr = resolve_addr(dkey) end
        local slave = dnum(it.slave or it.dev or it.device or it.slaveId or it.slave_id)
        if not slave then slave = dslave end
        -- 回执的 id: 平台给的 id/name 优先, 没有就按地址现造一个, 否则
        -- 平台那头对不上是哪一条
        local rid = dkey
        if type(rid) ~= "string" or rid == "" then rid = "r" .. tostring(addr or 0) end
        if it.values and type(it.values) == "table" and addr then
            local vals = {}
            for _, v in ipairs(it.values) do
                local n = dnum(v)
                if not n then n = 0 end
                vals[#vals + 1] = n
            end
            local okw = poll.enqueue_write({ slave = slave, addr = addr, values = vals })
            if okw then nok = nok + 1 else nfail = nfail + 1 end
            results[#results + 1] = { id = rid, value = okw and #vals or nil }
        elseif addr then
            local v = dnum(it.value or it.val or it.data)
            if v then
                local okw = poll.enqueue_write({ slave = slave, addr = addr, value = v })
                if okw then nok = nok + 1 else nfail = nfail + 1 end
                results[#results + 1] = { id = rid, value = okw and v or nil }
            else
                nfail = nfail + 1
                results[#results + 1] = { id = rid, value = nil }
                log.warn("iot", "write item bad value:", tostring(dkey))
            end
        else
            nfail = nfail + 1
            results[#results + 1] = { id = rid, value = nil }
            log.warn("iot", "write item unresolvable:", tostring(dkey))
        end
    end
    -- ok 只代表"入队成功"，不是"已发到总线"：enqueue_write 是异步的，
    -- 真正发送由 poll_task / worker 完成，结果看 R:STAT 的 write.done/wfail。
    -- 不能再写成 "downlink write: ok=N" —— 现场看到这句会以为写成功了，
    -- 而实际可能还压在队列里
    log.info("iot", string.format("downlink write: queued=%d rejected=%d", nok, nfail))
    return results
end

-- SN 归属过滤（文档"订阅关系" + "{targetSN} = 网关 SN 或其子设备 SN"）：
-- 下行 topic 末段必须等于本机 SN 或 {gwSn}-{n}。
-- 同 broker 上多台网关时会收到别人的指令，不过滤就是拿别人的指令写本地寄存器。
-- 两条例外，都会导致合法下行被静默丢弃，必须放行：
--   ① 无 SN：无从判断（allow_no_sn 模式下设备本来就不带 SN）
--   ② 非 /sys/thing/ 命名空间：用户自己配的订阅 topic，不在 V3 契约内
local function claim_ok(topic)
    if type(topic) ~= "string" then return true end
    if topic:sub(1, 11) ~= "/sys/thing/" then return true end
    local did = cur_did()
    if not did then return true end
    local last = topic:match("([^/]+)$")
    if not last then return false end
    if last == did then return true end
    -- 子设备形态：{gwSn}-{nodeIndex}，如 11802026092600016-1
    return last:sub(1, #did + 1) == (did .. "-")
end

-- 拉取握手是否正在进行（connecting/helloing/waiting）。
-- 必须定义在 handle_downlink 之前：Lua 的 local 是词法作用域，
-- 在函数体里引用后面才声明的 local 会变成全局查找，运行时拿到 nil 直接崩
local function pulling()
    local st = S.pull.state
    return st == "connecting" or st == "helloing" or st == "waiting"
end

-- 平台主动重新下发配置（前端没点拉取，设备也没在等）。
-- 判据就是 payload 里有 configSnapshot：这是 D1 快照的独有字段，
-- 拉取成功后自动落盘并生效（用户要求：不再等前端「保存配置」确认）。
-- 放在设备侧而不是前端侧，是为了让前端不在线时也生效——平台主动重推
-- 走的是同一条路径，靠前端的话没开串口就永远不落地。
--
-- 三道安全边界（少一道就是把现场设备交给平台随便改）：
--   ① normalize_poll 不过就整个不落盘，走 fail，skipped 明细照旧带回
--   ② interval_ms / timeout_ms 取设备当前值，平台再怎么下发也不改轮询节奏
--   ③ 打一行醒目的前后对比日志，否则现场无法追溯"配置什么时候被谁改的"
local function auto_apply(r)
    if not r or not r.poll then return false, "无可应用的配置" end
    local n, nerr = cfgstore.normalize_poll(r.poll)
    if not n then return false, "配置不合法: " .. tostring(nerr) end
    -- 平台不给轮询节奏：保留设备自己的 interval/timeout。base 取 ds_pull
    -- 而不是 ds_poll —— 平台配置落自己的槽，手动配的那份寄存器表不许被
    -- 覆盖掉(两个模式各用各的，见 lua/README.md 配置来源隔离)
    local base = cfgstore.load_pull()
    n.interval_ms = base.interval_ms
    n.timeout_ms = base.timeout_ms

    local before = { slave = base.slave, baud = base.baud, regs = #(base.regs or {}) }
    local ok, serr = cfgstore.save_pull(n)
    if not ok then return false, "落盘失败: " .. tostring(serr) end

    local pe = get_poll()
    if pe then
        -- 只有拉取档才让平台配置立即生效。跑手动档时 ds_pull 只是存着备用，
        -- 一旦这里 apply_cfg/start, 手配的那套就被顶掉, 而用户根本没切档
        -- (两个模式各用各的槽, 见 lua/README.md 配置来源隔离)
        if poll_slot() == "pull" then
            -- 串口参数变了才值得重启轮询任务；只换寄存器表时 apply_cfg 就够了，
            -- 重启会硬断一次正在进行的 Modbus 事务
            if pe.needs_restart(n) then
                if pe.is_running() then
                    pe.stop()
                    pe.apply_cfg(n)
                    pe.start("pull")
                else
                    pe.apply_cfg(n)
                end
            else
                pe.apply_cfg(n)
            end
        end
    end

    S.autosaved = true
    S.autosave_at = os.time()
    S.autosave_regs = #n.regs
    log.info("iot", string.format(
        "pullcfg 自动保存并生效: 寄存器 %d->%d, slave %d->%d, baud %d->%d, msgId=%s",
        before.regs, #n.regs, before.slave or 0, n.slave or 0,
        before.baud or 0, n.baud or 0, tostring(S.pull.msg_id)))
    return true
end

-- U6 应用回执。必须声明在 recv_push / auto_apply / pull_step 之前：
-- pcall(reply_config) 传的是【已声明的函数对象】，声明在后等于捕获 nil，
-- 回执静默不发——平台会一直重推，而且没有任何报错。
-- 只回一次（p.replied 去重）；msgId 与 D1 下发包里的一致，平台据此核销。
-- 现在拉取成功即自动保存生效，所以回执也跟着自动发，不需要用户点保存。
local function reply_config()
    local p = S.pull
    if p.replied then return true end
    if not p.msg_id or p.msg_id == "" then return true end
    if not S.connected or not S.client then return false, "MQTT 未连接" end
    local did = cur_did()
    if not did then return false, "无 SN" end
    local topic = string.format(cfg.PLATFORM_REPLY_TOPIC, did)
    -- message 用拉取结果里的那句话: 空快照时写 "config applied" 是撒谎,
    -- 平台侧核销记录会看着像真配了一份
    local body = string.format(
        '{"msgId":%s,"code":200,"message":%s,"status":"ok","appliedTs":%d}',
        jstr(p.msg_id), jstr(p.msg ~= "" and p.msg or "config applied"), os.time())
    log.info("iot", "config/reply " .. topic .. " " .. body)
    local ok, err = pub(topic, body, 1)
    if not ok then return false, err end
    p.replied = true
    S.replied = S.replied + 1
    return true
end
M.reply_config = reply_config

-- 平台主动重新下发配置（前端没点拉取，设备也没在等）。
-- 判据就是 payload 里有 configSnapshot：这是 D1 快照的独有字段，
-- REPORT/WRITE/裸值都不带它，不可能误判。
-- 解析成功即自动落盘并生效，与前端拉取完全同一套语义。
-- 放在设备侧而不是前端侧，是为了让前端不在线时也生效——平台主动重推
-- 走的是同一条路径，靠前端的话没开串口就永远不落地。
-- 做法是把它塞进拉取结果槽位、以 done 态呈现，前端复用同一套回填渲染
local function recv_push(t, payload)
    local r, err = pullcfg.parse_snap(t, t.configSnapshot)
    if not r then
        S.push_err = tostring(err)
        -- 原始报文必须打出来: 解析失败只说"哪个字段不对", 不说了收到什么,
        -- 现场照着改不了。整包打, 不占多少日志
        log.warn("iot", "push parse fail: " .. tostring(err) .. " body=" .. tostring(payload))
        return false
    end
    S.push_err = nil
    -- 空快照 = 平台侧没有配置(sniff 互斥守卫), 与拉取链路同一套收尾方式：
    -- 按成功算 + 回执。不回执平台就每 1s 重推一次同一份空包
    if r.empty then
        S.pull.state = "done"
        S.pull.src = "push"
        S.pull.seen = os.time()
        S.pull.msg = "平台未下发配置，本地嗅探自建生效"
        S.pull.result = nil
        S.pull.msg_id = r.msg_id
        S.pull.replied = false
        pcall(reply_config)
        S.push_n = S.push_n + 1
        log.info("iot", "push recv empty snapshot, 平台无配置, msgId=" .. r.msg_id)
        return true
    end
    S.pull.state = "done"
    S.pull.src = "push"
    S.pull.seen = os.time()
    S.pull.msg = "平台重新下发"
    S.pull.result = r
    S.pull.msg_id = r.msg_id
    S.pull.replied = false
    -- 与前端拉取完全同一套语义：解析成功就自动保存并回执。
    -- 平台点了「重新下发」期望的就是立即生效，再要人去开软件确认就没意义了
    local aok, aerr = auto_apply(r)
    if aok then
        S.pull.msg = "平台配置已自动保存生效"
        pcall(reply_config)
        S.push_n = S.push_n + 1
        log.info("iot", string.format("push recv msgId=%s regs=%d skipped=%d (已自动保存)",
            r.msg_id, #(r.poll.regs or {}), #(r.skipped or {})))
    else
        S.push_err = "自动保存失败: " .. tostring(aerr)
        S.push_n = S.push_n + 1
        log.warn("iot", string.format("push recv msgId=%s 但自动保存失败: %s", r.msg_id, tostring(aerr)))
    end
    return aok
end

-- 只被本文件的 task_main 调用(收到 MQTT 下行时转进来)，不外泄
local function handle_downlink(topic, payload)
    if not claim_ok(topic) then
        log.info("iot", "downlink dropped, not ours: " .. tostring(topic))
        return
    end
    -- 平台配置下发与业务指令下行默认共用同一 topic
    -- (/sys/thing/gw/config/get/{sn}), 不能一见这个前缀就当配置包收下,
    -- 否则 REPORT/WRITE 指令全被吞掉。
    -- 只有拉取状态机正在 waiting 时才当配置包; 其余情况按普通指令解析。
    if type(topic) == "string" and topic:find("/gw/config/get/", 1, true) then
        if S.pull.state == "waiting" then
            log.info("iot", string.format("pullcfg recv topic=%s len=%d body=%s",
                topic, #tostring(payload), tostring(payload)))
            S.pull_payload = payload
            return
        end
        log.info("iot", "downlink on get topic, pull idle -> parse as cmd")
    end
    if not json then return end
    local ok, t = pcall(json.decode, payload)
    if not ok or type(t) ~= "table" then return end
    -- 平台手动重新下发：前端没在等，但这包就是新的 configSnapshot。
    -- 以前这里一路走到最后，既不是 REPORT/WRITE 也没有 items/value，
    -- 于是【什么都不发生】——平台以为发了、设备什么都没干，且无任何日志
    if type(t.configSnapshot) == "table" then
        if pulling() then
            -- 握手中（ connecting/helloing ）到达：这就是要找的响应，
            -- 寄存下来，等状态机走到 waiting 立刻消费掉。
            -- 直接当 push 处理会把 state 改成 done、把握手掐断，
            -- 用户点了「拉取配置」却拿到一份可能是旧的推送
            S.pull_payload = payload
            log.info("iot", string.format("push during handshake(%s), parked len=%d",
                S.pull.state, #tostring(payload)))
            return
        end
        recv_push(t, payload)
        return
    end
    local cmd = t.cmd and t.cmd:upper() or nil
    if cmd == "REPORT" or cmd == "READALL" then
        S.dirty = true
        return
    end
    -- 回执一律走 func_reply(returns 的第一个值就是 per-item 结果)。
    -- 每个分支都要发: 平台按收到的回执核销指令, 漏一个分支那类指令就永远
    -- 停在 "已下发未执行", FunctionLog 里看不到结果
    if cmd == "WRITE" and type(t.items) == "table" then
        func_reply(downlink_write(t.items))
        return
    end
    if t[1] and type(t[1]) == "table" then
        func_reply(downlink_write(t))
        return
    end
    if t.items and type(t.items) == "table" then
        func_reply(downlink_write(t.items))
        return
    end
    if t.value or t.values or t.val or t.data then
        func_reply(downlink_write({ t }))
        return
    end
    -- 走到这里说明报文形状一个都不认识。以前是静默 return，平台以为发了、
    -- 设备什么都没干、日志一片空白 —— 现场只能靠猜。至少把收到的原文打出来
    log.warn("iot", "downlink unrecognized, no action: " .. tostring(payload))
end

-- 平台配置拉取状态机。
-- W:PULLCFG 只置状态并立即应答; 握手跑在 task_main 协程里(那里才能 sys.wait)。
local function pull_active() return pulling() end

-- 拉取是否正在进行(connecting/helloing/waiting)。导出给 W:PULLCFG 判重:
-- pull_start() 对"已在拉取中"改成返回 true, 调用方就分不出是新一轮
-- 启动还是复用旧的一轮, 判重只能由它自己来
function M.pulling() return pulling() end

-- 不要求 MQTT 已连上: 只要配好服务器地址/端口, 设备自己去连, 连上再握手。
-- 这是新设备首次使用的正常顺序(先配 MQTT, 再拉配置)。
-- 切换 MQTT 手动/自动档。由 ctrl.switch_mode 在切 485 模式时调用:
--   poll(手动配置)    -> true   只订用户自己填的 topic
--   poll(拉取配置)    -> false  订平台 4 条, 否则 hello 发出去没人应答
-- 手动/自动没有混搭场景(要么全手配, 要么全平台拉), 所以档位直接跟模式走。
--
-- 为什么要 destroy+kick: 订阅清单 build_subs() 挂在 conack 上, 已连接的
-- client 不会自己重读一遍。不断开重连的话, 从拉取档切回手动档后设备还订着平台
-- topic, 看起来像"手动配置没生效"。断开重连只是丢一次心跳周期, collector 的
-- 数据和寄存器表不动
function M.set_manual(on)
    on = on and true or false
    local c = mqttcfg.load()
    -- 档位没变就不必断开重连: 白丢一次心跳, 还可能撞上正在进行的拉取握手
    if not not c.manual_on == on then return false end
    c.manual_on = on
    if on then
        -- 手动<-自动: 不用动 broker。host/port 是两档共用的(mqttcfg L12), 
        -- 手动档用户会自己填地址, 动它反而打断"自动档配好的地址切手动档继续用"
        local ok, err = mqttcfg.save(c)
        if not ok then return false, err end
    else
        -- 自动<-手动: 平台地址必须归位。host/port 虽说是共用字段, 但手动档
        -- 用户可能填了自建 broker; 带着那个地址发 hello, 没人应答, 只会白等
        -- 满 35s 再报超时, 用户根本看不出是地址错了。
        -- 只在这条切换路径上重置, 不动 normalize 的语义。
        -- auto.pass 要带过去: 那是用户自己设的平台凭证密码, 丢了会静默退回
        -- 内置默认密码, 表现为"我改过密码怎么不生效"
        local d = mqttcfg.default
        local ok, err = mqttcfg.save({
            host = d.host, port = d.port, ssl = d.ssl,
            manual_on = false,
            auto = { pass = c.auto and c.auto.pass or "" },
        })
        if not ok then return false, err end
    end
    destroy_client()
    M.kick()
    log.info("iot", "mqtt manual_on ->", tostring(on))
    return true
end

function M.pull_start()
    -- 已在拉取中就直接当成功: 调用方主要是 ctrl.switch_mode, 它不该因为
    -- "重复请求"就把整个切模式判失败。W:PULLCFG 那边自己先查 busy 再调
    if pull_active() then return true end
    if not get_topic() then return false, "无 SN" end
    local c = mqttcfg.load()
    if not c.host or c.host == "" then return false, "请先配置 MQTT 服务器地址" end
    if not c.port or c.port < 1 or c.port > 65535 then return false, "请先配置 MQTT 端口" end
    S.pull = {
        state = "connecting", msg = "", result = nil,
        deadline = os.time() + math.floor(cfg.PULL_CONNECT_MS / 1000),
        msg_id = nil, replied = false,
        -- hello 发送失败的重发计数(见 pull_step 的 helloing 分支)。
        -- 放在 pull 状态里而不放 S: 一轮拉取结束它就跟着作废, 不会把上一轮的
        -- 失败计数带给下一轮
        hello_try = 0,
    }
    -- 未连上时打断退避等待, 让 task_main 立刻重连, 不必等下一个周期
    if not S.connected then M.kick() end
    return true
end

function M.pull_status()
    local p = S.pull
    local r = { state = p.state, msg = p.msg }
    if p.result then
        r.poll = p.result.poll
        r.skipped = p.result.skipped
        r.renamed = p.result.renamed
        -- 只带发布/订阅两个 topic 成品给前端回显(手动档填输入框)。
        -- 另外 3 条 gw 下行订阅是设备端固定常量, 前端没有对应输入框
        local prof = mqttcfg.profile(device_id())
        r.mqtt = {
            pub = prof and prof.pub, sub = prof and prof.sub,
        }
    end
    -- 回执状态单独给：前端据此提示"已回执"还是"平台还在重推"
    r.msg_id = p.msg_id
    r.replied = p.replied
    -- src/seen/autosaved：前端据此把提示语从"已拉取待保存"换成
    -- "已自动保存生效"，并显示是哪来的、什么时候落的
    r.src = p.src or "pull"
    r.seen = p.seen
    r.autosaved = S.autosaved
    r.autosave_at = S.autosave_at
    r.autosave_regs = S.autosave_regs
    r.push_n = S.push_n
    r.push_err = S.push_err
    return r
end

-- U1 hello。payload 的 6 个字段照文档 V3 契约，另带两个自述字段。
-- 单独抽出来是因为有两个调用方：pull_step 的握手，以及 task_main 里 pollpull
-- 档的 30min 周期重发 —— 两处发的是同一帧，不应各写一份
-- 返回 true, onboardingMode / false, err
local function send_hello()
    if not S.client or not S.connected then return false, "未连接" end
    local did = device_id()
    if not did or did == "" then return false, "无 SN" end
    -- hello topic 走固定平台常量(不再可配)。上面已经判过无 SN, 这里
    -- did 一定是非空串, format 拼出来就是带 SN 的完整 topic
    local topic = string.format(cfg.PLATFORM_HELLO_TOPIC, did)
    -- topicFormat 固定 v3：自述 topic 形状，消除"平台硬编码旧版 / 固件烧新版"
    -- 漂移导致下行 topic 错位（指令全丢且无报错）。
    --
    -- onboardingMode 按当前 485 档位如实报(文档: sniff/platform/manual):
    --   sniff     → 平台跳过"对本地自建设备无效的配置快照推送"。这正是我们要的:
    --               sniff 档的寄存器表来自本地旁听推断, 平台推过来的只会是 193B
    --               空壳(devices/properties/commInterfaces 全空), 收了还得回执,
    --               不回执平台每 1s 重推一次
    --   platform  → 平台照常推 ConfigSnapshot(pollpull 档要的就是这个)
    -- manual 档也发 hello, 但报 platform 而不是 manual: 文档只定义了 sniff
    -- 的行为(跳过快照推送), manual 的行为没写。报一个未定义的值风险大于
    -- 收益; 手动档本来就不等 configSnapshot(不发 pull_start), 平台推了也
    -- 由 recv_push 直接落盘, 不会卡住任何流程
    local onboard = get_mode() == "sniff" and "sniff" or "platform"
    -- deviceId 按文档取 IMEI，取不到报 "unknown"（不报空串：平台校验
    -- gateway_imei，空串和缺字段是两回事）。不一致会被拒 hello
    local dv = imei()
    if dv == "" then dv = "unknown" end
    local body = string.format(
        '{"vendor":%s,"model":%s,"fwVersion":%s,"deviceId":%s,"topicFormat":"v3","onboardingMode":%s}',
        jstr(cfg.PLATFORM_VENDOR), jstr(cfg.PLATFORM_MODEL), jstr(_G.VERSION or "0.0.0"),
        jstr(dv), jstr(onboard))
    log.info("iot", string.format("pullcfg hello topic=%s sn=%s imei=%s mode=%s body=%s",
        topic, did, imei(), onboard, body))
    -- 发送失败不能记 hello_at: 那是"本连接最后一次 hello 成功发送"的时间,
    -- 记了失败这一次, task_main 的 30min 重发会从一个假起点起算
    local ok, err = pub(topic, body, 1)
    if not ok then return false, err end
    -- 记【本连接内最后一次 hello 成功发送】的时间: task_main 靠它算 pollpull 档
    -- 的 30min 重发。reset_state 里置 0 表示这个连接还没发过, 计时不起跑
    S.hello_at = os.time()
    return true, onboard
end

-- 向平台报到一次 hello, 不进拉取状态机(不等 configSnapshot)。
-- 给手动档用: ctrl 进 poll 档时调, 让平台知道这台网关上线了。平台侧不预知
-- 具体配置, 靠上报 auto-provision 补建设备档案。
-- 失败不回滚切模式 —— 进模式那一刻 MQTT 可能还没连上(set_manual 刚触发
-- 断开重连), 补发由 task_main 的"连接后补发"分支负责
function M.hello()
    if not S.client or not S.connected then return false, "未连接" end
    return send_hello()
end

local function pull_finish(state, msg, result)
    S.pull.state = state
    S.pull.msg = msg
    S.pull.result = result
    -- 拉取结果已被前端看到 = 这条通知的使命完成，撤掉
    if state == "done" then
        S.push_err = nil
    end
    log.info("iot", "pullcfg", state, msg)
end

local function pull_step()
    local p = S.pull
    if p.state == "connecting" then
        -- 实际建连由 task_main 的常规连接分支做, 这里只等, 避免两处同时
        -- 建连建出两个 client 互相覆盖
        if S.connected then
            -- deadline 必须清零: 它还留着 connecting 态的"等连接"上限(+20s),
            -- 不清的话 helloing 分支的"退避中就等着"会把第一次 hello 也当成
            -- 退避期跳过, 用户白等一个 PULL_CONNECT_MS 才看到 hello 发出去
            p.deadline = 0
            p.hello_try = 0
            p.state = "helloing"
        elseif os.time() >= p.deadline then
            local why = S.reject_reason or S.last_err or "超时"
            pull_finish("fail", "MQTT 连接失败: " .. tostring(why))
        end
    elseif p.state == "helloing" then
        -- pull_step 跑在 while 循环的连接判断之前(connecting 态要能在未连接
        -- 时也走), 所以这里不能假定 S.client 还在: 同一轮循环里 refresh_subs
        -- 发现模式变了订阅清单就 destroy_client() 把 client 抽走, 下一轮重进
        -- 来时 state 已经是 helloing, 直接索引 nil 就是
        -- "attempt to index a nil value (field 'client')", 整轮拉取被
        -- pull_finish 判死、平台再也收不到 hello。退回 connecting 重等。
        -- 不是空转: refresh_subs 只在清单真变时才抽一次, 重连后就位了
        if not S.client or not S.connected then
            p.state = "connecting"
            p.deadline = os.time() + math.floor(cfg.PULL_CONNECT_MS / 1000)
            return
        end
        -- 退避中(上一次发送失败定的重发时刻还没到)就等着, 不重发
        if p.deadline > os.time() then return end
        local ok, onboard, err = send_hello()
        if not ok then
            -- 按文档 1s/3s/9s 退避重发, 不立即判死: 发送失败多半是连接刚被
            -- refresh_subs 抽走, 下一轮就好了。超过 3 次才报 —— 真连不上就该
            -- 让用户看见, 无限重发等于把"平台连不上"藏起来
            p.hello_try = (p.hello_try or 0) + 1
            local bo = cfg.HELLO_BACKOFF_S[p.hello_try]
            if not bo then
                return pull_finish("fail", "hello 发送失败: " .. tostring(err))
            end
            p.deadline = os.time() + bo
            log.warn("iot", string.format("hello 发送失败(%d/3), %ds 后重发: %s",
                p.hello_try, bo, tostring(err)))
            return
        end
        p.hello_try = 0
        -- sniff 档的 hello 报的就是 sniff，平台明确不会推配置快照 —— 等也等不到，
        -- 干等一个 PULL_TIMEOUT_MS 只会让前端显示"平台未下发配置(超时)"这种假故障。
        -- hello 本身照发：它负责建/更新网关设备、回写 fw/hw/ip，与推不推配置无关。
        -- 这里也不回 U6：没有收到 D1，没有 msgId 可核销
        if onboard == "sniff" then
            return pull_finish("done", "sniff 模式平台不下发配置，寄存器表用本地嗅探结果")
        end
        p.state = "waiting"
        p.deadline = os.time() + math.floor(cfg.PULL_TIMEOUT_MS / 1000)
    elseif p.state == "waiting" then
        if S.pull_payload then
            local payload = S.pull_payload
            S.pull_payload = nil
            local r, err = pullcfg.parse(payload)
            if not r then
                log.warn("iot", "pull parse fail: " .. tostring(err) .. " body=" .. tostring(payload))
                return pull_finish("fail", tostring(err))
            end
            p.src = "pull"
            p.seen = os.time()
            p.msg_id = r.msg_id
            p.replied = false
            -- 空快照 = 平台侧没有配置(sniff 互斥守卫)。按成功收尾：不回执的话
            -- 平台每 1s 重推一次同一份空包, 前端还会看到一条假的失败提示
            if r.empty then
                p.result = nil
                p.msg = "平台未下发配置，本地嗅探自建生效"
                pcall(reply_config)
                return pull_finish("done", p.msg)
            end
            -- 用户要求：拉取成功即自动保存，不再等前端「保存配置」确认。
            -- 落盘失败（配置不合法/存不下）不当成功：平台会继续重推，
            -- 而设备留着的还是旧配置，此时报 fail 比假装成功好排查
            local aok, aerr = auto_apply(r)
            if not aok then
                return pull_finish("fail", "自动保存失败: " .. tostring(aerr))
            end
            -- 保存已生效 = 这套配置被现场认可，此刻回执 U6，平台据此停止重推
            pcall(reply_config)
            return pull_finish("done", "已自动保存生效" .. (#r.skipped > 0 and ("，忽略 " .. #r.skipped .. " 条") or ""), r)
        end
        if os.time() >= p.deadline then pull_finish("fail", "平台未下发配置(超时)") end
    end
end

-- 订阅清单变了就断开重刷。为什么必须放在这个循环里而不是只在 conack 算:
-- build_subs() 挂在 conack 上, 而切模式(set_manual 的 kick / 进 sniff 不
-- 调 iot)时设备是已经连着的, 不会自己重读一遍。而 ctrl 是"先切凭证档位
-- 再 poll.start()", set_manual 触发重连的那一刻 get_mode() 还是旧值
-- (它靠 poll/mon 的 is_running 推导), 连上来拿到的仍是旧清单。放这里每秒
-- 比一次, 一次 mode/凭证/SN 的错配都会被自动纠正, 不用给 ctrl 的每个
-- return 点补一句刷新
local function subs_same(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function refresh_subs()
    if not S.client or not S.connected then return end
    local want = build_subs()
    if subs_same(want, S.subs) then return end
    -- 先记账再断开: 让 on_mqtt 的 conack 分支和这里看到的是同一份诉求,
    -- 否则某一轮两边不一致会来回重连
    S.subs = want
    destroy_client()
    M.kick()
    log.info("iot", "subs changed by mode, reconnect: [" .. table.concat(want, " ") .. "]")
end

local function task_main()
    S.want_run = true
    while S.want_run do
        -- 拉取状态机要在未连接时也能跑(connecting 态就是等连接), 所以放分支外
        if pull_active() then pcall(pull_step) end
        if not S.connected then
            if net_ready() then
                local ok, err = try_connect()
                if not ok then
                    if err == "no sn" then
                        log.warn("iot", "no sn, skip")
                        if sys then sys.wait(10000) end
                    else
                        local is_oom = type(err) == "string" and err:lower():find("memory") ~= nil
                        local wait_s = is_oom and 30 or S.backoff
                        if is_oom then
                            -- 堆不足: 清帧缓存 + 强制 GC, 固定等 30s 再试。
                            -- mon.trim_reqs() 不能省: lastReqs 是 mon 的局部表,
                            -- collector.trim_cache() 碰不到它, 少了这句清了
                            -- 缓存照样 OOM, 只是白等 30s
                            collector.trim_cache()
                            mon.trim_reqs()
                            collectgarbage("collect")
                            local h1, h2 = heap_info()
                            log.warn("iot", "oom, trim+gc done, heap total=" .. tostring(h1) .. " used=" .. tostring(h2))
                        else
                            S.backoff = math.min(S.backoff * 2, 60)
                        end
                        S.last_err = err
                        wait_kickable(wait_s * 1000)
                    end
                end
            else
                wait_kickable(10000)
            end
        else
            -- cpu_percent 的忙碌占比: 每轮循环量一次干活耗时(不含 sys.wait),
            -- 攒到发 U3 时算成占比。os.clock() 在本工程里当秒级单调时钟用
            -- (见 bus/mon.lua 的配对超时), 不是 CPU 时间
            local t0 = os.clock()
            if S.recv_pending then
                local rp = S.recv_pending
                S.recv_pending = nil
                pcall(handle_downlink, rp.topic, rp.payload)
            end
            refresh_subs()
            local c = mqttcfg.load()
            local due = false
            if c.interval_s > 0 then
                due = (os.time() - S.last_pub) >= c.interval_s
            else
                due = S.dirty
            end
            if S.dirty then due = true end
            if due then publish() end
            -- U3 网关资源与 U4 同一节奏(interval_s), 两者互不相干
            if (os.time() - (S.res_at or 0)) >= c.interval_s then send_gw_res() end
            -- 把这一轮的干活耗时记进 busy, 区间长度记进 span。span 与 busy
            -- 必须同一轮清零, 否则占比会越算越小
            S.busy_s = (S.busy_s or 0) + (os.clock() - t0)
            S.span_s = (S.span_s or 0) + (os.clock() - t0) + 1.0
            -- U2 两帧, 各按自己的指纹发, 都不做定时兜底:
            --   元数据帧(不带 nodes): imei/iccid/信号/经纬度会变(csq 尤其), 所以
            --     按内容指纹变化即发; 平台收到只更新属性, 不会重建模型
            --   拓扑帧(带 nodes): 建子设备 + 绑定 + 物模型。签名没变就是子设备
            --     清单没变, 平台那边的档还在, 不需要重建 —— 实测(2026-10-08)留了
            --     个 60s 兜底重发, 平台一收到带 nodes 的 info/post 就重建模型并
            --     回推 config/get, 形成"我们发拓扑 → 平台推配置 → 我们再发拓扑"
            --     的闭环, 每 60s 一轮。兜底路径还不打日志, 现象是"sniff 档平台
            --     不断下发模型配置", 难查
            local msig = meta_sig()
            if msig and msig ~= S.meta_sig then
                local ok, e = send_meta()
                if ok then
                    S.meta_sig = msig
                    log.info("iot", "gw meta posted: " .. msig)
                else
                    log.info("iot", "gw meta skip: " .. tostring(e))
                end
            end
            -- detect 跑完之前不发拓扑: 这期间 serial 参数还是上一轮的默认值
            -- (9600), 发出去平台就按错波特率建一次模型, detect 完还得再重建 ——
            -- 白推一次配置, 白占一次 info/post
            local sig = nil
            if not mon.status().detecting then sig = topo_sig() end
            if sig and sig ~= S.topo_sig then
                local ok, e = send_topo()
                if ok then
                    S.topo_sig = sig
                    log.info("iot", "topology posted: " .. sig)
                else
                    log.info("iot", "topology skip: " .. tostring(e))
                end
            end
            if sys then sys.wait(1000) end
            -- hello 的两个时机: 连接后补发一次 + pollpull 档 30min 周期重发。
            -- 放在 sys.wait 之后，保证每轮循环只判一次、且不和本轮的上报挤在一起
            --
            -- ① 连接后补发。进模式那一刻 MQTT 往往还没连上(set_manual 刚触发
            --    断开重连)，ctrl 里那次 hello 是静默失败的。这里保证每个连接
            --    至少发一次，且【所有非 idle 档都要】—— 包括手动档：平台侧不
            --    预知这台设备，靠 hello + 后续的拓扑/数据帧 auto-provision
            --    补建档案，收不到 hello 平台那头完全看不到设备上线。
            --    hello_at == 0 是 reset_state 里"这个连接还没发过"的语义, 正好复用
            -- ② 只对 pollpull 档周期重发：那是唯一"在等平台下发配置"的档。sniff 档
            --    的 hello 发完就判完成，没有"未拿到配置"这个状态；手动档不等
            --    configSnapshot，重发只会无意义地刷新档案。
            --
            -- 平台收到 hello 会重推 ConfigSnapshot，由 recv_push 自动落盘 ——
            -- 不走拉取状态机，所以不影响前端正在显示的拉取结果，也不需要用户
            -- 再点一次「拉取配置」。这正是文档"未拿到配置前每 30min 重发"的用途：
            -- 平台侧档案被重置/白名单到期时，设备侧无从得知，只靠上电那一次 hello
            -- 会永久失联且没有任何报错
            if S.hello_at == 0 and get_mode() ~= "idle" and not pulling() then
                log.info("iot", "hello on connect, mode=" .. get_mode())
                pcall(send_hello)
            elseif S.hello_at and S.hello_at > 0 and get_mode() == "pollpull"
                and not pulling()
                and (os.time() - S.hello_at) >= cfg.HELLO_RE_S then
                log.info("iot", "hello re-send (30min), mode=pollpull")
                pcall(send_hello)
            end
        end
    end
end

function M.init()
    collector.on_update(function()
        S.dirty = true
    end)
    return true
end

function M.start()
    if S.want_run then
        log.warn("iot", "already started")
        return false
    end
    reset_state()
    S.want_run = true
    if sys then sys.taskInit(task_main) end
    log.info("iot", "started")
    return true
end

function M.is_running() return S.want_run end

function M.report_now()
    return publish()
end

function M.kick()
    destroy_client()
    S.backoff = 1
    S.kick_flag = true
end

function M.apply_cfg(c)
    local ok, err = mqttcfg.save(c)
    if not ok then return false, err end
    M.kick()
    return true
end

function M.status()
    local c = mqttcfg.load()
    -- 未建连时按当前档次兜底算一份, 与 try_connect 同源, 否则这几行在
    -- 建连前是空的, 而 CONACK 0x05 时现场最需要看的正是 clientId/user/pub/sub
    local prof = mqttcfg.profile(device_id())
    return {
        want_run = S.want_run,
        connected = S.connected,
        subscribed = S.subscribed,
        device_id = S.device_id,
        client_id = S.client_id or (c.client_id ~= "" and c.client_id or default_client_id(device_id())),
        user = S.user or ((prof and prof.user ~= "" and prof.user) or device_id()),
        pub = S.pub or (prof and prof.pub),
        sub = S.sub or (prof and prof.sub),
        keep_session = c.keep_session,
        manual_on = c.manual_on,
        host = c.host,
        port = c.port,
        interval_s = c.interval_s,
        qos = c.qos,
        published = S.published,
        failed = S.failed,
        replied = S.replied,
        subs = S.subs,
        backoff = S.backoff,
        dirty = S.dirty,
        last_pub = S.last_pub,
        last_err = S.last_err,
        reject_reason = S.reject_reason,
        -- 平台主动下发、刚落地的配置。挂在 5s 轮询的 R:STAT 上：
        -- R:PULLCFG 只在用户点「拉取配置」时才查，等不到这里的通知。
        -- push_n/push_err/push_seen 是"设备被平台改过"的事实记录，
        -- autosaved 让前端知道这次改动已经落盘，不用再提示去保存
        push_n = S.push_n,
        push_seen = S.pull.seen,
        push_err = S.push_err,
        autosaved = S.autosaved,
        autosave_at = S.autosave_at,
        autosave_regs = S.autosave_regs,
        sn = _G.get_device_sn and tostring(_G.get_device_sn()) or nil,
        heap = (function() local a, b = heap_info(); return { total = a, used = b } end)(),
    }
end

function M.net_state()
    local st = {}
    if not mobile then return st end
    local function g(k)
        local v = mobile[k]
        if type(v) == "function" then
            local ok, r = pcall(v)
            return ok and r or nil
        end
        return v
    end
    st.csq = g("csq")
    st.rsrp = g("rsrp")
    st.rsrq = g("rsrq")
    st.pci = g("pci")
    st.reg = g("status")
    st.imei = g("imei")
    st.iccid = g("iccid")
    if socket then
        local ok, r = pcall(socket.isReady)
        st.socket_ready = ok and r or nil
    end
    return st
end

reset_state()

return M
