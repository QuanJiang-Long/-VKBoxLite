"""连接流程自检（自动识别串口这条分支）。

背景：打包后的 exe 在【全新安装】下连不上设备，报
    连接失败: TypeError: SnBurnerApp._emit() missing 1 required positional argument
根因跟串口、跟设备都没关系 —— 是回调签名对不上：
    device.find_device_port(baud, log=print)   -> log(msg)          1 个参数
    ui_app.SnBurnerApp._emit(level, msg)       -> _emit(level, msg) 2 个参数
以前直接 find_device_port(baud, self._emit)，一进这条分支就 TypeError。
而"工位上一直能用"是因为 config.json 里存了 port=<具体串口>，走的是另一条
分支（chosen），压根没碰 find_device_port。新机器/清空配置的机器必炸。

本自检盯住这个契约：
    1. find_device_port 的 log 回调确实是 1 个参数（用真实函数验证）
    2. ui_app 传进去的适配器能被 1 个参数调用
    3. 走完整的 _connect_worker（自动识别分支）不抛异常，且能拿到端口

用法: python _st_connect.py
"""

import inspect
import os
import queue
import sys
import tkinter as tk

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ok = True


def check(cond, label, extra=""):
    global ok
    print(("  OK   " if cond else "  FAIL ") + label + (("  " + extra) if extra else ""))
    if not cond:
        ok = False


def main() -> int:
    print("=== 连接流程自检 ===")
    import device
    import ui_app

    #---- 1. find_device_port 的 log 契约：1 个参数 ----
    sig = inspect.signature(device.find_device_port)
    n_params = len(sig.parameters)
    check(n_params == 2 and "log" in sig.parameters,
          "find_device_port(baud, log) 签名没变",
          str(sig))

    # 用真实实现验证它到底怎么调 log
    calls = []

    def one_arg_log(msg):
        calls.append(msg)

    # 只探一个不存在的口，让它走到 log 分支后返回
    orig_list_ports = device.list_ports
    device.list_ports = lambda: ["COM__NOT_EXIST__"]
    try:
        port, tried = device.find_device_port(115200, one_arg_log)
    finally:
        device.list_ports = orig_list_ports
    check(port is None and tried == ["COM__NOT_EXIST__"],
          "find_device_port 探测失败时返回 (None, tried)")
    check(len(calls) >= 1 and isinstance(calls[0], str),
          "find_device_port 用 1 个参数调 log", repr(calls[:1]))

    #---- 2/3. ui_app 适配器 + 完整走一遍自动识别分支 ----
    root = tk.Tk()
    root.withdraw()
    try:
        app = ui_app.SnBurnerApp(root)

        emitted = []
        orig_emit = app._emit

        def spy(level, msg):
            emitted.append((level, msg))
            orig_emit(level, msg)

        app._emit = spy

        # 伪造 find_device_port：严格按真实契约用【1 个参数】调 log
        seen = {}

        def fake_find(baud, log=print):
            seen["baud"] = baud
            log("  识别到设备口: COM_FAKE")
            log("  COM_OTHER: 无应答")
            return "COM_FAKE", ["COM_OTHER"]

        orig_find = ui_app.find_device_port
        ui_app.find_device_port = fake_find
        try:
            app._connect_worker("请选择串口", 115200, 1500)
        except Exception as e:                      # noqa: BLE001
            check(False, "自动识别分支不抛异常",
                  f"{type(e).__name__}: {e}")
        else:
            check(True, "自动识别分支不抛异常")
        finally:
            ui_app.find_device_port = orig_find

        check(seen.get("baud") == 115200,
              "find_device_port 收到了正确的波特率", str(seen.get("baud")))
        check(any("识别到设备口" in m for _, m in emitted),
              "find_device_port 的日志被适配成 _emit(level, msg) 收下了",
              str([e for e in emitted][:3]))

        # 结果应进队列，等主线程取
        item = app.result_q.get_nowait()
        check(item[0] == "connect" and item[1] == "COM_FAKE" and item[2] == "",
              "连接结果正确进了 result_q", str(item))
    finally:
        root.destroy()

    print()
    print("连接流程自检: " + ("通过" if ok else "未通过"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
