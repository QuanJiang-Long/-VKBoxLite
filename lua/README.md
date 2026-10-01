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
Q2: W:MODE=poll → ctrl → poll(总线唯一主人) → parse_frame/parse_value → collector

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
| R:MODE / W:MODE=idle\|poll\|sniff | 模式查询（返回 {mode,busy,poll,mon,write}）/ 切换 |
| R:CFG / W:CFG={json} | 轮询配置读写，读返回 `{cfg, src}`，src=default 表示 fskv 里没写过 |
| R:REG / W:REG=[json] | 寄存器表读写 |
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
| R:INFER | 从旁听帧反推轮询表 `{regs:[{slave,addr,count,fc,hits}], slaves, stat}` |
| W:APPLYINFER | 把推断结果写入轮询配置 |
| R:SNIFF=ms | 静默侦听总线 ms 毫秒（100~30000），返回帧数 |
| W:TX=hex | 裸发一串字节（总线诊断），回显 rx_len/parsed/rx |
| W:BOOTMODE=idle\|poll\|sniff | 开机默认模式（大小写不敏感） |
| R:ID / W:SN=xxx[,FORCE] / C:SN / LOCK:SN / UNLOCK:SN / R:SNEN / W:SNEN=n,0\|1[,P] | SN 产线指令（VUART_0 通道） |

> 指令集与 `frontend/protocol.js` 的 `Enc` 一一对应。`W:RAWTEST`/`R:NET`/`R:MEM`/`W:GC` 是前端不调用的现场诊断入口。
>
> **写寄存器的入口**：MQTT 下行 `{"cmd":"WRITE","items":[...]}`（设备自动排进写队列）与前端「写寄存器」。原先的 `W:WRITE`/`W:WRITEJ` 已删除——字段名与 MQTT 下行解析完全一致，属重复实现。写结果看 `R:STAT` 的 `write` 段，**不是 `enqueue_write` 的返回值**（那只代表入队）。
>
> **已删除的前端零调用指令**：`R:SN`（前端用 `R:INFO` 拿 SN）、`R:SNIFFCFG`/`W:SNIFFCFG`（前端无入口）、`R:IOTSTAT` 与 `R:POLL`（被 `R:STAT` 的 iot/mqtt 段和 data 段覆盖）、`W:RST`（前端各自有「恢复默认」按钮）。连带删掉只服务它们的 `cfg.reset()`、`mqttcfg.reset()`、`collector.clear()`。

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
- 当前键用量：`ds_poll`/`ds_sniff`/`ds_sys`/`mqtt_cfg`/`ds_enable`/`ds_boots`/`dev_sn*` 共 4 个 ≈ 10 个，余量充足

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

> **保存与回执都发生在设备侧（`iot.auto_apply`），不经前端**：平台主动重推
> 走的是同一条路径，靠前端的话没开串口就永远不落地。三道安全边界：
>
> | 边界 | 作用 |
> |---|---|
> | `normalize_poll` 不过 | 整体拒绝、不落盘、不重启轮询，`skipped` 明细照旧带回 |
> | `interval_ms`/`timeout_ms` 取设备现值 | 平台怎么下发都不改轮询节奏（`pullcfg` 本来也不给这两个字段） |
> | 前后对比日志 | `pullcfg 自动保存并生效: 寄存器 3→3, slave 1→2, baud 9600→19200, msgId=...`，否则现场无法追溯配置何时被谁改过 |
>
> 串口参数变了才 `stop/apply/start` 重启轮询任务；只换寄存器表时 `apply_cfg` 热更
> 就够了，重启会硬断一次正在进行的 Modbus 事务。
> 落盘失败（flash 写不下等）按 **fail** 报，不假装成功——平台会继续重推，而设备
> 留旧配置，报 fail 比静默好排查；失败时**不回执 U6**。
> 只回一次（`pull.replied` 去重），同一 msgId 重复回执会让平台重复核销。
> 新一轮 `W:PULLCFG` 会重置 `msg_id`/`replied`。
>
> hello payload 带 6 个字段（V3 契约 U1）：`vendor`/`model`/`fwVersion`/`deviceId`
> 加 **`topicFormat:"v3"`** 与 **`onboardingMode:"platform"`** 两个自述字段。
> 缺了平台可能按旧版格式猜下行 topic，导致指令全丢且无报错；`onboardingMode`
> 若写 `sniff`，平台会跳过推送配置，拉取直接废——我们这条链路就是找平台要配置，
> 所以固定 `platform`。

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
| 上报（发布） | `/sys/thing/node/property/post/{sn}` | 数据面。模板写死 `-1` 后缀（子设备站位），`{sn}` = 设备 SN。**前端可改**（`mqttcfg.pub_topic`） |
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

#### conack 时的下行订阅清单（`iot.build_subs()`）

平台下发恒用 **gw 前缀**（`node` 前缀是子设备上行专用，不能混），末段是目标裸 SN：

| topic | 用途 |
|---|---|
| `/sys/thing/gw/config/get/{SN}` | **无条件订阅**。业务 `sub_topic` 被用户改到别处时，这条仍要订，否则拉取链路断了 |
| `{sub}` | 用户自配的业务订阅（改过 sub_topic 时才会与上一条不同） |
| `/sys/thing/gw/function/get/{SN}` | 服务调用，固定平台常量（`cfg.PLATFORM_FUNC_TOPIC`） |
| `/sys/thing/gw/property/set/{SN}` | 属性设置，固定平台常量（`cfg.PLATFORM_PSET_TOPIC`） |
| `/sys/thing/gw/property/get/{SN}` | 属性查询，固定平台常量（`cfg.PLATFORM_PGET_TOPIC`） |

后三条**读固定常量而不是配置**：这三条模型侧也改不了，没必要给它留配置项。
去重逻辑不变（与 `config/get` 同形时仍只订一次）。

清单全量回在 `R:MQTT` 的 `stat.subs`（数组），前端「连接与上报状态」的 **下行订阅** 一栏显示。

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

**devices[0].addr → `slave`**（字符串转数字，须在 1~247）

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
