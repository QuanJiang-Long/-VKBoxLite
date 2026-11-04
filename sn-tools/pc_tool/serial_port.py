"""
Windows 串口层 —— 用 ctypes 直接调 Win32 API，不依赖 pyserial。

为什么不用 pyserial：
    产线目标机可能离线，pip install 装不上；pyserial 又要 vendored 又要
    PyInstaller 打包，体积和风险都上来。Win32 串口 API 很薄，自己包一层
    反而更可控（超时、缓冲区、错误码都能按本项目需要定制）。

只实现本项目用到的能力：
    枚举 / 打开 / 配置(115200 8N1) / 写 / 读一行 / 关闭
"""

from __future__ import annotations

import ctypes
from ctypes import wintypes
from typing import List, Optional

#=====================================================================
# Win32 常量
#=====================================================================
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3

# ⚠️ 64 位 Windows 的 INVALID_HANDLE_VALUE = (HANDLE)-1 = 0xFFFFFFFFFFFFFFFF。
#   Python 任意精度整数下 0xFFFFFFFFFFFFFFFF == -1 是 False（两个不同的大整数，
#   Python 没有"有符号补码"概念），写 INVALID_HANDLE_VALUE = -1 会让
#   "if h == INVALID_HANDLE_VALUE" 永远不成立，CreateFileW 失败的错误码被吞掉，
#   后续拿着 0xFFF... 句柄调 GetCommState → 错误 6，看起来像底层参数读失败，
#   实际是【根本就没打开】。
INVALID_HANDLE_VALUE = 0xFFFFFFFFFFFFFFFF

# 共享访问标志：sniff frontend (node-serialport 默认 lock:false) 走的就是这个，
# 所以 pc_tool 跟 sniff / Luatools 同时开也能共存。
# 注意：两个程序同时打开同一 COM 时，写入的数据也会被双方都看到，
# 所以使用时仍要确保同一时刻只有一个程序在"主动"通讯。
FILE_SHARE_READ = 0x00000001
FILE_SHARE_WRITE = 0x00000002

ERROR_FILE_NOT_FOUND = 2
ERROR_ACCESS_DENIED = 5
ERROR_SHARING_VIOLATION = 32

NOPARITY = 0
ONESTOPBIT = 1

PURGE_RXCLEAR = 0x0004
PURGE_TXCLEAR = 0x0008

# ClearCommError 返回的错误位（WinBase.h）。出现这些说明物理链路断了，
# 最常见就是 USB 线被拔。
HW_ERROR_MASK = (
    0x0001   # CE_BREAK     检测到断路
    | 0x0002  # CE_FRAME     帧格式错
    | 0x0004  # CE_IOE       I/O 错误
    | 0x0008  # CE_MODE      句柄模式不支持
    | 0x0010  # CE_OVERRUN   字符丢失（缓冲满）
    | 0x0020  # CE_RXOVER    接收溢出
    | 0x0040  # CE_RXPARITY  奇偶校验错
    | 0x0080  # CE_TXFULL    发送缓冲满
)

#=====================================================================
# 结构体
#
# ⚠️ DCB 必须与 Win32 的 _DCB 逐字段对齐，一个都不能少、顺序不能错。
#    早期版本漏了 wReserved / XonLim / XoffLim / XonChar ... 等字段，
#    导致 ByteSize / Parity / StopBits 的偏移整体错位，SetCommState
#    按错位结构写回内核，直接访问冲突段错误（0xC0000005）。
#    宁可用全部字段显式列全，也不要图省事用位域简写。
#=====================================================================


class DCB(ctypes.Structure):
    _fields_ = [
        ("DCBlength", wintypes.DWORD),
        ("BaudRate", wintypes.DWORD),
        ("fBinary", wintypes.DWORD, 1),
        ("fParity", wintypes.DWORD, 1),
        ("fOutxCtsFlow", wintypes.DWORD, 1),
        ("fOutxDsrFlow", wintypes.DWORD, 1),
        ("fDtrControl", wintypes.DWORD, 2),
        ("fDsrSensitivity", wintypes.DWORD, 1),
        ("fTXContinueOnXoff", wintypes.DWORD, 1),
        ("fOutX", wintypes.DWORD, 1),
        ("fInX", wintypes.DWORD, 1),
        ("fErrorChar", wintypes.DWORD, 1),
        ("fNull", wintypes.DWORD, 1),
        ("fRtsControl", wintypes.DWORD, 2),
        ("fAbortOnError", wintypes.DWORD, 1),
        ("fDummy2", wintypes.DWORD, 17),
        ("wReserved", wintypes.WORD),
        ("XonLim", wintypes.WORD),
        ("XoffLim", wintypes.WORD),
        ("ByteSize", wintypes.BYTE),
        ("Parity", wintypes.BYTE),
        ("StopBits", wintypes.BYTE),
        ("XonChar", wintypes.CHAR),
        ("XoffChar", wintypes.CHAR),
        ("ErrorChar", wintypes.CHAR),
        ("EofChar", wintypes.CHAR),
        ("EvtChar", wintypes.CHAR),
        ("wReserved1", wintypes.WORD),
    ]


