/* count_opens.h - (lane 65) forced into the TEST build of coop_patch.dll only (build.cmd: /FI). Every file the DLL opens
 * (CreateFileW, _wfopen) and every attribute look (GetFileAttributesExW, GetFileAttributesW) is counted; the mechanism
 * test reads the counts with the export coop_patch_test_opens. The shipped DLL is built without it. */
#define WIN32_LEAN_AND_MEAN
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#include <windows.h>
#include <stdio.h>
static volatile LONG g_t_opens, g_t_looks;
static HANDLE t_CreateFileW(LPCWSTR p, DWORD acc, DWORD share, LPSECURITY_ATTRIBUTES sa, DWORD disp, DWORD fl, HANDLE tpl)
{ InterlockedIncrement(&g_t_opens); return CreateFileW(p, acc, share, sa, disp, fl, tpl); }
static FILE *t_wfopen(const wchar_t *p, const wchar_t *m) { InterlockedIncrement(&g_t_opens); return _wfopen(p, m); }
static BOOL t_GetFileAttributesExW(LPCWSTR p, GET_FILEEX_INFO_LEVELS lv, LPVOID out) { InterlockedIncrement(&g_t_looks); return GetFileAttributesExW(p, lv, out); }
static DWORD t_GetFileAttributesW(LPCWSTR p) { InterlockedIncrement(&g_t_looks); return GetFileAttributesW(p); }
__declspec(dllexport) void __cdecl coop_patch_test_opens(long *opens, long *looks) { *opens = g_t_opens; *looks = g_t_looks; }
#define CreateFileW t_CreateFileW
#define _wfopen t_wfopen
#define GetFileAttributesExW t_GetFileAttributesExW
#define GetFileAttributesW t_GetFileAttributesW
