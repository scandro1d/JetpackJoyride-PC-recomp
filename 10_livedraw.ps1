# Switch the game to ps3recomp's "live draw" renderer (NV4097 -> D3D12), wired the way the toolkit's own
# boot harness does it. Patches your project's main.cpp, rebuilds, runs with RSX_LIVE_DRAW=1.
# Output: live.log / live_short.log   (the original renderer stays available: just run 05_run.ps1 as before)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'main.cpp'
$t = [IO.File]::ReadAllText($f)
if ($t -notmatch 'LIVEDRAW_PATCH') {
  # 1) declarations + helpers, placed before present_guest_frame()
  $anchor = 'static void present_guest_frame(void)'
  if (-not $t.Contains($anchor)) { throw 'present_guest_frame not found in main.cpp' }
  $block = @'
/* LIVEDRAW_PATCH: opt-in live NV4097 -> D3D12 engine (libs/video/rsx_live_draw.c), selected by RSX_LIVE_DRAW=1 */
extern "C" int      rsx_live_draw_enabled(void);
extern "C" int      rsx_live_draw_init(void* hwnd, uint32_t w, uint32_t h,
                                       const uint8_t* (*guest_ptr)(void*, uint32_t, uint32_t, uint32_t), void* user);
extern "C" void     rsx_live_draw_present(uint32_t buffer_id);
extern "C" int      rsx_null_backend_init(uint32_t w, uint32_t h, const char* title);
extern "C" int      rsx_null_backend_pump_messages(void);
extern "C" void*    rsx_null_backend_get_hwnd(void);
extern "C" void     rsx_null_backend_suppress_present(int on);
extern "C" uint32_t cellGcmResolveLocated(int local, uint32_t offset);
extern "C" uint32_t cellGcmResolveIO(uint32_t offset);
extern "C" unsigned cellGcmGetCurrentDisplayBufferId(void);
static int s_rsx_live = 0;
static const uint8_t* rsx_live_guest_ptr(void*, uint32_t location, uint32_t offset, uint32_t min_bytes)
{
    if (!vm_base) return nullptr;
    uint32_t ea;
    if (location == 0) ea = cellGcmResolveLocated(1, offset);
    else { ea = cellGcmResolveIO(offset); if (!ea) ea = cellGcmResolveLocated(0, offset); }
    if (!ea || ea == 0xFFFFFFFFu || (uint64_t)ea + min_bytes > 0x100000000ull) return nullptr;
    return (const uint8_t*)vm_base + ea;
}
static void rsx_present_frame(void)
{
    if (s_rsx_live) rsx_live_draw_present(cellGcmGetCurrentDisplayBufferId());
    else            rsx_backend_present();
}
static int rsx_pump_messages(void)
{ return s_rsx_live ? rsx_null_backend_pump_messages() : rsx_backend_pump(); }

'@
  $t = $t.Replace($anchor, $block + $anchor)
  # 2) route the two present calls and the message pump
  $t = [regex]::Replace($t, '(static void present_guest_frame\(void\)\s*\{\s*)rsx_backend_present\(\);', '${1}rsx_present_frame();')
  $t = [regex]::Replace($t, '(else if \(fc == 0\) \{\s*)rsx_backend_present\(\);', '${1}rsx_present_frame();')
  $t = $t.Replace('if (rsx_backend_pump() != 0)', 'if (rsx_pump_messages() != 0)')
  # 3) backend init
  $init = 'int rsx_ok = (rsx_backend_init(WINDOW_WIDTH, WINDOW_HEIGHT, title) == 0);'
  if (-not $t.Contains($init)) { throw 'backend init line not found in main.cpp' }
  $newinit = @'
int rsx_ok;
    if (rsx_live_draw_enabled()) {
        rsx_ok = (rsx_null_backend_init(WINDOW_WIDTH, WINDOW_HEIGHT, title) == 0);
        if (rsx_ok && rsx_live_draw_init(rsx_null_backend_get_hwnd(), WINDOW_WIDTH, WINDOW_HEIGHT,
                                         rsx_live_guest_ptr, nullptr) == 0) {
            s_rsx_live = 1;
            rsx_null_backend_suppress_present(1);
            fprintf(stderr, "[rsx] live-draw engine up (D3D12); GDI present suppressed\n");
        } else {
            fprintf(stderr, "[rsx] live-draw init FAILED -- falling back to the D3D12 backend\n");
            rsx_ok = (rsx_backend_init(WINDOW_WIDTH, WINDOW_HEIGHT, title) == 0);
        }
    } else {
        rsx_ok = (rsx_backend_init(WINDOW_WIDTH, WINDOW_HEIGHT, title) == 0);
    }
'@
  $t = $t.Replace($init, $newinit.TrimEnd("`r","`n"))
  if (($t -split 'rsx_present_frame\(\);').Count -lt 3) { throw 'present call sites were not patched (main.cpp differs from the template)' }
  [IO.File]::WriteAllText($f, $t)
  Write-Host 'patched main.cpp' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object live.log
Select-String live.log -NotMatch -Pattern '^\[WAIT\]|^\[evt\] q=1 receive|write_spu_mb|^\[HLETRACE\]' | ForEach-Object { $_.Line } | Select-Object -Last 100 | Set-Content live_short.log
Write-Host 'Wrote live_short.log' -ForegroundColor Green
