# Normal launcher with all the fixes from this session (no rebuild). F1 = settings menu, F11 = fullscreen.
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
Remove-Item Env:AUDIO_GAIN, Env:AUDIO_PEAK -ErrorAction SilentlyContinue
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF > play.log 2>&1"
