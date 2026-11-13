local util = require "util"
local cfg = require "core/config"
local log = util.log()

local fskv = util.try("fskv")
local json = util.try("json")
local rtos = util.try("rtos")

local M = {}

-- 4 种工作模式提到模块顶部(各文件独立常量是 Lua 闭包隔离的代价)
-- 记录 3: 删 MODE_POLL/MODE_PULL (历史别名)。项目还在测试阶段, 没正式发布,
-- 不存在老 fskv 存 "poll"/"pollpull" 的情况, normalize_sys 直接限 4 值。
local MODE_MANUAL, MODE_PLATFORM, MODE_IDLE, MODE_SNIFF = "manual", "platform", "idle", "sniff"

local K_POLL, K_SYS = "ds_poll", "ds_sys"
-- ds_pull: 平台拉取的独立槽, 复用 normalize_poll/default_poll, 不新增校验。
-- 必须分开: 原本共用一槽, 拉一次平台配置就覆盖手配的寄存器表(见 lua/README.md 配置来源隔离)。
-- ds_infer: sniff 推断表持久化槽 (2026-11)。存通讯参数 + 推断出的寄存器表。
--   进 sniff 时加载, 跳过识别直接收帧; 退出 sniff 先写 flash 再弹窗问是否清除。
local K_PULL = "ds_pull"
local K_INFER = "ds_infer"
-- ds_alias: sniff 侧别名表 (2026-10)。存【用户给 reg<addr> 起的名字】(id+name),
-- 不是识别出来的串口参数(那些只存本次会话)。决定 sniff 档 U2 拓扑属性与
-- U4 数据项的 id/name, 让平台物模型显示人看得懂的名字。
-- 不复用 ds_poll: 那是手配寄存器表, 会被平台下发覆盖/切 idle 复位清掉
-- ⚠️ 待废弃: ds_infer 持久化后, 推断表行里自带 name/id, 不再需要单独别名表
local K_ALIAS = "ds_alias"

local function num(v, d)
    if v == nil then return d end
    return tonumber(v) or d
end

local function str(v, d)
    if type(v) ~= "string" or v == "" then return d end
    return v
end

-- 往外报的"原因"先过这一道: 应答是【一整行】的, 原因里带换行会把后面所有
-- 帧的解析搅乱; 太长会顶到 prov 的行缓冲。C 层那句话(内存/参数)都是 ASCII,
-- 80 字节截断不会切断多字节字符
local function brief(v, n)
    local s = tostring(v):gsub("[\r\n]", " ")
    n = n or 80
    if #s > n then s = s:sub(1, n) end
    return s
end

-- 失败原因后面贴一次 Lua 池水位 (used/total, 约 20 字节)。
--   为什么只在失败路径贴: 11-12/11-13 现场反复出现同一句假话 ——
--     E/mem memory allocation failed total 307192, used 302680, alloc 160
--     E/user.cfg poll read fail: 分片4解码失败
--   连 160 字节都拿不到的时候, json.decode 是【回 nil】而不是抛的(这台 bsp
--   的 C 层就这样), 于是"池子不够"被报成"flash 里那段内容坏了"。同一段前后
--   都读得出来, 内容根本没坏。光说"解码失败"排查方向直接被带偏到 flash 上,
--   带上水位这一眼就分得清是哪种。
--   ⚠️ rtos.meminfo 的顺序是 (total, used, 峰值) —— 和 svc/cmd.lua 的
--   R:MEM 同一个口径, 别在这里换成 (used, total) 反着报
local function pool_tag()
    if not rtos then return "" end
    local ok, total, used = pcall(rtos.meminfo, "lua")
    if not ok or type(total) ~= "number" or type(used) ~= "number" then return "" end
    return "(池 " .. math.floor(used) .. "/" .. math.floor(total) .. ")"
end

-- 读一个槽的原文, 把【读不出来】和【没写过】分开。
--   ⚠️ 为什么单列这一步: 老固件留下的 ds_poll 是整份配置一大块(现场实测
--   3791B), 而池子高水位时只给得出 2048 —— 那一次 fskv.get 是【抛异常】的,
--   不是返回 nil。原来的 kv_get 把两者一起变成 nil, 于是"槽里明明有 56 行"
--   被读成"从没配过"(11-12 现场第二个假话)。poll_src 那一族更糟: 它直接
--   fskv.get, 抛出来没人接, 一路冒到 prov 的 pcall 才算停。
-- 返回 (值或 nil, 原因或 nil)
local function kv_read(k)
    if not fskv then return nil, nil end
    local ok, v = pcall(fskv.get, k)
    if not ok then return nil, "读不出来: " .. brief(v) end
    if v == nil or v == "" then return nil, nil end
    return v, nil
end

local function kv_get(k)
    return (kv_read(k))
end

-- ⚠️ 12-fix-3 (2026-10-28): 配置解码缓存。必须声明在 kv_set 之前 ——
--   Lua 的 local 只能看到它【之前】的声明, 晚声明的话 kv_set 里那次
--   json_cache[k] = nil 会写到全局表上, 缓存永远不失效。
local json_cache = {}   -- fskv key -> 解码后的原始表

-- 12-fix-9 (2026-10-29): 配置版本号。写盘就 +1。
--   给别的模块当缓存键用(别名映射一天可能只改一次, 不该每次 R:INFER
--   都重建一遍 128 条的映射表 —— 那是十几 KB 的垃圾/次)。
local cfg_ver = 0

function M.version() return cfg_ver end

