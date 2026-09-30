# VKBox 网关配置工具（前端软件）

Air780EP 485 采集设备的 PC 端配置软件。Electron + serialport 实现，
通过 USB 虚拟串口（VUART_0，Windows 下表现为 COM 口）与设备通讯，
用 electron-builder 打包成 Windows `.exe`。

四大功能：**SN 写入**（产线工具负责，本工具只读展示）、**485 轮询采集**、
**485 旁听嗅探**、**MQTT 上报**。

## 零、怎么运行（先看这里）

### 方式 1：双击启动脚本（推荐）

```
start.bat
```

### 方式 2：命令行

```bat
cd /d D:\VKBox_Lite\VKBoxLite_sniff\frontend
npm start
```

`npm start` 等价于 `electron .`。

### 方式 3：直接调 electron.exe

```bat
D:\VKBox_Lite\VKBoxLite_sniff\frontend\node_modules\electron\dist\electron.exe .
```

### ⚠️ node_modules 是 junction，不是真实目录

本目录**没有自己的 node_modules**，而是用 **junction（目录联接）** 指向：

```
D:\VKBox_Lite\VKBoxLite_poll\frontend\node_modules
```

两个工程的 `package-lock.json` MD5 完全一致（`E280EADD99E6967BFAB2914C1FF735F4`），
依赖树相同，故直接复用：electron **31.7.7** + serialport **12.0.0**
（`SerialPort.list` 为 function，匹配 `main.js` 的 v10+ 分支）。

> 原工程已装好依赖，但本会话沙箱禁止 npm spawn 子进程（`spawn EPERM`），
> 无法在此处执行 `npm install`，所以用联接复用。

**删联接必须用 `rmdir`（不带 `/S`）**：

```bat
:: 查看是不是 junction
dir /AL D:\VKBox_Lite\VKBoxLite_sniff\frontend

:: 删掉联接（只删联接本身，不动原工程真实数据）
rmdir D:\VKBox_Lite\VKBoxLite_sniff\frontend\node_modules

:: 重新创建
mklink /J D:\VKBox_Lite\VKBoxLite_sniff\frontend\node_modules D:\VKBox_Lite\VKBoxLite_poll\frontend\node_modules
```

**绝不能用 `Remove-Item node_modules -Recurse -Force` 或资源管理器删除** ——
对 junction 而言那是删真实数据，会把 `VKBoxLite_poll/frontend` 的依赖一并删掉。

想要独立依赖，在有网络且 npm 可正常 spawn 的机器上：`rmdir` 联接后执行 `npm install`。

### 连接设备

1. 插 USB → 设备管理器出现 **COM32**（LuatOS `uart.VUART_0 = 32`）
2. 软件里「刷新」→ 选 COM32 → 「打开串口」（115200 8N1）
3. 「读取设备信息」应填出 SN/IMEI/ICCID/CSQ/项目/版本/服务器

### 常见现象

