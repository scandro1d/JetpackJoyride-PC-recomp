# Runs the recompiled game and saves the console output to run.log (send me this file).
param([string]$DevFlash = '', [switch]$Diag, [switch]$DmaLax)   # path to a PS3 dev_flash folder, if the game asks for firmware files
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$exe = 'build\JetpackJoyride.exe'
if (-not (Test-Path $exe)) { throw 'Build first: .\04_build.ps1' }
$env:PS3_VFS_ROOT  = "$Root\vfs\bdvd"
$env:PS3_HDD0_ROOT = "$Root\vfs\hdd0"
$env:PS3_HDD1_ROOT = "$Root\vfs\hdd1"
# Remember the firmware folder so it only has to be given once
if ($DevFlash) { Set-Content -Path "$Root\devflash.txt" -Value $DevFlash }
elseif (Test-Path "$Root\devflash.txt") { $DevFlash = (Get-Content "$Root\devflash.txt" -Raw).Trim() }
if (-not $DevFlash) { throw "No dev_flash folder given. Run:  .\05_run.ps1 -DevFlash 'C:\path\to\rpcs3\dev_flash'" }
$pic = Join-Path $DevFlash 'sys\external\flashATRAC.pic'
if (-not (Test-Path $pic)) { throw "flashATRAC.pic not found at: $pic`nThe -DevFlash folder must be the one that CONTAINS the 'sys' folder (RPCS3's dev_flash)." }
$env:PS3_DEV_FLASH = $DevFlash
Write-Host "dev_flash: $DevFlash   (flashATRAC.pic found)" -ForegroundColor Green
# The MultiStream mixer loads flashATRAC.pic into SPU memory at run time. That code can't be lifted
# ahead of time, so let the runtime interpret it instead of ending the SPU job.
$env:SPU_INTERP_UNLIFTED = '1'
if ($Diag) {
    $env:PS3_STDIO_UNBUFFERED = '1'   # log lines appear in true order
    $env:PS3_HLE_TRACE = '4000'       # log the first 4000 system calls (names added afterwards)
    $env:PS3_HLE_TOP   = '5'          # every 5 s: which calls each thread makes most
    $env:PS3_WAITBT    = '1'          # where each blocked thread is parked (guest stack)
    Write-Host 'Diagnostics ON' -ForegroundColor Yellow
}
if ($DmaLax) { $env:SPU_DMA_LAX = '1'; Write-Host 'SPU_DMA_LAX=1 (accept zero-size SPU transfers)' -ForegroundColor Yellow }
# cmd merges stderr into stdout so PowerShell never sees an 'error' record (which would abort the run)
$ErrorActionPreference = 'Continue'
cmd /c "`"$exe`" game\EBOOT.ELF 2>&1" | Tee-Object run.log
if ($Diag -and (Test-Path "$Root\jj_imports.json")) {
    # Replace NID numbers in [HLETRACE] lines with function names
    $map = @{}
    $j = Get-Content "$Root\jj_imports.json" -Raw | ConvertFrom-Json
    foreach ($lib in $j.PSObject.Properties) { foreach ($f in $lib.Value) { if ($f.name) { $map[[Convert]::ToUInt32($f.nid,16)] = "$($lib.Name)::$($f.name)" } } }
    Get-Content run.log | ForEach-Object {
        if ($_ -match '^\[HLETRACE\] nid=0x([0-9A-Fa-f]{8})') { $n = [Convert]::ToUInt32($Matches[1],16); if ($map.ContainsKey($n)) { $_ -replace 'nid=0x[0-9A-Fa-f]{8}', ("nid=" + $map[$n]) } else { $_ } } else { $_ }
    } | Set-Content run_named.log
    Write-Host 'Wrote run_named.log (system calls with names)' -ForegroundColor Green
}
Select-String -Path run.log -NotMatch -Pattern '^\[WAIT\]|^\[evt\] q=1 receive|write_spu_mb|^\[HLETRACE\]' | ForEach-Object { $_.Line } | Set-Content run_short.log
Write-Host "`nExit code: $LASTEXITCODE   (full log: run.log, without the heartbeat spam: run_short.log)"

