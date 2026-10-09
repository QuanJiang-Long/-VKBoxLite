local corelib = require "core/corelib"
local log = corelib.log()
local sys = corelib.try("sys")

local poll = require "bus/poll"
local mon = require "bus/mon"
local cfgstore = require "cfg"
local mqttcfg = require "iot/mqttcfg"
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
            -- 进拉取档一律向平台报到(hello)并重新拉一次, 不再看 ds_pull
            -- 拉没拉过。之前只在 pull_src()=="default" 时才拉: 拿过一次
            -- 配置后再进 pollpull 就静默用旧配置, 平台那头看不到设备重新
            -- 上线, 而现场寄存器表可能已经在平台上改过了。拉取期间轮询继续
            -- 跑旧配置, 新配置到了由 auto_apply 立即生效
            local ok, err = iot and iot.pull_start()
            if not ok then
                poll.stop()
                return false, "FAIL pull: " .. tostring(err)
            end
            return true, "OK pollpull, pulling"
        end
        -- 手动档也向平台报到(hello)。平台侧不预知这台设备的具体配置, 靠
        -- 上报 auto-provision 补建 —— hello 是让平台知道"这台网关上线了"
        -- 的入口, 不发的话平台那头看不到设备。失败不回滚切模式: 手动档的
        -- 主职是采用户配的寄存器表, 平台那头看不到不影响采集。真没发出去
        -- 时 task_main 连上后会补发(见 iot.lua 的 hello on connect 分支)
        if iot then pcall(iot.hello) end
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
            -- sniff 也向平台报到。以前这里不碰 iot, 设备进旁听后平台完全
            -- 看不到它上线。失败不回滚: 旁听才是 sniff 的主职, 平台那头
            -- 连不上不该让用户连旁听都用不了
            if iot then pcall(iot.pull_start) end
            return true, "OK sniff started, detecting"
        end
        return false, "FAIL sniff start"

    elseif mode == "idle" or mode == "stop" then
        if poll.is_running() then poll.stop() end
        if mon.is_running() then mon.stop() end
        local cleared = M.reset_user_cfg()
        -- 第三个返回值是给 W:MODE 拼应答的(见 cmd.lua 的 cleared: 那段),
        -- msg 本身保持原样, 别把清单塞进去 —— switch_mode 的返回值有别的调用方
        return true, "OK idle (bus released)", cleared

    else
        return false, "FAIL unknown mode (use poll/pollpull/sniff/idle)"
    end
end

-- 切回 idle 时的配置复位。清 485 三槽 + 手动档 MQTT, 首页配好的平台连接不动。
-- 返回真正清掉的项名, 由 switch_mode 拼进应答, 用户看得见"到底清了什么"。
--
-- ⚠️ 只走 idle/stop 分支, 因为只有那时 poll/mon 已经停了。poll/pollpull
--    正在用这两份配置, 清了等于当场自残。
-- ⚠️ manual_on 变了必须 kick 重连: 旧的 user/pass/topic 还挂在已建连的
--    client 上, 不 kick 的话设备会用旧凭证继续跑, 直到下次自然重连才生效
function M.reset_user_cfg()
    local cleared = cfgstore.reset_user()
    -- wrote=false = 手动档本来就是干净的(从没配过), 不能报"已清空"骗用户
    local ok, err, wrote = mqttcfg.clear_manual()
    if ok then
        if wrote then cleared[#cleared + 1] = "mqtt_manual" end
    else
        -- 复位失败不能让切 idle 失败(总线已经放了, 回退会自相矛盾),
        -- 但必须留痕: 否则用户以为清干净了, 下次进 pollpull 拿旧配置起轮询
        log.warn("ctrl", "reset mqtt_manual fail:", tostring(err))
    end
    -- 手动档开着时旧凭证还挂在已建连的 client 上, 必须重连换一套
    if wrote and iot then pcall(iot.kick) end
    return cleared
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