| 现象 | 说明 |
|---|---|
| 首页无"存储空间"一栏 | 已移除。Air780EP base 25.11 实测 `type(rtos.fsinfo) ~= "function"` 且无 `fs` 库，取不到剩余空间 |
| 首页无"本地落盘"一栏、poll模式无"本地存储"面板 | **本地落盘功能已整体移除**（按需求，poll 模式不做本地保存）。设备端 `data/store.lua`、`R:DISK`、`W:STORE`、`R:STAT.store` 段及寄存器"落盘阈值"列均已删除。采集数据只走内存最新值（R:VAL）与 MQTT 上报 |
| 标签页只有 4 个 | poll模式 / sniff模式 是合并后的结果：原「串口配置」改名 **poll模式**，原「实时报文」改名 **sniff模式**，原「MQTT上报」页取消 |
| poll模式内有两个子标签 | 「串口1（485总线）」+「MQTT配置」，MQTT 内容已从串口1下面移到独立的「MQTT配置」子标签 |
| poll模式有"读取配置"和"拉取配置"两个按钮 | 「读取配置」= R:CFG + R:REG 回填表单；「拉取配置」= 通过 MQTT 从平台拉配置并回填表单（需先配好 MQTT 服务器地址和端口），同样不自动保存 |
| 点「拉取配置」提示"请先配置 MQTT 服务器地址/端口" | 拉取走 MQTT。先在首页或「MQTT配置」子标签填好服务器地址和端口并保存，再点拉取 |
| 首页的 MQTT 地址端口和「MQTT配置」页是什么关系 | 同一份配置的两个入口。首页只改地址/端口（保存时先读全量再合并，不会冲掉用户名和 topic）；完整配置（含 ClientID、hello/发布/订阅 topic）在「poll模式 → MQTT配置」子标签 |
| MQTT 显示"平台拒绝连接(CONACK 0x05 未授权)" | broker 拒绝了这个连接，**不代表一定要用户名密码**。排查顺序：① 首页看「实际使用」那行的 clientId，格式是否平台要求（如 `S&<SN>&12&1`）② 端口是否 MQTT 端口 ③ 设备是否已在平台注册 ④ 确实有账号再补用户名密码。详见 `../lua/README.md` 的「MQTT 连不上排查」 |
| 点「拉取配置」提示"平台未下发配置(超时)" | 设备已连上 MQTT 并发过 hello，但平台 15s 内没回。检查平台是否在线、topic 是否匹配、SN 是否已烧 |
| 拉取成功了但平台还在反复推配置 | 正常。回执 U6 要等用户点「保存配置」才发；没点就说明这套配置还没被确认。「连接与上报状态」的 **配置回执** 显示次数，为 0 = 尚未回执 |
| 拉取成功后「下行订阅」只有 1 条 | 没连上 broker。连上后固定 4 条（config/get + function/get + property/set + property/get） |
| 拉取后有的点是中文乱码/别名栏莫名变成 id | 平台把中文 `name` 按 GBK（非 UTF-8）下发。设备判为非法 UTF-8 后退回 id 并提示"N 个平台别名不可用已退用 id"，同时日志有 `alias 非 UTF-8(平台编码问题), 退回 id: xxx`。MQTTX 独立订阅同样看到乱码 → 是平台的编码问题，不是设备；要平台侧改成 UTF-8 |
| 拉取后某条寄存器少了，状态行说"忽略 1 条" | 该条平台配置不合法（如 `dataType` 用了 `-CDAB` 这类非大端字节序后缀、`address` 越界、`id` 含非字母数字），明细在"忽略"的 toast/日志。不会整包失败 |
| 485 页顶部出现黄色横幅"平台重新下发了配置" | 平台侧点了「重新下发配置」按钮，设备已接住并解析好，暂存在内存里等确认。点横幅「查看并保存」或用「拉取配置」把表单填上，检查完点「保存配置」才真正写入设备并向平台回执。详见「平台主动重新下发配置」 |
| 横幅说"解析失败"没别的反应 | 设备认出了这是配置包但读不懂（`configSnapshot` 里缺字段/`tsl.properties` 为空等），原因在横幅文案里，明细看设备日志 `push parse fail: xxx`。不会静默 |
| 横幅点「忽略」后又想看看 | 忽略只对当前这一份生效。平台再点一次「重新下发」（`push_n` 会变）横幅会重新弹；或者直接点「拉取配置」也能看到已解析好的那份 |
| 下拉框没有 COM32 | USB 未插好/未上电；或设备日志停在 `VUART task: 等待 USB 枚举...`，等 2~3 秒再刷新 |
| 串口被占用 | Luatools / ssCOM 正开着同一 COM 口，先关掉 |
| 打开白屏 | junction 断了，按上文重连或 `npm install` |

---

# 以下为原始文档


## 一、目录结构

```
frontend/
├── package.json         依赖与打包配置（electron / electron-builder / serialport）
├── .npmrc               npmmirror 镜像配置
├── main.js              Electron 主进程：串口枚举/打开/关闭/按行收发
├── preload.js           桥接层：仅暴露 window.serial 最小 API
├── protocol.js          设备协议编解码（浏览器/Electron 通用，含 8 种数据类型解码）
└── renderer/
    ├── index.html       界面：4 个标签页
    └── app.js           业务逻辑：串口/指令/配置/模式切换/报文视图/MQTT
```

## 标签页结构

| 标签页 | 内容 |
|---|---|
| **首页** | 运行状态总览 + MQTT 服务器 |
| **运行模式** | idle / poll / sniff 三卡片切换（互斥）+ 开机默认模式 + 当前运行详情 |
| **poll模式** | 两个子标签：**串口1（485总线）**（串口参数 + 参数列表）、**MQTT配置**（MQTT 连接参数 + 连接与上报状态） || **sniff模式** | 总线报文实时视图（REQ/RSP/ERR/配对标注 + 类型筛选）+ 轮询表推断 + 总线诊断 |

> 原「串口配置」「MQTT上报」「实时报文」三个页已合并/改名：poll模式内用子标签区分
> 「串口1（485总线）」与「MQTT配置」，「实时报文」改名为 sniff模式。

## 二、运行与打包

```bash
# 1. 安装 Node.js（>= 18）后，在 frontend 目录执行
cd frontend
npm install

# 2. 开发调试（弹出窗口）
npm start

# 3. 打包 Windows 安装包 (.exe)
npm run dist            # 输出 NSIS 安装包到 dist/
npm run dist:portable   # 或输出绿色单文件 exe
```

