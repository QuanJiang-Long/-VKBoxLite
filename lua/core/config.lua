local M = {}

-- 485 串口
M.BAUD = 9600
M.DATABITS = 8
M.STOPBITS = 1
M.PARITY = 0

-- 轮询
M.SLAVE_ADDR = 1
M.POLL_INTERVAL_MS = 5000
M.TIMEOUT_MS = 500
M.REG_DEFAULT = {}
M.MAX_REGS = 128

-- 看门狗与监控
M.WDT_TIMEOUT = 9000
M.WDT_FEED_MS = 3000
M.MONITOR_MS = 10000
M.STALL_LIMIT_S = 120
M.AUTO_REBOOT = false

-- SN
M.SN_MIN_LEN = 17
M.SN_MAX_LEN = 32
M.SN_WARN_PERIOD_S = 600

-- MQTT
M.MQTT_INTERVAL_S = 60
M.MQTT_QOS = 1
M.MQTT_ALLOW_NO_SN = false

-- 平台配置拉取(W:PULLCFG)
M.PLATFORM_VENDOR = "VKBoxLite"
M.PLATFORM_MODEL = "VKBox-Lite"
M.PLATFORM_GET_TOPIC = "/sys/thing/gw/config/get/%s"
-- ⚠️ 没有 PLATFORM_POST_TOPIC：上报 topic 只有一个来源 —— 发布/订阅的成品
-- topic 全在 iot.lua 里由下面这几个常量拼。曾在这里重复定义过一份带 "-1"
-- 后缀的，全仓库零引用，留错的那个迟早有人照它改代码
-- U6 应用回执：msgId 必须与 D1 下发包里的一致，平台据此核销待下发登记
M.PLATFORM_REPLY_TOPIC = "/sys/thing/gw/config/reply/%s"
-- 另外几条固定 topic。原先存在 mqttcfg 里可配（前端 6 个 topic 输入框），
-- 按"代码精简"要求删除配置项后改为写死常量：改动概率极低，每配一条就要在
-- 前端、mqttcfg.normalize、build_subs、effective 里各留一份逻辑。
-- 平台文档明确这些 topic 三路同（sniff/platform/manual 完全一样），可配只会
-- 让三个档画出不同的清单，平台那头对不上。
-- 发布/订阅两条（PUB_T/SUB_T）同理，已从配置项删除，见下面。
-- hello 是拉配置时的自述通道；func/pset/pget 是平台三类下行的订阅通道，
-- 少订一条平台那类下发就永远收不到且无报错。
M.PLATFORM_HELLO_TOPIC = "/sys/thing/gw/config/hello/%s"
-- U4 子设备数据上报: 带 -{n} 发到子设备名上。少了它, 平台认不出数据归属
-- 哪个子设备, 上报等于白发。{sn} 段是【网关 SN】, -{n} 是从机序号
M.PLATFORM_PUB_TOPIC = "/sys/thing/node/property/post/%s"
-- U2 拓扑上报: 带 nodes[] 向平台登记子设备(建档+绑定+物模型)。少了它,
-- U4 带 -{n} 的数据平台认不出归属哪个子设备, 上报等于白发
M.PLATFORM_INFO_TOPIC = "/sys/thing/gw/info/post/%s"
-- U3 网关自身资源(cpu/ram/uptime), 顶层节点不是子设备, 所以不带 -{n}
M.PLATFORM_RES_TOPIC = "/sys/thing/gw/property/post/%s"
-- U7 指令回执: D2/D3 执行完回复, 平台据此更新 FunctionLog。目标 SN 可能是
-- 子设备, 所以是 {targetSN} 而不是 {sn}
M.PLATFORM_FPOST_TOPIC = "/sys/thing/gw/function/post/%s"
M.PLATFORM_FUNC_TOPIC = "/sys/thing/gw/function/get/%s"
M.PLATFORM_PSET_TOPIC = "/sys/thing/gw/property/set/%s"
M.PLATFORM_PGET_TOPIC = "/sys/thing/gw/property/get/%s"
M.PULL_TIMEOUT_MS = 15000
-- 拉取前自动连 MQTT 的等待上限(设备可能刚上电, 网络还没就绪)
M.PULL_CONNECT_MS = 20000
-- U1 hello 重发周期(秒)。文档: "未拿到配置前每 30min 重发"。平台侧网关档案
-- 可能被重置/白名单到期, 设备侧无从得知 —— 只靠上电那一次 hello, 之后档案没了
-- 就永久失联, 且没有任何报错。平台收到 hello 会重推 ConfigSnapshot, 由
-- recv_push 落盘, 不需要动拉取状态机。
-- 只对 pollpull 档生效: sniff 档的 hello 发完就判完成(平台明确不推配置),
-- 没有"未拿到配置"这个状态, 重发只会让平台侧无意义地刷新档案
M.HELLO_RE_S = 1800
-- U1 hello 发送失败时的重发间隔(秒), 文档规定 1s/3s/9s。只重发这么几次:
-- 发送失败多半是连接刚被 refresh_subs 抽走, 下一轮就好了; 真连不上就该报出来,
-- 而不是无限重发把"平台连不上"藏起来
M.HELLO_BACKOFF_S = { 1, 3, 9 }
-- 平台 modbus.dataType -> 本框架 dtype。
-- 两套拼法都要收：doc 的 D1/U2 示例用 uint16/float，现网实测的运维平台用
-- ushort/long-ABCD。两套并存（实测 13:29 那次 Ua=long-ABCD、PT/CT=ushort，
-- 而 doc 示例是 uint16/float），只认一套就会把同样的配置丢掉一半。
-- int16/uint32/int32/float64/double/float32 是补齐的常见写法，doc 未举但别拒。
M.PULL_DTYPE = {
    ushort = "uint16", uint16 = "uint16",
    short = "int16", int16 = "int16",
    ulong = "uint32", uint32 = "uint32",
    long = "int32", int32 = "int32",
    float = "float32", float32 = "float32",
    double = "float64", float64 = "float64",
}
-- dataType 的字节序后缀白名单。本框架字节序/字序已从全链路删除、解码固定
-- 大端(即 ABCD)，所以只有 -ABCD 与裸类型能收；-CDAB/-BADC/-DCBA 一律拒收。
-- 按错字节序解出来的值看起来合理但是错的，比直接报错更难查。
M.PULL_ORDER_OK = { abcd = true }
-- 平台 parity -> 本框架 parity
M.PULL_PARITY = { none = 0, even = 1, odd = 2 }

