-- test_cmd_cshard.lua —— 分片上传 W:CSHARD / W:CFINISH / W:CSABORT (2026-11-13, 甲)
--
-- 起因是 11-13 现场那三行(60 行表, 轮询正在跑):
--   RET:MEM=mode:manual lua:226K lua:287384/307192 sys:76/198K max:3072 fail:4096
--   E/mem  used 293544, alloc 4089
--   E/user.prov rx lost: concat fail, drop 4072B
-- 一整行 4072B 的 W:CFG 在【还没解析之前】就被丢掉了, 因为并分片要的是
-- 那么大的连续块, 而池子只给得出 3072。同一个开机里 max 塌了不再回来
-- (清配置 + W:GC 两轮仍是 3072) —— "第一次保存能成、之后怎么存都失败"是
-- 结构性的。唯一出路是让单行本身变小。
--
-- 这个文件钉的是设备侧那三条:
--   1) 片按序攒成一张完整行表, 收尾时和【除 regs 外的字段】合成一份配置,
--      交给和 W:CFG 同一条提交路径(校验/落盘/起轮询一模一样)
--   2) 任何一种"没攒齐 / 攒错了"(顺序断、片数变、只收一半、途中切档、
--      片太大、解码失败)都必须【当场说出来】并且一个字都不落盘 ——
--      老配置原样留着是这条路的立身之本
--   3) 会话是被谁清掉的: 中途插进来的 W:CFG / W:MODE / W:CLRPOLL 都要作废
--      暂存, 否则下一次收尾拿到的是一份拼错槽的表
--
-- 跑法: tools\run_lua_tests.bat test_cmd_cshard.lua   (必须 Lua 5.3+, 见 run_lua_tests.bat)

package.path = 'firmware/?.lua;firmware/?/init.lua;tests/lua/?.lua;' .. package.path

local mock = require "mock_json"

local writes = {}          -- 串口上真正发出去的字节(一条 ask 一批)
local MODE = 'manual'
local SAVED = {}           -- 每次落盘记录: { slot, rows, fields, mode }
local NORM_FAIL = nil      -- 非 nil = normalize_poll 拒了, 值是原因
local POLLL = {}           -- poll 替身的行为记录
local RUN = false          -- poll.is_running()
local CLEAR = 0            -- collector.clear_all 被叫了几次 (W:CBEGIN 腾水)
local DROPC = 0            -- cfg.drop_cache 被叫了几次 (同上)
local ALIAS = 0            -- iot.drop_alias_cache 被叫了几次 (同上)

local function fresh()
  writes, SAVED, NORM_FAIL, POLLL = {}, {}, nil, {}
  CLEAR, DROPC, ALIAS, RUN = 0, 0, 0, false
  MODE = 'manual'
end

