/* builder.exe - one-window builder for Jetpack Joyride on Windows.
 * Pick your game folder, press Build. It runs scripts\build_all.ps1 (installs missing tools, patches ps3recomp,
 * translates and compiles the game) and leaves JetPackJoyride.exe in the install folder.
 * Needs the folders next to it: scripts\, patches\, project\, launcher\. Runs elevated (installing tools needs it). */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

enum { ID_DUMP = 101, ID_DUMP_B, ID_DEC, ID_DEC_B, ID_FLASH, ID_FLASH_B, ID_DEST, ID_DEST_B,
       ID_BUILD, ID_PROG, ID_STATUS, ID_LOG, ID_PLAY, ID_OPEN };
#define WM_LOGCHUNK (WM_APP + 1)   /* lParam = malloc'd wchar_t* (CRLF text) */
#define WM_BUILDDONE (WM_APP + 2)  /* wParam = exit code */

static HWND g_wnd, g_dump, g_dec, g_flash, g_dest, g_build, g_prog, g_status, g_log, g_play, g_open;
static HANDLE g_job, g_thread;
static volatile LONG g_running;
static wchar_t g_exedir[MAX_PATH], g_kit[MAX_PATH], g_ini[MAX_PATH], g_failmsg[1024];
static HFONT g_font, g_mono;

/* The build kit (scripts\, patches\, project\, launcher\) is next to builder.exe, or one folder up (builder\builder.exe in the repo). */
static BOOL kit_ok(const wchar_t* dir)
{
    wchar_t p[MAX_PATH + 40]; swprintf(p, MAX_PATH + 40, L"%ls\\scripts\\build_all.ps1", dir);
    return GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES;
}
static void find_kit(void)
{
    wcscpy(g_kit, g_exedir);
    if (kit_ok(g_kit)) return;
    wchar_t up[MAX_PATH]; wcscpy(up, g_exedir);
    wchar_t* sl = wcsrchr(up, L'\\'); if (sl) *sl = 0;
    if (up[0] && kit_ok(up)) wcscpy(g_kit, up);
}

static void trim(wchar_t* s)
{
    size_t n = wcslen(s), a = 0;
    while (n && (s[n - 1] == L' ' || s[n - 1] == L'\t' || s[n - 1] == L'\r' || s[n - 1] == L'\n')) s[--n] = 0;
    while (s[a] == L' ' || s[a] == L'\t') a++;
    if (a) memmove(s, s + a, (n - a + 1) * sizeof(wchar_t));
    n = wcslen(s);
    if (n >= 2 && s[0] == L'"' && s[n - 1] == L'"') { memmove(s, s + 1, (n - 2) * sizeof(wchar_t)); s[n - 2] = 0; }
    n = wcslen(s);
    while (n > 3 && (s[n - 1] == L'\\' || s[n - 1] == L'/')) s[--n] = 0;   /* a trailing \ would break "quoted" arguments */
}
static void get_text(HWND h, wchar_t* out, int cap) { GetWindowTextW(h, out, cap); trim(out); }

static void log_append(const wchar_t* t)
{
    int len = GetWindowTextLengthW(g_log);
    if (len > 3000000) {                                   /* keep the control fast: drop the oldest half */
        SendMessageW(g_log, EM_SETSEL, 0, len / 2);
        SendMessageW(g_log, EM_REPLACESEL, FALSE, (LPARAM)L"");
        len = GetWindowTextLengthW(g_log);
    }
    SendMessageW(g_log, EM_SETSEL, len, len);
    SendMessageW(g_log, EM_REPLACESEL, FALSE, (LPARAM)t);
}

/* handle ##STEP / ##FAILED / ##DONE marker lines in a chunk of text */
static void scan_markers(const wchar_t* t)
{
    const wchar_t* p = t;
    while (*p) {
        const wchar_t* e = p; while (*e && *e != L'\r' && *e != L'\n') e++;
        if (!wcsncmp(p, L"##STEP ", 7)) {
            int n = 0, N = 0; const wchar_t* q = p + 7;
            if (swscanf(q, L"%d/%d", &n, &N) == 2 && N > 0) {
                while (*q && *q != L' ') q++;
                while (*q == L' ') q++;
                wchar_t msg[300]; size_t l = (size_t)(e - q); if (l > 250) l = 250;
                wmemcpy(msg, q, l); msg[l] = 0;
                wchar_t st[400]; swprintf(st, 400, L"Step %d of %d: %ls", n, N, msg);
                SetWindowTextW(g_status, st);
                SendMessageW(g_prog, PBM_SETPOS, (WPARAM)((n - 1) * 100 / N), 0);
            }
        } else if (!wcsncmp(p, L"##FAILED ", 9)) {
            size_t l = (size_t)(e - (p + 9)); if (l > 1000) l = 1000;
            wmemcpy(g_failmsg, p + 9, l); g_failmsg[l] = 0;
        }
        while (*e == L'\r' || *e == L'\n') e++;
        p = e;
    }
}

