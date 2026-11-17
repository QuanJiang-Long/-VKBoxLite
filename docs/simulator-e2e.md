# 前端 ↔ LuatOS PC 模拟器 全流程联调手册

> 目的：不接真机（也不用 com0com 虚拟串口）就能把 **配置工具前端** 跑通
> 「连设备 → 读信息 → 切模式 → 读/改/存配置 → 导出/导入 → 旁听识别」整条链路。
>
> 结论先行：**官方 V2039 PC 模拟器是裁剪版**，
> `pcconf.json` 不会被加载（日志：`依赖裁剪模式下不拉取外部配置文件 pcconf.json`），
> 所以 `uart_udp` 那条 UDP 通道用不了；唯一可用的字节通道是
> `--webc=<port>` 起的 **Web Console**（只有 `uart31` 一条通用通道）。
> 前端主进程已经把它包装成一个伪串口，渲染层零改动。

---

## 1. 一次性准备

1. 引擎：`.simulator/LuatOS_PC/luatos-pc-64bit.exe`（+ `luat_uart_i686.dll`）。
2. 建一个**临时联调目录**（不要污染仓库），把真实固件拷进去：

   ```powershell
   $SCR = "$env:TEMP\vkbox_sim_device"
   robocopy firmware $SCR /E /NJH /NJS /NDL /NFL /NP
   Copy-Item .simulator\LuatOS_PC\luatos-pc-64bit.exe, .simulator\LuatOS_PC\luat_uart_i686.dll $SCR
   ```

3. **把命令口从 32 改到 31**（只改临时目录，仓库固件不动）：

   | 文件 | 原值 | 联调值 | 原因 |
   |---|---|---|---|
   | `sn/prov.lua` | `local UART_ID = uart.VUART_0` | `local UART_ID = 31` | 真机 VUART_0 = 32；模拟器里 32 被 GNSS mock 占用 |
   | `svc/cmd.lua`  | `local UART_ID = uart.VUART_0` | `local UART_ID = 31` | cmd 自己另存了一份 UART_ID，只改 prov 会出现「收得到、回包看不到」 |

   > 两个文件都要改：`prov` 负责收，`cmd` 负责发。只改一个的症状是
   > `R:MODE` 设备日志有 `prov cmd: R:MODE`，但 Web Console 里读不到 `RET:`。

## 2. 启动虚拟设备

```powershell
$p = Start-Process -FilePath "$SCR\luatos-pc-64bit.exe" -ArgumentList ".", "--webc=18921", "--noexit" `
       -WorkingDirectory $SCR -PassThru -WindowStyle Hidden `
       -RedirectStandardOutput "$SCR\stdout.log" -RedirectStandardError "$SCR\stderr.log"
$p.Id | Set-Content "$SCR\pid.txt"
```

自检：

```powershell
(Invoke-WebRequest http://127.0.0.1:18921/api/health -UseBasicParsing).Content
# {"ok":true,"service":"web-runtime-core"}
```

Web Console 只有两个有用端点：

```
POST /api/uart31/inject   {"direction":"rx","encoding":"utf8","payload":"R:MODE\r\n"}
GET  /api/uart31/console  → { ok, items:[{direction:"rx"|"tx", ts_ms, len, payload_utf8, payload_hex}] }
```

`payload_hex` 是 `\x52\x45...` 这种**转义文本**（不是原始字节），要自己解开。

## 3. 起前端

```powershell
$env:VKBOX_SIM_WEBC = '18921'          # 模拟器 Web Console 端口
$env:VKBOX_DOWNLOAD_DIR = "$env:TEMP\vkbox_dl"   # 可选：导出配置直接落盘，不弹系统保存框
cd frontend; npm start
```

串口下拉框里会多一项 **「模拟器 UART31 (127.0.0.1:18921)」**（`sim://127.0.0.1:18921/uart31`），
选中直接打开即可，后面的操作和真机完全一样。

## 4. 模拟器侧必备的前置动作

| 项 | 说明 |
|---|---|
| SN | 模拟器 fskv 是空的，先烧 SN：`W:SN=VL20261116001`（格式 VL+YYYYMMDD+序号，见 `sn/sn.lua`） |
| 模式 | 不了解设备当前档位时先发 `W:MODE=idle`，避免带着上次的 manual/sniff 状态开始 |
| 寄存器 | 空表不能存配置（前端提示「参数列表为空，请先添加寄存器」），先在 manual 页加一条 |

## 5. 已知限制（跑不通属于预期）

- **485 总线没有从站**：`poll` 会发标准 Modbus 帧（日志 `Tx s1 fc3 addr=1 ... raw=[01 03 00 01 00 01 d5 ca]`），
  但没有设备应答，所以 `sniff`/推断/`R:VAL` 只能验证到「发出去了、超时处理正常」。
  深度验证需要真 485 从站或额外写一个 Modbus 从站模拟器。
- **MQTT / 平台拉取需要网络**：模拟器没有 4G，`platform` 档拉配置、MQTT 上报都会失败（属预期）。
- **Web Console 的 history 是 64 条环形缓冲**：满了以后 `items.length` 恒为 64、头部被挤掉。
  取数据必须按 `ts_ms`（+同毫秒序号）推进，**不能按数组长度当游标**（否则会永远读不到新项，
  表现就是前端 `S.pending` 卡死、提示「上一条指令尚未返回」）。
- **模拟器脚本语法错会直接 minidump 退出**：`main.lua` 带 BOM 就会
  `E/fs 文件加载失败 main.lua ... unexpected symbol near '<\239>'` 然后崩栈，
  写文件时务必 UTF-8 **无 BOM**。
- **原生保存/选择文件框**：导出/导入走的是浏览器下载与文件选择框，
  无人值守跑自动化时用 `VKBOX_DOWNLOAD_DIR` + CDP 的 `Page.setInterceptFileChooserDialog`。

## 6. 自动化跑一遍（可选）

仓库里已经有脚本了，不用手写 CDP：

```powershell
node tools\sim_e2e.js --webc 18921 --launch
```

`--launch` 会自己拉起 Electron（带调试端口 + `VKBOX_DOWNLOAD_DIR`），
依次跑：页面就绪 → 枚举 → 打开 → 读信息 → 读模式 → 切 manual → 读配置 →
建测试点 → 存配置（W:CFG）→ 导出 JSON → 导入 JSON → 读实时值 → R:MEM →
R:NET → R:MQTT → 切 sniff + 推断 → 切回 idle（验证复位）→ 还原配置 → 关串口 →
页面错误汇总。

模拟器没有从站/4G/总线流量，所以读实时值、R:NET、MQTT 未就绪、推断这四步
会记 **SKIP**（属预期，不是失败）。真机用 `tools/real_device_e2e.js` 跑同一份
流程，见 [`docs/real-device-e2e.md`](real-device-e2e.md)。
