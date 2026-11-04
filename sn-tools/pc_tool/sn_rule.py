"""
SN 规则引擎 —— 拼装 prefix + 日期 + 流水号。

格式：`{prefix}{YYYYMMDD}{NNN}`（无校验位）
例：VL + 20261010 + 001 -> VL20261010001

唯一性靠 (日期, 流水号) 共同保证 —— 日期每天不同，流水号在日期内唯一。
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
from datetime import datetime
from typing import Optional


@dataclass
class SnRule:
    """SN 组成规则。改规则只改这里 + config.json，不动其它代码。"""

    prefix: str = "VL"            # 产品代号：VKBox-Lite
    serial_digits: int = 3        # 流水号位数（001 ~ 999）
    date_fmt: str = "%Y%m%d"      # 日期格式，8 位

    @property
    def body_len(self) -> int:
        """完整 SN 长度（= prefix + 日期 + 流水号，无校验位）。"""
        return len(self.prefix) + self.date_len + self.serial_digits

    @property
    def date_len(self) -> int:
        """日期段占几个字符。由 date_fmt 决定，别在别处硬编码 8。"""
        return len(datetime.now().strftime(self.date_fmt))

    @property
    def date_offset(self) -> int:
        """日期段在 SN 里的起始下标（紧接 prefix 之后）。"""
        return len(self.prefix)

    def date_of(self, sn: str) -> str:
        """从 SN 里切出日期段；长度不够或不是纯数字返回空串。

        流水号按天归零后，唯一性是 (日期, 流水号) 共同保证的，
        所以反查"这个 SN 属于哪天"是按天对账的基础。
        位置由 date_offset / date_len 算出，改 prefix 或 date_fmt
        都不用动这里。
        """
        if not sn:
            return ""
        a = self.date_offset
        b = a + self.date_len
        if len(sn) < b:
            return ""
        seg = sn[a:b]
        return seg if seg.isdigit() else ""

    def make(self, serial: int, date: Optional[str] = None) -> str:
        """流水号 -> 完整 SN（prefix + 日期 + 流水号，无校验位）。

        date 传 "auto" 或 None = 用当天；传 "20260925" = 指定日期。
        """
        if date in (None, "", "auto"):
            date = datetime.now().strftime(self.date_fmt)
        # ⚠️ 位数按 date_fmt 算，不写死 8：date_fmt 若换成 %y%m%d，
        #    这里、date_offset/date_len、date_of 的切分必须同时成立。
        #    写死 8 会让 SN 生成和按天对账各说各话。
        if len(date) != self.date_len or not date.isdigit():
            raise ValueError(
                f"日期应为 {self.date_len} 位数字（{self.date_fmt}），得到 {date!r}")
        # 顺带校验是真实存在的日期，防止 20261332 这种
        datetime.strptime(date, self.date_fmt)
        if serial < 0 or serial >= 10 ** self.serial_digits:
            raise ValueError(
                f"流水号超出 {self.serial_digits} 位范围: {serial} "
                f"(上限 {10 ** self.serial_digits - 1})")
        return f"{self.prefix}{date}{serial:0{self.serial_digits}d}"

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "SnRule":
        known = {f for f in cls.__dataclass_fields__}  # noqa: C401
        return cls(**{k: v for k, v in d.items() if k in known})


if __name__ == "__main__":
    ok = True

    r = SnRule()
    print(f"规则: prefix={r.prefix} serial_digits={r.serial_digits} "
          f"date_fmt={r.date_fmt} body_len={r.body_len}")
    print(f"  今天第 1 台: {r.make(1)}")
    print(f"  今天第 42 台: {r.make(42)}")
    print(f"  补录 20260101 第 5 台: {r.make(5, '20260101')}")

    # date_of：按天归零靠它从 SN 反查日期，切错一位整个对账就错
    today = datetime.now().strftime("%Y%m%d")
    for label, rule, sn, want in [
        ("今天生成的号", r, r.make(1), today),
        ("手工补录的旧号", r, r.make(5, "20260101"), "20260101"),
        ("不同 prefix 偏移要对", SnRule(prefix="99", serial_digits=4),
         SnRule(prefix="99", serial_digits=4).make(7), today),
        ("空串", r, "", ""),
        ("太短（只有 prefix）", r, "VL", ""),
        ("日期段不是数字", r, "VLXXXXXXXX000", ""),
    ]:
        got = rule.date_of(sn)
        if got != want:
            ok = False
        print(f"  {'OK ' if got == want else 'FAIL'} date_of({label}) "
              f"= {got!r} (期望 {want!r})")

    # date_len / date_offset 与实际切分一致（防改了 fmt 忘了这里）
    if r.date_len != 8 or r.date_offset != len(r.prefix):
        ok = False
    print(f"  {'OK ' if (r.date_len == 8 and r.date_offset == len(r.prefix)) else 'FAIL'} "
          f"date_len={r.date_len} date_offset={r.date_offset} (期望 8 / {len(r.prefix)})")

    # 位数不对要报错（date_len 不写死 8 之后仍须拦住 2026092 这种）
    for bad in ("2026092", "202609255", "20a60925"):
        try:
            r.make(1, bad)
            ok = False
            print(f"  FAIL make(1, {bad!r}) 应当抛 ValueError")
        except ValueError:
            print(f"  OK  make(1, {bad!r}) -> 拒绝（位数/非数字）")

    print("\n自检结果:", "全部通过" if ok else "有失败项")
    raise SystemExit(0 if ok else 1)