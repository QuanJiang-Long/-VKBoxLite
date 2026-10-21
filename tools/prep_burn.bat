@echo off
REM 一键生成"烧录瘦身版"脚本: 双击即可
REM 原理与用法见 tools\prep_burn.ps1 顶部注释
cd /d "%~dp0.."
powershell -ExecutionPolicy Bypass -File "tools\prep_burn.ps1"
echo.
echo 上面若显示"余量"为正, 就可以用 LuaTools 烧录 build\lua_burn\ 里的脚本。
echo (不要直接烧 lua\ 目录 —— 脚本区只有 256KB, 原始源码带注释会超限)
pause
