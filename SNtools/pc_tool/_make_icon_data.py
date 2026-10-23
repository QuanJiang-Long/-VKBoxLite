"""把 Lcon.png 转成 base64，内嵌进 _icon_data.py。

为什么不用 --add-data + sys._MEIPASS：
    --onefile 启动时要把数据文件解压到 %TEMP%\\_MEIxxxxxx。实测本环境
    报 "Failed to extract Lcon.png: Permission denied" —— 而且连
    VCRUNTIME140.dll 都解不出来，说明是 Temp 不可写，不是参数写错。
    产线机器多数没问题，但"工装起不起得来取决于 Temp 能不能写"这件事
    本身不该赌：某些加固产线/组策略限制 Temp 时，整个 exe 会启动失败。
    内嵌进源码后零文件依赖，任何环境都能设置窗口图标。

体积：Lcon.png 10200 字节 -> base64 约 13600 字符，可接受。

用法: python _make_icon_data.py
"""

import base64
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "Lcon.png")
OUT = os.path.join(HERE, "_icon_data.py")


def main() -> int:
    if not os.path.exists(SRC):
        print("FAIL 找不到 Lcon.png:", SRC)
        return 1

    with open(SRC, "rb") as f:
        raw = f.read()
    b64 = base64.b64encode(raw).decode("ascii")

    # 每行 96 字符：既不让单行过长难读，也不至于行数太多
    lines = [b64[i:i + 96] for i in range(0, len(b64), 96)]
    body = "\n".join('    "%s"' % l for l in lines)

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write('"""Lcon.png 的 base64 内嵌副本，供窗口图标使用。\n')
        f.write("\n")
        f.write("由 _make_icon_data.py 从仓库根的 Lcon.png 生成，【不要手改】。\n")
        f.write("换了 Lcon.png 后重跑那个脚本即可。\n")
        f.write("\n")
        f.write("为什么不走 --add-data / sys._MEIPASS：--onefile 要把数据文件\n")
        f.write("解压到 %TEMP%\\\\_MEIxxxxxx，实测本环境连 VCRUNTIME140.dll\n")
        f.write("都解不出来（Permission denied）。产线多数没问题，但工装能否\n")
        f.write("启动不该取决于 Temp 可不可写。内嵌后零文件依赖。\n")
        f.write('"""\n')
        f.write("\n")
        f.write("# 原始字节数（用于自检，防截断）\n")
        f.write("ICON_BYTES = %d\n" % len(raw))
        f.write("\n")
        f.write("ICON_B64 = (\n")
        f.write(body)
        f.write("\n)\n")

    print("OK 生成 _icon_data.py  %d 字节 (源 %d -> base64 %d)"
          % (os.path.getsize(OUT), len(raw), len(b64)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
