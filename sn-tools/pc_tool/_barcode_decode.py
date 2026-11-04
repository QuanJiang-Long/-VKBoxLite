"""
独立 Code128 解码器 —— 用纯 PIL 像素 + Code128 标准表反向解出字符串。

跟 _barcode.py 的编码器共享同一个 _CODE128 表（独立 import，无共享逻辑），
但反查时按"模块宽度"做 key，跟编码时的位序列不耦合。
如果 _barcode.py 的 render() 有 bug，输出图就能在这里被识破。

用法:
  decode_pil_image(pim: Image.Image) -> str | None
  把 Code128 黑白图传进来，返回解码字符串，失败返回 None
"""
from __future__ import annotations
from PIL import Image
import _barcode                                   # noqa: E402

# 直接用 _barcode 的表（不复制，编码器改了我们这边自动同步）
# 但只用前 107 项 (0..106) —— _barcode 的表 107 元素。多了的扔掉。
_CODE128_FULL = _barcode._CODE_B
# 反向表：6-元素宽 (w0..w5) -> 索引
_REV_BY_WIDTH: dict[tuple[int, ...], int] = {
    tuple(t): i for i, t in enumerate(_CODE128_FULL) if len(t) == 6
}

# Code B 数据值 0..95 -> ASCII 32..127
# 96..102 是 FNC3/FNC2/SHIFT/CODE C/CODE B/FNC4/FNC1 控制符
_VALUE_TO_CHAR = {i: chr(0x20 + i) for i in range(96)}

# Code128 终止符（标准 6-元素）
_STOP = (2, 3, 3, 1, 1, 1)
# Code B Start
_START_B = (2, 1, 1, 2, 1, 4)


def _scan_runs(px, w: int, h: int) -> list[int]:
    """沿中间一行扫描 (bar=1 / space=0) 序列，输出 run-length 列表。"""
    y = h // 2
    runs: list[int] = []
    cur_val = 1 if sum(px[c, y] for c in range(min(w, 5))) / min(w, 5) < 128 else 0
    cur_len = 0
    for x in range(w):
        v = 0 if px[x, y] < 128 else 1
        if v == cur_val:
            cur_len += 1
        else:
            runs.append(cur_len)
            cur_val = v
            cur_len = 1
    runs.append(cur_len)
    return runs


def _normalize(runs: list[int]) -> list[int]:
    """估算 module 像素宽（取 25 分位）并把 run 缩放成 module 倍数。"""
    if not runs:
        return []
    nonzero = [r for r in runs if r > 0]
    if not nonzero:
        return runs
    s = sorted(nonzero)
    est = s[len(s) // 4]                          # 25 分位
    if est < 1:
        est = 1
    return [max(1, round(r / est)) for r in runs]


def decode_pil_image(pim: Image.Image) -> str | None:
    """把 Code128 Code B 黑白图解回字符串。失败返回 None。"""
    pim = pim.convert("L")
    px = pim.load()
    w, h = pim.size
    runs = _normalize(_scan_runs(px, w, h))

    # 找 Start B
    start_idx = None
    for i in range(len(runs) - 5):
        if tuple(runs[i:i + 6]) == _START_B:
            start_idx = i
            break
    if start_idx is None:
        return None

    # 找 Stop
    stop_idx = None
    for j in range(start_idx + 6, len(runs) - 5):
        if tuple(runs[j:j + 6]) == _STOP:
            stop_idx = j
            break
    if stop_idx is None:
        return None

    # 解码 Start + 数据 + 校验
    values: list[int] = []
    pos = start_idx + 6
    while pos < stop_idx:
        sym = tuple(runs[pos:pos + 6])
        if sym not in _REV_BY_WIDTH:
            return None
        values.append(_REV_BY_WIDTH[sym])
        pos += 6
    if len(values) < 2:
        return None
    data = values[:-1]
    # 校验公式: check = (Start + sum((i+1) * v_i, i=0..n-2)) % 103
    # 其中 Start = 104 (Code B 在 _CODE128 表里的索引)
    check_expected = (104 + sum((i + 1) * v for i, v in enumerate(data))) % 103
    if check_expected != values[-1]:
        return None
    out: list[str] = []
    for v in data:
        if v not in _VALUE_TO_CHAR:
            return None                          # FNC 等控制符
        out.append(_VALUE_TO_CHAR[v])
    return "".join(out)


if __name__ == "__main__":
    import sys
    import _barcode
    ok = True
    for s in ["12345", "11802026100800020", "00000000000000000",
              "ABC123-xyz_42", "A", "0", "The quick brown fox 1234567890"]:
        img = _barcode.render(s, module=2, height=120)
        decoded = decode_pil_image(img)
        mark = "OK  " if decoded == s else "FAIL"
        if decoded != s:
            ok = False
        print(f"  {mark} {s!r:30s} -> {decoded!r}")
    print("\n" + ("全部通过" if ok else "有失败"))
    sys.exit(0 if ok else 1)