-- 放掉【解码缓存】这一堆引用, 不动 fskv、不动版本号。2026-11-13 为 W:CBEGIN 加的。
--   为什么是它: 轮询中池子只剩 max:1024 的连续块, 一整行配置在【被拼出来之前】
--   就接不住(现场 drop 1177B / drop 4072B 都是死在这儿)。上传前得先腾水, 而
--   现场最大的一块水就是这份缓存 —— 它装着整份配置的解码表 + 各分片的原始
--   JSON 串, 60 行是十几 KB, 且缓存的正是"马上要被换掉的那份"。
--   语义和写盘后 kv_set 里那次 json_cache[k]=nil 是同一件事, 只是提前到"还没写"。
--   不清版本号: fskv 里内容没变, 涨版本号等于让所有下游缓存白失效一遍。
--   代价: 下一次 load_* 要重读 fskv 再解一次 —— 那本来就是腾完水之后才做得动
--   的事(而且 W:CBEGIN 之后紧接着就是提交新配置, 这份旧表多半根本不会再读)。
-- 返回放掉的项数, 只给日志看。
function M.drop_cache()
    local n = 0
    for k in pairs(json_cache) do
        json_cache[k] = nil
        n = n + 1
    end
    return n
end

-- fskv 单值硬顶 4096B。超限 (以及 flash 空间不足) 时 C 层只打一行
--   E/fskv value too big N max 4096 然后【返回 false】, 不 raise —— 所以
--   pcall 那一关是过的。原来 kv_set 只看 pcall 的 ok, 把"没写进去"当成
--   "写好了": 前端收到 RET:CFG=OK, poll 起来的却是 fskv 里的旧值/空表。
-- 判失败只认【明确的 false】: 万一某版 bsp 的 fskv.set 成功时不返值,
--   写成 not ret 会把所有正常保存都判成失败。
local FSKV_VALUE_MAX = 4096

local function kv_set(k, s, noflush)
    if not fskv then return false, "no fskv" end
    local n = type(s) == "string" and #s or 0
    if n > FSKV_VALUE_MAX then
        log.warn("cfg", "value too big", k, n, "max", FSKV_VALUE_MAX)
        return false, "配置 " .. n .. "B 超 fskv 单值上限 " .. FSKV_VALUE_MAX .. "B"
    end
    local ok, ret = pcall(fskv.set, k, s)
    if not ok or ret == false then
        log.warn("cfg", "fskv.set failed:", k, n .. "B", brief(ret))
        -- 原因必须一起带回应答里: 只报"拒写"前端分不清是超限还是内存不足。
        --   11-12 现场 3774B(远小于 4096)保存失败, 真原因是 C 层 raise 的
        --   "not enough memory for buffer allocation" —— 那句话原先只进设备日志。
        return false, "fskv.set 拒写(值 " .. n .. "B): " .. brief(ret)
    end
    -- 只有真写进去了才动缓存/版本号: 写失败时 fskv 里的内容没变,
    -- 清缓存+涨版本号等于白让所有下游解码缓存失效一遍
    json_cache[k] = nil   -- 12-fix-3: 写盘了, 解码缓存必须失效
    cfg_ver = cfg_ver + 1 -- 12-fix-9: 版本号跟着涨(别名映射缓存靠它失效)
    -- noflush: 分片写要连写好几个键, 逐键 flush 等于一次保存擦一遍 flash。
    --   中间各段传 true, 由 shards_save 在"提交"那一下统一 flush
    if fskv.save and not noflush then pcall(fskv.save) end
    return true
end

-- ⚠️ 12-fix-3 (2026-10-28): 配置解码缓存。
--   原来 load_poll/load_pull/load_alias 每次调用都要
--   fskv.get(整份 JSON 串) + json.decode(整张表) —— 一份 128 条的配置
--   ≈ 12.7KB 字符串 + 22.5KB 解码表 ≈ 35KB 垃圾/次。
--   而 iot 的 build_items() 一次调用里就要反序列化 3~4 遍
--   (active_cfg ×2 + cfgstore.alias_map ×1~2), 且 publish 因为 S.dirty
--   被设成【每秒一次】→ 每秒上百 KB 垃圾, 比整个 Lua 堆(300KB)还大。
--   这正是"总空闲还有 40KB 却申请不到 3KB 连续块"的来源(碎片化),
--   也是 2026-10-28 现场 sniff 崩溃的帮凶之一。
--
--   ⚠️ 只缓存【解码后的原始表】, 归一化(normalize)仍然每次跑:
--      缓存的原始表是只读的(这点很重要 —— poll.lastCfg 就长期持有
--      load_poll() 的结果, 各调用方拿到各自独立的一份, 改它不会串味)。
--      ⚠️ 唯一的例外: normalize_poll(c, true) 会原地改 c, 那是 W:CFG 给
--      自己 jdecode 出来的私有表用的(省掉 13KB 第二份, 见该函数注释)。
--      从缓存出来的 raw 一律按【一个参数】调用, 传第二参数的地方必须
--      先确认那张表不在任何缓存里。
--   ⚠️ 写盘(kv_set / reset_user / clear_pull)必须清缓存。

