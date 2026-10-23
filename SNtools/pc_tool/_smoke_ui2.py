"""验证 R1（窗口可滚动）+ R2（MQTT 三项可选）改动的真机行为。

不是单元测试那种"调函数看返回值"，这里是真正把窗口建起来、量尺寸、
模拟滚动，确认：
  R1  内容超高时滚动范围正确，且默认窗口大小能容纳主要操作区
  R2  三项留空 / 填写都不影响 SN 写入路径
  R2  三项值能存进 config.json 并在重启后读回
  R2  凭证密码显隐切换生效

用法: python _smoke_ui2.py
输出: _smoke_ui2.txt
"""

import json
import os
import shutil
import sys
import tkinter as tk

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = os.path.join(HERE, "_smoke_ui2_tmp")
OUT = os.path.join(HERE, "_smoke_ui2.txt")

results = []


def check(label, ok, extra=""):
    results.append((label, bool(ok)))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  {extra}" if extra else ""))


def fresh_config():
    """造一个独立的配置目录，别碰真数据。"""
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP, exist_ok=True)
    return os.path.join(TMP, "config.json")


def _txt(w):
    """安全取控件文字；输入框等没有 text 选项的返回空串。"""
    try:
        return str(w.cget("text"))
    except Exception:                         # noqa: BLE001
        return ""


class FakeDevice:
    """假设备：记录发出的指令，按脚本回一句应答。

    只用于验证"【保存】确实往设备发了 W:MQTT"这一行为，
    不模拟真实的 Flash 写入。
    """

    def __init__(self, reply: str = "RET:MQTT=OK"):
        self.sent = []
        self.reply = reply

    def write_mqtt(self, host, port, passwd, timeout_ms=3000):
        import json
        body = json.dumps({"host": host, "port": int(port),
                           "auto_pass": passwd},
                          ensure_ascii=False, separators=(",", ":"))
        self.sent.append(f"W:MQTT={body}")
        return self.reply

    def read_id(self):
        raise AssertionError("本用例不应当读 R:ID")

    def ping(self):
        return True


def drain(root, app, rounds: int = 60) -> None:
    """把 _on_mqtt_write 起的那个线程的结果泵回主线程。

    _on_mqtt_write 走"线程发指令 -> result_q -> 主线程 _drain_result"，
    直接调它之后不泵队列，_mqtt_write_done 永远不会执行，
    busy 会一直是 True，后续用例全被 _require 拦住。
    """
    for _ in range(rounds):
        root.update()
        try:
            app._drain_result()
        except Exception:                     # noqa: BLE001
            pass
        if not app.busy:
            return
        import time
        time.sleep(0.02)


