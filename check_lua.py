#!/usr/bin/env python3
"""Lua 框架静态检查：括号配平 / local function 前向引用 / 裸调用未定义全局 / require 路径存在性"""
import os
import re
import sys

LUA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lua")

LUA_BUILTINS = {
    "assert", "error", "ipairs", "next", "pairs", "pcall", "print", "select",
    "tonumber", "tostring", "type", "xpcall", "setmetatable", "getmetatable",
    "rawget", "rawset", "rawequal", "rawlen", "unpack", "require", "collectgarbage",
    "os", "io", "math", "string", "table", "coroutine", "debug", "package", "_G", "_VERSION",
}
LUA_KEYWORDS = {
    "and", "or", "not", "return", "function", "end", "local", "if", "then", "else",
    "elseif", "for", "in", "do", "while", "repeat", "until", "break", "goto",
    "true", "false", "nil", "self",
}
KNOWN_GLOBALS = {
    "sys", "uart", "gpio", "log", "fskv", "json", "mqtt", "mobile", "rtos", "mcu",
    "wdt", "socket", "get_device_sn", "PROJECT", "VERSION", "BUILD_ID", "vcom_handle",
}
BLOCK_OPENERS = re.compile(r"\b(function|if|do|while|for|repeat)\b")
BLOCK_CLOSERS = re.compile(r"\b(end|until)\b")


def strip_comments_and_strings(src):
    """返回 (去注释去字符串的代码, 错误列表)。保留换行以维持行号。"""
    out = []
    errors = []
    i, n = 0, len(src)
    line = 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            out.append(c)
            i += 1
            continue
        # 注释：-- 后跟 [[ 或 [=[ 为长注释，否则为单行注释
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + len(m.group(0)))
                if j == -1:
                    errors.append(f"未闭合长注释 于行 {line}")
                    break
                line += src.count("\n", i, j)
                out.append(" " * (j + len(close) - i))
                i = j + len(close)
                continue
            j = src.find("\n", i)
            if j == -1:
                j = n
            out.append(" " * (j - i))
            i = j
            continue
        # 长注释/长字符串
        if c == "[" and i + 1 < n and src[i + 1] in "[=":
            m = re.match(r"\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + len(m.group(0)))
                if j == -1:
                    errors.append(f"未闭合长注释/字符串 于行 {line}")
                    break
                line += src.count("\n", i, j)
                out.append(" " * (j + len(close) - i))
                i = j + len(close)
                continue
        # 字符串
        if c in "\"'":
            q = c
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == q:
                    break
                if src[j] == "\n":
                    line += 1
                j += 1
            if j >= n:
                errors.append(f"未闭合字符串 于行 {line}")
                break
            out.append('"' + " " * (j - i - 1) + '"')
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), errors


def check_balance(code, path, errors):
    """检查块关键字与括号配平。
    规则: for/while 后的 do 不单独计; elseif 的 if 不计;
    一行式 if...then...end 的 if 与 end 互抵不计。"""
    lines = code.split("\n")
    opens = 0
    closes = 0
    for line in lines:
        toks = [m.group(1) for m in re.finditer(r"\b(function|if|do|while|for|repeat|end|until|elseif)\b", line)]
        if not toks:
            continue
        has_then = re.search(r"\bthen\b", line) is not None
        has_end = "end" in toks
        oneline_if = has_then and has_end and "if" in toks
        oneline_loop = (("for" in toks) or ("while" in toks)) and "do" in toks and "end" in toks
        if oneline_if or oneline_loop:
            continue
        for t in toks:
            if t == "elseif":
                continue
            if t in ("function", "repeat"):
                opens += 1
            elif t in ("end", "until"):
                closes += 1
            elif t == "if":
                opens += 1
            elif t == "do":
                if not (("for" in toks) or ("while" in toks)):
                    opens += 1
            elif t in ("for", "while"):
                opens += 1
    if opens != closes:
        errors.append(f"{path}: 块关键字不配平 opener={opens} closer={closes}")
    # 括号配平
    for a, b, name in [("(", ")", "圆括号"), ("{", "}", "花括号"), ("[", "]", "方括号")]:
        if code.count(a) != code.count(b):
            errors.append(f"{path}: {name}不配平 {a}={code.count(a)} {b}={code.count(b)}")


def scan_functions(code):
    """返回 [(name, line)] 的 local function 声明位置"""
    decls = []
    for m in re.finditer(r"\blocal\s+function\s+([A-Za-z_]\w*)", code):
        line = code.count("\n", 0, m.start()) + 1
        decls.append((m.group(1), line))
    return decls


