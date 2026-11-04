local M = {}


M.BAUD = 9600
M.DATABITS = 8
M.STOPBITS = 1
M.PARITY = 0


M.SLAVE_ADDR = 1
M.POLL_INTERVAL_MS = 5000
M.TIMEOUT_MS = 500
M.REG_DEFAULT = {}
M.MAX_REGS = 128








M.WDT_TIMEOUT = 9000
M.WDT_FEED_MS = 3000
M.MONITOR_MS = 10000
M.STALL_LIMIT_S = 120




M.AUTO_REBOOT = true







M.DTYPE_FLOAT_MIN = 1e-3
M.DTYPE_FLOAT_MAX = 1e7
M.DTYPE_INT32_SUSPECT = 1e7



M.SN_PREFIX = "VL"
M.SN_MIN_LEN = 13
M.SN_MAX_LEN = 32
M.SN_WARN_PERIOD_S = 600


M.MQTT_INTERVAL_S = 120  -- 默认 2min, U2-m (兜底) / U3 res / U4 prop 共享
M.MQTT_QOS = 1








M.PUB_MIN_MS = 30000


M.PLATFORM_VENDOR = "VKBoxLite"
M.PLATFORM_MODEL = "VKBox-Lite"
M.PLATFORM_GET_TOPIC = "/sys/thing/gw/config/get/%s"




M.PLATFORM_REPLY_TOPIC = "/sys/thing/gw/config/reply/%s"








M.PLATFORM_HELLO_TOPIC = "/sys/thing/gw/config/hello/%s"


M.PLATFORM_PUB_TOPIC = "/sys/thing/node/property/post/%s"


M.PLATFORM_INFO_TOPIC = "/sys/thing/gw/info/post/%s"

M.PLATFORM_RES_TOPIC = "/sys/thing/gw/property/post/%s"


M.PLATFORM_FPOST_TOPIC = "/sys/thing/gw/function/post/%s"

M.PLATFORM_EVENT_TOPIC = "/sys/thing/gw/event/post/%s"
M.PLATFORM_FUNC_TOPIC = "/sys/thing/gw/service/invoke/%s"






M.PLATFORM_FUNC_NODE_TOPIC = "/sys/thing/node/service/invoke/%s"
M.PLATFORM_PSET_TOPIC = "/sys/thing/gw/property/set/%s"
M.PLATFORM_PGET_TOPIC = "/sys/thing/gw/property/get/%s"
M.PULL_TIMEOUT_MS = 15000

M.PULL_CONNECT_MS = 20000






M.HELLO_RE_S = 1800



M.HELLO_BACKOFF_S = { 1, 3, 9 }





M.PULL_DTYPE = {
    ushort = "uint16", uint16 = "uint16",
    short = "int16", int16 = "int16",
    ulong = "uint32", uint32 = "uint32",
    long = "int32", int32 = "int32",
    float = "float32", float32 = "float32",
    double = "float64", float64 = "float64",
}



M.PULL_ORDER_OK = { abcd = true }

M.PULL_PARITY = { none = 0, even = 1, odd = 2 }


M.FRAME_CACHE = 10
M.RING_SIZE = 12
M.WRITEQ_MAX = 8















M.DETECT_BAUDS = { 9600, 19200, 38400, 115200, 4800, 2400, 1200 }










M.DETECT_WIN_MS = 800




M.DETECT_SETTLE_MS = 2000






M.TOPO_REBUILD_MS = 30000


M.DETECT_HITS = 2

return M
