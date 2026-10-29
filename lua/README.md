# VKBox Lite 485 采集框架 v2

基于合宙 Air780EP（LuatOS）的 485 串口采集设备框架。对照官方 API 文档重构，代码精简、结构清晰。

## ⚠️ 烧录前必看：脚本区只有 256KB

固件的**脚本区上限 256KB**，而 `lua/` 源码带大量中文注释(实测 270KB)，**直接烧 `lua/` 会报**
「文件总数据量(257kb)超过了固件脚本区空间(256kb)」。

**正确烧法**：

```
1) 双击 tools\prep_burn.bat   (或 powershell -ExecutionPolicy Bypass -File tools\prep_burn.ps1)
   → 生成 build\lua_burn\ : 源码的"去注释版", 行号完全不变, 代码逐行一致
   → 脚本会打印体积与余量 (当前 161KB, 余量 94KB)
2) LuaTools 烧录时, 脚本目录选 build\lua_burn\   ← 不是 lua\
```

仓库里的 `lua/` **一个字都不改**，注释全留着（设备的 log 行号仍与源码对得上）。
去注释版只在烧录时临时生成到 `build/`（已 gitignore）。

> 为什么不在源码里删注释：那些注释是这套框架的"为什么"（每个坑的来龙去脉都在里面），
> 删了等于把知识扔掉；烧进设备的脚本又不需要它们。瘦身发生在**烧录这一步**，
> 源码保持完整。

## 开发版 vs 发布版（`_build_flag.lua`）

固件分两版，靠 `lua/_build_flag.lua` 一行开关切：

```lua
-- 发布版开关。true=发布, false=开发。改这一行就切版本
return false        -- false=开发版 / true=发布版
```

`main.lua` 启动时读它：`_G.BUILD_RELEASE = require "_build_flag"`、`_G.DEBUG = not _G.BUILD_RELEASE`。

**两版的差别只有两处**：

| 差别 | 开发版 | 发布版 |
|---|---|---|
| 调试指令注册 | `W:GC`（强制 GC+踢连接）、`W:RAWTEST`（485 裸探针）**都注册** | **都不注册** |
| 原始 hex 收进 ring | 收（`collector.push_raw_rx`） | 不收（省内存，也不留总线原始报文） |

其余全部指令（含 sniff 三件套 `R:FRAMES`/`R:INFER`/`R:AUTODETECT`）**两版都有**。

### 为什么要拆

1. **暴露面**：设备挂在客户产线上是公开串口，谁都能连。`W:RAWTEST` 能**直接往客户 485 总线发原始帧**（干扰客户设备），`W:GC` 能强制断 MQTT —— 交付版不该开这些口子。
2. **体积**：Lua 堆只有 203K，脚本区只有 256KB，能省一点是一点（调试组那几条的闭包 + upvalue 都不进注册表）。
3. **排障需要**：现场出问题时，排障机上要有裸探针。

### 该用哪个

| 场景 | 用哪版 |
|---|---|
| 开发 / 产线排障 / 现场定位 485 问题 | **开发版**（`return false`），有 `W:RAWTEST` |
| 交付客户 / 挂到客户产线上长期跑 | **发布版**（`return true`），不往外露总线探针 |

> 现场排障的具体做法：把 `_build_flag.lua` 改成 `return false` → `tools\prep_burn.bat` → 烧 `build\lua_burn\` → 排障完改回 `return true` 再烧一次。
>
> `R:NET`/`R:MEM` 已在 2026-10 删除（信息早就并进 `R:STAT` 的 mqtt/guard 段，前端 0 引用，留着只是白占脚本区）。

## 功能

| 功能 | 模块 | 说明 |
|---|---|---|
| Q1 SN 烧录 | `sn/` | 三态状态机 + VL 前缀格式校验 + fskv 持久化 + 产线指令通道 |
| Q2 Modbus 轮询 | `bus/poll.lua` | 主机轮询（fc03）+ 写事务注入（fc06/fc16） |
| Q3 Modbus 旁听 | `bus/mon.lua` | 纯被动监听，CRC 试探切帧，REQ/RSP 配对 |
| Q4 MQTT 上报 | `iot/` | deviceId=SN，值变化驱动上报，下行 REPORT/WRITE |

## 目录结构

```
lua/
├── main.lua            启动编排（6 stage）
├── core/
│   ├── corelib.lua     库安全获取 + log 降级
│   └── config.lua      全部默认参数
├── sn/
│   ├── sn.lua          SN 状态机 + VL 前缀格式校验 + fskv 存储 + 身份
│   └── prov.lua        产线/前端串口指令通道（VUART_0）
├── bus/
│   ├── mbus.lua        Modbus 协议层（CRC/组帧/解析/解码/DE 精算）
│   ├── poll.lua        Q2 轮询
│   ├── mon.lua         Q3 旁听
│   └── ctrl.lua        模式仲裁（poll/sniff/idle 互斥）
├── data/
│   └── collector.lua   数据层（最新值 + 帧缓存 + 回调）
├── cfg.lua             配置中心（poll/sniff/sys 三类，fskv 持久化）
├── iot/
│   ├── mqttcfg.lua     MQTT 配置（{sn}/{id} 占位 + normalize）
│   ├── pullcfg.lua     平台配置下发解析（只提取，无副作用）
│   ├── topo.lua        拓扑(U2)的 JSON 拼装 + 指纹（一次成串）
│   └── iot.lua         连接编排 + 上报 + 下行 + 配置拉取状态机
└── svc/
    ├── guard.lua       看门狗喂狗 + 运行监控
    └── cmd.lua         前端指令层（R:/W: 指令）
```

## 启动时序

| 阶段 | 内容 |
|---|---|
| 1 | `guard.init()` 看门狗 9s 超时 / 3s 喂狗 |
| 2 | `sn.init()` 三态机 + 身份；on_change 烧号成功自动补启 MQTT |
| 3 | collector / cfg |
| 4 | poll / mon / ctrl；GPIO8 预置低电平；boot_mode 决定是否自动起 |
| 5 | iot.init + start（未烧 SN 不建连） |
| 6 | cmd.init（注册指令）+ prov.init（VUART_0 产线通道） |

## 数据流

```
Q2: W:MODE=poll     → ctrl → poll(总线唯一主人, 用 ds_poll 手配) → collector
    W:MODE=pollpull → ctrl → iot.hello 拉配置 → save ds_pull
                                  → poll(用 ds_pull) → collector

Q3: W:MODE=sniff → ctrl → mon(纯 RX) → CRC 试探切帧 → REQ/RSP 配对 → push_frame

下行: 平台 WRITE → recv 挂起 → handle_downlink → resolve_addr → poll.enqueue_write
      （idle 时一次性 worker 排空，sniff 占线则中止）

烧号: W:SN=xxx → prov → sn.write(锁检查/validate/VL前缀+长度) → fskv save + 回读
       → on_change → MQTT 自动启动
