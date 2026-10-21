@echo off
REM ============================================================
REM  prep_burn.bat - generate the "slim" script set for burning
REM  (This file is intentionally pure ASCII: cmd.exe on a Chinese
REM   Windows reads .bat as GBK, and UTF-8 Chinese in here turns
REM   into garbage that breaks the command lines.)
REM
REM  Usage:
REM   1) double-click this file (or run it from cmd)
REM   2) burn the scripts from  build\lua_burn\   (NOT lua\)
REM  See lua\README.md for details.
REM ============================================================
cd /d "%~dp0.."
powershell -ExecutionPolicy Bypass -File "tools\prep_burn.ps1"
echo.
echo If "FREE" above is positive, burn the scripts in build\lua_burn\ with LuaTools.
echo Do NOT burn the lua\ folder directly - script area is only 256KB.
pause