> **国内网络注意**：`.npmrc` 已配置 npmmirror 镜像。若 `npm install` 仍报
> `RequestError: read ECONNRESET`（electron 下载二进制被重置），先删掉
> `node_modules` 和 `package-lock.json` 再重试；或临时挂代理：
> ```bash
> npm config set proxy http://127.0.0.1:端口
> npm config set https-proxy http://127.0.0.1:端口
> ```
> 若杀毒软件锁文件导致 `EPERM ... rmdir`，退出杀软或换目录重装。

> 浏览器预览：直接用 Chrome/Edge 打开 `renderer/index.html` 可看界面
> （自动进入 mock 模式，返回假数据，不依赖 Node/串口）。

## 三、界面说明（5 个标签页）

| 标签页 | 用途 |
|---|---|
| **首页** | 运行状态总览（模式/轮询任务/数据点/MQTT/看门狗/报文）+ **MQTT 服务器地址与端口** |
| **运行模式** | idle / poll / sniff 三卡片切换（互斥）+ 开机默认模式 + 当前运行详情 |
| **poll模式** | 两个子标签：**串口1（485总线）**（485 串口参数 + 参数列表）、**MQTT配置**（MQTT 连接参数 + 连接与上报状态；密码框带小眼睛可显隐） |
| **sniff模式** | 总线报文实时视图（REQ/RSP/ERR/配对标注 + 类型筛选）+ 轮询表推断 + 总线诊断 |

> **485 模式互斥**：UART1 是 485 总线唯一物理口，poll（主机，要发帧控 DE）和
> sniff（旁听，只收不发）一次只能跑一个。开机默认 **idle**（不主动驱动总线），
> 由 `W:MODE=idle\|poll\|sniff` 切换，设备端 `mbus_ctrl.lua` 负责先停旧的再启新的。
> `W:MODE=stop` 是 `idle` 的别名，兼容旧脚本。

### 485 页「未保存改动」提示

改通讯参数或参数列表后不会自动写设备，以前界面没有任何提示，切个页面就丢了。
现在的机制：

| 环节 | 行为 |
|---|---|
| 检测 | `cfgSnap()` 把 4 个串口参数 + 3 组 radio + 参数表 5 个可编辑列归一化成快照，和上次「干净」快照（读配置/保存/拉取/导入之后）比对。`input`/`change` 事件代理挂在 `#sp-s1` 上；增行/删行走 DOM 操作，在 `addRegRow`/`deleteRow` 里手动标脏 |
| 提示 | 「保存配置」按钮文字变 **保存配置 *** 并加橙色 `.dirty` 底色，状态栏同步提示 |
| 拦截 | **读取配置 / 拉取配置 / 应用推断 / 导入配置** 这四个会整份覆盖表单的动作，脏状态下先弹自绘确认框（`guardUnsaved()`），取消则一个指令都不发 |
| 清除 | 保存成功、读配置完成、拉取回填、导入完成后重新取基线 |

> 只读的「值」「时间」两列不参与比对——`R:VAL` 刷新它们不该触发未保存提示。
> 从没读过配置时（`cfgSnap === null`）没有基线，不算脏，所以打开串口后直接点读取配置不会弹框。

### MQTT 页「未保存改动」提示

和 485 页同一套机制，改 MQTT 连接参数后不保存也不提示：

| 环节 | 行为 |
|---|---|
| 检测 | `mqSnap()` 把 MQTT 页 12 个字段（地址/端口/SSL/用户名/密码/ClientID/hello topic/上报 topic/下行 topic/上报间隔/允许无 SN/持久会话）+ 首页 MQTT 那一栏 2 个输入框（地址/端口）归一化成快照，和上次「干净」快照比对。14 个字段逐个挂 `input`/`change` 监听；程序回填（`renderMqtt`/`fillMqHome` 赋 `.value`）不触发这两个事件，不会误标脏 |
| 提示 | MQTT 页「保存」变 **保存 ***、首页「保存并重连」变 **保存并重连 ***，两边同时加橙色 `.dirty` 底色，状态栏同步提示 |
| 拦截 | **MQTT 页刷新 / 恢复默认 / 首页保存** 三个会整份覆盖表单的动作，脏状态下先弹自绘确认框 |
| 清除 | 保存成功、读 MQTT 完成后重新取基线 |

两个和 485 页不一样、必须额外处理的点：

