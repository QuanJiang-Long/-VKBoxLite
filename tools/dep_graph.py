"""依赖图检查：require 关系建图，检测循环依赖与缺失模块"""
import os
import re
import sys

LUA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lua")

def get_requires(path):
    """返回 [(模块名, 是否惰性)]。

    ⚠️ 12-fix-8 (2026-10-28): 惰性 require 写成 pcall(require, "x"),
    中间那个逗号会让老正则漏掉这条依赖 —— 依赖图少画一条边,
    循环依赖就检测不出来。所以这里把逗号也算进去。

    惰性(pcall(require, ...))的边【不参与】加载期循环检测:
    它在函数被调用时才加载, 而那时对方模块多半已经加载完了,
    不构成"加载 A 时又去加载 B、B 又回头加载 A"的死锁。
    12-fix-8 之后 bus/ctrl <-> bus/poll 就是这种关系:
    ctrl 惰性拉 poll, poll 顶层 require ctrl —— 谁先被加载都安全。
    """
    src = open(path, encoding="utf-8").read()
    mods = []
    for m in re.finditer(r'(pcall\s*\(\s*)?require\s*\(?\s*,?\s*"([^"]+)"', src):
        lazy = m.group(1) is not None
        mods.append((m.group(2), lazy))
    return mods

def resolve(mod):
    """把模块名解析为文件路径（优先 子目录/名.lua，退回平铺 名.lua）"""
    if "/" in mod:
        p = os.path.join(LUA_DIR, mod + ".lua")
        if os.path.exists(p):
            return p
        p2 = os.path.join(LUA_DIR, mod.split("/")[-1] + ".lua")
        if os.path.exists(p2):
            return p2
        return None
    return None  # 系统库不追

def main():
    files = {}
    for root, _, fs in os.walk(LUA_DIR):
        for f in fs:
            if f.endswith(".lua"):
                files[os.path.join(root, f)] = None
    graph = {}
    eager = {}          # 加载期依赖(参与循环检测)
    missing = []
    for path in files:
        rel = os.path.relpath(path, LUA_DIR)
        deps = []
        edeps = []
        for mod, lazy in get_requires(path):
            r = resolve(mod)
            if r is None:
                if "/" in mod:
                    missing.append(f"{rel}: require '{mod}' 无法解析到文件")
                continue
            d = os.path.relpath(r, LUA_DIR)
            if d not in deps:
                deps.append(d)
            if not lazy and d not in edeps:
                edeps.append(d)
        graph[rel] = deps
        eager[rel] = edeps

    # 循环检测（DFS）—— 只走【加载期】依赖, 惰性边不参与(见 get_requires 的说明)
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {k: WHITE for k in graph}
    cycles = []

    def dfs(node, stack):
        color[node] = GRAY
        for dep in eager.get(node, []):
            if color.get(dep) == GRAY:
                cycles.append(" -> ".join(stack + [node, dep]))
            elif color.get(dep) == WHITE:
                dfs(dep, stack + [node])
        color[node] = BLACK

    for k in graph:
        if color[k] == WHITE:
            dfs(k, [])

    print(f"模块数: {len(graph)}")
    total_edges = sum(len(v) for v in graph.values())
    print(f"内部依赖边: {total_edges}")
    print("\n依赖关系:")
    for k in sorted(graph):
        if graph[k]:
            print(f"  {k}")
            for d in graph[k]:
                print(f"    -> {d}")
    if missing:
        print("\n缺失:")
        for m in missing:
            print("  " + m)
    if cycles:
        print("\n循环依赖!")
        for c in cycles:
            print("  " + c)
        sys.exit(1)
    print("\n无循环依赖")


if __name__ == "__main__":
    main()