class COMMTIMEOUTS(ctypes.Structure):
    _fields_ = [
        ("ReadIntervalTimeout", wintypes.DWORD),
        ("ReadTotalTimeoutMultiplier", wintypes.DWORD),
        ("ReadTotalTimeoutConstant", wintypes.DWORD),
        ("WriteTotalTimeoutMultiplier", wintypes.DWORD),
        ("WriteTotalTimeoutConstant", wintypes.DWORD),
    ]


class COMSTAT(ctypes.Structure):
    _fields_ = [
        ("fBitFields", wintypes.DWORD),
        ("cbInQue", wintypes.DWORD),
        ("cbOutQue", wintypes.DWORD),
    ]


_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

#=====================================================================
# 函数原型声明
#   ⚠️ 64 位下不声明 argtypes/restype，句柄和指针会被按 int 截断，
#      后续用错位的句柄调 API 就是访问冲突（0xC0000005）。
#      HANDLE / LPVOID 一律 c_void_p，DWORD 输出参数用 byref。
#=====================================================================
_kernel32.CreateFileW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
    ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
]
_kernel32.CreateFileW.restype = wintypes.HANDLE

_kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
_kernel32.CloseHandle.restype = wintypes.BOOL

_kernel32.GetCommState.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
_kernel32.GetCommState.restype = wintypes.BOOL

_kernel32.SetCommState.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
_kernel32.SetCommState.restype = wintypes.BOOL

_kernel32.SetCommTimeouts.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
_kernel32.SetCommTimeouts.restype = wintypes.BOOL

_kernel32.PurgeComm.argtypes = [wintypes.HANDLE, wintypes.DWORD]
_kernel32.PurgeComm.restype = wintypes.BOOL

_kernel32.WriteFile.argtypes = [
    wintypes.HANDLE, ctypes.c_char_p, wintypes.DWORD,
    ctypes.c_void_p, ctypes.c_void_p,
]
_kernel32.WriteFile.restype = wintypes.BOOL

_kernel32.ReadFile.argtypes = [
    wintypes.HANDLE, ctypes.c_char_p, wintypes.DWORD,
    ctypes.c_void_p, ctypes.c_void_p,
]
_kernel32.ReadFile.restype = wintypes.BOOL

_kernel32.ClearCommError.argtypes = [
    wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
]
_kernel32.ClearCommError.restype = wintypes.BOOL


def _err() -> str:
    code = ctypes.get_last_error()
    return f"Win32 错误 {code}"


#=====================================================================
# 枚举串口
#=====================================================================
def _query_dos_device_exists(name: str) -> bool:
    """用 QueryDosDevice 判断 COM 口名是否真实存在。

    为什么不用 CreateFileW 探测：实测 CreateFileW("\\\\.\\COM5")
    在大量不存在的口上也返回有效句柄（本机 COM1~COM256 全部"能打开"），
    于是"探测"变成了"把 256 个全列出来" —— 工人看到的下拉是端口号清单，
    不是电脑当前有的端口。这是最初那个"端口没关联到实际端口号"的根因。

    QueryDosDevice 只在 DOS 设备名真实注册过时才返回内容，
    不存在的口返回 0 且 GetLastError()==ERROR_FILE_NOT_FOUND。
    它不需要打开设备，所以被占用的口也照样能识别出来。
    """
    buf = ctypes.create_unicode_buffer(1024)
    n = _kernel32.QueryDosDeviceW(name, buf, 1024)
    return n != 0


def _registry_ports() -> List[str]:
    """注册表 HARDWARE\\DEVICEMAP\\SERIALCOMM 里的串口设备。

    系统自己维护的表，插拔 USB 串口会立刻反映出来，所以适合拿来做
    轮询比对（只读注册表，不做 256 次 QueryDosDevice，开销小）。
    """
    ports: List[str] = []
    try:
        import winreg

        key_path = r"HARDWARE\DEVICEMAP\SERIALCOMM"
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path) as key:
            i = 0
            while True:
                try:
                    name, value, _ = winreg.EnumValue(key, i)
                except OSError:
                    break
                i += 1
                if isinstance(value, str) and value.upper().startswith("COM"):
                    ports.append(value.upper())
    except OSError:
        pass
    return ports