static void post_chunk(const char* s, size_t len)
{
    if (!len) return;
    int wl = MultiByteToWideChar(CP_UTF8, 0, s, (int)len, NULL, 0);
    if (wl <= 0) return;
    wchar_t* w = (wchar_t*)malloc((size_t)wl * sizeof(wchar_t));
    if (!w) return;
    MultiByteToWideChar(CP_UTF8, 0, s, (int)len, w, wl);
    wchar_t* o = (wchar_t*)malloc(((size_t)wl * 2 + 1) * sizeof(wchar_t));   /* normalise to CRLF */
    if (!o) { free(w); return; }
    size_t k = 0;
    for (int i = 0; i < wl; i++) {
        if (w[i] == L'\r') { if (i + 1 < wl && w[i + 1] == L'\n') i++; o[k++] = L'\r'; o[k++] = L'\n'; }
        else if (w[i] == L'\n') { o[k++] = L'\r'; o[k++] = L'\n'; }
        else if (w[i] == 0) continue;
        else o[k++] = w[i];
    }
    o[k] = 0; free(w);
    PostMessageW(g_wnd, WM_LOGCHUNK, 0, (LPARAM)o);
}

static DWORD WINAPI worker(LPVOID unused)
{
    (void)unused;
    wchar_t dump[MAX_PATH], dec[MAX_PATH], flash[MAX_PATH], dest[MAX_PATH];
    get_text(g_dump, dump, MAX_PATH); get_text(g_dec, dec, MAX_PATH); get_text(g_flash, flash, MAX_PATH); get_text(g_dest, dest, MAX_PATH);
    wchar_t cmd[4096];
    swprintf(cmd, 4096, L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%ls\\scripts\\build_all.ps1\" "
             L"-Dump \"%ls\" -Decrypted \"%ls\" -DevFlash \"%ls\" -Dest \"%ls\"", g_kit, dump, dec, flash, dest);

    SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
    HANDLE rd = NULL, wr = NULL;
    DWORD code = 1;
    if (!CreatePipe(&rd, &wr, &sa, 0)) { post_chunk("Could not create a pipe.\n", 25); PostMessageW(g_wnd, WM_BUILDDONE, 1, 0); return 0; }
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOW si; PROCESS_INFORMATION pi; memset(&si, 0, sizeof si); memset(&pi, 0, sizeof pi);
    si.cb = sizeof si; si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = wr; si.hStdError = wr; si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED, NULL, g_kit, &si, &pi)) {
        char m[200]; int n = snprintf(m, sizeof m, "Could not start PowerShell (error %lu).\n", GetLastError());
        post_chunk(m, (size_t)n);
        CloseHandle(rd); CloseHandle(wr);
        PostMessageW(g_wnd, WM_BUILDDONE, 1, 0); return 0;
    }
    CloseHandle(wr);
    if (g_job) AssignProcessToJobObject(g_job, pi.hProcess);     /* closing the builder stops the whole build tree */
    ResumeThread(pi.hThread);

    char buf[8192], acc[70000]; size_t acclen = 0;
    for (;;) {
        DWORD n = 0;
        if (!ReadFile(rd, buf, sizeof buf, &n, NULL) || n == 0) break;
        if (acclen + n > sizeof acc) { post_chunk(acc, acclen); acclen = 0; }
        memcpy(acc + acclen, buf, n); acclen += n;
        size_t cut = 0;
        for (size_t i = acclen; i > 0; i--) if (acc[i - 1] == '\n' || acc[i - 1] == '\r') { cut = i; break; }
        if (cut) { post_chunk(acc, cut); memmove(acc, acc + cut, acclen - cut); acclen -= cut; }
    }
    if (acclen) post_chunk(acc, acclen);
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess); CloseHandle(rd);
    PostMessageW(g_wnd, WM_BUILDDONE, (WPARAM)code, 0);
    return 0;
}

