# Adds the settings window (F1): master volume, windowed/fullscreen, 720p-4K output size, keyboard + controller remapping.
# Patches ps3recomp (cellAudio.c, cellPad.c) and your main.cpp, adds settings_menu.h, rebuilds, launches the game.
# Needs 10_livedraw.ps1 + 16_softclip.ps1 applied (they are). Settings are saved to settings.ini next to the exe.
# Afterwards just run .\play.ps1 to play.   Output: build output, play.log
. "$PSScriptRoot\env.ps1"
Set-Location $Root

# ---- 1. cellAudio.c: expose the master volume
$fa = Join-Path $Root 'ps3recomp\libs\audio\cellAudio.c'
$a = [IO.File]::ReadAllText($fa)
if ($a -notmatch 'SETTINGS_PATCH') {
  foreach ($need in @('SOFTCLIP_PATCH','static inline float ld_be_f32')) { if (-not $a.Contains($need)) { throw "cellAudio.c: '$need' not found (run 16_softclip.ps1 first)" } }
  $a = $a.Replace('static inline float ld_be_f32', "/* SETTINGS_PATCH: master volume set by the settings window (1.0 = default) */`nvolatile float g_ps3_master_vol = 1.0f;`nstatic inline float ld_be_f32")
  $o = 's_g = e ? (float)atof(e) : 1.0f; if (s_g < 0.0f) s_g = 1.0f;'
  if (-not $a.Contains($o)) { throw 'cellAudio.c: soft-clip gain line not found' }
  $a = $a.Replace($o, 's_g = e ? (float)atof(e) : 0.35f; if (s_g < 0.0f) s_g = 0.35f;')
  $o = 'float v = s_mix_buffer[i] * s_g;'
  if (-not $a.Contains($o)) { throw 'cellAudio.c: soft-clip multiply not found' }
  $a = $a.Replace($o, 'float v = s_mix_buffer[i] * s_g * g_ps3_master_vol;')
  [IO.File]::WriteAllText($fa, $a); Write-Host 'patched cellAudio.c' -ForegroundColor Green
}

