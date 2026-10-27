@echo off
rem ============================================================
rem  VKBoxLite 上位机一键打包
rem  产物: dist\VKBoxLite Setup <ver>.exe   (NSIS 安装器)
rem        dist\VKBoxLite <ver>.exe         (Portable 单文件)
rem  图标: build\icon.ico (缺省则用 Electron 默认图标)
rem ============================================================
cd /d %~dp0

echo === 依赖检查 ===
if not exist node_modules\electron-builder (
  echo 首次打包, 安装依赖中 ...
  call npm install
  if errorlevel 1 goto :fail
)
if not exist node_modules\electron\dist\electron.exe (
  echo electron 二进制未就位, 重装依赖中 ...
  call npm install
  if errorlevel 1 goto :fail
)

echo === [1/2] NSIS 安装包 ===
call npm run dist
if errorlevel 1 goto :fail

echo === [2/2] Portable 单文件 ===
call npm run dist:portable
if errorlevel 1 goto :fail

echo === 产物清单 ===
dir /b dist\*.exe
echo 完成. exe 未签名, 客户首装会有 SmartScreen 提示, 属正常.
exit /b 0

:fail
echo 打包失败, 见上方日志.
exit /b 1
