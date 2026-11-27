# Explains why patches\ps3recomp-jj.patch does not apply. Run from the repo folder:  .\tools\Diagnose-Patch.ps1
# Writes patchdiag.txt (send it to the maintainer).
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$patch = Join-Path $repo 'patches\ps3recomp-jj.patch'
$ps3 = Join-Path $repo 'ps3recomp'
$o = New-Object System.Collections.Generic.List[string]
function Say($s) { $o.Add([string]$s); Write-Host $s }
Say "== environment =="
Say ("git: " + (git --version))
Say ("global core.autocrlf: " + (git config --global core.autocrlf))
Say "== patch file =="
if (-not (Test-Path $patch)) { Say 'patch missing'; $o | Set-Content (Join-Path $repo 'patchdiag.txt'); return }
$b = [IO.File]::ReadAllBytes($patch)
Say ("size: {0:N0} bytes   modified: {1}" -f $b.Length, (Get-Item $patch).LastWriteTime)
Say ("first bytes: " + (($b[0..11] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + "   (expected 64 69 66 66 20 2D 2D 67 = 'diff --g')")
Say ("CR bytes: " + ($b | Where-Object { $_ -eq 13 }).Count)
Say "files touched by the patch:"
(Select-String -Path $patch -Pattern '^diff --git ' | ForEach-Object { '  ' + $_.Line }) | ForEach-Object { Say $_ }
Say "== ps3recomp checkout =="
Say ("HEAD: " + (git -C $ps3 rev-parse HEAD))
Say ("expected: de4f090328ea08bef6b2f15caec0b85e343a7ece")
Say ("local core.autocrlf: " + (git -C $ps3 config core.autocrlf))
Say "git status (first 10 lines):"
(git -C $ps3 status --short | Select-Object -First 10) | ForEach-Object { Say "  $_" }
Say "== apply attempts =="
foreach ($opt in @(@(), @('--ignore-whitespace'), @('--ignore-whitespace','--3way'))) {
    Say ("-- git apply --check -v " + ($opt -join ' '))
    $r = & git -C $ps3 apply --check -v @opt $patch 2>&1
    Say ("   exit code " + $LASTEXITCODE)
    $r | Select-Object -First 12 | ForEach-Object { Say ("   " + $_) }
}
$o | Set-Content (Join-Path $repo 'patchdiag.txt')
Write-Host "`nWrote patchdiag.txt" -ForegroundColor Green
