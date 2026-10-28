# U4 停发：碎片化，不是内存不够（2026-10-28，12-fix-7）

## 现场现象

用户测 12-fix-5（`e284035`）时发现：**U4 主题
`/sys/thing/node/property/post/VL20261019001-1` 停止上报**（一开始正常，
跑久了就不发了），而 sniff 业务没崩、没死机、U2 拓扑还在发。

日志（uptime 2475~2531s）：

```
W/user.iot build_items failed, skip publish: iot.lua:302:
    not enough memory for buffer allocation
W/user.iot topo_sig failed, skip this round: iot.lua:525:
    not enough memory for buffer allocation
I/user.iot census lua=222.0KB points=77 frames=116411 aliases=77 rows=24
    pub=60/0 meta=21 topo=18 blk=2409 fps=52 push=86 gc=1
```

## 定位的关键：行号对得上代码

把老固件 `e284035` 的 `lua/iot/iot.lua` 拉出来对行号：

| 日志行号 | 代码 | 一次要多大连续块 |
|---|---|---|
| `iot.lua:302` | `"[" .. table.concat(77 个点) .. "]"` | **~6 KB** |
| `iot.lua:525` | 拓扑 props 的 `table.concat` | **~1.2 KB** |

**决定性的一条：拓扑那条只要 1.2KB 也失败。** 所以不是「包太大」，
是 300KB 的池子被切碎了（只剩 78KB，但切不出 1.2KB 的连续块）。
→ 「把 U4 拆成 2~3 包」只能治 U4，治不了拓扑；病根是碎片。

## 几个容易看错的地方

- `mem=102432/203040` = `rtos.meminfo("sys")`（**系统**内存池，50% 不满）
  —— 跟 Lua 堆无关。Lua 堆的水位是 `census` 的 `lua=`（`collectgarbage("count")`，
  LuatOS 这个接口返回的就是 KB）。
- `pub=60/0` 里的 failed=0 **是假的**：拼大包失败走 pcall 跳过（`iot.lua` 的
  `publish()`），不计入 `S.failed`。所以 census 看不出「U4 已经不工作了」。
  → 12-fix-7 加了 `bfail=`。
- 12-fix-5 的水位保险丝阈值是 240KB，**比现场失效点(222KB)还高** → 等于没设防。
  → 12-fix-7 的 `reclaim_if_high()` 定 200KB，且只在拼大包之前做。

## 12-fix-7 做了什么

| 改动 | 位置 | 说明 |
|---|---|---|
| B 降级分包 | `iot.lua` `build_items()` | 整包失败才按 25 点（~2KB）拆，同 topic 分几条发；正常路径一字节不变 |
| C 大包前回收 | `iot.lua` `reclaim_if_high()` | 水位 > 200KB 才 `collectgarbage("collect")`，只在发布/拓扑路径上 |
| D census 计数 | `iot.lua` `census()` | 加 `bfail=`、`rc=` |

## 教训（比代码更重要）

1. **别凭感觉估 churn，要拿 `tests/lua/test_churn.lua` 量。**
   本轮原计划（A）把 `reg<addr>` 拼串缓存起来，理由是
   「520 次/秒 ≈ 13KB/秒垃圾」。实测 `pick_dtype` 改前 29.5 字节/次、
   改后 29.9 字节/次 —— **纹丝不动**。因为 Lua 的 `luaV_concat` 对
   ≤256 字节的结果走栈缓冲，不分配堆（短串还会被 intern）。
   缓存保留只为了「一个地址一个串对象」这条约定。
2. **`table.concat` 的大缓冲是碎片池里最难申请的东西。**
   现场两处（U4 的 6KB、拓扑的 1.2KB）都栽在它身上。
3. **失败计数要单独记**：走 pcall 跳过的失败不进 `failed`，census 会骗人。

## 还没解决的（下一步）

B/C/D 是**兜底**，不是根治。常驻里最大的一块是**代码**（现场 idle 基线
~190KB 就是代码 + 常量），而 sniff 档用不到的东西照样常驻：

- `bus/poll.lua`（21.6KB 源码）—— `main.lua:98` / `bus/ctrl.lua:5` /
  `svc/cmd.lua:12` **无条件 require**；
- `iot/pullcfg.lua`（11.6KB，平台配置拉取）—— `iot/iot.lua:35` 顶层 require；
- `sn/prov.lua` + `sn/sn.lua`（13.1 + 10.7KB，SN 烧录）。

改成惰性 require（`iot.lua` 里已经有 `get_poll()` 这个现成范式），
sniff 档能腾出 ~20~30KB（设备口径）—— 这是目前**唯一能显著抬高
"碎片化失效水位"**的杠杆。量它用 `tests/lua/test_codesize.lua`。

⚠️ 改 require 的加载时机要留意 LuatOS 的 `require` 是运行时读 FS，
且 `dep_graph.py` 的依赖图是静态扫的 —— 改完要重跑依赖检查。
