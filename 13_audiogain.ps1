# Sound is too loud / clipping. Adds a master gain (env AUDIO_GAIN, default 0.3) + hard limiter to ps3recomp's final audio mix,
# and turns on AUDIO_PEAK so the log shows how hot the game's own mix is. Edit $gain below to taste (0.1 quiet ... 1.0 original).
# Output: au.log (peak lines in au_peak.txt)
param([double]$Gain = 0.3)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'ps3recomp\libs\audio\cellAudio.c'
$t = [IO.File]::ReadAllText($f)
if ($t -notmatch 'AUDIOGAIN_PATCH') {
  $a = 'static void audio_dump_mix(void)'
  if (-not $t.Contains($a)) { throw 'audio_dump_mix not found' }
  $fn = @'
/* AUDIOGAIN_PATCH: master gain + limiter on the final mix (AUDIO_GAIN, default 1.0 unless set) */
static void audio_apply_gain(void)
{
    static float g = -1.0f;
    if (g < 0.0f) { const char* e = getenv("AUDIO_GAIN"); g = e ? (float)atof(e) : 1.0f; if (g < 0.0f) g = 1.0f; }
    for (u32 i = 0; i < CELL_AUDIO_BLOCK_SAMPLES * 2; i++) {
        float v = s_mix_buffer[i] * g;
        if (v > 0.98f) v = 0.98f; else if (v < -0.98f) v = -0.98f;
        s_mix_buffer[i] = v;
    }
}

'@
  $t = $t.Replace($a, $fn + $a)
  $n = ([regex]::Matches($t, 'audio_dump_mix\(\);')).Count
  $t = [regex]::Replace($t, '(\r?\n\s*)audio_dump_mix\(\);', '${1}audio_apply_gain();${1}audio_dump_mix();')
  [IO.File]::WriteAllText($f, $t)
  Write-Host "patched cellAudio.c ($n call sites)" -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'; $env:SPU_HOST_DEPTH_MAX='20000'
$env:AUDIO_GAIN = "$Gain"; $env:AUDIO_PEAK='1'
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object au.log
Select-String au.log -Pattern 'audio-peak' | Select-Object -First 60 | ForEach-Object { $_.Line } | Set-Content au_peak.txt
Write-Host 'Wrote au_peak.txt' -ForegroundColor Green
