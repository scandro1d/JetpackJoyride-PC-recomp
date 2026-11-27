# MAINTAINER TOOL - run once on the PC where the game already works, to fill this repo with your working changes:
#   patches\ps3recomp-jj.patch   (every change made inside your ps3recomp checkout, relative to the pinned commit)
#   project\*                    (CMakeLists.txt, main.cpp, stubs.cpp, config.toml, settings_menu.h)
# Usage:  .\tools\Export-FromWorkingTree.ps1 -Work C:\Users\you\Desktop\jj
param([Parameter(Mandatory)][string]$Work)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$commit = 'de4f090328ea08bef6b2f15caec0b85e343a7ece'
$ps3 = Join-Path $Work 'ps3recomp'
if (-not (Test-Path "$ps3\.git")) { throw "No ps3recomp checkout in $Work" }

# 1) diff of the whole checkout against the pinned commit, using a throw-away index so nothing in your tree is touched
$idx = Join-Path $env:TEMP 'jj_export_index'
Remove-Item $idx -ErrorAction SilentlyContinue
$env:GIT_INDEX_FILE = $idx
try {
    $out = Join-Path $repo 'patches\ps3recomp-jj.patch'
    Remove-Item $out -ErrorAction SilentlyContinue
    # core.autocrlf=input turns any Windows line endings in your tree into plain LF inside the patch, and
    # --output lets git write the file itself (piping through PowerShell would rewrite line endings and add a BOM)
    git -C $ps3 read-tree $commit
    git -C $ps3 -c core.autocrlf=input add -A
    git -C $ps3 -c core.autocrlf=input diff --cached --binary --output="$out" $commit
    git -C $ps3 diff --cached --stat $commit | Select-Object -Last 25
} finally { Remove-Item Env:GIT_INDEX_FILE; Remove-Item $idx -ErrorAction SilentlyContinue }
$bytes = [IO.File]::ReadAllBytes($out)
$cr = ($bytes | Where-Object { $_ -eq 13 }).Count
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) { throw 'patch starts with a BOM - export failed' }
if ($cr -gt 0) { Write-Host "NOTE: patch contains $cr carriage-return bytes (stray CRs in your files)." -ForegroundColor Yellow }

# 2) project files
New-Item -ItemType Directory -Force (Join-Path $repo 'project') | Out-Null
foreach ($f in 'CMakeLists.txt','main.cpp','stubs.cpp','config.toml','settings_menu.h') {
    if (-not (Test-Path (Join-Path $Work $f))) { throw "Missing $f in $Work" }
    Copy-Item (Join-Path $Work $f) (Join-Path $repo "project\$f") -Force
}

# 3) safety checks: no personal paths, no big/game-looking files
$bad = Select-String -Path (Join-Path $repo 'patches\*.patch'), (Join-Path $repo 'project\*') -Pattern 'C:\\Users\\|Desktop\\|MIKE' -ErrorAction SilentlyContinue
if ($bad) { Write-Host 'WARNING: personal paths found - review before publishing:' -ForegroundColor Yellow; $bad | Select-Object -First 10 | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" } }
$size = (Get-Item (Join-Path $repo 'patches\ps3recomp-jj.patch')).Length
Write-Host ("patch size: {0:N0} bytes" -f $size)
if ($size -gt 5MB) { Write-Host 'WARNING: patch is unexpectedly large - it may contain build output or game files. Check git status in ps3recomp.' -ForegroundColor Yellow }
Write-Host "`nExported. Test it on a CLEAN copy of the repo (see README, 'Testing a fresh install') before publishing." -ForegroundColor Green