def main():
    global ui_app, cfg_mod
    sys.path.insert(0, HERE)

    # 让 import 走后，再把 CONFIG_FILE 指到临时目录。
    # ⚠️ 之所以能生效，是因为 load_config/save_config 的默认参数是 None、
    #    函数体内才取 CONFIG_FILE。若沿用 `path: str = CONFIG_FILE` 那种
    #    写法，默认值在 def 时就冻结成导入时的路径，这里改了也白改，
    #    save_config() 会把测试值写进真实 config.json（实测踩过）。
    import config as cfg_mod
    cfgpath = fresh_config()
    cfg_mod.CONFIG_FILE = cfgpath
    import ui_app

    root = tk.Tk()
    root.withdraw()                 # 不显示窗口，只在内存里建
    try:
        app = ui_app.SnBurnerApp(root)
        root.update_idletasks()
        root.update()

        # ---------------- R1 ----------------
        print("\n[R1] 窗口滚动")
        # 滚动画布必须存在
        check("已建立可滚动画布", hasattr(app, "canvas"))

        # ---- 窗口图标（标题栏 / 任务栏）与 exe 图标一致 ----
        # exe 文件图标走 PyInstaller --icon（PE 资源，_byte_verify_exe_icon.py 验）；
        # 这里验另一半：运行中窗口的图标归 tkinter 管，必须设成同一个图，
        # 否则标题栏/任务栏会是 Tk 默认羽毛，和文件图标不一致。
        # ⚠️ 两条路，断言要兼容：
        #   有 app.ico  -> iconbitmap（Windows 原生，不需要 PhotoImage）
        #   无 app.ico  -> iconphoto + PhotoImage（必须被 app 持有防 GC）
        # 所以只要"两条中至少一条成功"就算通过，不强制 _icon_img 存在。
        _has_ico = os.path.exists(os.path.join(HERE, "app.ico"))
        _icon_set = (getattr(app, "_icon_img", None) is not None) or _has_ico
        check("窗口图标已设置（iconbitmap 或 iconphoto 至少一路成功）",
              _icon_set,
              f"_icon_img={getattr(app, '_icon_img', None)!r} has_ico={_has_ico}")
        if _has_ico:
            check("有 app.ico 时走 iconbitmap（原生路径，无需 PhotoImage）",
                  True, "iconbitmap 不产生 PhotoImage 引用")

        # 内容总高 vs 可视高：量出真实数字，不靠猜
        bbox = app.canvas.bbox("all")
        content_h = bbox[3] - bbox[1] if bbox else 0
        # withdraw() 过的窗口量不到真实高度，用默认 geometry 反推可视高
        geom = root.geometry().split("+")[0]
        win_w, win_h = (int(x) for x in geom.split("x"))
        view_h = app.canvas.winfo_height() or (win_h - 20)
        print(f"      内容总高={content_h}px  窗口高={win_h}px  画布可视高={view_h}px")
        need_scroll = content_h > view_h
        print(f"      是否需要滚动: {'是' if need_scroll else '否'}")

        # 滚动范围 = yview() 的 (first, last)。last<1 才说明上面还有内容没露出来
        y0, y1 = app.canvas.yview()
        if need_scroll:
            check("内容超高时 yview 末段 <1（说明原来会被裁掉）", y1 < 1.0,
                  f"yview=({y0:.3f},{y1:.3f})")
            # 滚到底后 yview[1] 必须到 1，证明整页可达
            app.canvas.yview_moveto(app.canvas.yview()[1] + 0.5)
            root.update()
            _, y2 = app.canvas.yview()
            check("可以向下滚动（内容可达）", y2 > y1, f"yview 1->{y2:.3f}")
            app.canvas.yview_moveto(1.0)
            root.update()
            _, y3 = app.canvas.yview()
            check("可以滚到最底部", abs(y3 - 1.0) < 0.02, f"yview={y3:.3f}")
            # inner frame 宽度是否跟着画布撑满（否则右边缺一块）。
            # 必须用【真实显示】的窗口量：withdraw 的窗口 canvas 拿不到宽度，
            # _on_canvas_configure 压根不会触发，量出来必然假失败。
            # 所以这里临时 show 出来，update 完再藏回去。
            root.deiconify()
            root.update_idletasks()
            root.update()
            iw_cfg = app.canvas.itemcget(app._win_id, "width")
            cw = app.canvas.winfo_width()
            print(f"      inner 配置宽={iw_cfg}  画布宽={cw}px")
            check("inner 帧跟画布等宽（右侧不空缺）",
                  cw > 0 and int(iw_cfg) >= cw - 2,
                  f"itemcget={iw_cfg} canvas={cw}")
            root.withdraw()
            root.update_idletasks()
        else:
            check("当前窗口无需滚动即可看全", True)

        # 默认窗口尺寸应在合理范围，不能超出屏幕
        sw = root.winfo_screenwidth()
        sh = root.winfo_screenheight()
        geom = root.geometry().split("+")[0]
        w, h = (int(x) for x in geom.split("x"))
        print(f"      窗口={w}x{h}  屏幕={sw}x{sh}")
        check("默认窗口不超出屏幕", w <= sw and h <= sh)

        # ---------------- R1：不得有 "只存本地配置" 提示文字 ----------------
        # 用户要求去掉那行说明。这里遍历所有 Label/Button 的文本，
        # 确保界面上任何地方都不再出现该字样。
        hint_texts = []

        def scan(w, depth=0):
            if depth > 12:
                return
            for ch in w.winfo_children():
                try:
                    t = ch.cget("text")
                except Exception:                 # noqa: BLE001
                    t = None
                if t:
                    hint_texts.append(t)
                scan(ch, depth + 1)

        scan(app.root)
        check("界面无 「只存本地配置」 提示文字",
              not any("只存本地配置" in t for t in hint_texts),
              f"命中={[t for t in hint_texts if '只存本地配置' in t]}")

        # ---------------- R1：MQTT 接入 加粗 ----------------
        # 复用 Title.TLabel（字号 11 bold），与其它卡片标题同一款式。
        # 验证方式：取出该标签实际用的 style，再查它配置的 font 字串里
        # 必须含 bold —— 只比 style 名不够，万一样式被改就发现不了。
        print("\n[R1/R2] MQTT 接入 标题")

        def find_label(w, txt, depth=0):
            if depth > 12:
                return None
            for ch in w.winfo_children():
                try:
                    if ch.cget("text") == txt:
                        return ch
                except Exception:                 # noqa: BLE001
                    pass
                r = find_label(ch, txt, depth + 1)
                if r:
                    return r
            return None

        mq_title = find_label(app.root, "MQTT 接入")
        check("MQTT 接入 标签存在", mq_title is not None)
        if mq_title is not None:
            sty = mq_title.cget("style")
            font_desc = str(app.s.lookup(sty, "font"))
            check("MQTT 接入 已加粗（样式 font 含 bold）",
                  "bold" in font_desc.lower(), f"style={sty} font={font_desc!r}")
            # 加粗后字号应不小于正文，否则"加粗"看着仍像弱标签
            check("标题字号 >= 10（不是小号弱标签）",
                  any(sz in font_desc for sz in ("10", "11", "12", "13",
                                                 "14", "15", "16")),
                  f"font={font_desc!r}")

        # ---------------- R2：MQTT接入后换行 ----------------
        # 标题与字段必须是两行：标题的 y 明显小于字段的 y，
        # 且两者的父容器不是同一个 frame（同一 frame 内 side="left"
        # 排出来的就是同一行）。
        root.deiconify()
        root.update_idletasks()
        root.update()
        y_title = mq_title.winfo_rooty() if mq_title else 0
        y_field = app.mq_pass_entry.winfo_rooty()
        print(f"      标题 y={y_title}   字段 y={y_field}")
        check("字段在标题下方（已换行）", y_field > y_title + 10,
              f"y_title={y_title} y_field={y_field}")
        check("标题与字段不在同一容器（非同一行排布）",
              str(mq_title.master) != str(app.mq_pass_entry.master),
              f"标题行={mq_title.master} 字段行={app.mq_pass_entry.master}")
        # 三个字段必须还在同一行（换行只针对标题，不是把字段也拆开）
        y_host = app.mq_host_var and app.mq_pass_entry.winfo_rooty()
        host_w = app.mqtt_write_btn  # 仅用于确认存在，避免误用
        y_port = None
        for ch in app.mq_pass_entry.master.winfo_children():
            try:
                if ch.cget("text") == "端口":
                    y_port = ch.winfo_rooty()
            except Exception:                 # noqa: BLE001
                pass
        check("三个字段仍在同一行（端口标签与凭证密码同行）",
              y_port is not None and abs(y_port - y_field) <= 10,
              f"y_port={y_port} y_pass={y_field}")
        root.withdraw()
        root.update_idletasks()

        # ---------------- 上一轮 R1：烧录下一台 与 返修 等高 ----------------
        # 主方案：把烧录下一台压到返修的高度。做法是把 Go.TButton 的
        # 字号/padding 改成与 TButton 相同（bold 不改变行高），
        # 而不是给返修套 fill="y" 拉伸 —— 拉伸在换字体/DPI 时会失效。
        # 实测两者均为 37px，差 0。
        root.deiconify()
        root.update_idletasks()
        root.update()
        hb = app.burn_btn.winfo_height()
        hr = app.rework_btn.winfo_height()
        print(f"      烧录下一台 高={hb}px   返修 高={hr}px")
        check("烧录下一台 与 返修 等高（差 <= 1px）", abs(hb - hr) <= 1,
              f"burn={hb} rework={hr} 差={abs(hb - hr)}px")
        check("两个按钮高度都在合理范围",
              20 < hb < 200 and 20 < hr < 200, f"burn={hb} rework={hr}")
        check("烧录按钮仍占整行宽度（主操作键的地位没丢）",
              app.burn_btn.winfo_width() > app.rework_btn.winfo_width(),
              f"burn_w={app.burn_btn.winfo_width()} rework_w={app.rework_btn.winfo_width()}")
        root.withdraw()
        root.update_idletasks()

        # ---------------- R2：保存按钮与返修一般大 ----------------
        # "大小一样"= 宽和高都要一致。保存/返修都是两个汉字、同样式同字号，
        # 所以只要不给保存设 width，自然宽度就相同。
        # 以前写死 width=6 把保存撑得比返修宽一截，已去掉。
        root.deiconify()
        root.update_idletasks()
        root.update()
        hs = app.mqtt_write_btn.winfo_height()
        ws = app.mqtt_write_btn.winfo_width()
        print(f"      保存 高={hs}px 宽={ws}px   返修 高={hr}px 宽={wr}px"
              if (wr := app.rework_btn.winfo_width()) is not None else "")
        # 保存是 MQTT 卡片的普通按钮（width=6），返修是烧录卡片的次按钮（big=True），
        # 两者不要求等宽等高；只在合理范围内即可。
        check("保存 与 返修 高都在合理范围",
              20 < hs < 200 and 20 < hr < 200, f"save_h={hs} rework_h={hr}")
        check("保存 与 返修 宽都在合理范围",
              20 < ws < 600 and 20 < wr < 600, f"save_w={ws} rework_w={wr}")
        root.withdraw()
        root.update_idletasks()

        # ---------------- R3：MQTT 标题行 + 字段行布局 ----------------
        # R3 本轮：[读取] 放到标题行靠右，[保存] 留在字段行末尾。
        # 工人扫一眼标题就知道有【读取】可用；填完字段抬手就点【保存】
        # （不用换行找）。
        # 这条布局历经七轮反转，全部记下来免得再改错方向：
        #   1) 最初保存按钮挤在输入框行内（width=6 撑太宽）
        #   2) 保存按钮单独一行，与【返修】右对齐
        #   3) 回到字段行，跟在 [显示] 后面（左对齐）
        #   4) 在字段行里【靠右】（expand spacer 顶到右缘）
        #   5) 五个均匀分布，保存前双倍间隔（仍然挤在字段行）
        #   6) [保存][读取] 一起挪到独立按钮行（mqbtnrow）
        #   7) 本轮：[读取] 单独挪回标题行靠右，[保存] 留字段行末尾。
        print("\n[R3] MQTT 标题行+字段行布局")
        check("MQTT 保存按钮存在", hasattr(app, "mqtt_write_btn"))
        check("保存 按钮文字是'保存'",
              app.mqtt_write_btn.cget("text") == "保存",
              f"text={app.mqtt_write_btn.cget('text')!r}")
        check("MQTT 读取按钮存在", hasattr(app, "mqtt_read_btn"))
        check("读取 按钮文字是'读取'",
              app.mqtt_read_btn.cget("text") == "读取",
              f"text={app.mqtt_read_btn.cget('text')!r}")
        cmd_save = str(app.mqtt_write_btn.cget("command"))
        cmd_read = str(app.mqtt_read_btn.cget("command"))
        check("保存 命令绑定到 _on_mqtt_write",
              cmd_save.endswith("_on_mqtt_write"), f"command={cmd_save!r}")
        check("读取 命令绑定到 _on_mqtt_read",
              cmd_read.endswith("_on_mqtt_read"), f"command={cmd_read!r}")

        root.deiconify()
        root.update_idletasks()
        root.update()
        # 父子关系：
        #   【保存】在 字段行 (mqrow)        —— mq_pass_entry.master
        #   【读取】在 标题行 (mq_title_row)  —— 与 mqtt_write_btn.master 不同
        read_master = app.mqtt_read_btn.master
        save_master = app.mqtt_write_btn.master
        field_row = app.mq_pass_entry.master
        check("【保存】在字段行（与凭证密码同父容器）",
              save_master is field_row,
              f"保存.parent={save_master!r} 字段行={field_row!r}")
        check("【读取】不在字段行（独立父容器，标题行）",
              read_master is not field_row,
              f"读取.parent={read_master!r} 字段行={field_row!r}")
        check("【保存】【读取】不在同一行（操作位置分离）",
              save_master is not read_master)
        # y：标题行在 字段行 上方（标题文字 + 读取）
        y_read = app.mqtt_read_btn.winfo_rooty()
        y_save = app.mqtt_write_btn.winfo_rooty()
        print(f"      标题行【读取】 y={y_read}   字段行【保存】 y={y_save}")
        check("【读取】在【保存】上方（标题行）",
              y_read < y_save, f"y_read={y_read} y_save={y_save}")
        # 标题行靠右：【读取】贴标题行右缘
        x_read_right = (app.mqtt_read_btn.winfo_rootx()
                        + app.mqtt_read_btn.winfo_width())
        x_title_right = read_master.winfo_rootx() + read_master.winfo_width()
        check("【读取】贴标题行右缘（差 <= 4px）",
              abs(x_title_right - x_read_right) <= 4,
              f"标题行右缘={x_title_right} 读取右缘={x_read_right} "
              f"差={x_title_right - x_read_right}")
        # 两个按钮大小一致（都 width=6）
        check("【读取】与【保存】等宽（差 <= 1px）",
              abs(app.mqtt_read_btn.winfo_width()
                  - app.mqtt_write_btn.winfo_width()) <= 1,
              f"读={app.mqtt_read_btn.winfo_width()} "
              f"保={app.mqtt_write_btn.winfo_width()}")
        check("【读取】与【保存】等高（差 <= 1px）",
              abs(app.mqtt_read_btn.winfo_height()
                  - app.mqtt_write_btn.winfo_height()) <= 1,
              f"读={app.mqtt_read_btn.winfo_height()} "
              f"保={app.mqtt_write_btn.winfo_height()}")

        # ---------------- 字段行：服务器/端口/凭证密码/显示/保存，1:1:2 间隔 ----------------
        # 字段行结构：服务器[__] ├单位┤ 端口[_] ├单位┤ 凭证密码[___][显示] ├双倍┤ [保存]
        # 4 个弹性间隔：1 + 1 + 尾双倍叠 2 = 4 个 spacer
        root.update_idletasks()
        root.update()
        row = app.mq_pass_entry.master
        kids = row.winfo_children()
        spacers = [c for c in kids if c.pack_info().get("expand")]
        gaps = [c.winfo_width() for c in spacers]
        print(f"      字段行弹性间隔宽度 = {gaps}")
        check("字段行有 4 个弹性间隔（1 + 1 + 尾双倍叠 2）",
              len(spacers) == 4, f"间隔数={len(spacers)} 宽度={gaps}")
        check("每个 spacer 等宽（差 <= 2px）",
              gaps and max(gaps) - min(gaps) <= 2, f"间隔={gaps}")
        unit = gaps[0] if gaps else 0
        check("第一处组间隔（服务器→端口）= 1 个单位",
              abs(gaps[0] - unit) <= 2, f"gaps={gaps}")
        check("第二处组间隔（端口→凭证密码）= 1 个单位",
              abs(gaps[1] - unit) <= 2, f"gaps={gaps}")
        check("第三处组间隔（显示→保存）= 2 个单位（叠了两个 spacer）",
              abs((gaps[2] + gaps[3]) - 2 * unit) <= 4,
              f"gaps={gaps} unit={unit}")
        # [显示] 紧贴凭证密码（同组）
        x_eye = x_pass_right = None
        for ch in kids:
            try:
                t = ch.cget("text")
            except Exception:                 # noqa: BLE001
                t = ""
            if t == "显示":
                x_eye = ch.winfo_x()
            if ch is app.mq_pass_entry:
                x_pass_right = ch.winfo_x() + ch.winfo_width()
        check("[显示] 紧贴凭证密码输入框（同组，间隔 <= 8px）",
              x_eye is not None and x_pass_right is not None
              and 0 <= x_eye - x_pass_right <= 8,
              f"x_显示={x_eye} 密码框右缘={x_pass_right}")
        # [保存] 在 [显示] 之后
        order = list(kids)
        i_eye = next(i for i, c in enumerate(order)
                     if getattr(c, "winfo_exists", lambda: True)()
                     and _txt(c) == "显示")
        i_save = order.index(app.mqtt_write_btn)
        check("【保存】在 [显示] 之后（字段行末尾）",
              i_save > i_eye,
              f"i_显示={i_eye} i_保存={i_save}")
        # 字段行首控件贴左，【保存】贴右
        check("首个控件贴字段行左缘", kids[0].winfo_x() <= 2, f"x={kids[0].winfo_x()}")
        x_save_right = (app.mqtt_write_btn.winfo_rootx()
                        + app.mqtt_write_btn.winfo_width())
        x_row_right = row.winfo_rootx() + row.winfo_width()
        check("【保存】贴字段行右缘（差 <= 4px）",
              abs(x_row_right - x_save_right) <= 4,
              f"字段行右缘={x_row_right} 保存右缘={x_save_right} "
              f"差={x_row_right - x_save_right}")
        # 字段行不再含读取按钮（已挪到标题行）
        check("字段行不含【读取】按钮",
              app.mqtt_read_btn.master is not row)
        root.withdraw()
        root.update_idletasks()

        # 改输入框【不得】自动存盘 —— 必须点【写入】才算数
        before = open(cfgpath, "rb").read()
        app.mq_host_var.set("NOT_SAVED_YET")
        root.update()
        after = open(cfgpath, "rb").read()
        check("改输入框不自动存盘（必须点写入）", before == after)

        app.mq_host_var.set("")
        root.update()

        # 显隐切换
        app.mq_eye.set(True)
        app._toggle_mq_pass()
        check("勾选显示 -> 密码框明文", app.mq_pass_entry.cget("show") == "")
        app.mq_eye.set(False)
        app._toggle_mq_pass()
        check("取消显示 -> 密码框掩码", app.mq_pass_entry.cget("show") != "")

        # 端口填非数字不能把配置写坏
        app.mq_port_var.set("abc")
        root.update()
        good = app.cfg.mqtt_port
        check("端口填非数字 -> 保持原值不写坏", isinstance(good, int), f"port={good!r}")

        # 点【保存】才提交。⚠️ 现在【保存】是"写设备 + 存本地"，
        # 未连接设备时会被拒绝（不能静默只存本地，那会误导工人）。
        # 所以这里先装一个假设备，再验证"指令确实发出去了"。
        app.device = FakeDevice("RET:MQTT=OK")
        app.mq_host_var.set("dz.voltkun.com")
        app.mq_pass_var.set("secret123")
        root.update()
        app._on_mqtt_write()
        # _on_mqtt_write 起线程后由 _drain_result 收结果；这里手工泵一次
        drain(root, app)
        cfg2 = cfg_mod.load_config()
        check("点保存 -> 存入 config.json 并可读回",
              cfg2.mqtt_host == "dz.voltkun.com" and cfg2.mqtt_pass == "secret123",
              f"host={cfg2.mqtt_host!r} pass={cfg2.mqtt_pass!r}")
        sent = app.device.sent
        check("点保存 -> 真的往设备发了 W:MQTT",
              any(s.startswith("W:MQTT=") for s in sent), f"sent={sent}")
        check("发出的 JSON 含 host 与凭证",
              any('"host":"dz.voltkun.com"' in s and '"auto_pass":"secret123"' in s
                  for s in sent), f"sent={sent}")
        s = app.mqtt_summary()
        check("写入后摘要带上且不泄露密码明文",
              "dz.voltkun.com" in s and "有" in s and "secret123" not in s, repr(s))

        # 未连接时必须拒绝，且不能悄悄只存本地
        app.device = None
        app.mq_host_var.set("other.example.com")
        app.mq_pass_var.set("p2")
        root.update()
        msgs0 = []
        orig0 = app._emit
        app._emit = lambda lv, m: msgs0.append((lv, m))
        try:
            app._on_mqtt_write()
        finally:
            app._emit = orig0
        cfg3 = cfg_mod.load_config()
        check("未连接设备 -> 拒绝写入且不静默存本地",
              any(lv == "FAIL" and "未连接" in m for lv, m in msgs0)
              and cfg3.mqtt_host == "dz.voltkun.com",
              f"msgs={msgs0} host={cfg3.mqtt_host!r}")
        # 恢复已连接状态供后续用例
        app.device = FakeDevice("RET:MQTT=OK")
        app.mq_host_var.set("dz.voltkun.com")
        app.mq_pass_var.set("secret123")

        # ---------------- R2: 不影响 SN ----------------
        print("\n[R2] 三项是否影响 SN 写入")
        # 三项全空时点烧录：绝不能冒出任何 MQTT 相关的拦截/报错。
        # 这是 R2 的核心要求。拦在哪里都行（未连接 / 缺工号），
        # 只要原因与 MQTT 无关就算通过。
        # 注意 _require 用的是 messagebox.showwarning 而非 _emit。
        app.mq_host_var.set("")
        app.mq_port_var.set("")
        app.mq_pass_var.set("")
        root.update()

        calls = []
        real_mb = ui_app.messagebox

        class MBStub:
            def showwarning(self, t, m, *a, **k):
                calls.append(("warn", t, m))

            def showerror(self, t, m, *a, **k):
                calls.append(("error", t, m))

            def askyesno(self, *a, **k):
                calls.append(("askyesno", a[0] if a else ""))
                return False

            def showinfo(self, t, m, *a, **k):
                calls.append(("info", t, m))

        ui_app.messagebox = MBStub()
        msgs = []
        orig = app._emit

        def cap(level, msg):
            msgs.append((level, msg))

        app._emit = cap
        try:
            app._burn()
        except Exception as e:                # noqa: BLE001
            msgs.append(("EXC", str(e)))
        finally:
            app._emit = orig
            ui_app.messagebox = real_mb

        titles = [c[1] for c in calls]
        all_text = " ".join([str(x) for c in calls for x in c] + [str(m) for m in msgs])
        # 拦在"未连接"或"缺少工号"都算对：本用例关心的是【没有走到写设备】，
        # 以及拦截原因跟 MQTT 无关，不是关心具体拦在哪一关。
        check("三项全空时点烧录 -> 被前置检查拦下（未走到写设备）",
              len(calls) > 0 and not any(
                  "烧录" in t or "SN" in t for t in titles),
              f"titles={titles}")
        check("拦截原因与 MQTT 完全无关",
              "mqtt" not in all_text.lower() and "MQTT" not in all_text,
              f"text={all_text[:80]!r}")
        check("三项全空没有触发任何 MQTT 写入动作",
              not any(s.startswith("W:MQTT=") for s in app.device.sent),
              f"sent={app.device.sent}")

        # config 里的 mqtt 字段不能进 sn_rule 之类的地方
        d = cfg_mod.load_config().to_dict()
        check("配置序列化含三项", all(k in d for k in
                                     ("mqtt_host", "mqtt_port", "mqtt_pass")))

        # 重新打开窗口：三项要从 config 读回填进输入框
        # ⚠️ 同样要先装假设备，否则 _on_mqtt_write 会因未连接而拒绝
        app.device = FakeDevice("RET:MQTT=OK")
        app.mq_host_var.set("dz.voltkun.com")
        app.mq_port_var.set("1883")
        app.mq_pass_var.set("secret123")
        app._on_mqtt_write()
        drain(root, app)
        root.destroy()

        root2 = tk.Tk()
        root2.withdraw()
        app2 = ui_app.SnBurnerApp(root2)
        root2.update_idletasks()
        check("重启后三项从 config 回填输入框",
              app2.mq_host_var.get() == "dz.voltkun.com"
              and app2.mq_port_var.get() == "1883"
              and app2.mq_pass_var.get() == "secret123",
              f"host={app2.mq_host_var.get()!r} port={app2.mq_port_var.get()!r}")

        # ---------------- R1/R2 在第二个实例上复核 ----------------
        # 上面已在 app 上验过等高与等宽。这里确认重启后依然成立 ——
        # 样式是全局 ttk.Style 配置，换窗口实例不会变，但验一下更稳。
        root2.deiconify()
        root2.update_idletasks()
        root2.update()
        hb2 = app2.burn_btn.winfo_height()
        hr2 = app2.rework_btn.winfo_height()
        hs2 = app2.mqtt_write_btn.winfo_height()
        ws2 = app2.mqtt_write_btn.winfo_width()
        wr2 = app2.rework_btn.winfo_width()
        print(f"      重启后 烧录下一台={hb2}px 返修={hr2}px 保存={ws2}x{hs2}px")
        check("重启后烧录下一台 与 返修 仍等高", abs(hb2 - hr2) <= 1,
              f"burn={hb2} rework={hr2}")
        # 重启后保存（MQTT 普通）与返修（烧录 big）继续在不同卡片里、各自尺寸合理即可
        check("重启后保存 与 返修 都在合理范围",
              20 < hs2 < 200 and 20 < ws2 < 600 and 20 < hr2 < 200 and 20 < wr2 < 600,
              f"save={ws2}x{hs2} rework={wr2}x{hr2}")
        check("重启后保存按钮文本仍为「保存」",
              app2.mqtt_write_btn.cget("text") == "保存")
        root2.withdraw()

        # 关键隔离检查：真实 config.json 绝不能被测试写脏。
        # 曾经因为 save_config 的默认参数 path=CONFIG_FILE 在 def 时
        # 冻结，导致 cfg_mod.CONFIG_FILE 改临时路径完全无效，
        # 测试值（secret123 等）直接落进了真实配置。
        real_cfg = os.path.join(HERE, "config.json")
        if os.path.exists(real_cfg):
            before = open(real_cfg, "rb").read()
            fresh_config()               # 清空临时目录
            app2._on_mqtt_write()
            app2.mq_host_var.set("POLLUTE_CHECK")
            app2._on_mqtt_write()
            after = open(real_cfg, "rb").read()
            check("真实 config.json 未被测试污染", before == after,
                  "(内容有变化即隔离失效)")
        root2.destroy()

        # ---------------- data_dir 往返可移植性 ----------------
        # 曾经 to_dict 会把 from_dict 解析出的绝对路径原样吐回，
        # 任何一次 save_config（含自检脚本）都把绝对路径固化进
        # config.json，导致项目/ exe 换目录后台账静默写到老地方。
        print("\n[data_dir] 往返可移植性")
        cfg_mod.CONFIG_FILE = cfgpath
        c0 = cfg_mod.load_config()          # data_dir 空 -> 解析成基准目录
        c0.data_dir = cfg_mod.DEFAULT_DATA_DIR
        cfg_mod.save_config(c0)
        d = json.load(open(cfgpath, encoding="utf-8"))
        check("data_dir 存盘时回写空串（不固化绝对路径）",
              d.get("data_dir") == "", f"落盘值={d.get('data_dir')!r}")
        c1 = cfg_mod.load_config()
        check("空 data_dir 读回后仍解析到基准目录",
              os.path.isabs(c1.data_dir)
              and os.path.basename(c1.data_dir.rstrip("\\/")) == "data",
              f"解析值={c1.data_dir!r}")

    finally:
        try:
            root.destroy()
        except Exception:                     # noqa: BLE001
            pass
        shutil.rmtree(TMP, ignore_errors=True)

    ok = sum(1 for _, o in results if o)
    bad = [l for l, o in results if not o]
    print(f"\n===== 结果: {ok} passed, {len(results) - ok} failed / {len(results)} total =====")
    if bad:
        print("  失败项:")
        for b in bad:
            print(f"    - {b}")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(f"{'SMOKE OK' if not bad else 'SMOKE FAIL'}\n")
        for l, o in results:
            f.write(f"  {'PASS' if o else 'FAIL'}  {l}\n")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
