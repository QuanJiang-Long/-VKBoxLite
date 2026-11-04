# soft_sn_demo 设备端测试单（不联调平台）

> 目标：只验证设备端 SN 的写入 / 查询 / 持久化 / 异常拒绝，不涉及 MQTT 平台。
> 用法：按顺序执行，把「实际结果」列填上，有任何一行与预期不符就停下来反馈。
>
> **最后更新：2026-09-25** —— 已按 Air780EP 真机实测结论修订：
> 固件版本、启动日志、需要下载的文件数、VM 退出/模块找不到两类故障的真实原因。

---

## 0. 准备清单

| 项 | 内容 |
|---|---|
| 模组 | Air780EP，底层固件 `V2026_Air780EP_1.soc`（**不更换、不降级**） |
| 实测固件 | `LuatOS@Air780EP base 25.11 bsp V2026 32bit`，`firmware[1] BASIC fs 128kbyte script 256kbyte` |
| 脚本 | 只需下载 **6 个** lua：`main / corelib / sn_core / sn_store_fskv / sn_prov_uart / identity` |
| 工具 | Luatools（烧录+看日志）、另一个串口工具（SSCOM/友善串口/XCOM，发指令用） |
| 接线 | USB-TTL 接模组 UART4 的 TX/RX/GND（**TX 接 TTL 的 RX，交叉接**） |

> **为什么只有 6 个文件**：LuatOS 靠**静态扫描**收集依赖，只有被字面量 `require "xxx"` 引用的文件才会进包。
> `report.lua` 只被 `mqtt_demo.lua` 引用，而 `mqtt_demo` 当前已按"先不联调平台"的要求关闭，
> 所以这两个文件现在不在包里——**这是正常状态，不影响 SN 测试**。等联调阶段放开 `main.lua`
> 里 stage 7 的注释，它们才会随包下载。

**前置检查（30 秒，决定后面能不能测）：** UART4 必须是模组上真实存在且焊出/引出的串口。
- 若你的板子 UART4 没引出 → 改 `main.lua` 里 `pcall(prov.init, 4)` 的 `4` 为实际 UART ID（改一个数字即可）
- 上电后日志有 `I/sn_prov COM4 ready, 115200 8N1` = UART4 可用 ✅；若这行没有或报参数错 = ID 不对，按上一条改

---

## 1. 烧录（顺序不能反！）

| 步骤 | 操作 | 预期 |
|---|---|---|
| S1 | Luatools **全量烧录底层** `V2026_Air780EP_1.soc` | 烧录成功（此步会清空 FSKV，所以 SN 必须在之后写） |
| S2 | Luatools **只下载脚本**（不动底层），把上面 6 个 lua 加入项目 | 下载成功；若工具要求平级存放，把 `soft_sn_demo/` 内文件平铺即可 |
| S3 | 模组重启上电，看 Luatools 日志窗口 | 见下方「预期启动日志」 |

**预期启动日志（这就是 2026-09-25 真机实测通过的样子，逐行对照）：**

```
I/user.main   boot start, project=soft_sn_demo version=1.0.0
I/user.main     libs: uart=userdata fskv=userdata mobile=userdata mcu=userdata log=userdata
D/sfd.lfs init ok                                    <-- fskv 已初始化
I/user.main     [OK] sn_core loaded                  <-- 三个模块必须都是 [OK]
I/user.main     [OK] sn_prov_uart loaded
I/user.main     [OK] identity loaded
I/user.main   [stage 2/5] SN 核心初始化
W/user.sn_core SN empty, wait for burning via COM4   <-- 未烧录态，正确
I/user.main     [OK] sn state=empty sn=nil burn=0
I/user.main   [stage 3/5] 产线通道 + 设备身份
I/user.sn_prov COM4 ready, 115200 8N1                <-- 有这行 = UART4 OK
I/user.main     [OK] COM4 烧录通道就绪 115200/8N1
I/user.identity chip_uid: NE033sLE imei: 869080075432338   <-- 芯片 UID + IMEI
I/user.main     [OK] chip_uid=NE033sLE imei=869080075432338
I/user.main   [stage 4/5] 未烧号周期告警 600s
I/user.main   boot complete, entering sys.run()      <-- 关键：进了主循环
```

**三个必须满足的条件**（缺一个就别往下测）：

1. 三个模块都是 `[OK]`，不是 `[SKIP] ... module not found`
2. 有 `COM4 ready, 115200 8N1`
3. 最后是 `boot complete, entering sys.run()`，**并且之后不再出现 `Lua VM exit!!`**

---

## 0.5 固件版本核对

启动日志里的版本行：

