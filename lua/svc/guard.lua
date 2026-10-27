local util = require "util"
local cfg = require "core/config"
local log = util.log()

local sys = util.try("sys")  -- try 而非 get: 早于 sys 挂载也能加载 (单测可调)
local rtos = util.try("rtos")
local wdt = util.try("wdt")

local M = {}

local ticks, last_alive = 0, 0

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

-- 本档位当前的 stall 秒数; nil = 不该判 stall(没采集在跑)
local function stall_of(mode)
    if not is_active_mode(mode) then return nil end
    if not collector_running(mode) then return nil end
    return ticks - last_alive
end
-- 导出: 单元测试用 (tests/lua/test_guard_modes.lua)
M.stall_of = stall_of

local function monitor()
    local mode = cur_mode()
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
