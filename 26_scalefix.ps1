# Fix for the 2x/4K freeze: my scale helper turned a position of 0 into 1 (it never returned 0), so the game's tiled
# copies of its 1728x972 gameplay surface landed at (1,1) and ran 1 pixel past the edge -> D3D12 rejected the command list.
# One-line fix in rsx_live_draw.c, then rebuild and launch.
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f1 = Join-Path $Root 'ps3recomp\libs\video\rsx_live_draw.c'
$t = [IO.File]::ReadAllText($f1)
$old = 'return r ? r : 1u;'
if ($t.Contains('SCALEFIX_PATCH')) { Write-Host 'already patched' }
else {
  if (([regex]::Matches($t, [regex]::Escape($old))).Count -ne 1) { throw 'ld_sc line not found exactly once (run 24_renderres.ps1 first)' }
  $t = $t.Replace($old, 'return (v && !r) ? 1u : r; /* SCALEFIX_PATCH: 0 stays 0 (positions); sizes never collapse to 0 */')
  [IO.File]::WriteAllText($f1, $t); Write-Host 'patched rsx_live_draw.c' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
& "$PSScriptRoot\play.ps1"
