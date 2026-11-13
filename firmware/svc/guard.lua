local util = require "util"
local cfg = require "core/config"
local log = util.log()

local sys = util.try("sys")  -- try 而非 get: 早于 sys 挂载也能加载 (单测可调)
local rtos = util.try("rtos")
local wdt = util.try("wdt")

local M = {}

local ticks, last_alive = 0, 0
-- 上一拍的采集引擎状态, 给 stall 时钟重定基用 (见 sync_running)
local was_running, was_mode = false, ""

local function wdt_ok()
    if not wdt then return false end
    return type(wdt.feed) == "function"
end

function M.alive()
    last_alive = ticks
end

local function feed_loop()
    while true do
        if wdt_ok() then pcall(wdt.feed) end
        if sys then sys.wait(cfg.WDT_FEED_MS) end
    end
end

local function tick_loop()
    while true do
        ticks = ticks + 1
        if sys then sys.wait(1000) end
    end
end

local function cur_mode()
    local ok, ctrl = pcall(require, "bus/ctrl")
    if ok and ctrl then return ctrl.get_mode() end
    return "idle"
end

-- 有心跳可谈的模式: manual/poll + platform(平台档同样跑 poll 循环, poll.lua 喂)
-- + sniff(旁听循环 mon.task 喂, 2026-10 补). idle 不算 —— 没有采集在跑,
-- 心跳停是正常状态, 不能当 stall
local function is_active_mode(mode)
    return mode == "manual" or mode == "poll" or mode == "platform" or mode == "sniff"
end
-- 导出: 单元测试用 (tests/lua/test_guard_modes.lua)
M.is_active_mode = is_active_mode

