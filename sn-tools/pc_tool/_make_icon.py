"""把 Lcon.png 转成 PyInstaller 用的多尺寸 .ico。

为什么需要这一步：
    PyInstaller 在 Windows 上的 --icon 只接受 .ico，直接喂 .png 会报
    "Invalid icon file"，或者干脆不报错但 exe 没图标。所以必须先转。

做法：
    一张 .ico 里嵌多个尺寸，Windows 会按用途（任务栏/资源管理器/
    标题栏/Alt+Tab）自己挑。尺寸表取 Windows 惯用的那几档。
    RGBA 保留，透明背景不会被填成黑块。

用法:
    python _make_icon.py            # 转换并报告
    python _make_icon.py --check    # 只检查，不写文件
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "Lcon.png")
OUT = os.path.join(HERE, "app.ico")

# Windows 惯用图标尺寸（含 Alt+Tab 用的 96、大图标 256）
SIZES = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)


def main():
    from PIL import Image                           # noqa: PLC0415

    if "--check" in sys.argv:
        print(f"  源图 {SRC}")
        print(f"    存在: {os.path.exists(SRC)}")
        print(f"  输出 {OUT}")
        print(f"    存在: {os.path.exists(OUT)}")
        if os.path.exists(OUT):
            print(f"    大小: {os.path.getsize(OUT)} 字节")
        return 0

    if not os.path.exists(SRC):
        print(f"FAIL 找不到源图: {SRC}")
        print("     请把图标放到仓库根目录并命名为 Lcon.png")
        return 1

    im = Image.open(SRC)
    print(f"  源图 {os.path.basename(SRC)}  模式={im.mode}  尺寸={im.size}")

    # 统一转成 RGBA：透明背景在任务栏上才干净，不会被填充成黑色
    im = im.convert("RGBA")

    # ⚠️ 必须先把底图放大到 256：Pillow 不会放大源图来生成 .ico 的
    #    256 那一档 —— 源图是 240x240 时，256 会被静默丢掉，
    #    而 256 正是资源管理器/高 DPI 任务栏用的主尺寸，
    #    缺了它 Windows 只能拿 128 去放大，图标发虚。
    #    240 -> 256 仅 +6.7%，肉眼看不出；LANCZOS 是最佳缩放算法。
    if min(im.size) < 256:
        im = im.resize((256, 256), Image.LANCZOS)
    if im.size != (256, 256):
        print(f"WARN 底图不是正方形 ({im.size})，图标可能被拉伸")

    # sizes 里每个尺寸都由 Pillow 从上面的 256 底图重新采样
    im.save(OUT, format="ICO", sizes=[(s, s) for s in SIZES])

    if not os.path.exists(OUT):
        print("FAIL 转换后文件不存在")
        return 1

    print(f"OK 已生成 {os.path.basename(OUT)}  {os.path.getsize(OUT)} 字节")
    print(f"   内嵌尺寸: {', '.join(str(s) for s in SIZES)}")

    # 回读校验：真能打开、且尺寸表齐全，才叫成功。
    # 注意 IcoFile.sizes 是【方法】，要调用；也可靠 im.info['sizes']
    # （是个 set）。两种都试，取到哪个用哪个。
    back = Image.open(OUT)
    try:
        sizes = sorted(set(back.ico.sizes()))
    except TypeError:
        sizes = []
    if not sizes:
        try:
            sizes = sorted(set(back.info.get("sizes", ())))
        except Exception:                     # noqa: BLE001
            sizes = []
    got = ", ".join(f"{w}x{h}" for w, h in sizes)
    print(f"   回读校验: 打开成功, sizes=[{got}]")
    if (256, 256) not in sizes:
        print("WARN 缺少 256x256 —— 这是资源管理器/高 DPI 任务栏用的主尺寸，")
        print("     图标会发虚。通常是源图小于 256 且没先放大导致的。")
    if len(sizes) < len(SIZES):
        print(f"WARN 期望 {len(SIZES)} 档，实际只有 {len(sizes)} 档")
    return 0


if __name__ == "__main__":
    sys.exit(main())
