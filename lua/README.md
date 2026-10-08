# VKBox Lite 485 采集框架 v2

基于合宙 Air780EP（LuatOS）的 485 串口采集设备框架。对照官方 API 文档重构，代码精简、结构清晰。

## 功能

| 功能 | 模块 | 说明 |
|---|---|---|
| Q1 SN 烧录 | `sn/` | 三态状态机 + Luhn 校验 + fskv 持久化 + 产线指令通道 |
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
│   ├── sn.lua          SN 状态机 + Luhn + fskv 存储 + 身份
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

烧号: W:SN=xxx → prov → sn.write(锁检查/validate/Luhn) → fskv save + 回读
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
| R:INFO | 设备信息（SN/IMEI/ICCID/CSQ/RSRP/版本/项目/服务器/波特率/从机/寄存器数/锁状态） |
| R:MODE / W:MODE=idle\|poll\|pollpull\|sniff | 模式查询（返回 `{mode,busy,poll_src,pull_ready,pull,poll,mon,write}`）/ 切换。`pollpull` = 拉取配置档，进模式自动 hello 拉取 |
| R:CFG / W:CFG={json} | 轮询配置读写，读返回 `{cfg, src}`，src=default 表示 fskv 里没写过。`W:CFG` 是**唯一**写寄存器表的入口（regs 并进 cfg 一起发） |
| R:REG | 读寄存器表（= `R:CFG` 的 `cfg.regs`，因前端单独读它才留） |
| R:VAL | 实时值快照 |
| R:STAT | 运行状态汇总（mode/data/guard/mqtt）；`mqtt` 段另带 `push_pending`/`push_n`/`push_seen`/`push_err`（平台主动重推横幅用） |
| W:PULLCFG / R:PULLCFG | 平台配置拉取：W 发起（回 `started`），R 查状态（`{state,msg,poll,skipped,mqtt,msg_id,replied,src,seen,autosaved,autosave_at,autosave_regs,push_n,push_err}`，`mqtt` 段含 `pub`/`sub` 两个拼好的 topic；`autosaved`=解析成功即已落盘生效并自动回执；`msg_id`/`replied` 反映回执；`src`=`pull`/`push`）。平台主动重推的配置也走这个返回（`src=push`）。前提只需配好 MQTT 服务器地址和端口，设备会自己连 |
| W:RAWTEST[=slave,addr,qty] | 485 裸探针：发原始请求并回显所有原始回字节，用于区分“没发出去/从机没回”与“回了但参数不匹配” |
| R:MQTT / W:MQTT={json} | MQTT 配置读写，读返回 `{cfg,auto_pass,manual_on,pub,sub,ready,err,stat}`。`cfg`=手动档表单原值，`auto_pass`=首页凭证密码，`manual_on`=当前档位，`pub`/`sub`=当前档次实际生效的成品 topic |
| W:MQTTRC | 只重连不动配置（等价 `iot.kick()`：销毁 client 后 backoff 归 1 立刻重连） |
| R:REPORT | 立即上报 |
| R:NET / R:MEM | 网络/内存诊断 |
| W:GC | 强制 GC + 重连 |
| R:FRAMES[=n] | 旁听帧（n 取 1~50，默认 20） |
| R:INFER | 从旁听帧反推轮询表 `{regs:[{slave,addr,count,fc,hits}], slaves, stat}`（**只读参考**，不写任何配置） |
| R:AUTODETECT | 识别 sniff 通讯参数 `{baud,databits,stopbits,parity}`（**只用于本次会话**，不写 fskv）。**非阻塞**：回 `BUSY` / 参数 / `RET:FAIL:not in sniff mode`，由前端轮询 |
| R:SNIFF=ms | 静默侦听总线 ms 毫秒（100~30000），返回帧数 |
| W:TX=hex | 裸发一串字节（总线诊断），回显 rx_len/parsed/rx（识别中回 BUSY） |
| W:MODE=poll\|pollpull\|sniff\|idle | 切换 485 运行模式。`sniff` 会**自动起一轮识别**（非阻塞），立即回 OK；`pollpull` 会自动 hello 拉平台配置 |
| W:BOOTMODE=idle\|poll\|pollpull\|sniff | 开机默认模式（大小写不敏感）。`sniff` 同样自动识别，但不堵开机流程 |
| R:SN / R:ID / W:SN=xxx[,FORCE] / C:SN / LOCK:SN / UNLOCK:SN / R:SNEN / W:SNEN=n,0\|1[,P] | SN 产线指令（VUART_0 通道） |

