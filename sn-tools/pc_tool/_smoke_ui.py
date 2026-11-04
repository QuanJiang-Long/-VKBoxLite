"""Q1/Q2/Q3 界面联动冒烟测试：构造真实窗口，点真实按钮。

用法: python _smoke_ui.py
"""

import traceback

import tkinter as tk
from tkinter import messagebox

from ui_app import SnBurnerApp

OUT = []


def say(m):
    OUT.append(m)


try:
    root = tk.Tk()
    app = SnBurnerApp(root)
    root.update_idletasks()

    say(f"初始: next={app.next_var.get()} 工号={app.operator_var.get()!r}")

    # --- Q3: 勾选指定日期 ---
    app.manual_date_var.set(True)
    app._on_manual_toggle()
    root.update()
    say(f"勾选后 date_entry 状态={app.date_entry['state']} "
        f"serial_entry={app.serial_entry['state']}")
    say(f"自动填入今天: {app.date_var.get()}")

    app.date_var.set("20260101")
    app._on_date_return()
    say(f"指定 20260101 后 next={app.next_var.get()}")

    app.serial_var.set("77")
    app._on_serial_return()
    say(f"指定流水 77 后 next={app.next_var.get()}")

    # 非法日期应弹提示且不崩溃
    app.date_var.set("2026")
    app._on_date_return()
    say(f"非法日期后 next 仍为={app.next_var.get()}")

    # 取消勾选 -> 恢复自动
    app.manual_date_var.set(False)
    app._on_manual_toggle()
    say(f"取消勾选后 next={app.next_var.get()}")

    # --- Q1: 工号为空 ---
    app.operator_var.set("")
    warns = []
    messagebox.showwarning = lambda t, m, *a, **k: warns.append((t, m))
    app._burn()
    say(f"工号空点烧录 -> 提示={warns[-1] if warns else None}")
    app._rework()
    say(f"工号空点返修 -> 提示={warns[-1] if warns else None}")

    # --- Q2: 返修密码 ---
    asks = []
    messagebox.askyesno = lambda t, m, *a, **k: asks.append((t, m)) or True
    app.operator_var.set("A001")

    # 模拟密码窗口：_ask_password 用 wait_window，这里直接替掉它
    app._ask_password = lambda: "0000"          # 错密码
    app._rework()
    say(f"错密码 -> 提示={warns[-1] if warns else None}")

    app._ask_password = lambda: "8888"          # 对密码
    app._rework()
    say(f"对密码 -> 二次确认={asks[-1] if asks else None}")

    app._ask_password = lambda: None            # 取消
    app._rework()
    say(f"取消密码 -> 不应弹二次确认, asks 数={len(asks)}")

    # --- 已连接场景：Q1/Q2 才真正生效（未连接时被 _require 挡住）---
    app.busy = False
    app.device = object()                      # 只要非 None 就能过 _require
    app.burner = object()
    app.burn_btn.configure(state="normal")
    root.update()

    warns.clear()
    app.operator_var.set("")
    app._burn()
    say(f"[已连接] 工号空点烧录 -> {warns[-1] if warns else None}")
    app._rework()
    say(f"[已连接] 工号空点返修 -> {warns[-1] if warns else None}")

    app.operator_var.set("A001")
    warns.clear()
    app._ask_password = lambda: "0000"
    app._rework()
    say(f"[已连接] 错密码 -> {warns[-1] if warns else None}")

    app._ask_password = lambda: "8888"
    app._rework()
    say(f"[已连接] 对密码 -> 二次确认={asks[-1] if asks else None}")
    say(f"[已连接] 工号校验通过后是否起了线程: busy={app.busy}")

    say("SMOKE OK")

except Exception:
    say("=== 异常 ===")
    say(traceback.format_exc())

with open("_smoke_ui.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(OUT))
