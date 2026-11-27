# FIX: the game opens files via cellFsOpen (HLE table) but reads/seeks/closes via raw kernel syscalls
# (a different table) -> EBADF. This patch lets the raw syscalls fall back to the HLE table.
# Patches ps3recomp, rebuilds, runs. Output: fix.log
. "$PSScriptRoot\env.ps1"
Set-Location $Root

# --- 0. undo the logging patch from 07_rawfs.ps1 (restores the original sys_fs.c)
git -C "$Root\ps3recomp" checkout -- runtime/syscalls/sys_fs.c

# --- 1. ppu_fs.cpp: export a bridge that runs the HLE handler for an fd it owns
$f1 = Join-Path $Root 'ps3recomp\runtime\ppu\ppu_fs.cpp'
$t = [IO.File]::ReadAllText($f1)
if ($t -notmatch 'FDBRIDGE_PATCH') {
  $anchor = 'static void cellFsAioInit(ppu_context* ctx)'
  if (-not $t.Contains($anchor)) { throw 'anchor (cellFsAioInit) not found in ppu_fs.cpp' }
  $bridge = @'
/* FDBRIDGE_PATCH: raw lv2 syscalls (sys_fs.c) fall back here for fds opened through cellFsOpen.
 * op: 0=read 1=lseek 2=fstat 3=close. Argument registers of the raw syscalls are laid out like the
 * cellFs imports (fd, buf/off, size/whence, out-ptr). Returns 1 and the result if this layer owns fd. */
extern "C" int ppu_fs_try_raw(int op, ppu_context* ctx, int64_t* out)
{
    int fd = (int)(uint32_t)ctx->gpr[3];
    if (!fd_file(fd)) return 0;
    switch (op) {
        case 0: cellFsRead(ctx);  break;
        case 1: cellFsLseek(ctx); break;
        case 2: cellFsFstat(ctx); break;
        case 3: cellFsClose(ctx); break;
        default: return 0;
    }
    *out = (int64_t)(int32_t)(uint32_t)ctx->gpr[3];
    return 1;
}

'@
  $t = $t.Replace($anchor, $bridge + $anchor)
  [IO.File]::WriteAllText($f1, $t)
  Write-Host 'patched ppu_fs.cpp' -ForegroundColor Green
}

# --- 2. sys_fs.c: ask the bridge first when the raw table does not hold the fd
$f2 = Join-Path $Root 'ps3recomp\runtime\syscalls\sys_fs.c'
$s = [IO.File]::ReadAllText($f2)
if ($s -notmatch 'FDBRIDGE_PATCH') {
  $nl = if ($s.Contains("`r`n")) { "`r`n" } else { "`n" }
  $ops = @{ 'read' = 0; 'lseek' = 1; 'fstat' = 2; 'close' = 3 }
  foreach ($n in $ops.Keys) {
    $sig = "int64_t sys_fs_$n(ppu_context* ctx)" + $nl + '{'
    if (-not $s.Contains($sig)) { throw "signature not found in sys_fs.c: sys_fs_$n" }
    $code = $sig + $nl + "    /* FDBRIDGE_PATCH */ { int32_t _fd = (int32_t)ctx->gpr[3]; int _s = _fd - 3;" +
      " if (_s < 0 || _s >= SYS_FS_FD_MAX || !g_sys_fs_fds[_s].active) { int64_t _r; if (ppu_fs_try_raw($($ops[$n]), ctx, &_r)) return _r; } }"
    $s = $s.Replace($sig, $code)
  }
  $decl = "extern int ppu_fs_try_raw(int op, ppu_context* ctx, int64_t* out); /* FDBRIDGE_PATCH */" + $nl
  $first = $s.IndexOf('int64_t sys_fs_open(ppu_context* ctx)')
  if ($first -lt 0) { throw 'sys_fs_open not found' }
  $s = $s.Substring(0, $first) + $decl + $s.Substring($first)
  [IO.File]::WriteAllText($f2, $s)
  Write-Host 'patched sys_fs.c' -ForegroundColor Green
}

& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'
Remove-Item Env:PS3_FSLOG -ErrorAction SilentlyContinue
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object fix.log
Select-String fix.log -NotMatch -Pattern '^\[WAIT\]|^\[evt\] q=1 receive|write_spu_mb|^\[HLETRACE\]' | ForEach-Object { $_.Line } | Select-Object -Last 120 | Set-Content fix_short.log
Write-Host 'Wrote fix_short.log' -ForegroundColor Green
