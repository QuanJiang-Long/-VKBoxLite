local util = require "util"
local log = util.log()
local sys = util.try("sys")

local poll = require "bus/poll"
local mon = require "bus/mon"
local cfgstore = require "cfg"
local mqttcfg = require "iot/mqttcfg"
local iot = util.try("iot/iot")

local M = {}

-- 34-fix: 当前模式. 之前 get_mode() 全靠 poll.is_running() / mon.is_running() 推导
--   (manual=轮询在跑+poll 槽 / platform=轮询在跑+pull 槽 / sniff=mon 在跑 /
--   idle=都没在跑). 34-fix 改了 poll: 槽空时不起轮询, "槽空=platform 档但
--   poll 没起" 这种状态下 get_mode 会误报 idle. 显式记一下最稳.
-- 启动默认 idle (没经过 switch_mode 时), 开机 boot 路径会立刻覆盖
local S = { cur = "idle" }

local SWITCH_DELAY_MS = 50
-- 运行模式 -> poll 配置槽(manual=手配 / platform=平台拉取)。MQTT 手动档跟着反着走:
-- 手动配置用手动档, 拉取配置必须用自动档(hello 应答走 config/get, 手动档不订)
-- "poll"/"pollpull" 是历史别名 (老 fskv 软切可能返回), 用 alias 处理
local SLOT = { manual = "poll", platform = "pull" }
-- 记录 3: 删 MODE_ALIAS (历史别名映射)。项目测试阶段, 无老 fskv 兼容需求,
-- 老命令 W:MODE=poll/pollpull 现在直接被 normalize_sys 报 bad boot_mode。
-- SLOT 表保留: 内部映射 manual→"poll" 槽 / platform→"pull" 槽, 是 cfgstore API。

local function switch_delay()
    if not sys then return end
    local ok = pcall(sys.wait, SWITCH_DELAY_MS)
    if ok then return end
    pcall(sys.taskInit, function()
        pcall(sys.wait, SWITCH_DELAY_MS)
    end)
end

-- 离开 sniff 统一入口: 停监听 + 抹掉这一轮的名字 (A 方案, 2026-10)
--   名字只对当前这一轮有效: 退出 sniff 就抹干净, 下次进来是干净的表
--   (clear_alias 空表不写 fskv, 所以"进 sniff 兜底再清一次"不费 flash)
local function stop_sniff()
    if not mon.is_running() then return end
    mon.stop()
    if cfgstore and cfgstore.clear_alias then pcall(cfgstore.clear_alias) end
end