package.preload["util"] = function()
  local L = {}
  for _, lv in ipairs({ "debug", "info", "warn", "error" }) do L[lv] = function() end end
  local libs = {
    uart = { VUART_0 = 4,
             write = function(_, s) writes[#writes + 1] = s return #s end,
             read = function() return "" end, on = function() end },
    json = { encode = mock.encode, decode = mock.decode },
    rtos = { meminfo = function(k)
      if k == "lua" then return 307192, 287384, 307192 end
      return 198000, 76000, 90000
    end },
    -- ⚠️ iot 走的是 util.try, 不是 require —— 挂到 package.preload 上永远不
    --   会被读到(cmd.lua 拿到的还是 nil)。原来 iot 是 nil 的时候, "开场到底
    --   有没有叫 drop_alias_cache" 只存在于注释里(名字打错了也是静默不叫),
    --   所以这里补一张替身表。装本文件会走到的那几位就够: cmd.lua 对 iot 的
    --   调用全是 if iot and iot.x 的守卫式, 缺的字段就是不走。
    ["iot/iot"] = {
      drop_alias_cache = function() ALIAS = ALIAS + 1 end,
      reply_config = function() return true end,
      attach_names = function(x) return x end,
      status = function() return {} end,
    },
  }
  return { log = function() return L end,
           get = function(n) return libs[n] end,
           try = function(n) return libs[n] end }
end
package.preload["core/config"] = function() return { BAUD = 9600, SLAVE_ADDR = 1 } end
package.preload["sn/sn"] = function()
  return { state = function() return "empty" end, imei = function() return "" end,
           uid = function() return "" end, locked = function() return false end }
end
package.preload["bus/ctrl"] = function()
  return {
    get_mode = function() return MODE end,
    status = function() return { mode = MODE } end,
    -- W:MODE 的替身: 只记模式, cleared/notcleared 给空表(cmd 侧那段拼应答已有
    --   别的用例覆盖, 这里要的是"切档成功之后暂存还在不在")
    switch_mode = function(m) MODE = m return true, "OK" end,
  }
end
package.preload["bus/mon"] = function() return { is_detecting = function() return false end } end
package.preload["data/collector"] = function()
  return { stats = function() return {} end, snapshot = function() return {} end,
           trim_cache = function() return 0 end,
           -- W:CBEGIN 腾水的四刀之一。替身按真函数的口径回"放掉了几条"
           clear_all = function() CLEAR = CLEAR + 1 return 7 end }
end
package.preload["iot/mqttcfg"] = function() return { load = function() return {} end } end
package.preload["bus/poll"] = function()
  return {
    needs_restart = function(n) return true end,
    is_running = function() return RUN end,
    stop = function() POLLL[#POLLL + 1] = "stop" RUN = false end,
    apply_cfg = function(n) POLLL[#POLLL + 1] = "apply:" .. #(n.regs or {}) end,
    -- ⚠️ 第二个参数可以没有, 而且【两种意思不一样】: 传表 = 用这张表起,
    --   不传 = 自己去 fskv 重读(reload_cfg)。W:CBEGIN 交还轮询走的是后者,
    --   替身原来写死 #(n.regs) 会把这条路直接崩掉 —— 那种崩法在测试里长得
    --   像"代码写错了", 其实是替身不像。
    start = function(slot, n)
      POLLL[#POLLL + 1] = "start:" .. tostring(slot) .. ":"
          .. (n and tostring(#(n.regs or {})) or "fskv")
      RUN = true
    end,
  }
end
package.preload["cfg"] = function()
  local function save(which)
    return function(t)
      if NORM_FAIL then return false, NORM_FAIL end
      SAVED[#SAVED + 1] = { slot = which, rows = #(t.regs or {}), mode = MODE,
                            baud = t.baud, interval = t.interval }
      return true
    end
  end
  return {
    -- 和真 normalize_poll 一样: inplace=true 时返回的就是传进来的那张表
    normalize_poll = function(t) if NORM_FAIL then return nil, NORM_FAIL end return t end,
    -- W:CBEGIN 腾水的一刀。真函数返回放掉的项数, 替身给个固定数就够(只看叫没叫)
    drop_cache = function() DROPC = DROPC + 1 return 3 end,
    save_poll_norm = save("poll"),
    save_pull_norm = save("pull"),
    load_poll = function() return { regs = {} }, nil end,
    load_pull = function() return { regs = {} }, nil end,
    poll_src = function() return "fskv" end,
    pull_src = function() return "fskv" end,
    load_sys = function() return { boot_mode = "idle" } end,
    load_infer = function() return { regs = {} } end,
    load_alias = function() return {} end,
    clear_poll = function() return true, nil, true end,
    clear_pull = function() return true, nil, true end,
    clear_infer = function() return true, nil, true end,
    reset_user = function() return {}, {} end,
  }
end

_G.DEBUG = true
local cmd = require "svc/cmd"
cmd.init()

local failed, checked = 0, 0
local function check(name, ok, detail)
  checked = checked + 1
  if ok then
    print(string.format("ok   %s", name))
  else
    failed = failed + 1
    print(string.format("FAIL %s: %s", name, tostring(detail or "")))
  end
end

local function ask(line)
  writes = {}
  local matched = cmd.handle(line)
  return matched, table.concat(writes, "")
end

-- 只要应答串。⚠️ 别写成 (ask(x)):find(...) —— 括号截的是【第一个】返回值,
--   那是"这条指令有没有匹配上注册表"的布尔值, 于是测出来一个 "attempt to
--   index a boolean" 而真正该看的应答字符串根本没进断言。
local function ask1(line)
  local _, a = ask(line)
  return a
end

local function row(i)
  return { id = "r" .. i, name = "行" .. i, addr = 100 + i, qty = 2,
           type = "uint16", fc = 3 }
end
local function fields()
  return { baud = 9600, slave = 1, interval = 1000 }
end

-- 前端该发的那几片。60 行是现场那份表的行数, 每片 20 行 = 现场单行尺寸的
--   1/3 左右 —— 用例 12 直接拿这组数据量"单行到底变小没有"
local ROWS_N, PER = 60, 20
local function upload(rows, per)
  local n = math.ceil(#rows / per)
  local lines = {}
  for i = 1, n do
    local piece = {}
    for k = (i - 1) * per + 1, math.min(i * per, #rows) do piece[#piece + 1] = rows[k] end
    lines[#lines + 1] = mock.line("W:CSHARD", i .. "/" .. n, piece)
  end
  lines[#lines + 1] = mock.line("W:CFINISH", tostring(n), fields())
  return lines, n
end

local function send_pieces(lns)
  for i = 1, #lns - 1 do ask(lns[i]) end
end

-- ===== 1) 正常路: 3 片 60 行, 顺序到齐, 收尾提交 =====
fresh()
local rows = {}
for i = 1, ROWS_N do rows[i] = row(i) end
local lines, npieces = upload(rows, PER)
check("① 60 行切成 3 片", npieces == 3, npieces)
local _, a1 = ask(lines[1])
check("① 第 1 片回 RET:CSHARD=1=OK", a1 == "RET:CSHARD=1=OK\r\n", string.format("%q", a1))
local _, a2 = ask(lines[2])
check("① 第 2 片回 OK", a2 == "RET:CSHARD=2=OK\r\n", string.format("%q", a2))
local _, a3 = ask(lines[3])
check("① 第 3 片回 OK", a3 == "RET:CSHARD=3=OK\r\n", string.format("%q", a3))
local _, fin = ask(lines[4])
check("① 收尾成功回自己的键 RET:CFINISH=OK", fin == "RET:CFINISH=OK\r\n", string.format("%q", fin))
-- ⚠️ 这一条是 11-13 现场那一坑的护栏。上一版这里回的是 RET:CFG=OK("和 W:CFG 同一个应答"
--   看着更整齐), 而前端 sendCmd(line,'CFINISH') 的匹配条件是 resp.cmd == 在途指令的键 ——
--   应答没人认领, 5s 超时 → 重发 → 会话已清 → 判失败 → 弹"收尾失败"。
--   设备那头 rows=60 早就落盘了。键名不匹配这类 bug 单看设备日志是"全对",
--   只有对着【调用方的匹配规则】才看得见, 所以断言写的是应答串而不是"提交成功了"。
check("① 不许同时回 RET:CFG=(前端会当成另一条指令的应答)",
    not fin:find("RET:CFG=", 1, true), string.format("%q", fin))
check("① 只落一次盘", #SAVED == 1, #SAVED)
check("① 落的是 manual 槽 = ds_poll", SAVED[1] and SAVED[1].slot == "poll", SAVED[1] and SAVED[1].slot)
check("① 攒齐了 60 行", SAVED[1] and SAVED[1].rows == ROWS_N, SAVED[1] and SAVED[1].rows)
check("① 收尾带的字段进了表", SAVED[1] and SAVED[1].baud == 9600
    and SAVED[1].interval == 1000, "见 stub")
check("① 起了轮询, 带的就是这 60 行",
    table.concat(POLLL, " ") == "apply:60 start:poll:60", table.concat(POLLL, " "))

-- ===== 2) 顺序断了: 第 3 片抢在第 2 片前面 =====
fresh()
ask(lines[1])
local _, bad = ask(lines[3])
check("② 乱序当场拒绝", bad:find("RET:FAIL:CSHARD:顺序不对", 1, true) ~= nil, string.format("%q", bad))
check("② 说清楚该发第几片", bad:find("下一片应该是 2", 1, true) ~= nil, string.format("%q", bad))
local _, fin2 = ask(lines[4])
check("② 会话已作废, 收尾不能提交", fin2:find("没有上传会话", 1, true) ~= nil, string.format("%q", fin2))
check("② 一个字都没落盘", #SAVED == 0, #SAVED)

-- ===== 3) 同一片重发(应答在路上丢了): 补 ACK, 但绝不追加两遍 =====
fresh()
ask(lines[1])
ask(lines[2])
local _, dup = ask(lines[2])
check("③ 重复的第 2 片回 OK(让前端接着往下发)", dup == "RET:CSHARD=2=OK\r\n", string.format("%q", dup))
ask(lines[3])
ask(lines[4])
check("③ 行数没有变成 80", #SAVED == 1 and SAVED[1].rows == ROWS_N, SAVED[1] and SAVED[1].rows)

-- ===== 4) 只收一半就收尾: 不提交, 但会话留着, 补发能接上 =====
fresh()
ask(lines[1])
ask(lines[2])
local _, half = ask(lines[4])
check("④ 报的是【只收到几片】", half:find("只收到 2/3", 1, true) ~= nil, string.format("%q", half))
check("④ 没落盘", #SAVED == 0, #SAVED)
local _, go3 = ask(lines[3])
check("④ 会话还在: 补发第 3 片照收", go3 == "RET:CSHARD=3=OK\r\n", string.format("%q", go3))
local _, fin4 = ask(lines[4])
check("④ 补完就能提交", fin4 == "RET:CFINISH=OK\r\n", string.format("%q", fin4))
check("④ 落盘一次 60 行", #SAVED == 1 and SAVED[1].rows == ROWS_N, #SAVED)

-- ===== 5) 上传途中切档: 拒绝, 并且不能落进切过去的那个槽 =====
fresh()
ask(lines[1])
ask(lines[2])
ask("W:MODE=platform")          -- cmd.lua 的 W:MODE 里挂了 up_reset
local _, fin5 = ask(lines[4])
check("⑤ 切档把暂存作废了", fin5:find("没有上传会话", 1, true) ~= nil, string.format("%q", fin5))
check("⑤ 没落盘", #SAVED == 0, #SAVED)

-- ===== 5b) 模式没经过 W:MODE 就变了(平台下发把档切了): 收尾仍要拦住 =====
fresh()
send_pieces(lines)
MODE = 'platform'               -- 不经命令, 直接改档 = 模拟设备自己变了模式
local _, fin5b = ask(lines[4])
check("⑤b 收尾当场比对模式, 拦下来",
    fin5b:find("上传途中模式从 manual 变成了 platform", 1, true) ~= nil, string.format("%q", fin5b))
check("⑤b 没落盘", #SAVED == 0, #SAVED)

-- ===== 6) 平台档整份上传: 落的是 ds_pull =====
fresh()
MODE = 'platform'
send_pieces(lines)
local _, fin6 = ask(lines[4])
check("⑥ platform 档收尾成功", fin6 == "RET:CFINISH=OK\r\n", string.format("%q", fin6))
check("⑥ 落的是 pull 槽", #SAVED == 1 and SAVED[1].slot == "pull", SAVED[1] and SAVED[1].slot)

-- ===== 7) 片太大 / 片数超上限: 明说, 不猜 =====
fresh()
local fat = {}
for i = 1, 40 do fat[i] = { id = "x", name = string.rep("名", 200), addr = i } end
local _, toobig = ask(mock.line("W:CSHARD", "1/2", fat))
check("⑦ 单片超上限当场拒绝", toobig:find("单片太大", 1, true) ~= nil, string.format("%q", toobig))
local _, toomany = ask("W:CSHARD=1/99," .. mock.encode({ row(1) }))
check("⑦ 片数超上限当场拒绝", toomany:find("片数超上限", 1, true) ~= nil, string.format("%q", toomany))
local _, nopath = ask("W:CSHARD=x/y," .. mock.encode({ row(1) }))
check("⑦ 片号不是数字也明说", nopath:find("片号不是 i/n", 1, true) ~= nil, string.format("%q", nopath))
-- 整行没有逗号 = 收尾字段那片的位置都找不到。注意不能拿"带 JSON 数组的畸形
--   行"当例子: 数组里本来就有逗号, 那条会被切成 i/n 检查(上面 x/y 就是它)
local _, nohead = ask("W:CSHARD=1")
check("⑦ 缺逗号也明说", nohead:find("缺 , 分隔", 1, true) ~= nil, string.format("%q", nohead))
check("⑦ 四条都没落盘", #SAVED == 0, #SAVED)

-- ===== 8) 收尾字段坏了: 报原因, 不落盘 =====
fresh()
send_pieces(lines)
local _, jbad = ask("W:CFINISH=3,{")
check("⑧ 解码不出来要带原因(不能只说 bad json)",
    jbad:find("RET:FAIL:CFINISH:", 1, true) ~= nil and #jbad > #"RET:FAIL:CFINISH:\r\n",
    string.format("%q", jbad))
check("⑧ 没落盘", #SAVED == 0, #SAVED)

-- ===== 9) 校验失败走的是同一条 FAIL 应答 =====
fresh()
NORM_FAIL = "bad slave"
send_pieces(lines)
local _, nbad = ask(lines[4])
check("⑨ 归一化失败回 RET:FAIL:CFG:bad slave",
    nbad == "RET:FAIL:CFG:bad slave\r\n", string.format("%q", nbad))
check("⑨ 失败不写盘", #SAVED == 0, #SAVED)
-- 同一条路径的对照: W:CFG 整行一次到, 原因一字一样
fresh()
NORM_FAIL = "bad slave"
local _, wbad = ask("W:CFG=" .. mock.encode({ baud = 9600, slave = 1, regs = { row(1) } }))
check("⑨ W:CFG 的失败应答和分片收尾一字一样", wbad == nbad, string.format("%q", wbad))
check("⑨ W:CFG 也没写盘", #SAVED == 0, #SAVED)

-- ===== 10) 中途插进来的写配置命令, 一律作废暂存 =====
for _, intr in ipairs({ "W:CLRPOLL", "W:CFG=" .. mock.encode({ baud = 9600, regs = {} }) }) do
  fresh()
  ask(lines[1])
  ask(intr)
  local saved_by_intr = #SAVED   -- W:CFG 那一条本来就该落一次盘, 只不许【再】落
  local _, after = ask(lines[4])
  check("⑩ " .. intr:sub(1, 12) .. " 之后收尾没有会话可用",
      after:find("没有上传会话", 1, true) ~= nil, string.format("%q", after))
  check("⑩ 收尾没有偷偷落盘", #SAVED == saved_by_intr, #SAVED)
end

-- ===== 11) W:CSABORT 显式放弃 =====
fresh()
ask(lines[1])
ask(lines[2])
local _, ab = ask("W:CSABORT")
check("⑪ 放弃回 RET:CSABORT=OK", ab == "RET:CSABORT=OK\r\n", string.format("%q", ab))
local _, after11 = ask(lines[4])
check("⑪ 放弃后收尾被拒", after11:find("没有上传会话", 1, true) ~= nil, string.format("%q", after11))
check("⑪ 没落盘", #SAVED == 0, #SAVED)
-- 再放弃一次: 没会话也不是错(前端取消时不用先问状态)
local _, ab2 = ask("W:CSABORT")
check("⑪ 没会话时放弃仍回 OK", ab2 == "RET:CSABORT=OK\r\n", string.format("%q", ab2))

-- ===== 12) 立身之本: 分片之后【单行】比原来那条小得多 =====
fresh()
local peak = 0
for _, l in ipairs(lines) do if #l > peak then peak = #l end end
local whole = "W:CFG=" .. mock.encode({ baud = 9600, slave = 1, interval = 1000, regs = rows })
check("⑫ 整行一次到的尺寸就是现场接不进来的那种(>4KB 那堵墙)",
    #whole > 4096, #whole)
check("⑫ 分片后最大单行落在设备给得出的连续块以内", peak <= 2048, peak)
check("⑫ 小了不止一半", peak * 2 < #whole, peak .. " vs " .. #whole)

-- ===== 13) W:CBEGIN 正常开场: 把轮询停下、把配置那堆表放掉, 再报水位 =====
--   这一组是 11-13 下午那轮现场补出来的: 片切到 1200B 之后第二次保存【还是】
--   进不来(轮询中 max:1024, 一片 1177B 在拼行之前就被丢掉), 而 W:GC 前后 max
--   一点没抬 —— 水不在可回收的对象里, 在轮询自己在用的表里。所以开场命令的
--   职责就是"把轮询停下来腾地方", 并且把腾完的水位如实报给前端。
fresh()
RUN = true
local _, cb = ask("W:CBEGIN=3,1200")
check("⑬ 开场回自己的键, 带着实测到的最大连续块",
    cb:find("RET:CBEGIN=OK max:", 1, true) ~= nil, string.format("%q", cb))
check("⑬ 水位一起报了(现场不用再单独跑一轮 R:MEM)",
    cb:find(" used:", 1, true) ~= nil, string.format("%q", cb))
check("⑬ 停的是【正在跑的】轮询", table.concat(POLLL, " ") == "stop", table.concat(POLLL, " "))
check("⑬ 清了采集缓存(含 ring)", CLEAR == 1, CLEAR)
check("⑬ 放了配置解码缓存", DROPC == 1, DROPC)
check("⑬ 放了 iot 那张别名映射", ALIAS == 1, ALIAS)
check("⑬ 轮询真的停了", RUN == false, RUN)

-- ===== 14) 第 1 片接到 CBEGIN 开的会话上, 而不是重开一次 =====
local _, p2first = ask(lines[2])
check("⑭ 会话是开场就开好的: 抢发第 2 片被按顺序拦下",
    p2first:find("顺序不对, 下一片应该是 1", 1, true) ~= nil, string.format("%q", p2first))
-- 上一条把会话作废了(顺序断 = 作废), 重新开场再走一遍正路
fresh()
RUN = true
ask("W:CBEGIN=3")     -- 预算不带: 按设备自己的单片上限探, 老前端也走得通
local _, q1 = ask(lines[1])
check("⑭ 第 1 片接得上(回自己的片号 OK)", q1 == "RET:CSHARD=1=OK\r\n", string.format("%q", q1))
check("⑭ 第 1 片没有把轮询再停一次", POLLL[2] == nil, table.concat(POLLL, " "))
local _, q2 = ask(lines[2])
check("⑭ 第 2 片照常收下", q2 == "RET:CSHARD=2=OK\r\n", string.format("%q", q2))
-- CBEGIN 说了 3 片, 片里却说 4: 拒收(n 是两端的合同, 不能各说各的)。
--   ⚠️ 要在【会话还活着】的时候测: 抢发第 2 片那次已经把会话作废了(顺序断=作废),
--   而作废之后再发第 1 片走的是"没开场就自己开一次"的兼容路 —— 它按片里的 n
--   重开, 不会报不一致。测错状态就等于什么都没测出来。
fresh()
RUN = true
ask("W:CBEGIN=3,1200")
ask(lines[1])
local _, mism = ask(mock.line("W:CSHARD", "2/4", { row(1) }))
check("⑭ 开场说的片数和片里说的不一致 → 当场拒", mism:find("片数", 1, true) ~= nil,
    string.format("%q", mism))

-- ===== 15) 腾完水还是接不住: 当场说清, 一片都不用发, 轮询立刻还回来 =====
--   模拟"最大连续块 = 0": 把试分配用的 string.rep 换成一叫就 raise。
--   ⚠️ 必须换完立刻换回来 —— 这文件后面每一条都要靠真 string.rep 之外的
--   路径, 但把全局函数留在坏状态里, 下一个失败就查不动了。
fresh()
RUN = true
local realrep = string.rep
string.rep = function() error("not enough memory") end
local _, cbad = ask("W:CBEGIN=3,1200")
string.rep = realrep
check("⑮ 水位不够回 FAIL 且挂在自己的键上",
    cbad:find("RET:FAIL:CBEGIN:腾完水仍接不住 1200B", 1, true) ~= nil, string.format("%q", cbad))
check("⑮ 说清实际只腾出多大一块", cbad:find("最大连续块只有 0B", 1, true) ~= nil,
    string.format("%q", cbad))
check("⑮ 下一句告诉用户该干什么", cbad:find("重启设备", 1, true) ~= nil, string.format("%q", cbad))
check("⑮ 会话没留下(再发片就是【没有会话】而不是【顺序不对】)",
    ask1(lines[2]):find("没有上传会话", 1, true) ~= nil, "见上一条")
check("⑮ 轮询当场还回去了, 不让人干等 60 秒兜底",
    table.concat(POLLL, " ") == "stop start:poll:fskv", table.concat(POLLL, " "))
check("⑮ 还回去是从 fskv 重读(不拿任何手上的表)", RUN == true, RUN)

-- ===== 16) 静默兜底: 前端一去不回, 设备自己把轮询捡起来 =====
fresh()
RUN = true
ask("W:CBEGIN=3,1200")
ask(lines[1])
cmd._cshold_fire()      -- 测试环境没有 sys 协程, 直接触发那一条兜底
check("⑯ 兜底把轮询按旧配置起回来了",
    table.concat(POLLL, " ") == "stop start:poll:fskv", table.concat(POLLL, " "))
check("⑯ 兜底同时作废了会话", ask1(lines[2]):find("没有上传会话", 1, true) ~= nil, "见上一条")
check("⑯ 一个字都没落盘", #SAVED == 0, #SAVED)
-- 兜底再来一次也不该起第二个轮询(is_running 那层守卫)
local before16 = #POLLL
cmd._cshold_fire()
check("⑯ 重复触发是空操作", #POLLL == before16, table.concat(POLLL, " "))

-- ===== 17) CSABORT 也会还轮询, 而且【没有会话】时照样还 =====
fresh()
RUN = true
ask("W:CBEGIN=3,1200")
ask(lines[1])
local _, ab17 = ask("W:CSABORT")
check("⑰ 放弃回 OK", ab17 == "RET:CSABORT=OK\r\n", string.format("%q", ab17))
check("⑰ 放弃把轮询还回来",
    table.concat(POLLL, " ") == "stop start:poll:fskv", table.concat(POLLL, " "))
-- 会话被中途的 W:MODE 清掉了, 但轮询还停着: CSABORT 不能因为"没会话"就跳过归还
fresh()
RUN = true
ask("W:CBEGIN=3,1200")
ask(lines[1])
ask("W:MODE=platform")          -- 这条会 up_reset, 但不会替我们把轮询起回来
local _, ab17b = ask("W:CSABORT")
check("⑰ 没会话时放弃仍回 OK", ab17b == "RET:CSABORT=OK\r\n", string.format("%q", ab17b))
check("⑰ 归还不能被【没有会话】那句跳过", RUN == true,
    POLLL and table.concat(POLLL, " ") or "-")

-- ===== 18) 提交成功: 起轮询的是 commit_config, 兜底只负责取消 =====
fresh()
RUN = true
ask("W:CBEGIN=3,1200")
send_pieces(lines)
local _, fin18 = ask(lines[4])
check("⑱ 收尾成功", fin18 == "RET:CFINISH=OK\r\n", string.format("%q", fin18))
local starts = 0
for _, v in ipairs(POLLL) do if v:find("^start") then starts = starts + 1 end end
check("⑱ 只起了一次轮询(第二次是白解一遍旧配置, 池子最紧的时候干这个)",
    starts == 1, table.concat(POLLL, " "))
check("⑱ 起的是【新】那 60 行, 不是从 fskv 重读",
    POLLL[#POLLL] == "start:poll:60", POLLL[#POLLL])
check("⑱ 落盘一次 60 行", #SAVED == 1 and SAVED[1].rows == ROWS_N, #SAVED)

-- ===== 19) 参数闸门 与 sniff 档不越界 =====
fresh()
check("⑲ n 超上限被拒", ask1("W:CBEGIN=99,1200"):find("片数非法", 1, true) ~= nil, "见上一条")
check("⑲ n=0 被拒", ask1("W:CBEGIN=0,1200"):find("片数非法", 1, true) ~= nil, "见上一条")
check("⑲ 预算大得离谱被拒", ask1("W:CBEGIN=3,9000"):find("单行预算 9000B", 1, true) ~= nil,
    "见上一条")
check("⑲ 预算小得不像话也被拒(等于没探)", ask1("W:CBEGIN=3,8"):find("单行预算 8B", 1, true) ~= nil,
    "见上一条")
check("⑲ 这四次一条都没停轮询", #POLLL == 0, table.concat(POLLL, " "))
fresh()
MODE = "sniff"
RUN = true
local _, cbs = ask("W:CBEGIN=3,1200")
check("⑲ sniff 档拒绝开场(那边的推断正靠 poll+collector 跑)",
    cbs:find("RET:FAIL:CBEGIN:sniff 档", 1, true) ~= nil, string.format("%q", cbs))
check("⑲ 拒绝的时候什么都没动", #POLLL == 0 and CLEAR == 0 and DROPC == 0 and RUN == true,
    table.concat(POLLL, " ") .. " clear=" .. CLEAR)

if failed > 0 then
  print(string.format("FAIL: %d 条不过 (%d 条)", failed, checked))
  os.exit(1)
end
print("PASS: 分片上传 —— 按序攒齐才提交, 攒不齐一个字不落盘")
