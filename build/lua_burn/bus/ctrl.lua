local util = require "util"
local log = util.log()
local sys = util.try("sys")

local mon = require "bus/mon"
local cfgstore = require "cfg"
local mqttcfg = require "iot/mqttcfg"
local iot = util.try("iot/iot")

local M = {}









local poll_mod
local poll_tried = false
local function pollmod(load)
    if load then
        if not poll_tried then
            poll_tried = true
            local ok, p = pcall(require, "bus/poll")
            poll_mod = ok and p or nil
            if not poll_mod then log.warn("ctrl", "bus/poll 加载失败") end
        end
        return poll_mod
    end
    if not poll_tried then return nil end   -- 从没加载 => 一定没在跑
    return poll_mod
end


local EMPTY_POLL = { running = false, timeout_ms = 500, baud = 9600, slave = 1,
                     interval = 5000, timeout = 0, regs = 0, gen = 0, zero = 0,
                     ok = 0, rounds = 0, werr = 0 }
local EMPTY_WRITE = { done = 0, queued = 0, fail = 0, qmax = 8 }






local S = { cur = "idle" }

local SWITCH_DELAY_MS = 50



local SLOT = { manual = "poll", platform = "pull" }




local function switch_delay()
    if not sys then return end
    local ok = pcall(sys.wait, SWITCH_DELAY_MS)
    if ok then return end
    pcall(sys.taskInit, function()
        pcall(sys.wait, SWITCH_DELAY_MS)
    end)
end




local function stop_sniff()
    if not mon.is_running() then return end
    mon.stop()
    if cfgstore and cfgstore.clear_alias then pcall(cfgstore.clear_alias) end
end

function M.switch_mode(mode, from_boot)



    from_boot = from_boot or false
    if type(mode) ~= "string" then
        return false, "FAIL unknown mode (use manual/platform/sniff/idle)"
    end
    mode = mode:lower():gsub("^%s+", ""):gsub("%s+$", "")




    if (mode == "manual" or mode == "platform" or mode == "sniff") and mon.is_detecting() then
        return false, "BUSY: 正在识别通讯参数, 完成后自动开始旁听(或先 W:MODE=idle 放弃)"
    end
    if mode == "manual" or mode == "platform" then










        if mon.is_running() then
            stop_sniff()
            switch_delay()
        end

        local pm = pollmod(true)
        if pm and pm.is_running() then pm.stop() end






        local slot = SLOT[mode]
        if iot then pcall(iot.set_manual, mode == "manual") end








        local have_cfg = true
        if mode == "manual" then
            have_cfg = cfgstore and cfgstore.has_poll_cfg and cfgstore.has_poll_cfg()
        elseif mode == "platform" then
            have_cfg = cfgstore and cfgstore.has_pull_cfg and cfgstore.has_pull_cfg()
        end
        if have_cfg then

            if not (pm and pm.start(slot)) then return false, "FAIL poll start" end
        else
            log.info("ctrl", string.format(
                "%s 档: %s 槽空, 暂不起轮询, 等配置就位后由 W:CFG / auto_apply 补起",
                mode, slot))
        end
        if mode == "platform" then





            local ok, err = iot and iot.pull_start()
            if not ok then



                log.warn("ctrl", "platform entered but pull_start failed: " .. tostring(err))
                S.cur = "platform"  -- 34-fix: 即便 pull_start 失败, 档位也切了
                return true, "OK platform (拉取未启动: " .. tostring(err) .. ")"
            end
            S.cur = "platform"  -- 34-fix: 记下当前 mode
            return true, "OK platform, pulling"
        end





        if iot then pcall(iot.hello) end
        S.cur = "manual"  -- 34-fix: 记下当前 mode
        return true, "OK manual started"

    elseif mode == "sniff" then


        local pm2 = pollmod(false)
        if pm2 and pm2.is_running() then
            pm2.stop()
            switch_delay()
        end
        if mon.is_running() then stop_sniff() end



        if cfgstore and cfgstore.clear_alias then pcall(cfgstore.clear_alias) end









        if iot then pcall(iot.set_manual, false) end
        if mon.start() then



            mon.request_detect()



            if iot then pcall(iot.pull_start) end
            S.cur = "sniff"  -- 34-fix: 记下当前 mode
            return true, "OK sniff started, detecting"
        end
        return false, "FAIL sniff start"

    elseif mode == "idle" or mode == "stop" then






        local pm3 = pollmod(false)
        if pm3 then pm3.stop() end
        stop_sniff()
        local cleared = M.reset_user_cfg()
        S.cur = "idle"  -- 34-fix: 记下当前 mode


        return true, "OK idle (bus released)", cleared

    else
        return false, "FAIL unknown mode (use manual/platform/sniff/idle)"
    end
end








function M.reset_user_cfg()
    local cleared = cfgstore.reset_user()

    local ok, err, wrote = mqttcfg.clear_manual()
    if ok then
        if wrote then cleared[#cleared + 1] = "mqtt_manual" end
    else


        log.warn("ctrl", "reset mqtt_manual fail:", tostring(err))
    end

    if wrote and iot then pcall(iot.kick) end
    return cleared
end






function M.get_mode()
    return S.cur
end

function M.is_busy()
    local pm = pollmod(false)
    return (pm and pm.is_running()) or mon.is_running()
end



function M.poll_loaded()
    return poll_mod ~= nil
end

function M.status()
    local pm = pollmod(false)
    return {
        mode = M.get_mode(),
        busy = M.is_busy(),


        poll_src = (pm and pm.is_running() and pm.cur_slot()) or nil,
        pull_ready = cfgstore.pull_src(),
        pull = iot and iot.pull_status() or nil,
        poll = pm and pm.status() or EMPTY_POLL,
        mon = mon.status(),
        write = pm and pm.write_status() or EMPTY_WRITE,
    }
end

log.info("ctrl", "mode arbiter ready, default=idle")

return M