1. **首页那 2 个输入框会被 5s 定时刷新打**。`renderHome()` 每 5s 调一次，
   里面 `fillMqHome()` 会回填地址/端口。原来的 `fillOk()` 只挡
   "焦点正在这个输入框里"，用户点一下别处焦点就丢了，下一轮刷新照样把改了
   一半的值冲成设备旧值，而且毫无提示。所以 `fillMqHome` 里额外加了一道
   `if (!S.mqDirty)` —— 脏了就不覆盖。切到别的标签页时 `tab0` 不可见，
   `fillOk` 本来就会挡住，两道一起才全覆盖。

2. **首页保存的合并基线来自设备，不是表单**。`saveHomeMqtt()` 先发
   `R:MQTT` 拿全量配置，再只把地址/端口两个字段打补丁进去。
   如果用户在 MQTT 页改了 topic、用户名、密码没保存，这里一保存就把那些
   改动冲掉了——而且是从设备旧值冲的，连提示都没有。所以这个入口也必须守卫。

> `readMqtt()` 有 `quiet` 参数：保存/上报/重连之后的回读、以及刚连上串口
> 还没有基线时传 `true`，跳过确认框。这些不是用户主动发起的读取，弹框会
> 弹第二次。用户主动点的「刷新」、切到 MQTT 子标签、首页「刷新」不传，
> 照常守卫。

### 密码框小眼睛

MQTT 密码以前是纯 `type="password"`，加密看不了，配错了只能猜。现在
密码框右侧加了一个眼睛按钮：

| 环节 | 行为 |
|---|---|
| 切换 | 点一下在 `password` / `text` 之间互换，同时按钮 `title` 在「显示密码」「隐藏密码」之间换 |
| 图形 | 单枚 SVG 眼睛（轮廓 + 瞳孔），密码已显示时叠一道斜杠变「隐藏」态，由 `.pw-eye.show .slash` 控制 `display` |
| 安全 | 按钮是独立的 `type="button"`，不是 input 的兄弟节点，点了**不抢输入框焦点**；切换只改 `type`，值和光标位置都不动 |

> CSS 上有个坑：`.form-row input[type="password"]` 的特异性是 (0,1,1,1)，
> 高于 `.pw-wrap input` 的 (0,1,0,1)。所以给 input 让出右侧空间必须写成
> `.form-row .pw-wrap input{padding-right:26px}`，直接写 `.pw-wrap input`
> 会被 `padding:4px` 覆盖，长密码的文字会钻到眼睛图标底下去。
> `.pw-wrap` 自身带 `flex:1; max-width:400px`，所以包一层**不改变输入框宽度**，
> 布局和以前完全一致。

## 四、与设备的通讯协议

协议沿用设备既有风格：**一行一条指令 → `RET:xxx` 应答，`\r\n` 结尾**。
波特率 115200 8N1（与 sn_prov_uart 的 VUART_0 一致）。
成功应答一律带 key（`RET:CFG=OK`），前端按 cmd 匹配；失败为 `RET:FAIL:<cmd>:原因`。

### 设备信息 / 配置

| 前端动作 | 指令 | 应答 | 说明 |
|---|---|---|---|
| 读设备信息 | `R:INFO` | `RET:INFO={json}` | SN/IMEI/ICCID/CSQ/RSRP/版本/项目/服务器/波特率/从机/寄存器数/锁状态 |
| 读 poll 配置 | `R:CFG` | `RET:CFG={json}` | `{cfg:{baud,databits,parity,stopbits,slave,interval_ms,timeout_ms,regs},src}` |
| 保存 poll 配置 | `W:CFG={json}` | `RET:CFG=OK` / `RET:FAIL:CFG:原因` | 串口参数变化自动重启轮询任务；间隔/寄存器表热更新 |
| 读寄存器表 | `R:REG` | `RET:REG=[json]` | `[{addr,count,name,alias,dtype}]` |
| 保存寄存器表 | `W:REG=[json]` | `RET:REG=OK` | 校验通过后热加载 |
| 读 sniff 配置 | `R:SNIFFCFG` | `RET:SNIFFCFG={json}` | 旁听模式的串口参数 |
| 保存 sniff 配置 | `W:SNIFFCFG={json}` | `RET:SNIFFCFG=OK` | 旁听运行中会自动重启生效 |
| 读实时值 | `R:VAL` | `RET:VAL=[json]` | `[{name,addr,value,hex,ts,dtype}]`，设备已解好值 |
| 读运行状态 | `R:STAT` | `RET:STAT={json}` | `{mode,data,guard,mqtt}` 全量状态；`mqtt` 段另带 `push_pending/push_n/push_seen/push_err`（平台主动重推横幅用，见下） |
| 恢复默认配置 | `W:RST` | `RET:RST=OK` | 清除设备保存的 485/MQTT 配置 |

