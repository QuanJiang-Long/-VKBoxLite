"""W:MQTT 指令层的单元测试（不发真串口）。

覆盖 device.Device.write_mqtt 的四类行为：
    1. 发出的指令文本与 VKBoxLite_sniff 的 cmd.lua 期望完全一致
       —— 这是最容易错的地方，字段名/JSON 形态错一个字符设备就不认
    2. RET:MQTT=OK 正常返回
    3. RET:FAIL:MQTT:<err> 抛 DeviceError，reason 是设备原文
    4. 无应答抛 TimeoutError_

另外验证 _cmd 的编码改动（ascii -> utf-8）没破坏原有 SN 指令：
中文密码要能原样发出，而不是抛 UnicodeEncodeError。

用法: python _st_mqtt.py
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from device import Device, DeviceError, TimeoutError_      # noqa: E402


class FakePort:
    """假串口：记录写出的字节，按脚本回话。"""

    def __init__(self, reply=None):
        self.sent = []
        self.reply = reply
        self.read_timeout_ms = 1000
        self.flushed = 0

    def flush(self):
        self.flushed += 1

    def write(self, data: bytes):
        self.sent.append(data)

    def read_line(self):
        if self.reply is None:
            return None
        return self.reply.encode("utf-8")

    @property
    def is_open(self):
        return True

    def close(self):
        pass


def one(reply):
    """构造一个只回一句话的 Device。"""
    fp = FakePort(reply)
    return Device(fp), fp


ok = True


def check(cond: bool, label: str) -> None:
    global ok
    print(("  OK   " if cond else "  FAIL ") + label)
    if not cond:
        ok = False


def main() -> int:
    print("=== W:MQTT 指令层自检 ===")

    #---- 1. 指令文本必须与设备侧 cmd.lua 的解析规则吻合 ----
    # 设备侧 dispatcher: line:match("^%s*([%w:]+)%s*=%s*(.-)%s*$")
    # 即 "W:MQTT=" 后面跟 JSON；JSON 里不能有 \r\n（会被 gsub 掉）
    dev, fp = one("RET:MQTT=OK")
    dev.write_mqtt("dz.voltkun.com", 1883, "VKBOXGW2026KEY")
    raw = fp.sent[0].decode("utf-8")
    print("  发出: " + raw.strip())
    check(raw.endswith("\r\n"), "指令以 \\r\\n 结尾（设备按行解析）")
    check("\n" not in raw.strip(), "指令体不含换行（否则设备侧 gsub 会吃掉）")
    check(raw.startswith("W:MQTT="), "指令以 W:MQTT= 开头")
    body = raw.strip()[len("W:MQTT="):]
    try:
        parsed = json.loads(body)
        parsed_ok = True
    except ValueError:
        parsed, parsed_ok = None, False
    check(parsed_ok, "JSON 部分可被标准 json.loads 解析")
    if parsed_ok:
        check(parsed.get("host") == "dz.voltkun.com", "host 字段正确")
        check(parsed.get("port") == 1883
              and isinstance(parsed["port"], int), "port 是数字 1883")
        check(parsed.get("auto_pass") == "VKBOXGW2026KEY",
              "凭证密码走 auto_pass 键（自动档，用户名用 SN）")
        check("pass" not in parsed, "没有误用手动档的 pass 键")
        check("manual_on" not in parsed, "没有设 manual_on（保持自动档）")
        check(not any(k in parsed for k in ("user", "client_id", "ssl")),
              "只发三项，其余交给设备默认值")

    #---- 2. 紧凑分隔符（不浪费串口行长） ----
    dev, fp = one("RET:MQTT=OK")
    dev.write_mqtt("h", 1, "p")
    raw = fp.sent[0].decode("utf-8")
    check(", " not in raw and '": ' not in raw,
          "JSON 用紧凑分隔符（无空格，缩短串口行）")

    #---- 3. 正常应答 ----
    dev, _ = one("RET:MQTT=OK")
    try:
        dev.write_mqtt("h", 1883, "p")
        check(True, "RET:MQTT=OK 正常返回，不抛异常")
    except Exception as e:                          # noqa: BLE001
        check(False, f"RET:MQTT=OK 不应抛异常，却抛了 {type(e).__name__}: {e}")

    #---- 4. 设备拒绝：reason 必须是设备原文，供 reason_cn 转中文 ----
    for err in ("bad host", "bad port", "no iot", "bad json",
                "no fskv", "encode fail", "too large"):
        dev, _ = one(f"RET:FAIL:MQTT:{err}")
        try:
            dev.write_mqtt("h", 1883, "p")
            check(False, f"RET:FAIL:MQTT:{err} 应当抛 DeviceError")
        except DeviceError as e:
            check(e.reason == err,
                  f"RET:FAIL:MQTT:{err} -> DeviceError.reason == {err!r}")
        except Exception as e:                      # noqa: BLE001
            check(False, f"{err} 抛了错的类型 {type(e).__name__}")

    #---- 5. 无应答 -> 超时（设备不认 W:MQTT 时的表现） ----
    dev, _ = one(None)
    try:
        dev.write_mqtt("h", 1883, "p")
        check(False, "无应答应当抛 TimeoutError_")
    except TimeoutError_:
        check(True, "无应答抛 TimeoutError_（设备不支持 W:MQTT 时会这样）")
    except Exception as e:                          # noqa: BLE001
        check(False, f"无应答抛了错的类型 {type(e).__name__}")

    #---- 6. 编码：中文地址/密码必须能原样发出 ----
    # 旧 _cmd 用 encode("ascii")，中文会抛 UnicodeEncodeError。
    # 设备侧 LuatOS json.decode 解 UTF-8 没问题。
    dev, fp = one("RET:MQTT=OK")
    try:
        dev.write_mqtt("中文.example.com", 1883, "密码")
        raw = fp.sent[0].decode("utf-8")
        check("中文.example.com" in raw and "密码" in raw,
              "中文地址/密码按 UTF-8 原样发出（不抛 UnicodeEncodeError）")
    except UnicodeEncodeError as e:
        check(False, f"中文内容仍按 ascii 编码，抛了 {e}")
    except Exception as e:                          # noqa: BLE001
        check(False, f"中文内容抛了 {type(e).__name__}: {e}")

    #---- 7. 三项全空也照样发（设备回落默认，PC 不拦截） ----
    dev, fp = one("RET:MQTT=OK")
    try:
        dev.write_mqtt("", 1883, "")
        body = fp.sent[0].decode("utf-8").strip()[len("W:MQTT="):]
        parsed = json.loads(body)
        check(parsed == {"host": "", "port": 1883, "auto_pass": ""},
              "三项全空时仍发完整 JSON（由设备回落默认值）")
    except Exception as e:                          # noqa: BLE001
        check(False, f"三项全空时抛了 {type(e).__name__}: {e}")

    #---- 8. 端口被强转 int（界面可能传来字符串） ----
    dev, fp = one("RET:MQTT=OK")
    dev.write_mqtt("h", "8883", "p")
    body = fp.sent[0].decode("utf-8").strip()[len("W:MQTT="):]
    parsed = json.loads(body)
    check(parsed["port"] == 8883 and isinstance(parsed["port"], int),
          "端口即使是字符串也被转成 JSON 数字")

    #---- 9. 原有 SN 指令不受 utf-8 改动影响 ----
    dev, fp = one("RET:SN=11802026092500018")
    sn = dev.read_sn()
    check(sn == "11802026092500018", "read_sn 仍正常（编码改动无副作用）")
    # ⚠️ read_sn 现在先探 R:INFO（当前固件唯一能用的通道），拿不到才兜底
    #    发 R:SN。所以不能再断言"R:SN 是第一条指令"，只能断言"发过 R:SN"。
    sent = [s.decode("utf-8").strip() for s in fp.sent]
    check("R:SN" in sent, "R:SN 指令文本不变（兜底路径仍会发）", )
    check("R:INFO" in sent, "read_sn 会先探 R:INFO（当前固件唯一通道）")

    dev, fp = one("RET:OK")
    dev.write_sn("11802026092500018", force=True)
    check(fp.sent[0].decode("utf-8").strip() == "W:SN=11802026092500018,FORCE",
          "W:SN 指令文本不变")

    #---- 10. reason_cn 覆盖设备侧全部已知原因 ----
    from device import REASON_CN, reason_cn
    for err in ("no iot", "bad json", "bad host", "bad port",
                "bad interval_s", "bad qos", "bad pub_topic",
                "bad sub_topic", "no json lib", "encode fail",
                "too large", "no fskv"):
        cn = reason_cn(err)
        check(cn != err and cn, f"reason_cn({err!r}) 有中文释义")

    print()
    print("W:MQTT 自检: " + ("通过" if ok else "未通过"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
