# Air780EP 软 SN 架构方案 V2.1（已确认版）

> 硬件：Air780EP，固件 `V2026_Air780EP_1.soc` 不变，不降级 V2002、不换 EPM 模组。
> 定义：软 SN = 业务层 SN，存于模组 Flash 的 FSKV 键值分区，非 Modem/OTP 硬件固化区。
> 本方案不参考 `VKBox_Lite（1）` 现有工程的 SN 实现，基于需求方向独立推导。

---

## 0. 决策记录（Q1~Q7 已确认）

| # | 问题 | 结论 |
|---|---|---|
| Q1 | 工程落点 | ✅ 就在 `VKBoxLite_sn` 建 `soft_sn_demo` 独立工程 |
| Q2 | SN 位数 | 先不定义格式；建议 **16 位定长**：`VK` + `YYMMDD` + `7 位流水号` + `1 位校验位`（见 §7） |
| Q3 | clientid 规范 | 平台无要求 → 未烧录时用 `pending_` + 兜底ID，平台可识别且不与已烧号 ID 冲突 |
| Q4 | 写次数限制 | ❌ 取消"启动周期写 N 次"限制。改为**唯一性语义**：一台设备任何时刻只有一个生效 SN；异值覆盖需显式 `FORCE`，且全程留 burn 追溯（见 §4.2） |
| Q5 | 烧录锁作用 | 出厂后把 SN 冻死：现场人员/误连串口改不了 SN；代价是返修需先解锁（见 §4.4） |
| Q6 | 平台写 SN | 平台不参与 → 代码里**不存在**平台下发写 SN 的路径，只有 COM4 一条写入口 |
| Q7 | 周期告警作用 | SN 缺失但设备长期在线时，让远程日志持续可见"这台没烧号"；默认 600s，可关 |

---

## 1. 分层架构（L0~L3）

```
┌──────────────────────────────────────────────────────────┐
│ L3 业务接入层                                             │
│   report.lua（上行报文统一注入）                            │
│   get_device_sn()（全局唯一只读入口，定义于 sn_core）        │
├──────────────────────────────────────────────────────────┤
│ L2 通道/策略层                                            │
│   sn_prov_uart.lua（COM4 产线烧录通道，唯一写入口）          │
│   identity.lua（MQTT clientid 降级链 + 设备身份结构）       │
├──────────────────────────────────────────────────────────┤
│ L1 SN 核心服务层                                          │
│   sn_core.lua：三态状态机 / 校验 / 内存缓存 / 写策略 / 追溯  │
├──────────────────────────────────────────────────────────┤
│ L0 存储适配层                                             │
│   sn_store_fskv.lua（FSKV 实现；未来换 OTP 只换这一层）      │
└──────────────────────────────────────────────────────────┘
```

依赖方向严格自上而下：**除 L0 外，任何模块禁止直接调用 fskv**。

---

## 2. 工程结构（已落地）

```
VKBoxLite_sn/
├── soft_sn_demo/            # 烧录到模组的脚本（下载到 /luadb 对应目录）
│   ├── main.lua             # 入口：上电初始化编排
│   ├── sn_core.lua          # L1 SN 核心服务（状态机/校验/缓存/写策略）
│   ├── sn_store_fskv.lua    # L0 FSKV 存储适配器
│   ├── sn_prov_uart.lua     # L2 COM4 产线指令通道
│   ├── identity.lua         # L2 设备身份策略（clientid 降级链）
│   ├── report.lua           # L3 上行报文统一注入
│   └── mqtt_demo.lua        # MQTT 接线演示骨架（主题/账号按平台改）
├── test/                    # PC 单测（lua/luajit 运行，无需硬件）
│   ├── mock/env.lua         # fskv/uart/mobile/mcu/sys mock
│   ├── sn_core_test.lua     # 13 例
│   ├── prov_uart_test.lua   # 13 例
│   ├── identity_test.lua    # 6 例
│   ├── report_test.lua      # 3 例
│   └── run_all.lua          # 入口：lua run_all.lua
└── docs/soft_sn_arch_v2.md  # 本文档
```

