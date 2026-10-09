# onboardingMode 的正确用法（2026-10-08 修正）

## 文档原话
> onboardingMode sniff/platform/manual；平台见 sniff 跳过对本地自建设备无效的配置快照推送

## 我们以前的错误理解
早期代码固定报 `"platform"`，注释写"报 sniff 平台会直接不搭理"。**错**：
拿到精确说明后确认，平台见 `sniff` 只是跳过 ④ 的配置快照推送，
① hello 本身照常处理（建/更新网关设备、回写 fw/hw/ip）。

固定 `platform` 的真实代价（17:15 实测）：sniff 档每次 hello + 每次拓扑上报后，
都收到一份 193B 空壳快照（`devices`/`tsl.properties`/`commInterfaces` 全空），
还要为它回 U6，不回执平台每 1s 重推一次。

## 现在的实现（iot.lua send_hello，2026-10-09 更新）
```lua
local onboard = get_mode() == "sniff" and "sniff"
    or (poll_slot() == "poll" and "manual" or "platform")
```
- `sniff` 档 → `"sniff"`，发完 hello 直接 `pull_finish("done", ...)`，
  **不进 waiting**（等也等不到，干等只会显示"平台未下发配置(超时)"的假故障），
  也**不回 U6**（没收到 D1 就没有 msgId 可核销）
- `pollpull` 档 → `"platform"`，照常等 D1
- `poll` 手配档 → `"manual"`（平台确认：manual 模式下**不推任何东西**，
  且手动档连的是同一个平台 broker，所以 hello 发过去有人收）

⚠️ **判据必须用 `poll_slot()` 不能用 `get_mode()`**：`get_mode()` 对 `poll` 和
`pollpull` **都返回 `"poll"`**，区分不了手配和拉取。`poll_slot()` 返回
`"poll"`/`"pull"`，正是"当前在采哪份配置"，与 `manual`/`platform` 一一对应。
写错过一次，后果是拉取档报成 `manual`，平台不推配置，前端显示超时。

## 手动档的 hello 触发链路（2026-10-09 新增）
手动档以前完全不发 hello，平台看不到设备在线。现在三条：
1. `ctrl.switch_mode` 进 `poll` 档 → `iot.hello()`（新导出，只发一次不等应答）。
   `M.hello` 必须声明在 `send_hello` **之后** —— `local function` 是词法作用域，
   写在前面会解析到全局 nil，运行时报 "attempt to call a nil value"。
   `check_lua.py` 的前向引用检查会抓到这个
2. `task_main` 已连接分支的"连接后补发"：`hello_at == 0` 时发，覆盖所有非 idle 档。
   **这一条是必须的** —— 进模式那一刻 `set_manual` 刚触发断开重连，第 1 条那次
   hello 往往是静默失败的
3. `on_mqtt` 的 conack 分支把 `hello_at` 清零。`reset_state()` 只在 `start()` 时跑，
   **不断线重连不清的话，重连后第 2 条的分支永远不成立** —— 平台看到的是设备
   中途消失再回来而没有任何 hello，manual 档会被判离线

周期重发**仍然只有 pollpull 档**做：sniff 档没有"未拿到配置"状态，手动档平台
不推东西，发了只会无意义地刷新档案。

## deviceId
按文档：IMEI → 网卡 MAC → `"unknown"`。平台校验 `gateway_imei`，不一致**拒 hello**。
我们报 IMEI（实测 17:15 hello 被接受，~1s 后有响应），取不到才报 `"unknown"`，
**不报空串**。

## 30min 重发 hello（2026-10-08 已实现）
- `cfg.HELLO_RE_S = 1800`，在 `task_main` 已连接分支、`sys.wait(1000)` 之后判
- 三个前提全满足才发：`S.hello_at > 0`（本连接发过 hello，否则开机白发一次）、
  `get_mode() == "pollpull"`、`not pulling()`（握手中不发）
- 不走拉取状态机：平台响应由 `recv_push` 落盘，不影响前端正在显示的拉取结果
- 只有 pollpull 档周期重发：sniff 档没有"未拿到配置"状态，手动档平台不推东西
- hello 抽成了 `send_hello()`（pull_step 和周期重发共用，返回 `ok, onboardingMode, err`）
- hello 发送失败按 `cfg.HELLO_BACKOFF_S = {1,3,9}` 退避重发，3 次都失败才报错
  （不无限重发，否则"平台连不上"被藏起来）

## 踩过的坑：connecting → helloing 必须清 deadline
`p.deadline` 在 connecting 态是"等连接"上限（+20s）。不清就进 helloing 的话，
helloing 分支的"退避中就等着"会把**第一次 hello 也当成退避期跳过**，用户白等
一个 `PULL_CONNECT_MS`。已改为进 helloing 时 `p.deadline = 0; p.hello_try = 0`。

## 防线的两层（都不删）
1. `onboardingMode=sniff` → 平台根本不推（根因）
2. `parse_snap` 认出三数组全空的快照 → 返回 `{empty=true}` 按成功收尾 + 回 U6
   （兜底：切换模式的瞬间、平台还没处理新 onboardingMode 时仍会收到空包）
