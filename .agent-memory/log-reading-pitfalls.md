# 日志判读的几个坑（本项目实测）

## 1. 厂商日志层会丢高位字节
厂商 log 层编码 `raw`/`data` 字段时，凡字节 ≥ `0x80` 一律丢弃。
所以日志里看到的二进制字段**不可信**，只有设备自己算出来的纯 ASCII 字段
（如 `vhex`、我们自己拼的 JSON）才是可信的。

## 2. U2 探测期间会先发一次错波特率
`mon.status().detecting == true` 期间 `build_nodes()` 的 serial 段取的是
`st.baud`（= `lastBaud or cfg.BAUD`，即上一轮/默认值 9600），不是识别出来的值。
所以 detect 期间 topology-post 的 `baudRate` 是 9600，detect 完才变 2400。
**这是预期行为**（第二次 post 会自我纠正），不是 bug；
但我已在 `task_main` 加了 `if not mon.status().detecting` 守卫，直接不发那一次错的。

## 3. `log.info` 两个分支必然打一行
`iot.lua` 的 U2 两帧（`gw meta posted:` / `gw meta skip:` / `topology posted:` /
`topology skip:`）在 `send_*` 返回后**必然**打印 success 或 skip 之一。
所以刷新固件后如果四行一种都没出现，只有两种可能：
   a. 贴出来的日志被筛选/裁剪过；
   b. 设备上的 iot.lua 不是最终版（改了源码但没重刷）。
不要在没确认之前断言"设备没发"。

## 5. "字段解析失败"先怀疑内容为空，别先怀疑字段名
`devices[0].addr 非法` 看起来像字段名不对，实际是 `devices: []`（空数组）。
教训：拿到解析失败第一件事是**把原始报文打出来**，不要凭 193B 这个长度推 schema。
本次已加 `body=` 到三处失败日志（`push parse fail` / `pull parse fail` /
`pullcfg recv`），下回直接看。


## 4. sys.taskInit 会立即跑到第一次挂起
LuatOS 的 `sys.taskInit(f)` 会先把 `f` 跑到第一个 `sys.wait` 才返回。
所以 `M.start()` 里 `sys.taskInit(task_main)` 之后的 `log.info("started")`
会打印在 `try_connect()` 产生的 `create mqtt` **之后**。日志顺序看着反了是正常的。