```

> ⚠️ **写队列是异步的**：`poll.enqueue_write` 返回 true 只代表"进队了"，不代表"已发到总线"。
> 发送由 `poll_task`（轮询在跑时）或 `worker`（轮询没跑时被拉起）完成，结果看
> `poll.write_status()` 的 `done`/`wfail`（前端经 `ctrl.status().write` 取）。
> 设备日志是 `downlink write: queued=N rejected=M`，**不是 `ok=N`**——后者会让现场
> 以为写成功了，实际可能还压在队列里。
>
> `worker` 这道闸曾长期是错的：它跟着 `poll_task` 一起判 `running`，而 idle 档
> `running` 恒为 false，于是 worker 一启动就 return，写请求静静躺在 `writeQ` 里，
> 直到某次切到 poll 模式才被 `poll_task` 顺带发出去（陈旧指令延后生效，比不生效更危险）。
> 现已改成 worker 用自己的 `gen` 守卫：`running` 只是 `poll_task` 的生命周期标志，
> 管不到 worker。同理 `do_transaction` 在轮询没跑时会先 `ensure_uart()`——那条路上
> `M.start()` 从没跑过，不补 setup 的话 `uart.write` 等于发到空气里。

## 前端指令（VUART_0，115200 8N1，RET: 前缀应答）

| 指令 | 用途 |
|---|---|
| R:INFO | 设备信息（SN/sn_state/lock/IMEI/**UID**/ICCID/CSQ/RSRP/版本/项目/服务器/波特率/从机/寄存器数） |
| R:MODE / W:MODE=idle\|poll\|pollpull\|sniff | 模式查询（返回 `{mode,busy,poll_src,pull_ready,pull,poll,mon,write}`）/ 切换。`pollpull` = 拉取配置档，进模式自动 hello 拉取 |
| R:CFG / W:CFG={json} | 轮询配置读写，读返回 `{cfg, src}`，src=default 表示 fskv 里没写过。`W:CFG` 是**唯一**写寄存器表的入口（regs 并进 cfg 一起发） |
| R:REG | 读寄存器表（= `R:CFG` 的 `cfg.regs`，因前端单独读它才留） |
| R:VAL | 实时值快照 |
| R:STAT | 运行状态汇总（mode/data/guard/mqtt）；`mqtt` 段另带 `push_pending`/`push_n`/`push_seen`/`push_err`（平台主动重推横幅用） |
| W:PULLCFG / R:PULLCFG | 平台配置拉取：W 发起（回 `started`），R 查状态（`{state,msg,poll,skipped,mqtt,msg_id,replied,src,seen,autosaved,autosave_at,autosave_regs,push_n,push_err}`，`mqtt` 段含 `pub`/`sub` 两个拼好的 topic；`autosaved`=解析成功即已落盘生效并自动回执；`msg_id`/`replied` 反映回执；`src`=`pull`/`push`）。平台主动重推的配置也走这个返回（`src=push`）。前提只需配好 MQTT 服务器地址和端口，设备会自己连 |
| W:RAWTEST[=slave,addr,qty] | 485 裸探针：发原始请求并回显所有原始回字节，用于区分“没发出去/从机没回”与“回了但参数不匹配”（**仅开发版注册**，发布版不可用） |
| R:MQTT / W:MQTT={json} | MQTT 配置读写，读返回 `{cfg,auto_pass,manual_on,pub,sub,ready,err,stat}`。`cfg`=手动档表单原值，`auto_pass`=首页凭证密码，`manual_on`=当前档位，`pub`/`sub`=当前档次实际生效的成品 topic |
| W:MQTTRC | 只重连不动配置（等价 `iot.kick()`：销毁 client 后 backoff 归 1 立刻重连） |
| R:REPORT | 立即上报 |
| W:GC | 强制 GC + 重连（**仅开发版注册**） |
| W:RAWTEST[=slave,addr,qty] | 485 裸探针：发原始请求并回显所有原始回字节，用于区分“没发出去/从机没回”与“回了但参数不匹配”（**仅开发版注册**——它能直接往总线上发帧，交付版不能开，见下「开发版 vs 发布版」） |
| R:FRAMES[=n] | 旁听帧（n 取 1~50，默认 20，**正式注册**，sniff 报文卡依赖） |
| R:INFER[=off,n] | 读**常驻推断表**（2026-10-28 起是累加器，不再每次重建）`{regs:[{slave,addr,fc,hits,answered,dtype,conf,value}], slaves, ignored, stat, total, off, n, pages, page}`（**只读参考**，不写任何配置）。**行只增不减**：请求帧里出现过的地址就进表，顺序 = 嗅探到的发现顺序（前端第 1 列"序号"就是这个顺序，前端自己编号，设备不存序号字段）；`hits` = 累计被请求多少次；`answered`=false 表示主站轮询了但没收到应答（这类地址**也进表**）；`value` = 旁听应答最新解析值。**最多累计 128 行**（`MAX_INFER_ROWS`，见「内存缓冲上限」一节）；`ignored` = 表里"没应答"的地址数。⚠️ **2026-10-29 起分页**：`off`=起始行号(0 起)、`n`=本页行数（上限 32）。`regs` 是**本页**的行，`slaves/ignored/stat/total/pages` 是**整张表**的口径。`id`/`name`（U4 上报 payload 的 id/name，别名映射）**不在行上**了，改挂顶层 `names` 表：`{"reg230":{"id":"x","name":"y"}}`，**只有跟默认值 `reg<addr>` 不一样的才登记**，没有的条目前端自己退回 `reg<addr>` |
| W:INFERWATCH=1\|0 | 推断表**主动推送**开关（2026-10-28）。`1` = 设备每发现一个新地址就把**当前页**推过来（`RET:INFER_PUSH={...}`，格式同 `R:INFER`；2026-10-29 起推的是前端最近一次 `R:INFER=off,n` 要的那一页，不是整张表 —— 推整张表在 64 个地址时是 8KB，正是现场崩掉的那个大小）；`0` = 停推。前端只在 sniff 面板打开时开、关面板就关 —— 没人看的时候设备一个字节都不发（串口让给报文/指令）。⚠️ 推送是**设备主动**发的，不受前端"单条未决指令"约束，前端必须先按 `INFER_PUSH` 键名把它跟在途指令分开（`frontend/renderer/app.js` 的 `onSerialLine`） |
| R:AUTODETECT[=restart] | 识别 sniff 通讯参数 `{baud,databits,stopbits,parity}`（**只用于本次会话**，不写 fskv）。**非阻塞**：回 `BUSY` / 参数 / `RET:FAIL:not in sniff mode`，由前端轮询。带 `=restart` = 强制重扫（先清旧帧旧值与旧结果，再从头扫），前端「重新识别通讯参数」按钮用 |
| R:SALIAS / W:SALIAS={key,id,name} | sniff 侧别名表（`ds_alias` 槽）：用户在推断表里给 `reg<addr>` 起的**参数名称**(`name`)与**建议标识符**(`id`)。`W:SALIAS` 单条 upsert，`id`/`name` 都空 = 删掉这条（恢复默认 `reg<addr>`）。生效范围：sniff 档的 **U2 拓扑属性 id/name** 与 **U4 数据项 id/name** —— 平台上显示的就是用户起的名字 |
| W:MODE=poll\|pollpull\|sniff\|idle | 切换 485 运行模式。`sniff` 会**自动起一轮识别**（非阻塞），立即回 OK；`pollpull` 会自动 hello 拉平台配置 |
| W:BOOTMODE=idle\|poll\|pollpull\|sniff | 开机默认模式（大小写不敏感）。`sniff` 同样自动识别，但不堵开机流程 |
| R:SN / R:ID / W:SN=xxx[,FORCE] / C:SN / LOCK:SN / UNLOCK:SN / R:SNEN / W:SNEN=n,0\|1[,P] | SN 产线指令（VUART_0 通道） |

> 指令集与 `frontend/protocol.js` 的 `Enc` 一一对应。`W:RAWTEST`/`W:GC` 是前端不调用的现场诊断入口，且**仅开发版注册**（`_build_flag.lua` = true 的发布固件里没有）。`R:FRAMES`/`R:INFER`/`R:AUTODETECT` 源自调试组，但已是 sniff 面板的正式依赖，2026-10 已**转正注册**（`cmd.lua` 的 `reg_cmds`，发布版可用）。
>
> **`R:MQTT` 的 stat 带 `sub_list`**（2026-10）：设备实际订阅清单（`build_subs()` 的产物，当前 5 条）。前端"其他生效 Topic"里的 **D2n** 那条用它替换模板——常量里是 `.../{sn}-N`（N=从机序号占位符），设备实际订的是 `.../{sn}-1`（多从机展开 `-1..-K`）。显示模板等于骗人：现场照着 `-N` 订阅收不到东西。老固件没有这个字段，前端退回模板。
>
> **`R:SN` 不是死代码**：前端确实不用它，但产线烧写软件（`pc_tool/device.py` 的 `read_sn()`）拿它做 `W:SN` 之后的回读校验，`burner.py` 比对不过就判失败、不上锁。曾按"前端零调用"删过一次，现场表现为「设备无响应（发送了 R:SN）」+ SN 写进去了但锁没上。**删任何指令前，先确认仓库外没有别的调用方。**
>
> **写寄存器的入口**：MQTT 下行 `{"cmd":"WRITE","items":[...]}`（设备自动排进写队列）与前端「写寄存器」。原先的 `W:WRITE`/`W:WRITEJ` 已删除——字段名与 MQTT 下行解析完全一致，属重复实现。写结果看 `R:STAT` 的 `write` 段，**不是 `enqueue_write` 的返回值**（那只代表入队）。
>
> ⚠️ **下行写指令的 `id`→地址解析必须按当前在用的配置槽**。平台是按 `ds_pull` 里的寄存器表下发的（拉取时 `name` 字段就取自平台 id，见 `pullcfg.lua` 的 `props_to_regs`），所以 `downlink_write` 和 `alias_map` 都要走 `active_cfg()` 而不是写死 `load_poll`。曾写死过一次，后果是拉取档下**每一条按名字下发的写指令都静默失败**：`ds_poll` 通常是空的，`resolve_addr` 返回 nil 只打一行 `write item unresolvable`，平台那头完全看不出异常。
>
> 报文形状认这三种（`handle_downlink` 末尾开始分流）：
> ① `[{"id":..,"value":..}]` 数组 → 整包当 items
> ② `{"cmd":"WRITE","items":[...]}`
> ③ 单对象带 `value`/`values`
> `{"cmd":"REPORT"/"READALL"}` 只置脏等下一个上报周期，不回包。
>
> **已删除的前端零调用指令**：`R:SNIFFCFG`/`W:SNIFFCFG`（前端无入口）、`R:IOTSTAT` 与 `R:POLL`（被 `R:STAT` 的 mqtt 段和 data 段覆盖）、`W:RST`（前端各自有「恢复默认」按钮）、`W:REG`（被 `W:CFG` 覆盖：前端「保存配置」把 regs 并进 cfg 一起发，单独写寄存器表的指令从来没被调过）。连带删掉只服务它们的 `cfg.reset()`、`mqttcfg.reset()`、`collector.clear()`。
>
> **删指令前必做的两步**：① 数前端 `Enc.xxx` 调用次数（`protocol.js` 里挂着但 app.js 零调用 = 候选）；② 查仓库外的 `pc_tool` 还在不在用。两步都过才能删。

## 固件适配要点（对照官方文档）

- `uart.setup(id, baud, databits, stopbits, parity)`，校验常量 `uart.NONE/EVEN/ODD`
- `uart.on(id, "receive", cb)`，回调 `cb(id, len)`，len 是字节数需再 `uart.read`
- `sys.wait/waitUntil` 只能在 `sys.taskInit` 协程内；定时器/订阅回调内不可用
- `mqtt.create(nil, host, port, ssl)` → `auth(cid, user, pass, cleanSession)` → `keepalive` → `autoreconn(false)` → `on(cb)` → `connect()`，等 `conack` 事件确认
- `mqttc:publish(topic, data, qos)` 三参数；模块端无重发，失败只能重连
- `fskv.set` 新版自动落盘；旧固件需 `fskv.save`（代码已做存在性判断，两者兼容）
- **Air780EP 无软件看门狗**：`wdt.init/setTimeout/close` 均返回 false，AON WDT 由固件托管（固定 28s），只有 `wdt.feed()` 有效——guard 仅负责 feed
- `rtos.meminfo("sys")` 返回 **3 个 int**（总/已用/历史峰值），不是 table
- `mobile.imei/csq/rsrp/iccid()` 均为无参函数；`mobile.status()` 不能用于判断联网（以连上目标服务器为准）
- `json.decode` 返回 obj/result/err 三个值；`json.encode` 第二参为浮点精度模式，缺省 "7f"
- `rtos.fsinfo` 官方确认不存在；`fs` 库也不存在 → 存储空间功能已整体移除
- 32 位固件：`ts*1000` 回绕、`%.0f` 大数科学计数法 → 数值全部手工拼（int_str/ms_of）
- `tonumber(nil)` 会崩 VM → 所有外部取值先判 nil
- 日志：开机不调 `setLevel`；guard 心跳用 `print` 走 stdout

## fskv 容量约束（Air780EP）

片上 flash 64K 区域（16×4K block），wear-leveling，单 cell 约 10 万次擦写：

- Value ≤255B：最多 **812** 个键值对（本框架全部配置均在此区间，JSON 限 512B 内）
- Value ≥256B：每个占一个 4K block，最多 **14** 个
- 当前键用量 **12 个**，余量充足：
  - 配置 3 个：`ds_poll`（485 手配）/ `ds_pull`（485 平台拉取）/ `mqtt_cfg`
  - 系统 1 个：`ds_sys`（开机模式）
  - SN 4 个：`dev_sn` / `dev_sn_lock` / `dev_sn_burn` / `dev_sn_btime`
  - SN 指令开关 4 个：`sn_en_write` / `sn_en_clear` / `sn_en_lock` / `sn_en_unlock`

## poll / sniff 配置隔离

两套配置**存储层本就分开**，各自的 fskv 键、归一化函数、默认值完全独立：

| 配置 | 键 | 字段 | 谁写它 |
|---|---|---|---|
| `poll` | `ds_poll` | 串口参数 + slave + interval + timeout + **regs 寄存器表** | `W:CFG`（非 `pollpull` 模式下） |
| `pull` | `ds_pull` | 同 `ds_poll`（复用同一份 normalize/default） | `W:CFG`（`pollpull` 模式下）+ 平台配置落地 `iot.auto_apply` |
| `sys` | `ds_sys` | boot_mode | `W:BOOTMODE` |
| `alias` | `ds_alias` | `regs:[{key="reg263", id, name}]` —— sniff 推断出的寄存器被用户起的名字 | `W:SALIAS` |

设计约束（改动前先读这里）：

- **sniff 没有持久槽，这是刻意的**。旁听识别出的串口参数只存本次会话
  （`mon.lua` 的 `bootCfg`），`cfg.lua` 里连可写的 `save_sniff` 都不留 —— 省下来的
  11 行死代码换来的是"误存 sniff 参数"从结构上不可能：没有写入口，改 `mon.lua`
  的人也无法顺手 `save` 一把。原先那个 `ds_sniff` 槽从未被任何代码或外部工具写入，
  `load_sniff()` 恒返回 `{9600,8,1,0}`，删掉后行为逐字节不变。
- **sniff 不持有寄存器表**。旁听是纯被动接收，解出的帧不代表"要采哪些点"。
  给 sniff 加 regs 是错的——那会让"旁听到什么"和"采集什么"耦合，改一侧污染另一侧。
  寄存器表的唯一来源是 `W:CFG` 与平台 `ds_pull`。
- **`ds_alias` 是另一回事，不违反上面那条**（2026-10）。它存的不是"采哪些点"，
  而是**用户给已推断出的点起的名字**（`reg263` → "A相电流"）。名字不参与采集，
  只影响上报时的 id/name，让平台物模型显示人看得懂的字。切 idle 的复位**不清**它
  ——名字是用户在现场攒下的成果，跟手配的寄存器表不是一回事。
- **但新一轮识别会把别名表清空**（A 方案，2026-10 定）。名字是"**这一轮**推断
  结果"的注解：重新识别 / 再进 sniff 档 = 开了新一轮，总线换了或地址变了，
  旧名字留着会张冠李戴（`reg305` 的"A相电流"可能已经是别的东西）。
  清的时机：**退出 sniff 就抹干净**（`ctrl.lua` 的 `stop_sniff()`：停监听 +
  `clear_alias()`），另外两处兜底——点「重新识别」(`cmd.lua`)与**进 sniff 档**
  (`ctrl.lua`)。进 sniff 那次是兜底：设备断电重启后开机直进 sniff 走的是
  `start` 不是 `stop`，上次的名字还留在 fskv。
  `cfg.clear_alias()` **表本来就空时不写 fskv**（flash 擦写次数有限），所以
  "退出已清 → 进入再清"这第二次是零成本。
- **`R:INFER` 只读，禁止回写 poll**。曾有过 `W:APPLYINFER` 把推断结果盖掉 poll 的
  regs，两个问题：① dtype 猜不准（旁听拿不到类型信息，全写 uint16，电压类 float 会被
  解成整数）；② 用户手配的寄存器表被一整份覆盖。现已删除该指令，推断结果仅作参考，
  由人工核对后自行配置。
- **两套串口参数独立**。poll 改了波特率不影响 sniff，反之亦然。代价是同一台设备两种
  模式可能要各配一次——但总线波特率本来就是物理属性，通常两边填一样的值。

## 手动配置 / 拉取配置隔离（`ds_poll` vs `ds_pull`）

平台配置原本和手动配置**共用 `ds_poll` 一个槽**，`iot.auto_apply()` 一落盘就把用户
手配的寄存器表整份覆盖掉——拉一次平台配置，手配的那套就没了，两个都要不了。

现在拆成两个**同构**的槽（复用同一份 `normalize_poll`/`default_poll`，零新增校验代码），
由运行模式决定用哪个：

| 运行模式 | `W:MODE=` | MQTT 档位 | 配置槽 | 行为 |
|---|---|---|---|---|
| poll（手动配置） | `poll` | `manual_on=true` | `ds_poll` | 用手配的寄存器表和 MQTT（含手填的 pub_topic/sub_topic）。**发 hello**，`onboardingMode` 借 `platform`（文档只定义了 sniff 的行为） |
| poll（拉取配置） | `pollpull` | `manual_on=false` | `ds_pull` | 进入即自动 hello 拉平台配置（`onboardingMode=platform`） |
| 旁听 sniff | `sniff` | 无所谓 | 不用 | 只收不发 |
| 空闲 idle | `idle` | 不变 | 不用 | 不动总线 |

**模式、档位、配置槽三者绑定，没有混搭场景**：要么全手配（寄存器表 + MQTT），
要么全平台拉取。`ctrl.SLOT` 这张表就是这个映射，改任何一个都要三处同步。

⚠️ **`iot.set_manual(on)` 的 `on=true` 是手动档**。切换档位那一行写的是
`iot.set_manual(slot == "poll")` —— 写反的后果是拿手动档的凭证去连平台，
拉取档的 hello 没人应答，而且界面上看不出原因（MQTT 页只是手动配置行
集体消失）。改这行前后各读一遍 `set_manual` 的注释。

- **拉取档必须关掉手动档**。`mqttcfg.normalize` 只在手动档写入时清
  user/pass/pub_topic/sub_topic，`host/port/ssl` 是两档共用字段。手动档用户
  可能填了自建 broker，带着那个地址发 hello 没人应答，只会白等 35s 再报超时，
  所以 `ctrl` 进 `pollpull` 前先 `iot.set_manual(false)`，它顺带把
  host/port/ssl 归位到默认值（`auto.pass` 会带过去，不让用户自己设的平台
  密码被重置）。
  ⚠️ 订阅清单**不是**切换档位的理由：`build_subs()` 除 idle 外三档都订那 4 条
  gw 平台前缀（文档"下行 topic 三路同"），手动档再多订自己那条。
- **档位切换要断开重连**。`S.manual_on` 是在 `try_connect()` 里读的，订阅清单挂在
  conack 上，已连接的 client 不会自己重读。`set_manual()` 因此 `destroy_client()`
  + `kick()`，让 `task_main` 用新档位重连重建订阅。代价只是丢一次心跳周期，
  `collector` 的数据和寄存器表都不动。
- **平台推送只在拉取档生效**。`auto_apply()` 落 `ds_pull` 后，只有 `poll.cur_slot()=="pull"`
  才 `apply_cfg`/`start`。跑手动档时那份配置只是**存着备用**——否则用户没切档就被
  平台改了寄存器表。
- **进 pollpull 前会先检查 `ds_pull` 拉过没有**。没拉过就直接拿 default 起轮询，等于
  凭空造一套寄存器表、从机地址多半还是错的，所以 `ctrl` 先 `iot.pull_start()`，成功才转正。
- **`R:CFG` / `W:CFG` 都按模式选槽**（`pollpull` → `ds_pull`，其余 → `ds_poll`）。
  读写必须是同一套规则：只读分槽、保存写死 `ds_poll` 的话，拉取档下用户改完
  看到的值和自己存的对不上。实测过的三种坏味道——改 `baud`/`slave` 时重启且
  `poll.start()` 不传槽会把 `curSlot` 翻成 `"poll"`，界面自己跳回手动配置卡；
  只改 `interval`/`regs` 时不重启，下次进拉取档又读回 `ds_pull` 的旧值。
  前端因此有一条「配置来源」提示，说明平台下次下发会覆盖本地改动。
- ⚠️ **`poll.start()` 必须带槽**。它是 `curSlot = (src == "pull") and "pull" or "poll"`，
  不传 `src` 就等于强制置回 `"poll"`。`ctrl` 和 `W:CFG` 都要把槽传进去，否则
  拉取档下一次保存就静默切档——`ctrl.get_mode()` 看的是 `poll.cur_slot()`，
  模式卡会跟着跳，而 `ds_pull` 还留着旧值。

> ⚠️ sniff 配置目前**前端没有编辑入口**（无 `W:SNIFFCFG` 指令），始终用 `cfg.BAUD`
> 等默认值。如果现场总线不是默认波特率，旁听会看到乱码——这是已知缺口，不是本次要
> 解决的问题。

## 切回 idle 时的配置复位

`W:MODE=idle`（含 `stop`）不只是停总线，还会把用户配过的东西复位。**不可恢复**——
清掉的只有重新手填或前端「导入配置」能回来，所以前端在切换弹窗里逐条列明，并建议
先「导出配置」备份。

| 配置 | 键 | 处理 | 为什么 |
|---|---|---|---|
| 485 手配 | `ds_poll` | 清空 | 寄存器表/串口参数/从机地址是用户配置的主体 |
| 485 平台拉取 | `ds_pull` | 清空 | ⚠️ **必须清**：`ctrl` 进 `pollpull` 前靠 `pull_src()=="default"` 决定要不要先 hello 拉一次。留着一份旧的 `ds_pull`，它会跳过拉取直接拿旧配置起轮询——用户以为平台的新配置生效了，其实采的还是上一轮 |
| 系统 | `ds_sys` | **不动** | `boot_mode` 是"开机该进什么模式"的意愿，不是配置内容。清了它下次开机又不 idle，和设备已经 idle 的事实矛盾 |
| MQTT | `mqtt_cfg` | **部分清** | 见下 |

MQTT 按"首页写入的算连接参数、MQTT 页写入的算手动档凭证"切两半：

| 字段 | 处理 | 说明 |
|---|---|---|
| `host` `port` `ssl` `client_id` | 保留 | 首页「MQTT 服务器」面板可改。⚠️ `ssl` **必须和 host/port 一起保**：同一个 host 的 1883 明文和 8883 TLS 是两条路，只保地址不保 ssl 会把走 TLS 的用户打回明文，表现是"切回来就连不上了" |
| `auto.pass` | 保留 | 首页填的 MQTT凭证密码，与手动档那个 `pass` 是两份独立的值 |
| `interval_s` `qos` `keep_session` | 保留 | 共用字段，首页「保存」会一并带走，算"首页写入的内容" |
| `user` `pass` | 清空 | 手动档凭证 |
| `manual_on` | 强制置 `false` | ⚠️ **必须和清值在同一个 `save()` 里完成**。`normalize` 在 `manual_on=true` 时**使用** user/pass，只清值不换档的话设备会拿空凭证匿名连平台——表现是"切回 idle 后再没连上过 MQTT"，且前端 MQTT 页显示成手动档。拆成两次 save，中间任何一次失败都会把设备留在那个失联状态 |

三个实现细节：

- **"清空"是 `fskv.set(k,"")` 而不是 `fskv.del(k)`**。`kv_get` / `poll_src` /
  `pull_src` 都把 `""` 当"没写过"，语义完全够；而 `del` 在某些 LuatOS 版本上不存在，
  为一行复位引入兼容性风险不划算。
- **只清"写过"的槽**。没写过的槽也清一遍等于白写 fskv 外加一次 `save`，而 flash
  擦写次数是有限的。同理 `mqttcfg.clear_manual()` 在 `manual_on` 已经是 false 时
  直接返回 `wrote=false`，不落盘。
- **`manual_on` 变了要 `iot.kick()` 重连**。旧凭证还挂在已建连的 client 上，不 kick
  的话设备会继续用旧凭证跑，直到下次自然重连才换过来。`kick` 只在真的写过时才发。

应答格式：`RET:MODE=OK`（什么都没清）或 `RET:MODE=OK;cleared:pull+mqtt_manual`。
用 `k:v` 而不是 `k=v`，是因为 `protocol.js` 的 kv 解析要求整段里同时有 `;` 和 `:` 才
拆键值对，写成 `cleared=...` 前端只会拿到一整条字符串、取不出清了什么。前端据此
播报"已清空配置：xxx"，并重读 `R:CFG` / `R:MQTT` 让表单回落。

## 切档必须释放 485 总线（12-fix, 2026-10-27）

`W:MODE=idle` 的语义是"设备退场，释放总线"。**但原来只有 `mon.stop()` 做了这件事，
`poll.stop()` 没做** —— 两个 stop 不对称：

| | 解绑 UART 接收回调 | 关串口 |
|---|---|---|
| `mon.stop()`（`bus/mon.lua`） | ✅ `uart.on(id,"receive",nil)` | ✅ `uart.close` |
| `poll.stop()`（`bus/poll.lua`） | ❌ 只置 `running=false` | ❌ |

回调是在 `poll.start()`（`poll.lua` 的 `uart.on`）绑的。**poll 停过 → 回调永久残留**，
于是 idle/manual 档下总线上每个字节都被 poll 模块读走并打 warn：

```
W/user.poll on_receive id=1 got 8 bytes but respFlag=false (raw=[01 03 00 61 00 01 d5 d4])
```

现场日志（2026-10-27）：`W:MODE=idle` **明确成功**（`RET:MODE=OK;cleared:manual 配置+mqtt_manual`，
`R:MODE`/`R:STAT` 都报 `idle`），之后 `poll.on_receive` 仍以 ~500ms 周期持续输出。
那些字节是**外部主站（PLC/上位机）在轮询仪表**，不是本设备发的 ——
8 字节是请求帧（slave/fc/addrHi/addrLo/qtyHi/qtyLo/crc×2），
7 字节是响应帧（slave/fc/byteCnt/data/crc×2）。

修法：

- `poll.stop()` **无条件**解绑 + 关串口。不再只在 `running` 时做：只跑过 mon 没跑过
  poll 时，`is_running()` 守卫会让这个清理根本不执行，UART 留在开着状态。
- `poll.probe_raw()`（`W:RAWTEST`）在不在轮询态时，测完要**解绑并关串口** ——
  原来不 `running` 就什么都不做，`raw_on_receive` 会永久留在 UART 上，同一类泄漏。
- `ctrl` 的 idle 分支去掉 `is_running()` 守卫，无条件 `poll.stop()`。
- **不影响任何启动路径**：`poll.start()` 会 `ensure_uart()` + 重新绑定，`mon.start()`
  自己也 setup + 绑定；`ensure_uart` 的"第 2 次 setup"本来就 `close+wait500`，
  关不关串口都一样，不会多出等待。

> ⚠️ `poll.stop()` 现在会关串口。从 manual 切 sniff 时，`mon.start()` 拿到的是一个
> **已关闭**的 UART —— 这比原来（open 状态下 `uart.setup` 走快路径、只改分频不复位
> RX/DE）更干净，正是 `poll.lua` 注释里"合宙 FAQ #32：重新 uart.setup 会重置 RX 缓冲
> 和驱动上下文"想要的效果。

### 顺带修的坑：manual 档 + 空寄存器表 → 设备自己重启

`guard` 的 stall 判据原来只看**档位**：manual/poll/platform/sniff 都算"有采集在跑"，
`stall = ticks - last_alive` 一直涨，超过 `STALL_LIMIT_S`(120) 就 `rtos.reboot()`
（`AUTO_REBOOT=true`）。

但 34-fix 定了"**档位对应的槽空着就不起轮询**"，其好处之一明确写着"看门狗不再被
'poll 起来了但 regs=0' 误判为停滞" —— **但 guard 的判据一直没跟上，34-fix 的这个
意图其实没落地。**

后果（现场踩过）：切 idle 时 `cleared:manual 配置` 擦掉了 `ds_poll`，切回 manual 又
没重配 → `regs=0` → poll 没起 → 没人调 `guard.alive()` → stall 无限累积 →
**设备看起来好好的，过两分钟自己重启**。

修法：`guard` 的 stall 判据加上"**采集引擎是否真的在跑**"
（`bus/poll` / `bus/mon` 的 `is_running()`）：

- 引擎**没起** = 没有采集任务在跑，心跳停是正常状态 → **不判 stall**
- 引擎**起了但卡死** = `is_running()` 仍是 true → stall 照常累积 → 120s 后照样
  自愈重启 —— **看门狗没有退化**

`is_active_mode()` 的语义没动（单测锁着它），新判据是独立的 `stall_of()`。
sniff 识别期不受影响：`mon.start()` 先于 `mon.request_detect()` 调用，
`is_running()` 一直是 true，且 `sniff_wait()` 每 20ms 喂一次 `guard.alive()`。

## sniff 通讯参数自动识别（`R:AUTODETECT`）

上面的缺口靠识别来补：sniff 侧不可配，那就现场试出来。

**12 个候选 = 4 baud × 3 parity**，`parity` 放外层循环：

```
for parity in {N, E, O}:        # 8N1 占现场绝大多数，先整个扫完
    for baud in {9600,4800,2400,1200}:
        试 1 秒，解出 ≥2 个 CRC 合法帧 → 命中，立即停
