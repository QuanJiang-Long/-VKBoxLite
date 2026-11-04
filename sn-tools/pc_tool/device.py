"""
设备指令封装。

协议与 soft_sn_demo/sn_prov_uart.lua 严格对应：

    发 -> R:SN / R:ID / W:SN=xxx[,FORCE] / LOCK:SN / UNLOCK:SN
    收 <- RET:SN=xxx|EMPTY|INVALID
          RET:ID=imei:..;uid:..;sn:..;state:..;lock:..
          RET:OK / RET:FAIL:原因

MQTT 三项走另一套（设备侧是 VKBoxLite_sniff 的脚本，不是 soft_sn_demo）：

    发 -> W:MQTT={"host":"..","port":1883,"auto_pass":".."}
    收 <- RET:MQTT=OK / RET:FAIL:MQTT:原因

    见 Device.write_mqtt 的 docstring：字段语义、"先清后写"、
    三项全空的设备侧行为，以及"设备不认识 W:MQTT 会超时"这件事。

⚠️ 每个端口同一时刻只允许一个程序占用。SSCOM / Luatools 开着时
   对应口会打不开，错误信息要能让人一眼看出该去关哪个。
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Callable, Optional

from serial_port import SerialPort, list_ports


def _parse_info(resp: str) -> dict:
    """R:INFO 返回的是 JSON 字符串 `RET:INFO={...}`，提取并解析。

    老协议 `R:ID` 返回的是 `RET:ID=imei:..;uid:..;sn:..;state:..;lock:..`
    这种 k:v;k:v 文本 —— 当前固件不再支持 R:ID（实测 R:ID/R:SN/W:SN/LOCK:SN/
    UNLOCK:SN 全部超时），但 sniff 同款设备的 R:INFO 正常。所以统一走 R:INFO。
    """
    s = resp.rstrip()
    if not s.startswith("RET:INFO="):
        return {}
    try:
        return json.loads(s[len("RET:INFO="):])
    except (ValueError, TypeError):
        return {}


class DeviceError(Exception):
    """设备侧明确返回的失败（RET:FAIL:xxx），原因可直接展示给工人。"""

    def __init__(self, reason: str):
        self.reason = reason
        super().__init__(reason)


class TimeoutError_(DeviceError):
    """串口无响应：线松了 / 口选错了 / 设备没起来。"""

    def __init__(self, cmd: str):
        super().__init__(f"设备无响应（发送了 {cmd}）")


REASON_CN = {
    "char invalid": "SN 含非法字符（规则配错了）",
    "length invalid": "SN 长度不符（规则配错了）",
    "checksum invalid": "SN 校验位错误（抄错一位或工装算错了）",
    "sn exists": "设备已有不同 SN，需确认是否返修",
    "locked": "设备已上锁，需走返修流程解锁",
    "not locked": "设备未上锁，无需解锁",
    "no sn": "设备还没有 SN，不能上锁",
    "write disabled": "设备侧已关闭写入",
    "verify fail": "写入后回读不一致（Flash 异常，该号作废）",
    "id unavailable": "设备读不到身份信息",

    #---- W:MQTT 的原因（设备侧 iot/mqttcfg.lua 的 normalize/save 返回）----
    # 注意键是设备原文（英文），值是给工人看的中文。
    "no iot": "设备侧 MQTT 模块未就绪（固件没带 iot？）",
    "bad json": "配置内容无法解析（PC 发出的 JSON 坏了）",
    "bad host": "服务器地址为空或超过 128 字符",
    "bad port": "端口超出 1~65535",
    "bad interval_s": "上报间隔超出 0~86400 秒",
    "bad qos": "QoS 只能是 0 / 1 / 2",
    "bad pub_topic": "发布 topic 为空或超过 128 字符",
    "bad sub_topic": "订阅 topic 为空或超过 128 字符",
    "no json lib": "设备固件缺 json 库，写不了配置",
    "encode fail": "设备侧配置编码失败",
    "too large": "配置内容过大（设备存不下）",
    "no fskv": "设备没有可用的键值存储分区",
}


def reason_cn(reason: str) -> str:
    return REASON_CN.get(reason, reason)


#=====================================================================
# 协议字段清洗
#
# 设备侧 R:ID 应答是【文本协议】，但芯片 UID 早期版本是把 mcu.unique_id()
# 的原始二进制直接拼进去的，带 0x00~0x1F 控制字符，0x00 还会截断 C 字符串。
# 在设备端修好之前，PC 必须自己兜底：把不可打印字符换成 '.'，
# 否则界面上就是一片乱码，工人没法核对，台账里也会存进脏数据。
#
# 新版固件已改成大写十六进制（见 soft_sn_demo/identity.lua 的 to_hex_uid），
# 这个清洗只对旧固件/异常数据生效，对正常 hex 字符串无副作用。
#=====================================================================
_PRINTABLE = set(
    "0123456789"
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "-_./:+@ "
)

# 解码失败占位符。device._cmd() 用 decode("ascii", errors="replace") 会把
# 非 ASCII 字节变成它，早期版本就这么原样存进了台账。它不是数据，是
# "这里有个字节我没看懂" 标记，清洗时应当【直接丢掉】——转成 "FFFD"
# 文本只会把乱码换一种形式继续显示。
REPLACEMENT_CHAR = "\ufffd"


def clean_field(v: str) -> str:
    """把协议字段清洗成可安全显示/存 CSV 的文本。

    空字段原样返回空——sn/imei 为空是合法业务状态（未烧录），
    不该被替换成"(空)"写进台账。只有字段里全是不可打印字符、
    清洗后什么都不剩时，才给一个可见的占位。
    """
    if not v:
        return ""
    out = []
    for ch in v:
        if ch == REPLACEMENT_CHAR:
            continue                      # 解码失败标记，不是数据
        if ch in _PRINTABLE:
            out.append(ch)
        elif ord(ch) > 0x7E:              # 高位字节，可能是 latin-1 的 UID
            out.append(f"{ord(ch):02X}")
        else:
            out.append(".")               # 控制字符
    s = "".join(out).strip()
    while ".." in s:                      # 压掉连续的点
        s = s.replace("..", ".")
    s = s.strip(".")
    return s if s else "(空)"


@dataclass
class DeviceInfo:
    """R:ID 的解析结果。imei 是台账查重的主键。"""

    imei: str = ""
    uid: str = ""
    sn: str = ""
    state: str = ""          # empty / invalid / ready
    lock: int = 0

    @property
    def is_locked(self) -> bool:
        return self.lock == 1

    @property
    def has_sn(self) -> bool:
        return bool(self.sn)

    @property
    def state_cn(self) -> str:
        return {
            "empty": "未烧录",
            "ready": "已烧录",
            "invalid": "Flash 脏数据",
        }.get(self.state, self.state or "未知")


class Device:
    """一台设备的指令通道。绑定一个已打开的串口。"""

    def __init__(self, port: SerialPort):
        self.port = port

    #-----------------------------------------------------------------
    def _cmd(self, cmd: str, timeout_ms: Optional[int] = None) -> str:
        """发一条指令，返回应答行。无响应抛 TimeoutError_。

        ⚠️ 编解码用 utf-8，不要用 ascii。SN 指令本身全是 ASCII，
            换 utf-8 对它们没有任何影响；但 W:MQTT 的 JSON 里可能带
            中文地址/密码，ascii 编码会直接抛 UnicodeEncodeError。
            设备侧 LuatOS 的 json.decode 能解 UTF-8，所以发得出去也解得回。
        """
        if timeout_ms is not None:
            old = self.port.read_timeout_ms
            self.port.read_timeout_ms = timeout_ms
        try:
            self.port.flush()
            self.port.write((cmd + "\r\n").encode("utf-8"))
            line = self.port.read_line()
        finally:
            if timeout_ms is not None:
                self.port.read_timeout_ms = old
        if line is None:
            raise TimeoutError_(cmd)
        return line.decode("utf-8", errors="replace").strip()

    #-----------------------------------------------------------------
    def ping(self, timeout_ms: int = 800) -> bool:
        """用 R:INFO 探活。自动识别串口时用。

        旧版用 R:ID；当前固件 R:ID/R:SN/W:SN/LOCK:SN/UNLOCK:SN 全部无响应，
        但 R:INFO 正常（sniff 同款设备实测）。原因：固件中 sn/prov.lua 的
        dispatch 路径上除了 R:SNEN 之外的指令都不再被触发，
        详见 sniff 仓库的 lua/README.md "R:SN 不是死代码" 注释。
        """
        try:
            return self._cmd("R:INFO", timeout_ms=timeout_ms).startswith("RET:INFO=")
        except (DeviceError, IOError):
            return False

    #-----------------------------------------------------------------
    def read_sn(self) -> str:
        """返回 SN 值 / 'EMPTY' / 'INVALID'。

        优先用 R:INFO 读 JSON（sn_state 字段）—— 这是当前固件唯一能拿到的通道。
        老协议的 R:SN 在当前固件已不响应，保留作为兜底以便将来兼容老固件。
        """
        try:
            d = _parse_info(self._cmd("R:INFO"))
        except (DeviceError, IOError):
            d = {}
        if d:
            st = d.get("sn_state", "")
            if st == "ready":
                return d.get("sn") or ""
            if st == "invalid":
                return "INVALID"
            return "EMPTY"
        # 兜底：老固件还有 R:SN 协议时走老路
        r = self._cmd("R:SN")
        if r.startswith("RET:SN="):
            return r[len("RET:SN="):]
        if r.startswith("RET:FAIL:"):
            raise DeviceError(r[len("RET:FAIL:"):])
        raise DeviceError(f"意外应答: {r}")

    #-----------------------------------------------------------------
    def read_id(self) -> DeviceInfo:
        """读设备身份。优先 R:INFO（当前固件唯一通道），兜底 R:ID（老固件）。"""
        try:
            d = _parse_info(self._cmd("R:INFO"))
        except (DeviceError, IOError):
            d = {}
        if d:
            info = DeviceInfo()
            info.imei = clean_field(str(d.get("imei") or ""))
            info.uid = clean_field(str(d.get("uid") or ""))
            info.sn = clean_field(str(d.get("sn") or ""))
            info.state = d.get("sn_state") or ""
            try:
                info.lock = int(d.get("lock") or 0)
            except (TypeError, ValueError):
                info.lock = 0
            return info
        # 兜底 R:ID 老协议
        r = self._cmd("R:ID")
        if not r.startswith("RET:ID="):
            if r.startswith("RET:FAIL:"):
                raise DeviceError(r[len("RET:FAIL:"):])
            raise DeviceError(f"意外应答: {r}")
        info = DeviceInfo()
        for kv in r[len("RET:ID="):].split(";"):
            if ":" not in kv:
                continue
            k, v = kv.split(":", 1)
            k, v = k.strip(), clean_field(v)
            if k == "imei":
                info.imei = v
            elif k == "uid":
                info.uid = v
            elif k == "sn":
                info.sn = v
            elif k == "state":
                info.state = v
            elif k == "lock":
                try:
                    info.lock = int(v)
                except ValueError:
                    info.lock = 0
        return info

    #-----------------------------------------------------------------
    def write_sn(self, sn: str, force: bool = False) -> None:
        cmd = f"W:SN={sn}" + (",FORCE" if force else "")
        r = self._cmd(cmd, timeout_ms=3000)   # 写 Flash 比读慢，多给点时间
        if r == "RET:OK":
            return
        if r.startswith("RET:FAIL:"):
            raise DeviceError(r[len("RET:FAIL:"):])
        raise DeviceError(f"意外应答: {r}")

    #-----------------------------------------------------------------
    def clear_sn(self, timeout_ms: int = 3000) -> None:
        """抹去设备上的 SN（C:SN）。返修场景用 —— 工人想让一台"已废但别处叫"
        的设备回到未烧状态。

        设备侧协议（VKBoxLite_sniff 的 lua/sn/sn/lua/svc/cmd.lua）：
            发 -> C:SN
            收 <- RET:OK
            收 <- RET:FAIL:<原因>     locked / clear disabled / ...

        设备侧行为（sn.clear()）：
            - 已锁 + state=ready → 拒绝 "locked"（必须先 UNLOCK:SN 解锁）
            - 已锁 + state=invalid → 允许（产线少一步操作）
            - 未锁 + 有 SN（任意 state） → 删 fskv 的 K_SN + flush，
              state 变 EMPTY
            - 已 empty → 也允许（幂等），无副作用

        ⚠️ 不动台账：device.clear_sn 只清设备侧 fskv 的 SN；PC 端台账保留
        原记录以便追溯"这台设备之前烧过什么号"。需要清理台账走单独流程。
        """
        r = self._cmd("C:SN", timeout_ms=timeout_ms)
        if r == "RET:OK":
            return
        if r.startswith("RET:FAIL:"):
            raise DeviceError(r[len("RET:FAIL:"):])
        raise DeviceError(f"意外应答: {r}")

    #-----------------------------------------------------------------
    def write_mqtt(self, host: str, port: int, passwd: str,
                   timeout_ms: int = 3000) -> None:
        """把 MQTT 三项写进设备（W:MQTT），成功后设备自动重连。

        设备侧协议（VKBoxLite_sniff 的 lua/svc/cmd.lua + lua/iot/mqttcfg.lua）：
            发 -> W:MQTT={"host":"..","port":1883,"auto_pass":".."}
            收 <- RET:MQTT=OK
            收 <- RET:FAIL:MQTT:<原因>   原因见 REASON_CN 的 MQTT 段

        字段对应关系（与前端"首页"MQTT 面板一致）：
            host      服务器地址
            port      端口，1~65535
            auto_pass 凭证密码。⚠️ 走的是【自动档】密码键 auto_pass，
                      不是手动档的 pass —— 自动档用户名固定用设备 SN，
                      正好对应 PC 工具"只填三项、用户名用 SN"的用法。
                      manual_on 不设即为自动档。

        ⚠️ 设备侧是"先清后写"：这份 JSON 会把整个 MQTT 配置按默认值重建，
           不在 JSON 里的字段全部回落默认（user/pass 清空、topic 回默认模板）。
           所以这里必须把三项都带上，不能只带改动的那个。

        ⚠️ 三项全空也照样发：设备会把 host 回落默认 dz.voltkun.com、
           auto_pass 回落默认凭证。这是设备侧行为，PC 不拦截 ——
           留空不得影响任何其它流程。

        ⚠️ 未知设备（如还在跑 soft_sn_demo）没有 W:MQTT，会静默不应答，
           最终抛 TimeoutError_("设备无响应")。这不是 bug，是协议提示。
        """
        payload = {
            "host": host or "",
            "port": int(port),
            "auto_pass": passwd or "",
        }
        # separators 去掉空格：串口行长一点就多一次被截断的风险，紧凑为好。
        # ensure_ascii=False：中文地址/密码按 UTF-8 发出，LuatOS 的
        # json.decode 能解；若用 ASCII 转义会变成 \uXXXX，设备侧解出来
        # 虽对但难读，且 _cmd 的 ascii 编码会直接抛 UnicodeEncodeError。
        body = json.dumps(payload, ensure_ascii=False,
                          separators=(",", ":"))
        cmd = f"W:MQTT={body}"
        r = self._cmd(cmd, timeout_ms=timeout_ms)
        if r == "RET:MQTT=OK":
            return
        if r.startswith("RET:FAIL:MQTT:"):
            raise DeviceError(r[len("RET:FAIL:MQTT:"):])
        if r.startswith("RET:FAIL:"):
            raise DeviceError(r[len("RET:FAIL:"):])
        raise DeviceError(f"意外应答: {r}")

    #-----------------------------------------------------------------
    def read_mqtt(self, timeout_ms: int = 3000) -> dict:
        """从设备读回 MQTT 三项配置（R:MQTT）。

        设备侧协议（VKBoxLite_sniff 的 lua/iot/mqttcfg.lua + iot/status.lua）：
            发 -> R:MQTT
            收 <- RET:MQTT=<json>          ← json 是 mqttcfg.effective() 的输出
            收 <- RET:FAIL:MQTT:<原因>

        返回的 json 是顶层 dict，至少有 cfg 字段（mqttcfg.load 全字段）；
        我们关心的三项在前端表单回填时取：
            cfg["host"]             服务器地址
            cfg["port"]             端口（int）
            cfg["auto"]["pass"]     凭证密码（自动档密码）

        ⚠️ 设备侧同样可能没有 R:MQTT（旧固件 soft_sn_demo），静默超时抛
           TimeoutError_("设备无响应")。W:MQTT 写过的设备基本都支持读。
        """
        r = self._cmd("R:MQTT", timeout_ms=timeout_ms)
        if r.startswith("RET:MQTT="):
            body = r[len("RET:MQTT="):]
            try:
                payload = json.loads(body)
            except json.JSONDecodeError as e:
                # 把原始应答也带出去，截断到 512 字避免日志炸：
                # 看 char 位置附近就能定位是哪个字段的引号/控制字符出问题。
                # 之前只抛 "Unterminated string" 一句话，对调试没帮助 —— 设备
                # 字段值里带了半个字符 / 控制符，根本看不出来是 cfg.pub_topic 还
                # 是 cfg.host 还是哪一项的问题。
                snippet = body[:512]
                if len(body) > 512:
                    snippet += f"…(总长{len(body)})"
                raise DeviceError(
                    f"设备应答 JSON 无法解析: {e}; "
                    f"原始应答前 512 字: {snippet!r}")
            if not isinstance(payload, dict):
                raise DeviceError(f"设备应答不是 dict: {type(payload).__name__}")
            return payload
        if r.startswith("RET:FAIL:MQTT:"):
            raise DeviceError(r[len("RET:FAIL:MQTT:"):])
        if r.startswith("RET:FAIL:"):
            raise DeviceError(r[len("RET:FAIL:"):])
        raise DeviceError(f"意外应答: {r}")

    #-----------------------------------------------------------------
    def lock(self) -> None:
        r = self._cmd("LOCK:SN")
        if r == "RET:OK":
            return
        if r.startswith("RET:FAIL:"):
            raise DeviceError(r[len("RET:FAIL:"):])
        raise DeviceError(f"意外应答: {r}")

    def unlock(self) -> None:
        r = self._cmd("UNLOCK:SN")
        if r == "RET:OK":
            return
        if r.startswith("RET:FAIL:"):
            raise DeviceError(r[len("RET:FAIL:"):])
        raise DeviceError(f"意外应答: {r}")

    #-----------------------------------------------------------------
    def wait_new_device(self, last_imei: str, timeout_s: float = 30.0) -> DeviceInfo:
        """轮询等待换设备（IMEI 变化）。生产模式用。"""
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            try:
                info = self.read_id()
            except (DeviceError, IOError):
                info = None
            if info and info.imei and info.imei != last_imei:
                return info
            time.sleep(0.5)
        raise TimeoutError_("等待新设备")


# ⚠️ 这里的 log 是【1 个参数】(log(msg))，跟 burner.LogFn 的
#    (level, msg) 不是一回事。ui_app 的 SnBurnerApp._emit 是 2 个参数，
#    直接把它塞进来会在自动识别串口时抛
#    "TypeError: _emit() missing 1 required positional argument"，
#    表现为"连不上设备"。ui_app 那边已用 lambda 适配，
#    _st_connect.py 盯着这个契约，别改回去。
LogFn1 = Callable[[str], None]          # (message)


def find_device_port(baud: int = 115200, log: LogFn1 = print) -> tuple[Optional[str], list[str]]:
    """逐个串口发 R:ID，找到设备口。

    返回 (设备口 or None, 试过的口列表)。
    合宙的虚拟口不一定是 COM4，所以必须探，不能猜。
    """
    tried = []
    for port in list_ports():
        tried.append(port)
        try:
            with SerialPort(port, baud=baud) as sp:
                if Device(sp).ping():
                    log(f"  识别到设备口: {port}")
                    return port, tried
                log(f"  {port}: 无应答")
        except IOError as e:
            log(f"  {port}: {e}")
    return None, tried


if __name__ == "__main__":
    print("=== 设备指令层自检 ===")
    port, tried = find_device_port()
    print(f"\n试过: {tried}")
    if port is None:
        print("没找到设备口（设备没上电？SSCOM 占着口？）")
        raise SystemExit(0)

    with SerialPort(port) as sp:
        dev = Device(sp)
        info = dev.read_id()
        print(f"  IMEI  : {info.imei}")
        print(f"  UID   : {info.uid}")
        print(f"  SN    : {info.sn or '(空)'}")
        print(f"  状态  : {info.state_cn}")
        print(f"  锁定  : {'是' if info.is_locked else '否'}")
        sn = dev.read_sn()
        print(f"  R:SN  : {sn}")

    print("\n设备指令层自检: 通过")
