"""验证打包后配置/台账路径是否落在 exe 同级目录。

PyInstaller --onefile 运行时，sys.executable 是 exe 本身（在 dist\\），
而 __file__ / os.getcwd() 可能指向 %TEMP%\\_MEIxxxx 解压目录。
若代码用相对路径读写 config.json 和 data\\，文件会写进临时目录，
每次运行都是新目录 -> 配置丢失、台账丢失。

用法: python _path_check.py
"""

import os
import sys


def describe():
    frozen = getattr(sys, "frozen", False)
    print(f"  sys.frozen        = {frozen}")
    print(f"  sys.executable    = {sys.executable}")
    print(f"  os.getcwd()       = {os.getcwd()}")
    print(f"  __file__          = {__file__}")


def exe_dir():
    """打包后应使用的基准目录：exe 所在目录。"""
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def main():
    print("当前进程视角:")
    describe()

    print()
    print("期望行为: config.json / data\\ 一律落在 exe 同级目录")
    base = exe_dir()
    print(f"  基准目录 = {base}")
    print(f"  config   = {os.path.join(base, 'config.json')}")
    print(f"  data     = {os.path.join(base, 'data')}")

    print()
    ok = True

    # 打包后基准目录必须不是临时解压目录
    if getattr(sys, "frozen", False):
        if "_MEI" in base:
            print("  [FAIL] 基准目录落在 _MEI 临时解压目录，配置/台账会丢")
            ok = False
        else:
            print("  [OK] 基准目录是 exe 同级目录")
    else:
        print("  [OK] 未打包（开发模式），基准目录 = 源码目录")

    # 基准目录必须可写
    if os.access(base, os.W_OK):
        print("  [OK] 基准目录可写")
    else:
        print("  [FAIL] 基准目录不可写（可能装在 Program Files）")
        ok = False

    print()
    print("结论: " + ("通过" if ok else "有问题，需修改 config.py 的路径解析"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