static void save_log_file(const wchar_t* dest)
{
    wchar_t path[MAX_PATH + 32];
    swprintf(path, MAX_PATH + 32, L"%ls\\builder.log", dest);
    int len = GetWindowTextLengthW(g_log);
    if (len <= 0) return;
    wchar_t* w = (wchar_t*)malloc((size_t)(len + 1) * sizeof(wchar_t));
    if (!w) return;
    GetWindowTextW(g_log, w, len + 1);
    int ul = WideCharToMultiByte(CP_UTF8, 0, w, len, NULL, 0, NULL, NULL);
    char* u = (char*)malloc((size_t)ul + 1);
    if (u) {
        WideCharToMultiByte(CP_UTF8, 0, w, len, u, ul, NULL, NULL);
        HANDLE f = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (f != INVALID_HANDLE_VALUE) { DWORD wrote; WriteFile(f, u, (DWORD)ul, &wrote, NULL); CloseHandle(f); }
        free(u);
    }
    free(w);
}

static void set_enabled(BOOL on)
{
    HWND c[] = { g_dump, g_dec, g_flash, g_dest, g_build };
    for (int i = 0; i < 5; i++) EnableWindow(c[i], on);
    for (int id = ID_DUMP_B; id <= ID_DEST_B; id += 2) EnableWindow(GetDlgItem(g_wnd, id), on);
}

static void browse(HWND edit, const wchar_t* title)
{
    BROWSEINFOW bi; memset(&bi, 0, sizeof bi);
    wchar_t disp[MAX_PATH];
    bi.hwndOwner = g_wnd; bi.pszDisplayName = disp; bi.lpszTitle = title;
    bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_EDITBOX;
    PIDLIST_ABSOLUTE pidl = SHBrowseForFolderW(&bi);
    if (pidl) {
        wchar_t path[MAX_PATH];
        if (SHGetPathFromIDListW(pidl, path)) SetWindowTextW(edit, path);
        CoTaskMemFree(pidl);
    }
}

static void start_build(void)
{
    wchar_t dump[MAX_PATH], dest[MAX_PATH], dec[MAX_PATH], flash[MAX_PATH], chk[MAX_PATH + 40];
    get_text(g_dump, dump, MAX_PATH); get_text(g_dest, dest, MAX_PATH); get_text(g_dec, dec, MAX_PATH); get_text(g_flash, flash, MAX_PATH);
    if (!dump[0]) { MessageBoxW(g_wnd, L"Please choose your game folder (the one called NPUB31615).", L"Jetpack Joyride Builder", MB_ICONINFORMATION); return; }
    swprintf(chk, MAX_PATH + 40, L"%ls\\PARAM.SFO", dump);
    if (GetFileAttributesW(chk) == INVALID_FILE_ATTRIBUTES) {
        MessageBoxW(g_wnd, L"PARAM.SFO was not found in that folder.\n\nChoose the game folder itself (NPUB31615), the one that contains PARAM.SFO and USRDIR.",
                    L"Jetpack Joyride Builder", MB_ICONWARNING); return;
    }
    if (!dest[0]) { MessageBoxW(g_wnd, L"Please choose where to install the game.", L"Jetpack Joyride Builder", MB_ICONINFORMATION); return; }
    if (wcschr(dest, L' ')) { MessageBoxW(g_wnd, L"The install folder must not contain spaces.\nUse something like C:\\JetpackJoyride.", L"Jetpack Joyride Builder", MB_ICONWARNING); return; }
    find_kit();
    if (!kit_ok(g_kit)) {
        wchar_t m[1200];
        swprintf(m, 1200, L"The build kit was not found.\n\nbuilder.exe is in:\n%ls\n\nIt looked for scripts\\build_all.ps1 there and one folder up, "
                 L"and did not find it. Keep builder.exe together with the scripts, patches, project and launcher folders of the same download "
                 L"(and make sure scripts\\build_all.ps1 is the new version).", g_exedir);
        MessageBoxW(g_wnd, m, L"Jetpack Joyride Builder", MB_ICONERROR); return;
    }
    if (MessageBoxW(g_wnd, L"This will install any missing tools (Git, Python, Visual Studio Build Tools) and then build the game.\n"
                    L"It needs about 15 GB of disk space and can take one to a few hours. Continue?", L"Jetpack Joyride Builder", MB_YESNO | MB_ICONQUESTION) != IDYES) return;

    WritePrivateProfileStringW(L"paths", L"dump", dump, g_ini);  WritePrivateProfileStringW(L"paths", L"decrypted", dec, g_ini);
    WritePrivateProfileStringW(L"paths", L"devflash", flash, g_ini); WritePrivateProfileStringW(L"paths", L"dest", dest, g_ini);

    g_failmsg[0] = 0;
    SetWindowTextW(g_log, L"");
    SendMessageW(g_prog, PBM_SETPOS, 0, 0);
    SetWindowTextW(g_status, L"Starting...");
    EnableWindow(g_play, FALSE); EnableWindow(g_open, FALSE);
    set_enabled(FALSE);
    g_running = 1;
    g_thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
}

