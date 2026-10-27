# 切档不释放 485 总线 + 空表档自己重启 — 12-fix（2026-10-27）

## 起因：11-fix 烧上去之后现场又发现两件事

1. 从 manual 切到 idle 后，日志里还在持续刷 `poll.on_receive` 的 warn
2. 手动配了寄存器表的档位切回 idle 再切回来，设备过两分钟自己重启

## 一、切 idle 后 485 总线没释放

### 现场日志（决定性）

```
17:36:31.673  W:MODE=idle
17:36:31.674  I/user.poll stopped                      ← poll.stop() 执行了
17:36:31.689  RET:MODE=OK;cleared:manual 配置+mqtt_manual
17:36:31.721  R:MODE  → "mode":"idle"                  ← 切 idle 明确成功
17:36:31.787  R:STAT → "mode":"idle"
17:36:32.096  D/user.poll on_receive id=1 len=8 n=8 flag=false   ← ★ 还在跑
17:36:32.097  W/user.poll ... respFlag=false (raw=[01 03 00 61 00 01 d5 d4])
```

**切 idle 明确成功，UART 接收回调却还挂着。**

### 根因：两个 stop 不对称

| | 解绑 UART 回调 | 关串口 |
|---|---|---|
| `mon.stop()`（mon.lua） | ✅ `uart.on(id,"receive",nil)` | ✅ `uart.close` |
| `poll.stop()`（poll.lua） | ❌ 只置 `running=false` | ❌ |

回调在 `poll.start()` 绑（`poll.lua` 的 `uart.on`）。poll 停过 → 回调永久残留。

### 那串字节是谁发的？

按 Modbus RTU 帧长拆（8 字节 = 请求帧 slave/fc/addrHi/addrLo/qtyHi/qtyLo/crc×2，
7 字节 = 响应帧 slave/fc/byteCnt/data/crc×2）：

| raw | 解读 |
|---|---|
| `01 03 00 61 00 01 d5 d4` | 请求：读 addr **97**（= sniff 推断出的 reg97） |
| `01 03 08 0c 00 01 46 69` | 请求：读 addr 2060 |
| `01 03 e3 00 00 01 b3 8e` | 请求：读 addr 58112 |
| `01 03 02 00 00 b8 44` | 响应：值 0 —— **与 10-fix 的 sscom 抓包逐字节相同** |
| `01 03 02 3d 37 e9 02` | 响应：值在变 |

**是外部主站（PLC/上位机）在轮询仪表**，周期 ~500ms。我们设备只是被动听到了，
而且把每个字节都读走了。

### ⚠️ 一个容易犯的错：`R:BOOTMODE` 不代表当前模式

`cmd.lua` 的 `R:BOOTMODE` 返回的是 fskv `ds_sys.boot_mode`（**下次开机进什么档**），
跟当前运行模式无关。当前模式的权威读数是 `R:STAT` 里的 `"mode"`。
现场一度误判成"切 idle 没成功"，其实是切完 idle 又切回了 manual。

### 修法

- `poll.stop()` **无条件**解绑 + 关串口
  （无条件是必须的：只跑过 mon 没跑过 poll 时，`is_running()` 守卫会让清理不执行）
- `poll.probe_raw()`（`W:RAWTEST`）不在轮询态时，测完**解绑 + 关串口**
  ——原来不 running 什么都不做，`raw_on_receive` 永久留在 UART 上，同一类泄漏
- `ctrl` 的 idle 分支去掉 `is_running()` 守卫，无条件 `poll.stop()`

### 不影响启动路径的理由

`poll.start()` → `ensure_uart()` + `uart.on(...on_receive)`；`mon.start()` 自己也
setup + 绑定。`ensure_uart` 的"第 2 次 setup"本来就 `close + wait500 + setup`，
**关不关串口都一样，不会多出等待**。

反过来，从 manual 切 sniff 时 `mon.start()` 拿到的是一个**已关闭**的 UART ——
比原来（open 状态 `uart.setup` 走快路径、只改分频不复位 RX/DE）更干净，
正是 `poll.lua` 注释里"合宙 FAQ #32：重新 uart.setup 会重置 RX 缓冲和驱动上下文"
想要的效果。

## 二、manual 档 + 空寄存器表 → 设备自己重启

### 链路

```
切 idle → cleared:manual 配置 → ds_poll 被擦空
切回 manual → regs=0 → poll 槽空不起轮询 (34-fix)
→ 没人调 guard.alive() → stall = ticks - last_alive 无限涨
→ > STALL_LIMIT_S(120) → AUTO_REBOOT=true → rtos.reboot()
```

