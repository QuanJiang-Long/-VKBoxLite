"""跑 pc_tool 各模块自检，绕开 harness 的编码/管道干扰，拿真实 exit code。

背景：PowerShell 直接 `python x.py` 时，中文输出按 GBK 落进管道，
读取端按 utf-8 解会抛 UnicodeDecodeError，PowerShell 于是报告 exit=1
（早期还见过 WinError 0）——那都是 harness 的假象，不是产品问题。
所以这里用 subprocess 按字节取，只在最后统计。

用法: python _st_all.py
"""

import subprocess
import sys
import os

MODULES = ["sn_rule", "config", "allocator", "serial_port", "device", "burner",
          "_barcode", "_barcode_decode", "_qrcode"]
HERE = os.path.dirname(os.path.abspath(__file__))


def run(mod: str) -> tuple[bool, str]:
    p = os.path.join(HERE, mod + ".py")
    r = subprocess.run([sys.executable, p], capture_output=True)
    out = (r.stdout + r.stderr).decode("utf-8", "replace")
    lines = [l for l in out.split("\n") if l.strip()]
    # 只留 ASCII：本脚本自身的输出也要能落进 GBK 控制台，否则一样炸
    tail = (lines[-1] if lines else "")[:60]
    tail = tail.encode("ascii", "replace").decode("ascii")
    return r.returncode == 0, tail


def main() -> int:
    bad = []
    for m in MODULES:
        ok, tail = run(m)
        print(f"  {'PASS' if ok else 'FAIL'}  {m:<14} rc={r_rc(ok)}  {tail}")
        if not ok:
            bad.append(m)
    print(f"===== self-test: {len(MODULES) - len(bad)} passed, "
          f"{len(bad)} failed / {len(MODULES)} total =====")
    if bad:
        print("  failed:", ", ".join(bad))
    return 1 if bad else 0


def r_rc(ok: bool) -> int:
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