# ---- 2. cellPad.c: table-driven keyboard + controller mapping
$fp = Join-Path $Root 'ps3recomp\libs\input\cellPad.c'
$p = [IO.File]::ReadAllText($fp)
if ($p -notmatch 'SETTINGS_PATCH') {
  $nl = if ($p.Contains("`r`n")) { "`r`n" } else { "`n" }
  $tables = @'
/* SETTINGS_PATCH: remappable bindings (edited by the settings window). Index = PS3 button:
 * 0 UP 1 DOWN 2 LEFT 3 RIGHT 4 CROSS 5 CIRCLE 6 SQUARE 7 TRIANGLE 8 L1 9 R1 10 L2 11 R2 12 START 13 SELECT 14 L3 15 R3 */
static const u16 g_pad_ps3_btn[16] = {
    CELL_PAD_CTRL_UP, CELL_PAD_CTRL_DOWN, CELL_PAD_CTRL_LEFT, CELL_PAD_CTRL_RIGHT,
    CELL_PAD_CTRL_CROSS, CELL_PAD_CTRL_CIRCLE, CELL_PAD_CTRL_SQUARE, CELL_PAD_CTRL_TRIANGLE,
    CELL_PAD_CTRL_L1, CELL_PAD_CTRL_R1, CELL_PAD_CTRL_L2, CELL_PAD_CTRL_R2,
    CELL_PAD_CTRL_START, CELL_PAD_CTRL_SELECT, CELL_PAD_CTRL_L3, CELL_PAD_CTRL_R3 };
int g_pad_kb_vk[16] = { PADKEY_UP, PADKEY_DOWN, PADKEY_LEFT, PADKEY_RIGHT, PADKEY_Z, PADKEY_X, PADKEY_A, PADKEY_S,
                        PADKEY_Q, PADKEY_W, PADKEY_1, PADKEY_2, PADKEY_RETURN, PADKEY_TAB, 0, 0 };
/* XInput wButtons mask per PS3 button; 0x10000 = left trigger, 0x20000 = right trigger */
unsigned g_pad_xi_mask[16] = { 0x0001, 0x0002, 0x0004, 0x0008, 0x1000, 0x2000, 0x4000, 0x8000,
                               0x0100, 0x0200, 0x10000, 0x20000, 0x0010, 0x0020, 0x0040, 0x0080 };

'@
  $tables = $tables.Replace("`r`n","`n").Replace("`n",$nl)
  $m = [regex]::Match($p, 'static void pad_poll_keyboard\(void\)\r?\n\{')
  if (-not $m.Success) { throw 'cellPad.c: pad_poll_keyboard not found' }
  $p = $p.Substring(0, $m.Index) + $tables + $p.Substring($m.Index)
  # keyboard: drop the fixed map, use the table
  $m1 = [regex]::Match($p, '    static const struct \{ int vk; u16 btn; \} map\[\] = \{.*?\r?\n    \};\r?\n', 'Singleline')
  $m2 = [regex]::Match($p, '    u16 btns = 0;\r?\n    for \(unsigned i = 0; i < sizeof map / sizeof map\[0\]; i\+\+\)\r?\n        if \(pad_key_down\(map\[i\]\.vk\)\) btns \|= map\[i\]\.btn;\r?\n')
  if (-not ($m1.Success -and $m2.Success)) { throw 'cellPad.c: keyboard map block not found' }
  $p = $p.Remove($m1.Index, $m1.Length)
  $m2 = [regex]::Match($p, '    u16 btns = 0;\r?\n    for \(unsigned i = 0; i < sizeof map / sizeof map\[0\]; i\+\+\)\r?\n        if \(pad_key_down\(map\[i\]\.vk\)\) btns \|= map\[i\]\.btn;\r?\n')
  $newk = "    u16 btns = 0;$nl    for (unsigned i = 0; i < 16; i++)$nl        if (g_pad_kb_vk[i] && pad_key_down(g_pad_kb_vk[i])) btns |= g_pad_ps3_btn[i];$nl"
  $p = $p.Remove($m2.Index, $m2.Length).Insert($m2.Index, $newk)
  # controller: drop the fixed mapping, use the table
  $m3 = [regex]::Match($p, '        u16 btns = 0;\r?\n        if \(gp->wButtons & XINPUT_GAMEPAD_BACK\).*?XINPUT_GAMEPAD_X\)\s+btns \|= CELL_PAD_CTRL_SQUARE;\r?\n', 'Singleline')
  if (-not $m3.Success) { throw 'cellPad.c: XInput mapping block not found' }
  $newx = "        u16 btns = 0;$nl        {$nl            unsigned xi = (unsigned)gp->wButtons;$nl            if (gp->bLeftTrigger > PAD_TRIGGER_THRESHOLD)  xi |= 0x10000u;$nl            if (gp->bRightTrigger > PAD_TRIGGER_THRESHOLD) xi |= 0x20000u;$nl            for (unsigned bi = 0; bi < 16; bi++)$nl                if (g_pad_xi_mask[bi] && (xi & g_pad_xi_mask[bi])) btns |= g_pad_ps3_btn[bi];$nl        }$nl"
  $p = $p.Remove($m3.Index, $m3.Length).Insert($m3.Index, $newx)
  [IO.File]::WriteAllText($fp, $p); Write-Host 'patched cellPad.c' -ForegroundColor Green
}

# ---- 3. project: settings_menu.h + main.cpp hooks
Copy-Item (Join-Path $PSScriptRoot 'patches\settings_menu.h') (Join-Path $Root 'settings_menu.h') -Force
$fm = Join-Path $Root 'main.cpp'
$t = [IO.File]::ReadAllText($fm)
if ($t -notmatch 'SETTINGS_PATCH') {
  if ($t -notmatch 'ARRAYELEM_PATCH|LIVEDRAW_PATCH') { throw 'main.cpp lacks the live-draw patch (run 10_livedraw.ps1)' }
  $i = $t.IndexOf('/* LIVEDRAW_PATCH:')
  if ($i -lt 0) { throw 'LIVEDRAW_PATCH marker not found in main.cpp' }
  $t = $t.Insert($i, '#include "settings_menu.h" /* SETTINGS_PATCH */' + [Environment]::NewLine)
  $old = '{ return s_rsx_live ? rsx_null_backend_pump_messages() : rsx_backend_pump(); }'
  if (-not $t.Contains($old)) { throw 'rsx_pump_messages body not found in main.cpp' }
  $t = $t.Replace($old, '{ static int sm_once = 0; if (s_rsx_live) { if (!sm_once) { sm_once = 1; sm::init(); } sm::pump(); }' + [Environment]::NewLine +
                          '  return s_rsx_live ? rsx_null_backend_pump_messages() : rsx_backend_pump(); }')
  [IO.File]::WriteAllText($fm, $t); Write-Host 'patched main.cpp' -ForegroundColor Green
}

& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed' }
Write-Host 'Build OK. Launching (F1 = settings, F11 = fullscreen)...' -ForegroundColor Green
& "$PSScriptRoot\play.ps1"
