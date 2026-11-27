# Captures the sound engine's runtime-loaded mixer code (the part that is running slowly in the interpreter) so it can be
# compiled to fast native code. Adds a one-time dump of the SPU's memory to ps3recomp, rebuilds, runs the game briefly.
# Run it, wait ~15 s in the game (start a run, grab a few coins), close the game, then send me ls_dump_*.bin (two files, ~256 KB each).
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'ps3recomp\runtime\spu\spu_channels.c'
$t = [IO.File]::ReadAllText($f)
if ($t -notmatch 'LSDUMP_PATCH') {
  $rx = [regex]'(?s)(\s*)spu_interp_run\(ctx, p\);(\s*)return;'
  if ($rx.Matches($t).Count -ne 1) { throw 'anchor not found exactly once' }
  $ins = '{ static int dn = 0; if (dn < 2 && (p == 0x34A58u || p == 0x30790u)) { char nm[64]; snprintf(nm, sizeof nm, "ls_dump_%05X.bin", p); FILE* df = fopen(nm, "wb"); if (df) { fwrite(ctx->ls, 1, SPU_LS_SIZE, df); fclose(df); dn++; fprintf(stderr, "[ls-dump] wrote %s\n", nm); } } } /* LSDUMP_PATCH */'
  $t = $rx.Replace($t, ('$1' + $ins + '$1spu_interp_run(ctx, p);$2return;'))
  [IO.File]::WriteAllText($f, $t)
  Write-Host 'patched spu_channels.c' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
Write-Host "Play ~15 s (start a run, grab a few coins), then close the game." -ForegroundColor Yellow
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF > lsdump.log 2>&1"
Get-ChildItem ls_dump_*.bin | ForEach-Object { Write-Host "got $($_.FullName) ($($_.Length) bytes)" -ForegroundColor Green }
