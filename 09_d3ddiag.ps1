# Diagnostic for "[VP] PSO creation FAIL (0x887A0005)": logs the device-removed reason + D3D12 debug layer output.
# Output: d3d_short.log (send me this)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'ps3recomp\libs\video\rsx_d3d12_backend.c'
$t = [IO.File]::ReadAllText($f)
if ($t -notmatch 'REMOVEDRSN_PATCH') {
  $a = 'printf("[VP] PSO creation FAIL (0x%08lX)\n", hr);'
  if (-not $t.Contains($a)) { throw 'anchor not found in rsx_d3d12_backend.c' }
  $b = $a + ' /* REMOVEDRSN_PATCH */ printf("[VP] device removed reason: 0x%08lX\n", (unsigned long)s_d3d.device->lpVtbl->GetDeviceRemovedReason(s_d3d.device));'
  $t = $t.Replace($a, $b)
  [IO.File]::WriteAllText($f, $t)
  Write-Host 'patched rsx_d3d12_backend.c' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:D3D12_DBG='1'
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object d3d.log
Select-String d3d.log -Pattern 'D3D12\] (device|Debug|ERROR|adapter)|d3d12 backend|removed|D3D12 (ERROR|WARNING|CORRUPTION|MESSAGE)|\[VP\]|adapter|GPU' | Select-Object -First 60 | ForEach-Object { $_.Line } | Set-Content d3d_short.log
Write-Host 'Wrote d3d_short.log' -ForegroundColor Green
