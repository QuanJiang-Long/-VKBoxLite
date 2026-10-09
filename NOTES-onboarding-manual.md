# 平台文档（2026-10-09 用户贴图确认）：三档的 topic / 链路差异

## 原文要点

| 维度 | sniff | platform | manual |
|---|---|---|---|
| onboarding 链路 | 照走，上电即报到；嗅探设备被互斥跳过，不被平台覆盖 | 必走，按快照建/改设备 | **不走**（用户界面手配，档案来源=用户） |
| 设备档案来源 | 本地自建（嗅探来源，锁定） | 平台配置下发快照应用 | 用户 Web 界面 |
| 谁先知道档案 | 网关先知道（嗅探得出）→ 上报让平台也自动建 | 平台先知道（预配+快照源）→ 下发网关落库 | 网关先知道（本地手配）；平台不预知，靠上报 auto-provision 补建 |
| 拓扑上报 | 接受后指纹变化自动发 | 应用后指纹变化自动发 | 设备上线后自动发 |
| 数据上报 topic | \| \| \| **三路同**：`/sys/thing/gw/property/post/{sn}` + `/sys/thing/node/property/post/{gwSn}-{n}` \| \| \| |
| 下行 topic | \| \| \| **三路同**：`/sys/thing/gw/function/get/{target}` 等 4 条 \| \| \| |
| ack 回执 | \| \| \| **三路同**：`/sys/thing/gw/function/post/{target}` \| \| \| |
| 平台鉴权 | onboard 下发（或出厂预烧录）：clientId 兼容 4/5/6 段 + `gw_<sn>` + 密码 | 同左（同一条控制连接） | 用户手填 broker + clientId 兼容 4/5/6 段 + 账密；同样受白名单三条件约束 |
| 平台侧门槛 | 网关产品已发布 + 凭证 + devcom_gateway 三条件 | 同左 + 子设备产品/映射表 | 同左；username 非 `gw_` 老形态可跳过认证白名单，但 auto-provision 门禁仍查表 |
| 数据通道 | \| \| \| **三路同**：复用同一条 MQTT 控制连接，同 broker 不建第二条 \| \| \| |

## 核心结论

**三档在 topic 层面完全统一**，差别只在「档案从哪来」和「要不要走 onboarding 握手」。
所以 topic 全部收敛成 `core/config.lua` 的 `PLATFORM_*_TOPIC` 固定常量，
`mqttcfg.pub_topic` / `sub_topic` 两个配置项已删除。

## 本次按这张表改了什么

| # | 改动 | 文件 |
|---|---|---|
| 1 | 回退手动档 hello（文档：manual 不走 onboarding 链路，平台靠上报 auto-provision 补建，不是靠 hello）。`onboardingMode` 回到 sniff/platform 两态，`M.hello()` 导出和 `ctrl` 里的调用删掉，`task_main` 的连接后补发分支和 conack 的 `hello_at=0` 也一并回退 | `iot.lua` `ctrl.lua` |
| 2 | `build_subs()` 除 idle 外三档同一份 4 条 gw 平台前缀（原来 poll 手动档只订用户填的那条） | `iot.lua` |
| 3 | U4 数据上报改走 `cfg.PLATFORM_PUB_TOPIC` + `-{n}`，不再吃 `S.pub` | `iot.lua` |
| 4 | 删 `pub_topic`/`sub_topic` 配置项 + 前端两个输入框 + 「生效发布/生效订阅」两个状态栏 + `.auto-only` CSS | `mqttcfg.lua` `app.js` `index.html` |

## 踩过的坑：topic 可配 = 数据发去文档外

曾把发布/订阅两条做成 `mqttcfg.pub_topic` / `sub_topic` 可配。用户按自己的命名
（`/10/<sn>/property/post` 这类）填了一份，设备就老老实实发去那儿，而平台按
`/sys/thing/...` 收 —— **两边谁都不知道，没有任何报错**，症状只是"平台收不到数据"。
MQTTX 订阅用户填的那个 topic 也看不到，因为 `publish()` 还会拼 `-{n}` 后缀
（`base .. "-" .. it.idx`），实际发的是 `/10/<sn>/property/post-1`。

教训：**平台文档说"三路同"的字段，不要给它留配置项**。可配只会让三个档画出
不同的清单，平台那头对不上，而这种故障没有任何一侧会报错。

## 相关
- `lua/README.md` 的「topic」与「conack 时的订阅清单」两节已按本表重写