> 指令集与 `frontend/protocol.js` 的 `Enc` 一一对应。`W:RAWTEST`/`R:NET`/`R:MEM`/`W:GC` 是前端不调用的现场诊断入口。
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
> **已删除的前端零调用指令**：`R:SNIFFCFG`/`W:SNIFFCFG`（前端无入口）、`R:IOTSTAT` 与 `R:POLL`（被 `R:STAT` 的 iot/mqtt 段和 data 段覆盖）、`W:RST`（前端各自有「恢复默认」按钮）、`W:REG`（被 `W:CFG` 覆盖：前端「保存配置」把 regs 并进 cfg 一起发，单独写寄存器表的指令从来没被调过）。连带删掉只服务它们的 `cfg.reset()`、`mqttcfg.reset()`、`collector.clear()`。
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

设计约束（改动前先读这里）：

- **sniff 没有持久槽，这是刻意的**。旁听识别出的串口参数只存本次会话
  （`mon.lua` 的 `bootCfg`），`cfg.lua` 里连可写的 `save_sniff` 都不留 —— 省下来的
  11 行死代码换来的是"误存 sniff 参数"从结构上不可能：没有写入口，改 `mon.lua`
  的人也无法顺手 `save` 一把。原先那个 `ds_sniff` 槽从未被任何代码或外部工具写入，
  `load_sniff()` 恒返回 `{9600,8,1,0}`，删掉后行为逐字节不变。
- **sniff 不持有寄存器表**。旁听是纯被动接收，解出的帧不代表"要采哪些点"。
  给 sniff 加 regs 是错的——那会让"旁听到什么"和"采集什么"耦合，改一侧污染另一侧。
  寄存器表的唯一来源是 `W:CFG` 与平台 `ds_pull`。
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
| poll（手动配置） | `poll` | `manual_on=true` | `ds_poll` | 用手配的寄存器表和 MQTT |
| poll（拉取配置） | `pollpull` | `manual_on=false` | `ds_pull` | 进入即自动 hello 拉平台配置 |
| 旁听 sniff | `sniff` | 无所谓 | 不用 | 只收不发 |
| 空闲 idle | `idle` | 不变 | 不用 | 不动总线 |

**模式、档位、配置槽三者绑定，没有混搭场景**：要么全手配（寄存器表 + MQTT），
要么全平台拉取。`ctrl.SLOT` 这张表就是这个映射，改任何一个都要三处同步。

⚠️ **`iot.set_manual(on)` 的 `on=true` 是手动档**。切换档位那一行写的是
`iot.set_manual(slot == "poll")` —— 写反的后果是手动档收不到自己的 topic、
拉取档订不上平台 topic，两个模式一起废，而且界面上看不出原因（MQTT 页只是
手动配置行集体消失）。改这行前后各读一遍 `set_manual` 的注释。

- **拉取档必须关掉手动档**。hello 的应答走 `config/get` 下行，而 `build_subs()` 在
  手动档**不订这条**（手动档接的是用户自己的 broker，平台那套 topic 订着也是噪音），
  所以 `ctrl` 进 `pollpull` 前先 `iot.set_manual(false)`。少了这步，hello 发出去
  必然等满 15s 超时——`iot.lua` 的 build_subs 注释里记着这个坑。
- **拉取档连的是平台那头**。`mqttcfg.normalize` 只在手动档写入时清 user/pass/topic，
  `host/port/ssl` 是两档共用字段。手动档用户可能填了自建 broker，带着那个地址发
  hello 没人应答，只会白等 35s 再报超时，所以 `set_manual(false)` 顺带把
  host/port/ssl 归位到默认值（`auto.pass` 会带过去，不让用户自己设的平台密码被重置）。
- **档位切换要断开重连**。`S.manual_on` 是在 `try_connect()` 里读的，订阅清单挂在
  conack 上，已连接的 client 不会自己重读。`set_manual()` 因此 `destroy_client()`
  + `kick()`，让 `task_main` 用新档位重连重建订阅。代价只是丢一次心跳周期，
  `collector` 的数据和寄存器表都不动。
