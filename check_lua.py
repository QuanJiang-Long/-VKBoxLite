#!/usr/bin/env python3
"""Lua 框架静态检查：括号配平 / local function 前向引用 / 裸调用未定义全局 / require 路径存在性"""
import os
import re
import subprocess
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
    # ⚠️ 必须排除 . / : 前缀: obj:publish() 是方法调用, 与同名的文件级
    # local function publish 毫无关系。少了这个前瞻, 只要有个同名局部函数
    # 声明在后面, 所有早于它的方法调用都会误报 —— 实测 iot.lua 抽 pub()
    # helper 时就踩到: S.client:publish() 被当成调用第 270 行的 publish
    for m in re.finditer(r"(?<![.:\w])([A-Za-z_]\w*)\s*\(", code):
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


def collect_declared(code, path, errors):
    """本文件声明过的名字全集：local / 参数 / for 变量 / 函数名 / 模块局部 M、S 之类。
    粗粒度(不分嵌套作用域)即可：判据是"读一个本文件从没声明过的自由变量"，
    作用域边界不影响结论——嵌套块里的 local 在文件别处当然也可能合法。"""
    names = set()
    # local a / local a, b / local function f
    for m in re.finditer(r"\blocal\s+(?!function\b)([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)", code):
        for p in m.group(1).split(","):
            names.add(p.strip())
    for m in re.finditer(r"\blocal\s+function\s+([A-Za-z_]\w*)", code):
        names.add(m.group(1))
    # function(...) / local function f(...) 的参数
    for m in re.finditer(r"\bfunction\s*[^(]*\(([^)]*)\)", code):
        for p in m.group(1).split(","):
            p = p.strip()
            if re.match(r"^[A-Za-z_]\w*$", p):
                names.add(p)
    # for a / for a, b in ...
    for m in re.finditer(r"\bfor\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s+in\b", code):
        for p in m.group(1).split(","):
            names.add(p.strip())
    # 数值 for: for i = 0, 255 do
    for m in re.finditer(r"\bfor\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*=", code):
        for p in m.group(1).split(","):
            names.add(p.strip())
    # 模块局部前缀：M.xxx = / S.xxx = / M.xxx, S.yyy =
    for m in re.finditer(r"^\s*([A-Za-z_]\w*)\s*\.\s*[A-Za-z_]\w*\s*=", code, re.M):
        names.add(m.group(1))
    # 纯下划线占位 for _ = 1, n
    names.add("_")
    return names


def check_undeclared_reads(code, path, errors):
    """读一个本文件没声明过、也不是内置/已知全局的自由变量。

    粗粒度版(整文件扫一遍): 只能抓"整个文件从没出现过 this 名字"的情况。
    细粒度按作用域扫的版本见 check_scope_reads —— 那才是修 recv_push
    丢行事故的规则: r/err 在本文件别处是 local, 粗粒度抓不到,
    必须按"声明早于使用且在同一可见作用域内"判。"""
    declared = collect_declared(code, path, errors)
    allowed = declared | LUA_BUILTINS | LUA_KEYWORDS | KNOWN_GLOBALS
    # 成员访问 obj.name / 调用 obj:name() 的 obj 不是自由变量
    for m in re.finditer(r"(?<![.:\w])([A-Za-z_]\w*)\s*(?=[.\[:])", code):
        if m.group(1) not in allowed:
            line = code.count("\n", 0, m.start()) + 1
            errors.append(f"{path}:{line}: 读了未声明的 '{m.group(1)}' (非局部/非内置/非已知全局)")
    # 裸标识符：出现在运算符/关键字旁边的读，或者是第一个实参
    for m in re.finditer(r"(?<![.:\w])([A-Za-z_]\w*)(?![.\w])", code):
        name = m.group(1)
        if name in allowed:
            continue
        # 形如 `M.xx =` 的值、`local` 声明、函数定义左侧都不算读
        pre = code[max(0, m.start() - 30):m.start()]
        post = code[m.end():m.end() + 30]
        if re.search(r"\blocal\s+$", pre):
            continue
        if re.search(r"[.\[\w:]\s*$", pre):
            continue
        if re.match(r"^\s*([.=,)\]]|\bend\b|\bfunction\b)", post):
            continue
        line = code.count("\n", 0, m.start()) + 1
        errors.append(f"{path}:{line}: 读了未声明的 '{name}' (非局部/非内置/非已知全局)")


