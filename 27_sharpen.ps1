# Sharpen the picture: a contrast-adaptive sharpening pass (like AMD CAS) applied to every frame as it is presented,
# plus a live "Sharpness" slider (0-100%) in the F1 settings window (default 35%, saved in settings.ini).
# Why: the game's art is fixed-size sprites/textures, so a higher render resolution can't add detail by itself;
# sharpening restores the crisp edges that bilinear texture filtering softens.
# Patches ps3recomp rsx_live_draw.c, writes the newest settings_menu.h (build 27), rebuilds, launches.   Output: play.log
. "$PSScriptRoot\env.ps1"
Set-Location $Root
$f1 = Join-Path $Root 'ps3recomp\libs\video\rsx_live_draw.c'
$t = [IO.File]::ReadAllText($f1)
if ($t -notmatch 'SHARPEN_PATCH') {
  function Edit([string]$old, [string]$new) {
    $n = ([regex]::Matches($script:t, [regex]::Escape($old))).Count
    if ($n -ne 1) { throw "rsx_live_draw.c: expected 1 match for [$old], found $n" }
    $script:t = $script:t.Replace($old, $new)
  }
  $helper = @'
/* SHARPEN_PATCH: contrast-adaptive sharpening applied when the finished frame is presented. */
volatile int g_ps3_sharpen = 35;   /* 0..100, set live from the settings window */
static ID3D12RootSignature* g_sharp_rs;
static ID3D12PipelineState* g_sharp_pso;
static int g_sharp_failed;

static int ld_sharpen_ready(void)
{
    if (g_sharp_pso) return 1;
    if (g_sharp_failed) return 0;
    g_sharp_failed = 1;
    static const char src[] =
        "cbuffer C : register(b0) { float4 k; };\n"
        "Texture2D t0 : register(t0);\n"
        "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
        "    float2 q = float2((id << 1) & 2, id & 2);\n"
        "    return float4(q * float2(2, -2) + float2(-1, 1), 0, 1); }\n"
        "float4 ps(float4 p : SV_Position) : SV_Target {\n"
        "    uint w, h; t0.GetDimensions(w, h);\n"
        "    int2 c = int2(p.xy); int2 lim = int2(w - 1, h - 1);\n"
        "    float4 m = t0.Load(int3(c, 0));\n"
        "    float3 a = t0.Load(int3(clamp(c + int2(0, -1), int2(0, 0), lim), 0)).rgb;\n"
        "    float3 b = t0.Load(int3(clamp(c + int2(-1, 0), int2(0, 0), lim), 0)).rgb;\n"
        "    float3 d = t0.Load(int3(clamp(c + int2(1, 0), int2(0, 0), lim), 0)).rgb;\n"
        "    float3 e = t0.Load(int3(clamp(c + int2(0, 1), int2(0, 0), lim), 0)).rgb;\n"
        "    float3 mn = min(min(min(a, b), min(d, e)), m.rgb);\n"
        "    float3 mx = max(max(max(a, b), max(d, e)), m.rgb);\n"
        "    float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));\n"
        "    float peak = -1.0 / lerp(8.0, 5.0, k.x);\n"
        "    float3 wgt = amp * peak;\n"
        "    float3 o = saturate(((a + b + d + e) * wgt + m.rgb) / (1.0 + 4.0 * wgt));\n"
        "    return float4(o, m.a); }\n";
    D3D12_DESCRIPTOR_RANGE range = {0};
    range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    range.NumDescriptors = 1;
    D3D12_ROOT_PARAMETER p[2] = {0};
    p[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    p[0].Constants.Num32BitValues = 4;
    p[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    p[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    p[1].DescriptorTable.NumDescriptorRanges = 1;
    p[1].DescriptorTable.pDescriptorRanges = &range;
    p[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_ROOT_SIGNATURE_DESC rsd = {0};
    rsd.NumParameters = 2; rsd.pParameters = p;
    ID3DBlob* sig = NULL; ID3DBlob* err = NULL;
    if (FAILED(D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &err))) {
        if (err) err->lpVtbl->Release(err);
        return 0;
    }
    HRESULT hr = g.dev->lpVtbl->CreateRootSignature(g.dev, 0, sig->lpVtbl->GetBufferPointer(sig),
                     sig->lpVtbl->GetBufferSize(sig), &IID_ID3D12RootSignature, (void**)&g_sharp_rs);
    sig->lpVtbl->Release(sig);
    if (FAILED(hr)) { g_sharp_rs = NULL; return 0; }
    ID3DBlob* vs = NULL; ID3DBlob* ps = NULL; err = NULL;
    if (FAILED(D3DCompile(src, sizeof(src) - 1u, "ld_sharpen", NULL, NULL, "vs", "vs_5_0", 0, 0, &vs, &err)) ||
        FAILED(D3DCompile(src, sizeof(src) - 1u, "ld_sharpen", NULL, NULL, "ps", "ps_5_0", 0, 0, &ps, &err))) {
        fprintf(stderr, "[sharpen] shader compile failed: %s\n",
                err ? (const char*)err->lpVtbl->GetBufferPointer(err) : "?");
        if (err) err->lpVtbl->Release(err);
        if (vs) vs->lpVtbl->Release(vs);
        return 0;
    }
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {0};
    pd.pRootSignature = g_sharp_rs;
    pd.VS.pShaderBytecode = vs->lpVtbl->GetBufferPointer(vs); pd.VS.BytecodeLength = vs->lpVtbl->GetBufferSize(vs);
    pd.PS.pShaderBytecode = ps->lpVtbl->GetBufferPointer(ps); pd.PS.BytecodeLength = ps->lpVtbl->GetBufferSize(ps);
    pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pd.SampleMask = 0xFFFFFFFFu;
    pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pd.RasterizerState.DepthClipEnable = TRUE;
    pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd.NumRenderTargets = 1;
    pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pd.SampleDesc.Count = 1;
    hr = g.dev->lpVtbl->CreateGraphicsPipelineState(g.dev, &pd, &IID_ID3D12PipelineState, (void**)&g_sharp_pso);
    vs->lpVtbl->Release(vs); ps->lpVtbl->Release(ps);
    if (FAILED(hr)) { fprintf(stderr, "[sharpen] PSO failed hr=0x%08lX\n", (unsigned long)hr); g_sharp_pso = NULL; return 0; }
    g_sharp_failed = 0;
    fprintf(stderr, "[sharpen] ready\n");
    return 1;
}

/* Call with srcimg in RENDER_TARGET state and bb in PRESENT state (same size). Overwrites bb with the sharpened frame. */
static int ld_sharpen_present(ID3D12Resource* srcimg, ID3D12Resource* bb, u32 target, u32 w, u32 h)
{
    if (!ld_sharpen_ready()) return 0;
    u32 slots[SRV_TABLE_SIZE];
    for (u32 i = 0; i < SRV_TABLE_SIZE; i++) slots[i] = SRV_WHITE;
    slots[0] = SRV_SURFACE_BASE + target;
    const D3D12_GPU_DESCRIPTOR_HANDLE table = srv_table(slots);
    if (!table.ptr) return 0;
    D3D12_RESOURCE_BARRIER b[2] = {0};
    b[0].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b[0].Transition.pResource = srcimg;
    b[0].Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b[0].Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    b[0].Transition.StateAfter = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
    b[1].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b[1].Transition.pResource = bb;
    b[1].Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b[1].Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
    b[1].Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
    g.list->lpVtbl->ResourceBarrier(g.list, 2, b);

    const u32 bbi = g.swap->lpVtbl->GetCurrentBackBufferIndex(g.swap);
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = rtv_handle(bbi);
    g.list->lpVtbl->OMSetRenderTargets(g.list, 1, &rtv, FALSE, NULL);
    ID3D12DescriptorHeap* heaps[] = {g.srv_heap, g.smp_heap};
    g.list->lpVtbl->SetDescriptorHeaps(g.list, 2, heaps);
    g.list->lpVtbl->SetPipelineState(g.list, g_sharp_pso);
    g.list->lpVtbl->SetGraphicsRootSignature(g.list, g_sharp_rs);
    int sv = g_ps3_sharpen; if (sv < 0) sv = 0; if (sv > 100) sv = 100;
    const float k[4] = { (float)sv / 100.0f, 0.0f, 0.0f, 0.0f };
    g.list->lpVtbl->SetGraphicsRoot32BitConstants(g.list, 0, 4, k, 0);
    g.list->lpVtbl->SetGraphicsRootDescriptorTable(g.list, 1, table);
    D3D12_VIEWPORT vp = { 0.0f, 0.0f, (float)w, (float)h, 0.0f, 1.0f };
    D3D12_RECT sc = { 0, 0, (LONG)w, (LONG)h };
    g.list->lpVtbl->RSSetViewports(g.list, 1, &vp);
    g.list->lpVtbl->RSSetScissorRects(g.list, 1, &sc);
    g.list->lpVtbl->IASetPrimitiveTopology(g.list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    g.list->lpVtbl->DrawInstanced(g.list, 3, 1, 0, 0);

    b[0].Transition.StateBefore = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
    b[0].Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
    b[1].Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    b[1].Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
    g.list->lpVtbl->ResourceBarrier(g.list, 2, b);
    return 1;
}

'@
  $call = @'
/* SHARPEN_PATCH: redraw the presented frame through the sharpen shader when the sizes match. */
    if (g_ps3_sharpen > 0) {
        D3D12_RESOURCE_DESC _sa, _sb;
        srcimg->lpVtbl->GetDesc(srcimg, &_sa);
        bb->lpVtbl->GetDesc(bb, &_sb);
        if (_sa.Width == _sb.Width && _sa.Height == _sb.Height)
            ld_sharpen_present(srcimg, bb, target, (u32)_sb.Width, (u32)_sb.Height);
    }
'@
  Edit 'static ID3D12RootSignature* g_sblit_rs;' ($helper + 'static ID3D12RootSignature* g_sblit_rs;')
  Edit 'ld_flush(LD_FLUSH_PRESENT);' ($call + 'ld_flush(LD_FLUSH_PRESENT);')
  [IO.File]::WriteAllText($f1, $t)
  Write-Host 'patched rsx_live_draw.c' -ForegroundColor Green
} else { Write-Host 'rsx_live_draw.c already patched' }

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
       ID_KBLIST = 120, ID_PADLIST, ID_KBBIND, ID_PADBIND, ID_KBRESET, ID_PADRESET, ID_CLOSE = 130, ID_STATUS = 131, ID_CROP = 132, ID_RENDER = 133, ID_SHARP = 134, ID_SHARP_T = 135 };
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
        mk(w, "STATIC", "Render res = what the game draws at (restart the game to apply). Fullscreen uses your desktop size.",
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
        g_status = mk(w, "STATIC", "F1 opens / closes this window. Changes apply immediately.", SS_LEFT, 16, 536, 560, 18, ID_STATUS);
        mk(w, "BUTTON", "Close", BS_PUSHBUTTON | WS_TABSTOP, 640, 532, 90, 26, ID_CLOSE);
        fill_lists(); upd_vol_text(w);
        SetTimer(w, 1, 30, NULL);
        return 0;
    }
    case WM_TIMER: tick_capture(); return 0;
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
        else if (id == ID_RENDER && nf == CBN_SELCHANGE) { g_render = (int)SendMessageA((HWND)lp, CB_GETCURSEL, 0, 0); save(); SetWindowTextA(g_status, "Render resolution saved - restart the game to apply it."); }
        else if (id == ID_CROP && nf == BN_CLICKED) { g_crop = (SendMessageA((HWND)lp, BM_GETCHECK, 0, 0) == BST_CHECKED) ? 1 : 0; InterlockedExchange(&g_apply_display, 1); save(); }
        else if (id == ID_KBBIND) begin_capture(1);
        else if (id == ID_PADBIND) begin_capture(2);
        else if (id == ID_KBRESET) { reset_kb(); save(); fill_lists(); }
        else if (id == ID_PADRESET) { reset_pad(); save(); fill_lists(); }
        else if (id == ID_KBLIST && nf == LBN_DBLCLK) begin_capture(1);
        else if (id == ID_PADLIST && nf == LBN_DBLCLK) begin_capture(2);
        else if (id == ID_CLOSE) { save(); ShowWindow(w, SW_HIDE); }
        return 0;
    }
    case WM_CLOSE: end_capture(); save(); ShowWindow(w, SW_HIDE); return 0;
    case WM_APP + 1: {
        if (IsWindowVisible(w)) { end_capture(); ShowWindow(w, SW_HIDE); }
        else { ShowWindow(w, SW_SHOW); SetForegroundWindow(w); }
        return 0;
    }
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
    g_menu = CreateWindowExA(0, "JJSettingsWnd", "Jetpack Joyride - Settings (build 27)", WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN,
                             CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, NULL, NULL, GetModuleHandleA(NULL), NULL);
    MSG msg;
    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
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
        SetForegroundWindow(g_fullscreen ? game : (g_menu && IsWindowVisible(g_menu) ? g_menu : game));
    }
}

} // namespace sm
'@
[IO.File]::WriteAllText((Join-Path $Root 'settings_menu.h'), $hdr)
Write-Host 'wrote settings_menu.h (build 27)' -ForegroundColor Green

& "$PSScriptRoot\04_build.ps1"
if ($LASTEXITCODE) { throw 'build failed - send me build.log' }
& "$PSScriptRoot\play.ps1"
