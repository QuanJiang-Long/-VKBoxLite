"""Luatools 静态扫描兼容性预检（烧录前必跑）。

背景（真机踩坑，2026-09-25）：
    Luatools 靠文本扫描收集 .lua 依赖，它抓模块名的正则疑似贪婪：
    从 require( 之后的第一个引号，一直匹配到【该行最后一个引号】。
    所以只要一行里 require( 后面还出现别的引号字符串，抓出来的
    "模块名"就是一长串垃圾，报：
        合并失败: 缺少 <垃圾>.lua 请添加
    烧录直接失败，而 Lua 语法完全正常、PC 单测全绿 —— 只有真机烧录
    才暴露。本脚本把这类行在烧录前揪出来。

另外一并检查：
    R1  同一行不得同时出现 require 和核心库名字面量（Luatools 判合并失败）
    R2  require 的目标文件必须真实存在
    R3  从 main.lua 出发的依赖闭包必须完整（够不到的文件进不了包）

用法: python _luatools_lint.py [脚本目录]
"""

import os
import re
import sys

CORE_LIBS = {"sys", "log", "uart", "fskv", "mobile", "mcu", "mqtt", "json",
             "bit", "bit32", "socket", "libgnss", "gpio", "net", "http",
             "i2c", "spi", "timer", "pwm", "adc", "io", "os", "string",
             "table", "math", "coroutine", "package", "debug"}

DEFAULT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "soft_sn_demo")

# require( 或 require + 引号 的两种形态
REQ_CALL = re.compile(r'require\s*\(')
REQ_BARE = re.compile(r'require\s+["\']')
# 一行里所有引号字符串
QUOTED = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')


def lint_file(path: str):
    """返回该文件的 (错误列表, 警告列表)。"""
    errs, warns = [], []
    rel = os.path.basename(path)
    lines = open(path, encoding="utf-8").read().split("\n")

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("--"):
            continue                      # 注释不参与扫描（Luatools 也不看）

        # R1: require 与核心库名同一行
        if re.search(r'require', line):
            for lib in CORE_LIBS:
                if re.search(r'["\']' + lib + r'["\']', line):
                    errs.append(f"{rel}:{i} [R1] 同一行出现 require 和核心库 "
                                f"'{lib}' 字面量，Luatools 会判合并失败")

        # R2: require( 之后同行还有其他引号字符串 -> 贪婪正则抓错模块名
        if REQ_CALL.search(line):
            # 找 require( 之后第一个引号的位置
            m = REQ_CALL.search(line)
            after = line[m.end():]
            quotes = QUOTED.findall(after)
            if len(quotes) > 1:
                # 模拟贪婪正则：从第一个引号后到该行最后一个引号
                first_open = after.find(quotes[0][0])
                last_close = after.rfind(quotes[-1][-1])
                grabbed = after[first_open + 1:last_close]
                errs.append(
                    f"{rel}:{i} [R2] require( 之后同行还有 {len(quotes)} 个"
                    f"引号字符串，Luatools 贪婪扫描会把模块名抓成 "
                    f"'{grabbed[:60]}' -> 合并失败。"
                    f"请把后续语句换行。")

        # R2b: require 裸调用的目标不存在（变量形式跳过）
        for m in re.finditer(r'require\s*\(?\s*["\']([\w%.%-]+)["\']', line):
            name = m.group(1)
            if name in CORE_LIBS:
                continue
            if "." in name:
                continue                  # LuaTools 把点当字面字符
            target = os.path.join(os.path.dirname(path), name + ".lua")
            if not os.path.isfile(target):
                errs.append(f"{rel}:{i} [R2b] require('{name}') 但 "
                            f"{name}.lua 不存在")

    return errs, warns


def closure(base: str, entry: str = "main"):
    """从 entry 出发的静态依赖闭包。"""
    seen, order = set(), []

    def walk(name):
        if name in seen:
            return
        seen.add(name)
        order.append(name)
        p = os.path.join(base, name + ".lua")
        if not os.path.isfile(p):
            return
        text = open(p, encoding="utf-8").read()
        for m in re.finditer(r'require\s*[(,]?\s*["\']([\w%.%-]+)["\']', text):
            dep = m.group(1)
            if dep in CORE_LIBS or "." in dep:
                continue
            walk(dep)

    walk(entry)
    return order


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR
    base = os.path.abspath(base)
    if not os.path.isdir(base):
        print(f"[FAIL] 目录不存在: {base}")
        return 1

    files = sorted(f for f in os.listdir(base) if f.endswith(".lua"))
    print(f"扫描 {base} 下 {len(files)} 个 .lua\n")

    all_errs = []
    for f in files:
        errs, _ = lint_file(os.path.join(base, f))
        all_errs.extend(errs)

    for e in all_errs:
        print("  [FAIL] " + e)
    if not all_errs:
        print("  [OK] 未发现 Luatools 扫描不兼容的写法")

    # 闭包检查
    print()
    order = closure(base)
    total = sum(os.path.getsize(os.path.join(base, n + ".lua"))
                for n in order
                if os.path.isfile(os.path.join(base, n + ".lua")))
    print(f"  依赖闭包({len(order)} 个文件, {total} B = {total/1024:.2f} KB):")
    for n in order:
        mark = "" if os.path.isfile(os.path.join(base, n + ".lua")) else "  <-- 缺失!"
        print(f"    {n + '.lua':<24}{mark}")
    outside = sorted(set(f[:-4] for f in files) - set(order))
    if outside:
        extra = sum(os.path.getsize(os.path.join(base, n + ".lua")) for n in outside)
        print(f"  闭包外 {len(outside)} 个（不进包、不占 flash，共 {extra} B）: "
              f"{', '.join(outside)}")

    missing = [n for n in order
               if not os.path.isfile(os.path.join(base, n + ".lua"))]
    if missing:
        for n in missing:
            print(f"  [FAIL] 闭包内 {n}.lua 缺失")
        all_errs.append("closure missing")

    print()
    if all_errs:
        print(f"结果: {len(all_errs)} 个问题，修复后再烧录")
        return 1
    print("结果: 通过，可以烧录")
    return 0


if __name__ == "__main__":
    sys.exit(main())
