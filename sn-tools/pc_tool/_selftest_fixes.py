"""Q1/Q2/Q3 + 台账 PermissionError 修复的自检。全部用假 Device，不碰真机。

用法: python _selftest_fixes.py
"""

import os
import shutil
import traceback

import sn_rule
import config as cfg_mod
from allocator import Allocator, AllocatorError
from burner import Burner, BurnResult, Step
from device import DeviceError

# 沙箱禁止写系统 Temp（WinError 5），用工作区内的本地目录
TMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_selftest_tmp")
if os.path.isdir(TMP):
    shutil.rmtree(TMP, ignore_errors=True)
os.makedirs(TMP, exist_ok=True)

PASS = []
FAIL = []


def check(name, fn):
    try:
        fn()
        PASS.append(name)
        print(f"  [PASS] {name}")
    except Exception as e:
        FAIL.append(f"{name}: {e}")
        print(f"  [FAIL] {name}: {e}")
        traceback.print_exc()


#=====================================================================
# 假设备：不发串口，直接按脚本应答
#=====================================================================
class FakeDevice:
    def __init__(self):
        self.sn = ""
        self._locked = 0        # 不能用 self.lock，会遮住 lock() 方法
        self.writes = []
        self.fail_write = None

    def ping(self):
        return True

    def read_id(self):
        from device import DeviceInfo
        return DeviceInfo(imei="869080075432338", uid="NE033sLE",
                          sn=self.sn, state="ready" if self.sn else "empty",
                          lock=self._locked)

    def read_sn(self):
        return self.sn or "EMPTY"

    def write_sn(self, sn, force=False):
        if self.fail_write:
            raise DeviceError(self.fail_write)
        self.writes.append((sn, force))
        self.sn = sn

    def lock(self):
        self._locked = 1

    def unlock(self):
        if not self._locked:
            raise DeviceError("not locked")
        self._locked = 0


class LogCollector:
    def __init__(self):
        self.lines = []

    def __call__(self, level, msg):
        self.lines.append((level, msg))


_n = [0]


def new_env():
    """每个用例一套干净的计数器+台账。"""
    _n[0] += 1
    d = os.path.join(TMP, f"case{_n[0]}")
    os.makedirs(d, exist_ok=True)
    rule = sn_rule.SnRule()
    alloc = Allocator(rule, os.path.join(d, "counter.json"),
                      os.path.join(d, "ledger.csv"))
    return rule, alloc


#=====================================================================
print("=== Q3a: 日期手动覆盖 ===")
def t_manual_date():
    _, alloc = new_env()
    auto = alloc.preview()
    alloc.set_manual_date("20260101")
    manual = alloc.preview()
    assert auto != manual, "手动日期应改变 SN"
    assert manual.startswith("118020260101"), manual
    alloc.set_manual_date(None)
    assert alloc.preview() == auto, "恢复自动后应回到按当天日期"

check("手动日期覆盖与恢复", t_manual_date)


def t_bad_date():
    _, alloc = new_env()
    # 空字符串 = 恢复按当天日期（UI 上勾选后清空输入框的合理语义），不算错误
    alloc.set_manual_date("")
    assert alloc.manual_date is None, "空字符串应等价于自动"
    for bad in ["2026", "20261332", "abcdefgh", "20260230"]:
        try:
            alloc.set_manual_date(bad)
        except AllocatorError:
            continue
        raise AssertionError(f"非法日期 {bad!r} 应被拒绝")

check("非法日期全部拒绝", t_bad_date)


print("=== Q3b: 起始流水号手动设置 ===")
def t_serial_start():
    _, alloc = new_env()
    alloc.set_manual_serial_start(50)
    a = alloc.allocate()
    assert a.serial == 50, a.serial
    b = alloc.allocate()
    assert b.serial == 51, b.serial

check("起始流水号生效并连续", t_serial_start)


def t_serial_no_backward():
    _, alloc = new_env()
    alloc.set_manual_serial_start(50)
    alloc.allocate()
    try:
        alloc.set_manual_serial_start(10)
    except AllocatorError:
        return
    raise AssertionError("往小改流水号应被拒绝（会重发已用过的号）")

