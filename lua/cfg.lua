local corelib = require "core/corelib"
local cfg = require "core/config"
local log = corelib.log()

local fskv = corelib.try("fskv")
local json = corelib.try("json")

local M = {}

local K_POLL, K_SNIFF, K_SYS = "ds_poll", "ds_sniff", "ds_sys"
-- ds_pull: 平台拉取配置的独立槽。和 ds_poll 同构(串口参数+slave+regs),
-- 复用同一份 normalize_poll/default_poll, 不新增校验代码。
-- 为什么必须分开: 手动配置和平台配置原本共用一个槽, 拉一次平台配置就把
-- 手配的寄存器表覆盖掉了, 用户没法两个都要(见 lua/README.md 配置来源隔离)
local K_PULL = "ds_pull"

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

local function kv_set(k, s)
    if not fskv then return false end
    fskv.set(k, s)
    if fskv.save then pcall(fskv.save) end
    return true
end

local function load_json(k, default)
    local s = kv_get(k)
    if not s or not json then return default end
    local ok, t = pcall(json.decode, s)
    if ok and type(t) == "table" then return t end
    log.warn("cfg", "decode fail", k)
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

M.default_sniff = {
    baud = cfg.BAUD,
    databits = cfg.DATABITS,
    stopbits = cfg.STOPBITS,
    parity = cfg.PARITY,
}

M.default_sys = { boot_mode = "idle" }

local function normalize_reg(r)
    if type(r) ~= "table" then return nil, "not table" end
    local addr = num(r.addr)
    if not addr or addr < 0 or addr > 65535 then return nil, "bad addr" end
    local count = num(r.count, 1)
    if count < 1 or count > 125 then return nil, "bad count" end
    local dtype = str(r.dtype, "uint16")
    if not ({ uint16 = 1, int16 = 1, uint32 = 1, int32 = 1, float32 = 1, uint64 = 1, int64 = 1, float64 = 1 })[dtype] then
        return nil, "bad dtype"
    end
    local name = str(r.name)
    if not name or #name > 16 or not name:match("^%w+$") then return nil, "bad name" end
    return {
        addr = addr, count = count, dtype = dtype, name = name,
        alias = str(r.alias, name),
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
    local regs = c.regs
    if type(regs) == "table" then
        for _, r in ipairs(regs) do
            local nr, err = normalize_reg(r)
            if not nr then return nil, err end
            if #out.regs >= cfg.MAX_REGS then return nil, "too many regs" end
            out.regs[#out.regs + 1] = nr
        end
    end
    return out
end

function M.normalize_sniff(c)
    return normalize_common(c, M.default_sniff)
end

function M.normalize_sys(c)
    c = c or {}
    local mode = str(c.boot_mode, "idle"):lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- pollpull = 拉取配置档: 用 ds_pull 轮询, 且开机后自动 hello 拉一次平台配置。
    -- 和 poll 共用同一套 normalize_poll, 只是配置来源不同
    if mode ~= "idle" and mode ~= "poll" and mode ~= "pollpull" and mode ~= "sniff" then
        return nil, "bad boot_mode"
    end
    return { boot_mode = mode }
end

-- 四套配置(poll/pull/sniff/sys)的读写除了键、归一化函数、默认值以外完全同构，
-- 各写一遍就是三处要同步改。这里合成一张表驱动，函数名是它们唯一的差别。
-- 注意 load 失败时静默退回默认值(load 用在启动路径, 崩了整个设备起不来),
-- 而 save 失败必须把原因带回去给 W:CFG 显示
local SECTIONS = {
    poll = { key = K_POLL, norm = M.normalize_poll, default = M.default_poll },
    pull = { key = K_PULL, norm = M.normalize_poll, default = M.default_poll },
    sniff = { key = K_SNIFF, norm = M.normalize_sniff, default = M.default_sniff },
    sys = { key = K_SYS, norm = M.normalize_sys, default = M.default_sys },
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
local RESET_SLOTS = { { "poll", K_POLL }, { "pull", K_PULL }, { "sniff", K_SNIFF } }

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
            cleared[#cleared + 1] = name
        end
    end
    if #cleared > 0 and fskv.save then pcall(fskv.save) end
    return cleared
end

return M