- **平台推送只在拉取档生效**。`auto_apply()` 落 `ds_pull` 后，只有 `poll.slot()=="pull"`
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
  拉取档下一次保存就静默切档——`ctrl.get_mode()` 看的是 `poll.slot()`，
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
| `interval_s` `qos` `allow_no_sn` `keep_session` | 保留 | 共用字段，首页「保存」会一并带走，算"首页写入的内容" |
| `user` `pass` `pub_topic` `sub_topic` | 清空 | 手动档凭证与 topic，回落默认模板 |
| `manual_on` | 强制置 `false` | ⚠️ **必须和清值在同一个 `save()` 里完成**。`normalize` 在 `manual_on=true` 时**使用** user/pass/topic，只清值不换档的话设备会拿空凭证匿名连平台——表现是"切回 idle 后再没连上过 MQTT"，且前端 MQTT 页显示成手动档。拆成两次 save，中间任何一次失败都会把设备留在那个失联状态 |

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
| `W:CFG` / `W:TX` / `W:RAWTEST` | ❌ `RET:FAIL:<cmd>:BUSY:...` |
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

### 已修：识别失败后串口停在最后一个候选

`auto_detect()` 扫空一轮后调 `restore_params()` 把串口还原成进 sniff 时那套参数
（`bootCfg`）。不还原的话，失败后串口停在最后一个候选 **1200 8O1** 上，接下来
3s 等待期里到的真流量全成乱码，而下一轮又要从 9600 重新开始——中间那段窗口看着
像"总线时好时坏"，查不出原因。

### 已知调优点

`DETECT_WIN_MS`（`core/config.lua`）现为 **1000ms**，按 9600 排第一定的：8 字节
帧约 8ms，轮询周期内轻松攒够 2 帧。⚠️ **慢总线（1200/2400）+ 稀疏从机时，1 秒
可能只收到 0~1 帧而漏检**。真机测试若发现慢 baud 识别不出，优先把它调到 **2000**
（代价：最坏耗时 12s → 24s）。常见 8N1 场景不受影响，因为 9600 第一个就中。
⚠️ 但注意现在失败会重试，慢 baud 漏检的代价从"认不出"变成"多等几轮"，
比改窗口更温和——调它之前先看重试轮次够不够。

`DETECT_HITS` 同理：若现场噪声大、偶发单帧误命中，可提到 3。

`DETECT_RETRY_MS`（`bus/mon.lua` 顶部）现为 **3000ms**，是两轮识别之间的间隔。
静默总线下没必要高频重扫（白耗电 + 刷日志），3s 足够等到稀疏主机冒出流量。

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

两个容易漏的点：

- **`lastReqs` 曾是缺口**：键是 `"slave:qty"`，键空间上千万且只增不减。sniff 挂在
  异常总线上会单调增长，两千条左右就吃掉大半堆。现在 `push_req` 里封顶，超限整表
  作废——不逐条 FIFO 是因为 `guess_last_req` 本来只认 10 秒内的条目，丢掉的都是
  更旧的，配对结果不变，还省一份顺序数组。
- **`pendingReqs` 的有界是间接的**：能进 `push_req` 的 fc 只有 3/5/15（`parse_frame`
  是白名单 + 强制 CRC），所以实际 ≤ 12 条。改 `decode_frame` 的 kind 判断时必须复核。

**OOM 兜底**（`iot.lua` 建连失败且报 memory 时）：`collector.trim_cache()` +
`mon.trim_reqs()` + 强制 GC + 固定等 30s。`mon.trim_reqs()` 不能省——`lastReqs` 是
`mon` 的局部表，`collector.trim_cache()` 碰不到它，少了这句清了缓存照样 OOM。


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

### 平台 V3 数据面三条上行（U2 / U3 / U7）

U4（数据上报）见上面 topic 表。这三条与订阅无关，都是 `publish`：

