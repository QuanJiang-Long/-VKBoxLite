"""验证：① UID 清洗 ② still_alive 判活 ③ 掉线监测逻辑。

用法: python _smoke3.py
"""

import traceback

OUT = []


def say(m):
    OUT.append(m)


#=====================================================================
print("=== ① UID / 协议字段清洗 ===")
try:
    from device import clean_field

    cases = [
        # (输入, 期望结果, 说明)
        ("NE033\x13sLE\x00", "NE033.sLE", "控制字符 -> '.'，0x00 被去掉"),
        ("\x4e\x45\x033sLE", "NE.3sLE", "原始二进制 UID 控制字符替换"),
        ("869080075432338", "869080075432338", "正常 IMEI 不受影响"),
        ("11802026092500018", "11802026092500018", "正常 SN 不受影响"),
        ("empty", "empty", "正常 state"),
        ("", "", "空字段原样返回（未烧录时 sn 为空是合法状态）"),
        ("NE033sLE", "NE033sLE", "干净 UID 原样"),
        ("4E45333313", "4E45333313", "新版 hex UID 原样通过"),
        ("\x00\x01", "(空)", "全是控制字符时给可见占位"),
    ]
    for raw, expect, desc in cases:
        got = clean_field(raw)
        ok = got == expect
        say(f"  {'OK ' if ok else 'BAD'} {desc}: {raw!r} -> {got!r}")
        assert ok, f"{desc}: 期望 {expect!r} 实际 {got!r}"

    # 清洗后必须可直接打印 + 可存 CSV：不含控制字符
    for raw in ["NE033\x13sLE\x00", "\x00\x01\x02", "a\x7fb"]:
        got = clean_field(raw)
        assert all(ch.isprintable() or ch == " " for ch in got), \
            f"清洗后仍有不可打印字符: {got!r}"
    say("  清洗后全部可打印 ✓")
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ② R:ID 解析（旧固件乱码 UID）===")
try:
    from device import Device, DeviceInfo
    from serial_port import SerialPort

    class FakePort:
        read_timeout_ms = 1500

        def flush(self):
            pass

        def write(self, data):
            pass

        def read_line(self):
            # 模拟旧固件：UID 带控制字符和 0x00
            return b"RET:ID=imei:869080075432338;uid:NE033\x13sLE\x00;sn:;state:invalid;lock:1"

    info = Device(FakePort()).read_id()
    say(f"  imei={info.imei!r}")
    say(f"  uid ={info.uid!r}")
    say(f"  sn  ={info.sn!r} state={info.state!r} lock={info.lock}")
    assert info.imei == "869080075432338"
    assert info.uid and all(c.isprintable() or c == " " for c in info.uid), \
        f"UID 仍不可打印: {info.uid!r}"
    assert info.state == "invalid" and info.lock == 1
    say("  旧固件乱码 UID 已被清洗成可打印 ✓")
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ③ still_alive 真机判活 ===")
try:
    from device import Device
    from serial_port import SerialPort, list_ports

    sp = SerialPort("COM8", baud=115200, read_timeout_ms=1500)
    sp.open()
    say(f"  COM8 打开, still_alive={sp.still_alive()}")
    assert sp.still_alive() is True
    sp.close()
    say(f"  关闭后 still_alive={sp.still_alive()}")
    assert sp.still_alive() is False, "关闭后必须返回 False"
    say("  判活接口正常 ✓")
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ④ 掉线监测逻辑（连续 N 次不在才断）===")
try:
    import tkinter as tk
    from ui_app import SnBurnerApp, WATCHDOG_MISS_LIMIT, WATCHDOG_INTERVAL_MS

    say(f"  参数: 间隔={WATCHDOG_INTERVAL_MS}ms 容错={WATCHDOG_MISS_LIMIT}次")

    root = tk.Tk()
    app = SnBurnerApp(root)
    root.update_idletasks()

    events = []
    app._emit = lambda lvl, msg: events.append((lvl, msg))

    class DeadPort:
        port = "COM8"
        is_open = True

        def still_alive(self):
            return False

        def close(self):
            self.is_open = False

    app.port = DeadPort()
    app.device = object()
    app.burner = object()
    app.burn_btn.configure(state="normal")
    app._set_status("已连接 COM8", "#1a7f37")

    # 手动驱动 watchdog 到阈值
    for i in range(WATCHDOG_MISS_LIMIT):
        app._miss_count += 1
        app._watchdog_body = None
        # 直接调判定体（跳过 after 调度）
        if app.port is not None and app.port.is_open and not app.port.still_alive():
            if app._miss_count >= WATCHDOG_MISS_LIMIT:
                app._on_disconnected("测试断开")
                break
        else:
            app._miss_count = 0

    say(f"  断开后 status={app.status_lbl['text']!r} burn_btn={app.burn_btn['state']}")
    say(f"  port={app.port} device={app.device}")
    say(f"  日志: {events}")
    assert app.port is None, "断开后 port 应清空"
    assert app.device is None, "断开后 device 应清空"
    assert str(app.burn_btn['state']) == 'disabled', "断开后烧录按钮应禁用"
    assert app.status_lbl['text'] == "已断开"
    assert any("USB" in m for _, m in events), "应提示重新插线"
    say("  掉线自动断开 ✓")
    root.destroy()
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())

say("DONE")
with open("_smoke3.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(OUT))
