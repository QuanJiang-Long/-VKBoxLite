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
M.PULL_TIMEOUT_MS = 15000
-- 拉取前自动连 MQTT 的等待上限(设备可能刚上电, 网络还没就绪)
M.PULL_CONNECT_MS = 20000
-- 平台 modbus.dataType -> 本框架 dtype
M.PULL_DTYPE = {
    ushort = "uint16", short = "int16",
    ulong = "uint32", long = "int32",
    float = "float32", double = "float64",
}
-- 平台 parity -> 本框架 parity
M.PULL_PARITY = { none = 0, even = 1, odd = 2 }

-- 缓冲
M.FRAME_CACHE = 10
M.RING_SIZE = 24
M.WRITEQ_MAX = 8

return M
