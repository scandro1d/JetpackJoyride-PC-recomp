# Configure and build. First build is slow (tens of minutes to a few hours, ~3.2 M lines of C++).
# -Jobs = parallel compiler processes; each can use 2-4 GB RAM. 16 GB RAM -> 4 ; 32 GB -> 8.
param([int]$Jobs = 4, [ValidateSet('Release','RelWithDebInfo','Debug')][string]$Config = 'Release')
. "$PSScriptRoot\env.ps1"
Import-VsEnv
Set-Location $Root
Require cmake 'Run 00_check_tools.ps1'; Require ninja 'Run 00_check_tools.ps1'; Require clang-cl 'Install "C++ Clang tools for Windows"'
if (-not (Test-Path recompiled\ppu_recomp.h)) { throw 'Run 03_lift.ps1 first.' }

if (Test-Path build\CMakeCache.txt) { if (Select-String -Path build\CMakeCache.txt -Pattern 'CMAKE_BUILD_TYPE:STRING=\$' -Quiet) { Remove-Item build -Recurse -Force } }
cmake -S . -B build -G Ninja "-DCMAKE_BUILD_TYPE=$Config" `
    "-DCMAKE_C_COMPILER=clang-cl" "-DCMAKE_CXX_COMPILER=clang-cl" `
    "-DPS3RECOMP_DIR=$Root\ps3recomp" "-DRECOMP_DIR=$Root\recompiled" "-DSPU_DIR=$Root\spu" 2>&1 | Tee-Object configure.log
if ($LASTEXITCODE) { throw 'CMake configure failed - send me configure.log' }

cmake --build build -j $Jobs 2>&1 | Tee-Object build.log
if ($LASTEXITCODE) { throw 'Build failed - send me build.log (the FIRST error is what matters)' }
Write-Host "`nBuilt: build\JetpackJoyride.exe" -ForegroundColor Green
Write-Host 'Next: .\05_run.ps1'
