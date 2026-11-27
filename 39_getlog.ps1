# Finds where the sound engine's runtime-loaded mixer code comes from (which main-memory address it is copied in from).
# Patches a log line into ps3recomp, rebuilds, runs ~15 s. Play briefly (start a run), close the game, send getlog.txt.
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'ps3recomp\runtime\spu\spu_channels.c'
$t = [IO.File]::ReadAllText($f)
if ($t -notmatch 'GETLOG_PATCH') {
  $anchor = 'uint32_t lsa = (uint32_t)(ls - ctx->ls);'
  if (([regex]::Matches($t, [regex]::Escape($anchor))).Count -ne 1) { throw 'anchor not found exactly once' }
  $ins = $anchor + ' { static int gn = 0; if (lsa >= 0x30000u && lsa < 0x38000u && gn < 400) { gn++; fprintf(stderr, "[getlog] img=%d ea=0x%08X lsa=0x%05X size=%u first=%02X%02X%02X%02X\n", ctx->image_id, ea, lsa, size, ls[0], ls[1], ls[2], ls[3]); } } /* GETLOG_PATCH */'
  $t = $t.Replace($anchor, $ins)
  [IO.File]::WriteAllText($f, $t)
  Write-Host 'patched' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
Write-Host "Play ~15 s, then close the game." -ForegroundColor Yellow
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF > getlog.log 2>&1"
Select-String -Path getlog.log -Pattern '^\[getlog\]|interpreting unlifted' | ForEach-Object { $_.Line } | Select-Object -First 400 | Set-Content getlog.txt
Write-Host "Wrote getlog.txt" -ForegroundColor Green
