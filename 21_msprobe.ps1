# Diagnostic for the music / effects split. Watches the control blocks the Multistream mixer SPU reads and logs which
# words change, so the in-game "music" / "sfx" mute buttons tell us which fields belong to which.
# HOW TO USE: run this, get to gameplay or the pause menu, then:
#   press F2 -> then mute MUSIC in the game (pause menu button) -> wait ~6 s
#   press F3 -> then unmute MUSIC -> wait ~6 s
#   press F2 -> then mute SFX -> wait ~6 s ;  press F3 -> unmute SFX -> wait ~6 s ;   then close the game.
# Output: msprobe.txt  (send it to me)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f1 = Join-Path $Root 'ps3recomp\runtime\spu\spu_channels.c'
$c = [IO.File]::ReadAllText($f1)
if ($c -notmatch 'MSPROBE_PATCH') {
  $probe = @'
/* MSPROBE_PATCH: MS_PROBE=1 -- watch the DMA GETs of the Multistream mixer SPU (image MS_PROBE_IMG, default 437002406).
 * Every 2 s, print the words that changed in each distinct (ea,size) block since the previous report, so toggling
 * "music mute" / "sfx mute" in the game shows which control-block fields belong to music and which to effects.
 * F2/F3/F4 print a marker line (press them right before you change something). */
void ms_probe_dma(int image_id, uint32_t cmd, uint32_t lsa, uint64_t ea, uint32_t size)
{
    static int on = -1; static int img = 437002406;
    if (on < 0) { const char* e = getenv("MS_PROBE"); on = e ? 1 : 0;
                  const char* i = getenv("MS_PROBE_IMG"); if (i) img = (int)strtol(i, 0, 0); }
    if (!on || image_id != img || (ea >> 32) || size < 16 || size > 4096) return;
    if (!mfc_ea_range_committed(ea, size) || !vm_base) return;
    enum { MAXE = 384, KEEP = 256 };
    typedef struct { uint32_t ea, size, lsa, n; uint8_t cur[KEEP], snap[KEEP]; } ent_t;
    static ent_t tab[MAXE]; static int nent; static unsigned long long t0, last_dump, last_key;
    static int k2, k3, k4;
    (void)cmd;
    const unsigned long long now = GetTickCount64();
    if (!t0) { t0 = now; last_dump = now; }
    ent_t* e = NULL;
    for (int i = 0; i < nent; i++) if (tab[i].ea == (uint32_t)ea && tab[i].size == size) { e = &tab[i]; break; }
    if (!e && nent < MAXE) { e = &tab[nent++]; memset(e, 0, sizeof *e); e->ea = (uint32_t)ea; e->size = size; e->lsa = lsa;
                             memcpy(e->snap, vm_base + (uint32_t)ea, size < KEEP ? size : KEEP); }
    if (e) { e->n++; memcpy(e->cur, vm_base + (uint32_t)ea, size < KEEP ? size : KEEP); }
    if (now - last_key >= 40) {
        last_key = now;
        int a = (GetAsyncKeyState(VK_F2) & 0x8000) != 0, b = (GetAsyncKeyState(VK_F3) & 0x8000) != 0, c = (GetAsyncKeyState(VK_F4) & 0x8000) != 0;
        if (a && !k2) fprintf(stderr, "[msprobe] t=%.1f MARK F2\n", (now - t0) / 1000.0);
        if (b && !k3) fprintf(stderr, "[msprobe] t=%.1f MARK F3\n", (now - t0) / 1000.0);
        if (c && !k4) fprintf(stderr, "[msprobe] t=%.1f MARK F4\n", (now - t0) / 1000.0);
        k2 = a; k3 = b; k4 = c;
    }
    if (now - last_dump >= 2000) {
        last_dump = now; int printed = 0;
        for (int i = 0; i < nent && printed < 40; i++) {
            ent_t* x = &tab[i]; uint32_t nb = x->size < KEEP ? x->size : KEEP;
            if (!memcmp(x->cur, x->snap, nb)) continue;
            char buf[600]; int p = 0, shown = 0;
            for (uint32_t w = 0; w + 4 <= nb && shown < 12; w += 4) {
                if (memcmp(x->cur + w, x->snap + w, 4)) {
                    p += snprintf(buf + p, sizeof buf - p, " +%X:%02X%02X%02X%02X->%02X%02X%02X%02X", w,
                        x->snap[w], x->snap[w+1], x->snap[w+2], x->snap[w+3], x->cur[w], x->cur[w+1], x->cur[w+2], x->cur[w+3]);
                    shown++;
                }
            }
            fprintf(stderr, "[msprobe] t=%.1f ea=0x%08X size=%u gets=%u changed:%s\n", (now - t0) / 1000.0, x->ea, x->size, x->n, buf);
            memcpy(x->snap, x->cur, nb); printed++;
        }
        fprintf(stderr, "[msprobe] t=%.1f -- %d distinct blocks tracked\n", (now - t0) / 1000.0, nent);
        fflush(stderr);
    }
}


'@
  $c = $c + [Environment]::NewLine + '#ifdef _WIN32' + [Environment]::NewLine + $probe + [Environment]::NewLine + '#endif' + [Environment]::NewLine
  [IO.File]::WriteAllText($f1, $c); Write-Host 'patched spu_channels.c' -ForegroundColor Green
}
$f2 = Join-Path $Root 'ps3recomp\runtime\spu\spu_dma.h'
$h = [IO.File]::ReadAllText($f2)
if ($h -notmatch 'MSPROBE_PATCH') {
  $anchor = '    /* DMA trace for the cri task (image 22)'
  $i = $h.IndexOf($anchor); if ($i -lt 0) { throw 'spu_dma.h anchor not found' }
  $call = '    /* MSPROBE_PATCH */ { extern void ms_probe_dma(int, uint32_t, uint32_t, uint64_t, uint32_t); if (mfc_is_get(cmd)) ms_probe_dma(spu->image_id, cmd, lsa, ea, size); }' + [Environment]::NewLine
  $h = $h.Insert($i, $call); [IO.File]::WriteAllText($f2, $h); Write-Host 'patched spu_dma.h' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
$env:MS_PROBE='1'
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Select-String -Pattern '\[msprobe\]' | ForEach-Object { $_.Line } | Tee-Object msprobe.txt | Out-Null
Write-Host ("msprobe.txt: " + (Get-Content msprobe.txt | Measure-Object -Line).Lines + ' lines') -ForegroundColor Green
