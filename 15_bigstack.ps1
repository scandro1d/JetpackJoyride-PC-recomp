# Sound still dies (~90 s now, was ~50 s): the mixer still leaks one host stack frame per loop pass, even with SPU_TAILRET.
# Stop-gap: give SPU threads a 512 MB stack (reserved, not committed) and allow 500000 frames instead of 20000.
# That is ~25x longer before it trips (roughly 40+ minutes). A real fix needs the leaking loop traced (see tr_events2.txt).
# Usage: .\15_bigstack.ps1 [-Gain 0.3]     Output: bs.log, bs_audio.txt
param([double]$Gain = 0.3)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
$env:AUDIO_GAIN="$Gain"; $env:AUDIO_PEAK='1'
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object bs.log
Select-String bs.log -Pattern 'spu-depth|FAULT|stopped|d3d-fail|stack overflow' | Select-Object -First 10 | ForEach-Object { $_.Line } | Set-Content bs_audio.txt
Select-String bs.log -Pattern 'audio-peak' | Select-Object -Last 8 | ForEach-Object { $_.Line } | Add-Content bs_audio.txt
Write-Host 'Wrote bs_audio.txt' -ForegroundColor Green
