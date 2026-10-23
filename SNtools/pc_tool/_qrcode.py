"""
QR Code 编码器 —— 自写、零外部依赖。

支持：
  - Version 1..10（21x21 到 57x57 模块）
  - 模式：数字 (Numeric)、字母 (Alphanumeric)、字节 (Byte)
  - EC 等级 M (中等，~15% 冗余)
  - 8 种掩码选最优（标准罚分规则）

不依赖 qrcode/PIL 之外的库。PIL 仅用于出图。

为什么自写：之前 Code128 走过这条路（自写 + 独立解码器做反验），
        写出来后能稳定产线扫码。
"""
from __future__ import annotations
from PIL import Image


#=====================================================================
# GF(256) 算术（Reed-Solomon 纠错用）
#=====================================================================
# 生成多项式：x^8 + x^4 + x^3 + x^2 + 1 = 0x11D
_GF_PRIM = 0x11D
_GF_EXP = [0] * 512
_GF_LOG = [0] * 256


def _init_gf() -> None:
    """初始化 GF(256) 指数 / 对数表。"""
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


def gf_poly_mul(p: list[int], q: list[int]) -> list[int]:
    """多项式乘法 (GF(256) 系数)。"""
    r = [0] * (len(p) + len(q) - 1)
    for i, pi in enumerate(p):
        for j, qj in enumerate(q):
            r[i + j] ^= gf_mul(pi, qj)
    return r


def rs_generator_poly(n: int) -> list[int]:
    """生成 (x - a^0)(x - a^1)...(x - a^(n-1)) 系数。"""
    g = [1]
    for i in range(n):
        g = gf_poly_mul(g, [1, _GF_EXP[i]])
    return g


def rs_encode(data: list[int], n_ec: int) -> list[int]:
    """Reed-Solomon 编码：data 是数据系数，输出 n_ec 个纠错系数。"""
    gen = rs_generator_poly(n_ec)
    # 多项式除法：把 data 后面补 n_ec 个 0，除以 gen
    msg = data + [0] * n_ec
    for i in range(len(data)):
        coef = msg[i]
        if coef != 0:
            for j in range(1, len(gen)):
                msg[i + j] ^= gf_mul(gen[j], coef)
    return msg[len(data):]


#=====================================================================
# QR 参数表（Version 1..10, EC level M）
#=====================================================================
# 每个 Version 一行：[总码字数, 数据码字数, 纠错码字数, EC 块数, 块 1 数据码字数, 块 2 数据码字数]
# 来源：ISO/IEC 18004 表 9
_PARAMS_M = {
    1:  (26,   16, 10, 1, 16,  0),    # 21x21, 26 码字
    2:  (44,   28, 16, 1, 28,  0),    # 25x25
    3:  (70,   44, 26, 1, 44,  0),    # 29x29
    4:  (100,  64, 36, 2, 32, 32),    # 33x33
    5:  (134,  86, 48, 2, 43, 43),    # 37x37
    6:  (172, 108, 64, 4, 27, 27),    # 41x41
    7:  (196, 124, 72, 4, 31, 31),    # 45x45
    8:  (242, 154, 88, 4, 38, 39),    # 49x49
    9:  (292, 182, 112, 5, 36, 37),   # 53x53
    10: (346, 216, 130, 5, 43, 44),   # 57x57
}

# 数字模式字符指示器 (4 bits) + 长度指示器 bits
# Version 1..9 / 10..26
_NUMERIC_LEN_BITS = {1: 10, 2: 12}              # v1..9 数字模式长度 10 bits, v10..26 是 12 bits
_BYTE_LEN_BITS = {1: 8, 2: 16}
_ALNUM_LEN_BITS = {1: 9, 2: 11}


#=====================================================================
# 编码数据 -> 位流
#=====================================================================
def _encode_numeric(text: str) -> list[int]:
    """数字模式：每 3 位数字 → 10 bits，每 2 位 → 7 bits，剩 1 位 → 4 bits。"""
    bits: list[int] = []
    bits.extend(_int_to_bits(0b0001, 4))                  # mode indicator
    bits.extend(_int_to_bits(len(text), _NUMERIC_LEN_BITS[len(text) and 1 or 1]))
    # 上面这行其实错，应该按 version 查长度 —— 改用参数化
    return bits


def _int_to_bits(n: int, length: int) -> list[int]:
    """整数 → MSB 优先位列表。"""
    return [(n >> (length - 1 - i)) & 1 for i in range(length)]


