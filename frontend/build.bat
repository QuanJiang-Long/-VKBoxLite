@echo off
rem ============================================================
rem  VKBoxLite host app one-shot packaging
rem  Outputs: dist\VKBoxLite Setup <ver>.exe   (NSIS installer)
rem           dist\VKBoxLite <ver>.exe         (Portable single file)
rem  Icon: build\icon.ico (falls back to Electron default if missing)
rem  NOTE: keep this file pure ASCII. Chinese comments here get
rem        chopped by GBK codepage consoles and corrupt the batch.
rem ============================================================
cd /d %~dp0

echo === deps check ===
if not exist node_modules\electron-builder (
  echo installing deps ...
  call npm install
  if errorlevel 1 goto :fail
)
if not exist node_modules\electron\dist\electron.exe (
  echo electron binary missing, reinstalling deps ...
  call npm install
  if errorlevel 1 goto :fail
)

echo === [1/2] NSIS installer ===
call npm run dist
if errorlevel 1 goto :fail

echo === [2/2] Portable single file ===
call npm run dist:portable
if errorlevel 1 goto :fail

echo === artifacts ===
dir /b dist\*.exe
echo done. unsigned exe, SmartScreen prompt on first install is normal.
exit /b 0

:fail
echo packaging failed, see log above.
exit /b 1
