# Lays out the game files the way the recompiled runtime expects them.
#   -Dump       the original extracted folder  (contains PARAM.SFO, USRDIR\movies\...)
#   -Decrypted  folder holding EBOOT.elf, jet.pak, sound.pak  (the DECRYPTED versions)
param(
    [Parameter(Mandatory)][string]$Dump,
    [string]$Decrypted = (Join-Path $PSScriptRoot 'decrypted')
)
. "$PSScriptRoot\env.ps1"
Set-Location $Root
function Need($p) { if (-not (Test-Path $p)) { throw "Missing: $p" } }
Need "$Decrypted\EBOOT.elf"; Need "$Decrypted\jet.pak"; Need "$Decrypted\sound.pak"
Need "$Dump\PARAM.SFO";     Need "$Dump\USRDIR\movies\BS_ShirtSleeves_Final.avi"

function Magic($p) { $b = [IO.File]::OpenRead($p); try { $x = New-Object byte[] 4; [void]$b.Read($x,0,4); ,$x } finally { $b.Close() } }
$m = Magic "$Decrypted\EBOOT.elf"
if ([Text.Encoding]::ASCII.GetString($m,1,3) -ne 'ELF') { throw 'EBOOT.elf is not a plain ELF (still encrypted?)' }
foreach ($f in 'jet.pak','sound.pak') {
    if ([Text.Encoding]::ASCII.GetString((Magic "$Decrypted\$f")) -eq "NPD`0") { throw "$f is still encrypted (starts with NPD)" }
}

New-Item -ItemType Directory -Force game | Out-Null
Copy-Item "$Decrypted\EBOOT.elf" game\EBOOT.ELF -Force

$usr = 'vfs\hdd0\game\NPUB31615\USRDIR'
New-Item -ItemType Directory -Force "$usr\movies","vfs\hdd1","vfs\bdvd" | Out-Null
# The game opens "jet.pak.edat"/"sound.pak.edat". We hand it the already-decrypted bytes under those
# names; the runtime only decrypts files that start with the NPD magic, so plain files pass through.
Copy-Item "$Decrypted\jet.pak"   "$usr\jet.pak.edat"   -Force
Copy-Item "$Decrypted\sound.pak" "$usr\sound.pak.edat" -Force
Copy-Item "$Dump\USRDIR\movies\BS_ShirtSleeves_Final.avi" "$usr\movies\" -Force
Copy-Item "$Dump\PARAM.SFO" 'vfs\hdd0\game\NPUB31615\' -Force
foreach ($x in 'ICON0.PNG','PS3LOGO.DAT') { if (Test-Path "$Dump\$x") { Copy-Item "$Dump\$x" 'vfs\hdd0\game\NPUB31615\' -Force } }
if (Test-Path "$Dump\TROPDIR") { Copy-Item "$Dump\TROPDIR" 'vfs\hdd0\game\NPUB31615\' -Recurse -Force }
Write-Host "Game files staged under $Root\vfs and $Root\game" -ForegroundColor Green
Write-Host "Next: .\03_lift.ps1"
