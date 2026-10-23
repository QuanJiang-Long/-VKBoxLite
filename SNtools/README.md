# soft_sn_demo

Air780EP 软 SN（业务层 SN）demo 工程。SN 存于模组 Flash 的 FSKV 键值分区，**非 Modem/OTP 硬件固化区**；固件维持 `V2026_Air780EP_1.soc` 不变。

架构与决策详见 [`docs/soft_sn_arch_v2.md`](../docs/soft_sn_arch_v2.md)。

## 文件清单

| 文件 | 层 | 职责 |
|---|---|---|
| `main.lua` | 入口 | 上电初始化编排（顺序即依赖顺序） |
| `corelib.lua` | 工具 | LuatOS 库统一获取（核心库取全局、非核心库才 require，避开 Luatools 合并检查） |
| `sn_core.lua` | L1 | SN 核心：三态状态机 / 校验 / 缓存 / 写策略 / 追溯，全局入口 `get_device_sn()` |
| `sn_store_fskv.lua` | L0 | FSKV 存储适配器（唯一碰 fskv 的文件，未来换 OTP 只换它） |
| `sn_prov_uart.lua` | L2 | COM4 产线烧录通道（唯一写 SN 的入口） |
| `identity.lua` | L2 | 设备身份策略：clientid 降级链 + 身份结构 |
| `report.lua` | L3 | 上行报文统一注入（`sn` / `sn_status` / `chip_uid`） |
| `mqtt_demo.lua` | 演示 | MQTT 接线骨架，主题/账号按平台改 |

## 上电流程

```
sn_core.init() → sn_prov_uart.init(4) → identity.init() → boot 摘要日志 → 周期告警 → mqtt_demo.start()
```

烧录通道不依赖联网：连不上平台也能烧 SN。

## COM4 产线指令（115200 8N1）

| 指令 | 应答 |
|---|---|
| `R:SN` | `RET:SN=xxx` / `RET:SN=EMPTY` / `RET:SN=INVALID` |
| `W:SN=SN20260924001` | `RET:OK` / `RET:FAIL:原因` |
| `W:SN=xxx,FORCE` | 强制覆盖（返修场景，平时默认拒绝异值覆盖） |
| `C:SN` | 量产默认无响应（`clear_enable=false`） |
| `LOCK:SN` | `RET:OK`，之后拒绝一切写入 |

**SN 唯一性**：一台设备任何时刻只有一个生效 SN。已有 SN 时写入不同值返回 `RET:FAIL:sn exists`；同值重复写幂等返回（不碰 Flash）。每次成功写入累加 burn 计数并记录首次烧录时间，可在日志/`R:SN` 之外追溯。

## 量产注意

1. **产线顺序**：先烧 soc 底层 + 业务脚本 → 上电写 SN。先写 SN 再刷底层，FSKV 被擦，SN 必丢。
2. 脚本 FOTA（只更 lua）SN 保留；USB 线刷 .soc 会清 FSKV，属预期。
3. `fskv.save()` 只在写成功路径执行一次，运行期间禁止定时/循环保存。
4. 出厂建议执行 `LOCK:SN` 冻死 SN；返修需先解锁。
5. 平台侧没有任何写 SN 的代码路径——SN 只在设备端通过 COM4 写入。

## PC 单测（无需硬件）

```
cd test
lua run_all.lua        # 或 luajit run_all.lua
```

覆盖校验、状态机、唯一性防呆、写后回读、烧录锁、串口半包/超长缓冲、clientid 降级链、上报注入，共 35 例。

## 部署

用 LuatOS 工具把 `soft_sn_demo/` 下的 **8 个** lua 文件下载到模组脚本区即可；`mqtt_demo.lua` 里的 `M.host` / `M.port` / 账号密码按实际平台修改。

**关于库的引用**：所有 LuatOS 库（`sys`/`log`/`uart`/`fskv`/`mobile`/`mcu`/`mqtt`/`json`）都通过 `corelib.get("xxx")` / `corelib.log()` 获取，不要直接写加载核心库的语句——Luatools 脚本合并检查会因此中断合并。**注意该检查是文本扫描：任何一行里同时出现 `require` 和核心库名（连注释里）都会被拒**，所以核心库名要用变量间接引用（见 `corelib.lua` 里的 `LOG_LIB`）。
