"""打包 .exe 脚本。

直接执行本脚本：
    python _build.py
输出：
    dist/VKBoxLiteSn.exe    （单文件 ~18 MB，含 PIL/Tk）
    build/                  （PyInstaller 中间产物，生成后可以删）

参数选择理由（每条都踩过坑）：

  --onefile
    整个工具链要丢给产线工人双击运行。--onedir 散一堆 .dll .pyd
    体验很糟，工人不知道"该点哪个"。--onefile 单文件就一个图标可点。

  --noconsole
    GUI 程序双击不能弹黑色控制台窗（产线工人会被吓到以为中毒），
    也不挡在主窗前面。

  --icon=app.ico
    文件资源管理器里看到的就是这个图标。运行时窗口图标归
    ui_app._set_window_icon 管（用内嵌 base64 那份），跟 exe
    图标一致。

  --exclude-module=tkinter.test
    tkinter 带的 test 包（~3 MB）运行时永远用不到，打包会拖大 exe
    而且有时在 clean 环境启动会触发奇怪的 import。直接排除。

  不加 --exclude-module=PIL
    ui_app.py 22 行直接 from PIL import ...，不是 _make_icon.py
    才用。打了 --exclude-module=PIL 会 ModuleNotFoundError。

  不加 --add-data Lcon.png / app.ico
    ui_app._icon_candidates / _set_window_icon 已经写了
    "内嵌 base64 优先，磁盘兜底" 两条路，且对 --onefile 解压到
    _MEIPASS 失败的情况做了"完全不靠磁盘"的兜底。强行 --add-data
    反而让 _MEIPASS 失败时连兜底都失败。

⚠️ 打包后首次启动会卡 3-5 秒（PyInstaller bootloader 在
%TEMP%\_MEIxxxx 解压到内存再执行），不是死机。
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(HERE, "dist")
BUILD = os.path.join(HERE, "build")
SPEC = os.path.join(HERE, "VKBoxLiteSn.spec")
EXE_NAME = "VKBoxLiteSn"


def clean() -> None:
    """清掉旧的 build / dist / spec，避免 --onefile 旧文件残留。"""
    for p in (DIST, BUILD, SPEC):
        if os.path.exists(p):
            print(f"  清理 {os.path.relpath(p, HERE)}")
            shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)


def build() -> None:
    cmd = [
        sys.executable, "-m", "PyInstaller",
        "--onefile",
        "--noconsole",
        f"--name={EXE_NAME}",
        "--icon=app.ico",
        "--exclude-module=tkinter.test",
        "main.py",
    ]
    print(">>>", " ".join(cmd))
    subprocess.check_call(cmd, cwd=HERE)


def main() -> None:
    print("=== 1. 清理旧产物 ===")
    clean()
    print("=== 2. 打包 ===")
    build()
    print("=== 3. 完成 ===")
    exe = os.path.join(DIST, f"{EXE_NAME}.exe")
    if os.path.exists(exe):
        mb = os.path.getsize(exe) / 1024 / 1024
        print(f"  OK {exe}  ({mb:.1f} MB)")
    else:
        print(f"  FAIL 未找到 {exe}，请检查上面 PyInstaller 输出")
        sys.exit(1)


if __name__ == "__main__":
    main()
