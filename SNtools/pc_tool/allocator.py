"""
SN 分配器 + 四道防重防线。

这是整个工装【最重要】的模块。烧错一个号只是麻烦，烧重一个号是事故。

四道防线：
    ① IMEI 台账查重     同一台设备被重复分配新号
    ② 计数器先占位      两台设备拿到同一个号
    ③ 失败号作废不回收  崩溃后重发旧号
    ④ 启动对账          计数器文件丢失或被改小

设计原则：counter.json 损坏且 ledger.csv 也损坏时【停机报警，绝不猜】。

⚠️ 流水号按天归零（daily_reset=True，默认）：
    唯一性从"serial 全局唯一"变成"(日期, serial) 唯一"。日期嵌在 SN 里
    （prefix + YYYYMMDD + serial + 校验位），所以不同天的同一个 serial
    是两个不同的 SN，不会撞号。9999 的容量也从"一辈子总量"变成"每天上限"。
    防线④ 的兜底相应改为只查【当天】的台账记录，否则昨天烧到 500，
    今天会被顶到 501，归零等于没做。
"""

from __future__ import annotations

import csv
import json
import os
from dataclasses import dataclass, asdict
from datetime import datetime
from typing import Optional

from device import clean_field

from sn_rule import SnRule


class AllocatorError(Exception):
    """分配器自身出问题（文件损坏、对账失败等）。必须让人知道，不能静默。"""


#=====================================================================
# 台账
#=====================================================================
LEDGER_FIELDS = ["time", "imei", "uid", "sn", "serial", "result", "reason", "operator", "rework"]


