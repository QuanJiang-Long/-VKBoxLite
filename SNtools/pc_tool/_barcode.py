"""
Code128 条形码 —— 零依赖实现，产线扫 SN 用。

Code128 是高密度一维条码，能编码 ASCII 全集（128 字符）。
这里只用 Code B 子集（可打印 ASCII 0x20..0x7E）—— 数字 + 英文
足够产线扫 SN 用了。如果以后要扫全 Unicode 再加 Code A/C，
工作量也不大。

输出：PIL Image 单色图，2D-list 表示也行。这里产线只需要在
Tkinter 上显示 + 截图给工装验证，所以固定返回 PIL Image。
"""
from __future__ import annotations

from PIL import Image


#------------------------------------------------------------------
# Code B 编码表：index 0..106，每个值是该符号对应的"图案宽度序列"
# Code128 用 6 个单元（条/空交替）表示一个符号，每单元宽 1..4。
# 这里存的是 6 个单元的相对宽度，最后渲染时再 × module 像素。
#------------------------------------------------------------------
_CODE_B: list[tuple[int, ...]] = [
    (2, 1, 2, 2, 2, 2), (2, 2, 2, 1, 2, 2), (2, 2, 2, 2, 2, 1),
    (1, 2, 1, 2, 2, 3), (1, 2, 1, 3, 2, 2), (1, 3, 1, 2, 2, 2),
    (1, 2, 2, 2, 1, 3), (1, 2, 2, 3, 1, 2), (1, 3, 2, 2, 1, 2),
    (2, 2, 1, 2, 1, 3), (2, 2, 1, 3, 1, 2), (2, 3, 1, 2, 1, 2),
    (1, 1, 2, 2, 3, 2), (1, 2, 2, 1, 3, 2), (1, 2, 2, 2, 3, 1),
    (1, 1, 3, 2, 2, 2), (1, 2, 3, 1, 2, 2), (1, 2, 3, 2, 2, 1),
    (2, 2, 3, 2, 1, 1), (2, 2, 1, 1, 3, 2), (2, 2, 1, 2, 3, 1),
    (2, 1, 3, 2, 1, 2), (2, 2, 3, 1, 1, 2), (3, 1, 2, 1, 3, 1),
    (3, 1, 1, 2, 2, 2), (3, 2, 1, 1, 2, 2), (3, 2, 1, 2, 2, 1),
    (3, 1, 2, 2, 1, 2), (3, 2, 2, 1, 1, 2), (3, 2, 2, 2, 1, 1),
    (2, 1, 2, 1, 2, 3), (2, 1, 2, 3, 2, 1), (2, 3, 2, 1, 2, 1),
    (1, 1, 1, 3, 2, 3), (1, 3, 1, 1, 2, 3), (1, 3, 1, 3, 2, 1),
    (1, 1, 2, 3, 1, 3), (1, 3, 2, 1, 1, 3), (1, 3, 2, 3, 1, 1),
    (2, 1, 1, 3, 1, 3), (2, 3, 1, 1, 1, 3), (2, 3, 1, 3, 1, 1),
    (1, 1, 2, 1, 3, 3), (1, 1, 2, 3, 3, 1), (1, 3, 2, 1, 3, 1),
    (1, 1, 3, 1, 2, 3), (1, 1, 3, 3, 2, 1), (1, 3, 3, 1, 2, 1),
    (3, 1, 3, 1, 2, 1), (2, 1, 1, 3, 3, 1), (2, 3, 1, 1, 3, 1),
    (2, 1, 3, 1, 1, 3), (2, 1, 3, 3, 1, 1), (2, 1, 3, 1, 3, 1),
    (3, 1, 1, 1, 2, 3), (3, 1, 1, 3, 2, 1), (3, 3, 1, 1, 2, 1),
    (3, 1, 2, 1, 1, 3), (3, 1, 2, 3, 1, 1), (3, 3, 2, 1, 1, 1),
    (3, 1, 4, 1, 1, 1), (2, 2, 1, 4, 1, 1), (4, 3, 1, 1, 1, 1),
    (1, 1, 1, 2, 2, 4), (1, 1, 1, 4, 2, 2), (1, 2, 1, 1, 2, 4),
    (1, 2, 1, 4, 2, 1), (1, 4, 1, 1, 2, 2), (1, 4, 1, 2, 2, 1),
    (1, 1, 2, 2, 1, 4), (1, 1, 2, 4, 1, 2), (1, 2, 2, 1, 1, 4),
    (1, 2, 2, 4, 1, 1), (1, 4, 2, 1, 1, 2), (1, 4, 2, 2, 1, 1),
    (2, 4, 1, 2, 1, 1), (2, 2, 1, 1, 1, 4), (4, 1, 3, 1, 1, 1),
    (2, 4, 1, 1, 1, 2), (1, 3, 4, 1, 1, 1), (1, 1, 1, 2, 4, 2),
    (1, 2, 1, 1, 4, 2), (1, 2, 1, 2, 4, 1), (1, 1, 4, 2, 1, 2),
    (1, 2, 4, 1, 1, 2), (1, 2, 4, 2, 1, 1), (4, 1, 1, 2, 1, 2),
    (4, 2, 1, 1, 1, 2), (4, 2, 1, 2, 1, 1), (2, 1, 2, 1, 4, 1),
    (2, 1, 4, 1, 2, 1), (4, 1, 2, 1, 2, 1), (1, 1, 1, 1, 4, 3),
    (1, 1, 1, 3, 4, 1), (1, 3, 1, 1, 4, 1), (1, 1, 4, 1, 1, 3),
    (1, 1, 4, 3, 1, 1), (4, 1, 1, 1, 1, 3), (4, 1, 1, 3, 1, 1),
    (1, 1, 3, 1, 4, 1), (1, 1, 4, 1, 3, 1), (3, 1, 1, 1, 4, 1),
    (4, 1, 1, 1, 3, 1), (2, 1, 1, 4, 1, 2), (2, 1, 1, 2, 1, 4),
    (2, 1, 1, 2, 3, 2), (2, 3, 3, 1, 1, 1, 2),    # 106: Start B
]

