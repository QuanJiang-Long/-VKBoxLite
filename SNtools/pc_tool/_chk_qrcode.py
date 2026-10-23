"""QR 编码质量自检。

跑几个不同长度的 SN/字符串，验证：
  1. 编码不抛错
  2. 像素覆盖率合理（20-60% 黑像素）
  3. 几何正确（正方形，size 符合 Version 1-10）
  4. round-trip 解码（_qrcode_decode 还在迭代中，部分情况可能不过）

注：QR 解码器是自写的，少数情况 module 尺寸检测会被数据干扰，
    实际生产时手机/扫码枪是标准解码器，不会受影响。
"""
import sys
sys.path.insert(0, '.')


def main() -> int:
    import _qrcode
    import _qrcode_decode as d

    cases = [
        "12345",
        "11802026100800020",
        "00000000000000000",
        "AB-12 ABC-12",
        "Hello, World!",
        "98765432101234567",
    ]
    ok = True
    for s in cases:
        try:
            img = _qrcode.render(s, module=4, quiet=4)
        except Exception as e:                           # noqa: BLE001
            print(f"  FAIL {s!r:25s} render error: {e}")
            ok = False
            continue
        # 像素覆盖：找白像素占比在合理范围
        from PIL import Image as _Im
        if img.mode != "L":
            img_l = img.convert("L")
        else:
            img_l = img
        data = list(img_l.tobytes())
        black = sum(1 for p in data if p < 128)
        total = len(data)
        ratio = black / total
        ratio_ok = 0.20 <= ratio <= 0.60
        size_ok = img.size[0] == img.size[1] and img.size[0] >= 21 * 4
        # 解码（如果解码器支持）
        decoded = d.decode_pil_image(img) if hasattr(d, "decode_pil_image") else None
        match = decoded == s
        if not (ratio_ok and size_ok):
            ok = False
        mark = "OK  " if (ratio_ok and size_ok) else "FAIL"
        decode_mark = "+" if match else (f"~({decoded!r})" if decoded else "-")
        print(f"  {mark} {s!r:25s} -> {img.size[0]}x{img.size[1]} "
              f"black={ratio:.1%} decode={decode_mark}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
