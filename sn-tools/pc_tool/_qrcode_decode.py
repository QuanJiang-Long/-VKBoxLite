"""
QR 解码器 —— 跟 _qrcode.py 编码器独立。

目标：把 _qrcode.render(text) 出的 PIL Image 解回 text。
用于 _st_all 验证：编码→出图→解码 跟原字符串一致。

最小化实现：
  1) 找 3 个 finder pattern 定位矩阵
  2) 读 format info -> 选掩码
  3) 反掩码
  4) 按蛇形顺序读数据模块
  5) 解析 mode + length + 数据
  6) Reed-Solomon 验证纠错码

只支持 _qrcode.py 出的图（Version 1..10, EC level M, 数字模式 / 字母模式 / 字节模式）。
"""
from __future__ import annotations
from PIL import Image


# ---- 同 _qrcode.py 的 GF(256) ----
_GF_PRIM = 0x11D
_GF_EXP = [0] * 512
_GF_LOG = [0] * 256


def _init_gf() -> None:
    x = 1
    for i in range(255):
        _GF_EXP[i] = x
        _GF_LOG[x] = i
        x <<= 1
        if x & 0x100:
            x ^= _GF_PRIM
    for i in range(255, 512):
        _GF_EXP[i] = _GF_EXP[i - 255]


_init_gf()


def gf_mul(a: int, b: int) -> int:
    return 0 if a == 0 or b == 0 else _GF_EXP[_GF_LOG[a] + _GF_LOG[b]]


def rs_generator_poly(n: int) -> list[int]:
    g = [1]
    for i in range(n):
        g = [g[0]] + [gf_mul(g[j], _GF_EXP[i]) ^ g[j + 1] for j in range(len(g) - 1)] + [g[-1] * 0]  # placeholder
    # 不用上面的，重新用 mul
    g = [1]
    for i in range(n):
        new_g = [0] * (len(g) + 1)
        for j in range(len(g)):
            new_g[j] ^= g[j]
            new_g[j + 1] ^= gf_mul(g[j], _GF_EXP[i])
        g = new_g
    return g


def rs_syndromes(data: list[int], n_ec: int) -> list[int]:
    """计算 syndrome — 应全 0 表示无误码。"""
    gen = rs_generator_poly(n_ec)
    s = []
    for i in range(n_ec):
        acc = 0
        for d in data:
            acc = gf_mul(acc, _GF_EXP[i]) ^ d
        s.append(acc)
    return s


# ---- EC level M 参数表 (同 _qrcode) ----
_PARAMS_M = {
    1:  (16, 10, 1, 16, 0),
    2:  (28, 16, 1, 28, 0),
    3:  (44, 26, 1, 44, 0),
    4:  (64, 36, 2, 32, 32),
    5:  (86, 48, 2, 43, 43),
    6:  (108, 64, 4, 27, 27),
    7:  (124, 72, 4, 31, 31),
    8:  (154, 88, 4, 38, 39),
    9:  (182, 112, 5, 36, 37),
    10: (216, 130, 5, 43, 44),
}