```
I/main LuatOS@Air780EP base 25.11 bsp V2026 32bit
self_info 130:firmware[1] BASIC fs 128kbyte script 256kbyte
```

- 需求要求维持 `V2026_Air780EP_1.soc` 不变，**若日志显示 `bsp V2002`，说明模组上跑的不是 V2026**：检查 Luatools 里底层固件选的文件，并确认执行的是「下载底层」而不是只下载脚本。
- `BASIC` 是该 soc 的固件形态标识，**不代表缺库**——实测 `uart/fskv/mobile/mcu/log/mqtt/json` 全部可用（都是 userdata 形态，见 §6）。

---

## 2. COM4 指令测试（核心）

串口工具设置：**115200 / 8 / 1 / None**，**必须勾选「发送新行」**（指令以 `\r\n` 结尾，不勾选设备收不到完整指令）。

| # | 发送 | 预期应答 | 预期日志 | 实际结果 |
|---|---|---|---|---|
| T1 | `R:SN` | `RET:SN=EMPTY` | — | |
| T2 | `W:SN=SN20260924001` | `RET:OK` | `I/sn_core SN burned: SN20260924001 burn#1` | |
| T3 | `R:SN` | `RET:SN=SN20260924001` | — | |
| T4 | `W:SN=bad sn!`（带空格符号） | `RET:FAIL:char invalid` | — | |
| T5 | `W:SN=` + 33 个 A | `RET:FAIL:length invalid` | — | |
| T6 | `W:SN=SNOTHER0001`（与现有值不同） | `RET:FAIL:sn exists` | — | |
| T7 | `R:SN` | `RET:SN=SN20260924001`（**仍原值，没被改**） | — | |
| T8 | `W:SN=SN20260924001`（同值重写） | `RET:OK` | **无 burn 日志**（幂等，没碰 Flash） | |
| T9 | `W:SN=SNREWORK0001,FORCE` | `RET:OK` | `burn#2` | |
| T10 | 半包分片：**取消勾选「发送新行」**发 `W:SN=SNSP`，**再勾选**发 `LIT00001,FORCE` | 第一次**无返回**，第二次 `RET:OK` | `SN burned: SNSPLIT00001 burn#3` | |
| T11 | `LOCK:SN` | `RET:OK` | — | |
| T12 | `W:SN=SNX,FORCE` | `RET:FAIL:locked` | — | |
| T13 | `R:SN` | `RET:SN=SNSPLIT00001` | — | |
| T14 | `C:SN` | **无任何返回**（量产默认关闭） | — | |
| T15 | `HELLO` | 无返回 | `I/sn_prov unknown cmd, ignored: HELLO` | |

**T6/T7 是本次重点**：验证**一台设备只会有一个 SN**，异值写不进去。

**T10 半包的两个细节**（真机实测修正）：
- SSCOM 勾了「发送新行」会**每次发送都自动补 `\r\n`**，所以第一半必须先**取消勾选**再发，否则它会被当成完整指令立即执行（真机日志表现为两条独立 `cmd:`，第二跳 `unknown cmd`）
- T10 必须放在 `LOCK:SN`（T11）**之前**——上锁后任何写入都会被拒，包括 FORCE

**T11 之后设备进入锁定态**，后续 T12~T15 只验证拒绝与读取，不再写入。

### 返修：UNLOCK:SN（解锁后重烧）

锁了之后不用重刷 soc，用 `UNLOCK:SN` 摘锁：

| # | 发送 | 预期应答 | 说明 |
|---|---|---|---|
| U1 | `UNLOCK:SN` | `RET:OK` | 只摘锁，**不清 SN**（`R:SN` 仍返回原值） |
| U2 | `R:SN` | `RET:SN=SNSPLIT00001` | 值还在 |
| U3 | `W:SN=SNNEW0001` | `RET:FAIL:sn exists` | 解锁后异值仍默认拒绝，防"顺手改号" |
| U4 | `W:SN=SNNEW0001,FORCE` | `RET:OK` | 必须带 FORCE 才改写 |
| U5 | `UNLOCK:SN`（未上锁时） | `RET:FAIL:not locked` | 幂等拒绝 |

> 量产如不希望现场能解锁，把 `sn_prov_uart.lua` 里 `M.unlock_enable` 改为 `false`，
> 此时 `UNLOCK:SN` 无任何响应（和 `C:SN` 关闭时一致，扫描不到该指令的存在）。

---

## 3. 持久化 / 重启测试

| # | 操作 | 预期 | 实际结果 |
|---|---|---|---|
| P1 | 模组**断电重启** | 启动日志 `sn state=ready sn=SNSPLIT00001 burn=3` | |
| P2 | 重启后发 `R:SN` | `RET:SN=SNSPLIT00001`（与重启前一致） | |
| P3 | 再发 `W:SN=SNANOTHER1` | `RET:FAIL:sn exists`（重启后防呆依然生效） |

