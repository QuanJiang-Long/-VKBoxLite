# 语法校验是假阳性 —— 烧录才炸 (2026-10-27)

## 事故

12-fix 提交后烧录，LuaTools 报：

```
合并失败: 有语法错误
poll.lua:505: 'end' expected (to close 'function' at line 478) near 'return'
```

而**提交前的验证全绿**：luac "19/19 通过"、check_lua.py 只剩 7 条已知误报、
dep_graph.py 无新循环、单元测试 PASS=3。

## 真错：重复的 return

改 `M.stop()` 时，我的 `old_string` 截到 `log.info("poll", "stopped")` 就停了，
**漏掉了原来的 `return true`（原文件 478 行）**；`new_string` 自己又写了一条
`return true`。结果：

```lua
478 function M.stop()
...
503     if was_running then log.info("poll", "stopped") end
504     return true
505     return true      ← 原来那条留下的
506 end
```

**Lua 的规则：`return` 必须是块的最后一条语句。** 第一条 `return` 终结了函数体，
第二条落到文件作用域 → `'end' expected (to close 'function' at line 478)`。

（这类错**不会**被 `check_lua.py` 抓到 —— 它查的是 `M.xxx` 字段访问，不是块结构。）

## 根因：我的校验脚本一直是假阳性

之前一直用：

```powershell
cmd /c "`"$luac`" -p `"$f`" 2>&1 & echo E=%ERRORLEVEL!"
```

**`%ERRORLEVEL%` 是 cmd 在【解析整行】时展开的**，拿到的是**上一条命令**的退出码，
不是 luac 的真实退出码。结果恒为 0 —— **语法错误 100% 漏过去**。

所以前几轮我报的"luac 19/19 通过"全是假的。这次是第二次栽在同一个坑里
（第一次是 `2>&1` 让 `$LASTEXITCODE` 变空）。

## 为什么不用本机 luac 直接改对

本机 `luac.exe` 是 **Lua 5.1**（`C:\Program Files (x86)\Lua\5.1\luac.exe`），
固件跑的是 **Lua 5.3**。5.1 解析不了 5.3 的 `//` `~` `<<` `>>`，
而 `lua/bus/mbus.lua` 的 CRC 表正好用了：

```lua
crc = (crc // 2) ~ poly
```

→ 5.1 的 luac 对 mbus.lua **必然误报**。这就是当初为什么改用 `cmd /c` 那套写法
（结果把真错也盖住了）。

**结论：语法校验必须用固件同款 5.3 内核。**

## 新工具：tools/check_syntax.ps1

用 Luatools 自带的 **LuatOS PC 模拟器**（就是固件同款 5.3 内核），
`loadfile()` **只编译不执行**，逐个文件过一遍。

踩过的坑：

1. **模拟器的"依赖裁剪"扫描器只认 main.lua 里的字面量**。文件清单放环境变量里
   它看不见 → 文件被裁掉 → 只检了 8/19 个。**必须把清单写成 main.lua 里的
   字面量表**。
2. **`lua/main.lua` 和生成的 main.lua 重名** → 模拟器报"依赖裁剪模式下不允许
   重名文件 main.lua"。把它 stage 成 `lua/_entry.lua`（loadfile 只看字节）。
3. **`.bat` 文件不能有中文**：cmd.exe 按 OEM 码页读 `.bat`，UTF-8 中文注释会变成
   乱码命令行（`'——' is not recognized as an internal or external command`）。
   改成纯英文注释。
4. **`.ps1` 必须带 UTF-8 BOM**：Windows PowerShell 5.1 没 BOM 就按 ANSI 读，
   中文注释乱码会把语法搞坏（`prep_burn.ps1` 一直带 BOM，照着做）。
5. **沙箱里 `cmd` 的 stdout 管道捕获被禁**（EPERM），`cmd /c "echo hi"` 也是 0 行；
   直接 `& luac.exe` 则是 "Access is denied"。要么用 `cmd /c` 包一层，要么申请
   更宽的沙箱模式。

### 自检是必须的

校验器如果**永远不会失败**，那比没有校验器更危险 —— 它给人虚假的安全感。
所以 `check_syntax.ps1` 每次跑完都会**故意注入一个写坏的文件**
（就是本次事故的重复 `return`），确认自己**能**判 FAIL，才返回 0。

## 新增/修改

| 文件 | 说明 |
|---|---|
| `tools/check_syntax.ps1` | Lua 5.3 权威语法校验 + 自检。`-Root lua` / `-Root build\lua_burn` |
| `lua/bus/poll.lua` | 删掉重复的 `return true`（本次真错） |

## 以后怎么验

```powershell
powershell -ExecutionPolicy Bypass -File tools\check_syntax.ps1 -Root lua
powershell -ExecutionPolicy Bypass -File tools\check_syntax.ps1 -Root build\lua_burn
```

**烧录前必须跑第二条**（烧的是 `build\lua_burn\`，不是 `lua\`）。

⚠️ 拿到退出码的规矩：**直接调 exe 用 `$LASTEXITCODE`**；
必须走 `cmd /c` 时用 `cmd /v:on /c "... & echo !ERRORLEVEL!"`（**延迟展开**，
执行期取值），**绝不能用 `%ERRORLEVEL%`**（解析期展开，拿到的是上一条命令的值）。
