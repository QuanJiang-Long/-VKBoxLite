# prep_burn.ps1 —— 烧录前生成"瘦身版"脚本
#
# 为什么需要: 固件脚本区只有 256KB, 而仓库里的 lua/ 源码带大量中文注释,
#   实测已经顶到 257KB 烧不进去(2026-10)。注释对**设备**没有意义(运行时
#   直接丢掉), 却实打实占着脚本区的空间。
#
# 做法: 复制 lua/ → build/lua_burn/, 把**整行注释**清成空行(行尾注释保留,
#   避免误伤字符串里的 "--"), **行号完全不变** —— 设备 log 里的行号仍然
#   能对上仓库源码。仓库本身一个字都不改, 注释全留着。
#
# 用法:
#   1) 在仓库根跑:  powershell -ExecutionPolicy Bypass -File tools\prep_burn.ps1
#   2) LuaTools 烧录时, 脚本目录选 build\lua_burn\ (不是 lua\)
#
# 安全性: 只清"整行都是 -- 开头"的行; `--[[ ... ]]` 块注释整块清空(保留
#   块后同一行的代码); 行尾注释一律不动。行号与源文件完全一致。

param(
    [string]$Src = (Join-Path $PSScriptRoot '..\lua'),
    [string]$Dst = (Join-Path $PSScriptRoot '..\build\lua_burn')
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$srcRoot = (Resolve-Path $Src).Path
if (Test-Path $Dst) { Remove-Item $Dst -Recurse -Force }
New-Item -ItemType Directory -Path $Dst -Force | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$srcTotal = 0
$dstTotal = 0
$stripped = 0

Get-ChildItem $Src -Recurse -Filter *.lua | ForEach-Object {
    $rel = $_.FullName.Substring($srcRoot.Length).TrimStart('\')
    $outFile = Join-Path $Dst $rel
    New-Item -ItemType Directory -Path (Split-Path $outFile) -Force | Out-Null

    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }

    $lines = $text -split "`r?`n"
    $out = New-Object string[] $lines.Length
    $inBlock = $false
    $blockClose = ''
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]
        $t = $l.Trim()
        if ($inBlock) {
            # 块注释内部: 整行清空; 若本行带块结束符, 结束后面的代码留下
            $ci = $t.IndexOf($blockClose)
            if ($ci -ge 0) {
                $after = $t.Substring($ci + $blockClose.Length)
                $out[$i] = if ($after.Trim() -ne '') { $after } else { '' }
                $inBlock = $false
            } else {
                $out[$i] = ''
            }
            continue
        }
        # 块注释开始: --[[ 或 --[==[ (开始行本身通常没有结束符)
        if ($t -match '^\s*--\[(=*)\[') {
            $blockClose = ']' + $Matches[1] + ']'
            $ci = $t.IndexOf($blockClose)
            if ($ci -ge 0) {
                $after = $t.Substring($ci + $blockClose.Length)
                $out[$i] = if ($after.Trim() -ne '') { $after } else { '' }
                $blockClose = ''
            } else {
                $out[$i] = ''
                $inBlock = $true
            }
            $stripped++
            continue
        }
        if ($t.StartsWith('--')) { $out[$i] = ''; $stripped++; continue }
        $out[$i] = $l
    }

    $res = [string]::Join("`r`n", $out)
    [System.IO.File]::WriteAllText($outFile, $res, $(if ($hasBom) { $utf8Bom } else { $utf8NoBom }))
    $srcTotal += $_.Length
    $dstTotal += (Get-Item $outFile).Length
}

Write-Host ("source lua/   : {0,7} bytes ({1} KB)" -f $srcTotal, [math]::Round($srcTotal / 1kb, 1))
Write-Host ("slim build    : {0,7} bytes ({1} KB)   {2} comment lines removed" -f $dstTotal, [math]::Round($dstTotal / 1kb, 1), $stripped)
Write-Host ("script area   :      262144 bytes (256 KB) max")
if ($dstTotal -gt 262144) {
    Write-Host "!! slim set is STILL over the limit - cut real code" -ForegroundColor Red
    exit 1
} else {
    Write-Host ("FREE          : {0} bytes ({1} KB)" -f (262144 - $dstTotal), [math]::Round((262144 - $dstTotal) / 1kb, 1)) -ForegroundColor Green
}
Write-Host ""
Write-Host ("Burn from: {0}" -f (Resolve-Path $Dst).Path) -ForegroundColor Cyan
