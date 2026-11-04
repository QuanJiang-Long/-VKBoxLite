"""验证：① 密码窗居中 ② 台账被占用时日志给出真实原因。

用法: python _smoke2.py
"""

import os
import shutil
import traceback

OUT = []


def say(m):
    OUT.append(m)


#=====================================================================
print("=== ① 密码窗居中 ===")
try:
    import tkinter as tk
    from ui_app import SnBurnerApp

    root = tk.Tk()
    app = SnBurnerApp(root)
    root.geometry("1000x800+100+100")
    root.update_idletasks()

    captured = {}

    real_after = app.root.after

    def fake_wait_window(win):
        # 在窗口真的关闭前，抓它的位置
        win.update_idletasks()
        w, h = win.winfo_width(), win.winfo_height()
        sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
        captured["geom"] = win.geometry()
        captured["size"] = (w, h)
        captured["screen"] = (sw, sh)
        captured["center"] = ((sw - w) // 2, (sh - h) // 2)
        win.destroy()

    app.root.wait_window = fake_wait_window
    pwd = app._ask_password()
    say(f"  返回: {pwd!r}（取消应为 None）")
    say(f"  窗口尺寸: {captured['size']}")
    say(f"  屏幕尺寸: {captured['screen']}")
    say(f"  期望中心点: {captured['center']}")
    say(f"  实际 geometry: {captured['geom']}")
    assert captured["geom"] == (f"{captured['size'][0]}x{captured['size'][1]}"
                                f"+{captured['center'][0]}+{captured['center'][1]}"), \
        "窗口应精确居中"
    say("  密码窗已屏幕居中 ✓")
    root.destroy()
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ② 台账被占用时给出真实原因 ===")
try:
    import sn_rule
    from allocator import Allocator

    TMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_smoke2_tmp")
    if os.path.isdir(TMP):
        shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP)
    path = os.path.join(TMP, "ledger.csv")
    open(path, "a").close()

    # 用只读权限模拟"被占用"
    os.chmod(path, 0o444)
    try:
        alloc = Allocator(sn_rule.SnRule(), os.path.join(TMP, "counter.json"), path)
        info = type("I", (), {"imei": "869080075432338", "uid": "NE033sLE"})()
        ok = alloc.record_ok(info, alloc.allocate(), "A001")
        say(f"  record_ok 返回: {ok}（应为 False，不抛异常）")
        say(f"  last_error: {alloc.ledger.last_error}")
        say(f"  describe_error: {alloc.ledger.describe_error()}")
        assert ok is False
        assert "Errno 13" in alloc.ledger.last_error
        assert "Excel" in alloc.ledger.describe_error()
        say("  真实原因已透出 ✓")
    finally:
        os.chmod(path, 0o666)

    n = alloc.ledger.flush_pending()
    say(f"  恢复后补写: {n} 条")
    assert n == 1
    shutil.rmtree(TMP, ignore_errors=True)
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())

say("DONE")
with open("_smoke2.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(OUT))
