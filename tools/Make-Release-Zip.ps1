# MAINTAINER TOOL: packs the download users get: builder.exe + the build kit. Run after Export-FromWorkingTree.ps1.
#   .\tools\Make-Release-Zip.ps1 -Version 0.1
param([string]$Version = '0.1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
foreach ($need in 'patches\ps3recomp-jj.patch','project\main.cpp','project\CMakeLists.txt','project\stubs.cpp','project\config.toml','project\settings_menu.h','builder\builder.exe') {
    if (-not (Test-Path (Join-Path $repo $need))) { throw "Missing $need - run tools\Export-FromWorkingTree.ps1 (and builder\build_builder.ps1 if builder.exe is absent) first." }
}
$stage = Join-Path $env:TEMP "jj_release_$Version"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
$top = Join-Path $stage "JetpackJoyride-Builder-$Version"
New-Item -ItemType Directory -Force $top | Out-Null
Copy-Item (Join-Path $repo 'builder\builder.exe') $top
foreach ($d in 'scripts','patches','project','launcher') { Copy-Item (Join-Path $repo $d) (Join-Path $top $d) -Recurse }
foreach ($f in 'README.md','LICENSE','NOTICE.md') { Copy-Item (Join-Path $repo $f) $top }
Get-ChildItem $top -Recurse -Include .gitkeep,*.log | Remove-Item -Force
$zip = Join-Path $repo "JetpackJoyride-Builder-$Version.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path $top -DestinationPath $zip
Write-Host "Created $zip" -ForegroundColor Green
