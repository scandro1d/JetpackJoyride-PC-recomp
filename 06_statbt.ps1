# Diagnostic: patches ps3recomp so the Nth failed cellFsStat dumps the guest call stack, rebuilds, runs.
# Output: statbt.log  (send me the "[statbt]" lines)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'ps3recomp\runtime\ppu\ppu_fs.cpp'
$t = [IO.File]::ReadAllText($f)
# repair a previous (broken) version of this patch: block-scope extern "C" is illegal C++
if ($t.Contains('{ extern "C" void ppu_dump_guest_stack(ppu_context*, const char*);')) {
  $t = $t.Replace('{ extern "C" void ppu_dump_guest_stack(ppu_context*, const char*);', '{')
  [IO.File]::WriteAllText($f, $t); Write-Host 'repaired earlier patch' -ForegroundColor Yellow
}
if ($t -notmatch 'STATBT_DECL') {
  $fn = 'static void cellFsStat(ppu_context* ctx)'
  if (-not $t.Contains($fn)) { throw 'cellFsStat not found in ppu_fs.cpp' }
  $t = $t.Replace($fn, "extern `"C`" void ppu_dump_guest_stack(ppu_context*, const char*); /* STATBT_DECL */`n" + $fn)
  [IO.File]::WriteAllText($f, $t)
}
if ($t -notmatch 'STATBT_PATCH') {
  $anchor = 'if (ps3_env_once("PS3_FSLOG")) fprintf(stderr, "[fs] stat ''%s'' -> ENOENT\n", gpath);'
  if (-not $t.Contains($anchor)) { throw 'anchor not found in ppu_fs.cpp (different toolkit version?)' }
  $add = $anchor + @'

        /* STATBT_PATCH */ { static unsigned _n = 0; _n++;
          if (_n == 2000 || _n == 50000) {
              char tg[160]; snprintf(tg, sizeof tg, "statbt n=%u path=%s", _n, gpath); ppu_dump_guest_stack(ctx, tg); } }
'@
  $t = $t.Replace($anchor, $add)
  [IO.File]::WriteAllText($f, $t)
  Write-Host 'patched ppu_fs.cpp' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:PS3_STDIO_UNBUFFERED='1'
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object statbt.log
Select-String statbt.log -Pattern 'statbt' -Context 0,25 | ForEach-Object { $_.Line; $_.Context.PostContext } | Set-Content statbt_short.log
Write-Host 'Wrote statbt_short.log' -ForegroundColor Green