现场：`17:38:10 stall=104` → `17:38:15 stall=109`（每秒 +1）→ 约 17:38:26 自动重启。

### 根因：34-fix 的意图没落地

34-fix 定了"档位对应的槽空着就不起轮询"，好处之一明确写着
"看门狗不再被 'poll 起来了但 regs=0' 误判为停滞" ——
**但 `guard` 的判据一直只看 `mode`，没跟上。**

### 修法：stall 判据加"采集引擎是否真的在跑"

```lua
local function collector_running(mode)
    local mod = (mode == "sniff") and "bus/mon" or "bus/poll"
    local ok, m = pcall(require, mod)
    if not ok or not m or type(m.is_running) ~= "function" then return false end
    return m.is_running() and true or false
end
```

- 引擎**没起** → 没有采集任务在跑，心跳停是正常状态 → **不判 stall**
- 引擎**起了但卡死** → `is_running()` 仍是 true → stall 照常累积 → 120s 后照样
  自愈重启 —— **看门狗没退化**

`is_active_mode()` 的语义**没动**（单测锁着它），新判据是独立的 `stall_of()`。

### sniff 识别期不受影响

`ctrl` 的 sniff 分支里 `mon.start()`（ctrl.lua）**先于** `mon.request_detect()`，
所以识别全程 `is_running()` 都是 true；且 `sniff_wait()` 每 20ms 喂一次
`guard.alive()`，识别中 stall 一直是 0。

### 依赖方向

`guard.lua` → `bus/poll` 是**函数内惰性 require**（`pcall(require, mod)`），
顶层不依赖，所以两种加载顺序都安全：

- 先 guard 后 poll：guard 顶层不碰 bus/poll；后加载 poll 时 `require "svc/guard"`
  命中 `package.loaded` ✓
- 先 poll 后 guard：poll 顶层 `util.try("svc/guard")`（弱加载）→ guard 加载，
  顶层不碰 bus/poll ✓

`dep_graph.py` 看不到这条边（它扫的是 `require "字面量"`），**属于静态检查的盲区**，
以后加新的惰性 require 要自己过一遍这个推理。

## 三、顺带：`mon.infer()` 加 2 秒 TTL 缓存

`infer()` 每次都要遍历 frames + 重建整张 `agg` 表 + `regs` 数组 + `table.sort`，
全是临时分配。**插桩实测单次 infer 净增 ~3.1KB Lua 堆垃圾**，是 sniff 上报路径上
最大的一笔，而 `build_nodes()` 每秒调它一次。

加 2 秒 TTL 缓存 → 调用频率减半、垃圾减半。`R:INFER` 走 `mon.infer(true)`
强制取当前值（前端推断表要新鲜）。`mon.start()` / `mon.stop()` 会清缓存。

## 四、插桩改成门槛门控

原来每轮固定打 2 行 `mem bn ...`，是纯开销。现在加门槛 `MEM_LOG_KB = 210`：
**常态静默，超标才报**。实测水位（sniff 档）：稳态 infer 起点 ~198KB /
轮内峰值 ~204KB / 刚识别完的瞬时峰值 ~222KB。

**看不到这两行 = 水位在门槛以下。**

## 五、口径备忘：`rtos.meminfo("sys")` 不是 Lua 堆

实测 `rtos.meminfo("sys")` 报 `69048/203040`（= 67KB/198KB），而
`collectgarbage("count")` 同一时刻报 ~200KB —— **差 3 倍，根本不是同一个东西**。
`rtos.meminfo("sys")` 读的是系统内存池。

**判断"Lua 堆还剩多少"只能用 `collectgarbage("count")`**（KB）。
README 里"Lua 堆 ~300KB"的说法也值得回头核一遍。

另外：**Lua 堆上限是 LuatOS 固件/BSP 编译期常量**（`luat_mem.c` 的 `LUAT_MEM_SIZE`），
**改不了**（要重编译固件）。能做的只有降占用。

## 六、还没做的（下次再说）

- **idle 档仍然在连平台 MQTT**：`should_pub_platform()` 在 idle 返回 false →
  `subscribed=false, topics=[]`，一条都不订；但 `mqtt.create` + connect 照跑，
  **heap 从 69048 涨到 102736（+33.7KB）**。白占内存不干活，要不要断？
- **满负荷验证**：现场只有 8~9 个 props（离 64 上限很远）。换寄存器多的表，
  `node_json` 的 concat 会涨到 ~9.6KB，峰值会重新逼近崩溃线（~231KB）。
  需要造一张大表实测。