class Ledger:
    """IMEI ↔ SN 台账。CSV 存储，人也能直接用 Excel 打开看。"""

    def __init__(self, path: str):
        self.path = path
        self._rows: list[dict] = []
        self._by_imei: dict[str, dict] = {}
        self._pending: list[dict] = []      # 写盘失败暂存的记录，退出时补写
        self.last_error: str = ""           # 最近一次写失败的真实原因
        self._load()

    def _load(self) -> None:
        if not os.path.exists(self.path):
            return
        try:
            with open(self.path, "r", encoding="utf-8", newline="") as f:
                for row in csv.DictReader(f):
                    if not row.get("imei"):
                        continue
                    # 历史数据清洗：早期版本把芯片 UID 的原始二进制（含 0x13
                    # 这类控制字符）和 U+FFFD 替换字符直接存进了 CSV。
                    # 在这里统一洗掉，查询/统计/查重拿到的就都是干净文本。
                    # sn/imei 正常不受影响（本来就是可打印 ASCII）。
                    for k in ("imei", "uid", "sn", "reason", "operator"):
                        if row.get(k):
                            row[k] = clean_field(row[k])
                    self._rows.append(row)
                    # 同一 IMEI 只留最后一条成功记录（返修会追加新的）
                    if row.get("result") == "ok":
                        self._by_imei[row["imei"]] = row
        except OSError as e:
            raise AllocatorError(f"台账文件读取失败: {self.path} ({e})")

    #-----------------------------------------------------------------
    def find_by_imei(self, imei: str) -> Optional[dict]:
        return self._by_imei.get(imei)

    def find_by_sn(self, sn: str) -> Optional[dict]:
        for row in reversed(self._rows):
            if row.get("sn") == sn and row.get("result") == "ok":
                return row
        return None

    def has_sn(self, sn: str) -> bool:
        """SN 是否在台账里被成功烧过（result=ok 的才算）。
        用于返修场景的"指定特定号"：这个号不能跟已有 SN 撞。
        """
        return self.find_by_sn(sn) is not None

    def max_serial(self) -> int:
        """台账里出现过的最大流水号。启动对账用。"""
        best = 0
        for row in self._rows:
            try:
                best = max(best, int(row.get("serial") or 0))
            except (TypeError, ValueError):
                continue
        return best

    #-----------------------------------------------------------------
    def max_serial_for_date(self, day: str, rule: SnRule) -> int:
        """台账里【指定日期】出现过的最大流水号。按天归零的对账基准。

        ⚠️ 必须统计所有行，含 result=="fail" 的：失败号作废不回收
            （防线③），漏统计就会把失败用过的号重新发出去。

        日期从 SN 里切（rule.date_of），不给 CSV 加 date 列 ——
        这样旧台账零迁移，且日期在 SN 里是构造保证的，不会两处不一致。
        """
        best = 0
        for row in self._rows:
            if rule.date_of(row.get("sn") or "") != day:
                continue
            try:
                best = max(best, int(row.get("serial") or 0))
            except (TypeError, ValueError):
                continue
        return best

    #-----------------------------------------------------------------
    def query(self, keyword: str) -> list[dict]:
        """按 IMEI 或芯片 UID 查这台设备烧过什么号。

        来料/售后场景：拿到一台设备，先查有没有烧过，再决定走正常烧录
        还是返修。所以：
          - IMEI 和 UID 都查，命中任意一个就算
          - 大小写不敏感（UID 有 hex 和原始两种历史形态）
          - 返回全部相关记录（含失败/返修），让查询人看到完整历史
        没查到返回空列表。成功的排前面，同状态按时间倒序。
        """
        kw = (keyword or "").strip().upper()
        if not kw:
            return []
        hits = []
        for seq, row in enumerate(self._rows):
            imei = (row.get("imei") or "").upper()
            uid = (row.get("uid") or "").upper()
            if kw in imei or kw in uid:
                hits.append((seq, row))
        hits.sort(key=lambda t: (t[1].get("result") != "ok", -t[0]))
        return [r for _, r in hits]

    #-----------------------------------------------------------------
    def append(self, *, imei: str, uid: str, sn: str, serial: int,
               result: str, reason: str = "", operator: str = "",
               rework: bool = False) -> None:
        """追加一条台账记录。

        ⚠️ 记账失败【不能】抛异常否决烧录结果——SN 已经写进设备了。
           常见失败原因：ledger.csv 正被 Excel 打开（Windows 会锁文件）。
           所以这里自己吞掉异常并返回 False，由调用方决定怎么提示。
        """
        row = {
            "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "imei": imei,
            "uid": uid,
            "sn": sn,
            "serial": str(serial),
            "result": result,
            "reason": reason,
            "operator": operator,
            "rework": "1" if rework else "0",
        }
        self._rows.append(row)
        if result == "ok":
            self._by_imei[imei] = row

        try:
            os.makedirs(os.path.dirname(os.path.abspath(self.path)),
                        exist_ok=True)
            new = not os.path.exists(self.path)
            with open(self.path, "a", encoding="utf-8", newline="") as f:
                w = csv.DictWriter(f, fieldnames=LEDGER_FIELDS)
                if new:
                    w.writeheader()
                w.writerow(row)
            return True
        except OSError as e:
            # 台账写不进去（文件被占用/只读/磁盘满）。SN 已烧成功，
            # 不能因为记不上账就告诉工人"失败了"。保留在内存里，
            # 关闭软件时会尝试补写。
            self._pending.append(row)
            # 记住真实原因，UI 要原样显示，不要让工人猜
            self.last_error = f"{type(e).__name__}: {e}"
            print(f"[ledger] 写入失败({e})，已暂存内存，退出时补写: {self.path}")
            return False

    #-----------------------------------------------------------------
    def stats(self) -> dict:
        ok = sum(1 for r in self._rows if r.get("result") == "ok")
        fail = sum(1 for r in self._rows if r.get("result") == "fail")
        rework = sum(1 for r in self._rows if r.get("rework") == "1")
        return {"total": len(self._rows), "ok": ok, "fail": fail,
                "rework": rework, "pending": len(self._pending)}

    #-----------------------------------------------------------------
    def flush_pending(self) -> int:
        """补写之前写盘失败的记录。返回成功补写的条数。"""
        if not self._pending:
            return 0
        left = []
        written = 0
        for row in self._pending:
            try:
                os.makedirs(os.path.dirname(os.path.abspath(self.path)),
                            exist_ok=True)
                new = not os.path.exists(self.path)
                with open(self.path, "a", encoding="utf-8", newline="") as f:
                    w = csv.DictWriter(f, fieldnames=LEDGER_FIELDS)
                    if new:
                        w.writeheader()
                    w.writerow(row)
                written += 1
            except OSError:
                left.append(row)
        self._pending = left
        return written

    #-----------------------------------------------------------------
    def describe_error(self) -> str:
        """把写失败的原因说成人话，附上解决办法。"""
        err = self.last_error or "未知原因"
        if "being used by another process" in err or "Errno 13" in err:
            return f"台账被占用：{err}\n请关闭正在查看 {os.path.basename(self.path)} 的 Excel/WPS。"
        if "Errno 28" in err or "No space" in err:
            return f"磁盘空间不足：{err}"
        return f"台账写入失败：{err}"


