# Downloads ps3recomp at the exact commit this project was tested against, applies our patch,
# installs the Python dependencies and creates the project files from the toolkit's template.
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$commit = 'de4f090328ea08bef6b2f15caec0b85e343a7ece'
Require git 'Install Git for Windows'
Require python 'Install Python 3.10+'

if (-not (Test-Path 'ps3recomp\.git')) { git clone https://github.com/sp00nznet/ps3recomp.git ps3recomp }
git -C ps3recomp fetch --all --quiet
git -C ps3recomp checkout --quiet $commit
if ($LASTEXITCODE) { throw "Could not check out $commit" }

# Patch: --code-end option for the SPU lifter (needed for the MultiStream mixer program)
$patch = Join-Path $Root 'patches\0001-spu-code-end.patch'
git -C ps3recomp apply --check $patch 2>$null
if ($LASTEXITCODE -eq 0) { git -C ps3recomp apply $patch; Write-Host 'Applied 0001-spu-code-end.patch' }
else { Write-Host 'Patch already applied (or toolkit changed) - continuing' -ForegroundColor Yellow }

python -m pip install --upgrade pip | Out-Null
python -m pip install -r ps3recomp\tools\requirements.txt
if ($LASTEXITCODE) { throw 'pip install failed' }

# Project files from the template (never overwrites your edits)
foreach ($f in 'CMakeLists.txt','main.cpp','stubs.cpp','config.toml') {
    if (-not (Test-Path $f)) {
        $c = Get-Content "ps3recomp\templates\project\$f" -Raw
        $c = $c -replace 'MyGameRecomp','JetpackJoyride'
        Set-Content -Path $f -Value $c -NoNewline
        Write-Host "Created $f"
    }
}
Write-Host "`nDone. Next: .\02_prepare_game.ps1 -Dump <path to NPUB31615> -Decrypted <path to decrypted folder>" -ForegroundColor Green