def check_forward_refs(code, path, errors):
    """local function 在声明前被调用"""
    decls = dict()
    for name, line in scan_functions(code):
        decls.setdefault(name, []).append(line)
    if not decls:
        return
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\(", code):
        name = m.group(1)
        if name not in decls:
            continue
        # 跳过声明本身和 function name( 定义形式
        pos = m.start()
        pre = code[max(0, pos - 20):pos]
        if re.search(r"\blocal\s+function\s+$", pre) or re.search(r"\bfunction\s+$", pre):
            continue
        call_line = code.count("\n", 0, pos) + 1
        first_decl = min(decls[name])
        if call_line < first_decl:
            errors.append(f"{path}:{call_line}: local function '{name}' 在声明(行{first_decl})前被调用")


def check_undefined_calls(code, path, errors):
    """裸调用 NAME( 且本文件无 local 声明也不属于内置/已知全局"""
    local_names = set()
    for m in re.finditer(r"\blocal\s+(?:function\s+)?([A-Za-z_]\w*)", code):
        local_names.add(m.group(1))
    for m in re.finditer(r"\blocal\s+([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*)", code):
        local_names.add(m.group(1))
        local_names.add(m.group(2))
    # 函数参数名
    for m in re.finditer(r"\bfunction\s*[^(]*\(([^)]*)\)", code):
        for p in m.group(1).split(","):
            p = p.strip()
            if re.match(r"^[A-Za-z_]\w*$", p):
                local_names.add(p)
    # for 变量
    for m in re.finditer(r"\bfor\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s+in\b", code):
        for p in m.group(1).split(","):
            local_names.add(p.strip())
    # 字段调用 obj:method() / obj.method() 已带前缀，只查裸调用
    for m in re.finditer(r"(?<![.:\w])([A-Za-z_]\w*)\s*\(", code):
        name = m.group(1)
        if name in local_names or name in KNOWN_GLOBALS or name in LUA_KEYWORDS or name in LUA_BUILTINS:
            continue
        pre = code[max(0, m.start() - 20):m.start()]
        if re.search(r"\blocal\s+function\s+$", pre) or re.search(r"\bfunction\s+$", pre):
            continue
        # return f( / and f( / or f( / not f( 这类：前面是关键字+空格，跳过
        if re.search(r"\b(return|and|or|not|elseif|if|while|until|then|do)\s+$", pre):
            continue
        line = code.count("\n", 0, m.start()) + 1
        errors.append(f"{path}:{line}: 调用了未定义的 '{name}'(非局部/非内置/非已知全局)")


def strip_comments_only(src):
    """只剥注释(保留字符串), 用于 require 类检查——注释里提到 require 不算引用"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "\n":
            out.append(c)
            i += 1
            continue
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + len(m.group(0)))
                if j == -1:
                    break
                out.append(" " * (j + len(close) - i))
                i = j + len(close)
                continue
            j = src.find("\n", i)
            if j == -1:
                j = n
            out.append(" " * (j - i))
            i = j
            continue
        if c == '"' or c == "'":
            q = c
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == q:
                    break
                j += 1
            out.append(src[i:j + 1])
            i = j + 1
            continue
        if c == "[" and i + 1 < n and src[i + 1] in "[=":
            m = re.match(r"\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + len(m.group(0)))
                if j == -1:
                    break
                out.append(src[i:j + len(close)])
                i = j + len(close)
                continue
        out.append(c)
        i += 1
    return "".join(out)


def check_requires(files, raw_files, errors):
    """require 模块必须对应存在的 lua 文件。
    覆盖两种写法: require "x/y" 与 pcall(require, "x/y")
    注意: 必须在原始源码上匹配, 且剥掉注释(注释里提到不算引用)"""
    for f, src in raw_files.items():
        code = strip_comments_only(src)
        for m in re.finditer(r'require\s*,?\s*\(?\s*"([^"]+)"', code):
            mod = m.group(1)
            if "/" not in mod:
                continue
            p1 = os.path.join(LUA_DIR, mod.replace(".", "/") + ".lua")
            p2 = os.path.join(LUA_DIR, mod.split("/")[-1] + ".lua")
            if not os.path.exists(p1) and not os.path.exists(p2):
                line = src.count("\n", 0, m.start()) + 1
                errors.append(f"{f}:{line}: require '{mod}' 找不到文件")


def check_string_format(src, path, errors):
    """32 位固件禁用清单: %f / %0Nd / %0Nx 用于数值格式化时有问题。
    例外: %02x/%04x 等对 0-255 字节做 hex 转义是安全的(hex dump / \\u 转义)"""
    for m in re.finditer(r'string\.format\(\s*"([^"]*)"', src):
        fmt = m.group(1)
        bad = False
        if re.search(r"%[-+ #0]*\d*f", fmt):
            bad = True
        # 先把 \u%04x 这类字节转义抠掉, 剩下的 %0Nx 才是数值场景
        probe = re.sub(r"\\u%0?\d+x", "", fmt)
        for wm in re.finditer(r"%[-+ #0]*(\d+)x", probe):
            if int(wm.group(1)) >= 3:
                bad = True
        if bad:
            line = src.count("\n", 0, m.start()) + 1
            errors.append(f"{path}:{line}: string.format 用了 32 位固件不安全的格式 '{fmt}'")


CORE_LIBS = {
    "log", "sys", "uart", "gpio", "fskv", "json", "mqtt", "mobile", "rtos",
    "mcu", "wdt", "socket", "pack", "bit", "crypto", "string", "table",
    "math", "os", "io", "coroutine", "debug", "pm", "i2c", "spi", "adc",
}


def check_module_names(errors):
    """模块 basename 不能与核心库同名: Luatools 扫 require 'iot/mqtt' 会误判引用核心库"""
    for root, _, fs in os.walk(LUA_DIR):
        for f in fs:
            if not f.endswith(".lua"):
                continue
            base = f[:-4]
            if base in CORE_LIBS:
                rel = os.path.relpath(os.path.join(root, f), LUA_DIR)
                errors.append(f"{rel}: 模块名 '{base}' 与核心库同名, Luatools 会误判'多余核心库引用', 必须改名(如 {base}cfg.lua)")


def check_core_lib_require(src, path, errors):
    """Luatools 静态扫描: require 核心库(字面量)会被判'多余核心库引用'拒绝烧录。
    注意: 实测 Luatools 连【注释】里的 require "log" 字样都会扫到,
    所以除了剥注释后的代码, 还要对原始源码本身查一遍(注释也不许出现)。"""
    code = strip_comments_only(src)
    reported = set()
    for m in re.finditer(r'require\s*[,(]?\s*"([^"]+)"', code):
        mod = m.group(1)
        if mod in CORE_LIBS:
            line = code.count("\n", 0, m.start()) + 1
            reported.add((mod, line))
            errors.append(f"{path}:{line}: require 了核心库 '{mod}', Luatools 会拒绝烧录(核心库无需 require, 用 _G.{mod})")
    # 原始源码(含注释): 注释里出现核心库 require 字样同样会被 Luatools 扫到
    for m in re.finditer(r'require\s*[,(]?\s*"([^"]+)"', src):
        mod = m.group(1)
        if mod not in CORE_LIBS:
            continue
        line = src.count("\n", 0, m.start()) + 1
        if (mod, line) in reported:
            continue
        errors.append(f"{path}:{line}: 注释里出现 require \"{mod}\" 字样, 实测 Luatools 静态扫描会读到并拒绝烧录, 必须改写措辞")


def check_tonumber_nil(code, path, errors):
    """tonumber(x) 中 x 是裸 nil 字面量"""
    for m in re.finditer(r"\btonumber\(\s*nil\s*\)", code):
        line = code.count("\n", 0, m.start()) + 1
        errors.append(f"{path}:{line}: tonumber(nil) 在 LuatOS 会崩 VM")


def main():
    import io as _io
    sys.stdout = _io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    all_errors = []
    files = {}
    raw_files = {}
    lua_files = []
    for root, _, fs in os.walk(LUA_DIR):
        for f in fs:
            if f.endswith(".lua"):
                lua_files.append(os.path.join(root, f))
    lua_files.sort()
    for path in lua_files:
        rel = os.path.relpath(path, LUA_DIR)
        with open(path, "r", encoding="utf-8") as fh:
            src = fh.read()
        raw_files[rel] = src
        code, errs = strip_comments_and_strings(src)
        all_errors.extend(f"{rel}: {e}" for e in errs)
        files[rel] = code
        check_balance(code, rel, all_errors)
        check_forward_refs(code, rel, all_errors)
        check_undefined_calls(code, rel, all_errors)
        check_requires(files, raw_files, all_errors)
        check_string_format(src, rel, all_errors)
        check_tonumber_nil(src, rel, all_errors)
        check_core_lib_require(src, rel, all_errors)

    print(f"检查 {len(lua_files)} 个 Lua 文件")
    check_module_names(all_errors)
    if all_errors:
        print(f"\n发现 {len(all_errors)} 个问题:")
        for e in all_errors:
            print("  " + e)
        sys.exit(1)
    print("全部通过：括号配平 / 无前向引用 / 无裸调用未定义 / require 路径存在 / 无危险 format / 无 tonumber(nil)")


if __name__ == "__main__":
    main()