---

## 3. 三态状态机

```
        init 读到合法 SN                 write 成功
EMPTY ──────────────────→ READY ◄──────────────────┐
  ↑                        │                        │
  │ init 读到脏数据          │ clear / FSKV 被擦      │
  └──── INVALID ────────────┘（重启后回到 EMPTY/INVALID）
```

| 状态 | 含义 | clientid | 上报 | 日志 |
|---|---|---|---|---|
| `ready` | SN 正常 | 软 SN | `sn=软SN, sn_status=normal` | info |
| `invalid` | Flash 有值但非法（脏数据，**允许被覆盖写**） | `pending_`+兜底ID | `sn_status=unset` | error |
| `empty` | 无 SN，待烧录 | `pending_`+兜底ID | `sn_status=unset` | warn（600s 周期） |

---

## 4. 核心规则

### 4.1 SN 格式（`sn_core.rules`，唯一改动点）
- 当前：仅 `A-Z a-z 0-9`，长度 1~32 字节；拒绝空格/符号/中文/非字符串。
- 后续定格式只改 `sn_core.lua` 顶部的 `M.rules` 表 + `validate()` 追加分支，其余代码不动。

### 4.2 SN 唯一性（Q4 结论，核心）
- FSKV 只有一个 `dev_sn` 键 → 物理上任何时刻只有一个生效 SN。
- `W:SN=xxx` 当已有 SN 且值不同 → **默认拒绝** `RET:FAIL:sn exists`（防止一个设备被烧成两个码）。
- 同值重复写 → 幂等返回 `same`，**完全不碰 Flash**。
- 产线返修需覆盖 → `W:SN=xxx,FORCE`。
- 每次成功写入累加 `dev_sn_burn`、记录 `dev_sn_btime`（首次烧录时间），全程可追溯"这台被烧过几次"。
- ❌ 不设"启动周期写 N 次"限制：正常产线一个模块只写一次，Flash 擦写天然受控；防夹具死循环由上面的"存在即拒绝"兜底。

### 4.3 写后回读
`fskv.set` 后立即回读比对，不一致 → `RET:FAIL:verify fail` 且不更新内存缓存（防 set 静默失败导致内存与 Flash 不一致）。

### 4.4 烧录锁（Q5 结论）
- `LOCK:SN` 置 `dev_sn_lock=1`，之后任何 `W:`/`C:` 一律 `RET:FAIL:locked`。
- 作用：出厂后 SN 不可变，现场误操作/误连串口改不了。
- 代价：返修必须先解锁（重新烧录或调试口清键）。默认可选开启。

### 4.5 量产安全开关（`sn_prov_uart.lua`）
| 开关 | 默认 | 说明 |
|---|---|---|
| `write_enable` | true | false = 现场禁改场景，整体关闭写 SN |
| `clear_enable` | false | 量产必须 false；关闭时 `C:SN` **无任何响应**（现场扫不到该指令） |
| `lock_enable` | true | 是否支持 `LOCK:SN` |

---

## 5. COM4 指令协议（115200 8N1）

| 指令 | 应答 | 说明 |
|---|---|---|
| `R:SN` | `RET:SN=xxx` / `RET:SN=EMPTY` / `RET:SN=INVALID` | 烧后校验 |
| `W:SN=xxxx` | `RET:OK` / `RET:FAIL:原因` | 已有 SN 且不同 → `sn exists` |
| `W:SN=xxxx,FORCE` | `RET:OK` | 强制覆盖（返修） |
| `C:SN` | 无响应（量产） | 调试用 |
| `LOCK:SN` | `RET:OK` / `RET:FAIL:no sn` | 上一旦性锁 |

工程细节：串口数据**按行缓冲**（遇 `\n` 才解析），解决 115200 下半包/分片被当成指令的坑；缓冲超 64B 自动清空。

---

