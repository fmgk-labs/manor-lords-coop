/* image_test.c - runs the SHIPPED coop_patch.dll (no test switch) against this program's own image-backed .text.
 *
 * This program carries the P1 byte pattern inside its real .text section (a mapped image, like the game's), so the
 * shipped DLL scans GetModuleHandleW(NULL) exactly as it will in the game and writes through the copy-on-write path of
 * an image page. Only P1 can match here (no TriggerSquadRetreat / reformSquad), so P2/P3/ROUT/REFORM must say
 * "unavailable". The DLL is copied into out\test\image\ first, so no command or status file lands beside out\coop_patch.dll.
 * Usage: image_test.exe <path to the shipped coop_patch.dll>       exit code 0 = every check passed
 */
#define WIN32_LEAN_AND_MEAN
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

/* P1 at offset 7 of a 16-aligned block: the patch (offset 7 + 21 = 28) is at byte 4 of an aligned qword, like the game */
/* own section, merged into .text by the linker (/MERGE:.ptext=.text in build.cmd): one .text, like the game */
#pragma section(".ptext", read, execute)
__declspec(allocate(".ptext")) __declspec(align(16)) const unsigned char g_p1_blob[64] = {
    0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC,
    0x44, 0x0F, 0x2F, 0xBE, 0xE8, 0x02, 0x00, 0x00, 0x0F, 0x82, 0x11, 0x22, 0x33, 0x00, 0x80, 0xBD, 0x48, 0x04, 0x00,
    0x00, 0x00, 0x74, 0x1C, 0xC7, 0x86, 0xE8, 0x02, 0x00, 0x00, 0x00, 0x00, 0x80, 0x3F, 0xE9, 0x44, 0x55, 0x66, 0x00,
    0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC
};

typedef int (__cdecl *tick_fn)(void *);
static int g_pass, g_fail;
static wchar_t g_dir[MAX_PATH];
static char g_buf[8192];

static void check(int ok, const char *what) { printf("  %s  %s\n", ok ? "PASS" : "FAIL", what); if (ok) g_pass++; else g_fail++; }

static const char *status(void)
{
    wchar_t p[MAX_PATH]; FILE *f; size_t n;
    _snwprintf(p, MAX_PATH, L"%spatch_status.txt", g_dir);
    g_buf[0] = 0;
    f = _wfopen(p, L"rb"); if (!f) return g_buf;
    n = fread(g_buf, 1, sizeof(g_buf) - 1, f); g_buf[n] = 0; fclose(f);
    return g_buf;
}

static void send(const char *line)
{
    wchar_t p[MAX_PATH]; FILE *f;
    _snwprintf(p, MAX_PATH, L"%spatch_cmd.txt", g_dir);
    f = _wfopen(p, L"ab"); if (f) { fputs(line, f); fputs("\n", f); fclose(f); }
}

