# Dot-sourced by the other scripts. Loads the Visual Studio x64 build environment
# (cl, link, clang-cl, cmake, ninja) into the current PowerShell session.
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-VsPath {
    # Collect every Visual Studio install, then prefer one that has clang-cl (required by the build).
    $cands = @()
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) { $cands += @(& $vswhere -all -products * -property installationPath) }
    foreach ($root in "${env:ProgramFiles(x86)}\Microsoft Visual Studio", "${env:ProgramFiles}\Microsoft Visual Studio") {
        if (Test-Path $root) {
            foreach ($ver in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
                foreach ($ed in Get-ChildItem $ver.FullName -Directory -ErrorAction SilentlyContinue) { $cands += $ed.FullName }
            }
        }
    }
    $cands = $cands | Where-Object { $_ -and (Test-Path (Join-Path $_ 'VC\Auxiliary\Build\vcvars64.bat')) } | Select-Object -Unique
    foreach ($c in $cands) { if (Test-Path (Join-Path $c 'VC\Tools\Llvm\x64\bin\clang-cl.exe')) { return $c } }
    if ($cands) { return ($cands | Select-Object -First 1) }
    return $null
}

function Import-VsEnv {
    if ($env:JJ_VSENV_LOADED -eq '1') { return }
    $vs = Find-VsPath
    if (-not $vs) { throw "Visual Studio not found. Install 'Build Tools for Visual Studio 2022' (see SETUP.md step 1)." }
    $bat = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path $bat)) { throw "vcvars64.bat missing in $vs - install the 'Desktop development with C++' workload." }

    # Run vcvars64 in cmd, capture the resulting environment, copy it into this session.
    # (SetEnvironmentVariable is used because names like 'ProgramFiles(x86)' break Set-Item env:)
    $lines = cmd /c "`"$bat`" >nul 2>&1 && set"
    foreach ($l in $lines) {
        $i = $l.IndexOf('=')
        if ($i -gt 0) {
            try { [Environment]::SetEnvironmentVariable($l.Substring(0,$i), $l.Substring($i+1), 'Process') } catch {}
        }
    }
    # Tools VS ships in these folders when the matching components are installed
    foreach ($p in "$vs\VC\Tools\Llvm\x64\bin",
                   "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin",
                   "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja") {
        if (Test-Path $p) { $env:PATH = "$p;$env:PATH" }
    }
    $env:JJ_VSENV_LOADED = '1'
}

function Require($cmd, $hint) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "'$cmd' not found. $hint" }
}
