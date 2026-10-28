local util = require "util"
local cfg = require "core/config"
local log = util.log()

local fskv = util.try("fskv")
local json = util.try("json")

local M = {}

-- 4 种工作模式提到模块顶部(各文件独立常量是 Lua 闭包隔离的代价)
-- 记录 3: 删 MODE_POLL/MODE_PULL (历史别名)。项目还在测试阶段, 没正式发布,
-- 不存在老 fskv 存 "poll"/"pollpull" 的情况, normalize_sys 直接限 4 值。
local MODE_MANUAL, MODE_PLATFORM, MODE_IDLE, MODE_SNIFF = "manual", "platform", "idle", "sniff"

local K_POLL, K_SYS = "ds_poll", "ds_sys"
-- ds_pull: 平台拉取的独立槽, 复用 normalize_poll/default_poll, 不新增校验。
-- 必须分开: 原本共用一槽, 拉一次平台配置就覆盖手配的寄存器表(见 lua/README.md 配置来源隔离)。
-- 没有 sniff 槽: auto_detect 结果只存本次会话(mon.bootCfg), 不落 fskv, 从结构上堵住误存
local K_PULL = "ds_pull"
-- ds_alias: sniff 侧别名表 (2026-10)。存【用户给 reg<addr> 起的名字】(id+name),
-- 不是识别出来的串口参数(那些只存本次会话)。决定 sniff 档 U2 拓扑属性与
-- U4 数据项的 id/name, 让平台物模型显示人看得懂的名字。
-- 不复用 ds_poll: 那是手配寄存器表, 会被平台下发覆盖/切 idle 复位清掉
local K_ALIAS = "ds_alias"

local function num(v, d)
    if v == nil then return d end
    return tonumber(v) or d
end

local function str(v, d)
    if type(v) ~= "string" or v == "" then return d end
    return v
end

local function kv_get(k)
    if not fskv then return nil end
    local ok, v = pcall(fskv.get, k)
    if ok and type(v) == "string" and v ~= "" then return v end
    return nil
end

-- ⚠️ 12-fix-3 (2026-10-28): 配置解码缓存。必须声明在 kv_set 之前 ——
--   Lua 的 local 只能看到它【之前】的声明, 晚声明的话 kv_set 里那次
--   json_cache[k] = nil 会写到全局表上, 缓存永远不失效。
local json_cache = {}   -- fskv key -> 解码后的原始表

local function kv_set(k, s)
    if not fskv then return false end
    json_cache[k] = nil   -- 12-fix-3: 写盘了, 解码缓存必须失效
    fskv.set(k, s)
    if fskv.save then pcall(fskv.save) end
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
--      normalize_poll/normalize_alias 都不改它们的入参, 所以缓存的原始表
--      是只读的, 安全; 而归一化结果每次新建, 各调用方拿到各自独立的一份,
--      改它不会串味(这点很重要 —— poll.lastCfg 就长期持有 load_poll() 的结果)。
--   ⚠️ 写盘(kv_set / reset_user / clear_pull)必须清缓存。

local function load_json(k, default)
    local cached = json_cache[k]
    if cached ~= nil then return cached end
    local s = kv_get(k)
    if not s or not json then
        json_cache[k] = default
        return default
    end
    local ok, t = pcall(json.decode, s)
    if ok and type(t) == "table" then
        json_cache[k] = t
        return t
    end
    log.warn("cfg", "decode fail", k)
    json_cache[k] = default
    return default
end

local function save_json(k, t)
    if not json then return false, "no json lib" end
    local ok, s = pcall(json.encode, t)
    if not ok or not s then return false, "encode fail" end
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
                            if #out.regs >= MAX_ALIAS then return nil, "别名条数过多" end
                        end
                    end
                end
            end
        end
    end
    return out
end

-- 别名表查表: key -> {id,name}, 供 iot 上报时套用
function M.alias_map()
    local m = {}
    local c = M.load_alias()
    for _, r in ipairs((c and c.regs) or {}) do
        m[r.key] = { id = r.id, name = r.name }
    end
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

local function normalize_reg(r)
    if type(r) ~= "table" then return nil, "not table" end
    -- 范围/格式校验委托给 util.validate_reg(抽离后 ds_poll/ds_pull 共享)
    local ok, why = util.validate_reg(r)
    if not ok then return nil, why end
    return {
        addr = num(r.addr), count = num(r.count, 1),
        dtype = str(r.dtype, "uint16"),
        name = r.name,
        alias = str(r.alias, r.name),
    }
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

