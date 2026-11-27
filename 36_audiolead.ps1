# Sound effects glitch on coins / power-ups: the game's audio engine delivers a block late and the whole mix drops out for a moment.
# Fix: tell the game the mixer's read position is N blocks AHEAD, so it writes N blocks further ahead of playback and a late
# block has more time to arrive (costs N x 5.3 ms extra delay on every sound). N comes from env AUDIO_LEAD (0 = off).
# This patches cellAudio.c, rebuilds, and runs the diagnostic with the lead you give (default 4). Output: audio_rate.txt
param([int]$Lead = 4)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'ps3recomp\libs\audio\cellAudio.c'
$t = [IO.File]::ReadAllText($f)
if ($t -notmatch 'AUDIOLEAD_PATCH') {
  $old = 'vm_write64((u32)port->read_idx_addr, port->read_index % nblock);'
  if (([regex]::Matches($t, [regex]::Escape($old))).Count -ne 1) { throw 'read-index line not found exactly once' }
  $new = '{ static int lead = -1; if (lead < 0) { const char* e = getenv("AUDIO_LEAD"); lead = e ? atoi(e) : 0; if (lead < 0) lead = 0; fprintf(stderr, "[audio-lead] %d blocks\n", lead); } vm_write64((u32)port->read_idx_addr, (port->read_index + (u64)lead) % nblock); } /* AUDIOLEAD_PATCH */'
  $t = $t.Replace($old, $new)
  [IO.File]::WriteAllText($f, $t)
  Write-Host 'patched cellAudio.c' -ForegroundColor Green
} else { Write-Host 'cellAudio.c already patched' }
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
& "$PSScriptRoot\35_audiodiag.ps1" -Lead $Lead
