# D2 服务调用 topic 切换 - 分步验证记录 (2026-10-19)

> 需求: D2 `/gw/function/get/{sn}` → `/gw/service/invoke/{sn}`; 新增 node 级
> `/node/service/invoke/{sn}-N` 订阅 (platform + sniff 两档, manual/idle 不动)。
> 平台侧已支持新 topic。分步验证, 每步一个 commit, 便于烧录对照。

## Step0: 基线 2151119 (旧 topic function/get, 4 条订阅)

- 烧录验证: 设备行为正常 ✅ (用户确认)

## Step1 (78343db, 已被 7467d9c revert): 一次全改 (service/invoke + node `-+`)

- **症状 (用户报告): 切到 platform 模式会断开 MQTT 连接** ❌
- 当时未抓到串口 log, 根因未确认; 嫌疑: broker 对 `{sn}-+` 通配订阅的处理

## Step2 (7549497): 仅改名 gw D2 topic, 不加 node 条

- OS log (设备 SN=VL20261019001, broker=dz.voltkun.com:1883, 2026-10-19 15:59):

```
15:59:36.843 I/user.iot subs changed by mode, reconnect:
            [/gw/config/get/VL…01 /gw/service/invoke/VL…01
             /gw/property/set/VL…01 /gw/property/get/VL…01]
15:59:37.119 I/user.iot conack ok, subscribed=true, topics=[同上 4 条]
15:59:38.829 I/user.iot pullcfg hello topic=/gw/config/hello/VL…01
15:59:39.843 I/user.iot pullcfg recv topic=/gw/config/get/VL…01 len=1232 (configSnapshot 6 regs)
15:59:40.953 I/user.iot pullcfg 自动保存并生效: 寄存器 0->6, msgId=hello-8a2a4520
15:59:40.953 I/user.iot config/reply {"code":200,"message":"config applied","status":"ok"}
```

- **结论: broker (dz.voltkun.com) 接受 service/invoke 订阅, 切 platform 不断连 ✅**
- R:STAT.aspect: connected=true / subscribed=true / replied=1 全程稳定
- 附注: 同段 log 485 轮询 addr=4096/4161/4160/97/141/142 全 `Rx n=0` timeout,
  与 MQTT 无关 (总线侧没收到仪表响应), 烧现场时留意总线接线/表是否在线

## Step3a (4ee142a): 新增 node 级精确订 {sn}-1 (5 条订阅)

- 烧录验证: 稳定 ✅ (用户确认, 切 platform 不断连)

## Step3b (4f0791d → d962314 revert): node 级订换 -+ 通配

- **烧录验证: 切 platform 断连复现 ❌**
- **定论: broker (dz.voltkun.com) 不接受 {sn}-+ 单层通配订阅**
- 设备端已回退到 Step3a 精确订版本; 通配方案弃用, 后续按档案从机逐条精确订

## 前端 (topics.js/mqtt.js 展示 + README + test_22) 待设备端全部验证通过后统一跟改
