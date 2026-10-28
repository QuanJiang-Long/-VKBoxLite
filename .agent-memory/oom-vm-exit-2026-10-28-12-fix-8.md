# 第四次现场复盘：翻页就崩（2026-10-28，12-fix-8）

> 结论先行：**不是"内存不够"，是三件事叠在一起**。
> ① 水位保险丝**量错了对象**（量 `collectgarbage("count")`，而池真实用量比它高 33%）
> → 保险丝一次都没触发 → 垃圾堆到池 98.6% → VM exit 重启；
> ② sniff 档用不到的 `bus/poll` + `iot/pullcfg` 无条件常驻（~20KB）；
> ③ GC **不合并相邻空闲块** → "先 GC 再拼大包"救不了 6.4KB 的拓扑串。

## 现场日志（关键行）

```
18:27:34  W:MODE=sniff
18:27:38  W/user.iot reclaim before big alloc: lua=214.4KB -> collected
18:27:38  W/user.iot topo_sig failed, skip this round: iot.lua:629:
          not enough memory for buffer allocation
18:27:41  D/user.cmd tx: RET:FAIL:handler error:cmd.lua:225:
          not enough memory for buffer allocation
18:27:43  E/mem memory allocation failed total 307192, used 290368, alloc 6088
18:27:43  D/user.cmd tx: RET:INFER_PUSH={}
18:28:35  E/mem memory allocation failed total 307192, used 302880, alloc 320
18:28:35  E/user.coroutine.resume not enough memory
          stack traceback: iot.lua:1898: in function <iot.lua:1846>
18:28:35  E/main Lua VM exit!! reboot in 15000ms
```

进入 sniff 到重启只活了 **61 秒**。

## 三个最容易读错的点

1. **`E/mem ... used 290368` 是 Lua 堆池**（total 307192 = 开机那行
   `loadlibs luavm 307192`）。而 `guard` 心跳里的 `mem=110208/203040` 是
   **系统内存池**，跟 Lua 堆没关系 —— 别拿它判断堆水位。
2. **`census lua=213.7KB` 和池的 283.6KB 不是一回事**。差的那 ~70KB 是
   **每个活跃对象的 GC 头 + 池块头**（现场约 1900 个对象，一个 ~40B），
   不是垃圾，GC 也回收不掉。换算：**池用量 ≈ count × 1.33**。
3. **`reclaim before big alloc` 之后 45ms 照样 `topo_sig failed`** ——
   这不是巧合，是 LuatOS 分配器**不合并相邻空闲块**。GC 把垃圾块还回
   池子，但拼不出连续大块。12-fix-7 的 C 方案定位要改：它保的是"中等
   大小的分配有货可拿"，不是"腾大块"。

## 12-fix-8 改了什么

| 改动 | 位置 | 省下/效果 |
|---|---|---|
| 保险丝阈值 240 → 200（count） | `iot/iot.lua` task_main | 池约 266KB(87%) 就收垃圾；原来 240 比失效点还高 → `gc=0` |
| `bus/poll` 惰性 require | `main.lua` / `bus/ctrl.lua` / `svc/cmd.lua` | sniff 档省 ~14KB 常驻 |
| `iot/pullcfg` 惰性 require | `iot/iot.lua` `get_pullcfg()` | sniff 档省 ~7.5KB 常驻 |
| `R:STAT` 删掉重复的 `iot` 段 | `svc/cmd.lua` | 每次应答少 1.5KB 连续内存（每 5 秒一次） |
| 收帧协程 pcall | `bus/mon.lua` task() | 分配失败丢一帧，不死协程 |
| 上报协程 pcall + 重启 | `iot/iot.lua` `M.start()` | 分配失败丢一轮上报，不进 VM exit |
| `dep_graph.py` 识别惰性边 | `dep_graph.py` | `pcall(require,"x")` 不再被正则漏掉；惰性边不参与加载期循环检测 |

**惰性 require 的判据**（ctrl/cmd 都用这一套）：
poll 没被加载 ⇒ 它一定没在跑（只有 ctrl/cmd 会起它，而起它之前必然先加载）。
所以"问在不在跑"不需要把模块拉进来。

## 现场怎么验

- `census lua=` 从 213KB 降到 **190KB 上下**（少 20KB 常驻）；
- `census gc=`（保险丝触发次数）**偶尔** >0 —— 瘦身后稳态 count 约 194KB，
  垃圾攒到 200KB 收一次。**`gc=0` 且 `lua=` 明显 >200KB = 水位又上去了**；
- `census aerr=`（因堆分配失败丢帧）保持 0；
- 前端 R:STAT / R:INFER 不再 `RET:FAIL:handler error:not enough memory`；
- 跑满 10 分钟不重启。

## 下一轮的账

- `iot/iot.lua` 本身在设备上约 **75KB**（堆的 1/4），`bus/mon` ~27KB，
  `svc/cmd` ~23KB。再往下压只能拆模块。
- 拓扑 props 一条就要 6.4KB 连续内存 —— 常驻降下来之后池里才真有这么大
  一块，别在碎片池里硬拼。
- count 与池用量之间那 30% 的差是**每对象开销**，只能"少造对象"来降，
  GC 帮不上。
