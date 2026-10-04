local corelib = require "core/corelib"
local log = corelib.log()
local sys = corelib.try("sys")

local poll = require "bus/poll"
local mon = require "bus/mon"
local cfgstore = require "cfg"
local iot = corelib.try("iot/iot")

local M = {}

local SWITCH_DELAY_MS = 50
-- 运行模式 -> poll 配置槽(poll=手配 / pull=平台拉取)。MQTT 手动档跟着反着走:
-- 手动配置用手动档, 拉取配置必须用自动档(hello 应答走 config/get, 手动档不订)
local SLOT = { poll = "poll", pollpull = "pull" }

local function switch_delay()
    if not sys then return end
    local ok = pcall(sys.wait, SWITCH_DELAY_MS)
    if ok then return end
    pcall(sys.taskInit, function()
        pcall(sys.wait, SWITCH_DELAY_MS)
    end)
end

function M.switch_mode(mode)
    if type(mode) ~= "string" then
        return false, "FAIL unknown mode (use poll/sniff/idle)"
    end
    mode = mode:lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- 识别期间串口正被反复 uart.setup, 切模式会和它抢串口, 扫出来的结果不可信。
    -- 只放行 idle/stop —— 那是用户主动放弃识别的唯一逃生口
    if (mode == "poll" or mode == "pollpull" or mode == "sniff") and mon.is_detecting() then
        return false, "BUSY: 正在识别通讯参数, 完成后自动开始旁听(或先 W:MODE=idle 放弃)"
    end
    if mode == "poll" or mode == "pollpull" then
        if mon.is_running() then
            mon.stop()
            switch_delay()
        end
        if poll.is_running() then poll.stop() end
        -- 档位先切再起轮询: iot.set_manual 会断开重连换订阅清单, 必须在
        -- 拉取握手之前就位, 否则 hello 发出去没人应答(pollpull 才需要)。
        -- ⚠️ 别把这里写反: set_manual(true)=手动档(订用户 topic),
        --    手动配置用 ds_poll 槽所以要 true, 拉取配置用 ds_pull 槽要 false。
        --    写反的后果是手动档收不到自己的 topic、拉取档订不上平台 topic,
        --    两个模式一起废
        local slot = SLOT[mode]
        if iot then pcall(iot.set_manual, slot == "poll") end
        if not poll.start(slot) then return false, "FAIL poll start" end
        if slot == "pull" then
            -- 平台配置还没拉过就直接拿 default 起轮询, 等于凭空造一套寄存器表,
            -- 从机地址多半还是错的。必须先拉一次(异步, 最坏 35s), 成功才转正
            if cfgstore.pull_src() == "default" then
                local ok, err = iot and iot.pull_start()
                if not ok then
                    poll.stop()
                    return false, "FAIL pull: " .. tostring(err)
                end
                return true, "OK pollpull, pulling"
            end
            return true, "OK pollpull started"
        end
        return true, "OK poll started"

    elseif mode == "sniff" then
        if poll.is_running() then
            poll.stop()
            switch_delay()
        end
        if mon.is_running() then mon.stop() end
        if mon.start() then
            -- 识别必须放后台: switch_mode 是同步的, 而且在开机路径(main.lua 的
            -- boot_mode)上也会被调用。同步等识别会把开机流程堵住, 而识别失败是
            -- 重试到成功为止的, 静默总线上开机就永远回不来
            mon.request_detect()
            return true, "OK sniff started, detecting"
        end
        return false, "FAIL sniff start"

    elseif mode == "idle" or mode == "stop" then
        if poll.is_running() then poll.stop() end
        if mon.is_running() then mon.stop() end
        return true, "OK idle (bus released)"

    else
        return false, "FAIL unknown mode (use poll/pollpull/sniff/idle)"
    end
end

-- 前端据此高亮对应的卡。pollpull 要单列一张卡, 不能和 poll 混:
-- 两者跑的是两套配置(手配 / 平台拉), 混在一起用户看不出当前在采哪份
function M.get_mode()
    if poll.is_running() then
        return poll.slot() == "pull" and "pollpull" or "poll"
    end
    if mon.is_running() then return "sniff" end
    return "idle"
end

function M.is_busy()
    return poll.is_running() or mon.is_running()
end

function M.status()
    return {
        mode = M.get_mode(),
        busy = M.is_busy(),
        -- 前端区分"手动配置"和"拉取配置"两张卡用的就是这两个字段:
        -- poll_src = manual/pull 当前在采哪份; pull_ready = ds_pull 拉过没有
        poll_src = (poll.is_running() and poll.slot()) or nil,
        pull_ready = cfgstore.pull_src(),
        pull = iot and iot.pull_status() or nil,
        poll = poll.status(),
        mon = mon.status(),
        write = poll.write_status(),
    }
end

log.info("ctrl", "mode arbiter ready, default=idle")

return M
