# Stage 1-3: analyse the ELF, lift the PPU code to C++, lift the SPU (MultiStream) program.
# Takes ~1-3 minutes. Produces ~215 MB of generated C++ in .\recompiled (that is expected).
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$tools = Join-Path $Root 'ps3recomp\tools'
function Run { & python @args; if ($LASTEXITCODE) { throw "python $($args[0]) failed ($LASTEXITCODE)" } }
if (-not (Test-Path game\EBOOT.ELF)) { throw 'Run 02_prepare_game.ps1 first.' }

Write-Host '== 1/3 Loader (function table, imports, TOC) ==' -ForegroundColor Cyan
New-Item -ItemType Directory -Force analysis | Out-Null
Run "$tools\ppu_loader.py" game\EBOOT.ELF -o analysis\

Write-Host '== 2/3 PPU lift ==' -ForegroundColor Cyan
if (Test-Path recompiled) { Remove-Item recompiled -Recurse -Force }
New-Item -ItemType Directory -Force recompiled | Out-Null
# --chunk-lines 150000 keeps every generated .cpp small enough to compile in a few GB of RAM
Run "$tools\ppu_lifter.py" game\EBOOT.ELF --functions analysis\EBOOT.functions.json `
    --hle-stubs analysis\EBOOT.imports.json --output recompiled --chunk-lines 150000

Write-Host '== 3/3 SPU lift (MultiStream mixer) ==' -ForegroundColor Cyan
if (Test-Path spu) { Remove-Item spu -Recurse -Force }
Run "$tools\build_spu_workloads.py" --input game\EBOOT.ELF --lifted spu --out spu\spu_workloads.c `
    --constructor --code-end a0c20a60=0xDE10

$n = (Get-ChildItem recompiled -Filter 'ppu_recomp_*.cpp').Count
Write-Host "`nLift complete: $n PPU source files." -ForegroundColor Green
Write-Host 'Expected: 28705 functions lifted, 10518 call targets, SPU "1/1 candidates registered; complete=True".'
Write-Host 'Next: .\04_build.ps1'
