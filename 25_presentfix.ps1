# Freeze at 2x render scale: at ~frame 917 (gameplay start) a new 1728x972 surface appears and D3D12 rejects the command list.
# Suspect: the final "copy frame to the window" assumed equal sizes. This makes that copy size-safe and logs what it sees.
# Optional -DebugLayer turns on the D3D12 validation layer (needs Windows "Graphics Tools" optional feature) - it names the bad call.
# Output: p25.log, p25_sel.txt (send me p25_sel.txt)
param([switch]$DebugLayer)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f1 = Join-Path $Root 'ps3recomp\libs\video\rsx_live_draw.c'
$t = [IO.File]::ReadAllText($f1)
if ($t -notmatch 'PRESENTFIX_PATCH') {
  $old = 'g.list->lpVtbl->CopyResource(g.list, bb, srcimg);'
  if (([regex]::Matches($t, [regex]::Escape($old))).Count -ne 1) { throw 'present CopyResource anchor not found exactly once' }
  $new = @'
/* PRESENTFIX_PATCH: CopyResource needs identical sizes; copy the overlapping region otherwise. */
    {
        D3D12_RESOURCE_DESC _sd, _dd;
        srcimg->lpVtbl->GetDesc(srcimg, &_sd);
        bb->lpVtbl->GetDesc(bb, &_dd);
        if (_sd.Width == _dd.Width && _sd.Height == _dd.Height) {
            g.list->lpVtbl->CopyResource(g.list, bb, srcimg);
        } else {
            static int _pl = 0;
            if (_pl++ < 8)
                fprintf(stderr, "[present-size] surface %u is %ux%u (fmt %d) but the swap chain is %ux%u (fmt %d) - copying the overlap\n",
                        target, (unsigned)_sd.Width, (unsigned)_sd.Height, (int)_sd.Format,
                        (unsigned)_dd.Width, (unsigned)_dd.Height, (int)_dd.Format);
            D3D12_TEXTURE_COPY_LOCATION _dl = {0}, _sl = {0};
            _dl.pResource = bb;     _dl.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            _sl.pResource = srcimg; _sl.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            D3D12_BOX _bx = { 0, 0, 0, (UINT)(_sd.Width < _dd.Width ? _sd.Width : _dd.Width),
                              (UINT)(_sd.Height < _dd.Height ? _sd.Height : _dd.Height), 1 };
            g.list->lpVtbl->CopyTextureRegion(g.list, &_dl, 0, 0, 0, &_sl, &_bx);
        }
    }
'@
  $t = $t.Replace($old, $new)
  [IO.File]::WriteAllText($f1, $t); Write-Host 'patched rsx_live_draw.c' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_TAILRET='1'; $env:SPU_HOST_STACK_BIG='1'; $env:SPU_HOST_DEPTH_MAX='500000'
if ($DebugLayer) { $env:RSX_D3D_DEBUG='1' }
Write-Host 'Launching: get into a run (where it froze before), then close the game.' -ForegroundColor Yellow
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF > p25.log 2>&1"
Select-String p25.log -Pattern 'render-scale|present-size|d3d-fail|d3d-debug|D3D12 (ERROR|WARNING|CORRUPTION)|surfsz|dred\] (trigger|breadcrumbs)|zetatrack' | Select-Object -First 80 | ForEach-Object { $_.Line.Substring(0, [Math]::Min(300, $_.Line.Length)) } | Set-Content p25_sel.txt
Write-Host 'Wrote p25_sel.txt' -ForegroundColor Green
