"""量 ttk 按钮在不同 font/padding 下的真实高度，为"等高"需求选配置。

用法: python _btn_metrics.py
输出: 各配置的自然高度（px），找与普通 TButton 等高（37px 左右）的那一档。
"""

import tkinter as tk
from tkinter import ttk

YH = "Microsoft YaHei UI"


def measure(root, font, padding, text="返修"):
    s = ttk.Style()
    name = f"Probe{abs(hash((font, padding)))}.TButton"
    try:
        s.configure(name, font=font, padding=padding)
    except tk.TclError:
        return None
    b = ttk.Button(root, text=text, style=name)
    b.pack()
    root.update_idletasks()
    h = b.winfo_reqheight()
    b.destroy()
    return h


def main():
    root = tk.Tk()
    root.withdraw()
    try:
        base = measure(root, (YH, 10), 6)
        print(f"  基准 TButton            font=10 pad=6   -> {base}px")
        print()
        print("  试着把 Go.TButton 压到基准高度：")
        cands = [
            ((YH, 10, "bold"), 6, "font=10 bold  pad=6"),
            ((YH, 11, "bold"), 5, "font=11 bold  pad=5"),
            ((YH, 12, "bold"), 4, "font=12 bold  pad=4"),
            ((YH, 12, "bold"), 3, "font=12 bold  pad=3"),
            ((YH, 14, "bold"), 1, "font=14 bold  pad=1"),
            ((YH, 16, "bold"), 0, "font=16 bold  pad=0"),
            ((YH, 16, "bold"), -2, "font=16 bold  pad=-2"),
        ]
        hits = []
        for font, pad, desc in cands:
            h = measure(root, font, pad, text="烧 录 下 一 台")
            mark = ""
            if h is not None and base is not None and abs(h - base) <= 1:
                mark = "   <== 与基准等高"
                hits.append((desc, h))
            print(f"  Go.TButton {desc:<22} -> {h}px{mark}")
        print()
        if hits:
            print(f"  结论: {len(hits)} 组可与普通按钮严格等高（差<=1px），"
                  f"优先采用 {hits[0][0]}")
        else:
            print("  结论: 没有一档能严格等高 -> 走用户给的备选方案："
                  "把返修拉到烧录按钮的高度（fill='y'）")
    finally:
        root.destroy()


if __name__ == "__main__":
    main()
