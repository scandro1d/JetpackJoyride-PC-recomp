# Does Windows show your controller as an Xbox-style (XInput) pad? This game only reads XInput pads.
# Run it, then press buttons / move sticks on the controller for ~10 seconds. Output: padcheck.txt (send it to me).
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$out = Join-Path $Root 'padcheck.txt'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class XiProbe {
  [StructLayout(LayoutKind.Sequential)] public struct ST { public uint pk; public ushort btn; public byte lt, rt; public short lx, ly, rx, ry; }
  [DllImport("XInput1_4.dll", EntryPoint="XInputGetState")] public static extern uint Get(uint i, ref ST s);
}
'@
$lines = @()
$lines += "== XInput slots (0 = Xbox-style pad found) =="
$seen = @{}
$end = (Get-Date).AddSeconds(10)
Write-Host 'Press buttons and move the sticks on the controller for 10 seconds...' -ForegroundColor Yellow
while ((Get-Date) -lt $end) {
  for ($i = 0; $i -lt 4; $i++) {
    $s = New-Object XiProbe+ST
    $r = [XiProbe]::Get($i, [ref]$s)
    if ($r -eq 0) { $seen[$i] = $true; if ($s.btn -ne 0 -or [math]::Abs($s.lx) -gt 8000 -or [math]::Abs($s.ly) -gt 8000) { $k = "slot $i buttons=0x{0:X4} lx=$($s.lx) ly=$($s.ly)" -f $s.btn; if ($lines[-1] -ne $k) { $lines += $k } } }
  }
  Start-Sleep -Milliseconds 50
}
for ($i = 0; $i -lt 4; $i++) { $lines += ("slot {0}: {1}" -f $i, $(if ($seen[$i]) { 'CONNECTED (XInput)' } else { 'nothing' })) }
$lines += ''
$lines += '== Game controllers / HID devices Windows can see =='
$lines += (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'controller|gamepad|xbox|dualshock|dualsense|wireless|joystick|pro controller|8bitdo|logitech' } | ForEach-Object { "$($_.Status)  $($_.Class)  $($_.FriendlyName)" })
$lines += ''
$lines += '== cellPad lines in play.log =='
if (Test-Path (Join-Path $Root 'play.log')) { $lines += (Select-String -Path (Join-Path $Root 'play.log') -Pattern 'cellPad\] (XInput|keyboard|GetData|pad)' | Select-Object -First 8 | ForEach-Object { $_.Line }) }
$lines | Set-Content $out
$lines | ForEach-Object { Write-Host $_ }
Write-Host "`nWrote $out" -ForegroundColor Green