> burn 计数口径：T2=1、T8 同值不计数、T9=2、T15=3。所以 P1 是 `burn=3`。

---

## 4. Flash 边界验证（可选，验证产线规范）

| # | 操作 | 预期 | 实际结果 |
|---|---|---|---|
| F1 | Luatools **只下载脚本**（不动 soc）后重启 | SN 保留 ✅（脚本 FOTA 不清 FSKV） | |
| F2 | Luatools **全量烧录 soc** 后重启 | SN 清空、`sn state=empty`（**符合预期**，所以产线必须先烧 soc 再写 SN） | |

---

## 5. 结果记录

| 测试项 | 通过数 / 总数 | 失败项（填 #） | 备注 |
|---|---|---|---|
| 启动日志（§1） | / 3 | | |
| COM4 指令 T1~T15 | / 15 | | |
| 持久化 P1~P3 | / 3 | | |
| Flash 边界 F1~F2 | / 2 | | |

---

## 6. 常见问题对照（已按真机实测结论重写）

| 现象 | 原因 / 处理 |
|---|---|
| **`E/main Lua VM exit!! reboot in 15000ms`，设备每 15s 重启** | **`main.lua` 末尾少了 `sys.run()`**。main.lua 结束时不进主循环，LuatOS 就判定脚本已结束并重启。已修复：`main.lua` 最后必须调用 `sys.run()`，且它之后不能写任何语句。（注：在任务里加保活循环**无效**，必须是 `sys.run()`） |
| **`[SKIP] sn_core not loaded: module 'sn_core' not found`** | require 必须用**字面量**：`pcall(require, "sn_core")` ✅，`load(name)` 这种变量传递 ❌——LuatOS 静态扫描不到，文件不会进包 |
| **`E/fskv call fskv.init() first!!!`** | 该固件 fskv 用前必须显式初始化。已在 `sn_store_fskv.lua` 加载时调用 `fskv.init()` |
| **`sn_store_fskv.lua:44: bad argument #1 to 'tonumber'`** | fskv 未初始化时 `get()` 不返回值，导致 `tonumber()` 收到 0 个参数。已改为先接变量再转换 |
| **库判断不要用 `type(x) == "table"`** | 实测该固件核心库全是 `userdata` 形态（`uart/fskv/mobile/mcu/log/mqtt/json`）。用 table 判断会把可用的库误判为缺失。已统一走 `corelib.lua`（table/userdata 都认） |
| **合并失败：`文件 xxx.lua 存在多余的 require "mobile", 请删除引用,核心库不需要require`** | Luatools 合并检查是**文本扫描**：同一行出现 `require` 和核心库名就中招，**注释里也算**。规避办法：核心库名用变量间接引用（如 `local LOG_LIB = "log"`），或干脆不要在同名行出现 |
| 日志没有 `I/` 级别标签，变成 `[I] xxx` | `log` 库取不到时自动退化为 `print`，内容不变。该固件 `log` 是 userdata，正常能取到 |
| 发指令完全没反应 | ① TX/RX 接反（应交叉）② 没勾「发送新行」③ 波特率不对 ④ UART ID 不对 |
| 日志出现 `uart.setup failed! id = 4` | 固件不支持该 UART ID → 改 `main.lua` 里 `pcall(prov.init, 4)` 的数字（Air780EP 上 UART0 被日志口占用） |
| `R:SN` 返回 EMPTY 但明明写过 | 写过 SN 之后又全量刷了 soc → FSKV 被擦，重烧 soc 后必须重新写 SN |
| T8 同值写入也有 burn 日志 | 不该出现 → 说明幂等分支没走到，把日志发我 |
| 日志里 mqtt 一直重连报错 | 已按"先不联调平台"关闭 mqtt_demo，正常不该再有 mqtt 噪音 |

---

## 7. 全部通过后的结论

T1~T15 + P1~P3 全过 = 设备端 SN 管理闭环成立：
**上电加载 → 串口烧录 → 读回校验 → 唯一性防呆 → 持久化 → 重启恢复 → 锁死保护**。

之后进入平台联调时需要做三件事：
1. 填 `mqtt_demo.lua` 的 host/port/账号，并去掉 `main.lua` 里 stage 7 的注释
2. 参考工程实测：mqtt 库还需要 `_G.sysplus = require("sysplus")`，且 `mqtt` 全局可能为 nil，需判空
3. `report.lua` 届时会随 `mqtt_demo` 一起进包（它只被 mqtt_demo 引用），用于给上报 payload 注入 `sn`/`sn_status`/`chip_uid`