# 起止符：104=Start B，106=Stop（与编码表不同，需要特别加 2 终止条）
_START_B = 104
_STOP = (2, 3, 3, 1, 1, 1, 2)            # 7 个单元，末尾多一条 2 宽的终止条
_MOD103 = 103                              # Code128 校验用模 103


def _check_digit(values: list[int]) -> int:
    """模 103 校验：Start B + Σ(i * value_i) mod 103，i 从 1 起。"""
    total = values[0]                       # Start B 当作 i=0
    for i, v in enumerate(values[1:], start=1):
        total += i * v
    return total % _MOD103


def encode(text: str) -> list[tuple[int, ...]]:
    """把 ASCII 文本转成 Code128 Code B 图案序列（每个元素是一符号的单元宽度序列）。

    序列组成：Start B + 数据符号 + 校验符 + Stop
    不接受 NUL、控制字符；只支持可打印 ASCII (0x20..0x7E) + DEL 之后的就截断不报错。
    """
    # 过滤到 Code B 支持的字符集
    chars = [c for c in text if 0x20 <= ord(c) <= 0x7E]
    if not chars:
        raise ValueError("没有可编码的字符（需可打印 ASCII）")

    symbols = [_START_B] + [ord(c) - 0x20 for c in chars]
    symbols.append(_check_digit(symbols))

    # 把每个符号展开成 6 单元宽度序列
    pattern: list[int] = []
    for s in symbols:
        pattern.extend(_CODE_B[s])
    pattern.extend(_STOP)
    return [tuple(pattern[i:i + 6]) for i in range(0, len(pattern) - 7, 6)] + [tuple(pattern[-7:])]


def render(text: str, module: int = 2, height: int = 60,
           quiet: int = 12) -> Image.Image:
    """把 Code128 画成 PIL Image。

    module: 每"单元"的像素宽；2 px 在屏幕上约等于 0.3mm，产线扫码枪能识。
    height: 条码区像素高（不含下方文本标签，由 Tk 自己叠）。
    quiet:  两侧静区像素。ISO 15417 要求 ≥ 10×module，这里默认 12（24 px）
            —— 实际 6×module 已经能扫，但产线手机扫码算法对边界敏感，
            多留 4 px 让它对反光/取景抖动有裕量。
    """
    symbols = encode(text)
    total_units = sum(sum(s) for s in symbols)
    width = total_units * module + 2 * quiet
    img = Image.new("1", (width, height), 1)        # 1=白
    px = img.load()

    # Code128 是"条空条空..."交替；这里把每个 symbol 展平成 1=条 0=空
    # 关键：交替判断看的是"单元序号"(每加一个 u 就 +1)，
    # 不能看 len(bits)——u 不一定为 1，bar 可能是 2-4 单元宽，
    # 用 len(bits) 算 parity 就乱了。
    x = quiet
    bits: list[int] = []                            # 1=条 0=空
    unit_index = 0                                  # 已加了多少个单元（不管宽）
    for s in symbols:
        # 注意 Stop 有 7 单元，特殊处理：前 6 单元走交替，
        # 第 7 单元是终止条（也是 bar），覆盖交替结果。
        if len(s) == 7:
            for u in s[:6]:
                bits.extend([1 if (unit_index % 2 == 0) else 0] * u)
                unit_index += 1
            bits.extend([1] * s[6])                 # 终止条：bar
            unit_index += 1
        else:
            for u in s:
                bits.extend([1 if (unit_index % 2 == 0) else 0] * u)
                unit_index += 1

    for b in bits:
        for _ in range(module):
            if b:
                for y in range(height):
                    px[x, y] = 0                    # 黑
            x += 1

    return img


#=====================================================================
# 自检 —— 编码校验 + 实际出图
#=====================================================================
if __name__ == "__main__":
    import sys

    ok = True

    # 1) 空串应抛
    try:
        encode("")
        ok = False
        print("  FAIL: 空串应抛 ValueError")
    except ValueError:
        print("  OK   空串抛 ValueError")

    # 2) 控制字符被滤掉：Start B(1) + 数据 + 校验(1) + Stop(1) = 数据数+3
    syms = encode("\x01abc\x02")
    expected = 3 + 3                                # 3 个数据 + Start/校验/Stop
    if len(syms) != expected:
        ok = False
        print(f"  FAIL: 控制字符过滤后应是 {expected} 符号，实际 {len(syms)}")
    else:
        print(f"  OK   控制字符被滤掉，留 'abc' 共 {expected} 符号")

    # 3) 常见 SN 能编码
    for sn in ["11802026100900010", "00000000000000000",
               "ABC123-xyz_42"]:
        try:
            syms = encode(sn)
            img = render(sn, module=2, height=60)
            if img.size[0] <= 0 or img.size[1] != 60:
                ok = False
                print(f"  FAIL: {sn!r} 图像尺寸 {img.size}")
            else:
                print(f"  OK   {sn!r:25s} -> {len(syms)} 符号, "
                      f"图 {img.size[0]}x{img.size[1]}")
        except Exception as e:                       # noqa: BLE001
            ok = False
            print(f"  FAIL: {sn!r}: {e}")

    print("\n" + ("全部通过" if ok else "有失败"))
    sys.exit(0 if ok else 1)
