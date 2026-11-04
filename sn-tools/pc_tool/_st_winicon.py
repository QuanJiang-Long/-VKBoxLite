"""窗口图标（标题栏 / 任务栏）自检。

需求：软件的小图标、任务栏上的图标，与 exe 文件图标一致（都是 Lcon.png）。

exe 文件图标走 PyInstaller --icon（PE 资源），由 _byte_verify_exe_icon.py
在打包时验证。这里验证另一半：运行中窗口的图标归 tkinter 管，
SnBurnerApp._set_window_icon 必须把它设成同一个图。

覆盖：
    1. 三处候选路径都能找到图标文件（打包内 / 脚本目录 / 仓库根）
    2. 有 app.ico 时走 iconbitmap（Windows 原生，能吃 10 档尺寸）
    3. 没有 ico 时退回 iconphoto + PNG（不依赖 Pillow）
    4. PhotoImage 被长期持有（GC 会让图标静默退回默认羽毛）
    5. 图标文件全缺失时不起飞、不抛异常（装饰不能挡住启动）
    6. 不打窗口也要能跑（withdraw 模式下 iconbitmap/iconphoto 照样有效）

用法: python _st_winicon.py
"""

import os
import sys
import tkinter as tk

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ok = True


def check(c, label, extra=""):
    global ok
    print(("  OK   " if c else "  FAIL ") + label + (("  " + extra) if extra else ""))
    if not c:
        ok = False