### 平台配置拉取

| 前端动作 | 指令 | 应答 | 说明 |
|---|---|---|---|
| 发起拉取 | `W:PULLCFG` | `RET:PULLCFG=started` | 设备向平台发 hello 并等配置下发；未连 MQTT 直接回 `RET:FAIL:PULLCFG:原因` |
| 查拉取状态 | `R:PULLCFG` | `RET:PULLCFG={json}` | `{state,msg,poll,skipped,renamed,mqtt,msg_id,replied,src,seen,push_pending,push_n,push_err}`；`state` = `helloing`/`waiting`/`done`/`fail`；`renamed` = 平台别名不可用、已退回 id 的条目名单；`src` = `pull`/`push`，`push` = 这份是平台主动重新下发的 |

拉取流程与字段映射详见 `../lua/README.md` 的「平台配置拉取」章节。要点：

- 设备 publish `hello` 到 `mqttcfg.hello_topic`（默认 `/sys/thing/gw/config/hello/{SN}`，可在「MQTT配置」页的 **hello Topic** 输入框改），payload 带 `topicFormat:"v3"` 与 `onboardingMode:"platform"`
- conack 时订 4 条 gw 前缀下行：`config/get` + `function/get` + `property/set` + `property/get`（全量见「连接与上报状态」的 **下行订阅** 一栏）。`config/get` **无条件订**：业务订阅 topic 被改到别处时，拉取链路仍要通
- 非本机 SN（或 `{SN}-{n}`）的下行直接丢弃，不会拿去写寄存器
- 只提取 `commInterfaces`（串口参数）与 `tsl.properties`（寄存器表），其余全部丢弃
- 拉取结果里回的 topic：上报 `/sys/thing/node/property/post/{SN}-1`，下行 `/sys/thing/gw/config/get/{SN}`
- **平台不下发 clientId / 订阅 topic / 上报间隔**（V3 契约），这三样仍是设备自拼
- **拉取只回填表单，不自动保存**：需用户点「保存配置」才写入设备
- **回执 U6 也要等用户保存**：`parse()` 成功后只提示"点保存后回执"，此时不回；
  用户点「保存配置」（`W:CFG`）成功才向 `/sys/thing/gw/config/reply/{SN}` 发
  `{"msgId":<下发原值>,"code":200,...}`。用户不保存就不回执，平台会继续重推
  ——这是预期语义，不是卡住。「连接与上报状态」的 **配置回执** 一栏显示已回执次数
- 拉取成功后 topic 由平台接管：三个 topic 换成设备拼好的成品，并自动关掉
  「手动配置」（详见下面「MQTT topic 手动/自动切换」）
- **平台中文名乱码 → 别名退回 id**：平台若把中文 `name` 按 GBK 而非 UTF-8 下发（MQTTX
  独立订阅同样看到乱码，与设备无关），设备判为非法 UTF-8 会把 `alias` 退回 `id`，并把
  该 id 放进 `renamed`。状态行会多说一句"1 个平台别名不可用已退用 id（Ua，中文需平台
  改 UTF-8）"——别当成 bug。要平台侧改成 UTF-8 才能拿到真中文名

### 平台主动重新下发配置

平台侧有「重新下发配置」按钮：一点就主动往 `/sys/thing/gw/config/get/{SN}` 再推一份
`configSnapshot`，**不等设备问**。设备必须接住——以前会静默丢掉（没有 `cmd`、
没有 `items/value`，走完所有分支什么都不发生，平台以为发了、设备什么都没干）。

横幅触发链（注意为什么必须挂在 `R:STAT` 上）：

```
平台重推 → handle_downlink 认出 configSnapshot → 解析成功 → push_pending=true
        → R:STAT 的 mqtt 段带 push_pending/push_n/push_seen/push_err
        → 前端 5s 轮询 readHome → renderPushBanner → 485 页顶部黄条
```

`R:PULLCFG` 只在用户点「拉取配置」时才查，等不到这个横幅，所以横幅的数据挂在
5s 轮询的 `R:STAT`（`readHome` 每 5s 一次）上。

| 横幅状态 | `R:STAT.mqtt` 字段 | 横幅表现 |
|---|---|---|
| 正常待确认 | `push_pending:true, push_n:1, push_seen:<秒>` | "平台重新下发了配置，已等待 N 秒/分钟。检查后点「保存配置」才会写入设备并向平台回执" |
| 连推多份 | `push_n >= 2` | 文案加「（第 N 份）」，msgId 取最新一份 |
| 解析失败 | `push_err:"原因"` | "平台推送了配置，但设备解析失败：原因（见设备日志）" |
| 已保存回执 | `push_pending:false` | 横幅消失 |

