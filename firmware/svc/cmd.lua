local util = require "util"
local cfg = require "core/config"
local log = util.log()

local uart = util.get("uart")
local json = util.try("json")
local rtos = util.try("rtos")
local mobile = util.try("mobile")

local sn = require "sn/sn"
local ctrl = require "bus/ctrl"
local mon = require "bus/mon"
local collector = require "data/collector"
local cfgstore = require "cfg"
local mqtt_cfg = require "iot/mqttcfg"
local iot = util.try("iot/iot")
local guard = util.try("svc/guard")

local M = {}

-- ⚠️ 12-fix-8 (2026-10-28): bus/poll 改成【惰性 require】(见 bus/ctrl.lua 的说明)。
--   sniff 档不跑轮询, 这 14KB 常驻堆纯属白占; 而 sniff 档恰恰是现场崩的档位
--   (Lua 堆 307192 字节, 池用满 98.6% -> VM exit 重启)。
--   只有真的要碰轮询的命令(W:CFG / W:RAWTEST / R:REG)才会把它拉进来。
local poll_mod
local poll_tried = false
local function pollmod(load)
    if load then
        if not poll_tried then
            poll_tried = true
            local ok, p = pcall(require, "bus/poll")
            poll_mod = ok and p or nil
            if not poll_mod then log.warn("cmd", "bus/poll 加载失败") end
        end
        return poll_mod
    end
    if not poll_tried then return nil end
    return poll_mod
end

-- 单元测试用: bus/poll 到底有没有被拉进来 (12-fix-8)
function M.poll_loaded()
    return poll_mod ~= nil
end

-- 4 种工作模式提到模块顶部
-- 记录 3: 删 MODE_POLL/MODE_PULL (历史别名)。项目测试阶段, 没正式发布,
-- 不存在老 fskv 兼容场景, normalize_sys 限 4 值直接拒。
local MODE_MANUAL, MODE_PLATFORM, MODE_IDLE, MODE_SNIFF = "manual", "platform", "idle", "sniff"
-- 内部 cfgstore 槽名常量 (跟 boot_mode 历史别名不同, 是项目内部 API, 保留)
local SLOT_POLL, SLOT_PULL = "poll", "pull"

local UART_ID = uart.VUART_0
if UART_ID == nil then UART_ID = 4 end

local g_cmds = {}

