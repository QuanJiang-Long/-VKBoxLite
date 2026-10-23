"""Burner.lock_only 业务测试。一次性脚本，不并入 build.ps1 跑（已加）。

测的是 burner 那一层：探测 / has_sn / is_locked 短路 / DeviceError 透传。
UI 层的按钮启用规则另在 _chk_ui_layout.py 里测。
"""

import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from device import DeviceError, DeviceInfo         # noqa: E402
from burner import Burner                          # noqa: E402
import sn_rule                                      # noqa: E402
import allocator                                    # noqa: E402

fails = []


def check(cond, msg):
    print(("  OK   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


#----------------------------------------------------------------------
# 假设备 —— 与 _smoke6.py 同款，去掉 burner 用不上的方法
#----------------------------------------------------------------------
class FakeDevice:
    def __init__(self, sn="", lock=0, imei="869080075432338", uid="4E45333313"):
        self.sn = sn
        self._locked = lock
        self.imei = imei
        self.uid = uid
        self.writes = []
        self.fail_lock = None

    def ping(self): return True

    def read_id(self):
        return DeviceInfo(imei=self.imei, uid=self.uid, sn=self.sn,
                          state="ready" if self.sn else "empty",
                          lock=self._locked)

    def read_sn(self): return self.sn or "EMPTY"

    def write_sn(self, sn, force=False): self.writes.append((sn, force)); self.sn = sn

    def lock(self):
        if self.fail_lock:
            raise DeviceError(self.fail_lock)
        self._locked = 1

    def unlock(self):
        if not self._locked:
            raise DeviceError("not locked")
        self._locked = 0


class Log:
    def __init__(self): self.lines = []
    def __call__(self, lvl, msg): self.lines.append((lvl, msg))


def fresh_alloc():
    r"""造一个全新 Allocator，不动 pc_tool/data/ 里的真数据。

    注意：不能放 /tmp —— 沙箱里 C:\Users\...\AppData\Local\Temp 是
    只读的，会 PermissionError。放在工作区下，测试完 shutil.rmtree。
    """
    tmp = os.path.join(HERE, f"_chk_lock_tmp_{os.getpid()}")
    os.makedirs(tmp, exist_ok=True)
    return allocator.Allocator(
        sn_rule.SnRule(),
        os.path.join(tmp, "counter.json"),
        os.path.join(tmp, "ledger.csv"),
    )


#=====================================================================
print("=== ① 主路径：有 SN + 未锁 -> 调 LOCK:SN + 日志 OK ===")
try:
    a = fresh_alloc()
    dev = FakeDevice(sn="11802026092500018", lock=0)
    log = Log()
    r = Burner(dev, a, log=log).lock_only(operator="W001")
    check(r.ok, f"返回 ok: {r}")
    check(r.sn == "11802026092500018", f"sn 在结果里: {r.sn}")
    check(dev._locked == 1, f"设备应已锁: {dev._locked}")
    check(len(dev.writes) == 0, f"不应写 SN: {dev.writes}")
    ok_lines = [m for lvl, m in log.lines if lvl == "OK" and "手动上锁" in m]
    check(len(ok_lines) == 1, f"应有一条 'OK 手动上锁' 日志: {ok_lines}")
    # 台账不应增加记录
    check(a.ledger.find_by_imei(dev.imei) is None,
          "单纯上锁不应写台账")
except Exception:
    print("    === 异常 ===")
    print(traceback.format_exc())
    fails.append("① 主路径异常")


#=====================================================================
print("=== ② 短路：已锁 -> 不调 LOCK:SN，返 ok ===")
try:
    a = fresh_alloc()
    dev = FakeDevice(sn="11802026092500018", lock=1)        # 已锁
    # 让 lock() 抛，验证根本不被调到
    dev.fail_lock = "no sn"
    log = Log()
    r = Burner(dev, a, log=log).lock_only(operator="W001")
    check(r.ok, f"已锁时直接返 ok: {r}")
    check(dev._locked == 1, f"仍是 1（没被错误改成 0）: {dev._locked}")
    info_lines = [m for lvl, m in log.lines if lvl == "INFO" and "已是上锁" in m]
    check(len(info_lines) == 1, f"应给一条 '设备已是上锁' 信息: {info_lines}")
except Exception:
    print("    === 异常 ===")
    print(traceback.format_exc())
    fails.append("② 短路异常")


#=====================================================================
print("=== ③ 拒绝：设备没 SN -> 返 ok=False + reason=cn")
try:
    a = fresh_alloc()
    dev = FakeDevice(sn="", lock=0)                         # 空的
    r = Burner(dev, a, log=Log()).lock_only(operator="W001")
    check(not r.ok, f"应失败: {r}")
    check("没有 SN" in r.reason_cn or "没有SN" in r.reason_cn,
          f"reason 指向 '没有 SN': {r.reason_cn!r}")
    check(dev._locked == 0, "失败时不应改锁标志")
except Exception:
    print("    === 异常 ===")
    print(traceback.format_exc())
    fails.append("③ 空设备异常")


#=====================================================================
print("=== ④ 透传：DeviceError 冒泡 ===")
try:
    a = fresh_alloc()
    dev = FakeDevice(sn="11802026092500018", lock=0)
    dev.fail_lock = "no sn"                                 # 假装设备侧抛
    r = Burner(dev, a, log=Log()).lock_only(operator="W001")
    check(not r.ok, "上锁失败应返 ok=False")
    check("no sn" in r.reason or r.step.value == "上锁",
          f"失败步骤/原因应含 '上锁' 或 'no sn': step={r.step} reason={r.reason}")
except Exception:
    print("    === 异常 ===")
    print(traceback.format_exc())
    fails.append("④ DeviceError 透传异常")


#=====================================================================
print("=== ⑤ IOError 透传 ===")
try:
    a = fresh_alloc()
    dev = FakeDevice(sn="11802026092500018", lock=0)

    def boom_lock():
        raise IOError("USB 拔了")
    dev.lock = boom_lock
    r = Burner(dev, a, log=Log()).lock_only(operator="W001")
    check(not r.ok, "IOError 应被捕获返 ok=False")
    check(r.step.value == "上锁", f"失败步骤是上锁: {r.step.value}")
    check("串口错误" in r.reason_cn, f"原因含 '串口错误': {r.reason_cn!r}")
except Exception:
    print("    === 异常 ===")
    print(traceback.format_exc())
    fails.append("⑤ IOError 异常")


#=====================================================================
print("=== ⑥ 探测阶段也接受 IOError 透传（设备拔了等）===")
try:
    a = fresh_alloc()
    dev = FakeDevice(sn="11802026092500018", lock=0)

    def boom_id():
        raise IOError("USB 拔了")
    dev.read_id = boom_id
    r = Burner(dev, a, log=Log()).lock_only(operator="W001")
    check(not r.ok, "探测 IOError 应被捕获")
    check(r.step.value == "探测", f"失败步骤是探测: {r.step.value}")
    check("串口错误" in r.reason_cn, f"原因含 '串口错误': {r.reason_cn!r}")
except Exception:
    print("    === 异常 ===")
    print(traceback.format_exc())
    fails.append("⑥ 探测 IOError 异常")


#=====================================================================
print("=== ⑦ 探测阶段 DeviceError 透传 ===")
try:
    a = fresh_alloc()
    dev = FakeDevice(sn="11802026092500018", lock=0)

    def boom_id():
        raise DeviceError("timeout")
    dev.read_id = boom_id
    r = Burner(dev, a, log=Log()).lock_only(operator="W001")
    check(not r.ok, "探测 DeviceError 应被捕获")
    check(r.step.value == "探测", f"失败步骤是探测: {r.step.value}")
except Exception:
    print("    === 异常 ===")
    print(traceback.format_exc())
    fails.append("⑦ 探测 DeviceError 异常")


#=====================================================================
print("=== ⑧ 日志带工号 ===")
try:
    a = fresh_alloc()
    dev = FakeDevice(sn="11802026092500018", lock=0)
    log = Log()
    Burner(dev, a, log=log).lock_only(operator="W007")
    msgs = [m for _, m in log.lines]
    has_op = any("W007" in m for m in msgs)
    check(has_op, f"日志里出现工号 W007: {msgs}")
except Exception:
    print("    === 异常 ===")
    print(traceback.format_exc())
    fails.append("⑧ 日志带工号异常")


#=====================================================================
print("=== ⑨ 计数器、台账：纯上锁一动不动 ===")
try:
    a = fresh_alloc()
    # 烧一台，让计数器/台账都有数据
    dev = FakeDevice(sn="", lock=0)
    Burner(dev, a, auto_lock=True, log=Log()).burn(operator="W001")
    # 烧完后设备是 lock=1
    check(dev._locked == 1, f"burn 后设备已锁: {dev._locked}")
    # 模拟烧完后再来一次 lock_only —— 设备已锁应直接返 ok
    log = Log()
    r = Burner(dev, a, log=log).lock_only(operator="W002")
    check(r.ok, f"已锁时再调 lock_only 应返 ok: {r}")
    next_after = a.peek()
    # peek 是 next_serial 的预读：burn 已经消耗一个，再 burn 一次 next 应该 = 2
    # 然后 lock_only 不应消耗
    check(next_after == 2, f"计数器没动: {next_after}")
    # 台账只有一条 burn 记录
    rows = [r for r in a.ledger._rows]
    check(len(rows) == 1, f"台账只有 burn 那一条: {len(rows)}")
except Exception:
    print("    === 异常 ===")
    print(traceback.format_exc())
    fails.append("⑨ 计数器/台账异常")


print("\n" + ("全部通过" if not fails else f"有 {len(fails)} 项失败: {fails}"))

# 清理测试用临时目录
import shutil
for d in os.listdir(HERE):
    if d.startswith("_chk_lock_tmp_"):
        shutil.rmtree(os.path.join(HERE, d), ignore_errors=True)
sys.exit(1 if fails else 0)
