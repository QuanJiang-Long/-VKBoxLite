# 待办：onboardingMode = "manual" 尚未实现

## 现状
`lua/iot/iot.lua` 的 `send_hello()` 只报两个值：

```lua
local onboard = get_mode() == "sniff" and "sniff" or "platform"
```

| 我们的模式 | 上报的 onboardingMode |
|---|---|
| `sniff`（旁听档） | `sniff` |
| `pollpull`（平台拉取档） | `platform` |
| `poll`（手工配置档） | **`platform`（借用的，不是 manual）** |

## 为什么不现在做
文档原文只定义了 `sniff` 的行为：

> onboardingMode sniff/platform/manual；平台见 sniff 跳过对本地自建设备无效的配置快照推送

`manual` 收到之后平台会怎么处理，**文档没有写**。可能的行为包括：
- 和 `sniff` 一样跳过配置推送（那我们报了没坏处）
- 跳过 hello 建档（那我们会永久失联）
- 拒 hello

报一个行为未知的风险大于收益。当前借 `platform` 也没造成实际问题：`poll` 档本来就不订
`config/get`（`build_subs` 只在 `pollpull`/`sniff` 下订平台 topic），平台推了也收不到。

## 要做的时候
1. 找平台确认 `manual` 的确切行为，**重点是会不会拒 hello / 跳过建档**
2. 确认后把 `send_hello()` 改成三路：
   ```lua
   local ONBOARD = { sniff = "sniff", pollpull = "platform", poll = "manual" }
   local onboard = ONBOARD[get_mode()] or "platform"
   ```
3. 真机验证：`poll` 档进模式后， hello 仍被接受（有 `pullcfg hello ... mode=manual`
   日志且平台不报错），且 `pollpull`/`sniff` 两档行为不回退

## 相关
- `lua/README.md` 的 hello 小节有同样的映射表
- `lua/core/config.lua` 的 `HELLO_RE_S` / `HELLO_BACKOFF_S` 是 hello 重发参数
