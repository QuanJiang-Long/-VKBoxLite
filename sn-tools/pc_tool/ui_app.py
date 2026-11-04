"""
主窗口。tkinter 实现，只负责展示与交互，不含业务判断。

布局：
    顶部   串口连接区（请选择串口 + 手动选/刷新）
    上部   设备身份卡
    中部   SN 规则 + 下一号 + 烧录大按钮 + 班产统计
    下部   指令/应答日志
"""

from __future__ import annotations

import os
import queue
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import font as tkfont
from tkinter import messagebox, ttk, filedialog

from PIL import Image, ImageDraw, ImageFont, ImageTk

import config as cfg_mod
from allocator import Allocator, AllocatorError
from burner import Burner, BurnResult
from device import (Device, DeviceError, TimeoutError_, clean_field,
                    find_device_port, reason_cn)
from serial_port import SerialPort, _registry_ports, list_ports
import _barcode

BG = "#f5f6f8"
CARD = "#ffffff"
OK_GREEN = "#1a7f37"
FAIL_RED = "#cf222e"
WARN_ORANGE = "#bf8700"
LINE = "#d8dee4"
FG = "#1f2328"
FG_DIM = "#57606a"
# 苹果风：圆角输入框配色
ENTRY_BG = "#ffffff"
ENTRY_BORDER = "#e5e5ea"     # 苹果浅灰边
ENTRY_FOCUS = "#007aff"      # 苹果蓝
ENTRY_FG = "#1f2328"
ENTRY_FONT = ("Microsoft YaHei UI", 11)
ENTRY_PLACEHOLDER = "#9b9ba1"

WATCHDOG_INTERVAL_MS = 1000      # 多久问一次"设备还在吗"
WATCHDOG_MISS_LIMIT = 1          # 一次发现不在就报告（之前是 2 次 → 4 秒，
                                  # 部分 USB 转串口适配器 ClearCommError 在
                                  # 设备掉电瞬间仍可能成功，连续 2 次检查
                                  # 会让用户等近 4 秒，体感像"软件没识别到"）
PORT_POLL_MS = 1500              # 多久看一次串口插拔（工人不会主动点刷新）


#=====================================================================
# 圆角输入框 —— 用 Canvas 画圆角矩形作背景，再叠一个 tk.Entry 拿输入。
#   ttk.Entry 在 Win 上没办法真圆角（ttk 是 X11 风格主题），自己画一个。
#   API 跟 ttk.Entry 一致：textvariable / width / show / focus / get / set
#=====================================================================
class RoundedEntry(tk.Canvas):
    """Apple 风圆角输入框。"""

    _CHAR_W = 9                       # Consolas 11pt 每字约 9px
    _PAD_X = 12                       # 左右内边距
    _PAD_Y = 9                        # 上下内边距，让 11pt 文字垂直居中
    _RADIUS = 10
    _H = 37                           # 整体 37px 高，与 Combobox / Button 同行等高

    def __init__(self, master, textvariable=None, width: int = 20, show: str = "",
                 font=None, state: str = "normal", **kw):
        # ttk widget 的 master 拿不到 -bg（ttk 不暴露 -bg），用 CARD 兜底
        try:
            self._master_bg = master.cget("bg")
        except (tk.TclError, AttributeError):
            self._master_bg = CARD
        self._char_width = int(width)                # 记下字符宽，cget("width") 仍返回它
        canvas_w = self._char_width * self._CHAR_W + 2 * self._PAD_X
        # canvas 比 polygon 周边各多 1 像素：Tk 的 outline width=1 是居中绘制，
        # 不留余地的话右/下边那 0.5px 落到画布外被裁，看起来"下边框和右边框没有"。
        canvas_pad = 1
        canvas_w_pix = canvas_w + 2 * canvas_pad
        canvas_h_pix = self._H + 2 * canvas_pad
        # show/state 不传给 Canvas（Canvas 没这俩选项），传给内嵌 tk.Entry
        kw.pop("show", None)
        kw.pop("state", None)
        super().__init__(master, width=canvas_w_pix, height=canvas_h_pix,
                         bg=self._master_bg, highlightthickness=0, bd=0, **kw)
        self._radius = self._RADIUS
        self._border_color = ENTRY_BORDER
        self._focus_color = ENTRY_FOCUS
        # 圆角矩形 = 360 段折线模拟 4 段圆弧；起点偏移 canvas_pad，
        # 让 4 段边都完整落在画布内。
        self._rect = self.create_polygon(
            self._rounded_rect_points(canvas_pad, canvas_pad, canvas_w, self._H, self._radius),
            fill=ENTRY_BG, outline=self._border_color, width=1, smooth=True)
        # 内部 tk.Entry 拿焦点
        self._var = textvariable or tk.StringVar()
        self._entry = tk.Entry(
            self, textvariable=self._var, show=show,
            relief="flat", bd=0, highlightthickness=0, bg=ENTRY_BG, fg=ENTRY_FG,
            insertbackground=ENTRY_FOCUS, font=font or ENTRY_FONT)
        self.create_window(canvas_pad + self._PAD_X, canvas_pad + self._PAD_Y,
                           window=self._entry, anchor="nw",
                           width=canvas_w - 2 * self._PAD_X,
                           height=self._H - 2 * self._PAD_Y)
        self._entry.bind("<FocusIn>", lambda e: self._set_focus(True))
        self._entry.bind("<FocusOut>", lambda e: self._set_focus(False))
        if state != "normal":
            self.configure(state=state)

    def configure(self, cnf=None, **kw):  # noqa: A003
        # 拦截 state / show 配置，映射到内部 Entry（Canvas 没这俩选项）
        if cnf == "state" or "state" in kw:
            st = kw.get("state", cnf)
            if st in ("disabled", "readonly"):
                self._entry.configure(state=st)
                self._disable_rect()
            else:
                self._entry.configure(state="normal")
                self._enable_rect()
            return None
        if "show" in kw:
            self._entry.configure(show=kw.pop("show"))
            return None
        if cnf == "show":
            self._entry.configure(show=cnf)
            return None
        return super().configure(cnf, **kw)

    def _disable_rect(self) -> None:
        self.itemconfig(self._rect, fill="#f0f0f3", outline="#e2e2e6")

    def _enable_rect(self) -> None:
        self.itemconfig(self._rect, fill=ENTRY_BG, outline=self._border_color)

    def cget(self, key):  # noqa: D401
        if key == "state":
            return self._entry.cget("state")
        if key == "width":
            return self._char_width                # 字符数，不是像素
        if key == "show":
            return self._entry.cget("show")
        return super().cget(key)

    def _set_focus(self, on: bool) -> None:
        self.itemconfig(self._rect, outline=(self._focus_color if on else self._border_color),
                        width=2 if on else 1)

    def get(self) -> str:
        return self._var.get()

    def set(self, v: str) -> None:
        self._var.set(v)

    def focus_set(self):
        self._entry.focus_set()

    @staticmethod
    def _rounded_rect_points(x: float, y: float, w: float, h: float, r: float):
        import math
        if r > w / 2:
            r = w / 2
        if r > h / 2:
            r = h / 2
        pts = []
        # 左上：180°→270°  (从 9 点钟逆时针到 12 点钟)
        for i in range(91):
            a = math.pi + math.pi * i / 180
            pts.extend([x + r + r * math.cos(a), y + r + r * math.sin(a)])
        # 右上：270°→360°
        for i in range(91):
            a = -math.pi / 2 + math.pi * i / 180
            pts.extend([x + w - r + r * math.cos(a), y + r + r * math.sin(a)])
        # 右下：0°→90°
        for i in range(91):
            a = math.pi * i / 180
            pts.extend([x + w - r + r * math.cos(a), y + h - r + r * math.sin(a)])
        # 左下：90°→180°
        for i in range(91):
            a = math.pi / 2 + math.pi * i / 180
            pts.extend([x + r + r * math.cos(a), y + h - r + r * math.sin(a)])
        return pts


#=====================================================================
# 圆角按钮 —— Canvas 画圆角矩形 + 居中文字 + 点击/hover。
#   颜色风格分 3 种：primary(主蓝) / secondary(灰白) / danger(红)
#   state=disabled 时变灰，不可点。
#=====================================================================
BTN_FONT = ("Microsoft YaHei UI", 11)
BTN_FONT_BOLD = ("Microsoft YaHei UI", 11, "bold")
BTN_BIG_FONT = ("Microsoft YaHei UI", 13, "bold")         # 主操作按钮

BTN_PRIMARY_BG = "#007aff"      # 苹果蓝
BTN_PRIMARY_HOVER = "#0a84ff"
BTN_PRIMARY_PRESS = "#0060df"
BTN_SECONDARY_BG = "#f2f2f7"    # 浅灰
BTN_SECONDARY_HOVER = "#e5e5ea"
BTN_SECONDARY_PRESS = "#d8d8de"
BTN_DANGER_BG = "#ff3b30"
BTN_DANGER_HOVER = "#ff453a"
BTN_TEXT_ON_DARK = "#ffffff"
BTN_TEXT_ON_LIGHT = "#1f2328"
BTN_DISABLED_BG = "#e9e9ee"
BTN_DISABLED_FG = "#9b9ba1"

BTN_RADIUS = 8
BTN_PAD_X = 18
BTN_H = 37                      # Canvas 整体高度，对齐 ttk.Combobox 的 37px
BTN_H_BIG = 49                  # 大号按钮：烧录下一台 / 返修 / 保存 主操作
BTN_PAD_Y = (BTN_H - BTN_FONT[1]) // 2
BTN_PAD_Y_BIG = (BTN_H_BIG - BTN_BIG_FONT[1]) // 2

_kind_bg = {"primary": BTN_PRIMARY_BG, "secondary": BTN_SECONDARY_BG, "danger": BTN_DANGER_BG}
_kind_hover = {"primary": BTN_PRIMARY_HOVER, "secondary": BTN_SECONDARY_HOVER, "danger": BTN_DANGER_HOVER}
_kind_press = {"primary": BTN_PRIMARY_PRESS, "secondary": BTN_SECONDARY_PRESS, "danger": BTN_DANGER_BG}
_kind_text = {"primary": BTN_TEXT_ON_DARK, "secondary": BTN_TEXT_ON_LIGHT, "danger": BTN_TEXT_ON_DARK}


#=====================================================================
# 圆角勾选框 —— Canvas 画方角小方框，勾选时填蓝 + 白色对勾。
#   与 ttk.Checkbutton 用法一致：variable=BooleanVar, text=label
#=====================================================================
CHECK_BOX_SIZE = 18
CHECK_RADIUS = 4
CHECK_BORDER = "#d2d2d7"
CHECK_FILL = BTN_PRIMARY_BG                # 勾选时填苹果蓝
CHECK_FG = "#ffffff"
CHECK_LABEL_FONT = ("Microsoft YaHei UI", 11)
CHECK_PAD = 6                              # 方框与文字间距


class RoundedCheckbutton(tk.Frame):
    """苹果风圆角勾选框：方框 + 文字，绑 BooleanVar。"""

    def __init__(self, master, text: str = "", variable: tk.BooleanVar = None,
                 command=None, **kw):
        try:
            self._master_bg = master.cget("bg")
        except (tk.TclError, AttributeError):
            self._master_bg = CARD
        super().__init__(master, bg=self._master_bg, bd=0, **kw)
        self._text = text
        self._var = variable or tk.BooleanVar()
        self._command = command
        self._canvas = tk.Canvas(self, width=CHECK_BOX_SIZE + 2, height=CHECK_BOX_SIZE + 2,
                                 bg=self._master_bg, highlightthickness=0, bd=0)
        self._canvas.pack(side="left")
        # 起点偏移 1 像素：outline 居中绘制，留出 0.75px 给边框不被裁
        self._box = self._canvas.create_polygon(
            RoundedEntry._rounded_rect_points(
                1, 1, CHECK_BOX_SIZE, CHECK_BOX_SIZE, CHECK_RADIUS),
            fill="#ffffff", outline=CHECK_BORDER, width=1.5, smooth=True)
        # 白色对勾（3 点折线）—— 勾选时再显示
        cx = CHECK_BOX_SIZE / 2
        cy = CHECK_BOX_SIZE / 2
        d = CHECK_BOX_SIZE * 0.18
        self._check = self._canvas.create_line(
            cx - 0.45 * CHECK_BOX_SIZE, cy + 0.05 * CHECK_BOX_SIZE,
            cx - 0.15 * CHECK_BOX_SIZE, cy + 0.30 * CHECK_BOX_SIZE,
            cx + 0.40 * CHECK_BOX_SIZE, cy - 0.30 * CHECK_BOX_SIZE,
            fill=CHECK_FG, width=2.2, capstyle="round", joinstyle="round",
            state="hidden")
        self._label = tk.Label(self, text=text, bg=self._master_bg, fg=FG,
                               font=CHECK_LABEL_FONT, cursor="hand2")
        self._label.pack(side="left", padx=(CHECK_PAD, 0))
        # 事件
        for w in (self, self._canvas, self._label):
            w.bind("<Button-1>", self._on_click)
            w.bind("<Enter>", self._on_enter)
            w.bind("<Leave>", self._on_leave)
        # 跟踪 var 变化（外部代码改 var 也要反映到 UI）
        self._var.trace_add("write", self._on_var_change)
        self._apply_state()

    def _on_click(self, _e=None):
        self._var.set(not self._var.get())
        if callable(self._command):
            self._command()

    def _on_enter(self, _e=None):
        if not self._var.get():
            self._canvas.itemconfig(self._box, outline="#a0a0a5", width=1.5)

    def _on_leave(self, _e=None):
        if not self._var.get():
            self._canvas.itemconfig(self._box, outline=CHECK_BORDER, width=1.5)

    def _on_var_change(self, *_):
        self._apply_state()

    def _apply_state(self):
        if self._var.get():
            self._canvas.itemconfig(self._box, fill=CHECK_FILL, outline=CHECK_FILL, width=1.5)
            self._canvas.itemconfig(self._check, state="normal")
        else:
            self._canvas.itemconfig(self._box, fill="#ffffff", outline=CHECK_BORDER, width=1.5)
            self._canvas.itemconfig(self._check, state="hidden")

    def cget(self, key):  # noqa: D401
        if key == "text":
            return self._text
        if key == "variable":
            return self._var
        return super().cget(key)

    def configure(self, cnf=None, **kw):  # noqa: A003
        if "text" in kw or cnf == "text":
            new_text = kw["text"] if "text" in kw else cnf
            self._text = new_text
            self._label.configure(text=new_text)
            return None
        if "variable" in kw or cnf == "variable":
            new_var = kw["variable"] if "variable" in kw else cnf
            self._var = new_var
            self._var.trace_add("write", self._on_var_change)
            self._apply_state()
            return None
        return super().configure(cnf, **kw)


#=====================================================================
# 圆角下拉框 —— Canvas 画外观（圆角矩形 + 当前文字 + 下拉箭头），
#   点击弹 Toplevel 列表选择。完全替代 ttk.Combobox 的视觉。
#=====================================================================
CB_H = 37
CB_RADIUS = 8
CB_BORDER = "#d2d2d7"
CB_BG = "#ffffff"
CB_HOVER_BORDER = "#a0a0a5"
CB_TEXT_FONT = ("Microsoft YaHei UI", 11)
CB_PAD_X = 10