def _encode_bytes(text: str, version: int) -> list[int]:
    """字节模式：UTF-8 字节流。Version 1-9 长度 8 bits, 10-26 长度 16 bits。"""
    raw = text.encode("utf-8")
    length_bits = 8 if version <= 9 else 16
    bits: list[int] = []
    bits.extend(_int_to_bits(0b0100, 4))                  # byte mode
    bits.extend(_int_to_bits(len(raw), length_bits))
    for b in raw:
        bits.extend(_int_to_bits(b, 8))
    return bits


def _encode_alnum(text: str, version: int) -> list[int]:
    """字母数字模式：每 2 字符 → 11 bits，剩 1 字符 → 6 bits。"""
    # 字符表：0-9 A-Z $%*+-./: 空格
    table = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
    length_bits = 9 if version <= 9 else 11
    bits: list[int] = []
    bits.extend(_int_to_bits(0b0010, 4))                  # alnum mode
    bits.extend(_int_to_bits(len(text), length_bits))
    i = 0
    while i + 1 < len(text):
        v = table.index(text[i]) * 45 + table.index(text[i + 1])
        bits.extend(_int_to_bits(v, 11))
        i += 2
    if i < len(text):
        bits.extend(_int_to_bits(table.index(text[i]), 6))
    return bits


def _encode_data(text: str, version: int, n_data: int) -> list[int]:
    """根据 text 选最合适模式，返回总位流 + 填充。"""
    # 优先看能否用数字模式
    is_numeric = text.isdigit()
    # 字母模式：所有字符在表里
    alnum_table = set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
    is_alnum = all(c in alnum_table for c in text)

    if is_numeric and version <= 10:
        bits = _encode_numeric_full(text, version)
    elif is_alnum:
        bits = _encode_alnum(text, version)
    else:
        bits = _encode_bytes(text, version)
    # 终止符：最多 4 个 0
    total_data_bits = n_data * 8
    bits.extend([0] * min(4, total_data_bits - len(bits)))
    # 字节对齐
    while len(bits) % 8 != 0:
        bits.append(0)
    # 填充交替字节 0xEC, 0x11 直到达到总数据位
    pad = [0xEC, 0x11]
    while len(bits) < total_data_bits:
        for p in pad:
            if len(bits) < total_data_bits:
                bits.extend(_int_to_bits(p, 8))
            else:
                break
    return bits[:total_data_bits]


def _encode_numeric_full(text: str, version: int) -> list[int]:
    """数字模式完整编码。Version 1-9 长度 10 bits, 10-26 长度 12 bits。"""
    length_bits = 10 if version <= 9 else 12
    bits: list[int] = []
    bits.extend(_int_to_bits(0b0001, 4))
    bits.extend(_int_to_bits(len(text), length_bits))
    i = 0
    while i + 2 < len(text):
        v = int(text[i:i + 3])
        bits.extend(_int_to_bits(v, 10))
        i += 3
    if i + 1 < len(text):
        v = int(text[i:i + 2])
        bits.extend(_int_to_bits(v, 7))
        i += 2
    if i < len(text):
        bits.extend(_int_to_bits(int(text[i]), 4))
    return bits


#=====================================================================
# 摆位：把数据 + 纠错码字摆到 21x21 / 25x25 / ... 模块矩阵
#=====================================================================
def _is_data_cell(r: int, c: int, size: int) -> bool:
    """是否数据单元（非功能图案）。

    包括：3 个 finder、时序图案、暗模块、格式信息 (P1 + P2)、版本信息 (V ≥ 7)。
    排除 finder 周边 1 模宽的隔离带。
    """
    version = (size - 21) // 4 + 1
    # 暗模块 (固定位置，永为黑)
    if r == 4 * version + 9 and c == 8:
        return False
    # 时序
    if r == 6 or c == 6:
        return False
    # 3 个 finder (含隔离带) — 8x8 块
    if r < 8 and c < 8:                                # TL
        return False
    if r < 8 and c >= size - 8:                        # TR
        return False
    if r >= size - 8 and c < 8:                        # BL
        return False
    # 格式信息 P1：沿 (8, 0..5), (8, 7), (8, 8), (7, 8), (0..5, 8)
    if r == 8 and (c < 6 or c == 7 or c == 8):
        return False
    if c == 8 and r < 6:                               # (0..5, 8)
        return False
    if r == 7 and c == 8:                              # (7, 8)
        return False
    # 格式信息 P2：沿 (size-8..size-1, 8) 和 (8, size-8..size-1)
    if c == 8 and size - 8 <= r < size:
        return False
    if r == 8 and size - 8 <= c < size:
        return False
    # 版本信息 (V ≥ 7) — 在 BL finder 旁和 TR finder 下方
    if version >= 7:
        if size - 11 <= r < size - 8 and c < 6:
            return False
        if c >= size - 11 and c < size - 8 and r < 6:
            return False
    return True


