# Diagnose the sound-effect glitches on coins / power-ups. Runs the game with the runtime's AUDIO_RATE report on.
# Play until you've collected lots of coins and a few power-ups (30-60 s of glitching is plenty), close the game, then send
# audio_rate.txt.  Optional:  -BufMs 40   makes the audio device buffer larger (tests whether the glitch is the sound card running dry).
param([int]$BufMs = 0, [int]$Lead = 0)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
$env:AUDIO_RATE='1'
if ($Lead -gt 0) { $env:AUDIO_LEAD = "$Lead" } else { Remove-Item Env:AUDIO_LEAD -ErrorAction SilentlyContinue }
if ($BufMs -gt 0) { $env:PS3_AUDIO_BUF_MS = "$BufMs" } else { Remove-Item Env:PS3_AUDIO_BUF_MS -ErrorAction SilentlyContinue }
Write-Host "Play now: collect lots of coins and power-ups, then close the game." -ForegroundColor Yellow
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF > au_rate.log 2>&1"
$lines = Select-String -Path au_rate.log -Pattern '\[audio-rate\]|\[audio-lead\]|\[cellAudio\] (HAS|MMCSS|WASAPI)|underrun|SPU.*(FAULT|depth)' | ForEach-Object { $_.Line }
"BufMs=$BufMs Lead=$Lead" | Set-Content audio_rate.txt
$lines | Select-Object -First 400 | Add-Content audio_rate.txt
Write-Host "Wrote audio_rate.txt ($($lines.Count) lines)" -ForegroundColor Green
