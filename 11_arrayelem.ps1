# FIX: the game draws with NV4097_ARRAY_ELEMENT16 (0x180C) immediate indices inside BEGIN/END. The live-draw engine
# only knows DRAW_ARRAYS / DRAW_INDEX_ARRAY / INLINE_ARRAY, so every draw was dropped (groups[seen=0]).
# This patch collects the immediate indices and, at END, replays them as a DRAW_INDEX_ARRAY over a host-side buffer.
# Patches ps3recomp (rsx_live_draw.c) + your main.cpp, rebuilds, runs with RSX_LIVE_DRAW=1. Output: ae.log / ae_short.log
. "$PSScriptRoot\env.ps1"
Set-Location $Root

# --- 1. rsx_live_draw.c: intercept ARRAY_ELEMENT16/32 + END
$f1 = Join-Path $Root 'ps3recomp\libs\video\rsx_live_draw.c'
$t = [IO.File]::ReadAllText($f1)
if ($t -notmatch 'ARRAYELEM_PATCH') {
  $m = [regex]::Match($t, 'void rsx_live_draw_method\(u32 method, u32 arg\)\r?\n\{')
  if (-not $m.Success) { throw 'rsx_live_draw_method not found' }
  $wrap = @'
/* ARRAYELEM_PATCH: immediate-index draws (NV4097_ARRAY_ELEMENT16 0x180C / ARRAY_ELEMENT32 0x1810).
 * Indices are collected and, at SET_BEGIN_END(0), replayed as SET_INDEX_ARRAY_ADDRESS/DMA + DRAW_INDEX_ARRAY
 * over a host ring (served to the engine through the guest_ptr callback at offsets >= 0xF0000000). */
#define AE_SENT      0xF0000000u
#define AE_RING_BYTES (4u * 1024u * 1024u)
#define AE_MAX_IDX   65536u
static u8  s_ae_ring[AE_RING_BYTES];
static u32 s_ae_off;
static u32 s_ae_idx[AE_MAX_IDX];
static u32 s_ae_n;
static void ld_method_impl(u32 method, u32 arg);
const u8* rsx_synth_idx_ptr(u32 off, u32 bytes)
{
    if ((u64)off + bytes > AE_RING_BYTES) return NULL;
    return s_ae_ring + off;
}
static void ae_flush(u32 sub)
{
    u32 n = s_ae_n;
    s_ae_n = 0;
    if (!n) return;
    if (n * 4u > AE_RING_BYTES) n = AE_RING_BYTES / 4u;
    if (s_ae_off + n * 4u > AE_RING_BYTES) s_ae_off = 0;
    const u32 base = s_ae_off;
    for (u32 i = 0; i < n; i++) {
        u8* p = s_ae_ring + base + i * 4u;
        const u32 v = s_ae_idx[i];
        p[0] = (u8)(v >> 24); p[1] = (u8)(v >> 16); p[2] = (u8)(v >> 8); p[3] = (u8)v;
    }
    s_ae_off = (base + n * 4u + 15u) & ~15u;
    ld_method_impl((sub << 13) | 0x181Cu, AE_SENT + base);
    ld_method_impl((sub << 13) | 0x1820u, 0x00000001u);     /* location 1, type 0 = 32-bit */
    for (u32 first = 0; first < n; first += 256u) {
        u32 c = n - first; if (c > 256u) c = 256u;
        ld_method_impl((sub << 13) | 0x1824u, (first & 0xFFFFFFu) | ((c - 1u) << 24));
    }
}
void rsx_live_draw_method(u32 method, u32 arg)
{
    const u32 cm = method & 0x1FFCu, sub = (method >> 13) & 7u;
    if (cm == 0x180Cu) {
        if (s_ae_n + 2u <= AE_MAX_IDX) { s_ae_idx[s_ae_n++] = arg & 0xFFFFu; s_ae_idx[s_ae_n++] = arg >> 16; }
        return;
    }
    if (cm == 0x1810u) {
        if (s_ae_n + 1u <= AE_MAX_IDX) s_ae_idx[s_ae_n++] = arg;
        return;
    }
    if (cm == 0x1808u) {
        if (arg == 0) ae_flush(sub); else s_ae_n = 0;
    }
    ld_method_impl(method, arg);
}

'@
  $t = $t.Substring(0, $m.Index) + $wrap + 'static void ld_method_impl(u32 method, u32 arg)' + [Environment]::NewLine + '{' + $t.Substring($m.Index + $m.Length)
  [IO.File]::WriteAllText($f1, $t)
  Write-Host 'patched rsx_live_draw.c' -ForegroundColor Green
}

# --- 2. main.cpp: serve the synthetic index buffer
$f2 = Join-Path $Root 'main.cpp'
$s = [IO.File]::ReadAllText($f2)
if ($s -notmatch 'ARRAYELEM_PATCH') {
  $m = [regex]::Match($s, 'static const uint8_t\* rsx_live_guest_ptr\(void\*, uint32_t location, uint32_t offset, uint32_t min_bytes\)\r?\n\{')
  if (-not $m.Success) { throw 'rsx_live_guest_ptr not found in main.cpp (run 10_livedraw.ps1 first)' }
  $add = 'extern "C" const uint8_t* rsx_synth_idx_ptr(uint32_t off, uint32_t bytes); /* ARRAYELEM_PATCH */' + [Environment]::NewLine
  $s = $s.Substring(0, $m.Index) + $add + $s.Substring($m.Index, $m.Length) + [Environment]::NewLine +
       '    if (offset >= 0xF0000000u) return rsx_synth_idx_ptr(offset - 0xF0000000u, min_bytes);' + $s.Substring($m.Index + $m.Length)
  [IO.File]::WriteAllText($f2, $s)
  Write-Host 'patched main.cpp' -ForegroundColor Green
}

& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object ae.log
Select-String ae.log -NotMatch -Pattern '^\[WAIT\]|^\[evt\] q=1 receive|write_spu_mb|^\[HLETRACE\]|^\[RSX null\]' | ForEach-Object { $_.Line } | Select-Object -Last 100 | Set-Content ae_short.log
Write-Host 'Wrote ae_short.log' -ForegroundColor Green
