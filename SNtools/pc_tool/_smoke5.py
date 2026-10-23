"""验证：台账里的历史脏 UID 在查询/显示时被清洗。

直接用工装真实的 data/ledger.csv（里面就存着 0x13 和 U+FFFD）。

用法: python _smoke5.py
"""

import os
import shutil
import traceback

OUT = []


def say(m):
    OUT.append(m)


def is_printable_safe(s: str) -> bool:
    # 允许换行：tkinter 的 wraplength 会自动插 \n，那是排版不是脏数据
    return all(ch.isprintable() or ch in (" ", "\n", "\t") for ch in s)


try:
    from allocator import Allocator
    from device import clean_field
    import sn_rule

    REAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "ledger.csv")

    print("=== ① 真实台账的脏数据 ===")
    if os.path.exists(REAL):
        with open(REAL, "rb") as f:
            raw = f.read()
        say(f"  文件 {len(raw)} 字节")
        # 找出含不可打印字符或 U+FFFD 的行
        dirty = [ln for ln in raw.split(b"\r\n")
                 if any(b < 32 and b not in (9,) for b in ln) or b"\xef\xbf\xbd" in ln]
        say(f"  含脏字符的行数: {len(dirty)}")
        if dirty:
            say(f"  样例: {dirty[0][:90]!r}")
    else:
        say("  （真实台账不存在，跳到构造用例）")

    print("=== ② _load 清洗后查询 ===")
    alloc = Allocator(sn_rule.SnRule(),
                      os.path.join(os.path.dirname(REAL), "counter.json"),
                      REAL)
    rows = alloc.ledger._rows
    say(f"  读入 {len(rows)} 条")
    for r in rows:
        say(f"    uid={r.get('uid')!r}  sn={r.get('sn')!r}  imei={r.get('imei')!r}")
        assert is_printable_safe(r.get("uid") or ""), \
            f"UID 仍含不可打印字符: {r.get('uid')!r}"
        assert "\ufffd" not in (r.get("uid") or ""), "UID 仍含替换字符"
        assert is_printable_safe(r.get("sn") or ""), "SN 被洗坏了"
        assert is_printable_safe(r.get("imei") or ""), "IMEI 被洗坏了"
    say("  台账读入后全部可打印 ✓")

    print("=== ③ 按 IMEI 查（用户实际场景）===")
    if rows:
        imei = rows[0].get("imei")
        hits = alloc.ledger.query(imei)
        say(f"  查 {imei}: {len(hits)} 条")
        for h in hits:
            say(f"    SN={h.get('sn')} UID={h.get('uid')!r} "
                f"时间={h.get('time')} 工号={h.get('operator')}")
            assert is_printable_safe(h.get("uid") or "")
        assert hits, "应能查到"

    print("=== ④ 界面显示层再洗一次 ===")
    import tkinter as tk
    from ui_app import SnBurnerApp

    root = tk.Tk()
    app = SnBurnerApp(root)
    root.update_idletasks()

    if rows:
        app.query_var.set(rows[0].get("imei"))
        app._do_query()
        txt = app.query_result["text"]
        say("  查询结果:")
        for ln in txt.splitlines():
            say(f"    {ln}")
        assert is_printable_safe(txt), "界面上仍有不可打印字符"
        assert "\ufffd" not in txt, "界面上仍有替换字符"
        say("  界面无可打印字符/替换字符 ✓")
    root.destroy()

    print("=== ⑤ 清洗函数本身 ===")
    for raw in ["NE033\x13sLE\ufffd", "\ufffd\ufffd", "NE033sLE", ""]:
        got = clean_field(raw)
        say(f"  {raw!r} -> {got!r}")
        assert is_printable_safe(got) or got == ""

    say("DONE")

except Exception:
    say("=== 异常 ===")
    say(traceback.format_exc())

with open("_smoke5.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(OUT))
