"""字节级终验：exe 内嵌的 PNG 帧 vs app.ico 里的 PNG 帧。

这是最硬的判据：如果 PyInstaller 把 .ico 原样嵌进 exe，那么 exe 里每个
RT_ICON 的原始字节，应当与 app.ico 对应帧的原始字节【逐字节相等】。
不涉及任何重采样，不受缩放算法差异影响。

（像素级对比改用它，是因为 LANCZOS 重缩放源图会引入 1-4/255 的
边缘误差，让小尺寸帧假 FAIL，而 256 帧本来就是 0。）

用法: python _byte_verify_exe_icon.py
"""

import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
EXE = os.path.join(REPO, "pc_tool", "dist", "SnBurner.exe")
APPICO = os.path.join(HERE, "app.ico")
RT_ICON = 3


def sections_of(d):
    e = struct.unpack_from("<I", d, 0x3C)[0]
    coff = e + 4
    nsec = struct.unpack_from("<H", d, coff + 2)[0]
    opt_size = struct.unpack_from("<H", d, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from("<H", d, opt)[0]
    ddoff = opt + (96 if magic == 0x10B else 112)
    rsrc_va, _ = struct.unpack_from("<II", d, ddoff + 2 * 8)
    secs = []
    for i in range(nsec):
        off = opt + opt_size + i * 40
        nm = d[off:off + 8].rstrip(b"\x00").decode("latin1")
        vsize, vaddr, rsize, roff = struct.unpack_from("<IIII", d, off + 8)
        secs.append((nm, vaddr, vsize, rsize, roff))
    return rsrc_va, secs


def rva_to_off(rva, secs):
    for _n, va, vs, rs, ro in secs:
        if va <= rva < va + max(vs, rs):
            return ro + (rva - va)
    return None


def entries(d, base):
    nn, ni = struct.unpack_from("<HH", d, base + 12)
    out, eoff = [], base + 16
    for _ in range(nn + ni):
        nid, off = struct.unpack_from("<II", d, eoff)
        eoff += 8
        out.append((bool(off & 0x80000000), nid, off & 0x7FFFFFFF))
    return out


def exe_frames(d, rsrc_file, secs):
    out = {}
    for _d1, tid, o1 in entries(d, rsrc_file):
        if tid != RT_ICON:
            continue
        for _d2, name, o2 in entries(d, rsrc_file + o1):
            if not _d2:
                continue
            for d3, _n3, o3 in entries(d, rsrc_file + o2):
                if d3:
                    continue
                rva, sz = struct.unpack_from("<II", d, rsrc_file + o3)
                fo = rva_to_off(rva, secs)
                if fo is not None:
                    out[name] = d[fo:fo + sz]
    return out


def ico_frames(raw):
    """按 ICO 文件格式拆出每帧原始字节。"""
    if raw[:4] != b"\x00\x00\x01\x00":
        raise RuntimeError("不是标准 .ico")
    count = struct.unpack_from("<H", raw, 4)[0]
    out = {}
    for i in range(count):
        eoff = 6 + i * 16
        w, h, _cc, _res, _pl, _bc, nbytes, image_off = struct.unpack_from(
            "<BBBBHHII", raw, eoff)
        out[(w or 256, h or 256)] = raw[image_off:image_off + nbytes]
    return out


def main():
    for p, lbl in ((EXE, "exe"), (APPICO, "app.ico")):
        if not os.path.exists(p):
            print("FAIL 找不到 %s: %s" % (lbl, p))
            return 1

    with open(EXE, "rb") as f:
        d = f.read()
    rsrc_va, secs = sections_of(d)
    rsrc_file = rva_to_off(rsrc_va, secs)
    exe = exe_frames(d, rsrc_file, secs)

    with open(APPICO, "rb") as f:
        ref = ico_frames(f.read())

    print("  exe 帧数 = %d    app.ico 帧数 = %d" % (len(exe), len(ref)))
    print()
    print("  按尺寸配对后逐字节比对：")
    print()

    def size_of(b):
        if b[:8] == b"\x89PNG\r\n\x1a\n" and len(b) >= 24:
            return struct.unpack_from(">II", b, 16)
        if len(b) >= 12:
            return b[4] or 256, b[8] or 256
        return None, None

    exe_by_size = {size_of(b): b for b in exe.values()}

    all_ok = True
    matched = 0
    for (w, h), ref_blob in sorted(ref.items()):
        got = exe_by_size.get((w, h))
        if got is None:
            print("    [FAIL] %3dx%-3d  exe 里没有这个尺寸" % (w, h))
            all_ok = False
            continue
        if got == ref_blob:
            print("    [PASS] %3dx%-3d  字节完全相等（%d 字节）" % (w, h, len(got)))
            matched += 1
        else:
            n = min(len(got), len(ref_blob))
            first = next((i for i in range(n) if got[i] != ref_blob[i]), None)
            print("    [FAIL] %3dx%-3d  字节不同  exe=%d/B ico=%d/B 首个差异@%s"
                  % (w, h, len(got), len(ref_blob), first))
            all_ok = False

    print()
    print("  匹配 %d / %d 帧字节完全相等" % (matched, len(ref)))
    if all_ok and exe:
        print()
        print("  结论: exe 内嵌图标与 app.ico 逐字节一致，")
        print("        而 app.ico 由 _make_icon.py 从 Lcon.png 转出，")
        print("        所以 exe 用的就是 Lcon.png。")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
