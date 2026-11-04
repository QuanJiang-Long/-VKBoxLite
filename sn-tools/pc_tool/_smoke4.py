"""验证：① 去掉仅探测按钮 ② SN 查询功能（IMEI / UID）。

用法: python _smoke4.py
"""

import os
import shutil
import traceback

OUT = []


def say(m):
    OUT.append(m)


#=====================================================================
print("=== ① 仅探测按钮已移除 ===")
try:
    import tkinter as tk
    from ui_app import SnBurnerApp

    root = tk.Tk()
    app = SnBurnerApp(root)
    root.update_idletasks()

    btns = []
    for w in root.winfo_children():
        def walk(w):
            try:
                for c in w.winfo_children():
                    if isinstance(c, tk.Button) or c.winfo_class() == "TButton":
                        try:
                            btns.append(c["text"])
                        except Exception:
                            pass
                    walk(c)
            except Exception:
                pass
        walk(w)
    say(f"  窗口内所有按钮: {btns}")
    assert "仅探测" not in btns, "仅探测按钮应已移除"
    assert "查询" in btns, "查询按钮应存在"
    assert "查本机" in btns, "查本机按钮应存在"
    assert "烧 录 下 一 台" in btns
    say("  仅探测已去除，查询/查本机已就位 ✓")

    # _probe_only 仍可用于内部刷新，且不再需要连接检查
    assert callable(app._probe_only)
    say("  _probe_only 保留为内部刷新（连接/烧录后自动调）✓")
    root.destroy()
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ② Ledger.query 按 IMEI / UID 查 ===")
try:
    import sn_rule
    from allocator import Allocator

    TMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_smoke4_tmp")
    if os.path.isdir(TMP):
        shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP)

    alloc = Allocator(sn_rule.SnRule(),
                      os.path.join(TMP, "counter.json"),
                      os.path.join(TMP, "ledger.csv"))

    class Info:
        def __init__(self, imei, uid):
            self.imei, self.uid = imei, uid

    # 造三台设备的记录
    for imei, uid, tag in [("869080075432338", "4E45333313", "A"),
                           ("869080075432339", "4E45333314", "B"),
                           ("869080075432340", "4E45333315", "C")]:
        a = alloc.allocate()
        alloc.record_ok(Info(imei, uid), a, "W001")

    # 一次失败记录（IMEI 同第一台）
    a = alloc.allocate()
    alloc.record_fail(Info("869080075432338", "4E45333313"), a, "locked", "W001")

    r = alloc.ledger.query("869080075432338")
    say(f"  按 IMEI 查: {len(r)} 条, 首条 sn={r[0]['sn']} result={r[0]['result']}")
    assert len(r) == 2 and r[0]["result"] == "ok", "成功记录应排最前"

    r = alloc.ledger.query("4E45333314")
    say(f"  按 UID 查: {len(r)} 条, sn={r[0]['sn']}")
    assert len(r) == 1 and r[0]["sn"].startswith("1180")

    r = alloc.ledger.query("4e45333314")     # 小写也应命中
    say(f"  按小写 UID 查: {len(r)} 条")
    assert len(r) == 1, "大小写不敏感"

    r = alloc.ledger.query("869080075499999")
    say(f"  查不存在的 IMEI: {len(r)} 条")
    assert r == [], "查不到应返回空"

    r = alloc.ledger.query("")
    assert r == [], "空关键词应返回空"
    say("  query 行为全部正确 ✓")
    shutil.rmtree(TMP, ignore_errors=True)
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ③ 查询界面联动（含查本机走队列）===")
try:
    import tkinter as tk
    from ui_app import SnBurnerApp

    root = tk.Tk()
    app = SnBurnerApp(root)
    root.update_idletasks()

    # 预置一个 alloc 的假台账
    class FakeLedger:
        def query(self, kw):
            if kw == "869080075432338":
                return [{"time": "2026-09-25 12:00:00", "imei": kw,
                         "uid": "4E45333313", "sn": "11802026092500018",
                         "result": "ok", "operator": "W001", "rework": "0"},
                        {"time": "2026-09-25 12:05:00", "imei": kw,
                         "uid": "4E45333313", "sn": "11802026092500026",
                         "result": "fail", "reason": "locked",
                         "operator": "W001", "rework": "0"}]
            return []

    class FakeAlloc:
        ledger = FakeLedger()

    app.alloc = FakeAlloc()

    # 空输入
    app.query_var.set("")
    app._do_query()
    say(f"  空输入提示: {app.query_result['text']!r}")
    assert "请输入" in app.query_result["text"]

    # 查不到
    app.query_var.set("999")
    app._do_query()
    say(f"  查不到: {app.query_result['text'].splitlines()[0]!r}")
    assert "未查到" in app.query_result["text"]

    # 查得到
    app.query_var.set("869080075432338")
    app._do_query()
    txt = app.query_result["text"]
    say("  查得到:")
    for ln in txt.splitlines():
        say(f"    {ln}")
    assert "11802026092500018" in txt, "应显示当前生效 SN"
    assert "W001" in txt, "应显示操作员"
    assert "历史记录 2 条" in txt, "应列历史"

    # 查本机：未连接
    app.device = None
    app._fill_query_from_device()
    say(f"  未连接查本机: {app.query_result['text']!r}")
    assert "尚未连接" in app.query_result["text"]

    # 查本机：已连接，走队列
    class FakeDevice:
        def read_id(self):
            class I:
                imei = "869080075432338"
            return I()

    app.device = FakeDevice()
    app._fill_query_from_device()
    app._drain_result()          # 手动排空队列（等价于主循环轮询）
    say(f"  查本机结果: {app.query_result['text'].splitlines()[0]!r}")
    assert "11802026092500018" in app.query_result["text"], "查本机应自动带出结果"
    say("  查询界面联动 ✓")
    root.destroy()
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())

say("DONE")
with open("_smoke4.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(OUT))
