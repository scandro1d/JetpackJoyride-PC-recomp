# Usage: .\42_findplug2.ps1 -Dir 'C:\path\to\decrypted\NPUB31615\USRDIR'   (the folder with the DECRYPTED jet.pak / sound.pak)
# Searches every game file for pieces of the mixer code (32-byte samples from several places), to see where it is stored.
param([string[]]$Dir = @())
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$py = @'
import sys, os
plug = open(sys.argv[1], "rb").read()
probes = [(o, plug[o:o+32]) for o in (0x0, 0x40, 0x400, 0x1000, 0x2000, 0x3000, 0x4000, 0x4800, 0x5000) if any(plug[o:o+32])]
roots = sys.argv[2:]
files = []
for r in roots:
    if os.path.isfile(r): files.append(r)
    else:
        for d, _, fs in os.walk(r):
            for f in fs: files.append(os.path.join(d, f))
for name in files:
    try: data = open(name, "rb").read()
    except Exception: continue
    hits = [(hex(o), hex(data.find(p))) for o, p in probes if data.find(p) >= 0]
    print("%-70s %10d bytes  %s" % (name[-70:], len(data), ("HITS(plugin off, file off): %s" % hits) if hits else "no match"))
'@
Set-Content -Path "$env:TEMP\findplug2.py" -Value $py -Encoding ASCII
$roots = (@('game') + $Dir) | Where-Object { Test-Path $_ } | Select-Object -Unique
$extra = @(); if (Test-Path 'devflash.txt') { }
& python "$env:TEMP\findplug2.py" spu\mixplug\plugin.bin @roots | Tee-Object findplug2.txt
Write-Host 'Wrote findplug2.txt - send it to me.' -ForegroundColor Green
