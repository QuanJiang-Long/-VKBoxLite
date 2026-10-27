@echo off
rem ============================================================
rem  Run device Lua unit tests (tests/lua/*.lua)
rem
rem  Prefers the LuatOS PC simulator bundled with Luatools
rem  (Lua 5.3 core, same dialect as the device firmware; mbus uses
rem  5.3 bitops so local Lua 5.1 cannot run those modules).
rem  Falls back to lua on PATH for plain-logic tests.
rem
rem  Usage (repo root):  tools\run_lua_tests.bat [test_xxx.lua ...]
rem    no args = run all
rem ============================================================
setlocal enabledelayedexpansion
cd /d %~dp0..

set "LUATOS_PC="
if exist "D:\Luatools\resource\LuatOS_PC" (
    for /d %%B in ("D:\Luatools\resource\LuatOS_PC\LuatOS-SoC_*_PC") do set "LUATOS_PC=%%B"
)

if not defined LUATOS_PC (
    where lua >nul 2>nul
    if errorlevel 1 (
        echo FAIL: no Luatools simulator and no lua on PATH
        exit /b 1
    )
    echo engine: none, fallback to local lua
) else (
    for /f "delims=" %%b in ("!LUATOS_PC!") do echo engine: %%~b
)

set "SCR=%TEMP%\vkbox_lua_pc_test"
set "SUMMARY_PASS=0"
set "SUMMARY_FAIL=0"
set "FAILED_ITEMS="

if "%~1"=="" (
    for %%F in (tests\lua\*.lua) do call :run_one %%~nF
) else (
    for %%F in (%*) do call :run_one %%~nF %%F
)

echo.
echo ============ RESULT: PASS=!SUMMARY_PASS!  FAIL=!SUMMARY_FAIL! ============
if !SUMMARY_FAIL! gtr 0 (
    echo failed:!FAILED_ITEMS!
    exit /b 1
)
exit /b 0


:run_one
rem %~1 = short test name (tests\lua\<name>.lua)
if defined LUATOS_PC (
    call :run_pc %~1
) else (
    call :run_lua5 %~1
)
goto :eof


:run_pc
rem Simulator needs a project dir whose main.lua is our shim
rem (tools/luatos_pc_main.lua, driven by LUA_TEST env). We pass "."
rem so the dependency-trim scanner packs the SCR root itself.
rem Mirror latest code into SCR before every run.
if not exist "%SCR%" (
    robocopy "%LUATOS_PC%" "%SCR%" /E /XD demo pclogs >nul 2>&1
    echo [setup] simulator root staged at %SCR%
)
copy /y tools\luatos_pc_main.lua "%SCR%\main.lua" >nul
robocopy lua "%SCR%\lua" /MIR /NJH /NJS /NDL /NFL >nul 2>&1
del /q "%SCR%\lua\main.lua" >nul 2>&1
robocopy tests\lua "%SCR%\tests" /MIR /NJH /NJS /NDL /NFL >nul 2>&1
set "LUA_TEST=%~1.lua"
pushd "%SCR%"
"luatos-pc.exe" .
set "RC=%ERRORLEVEL%"
popd
if "%RC%"=="0" (
    echo [PASS] %~1
    set /a SUMMARY_PASS+=1
) else (
    echo [FAIL] %~1  ^(rc=%RC%, see FAIL lines above^)
    set /a SUMMARY_FAIL+=1
    set "FAILED_ITEMS=!FAILED_ITEMS! %~1"
)
goto :eof


:run_lua5
lua "tests\lua\%~1.lua" >nul 2>&1
if errorlevel 1 (
    echo [FAIL] %~1  ^(local lua, run directly for details^)
    set /a SUMMARY_FAIL+=1
    set "FAILED_ITEMS=!FAILED_ITEMS! %~1"
) else (
    echo [PASS] %~1
    set /a SUMMARY_PASS+=1
)
goto :eof
