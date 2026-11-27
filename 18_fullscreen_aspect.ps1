# Fullscreen now keeps 16:9: borderless at your desktop resolution, game centred on a black backdrop (pillarbox on ultrawide).
# Updates settings_menu.h, rebuilds, launches.
. "$PSScriptRoot\env.ps1"
Set-Location $Root
Copy-Item (Join-Path $PSScriptRoot 'patches\settings_menu.h') (Join-Path $Root 'settings_menu.h') -Force
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
& "$PSScriptRoot\play.ps1"