| 编号 | topic | 时机 | 内容 |
|---|---|---|---|
| U3 | `/sys/thing/gw/property/post/{sn}` | 与 U4 同节奏（`interval_s`） | `ram_percent`（`rtos.meminfo("sys")`）、`uptime_sec`（`os.clock()`）、`cpu_percent`（主循环忙碌占比，**非 MCU CPU 占用率**，LuatOS 无 OS 级 CPU 接口） |
| U7 | `/sys/thing/gw/function/post/{targetSN}` | 每次 D2/D3 下行执行后 | `[{"id":<下发 id>,"value":<值或 null>}]`。粒度只到**入队/拒绝**：`poll.enqueue_write` 是异步的，汇总 `write_status()` 分不出是哪一条，所以 `value` 非 null **不等于已写到总线** |

**U2 是双重用途的**（`iot.lua` 的 `send_meta` / `send_topo`），靠 body 里有没有
`nodes[]` 区分语义，所以拆成**两帧**各发一次（合成一帧平台拿不准该干嘛）：

| 帧 | body | 平台行为 | 时机 |
|---|---|---|---|
| 元数据帧 | 不带 `nodes[]`：`sn`/`deviceSn`/`imei`/`iccid`/`fw`/`firmwareVersion`/`hw`/`capabilities`/`deviceName`/`serialNumber`/`csq`/`netRegister`/`networkAddress`/`isShadow`/`summary`/`ts` | 只更新网关属性，**不重建模型** | 元数据指纹（imei/iccid/csq/host）变化即发 |
| 拓扑帧 | 带 `nodes[]`：`sn`/`deviceSn`/`ts`/`nodes[]` | 建子设备 + 绑定 + 物模型 | 拓扑签名变化即发，**且 detect 未跑完不发**（否则 baud 是上一轮的默认值，平台按错波特率建一次模型还得再重建） |

两帧都**不做定时兜底**：实测（2026-10-08）留着 60s 兜底重发会形成
"我们发拓扑 → 平台推配置 → 我们再发拓扑"的闭环，每 60s 一轮；而且兜底路径不打日志，
现象是"sniff 档平台不断下发模型配置"，难查。

`firmwareVersion` 是纯数字（`2.0.0` → `20000`）= major\*10000 + minor\*100 + patch：
平台侧该字段是 BigDecimal，传字符串会**整帧被丢**。`ts` 用秒，毫秒会让平台按 1970 年解析。

**U2 拓扑的两个来源保真度不同**（`iot.lua` 的 `build_nodes`）：

| 模式 | 来源 | id / name / dtype |
|---|---|---|
| poll / pollpull | `active_cfg()` 平台下发的正经配置 | 全是真的（`name`/`alias`/`dtype`） |
| sniff | `mon.infer()` ∪ `cfgstore.load_pull()`，按 `slave:addr` 合并，**平台配置覆盖推断** | 只有 slave/addr/count，id/name 按地址现造（`r<addr>`），dtype 默认 `uint16` |

