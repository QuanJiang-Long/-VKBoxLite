@echo off
rem ============================================================
rem  VKBox Lite Config Tool launcher
rem  Air780EP 485 collector PC config software
rem  (ASCII only on purpose: avoids codepage mojibake in bat)
rem ============================================================
setlocal

cd /d "%~dp0" || exit /b 1

set "ELECTRON=%~dp0node_modules\electron\dist\electron.exe"
set "APP=%~dp0"

if not exist "%ELECTRON%" goto no_electron
if not exist "%~dp0main.js" goto no_main

echo Starting VKBox Config Tool ...
echo   device port: COM32 (LuatOS VUART_0), 115200 8N1
echo.

start "" "%ELECTRON%" "%APP%"

endlocal
exit /b 0

:no_electron
echo [ERROR] electron not found: %ELECTRON%
echo.
echo node_modules here is a junction to VKBoxLite_poll\frontend\node_modules
echo and it is now broken. Fix with either:
echo.
echo   A) recreate the junction:
echo      rmdir "%~dp0node_modules"
echo      mklink /J "%~dp0node_modules" "D:\VKBox_Lite\VKBoxLite_poll\frontend\node_modules"
echo.
echo   B) install standalone deps:
echo      rmdir "%~dp0node_modules"
echo      cd /d "%~dp0" && npm install
echo.
pause
exit /b 1

:no_main
echo [ERROR] main.js not found. Run this from the frontend directory.
pause
exit /b 1