-- 缓冲
M.FRAME_CACHE = 10
M.RING_SIZE = 12
M.WRITEQ_MAX = 8

-- sniff 通讯参数自动识别(R:AUTODETECT)
-- parity 外层、baud 内层: 8N1 占现场绝大多数, 先把 8N1 的 4 个 baud 扫完
-- 再碰 E/O, 常见 1~4s 命中(9600 排第一, 多数现场 1s 就中)。
-- databits/stopbits 固定 8/1 —— ModbusRTU 事实标准, 7 位/2 停止位极少见,
-- 为它们把候选翻 3 倍不划算。
-- ⚠️ baud 只列 1200~9600: Air780EP 的 UART 在这个区间之外不可用, 列了也是
-- 拿错参数去扫, 白等一轮超时。
-- ⚠️ 为什么 parity 不参与排列: CRC 按无校验位字节算, 校验位错=数据位错=CRC
-- 必败, 所以 parity 错时同一个 baud 一帧都解不出。但这也意味着无法从"解不出
-- 帧"区分 baud 错还是 parity 错, 不知道 baud 就没法只试 parity, 必须每个
-- parity 都重扫一遍 baud —— 所以是 3*4=12 个候选, 不是 4+2=6 个。
-- 原工程(VKBox_Lite(1)/485_monitor.lua)是 baud 候选 x 2s + 命中后强验证;
-- 这里 12 候选 x 1s, 最坏 12s
M.DETECT_BAUDS = { 9600, 4800, 2400, 1200 }
-- 每个候选的采样窗口。1s 是按 9600(最常见, 排第一)定的: 8 字节帧约 8ms,
-- 轮询周期内轻松攒够阈值。⚠️ 慢总线(1200/2400)在稀疏从机时 1 秒可能只收到
-- 0~1 帧而漏检 —— 真机测试若发现慢 baud 识别不出, 优先把这个值调到 2000,
-- 代价是最坏耗时 12s->24s
M.DETECT_WIN_MS = 1000
-- 判定"这个参数对了"所需的最小 CRC 合法帧数。取 2 是因为单帧有 ~1/65536
-- 概率碰巧 CRC 正确, 两帧同时碰巧的概率可以忽略
M.DETECT_HITS = 2

return M