## 6. 上电时序（`main.lua`）

```
1. sn_core.init()       读 FSKV → 校验 → 置三态之一 → 内存缓存
2. sn_prov_uart.init(4) COM4 烧录通道就绪（不依赖联网，连不上平台也能烧号）
3. identity.init()      读芯片 UID / IMEI
4. boot 摘要日志        sn_state / sn / burn / imei / chip_uid
5. start_warn_monitor   未烧号周期 warn（默认 600s）
6. mqtt_demo.start()    clientid = identity.get().clientid
```

---

## 7. SN 位数建议（Q2）

推荐 **16 位定长**：`VK` + `YYMMDD` + `7 位流水号` + `1 位校验位`

| 段 | 位 | 示例 | 作用 |
|---|---|---|---|
| 前缀 | 2 | `VK` | 品牌/产品线标识，扫码可读 |
| 日期 | 6 | `260524` | 产线批次可追溯 |
| 流水号 | 7 | `0000001` | 日产能上限 1000 万台，足够 |
| 校验位 | 1 | `7` | 防扫码误读/误录入（建议 Luhn 或累加和） |

- 定长便于产线 MES 对接与格式校验；`sn_core.rules` 已预留位置，定了格式只改一处。
- 若嫌复杂可退化为 **14 位纯数字**（`YYMMDD` + 8 位流水号），日产能上限 1 亿台。
- 设备端 `validate()` 可加校验位验证，非法码直接拒绝写入，脏数据进不了 FSKV。

---

## 8. Flash / FSKV 安全规范（硬约束）

1. 产线顺序：**先烧 soc 底层 + 业务脚本 → 上电 COM4 写 SN**。先写 SN 再刷底层 = SN 必丢（FSKV 被擦）。
2. 脚本 FOTA（只更 lua）：FSKV 保留，SN 不丢；USB 线刷 .soc：FSKV 擦除，SN 丢失属预期，靠产线规范规避。
3. `fskv.save()` 只在写成功路径调用；运行期间零定时保存、零循环写。
4. 业务全程读内存缓存，不重复读 Flash。
5. 同值写入幂等（不碰 Flash）；异值写入需显式 FORCE。

---

## 9. 测试方案与结果

**PC 单测（`test/`，lua/luajit 运行，mock 全部硬件依赖）：**

```
cd test
lua run_all.lua      # 或 luajit run_all.lua
```

覆盖：校验规则、长度边界、重启恢复、脏数据态、唯一性防呆、幂等写、FORCE 覆盖、烧录锁、写后回读失败、clear、变更回调、串口半包/多行/超长缓冲、`C:SN` 静默、未知指令、clientid 三级降级链、`mobile.sn` 缺失降级、上报注入。
**当前结果：35 passed, 0 failed。**

**整机验证（产线/现场）：**

| # | 用例 | 预期 |
|---|---|---|
| 1 | 全新模组上电 | `empty`，warn，MQTT 用 `pending_`+兜底ID 可连 |
| 2 | `W:SN=SNTEST001` → `R:SN` | `RET:OK`，读回一致 |
| 3 | 断电重启 | SN 仍在 |
| 4 | 非法 SN（符号/超长） | `RET:FAIL`，原值不变 |
| 5 | 脚本 FOTA 重启 | SN 保留 |
| 6 | soc 全量重烧 | SN 清空（预期，产线规范规避） |
| 7 | READY 态 | 握手/告警均带正确 SN + `sn_status=normal` |
| 8 | 已烧号设备再发异值 `W:SN` | `RET:FAIL:sn exists`，SN 不被改 |

---

## 10. 后续可选增强（不做也不影响主线）

- SN 格式定稿后加校验位算法（§7）
- 烧录完成后 `on_change` 回调里自动触发一次设备信息上报
- `identity` 增加 IMEI 就绪重试（`SYS_NET_READY` 事件后补一次）
- OTP 适配器 `sn_store_otp.lua`（换 EPM/完整版固件时启用）
