-- pubsched.lua —— 对外上报的统一调度器 (12-fix-4, 2026-10-28)
--
-- ═══ 为什么要有这个模块 ═══
--
-- 2026-10-28 现场: 用多寄存器设备测 sniff 上报, 跑到 5 分钟崩了:
--
--   E/main iot.lua:621: not enough memory for buffer allocation
--     [C]: in field 'concat'          <- send_meta 里 table.concat 拼 600 字节都失败
--   当时 used=275456 / total=307192, 还剩 31KB 空闲 ——
--   不是"不够", 是【碎片化】: 堆被切成大大小小的空洞, 切不出连续块。
--
-- 碎片哪来的? 每秒:
--   ① publish() 一次 —— build_items 重建配置 + 拼 ~4KB body + MQTT 编码
--   ② build_nodes() 一次 —— 重建整张推断表(~14KB) + node_json 拼 JSON
--   ③ meta_sig() 一次 —— 里面含 csq, 信号强度一变就重发元数据帧
--
-- 现场实测 published 从 112 涨到 213: 126 秒发了 101 次 = 0.8 次/秒。
-- 三件事叠在一起, 每秒往 300KB 的堆里灌 ~25KB 垃圾, 灌 5 分钟就碎了。
--
-- ═══ 口径 ═══
--
-- 把两件事拆开:
--   "内容变了" = 事实, 只置脏(changed)
--   "该不该发" = 策略, 走这里的闸门(due / ready)
--
--   发 = (内容变了 OR 到期兜底) AND 过了本通道的最小间隔
--
-- 通道:
--   meta  U2 元数据   身份指纹变了(imei/iccid/host/位置) —— 不含 csq!
--   prop  U4 子设备数据 有数据点更新
--   topo  U2 拓扑     推断出的寄存器集变了
--
-- ⚠️ csq 为什么从 meta 指纹里拿掉(12-fix-4):
--   指纹的语义是"要不要重建平台模型"的身份标识。csq 是会变的数值,
--   混进去 = 信号强度一变就重发元数据帧 = 平台每秒重建模型,
--   还会把平台拖进"重建模型→回推配置→我们再发拓扑"的循环。
--   csq 仍然在 payload 里(只是不再参与指纹), 靠 interval_s 定期带上去。
--
-- ⚠️ 闸门按【上次尝试】计时, 不是上次成功:
--   发送失败(多半是 OOM)时不要每秒重试 —— 重试本身又是一份垃圾,
--   会把堆压得更碎。失败就等下一个窗口(30 秒)再说。
--
-- ⚠️ 时钟:
--   os.clock() 是【秒级单调时钟】(开机起算, 不受 NTP 跳变影响) —— 用它算间隔
--   os.time() 是墙钟 —— 用它算 interval_s 兜底(跟原实现口径一致)

local cfg = require "core/config"

local M = {}

-- 最小发布间隔(毫秒)。用户拍板 30 秒(2026-10-28)。
M.PUB_MIN_MS = cfg.PUB_MIN_MS or 30000

-- 通道表。min_ms = 该通道两次发送之间的最小间隔(毫秒)。
local CH = {
    meta = { min_ms = M.PUB_MIN_MS },            -- U2 元数据
    prop = { min_ms = M.PUB_MIN_MS },            -- U4 子设备数据
    topo = { min_ms = cfg.TOPO_REBUILD_MS or M.PUB_MIN_MS },  -- U2 拓扑
}

-- 时钟钩子: 单测要能注入假时钟, 否则没法验 30 秒闸门
local clock = os.clock
local clock_wall = os.time
M._set_clock = function(fn, fn_wall)
    clock = fn or os.clock
    clock_wall = fn_wall or os.time
end

-- 内容变了: 只置脏, 不决定发不发
function M.changed(ch)
    local st = CH[ch]
    if st then st.dirty = true end
end

-- 占用这个时间窗: 本轮已经尝试过了, 下次再评估要等 min_ms
local function consume(st)
    st.at = clock()
    st.wall = clock_wall()
end

-- 该不该发(会占用时间窗)。
--   fallback_s: 到期兜底周期(秒), 0 = 不做兜底。
--              兜底不看脏标记 —— 指纹/数据长时间没变也定期重发一次,
--              让平台确认设备还活着(原来的 interval_s 语义)。
function M.due(ch, fallback_s)
    local st = CH[ch]
    if not st then return false end
    -- 兜底: 距上次【尝试】满 fallback_s
    if fallback_s and fallback_s > 0 and (clock_wall() - (st.wall or 0)) >= fallback_s then
        consume(st)
        return true
    end
    if not st.dirty then return false end
    -- 闸门: 距上次【尝试】满 min_ms
    if ((clock() - (st.at or -1e9)) * 1000) < st.min_ms then
        st.blocked = (st.blocked or 0) + 1
        return false
    end
    consume(st)
    return true
end

-- 纯时间闸门(会占用时间窗)。给"内容变了"要靠重建才能知道的通道用 ——
-- 比如拓扑: 想知道寄存器集变没变, 得先重建一遍拓扑, 而重建本身很贵,
-- 所以不能每轮都重建。
function M.ready(ch)
    local st = CH[ch]
    if not st then return false end
    if ((clock() - (st.at or -1e9)) * 1000) < st.min_ms then return false end
    consume(st)
    return true
end

-- 确实发出去了
function M.sent(ch)
    local st = CH[ch]
    if not st then return end
    st.dirty = false
    st.sent = (st.sent or 0) + 1
    st.ok_at = clock()
end

function M.dirty(ch)
    local st = CH[ch]
    return (st and st.dirty) or false
end

-- 状态: 给 R:STAT 看。last_age = 距上次成功发送过了多少秒
function M.status()
    local out = {}
    for ch, st in pairs(CH) do
        out[ch] = {
            dirty = st.dirty and true or false,
            sent = st.sent or 0,
            blocked = st.blocked or 0,
            min_ms = st.min_ms,
            last_age = (st.ok_at and (clock() - st.ok_at) or nil),
        }
    end
    return out
end

-- 重置: 断线重连/切档时调用。
--   ⚠️ dirty 置【true】而不是 false —— 重连后要重新报一遍
--      (平台那头刚失去过设备状态, 不重新报它不知道设备回来了)。
--   ⚠️ st.wall 设成【现在】而不是 0 —— 否则 interval_s 兜底会在重连
--      那一刻立刻空转一次(没什么可发的, 白白 build_items 一次)。
function M.reset()
    local w = clock_wall()
    for _, st in pairs(CH) do
        st.dirty = true
        st.at = -1e9
        st.wall = w
    end
end

-- 初始化: at = -1e9 保证"第一次"能立刻过闸门(有数据就马上发);
--   wall = 现在的墙钟 —— interval_s 兜底从开机起算, 不会开机就空转。
for _, st in pairs(CH) do
    st.dirty = false
    st.at = -1e9
    st.wall = clock_wall()
    st.ok_at = nil
    st.sent = 0
    st.blocked = 0
end

return M