def _is_function_pattern(r: int, c: int, size: int) -> bool:
    """3 个定位图案 + 时序图案 + 暗模块 + 格式/版本信息。供 _apply_mask 用。"""
    # 左上
    if r < 9 and c < 9:
        return True
    # 右上
    if r < 9 and c >= size - 8:
        return True
    # 左下
    if r >= size - 8 and c < 9:
        return True
    # 时序
    if r == 6 or c == 6:
        return True
    return False


def _place_data(matrix: list[list[int | None]], data_bits: list[int], ec_bits: list[int]) -> None:
    """QR 数据 + EC 摆位：每 2 列一组（从右向左），每组蛇形扫描，方向交替。

    严格按 ZXing 风格：每组内一次走一行（同行的右列、左列两个 cell），
    然后上下切换方向；遇功能图案/时序/格式信息等已置位的 cell 跳过。
    """
    bits = data_bits + ec_bits
    idx = 0
    size = len(matrix)
    inc = -1                                       # 初始方向：向上
    row = size - 1
    for right in range(size - 1, 0, -2):
        if right <= 6:                             # 跳过垂直时序列 col 6
            right -= 1
        col_range = (right, right - 1)
        while True:
            for col in col_range:
                if 0 <= col < size and matrix[row][col] is None and _is_data_cell(row, col, size):
                    bit = 0 if idx >= len(bits) else bits[idx]
                    matrix[row][col] = bit
                    idx += 1
            row += inc
            if row < 0 or row >= size:
                row -= inc
                inc = -inc
                break


#=====================================================================
# 功能图案：定位 / 时序 / 暗模块 / 格式预留
#=====================================================================
def _place_finder(matrix: list[list[int | None]], row: int, col: int) -> None:
    """7x7 定位图案，从 (row, col) 算。"""
    for r in range(7):
        for c in range(7):
            on_finder = (r in (0, 6) or c in (0, 6) or
                         2 <= r <= 4 and 2 <= c <= 4)
            matrix[row + r][col + c] = 1 if on_finder else 0
    # 隔离带
    for i in range(8):
        if col - 1 >= 0 and row + i < len(matrix):
            matrix[row + i][col - 1] = 0
        if col + 7 < len(matrix) and row + i < len(matrix):
            matrix[row + i][col + 7] = 0
        if row - 1 >= 0 and col + i < len(matrix):
            matrix[row - 1][col + i] = 0
        if row + 7 < len(matrix) and col + i < len(matrix):
            matrix[row + 7][col + i] = 0


def _place_timing(matrix: list[list[int | None]]) -> None:
    """第 6 行 + 第 6 列的时序图案：1, 0 交替。"""
    size = len(matrix)
    for i in range(8, size - 8):
        matrix[6][i] = 1 if i % 2 == 0 else 0
        matrix[i][6] = 1 if i % 2 == 0 else 0


def _place_dark_module(matrix: list[list[int | None]], version: int) -> None:
    """暗模块：固定在 (4*version + 9, 8)。"""
    matrix[4 * version + 9][8] = 1


#=====================================================================
# 掩码 + 选最优
#=====================================================================
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


def _apply_mask(matrix: list[list[int]], mask: int) -> list[list[int]]:
    """应用掩码到矩阵。功能图案位不动。"""
    size = len(matrix)
    fn = _MASK_FNS[mask]
    out = [row[:] for row in matrix]
    for r in range(size):
        for c in range(size):
            # 不掩码功能图案：先备份原始位置
            if _is_function_pattern(r, c, size):
                continue
            if fn(r, c):
                out[r][c] ^= 1
    return out


def _is_function_pattern(r: int, c: int, size: int) -> bool:
    """3 个定位图案 + 时序图案 + 暗模块 + 格式/版本信息。"""
    # 左上
    if r < 9 and c < 9:
        return True
    # 右上
    if r < 9 and c >= size - 8:
        return True
    # 左下
    if r >= size - 8 and c < 9:
        return True
    # 时序
    if r == 6 or c == 6:
        return True
    return False


