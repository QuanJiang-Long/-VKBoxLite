"""核对串口插拔自动刷新。一次性脚本，不并入 build.ps1。

用一个假的 _registry_ports 造出"插拔"效果，验证：
  1. 插上一个新口 -> 下拉自动多出这一项，不发断开流程
  2. 拔掉正连着的口 -> 走断开流程，状态灯变红
  3. 拔掉没连着的已选口 -> 只切回自动识别 + 提示
  4. 读注册表抛异常 -> 轮询不中断（下一轮照样排上）
"""

import os
import sys
import tkinter as tk

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import ui_app                                       # noqa: E402
from ui_app import SnBurnerApp, PORT_POLL_MS        # noqa: E402

fails = []


def check(cond, msg):
    print(("  OK   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


# 假的注册表读数：一个可变的列表，测试里改它就等于插拔设备
FAKE = {"ports": ["COM3", "COM7"]}


def fake_registry():
    return list(FAKE["ports"])


def fake_list_ports():
    # 与真实 list_ports 同一套排序：按编号升序
    return sorted(FAKE["ports"], key=lambda p: int(p[3:]))


ui_app._registry_ports = fake_registry
ui_app.list_ports = fake_list_ports

root = tk.Tk()
root.withdraw()
app = SnBurnerApp(root)
root.update()

# --- 基线 ---
# ⚠️ 占位项文案：ui_app 用的是【请选择串口】（不是老版的"自动识别"）。
#    界面改成"手动选 + 刷新"之后占位项就换名了，这里跟着改。
check(set(app.port_cb["values"]) == {"请选择串口", "COM3", "COM7"},
      f"基线下拉 = 请选择串口 + COM3/COM7，实际 {list(app.port_cb['values'])}")

# --- 1) 插上一个新口 ---
app.port_var.set("COM7")
FAKE["ports"] = ["COM3", "COM7", "COM12"]
app._poll_ports()
root.update()
check("COM12" in list(app.port_cb["values"]),
      f"插入 COM12 后下拉自动多出它: {list(app.port_cb['values'])}")
check(app.port_var.get() == "COM7", "插入新口不影响当前选择")
check(app.port is None, "插入新口不触发断开")

# --- 2) 拔掉正连着的口 -> 断开流程 ---
app.port_var.set("COM12")


class FakePort:
    port = "COM12"
    is_open = True

    def close(self):
        pass


app.port = FakePort()
app.device = object()
app.burner = object()
app.burn_btn.configure(state="normal")
FAKE["ports"] = ["COM3", "COM7"]
app._poll_ports()
root.update()
check(app.port is None, f"拔掉正连着的口 -> 已断开（port={app.port}）")
check(app.status_lbl.cget("text") == "已断开",
      f"状态显示已断开: {app.status_lbl.cget('text')!r}")
check(str(app.burn_btn.cget("state")) == "disabled", "烧录按钮被禁用")
check(app.port_var.get() == "请选择串口", f"选择切回请选择串口: {app.port_var.get()!r}")

# --- 3) 拔掉没连着的已选口 -> 只切回自动识别 ---
app.port = None
app.port_var.set("COM3")
FAKE["ports"] = ["COM7"]
app._poll_ports()
root.update()
check(app.port_var.get() == "请选择串口",
      f"拔掉未连接的已选口 -> 切回请选择串口: {app.port_var.get()!r}")
check("COM3" not in list(app.port_cb["values"]), "COM3 已从下拉移除")

# --- 4) 读注册表抛异常 -> 轮询不中断 ---
app.port_var.set("COM7")
FAKE["ports"] = ["COM7", "COM20"]


def boom():
    raise OSError("registry unavailable")


ui_app._registry_ports = boom
try:
    app._poll_ports()
    ok = True
except Exception as e:                             # noqa: BLE001
    ok = False
    print(f"    异常: {e}")
check(ok, "注册表读取失败不向上抛异常")
# 恢复后下一轮还能正常工作（证明 finally 里的 after 排上了）
ui_app._registry_ports = fake_registry
FAKE["ports"] = ["COM7", "COM20", "COM25"]
app._poll_ports()
root.update()
check("COM25" in list(app.port_cb["values"]),
      f"恢复后轮询继续工作: {list(app.port_cb['values'])}")

# --- 5) 轮询间隔常量存在且在合理范围 ---
check(800 <= PORT_POLL_MS <= 3000, f"轮询间隔 {PORT_POLL_MS}ms 在合理范围")

root.destroy()
print("\n" + ("全部通过" if not fails else f"有 {len(fails)} 项失败: {fails}"))
sys.exit(1 if fails else 0)