**U5 / U5b 告警事件（`gw/event/post`）本次未实现**，需要时按同一套方式补。


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
> **`onboardingMode` 按当前 485 模式如实报**（文档：`sniff`/`platform`/`manual`）：
>
> | 模式 | 上报值 | 平台行为 |
> |---|---|---|
> | `sniff` | `sniff` | 跳过"对本地自建设备无效的配置快照推送" |
> | `pollpull` | `platform` | 照常推 ConfigSnapshot（拉取档要的就是这个） |
> | `poll`（手配） | `platform` | 该档不订 `config/get`，推了也收不到 |
>
> `manual` **不报**：文档只写明了 `sniff` 的行为，`manual` 收到会怎样没有定义，
> 报一个行为未知的值风险大于收益。待确认后补，见 `NOTES-onboarding-manual.md`。
>
> ⚠️ 这里改过一次。早期固定报 `platform`，理由是"报 sniff 平台会直接不搭理"。
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
> **pollpull 档每 30min 重发一次**（`HELLO_RE_S`，在 `task_main` 已连接分支里判）：
> 平台侧网关档案可能被重置/白名单到期，设备侧无从得知，只靠上电那一次 hello 会
> **永久失联且没有任何报错**。重发不走拉取状态机 —— 平台响应由 `recv_push` 直接
> 落盘，不影响前端正在显示的拉取结果，也不需要用户再点一次「拉取配置」。
> `hello_at` 记的是**本连接内最后一次 hello 成功发送**的时间，`reset_state` 置 0，
> 所以开机不会白发；新一轮拉取/重连后重新起跑。
> 三个前提都满足才发：`hello_at > 0`、当前是 pollpull 档、`pulling()` 为假
> （握手中不发，避免和正在等的应答打架）。
> sniff / poll 两档**不发**：前者没有"未拿到配置"这个状态，后者不订 `config/get`。
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
| 上报（发布） | `/sys/thing/node/property/post/{sn}-{n}` | 数据面（U4）。`{n}` = 子设备序号，**从机地址升序**：一份轮询配置只有一个 slave 恒为 `-1`，sniff 档多从机才递增。`-{n}` 后缀不能省，缺了平台无法把数据归属到子设备、上报等于白发。**前端可改**（`mqttcfg.pub_topic`，改的是 `{sn}` 前那段） |
| 拓扑上报（发布） | `/sys/thing/gw/info/post/{sn}` | U2 建档，带 `nodes[]`。**固定平台常量**（`cfg.PLATFORM_INFO_TOPIC`），不可改 |
| 网关资源（发布） | `/sys/thing/gw/property/post/{sn}` | U3，`ram_percent`/`uptime_sec`/`cpu_percent`。**固定平台常量**（`cfg.PLATFORM_RES_TOPIC`），不可改 |
| 指令回执（发布） | `/sys/thing/gw/function/post/{targetSN}` | U7，D2/D3 执行后回 `[{id,value}]`，失败项 `value:null`。**固定平台常量**（`cfg.PLATFORM_FPOST_TOPIC`），不可改 |
| 订阅（下行） | `/sys/thing/gw/config/get/{sn}` | 主下行通道：平台配置下发 + 普通指令都走它。**前端可改**（`mqttcfg.sub_topic`） |
| hello | `/sys/thing/gw/config/hello/{sn}` | 拉取握手，`{sn}` = 设备 SN。**固定平台常量**（`cfg.PLATFORM_HELLO_TOPIC`），不可改 |
| 服务调用 | `/sys/thing/gw/function/get/{sn}` | 平台三类下行之一，conack 时订阅。**固定平台常量**（`cfg.PLATFORM_FUNC_TOPIC`） |
| 属性设置 | `/sys/thing/gw/property/set/{sn}` | 同上（`cfg.PLATFORM_PSET_TOPIC`） |
| 属性查询 | `/sys/thing/gw/property/get/{sn}` | 同上（`cfg.PLATFORM_PGET_TOPIC`） |
| 配置下发 | `/sys/thing/gw/config/get/{SN}` | conack 时与下行 topic 一起订阅 |
| 上报（平台） | `/sys/thing/node/property/post/{SN}-1` | 拉取结果里回给前端展示，当前不订阅 |
| 下行命令（平台） | `/sys/thing/gw/function/get/{SN}` | 拉取结果里回给前端展示，当前不订阅 |

> 上表只有 **发布 / 订阅 2 条**带 `{sn}` 的是模板、可从前端改；其余 4 条
> （hello / 服务调用 / 属性设置 / 属性查询）已按"代码精简"从 `mqttcfg` 配置项
> 里删除，改为 `core/config.lua` 的 `PLATFORM_*_TOPIC` 固定常量。这 4 条平台侧
> 几乎不会变，每配一条就要在 normalize、`build_subs`、`effective`、前端表单里
> 各留一份逻辑。**发布/订阅行为完全不变**，只是不能再从界面改。
> 2 条模板都存在 `mqtt_cfg` 这一条 fskv 里，落盘上限已从 512 抬到 **2048**——
> 原上限下 host(128)+clientId(128) 就会到 300B+，加上 2 条 topic 仍可能超。
> 缺字段的键用设备默认值补，所以老固件/老配置（带 hello/func/pset/pget 键）
> 也能正常加载，多出来的键被忽略。
>
> #### `mqtt_cfg` 的字段分档
>
> | 分组 | 字段 | 说明 |
> |---|---|---|
> | 共用 | `host` `port` `ssl` `client_id` `interval_s` `qos` `allow_no_sn` `keep_session` | 自动档和手动档建连都读这份 |
> | 手动档 | `user` `pass` `pub_topic` `sub_topic` | 只有 `manual_on` 为真时才用。置假时 `normalize` 会把它们清空，回到默认模板 |
> | 自动档 | `auto.pass` | 首页「MQTT凭证密码」。`profile()` 里用户名固定留空 → `try_connect` 兜底填 SN |
> | 开关 | `manual_on` | 当前档位。`W:MQTT` 下发；`R:MQTT` 的 `manual_on` / `auto_pass` 给前端回显 |
>
> 前端两页分别写不同键：首页「MQTT 服务器」写 `auto_pass`（+ 共用的地址/端口/ClientID），
> 「MQTT配置」页写 `user`/`pass`/`pub_topic`/`sub_topic` + `manual_on`。
> **两个密码必须分成两个键**，否则前端无法表达"这次改的是哪一档"，改一个就会把另一个冲掉。

