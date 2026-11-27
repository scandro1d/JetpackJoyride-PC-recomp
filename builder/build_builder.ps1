# Rebuilds builder\builder.exe from builder.c (needs the Visual Studio Build Tools with clang-cl and the Windows SDK).
. "$PSScriptRoot\..\scripts\env.ps1"
Import-VsEnv
Set-Location $PSScriptRoot
rc /nologo builder.rc
if ($LASTEXITCODE) { throw 'rc failed' }
clang-cl /nologo /O2 /MT /W3 builder.c builder.res /Fe:builder.exe /link /SUBSYSTEM:WINDOWS comctl32.lib shell32.lib ole32.lib user32.lib gdi32.lib uuid.lib
if ($LASTEXITCODE -or -not (Test-Path builder.exe)) { throw 'builder build failed' }
Remove-Item builder.obj, builder.res -ErrorAction SilentlyContinue
Write-Host 'Built builder\builder.exe' -ForegroundColor Green