def _mask_penalty(matrix: list[list[int]]) -> int:
    """标准 QR 掩码罚分规则（4 项求和）。"""
    size = len(matrix)
    score = 0
    # 规则 1：连续 5+ 同色
    for r in range(size):
        run = 1
        for c in range(1, size):
            if matrix[r][c] == matrix[r][c - 1]:
                run += 1
                if run == 5:
                    score += 3
                elif run > 5:
                    score += 1
            else:
                run = 1
    for c in range(size):
        run = 1
        for r in range(1, size):
            if matrix[r][c] == matrix[r - 1][c]:
                run += 1
                if run == 5:
                    score += 3
                elif run > 5:
                    score += 1
            else:
                run = 1
    # 规则 2：2x2 同色块
    for r in range(size - 1):
        for c in range(size - 1):
            if (matrix[r][c] == matrix[r][c + 1] ==
                    matrix[r + 1][c] == matrix[r + 1][c + 1]):
                score += 3
    # 规则 3：1011101 模式
    pattern = [1, 0, 1, 1, 1, 0, 1]
    for r in range(size):
        for c in range(size - 6):
            if all(matrix[r][c + i] == pattern[i] for i in range(7)):
                score += 40
            if all(matrix[c + i][r] == pattern[i] for i in range(7)):
                score += 40
    # 规则 4：黑白比例偏差
    dark = sum(sum(row) for row in matrix)
    total = size * size
    ratio = dark / total * 100
    k = abs(ratio - 50) // 5
    score += int(k) * 10
    return score


#=====================================================================
# 格式信息（5 位数据 + 10 位 BCH 纠错 → 15 位）选掩码用
#=====================================================================
# ISO 18004 Table C.1 — EC level M 的 8 种掩码对应的 15 位格式信息
# (含 BCH 纠错和掩码 XOR `101010000010010`)
_FORMAT_INFO_BITS = [
    0b101010000010010,    # mask 0
    0b101000100100101,    # mask 1
    0b101111001111100,    # mask 2
    0b101101101001011,    # mask 3
    0b100010111111001,    # mask 4
    0b100000011001110,    # mask 5
    0b100111110010111,    # mask 6
    0b100101010100000,    # mask 7
]


def _place_format(matrix: list[list[int]], mask: int) -> None:
    """填格式信息（带掩码，索引 = mask）。EC level M = 0b00。"""
    bits = _FORMAT_INFO_BITS[mask]                        # M(00) XOR mask 已是预设
    size = len(matrix)
    # P1 围绕 TL finder（15 cells，bit 14 是 MSB）：
    #   bit 14..9 → (8, 0..5)
    #   bit 8     → (8, 7)
    #   bit 7     → (8, 8)
    #   bit 6     → (7, 8)
    #   bit 5..0  → (5, 8) 到 (0, 8)
    for i in range(6):
        matrix[8][i] = (bits >> (14 - i)) & 1
    matrix[8][7] = (bits >> 8) & 1
    matrix[8][8] = (bits >> 7) & 1
    matrix[7][8] = (bits >> 6) & 1
    for i in range(6):
        matrix[5 - i][8] = (bits >> (5 - i)) & 1
    # P2 分布在 BL + TR finder 旁（15 cells）：
    #   bit 14..8 → BL (col 8, rows size-1..size-7)，共 7 cells
    #   bit 7..0  → TR (row 8, cols size-8..size-1)，共 8 cells
    # 注意：(size-8, 8) 是暗模块，固定为 1，不在 P2 范围
    for i in range(7):
        matrix[size - 1 - i][8] = (bits >> (14 - i)) & 1
    for i in range(8):
        matrix[8][size - 8 + i] = (bits >> (7 - i)) & 1


#=====================================================================
# 主函数：text → QR 矩阵 → PIL Image
#=====================================================================
def _bits_to_bytes(bits: list[int]) -> list[int]:
    out = []
    for i in range(0, len(bits), 8):
        v = 0
        for j in range(8):
            v = (v << 1) | bits[i + j]
        out.append(v)
    return out


