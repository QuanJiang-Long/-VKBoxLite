# sniff 上报崩溃（OOM fatal）— 11-fix（2026-10-27）

## 现场
设备 SN `VL20261019001`，broker `dz.voltkun.com:1883`，sniff 档（波特率自动识别出 2400）。

两次崩溃，traceback 不同但同源：

| | 崩溃 A (16:30:37.587) | 崩溃 B (16:26:24.508) |
|---|---|---|
| 前一条日志 | `topology posted: 1209:{...}` | `gw meta posted: ...` |
| C 层帧 | `[C]: in field 'concat'` | `[C]: in field 'format'` |
| Lua 帧 | `iot.luac:1601` = **task_main** | 同 |
| 结果 | `Lua VM exit!! reboot in 15000ms` | 同 |
| 崩溃时 `heap.used` | 108640/203040 (53%) | **77092/203040 (38%)** |

## 三个必须记住的结论

### 1. `rtos.meminfo("sys")` 不是 Lua 堆
`iot.lua` 的 `heap_info()` 读的是**系统内存**。拿它判断"Lua 堆还剩多少"是不准的。
真 Lua 堆用量要 `collectgarbage("count")`（单位 KB）。
现场显示 38% 就 fatal —— 说明**不是堆总量不够**，是某一次具体分配拿不到
（LuatOS 的堆是固定内存池 + 独立 big block，大字符串要的是**连续大块**，
碎片化后总量够也未必拿得到）。

### 2. `pcall` 拦不住 LuatOS 分配器级的 OOM
`not enough memory for buffer allocation` 是**分配器 fatal**（C 层打印 + 自己抓
stack traceback + VM 退出），不是 Lua error。`pcall` 只能拦普通 Lua error。
**真正兜底只能靠"少分配"。**

> 我在 `iot.lua` 里写过"包起来最多丢一次拓扑重发, 不至于重启"的注释 —— **那是错的**，
> 已改掉，别再照抄。

### 3. 历史那个"异常 qty 展开"不是这次的原因
README 内存章节记过同一个崩点（`[C]: in field 'concat'` ← `node_json` 的
`table.concat(props)`），当时归因于"总线上冒出 qty=65535 的脏帧 → 展开 6 万多项"。
**同址不同因。** 判据是 `mon.stat.infer_clamped`：现场两次都是 **0**，
说明 `clamp_qty`/`MAX_INFER_ROWS`/`MAX_PROPS` 三层封顶都在生效，没截断过。
**以后排查这个崩溃，先看 `infer_clamped` —— 不为 0 才走"异常 qty"那条线。**

## 真因：每轮两次 build_nodes
`task_main` 每轮：
```
topo_sig()   → build_nodes()   ← 第 1 次
send_topo()  → build_nodes()   ← 第 2 次 (签名变化时)
```
每次 `build_nodes()` = `mon.infer()`（重建整张推断表 + 排序）+ `alias_map()` +
每个从机一次 `node_json()`（props 数组）+ 两层 `table.concat`。
**白扔一半分配预算。**

## 11-fix 做了什么（`lua/iot/iot.lua` + `lua/bus/poll.lua`）

| # | 改动 | 效果 |
|---|---|---|
| 1 | `topo_sig()` 改为 `return sig, nodes`；`send_topo(nodes_in)` 复用 | 每轮 build **2 次 → 1 次**，峰值分配砍半 |
| 2 | `topology posted` 日志不再拼整串 sig（`len=` + `head=`） | 少一次 1.2KB 拷贝 |
| 3 | `node_json` 的 `MAX_PROPS` 128 → 64 | 单次最大分配 ~19KB → ~10KB |
| 4 | `send_topo` 加 pcall | 普通 Lua error 不再掀 task（**不是**防 OOM） |
| 5 | `build_nodes()` 加两行 `mem bn infer/nodes` 插桩 | 定位用，`collectgarbage("count")` 读真堆 |
| 6 | `poll.lua` 的 `hexspaced()` 挪到 `on_receive()` 之前 | 修真 bug（见下） |

### 附带修掉的真 bug：`poll.lua` 的 `hexspaced` 前向引用
`local function hexspaced(s)` 定义在 163 行，`on_receive` 的
`respFlag=false` 分支在 102 行调用它。`local function` 是词法作用域，
**定义在后面的 local 对前面的代码不可见** → 那条分支里的 `hexspaced`
解析成**全局 nil** → `attempt to call a nil value`。
**这条分支正是 7-fix/8-fix 的诊断路径**（"UART 收到字节但 poll 不在等响应"），
一旦触发就崩，把最关键的"收到的原始字节"丢掉。`check_lua.py` 能抓到。

### 只影响 sniff 档
`should_pub_topo()` **只对 sniff 返回 true**，`build_nodes`/`node_json` 只有它会调。
所以 1~5 **对 platform/manual 的采集与上报零影响**。
第 6 项在 485 主链路上，但只是**移动函数定义位置**，语义零变化
（轮询时序/Modbus 解析/事务逻辑一个字没动），只是把"必崩的日志"变成"能打的日志"。

## 还没定位的（下次现场要盯的）
**具体是哪一次分配失败**仍未知。traceback 的 `in upvalue '?'` 把函数名剥了，
只能靠调用层数推断。插桩就是为了下一次能直接读到水位：
- 看 `mem bn infer` 的水位（`mon.infer()` 那一步）
- 看 `mem bn nodes` 的水位（`node_json` 之后）

如果插桩显示水位一直很低（比如 60KB）却仍然崩 → 不是"总量不够"，
而是"拿不到连续大块"，得往 Plan B 走（降频 / 不发 U2 拓扑）。

**Plan B（如果 1~3 还不够，按代价递增）**：
1. sniff 档 U2 拓扑上报降频（60s 一次）
2. sniff 档不发 U2 拓扑，只发 U4（平台靠 auto-provision 补建，字段名退化成 `reg97`）
3. U4 数据也改成攒批再发

## 顺带修正的两个认知
- **`heap_info()` 读系统内存**（见结论 1），`R:STAT` 里的 `heap.used` 别当 Lua 堆看。
- **`mon.infer()` 有副作用**：`stat.infer_clamped` 会被累加。原来每轮被调 2 次，
  这个计数**是双倍计数的**；11-fix 降到 1 次后它才准。
  **README 里"这个数不为 0 就说明总线上有异常 qty 的帧"这条判据，前提是每轮只调一次。**

## 插桩怎么摘
定位完删掉 `build_nodes()` 里两行 `log.info("iot", string.format("mem bn ...))`
和 `lua_kb()` 辅助函数即可。**别换成 `collectgarbage("collect")`** —— 那是真回收，
毫秒级暂停，放热路径上有让 UART 环形缓冲溢出的风险。
