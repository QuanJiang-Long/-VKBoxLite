"""把弹窗用的小图标转成 base64，内嵌进 _dialog_icon_data.py。

为什么不用 --add-data + sys._MEIPASS：
    跟 _make_icon_data.py 同一个理由 —— --onefile 启动时要把数据文件解压到
    %TEMP%\\_MEIxxxxxx，实测本环境连 VCRUNTIME140.dll 都解不出来
    （Permission denied）。工装能否起得来，不该赌 Temp 能不能写。

为什么这些图标以前是"看得见"的、现在看不见：
    弹窗图标（条形码 qrcode.png / 返修 bug.png / 返修密码 lock-password.png）
    以前靠硬编码绝对路径 D:/VKBox_Lite/VKBoxLite_sn/xxx.png 去取，
    仓库换目录后那个路径不存在了，iconphoto 就再也没被调用过。
    硬编码路径 + 打包不带数据文件 = 图标只剩 Tk 默认的那根羽毛。

内嵌之后：
    1. 不依赖任何绝对路径，仓库放哪都能跑；
    2. 打包后 exe 旁边没有 png 也能显示；
    3. 磁盘上的原图仍可作为兜底（开发时改了 png 直接生效）。

用法: python _make_dialog_icon_data.py
"""

import base64
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 弹窗图标名 -> 仓库根的 png 文件名
WANTED = ("qrcode.png", "bug.png", "lock-password.png")

OUT = os.path.join(HERE, "_dialog_icon_data.py")


def main() -> int:
    missing = [n for n in WANTED
               if not os.path.exists(os.path.join(ROOT, n))]
    if missing:
        print("FAIL 仓库根缺少这些图标:", ", ".join(missing))
        return 1

    parts = []
    total = 0
    for name in WANTED:
        src = os.path.join(ROOT, name)
        with open(src, "rb") as f:
            raw = f.read()
        total += len(raw)
        b64 = base64.b64encode(raw).decode("ascii")
        lines = [b64[i:i + 96] for i in range(0, len(b64), 96)]
        body = "\n".join('        "%s"' % l for l in lines)
        parts.append(
            '    "%s": (\n'
            '        %d,                       # 原始字节数（自检，防截断）\n'
            '        (\n%s\n        ),\n'
            '    ),' % (name, len(raw), body))

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write('"""弹窗小图标的 base64 内嵌副本（条形码 / 返修 / 返修密码）。\n')
        f.write("\n")
        f.write("由 _make_dialog_icon_data.py 从仓库根的 png 生成，【不要手改】。\n")
        f.write("换了 png 后重跑那个脚本即可。\n")
        f.write("\n")
        f.write("内嵌而不是 --add-data / sys._MEIPASS：--onefile 要把数据文件\n")
        f.write("解压到 %TEMP%\\\\_MEIxxxxxx，实测本环境连 VCRUNTIME140.dll\n")
        f.write("都解不出来（Permission denied）。工装能否启动不该取决于 Temp\n")
        f.write("能不能写。内嵌后零文件依赖，仓库挪到哪儿都能跑。\n")
        f.write('"""\n')
        f.write("\n")
        f.write("# 图标名 -> (原始字节数, base64 字符串)\n")
        f.write("ICONS = {\n")
        f.write("\n".join(parts))
        f.write("\n}\n")

    print("OK 生成 _dialog_icon_data.py  %d 字节 (源合计 %d 字节)"
          % (os.path.getsize(OUT), total))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