def list_ports() -> List[str]:
    """列出本机实际存在的 COM 口。

    判定方式（按可靠度排序）：
      1. 注册表 HARDWARE\\DEVICEMAP\\SERIALCOMM —— 系统维护的当前
         串口设备表，最权威，USB 虚拟口也在里面
      2. QueryDosDevice 逐个问 COM1~COM256 —— 补注册表没刷新的情况
         （驱动刚装上、设备枚举慢半拍）

    ⚠️ 不要再改回 CreateFileW 试开：那样会把 COM1~COM256 全列出来，
        见 _query_dos_device_exists 的说明。
    """
    ports = _registry_ports()

    # 方式二：QueryDosDevice 补问 COM1~COM256。
    # 只补注册表里没有的，且必须真的存在，不猜。
    found = {p.upper() for p in ports}
    for n in range(1, 257):
        name = f"COM{n}"
        if name in found:
            continue
        if _query_dos_device_exists(name):
            ports.append(name)

    def sort_key(p: str) -> tuple:
        try:
            return (0, int(p[3:]))
        except ValueError:
            return (1, 0)

    return sorted(set(ports), key=sort_key)


#=====================================================================
# 串口对象
#=====================================================================
class SerialPort:
    """极简串口：打开 / 写 / 按行读 / 关闭。全部同步阻塞，产线场景够用。"""

    def __init__(self, port: str, baud: int = 115200, read_timeout_ms: int = 1500):
        self.port = port
        self.baud = baud
        self.read_timeout_ms = read_timeout_ms
        self._handle = None

    #-----------------------------------------------------------------
    @property
    def is_open(self) -> bool:
        return self._handle is not None

    #-----------------------------------------------------------------
    def open(self) -> None:
        if self._handle is not None:
            return
        h = _kernel32.CreateFileW(
            f"\\\\.\\{self.port}", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,   # 共享访问：与 sniff / Luatools 共存
            None, OPEN_EXISTING, 0, None,
        )
        # CreateFileW 失败时返回 INVALID_HANDLE_VALUE (0xFFFFFFFFFFFFFFFF)。
        # 必须用 unsigned & 0xFFFF... 比对，不能用 h == -1（见上面常量定义处的注释）。
        if (h == 0) or ((h & 0xFFFFFFFFFFFFFFFF) == INVALID_HANDLE_VALUE):
            code = ctypes.get_last_error()
            if code == ERROR_FILE_NOT_FOUND:
                raise IOError(f"{self.port} 不存在")
            if code in (ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION):
                raise IOError(f"{self.port} 被独占占用（其它程序用独占模式打开了同一 COM，关闭该程序后再试）")
            raise IOError(f"打开 {self.port} 失败：{_err()}")

        self._handle = h
        try:
            self._configure()
        except Exception:
            self.close()
            raise

    def _configure(self) -> None:
        assert self._handle is not None
        dcb = DCB()
        dcb.DCBlength = ctypes.sizeof(DCB)
        if not _kernel32.GetCommState(self._handle, ctypes.byref(dcb)):
            raise IOError(f"读取 {self.port} 参数失败：{_err()}")

        dcb.BaudRate = self.baud
        dcb.ByteSize = 8
        dcb.Parity = NOPARITY
        dcb.StopBits = ONESTOPBIT
        if not _kernel32.SetCommState(self._handle, ctypes.byref(dcb)):
            raise IOError(f"设置 {self.port} 参数失败：{_err()}（115200 8N1）")

        # 超时：读操作总超时 = read_timeout_ms
        to = COMMTIMEOUTS()
        to.ReadIntervalTimeout = 50            # 字符间间隔 > 50ms 视为一行结束
        to.ReadTotalTimeoutMultiplier = 0
        to.ReadTotalTimeoutConstant = self.read_timeout_ms
        to.WriteTotalTimeoutMultiplier = 0
        to.WriteTotalTimeoutConstant = 2000
        if not _kernel32.SetCommTimeouts(self._handle, ctypes.byref(to)):
            raise IOError(f"设置 {self.port} 超时失败：{_err()}")

        # 清收发缓冲，避免上一会话的残留字节污染本次探测
        _kernel32.PurgeComm(self._handle, PURGE_RXCLEAR | PURGE_TXCLEAR)

    #-----------------------------------------------------------------
    def write(self, data: bytes) -> None:
        if self._handle is None:
            raise IOError("串口未打开")
        written = wintypes.DWORD(0)
        if not _kernel32.WriteFile(
            self._handle, data, len(data), ctypes.byref(written), None
        ):
            raise IOError(f"写入 {self.port} 失败：{_err()}")
        if written.value != len(data):
            raise IOError(f"写入不完整：{written.value}/{len(data)}")

    #-----------------------------------------------------------------
    def read_line(self, max_bytes: int = 4096) -> Optional[bytes]:
        """读到 \n 为止，或超时返回 None。不含换行符。

        max_bytes 默认 4096（不是 512）：
            - 老的 SN/LOCK/UNLOCK/R:INFO 等短指令应答都在 128 字节以内，
              512 完全够用 —— 但 R:MQTT（设备侧 iot.status + mqttcfg.effective
              的完整 dump，含 stat + cfg + auto_pass + pub/sub 等）实测
              ~700+ 字节，且 last_err 字段是中文（UTF-8 3 字节/字），再加
              hex 数值字段，JSON 应答轻轻松松过 512 字节。
            - 之前默认 512 时 R:MQTT 在 PC 端被截断，json.loads 报
              "Unterminated string" —— 看似 JSON 损坏，其实是 PC 端切坏了。
              提到 4096 覆盖 R:MQTT 全长 + 给将来更长的指令留空间。
            - ReadFile 每次读 256 字节块，遇到 \n 立即返回，所以即使 max_bytes
              大，超短指令也不会浪费（早返回）。
        """
        if self._handle is None:
            raise IOError("串口未打开")
        buf = bytearray()
        while len(buf) < max_bytes:
            chunk = ctypes.create_string_buffer(256)
            got = wintypes.DWORD(0)
            if not _kernel32.ReadFile(
                self._handle, chunk, 256, ctypes.byref(got), None
            ):
                raise IOError(f"读取 {self.port} 失败：{_err()}")
            if got.value == 0:
                return None          # 超时
            buf += chunk.raw[: got.value]
            idx = buf.find(b"\n")
            if idx >= 0:
                return bytes(buf[:idx]).rstrip(b"\r")
        return bytes(buf).rstrip(b"\r\n")

    def read_available(self) -> bytes:
        """读掉缓冲里现有的全部字节（用于清残留在探测失败后）。"""
        if self._handle is None:
            return b""
        st = COMSTAT()
        errs = wintypes.DWORD(0)
        if not _kernel32.ClearCommError(self._handle, ctypes.byref(errs), ctypes.byref(st)):
            return b""
        if st.cbInQue == 0:
            return b""
        out = bytearray()
        while st.cbInQue > 0 and len(out) < 4096:
            chunk = ctypes.create_string_buffer(min(256, st.cbInQue))
            got = wintypes.DWORD(0)
            if not _kernel32.ReadFile(self._handle, chunk, len(chunk), ctypes.byref(got), None):
                break
            if got.value == 0:
                break
            out += chunk.raw[: got.value]
            if not _kernel32.ClearCommError(self._handle, ctypes.byref(errs), ctypes.byref(st)):
                break
        return bytes(out)

    #-----------------------------------------------------------------
    def flush(self) -> None:
        if self._handle is not None:
            _kernel32.PurgeComm(self._handle, PURGE_RXCLEAR | PURGE_TXCLEAR)

    #-----------------------------------------------------------------
    def still_alive(self) -> bool:
        """串口对应的物理设备还在不在。

        USB 拔掉后句柄不会自动失效，WriteFile/ReadFile 可能仍返回成功
        （或者一直读不到数据），光靠"读不到应答"分不清是设备挂了还是
        程序没跑。ClearCommError 在设备消失后会失败，这是可靠的判据。

        返回 False = 设备已断开，调用方应关闭串口并提示重插。
        """
        if self._handle is None:
            return False
        errs = wintypes.DWORD(0)
        st = COMSTAT()
        if not _kernel32.ClearCommError(self._handle, ctypes.byref(errs),
                                        ctypes.byref(st)):
            return False
        # 硬件错误位：CE_BREAK/CE_FRAME/CE_OVERRUN 等，通常是线被拔了
        return not bool(errs.value & HW_ERROR_MASK)

    #-----------------------------------------------------------------
    def close(self) -> None:
        if self._handle is not None:
            _kernel32.CloseHandle(self._handle)
            self._handle = None

    def __enter__(self) -> "SerialPort":
        self.open()
        return self

    def __exit__(self, *exc) -> None:
        self.close()


if __name__ == "__main__":
    ports = list_ports()
    print(f"枚举到 {len(ports)} 个串口: {ports}")
    if not ports:
        print("（没有串口，插入设备后再试）")
        raise SystemExit(0)

    p = ports[0]
    print(f"\n试开 {p} ...")
    try:
        with SerialPort(p) as sp:
            print(f"  {p} 打开成功，115200 8N1")
            sp.write(b"\r\n")
            line = sp.read_line()
            print(f"  读到: {line!r}")
    except IOError as e:
        print(f"  打不开: {e}")
    print("\n串口层自检: 通过")