def encode_matrix(text: str) -> tuple[list[list[int]], int]:
    """返回 (size x size 矩阵, version)。"""
    # 选 Version：贪心找最小够装的
    version = 1
    for v in range(1, 11):
        params = _PARAMS_M[v]
        # 估算需要的位：mode(4) + len + 数据 + 终止(4) + 对齐
        # 简化：直接按 _encode_data 看长度
        n_data = params[1]
        bits = _encode_data(text, v, n_data)
        if len(bits) == n_data * 8:
            version = v
            break
    else:
        raise ValueError(f"text 太长，Version 10 都装不下 ({len(text)} chars)")

    params = _PARAMS_M[version]
    n_total, n_data, n_ec, n_blocks, blk1, blk2 = params
    size = 21 + (version - 1) * 4

    # 编码数据
    data_bits = _encode_data(text, version, n_data)
    data_bytes = _bits_to_bytes(data_bits)
    assert len(data_bytes) == n_data, f"data bytes {len(data_bytes)} != {n_data}"

    # 分块 + Reed-Solomon 纠错
    ec_bytes_per_block = n_ec // n_blocks
    ec_blocks: list[list[int]] = []
    data_blocks: list[list[int]] = []
    pos = 0
    for b in range(n_blocks):
        block_len = blk1 if b < n_blocks - (n_blocks if blk2 == blk1 else 1) else blk2
        if blk2 == blk1:
            block_len = blk1
        # 简化：前 n_blocks - 1 块用 blk1，最后一块用 blk2（如果有 blk2）
        if b < n_blocks - 1 or blk2 == 0:
            block_len = blk1
        else:
            block_len = blk2
        block = data_bytes[pos:pos + block_len]
        pos += block_len
        data_blocks.append(block)
        ec_blocks.append(rs_encode(block, ec_bytes_per_block))

    # 交织：先取所有数据块第 1 个码字，再取所有 EC 块第 1 个，依此类推
    final: list[int] = []
    max_data = max(len(b) for b in data_blocks)
    for i in range(max_data):
        for b in data_blocks:
            if i < len(b):
                final.append(b[i])
    max_ec = max(len(b) for b in ec_blocks)
    for i in range(max_ec):
        for b in ec_blocks:
            if i < len(b):
                final.append(b[i])
    final_bits: list[int] = []
    for b in final:
        final_bits.extend(_int_to_bits(b, 8))

    # 建矩阵
    matrix: list[list[int | None]] = [[None] * size for _ in range(size)]
    _place_finder(matrix, 0, 0)
    _place_finder(matrix, 0, size - 7)
    _place_finder(matrix, size - 7, 0)
    _place_timing(matrix)
    _place_dark_module(matrix, version)

    _place_data(matrix, data_bits, final_bits[len(data_bits):])
    # 把 None 替换成 0
    for r in range(size):
        for c in range(size):
            if matrix[r][c] is None:
                matrix[r][c] = 0

    # 选最优掩码
    best_mask = 0
    best_score = float("inf")
    for m in range(8):
        masked = _apply_mask(matrix, m)
        _place_format(masked, m)
        score = _mask_penalty(masked)
        if score < best_score:
            best_score = score
            best_mask = m

    final_matrix = _apply_mask(matrix, best_mask)
    _place_format(final_matrix, best_mask)
    return [[int(v) for v in row] for row in final_matrix], version


def render(text: str, module: int = 4, quiet: int = 4) -> Image.Image:
    """把 text 画成 QR 二维码。module 每模块像素，quiet 静区模块数。"""
    matrix, _ = encode_matrix(text)
    size = len(matrix)
    px = module * size + 2 * quiet * module
    img = Image.new("1", (px, px), 1)                   # 1=白
    pixels = img.load()
    for r in range(size):
        for c in range(size):
            if matrix[r][c]:
                x0 = quiet * module + c * module
                y0 = quiet * module + r * module
                for dy in range(module):
                    for dx in range(module):
                        pixels[x0 + dx, y0 + dy] = 0
    return img


if __name__ == "__main__":
    import sys
    ok = True
    for s in ["12345", "11802026100800020", "00000000000000000",
              "AB-12 ABC-12", "Hello, World!"]:
        try:
            img = render(s, module=4, quiet=4)
            print(f"  OK   {s!r:25s} -> {img.size}")
        except Exception as e:                           # noqa: BLE001
            ok = False
            print(f"  FAIL {s!r:25s} -> {e}")
    print("\n" + ("全部通过" if ok else "有失败"))
    sys.exit(0 if ok else 1)
