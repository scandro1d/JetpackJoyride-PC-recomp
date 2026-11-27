# Diagnostic v2 for the music / effects split. Watches the control blocks the Multistream mixer SPU reads and logs which
# words change, so the in-game "music" / "sfx" mute buttons tell us which fields belong to which.
# HOW TO USE (v2): run this and get into a run (or the pause menu) with music AND sound effects audible. Wait 15 s. Then:
#   press F2, THEN click the MUSIC mute button        -> wait 6 s
#   press F3, THEN click the MUSIC button again (unmute) -> wait 6 s
#   press F4, THEN click the SFX (sound effects) mute button -> wait 6 s
#   press F5, THEN click the SFX button again (unmute) -> wait 6 s ;   then close the game.
# Output: msprobe2.txt  (send it to me)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f1 = Join-Path $Root 'ps3recomp\runtime\spu\spu_channels.c'
$c = [IO.File]::ReadAllText($f1)
$probe = @'
/* MSPROBE_PATCH v2: watch only the Multistream per-channel blocks (size MS_PROBE_SIZE, default 1168). */
void ms_probe_dma(int image_id, uint32_t cmd, uint32_t lsa, uint64_t ea, uint32_t size)
{
    static int on = -1; static int img = 437002406; static uint32_t want = 1168;
    if (on < 0) { const char* e = getenv("MS_PROBE"); on = e ? 1 : 0;
                  const char* i = getenv("MS_PROBE_IMG"); if (i) img = (int)strtol(i, 0, 0);
                  const char* z = getenv("MS_PROBE_SIZE"); if (z) want = (uint32_t)strtol(z, 0, 0); }
    if (!on || image_id != img || (ea >> 32) || size != want) return;
    if (!mfc_ea_range_committed(ea, size) || !vm_base) return;
    enum { MAXE = 48, KEEP = 1200 };
    typedef struct { uint32_t ea, size, lsa, n; uint8_t cur[KEEP], snap[KEEP]; } ent_t;
    static ent_t tab[MAXE]; static int nent; static unsigned long long t0, last_dump, last_key; static int k[6], dumped;
    (void)cmd;
    const unsigned long long now = GetTickCount64();
    if (!t0) { t0 = now; last_dump = now; }
    ent_t* e = NULL;
    for (int i = 0; i < nent; i++) if (tab[i].ea == (uint32_t)ea) { e = &tab[i]; break; }
    if (!e && nent < MAXE) { e = &tab[nent++]; memset(e, 0, sizeof *e); e->ea = (uint32_t)ea; e->size = size; e->lsa = lsa;
                             memcpy(e->snap, vm_base + (uint32_t)ea, size); }
    if (e) { e->n++; memcpy(e->cur, vm_base + (uint32_t)ea, size); }
    int want_dump = 0;
    if (now - last_key >= 40) {
        last_key = now;
        static const int vk[4] = { VK_F2, VK_F3, VK_F4, VK_F5 }; static const char* nm[4] = { "F2", "F3", "F4", "F5" };
        for (int j = 0; j < 4; j++) { int d = (GetAsyncKeyState(vk[j]) & 0x8000) != 0;
            if (d && !k[j]) { fprintf(stderr, "[msprobe] t=%.1f MARK %s\n", (now - t0) / 1000.0, nm[j]); }
            k[j] = d; }
    }
    if (!dumped && now - t0 >= 12000) { dumped = 1; want_dump = 1; }
    if (want_dump) {
        for (int i = 0; i < nent; i++) {
            fprintf(stderr, "[msprobe] DUMP block %d ea=0x%08X lsa=0x%05X gets=%u\n", i, tab[i].ea, tab[i].lsa, tab[i].n);
            for (uint32_t w = 0; w < tab[i].size; w += 32) {
                int nz = 0; for (uint32_t q = 0; q < 32 && w + q < tab[i].size; q++) if (tab[i].cur[w + q]) nz = 1;
                if (!nz) continue;
                fprintf(stderr, "[msprobe]   +%03X:", w);
                for (uint32_t q = 0; q < 32 && w + q < tab[i].size; q++) fprintf(stderr, "%s%02X", (q & 3) ? "" : " ", tab[i].cur[w + q]);
                fprintf(stderr, "\n");
            }
        }
        fflush(stderr);
    }
    if (now - last_dump >= 1000) {
        last_dump = now;
        for (int i = 0; i < nent; i++) {
            ent_t* x = &tab[i];
            if (!memcmp(x->cur, x->snap, x->size)) continue;
            char buf[700]; int p = 0, shown = 0;
            for (uint32_t w = 0; w + 4 <= x->size && shown < 16; w += 4) {
                if (memcmp(x->cur + w, x->snap + w, 4)) {
                    p += snprintf(buf + p, sizeof buf - p, " +%X:%02X%02X%02X%02X->%02X%02X%02X%02X", w,
                        x->snap[w], x->snap[w+1], x->snap[w+2], x->snap[w+3], x->cur[w], x->cur[w+1], x->cur[w+2], x->cur[w+3]);
                    shown++;
                }
            }
            fprintf(stderr, "[msprobe] t=%.1f block%d ea=0x%08X changed:%s\n", (now - t0) / 1000.0, i, x->ea, buf);
            memcpy(x->snap, x->cur, x->size);
        }
        fflush(stderr);
    }
}
'@
$m = [regex]::Match($c, '\r?\n#ifdef _WIN32\r?\n/\* MSPROBE_PATCH')
if ($m.Success) { $c = $c.Substring(0, $m.Index) }   # drop the v1 probe
if ($c -notmatch 'MSPROBE_PATCH v2') {
  $c = $c + [Environment]::NewLine + '#ifdef _WIN32' + [Environment]::NewLine + $probe + [Environment]::NewLine + '#endif' + [Environment]::NewLine
  [IO.File]::WriteAllText($f1, $c); Write-Host 'patched spu_channels.c (probe v2)' -ForegroundColor Green
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
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Select-String -Pattern '\[msprobe\]' | ForEach-Object { $_.Line } | Tee-Object msprobe2.txt | Out-Null
Write-Host ("msprobe2.txt: " + (Get-Content msprobe2.txt | Measure-Object -Line).Lines + ' lines') -ForegroundColor Green