static void on_done(DWORD code)
{
    wchar_t dest[MAX_PATH];
    get_text(g_dest, dest, MAX_PATH);
    g_running = 0; set_enabled(TRUE);
    if (g_thread) { CloseHandle(g_thread); g_thread = NULL; }
    CreateDirectoryW(dest, NULL);
    save_log_file(dest);
    if (code == 0) {
        SendMessageW(g_prog, PBM_SETPOS, 100, 0);
        SetWindowTextW(g_status, L"Done! Press Play to start the game.");
        EnableWindow(g_play, TRUE); EnableWindow(g_open, TRUE);
        MessageBoxW(g_wnd, L"The game is built.\n\nPress Play (or run JetPackJoyride.exe in the install folder).\nIn the game: F1 = settings, F11 = fullscreen.",
                    L"Jetpack Joyride Builder", MB_ICONINFORMATION);
    } else {
        wchar_t m[1400];
        SetWindowTextW(g_status, L"The build stopped - see the message and the log below.");
        EnableWindow(g_open, TRUE);
        swprintf(m, 1400, L"The build did not finish.\n\n%ls\n\nThe full log was saved as builder.log in the install folder. Fix the problem and press Build again; finished steps are reused.",
                 g_failmsg[0] ? g_failmsg : L"(no message - see the log)");
        MessageBoxW(g_wnd, m, L"Jetpack Joyride Builder", MB_ICONERROR);
    }
}

static HWND mk(const wchar_t* cls, const wchar_t* text, DWORD style, DWORD ex, int x, int y, int w, int h, int id)
{
    HWND c = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h, g_wnd, (HMENU)(INT_PTR)id, GetModuleHandleW(NULL), NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)g_font, TRUE);
    return c;
}

static void row(int y, const wchar_t* label, const wchar_t* ini_key, const wchar_t* def, HWND* edit, int editid, int btnid)
{
    wchar_t v[MAX_PATH];
    mk(L"STATIC", label, SS_LEFT, 0, 16, y, 640, 18, 0);
    GetPrivateProfileStringW(L"paths", ini_key, def, v, MAX_PATH, g_ini);
    *edit = mk(L"EDIT", v, WS_TABSTOP | ES_AUTOHSCROLL, WS_EX_CLIENTEDGE, 16, y + 20, 620, 24, editid);
    mk(L"BUTTON", L"Browse...", BS_PUSHBUTTON | WS_TABSTOP, 0, 646, y + 19, 90, 26, btnid);
}

