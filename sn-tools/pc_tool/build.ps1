# PyInstaller build: produces dist\SnBurner.exe (no Python needed on target PC)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File build.ps1
#
# Icon: repo-root Lcon.png is converted to app.ico by _make_icon.py,
#       then passed to PyInstaller --icon (PyInstaller only accepts .ico).
#
# Self-tests run first; any failure aborts so a bad exe never ships.
#
# Product notes:
#   dist\SnBurner.exe    single file, double-click to run, no Python needed
#   First run creates config.json and data\ next to the exe
#   (path base: config.py app_dir(), not cwd, so it will not write into _MEI)

$ErrorActionPreference = "Stop"

# Directory of this script (build.ps1 lives in pc_tool\)
$thisDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($thisDir)) {
    $thisDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
}
Set-Location -Path $thisDir

# Icon source (PNG at repo root) and converted artifact (.ico in this dir)
$repoRoot = Split-Path -Path $thisDir -Parent
$IconPng = Join-Path $repoRoot "Lcon.png"
$IconIco = Join-Path $thisDir "app.ico"

Write-Host "=== [1/6] Clean old artifacts ==="
Remove-Item -Recurse -Force build, dist -ErrorAction SilentlyContinue
Remove-Item -Force SnBurner.spec, app.ico -ErrorAction SilentlyContinue

Write-Host "=== [2/6] Check PyInstaller ==="
python -c "import PyInstaller; print('  PyInstaller', PyInstaller.__version__)"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  not installed, installing (about 1-3 minutes)..."
    python -m pip install pyinstaller
    if ($LASTEXITCODE -ne 0) {
        Write-Error "PyInstaller install failed. Run manually: python -m pip install pyinstaller"
        exit 1
    }
}

Write-Host "=== [3/6] Build exe icon ==="
if (Test-Path -LiteralPath $IconPng) {
    python _make_icon.py
    if ($LASTEXITCODE -ne 0) { Write-Error "Icon conversion failed"; exit 1 }
    # Embedded copy for the WINDOW icon (title bar / taskbar).
    # --icon only covers the Explorer file icon; the running window's icon
    # is tkinter's job. Embedded as base64 rather than --add-data so that
    # startup does not depend on %TEMP% being writable.
    python _make_icon_data.py
    if ($LASTEXITCODE -ne 0) { Write-Error "Embedded icon data generation failed"; exit 1 }
    # Same for the popup icons (qrcode / bug / lock-password). They used to
    # be loaded from a hardcoded absolute path, which broke as soon as the
    # repo moved; now they are embedded, so the path no longer matters.
    python _make_dialog_icon_data.py
    if ($LASTEXITCODE -ne 0) { Write-Error "Embedded popup icon data generation failed"; exit 1 }
} else {
    Write-Host "  $IconPng not found, skipping icon (exe keeps default icon)"
}

Write-Host "=== [4/6] Self-tests (must all pass before packaging) ==="
# NOTE: do not judge exit code with "python x.py 2>&1 | Select-Object".
# Chinese output goes down the pipe as GBK while the reader decodes utf-8,
# which raises UnicodeDecodeError and PowerShell then reports exit=1
# (a false failure; the script actually passed).
# _st_all.py captures child output byte-wise, so it gets the real code.
python sn_rule.py
if ($LASTEXITCODE -ne 0) { Write-Error "SN rule self-test failed"; exit 1 }
python _st_all.py
if ($LASTEXITCODE -ne 0) { Write-Error "module self-tests not all passed, abort"; exit 1 }
python _path_check.py
if ($LASTEXITCODE -ne 0) { Write-Error "path check failed, config/ledger would be lost"; exit 1 }
python _smoke_ui2.py
if ($LASTEXITCODE -ne 0) { Write-Error "UI smoke test failed (scroll / MQTT three fields)"; exit 1 }
python _chk_ui_layout.py
if ($LASTEXITCODE -ne 0) { Write-Error "UI layout check failed (port dropdown / buttons / card order)"; exit 1 }
python _chk_port_watch.py
if ($LASTEXITCODE -ne 0) { Write-Error "port hotplug auto-refresh check failed"; exit 1 }
python _chk_lock_only.py
if ($LASTEXITCODE -ne 0) { Write-Error "manual lock-only operation check failed"; exit 1 }
python _st_mqtt.py
if ($LASTEXITCODE -ne 0) { Write-Error "W:MQTT command layer self-test failed"; exit 1 }
python _st_winicon.py
if ($LASTEXITCODE -ne 0) { Write-Error "window icon self-test failed (title bar / taskbar)"; exit 1 }
python _st_connect.py
if ($LASTEXITCODE -ne 0) { Write-Error "connect flow self-test failed (auto-detect port branch)"; exit 1 }

