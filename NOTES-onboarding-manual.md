# onboardingMode = "manual" 已实现

## 结论（2026-10-09 与平台确认）

| 档位 | 上报的 onboardingMode | 平台行为 |
|---|---|---|
| `sniff`（旁听档） | `sniff` | 跳过"对本地自建设备无效的配置快照推送" |
| `pollpull`（平台拉取档） | `platform` | 照常推 ConfigSnapshot |
| `poll`（手工配置档） | `manual` | **等待人工在平台上配置，不推任何东西** |

关键事实（平台确认）：
- `manual` 模式下平台**不推任何东西** —— 不是"跳过快照"，是根本不发
- 手动档连的是**同一个平台 broker**（`dz.voltkun.com`），所以 hello 发过去有人收

## 实现要点

`send_hello()` 的判据用 `poll_slot()` 而不是 `get_mode()`：

```lua
local onboard = get_mode() == "sniff" and "sniff"
    or (poll_slot() == "poll" and "manual" or "platform")
```

`get_mode()` 对 `poll` 和 `pollpull` **都返回 `"poll"`**，区分不了手配和拉取；
`poll_slot()` 返回 `"poll"`/`"pull"`，正是"当前在采哪份配置"，与 `manual`/`platform`
一一对应。

手动档的触发链路（`pollpull`/`sniff` 原本就有，不用改）：
1. `ctrl.switch_mode` 进 `poll` 档 → `iot.hello()`（新增导出，只发一次不等应答）
2. `task_main` 已连接分支的"连接后补发"：`hello_at == 0` 时发，覆盖所有非 idle 档。
   这一条是必须的 —— 进模式那一刻 `set_manual` 刚触发断开重连，步骤 1 那次 hello
   往往是静默失败的
3. `on_mqtt` 的 conack 分支把 `hello_at` 清零。`reset_state()` 只在 `start()` 时跑，
   不断线重连不清的话，重连后步骤 2 的分支永远不成立

周期重发**仍然只有 pollpull 档**做（`HELLO_RE_S`=30min）：sniff 档没有"未拿到配置"
这个状态，手动档平台不推东西，发了只会无意义地刷新档案。

## 曾经为什么不实现

文档原文只定义了 `sniff` 的行为，`manual` 收到会怎样没有写。当时担心三种可能：
和 `sniff` 一样跳过推送（报了没坏处）/ 跳过 hello 建档（永久失联）/ 拒 hello。
借 `platform` 也不会造成实际问题（`poll` 档不订 `config/get`，推了也收不到）。
向平台确认后上述担忧都不成立，才补上。

## 相关
- `lua/README.md` 的 hello 小节有完整的两时机说明
- `lua/core/config.lua` 的 `HELLO_RE_S` / `HELLO_BACKOFF_S` 是 hello 重发参数