class RoundedCombobox(tk.Canvas):
    """苹果风圆角下拉框。state=readonly：只选不输。"""

    def __init__(self, master, textvariable: tk.StringVar, values: list = None,
                 width: int = 18, state: str = "readonly", **kw):
        try:
            self._master_bg = master.cget("bg")
        except (tk.TclError, AttributeError):
            self._master_bg = CARD
        self._var = textvariable
        self._values = list(values or [])
        self._state = state
        self._char_width = int(width)
        # 画布尺寸：8 px/字 + 20 内边距 + 18 箭头区
        self._width_px = self._char_width * 8 + 2 * CB_PAD_X + 22
        # 多留 1 像素给 outline，避免右/下边框被裁（与 RoundedEntry 同款）
        super().__init__(master, width=self._width_px + 2, height=CB_H + 2,
                         bg=self._master_bg, highlightthickness=0, bd=0, **kw)
        self._rect = self.create_polygon(
            RoundedEntry._rounded_rect_points(1, 1, self._width_px, CB_H, CB_RADIUS),
            fill=CB_BG, outline=CB_BORDER, width=1, smooth=True)
        self._text_id = self.create_text(CB_PAD_X + 1, CB_H // 2 + 1,
                                         text=self._var.get(), fill=ENTRY_FG,
                                         font=CB_TEXT_FONT, anchor="w")
        # 下拉箭头（▼ 用 3 点折线画一个朝下的箭头）
        ax = self._width_px - 11
        ay = CB_H // 2 + 1
        self._arrow = self.create_polygon(
            [ax - 4, ay - 2, ax + 4, ay - 2, ax, ay + 3],
            fill="#9b9ba1", outline="")
        # 事件
        for ev, fn in (("<Button-1>", self._on_click),
                       ("<Enter>", self._on_enter),
                       ("<Leave>", self._on_leave)):
            self.bind(ev, fn)
        # 跟踪 var
        self._var.trace_add("write", lambda *_: self._refresh_text())

    def _refresh_text(self):
        self.itemconfig(self._text_id, text=self._var.get())

    def _on_click(self, _e=None):
        if self._state == "disabled":
            return
        self._open_dropdown()

    def _on_enter(self, _e=None):
        if self._state != "disabled":
            self.itemconfig(self._rect, outline=CB_HOVER_BORDER, width=1)

    def _on_leave(self, _e=None):
        self.itemconfig(self._rect, outline=CB_BORDER, width=1)

    def _open_dropdown(self):
        """弹一个 Toplevel 列表，选中回填到 self._var。"""
        if not self._values:
            return
        # 弹窗定位：紧贴 combobox 下方
        x = self.winfo_rootx()
        y = self.winfo_rooty() + CB_H
        win = tk.Toplevel(self)
        win.overrideredirect(True)                          # 无标题栏
        wh = min(280, len(self._values) * 32 + 8)
        win.geometry(f"+{x}+{y}")
        # 圆角背景（用 Frame + Canvas 描边）；多 2 像素给 outline 不被裁
        wrap = tk.Canvas(win, width=self._width_px + 2, height=wh + 2,
                         bg=self._master_bg, highlightthickness=0, bd=0)
        wrap.pack()
        wrap.create_polygon(
            RoundedEntry._rounded_rect_points(
                1, 1, self._width_px, wh, CB_RADIUS),
            fill="#ffffff", outline=CB_BORDER, width=1, smooth=True)
        # 用 Frame 装选项（Frame 不能透明，所以 wrap 只画边框，Frame 放内容）
        inner = tk.Frame(win, bg="#ffffff")
        # 把 inner 套到 wrap 的画布里（用 create_window 浮在上面）
        wrap.create_window(1, 1, window=inner, anchor="nw",
                           width=self._width_px,
                           height=wh)
        for i, v in enumerate(self._values):
            lbl = tk.Label(inner, text=v, bg="#ffffff", fg=ENTRY_FG,
                           font=CB_TEXT_FONT, anchor="w", padx=CB_PAD_X,
                           width=self._char_width)
            lbl.pack(fill="x", pady=2)
            lbl.bind("<Enter>", lambda e, w=lbl: w.configure(bg="#e8e8ed"))
            lbl.bind("<Leave>", lambda e, w=lbl: w.configure(bg="#ffffff"))
            lbl.bind("<Button-1>",
                     lambda e, val=v, w=win: self._pick(val, w))
        # 点外面关闭
        win.bind("<FocusOut>", lambda e: win.after(50, win.destroy))
        win.focus_set()
        win.grab_set()                                      # 模态

    def _pick(self, value: str, win: tk.Toplevel):
        self._var.set(value)
        win.destroy()

    def configure(self, cnf=None, **kw):  # noqa: A003
        if "values" in kw or cnf == "values":
            self._values = list(kw["values"] if "values" in kw else cnf)
            return None
        if "state" in kw or cnf == "state":
            self._state = kw["state"] if "state" in kw else cnf
            return None
        return super().configure(cnf, **kw)

    def __setitem__(self, key, value):  # 支持 port_cb['values'] = [...] 写法
        if key == "values":
            self._values = list(value)
            return
        if key == "state":
            self._state = value
            return
        super().configure(**{key: value})

    def __getitem__(self, key):
        return self.cget(key)

    def cget(self, key):  # noqa: D401
        if key == "values":
            return self._values
        if key == "state":
            return self._state
        return super().cget(key)


