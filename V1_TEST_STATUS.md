# V1 测试清单

## 测试状态总览

| 项目 | 状态 | 说明 |
|------|------|------|
| V1-1 boot idle 配置保留 | ✅ 通过 | 2026-11-06 测试 |
| V1-2 fskv.set 返回值检查 | ✅ 通过 | 2026-11-06 测试 |
| V1-3 MQTT 间隔调整 | ⏳ 待测试 | 无 4G 网络，暂时无法测试 |
| V1-4 sniff slave ID 修正 | ✅ 通过 | topic 后缀设计符合平台要求 |
| V1-4 拓扑上报间隔拆分 | ⏳ 待测试 | 无 4G 网络，暂时无法测试 |
| V1-5 send_gw_res 失败推进 | ⏳ 待测试 | 无 4G 网络，暂时无法测试 |
| SN 烧写+自动上锁 | ✅ 通过 | 2026-11-06 测试，INFER_PUSH 干扰已修复 |

---

## 详细测试记录

### V1-1 boot idle 配置保留 ✅

**测试步骤**：
1. 配置 manual 模式（3 个寄存器）并保存
2. 设置 `W:BOOTMODE=idle` 并重启设备
3. 切回 manual：前端应立即显示 3 个寄存器

**结果**：通过

**修复 commit**：
- `f3dde0b` debug: V1-1 boot idle 配置保留逻辑添加调试日志
- `0b0a174` fix(frontend): 切档后清除 cfgRead 标记，强制重新读取配置
- `a0e2af5` fix(frontend): readCfgSilent 用 R:CFG.regs 填充寄存器表
- `ac6bcf5` fix(frontend): readCfg 用 R:CFG.regs 填充寄存器表

---

### V1-2 fskv.set 返回值检查 ✅

**测试内容**：fskv.set 失败时正确返回错误，不再静默丢失配置

**结果**：通过

---

### V1-3 MQTT 间隔调整 ⏳

**待测试内容**：
- MQTT_INTERVAL_S: 120→180s (兜底上报间隔)
- MQTT_MIN_S: 30→60s (最小上报间隔)

**状态**：无 4G 网络，暂时无法测试

---

### V1-4 sniff slave ID 修正 ✅

**问题**：
- 前端显示 slave=2
- MQTT topic: `/sys/thing/node/property/post/VL20261019001-1`（后缀 `-1`）

**分析**：
- topic 后缀是**子设备索引**（第几个从机），不是**从机地址**
- 只有一个 slave=2 时，它是第 1 个，索引=1，topic 后缀=`-1`

**结果**：符合平台要求，topic 后缀用于区分同一网关下的多个子设备，与 Modbus slave ID 无直接关系

---

### V1-4 拓扑上报间隔拆分 ⏳

**实现内容**：
- 带 nodes：事件触发（首次/新增），30s 是分包节流
- 不带 nodes：定时保活，60s min / 180s fallback

**预期效果**：
- 流量减少约 50%（原 120 条/小时 → 约 60 条/小时）

**状态**：无 4G 网络，暂时无法测试

**修复 commit**：
- `1f9a352` feat(iot): 拆分拓扑上报间隔

---

### V1-5 send_gw_res 失败推进 ⏳

**待测试内容**：send_gw_res 失败时也推进 res_at，避免连续重试

**状态**：无 4G 网络，暂时无法测试

---

### SN 烧写+自动上锁 ✅

**问题**：
1. 烧写 SN 时收到意外应答：`RET:INFER_PUSH={...}`
2. 烧写后未能自动上锁（勾选了"烧写后自动上锁"）
3. 手动上锁正常

**根因**：
- SN 烧写流程：`W:SN=xxx` → `R:SN` 回读校验 → 自动上锁
- `RET:INFER_PUSH` 是设备主动推送，在 `R:SN` 应答前发出
- 烧写工具收到意外应答，校验失败，自动上锁不成功

**修复方案**：
- SN 操作期间暂停 INFER_PUSH 推送
- `prov.lua`: 新增 `sn_busy` 标记
- `cmd.lua`: `push_infer()` 检查 `prov.busy()`，为 true 时跳过推送

**结果**：通过，SN 烧写+自动上锁恢复正常

**修复 commit**：
- `e57f9ad` fix(sn): SN 烧写期间暂停 INFER_PUSH 推送

---

## 待办事项

1. **有 4G 网络后测试**：
   - V1-3 MQTT 间隔调整
   - V1-4 拓扑上报间隔拆分
   - V1-5 send_gw_res 失败推进

2. **V2 实施准备**：
   - V1 全部测试通过后，开始 V2（128 点支持，5 个 commit 需批量实施）