-- ⚠️ 12-fix-9 (2026-10-29): 【别把整条应答打进日志】。
--   原来 log.debug("cmd", "tx:", s) 把整条应答(64 个地址时 8158 字节)
--   原样交给日志模块格式化 —— 那就是又一份 8KB 的分配 + 8KB 的串口输出。
--   现场 300KB 的堆就是这样被一次次抄没的(池 294448/307192 = 95.8%,
--   "alloc 8147 failed" → json encode out of memory → 整机卡死)。
--   只打长度 + 前 80 字节: 排查够用, 代价是一条小日志。
-- ⚠️ 128点排障 (2026-11-10): 应答【逐段写, 不拼整行】。
--   table.concat 出来的那份整行, 是 jencode 产物之外的【第二份完整拷贝】,
--   也就是发送峰值 = 2 倍应答体。60 点配置保存成功后前端点"读取配置",
--   应答体 3919B 已经躺在堆上了, concat 还要 3919B 的连续块 —— 池子贴着
--   天花板时正好切不出来, 现场就是这个错:
--     RET:FAIL:handler error:cmd.lua:100: not enough memory for buffer allocation
--   拆开发之后峰值只剩 1 倍应答体。
--   为什么可以拆: ① uart.write 是 C 调用, 不让出 CPU; LuatOS 协程是协作式的,
--     段与段之间没有 yield 点, 别的任务插不进来(VUART 上只有 cmd/prov 两个写者,
--     全都在自己的调用里写完)。② 收端一律按 \r\n 切行, 不按包边界: 前端
--     main.js 的 onData 有 rxBuffer, 产线 serial_port.py 的 read_line 读到 \n
--     为止。拆段只是把同一行分进几个 USB 包里。
local function tx_frags(frags)
    local n = 0
    for i = 1, #frags do n = n + #frags[i] end
    -- 前 80 字节: 逐段凑, 凑够就收手(每次应答最多 3 个小字符串, 都 <=80B)
    local head = ""
    for i = 1, #frags do
        if #head >= 80 then break end
        head = head .. frags[i]:sub(1, 80 - #head)
    end
    log.debug("cmd", "tx:", n, "B:", head)
    for i = 1, #frags do
        if #frags[i] > 0 then pcall(uart.write, UART_ID, frags[i]) end
    end
end

function M.reply(s)
    tx_frags({ s, "\r\n" })
end

-- 大应答(R:INFER / INFER_PUSH): payload 已经是一整串, 没有可省的第二份拷贝
local function reply_big(key, payload)
    tx_frags({ key, payload, "\r\n" })
end

-- ⚠️ 12-fix-11 (2026-10-29): JSON 应答走【片段表】, 不要在字符串上叠字符串。
--   原来的写法 M.reply("RET:X=" .. jencode(t)) 会造两份大字符串:
--   一份是 jencode 的产物, 一份是拼接后的整行; M.reply 里再 s.."\r\n"
--   又是第三份。R:STAT 现场实测 2226 字节, 每 5 秒问一次 →
--   每次 6.7KB 垃圾(2226×3), 一年不停 —— 现场池子 95% 的碎片就是这么攒的。
--   这里把 key / 各段 / 花括号 / 换行 全塞进一个表: 小片段本身是编码时
--   就在的, 不额外产生整行拷贝(2026-11-10 起连最后那次 concat 也省了,
--   见上面 tx_frags)。
--   传 table 时按 "{" frag "," frag "}" 拼(给 R:STAT 这种多段 JSON 用)。
--   json_reply_str 仍然 concat, 但只给单测验结构用
--   (见 M._json_reply_str / M._stat_reply), 串口上不走它。
local function json_reply_frags(key, val)
    local t
    if type(val) == "table" then
        t = { key, "{" }
        for i = 1, #val do
            if i > 1 then t[#t + 1] = "," end
            t[#t + 1] = val[i]
        end
        t[#t + 1] = "}"
    else
        t = { key, val }
    end
    t[#t + 1] = "\r\n"
    return t
end
local function json_reply_str(key, val)
    return table.concat(json_reply_frags(key, val))
end
local function reply_json(key, val)
    tx_frags(json_reply_frags(key, val))
end

-- 只拼不发(给单测用)。模拟器里 uart 是 C 库的只读表, 换不掉 write,
-- 截不到串口上的东西 —— 所以把"拼"这一步单独露出来, tests/lua/test_cmd_stat.lua
-- 直接验拼出来的结构。
function M._json_reply_str(key, val)
    return json_reply_str(key, val)
end

-- 识别期间挡住会动串口的命令
local function blocked_while_detecting(cmd)
    if not mon.is_detecting() then return false end
    M.reply("RET:FAIL:" .. cmd .. ":BUSY: 正在识别通讯参数, 完成后自动开始旁"
        .. "听(或先 W:MODE=idle 放弃)")
    return true
end

local function device_id_str()
    local ok, snc = pcall(require, "sn/sn")
    if ok and snc and snc.state() == "ready" then
        return _G.get_device_sn and _G.get_device_sn()
    end
    return nil
end

function M.reg(cmd, fn) g_cmds[cmd] = fn end

local function jencode(t)
    if not json then return "{}" end
    local ok, s = pcall(json.encode, t)
    return ok and s or "{}"
end

local function jdecode(s)
    if not json then return nil end
    local ok, t = pcall(json.decode, s)
    return ok and t or nil
end

-- 往外报的"原因"先过这一道: 应答是一整行的, 原因里带换行会把后面所有帧的
-- 解析搅乱; 太长会顶到应答缓冲。C 层那句(not enough memory for buffer
-- allocation)都是 ASCII, 截断不会切断多字节字符
local function brief(v, n)
    local s = tostring(v):gsub("[\r\n]", " ")
    n = n or 80
    if #s > n then s = s:sub(1, n) end
    return s
end

-- Lua 池水位后缀。诊断串里带上"当时池子什么样子", 一句话就能分清
--   【拼不出来】和【本来就没有】—— 不带水位时这两种情况在日志里长一个样。
--   取不到就整段不追加, 别用 0 冒充(0/0 会被读成"池子空着")
local function pool_tag()
    if not rtos then return "" end
    local ok, total, used = pcall(rtos.meminfo, "lua")
    if not ok or type(total) ~= "number" or type(used) ~= "number" then return "" end
    return " pool " .. math.floor(used) .. "/" .. math.floor(total)
end

-- jencode 的"带原因"版本。
--   ⚠️ 为什么不能继续让 jencode 失败回 "{}": 11-12 现场 R:VAL 那一次, 日志
--   里明明白白是 alloc 4023 → 编码不出来, 但应答是 RET:VAL={} ——前端把它
--   显示成"暂无数据: 设备可能未进入轮询模式"。两件事被说成了同一件:
--     1) 缓存里确实一行数据都没有(轮询没跑)
--     2) 缓存里有 60 行, 但拼不出一条应答(池子见底)
--   只有 jencode_err 把第二件如实报出来, 前端那句提示才不再是猜。
--   其余命令仍用 jencode: 本次只改 R:VAL(现场唯一被误读成"没数据"的那条),
--   不动 R:INFO/R:CFG/R:STAT 那些应答的形状。
local function jencode_err(t)
    if not json then return nil, "json 库不可用" end
    local ok, s = pcall(json.encode, t)
    if ok and type(s) == "string" then return s end
    return nil, brief(s) .. pool_tag()
end

-- jdecode 的"带原因"版本(道理和上面一样: 原来 bad json 这一个词同时代表了
--   "前端写的东西不合法"和"解码时分配不出来", 后者重发就能过, 前者重发永远
--   不过 —— 分不清就会一直重试或一直放弃)
local function jdecode_err(s)
    if not json then return nil, "json 库不可用" end
    local ok, t = pcall(json.decode, s)
    if ok and t ~= nil then return t end
    return nil, brief(ok and "解码结果为空" or t) .. pool_tag()
end

local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

-- W:MODE 的槽清单拼成 k:v 段。前端 protocol.js 按 ';' 分段、段内按【第一个】
-- ':' 拆键值, 所以段里的 ';' 会把一条拆成两条, 必须换掉; 后面的 ':' 无所谓
local function mode_seg(key, list)
    if type(list) ~= "table" or #list == 0 then return nil end
    local parts = {}
    for i = 1, #list do
        parts[i] = tostring(list[i]):gsub(";", " ")
    end
    return key .. ":" .. table.concat(parts, "+")
end

-- 12-fix-6: 主动把推断表推给前端。设备每发现一个新地址就推一次,
--   前端不用手动点刷新(用户 2026-10-28 要求)。
--   ⚠️ 键名用 INFER_PUSH 而不是 INFER: 前端的"单未决指令"靠键名配对,
--   跟 R:INFER 的应答撞名的话, 推送会被当成那条指令的应答吞掉。
--   由 iot 的 1 秒巡检调用(不在 sniff 热路径上 —— 一次推送要拼几 KB JSON,
--   放在收帧协程里就是新的碎片化来源)。
--
-- ⚠️ 12-fix-9 (2026-10-29): 推【当前页】, 不推整张表。
--   设备记着前端最近一次 R:INFER 要的是哪一页(mon.set_infer_view),
--   推同一页过去, 前端直接换掉那一页的缓存。
--   推整张表的话, 64 个地址就是 8KB 的 JSON —— 正是现场崩掉的那个大小。
function M.push_infer()
    if not mon then return false end
    -- V1-1 修复 (2026-11-06): SN 烧写期间暂停推送，避免干扰产线工具
    local prov = package.loaded["sn/prov"]
    if prov and prov.busy and prov.busy() then
        log.debug("cmd", "skip INFER_PUSH: SN busy")
        return false
    end
    local off, n = mon.infer_view()
    local ok, inf = pcall(mon.infer_page, off, n)
    if not ok or type(inf) ~= "table" then return false end
    -- 名字/标识符跟 R:INFER 走同一套映射(前端两处显示一致)
    if iot and iot.attach_names then inf = iot.attach_names(inf) end
    reply_big("RET:INFER_PUSH=", jencode(inf))
    return true
end

-- ==== W:CFG 分阶段内存采样 (2026-11-11, 仅开发版) ====
-- 为什么要有它: 128 点卡的是【内存峰值】这道门, 而厂家给的那张表是算出来的,
--   不是量出来的。整条 W:CFG 只有"解码 → 归一化 → 落盘"三步, 每一步都把整份
--   寄存器表在内存里过一遍, 但哪一步吃掉多少、峰究竟在哪, 只有一个办法知道:
--   在每一步的进出口各采一次样。
-- 两个数缺一不可:
--   used = 即时水位。相邻两次一减 = 这一步【留在堆上】多少。
--   max  = rtos.meminfo("lua") 的 max_used, 【自开机以来】的峰值。采样点看不见、
--          但确实在这一步内部出现过又立刻还掉的瞬时峰就是它 —— 落盘时 jencode
--          那份整串 JSON 属于这种(返回时字符串已经没了)。两次采样之间 max
--          涨了, 涨到的那个值就是这一步的真实峰值。
-- 装填只在开发版: reg_debug_cmds 里置 TR_ON, 发布版这四个函数就是白检一次 nil,
--   W:CFG 的行为一个字节都没变(该做的 GC 本来 >4096B 时就在做)。
-- ⚠️ max_used 是【自开机以来】的单调高水位, 不会回落 —— 所以"每段 max 比上段
--   高多少"这个读法只在【开机后第一次大配置保存】上成立: 那一次之后高水位已经
--   被顶上去了, 再存第二次各段的 max 全等于同一个数, 看着像"没有瞬时峰"。
--   现场读法因此是: 重启 → 存一次 96/128 点 → 立刻 R:CTRACE, 中间别插别的保存。
local TR_ON, TR, TR_LAST = false, nil, nil

local function trc_sample(stage)
    if not TR then return end
    local used, mx = -1, -1
    if rtos then
        local ok, _, u, m = pcall(rtos.meminfo, "lua")
        if ok then
            if type(u) == "number" then used = u end
            if type(m) == "number" then mx = m end
        end
    end
    local s = TR.s
    s[#s + 1] = string.format("%s %d/%d", stage, used, mx)
end

local function trc_begin(nbytes)
    if not TR_ON then return end
    -- 只保最近两条: 现场往往是"保存失败 → 再发 R:CTRACE", 失败那条最值钱,
    -- 不能被下一次点保存挤掉
    if TR then TR_LAST = TR end
    TR = { arg = nbytes, regs = -1, tot = -1, s = {} }
    if rtos then
        local ok, t = pcall(rtos.meminfo, "lua")
        if ok and type(t) == "number" then TR.tot = t end
    end
    trc_sample("enter")
end

-- 归一化之后调, 顺手做一次 full GC 再采样。为什么要 GC: 不主动收, used 里的
--   东西只是"看起来还在", 分不清"确实没引用了、能还回去"和"哪里还攥着它"
--   —— 现场"开机 16 秒存得下 80 点、107 秒存不下"要排除的正是后面这种。
--   11-12 起归一化改成原地(W:CFG 传 inplace), 解码表就是结果本身、没有
--   "放开 t"这一步, 所以 freed 段现在读的是"落盘之前 GC 能腾出多少",
--   不再是"那 13KB 还不还回来"(答案: 原地之后根本没有那 13KB)。
local function trc_freed()
    if not TR then return end
    collectgarbage("collect")
    trc_sample("freed")
end

local function trc_regs(n)
    if not TR then return end
    TR.regs = (type(n) == "table") and #(n.regs or {}) or -1
end

-- 一条采样 ≈ 200B, 单独 concat 一份字符串、单独一行发出去。
--   不用 reply_json: 那要 json.encode 再抄一份, 而这条命令恰恰是在池子快死的时候
--   读的, 每一份额外拷贝都可能让它自己失败。
local function trc_line(tr, tag)
    if not tr then return nil end
    local p = { string.format("%s arg=%d regs=%d tot=%d", tag, tr.arg, tr.regs, tr.tot) }
    for i = 1, #tr.s do p[#p + 1] = tr.s[i] end
    return table.concat(p, " | ")
end

-- 提交一份【已解码】的配置表: 归一化 -> 落盘 -> 按需重启轮询 -> 平台回报。
-- W:CFG(整行一次到) 和 W:CFINISH(分片攒齐) 共用这一条。
--   ⚠️ 为什么必须共用: 分片上传存在的唯一理由是"一整行 4KB 在轮询中接不进
--   来"(见下面 UP_PIECE_MAX 那段), 它只改【传输怎么分片】, 不改存储格式也不改
--   校验。要是 CFINISH 自己再写一遍提交逻辑, 两条路迟早某个校验或某次落盘
--   行为分叉 —— 那种 bug 只会以"手动保存能成、分片保存 somehow 不能成"的
--   形式在现场撞见, 而现场没法同时对比两条路。
-- 返回 (true) 或 (false, 原因)。原因一律由调用方原样带进 RET:FAIL:CFG:
local function commit_config(t)
    -- 第二个参数 true = 在 t 上【原地】归一化, 不再新建第二张表。
    --   11-12 现场 56 点这一段 +13048B, 那就是"归一化的第二份" —— 解码表
    --   和归一化表同时在堆上, 一次保存的入场费因此是 decoded+norm ≈ 28KB。
    -- ⚠️ 这里敢原地, 是因为 t 是调用方现解的私有表, 不进任何缓存;
    --    缓存里那份(raw)必须走纯函数路径, 见 cfg.lua 12-fix-3 的约定
    local n, err = cfgstore.normalize_poll(t, true)
    -- inplace 之后 n == t, 所以这一段应当贴着 0(还在涨就说明没走到原地路径)
    trc_sample("norm")
    -- ⚠️ 归一化失败就地返回: 采样的"停在第几段"就是"死在第几步",
    --    这里再多走一段 freed, 读的人会以为归一化过了
    if not n then return false, tostring(err) end
    trc_regs(n)
    trc_freed()
    local cur_mode = ctrl.get_mode()
    local slot = (cur_mode == "platform") and SLOT_PULL or SLOT_POLL
    local ok, serr
    -- 落归一化后的 n, 不再用 save_poll(t): 后者会在内部再 normalize 一遍,
    --   等于把 128 个寄存器表(~30KB)白造第二次
    if slot == SLOT_PULL then ok, serr = cfgstore.save_pull_norm(n)
    else ok, serr = cfgstore.save_poll_norm(n) end
    -- 落盘内部那份 jencode 字符串已经还掉了, used 看不见它; 靠 max 的涨幅
    trc_sample("saved")
    if not ok then return false, tostring(serr or "写入失败") end
    -- 34-fix: 进入 polling 档 (manual/platform) 时, 如果 poll 因为空配置
    --   没起来 (34-fix 的副作用, 之前一定起来), 现在写完要把 poll 启起来,
    --   否则用户添了表保存后什么都看不到
    -- idle/sniff 档: poll 本来就不该起, 即便 get_mode() 算出 SLOT_POLL
    --   也不在这两档起 (前端不会在这两档发配置, 这层防御是兜底)
    local in_poll_mode = cur_mode == "manual" or cur_mode == "platform"
    -- 配置提交就是在配轮询, 这里该把 poll 拉进来
    local poll = pollmod(true)
    if not poll then return false, "bus/poll 不可用" end
    if poll.needs_restart(n) then
        if poll.is_running() then
            poll.stop()
            poll.apply_cfg(n)
            -- ⚠️ 必须带槽: poll.start() 不传 src 会把 curSlot 强制置成 "poll"
            -- 第二个参数 = 刚归一化好的那份, start 里就不再 reload_cfg 了
            poll.start(slot, n)
        else
            poll.apply_cfg(n)
            if in_poll_mode then poll.start(slot, n) end
        end
    else
        poll.apply_cfg(n)
        if in_poll_mode and not poll.is_running() then
            -- 34-fix: needs_restart 不成立但 poll 没起来 (例如:
            --   manual 档进入时空 ds_poll → 34-fix 不起 → 用户添
            --   寄存器表但 baud/slave 没动 → needs_restart=false →
            --   之前没人调 poll.start). 补起
            poll.start(slot, n)
        end
    end
    if iot and iot.reply_config then pcall(iot.reply_config) end
    -- 重启轮询(建块计划)之后采一次。11-12 起 start 拿得到 n, 不再回头
    --   reload_cfg 解第二遍, 这一段应当只剩建块计划那点(几 KB 量级);
    --   还是 +15KB 往上跳就说明没走到传 n 的那条路(旧版这里 +26992B,
    --   池子 306168/307192 只剩 1024B —— 见 README 的 CTRACE 现场表)
    trc_sample("done")
    return true
end

-- ==== 分片上传的暂存状态(只在 RAM) ====
--   为什么只放 RAM: 这条路的目的是【让单行变小】, 存储格式一点没动(还是
--   cfg.lua 那套 fskv 分片槽)。暂存落了盘反而多出一份半写状态要管。
--   带来的好处: 上传中断(断电/放弃/片没凑齐)时 flash 里那份老配置完好无损,
--   比 st=w 那种半写头更安全 —— 这是白捡的。
--   mode 记下【第 1 片到达时】的模式: commit_config 按当刻 get_mode() 决定
--   落 ds_poll 还是 ds_pull, 上传途中切档会把这几十片送进另一个槽。
local up = { on = false, n = 0, got = 0, rows = {}, bytes = 0, mode = nil }

-- 会话作废。why 只进日志: 现场要能回答"我明明发了 8 片, 怎么说没会话",
--   答案通常是"中间插了一条 W:MODE / W:CFG, 那 8 片是被谁清掉的"
local function up_reset(why)
    if up.on and up.got > 0 then
        log.info("cmd", "分片暂存作废:", why or "-", "已收 " .. up.got .. "/" .. up.n)
    end
    up.on, up.n, up.got, up.bytes, up.mode = false, 0, 0, 0, nil
    up.rows = {}
end

-- ==== 上传期间的"轮询占用" ====
--   W:CBEGIN 会把轮询停下来腾接收窗口(见下面 W:CBEGIN 那段的实测)。停了的
--   轮询必须有人还回去, 否则前端一关页面, 设备就永远不采数了 —— 而这恰恰是
--   这条命令【唯一】新增的失败面。三个还回去的时机:
--     1) W:CSABORT  前端明确放弃(cfg.js 每条失败路都会发)
--     2) W:CFINISH 提交成功 —— commit_config 已经按新配置把轮询起了,
--        这里只是取消兜底, is_running() 那一层守卫让它自动变成空操作
--     3) 静默兜底   会话超过 HOLD_IDLE_S 没有任何一片到达
--   ⚠️ 为什么兜底是"静默"而不是"整场上传限时": 一片丢了前端会重试 3 次、
--   每次等 5 秒, 32 片的合法上传本来就可能跑到一两分钟, 定死的总时限会在
--   正常路上把轮询抢回来, 后面几片又撞回那 1024 的墙上。所以每条被接受的
--   指令都刷新 hold.touched, 只有【安静了 60 秒】才当前端不干了。
local HOLD_IDLE_S  = 60
local HOLD_TICK_MS = 5000
local hold = { armed = false, stopped = false, touched = 0, gen = 0 }

-- 前向声明: hold_arm 里那个兜底协程要调它, 而 Lua 的 local 只看得到【之前】
--   的声明 —— 不先挂这个名字, 协程里的 hold_restore 会解析成全局(=nil),
--   兜底一触发就是 "attempt to call a nil value", 而那正是最需要它的时候。
local hold_restore

-- W:CBEGIN 的档位闸门。实现挂在 reg_cmds 末尾的 sniff 那一节(和"谁靠 poll/
--   collector 干活"写在一起, 改那边的人看得见)。没挂 = 不拦。
local cbegin_guard

-- 试分配阶梯, 量【最大连续块】。R:MEM 和 W:CBEGIN 用同一个函数: 现场两个数
--   对不上就会多养一个假结论(11-12 复盘过)。每档前 full GC 一次 —— 上一档的
--   探测块要真还回去才测得准下一档, 代价是毫秒级停顿, 所以只在人工命令里用。
--   返回 (最后一档成功, 第一档失败)。
local function max_block(steps)
    local last_ok, first_fail = 0, 0
    for i = 1, #steps do
        local n = steps[i]
        collectgarbage("collect")
        local ok, s = pcall(string.rep, "x", n)
        if ok and type(s) == "string" and #s == n then
            last_ok = n
        else
            first_fail = n
            break
        end
    end
    return last_ok, first_fail
end

-- Lua 池已用字节。拿不到就回 nil —— 0 会被读成"池子空着"(R:MEM 同口径)
local function lua_used()
    if not rtos then return nil end
    local ok, total, used = pcall(rtos.meminfo, "lua")
    if ok and type(used) == "number" then return used, total end
    return nil
end

-- 腾水: 把"为了让下一行收得进来"能放掉的都放掉。返回放了哪几样(只给日志)。
--   四样东西按【谁攥着配置】挑的, 不是按谁占得多:
--     poll.stop()  regs + lastCfg + 【合并计划 plan】(plan.rows 里是每行的
--                  直接引用, 60 行就是 60 份, 原来 stop() 不清它 —— 见 bus/poll.lua)
--     clear_all()  dataCache(值/dtype/conf) + frames + ring
--                  ⚠️ ring 里没上报完的历史值会一起丢掉: 换配置本来就要重采,
--                  旧参数下的点没有意义, 2026-11-13 和用户明确定过这一条
--     drop_cache() cfg.lua 那份解码缓存 = 整份配置的表 + 各分片原始 JSON,
--                  现场最大的一块水, 且它缓存的正是马上要被换掉的那份
--     alias 缓存   iot 那张 name->alias 映射(从配置派生, 128 行几 KB)
--   动完收两轮垃圾: 这些都是【纯引用】, 不收到 GC 就等于没放。
local function make_room()
    local did = {}
    local poll = pollmod(false)
    if poll and poll.is_running and poll.is_running() then
        -- 只有真是我们停的, hold_restore 才负责还回去(别的场合轮询本来就没跑,
        --   还回去等于在 idle/sniff 档凭空起一个轮询)
        poll.stop()
        hold.stopped = true
        did[#did + 1] = "poll"
    end
    if collector.clear_all then
        local n = collector.clear_all()
        did[#did + 1] = "cache:" .. tostring(n or "?")
    end
    if cfgstore.drop_cache then
        did[#did + 1] = "cfgcache:" .. tostring(cfgstore.drop_cache() or "?")
    end
    if iot and iot.drop_alias_cache then pcall(iot.drop_alias_cache) end
    collectgarbage("collect")
    collectgarbage("collect")
    return did
end

local function hold_disarm()
    hold.armed = false
    hold.gen = hold.gen + 1     -- 让在跑的兜底协程下一轮自己退出
end

-- 装兜底协程。sys 拿不到(单元测试/裁掉协程库)就只打一行警告: 少一层保险,
--   但 CSABORT 那条明路还在, 不能因为这个拒绝开场。
local function hold_arm()
    hold.armed = true
    hold.touched = os.time()
    hold.gen = hold.gen + 1
    local mygen = hold.gen
    local sok, sys = pcall(require, "sys")
    if not sok or not sys or not sys.taskInit or not sys.wait then
        log.warn("cmd", "分片上传的静默兜底没装上(没有 sys 协程), 只能靠 W:CSABORT 还轮询")
        return
    end
    sys.taskInit(function()
        while hold.armed and mygen == hold.gen do
            sys.wait(HOLD_TICK_MS)
            if not (hold.armed and mygen == hold.gen) then break end
            if os.time() - hold.touched >= HOLD_IDLE_S then
                log.warn("cmd", "分片上传静默超 " .. HOLD_IDLE_S .. "s, 作废会话并交还轮询")
                up_reset("静默超时")
                hold_restore("静默超时")
                return
            end
        end
    end)
end

-- 有进展就把静默计时归零。没装兜底(armed=false)时空转, 不碰任何状态。
local function hold_touch()
    if hold.armed then hold.touched = os.time() end
end

-- 把 CBEGIN 停掉的轮询交还回去。幂等, 三条路都敢重复调。
hold_restore = function(why)
    hold_disarm()
    if not hold.stopped then return end
    hold.stopped = false
    local m = ctrl.get_mode()
    -- idle/sniff 档不该有轮询。上传途中切了档就跟着新档的规则走, 别硬起
    if m ~= "manual" and m ~= "platform" then
        log.info("cmd", "分片上传结束(" .. tostring(why) .. "), 当前档 " .. tostring(m) .. " 不起轮询")
        return
    end
    local poll = pollmod(false)
    if not poll then
        log.warn("cmd", "分片上传结束(" .. tostring(why) .. ") 但 bus/poll 不在, 轮询没还回来")
        return
    end
    if poll.is_running() then return end   -- commit_config 已经按新配置起了
    log.info("cmd", "分片上传结束(" .. tostring(why) .. "), 按 fskv 里那份旧配置恢复轮询")
    -- 不传第二个参数 = poll 自己 reload_cfg 从 fskv 读。上传期间 flash 一个字
    --   没动过(暂存只在 RAM), 所以这份就是开场之前跑着的那张表
    local ok, err = pcall(poll.start, (m == "platform") and SLOT_PULL or SLOT_POLL)
    if not ok then log.warn("cmd", "恢复轮询失败:", tostring(err)) end
end

-- 单元测试用: 直接触发一次静默兜底(测试环境没有 sys 协程, 等不到那 60 秒)
function M._cshold_fire()
    up_reset("_cshold_fire")
    hold_restore("_cshold_fire")
end

-- A 类：上位软件业务必需的 16 条指令
local function reg_cmds()
    -- R:INFO: 前端打开串口读设备信息用的第一条指令
    -- ⚠️ mobile.iccid / mobile.csq / mobile.rsrp 是【函数】, 必须调用取号
    M.reg("R:INFO", function()
        local function mval(k)
            if not mobile then return nil end
            local v = mobile[k]
            if type(v) == "function" then
                local ok, r = pcall(v)
                return ok and r or nil
            end
            return v
        end
        local okc, c = pcall(cfgstore.load_poll)
        local pc = okc and c or nil
        local okm, mc = pcall(mqtt_cfg.load)
        local mq = okm and mc or nil
        reply_json("RET:INFO=", jencode({
            project = _G.PROJECT,
            version = _G.VERSION,
            sn = _G.get_device_sn and _G.get_device_sn(),
            sn_state = sn.state(),
            lock = sn.locked() and 1 or 0,
            imei = sn.imei(),
            uid = sn.uid(),
            imsi = mval("imsi"),
            iccid = mval("iccid"),
            csq = mval("csq"),
            rsrp = mval("rsrp"),
            server = mq and mq.host or nil,
            baud = pc and pc.baud or cfg.BAUD,
            slave = pc and pc.slave or cfg.SLAVE_ADDR,
            regs = pc and #(pc.regs or {}) or 0,
        }))
    end)

    -- R:MODE: 前端 renderHome 读 st.mode/st.busy/st.poll/st.mon
    M.reg("R:MODE", function()
        reply_json("RET:MODE=", jencode(ctrl.status()))
    end)

    M.reg("W:MODE", function(arg)
        local v = trim(arg):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if v == "stop" then v = MODE_IDLE end
        -- 记录 3: 软切删了。"poll"/"pollpull" 现在直接被 ctrl.switch_mode
        -- 走下游拒掉, 不会翻译成 manual/platform。
        local ok, msg, cleared, notcleared = ctrl.switch_mode(v)
        if not ok then return M.reply("RET:FAIL:MODE:" .. tostring(msg)) end
        -- 切档成功 = 这 N 片要落的槽可能变了, 暂存会话直接作废(见 W:CSHARD)。
        --   切失败不动: 模式没变, 会话还成立
        up_reset("W:MODE 切档")
        -- 切回 idle 会顺带复位配置。用 k:v 而不是 k=v: protocol.js 的 kv 解析
        -- 要求整段里同时有 ';' 和 ':' 才拆键值对
        -- 11-12: notcleared 是"想清但没清掉"的槽。以前只报 cleared, 高水位下
        --   分片头读不出来 → slot_clear 失败 → 应答照说"OK", 旧表还在 flash 里。
        --   老前端见到不认识的键直接忽略, 加这一段向后兼容
        local segs = {}
        local s1, s2 = mode_seg("cleared", cleared), mode_seg("notcleared", notcleared)
        if s1 then segs[#segs + 1] = s1 end
        if s2 then segs[#segs + 1] = s2 end
        if #segs == 0 then
            M.reply("RET:MODE=OK")
        else
            M.reply("RET:MODE=OK;" .. table.concat(segs, ";"))
        end
    end)

    M.reg("R:CFG", function()
        -- 按当前运行模式取对应的配置槽
        local slot = (ctrl.get_mode() == "platform") and SLOT_PULL or SLOT_POLL
        -- ⚠️ 必须先取【函数】再调用, 不能写成 local c, e = (x) and a() or b():
        --   括号表达式在 Lua 里只保留第一个返回值, 第二个返回值(原因)会被静默
        --   截成 nil —— 那样下面那道闸永远不放行, 假配置照样发出去
        local loader = (slot == SLOT_PULL) and cfgstore.load_pull or cfgstore.load_poll
        local cfg, lerr = loader()
        -- 第二个返回值 = 归一化没能跑完的原因(见 cfg.lua 的 load_*)。这时候
        --   cfg 是【出厂默认表】, 不是设备里那份 —— 以前照样回 RET:CFG=,
        --   前端把默认表填进表单, 用户以为保存的那 56 行没了。
        --   11-12 现场那条 E/mem alloc 160 就是这么被说成"设备里没有配置"的。
        if lerr then return M.reply("RET:FAIL:CFG:" .. lerr) end
        -- src 必须反映本次 cfg 实际所在槽: pollpull 档下 ds_poll 空着但
        -- ds_pull 已被平台覆盖的情况很常见 (老用户从 poll 切到 pollpull),
        -- 之前这里写 poll_src() 永远查 K_POLL, 前端拿 src='default' 误判
        -- "平台没下发", 实际 ds_pull 已经有平台配置. 用 slot 决定查哪个 src
        local src = (slot == SLOT_PULL) and cfgstore.pull_src() or cfgstore.poll_src()
        reply_json("RET:CFG=", jencode({ cfg = cfg, slot = slot, src = src }))
    end)

    M.reg("W:CFG", function(arg)
        if blocked_while_detecting("CFG") then return end
        -- 整行一次到位的配置 = 分片会话的终结者: 攒着的那半份已经作废
        up_reset("W:CFG")
        trc_begin(#arg)
        -- 大配置(128 点整行最坏 12.7KB)解码前先收一轮垃圾: Lua 堆池平时就
        --   贴着天花板(R:STAT 每 5 秒造 1.5KB 串), 2026-11-10 现场保存 90 点
        --   时池子已 used 306712/307192, 连 160B 都分配不出来。
        --   ⚠️ GC 合并不了相邻空闲块(见 README 12-fix-8 第三层), 它救不了
        --   连续大块; 但这条路径上的分配绝大多数是寄存器表那种小对象,
        --   收一轮就有货。停顿只在人工保存时发生, 不在 UART 收帧路径上。
        --   分片路径(W:CSHARD)不走这一步: 片体本来就 <=2KB, 没有大块解码。
        if #arg > 4096 then collectgarbage("collect") end
        trc_sample("gc")
        local t, jerr = jdecode_err(arg)
        trc_sample("decoded")
        -- 原来这里固定报 bad json, 而"前端写得不合法"和"解码时分配不出来"
        --   共用这一个词 —— 后者重发就能过, 前者重发永远不过(见 jencode_err)
        if not t then return M.reply("RET:FAIL:CFG:" .. jerr) end
        local ok, reason = commit_config(t)
        if not ok then return M.reply("RET:FAIL:CFG:" .. reason) end
        M.reply("RET:CFG=OK")
    end)

    -- ==== 分片上传(W:CBEGIN / W:CSHARD / W:CFINISH / W:CSABORT) ====
    --   ⚠️ 为什么非有不可: 11-13 现场把这件事钉死了 —— 轮询跑起来之后
    --   R:MEM 是 max:3072 fail:4096, 而 60 行那份 W:CFG 是【一整行 4072B】,
    --   prov 把分片并成一行时 table.concat 要的正是那么大的连续块, 于是在
    --   【还没解析】的时候整条就被丢掉:
    --     E/mem used 293544, alloc 4089
    --     E/user.prov rx lost: concat fail, drop 4072B
    --   方案只做传输分片: 每片一个 <=2KB 的小 JSON 数组, 设备在 RAM 里攒成
    --   行表, W:CFINISH 时交给 commit_config —— 和 W:CFG 同一条提交路径,
    --   存储格式(fskv 分片槽)、校验(normalize_poll)一个字节都没改。
    --   好处不只是能收: 上传没走完就断电/放弃时, flash 里那份【老配置】完好
    --   无损(暂存只在 RAM), 比现在 st=w 那种半写状态更安全。
    --
    -- ⚠️ 2026-11-13 下午现场补正(这一段之前写着"清多少水都不解决问题(乙已
    --   实测否掉)", 那句是【错的】, 错在用一条已经被推翻的测量当地基):
    --   片切到 1200B 之后, 第二次保存【还是】失败, 而且死得更早 ——
    --     RET:MEM=mode:manual lua:294688/307192 max:1024 fail:2048
    --     E/user.prov rx lost: not enough memory for buffer allocation ... drop 1177B
    --   轮询跑着的时候连 R:STAT 都要不到 1280B(每 5 秒一条 handler error),
    --   14:21:26 更是 used 302184/307192、160B 都给不出。池子只剩 ~11KB 而
    --   最大连续块 1024 —— 片再切小只是把赌注从 1177 挪到 600, 不是解法。
    --   "腾水没用"这个结论当初只验到 W:GC: 实测 W:GC(trim_cache + 两轮 GC)
    --   前后 max 一点没抬(1024), 因为水不在【可回收】的对象里, 在【轮询自己在
    --   用】的那几张表里。而切一次 idle(= poll.stop + collector.clear_all +
    --   清配置)max 就从 1024 回到 6144 —— 同一次开机内就回来了。所以腾水有效,
    --   只是必须把轮询停下来腾。这就是下面 W:CBEGIN 的全部职责。
    -- 单片 body 上限。前端按 <=1200B 切, 设备只在明显离谱时拒收: 收到更大的
    --   片说明前端切错了, 当场拒绝比让它把池子打死好。
    --   ("片到底收不收得下"不再由这个常数担保, 那是 W:CBEGIN 现场探出来的)
    local UP_PIECE_MAX  = 2048
    local UP_PIECES_MAX = 32      -- n 的上限: 32 片 x 每片几十行, 远超 128 点
    local UP_ROWS_MAX   = 200     -- 暂存行数上限(和 cfg.lua 的 MAX_REGS 同量级)

    local function up_fail(i, why)
        log.warn("cmd", "CSHARD 第" .. i .. "片拒收:", why)
        return M.reply("RET:FAIL:CSHARD:" .. why)
    end

    -- ==== 开场: W:CBEGIN=<片数>,<单行预算字节> ====
    --   存在的理由只有一个: 【片自己】也得先收得进来。轮询跑着的时候最大连续块
    --   只有 1024B, 一片 1177B 的行在 prov 拼行阶段就被丢掉(2026-11-13 现场),
    --   后面写得再对都没用。所以先发一条【一定收得进来】的短命令(十来字节),
    --   由它把轮询停掉、把配置那一堆表放掉, 然后把腾完的水位如实回报。
    --   水还是不够就当场 FAIL —— 前端这时候一片都不用发, 用户立刻看到原因,
    --   而不是发满 N 片、每片重试 3 次、每次干等 5 秒超时。
    --   ⚠️ 只有这条命令会停轮询。W:CSHARD 第 1 片自己开会话(老前端不发 CBEGIN
    --   时的兼容路)保持原样: 不安兜底、不停轮询, 传不进去就跟今天一样失败。
    --   把"背后停掉正在跑的轮询"这件事收在一条显式开场命令里, 失败面只有一处,
    --   恢复也只有一处 —— 两条命令都能悄悄停轮询, 迟早会出现"没人记得是谁停的"。
    M.reg("W:CBEGIN", function(arg)
        if blocked_while_detecting("CBEGIN") then return end
        if cbegin_guard then
            local no = cbegin_guard()
            if no then return M.reply("RET:FAIL:CBEGIN:" .. no) end
        end
        local c = arg:find(",", 1, true)
        local n = tonumber(c and arg:sub(1, c - 1) or arg)
        if not n or n < 1 or n > UP_PIECES_MAX then
            return M.reply("RET:FAIL:CBEGIN:片数非法(1.." .. UP_PIECES_MAX .. ")")
        end
        -- 预算 = 前端那一行的【整行】字节数(含 W:CSHARD=i/n, 行头)。老前端不带
        --   就按设备自己的单片上限探。上下界都要卡: 太小等于没探, 太大说明
        --   前端切错了, 让它拿一个更大的数字来逼设备试分配没有意义。
        local budget = c and tonumber(arg:sub(c + 1)) or UP_PIECE_MAX
        if budget < 64 or budget > UP_PIECE_MAX + 256 then
            return M.reply("RET:FAIL:CBEGIN:单行预算 " .. tostring(budget)
                .. "B 不在 64.." .. (UP_PIECE_MAX + 256) .. " 之间")
        end
        up_reset("W:CBEGIN")
        up.on, up.n, up.got, up.mode = true, n, 0, ctrl.get_mode()
        local used = lua_used()          -- 先取水位的数, 再去试分配(探测本身吃块)
        local did = make_room()
        hold_arm()
        local mx = max_block({ 1024, 2048, 3072, 4096, 6144, 8192 })
        log.info("cmd", "分片上传开场 n=" .. n .. " mode=" .. tostring(up.mode)
            .. " 腾出[" .. table.concat(did, " ") .. "] max=" .. mx
            .. " used=" .. tostring(used))
        if mx < budget then
            -- 腾完还是接不住: 会话作废, 轮询原样还回去, 一句话把现场原因讲清。
            --   这句话会直接弹给用户, 所以带着"下一步该干什么"
            up_reset("CBEGIN 水位不够")
            hold_restore("CBEGIN 水位不够")
            return M.reply("RET:FAIL:CBEGIN:腾完水仍接不住 " .. budget
                .. "B 的单行(最大连续块只有 " .. mx .. "B), 重启设备后立刻保存, 或把表改小")
        end
        -- max 一起回报: 现场下一次不用为了"到底剩多少"再单独跑一轮 R:MEM
        M.reply("RET:CBEGIN=OK max:" .. mx .. " used:" .. tostring(used))
    end)

    M.reg("W:CSHARD", function(arg)
        if blocked_while_detecting("CSHARD") then return end
        -- 拆 "i/n,<JSON 行数组>"。用 find(",") 而不是 gmatch: 大字符串上
        --   gsub/gmatch 都要二次分配, 这条命令恰恰是在池子紧的时候用的
        local c = arg:find(",", 1, true)
        if not c then return up_fail(0, "缺 , 分隔") end
        local i, n = arg:sub(1, c - 1):match("^(%d+)/(%d+)$")
        i, n = tonumber(i), tonumber(n)
        if not i or not n then return up_fail(0, "片号不是 i/n") end
        if i < 1 or n < 1 or i > n then return up_fail(i, "片号超范围 n=" .. n) end
        if n > UP_PIECES_MAX then return up_fail(i, "片数超上限 " .. UP_PIECES_MAX) end
        local body = arg:sub(c + 1)
        if #body > UP_PIECE_MAX then
            return up_fail(i, "单片太大 " .. #body .. ">" .. UP_PIECE_MAX)
        end

        if i == 1 and up.on and up.n == n and up.got == 0 then
            -- 第 1 片接到【W:CBEGIN 已经开好】的会话上: 不重开。重开等于把开场
            --   时记下的模式换一遍、把刚腾好的空暂存再清一遍, 一点好处没有
            log.info("cmd", "第 1 片接上 CBEGIN 开的会话 n=" .. n .. " mode=" .. tostring(up.mode))
        elseif i == 1 then
            -- 第 1 片: 开新会话。同时记下【此刻】的模式 —— 落盘落在哪个槽
            --   是由模式决定的(commit_config 里按 get_mode 选 ds_poll/ds_pull),
            --   上传途中切档会把这 N 片送进另一个槽, 那才是真的灾难
            up_reset("CSHARD 第 1 片")
            up.on, up.n, up.mode = true, n, ctrl.get_mode()
            log.info("cmd", "分片上传开始 n=" .. n .. " mode=" .. tostring(up.mode))
        elseif not up.on then
            return up_fail(i, "没有上传会话, 先发第 1 片")
        elseif up.n ~= n then
            local why = "片数和正在收的那次不一样(n=" .. up.n .. " 收到 " .. n .. ")"
            up_reset("片数变了")
            return up_fail(i, why)
        elseif i == up.got then
            -- 同一片重发: 上一次已经收进暂存了, 只是应答在路上丢了。
            --   不能再追加一遍(追加=同一行存两份), 补一次 OK 让前端接着发下一片
            log.info("cmd", "第" .. i .. "片重复到达, 已按原样回 OK")
            hold_touch()
            return M.reply("RET:CSHARD=" .. i .. "=OK")
        elseif i ~= up.got + 1 then
            local want = up.got + 1
            up_reset("顺序断了")
            return up_fail(i, "顺序不对, 下一片应该是 " .. want)
        end

        local rows, jerr = jdecode_err(body)
        if not rows then
            up_reset("片解码失败")
            return up_fail(i, jerr)
        end
        if type(rows) ~= "table" then
            up_reset("片不是数组")
            return up_fail(i, "片不是 JSON 数组")
        end
        -- ⚠️ 逐行挪进暂存, 不把 rows 整张存下来: rows 这一层的表头是这一片
        --   独有的临时对象, 存下来就等于让一次解码的产物常驻; 行本身是解码
        --   产物、要留着, 所以只挪引用, 不复制行内容
        for k = 1, #rows do
            if type(rows[k]) ~= "table" then
                up_reset("第 " .. k .. " 项不是对象")
                return up_fail(i, "数组第 " .. k .. " 项不是对象")
            end
            if #up.rows >= UP_ROWS_MAX then
                up_reset("暂存行数超上限")
                return up_fail(i, "行数超上限 " .. UP_ROWS_MAX)
            end
            up.rows[#up.rows + 1] = rows[k]
        end
        up.got = i
        up.bytes = up.bytes + #body
        hold_touch()      -- 有进展就把"静默 60 秒"的计时归零
        M.reply("RET:CSHARD=" .. i .. "=OK")
    end)

    -- 收尾: "n,<除 regs 外的整份配置字段>"。
    --   为什么把非 regs 字段也放这里而不是让第 1 片带: 那份字段是【整张表】的
    --   一部分, commit_config 要的是完整一张表; 分两处传就要在设备里合并两处,
    --   多一个合并点多一类分叉。
    M.reg("W:CFINISH", function(arg)
        if blocked_while_detecting("CFINISH") then return end
        if not up.on then
            return M.reply("RET:FAIL:CFINISH:没有上传会话, 先发 W:CSHARD")
        end
        local c = arg:find(",", 1, true)
        local n = c and tonumber(arg:sub(1, c - 1)) or nil
        if not n then
            up_reset("CFINISH 缺 n")
            return M.reply("RET:FAIL:CFINISH:缺片数 n")
        end
        if n ~= up.n then
            local why = "片数不符(上传时说是 " .. up.n .. ", 收尾说 " .. n .. ")"
            up_reset("CFINISH 片数不符")
            return M.reply("RET:FAIL:CFINISH:" .. why)
        end
        if up.got ~= up.n then
            -- 只收了一半就收尾: 绝不能把它当成一份完整配置写下去。
            --   老配置必须原样留着, 所以这里连 commit 都不进; 会话也【留着】,
            --   前端只需要补发缺的那几片, 不用整份重传
            return M.reply("RET:FAIL:CFINISH:只收到 " .. up.got
                .. "/" .. up.n .. " 片, 补发第 " .. (up.got + 1) .. " 片起")
        end
        if ctrl.get_mode() ~= up.mode then
            -- 原因串要在 up_reset 之前凑好: 会话字段一清就全是 0/nil 了
            local why = "上传途中模式从 " .. tostring(up.mode) .. " 变成了 "
                .. tostring(ctrl.get_mode()) .. ", 这" .. up.n .. "片作废, 重新上传"
            up_reset("CFINISH 时模式变了")
            return M.reply("RET:FAIL:CFINISH:" .. why)
        end
        local base, jerr = jdecode_err(arg:sub(c + 1))
        if not base then
            up_reset("CFINISH 解码失败")
            return M.reply("RET:FAIL:CFINISH:" .. jerr)
        end
        if type(base) ~= "table" then
            up_reset("CFINISH 不是对象")
            return M.reply("RET:FAIL:CFINISH:收尾字段不是 JSON 对象")
        end
        -- 会话到此结束: 先把暂存的行交出去, 再放开会话引用。
        --   顺序很重要 —— up_reset 换掉 up.rows 这个字段, 已经挂到 base.regs
        --   上的那张表不受影响, 后面 commit_config 原地归一化用的就是它
        base.regs = up.rows
        local rows_n, bytes_n = #up.rows, up.bytes + #arg
        up_reset("CFINISH 提交")
        trc_begin(bytes_n)
        local ok, reason = commit_config(base)
        -- 校验/落盘失败的原因仍挂 CFG: 那是"这份配置被拒了", 与 W:CFG 逐字节同一句
        if not ok then
            -- 提交失败 = 会话到此为止(CFINISH 已经把暂存清了), 那就得由这一条
            --   把开场停掉的轮询还回去。前端这时候会跟着发 W:CSABORT, 但把设备
            --   停在"不采数"上等那句应答, 不如现在就恢复
            hold_restore("CFINISH 提交失败")
            return M.reply("RET:FAIL:CFG:" .. reason)
        end
        -- 成功: commit_config 里已按【新配置】把轮询起回来了, hold_restore 走到
        --   is_running() 那层守卫就是空操作 —— 它在这里的活只剩取消静默兜底
        hold_restore("CFINISH 提交")
        log.info("cmd", "分片上传提交完成 rows=" .. rows_n)
        -- ⚠️ 成功应答必须用【自己的键】RET:CFINISH。11-13 现场第一次分片保存
        --   就是这么骗人的: 设备 77.778s 已 rows=60 落盘并回了 RET:CFG=OK,
        --   但前端 sendCmd 等的键是 CFINISH —— app.js 的匹配条件是
        --   "resp.cmd == 在途指令的键", 这条应答谁也匹配不上, 于是 5s 超时 →
        --   重发 CFINISH(会话已清 → RET:FAIL:CFINISH:没有上传会话) → 再重发 →
        --   发 CSABORT → 弹"收尾失败"。真事是【存进去了】, 用户看到的是失败。
        M.reply("RET:CFINISH=OK")
    end)

    -- 放弃上传: 前端取消/重试整个流程时显式释放暂存, 不用等下一次第 1 片来
    --   覆盖。行为上 up_reset 在每条会动配置的命令里都会做, 这条只是让它立刻发生
    M.reg("W:CSABORT", function()
        local n = up.on and up.got or 0
        up_reset("W:CSABORT")
        -- 归还轮询放在 up.on 判断【外面】: 会话可能早被中间插进来的 W:MODE /
        --   W:CFG 清掉了, 而 CBEGIN 停掉的轮询还停着。那句"没有会话"要是顺手
        --   把归还也跳过, 设备就一直不采数, 只能等 60 秒兜底
        hold_restore("W:CSABORT")
        if n > 0 then log.info("cmd", "分片上传被放弃, 已暂存 " .. n .. " 片") end
        M.reply("RET:CSABORT=OK")
    end)

    M.reg("R:REG", function()
        -- poll 没加载 = 没起过轮询, 回空表即可(前端 manual 档下 poll 必然已加载)
        local pm = pollmod(false)
        local regs = pm and pm.get_regs() or nil
        reply_json("RET:REG=", jencode(regs or {}))
    end)

    M.reg("R:VAL", function()
        -- 编码不出来时必须单独报, 不能回 RET:VAL={} —— 见上面 jencode_err 的
        -- 说明: 那会把"应答拼不出来"说成"设备里没有数据"
        local s, err = jencode_err(collector.snapshot())
        if not s then return M.reply("RET:FAIL:VAL:" .. err) end
        reply_json("RET:VAL=", s)
    end)

    -- R:STAT 的片段表。单独抽出来是为了让单测能直接验结构
    --   (tests/lua/test_cmd_stat.lua) —— 模拟器里截不到串口输出。
    local function stat_parts()
        local parts = {}
        local m = ctrl.status()
        if m then parts[#parts + 1] = '"mode":' .. jencode(m) end
        local d = collector.stats()
        if d then parts[#parts + 1] = '"data":' .. jencode(d) end
        if guard then parts[#parts + 1] = '"guard":' .. jencode(guard.status()) end
        local it = iot and iot.status() or nil
        if it then
            -- ⚠️ 12-fix-8 (2026-10-28): 去掉重复的 "iot" 段。
            --   iot.status() 和 mqtt 段本来是同一份表(现场 R:STAT 实测两段
            --   逐字节一样), 应答里却各写一遍 —— 每 5 秒白多占 1.5KB
            --   连续内存。现场这堆碎片就是被这种大块顶死的:
            --     E/mem memory allocation failed total 307192, used 290368
            --   前端只读 "mqtt" 段(见 renderer/app.js 的 r.data.mqtt),
            --   "iot" 段没人用 —— 调试要看细节看 census 日志就行。
            local j = jencode(it)
            parts[#parts + 1] = '"mqtt":' .. j
        end
        return parts
    end

    -- R:STAT: 前端 readHome 读 mode/data/guard/mqtt 段
    M.reg("R:STAT", function()
        -- ⚠️ 12-fix-11 (2026-10-29): 改走 reply_json —— 原来这里
        --   "RET:STAT={" .. table.concat(parts, ",") .. "}" 拼两次,
        --   M.reply 里再 s.."\r\n" 拼第三次 = 2226×3 = 6.7KB 垃圾/次,
        --   而 R:STAT 每 5 秒就被前端问一次。现在全程只拼一次(4.4KB)。
        reply_json("RET:STAT=", stat_parts())
    end)

    -- 给单测用: 返回 R:STAT 的片段表和拼好的整行(模拟器里 uart.write 换不掉)
    function M._stat_reply()
        local parts = stat_parts()
        return parts, json_reply_str("RET:STAT=", parts)
    end

    -- 平台配置拉取: W 发起, R 轮询状态
    M.reg("W:PULLCFG", function()
        if not iot then return M.reply("RET:FAIL:PULLCFG:iot 不可用") end
        if iot.pulling() then return M.reply("RET:PULLCFG=BUSY") end
        local ok, err = iot.pull_start()
        if not ok then return M.reply("RET:FAIL:PULLCFG:" .. tostring(err)) end
        M.reply("RET:PULLCFG=started")
    end)

    M.reg("R:PULLCFG", function()
        if not iot then return M.reply("RET:FAIL:PULLCFG:iot 不可用") end
        reply_json("RET:PULLCFG=", jencode(iot.pull_status()))
    end)

    -- 38-fix: W:CLRPULL 清空 ds_pull. 场景: 前端从 platform 切 manual/sniff
    --   时弹窗, 默认勾选清空平台拉取配置. 设备收到后只擦 ds_pull (不动
    --   ds_poll / mqtt_manual / mqtt auto 凭证). 留个"已清空"应答, 前端
    --   能区分"设备端正常清掉了"和"命令丢失 / 设备忙".
    M.reg("W:CLRPULL", function()
        if not cfgstore then return M.reply("RET:FAIL:CLRPULL:cfgstore 不可用") end
        -- 不能在 platform 档正在拉取中清: 拉取链路可能正在写 ds_pull
        if iot and iot.pulling() then
            return M.reply("RET:FAIL:CLRPULL:平台正在拉取中, 稍后重试")
        end
        local ok, err, wrote = cfgstore.clear_pull()
        if not ok then return M.reply("RET:FAIL:CLRPULL:" .. tostring(err)) end
        up_reset("W:CLRPULL")
        -- wrote=false 时 ds_pull 本来就是空, 也回 ok 不报错, 避免前端
        -- 出现"没清成功"的误提示
        log.info("cmd", string.format("W:CLRPULL cleared=%s", tostring(wrote)))
        if wrote then return M.reply("RET:CLRPULL=OK;cleared:platform 配置")
        else return M.reply("RET:CLRPULL=OK;cleared:") end
    end)

    -- 2026-11: W:CLRINFER 清空 ds_infer (sniff 推断表持久化槽).
    --   场景: 前端从 sniff 切 manual/platform 时弹窗, 默认勾选清空推断表.
    --   前端在 W:MODE 之前发这条, 此时 sniff 可能还在运行, 允许清.
    M.reg("W:CLRINFER", function()
        if not cfgstore then return M.reply("RET:FAIL:CLRINFER:cfgstore 不可用") end
        local ok, err, wrote = cfgstore.clear_infer()
        if not ok then return M.reply("RET:FAIL:CLRINFER:" .. tostring(err)) end
        log.info("cmd", string.format("W:CLRINFER cleared=%s", tostring(wrote)))
        if wrote then return M.reply("RET:CLRINFER=OK;cleared:sniff 推断表")
        else return M.reply("RET:CLRINFER=OK;cleared:") end
    end)

    -- 2026-11: W:CLRPOLL 清空 ds_poll (手动配置槽).
    --   场景: 前端从 manual 切 platform/sniff 时弹窗, 默认勾选清空手动配置.
    --   前端在 W:MODE 之前发这条, 此时 poll 可能还在运行, 允许清.
    M.reg("W:CLRPOLL", function()
        if not cfgstore then return M.reply("RET:FAIL:CLRPOLL:cfgstore 不可用") end
        local ok, err, wrote = cfgstore.clear_poll()
        if not ok then return M.reply("RET:FAIL:CLRPOLL:" .. tostring(err)) end
        up_reset("W:CLRPOLL")
        log.info("cmd", string.format("W:CLRPOLL cleared=%s", tostring(wrote)))
        if wrote then return M.reply("RET:CLRPOLL=OK;cleared:manual 配置")
        else return M.reply("RET:CLRPOLL=OK;cleared:") end
    end)

    -- R:MQTT: 前端读 cfg / auto_pass / manual_on / pub / sub
    M.reg("R:MQTT", function()
        local e = mqtt_cfg.effective(device_id_str())
        reply_json("RET:MQTT=", jencode({
            cfg = e.cfg,
            auto_pass = e.cfg.auto and e.cfg.auto.pass or "",
            manual_on = e.cfg.manual_on,
            pub = e.pub,
            sub = e.sub,
            ready = e.ready,
            err = e.err,
            stat = iot and iot.status() or nil,
        }))
    end)

    -- V2 日志优化：R:NET 4G 网络快照
    M.reg("R:NET", function()
        if not mobile then return M.reply("RET:NET=mobile unavailable") end
        local st = mobile.status() or -1
        local c = (st==1 or st==5) and mobile.scell() or nil
        M.reply(string.format("RET:NET=iccid:%s;imsi:%s;imei:%s;num:%s;status:%d;csq:%s;rsrp:%s;rsrq:%s;snr:%s;band:%s;tac:%s;eci:%s;ip:%s",
            tostring(mobile.iccid()), tostring(mobile.imsi()), tostring(mobile.imei()),
            tostring(mobile.number()), st,
            tostring(mobile.csq()), tostring(mobile.rsrp()), tostring(mobile.rsrq()),
            tostring(mobile.snr()),
            tostring(c and c.band), tostring(c and c.tac), tostring(c and c.eci),
            tostring(socket.localIP() or "-")))
    end)

    -- V2 日志优化：R:IOT MQTT 连接快照
    M.reg("R:IOT", function()
        if not iot then return M.reply("RET:IOT=iot unavailable") end
        local s = iot.status()
        M.reply(string.format("RET:IOT=want:%d;conn:%d;sub:%d;sn:%s;host:%s:%s;manual:%d;pub:%s;subt:%s;ok:%d;fail:%d;bo:%d;err:%s;last:%s",
            s.want_run and 1 or 0, s.connected and 1 or 0, s.subscribed and 1 or 0,
            tostring(s.device_id), tostring(s.host), tostring(s.port),
            s.manual_on and 1 or 0, tostring(s.pub), tostring(s.sub),
            s.published or 0, s.failed or 0, s.backoff or 0,
            tostring(s.last_err or s.reject_reason or "-"), tostring(s.last_pub or "-")))
    end)

    M.reg("W:MQTT", function(arg)
        if not iot then return M.reply("RET:FAIL:MQTT:no iot") end
        local t = jdecode(arg)
        if not t then return M.reply("RET:FAIL:MQTT:bad json") end
        local ok, err = iot.apply_cfg(t)
        if ok then M.reply("RET:MQTT=OK") else M.reply("RET:FAIL:MQTT:" .. tostring(err)) end
    end)

    -- W:MQTTRC: 只重连, 不写配置
    M.reg("W:MQTTRC", function()
        if not iot then return M.reply("RET:FAIL:MQTTRC:no iot") end
        iot.kick()
        M.reply("RET:MQTTRC=OK")
    end)

    M.reg("R:REPORT", function()
        if not iot then return M.reply("RET:FAIL:REPORT:no iot") end
        iot.report_now()
        M.reply("RET:REPORT=OK")
    end)

    -- 2026-11: W:BOOTMODE 设置开机默认模式, 同时联动清除其他档配置
    --   设 manual → 留 manual, 清 ds_pull + ds_infer
    --   设 platform → 留 platform, 清 ds_poll + ds_infer
    --   设 sniff → 留 sniff, 清 ds_poll + ds_pull
    --   设 idle → 只改 boot_mode 值, 不碰配置
    M.reg("W:BOOTMODE", function(arg)
        local m = trim(arg):lower()
        local ok, err = cfgstore.save_sys({ boot_mode = m })
        if not ok then return M.reply("RET:FAIL:BOOTMODE:" .. tostring(err)) end
        -- 联动清除其他档配置
        local cleared = {}
        if m == MODE_MANUAL then
            -- 清 ds_pull + ds_infer
            local ok1, _, w1 = cfgstore.clear_pull()
            if ok1 and w1 then cleared[#cleared + 1] = "platform" end
            local ok2, _, w2 = cfgstore.clear_infer()
            if ok2 and w2 then cleared[#cleared + 1] = "sniff" end
        elseif m == MODE_PLATFORM then
            -- 清 ds_poll + ds_infer
            local ok1, _, w1 = cfgstore.clear_poll()
            if ok1 and w1 then cleared[#cleared + 1] = "manual" end
            local ok2, _, w2 = cfgstore.clear_infer()
            if ok2 and w2 then cleared[#cleared + 1] = "sniff" end
        elseif m == MODE_SNIFF then
            -- 清 ds_poll + ds_pull
            local ok1, _, w1 = cfgstore.clear_poll()
            if ok1 and w1 then cleared[#cleared + 1] = "manual" end
            local ok2, _, w2 = cfgstore.clear_pull()
            if ok2 and w2 then cleared[#cleared + 1] = "platform" end
        end
        -- idle 不碰配置
        if #cleared > 0 then
            M.reply("RET:BOOTMODE=OK;cleared:" .. table.concat(cleared, "+"))
        else
            M.reply("RET:BOOTMODE=OK")
        end
    end)

    -- R:SALIAS: 读 sniff 别名表 (用户给 reg<addr> 起的 id/name)
    M.reg("R:SALIAS", function()
        reply_json("RET:SALIAS=", jencode(cfgstore.load_alias()))
    end)

    -- W:SALIAS={key,id,name,dtype}: 单条 upsert, id/name 都空 = 删这条
    M.reg("W:SALIAS", function(arg)
        local t = jdecode(arg)
        if not t then return M.reply("RET:FAIL:SALIAS:bad json") end
        local function s(v) if type(v) == "string" then return v end return "" end
        local key = s(t.key)
        if not key:match("^reg%d+$") then
            return M.reply("RET:FAIL:SALIAS:bad key(要 reg<addr>)")
        end
        local ok, err = cfgstore.set_alias(key, s(t.id), s(t.name))
        if not ok then return M.reply("RET:FAIL:SALIAS:" .. tostring(err)) end
        -- 2026-11: 同步更新内存推断表行, 自动保存时能拿到最新 name/id/dtype
        local addr = tonumber(key:match("^reg(%d+)$"))
        if addr and mon.update_row_name then
            pcall(mon.update_row_name, addr, s(t.name), s(t.id), s(t.dtype))
        end
        M.reply("RET:SALIAS=OK")
    end)

    M.reg("R:BOOTMODE", function()
        -- 读开机默认模式 (fskv ds_sys.boot_mode)。前端 "运行状态总览" 卡片
        -- 用, 跟 W:BOOTMODE 配对: 改了 selBootMode 但没保存, 设备值跟本地
        -- 值不一致, 提示 dirty
        local sysc = cfgstore and cfgstore.load_sys()
        M.reply("RET:BOOTMODE=" .. (sysc and sysc.boot_mode or "idle"))
    end)

    -- ===== 2026-10 转正: 以下 3 条原在 B 类调试组 (发布版不注册) =====
    -- 但它们已是 sniff 档前端的正式依赖:
    --   R:AUTODETECT = 识别通讯参数的唯一入口 (切档自动识别/手动重识别全走它)
    --   R:INFER      = 推断轮询表 (识别成功自动推 / 最新值/参数名称两列都在它)
    --   R:FRAMES     = 总线报文卡的 2s 轮询 + 手动刷新
    -- 留在调试组的话, _build_flag=true 的发布固件里这仨查无此键:
    -- 平台上报不受影响 (设备内部 mon 照常跑), 但上位机三个诊断面板全灭,
    -- 且报错文案 ("21 组候选都没解出") 引导排查往 AB 线上去 = 误导现场。
    -- 所以挪进正式组。真要减表的瘦身面, 瘦的是 UI 入口而不是指令注册;
    -- 闭包只捕获 mon/iot, 开销可忽略。剩下确属探针/诊断的 4 条仍留 B 组
    -- R:FRAMES[=n]  n 取 1..50, 默认 20
    M.reg("R:FRAMES", function(arg)
        local n = 20
        if arg then
            local v = tonumber(arg)
            if v then n = math.floor(v) end
        end
        if n < 1 then n = 1 end
        if n > 50 then n = 50 end
        reply_json("RET:FRAMES=", jencode(mon.recent_frames(n)))
    end)

    -- R:INFER[=off,n]: 从旁听帧反推轮询表 (attach_names 给每行补 name 字段, 与
    --   U4 上报的 name 同一套映射, 前端推断表"参数名称"列直接显示)
    --
    -- ⚠️ 12-fix-9 (2026-10-29): 【分页】。off=起始行号(0 起), n=本页行数。
    --   现场(09:14~09:19, 64 个地址)整表应答是 8158 字节的 JSON, 峰值连续块
    --   需求 8158, 而那会儿 Lua 池已经 294448/307192 = 95.8% →
    --   "alloc 8147 failed" → json encode out of memory → RET:INFER={} →
    --   系统池也见底 → "E/uart system is out of memory!!!" → 整机卡死。
    --   分页后一次最多 32 行, 应答 ~4KB, 峰值需求减半。
    --   ⚠️ 前端要一起改(app.js 的 doInfer/renderInfer): 按页取 + 显示页码。
    M.reg("R:INFER", function(arg)
        local off, n = 0, nil
        if arg and arg ~= "" then
            local a, b = arg:match("^(%d*)%s*,%s*(%d*)")
            if a then
                off = tonumber(a) or 0
                n = tonumber(b)
            else
                local v = tonumber(arg)
                if v then off = v end
            end
        end
        -- 记下前端在看哪一页: 主动推送也推这一页
        mon.set_infer_view(off, n)
        reply_big("RET:INFER=", jencode(iot.attach_names(mon.infer_page(off, n))))
    end)

    -- 12-fix-6: W:INFERWATCH=1|0 —— 前端 sniff 面板打开/关闭。
    --   打开: 设备每发现一个新地址就把整张推断表推过来(RET:INFER_PUSH=),
    --   前端不用手动点刷新。关闭: 停推(没人看, 推了纯占串口)。
    --   ⚠️ 这是【设备主动】发的, 不受"单未决指令"约束: 前端正在等某条
    --   指令的应答时来一条推送, 前端必须能把它跟那条应答分开
    --   (见 frontend/renderer/app.js 的 onSerialLine)。
    M.reg("W:INFERWATCH", function(arg)
        local on = (arg == "1" or arg == "on" or arg == "true")
        mon.set_infer_watch(on)
        M.reply("RET:INFERWATCH=" .. tostring(on))
    end)

    -- R:AUTODETECT: 非阻塞, 由前端轮询; arg 精确等于 "restart" 时强制作废
    --   上一轮结果并重扫 (前端「重新识别通讯参数」按钮用)。⚠️ 不是判空:
    --   M.handle 对裸指令也把整行当参数传进来 (pcall(fn, line), 裸发时
    --   arg = "R:AUTODETECT"), 判空会让每次轮询都被当成 restart —— 实测
    --   后果就是轮询自己把识别轮每秒作废一次, 永远扫不出参数 (2026-10 踩过)
    --   restart 走 mon.restart_detect: 先清旧帧旧值(旧参数下的东西不能混进
    --   新一轮推断), 再重扫 (2026-10)
    --   2026-11: restart 时同时清 ds_infer (持久化推断表), 做到真正的"重新识别"
    M.reg("R:AUTODETECT", function(arg)
        if arg == "restart" then
            if not mon.is_running() then
                return M.reply("RET:FAIL:AUTODETECT:not in sniff mode")
            end
            -- A 方案 (2026-10): 重新识别 = 新一轮, 名字(别名表)一起清 ——
            -- 名字是"这一轮推断结果"的注解, 新一轮地址变了旧名字就张冠李戴
            if cfgstore and cfgstore.clear_alias then pcall(cfgstore.clear_alias) end
            -- 2026-11: 持久化推断表也清, 否则下次进 sniff 会加载旧的
            if cfgstore and cfgstore.clear_infer then pcall(cfgstore.clear_infer) end
            local ok, err = mon.restart_detect()
            if not ok then
                return M.reply("RET:FAIL:AUTODETECT:" .. tostring(err))
            end
            return M.reply("RET:AUTODETECT=BUSY")
        end
        if not mon.is_running() then
            return M.reply("RET:FAIL:AUTODETECT:not in sniff mode")
        end
        if mon.is_detecting() then
            return M.reply("RET:AUTODETECT=BUSY")
        end
        local last = mon.detect_result()
        if last then
            return reply_json("RET:AUTODETECT=", jencode({
                baud = last.baud, databits = last.databits,
                stopbits = last.stopbits, parity = last.parity,
                fallback = last.fallback or false,  -- Q2: 区分命中 vs 兜底 cfg.BAUD
            }))
        end
        mon.request_detect()
        M.reply("RET:AUTODETECT=BUSY")
    end)

    -- ==== sniff 档别被 W:CBEGIN 停掉 ====
    --   11-13 加 W:CBEGIN 时撞出来的口径缺口: 腾水里最狠的两刀是 poll.stop()
    --   和 collector.clear_all(), 而 sniff 档【也在用这两个东西】—— mon 自己
    --   起停轮询做参数探测, 抓到的帧就落在 collector 那份缓存里。sniff 跑到一半
    --   被一条开场命令停了轮询、清了帧, 那一轮推断就废了, 而前端根本不会在
    --   sniff/idle 档保存配置(README 的档位说明里写着)。
    --   所以这一条不是"支持在 sniff 档上传", 是一道【别越界】的门。
    --   ⚠️ 重定义【不行】: hold_restore 是 hold_arm 里那个兜底协程的 upvalue,
    --   在这儿换个同名的新 local, 兜底那条路还在调旧的 —— 现场就变成"明路会拦、
    --   暗路不拦"。加一个标志位, 让两条路共用同一个函数。
    cbegin_guard = function()
        if ctrl.get_mode() == "sniff" then
            return "sniff 档在靠 poll/collector 做推断, W:CBEGIN 不能在这儿停轮询腾水; 要改配置先切 manual 或 platform"
        end
        return nil
    end
end

-- B 类：仅开发调试用的 5 条指令。发布版整个函数不调用,
-- 键 + 闭包 + 闭包内捕获的 poll/iot 等 upvalue 全部不进注册表,
-- 出厂固件更小、也不接受任何探针/总线诊断入口。
--   W:GC      强制 GC + 踢连接 (乱用会断 MQTT, 不给客户)
--   W:RAWTEST 485 裸探针: 能直接往总线上发原始帧 —— 交付版绝对不能开,
--              现场排障时切开发版烧一次 (见 lua/README.md「开发版 vs 发布版」)
--   R:MEM     内存口径探针 (2026-11-10 为 128 点排障重新加回, 见下面说明)
--   W:FS      文件系统探针 (2026-11-11 为 128 点路线 B 定生死, 见下面说明)
--   R:CTRACE  读 W:CFG 的分阶段内存采样 (2026-11-11, 为 128 点量出真实峰值)
-- 历史: 2026-10 曾把 R:NET/R:MEM 删掉(信息早就并进 R:STAT 的 iot/guard 段,
--   前端 0 引用, 留着只是白占脚本区)。R:MEM 现在【换了职责】才加回来:
--   它量的不是水位(那部分 R:STAT 已经有了), 而是【最大连续可分配块】——
--   水位判不出碎片化, 而这正是 128 点卡住的那一层。
--   R:FRAMES/R:INFER/R:AUTODETECT 已转正进 reg_cmds
local function reg_debug_cmds()
    TR_ON = true                   -- 打开 W:CFG 的分阶段采样(见文件顶部说明)
    M.reg("W:GC", function()
        collector.trim_cache()
        collectgarbage("collect")
        collectgarbage("collect")
        if iot then iot.kick() end
        M.reply("RET:GC=OK")
    end)

    -- R:MEM: 三个口径一次报齐, 应答刻意压在 80 字节内(tx_frags 只打前 80)。
    --   为什么要单独一条: 现场两条日志互相误导 ——
    --     I/user.guard ... mem=67940/203040        ← rtos.meminfo("sys")
    --       系统池只用了 33%, 看着"内存多得很"
    --     E/mem memory allocation failed total 307192, used 306768, alloc 160
    --                                             ← Lua 池 99.86% 满, 160B 都给不出
    --   R:STAT 里带了 lua_kb, 但那一段永远被 80 字节截断掉, 现场看不到。
    --   max/fail: 阶梯试分配。Lua 池是固定池, 碎片化时总量够也拿不到连续大块
    --   (GC 只能回收, 合并不了相邻空闲块), 所以"还剩多少"和"能发出 3.9KB
    --   的应答体"是两件事, 必须分开量。
    --   ⚠️ 每档前做一次 full GC(上一档的探测块要真还回去才测得准下一档),
    --      有毫秒级停顿 —— 这也是它只进开发版的原因。
    --   11-12 补: 加 mode=, sys 改 KB。原因 —— 现场两次读数对不上, 复盘才发现
    --     一次是 idle 档(没起轮询)、一次是 manual 档在轮询, 而应答里没有任何
    --     东西说明当时是什么档, 于是把"轮询把池子打碎"这个假结论供了两轮。
    --     mode 放最前是因为 log 只打应答前 80 字节, 后缀名再长也得看得见;
    --     sys 换成 KB 是给 mode 腾这 12 个字节(系统池从来不是判据, Lua 池的
    --     used/total 保持字节原样)
    M.reg("R:MEM", function()
        local p = {}
        p[#p + 1] = "mode:" .. tostring(ctrl.get_mode())
        p[#p + 1] = string.format("lua:%dK", math.floor(collectgarbage("count")))
        if rtos then
            -- 池水位: "lua" 是 Lua 固定池(307192 那个), "sys" 是系统池。
            -- 拿不到就整段不报, 别用 0 冒充(0/0 会被读成"池子空着")
            -- sys 报 KB(见上面注释), lua 报字节不动
            for _, k in ipairs({ "lua", "sys" }) do
                local ok, total, used = pcall(rtos.meminfo, k)
                if ok and type(total) == "number" and type(used) == "number" then
                    if k == "sys" then
                        p[#p + 1] = string.format("%s:%d/%dK", k,
                            math.floor(used / 1024), math.floor(total / 1024))
                    else
                        p[#p + 1] = string.format("%s:%d/%d", k, used, total)
                    end
                end
            end
        end
        -- 阶梯挪进 max_block 了: W:CBEGIN 也要量同一个数, 两处口径必须一样
        local last_ok, first_fail = max_block({ 1024, 2048, 3072, 4096, 6144, 8192, 12288, 16384 })
        p[#p + 1] = string.format("max:%d fail:%d", last_ok, first_fail)
        M.reply("RET:MEM=" .. table.concat(p, " "))
    end)

    -- W:FS: 文件系统探针。128 点路线 B(整份配置写文件, 不受 fskv 单值 4096 约束)
    --   成不成立, 只取决于三件事, 这一条指令一次答完:
    --     1) Lua 侧到底有没有 io.open
    --     2) 可写区有多大 (io.fsstat)
    --     3) 写 8192B → 读回 → rename → 删, 整条走得通吗
    --   为什么现在必须测: 开机日志两行摆在那儿互相打架 ——
    --     self_info: firmware[1] BASIC fs 128kbyte   +  D/sfd.lfs init ok
    --     而 README 早年写的是"fs 库和 rtos.fsinfo 都取不到 ⇒ 本机型没有可写
    --     文件系统", 据此选了 fskv。合宙指出那是【查错了函数名】: fs 库已被
    --     io 库取代(io.fsstat 替 fs.fsstat), 我们从没试过 io.open。
    --   所以这里不猜: 逐个报函数存在性(报 nil 也要报, 缺字段会被读成"日志
    --     被截断没看见", 明写 nil 才是明确答案), 再真写一次。
    --   ⚠️ 探测会往可写区写一个 8KB 临时文件再删掉, 不碰任何配置/键。
    --   ⚠️ 8192B 那块 blob 同时就是"能不能一次切出 8KB 连续块"的实测——
    --      128 点整份配置正好是这个尺寸, 白捡一个数据点。
    --   ⚠️ 路径形状未知(绝对/裸名), 每种都试: 只试一种失败就下"没有文件系统"
    --      的结论, 正是这次要避开的第二个坑。/luadb 是只读烧录区, 不试。
    M.reg("W:FS", function()
        local p, verdict = {}, "?"
        -- ⚠️ 取库的口径必须和业务代码【一模一样】。11-12 现场这条报的是
        --   `open:no-lib fsstat:no-lib exist:no-lib fsize:no-lib rm:no-lib ren:no-lib`
        --   —— 六个字段齐刷刷 no-lib。可 `ren:` 那格查的是【os 库】, 而
        --   `os.clock()`/`os.time()` 是这台设备每一轮轮询都在用的
        --   (bus/mon.lua、data/collector.lua:98 那个 ts 就是它写的)。
        -- 真原因当场钉死了(下一版实测 io(env:userdata raw:userdata try:userdata)
        --   + `=>B:YES 108K/128K`): LuatOS 把 io/os 做成【userdata 库对象】,
        --   而探针里那句 `if type(io_lib) ~= "table" then ... no-lib` 把
        --   userdata 一把推进了"没有库"分支 —— 六个字段全是那一条判断写出来的。
        --   先前怪给 `rawget(_G, "io")`(说它绕过 __index)是【我的误判】:
        --   三个口径报出来的类型一模一样, rawget 看得见。口径不是问题,
        --   问题是【只认 table】这一条判断。
        --   拿这条假阴性下过"路线 B 死了"的结论, 白扔了整整一轮排障。
        -- 三种口径仍然一起报(留作机制证据, 顺序: env 在前, 日志只打前 80 字节):
        --   env  直接引用 ENV[name] —— 与 os.clock() 同一条解析路径, 判定以它为准
        --   raw  rawget(ENV, name) —— 库是否真在主全局表里(原探针的口径)
        --   try  util.try(name) —— 项目取库的现役写法(_G 索引 + require 兜底)
        local ENV = _ENV or _G -- 5.1 上没有 _ENV(取到 nil), 退回 _G
        local function env_get(n)
            local ok, v = pcall(function() return ENV[n] end)
            if not ok then return nil, "raise" end
            return v, type(v)
        end
        local function look(n)
            local _, t = env_get(n)
            local tr = util.try(n)
            return n .. "(env:" .. t .. " raw:" .. type(rawget(ENV, n))
                .. " try:" .. type(tr) .. ")"
        end
        p[#p + 1] = look("io")
        p[#p + 1] = look("os")
        local io_lib = (env_get("io"))
        local os_lib = (env_get("os"))
        -- 库可能是 table 也可能是 userdata(带 __index 的库对象), 两种都算"有库"
        local function is_lib(t)
            return type(t) == "table" or type(t) == "userdata"
        end
        local function fn(t, n)
            if not is_lib(t) then return "no-lib" end
            -- 索引本身也可能 raise(userdata 的 __index 是 C 函数), 不能让它冒出来
            local ok, v = pcall(function() return t[n] end)
            if not ok then return "index-raise" end
            return tostring(type(v))
        end
        p[#p + 1] = "open:" .. fn(io_lib, "open")
        p[#p + 1] = "fsstat:" .. fn(io_lib, "fsstat")
        p[#p + 1] = "exist:" .. fn(io_lib, "exists")
        p[#p + 1] = "fsize:" .. fn(io_lib, "fileSize")
        p[#p + 1] = "rm:" .. fn(io_lib, "remove")
        p[#p + 1] = "ren:" .. fn(os_lib, "rename")
        if rtos then p[#p + 1] = "rtos.fsinfo:" .. tostring(type(rtos.fsinfo)) end

        -- io.fsstat 返回几个值、第一个是不是 bool, 各版固件说法不一
        -- → 只认"从 pcall 返回里挑出前三个数", 别按写死的下标解
        local function nums(t)
            local out = {}
            for i = 1, #t do
                if type(t[i]) == "number" then out[#out + 1] = t[i] end
            end
            return out
        end
        local space = "?"
        if fn(io_lib, "fsstat") == "function" then
            local pack = { pcall(io_lib.fsstat, "/") }
            local n = nums(pack)
            if #pack >= 1 and pack[1] and #n >= 2 then
                -- 三个数 = 块数,已用块,块字节 (合宙给的口径 32/4/4096);
                -- 只有两个数 = 已经是字节 (总量,已用)。两种都算, 别猜死一种
                local tot, free
                if #n >= 3 then
                    tot, free = n[1] * n[3], (n[1] - n[2]) * n[3]
                else
                    tot, free = n[1], n[1] - n[2]
                end
                if free < 0 then free = -1 end
                space = string.format("%dK/%dK", math.floor(free / 1024),
                    math.floor(tot / 1024))
                local raw = {}
                for i = 1, #n do raw[i] = tostring(n[i]) end
                p[#p + 1] = "fs=" .. table.concat(raw, ",")
            else
                space = "stat-fail"
            end
        end
        p[#p + 1] = "free:" .. space

        -- 真写一次: tmp → 校验长度 → rename → 校验 → 删
        local blob = nil
        if fn(io_lib, "open") ~= "function" then
            -- 没有 io.open 就谈不上写, 别去 alloc —— 报成"申请不到 8K"
            -- 会把结论带歪(那是内存问题, 这是固件没编 io 库, 下一步完全不同)
            p[#p + 1] = "blob:skip"
            verdict = "B:NO(没有io.open)"
        else
            local ok, s = pcall(string.rep, "x", 8192)
            if ok and type(s) == "string" and #s == 8192 then blob = s end
            if not blob then
                p[#p + 1] = "blob:FAIL-8K"
                verdict = "B:NO-MEM(8KB申请不到)"
            else
                local done, open_nil = false, false
                for _, tmp in ipairs({ "/vk_probe.tmp", "vk_probe.tmp" }) do
                    if not done then
                        local bin = tmp:gsub("tmp$", "bin")
                        local r = { path = tmp:sub(1, 1) }
                        local f = io_lib.open(tmp, "wb")
                        if not f then
                            r.w = "open-nil"
                            open_nil = true
                        else
                            local wok = f:write(blob)
                            f:close()
                            r.w = wok and "ok" or "write-fail"
                            local sz = io_lib.fileSize and io_lib.fileSize(tmp) or -1
                            r.wsz = tostring(sz)
                            if fn(os_lib, "rename") == "function" then
                                r.ren = tostring(os_lib.rename(tmp, bin))
                            else
                                r.ren = "no-rename"
                            end
                            local g = io_lib.open(bin, "rb")
                            if g then
                                local got = g:read("*a") or ""
                                g:close()
                                r.rsz = tostring(#got)
                            else
                                r.rsz = "read-fail"
                            end
                            if io_lib.remove then
                                io_lib.remove(bin)
                                io_lib.remove(tmp)
                            end
                            if io_lib.exists then
                                r.left = tostring(io_lib.exists(tmp) or io_lib.exists(bin))
                            end
                            -- 判据只看"写完 + 改名后读回 8192"。fileSize 在部分
                            -- 固件里不存在(wsz 会是 -1), 它是补充信息不是闸门 ——
                            -- 拿它当条件会把一条明明能用的路径误判成 B?
                            done = (r.w == "ok" and r.rsz == "8192")
                        end
                        local q = {}
                        for k, v in pairs(r) do q[#q + 1] = k .. "=" .. v end
                        table.sort(q)
                        p[#p + 1] = "probe:" .. table.concat(q, " ")
                    end
                end
                if done then
                    verdict = "B:YES"
                elseif open_nil then
                    verdict = "B:NO(open返回nil)"
                else
                    verdict = "B?:写了没读回8192"
                end
            end
        end
        log.info("fs", "probe", verdict, space)
        M.reply("RET:FS=" .. table.concat(p, " ") .. " =>" .. verdict)
    end)

    -- R:CTRACE: 读最近两次 W:CFG 的分阶段内存采样 (#1=上一条, #2=最新一条)。
    --   用法: 点一次"保存配置"(或串口发 W:CFG), 再发这条。保存失败【不用重跑】,
    --   失败那条采样本来就留着。
    --   每段的 "a/b" = used/max_used; 相邻两段的 used 之差 = 这一步留下多少,
    --   任何一段的 max 高于前一段 = 前一步内部冒出过更高的瞬时峰。
    --   为什么单独一条指令、不并进 RET:CFG=OK: 前端按 "RET:CFG=OK" 判成败,
    --   后面多挂一串字符就变成"保存失败", 而且产线工具同样按整行对答。
    M.reg("R:CTRACE", function()
        if not TR then return M.reply("RET:CTRACE=empty (还没发过 W:CFG)") end
        local one = trc_line(TR_LAST, "#1")
        if one then M.reply("RET:CTRACE=" .. one) end
        M.reply("RET:CTRACE=" .. trc_line(TR, "#2"))
    end)

    M.reg("W:RAWTEST", function(arg)
        if blocked_while_detecting("RAWTEST") then return end
        local poll = pollmod(true)
        if not poll then return M.reply("RET:FAIL:RAWTEST:bus/poll 不可用") end
        local a, b, c = arg:match("^%s*(%d*)%s*,?%s*(%d*)%s*,?%s*(%d*)%s*$")
        local r, err = poll.probe_raw(
            a ~= "" and tonumber(a) or nil,
            b ~= "" and tonumber(b) or nil,
            c ~= "" and tonumber(c) or nil)
        if not r then return M.reply("RET:FAIL:RAWTEST:" .. tostring(err)) end
        M.reply(string.format("RET:RAWTEST tx_ok=%s tx=%s rx_len=%d parsed=%s rx=%s",
            tostring(r.tx_ok), r.tx_hex, r.rx_len, tostring(r.parsed),
            r.rx_hex == "" and "(空)" or r.rx_hex))
        if not r.tx_ok then
            log.warn("cmd", "RAWTEST uart.write 失败:", r.tx_err)
        elseif r.rx_len == 0 then
            log.warn("cmd", "RAWTEST 无任何回字节: 查 AB线/从机地址/波特率/DE极性/从机是否上电")
        elseif not r.parsed then
            log.warn("cmd", "RAWTEST 有字节但 CRC 不过: 查 波特率/校验位/停止位/AB线序")
        end
    end)

    M.reg("W:RING", function(arg)
        -- 环形调试缓冲开关(12-fix-5): 默认全关, 因为写进去的东西没人读,
        -- 而每帧一次的 string.format 是热路径上实打实的垃圾(见 collector.lua)
        local on = (arg == "1" or arg == "on" or arg == "true")
        collector.ring_enable(on)
        M.reply("RET:RING=" .. tostring(on))
    end)

    M.reg("R:RING", function()
        local out = collector.get_ring()
        reply_json("RET:RING=", jencode(out))
    end)

end -- R:FRAMES/R:INFER/R:AUTODETECT 已转正到 reg_cmds (2026-10, 见上面说明)

function M.handle(line)
    if type(line) ~= "string" then return false end
    -- ⚠️ 这里不能再 gsub 去 \r\n: prov 已按换行切好行并跳掉了 \r。
    --   老代码 `line:gsub("[\r\n]","")` 有两个毛病: ① 对一条 12.7KB 的
    --   128 点 W:CFG 白抄一份同大小的垃圾; ② 它在下面 pcall(fn) 【之外】,
    --   抄不动就整个函数抛错、被 prov 的 pcall 吞掉 —— 前端只看到设备
    --   收了命令却不应答(2026-11-10 情况1)。改成 find/sub: 只切一个小命令名,
    --   参数那份拷贝是 jdecode 必需的, 省不掉。
    local eq = line:find("=", 1, true)
    local fn, arg
    if eq then
        fn = g_cmds[line:sub(1, eq - 1)]
        if fn then arg = line:sub(eq + 1) end
    else
        fn = g_cmds[line]
        arg = line
    end
    if not fn then return false end
    local ok, err = pcall(fn, arg)
    if not ok then
        M.reply("RET:FAIL:handler error:" .. tostring(err))
    end
    return true
end

function M.init()
    reg_cmds()
    -- 12-fix-6: iot 的巡检任务通过这个全局钩子触发推断表推送。
    --   为什么用全局而不是 require: cmd 依赖 iot(iot.status 等), iot 再
    --   require cmd 就是循环依赖(命令模块会拿到半初始化的 iot 表)。
    --   项目里已有同类全局钩子(_G.vcom_handle / _G.mon_detect_result)。
    _G.cmd_push_infer = M.push_infer
    -- 发布版: 调试组 5 条 (W:GC/W:RAWTEST/R:MEM/W:FS/R:CTRACE) 整组不注册;
    -- R:FRAMES/R:INFER/R:AUTODETECT 已转正在 reg_cmds, 发布版仍可用
    if _G.DEBUG then reg_debug_cmds() end
    local names = {}
    for k in pairs(g_cmds) do names[#names + 1] = k end
    table.sort(names)
    log.info("cmd", "ready on VUART via prov hook, cmds:", table.concat(names, " "))
    return true
end

_G.vcom_handle = function(line) return M.handle(line) end

return M
