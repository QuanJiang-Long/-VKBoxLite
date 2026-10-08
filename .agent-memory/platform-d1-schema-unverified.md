# 【已解决】空 configSnapshot = sniff 模式的正常终态

## 结论（2026-10-08 17:15 实测证明）
`devices[0].addr 非法` 的根因**不是 schema 不匹配**，而是平台下发的是一份
**空配置快照**：

```json
{"msgId":"hello-1192443f","ts":1791450936,"configSnapshot":{
  "tsl":{"properties":[]},"commInterfaces":[],"devices":[],
  "mqttPlatform":{"host":"","port":0,"username":"","password":"","topic":""}}}
```

三个数组全空，整包 193B。sniff 模式下平台**永远**推这个 —— 设备档案本地自建
（doc: `source='sniff'`），平台互斥守卫不覆盖现场调通的配置。

## 我走过的弯路（不要重犯）
一听"字段解析失败"就猜字段名不一样，去加 `slaveId`/`slave`/`address` 容错。
**完全没有命中**，因为 `devices` 里连一个元素都没有。猜之前先把原始报文打出来，
这次就是靠 `body=` 那行日志一步定位的。

## 触发时机（与 doc 完全一致）
1. hello 后 ~1s 推一次
2. 每次 U2 拓扑上报后再推一次
共 5 次空包（17:15:37 / 17:15:39 + 重推）。回 U6 后应停止重推。

## 修复
- `pullcfg.parse_snap`：三数组全空 → 返回 `{empty=true, msg_id=...}` 而非报错
- `iot.lua` 两处消费点（`pull_step` waiting 分支 / `recv_push`）：`r.empty` →
  按 done 收尾 + `reply_config()`，`p.msg` = "平台未下发配置，本地嗅探自建生效"
- `reply_config` 的 `message` 改用 `p.msg`，不再恒写 "config applied"（撒谎）

## 推论
**sniff 档无法验证"平台拉配置 → 自动保存"链路**，那儿的寄存器表本来就来自
`mon.infer()`。要验证拉取链路必须切 platform 档，且平台侧已建档。
