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

-- 当前轮询引擎用的是哪个配置槽("poll"=手动 / "pull"=拉取)。
-- 平台推送落地时据此决定要不要立即生效: 跑手动档就只存 ds_pull 备着，
-- 不许把手配的寄存器表顶掉。问 poll 而不是问 ctrl 是为了不引入
-- ctrl -> mon/poll -> iot 这条环
local function poll_slot()
    local p = get_poll()
    return (p and p.slot()) or "poll"
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

local function alias_map()
    local ok, c = pcall(cfgstore.load_poll)
    if not ok or not c or not c.regs then return {} end
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

local function build_payload()
    local amap = alias_map()
    local parts = {}
    for k, d in pairs(collector.get_all_latest()) do
        local vs = jnum(d.value)
        if vs then
            parts[#parts + 1] = string.format('{"id":%s,"name":%s,"value":%s,"ts":%s}',
                jstr(k), jstr(amap[k] or k), vs, ms_of(d.ts))
        end
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function publish(force)
    if not S.client or not S.connected then return false end
    local payload = build_payload()
    if payload == "[]" then return false end
    local ok, err = pcall(function()
        S.client:publish(S.pub, payload, mqttcfg.load().qos)
    end)
    if ok then
        S.published = S.published + 1
        S.dirty = false
        S.last_pub = os.time()
        return true
    end
    S.failed = S.failed + 1
    log.warn("iot", "publish fail:", tostring(err))
    return false
end