-- ====================== 分片存储 (2026-11-12) ======================
-- 为什么要拆段: 真机量到的是【两堵墙叠在一起】, 而且第二堵才是致命的。
--   ① fskv 单值 4096B 硬顶 —— 128 点整份 JSON ≈ 8.6KB, 一个键装不下。
--   ② 连续块: 56 点跑起来之后 R:MEM 实测 max 只剩 2048B(八条读数一模一样),
--      可"读一次配置"要 fskv.get 出一整块 3791B、"写一次"要 json.encode 出
--      同样大的一整块。11-12 现场三个后果全从这里来:
--        R:CFG     → RET:FAIL:CFG:内存/内部异常: not enough memory(配置读不回)
--        W:MODE=idle → alloc 3791 raise 被 pcall 吃掉, 回 OK 却没清掉
--        W:CFG 导入  → prov.lua:190 rx_merge 的 concat OOM → Lua VM exit
--      同一天 W:FS 证明 littlefs 能写(B:YES, 108K/128K), 但高水位那次
--      string.rep(8192) 直接 FAIL —— 【换介质没用】, littlefs 的 read("*a")
--      照样要一整块。唯一的出路是让每一次分配都不超过一段。
-- 段宽为什么是 1024 而不是贴着 2048: 那 2048 是最坏读数的上限, 段内还要
--   放解码出来的行表本身; 留一半余量。行宽有 normalize 兜着(validate_reg),
--   单行不会超, 所以"行数上限 + 字节上限"两个闸门里字节闸先行。
-- 写序(不能省): header(st="w", n=N) → 各段 → header(st="r", n=N)。
--   断电停在任何一步, 读侧看见 st~="r" 就知道这份配置不完整, 报原因而不是
--   拿半套寄存器表去起轮询。代价是多一次小写, 换来"保存一半不坏"。
--   ⚠️ 中途【写失败】(段写不进去)也是同一条路: 老 header 已经被 st=w 顶掉,
--   前面几段又已经换成新内容 —— 这时候回滚救不回来(旧段已经没了), 唯一不能
--   丢的是"说出来"。所以宁可下一次读取报"分片未提交", 也不能把新旧混在一起
--   当有效配置: 用户会看见设备在采一批他从来没配过的地址。
local SHARD_ROWS = 16
local SHARD_MAX = 1024
local SHARD_VER = 1
local SHARD_W, SHARD_R = "w", "r"

local function shard_key(k, i) return k .. "." .. i end

local function dec_json(s)
    if not s or not json then return nil end
    local ok, t = pcall(json.decode, s)
    if ok and type(t) == "table" then return t end
    return nil
end

-- "是不是分片格式"只看 header 那两个字段: 老的整份配置里没有 v, 所以这个
--   判断一次段都不用读。返回 (段数, st) 或 nil
local function shard_of(h)
    if type(h) ~= "table" or h.v ~= SHARD_VER then return nil end
    local n = tonumber(h.n)
    if not n then return nil end
    return math.floor(n), tostring(h.st)
end

-- 逐段取回, 拼成 t.regs。失败一律带原因回来 —— 调用方必须把原因传出去,
--   不许再退回"当成没写过"那条老路(那就是 11-12 那两个假话的根)
local function shards_load(k, t)
    local n, st = shard_of(t)
    if st ~= SHARD_R then
        return nil, "分片未提交(应有 " .. n .. " 段, st=" .. st .. ")"
    end
    if not fskv then return nil, "fskv 不可用, 段取不到" end
    local rows = {}
    for i = 1, n do
        -- 这里不用 kv_get: 它把"读不出来(raise)"和"没写过(\"\")"并成 nil。
        --   段只有 1KB, 正常情况下两者都不会发生, 真发生时"分片不全"和
        --   "分片读不出来"是两个不同的排查方向, 别让人往"flash 掉了"上查
        local ok, cs = pcall(fskv.get, shard_key(k, i))
        if not ok then return nil, "分片" .. i .. "读不出来: " .. brief(cs) end
        if cs == nil or cs == "" then return nil, "分片不全(" .. (i - 1) .. "/" .. n .. ")" end
        local ct = dec_json(cs)
        if ct == nil then return nil, "分片" .. i .. "解码失败" .. pool_tag() end
        for j = 1, #ct do rows[#rows + 1] = ct[j] end
    end
    t.regs = rows
    return t
end

local function put_json(k, v, noflush)
    local ok, s = pcall(json.encode, v)
    if not ok then return false, "encode fail: " .. brief(s) end
    if not s then return false, "encode fail(无返回)" end
    if #s > FSKV_VALUE_MAX then
        return false, "段 " .. #s .. "B 超 fskv 单值上限 " .. FSKV_VALUE_MAX .. "B"
    end
    return kv_set(k, s, noflush)
end

