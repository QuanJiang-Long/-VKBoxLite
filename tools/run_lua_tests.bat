@echo off
rem ============================================================
rem  Run device Lua unit tests (tests/lua/*.lua)
rem
rem  Engines, best effort:
rem    1. plain Lua 5.1 - fast, always tried first.
rem    2. LuatOS PC simulator .simulator\LuatOS_PC\ (Lua 5.3 core,
rem       same dialect as the device firmware). Used automatically
rem       when the plain engine cannot run the test: LuatOS libs
rem       (sys/uart/fskv), mbus 5.3 bitops (// ~), or memory
rem       budgets that need the device's 32-bit Lua.
rem
rem  Bitness matters (2026-11-13 finding):
rem    - 64-bit Lua tables/values carry ~2x header overhead, so the
rem      per-object memory budgets (test_churn / test_infer_acc /
rem      test_infer_mem, they guard the 32-bit device heap) must run
rem      on the 32-bit engine.
rem    - the 32-bit engine is fine for those; everything else runs
rem      on the 64-bit engine.
rem
rem  Install the simulator (once):
rem    https://cdn18.luatos.com/files/public/LuatOS_PC/LuatOS-SoC_V2039_PC.zip
rem    extract into .simulator\LuatOS_PC\  (kept out of git)
rem
rem  Staging pitfall (.agent-memory oom-crash-2026-10-28): a stale
rem  staging dir crashes the engine (observed again on 2026-11-13:
rem  test_cmd_stat crashed on a reused staging, passed on a fresh
rem  one) - so the staging %TEMP%\vkbox_lua_pc_test is rebuilt
rem  from scratch before EVERY simulator run.
rem
rem  Usage (repo root):  tools\run_lua_tests.bat [test_xxx.lua ...]
rem    no args = run all
rem  NOTE: keep this file ASCII-only, cmd.exe mangles UTF-8 Chinese.
rem ============================================================
setlocal enabledelayedexpansion
cd /d %~dp0..

rem --- engine 1: plain Lua ------------------------------------
set "LUA_CMD="
where lua >nul 2>nul
if not errorlevel 1 (
    set "LUA_CMD=lua"
) else if exist "C:\Program Files (x86)\Lua\5.1\lua.exe" (
    set "LUA_CMD=C:\Program Files (x86)\Lua\5.1\lua.exe"
) else if exist "C:\Users\Administrator\AppData\Local\Programs\Lua\bin\lua.exe" (
    set "LUA_CMD=C:\Users\Administrator\AppData\Local\Programs\Lua\bin\lua.exe"
)

rem --- engine 2: LuatOS PC simulator ---------------------------
set "SIMDIR=%~dp0..\.simulator\LuatOS_PC"
set "SIM64=%SIMDIR%\luatos-pc-64bit.exe"
set "SIM32=%SIMDIR%\luatos-pc.exe"
set "SIM_STAGE=%TEMP%\vkbox_lua_pc_test"
if not exist "!SIM64!" if not exist "!SIM32!" (
    set "SIM64="
    set "SIM32="
)

if not defined LUA_CMD if not defined SIM64 if not defined SIM32 (
    echo FAIL: no lua and no LuatOS PC simulator found
    exit /b 1
)
if defined LUA_CMD echo engine1: !LUA_CMD! ^(plain 5.1^)
if defined SIM64   echo engine2: !SIM64!
if defined SIM32   echo engine3: !SIM32! ^(32-bit, for per-object memory budgets^)

set "SUMMARY_PASS=0"
set "SUMMARY_FAIL=0"
set "SUMMARY_SKIP=0"
set "FAILED_ITEMS="
set "SKIPPED_ITEMS="
set "SIM_USED_ITEMS="

if "%~1"=="" (
    for %%F in (tests\lua\*.lua) do call :run_one %%~nF
) else (
    for %%F in (%*) do call :run_one %%~nF %%F
)

echo.
echo ============ RESULT: PASS=!SUMMARY_PASS!  FAIL=!SUMMARY_FAIL!  SKIP=!SUMMARY_SKIP! ============
if defined SIM_USED_ITEMS echo passed_via_simulator:!SIM_USED_ITEMS!
if defined SKIPPED_ITEMS  echo skipped_need_luatos_engine:!SKIPPED_ITEMS!
if !SUMMARY_FAIL! gtr 0 (
    echo failed:!FAILED_ITEMS!
    exit /b 1
)
exit /b 0


:run_one
rem %~1 = short test name (tests\lua\<name>.lua)
set "ERRF=!TEMP!\vkbox_lua_err.txt"
set "OUTF=!TEMP!\vkbox_lua_out.txt"
if not defined LUA_CMD goto :no_plain
"%LUA_CMD%" -e "package.path='firmware/?.lua;firmware/?/init.lua;'..package.path; dofile('tests/lua/%~1.lua')" >"!OUTF!" 2>"!ERRF!"
if not errorlevel 1 (
    echo [PASS] %~1
    set /a SUMMARY_PASS+=1
    goto :eof
)

:no_plain
rem ---- classify: engine capability issue -> retry on simulator ----
set "ENGINE_NEEDY=0"
if defined LUA_CMD (
    findstr /l /c:"library not available" "!ERRF!" "!OUTF!" >nul 2>nul && set "ENGINE_NEEDY=1"
    findstr /l /c:"unexpected symbol near '/'" "!ERRF!" "!OUTF!" >nul 2>nul && set "ENGINE_NEEDY=1"
)
rem heapsize red line is calibrated on Lua 5.3-class engines (plain 5.1
rem happens to agree, but if it ever drifts, retry on the simulator)
if /i "%~1"=="test_heapsize" set "ENGINE_NEEDY=1"
if "!ENGINE_NEEDY!"=="0" goto :real_fail

rem ---- engine-bound test: simulator available? ----
if defined SIM64 if not defined SIM32 goto :pick64
if defined SIM32 goto :pick_bitness
echo [SKIP] %~1  -- engine-bound test, install LuatOS PC simulator into .simulator\LuatOS_PC\
set /a SUMMARY_SKIP+=1
set "SKIPPED_ITEMS=!SKIPPED_ITEMS! %~1"
goto :eof

:pick_bitness
rem per-object memory budgets guard the 32-bit device heap: a 64-bit Lua
rem carries ~2x header overhead, its numbers do not transfer. These three
rem must run on the 32-bit engine (2026-11-13: 64-bit false-alarms them).
set "USE32=0"
for %%T in (test_churn test_infer_acc test_infer_mem) do if /i "%~1"=="%%T" set "USE32=1"
if "!USE32!"=="1" (
    if defined SIM32 goto :run_sim32
    if defined SIM64 goto :run_sim64
) else (
    if defined SIM64 goto :run_sim64
    if defined SIM32 goto :run_sim32
)
goto :skip_no_engine

:pick64
set "USE32=0"
goto :run_sim64

:skip_no_engine
echo [SKIP] %~1  -- engine-bound test, install LuatOS PC simulator into .simulator\LuatOS_PC\
set /a SUMMARY_SKIP+=1
set "SKIPPED_ITEMS=!SKIPPED_ITEMS! %~1"
goto :eof

:run_sim64
set "RUNEXE=!SIM64!"
goto :sim_common

:run_sim32
set "RUNEXE=!SIM32!"
goto :sim_common

:sim_common
set "SIMF=!TEMP!\vkbox_lua_sim_out.txt"
call :stage_sim
set "LUA_TEST=%~1.lua"
pushd "!SIM_STAGE!"
"!RUNEXE!" . >"!SIMF!" 2>&1
popd
rem verdict from output, not exit code: the main.lua shim always exits 0.
rem line-anchored FAIL (tests print "FAIL: ..."/"[FAIL] ..."), or a crash dump.
findstr /r /c:"^FAIL" /c:"^\[FAIL" "!SIMF!" >nul 2>nul
if not errorlevel 1 goto :sim_fail
findstr /l /c:"Minidump" /c:"CrashDump" "!SIMF!" >nul 2>nul
if not errorlevel 1 goto :sim_fail
echo [PASS] %~1  -- via LuatOS PC simulator
set /a SUMMARY_PASS+=1
set "SIM_USED_ITEMS=!SIM_USED_ITEMS! %~1"
goto :eof

:sim_fail
echo [FAIL] %~1  -- via LuatOS PC simulator
set /a SUMMARY_FAIL+=1
set "FAILED_ITEMS=!FAILED_ITEMS! %~1"
for /f "usebackq delims=" %%L in (`findstr /r /c:"^FAIL" /c:"^\[FAIL" "!SIMF!"`) do (
    echo         sim: %%L
    goto :eof
)
for /f "usebackq delims=" %%L in (`findstr /l /c:"Minidump" /c:"CrashDump" "!SIMF!"`) do (
    echo         sim: %%L
    goto :eof
)
goto :eof

:stage_sim
rem rebuild staging from scratch every simulator run (stale staging crashes)
if exist "!SIM_STAGE!" rd /s /q "!SIM_STAGE!"
md "!SIM_STAGE!"
if exist "!SIM64!"  copy /y "!SIM64!"  "!SIM_STAGE!" >nul
if exist "!SIM32!" (
    copy /y "!SIM32!" "!SIM_STAGE!" >nul
    if exist "!SIMDIR!\luat_uart_i686.dll" copy /y "!SIMDIR!\luat_uart_i686.dll" "!SIM_STAGE!" >nul
)
copy /y "%~dp0luatos_pc_main.lua" "!SIM_STAGE!\main.lua" >nul
robocopy firmware "!SIM_STAGE!\lua" /MIR /NJH /NJS /NDL /NFL /NP >nul
if exist "!SIM_STAGE!\lua\main.lua" del /q "!SIM_STAGE!\lua\main.lua"
robocopy tests\lua "!SIM_STAGE!\tests" /MIR /NJH /NJS /NDL /NFL /NP >nul
if exist build\lua_burn robocopy build\lua_burn "!SIM_STAGE!\build\lua_burn" /MIR /NJH /NJS /NDL /NFL /NP >nul
goto :eof

:real_fail
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