-- conack 时的订阅清单（文档"订阅关系"），按 manual_on 分两套：
--
-- 自动档：订 4 条 gw 平台前缀 + S.sub。三条要点：
--   ① D1(/gw/config/get/{sn}) 必须无条件订上：它是"拉取配置"链路唯一的
--      入口。业务 sub_topic 虽默认同形，但用户改到别处时不能跟着丢，
--      否则 handle_downlink 永远等不到 configSnapshot。
--   ② function/get + property/set + property/get 是平台侧另外三类下行，
--      也走 gw 前缀，不订就收不到服务调用/属性设置/全量查询。
--      这三条已按"代码精简"写死成 core/config.lua 的平台常量，不再可配。
--   ③ 与 S.sub 同形的先去重再订，同一个 topic 订两遍纯属浪费。
--
-- 手动档：只订 S.sub 一条，上面 4 条一条都不订。
--   手动档接的是用户自己的 broker 和自己的 topic 命名，平台那套
--   /sys/thing/gw/{sn} 拼出来也没人往那儿发，订着纯属噪音 —— 界面
--   上"订阅Topic"列一堆自己没配过的东西，用户会以为手动配置没生效。
--   ⚠️ 代价：拉取配置在手动档必然超时，它的应答走 config/get，
--     而手动档不订这条。前端已在手动档把「拉取配置」按钮置灰。
--     曾只按"少订会静默失效"把 4 条无条件全订，结果就是上面那个误会
local function build_subs()
    local subs = {}
    local function add(t)
        if not t or t == "" then return end
        for _, x in ipairs(subs) do
            if x == t then return end
        end
        subs[#subs + 1] = t
    end
    local did = S.device_id
    if did and did ~= "" and not S.manual_on then
        add(string.format(cfg.PLATFORM_GET_TOPIC, did))
        -- 另外 3 条 gw 下行订阅，固定平台常量。少订一条 = 平台那类
        -- 下发永远收不到且无报错，所以这三行一条都不能删
        add(string.format(cfg.PLATFORM_FUNC_TOPIC, did))
        add(string.format(cfg.PLATFORM_PSET_TOPIC, did))
        add(string.format(cfg.PLATFORM_PGET_TOPIC, did))
    end
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

-- Lua 堆信息: 返回 total, used; 取不到返回 nil, nil
-- Air780EP 堆约 300KB, mqtt.create 需要连续块, 建连前打印便于定位 OOM
local function heap_info()
    if not rtos or type(rtos.meminfo) ~= "function" then return nil, nil end
    local ok, a, b = pcall(rtos.meminfo, "sys")
    if not ok or type(a) ~= "number" then return nil, nil end
    return a, b
end

local function net_ready()
    if not mobile then return true end
    local csq = mobile.csq
    if type(csq) == "function" then
        local ok, v = pcall(csq)
        csq = ok and v or nil
    end
    if type(csq) == "number" and csq == 0 then return false end
    return true
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
    -- 无 SN 时把 "unknown" 视作无 id: topic 含 {id} 会被拒, 不会把字面
    -- unknown 拼进 topic(与原工程一致)
    -- 凭证和 topic 按 manual_on 取: 手动档用前端填的, 自动档用 SN 用户名
    -- + 首页那份 MQTT凭证密码 + 默认模板(见 mqttcfg.profile)
    local prof, terr = mqttcfg.profile(did == "unknown" and nil or did)
    if not prof then return false, terr end
    S.pub, S.sub = prof.pub, prof.sub
    -- build_subs() 挂在 conack 回调里，拿不到这里的局部变量 c，而
    -- mqttcfg.load() 要读 fskv 解 JSON，不能在每个 topic 上重跑一遍。
    -- 所以档位顺手存进 S，和 pub/sub 同一处赋值
    S.manual_on = not not c.manual_on
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
    local okc, c = pcall(cfgstore.load_poll)
    local regs = okc and c and c.regs or {}
    -- 默认从机地址只读一次: 挂在循环里等于每条缺 slave 的下行都重读一次 fskv+JSON
    local dslave = (okc and c and c.slave) or cfg.SLAVE_ADDR
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
    local nok, nfail = 0, 0
    for _, it in ipairs(items) do
        local dkey = it.id or it.name or it.key or it.regName or it.reg_name
        local addr = dnum(it.addr or it.address or it.reg or it.register or it.offset)
        if not addr then addr = resolve_addr(dkey) end
        local slave = dnum(it.slave or it.dev or it.device or it.slaveId or it.slave_id)
        if not slave then slave = dslave end
        if it.values and type(it.values) == "table" and addr then
            local vals = {}
            for _, v in ipairs(it.values) do
                local n = dnum(v)
                if not n then n = 0 end
                vals[#vals + 1] = n
            end
            local okw = poll.enqueue_write({ slave = slave, addr = addr, values = vals })
            if okw then nok = nok + 1 else nfail = nfail + 1 end
        elseif addr then
            local v = dnum(it.value or it.val or it.data)
            if v then
                local okw = poll.enqueue_write({ slave = slave, addr = addr, value = v })
                if okw then nok = nok + 1 else nfail = nfail + 1 end
            else
                nfail = nfail + 1
                log.warn("iot", "write item bad value:", tostring(dkey))
            end
        else
            nfail = nfail + 1
            log.warn("iot", "write item unresolvable:", tostring(dkey))
        end
    end
    -- ok 只代表"入队成功"，不是"已发到总线"：enqueue_write 是异步的，
    -- 真正发送由 poll_task / worker 完成，结果看 R:STAT 的 write.done/wfail。
    -- 不能再写成 "downlink write: ok=N" —— 现场看到这句会以为写成功了，
    -- 而实际可能还压在队列里
    log.info("iot", string.format("downlink write: queued=%d rejected=%d", nok, nfail))
    return nok, nfail
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
    local did = S.device_id or device_id()
    if not did or did == "" then return true end
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
    local did = device_id()
    if not did or did == "" then return false, "无 SN" end
    local topic = string.format(cfg.PLATFORM_REPLY_TOPIC, did)
    local body = string.format(
        '{"msgId":%s,"code":200,"message":"config applied","status":"ok","appliedTs":%d}',
        jstr(p.msg_id), os.time())
    log.info("iot", "config/reply " .. topic .. " " .. body)
    local ok, err = pcall(function() S.client:publish(topic, body, 1) end)
    if not ok then return false, tostring(err) end
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
local function recv_push(t)
    local r, err = pullcfg.parse_snap(t, t.configSnapshot)
    if not r then
        S.push_err = tostring(err)
        log.warn("iot", "push parse fail: " .. tostring(err))
        return false
    end
    S.push_err = nil
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
            log.info("iot", string.format("pullcfg recv topic=%s len=%d", topic, #tostring(payload)))
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
        recv_push(t)
        return
    end
    local cmd = t.cmd and t.cmd:upper() or nil
    if cmd == "REPORT" or cmd == "READALL" then
        S.dirty = true
        return
    end
    if cmd == "WRITE" and type(t.items) == "table" then
        downlink_write(t.items)
        return
    end
    if t[1] and type(t[1]) == "table" then
        downlink_write(t)
        return
    end
    if t.items and type(t.items) == "table" then
        downlink_write(t.items)
        return
    end
    if t.value or t.values or t.val or t.data then
        downlink_write({ t })
        return
    end
    -- 走到这里说明报文形状一个都不认识。以前是静默 return，平台以为发了、
    -- 设备什么都没干、日志一片空白 —— 现场只能靠猜。至少把收到的原文打出来
    log.warn("iot", "downlink unrecognized, no action: " .. tostring(payload))
end

-- 平台配置拉取状态机。
-- W:PULLCFG 只置状态并立即应答; 握手跑在 task_main 协程里(那里才能 sys.wait)。
local function pull_active() return pulling() end

-- 不要求 MQTT 已连上: 只要配好服务器地址/端口, 设备自己去连, 连上再握手。
-- 这是新设备首次使用的正常顺序(先配 MQTT, 再拉配置)。
-- 切换 MQTT 手动/自动档。由 ctrl.switch_mode 在切 485 模式时调用:
--   poll(手动配置)    -> true   只订用户自己填的 topic
--   poll(拉取配置)    -> false  订平台 4 条, 否则 hello 发出去没人应答
-- 手动/自动没有混搭场景(要么全手配, 要么全平台拉), 所以档位直接跟模式走。
--
-- 为什么要 destroy+kick: S.manual_on 是在 try_connect() 里读的, 订阅清单
-- build_subs() 挂在 conack 上, 已连接的 client 不会自己重读一遍。不断开
-- 重连的话, 从拉取档切回手动档后设备还订着平台 topic, 看起来像"手动配置
-- 没生效"。断开重连只是丢一次心跳周期, collector 的数据和寄存器表不动
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
    S.manual_on = on
    destroy_client()
    M.kick()
    log.info("iot", "mqtt manual_on ->", tostring(on))
    return true
end

function M.pull_start()
    if pull_active() then return false, "正在拉取中" end
    if not get_topic() then return false, "无 SN" end
    local c = mqttcfg.load()
    if not c.host or c.host == "" then return false, "请先配置 MQTT 服务器地址" end
    if not c.port or c.port < 1 or c.port > 65535 then return false, "请先配置 MQTT 端口" end
    S.pull = {
        state = "connecting", msg = "", result = nil,
        deadline = os.time() + math.floor(cfg.PULL_CONNECT_MS / 1000),
        msg_id = nil, replied = false,
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
        -- 只带发布/订阅两个 topic 成品给前端回显（自动模式填输入框）。
        -- hello/func/pset/pget 4 条已不可配，前端也没有对应输入框
        local t2 = pullcfg.topics(device_id())
        r.mqtt = {
            pub = t2 and t2.pub, sub = t2 and t2.sub,
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
            p.state = "helloing"
        elseif os.time() >= p.deadline then
            local why = S.reject_reason or S.last_err or "超时"
            pull_finish("fail", "MQTT 连接失败: " .. tostring(why))
        end
    elseif p.state == "helloing" then
        local did = device_id()
        -- hello topic 走固定平台常量(不再可配); 无 SN 返回 nil,
        -- 这时候发出去就是把不带 SN 的 topic 发给平台
        local topic = mqttcfg.resolve_hello(did)
        if not topic then return pull_finish("fail", "hello topic 解析失败(无 SN)") end
        -- topicFormat/onboardingMode 是文档 U1 的"自述字段"，缺了平台可能
        -- 按旧版格式猜下行 topic 导致指令全丢且无报错。本链路就是找平台要
        -- 配置的那一路，固定报 v3/platform。
        -- 不报 sniff：文档明确"平台见 sniff 跳过推送配置"，Pull 会直接废。
        local body = string.format(
            '{"vendor":%s,"model":%s,"fwVersion":%s,"deviceId":%s,"topicFormat":"v3","onboardingMode":"platform"}',
            jstr(cfg.PLATFORM_VENDOR), jstr(cfg.PLATFORM_MODEL), jstr(_G.VERSION or "0.0.0"), jstr(imei()))
        log.info("iot", string.format("pullcfg hello topic=%s sn=%s imei=%s body=%s",
            topic, tostring(did), imei(), body))
        local ok, err = pcall(function() S.client:publish(topic, body, 1) end)
        if not ok then return pull_finish("fail", "hello 发送失败: " .. tostring(err)) end
        p.state = "waiting"
        p.deadline = os.time() + math.floor(cfg.PULL_TIMEOUT_MS / 1000)
    elseif p.state == "waiting" then
        if S.pull_payload then
            local payload = S.pull_payload
            S.pull_payload = nil
            local r, err = pullcfg.parse(payload)
            if not r then return pull_finish("fail", tostring(err)) end
            p.src = "pull"
            p.seen = os.time()
            p.msg_id = r.msg_id
            p.replied = false
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
            if S.recv_pending then
                local rp = S.recv_pending
                S.recv_pending = nil
                pcall(handle_downlink, rp.topic, rp.payload)
            end
            local c = mqttcfg.load()
            local due = false
            if c.interval_s > 0 then
                due = (os.time() - S.last_pub) >= c.interval_s
            else
                due = S.dirty
            end
            if S.dirty then due = true end
            if due then publish(false) end
            if sys then sys.wait(1000) end
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
    return publish(true)
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
    -- 未建连时按当前档次兜底算一份, 与 try_connect 同源, 否则这两行在
    -- 建连前是空的, 而 CONACK 0x05 时现场最需要看的正是这两个值
    local prof = mqttcfg.profile(device_id())
    return {
        want_run = S.want_run,
        connected = S.connected,
        subscribed = S.subscribed,
        device_id = S.device_id,
        client_id = S.client_id or (c.client_id ~= "" and c.client_id or default_client_id(device_id())),
        user = S.user or ((prof and prof.user ~= "" and prof.user) or device_id()),
        keep_session = c.keep_session,
        manual_on = c.manual_on,
        pub = S.pub or (prof and prof.pub),
        sub = S.sub or (prof and prof.sub),
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
