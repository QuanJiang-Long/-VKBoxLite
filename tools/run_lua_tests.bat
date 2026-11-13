@echo off
rem ============================================================
rem  Run device Lua unit tests (tests/lua/*.lua)
rem
rem  V1-3 fix (2026-11-06): Use plain Lua 5.1 first (stable/fast),
rem  only use simulator for LuatOS-specific features (e.g. mbus bitops).
rem
rem  2026-11-13: no longer swallow errors (used to be >nul 2>&1, a FAIL
rem  told you nothing), and tests the plain engine cannot run are
rem  counted as SKIP instead of FAIL:
rem    - mbus.lua uses Lua 5.3 bit ops (// ~), plain 5.1 syntax error
rem    - iot/cmd/sn modules require LuatOS libs (sys/uart/fskv)
rem    - test_heapsize 320KB red line is calibrated on the LuatOS
rem      engine; plain 5.1 compiled chunks are heavier -> false alarm
rem  To run those fully, install the LuatOS PC engine (luatos-pc.exe).
rem
rem  Usage (repo root):  tools\run_lua_tests.bat [test_xxx.lua ...]
rem    no args = run all
rem  NOTE: keep this file ASCII-only, cmd.exe mangles UTF-8 Chinese.
rem ============================================================
setlocal enabledelayedexpansion
cd /d %~dp0..

rem Find available Lua interpreter
set "LUA_CMD="
where lua >nul 2>nul
if not errorlevel 1 (
    set "LUA_CMD=lua"
) else if exist "C:\Program Files (x86)\Lua\5.1\lua.exe" (
    set "LUA_CMD=C:\Program Files (x86)\Lua\5.1\lua.exe"
) else if exist "C:\Users\Administrator\AppData\Local\Programs\Lua\bin\lua.exe" (
    set "LUA_CMD=C:\Users\Administrator\AppData\Local\Programs\Lua\bin\lua.exe"
)

if not defined LUA_CMD (
    echo FAIL: no lua on PATH or in standard locations
    exit /b 1
)

echo engine: %LUA_CMD%

set "SUMMARY_PASS=0"
set "SUMMARY_FAIL=0"
set "SUMMARY_SKIP=0"
set "FAILED_ITEMS="
set "SKIPPED_ITEMS="

if "%~1"=="" (
    for %%F in (tests\lua\*.lua) do call :run_one %%~nF
) else (
    for %%F in (%*) do call :run_one %%~nF %%F
)

echo.
echo ============ RESULT: PASS=!SUMMARY_PASS!  FAIL=!SUMMARY_FAIL!  SKIP=!SUMMARY_SKIP! ============
if defined SKIPPED_ITEMS echo skipped_need_luatos_engine:!SKIPPED_ITEMS!
if !SUMMARY_FAIL! gtr 0 (
    echo failed:!FAILED_ITEMS!
    exit /b 1
)
exit /b 0


:run_one
rem %~1 = short test name (tests\lua\<name>.lua)
set "ERRF=!TEMP!\vkbox_lua_err.txt"
set "OUTF=!TEMP!\vkbox_lua_out.txt"
rem Run with plain Lua, set package.path so require can find firmware modules
rem stdout/stderr go to temp files, shown again on FAIL - errors not swallowed
"%LUA_CMD%" -e "package.path='firmware/?.lua;firmware/?/init.lua;'..package.path; dofile('tests/lua/%~1.lua')" >"!OUTF!" 2>"!ERRF!"
if not errorlevel 1 (
    echo [PASS] %~1
    set /a SUMMARY_PASS+=1
    goto :eof
)

rem ---- classify: engine capability issue = SKIP, otherwise real FAIL ----
rem 1) LuatOS lib missing (util.lua get check: sys/uart/fskv/...)
findstr /c:"library not available" "!ERRF!" "!OUTF!" >nul 2>nul
if not errorlevel 1 (
    echo [SKIP] %~1  -- need LuatOS engine: plain Lua 5.1 has no sys/uart/fskv libs
    set /a SUMMARY_SKIP+=1
    set "SKIPPED_ITEMS=!SKIPPED_ITEMS! %~1"
    goto :eof
)
rem 2) Lua 5.3 bit-op syntax in mbus.lua (// and ~)
findstr /c:"unexpected symbol near '/'" "!ERRF!" "!OUTF!" >nul 2>nul
if not errorlevel 1 (
    echo [SKIP] %~1  -- need Lua 5.3+/LuatOS: mbus.lua uses 5.3 bit ops
    set /a SUMMARY_SKIP+=1
    set "SKIPPED_ITEMS=!SKIPPED_ITEMS! %~1"
    goto :eof
)
rem 3) red line calibrated on the LuatOS engine (plain 5.1 false-alarms)
if /i "%~1"=="test_heapsize" (
    echo [SKIP] %~1  -- red line calibrated on LuatOS engine, plain 5.1 measures heavier
    set /a SUMMARY_SKIP+=1
    set "SKIPPED_ITEMS=!SKIPPED_ITEMS! %~1"
    goto :eof
)

rem ---- real FAIL: show first stderr line + FAIL lines from stdout ----
echo [FAIL] %~1
set /a SUMMARY_FAIL+=1
set "FAILED_ITEMS=!FAILED_ITEMS! %~1"
set "ERR_SHOWN=0"
for /f "usebackq delims=" %%L in ("!ERRF!") do (
    if "!ERR_SHOWN!"=="0" (
        echo         err: %%L
        set "ERR_SHOWN=1"
    )
)
for /f "usebackq delims=" %%L in (`findstr /c:"FAIL" "!OUTF!" 2^>nul`) do (
    echo         out: %%L
    goto :eof
)
goto :eof