function M.switch_mode(mode, from_boot)
    -- 25-fix: from_boot 默认 false, 开机自启路径 (main.lua 的 boot_mode) 传 true
    --   跳过 platform 的 MQTT 连接前置检查 —— 开机时 iot.start 还没跑, MQTT
    --   还没连, 但 boot 路径应该正常进入, 连上后自动拉取
    from_boot = from_boot or false
    if type(mode) ~= "string" then
        return false, "FAIL unknown mode (use manual/platform/sniff/idle)"
    end
    mode = mode:lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- 记录 3: 软切删了。poll/pollpull 现在直接被 switch_mode 下游 (ctrl.status /
    -- poll.start 等) 拒掉, 不需要再翻译。简单些。
    -- 识别期间串口正被反复 uart.setup, 切模式会和它抢串口, 扫出来的结果不可信。
    -- 只放行 idle/stop —— 那是用户主动放弃识别的唯一逃生口
    if (mode == "manual" or mode == "platform" or mode == "sniff") and mon.is_detecting() then
        return false, "BUSY: 正在识别通讯参数, 完成后自动开始旁听(或先 W:MODE=idle 放弃)"
    end
    if mode == "manual" or mode == "platform" then
        -- 33-fix: 撤掉 25-fix 的 platform MQTT 拦截. 让用户自由进 platform 档.
        --   之前 25-fix 要求 MQTT 已连接才能切, 体验不好 (用户想先进去看
        --   看但被弹窗打断). 现在改为: 不管 MQTT 连没连都让进.
        --   - 如果 ds_pull 有旧配置: poll.start("pull") 用旧配置起轮询
        --   - 如果 ds_pull 是空的: poll.start("pull") 也起, 但 for 循环空跑
        --     (空配置), 此时不触发现有活动. 看门狗停滞是误报, 后续再讨论
        --   - iot.pull_start() 会 kick MQTT 重连, 连上后自动拉新配置,
        --     拉到了 auto_apply 调 poll.start("pull") 重启轮询
        --   - 即使 host/port 没配, 也让用户进来 (前端的 pMqttHint 黄条会提示)
        -- 开机路径 (from_boot=true) 本来就没这个检查, 不受影响
        if mon.is_running() then
            stop_sniff()
            switch_delay()
        end
        if poll.is_running() then poll.stop() end
        -- 档位先切再起轮询: iot.set_manual 会断开重连换订阅清单, 必须在
        -- 拉取握手之前就位, 否则 hello 发出去没人应答(platform 才需要)。
        -- ⚠️ 别把这里写反: set_manual(true)=手动档(订用户 topic),
        --    manual 用 ds_poll 槽所以要 true, platform 用 ds_pull 槽要 false。
        --    写反的后果是 manual 收不到自己的 topic、platform 订不上平台 topic,
        --    两个模式一起废
        local slot = SLOT[mode]
        if iot then pcall(iot.set_manual, mode == "manual") end
        -- 34-fix: 模式对应的槽空着, 就不起轮询. 不起的好处:
        --   1) for 循环不会空跑 (空 regs 没活可干, 浪费串口/CPU)
        --   2) 看门狗不再被 "poll 起来了但 regs=0" 误判为"停滞"
        --   3) 用户界面更清晰: 看不到假的"轮询中"状态
        -- 起来后补路径:
        --   - manual: 用户在表单添寄存器表后 W:CFG 会重启 poll (见 cmd.lua W:CFG)
        --   - platform: iot.pull_start 拉到平台配置后 auto_apply 会启动 poll
        --             (见 iot.lua auto_apply)
        local have_cfg = true
        if mode == "manual" then
            have_cfg = cfgstore and cfgstore.has_poll_cfg and cfgstore.has_poll_cfg()
        elseif mode == "platform" then
            have_cfg = cfgstore and cfgstore.has_pull_cfg and cfgstore.has_pull_cfg()
        end
        if have_cfg then
            if not poll.start(slot) then return false, "FAIL poll start" end
        else
            log.info("ctrl", string.format(
                "%s 档: %s 槽空, 暂不起轮询, 等配置就位后由 W:CFG / auto_apply 补起",
                mode, slot))
        end
        if mode == "platform" then
            -- 进拉取档一律向平台报到(hello)并重新拉一次, 不再看 ds_pull
            -- 拉没拉过。之前只在 pull_src()=="default" 时才拉: 拿过一次
            -- 配置后再进 platform 就静默用旧配置, 平台那头看不到设备重新
            -- 上线, 而现场寄存器表可能已经在平台上改过了。拉取期间轮询继续
            -- 跑旧配置, 新配置到了由 auto_apply 立即生效
            local ok, err = iot and iot.pull_start()
            if not ok then
                -- 33-fix: 撤掉 25-fix 的 poll.stop() 回滚. 让用户进 platform 档,
                --   拉取失败时 poll 仍用 ds_pull 跑 (空/旧), 前端黄条会提示
                --   MQTT 未连接. MQTT 连上后 waitPullDone / auto_apply 会自动重拉
                log.warn("ctrl", "platform entered but pull_start failed: " .. tostring(err))
                S.cur = "platform"  -- 34-fix: 即便 pull_start 失败, 档位也切了
                return true, "OK platform (拉取未启动: " .. tostring(err) .. ")"
            end
            S.cur = "platform"  -- 34-fix: 记下当前 mode
            return true, "OK platform, pulling"
        end
        -- 手动档也向平台报到(hello)。平台侧不预知这台设备的具体配置, 靠
        -- 上报 auto-provision 补建 —— hello 是让平台知道"这台网关上线了"
        -- 的入口, 不发的话平台那头看不到设备。失败不回滚切模式: 手动档的
        -- 主职是采用户配的寄存器表, 平台那头看不到不影响采集。真没发出去
        -- 时 task_main 连上后会补发(见 iot.lua 的 hello on connect 分支)
        if iot then pcall(iot.hello) end
        S.cur = "manual"  -- 34-fix: 记下当前 mode
        return true, "OK manual started"

    elseif mode == "sniff" then
        if poll.is_running() then
            poll.stop()
            switch_delay()
        end
        if mon.is_running() then stop_sniff() end
        -- A 方案 (2026-10): 进 sniff = 新一轮。正常路径上"退出已清", 这里
        --   这次是兜底(设备断电重启后开机直进 sniff, 走的是 start 不是
        --   stop, 上次的名字还留在 fskv)。clear_alias 空表不写 fskv, 不费 flash
        if cfgstore and cfgstore.clear_alias then pcall(cfgstore.clear_alias) end
        -- ⚠️ sniff 也要复位 manual_on (2026-10 修): 之前只有 manual/platform
        --   分支调 set_manual, 从 manual 切到 sniff 时 manual_on 仍是 true ——
        --   后果不止是上位机"当前档次"显示成"手动配置":
        --     ① 订阅清单错: build_subs 在 manual_on=true 时只订用户那条 sub,
        --        平台那 5 条(config/get + service/invoke ×2 + pset + pget)全不订
        --        → 平台在 sniff 档下发的东西设备一条都收不到
        --     ② 上报 topic 错: profile() 走用户 pub_topic, sniff 的数据/建档
        --        报给用户自己的 broker, 平台那头看不到设备
        --   set_manual(false) 会断开重连换订阅清单, 必须在识别起来之前做
        if iot then pcall(iot.set_manual, false) end
        if mon.start() then
            -- 识别必须放后台: switch_mode 是同步的, 而且在开机路径(main.lua 的
            -- boot_mode)上也会被调用。同步等识别会把开机流程堵住, 而识别失败是
            -- 重试到成功为止的, 静默总线上开机就永远回不来
            mon.request_detect()
            -- sniff 也向平台报到。以前这里不碰 iot, 设备进旁听后平台完全
            -- 看不到它上线。失败不回滚: 旁听才是 sniff 的主职, 平台那头
            -- 连不上不该让用户连旁听都用不了
            if iot then pcall(iot.pull_start) end
            S.cur = "sniff"  -- 34-fix: 记下当前 mode
            return true, "OK sniff started, detecting"
        end
        return false, "FAIL sniff start"

    elseif mode == "idle" or mode == "stop" then
        if poll.is_running() then poll.stop() end
        stop_sniff()
        local cleared = M.reset_user_cfg()
        S.cur = "idle"  -- 34-fix: 记下当前 mode
        -- 第三个返回值是给 W:MODE 拼应答的(见 cmd.lua 的 cleared: 那段),
        -- msg 本身保持原样, 别把清单塞进去 —— switch_mode 的返回值有别的调用方
        return true, "OK idle (bus released)", cleared

    else
        return false, "FAIL unknown mode (use manual/platform/sniff/idle)"
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

-- 前端据此高亮对应的卡。platform 要单列一张卡, 不能和 manual 混:
-- 两者跑的是两套配置(手配 / 平台拉), 混在一起用户看不出当前在采哪份
-- 34-fix: 优先用 S.cur (switch_mode 记下的), 兜底用 poll/mon 推导
--   S.cur 必中; 兜底只在 S.cur 没更新过的极端路径才需要 (例如设备启动后
--   switch_mode 还没被调用过, 此时 S.cur="idle" 也是对的)
function M.get_mode()
    return S.cur
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
        poll_src = (poll.is_running() and poll.cur_slot()) or nil,
        pull_ready = cfgstore.pull_src(),
        pull = iot and iot.pull_status() or nil,
        poll = poll.status(),
        mon = mon.status(),
        write = poll.write_status(),
    }
end

log.info("ctrl", "mode arbiter ready, default=idle")

return M
