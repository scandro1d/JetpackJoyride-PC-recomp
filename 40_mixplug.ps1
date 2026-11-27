# Fixes the coin sound glitches: compiles the sound engine's runtime-loaded mixer code (the part that was running in the slow
# interpreter) to native code, like the rest of the game's SPU code. Needs ls_dump_34A58.bin from step 38 (in this folder).
# Then rebuilds and runs the game with the interpreter statistics + audio report so we can see it worked (no more interpreted calls).
# Set env MIXPLUG_OFF=1 before starting the game to switch the new code off (for A/B comparison).
param([switch]$NoRun)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$tools = Join-Path $Root 'ps3recomp\tools'
$dump = Join-Path $Root 'ls_dump_34A58.bin'
if (-not (Test-Path $dump)) { throw 'ls_dump_34A58.bin not found in this folder (run 38_lsdump.ps1 first).' }
$base = 0x30780; $len = 0x7E80
$all = [IO.File]::ReadAllBytes($dump)
$plug = New-Object byte[] $len
[Array]::Copy($all, $base, $plug, 0, $len)
New-Item -ItemType Directory -Force spu\mixplug | Out-Null
[IO.File]::WriteAllBytes((Join-Path $Root 'spu\mixplug\plugin.bin'), $plug)
$sig = ($plug[0..15] | ForEach-Object { '0x{0:X2}' -f $_ }) -join ','

& python "$tools\spu_lifter.py" spu\mixplug\plugin.bin --base 0x30780 --length 0x5448 --code-end 0x35BC4 `
    --extra-funcs 0x30790,0x30A70,0x30D48,0x310B0,0x34888,0x34A58,0x35844,0x35A18,0x35BBC `
    --return-entries --merge-chunks --symbol-prefix mixplug_ -o spu\mixplug
if ($LASTEXITCODE) { throw 'spu_lifter failed' }

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
$c = Join-Path $Root 'spu\mixplug\spu_recomp.c'
$txt = [IO.File]::ReadAllText($c)
if ($txt -notmatch '#include <stdlib.h>') { $txt = "#include <stdlib.h>`n#include <stdint.h>`n" + $txt }
[IO.File]::WriteAllText($c, $txt + $reg)
Write-Host 'lifted mixer code written to spu\mixplug' -ForegroundColor Green

& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
if ($NoRun) { return }

$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
$env:AUDIO_RATE='1'; $env:SPU_INTERP_STATS='2'
Write-Host "Play now: normal for ~10 s, then collect lots of coins for ~20 s. Listen for glitches. Close the game when done." -ForegroundColor Yellow
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF > au_rate.log 2>&1"
$lines = Select-String -Path au_rate.log -Pattern '^\[audio-rate\]|^\[spu-interp\]|^  top |^    img=|interpreting unlifted|SPU.*FAULT' | ForEach-Object { $_.Line }
$lines | Select-Object -First 600 | Set-Content audio_rate.txt
Write-Host "Wrote audio_rate.txt - tell me whether the coin sounds still glitch, and send the file" -ForegroundColor Green