```

> ⚠️ **baud 只列 1200~9600**：Air780EP 的 UART 在这个区间外不可用。原先的
> 19200/38400/115200 是照搬通用 Modbus 表，拿它们去扫只是白等一轮超时。

| 情况 | 耗时 |
|---|---|
| 总线是 8N1（绝大多数） | **1~4s**（9600 排第一，常见 1s 就中） |
| 总线是 8E1 / 8O1 | 4s + 1~4s |
| 总线上没数据 / AB 线错 | 走满 12s 后报 `no hit` |

**databits/stopbits 固定 8/1**，不参与扫描——ModbusRTU 的事实标准，7 位数据 /
2 停止位极少见，为它们把候选翻 3 倍不划算。

**判定不新写校验**，借 `task()` 现有的 CRC 试探切帧，只数 `stat.frames` 增量。
参数错 → 字节乱 → CRC 不过 → 一帧都解不出，这就是信号。CRC 是 16 位校验，
单帧误判率 ~1/65536，所以要 `DETECT_HITS=2` 帧才算命中。

### 三个实现要点（改之前必读）

1. **每个候选前必须 `rxbuf = ""`**。上一个候选解出来的乱码若留着，会在下一个
   候选的 1 秒窗口里被误当成新参数的帧，造成假命中。
2. **`uart.setup` 后必须重新 `uart.on(receive, on_receive)`**。LuatOS 的
   `uart.setup` 会重置 receive callback，少了这行从这个候选起一个字节都收不到，
   全部候选假阴性。原工程 `VKBox_Lite(1)/485_monitor.lua` 的 Q-Fix 8 就是这个坑。
3. **结果只存本次会话**。识别出的参数不写任何持久槽、更不碰 `ds_poll`——
   见上文「poll / sniff 配置隔离」。给一个「填入 poll 配置」的按钮会让用户
   一键覆盖手配的寄存器表，已确认不做。

### 触发时机：进 sniff 自动识别 + 按钮重新识别

**`W:MODE=sniff` / 开机 `boot_mode=sniff` 都会自动起一轮识别**，不需要用户先点
按钮。`mon.request_detect()` 由 `ctrl.switch_mode()` 调用，和手动按钮同一条路径。

**识别是非阻塞的**，这是关键设计：

| | 做法 | 为什么 |
|---|---|---|
| 同步等 12s | ❌ 不可行 | 命令是串行分发的（`prov.lua` 单循环），`W:MODE` 堵 12s 会让前端**所有**指令一起卡；而开机路径上堵住会让 VUART/MQTT 晚 12s 才就绪 |
| 同步且失败重试 | ❌ 更糟 | 静默总线上开机流程**永久卡死** |
| **后台任务 + 轮询** | ✅ | `W:MODE` 立即回 `OK`，识别在 `detect_loop` 里跑，前端轮 `R:AUTODETECT` 问结果 |

**失败不停、不退回 idle，每 3s 重来一轮**，直到命中或用户 `W:MODE=idle`：

- 模式必须停在 `sniff`，否则前端看到模式掉回 idle 会以为设备重启了
- 静默总线 / 主机间歇轮询时，一直重试总能等到它有流量的那一刻
- `detect_fail` / `detect_round` 计数让前端能显示"第 N 轮，已失败 M 次"

**识别期间屏蔽会动串口的命令**（`cmd.lua` 的 `blocked_while_detecting`）：

| 命令 | 识别期间 |
|---|---|
| `W:CFG` / `W:RAWTEST` | ❌ `RET:FAIL:<cmd>:BUSY:...` |
| `W:MODE=poll` / `sniff` | ❌ BUSY（闸门在 `ctrl.switch_mode` 里） |
| `W:MODE=idle` / `stop` | ✅ 放行——用户主动放弃的唯一逃生口 |
| `R:` 全部只读命令 | ✅ 放行（进度就靠 `R:MODE` 的 `mon.detecting` 看） |

> 识别正在 21 个候选间反复 `uart.setup`，此时写配置或裸发字节会跟它抢同一条
> 串口，出来的结果不可信。**`M.stop()` 里必须 `detecting = false`**——少了这行，
> 逃生口关了 BUSY 闸门还在，设备看着像卡死。

**`R:AUTODETECT` 是非阻塞的**，返回三种东西：

```
RET:AUTODETECT=BUSY            正在扫，过会儿再问
RET:AUTODETECT={...}           上一轮已识别出的参数（刷新页面后也拿得到）
RET:FAIL:AUTODETECT:not in sniff mode
```

不在 sniff 模式时**不会**自动帮用户进 sniff——一条查询指令不该有切模式的副作用。

### 2026-10: 重新识别 = 重新开一轮（先清再识别）+ 识别未成功前不上报

**「重新识别通讯参数」按钮**发的是 `R:AUTODETECT=restart`（不是裸的 `R:AUTODETECT`）：

| 动作 | 设备端做的事 |
|---|---|
| 清旧缓存 | `collector.clear_all()`：dataCache(值/dtype/conf) + frames + ring 全清 |
| 作废旧结果 | `mon.request_detect()`：当前检测轮作废 + `_G.mon_detect_result = nil` |
| 重扫 | 21 候选从头扫（最坏 21s） |

裸发 `R:AUTODETECT` 只是**问**上一轮的结果（设备有结果就直接回旧值，不重扫）——
所以按钮必须带 `=restart`，否则用户看到的是"点了没反应，只是复读参数"。

> ⚠️ `restart` 的参数判断必须**精确等于** `"restart"`：`cmd.lua` 的 `M.handle`
> 对**裸指令**也会把整行当参数传进 handler（`pcall(fn, line)`），裸发时
> `arg == "R:AUTODETECT"`。按"非空就算 restart"写，会让每秒一次的识别轮询
> 把自己正在跑的识别作废一轮，永远扫不出参数（2026-10 实测踩过）。

**缓存清理的三个时机**（`mon.lua`）：

| 时机 | 清什么 | 为什么 |
|---|---|---|
| 进 sniff（`mon.start`） | dataCache + frames + 旧识别结果 | 旧参数下的值/帧不能混进这一轮的推断 |
| 重新识别（`mon.restart_detect`） | 同上 | 同上 |
| 退出 sniff（`mon.stop`） | 同上 | 识别参数是"仅本次会话"的；不清的话下次进 sniff 的一瞬间，前端的"5s 轮询兜底采纳"会把上次的旧参数当成"已识别"显示出来 |

**识别未成功前不上报**（`iot.pub_blocked`）：

| 通道 | 识别未成功期间 |
|---|---|
| U1 hello / U2 meta / U2 拓扑 / U3 资源 / U4 数据 / U5 告警 | 🚫 全部不发 |
| U6 配置回执 / U7 指令回执 / `claim_ok` / `func_reply` | ✅ 照发（控制面回执，平台在等应答，压了会一直等/重推） |

- **"未成功"** = 正在识别 / 压根没有识别结果 / 识别失败（兜底 `cfg.BAUD`）
- **原因**：识别期间串口参数还是默认值或候选值，这期间发出去的东西，平台会按错波特率建一次模型（拓扑）、收到脏值（数据），白推一次配置还得重建
- **恢复**：识别成功后，下一轮周期任务自然恢复——门闸是"当轮跳过"且**不推进 `last_pub`**，识别一结束下一轮立刻补发，不需要额外的"恢复"逻辑

### 已修：识别失败后串口停在最后一个候选

`auto_detect()` 扫空一轮后调 `restore_params()` 把串口还原成进 sniff 时那套参数
（`bootCfg`）。不还原的话，失败后串口停在最后一个候选 **1200 8O1** 上，接下来
3s 等待期里到的真流量全成乱码，而下一轮又要从 9600 重新开始——中间那段窗口看着
像"总线时好时坏"，查不出原因。

### 已知调优点

`DETECT_WIN_MS`（`core/config.lua`）现为 **800ms**（12-fix-2 从 2000ms 降下来）。
按 9600 排第一定的：8 字节帧约 8ms，轮询周期内轻松攒够 2 帧。⚠️ **慢总线
（1200/2400）+ 稀疏从机时，800ms 可能只收到 0~1 帧而漏检**。真机测试若发现慢
baud 识别不出，优先把它调到 **1500~2000**（代价：最坏耗时 21s → 39s）。
常见 8N1 场景不受影响，因为 9600 第一个就中。

`DETECT_SETTLE_MS`（`core/config.lua`）现为 **2000ms**（12-fix-2 从硬编码 5000
降下来），是"进 sniff 后等 UART 稳定再开始扫候选"的固定等待。

`DETECT_HITS` 同理：若现场噪声大、偶发单帧误命中，可提到 3。

`DETECT_RETRY_MS`（`bus/mon.lua` 顶部）现为 **3000ms**，是两轮识别之间的间隔。
静默总线下没必要高频重扫（白耗电 + 刷日志），3s 足够等到稀疏主机冒出流量。

### 识别为什么这么慢：盲扫的代价（12-fix-2）

sniff 的通讯参数**用户不配**（sniff 没有持久槽，是刻意的设计），只能靠设备自己
认出来。现在的识别策略是**串行盲扫 21 个候选**：

```
外层 parity {8N1, 8E1, 8O1}        ← 奇校验排第三层
  内层 baud {9600,19200,38400,115200,4800,2400,1200}
