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
M.PLATFORM_POST_TOPIC = "/sys/thing/node/property/post/%s-1"
-- U6 应用回执：msgId 必须与 D1 下发包里的一致，平台据此核销待下发登记
M.PLATFORM_REPLY_TOPIC = "/sys/thing/gw/config/reply/%s"
-- 另外 5 条固定 topic。原先存在 mqttcfg 里可配（前端 6 个 topic 输入框），
-- 按"代码精简"要求删除配置项后改为写死常量：这 5 条改动概率极低，每配一条
-- 就要在前端、mqttcfg.normalize、build_subs、effective 里各留一份逻辑。
-- 发布/订阅仍可配（mqttcfg.pub_topic / sub_topic），那两条业务上真会改。
-- hello 是拉配置时的自述通道；func/pset/pget 是平台三类下行的订阅通道，
-- 少订一条平台那类下发就永远收不到且无报错。
M.PLATFORM_HELLO_TOPIC = "/sys/thing/gw/config/hello/%s"
M.PLATFORM_FUNC_TOPIC = "/sys/thing/gw/function/get/%s"
M.PLATFORM_PSET_TOPIC = "/sys/thing/gw/property/set/%s"
M.PLATFORM_PGET_TOPIC = "/sys/thing/gw/property/get/%s"
M.PULL_TIMEOUT_MS = 15000
-- 拉取前自动连 MQTT 的等待上限(设备可能刚上电, 网络还没就绪)
M.PULL_CONNECT_MS = 20000
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
M.RING_SIZE = 24
M.WRITEQ_MAX = 8

return M
