# PC 产线 SN 烧录工装

替代 SSCOM 手工发指令的一键式产线工具。设备端见 `../soft_sn_demo/`。

## 环境要求

- Python 3.10+（开发用 3.13）
- 依赖：`pyserial`（已 vendored 到 `vendor/`，无需 pip install）

## 运行

```powershell
python main.py
```

## 打包成 exe

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

产物：`dist\SnBurner.exe`（单文件，目标机无需装 Python）

## 目录

```
main.py            入口 + 主窗口
config.py          配置读写（config.json）
sn_rule.py         SN 规则引擎 + Luhn 校验位（与设备端 sn_luhn.lua 同算法）
serial_port.py     串口层 + 自动识别设备口
device.py          设备指令封装
allocator.py       计数器 + 四道防重防线
ledger.py          台账 CSV
ui/                界面
vendor/pyserial/   内置 pyserial
build.ps1          PyInstaller 打包
```

## 图标（标题栏 / 任务栏 / 弹窗左上角）

图标全部**内嵌成 base64**，运行时零文件依赖（`--onefile` 要把数据文件解压到
`%TEMP%\_MEIxxxxxx`，实测本环境 Temp 不可写）。改图标的流程：

| 图标 | 源文件 | 生成脚本 | 内嵌产物 |
| --- | --- | --- | --- |
| 主窗口 / exe 文件图标 | `../Lcon.png` | `_make_icon.py` → `_make_icon_data.py` | `app.ico` / `_icon_data.py` |
| 条形码弹窗 | `../qrcode.png` | `_make_dialog_icon_data.py` | `_dialog_icon_data.py` |
| 返修弹窗 | `../bug.png` | 同上 | 同上 |
| 返修密码弹窗 | `../lock-password.png` | 同上 | 同上 |

改了仓库根的 png 记得重跑对应生成脚本。`build.ps1` 会在打包前自动重跑，
`_st_winicon.py` 会把内嵌数据和磁盘原图逐字节比对，对不上直接 FAIL。

⚠️ **别再写死绝对路径去取图标**。以前弹窗图标写的是
`D:/VKBox_Lite/VKBoxLite_sn/qrcode.png`，仓库一换目录那个路径就没了，
`iconphoto` 再也没被调用过 —— 弹窗左上角只剩 Tk 默认的那根羽毛。
另外 `wm iconbitmap` / `wm iconphoto` 不带 `-default` 时只作用于那一个窗口，
新建的 `Toplevel` 不会继承，主窗口有图标而弹窗没有就是这么来的。

## 自检（build.ps1 打包前全过才放行）

| 脚本 | 盯什么 |
| --- | --- |
| `sn_rule.py` / `_st_all.py` | SN 规则、config、allocator、串口层、设备协议、烧录 |
| `_path_check.py` | 打包后 config.json / data\ 落在 exe 同级，不丢台账 |
| `_smoke_ui2.py` | 滚动布局、MQTT 三字段 |
| `_chk_ui_layout.py` | 控件顺序、按钮状态、**弹窗左上角图标**（用 Win32 查真实图标句柄） |
| `_chk_port_watch.py` | 串口插拔自动刷新 |
| `_chk_lock_only.py` | 手动上锁全路径 |
| `_st_mqtt.py` | W:MQTT 指令层 |
| `_st_winicon.py` | 标题栏 / 任务栏 / 弹窗图标（含"磁盘无图时靠内嵌数据"） |
| `_st_connect.py` | 连接流程（自动识别串口那条分支，见下） |
| `_byte_verify_exe_icon.py` | exe 的 PE 图标资源 == app.ico（逐帧逐字节） |
| `_chk_bundle.py` | **产物终验**：exe 里的图标数据与代码 == 当前源码 |

⚠️ **`_st_connect.py` 的来历**：打包后的 exe 在全新安装下连不上设备，报
`TypeError: _emit() missing 1 required positional argument`。根因跟串口无关 ——
`device.find_device_port` 的 log 回调是 **1 个参数**，`ui_app._emit` 是 **2 个参数**，
以前直接传 `self._emit` 进去就炸了。之所以一直没暴露，是因为老机器的
`config.json` 里存了具体串口，走的是另一条分支。
`device.py` 的 `LogFn1` 和 `_st_connect.py` 就是为了钉死这个契约。

## SN 格式

```
16 位主体 + 1 位 Luhn 校验位 = 17 位纯数字
主体 = 产品代号(4) + 生产日期 YYYYMMDD(8) + 流水号(4)
例：1180 20260925 0001 -> 校验位 8 -> 11802026092500018
```

设备端与 PC 端使用同一套 Luhn 算法，两边实现互相印证
（设备端 `sn_luhn.lua`，PC 端 `sn_rule.py`，共用 `test/vectors.json` 里的已知向量）。