# 词法记号。顺序即优先级: "local function" 必须先于 "local" 匹配掉
TOK = re.compile(r"""
    (?P<lf>\blocal\s+function\s+(?P<lfname>[A-Za-z_]\w*))
  | (?P<loc>\blocal\s+(?!function\b)(?P<lvars>[A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*))
  | (?P<open>\b(?P<kw>function|if|for|while|do|repeat)\b)
  | (?P<close>\b(?P<ender>end|until)\b)
  | (?P<number>0[xX][0-9a-fA-F_]+|\d[\d_.]*(?:[eE][-+]?\d+)?)
  | (?P<name>[A-Za-z_]\w*)
""", re.X)


def _params_after(code, pos):
    """从 pos 起找函数的形参表。兼容 function f(a,b) / function M.f(a) /
    function M:f(a) / function(a)。取不到就返回空。"""
    m = re.match(r"\s*([A-Za-z_]\w*[\w.:]*)?\s*\(([^)]*)\)", code[pos:])
    if not m:
        return []
    out = []
    for p in m.group(2).split(","):
        p = p.strip()
        if re.match(r"^[A-Za-z_]\w*$", p):
            out.append(p)
    return out


def _for_vars_after(code, pos):
    """for 头部变量: for a, b in ... / for i = 1, 10 ..."""
    m = re.match(r"\s*([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*(?:in|=)", code[pos:])
    if not m:
        return []
    return [p.strip() for p in m.group(1).split(",")]


M_FIELDS = re.compile(r"(?<![.:\w])(M)\.([A-Za-z_]\w*)")


def check_m_fields(code, path, errors):
    """M.xxx 读的字段必须在同一文件里被赋值/定义过。

    本工程所有模块都用 `local M = {} ... function M.foo()` 这套导出模式，
    把导出改成 local（或反过来改调用方）时，另一边对不上只会得到 nil。
    pcall(M.xxx) / M.xxx() 这种写法把错误彻底吞掉——真实事故：
    iot.lua 把 handle_downlink 降级成 local function 后漏改调用点，
    结果是所有 MQTT 下行都不再被处理，且无任何报错。
    只查 M 这一个名字：它是本工程唯一的模块表约定，别的 obj.field
    谁是谁根本看不出来，查了只会误报。"""
    defined = set()
    for m in re.finditer(r"\bM\.([A-Za-z_]\w*)\s*=", code):
        defined.add(m.group(1))
    for m in re.finditer(r"\bfunction\s+M\.([A-Za-z_]\w*)", code):
        defined.add(m.group(1))
    if not defined:
        return
    for m in M_FIELDS.finditer(code):
        fld = m.group(2)
        if fld in defined:
            continue
        post = code[m.end():m.end() + 20]
        if re.match(r"^\s*=", post):            # M.xxx = 赋值本身
            continue
        line = code.count("\n", 0, m.start()) + 1
        errors.append(f"{path}:{line}: 读了本文件未定义的 'M.{fld}' (字段没赋值/没定义, 运行时是 nil)")


def _brace_depth(code, pos):
    """pos 处的花括号嵌套深度(字符串已剥成空格, 计数安全)"""
    return (code.count("{", 0, pos) - code.count("}", 0, pos)) // 1


