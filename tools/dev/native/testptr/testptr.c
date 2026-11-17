/* testptr.dll : a TEST-ONLY private mouse pointer for one copy of the game. Never shipped, never loaded by the mod.
 *
 * Why: clicks on the ground (placing, drawing, move orders) cannot be exercised through widget handlers, and the
 * user's real pointer must not be touched while they work. Loaded into a test copy (package.loadlib from the test
 * console), it
 *   1. makes this process read a pointer position of our own (GetCursorPos is redirected in the game's import table),
 *   2. swallows SetCursorPos and ClipCursor, so a test copy can never move or confine the real pointer,
 *   3. posts ordinary mouse messages to the game's own window, read from a command file.
 * The system pointer is never moved and no input is sent to any other window.
 *
 * Use:  f = package.loadlib(<this dll>, "testptr_start"); f()      once per process
 *       then write lines to  <dll folder>\ptr_cmd_<pid>.txt  (client pixels of the game window):
 *         move x y | click x y | rclick x y | down x y | up x y | rdown x y | rup x y | drag x1 y1 x2 y2 [steps]
 *         wheel x y delta | key vk | wait ms | off
 *       answers go to <dll folder>\ptr_log_<pid>.txt
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static volatile LONG g_on = 0;          /* 1 = the game sees our pointer */
static POINT g_pos;                     /* screen coordinates */
static HWND g_wnd;
static char g_dir[MAX_PATH];
static BOOL (WINAPI *real_GetCursorPos)(LPPOINT);
static BOOL (WINAPI *real_SetCursorPos)(int, int);
static BOOL (WINAPI *real_ClipCursor)(const RECT *);
static HWND (WINAPI *real_GetForegroundWindow)(void);

static void logf_(const char *fmt, ...) {
  char p[MAX_PATH + 40], b[512]; va_list a; FILE *f;
  sprintf(p, "%s\\ptr_log_%lu.txt", g_dir, GetCurrentProcessId());
  va_start(a, fmt); vsnprintf(b, sizeof b, fmt, a); va_end(a);
  f = fopen(p, "ab"); if (f) { fprintf(f, "%s\n", b); fclose(f); }
}

static BOOL WINAPI my_GetCursorPos(LPPOINT p) { if (g_on && p) { *p = g_pos; return TRUE; } return real_GetCursorPos(p); }
static BOOL WINAPI my_SetCursorPos(int x, int y) { if (g_on) { g_pos.x = x; g_pos.y = y; } return TRUE; }   /* never the real pointer */
static BOOL WINAPI my_ClipCursor(const RECT *r) { (void)r; return TRUE; }                                    /* never confine */
static HWND WINAPI my_GetForegroundWindow(void) { if (g_on && g_wnd) return g_wnd; return real_GetForegroundWindow(); }

static int patch_iat(HMODULE mod, const char *dll, const char *name, void *repl, void **orig) {
  BYTE *base = (BYTE *)mod; IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
  IMAGE_DATA_DIRECTORY d = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT]; int n = 0;
  HMODULE target = GetModuleHandleA(dll); void *want; IMAGE_IMPORT_DESCRIPTOR *imp;
  if (!d.VirtualAddress || !target) return 0;
  want = (void *)GetProcAddress(target, name); if (!want) return 0;
  *orig = want;
  for (imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + d.VirtualAddress); imp->Name; imp++) {
    IMAGE_THUNK_DATA *t = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
    for (; t->u1.Function; t++) {
      if ((void *)t->u1.Function == want) {
        DWORD old; if (VirtualProtect(&t->u1.Function, sizeof(void *), PAGE_READWRITE, &old)) {
          t->u1.Function = (ULONG_PTR)repl; VirtualProtect(&t->u1.Function, sizeof(void *), old, &old); n++; }
      }
    }
  }
  return n;
}

static BOOL CALLBACK find_wnd(HWND h, LPARAM lp) {
  DWORD pid = 0; char cls[64]; (void)lp;
  GetWindowThreadProcessId(h, &pid);
  if (pid == GetCurrentProcessId() && IsWindowVisible(h) && GetClassNameA(h, cls, sizeof cls) && strcmp(cls, "UnrealWindow") == 0) { g_wnd = h; return FALSE; }
  return TRUE;
}

static void at(int x, int y) { POINT p; p.x = x; p.y = y; ClientToScreen(g_wnd, &p); g_pos = p; InterlockedExchange(&g_on, 1); }
static void post(UINT msg, WPARAM w, int x, int y) { PostMessageA(g_wnd, msg, w, MAKELPARAM(x, y)); }
static void move(int x, int y) { at(x, y); post(WM_MOUSEMOVE, 0, x, y); Sleep(60); }
static void btn(int right, int down, int x, int y) {
  at(x, y);
  if (down) post(right ? WM_RBUTTONDOWN : WM_LBUTTONDOWN, right ? MK_RBUTTON : MK_LBUTTON, x, y);
  else post(right ? WM_RBUTTONUP : WM_LBUTTONUP, 0, x, y);
  Sleep(80);
}

