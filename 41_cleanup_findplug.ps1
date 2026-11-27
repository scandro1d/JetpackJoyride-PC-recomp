# 1) Removes the temporary diagnostic changes (memory dump, DMA log) from ps3recomp\runtime\spu\spu_channels.c
# 2) Looks for the mixer code inside the game's own files, so the release builder can create it from each user's dump.
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f = Join-Path $Root 'ps3recomp\runtime\spu\spu_channels.c'
$t = [IO.File]::ReadAllText($f)
$n = 0
$rx1 = [regex]'\{ static int dn = 0; if \(dn < 2.*?/\* LSDUMP_PATCH \*/'
if ($rx1.IsMatch($t)) { $t = $rx1.Replace($t, ''); $n++ }
$rx2 = [regex]'\{ static int gn = 0; if \(lsa >= 0x30000u.*?/\* GETLOG_PATCH \*/'
if ($rx2.IsMatch($t)) { $t = $rx2.Replace($t, ''); $n++ }
if ($n) { [IO.File]::WriteAllText($f, $t); Write-Host "removed $n diagnostic change(s)" -ForegroundColor Green } else { Write-Host 'nothing to remove' }

$py = @'
import sys
plug = open(sys.argv[1], "rb").read()
for name in sys.argv[2:]:
    try: data = open(name, "rb").read()
    except Exception as e: print(name, "unreadable"); continue
    # whole 32384-byte image, then the first 4 KB, then the first 64 bytes
    for label, n in (("whole image", len(plug)), ("first 4 KB", 4096), ("first 64 bytes", 64)):
        i = data.find(plug[:n])
        if i >= 0: print("FOUND %s of mixer code in %s at file offset 0x%X" % (label, name, i)); break
    else: print("not found in", name)
'@
Set-Content -Path "$env:TEMP\findplug.py" -Value $py -Encoding ASCII
$files = @('game\EBOOT.ELF') + @(Get-ChildItem game -Recurse -File -Include *.pak,*.bin,*.self,*.prx -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
& python "$env:TEMP\findplug.py" spu\mixplug\plugin.bin @files | Tee-Object findplug.txt
Write-Host 'Wrote findplug.txt - send it to me. (Rebuild with 04_build.ps1 whenever convenient; the game itself is unchanged.)' -ForegroundColor Green