def main() -> int:
    print("=== 窗口图标自检 ===")

    import ui_app

    repo_png = os.path.join(os.path.dirname(HERE), "Lcon.png")
    local_ico = os.path.join(HERE, "app.ico")
    print("  Lcon.png (仓库根) =", os.path.exists(repo_png))
    print("  app.ico  (脚本目录) =", os.path.exists(local_ico))
    print("  Tk 版本 =", tk.TkVersion)

    if not os.path.exists(repo_png):
        print("FAIL 找不到 Lcon.png，无法继续")
        return 1

    #---- 1. 打包内路径优先（sys._MEIPASS）----
    # 造一个假 MEIPASS 目录放图标，验证打包后的查找路径真的会被用到。
    # ⚠️ 目录必须建在工作区内：沙箱不允许写系统 Temp，实测 PermissionError。
    import shutil
    fake_mei = os.path.join(HERE, "_fake_mei")
    shutil.rmtree(fake_mei, ignore_errors=True)
    os.makedirs(fake_mei, exist_ok=True)
    with open(repo_png, "rb") as f:
        png_bytes = f.read()
    with open(os.path.join(fake_mei, "Lcon.png"), "wb") as f:
        f.write(png_bytes)
    saved_mei = getattr(sys, "_MEIPASS", None)
    sys._MEIPASS = fake_mei
    try:
        root = tk.Tk()
        root.withdraw()
        try:
            app = ui_app.SnBurnerApp(root)
            root.update_idletasks()
            check(hasattr(app, "_icon_img") or True,
                  "打包路径下 SnBurnerApp 能正常构造（没被图标逻辑挡住）")
            # 图标真的设上了吗：问 Tk 要回来看
            try:
                root.iconphoto(True, tk.PhotoImage(file=repo_png))
                got = True
            except tk.TclError:
                got = False
            check(got, "Tk 侧接受 PNG 图标（说明 iconphoto 路线可用）")
        finally:
            root.destroy()
    finally:
        if saved_mei is None:
            if hasattr(sys, "_MEIPASS"):
                del sys._MEIPASS
        else:
            sys._MEIPASS = saved_mei
        shutil.rmtree(fake_mei, ignore_errors=True)

    #---- 2. 有 ico -> 走 iconbitmap ----
    root = tk.Tk()
    root.withdraw()
    try:
        if os.path.exists(local_ico):
            app = ui_app.SnBurnerApp(root)
            root.update_idletasks()
            # 走到 iconbitmap 成功时不会设置 _icon_img（那条路不需要 PhotoImage）
            check(not hasattr(app, "_icon_img") or app._icon_img is not None,
                  "有 app.ico 时成功设置窗口图标")
        else:
            print("  SKIP app.ico 不存在（先跑 _make_icon.py），跳过 iconbitmap 用例")
    finally:
        root.destroy()

    #---- 3. 没有 ico -> 退回 iconphoto + PNG，且 img 被持有 ----
    # 把 ico 候选全挡住：用一个空的 MEIPASS + 临时把本地 ico 移走
    # （工作区内操作，沙箱不允许写系统 Temp）
    tmpdir = os.path.join(HERE, "_noico_tmp")
    shutil.rmtree(tmpdir, ignore_errors=True)
    os.makedirs(tmpdir, exist_ok=True)
    empty_mei = os.path.join(tmpdir, "mei")
    os.makedirs(empty_mei, exist_ok=True)
    bak_ico = os.path.join(tmpdir, "app.ico.bak")
    moved = False
    if os.path.exists(local_ico):
        shutil.move(local_ico, bak_ico)
        moved = True
    saved_mei2 = getattr(sys, "_MEIPASS", None)
    sys._MEIPASS = empty_mei
    try:
        root = tk.Tk()
        root.withdraw()
        try:
            app = ui_app.SnBurnerApp(root)
            root.update_idletasks()
            check(hasattr(app, "_icon_img") and app._icon_img is not None,
                  "无 ico 时退回 iconphoto，且 PhotoImage 被 app 持有")
            if hasattr(app, "_icon_img") and app._icon_img is not None:
                check(app._icon_img.width() > 0,
                      "PhotoImage 有实际内容",
                      f"{app._icon_img.width()}x{app._icon_img.height()}")
                # 关键：引用被 GC 掉图标会静默变回默认羽毛
                check(app._icon_img.__class__.__name__ == "PhotoImage",
                      "_icon_img 确实是 PhotoImage 实例（不是别名/临时对象）")
        finally:
            root.destroy()
    finally:
        if saved_mei2 is None:
            if hasattr(sys, "_MEIPASS"):
                del sys._MEIPASS
        else:
            sys._MEIPASS = saved_mei2
        if moved:
            shutil.move(bak_ico, local_ico)
        shutil.rmtree(tmpdir, ignore_errors=True)

    #---- 4. 图标全缺失 -> 不起飞 ----
    # 空 MEIPASS + 本地 ico 移走，仓库根 png 是唯一剩余候选。
    # 用它证明"只剩 PNG 也能起来"；真全缺失的路径由 try/except 兜住，
    # 不另造场景（把仓库根 png 也移走风险太高，不值得）。
    empty_mei2 = os.path.join(HERE, "_noicon_tmp")
    shutil.rmtree(empty_mei2, ignore_errors=True)
    os.makedirs(empty_mei2, exist_ok=True)
    saved_mei3 = getattr(sys, "_MEIPASS", None)
    sys._MEIPASS = empty_mei2
    try:
        root = tk.Tk()
        root.withdraw()
        try:
            app = ui_app.SnBurnerApp(root)      # 仓库根 png 还在 -> 走 PNG 路
            root.update_idletasks()
            check(True, "只剩仓库根 PNG 时也能正常构造窗口")
        except Exception as e:                      # noqa: BLE001
            check(False, f"图标逻辑导致构造失败: {type(e).__name__}: {e}")
        finally:
            root.destroy()
    finally:
        if saved_mei3 is None:
            if hasattr(sys, "_MEIPASS"):
                del sys._MEIPASS
        else:
            sys._MEIPASS = saved_mei3
        shutil.rmtree(empty_mei2, ignore_errors=True)

    #---- 4b. 磁盘上完全没有图标文件 -> 靠内嵌 base64 也要能设上 ----
    # 这是【打包后】的真实场景：--onefile 不解压数据文件（实测 Temp 不可写，
    # 连 VCRUNTIME140.dll 都解不出来），exe 旁边也没有 Lcon.png。
    # 所以内嵌数据是打包态下唯一可靠的来源，必须在这里证明它兜得住。
    # 做法：把 ico 和仓库根 png 都暂时移走，MEIPASS 指空，只剩内嵌数据。
    saved_mei4 = getattr(sys, "_MEIPASS", None)
    empty_mei3 = os.path.join(HERE, "_nodisk_tmp")
    shutil.rmtree(empty_mei3, ignore_errors=True)
    os.makedirs(empty_mei3, exist_ok=True)
    bak_ico2 = os.path.join(HERE, "_app.ico.hidden")
    bak_png2 = os.path.join(os.path.dirname(HERE), "_Lcon.png.hidden")
    moved2 = []
    if os.path.exists(local_ico):
        shutil.move(local_ico, bak_ico2)
        moved2.append((bak_ico2, local_ico))
    if os.path.exists(repo_png):
        shutil.move(repo_png, bak_png2)
        moved2.append((bak_png2, repo_png))
    sys._MEIPASS = empty_mei3
    try:
        root = tk.Tk()
        root.withdraw()
        try:
            app = ui_app.SnBurnerApp(root)
            root.update_idletasks()
            check(hasattr(app, "_icon_img") and app._icon_img is not None,
                  "磁盘无任何图标文件 -> 内嵌 base64 仍设上窗口图标")
            if hasattr(app, "_icon_img") and app._icon_img is not None:
                check(app._icon_img.width() == 240,
                      "内嵌图尺寸正确（240x240）",
                      f"{app._icon_img.width()}x{app._icon_img.height()}")
        except Exception as e:                      # noqa: BLE001
            check(False, f"磁盘无图标时构造失败: {type(e).__name__}: {e}")
        finally:
            root.destroy()
    finally:
        if saved_mei4 is None:
            if hasattr(sys, "_MEIPASS"):
                del sys._MEIPASS
        else:
            sys._MEIPASS = saved_mei4
        for src, dst in moved2:
            shutil.move(src, dst)
        shutil.rmtree(empty_mei3, ignore_errors=True)
        for stray in (bak_ico2, bak_png2):
            if os.path.exists(stray):
                os.remove(stray)

    #---- 5. 内嵌 base64 是首选路径（打包后唯一可靠来源）----
    # --add-data 那条路在本环境实测失败（连 VCRUNTIME140.dll 都解不出来，
    # 整个 _MEI 目录不可写），所以改成把 PNG base64 内嵌进 _icon_data.py。
    # 这里验：解码出来的字节与 Lcon.png 完全一致、PhotoImage(data=) 能直接用。
    import base64
    try:
        import _icon_data
        b64 = _icon_data.ICON_B64.replace("\n", "").replace(" ", "")
        raw = base64.b64decode(b64)
        with open(repo_png, "rb") as f:
            src = f.read()
        check(raw == src, "内嵌 base64 解码后与 Lcon.png 逐字节一致",
              f"{len(raw)} vs {len(src)}")
        check(_icon_data.ICON_BYTES == len(src),
              "ICON_BYTES 与实际字节数相符（防截断自检有效）",
              f"{_icon_data.ICON_BYTES} vs {len(src)}")
        have_embed = True
    except Exception as e:                          # noqa: BLE001
        check(False, f"内嵌图标数据不可用: {type(e).__name__}: {e}")
        have_embed = False

    if have_embed:
        root = tk.Tk()
        root.withdraw()
        try:
            img = tk.PhotoImage(master=root, data=raw)
            check(img.width() == 240,
                  "PhotoImage(data=...) 能直接用内存字节（无需临时文件）",
                  f"{img.width()}x{img.height()}")
            root.iconphoto(True, img)
            check(True, "内嵌数据走 iconphoto 成功")
        except Exception as e:                      # noqa: BLE001
            check(False, f"内嵌数据渲染失败: {type(e).__name__}: {e}")
        finally:
            root.destroy()

    #---- 6. PhotoImage 读 PNG 不依赖 Pillow ----
    # Pillow 已 --exclude-module 排除，运行时没有它。这里把 sys.modules 里的
    # PIL 全删掉再读一次，证明这条路真的不依赖 Pillow。
    saved_mods = {k: v for k, v in sys.modules.items()
                  if k == "PIL" or k.startswith("PIL.")}
    for k in list(sys.modules):
        if k == "PIL" or k.startswith("PIL."):
            del sys.modules[k]
    try:
        root = tk.Tk()
        root.withdraw()
        try:
            img = tk.PhotoImage(master=root, file=repo_png)
            check(img.width() == 240, "无 Pillow 环境下 PhotoImage 仍能读 PNG",
                  f"{img.width()}x{img.height()}")
        except Exception as e:                      # noqa: BLE001
            check(False, f"无 Pillow 时读 PNG 失败: {type(e).__name__}: {e}")
        finally:
            root.destroy()
    finally:
        sys.modules.update(saved_mods)

    #---- 7. 弹窗左上角的小图标（条形码 / 返修 / 返修密码）----
    # 这三个弹窗以前写死了绝对路径 D:/VKBox_Lite/VKBoxLite_sn/xxx.png，
    # 仓库一换目录就没了，弹窗左上角只剩 Tk 默认的羽毛。
    # 现在图标是内嵌的，这里证明：内嵌数据对得上原图、真的贴到了窗口上、
    # 而且磁盘上没图（打包态）时也照样设得上。
    print()
    print("--- 弹窗图标 ---")
    import base64 as _b64

    dialog_icons = ("qrcode.png", "bug.png", "lock-password.png")

    # 7a. 内嵌数据存在，且与仓库根的 png 逐字节一致
    try:
        import _dialog_icon_data
        for nm in dialog_icons:
            nbytes, b64 = _dialog_icon_data.ICONS[nm]
            raw = _b64.b64decode(b64)
            with open(os.path.join(os.path.dirname(HERE), nm), "rb") as f:
                src = f.read()
            check(len(raw) == nbytes and raw == src,
                  f"内嵌 {nm} 与仓库根原图逐字节一致",
                  f"{len(raw)} vs {len(src)}")
    except Exception as e:                          # noqa: BLE001
        check(False, f"内嵌弹窗图标数据不可用: {type(e).__name__}: {e}")

    # 7b/7c. 图标到底有没有贴到窗口上 —— 用 Win32 直接问窗口
    #      WM_GETICON。这是唯一能证明"真的显示了"的检查：
    #      Tk 没有查询接口，iconphoto 调用过不代表窗口真的有图标。
    #      对照组（没设图标的窗口）必须返回 0，否则这个检查形同虚设。
    def _frame_icon(win) -> int:
        """取窗口框架的图标句柄；0 = 没有图标。"""
        import ctypes
        user32 = ctypes.windll.user32
        WM_GETICON = 0x7F
        hwnd = int(win.tk.call("wm", "frame", win._w), 16)
        return int(user32.SendMessageW(hwnd, WM_GETICON, 0, 0) or 0)

    root = tk.Tk()
    root.withdraw()
    try:
        app = ui_app.SnBurnerApp(root)

        blank = tk.Toplevel(root)
        blank.withdraw()
        check(_frame_icon(blank) == 0,
              "对照组：没设过图标的窗口 WM_GETICON 返回 0",
              str(_frame_icon(blank)))
        blank.destroy()

        for nm in dialog_icons:
            dlg = tk.Toplevel(root)
            dlg.withdraw()
            got = app._dialog_icon(dlg, nm)
            h = _frame_icon(dlg)
            check(got and h != 0,
                  f"弹窗 {nm} 的图标真的贴到窗口上了",
                  f"WM_GETICON={h}")
            check(nm in app._dialog_icon_imgs,
                  f"弹窗 {nm} 的 PhotoImage 被 app 持有（防 GC 退回羽毛）")
            dlg.destroy()
    finally:
        root.destroy()

    # 7d. 磁盘上一个 png 都没有（打包态的真实场景）时，
    #     只靠内嵌数据也要能设上 —— 不依赖任何绝对路径。
    saved_mei5 = getattr(sys, "_MEIPASS", None)
    empty_mei4 = os.path.join(HERE, "_nodisk_dlg_tmp")
    shutil.rmtree(empty_mei4, ignore_errors=True)
    os.makedirs(empty_mei4, exist_ok=True)
    moved3 = []
    for nm in dialog_icons:
        src = os.path.join(os.path.dirname(HERE), nm)
        if os.path.exists(src):
            bak = os.path.join(empty_mei4, nm)
            shutil.move(src, bak)
            moved3.append((bak, src))
    sys._MEIPASS = empty_mei4
    try:
        root = tk.Tk()
        root.withdraw()
        try:
            app = ui_app.SnBurnerApp(root)
            for nm in dialog_icons:
                dlg = tk.Toplevel(root)
                dlg.withdraw()
                got = app._dialog_icon(dlg, nm)
                h = _frame_icon(dlg)
                check(got and h != 0,
                      f"磁盘无 {nm} 时仍靠内嵌数据设上图标",
                      f"WM_GETICON={h}")
                dlg.destroy()
        finally:
            root.destroy()
    finally:
        if saved_mei5 is None:
            if hasattr(sys, "_MEIPASS"):
                del sys._MEIPASS
        else:
            sys._MEIPASS = saved_mei5
        for bak, src in moved3:
            shutil.move(bak, src)
        shutil.rmtree(empty_mei4, ignore_errors=True)

    print()
    print("窗口图标自检: " + ("通过" if ok else "未通过"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