static void run_line(char *s) {
  int a = 0, b = 0, c = 0, d = 0, e = 0; char cmd[16] = "";
  int n = sscanf(s, "%15s %d %d %d %d %d", cmd, &a, &b, &c, &d, &e);
  if (n < 1) return;
  if (!g_wnd) EnumWindows(find_wnd, 0);
  if (!g_wnd) { logf_("no game window: %s", s); return; }
  if (!strcmp(cmd, "move")) { move(a, b); }
  else if (!strcmp(cmd, "click")) { move(a, b); move(a, b); btn(0, 1, a, b); btn(0, 0, a, b); }
  else if (!strcmp(cmd, "rclick")) { move(a, b); move(a, b); btn(1, 1, a, b); btn(1, 0, a, b); }
  else if (!strcmp(cmd, "down")) { move(a, b); btn(0, 1, a, b); }
  else if (!strcmp(cmd, "up")) { move(a, b); btn(0, 0, a, b); }
  else if (!strcmp(cmd, "rdown")) { move(a, b); btn(1, 1, a, b); }
  else if (!strcmp(cmd, "rup")) { move(a, b); btn(1, 0, a, b); }
  else if (!strcmp(cmd, "drag")) {
    int i, steps = (n >= 6 && e > 0) ? e : 12; move(a, b); btn(0, 1, a, b);
    for (i = 1; i <= steps; i++) { int x = a + (c - a) * i / steps, y = b + (d - b) * i / steps; at(x, y); post(WM_MOUSEMOVE, MK_LBUTTON, x, y); Sleep(40); }
    btn(0, 0, c, d);
  }
  else if (!strcmp(cmd, "wheel")) { POINT p; move(a, b); p = g_pos; PostMessageA(g_wnd, WM_MOUSEWHEEL, MAKEWPARAM(0, (short)c), MAKELPARAM(p.x, p.y)); Sleep(60); }
  else if (!strcmp(cmd, "key")) { PostMessageA(g_wnd, WM_KEYDOWN, (WPARAM)a, 1); Sleep(60); PostMessageA(g_wnd, WM_KEYUP, (WPARAM)a, 0xC0000001); Sleep(60); }
  else if (!strcmp(cmd, "wait")) { Sleep((DWORD)a); }
  else if (!strcmp(cmd, "off")) { InterlockedExchange(&g_on, 0); }
  else { logf_("unknown: %s", s); return; }
  logf_("ok %s (pointer %ld,%ld on=%ld)", s, g_pos.x, g_pos.y, g_on);
}

static DWORD WINAPI worker(LPVOID arg) {
  char p[MAX_PATH + 40], t[MAX_PATH + 40]; (void)arg;
  sprintf(p, "%s\\ptr_cmd_%lu.txt", g_dir, GetCurrentProcessId());
  sprintf(t, "%s\\ptr_run_%lu.txt", g_dir, GetCurrentProcessId());
  for (;;) {
    if (MoveFileExA(p, t, MOVEFILE_REPLACE_EXISTING)) {
      FILE *f = fopen(t, "rb");
      if (f) { char line[256]; while (fgets(line, sizeof line, f)) { line[strcspn(line, "\r\n")] = 0; if (line[0]) run_line(line); } fclose(f); }
      DeleteFileA(t); logf_("done");
    }
    Sleep(30);
  }
}

__declspec(dllexport) int __cdecl testptr_start(void *L) {
  static LONG started = 0; HMODULE self = NULL, exe = GetModuleHandleA(NULL); char *slash; int a, b, c, d;
  (void)L;
  if (InterlockedExchange(&started, 1)) return 0;
  GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN, (LPCSTR)&testptr_start, &self);
  GetModuleFileNameA(self, g_dir, MAX_PATH); slash = strrchr(g_dir, '\\'); if (slash) *slash = 0;
  a = patch_iat(exe, "user32.dll", "GetCursorPos", (void *)my_GetCursorPos, (void **)&real_GetCursorPos);
  b = patch_iat(exe, "user32.dll", "SetCursorPos", (void *)my_SetCursorPos, (void **)&real_SetCursorPos);
  c = patch_iat(exe, "user32.dll", "ClipCursor", (void *)my_ClipCursor, (void **)&real_ClipCursor);
  d = patch_iat(exe, "user32.dll", "GetForegroundWindow", (void *)my_GetForegroundWindow, (void **)&real_GetForegroundWindow);
  EnumWindows(find_wnd, 0);
  logf_("started: GetCursorPos %d, SetCursorPos %d, ClipCursor %d, GetForegroundWindow %d import slots redirected; window %p", a, b, c, d, (void *)g_wnd);
  CreateThread(NULL, 0, worker, NULL, 0, NULL);
  return 0;
}
