# Settings window: (1) opens/closes with L3+R3 (click both sticks) instead of Back+Start, which paused the game;
# (2) always on top, so it no longer gets stuck behind the game when you switch windowed <-> fullscreen.
# Header-only change (settings_menu.h build 32); needs 31_menunav.ps1 applied. Rebuilds and launches.
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$hdr = @'
// settings_menu.h -- in-game settings window for the Jetpack Joyride recomp (included by main.cpp).
//   F1  : open / close the settings window        F11 : toggle fullscreen
// Settings are stored in settings.ini next to the exe.
#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <commctrl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(_MSC_VER) || defined(__clang__)
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#endif

extern "C" {
extern volatile int   g_ps3_pad_block;     // cellPad.c: 1 = the game sees no controller input (menu is using it)
extern volatile int   g_ps3_sharpen;       // rsx_live_draw.c: 0..100 sharpening strength applied when presenting
extern volatile float g_ps3_master_vol;   // cellAudio.c (1.0 = default loudness)
extern volatile float g_ps3_music_mult;   // spu_channels.c: multiplier applied to the music stream
extern volatile float g_ps3_sfx_gain;     // spu_channels.c: gain on the whole mix (effects = everything but music)
extern int      g_pad_kb_vk[16];          // cellPad.c: keyboard virtual-key per PS3 button (0 = unbound)
extern unsigned g_pad_xi_mask[16];        // cellPad.c: XInput button mask per PS3 button (0x10000 = LT, 0x20000 = RT)
void* rsx_null_backend_get_hwnd(void);
}

