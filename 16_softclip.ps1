# Clipping fix. The mixer hard-clips the SUM of the game's audio ports at +-1.0 inside ps3recomp, before my master gain
# (13_audiogain.ps1) ever ran, so lowering the gain could not remove the distortion. This moves the gain in FRONT of
# that clip and replaces the hard clip with a soft knee (smooth compression above 0.7).
# Usage: .\16_softclip.ps1 [-Gain 0.35]   (lower = quieter / cleaner; try 0.2-0.5)    Output: sc.log
param([double]$Gain = 0.35)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'ps3recomp\libs\audio\cellAudio.c'
$t = [IO.File]::ReadAllText($f)
if ($t -notmatch 'SOFTCLIP_PATCH') {
  $nl = if ($t.Contains("`r`n")) { "`r`n" } else { "`n" }
  # 1) the earlier post-clip gain stage becomes a pass-through
  $o1 = 'float v = s_mix_buffer[i] * g;'
  if (-not $t.Contains($o1)) { throw 'audio_apply_gain (13_audiogain.ps1) not found - run 13 first' }
  $t = $t.Replace($o1, 'float v = s_mix_buffer[i]; (void)g;')
  # 2) gain + soft knee instead of the hard clip
  $m = [regex]::Match($t, '    /\* Clip to \[-1\.0, 1\.0\] \*/\r?\n    for \(u32 i = 0; i < CELL_AUDIO_BLOCK_SAMPLES \* 2; i\+\+\) \{\r?\n.*?\r?\n.*?\r?\n    \}')
  if (-not $m.Success) { throw 'hard clip loop not found in cellAudio.c' }
  $new = @'
    /* SOFTCLIP_PATCH: master gain BEFORE limiting, then a soft knee above 0.7 (asymptote 1.0) */
    {
        static float s_g = -1.0f;
        if (s_g < 0.0f) { const char* e = getenv("AUDIO_GAIN"); s_g = e ? (float)atof(e) : 1.0f; if (s_g < 0.0f) s_g = 1.0f; }
        for (u32 i = 0; i < CELL_AUDIO_BLOCK_SAMPLES * 2; i++) {
            float v = s_mix_buffer[i] * s_g;
            float a = v < 0.0f ? -v : v;
            if (a > 0.7f) { float x = (a - 0.7f) * (1.0f / 0.3f); a = 0.7f + 0.3f * (x / (1.0f + x)); }
            s_mix_buffer[i] = v < 0.0f ? -a : a;
        }
    }
'@
  $t = $t.Substring(0, $m.Index) + $new.Replace("`r`n","`n").Replace("`n",$nl) + $t.Substring($m.Index + $m.Length)
  [IO.File]::WriteAllText($f, $t)
  Write-Host 'patched cellAudio.c' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
$env:AUDIO_GAIN="$Gain"
Remove-Item Env:AUDIO_PEAK -ErrorAction SilentlyContinue
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object sc.log | Out-Null
Write-Host 'done (sc.log)' -ForegroundColor Green