def check_scope_reads(code, path, errors):
    """按作用域查"读了当前不可见的自由变量"。

    这是本次 iot.lua recv_push 丢行事故的根因规则: 编辑时把
    `local r, err = pullcfg.parse_snap(...)` 那行碰掉了，函数体里留着
    `if not r then` —— r/err 变成全局，运行时恒 nil，表现是
    "平台主动重推永远解析失败"且不报任何语法错。之前的规则都抓不到:
    括号仍配平、r 不是调用所以"裸调用未定义"不命中、r 在本文件别处
    确实是 local 所以整文件扫也看不出来。

    作用域模型(故意简化，只保证不漏报、不误报最常见的形态):
      push: function / if / for / while / do(非 for/while 的) / repeat
      pop:  end / until
      local 与形参加进当前栈顶; for 头变量加进 for 自己的作用域。
    判定只看"名字在栈上任一层或内置/已知全局里"，所以 if/else 分支
    之间串味只会造成漏报，不会误报。"""
    stack = [set()]
    header_do = False
    for m in TOK.finditer(code):
        kind = m.lastgroup
        if kind == "lf":                                  # local function f
            stack[-1].add(m.group("lfname"))
            stack.append(set(_params_after(code, m.end())))
        elif kind == "loc":                               # local a, b
            for p in m.group("lvars").split(","):
                stack[-1].add(p.strip())
        elif kind == "open":
            kw = m.group("kw")
            if kw in ("for", "while"):
                stack.append(set(_for_vars_after(code, m.end())))
                header_do = True
            elif kw == "do":
                if header_do:
                    header_do = False                   # for/while 的 do, 不另开作用域
                else:
                    stack.append(set())
            else:                                        # function / if / repeat
                stack.append(set(_params_after(code, m.end())))
        elif kind == "close":
            if len(stack) > 1:
                stack.pop()
            else:
                line = code.count("\n", 0, m.start()) + 1
                errors.append(f"{path}:{line}: 多出的 '{m.group('ender')}'(作用域栈已空)")
        elif kind == "name":
            name = m.group()
            if name in LUA_KEYWORDS or name in LUA_BUILTINS or name in KNOWN_GLOBALS:
                continue
            visible = set()
            for sc in stack:
                visible |= sc
            if name in visible:
                continue
            pre = code[max(0, m.start() - 30):m.start()]
            post = code[m.end():m.end() + 30]
            if re.search(r"[.:]\s*$", pre):              # obj.name 的 name 段
                continue
            # 表构造器里的键: { a = 1, b = 2 }。深度>0 且后跟 = 的是键不是读
            if re.match(r"^\s*=", post) and _brace_depth(code, m.start()) > 0:
                continue
            line = code.count("\n", 0, m.start()) + 1
            errors.append(f"{path}:{line}: 读了作用域内不可见的 '{name}' (未声明且非内置/已知全局)")


def _block_delta(ln):
    """一行对块嵌套深度的贡献。for/while 自带的那个 do 不能重复计数：
    `while x do ... end` 只有一个 end 收尾。同行 if...end 自抵为 0。"""
    toks = re.findall(r"\b(function|if|for|while|do|repeat|end|until)\b", ln)
    opens = [t for t in toks if t in ("function", "if", "for", "while", "do", "repeat")]
    closes = [t for t in toks if t in ("end", "until")]
    if ("for" in toks or "while" in toks) and "do" in toks:
        opens.remove("do")
    return len(opens) - len(closes)


def _fn_bodies(code):
    """按 function 切出 [(名字, 归一化后的行集合)]。
    归一化: 去空行/注释/首尾空白, 便于比较"形状"而不是排版。"""
    lines = [ln.strip() for ln in code.split("\n")]
    lines = [ln for ln in lines if ln and not ln.startswith("-")]
    bodies = {}
    cur_name, cur = None, []
    depth = 0
    for ln in lines:
        m = re.match(r"^(?:local\s+)?function\s+([A-Za-z_][\w.:]*)", ln)
        if m and depth == 0:
            if cur_name and cur:
                bodies.setdefault(cur_name, set()).update(cur)
            cur_name, cur, depth = m.group(1), [ln], 1
            continue
        if cur_name:
            cur.append(ln)
            depth += _block_delta(ln)
            if depth <= 0:
                bodies.setdefault(cur_name, set()).update(cur)
                cur_name, cur, depth = None, [], 0
    if cur_name and cur:
        bodies.setdefault(cur_name, set()).update(cur)
    return bodies


def check_dup_bodies(code, path, errors):
    """两个函数体高度重复 -> 抄了两遍，改一处必漏另一处。

    本工程的真实教训: poll.probe_raw 与 poll.tx_raw 各写了一整套
    uart 准备/DE 拉高保保持/收发等待/恢复 on_receive, ~35 行重复,
    只有"帧从哪来"不同。判据用过采样行集合重合度, 只报 >=12 行相似
    且重合率 >=60% 的对, 不抓小巧合(几个 return false 谁都像)。
    """
    bodies = _fn_bodies(code)
    names = [n for n in bodies if n]
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            a, b = bodies[names[i]], bodies[names[j]]
            if not a or not b:
                continue
            inter = a & b
            if len(inter) < 12:
                continue
            rate = len(inter) / min(len(a), len(b))
            if rate >= 0.6:
                errors.append(
                    f"{path}: 函数 '{names[i]}' 与 '{names[j]}' 有 {len(inter)} 行重复"
                    f"(重合率 {rate:.0%})，应考虑抽公共实现")