> 业务订阅模板默认与「配置下发」topic 同形，所以 conack 时会去重（同一 topic 只订一次），
> 且下行分流只在拉取状态机 `waiting` 时才把该 topic 的报文当配置包收，其余按普通指令解析。
>
> **例外：平台主动重推**。同一条 `config/get` topic 上，用户没点拉取时平台也能主动推
> `configSnapshot`（「重新下发配置」按钮）。此时不按 `configSnapshot` 字段识别就会
> 静默丢弃，所以分流条件不止看 `waiting`——见上方「平台主动重新下发」。

#### conack 时的订阅清单（`iot.build_subs()`）

**按 `manual_on` 分两套，订阅条数直接反映档位**：

| 档位 | 订几条 | 清单 |
|---|---|---|
| 自动档 | 4 条 | 4 条 gw 平台前缀（`sub_topic` 默认模板与 `config/get` 同形，去重后不额外占位） |
| 手动档 | **1 条** | 只有用户填的 `sub_topic`，4 条 gw 平台前缀**一条都不订** |

平台下发恒用 **gw 前缀**（`node` 前缀是子设备上行专用，不能混），末段是目标裸 SN：

| topic | 用途 |
|---|---|
| `/sys/thing/gw/config/get/{SN}` | **无条件订阅**（仅自动档）。业务 `sub_topic` 被用户改到别处时，这条仍要订，否则拉取链路断了 |
| `{sub}` | 用户自配的业务订阅（改过 sub_topic 时才会与上一条不同） |
| `/sys/thing/gw/function/get/{SN}` | 服务调用，固定平台常量（`cfg.PLATFORM_FUNC_TOPIC`） |
| `/sys/thing/gw/property/set/{SN}` | 属性设置，固定平台常量（`cfg.PLATFORM_PSET_TOPIC`） |
| `/sys/thing/gw/property/get/{SN}` | 属性查询，固定平台常量（`cfg.PLATFORM_PGET_TOPIC`） |

后三条**读固定常量而不是配置**：这三条模型侧也改不了，没必要给它留配置项。
去重逻辑不变（与 `config/get` 同形时仍只订一次）。

**手动档为什么一条 gw 都不订**：手动档接的是用户自己的 broker 和自己的 topic
命名，`/sys/thing/gw/{SN}` 那套拼出来也没人往那儿发，订着纯属噪音——界面上
「订阅Topic」列一堆自己没配过的东西，用户会以为手动配置没生效。

> ⚠️ **代价：拉取配置在手动档必然超时**。它的应答走 `config/get`，而手动档
> 不订这条。前端已在手动档把「拉取配置」按钮置灰并提示"请先关闭手动配置"。
> 想拉配置就先关手动配置。

清单全量回在 `R:MQTT` 的 `stat.subs`（数组），前端「连接与上报状态」的 **订阅Topic** 一栏显示（**仅自动档**；手动档下这一栏整行隐藏，改看「生效发布」「生效订阅」）。

#### SN 归属过滤（`iot.claim_ok()`）

同 broker 上多台网关时，别人网关的下行也会被 EMQX 送过来。`handle_downlink` 入口按
「topic 末段 == 本机 SN 或 `{gwSn}-{n}`」判定，不是自己的直接丢弃。两条例外：
无 SN（`allow_no_sn`）和非 `/sys/thing/` 命名空间（用户自配 topic）都放行，
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
I/iot: conack ok, subscribed=true, topics=[/sys/thing/gw/config/get/11802026092600016 /sys/thing/gw/function/get/11802026092600016 /sys/thing/gw/property/set/11802026092600016 /sys/thing/gw/property/get/11802026092600016]
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
I/iot: downlink dropped, not ours: /sys/thing/gw/function/get/V239342435
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