#=====================================================================
# 计数器
#=====================================================================
@dataclass
class Counter:
    next_serial: int = 1
    updated: str = ""
    # 这个 next_serial 归属哪一天（YYYYMMDD）。
    # 流水号按天归零后，光有 next_serial 不足以判断"要不要归零"，
    # 必须知道它算的是哪天的号。旧版本没有这个字段，读的时候给空串，
    # Allocator._roll_to 会发现与今天不同而走归零分支，天然完成迁移。
    date: str = ""


class CounterStore:
    """流水号计数器。原子写盘，断电不留半个文件。"""

    def __init__(self, path: str):
        self.path = path

    def load(self) -> Counter:
        if not os.path.exists(self.path):
            return Counter()
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                d = json.load(f)
            return Counter(
                next_serial=int(d.get("next_serial", 1)),
                updated=str(d.get("updated", "")),
                # 旧版本没有 date：给空串。_roll_to 看到与生效日期不同
                # 就会归零，并从当天台账接上去 —— 不需要迁移脚本。
                date=str(d.get("date", "")),
            )
        except (json.JSONDecodeError, OSError, ValueError) as e:
            raise AllocatorError(
                f"计数器文件损坏: {self.path} ({e})\n"
                f"  若台账 {os.path.basename(self.path)} 完好，可删除该文件自动重建；\n"
                f"  若两个都坏了，请从备份恢复，【不要】手动猜一个起始值。"
            )

    def save(self, c: Counter) -> None:
        c.updated = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(asdict(c), f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())      # 真落盘，防断电丢号
        os.replace(tmp, self.path)


#=====================================================================
# 分配器
#=====================================================================
@dataclass
class Allocation:
    """一次分配的结果。"""

    sn: str
    serial: int
    body: str
    date: str = ""                 # 实际使用的日期（YYYYMMDD）
    reused: bool = False           # True = 复用该设备已有的号（不是新分配）