def check_tonumber_nil(code, path, errors):
    """tonumber(x) 中 x 是裸 nil 字面量"""
    for m in re.finditer(r"\btonumber\(\s*nil\s*\)", code):
        line = code.count("\n", 0, m.start()) + 1
        errors.append(f"{path}:{line}: tonumber(nil) 在 LuatOS 会崩 VM")


def _restore(path, buf):
    """写回原文。newline="" 保证不把 LF 改成 CRLF——lua 目录全是 LF 文件"""
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(buf)


def _inject(buf, old_s, new_s):
    """原文 -> 注入后的内容。换不上去说明源码已变(注入失效)。"""
    if old_s not in buf:
        return None
    return buf.replace(old_s, new_s)


def selftest():
    """把历史上真实出过的事故注入一遍，确认对应规则真的会报错。

    不测"规则存在"，只测"规则对这类代码亮红灯"。每条注入跑完都还原，
    并在还原后再跑一次确认工作树干净。
    用法: python check_lua.py --selftest
    """
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    iot = os.path.join(LUA_DIR, "iot", "iot.lua")
    poll = os.path.join(LUA_DIR, "bus", "poll.lua")
    # 规则 -> (目标文件, [(注入前, 注入后)], 输出里必须出现的关键词)
    cases = {
        "scope_reads": (iot, [
            # 事故: recv_push 的 `local r, err = pullcfg.parse_snap(...)` 被碰掉，
            # 函数体留着 `if not r then` -> r/err 变全局恒 nil，推送永远解析失败
            ("    local r, err = pullcfg.parse_snap(t, t.configSnapshot)\n", ""),
        ], "r"),
        "m_fields": (iot, [
            # 事故: handle_downlink 降级成 local function 后漏改调用点，
            # pcall(M.handle_downlink) 传 nil -> 所有 MQTT 下行都不再被处理
            ("pcall(handle_downlink, rp.topic, rp.payload)",
             "pcall(M.handle_downlink, rp.topic, rp.payload)"),
        ], "handle_downlink"),
        "dup_bodies": (poll, [
            # 事故: probe_raw / tx_raw 各写一整套 uart 准备 + DE 时序 + 收发窗口
            ("__git__", ""),
        ], "probe_raw"),
    }

    fails = []
    for rule, (path, samples, keyword) in cases.items():
        with open(path, "r", encoding="utf-8", newline="") as fh:
            orig = fh.read()
        buf = orig
        for old_s, new_s in samples:
            buf = subprocess.run(["git", "show", "a55100f:lua/bus/poll.lua"],
                                 capture_output=True).stdout.decode("utf-8") \
                if old_s == "__git__" else _inject(buf, old_s, new_s)
            if buf is None:
                fails.append(f"{rule} 样本没拼上(注入失效, 源码可能已变)")
                break
        if buf is None:
            print(f"[{rule}] 跳过")
            continue
        _restore(path, buf)
        rc, sout = _run_check(env)
        hit = [ln for ln in sout.splitlines()
               if "不可见" in ln or "字段" in ln or "重复" in ln]
        print(f"[{rule}] exit={rc}")
        for ln in hit:
            print("   " + ln.strip())
        _restore(path, orig)
        rc2, sout2 = _run_check(env)
        if rc2 != 0:
            print(f"[还原] {os.path.basename(path)} 还原后 check_lua 不通过:\n{sout2}")
            sys.exit(1)
        print(f"[还原] {os.path.basename(path)} 通过")
        if rc == 0 or not any(keyword in ln for ln in hit):
            fails.append(f"{rule} 对注入的 bug 未报错")
        else:
            print("   抓到")

    if fails:
        print("\n失败: " + "; ".join(fails))
        sys.exit(1)
    print("\nselftest 全部通过：注入的历史事故都被对应规则抓到")


def _run_check(env):
    p = subprocess.run([sys.executable, __file__], cwd=os.path.dirname(os.path.abspath(__file__)),
                       capture_output=True, env=env)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return
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
        check_scope_reads(code, rel, all_errors)
        check_m_fields(code, rel, all_errors)
        check_dup_bodies(code, rel, all_errors)
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
    print("全部通过：括号配平 / 无前向引用 / 无裸调用未定义 / 无作用域外读 / 无 M.字段缺失 / 无函数体重复 / require 路径存在 / 无危险 format / 无 tonumber(nil)")


if __name__ == "__main__":
    main()