要点：

- **pending 的推送不覆盖正在进行的拉取**。拉取握手途中（`connecting`/`helloing`）到达的
  推送会先寄存，等状态机走到 `waiting` 立刻消费——直接当推送处理会把 `state` 改成
  `done`、把握手掐断，用户点了「拉取配置」却拿到一份可能是旧的推送
- **横幅「查看并保存」= 复用「拉取配置」按钮**：点它走同一个 `pullCfg()`，但会先看
  `R:STAT` 的 `push_pending`，为 true 时**跳过 `W:PULLCFG` 握手**直接读 `R:PULLCFG`
  ——否则会把设备已解析好的结果冲掉，白等 20s(连接)+15s(下发)
- **「忽略」只对当前这一份生效**：`push_n` 不变就一直不弹；平台再推一份（`push_n`
  变大）照旧弹
- **横幅撤掉的三个时机**：用户在 `R:PULLCFG` 看到这份（拉取状态机 `done`）/ 保存并
  回执成功 / 平台不再重推。回执失败（未连接）时不撤，还得提示用户
- **横幅不自动写入设备**。解析成功后只暂存在设备内存里，用户点「保存配置」才会
  落 fskv 并重启轮询——和前端拉取完全同一套语义

### MQTT topic 手动/自动切换

「MQTT配置」子标签左上方有个 **手动配置** 按钮，控制下面三个 topic（hello Topic /
发布 Topic / 订阅 Topic）到底由谁定：

| 模式 | 按钮样子 | 三个 topic | 输入框里放什么 | 保存时 |
|---|---|---|---|---|
| 自动（默认） | 灰色「手动配置」 | **只读**，设备拼好 | 成品，SN 已代入 | **不下发**三个 topic 键，设备保留自己的模板 |
| 手动 | 蓝色「关闭手动配置」 | 可编辑 | 带 `{sn}` 的模板 | 三个 topic 原样下发 |

要点：

- **切换模式会顺手把输入框内容也换掉**。自动态放成品（`.../property/post/11802026092600016-1`），
  手动态放模板（`.../property/post/{sn}`）。不换的话用户会把成品存回设备，
  把 `{sn}` 模板冲成固定 SN，以后换机器就废了。换完自动重新取脏快照，
  不会误报「有未保存更改」。
- **切模式前先过未保存守卫**。自动→手动、手动→自动都会弹自绘确认框
  （和「恢复默认」「首页保存」同一套 `guardUnsaved`），确认才切。
- **拉取配置成功会强制关掉手动配置**。平台说了算：`R:PULLCFG` 回来的
  `mqtt` 段（`hello`/`pub`/`sub` 三个，都是设备按 SN 拼好的）直接回显→三个输入框，
  同时 `S.mqManual` 置回 `false`。现场手改的 topic 被平台覆盖是预期行为。
- **「恢复默认」会先切手动模式**。自动模式下保存不写 topic，不切手动的话
  点了恢复默认也改不动 topic，属于白点。
- **自动模式下 `{sn}` 缺失提示跳过**。那三个值是设备给的，没什么可提。
- 每行 topic 右边有「设备拼 / 手动」小字，和按钮颜色双保险，切过去一眼能看到。
- 模式只在本次会话有效（`S.mqManual`，不落盘）。重新打开软件回到自动态，
  但设备已存的 topic 模板还在，回显不会丢。

| 前端动作 | 指令 | 应答 | 说明 |
|---|---|---|---|
| 读模式+状态 | `R:MODE` | `RET:MODE={json}` | `{mode,busy,poll,mon,write}` |
| 切模式 | `W:MODE=idle\|poll\|sniff` | `RET:MODE=OK` | 先停旧的再启新的，互斥；`stop` 为 `idle` 别名 |
| 开机默认模式 | `W:BOOTMODE=idle\|poll\|sniff` | `RET:BOOTMODE=OK` | 掉电重启后生效 |

### 写寄存器

| 前端动作 | 指令 | 应答 | 说明 |
|---|---|---|---|
| 写单寄存器 | `W:WRITE=<slave>,<addr>,<value>` | `RET:WRITE=OK` | 功能码 06，入写事务队列 |
| 写寄存器(JSON) | `W:WRITEJ={"slave":1,"addr":100,"value":2201}` | `RET:WRITEJ=OK` | 同上 |

> 写事务经**注入轮询任务**实现：总线唯一主人永远是 poll 任务，写请求不直接碰 UART，
> 只是在两个寄存器事务之间的安全点优先排空队列。不需要 pause/resume 握手，
> 也不存在接收回调被外部覆盖导致轮询永远超时的风险。
> 写前需先 `W:MODE=poll`；队列上限 8 笔，满时返回 `RET:FAIL:WRITE:写队列已满(8), 稍后重试`。

