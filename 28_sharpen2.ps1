# Stronger, resolution-aware sharpening (the first version was too subtle to see).
# Now an unsharp-mask: the neighbour distance scales with the render resolution, strength is 0..300% of the detail,
# and the result is clamped near the local min/max so edges get crisp without big halos. Needs 27_sharpen.ps1 applied first.
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f1 = Join-Path $Root 'ps3recomp\libs\video\rsx_live_draw.c'
$t = [IO.File]::ReadAllText($f1)
if ($t -notmatch 'SHARPEN_PATCH') { throw 'run 27_sharpen.ps1 first' }
if ($t -match 'SHARPEN2_PATCH') { Write-Host 'already patched' }
else {
  $new = @'
        "cbuffer C : register(b0) { float4 k; };\n"
        "Texture2D t0 : register(t0);\n"
        "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
        "    float2 q = float2((id << 1) & 2, id & 2);\n"
        "    return float4(q * float2(2, -2) + float2(-1, 1), 0, 1); }\n"
        "float4 ps(float4 p : SV_Position) : SV_Target {\n"
        "    uint w, h; t0.GetDimensions(w, h);\n"
        "    int2 c = int2(p.xy); int2 lim = int2(w - 1, h - 1); int r = max(1, (int)(k.y + 0.5));\n"
        "    float4 m = t0.Load(int3(c, 0));\n"
        "    float3 a = t0.Load(int3(clamp(c + int2(0, -r), int2(0, 0), lim), 0)).rgb;\n"
        "    float3 b = t0.Load(int3(clamp(c + int2(-r, 0), int2(0, 0), lim), 0)).rgb;\n"
        "    float3 d = t0.Load(int3(clamp(c + int2(r, 0), int2(0, 0), lim), 0)).rgb;\n"
        "    float3 e = t0.Load(int3(clamp(c + int2(0, r), int2(0, 0), lim), 0)).rgb;\n"
        "    float3 mn = min(min(min(a, b), min(d, e)), m.rgb);\n"
        "    float3 mx = max(max(max(a, b), max(d, e)), m.rgb);\n"
        "    float3 blur = (a + b + d + e) * 0.25;\n"
        "    float3 o = m.rgb + (m.rgb - blur) * (k.x * 3.0);\n"
        "    o = clamp(o, mn - 0.06, mx + 0.06);\n"
        "    return float4(saturate(o), m.a); }\n";
'@
  $s = $t.IndexOf('"cbuffer C : register(b0) { float4 k; };\n"')
  $endMark = 'return float4(o, m.a); }\n";'
  $e = $t.IndexOf($endMark)
  if ($s -lt 0 -or $e -lt $s) { throw 'old sharpen shader not found' }
  $t = $t.Substring(0, $s) + '/* SHARPEN2_PATCH */' + "`n" + $new.TrimStart() + $t.Substring($e + $endMark.Length)
  $oldK = 'const float k[4] = { (float)sv / 100.0f, 0.0f, 0.0f, 0.0f };'
  if (([regex]::Matches($t, [regex]::Escape($oldK))).Count -ne 1) { throw 'k constants line not found' }
  $t = $t.Replace($oldK, 'const float k[4] = { (float)sv / 100.0f, ld_render_scale(), 0.0f, 0.0f };')
  [IO.File]::WriteAllText($f1, $t)
  Write-Host 'patched sharpen shader' -ForegroundColor Green
}
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
& "$PSScriptRoot\play.ps1"
