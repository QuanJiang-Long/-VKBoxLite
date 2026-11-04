"""
烧录流程编排。

一条流水线：连接 -> 探测 -> 台账查重 -> 分配 -> 写入 -> 回读校验 -> 记台账
每一步的成败都变成 BurnResult，UI 只负责展示，不含业务判断。

设计要点：
    - 分配在写设备【之前】落盘（防线②），写入失败也不回收号（防线③）
    - 回读校验用设备自己的 R:SN，不信任 PC 本地状态
    - 每步失败立即停，原因直译成工人能懂的话
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Optional

from allocator import Allocator, Allocation
from device import Device, DeviceError, DeviceInfo, reason_cn


class Step(str, Enum):
    CONNECT = "连接"
    PROBE = "探测"
    DEDUP = "查重"
    ALLOC = "分配"
    WRITE = "写入"
    VERIFY = "校验"
    LOCK = "上锁"
    UNLOCK = "开锁"
    CLEAR = "抹号"     # C:SN：把设备侧 fskv 的 SN 键删掉
    LEDGER = "记账"


@dataclass
class BurnResult:
    ok: bool
    step: Optional[Step] = None
    sn: str = ""
    serial: int = 0
    imei: str = ""
    reason: str = ""                 # 原始原因（设备返回的英文）
    reason_cn: str = ""              # 人话
    reused: bool = False             # True = 这台设备已有号，跳过分配
    detail: dict = field(default_factory=dict)

    @property
    def reason_display(self) -> str:
        return self.reason_cn or self.reason


LogFn = Callable[[str, str], None]      # (level, message)


def _noop(level: str, msg: str) -> None:
    pass


class _FakeInfo:
    """只有 imei/uid 的最小信息对象，供记账用。"""

    def __init__(self, imei: str, uid: str = ""):
        self.imei, self.uid = imei, uid


class Burner:
    def __init__(self, device: Device, allocator: Allocator,
                 auto_lock: bool = True, log: LogFn = _noop):
        self.device = device
        self.alloc = allocator
        self.auto_lock = auto_lock
        self.log = log
        self._operator = ""
        # 已经记过账的分配，避免同一次失败被记两遍
        self._recorded: set[int] = set()

    #-----------------------------------------------------------------
    def _record_fail_once(self, imei: str, alloc: Optional[Allocation],
                          reason: str) -> None:
        """失败记账，保证同一次分配只记一条。台账写不进去也不抛。"""
        key = id(alloc) if alloc is not None else -1
        if key in self._recorded:
            return
        self._recorded.add(key)
        try:
            self.alloc.record_fail(_FakeInfo(imei), alloc, reason, self._operator)
        except Exception:                           # noqa: BLE001
            pass

    #-----------------------------------------------------------------
    def _fail(self, step: Step, reason: str, imei: str = "",
              alloc: Optional[Allocation] = None) -> BurnResult:
        """记录失败并返回结果。台账写不进去只提示，不改变失败结论。"""
        if alloc is not None:
            self._record_fail_once(imei, alloc, reason)
        self.log("FAIL", f"[{step.value}] {reason_cn(reason)}")
        return BurnResult(
            ok=False, step=step, reason=reason, reason_cn=reason_cn(reason),
            imei=imei, sn=alloc.sn if alloc else "",
            serial=alloc.serial if alloc else 0,
        )

    #-----------------------------------------------------------------
    def probe(self) -> DeviceInfo:
        """读一次 R:ID。"""
        info = self.device.read_id()
        self.log("INFO", f"探测: IMEI={info.imei} SN={info.sn or '(空)'} "
                         f"状态={info.state_cn} 锁={'是' if info.is_locked else '否'}")
        return info

    #-----------------------------------------------------------------
    def burn(self, operator: str = "", force_rework: bool = False,
             confirm: Optional[Callable[[str], bool]] = None) -> BurnResult:
        """烧录一台设备。confirm 用于写入前二次确认。"""
        self._operator = operator
        self._recorded.clear()

        # 1. 探测
        try:
            info = self.probe()
        except DeviceError as e:
            return self._fail(Step.PROBE, e.reason)
        except IOError as e:
            return self._fail(Step.PROBE, f"串口错误: {e}")

        if not info.imei:
            return self._fail(Step.PROBE, "读不到 IMEI，设备可能没注册上 4G 网", info.imei)

        # 2. 台账查重（防线①）
        dup = self.alloc.check_duplicate(info.imei)
        if dup and not force_rework:
            self.log("WARN", f"该设备已有编号 {dup['sn']}，跳过（如需重烧请走返修）")
            return BurnResult(
                ok=False, step=Step.DEDUP, reason="duplicate",
                reason_cn=f"该设备已有编号 {dup['sn']}，不重复分配",
                imei=info.imei, sn=dup["sn"], reused=True,
            )
        rework = bool(dup) and force_rework

        # 3. 分配（防线②：先占位落盘）
        try:
            alloc = self.alloc.allocate()
        except Exception as e:                      # AllocatorError 等
            return self._fail(Step.ALLOC, str(e), info.imei)
        self.log("INFO", f"分配: {alloc.sn} (流水号 {alloc.serial})")

        # 4. 写入前二次确认
        if confirm is not None and not confirm(alloc.sn):
            self.log("WARN", "操作员取消，该号作废不回收")
            self._record_fail_once(info.imei, alloc, "cancelled")
            return BurnResult(
                ok=False, step=Step.WRITE, reason="cancelled",
                reason_cn="操作员取消", imei=info.imei,
                sn=alloc.sn, serial=alloc.serial,
            )

        # 5. 写入（_fail 内部会统一记账，这里不重复记）
        try:
            self.device.write_sn(alloc.sn, force=rework or info.has_sn)
        except DeviceError as e:
            return self._fail(Step.WRITE, e.reason, info.imei, alloc)
        except IOError as e:
            return self._fail(Step.WRITE, f"串口错误: {e}", info.imei, alloc)

        # 6. 回读校验（不信 PC 本地状态，问设备要）
        try:
            back = self.device.read_sn()
        except DeviceError as e:
            return self._fail(Step.VERIFY, e.reason, info.imei, alloc)
        if back != alloc.sn:
            return self._fail(Step.VERIFY, "verify fail", info.imei, alloc)
        self.log("OK", f"回读校验通过: {back}")

        # 7. 自动上锁（Q3 确认开启）
        if self.auto_lock:
            try:
                self.device.lock()
                self.log("OK", "已自动上锁")
            except DeviceError as e:
                # 上锁失败不影响烧录结果：SN 已经写对并校验过了。
                # 但要明确告知，让操作员决定是否补锁。
                self.log("WARN", f"自动上锁失败: {reason_cn(e.reason)}（SN 已烧成功）")

        # 8. 记账
        #    记账失败不影响烧录结果：SN 已经写对并回读校验过了。
        #    台账会暂存内存，关闭软件时补写。绝不能因为记不上账
        #    就把一次成功的烧录报成失败。
        ok_ledger = self.alloc.record_ok(info, alloc, operator, rework=rework)
        if not ok_ledger:
            # 说清楚真实原因和怎么办，别让工人猜
            self.log("WARN", self.alloc.ledger.describe_error())
        self.log("OK", f"烧录完成: {alloc.sn}")

        return BurnResult(
            ok=True, sn=alloc.sn, serial=alloc.serial, imei=info.imei,
            reused=False,
        )

    #-----------------------------------------------------------------
    def recover(self, sn: str, operator: str = "") -> BurnResult:
        """补烧：把该设备原编号写回去。

        场景：设备重刷固件后 FSKV 被擦，SN 丢了，但台账里还记着这台
        设备原来烧的是哪个号。这时要把【旧号】补烧回去，而不是分配新号
        ——分配新号会让台账出现两个号，且浪费一个流水号。

        与 burn() 的区别：
          - 不调 allocate()，不消耗流水号
          - 多一步"台账里这个号必须确实是这个 IMEI 的"校验，防张冠李戴
          - 记账时标记 reason=recover，保留补烧痕迹

        前置条件（现场重新探测，不信缓存）：
          - 设备当前没有 SN（有且不同 -> 拒绝，让走返修）
          - 设备未上锁（上锁 -> 拒绝，让走返修解锁）
        """
        self._operator = operator
        self._recorded.clear()

        # 1. 现场探测：设备状态可能在上次连接后已经变了
        try:
            info = self.probe()
        except DeviceError as e:
            return self._fail(Step.PROBE, e.reason)
        except IOError as e:
            return self._fail(Step.PROBE, f"串口错误: {e}")

        if not info.imei:
            return self._fail(Step.PROBE, "读不到 IMEI，设备可能没注册上 4G 网", info.imei)

        # 2. 设备当前 SN 状态
        if info.has_sn:
            if info.sn == sn:
                # 幂等：已经是这个号了，不算失败
                self.log("OK", f"设备已是 {sn}，无需补烧")
                return BurnResult(ok=True, sn=sn, imei=info.imei)
            return self._fail(
                Step.PROBE,
                f"设备已有 SN {info.sn}，与要补烧的 {sn} 不同，请走返修流程",
                info.imei)
        if info.is_locked:
            # 设备上过锁又丢了 SN：锁还在但数据没了。这种必须走返修解锁，
            # 不能在这里强行写。
            return self._fail(Step.PROBE, "locked", info.imei)

        # 3. 台账核对：这个号必须确实是这个 IMEI 绑的
        #    防止查询框里填了个别的号、或者 IMEI 看串行
        row = self.alloc.ledger.find_by_imei(info.imei)
        if not row:
            return self._fail(Step.DEDUP,
                              f"台账里没有 {info.imei} 的记录，不能补烧", info.imei)
        bound_sn = (row.get("sn") or "").strip()
        if bound_sn != sn:
            return self._fail(Step.DEDUP,
                              f"台账中 {info.imei} 绑定的是 {bound_sn or '(空)'}，"
                              f"不是 {sn}", info.imei)
        self.log("INFO", f"台账核对通过: {info.imei} -> {sn}")

        # 4. 写入。设备当前是空的，不需要 FORCE
        try:
            self.device.write_sn(sn, force=False)
        except DeviceError as e:
            return self._fail(Step.WRITE, e.reason, info.imei)
        except IOError as e:
            return self._fail(Step.WRITE, f"串口错误: {e}", info.imei)

        # 5. 回读校验（不信 PC 本地状态，问设备要）
        try:
            back = self.device.read_sn()
        except DeviceError as e:
            return self._fail(Step.VERIFY, e.reason, info.imei)
        if back != sn:
            return self._fail(Step.VERIFY, "verify fail", info.imei)
        self.log("OK", f"回读校验通过: {back}")

        # 6. 自动上锁
        if self.auto_lock:
            try:
                self.device.lock()
                self.log("OK", "已自动上锁")
            except DeviceError as e:
                self.log("WARN", f"自动上锁失败: {reason_cn(e.reason)}（SN 已补烧成功）")

        # 7. 记账：补一条 recover 记录，保留"这台补烧过"的痕迹。
        #    不消耗流水号，serial 沿用原记录的。
        serial = 0
        try:
            serial = int(row.get("serial") or 0)
        except (TypeError, ValueError):
            pass
        alloc = Allocation(sn=sn, serial=serial, body=sn[:-1], date="")
        ok_ledger = self.alloc.record_ok(info, alloc, operator, reason="recover")
        if not ok_ledger:
            self.log("WARN", self.alloc.ledger.describe_error())
        self.log("OK", f"补烧完成: {sn}（未分配新号）")
        return BurnResult(ok=True, sn=sn, serial=serial, imei=info.imei)

    #-----------------------------------------------------------------
    def rework(self, operator: str = "",
               manual_serial: Optional[int] = None,
               manual_date: Optional[str] = None,
               confirm: Optional[Callable[[str], bool]] = None) -> BurnResult:
        """返修：解锁 -> 分配新号 -> FORCE 写入 -> 校验 -> （可选）重新上锁。

        manual_serial / manual_date —— 工人指定"这台设备的新 SN 用哪个
        流水号 / 哪个日期"。走 allocate_specific()，不动 counter：

          - manual_serial=None 且 manual_date=None  → 用 alloc.allocate()
            （从 counter 取，counter.next_serial++）
          - 传了 manual_serial          → 用 alloc.allocate_specific()
            （查 ledger.has_sn 唯一性，不动 counter）

        返修场景的特殊语义：counter 是主流程下次发号的起点，返修烧了
        005 不应该让主流程下次从 005 开始 —— 必须保持独立。
        """
        self._operator = operator
        self._recorded.clear()
        try:
            info = self.probe()
        except DeviceError as e:
            return self._fail(Step.PROBE, e.reason)
        except IOError as e:
            return self._fail(Step.PROBE, f"串口错误: {e}")

        # 解锁（设备未上锁时返回 not locked，不算失败）
        try:
            self.device.unlock()
            self.log("OK", "已解锁")
        except DeviceError as e:
            if e.reason != "not locked":
                return self._fail(Step.WRITE, e.reason, info.imei)
            self.log("INFO", "设备未上锁，无需解锁")

        # 分配：传了 manual_serial 就走 allocate_specific（不动 counter），
        # 否则走 allocate（从 counter 取）。
        try:
            if manual_serial is not None:
                alloc = self.alloc.allocate_specific(
                    manual_serial, manual_date)
                self.log("INFO",
                         f"返修分配（指定流水号）: {alloc.sn}")
            else:
                alloc = self.alloc.allocate()
                self.log("INFO", f"返修分配: {alloc.sn}")
        except Exception as e:
            return self._fail(Step.ALLOC, str(e), info.imei)

        if confirm is not None and not confirm(alloc.sn):
            self.log("WARN", "操作员取消，该号作废不回收")
            self._record_fail_once(info.imei, alloc, "cancelled")
            return BurnResult(ok=False, step=Step.WRITE, reason="cancelled",
                              reason_cn="操作员取消", imei=info.imei,
                              sn=alloc.sn, serial=alloc.serial)

        try:
            self.device.write_sn(alloc.sn, force=True)
        except DeviceError as e:
            return self._fail(Step.WRITE, e.reason, info.imei, alloc)

        try:
            back = self.device.read_sn()
        except DeviceError as e:
            return self._fail(Step.VERIFY, e.reason, info.imei, alloc)
        if back != alloc.sn:
            return self._fail(Step.VERIFY, "verify fail", info.imei, alloc)

        if self.auto_lock:
            try:
                self.device.lock()
                self.log("OK", "已重新上锁")
            except DeviceError as e:
                self.log("WARN", f"重新上锁失败: {reason_cn(e.reason)}")

        ok_ledger = self.alloc.record_ok(info, alloc, operator, rework=True)
        if not ok_ledger:
            self.log("WARN", self.alloc.ledger.describe_error())
        self.log("OK", f"返修完成: {alloc.sn}")
        return BurnResult(ok=True, sn=alloc.sn, serial=alloc.serial, imei=info.imei)

    #-----------------------------------------------------------------
    def lock_only(self, operator: str = "") -> BurnResult:
        """事后补锁：不分配号、不写 SN、不动台账。

        用途：烧录/补烧/返修那次 auto_lock=True 但上锁那一步失败了，
        或者工人故意没勾 auto_lock —— 设备现在是"有 SN 但未锁"，
        补这一刀让它跟上锁状态一致。已经有锁时设备会幂等回 RET:OK，
        也没事。

        不写台账：单纯补锁不改 SN，台账是给 SN 事件用的；只在日志
        留一条 [INFO]，事后能查到这次补锁动作（带工号）。
        """
        self._operator = operator
        self._recorded.clear()

        # 现场探测 —— 工人可能拔了旧设备插了新的，不信缓存
        try:
            info = self.probe()
        except DeviceError as e:
            return self._fail(Step.PROBE, e.reason)
        except IOError as e:
            return self._fail(Step.PROBE, f"串口错误: {e}")

        if not info.imei:
            return self._fail(Step.PROBE, "读不到 IMEI", info.imei)
        if info.state != "ready":
            # 与设备侧 cmd_lock 的前置条件保持一致：必须 ready（有 SN）
            return self._fail(Step.PROBE, "设备还没有 SN，不能上锁", info.imei)
        if info.is_locked:
            self.log("INFO", f"设备已是上锁状态，无需补锁（IMEI {info.imei}）")
            return BurnResult(ok=True, sn=info.sn, imei=info.imei)

        try:
            self.device.lock()
        except DeviceError as e:
            return self._fail(Step.LOCK, e.reason, info.imei)
        except IOError as e:
            return self._fail(Step.LOCK, f"串口错误: {e}", info.imei)

        op = f"操作员 {operator}" if operator else "未填工号"
        self.log("OK", f"手动上锁完成（{op}，IMEI {info.imei}）")
        return BurnResult(ok=True, sn=info.sn, imei=info.imei)

    #-----------------------------------------------------------------
    def unlock_only(self, operator: str = "") -> BurnResult:
        """事后补解锁：不分配号、不写 SN、不动台账。

        用途：返修场景要强制改写 SN（写新 SN 路径）之前先把锁解开。
        设备已经是未锁状态时设备会拒（必须先 locked 才让 clear_lock），
        PC 端先拦住，避免无意义的 round-trip。

        不写台账：单纯解锁定不改 SN，台账是给 SN 事件用的；只在日志
        留一条 [INFO]，事后能查到这次补解锁动作（带工号）。
        """
        self._operator = operator
        self._recorded.clear()

        # 现场探测 —— 工人可能拔了旧设备插了新的，不信缓存
        try:
            info = self.probe()
        except DeviceError as e:
            return self._fail(Step.PROBE, e.reason)
        except IOError as e:
            return self._fail(Step.PROBE, f"串口错误: {e}")

        if not info.imei:
            return self._fail(Step.PROBE, "读不到 IMEI", info.imei)
        if info.state != "ready":
            # 与设备侧 cmd_unlock 的前置条件保持一致：必须有 SN 才能谈锁
            return self._fail(Step.PROBE, "设备还没有 SN，无法开锁", info.imei)
        if not info.is_locked:
            self.log("INFO", f"设备已是未锁状态，无需补解锁（IMEI {info.imei}）")
            return BurnResult(ok=True, sn=info.sn, imei=info.imei)

        try:
            self.device.unlock()
        except DeviceError as e:
            return self._fail(Step.UNLOCK, e.reason, info.imei)
        except IOError as e:
            return self._fail(Step.UNLOCK, f"串口错误: {e}", info.imei)

        op = f"操作员 {operator}" if operator else "未填工号"
        self.log("OK", f"手动开锁完成（{op}，IMEI {info.imei}）")
        return BurnResult(ok=True, sn=info.sn, imei=info.imei)

    #-----------------------------------------------------------------
    def clear_sn_only(self, operator: str = "") -> BurnResult:
        """事后抹号：把设备侧 fskv 的 SN 键删掉（C:SN）。

        用途：返修场景里工人想让一台"已废但别处叫"的设备回到未烧状态
        （state="empty"），下一步可以重新烧新号（不走返修弹窗的写新 SN，
        走主流程【烧写 SN】即可）。

        与 unlock_only 是同一类（不分配号、不烧号、不动台账），区别在最终
        这一拍：
              unlock_only: device.unlock()    → DE pin high + clear lock flag
              clear_sn_only: device.clear_sn() → fskv.del(K_SN) + flush

        设备侧前置条件（sn.lua 的 M.clear()）：
            - 已锁 + state=ready      → 拒绝 "locked"（必须先开锁）
            - 已锁 + state=invalid    → 允许
            - 未锁 + 有 SN             → 允许
            - 已 empty                  → 幂等通过
        PC 端对应：
            - info.is_locked + state=ready  → _fail(PROBE, "locked")
            - state=empty                    → 提示"已是未烧状态，无需抹号" + ok=True
            - 否则                           → 发 C:SN

        ⚠️ 不动台账：device.clear_sn 只清设备侧 fskv 的 SN；PC 端台账保留
        原记录以便追溯"这台设备之前烧过什么号"。台账清理走独立流程。
        """
        self._operator = operator
        self._recorded.clear()

        # 现场探测 —— 工人可能拔了旧设备插了新的，不信缓存
        try:
            info = self.probe()
        except DeviceError as e:
            return self._fail(Step.PROBE, e.reason)
        except IOError as e:
            return self._fail(Step.PROBE, f"串口错误: {e}")

        if not info.imei:
            return self._fail(Step.PROBE, "读不到 IMEI", info.imei)

        # 设备侧前置：已锁 + state=ready 拒，否则可以抹
        if info.state == "ready" and info.is_locked:
            return self._fail(Step.PROBE, "locked", info.imei)

        # state=empty 时设备会幂等通过，但 PC 端先告诉工人"已是未烧状态"，省一次 round-trip
        if info.state == "empty":
            self.log("INFO",
                     f"设备已是未烧状态，无需抹号（IMEI {info.imei}）")
            return BurnResult(ok=True, sn="", imei=info.imei)

        try:
            self.device.clear_sn()
        except DeviceError as e:
            return self._fail(Step.CLEAR, e.reason, info.imei)
        except IOError as e:
            return self._fail(Step.CLEAR, f"串口错误: {e}", info.imei)

        op = f"操作员 {operator}" if operator else "未填工号"
        self.log("OK", f"手动抹号完成（{op}，IMEI {info.imei}）")
        return BurnResult(ok=True, sn="", imei=info.imei)
