"""统计脚本区各文件的注释/空行/死代码字节占比，输出优化空间报告。

用法: python _size_report.py
"""

import os
import re

FILES = ["main.lua", "corelib.lua", "sn_core.lua", "sn_store_fskv.lua",
         "sn_prov_uart.lua", "identity.lua", "sn_luhn.lua"]
NOT_DL = ["report.lua", "mqtt_demo.lua"]

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                    "soft_sn_demo")


def strip_block_comments(text: str) -> str:
    """去掉 --[[ ]] 与 -- 行注释，返回剩余字节数（粗略，仅供占比统计）。"""
    # 块注释
    text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
    # 行注释（保守：只算行首到 -- 的部分，不动字符串内的）
    out = []
    for line in text.split("\n"):
        idx = line.find("--")
        out.append(line[:idx] if idx >= 0 else line)
    return "\n".join(out)


def main():
    print(f"{'文件':<20}{'总B':>8}{'代码B':>8}{'注释B':>8}{'空行B':>8}"
          f"{'注释占比':>9}")
    print("-" * 66)
    tot = code = cmt = blank = 0
    for f in FILES:
        raw = open(os.path.join(BASE, f), encoding="utf-8").read()
        b_raw = len(raw.encode("utf-8"))
        b_code = len(strip_block_comments(raw).encode("utf-8"))
        b_blank = sum(len(l.encode("utf-8")) for l in raw.split("\n")
                      if not l.strip())
        b_cmt = b_raw - b_code - b_blank
        tot += b_raw
        code += b_code
        cmt += b_cmt
        blank += b_blank
        print(f"{f:<20}{b_raw:>8}{b_code:>8}{b_cmt:>8}{b_blank:>8}"
              f"{100 * b_cmt / b_raw:>8.1f}%")

    print("-" * 66)
    print(f"{'合计(下载的7个)':<18}{tot:>8}{code:>8}{cmt:>8}{blank:>8}"
          f"{100 * cmt / tot:>8.1f}%")
    print()
    nd = sum(len(open(os.path.join(BASE, f), encoding="utf-8").read()
                 .encode("utf-8")) for f in NOT_DL)
    print(f"未进包的文件({', '.join(NOT_DL)}): {nd} B，不占设备空间")
    print()
    print(f"若去掉全部注释: {tot} -> {code} B，省 {cmt} B ({100*cmt/tot:.1f}%)")
    print(f"若再去掉空行  : -> {code - blank} B，共省 "
          f"{tot - code + blank} B ({100*(tot-code+blank)/tot:.1f}%)")
    print()
    print("注：以上按源码字节算。设备端'已使用'若为编译后字节码，")
    print("    注释本就被编译器丢掉，此时只有删死代码/函数才真省空间。")


if __name__ == "__main__":
    main()
