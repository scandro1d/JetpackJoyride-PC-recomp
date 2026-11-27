# Creates the fast native version of the sound engine's runtime-loaded mixer code (fixes crackling coin sounds) from the
# user's OWN game: runs the game once so the runtime saves that code to a file, compiles it into the game and rebuilds.
# Nothing from the game is shipped; everything is generated locally. Same file is used in the working folder and in the release kit.
#   -Soft   on any problem print a warning and carry on (the game still works, coin sounds may crackle)
#   -Jobs   parallel compile jobs for the rebuild
param([int]$Jobs = 4, [switch]$Soft)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$ErrorActionPreference = 'Stop'
function Bail([string]$m) {
    if ($Soft) { Write-Host "WARNING: $m" -ForegroundColor Yellow; Write-Host 'Continuing without the sound fix (the game works; coin sounds may crackle).' -ForegroundColor Yellow; exit 0 }
    throw $m
}
$tools = Join-Path $Root 'ps3recomp\tools'
$f = Join-Path $Root 'ps3recomp\runtime\spu\spu_channels.c'
if (-not (Test-Path $f)) { Bail 'ps3recomp is missing (run the earlier steps first).' }

# 0) older working folders: add the one-time capture hook (the release patch already contains it)
$t = [IO.File]::ReadAllText($f)
if ($t -notmatch 'MIXPLUG_CAPTURE') {
    $rx = [regex]'(?s)(\s*)spu_interp_run\(ctx, p\);(\s*)return;'
    if ($rx.Matches($t).Count -ne 1) { Bail 'could not add the capture hook (unexpected source)' }
    $ins = '{ static int dn = 0; const char* cp = getenv("PS3_MIXPLUG_CAPTURE"); if (cp && !dn && p == 0x34A58u) { FILE* df = fopen(cp, "wb"); if (df) { fwrite(ctx->ls + 0x30780, 1, 0x7E80, df); fclose(df); dn = 1; fprintf(stderr, "[mixplug] captured mixer code\n"); } } } /* MIXPLUG_CAPTURE */'
    [IO.File]::WriteAllText($f, $rx.Replace($t, ('$1' + $ins + '$1spu_interp_run(ctx, p);$2return;')))
    Write-Host 'added the capture hook; rebuilding first' -ForegroundColor Green
    & "$PSScriptRoot\04_build.ps1" -Jobs $Jobs
    if ($LASTEXITCODE) { Bail 'build failed' }
}

# 1) capture: run the game with the new code switched off so the slow path runs and the hook fires
$dir = Join-Path $Root 'spu\mixplug'
New-Item -ItemType Directory -Force $dir | Out-Null
$cap = Join-Path $dir 'plugin.cap'
Remove-Item $cap -ErrorAction SilentlyContinue
if (-not (Test-Path (Join-Path $Root 'devflash.txt'))) { Bail 'devflash.txt is missing (the firmware folder has not been set yet).' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
$env:MIXPLUG_OFF='1'; $env:PS3_MIXPLUG_CAPTURE=$cap
Write-Host 'Starting the game once, in the background, to read its sound engine (a game window opens for a moment; do not close it)...'
$p = Start-Process -FilePath (Join-Path $Root 'build\JetpackJoyride.exe') -ArgumentList 'game\EBOOT.ELF' -WorkingDirectory $Root -PassThru `
        -RedirectStandardOutput (Join-Path $Root 'capture.out.log') -RedirectStandardError (Join-Path $Root 'capture.log')
$ok = $false
for ($i = 0; $i -lt 180; $i++) {
    Start-Sleep -Seconds 1
    if ((Test-Path $cap) -and ((Get-Item $cap).Length -eq 0x7E80)) { $ok = $true; break }
    if ($p.HasExited) { break }
}
Start-Sleep -Seconds 1
if (-not $p.HasExited) { try { Stop-Process -Id $p.Id -Force } catch {} }
Remove-Item Env:MIXPLUG_OFF, Env:PS3_MIXPLUG_CAPTURE -ErrorAction SilentlyContinue
if (-not $ok) { Bail 'the game did not reach its sound engine within 3 minutes (see capture.log).' }

# 2) make sure it is the code this fix was written for
$plug = [IO.File]::ReadAllBytes($cap)
function Hex($b, $o, $n) { ($b[$o..($o + $n - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join '' }
if ((Hex $plug 0 16) -ne '42F21A0243D36E8242B1850243E9B182' -or (Hex $plug 0x42D8 8) -ne '40840C1024FA00FE') {
    Bail 'this game version has a different sound engine than the one this fix was written for.'
}
Move-Item $cap (Join-Path $dir 'plugin.bin') -Force
$sig = ($plug[0..15] | ForEach-Object { '0x{0:X2}' -f $_ }) -join ','

# 3) compile it to native code
& python "$tools\spu_lifter.py" (Join-Path $dir 'plugin.bin') --base 0x30780 --length 0x5448 --code-end 0x35BC4 `
    --extra-funcs 0x30790,0x30A70,0x30D48,0x310B0,0x34888,0x34A58,0x35844,0x35A18,0x35BBC `
    --return-entries --merge-chunks --symbol-prefix mixplug_ -o $dir
if ($LASTEXITCODE) { Bail 'spu_lifter failed' }
$reg = @"

/* Registers the lifted mixer code under image id 90; it becomes active when the game streams that code into local store. */
extern void spu_begin_image(int image_id);
extern void spu_overlay_register_sig(const uint8_t sig[16], int image_id);
__attribute__((constructor)) static void mixplug_ctor(void)
{
    static const uint8_t sig[16] = { $sig };
    if (getenv("MIXPLUG_OFF")) return;
    spu_begin_image(90); mixplug_spu_recomp_register(); spu_begin_image(0);
    spu_overlay_register_sig(sig, 90);
}
"@
$c = Join-Path $dir 'spu_recomp.c'
$txt = [IO.File]::ReadAllText($c)
if ($txt -notmatch '#include <stdlib.h>') { $txt = "#include <stdlib.h>`n#include <stdint.h>`n" + $txt }
[IO.File]::WriteAllText($c, $txt + $reg)

# 4) rebuild (only this file and the final link are new)
& "$PSScriptRoot\04_build.ps1" -Jobs $Jobs
if ($LASTEXITCODE) { Bail 'the rebuild with the sound fix failed (send build.log).' }
Write-Host 'Sound fix installed.' -ForegroundColor Green
