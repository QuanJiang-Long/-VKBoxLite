"""核对本轮 UI 改动的几何/行为，跑完即删式的一次性脚本。

不并入 build.ps1：这里的断言依赖窗口真实布局，冒烟测试已覆盖主要路径。
"""

import os
import sys
import tkinter as tk

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from ui_app import SnBurnerApp          # noqa: E402
from sn_rule import SnRule as _R        # noqa: E402

_rule = _R()  # 用默认 SnRule (prefix=VL serial_digits=3)


def self_make(date, serial):
    """独立算一遍期望值，避免把测试写死成某个可能猜错的校验位。"""
    return _rule.make(serial, date)


fails = []


def check(cond, msg):
    print(("  OK   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


def find_btn(root, text):
    """按按钮文字找控件。兼容 ttk.Button (TButton) 和 RoundedButton (Canvas)。"""
    out = []

    def walk(w):
        for c in w.winfo_children():
            try:
                if c.winfo_class() == "TButton" and c.cget("text") == text:
                    out.append(c)
                # RoundedButton 是 tk.Canvas，按 _text 字段匹配
                if c.winfo_class() == "Canvas" and getattr(c, "_text", None) == text:
                    out.append(c)
            except Exception:                       # noqa: BLE001
                pass
            walk(c)
    walk(root)
    return out[0] if out else None


root = tk.Tk()
root.withdraw()
app = SnBurnerApp(root)
root.update()

# --- 端口下拉：只列电脑实际有的口 ---
vals = list(app.port_cb["values"])
check(vals[0] == "请选择串口", f"第一项是请选择串口: {vals[0]!r}")
from serial_port import list_ports as _lp          # noqa: E402
real = _lp()
check(vals == ["请选择串口"] + real,
      f"下拉 == 请选择串口 + 实际有的口（{len(real)} 个: {real}），"
      f"实际 {len(vals)} 项")
check(len(vals) <= 20, f"不再把 COM1~COM256 全列出来，共 {len(vals)} 项")
check("COM256" not in vals, "COM256 不在下拉里（本机没有这个口）")

# --- 今天 按钮已删除；【生成SN】已挪到【返修】弹窗，主界面只剩【保存】【返修】 ---
save = find_btn(root, "保存")
rework = find_btn(root, "返修")
check(find_btn(root, "今天") is None, "【今天】按钮已删除")
check(find_btn(root, "生成SN") is None, "【生成SN】已不在主界面（在返修弹窗里）")
check(save is not None, "找到【保存】按钮")
check(rework is not None, "找到【返修】按钮")
if save and rework:
    root.update()
    ws, wr = save.winfo_width(), rework.winfo_width()
    # 返修是 big=True + 自然宽度，跟普通按钮宽度差异在合理范围即可
    check(20 < ws < 600 and 20 < wr < 600,
          f"保存/返修 宽度在合理范围: save={ws} rework={wr}")

# --- SN： 预览 ---
# 没设备时 next_var = "SN：—"（破折号占位），连接后才刷新成具体号 —— 见
# _teardown_connection / _connect_done。模拟一下"连接 + refresh"才能
# 验证 alloc.preview() 真的把号拼出来了。
check(app.next_var.get() == "SN：—",
      f"未连接时 next_var 占位: {app.next_var.get()!r}")
app._refresh_next()
root.update()
check(app.next_var.get().startswith("SN："),
      f"refresh 后下一号预览带 SN： 前缀: {app.next_var.get()!r}")

# --- 日期/流水号 / 【生成SN】已挪到【返修】弹窗（见 _ask_rework）。
# 主流程（烧录下一台）不在此弹窗里，date_var/serial_var 留空，
# 烧录永远按 alloc 自动按当天日期发号。返修弹窗打开会预填当天到 date_var。
# 【指定日期】复选框已删：现在按 date_var 实际有没有值判断用手动 / 默认。
check(app.date_var.get() == "", f"默认 date_var 空: {app.date_var.get()!r}")
check(app.serial_var.get() == "", f"默认 serial_var 空: {app.serial_var.get()!r}")
check(app.next_var.get() == f"SN：{app.alloc.preview()}",
      f"默认预览按当天日期自动生成: {app.next_var.get()!r}")

# --- 生成SN：只预览，不占计数器 ---
# 弹窗里的 _on_gen_sn 现在接收目标 StringVar（避免覆盖主界面 next_var），
# 直接调用验证函数行为。
import tkinter as _tk                                          # noqa: E402
_test_target = _tk.StringVar(value="")
_test_hint = _tk.StringVar(value="")
app.date_var.set("20260101")
app.serial_var.set("77")
app._apply_overrides()
root.update()
# 记下当前主界面 next_var（之前 _refresh_next 写入的 alloc.preview()），
# 后面用来验证"生成 SN 不影响主界面"。
_next_before_gen = app.next_var.get()
before = app.alloc.peek()
app._on_gen_sn(_test_target, _test_hint)
root.update()
after = app.alloc.peek()
check(before == after, f"生成SN 不占计数器: {before} -> {after}")
check(_test_target.get() == "SN：" + self_make("20260101", 77),
      f"按 20260101 + 77 生成（写入传入 var）: {_test_target.get()!r}")
check("未占用计数器" in _test_hint.get(),
      f"提示说明未占用: {_test_hint.get()!r}")
# 不影响主界面 next_var —— 这是任务 5 的关键
check(app.next_var.get() == _next_before_gen,
      f"主界面 next_var 不被覆盖: 之前={_next_before_gen!r} "
      f"之后={app.next_var.get()!r}")

# --- 生成SN 后，清掉 overrides 预览恢复正常 ---
app.date_var.set("")
app.serial_var.set("")
app._apply_overrides()
app._refresh_next()
root.update()
check(app.next_var.get() == f"SN：{app.alloc.preview()}",
      f"清掉覆盖后预览恢复正常: {app.next_var.get()!r}")

# --- 非法流水号要拦住，不能崩 ---
# showwarning 是模态弹窗，headless 下会卡死整个脚本；patch 成 no-op。
# 不影响功能验证 —— 我们要看的是"不崩 + 预览不被改坏 + 弹了一次警告"。
import tkinter.messagebox as _mb                # noqa: E402
_warn_calls: list = []
_orig_warn = _mb.showwarning
_mb.showwarning = lambda *a, **k: _warn_calls.append(a)
app.date_var.set("20260101")
app.serial_var.set("abc")
good = app.next_var.get()
try:
    app._on_gen_sn(_test_target, _test_hint)
    crashed = False
except Exception as e:                            # noqa: BLE001
    crashed = True
    print(f"    异常: {e}")
check(not crashed, "非法流水号不抛异常")
check(_test_target.get() == "SN：" + self_make("20260101", 77),
      f"非法流水号不污染传入 var: {_test_target.get()!r}")
check(len(_warn_calls) == 1 and "流水号" in (_warn_calls[0][1] or ""),
      f"非法输入应弹一次警告（消息体含'流水号'）: {_warn_calls}")
_mb.showwarning = _orig_warn
app.serial_var.set("")
app.date_var.set("")
app._apply_overrides()

# --- 卡片顺序：串口 设备身份 SN查询 烧录 MQTT接入 日志 ---
titles = []


def walk(w):
    for c in w.winfo_children():
        try:
            if c.winfo_class() == "TLabel" and "Title" in str(c.cget("style")):
                titles.append(c.cget("text"))
        except Exception:                           # noqa: BLE001
            pass
        walk(c)


walk(root)
want = ["串口", "设备身份", "SN 查询", "烧录", "MQTT 接入", "日志"]
check(titles == want, f"卡片顺序 = {want}，实际 {titles}")

# --- MQTT 控件确实在自己卡片里，不在烧录卡片里 ---
mq_host_master = app.mq_host_entry if hasattr(app, "mq_host_entry") else None
burn_master = app.burn_btn.master
check(app.mq_pass_entry.master is not burn_master,
      "MQTT 密码框与烧录按钮不在同一个父容器里")

# --- 【手动上锁】按钮存在 + 启用规则 ---
from device import DeviceInfo                     # noqa: E402

lock_btn = getattr(app, "lock_btn", None)
check(lock_btn is not None, "存在【手动上锁】按钮")
if lock_btn is not None:
    # 初始：未连设备，无需上锁 → 按钮隐藏
    check(not bool(lock_btn.winfo_ismapped()),
          f"未连设备时【手动上锁】隐藏: mapped={lock_btn.winfo_ismapped()}")

    # 模拟连上 + 设备有 SN + 未上锁 -> 显示
    class _StubPort:
        is_open = True
        def still_alive(self): return True
    app.port = _StubPort()
    app.device = object()                                          # burner 才用
    class _StubBurner: pass
    app.burner = _StubBurner()
    app.busy = False
    app.last_info = DeviceInfo(imei="86", uid="uid", sn="11802026092500018",
                              state="ready", lock=0)
    app._update_lock_btn()
    root.update()
    check(bool(lock_btn.winfo_ismapped()),
          f"有 SN + 未锁 + 未烧录 -> 显示: mapped={lock_btn.winfo_ismapped()}")

    # 设备已锁 -> 隐藏
    app.last_info.lock = 1
    app._update_lock_btn()
    root.update()
    check(not bool(lock_btn.winfo_ismapped()),
          f"设备已锁时隐藏: mapped={lock_btn.winfo_ismapped()}")

    # 设备没 SN (state=empty) -> 隐藏
    app.last_info = DeviceInfo(imei="86", uid="uid", sn="",
                              state="empty", lock=0)
    app._update_lock_btn()
    root.update()
    check(not bool(lock_btn.winfo_ismapped()),
          f"没 SN 时隐藏: mapped={lock_btn.winfo_ismapped()}")

    # 在烧录中 (busy) -> 隐藏
    app.last_info = DeviceInfo(imei="86", uid="uid", sn="11802026092500018",
                              state="ready", lock=0)
    app.busy = True
    app._update_lock_btn()
    root.update()
    check(not bool(lock_btn.winfo_ismapped()),
          f"烧录中隐藏: mapped={lock_btn.winfo_ismapped()}")

    # busy=False 恢复 -> 显示
    app.busy = False
    app._update_lock_btn()
    root.update()
    check(bool(lock_btn.winfo_ismapped()),
          f"busy 恢复后重新显示: mapped={lock_btn.winfo_ismapped()}")

    # 按钮文本是【手动上锁】
    check(lock_btn.cget("text") == "手动上锁",
          f"按钮文本: {lock_btn.cget('text')!r}")

    # 与「烧录后自动上锁」是不同控件 —— 不能把它替换了
    auto_lock_cb = app.auto_lock_var
    check(hasattr(app, "auto_lock_var"),
          "原有的「烧录后自动上锁」复选框仍存在")
    check(isinstance(auto_lock_cb, tk.BooleanVar),
          f"auto_lock_var 仍是 BooleanVar: {type(auto_lock_cb)}")

    # 手动把内部状态复位成未连 -> 验证 _update_lock_btn 把它隐藏
    # 不走 _teardown_connection 完整流程：它会调 port.close()，
    # 测试用的 _StubPort 没真的串口关不掉，路径不一样。
    app.port = None
    app.device = None
    app.burner = None
    app.busy = False
    app.last_info = None
    app._update_lock_btn()
    root.update()
    check(not bool(lock_btn.winfo_ismapped()),
          f"未连设备时隐藏: mapped={lock_btn.winfo_ismapped()}")

# --- 【工号】搬到顶栏，位置醒目 ---
op_entry = app.operator_entry
check(op_entry.master is app.port_cb.master,
      "工号输入框与端口下拉在同一个父容器（顶栏）")
# 工号 Entry 不在烧录卡片的父容器里
op_in_burn = any(w is op_entry for w in app.burn_btn.master.winfo_children())
check(not op_in_burn, "工号输入框不在烧录卡片的父容器里")
# 初始值来自 cfg.operator
check(op_entry.get() == app.cfg.operator,
      f"工号初始值取自 cfg.operator: {op_entry.get()!r}")

# --- 主界面剩余输入框统一 width=16 ---
# 日期/流水号已挪到返修弹窗（_ask_password 里现建现用），
# 主界面只剩 3 个 MQTT 输入框需要 width 检查。
want_width = 16
# 服务器/端口/凭证密码：从 mqtt_write_btn 往根找，找到【MQTT 接入卡片】（mq
# 容器，里面有 mqbtnrow + mqrow 两行子 frame）。RoundedEntry（Canvas +
# 内嵌 tk.Entry）只在这两个子 frame 里。
mq_card = app.mqtt_write_btn.master.master
mq_entries = []
def _scan_mq(parent):
    for c in parent.winfo_children():
        # RoundedEntry 是 Canvas，包含内嵌的 tk.Entry；按 Canvas class 找
        if c.winfo_class() == "Canvas" and hasattr(c, "_entry"):
            mq_entries.append(c)
        _scan_mq(c)
_scan_mq(mq_card)
check(len(mq_entries) == 3, f"MQTT 卡有 3 个 RoundedEntry: {len(mq_entries)}")
for e in mq_entries:
    check(int(str(e.cget("width"))) == want_width,
          f"MQTT RoundedEntry width=16: {e.cget('width')}")

# --- 设备身份 grid 列间距 = 16（约 2 Tab）---
grid = None
def _find_grid(w):
    global grid
    if grid is not None:
        return
    try:
        for c in w.winfo_children():
            if c.winfo_class() == "TLabel" and c.cget("text") == "IMEI":
                grid = c.master
                return
            _find_grid(c)
    except Exception:                              # noqa: BLE001
        pass
_find_grid(root)
check(grid is not None, "找到设备身份 grid 容器")
if grid is not None:
    for c in grid.winfo_children():
        if c.winfo_class() == "TLabel" and c.cget("text") == "IMEI":
            # padx 是 grid 布局参数，不是 widget 属性；要从 grid_info 拿
            info = c.grid_info()
            padx = info.get("padx", 0)
            if isinstance(padx, tuple):
                right_pad = padx[1] if len(padx) >= 2 else padx[0]
            else:
                parts = str(padx).split()
                right_pad = int(parts[1]) if len(parts) == 2 else int(parts[0])
            check(int(right_pad) >= 16,
                  f"IMEI label 右边距 = {right_pad} (期望 >=16)")
            break

# --- 【条形码】【二维码】按钮 + 弹窗 ---
# SN 条码卡已并入【设备身份】卡，按钮放在手动上锁下方；弹窗里才出图。
def _walk_all_widgets(root):
    out = [root]
    for w in list(root.winfo_children()):
        out.extend(_walk_all_widgets(w))
    return out
def _get_text(w):
    try:
        return str(w.cget("text"))
    except Exception:                                     # noqa: BLE001
        return ""
widgets = _walk_all_widgets(app.root)
for name in ("条形码", "二维码"):
    hits = [w for w in widgets if _get_text(w) == name]
    check(len(hits) == 1, f"找到【{name}】按钮: {len(hits)} 个")
# 主界面不应再有【保存图片】按钮（已挪进弹窗）
save_in_main = [w for w in widgets if _get_text(w) == "保存图片"]
check(len(save_in_main) == 0,
      f"主界面无【保存图片】按钮（已挪到弹窗）: {len(save_in_main)} 个")

# 给 SN 字段一个值，让弹窗能开
app.fields["sn"].set("11802026100900010")
# 点【条形码】按钮 -> 弹窗
for name, mode in [("条形码", "1D"), ("二维码", "QR")]:
    btn = [w for w in widgets if _get_text(w) == name][0]
    btn.invoke()
    root.update_idletasks(); root.update()
    popups = [w for w in app.root.winfo_children()
              if str(w.winfo_class()) == "Toplevel"]
    check(len(popups) >= 1, f"点【{name}】后弹出 Toplevel: {len(popups)} 个")
    if popups:
        win = popups[-1]
        all_in_win = _walk_all_widgets(win)
        # 弹窗里要能找到显示 SN 文字的 Label
        sn_lbl_texts = [str(w.cget("text")) for w in all_in_win
                        if str(w.winfo_class()) == "Label"
                        and "11802026100900010" in str(w.cget("text"))]
        check(len(sn_lbl_texts) >= 1,
              f"【{name}】弹窗里有 SN 文字: {sn_lbl_texts}")
        # 弹窗里只有【保存图片】按钮（【关闭】用自带 X）
        # RoundedButton 是 Canvas（按 _text 匹配），ttk.Button 是 TButton（按 text 配置）
        btn_texts = []
        for w in all_in_win:
            cls = str(w.winfo_class())
            if cls in ("Button", "TButton"):
                btn_texts.append(_get_text(w))
            elif cls == "Canvas" and getattr(w, "_text", ""):
                btn_texts.append(w._text)
        check("保存图片" in btn_texts,
              f"【{name}】弹窗有【保存图片】按钮: {btn_texts}")
        check("关闭" not in btn_texts,
              f"【{name}】弹窗无【关闭】按钮（用自带 X）: {btn_texts}")
        # 弹窗左上角图标用 qrcode.png
        # ⚠️ 不能用 wm iconphoto ... query：Tk 9 没有 query 选项，
        #    会抛 TclError 被当成"跳过"，检查等于没做（历史上就是这么
        #    漏掉弹窗图标问题的）。改用 Win32 直接问窗口框架的图标句柄。
        try:
            import ctypes
            _u32 = ctypes.windll.user32
            _hwnd = int(win.tk.call("wm", "frame", win._w), 16)
            _hicon = int(_u32.SendMessageW(_hwnd, 0x7F, 0, 0) or 0)   # WM_GETICON
            check(_hicon != 0, f"【{name}】弹窗左上角已设图标（WM_GETICON={_hicon}）")
        except Exception as e:                      # noqa: BLE001
            check(False, f"【{name}】弹窗图标检查失败: {type(e).__name__}: {e}")
        win.destroy()
    widgets = _walk_all_widgets(app.root)                # 刷新（窗口已关）

# 清回原状态
app.fields["sn"].set("—")

# --- 串口下拉与同行的 刷新/连接 按钮等高 ---
root.update()
port_h = app.port_cb.winfo_height()
btn_h = app.conn_btn.winfo_height()
check(abs(port_h - btn_h) <= 1, f"串口下拉与连接按钮等高: {port_h} vs {btn_h}")

# --- 连接 toggle 按钮状态机 ---
# 初始：未连接 -> 显示"连接设备"且可点
check(getattr(app, "conn_btn", None) is not None,
      "存在【连接 toggle】按钮引用")
check(app.conn_btn.cget("text") == "连接设备",
      f"未连接时按钮显示【连接设备】: {app.conn_btn.cget('text')!r}")
check(str(app.conn_btn.cget("state")) == "normal",
      f"未连接时按钮可点: {app.conn_btn.cget('state')!r}")
# 模拟已连接状态
app.device = object()                                     # 任何非 None 都行
app._update_connection_btns()
check(app.conn_btn.cget("text") == "断开",
      f"已连接时按钮显示【断开】: {app.conn_btn.cget('text')!r}")
check(str(app.conn_btn.cget("state")) == "normal",
      f"已连接时按钮可点: {app.conn_btn.cget('state')!r}")
# 模拟 busy
app.busy = True
app._update_connection_btns()
check(app.conn_btn.cget("text") == "正在识别…",
      f"busy 时按钮显示【正在识别…】: {app.conn_btn.cget('text')!r}")
check(str(app.conn_btn.cget("state")) == "disabled",
      f"busy 时按钮禁用: {app.conn_btn.cget('state')!r}")
# 恢复
app.busy = False
app.device = None
app._update_connection_btns()

root.destroy()
print("\n" + ("全部通过" if not fails else f"有 {len(fails)} 项失败: {fails}"))
sys.exit(1 if fails else 0)
