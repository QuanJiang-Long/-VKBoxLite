local util = require "util"
local cfg = require "core/config"
local log = util.log()

local sys = util.get("sys")
local json = util.try("json")
local mqtt = util.try("mqtt")
local rtos = util.try("rtos")
local mobile = util.try("mobile")
local socket = util.try("socket")
-- 兼容老固件: lbsLoc2.lua 文件加载时会自动启动 sys.taskInit (line 124-136),
-- 直接用全局 _G.sys. base 24.10 bsp V2002 上 _G.sys 未自动注入 → sys=nil 崩
-- (lbsLoc2.lua:148 'attempt to index a nil value (field "sys")'). 在这里强制
-- 把 sys / socket / mobile 注册到 _G, 让 lbsLoc2 自带的协程能跑
for _, lib in ipairs({"sys", "socket", "mobile", "json", "bit", "zbuff", "pack"}) do
    local m = util.try(lib)
    if m and _G[lib] == nil then _G[lib] = m end
end
-- lbsLoc2 = 合宙免费 LBS 基站定位, 默认扩展库, 单基站 1.5km 精度,
-- 频率被卡死(官方口径 4h-2min), 工程上 30min 一次足够.
-- 取不到就 nil, 整段 LBS 流程直接跳过
local lbsLoc2 = util.try("lbsLoc2")
if lbsLoc2 then
    log.info("iot", "lbs lib: loaded, version=", lbsLoc2.version and lbsLoc2.version() or "?")
else
    -- 区分"库没烧录" vs "库坏了": require 失败的错误消息能告诉我们
    local ok, err = pcall(require, "lbsLoc2")
    log.info("iot", "lbs lib: MISSING, require:", ok, err)
end

local mqttcfg = require "iot/mqttcfg"
local pubsched = require "iot/pubsched"   -- 12-fix-4: 统一上报调度(节奏都在那管)
local collector = require "data/collector"
local cfgstore = require "cfg"
local mon = require "bus/mon"
local MqttUtil = require "util/mqtt_util"
-- ⚠️ 12-fix-11 (2026-10-29): 拓扑的 JSON 拼装挪到独立模块。
--   拓扑是本机最大的一块连续内存需求(现场就是死在这上面), 而且平台的
--   物模型契约一个字段都不能多不能少 —— 独立成模块才能写模拟器单测盯着
--   它(tests/lua/test_topo.lua), 不用烧到现场才发现拼错了。
local topo = require "iot/topo"

-- ⚠️ 12-fix-8 (2026-10-28): pullcfg 改成【惰性 require】。
--   sniff 档平台根本不下发配置(日志: "pullcfg done sniff 模式平台不下发配置"),
--   这个模块在 sniff 档一次都用不到, 却无条件占着 ~7.5KB 常驻堆。
--   现场实测: Lua 堆 307192 字节, idle 基线就 186KB(其中绝大部分是代码),
--   每 KB 都要命 —— 池用满 98.6% 时连协程栈都分配不出来 -> VM exit 重启。
--   只在 platform/pullpull 档(平台真的要下发配置时)才加载。
local pullcfg_mod
local function get_pullcfg()
    if pullcfg_mod == nil then
        local ok, p = pcall(require, "iot/pullcfg")
        pullcfg_mod = (ok and p) or false
    end
    return pullcfg_mod or nil
end

-- ⚠️ 12-fix-7 (2026-10-28): U4 降级分包的每包点数。
--   整包(77 个点 ≈ 6KB)拼不出来时(碎片化), 按这个数拆成 ~2KB 的小包,
--   同一个 topic 分几条发。2KB 在碎片池里比 6KB 好找得多。
local U4_CHUNK_PTS = 25

-- ⚠️ 12-fix-7: 大块分配前的水位线。超过它就先回收一次再拼大字符串。
--   现场实测: 水位 222KB 时 6KB(甚至 1.2KB)的连续块就申请不到了;
--   12-fix-5 那条保险丝的阈值是 240KB —— 比失效点还高, 等于没设防。
--   这里定 200KB: 低于现场观察到的 222KB 失效水位, 又高于 idle 基线(~190KB),
--   所以正常 sniff 基本不触发, 真要拼大包时一定触发。
local BIG_ALLOC_KB = 200

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
-- 走惰性 require: 依赖图已确认无环(全工程没有任何文件 require 'iot/iot'),
-- 但顶层 require 会把 iot 的加载时机提前到 main.lua 初始化序列里, 保持
-- 惰性最稳。拿不到就当 idle -- 宁可少订也不能给未接任务的状态乱订
-- ⚠️ 上面那行注释里的 'iot/iot' 用单引号: dep_graph.py 认的是双引号,
--   双引号会被当成真的 require, 把 iot.lua 判成自依赖的循环依赖。
local ctrl_mod
local function get_mode()
    if ctrl_mod == nil then
        local ok, p = pcall(require, "bus/ctrl")
        ctrl_mod = ok and p or false
    end
    return (ctrl_mod and ctrl_mod.get_mode()) or "idle"
end

-- 当前轮询引擎用的是哪个配置槽("poll"=手动/manual / "pull"=拉取/pollpull)。
-- 平台推送落地时据此决定要不要立即生效: 跑手动档就只存 ds_pull 备着，
-- 不许把手配的寄存器表顶掉。问 poll 而不是问 ctrl 是为了不引入
-- ctrl -> mon/poll -> iot 这条环
local function poll_slot()
    -- 37-fix: 改用 get_mode() (ctrl 记下的 S.cur) 而不是 p.cur_slot().
    --   切 platform 档时 ctrl.switch_mode 会调 poll.stop() (36-fix 后 stop
    --   清空 regs/lastCfg, 但不重置 curSlot), ds_pull 空时又不起 poll,
    --   curSlot 残留 "poll" 默认值. 这种状态下 auto_apply 走 if poll_slot()
    --   == "pull" 判断, 看到的是 "poll" 就跳过 apply_cfg, 导致 poll.regs
    --   永远空, R:REG 返回 {} (用户实测: 拉取到了 4 条, ds_pull 有, R:REG 没).
    --   改用 ctrl 记下的 mode: platform -> "pull", manual -> "poll", 其它 nil.
    --   poll.cur_slot() 只表示 poll 模块当前在跑哪个槽, 不等价于"用户想用哪槽"
    local m = get_mode()
    if m == "platform" then return "pull"
    elseif m == "manual" then return "poll"
    else return nil end
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

-- 单元测试用: iot/pullcfg 有没有被拉进来 (12-fix-8)。
-- sniff 档平台不下发配置, 这个模块一次都用不到, 白占 ~7.5KB 常驻堆。
function M.pullcfg_loaded()
    return pullcfg_mod ~= nil and pullcfg_mod ~= false
end

local S = {}

-- 大块分配前按水位回收一次。
-- ⚠️ 完整回收有毫秒级停顿, 所以【只在超水位时做】, 而且放在 iot 的
--   巡检/发布路径上(不在 UART 收帧协程里 —— 那会让环形缓冲溢出丢帧)。
--   现场帧率 52 帧/秒 ≈ 每 19ms 一帧, 几毫秒的停顿是安全的。
--
-- ⚠️ 12-fix-8 (2026-10-28): 现场证明【它救不了大块】。日志:
--     18:27:38.723 reclaim before big alloc: lua=214.4KB -> collected
--     18:27:38.768 topo_sig failed, skip this round: iot.lua:629:
--                  not enough memory for buffer allocation
--   收了垃圾 45ms 后照样切不出 6.4KB 连续块 —— LuatOS 的分配器不合并相邻
--   空闲块, GC 只是把垃圾块还回池子, 拼不出连续大块。
--   所以它现在的定位是"顺带把垃圾清掉, 让中等大小的分配(几百字节到
--   几KB)有货可拿", 不是"腾大块"。真正的解法是少占常驻(12-fix-8 的
--   poll/pullcfg 惰性 require)和把水位判据改对(保险丝 240 → 200)。
local function reclaim_if_high()
    local kb = collectgarbage("count")
    if kb > BIG_ALLOC_KB then
        collectgarbage("collect")
        S.reclaim_n = (S.reclaim_n or 0) + 1
        log.warn("iot", string.format("reclaim before big alloc: lua=%.1fKB -> collected", kb))
        return true
    end
    return false
end


