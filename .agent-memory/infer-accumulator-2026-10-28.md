# 推断表改成常驻累加器 + 主动推送（2026-10-28，12-fix-6）

## 用户需求（2026-10-28）

> 「现在前端点击刷新发现每次的推断表都不一样的，这个逻辑需要重新思考设计下，
> 嗅探总线时，总线上可能会有新的地址上。我想需要的效果有新地址嗅探到，
> 会往推断表中添加新的，却不用手动去刷新前端的推断表，设备自动给前端推更新后的推断表。
> MQTT上报也同理。另外前端sniff推断表里的"从机地址"列不要了，改成"序号"列。」

用户拍板的四个点：

1. **序号 = 发现顺序**（不是按地址排）；
2. **没应答的地址也进表**，逐个地址判（不是按从机整批过滤）；
3. **结构变了才推**，值的变化靠 30 秒慢刷补；
4. **限流**：只在 sniff 面板打开时推。

## 为什么老实现会「每次刷新都不一样」

老 `M.infer()` 每次拿 `collector` 的**最后 10 帧**重建整张表。现场总线一圈轮询
48 个地址，10 帧只够看见 5 个请求 → 表在两组地址之间来回跳：

- 前端每点一次「推断轮询表」看到的都不一样；
- `topo_sig()` 的指纹跟着每 30 秒变 → 平台每 30 秒重建一次物模型。

## 实现要点

### 设备端（`lua/bus/mon.lua`）

- 常驻累加器：`infer_acc[slave][addr] = 行`，`infer_order` = 行数组（发现顺序）。
- `acc_row()` 建行（超 `MAX_INFER_ROWS`=128 就不建，计 `stat.infer_clamped`）、
  `acc_note_req()` 记命中、`acc_note_rsp()` 回填值/类型/置信度。
- `M.infer(force)` 改成**读累加器**（不再重建）；`M.start()`/`M.stop()` 清空累加器。
- `M.set_infer_watch(on)` / `M.take_infer_dirty()` / `M.infer_watch()`：推送开关。
- `mon.status().infer_rows` = `#infer_order`。

### 推送链路

```
前端 → 设备:  W:INFERWATCH=1     (sniff 面板打开)
设备 → 前端:  RET:INFERWATCH=1
设备 → 前端:  RET:INFER_PUSH={regs:[...], slaves:[...], ignored:N, stat:{...}}
```

- `cmd.lua`：`W:INFERWATCH` 指令 + `M.push_infer()`（`_G.cmd_push_infer` 全局钩子，
  避开 cmd↔iot 的循环依赖）。
- `iot.lua`：1 秒巡检里 `if mon.infer_watch() and mon.take_infer_dirty() then pcall(_G.cmd_push_infer) end`。
  ⚠️ 这行**必须在【MQTT 连没连的分支之外】** —— 推给前端跟 MQTT 无关。

### 前端（`frontend/renderer/app.js`）

- ⚠️ `RET:INFER_PUSH` 必须**在在途指令匹配之前**判掉。两条原因：
  ① 键名不能跟 `R:INFER` 撞（撞了推送会被当成那条指令的应答）；
  ② 下面的 `!resp.ok` 会把**任何**失败应答算作在途指令的应答 —— 推送撞上
  在途指令时会把那条指令判成失败。
- 序号列 = 行在表里的位置（前端自己编号，设备不存 seq 字段）。
- `activateTab` 开关 watch；30 秒 `inferTimer` 慢刷补值。

## ⚠️ 内存：行字段数必须 ≤ 8（本次最值钱的发现）

Lua 表的哈希槽按 **2 的幂**走，实测（PC 模拟器）：

| 字段数 | 6/7/8 | 9 | 10 | 11 | 12/13 |
|---|---|---|---|---|---|
| 每行字节 | 203 | 363 | 363 | 364 | 364 |

**第 9 个字段就把 8 槽撑成 16 槽（+78%）**。所以推断行只留 8 个字段：
`slave/addr/fc/hits/answered/dtype/conf/value`。三个能推出来的不存：

- `seq` → 序号 = 行在表里的位置；
- `status` → 前端按 `conf` 推（≥80 ok / ≥60 review / 其余 uncertain），
  「没应答」用 `answered=false`；
- `count` → 数量 = `dtype` 的宽度，前端按类型推。

48 行的实测占用：**18.3KB（11 字段）→ 10.8KB（8 字段）**。

### ⚠️ `iot.attach_names()` 必须复制，不能就地改

它给行加 `id`/`name` = 第 9/10 个字段 → 就地改 = +7.7KB 常驻堆。
现在改成**复制一份**再挂名字（复制只发生在 `R:INFER`/推送这种稀疏调用上，
复制出来的表马上变垃圾）。

### `tests/lua/test_infer_acc.lua` 钉住的两条

- 行字段数 ≤ 8；
- 48 行占用 < 12KB。

改行结构时这个测试会先炸。

## 其他坑

- 老表按「32bit 合并成一行」，新表是**每 16bit 槽一行**（32bit 占两行）——
  跟 `dataCache`/U4 的点集一一对应，平台模型和数据才对得上。
- `node_json` 的 `MAX_PROPS` 还是 64：推断表能到 128 行，但拓扑只上报前 64 个。
- 前端「数量」列现在按 dtype 推（uint16=1 / 32bit=2 / 64bit=4）。
