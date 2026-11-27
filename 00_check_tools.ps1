# Checks that everything needed is installed. Changes nothing.
. "$PSScriptRoot\env.ps1"
$ok = $true
function Check($name, $found, $hint) {
    if ($found) { Write-Host ("  [ OK ] {0}" -f $name) -ForegroundColor Green }
    else { Write-Host ("  [MISS] {0}  ->  {1}" -f $name, $hint) -ForegroundColor Red; $script:ok = $false }
}
try { Import-VsEnv; Write-Host "        Visual Studio: $(Find-VsPath)" } catch { Write-Host "  [MISS] Visual Studio: $($_.Exception.Message)" -ForegroundColor Red; $ok = $false }

Check 'git'      (Get-Command git -EA 0)       'https://git-scm.com/download/win'
$py = Get-Command python -EA 0
$pyok = $false
if ($py) { $v = & python -c "import sys;print('%d.%d'%sys.version_info[:2])"; $pyok = ([version]$v -ge [version]'3.10'); Write-Host "        python $v" }
Check 'Python 3.10+' $pyok 'https://www.python.org/downloads/windows/  (tick "Add python.exe to PATH")'
Check 'cmake 3.20+' (Get-Command cmake -EA 0)  'VS Installer > "C++ CMake tools for Windows", or https://cmake.org/download/'
Check 'ninja'       (Get-Command ninja -EA 0)  'VS Installer > "C++ CMake tools for Windows", or https://github.com/ninja-build/ninja/releases'
Check 'clang-cl'    (Get-Command clang-cl -EA 0) 'VS Installer > "C++ Clang tools for Windows", or https://github.com/llvm/llvm-project/releases'
Check 'MSVC cl.exe' (Get-Command cl -EA 0)     'VS Installer > "Desktop development with C++"'
Check 'Windows SDK' ($env:WindowsSdkDir -and (Test-Path $env:WindowsSdkDir)) 'VS Installer > "Windows 11 SDK" (10.0.19041 or newer)'

$ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)
$col = if ($ram -ge 16) {'Green'} else {'Yellow'}
Write-Host ("  RAM: {0} GB  (16 GB minimum recommended; build with -Jobs 2 if you have less)" -f $ram) -ForegroundColor $col
$free = [math]::Round((Get-PSDrive -Name ((Get-Location).Drive.Name)).Free/1GB)
Write-Host "  Free disk on this drive: $free GB  (need about 15 GB)"
if ($ok) { Write-Host "`nAll required tools found. Next: .\01_get_toolkit.ps1" -ForegroundColor Green } else { Write-Host "`nInstall the missing items, open a NEW PowerShell window, and re-run this script." -ForegroundColor Yellow }
