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
│   ├── mqttcfg.lua     MQTT 配置（{id} 占位 + normalize）
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
| W:PULLCFG / R:PULLCFG | 平台配置拉取：W 发起（回 `started`），R 查状态（`{state,msg,poll,skipped,mqtt}`） |
| W:WRITE=slave,addr,value / W:WRITEJ={json} | 写寄存器（idle 也可写，经写事务队列在安全点注入） |
| W:RAWTEST[=slave,addr,qty] | 485 裸探针：发原始请求并回显所有原始回字节，用于区分“没发出去/从机没回”与“回了但参数不匹配” |
| R:MQTT / W:MQTT={json} | MQTT 配置读写，读返回 `{cfg,pub,sub,ready,err,stat}` |
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

### 时序

```
前端  ──W:PULLCFG──────────▶  设备  立即回 RET:PULLCFG=started
前端  ──R:PULLCFG(每1s)────▶  设备  回 {state:"helloing"|"waiting", msg}
                                    │
设备  ──publish────────────────▶  平台  /sys/thing/gw/config/hello/{SN}
                                    {"vendor":"VKBoxLite","model":"VKBox-Lite",
                                     "fwVersion":"<VERSION>","deviceId":"<IMEI>"}
平台  ──publish────────────────▶  设备  /sys/thing/gw/config/get/{SN}  （连上即订阅）
                                    │
前端  ──R:PULLCFG──────────▶  设备  回 {state:"done", poll:{...}, skipped:[...],
                                        mqtt:{pub,sub}}
前端  回填 485 表单 + 寄存器表 + MQTT pub/sub 输入框
用户  点「保存配置」/「保存并重连」→ W:CFG / W:REG / W:MQTT
```

> `W:PULLCFG` 处理器在 VUART 回调上下文，**不能 `sys.wait`**，所以握手跑在
> `iot.task_main` 协程里；指令只置状态并立即应答，前端轮询拿结果。
> 超时 `PULL_TIMEOUT_MS=15s`，前端最多轮询 16 次（≈19s），不会早于设备放弃。

### topic

| 用途 | topic | 说明 |
|---|---|---|
| hello | `/sys/thing/gw/config/hello/{SN}` | `{SN}` = 设备 SN |
| 配置下发 | `/sys/thing/gw/config/get/{SN}` | conack 时与下行 topic 一起订阅 |
| 上报 | `/sys/thing/node/property/post/{SN}-1` | `{n}` 固定为 1 |
| 下行命令 | `/sys/thing/gw/function/get/{SN}` | |

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
| `modbus.dataType` | `dtype` | `ushort`→uint16、`short`→int16、`ulong`→uint32、`long`→int32、`float`→float32、`double`→float64 |

**丢弃**：`msgId`、`ts`、`mqttPlatform`（保持现有 broker）、`tslName`、
`devices[].name/protocol/comm`、`modbus.type`、`modbus.slave`、外层 `dataType`。

非法条目不整包失败：跳过并记入 `skipped`，前端提示"已忽略 N 条"。
寄存器数超过 `MAX_REGS=128` 截断。`interval_ms`/`timeout_ms` 沿用设备当前值，不随平台变更。

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
- 配置校验与原工程对齐：串口参数范围 / MAX_REGS=128 / 标识符去重 / count%width，save 上限 2048