local function reset_state()
    S = {
        want_run = false, connected = false, subscribed = false,
        client = nil, dirty = false, backoff = 1,
        published = 0, failed = 0, replied = 0, kick_flag = false,
        -- 12-fix-7: build_fail = 大包拼不出来(U4/拓扑)的次数。
        --   现场那次 U4 停发, 而 pub=60/0 完全看不出来(失败走 pcall 跳过,
        --   不计 failed) —— 这个数进 census, 不为 0 就是"上报已经瘸了"。
        build_fail = 0, reclaim_n = 0,
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
        -- 12-fix-2: 上次【重建拓扑】的时刻 (os.clock, 秒级单调)。拓扑重建
        --   按 cfg.TOPO_REBUILD_MS 节流, 降 build_nodes 的分配速率。
        --   置 -1e9 = 还没重建过, 第一轮立刻重建(不等闸门)。
        --   ⚠️ 12-fix-4: 这个字段现在只留作观测(真正的闸门在 pubsched),
        --     TOPO_REBUILD_MS 从 5s 改成 30s。
        topo_at = -1e9,
        -- 12-fix-4: 上次打【结构普查】的时刻 (os.clock, 秒)。每 30 秒一行,
        --   把各常驻结构的条目数 + 堆水位一次列出来 —— 现场一崩, 最后那行
        --   census 就直接指出是哪个数字在涨(不用再猜)。
        census_at = -1e9,
        -- 12-fix-5: 堆水位保险丝的状态。上次强制回收的时刻(os.clock, 秒)
        --   + 累计触发次数(给 census 报)。见 task_main 里的 gc 保险丝。
        gc_at = -1e9, gc_trig = 0,
        -- 上一次普查时的累计计数(帧/点), 用来算帧率 fps / 点率 push
        census_prev = nil,
        busy_s = 0, span_s = 0,
        -- hello_at 是【连接生命周期内最后一次 hello 成功发送】的时间(OS time),
        -- 不是上电时间 —— task_main 靠它算 pollpull 档 30min 重发。置 0 表示
        -- 这个连接还没发过 hello, 重发计时不起跑(否则开机就白发一次)
        hello_at = 0,
        -- LBS 定位结果: {lat, lng} + 取到时间(OS time). 没取到 = nil
        lbs = nil, lbs_at = 0,
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

-- ⚠️ 12-fix-3 (2026-10-28): c 可选 —— 传进来就复用, 不要再 active_cfg()。
--   build_items() 一次调用里原来要 active_cfg() 两次(自己一次 + alias_map()
--   里面一次), 每次都是把整份配置从 fskv 反序列化一遍。现在只取一次。
--
-- ⚠️ 12-fix-9 (2026-10-29): 结果【缓存】, 键 = 配置版本 + 槽位。
--   原来每次都新建这张 name->alias 映射(最多 128 条 ≈ 8KB 垃圾/次),
--   而 attach_names(每次 R:INFER) 和 build_items(每次发布)都要它。
--   配置一天可能只改一次(用户手配 / 平台下发), 写盘时版本号涨 → 缓存失效;
--   槽位(poll/pull)也算进键: 切档读的是另一个配置槽, 别拿串。
local alias_map_cache = nil
local alias_map_key = nil
local function alias_map(c)
    local key = tostring(cfgstore.version()) .. ":" .. tostring(poll_slot())
    if alias_map_cache and alias_map_key == key then return alias_map_cache end
    c = c or active_cfg()
    local m = {}
    if c and c.regs then
        for _, r in ipairs(c.regs) do m[r.name] = r.alias or r.name end
    end
    alias_map_cache = m
    alias_map_key = key
    return m
end

-- 推断结果补 name/id: 与上报同一套映射(用户别名表优先, 再 cfg alias_map)
--
-- ⚠️ 12-fix-9 (2026-10-29): 【不再复制行】, 名字表挂到【顶层】。
--   12-fix-6 的做法是"复制一份再挂名字": 每行复制一张 10 字段表(第 9/10 个
--   字段 → Lua 哈希槽 8 涨到 16 → 203 → 363 字节/行)。现场 64 个地址就是:
--     ① 64 张 10 字段表 = 23KB
--     ② 再拼 64 个 id 串 + 64 个 name 串      ≈ 28KB 一次性垃圾
--   加上 alias_map/alias_map 两张映射表(另 ~23KB), 一次 R:INFER 制造
--   ~65KB 短命垃圾。现场(09:14~09:19, 池 294448/307192 = 95.8%)就是这么
--   被打碎的: "alloc 8147 failed" → json encode out of memory →
--   RET:INFER={} → 系统池也见底 → "E/uart system is out of memory!!!" →
--   整机卡死(09:19:03)。
--   现在:
--     · 行【一个字段都不加】(还是 8 字段 8 槽 = 203 字节/行), 常驻不变
--     · 名字表只在【跟默认值不一样】时才有条目(用户改过名的那些, 通常几个):
--         {"regs":[...8 字段的行...], "names":{"reg230":{"id":"x","name":"y"}}}
--     · 零复制, 每行还少两个字段(应答再小 ~30 字节/行)
--   ⚠️ 前端要跟着改: 显示名字时先查 names['reg'+addr], 没有就用 reg<addr>
--      (见 frontend/renderer/app.js 的 renderInfer)。
function M.attach_names(inf)
    if type(inf) ~= "table" or type(inf.regs) ~= "table" then return inf end
    local amap = alias_map()
    local smap = cfgstore.alias_map()   -- sniff 别名表 (用户起的名字)
    local names = {}
    for _, a in ipairs(inf.regs) do
        local k = "reg" .. tostring(a.addr or "")
        local sa = smap[k]
        local id, name
        if sa then
            local sid = sa.id or ""
            local snm = sa.name or ""
            id = (sid ~= "") and sid or k
            name = (snm ~= "") and snm or id
        else
            id = k
            name = amap[k] or k   -- 没配 alias 时 = 本身, 与 U4 上报完全一致
        end
        -- 只有跟默认值不一样才登记 —— 默认值前端自己就能补(reg<addr>)
        if id ~= k or name ~= k then
            names[k] = { id = id, name = name }
        end
    end
    -- 顶层字段(regs/slaves/ignored/stat/total/off/n/pages)原样带过去
    local out = {}
    for k, v in pairs(inf) do out[k] = v end
    out.regs = inf.regs   -- 同一个数组, 不复制
    out.names = names
    return out
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
        local v = MqttUtil.jnum(it.value) or "null"
        out[#out + 1] = ts
            and string.format('{"id":%s,"value":%s,"ts":%s}', MqttUtil.jstr(it.id or "unknown"), v, ts)
            or string.format('{"id":%s,"value":%s}', MqttUtil.jstr(it.id or "unknown"), v)
    end
    return "[" .. table.concat(out, ",") .. "]"
end

-- csq 为 0 即未注册。全项目只此一处定义 —— send_meta 的 netRegister 字段和
-- net_ready 的建连判据原本是两套同形算法, 口径一旦漂移, 平台看到的注册状态
-- 和设备实际能否建连就对不上, 且两边都不报错
local function net_registered(csq)
    return not (type(csq) == "number" and csq == 0)
end

-- ⚠️ 12-fix-7 (2026-10-28): 把一个从机的点表切成若干块(降级分包用)。
--   切法: 每块 chunk 个点, 块内保持原顺序(平台按 id 覆盖, 顺序不影响)。
--   ⚠️ 只在整包分配失败时用 —— 正常路径一个字节都不变。
local function split_points(pts, chunk)
    local out = {}
    local n = #pts
    if n == 0 then return out end
    chunk = chunk or U4_CHUNK_PTS
    if chunk < 1 then chunk = 1 end
    local i = 1
    while i <= n do
        local last = math.min(i + chunk - 1, n)
        local part = {}
        for j = i, last do part[#part + 1] = pts[j] end
        out[#out + 1] = part
        i = last + 1
    end
    return out
end
-- 单测钩子(tests/lua/test_u4_split.lua 用; 设备逻辑不依赖)
M._test_split_points = split_points

-- U4 按子设备逐条上报: /sys/thing/node/property/post/{gwSn}-{n}。
-- n = 子设备序号, 按从机地址升序排(同一份配置只有一个 slave, 所以轮询档
-- 恒为 1; sniff 档才可能有多个从机)。从机地址从 key 里取:
--   sniff 的 key 是 "reg{addr}"(见 bus/mon.lua push_rsp_value, 不带 s<slave>_ 前缀)
--   轮询的 key 是配置里的 name 或 "r{addr}"(见 bus/poll.lua), 不带从机号
--   —— 一份轮询配置只有一个 slave(cfg.normalize_poll), 直接取那份的
-- 少了 -{n} 这个后缀, 平台无法把数据归属到子设备, 上报等于白发
local function build_items()
    -- ⚠️ 12-fix-3: 先取一次配置, 下面 alias_map(c) 复用它, 别再各自去
    --   active_cfg() —— 那等于把整份配置反序列化两遍。
    local c = active_cfg()
    local amap = alias_map(c)
    local cfg_slave = c and c.slave or nil
    -- 过滤: 只发当前 mode 应该有的 alias, 避免切档残留数据被当成当前数据误发
    -- 例: sniff 累积的 reg<addr> 不该在 pollpull 模式上报
    --
    -- sniff 模式特殊: 旁听推断的 alias 跟 cfg.regs 不对应, 全发 (sniff 自己
    -- 在推断寄存器表, alias 是 reg<addr> 格式, 不在 cfg.regs.name 里)
    --
    -- pollpull/poll/manual 模式: 只发 cfg.regs.name 里的 alias (cfg.regs 是真表)
    -- 平台刚下发时 cfg.regs 是空, build_items 返回空, 不发
    local sniff_mode = get_mode() == "sniff"
    local allowed
    if not sniff_mode and c and c.regs then
        allowed = {}
        for _, r in ipairs(c.regs) do allowed[r.name] = true end
    end
    local by_slave, order = {}, {}
    -- sniff 别名表: 用户在推断表里给 reg<addr> 起的名字, 优先于一切
    local smap = cfgstore.alias_map()
    for k, d in pairs(collector.get_all_latest()) do
        local vs = MqttUtil.jnum(d.value)
        if vs then
            -- reg<addr> 格式 (去掉 s<slave>_ 前缀, 单从机场景够用,
            -- 多从机同地址会冲突, 但 sniff 模式是单从机视角)
            local slave = tonumber(k:match("^reg%d+$") and "1") or cfg_slave
            if slave and (sniff_mode or allowed == nil or allowed[k]) then
                if not by_slave[slave] then
                    by_slave[slave] = {}
                    order[#order + 1] = slave
                end
                -- id: 别名表配了用别名, 否则用键本身; name: 名字 > 别名 id > cfg alias > 键
                local sa = smap[k]
                local pid = (sa and sa.id ~= "" and sa.id) or k
                local pname = (sa and sa.name ~= "" and sa.name)
                    or (sa and sa.id ~= "" and sa.id)
                    or amap[k] or k
                by_slave[slave][#by_slave[slave] + 1] =
                    string.format('{"id":%s,"name":%s,"value":%s,"ts":%s}',
                        MqttUtil.jstr(pid), MqttUtil.jstr(pname), vs, MqttUtil.ms_of(d.ts))
            end
        end
    end
    table.sort(order)
    local items = {}
    for n, slave in ipairs(order) do
        local pts = by_slave[slave]
        -- ⚠️ 12-fix-7 (2026-10-28): 整包拼不出来时【降级分包】。
        --   现场(41 分钟): lua=222KB/300KB, table.concat 一次要 ~6KB 连续块
        --   -> "not enough memory for buffer allocation" -> U4 停发;
        --   同期拓扑那条只要 1.2KB 也失败 —— 说明不是"包太大", 是池子碎了。
        --   先试整包(正常路径一个字节不变, 平台行为不变), 失败才按块拆,
        --   同一个 topic 分几条发。总发不出去和只发一半, 当然是后者好。
        local ok, body = pcall(function()
            return "[" .. table.concat(pts, ",") .. "]"
        end)
        if ok then
            items[#items + 1] = { idx = n, slave = slave, body = body }
        else
            local chunks = 0
            for _, part in ipairs(split_points(pts, U4_CHUNK_PTS)) do
                local cok, cbody = pcall(function()
                    return "[" .. table.concat(part, ",") .. "]"
                end)
                if cok then
                    items[#items + 1] = { idx = n, slave = slave, body = cbody }
                    chunks = chunks + 1
                end
            end
            S.build_fail = (S.build_fail or 0) + 1
            log.warn("iot", "u4 body alloc failed, split " .. #pts .. " points into "
                .. chunks .. " chunks")
        end
    end
    return items
end

-- 识别闸门 (2026-10): sniff 档识别未成功(识别中/无结果/兜底失败)时不上报。
-- 详见 lua/README.md「识别未成功前不上报」
local function pub_blocked()
    if get_mode() ~= "sniff" then return false end
    local st = mon.status()
    if st.detecting then return true end
    local d = st.detected
    if not d or d.baud == nil then return true end
    if d.fallback then return true end
    return false
end

-- U4 子设备数据上报。topic = profile 出的 base, 是否加 -{n} 后缀看档位:
--   自动档 = PLATFORM_PUB_TOPIC 固定常量, 按 V3 契约拼 -{n}
--   手动档 = 用户填的 pub_topic, 原样用不加后缀
-- -{n} 是平台认子设备用的: 少了平台认不出数据归属哪个子设备, 上报等于白发。
-- 但手动档连的是用户自己的 broker、用用户自己的命名, 用户也按原样订阅 ——
-- 加个 -1 之后平台那头什么都收不到(实测踩过), 所以手动档不加
local function publish()
    if not S.client or not S.connected then return false end
    -- 识别未成功前不上报 (见 pub_blocked)
    if pub_blocked() then return false end
    -- idle 模式短路: collector.dataCache 可能残留之前切档前的数据, idle 不该发
    -- (跟 should_pub_platform 一样, idle 不上送任何平台数据, 包括 U4)
    if get_mode() == "idle" then return false end
    -- pcall: build_items 里拼上报 body 也是大字符串, 一次分配失败不该掀掉
    -- 整个 task (2026-10, 与 topo_sig 同一个道理)
    -- ⚠️ 12-fix-7: 拼之前先按水位回收一次 —— 现场 41 分钟时 77 个点的
    --   ~6KB 整包申请不到, U4 直接停发(日志里 pub=60/0 看不出来)。
    reclaim_if_high()
    local ok, items = pcall(build_items)
    if not ok then
        S.build_fail = (S.build_fail or 0) + 1
        log.warn("iot", "build_items failed, skip publish: " .. tostring(items))
        return false
    end
    if #items == 0 then return false end
    local base = S.pub or ""
    if base == "" then return false end
    -- ⚠️ 12-fix-4: mqttcfg.load() 原来在下面那个循环里(每从机一次),
    --   而它每次都要 fskv.get + json.decode 整份 MQTT 配置。提到循环外。
    local mc = mqttcfg.load()
    local manual = mc.manual_on
    local qos = mc.qos
    local any = false
    for _, it in ipairs(items) do
        local topic = manual and base or (base .. "-" .. it.idx)
        local ok, err = pcall(function()
            S.client:publish(topic, it.body, qos)
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
        -- 12-fix-4: 脏标记交给 pubsched 统一管(这里只留个镜像给 R:STAT 看)
        pubsched.sent("prop")
        S.dirty = false
        S.last_pub = os.time()
    end
    return any
end

-- ===== 结构普查 (12-fix-4, 2026-10-28) =====
--
-- 为什么要有: 2026-10-28 现场崩了两次, 光看 mem 水位看不出"是哪个结构在涨"
-- (used 一直在 260~277KB 之间晃, 活对象和垃圾混在一起分不清)。
-- 这一行把关键结构的条目数 + 堆水位一次列出来, 现场一崩, 最后那行
-- census 就直接指出是谁在长。
--
-- 成本: 一次 string.format + 一次 collectgarbage("count"), 30 秒一次。
--   ⚠️ 绝不能用 collectgarbage("collect") —— 那是完整回收, 有毫秒级暂停,
--      放热路径上有让 UART 环形缓冲溢出的风险。这里只【读】count。
--
-- ⚠️ 12-fix-5 (2026-10-28): 单位写错了, 这一行一直是瞎的!
--   原来打的是 collectgarbage("count") / 1024, 可 LuatOS 这个接口【返回的
--   就是 KB】(不是标准 Lua 的字节) —— 于是每一行都打成 "lua=0.2KB",
--   现场看着像"堆才用了 0.2KB", 白白误导了两轮排查。设备上
--   R:STAT 的 lua_kb 字段(直接取 count)显示的是 190~231, 才是真水位。
--   现在 census 和 R:STAT 用同一个口径, 两边数字能对得上。
--
-- 追加的两个字段(fps / push)是为了直接看出【垃圾产生速率】:
--   现场 48 帧/秒 × 每帧 ~1.2KB 垃圾 ≈ 58KB/秒, 300KB 的堆几分钟就碎。
--   fps/push 一升高, 就说明分配量又上去了。
local function census()
    local cs = collector.stats()
    local ms = mon.status()
    local ps = pubsched.status()
    -- 帧率/点率: 跟上一次普查比(上次的时间戳存在 census_prev.clock 里)
    local fps, push = 0, 0
    local prev = S.census_prev
    local now = os.clock()
    if prev and prev.clock then
        local dt = now - prev.clock
        if dt > 0 then
            fps = math.floor(((cs.frames or 0) - (prev.frames or 0)) / dt)
            push = math.floor(((cs.pushed or 0) - (prev.pushed or 0)) / dt)
        end
    end
    S.census_prev = { frames = cs.frames or 0, pushed = cs.pushed or 0, clock = now }
    log.info("iot", string.format(
        "census lua=%.1fKB points=%d frames=%d aliases=%d rows=%d pub=%d/%d meta=%d topo=%d blk=%d fps=%d push=%d gc=%d bfail=%d rc=%d err=%d aerr=%d",
        collectgarbage("count"),
        cs.points or 0, cs.frames or 0,
        ms.hist_aliases or 0, ms.infer_rows or 0,
        S.published or 0, S.failed or 0,
        (ps.meta and ps.meta.sent) or 0, (ps.topo and ps.topo.sent) or 0,
        ((ps.prop and ps.prop.blocked) or 0) + ((ps.meta and ps.meta.blocked) or 0),
        fps, push, S.gc_trig or 0,
        -- 12-fix-7: 大包拼不出来(U4/拓扑)的次数。现场 41 分钟那次 U4
        --   整整停发, 而 pub=60/0 看不出来(失败走 pcall 跳过, 不计 failed)
        --   —— 这个数不为 0 就是"上报已经瘸了"。
        S.build_fail or 0,
        -- rc = 大包分配前主动回收的次数(水位 >200KB 才回收)
        S.reclaim_n or 0,
        -- 12-fix-8: err = 旁听解析出错次数(含丢帧), aerr = 其中"堆分配失败"
        --   导致的丢帧(新加的 pcall 兜底记的)。aerr 不为 0 = 堆又在吃紧,
        --   设备没崩但已经开始丢帧了 —— 这是崩溃前的先行指标。
        ms.errs or 0, ms.alloc_err or 0))
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

-- Lua 堆真实用量 (KB)。rtos.meminfo("sys") 读的是【系统内存】不是 Lua 堆,
-- 拿它判断"还剩多少空间"是不准的 —— LuatOS 的 Lua 堆是固定内存池 + 独立
-- big block, 大字符串要的是【连续大块】, 总量够也未必拿得到(碎片化)。
-- collectgarbage("count") 只读不触发回收, 放在上报路径上不影响实时性。
--
-- ⚠️ 绝对不要在这里用 collectgarbage("collect"): 那是真回收, 有毫秒级暂停,
--   放在热路径上有让 UART 环形缓冲溢出的风险。本文件里 collect("collect")
--   只出现在 destroy_client() 和 OOM 兜底两处, 都不在 UART 路径上。
--
-- ⚠️ 内存水位插桩已摘除 (12-fix-2, 2026-10-27)。
--   原来 build_nodes() 里每轮打两行 "mem bn infer/nodes" (collectgarbage
--   ("count") 读真 Lua 堆用量)。摘掉的理由:
--     1) 它自己就是热路径上的分配(两次 string.format + 两次 collectgarbage
--        调用), 每秒 2 行;
--     2) 常态下它被门槛(MEM_LOG_KB=210)挡住时, 三处 lua_kb() 调用仍然是
--        实打实跑着的, 白花;
--     3) 真正的水位现在从 R:STAT 的 lua_kb 字段看(零常态开销, 前端想看就看),
--        真要报警再单独加阈值检查。
--   ⚠️ 千万别改回 collectgarbage("collect") —— 那是真回收, 有毫秒级暂停,
--      放热路径上有让 UART 环形缓冲溢出的风险。
--
-- 只给 status() 用: R:STAT 是 5s/次的人工查看路径, 在这里读一次堆水位
-- 零常态开销 (原来挂在 build_nodes 的每秒热路径上才是浪费)。
-- ⚠️ 读的是【真 Lua 堆用量】。别用 rtos.meminfo("sys") —— 那是系统内存,
--    实测和 Lua 堆差 3 倍 (同刻 sys 报 67KB/198KB, 这里报 ~200KB)。
local function lua_kb()
    return collectgarbage("count")
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
        c.stopbits or cfg.STOPBITS, MqttUtil.jstr(PARITY_LETTER[c.parity or cfg.PARITY] or "N"))
end

-- U2 的一个子设备。两个来源, 保真度差很远:
--   poll/pollpull: active_cfg() —— 平台下发的正经配置, id/name/dtype 全是真的
--   sniff: mon.infer() —— 旁听推断, 只有 slave/addr/count/fc, 没有名字和类型,
--          id/name 只能按地址现造("r"+addr), dtype 默认 uint16。平台上看到
--          的名字会是地址而不是中文别名, 想看得顺眼得让用户配一份轮询表
-- ⚠️ nodeIndex 必须和 U4 的 -{n} 同一套序号(都按从机地址升序), 否则平台把
--    建档的子设备和上报的数据对不上, 症状是"拓扑发成功了但数据不进去"
-- ⚠️ props 条数封顶 (纵深防御, 2026-10): 推断表万一被撑大(异常 qty
--   的请求帧), 这里拼出来的 JSON 会是几 MB, 一个分配就把
--   Lua 堆(203K)顶爆 → "not enough memory for buffer allocation"
--   → VM 退出 → 设备重启(现场表现: 跑着跑着莫名重启)。
--
-- 11-fix (2026-10-27) 从 128 降到 64: 快照实测 sniff 档只有 8~9 个点,
--   128 条时单次 table.concat 要 ~19KB 连续内存, 在 203K 堆上是灾难级
--   分配; 64 条约 ~10KB。
--   ⚠️ 只影响 sniff 档: 拓扑只在 should_pub_topo() 为真时才拼, 而那个
--   闸门只对 sniff 返回 true (iot.lua 的 should_pub_topo)。platform 档的
--   物模型是平台自己下发的, 设备不通过 U2 拓扑上报它, 所以这里砍条数
--   砍不到 platform 头上。
local MAX_PROPS = 64

-- 一条 property 的 id/name 怎么定(平台靠 id 把数据对上号)。
--   pid/pname: 别名表指定的 id/name (2026-10), 优先
--   name:     用户配的真名, 但 "r123" 这种默认名不算
--   alias:    别名表的备用名
--   兜底:     reg<addr> —— 必须跟 U4 上报的 key(reg<addr>)一致,
--             平台按 id 匹配 property, 对不上就"拓扑建了但数据不进去"
local function prop_id_name(r)
    local id
    if r.pid and r.pid ~= "" then
        id = r.pid
    elseif r.name and r.name ~= "" and not r.name:match("^r%d+$") then
        id = r.alias or r.name
    else
        id = "reg" .. tostring(r.addr or "")
    end
    local nm = (r.pname and r.pname ~= "" and r.pname) or r.alias or id
    return id, nm
end

-- U2 的 nodes[]。返回【片段表】(不是成品串), nil+原因表示拓扑还没成形
-- (从机没识别出来/没配寄存器表)。
--
-- ⚠️ 12-fix-11 (2026-10-29): 这里不再造每行的小表, 也不再拼大串。
--   原来每个地址要过 put() 造两张表(6 字段 + 7 字段 = 406 字节),
--   82 个地址 = 33KB 垃圾/轮; 而且 nodes 串要再拼两次(nodes 本身 +
--   指纹拷贝 + 发布用的 body), 同时活着 4 份 8KB+ 的连续串 → 现场
--   8.3KB 都切不出来 → 拓扑一帧都没发出去。
--   现在: 解析出来的 id/name 立刻变成 property 片段, 中间不留表;
--   片段全部塞进一个表, 最后由 send_topo 一次 table.concat 成 body。
--   行本身直接引用 mon 的行(活的行谁都不动), 只多两个平行数组
--   (addrs/props)当分组用。
--
-- sniff 档的 RegisterData[] = 旁听推断 ∪ 平台下发配置, 同名同址以配置覆盖:
-- 平台是按我们上报的拓扑来建设备和生成配置的(用户确认), 只报推断那几条,
-- 平台就只认那几条; 配置落地后带真名(CT1/A相电流)的寄存器必须补进去才不缺项。
-- 因为拓扑指纹拿本函数产物当指纹, 配置一落地签名就变, 会自动补发一次 ——
-- 实测过的时序坑: 拓扑比配置落盘早 1 秒发(报的是推断出的 2 条裸名), 之后
-- 签名不变就再也不补发, 平台上建的物模型和数据面对不上
-- sniff 的 serial 参数必须用探测到的那几个值: active_cfg() 在 sniff 下返回的
-- 是 ds_poll 手工档的默认 9600, 而总线的波特率是自动识别出来的。拿错的
-- 波特率上报, 平台就照它建配置 —— 实测识别出 2400 却发了 9600, 平台回的
-- 建设配置 baud 就是 9600, 拿这份配置去轮询一帧都收不到
local function build_topo()
    local mode = get_mode()
    local parts = {}
    if mode == "sniff" then
        local smap = cfgstore.alias_map()
        -- 分组: slave → { addrs = {}, props = {} }
        local groups, gorder = {}, {}
        local function group_of(slave)
            local g = groups[slave]
            if not g then
                g = { addrs = {}, props = {} }
                groups[slave] = g
                gorder[#gorder + 1] = slave
            end
            return g
        end
        -- ① 旁听推断出来的行(直接引用, 不复制)
        for _, r in ipairs((mon.infer() or {}).regs or {}) do
            local g = group_of(r.slave)
            -- 别名表命中: id/name 用用户起的; 没命中还是 reg<addr>
            local sa = smap["reg" .. tostring(r.addr or "")]
            local id, nm
            if sa then
                id = (sa.id ~= "" and sa.id) or ("reg" .. tostring(r.addr or ""))
                nm = (sa.name ~= "" and sa.name) or id
            else
                id = "reg" .. tostring(r.addr or "")
                nm = id
            end
            -- ⚠️ dtype 口径保持原样(12-fix-11 不动它): 原来这里读的是
            --   r.dtype_summary —— 12-fix-6 把推断表改成累加器之后, 行里
            --   已经没这个字段了, 所以 sniff 档的物模型 dataType 一直是
            --   "uint16"(32bit 寄存器也会报成 uint16)。这是 12-fix-6 带来的
            --   回归, 但改它等于动平台的物模型契约(平台到底收不收
            --   uint32/int32/float32 还没在现网验过), 单独一次改, 不混在
            --   内存优化里。见 lua/README.md「物模型 dataType」。
            g.addrs[#g.addrs + 1] = r.addr
            g.props[#g.props + 1] = topo.prop(id, nm, "uint16", r.slave, r.addr, 1)
        end
        -- ② 平台下发的配置行: 同址覆盖推断行(用户配的真名优先)
        local pc = cfgstore.load_pull()
        for _, r in ipairs((pc and pc.regs) or {}) do
            local g = group_of(pc.slave)
            local id, nm = prop_id_name(r)
            local prop = topo.prop(id, nm, r.dtype or "uint16", pc.slave, r.addr, r.count or 1)
            -- 同址覆盖: 配置行顶掉推断行(位置不变, 跟老逻辑一致)
            local hit = 0
            for i = 1, #g.addrs do
                if g.addrs[i] == r.addr then hit = i break end
            end
            if hit > 0 then
                g.props[hit] = prop
            else
                g.addrs[#g.addrs + 1] = r.addr
                g.props[#g.props + 1] = prop
            end
        end
        local st = mon.status()
        local d = st.detected
        local ser = {
            baud = (d and d.baud) or st.baud,
            databits = (d and d.databits) or 8,
            stopbits = (d and d.stopbits) or 1,
            parity = (d and d.parity) or 0,
        }
        table.sort(gorder)
        for i, s in ipairs(gorder) do
            local g = groups[s]
            local props = g.props
            if #props > MAX_PROPS then
                local cut = {}
                for j = 1, MAX_PROPS do cut[j] = props[j] end
                props = cut
            end
            topo.node_parts(parts, i, s, serial_json(ser), "sniff_s" .. s, props)
        end
        return parts, "还没识别到在线的从机"
    end
    -- 一份轮询配置只有一个 slave(cfg.normalize_poll), 所以轮询档恒一个节点
    local c = active_cfg()
    if not (c and c.regs and #c.regs > 0) then
        return nil, "没有可用的寄存器表"
    end
    local props = {}
    for _, r in ipairs(c.regs) do
        if #props >= MAX_PROPS then break end
        local id, nm = prop_id_name(r)
        props[#props + 1] = topo.prop(id, nm, r.dtype or "uint16", c.slave, r.addr, r.count or 1)
    end
    topo.node_parts(parts, 1, c.slave, serial_json(c), "sniff_s" .. c.slave, props)
    return parts
end

-- 拓扑签名: 拿 build_topo 的产物做指纹。不另造一套字段遍历是因为
-- 拼串的时候从机/寄存器/串口参数全进去了, 内容变了就是拓扑真变了。
--
-- ⚠️ 11-fix (2026-10-27): 同时把片段表带出去, 给 send_topo 复用。
--   原来 task_main 每轮要 build 两次(拓扑指纹一次 + 发送一次), 每次都是
--   mon.infer() 重建整张推断表 + node_json + 两层 table.concat, 白扔一半
--   分配预算 —— sniff 档偶发 "not enough memory for buffer allocation"
--   → Lua VM exit → 设备重启, 崩点就在这些大字符串拼接上。
--   复用还有一个附带好处: 签名与实际发布内容【严格一致】, 不会再出现
--   "发了新内容却存了旧签名" 导致下一轮又重发一遍。
--
-- ⚠️ 12-fix-11 (2026-10-29): 指纹从【整串】改成【哈希】。
--   原来指纹 = "#长度:" .. nodes 串 —— 那是要常驻一份 8.5KB 连续内存的
--   (S.topo_sig), 而且发布时 body 又要拼一份, 峰值连续块需求 25KB。
--   现在指纹 = 片段内容的 31 位哈希(几十字节), 峰值降到 8.6KB。
local function topo_sig()
    -- ⚠️ 12-fix-7: 拼拓扑那几 KB 连续内存之前先按水位回收一次。
    --   现场(41 分钟): 拓扑这条只要 1.2KB 连续块都申请不到
    --   ("not enough memory for buffer allocation") —— 池子被 churn 切碎了。
    --   完整回收能把碎片并回大块(要现场验证, 所以加了日志)。
    reclaim_if_high()
    local parts = build_topo()
    if not parts then return nil end
    return topo.sig(parts), parts
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
-- 无源的字段(imei/iccid/longitude/latitude)按注释留空或整项不发, 不编假值
-- 19-fix: deviceName 字段按 mode 分流:
--   manual/platform 模式: 留空字符串 (用户决策 2026-10-16)
--   sniff 模式: 不动, 仍用 "VKBOX-" .. did
local function send_meta()
    local did = cur_did()
    if not did then return false, "无 SN" end
    -- 识别未成功前不上报 (见 pub_blocked)
    if pub_blocked() then return false, "识别未完成" end
    local csq = MqttUtil.mcall(mobile, "csq")
    if type(csq) ~= "number" then csq = nil end
    local p = {}
    -- V3 平台要求顶层 vendor/model/fwVersion (元数据帧和拓扑帧都要带)
    -- 记录 1: send_meta 删 vendor/model/fwVersion (用户决策, send_topo 跟 send_hello 保留)
    p[#p + 1] = string.format('"sn":%s', MqttUtil.jstr(did))
    p[#p + 1] = string.format('"deviceSn":%s', MqttUtil.jstr(did))
    p[#p + 1] = string.format('"imei":%s', MqttUtil.jstr(MqttUtil.imei(mobile)))
    p[#p + 1] = string.format('"iccid":%s', MqttUtil.jstr(tostring(MqttUtil.mcall(mobile, "iccid") or "")))
    p[#p + 1] = string.format('"fw":%s', MqttUtil.jstr("v" .. (_G.VERSION or "0.0.0")))
    p[#p + 1] = string.format('"firmwareVersion":%d', fw_num())
    p[#p + 1] = string.format('"hw":%s', MqttUtil.jstr(cfg.PLATFORM_MODEL))
    p[#p + 1] = string.format('"capabilities":[%s]', '"modbus","mqtt"')
    -- 19-fix: deviceName 按 mode 分流
    local mode = get_mode()
    if mode == "manual" or mode == "platform" then
        p[#p + 1] = string.format('"deviceName":%s', MqttUtil.jstr(""))
    else
        p[#p + 1] = string.format('"deviceName":%s', MqttUtil.jstr("VKBOX-" .. did))
    end
    p[#p + 1] = string.format('"serialNumber":%s', MqttUtil.jstr(did))
    if csq then p[#p + 1] = string.format('"csq":%d', csq) end
    p[#p + 1] = string.format('"netRegister":%s', tostring(net_registered(csq)))
    p[#p + 1] = string.format('"networkAddress":%s', MqttUtil.jstr(mqttcfg.load().host))
    p[#p + 1] = string.format('"isShadow":0')
    p[#p + 1] = string.format('"summary":%s', MqttUtil.jstr("VKBoxLite Bootstrap"))
    -- deviceType 固定 3 (产品定义: 网关). locationWay 0=未定位/2=LBS 成功
    p[#p + 1] = '"deviceType":3'
    p[#p + 1] = '"locationWay":' .. (S.lbs and "2" or "0")
    -- LBS 取到时加经纬度 (成功改 2 + 加两字段); 取不到按 send_meta 上方
    -- "无源不发"规矩整项不写, 不编 0/0 假装定位
    if S.lbs then
        p[#p + 1] = string.format('"latitude":%.6f', S.lbs.lat)
        p[#p + 1] = string.format('"longitude":%.6f', S.lbs.lng)
    end
    -- V3 平台 ts 毫秒 (13 位)
    -- ⚠️ 12-fix-11 (2026-10-29): ts 改用 MqttUtil.ms_of(os.time())。
    --   原来写的是 os.time()*1000 —— 32 位固件上这是【整数回绕】:
    --   实测 os.time()*1000 = -2036609728(负数!), 因为 1.75e9 × 1000
    --   早就超出了 32 位整数的范围, Lua 5.3 的整数乘法直接绕回去。
    --   ms_of() 是框架里早就有的正确写法(秒 → 13 位毫秒串, 绕开 int32)。
    --   ⚠️ ts 的 JSON 类型从"数字"变成"字符串" —— U4 的 ts 本来就是字符串
    --   (平台在收 ✓), 这里跟 U4 保持一致。
    p[#p + 1] = string.format('"ts":%s', MqttUtil.ms_of(os.time()))
    return pub(string.format(cfg.PLATFORM_INFO_TOPIC, did), "{" .. table.concat(p, ",") .. "}", 1)
end

-- 带 nodes[] 的那帧: 子设备拓补建档。
-- V3 平台要求顶层 vendor/model/fwVersion/ts(ms), 走'建子设备'路径
-- 自述字段(imei/iccid/位置等)归 send_meta, 不重复
-- parts_in: 由 topo_sig 传进来的【片段表】(11-fix)。不给才自己 build 一次。
--   正常路径永远走 topo_sig 那份, 所以每轮只 build 一次。
--
-- ⚠️ 12-fix-11 (2026-10-29): body 也改成【一次拼完】。
--   原来 string.format('...,"nodes":[%s]}', nodes) 会在 nodes 串之外
--   再造一份完整的 body(8.6KB 连续), 跟 nodes(8.5KB)同时活着 ——
--   现场池子 95% 时, 这 8.6KB 连续块就是切不出来的那个。
--   现在固定字段 + nodes 片段全塞进一个表, 一次 table.concat 出 body。
--   拼出来的字节跟老逻辑【逐字节一致】(平台的物模型契约不能动)。
local function send_topo(parts_in)
    local did = cur_did()
    if not did then return false, "无 SN" end
    -- 识别未成功前不发拓扑 (见 pub_blocked)。旧门闸只看 detecting, 兜底失败
    -- 之后 detecting=false 但其实没识别成功, 照样会发 —— 现在统一按"未成功"判
    if pub_blocked() then return false, "识别未完成" end
    local parts = parts_in
    if not parts then
        local p, err = build_topo()
        if not p then return false, err end
        parts = p
    end
    local b = {
        '{"vendor":', MqttUtil.jstr("VKBox"),
        ',"model":', MqttUtil.jstr(cfg.PLATFORM_MODEL),
        ',"fwVersion":', MqttUtil.jstr(_G.VERSION or "0.0.0"),
        -- ⚠️ 12-fix-11 (2026-10-29): ts 用 MqttUtil.ms_of(os.time())(秒 → 毫秒串)。
        --   原来写的是 tostring(os.time() * 1000) —— 32 位固件上整数回绕成
        --   负数(实测 -2036609728)。ms_of 是框架里早就有的正确写法,
        --   而且 U4 的 ts 本来就是字符串(平台在收 ✓), 这里跟 U4 保持一致。
        ',"ts":"', MqttUtil.ms_of(os.time()), '"',
        ',"nodes":[',
    }
    for i = 1, #parts do b[#b + 1] = parts[i] end
    b[#b + 1] = ']}'
    local body = table.concat(b)
    return pub(string.format(cfg.PLATFORM_INFO_TOPIC, did), body, 1)
end

-- 元数据指纹: 只挑会变的字段(imei/iccid/csq/主机名), 版本和型号是常量不必算。
-- 拿这几个字段拼串当指纹, 变了就重发, 和 topo_sig 同一套路
-- ⚠️ 12-fix-4 (2026-10-28): csq 从指纹里【摘掉】了(用户拍板)。
--   指纹的语义是"要不要重建平台模型"的身份标识 —— imei/iccid/host/位置
--   这些几乎不变的东西。csq 是【会变的数值】, 混进去的后果是:
--     信号强度一变 → 指纹变 → 重发元数据帧 → 平台按契约重建模型
--     → 回推 config/get → 我们再发拓扑 …… 每秒一轮, 白烧流量,
--     还把平台拖进"重建模型"的循环里。
--   现场实测(2026-10-28): 元数据帧从"偶尔"变成每 10~20 秒一帧, 每次
--   都是 csq 变了 29→27→30→28→26 在牵着走。
--   csq 仍然在 payload 里(只是不再参与指纹), 靠 interval_s 定期带上去。
local function meta_sig()
    local lbs_lat = S.lbs and S.lbs.lat or 0
    local lbs_lng = S.lbs and S.lbs.lng or 0
    return string.format("%s|%s|%s|%.6f|%.6f", MqttUtil.imei(mobile),
        tostring(MqttUtil.mcall(mobile, "iccid") or ""),
        tostring(mqttcfg.load().host or ""), lbs_lat, lbs_lng)
end

-- LBS 单基站免费定位 (合宙 lbsLoc2 默认扩展库).
-- 失败返回 nil, 成功返回 {lat, lng}. lbsLoc2.request 返回 lat/lng 是 string
-- (整数 3 位 + 小数 7 位, 例 "031.1346219"), 这里 tonumber 转 number 便于
-- fingerprint 算等值比较
local function lbs_request()
    if not lbsLoc2 or not mobile then return nil end
    -- 必须先扫基站, 不扫 lbsLoc2 内部 getCellInfo 取不到就直接 return nil
    pcall(mobile.reqCellInfo, 15)
    if sys and type(sys.waitUntil) == "function" then
        sys.waitUntil("CELL_INFO_UPDATE", 3000)
    end
    local ok, r1, r2 = pcall(lbsLoc2.request, 5000)
    if not ok then log.warn("iot", "lbs request err:", r1); return nil end
    if r1 == nil or r2 == nil then return nil end
    local lat, lng = tonumber(r1), tonumber(r2)
    if type(lat) ~= "number" or type(lng) ~= "number" then return nil end
    log.info("iot", "lbs got:", lat, lng)
    return { lat = lat, lng = lng }
end

-- U3: 网关自身资源。口径要说清, 否则平台拿阈值做告警会定错:
--   ram_percent  = rtos.meminfo("sys") 已用/总量, 真实系统内存(比 Lua 堆全)
--   uptime_sec   = os.clock() 秒级单调计数, 开机起算, 不受 NTP 跳变影响
--   cpu_percent  = 本框架主循环的忙碌占比(真实测量, 不是 MCU 的 CPU 占用率)。
--                 LuatOS 没有 OS 级 CPU 接口(README 记过 fsinfo/fs 都不存在),
--                 与其编一个 0 骗平台, 不如报一个能测的量。平台若按 90% 做
--                 CPU 告警, 得知道这个口径 —— U5 告警本次不做(已确认)
-- U5 资源告警阈值表 (百分比)
local EVENT_THRESHOLD = { ram = 85, cpu = 90, disk = 90 }

-- LuatOS 平台文件系统用量。rtos.fsinfo(path) 返回 total,used。内核没
-- 暴露就返回 nil — 该资源不参与告警, 不影响其他两个。
local function disk_used_pct()
    if not rtos or type(rtos.fsinfo) ~= "function" then return nil end
    local ok, total, used = pcall(rtos.fsinfo, "/")
    if not ok or type(total) ~= "number" or total <= 0 then return nil end
    return math.floor(used * 1000 / total) / 10
end

-- U5: 资源告警。payload 严格按 V3 文档 (sn/type/subtype/level/value/threshold/ts)
local function send_event(subtype, value, threshold)
    local did = cur_did()
    if not did then return false end
    local body = string.format(
        '{"sn":%s,"type":"resource_alarm","subtype":%s,'
        .. '"level":"warn","value":%s,"threshold":%s,"ts":%d}',
        MqttUtil.jstr(did), MqttUtil.jstr(subtype),
        tostring(value), tostring(threshold), os.time())
    return pub(string.format(cfg.PLATFORM_EVENT_TOPIC, did), body, 1)
end

-- 上升沿触发: value>=threshold 时只在状态从 false→true 的瞬间上报,
-- 状态保持不刷; 回到 threshold 以下把状态清掉, 下次越界再上报。
-- 节流 30s 防止阈值附近抖动连续上报。
local function check_event_threshold(ram_pct, cpu_pct)
    S.event_state = S.event_state or { ram = false, cpu = false, disk = false }
    S.event_at = S.event_at or 0
    local now = os.time()
    if (now - S.event_at) < 30 then return end
    local disk = disk_used_pct()
    local resources = {
        ram  = { value = ram_pct, threshold = EVENT_THRESHOLD.ram },
        cpu  = { value = cpu_pct, threshold = EVENT_THRESHOLD.cpu },
    }
    if disk then
        resources.disk = { value = disk, threshold = EVENT_THRESHOLD.disk }
    end
    for sub, r in pairs(resources) do
        local crossed = r.value >= r.threshold
        if crossed and not S.event_state[sub] then
            send_event(sub, r.value, r.threshold)
            S.event_state[sub] = true
            S.event_at = now
        elseif not crossed and S.event_state[sub] then
            S.event_state[sub] = false
        end
    end
end

local function send_gw_res()
    local did = cur_did()
    if not did then return false end
    -- 识别未成功前不上报 (见 pub_blocked)。U5 资源告警的判定在函数末尾
    -- (check_event_threshold), 这里一并挡掉 —— 识别扫描吃 CPU, 忙碌占比
    -- 虚高容易撞 cpu>=90 阈值, 误发一条资源告警给平台
    if pub_blocked() then return false end
    local total, used = heap_info()
    local ts = MqttUtil.ms_of(os.time())
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
    -- U5 阈值检测: 上升沿触发, 防刷屏
    check_event_threshold(ram, cpu)
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
-- manual 都是 /service/invoke 系列 + config/pset/pget 等 5 条），所以除 idle 外
-- 所有档都订同一份，不再按模式分流：
--
-- idle：什么都不订。idle 是"未接任务"的原始态，此时 MQTT 连接可以是通的
--   （凭证、broker 都与模式无关），但订阅意味着接收平台下行，而拉取配置
--   (config/get) 和下行写 (property/set 系列) 都只在 poll/pollpull/sniff
--   下才有意义。idle 订着 = 设备还没开始采数就先挂在平台的接收侧，
--   看着像已经接了任务，实际一个字节都不会用上。
--
-- 其余三档：5 条平台 topic（4 条 gw 前缀 + 1 条 node 前缀），一条都不能少：
--   ① D1(/gw/config/get/{sn}) 是"拉取配置"链路唯一的入口
--   ② service/invoke + property/set + property/get 是平台侧另外三类下行，
--      不订就收不到服务调用/属性设置/全量查询，且无报错
--   ③ D2-node(/node/service/invoke/{sn}-1) 是子设备级服务调用的下行：
--      {-N} 跟 U4 上报的 -{n} 同序列(子设备序号), 按档案从机数精确展开,
--      broker 不支持通配(Step3b 实证, 见 .agent-memory/d2-topic-switch-log)
--   这些 topic 是 core/config.lua 的平台常量，不随配置变
--
-- ⚠️ 手动档额外还要订用户填的 sub_topic：手动档连的是用户自己的 broker，
--    平台那套 /sys/thing/gw/{sn} 拼出来也没人往那儿发。不订用户那条 =
--    用户配的下行永远收不到。自动档的 sub 与 config/get 同形，上面已去重
-- ⚠️ 曾按 manual_on 分流过，导致 sniff 沿用切入前那份清单：从 idle 进 sniff
--    会是空的，从手动配置进 sniff 又少订 4 条平台 topic，平台下发到设备全丢。
-- D2-node 订阅清单: 与 U4 上报的 -{n} 同语义 (n=子设备序号, 从机地址升序
-- 1..K; 不是 slave 地址)。broker 不支持通配 (Step3b 实证), 按档案从机数
-- 精确展开。当前架构单从机 (pullcfg 只解析 devices[0]) → 恒订 -1;
-- 多从机扩展点: pullcfg 存下 devices[] 列表后, 在这里展开成 -1..-K
local function node_invoke_topics(did)
    local topics = {}
    -- TODO(pullcfg 多从机): 平台快照 devices 台数 → 序号 1..#devices
    topics[1] = string.format(cfg.PLATFORM_FUNC_NODE_TOPIC, did) .. "-1"
    return topics
end

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
    -- 手动档不订平台下行：manual 完全独立于平台, 唯一入口是用户 sub_topic
    if not mqttcfg.load().manual_on then
        add(string.format(cfg.PLATFORM_GET_TOPIC, did))
        -- D2 服务调用：gw 级 + node 级。node 级按档案从机动态生成精确订阅
        -- （订阅循环逐条 pcall, 单条被拒不连坐其他订阅）
        add(string.format(cfg.PLATFORM_FUNC_TOPIC, did))
        for _, t in ipairs(node_invoke_topics(did)) do
            add(t)
        end
        add(string.format(cfg.PLATFORM_PSET_TOPIC, did))
        add(string.format(cfg.PLATFORM_PGET_TOPIC, did))
    end
    add(S.sub)
    return subs
end

-- 平台 topic 发布的中央闸门: idle/manual 全不发, 只 pollpull/sniff 走
-- U1/U2/U3/U5/U6/U7 全部受这个 gate 管, U4 的 manual 路径仍走用户 pub_topic
local function should_pub_platform()
    if get_mode() == "idle" then return false end
    if mqttcfg.load().manual_on then return false end
    return true
end

-- U2 topo (带 nodes[]) 单独的闸门: 只有 sniff 主动建档需要发,
-- pollpull 的拓扑由平台 configSnapshot 下发(平台已知道/对方主动),
-- device 再发回去是闭环+浪费, 触发后还会被 60s 兜底限制 (见 L1460)。
-- idle/poll 拓扑没意义
local function should_pub_topo()
    return get_mode() == "sniff"
end

-- U2 meta (不带 nodes[], 走 /sys/thing/gw/info/post/{sn}) 单独的闸门:
-- manual 也发 (用户需求, 2026-10-13: 填 W:MQTT 后走用户 broker / 平台),
-- sniff 主动建档需要发, platform configSnapshot 后由 send_gw_res 带过,
-- 但 send_meta 不管 platform 怎么走, 只要指纹变就发, 简化一份冗余.
-- idle 不发: 切回 idle 设备已经退场, 继续发会污染平台档案
local function should_pub_meta()
    local m = get_mode()
    if m == "idle" then return false end
    return true
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
        -- 12-fix-4: 新连接要重新报到 —— pubsched 的闸门状态也得重置,
        --   否则重连后第一次上报还要再等 30 秒(闸门是按上次发送时间算的)。
        pubsched.reset()
        -- 每个新连接都要重新报到。reset_state 只在 start() 时跑, 不断线重连
        -- 不会清 hello_at —— 不清的话重连后 task_main 的"连接后补发"分支
        -- (判 hello_at == 0)永远不成立, 平台那头看到的是设备中途消失再回来,
        -- 而没有任何 hello
        S.hello_at = 0
        -- meta_sig 同理: 重连后 task_main 的"指纹变了就发 send_meta"分支
        -- 不会重置 meta_sig, 指纹不变就不发, 平台 / 用户 broker 拿不到最新
        -- 元数据。清掉后下一轮 loop 必发第一帧 (跟 hello_at 同套路)
        S.meta_sig = nil
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
                    S.reject_reason = "平台拒绝连接(CONACK 0x05 未授权), 检查地址/端口或补用户密码/凭证密码"
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
    return net_registered(MqttUtil.mcall(mobile, "csq"))
end

local function try_connect()
    if not mqtt then return false, "mqtt 库不可用(需 sysplus/mqtt 组件)" end
    if type(mqtt.create) ~= "function" then return false, "mqtt.create 不可用" end
    local c = mqttcfg.load()
    local did = device_id()
    -- 18-fix: 必须有 SN 才能建连, 不再有 allow_no_sn 旁路
    if not did or did == "" then return false, "no sn" end
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
-- 一条例外，会导致合法下行被静默丢弃，必须放行：
--   非 /sys/thing/ 命名空间：用户自己配的订阅 topic，不在 V3 契约内
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
                    -- 37-fix: needs_restart=true 但 poll 没起来 (34-fix 让
                    --   切 platform 时 ds_pull 空就不起), apply_cfg 后必须
                    --   兜底 start, 否则 R:REG 永远空, poll 也不真起
                    pe.apply_cfg(n)
                    pe.start("pull")
                end
            else
                pe.apply_cfg(n)
                -- 37-fix: needs_restart=false 但 poll 没起来 (用户切 platform
                --   时 ds_pull 空, 34-fix 不起; 平台随后推了一样的 baud/slave),
                --   也得兜底 start
                if not pe.is_running() then pe.start("pull") end
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
        MqttUtil.jstr(p.msg_id), MqttUtil.jstr(p.msg ~= "" and p.msg or "config applied"), os.time())
    log.info("iot", "config/reply " .. topic .. " " .. body)
    local ok, err = pub(topic, body, 1)
    if not ok then return false, err end
    p.replied = true
    S.replied = S.replied + 1
    return true
end
M.reply_config = reply_config

-- configSnapshot 判据/设备侧落地原因见 handle_push_payload 上头那段。
-- REPORT/WRITE/裸值都不带它, 不可能误判。
-- 塞进拉取结果槽位以 done 态呈现, 前端复用回填渲染
local function recv_push(t, payload)
    local pc = get_pullcfg()
    if not pc then
        S.push_err = "pullcfg 未加载(该档位不应收到配置推送)"
        log.warn("iot", "push ignored: pullcfg not loaded")
        return false
    end
    local r, err = pc.parse_snap(t, t.configSnapshot)
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
        pubsched.changed("prop")   -- 12-fix-4: 平台点名要数据 → 置脏(节奏仍走闸门)
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
    -- 识别未成功前不上报 (见 pub_blocked): hello 是平台建档的入口, 识别期间
    -- 串口参数还是默认值, 这时报到等于让平台按错波特率建一次模型
    if pub_blocked() then return false, "识别未完成" end
    local did = device_id()
    if not did or did == "" then return false, "无 SN" end
    -- hello topic 走固定平台常量(不再可配)。上面已经判过无 SN, 这里
    -- did 一定是非空串, format 拼出来就是带 SN 的完整 topic
    local topic = string.format(cfg.PLATFORM_HELLO_TOPIC, did)
    -- topicFormat 固定 v3：自述 topic 形状，消除"平台硬编码旧版 / 固件烧新版"
    -- 漂移导致下行 topic 错位（指令全丢且无报错）。
    --
    -- onboardingMode 按当前 485 档位如实报(文档: sniff/platform/manual):
    --   sniff     → 平台跳过"对本地自建设备无效的配置快照推送"。sniff 档的
    --               寄存器表来自本地旁听推断, 平台推过来的只会是 193B 空壳
    --   platform  → 平台照常推 ConfigSnapshot(pollpull 档要的就是这个)
    --   manual    → 平台见 manual 不推配置(行为同 sniff: 用户手配档案, 平台
    --               侧不预知具体设备, 靠上报 auto-provision 补建)
    local m = get_mode()
    -- "platform" 是当前 mode 名; "pollpull" 是历史别名 (老 fskv 软切可能返回)
    local onboard = m == "sniff" and "sniff" or (m == "platform" or m == "pollpull") and "platform" or "manual"
    -- deviceId 按文档取 IMEI，取不到报 "unknown"（不报空串：平台校验
    -- gateway_imei，空串和缺字段是两回事）。不一致会被拒 hello
    local dv = MqttUtil.imei(mobile)
    if dv == "" then dv = "unknown" end
    local body = string.format(
        '{"vendor":%s,"model":%s,"fwVersion":%s,"deviceId":%s,"topicFormat":"v3","onboardingMode":%s}',
        MqttUtil.jstr(cfg.PLATFORM_VENDOR), MqttUtil.jstr(cfg.PLATFORM_MODEL), MqttUtil.jstr(_G.VERSION or "0.0.0"),
        MqttUtil.jstr(dv), MqttUtil.jstr(onboard))
    log.info("iot", string.format("pullcfg hello topic=%s sn=%s imei=%s mode=%s body=%s",
        topic, did, MqttUtil.imei(mobile), onboard, body))
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
            local pc = get_pullcfg()
            if not pc then
                return pull_finish("fail", "pullcfg 未加载")
            end
            local r, err = pc.parse(payload)
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
            -- 34-fix: 区分 "拉取失败" (网络/超时) 和 "拉到了但应用失败"
            --   (配置不合法/存不下). 后者单独给 apply_fail 状态, 前端可
            --   据此给用户更精确的提示 (用户卡在 "等下发" 时能知道是
            --   平台配置有问题, 不是网络)
            local aok, aerr = auto_apply(r)
            if not aok then
                return pull_finish("apply_fail", "拉取成功但配置不适用: " .. tostring(aerr))
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
        -- 12-fix-6: 推断表多出新地址 → 主动推给前端(用户 2026-10-28
        --   要求: 前端不用手动刷新推断表)。只在用户看着 sniff 面板时推
        --   (前端用 W:INFERWATCH 开关), 没人看就一个字节都不发。
        --   ⚠️ 先问 watch 再取 dirty: 没人看的时候 dirty 必须留着, 等
        --   前端打开面板时一次性推出去(表里可能已经有东西了)。
        --   放在这里而不是收帧协程里: 一次推送要拼几 KB JSON, 放进热
        --   路径就是新的碎片化来源(12-fix-5 的教训)。
        --   ⚠️ 必须放在【连接与否的分支之外】: 推给前端跟 MQTT 连没连
        --   没关系, 平台连不上时前端照样要看到新地址。
        if mon.infer_watch() and mon.take_infer_dirty() then
            local push = _G.cmd_push_infer
            if push then pcall(push) end
        end
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
            -- ⚠️ 12-fix-8 (2026-10-28): 阈值 240 → 200, 因为这条保险丝
            --   【量错了对象】—— 它量的是 collectgarbage("count")(Lua 自己
            --   记的字节数), 不是 Lua 堆池的真实用量。
            --   现场实测(12-fix-8 崩溃日志, 18:28:35):
            --     E/mem memory allocation failed total 307192, used 290368
            --     同时 census lua=213.7KB
            --   池实际用了 283.6KB, count 只报 213.7KB —— 差的那 ~70KB 是
            --   【每个对象的 GC 头 + 池块头】(现场约 1900 个对象, 一个 ~40B)
            --   再加碎片。count 永远看不到这一块。
            --   240 的阈值因此形同虚设: count 停在 213 < 240 → 保险丝一次
            --   都没触发(现场 census gc=0), 垃圾一路堆到池 98.6%, 最后连
            --   协程栈都分配不出来 → "E/user.coroutine.resume not enough
            --   memory" → VM exit → 重启。
            --   换算: 池用量 ≈ count × 1.33。阈值 200KB(count) ≈ 池 266KB
            --   ≈ 87%, 留够连续大块的余地。
            --   ⚠️ 收完垃圾不会【合并】相邻空闲块(LuatOS 分配器不合并),
            --   这条保险丝的作用是"别让池的总用量飘上去", 不是"腾出一块
            --   连续大内存" —— 后者只能靠少占常驻(见 12-fix-8 的
            --   bus/poll / iot/pullcfg 惰性 require)。
            --   10 秒最多一次, 且不在 UART 热路径上(task_main 每秒一轮),
            --   一次全回收几毫秒。
            if (os.clock() - (S.gc_at or -1e9)) >= 10 then
                local kb = collectgarbage("count")
                if kb > 200 then
                    collectgarbage("collect")
                    S.gc_at = os.clock()
                    S.gc_trig = (S.gc_trig or 0) + 1
                    log.warn("iot", string.format("gc safety: lua=%.1fKB -> collected", kb))
                end
            end
            if S.recv_pending then
                local rp = S.recv_pending
                S.recv_pending = nil
                pcall(handle_downlink, rp.topic, rp.payload)
            end
            refresh_subs()
            local c = mqttcfg.load()
            local pub_platform = should_pub_platform()
            local pub_meta = should_pub_meta()
            local pub_topo = should_pub_topo()
            -- U4 始终跑: manual 走用户 pub_topic, 自动档走 PLATFORM_PUB_TOPIC + -{n}
            -- idle 模式由 publish() 内部 get_mode() 短路 (跟 should_pub_platform 一致),
            -- collector.dataCache 残留历史数据不应当上送平台
            -- U1/U2/U3/U5/U6/U7 受 pub_platform gate 管: idle/manual 全不发
            -- ⚠️ 12-fix-4 (2026-10-28): 节奏统一交给 pubsched。
            --   原来这里是:
            --     local due = false
            --     if c.interval_s > 0 then due = (os.time() - S.last_pub) >= c.interval_s
            --     else due = S.dirty end
            --     if S.dirty then due = true end      ← 这行把 interval_s 架空了
            --   S.dirty 由 collector 每存一个数据点就置位, sniff 档下总线
            --   一直在跑 → 永远脏 → 每秒发一次全量(现场实测 0.8 次/秒)。
            --   现在: 脏只表示"有东西要发", 还要过 30 秒闸门才真发。
            --   interval_s 的兜底重发由 pubsched.due(ch, fallback_s) 负责。
            if pubsched.due("prop", c.interval_s) then publish() end
            -- 把这一轮的干活耗时记进 busy, 区间长度记进 span。span 与 busy
            -- 必须同一轮清零, 否则占比会越算越小
            S.busy_s = (S.busy_s or 0) + (os.clock() - t0)
            S.span_s = (S.span_s or 0) + (os.clock() - t0) + 1.0
            -- U2 元数据帧 (不带 nodes, 走 /sys/thing/gw/info/post/{sn}):
            --   manual 模式也发 (用户需求, 2026-10-13): 触发条件是用户在 W:MQTT
            --   填了连接信息 + MQTT 连上, 发到用户 broker (跟 manual 一样可填,
            --   填 dz.voltkun.com 时平台也收到, 填自家 broker 时平台收不到
            --   也不影响其他功能)
            --   记录 2: 指纹变就发, 跟 sniff/platform 一致; 同时加 c.interval_s
            --   兜底 (默认 2min), 指纹长时间没变也定期重发一次, 跟 U3/U4 共享
            --   idle 模式不发: 切回 idle 设备已退场, 继续发会污染平台档案
            if pub_meta then
                local msig = meta_sig()
                -- ⚠️ 12-fix-4: 指纹变了只是"有东西要发", 还要过 30 秒闸门。
                --   原来 (msig ~= S.meta_sig) 直接就发了 —— 而 csq 摘掉之前
                --   指纹里含 csq, 信号强度一变就发一帧(现场实测每 10~20 秒
                --   一帧, 每次都是 csq 29→27→30→28→26 牵着走)。
                if msig and msig ~= S.meta_sig then pubsched.changed("meta") end
                if pubsched.due("meta", c.interval_s) then
                    local ok, e = send_meta()
                    if ok then
                        S.meta_sig = msig
                        S.meta_at = os.time()
                        pubsched.sent("meta")
                        log.info("iot", "gw meta posted: " .. (msig or "due " .. c.interval_s))
                    else
                        log.info("iot", "gw meta skip: " .. tostring(e))
                    end
                end
            end
            -- U1/U3/U5/U6/U7 + U2 拓扑 受 pub_platform gate 管: idle/manual 全不发
            if pub_platform then
                if (os.time() - (S.res_at or 0)) >= c.interval_s then send_gw_res() end
            -- U2 拓扑帧(带 nodes[]): 建子设备 + 绑定 + 物模型。签名没变就是子设备
            --   清单没变, 平台那边的档还在, 不需要重建 —— 实测(2026-10-08)留了
            --   个 60s 兜底重发, 平台一收到带 nodes 的 info/post 就重建模型并
            --   回推 config/get, 形成"我们发拓扑 → 平台推配置 → 我们再发拓扑"
            --   的闭环, 每 60s 一轮。兜底路径还不打日志, 现象是"sniff 档平台
            --   不断下发模型配置", 难查
            -- detect 跑完之前不发拓扑: 这期间 serial 参数还是上一轮的默认值
            -- (9600), 发出去平台就按错波特率建一次模型, detect 完还得再重建 ——
            -- 白推一次配置, 白占一次 info/post
            -- 2026-10: 判据从"正在识别"升级成"识别未成功"(含兜底失败), 与
            -- pub_blocked 同一口径
            local sig = nil
            local nodes_json = nil
            -- ⚠️ pcall 包一层 (2026-10): topo_sig → build_nodes → node_json 里
            --   有大字符串拼接, 万一某次数据异常导致一次分配失败, 未捕获的话
            --   直接把整个 task 掀了("not enough memory for buffer allocation"
            --   → Lua VM exit → 设备重启)。包起来最多丢一次拓扑重发, 不至于重启
            --
            -- ⚠️ 11-fix (2026-10-27) 更正上面那条注释的假设: pcall 只拦得住
            --   普通 Lua error, 拦不住 LuatOS 分配器级的 OOM fatal —— 真要防住
            --   只能【少分配】, 也就是下面把 build_nodes 从每轮两次降到一次。
            --   pcall 留着当普通 error 的兜底。
            --
            -- ⚠️ 12-fix-2 (2026-10-27): 拓扑【重建】节流 cfg.TOPO_REBUILD_MS。
            --   build_nodes 每秒调一次, 每轮分配 ~14KB (infer 重建整张
            --   推断表 + node_json 拼 JSON + 两次 concat)。
            -- ⚠️ 12-fix-4 (2026-10-28): 拓扑的【重建】也并进统一闸门(30 秒)。
            --   原来重建节流 5 秒, 但 sniff 档寄存器集一直在变 → 每 5 秒就重建
            --   一次(~14KB) + 重发一次(平台收到 info/post 就重建模型 →
            --   回推 config/get → 我们再发拓扑)。现场实测拓扑 posted 出现在
            --   10:46:34 / 10:46:50 / 10:46:55 / 10:47:00 —— 平均 20 秒一帧,
            --   每次都拖着平台重建一遍模型。
            --   拓扑只是"建档"用的, 晚 30 秒被认出来完全无影响。
            --
            --   用 ready() 而不是 due(): 拓扑的"内容变了"要靠重建才能知道,
            --   而重建本身很贵 —— 所以按时间闸门来, 而不是每轮都重建。
            if pub_topo and not pub_blocked() then
                if pubsched.ready("topo") then
                    local ok, s, n = pcall(topo_sig)
                    if ok then
                        sig, nodes_json = s, n
                        S.topo_at = os.clock()
                    else
                        -- 12-fix-7: 计数 + 记进 census —— 现场"拓扑停了"之前
                        -- 只有这一行 warn, 光看 census 以为一切正常
                        S.build_fail = (S.build_fail or 0) + 1
                        log.warn("iot", "topo_sig failed, skip this round: " .. tostring(s))
                    end
                end
            end
            if sig and sig ~= S.topo_sig then
                -- pcall: send_topo 同样有大字符串拼接, 普通 Lua error 不该掀掉
                --   整个 task。返回值拆成 pok/sent/e 三段 —— pcall 的第一个
                --   返回值是"有没有出错", 不能当"发没发成功"用。
                local pok, sent, e = pcall(send_topo, nodes_json)
                if pok and sent then
                    S.topo_sig = sig
                    pubsched.sent("topo")
                    -- ⚠️ 12-fix-11 (2026-10-29): 指纹现在是哈希(几十字节),
                    --   不是原来那份 nodes 串, 所以 #sig/头 100 字节没意义了。
                    --   改打: 片段数 + 内容总长(现场看拓扑规模用) + 指纹。
                    log.info("iot", "topology posted: parts=" .. #nodes_json
                        .. " bytes=" .. topo.len(nodes_json) .. " sig=" .. sig)
                else
                    log.info("iot", "topology skip: " .. tostring(e or sent))
                end
            end
            end  -- if pub_platform end
            -- 12-fix-4: 每 30 秒一行结构普查(见 census() 上面的说明)
            if (os.clock() - (S.census_at or -1e9)) >= 30 then
                S.census_at = os.clock()
                local cok, cerr = pcall(census)
                if not cok then log.warn("iot", "census failed: " .. tostring(cerr)) end
            end
            if sys then sys.wait(1000) end
            -- LBS 定位: 30 分钟一次. 避开免费版频率限制(官方 4h-2min 不一致,
            -- 30min 足够稳). lbs_request 失败保留旧 S.lbs (或 nil), 指纹不变
            -- 不会触发发 U2 (成功后指纹变, 自动发)
            if lbsLoc2 and (os.time() - (S.lbs_at or 0)) >= 1800 then
                local r = lbs_request()
                S.lbs_at = os.time()
                if r then S.lbs = r end
            end
            -- hello 有【两个入口】, 不能只看 task_main 这一个:
            --   入口 1: ctrl.lua:76 — 进 mode 时主动调 iot.hello() (manual 档会走这里)
            --   入口 2: 下面这个 if — task_main 每轮循环的"连上后补发" (manual 不进)
            -- 入口 1 失败 (进 mode 时 MQTT 还没连上) 才需要入口 2 补, 但 manual 的
            -- 入口 2 永远 false, 意味着 manual 模式下如果切档时 MQTT 没连上, hello
            -- 不会重发 —— 但 ctrl.lua:71-75 注释说明 manual 失败不回滚, 平台那头
            -- 看不到不影响采集 (主职是采寄存器表), 也就无所谓
            --
            -- 放在 sys.wait 之后, 保证每轮循环只判一次、且不和本轮的上报挤在一起
            -- 只对【非 idle 且非 manual】档走这个 if —— pub_platform 在 manual_on
            -- 时返回 false, manual 档根本不会进 ① 也不会进 ②
            --
            -- ① 连接后补发。进模式那一刻 MQTT 往往还没连上(set_manual 刚触发
            --    断开重连), ctrl 里那次 hello 是静默失败的。这里保证每个连接
            --    至少发一次:
            --      platform: 平台侧需要这个 hello + 后续拓扑/数据帧 auto-provision
            --                补建档案, 收不到 hello 平台那头完全看不到设备上线
            --      sniff:    也发一次, 是拓扑建档的前置
            --    hello_at == 0 是 reset_state 里"这个连接还没发过"的语义, 正好复用
            -- ② 只对 platform 档周期重发: 那是唯一"在等平台下发配置"的档。sniff 档
            --    的 hello 发完就判完成, 没有"未拿到配置"这个状态; manual 档的 hello
            --    由 ctrl 入口发, 这里 30min 重发不涉及 manual
            --
            -- 平台收到 hello 会重推 ConfigSnapshot, 由 recv_push 自动落盘 ——
            -- 不走拉取状态机, 所以不影响前端正在显示的拉取结果, 也不需要用户
            -- 再点一次「拉取配置」。这正是文档"未拿到配置前每 30min 重发"的用途:
            -- 平台侧档案被重置/白名单到期时, 设备侧无从得知, 只靠上电那一次 hello
            -- 会永久失联且没有任何报错
            if pub_platform and S.hello_at == 0 and not pulling() then
                log.info("iot", "hello on connect, mode=" .. get_mode())
                pcall(send_hello)
            elseif pub_platform and S.hello_at and S.hello_at > 0 and get_mode() == "platform"
                and not pulling()
                and (os.time() - S.hello_at) >= cfg.HELLO_RE_S then
                log.info("iot", "hello re-send (30min), mode=platform")
                pcall(send_hello)
            end
        end
    end
end

function M.init()
    collector.on_update(function()
        -- 12-fix-4: 只置脏, 不直接决定发不发。
        --   原来这里 S.dirty = true, 而 task_main 里 `if S.dirty then due = true end`
        --   直接把它当成"立刻发" —— sniff 档下总线一有流量就永远脏 →
        --   每秒发一次全量数据 → 堆被压碎(现场 2026-10-28 崩溃)。
        --   现在脏归 pubsched, 节奏由 30 秒闸门统一管。
        S.dirty = true
        pubsched.changed("prop")
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
    if sys then
        -- ⚠️ 12-fix-8 (2026-10-28): 给上报协程套一层 pcall。
        --   现场崩溃日志:
        --     18:28:35.367 E/mem memory allocation failed total 307192,
        --                   used 302880, alloc 320
        --     18:28:35.383 E/user.coroutine.resume not enough memory
        --                   iot.lua:1898
        --     18:28:35.886 E/main Lua VM exit!! reboot in 15000ms
        --   堆用到 98.6% 时, 这一轮里任何一次分配失败都会把协程带死,
        --   LuatOS 判定成致命错误 -> 整个 VM 退出 -> 设备重启(现场"翻页
        --   就崩了")。这里兜住: 死一轮就清缓存 + 回收, 再拉起来,
        --   最多丢一轮上报, 不再连累整个设备。
        sys.taskInit(function()
            while true do
                local want = S.want_run
                local ok, err = pcall(task_main)
                if ok then break end          -- 正常退出(want_run=false)
                log.warn("iot", "task_main error, restart: " .. tostring(err))
                S.want_run = want              -- 恢复用户原本的意图
                if not want then break end
                pcall(collector.trim_cache)
                pcall(mon.trim_reqs)
                collectgarbage("collect")
                if sys then sys.wait(1000) end
            end
        end)
    end
    log.info("iot", "started")
    return true
end

function M.is_running() return S.want_run end

-- 25-fix: 暴露 MQTT 当前连接状态 (S.connected 是 local, 外部读不到)
--   ctrl.lua 在切 platform 档时用它做前置检查
function M.is_connected() return S.connected == true end

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
        -- ⚠️ 这里必须判【非空】而不是用 or: Lua 里 "" 是 truthy!
        --   切档(manual→sniff)时 set_manual 会 kick 重连, 重连完成前 S.sub/S.pub
        --   还是旧档位的值(手动档没配 topic 时就是空串), 用 or 会宁可空串也不
        --   回退到 profile 现算的当前档位值 → 前端"生效订阅"显示"未连接",
        --   而"生效发布"走 pub_topics(profile 直算)是对的, 两栏自相矛盾
        --   (2026-10 用户实测报出)
        pub = (S.pub and S.pub ~= "") and S.pub or (prof and prof.pub),
        sub = (S.sub and S.sub ~= "") and S.sub or (prof and prof.sub),
        -- 32-fix: 设备实际发送的 topic 列表 (平台档带 -N 后缀). 前端只显示
        --   这个, 不做本地构造. 老设备 (无 pub_topics 字段) 时为 nil, 前端
        --   会回退到 s.pub
        pub_topics = prof and prof.pub_topics,
        -- 32-fix: 设备实际发送的 topic 列表 (平台档带 -N 后缀). 前端只显示
        --   这个, 不做本地构造. 老设备 (无 pub_topics 字段) 时为 nil, 前端
        --   会回退到 s.pub
        -- 实际订阅清单 (2026-10): 前端原来自己拼 D2n 那条, 显示的是模板
        --   ".../{sn}-N"(N 是从机序号占位符), 设备实际订的是 ".../{sn}-1"
        --   (多从机展开成 -1..-K)。现场照着模板订阅是收不到的, 所以把
        --   build_subs() 的真实清单报上来, 前端照实显示
        sub_list = build_subs(),
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
        -- 12-fix-4: 上报调度状态 —— 每个通道: 脏没脏 / 发了几次 /
        --   被闸门挡了多少次 / 距上次发送多少秒。前端和现场排查都靠它
        --   判断"上报是不是被 30 秒闸门挡住了"。
        pub = pubsched.status(),
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
        -- 12-fix-2: 真·Lua 堆水位 (KB)。heap 那份是 rtos.meminfo("sys") 的
        --   【系统内存】, 和 Lua 堆差 3 倍 (同刻 sys 报 67KB/198KB, 这里
        --   ~200KB), 判断"Lua 堆还剩多少"只能看这个字段。
        --   替代原来 build_nodes 里每秒打两行的 "mem bn ..." 插桩 ——
        --   R:STAT 是人工查看路径, 在这里读一次零常态开销。
        lua_kb = lua_kb(),
    }
end

reset_state()

return M