namespace sm {

// PS3 button order -- MUST match g_pad_ps3_btn[] in the cellPad.c patch.
static const char* const kBtnName[16] = {
    "D-Pad Up", "D-Pad Down", "D-Pad Left", "D-Pad Right",
    "Cross (X)", "Circle (O)", "Square", "Triangle",
    "L1", "R1", "L2", "R2", "Start", "Select", "L3", "R3" };
static const int kDefKb[16] = { VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT, 'Z', 'X', 'A', 'S',
                                'Q', 'W', '1', '2', VK_RETURN, VK_TAB, 0, 0 };
static const unsigned kDefXi[16] = { 0x0001, 0x0002, 0x0004, 0x0008, 0x1000, 0x2000, 0x4000, 0x8000,
                                     0x0100, 0x0200, 0x10000, 0x20000, 0x0010, 0x0020, 0x0040, 0x0080 };

struct Res { int w, h; const char* name; };
static const Res kRes[] = { {1280, 720, "1280 x 720  (720p)"}, {1600, 900, "1600 x 900"},
                            {1920, 1080, "1920 x 1080  (1080p)"}, {2560, 1440, "2560 x 1440  (1440p)"},
                            {3840, 2160, "3840 x 2160  (4K)"} };
static const int kResCount = (int)(sizeof(kRes) / sizeof(kRes[0]));

static int  g_master = 100;        // 0..200 %
static int  g_music = 100, g_sfx = 100;   // 0..100 % (not wired to the audio engine yet)
static int  g_fullscreen = 0;
static int  g_res = 0;
static int  g_render = 2;         // render resolution index into kRes (restart needed); 2 = 1080p = native
static int  g_sharp = 35;         // 0..100 sharpening (live)
static int  g_render_boot = 2;    // render res the running game started with (to know when a restart is needed)
static int  g_crop = 1;           // fullscreen: crop the game's black screen-safe border so the picture fills the height
static volatile LONG g_apply_display = 1;
static volatile LONG g_menu_toggle = 0;
static HWND g_menu = NULL;
static int  g_fs_active = 0;

static void path_ini(char* out, size_t n)
{
    GetModuleFileNameA(NULL, out, (DWORD)n);
    char* s = strrchr(out, '\\');
    if (s) s[1] = 0; else out[0] = 0;
    strncat(out, "settings.ini", n - strlen(out) - 1);
}

static void push_audio()
{
    // Effects = the whole mix, music = one stream inside it. So: whole-mix gain = effects slider, and the music
    // stream is multiplied by music/effects to land on its own slider value. (Effects floor 5% so music can still be heard.)
    float m = (float)g_music / 100.0f, f = (float)g_sfx / 100.0f;
    if (f < 0.05f) f = 0.05f;
    float mult = m / f; if (mult > 20.0f) mult = 20.0f;
    g_ps3_master_vol = (float)g_master / 100.0f;
    g_ps3_sfx_gain = f;
    g_ps3_music_mult = mult;
}

static void reset_kb()  { for (int i = 0; i < 16; i++) g_pad_kb_vk[i] = kDefKb[i]; }
static void reset_pad() { for (int i = 0; i < 16; i++) g_pad_xi_mask[i] = kDefXi[i]; }

static void save()
{
    char ini[MAX_PATH], v[32];
    path_ini(ini, sizeof ini);
    auto wi = [&](const char* sec, const char* key, int val) {
        snprintf(v, sizeof v, "%d", val); WritePrivateProfileStringA(sec, key, v, ini); };
    wi("audio", "master", g_master); wi("audio", "music", g_music); wi("audio", "sfx", g_sfx);
    wi("display", "fullscreen", g_fullscreen); wi("display", "resolution", g_res); wi("display", "render", g_render); wi("display", "crop", g_crop); wi("display", "sharpen", g_sharp);
    for (int i = 0; i < 16; i++) {
        char k[16]; snprintf(k, sizeof k, "btn%d", i);
        wi("keyboard", k, g_pad_kb_vk[i]); wi("controller", k, (int)g_pad_xi_mask[i]);
    }
}

static void load()
{
    char ini[MAX_PATH]; path_ini(ini, sizeof ini);
    reset_kb(); reset_pad();
    g_master = GetPrivateProfileIntA("audio", "master", 100, ini);
    g_music  = GetPrivateProfileIntA("audio", "music", 100, ini);
    g_sfx    = GetPrivateProfileIntA("audio", "sfx", 100, ini);
    g_fullscreen = GetPrivateProfileIntA("display", "fullscreen", 0, ini) ? 1 : 0;
    g_res = GetPrivateProfileIntA("display", "resolution", 0, ini);
    if (g_res < 0 || g_res >= kResCount) g_res = 0;
    g_crop = GetPrivateProfileIntA("display", "crop", 1, ini) ? 1 : 0;
    g_render = GetPrivateProfileIntA("display", "render", 2, ini);
    if (g_render < 0 || g_render >= kResCount) g_render = 2;
    g_render_boot = g_render;
    g_sharp = GetPrivateProfileIntA("display", "sharpen", 35, ini);
    if (g_sharp < 0) g_sharp = 0; if (g_sharp > 100) g_sharp = 100;
    g_ps3_sharpen = g_sharp;
    if (g_master < 0) g_master = 0; if (g_master > 200) g_master = 200;
    for (int i = 0; i < 16; i++) {
        char k[16]; snprintf(k, sizeof k, "btn%d", i);
        g_pad_kb_vk[i]    = GetPrivateProfileIntA("keyboard", k, kDefKb[i], ini);
        g_pad_xi_mask[i]  = (unsigned)GetPrivateProfileIntA("controller", k, (int)kDefXi[i], ini);
    }
    push_audio();
}

// ---------------------------------------------------------------- naming
static void vk_name(int vk, char* out, size_t n)
{
    if (!vk) { snprintf(out, n, "(unbound)"); return; }
    UINT sc = MapVirtualKeyA((UINT)vk, MAPVK_VK_TO_VSC);
    LONG lp = (LONG)(sc << 16);
    switch (vk) { case VK_UP: case VK_DOWN: case VK_LEFT: case VK_RIGHT: case VK_INSERT: case VK_DELETE:
                  case VK_HOME: case VK_END: case VK_PRIOR: case VK_NEXT: lp |= (1 << 24); break; }
    if (!GetKeyNameTextA(lp, out, (int)n)) snprintf(out, n, "key 0x%02X", vk);
}
static void xi_name(unsigned m, char* out, size_t n)
{
    static const struct { unsigned m; const char* s; } t[] = {
        {0x1000,"A"},{0x2000,"B"},{0x4000,"X"},{0x8000,"Y"},{0x0100,"LB"},{0x0200,"RB"},
        {0x10000,"LT"},{0x20000,"RT"},{0x0010,"Start"},{0x0020,"Back"},{0x0040,"Left stick click"},
        {0x0080,"Right stick click"},{0x0001,"D-Pad Up"},{0x0002,"D-Pad Down"},{0x0004,"D-Pad Left"},{0x0008,"D-Pad Right"} };
    if (!m) { snprintf(out, n, "(unbound)"); return; }
    for (auto& e : t) if (e.m == m) { snprintf(out, n, "%s", e.s); return; }
    snprintf(out, n, "button 0x%X", m);
}

// ---------------------------------------------------------------- XInput (own loader; for rebinding only)
struct XiPad { DWORD pk; WORD btn; BYTE lt, rt; SHORT lx, ly, rx, ry; };
typedef DWORD (WINAPI* XiGet)(DWORD, XiPad*);
static XiGet xi_get()
{
    static XiGet f = NULL; static int tried = 0;
    if (!tried) {
        tried = 1;
        static const char* const names[] = { "XInput1_4.dll", "XInput1_3.dll", "XInput9_1_0.dll" };
        for (auto nm : names) { HMODULE m = LoadLibraryA(nm); if (m) { f = (XiGet)(void*)GetProcAddress(m, "XInputGetState"); if (f) break; } }
    }
    return f;
}
static unsigned xi_pressed_mask()    // all currently pressed buttons, our mask format
{
    XiGet g = xi_get(); unsigned all = 0;
    if (!g) return 0;
    for (DWORD i = 0; i < 4; i++) {
        XiPad p; memset(&p, 0, sizeof p);
        if (g(i, &p) != ERROR_SUCCESS) continue;
        all |= p.btn;
        if (p.lt > 100) all |= 0x10000;
        if (p.rt > 100) all |= 0x20000;
    }
    return all;
}

// ---------------------------------------------------------------- UI
enum { ID_MASTER = 100, ID_MUSIC, ID_SFX, ID_MASTER_T, ID_MUSIC_T, ID_SFX_T, ID_MODE = 110, ID_RES,
       ID_KBLIST = 120, ID_PADLIST, ID_KBBIND, ID_PADBIND, ID_KBRESET, ID_PADRESET, ID_CLOSE = 130, ID_STATUS = 131, ID_CROP = 132, ID_RENDER = 133, ID_SHARP = 134, ID_SHARP_T = 135, ID_RESTART = 136 };
static HWND g_kb_list, g_pad_list, g_status;
static int  g_cap_kind = 0, g_cap_idx = -1, g_cap_armed = 0;   // 0 none / 1 keyboard / 2 controller

static void fill_lists()
{
    int ks = (int)SendMessageA(g_kb_list, LB_GETCURSEL, 0, 0), ps = (int)SendMessageA(g_pad_list, LB_GETCURSEL, 0, 0);
    SendMessageA(g_kb_list, LB_RESETCONTENT, 0, 0); SendMessageA(g_pad_list, LB_RESETCONTENT, 0, 0);
    for (int i = 0; i < 16; i++) {
        char a[64], b[160];
        vk_name(g_pad_kb_vk[i], a, sizeof a);
        snprintf(b, sizeof b, "%s\t%s", kBtnName[i], (g_cap_kind == 1 && g_cap_idx == i) ? "press a key... (Esc = cancel)" : a);
        SendMessageA(g_kb_list, LB_ADDSTRING, 0, (LPARAM)b);
        xi_name(g_pad_xi_mask[i], a, sizeof a);
        snprintf(b, sizeof b, "%s\t%s", kBtnName[i], (g_cap_kind == 2 && g_cap_idx == i) ? "press a button... (Esc = cancel)" : a);
        SendMessageA(g_pad_list, LB_ADDSTRING, 0, (LPARAM)b);
    }
    if (ks >= 0) SendMessageA(g_kb_list, LB_SETCURSEL, ks, 0);
    if (ps >= 0) SendMessageA(g_pad_list, LB_SETCURSEL, ps, 0);
}

static void begin_capture(int kind)
{
    HWND l = kind == 1 ? g_kb_list : g_pad_list;
    int sel = (int)SendMessageA(l, LB_GETCURSEL, 0, 0);
    if (sel < 0) { SetWindowTextA(g_status, "Select a row first, then press Rebind."); return; }
    g_cap_kind = kind; g_cap_idx = sel; g_cap_armed = 0;
    SetWindowTextA(g_status, kind == 1 ? "Press the new key for the selected action (Esc cancels)..."
                                       : "Press the new controller button (Esc cancels)...");
    fill_lists();
}

static void end_capture() { g_cap_kind = 0; g_cap_idx = -1; fill_lists(); }

static void tick_capture()
{
    if (!g_cap_kind) return;
    if (g_cap_kind == 1) {
        int down = 0, found = 0;
        for (int vk = 8; vk < 255; vk++) {
            if (vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU || vk == VK_F1 ||
                (vk >= 1 && vk <= 6) || vk == VK_LWIN || vk == VK_RWIN) continue;
            if (GetAsyncKeyState(vk) & 0x8000) { down = 1; if (!found) found = vk; }
        }
        if (!g_cap_armed) { if (!down) g_cap_armed = 1; return; }
        if (!found) return;
        if (found == VK_ESCAPE) { SetWindowTextA(g_status, "Cancelled."); end_capture(); return; }
        for (int i = 0; i < 16; i++) if (i != g_cap_idx && g_pad_kb_vk[i] == found)
            g_pad_kb_vk[i] = g_pad_kb_vk[g_cap_idx];          // swap with the action that had it
        g_pad_kb_vk[g_cap_idx] = found;
        SetWindowTextA(g_status, "Saved."); save(); end_capture();
    } else {
        unsigned m = xi_pressed_mask();
        if (!g_cap_armed) { if (!m && !(GetAsyncKeyState(VK_ESCAPE) & 0x8000)) g_cap_armed = 1; return; }
        if (GetAsyncKeyState(VK_ESCAPE) & 0x8000) { SetWindowTextA(g_status, "Cancelled."); end_capture(); return; }
        if (!m) return;
        unsigned pick = m & (~m + 1u);   // lowest set bit = one button
        if (m & 0x1000) pick = 0x1000; else if (m & 0x2000) pick = 0x2000; else if (m & 0x4000) pick = 0x4000;
        else if (m & 0x8000) pick = 0x8000; else if (m & 0x10000) pick = 0x10000; else if (m & 0x20000) pick = 0x20000;
        for (int i = 0; i < 16; i++) if (i != g_cap_idx && g_pad_xi_mask[i] == pick)
            g_pad_xi_mask[i] = g_pad_xi_mask[g_cap_idx];
        g_pad_xi_mask[g_cap_idx] = pick;
        SetWindowTextA(g_status, "Saved."); save(); end_capture();
    }
}

static void upd_vol_text(HWND w)
{
    char b[32];
    snprintf(b, sizeof b, "%d%%", g_master); SetDlgItemTextA(w, ID_MASTER_T, b);
    snprintf(b, sizeof b, "%d%%", g_music);  SetDlgItemTextA(w, ID_MUSIC_T, b);
    snprintf(b, sizeof b, "%d%%", g_sfx);    SetDlgItemTextA(w, ID_SFX_T, b);
    snprintf(b, sizeof b, "%d%%", g_sharp);  SetDlgItemTextA(w, ID_SHARP_T, b);
}

static HWND mk(HWND p, const char* cls, const char* txt, DWORD st, int x, int y, int w, int h, int id, DWORD ex = 0)
{
    HWND c = CreateWindowExA(ex, cls, txt, WS_CHILD | WS_VISIBLE | st, x, y, w, h, p, (HMENU)(INT_PTR)id, GetModuleHandleA(NULL), NULL);
    SendMessageA(c, WM_SETFONT, (WPARAM)GetStockObject(DEFAULT_GUI_FONT), TRUE);
    return c;
}

// Relaunch this exe with the same command line and environment (settings are saved first), then end this process.
static void restart_game(HWND w)
{
    save();
    char exe[MAX_PATH]; GetModuleFileNameA(NULL, exe, MAX_PATH);
    char cmd[4096]; lstrcpynA(cmd, GetCommandLineA(), (int)sizeof cmd);
    STARTUPINFOA si = {0}; si.cb = sizeof si; PROCESS_INFORMATION pi = {0};
    if (CreateProcessA(exe, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        TerminateProcess(GetCurrentProcess(), 0);
    } else {
        SetWindowTextA(g_status, "Could not restart automatically - close the game and start it again.");
    }
}

static void toggle_menu(HWND w)
{
    if (IsWindowVisible(w)) { end_capture(); save(); ShowWindow(w, SW_HIDE); }
    else {
        SetWindowPos(w, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        ShowWindow(w, SW_SHOW); SetForegroundWindow(w);
        HWND f = GetDlgItem(w, ID_MASTER); if (f) SetFocus(f);
        SetWindowTextA(g_status, "Controller: D-pad = move / change, A = select, B = close. F1 also closes.");
    }
}

// ---------------------------------------------------------------- controller navigation of this window
static int nav_ids_visible(HWND w, int* out)
{
    static const int order[] = { ID_MASTER, ID_MUSIC, ID_SFX, ID_MODE, ID_RES, ID_RENDER, ID_CROP, ID_SHARP,
                                 ID_KBLIST, ID_KBBIND, ID_KBRESET, ID_PADLIST, ID_PADBIND, ID_PADRESET, ID_RESTART, ID_CLOSE };
    int n = 0;
    for (int id : order) { HWND c = GetDlgItem(w, id); if (c && IsWindowVisible(c) && IsWindowEnabled(c)) out[n++] = id; }
    return n;
}
static void nav_move(HWND w, int dir)            // dir -1 = previous control, +1 = next
{
    int ids[24]; const int n = nav_ids_visible(w, ids); if (!n) return;
    const int cur = GetDlgCtrlID(GetFocus());
    int idx = -1; for (int i = 0; i < n; i++) if (ids[i] == cur) idx = i;
    idx = idx < 0 ? 0 : (idx + dir + n) % n;
    SetFocus(GetDlgItem(w, ids[idx]));
}
static void nav_dir(HWND w, int d)                // d: 0 up, 1 down, 2 left, 3 right
{
    HWND f = GetFocus(); const int id = f ? GetDlgCtrlID(f) : 0;
    if (id == ID_KBLIST || id == ID_PADLIST) {    // up/down walk the rows, then fall through to the next control
        if (d == 0 || d == 1) {
            const int cnt = (int)SendMessageA(f, LB_GETCOUNT, 0, 0), cur = (int)SendMessageA(f, LB_GETCURSEL, 0, 0);
            const int nx = cur + (d == 1 ? 1 : -1);
            if (cur < 0) { SendMessageA(f, LB_SETCURSEL, 0, 0); return; }
            if (nx < 0 || nx >= cnt) { nav_move(w, d == 1 ? 1 : -1); return; }
            SendMessageA(f, LB_SETCURSEL, nx, 0); return;
        }
        return;
    }
    if (d == 0) { nav_move(w, -1); return; }
    if (d == 1) { nav_move(w, +1); return; }
    const int step = d == 3 ? 1 : -1;
    if (id == ID_MASTER || id == ID_MUSIC || id == ID_SFX || id == ID_SHARP) {
        const int lo = (int)SendMessageA(f, TBM_GETRANGEMIN, 0, 0), hi = (int)SendMessageA(f, TBM_GETRANGEMAX, 0, 0);
        int v = (int)SendMessageA(f, TBM_GETPOS, 0, 0) + step * (id == ID_MASTER ? 10 : 5);
        if (v < lo) v = lo; if (v > hi) v = hi;
        SendMessageA(f, TBM_SETPOS, TRUE, v);
        SendMessageA(w, WM_HSCROLL, MAKEWPARAM(SB_ENDSCROLL, v), (LPARAM)f);
    } else if (id == ID_MODE || id == ID_RES || id == ID_RENDER) {
        const int cnt = (int)SendMessageA(f, CB_GETCOUNT, 0, 0), cur = (int)SendMessageA(f, CB_GETCURSEL, 0, 0);
        const int nx = cur + step;
        if (nx >= 0 && nx < cnt) {
            SendMessageA(f, CB_SETCURSEL, nx, 0);
            SendMessageA(w, WM_COMMAND, MAKEWPARAM(id, CBN_SELCHANGE), (LPARAM)f);
        }
    }
}
static void nav_activate(HWND w)                  // A button
{
    HWND f = GetFocus(); const int id = f ? GetDlgCtrlID(f) : 0;
    if (id == ID_KBLIST) begin_capture(1);
    else if (id == ID_PADLIST) begin_capture(2);
    else if (id == ID_CROP || id == ID_KBBIND || id == ID_KBRESET || id == ID_PADBIND || id == ID_PADRESET ||
             id == ID_RESTART || id == ID_CLOSE) SendMessageA(f, BM_CLICK, 0, 0);
}
// Called from the 30 ms timer. L3+R3 (click both sticks) opens / closes the window from a controller; while it is open the
// controller drives it and the game gets no controller input (g_ps3_pad_block).
static void tick_nav(HWND w)
{
    static unsigned prev = 0; static int armed = 1; static DWORD rep_at[4] = {0,0,0,0}; static int hold_block = 0;
    XiGet g = xi_get(); unsigned btn = 0; int sx = 0, sy = 0;
    if (g) for (DWORD i = 0; i < 4; i++) {
        XiPad p; memset(&p, 0, sizeof p);
        if (g(i, &p) != ERROR_SUCCESS) continue;
        btn |= p.btn; if (p.lt > 100) btn |= 0x10000; if (p.rt > 100) btn |= 0x20000;
        if (p.lx > sx || -p.lx > sx) sx = p.lx; if (p.ly > sy || -p.ly > sy) sy = p.ly;
    }
    const int vis = IsWindowVisible(w) ? 1 : 0;
    const unsigned combo = 0x0040u | 0x0080u;                      // L3 + R3 (both stick clicks)
    if ((btn & combo) == combo && (prev & combo) != combo && !g_cap_kind) { toggle_menu(w); armed = 0; hold_block = 1; }
    const int nowvis = IsWindowVisible(w) ? 1 : 0;
    // The game ignores the controller while the window is open, and until every button is let go after it closes.
    if (nowvis) hold_block = 1; else if (!btn && hold_block) hold_block = 0;
    g_ps3_pad_block = (nowvis || hold_block) ? 1 : 0;
    if (nowvis && !g_cap_kind) {
        if (!armed) { if (!btn && sx < 8000 && sy < 8000) armed = 1; }   // wait for the opening combo to be released
        else {
            int dirs[4] = { (btn & 0x0001) || sy > 16000, (btn & 0x0002) || sy < -16000,
                            (btn & 0x0004) || sx < -16000, (btn & 0x0008) || sx > 16000 };
            const DWORD now = GetTickCount();
            for (int d = 0; d < 4; d++) {
                if (!dirs[d]) { rep_at[d] = 0; continue; }
                if (rep_at[d] == 0) { nav_dir(w, d); rep_at[d] = now + 380; }
                else if (now >= rep_at[d]) { nav_dir(w, d); rep_at[d] = now + 90; }
            }
            if ((btn & 0x1000) && !(prev & 0x1000)) nav_activate(w);
            if ((btn & 0x2000) && !(prev & 0x2000)) toggle_menu(w);   // B closes (and saves)
        }
    } else if (!nowvis) armed = 1;
    (void)vis; prev = btn;
}

static LRESULT CALLBACK menu_proc(HWND w, UINT m, WPARAM wp, LPARAM lp)
{
    switch (m) {
    case WM_CREATE: {
        mk(w, "STATIC", "Audio", SS_LEFT, 16, 10, 200, 18, 0);
        mk(w, "STATIC", "Master volume", SS_LEFT, 16, 34, 110, 18, 0);
        HWND t = mk(w, TRACKBAR_CLASSA, "", TBS_HORZ | TBS_NOTICKS | WS_TABSTOP, 130, 30, 220, 26, ID_MASTER);
        SendMessageA(t, TBM_SETRANGE, TRUE, MAKELONG(0, 200)); SendMessageA(t, TBM_SETPOS, TRUE, g_master);
        mk(w, "STATIC", "", SS_LEFT, 356, 34, 50, 18, ID_MASTER_T);
        mk(w, "STATIC", "Music volume", SS_LEFT, 16, 64, 110, 18, 0);
        t = mk(w, TRACKBAR_CLASSA, "", TBS_HORZ | TBS_NOTICKS | WS_TABSTOP, 130, 60, 220, 26, ID_MUSIC);
        SendMessageA(t, TBM_SETRANGE, TRUE, MAKELONG(0, 100)); SendMessageA(t, TBM_SETPOS, TRUE, g_music);
        mk(w, "STATIC", "", SS_LEFT, 356, 64, 50, 18, ID_MUSIC_T);
        mk(w, "STATIC", "Effects volume", SS_LEFT, 16, 94, 110, 18, 0);
        t = mk(w, TRACKBAR_CLASSA, "", TBS_HORZ | TBS_NOTICKS | WS_TABSTOP, 130, 90, 220, 26, ID_SFX);
        SendMessageA(t, TBM_SETRANGE, TRUE, MAKELONG(0, 100)); SendMessageA(t, TBM_SETPOS, TRUE, g_sfx);
        mk(w, "STATIC", "", SS_LEFT, 356, 94, 50, 18, ID_SFX_T);
        mk(w, "STATIC", "Music = the game's music stream. Effects = everything else (coins, zappers, jetpack...).",
           SS_LEFT, 16, 120, 400, 16, 0);

        mk(w, "STATIC", "Display", SS_LEFT, 440, 10, 200, 18, 0);
        mk(w, "STATIC", "Mode", SS_LEFT, 440, 34, 70, 18, 0);
        HWND c = mk(w, "COMBOBOX", "", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, 520, 30, 200, 120, ID_MODE);
        SendMessageA(c, CB_ADDSTRING, 0, (LPARAM)"Windowed"); SendMessageA(c, CB_ADDSTRING, 0, (LPARAM)"Fullscreen");
        SendMessageA(c, CB_SETCURSEL, g_fullscreen, 0);
        mk(w, "STATIC", "Window size", SS_LEFT, 440, 62, 76, 18, 0);
        c = mk(w, "COMBOBOX", "", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, 520, 58, 200, 200, ID_RES);
        for (int i = 0; i < kResCount; i++) SendMessageA(c, CB_ADDSTRING, 0, (LPARAM)kRes[i].name);
        SendMessageA(c, CB_SETCURSEL, g_res, 0);
        mk(w, "STATIC", "Render res", SS_LEFT, 440, 90, 76, 18, 0);
        c = mk(w, "COMBOBOX", "", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, 520, 86, 200, 200, ID_RENDER);
        for (int i = 0; i < kResCount; i++) SendMessageA(c, CB_ADDSTRING, 0, (LPARAM)kRes[i].name);
        SendMessageA(c, CB_SETCURSEL, g_render, 0);
        mk(w, "STATIC", "Changing Render res requires restarting the game.",
           SS_LEFT, 440, 112, 290, 16, 0);
        { HWND cb = mk(w, "BUTTON", "Fullscreen: crop the game's black border (fill height)", BS_AUTOCHECKBOX | WS_TABSTOP, 440, 128, 290, 20, ID_CROP);
          SendMessageA(cb, BM_SETCHECK, g_crop ? BST_CHECKED : BST_UNCHECKED, 0); }
        mk(w, "STATIC", "Sharpness", SS_LEFT, 440, 156, 70, 18, 0);
        { HWND st = mk(w, TRACKBAR_CLASSA, "", TBS_HORZ | TBS_NOTICKS | WS_TABSTOP, 510, 152, 160, 26, ID_SHARP);
          SendMessageA(st, TBM_SETRANGE, TRUE, MAKELONG(0, 100)); SendMessageA(st, TBM_SETPOS, TRUE, g_sharp);
          mk(w, "STATIC", "", SS_LEFT, 676, 156, 50, 18, ID_SHARP_T); }

        mk(w, "STATIC", "Keyboard controls", SS_LEFT, 16, 180, 200, 18, 0);
        g_kb_list = mk(w, "LISTBOX", "", LBS_NOTIFY | LBS_USETABSTOPS | WS_BORDER | WS_VSCROLL | WS_TABSTOP, 16, 202, 350, 290, ID_KBLIST);
        mk(w, "BUTTON", "Rebind selected", BS_PUSHBUTTON | WS_TABSTOP, 16, 498, 130, 26, ID_KBBIND);
        mk(w, "BUTTON", "Reset keyboard", BS_PUSHBUTTON | WS_TABSTOP, 152, 498, 130, 26, ID_KBRESET);
        mk(w, "STATIC", "Controller (Xbox-layout) controls", SS_LEFT, 380, 180, 250, 18, 0);
        g_pad_list = mk(w, "LISTBOX", "", LBS_NOTIFY | LBS_USETABSTOPS | WS_BORDER | WS_VSCROLL | WS_TABSTOP, 380, 202, 350, 290, ID_PADLIST);
        mk(w, "BUTTON", "Rebind selected", BS_PUSHBUTTON | WS_TABSTOP, 380, 498, 130, 26, ID_PADBIND);
        mk(w, "BUTTON", "Reset controller", BS_PUSHBUTTON | WS_TABSTOP, 516, 498, 130, 26, ID_PADRESET);
        int tabs[1] = { 90 };
        SendMessageA(g_kb_list, LB_SETTABSTOPS, 1, (LPARAM)tabs); SendMessageA(g_pad_list, LB_SETTABSTOPS, 1, (LPARAM)tabs);
        g_status = mk(w, "STATIC", "F1 opens / closes this window. Changes apply immediately.", SS_LEFT, 16, 536, 470, 18, ID_STATUS);
        mk(w, "BUTTON", "Close", BS_PUSHBUTTON | WS_TABSTOP, 640, 532, 90, 26, ID_CLOSE);
        mk(w, "BUTTON", "Restart game", BS_PUSHBUTTON | WS_TABSTOP, 510, 532, 120, 26, ID_RESTART);
        ShowWindow(GetDlgItem(w, ID_RESTART), SW_HIDE);
        fill_lists(); upd_vol_text(w);
        SetTimer(w, 1, 30, NULL);
        return 0;
    }
    case WM_TIMER: tick_capture(); tick_nav(w); return 0;
    case WM_HSCROLL: {
        HWND src = (HWND)lp; int id = GetDlgCtrlID(src);
        int v = (int)SendMessageA(src, TBM_GETPOS, 0, 0);
        if (id == ID_SHARP) { g_sharp = v; g_ps3_sharpen = v; }
        else if (id == ID_MASTER) { g_master = v; push_audio(); }
        else if (id == ID_MUSIC) { g_music = v; push_audio(); } else if (id == ID_SFX) { g_sfx = v; push_audio(); }
        upd_vol_text(w);
        if (LOWORD(wp) == SB_ENDSCROLL) save();
        return 0;
    }
    case WM_COMMAND: {
        int id = LOWORD(wp), nf = HIWORD(wp);
        if (id == ID_MODE && nf == CBN_SELCHANGE) { g_fullscreen = (int)SendMessageA((HWND)lp, CB_GETCURSEL, 0, 0); InterlockedExchange(&g_apply_display, 1); save(); }
        else if (id == ID_RES && nf == CBN_SELCHANGE) { g_res = (int)SendMessageA((HWND)lp, CB_GETCURSEL, 0, 0); InterlockedExchange(&g_apply_display, 1); save(); }
        else if (id == ID_RENDER && nf == CBN_SELCHANGE) { g_render = (int)SendMessageA((HWND)lp, CB_GETCURSEL, 0, 0); save(); { const BOOL pend = g_render != g_render_boot; ShowWindow(GetDlgItem(w, ID_RESTART), pend ? SW_SHOW : SW_HIDE);
                  SetWindowTextA(g_status, pend ? "Render resolution changed - click Restart game to apply it." : "Render resolution unchanged."); } }
        else if (id == ID_CROP && nf == BN_CLICKED) { g_crop = (SendMessageA((HWND)lp, BM_GETCHECK, 0, 0) == BST_CHECKED) ? 1 : 0; InterlockedExchange(&g_apply_display, 1); save(); }
        else if (id == ID_KBBIND) begin_capture(1);
        else if (id == ID_PADBIND) begin_capture(2);
        else if (id == ID_KBRESET) { reset_kb(); save(); fill_lists(); }
        else if (id == ID_PADRESET) { reset_pad(); save(); fill_lists(); }
        else if (id == ID_KBLIST && nf == LBN_DBLCLK) begin_capture(1);
        else if (id == ID_PADLIST && nf == LBN_DBLCLK) begin_capture(2);
        else if (id == ID_RESTART) restart_game(w);
        else if (id == ID_CLOSE) { save(); ShowWindow(w, SW_HIDE); }
        return 0;
    }
    case WM_CLOSE: end_capture(); save(); ShowWindow(w, SW_HIDE); return 0;
    case WM_APP + 1: {
        static DWORD last = 0; const DWORD now = GetTickCount();
        if (last && now - last < 250) return 0;          // F1 seen by two paths in the same press: toggle once
        last = now;
        toggle_menu(w);
        return 0;
    }
    case WM_APP + 3:   // after a display change: stay above the game / backdrop windows
        SetWindowPos(w, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        return 0;
    case WM_APP + 2:   // display mode changed from F11: refresh the combo
        SendDlgItemMessageA(w, ID_MODE, CB_SETCURSEL, g_fullscreen, 0);
        return 0;
    }
    return DefWindowProcA(w, m, wp, lp);
}

static DWORD WINAPI menu_thread(LPVOID)
{
    INITCOMMONCONTROLSEX ic = { sizeof ic, ICC_BAR_CLASSES };
    InitCommonControlsEx(&ic);
    WNDCLASSEXA wc = {0};
    wc.cbSize = sizeof wc; wc.lpfnWndProc = menu_proc; wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW); wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = "JJSettingsWnd";
    RegisterClassExA(&wc);
    RECT r = { 0, 0, 748, 570 };
    AdjustWindowRect(&r, WS_CAPTION | WS_SYSMENU, FALSE);
    g_menu = CreateWindowExA(WS_EX_TOPMOST, "JJSettingsWnd", "Jetpack Joyride - Settings (build 32)", WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN,
                             CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, NULL, NULL, GetModuleHandleA(NULL), NULL);
    MSG msg;
    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        if (g_menu && (msg.message == WM_KEYDOWN || msg.message == WM_SYSKEYDOWN) && msg.wParam == VK_F1 && !(msg.lParam & (1 << 30))) {
            PostMessageA(g_menu, WM_APP + 1, 0, 0); continue; }
        if (g_menu && IsDialogMessageA(g_menu, &msg)) continue;
        TranslateMessage(&msg); DispatchMessageA(&msg);
    }
    return 0;
}

// ---------------------------------------------------------------- display (runs on the game's window thread)
// Fullscreen = borderless at the desktop's native resolution (no mode switch, so ultrawide monitors are never
// stretched). The game window is the largest 16:9 rectangle that fits, centred, on a black backdrop window.
static HWND g_backdrop = NULL;
static LRESULT CALLBACK backdrop_proc(HWND w, UINT m, WPARAM wp, LPARAM lp)
{
    if (m == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (m == WM_ERASEBKGND) { RECT rc; GetClientRect(w, &rc); FillRect((HDC)wp, &rc, (HBRUSH)GetStockObject(BLACK_BRUSH)); return 1; }
    return DefWindowProcA(w, m, wp, lp);
}
static void backdrop_show(const RECT& mon)
{
    if (!g_backdrop) {
        WNDCLASSEXA wc = {0};
        wc.cbSize = sizeof wc; wc.lpfnWndProc = backdrop_proc; wc.hInstance = GetModuleHandleA(NULL);
        wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH); wc.lpszClassName = "JJBackdropWnd";
        RegisterClassExA(&wc);
        g_backdrop = CreateWindowExA(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, "JJBackdropWnd", "", WS_POPUP,
                                     mon.left, mon.top, mon.right - mon.left, mon.bottom - mon.top,
                                     NULL, NULL, GetModuleHandleA(NULL), NULL);
    }
    if (g_backdrop) {
        SetWindowPos(g_backdrop, HWND_TOP, mon.left, mon.top, mon.right - mon.left, mon.bottom - mon.top,
                     SWP_NOACTIVATE | SWP_SHOWWINDOW);
        InvalidateRect(g_backdrop, NULL, TRUE);
    }
}
static void backdrop_hide() { if (g_backdrop) ShowWindow(g_backdrop, SW_HIDE); }

static void apply_display(HWND w)
{
    const Res& r = kRes[g_res];
    MONITORINFO mi = { sizeof mi };
    GetMonitorInfoA(MonitorFromWindow(w, MONITOR_DEFAULTTOPRIMARY), &mi);
    if (g_fullscreen) {
        const RECT mon = mi.rcMonitor;
        const int mw = mon.right - mon.left, mh = mon.bottom - mon.top;
        int gw, gh;                                   // largest 16:9 area that fits
        if ((long long)mw * 9 >= (long long)mh * 16) { gh = mh; gw = mh * 16 / 9; }
        else                                          { gw = mw; gh = mw * 9 / 16; }
        backdrop_show(mon);
        // The game draws inside a 1728x972 viewport of its 1920x1080 frame (a 5% black "safe area" border).
        // Cropping = make the window 1920/1728 bigger than the area we want to see, centred, so the border falls
        // outside the screen / onto the black backdrop.
        int ww = gw, wh = gh;
        if (g_crop) { ww = gw * 1920 / 1728; wh = gh * 1920 / 1728; }
        SetWindowLongPtrA(w, GWL_STYLE, WS_POPUP | WS_VISIBLE);
        SetWindowPos(w, HWND_TOP, mon.left + (mw - ww) / 2, mon.top + (mh - wh) / 2, ww, wh,
                     SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        g_fs_active = 1;
        { RECT wrc, crc; GetWindowRect(w, &wrc); GetClientRect(w, &crc);
          fprintf(stderr, "[settings] fullscreen: monitor %dx%d at (%ld,%ld) | want game %dx%d | window now %ldx%d at (%ld,%ld), client %ldx%ld | dpi %u backdrop=%p\n",
                  mw, mh, mon.left, mon.top, gw, gh, wrc.right - wrc.left, (int)(wrc.bottom - wrc.top), wrc.left, wrc.top,
                  crc.right - crc.left, crc.bottom - crc.top, (unsigned)GetDpiForWindow(w), (void*)g_backdrop);
          fflush(stderr); }
    } else {
        backdrop_hide();
        g_fs_active = 0;
        int cw = r.w, ch = r.h;
        const int aw = mi.rcWork.right - mi.rcWork.left - 16, ah = mi.rcWork.bottom - mi.rcWork.top - 48;
        while ((cw > aw || ch > ah) && cw > 640) { cw = cw * 9 / 10; ch = ch * 9 / 10; }   // keep it on screen
        RECT wr = { 0, 0, cw, ch };
        AdjustWindowRect(&wr, WS_OVERLAPPEDWINDOW, FALSE);
        const int ww = wr.right - wr.left, wh = wr.bottom - wr.top;
        SetWindowLongPtrA(w, GWL_STYLE, WS_OVERLAPPEDWINDOW | WS_VISIBLE);
        SetWindowPos(w, HWND_NOTOPMOST, mi.rcWork.left + (mi.rcWork.right - mi.rcWork.left - ww) / 2,
                     mi.rcWork.top + (mi.rcWork.bottom - mi.rcWork.top - wh) / 2, ww, wh,
                     SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    }
}

// Call BEFORE the graphics engine starts: tells it what scale to render at (render res / 1080p).
static void early_env()
{
    char ini[MAX_PATH]; path_ini(ini, sizeof ini);
    int r = GetPrivateProfileIntA("display", "render", 2, ini);
    if (r < 0 || r >= kResCount) r = 2;
    char v[32]; snprintf(v, sizeof v, "%.4f", (double)kRes[r].h / 1080.0);
    _putenv_s("RSX_RENDER_SCALE", v);
}

// Call once at startup (before the game's first frame).
static void init()
{
    load();
    CreateThread(NULL, 0, menu_thread, NULL, 0, NULL);
}

// Call every frame from the game's window thread (the message pump).
static void pump()
{
    static int f1_prev = 0, f11_prev = 0;
    HWND game = (HWND)rsx_null_backend_get_hwnd();
    HWND fg = GetForegroundWindow();
    const int ours = fg && (fg == game || fg == g_menu);
    const int f1 = ours && (GetAsyncKeyState(VK_F1) & 0x8000) != 0;
    const int f11 = ours && (GetAsyncKeyState(VK_F11) & 0x8000) != 0;
    if (f1 && !f1_prev && g_menu) PostMessageA(g_menu, WM_APP + 1, 0, 0);
    if (f11 && !f11_prev) { g_fullscreen = !g_fullscreen; InterlockedExchange(&g_apply_display, 1); save();
                            if (g_menu) PostMessageA(g_menu, WM_APP + 2, 0, 0); }
    f1_prev = f1; f11_prev = f11;
    if (game && InterlockedExchange(&g_apply_display, 0)) {
        apply_display(game);
        if (g_menu) PostMessageA(g_menu, WM_APP + 3, 0, 0);
        SetForegroundWindow(g_menu && IsWindowVisible(g_menu) ? g_menu : game);
    }
}

} // namespace sm
'@
[IO.File]::WriteAllText((Join-Path $Root 'settings_menu.h'), $hdr)
Write-Host 'wrote settings_menu.h (build 32)' -ForegroundColor Green
& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
& "$PSScriptRoot\play.ps1"
