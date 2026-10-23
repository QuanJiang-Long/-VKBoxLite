"""打包产物终验：dist\\SnBurner.exe 里是不是【当前源码 + 当前图标数据】。

为什么要有这个：
    1. 源码改了但忘了重新打包，exe 里跑的还是老代码 —— 现场表现为
       "我明明改了，怎么还是老样子"。这类问题极难从界面反推。
       这里把 exe(PYZ) 里的字节码抠出来，跟当前源码逐个代码对象比对，
       不一致直接 FAIL。
    2. 图标是内嵌的 base64（打包后 exe 旁边没有 png），
       所以必须确认 _icon_data / _dialog_icon_data 真的在包里，
       而且字节跟仓库根的原图一致 —— 否则产线上的 exe 弹窗就是羽毛图标。

检查三件事：
    1. PYZ 里有 _icon_data / _dialog_icon_data，且解码后与原图逐字节相等
    2. PYZ 里的 ui_app / device 字节码 == 当前源码
    3. ui_app 代码里没有硬编码绝对路径（当年弹窗图标消失的元凶）

用法: python _chk_bundle.py
（需要先跑过 build.ps1，产物在 dist\\SnBurner.exe）
"""

import marshal
import os
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EXE = os.path.join(HERE, "dist", "SnBurner.exe")

ok = True


def check(cond, label, extra=""):
    global ok
    print(("  OK   " if cond else "  FAIL ") + label + (("  " + extra) if extra else ""))
    if not cond:
        ok = False


# 代码对象里要比的实质字段。
# ⚠️ 不能直接比 marshal.dumps()：co_filename / co_linetable 这类元数据
#    在 PyInstaller 里跟本地 compile() 出来的不完全一样，会误报"不一致"。
FIELDS = ("co_argcount", "co_kwonlyargcount", "co_nlocals", "co_flags",
          "co_code", "co_names", "co_varnames", "co_freevars",
          "co_cellvars", "co_consts")


def walk(c, path="<module>"):
    yield path, c
    for const in c.co_consts:
        if isinstance(const, types.CodeType):
            yield from walk(const, path + "." + const.co_name)


def compare(code_a, code_b) -> list:
    a = dict(walk(code_a))
    b = dict(walk(code_b))
    bad = []
    for k in sorted(set(a) | set(b)):
        if k not in a or k not in b:
            bad.append(k + " (只存在于一边)")
            continue
        for f in FIELDS:
            if getattr(a[k], f) != getattr(b[k], f):
                bad.append(f"{k} ({f})")
                break
    return bad


def main() -> int:
    print("=== 打包产物终验 ===")
    if not os.path.exists(EXE):
        print("FAIL 找不到产物:", EXE)
        return 1
    print("  产物:", EXE, f"({os.path.getsize(EXE) / 1024 / 1024:.1f} MB)")

    try:
        from PyInstaller.archive.readers import CArchiveReader, ZlibArchiveReader
    except ImportError:
        print("FAIL 没装 PyInstaller，跳过产物终验")
        return 1

    arc = CArchiveReader(EXE)
    pyz_names = [n for n in arc.toc if n.startswith("PYZ")]
    check(bool(pyz_names), "exe 里有 PYZ 归档")
    if not pyz_names:
        return 1

    with tempfile.TemporaryDirectory(dir=HERE) as td:
        pyz_path = os.path.join(td, "PYZ.pyz")
        with open(pyz_path, "wb") as f:
            f.write(arc.extract(pyz_names[0]))
        pyz = ZlibArchiveReader(pyz_path)

        #---- 1. 图标数据在包里，且与原图逐字节相等 ----
        import base64

        def load(modname):
            code = pyz.extract(modname)
            assert code is not None, f"{modname} 不在包里"
            ns = {}
            exec(code, ns)
            return ns

        try:
            icon = load("_icon_data")
            raw = base64.b64decode(icon["ICON_B64"].replace("\n", "").replace(" ", ""))
            with open(os.path.join(ROOT, "Lcon.png"), "rb") as f:
                src = f.read()
            check(raw == src and len(raw) == icon["ICON_BYTES"],
                  "exe 里的 _icon_data 与 Lcon.png 逐字节一致",
                  f"{len(raw)} vs {len(src)}")
        except Exception as e:                      # noqa: BLE001
            check(False, "exe 里的 _icon_data 不可用",
                  f"{type(e).__name__}: {e}")

        try:
            dlg = load("_dialog_icon_data")
            for name, (nbytes, b64) in dlg["ICONS"].items():
                raw = base64.b64decode(b64)
                with open(os.path.join(ROOT, name), "rb") as f:
                    src = f.read()
                check(len(raw) == nbytes and raw == src,
                      f"exe 里的 _dialog_icon_data {name} 与原图逐字节一致",
                      f"{len(raw)} vs {len(src)}")
        except Exception as e:                      # noqa: BLE001
            check(False, "exe 里的 _dialog_icon_data 不可用",
                  f"{type(e).__name__}: {e}")

        #---- 2. exe 里的代码 == 当前源码 ----
        for mod in ("ui_app", "device"):
            code = pyz.extract(mod)
            if code is None:
                check(False, f"{mod} 在包里")
                continue
            src_path = os.path.join(HERE, mod + ".py")
            with open(src_path, encoding="utf-8") as f:
                src = f.read()
            cur = compile(src, mod + ".py", "exec")
            bad = compare(code, cur)
            check(not bad, f"exe 里的 {mod} == 当前源码",
                  f"({len(dict(walk(code)))} 个代码对象)")
            for b in bad[:5]:
                print("        差异:", b)

        #---- 3. 没有硬编码绝对路径 ----
        src = open(os.path.join(HERE, "ui_app.py"), encoding="utf-8").read()
        code_only = "\n".join(l for l in src.split("\n")
                              if not l.strip().startswith("#"))
        check('Path("D:/' not in code_only,
              "ui_app 代码里没有硬编码绝对路径（弹窗图标消失的元凶）")

    print()
    print("打包产物终验: " + ("通过" if ok else "未通过"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