-- 采集引擎是否真的在跑 (12-fix, 2026-10-27)。
--
-- 只看"档位"判 stall 是不够的: 34-fix 定了"档位对应的槽空着就不起轮询",
-- 好处之一明确写着"看门狗不再被 'poll 起来了但 regs=0' 误判为停滞" ——
-- 但 guard 的判据一直只看 mode, 34-fix 的这个意图其实没落地。
--
-- 后果 (现场踩过): manual 档但寄存器表是空的 (切 idle 时 "cleared:manual
-- 配置" 擦掉了 ds_poll, 切回 manual 又没重配) → poll 没起 → 没人调
-- guard.alive() → stall 一路涨到 STALL_LIMIT_S(120) → AUTO_REBOOT 自动
-- 重启。设备看起来好好的, 过两分钟自己重启。
--
-- 这里加的判据【不削弱看门狗】:
--   poll/mon 没起 (is_running()==false) = 没有采集任务在跑, 心跳停是正常
--                                    状态, 不该算 stall
--   poll/mon 起了但卡死              = is_running() 仍是 true → stall 照常
--                                    累积 → 120s 后照样自愈重启
local function collector_running(mode)
    local mod = (mode == "sniff") and "bus/mon" or "bus/poll"
    local ok, m = pcall(require, mod)
    if not ok or not m or type(m.is_running) ~= "function" then return false end
    return m.is_running() and true or false
end

-- stall 时钟重定基 (2026-11-10)。last_alive 只有 alive() 会动, 所以采集引擎
-- 停着的那段时间里它一路陈旧; 引擎【重新起来的下一拍】直接拿
-- ticks - last_alive 算差值, 停机多久就报多少秒 stall。
-- 现场: 128 点配置落盘失败 → poll 读回空表跑起来, 日志里 poll 于
-- uptime=1117 起, uptime=1120 的 monitor 就算出 stall=611s 直接 reboot ——
-- 用户看到的是"改完配置 3 秒后设备自己重启", 而不是配置报错。
-- 规则统一, 不按档位特判: 采集引擎在跑 且 (相对上一拍刚起来 / 刚换档) → 归零。
local function sync_running(mode)
    local r = collector_running(mode)
    if r and (not was_running or mode ~= was_mode) then last_alive = ticks end
    was_running, was_mode = r, mode
    return r
end

-- 本档位当前的 stall 秒数; nil = 不该判 stall(没采集在跑)
local function stall_of(mode)
    if not is_active_mode(mode) then return nil end
    if not sync_running(mode) then return nil end
    return ticks - last_alive
end
-- 导出: 单元测试用 (tests/lua/test_guard_modes.lua)
M.stall_of = stall_of

-- Lua 池保险丝: 剩余空间低于 GC_FUSE_FREE 就完整回收一轮, 并打一行前后水位。
--   ⚠️ 为什么挂在 guard 而不是继续加在 iot 里: 全仓库的 collectgarbage
--   ("collect") 保险丝原先都在 iot 那边(reclaim_if_high / task_main 那条
--   12-fix-5), 而 main.lua 只在【烧了 SN】才 iot.start()。11-13 现场那台
--   SN 为空的机器, 60 点第一轮采集后 used 302528/307192 —— 从头到尾一次
--   完整回收都没跑过, 一个 672 字节的分配拿不到, prov.poll 抛 not enough
--   memory 打死整个 VM。monitor 由定时器驱动, 和 SN/MQTT/档位都无关, 是
--   唯一一档必然在跑的周期任务, 所以这条保险丝只能住在这里。
--   两个调用点: 心跳(兜住所有档位) + poll 每轮开头(见 bus/poll.lua)。11-13
--   那次崩在上一拍心跳之后 3.6 秒, 光靠 10 秒一拍赶不上; 而一轮采集正是
--   全系统分配最密的时段, 和 iot 那句"拼大包前先回收"同一个道理。
--   判据用 rtos.meminfo("lua") 的真实字节, 不用 collectgarbage("count"):
--   后者少报约 1/3, 照它定阈值等于在最需要的那一段里永不触发。
--   ⚠️ 它救不了大块(12-fix-8 已证: 分配器不合并相邻空闲块), 只保证几百字节
--   到几 KB 的分配有货可拿。所以那一行的两个数字才是重点: 若 B 和 A 差不
--   多, 说明剩下的全是活对象, 得回去砍常驻, 而不是再来一轮回收。
function M.sweep()
    if not rtos then return false end
    local ok, total, used = pcall(rtos.meminfo, "lua")
    if not ok or type(total) ~= "number" or type(used) ~= "number" then return false end
    if total - used > cfg.GC_FUSE_FREE then return false end
    pcall(collectgarbage, "collect")
    local ok2, t2, u2 = pcall(rtos.meminfo, "lua")
    if ok2 and type(t2) == "number" and type(u2) == "number" then
        log.warn("guard", string.format("lua 池剩 %d, 扫一轮 %d->%d 剩 %d",
            total - used, used, u2, t2 - u2))
    else
        log.warn("guard", string.format("lua 池剩 %d, 扫一轮", total - used))
    end
    return true
end

local function monitor()
    local mode = cur_mode()
    -- 先扫水再打日志: 日志那一行自己也要分配字符串, 排在后面的话正好可能
    -- 死在最该报出这句话的时候
    M.sweep()
    -- "manual" 才是当前 mode 名; "poll" 是历史别名, 老 fskv 软切会同时返回 "poll",
    -- 也算 manual 行为 (MQTT 手动档 + 寄存器手配)
    local is_manual = mode == "manual" or mode == "poll"
    local stall = stall_of(mode)
    local parts = {
        string.format("uptime=%ds mode=%s feed=%d", ticks, mode, math.floor(cfg.WDT_FEED_MS / 1000)),
    }
    if stall then parts[#parts + 1] = string.format("stall=%ds", stall) end
    -- 轮询进度: 让"是否在周期轮询"直接从心跳可见 (manual/platform 两档都跑 poll)
    if is_manual or mode == "platform" then
        local okp, poll = pcall(require, "bus/poll")
        if okp and poll then
            local ps = poll.status()
            parts[#parts + 1] = string.format("poll_round=%d ok=%d timeout=%d werr=%d",
                ps.rounds or 0, ps.ok or 0, ps.timeout or 0, ps.werr or 0)
        end
    end
    if rtos then
        local total, used = rtos.meminfo("sys")
        if type(used) == "number" then
            parts[#parts + 1] = string.format("mem=%d/%d", used, total or 0)
        end
    end
    log.info("guard", table.concat(parts, " "))
    if stall and stall > cfg.STALL_LIMIT_S then
        log.error("guard", "collector stalled!")
        if cfg.AUTO_REBOOT and rtos and rtos.reboot then pcall(rtos.reboot) end
    end
end

function M.status()
    return {
        uptime = ticks,
        feed = cfg.WDT_FEED_MS,
        stall = stall_of(cur_mode()),
        wdt_to = cfg.WDT_TIMEOUT,
    }
end

function M.init()
    if wdt_ok() then
        local pok, ret = false, nil
        if type(wdt.init) == "function" then
            pok, ret = pcall(wdt.init, cfg.WDT_TIMEOUT)
        end
        if pok and ret then
            log.info("guard", "wdt init " .. cfg.WDT_TIMEOUT .. "ms")
        else
            log.info("guard", "wdt.init 无效(Air780EP 无软件看门狗, AON WDT 由固件托管), 仅 feed 有效")
        end
    else
        log.warn("guard", "wdt unavailable")
    end
    if sys then
        sys.taskInit(feed_loop)
        sys.taskInit(tick_loop)
        sys.timerLoopStart(monitor, cfg.MONITOR_MS)
    end
    log.info("guard", "ready")
    return true
end

return M