Write-Host "=== [5/6] Package ==="
# --onefile        single-file exe
# --windowed       no black console window (GUI program)
# --name           exe name
# --icon           exe icon; must be .ico (produced by _make_icon.py from Lcon.png)
# --hidden-import  local modules (PyInstaller sometimes misses cross-module imports)
# --exclude-module test/tool scripts, keep them out of the bundle

# Icon args: pass it only when it exists. PyInstaller does not fail when
# --icon is absent, but it does fail hard when given a nonexistent file.
$iconArgs = @()
if (Test-Path -LiteralPath $IconIco) { $iconArgs = @("--icon", $IconIco) }

# NOTE: no --add-data for the window icon, on purpose.
# --onefile extracts data files to %TEMP%\_MEIxxxxxx, which makes app
# startup depend on Temp being writable. Measured here: extraction fails
# with "Permission denied", and not only for our files - even
# VCRUNTIME140.dll fails, i.e. the whole _MEI dir is unwritable.
# Production PCs are usually fine, but that is not a bet worth taking.
# Instead the PNG is embedded as base64 in _icon_data.py (generated in
# [3/6]), so the window icon has zero filesystem dependency.

python -m PyInstaller --onefile --windowed --name SnBurner @iconArgs `
    --hidden-import serial_port `
    --hidden-import device `
    --hidden-import allocator `
    --hidden-import burner `
    --hidden-import config `
    --hidden-import sn_rule `
    --hidden-import ui_app `
    --hidden-import _barcode `
    --hidden-import _qrcode `
    --hidden-import _icon_data `
    --hidden-import _dialog_icon_data `
    --exclude-module _selftest_fixes `
    --exclude-module _make_icon `
    --exclude-module _smoke2 `
    --exclude-module _smoke3 `
    --exclude-module _smoke4 `
    --exclude-module _smoke5 `
    --exclude-module _smoke6 `
    --exclude-module _smoke_ui `
    --exclude-module _smoke_ui2 `
    --exclude-module _chk_ui_layout `
    --exclude-module _chk_port_watch `
    --exclude-module _chk_lock_only `
    --exclude-module _st_all `
    --exclude-module _path_check `
    --exclude-module _luatools_lint `
    --exclude-module _pkg_closure `
    --exclude-module _code_bytes `
    --exclude-module _size_report `
    --exclude-module _byte_verify_exe_icon `
    --exclude-module _st_mqtt `
    --exclude-module _st_winicon `
    --exclude-module _st_connect `
    --exclude-module _make_icon_data `
    --exclude-module _make_dialog_icon_data `
    --exclude-module _chk_bundle `
    main.py

if ($LASTEXITCODE -ne 0) { Write-Error "Packaging failed"; exit 1 }

Write-Host "=== [6/6] Verify artifact ==="
$exe = Join-Path $thisDir "dist\SnBurner.exe"
if (-not (Test-Path -LiteralPath $exe)) { Write-Error "not found: $exe"; exit 1 }
if (Test-Path -LiteralPath $IconIco) {
    python _byte_verify_exe_icon.py
    if ($LASTEXITCODE -ne 0) { Write-Error "embedded icon is not the expected one"; exit 1 }
}
# 终验：exe 里的图标数据 + 代码 == 当前源码。
# 防止"源码改了但忘了重打包"，也防止内嵌图标数据没进包。
python _chk_bundle.py
if ($LASTEXITCODE -ne 0) { Write-Error "bundle verification failed (exe is stale or icon data missing)"; exit 1 }

$size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
Write-Host ""
Write-Host "=== Packaging complete ==="
Write-Host "  Product: $exe  ($size MB)"
if (Test-Path -LiteralPath $IconIco) { Write-Host "  Icon: from Lcon.png (verified byte-exact)" }
Write-Host ""
Write-Host "  Copy SnBurner.exe alone to the production PC and double-click."
Write-Host "  First run creates config.json and data\ next to the exe."
Write-Host "  Do not put it under C:\Program Files\ (no write permission)."
Write-Host "  Do not delete config.json or data\: ledger and serial counters live there."
