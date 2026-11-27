# Step 1: removes the experimental "audio lead" change (it made the glitches worse) and rebuilds.
# Step 2: runs the game with the runtime's SPU interpreter statistics on, next to the audio report, so we can see
#         which sound-engine code the coin pickups run through the slow interpreter.
# Play ~40 s: run normally for a few seconds, then collect lots of coins, then close the game. Send audio_rate.txt.
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'ps3recomp\libs\audio\cellAudio.c'
$t = [IO.File]::ReadAllText($f)
if ($t -match 'AUDIOLEAD_PATCH') {
  $rx = [regex]'\{ static int lead = -1;.*?/\* AUDIOLEAD_PATCH \*/'
  if ($rx.Matches($t).Count -ne 1) { throw 'could not find the lead patch to remove' }
  $t = $rx.Replace($t, 'vm_write64((u32)port->read_idx_addr, port->read_index % nblock);')
  [IO.File]::WriteAllText($f, $t)
  Write-Host 'removed the lead change from cellAudio.c' -ForegroundColor Green
  & "$PSScriptRoot\04_build.ps1"
  if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
} else { Write-Host 'lead change already removed' }

$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
$env:AUDIO_RATE='1'; $env:SPU_INTERP_STATS='2'
Remove-Item Env:AUDIO_LEAD -ErrorAction SilentlyContinue
Write-Host "Play now: ~10 s normal running, then collect lots of coins for ~20 s, then close the game." -ForegroundColor Yellow
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF > au_rate.log 2>&1"
$lines = Select-String -Path au_rate.log -Pattern '^\[audio-rate\]|^\[spu-interp\]|^  top |^    img=|interpreting unlifted' | ForEach-Object { $_.Line }
$lines | Select-Object -First 600 | Set-Content audio_rate.txt
Write-Host "Wrote audio_rate.txt ($($lines.Count) lines) - send it to me" -ForegroundColor Green
