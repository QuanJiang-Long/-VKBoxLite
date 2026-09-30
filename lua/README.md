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
      （idle 时一次性写任务排空，sniff 占线则中止）

烧号: W:SN=xxx → prov → sn.write(锁检查/validate/Luhn) → fskv save + 回读
      → on_change → MQTT 自动启动
```

## 前端指令（VUART_0，115200 8N1，RET: 前缀应答）

| 指令 | 用途 |
|---|---|
| R:INFO | 设备信息（SN/IMEI/ICCID/CSQ/RSRP/版本/项目/服务器/波特率/从机/寄存器数/锁状态） |
| R:MODE / W:MODE=idle\|poll\|sniff | 模式查询（返回 {mode,busy,poll,mon,write}）/ 切换 |
| R:CFG / W:CFG={json} | 轮询配置读写，读返回 `{cfg, src}`，src=default 表示 fskv 里没写过 |
| R:SNIFFCFG / W:SNIFFCFG={json} | 旁听配置读写，读返回 `{cfg, src}` |
| R:REG / W:REG=[json] | 寄存器表读写 |
| R:VAL | 实时值快照 |
| R:STAT | 运行状态汇总（mode/data/guard/mqtt） |
| W:PULLCFG / R:PULLCFG | 平台配置拉取：W 发起（回 `started`），R 查状态（`{state,msg,poll,skipped,mqtt}`，`mqtt` 段含 `hello`/`pub`/`sub` 三个拼好的 topic；另有 `msg_id`/`replied` 反映回执）。前提只需配好 MQTT 服务器地址和端口，设备会自己连 |
| W:WRITE=slave,addr,value / W:WRITEJ={json} | 写寄存器（idle 也可写，经写事务队列在安全点注入） |
| W:RAWTEST[=slave,addr,qty] | 485 裸探针：发原始请求并回显所有原始回字节，用于区分“没发出去/从机没回”与“回了但参数不匹配” |
| R:MQTT / W:MQTT={json} | MQTT 配置读写，读返回 `{cfg,pub,sub,ready,err,stat}` |
| W:MQTTRC | 只重连不动配置（等价 `iot.kick()`：销毁 client 后 backoff 归 1 立刻重连） |
| R:REPORT | 立即上报 |
| R:IOTSTAT | MQTT 运行态（connected/subscribed/published/failed/last_err/last_pub/backoff） |
| R:NET / R:MEM | 网络/内存诊断 |
| W:GC | 强制 GC + 重连 |
| R:FRAMES[=n] | 旁听帧（n 取 1~50，默认 20） |
| R:POLL | 轮询状态（rounds/ok/timeout/werr/regs/interval） |
| R:INFER | 从旁听帧反推轮询表 `{regs:[{slave,addr,count,fc,hits}], slaves, stat}` |
| W:APPLYINFER | 把推断结果写入轮询配置 |
| R:SNIFF=ms | 静默侦听总线 ms 毫秒（100~30000），返回帧数 |
| W:TX=hex | 裸发一串字节（总线诊断），回显 rx_len/parsed/rx |
| W:BOOTMODE=idle\|poll\|sniff | 开机默认模式（大小写不敏感） |
| W:RST | 恢复默认 |
| R:SN / R:ID / W:SN=xxx[,FORCE] / C:SN / LOCK:SN / UNLOCK:SN / R:SNEN / W:SNEN=n,0\|1[,P] | SN 产线指令 |

指令集与 `frontend/protocol.js` 的 `Enc` 一一对应；`W:RAWTEST`/`R:NET`/`R:MEM`/`W:GC` 是前端不调用的现场诊断入口。

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
I/user.iot connect: host=dz.voltkun.com port=1883 ssl=false clientId=11802026092600016 user=(无) clean=true
```

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

`0x05` **不等于"必须补用户名密码"**。按以下顺序查：

1. **clientId 格式**（最常见）
   很多平台不认纯 SN，而是带前缀后缀的格式，例如 `S&<SN>&12&1`。
   原工程 `lua/iot/mqtt_cfg.lua` 明确记载过这种规范。
   留空时本框架退回用 SN，格式不对平台就判未授权。
   → 去「MQTT配置」或首页填平台要求的 clientId 格式。
2. **地址/端口**：确认平台给的是 MQTT 端口（常见 1883 / 8883(TLS) / 自定义），
   不是 Web 端口。
3. **设备是否已注册**：平台可能只放行预先录入的设备，按 clientId 或 SN 白名单。
4. **用户名密码**：确实有账号密码时才需要补。

### 两个实现细节

- **`auth()` 的空串必须传 `nil`**。LuatOS 只判指针非空就当"有用户名"，
  会把零长用户名字段塞进 CONNECT 包，部分平台据此判未授权回 0x05。
- **`reject_reason` 独立于 `last_err`**。`try_connect` 等满 15s 后会把
  `last_err` 覆盖成 `conack timeout`，拒绝原因就丢了，所以单独记一个字段，
  前端优先显示它。

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

前端点「拉取配置」→ 设备与平台握手拿配置 → **只回填表单，不自动落盘**，用户点「保存配置」才生效。

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
      ④ 解析 → 回结果                       state=done / fail