check("流水号禁止往小改", t_serial_no_backward)


print("=== 台账 PermissionError 不再否决烧录结果 ===")
def t_ledger_locked():
    rule, alloc = new_env()
    dev = FakeDevice()
    r = Burner(dev, alloc, auto_lock=True, log=LogCollector()).burn(operator="A001")
    assert r.ok, f"应成功: {r}"
    assert dev.sn == r.sn
    # 台账文件设成只读，模拟被 Excel 占用（PermissionError）
    os.chmod(alloc.ledger.path, 0o444)
    try:
        _, alloc2 = new_env()                     # 复用同一个台账路径
        r2 = Burner(FakeDevice(), alloc2, auto_lock=True,
                    log=LogCollector()).burn(operator="A001")
        assert r2.ok, f"台账写不进去时烧录仍应判成功: {r2}"
    finally:
        os.chmod(alloc.ledger.path, 0o666)

check("台账写失败仍判烧录成功", t_ledger_locked)


def t_ledger_pending_flush():
    _, alloc = new_env()
    os.makedirs(os.path.dirname(alloc.ledger.path), exist_ok=True)
    open(alloc.ledger.path, "a").close()          # 先建出文件再改权限
    os.chmod(alloc.ledger.path, 0o444)
    try:
        # record_ok 内部吞掉写入异常，不抛、不返回 False（成功与否由 result 决定）
        alloc.record_ok(FakeDevice().read_id(), alloc.allocate(), "A001")
    finally:
        os.chmod(alloc.ledger.path, 0o666)
    assert alloc.ledger.stats()["pending"] == 1, "应暂存 1 条待补写"
    n = alloc.ledger.flush_pending()
    assert n == 1, f"应补写 1 条，实际 {n}"
    assert alloc.ledger.stats()["pending"] == 0

check("暂存记录退出时补写", t_ledger_pending_flush)


print("=== 失败只记一次账 ===")
def t_record_once():
    _, alloc = new_env()
    dev = FakeDevice()
    dev.fail_write = "locked"
    r = Burner(dev, alloc, auto_lock=True, log=LogCollector()).burn(operator="A001")
    assert not r.ok and r.step == Step.WRITE
    fails = [x for x in alloc.ledger._rows if x["result"] == "fail"]
    assert len(fails) == 1, f"一次失败只应记一条，实际 {len(fails)}"

check("失败不重复记账", t_record_once)


print("=== 烧录成功路径完整闭环 ===")
def t_happy():
    _, alloc = new_env()
    dev = FakeDevice()
    burn = Burner(dev, alloc, auto_lock=True, log=LogCollector())
    r = burn.burn(operator="A001")
    assert r.ok and dev.sn == r.sn and dev._locked == 1, f"闭环失败: {r}"
    r2 = burn.burn(operator="A001")
    assert not r2.ok and r2.reused, "同一台再烧应被查重挡住"

check("成功闭环 + 查重拦截", t_happy)


print("=== 返修路径 ===")
def t_rework():
    _, alloc = new_env()
    dev = FakeDevice()
    burn = Burner(dev, alloc, auto_lock=True, log=LogCollector())
    r1 = burn.burn(operator="A001")
    assert r1.ok
    r2 = burn.rework(operator="A001")
    assert r2.ok, r2
    assert r2.sn != r1.sn, "返修必须分配新号"
    assert dev._locked == 1, "返修后应重新上锁"
    rows = alloc.ledger._rows
    assert sum(1 for x in rows if x["rework"] == "1") == 1

check("返修：解锁-换号-重锁-记账", t_rework)


print("=== 配置新增项 ===")
def t_config():
    c = cfg_mod.Config()
    assert c.rework_password == "8888"
    assert c.require_operator is True
    d = c.to_dict()
    assert "rework_password" in d and "require_operator" in d

check("配置含返修密码与工号必填", t_config)


#=====================================================================
shutil.rmtree(TMP, ignore_errors=True)
print()
print(f"===== 结果: {len(PASS)} passed, {len(FAIL)} failed =====")
if FAIL:
    for f in FAIL:
        print("  FAIL:", f)
    raise SystemExit(1)
