"""依赖图检查：require 关系建图，检测循环依赖与缺失模块"""
import os
import re
import sys

LUA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lua")

def get_requires(path):
    src = open(path, encoding="utf-8").read()
    mods = []
    for m in re.finditer(r'require\s*\(?\s*"([^"]+)"', src):
        mods.append(m.group(1))
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
    missing = []
    for path in files:
        rel = os.path.relpath(path, LUA_DIR)
        deps = []
        for mod in get_requires(path):
            r = resolve(mod)
            if r is None:
                if "/" in mod:
                    missing.append(f"{rel}: require '{mod}' 无法解析到文件")
                continue
            deps.append(os.path.relpath(r, LUA_DIR))
        graph[rel] = deps

    # 循环检测（DFS）
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {k: WHITE for k in graph}
    cycles = []

    def dfs(node, stack):
        color[node] = GRAY
        for dep in graph.get(node, []):
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
