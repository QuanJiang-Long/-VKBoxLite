"""验证补烧功能：按钮显隐条件 + Burner.recover 全部分支。

用法: python _smoke6.py
"""

import os
import shutil
import traceback

OUT = []


def say(m):
    OUT.append(m)


#=====================================================================
# 假设备
#=====================================================================
class FakeDevice:
    def __init__(self, sn="", lock=0, imei="869080075432338", uid="4E45333313"):
        self.sn = sn
        self._locked = lock      # 不能叫 self.lock，会遮住 lock() 方法
        self.imei = imei
        self.uid = uid
        self.writes = []
        self.fail_write = None
        self.fail_lock = None

    def ping(self):
        return True

    def read_id(self):
        from device import DeviceInfo
        return DeviceInfo(imei=self.imei, uid=self.uid, sn=self.sn,
                          state="ready" if self.sn else "empty", lock=self._locked)

    def read_sn(self):
        return self.sn or "EMPTY"

    def write_sn(self, sn, force=False):
        if self.fail_write:
            raise DeviceError(self.fail_write)
        self.writes.append((sn, force))
        self.sn = sn

    def lock(self):
        if self.fail_lock:
            raise DeviceError(self.fail_lock)
        self._locked = 1

    def unlock(self):
        if not self._locked:
            raise DeviceError("not locked")
        self._locked = 0


class Log:
    def __init__(self):
        self.lines = []

    def __call__(self, lvl, msg):
        self.lines.append((lvl, msg))


from device import DeviceError          # noqa: E402
import sn_rule                          # noqa: E402
from allocator import Allocator         # noqa: E402
from burner import Burner               # noqa: E402

TMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_smoke6_tmp")
if os.path.isdir(TMP):
    shutil.rmtree(TMP, ignore_errors=True)
os.makedirs(TMP)


def new_env():
    d = os.path.join(TMP, f"c{len(os.listdir(TMP)) + 1}")
    os.makedirs(d)
    return Allocator(sn_rule.SnRule(), os.path.join(d, "counter.json"),
                     os.path.join(d, "ledger.csv"))


class Info:
    def __init__(self, imei, uid):
        self.imei, self.uid = imei, uid


