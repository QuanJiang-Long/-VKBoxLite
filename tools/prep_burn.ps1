# prep_burn.ps1 —— 烧录前生成"瘦身版"脚本
#
# 为什么需要: 固件脚本区只有 256KB, 而仓库里的 lua/ 源码带大量中文注释,
#   实测顶到 257KB 就烧不进去(2026-10 撞过一次, 11-12 又撞一次 —— 这次工具的
#   "257kb" 是它的取整口径, raw 只有 245.8KB, 见下面 ①)。注释对**设备**没有
#   意义(运行时直接丢掉), 却实打实占着脚本区的空间。
#
# 做法: 复制 lua/ → build/lua_burn/, 把**整行注释**清成空行(行尾注释保留,
#   避免误伤字符串里的 "--"), **行号完全不变** —— 设备 log 里的行号仍然
#   能对上仓库源码。仓库本身一个字都不改, 注释全留着。
#
# 2026-11-12 两条新增(都是被"烧不进去"逼出来的):
#   ① 脚本区余量【不能按 raw 字节算】。LuaTools 是"每个文件向上取整到 1KB, 再加
#     1 个块"来计数的 —— 本目录 21 个文件的取整浪费就有 ~10KB。上一版 stamp 报的
#     "余量 10475 字节"就是这么骗人的: raw 251669 < 262144, 工具却报
#     "文件总数据量(257kb)超过了固件脚本区空间(256kb)"。模型拿两版快照对号过:
#     0eb18da → 249.0K+1K=250K(烧得进) / 460e96c → 256.0K+1K=257K(烧不进)。
#     所以现在同时打 raw 和"工具口径", 判不判超用后者。
#   ② 顺手清掉**行首缩进**: 缩进对设备同样没有意义(运行时直接丢), 而它占 44.7KB,
#     正好是取整浪费的好几倍 —— 清完之后工具口径 257K → 215K, 真余量回到 ~41KB。
#     只动每行行首的空白, 换行一个不删, 所以**行号还是不变的**。前提已经核过:
#     全仓 0 处长字符串([[ ]]), 唯一带缩进语义的那种写法不存在, 不会改坏任何字符串。
#
# 用法:
#   1) 在仓库根跑:  powershell -ExecutionPolicy Bypass -File tools\prep_burn.ps1
#   2) LuaTools 烧录时, 脚本目录选 build\lua_burn\ (不是 lua\)
#
# 安全性: 清"整行都是 -- 开头"的行(留成空行), `--[[ ... ]]` 块注释整块清空(保留
#   块后同一行的代码), 行尾注释一律不动, 每行再剥掉行首空白。换行一个不删,
#   所以行号与源文件完全一致。长字符串([[ 或 [=[ )里的缩进是数据, 检测到就
#   整个文件保留缩进不动并报警 —— 那种写法目前没有, 但也不能悄悄改坏它。