class RoundedButton(tk.Canvas):
    """Apple 风圆角按钮。

    kind: primary（蓝） / secondary（灰白） / danger（红）
    big:  True 用大号字体 + 高 4px（烧录主按钮那种）
    """

    def __init__(self, master, text: str = "", command=None,
                 kind: str = "secondary", big: bool = False,
                 font=None, state: str = "normal", width: int = 0, **kw):
        try:
            self._master_bg = master.cget("bg")
        except (tk.TclError, AttributeError):
            self._master_bg = CARD
        self._text = text
        self._command = command
        self._kind = kind if kind in _kind_bg else "secondary"
        self._state = state
        self._big = big
        self._font = font or (BTN_BIG_FONT if big else BTN_FONT)
        # 算尺寸：text 宽 + 左右 pad，若指定 width 则按它（字符数）展宽
        self._tkfont_obj = tkfont.Font(family=self._font[0], size=self._font[1],
                                       weight=self._font[2] if len(self._font) > 2 else "normal")
        text_w = self._tkfont_obj.measure(text or " ") if text else 40
        h = BTN_H_BIG if big else BTN_H
        if width > 0:
            # 按字符数补宽（中文字符按 2 计算近似）
            char_w = int(self._tkfont_obj.measure("中") * 0.95)
            need_w = width * char_w
            text_w = max(text_w, need_w)
        self._width = text_w + 2 * BTN_PAD_X
        self._height = h
        # 多留 1 像素给圆角边缘不被画布边界裁切（无 outline 的按钮也保留这 1px 余量，
        # 右/下角的圆角看起来才完整；参见 RoundedEntry 的注释）
        self._pad = 1
        super().__init__(master, width=self._width + 2 * self._pad,
                         height=self._height + 2 * self._pad,
                         bg=self._master_bg, highlightthickness=0, bd=0, **kw)
        self._rect = self.create_polygon(
            RoundedEntry._rounded_rect_points(
                self._pad, self._pad, int(self._width), int(self._height),
                int(BTN_RADIUS)),
            fill=_kind_bg[self._kind], outline="", width=0, smooth=True)
        self._text_id = self.create_text(self._width // 2 + self._pad,
                                         self._height // 2 + self._pad, text=text,
                                         fill=_kind_text[self._kind], font=self._font)
        # 创建完立即同步 state 视觉：state="disabled" 时不能还是 primary 蓝，
        # 必须用 BTN_DISABLED_BG/FG 灰显。否则【烧写SN】(kind=primary,
        # state="disabled" 启动默认) 第一次画出来是蓝底白字 ——
        # 看着像可点，但点了没反应，让工人迷惑。
        self._apply_state()
        # 让 polygon 跟随 widget 实际大小变化：填满 pack(fill="x", expand=True)
        # 撑开的所有空间，否则按钮看起来只占左/右 1/5 宽。
        # 注意：bind <Configure> 会回调多次（每次 winfo_width 变化），用
        # _redraw_to_size 重画 polygon + 文字到新尺寸。
        self.bind("<Configure>", self._on_configure)
        # 事件
        for ev, h_fn in (("<Enter>", self._on_enter), ("<Leave>", self._on_leave),
                         ("<Button-1>", self._on_press),
                         ("<ButtonRelease-1>", self._on_release)):
            self.bind(ev, h_fn)

    def _on_configure(self, event):
        """widget 大小变化（pack(fill="x", expand=True) 拉伸）时重画 polygon 和文字。
        跟之前 self._width 是固定自然宽度不同：现在让按钮跟随 btns 的可用宽度走，
        这样【烧录SN】【返修】能真正各占一行 1:1。
        """
        # 只响应自己的 Configure，不响应子 widget 的
        if event.widget is not self:
            return
        w = event.width - 2 * self._pad
        h = event.height - 2 * self._pad
        if w <= 0 or h <= 0:
            return
        self.coords(self._rect, *RoundedEntry._rounded_rect_points(
            self._pad, self._pad, w, h, int(BTN_RADIUS)))
        self.coords(self._text_id, w // 2 + self._pad, h // 2 + self._pad)

    def _on_enter(self, _e):
        if self._state != "normal":
            return
        self.itemconfig(self._rect, fill=_kind_hover[self._kind])

    def _on_leave(self, _e):
        if self._state != "normal":
            return
        self.itemconfig(self._rect, fill=_kind_bg[self._kind])

    def _on_press(self, _e):
        if self._state != "normal":
            return
        self.itemconfig(self._rect, fill=_kind_press[self._kind])

    def _on_release(self, _e):
        if self._state != "normal":
            return
        self.itemconfig(self._rect, fill=_kind_hover[self._kind])
        if callable(self._command):
            self._command()

    def _apply_state(self):
        if self._state == "disabled":
            self.itemconfig(self._rect, fill=BTN_DISABLED_BG)
            self.itemconfig(self._text_id, fill=BTN_DISABLED_FG)
        else:
            self.itemconfig(self._rect, fill=_kind_bg[self._kind])
            self.itemconfig(self._text_id, fill=_kind_text[self._kind])

    def configure(self, cnf=None, **kw):  # noqa: A003
        # 一次性处理多个 key（一次调用常带 text + state 两项）
        text = kw.pop("text", None) if cnf is None else (
            cnf if cnf == "text" else None)
        cmd = kw.pop("command", None) if cnf is None else (
            cnf if cnf == "command" else None)
        state = kw.pop("state", None) if cnf is None else (
            cnf if cnf == "state" else None)
        if text is not None:
            self._text = text
            self.itemconfig(self._text_id, text=text)
        if cmd is not None:
            self._command = cmd
        if state is not None:
            self._state = state
            self._apply_state()
        # 其它 key（如 width/height）回给 Canvas
        if kw or (cnf is not None and cnf not in ("text", "command", "state")):
            return super().configure(cnf, **kw) if kw else super().configure(cnf)
        return None

    def cget(self, key):  # noqa: D401
        if key == "state":
            return self._state
        if key == "text":
            return self._text
        if key == "command":
            # ttk.Button.cget("command") 返回 Tcl 命令名字符串（如
            # "123456789_on_mqtt_write"）。RoundedButton 没走 Tcl 层，
            # 这里把 bound method 名字也拼成 "_on_xxx" 形式让测试能识别。
            cmd = self._command
            if cmd is None:
                return ""
            if hasattr(cmd, "__name__"):
                return f"roundedbtn{cmd.__name__}"
            return str(cmd)
        return super().cget(key)

    def invoke(self):
        if self._state == "normal" and callable(self._command):
            self._command()


class SnBurnerApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.cfg = cfg_mod.load_config()
        self.port: SerialPort | None = None
        self.device: Device | None = None
        self.burner: Burner | None = None
        self.alloc: Allocator | None = None
        self.busy = False
        self.log_q: queue.Queue = queue.Queue()
        self.result_q: queue.Queue = queue.Queue()
        self.session = {"ok": 0, "fail": 0}
        self.fail_streak = 0
        self._miss_count = 0
        self.last_info = None            # 最近一次探测到的设备信息
        self.recover_sn = ""             # 查询查到的该设备已绑定 SN
        # 弹窗图标的 PhotoImage 缓存：PhotoImage 被 GC 掉图标会静默退回
        # Tk 默认的羽毛，挂在 self 上随窗口一起活着。
        self._dialog_icon_imgs: dict = {}

        root.title("SN 烧录工装")
        # 默认尺寸按"一屏能看全主要操作"给：串口/查询/身份/烧录都露出来，
        # 日志区需要时才滚动。内容超高也不再被裁掉（外层是 Canvas 滚动）。
        sw = root.winfo_screenwidth()
        sh = root.winfo_screenheight()
        w = min(1000, max(860, int(sw * 0.62)))
        h = min(900, max(760, int(sh * 0.86)))
        root.geometry(f"{w}x{h}")
        root.minsize(820, 700)
        root.configure(bg=BG)
        self._set_window_icon(root)

        self._build_styles()
        self._build_ui()
        self._init_allocator()
        self._update_connection_btns()
        # 启动时把"设备依赖按钮"全部按 device=None 状态初始化 —— 防止
        # _build_ui 里 RoundedButton 默认 state=normal 的【烧写】等按钮
        # 在刚启动的窗口里短暂可点。_update_connection_btns 处理
        # query_self/rework/mqtt_*，剩下的 recover_btn / lock_btn 在这
        # 两个函数里各自刷一次。
        self._update_recover_visibility()
        self._update_lock_btn()
        self._drain_log()
        self._drain_result()
        self._watchdog()
        self._start_port_watch()

        root.protocol("WM_DELETE_WINDOW", self._on_close)

    #=================================================================
    # 窗口图标
    #=================================================================
    def _set_window_icon(self, root: tk.Tk) -> None:
        """把标题栏小图标和任务栏图标设成 Lcon.png，与 exe 文件图标一致。

        为什么需要这一步：exe 那个图标是 PyInstaller --icon 写进 PE 资源
        的，只管资源管理器里【文件】长什么样。运行中的窗口图标归 tkinter
        管 —— 不显式设置的话，标题栏和任务栏都是 Tk 默认的那根羽毛，
        用户看到的就是"文件是一个图标、跑起来是另一个"。

        图标从哪来：优先用内嵌的 base64（_icon_data.py），其次找磁盘上
        的文件。⚠️ 为什么优先内嵌而不是 --add-data / sys._MEIPASS：
            --onefile 启动要把数据文件解压到 %TEMP%\\_MEIxxxxxx，实测本环境
            报 "Failed to extract Lcon.png: Permission denied" —— 而且连
            VCRUNTIME140.dll 都解不出来，说明是 Temp 不可写而非参数写错。
            产线机器多数没问题，但"工装能否启动"不该取决于 Temp 可不可写
            （某些加固产线/组策略会限制 Temp）。内嵌后零文件依赖。
            顺带一个好处：改了 Lcon.png 只需重跑 _make_icon_data.py，
            不用重新 --add-data。

        两条渲染路，按可用性挑：
          1) iconbitmap(app.ico)   Windows 原生，能吃下 ico 里那 10 档
                                   尺寸，标题栏/任务栏/Alt+Tab 各自挑
                                   最合适的，效果最好
          2) iconphoto(True, png)  兜底。Tk 8.6 的 PhotoImage 直接读 PNG，
                                   不需要 Pillow（Pillow 只被 _make_icon.py
                                   用，且已 --exclude-module 排除，打进 exe
                                   后运行时没有它，这点必须注意）

        ⚠️ 两条路都必须带 "-default"：
            wm iconbitmap  /  wm iconphoto  不加 -default 时【只作用于那一个
            窗口】，之后新建的 Toplevel（条形码窗 / 返修窗 / 返修密码窗…）
            一律退回 Tk 默认的那根羽毛 —— 主窗口有图标、弹窗没有，就是
            这个原因。加了 -default 才是"新建的 toplevel 也用这个图标"。
        ⚠️ iconphoto(True, ...) 里的 True 就是 -default，两条路是对称的。

        任何一步失败都不算错误：图标是装饰，不能因为它起不来就让工装
        开不了机。全部落空就保持 Tk 默认图标，静默继续。
        """
        import base64
        import os

        # ---- 拿 PNG 字节：内嵌优先，磁盘兜底 ----
        png_bytes = None
        try:
            import _icon_data
            b64 = _icon_data.ICON_B64.replace("\n", "").replace(" ", "")
            png_bytes = base64.b64decode(b64)
            # 自检：字节数对不上说明内嵌数据被截断了，宁可不显示也别显示半个图
            if len(png_bytes) != _icon_data.ICON_BYTES:
                png_bytes = None
        except Exception:                          # noqa: BLE001
            png_bytes = None

        if png_bytes is None:
            for p in self._icon_candidates("Lcon.png"):
                try:
                    with open(p, "rb") as f:
                        png_bytes = f.read()
                    break
                except OSError:
                    continue

        # ---- 拿 ICO 字节：磁盘才有（ico 只用于 iconbitmap 的原生路径）----
        ico_path = next((p for p in self._icon_candidates("app.ico")), None)

        # ---- 路 1：iconbitmap（Windows 原生，需要磁盘上的 .ico）----
        # 只有磁盘上有 app.ico 时才能走这条路（未打包直接跑时有；
        # 打包后没有 —— 那时走路 2，效果等价）。
        # ⚠️ 一定要带 -default：不带就只管 root 这一个窗口，
        #    之后 build 出来的 Toplevel 全部退回 Tk 默认的羽毛。
        try:
            if ico_path:
                root.tk.call("wm", "iconbitmap", root._w, "-default", ico_path)
                return
        except tk.TclError:
            pass                              # 换路 2，不放弃

        # ---- 路 2：iconphoto，PhotoImage 支持 data=（无需临时文件）----
        if png_bytes:
            try:
                img = tk.PhotoImage(master=root, data=png_bytes)
                # iconphoto(True, ...) 对【所有】 toplevel 生效，
                # 任务栏按钮用的是这个，不是标题栏那个。
                # ⚠️ img 必须被长期持有：PhotoImage 被 GC 掉的话
                #    tkinter 会立刻把图标退回默认羽毛，且不报错。
                #    挂在 self 上，随窗口一起活着。
                self._icon_img = img
                root.iconphoto(True, img)
            except (tk.TclError, OSError):
                pass                          # 图标是装饰，不影响启动

    @staticmethod
    def _icon_candidates(name: str) -> list:
        """图标文件可能的落点，按优先级排。"""
        import os
        import sys

        cands = []
        mei = getattr(sys, "_MEIPASS", None)
        if mei:
            cands.append(os.path.join(mei, name))
        here = os.path.dirname(os.path.abspath(__file__))
        cands.append(os.path.join(here, name))
        cands.append(os.path.join(os.path.dirname(here), name))
        return [p for p in cands if os.path.exists(p)]

    #=================================================================
    # 弹窗左上角的小图标
    #=================================================================
    def _dialog_icon(self, win, ico_name: str) -> bool:
        """给弹窗设置左上角小图标；成功返回 True。

        踩过的坑（别再改回去）：
            1. 以前这里写死了绝对路径 D:/VKBox_Lite/VKBoxLite_sn/xxx.png。
               仓库一换目录那个路径就没了，ico_path.exists() 为 False，
               iconphoto 从来没被调用过 —— 弹窗左上角只剩 Tk 默认的羽毛。
               现在改成：内嵌 base64 优先，磁盘候选兜底，跟仓库位置无关。
            2. 打包后 exe 旁边没有这些 png（--onefile 不带数据文件，
               而且本环境 Temp 不可写），所以必须内嵌，不能靠磁盘。
            3. 用 iconphoto(False, ...) 只改这一个窗口，正好符合"每个弹窗
               配自己的图标"；不改的话会跟 root 的 -default 图标打架。
            4. PhotoImage 必须被长期持有，挂到 self 上。
            5. 内嵌优先于磁盘，是为了"开发时看到的 == 打包后 exe 里显示的"。
               代价是改了仓库根的 png 后要重跑 _make_dialog_icon_data.py；
               忘了跑不要紧 —— _st_winicon.py 会把内嵌数据和磁盘原图逐字节
               对比，对不上直接 FAIL，不会悄悄显示旧图标。
        """
        import base64

        png_bytes = None

        # ---- 路 1：内嵌 base64（打包后唯一可靠来源）----
        try:
            import _dialog_icon_data
            entry = _dialog_icon_data.ICONS.get(ico_name)
            if entry:
                nbytes, b64 = entry
                raw = base64.b64decode(b64)
                # 字节数对不上说明内嵌数据被截断了，宁可不显示也别显示半个图
                if len(raw) == nbytes:
                    png_bytes = raw
        except Exception:                          # noqa: BLE001
            png_bytes = None

        # ---- 路 2：磁盘兜底（内嵌模块缺失/损坏时用）----
        if png_bytes is None:
            for p in self._icon_candidates(ico_name):
                try:
                    with open(p, "rb") as f:
                        png_bytes = f.read()
                    break
                except OSError:
                    continue

        if not png_bytes:
            return False

        try:
            img = tk.PhotoImage(master=win, data=png_bytes)
            self._dialog_icon_imgs[ico_name] = img       # 防 GC
            win.iconphoto(False, img)
            return True
        except (tk.TclError, OSError):
            return False                                # 图标是装饰，不影响功能

    #=================================================================
    # 构建界面
    #=================================================================
    def _build_styles(self) -> None:
        self.s = ttk.Style()
        try:
            self.s.theme_use("clam")
        except tk.TclError:
            pass
        self.s.configure("TFrame", background=BG)
        self.s.configure("Card.TFrame", background=CARD, relief="flat")
        # 一级字体（卡片标题）：13 bold，比 11pt 大一档但不喧宾夺主
        # 二级字体（普通文字）：11pt，比 10pt 大一档更易读
        # 三级字体（dim 标签/副标题）：10pt，比 9pt 略大
        self.s.configure("TLabel", background=BG, foreground=FG,
                         font=("Microsoft YaHei UI", 11))
        self.s.configure("Card.TLabel", background=CARD, foreground=FG)
        self.s.configure("Dim.TLabel", background=CARD, foreground=FG_DIM,
                         font=("Microsoft YaHei UI", 10))
        self.s.configure("Title.TLabel", background=CARD, foreground=FG,
                         font=("Microsoft YaHei UI", 13, "bold"))
        # Big.TLabel：20pt bold，用于 SN 预览和烧录后反馈，等同 result_lbl 字号
        # anchor="center" 让文字在 Label 内居中（ttk 默认 w=左对齐，pack(fill="x")
        # 只让 Label 占满宽度，不会自动让文字居中 —— 必须 anchor）
        self.s.configure("Big.TLabel", background=CARD, foreground=FG,
                         font=("Consolas", 20, "bold"), anchor="center")
        self.s.configure("TButton", font=("Microsoft YaHei UI", 11), padding=6)
        # Combobox 内部 padding 默认 1px，比按钮矮几像素。同高度才好并排。
        self.s.configure("TCombobox", padding=8)
        # Go.TButton：之前是烧录下一台专用样式，现在已改用 RoundedButton big=True
        self.s.configure("Go.TButton",
                         font=("Microsoft YaHei UI", 13, "bold"), padding=6)
        self.s.configure("TLabelframe", background=BG, foreground=FG_DIM)
        self.s.configure("TLabelframe.Label", background=BG, foreground=FG_DIM,
                         font=("Microsoft YaHei UI", 10))

    def _card(self, parent, padx=14, pady=10) -> ttk.Frame:
        f = ttk.Frame(parent, style="Card.TFrame", padding=padx)
        f.pack(fill="x", padx=12, pady=(0, 10))
        return f

    def _even_gap(self, parent) -> ttk.Frame:
        """在 parent 里插入一个"可横向膨胀"的空白间隔，用于均匀分布控件。

        原理：tkinter 把父容器多出来的宽度按权重平分给所有 expand 的
        子控件。这里每个间隔都 fill="x" + expand=True（权重默认 1），
        所以插入 N 个间隔 = 把剩余宽度 N 等分，组间距自然相等。
        不设最小宽度，窄窗口下间隔缩到 0 也不会挤坏控件。
        """
        f = ttk.Frame(parent, style="Card.TFrame")
        f.pack(side="left", fill="x", expand=True)
        return f

    def _build_ui(self) -> None:
        # ================= 可滚动容器 =================
        # 问题：卡片总高超过窗口高度时，下面的内容（日志、导出按钮）被直接裁掉，
        #       且原先没有任何滚动条，用户根本无法看到 —— 小屏幕/低分辨率上必现。
        # 方案：整页套一层 Canvas + 滚动条。所有卡片都放进 inner  frame，
        #       由 canvas 统一滚动；单个卡片仍用 fill="x" 只随宽度变化。
        # 注意：tkinter 里 MouseWheel 要绑到具体控件上才会触发，所以这里
        #       用 bind_all 全局绑定，滚动时按当前是否悬停在本页面上决定吃不吃事件。
        outer = ttk.Frame(self.root)
        outer.pack(fill="both", expand=True)

        self.canvas = tk.Canvas(outer, bg=BG, highlightthickness=0, bd=0)
        vsb = ttk.Scrollbar(outer, orient="vertical", command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=vsb.set)
        vsb.pack(side="right", fill="y")
        self.canvas.pack(side="left", fill="both", expand=True)

        top = ttk.Frame(self.canvas)
        # anchor="nw"：内容变矮时贴顶，不会留一条空白在中间
        self._win_id = self.canvas.create_window((0, 0), window=top, anchor="nw")

        def _on_frame_configure(_e):
            # 内容高度变化 -> 更新滚动范围
            self.canvas.configure(scrollregion=self.canvas.bbox("all"))

        def _on_canvas_configure(e):
            # 画布宽度变化 -> 让 inner frame 跟着撑满，否则卡片右边会缺一块
            self.canvas.itemconfigure(self._win_id, width=e.width)

        top.bind("<Configure>", _on_frame_configure)
        self.canvas.bind("<Configure>", _on_canvas_configure)

        def _on_wheel(e):
            # 只在内容真的超高时才吃事件，避免挡住别的控件的默认行为
            bbox = self.canvas.bbox("all")
            if not bbox:
                return
            if bbox[3] - bbox[1] <= self.canvas.winfo_height():
                return
            self.canvas.yview_scroll(int(-e.delta / 120), "units")

        self.canvas.bind("<Enter>", lambda e: self.canvas.focus_set())
        self.canvas.bind_all("<MouseWheel>", _on_wheel)

        # ---------------- 串口连接 ----------------
        c = self._card(top)
        ttk.Label(c, text="串口", style="Title.TLabel").pack(anchor="w")

        row = ttk.Frame(c, style="Card.TFrame")
        row.pack(fill="x", pady=(8, 0))

        ttk.Label(row, text="端口", style="Dim.TLabel").pack(side="left")
        self.port_var = tk.StringVar(value=self.cfg.port or "请选择串口")
        self.port_cb = RoundedCombobox(row, textvariable=self.port_var,
                                       width=18, state="readonly")
        self.port_cb.pack(side="left", padx=(6, 10))
        self._refresh_ports()

        RoundedButton(row, text="刷新", command=self._refresh_ports,
                      kind="secondary", width=6).pack(side="left", padx=(0, 6))
        # 合并为一个 toggle 按钮：未连显示"连接设备"，已连显示"断开"。
        # busy 期间显示"正在识别…"并禁用，避免重入。
        self.conn_btn = RoundedButton(row, command=self._toggle_connection,
                                      kind="primary", width=6)
        self.conn_btn.pack(side="left")

        self.status_dot = tk.Label(row, text="●", fg=FG_DIM, bg=CARD,
                                   font=("Microsoft YaHei UI", 14))
        self.status_dot.pack(side="left", padx=(12, 4))
        self.status_lbl = ttk.Label(row, text="未连接", style="Dim.TLabel")
        self.status_lbl.pack(side="left")

        # 工号放在顶栏：开界面第一眼就看到，不会忘填；烧录/补烧/返修
        # 都从这里取同一个值。固定 10 字符宽，operator 写到台账里就是它。
        self.operator_var = tk.StringVar(value=self.cfg.operator)
        self.operator_entry = RoundedEntry(row, textvariable=self.operator_var,
                                        width=10)
        self.operator_entry.pack(side="right")
        ttk.Label(row, text="工号", style="Dim.TLabel").pack(
            side="right", padx=(0, 6))

        # ---------------- 设备身份 ----------------
        # 排在 SN 查询上方：先让工人看到"这台设备现在是什么状态"
        # （IMEI / UID / 当前 SN / 状态 / 烧录锁），再决定去查还是去烧。
        c = self._card(top)
        head = ttk.Frame(c, style="Card.TFrame")
        head.pack(fill="x")
        ttk.Label(head, text="设备身份", style="Title.TLabel").pack(side="left")
        # 手动上锁按钮：补"自动上锁失败"或"故意不自动上锁"造成的"有 SN 但未锁"缺口。
        # 启用：已连 + 设备有 SN + 未在烧录中 + 未上锁。
        #   已锁就禁用 —— 没活儿干就别让点（状态不对时想重锁走断电重插）。
        #   放在标题行右侧，与烧录卡片的"烧录后自动上锁"风格对齐。
        # 不写台账：单纯补锁不改 SN，台账是给 SN 事件用的；只在日志留一条
        #   含工号的痕迹，事后能查"谁在什么时候补过锁"。
        # 不加密码：锁本身幂等无害，误锁走返修就能解。
        self.lock_btn = RoundedButton(head, text="手动上锁", command=self._lock_only,
                                      kind="secondary", width=6)
        # 不在这里 pack：_update_lock_btn 会按"是否需要上锁"决定 pack / pack_forget
        self._update_lock_btn()

        # 内容区：左侧字段 grid + 右侧【条形码】【二维码】按钮（同一行，不另起行）
        content = ttk.Frame(c, style="Card.TFrame")
        content.pack(fill="x", pady=(8, 0))

        grid = ttk.Frame(content, style="Card.TFrame")
        grid.pack(side="left", fill="x", expand=True)
        self.fields = {}
        labels = [("imei", "IMEI"), ("uid", "芯片 UID"), ("sn", "当前 SN"),
                  ("state", "状态"), ("lock", "烧录锁")]
        for i, (key, text) in enumerate(labels):
            # 列间距 16：约等于 2 个 Tab（Tab≈4 字）。之前 8 太挤，标签
            # 和值几乎贴在一起，长 IMEI/SN 串看着像连写。
            ttk.Label(grid, text=text, style="Dim.TLabel").grid(
                row=i // 3, column=(i % 3) * 2, sticky="w",
                padx=(0, 16), pady=3)
            var = tk.StringVar(value="—")
            self.fields[key] = var
            ttk.Label(grid, textvariable=var, style="Card.TLabel",
                      font=("Consolas", 10)).grid(
                row=i // 3, column=(i % 3) * 2 + 1, sticky="w", pady=3)

        # 右侧【条形码】【二维码】：跟在字段后面，与 grid 同行不换行。
        barcodes = ttk.Frame(content, style="Card.TFrame")
        barcodes.pack(side="right", padx=(16, 0))
        RoundedButton(barcodes, text="条形码",
                      command=lambda: self._open_barcode_popup("1D"),
                      kind="secondary", width=6).pack(side="top", pady=(0, 4))
        RoundedButton(barcodes, text="二维码",
                      command=lambda: self._open_barcode_popup("QR"),
                      kind="secondary", width=6).pack(side="top")

        # ---------------- SN 查询 ----------------
        # 排在设备身份下方：来料/售后拿来一台设备，先看它的身份，
        # 再查它有没有烧过号，然后决定走正常烧录还是返修。
        # 不依赖当前串口连接。
        c = self._card(top)
        head = ttk.Frame(c, style="Card.TFrame")
        head.pack(fill="x")
        ttk.Label(head, text="SN 查询", style="Title.TLabel").pack(side="left")
        ttk.Label(head, text="按 IMEI 或芯片 UID 查是否已绑定", style="Dim.TLabel").pack(
            side="left", padx=(8, 0))

        qrow = ttk.Frame(c, style="Card.TFrame")
        qrow.pack(fill="x", pady=(8, 0))
        self.query_var = tk.StringVar()
        # 输入框 fill="x" expand=True 占满中间区域，按钮 side="right" 靠右对齐。
        # 输入框"到按钮处停"——输入框右边缘紧贴【查本机】，输入多长就多长。
        self.query_entry = RoundedEntry(qrow, textvariable=self.query_var,
                                     font=("Consolas", 11))
        self.query_entry.pack(side="left", fill="x", expand=True)
        self.query_entry.bind("<Return>", lambda e: self._do_query())
        # 【查本机】【查询】靠右，宽度都 width=6 跟其他普通按钮同宽。
        # 顺序：先 pack 后查本机 = 显示顺序 [查本机][查询]（side="right" 反向）
        self.query_btn = RoundedButton(qrow, text="查询", command=self._do_query,
                                       kind="primary", width=6)
        self.query_btn.pack(side="right")
        self.query_self_btn = RoundedButton(qrow, text="查本机",
                                           command=self._fill_query_from_device,
                                           kind="secondary", width=6)
        self.query_self_btn.pack(side="right", padx=(0, 8))

        # --- 补烧入口：查到已绑定的 SN 且设备当前没有 SN 时才出现 ---
        # 场景：重刷固件把 FSKV 擦了，SN 丢了，但台账记着这台原来烧的号。
        # 这时要把【旧号】补烧回去，不分配新号（否则一台设备两个号）。
        self.recover_sn = ""
        self.recover_row = ttk.Frame(c, style="Card.TFrame")
        # ⚠️ 必须用 tk.Label 而不是 ttk.Label：ttk 没有 -fg 选项，颜色要
        #    走 Style，运行时 configure(fg=...) 会直接 TclError。
        self.recover_lbl = tk.Label(self.recover_row, text="", bg=CARD, fg=FG,
                                    anchor="w", justify="left", wraplength=600,
                                    font=("Microsoft YaHei UI", 9))
        self.recover_lbl.pack(side="left", fill="x", expand=True)
        self.recover_btn = RoundedButton(self.recover_row, text="烧写",
                                         command=self._recover_burn, kind="primary",
                                         width=6)
        self.recover_btn.pack(side="right", padx=(8, 0))
        # 默认不显示，条件满足时才 pack（用 before= 保证紧跟查询行下方）
        self.recover_row.pack_forget()

        self.query_result = tk.Label(c, text="", bg=CARD, fg=FG, anchor="w",
                                     justify="left", wraplength=760,
                                     font=("Consolas", 10))
        self.query_result.pack(fill="x", pady=(8, 0))

        # ---------------- 烧录操作 ----------------
        c = self._card(top)
        head = ttk.Frame(c, style="Card.TFrame")
        head.pack(fill="x")
        ttk.Label(head, text="烧录", style="Title.TLabel").pack(side="left")

        self.auto_lock_var = tk.BooleanVar(value=self.cfg.auto_lock)
        # 切换勾选 → 同步 burner.auto_lock（连接时读过的快照） + cfg.auto_lock
        # （落盘到 config.json，下次连接也用上）。burner 创建后如果一直不重连，
        # 这里不更新就会按旧的勾烧，正是这个 bug 导致"不勾却自动上锁"。
        RoundedCheckbutton(head, text="烧录后自动上锁",
                           variable=self.auto_lock_var,
                           command=self._on_auto_lock_toggle).pack(side="right")

        body = ttk.Frame(c, style="Card.TFrame")
        body.pack(fill="x", pady=(10, 0))

        rule = self.cfg.rule
        ttk.Label(body, text=f"规则: {rule.prefix} + YYMMDD + "
                             f"{rule.serial_digits} 位流水 + 校验位",
                  style="Dim.TLabel").pack(anchor="w")

        # --- SN 预览 ---
        # 居中，字号与【烧录后提示】（result_lbl，20pt bold）一致——
        # 工人扫一眼就知道"下一个号就是这个"，跟烧完后的反馈视觉权重对等。
        # 日期/流水号手动覆盖 + 【生成SN】已挪到【返修】弹窗（见 _ask_password）：
        #   主流程（烧录下一台）= 全自动按当天日期发号，不让工人手动改；
        #   返修 / 补号才需要手动指定，所以放弹窗里"按需弹"。
        self.next_var = tk.StringVar(value="SN：—")
        self.next_hint_var = tk.StringVar(value="")
        # 控件本体还是要在主界面先建好（_ask_rework 里直接复用），
        # 否则返修弹窗里显示不出来。
        self.date_var = tk.StringVar()
        self.serial_var = tk.StringVar()
        # 主界面的 SN：XX 标签：水平居中、20pt bold（与 result_lbl 同号）
        # pack(anchor="center") 让 Label 控件本身在 body 居中（按文字自然宽度），
        # Big.TLabel 的 anchor="center" 让文字在 Label 内居中 —— 两层居中叠加
        # 看起来"SN：XX" 居中于卡片正中，比 pack(fill="x") 居中更紧凑醒目。
        ttk.Label(body, textvariable=self.next_var,
                  style="Big.TLabel").pack(anchor="center", pady=(6, 4))
        # 流水号按天归零的说明。工人需要知道"今天的第 N 台"是什么意思，
        # 否则看到第二天又从 0001 开始会以为号发重了。
        ttk.Label(body, textvariable=self.next_hint_var,
                  style="Dim.TLabel").pack(anchor="center", pady=(0, 6))

        btns = ttk.Frame(body, style="Card.TFrame")
        btns.pack(fill="x", pady=(6, 0))
        # 烧写SN：主操作键 + 大字号 + 苹果蓝。
        # 高度刻意与返修保持一致（用 big=True），不靠 fill 拉伸。
        # 两个按钮 1:1 各占一半：都 fill="x" expand=True，btns 自身 fill="x"
        # 占满 body 宽度，按钮对半分。
        self.burn_btn = RoundedButton(btns, text="烧写SN", big=True,
                                      kind="primary", command=self._burn,
                                      state="disabled")
        self.burn_btn.pack(side="left", fill="x", expand=True)

        # 返修：次要操作，灰白底，同样 big=True 跟烧录等高。
        self.rework_btn = RoundedButton(btns, text="返修", big=True,
                                        kind="secondary", command=self._rework)
        self.rework_btn.pack(side="left", fill="x", expand=True, padx=(10, 0))

        # ---------------- MQTT 接入信息（可选，留空不影响 SN 烧录） ----------------
        # 独立成一张卡片，与【烧录】彻底分开。
        #   原来这段挤在烧录卡片里面，工人会以为"不填 MQTT 就烧不了号"，
        #   而且烧录卡片被撑得很高，SN 预览和按钮被推到屏幕外。
        #   拆开后：烧录卡片只剩烧录相关，MQTT 自己一张卡，视觉上也分层。
        # 参照 VKBoxLite_sniff 前端"首页"的 MQTT 服务器面板，取其中三项：
        #   服务器地址 / 端口 / MQTT 凭证密码
        # ✅ 现在【保存】是"写设备 + 存本地"双动作：通过 W:MQTT 把三项
        #    写进设备，同时落一份到本地 config.json 供下次回填。
        #    设备侧协议见 device.Device.write_mqtt（VKBoxLite_sniff 的
        #    lua/svc/cmd.lua + lua/iot/mqttcfg.lua）：
        #        W:MQTT={"host":"..","port":1883,"auto_pass":".."}
        #    用户名不用填：设备侧自动档固定用设备 SN 当用户名。
        # ⚠️ 设备侧是"先清后写"：JSON 里没有的字段全部回落默认值，
        #    所以三项必须每次都整套发，不能只发改动的那一个。
        # ⚠️ 全留空也必须能正常烧 SN：不校验、不拦截、不参与任何烧录判断。
        #    全留空也照样发给设备（设备回落默认服务器/默认凭证）。
        # ⚠️ 未连接设备时【保存】会拒绝，不静默只存本地 ——
        #    否则工人会以为已经写进设备了。
        c = self._card(top)

        # 标题行：MQTT 接入 + 右侧【读取】按钮。
        #   "MQTT 接入" 标签靠左，右边一个 expand spacer 撑满空间，
        #   【读取】紧贴右缘。"读取"是辅助操作（先看设备配的啥），
        #   放在标题行能让工人第一眼看到；"保存"是提交动作，放在
        #   字段行末尾，符合"填完 → 提交"的操作顺序。
        mq_title_row = ttk.Frame(c, style="Card.TFrame")
        mq_title_row.pack(fill="x")
        ttk.Label(mq_title_row, text="MQTT 接入",
                  style="Title.TLabel").pack(side="left")
        tk.Frame(mq_title_row, bg=CARD).pack(side="left", expand=True, fill="x")
        # 【读取】在标题行靠右：从设备 R:MQTT 拉回 host/port/凭证密码。
        # secondary 灰显，视觉权重弱于 primary 的【保存】。
        self.mqtt_read_btn = RoundedButton(mq_title_row, text="读取",
                                            kind="secondary", command=self._on_mqtt_read,
                                            width=6)
        self.mqtt_read_btn.pack(side="right")

        mq = ttk.Frame(c, style="Card.TFrame")
        mq.pack(fill="x", pady=(8, 0))

        # 字段行：服务器/端口/凭证密码/[显示] + 末尾【保存】按钮。
        #
        #   排布变迁（七轮，全记下来免得再猜错方向）：
        #     1) 五控件全挤在左边，[保存] 跟在 [显示] 后，width=6 撑太宽
        #     2) [保存] 单独一行并与【返修】右对齐
        #     3) 回到字段行，跟在 [显示] 后面（左对齐）
        #     4) 在字段行里【靠右】—— 插一个 expand 空白顶到右缘
        #     5) 五个【均匀分布】—— 组间距全相等
        #     6) [保存] [读取] 一起挪到独立按钮行
        #     7) 本轮：[读取] 单独放回标题行靠右，[保存] 留在字段行末尾。
        #        工人扫一眼标题就知道有【读取】可用；填完字段抬手就
        #        能点（不用换行找）。
        #
        #   实测形态： 服务器[__] ├88┤ 端口[_] ├88┤ 凭证密码[___][显示] ├176┤ [保存]
        #   末尾【保存】前用【双倍】间隔（叠两个 spacer），与字段区分开。
        mqrow = ttk.Frame(mq, style="Card.TFrame")
        mqrow.pack(fill="x")

        # 做法：见 _even_gap()。间隔数 = 4 个 spacer，前三个位置各 1 个
        # （等宽），最后一处叠 2 个，于是宽度恰好是 2 倍 ——
        # 这就是"1:1:2"比例，不用写死像素，窗口缩放时比例不变。
        # 组内仍是紧挨的 padx=(4, 0) 只 4px，视觉上还是一个整体。
        self.mq_host_var = tk.StringVar(value=self.cfg.mqtt_host)
        ttk.Label(mqrow, text="服务器", style="Dim.TLabel").pack(side="left")
        self.mq_host_entry = RoundedEntry(mqrow, textvariable=self.mq_host_var,
                                          width=16)
        self.mq_host_entry.pack(side="left", padx=(4, 0))
        self._even_gap(mqrow)

        self.mq_port_var = tk.StringVar(value=str(self.cfg.mqtt_port or ""))
        ttk.Label(mqrow, text="端口", style="Dim.TLabel").pack(side="left")
        self.mq_port_entry = RoundedEntry(mqrow, textvariable=self.mq_port_var,
                                          width=16)
        self.mq_port_entry.pack(side="left", padx=(4, 0))
        self._even_gap(mqrow)

        # [凭证密码] + [显示] 同一组：显示开关紧跟在密码框后面。
        # 这里【不放】间隔 —— 放了就成为独立一组，与需求相反。
        self.mq_pass_var = tk.StringVar(value=self.cfg.mqtt_pass)
        ttk.Label(mqrow, text="凭证密码", style="Dim.TLabel").pack(side="left")
        self.mq_pass_entry = RoundedEntry(mqrow, textvariable=self.mq_pass_var,
                                          width=16, show="•")
        self.mq_pass_entry.pack(side="left", padx=(4, 0))
        self.mq_eye = tk.BooleanVar(value=False)
        RoundedCheckbutton(mqrow, text="显示", variable=self.mq_eye,
                           command=self._toggle_mq_pass).pack(side="left")

        # 【保存】前双倍间隔（叠两个 spacer）：把"动作按钮"与"字段输入区"
        # 在视觉上分层，填完字段的人不会把保存误看成又一个输入项。
        self._even_gap(mqrow)
        self._even_gap(mqrow)

        # 【保存】按钮：MQTT 信息与 SN 烧录彻底拆开，独立提交、独立回报。
        # width=6：与【读取】等大，两个汉字同样字号自然宽度本就一致，
        # 显式锁宽度防止将来字号/DPI 改了再被撑变形。
        self.mqtt_write_btn = RoundedButton(mqrow, text="保存",
                                             kind="primary", command=self._on_mqtt_write,
                                             width=6)
        self.mqtt_write_btn.pack(side="left")

        self.result_lbl = tk.Label(body, text="", bg=CARD, fg=FG,
                                   font=("Microsoft YaHei UI", 20, "bold"))
        self.result_lbl.pack(fill="x", pady=(12, 2))

        stats = ttk.Frame(body, style="Card.TFrame")
        stats.pack(fill="x")
        self.stat_var = tk.StringVar(value="本次: 成功 0   失败 0")
        ttk.Label(stats, textvariable=self.stat_var, style="Dim.TLabel").pack(side="left")
        # 工号已搬到顶栏（更显眼），这里不再放；引用的是同一个 operator_var

        # ---------------- 日志 ----------------
        c = self._card(top, pady=(0, 12))
        head = ttk.Frame(c, style="Card.TFrame")
        head.pack(fill="x")
        ttk.Label(head, text="日志", style="Title.TLabel").pack(side="left")
        RoundedButton(head, text="导出", command=self._export_log,
                      kind="secondary", width=6).pack(side="right")
        RoundedButton(head, text="清空", command=self._clear_log,
                      kind="secondary", width=6).pack(side="right", padx=(0, 6))

        wrap = ttk.Frame(c, style="Card.TFrame")
        wrap.pack(fill="both", expand=True, pady=(8, 0))
        self.log_box = tk.Text(wrap, height=12, wrap="word", relief="flat",
                               bg="#fbfcfd", fg=FG, font=("Consolas", 9),
                               padx=8, pady=6, state="disabled")
        sb = ttk.Scrollbar(wrap, command=self.log_box.yview)
        self.log_box.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self.log_box.pack(side="left", fill="both", expand=True)

        for tag, color in (("OK", OK_GREEN), ("FAIL", FAIL_RED),
                           ("WARN", WARN_ORANGE), ("DIM", FG_DIM)):
            self.log_box.tag_configure(tag, foreground=color)

    #=================================================================
    # SN 查询：按 IMEI / 芯片 UID 查是否已绑定
    #=================================================================
    def _do_query(self) -> None:
        kw = self.query_var.get().strip()
        # 换了一次查询，上次查到的号就作废——否则补烧按钮会按旧结果亮着
        self.recover_sn = ""
        if not kw:
            self.query_result.configure(text="请输入 IMEI 或芯片 UID", fg=WARN_ORANGE)
            self.query_entry.focus_set()
            self._update_recover_visibility()
            return
        if self.alloc is None:
            return

        hits = self.alloc.ledger.query(kw)
        if not hits:
            self.query_result.configure(
                text=f"未查到：{kw}\n该设备没有绑定记录（未烧录，或台账已被清理）",
                fg=FG_DIM)
            self._emit("INFO", f"查询 {kw}: 无记录")
            self._update_recover_visibility()
            return

        # 有记录：重点突出"当前生效的那个号"，再列历史
        # 显示前再洗一次：万一有没走 _load 清洗的脏数据，也不能把乱码甩到界面上
        def clean(v):
            return clean_field(v or "")

        lines = []
        ok_rows = [r for r in hits if r.get("result") == "ok"]
        cur = ok_rows[0] if ok_rows else None
        if cur:
            lines.append(
                f"已绑定 SN: {clean(cur.get('sn'))}"
                f"    烧录时间: {clean(cur.get('time'))}"
                f"    操作员: {clean(cur.get('operator'))}"
                + ("    [返修号]" if cur.get("rework") == "1" else ""))
        lines.append(f"IMEI: {clean(hits[0].get('imei'))}    "
                     f"UID: {clean(hits[0].get('uid'))}")
        if len(hits) > 1:
            lines.append(f"历史记录 {len(hits)} 条：")
            for r in hits[1:6]:
                tag = {"ok": "成功", "fail": "失败"}.get(r.get("result"), r.get("result"))
                extra = f"/{clean(r.get('reason'))}" if r.get("reason") else ""
                lines.append(f"  {clean(r.get('time'))}  {clean(r.get('sn'))}  "
                             f"[{tag}{extra}]  工号 {clean(r.get('operator'))}")
            if len(hits) > 6:
                lines.append(f"  …另有 {len(hits) - 6} 条，详见 data/ledger.csv")

        self.query_result.configure(text="\n".join(lines), fg=OK_GREEN)
        # 记住查到的号，供"补烧"按钮使用（只在设备 SN 为空时才出现）
        self.recover_sn = cur.get("sn") if cur else ""
        self._update_recover_visibility()
        self._emit("OK", f"查询 {kw}: 命中 {len(hits)} 条，"
                         f"当前 SN={cur.get('sn') if cur else '-'}")

    #=================================================================
    # 补烧按钮的显隐与可用性
    #=================================================================
    def _update_recover_visibility(self) -> None:
        """决定'烧写'按钮出不出现。

        出现条件：查询查到该设备已绑定的 SN + 设备已连接 + 设备当前没有 SN
              + 未上锁 — 这 4 个条件全部满足才显示按钮。
        任意一个不满足就 pack_forget：
            没 recover_sn / 没设备 / 没 last_info → 不需要补烧
            设备已有 SN（无论匹不匹配）            → 不需要补烧
            设备已上锁                            → 走【返修】流程更合适

        ⚠️ hide 时也 disable recover_btn：刚启动时 _build_ui 把按钮创建成默认
           state=normal，pack_forget 之后 widget 不可见但 state 还是 normal。
           万一有 race（比如 _recover_burn 接到一个早先发的 event），
           按钮还是会响应。统一 disable 让"按钮状态"和"按钮可见性"同步。
        """
        if (not self.recover_sn or self.device is None
                or self.last_info is None):
            self.recover_btn.configure(state="disabled")
            self.recover_row.pack_forget()
            return

        info = self.last_info
        if info.has_sn:
            # 设备已经有 SN（匹配 / 不匹配都算），不需要补烧
            self.recover_btn.configure(state="disabled")
            self.recover_row.pack_forget()
            return
        if info.is_locked:
            # 已锁不能直接 W:SN 覆盖，要走返修先解锁
            self.recover_btn.configure(state="disabled")
            self.recover_row.pack_forget()
            return

        # 唯一需要补烧的场景：无 SN + 未锁 + 台账查到旧号
        self.recover_lbl.configure(
            text=f"该设备原编号 {self.recover_sn}，当前设备无 SN，"
                 f"可把旧号补烧回去（不分配新号）", fg=FG)
        self.recover_btn.configure(state="normal")
        # before= 保证它紧跟查询行下方，不会跑到结果文字后面
        self.recover_row.pack(fill="x", pady=(6, 0), before=self.query_result)

    def _fill_query_from_device(self) -> None:
        """把当前连接设备的 IMEI 填进查询框并查（连上设备后一键查自己）。

        串口读是阻塞操作，放工作线程；回填走 result_q，不在线程里碰控件。
        """
        if self.device is None:
            self.query_result.configure(text="尚未连接设备，无法查本机",
                                        fg=WARN_ORANGE)
            return
        if self.busy:
            return
        self.busy = True
        threading.Thread(target=self._query_self_worker, daemon=True).start()

    def _query_self_worker(self) -> None:
        imei, err = "", ""
        try:
            imei = self.device.read_id().imei or ""
        except (DeviceError, IOError) as e:
            err = str(e)
        except Exception as e:                          # noqa: BLE001
            err = f"{type(e).__name__}: {e}"
        self.result_q.put(("query_self", imei, err))

    #=================================================================
    # 初始化
    #=================================================================
    def _init_allocator(self) -> None:
        try:
            self.alloc = Allocator(self.cfg.rule, self.cfg.counter_file,
                                   self.cfg.ledger_file,
                                   daily_reset=self.cfg.serial_daily_reset)
            # 注意：不在这里 _refresh_next —— 没设备时显示 "SN：—"，连接后才
            # 显示出"准备烧的是这个号"。详见 _connect_done 与 _teardown_connection。
        except AllocatorError as e:
            messagebox.showerror("初始化失败", str(e))
            self.root.destroy()
            raise SystemExit(1)

    def _refresh_next(self) -> None:
        if self.alloc:
            self.next_var.set(f"SN：{self.alloc.preview()}")
            # 说明"这是今天第几台"，避免工人看到第二天从 0001 重新开始
            # 以为号发重了。9999 是每天上限，到顶会停机要求扩位。
            try:
                n = self.alloc.peek()
                cap = 10 ** self.cfg.rule.serial_digits - 1
                mode = ("每天归零" if self.cfg.serial_daily_reset
                        else "全局递增")
                self.next_hint_var.set(
                    f"下一台 = 第 {n} 台（{mode}，单日上限 {cap}）")
            except Exception:                           # noqa: BLE001
                self.next_hint_var.set("")

    #=================================================================
    # Q3: 日期 / 起始流水号手动覆盖
    #=================================================================
    def _on_gen_sn(self, target_var: tk.StringVar, hint_var: tk.StringVar) -> None:
        """【生成SN】：按当前日期 + 输入的流水号，算一个 SN 给工人看。

        只预览，三不：
            - 不占计数器（下一次烧录还是照原顺序发号，不会跳过这个号）
            - 不写设备
            - 不记台账

        用途：核对"这个流水号会生成什么号"、补录前确认格式、
        或者给外面的人报一个预计的号。想看下一个真的号，看上面的
        SN 预览就行，不用点这里。

        写两个 StringVar 参数：返修窗口有自己专属的 preview var，
        不去覆盖主界面 next_var —— 工人想 "算出来看看" 不应该把主流程
        准备烧的号也弄乱（之前直接写 self.next_var 就有这个副作用）。

        日期直接取 date_var（弹窗里默认预填当天，要补别的日期自己改）；
        流水号必须填 —— 不填就不知道要算哪一台。
        """
        txt = self.serial_var.get().strip()
        if not txt:
            messagebox.showwarning("缺少流水号", "请先填【起始流水号】")
            return
        try:
            serial = int(txt)
        except ValueError:
            messagebox.showwarning("输入无效", f"流水号必须是数字，得到 {txt!r}")
            return
        date = self.date_var.get().strip()
        try:
            sn = self.cfg.rule.make(serial, date or None)
        except ValueError as e:
            messagebox.showwarning("生成失败", str(e))
            return
        target_var.set(f"SN：{sn}")
        hint_var.set(
            f"预览：第 {serial} 台 · {date or '当天'}（未占用计数器，未写入设备）")
        self._emit("DIM", f"生成 SN 预览: {sn}（未占用计数器，未写入设备）")

    def _apply_overrides(self) -> None:
        """[未使用] 旧版本：把 date_var/serial_var 同步到 alloc.set_manual_*。

        返修现在不污染 alloc —— _rework 读 date_var/serial_var 直接传给
        burner.rework(manual_serial, manual_date)，走 allocate_specific()
        单独查 ledger.has_sn()，counter 永不动。

        主流程【烧写 SN】也不需要 manual_serial_start —— 永远 alloc.allocate()
        从 counter 取号。

        此方法保留是因为 allocator.set_manual_serial_start / set_manual_date
        还在被外部测试调用，但 PC 端 UI 已经不再触发它。
        """
        if self.alloc is None:
            return
        try:
            date_txt = self.date_var.get().strip()
            serial_txt = self.serial_var.get().strip()
            self.alloc.set_manual_date(date_txt if date_txt else None)
            if serial_txt:
                self.alloc.set_manual_serial_start(int(serial_txt))
            else:
                self.alloc.set_manual_serial_start(None)
        except (AllocatorError, ValueError) as e:
            messagebox.showwarning("输入无效", str(e))
            self._refresh_next()
            return
        self._refresh_next()

    def _on_date_return(self, _event=None) -> None:
        """[未使用] 保留：主流程以前绑过这个回调，现在 date/serial 输入框
        只在返修弹窗里，而弹窗里绑定的是 _on_rework_date_return。
        留着以防将来主流程再加日期/流水号字段。"""
        self._apply_overrides()
        return "break"

    def _on_serial_return(self, _event=None) -> None:
        """[未使用] 同上。"""
        self._apply_overrides()
        return "break"

    def _on_rework_date_return(self, _event=None) -> None:
        """返修弹窗里日期框的回调 —— 只刷新弹窗内的 SN 预览，不动 alloc。
        弹窗关掉前 submit() 才会 _apply_overrides 把值传给 alloc。
        之前用 _on_date_return 会导致主界面 next_var 被覆盖，工人
        看着"烧录下一台"的号被改来改去，困惑为啥不是预想的那个。"""
        self._refresh_rework_preview()
        return "break"

    def _on_rework_serial_return(self, _event=None) -> None:
        """返修弹窗里起始号框的回调 —— 同上，只刷新弹窗预览。"""
        self._refresh_rework_preview()
        return "break"

    def _refresh_rework_preview(self) -> None:
        """按当前 date_var/serial_var 算一个 SN 写到返修弹窗的预览 var。
        与主界面 next_var 完全隔离 —— 这里只算"指定流水号对应的 SN"，
        不占 alloc 的计数器（_on_gen_sn 也不占，preview 仅供核对）。"""
        if not hasattr(self, "rework_preview_var"):
            return
        serial_txt = self.serial_var.get().strip()
        if not serial_txt:
            self.rework_preview_var.set("")
            self.rework_hint_var.set("")
            return
        try:
            serial = int(serial_txt)
        except ValueError:
            self.rework_preview_var.set("")
            self.rework_hint_var.set("起始号必须是数字")
            return
        date = self.date_var.get().strip()
        try:
            sn = self.cfg.rule.make(serial, date or None)
        except ValueError as e:
            self.rework_preview_var.set("")
            self.rework_hint_var.set(f"无效：{e}")
            return
        self.rework_preview_var.set(f"SN：{sn}")
        self.rework_hint_var.set(
            f"预览：第 {serial} 台 · {date or '当天'}（未占用计数器，未写入设备）")

    #=================================================================
    # 日志
    #=================================================================
    def _emit(self, level: str, msg: str) -> None:
        self.log_q.put((level, msg))

    def _drain_log(self) -> None:
        try:
            while True:
                level, msg = self.log_q.get_nowait()
                self.log_box.configure(state="normal")
                self.log_box.insert("end", msg + "\n", level if level in
                                    ("OK", "FAIL", "WARN") else ())
                self.log_box.see("end")
                self.log_box.configure(state="disabled")
        except queue.Empty:
            pass
        self.root.after(80, self._drain_log)

    def _clear_log(self) -> None:
        self.log_box.configure(state="normal")
        self.log_box.delete("1.0", "end")
        self.log_box.configure(state="disabled")

    #=================================================================
    # MQTT 接入信息（可选）
    #   这三项目前只记录不写设备，见 _build_ui 里的说明。
    #   与 SN 烧录完全解耦：这里是独立的"保存"动作，
    #   不挂在烧录按钮上，也不在烧录过程中被读写。
    #   设计原则：任何异常都不能影响 SN 烧录主流程。
    #=================================================================
    def _toggle_mq_pass(self) -> None:
        """凭证密码显/隐切换。"""
        self.mq_pass_entry.configure(show="" if self.mq_eye.get() else "•")

    def _on_mqtt_write(self) -> None:
        """【保存】按钮：把 MQTT 三项写进设备，并同步到本地 config.json。

        ⚠️ 与 SN 烧录完全解耦：不分配流水号、不动台账、失败绝不影响烧 SN。
           三项留空也照样提交（设备侧会回落默认服务器/默认凭证）。

        流程（串口读写必须在线程里做，主线程只碰队列）：
            1) 在主线程把界面值取成普通 Python 值（tkinter 非线程安全）
            2) 起线程发 W:MQTT，等设备应答
            3) 结果进队列，由 _drain_result -> _mqtt_write_done 处理

        设备侧协议见 device.Device.write_mqtt：
            W:MQTT={"host":"..","port":1883,"auto_pass":".."}
            <- RET:MQTT=OK / RET:FAIL:MQTT:<原因>

        异常处理：
          - 端口填了非数字：保持原值，不把配置写坏，并明确告知
          - 未连接设备：拒绝并提示先连接（不静默只存本地，那会误导）
          - 设备不认识 W:MQTT（还在跑 soft_sn_demo）：超时，明确告知
          - 写盘失败（只读/被占用）：只提示，绝不抛异常影响烧录
        """
        host = self.mq_host_var.get().strip()
        passwd = self.mq_pass_var.get()
        port_raw = self.mq_port_var.get().strip()

        port = self.cfg.mqtt_port
        if port_raw:
            try:
                port = int(port_raw)
            except ValueError:
                # 不写坏原配置，但要让工人知道刚才那次没生效
                self._emit("WARN", f"端口 {port_raw!r} 不是数字，"
                                   f"仍用原值 {port}；请改正后重新点【保存】")
                self.mq_port_var.set(str(port))

        # 端口范围提示（只提示，不拦截：留空/越界都不影响 SN 烧录）
        if not (1 <= port <= 65535):
            self._emit("WARN", f"端口 {port} 越界（1~65535），已按原值处理")

        # 未连接就不发：只存本地会让工人以为已经写进设备了
        if self.device is None:
            self._emit("FAIL", "未连接设备，无法写入 MQTT 配置"
                               "（请先点【连接设备】）")
            return
        if self.busy:
            return

        # 先把三项落到本地配置：设备写成功与否都不影响本地记录，
        # 且这样即便设备侧写入失败，工人填的值也不会丢
        self.cfg.mqtt_host = host
        self.cfg.mqtt_port = port
        self.cfg.mqtt_pass = passwd
        local_saved = True
        try:
            cfg_mod.save_config(self.cfg)
        except OSError as e:
            # 这三个值存不下去不影响烧 SN，说清楚就行
            local_saved = False
            self._emit("WARN", f"MQTT 配置写设备前，本地保存失败: {e}")

        self.busy = True
        self.mqtt_write_btn.configure(state="disabled")
        self._set_status("正在写入 MQTT 配置…", WARN_ORANGE)
        threading.Thread(target=self._mqtt_write_worker,
                         args=(host, port, passwd, local_saved),
                         daemon=True).start()

    def _mqtt_write_worker(self, host: str, port: int, passwd: str,
                           local_saved: bool) -> None:
        """线程体：只做串口读写，不碰任何控件。"""
        ok, msg = False, ""
        try:
            self.device.write_mqtt(host, port, passwd)
            ok = True
        except DeviceError as e:
            # 设备明确拒绝：e.reason 是设备原文，转成工人看得懂的中文
            msg = reason_cn(e.reason)
        except TimeoutError_ as e:
            # 无应答：多半是设备跑的还是 soft_sn_demo（没有 W:MQTT），
            # 设备会静默忽略未知指令，所以等到超时。
            msg = (f"{e}（设备不支持 W:MQTT？"
                   f"确认刷的是带 MQTT 的固件）")
        except IOError as e:
            msg = f"串口错误: {e}"
        except Exception as e:                      # noqa: BLE001
            msg = f"异常: {type(e).__name__}: {e}"
        self.result_q.put(("mqtt_write", ok, msg, local_saved))

    def _mqtt_write_done(self, ok: bool, msg: str, local_saved: bool) -> None:
        self.busy = False
        self.mqtt_write_btn.configure(state="normal")
        if ok:
            self._set_status("MQTT 配置已写入设备", OK_GREEN)
            tail = "" if local_saved else "（本地配置保存失败，仅设备已更新）"
            self._emit("OK", f"MQTT 接入已写入设备{tail}: "
                              f"{self.mqtt_summary()}")
        else:
            self._set_status("MQTT 写入失败", FAIL_RED)
            self._emit("FAIL", f"MQTT 写入设备失败: {msg}")

    #=================================================================
    # 【读取】MQTT 配置：从设备 R:MQTT 拉回三项填到表单
    #=================================================================
    def _on_mqtt_read(self) -> None:
        """【读取】按钮：发 R:MQTT，把设备里的 host/port/凭证密码填回表单。

        跟【保存】对称的设计：
          - 不分配流水号、不动台账、不动本地 config.json（跟烧 SN 解耦）
          - 设备端协议 R:MQTT 由 device.read_mqtt 处理，返 mqttcfg.effective()
            的 JSON。设备侧 RET:FAIL:MQTT:原因 / 超时（不识别的固件）都明确报错
          - 失败绝不影响烧录主流程（任何"异常"入口都只走 _emit）

        工人典型路径：插上设备 → 点【读取】→ 看一眼现在设备配的啥 →
        觉得没问题就关掉，想改就改完再【保存】。之前没这个入口就只能
        凭记忆填，写错了对账很麻烦。
        """
        if self.device is None:
            self._emit("FAIL", "未连接设备，无法读取 MQTT 配置"
                               "（请先点【连接设备】）")
            return
        if self.busy:
            return
        self.busy = True
        # 【读取】【保存】都 disable 避免 race —— 同一份配置两个动作并行容易乱
        self.mqtt_read_btn.configure(state="disabled")
        self.mqtt_write_btn.configure(state="disabled")
        self._set_status("正在读取 MQTT 配置…", WARN_ORANGE)
        threading.Thread(target=self._mqtt_read_worker,
                         daemon=True).start()

    def _mqtt_read_worker(self) -> None:
        """线程体：发 R:MQTT，解析三项放回队列。"""
        payload = None
        err = ""
        try:
            payload = self.device.read_mqtt()
        except DeviceError as e:
            err = reason_cn(e.reason)
        except TimeoutError_ as e:
            err = (f"{e}（设备不支持 R:MQTT？"
                   f"确认刷的是带 MQTT 的固件）")
        except IOError as e:
            err = f"串口错误: {e}"
        except Exception as e:                      # noqa: BLE001
            err = f"异常: {type(e).__name__}: {e}"
        self.result_q.put(("mqtt_read", payload, err))

    def _mqtt_read_done(self, payload, err: str) -> None:
        """主线程：解析 payload 填回表单，并同步本地 config.json。

        设备返回的 JSON 字段（mqttcfg.effective() 全字段）：
            cfg.host / cfg.port / cfg.user / cfg.pass
            cfg.pub_topic / cfg.sub_topic
            cfg.ssl / cfg.client_id / cfg.interval_s / cfg.qos
            cfg.allow_no_sn / cfg.keep_session
            cfg.auto.pass              ← 凭证密码在这里（自动档）
            cfg.manual_on
            auto_pass / manual_on / pub / sub / ready / err / stat

        表单只关心三项：cfg.host / cfg.port / cfg.auto.pass。
        其余字段由设备侧维护，前端不显示，避免表单越加越乱。
        """
        self.busy = False
        self.mqtt_read_btn.configure(state="normal")
        # mqtt_write_btn 在 _on_mqtt_read 里被 disable 防 race；这里 busy 已经
        # 释放，调 _update_connection_btns 让两个按钮都按 device is not None
        # 重置 —— 没改之前的逻辑是"不再这里改 write_btn"，结果读取完了 write
        # 永远停在 disabled，工人点不动。读 → 改 → 保存是连续动作，必须恢复。
        self._update_connection_btns()
        if err:
            self._set_status("MQTT 读取失败", FAIL_RED)
            self._emit("FAIL", f"MQTT 读取失败: {err}")
            return
        if not isinstance(payload, dict):
            self._set_status("MQTT 读取失败", FAIL_RED)
            self._emit("FAIL", f"MQTT 读取失败: 应答格式不是 dict")
            return
        cfg = payload.get("cfg")
        if not isinstance(cfg, dict):
            self._set_status("MQTT 读取失败", FAIL_RED)
            self._emit("FAIL", f"MQTT 读取失败: 应答缺 cfg 字段")
            return
        host = cfg.get("host", "") or ""
        port = cfg.get("port", 0) or 0
        auto = cfg.get("auto") or {}
        passwd = auto.get("pass", "") if isinstance(auto, dict) else ""
        passwd = passwd or ""

        # 填回前端 StringVar —— 自动触发 Entry 重绘，不需要手动 refresh
        self.mq_host_var.set(host)
        self.mq_port_var.set(str(port) if port else "")
        self.mq_pass_var.set(passwd)

        # 同步本地 config.json —— 工人在另一台机器上重连也能看到当前配的啥
        self.cfg.mqtt_host = host
        self.cfg.mqtt_port = int(port) if port else self.cfg.mqtt_port
        self.cfg.mqtt_pass = passwd
        try:
            cfg_mod.save_config(self.cfg)
        except OSError as e:
            self._emit("WARN", f"MQTT 本地保存失败: {e}")

        self._set_status("MQTT 配置已读回", OK_GREEN)
        self._emit("OK", f"MQTT 已读回: {self.mqtt_summary()}")

    def mqtt_summary(self) -> str:
        """一句话摘要，供日志用。三项全空返回空串。"""
        host = self.cfg.mqtt_host or ""
        port = self.cfg.mqtt_port or ""
        has_pass = "有" if self.cfg.mqtt_pass else "无"
        if not host and not self.cfg.mqtt_pass:
            return ""
        return f"{host or '(未填)'}:{port} 凭证:{has_pass}"

    #=================================================================
    # 掉线监测
    #   USB 拔掉后句柄不会自动失效，界面会一直显示"已连接"，
    #   工人以为连着，其实设备早没了。所以定时问内核一句"设备还在吗"，
    #   连续几次不在就断开，并把状态灯变红、禁用烧录按钮。
    #=================================================================
    def _watchdog(self) -> None:
        """每 WATCHDOG_INTERVAL_MS 问一次"设备还在吗"。
        关键修复：之前还要求 not self.busy → 烧录过程中如果设备掉了，
        看门狗被跳过，要等 burn 完才检测 → 用户看到"软件没识别到"。
        现在 busy 时仍然检查（burner 内部有 serial IO 异常处理，busy 状态
        不会因 watch 误报断开而乱跳）。"""
        try:
            if self.port is not None and self.port.is_open:
                if not self.port.still_alive():
                    self._miss_count += 1
                    if self._miss_count >= WATCHDOG_MISS_LIMIT:
                        self._on_disconnected("设备已断开（USB 线拔了或设备掉电）")
                        return
                else:
                    self._miss_count = 0
            else:
                self._miss_count = 0
        except Exception:                           # noqa: BLE001
            self._miss_count = 0
        self.root.after(WATCHDOG_INTERVAL_MS, self._watchdog)

    def _on_disconnected(self, why: str) -> None:
        self._miss_count = 0
        port_name = self.port.port if self.port is not None else "?"
        self._teardown_connection("已断开")
        self._set_status("已断开", FAIL_RED)
        self._emit("FAIL", f"{why}（{port_name}）")
        self._emit("WARN", "请重新插好 USB 线，然后点【连接设备】")

    #=================================================================
    # 串口插拔监听
    #   手动点【刷新】也能刷，但工人插设备时不会想到去点那个按钮 ——
    #   插上设备发现下拉里没有，会以为软件坏了。所以定时看一眼注册表，
    #   口变了就自动更新下拉，并把变化说一声。
    #
    #   为什么轮询而不监听 WM_DEVICECHANGE：
    #     那条路要给 tkinter 的窗口子类化改 wndproc，或者另建消息窗口
    #     开线程，在纯 ctypes 下踩坑风险高（wndproc 里调 Python 回调、
    #     引用被 GC、消息循环和 tkinter 抢消息），一旦写错可能直接崩。
    #     而"读一遍注册表 + 比对"只要几百微秒，1.5 秒一次的开销可以忽略，
    #     检测延迟也就 1.5 秒，工人完全感觉不到。
    #=================================================================
    def _start_port_watch(self) -> None:
        # None = 还没取过基线，第一轮只记录不发通知
        self._known_ports = None
        self._poll_ports()

    def _poll_ports(self) -> None:
        try:
            cur = set(_registry_ports())
            if self._known_ports is None:
                self._known_ports = cur
            elif cur != self._known_ports:
                self._known_ports = cur
                self._on_ports_changed()
        except Exception:                           # noqa: BLE001
            # 读注册表失败不该影响任何功能，下一轮再试
            pass
        finally:
            # 必须放在 finally：上面任何一步出错也要继续排下一轮，
            # 否则轮询悄悄停掉，插拔就又得手动刷了
            self.root.after(PORT_POLL_MS, self._poll_ports)

    def _on_ports_changed(self) -> None:
        """注册表里的串口变了 -> 刷新下拉，并处理"选中的口没了"。

        关键修复：之前要等 watchdog（1-2 秒）才报断开，但部分 USB 转串口
        适配器在 PC 看到"注册表 COM 口消失"时，串口句柄仍然短暂有效
        → ClearCommError 不一定立即失败 → 体感"软件没识别到"。
        现在注册表检测到当前正在用的口消失，**立即**走断开流程
        （不等 watchdog 兜底）。
        """
        ports = list_ports()
        values = ["请选择串口"] + ports
        self.port_cb.configure(values=values)

        sel = self.port_var.get()
        if sel != "请选择串口" and sel not in values:
            # 选中的口消失了。两种情况分开处理：
            #   正连着它 -> 就是这台被拔了，走断开流程（否则界面一直
            #               显示"已连接"，工人以为还在烧）
            #   没连着   -> 只是列表里少了项，回"请选择串口"
            # ⚠️ 两种情况都必须先把选择切回"请选择串口"：那个口已经不存在了，
            #    留在下拉里工人下次一点"连接"就是打开一个不存在的口。
            was_connected = (self.port is not None and self.port.port == sel)
            self.port_var.set("请选择串口")
            if was_connected:
                # 注册表口消失 = 物理上已断开，比 watchdog 的 ClearCommError
                # 探针更可靠，立刻走断开（不把 1-2 秒延迟留给用户）
                self._on_disconnected(f"{sel} 已移除")
                return
            self._emit("WARN", f"端口 {sel} 已不存在，已切回【请选择串口】")

        self._emit("DIM", f"串口列表已变化，当前 {len(ports)} 个: "
                          f"{', '.join(ports) or '（无）'}")
        for k in self.fields:
            self.fields[k].set("—")
        self.next_var.set("SN：—")

    #=================================================================
    # 结果队列：工作线程的唯一回主线程通道
    #   tkinter 非线程安全，所以线程里不碰任何控件，只往队列放结果，
    #   由主线程的 _drain_result 统一处理。
    #=================================================================
    def _drain_result(self) -> None:
        try:
            while True:
                item = self.result_q.get_nowait()
                kind = item[0]
                if kind == "connect":
                    self._connect_done(item[1], item[2])
                elif kind == "burn":
                    self._burn_done(item[1])
                elif kind == "probe":
                    # 先释放 busy 再 _show_info —— _show_info 会调 _update_lock_btn，
                    # 那里面读 self.busy 判断是否显示【手动上锁】。如果 busy=True
                    # 调 _show_info，按钮被 pack_forget；之后 busy=False 就再也不会
                    # 把它 pack 回来了（直到下一次 _show_info）。先释放就能避开
                    # "按钮消失后不见回来" 的死状态。
                    self.busy = False
                    if item[1] is not None:
                        self._show_info(item[1])
                    else:
                        self._emit("FAIL", f"探测失败: {item[2]}")
                elif kind == "query_self":
                    self.busy = False
                    if item[1]:
                        self.query_var.set(item[1])
                        self._do_query()
                    else:
                        self.query_result.configure(
                            text=f"读取设备 IMEI 失败: {item[2]}", fg=FAIL_RED)
                elif kind == "mqtt_write":
                    self._mqtt_write_done(item[1], item[2], item[3])
                elif kind == "mqtt_read":
                    self._mqtt_read_done(item[1], item[2])
                elif kind == "lock":
                    self._lock_done(item[1], item[2])
                elif kind == "unlock":
                    self._unlock_done(item[1], item[2])
                elif kind == "clear_sn":
                    self._clear_sn_done(item[1], item[2])
        except queue.Empty:
            pass
        self.root.after(80, self._drain_result)

    def _export_log(self) -> None:
        import datetime
        os.makedirs(self.cfg.data_dir, exist_ok=True)
        path = os.path.join(self.cfg.data_dir,
                            f"log-{datetime.datetime.now():%Y%m%d-%H%M%S}.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(self.log_box.get("1.0", "end"))
        self._emit("OK", f"日志已导出: {path}")

    #=================================================================
    # 串口
    #=================================================================
    def _on_auto_lock_toggle(self) -> None:
        """烧录后自动上锁 勾选切换：把值同步到 burner（连接后改才有意义）、
        cfg（落盘 config.json 下次连接也用）。不更新 burner 的话会按连接时
        读的旧值自动锁/不锁，正是"不勾也上锁"的根因。"""
        on = bool(self.auto_lock_var.get())
        if self.burner is not None:
            self.burner.auto_lock = on
        self.cfg.auto_lock = on

    def _refresh_ports(self) -> None:
        # 只列电脑【实际有】的串口：注册表枚举 + CreateFileW 逐个试开。
        # 曾经改成"COM1~COM256 全列"，工人反馈那是在列端口号而不是
        # 识别电脑当前有的端口 —— 256 项里绝大多数根本不存在，
        # 反而要在里面找自己那一个。改回只列探测到的。
        ports = list_ports()
        self.port_cb.configure(values=["请选择串口"] + ports)
        if self.port_var.get() not in (["请选择串口"] + ports):
            self.port_var.set("请选择串口")

    def _set_status(self, text: str, color: str) -> None:
        self.status_lbl.configure(text=text)
        self.status_dot.configure(fg=color)

    def _update_connection_btns(self) -> None:
        """连接 toggle 按钮状态机。

        单一按钮，文字随状态切换：
          - 未连接（device is None）→ "连接设备"  normal
          - 已连接                   → "断开"        normal
          - busy（识别/烧录中）      → "正在识别…"    disabled

        同时按设备连接状态 enable/disable 其它依赖设备的按钮——
        没接设备就别让工人点【查本机】【返修】等，点了也是 messagebox 弹回来，
        还不如直接 disable 一目了然。
        """
        if not hasattr(self, "conn_btn"):
            return
        if self.busy:
            self.conn_btn.configure(text="正在识别…", state="disabled")
        elif self.device is None:
            self.conn_btn.configure(text="连接设备", state="normal")
        else:
            self.conn_btn.configure(text="断开", state="normal")
        # 设备依赖按钮：没设备就 disable。【烧写 SN】由 burn_btn 自己在 connect/
        # disconnect 里管，不在这里重复。【手动上锁】由 _update_lock_btn 按
        # 状态管，也不在这里重复。
        ok = self.device is not None and not self.busy
        if hasattr(self, "query_self_btn"):
            self.query_self_btn.configure(
                state="normal" if ok else "disabled")
        if hasattr(self, "rework_btn"):
            self.rework_btn.configure(
                state="normal" if ok else "disabled")
        # MQTT 接入栏：服务器/端口/密码 + 保存+读取按钮。MQTT 信息通过 W:MQTT / R:MQTT
        # 跟设备交互（device.write_mqtt / read_mqtt），没设备发不出去，整栏 disable。
        # 工人只能在设备连接状态下保存 / 读取 MQTT 三项。
        mq_ok = self.device is not None  # busy 时不阻塞 disable MQTT
        for attr in ("mq_host_entry", "mq_port_entry", "mq_pass_entry",
                     "mqtt_write_btn", "mqtt_read_btn"):
            w = getattr(self, attr, None)
            if w is not None:
                w.configure(state="normal" if mq_ok else "disabled")

    def _toggle_connection(self) -> None:
        """toggle 按钮回调：未连就连，已连就断。"""
        if self.busy:
            return
        if self.device is None:
            self._connect()
        else:
            self._disconnect_click()

    def _connect(self) -> None:
        if self.busy:
            return
        self.busy = True
        self._update_connection_btns()
        self._set_status("正在识别…", WARN_ORANGE)
        # ⚠️ tkinter 不是线程安全的。工作线程里读 StringVar、调 after()、
        #    改控件状态，都可能抛 "main thread is not in main loop"。
        #    所以：要用的值在主线程先取成普通 Python 值；线程只碰这些副本；
        #    结果通过队列送回主线程处理，线程绝不直接调 root.after()。
        chosen = self.port_var.get()
        baud = self.cfg.baud
        timeout_ms = self.cfg.timeout_ms
        threading.Thread(target=self._connect_worker,
                         args=(chosen, baud, timeout_ms), daemon=True).start()

    def _connect_worker(self, chosen: str, baud: int, timeout_ms: int) -> None:
        port = None
        err = ""
        try:
            if chosen and chosen != "请选择串口":
                # 试通后再正式打开：避免把打不开的口写进配置
                with SerialPort(chosen, baud=baud,
                                read_timeout_ms=timeout_ms) as sp:
                    if Device(sp).ping():
                        port = chosen
                    else:
                        err = f"{chosen} 无应答（不是设备口，或设备没起来）"
            else:
                # ⚠️ log 回调的签名对不上会直接炸掉整条连接流程：
                #    device.find_device_port 的 log 是【1 个参数】(log(msg))，
                #    而 self._emit 是【2 个参数】(_emit(level, msg))。
                #    以前直接把 self._emit 传进去，新装的机器（config 里
                #    port 为空 -> 走自动识别这条唯一分支）一连就报
                #    "TypeError: _emit() missing 1 required positional argument"，
                #    表现为"连不上设备"，但根因跟串口一点关系都没有。
                #    这里用 lambda 适配成 1 参。
                port, tried = find_device_port(
                    baud, lambda m: self._emit("DIM", m))
                if port is None:
                    err = f"已试 {len(tried)} 个串口，全部无应答"
        except Exception as e:                      # noqa: BLE001
            err = f"{type(e).__name__}: {e}"
        self.result_q.put(("connect", port, err))

    def _connect_done(self, port: str | None, err: str) -> None:
        self.busy = False
        if port is None:
            self._set_status(f"连接失败: {err}", FAIL_RED)
            self._emit("FAIL", f"连接失败: {err}")
            self._update_connection_btns()
            return

        # 先关掉旧连接，避免重复打开同一口
        if self.port is not None:
            try:
                self.port.close()
            except OSError:
                pass
            self.port = None

        try:
            self.port = SerialPort(port, baud=self.cfg.baud,
                                   read_timeout_ms=self.cfg.timeout_ms)
            self.port.open()
        except IOError as e:
            self.port = None
            self._set_status(f"打开失败: {e}", FAIL_RED)
            self._emit("FAIL", f"打开 {port} 失败: {e}")
            return

        self.device = Device(self.port)
        self.burner = Burner(self.device, self.alloc,
                             auto_lock=self.auto_lock_var.get(), log=self._emit)
        self.cfg.port = port
        try:
            cfg_mod.save_config(self.cfg)
        except OSError as e:
            self._emit("WARN", f"配置保存失败: {e}")

        self._set_status(f"已连接 {port}", OK_GREEN)
        self._emit("OK", f"已连接 {port}，115200 8N1")
        self.burn_btn.configure(state="normal")
        # 连接设备后立即刷一次下一号预览 —— 没设备时 next_var 是 "SN：—"，连上
        # 才显示出"准备烧的号"，让工人一眼看到接下来要写什么。
        self._refresh_next()
        self._update_connection_btns()
        self._probe_only()

    def _disconnect_click(self) -> None:
        self._teardown_connection("已断开")

    def _teardown_connection(self, say_what: str) -> None:
        """统一的断开清理。主动点断开 / 看门狗发现掉线都走这里。

        不判断 port 是否为 None——掉线时 port 可能已经被关成 None 了，
        早退会让 UI 状态（按钮、身份卡、补烧入口）留在"已连接"的样子。
        """
        if self.port is not None:
            name = self.port.port
            try:
                self.port.close()
            except OSError:
                pass
        else:
            name = "串口"
        self.port = None
        self.device = None
        self.burner = None
        self.busy = False
        self.last_info = None
        self.recover_row.pack_forget()
        self.burn_btn.configure(state="disabled")
        # 断开后设备身份卡字段恢复占位 —— 不然工人看到的 IMEI/SN 是上一台的，
        # 误以为插的就是那台，重新连接前根本不知道要看的是哪一台。
        for k in self.fields:
            self.fields[k].set("—")
        # 断开后下一号预览恢复 "SN：—" —— 没设备显示具体 SN 没意义，
        # 还可能让人以为"程序已经准备好烧这个了"误导操作。
        self.next_var.set("SN：—")
        self.next_hint_var.set("")
        self._set_status("未连接", FG_DIM)
        self._emit("INFO", f"{say_what} {name}")
        self._update_connection_btns()
        self._update_lock_btn()

    #=================================================================
    # 操作
    #=================================================================
    def _require(self) -> bool:
        if self.busy:
            return False
        if self.device is None:
            messagebox.showwarning("未连接", "请先连接设备")
            return False
        return True

    def _probe_only(self) -> None:
        """刷新设备身份卡。连接成功 / 烧录完成后自动调，不暴露成按钮
        （用户反馈这个手动按钮没意义——连接时本来就会读一次）。"""
        if self.device is None:
            return
        self.busy = True
        threading.Thread(target=self._probe_worker, daemon=True).start()

    def _probe_worker(self) -> None:
        info, err = None, ""
        try:
            info = self.device.read_id()
        except (DeviceError, IOError) as e:
            err = str(e)
        except Exception as e:                      # noqa: BLE001
            err = f"{type(e).__name__}: {e}"
        self.result_q.put(("probe", info, err))

    def _show_info(self, info) -> None:
        self.last_info = info
        self.fields["imei"].set(info.imei or "—")
        self.fields["uid"].set(info.uid or "—")
        self.fields["sn"].set(info.sn or "(空)")
        self.fields["state"].set(info.state_cn)
        self.fields["lock"].set("已锁" if info.is_locked else "未锁")
        self._update_recover_visibility()
        self._update_lock_btn()
        # 返修弹窗开着的话，【手动开锁】+【抹去SN】按钮都要按最新设备状态决定
        # 显示/隐藏 —— 工人在弹窗里点开锁 / 抹号后，last_info 更新了，
        # 按钮就该消失；不更新就一直显示，点了也没意义（前置检查会拦）。
        self._update_rework_buttons()

    def _update_rework_buttons(self) -> None:
        """返修弹窗开着时，按 last_info 同步【手动开锁】+【抹去SN】两个按钮的
        pack/forget。弹窗没开或按钮 widget 不存在时静默返回。

        显隐规则（与设备侧协议对齐）：
          【手动开锁】= info.is_locked              （已锁才需要开）
          【抹去 SN】  = 有 SN 且 (未锁 或 是 invalid)
                ├─ state=ready + is_locked=True   → 隐藏（必须先开锁）
                ├─ state=ready + is_locked=False  → 显示
                ├─ state=invalid + is_locked=any  → 显示
                └─ state=empty                    → 隐藏

        pack 顺序：先 pack clear_sn(side="left") → 最左；再 pack
        manual_lock(side="left", padx=(0, 8)) → 紧贴 clear_sn 右侧。
        视觉左→右 = [抹去SN] [手动开锁]，与"放在【手动开锁】后面"的
        需求一致。
        """
        info = self.last_info

        # 1) 【抹去 SN】—— 视觉最左，先 pack
        cs = getattr(self, "rework_clear_sn_btn", None)
        if cs is not None and cs.winfo_exists():
            should_cs = (info is not None
                         and info.state in ("ready", "invalid")
                         and not (info.state == "ready" and info.is_locked))
            if should_cs:
                cs.pack(side="left")
            else:
                cs.pack_forget()

        # 2) 【手动开锁】—— 紧贴抹去 SN 右侧（在它右边）
        ml = getattr(self, "rework_manual_lock_btn", None)
        if ml is not None and ml.winfo_exists():
            should_ml = bool(info and info.is_locked)
            if should_ml:
                ml.pack(side="left", padx=(0, 8))
            else:
                ml.pack_forget()

    #=================================================================
    # SN 条码弹窗：两个按钮【条形码】【二维码】都打开 Toplevel。
    #   弹窗里：图 + SN 文字 + 【保存图片】【关闭】两个按钮
    #   保存 = 图 + SN 文字 + 四周白边，合成为一张图（不是只存图）
    #=================================================================
    def _open_barcode_popup(self, mode: str) -> None:
        sn = self.fields["sn"].get() if getattr(self, "fields", None) else ""
        if not sn or sn in ("—", "(空)"):
            messagebox.showinfo("提示", "当前没有 SN，请先连接设备并读取身份")
            return
        import _qrcode                                              # noqa: E402
        # 渲染图：1D 用 module=2 height=120；QR 用 module=8 quiet=4
        # module=8：17 位 SN 走 Version 2 (25×25 模块) → 264 px 正方形，
        # 扫码枪/手机在 30~50cm 距离仍能稳定识别；之前 module=4 太密，
        # 远一点或稍抖动就识别失败。
        img = _barcode.render(sn, module=2, height=120) if mode == "1D" \
              else _qrcode.render(sn, module=8, quiet=4)

        win = tk.Toplevel(self.root)
        win.title(f"SN {sn} - {'条形码' if mode == '1D' else '二维码'}")
        win.configure(bg="white")
        win.transient(self.root)
        # 弹窗左上角图标用 qrcode.png（内嵌 base64 优先，磁盘兜底）
        self._dialog_icon(win, "qrcode.png")
        # 图
        photo = ImageTk.PhotoImage(img.convert("RGB"))
        img_lbl = tk.Label(win, image=photo, bg="white", bd=0)
        img_lbl.image = photo                                        # 防 GC
        img_lbl.pack(padx=30, pady=(30, 8))
        # SN 文字，居中
        tk.Label(win, text=f"SN: {sn}", font=("Consolas", 16, "bold"),
                 bg="white", fg="black").pack(pady=(0, 16))
        # 保存按钮（弹窗用自带 X 关，不另加【关闭】）
        RoundedButton(win, text="保存图片", big=True, kind="primary",
                      command=lambda: self._save_popup_image(mode, sn, win)
                      ).pack(pady=(0, 24))
        # 居中弹窗
        win.update_idletasks()
        w, h = win.winfo_width(), win.winfo_height()
        sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
        win.geometry(f"+{(sw - w) // 2}+{(sh - h) // 2}")

    def _save_popup_image(self, mode: str, sn: str, win: tk.Toplevel) -> None:
        """合成最终图：图 + SN 文字 + 四周白边，写到用户选择的文件。
        成功/失败都用 messagebox 反馈，避免"按了没反应"的疑惑。
        parent 传弹窗本身，让 filedialog 焦点在弹窗上、不会被主窗口遮住。"""
        import _qrcode                                              # noqa: E402
        # 跟弹窗同款 module=8，保存出来的图跟屏幕显示一致
        img = _barcode.render(sn, module=2, height=120) if mode == "1D" \
              else _qrcode.render(sn, module=8, quiet=4)
        img = img.convert("RGB")
        iw, ih = img.size

        # 字体：优先 Consolas / 微软雅黑 / 默认
        font = None
        for fp in ("consola.ttf", "consolab.ttf",
                   "C:/Windows/Fonts/consola.ttf",
                   "C:/Windows/Fonts/msyh.ttc",
                   "C:/Windows/Fonts/msyh.ttf"):
            try:
                font = ImageFont.truetype(fp, 28)
                break
            except OSError:
                continue
        if font is None:
            font = ImageFont.load_default()

        # 量文字尺寸
        dummy = Image.new("RGB", (1, 1))
        d = ImageDraw.Draw(dummy)
        label = f"SN: {sn}"
        bbox = d.textbbox((0, 0), label, font=font)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]

        # 合成：上下白边 30，图与文字间距 16，文字与下白边 30
        m, gap = 30, 16
        final_w = max(iw, tw) + 2 * m
        final_h = m + ih + gap + th + m
        final = Image.new("RGB", (final_w, final_h), "white")
        # 图居中
        final.paste(img, ((final_w - iw) // 2, m))
        # 文字居中（抵消 bbox 偏移让视觉居中）
        tx = (final_w - tw) // 2 - bbox[0]
        ty = m + ih + gap - bbox[1]
        ImageDraw.Draw(final).text((tx, ty), label, fill="black", font=font)

        # 弹保存框：parent 传 win 防止 dialog 被主窗口挡住
        # 初始目录用 exe 所在目录，工人直接把图存到桌面/U 盘方便拷走
        initial_dir = str(Path(sys.executable).parent if getattr(sys, "frozen", False)
                          else Path(__file__).parent)
        path = filedialog.asksaveasfilename(
            parent=win,
            title="保存图片",
            defaultextension=".png",
            initialdir=initial_dir,
            initialfile=f"SN_{sn}_{mode}.png",
            filetypes=[("PNG", "*.png"), ("BMP", "*.bmp"),
                       ("JPEG", "*.jpg"), ("All", "*.*")])
        if not path:
            return
        low = path.lower()
        try:
            if low.endswith((".jpg", ".jpeg")):
                final.save(path, "JPEG", quality=95)
            elif low.endswith(".bmp"):
                final.save(path, "BMP")
            else:
                final.save(path, "PNG")
        except OSError as e:
            messagebox.showerror("保存失败", f"无法写入 {path}\n\n{e}", parent=win)
            return
        self._emit("OK", f"已保存: {path}")
        messagebox.showinfo("已保存", f"图片已保存到：\n{path}", parent=win)

    def _update_lock_btn(self) -> None:
        """【手动上锁】按钮的显示规则：
            已连接 + 设备有 SN + 未上锁 + 未在烧录中  →  显示
            任一不满足                                  →  隐藏（pack_forget）

        之前是 disable（灰显可点）作为禁用方式，跟工人沟通过后改成彻底隐藏：
        没有可点的活儿就别让工人琢磨为啥是灰的。看到按钮就知道"该补锁了"。

        ⚠️ 同步 disable：刚启动时 _build_ui 创建 lock_btn 默认 state=normal，
        启动调一次本函数时 device=None → hide，但 state 还是 normal —— 一旦有
        race（_lock_only 接到一个早先发的 event）按钮仍会响应。统一 disable
        让"按钮可见性"和"按钮可用性"严格同步。
        """
        if not hasattr(self, "lock_btn"):
            return
        info = self.last_info
        ok = (self.busy is False
              and self.device is not None
              and info is not None
              and info.state == "ready"
              and not info.is_locked)
        if ok:
            self.lock_btn.configure(state="normal")
        else:
            self.lock_btn.configure(state="disabled")
        mapped = bool(self.lock_btn.winfo_ismapped())
        if ok and not mapped:
            self.lock_btn.pack(side="right")
        elif not ok and mapped:
            self.lock_btn.pack_forget()

    #=================================================================
    # 手动上锁：补"自动上锁失败"或"故意不自动上锁"造成的"有 SN 但未锁"缺口
    #=================================================================
    def _lock_only(self) -> None:
        if self.busy:
            return
        if self.device is None:
            messagebox.showwarning("未连接", "请先连接设备")
            return
        if not self.last_info or self.last_info.is_locked:
            # 多一道保险：理论上按钮已被 _update_lock_btn 禁用，
            # 但 _update_lock_btn 在 on_disconnected 之后才会跑，
            # 中间这一瞬防御一下
            return
        # Q1: 工号必填（沿用界面上的输入框，返修/补烧/烧录都共用同一个）
        operator = self.operator_var.get().strip()
        if not operator:
            messagebox.showwarning("缺少工号", "请先填写操作员工号")
            self.operator_entry.focus_set()
            return
        self.busy = True
        self._update_lock_btn()
        self._emit("INFO", f"操作员 {operator} 请求手动上锁…")
        threading.Thread(target=self._lock_worker, args=(operator,),
                         daemon=True).start()

    def _lock_worker(self, operator: str) -> None:
        try:
            r = self.burner.lock_only(operator=operator)
        except (DeviceError, IOError) as e:
            self.result_q.put(("lock", None, f"{type(e).__name__}: {e}"))
            return
        except Exception as e:                       # noqa: BLE001
            self.result_q.put(("lock", None, f"{type(e).__name__}: {e}"))
            return
        self.result_q.put(("lock", r, ""))

    def _lock_done(self, r, err: str) -> None:
        self.busy = False
        if err:
            self._set_status("上锁失败", FAIL_RED)
            self._emit("FAIL", f"手动上锁失败: {err}")
            # 失败也要刷一次按钮状态（避免禁用状态卡住）
            self._probe_only()
            return
        if r is None or not r.ok:
            reason = r.reason_cn if r else "未知原因"
            self._set_status("上锁失败", FAIL_RED)
            self._emit("FAIL", f"手动上锁失败: {reason}")
            self._probe_only()
            return
        self._set_status("已上锁", OK_GREEN)
        # 成功也刷一次，让 UI（已锁/未锁 + 按钮启用状态）跟设备对齐
        self._probe_only()

    #=================================================================
    # 手动开锁：返修窗口用，把设备的烧录锁解开（lock=1 -> lock=0），
    # 不改 SN、不动台账。发 UNLOCK:SN 命令（device.unlock()）。
    #=================================================================
    def _unlock_only(self) -> None:
        if self.busy:
            return
        if self.device is None:
            messagebox.showwarning("未连接", "请先连接设备")
            return
        info = self.last_info
        if info is None:
            messagebox.showwarning("设备未就绪", "还没读到设备信息，请稍候")
            return
        if info.state != "ready":
            messagebox.showwarning("设备还没有 SN",
                                   f"当前状态: {info.state_cn or '未知'}。"
                                   "\nUNLOCK:SN 需要设备已烧录。")
            return
        if not info.is_locked:
            messagebox.showinfo("已是未锁状态", "该设备未锁，无需重复开锁。")
            return
        # 工号校验沿用界面上同一个输入框（返修流程前已经填过）
        operator = self.operator_var.get().strip()
        if not operator:
            messagebox.showwarning("缺少工号", "请先填写操作员工号")
            self.operator_entry.focus_set()
            return
        self.busy = True
        self._emit("INFO", f"操作员 {operator} 请求手动开锁…")
        threading.Thread(target=self._unlock_worker, args=(operator,),
                         daemon=True).start()

    def _unlock_worker(self, operator: str) -> None:
        try:
            r = self.burner.unlock_only(operator=operator)
        except (DeviceError, IOError) as e:
            self.result_q.put(("unlock", None, f"{type(e).__name__}: {e}"))
            return
        except Exception as e:                       # noqa: BLE001
            self.result_q.put(("unlock", None, f"{type(e).__name__}: {e}"))
            return
        self.result_q.put(("unlock", r, ""))

    def _unlock_done(self, r, err: str) -> None:
        self.busy = False
        if err:
            self._set_status("开锁失败", FAIL_RED)
            self._emit("FAIL", f"手动开锁失败: {err}")
            self._probe_only()
            return
        if r is None or not r.ok:
            reason = r.reason_cn if r else "未知原因"
            self._set_status("开锁失败", FAIL_RED)
            self._emit("FAIL", f"手动开锁失败: {reason}")
            self._probe_only()
            return
        self._set_status("已开锁", OK_GREEN)
        # 成功也刷一次，让 UI（已锁/未锁 + 按钮启用状态）跟设备对齐
        self._probe_only()

    #=================================================================
    # 抹去 SN：把设备侧 fskv 的 SN 键删掉（C:SN），不动台账
    #=================================================================
    def _clear_sn_only(self) -> None:
        """返修弹窗【抹去 SN】按钮回调：发 C:SN 抹号。

        与 _unlock_only 是镜像（同属"辅助动作"，不分配号、不写 SN、不动台账），
        区别在最终一拍：unlock 解锁标志位，clear_sn 删 fskv 的 K_SN。

        前置检查：unlock_only 的同款前置 + 一个"locked+ready 必须先开锁"的
        友好提示（设备侧也会拒，但用 PC 端 warning 让工人一眼看到原因）。
        """
        if self.busy:
            return
        if self.device is None:
            messagebox.showwarning("未连接", "请先连接设备")
            return
        info = self.last_info
        if info is None:
            messagebox.showwarning("设备未就绪", "还没读到设备信息，请稍候")
            return
        # 设备侧前置：locked + state=ready 拒。先提示工人"先开锁"，比
        # 让 round-trip 跑一圈拿回 "locked" 字符串更直接。
        if info.state == "ready" and info.is_locked:
            messagebox.showwarning("设备已锁",
                                   "当前设备已锁且有有效 SN，需先【手动开锁】"
                                   "再【抹去 SN】。")
            return
        # state=empty 时 PC 端先告诉工人"已是未烧状态"，省一次 round-trip
        # （设备侧会幂等通过，但日志里"刷了一行 RET:OK"也是浪费）
        if info.state == "empty":
            messagebox.showinfo("已是未烧状态",
                                "该设备当前无 SN，无需抹号。\n"
                                "如要烧新号，请直接走主流程【烧写 SN】。")
            return
        # 工号校验沿用界面上同一个输入框
        operator = self.operator_var.get().strip()
        if not operator:
            messagebox.showwarning("缺少工号", "请先填写操作员工号")
            self.operator_entry.focus_set()
            return
        self.busy = True
        self._emit("INFO", f"操作员 {operator} 请求抹去 SN…")
        threading.Thread(target=self._clear_sn_worker, args=(operator,),
                         daemon=True).start()

    def _clear_sn_worker(self, operator: str) -> None:
        try:
            r = self.burner.clear_sn_only(operator=operator)
        except (DeviceError, IOError) as e:
            self.result_q.put(("clear_sn", None, f"{type(e).__name__}: {e}"))
            return
        except Exception as e:                       # noqa: BLE001
            self.result_q.put(("clear_sn", None, f"{type(e).__name__}: {e}"))
            return
        self.result_q.put(("clear_sn", r, ""))

    def _clear_sn_done(self, r, err: str) -> None:
        self.busy = False
        if err:
            self._set_status("抹号失败", FAIL_RED)
            self._emit("FAIL", f"手动抹号失败: {err}")
            self._probe_only()
            return
        if r is None or not r.ok:
            reason = r.reason_cn if r else "未知原因"
            self._set_status("抹号失败", FAIL_RED)
            self._emit("FAIL", f"手动抹号失败: {reason}")
            self._probe_only()
            return
        self._set_status("已抹号", OK_GREEN)
        # 成功也刷一次，让 UI（SN 字段、按钮启用状态）跟设备对齐
        self._probe_only()

    #=================================================================
    # 补烧：把台账里该设备的旧 SN 写回去（重刷固件丢号场景）
    #=================================================================
    def _recover_burn(self) -> None:
        if not self._require():
            return
        if not self.recover_sn:
            return
        # Q1: 工号不能为空
        operator = self.operator_var.get().strip()
        if not operator:
            messagebox.showwarning("缺少工号", "请先填写操作员工号")
            self.operator_entry.focus_set()
            return
        sn = self.recover_sn
        if not messagebox.askyesno(
                "补烧确认",
                f"设备当前没有 SN。\n将把该设备原编号 {sn} 补烧回去，"
                f"不会分配新号。\n确认继续？"):
            return
        self.busy = True
        self.burn_btn.configure(state="disabled")
        self.recover_btn.configure(state="disabled")
        self.result_lbl.configure(text="补烧中…", fg=FG_DIM)
        threading.Thread(target=self._recover_worker, args=(sn, operator),
                         daemon=True).start()

    def _recover_worker(self, sn: str, operator: str) -> None:
        r = None
        try:
            r = self.burner.recover(sn, operator=operator)
        except Exception as e:                      # noqa: BLE001
            self._emit("FAIL", f"异常: {type(e).__name__}: {e}")
            r = BurnResult(ok=False, reason=str(e))
        self.result_q.put(("burn", r, ""))

    def _burn(self) -> None:
        if not self._require():
            return
        # Q1: 工号不能为空——没有工号就无法追溯是谁烧的
        operator = self.operator_var.get().strip()
        if not operator:
            messagebox.showwarning("缺少工号", "请先填写操作员工号")
            self.operator_entry.focus_set()
            return
        if self.cfg.confirm_before_write:
            if not messagebox.askyesno("确认烧录", "确认写入 SN？"):
                return
        self.busy = True
        self.burn_btn.configure(state="disabled")
        self.result_lbl.configure(text="烧录中…", fg=FG_DIM)
        threading.Thread(target=self._burn_worker,
                         args=(operator, False), daemon=True).start()

    def _rework(self) -> None:
        if not self._require():
            return
        # Q1: 工号不能为空
        operator = self.operator_var.get().strip()
        if not operator:
            messagebox.showwarning("缺少工号", "请先填写操作员工号")
            self.operator_entry.focus_set()
            return
        # Q2: 返修要密码。返修会解锁并强制改写 SN，风险高于正常烧录。
        # 第一步弹密码窗（lock-password.png 图标），密码对了才进返修参数窗。
        pwd = self._ask_password()
        if pwd is None:
            return
        if pwd != self.cfg.rework_password:
            messagebox.showerror("密码错误", "返修密码不正确")
            self._emit("WARN", "返修密码错误，已拒绝")
            return
        # 第二步：返修参数（日期/流水号/生成SN/预览），bug.png 图标。
        # 返回 True 表示点了【确定】继续；False 表示取消。
        if not self._ask_rework():
            return
        if not messagebox.askyesno(
                "返修确认",
                "返修会【解锁】并强制改写 SN，该设备原有编号将作废。\n确认继续？"):
            return
        # 读弹窗里工人填的日期/流水号。不走 _apply_overrides / set_manual_serial_start：
        # 那是改 alloc.counter 的，会污染主流程 next_var。返修走 allocate_specific()
        # 单独查 ledger.has_sn()，counter 不动。
        manual_serial_txt = self.serial_var.get().strip()
        manual_date = self.date_var.get().strip() or None
        manual_serial = None
        if manual_serial_txt:
            try:
                manual_serial = int(manual_serial_txt)
            except ValueError:
                messagebox.showwarning("起始号无效",
                                       "起始流水号必须是数字")
                return
        self.busy = True
        self.burn_btn.configure(state="disabled")
        self.result_lbl.configure(text="返修中…", fg=FG_DIM)
        threading.Thread(target=self._burn_worker,
                         args=(operator, True, manual_serial, manual_date),
                         daemon=True).start()

    def _ask_password(self) -> str | None:
        """返修第一步：弹密码窗（lock-password.png 图标）。
        返回密码字符串；取消返回 None。
        """
        return self._modal_input(
            title="返修密码",
            ico_name="lock-password.png",
            body=self._build_password_body,
            result_key="pwd",
        )

    def _ask_rework(self) -> bool:
        """返修第二步：弹返修窗口（日期/流水号/生成SN/预览，bug.png 图标）。
        返回 True = 用户点了【写新SN】；False = 取消 / 点了【手动开锁】。
        """
        return self._modal_input(
            title="返修",
            ico_name="bug.png",
            body=self._build_rework_body,
            result_key="ok",
        )

    def _modal_input(self, *, title, ico_name, body, result_key):
        """通用模态弹窗：图标 + body 构造器 + 居中 + wait_window。
        body(win, frame, ok, cancel) 在弹窗框架内填内容；
        调 ok(key, value) 关闭弹窗并设返回值；返回 result[key] 或 None。
        """
        win = tk.Toplevel(self.root)
        win.title(title)
        win.resizable(False, False)
        win.transient(self.root)
        win.grab_set()
        win.configure(bg=CARD)

        # 左上角图标（仓库根的 png，内嵌 base64 优先，磁盘兜底）
        self._dialog_icon(win, ico_name)

        f = tk.Frame(win, bg=CARD, padx=16, pady=16)
        f.pack(fill="both", expand=True)

        result: dict = {}
        def ok(key, value):
            result[key] = value
            win.destroy()
        def cancel():
            win.destroy()

        body(win=win, frame=f, ok=ok, cancel=cancel)

        # 屏幕居中
        win.update_idletasks()
        w, h = win.winfo_width(), win.winfo_height()
        sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
        win.geometry(f"{w}x{h}+{max(0, (sw - w) // 2)}+{max(0, (sh - h) // 2)}")

        self.root.wait_window(win)
        return result.get(result_key)

    def _build_password_body(self, *, win, frame, ok, cancel) -> None:
        """密码窗内容：返修密码 + 确定/取消。"""
        f = frame
        ttk.Label(f, text="返修密码", style="Dim.TLabel").pack(anchor="w")
        var = tk.StringVar()
        entry = RoundedEntry(f, textvariable=var, show="•", width=24)
        entry.pack(pady=(4, 12), fill="x")

        def submit():
            ok("pwd", var.get())

        btns = tk.Frame(f, bg=CARD)
        btns.pack(fill="x")
        RoundedButton(btns, text="确定", kind="primary", command=submit).pack(side="right")
        RoundedButton(btns, text="取消", kind="secondary", command=cancel).pack(
            side="right", padx=(0, 8))
        win.bind("<Return>", lambda e: submit())
        win.bind("<Escape>", lambda e: cancel())
        entry.focus_set()

    def _build_rework_body(self, *, win, frame, ok, cancel) -> None:
        """返修窗口内容：日期 + 起始号 + 生成SN + 预览 + 写新SN/手动开锁。

        之前有【指定日期】复选框：勾上才放开日期框。复选让两个状态分叉
        （勾 vs 不勾），工人经常困惑——勾错了日期框又是灰的；不勾又
        看不到日期到底是什么。

        现在去复选框：日期和起始号都是"默认手动填"。
            - 弹窗打开时预填当天日期（要改就自己改）
            - 起始号永远是空，工人按需填
            - 烧录下一台（主流程）不在此弹窗里，永远用当天日期，跟
              返修窗口里的 date_var 解耦（_apply_overrides 现在按"date_var
              实际有没有值"判断，不用勾选）
        """
        f = frame
        # 弹窗打开时预填当天日期（之前是勾【指定日期】时才预填）。
        # 不预填的话工人还得先想起今天几号，特别是补录别的日期场景下
        # 反而成"我就想用今天的"。
        if not self.date_var.get().strip():
            from datetime import datetime as _dt            # noqa: E402
            self.date_var.set(_dt.now().strftime("%Y%m%d"))
        # 起始号留空：返修场景就是"我手动指定第 N 台"，永远让工人填。

        # 日期 + 起始号 + 生成SN
        ov = tk.Frame(f, bg=CARD)
        ov.pack(fill="x", pady=(0, 4))
        ttk.Label(ov, text="日期", style="Dim.TLabel").pack(side="left")
        self.date_entry = RoundedEntry(ov, textvariable=self.date_var, width=12)
        self.date_entry.pack(side="left", padx=(6, 0))
        # 弹窗内的回调只刷弹窗内预览，不动 alloc —— alloc 由 submit() 关弹窗前
        # 才统一传给 burner.rework 用。弹窗开着改 date/serial 不能影响主界面
        # 准备烧的号（之前用 _on_date_return / _on_serial_return 会通过
        # _apply_overrides 改 alloc，导致主界面 next_var 跟着跳）。
        self.date_entry.bind("<Return>", self._on_rework_date_return)
        self.date_entry.bind("<FocusOut>", self._on_rework_date_return)
        ttk.Label(ov, text="  起始号", style="Dim.TLabel").pack(side="left", padx=(8, 0))
        self.serial_entry = RoundedEntry(ov, textvariable=self.serial_var, width=12)
        self.serial_entry.pack(side="left", padx=(6, 0))
        self.serial_entry.bind("<Return>", self._on_rework_serial_return)
        self.serial_entry.bind("<FocusOut>", self._on_rework_serial_return)
        # 【生成SN】宽度基准：写新SN/手动开锁 都跟它同宽 (width=6)
        # 预览写独立的 StringVar —— 不与主界面 next_var 共享，避免点【生成SN】
        # 把主界面"准备烧的号"也覆盖掉。
        self.rework_preview_var = tk.StringVar(value="")
        self.rework_hint_var = tk.StringVar(value="")
        RoundedButton(ov, text="生成SN", kind="primary", width=6,
                      command=lambda: self._on_gen_sn(
                          self.rework_preview_var, self.rework_hint_var)
                      ).pack(side="left", padx=(10, 0))

        # SN 预览（用独立的 var，不与主界面 next_var 联动）
        ttk.Label(f, textvariable=self.rework_preview_var,
                  style="Big.TLabel").pack(anchor="center", pady=(8, 12))
        ttk.Label(f, textvariable=self.rework_hint_var,
                  style="Dim.TLabel").pack(anchor="center")

        def submit():
            # 关弹窗：日期/流水号由 _rework 读 date_var/serial_var 传给
            # burner.rework(manual_serial, manual_date)，不走 alloc。
            # 这样 alloc.counter 不会被返修污染，主界面"下一号预览"保持稳定。
            ok("ok", True)

        def manual_lock():
            # 【手动开锁】= 把设备的烧录锁解开（lock=1 -> lock=0，发 UNLOCK:SN），
            # 不烧新号、不改 SN、不动台账 —— 工人下一步还要【写新SN】呢。
            # 不关返修窗口 —— 工人可能想"开了之后立刻写新 SN"。
            #
            # 前置检查：UNLOCK:SN 的设备端前置条件是 "locked"，没锁发过去设备
            # 会回 RET:FAIL:not locked。提前在 PC 端给明确报错，省得看到
            # 一行设备应答日志还要反推"为啥拒了"。
            info = self.last_info
            if self.device is None:
                messagebox.showwarning("未连接", "请先连接设备")
                return
            if info is None:
                messagebox.showwarning("设备未就绪", "还没读到设备信息，请稍候")
                return
            if info.state != "ready":
                messagebox.showwarning("设备还没有 SN",
                                       f"当前状态: {info.state_cn or '未知'}。"
                                       "\n开锁前请先【写新SN】。")
                return
            if not info.is_locked:
                messagebox.showinfo("已是未锁状态", "该设备未锁，无需重复开锁。"
                                    "\n如要改 SN，请直接【写新SN】。")
                return
            self.root.after(50, self._unlock_only)

        def clear_sn():
            # 【抹去 SN】= 把设备侧 fskv 的 SN 键删掉（发 C:SN），不动台账。
            # 用途：返修场景里工人想让一台"已废但别处叫"的设备回到未烧
            # 状态（state=empty），下一步可以重新烧新号（走主流程【烧写 SN】）。
            # 不关返修窗口 —— 工人可能想"抹完再立刻生成新号烧"。
            # 设备侧前置：locked + state=ready 拒（必须先开锁）；其他都允许；
            # state=empty 幂等通过。PC 端 _clear_sn_only 已拦前三类，剩
            # empty 也在 _clear_sn_only 里提前 messagebox 拦截。
            self.root.after(50, self._clear_sn_only)

        btns = tk.Frame(f, bg=CARD)
        btns.pack(fill="x")
        # 布局：左侧辅助操作（【抹去 SN】【手动开锁】按需显隐），
        #      右侧主操作（【写新 SN】恒在）。中间用 expand spacer 撑开，
        #      "辅助 vs 主" 在视觉上分两块，不再是塞在【写新 SN】左侧挨着。
        # 为什么改：之前三个 secondary 按钮贴在【写新 SN】左侧，工人一眼
        # 看去全是按钮，误以为【手动开锁】也是"主操作"——其实是改 SN 之前
        # 的辅助步骤。分开后左/右清楚区分"准备动作 / 提交动作"。
        #
        # pack 顺序：先 pack 写新SN（贴右缘）+ 中间 spacer（吃满），再创建
        # 左侧两个按钮（不预 pack，由 _update_rework_buttons 决定显隐，
        # 且按 _update_rework_buttons 内的顺序 pack(side="left")，让视觉
        # 顺序从左到右 = [抹去SN] [手动开锁]）。
        RoundedButton(btns, text="写新SN", kind="primary", width=6,
                      command=submit).pack(side="right")
        # 中间 expand spacer：把左右两组顶到两端
        tk.Frame(btns, bg=CARD).pack(side="left", expand=True, fill="x")

        # 创建两个辅助按钮（不预 pack；_update_rework_buttons 控制显隐）
        manual_lock_btn = RoundedButton(btns, text="手动开锁", kind="secondary",
                                        width=6, command=manual_lock)
        self.rework_manual_lock_btn = manual_lock_btn
        clear_sn_btn = RoundedButton(btns, text="抹去SN", kind="secondary",
                                     width=6, command=clear_sn)
        self.rework_clear_sn_btn = clear_sn_btn
        self._update_rework_buttons()
        # 返修窗口关闭 = 用窗口原生关闭（X 按钮 / Alt+F4）。
        # 不再有【取消】按钮，关窗就是取消；写新 SN 也算关。
        # 弹窗关闭（无论是 X、Esc、Return、还是 submit/cancel 路径）后清掉
        # self.rework_*_btn 引用，否则下次 _show_info 还会拿旧
        # widget 操作（widget 已 destroyed，winfo_exists() 会拦住但留着没意义）。
        def _cleanup():
            self.rework_manual_lock_btn = None
            self.rework_clear_sn_btn = None
        win.protocol("WM_DELETE_WINDOW", lambda: (cancel(), _cleanup()))
        win.bind("<Return>", lambda e: (submit(), _cleanup()))
        win.bind("<Escape>", lambda e: (cancel(), _cleanup()))

    def _burn_worker(self, operator: str, rework: bool,
                  manual_serial: Optional[int] = None,
                  manual_date: Optional[str] = None) -> None:
        self.cfg.operator = operator
        r = None
        try:
            if rework:
                r = self.burner.rework(operator=operator,
                                       manual_serial=manual_serial,
                                       manual_date=manual_date)
            else:
                r = self.burner.burn(operator=operator)
        except Exception as e:                      # noqa: BLE001
            self._emit("FAIL", f"异常: {type(e).__name__}: {e}")
            r = BurnResult(ok=False, reason=str(e))
        self.result_q.put(("burn", r, ""))

    def _burn_done(self, r: BurnResult) -> None:
        self.busy = False                 # 先解锁，末尾的探测才起得来
        self.burn_btn.configure(state="normal")
        self.recover_btn.configure(state="normal")   # 由 _update_recover_visibility 再判
        self._refresh_next()

        if r.ok:
            self.session["ok"] += 1
            self.fail_streak = 0
            self.result_lbl.configure(text=f"✓ {r.sn}", fg=OK_GREEN)
            self._beep()
            # 注意：这里【不】读也不写 MQTT 接入信息。
            # MQTT 那三项已改成独立【保存】按钮提交，与 SN 烧录解耦；
            # 若在这里再打一行，工人会以为烧录时把它一起写进设备了。
        else:
            self.session["fail"] += 1
            self.fail_streak += 1
            self.result_lbl.configure(text=f"✗ {r.reason_display}", fg=FAIL_RED)
            if self.fail_streak >= 3:
                self._emit("WARN", f"连续失败 {self.fail_streak} 次，请检查接线/设备")

        self.stat_var.set(f"本次: 成功 {self.session['ok']}   "
                          f"失败 {self.session['fail']}")
        if self.alloc:
            st = self.alloc.ledger.stats()
            self._emit("DIM", f"台账累计: {st['ok']} 成功 / {st['fail']} 失败 / "
                              f"{st['rework']} 返修")

        # 刷新身份卡：仍走线程 + 队列，不在主线程里做阻塞串口读
        if self.device is not None:
            self._probe_only()

    def _beep(self) -> None:
        try:
            self.root.bell()
        except tk.TclError:
            pass

    #=================================================================
    def _on_close(self) -> None:
        try:
            self.cfg.operator = self.operator_var.get().strip()
            cfg_mod.save_config(self.cfg)
        except OSError:
            pass
        # 补写之前写盘失败的台账记录（比如当时 ledger.csv 被 Excel 占着）
        if self.alloc is not None:
            try:
                n = self.alloc.ledger.flush_pending()
                if n:
                    self._emit("OK", f"已补写 {n} 条台账记录")
            except Exception:                       # noqa: BLE001
                pass
        if self.port is not None:
            self.port.close()
        self.root.destroy()


def main() -> None:
    # 全局异常钩子：tkinter 里任何未捕获异常都不能让窗口"静默退出"。
    # 产线上最怕的就是软件莫名消失，工人不知道发生了什么。
    import traceback

    def excepthook(exc_type, exc, tb):
        detail = "".join(traceback.format_exception(exc_type, exc, tb))
        try:
            messagebox.showerror("程序出错", f"{exc}\n\n{detail}")
        except Exception:                        # noqa: BLE001
            pass
        try:
            # 必须用绝对路径：打包后 cwd 是 %TEMP%\_MEIxxxx，
            # 相对路径会把崩溃日志写进临时目录，现场根本找不到
            with open(cfg_mod.app_path("crash.log"), "a", encoding="utf-8") as f:
                f.write(detail + "\n")
        except OSError:
            pass

    import sys
    sys.excepthook = excepthook

    # 线程里的异常默认只打印到 stderr，窗口照样看似正常但功能失效
    def thread_excepthook(args):
        excepthook(args.exc_type, args.exc_value, args.exc_traceback)

    threading.excepthook = thread_excepthook

    root = tk.Tk()
    SnBurnerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