### MQTT

| 前端动作 | 指令 | 应答 | 说明 |
|---|---|---|---|
| 读 MQTT 配置+状态 | `R:MQTT` | `RET:MQTT={json}` | `{cfg,hello,pub,sub,ready,err,stat}`；`hello`/`pub`/`sub` 是设备按 SN 拼好的成品 topic |
| 保存 MQTT 配置 | `W:MQTT={json}` | `RET:MQTT=OK` | 保存后自动断开重连 |
| 只重连不动配置 | `W:MQTTRC` | `RET:MQTTRC=OK` | 等价设备侧 `iot.kick()`，改完参数想立即生效又不想整份覆盖时用 |
| 立即上报一次 | `R:REPORT` | `RET:REPORT=OK` | 调试用 |
| 读上报状态 | `R:IOTSTAT` | `RET:IOTSTAT={json}` | 连接/序号/已上报/失败/错误 |

> MQTT 配置页按钮顺序：**恢复默认** / **立即上报一次** ‖ **重连** / **保存**（后两个靠右）。
> 「保存」= 保存配置 + 重连（原「保存并重连」改名，功能不变）；「重连」只重连、不写配置。
> 有未保存改动时「保存」变「保存 **」并加橙色底色，首页「保存并重连」同步标记。

> **deviceId 用 SN**：topic 里的 `{sn}` 占位符会被替换成设备 SN（`{id}` 为旧写法，仍兼容）。
> 多台设备共用不含 SN 占位符的 topic 会导致数据互相覆盖，前端保存时会弹窗警告。
> 未烧 SN 时设备默认**拒绝建连**（`allow_no_sn=false`），可在配置里打开调试后门。

### sniff / 总线诊断

| 前端动作 | 指令 | 应答 | 说明 |
|---|---|---|---|
| 读最近解译帧 | `R:FRAMES[=n]` | `RET:FRAMES=[json]` | n 默认 20，最大 50 |
| 推断轮询表 | `R:INFER` | `RET:INFER={json}` | `{regs,slaves,stat}`，从监听到的 REQ 帧反推 |
| 应用推断结果 | `W:APPLYINFER` | `RET:APPLYINFER=OK` | 把推断出的寄存器表写入 poll 配置 |
| 静默侦听总线 | `R:SNIFF=ms` | `RET:SNIFF=帧数` | ms 500~15000，不切模式纯收听 |
| 手动发帧 | `W:TX=<hex>` | `RET:TX=OK` | 验证发送链路（DE 自动切换） |
| 手动采一轮 | `R:POLL` | `RET:POLL=OK` | 调试用 |

### 产线 SN 指令（原有，本工具不使用）

| 指令 | 应答 | 说明 |
|---|---|---|
| `R:SN` | `RET:SN=xxx` | 读 SN |
| `R:ID` | `RET:ID=imei:..;uid:..;sn:..;state:..;lock:..` | 读身份 |
| `W:SN=xxx[,FORCE]` | `RET:OK` | **烧 SN，仅产线工具使用** |
| `C:SN` / `LOCK:SN` / `UNLOCK:SN` | `RET:OK` | 清号 / 锁定 / 解锁 |

设备端由 `lua/svc/vcom.lua` 的 `reg_cmds()` 注册上述前端指令，
通过 `lua/sn/sn_prov_uart.lua` 的 `dispatch()` 未知指令分支转发（SN 指令逻辑零改动）。

## 五、寄存器表字段约定

| 字段 | 含义 | 约束 |
|---|---|---|
| 寄存器地址 | Modbus 寄存器起始地址 | 0~65535 |
| 数据类型 | 解码方式 | uint16/int16（1 寄存器）、uint32/int32/float32（2）、uint64/int64/float64（4） |
| 寄存器个数 | 从起始地址起**连续读取的寄存器个数** | 1~125，必须是类型宽度的整数倍 |
| 标识符 | 数据点名称，上报字段名 | ≤16 字符，只能含字母数字下划线 |
| 参数名称 | MQTT 上报 `name` 字段的中文名 | 留空则 `name` 等于标识符 |
| 值 | 只读，设备解好的实时值 | 读失败时显示原始 hex 或留空 |
| 时间 | 只读，该值采集时刻 | 设备 `os.time()` 秒级时间戳，显示为 HH:MM:SS |

> float32/float64 按 IEEE754 解析；int64/uint64 超出 2^53 时前端用 BigInt
> 精确显示（设备端 Lua 走双精度会有精度损失，可看 hex 字段核对）。

