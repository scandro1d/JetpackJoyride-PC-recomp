# Sound dies after ~1 minute: the SPU audio mixer polls in a loop that returns through a register other than $r0, so every
# iteration leaves a host stack frame behind (depth reached the 20000 limit -> SPU halted). ps3recomp has an opt-in fix,
# SPU_TAILRET=1, which treats such a transfer as the return. This runs the game with it. No rebuild needed.
# Usage: .\14_tailret.ps1 [-Gain 0.3]     Output: tr.log, tr_audio.txt
param([double]$Gain = 0.3)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'; $env:SPU_HOST_DEPTH_MAX='20000'
$env:SPU_TAILRET='1'; $env:AUDIO_GAIN="$Gain"; $env:AUDIO_PEAK='1'
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object tr.log
Select-String tr.log -Pattern 'spu-depth|FAULT|d3d-fail|audio-peak' | Select-Object -First 25 | ForEach-Object { $_.Line } | Set-Content tr_audio.txt
Select-String tr.log -Pattern 'audio-peak' | Select-Object -Last 5 | ForEach-Object { $_.Line } | Add-Content tr_audio.txt
Write-Host 'Wrote tr_audio.txt' -ForegroundColor Green
