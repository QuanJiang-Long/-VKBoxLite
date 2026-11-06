@echo off
rem ============================================================
rem  Run device Lua unit tests (tests/lua/*.lua)
rem
rem  V1-3 fix (2026-11-06): Use plain Lua 5.1 first (stable/fast),
rem  only use simulator for LuatOS-specific features (e.g. mbus bitops).
rem
rem  Usage (repo root):  tools\run_lua_tests.bat [test_xxx.lua ...]
rem    no args = run all
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
rem Run with plain Lua, set package.path so require can find firmware modules
"%LUA_CMD%" -e "package.path='firmware/?.lua;firmware/?/init.lua;'..package.path; dofile('tests/lua/%~1.lua')" >nul 2>&1
if errorlevel 1 (
    echo [FAIL] %~1
    set /a SUMMARY_FAIL+=1
    set "FAILED_ITEMS=!FAILED_ITEMS! %~1"
) else (
    echo [PASS] %~1
    set /a SUMMARY_PASS+=1
)
goto :eof