function M.normalize_poll(c)
    local out = normalize_common(c, M.default_poll)
    out.slave = math.floor(num(c.slave, M.default_poll.slave))
    if out.slave < 1 or out.slave > 247 then return nil, "bad slave" end
    out.interval_ms = math.floor(num(c.interval_ms, M.default_poll.interval_ms))
    if out.interval_ms < 100 then return nil, "bad interval" end
    -- timeout_ms 允许留空(null)= 早返回模式: 收到响应立刻走下一事务,
    -- 不等满超时。字段名与前端一致(前端 collectCfg 下发 timeout_ms)
    if c.timeout_ms == nil then
        out.timeout_ms = nil
    else
        local t = math.floor(num(c.timeout_ms, M.default_poll.timeout_ms))
        if t < 50 or t > 500 then return nil, "响应上限越界(50~500ms)" end
        out.timeout_ms = t
    end
    out.regs = {}
    local seen = {}
    local regs = c.regs
    if type(regs) == "table" then
        for _, r in ipairs(regs) do
            local nr, err = normalize_reg(r)
            if not nr then return nil, err end
            if #out.regs >= cfg.MAX_REGS then return nil, "too many regs" end
            -- 同 addr 只留首条。平台的 properties 实测会把同一属性发两遍
            -- (2026-10-08 日志: skipped 里 reg_100/reg_250 各出现两次),
            -- 原样存进重复项, 切 pollpull 后同一帧重复读, 白占总线时间
            if not seen[nr.addr] then
                seen[nr.addr] = true
                out.regs[#out.regs + 1] = nr
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
local SECTIONS = {
    poll = { key = K_POLL, norm = M.normalize_poll, default = M.default_poll },
    pull = { key = K_PULL, norm = M.normalize_poll, default = M.default_poll },
    sys = { key = K_SYS, norm = M.normalize_sys, default = M.default_sys },
    alias = { key = K_ALIAS, norm = M.normalize_alias, default = M.default_alias },
}

for name, sec in pairs(SECTIONS) do
    M["load_" .. name] = function()
        local raw = load_json(sec.key, {})
        local ok, c = pcall(sec.norm, raw)
        if not ok or not c then
            log.warn("cfg", name, "normalize fail, use default")
            return sec.default
        end
        return c
    end
    M["save_" .. name] = function(c)
        local n, err = sec.norm(c)
        if not n then return false, err end
        return save_json(sec.key, n)
    end
end

-- 配置来源: fskv 里从未写过就是 default(前端据此提示"尚未保存过配置")
function M.poll_src()
    if not fskv then return "default" end
    local v = fskv.get(K_POLL)
    if v == nil or v == "" then return "default" end
    return "fskv"
end

-- ds_pull 是否拉过平台配置。前端据此判断"拉取配置"档能不能直接起轮询
-- (没拉过就必须先走 hello 拉一次, 否则拿 default 去轮询等于凭空造一套寄存器表)
function M.pull_src()
    if not fskv then return "default" end
    local v = fskv.get(K_PULL)
    if v == nil or v == "" then return "default" end
    return "fskv"
end

-- 34-fix: 槽里是否真有可轮询的配置。
--   仅 src=="fskv" 还不够, 万一上层把空配置(regs={})写进去就骗过这一道。
--   用 #regs>0 才算"有东西可采"; 串口参数(baud/slave/...)总是有默认值的,
--   不是判断依据, 真正决定"轮询一跑就能出活"的是寄存器表
--   用途: ctrl.switch_mode 看到这个为 false 就跳过 poll.start,
--   省掉"空配置下 for 循环空跑 + 喂狗误报"那一串副作用
function M.has_poll_cfg()
    if M.poll_src() ~= "fskv" then return false end
    local c = M.load_poll()
    return c and #(c.regs or {}) > 0
end

function M.has_pull_cfg()
    if M.pull_src() ~= "fskv" then return false end
    local c = M.load_pull()
    return c and #(c.regs or {}) > 0
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
local RESET_SLOTS = { { "manual 配置", K_POLL }, { "platform 配置", K_PULL } }

function M.reset_user()
    local cleared = {}
    if not fskv then return cleared end
    for _, s in ipairs(RESET_SLOTS) do
        local name, k = s[1], s[2]
        -- 只清"写过"的槽: 没写过的槽也清一遍等于白写 fskv + 多一次 save,
        -- 而 flash 擦写次数是有限的
        local ok, v = pcall(fskv.get, k)
        if ok and v ~= nil and v ~= "" then
            fskv.set(k, "")
            json_cache[k] = nil   -- 12-fix-3: 绕过了 kv_set, 缓存要手动失效
            cleared[#cleared + 1] = name
        end
    end
    if #cleared > 0 and fskv.save then pcall(fskv.save) end
    return cleared
end

-- 38-fix: 只清 ds_pull (不动 ds_poll / mqtt 凭证). 场景: 前端从 platform
--   切 manual/sniff 时弹窗, 默认勾选 "清空平台拉取配置", 确认后发 W:CLRPULL
--   调这个. 返回 (ok, err, wrote) - wrote 表示是否实际清掉东西 (没写过
--   的话 wrote=false, 不报"已清空"骗用户).
function M.clear_pull()
    if not fskv then return false, "fskv 不可用", false end
    local ok, v = pcall(fskv.get, K_PULL)
    if not ok then return false, "读 ds_pull 失败: " .. tostring(v), false end
    if v == nil or v == "" then return true, nil, false end
    fskv.set(K_PULL, "")
    json_cache[K_PULL] = nil   -- 12-fix-3: 绕过了 kv_set, 缓存要手动失效
    if fskv.save then pcall(fskv.save) end
    return true, nil, true
end

return M