class Allocator:
    def __init__(self, rule: SnRule, counter_file: str, ledger_file: str,
                 daily_reset: bool = True):
        self.rule = rule
        self.ledger = Ledger(ledger_file)
        self.counter_store = CounterStore(counter_file)
        # 手动覆盖：None = 按实际日期自动走；设置了就用手动值
        self.manual_date: Optional[str] = None
        self.manual_serial_start: Optional[int] = None
        # 流水号按天归零开关，默认开。关掉退回旧的"全局单调递增"行为，
        # 留给产线一个不用重新打包的回退手段（改 config.json 一个字段）。
        self.daily_reset = daily_reset
        self._reconcile()

    #-----------------------------------------------------------------
    def _reconcile(self) -> None:
        """防线④ 启动对账。

        按天归零模式：把计数器切到"当前生效日期"这一天。
            - 日期不同 -> 归零，并从【那天】的台账记录接上去
            - 日期相同 -> 用台账兜底，防 counter.json 被改小或丢失
        旧模式（daily_reset=False）：next = max(全历史最大流水号 + 1, 计数器)。

        ⚠️ 归零后唯一性由 (日期, 流水号) 共同保证。日期嵌在 SN 里，
           所以不同天的同一个流水号是两个不同的 SN，不会撞号。
        """
        self.counter = self.counter_store.load()
        if self.daily_reset:
            self._roll_to(self.effective_date())
            return
        floor = self.ledger.max_serial() + 1
        if self.counter.next_serial < floor:
            self.counter.next_serial = floor
            self.counter_store.save(self.counter)

    def _roll_to(self, day: str) -> None:
        """把计数器切到 day 这一天。按天归零的核心。

        两条路都拿"当天的台账最大流水号 + 1"兜底，这一句同时干三件事：
            1. 新的一天 -> 归零重来（注意不是"从 1 开始"，是从台账接上）
            2. counter.json 丢失/被改小 -> 台账能把丢的号捞回来
            3. 时钟被回拨到已经烧过的某天 -> 不会重发那天的旧号
        """
        floor = self.ledger.max_serial_for_date(day, self.rule) + 1
        if self.counter.date == day:
            if self.counter.next_serial < floor:
                self.counter.next_serial = floor
                self.counter_store.save(self.counter)
            return
        self.counter.date = day
        self.counter.next_serial = max(1, floor)
        self.counter_store.save(self.counter)

    def _roll_if_new_day(self) -> None:
        """日期翻了就归零。allocate() 每次进来都调。

        ⚠️ 不能只在启动时判：工装可能跑一整班甚至 24 小时不重启，
            凌晨一过日期变了，内存里的 next_serial 不会自己归零。
            同一天只比一次字符串，开销可以忽略。
        """
        if not self.daily_reset:
            return
        day = self.effective_date()
        if self.counter.date != day:
            self._roll_to(day)

    #-----------------------------------------------------------------
    def peek(self) -> int:
        return self.counter.next_serial

    def preview(self) -> str:
        """预览下一台会烧什么号（含手动日期/流水号覆盖）。"""
        # 显式传 effective_date()，不把 manual_date 透传给 sn_rule：
        # 那样 sn_rule 内部会自己取一次 now()，与分配器的时钟不一致，
        # 跨天或测试注入假时钟时，预览会和实际烧的号对不上。
        return self.rule.make(self.counter.next_serial, self.effective_date())

    #-----------------------------------------------------------------
    def set_manual_date(self, date: Optional[str]) -> None:
        """手动指定日期（YYYYMMDD）；传 None 恢复按实际日期。

        ⚠️ 日期与 UI 输入框绑定，这里仍按 8 位 YYYYMMDD 校验。
            若哪天 date_fmt 改成别的位数，要连 UI 一起改。
        """
        if date in (None, "", "auto"):
            self.manual_date = None
            # 恢复自动 = 回到今天，计数器也要切回今天，
            # 否则会停留在补录那天的号上
            if self.daily_reset:
                self._roll_to(self.effective_date())
            return
        if len(date) != 8 or not date.isdigit():
            raise AllocatorError(f"日期应为 8 位数字 YYYYMMDD，得到 {date!r}")
        from datetime import datetime as _dt
        try:
            _dt.strptime(date, "%Y%m%d")
        except ValueError:
            raise AllocatorError(f"{date} 不是有效日期")
        self.manual_date = date
        # 补录历史日期时，流水号要接【那天】的，不是今天的
        if self.daily_reset:
            self._roll_to(self.effective_date())

    def set_manual_serial_start(self, serial: Optional[int]) -> None:
        """手动指定起始流水号；传 None 恢复自动。

        ⚠️ 只允许往【大】改。往小改会重发已经用过的号，
           台账对不上，属于产线事故，直接拒绝。

        ⚠️ 必须同步 counter.date：否则下次 allocate() 的 _roll_if_new_day()
            发现日期不匹配，会把手动设的值当"跨天"直接归零抹掉。
        """
        if serial is None:
            self.manual_serial_start = None
            return
        if serial < self.counter.next_serial:
            raise AllocatorError(
                f"起始流水号不能小于当前值 {self.counter.next_serial}"
                f"（往小改会重发已用过的号）"
            )
        self.manual_serial_start = serial
        self.counter.next_serial = serial
        self.counter.date = self.effective_date()
        self.counter_store.save(self.counter)

    def effective_date(self) -> str:
        if self.manual_date:
            return self.manual_date
        return datetime.now().strftime(self.rule.date_fmt)

    #-----------------------------------------------------------------
    def allocate(self) -> Allocation:
        """分配一个新号。先占位（防线②）再返回，调用方接着写设备。

        占位在这里完成：计数器立即落盘。即使随后设备写入失败，
        这个号也不会再被分配出去（防线③：失败号作废不回收）。

        ⚠️ 先 _roll_if_new_day()：跨天运行时流水号要归零，
            且"今天第 1 台"必须真的是 0001。
        """
        self._roll_if_new_day()
        serial = self.counter.next_serial
        if serial >= 10 ** self.rule.serial_digits:
            raise AllocatorError(
                f"流水号已到上限 {10 ** self.rule.serial_digits - 1}，"
                f"请【扩大流水号位数】后继续。不要静默变成更多位——"
                f"会与旧格式混淆，且台账对不上。"
            )
        date = self.effective_date()
        sn = self.rule.make(serial, date)
        self.counter.next_serial = serial + 1
        self.counter_store.save(self.counter)      # 先占位
        return Allocation(sn=sn, serial=serial, body=sn[:-1], date=date)

    #-----------------------------------------------------------------
    def allocate_specific(self, serial: int,
                          date: Optional[str] = None) -> Allocation:
        """返修专用：指定一个特定流水号发号，不动 counter.next_serial。

        为什么独立方法（不走 allocate）：

          - allocate() 从 counter.next_serial 取号 + counter.next_serial++
            —— counter 是主流程下次发号的起点，必须严格递增（防线②）。
          - 返修场景是"这台设备改号"，跟主流程计数器序列没关系。
            counter 应该独立推进，返修烧 005 不应该让主流程下次从 005 开始。

        为什么用 ledger.has_sn() 而不是 counter 检查：

          - counter 检查只能拦住"小于 counter.next_serial" —— 太宽。返修
            场景里 counter 已经烧到 010，工人想给返修设备烧 005，counter
            检查会把 005 挡掉，但 005 可能在台账里根本没烧过。
          - SN 唯一性是真正的约束。allocate_specific 走 ledger.has_sn()，
            真正跟台账撞了才拒，没撞就放行。这样返修可以烧任意没在台账
            里的号（含小于 counter.next_serial 的）。

        ⚠️ 不占位（counter 不动），不写 counter.json。
        """
        d = date if date else self.effective_date()
        try:
            sn = self.rule.make(serial, d)
        except ValueError as e:
            raise AllocatorError(f"生成 SN 失败: {e}")
        existing = self.ledger.find_by_sn(sn)
        if existing is not None:
            raise AllocatorError(
                f"SN {sn} 已在台账里（{existing.get('operator', '?')} "
                f"于 {existing.get('ts', '?')} 烧给 IMEI "
                f"{existing.get('imei', '?')}），无法重复烧。"
                f"请换号或走【补烧】流程。"
            )
        return Allocation(sn=sn, serial=serial, body=sn[:-1], date=d)

    #-----------------------------------------------------------------
    def check_duplicate(self, imei: str) -> Optional[dict]:
        """防线①：这台设备是不是已经烧过？

        返回台账里已存在的记录，或 None。调用方据此决定跳过还是返修。
        """
        return self.ledger.find_by_imei(imei)

    #-----------------------------------------------------------------
    def record_ok(self, info, alloc: Allocation, operator: str,
                  rework: bool = False, reason: str = "") -> bool:
        """记账成功。返回 True = 落盘成功，False = 写不进去（已暂存）。

        ⚠️ 必须把 append 的返回值传出去。之前漏了 return，调用方拿到的
           永远是 None，`if not ok_ledger` 恒真，于是每次烧录都误报
           "台账写入失败"——哪怕文件写得挺好。

        reason 用于补烧场景标记 "recover"，保留补烧痕迹。
        """
        return self.ledger.append(
            imei=info.imei, uid=info.uid, sn=alloc.sn, serial=alloc.serial,
            result="ok", operator=operator, rework=rework, reason=reason,
        )

    def record_fail(self, info, alloc: Optional[Allocation],
                    reason: str, operator: str) -> bool:
        return self.ledger.append(
            imei=info.imei, uid=info.uid,
            sn=alloc.sn if alloc else "", serial=alloc.serial if alloc else 0,
            result="fail", reason=reason, operator=operator,
        )