每个候选 = close + wait500 + 监听 DETECT_WIN_MS
```

现场实测（2026-10-27，用户总线 = 外部主站每 ~500ms 轮询，设备为 4800 **奇校验**）：

| 项 | 改之前 | 改之后 |
|---|---|---|
| 每个候选耗时 | 0.5s + 2.0s = **2.5s** | 0.5s + 0.8s = **1.3s** |
| 首等（UART 稳定） | **5s** | **2s** |
| 4800 奇校验命中总耗时 | ≈ **52s**（它排在第 32 位） | ≈ **27s** |
| 轮次之间 | 整个 21 个候选重扫 | **跳过已试过的**，不重扫 |

12-fix-2 做了四件事：

1. **窗口 2000 → 800ms**、**首等 5000 → 2000ms**（`DETECT_WIN_MS` /
   `DETECT_SETTLE_MS`）
2. **候选记忆**：`mon.lua` 的 `tried` 表记住"试过且没命中"的组合，轮次之间不重扫
   —— 原来落空后整个 21 个候选白扫第二遍，还反复切 baud 打断外部主站。
   ⚠️ 只在**新一轮**识别（`mon.start()` / `mon.restart_detect()`）时清零，
   `request_detect()` 不清（它也被 `R:AUTODETECT` 的轮询路径调用）。
3. **暴露识别进度**：`R:STAT` → `mode.mon.try_baud` / `try_parity` 是"当前正在试
   哪个 baud/parity"。原来只能看到一个转圈，完全不知道设备在干嘛。
4. **加 `rx_bytes` 计数器**（收到多少**字节**，与 CRC 是否通过无关），
   每个候选的日志打 `frames=N bytes=M`。

### 下一步（量完再改）：21 个候选 → 7 个

`stat.frames` 只在 **CRC 合法**时才 +1，所以"**这个 baud 上有流量、只是校验位
不对**"这个强信息被整个丢掉了。如果 UART 在 parity 错时**仍然把字节交上来**
（一般 UART 只置 parity error flag，不丢字节），那么可以：

1. 先用"收到过字节"在 **7 个 baud** 上定位 baud（每个短窗口）
2. 再在该 baud 上用 CRC 找出正确的 parity（3 个）

→ 21 次降到 10 次，总耗时 ~6s。**但这个假设还没在设备上验证过**，所以 12-fix-2
先把 `bytes=` 打进日志，用现场数据确认"parity 错时字节收不收得到"，确认了再上。

> ⚠️ 如果 `bytes=0`（parity 错时字节被 UART 丢了），这条路走不通，得另想办法
> （比如按"主站轮询周期"反推 baud，或者干脆让用户手填）。


## 推断表：常驻累加器 + 主动推送（2026-10-28，12-fix-6）

### 为什么改

老 `M.infer()` 每次拿 `collector` 的**最后 10 帧**重建整张表。现场的总线一圈轮询
有 48 个地址，10 帧只够看见 5 个请求 —— 表在两组地址之间来回跳：

- 前端每点一次"推断轮询表"看到的**都不一样**（用户 2026-10-28 反馈）；
- `topo_sig()` 的指纹跟着每 30 秒变一次 → 平台每 30 秒重建一次物模型。

### 现在的语义

| | 老行为 | 现在 |
|---|---|---|
| 行的集合 | 每 10 帧重建，来回跳 | **只增不减**（到 `MAX_INFER_ROWS`=128 为止），一轮 sniff 内不删 |
| 顺序 | 按 从机 + 地址 排序 | **发现顺序**（前端第 1 列"序号"就是这个顺序） |
| `hits` | 每次重建都归 1 | **真累计**（这一轮嗅探到现在被请求了多少次） |
| 没应答的地址 | 整个从机没应答就整批过滤掉 | **也进表**，逐个地址判：`answered=false` + 前端显示 `no_rsp`（红色） |
| 前端刷新 | 必须手点"推断轮询表" | **设备主动推**（`RET:INFER_PUSH`），面板开着就自动更新 |

### 推送协议

```
前端 → 设备:  W:INFERWATCH=1      (sniff 面板打开)
设备 → 前端:  RET:INFERWATCH=1
设备 → 前端:  RET:INFER_PUSH={regs:[...], slaves:[...], ignored:N, stat:{...}}
前端 → 设备:  W:INFERWATCH=0      (面板关闭 → 停推)
```

- **只在 sniff 面板打开时开**：没人看的时候设备一个字节都不发（串口让给报文/指令）。
- 触发条件是**行集合变了**（发现了新地址）。表里的"最新值/出现次数"靠前端的
  **30 秒慢刷**（`R:INFER`）补 —— 值变化很频繁，为它推整张表不值当。
- 推送在 iot 的 1 秒巡检里发（`mon.take_infer_dirty()`），**不在收帧热路径上**：
  一次推送要拼几 KB JSON，放进热路径就是新的碎片化来源。
- ⚠️ `RET:INFER_PUSH` 是**设备主动**发的，不受前端"单条未决指令"约束：
  前端正在等某条指令的应答时来一条推送，前端必须先按 `INFER_PUSH` 键名把它分开
  （`frontend/renderer/app.js` 的 `onSerialLine`），否则会被当成那条指令的应答吞掉。

### 内存账（这表是常驻的）

- 一行 **8 个字段**：`slave/addr/fc/hits/answered/dtype/conf/value`。
- ⚠️ **字段数必须 ≤ 8**：Lua 表的哈希槽按 2 的幂走，**第 9 个字段就把 8 槽撑成
  16 槽** —— 实测每行 203 → 363 字节（+78%）。现场的 48 行 = 17.5KB → 10.8KB。
  三个能推出来的字段因此**不存**：`seq`（序号 = 行在表里的位置）、`status`
  （前端按 `conf` 推）、`count`（数量 = `dtype` 的宽度，前端按类型推）。
- `iot.attach_names()` 会给行加 `id`/`name` → 那是第 9/10 个字段 → 所以它
  **复制一份**再挂名字，不就地改活着的行（就地改 = +7.7KB 常驻堆）。
  ⚠️ **12-fix-9 起连复制都取消了**：名字改挂到顶层 `names` 表（见下节 B3）。
- `tests/lua/test_infer_acc.lua` 里有两条断言钉住这件事：行字段数 ≤ 8、
  48 行占用 < 12KB。改行结构时这个测试会先炸。

### 与平台（U2 拓扑）的关系

- 拓扑指纹现在**只在发现新地址时变** → 平台只在有新地址时重建物模型。
- ⚠️ `node_json` 的 `MAX_PROPS` 还是 **64**：现场的 48 个地址离上限还有余量，
  但**超过 64 个地址时拓扑只上报前 64 个**（推断表本身能到 128 行）。
- ⚠️ 推断表现在是**每 16bit 槽一行**（32bit 寄存器占两行），跟 `dataCache`
  和 U4 上报的点一一对应 —— 平台那边的模型和数据才对得上。老表是"32bit 合并成
  一行"，跟 U4 的点集对不上。

### 一轮 sniff 的重置

`mon.start()` / `mon.stop()` 会清空累加器 —— 新一轮 sniff 的地址表从零开始
（旧轮的地址混进新轮，平台上的物模型就串了）。


## 推断表分页 + 名字表外置 + 两处腾挪（2026-10-29，12-fix-9）

### 现场：第四次崩溃（09:14~09:19，SN VL20261019001）

前端连点刷新 → 整机卡死（09:19:03 + ramdump）。链条：

| 时刻 | 现象 | 数字 |
|---|---|---|
| 09:14~09:19 | Lua 池一路涨 | 290~294 KB / 307192 B（**95.8%**） |
| 点刷新 | 整表应答要**一块连续内存** | 64 行 JSON = **8158 B** |
| | 切不出来 | `alloc 8147 failed` |
| | json 编码失败 | `E/json json encode out of memory!!!` ×4 |
| | 应答变空表 | `RET:INFER={}` / `RET:STAT={"mode":{},...}` |
| | 系统池也见底 | 190780 / 203040 B（**94%**） |
| | 串口写不进去 | `E/uart system is out of memory!!!` |
| 09:19:03 | 整机卡死 | ramdump |

⚠️ 关键：**不是"总量不够"，是"要一块 8158 字节的连续块"**。LuatOS 的分配器
不合并相邻空闲块（`iot.lua` 的老注释早就写明了），池里全是小洞，8KB 连续块
根本切不出来 —— 现场日志里 `alloc 8147 failed` 后面 45ms 就是 `topo_sig failed`。

> 顺带查清了另一件事：**系统池没有泄漏**。同一份固件另一次跑，uptime
> 317s/327s/337s 的 `mem=145708/154168/154204` —— 涨 8.5KB 后就稳在
> **≈154KB（75.9%）**。崩溃那次的 190KB 里，多出来的 ≈36KB 是**排队等发的
> 8KB 应答**（R:INFER 的整表应答在 uart tx 缓冲里排着）。分页把应答砍一半，
> 这块也跟着减半。

### 四处改动

| # | 改动 | 位置 | 省的是什么 |
|---|---|---|---|
| A | **分页**：`R:INFER=off,n`，一次最多 32 行 | `mon.infer_page` / `cmd.lua` | 峰值连续块需求 8158 → ~4000 B |
| B3 | **名字表外置**：行一个字段都不加，名字挂顶层 `names` 表 | `iot.attach_names` | 一次 R:INFER 少造 ~50KB 瞬时垃圾 |
| 腾挪1 | **dtype 历史打包成一个数**（每帧 1 个 16 进制位） | `mon.dtypeHistory` | 每地址常驻 −96 B |
| 腾挪2 | **数据点不再存 hex**（那一行挂着整帧的十六进制串） | `collector.push_data` | 每地址常驻 −31 B |

另外两处配套：`iot.alias_map()` / `cfgstore.alias_map()` 加了**缓存**
（键 = 配置版本 + 槽位，写盘时失效），一次 R:INFER 少造 ~23KB 瞬时垃圾；
`cmd.M.reply` 不再把整条应答打进日志（大应答走新的 `reply_big`，只打长度 +
前 80 字节，一次省 2 份 8KB 拷贝）。

### A：分页

- 设备：`M.infer_page(off, n)` → `{regs(本页), slaves, ignored, stat, total, off, n, pages, page}`。
  `slaves/ignored/stat` 是**整张表**的口径（前端要显示"共 N 个从机，M 个轮询项，
  其中 K 个没应答"），`regs` 才是本页的。`n` 的硬上限是 `INFER_PAGE_MAX = 32`。
- 设备记着前端在看哪一页（`mon.set_infer_view`），主动推送（`RET:INFER_PUSH`）
  推的也是**那一页** —— 推整张表就是 8KB，正是现场崩掉的那个大小。
- 前端：`Protocol.Enc.infer(off, n)` → 按页取，表格下方有"上一页/下一页/第 X/Y 页"。
  序号列用**全局下标** `off + i + 1`（否则每页都从 1 开始，看不出是同一张表的两段）。
  名字表跨页累积（每页只带自己那页的条目）。

### B3：名字表外置

12-fix-6 的做法是"复制一份行再挂 id/name"—— 那次是为了**不就地改**活着的行
（就地改 = 第 9/10 个字段 = 哈希槽 8→16 = 每行 203→363 B）。复制本身在 64 个
地址时是 **23KB 表 + 128 个 id/name 串 ≈ 28KB**，加上两张别名映射表，一次
`R:INFER` 制造 **~65KB 短命垃圾** —— 现场就是这么被碎的。

现在：

- 行**一个字段都不加**（还是 8 字段 8 槽 = 203 B/行），常驻不变；
- 名字挂到**顶层 `names` 表**，且**只有跟默认值 `reg<addr>` 不一样的才登记**
  （用户改过名的通常只有几个）：
  `{"regs":[...8 字段的行...], "names":{"reg230":{"id":"x","name":"y"}}}`；
- **零复制**（`out.regs` 就是 `inf.regs`），每行还少两个字段 → 应答再小 ~30 B/行。
- ⚠️ 前端要跟着改：`renderInfer` 显示名字时先查 `names['reg'+addr]`，查不到
  就退回 `reg<addr>`（见 `frontend/renderer/app.js`）。

### 腾挪 1：dtype 判型历史打包

`dtypeHistory[alias]` 原来是 `{"uint16","uint16",...}`（最多 5 个字符串的表），
一张表 ≈ 96 B/alias。现在打包成一个数：每帧占 1 个 16 进制位，5 帧 = 5 位
（`16^5 = 1048576`，double 里精确）：

```
pushHistory:  dtypeHistory[alias] = ((old or 0) * 16 + code) % 16^5
calcContinuity: 逐位解出"最近 5 帧里有多少帧是这个类型"
```

- 判型口径**一个字没变**（`score()` 里那条"最后一帧也是这个类型 +5 分"的
  规则改成看最低位；`calcContinuity` 改成数位）。
- 为什么不是"砍到 32 个 alias"：FIFO 深度砍了会把老 alias 挤出去，判型连续性
  归零 → 现场那个"判死不认错"的毛病会回来（见 `test_dtype_band.lua`）。
- 单测钩子 `seed_history` 还能一次塞 8 帧（老的 `seed_history` 就是直接塞整张
  表不截断的），所以打包数留得下 8 位（`16^8`，double 里也精确）。

### 腾挪 2：数据点不存 hex

`collector.push_data(addr, alias, hex, ...)` 的 `hex` 参数还留着（调用点不用改），
但**不再挂到数据点上**：那一行挂着的是**整帧的十六进制串**，每个地址各留一份
引用（现场 64 个地址 = 64 个不同的帧串常驻）。而它只有一个读者 ——
`collector.snapshot()` 的 `R:VAL`，而前端只用 `name/addr/value`，不用 `hex`
（报文卡那儿的 hex 更全）。快照也不再带 `hex` 字段。

### 实测（PC 模拟器，`tests/lua/test_infer_mem.lua`，同一份量法）

64 个地址（累加器行 + dtype 历史 + 数据点）的**常驻**增量：

| | 64 地址常驻 | 每地址 |
|---|---|---|
| 旧 `13304dc` | 42.63 KB | **682 B** |
| 新 `12-fix-9` | **34.69 KB** | **555 B**（−127 B，−18.6%） |

128 个地址就是 71KB（旧的 85KB）—— 堆只有 300KB，这 14KB 是实打实的余量。
⚠️ 但**光靠腾挪还不够**：128 个地址要真正的余量，还得拆 `iot.lua`
（79.5KB 常驻，选项 B，见下面"常驻还是大"那条）。分页 + 腾挪解决的是
**碎片化**（不再要 8KB 连续块、不再造 65KB 瞬时垃圾），不是总量。

## 拓扑一次成串 + 每地址瘦身（2026-10-29，12-fix-11）

### 现场症状：拓扑一帧都没发出去（`topo=0`）

现场 SN VL20261019001，跑到 82 个地址时：

```
W/user.iot topo_sig failed, skip this round: iot.lua:690: not enough memory for buffer allocation
```

`iot.lua:690` 就是拓扑拼串的那行 `table.concat(props, ",")`。**连 8.3KB 的
连续块都切不出来**，所以拓扑一帧都没发出去 → 平台那边没有物模型 →
用户在平台上只看到一部分数据（这就是"只报了一部分数据"的根因）。

### 为什么拓扑这么吃内存：它同时活着 4 份 8KB+ 的连续串

| 步骤 | 产物 | 常驻/瞬时 |
|---|---|---|
| `props[64]` | 64 个 property 片段（每个 ~130B） | 8.3KB（小块，散着） |
| `table.concat(props, ",")` | **8.3KB 连续** | 瞬时 |
| `string.format(...)` 拼 node | **8.5KB 连续** | 瞬时 |
| `table.concat(nodes, ",")` | **8.5KB 连续** | 瞬时 |
| 指纹 `tostring(#nodes)..":"..nodes` | **8.5KB 连续** | **常驻**（`S.topo_sig`） |
| `string.format(...)` 拼 body | **8.6KB 连续** | 瞬时 |

峰值 = **25.6KB 连续内存同时活着**；另外 `build_nodes` 里的 `put()` 还给
每个地址造两张表（6 字段 + 7 字段 = 406 字节），82 个地址 = **33KB 垃圾/轮**。

### 改法

1. **拓扑一次成串**（新模块 `lua/iot/topo.lua`）
   - `topo.prop()` 出一条 property 片段；`topo.node_parts()` 往调用方的表里
     塞节点的片段；**最后一次 `table.concat` 才出 body**。
   - 指纹从"整串"改成**片段内容的 31 位哈希**（几十字节）——`S.topo_sig`
     不再常驻 8.5KB。
   - 峰值连续需求：**25.6KB → 8.6KB**；总分配量实测 **-34%**
     （`tests/lua/test_topo.lua` 里钉着这条线）。
   - 输出**逐字节不变**：拓扑的字节就是平台的物模型契约，
     `test_topo.lua` 把老逻辑的格式串抄了一份做基准，逐字节对比。
2. **不再给每行造小表**：`build_topo()` 直接引用 `mon` 的活行，
   解析出的 id/name 立刻变成 property 片段；分组用两个平行数组
   （`addrs`/`props`）而不是每行一张表。
3. **数据点瘦成 4 个字段**（`data/collector.lua`）
   - 原来 6 个：`addr/value/ts/dtype/conf/status` —— 其中 `conf` 和 `status`
     **全项目没有任何读者**（前端的 conf 来自推断行，状态是前端按 conf 推的）。
   - Lua 表的哈希段按 2 的幂走：≤4 字段 = 4 槽 = 96B，5~8 字段 = 8 槽 = 192B。
     砍到 4 个字段 = 哈希段直接减半，**每地址 -96 字节**。
4. **删掉 `aliasCache`**：`"reg<addr>"` 本来就是全局 intern 的同一个串对象
   （Lua 的短串表保证），自己再缓存一张哈希表纯属白占
   （128 个地址 ≈ 6KB 一次性 + 每地址 ~40 字节）。
   代价是每次 `alias_of` 多 1.7 字节的数字→串转换（现场 520 次/秒 ≈ 0.9KB/s，
   跟整帧几十 KB/s 的 churn 比是 2~5%）。`test_churn.lua` 的上限相应从 1 放宽到 4。
5. **JSON 应答只拼一次**（`svc/cmd.lua`）
   - `M.reply("RET:X=" .. jencode(t))` 会造三份大字符串（jencode 产物、
     拼好的整行、再拼 `\r\n`）。`R:STAT` 现场实测 2226 字节 × 3 = 6.7KB 垃圾，
     **每 5 秒一次**。现在统一走 `reply_json()`，全程只留一份。

### 实测（PC 模拟器）

| | 64 地址常驻 | 每地址 |
|---|---|---|
| 旧 `12-fix-9` | 34.69 KB | 555 B |
| 新 `12-fix-11` | **29.69 KB** | **475 B**（−80 B，−14.4%） |

拓扑构建（64 条 property）：老链路 65026 字节 → 新链路 42641 字节（**−34%**）。

### 顺带查出来的两个真 bug（**没改**，单独排期）

1. **物模型的 `dataType` 一直是 `uint16`**：`build_nodes` 原来读的是
   `r.dtype_summary`，而 12-fix-6 把推断表改成累加器之后，行里已经没有这个
   字段了 → sniff 档的 32bit 寄存器也被报成 `uint16`。
   修它等于动平台的物模型契约（平台到底收不收 `uint32/int32/float32`
   还没在现网验过），**必须单独一次改**，别混在内存优化里。
2. **32 位固件上 `os.time()*1000` 整数回绕**：实测 `os.time()*1000` =
   **-2036609728**（负数！）。`send_meta` / `send_topo` / `check_event_threshold`
   三处的 `ts` 都是这个回绕值。框架里已经有正确的写法
   （`MqttUtil.ms_of(os.time())`），但那三处还没换。
   ⚠️ 换的话 `ts` 会从"数字"变成"字符串"（32 位机上毫秒数放不进 int32），
   U4 的 ts 早就是字符串、平台认，所以大概率没问题 —— 但仍要单独验一次。

### 新增测试

| 测试 | 钉住什么 |
|---|---|
| `tests/lua/test_topo.lua` | 拓扑的字节与老逻辑**逐字节一致**；指纹的性质；拓扑构建的分配量 |
| `tests/lua/test_cmd_stat.lua` | `R:STAT` 的结构（括号配平/逗号不错位/四个段都在）；一次应答只拼一份 |


## 内存缓冲上限（Air780EP，Lua 堆 ~300KB）

所有常驻缓冲都必须有硬上限——堆只有 300KB，`R:STAT` 实测已用 ~110KB，余量 ~90KB。
下表是全部常驻缓冲，**新增缓冲前先在这里补一行**：

| 缓冲 | 位置 | 上限 | 超限行为 |
|---|---|---|---|
| `dataCache` 采集值 | `data/collector.lua` | 无显式上限，键来自 regs ≤ `MAX_REGS`(128) | 按 alias 覆盖，不增长 |
| `frames` 帧缓存 | `data/collector.lua` | `FRAME_CACHE`(10) | 删最早 |
| `ring` 事件日志 | `data/collector.lua` | `RING_SIZE`(24) | 环形覆盖 |
| `writeQ` 下行写队列 | `bus/poll.lua` | `WRITEQ_MAX`(8) | 拒收入队 |
| `rxbuf` 串口收缓冲 | `bus/mon.lua` | 512B | 截到尾 256B |
| `rx_buf` 指令行缓冲 | `sn/prov.lua` | `MAX_BUF`(16384) | 整缓冲清空 |
| `pendingReqs` 待配对请求 | `bus/mon.lua` | 每 fc ≤ `MAX_PENDING_PER_FC`(4) | 删最早 |
| `lastReqs` 最近请求索引 | `bus/mon.lua` | `MAX_LAST_REQ`(64) | **整表作废** |
| 推断展开的 qty | `util.lua` `clamp_qty` | `MAX_INFER_QTY`(256) | 截到上限 |
| **推断表行数（常驻累加器）** | `bus/mon.lua` `M.infer` / `acc_row` | `MAX_INFER_ROWS`(**128**，2026-10-28 从 512 降；**最多只累计 128 个参数地址**） | 不再新增行（`stat.infer_clamped` 计数） |
| **推断表单次应答行数** | `bus/mon.lua` `M.infer_page` | `INFER_PAGE_MAX`(**32**，2026-10-29 新增) | 多的分页给前端（`R:INFER=off,n`） |
| **dtype 判型历史** | `bus/mon.lua` `dtypeHistory` | **128 个 alias**（2026-10-28 新增上限） | 淘汰最旧的 alias |
| 拓扑 properties 条数 | `iot.lua` `node_json` | 64（2026-10-27 从 128 降） | 不再拼进 JSON |

三个容易漏的点：

- **`lastReqs` 曾是缺口**：键是 `"slave:qty"`，键空间上千万且只增不减。sniff 挂在
  异常总线上会单调增长，两千条左右就吃掉大半堆。现在 `push_req` 里封顶，超限整表
  作废——不逐条 FIFO 是因为 `guess_last_req` 本来只认 10 秒内的条目，丢掉的都是
  更旧的，配对结果不变，还省一份顺序数组。
- **`pendingReqs` 的有界是间接的**：能进 `push_req` 的 fc 只有 3/5/15（`parse_frame`
  是白名单 + 强制 CRC），所以实际 ≤ 12 条。改 `decode_frame` 的 kind 判断时必须复核。
- **推断的 qty 曾是缺口（2026-10 修的真崩溃）**：请求帧里的 qty 是 2 字节，最大
  0xFFFF=65535，跟从机实际回了多少字节无关。`M.infer` 原来直接 `while j < f.qty`
  展开——总线上来一个异常 qty 的帧（别的协议的帧 / 脏帧 / 误解析），一次就展开
  6 万多项，每项一个表 + 一个字符串 key → 几十 MB → Lua 堆(203K)爆：
  ```
  E/user.coroutine.resume iot.lua:401: not enough memory for buffer allocation
      [C]: in field 'concat'          ← node_json 里 table.concat(props)
      iot.lua:466 → build_nodes
      iot.lua:486 → topo_sig (每秒一次)
  E/main Lua VM exit!! reboot in 15000ms
  ```
  现场表现：**跑着跑着莫名重启，重启后又好了**（偶发，取决于何时冒出异常 qty）。
  现在三层封顶：`util.clamp_qty`(256) → `MAX_INFER_ROWS`(512) → `node_json` props
  ≤128。被截断的次数记在 `mon.stat.infer_clamped`，`R:STAT` 的 `mon` 段能看到
  ——**这个数不为 0 就说明总线上有异常 qty 的帧**，值得查现场设备。

**sniff 拓扑上报的分配预算（11-fix, 2026-10-27）**：现场抓到 sniff 识别成功后
偶发 `not enough memory for buffer allocation` → `Lua VM exit!! reboot`，崩在
`build_nodes` → `node_json` 的 `table.concat` 上。排查结论：

- **不是**历史上那个"异常 qty 展开"（那次 `mon.stat.infer_clamped` 会 ≠ 0，
  现场两次都是 0，`clamp_qty`/`MAX_INFER_ROWS`/`MAX_PROPS` 三层封顶是生效的）；
- **也不是**"堆不够用"——`rtos.meminfo("sys")`（`iot.lua` 的 `heap_info()`）
  读的是**系统内存**不是 Lua 堆，现场显示 38% 就 fatal。真 Lua 堆用量要用
  `collectgarbage("count")` 读；
- 真因是**每轮两次 `build_nodes()`**：`topo_sig()` 算指纹 build 一次，
  `send_topo()` 发送时又 build 一次。每次都是 `mon.infer()` 重建整张推断表
  → `node_json` → 两层 `table.concat`，白扔一半分配预算。

修法：`topo_sig()` 把 nodes 串一并带出，`send_topo()` 复用，**每轮只 build 一次**；
顺带 `node_json` 的 props 上限 128→64、`topology posted` 日志不再拼整串 sig
（1.2KB 又一份拷贝）。

> ⚠️ `should_pub_topo()` 只对 sniff 返回 true，`build_nodes`/`node_json` 只有它
> 会调到 —— **这套改动只影响 sniff 档，platform/manual 的采集与上报完全不受影响。**
>
> ⚠️ `pcall` 拦不住这个 —— LuatOS 分配器级的 OOM 是 **fatal**，`pcall` 只能拦
> 普通 Lua error。真正兜底只能靠"少分配"，别指望加 pcall 就行。

> ⚠️ **插桩已摘除（12-fix-2, 2026-10-27）**：原来 `build_nodes()` 里每轮打两行
> `mem bn infer %.1f->%.1fKB` / `mem bn nodes %.1fKB`（`collectgarbage("count")`
> 读真 Lua 堆用量）。摘掉的原因：
> ① 它自己就是热路径上的分配（两次 `string.format` + 三次 `collectgarbage` 调用），
> 每秒 2 行；
> ② 被门槛挡住时那三次 `lua_kb()` 调用**仍然是实打实跑着的**，白花；
> ③ 水位现在从 **`R:STAT` 的 `mqtt.lua_kb` 字段**看 —— 那是 5s/次的人工查看路径，
> 零常态开销，前端想看就看。（12-fix-8 起 `R:STAT` 只有一个 `mqtt` 段，
> 原来的 `iot` 段与它内容完全一样、白占 1.5KB 连续内存，已删。）
>
> ⚠️ **别把 `collectgarbage("count")` 换成 `collectgarbage("collect")`** ——
> 那是真回收，有毫秒级暂停，放热路径上有让 UART 环形缓冲溢出的风险。
>
> **实测水位（sniff 档，2026-10-27）**：
>
> | 场景 | infer 起点 | 轮内峰值 |
> |---|---|---|
> | 刚识别完（推断表还小） | ~198KB | ~204KB |
> | 跑 9 分钟（主站把 `dataCache` 轮询到 128 个地址） | ~221KB | **~236KB** |
>
> 基线抬高的 23KB 就是 `dataCache` 填到 `MAX_REGS`(128) 条常驻值 —— 它**到 128
> 就封顶**，所以基线不会继续涨（实测第 3~5 轮是锯齿不是单调上升）。但 **236KB
> 这个峰值已经越过 ~231KB 的崩溃线**，这就是 12-fix-2 要压的东西。

- **`mon.infer()` 加了 2 秒 TTL 缓存**（12-fix）：`infer()` 每次都要遍历 frames +
  重建整张 `agg` 表 + `regs` 数组 + `table.sort`，全是临时分配；插桩实测单次
  infer 净增 **~3.1KB** Lua 堆垃圾，是 sniff 上报路径上最大的一笔。而
  `build_nodes()` 每秒调它一次。推断结果几秒内不会变，加缓存后调用频率减半、
  垃圾减半。`R:INFER` 走 `mon.infer(true)` 强制取当前值（前端推断表要新鲜）。

- **拓扑【重建】按 `TOPO_REBUILD_MS`(5s) 节流**（12-fix-2）：`build_nodes()` 每轮
  分配 ~14KB（infer 重建整张推断表 + `node_json` 拼 JSON + 两次 concat），
  满负荷时实测峰值 236KB。拓扑只在"推断出的寄存器集变了"时才需要重发，
  **晚 5 秒完全无影响**，所以节流的是**重建本身**（`iot.lua` 的 task_main 里
  `S.topo_at` 闸门），**不是主循环** —— 心跳/上行/平台推送照旧 1 秒一轮。
  ⚠️ `os.clock()` 是**秒**级单调时钟，配置里是毫秒，比较时必须除 1000
  （直接比 5000 会变成 83 分钟才重建一次）。

### 统一上报调度（12-fix-4，2026-10-28）

**先说现象**：第二次现场崩溃（跑 5 分钟）跟第一次不一样了 —— 崩在
`iot.lua:621`（`send_meta` 里 `table.concat` 拼 600 字节），而当时
**used=275456 / total=307192，还剩 31KB 空闲**。

> 不是"不够"，是**碎片化**：堆被切成大大小小的空洞，切不出 600 字节的连续块。

碎片哪来的？**每秒**往 300KB 的堆里灌 ~25KB 垃圾：

| 每秒都在做的事 | 分配量 |
|---|---|
| `publish()` —— 重建配置 + 拼 ~4KB body + MQTT 编码 | ~12KB |
| `build_nodes()` —— 重建整张推断表 + node_json | ~14KB（每 5 秒一次） |
| `meta_sig()` —— 含 `csq`，信号强度一变就重发元数据帧 | ~2KB |

现场实测 `published` 从 112 涨到 213：**126 秒发了 101 次 = 0.8 次/秒**。

#### 口径：把「内容变了」和「该不该发」拆开

```
"内容变了" = 事实，只置脏
"该不该发" = 策略，走统一闸门

发 = (内容变了 OR 到期兜底) AND 过了本通道的最小间隔
```

| 通道 | 内容变了怎么判定 | 最小间隔 | 到期兜底 |
|---|---|---|---|
| `meta` U2 元数据 | 身份指纹变（imei/iccid/host/位置） | `PUB_MIN_MS`(30s) | `interval_s`(120s) |
| `prop` U4 子设备数据 | 有数据点更新 | `PUB_MIN_MS`(30s) | `interval_s`(120s) |
| `topo` U2 拓扑 | 推断出的寄存器集变 | `TOPO_REBUILD_MS`(30s) | 无（靠重建时比对） |

实现在 `lua/iot/pubsched.lua`，单测 `tests/lua/test_pubsched.lua`（含
「30 秒内持续置脏 → 只发 1 次」的回归）。

#### ⚠️ csq 从元数据指纹里摘掉了（用户拍板）

指纹的语义是**"要不要重建平台模型"的身份标识**。`csq`（信号强度）是个
**会变的数值**，混进去的后果是：

```
csq 变 → 指纹变 → 重发元数据帧 → 平台按契约重建模型
        → 回推 config/get → 我们再发拓扑 …… 每秒一轮
```

现场实测元数据帧从"偶尔"变成**每 10~20 秒一帧**，每次都是 csq
29→27→30→28→26 在牵着走。

`csq` **仍然在 payload 里**（只是不再参与指纹），靠 `interval_s` 定期带上去。

#### 配套的四处降 churn

- **`publish()` 里 `mqttcfg.load()` 提到循环外** —— 原来每从机调一次，
  而它每次都要 `fskv.get` + `json.decode` 整份 MQTT 配置
- **`mqttcfg.load()` 加缓存** —— 这份配置一天可能只改一次，却在项目里被调
  得极勤（task_main 每秒、meta_sig 每秒、publish 每从机）。
  ⚠️ 已核过全部 12 处调用点都只读不改；`save()` 落盘后必须让缓存失效
- **`collector` 的 ring 改成调试期才写** —— 现场实测 `push_data` 被调
  **80 次/秒**、每次 `string.format` 一条 "data reg123=456"，而 ring 只留
  24 条、且**全项目没有任何一处读它** → 每秒白造 ~120 个字符串。
  ⚠️ 拼接必须写在 `if` 里面（Lua 的实参先求值再调用，
  写成 `f(string.format(...))` 的话 format 照样每次都跑）
- **`TOPO_REBUILD_MS` 5000 → 30000** —— 拓扑的重建也并进统一闸门。
  原来 5 秒一重建，而 sniff 档寄存器集一直在变 → 现场实测拓扑 posted
  出现在 10:46:34 / 10:46:50 / 10:46:55 / 10:47:00，平均 20 秒一帧，
  每次都拖着平台重建一遍模型

#### 结构普查（每 30 秒一行）

```
I/user.iot census lua=126.4KB points=64 frames=10 aliases=128 rows=64 pub=213/0 meta=3 topo=6 blk=412
```

一次 `string.format` + 一次 `collectgarbage("count")`，30 秒一次，零常态开销。
**现场一崩，最后那行 census 就直接指出是哪个数字在涨**（不用再猜）。

字段（2026-10-28，12-fix-7 之后）：

| 字段 | 含义 |
|---|---|
| `lua=` | Lua 堆水位（KB，`collectgarbage("count")`） |
| `points=` / `aliases=` / `rows=` | dataCache 点数 / dtype 历史别名数 / 推断表行数 |
| `pub=` | 已发布条数 / 失败条数（**注意：拼大包失败不计入 failed**） |
| `meta=` / `topo=` | 统一调度已发的 U2 元数据 / U2 拓扑条数 |
| `blk=` | 被 30 秒闸门挡掉的次数 |
| `fps=` / `push=` | 帧率 / 点率（涨了 = 分配量又上去了） |
| `gc=` | 堆水位保险丝触发次数（12-fix-8 起阈值 **200KB(count)**，换算成池用量约 266KB ≈ 87%）。⚠️ 12-fix-7 那版阈值是 240KB，**比失效点还高 → 一次都没触发过**（现场 `gc=0`），垃圾堆到池 98.6% 才崩 |
| `bfail=` | **大包拼不出来的次数**（U4/拓扑，12-fix-7 新增）。**不为 0 = 上报已经瘸了**，哪怕 `pub=` 的失败数是 0 |
| `rc=` | 大包分配前主动回收的次数（12-fix-7 新增） |
| `err=` / `aerr=` | 旁听解析出错次数 / 其中"堆分配失败"导致的丢帧（12-fix-8 新增）。**`aerr` 不为 0 = 堆又在吃紧**，设备没崩但已经开始丢帧 —— 这是崩溃前的先行指标 |

⚠️ `collectgarbage("count")` **不等于** Lua 堆池的真实用量：现场
`E/mem ... used 290368`（283.6KB）对应 `census lua=213.7KB`，差的 ~70KB 是
**每个活跃对象的 GC 头 + 池块头**（约 1900 个对象，一个 ~40B）再加碎片。
换算关系约 **池用量 ≈ count × 1.33**，定阈值时别忘了这一层（12-fix-8 的
保险丝从 240 降到 200 就是为这个）。

⚠️ 只**读** `count`，绝不能用 `collectgarbage("collect")`（那是完整回收，
有毫秒级暂停，热路径上有让 UART 环形缓冲溢出的风险）。
—— 唯一的例外是 12-fix-7 的 `reclaim_if_high()`：它**只在拼大包之前、
且水位 > 200KB 时**回收一次，跑在 iot 的发布/巡检路径上（不在 UART 收帧
协程里），现场 52 帧/秒 ≈ 每 19ms 一帧，几毫秒停顿是安全的。

### sniff 档 OOM 崩溃复盘（2026-10-28，12-fix-3）
用**多寄存器**设备测 sniff 上报，跑到 130 秒时崩了：

```
E/mem memory allocation failed total 307192, used 266752, alloc 3033
E/main Luat: not enough memory
  mbus.lua:188 → mon.lua:210 → mon.lua:239 → mon.lua:290 → mon.lua:341 → mon.lua:402
E/main Lua VM exit!! reboot in 15000ms
```

**崩溃点不在上报路径**（`topo_sig`/`build_items` 都被 pcall 兜住，只打
"skip this round"），而在**收帧处理协程**里解析寄存器值那一步。

`used` 一直在 **258840~268696** 之间波动、**从不降到 253KB 以下**，而堆总量是
300KB —— 空闲 40KB 却申请不到 3KB 连续块 = 碎片化 + 常驻太高。

#### ⚠️ 走过的弯路：不是 GC 参数的锅

我一度判断那 253KB 地板是「Lua GC 的触发水位」（以为 pause=200、活对象翻倍才
收），打算用 `collectgarbage("setpause", 120)` 压下去。**单测把它否掉了**：

- LuatOS 的默认 pause 是 **90**，不是 200；
- 把 pause 调成 120 / 200，垃圾水位峰值**纹丝不动**（238.2 vs 238.3 KB）。

所以 **253KB 地板就是活对象本身**。调 GC 参数救不了 OOM，**只能少常驻、少分配**。
（`tests/lua/test_gc_pressure.lua` 把这条结论钉住了，免得以后再走一遍。）

#### 三处根因 + 修法

| 根因 | 常驻/瞬时 | 修法 |
|---|---|---|
| **推断表** 512 行 × 9 字段 table(272B)，而且 `infer_cache` 把整份**常驻** | **~140KB 常驻**，重建瞬时 ~185KB | `MAX_INFER_ROWS` 512 → **128**（下游 `node_json` 的 `MAX_PROPS` 才 64，128 已 2 倍余量）→ 常驻 ~35KB。⚠️ 2026-10-28 又改成常驻累加器（每行只 8 字段 = 203B，48 行 10.8KB），见「推断表：常驻累加器 + 主动推送」 |
| **`dtypeHistory`** 每个见过的地址一条，**从不淘汰**，`mon.stop()` 也不清 | 26~100KB（无上限） | 加 `MAX_HIST_ALIAS`=**128**（与 `dataCache` 对齐）；`mon.stop()` 补 `clear_history()` |
| **`mbus.parse_value` 每次调用分配 2~4 个对象**（`raw` 字符串 + `b` 表 + 字交换表 + float 表），而 `pickDtype` 一次调它 **8 次** | **~1.1 万次分配/秒**（47 帧/秒 × 240 次/帧） | 改成 `data:byte(p+1, p+8)` 直接取字节、**不建中间表** → **零分配** |

另外两处降 churn（不是崩溃主因，但同一个方向）：

- **`cfg.lua` 加配置解码缓存**：原来 `load_poll`/`load_pull`/`load_alias` 每次
  调用都要 `fskv.get` 整份 JSON + `json.decode` 整张表（128 条 ≈ 35KB 垃圾/次），
  而 `build_items()` 一次调用里就要反序列化 3~4 遍。→ 只缓存**解码后的原始表**
  （归一化仍每次跑，调用方拿到的仍是各自独立的一份），`build_items()` 里
  `alias_map(c)` 复用已加载的配置。⚠️ 写盘（`kv_set`/`reset_user`/`clear_pull`）
  必须让缓存失效。
- **`iot.lua` 的 `S.dirty` 把 publish 变成每秒一次**：`collector.on_update` 每次
  `push_data` 都置位 `S.dirty`，总线上有流量就永远脏 → `publish()` 每秒跑 →
  每秒上百 KB 垃圾。**这一条改的是产品行为（平台数据延迟），还没改**，
  待定。

**OOM 兜底**（`iot.lua` 建连失败且报 memory 时）：`collector.trim_cache()` +
`mon.trim_reqs()` + 强制 GC + 固定等 30s。`mon.trim_reqs()` 不能省——`lastReqs` 是
`mon` 的局部表，`collector.trim_cache()` 碰不到它，少了这句清了缓存照样 OOM。


### 第二次崩溃复盘：churn 才是碎片化的根源（2026-10-28，12-fix-5）

12-fix-4（统一上报调度）之后现场又崩了两次，**崩溃点从上报路径挪到了收帧路径**：

```
E/mem memory allocation failed total 307192, used 282488, alloc 3471   ← 3471 = R:STAT 的 JSON
E/mem memory allocation failed total 307192, used 276112, alloc 1568
E/user.coroutine.resume not enough memory
  mbus.lua:218 (parse_value) ← mon.lua:244 ← mon.lua:273 (pick_dtype)
  ← mon.lua:324 ← mon.lua:375 ← mon.lua:436
E/main Luat: not enough memory → Lua VM exit!! reboot in 15000ms
```

两次崩溃前都紧跟着一条 `R:FRAMES=30`（用户打开了前端「总线报文」面板）。
`used 282488/307192` = 堆已用 92%，**还剩 24KB 却切不出 3.4KB 连续块** ——
这是碎片化的签名，不是"总量不够"。

#### 两条独立的根因（都量出来了，不是猜的）

**① 我们的代码本身就吃掉 276KB —— 堆的 92%**

`tests/lua/test_heapsize.lua`：在 LuatOS PC 仿真器里逐个编译 `lua/` 下的模块、
留住产物、量 `collectgarbage("count")` 的增量：

| 模块 | 编译后占堆 | 模块 | 编译后占堆 |
|---|---|---|---|
| `iot/iot.lua` | **79.6 KB** | `sn/prov.lua` | 13.2 KB |
| `bus/mon.lua` | **38.1 KB** | `iot/pullcfg.lua` | 11.6 KB |
| `svc/cmd.lua` | 28.3 KB | `sn/sn.lua` | 10.7 KB |
| `bus/poll.lua` | 21.6 KB | `cfg.lua` | 14.0 KB |
| `lbsLoc2.lua` | 16.0 KB | `iot/mqttcfg.lua` | 9.5 KB |
| `bus/mbus.lua` | 16.0 KB | `bus/ctrl.lua` | 8.3 KB |
| `data/collector.lua` | 7.8 KB | `util.lua` | 8.3 KB |
| `svc/guard.lua` | 6.0 KB | `iot/topo.lua` | 2.6 KB |
| `core/config.lua` | 4.2 KB | `util/mqtt_util.lua` | 3.4 KB |
| `iot/pubsched.lua` | 4.5 KB | 其余 2 个 | 0.4 KB |
| **合计** | **303.9 KB** | | |

> ⚠️ 上表是 **2026-10-29（12-fix-11 之后）** 的实测（`tests/lua/test_heapsize.lua`
> 在 PC 模拟器里逐个编译模块、留住产物、量 `collectgarbage("count")` 的增量）。
> 红线 320KB，现在 **303.9KB，余量只有 16.1KB** —— 下次再加代码前先看这张表。
> ⚠️ `iot/topo.lua` 是 12-fix-11 新加的模块（+2.6KB），换来的是拓扑指纹
> 不再常驻 8.5KB —— 净账是赚的。

设备上 idle 档 `collectgarbage("count")` = **190KB**（LuatOS 这个接口返回 KB，
不是标准 Lua 的字节），堆总量只有 300KB —— **留给运行期数据的只有 ~110KB**。
去注释（`prep_burn.ps1`）对体积**毫无帮助**（275.75 vs 273.46 KB）：编译产物的
大小由指令和常量决定，注释根本不进产物。`test_heapsize.lua` 现在把 320KB
钉成红线，代码再涨就测试红。

**② 每秒几十 KB 的垃圾 churn —— 碎片化就是这么来的**

`tests/lua/test_churn.lua`（量法见该文件头：Lua 5.3 的
`collectgarbage("stop")` 只关紧急回收、增量 GC 照跑，所以要靠"N 次分配量
低于 GC 启动阈值"来量）：

| 热路径 | 改前 | 改后 | 怎么改的 |
|---|---|---|---|
| `mon.pick_dtype`（一个 16bit 槽位） | **632 B** | **29.5 B** | 候选表 `{int16,uint16}` 等 3 个表字面量写在函数体里 → 每次调用重建 8 张表；提到模块级常量 |
| `collector.push_data`（一个点） | **192 B** | **16 B** | 每次新建 7 字段表 → 老 key 原地改字段 |
| `mbus.decode_frame`（一帧） | **450 B** | **178 B** | 见下 |
| 同一帧**被解两次** | ×2 | ×1 | `next_frame` 为了判断合法性先解一遍、把表扔掉，`process_frame` 又解一遍 |
| 帧表本身 | 每帧新建 | **复用** | `collector.take_frame()` 从池子里拿旧表来填（字段集合稳定 → 哈希段不再扩容） |
| `f.vhex` | 单独 gsub 一遍 | 从 `f.hex` 切一刀 | 帧结构固定：载荷从第 4 字节起 = hex 串第 7 字符起 |
| hex 转换的闭包 | 每帧一张 | 0 | `gsub(".", hex_one)`，`hex_one` 提到模块级 |
| 调试环形缓冲 | 176 个 string.format/秒 | **0** | ring 全项目没有读者 → 改成 `W:RING=1` 显式打开 |
| `R:STAT` 应答 | 3471 B | ~1800 B | iot 状态原来被**编码两遍**（`iot` 段 + `mqtt` 段内容完全一样）→ 只编码一次拼两遍 |
| `R:FRAMES` 应答 | ~9 KB | ~3 KB | 帧表里的 `raw`(二进制)/`data` 丢掉 —— JSON 里 raw 会被转义成 `\u00xx`（6 字节/字符） |

现场换算：48 帧/秒 × 1.7 槽位/帧，**churn 从 ~110 KB/秒降到 ~12 KB/秒**。

#### 配套的三件小事

- **`census` 那一行一直是瞎的**：原来打 `collectgarbage("count") / 1024`，
  可 LuatOS 这个接口返回的就是 KB —— 于是每行都打成 `lua=0.2KB`，现场看着
  像"堆才用了 0.2KB"，白白误导了两轮排查。现在 `census` 和 `R:STAT` 用同一
  口径，并加了 `fps=`（帧率）/`push=`（点率）/`gc=`（保险丝触发次数）——
  **fps/push 一升高就说明分配量又上去了**。
- **堆水位保险丝**（`iot.lua` task_main，1 秒一轮，不在 UART 热路径上）：
  水位 > **200KB**（`collectgarbage("count")`，换算成池用量约 266KB ≈ 87%）
  就 `collectgarbage("collect")` 一次，最多 10 秒一次。
  ⚠️ 12-fix-8 修正：原来阈值是 240KB，量的是 count 不是池用量，**比失效点
  还高 → 一次都没触发过**，垃圾堆到池 98.6% 直接把设备送进重启。
  另外**收完垃圾不会合并相邻空闲块**，所以它保的是「池的总用量别飘上去」，
  不是「腾出一块连续大内存」。
- **`W:RING=1` / `R:RING`**：环形调试缓冲改成显式打开（默认全关）。

#### 还欠着的账（下一步）

**276KB 的代码 vs 300KB 的堆**，这是本轮 OOM 的根因，12-fix-5 只是把
"运行期 churn"压下来了，**代码体积一分没少**。候选（都需要用户拍板）：

1. `bus/poll.lua`(21.6KB) 只有 poll/platform 档用得上 → 改成**按需 require**
   （sniff 档不加载）。`bus/mon.lua`(33.1KB) 同理，只有 sniff 档用。
2. `iot/iot.lua`(73.1KB) 拆成"必载"和"按需"两半。
3. `cfg.lua`(13.5KB) / `lbsLoc2.lua`(8.2KB) 能不能不常驻。

⚠️ 改 `require` 的加载时机要留意 LuatOS 的 `require` 是**运行时读 FS**，
而且 `dep_graph.py` 的依赖图是静态扫的 —— 改成懒加载后要重跑依赖检查。


### 第三次现场复盘：U4 停发（2026-10-28，12-fix-7）

现场版本 12-fix-5（`e284035`）跑约 41 分钟后，**U4 主题
`/sys/thing/node/property/post/VL20261019001-1` 停止上报**，而 sniff 业务
没崩、没死机。日志长这样：

```
W/user.iot build_items failed, skip publish: iot.lua:302:
    not enough memory for buffer allocation
W/user.iot topo_sig failed, skip this round: iot.lua:525:
    not enough memory for buffer allocation
I/user.iot census lua=222.0KB points=77 frames=116411 aliases=77 rows=24
    pub=60/0 meta=21 topo=18 blk=2409 fps=52 push=86 gc=1
```

#### 行号对得上代码（这是定位的关键）

| 日志行号（老固件 `e284035`） | 代码 | 一次要多大连续块 |
|---|---|---|
| `iot.lua:302` | `"[" .. table.concat(77 个点) .. "]"` | **~6 KB** |
| `iot.lua:525` | 拓扑 props 的 `table.concat` | **~1.2 KB** |

⚠️ **关键判断：不是「包太大」，是「池子被切碎了」** —— 拓扑那条只要 1.2KB
也失败，说明当时连 1.2KB 的连续块都切不出来（300KB 的堆只剩 78KB，
但都是碎片）。另外 `mem=102432/203040` 是 `rtos.meminfo("sys")`
（**系统**内存池），跟 Lua 堆无关，别被它误导；Lua 堆的水位是
`census` 里的 `lua=`（`collectgarbage("count")`，LuatOS 返回的就是 KB）。

#### 本轮改了三件事

| 改动 | 位置 | 作用 |
|---|---|---|
| **B 降级分包** | `iot.lua` `build_items()` | 整包拼不出来时，按 25 个点（~2KB）拆开，**同一个 topic 分几条发**。正常路径一个字节不变（平台行为不变），只有整包分配失败才走分包 —— 「总发不出去」和「只发一半」当然选后者 |
| **C 大包前先回收** | `iot.lua` `reclaim_if_high()` | 拼大字符串**之前**看水位（`collectgarbage("count") > 200KB`）先 `collectgarbage("collect")` 一次。12-fix-5 那条保险丝阈值是 240KB —— **比失效点(222KB)还高，等于没设防**；这里定 200KB。⚠️ 完整回收有毫秒级停顿，所以只放在 iot 的发布/巡检路径上（不在 UART 收帧协程里），且只在超水位时做 |
| **D census 加计数** | `iot.lua` `census()` | 加 `bfail=`（大包拼不出来的次数）和 `rc=`（主动回收次数）。之前 `pub=60/0` **完全看不出 U4 已经不工作了** —— 失败走 pcall 跳过，不计入 `failed` |

#### A（砍 churn）实测无效 —— 别再拿它当理由

原计划把 `reg<addr>` 的拼串缓存起来（`collector.alias_of()`），理由是
「每帧每槽现拼一次 = 520 次/秒 ≈ 13KB/秒垃圾」。**实测是错的**：
Lua 的 `luaV_concat` 对 ≤256 字节的结果**走栈缓冲，不分配堆**，
`test_churn.lua` 里 `pick_dtype` 改前 29.5 字节/次、改后 29.9 字节/次，
纹丝不动。缓存保留下来只为「一个地址一个串对象」这条约定（省的是
intern 查表，CPU 级）。**教训：碎片化的账要拿 `test_churn.lua` 量，
不能凭感觉估。**

#### 还没解决的：常驻代码太大（= 12-fix-5 的「还欠着的账」）

本轮 B/C/D 都是**兜底**：真到碎片化那天靠它们把数据救回来。要根治，
得把常驻降下来 —— 现场 idle 基线就有 ~190KB 是代码，而 sniff 档用不到的
`bus/poll.lua`（21.6KB 源码）现在是**无条件加载**的
（`main.lua:98` / `bus/ctrl.lua:5` / `svc/cmd.lua:12`）。
`tests/lua/test_codesize.lua` 是量这个的诊断脚本。

### 第四次现场复盘：翻页就崩（2026-10-28，12-fix-8）

12-fix-7 那版烧上去之后，**没跑满一分钟就崩了** —— 不是 U4 停发，是设备
**重启**（`Lua VM exit!! reboot in 15000ms`）。现场说法是「我在设备那边翻页，
程序就崩了」。

崩溃时间线（18:27:34 进 sniff → 18:28:35 重启，只活了 61 秒）：

```
18:27:38.723 W/user.iot reclaim before big alloc: lua=214.4KB -> collected
18:27:38.768 W/user.iot topo_sig failed, skip this round: iot.lua:629:
             not enough memory for buffer allocation
18:27:41.461 D/user.cmd tx: RET:FAIL:handler error:cmd.lua:225:
             not enough memory for buffer allocation
18:27:43.855 E/mem memory allocation failed total 307192, used 290368, alloc 6088
18:27:43.856 D/user.cmd tx: RET:INFER_PUSH={}
18:28:35.367 E/mem memory allocation failed total 307192, used 302880, alloc 320
18:28:35.383 E/user.coroutine.resume not enough memory
             stack traceback: iot.lua:1898: in function <iot.lua:1846>
18:28:35.886 E/main Lua VM exit!! reboot in 15000ms
```

现场表现对应关系：**前端 R:STAT / R:INFER 全部失败**（`RET:FAIL:handler
error:not enough memory`）→ 界面看着像死了；最后 VM 退出 → 设备重启。

#### 根因不是「内存不够」，是三层叠加

**第一层：水位保险丝量错了对象（这是主因）**

12-fix-5 那条保险丝（`iot.lua` task_main 里）是：

```lua
local kb = collectgarbage("count")
if kb > 240 then collectgarbage("collect") end
```

它量的是 `collectgarbage("count")`（Lua 自己记的字节数），**不是 Lua 堆池
的真实用量**。现场两个数放一起看就明白了：

| 口径 | 现场值 | 说明 |
|---|---|---|
| `E/mem ... total 307192, used 290368` | **283.6 KB** | Lua 堆池**真实**用量 |
| `census lua=213.7KB` | 213.7 KB | `collectgarbage("count")`，**不含**每对象开销 |
| 差值 | **~70 KB** | 每个活跃对象的 GC 头 + 池块头（现场约 1900 个对象，一个 ~40B），再加碎片 |

所以 count 停在 **213.7 < 240** → **保险丝一次都没触发**（现场 census
`gc=0` 就是证据）→ 垃圾一路堆到池 **98.6%**（302880/307192）→ 连协程栈都
分配不出来 → `E/user.coroutine.resume not enough memory` → **VM exit 重启**。

换算：池用量 ≈ count × 1.33。阈值定 200KB（count）≈ 池 266KB ≈ 87%。

**第二层：常驻太大（idle 基线就 186KB）**

heap 才 307192 字节，idle 基线的 count 就 186KB —— 绝大部分是**代码**。
而 sniff 档用不到的 `bus/poll`（~14KB 堆）和 `iot/pullcfg`（~7.5KB 堆）
是**无条件加载**的。

**第三层：GC 不合并相邻空闲块 → 救不了大块**

现场日志直接证伪了 12-fix-7 的 C 方案：

```
18:27:38.723 reclaim before big alloc: lua=214.4KB -> collected
18:27:38.768 topo_sig failed ... not enough memory     ← 45ms 后照样失败
```

LuatOS 的分配器不合并相邻空闲块（`iot.lua` 里的老注释早就写明了），
GC 只是把垃圾块还回池子，**拼不出 6.4KB 的连续块**。所以 C 的定位要改成
「让中等大小的分配有货可拿」，不是「腾大块」。

#### 本轮改了五件事

| 改动 | 位置 | 作用 |
|---|---|---|
| **保险丝阈值 240 → 200** | `iot.lua` task_main | 终于能在池用满之前触发（`gc=0` → `gc>0`）。阈值换算过：count × 1.33 ≈ 池用量 |
| **`bus/poll` 惰性 require** | `main.lua` / `bus/ctrl.lua` / `svc/cmd.lua` | sniff 档不加载轮询引擎，**省约 14KB 常驻**。判据：poll 没被加载 ⇒ 它一定没在跑（只有 ctrl/cmd 会起它，而起它之前必然先加载） |
| **`iot/pullcfg` 惰性 require** | `iot.lua` `get_pullcfg()` | sniff 档平台根本不下发配置（`pullcfg done sniff 模式平台不下发配置`），这模块一次都用不到，**省约 7.5KB** |
| **R:STAT 去掉重复的 `iot` 段** | `svc/cmd.lua` | `iot` 段和 `mqtt` 段本来就是同一份表（现场实测逐字节一样），前端只读 `mqtt` 段。**每次应答少 1.5KB 连续内存**（每 5 秒一次） |
| **收帧 / 上报协程加 pcall 兜底** | `bus/mon.lua` task()、`iot.lua` `M.start()` | 分配失败时丢一帧 / 丢一轮上报，**不再连累整个 VM**（原来未捕获 → 协程死 → VM exit → 重启） |

另外把 `dep_graph.py` 的 require 正则补上逗号（`pcall(require, "x")` 这种
惰性写法老正则会漏掉，依赖图少画边就检测不出循环），并让**惰性边不参与
加载期循环检测**（12-fix-8 之后 `bus/ctrl ↔ bus/poll` 就是这种关系：ctrl
惰性拉 poll，poll 顶层 require ctrl，谁先被加载都安全）。

#### 怎么验证这轮修对了

- `tests/lua/test_codesize.lua` 新增**启动路径断言**：模拟器里加载一遍
  启动路径（14 个模块）后，`ctrl.poll_loaded()` / `cmd.poll_loaded()` /
  `iot.pullcfg_loaded()` 必须全是 false。模拟器里 `package.loaded` 不存在，
  所以由模块自己报。
- 现场：
  - `census lua=` 应从 213KB 降到 **190KB 上下**（少 20KB 常驻）；
  - `gc=`（保险丝触发次数）**偶尔**会 >0 —— 瘦身后的稳态 count 约 194KB，
    垃圾攒到 200KB 就收一次。**如果 `gc=0` 且 `lua=` 明显 >200KB，说明水位
    又上去了**；
  - `aerr=`（因堆分配失败丢帧的次数）应保持 0 —— 不为 0 就说明堆还在吃紧；
  - 前端 R:STAT / R:INFER 不再 `RET:FAIL:handler error:not enough memory`；
  - 跑满 10 分钟不重启。

#### 还没解决的（下一轮的账）

- 常驻还是大：`iot/iot.lua` 本身在设备上就占约 **75KB**（堆的 1/4），
  `bus/mon` 约 27KB，`svc/cmd` 约 23KB。想再往下压，只能拆模块。
- 拓扑 props 一条就是 6.4KB 连续内存。池里得真有这么大一块才行 ——
  常驻降下来之后才有可能，别在碎片池里硬拼。
- `collectgarbage("count")` 与池真实用量之间那 30% 的差，是**每个对象的
  开销**（GC 头 + 池块头），不是垃圾，也不是能回收的碎片。它只能靠
  「少造对象」来降，GC 帮不上。


## 485 无响应排查（现场顺序）

日志出现 `round N 无有效响应 timeout=X` 时，按序执行：

1. **`W:RAWTEST`**（最重要，一步定位）
   - `tx_ok=false` → uart.write 失败，查 UART1 是否被占用/波特率非法
   - `rx_len=0` → 模块发了但总线上**没有任何回字节**：
     从机是否上电、A/B 是否接反、从机地址是否真的是配置值、
     波特率/校验位/停止位是否与从机一致（很多从机默认 **8E1** 而非 8N1）
   - `rx_len>0` 但 `parsed=false` → 有字节但 CRC 不过：**波特率/校验位/停止位**不匹配
     （9600 8N1 采到 8E1 的数据会整帧错乱），或 A/B 线序反
   - `parsed=true` → 物理层通了，问题在配置（地址/count/dtype）
2. **`R:CFG`** 核对 `slave/baud/databits/stopbits/parity/regs`
3. **`W:CFG={...}`** 修改后，若改了 baud/parity/slave 会自动重启轮询任务
4. `parsed=true` 但 `R:VAL` 取不到值 → 查 name/alias 是否填错、count 是否为类型宽度整数倍
5. DE/RE 接 GPIO8，**高=发送、低=接收**；`W:RAWTEST` 会自动拉高/拉低

协议层已用标准 Modbus 校验值复核：读 slave=1 addr=14 qty=1 的请求帧为
`01 03 00 0e 00 01 e5 c9`，合法响应形如 `01 03 02 00 64 b9 af`（值 100）。

## MQTT 连不上排查

**先看这一行**——每次建连前都会把 CONNECT 的关键参数打全：

```
I/user.iot connect: host=dz.voltkun.com port=1883 ssl=false clientId=11802026092600016_ user=11802026092600016 clean=true
```

B 模型下 `clientId` = **SN 加一个下划线**、`user` = **裸 SN**。
若 `user=(无)` 说明代码没兜底，被拒时先看这一行确认到底发了什么。

### CONACK 返回码

日志出现 `W/mqtt CONACK 0x05` 时，固件随后打 `W/user.iot error conack`，
前端显示「平台拒绝连接(CONACK 0x05 未授权)」。

| 码 | 含义 | 处理 |
|---|---|---|
| `0x01` | 协议版本不接受 | 平台只支持 MQTT 3.1 或 5.0 |
| `0x02` | clientId 被拒 | 平台对 clientId 有格式要求 |
| `0x03` | 服务不可用 | 平台限流/维护 |
| `0x04` | 用户名或密码错 | 补 `user`/`pass` |
| `0x05` | **未授权** | 见下 |

### 0x05 未授权的排查顺序

本平台（`dz.voltkun.com`）走 **B 模型鉴权：按 username 查凭证表 + 明文比对密码**。

| 字段 | 取值 | 你这台设备 |
|---|---|---|
| `clientId` | 设备 SN + 下划线（留空时自动拼） | `11802026092600016_` |
| `username` | 设备 SN（凭证页「MQTT用户名」填的就是裸 SN） | `11802026092600016` |
| `password` | 平台签发的凭证密码，默认 `VKBOXGW2026KEY`（`mqttcfg.default.pass`） | 同左 |

平台签发的凭证就是 `SN_` 这个形状 —— **下划线后面是空的，不带 ProductId**。
`&12&1`、`_12` 之类的后缀都不要自己拼，产品不同那段就不同。

设备侧两个值都不写死 SN：`client_id`/`user` 留空时由 `try_connect` 兜底
（`default_client_id()` 拼 `SN_`，username 直接用 SN），换一台烧了别的 SN
的设备自动跟着变。

> **`S&<SN>&12&1` 那套已废弃。** 那是平台 4 段设备格式的 clientId，
> 用户名得配 `gw_{sn}`，且 `&12&1` 不是固定值（平台侧按产品/用户动态签发）。
> 拼死只会对不上，现已改为 B 模型。若要用回别的格式，
> 去「MQTT配置」页把 **ClientID** 填成平台给的值即可（优先于兜底）。

排查顺序：

1. **password**：两档各一份。自动档改 `mqttcfg.default.auto.pass` 或在前端
   首页「MQTT凭证密码」填；手动档在「MQTT配置」页「密码」填。
   两份互不影响，改一个不会冲掉另一个。
2. **设备是否已注册**：平台按 username（=SN）查凭证表，
   凭证状态必须是「生效中」且未过期。新烧的 SN 若平台侧没录，一样 0x05。
3. **clientId/username 是否被手填过**：若前端填过固定值，
   换 SN 后不会自动跟着变，需要清空恢复兜底。

> **证书模式已取消。** VKBox 早期文档描述过"出厂预置 TLS 证书、双向校验、
> 8883 端口"，但本平台实际发放的是账号密码凭证（`dz.voltkun.com:8883`
> 实测不对公网开放），故不做 `W:CERT=`，`ssl` 恒为 `false`。

### 连不上服务器（根本没发出 CONNECT）

日志出现 `dns_run ... no ipv6, no ipv4` + `W/user.iot error connect` 时，
域名解析就没过，跟平台、账号都无关，`last_err` 里那句 `conack timeout` 只是
`try_connect` 等满 15s 的兜底，别照着它去补账号密码。前端此时显示的是
`连不上服务器(connect): 域名解析不到或端口不通, 核对 host 拼写`。

**域名写错一个字母就是这个现象**，而两个字母写颠过去肉眼根本看不出来：

| 写法 | 结果 |
|---|---|
| `dz.voltkun.com` | 正确 |
| `dz.volktun.com` | 第 6/7 位 `t`/`k` 颠倒，长度一样，`no ipv6, no ipv4` |

`W:MQTT` 只校验非空和长度 ≤128，这种"形如合法域名"的错字校验拦不住。
判断方法：`R:MQTT` 看 `cfg.host` 是不是平台给的原样，尤其逐字符比对
`voltkun` 这类品牌名；同网段用电脑 `nslookup dz.voltkun.com` 对一下，
解析不出就是域名本身不对。

### 两个实现细节

- **`auth()` 的空串必须传 `nil`**。LuatOS 只判指针非空就当"有用户名"，
  会把零长用户名字段塞进 CONNECT 包，部分平台据此判未授权回 0x05。
- **`reject_reason` 独立于 `last_err`**。`try_connect` 等满 15s 后会把
  `last_err` 覆盖成 `conack timeout`，拒绝原因就丢了，所以单独记一个字段，
  前端优先显示它。error 事件里 `conack` 表示"连上了被平台拒"，
  其余值（`connect` 等）表示"根本没连上"，两者文案不同，别混。

## 485 轮询日志（poll_reg）

每笔事务固定两行，直接在日志里核对地址/长度/别称/数据：

```
I/user.poll Tx s1 fc3 addr=14 len=1 CT
I/user.poll Rx s1 addr=14 len=1 CT hex=00ea val=234
```

| 行 | 字段 | 含义 |
|---|---|---|
| Tx | `s1` | 从机地址 |
| | `fc3` | 功能码（读保持寄存器） |
| | `addr=14` | 起始寄存器地址 |
| | `len=1` | 连续读几个寄存器 |
| | `CT` | 别称（alias，未配则用 name，再退 `r<addr>`） |
| Rx | `hex=00ea` | 原始字节（小写十六进制） |
| | `val=234` | 按 dtype 解出的值 |

失败时的三种日志：`Rx timeout addr=14 CT rx=00ea39cb`（收到字节但组不成帧）、
`Rx timeout ... rx=-`（一个字节都没收到）、`Rx err fc=83 code=2 ...`（从机返异常码）。

> ⚠️ `poll.lua` 的 `hexspaced()` **必须定义在 `on_receive()` 之前**（11-fix,
> 2026-10-27）。`on_receive` 的 `respFlag=false` 分支要用它，而 `local function`
> 是词法作用域，定义在后面的 local 对前面的代码**不可见** —— 那条分支里的
> `hexspaced` 会解析成全局 nil，一旦走到就是
> `attempt to call a nil value`，把 7-fix/8-fix 最关键的那条诊断日志
> （收到的原始字节）连同整个 `on_receive` 回调一起掀掉。
> `check_lua.py` 的前向引用规则能抓到这个问题，别把定义挪回去。

## 平台配置拉取（W:PULLCFG）

前端点「拉取配置」→ 设备与平台握手拿配置 → **解析成功即自动落盘、生效、回执平台**，
不需要人在前端点「保存配置」确认。

**前提只需配好 MQTT 服务器地址和端口**，不要求 MQTT 已连上：设备会自己先去连
（`PULL_CONNECT_MS=20s`），连上再发 hello。这是新设备首次使用的正常顺序——
先配 MQTT，再拉配置。

### 时序

```
前端  ──W:PULLCFG──────────▶  设备  立即回 RET:PULLCFG=started
前端  ──R:PULLCFG(每1s)────▶  设备  回 {state, msg}

设备  ① 未连 MQTT? 先自己连(最多 20s)      state=connecting
      ② publish hello                      state=helloing
      ③ 等平台下发(15s 超时)                state=waiting
       ④ 解析 → auto_apply 落盘生效 → 回执    state=done / fail

平台  ──publish────────────────▶  设备  /sys/thing/gw/config/get/{SN}  （连上即订阅）

前端  回填 485 表单 + 寄存器表 + MQTT 可编辑的发布/订阅 2 个 topic 输入框，
       并强制关掉「手动配置」——topic 换成平台给的那套成品设备  auto_apply 落盘生效 → iot.reply_config()（都不需要用户操作）
设备  ──publish────────────────▶  平台  /sys/thing/gw/config/reply/{SN}
       {"msgId":<下发原值>,"code":200,"status":"ok","appliedTs":<now>}
（「重连」按钮单独发 W:MQTTRC，只重连不动配置）
```

### 平台 V3 数据面四条上行（U2 / U3 / U5 / U7）

U4（数据上报）见上面 topic 表。这几条与订阅无关，都是 `publish`：

| 编号 | topic | 时机 | 内容 |
|---|---|---|---|
| U3 | `/sys/thing/gw/property/post/{sn}` | 与 U4 同节奏（`interval_s`） | `ram_percent`（`rtos.meminfo("sys")`）、`uptime_sec`（`os.clock()`）、`cpu_percent`（主循环忙碌占比，**非 MCU CPU 占用率**，LuatOS 无 OS 级 CPU 接口） |
| U7 | `/sys/thing/gw/function/post/{targetSN}` | 每次 D2/D3 下行执行后 | `[{"id":<下发 id>,"value":<值或 null>}]`。粒度只到**入队/拒绝**：`poll.enqueue_write` 是异步的，汇总 `write_status()` 分不出是哪一条，所以 `value` 非 null **不等于已写到总线** |
| U5 | `/sys/thing/gw/event/post/{sn}` | **事件触发，与周期无关** | `resource_alarm`：ram/cpu/disk 越限。**上升沿触发**（越限瞬间发一次，持续越限不刷屏；回落后再越限才再发）+ **30 秒节流**防阈值附近抖动（`send_event` / `check_event_threshold`，阈值表 `EVENT_THRESHOLD`：ram=85、cpu=90、disk=90，disk 取不到时不参与） |

**U2 是双重用途的**（`iot.lua` 的 `send_meta` / `send_topo`），靠 body 里有没有
`nodes[]` 区分语义，所以拆成**两帧**各发一次（合成一帧平台拿不准该干嘛）：

| 帧 | body | 平台行为 | 时机 |
|---|---|---|---|
| 元数据帧 | 不带 `nodes[]`：`sn`/`deviceSn`/`imei`/`iccid`/`fw`/`firmwareVersion`/`hw`/`capabilities`/`deviceName`/`serialNumber`/`csq`/`netRegister`/`networkAddress`/`isShadow`/`summary`（固定 `"VKBoxLite Bootstrap"`）/`ts`；LBS 定位成功再加 `latitude`/`longitude`（`locationWay` 同步 2） | 只更新网关属性，**不重建模型** | 元数据指纹（imei/iccid/csq/host/LBS）变化即发；**另带 `interval_s` 兜底**（指纹长期不变也按周期重发一次，与 U3/U4 共享节奏）。`deviceName` 按档分流：manual/platform 留空串（用户决策 2026-10-16），sniff 用 `"VKBox-{sn}"` |
| 拓扑帧 | 带 `nodes[]`：`sn`/`deviceSn`/`ts`/`nodes[]` | 建子设备 + 绑定 + 物模型 | 拓扑签名变化即发，**且 detect 未跑完不发**（否则 baud 是上一轮的默认值，平台按错波特率建一次模型还得再重建） |

拓扑帧**不做定时兜底**：实测（2026-10-08）留着 60s 兜底重发会形成
"我们发拓扑 → 平台推配置 → 我们再发拓扑"的闭环，每 60s 一轮；而且兜底路径不打日志，
现象是"sniff 档平台不断下发模型配置"，难查。元数据帧的兜底是 `interval_s`
（指纹没变也定期重报，防止档案一直收不到最新一次），两者口径不同。

`firmwareVersion` 是纯数字（`1.0.0` → `10000`）= major\*10000 + minor\*100 + patch：
平台侧该字段是 BigDecimal，传字符串会**整帧被丢**。`ts` 用秒，毫秒会让平台按 1970 年解析。

**U2 拓扑的两个来源保真度不同**（`iot.lua` 的 `build_nodes`）：

| 模式 | 来源 | id / name / dtype |
|---|---|---|
| poll / pollpull | `active_cfg()` 平台下发的正经配置 | 全是真的（`name`/`alias`/`dtype`） |
| sniff | `mon.infer()` ∪ `cfgstore.load_pull()`，按 `slave:addr` 合并，**平台配置覆盖推断** | 只有 slave/addr/count，id/name 按地址现造（`r<addr>`），dtype 默认 `uint16` |

**U5 / U5b 告警事件（`gw/event/post`）已实现**（2026-10）：`send_event` +
`check_event_threshold`（`iot.lua`），见上面 U5 行。判定挂在 `send_gw_res`
尾部 —— 只有周期任务真的发了 U3 才顺带判一次阈值；且受两级闸门：
`should_pub_platform`（idle/manual 不发）+ `pub_blocked`（识别扫描吃 CPU
会把忙碌占比推高，识别未成功期间一并挡掉，防误发一条 cpu 告警）。


> **保存与回执都发生在设备侧（`iot.auto_apply`），不经前端**：平台主动重推
> 走的是同一条路径，靠前端的话没开串口就永远不落地。三道安全边界：
>
> | 边界 | 作用 |
> |---|---|
> | `normalize_poll` 不过 | 整体拒绝、不落盘、不重启轮询，`skipped` 明细照旧带回 |
> | `interval_ms`/`timeout_ms` 取设备现值 | 平台怎么下发都不改轮询节奏（`pullcfg` 本来也不给这两个字段） |
> | 前后对比日志 | `pullcfg 自动保存并生效: 寄存器 3→3, slave 1→2, baud 9600→2400, msgId=...`，否则现场无法追溯配置何时被谁改过 |
>
> 串口参数变了才 `stop/apply/start` 重启轮询任务；只换寄存器表时 `apply_cfg` 热更
> 就够了，重启会硬断一次正在进行的 Modbus 事务。
> 落盘失败（flash 写不下等）按 **fail** 报，不假装成功——平台会继续重推，而设备
> 留旧配置，报 fail 比静默好排查；失败时**不回执 U6**。
> 只回一次（`pull.replied` 去重），同一 msgId 重复回执会让平台重复核销。
> 新一轮 `W:PULLCFG` 会重置 `msg_id`/`replied`。
>
> hello payload 带 6 个字段（V3 契约 U1）：`vendor`/`model`/`fwVersion`/`deviceId`
> 加 **`topicFormat:"v3"`** 与 **`onboardingMode`** 两个自述字段。
> 缺 `topicFormat` 平台可能按旧版格式猜下行 topic，导致指令全丢且无报错。
>
> **`onboardingMode` 按当前 485 档位如实报**（文档：`sniff`/`platform`/`manual`）：
>
> | 档位 | 上报值 | 平台行为 |
> |---|---|---|
> | `sniff` | `sniff` | 跳过"对本地自建设备无效的配置快照推送" |
> | `pollpull` | `platform` | 照常推 ConfigSnapshot（拉取档要的就是这个） |
> | `poll`（手配） | `platform`（借来的） | 见下 |
>
> **`poll` 手动档也发 hello，但借 `platform` 这个值**。文档只定义了 `sniff`
> 的行为（跳过快照推送），`manual` 的行为没写 —— 报一个未定义的值风险大于收益。
> 手动档本来就不发 `pull_start`、不等 `configSnapshot`，平台推了也由 `recv_push`
> 直接落盘，不会卡住任何流程，所以借 `platform` 是安全的。
>
> 曾按"manual 档不走 onboarding 链路"把手动档的 hello 整个删掉，实测发现平台侧
> 确实需要它：平台不预知这台设备，靠 hello + 后续的拓扑/数据帧 auto-provision
> 补建档案。没有 hello，平台那头完全看不到设备上线。已恢复。
>
> ⚠️ 这里改过三次。早期固定报 `platform`，理由是"报 sniff 平台会直接不搭理"；
> 拿到更精确的说明后确认：平台见 `sniff` 只是**跳过配置快照推送**，hello 本身照常
> 处理（建/更新网关设备、回写 fw/hw/ip）。固定 `platform` 的真实代价是 sniff 档
> 每次 hello/拓扑后都收到一份 193B 空壳快照，还要为它回执，否则平台每 1s 重推。
>
> `deviceId` 取 IMEI，取不到报 `"unknown"`（不报空串）。平台校验 `gateway_imei`，
> 不一致会拒 hello。
>
> **sniff 档发完 hello 直接判完成，不进 waiting**：既知平台不推，等一个
> `PULL_TIMEOUT_MS` 只会让前端显示"平台未下发配置(超时)"这种假故障。也不回 U6 ——
> 没收到 D1 就没有 msgId 可核销。
>
> **hello 的两个时机**（都在 `task_main` 已连接分支里判）：
>
> ① **连接后补发一次**（所有非 idle 档）。进模式那一刻 MQTT 往往还没连上
> （`set_manual` 刚触发断开重连），`ctrl` 里那次 hello 是静默失败的。判据是
> `hello_at == 0`（`reset_state` 里"这个连接还没发过"的语义）。`on_mqtt` 的
> conack 分支会把 `hello_at` 清零 —— `reset_state` 只在 `start()` 时跑，不断线
> 重连不清的话，重连后这个分支永远不成立，平台看到的是设备中途消失再回来而
> 没有任何 hello。
> ② **pollpull 档每 30min 重发**（`HELLO_RE_S`）。平台侧网关档案可能被重置/
> 白名单到期，设备侧无从得知，只靠上电那一次 hello 会**永久失联且没有任何报错**。
> 重发不走拉取状态机 —— 平台响应由 `recv_push` 直接落盘，不影响前端正在显示的
> 拉取结果，也不需要用户再点一次「拉取配置」。
>
> 时机②的三个前提都满足才发：`hello_at > 0`、当前是 pollpull 档、`pulling()` 为假
> （握手中不发，避免和正在等的应答打架）。sniff 档没有"未拿到配置"这个状态、
> 手动档不等快照，两档都**不做周期重发** —— 发了只会无意义地刷新档案。
>
> hello 发送失败按 **1s/3s/9s** 退避重发（`HELLO_BACKOFF_S`），3 次都不成才报
> `hello 发送失败`。不立即判死是因为失败多半是 `refresh_subs` 刚把 client 抽走，
> 下一轮就好了；也不无限重发，否则"平台连不上"会被藏起来。

> `W:PULLCFG` 处理器在 VUART 回调上下文，**不能 `sys.wait`**，所以握手跑在
> `iot.task_main` 协程里；指令只置状态并立即应答，前端轮询拿结果。
>
> `connecting` 态**只等不连**：实际建连由 `task_main` 的常规连接分支做，
> 避免两处同时 `try_connect` 建出两个 client 互相覆盖。`pull_start` 里对未连上的
> 情况调 `M.kick()` 打断退避等待，让重连立刻发生。
>
> 前端按总时长轮询 55s，覆盖 20s 连接 + 15s 等下发 + 余量。

### 平台主动重新下发（非前端拉取触发）

平台侧有「重新下发配置」按钮：一点就主动往 `/sys/thing/gw/config/get/{SN}` 再推一份
`configSnapshot`，**不等设备问**。这条路径原来会**静默丢弃**：
`handle_downlink` 一看拉取状态机不在 `waiting` 就往下按普通指令解析，而
`configSnapshot` 既没有 `cmd` 也没有 `items`/`value`/`values`/`val`/`data`，
走完所有分支什么都不发生——平台以为发了，设备什么都没干，且无任何日志。

现在按 `type(t.configSnapshot) == "table"` 认出它（这是 D1 快照的独有字段，
REPORT/WRITE/裸值都不带，不可能误判）：

```
handle_downlink
 ├─ pull 状态机 waiting ────────────▶ S.pull_payload = payload（原逻辑，供 pull_step 解析）
 ├─ configSnapshot 且握手中 ────────▶ S.pull_payload = payload（寄存，走到 waiting 立刻消费）
 ├─ configSnapshot 且未握手 ────────▶ recv_push(t)：解析 → 存进 S.pull 结果槽位
 │                                     state=done / src=push / seen=os.time()
 │                                     push_pending=true / push_n += 1
 ├─ parse 失败 ─────────────────────▶ push_err=原因 + warn 日志，不静默
 └─ 其余 ──────────────────────────▶ 按普通业务指令解析（REPORT/WRITE/写值，原逻辑）
```

**为什么不直接落盘、重启轮询**：落盘会把正在跑的 485 配置换掉，属于改设备行为，
必须有现场确认——与「点保存配置才回执 U6」是同一条原则。做法是把这份塞进
**拉取结果槽位**（`S.pull`）以 `done` 态呈现，前端 `R:PULLCFG` 直接用同一套
回填渲染，不必再加一条渲染路径。

**握手中到达的推送先寄存而不当 push 处理**：`recv_push` 会把 `S.pull.state`
改成 `done`，把握手掐断——用户点了「拉取配置」却拿到一份可能是旧的推送。
寄存后状态机走到 `waiting` 会立刻消费掉，反而省一次平台往返。

**横幅已从"待确认门控"改为"已自动保存的通知"**：黄底=已生效（附多久前落下），红底=解析或自动保存失败需介入。

**横幅数据为什么挂在 `R:STAT`**：`R:PULLCFG` 只在用户点「拉取配置」时才查，
等不到横幅。`M.status()` 的 `mqtt` 段因此多带四个字段，前端 5s 轮询
（`readHome`）就能发现：

| 字段 | 含义 |
|---|---|
| `push_pending` | true = 有平台推送待确认。横幅显示的开关 |
| `push_n` | 累计收到几份。新的一份覆盖旧的，前端据此解除「忽略」 |
| `push_seen` | 收到的 OS 时间，横幅显示"已等待 N 秒/分钟" |
| `push_err` | 解析失败原因，非空时横幅改成"解析失败" |

**横幅撤掉的时机**：用户点「知道了」，或 `push_n` 归零 /
保存并回执成功（`reply_config`）/ 平台不再推。回执失败（未连接）时不撤。

> 注意 `R:PULLCFG` 的返回也多了 `src`/`seen`/`push_pending`/`push_n`/`push_err`
> 五个字段，`src=="push"` 时前端把状态行措辞从"已拉取"换成"平台重新下发"。
> 字段增量都是附加，老前端忽略新键不会坏。

### topic

| 用途 | topic | 说明 |
|---|---|---|
| 上报（发布） | `/sys/thing/node/property/post/{sn}-{n}` | 数据面（U4）。`{n}` = 子设备序号，**从机地址升序**：一份轮询配置只有一个 slave 恒为 `-1`，sniff 档多从机才递增。`-{n}` 后缀不能省，缺了平台无法把数据归属到子设备、上报等于白发。**自动档固定平台常量**（`cfg.PLATFORM_PUB_TOPIC`）；**手动档可配**（`mqttcfg.pub_topic`） |
| 拓扑上报（发布） | `/sys/thing/gw/info/post/{sn}` | U2 建档，带 `nodes[]`。**固定平台常量**（`cfg.PLATFORM_INFO_TOPIC`），不可改 |
| 网关资源（发布） | `/sys/thing/gw/property/post/{sn}` | U3，`ram_percent`/`uptime_sec`/`cpu_percent`。**固定平台常量**（`cfg.PLATFORM_RES_TOPIC`），不可改 |
| 指令回执（发布） | `/sys/thing/gw/function/post/{targetSN}` | U7，D2/D3 执行后回 `[{id,value}]`，失败项 `value:null`。**固定平台常量**（`cfg.PLATFORM_FPOST_TOPIC`），不可改 |
| 订阅（下行） | `/sys/thing/gw/config/get/{sn}` | 主下行通道：平台配置下发 + 普通指令都走它。**固定平台常量**（`cfg.PLATFORM_GET_TOPIC`），不可改 |
| hello | `/sys/thing/gw/config/hello/{sn}` | 拉取握手，`{sn}` = 设备 SN。**固定平台常量**（`cfg.PLATFORM_HELLO_TOPIC`），不可改 |
| 服务调用（gw 级） | `/sys/thing/gw/service/invoke/{sn}` | 平台三类下行之一，conack 时订阅。**固定平台常量**（`cfg.PLATFORM_FUNC_TOPIC`）。旧名 `/gw/function/get/{sn}`，2026-10 改 |
| 服务调用（node 级） | `/sys/thing/node/service/invoke/{sn}-N` | 子设备级服务调用。`N` = 子设备序号（与上报 `{sn}-{n}` 同一序列），按档案从机精确订阅（当前单从机恒 `-1`）。**broker 拒绝 `{sn}-+` 通配**，见 `iot.node_invoke_topics`。固定平台常量（`cfg.PLATFORM_FUNC_NODE_TOPIC`） |
| 属性设置 | `/sys/thing/gw/property/set/{sn}` | 同上（`cfg.PLATFORM_PSET_TOPIC`） |
| 属性查询 | `/sys/thing/gw/property/get/{sn}` | 同上（`cfg.PLATFORM_PGET_TOPIC`） |
| 配置下发 | `/sys/thing/gw/config/get/{SN}` | conack 时与下行 topic 一起订阅 |
| 上报（平台） | `/sys/thing/node/property/post/{SN}-1` | 拉取结果里回给前端展示，当前不订阅 |
| 下行命令（平台） | `/sys/thing/gw/service/invoke/{SN}`（gw 级）+ `/sys/thing/node/service/invoke/{SN}-N`（node 级） | 拉取结果里回给前端展示，node 级按档案从机精确订阅 |

> **除发布/订阅两条外，全部是固定平台常量，一条都不可从前端改。**
> 平台文档明确这些 topic **三路同**（sniff / platform / manual 三个档位完全一样），
> 所以没有"按档位配不同 topic"的需求。
>
> **发布/订阅两条是手动档专属，可以配**。手动档连的是用户自己的 broker、用
> 自己的 topic 命名（实例：`/12/{sn}/property/post`、`/12/{sn}/function/get`），
> 设备固定拼出来的 `/sys/thing/...` 那头没人接收。曾按"三路同"把这两条删过
> 一次，结果手动档的用户配不出自己的 topic，属于误伤 —— 已恢复。
>
> 自动档不读这两个键：`profile()` 在 `manual_on=false` 时直接返回
> `PLATFORM_PUB_TOPIC` / `PLATFORM_GET_TOPIC` 常量，`M.default` 里的
> `pub_topic`/`sub_topic` 只是给手动档的空值兜底（与常量同形）。
>
> ⚠️ 曾踩过的坑：用户把发布/订阅两条**填反**（pub 填成 function/get、
> sub 填成 property/post），数据发去了文档外的 topic，平台按 `/sys/thing/...`
> 收，**两边谁都不知道，没有任何报错**，症状只是"平台收不到数据"。
> `publish()` 还会拼 `-{n}` 后缀，实际发的是用户填的 topic 加 `-1`。
> 界面上现在用「发布Topic」/「订阅Topic」两个明确标签 + 占位符提示默认模板。
>
> #### `mqtt_cfg` 的字段分档
>
> | 分组 | 字段 | 说明 |
> |---|---|---|
> | 共用 | `host` `port` `ssl` `client_id` `interval_s` `qos` `keep_session` | 自动档和手动档建连都读这份 |
> | 手动档 | `user` `pass` `pub_topic` `sub_topic` | 只有 `manual_on` 为真时才用。置假时 `normalize` 会把它们清空 |
> | 自动档 | `auto.pass` | 首页「MQTT凭证密码」。`profile()` 里用户名固定留空 → `try_connect` 兜底填 SN |
> | 开关 | `manual_on` | 当前档位。`W:MQTT` 下发；`R:MQTT` 的 `manual_on` / `auto_pass` 给前端回显 |
>
> 前端两页分别写不同键：首页「MQTT 服务器」写 `auto_pass`（+ 共用的地址/端口/ClientID），
> 「MQTT配置」页写 `user`/`pass`/`pub_topic`/`sub_topic` + `manual_on`。
> **两个密码必须分成两个键**，否则前端无法表达"这次改的是哪一档"，改一个就会把另一个冲掉。
> `mqtt_cfg` 落盘上限 **2048**（host 128 + clientId 128 + 两段密码 + 两条 topic）。
> 缺字段的键用设备默认值补，所以老固件/老配置（不带 topic 键）也能正常加载。

> 业务订阅与「配置下发」topic 同形（都是 `config/get`），所以 conack 时只会订到一条，
> 且下行分流只在拉取状态机 `waiting` 时才把该 topic 的报文当配置包收，其余按普通指令解析。
>
> **例外：平台主动重推**。同一条 `config/get` topic 上，用户没点拉取时平台也能主动推
> `configSnapshot`（「重新下发配置」按钮）。此时不按 `configSnapshot` 字段识别就会
> 静默丢弃，所以分流条件不止看 `waiting`——见上方「平台主动重新下发」。

#### conack 时的订阅清单（`iot.build_subs()`）

**除 idle 外三档都订那 4 条 gw 平台前缀**（文档"下行 topic 三路同"），
**手动档再多订一条自己填的 `sub_topic`**：

| 档位 | 订几条 | 清单 |
|---|---|---|
| idle | 0 条 | 什么都不订 |
| poll（手配） | **5 + 1** | 5 条平台前缀（4 条 gw + 1 条 node）+ `mqttcfg.sub_topic`（`{sn}` 已代入） |
| pollpull / sniff | **5 条** | `config/get` + `service/invoke`（gw 级）+ `service/invoke/{sn}-1`（node 级）+ `property/set` + `property/get` |

平台下发恒用 **gw 前缀**（`node` 前缀是子设备上行专用，不能混），末段是目标裸 SN：

| topic | 用途 |
|---|---|
| `/sys/thing/gw/config/get/{SN}` | **无条件订阅**。拉取链路 + 普通指令都走它 |
| `/sys/thing/gw/service/invoke/{SN}` | 服务调用（gw 级），固定平台常量（`cfg.PLATFORM_FUNC_TOPIC`） |
| `/sys/thing/node/service/invoke/{SN}-1` | 子设备级服务调用（node 级），按档案从机逐条精确订，多从机则 `-1..-K`（`cfg.PLATFORM_FUNC_NODE_TOPIC`） |
| `/sys/thing/gw/property/set/{SN}` | 属性设置，固定平台常量（`cfg.PLATFORM_PSET_TOPIC`） |
| `/sys/thing/gw/property/get/{SN}` | 属性查询，固定平台常量（`cfg.PLATFORM_PGET_TOPIC`） |

那 5 条**是固定常量**，不读任何配置；手动档那条读 `mqttcfg.sub_topic`。
曾按 `manual_on` 分流（手动档只订用户填的那条），导致 sniff 沿用切入前那份清单：
从 idle 进 sniff 会是空的，从手动配置进 sniff 又少订 4 条平台 topic，平台下发到
设备全丢。三档统一后这条歧路没有了。

**手动档为什么还要订那 4 条 gw**：虽然手动档连的是用户自己的 broker、平台那套
`/sys/thing/gw/{SN}` 平时没人往那儿发，但**平台主动重推配置**走的正是
`config/get`。真机上验证过：手动档连上后平台自己推了一份 `configSnapshot` 到
`/sys/thing/gw/config/get/{SN}`，设备接住并自动落盘生效。不订这条 = 平台推的
东西静默丢掉。

去重逻辑不变：手动档那条与 `config/get` 同形时仍只订一次；自动档的 `sub` 与
`config/get` 天然同形，所以自动档实际就是 4 条。

清单全量回在 `R:MQTT` 的 `stat.subs`（数组），前端「连接与上报状态」的
**订阅Topic** 一栏显示。另外 `stat.pub` / `stat.sub` 是当前档次实际生效的
两条成品 topic（`{sn}` 已代入），前端在 **生效发布** / **生效订阅** 两栏显示。

#### SN 归属过滤（`iot.claim_ok()`）

同 broker 上多台网关时，别人网关的下行也会被 EMQX 送过来。`handle_downlink` 入口按
「topic 末段 == 本机 SN 或 `{gwSn}-{n}`」判定，不是自己的直接丢弃。一条例外：
非 `/sys/thing/` 命名空间（用户自配 topic）放行，
否则改了 `sub_topic` 会静默收不到指令。

### 字段提取（`lua/iot/pullcfg.lua`）

**commInterfaces → 串口参数**（取 `type=="mbRTUClient"` 且 `enable==true` 的那条）

| 平台字段 | 设备字段 | 转换 |
|---|---|---|
| `param.baudRate` | `baud` | 原值 |
| `param.dataBits` | `databits` | 仅接受 7/8 |
| `param.stopBits` | `stopbits` | 仅接受 1/2 |
| `param.parity` | `parity` | `none`→0、`even`→1、`odd`→2 |

**从机号 → `slave`**：`devices[0].addr`，字符串转数字，须在 1~247（文档示例
`"addr": "5"` 就是字符串）。

**⚠️ 空快照是正常终态，不是失败**。`devices`/`tsl.properties`/`commInterfaces`
三个数组**同时为空**（`mqttPlatform` 也全空）时，`parse_snap` 返回
`{empty=true}` 而不是报错。这正是 sniff 模式的预期行为：设备档案本地自建
（`source='sniff'`），平台互斥守卫不覆盖现场调通的配置，所以
`publishConfigSnapshot` 只回一个 193B 的空壳。

按成功收尾 + 回 U6（`message` = 那句话说清楚"平台未下发配置"）。不回执的代价是
平台每 1s 重推一次同一份空包 —— 2026-10-08 17:15 实测连推 5 次。

| 场景 | 平台会推什么 |
|---|---|
| sniff 模式 | **空快照**（本文所述） |
| platform 模式 + 平台侧已建档 | 带 `devices`/`properties` 的真配置 |
| platform 模式 + 平台侧还没建档 | 也是空快照，要在平台上建子设备/物模型 |

**所以：想在 sniff 档验证"平台拉配置 → 自动保存"，是验证不到的** ——
sniff 档的寄存器表本来就来自本地旁听推断。要验证拉取链路得切到 platform 档
（前端「拉取配置」按钮所在的档）。

**tsl.properties → 寄存器表**

| 平台字段 | 寄存器字段 | 说明 |
|---|---|---|
| `id` | `name` | 须匹配 `^%w+$` 且 ≤16 字符 |
| `name` | `alias` | 为空则退化为 `id` |
| `modbus.address` | `addr` | 0~65535 |
| `modbus.quantity` | `count` | **地址长度取这个字段**，1~125 |
| `modbus.dataType` | `dtype` | 见下方「dataType 拼法」 |
| `msgId` | `msg_id` | 不参与 485 配置，仅供 U6 回执原样回带；缺失记 `"unknown"` |

**dataType 拼法**：`modbus.dataType`（**不是**外层 `dataType`，外层是物模型口径）
有两套拼法在同时流通——doc 的 D1/U2 示例用 `uint16`/`float`，现网运维平台实测用
`ushort`/`long-ABCD`，所以两套都收。带字节序后缀时本框架只认 `-ABCD`，
`-CDAB/-BADC/-DCBA` 一律拒收（按错字节序解出来的值看起来合理但是错的，比报错更难查）。

| 平台写法 | 收成 | 来源 |
|---|---|---|
| `ushort` / `short` / `ulong` / `long` | uint16 / int16 / uint32 / int32 | 现网实测 |
| `uint16` / `float` | 同上 / float32 | doc D1、U2 示例 |
| `int16` / `uint32` / `int32` / `float32` / `float64` / `double` | 对应类型 | 常见写法补齐 |
| 以上任一带 `-ABCD` 后缀 | 按裸类型收 | 现网实测 `long-ABCD`→int32 |
| 带上其他字节序后缀 | **拒收** | `long-CDAB` 拒绝 |
| 空 / 其他 | **拒收** | 如外层误传的 `decimal` |

**`modbus.address` 的两种口径（未定，需平台确认）**：doc 的示例是 4xxxx 逻辑地址
（`40001`/`40003`），现网运维平台实测是 0-based PDU 地址（`14`/`15`/`16`）。
本框架**原样存**（`addr = num(mb.address)`），因为现网数据按 0-based 处理是对的，
一旦改成"≥40001 就减 40001"反而会把现网数据弄错。若平台哪天开始下发 `40001`
这种逻辑地址，设备会去读 40001 号寄存器读到错误的数据（地址合法、无报错，
最难查的一类问题）——需要平台侧明确口径，或在设备侧按 `type == 2` 判定后再减。
**这是目前唯一一个"只能在平台侧定"的口径分歧，也是要平台侧确认的首要问题。**

**丢弃**：`ts`、`mqttPlatform`（保持现有 broker）、`tslName`、
`devices[].name/protocol/comm`、`modbus.type`、`modbus.slave`、外层 `dataType`。

非法条目不整包失败：跳过并记入 `skipped`，前端提示"已忽略 N 条"。
**平台别名不可用**：平台若把中文 `name` 按 GBK 而非 UTF-8 下发，设备判为非法 UTF-8 并把
`alias` 退回 `id`，同时把该 id 记入 `renamed` 名单。前端据此提示"平台改 UTF-8"，否则用户
只会看见别名栏莫名其妙变成了 id。详见下方「平台中文名乱码」。
寄存器数超过 `MAX_REGS=128` 截断。`interval_ms`/`timeout_ms` 沿用设备当前值，不随平台变更。

### 日志（`I/iot`）

点「拉取配置」后 OS log 里依次出现：

```
I/iot: conack ok, subscribed=true, topics=[/sys/thing/gw/config/get/11802026092600016 /sys/thing/gw/service/invoke/11802026092600016 /sys/thing/node/service/invoke/11802026092600016-1 /sys/thing/gw/property/set/11802026092600016 /sys/thing/gw/property/get/11802026092600016]
I/iot: pullcfg hello topic=/sys/thing/gw/config/hello/11802026092600016 sn=11802026092600016 imei=86xxxxxxxxxxxxx body={"vendor":"VKBoxLite",...,"topicFormat":"v3","onboardingMode":"platform"}
I/iot: pullcfg recv topic=/sys/thing/gw/config/get/11802026092600016 len=812
I/pullcfg: alias 非 UTF-8(平台编码问题), 退回 id: Ua      ← 有平台中文名才出现
I/iot: pullcfg done 已自动保存生效
I/iot: pullcfg 自动保存并生效: 寄存器 3->3, slave 1->1, baud 9600->9600, msgId=hello-3f9a2b1c
I/iot: config/reply /sys/thing/gw/config/reply/11802026092600016 {"msgId":"hello-3f9a2b1c","code":200,"message":"config applied","status":"ok","appliedTs":1721884800}
```

`config/reply` 那行**紧跟在 `自动保存并生效` 之后由设备自发**（前端拉取与平台主动重推
都走这一条）。没出现就说明没落盘成功，平台会继续重推；此时 `state` 会是 `fail`
并带原因（`自动保存失败: 配置不合法: ...` / `落盘失败: ...`）。**不需要用户操作。**

平台主动重推的日志（`push recv`）：
```
I/iot: push recv msgId=hello-6e86d9f7 regs=3 skipped=0 (已自动保存)
```
后半段带 `(已自动保存)` = 这条路也落盘生效并回执了。

不是本机 SN 的下行会被丢掉，日志：

```
I/iot: downlink dropped, not ours: /sys/thing/gw/service/invoke/V239342435
```

**平台主动重新下发**（没点「拉取配置」时平台自己推一份）的日志：

```
I/iot: push recv msgId=hello-3eff79ec regs=3 skipped=0      ← 认出并解析成功，等用户保存
I/iot: push during handshake(helloing), parked len=850       ← 拉取握手中到达，先寄存
W/iot: push parse fail: tsl.properties 为空                  ← 认出是配置包但读不懂
```

`push recv` 出现后设备**立即**自动落盘、生效并回执 `config/reply`（与 `W:PULLCFG` 同一条 `auto_apply`），不需要用户在 GUI 操作；只有 `自动保存失败` 才需要介入。
前端此时会弹黄色横幅提示。

连不上 MQTT 时是 `pullcfg fail MQTT 连接失败: <原因>`（等 20s）。

topic 里的 `{SN}` 取的是**烧号的 SN**（`_G.get_device_sn()`），与 payload 里的
`deviceId`（IMEI）**不是同一个标识**。所有 topic 用的都是同一个 SN，对不上时先看这行日志确认。

### 平台中文名乱码（手动下发正常 / hello 触发乱码）

**现象**：MQTTX 同时抓到两份 `configSnapshot`，**除 `Ua.name` 外逐字节相同**——
连 `configSnapshot.ts` 都是同一个 `1790750323`、`msgId` 分别是 `hello-6e86d9f7`（平台
手动点「重新下发」）与 `hello-cf25cea8`（设备发 hello 触发）：

| 触发方式 | `Ua.name` | 底层字节 |
|---|---|---|
| 平台手动下发 | `电压` | `E7 94 B5 E5 8E 8B`（合法 UTF-8） |
| 设备发 hello | `??ѹ` | GBK `B5 E7 D1 B9` 被当 UTF-8 解 |

**结论：是编码不一致，但不在设备端，在平台的两条下发路径之间。** 同一份配置数据
（同一 `ts`、其余字段全同）被两条序列化路径发出：手动下发用 UTF-8，hello 触发用
GBK。这不是设备能影响的——设备发的 hello 是**纯 ASCII**
（`{"vendor":...,"model":...,"fwVersion":...,"deviceId":...,"topicFormat":"v3","onboardingMode":"platform"}`），
没有任何 charset 声明，两种触发下发的 hello 也是逐字节相同的。

字节级定位：「电压」GBK = `B5 E7 D1 B9`；按 UTF-8 解码，`B5`→`U+FFFD`、`E7`→`U+FFFD`，
而 `D1 B9` **恰好是合法的 2 字节 UTF-8 序列**→ `U+0479`（西里尔 `ѹ`，不是替代符）。
所以结果是 `U+FFFD U+FFFD U+0479`，渲染成 `??ѹ`——与 MQTTX、前端、本设备三方看到的
逐字符一致。MQTTX 是完全独立的客户端，它坏就证明字节在到达任何读取方之前就已经坏了。

**两种"看起来一样"的成因，报障时必须区分**（设备日志已输出判据）：

| 成因 | 平台发的字节 | 数据状态 | 平台该改哪里 |
|---|---|---|---|
| 序列化选错 charset | `B5 E7 D1 B9`（GBK 原样） | **未损** | 下发序列化统一 UTF-8 即彻底好 |
| 已做有损转码 | `EF BF BD EF BF BD D1 B9`（U+FFFD×2 + `ѹ`） | **已毁** | 从数据库源头修，序列化改了也没用 |

判据是字节里有没有 `EF BF BD`（U+FFFD 自身的 UTF-8 编码）。注意它是**合法** UTF-8，
所以纯按结构校验会漏过去、把 `??ѹ` 当正常中文收下——`utf8_ok()` 里专门加了这条拒绝。

**设备侧的对策**（`pullcfg.utf8_ok()` + `enc_note()`）：只做校验和归因，不做转码。
GBK→UTF-8 有 14346 个码位、朴素存法约 70KB，塞不进 300KB 的 Lua 堆。校验不过就把
`alias` 退回 `id`——至少不把坏字节当成 `name` 发回平台循环污染，也不在前端显示乱码。
真机日志形如：

```
I/pullcfg: alias 非 UTF-8(平台编码问题), 退回 id: Ua
I/pullcfg:   name 原始字节 B5 E7 D1 B9 (4B) 未见 EFBFBD(GBK 原样字节, 数据未损, 平台序列化改用 UTF-8 即可)
```

**要平台侧改的地方**（按优先级）：

1. **让 hello 触发的自动下发与手动下发走同一套 UTF-8 序列化。** 这是本次问题的直接
   结论：手动下发正常说明平台**有能力**发对，只是 hello 响应路径用了另一套（多半是
   响应设备请求时用了 GBK 默认 charset，或那条路直接读数据库原字节未转码）。
   `configSnapshot.tsl.properties[].name` 必须 UTF-8。
2. **明确 `modbus.address` 的口径**：doc 示例写 `40001`（逻辑地址），现网实测写
   `14`（0-based PDU）。设备现在原样存、按 PDU 用；如果平台要发 4xxxx，需要约定
   好减不减偏移，否则设备会"合法地"读到错的寄存器、不报任何错。
3. `modbus.dataType` 与 doc 的裸 `uint16`/`float` 不一致，实际发 `ushort`/`long-ABCD`
   （带字节序后缀）。设备已两套都收（`-ABCD` 与裸类型），但最好统一成 doc 的写法；
   另外请勿发 `-CDAB/-BADC/-DCBA`，设备会按"字节序不支持"拒收。

## 本地落盘（已移除）
按需求，poll 模式**不做本地保存**，采集数据只走两条路：

- `collector.dataCache` 内存最新值 → `R:VAL` 实时查询
- `on_update` → iot → MQTT 上行

已删除：`data/store.lua` 整个模块、`collector.on_store`、`main.lua` 里的挂接、
`R:DISK` / `W:STORE` 两条指令、`R:STAT` 的 store 段、`guard` 心跳里的 queue/saved 字段，
以及配置里的 `DATA_FILE` / `KEEP_ROUNDS` / `STORE_ENABLE` / `CHANGE_EPS` /
`FLUSH_MS` / `FLUSH_EVERY` / `FLUSH_BATCH` 和寄存器的 `eps` 字段。

## 与原版（v1）的差异

- 24 文件 → 16 文件；删除 fsinfo/bootreason 桩、identity 独立模块、logctl 独立模块、本地落盘模块
- mbus_common → mbus；cfg_store → cfg.lua；collector/data_store 移入 data/
- vcom → cmd，指令集按 `frontend/protocol.js` 全量对齐（cmd.lua 31 条 + SN 产线 8 条），
  恢复 v1 删掉的 TX/INFER/APPLYINFER/SNIFF/IOTSTAT，新增 W:RAWTEST 裸探针
- 应答结构按前端读取方式修正：R:MODE 返回状态对象而非裸字符串；R:CFG/R:SNIFFCFG 包
  `{cfg, src}`；R:MQTT 补 `stat`；R:INFO 补 server/baud/slave/regs 并修复
  mobile.iccid/csq 未调用导致 json.encode 失败返回 `{}` 的问题
- 配置字段名 `timeout` → `timeout_ms`（与前端 collectCfg 一致），范围 50~500，
  允许 null = 早返回模式
- **本地落盘功能已整体移除**（按需求，poll 模式不做本地保存）：删除 `data/store.lua`、
  `collector.on_store`、`R:DISK`/`W:STORE`、`R:STAT` 的 store 段、配置里的
  `DATA_FILE`/`KEEP_ROUNDS`/`STORE_ENABLE`/`CHANGE_EPS`/`FLUSH_*` 及寄存器的 `eps` 字段
- **存储空间功能已整体移除**：本固件 `rtos.fsinfo` 与 `fs` 库均不存在，
  前端首页"存储空间"栏、store.stats 的 `fs` 段、R:DISK 的探测字段全部删除
- 看门狗参数、MQTT 用法、启动顺序均对照官方文档核对修正
- 切帧统一为 CRC 试探法（每个候选长度都验 CRC，fc15/16 用 byte(7)=bc）；事务前 drain 清残帧（v1 只在失败后 drain）
- 配置校验与原工程对齐：串口参数范围 / MAX_REGS=128 / 标识符去重 / count%width
- **字节序/字序已整体移除**（按需求）：前端参数列表和添加寄存器弹窗的选择项删除，
  设备端 `normalize_reg` 的 `byteOrder`/`wordOrder` 字段、`mbus.parse_value/parse_regs` 的
  字节序参数、`swap_pairs` 辅助函数全部删除，解码固定走 Modbus 标准大端。
  老配置里残留的这两个字段会被 `normalize_reg` 忽略，不影响升级
- **W:CFG 保存失败已修**：`save_json` 上限 512 太小，5 个寄存器（含别名）就超限，
  一直回 `too large`，前端只看到"保存失败"。上限与 `prov.lua` 的 `MAX_BUF` 对齐到 16KB
  （`W:CFG` 是一整行命令，行超 `MAX_BUF` 会被整缓冲丢弃，存得下也传不过来）
