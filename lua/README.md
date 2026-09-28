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
│   ├── collector.lua   数据层（最新值 + 帧缓存 + 回调）
│   └── store.lua       本地落盘（按轮环形 + 整文件重写 + eps 过滤）
├── cfg.lua             配置中心（poll/sniff/sys 三类，fskv 持久化）
├── iot/
│   ├── mqttcfg.lua     MQTT 配置（{id} 占位 + normalize）
│   └── iot.lua         连接编排 + 上报 + 下行
└── svc/
    ├── guard.lua       看门狗喂狗 + 运行监控
    └── cmd.lua         前端指令层（R:/W: 指令）
```

## 启动时序

| 阶段 | 内容 |
|---|---|
| 1 | `guard.init()` 看门狗 9s 超时 / 3s 喂狗 |
| 2 | `sn.init()` 三态机 + 身份；on_change 烧号成功自动补启 MQTT |
| 3 | collector / cfg / store；collector.on_store → store.push |
| 4 | poll / mon / ctrl；GPIO8 预置低电平；boot_mode 决定是否自动起 |
| 5 | iot.init + start（未烧 SN 不建连） |
| 6 | cmd.init（注册指令）+ prov.init（VUART_0 产线通道） |

## 数据流

```
Q2: W:MODE=poll → ctrl → poll(总线唯一主人) → parse_frame/parse_value → collector
       ├─ on_update → iot → build_payload → MQTT 上行
       └─ on_store  → store → 整文件重写（仅存最近 10 轮）

Q3: W:MODE=sniff → ctrl → mon(纯 RX) → CRC 试探切帧 → REQ/RSP 配对 → push_frame

下行: 平台 WRITE → recv 挂起 → handle_downlink → resolve_addr → poll.enqueue_write
      （idle 时一次性写任务排空，sniff 占线则中止）

烧号: W:SN=xxx → prov → sn.write(锁检查/validate/Luhn) → fskv save + 回读
      → on_change → MQTT 自动启动
```

## 前端指令（VUART_0，115200 8N1，RET: 前缀应答）

| 指令 | 用途 |
|---|---|
| R:INFO | 设备信息（IMEI/UID/SN/锁状态/信号） |
| R:MODE / W:MODE=idle\|poll\|sniff | 模式查询/切换 |
| R:CFG / W:CFG={json} | 轮询配置读写 |
| R:SNIFFCFG / W:SNIFFCFG={json} | 旁听配置读写 |
| R:REG / W:REG=[json] | 寄存器表读写 |
| R:VAL | 实时值 |
| R:STAT | 运行状态汇总 |
| W:WRITE=slave,addr,value / W:WRITEJ={json} | 写寄存器（idle 也可写） |
| W:RAWTEST[=slave,addr,qty] | 485 裸探针：发原始请求并回显所有原始回字节，用于区分“没发出去/从机没回”与“回了但参数不匹配” |
| R:MQTT / W:MQTT={json} | MQTT 配置读写 |
| R:REPORT | 立即上报 |
| R:NET / R:MEM | 网络/内存诊断 |
| W:GC | 强制 GC + 重连 |
| R:DISK / W:STORE=0\|1[,P] | 存储查询/开关 |
| R:FRAMES / R:POLL | 旁听帧/轮询状态 |
| W:BOOTMODE=idle\|poll\|sniff | 开机默认模式（大小写不敏感） |
| W:RST | 恢复默认 |
| R:SN / R:ID / W:SN=xxx[,FORCE] / C:SN / LOCK:SN / UNLOCK:SN / R:SNEN / W:SNEN=n,0\|1[,P] | SN 产线指令 |

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
- `rtos.fsinfo` 官方确认不存在（本框架已不依赖）
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
4. `parsed=true` 但 `pushed` 不涨 → 查 `R:VAL` 与 `eps`（值变化过滤，`eps=0` 表示不过滤）
5. DE/RE 接 GPIO8，**高=发送、低=接收**；`W:RAWTEST` 会自动拉高/拉低

协议层已用标准 Modbus 校验值复核：读 slave=1 addr=14 qty=1 的请求帧为
`01 03 00 0e 00 01 e5 c9`，合法响应形如 `01 03 02 00 64 b9 af`（值 100）。

## 与原版（v1）的差异

- 24 文件 → 16 文件；删除 fsinfo/bootreason 桩、identity 独立模块、logctl 独立模块
- mbus_common → mbus；cfg_store → cfg.lua；collector/data_store 移入 data/
- vcom → cmd，指令集保留核心 26 条（含 W:RAWTEST 裸探针），
  去掉 TX/FRAMELOG/NETTEST/INFER/PROBE 等诊断指令
- 看门狗参数、MQTT 用法、启动顺序均对照官方文档核对修正
- 切帧统一为 CRC 试探法；事务前 drain 清残帧（v1 只在失败后 drain）