平台  ──publish────────────────▶  设备  /sys/thing/gw/config/get/{SN}  （连上即订阅）

前端  回填 485 表单 + 寄存器表 + MQTT hello/pub/sub 输入框，
      并强制关掉「手动配置」——三个 topic 换成平台给的那套成品
用户  点「保存配置」→ W:CFG 成功 → iot.reply_config()
设备  ──publish────────────────▶  平台  /sys/thing/gw/config/reply/{SN}
       {"msgId":<下发原值>,"code":200,"status":"ok","appliedTs":<now>}
（「重连」按钮单独发 W:MQTTRC，只重连不动配置）
```

> 回执刻意放在**用户保存之后**：`parse()` 成功只代表报文解析通过，不代表现场
> 认可这套配置。用户不点保存就不回执，平台会继续重推——这正是想要的语义。
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

### topic

| 用途 | topic | 说明 |
|---|---|---|
| 上报（发布） | `/sys/thing/node/property/post/{sn}` | 前端留空时的默认模板，`{sn}` = 设备 SN |
| 订阅（下行） | `/sys/thing/gw/config/get/{sn}` | 前端留空时的默认模板 |
| hello | `/sys/thing/gw/config/hello/{sn}` | 拉取握手，`{sn}` = 设备 SN。**前端可改**（`mqttcfg.hello_topic`，「MQTT配置」页的 **hello Topic** 输入框），留空回落此默认 |
| 配置下发 | `/sys/thing/gw/config/get/{SN}` | conack 时与下行 topic 一起订阅 |
| 上报（平台） | `/sys/thing/node/property/post/{SN}-1` | 拉取结果里回给前端展示，当前不订阅 |
| 下行命令（平台） | `/sys/thing/gw/function/get/{SN}` | 拉取结果里回给前端展示，当前不订阅 |

> 业务订阅模板默认与「配置下发」topic 同形，所以 conack 时会去重（同一 topic 只订一次），
> 且下行分流只在拉取状态机 `waiting` 时才把该 topic 的报文当配置包收，其余按普通指令解析。

#### conack 时的下行订阅清单（`iot.build_subs()`）

平台下发恒用 **gw 前缀**（`node` 前缀是子设备上行专用，不能混），末段是目标裸 SN：

| topic | 用途 |
|---|---|
| `/sys/thing/gw/config/get/{SN}` | **无条件订阅**。业务 `sub_topic` 被用户改到别处时，这条仍要订，否则拉取链路断了 |
| `{sub}` | 用户自配的业务订阅（改过 sub_topic 时才会与上一条不同） |
| `/sys/thing/gw/function/get/{SN}` | 服务调用 |
| `/sys/thing/gw/property/set/{SN}` | 属性设置 |
| `/sys/thing/gw/property/get/{SN}` | 属性查询（空 body = 读全量） |

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
I/iot: pullcfg done 已忽略 0 条
I/iot: config/reply /sys/thing/gw/config/reply/11802026092600016 {"msgId":"hello-3f9a2b1c","code":200,"message":"config applied","status":"ok","appliedTs":1721884800}
```

`config/reply` 那行**只在用户点过「保存配置」之后**才出现。没出现就说明配置还没被
确认，平台会继续重推；这是预期行为，不是 bug。

不是本机 SN 的下行会被丢掉，日志：

```
I/iot: downlink dropped, not ours: /sys/thing/gw/function/get/V239342435
```

连不上 MQTT 时是 `pullcfg fail MQTT 连接失败: <原因>`（等 20s）。

topic 里的 `{SN}` 取的是**烧号的 SN**（`_G.get_device_sn()`），与 payload 里的
`deviceId`（IMEI）**不是同一个标识**。所有 topic 用的都是同一个 SN，对不上时先看这行日志确认。

### 平台中文名乱码

**现象**：`R:PULLCFG` 回来 `alias` 不是中文而是一串替代符；前端提示
"N 个平台别名不可用已退用 id"。MQTTX 直接订阅同样看到乱码。

**结论：不是设备的原因。** 平台把中文 `name` 按 GBK/GB2312 写进了本该是 UTF-8 的
JSON 字符串字段。"电压" 的 GBK 字节是 `B5 E7 D1 B9`，按 UTF-8 弱解码得到的是
`U+FFFD U+FFFD U+0479`（两个 Unicode 替代符 + 一个伪西里尔字母 `ѹ`，在终端里显示成
`??ѹ`），与现场看到的逐字符一致。任何按标准解 UTF-8 的客户端（MQTTX / Electron /
本设备）都会看到同样结果，因为字节在到达订阅方之前就已经坏了——MQTTX 是完全独立的
客户端，它坏就证明与读取方无关。

**设备侧的对策**（`pullcfg.utf8_ok()`）：只做校验不做转码。GBK→UTF-8 需要几万条
映射表，塞不进 300KB 的 Lua 堆。校验不过就把 `alias` 退回 `id`——这样至少不会把
坏字节当成 `name` 发回平台，也不在前端显示乱码。

**要平台侧改的地方**（三件事，按优先级）：

1. **把下发 JSON 的字符集统一成 UTF-8**，特别是 `configSnapshot.tsl.properties[].name`。
   现在中文按 GBK 下发，MQTTX / Electron / 本设备三方都看到乱码。
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