#=====================================================================
print("=== ① 主路径：空设备 + 台账有绑定 -> 补烧旧号 ===")
try:
    alloc = new_env()
    # 先正常烧一台，拿到它绑定的号
    dev = FakeDevice()
    r1 = Burner(dev, alloc, auto_lock=True, log=Log()).burn(operator="W001")
    bound_sn = r1.sn
    next_before = alloc.peek()
    say(f"  首次烧录: {bound_sn}，当时 next={next_before}")

    # 模拟重刷固件：SN 丢了，锁也没了（FSKV 全擦）
    dev.sn = ""
    dev._locked = 0
    log = Log()
    r2 = Burner(dev, alloc, auto_lock=True, log=log).recover(bound_sn, operator="W001")

    say(f"  补烧结果: ok={r2.ok} sn={r2.sn}")
    say(f"  设备写入记录: {dev.writes}")
    say(f"  设备最终: sn={dev.sn} lock={dev._locked}")
    say(f"  流水号 next: {next_before} -> {alloc.peek()}")
    for lvl, m in log.lines:
        say(f"    [{lvl}] {m}")

    assert r2.ok, f"补烧应成功: {r2}"
    assert dev.sn == bound_sn, "设备应写回旧号"
    assert dev._locked == 1, "补烧后应自动上锁"
    # 只看补烧那一次写入：应是旧号、且不带 FORCE（设备为空不需要）
    assert dev.writes[-1] == (bound_sn, False), \
        f"空设备补烧不应带 FORCE: {dev.writes[-1]}"
    assert alloc.peek() == next_before, \
        f"补烧绝不能消耗流水号: {next_before} -> {alloc.peek()}"
    rows = alloc.ledger._rows
    rec = [r for r in rows if r.get("reason") == "recover"]
    say(f"  台账 recover 记录: {len(rec)} 条, sn={rec[0]['sn'] if rec else None}")
    assert len(rec) == 1 and rec[0]["sn"] == bound_sn, "应记一条 recover"
    say("  主路径 ✓")
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ② 拒绝：设备已有不同 SN ===")
try:
    alloc = new_env()
    dev = FakeDevice()
    r1 = Burner(dev, alloc, auto_lock=True, log=Log()).burn(operator="W001")
    dev.sn = "11802026092599999"          # 变成另一个号
    r2 = Burner(dev, alloc, auto_lock=True, log=Log()).recover(r1.sn, operator="W001")
    say(f"  结果: ok={r2.ok} reason={r2.reason}")
    assert not r2.ok and "已有 SN" in r2.reason
    say("  已拦下 ✓")
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ③ 拒绝：设备已上锁 ===")
try:
    alloc = new_env()
    dev = FakeDevice()
    r1 = Burner(dev, alloc, auto_lock=True, log=Log()).burn(operator="W001")
    dev.sn = ""                           # 锁还在但 SN 丢了
    r2 = Burner(dev, alloc, auto_lock=True, log=Log()).recover(r1.sn, operator="W001")
    say(f"  结果: ok={r2.ok} reason={r2.reason}")
    assert not r2.ok and r2.reason == "locked"
    say("  已拦下（提示走返修解锁）✓")
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ④ 拒绝：台账里这个 IMEI 绑的不是这个号（防张冠李戴）===")
try:
    alloc = new_env()
    # 设备 A 正常烧一个号
    devA = FakeDevice(imei="869080075432338")
    Burner(devA, alloc, auto_lock=True, log=Log()).burn(operator="W001")
    snA = alloc.ledger.find_by_imei("869080075432338")["sn"]

    # 设备 B 也烧一个号（不同 IMEI，不同 SN）
    devB = FakeDevice(imei="869080099999999")
    Burner(devB, alloc, auto_lock=True, log=Log()).burn(operator="W001")
    snB = alloc.ledger.find_by_imei("869080099999999")["sn"]
    assert snA != snB, "两台设备应分到不同号"

    # 设备 B 丢了 SN，却想补烧设备 A 的号 -> 必须拒绝
    devB.sn = ""
    devB._locked = 0
    r = Burner(devB, alloc, auto_lock=True, log=Log()).recover(snA, operator="W001")
    say(f"  B({devB.imei}) 想补烧 A 的号 {snA}")
    say(f"  结果: ok={r.ok} reason={r.reason}")
    assert not r.ok, "绝不允许把 A 的号烧到 B 上"
    assert "绑定的是" in r.reason, f"原因应指明台账绑定的是别的号: {r.reason}"
    assert devB.writes[-1] != (snA, False), "绝不该写入 A 的号"
    say("  已拦下 ✓")
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ⑤ 幂等：设备已经是这个号 ===")
try:
    alloc = new_env()
    dev = FakeDevice()
    r1 = Burner(dev, alloc, auto_lock=True, log=Log()).burn(operator="W001")
    r2 = Burner(dev, alloc, auto_lock=True, log=Log()).recover(r1.sn, operator="W001")
    say(f"  结果: ok={r2.ok} sn={r2.sn}")
    assert r2.ok and r2.sn == r1.sn
    say("  幂等成功 ✓")
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ⑥ 写入失败 -> 明确报失败（不谎报成功）===")
try:
    alloc = new_env()
    dev = FakeDevice()
    r1 = Burner(dev, alloc, auto_lock=True, log=Log()).burn(operator="W001")
    # 模拟重刷固件：SN 和锁都没了，但这次写入会失败
    dev.sn = ""
    dev._locked = 0
    dev.fail_write = "checksum invalid"
    r2 = Burner(dev, alloc, auto_lock=True, log=Log()).recover(r1.sn, operator="W001")
    say(f"  结果: ok={r2.ok} step={r2.step} reason={r2.reason}")
    assert not r2.ok, "写入失败绝不能报成功"
    assert r2.step.value == "写入", f"失败应定位到写入步: {r2.step}"
    assert dev._locked == 0, "写入失败不应上锁"
    say("  已正确报失败 ✓")
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ⑦ 界面：按钮显隐条件 ===")
try:
    import tkinter as tk
    from ui_app import SnBurnerApp
    from device import DeviceInfo

    root = tk.Tk()
    app = SnBurnerApp(root)
    root.update_idletasks()

    def visible():
        # winfo_ismapped 需要窗口真正完成一次布局才准，先 update 再问
        root.update()
        return app.recover_row.winfo_ismapped()

    def btn_state():
        return str(app.recover_btn['state'])

    def lbl():
        return app.recover_lbl['text']

    # 初始：没查过 -> 不显示
    say(f"  初始: 显示={visible()}  recover_sn={app.recover_sn!r}")
    assert not visible(), "未查询时应隐藏"

    # 查到一个绑定的号
    app.alloc = new_env()
    dev = FakeDevice()
    Burner(dev, app.alloc, auto_lock=True, log=Log()).burn(operator="W001")
    bound = app.alloc.ledger.find_by_imei("869080075432338")["sn"]
    app.query_var.set("869080075432338")
    app._do_query()
    say(f"  查到 {bound}，但未连接设备: 显示={visible()}")
    assert not visible(), "未连接设备时应隐藏"

    # 连接设备（空 SN）-> 按钮应出现且可点
    app.device = object()
    app._show_info(DeviceInfo(imei="869080075432338", uid="4E45333313",
                              sn="", state="empty", lock=0))
    say(f"  空设备已连接: 显示={visible()} 按钮={btn_state()}")
    say(f"    说明: {lbl()}")
    assert visible(), "空设备 + 有绑定号 -> 按钮应出现"
    assert "normal" in btn_state(), "应可点击"
    assert bound in lbl()

    # 设备已有相同 SN -> 禁用 + 说明
    app._show_info(DeviceInfo(imei="869080075432338", uid="4E45333313",
                              sn=bound, state="ready", lock=1))
    say(f"  设备已是该号: 显示={visible()} 按钮={btn_state()} 说明={lbl()!r}")
    assert visible() and "disabled" in btn_state()
    assert "无需补烧" in lbl()

    # 设备已有不同 SN -> 禁用 + 提示走返修
    app._show_info(DeviceInfo(imei="869080075432338", uid="4E45333313",
                              sn="11802026092599999", state="ready", lock=1))
    say(f"  设备有其它号: 按钮={btn_state()} 说明={lbl()!r}")
    assert "disabled" in btn_state() and "返修" in lbl()

    # 空 SN 但已上锁 -> 禁用 + 提示先解锁
    app._show_info(DeviceInfo(imei="869080075432338", uid="4E45333313",
                              sn="", state="empty", lock=1))
    say(f"  空号但已锁: 按钮={btn_state()} 说明={lbl()!r}")
    assert "disabled" in btn_state() and "解锁" in lbl()

    # 查询没有绑定 -> 隐藏
    app.query_var.set("869080000000000")
    app._do_query()
    say(f"  查不到绑定: 显示={visible()}")
    assert not visible(), "没查到绑定号时应隐藏"

    # 断开连接 -> 隐藏
    app.query_var.set("869080075432338")
    app._do_query()
    app._show_info(DeviceInfo(imei="869080075432338", uid="4E45333313",
                              sn="", state="empty", lock=0))
    assert visible()
    app._disconnect_click()
    say(f"  断开后: 显示={visible()}")
    assert not visible(), "断开后应隐藏"

    say("  界面显隐全部正确 ✓")
    root.destroy()
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())