-- 按行收段: 每行先单独 encode 量一次尺寸(几百字节的小分配), 够了就封段。
--   段字节由 json.encode(整段) 再产一次 —— 一次分配正好一个段宽。
local function shards_save(k, t)
    local rows = (type(t.regs) == "table") and t.regs or {}
    local segs, cur, cur_sz = {}, {}, 2
    local function close_seg()
        if #cur == 0 then return true end
        segs[#segs + 1] = cur
        cur, cur_sz = {}, 2
        return true
    end
    for i = 1, #rows do
        local ok, e = pcall(json.encode, rows[i])
        -- ⚠️ "encode fail" 这个前缀和 save_json 那边一样, 一个字都不能动:
        --   上位机(sn-tools/pc_tool)按它认这条失败。分片把一次大编码拆成
        --   逐行小编码, 失败点挪了, 认法不能跟着挪
        if not ok then return false, "encode fail: " .. brief(e) end
        if not e then return false, "encode fail(无返回)" end
        -- 加这行会撑破段宽(或撑破行数)就先封段, 再把它起成新段的第一行
        if #cur > 0 and (cur_sz + #e + 1 > SHARD_MAX or #cur >= SHARD_ROWS) then
            close_seg()
        end
        cur[#cur + 1] = rows[i]
        cur_sz = cur_sz + #e + (#cur > 1 and 1 or 0)
    end
    close_seg()

    local n = #segs
    local head = {}
    for key, val in pairs(t) do
        if key ~= "regs" then head[key] = val end
    end

    -- 旧段数(只为回收残段): 上一份本来就是分片才有, 老格式/没写过就是 0
    local old_n = 0
    local oh = dec_json(kv_get(k))
    if oh then
        local on = shard_of(oh)
        if on and on > 0 then old_n = on end
    end

    head.v, head.n, head.st = SHARD_VER, n, SHARD_W
    local ok1, err1 = put_json(k, head, true)
    if not ok1 then return false, err1 end
    for i = 1, n do
        local ok2, err2 = put_json(shard_key(k, i), segs[i], true)
        if not ok2 then
            return false, "分片" .. i .. "/" .. n .. "写入失败: " .. tostring(err2)
        end
    end
    head.st = SHARD_R
    local ok3, err3 = put_json(k, head) -- 提交: 只有这一次 flush
    if not ok3 then return false, "分片提交失败: " .. tostring(err3) end

    -- 残段(n < old_n 时多出来的那几把)清掉。读侧只认 header 里的 n, 所以
    --   残段不影响正确性, 但会白占 fskv 空间; 清失败也不该让保存失败
    for i = n + 1, old_n do pcall(fskv.set, shard_key(k, i), "") end
    return true
end

local function load_json(k, default, shard)
    local cached = json_cache[k]
    if cached ~= nil then return cached end
    local s, rerr = kv_read(k)
    if rerr then
        -- 读不出来 = 这一次没法知道槽里有什么。不缓存(缓存了等于把一次瞬时的
        --   内存不足固化成"这台设备从没配过"), 把原因原样交回调用方
        return nil, rerr
    end
    if not s or not json then
        json_cache[k] = default
        return default
    end
    local t = dec_json(s)
    if t == nil then
        log.warn("cfg", "decode fail", k)
        json_cache[k] = default
        return default
    end
    -- 没开分片、或者那份还是老的"整份 JSON 一个键": 原样返回。老格式不做
    --   双写兼容层 —— 读到就用, 下一次保存自然迁成分片, 迁移期最长一次保存
    -- ⚠️ 这一整步【必须包在 pcall 里】: 判断"是不是分片"要读 header 的字段,
    --   而读字段这一步在池子见底时一样会 raise。load_json 的调用方里
    --   main.lua 是【开机】用的, 抛出去等于设备起不来(以前 raise 只可能发生在
    --   归一化里, 那一层有 pcall 兜着)
    local pok, c, perr = pcall(function()
        if not shard or not shard_of(t) then return t end
        return shards_load(k, t)
    end)
    if not pok then
        -- raise: 连"这是不是分片"都没判出来。这和"配置内容非法"是两句话,
        --   用和归一化异常同一个标签, 现场看到就知道是池子的问题不是表的问题
        return nil, "内存/内部异常: " .. brief(c)
    end
    if c == nil then return nil, perr end
    json_cache[k] = c
    return c
end

local function save_json(k, t, shard)
    if not json then return false, "no json lib" end
    if shard then return shards_save(k, t) end
    local ok, s = pcall(json.encode, t)
    -- ⚠️ "encode fail" 这个前缀一个字都不能动: 上位机按它认这条失败。
    --   后面必须跟真原因 —— 11-12 现场第二次保存死在这里(不是 fskv):
    --     used 298576/307192, json.encode 要一块 3791B 连续块拿不到,
    --   设备日志打了 E/mem, 应答却只有光秃秃一句 encode fail。
    --   encode 有两种失败: raise(内存) / 不 raise 只回 nil(内容编码不了), 分开报
    if not ok then return false, "encode fail: " .. brief(s) end
    if not s then return false, "encode fail(无返回)" end
    -- 上限必须和 prov.lua 的 MAX_BUF 对齐: W:CFG 是【一整行】下发,
    -- 行超过 MAX_BUF 会被整缓冲丢弃, 存得下也传不过来。
    -- 128 条寄存器最坏约 12.7KB, 两侧都取 16KB。
    -- 曾设 512, 结果 5 个寄存器就超限, W:CFG 一直回 too large,
    -- 前端只看到"保存失败"却查不出原因
    if #s > 16384 then return false, "too large" end
    return kv_set(k, s)
end

M.default_poll = {
    baud = cfg.BAUD,
    databits = cfg.DATABITS,
    stopbits = cfg.STOPBITS,
    parity = cfg.PARITY,
    slave = cfg.SLAVE_ADDR,
    interval_ms = cfg.POLL_INTERVAL_MS,
    timeout_ms = cfg.TIMEOUT_MS,
    regs = cfg.REG_DEFAULT,
}

M.default_sys = { boot_mode = MODE_IDLE }

-- sniff 推断表持久化默认值 (2026-11)
M.default_infer = {
    baud = cfg.BAUD,
    databits = cfg.DATABITS,
    stopbits = cfg.STOPBITS,
    parity = cfg.PARITY,
    slave = cfg.SLAVE_ADDR,
    regs = {},
}

-- 别名表上限: 推断出来的寄存器地址不会太多, 128 条足够覆盖现场, 也能挡住
-- 异常输入把 fskv 撑爆
local MAX_ALIAS = 128

M.default_alias = { regs = {} }

-- sniff 别名表归一化。结构 { regs = { {key="reg263", id="CT1", name="A相电流"} } }
--   key 只认 reg<addr>; id/name 都空 = 删除该条
function M.normalize_alias(c)
    c = c or {}
    local out = { regs = {} }
    local seen = {}
    local regs = c.regs
    if type(regs) == "table" then
        for _, r in ipairs(regs) do
            if type(r) == "table" then
                local key = str(r.key, "")
                if key:match("^reg%d+$") then
                    local id = str(r.id, "")
                    local nm = str(r.name, "")
                    if id ~= "" or nm ~= "" then
                        if #id > 64 then return nil, "alias id 太长(64 字符内)" end
                        if #nm > 64 then return nil, "alias name 太长(64 字符内)" end
                        if not seen[key] then
                            seen[key] = true
                            out.regs[#out.regs + 1] = { key = key, id = id, name = nm }
                            if #out.regs > MAX_ALIAS then return nil, "别名条数过多" end
                        end
                    end
                end
            end
        end
    end
    return out
end

-- 别名表查表: key -> {id,name}, 供 iot 上报时套用
-- ⚠️ 12-fix-9 (2026-10-29): 结果【缓存】。
--   原来每次调用都新建这张表: 最多 128 条 → 128 张 {id,name} 小表 + 一张
--   哈希表 ≈ 15KB 垃圾/次, 外加 load_alias() 的归一化表。
--   而 attach_names 每次 R:INFER 都要调它 —— 现场(09:14~09:19)前端连着
--   点刷新, 一次调用就制造几十 KB 短命垃圾, 把 300KB 的堆打成碎片
--   → "alloc 8147 failed" → json encode out of memory → 整机卡死。
--   别名表一天可能只改一次(前端改名), 缓存到写盘(cfg_ver 变)时失效。
local alias_map_cache = nil
local alias_map_ver = -1

function M.alias_map()
    local v = cfg_ver
    if alias_map_cache and alias_map_ver == v then return alias_map_cache end
    local m = {}
    local c = M.load_alias()
    for _, r in ipairs((c and c.regs) or {}) do
        m[r.key] = { id = r.id, name = r.name }
    end
    alias_map_cache = m
    alias_map_ver = v
    return m
end

-- 别名表单条 upsert (2026-10): 前端弹窗保存走这里; id/name 都空 = 删这条
function M.set_alias(key, id, name)
    local c = M.load_alias()
    local out = { regs = {} }
    local found = false
    for _, r in ipairs((c and c.regs) or {}) do
        if r.key == key then
            found = true
            if id ~= "" or name ~= "" then
                out.regs[#out.regs + 1] = { key = key, id = id, name = name }
            end
        else
            out.regs[#out.regs + 1] = r
        end
    end
    if not found and (id ~= "" or name ~= "") then
        out.regs[#out.regs + 1] = { key = key, id = id, name = name }
    end
    return M.save_alias(out)
end

-- 清空别名表 (2026-10, A 方案): 离开 sniff / 新一轮识别时调用。
-- 名字是"这一轮推断结果"的注解: 新一轮的地址可能都变了, 留着旧名字会张冠李戴
-- ⚠️ 表本来就是空时【不写 fskv】: flash 擦写次数有限, 而"退出已清"之后
--    "进入再清"这种兜底调用就不该再擦一次
function M.clear_alias()
    local c = M.load_alias()
    if not c or not c.regs or #c.regs == 0 then return true end
    return M.save_alias({ regs = {} })
end

-- reuse=true: 【原地】把 r 收拾成归一化行并返回 r 本身, 不再新建一张表。
--   两条路径的键集合必须完全一致(addr/count/dtype/name/alias 五个) ——
--   W:CFG 走原地, 落进 fskv 的 JSON 不能比新建路径变长, 所以先把五个值
--   读进局部变量, 再清空整张表(顺带把用户多塞的键一起丢掉), 再写回去。
local function normalize_reg(r, reuse)
    if type(r) ~= "table" then return nil, "not table" end
    -- 范围/格式校验委托给 util.validate_reg(抽离后 ds_poll/ds_pull 共享)
    local ok, why = util.validate_reg(r)
    if not ok then return nil, why end
    local addr, count = num(r.addr), num(r.count, 1)
    local dtype, name = str(r.dtype, "uint16"), r.name
    local alias = str(r.alias, r.name)
    if not reuse then
        return { addr = addr, count = count, dtype = dtype, name = name, alias = alias }
    end
    for k in pairs(r) do r[k] = nil end
    r.addr, r.count, r.dtype, r.name, r.alias = addr, count, dtype, name, alias
    return r
end

local function normalize_common(c, d)
    c = c or {}
    return {
        baud = math.floor(num(c.baud, d.baud)),
        databits = math.floor(num(c.databits, d.databits)),
        stopbits = math.floor(num(c.stopbits, d.stopbits)),
        parity = math.floor(num(c.parity, d.parity)),
    }
end

-- inplace=true: 在 c 上【原地】归一化并返回 c。
-- ⚠️ 只给"这张表本来就是调用方私有的"路径用(目前只有 svc/cmd.lua 的 W:CFG:
--    那里的 t 是 json.decode 现解的, 不进任何缓存)。load_poll/load_pull
--    走的是 SECTIONS 里的 pcall(sec.norm, raw) —— 只有一个参数, 永远是纯函数,
--    因为 raw 是 12-fix-3 那张解码缓存, 归一化改它会串味到后续所有读取。
-- ⚠️ 校验失败时 c 已被改成半份(寄存器表逐行原地收拾, 中途出错就停在半途)。
--    W:CFG 出错就地 RET:FAIL 并把 t 丢掉, 不会拿半份表去落盘, 所以不用回滚。
function M.normalize_poll(c, inplace)
    -- 先把输入值全读进局部变量: 原地路径下面要把 c 清成空表再填回去
    local baud = math.floor(num(c.baud, M.default_poll.baud))
    local databits = math.floor(num(c.databits, M.default_poll.databits))
    local stopbits = math.floor(num(c.stopbits, M.default_poll.stopbits))
    local parity = math.floor(num(c.parity, M.default_poll.parity))
    local slave = math.floor(num(c.slave, M.default_poll.slave))
    local interval = math.floor(num(c.interval_ms, M.default_poll.interval_ms))
    local timeout
    -- timeout_ms 允许留空(null)= 早返回模式: 收到响应立刻走下一事务,
    -- 不等满超时。字段名与前端一致(前端 collectCfg 下发 timeout_ms)
    if c.timeout_ms ~= nil then
        timeout = math.floor(num(c.timeout_ms, M.default_poll.timeout_ms))
    end
    local regs = c.regs
    if slave < 1 or slave > 247 then return nil, "bad slave" end
    if interval < 100 then return nil, "bad interval" end
    if timeout and (timeout < 50 or timeout > 500) then
        return nil, "响应上限越界(50~500ms)"
    end
    local out = inplace and c or {}
    if inplace then
        for k in pairs(c) do c[k] = nil end
    end
    out.baud, out.databits, out.stopbits, out.parity = baud, databits, stopbits, parity
    out.slave = slave
    out.interval_ms = interval
    out.timeout_ms = timeout
    local is_list = (type(regs) == "table")
    local dst = (inplace and is_list) and regs or {}
    local seen = {}
    local kept = 0
    if is_list then
        local cnt = #regs
        for i, r in ipairs(regs) do
            local nr, err = normalize_reg(r, inplace)
            if not nr then return nil, err end
            if kept > cfg.MAX_REGS then return nil, "too many regs" end
            -- 同 addr 只留首条。平台的 properties 实测会把同一属性发两遍
            -- (2026-10-08 日志: skipped 里 reg_100/reg_250 各出现两次),
            -- 原样存进重复项, 切 pollpull 后同一帧重复读, 白占总线时间
            if not seen[nr.addr] then
                seen[nr.addr] = true
                kept = kept + 1
                dst[kept] = nr
                if inplace and kept < i then regs[i] = nil end
            end
        end
        -- 丢过重复项要把尾巴截掉, 否则 #regs 比 kept 大、后面还挂着空位
        if inplace then
            for i = kept + 1, cnt do regs[i] = nil end
        end
    end
    out.regs = dst
    return out
end

-- sniff 推断表归一化 (2026-11)。结构:
-- { baud, databits, stopbits, parity, slave, regs: [{addr, count, fc, dtype, name, id}] }
local function normalize_infer_reg(r)
    if type(r) ~= "table" then return nil end
    local addr = num(r.addr, nil)
    if not addr or addr < 0 or addr > 65535 then return nil end
    local count = num(r.count, 1)
    if count < 1 or count > 125 then count = 1 end
    local fc = num(r.fc, 3)
    if fc ~= 3 and fc ~= 4 then fc = 3 end
    return {
        addr = math.floor(addr),
        count = math.floor(count),
        fc = math.floor(fc),
        dtype = str(r.dtype, "uint16"),
        name = str(r.name, ""),
        id = str(r.id, ""),
    }
end

function M.normalize_infer(c)
    c = c or {}
    local out = normalize_common(c, M.default_infer)
    out.slave = math.floor(num(c.slave, M.default_infer.slave))
    if out.slave < 1 or out.slave > 247 then return nil, "bad slave" end
    out.regs = {}
    local seen = {}
    local regs = c.regs
    if type(regs) == "table" then
        for _, r in ipairs(regs) do
            local nr = normalize_infer_reg(r)
            if nr then
                local key = nr.addr
                if not seen[key] then
                    seen[key] = true
                    out.regs[#out.regs + 1] = nr
                    if #out.regs > MAX_ALIAS then break end
                end
            end
        end
    end
    return out
end

function M.normalize_sys(c)
    c = c or {}
    local mode = str(c.boot_mode, MODE_IDLE):lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- 记录 3: 限 4 值 (idle/manual/platform/sniff)。删 poll/pollpull 历史别名:
    -- 项目测试阶段, 不存在老 fskv 兼容, 直接报 bad boot_mode 让用户重置。
    if mode ~= MODE_IDLE and mode ~= MODE_MANUAL and mode ~= MODE_PLATFORM and mode ~= MODE_SNIFF then
        return nil, "bad boot_mode"
    end
    return { boot_mode = mode }
end

-- 三套配置(poll/pull/sys)的读写除键/归一化/默认值外完全同构,
-- 表驱动避免两处要同步改。load 失败静默退回(启动路径崩设备起不来),
-- save 失败必须把原因带回去给 W:CFG 显示
--
-- shard=true 的规则: 【装寄存器表的那几个槽】才分片。poll/pull/infer 三段的
--   norm 产物都带 regs 数组, 长度随现场点数走 —— 128 点整份 JSON ≈ 8.6KB,
--   既是 fskv 单值 4096 顶唯一会被撞的对象, 也是"读一次要一整块连续内存"
--   唯一躲不开的对象(见上面分片那一大段)。
--   ds_sys 只有一个 boot_mode、ds_alias 已标"待废弃"(推断表行里自带
--   name/id), 分片只是多两次写、给一段没人用的代码加迁移, 不动。
local SECTIONS = {
    poll = { key = K_POLL, norm = M.normalize_poll, default = M.default_poll, shard = true },
    pull = { key = K_PULL, norm = M.normalize_poll, default = M.default_poll, shard = true },
    sys = { key = K_SYS, norm = M.normalize_sys, default = M.default_sys },
    alias = { key = K_ALIAS, norm = M.normalize_alias, default = M.default_alias },
    infer = { key = K_INFER, norm = M.normalize_infer, default = M.default_infer, shard = true },
}

for name, sec in pairs(SECTIONS) do
    M["load_" .. name] = function()
        local raw, serr = load_json(sec.key, {}, sec.shard)
        if serr then
            -- 段没取齐/还没提交。这时 flash 里那几行很可能一个字没坏, 只是
            --   拼不出来 —— 这句话必须原样传出去, 混进"配置坏了"就等于骗用户
            --   (11-12 现场那个"我填的 56 行消失了"就是这么来的)。
            --   原因原文自己带阶段名("分片不全(2/4)" / "内存/内部异常: ..."),
            --   这里不再加前缀: 加了就等于替分片之外的那两类失败也署上"分片"
            log.error("cfg", name, "read fail:", brief(serr))
            return sec.default, brief(serr)
        end
        local ok, c, err = pcall(sec.norm, raw)
        if ok and c then return c end
        -- ⚠️ 两种失败【话不一样】, 不能混成一句"配置坏了"(2026-11-12 现场):
        --   ok==false      = 归一化【抛异常】。那次是 used 304848/307192 时连
        --                    160B 都分配不出来 —— flash 里那 56 行一个字没少。
        --   ok==true,c==nil = 归一化【判非法】, err 是原因, 存的内容真有问题。
        -- 两种都回默认值(main.lua 靠这个起机, 回 nil 等于设备起不来), 但把原因
        -- 作为【第二个返回值】交给调用方。以前只打一行 warn 就把 default 当设备
        -- 配置返回, R:CFG 于是把"池子不够"报成"这份配置坏了/是空的",
        -- 用户看到的是"我填的 56 行消失了"。
        if not ok then
            log.error("cfg", name, "normalize raised:", brief(c))
            return sec.default, "内存/内部异常: " .. brief(c)
        end
        log.warn("cfg", name, "normalize fail, use default")
        return sec.default, tostring(err)
    end
    M["save_" .. name] = function(c)
        local n, err = sec.norm(c)
        if not n then return false, err end
        return save_json(sec.key, n, sec.shard)
    end
    -- 落盘【已经归一化过】的表。W:CFG 大配置(128 点)必须先 normalize 一遍
    --   校验、再落盘、再拿同一份去 apply_cfg; 走 save_xxx 会在里面再
    --   normalize 一次 —— 那 128 个寄存器表(~30KB)白造一遍, 池子只剩几 KB
    --   时就是压死的一根。n 已是 norm 的产物, 落盘内容和 save_xxx 逐字节相同
    M["save_" .. name .. "_norm"] = function(n)
        return save_json(sec.key, n, sec.shard)
    end
end

-- 三个 src 函数共用的一格: "这个槽到底算不算写过"。
--   ⚠️ 原来每个函数都是裸 fskv.get —— 老固件那份整块配置在最坏水位下
--   get 直接 raise, 冒到调用方(cmd.lua 的 R:CFG、main.lua 的开机日志)算运气好,
--   冒到 prov 那层就是把整条命令打成 internal error。现在一律走 kv_read,
--   读不出来时返回值是 "read-fail"(前端契约只看 =="fskv", 多出来的这一格
--   不会把老前端判成别的), 第二格带原因
local function src_of(k)
    local v, why = kv_read(k)
    if why then return "read-fail", why end
    if not v then return "default" end
    return "fskv"
end

-- 配置来源: fskv 里从未写过就是 default(前端据此提示"尚未保存过配置")
function M.poll_src() return (src_of(K_POLL)) end

-- ds_pull 是否拉过平台配置。前端据此判断"拉取配置"档能不能直接起轮询
-- (没拉过就必须先走 hello 拉一次, 否则拿 default 去轮询等于凭空造一套寄存器表)
function M.pull_src() return (src_of(K_PULL)) end

-- ds_infer 是否写过
function M.infer_src() return (src_of(K_INFER)) end

-- 34-fix: 槽里是否真有可轮询的配置。
--   仅 src=="fskv" 还不够, 万一上层把空配置(regs={})写进去就骗过这一道。
--   用 #regs>0 才算"有东西可采"; 串口参数(baud/slave/...)总是有默认值的,
--   不是判断依据, 真正决定"轮询一跑就能出活"的是寄存器表
--   用途: ctrl.switch_mode 看到这个为 false 就跳过 poll.start,
--   省掉"空配置下 for 循环空跑 + 喂狗误报"那一串副作用
--
-- ⚠️ 第二个返回值 = "想读却读不出来"的原因, 和"确实没配过"是两件事
--   (2026-11-12 现场: manual 档那句 "poll 槽空, 暂不起轮询" 是假的 ——
--   flash 里 56 行一个字没少, 是 used 304K 时 load_poll 抛了内存异常,
--   原因躺在第二个返回值上没人接, 于是被读成了"空槽")
function M.has_poll_cfg()
    local src, why = src_of(K_POLL)
    if src == "default" then return false end
    if src ~= "fskv" then return false, why end
    local c, w2 = M.load_poll()
    if w2 then return false, w2 end
    return c and #(c.regs or {}) > 0
end

function M.has_pull_cfg()
    local src, why = src_of(K_PULL)
    if src == "default" then return false end
    if src ~= "fskv" then return false, why end
    local c, w2 = M.load_pull()
    if w2 then return false, w2 end
    return c and #(c.regs or {}) > 0
end

-- sniff 推断表是否有持久化配置 (2026-11)
function M.has_infer_cfg()
    local src, why = src_of(K_INFER)
    if src == "default" then return false end
    if src ~= "fskv" then return false, why end
    local c, w2 = M.load_infer()
    if w2 then return false, w2 end
    return c and #(c.regs or {}) > 0
end

-- 哪些槽是分片存的 —— 从 SECTIONS 推出来, 不在第二处重写一遍规则
local SHARDED = {}
for _, sec in pairs(SECTIONS) do SHARDED[sec.key] = sec.shard end

-- 清掉一个槽(连分片一起)。返回 (真清掉了, 原因)。
--
-- ⚠️ 为什么要分得这么细: 老写法是
--     local ok, v = pcall(fskv.get, k)
--     if ok and v ~= nil and v ~= "" then ... end
--   "读不出来"(OOM raise, ok=false)和"本来就空"(v=="")被并成同一个分支,
--   于是 11-12 现场 used 292688 那次切 idle 回了 RET:MODE=OK;cleared:mqtt_manual,
--   而 flash 里那 56 行一个字没少 —— 用户以为清了, 下次进 manual 起的还是旧表。
--
-- 为什么现在读得出段数: header 只有一两百字节, 老的这一步要 fskv.get 出
--   一整块 3791B(整份配置的字节数), 在最坏水位(max 只剩 2048)下必然失败。
--   分片把这一步的分配尺寸打回 header 大小, 这一类失败跟着消失。
local function slot_clear(k, shard)
    local ok, v = pcall(fskv.get, k)
    if not ok then return false, "读不出来: " .. brief(v) end
    if v == nil or v == "" then return false, nil end
    local n = 0
    if shard then
        local h = dec_json(v)
        local hn = h and shard_of(h)
        if hn and hn > 0 then n = hn end
    end
    local sok, serr = pcall(fskv.set, k, "")
    if not sok then return false, "清不掉: " .. brief(serr) end
    json_cache[k] = nil   -- 12-fix-3: 绕过了 kv_set, 缓存要手动失效
    cfg_ver = cfg_ver + 1 -- 12-fix-9: 版本号也要涨(别名映射缓存靠它失效)
    for i = 1, n do
        pcall(fskv.set, shard_key(k, i), "")
        json_cache[shard_key(k, i)] = nil
    end
    return true
end

-- 切回 idle 时的 485 复位: 擦掉用户改过的痕迹, 回到"从没存过配置"的状态。
-- 返回真正清掉的槽名(没写过的槽不出现), 由调用方拼进 W:MODE 应答给前端看。
--
-- 为什么用 fskv.set(k,"") 而不是 fskv.del: kv_get / poll_src / pull_src 都把
-- "" 当"没写过", 语义完全够; 而 del 在某些 LuatOS 版本上不存在, 为一行复位
-- 引入兼容性风险不划算。
--
-- ⚠️ ds_pull 必须一起清, 不清有功能危害: ctrl.switch_mode 的 pollpull 分支靠
--    pull_src()=="default" 决定进模式时要不要先 hello 拉一次平台配置。留着旧的
--    ds_pull 会让它跳过拉取、直接拿旧配置起轮询 —— 用户以为平台的新配置已经
--    生效, 其实采的还是上一轮那份。
--
-- ⚠️ 刻意不碰 ds_sys: boot_mode 是"开机该进什么模式"的意愿, 不是配置内容。
--    清了它下次开机又不 idle, 和设备已经 idle 的事实矛盾。
-- 记录 A: 改友好名, 切 idle 时 W:MODE 应答 cleared 给用户看的字面。
-- 显示名 (前) 是给用户看的; 键名 (后 K_POLL/K_PULL) 是 cfgstore 内部槽名, 保留
-- "poll"/"pull" (项目内部 API, 删了工作量大, 收益小 — 跟记录 3 Q2 决策)。
local RESET_SLOTS = {
    { "manual 配置", K_POLL },
    { "platform 配置", K_PULL },
    { "sniff 推断表", K_INFER },  -- 2026-11: 切 idle 时一起清
}

-- 第二个返回值 failed: 想清却没清掉的槽(原因在里面)。调用方必须把它带到
--   应答里去 —— 少这一句, "清了"和"没清动"在用户那边长得一模一样
function M.reset_user()
    local cleared, failed = {}, {}
    if not fskv then return cleared, failed end
    for _, s in ipairs(RESET_SLOTS) do
        local name, k = s[1], s[2]
        -- 只清"写过"的槽: 没写过的槽也清一遍等于白写 fskv + 多一次 save,
        -- 而 flash 擦写次数是有限的
        local wrote, why = slot_clear(k, SHARDED[k])
        if wrote then
            cleared[#cleared + 1] = name
        elseif why then
            failed[#failed + 1] = name .. ":" .. why
        end
    end
    if #cleared > 0 and fskv.save then pcall(fskv.save) end
    return cleared, failed
end

-- 38-fix: 只清 ds_pull (不动 ds_poll / mqtt 凭证). 场景: 前端从 platform
--   切 manual/sniff 时弹窗, 默认勾选 "清空平台拉取配置", 确认后发 W:CLRPULL
--   调这个. 返回 (ok, err, wrote) - wrote 表示是否实际清掉东西 (没写过
--   的话 wrote=false, 不报"已清空"骗用户).
function M.clear_pull()
    if not fskv then return false, "fskv 不可用", false end
    local wrote, why = slot_clear(K_PULL, SHARDED[K_PULL])
    if why then return false, "清 ds_pull 失败: " .. why, false end
    if wrote and fskv.save then pcall(fskv.save) end
    return true, nil, wrote
end

-- 2026-11: 只清 ds_infer (不动 ds_poll / ds_pull / mqtt 凭证).
--   场景: 前端从 sniff 切 manual/platform 时弹窗, 默认勾选 "清空推断表",
--   确认后发 W:CLRINFER 调这个. 返回 (ok, err, wrote)
function M.clear_infer()
    if not fskv then return false, "fskv 不可用", false end
    local wrote, why = slot_clear(K_INFER, SHARDED[K_INFER])
    if why then return false, "清 ds_infer 失败: " .. why, false end
    if wrote and fskv.save then pcall(fskv.save) end
    return true, nil, wrote
end

-- 2026-11: 只清 ds_poll (不动 ds_pull / ds_infer / mqtt 凭证).
--   场景: W:BOOTMODE 设成 platform/sniff 时联动清除 manual 配置.
--   返回 (ok, err, wrote)
function M.clear_poll()
    if not fskv then return false, "fskv 不可用", false end
    local wrote, why = slot_clear(K_POLL, SHARDED[K_POLL])
    if why then return false, "清 ds_poll 失败: " .. why, false end
    if wrote and fskv.save then pcall(fskv.save) end
    return true, nil, wrote
end

return M
