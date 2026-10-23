"""从 main.lua 出发做静态依赖闭包，算出真正会进包的 .lua 文件清单与字节数。

LuatOS/LuaTools 按 require 静态扫描收集依赖：main.lua 够不到的文件
不会进包，也就不占 flash。这个脚本把闭包算出来，避免"目录里放了但
没进包"和"以为没进包其实进了"两种误判。

用法: python _pkg_closure.py
"""

import os
import re
import sys

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "soft_sn_demo")

# 核心库名：这些不是脚本文件，require 它们会被 LuaTools 判合并失败
CORE_LIBS = {"sys", "log", "uart", "fskv", "mobile", "mcu", "mqtt", "json",
             "bit", "bit32", "socket", "libgnss", "gpio", "net", "http",
             "i2c", "spi", "timer", "pwm", "adc", "io", "os", "string",
             "table", "math", "coroutine", "package", "debug"}

# 覆盖三种写法：
#   require "x"          require("x")          pcall(require, "x")
# 第三种在本工程大量使用（分层加载，失败只打 [SKIP] 不挡开机），
# 正则必须认它，否则闭包会漏算、把实际进包的目录误判成"够不到"。
REQ = re.compile(r'require\s*[(,]?\s*["\']([\w%.%-]+)["\']')


def closure(entry: str):
    seen, order, missing = set(), [], []

    def walk(name: str):
        if name in seen:
            return
        seen.add(name)
        order.append(name)
        path = os.path.join(BASE, name + ".lua")
        if not os.path.isfile(path):
            missing.append(name)
            return
        text = open(path, encoding="utf-8").read()
        for m in REQ.finditer(text):
            dep = m.group(1)
            if dep in CORE_LIBS:
                continue
            # LuaTools 把点当字面字符，所以 X.Y 不是路径分隔
            if dep.count("."):
                continue
            walk(dep)

    walk(entry)
    return order, missing


def main():
    order, missing = closure("main")

    print("从 main.lua 出发的静态依赖闭包（这些才会进包）:")
    total = 0
    for i, name in enumerate(order, 1):
        p = os.path.join(BASE, name + ".lua")
        if os.path.isfile(p):
            n = os.path.getsize(p)
            total += n
            print(f"  {i}. {name + '.lua':<22} {n:>6} B")
        else:
            print(f"  {i}. {name + '.lua':<22} 缺失!")
    print(f"\n  合计 {total} B = {total / 1024:.2f} KB")

    # 目录里存在但够不到的文件
    all_files = {f[:-4] for f in os.listdir(BASE) if f.endswith(".lua")}
    unreached = sorted(all_files - set(order))
    print(f"\n目录中共 {len(all_files)} 个 .lua，闭包外 {len(unreached)} 个"
          f"（不进包、不占 flash）:")
    extra = 0
    for name in unreached:
        n = os.path.getsize(os.path.join(BASE, name + ".lua"))
        extra += n
        print(f"    {name + '.lua':<22} {n:>6} B  跳过")
    print(f"  合计 {extra} B = {extra / 1024:.2f} KB")

    if missing:
        print(f"\n[警告] 闭包内有 {len(missing)} 个 require 找不到文件: "
              f"{', '.join(missing)}")
        return 1
    print("\n闭包完整，无缺失依赖。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