if __name__ == "__main__":
    # 自检：全流程 + 四道防线，用本地临时目录（沙箱可能禁系统 Temp）
    import shutil

    td = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_selftest_tmp")
    shutil.rmtree(td, ignore_errors=True)
    os.makedirs(td, exist_ok=True)

    try:
        rule = SnRule(prefix="1180", serial_digits=4)
        cf = os.path.join(td, "counter.json")
        lf = os.path.join(td, "ledger.csv")

        class FakeInfo:
            def __init__(self, imei, uid="UID1"):
                self.imei, self.uid = imei, uid

        # --- 基本分配：连续两台拿到不同号 ---
        a = Allocator(rule, cf, lf)
        x1 = a.allocate()
        x2 = a.allocate()
        assert x1.serial == 1 and x2.serial == 2, (x1, x2)
        assert x1.sn != x2.sn
        # 不再做 Luhn 校验（SN 改成 prefix+日期+流水号，无校验位），
        # 这里只校验两个号结构上是预期 body_len 的字符串。
        assert len(x1.sn) == rule.body_len and len(x2.sn) == rule.body_len
        print(f"  OK  连续分配: {x1.sn} / {x2.sn}")

        # --- 防线① 台账查重 ---
        a.record_ok(FakeInfo("IMEI-A"), x1, "OP1")
        dup = a.check_duplicate("IMEI-A")
        assert dup is not None and dup["sn"] == x1.sn
        assert a.check_duplicate("IMEI-NEW") is None
        print(f"  OK  台账查重: IMEI-A -> {dup['sn']}, IMEI-NEW -> None")

        # --- 防线③ 失败号作废不回收 ---
        before = a.peek()
        xf = a.allocate()
        a.record_fail(FakeInfo("IMEI-B"), xf, "verify fail", "OP1")
        assert a.peek() == before + 1, "失败后计数器必须前进，不能回退"
        xn = a.allocate()
        assert xn.serial == xf.serial + 1, "失败号不能被重新分配"
        print(f"  OK  失败号作废: {xf.sn} 作废，下一个是 {xn.sn}")

        # --- 防线④ 启动对账 ---
        today = datetime.now().strftime("%Y%m%d")
        b = Allocator(rule, cf, lf)     # 重新加载
        assert b.peek() > xn.serial, (b.peek(), xn.serial)
        print(f"  OK  启动对账: 重启后 next={b.peek()} "
              f"(当天台账最大 {b.ledger.max_serial_for_date(today, rule)})")

        # 计数器被改小 -> 对账拉回来
        b.counter.next_serial = 1
        b.counter_store.save(b.counter)
        c = Allocator(rule, cf, lf)
        want = b.ledger.max_serial_for_date(today, rule) + 1
        assert c.peek() == want, (c.peek(), want)
        print(f"  OK  计数器被改小 -> 对账修正为 {c.peek()}")

        # 计数器损坏 -> 明确报错，不猜
        # 注意：必须先建好分配器再破坏文件，否则构造时的 _reconcile 就会抛
        d = Allocator(rule, cf, lf)
        with open(cf, "w", encoding="utf-8") as f:
            f.write("{ broken")
        try:
            Allocator(rule, cf, lf)
            raise AssertionError("计数器损坏时应抛 AllocatorError")
        except AllocatorError as e:
            assert "计数器文件损坏" in str(e)
        print("  OK  计数器损坏 -> 停机报警，不猜起始值")

        # --- 流水号到顶 -> 明确报错，不静默变长 ---
        # d 的计数已在内存里，直接改内存值即可（不再触发 load）
        d.counter.next_serial = 10 ** rule.serial_digits
        try:
            d.allocate()
            raise AssertionError("流水号到顶时应抛 AllocatorError")
        except AllocatorError as e:
            assert "上限" in str(e)
        print("  OK  流水号到顶 -> 要求扩位，不静默变长")

        # ==============================================================
        # 按天归零
        # ==============================================================
        # 用假时钟推进日期：把模块级的 datetime 换掉，effective_date()
        # 和 Ledger.append 记的 time 会一起变，账才对得上。
        # ⚠️ 必须用 sys.modules[__name__] 拿当前模块。直接
        #    `import allocator` 会新建一份模块对象，改它的 datetime
        #    对正在跑的这份毫无作用（实测：归零断言全部失败）。
        import sys
        _self_mod = sys.modules[__name__]
        _RealDT = _self_mod.datetime

        class FakeDT:
            now = staticmethod(_RealDT.now)

        def _set_day(days_later: int) -> None:
            """把"现在"改成当月 1 号 + days_later 天（保持时分秒，避免
            同一天内因为时刻不同被误判成跨天）。"""
            base = _RealDT.now()
            d = _RealDT.fromordinal(base.replace(day=1).toordinal() + days_later)
            FakeDT.now = staticmethod(
                lambda dd=d: dd.replace(hour=base.hour, minute=base.minute,
                                        second=base.second))

        _self_mod.datetime = FakeDT
        try:
            # --- 跨天归零（重启场景）---
            td2 = os.path.join(td, "day2")
            os.makedirs(td2, exist_ok=True)
            cf2, lf2 = os.path.join(td2, "counter.json"), os.path.join(td2, "ledger.csv")
            _set_day(0)
            e = Allocator(rule, cf2, lf2)
            d1a, d1b = e.allocate(), e.allocate()
            assert d1a.serial == 1 and d1b.serial == 2, (d1a, d1b)
            e.record_ok(FakeInfo("IMEI-D1"), d1a, "OP1")

            _set_day(1)                      # 过了一天，重新开软件
            f = Allocator(rule, cf2, lf2)
            d2a = f.allocate()
            assert d2a.serial == 1, f"跨天应从 1 开始，实际 {d2a.serial}"
            assert d2a.sn != d1a.sn, "不同天的同序号必须是不同的 SN"
            assert d2a.date != d1a.date, "日期段必须跟着变"
            assert len(d2a.sn) == rule.body_len
            f.record_ok(FakeInfo("IMEI-D2"), d2a, "OP1")
            print(f"  OK  跨天归零: {d1a.sn} -> {d2a.sn}（流水号回到 1，SN 不同）")

            # --- 跨天运行（不重启，内存里滚）---
            g = Allocator(rule, cf2, lf2)
            _set_day(1)
            r1 = g.allocate()                # 第 2 天第 2 台
            _set_day(2)                      # 又过一天，软件没重启
            r2 = g.allocate()
            assert r2.serial == 1, f"不重启跨天也应归零，实际 {r2.serial}"
            assert r1.serial == 2 and r2.serial == 1
            g.record_ok(FakeInfo("IMEI-R2"), r2, "OP1")
            print(f"  OK  跨天运行: {r1.sn} -> {r2.sn}（不重启也归零）")

            # --- 补录历史日期：接【那天】的号 ---
            past = _RealDT.fromordinal(
                _RealDT.now().replace(day=1).toordinal() - 30)
            past_s = past.strftime("%Y%m%d")
            g.set_manual_date(past_s)
            hp = g.allocate()
            assert hp.date == past_s and hp.serial == 1, (hp.date, hp.serial)
            # 记账：时钟回拨的防线来自【台账】，没记账就无从保护
            g.record_ok(FakeInfo("IMEI-PAST"), hp, "OP1")
            g.set_manual_date(None)          # 恢复自动
            back = g.allocate()
            assert back.date != past_s, "恢复自动后应回到当天"
            print(f"  OK  补录历史日期: {hp.sn}（{past_s} 从 1 开始）")

            # --- 时钟回拨：不能重发已经烧过的号 ---
            g.counter.date = past_s
            g.counter.next_serial = 1
            g.counter_store.save(g.counter)
            h = Allocator(rule, cf2, lf2)
            h.set_manual_date(past_s)
            rb = h.allocate()
            assert rb.serial > hp.serial, \
                f"时钟回拨到已烧过的日期必须接上去，实际 {rb.serial} <= {hp.serial}"
            print(f"  OK  时钟回拨: {past_s} 已烧到 {hp.serial}，"
                  f"回拨后从 {rb.serial} 继续，不重发")

            # --- 手动起始流水号要能按住，不被归零抹掉 ---
            _set_day(0)
            k = Allocator(rule, cf2, lf2)
            k.set_manual_date(_RealDT.now().strftime("%Y%m%d"))
            k.set_manual_serial_start(50)
            assert k.peek() == 50
            m = k.allocate()
            assert m.serial == 50, f"手动设的 50 被抹掉了，实际 {m.serial}"
            print(f"  OK  手动起始流水号: 设 50 -> {m.sn}")

            # --- 旧 counter.json（无 date 字段）平滑迁移 ---
            td3 = os.path.join(td, "legacy")
            os.makedirs(td3, exist_ok=True)
            cf3, lf3 = os.path.join(td3, "counter.json"), os.path.join(td3, "ledger.csv")
            with open(cf3, "w", encoding="utf-8") as fh:
                fh.write('{"next_serial": 500, "updated": "2026-01-01 00:00:00"}')
            n = Allocator(rule, cf3, lf3)
            assert n.peek() == 1, f"旧文件迁移后当天应从 1 开始，实际 {n.peek()}"
            # counter.date 记的是【假时钟】的日期，不是真实今天
            assert n.counter.date == FakeDT.now().strftime("%Y%m%d")
            print(f"  OK  旧 counter.json 迁移: next=500(无 date) -> {n.peek()}")

            # --- daily_reset=False 退回旧的全局单调行为 ---
            td4 = os.path.join(td, "old")
            os.makedirs(td4, exist_ok=True)
            cf4, lf4 = os.path.join(td4, "counter.json"), os.path.join(td4, "ledger.csv")
            _set_day(0)
            o1 = Allocator(rule, cf4, lf4, daily_reset=False)
            s1, s2 = o1.allocate(), o1.allocate()
            o1.record_ok(FakeInfo("IMEI-O1"), s1, "OP1")
            _set_day(1)
            o2 = Allocator(rule, cf4, lf4, daily_reset=False)
            s3 = o2.allocate()
            assert s3.serial == s2.serial + 1, \
                f"关闭归零应继续递增，实际 {s3.serial}，上一个是 {s2.serial}"
            print(f"  OK  daily_reset=False: {s1.sn} / {s2.sn} / {s3.sn}（不归零）")

            # --- 失败号在按天模式下同样不回收 ---
            _set_day(0)
            p = Allocator(rule, cf4, lf4, daily_reset=False)
            before = p.peek()
            pf = p.allocate()
            p.record_fail(FakeInfo("IMEI-F"), pf, "verify fail", "OP1")
            assert p.peek() == before + 1
            print("  OK  失败号不回收（按天模式回归）")
        finally:
            _self_mod.datetime = _RealDT

        # --- 返修专用 allocate_specific：counter 不动 + 查 ledger 去重 ---
        cf5 = os.path.join(td, "counter_spec.json")
        lf5 = os.path.join(td, "ledger_spec.csv")
        sp = Allocator(rule, cf5, lf5, daily_reset=True)
        a1 = sp.allocate()                  # counter -> 2
        sp.record_ok(FakeInfo("IMEI-X1"), a1, "OP1")
        # 工人想返修烧 005 —— 但台账里没有 005 这个 SN，应该通过
        sp_before = sp.peek()
        sp1 = sp.allocate_specific(5)
        assert sp1.serial == 5, sp1.serial
        assert sp.peek() == sp_before, "allocate_specific 不动 counter"
        sp.record_ok(FakeInfo("IMEI-X5"), sp1, "OP1", rework=True)
        # 再 allocate_specific(5) —— 应该被 ledger 拒
        try:
            sp.allocate_specific(5)
            raise AssertionError("重复 SN 没拒")
        except AllocatorError as e:
            assert "已在台账里" in str(e), str(e)
            print("  OK  allocate_specific 拒绝重复 SN")
        # counter 应该还是 sp_before —— 返修没动 counter
        assert sp.peek() == sp_before, "重复失败也不动 counter"
        print("  OK  allocate_specific 返修不污染 counter")

        print("\n分配器自检: 全部通过")
    finally:
        shutil.rmtree(td, ignore_errors=True)