param(
    [string]$Src = (Join-Path $PSScriptRoot '..\firmware'),
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
$alignTotal = 0
$stripped = 0

Get-ChildItem $Src -Recurse -Filter *.lua | ForEach-Object {
    $rel = $_.FullName.Substring($srcRoot.Length).TrimStart('\')
    $outFile = Join-Path $Dst $rel
    New-Item -ItemType Directory -Path (Split-Path $outFile) -Force | Out-Null

    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }

    # 长字符串([[ / [=[ )里的行首缩进是【数据】, 剥了会改坏运行期的值。仓库目前没有
    # 这种写法, 但以后谁加了就得自动保留这个文件的缩进并吼一声, 而不是悄悄改坏。
    # 块注释的 --[[ 不算(它左边两个字符是 --) —— 这两种写法长得一样, 不区分就会
    # 把"带块注释的文件"整个当成有长字符串, 缩进一刀都剥不动。
    $longStr = $false
    foreach ($mm in [regex]::Matches($text, '\[=*\[')) {
        if ($mm.Index -lt 2 -or $text.Substring($mm.Index - 2, 2) -ne '--') { $longStr = $true; break }
    }
    if ($longStr) {
        Write-Host ("  !! {0}: 有长字符串, 这个文件保留缩进(多占脚本区)" -f $rel) -ForegroundColor Yellow
    }

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

    # 行首缩进对设备同样没有意义(运行时直接丢), 而它占 44.7KB —— 见文件头 ②。
    # 只动每行行首, 换行一个不删, 所以行号还是和源码对得上。
    if (-not $longStr) {
        for ($i = 0; $i -lt $out.Length; $i++) { $out[$i] = $out[$i] -replace '^[ \t]+', '' }
    }

    $res = [string]::Join("`r`n", $out)
    [System.IO.File]::WriteAllText($outFile, $res, $(if ($hasBom) { $utf8Bom } else { $utf8NoBom }))
    $dstLen = (Get-Item $outFile).Length
    $srcTotal += $_.Length
    $dstTotal += $dstLen
    # LuaTools 数的是【每个文件向上取整到 1KB】, 不是 raw 相加(见文件头 ①):
    # 上一版按 raw 报"余量 10475 字节", 工具却报 257kb 烧不进去 —— 取整浪费 10KB。
    $alignTotal += [math]::Ceiling($dstLen / 1kb) * 1kb
}
# 那 1 个块是工具自己多算的(两版快照都对号: 249K+1K 过 / 256K+1K 挂)
$toolTotal = $alignTotal + 1kb

Write-Host ("source firmware/: {0,7} bytes ({1} KB)" -f $srcTotal, [math]::Round($srcTotal / 1kb, 1))
Write-Host ("slim build    : {0,7} bytes ({1} KB)   {2} comment lines removed" -f $dstTotal, [math]::Round($dstTotal / 1kb, 1), $stripped)
Write-Host ("LuaTools 口径 : {0,7} bytes ({1} KB) = 每文件取整到 1K + 1K" -f $toolTotal, [math]::Round($toolTotal / 1kb, 1))
Write-Host ("script area   :      262144 bytes (256 KB) max")
if ($toolTotal -gt 262144) {
    Write-Host "!! slim set is STILL over the limit - cut real code" -ForegroundColor Red
    exit 1
} else {
    Write-Host ("FREE          : {0} bytes ({1} KB)  [按工具口径]" -f (262144 - $toolTotal),
        [math]::Round((262144 - $toolTotal) / 1kb, 1)) -ForegroundColor Green
}
Write-Host ""
Write-Host ("Burn from: {0}" -f (Resolve-Path $Dst).Path) -ForegroundColor Cyan

# ---- 新鲜度戳 (2026-10): build\lua_burn\ 是【快照】, 改了源码不重跑就烧的是旧版。
#   烧错过一次(烧了修 OOM 之前的版本, 设备照样崩), 所以在 build/ 下留一份戳:
#   记录【本次生成时的 git HEAD + 源码大小 + 生成时间】。烧之前对着戳确认一下。
$stamp = Join-Path (Split-Path $Dst -Parent) 'lua_burn.stamp.txt'
$head = 'n/a'
try { $head = (git rev-parse --short HEAD 2>$null) } catch { }
$srcBytes = (Get-ChildItem $Src -Recurse -Filter *.lua | Measure-Object -Property Length -Sum).Sum
@(
  "生成时间 : " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  "git HEAD : $head"
  "源码大小 : $srcBytes 字节"
  "瘦身版   : $dstTotal 字节 (raw 相加, 【不是】工具的计数)"
  "工具口径 : $toolTotal 字节 / 上限 262144 —— 余量 " + (262144 - $toolTotal) +
      " 字节 (每文件取整到 1K + 1K, 判超只看这一行)"
  "烧之前请确认这行 HEAD 与你期望的一致 —— 快照不重跑就是旧版!"
) | Set-Content -Path $stamp -Encoding UTF8
Write-Host ("stamp    : {0}" -f $stamp) -ForegroundColor Cyan
Write-Host ("HEAD     : {0}   (烧之前拿这个对一下)" -f $head) -ForegroundColor Cyan