static LRESULT CALLBACK wndproc(HWND w, UINT m, WPARAM wp, LPARAM lp)
{
    switch (m) {
    case WM_CREATE: {
        g_wnd = w;
        g_font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
        g_mono = CreateFontW(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, FIXED_PITCH, L"Consolas");
        row(12,  L"1. Your game folder - the folder called NPUB31615 (contains PARAM.SFO and USRDIR):", L"dump", L"", &g_dump, ID_DUMP, ID_DUMP_B);
        row(62,  L"2. Decrypted files folder (EBOOT.elf, jet.pak, sound.pak) - optional, looked for next to the game folder:", L"decrypted", L"", &g_dec, ID_DEC, ID_DEC_B);
        row(112, L"3. PS3 firmware dev_flash folder - optional, found automatically if RPCS3 is installed:", L"devflash", L"", &g_flash, ID_FLASH, ID_FLASH_B);
        row(162, L"4. Where to build and install the game (short path, no spaces; needs about 15 GB):", L"dest", L"C:\\JetpackJoyride", &g_dest, ID_DEST, ID_DEST_B);
        g_build = mk(L"BUTTON", L"Build", BS_DEFPUSHBUTTON | WS_TABSTOP, 0, 16, 218, 120, 32, ID_BUILD);
        g_play = mk(L"BUTTON", L"Play", BS_PUSHBUTTON | WS_TABSTOP | WS_DISABLED, 0, 146, 218, 100, 32, ID_PLAY);
        g_open = mk(L"BUTTON", L"Open folder", BS_PUSHBUTTON | WS_TABSTOP | WS_DISABLED, 0, 256, 218, 110, 32, ID_OPEN);
        g_status = mk(L"STATIC", L"Choose your game folder and press Build.", SS_LEFT, 0, 380, 226, 356, 20, ID_STATUS);
        g_prog = mk(PROGRESS_CLASSW, L"", PBS_SMOOTH, 0, 16, 258, 720, 16, ID_PROG);
        g_log = mk(L"EDIT", L"", WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_TABSTOP, WS_EX_CLIENTEDGE, 16, 282, 720, 262, ID_LOG);
        SendMessageW(g_log, WM_SETFONT, (WPARAM)g_mono, TRUE);
        SendMessageW(g_log, EM_SETLIMITTEXT, 0x7FFFFFF0, 0);
        return 0;
    }
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_DUMP_B:  browse(g_dump,  L"Choose your game folder (NPUB31615)"); break;
        case ID_DEC_B:   browse(g_dec,   L"Choose the folder with the decrypted EBOOT.elf, jet.pak and sound.pak"); break;
        case ID_FLASH_B: browse(g_flash, L"Choose the PS3 dev_flash folder"); break;
        case ID_DEST_B:  browse(g_dest,  L"Choose where to build the game"); break;
        case ID_BUILD:   if (!g_running) start_build(); break;
        case ID_PLAY: {
            wchar_t dest[MAX_PATH], exe[MAX_PATH + 40];
            get_text(g_dest, dest, MAX_PATH); swprintf(exe, MAX_PATH + 40, L"%ls\\JetPackJoyride.exe", dest);
            ShellExecuteW(w, L"open", exe, NULL, dest, SW_SHOWNORMAL); break;
        }
        case ID_OPEN: {
            wchar_t dest[MAX_PATH]; get_text(g_dest, dest, MAX_PATH);
            ShellExecuteW(w, L"open", dest, NULL, NULL, SW_SHOWNORMAL); break;
        }
        }
        return 0;
    case WM_LOGCHUNK: {
        wchar_t* t = (wchar_t*)lp;
        if (t) { scan_markers(t); log_append(t); free(t); }
        return 0;
    }
    case WM_BUILDDONE: on_done((DWORD)wp); return 0;
    case WM_CLOSE:
        if (g_running && MessageBoxW(w, L"A build is running. Stop it and close?", L"Jetpack Joyride Builder", MB_YESNO | MB_ICONQUESTION) != IDYES) return 0;
        DestroyWindow(w); return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(w, m, wp, lp);
}

int WINAPI wWinMain(HINSTANCE hi, HINSTANCE hp, LPWSTR cl, int show)
{
    (void)hp; (void)cl;
    GetModuleFileNameW(NULL, g_exedir, MAX_PATH);
    { wchar_t* sl = wcsrchr(g_exedir, L'\\'); if (sl) *sl = 0; }
    swprintf(g_ini, MAX_PATH, L"%ls\\builder.ini", g_exedir);
    OleInitialize(NULL);
    INITCOMMONCONTROLSEX ic = { sizeof ic, ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&ic);

    g_job = CreateJobObjectW(NULL, NULL);
    if (g_job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION li; memset(&li, 0, sizeof li);
        li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &li, sizeof li);
    }
    WNDCLASSW wc; memset(&wc, 0, sizeof wc);
    wc.lpfnWndProc = wndproc; wc.hInstance = hi; wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1); wc.lpszClassName = L"JJBuilderWnd";
    wc.hIcon = LoadIconW(NULL, IDI_APPLICATION);
    RegisterClassW(&wc);
    RECT r = { 0, 0, 752, 560 };
    AdjustWindowRect(&r, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, FALSE);
    HWND w = CreateWindowExW(0, wc.lpszClassName, L"Jetpack Joyride PC Builder",
                             WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
                             CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, NULL, NULL, hi, NULL);
    if (!w) return 1;
    ShowWindow(w, show); UpdateWindow(w);
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (!IsDialogMessageW(w, &msg)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    }
    return 0;
}