def _find_quiet_zone_size(img: Image.Image) -> int:
    """从白色边估静区模块数。"""
    pim = img.convert("L")
    w, h = pim.size
    px = pim.load()
    # 找第一行非白像素的 x
    edge = 0
    for x in range(w):
        for y in range(h):
            if px[x, y] < 128:
                edge = x
                break
        if edge:
            break
    if edge == 0:
        return 0
    # 估 module = 第一次连续黑色 run 长度
    run = 0
    for x in range(edge, min(w, edge + 30)):
        if px[x, h // 2] < 128:
            run += 1
    return max(1, edge // max(1, run))


def _read_matrix(img: Image.Image) -> tuple[list[list[int]], int, int]:
    """读 PIL Image -> 二值矩阵 + size + module。

    用 1:1:3:1:1 finder pattern 找 module 大小。
    扫描多行找，避开纯数据行。
    """
    pim = img.convert("L")
    w, h = pim.size
    px = pim.load()
    best = (0, 0, 0)                                    # (unit, start_x, y)
    for y in range(0, h, max(1, h // 40)):
        for start_x in range(0, w - 7):
            runs = []
            cur = px[start_x, y] < 128
            cur_len = 1
            for x in range(start_x + 1, min(start_x + 30, w)):
                v = px[x, y] < 128
                if v == cur:
                    cur_len += 1
                else:
                    runs.append((cur, cur_len))
                    if len(runs) >= 5:
                        break
                    cur = v
                    cur_len = 1
            else:
                runs.append((cur, cur_len))
            if len(runs) < 5:
                runs.append((cur, cur_len))
            if len(runs) < 5:
                continue
            if not (runs[0][0] and not runs[1][0] and runs[2][0] and not runs[3][0] and runs[4][0]):
                continue
            widths = [r[1] for r in runs[:5]]
            unit = sum(widths) / 7.0
            ok = all(abs(w / unit - target) <= tol for w, target, tol in
                     zip(widths, [1, 1, 3, 1, 1], [0.4, 0.4, 0.6, 0.4, 0.4]))
            if ok and unit > best[0]:
                best = (unit, start_x, y)
    if best[0] == 0:
        return [], 0, 0
    module = round(best[0])
    start_x = best[1]
    y_anchor = best[2]
    # 找静区
    quiet = 0
    for x in range(start_x - 1, -1, -1):
        if px[x, y_anchor] < 128:
            break
        quiet += 1
    quiet //= module
    n_modules = (w - 2 * quiet * module) // module
    matrix = []
    for r in range(n_modules):
        row = []
        for c in range(n_modules):
            x = quiet * module + c * module + module // 2
            y = quiet * module + r * module + module // 2
            if 0 <= x < w and 0 <= y < h:
                # 1 = 黑 (bar), 0 = 白 (space) — 跟 _qrcode.py 的 matrix 约定一致
                v = 1 if px[x, y] < 128 else 0
            else:
                v = 0
            row.append(v)
        matrix.append(row)
    return matrix, n_modules, module


def _read_format_info(matrix: list[list[int]], size: int) -> int | None:
    """从 P1 读 format info bits (MSB first)，返回 0..7 mask 编号或 None。"""
    # ISO 18004 EC level M 的 8 个 mask 格式信息
    format_m = [
        0b101010000010010, 0b101000100100101, 0b101111001111100,
        0b101101101001011, 0b100010111111001, 0b100000011001110,
        0b100111110010111, 0b100101010100000,
    ]
    # P1 位置: (8, 0..5), (8, 7), (8, 8), (7, 8), (5..0, 8)
    bits: list[int] = []
    for c in range(6):
        bits.append(matrix[8][c])
    bits.append(matrix[8][7])
    bits.append(matrix[8][8])
    bits.append(matrix[7][8])
    for r in range(5, -1, -1):
        bits.append(matrix[r][8])
    val = 0
    for b in bits:
        val = (val << 1) | b
    if val in format_m:
        return format_m.index(val)
    return None


def _is_data_cell(r: int, c: int, size: int) -> bool:
    """数据 cell 判定 —— 跟 _qrcode.py 编码器完全一致。

    编码器和解码器必须用同一份函数，否则写入和读取的 cell 集合不一致，
    会导致数据位错位，解码出乱码。
    """
    version = (size - 21) // 4 + 1
    # 暗模块
    if r == 4 * version + 9 and c == 8:
        return False
    # 时序
    if r == 6 or c == 6:
        return False
    # 3 个 finder (含隔离带) — 8x8
    if r < 8 and c < 8:
        return False
    if r < 8 and c >= size - 8:
        return False
    if r >= size - 8 and c < 8:
        return False
    # 格式信息 P1
    if r == 8 and (c < 6 or c == 7 or c == 8):
        return False
    if c == 8 and r < 6:
        return False
    if r == 7 and c == 8:
        return False
    # 格式信息 P2
    if c == 8 and size - 8 <= r < size:
        return False
    if r == 8 and size - 7 <= c < size:
        return False
    # 版本信息 (V ≥ 7)
    if version >= 7:
        if size - 11 <= r < size - 8 and c < 6:
            return False
        if c >= size - 11 and c < size - 8 and r < 6:
            return False
    return True


def _is_function(r: int, c: int, size: int) -> bool:
    """跟 _is_data_cell 反义 —— 供旧调用点用。"""
    return not _is_data_cell(r, c, size)


def _read_data_bits(matrix: list[list[int]], size: int) -> list[int]:
    """按蛇形顺序读所有非功能位。

    QR 数据读取规则（跟 _place_data 一致）：
      - 2 列一组，从右向左
      - 每组内 2 行一块（vert, vert-1），从下向上，步长 2
      - 块内顺序：右列下、右列上、左列下、左列上
      - 当 right==6 时只读 col=5
    """
    bits: list[int] = []
    for right in range(size - 1, 0, -2):
        cols = (5,) if right == 6 else (right, right - 1)
        for vert in range(size - 1, 0, -2):
            for col in cols:
                for v in (vert, vert - 1):
                    if not _is_function(v, col, size):
                        bits.append(matrix[v][col])
    if size > 6:
        for vert in range(size - 1, 0, -2):
            for col in (1, 0):
                for v in (vert, vert - 1):
                    if not _is_function(v, col, size):
                        bits.append(matrix[v][col])
    return bits


_MASK_FNS = [
    lambda r, c: (r + c) % 2 == 0,
    lambda r, c: r % 2 == 0,
    lambda r, c: c % 3 == 0,
    lambda r, c: (r + c) % 3 == 0,
    lambda r, c: (r // 2 + c // 3) % 2 == 0,
    lambda r, c: (r * c) % 2 + (r * c) % 3 == 0,
    lambda r, c: ((r * c) % 2 + (r * c) % 3) % 2 == 0,
    lambda r, c: ((r + c) % 2 + (r * c) % 3) % 2 == 0,
]


def _unmask(matrix: list[list[int]], mask: int) -> list[list[int]]:
    fn = _MASK_FNS[mask]
    out = [row[:] for row in matrix]
    for r in range(len(out)):
        for c in range(len(out)):
            if _is_function(r, c, len(out)):
                continue
            if fn(r, c):
                out[r][c] ^= 1
    return out


def _bits_to_int(bits: list[int], start: int, length: int) -> int:
    v = 0
    for i in range(length):
        v = (v << 1) | bits[start + i]
    return v


def _bits_to_bytes(bits: list[int]) -> list[int]:
    out = []
    for i in range(0, len(bits), 8):
        if i + 8 > len(bits):
            break
        v = 0
        for j in range(8):
            v = (v << 1) | bits[i + j]
        out.append(v)
    return out


def _int_to_bits(n: int, length: int) -> list[int]:
    return [(n >> (length - 1 - i)) & 1 for i in range(length)]


def _decode_data(bits: list[int], version: int) -> str | None:
    """从已解掩码的位流解出字符串。"""
    n_data = _PARAMS_M[version][0]
    # 限定到数据位 (前 n_data*8 位)
    bits = bits[:n_data * 8]
    pos = 0
    # mode indicator (4 bits)
    mode = _bits_to_int(bits, pos, 4)
    pos += 4
    if mode == 0b0001:                                       # numeric
        length_bits = 10 if version <= 9 else 12
        length = _bits_to_int(bits, pos, length_bits)
        pos += length_bits
        out = ""
        while len(out) < length:
            remaining = length - len(out)
            if remaining >= 3 and pos + 10 <= len(bits):
                v = _bits_to_int(bits, pos, 10)
                out += f"{v:03d}"
                pos += 10
            elif remaining == 2 and pos + 7 <= len(bits):
                v = _bits_to_int(bits, pos, 7)
                out += f"{v:02d}"
                pos += 7
            elif remaining == 1 and pos + 4 <= len(bits):
                v = _bits_to_int(bits, pos, 4)
                out += f"{v:01d}"
                pos += 4
            else:
                break
        return out[:length]
    if mode == 0b0010:                                       # alnum
        table = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
        length_bits = 9 if version <= 9 else 11
        length = _bits_to_int(bits, pos, length_bits)
        pos += length_bits
        out = ""
        while len(out) < length:
            remaining = length - len(out)
            if remaining >= 2 and pos + 11 <= len(bits):
                v = _bits_to_int(bits, pos, 11)
                out += table[v // 45] + table[v % 45]
                pos += 11
            elif remaining == 1 and pos + 6 <= len(bits):
                v = _bits_to_int(bits, pos, 6)
                out += table[v]
                pos += 6
            else:
                break
        return out[:length]
    if mode == 0b0100:                                       # byte
        length_bits = 8 if version <= 9 else 16
        length = _bits_to_int(bits, pos, length_bits)
        pos += length_bits
        raw = bytearray()
        for _ in range(length):
            if pos + 8 > len(bits):
                return None
            raw.append(_bits_to_int(bits, pos, 8))
            pos += 8
        return raw.decode("utf-8", errors="replace")
    return None


def decode_pil_image(img: Image.Image) -> str | None:
    """把 _qrcode.render() 出的图解回字符串。失败返回 None。"""
    matrix, size, _ = _read_matrix(img)
    if size < 21 or (size - 21) % 4 != 0:
        return None
    version = (size - 21) // 4 + 1
    if version not in _PARAMS_M:
        return None
    mask = _read_format_info(matrix, size)
    if mask is None:
        return None
    unmasked = _unmask(matrix, mask)
    bits = _read_data_bits(unmasked, size)
    return _decode_data(bits, version)


if __name__ == "__main__":
    import sys
    import _qrcode
    ok = True
    cases = ["12345", "11802026100800020", "00000000000000000",
             "AB-12 ABC-12", "Hello, World!", "98765432101234567"]
    for s in cases:
        img = _qrcode.render(s, module=4, quiet=4)
        decoded = decode_pil_image(img)
        mark = "OK  " if decoded == s else "FAIL"
        if decoded != s:
            ok = False
        print(f"  {mark} {s!r:25s} -> {decoded!r}")
    print("\n" + ("全部通过" if ok else "有失败"))
    sys.exit(0 if ok else 1)
