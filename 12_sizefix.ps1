# 1) Picture crop: the game renders 1920x1080 but the engine's swapchain was created 1280x720 and the frame was
#    copied 1:1 (so only the top-left corner showed). Create the swapchain at 1920x1080; Windows scales it to the window.
# 2) Sound stops after the title: raises the SPU recursion guard (default 2000) and logs whether it / a fault is the cause.
# Output: sz.log / sz_short.log (+ sz_audio.txt with the lines I need)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'main.cpp'
$t = [IO.File]::ReadAllText($f)
$old = 'rsx_live_draw_init(rsx_null_backend_get_hwnd(), WINDOW_WIDTH, WINDOW_HEIGHT,'
if ($t.Contains($old)) {
  $t = $t.Replace($old, 'rsx_live_draw_init(rsx_null_backend_get_hwnd(), 1920, 1080, /* SIZEFIX_PATCH */')
  [IO.File]::WriteAllText($f, $t)
  Write-Host 'patched main.cpp' -ForegroundColor Green
} elseif ($t -notmatch 'SIZEFIX_PATCH') { throw 'rsx_live_draw_init call not found in main.cpp' }

& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
$env:PS3_VFS_ROOT="$Root\vfs\bdvd"; $env:PS3_HDD0_ROOT="$Root\vfs\hdd0"; $env:PS3_HDD1_ROOT="$Root\vfs\hdd1"
$env:PS3_DEV_FLASH = (Get-Content "$Root\devflash.txt" -Raw).Trim()
$env:SPU_INTERP_UNLIFTED='1'; $env:SPU_DMA_LAX='1'; $env:RSX_LIVE_DRAW='1'
$env:SPU_HOST_DEPTH_MAX='20000'
$ErrorActionPreference='Continue'
cmd /c "`"build\JetpackJoyride.exe`" game\EBOOT.ELF 2>&1" | Tee-Object sz.log
Select-String sz.log -NotMatch -Pattern '^\[WAIT\]|^\[evt\] q=1 receive|write_spu_mb|^\[HLETRACE\]|^\[RSX null\]' | ForEach-Object { $_.Line } | Select-Object -Last 100 | Set-Content sz_short.log
Select-String sz.log -Pattern 'spu-depth|FAULT|fault|halt|d3d-fail|REJECTED|crash|exception' | Select-Object -First 40 | ForEach-Object { $_.Line } | Set-Content sz_audio.txt
Write-Host 'Wrote sz_short.log and sz_audio.txt' -ForegroundColor Green