#=====================================================================
print("=== ⑧ 按钮位置在查询行正下方 ===")
try:
    import tkinter as tk
    from ui_app import SnBurnerApp
    from device import DeviceInfo

    root = tk.Tk()
    app = SnBurnerApp(root)
    root.update_idletasks()
    app.alloc = new_env()
    dev = FakeDevice()
    Burner(dev, app.alloc, auto_lock=True, log=Log()).burn(operator="W001")
    app.query_var.set("869080075432338")
    app._do_query()
    app.device = object()
    app._show_info(DeviceInfo(imei="869080075432338", uid="4E45333313",
                              sn="", state="empty", lock=0))
    root.update()

    # pack 顺序：recover_row 必须在 query_result 之前
    parent = app.recover_row.master
    order = [str(w) for w in parent.winfo_children()]
    say(f"  查询卡片内控件顺序:")
    for w in parent.winfo_children():
        say(f"    {w.winfo_class():12} y={w.winfo_y():4}  "
            f"{getattr(w, 'winfo_text', lambda: '')() if w.winfo_class() == 'TLabel' else ''}")
    assert app.recover_row.winfo_y() < app.query_result.winfo_y(), \
        "补烧行应在查询结果文字上方（即查询按钮正下方）"
    say("  位置正确 ✓")
    root.destroy()
except Exception:
    say("  === 异常 ===")
    say(traceback.format_exc())

shutil.rmtree(TMP, ignore_errors=True)
say("DONE")
with open("_smoke6.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(OUT))