int main(int argc, char **argv)
{
    wchar_t src[MAX_PATH], dst[MAX_PATH], exe[MAX_PATH], *sl, tmp[MAX_PATH];
    HMODULE h;
    tick_fn tick;
    const volatile unsigned char *patch = g_p1_blob + 28;
    MEMORY_BASIC_INFORMATION mi;
    char line[80];
    IMAGE_NT_HEADERS64 *nt;

    if (argc < 2) { printf("usage: image_test <coop_patch.dll>\n"); return 2; }
    MultiByteToWideChar(CP_ACP, 0, argv[1], -1, src, MAX_PATH);
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    sl = wcsrchr(exe, L'\\'); sl[1] = 0;
    _snwprintf(g_dir, MAX_PATH, L"%simage\\", exe);
    CreateDirectoryW(g_dir, NULL);
    _snwprintf(dst, MAX_PATH, L"%scoop_patch.dll", g_dir);
    _snwprintf(tmp, MAX_PATH, L"%spatch_cmd.txt", g_dir); DeleteFileW(tmp);
    _snwprintf(tmp, MAX_PATH, L"%spatch_status.txt", g_dir); DeleteFileW(tmp);
    _snwprintf(tmp, MAX_PATH, L"%scoop_patch.log", g_dir); DeleteFileW(tmp);
    SetEnvironmentVariableW(L"COOP_NAME", NULL); SetEnvironmentVariableW(L"COOP_ROLE", NULL);
    if (!CopyFileW(src, dst, FALSE)) { printf("cannot copy the DLL\n"); return 2; }

    printf("\n[shipped DLL against this program's own image-backed .text]\n");
    VirtualQuery((const void *)patch, &mi, sizeof(mi));
    check(mi.Type == MEM_IMAGE && mi.Protect == PAGE_EXECUTE_READ, "(setup) the P1 bytes sit in an image-backed PAGE_EXECUTE_READ page");
    check(((uintptr_t)patch & 7) == 4 && patch[0] == 0x74 && patch[1] == 0x1C, "(setup) patch bytes 74 1C at byte 4 of an aligned qword");

    h = LoadLibraryW(dst);
    tick = h ? (tick_fn)(void *)GetProcAddress(h, "coop_patch_tick") : NULL;
    check(tick != NULL, "package.loadlib equivalent: LoadLibrary + GetProcAddress(coop_patch_tick)");
    if (!tick) return 1;
    check(GetProcAddress(h, "coop_patch_test_use_module") == NULL, "the shipped DLL has no test export");
    check(tick(NULL) == 0, "first tick returns 0");
    /* lane 47: the shipped DLL scans on a thread of its own; until its hits are evaluated the status says "scanning" */
    check(strncmp(status(), "scanning", 8) == 0, "lane 47: after the first tick the status says 'scanning' (the scan runs on its own thread)");
    {   int w = 0; DWORD t0 = GetTickCount(), t1, a, longest = 0;
        while (strncmp(status(), "scanning", 8) == 0 && w < 2000) { Sleep(5); a = GetTickCount(); tick(NULL); a = GetTickCount() - a; if (a > longest) longest = a; w++; }
        t1 = GetTickCount();
        printf("  (lane 47: %d more ticks, %lu ms, until the scan was done; longest tick %lu ms)\n", w, t1 - t0, longest);
        check(w > 0 && w < 2000, "lane 47: the scan's thread finishes and a later tick evaluates it");
        check(longest < 50, "lane 47: no tick of the game thread over 50 ms meanwhile");
    }
    nt = (IMAGE_NT_HEADERS64 *)((uint8_t *)GetModuleHandleW(NULL) + ((IMAGE_DOS_HEADER *)GetModuleHandleW(NULL))->e_lfanew);
    _snprintf(line, sizeof(line), "ready %X %X\r\n", nt->FileHeader.TimeDateStamp, nt->OptionalHeader.SizeOfImage);
    check(strncmp(status(), line, strlen(line)) == 0, "status line 1 'ready' with this program's timestamp and size");
    check(strstr(status(), "P1 off\r\n") != NULL, "P1 found exactly once, off");
    check(strstr(status(), "P2 unavailable") && strstr(status(), "P3a unavailable") && strstr(status(), "P3b unavailable"), "P2/P3 unavailable (no such code here)");
    check(strstr(status(), "ROUT unavailable") && strstr(status(), "REFORM unavailable") && strstr(status(), "FINISH unavailable"), "ROUT/REFORM/FINISH unavailable");

    send("NOKILL ON"); tick(NULL);
    check(patch[0] == 0x66 && patch[1] == 0x90, "NOKILL ON wrote 66 90 into the image-backed .text");
    VirtualQuery((const void *)patch, &mi, sizeof(mi));
    check(mi.Protect == PAGE_EXECUTE_READ, "page protection restored to PAGE_EXECUTE_READ after the write");
    check(strstr(status(), "P1 on\r\n") != NULL, "status P1 on");
    send("ROUT 4096 5"); tick(NULL);
    check(strstr(status(), "calls rout=0 reform=0 finish=0 burn=0 fireout=0 failed=1") != NULL, "ROUT refused while unavailable");
    send("NOKILL OFF"); tick(NULL);
    check(patch[0] == 0x74 && patch[1] == 0x1C, "NOKILL OFF restored 74 1C");
    send("ALLOFF"); send("STATUS"); tick(NULL);
    check(strstr(status(), "P1 off\r\n") != NULL, "ALLOFF + STATUS: P1 off");

    printf("\nRESULT: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