## 六、设备端模块（lua/）

| 文件 | 职责 |
|---|---|
| `lua/bus/mbus.lua` | 协议层：CRC16 / 帧构造解析 / 8 类型解码 / DE 时长精算 / CRC 试探切帧 |
| `lua/bus/mbus_poll.lua` | Modbus 主机轮询：任务代际令牌、早返回响应、写事务注入队列、DE 手动控制、残帧清理 |
| `lua/bus/mbus_mon.lua` | 旁听嗅探：DE 恒低纯接收、CRC 试探切帧、REQ/RSP 配对 + no-match 兜底、本地存储 + VCOM 透传 |
| `lua/bus/mbus_ctrl.lua` | 模式仲裁：poll/sniff/stop 互斥切换，开机默认 idle |
| `lua/bus/collector.lua` | 纯数据层：dataCache / 帧缓存 / ring buffer / on_update + on_store 回调 |
| `lua/cfg/cfg_store.lua` | 统一配置中心：poll / sniff / sys 三类配置的 fskv 持久化 + 校验规范化 |
| `lua/iot/mqtt_cfg.lua` | MQTT 配置持久化 + `{sn}`/`{id}` 占位符解析 + allow_no_sn 开关 |
| `lua/iot/iot_manager.lua` | MQTT 编排：指数退避重连、订阅、值变化驱动上报、下行 REPORT/WRITE |
| `lua/svc/vcom.lua` | 前端指令层（全部 R:/W: 指令注册） |
| `lua/main.lua` | 启动编排 8 个 stage（顶部含 require 兼容层） |
| `lua/svc/guard.lua` | 看门狗 + 运行监控 |
| `lua/bus/data_store.lua` | 本地 JSONL 落盘 + 双文件轮转 |
| `lua/core/config.lua` | 全工程可调参数默认值 |
| `lua/core/corelib.lua` | 库安全获取 + log 降级（公共底座） |

> `lua/sn/` 下的 `sn_core.lua` / `sn_prov_uart.lua` / `sn_store_fskv.lua` /
> `identity.lua` / `sn_luhn.lua` / `report.lua` 为 SN 产线原有文件，**逻辑零改动**；
> 仅 `sn_prov_uart.lua` 有 `MAX_BUF` 64→2048（长配置行不被截断）和
> 一行 `_G.vcom_handle` 未知指令钩子。
>
> 21 个 `.lua` 按功能分 6 个子目录存放，`require` 写成 `"子目录/模块名"`；
> `main.lua` 顶部有兼容层，子目录加载失败会自动退回平铺名。
> 详细目录划分与烧录注意事项见 `lua/README.md`。

## 七、联调步骤

1. `frontend` 目录 `npm install && npm start`；
2. 设备用 USB 线连接 PC，Luatools 烧录 `lua/` 全部脚本（**含子目录**）+ Air780EP 固件；
3. 工具里「刷新」→ 选中设备虚拟串口 COM 口 → 「打开串口」；
4. 「读设备信息」：左侧 SN/IMEI/ICCID/信号/版本/项目 应填充；
5. **轮询模式**：「运行模式」页点「轮询 poll」→「应用所选模式」→「串口配置」页「读实时值」；
6. **旁听模式**：「运行模式」页点「旁听 sniff」→「实时报文」页应实时刷出总线报文；
   「推断轮询表」→「应用到轮询配置」可省掉手工问客户要寄存器地址；
7. **MQTT**：「MQTT配置」子标签填 MQTT 服务器地址 →「保存」→ 连接状态变「已连接」；
   改完参数想立即生效又不想整份覆盖时，点「重连」；
   下行发 `{"cmd":"REPORT"}` 可触发设备立即上报；
8. 「保存配置」后断电重启，验证配置是否保留。

## 八、已知限制 / 后续

- **单从机模型**：寄存器表没有从机地址字段，poll 全部访问 `config.SLAVE_ADDR`（默认 1）；
  多从机需在寄存器表加 `slave` 字段并改 `mbus_poll.lua` 组帧处；
- **sniff 暂不上报 MQTT**：本期只本地存储 + 前端查看，后续再考虑；
- `R:INFO` 需要较新固件；老固件会自动回退 `R:ID`+`R:SN`（只填 SN/IMEI）；
- ICCID/CSQ/RSRP 依赖 `mobile` 库，未插卡或未注册网络时为空；
- 写寄存器目前只支持功能码 06（单寄存器）；功能码 16（多寄存器）设备端
  `mbus_poll.enqueue_write_multi()` 已实现，前端指令后续补；
- 4G 未附着网络时 MQTT 会指数退避重连（1s→2s→4s…封顶 60s）。
