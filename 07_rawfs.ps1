# Diagnostic: log the game's RAW kernel file calls (open/read/lseek/fstat/stat/close), rebuild, run.
# Output: rawfs.log + rawfs_short.log  (send me rawfs_short.log)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'ps3recomp\runtime\syscalls\sys_fs.c'
$t = [IO.File]::ReadAllText($f)
if ($t -notmatch 'RAWFS_PATCH') {
  foreach ($n in 'open','read','close','lseek','stat','fstat') {
    $sig = "int64_t sys_fs_$n(ppu_context* ctx)"
    $idx = $t.IndexOf($sig + "`n"); if ($idx -lt 0) { $idx = $t.IndexOf($sig + "`r`n") }
    if ($idx -lt 0) { throw "signature not found: $sig" }
    $wrap = "static int64_t sys_fs_${n}_impl(ppu_context* ctx); /* RAWFS_PATCH */`n" +
      "int64_t sys_fs_$n(ppu_context* ctx) { int64_t r = sys_fs_${n}_impl(ctx); static int c; if (c++ < 60) { " +
      $(if ($n -in 'open','stat') { "fprintf(stderr, `"[rawfs] $n '%s' -> %d\n`", (const char*)vm_to_host((uint32_t)ctx->gpr[3]), (int)r);" }
        else { "fprintf(stderr, `"[rawfs] $n fd=%d a1=0x%llX a2=0x%llX -> %d\n`", (int)ctx->gpr[3], (unsigned long long)ctx->gpr[4], (unsigned long long)ctx->gpr[5], (int)r);" }) +
      " } return r; }`n"
    $t = $t.Substring(0,$idx) + $wrap + "static " + $t.Substring($idx).Replace($sig, "int64_t sys_fs_${n}_impl(ppu_context* ctx)").Substring(0) 
  }
  [IO.File]::WriteAllText($f, $t)
  Write-Host 'patched sys_fs.c' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:PS3_STDIO_UNBUFFERED='1'
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object rawfs.log
Select-String rawfs.log -Pattern '^\[rawfs\]|^\[LV2\]' | ForEach-Object { $_.Line } | Select-Object -First 150 | Set-Content rawfs_short.log
Write-Host 'Wrote rawfs_short.log' -ForegroundColor Green
