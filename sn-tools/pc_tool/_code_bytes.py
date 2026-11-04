"""统计"代码字节"——即真正占 flash 的那部分（注释/空行不占）。

设备端实测锚点：
    源码 42751 B(其中代码 18406 B) -> flash 28 KB
    源码 16954 B(其中代码 16495 B) -> flash 26 KB

用法: python _code_bytes.py
"""

import os
import re
import subprocess
import sys

FILES = ["main.lua", "corelib.lua", "sn_core.lua", "sn_store_fskv.lua",
         "sn_luhn.lua", "sn_prov_uart.lua", "identity.lua"]
BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                    "soft_sn_demo")


def code_bytes(text: str) -> int:
    text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
    out = []
    for line in text.split("\n"):
        i = line.find("--")
        if i >= 0:
            line = line[:i]
        if line.strip():
            out.append(line)
    return len("\n".join(out).encode("utf-8"))


def snapshot(ref=None):
    """取指定 git ref 的各文件代码字节；ref=None 取工作区。"""
    res = {}
    for f in FILES:
        if ref is None:
            data = open(os.path.join(BASE, f), "rb").read()
        else:
            # 必须按字节取：早期版本有中文注释，git 走 GBK 解码会炸
            data = subprocess.run(
                ["git", "show", f"{ref}:soft_sn_demo/{f}"],
                capture_output=True, check=True).stdout
        res[f] = code_bytes(data.decode("utf-8"))
    return res


def main():
    cur = snapshot()
    old = snapshot("62e7d26")        # 最初带注释的版本
    prev = snapshot("6e4b3b0")       # 上一轮"只删注释"的版本

    print(f"{'文件':<20}{'代码B(最初)':>12}{'删注释后':>10}{'本次再优化':>12}")
    print("-" * 58)
    for f in FILES:
        print(f"{f:<20}{old[f]:>12}{prev[f]:>10}{cur[f]:>12}")
    print("-" * 58)
    to, tp, tc = sum(old.values()), sum(prev.values()), sum(cur.values())
    print(f"{'合计':<20}{to:>12}{tp:>10}{tc:>12}")

    print()
    print(f"本轮(6e4b3b0 -> 现在) 代码字节减少: {tp - tc} B")
    print(f"最初(62e7d26 -> 现在) 代码字节减少: {to - tc} B")
    print()
    print("按实测锚点，flash 增量 ≈ 代码字节增量，所以：")
    print(f"  设备端预计 26 KB -> {26 - (tp - tc) / 1024:.2f} KB")
    print(f"  相比最初 28 KB，共省约 {(to - tc) / 1024:.2f} KB")


if __name__ == "__main__":
    sys.exit(main())
