/* coop_patch.c - Manor Lords co-op: tiny reversible code patches for a friend's copy, and two game calls.
 *
 * Why: in co-op the host decides every death and every rout. A friend's copy must not kill or rout on its own.
 * A static read of the game (research\2026-11-10-game-probe\registry\native5\report.txt) found 2-byte patches:
 *   P1  NOKILL   CombatHit death check "74 1C" -> "66 90": health <= 0 becomes health = 1.0   (report answer 4 (b))
 *   P2  NOROUT   calculateMorale's call to TriggerSquadRetreat jumped over ("E8 xx" -> "EB 03") (report answer 5)
 *   P3a/P3b NOREFORM  the two calls to reformSquad jumped over the same way                   (report answer 5, optional)
 * and two functions the host's decisions are replayed with:
 *   ROUT    TriggerSquadRetreat(USquadComponent*, int handle)   (report answer 5, native4)
 *   REFORM  reformSquad(USquadComponent*, int handle)           (native4_orders_rout_ai.md section 2)
 *   FINISH  finishConstruction(SMBuildingMaster*)               (lanes\lane_w\report_W.txt answer 1)
 *
 * How it is used: the mod's Lua does  f = package.loadlib(<path>, "coop_patch_tick")  and calls f() once per frame
 * on the game thread. The function never touches the Lua state and always returns 0. Input and output are files in
 * one folder (by default this DLL's folder; "dir=" in coop_patch.cfg beside the DLL overrides it; when the
 * environment variable COOP_NAME is set - else COOP_ROLE - the folder gets a subfolder of that name, so two copies of
 * the game on one PC do not read each other's commands):
 *   patch_cmd.txt     the mod appends one command per line; this DLL tails it from where it was at the first tick
 *   patch_status.txt  rewritten atomically (temp file + MoveFileEx) whenever something changes, and on STATUS
 *   coop_patch.log    one line per event (about 256 KB, then moved to coop_patch.log.old)
 * Formats: README.md.
 *
 * Safety (report answer 6): .text only, exactly one hit per signature, original bytes checked, call targets checked,
 * each patch inside one aligned 8-byte block written with one InterlockedCompareExchange64, read back after writing.
 * Nothing escapes coop_patch_tick: every step runs under __try/__except. Three internal failures switch the DLL off
 * and put every patched byte back.
 *
 * Build: build.cmd (MSVC x64, /MT, /W4). The test build (/DCOOP_PATCH_TEST) adds coop_patch_test_use_module() so a
 * test program can point the scan at a synthetic module, and a TESTFAULT command; the shipped DLL has neither.
 */
#define WIN32_LEAN_AND_MEAN
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <limits.h>
#include "coop_scan.h"

#define COOP_PATCH_VERSION "0.9.1"
#define LOG_CAP            (256u * 1024u)
#define MAX_LINE           4096       /* lane 22: a TOTALS SET line names every good of a region (512 was too short live) */
#define READ_CHUNK         65536
#define MAX_FAILURES       3
#define COMP_CHECK_BYTES   0x100      /* bytes of the SquadComponent that must be readable before a call */

typedef void (*squad_fn)(void *comp, int handle);    /* Microsoft x64: rcx = comp, edx = handle, returns void */
typedef void (*building_fn)(void *building);         /* finishConstruction, extinguishFire: rcx = SMBuildingMaster*, returns void */
typedef void (*burn_fn)(void *building, float dt);   /* progressFire: rcx = SMBuildingMaster*, xmm1 = seconds, returns void */
#define ONFIRE_OFFSET 0x388                          /* SMBuildingMaster.onFire (reflected BoolProperty; lane_f) */

/* ------------------------------------------------------------------ state (game thread only) */
static int       g_inited;
static int       g_off;                     /* 1 = switched off (line 1 "off <reason>") */
static char      g_off_reason[160];
static int       g_failures;                /* internal failures; MAX_FAILURES -> off */
static int       g_in_tick;
static wchar_t   g_dir[MAX_PATH];           /* I/O folder, ends with a backslash */
static wchar_t   g_moddir[MAX_PATH];        /* lane 61: this DLL's own folder (the mod folder), ends with a backslash */
static wchar_t   g_cmd_path[MAX_PATH], g_status_path[MAX_PATH], g_status_tmp[MAX_PATH], g_log_path[MAX_PATH], g_log_old[MAX_PATH];
static ULONGLONG g_cmd_off;                 /* bytes of patch_cmd.txt already consumed */
static int       g_dirty;                   /* status must be rewritten at the end of this tick */

static uint8_t  *g_base;                    /* module scanned (the game's main module) */
static uint32_t  g_stamp, g_imgsize;
static uint8_t  *g_text; static uint32_t g_text_rva; static size_t g_text_len;

static sig_pat   g_pat[S_DLL_COUNT];
static sig_hit   g_hit[S_DLL_COUNT];
static site_eval g_site[S_DLL_COUNT];       /* used for S_P1..S_P3B */
#define CALL_TYPES 5
static const char *const CALL_NAME[CALL_TYPES] = { "ROUT", "REFORM", "FINISH", "BURN", "FIREOUT" };
static const int CALL_SIG[CALL_TYPES]          = { S_TSR, S_REFORM, S_FINISH, S_BURN, S_FIREOUT };
static int       g_call_ok[CALL_TYPES];     /* 0 = ROUT, 1 = REFORM, 2 = FINISH: entry found and never faulted */
static char      g_call_why[CALL_TYPES][120];
static unsigned  g_calls_n[CALL_TYPES], g_calls_failed;
static volatile LONG g_scan_busy;           /* lane 47: 1 while the scan's thread reads .text */
static int       g_scan_done;               /* lane 47: the scan's hits were evaluated (scan_end) */

#ifdef COOP_PATCH_TEST
static uint8_t *g_test_base;
#endif

static void join_path(wchar_t *out, const wchar_t *dir, const wchar_t *name);
#include "coop_cost.h"                      /* lane 45: the tick's own cost, the status file written only when changed */
#include "coop_scrub.h"                     /* lane 61: no user name, Steam name or whole Steam id in what is written */

/* ------------------------------------------------------------------ log */
static void log_line(const char *fmt, ...)
{
    char msg[700], line[800];
    va_list ap;
    SYSTEMTIME t;
    HANDLE h;
    LARGE_INTEGER sz;
    DWORD wr;
    int n;
    unsigned long long co0;
    if (!g_log_path[0]) return;
    co0 = co_now();                                       /* lane 45 */
    va_start(ap, fmt);
    _vsnprintf(msg, sizeof(msg) - 1, fmt, ap);
    msg[sizeof(msg) - 1] = 0;
    va_end(ap);
    {   char sm[sizeof(msg)];                             /* lane 61: the folder line and every path: no user name */
        size_t sn = scrub_buf(msg, strlen(msg), sm, sizeof(sm) - 1);
        sm[sn] = 0; memcpy(msg, sm, sn + 1);
    }
    GetLocalTime(&t);
    n = _snprintf(line, sizeof(line) - 3, "%04u-%02u-%02u %02u:%02u:%02u.%03u %s", t.wYear, t.wMonth, t.wDay,
                  t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, msg);
    if (n < 0) n = (int)strlen(line);
    line[n++] = '\r'; line[n++] = '\n';
    h = CreateFileW(g_log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    if (GetFileSizeEx(h, &sz) && sz.QuadPart > (LONGLONG)LOG_CAP) {
        CloseHandle(h);
        MoveFileExW(g_log_path, g_log_old, MOVEFILE_REPLACE_EXISTING);
        h = CreateFileW(g_log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h == INVALID_HANDLE_VALUE) return;
    }
    WriteFile(h, line, (DWORD)n, &wr, NULL);
    CloseHandle(h);
    co_add(CO_LOG, co0);                                  /* lane 45 */
}
#include "coop_wd.h"                        /* lane 51: the frame watchdog (after log_line, before the hooks) */

/* ------------------------------------------------------------------ folder and files */
static void trim(char *s)
{
    size_t n = strlen(s), i = 0;
    while (n && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r' || s[n - 1] == '\n')) s[--n] = 0;
    while (s[i] == ' ' || s[i] == '\t') i++;
    if (i) memmove(s, s + i, n - i + 1);
}

static void join_path(wchar_t *out, const wchar_t *dir, const wchar_t *name)
{
    _snwprintf(out, MAX_PATH - 1, L"%s%s", dir, name);
    out[MAX_PATH - 1] = 0;
}

/* this DLL's folder, from GetModuleFileNameW; then coop_patch.cfg "dir=" (environment %VARS% expanded, relative to the
 * DLL folder unless absolute); then <COOP_NAME>\ when that environment variable is set, else <COOP_ROLE>\ */
static void resolve_dir(void)
{
    wchar_t self[MAX_PATH], cfg[MAX_PATH], tmp[MAX_PATH], exp[MAX_PATH], name[64];
    HMODULE me = NULL;
    wchar_t *slash;
    FILE *f;
    char line[600];
    size_t n;
    DWORD nn;

    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       (LPCWSTR)(void *)&resolve_dir, &me);
    nn = GetModuleFileNameW(me, self, MAX_PATH);
    if (nn == 0 || nn >= MAX_PATH) { wcscpy(self, L".\\x"); }
    slash = wcsrchr(self, L'\\');
    if (slash) slash[1] = 0; else wcscpy(self, L".\\");
    wcscpy(g_dir, self);
    wcscpy(g_moddir, self);             /* lane 61 */
    scrub_init_env();                   /* lane 61: the user name, before the first log line */

    join_path(cfg, self, L"coop_patch.cfg");
    f = _wfopen(cfg, L"rb");
    if (f) {
        while (fgets(line, sizeof(line), f)) {
            char *eq;
            trim(line);
            if (line[0] == '#' || line[0] == 0) continue;
            eq = strchr(line, '=');
            if (!eq) continue;
            *eq = 0;
            trim(line);
            if (_stricmp(line, "dir") == 0) {
                char *v = eq + 1;
                trim(v);
                if (*v) {
                    MultiByteToWideChar(CP_UTF8, 0, v, -1, tmp, MAX_PATH);
                    tmp[MAX_PATH - 1] = 0;
                    if (ExpandEnvironmentStringsW(tmp, exp, MAX_PATH) == 0 || exp[0] == 0) wcscpy(exp, tmp);
                    for (n = 0; exp[n]; n++) if (exp[n] == L'/') exp[n] = L'\\';
                    if ((exp[0] && exp[1] == L':') || (exp[0] == L'\\' && exp[1] == L'\\')) wcscpy(g_dir, exp);
                    else _snwprintf(g_dir, MAX_PATH - 2, L"%s%s", self, exp);
                    g_dir[MAX_PATH - 2] = 0;
                    n = wcslen(g_dir);
                    if (n && g_dir[n - 1] != L'\\') { g_dir[n] = L'\\'; g_dir[n + 1] = 0; }
                }
            }
        }
        fclose(f);
    }
    nn = GetEnvironmentVariableW(L"COOP_NAME", name, 64);
    if (nn == 0 || nn >= 64) nn = GetEnvironmentVariableW(L"COOP_ROLE", name, 64);   /* the variable that must differ */
    if (nn > 0 && nn < 64) {
        for (n = 0; name[n]; n++) {     /* keep it a plain folder name */
            wchar_t c = name[n];
            if (!((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || (c >= L'0' && c <= L'9') || c == L'_' || c == L'-')) name[n] = L'_';
        }
        n = wcslen(g_dir);
        _snwprintf(g_dir + n, MAX_PATH - 2 - n, L"%s\\", name);
        g_dir[MAX_PATH - 1] = 0;
    }
    CreateDirectoryW(g_dir, NULL);      /* the subfolder may not exist yet; an existing folder is fine */
    join_path(g_cmd_path, g_dir, L"patch_cmd.txt");
    join_path(g_status_path, g_dir, L"patch_status.txt");
    join_path(g_status_tmp, g_dir, L"patch_status.tmp");
    join_path(g_log_path, g_dir, L"coop_patch.log");
    join_path(g_log_old, g_dir, L"coop_patch.log.old");
}

static const char *state_word(int st) { return st == ST_ON ? "on" : st == ST_OFF ? "off" : "unavailable"; }
static int goods_status(char *buf, size_t len);      /* the GOODS lines of the status file (defined with the switch) */
static int goods_gone_status(char *buf, size_t len); /* lane 46: the goodsgone line (defined with GOODS) */
static int totals_status(char *buf, size_t len);     /* the TOTALS lines (lane 22) */
static int cursor_status(char *buf, size_t len);     /* lane 26: the CURSOR lines */
static int hold_status(char *buf, size_t len);       /* lane 31: the HOLD lines */
static int cursor_scan(void);
static int l28_status(char *buf, size_t len);        /* lane 28: the DRAW / ORDER lines */
static int l53_status(char *buf, size_t len);        /* lane 53: the WALLSET line */
static int l28_scan(void);
static int      g_l53_dead;                         /* lane 53: WALLSET faulted in this run (cleared by the scan) */
static void order_unhook(const char *why);
static void order_tick(void);
static int choose_status(char *buf, size_t len);     /* lane 23: the CHOOSE line */
static int choose_scan(void);
static void choose_off(const char *why);
static int noregion_status(char *buf, size_t len);   /* the lead: the NOREGION line */
static int noregion_scan(void);
static void noregion_off(const char *why);
static int pick_status(char *buf, size_t len);       /* lane 35: the PICK lines */
static int pick_scan(void);
static void pick_off(const char *why);
static int field_status(char *buf, size_t len);      /* lane 40: the FIELD lines */
static int field_scan(void);
static void field_off(void);
static void field_tick(void);
static int dist_status(char *buf, size_t len);       /* lane 42: the DIST line */
static int dist_scan(void);
static void dist_off(const char *why);
static int regset_status(char *buf, size_t len);     /* lane 35, round six: the REGSET line */
static int regset_scan(void);
static int men_status(char *buf, size_t len);        /* lane 43: the MEN lines */
static int snap_status(char *buf, size_t len);       /* lane 47: the SNAP and GUARD lines */
static int snap_scan(void);
static int men_scan(void);
static void men_off(void);
static void men_tick(void);
static int guide_status(char *buf, size_t len);      /* lane 49: the GUIDE line */
static int guide_scan(void);
static int fell_status(char *buf, size_t len);       /* lane 54: the FELL line */
static int fell_scan(void);
static int endhold_status(char *buf, size_t len);    /* lane 49, round four: the ENDHOLD line */
static int endhold_scan(void);
static void endhold_off(const char *why);
static int report_status(char *buf, size_t len);     /* lane 61: the REPORT line (coop_report.h) */

static int write_status(void)              /* lane 45: 0 = not written yet (only counters changed): stays dirty */
{
    char buf[8192];                             /* lane 43: was 4096; the items' lines came near it */
    int n = 0, k;
    HANDLE h;
    DWORD wr;
    unsigned long long co0;
    if (!g_scan_done) {          /* lane 47: nothing is known before the scan's hits are evaluated */
        n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "scanning the game's code (its own thread)\r\nprocess %lu version %s\r\n", GetCurrentProcessId(), COOP_PATCH_VERSION);
        goto have_text;
    }
    if (g_off) n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "off %s\r\n", g_off_reason);
    else n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "ready %X %X\r\n", g_stamp, g_imgsize);
    for (k = S_P1; k <= S_PATCH_LAST; k++) {
        if (g_site[k].state == ST_UNAVAILABLE)
            n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "%s unavailable %s\r\n", SIGS[k].name, g_site[k].why[0] ? g_site[k].why : "-");
        else
            n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "%s %s\r\n", SIGS[k].name, state_word(g_site[k].state));
    }
    for (k = 0; k < CALL_TYPES; k++) {
        int ok = !g_off && g_call_ok[k];
        n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "%s %s%s%s\r\n", CALL_NAME[k], ok ? "available" : "unavailable",
                       ok ? "" : " ", ok ? "" : (g_off ? "dll is off" : g_call_why[k]));
    }
    n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "calls rout=%u reform=%u finish=%u burn=%u fireout=%u failed=%u\r\n", g_calls_n[0], g_calls_n[1], g_calls_n[2], g_calls_n[3], g_calls_n[4], g_calls_failed);
    n += goods_status(buf + n, sizeof(buf) - (size_t)n);
    n += goods_gone_status(buf + n, sizeof(buf) - (size_t)n);      /* lane 46 */
    n += totals_status(buf + n, sizeof(buf) - (size_t)n);
    n += cursor_status(buf + n, sizeof(buf) - (size_t)n);
    n += l28_status(buf + n, sizeof(buf) - (size_t)n);
    n += l53_status(buf + n, sizeof(buf) - (size_t)n);      /* lane 53 */
    n += choose_status(buf + n, sizeof(buf) - (size_t)n);
    n += noregion_status(buf + n, sizeof(buf) - (size_t)n);
    n += hold_status(buf + n, sizeof(buf) - (size_t)n);
    n += pick_status(buf + n, sizeof(buf) - (size_t)n);     /* lane 35 */
    n += field_status(buf + n, sizeof(buf) - (size_t)n);    /* lane 40 */
    n += dist_status(buf + n, sizeof(buf) - (size_t)n);     /* lane 42 */
    n += regset_status(buf + n, sizeof(buf) - (size_t)n);   /* lane 35, round six */
    n += men_status(buf + n, sizeof(buf) - (size_t)n);      /* lane 43 */
    n += snap_status(buf + n, sizeof(buf) - (size_t)n);     /* lane 47 */
    n += guide_status(buf + n, sizeof(buf) - (size_t)n);    /* lane 49 */
    n += fell_status(buf + n, sizeof(buf) - (size_t)n);     /* lane 54 */
    n += endhold_status(buf + n, sizeof(buf) - (size_t)n);  /* lane 49, round four */
    n += report_status(buf + n, sizeof(buf) - (size_t)n);   /* lane 61 */
    n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "process %lu version %s\r\n", GetCurrentProcessId(), COOP_PATCH_VERSION);
have_text:
    if (n < 0 || n > (int)sizeof(buf)) n = (int)strlen(buf);
    /* lane 45: the same text as last time (and the file still there): not written again; only counters changed
     * and the last write is under a second old: written at a later tick */
    if (GetFileAttributesW(g_status_path) != INVALID_FILE_ATTRIBUTES) {
        if (co_status_same(buf, n)) { g_co[CO_SKIP].n++; return 1; }
        if (co_status_defer(buf, n)) return 0;
    }
    co0 = co_now();
    h = CreateFileW(g_status_tmp, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) { co_forget_status(); log_line("cannot write %ls (error %lu)", g_status_tmp, GetLastError()); return 1; }
    WriteFile(h, buf, (DWORD)n, &wr, NULL);
    CloseHandle(h);
    /* lane 45: no MOVEFILE_WRITE_THROUGH (it waited for the disk on every write) */
    if (!MoveFileExW(g_status_tmp, g_status_path, MOVEFILE_REPLACE_EXISTING)) {
        co_forget_status();
        log_line("cannot replace patch_status.txt (error %lu)", GetLastError());
    } else co_status_written(buf, n);
    co_add(CO_STATUS, co0);
    return 1;
}

/* ------------------------------------------------------------------ memory checks */
static int readable_prot(DWORD p)
{
    if (p & (PAGE_GUARD | PAGE_NOACCESS)) return 0;
    return (p & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) != 0;
}

/* every byte of [p, p+len) committed and readable */
static int range_readable(const void *p, size_t len)
{
    const uint8_t *a = (const uint8_t *)p, *end = a + len;
    if (end < a) return 0;
    while (a < end) {
        MEMORY_BASIC_INFORMATION mi;
        if (VirtualQuery(a, &mi, sizeof(mi)) != sizeof(mi)) return 0;
        if (mi.State != MEM_COMMIT || !readable_prot(mi.Protect)) return 0;
        a = (const uint8_t *)mi.BaseAddress + mi.RegionSize;
    }
    return 1;
}

/* ------------------------------------------------------------------ PE headers of the module in memory (report 6 step 1) */
static int find_text(uint8_t *base, char *why, size_t whylen)
{
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    IMAGE_NT_HEADERS64 *nt;
    IMAGE_SECTION_HEADER *sec;
    int i;
    if (!range_readable(base, sizeof(IMAGE_DOS_HEADER)) || dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 || dos->e_lfanew > 4096) {
        _snprintf(why, whylen, "main module has no DOS header"); return 0;
    }
    nt = (IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
    if (!range_readable(nt, sizeof(*nt)) || nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
        nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
        _snprintf(why, whylen, "main module is not a PE32+ x64 image"); return 0;
    }
    g_stamp = nt->FileHeader.TimeDateStamp;
    g_imgsize = nt->OptionalHeader.SizeOfImage;
    sec = IMAGE_FIRST_SECTION(nt);
    if (!range_readable(sec, sizeof(*sec) * nt->FileHeader.NumberOfSections)) { _snprintf(why, whylen, "section table unreadable"); return 0; }
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        if (memcmp(sec[i].Name, ".text\0\0\0", 8) == 0) {
            uint32_t va = sec[i].VirtualAddress, vs = sec[i].Misc.VirtualSize;
            if (vs == 0 || (uint64_t)va + vs > g_imgsize) { _snprintf(why, whylen, ".text outside the image"); return 0; }
            if (!range_readable(base + va, vs)) { _snprintf(why, whylen, ".text is not all committed and readable"); return 0; }
            g_text = base + va; g_text_rva = va; g_text_len = vs;
            return 1;
        }
    }
    _snprintf(why, whylen, "no .text section");
    return 0;
}

/* ------------------------------------------------------------------ the scan (report 6 steps 1-3) */
static int goods_scan(void);                         /* GOODS: can the switch be used on this build (defined with the switch) */
static int totals_scan(void);                        /* TOTALS (lane 22) */
static int hold_scan(void);                          /* HOLD (lane 31) */

static void evaluate_sites(void)
{
    int k;
    for (k = S_P1; k <= S_PATCH_LAST; k++) {
        uint8_t *patch = NULL;
        if (g_hit[k].hits == 1) patch = g_base + g_hit[k].rva + SIGS[k].patch_off;
        if (patch) eval_site(&SIGS[k], &g_hit[k], g_hit, patch, (uint64_t)(uintptr_t)patch, &g_site[k]);
        else eval_site(&SIGS[k], &g_hit[k], g_hit, NULL, 0, &g_site[k]);
    }
}

/* lane 47: the scan of .text (2.4 to 2.7 s, lane 45) runs on a thread of its own in the shipped DLL; it only reads the
 * game's code bytes into g_hit. The game thread's tick does nothing else meanwhile: the command file is not read
 * (commands wait in it), the status file says "scanning". When the thread is done, the tick evaluates the hits (the
 * same code as before, on the game thread). The test build scans in the first tick as before (COOP_SCAN_THREAD=1 in
 * its environment takes the thread there too). */
static LARGE_INTEGER g_scan_f, g_scan_t0, g_scan_t1;
static int scan_begin(void);
static void scan_end(void);
static DWORD WINAPI scan_thread(LPVOID arg)
{
    (void)arg;
    scan_text(g_text, g_text_rva, g_text_len, SIGS, g_pat, S_DLL_COUNT, g_hit);
    QueryPerformanceCounter(&g_scan_t1);
    InterlockedExchange(&g_scan_busy, 0);
    return 0;
}
static int scan_threaded(void)
{
#ifdef COOP_PATCH_TEST
    char e[8];
    if (GetEnvironmentVariableA("COOP_SCAN_THREAD", e, sizeof(e)) == 0 || e[0] != '1') return 0;
#endif
    return 1;
}
static void scan_module(void)
{
    HANDLE th;
    g_scan_done = 0; g_scan_t1.QuadPart = 0;
    if (!scan_begin()) { g_scan_done = 1; return; }
    QueryPerformanceFrequency(&g_scan_f); QueryPerformanceCounter(&g_scan_t0);
    if (scan_threaded()) {
        InterlockedExchange(&g_scan_busy, 1);
        th = CreateThread(NULL, 0, scan_thread, NULL, 0, NULL);
        if (th) { CloseHandle(th); log_line("scan of .text started on its own thread"); return; }
        InterlockedExchange(&g_scan_busy, 0);
        log_line("no thread for the scan (error %lu): scanned in this tick", GetLastError());
    }
    scan_text(g_text, g_text_rva, g_text_len, SIGS, g_pat, S_DLL_COUNT, g_hit);
    QueryPerformanceCounter(&g_scan_t1);
    g_scan_done = 1;
    scan_end();
}
/* 1 = the patterns are parsed and .text is known: the scan may run */
static int scan_begin(void)
{
    char why[160];
    int k;
    uint8_t *base;
#ifdef COOP_PATCH_TEST
    base = g_test_base ? g_test_base : (uint8_t *)GetModuleHandleW(NULL);
#else
    base = (uint8_t *)GetModuleHandleW(NULL);
#endif
    g_base = base;
    for (k = 0; k < S_DLL_COUNT; k++) {
        memset(&g_site[k], 0, sizeof(g_site[k]));
        _snprintf(g_site[k].why, sizeof(g_site[k].why), "not scanned");
    }
    for (k = 0; k < CALL_TYPES; k++) _snprintf(g_call_why[k], sizeof(g_call_why[k]), "not scanned");
    if (!base || !find_text(base, why, sizeof(why))) {
        g_off = 1; _snprintf(g_off_reason, sizeof(g_off_reason), "%s", base ? why : "no main module");
        log_line("off: %s", g_off_reason);
        return 0;
    }
    if (g_stamp != KNOWN_TIMESTAMP || g_imgsize != KNOWN_IMAGESIZE)
        log_line("game build differs from the one the report was made from: timestamp %X size %X (known %X %X); the signatures decide",
                 g_stamp, g_imgsize, KNOWN_TIMESTAMP, KNOWN_IMAGESIZE);
    else
        log_line("game build is the known one: timestamp %X size %X", g_stamp, g_imgsize);
    for (k = 0; k < S_DLL_COUNT; k++) {
        if (sig_parse(&SIGS[k], &g_pat[k]) != 0) { g_off = 1; _snprintf(g_off_reason, sizeof(g_off_reason), "bad pattern %s", SIGS[k].name); log_line("off: %s", g_off_reason); return 0; }
    }
    return 1;
}
/* the hits of the scan evaluated (game thread) */
static void scan_end(void)
{
    int k, any = 0;
    log_line("scanned .text (rva %X, %Iu bytes) in %.0f ms", g_text_rva, g_text_len, (double)(g_scan_t1.QuadPart - g_scan_t0.QuadPart) * 1000.0 / (double)g_scan_f.QuadPart);
    for (k = 0; k < S_DLL_COUNT; k++)
        log_line("  %-6s hits=%d rva=%X%s", SIGS[k].name, g_hit[k].hits, g_hit[k].rva, g_hit[k].form == 1 ? " (already patched form)" : "");
    evaluate_sites();
    for (k = S_P1; k <= S_PATCH_LAST; k++) {
        log_line("  %-6s %s %s", SIGS[k].name, state_word(g_site[k].state), g_site[k].state == ST_UNAVAILABLE ? g_site[k].why : "");
        if (g_site[k].state != ST_UNAVAILABLE) any = 1;
    }
    for (k = 0; k < CALL_TYPES; k++) {
        int s = CALL_SIG[k];
        g_call_ok[k] = g_hit[s].hits == 1;
        if (g_call_ok[k]) { g_call_why[k][0] = 0; any = 1; }
        else _snprintf(g_call_why[k], sizeof(g_call_why[k]), "entry signature has %d hits", g_hit[s].hits);
    }
    if (goods_scan()) any = 1;
    if (totals_scan()) any = 1;
    if (cursor_scan()) any = 1;
    if (l28_scan()) any = 1;
    if (choose_scan()) any = 1;
    if (noregion_scan()) any = 1;
    if (hold_scan()) any = 1;
    if (pick_scan()) any = 1;      /* lane 35 */
    if (field_scan()) any = 1;     /* lane 40 */
    if (dist_scan()) any = 1;      /* lane 42 */
    if (regset_scan()) any = 1;    /* lane 35, round six */
    if (men_scan()) any = 1;       /* lane 43 */
    snap_scan();                   /* lane 47 (SNAP: reads only; does not count as a patch) */
    if (guide_scan()) any = 1;     /* lane 49 */
    if (fell_scan()) any = 1;      /* lane 54 */
    if (endhold_scan()) any = 1;   /* lane 49, round four */
    if (!any) {
        g_off = 1;
        _snprintf(g_off_reason, sizeof(g_off_reason), "nothing matches this game build (timestamp %X)", g_stamp);
        log_line("off: %s", g_off_reason);
    }
}

/* ------------------------------------------------------------------ writing (report 6 step 4) */
/* Write `want` over `expect` at `addr` (len <= 8) through the aligned qword that contains it.
 * Returns 1 on success, 0 on refusal (nothing written), -1 on a failed write or read-back (counts as internal failure). */
static int write_bytes(uint8_t *addr, const uint8_t *expect, const uint8_t *want, int len, char *why, size_t whylen)
{
    uintptr_t a = (uintptr_t)addr, q = a & ~(uintptr_t)7;
    volatile LONG64 *qp = (volatile LONG64 *)q;
    LONG64 cur, nv, prev;
    uint8_t blk[8];
    DWORD old = 0, dummy;
    int off = (int)(a - q), i;
    if (((a + (uintptr_t)len - 1) & ~(uintptr_t)7) != q) { _snprintf(why, whylen, "patch crosses an 8-byte block"); return 0; }
    cur = *qp;                                          /* the block as read just before */
    memcpy(blk, (const void *)&cur, 8);
    if (memcmp(blk + off, expect, (size_t)len) != 0) {
        char hex[20]; int n = 0;
        for (i = 0; i < len; i++) n += _snprintf(hex + n, sizeof(hex) - (size_t)n, "%02X", blk[off + i]);
        _snprintf(why, whylen, "bytes are %s, not the expected ones", hex);
        return 0;
    }
    memcpy(blk + off, want, (size_t)len);
    memcpy(&nv, blk, 8);
    if (!VirtualProtect((void *)q, 8, PAGE_EXECUTE_READWRITE, &old)) { _snprintf(why, whylen, "VirtualProtect failed (error %lu)", GetLastError()); return -1; }
    prev = InterlockedCompareExchange64(qp, nv, cur);
    VirtualProtect((void *)q, 8, old, &dummy);
    FlushInstructionCache(GetCurrentProcess(), (void *)q, 8);
    if (prev != cur) {
        LONG64 again = *qp;
        _snprintf(why, whylen, "block changed under us (now %016llX, was %016llX)", (unsigned long long)again, (unsigned long long)cur);
        return -1;
    }
    if (memcmp(addr, want, (size_t)len) != 0) { _snprintf(why, whylen, "read-back differs after writing"); return -1; }
    return 1;
}

static void internal_failure(const char *what);
static void goods_off(const char *why);              /* GOODS: take both hooks out (defined with the switch) */
static void totals_drop(int recount, const char *why); /* TOTALS: recount (or forget) and take the hook out */
static void hold_drop(int recount, const char *why);   /* HOLD (lane 31): recount approval (or forget) and take the hooks out */

/* turn one site on (want_on = 1) or off; state is always taken from the bytes in memory, never from a cached flag */
static void set_site(int k, int want_on)
{
    site_eval *e = &g_site[k];
    uint8_t *addr;
    char why[160];
    int r;
    if (e->state == ST_UNAVAILABLE) { log_line("%s %s refused: unavailable (%s)", SIGS[k].name, want_on ? "on" : "off", e->why); return; }
    addr = g_base + e->patch_rva;
    if (memcmp(addr, want_on ? e->patched : e->orig, (size_t)e->len) == 0) {
        if (e->state != (want_on ? ST_ON : ST_OFF)) g_dirty = 1;
        e->state = want_on ? ST_ON : ST_OFF;
        log_line("%s already %s", SIGS[k].name, want_on ? "on" : "off");
        return;
    }
    r = write_bytes(addr, want_on ? e->orig : e->patched, want_on ? e->patched : e->orig, e->len, why, sizeof(why));
    if (r == 1) {
        e->state = want_on ? ST_ON : ST_OFF;
        log_line("%s %s at %p (rva %X)", SIGS[k].name, want_on ? "on" : "off", (void *)addr, e->patch_rva);
    } else {
        e->state = ST_UNAVAILABLE;
        _snprintf(e->why, sizeof(e->why), "%s", why);
        log_line("%s %s FAILED: %s; item marked unavailable", SIGS[k].name, want_on ? "on" : "off", why);
        if (r < 0) internal_failure("patch write failed");
    }
    g_dirty = 1;
}

/* put every patched byte back (ALLOFF, and when the DLL switches itself off). Each site in its own __try. */
static void restore_all(void)
{
    int k;
    __try { goods_off("all patches off"); }
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("GOODS restore raised exception %08lX", GetExceptionCode()); }
    __try { totals_drop(1, "all patches off"); }
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("TOTALS restore raised exception %08lX", GetExceptionCode()); }
    __try { order_unhook("all patches off"); }     /* lane 28 */
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("ORDERHOOK restore raised exception %08lX", GetExceptionCode()); }
    __try { choose_off("all patches off"); }
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("CHOOSE restore raised exception %08lX", GetExceptionCode()); }
    __try { noregion_off("all patches off"); }
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("NOREGION restore raised exception %08lX", GetExceptionCode()); }
    __try { hold_drop(1, "all patches off"); }
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("HOLD restore raised exception %08lX", GetExceptionCode()); }
    __try { pick_off("all patches off"); }      /* lane 35 */
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("PICK restore raised exception %08lX", GetExceptionCode()); }
    __try { field_off(); }                      /* lane 40 */
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("FIELD restore raised exception %08lX", GetExceptionCode()); }
    __try { dist_off("all patches off"); }      /* lane 42 */
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("DIST restore raised exception %08lX", GetExceptionCode()); }
    __try { men_off(); }                        /* lane 43 */
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("MEN restore raised exception %08lX", GetExceptionCode()); }
    __try { endhold_off("all patches off"); }   /* lane 49, round four */
    __except (EXCEPTION_EXECUTE_HANDLER) { log_line("ENDHOLD restore raised exception %08lX", GetExceptionCode()); }
    for (k = S_P1; k <= S_PATCH_LAST; k++) {
        site_eval *e = &g_site[k];
        if (e->len == 0 || e->patch_rva == 0 || e->orig[0] == 0 || !g_base) continue;   /* never evaluated: nothing to restore */
        __try {
            uint8_t *addr = g_base + e->patch_rva;
            if (memcmp(addr, e->patched, (size_t)e->len) == 0) {
                char why[160];
                int r = write_bytes(addr, e->patched, e->orig, e->len, why, sizeof(why));
                if (r == 1) { e->state = ST_OFF; log_line("%s off (restored)", SIGS[k].name); }
                else log_line("%s restore FAILED: %s", SIGS[k].name, why);
            } else if (e->state == ST_ON) {
                e->state = ST_OFF;
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            log_line("%s restore raised exception %08lX", SIGS[k].name, GetExceptionCode());
        }
    }
    g_dirty = 1;
}

static void go_off(const char *reason)
{
    if (g_off) return;
    g_off = 1;
    _snprintf(g_off_reason, sizeof(g_off_reason), "%s", reason);
    log_line("switching off: %s; restoring every patch", reason);
    restore_all();
    g_dirty = 1;
}

static void internal_failure(const char *what)
{
    g_failures++;
    log_line("internal failure %d of %d: %s", g_failures, MAX_FAILURES, what);
    if (g_failures >= MAX_FAILURES) go_off("3 internal failures");
    g_dirty = 1;
}

/* ------------------------------------------------------------------ ROUT / REFORM (report 5; safety rule 4) */
static int parse_u64(const char *s, unsigned long long *v)
{
    char *end;
    if (!s || !*s || *s == '-' || *s == '+') return 0;
    if ((s[0] == '0') && (s[1] == 'x' || s[1] == 'X')) { if (!s[2]) return 0; *v = _strtoui64(s + 2, &end, 16); }
    else *v = _strtoui64(s, &end, 10);
    return *end == 0;
}

static int parse_i32(const char *s, int *v)
{
    char *end;
    long long x;
    if (!s || !*s) return 0;
    x = _strtoi64(s, &end, 10);
    if (*end != 0 || x < INT_MIN || x > INT_MAX) return 0;
    *v = (int)x;
    return 1;
}

/* the SquadComponent pointer must look like a live UObject of this module: non-null, 8-aligned, COMP_CHECK_BYTES
 * committed readable, and its first qword (the C++ vtable) inside the game module's image */
static int comp_sane(unsigned long long a, size_t check_bytes, char *why, size_t whylen)
{
    uintptr_t vt = 0;
    if (a == 0) { _snprintf(why, whylen, "address is 0"); return 0; }
    if (a & 7) { _snprintf(why, whylen, "address %llX is not 8-aligned", a); return 0; }
    if (!range_readable((const void *)(uintptr_t)a, check_bytes)) { _snprintf(why, whylen, "address %llX is not committed readable memory (%Iu bytes)", a, check_bytes); return 0; }
    __try { vt = *(const uintptr_t *)(uintptr_t)a; }
    __except (EXCEPTION_EXECUTE_HANDLER) { _snprintf(why, whylen, "reading address %llX faulted", a); return 0; }
    if (vt < (uintptr_t)g_base || vt >= (uintptr_t)g_base + g_imgsize || (vt & 7)) {
        _snprintf(why, whylen, "object at %llX has no vtable in the game module (first qword %IX)", a, vt); return 0;
    }
    return 1;
}

/* ------------------------------------------------------------------ GOODS: building stock changes only on the host's word
 * (lane 14: research\2026-11-10-game-probe\lanes\lane_s21_14\report.txt)
 *
 * Why: each copy runs its own villagers, so the stock of every building drifts between copies, and correcting it from
 * outside makes numbers flicker. With GOODS ON a friend's copy keeps the amounts of a building's Inventory at what the
 * host last said, while its villagers go on walking, working and carrying.
 *
 * How. The game changes a building's Inventory in many places (two add helpers with 23 call sites, and code written
 * out in place), but after a change it calls recountStorage(building) (42 call sites) and / or the region's
 * refreshBuildingStorageCache(region, building) (56 call sites). Both entries are hooked: their first instruction
 * (5 bytes) is replaced by a jump to a small stub of this DLL, which calls goods_hook_* and then runs the replaced
 * instruction and jumps back. So the hook runs BEFORE the routine recounts, in the same call chain as the write.
 *   - A call that returns into SMBuildingMaster::addToInventory is the mod's own write (the game never calls that
 *     routine itself: one caller in the file, the script layer's thunk). It is the host's word: the building's
 *     amounts are remembered ("frozen") as they are now.
 *   - So is every call made while this DLL itself runs FINISH, BURN, FIREOUT or PILEGONE.
 *   - Any other call for a frozen building is the game's own change: the amounts are put back to the remembered
 *     ones first. For the region's refresh the game's "what changed" list is dropped too, so the region's totals are
 *     taken from the building as it now is.
 *   - A building that is not frozen is left alone, except that a building of the lord named in GOODS ON is frozen
 *     the first time it is seen.
 * Inside a hook the list is never moved or grown (a caller may hold a pointer into it): amounts are written in
 * place, a record the game added at the end is cut off by the length, a record the game removed is put back only
 * while the list has room. What that leaves (rare) is repaired at the next tick with the game's own addToInventory.
 * Every step runs under __try; an exception in a hook switches the hooks to pass-through at once and removes them at
 * the next tick. Calls from another thread than the one that ticks are passed through and counted. */
#define INV_OFF        0x448       /* SMBuildingMaster.Inventory: { FGood *data; int num; int max; } (in the RECOUNT pattern) */
#define OWNER_OFF      0x2E0       /* SMBuildingMaster.ownerPawn (reflected) */
#define BTYPE_OFF      0x3B8       /* SMBuildingMaster.Data, first int = the building type (recountStorage compares it with 58h) */
#define OBJ_INDEX_OFF  0x0C        /* UObject: its number in the engine's object list */
#define OBJ_NAME_OFF   0x18        /* UObject: its name (8 bytes) */
#define PILE_TYPE      0x58        /* the pile a demolished building leaves: recountStorage removes it when it is empty */
#define SNAP_MAX       160         /* kinds of goods remembered per building */
#define SNAP_SLOTS     4096        /* buildings remembered (a power of two) */
#define PEND_MAX       128
#define WR_MAX         128
#define TOMB           ((uint8_t *)(uintptr_t)1)

typedef struct { int32_t type, amt; void *p1, *p2; } fgood;         /* the game's record "Good": 24 bytes */
typedef struct { fgood *data; int32_t num, max; } garr;
typedef void (*addinv_fn)(void *building, fgood *good);
typedef void (*recount_fn)(void *building, int allowRemove, int flag, void *arg);

typedef struct {
    uint8_t *b;                     /* the building; NULL = free, TOMB = dropped */
    uint32_t idx; uint64_t name;    /* which object it was when remembered (an address can be used again) */
    int32_t n;                      /* kinds remembered; -1 = more than SNAP_MAX, left alone */
    uint32_t last_ms;
    uint8_t pending;
    int32_t type[SNAP_MAX], amt[SNAP_MAX];
} snap_t;
typedef struct { uint32_t rva, calls, putbacks; unsigned long long units; } writer_t;

static struct {
    int avail; char why[120];
    volatile LONG enabled;          /* the hooks act (0 = pass-through) */
    int own, fixing;                /* own: this DLL runs a game call that is the host's word; fixing: its own repair */
    DWORD thread;
    uint8_t *pawn;
    uint8_t *stub;
    uint8_t *e_recount, *e_refresh, *e_addinv;
    uintptr_t ret_recount, ret_refresh;
    uint8_t jmp_recount[GOODS_HOOK_LEN], jmp_refresh[GOODS_HOOK_LEN];
    volatile LONG want_off; DWORD fault_code;
    snap_t *pend[PEND_MAX]; int npend;
    unsigned used, frozen;
    unsigned long long calls, own_n, putback, units, appended, dropped, deferred, fixed, unfixable, autoreg, stale, toobig,
                       otherthread, nodelta, faults, audits, leaks, leak_units, pilegone;
} G;
static snap_t   g_snap[SNAP_SLOTS];
static writer_t g_wr[WR_MAX];
static int      g_nwr;

static int goods_bytes_on(void)  { return G.stub && memcmp(G.e_recount, G.jmp_recount, GOODS_HOOK_LEN) == 0 && memcmp(G.e_refresh, G.jmp_refresh, GOODS_HOOK_LEN) == 0; }
static int goods_bytes_off(void) { return memcmp(G.e_recount, GOODS_ORIG_RECOUNT, GOODS_HOOK_LEN) == 0 && memcmp(G.e_refresh, GOODS_ORIG_REFRESH, GOODS_HOOK_LEN) == 0; }

static int goods_status(char *buf, size_t len)
{
    int n = 0;
    if (g_off || !G.avail) n += _snprintf(buf + n, len - (size_t)n, "GOODS unavailable %s\r\n", g_off ? "dll is off" : G.why);
    else n += _snprintf(buf + n, len - (size_t)n, "GOODS %s\r\n", goods_bytes_on() ? "on" : goods_bytes_off() ? "off" : "unavailable its two entries are in different states");
    n += _snprintf(buf + n, len - (size_t)n,
                   "goods frozen=%u calls=%llu own=%llu putback=%llu units=%llu appended=%llu dropped=%llu deferred=%llu fixed=%llu unfixable=%llu "
                   "autoreg=%llu stale=%llu toobig=%llu otherthread=%llu nodelta=%llu faults=%llu audits=%llu leaks=%llu leakunits=%llu pilegone=%llu\r\n",
                   G.frozen, G.calls, G.own_n, G.putback, G.units, G.appended, G.dropped, G.deferred, G.fixed, G.unfixable,
                   G.autoreg, G.stale, G.toobig, G.otherthread, G.nodelta, G.faults, G.audits, G.leaks, G.leak_units, G.pilegone);
    return n < 0 ? 0 : n;
}

/* ---- the remembered amounts */
static snap_t *snap_find(uint8_t *b)
{
    unsigned i = (unsigned)(((uintptr_t)b >> 4) * 2654435761u) & (SNAP_SLOTS - 1), n;
    for (n = 0; n < SNAP_SLOTS; n++, i = (i + 1) & (SNAP_SLOTS - 1)) {
        if (g_snap[i].b == b) return &g_snap[i];
        if (g_snap[i].b == NULL) return NULL;
    }
    return NULL;
}

static snap_t *snap_add(uint8_t *b)
{
    unsigned i = (unsigned)(((uintptr_t)b >> 4) * 2654435761u) & (SNAP_SLOTS - 1), n;
    if (G.used >= SNAP_SLOTS * 3 / 4) { G.toobig++; return NULL; }
    for (n = 0; n < SNAP_SLOTS; n++, i = (i + 1) & (SNAP_SLOTS - 1)) {
        if (g_snap[i].b == NULL || g_snap[i].b == TOMB) {
            if (g_snap[i].b == NULL) G.used++;
            memset(&g_snap[i], 0, sizeof(g_snap[i]));
            g_snap[i].b = b; G.frozen++;
            return &g_snap[i];
        }
    }
    return NULL;
}

static void snap_del(snap_t *s)
{
    int i;
    for (i = 0; i < G.npend; i++) if (G.pend[i] == s) { G.pend[i] = G.pend[--G.npend]; break; }
    s->b = TOMB; s->pending = 0;
    if (G.frozen) G.frozen--;
}

static void goods_clear(void)
{
    memset(g_snap, 0, sizeof(g_snap));
    G.used = G.frozen = 0; G.npend = 0;
}

static int same_object(const snap_t *s, const uint8_t *b)
{
    return *(const uint32_t *)(b + OBJ_INDEX_OFF) == s->idx && *(const uint64_t *)(b + OBJ_NAME_OFF) == s->name;
}

/* the list looks like a list: a length within its room, and a data pointer when it has records */
static int list_sane(const garr *a) { return a->num >= 0 && a->num <= 4096 && a->max >= a->num && (a->num == 0 || a->data != NULL); }

static void snap_take(snap_t *s, uint8_t *b)
{
    garr *a = (garr *)(b + INV_OFF);
    int i, j, n = 0;
    s->idx = *(uint32_t *)(b + OBJ_INDEX_OFF); s->name = *(uint64_t *)(b + OBJ_NAME_OFF); s->last_ms = GetTickCount();
    if (!list_sane(a)) { s->n = -1; return; }
    for (i = 0; i < a->num; i++) {
        for (j = 0; j < n; j++) if (s->type[j] == a->data[i].type) break;
        if (j < n) { s->amt[j] += a->data[i].amt; continue; }
        if (n >= SNAP_MAX) { s->n = -1; G.toobig++; return; }
        s->type[n] = a->data[i].type; s->amt[n] = a->data[i].amt; n++;
    }
    s->n = n;
}

static void pend_add(snap_t *s)
{
    if (s->pending) return;
    if (G.npend >= PEND_MAX) return;               /* the next hook or audit sees it again */
    s->pending = 1; G.pend[G.npend++] = s; G.deferred++;
}

/* record i is not in the host's word: a kind the host's word does not have here, or a second record of a kind */
static int is_extra(const snap_t *s, const fgood *d, int i)
{
    int j;
    for (j = 0; j < s->n; j++) if (s->type[j] == d[i].type) break;
    if (j >= s->n) return 1;
    for (j = 0; j < i; j++) if (d[j].type == d[i].type) return 1;
    return 0;
}

static unsigned long long absdiff(int32_t a, int32_t b) { long long d = (long long)a - (long long)b; return (unsigned long long)(d < 0 ? -d : d); }

/* Put the amounts back without moving or growing the list. Returns the units changed (0 = nothing differed). */
static unsigned long long snap_putback(snap_t *s, uint8_t *b)
{
    garr *a = (garr *)(b + INV_OFF);
    fgood *d = a->data;
    int i, j, later = 0, changed = 0;
    unsigned long long units = 0;
    s->last_ms = GetTickCount();
    if (!list_sane(a)) return 0;
    while (a->num > 0 && is_extra(s, d, a->num - 1)) {      /* added at the end by the game: the list is made shorter */
        units += absdiff(d[a->num - 1].amt, 0); a->num--; G.dropped++; changed = 1;
    }
    for (i = 0; i < a->num; i++) {
        int32_t want = 0;
        if (is_extra(s, d, i)) later = 1;                   /* in the middle: amount 0 now, removed at the tick */
        else for (j = 0; j < s->n; j++) if (s->type[j] == d[i].type) { want = s->amt[j]; break; }
        if (d[i].amt != want) { units += absdiff(d[i].amt, want); d[i].amt = want; changed = 1; }
    }
    for (j = 0; j < s->n; j++) {                            /* removed by the game: put back while there is room */
        if (s->amt[j] == 0) continue;
        for (i = 0; i < a->num; i++) if (d[i].type == s->type[j]) break;
        if (i < a->num) continue;
        if (d && a->num < a->max) {
            fgood *r = d + a->num;
            r->type = s->type[j]; r->amt = s->amt[j]; r->p1 = NULL; r->p2 = NULL;
            a->num++; G.appended++; changed = 1; units += absdiff(s->amt[j], 0);
        } else later = 1;
    }
    if (later) pend_add(s);
    if (changed) { G.putback++; G.units += units; if (!units) units = 1; }
    return changed ? units : 0;
}

/* amounts differ from the remembered ones (a missing record counts as 0) */
static int snap_differs(const snap_t *s, const uint8_t *b, int32_t *kind, int32_t *have_out, int32_t *want_out)
{
    const garr *a = (const garr *)(b + INV_OFF);
    int i, j;
    if (!list_sane(a)) return 0;
    for (j = 0; j < s->n; j++) {
        int32_t have = 0;
        for (i = 0; i < a->num; i++) if (a->data[i].type == s->type[j]) have += a->data[i].amt;
        if (have != s->amt[j]) { *kind = s->type[j]; *have_out = have; *want_out = s->amt[j]; return 1; }
    }
    for (i = 0; i < a->num; i++) {
        for (j = 0; j < s->n; j++) if (s->type[j] == a->data[i].type) break;
        if (j >= s->n && a->data[i].amt != 0) { *kind = a->data[i].type; *have_out = a->data[i].amt; *want_out = 0; return 1; }
    }
    return 0;
}

static void writer_note(uintptr_t ret, unsigned long long units)
{
    uint32_t rva = (uint32_t)(ret - (uintptr_t)g_base);
    int i;
    for (i = 0; i < g_nwr; i++) if (g_wr[i].rva == rva) break;
    if (i == g_nwr) { if (g_nwr >= WR_MAX) return; g_wr[g_nwr].rva = rva; g_wr[g_nwr].calls = 0; g_wr[g_nwr].putbacks = 0; g_wr[g_nwr].units = 0; g_nwr++; }
    g_wr[i].calls++;
    if (units) { g_wr[i].putbacks++; g_wr[i].units += units; }
}

/* ---- lane 46: A BUILDING BEING DEMOLISHED IS NEVER GIVEN ITS STOCK BACK (research/2026-11-10-game-probe/lanes/
 * lane_s21_46/report.txt, job 1). The game's demolish (4d32ef0) moves a building's goods into the refund pile, empties
 * the building's list in place (num 0, room 0), calls refreshBuildingStorageCache(region, building) (the call at the
 * DEMREF site) and later Engine::eraseBuildingReferences takes the building out of its region's two building sets
 * (+5A8h, +5F8h). The only routine that puts a building INTO those sets is its surplus cache (4d24b60, DGSURP), which
 * recountStorage calls: it inserts a building that holds goods, and reads the region from +2C8h, which demolish does
 * not clear. Before this rule GOODS saw that refresh as "the game's own change of a frozen building", could not put the
 * amounts back in place (no room), and its tick repaired the building with addToInventory -> recountStorage -> the
 * surplus cache: the demolished building was a member of its region's sets again, freed later, and the job chooser's
 * walk of the set read freed memory (the friend's crashes of 2026-11-13).
 * The rule: a hooked call that returns to the DEMREF site names a building being demolished. It is forgotten and
 * marked GONE (address, object number, name): no put-back, no repair, no audit, no taking in (neither by a lord's
 * building's first change nor by a mod write) for that object again; DIST writes nothing into it either. The Lua side
 * (the town module, at the moment it applies or sends a DEMOLISH, before the game removes the building) marks it too:
 * "GOODS GONE <addr>,..." (such a mark lasts GONE_LUA_MS, since a demolish request can fail). Without the DEMREF
 * signature GOODS works as before and only the Lua marks hold (status "goodsgone site=0").
 * Test switch (console only): "GOODS DEMRULE OFF|ON" (the site is then not used; the Lua marks still are). */
#define GONE_SLOTS   256
#define GONE_LUA_MS  15000u
typedef struct { uint8_t *b; uint32_t idx; uint64_t name; uint32_t ms; int forever; } gone_t;
static gone_t g_gone[GONE_SLOTS];
static int    g_gone_next;
static struct {
    uintptr_t ret_dem;              /* the return address of the DEMREF call (0 = signature not found) */
    int rule_off;                   /* test switch */
    unsigned long long demolished, marks, putskip, fixskip, auditskip, modwrites, distskip, takeskip;
} GD;

static gone_t *gone_find(const uint8_t *b)
{
    int i;
    uint32_t now = GetTickCount();
    if (!b) return NULL;
    for (i = 0; i < GONE_SLOTS; i++) {
        gone_t *g = &g_gone[i];
        if (g->b != b) continue;
        if (!g->forever && now - g->ms > GONE_LUA_MS) { g->b = NULL; continue; }
        if (!range_readable(b, OBJ_NAME_OFF + 8)) return g;                 /* freed: still gone */
        if (*(const uint32_t *)(b + OBJ_INDEX_OFF) == g->idx && *(const uint64_t *)(b + OBJ_NAME_OFF) == g->name) return g;
        g->b = NULL;                                                         /* the address holds another object now */
    }
    return NULL;
}

static void gone_mark(uint8_t *b, int forever)
{
    gone_t *g = gone_find(b);
    if (!g) { g = &g_gone[g_gone_next]; g_gone_next = (g_gone_next + 1) % GONE_SLOTS; g->forever = 0; }   /* a new slot keeps nothing of the one before */
    g->b = b; g->idx = *(uint32_t *)(b + OBJ_INDEX_OFF); g->name = *(uint64_t *)(b + OBJ_NAME_OFF);
    g->ms = GetTickCount(); g->forever = g->forever || forever;
}

/* the building leaves GOODS: its remembered amounts are dropped (and DIST's entry, defined with DIST) */
static void dist_gone(const uint8_t *b);
static void goods_gone(uint8_t *b, int forever)
{
    snap_t *s = snap_find(b);
    if (s) snap_del(s);
    gone_mark(b, forever);
    dist_gone(b);
}

/* GOODS GONE <addr>,<addr>,...  (the Lua side, at the moment of a DEMOLISH) */
static void goods_gone_cmd(const char *list)
{
    char buf[1024], *p, *q;
    unsigned long long a;
    g_dirty = 1;
    _snprintf(buf, sizeof(buf), "%s", list); buf[sizeof(buf) - 1] = 0;
    for (p = buf; p && *p; p = q) {
        q = strchr(p, ','); if (q) *q++ = 0;
        if (!parse_u64(p, &a) || !range_readable((void *)(uintptr_t)a, INV_OFF + sizeof(garr))) { log_line("GOODS GONE: '%s' refused", p); continue; }
        __try { goods_gone((uint8_t *)(uintptr_t)a, 0); GD.marks++; }
        __except (EXCEPTION_EXECUTE_HANDLER) { log_line("GOODS GONE(%s) raised exception %08lX", p, GetExceptionCode()); }
    }
}

static int goods_gone_status(char *buf, size_t len)
{
    int n = _snprintf(buf, len, "goodsgone site=%d rule=%s demolished=%llu marks=%llu putskip=%llu fixskip=%llu auditskip=%llu takeskip=%llu modwrites=%llu distskip=%llu\r\n",
                      GD.ret_dem ? 1 : 0, GD.rule_off ? "off" : "on", GD.demolished, GD.marks, GD.putskip, GD.fixskip, GD.auditskip,
                      GD.takeskip, GD.modwrites, GD.distskip);
    return n < 0 ? 0 : n;
}

/* ---- the hooks (called by the stubs; frame = { r9, r8, rdx, rcx, return address } as they were at the entry) */
static void goods_event(uint8_t *b, uint64_t *frame, int refresh)
{
    uintptr_t ret = (uintptr_t)frame[4];
    snap_t *s;
    int own, modw;
    G.calls++;
    if (!G.enabled || G.fixing || !b) return;
    if (GetCurrentThreadId() != G.thread) { G.otherthread++; return; }
    modw = ret == (refresh ? G.ret_refresh : G.ret_recount);        /* the call returns into addToInventory: the mod's write */
    /* lane 46: the demolish's refresh of the building it is taking away; and any later call for a building gone */
    if (refresh && GD.ret_dem && !GD.rule_off && ret == GD.ret_dem) { goods_gone(b, 1); GD.demolished++; g_dirty = 1; return; }
    if (gone_find(b)) {
        if (modw) GD.modwrites++; else if (snap_find(b)) GD.putskip++; else GD.takeskip++;
        return;
    }
    own = G.own || modw;
    s = snap_find(b);
    if (s && !same_object(s, b)) { snap_del(s); s = NULL; G.stale++; }
    if (own) {                                              /* the host's word: remember the building as it is now */
        /* a building not yet remembered is taken in by the mod's own write, or when it is the lord's; a call of
         * this DLL (FINISH on another lord's building, the goods it uses up elsewhere) does not take one in */
        if (!s && (modw || (G.pawn && *(uint8_t **)(b + OWNER_OFF) == G.pawn))) s = snap_add(b);
        if (s) {
            snap_take(s, b); G.own_n++;
            /* A game routine this DLL runs hands the region its own list of what it used up (finishConstruction: the
             * site's list of materials at +3D0h, negated), not what left the building. On a friend the building holds
             * the host's amounts, so that list is wrong here: it is dropped and the region takes the building as it
             * is (the same path the mod's own write takes, which never has a list). */
            if (!modw && s->n >= 0 && refresh && (uint32_t)frame[1] == 0 && frame[0]) { frame[0] = 0; G.nodelta++; }
        }
        return;
    }
    if (!s) {
        if (G.pawn && *(uint8_t **)(b + OWNER_OFF) == G.pawn) { s = snap_add(b); if (s) { snap_take(s, b); G.autoreg++; } }
        return;
    }
    if (s->n < 0) return;
    writer_note(ret, snap_putback(s, b));
    /* the region's refresh, mode 0, with the game's list of what changed: that change was just undone */
    if (refresh && (uint32_t)frame[1] == 0 && frame[0]) { frame[0] = 0; G.nodelta++; }
}

static void goods_fault(DWORD code)
{
    InterlockedExchange(&G.enabled, 0);
    G.faults++; G.fault_code = code;
    InterlockedExchange(&G.want_off, 1);
}

static void goods_hook_recount_wd(uint8_t *b, uint64_t *frame)
{
    __try { goods_event(b, frame, 0); }
    __except (EXCEPTION_EXECUTE_HANDLER) { goods_fault(GetExceptionCode()); }
}
static void goods_hook_recount(uint8_t *b, uint64_t *frame)   /* lane 51: the watchdog's marks around it */
{
    wd_in(WD_GREC); goods_hook_recount_wd(b, frame); wd_out(WD_GREC);
}

static void goods_hook_refresh_wd(uint8_t *region, uint64_t *frame)
{
    (void)region;
    __try { goods_event((uint8_t *)(uintptr_t)frame[2], frame, 1); }
    __except (EXCEPTION_EXECUTE_HANDLER) { goods_fault(GetExceptionCode()); }
}
static void goods_hook_refresh(uint8_t *region, uint64_t *frame)   /* lane 51: the watchdog's marks around it */
{
    wd_in(WD_GREF); goods_hook_refresh_wd(region, frame); wd_out(WD_GREF);
}

/* ---- the stubs: push rcx rdx r8 r9; sub rsp,28h; lea rdx,[rsp+28h]; mov rax,<hook>; call rax; add rsp,28h;
 * pop r9 r8 rdx rcx; <the entry's first instruction>; jmp [rip+0] -> entry + 5 */
static size_t emit_stub(uint8_t *p, void *hookfn, const uint8_t *orig, uint8_t *resume)
{
    static const uint8_t pre[]  = { 0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x48, 0x83, 0xEC, 0x28, 0x48, 0x8D, 0x54, 0x24, 0x28, 0x48, 0xB8 };
    static const uint8_t post[] = { 0xFF, 0xD0, 0x48, 0x83, 0xC4, 0x28, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59 };
    size_t n = 0;
    memcpy(p + n, pre, sizeof(pre)); n += sizeof(pre);
    memcpy(p + n, &hookfn, 8); n += 8;
    memcpy(p + n, post, sizeof(post)); n += sizeof(post);
    memcpy(p + n, orig, GOODS_HOOK_LEN); n += GOODS_HOOK_LEN;
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0;
    memcpy(p + n, &resume, 8); n += 8;
    return n;
}

/* one page of memory a 32-bit jump from the module can reach: the first free 64 KB block below it, else above it */
static uint8_t *alloc_near(uint8_t *base, uint32_t imgsize)
{
    const uintptr_t gran = 0x10000, reach = 0x70000000;
    uintptr_t a;
    MEMORY_BASIC_INFORMATION mi;
    int guard;
    a = ((uintptr_t)base - gran) & ~(gran - 1);
    for (guard = 0; guard < 100000 && a > gran && (uintptr_t)base - a < reach; guard++) {
        if (VirtualQuery((void *)a, &mi, sizeof(mi)) != sizeof(mi)) break;
        if (mi.State == MEM_FREE) {
            void *p = VirtualAlloc((void *)a, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
            if (p) return (uint8_t *)p;
            a -= gran;
        } else a = (((uintptr_t)mi.AllocationBase) - gran) & ~(gran - 1);
    }
    a = ((uintptr_t)base + imgsize + gran - 1) & ~(gran - 1);
    for (guard = 0; guard < 100000 && a - (uintptr_t)base < reach; guard++) {
        if (VirtualQuery((void *)a, &mi, sizeof(mi)) != sizeof(mi)) break;
        if (mi.State == MEM_FREE) {
            void *p = VirtualAlloc((void *)a, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
            if (p) return (uint8_t *)p;
            a += gran;
        } else a = (((uintptr_t)mi.BaseAddress + mi.RegionSize) + gran - 1) & ~(gran - 1);
    }
    return NULL;
}

static int goods_make_stub(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize);
    size_t n;
    int32_t rel;
    DWORD old;
    if (!p) return 0;
    n = emit_stub(p, (void *)&goods_hook_recount, GOODS_ORIG_RECOUNT, G.e_recount + GOODS_HOOK_LEN);
    rel = (int32_t)((intptr_t)p - (intptr_t)(G.e_recount + GOODS_HOOK_LEN));
    G.jmp_recount[0] = 0xE9; memcpy(G.jmp_recount + 1, &rel, 4);
    n = (n + 15) & ~(size_t)15;
    emit_stub(p + n, (void *)&goods_hook_refresh, GOODS_ORIG_REFRESH, G.e_refresh + GOODS_HOOK_LEN);
    rel = (int32_t)((intptr_t)(p + n) - (intptr_t)(G.e_refresh + GOODS_HOOK_LEN));
    G.jmp_refresh[0] = 0xE9; memcpy(G.jmp_refresh + 1, &rel, 4);
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    G.stub = p;
    log_line("GOODS: stubs at %p (recount entry %p, refresh entry %p)", (void *)p, (void *)G.e_recount, (void *)G.e_refresh);
    return 1;
}

/* called by the scan: can the switch be used on this game build? */
static int goods_scan(void)
{
    memset(&G, 0, sizeof(G)); g_nwr = 0; goods_clear();
    G.avail = goods_check(g_hit, g_base + g_hit[S_RECOUNT].rva, g_base + g_hit[S_REFRESH].rva, g_base + g_hit[S_ADDINV].rva,
                          (uint64_t)(uintptr_t)(g_base + g_hit[S_RECOUNT].rva), (uint64_t)(uintptr_t)(g_base + g_hit[S_REFRESH].rva),
                          G.why, sizeof(G.why));
    if (G.avail) {
        G.e_recount = g_base + g_hit[S_RECOUNT].rva; G.e_refresh = g_base + g_hit[S_REFRESH].rva; G.e_addinv = g_base + g_hit[S_ADDINV].rva;
        G.ret_recount = (uintptr_t)(G.e_addinv + ADDINV_CALL_RECOUNT + 5);
        G.ret_refresh = (uintptr_t)(G.e_addinv + ADDINV_CALL_REFRESH + 5);
    }
    /* lane 46: the demolish's refresh of the building (DEMREF): exactly one hit and its call reaches REFRESH */
    memset(&GD, 0, sizeof(GD)); memset(g_gone, 0, sizeof(g_gone)); g_gone_next = 0;
    if (G.avail) {
        uint32_t t;
        uint32_t site = g_hit[S_DEMREF].rva + (uint32_t)SIGS[S_DEMREF].patch_off;
        if (g_hit[S_DEMREF].hits != 1) log_line("  GOODS: the demolish rule is out: DEMREF signature has %d hits (need exactly 1)", g_hit[S_DEMREF].hits);
        else if (!goods_call_target(g_base + site, site, &t) || t != g_hit[S_REFRESH].rva) log_line("  GOODS: the demolish rule is out: DEMREF's call does not reach REFRESH");
        else GD.ret_dem = (uintptr_t)(g_base + site + 5);
    }
    log_line("  GOODS  %s %s", G.avail ? "off" : "unavailable", G.avail ? "" : G.why);
    return G.avail;
}

static void goods_off(const char *why)
{
    char w[160];
    int r;
    InterlockedExchange(&G.enabled, 0);
    if (!G.avail || !G.stub) { goods_clear(); return; }
    if (memcmp(G.e_recount, G.jmp_recount, GOODS_HOOK_LEN) == 0) {
        r = write_bytes(G.e_recount, G.jmp_recount, GOODS_ORIG_RECOUNT, GOODS_HOOK_LEN, w, sizeof(w));
        if (r != 1) { log_line("GOODS: the recount entry could not be restored: %s", w); if (r < 0) internal_failure("goods restore failed"); }
    }
    if (memcmp(G.e_refresh, G.jmp_refresh, GOODS_HOOK_LEN) == 0) {
        r = write_bytes(G.e_refresh, G.jmp_refresh, GOODS_ORIG_REFRESH, GOODS_HOOK_LEN, w, sizeof(w));
        if (r != 1) { log_line("GOODS: the refresh entry could not be restored: %s", w); if (r < 0) internal_failure("goods restore failed"); }
    }
    log_line("GOODS off (%s): %u buildings were frozen; put back %llu times, %llu units", why, G.frozen, G.putback, G.units);
    goods_clear();
    g_dirty = 1;
}

static void goods_on(unsigned long long pawn)
{
    char w[160];
    int r;
    g_dirty = 1;
    if (!G.avail) { log_line("GOODS ON refused: unavailable (%s)", G.why); return; }
    if (!G.stub && !goods_make_stub()) {
        G.avail = 0; _snprintf(G.why, sizeof(G.why), "no free memory near the game module for the stubs");
        log_line("GOODS ON refused: %s", G.why); return;
    }
    G.pawn = (uint8_t *)(uintptr_t)pawn;
    if (goods_bytes_on()) { InterlockedExchange(&G.enabled, 1); log_line("GOODS already on (lord %p)", (void *)G.pawn); return; }
    if (!goods_bytes_off()) { G.avail = 0; _snprintf(G.why, sizeof(G.why), "an entry holds neither its own bytes nor this DLL's jump"); log_line("GOODS ON refused: %s", G.why); return; }
    goods_clear();
    G.thread = GetCurrentThreadId(); G.own = 0; G.fixing = 0;
    InterlockedExchange(&G.want_off, 0);
    InterlockedExchange(&G.enabled, 1);
    r = write_bytes(G.e_recount, GOODS_ORIG_RECOUNT, G.jmp_recount, GOODS_HOOK_LEN, w, sizeof(w));
    if (r == 1) {
        r = write_bytes(G.e_refresh, GOODS_ORIG_REFRESH, G.jmp_refresh, GOODS_HOOK_LEN, w, sizeof(w));
        if (r != 1) goods_off("the second entry could not be written");       /* both or neither */
    }
    if (r != 1) {
        InterlockedExchange(&G.enabled, 0);
        G.avail = 0; _snprintf(G.why, sizeof(G.why), "%s", w);
        log_line("GOODS ON FAILED: %s; item marked unavailable", w);
        if (r < 0) internal_failure("goods hook write failed");
        return;
    }
    log_line("GOODS on (lord %p): recount at %p, refresh at %p", (void *)G.pawn, (void *)G.e_recount, (void *)G.e_refresh);
}

/* a remembered building that is still there and still the same object */
static int snap_alive(snap_t *s)
{
    if (!s->b || s->b == TOMB) return 0;
    if (!range_readable(s->b, INV_OFF + sizeof(garr))) return 0;
    return same_object(s, s->b);
}

/* at the tick, outside every call chain of the game: finish what a hook could not do in place, with the game's own
 * addToInventory (it grows the list and removes records at or below nothing by itself) */
static void goods_fix(snap_t *s)
{
    uint8_t *b = s->b;
    garr *a = (garr *)(b + INV_OFF);
    int i, j, guard;
    int32_t k, h, w;
    G.fixing = 1;
    __try {
        for (guard = 0; guard < 64 && list_sane(a); guard++) {     /* records the host's word does not have */
            int found = -1;
            fgood g;
            for (i = 0; i < a->num; i++) if (is_extra(s, a->data, i)) { found = i; break; }
            if (found < 0) break;
            a->data[found].amt = 0;
            g.type = a->data[found].type; g.amt = -1; g.p1 = NULL; g.p2 = NULL;
            ((addinv_fn)(void *)G.e_addinv)(b, &g);
        }
        for (j = 0; j < s->n && list_sane(a); j++) {               /* amounts, and records that are missing */
            int32_t have = 0;
            fgood g;
            for (i = 0; i < a->num; i++) if (a->data[i].type == s->type[j]) have += a->data[i].amt;
            if (have == s->amt[j]) continue;
            g.type = s->type[j]; g.amt = s->amt[j] - have; g.p1 = NULL; g.p2 = NULL;
            ((addinv_fn)(void *)G.e_addinv)(b, &g);
        }
        if (snap_differs(s, b, &k, &h, &w)) G.unfixable++; else G.fixed++;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        G.fixing = 0;
        goods_fault(GetExceptionCode());
    }
    G.fixing = 0;
}

static void goods_tick(void)
{
    int i;
    if (G.want_off) {
        InterlockedExchange(&G.want_off, 0);
        log_line("GOODS: exception %08lX in a hook or a repair: the switch is taken out", G.fault_code);
        goods_off("exception");
        G.avail = 0; _snprintf(G.why, sizeof(G.why), "exception %08lX in a hook", G.fault_code);
        g_dirty = 1;
        return;
    }
    if (!G.enabled || G.npend == 0) return;
    for (i = 0; i < G.npend; i++) {
        snap_t *s = G.pend[i];
        s->pending = 0;
        if (s->b && s->b != TOMB && gone_find(s->b)) { GD.fixskip++; snap_del(s); i--; continue; }   /* lane 46: never repair a demolished building (snap_del took it off this list) */
        if (snap_alive(s) && s->n >= 0) goods_fix(s);
    }
    G.npend = 0;
}

/* GOODS AUDIT: every remembered building against its remembered amounts. A difference found here is a change that
 * reached neither hook yet ("leak"); it is logged, counted and repaired. */
static void goods_audit(void)
{
    unsigned i;
    int said = 0;
    if (!G.enabled) return;
    for (i = 0; i < SNAP_SLOTS; i++) {
        snap_t *s = &g_snap[i];
        int32_t kind = 0, have = 0, want = 0;
        if (!s->b || s->b == TOMB) continue;
        if (gone_find(s->b)) { snap_del(s); GD.auditskip++; continue; }     /* lane 46 */
        if (!snap_alive(s)) { snap_del(s); G.stale++; continue; }
        if (s->n < 0) continue;
        if (snap_differs(s, s->b, &kind, &have, &want)) {
            G.leaks++; G.leak_units += absdiff(have, want);
            if (said++ < 8) log_line("GOODS leak: building %p (type %d) good %d is %d, the host's word is %d; last hook %lu ms ago",
                                     (void *)s->b, *(int32_t *)(s->b + BTYPE_OFF), kind, have, want, (unsigned long)(GetTickCount() - s->last_ms));
            snap_putback(s, s->b);
            pend_add(s);
        }
    }
    G.audits++;
    g_dirty = 1;
}

/* GOODS STATS: where the game's own changes came from (the return address of each hooked call), into goods_stats.txt */
static void goods_stats(void)
{
    wchar_t path[MAX_PATH];
    FILE *f;
    int i;
    join_path(path, g_dir, L"goods_stats.txt");
    f = _wfopen(path, L"wb");
    if (!f) return;
    fprintf(f, "# caller_rva calls putbacks units   (the instruction after each call of recountStorage / refreshBuildingStorageCache)\r\n");
    for (i = 0; i < g_nwr; i++) fprintf(f, "%X %u %u %llu\r\n", g_wr[i].rva, g_wr[i].calls, g_wr[i].putbacks, g_wr[i].units);
    fclose(f);
    log_line("GOODS STATS: %d callers written to goods_stats.txt", g_nwr);
}

/* after FINISH / BURN / FIREOUT ran: the building as the host's word left it */
static void goods_resnap(uint8_t *b)
{
    snap_t *s;
    if (!G.enabled) return;
    __try {
        if (gone_find(b)) { GD.takeskip++; return; }                        /* lane 46 */
        s = snap_find(b);
        if (s && !same_object(s, b)) { snap_del(s); s = NULL; }
        if (!s && G.pawn && *(uint8_t **)(b + OWNER_OFF) == G.pawn) s = snap_add(b);     /* the lord's only */
        if (s) snap_take(s, b);
    } __except (EXCEPTION_EXECUTE_HANDLER) { goods_fault(GetExceptionCode()); }
}

/* which: 0 ROUT, 1 REFORM (address + squad handle), 2 FINISH (address only: finishConstruction(SMBuildingMaster*)).
 * FINISH checks FINISH_CHECK_BYTES of the building: the function reads fields up to +0x14C4 (seen in its first blocks). */
#define FINISH_CHECK_BYTES 0x1500
static void do_call(int which, int argc, char **argv)
{
    const char *nm = CALL_NAME[which];
    int want_args = which >= 2 ? 1 : 2;
    unsigned long long addr = 0;
    int handle = 0;
    char why[200];
    void *target;
    DWORD code = 0;
    int faulted = 0;
    g_dirty = 1;
    if (!g_call_ok[which]) { g_calls_failed++; log_line("%s refused: unavailable (%s)", nm, g_call_why[which]); return; }
    if (argc != want_args + 1) {
        g_calls_failed++;
        log_line("%s refused: needs exactly %d argument%s (%s), got %d", nm, want_args, want_args == 1 ? "" : "s",
                 which >= 2 ? "address" : "address handle", argc - 1);
        return;
    }
    if (!parse_u64(argv[1], &addr)) { g_calls_failed++; log_line("%s refused: address '%s' is not a number", nm, argv[1]); return; }
    if (which < 2) {
        if (!parse_i32(argv[2], &handle)) { g_calls_failed++; log_line("%s refused: handle '%s' is not a 32-bit integer", nm, argv[2]); return; }
        if (handle == 0) { g_calls_failed++; log_line("%s refused: handle 0 is the invalid squad", nm); return; }
    }
    if (!comp_sane(addr, which >= 2 ? FINISH_CHECK_BYTES : COMP_CHECK_BYTES, why, sizeof(why))) { g_calls_failed++; log_line("%s refused: %s", nm, why); return; }
    /* BURN: progressFire does not test onFire itself; on a building that is not burning it would mark it built with the
     * wrong type (lane_f Q3). The bytes were just proven readable by comp_sane. */
    if (which == 3 && *((const unsigned char *)(uintptr_t)addr + ONFIRE_OFFSET) == 0) { g_calls_failed++; log_line("%s refused: the building is not on fire", nm); return; }
    target = (void *)(g_base + g_hit[CALL_SIG[which]].rva);
    /* FINISH, BURN and FIREOUT are the host's word: what they do to stock is remembered, not put back (GOODS) */
    if (which >= 2) G.own++;
    __try {
        if (which == 3) ((burn_fn)target)((void *)(uintptr_t)addr, 1000000.0f);
        else if (which >= 2) ((building_fn)target)((void *)(uintptr_t)addr);
        else ((squad_fn)target)((void *)(uintptr_t)addr, handle);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        faulted = 1; code = GetExceptionCode();
    }
    if (which >= 2) { G.own--; if (!faulted && which != 3) goods_resnap((uint8_t *)(uintptr_t)addr); }
    if (faulted) {
        g_calls_failed++;
        g_call_ok[which] = 0;
        _snprintf(g_call_why[which], sizeof(g_call_why[which]), "exception %08lX in an earlier call", code);
        log_line("%s(%llX, %d) raised exception %08lX: %s is now unavailable", nm, addr, handle, code, nm);
        return;
    }
    g_calls_n[which]++;
    if (which >= 2) log_line("%s(%llX) called", nm, addr);
    else log_line("%s(%llX, %d) called", nm, addr, handle);
}

/* PILEGONE <building>: the host's pile (what a demolished building leaves, type 58h) is gone, so this copy's pile goes
 * too. With GOODS on a pile never empties by itself here. Its records are emptied with the game's own addToInventory
 * and then the game's own recountStorage is called the way the game's carriers call it (second argument 1): that is
 * the branch which removes an empty pile. The third argument's block is the one addToInventory itself passes. */
static void goods_pilegone(int argc, char **argv)
{
    unsigned long long addr = 0;
    char why[200];
    uint8_t *b;
    garr *a;
    snap_t *s;
    int i, guard;
    struct { double z[2]; double k; } arg;
    g_dirty = 1;
    if (!G.avail || !goods_bytes_on()) { g_calls_failed++; log_line("PILEGONE refused: GOODS is not on"); return; }
    if (argc != 2 || !parse_u64(argv[1], &addr)) { g_calls_failed++; log_line("PILEGONE refused: needs exactly 1 argument (address)"); return; }
    if (!comp_sane(addr, FINISH_CHECK_BYTES, why, sizeof(why))) { g_calls_failed++; log_line("PILEGONE refused: %s", why); return; }
    b = (uint8_t *)(uintptr_t)addr; a = (garr *)(b + INV_OFF);
    if (*(int32_t *)(b + BTYPE_OFF) != PILE_TYPE) { g_calls_failed++; log_line("PILEGONE refused: building %llX is type %d, not a pile", addr, *(int32_t *)(b + BTYPE_OFF)); return; }
    if (!list_sane(a)) { g_calls_failed++; log_line("PILEGONE refused: the building's list does not look like one"); return; }
    s = snap_find(b);
    if (s) snap_del(s);
    G.own++;
    __try {
        for (guard = 0; guard < 64 && a->num > 0; guard++) {
            fgood g;
            for (i = 0; i < a->num; i++) a->data[i].amt = 0;
            g.type = a->data[0].type; g.amt = -1; g.p1 = NULL; g.p2 = NULL;
            ((addinv_fn)(void *)G.e_addinv)(b, &g);                 /* removes every record at or below nothing */
        }
        arg.z[0] = 0.0; arg.z[1] = 0.0;
        {   int32_t rel; memcpy(&rel, G.e_addinv + 0x26, 4); memcpy(&arg.k, G.e_addinv + 0x2A + rel, 8); }   /* movsd xmm1,[rip+rel] at +22h */
        ((recount_fn)(void *)G.e_recount)(b, 1, 1, &arg);
        G.pilegone++;
        log_line("PILEGONE(%llX): emptied and recounted", addr);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        g_calls_failed++;
        log_line("PILEGONE(%llX) raised exception %08lX", addr, GetExceptionCode());
    }
    G.own--;
    s = snap_find(b);                                               /* a hook remembered it again during the call */
    if (s) snap_del(s);
}

/* ------------------------------------------------------------------ TOTALS: a region's totals change only on the host's word
 * (lane 22: research\2026-11-10-game-probe\lanes\lane_s21_22\report.txt)
 *
 * Why: a region's totals (the top bar; the list at region +528h that Region::getStockOfGood reads) are the region's
 * buildings plus what its people carry. With GOODS the buildings are the host's, but what is carried is each copy's
 * own, so the totals differ. The game changes that list only through "add a list of goods to a list" (ADDLIST,
 * 4b73d00), at six call sites (TS1-TS6). ADDLIST's entry is hooked as GOODS hooks its two entries. For a region the
 * mod has named (TOTALS SET), a call whose list is that region's totals is not run: its change is added to the DLL's
 * SHADOW of those totals instead (the game's own bookkeeping, as the totals would be without the switch). Every other
 * list, and every other region's totals, is left to the game.
 *   TOTALS ON               writes the hook (nothing tracked yet: every call passes)
 *   TOTALS SET <region> <good>=<amount>,...
 *                           tracks the region from now on (its shadow starts as its totals now) and writes the
 *                           listed amounts with the game's own ADDLIST, then calls the region's NOTIFY with the change
 *   TOTALS OFF              the RECOUNT: every tracked region that is still the same object gets its shadow written
 *                           back (so its totals are again its own buildings plus hands, by the game's own sums), then
 *                           the hook goes
 *   TOTALS FORGET           the same without writing (after a load the regions are new objects)
 *   TOTALS AUDIT            every tracked region's totals against what was last written: a difference is a change
 *                           that did not go through ADDLIST ("leak"); logged, counted, written back
 *   TOTALS DUMP             totals_dump.txt: per tracked region the totals and the shadow */
#define REG_MAX      16
#define TOT_MAX      512
#define REGION_CHECK 0x600
typedef void (*addlist_fn)(garr *list, const garr *src, int negate, int removeEmpty);
typedef void (*notify_fn)(void *region, const garr *src);
/* a region has two such lists: +528h the totals, +538h the totals minus what is reserved (the top bar shows it when the
 * player's "surplus" view is on: Region::getStockOfGood(good, minusReserved = 1) reads +538h; lane 22 saw the bar
 * show it). Both change only through ADDLIST; both are kept. */
#define TOT_LISTS 2
static const uint32_t TOT_LIST_OFF[TOT_LISTS] = { TOTALS_OFF, TOTALS_OFF_R };
static const char *const TOT_LIST_NAME[TOT_LISTS] = { "totals", "minus-reserved" };
typedef struct {
    int ns; int32_t st[TOT_MAX], sa[TOT_MAX];       /* shadow: the game's own list */
    int nl; int32_t lt[TOT_MAX], la[TOT_MAX];       /* the list as last written (for the audit) */
} tl_t;
typedef struct {
    uint8_t *r; uint32_t idx; uint64_t name;
    tl_t L[TOT_LISTS];
} treg_t;
static struct {
    int avail; char why[120];
    volatile LONG enabled; int own; DWORD thread;
    uint8_t *e_addlist, *e_notify, *stub;
    uint8_t jmp[TOTALS_HOOK_LEN];
    volatile LONG want_off; DWORD fault_code;
    int n; treg_t reg[REG_MAX];
    unsigned long long calls, skipped, skipunits, sets, setunits, recounts, recountunits, recountbad, forgot, otherthread, faults, audits, leaks, leakunits, badsrc;
} T;

static int totals_bytes_on(void)  { return T.stub && T.e_addlist && memcmp(T.e_addlist, T.jmp, TOTALS_HOOK_LEN) == 0; }
static int totals_bytes_off(void) { return T.e_addlist && memcmp(T.e_addlist, TOTALS_ORIG_ADDLIST, TOTALS_HOOK_LEN) == 0; }

static int totals_status(char *buf, size_t len)
{
    int n = 0;
    if (g_off || !T.avail) n += _snprintf(buf + n, len - (size_t)n, "TOTALS unavailable %s\r\n", g_off ? "dll is off" : T.why);
    else n += _snprintf(buf + n, len - (size_t)n, "TOTALS %s\r\n", totals_bytes_on() ? "on" : totals_bytes_off() ? "off" : "unavailable its entry holds unknown bytes");
    n += _snprintf(buf + n, len - (size_t)n,
                   "totals regions=%d calls=%llu skipped=%llu skipunits=%llu sets=%llu setunits=%llu recounts=%llu recountunits=%llu recountbad=%llu forgot=%llu "
                   "otherthread=%llu badsrc=%llu faults=%llu audits=%llu leaks=%llu leakunits=%llu\r\n",
                   T.n, T.calls, T.skipped, T.skipunits, T.sets, T.setunits, T.recounts, T.recountunits, T.recountbad, T.forgot,
                   T.otherthread, T.badsrc, T.faults, T.audits, T.leaks, T.leakunits);
    return n < 0 ? 0 : n;
}

static const uint8_t *mem_at(uint32_t rva, void *ctx) { (void)ctx; return g_base + rva; }

static int totals_scan(void)
{
    memset(&T, 0, sizeof(T));
    T.avail = totals_check(g_hit, mem_at, NULL, (uint64_t)(uintptr_t)(g_base + g_hit[S_ADDLIST].rva), T.why, sizeof(T.why));
    if (T.avail) { T.e_addlist = g_base + g_hit[S_ADDLIST].rva; T.e_notify = g_base + g_hit[S_NOTIFY].rva; }
    log_line("  TOTALS %s %s", T.avail ? "off" : "unavailable", T.avail ? "" : T.why);
    return T.avail;
}

/* add src (negated when asked) to a per-good sum table; returns the units moved */
static unsigned long long sum_add(int32_t *ty, int32_t *am, int *n, const garr *src, int negate)
{
    unsigned long long u = 0;
    int i, j;
    for (i = 0; i < src->num; i++) {
        int32_t d = src->data[i].amt;
        if (!d) continue;
        if (negate) d = -d;
        for (j = 0; j < *n; j++) if (ty[j] == src->data[i].type) break;
        if (j == *n) { if (*n >= TOT_MAX) continue; ty[j] = src->data[i].type; am[j] = 0; (*n)++; }
        am[j] += d; u += absdiff(d, 0);
    }
    return u;
}

static int32_t list_have(const garr *a, int32_t type)
{
    int32_t h = 0; int i;
    for (i = 0; i < a->num; i++) if (a->data[i].type == type) h += a->data[i].amt;
    return h;
}

/* the hook: list = rcx at ADDLIST's entry; frame = { r9, r8, rdx, rcx, return address }. Returns 1 = do not run it. */
static int totals_event(garr *list, uint64_t *frame)
{
    int i, k = 0;
    if (!T.enabled || T.own || !T.n) return 0;
    for (i = 0; i < T.n; i++) {
        for (k = 0; k < TOT_LISTS; k++) if ((uint8_t *)list == T.reg[i].r + TOT_LIST_OFF[k]) break;
        if (k < TOT_LISTS) break;
    }
    if (i == T.n) return 0;
    if (GetCurrentThreadId() != T.thread) { T.otherthread++; return 0; }
    {
        const garr *src = (const garr *)(uintptr_t)frame[2];
        tl_t *l = &T.reg[i].L[k];
        T.calls++;
        if (!src || !list_sane(src)) { T.badsrc++; return 1; }
        T.skipunits += sum_add(l->st, l->sa, &l->ns, src, (uint8_t)frame[1] != 0);
        T.skipped++;
        return 1;
    }
}

static void totals_fault(DWORD code)
{
    InterlockedExchange(&T.enabled, 0);
    T.faults++; T.fault_code = code;
    InterlockedExchange(&T.want_off, 1);
}

static int totals_hook_wd(garr *list, uint64_t *frame)
{
    __try { return totals_event(list, frame); }
    __except (EXCEPTION_EXECUTE_HANDLER) { totals_fault(GetExceptionCode()); return 0; }
}
static int totals_hook(garr *list, uint64_t *frame)   /* lane 51: the watchdog's marks around it */
{
    int r; wd_in(WD_TOT); r = totals_hook_wd(list, frame); wd_out(WD_TOT); return r;
}

/* stub: push rcx rdx r8 r9; sub rsp,28h; lea rdx,[rsp+28h]; mov rax,<hook>; call rax; add rsp,28h; pop r9 r8 rdx rcx;
 * test eax,eax; jz +1; ret; <the entry's first instruction>; jmp [rip+0] -> entry + 5 */
static int totals_make_stub(void)
{
    static const uint8_t pre[]  = { 0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x48, 0x83, 0xEC, 0x28, 0x48, 0x8D, 0x54, 0x24, 0x28, 0x48, 0xB8 };
    static const uint8_t post[] = { 0xFF, 0xD0, 0x48, 0x83, 0xC4, 0x28, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59, 0x85, 0xC0, 0x74, 0x01, 0xC3 };
    uint8_t *p = alloc_near(g_base, g_imgsize), *resume;
    void *fn = (void *)&totals_hook;
    size_t n = 0;
    int32_t rel;
    DWORD old;
    if (!p) return 0;
    resume = T.e_addlist + TOTALS_HOOK_LEN;
    memcpy(p + n, pre, sizeof(pre)); n += sizeof(pre);
    memcpy(p + n, &fn, 8); n += 8;
    memcpy(p + n, post, sizeof(post)); n += sizeof(post);
    memcpy(p + n, TOTALS_ORIG_ADDLIST, TOTALS_HOOK_LEN); n += TOTALS_HOOK_LEN;
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0;
    memcpy(p + n, &resume, 8);
    rel = (int32_t)((intptr_t)p - (intptr_t)(T.e_addlist + TOTALS_HOOK_LEN));
    T.jmp[0] = 0xE9; memcpy(T.jmp + 1, &rel, 4);
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    T.stub = p;
    log_line("TOTALS: stub at %p (ADDLIST entry %p)", (void *)p, (void *)T.e_addlist);
    return 1;
}

static void totals_unhook(void)
{
    char w[160];
    int r;
    InterlockedExchange(&T.enabled, 0);
    if (!T.avail || !T.stub) return;
    if (memcmp(T.e_addlist, T.jmp, TOTALS_HOOK_LEN) == 0) {
        r = write_bytes(T.e_addlist, T.jmp, TOTALS_ORIG_ADDLIST, TOTALS_HOOK_LEN, w, sizeof(w));
        if (r != 1) { log_line("TOTALS: the ADDLIST entry could not be restored: %s", w); if (r < 0) internal_failure("totals restore failed"); }
    }
    g_dirty = 1;
}

static void totals_on(void)
{
    char w[160];
    int r;
    g_dirty = 1;
    if (!T.avail) { log_line("TOTALS ON refused: unavailable (%s)", T.why); return; }
    if (!T.stub && !totals_make_stub()) {
        T.avail = 0; _snprintf(T.why, sizeof(T.why), "no free memory near the game module for the stub");
        log_line("TOTALS ON refused: %s", T.why); return;
    }
    if (totals_bytes_on()) { InterlockedExchange(&T.enabled, 1); log_line("TOTALS already on"); return; }
    if (!totals_bytes_off()) { T.avail = 0; _snprintf(T.why, sizeof(T.why), "the entry holds neither its own bytes nor this DLL's jump"); log_line("TOTALS ON refused: %s", T.why); return; }
    T.n = 0; T.own = 0; T.thread = GetCurrentThreadId();
    InterlockedExchange(&T.want_off, 0);
    InterlockedExchange(&T.enabled, 1);
    r = write_bytes(T.e_addlist, TOTALS_ORIG_ADDLIST, T.jmp, TOTALS_HOOK_LEN, w, sizeof(w));
    if (r != 1) {
        InterlockedExchange(&T.enabled, 0);
        T.avail = 0; _snprintf(T.why, sizeof(T.why), "%s", w);
        log_line("TOTALS ON FAILED: %s; item marked unavailable", w);
        if (r < 0) internal_failure("totals hook write failed");
        return;
    }
    log_line("TOTALS on: ADDLIST at %p", (void *)T.e_addlist);
}

/* the region is still the object it was when it was taken in */
static int treg_alive(const treg_t *g)
{
    if (!range_readable(g->r, REGION_CHECK)) return 0;
    return *(const uint32_t *)(g->r + OBJ_INDEX_OFF) == g->idx && *(const uint64_t *)(g->r + OBJ_NAME_OFF) == g->name;
}

/* write want[] (types ty, amounts am, n of them; types of the list not named stay as they are unless `all`) into list
 * k of the region with the game's ADDLIST, then NOTIFY with the change. Returns the units changed. */
static unsigned long long totals_write(treg_t *g, int k, const int32_t *ty, const int32_t *am, int n, int all)
{
    static fgood d[TOT_MAX];
    garr *list = (garr *)(g->r + TOT_LIST_OFF[k]), src;
    int i, j, nd = 0;
    unsigned long long u = 0;
    if (!list_sane(list)) return 0;
    for (i = 0; i < n && nd < TOT_MAX; i++) {
        int32_t dl = am[i] - list_have(list, ty[i]);
        if (dl) { d[nd].type = ty[i]; d[nd].amt = dl; d[nd].p1 = NULL; d[nd].p2 = NULL; nd++; u += absdiff(dl, 0); }
    }
    if (all) {      /* kinds the list has and want[] does not: to nothing */
        for (i = 0; i < list->num && nd < TOT_MAX; i++) {
            int32_t t = list->data[i].type, h;
            for (j = 0; j < n; j++) if (ty[j] == t) break;
            if (j < n) continue;
            for (j = 0; j < nd; j++) if (d[j].type == t) break;
            if (j < nd) continue;
            h = list_have(list, t);
            if (h) { d[nd].type = t; d[nd].amt = -h; d[nd].p1 = NULL; d[nd].p2 = NULL; nd++; u += absdiff(h, 0); }
        }
    }
    if (!nd) return 0;
    src.data = d; src.num = nd; src.max = nd;
    T.own = 1;
    /* the totals: records at or below nothing are removed, as the game does for +528h; the list minus reserved keeps
     * them (the game never removes there: it can hold a negative amount, a good reserved that is not in stock) */
    ((addlist_fn)(void *)T.e_addlist)(list, &src, 0, k == 0 ? 1 : 0);
    ((notify_fn)(void *)T.e_notify)(g->r, &src);
    T.own = 0;
    return u;
}

static void treg_remember(treg_t *g, int k)
{
    garr *list = (garr *)(g->r + TOT_LIST_OFF[k]);
    tl_t *l = &g->L[k];
    l->nl = 0;
    if (list_sane(list)) sum_add(l->lt, l->la, &l->nl, list, 0);
}

static void totals_drop(int recount, const char *why)
{
    int i, k;
    for (i = 0; i < T.n; i++) {
        treg_t *g = &T.reg[i];
        if (!recount) { T.forgot++; continue; }
        __try {
            if (!treg_alive(g)) { T.forgot++; log_line("TOTALS: region %p is no longer the same object: forgotten, not written", (void *)g->r); continue; }
            for (k = 0; k < TOT_LISTS; k++) {
                tl_t *s = &g->L[k];
                unsigned long long u = totals_write(g, k, s->st, s->sa, s->ns, 1);
                garr *l = (garr *)(g->r + TOT_LIST_OFF[k]);
                int j, bad = 0;
                T.recounts++; T.recountunits += u;
                /* read back: every good of the shadow, and nothing else, must now be in the list */
                for (j = 0; j < s->ns; j++) if (list_have(l, s->st[j]) != (k == 0 && s->sa[j] < 0 ? 0 : s->sa[j])) bad++;   /* totals: at or below nothing removed */
                for (j = 0; j < l->num; j++) { int q; for (q = 0; q < s->ns; q++) if (s->st[q] == l->data[j].type) break; if (q == s->ns && l->data[j].amt) bad++; }
                T.recountbad += (unsigned long long)bad;
                log_line("TOTALS recount: region %p, list %s back to the game's own (%llu units changed; read back: %d goods differ from the shadow)", (void *)g->r, TOT_LIST_NAME[k], u, bad);
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            T.own = 0;
            log_line("TOTALS recount of region %p raised exception %08lX", (void *)g->r, GetExceptionCode());
        }
    }
    T.n = 0;
    totals_unhook();
    log_line("TOTALS off (%s)", why);
}

static treg_t *treg_find(uint8_t *r)
{
    int i;
    for (i = 0; i < T.n; i++) if (T.reg[i].r == r) return &T.reg[i];
    return NULL;
}

/* TOTALS SET <region> <good>=<amount>,<good>=<amount>,... [ALL]   the totals (+528h)
 * TOTALS SETR <region> ...                                       the totals minus what is reserved (+538h)
 * (the list may be empty: "-"). With ALL every good the list does not name is set to nothing. */
static void totals_set(int argc, char **argv, int k)
{
    unsigned long long a = 0;
    char why[200], *p;
    treg_t *g;
    int32_t ty[TOT_MAX], am[TOT_MAX];
    int n = 0, all = 0, q;
    g_dirty = 1;
    if (!T.avail || !totals_bytes_on() || !T.enabled) { log_line("TOTALS SET refused: TOTALS is not on"); return; }
    if (argc == 5 && _stricmp(argv[4], "ALL") == 0) { all = 1; argc = 4; }
    if (argc != 4 || !parse_u64(argv[2], &a)) { log_line("TOTALS SET refused: needs <region> <good>=<amount>,... [ALL]"); return; }
    p = argv[3];
    if (strcmp(p, "-") != 0) {
        while (*p) {
            char *end; long long t, v;
            t = _strtoi64(p, &end, 10);
            if (end == p || *end != '=') { log_line("TOTALS SET refused: bad list near '%.20s'", p); return; }
            p = end + 1;
            v = _strtoi64(p, &end, 10);
            if (end == p || (*end && *end != ',') || t < INT_MIN || t > INT_MAX || v < INT_MIN || v > INT_MAX) { log_line("TOTALS SET refused: bad list near '%.20s'", p); return; }
            if (n >= TOT_MAX) { log_line("TOTALS SET refused: more than %d goods", TOT_MAX); return; }
            ty[n] = (int32_t)t; am[n] = (int32_t)v; n++;
            p = *end ? end + 1 : end;
        }
    }
    g = treg_find((uint8_t *)(uintptr_t)a);
    __try {
        if (g && !treg_alive(g)) { *g = T.reg[--T.n]; g = NULL; T.forgot++; }
        if (!g) {
            if (!comp_sane(a, REGION_CHECK, why, sizeof(why))) { log_line("TOTALS SET refused: %s", why); return; }
            for (q = 0; q < TOT_LISTS; q++)
                if (!list_sane((garr *)(uintptr_t)(a + TOT_LIST_OFF[q]))) { log_line("TOTALS SET refused: region %llX has no list at +%Xh", a, TOT_LIST_OFF[q]); return; }
            if (T.n >= REG_MAX) { log_line("TOTALS SET refused: %d regions tracked already", REG_MAX); return; }
            g = &T.reg[T.n++];
            memset(g, 0, sizeof(*g));
            g->r = (uint8_t *)(uintptr_t)a;
            g->idx = *(uint32_t *)(g->r + OBJ_INDEX_OFF); g->name = *(uint64_t *)(g->r + OBJ_NAME_OFF);
            for (q = 0; q < TOT_LISTS; q++) {       /* the shadows start as the game's lists now; both are kept from now on */
                sum_add(g->L[q].st, g->L[q].sa, &g->L[q].ns, (garr *)(g->r + TOT_LIST_OFF[q]), 0);
                treg_remember(g, q);
            }
            log_line("TOTALS: region %llX tracked from now on (%d kinds in its totals, %d in the list minus reserved)", a, g->L[0].ns, g->L[1].ns);
        }
        T.setunits += totals_write(g, k, ty, am, n, all);
        T.sets++;
        treg_remember(g, k);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        T.own = 0;
        totals_fault(GetExceptionCode());
        log_line("TOTALS SET(%llX) raised exception %08lX", a, GetExceptionCode());
    }
}

static void totals_audit(void)
{
    int i, j, k, said = 0;
    if (!T.enabled) return;
    __try {
        for (i = 0; i < T.n; i++) {
            treg_t *g = &T.reg[i];
            if (!treg_alive(g)) continue;
            for (k = 0; k < TOT_LISTS; k++) {
                tl_t *s = &g->L[k];
                garr *list = (garr *)(g->r + TOT_LIST_OFF[k]);
                int32_t ty[TOT_MAX], am[TOT_MAX];
                int n = 0, bad = 0;
                if (!list_sane(list)) continue;
                sum_add(ty, am, &n, list, 0);
                for (j = 0; j < s->nl; j++) {
                    int32_t h = list_have(list, s->lt[j]);
                    if (h != s->la[j]) { bad = 1; T.leakunits += absdiff(h, s->la[j]); if (said++ < 8) log_line("TOTALS leak: region %p list %s good %d is %d, last written %d", (void *)g->r, TOT_LIST_NAME[k], s->lt[j], h, s->la[j]); }
                }
                for (j = 0; j < n; j++) {
                    int q;
                    for (q = 0; q < s->nl; q++) if (s->lt[q] == ty[j]) break;
                    if (q == s->nl && am[j]) { bad = 1; T.leakunits += absdiff(am[j], 0); if (said++ < 8) log_line("TOTALS leak: region %p list %s good %d is %d, not written", (void *)g->r, TOT_LIST_NAME[k], ty[j], am[j]); }
                }
                if (bad) { T.leaks++; totals_write(g, k, s->lt, s->la, s->nl, 1); treg_remember(g, k); }
            }
        }
        T.audits++;
    } __except (EXCEPTION_EXECUTE_HANDLER) { T.own = 0; totals_fault(GetExceptionCode()); }
    g_dirty = 1;
}

/* totals_dump.txt: per region the lines "shadow", "totals" (+528h), then "shadowR", "totalsR" (+538h) */
static void totals_dump(void)
{
    wchar_t path[MAX_PATH];
    FILE *f;
    int i, j, k;
    join_path(path, g_dir, L"totals_dump.txt");
    f = _wfopen(path, L"wb");
    if (!f) return;
    __try {
        for (i = 0; i < T.n; i++) {
            treg_t *g = &T.reg[i];
            fprintf(f, "region %p alive=%d\r\n", (void *)g->r, treg_alive(g));
            for (k = 0; k < TOT_LISTS; k++) {
                tl_t *s = &g->L[k];
                fprintf(f, "shadow%s", k ? "R" : "");
                for (j = 0; j < s->ns; j++) if (s->sa[j]) fprintf(f, " %d=%d", s->st[j], s->sa[j]);
                fprintf(f, "\r\ntotals%s", k ? "R" : "");
                if (treg_alive(g)) {
                    garr *l = (garr *)(g->r + TOT_LIST_OFF[k]);
                    if (list_sane(l)) for (j = 0; j < l->num; j++) fprintf(f, " %d=%d", l->data[j].type, l->data[j].amt);
                }
                fprintf(f, "\r\n");
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { fprintf(f, "exception\r\n"); }
    fclose(f);
    log_line("TOTALS DUMP: %d regions written to totals_dump.txt", T.n);
}

static void totals_tick(void)
{
    if (!T.want_off) return;
    InterlockedExchange(&T.want_off, 0);
    log_line("TOTALS: exception %08lX in the hook or a write: the switch is taken out (nothing written back)", T.fault_code);
    totals_drop(0, "exception");
    T.avail = 0; _snprintf(T.why, sizeof(T.why), "exception %08lX in the hook or a write", T.fault_code);
    g_dirty = 1;
}

/* ------------------------------------------------------------------ HOLD: a region's panel numbers change only on the host's word
 * (lane 31: research\2026-11-10-game-probe\lanes\lane_s21_31\report.txt)
 *
 * Why: approval, its factor rows, public order, the months of food and fuel, the regional wealth and the problem list
 * of a region are each copy's own sums: a friend's day routine rebuilds approval from its own families' memories (one
 * more "cold" row on a friend whose homes were refuelled one day later), its villagers' market trade moves its own
 * wealth, and its own checks add and remove problems. Written from outside, a friend's own value shows for a moment.
 * HOLD makes those routines not run for a region the mod has named, on a friend's copy; the mod then writes the
 * host's values (Approval, publicOrder, the months and the wealth through reflection; the lists through this DLL).
 *   HOLD ON                       writes the seven entry hooks and the store site (all or none)
 *   HOLD SET <region>             holds the region from now on
 *   HOLD ROWS <region> A|O|M <type>:<past>:<effect>:<day>:<expires>:<count>/...  or  -
 *                                 writes a whole list of approval records (A summedApprovalFactors +1038h, O
 *                                 summedPublicOrderFactors +1060h, M publicOrderMemory +1050h); a longer list is
 *                                 grown with the game's own helper, a shorter one cut by its length
 *   HOLD PROB <region> <type>:<building>:<unit>/...  or  -
 *                                 makes the region's problem list hold exactly these, with the game's own add and
 *                                 remove routines (each passes the hook: this DLL's own call)
 *   HOLD OFF                      the recount: every held region's approval is rebuilt once by the game's own
 *                                 updateApproval (from its own families), then the hooks go; the other numbers follow
 *                                 at the next day change (public order and the months) or stay as last written (wealth)
 *   HOLD FORGET                   the same without the recount (after a load the regions are other objects)
 *   HOLD DUMP                     hold_dump.txt: per held region the numbers and lists as they are
 * A held wealth routine returns what the game would have returned (consume: settled and enough wealth; add problem:
 * the problem was there), so the callers branch as on the host. Calls from another thread pass and are counted. */
#define HOLD_REG_MAX   16
#define HOLD_CHECK     0x1100
#define APPROVAL_OFF   0x1030
#define ORDER_VAL_OFF  0x104C
#define ROWS_A_OFF     0x1038
#define ROWS_M_OFF     0x1050
#define ROWS_O_OFF     0x1060
#define PROBLEMS_OFF   0xD80
#define WEALTH_OFF     0x648
#define SETTLED_OFF    0x2E8
#define HOLD_ROWS_MAX  512
#define HOLD_PROB_MAX  512
typedef struct { int32_t type, day, exp, count; uint8_t past, pad[3]; float effect; } amem;     /* ApprovalMemory, 0x18 */
typedef struct { amem *data; int32_t num, max; } aarr;
typedef struct { uint8_t type, pad[7]; void *unit; void *building; double loc[3]; int32_t day, expires; } prob_t;   /* Problem, 0x38 */
typedef struct { prob_t *data; int32_t num, max; } parr;
typedef char (*hold_bool_fn)(void *region, int a, void *b, void *c);
typedef void (*hold_void_fn)(void *region, int a, void *b, void *c);
typedef void (*grow_fn)(void *arr, int oldNum);
typedef void (*region_fn)(void *region);
typedef char hold_sizes_ok[(sizeof(amem) == 0x18 && sizeof(prob_t) == 0x38) ? 1 : -1];
static struct {
    int avail; char why[160];
    volatile LONG enabled; int own; DWORD thread;
    uint8_t *e[HOLD_GATES], *wmon, *stub, *grow;
    uint8_t jmp[HOLD_GATES][8], wjmp[5];
    volatile LONG want_off; DWORD fault_code;
    int n; struct { uint8_t *r; uint32_t idx; uint64_t name; } reg[HOLD_REG_MAX];
    unsigned long long calls[HOLD_GATES], held[HOLD_GATES], wcalls, wheld, otherthread, faults, sets, rows, grown, padds, prems, recounts, forgot, refused;
} H;

static int hold_bytes_on(void)
{
    int k;
    if (!H.stub) return 0;
    for (k = 0; k < HOLD_GATES; k++) if (memcmp(H.e[k], H.jmp[k], (size_t)HOLD_LEN[k]) != 0) return 0;
    return memcmp(H.wmon, H.wjmp, 5) == 0;
}
static int hold_bytes_off(void)
{
    int k;
    for (k = 0; k < HOLD_GATES; k++) if (!H.e[k] || memcmp(H.e[k], HOLD_ORIG[k], (size_t)HOLD_LEN[k]) != 0) return 0;
    return H.wmon && memcmp(H.wmon, HOLD_WMON_ORIG, 5) == 0;
}

static int hold_status(char *buf, size_t len)
{
    int n = 0;
    if (g_off || !H.avail) n += _snprintf(buf + n, len - (size_t)n, "HOLD unavailable %s\r\n", g_off ? "dll is off" : H.why);
    else n += _snprintf(buf + n, len - (size_t)n, "HOLD %s\r\n", hold_bytes_on() ? "on" : hold_bytes_off() ? "off" : "unavailable its entries hold unknown bytes");
    n += _snprintf(buf + n, len - (size_t)n,
                   "hold regions=%d approval=%llu/%llu order=%llu/%llu supplies=%llu/%llu wealthAdd=%llu/%llu wealthSub=%llu/%llu problemAdd=%llu/%llu problemRemove=%llu/%llu "
                   "problemRemoveAll=%llu/%llu emigration=%llu/%llu housing=%llu/%llu wealthMonth=%llu/%llu otherthread=%llu sets=%llu rows=%llu grown=%llu padds=%llu prems=%llu recounts=%llu forgot=%llu refused=%llu faults=%llu\r\n",
                   H.n, H.calls[0], H.held[0], H.calls[1], H.held[1], H.calls[2], H.held[2], H.calls[3], H.held[3], H.calls[4], H.held[4], H.calls[5], H.held[5],
                   H.calls[6], H.held[6], H.calls[7], H.held[7], H.calls[8], H.held[8], H.calls[9], H.held[9], H.wcalls, H.wheld, H.otherthread, H.sets, H.rows, H.grown, H.padds, H.prems, H.recounts, H.forgot, H.refused, H.faults);
    return n < 0 ? 0 : n;
}

static int hold_scan(void)
{
    uint32_t grow = 0;
    int k;
    memset(&H, 0, sizeof(H));
    H.avail = hold_check(g_hit, mem_at, NULL, &grow, H.why, sizeof(H.why));
    if (H.avail) {
        for (k = 0; k < HOLD_GATES; k++) H.e[k] = g_base + g_hit[HOLD_SIG[k]].rva;
        H.wmon = g_base + g_hit[S_HWMON].rva + HOLD_WMON_OFF;
        H.grow = g_base + grow;
    }
    log_line("  HOLD   %s %s", H.avail ? "off" : "unavailable", H.avail ? "" : H.why);
    return H.avail;
}

static int hold_find(const uint8_t *r)
{
    int i;
    for (i = 0; i < H.n; i++) if (H.reg[i].r == r) return i;
    return -1;
}

/* the gates: region = rcx at the entry; frame = { r9, r8, rdx, rcx, return address }. 0 = run the game's routine,
 * 1 = do not run it and return 0 (al), 2 = do not run it and return 1 (al). */
static int hold_event(uint8_t *region, uint64_t *frame, int id)
{
    if (id < 0 || id >= HOLD_GATES) return 0;
    H.calls[id]++;
    if (!H.enabled || H.own || !H.n || hold_find(region) < 0) return 0;
    if (GetCurrentThreadId() != H.thread) { H.otherthread++; return 0; }
    H.held[id]++;
    if (HOLD_SIG[id] == S_HWSUB) {          /* consumeRegionalWealth: settled, and the wealth covers it */
        int32_t amt = (int32_t)(uint32_t)frame[2], w = *(int32_t *)(region + WEALTH_OFF);
        return (region[SETTLED_OFF] && (long long)w - (long long)amt >= 0) ? 2 : 1;
    }
    if (HOLD_SIG[id] == S_HPADD) {          /* add a problem: was it there already (type, building, unit)? */
        const parr *p = (const parr *)(region + PROBLEMS_OFF);
        uint8_t type = (uint8_t)frame[2];
        int i;
        if (p->num < 0 || p->num > 100000 || (p->num && !p->data)) return 1;
        for (i = 0; i < p->num; i++)
            if (p->data[i].type == type && (uint64_t)(uintptr_t)p->data[i].building == frame[1] && (uint64_t)(uintptr_t)p->data[i].unit == frame[0]) return 2;
        return 1;
    }
    return 1;
}

static void hold_fault(DWORD code)
{
    InterlockedExchange(&H.enabled, 0);
    H.faults++; H.fault_code = code;
    InterlockedExchange(&H.want_off, 1);
}

static int hold_gate_wd(uint8_t *region, uint64_t *frame, int id)
{
    __try { return hold_event(region, frame, id); }
    __except (EXCEPTION_EXECUTE_HANDLER) { hold_fault(GetExceptionCode()); return 0; }
}
static int hold_gate(uint8_t *region, uint64_t *frame, int id)   /* lane 51: the watchdog's marks around it */
{
    int r; wd_in(WD_HGATE); r = hold_gate_wd(region, frame, id); wd_out(WD_HGATE); return r;
}

/* the monthly wealth store: stores the game's new value unless the region is held (r15 = region, eax = value) */
static void hold_wmon_wd(uint8_t *region, int32_t value)
{
    int held = 0;
    __try {
        H.wcalls++;
        if (H.enabled && !H.own && H.n && hold_find(region) >= 0) {
            if (GetCurrentThreadId() == H.thread) { held = 1; H.wheld++; } else H.otherthread++;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { hold_fault(GetExceptionCode()); held = 0; }
    if (!held) *(int32_t *)(region + WEALTH_OFF) = value;      /* the game's own instruction (a fault here is the game's) */
}
static void hold_wmon(uint8_t *region, int32_t value)   /* lane 51: the watchdog's marks around it */
{
    wd_in(WD_HWMON); hold_wmon_wd(region, value); wd_out(WD_HWMON);
}

/* stubs. A gate: push rcx rdx r8 r9; sub rsp,28h; lea rdx,[rsp+28h]; mov r8d,<id>; mov rax,<hold_gate>; call rax;
 * add rsp,28h; pop r9 r8 rdx rcx; test eax,eax; jz run; dec eax; ret; run: <the entry's first bytes>; jmp [rip+0] ->
 * entry + len. The store site: push rax rcx rdx r8 r9 r10 r11 rbp; mov rbp,rsp; and rsp,-16; sub rsp,80h; xmm0-5 kept;
 * mov rcx,r15; mov edx,eax; mov rax,<hold_wmon>; call rax; xmm0-5 back; mov rsp,rbp; pop ... ; jmp [rip+0] -> site + 7 */
static size_t hold_emit_gate(uint8_t *p, int id)
{
    static const uint8_t pre[] = { 0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x48, 0x83, 0xEC, 0x28, 0x48, 0x8D, 0x54, 0x24, 0x28, 0x41, 0xB8 };
    static const uint8_t mid[] = { 0x48, 0xB8 };
    static const uint8_t post[] = { 0xFF, 0xD0, 0x48, 0x83, 0xC4, 0x28, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59, 0x85, 0xC0, 0x74, 0x03, 0xFF, 0xC8, 0xC3 };
    void *fn = (void *)&hold_gate;
    uint8_t *resume = H.e[id] + HOLD_LEN[id];
    int32_t idv = id;
    size_t n = 0;
    memcpy(p + n, pre, sizeof(pre)); n += sizeof(pre);
    memcpy(p + n, &idv, 4); n += 4;
    memcpy(p + n, mid, sizeof(mid)); n += sizeof(mid);
    memcpy(p + n, &fn, 8); n += 8;
    memcpy(p + n, post, sizeof(post)); n += sizeof(post);
    memcpy(p + n, HOLD_ORIG[id], (size_t)HOLD_LEN[id]); n += (size_t)HOLD_LEN[id];
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0;
    memcpy(p + n, &resume, 8); n += 8;
    return n;
}

static size_t hold_emit_wmon(uint8_t *p)
{
    static const uint8_t pre[] = { 0x50, 0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x41, 0x52, 0x41, 0x53, 0x55, 0x48, 0x8B, 0xEC, 0x48, 0x83, 0xE4, 0xF0,
                                   0x48, 0x81, 0xEC, 0x80, 0x00, 0x00, 0x00,
                                   0xF3, 0x0F, 0x7F, 0x44, 0x24, 0x20, 0xF3, 0x0F, 0x7F, 0x4C, 0x24, 0x30, 0xF3, 0x0F, 0x7F, 0x54, 0x24, 0x40,
                                   0xF3, 0x0F, 0x7F, 0x5C, 0x24, 0x50, 0xF3, 0x0F, 0x7F, 0x64, 0x24, 0x60, 0xF3, 0x0F, 0x7F, 0x6C, 0x24, 0x70,
                                   0x49, 0x8B, 0xCF, 0x8B, 0xD0, 0x48, 0xB8 };
    static const uint8_t post[] = { 0xFF, 0xD0,
                                    0xF3, 0x0F, 0x6F, 0x44, 0x24, 0x20, 0xF3, 0x0F, 0x6F, 0x4C, 0x24, 0x30, 0xF3, 0x0F, 0x6F, 0x54, 0x24, 0x40,
                                    0xF3, 0x0F, 0x6F, 0x5C, 0x24, 0x50, 0xF3, 0x0F, 0x6F, 0x64, 0x24, 0x60, 0xF3, 0x0F, 0x6F, 0x6C, 0x24, 0x70,
                                    0x48, 0x8B, 0xE5, 0x5D, 0x41, 0x5B, 0x41, 0x5A, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59, 0x58,
                                    0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 };
    void *fn = (void *)&hold_wmon;
    uint8_t *resume = H.wmon + HOLD_WMON_LEN;
    size_t n = 0;
    memcpy(p + n, pre, sizeof(pre)); n += sizeof(pre);
    memcpy(p + n, &fn, 8); n += 8;
    memcpy(p + n, post, sizeof(post)); n += sizeof(post);
    memcpy(p + n, &resume, 8); n += 8;
    return n;
}

static int hold_make_stub(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize);
    size_t n = 0;
    int k, j;
    int32_t rel;
    DWORD old;
    if (!p) return 0;
    for (k = 0; k < HOLD_GATES; k++) {
        size_t at = n;
        n += hold_emit_gate(p + n, k);
        n = (n + 15) & ~(size_t)15;
        rel = (int32_t)((intptr_t)(p + at) - (intptr_t)(H.e[k] + 5));
        H.jmp[k][0] = 0xE9; memcpy(&H.jmp[k][1], &rel, 4);
        for (j = 5; j < HOLD_LEN[k]; j++) H.jmp[k][j] = 0x90;          /* never run: the jump comes first */
    }
    rel = (int32_t)((intptr_t)(p + n) - (intptr_t)(H.wmon + 5));
    H.wjmp[0] = 0xE9; memcpy(&H.wjmp[1], &rel, 4);
    n += hold_emit_wmon(p + n);
    if (n > 0x1000) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    H.stub = p;
    log_line("HOLD: stubs at %p (%Iu bytes)", (void *)p, n);
    return 1;
}

/* put the original bytes back wherever this DLL's jump is (each on its own) */
static void hold_unhook(void)
{
    char w[160];
    int k, r;
    InterlockedExchange(&H.enabled, 0);
    if (!H.avail || !H.stub) return;
    for (k = 0; k < HOLD_GATES; k++)
        if (memcmp(H.e[k], H.jmp[k], (size_t)HOLD_LEN[k]) == 0) {
            r = write_bytes(H.e[k], H.jmp[k], HOLD_ORIG[k], HOLD_LEN[k], w, sizeof(w));
            if (r != 1) { log_line("HOLD: %s could not be restored: %s", SIGS[HOLD_SIG[k]].name, w); if (r < 0) internal_failure("hold restore failed"); }
        }
    if (memcmp(H.wmon, H.wjmp, 5) == 0) {
        r = write_bytes(H.wmon, H.wjmp, HOLD_WMON_ORIG, 5, w, sizeof(w));
        if (r != 1) { log_line("HOLD: HWMON could not be restored: %s", w); if (r < 0) internal_failure("hold restore failed"); }
    }
    g_dirty = 1;
}

static void hold_on(void)
{
    char w[160];
    int k, r = 1;
    g_dirty = 1;
    if (!H.avail) { log_line("HOLD ON refused: unavailable (%s)", H.why); return; }
    if (!H.stub && !hold_make_stub()) {
        H.avail = 0; _snprintf(H.why, sizeof(H.why), "no free memory near the game module for the stubs");
        log_line("HOLD ON refused: %s", H.why); return;
    }
    if (hold_bytes_on()) { InterlockedExchange(&H.enabled, 1); log_line("HOLD already on"); return; }
    if (!hold_bytes_off()) { H.avail = 0; _snprintf(H.why, sizeof(H.why), "an entry holds neither its own bytes nor this DLL's jump"); log_line("HOLD ON refused: %s", H.why); return; }
    H.n = 0; H.own = 0; H.thread = GetCurrentThreadId();
    InterlockedExchange(&H.want_off, 0);
    InterlockedExchange(&H.enabled, 1);
    for (k = 0; k < HOLD_GATES && r == 1; k++) {
        r = write_bytes(H.e[k], HOLD_ORIG[k], H.jmp[k], HOLD_LEN[k], w, sizeof(w));
        if (r != 1) log_line("HOLD ON: %s not written: %s", SIGS[HOLD_SIG[k]].name, w);
    }
    if (r == 1) { r = write_bytes(H.wmon, HOLD_WMON_ORIG, H.wjmp, 5, w, sizeof(w)); if (r != 1) log_line("HOLD ON: HWMON not written: %s", w); }
    if (r != 1) {
        hold_unhook();                                  /* all or none */
        H.avail = 0; _snprintf(H.why, sizeof(H.why), "%s", w);
        log_line("HOLD ON FAILED: %s; every hook taken out, item marked unavailable", w);
        if (r < 0) internal_failure("hold hook write failed");
        return;
    }
    log_line("HOLD on: %s %p %s %p %s %p %s %p %s %p %s %p %s %p, store %p", SIGS[S_HAPPR].name, (void *)H.e[0], SIGS[S_HORDER].name, (void *)H.e[1],
             SIGS[S_HSUPPL].name, (void *)H.e[2], SIGS[S_HWADD].name, (void *)H.e[3], SIGS[S_HWSUB].name, (void *)H.e[4], SIGS[S_HPADD].name, (void *)H.e[5],
             SIGS[S_HPREM].name, (void *)H.e[6], (void *)H.wmon);
}

static int hold_alive(int i)
{
    const uint8_t *r = H.reg[i].r;
    if (!range_readable(r, HOLD_CHECK)) return 0;
    return *(const uint32_t *)(r + OBJ_INDEX_OFF) == H.reg[i].idx && *(const uint64_t *)(r + OBJ_NAME_OFF) == H.reg[i].name;
}

static void hold_drop(int recount, const char *why)
{
    int i;
    for (i = 0; i < H.n; i++) {
        if (!recount) { H.forgot++; continue; }
        __try {
            if (!hold_alive(i)) { H.forgot++; log_line("HOLD: region %p is no longer the same object: forgotten", (void *)H.reg[i].r); continue; }
            H.own = 1;
            ((region_fn)(void *)H.e[0])(H.reg[i].r);     /* the game's own updateApproval: its approval from its own families */
            H.own = 0;
            H.recounts++;
            log_line("HOLD recount: region %p approval rebuilt by the game: %d (%d rows)", (void *)H.reg[i].r, *(int32_t *)(H.reg[i].r + APPROVAL_OFF), ((aarr *)(H.reg[i].r + ROWS_A_OFF))->num);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            H.own = 0;
            log_line("HOLD recount of region %p raised exception %08lX", (void *)H.reg[i].r, GetExceptionCode());
        }
    }
    H.n = 0;
    hold_unhook();
    log_line("HOLD off (%s)", why);
}

/* the region named in a command must be held (HOLD SET first) and still be the same object */
static int hold_region_arg(const char *s, uint8_t **r, const char *what)
{
    unsigned long long a = 0;
    int i;
    if (!parse_u64(s, &a)) { log_line("%s refused: '%s' is not an address", what, s); H.refused++; return -1; }
    i = hold_find((uint8_t *)(uintptr_t)a);
    if (i < 0) { log_line("%s refused: region %llX is not held (HOLD SET first)", what, a); H.refused++; return -1; }
    if (!hold_alive(i)) { log_line("%s refused: region %llX is no longer the same object", what, a); H.reg[i] = H.reg[--H.n]; H.forgot++; H.refused++; return -1; }
    *r = (uint8_t *)(uintptr_t)a;
    return i;
}

static int aarr_sane(const aarr *a) { return a->num >= 0 && a->num <= 100000 && a->max >= a->num && (a->num == 0 || a->data != NULL); }

static void hold_set(int argc, char **argv)
{
    unsigned long long a = 0;
    char why[200];
    uint8_t *r;
    int i;
    g_dirty = 1;
    if (!H.avail || !H.enabled || !hold_bytes_on()) { log_line("HOLD SET refused: HOLD is not on"); H.refused++; return; }
    if (argc != 3 || !parse_u64(argv[2], &a)) { log_line("HOLD SET refused: needs <region>"); H.refused++; return; }
    r = (uint8_t *)(uintptr_t)a;
    i = hold_find(r);
    __try {
        if (i >= 0 && hold_alive(i)) return;                          /* already held */
        if (i >= 0) { H.reg[i] = H.reg[--H.n]; H.forgot++; }
        if (!comp_sane(a, HOLD_CHECK, why, sizeof(why))) { log_line("HOLD SET refused: %s", why); H.refused++; return; }
        if (!aarr_sane((aarr *)(r + ROWS_A_OFF)) || !aarr_sane((aarr *)(r + ROWS_O_OFF)) || !aarr_sane((aarr *)(r + ROWS_M_OFF)) || !aarr_sane((aarr *)(r + PROBLEMS_OFF))) {
            log_line("HOLD SET refused: region %llX has no sane lists at +1038h/+1050h/+1060h/+D80h", a); H.refused++; return; }
        if (H.n >= HOLD_REG_MAX) { log_line("HOLD SET refused: %d regions held already", HOLD_REG_MAX); H.refused++; return; }
        H.reg[H.n].r = r; H.reg[H.n].idx = *(uint32_t *)(r + OBJ_INDEX_OFF); H.reg[H.n].name = *(uint64_t *)(r + OBJ_NAME_OFF); H.n++;
        H.sets++;
        log_line("HOLD: region %llX held from now on (approval %d, order %d, wealth %d, %d problems)", a, *(int32_t *)(r + APPROVAL_OFF), *(int32_t *)(r + ORDER_VAL_OFF),
                 *(int32_t *)(r + WEALTH_OFF), ((parr *)(r + PROBLEMS_OFF))->num);
    } __except (EXCEPTION_EXECUTE_HANDLER) { hold_fault(GetExceptionCode()); log_line("HOLD SET(%llX) raised exception %08lX", a, GetExceptionCode()); }
}

/* HOLD ROWS <region> A|O|M <type>:<past>:<effect>:<day>:<expires>:<count>/...  or  - */
static void hold_rows(int argc, char **argv)
{
    static amem want[HOLD_ROWS_MAX];
    uint8_t *r = NULL;
    aarr *a;
    char *p;
    int n = 0, i;
    uint32_t off;
    g_dirty = 1;
    if (!H.enabled || !hold_bytes_on()) { log_line("HOLD ROWS refused: HOLD is not on"); H.refused++; return; }
    if (argc != 5 || strlen(argv[3]) != 1) { log_line("HOLD ROWS refused: needs <region> A|O|M <rows>"); H.refused++; return; }
    switch (argv[3][0]) { case 'A': off = ROWS_A_OFF; break; case 'O': off = ROWS_O_OFF; break; case 'M': off = ROWS_M_OFF; break;
                          default: log_line("HOLD ROWS refused: list '%s' is not A, O or M", argv[3]); H.refused++; return; }
    p = argv[4];
    if (strcmp(p, "-") != 0) {
        while (*p) {
            char *end; long long t, past, day, ex, cnt; double eff;
            if (n >= HOLD_ROWS_MAX) { log_line("HOLD ROWS refused: more than %d rows", HOLD_ROWS_MAX); H.refused++; return; }
            t = _strtoi64(p, &end, 10); if (end == p || *end != ':') goto bad; p = end + 1;
            past = _strtoi64(p, &end, 10); if (end == p || *end != ':') goto bad; p = end + 1;
            eff = strtod(p, &end); if (end == p || *end != ':' || eff != eff || eff > 1e7 || eff < -1e7) goto bad; p = end + 1;
            day = _strtoi64(p, &end, 10); if (end == p || *end != ':') goto bad; p = end + 1;
            ex = _strtoi64(p, &end, 10); if (end == p || *end != ':') goto bad; p = end + 1;
            cnt = _strtoi64(p, &end, 10); if (end == p || (*end && *end != '/')) goto bad;
            if (t < 0 || t > 255 || (past != 0 && past != 1) || day < INT_MIN || day > INT_MAX || ex < INT_MIN || ex > INT_MAX || cnt < INT_MIN || cnt > INT_MAX) goto bad;
            memset(&want[n], 0, sizeof(want[n]));
            want[n].type = (int32_t)t; want[n].past = (uint8_t)past; want[n].effect = (float)eff; want[n].day = (int32_t)day; want[n].exp = (int32_t)ex; want[n].count = (int32_t)cnt;
            n++;
            p = *end ? end + 1 : end;
        }
    }
    if (hold_region_arg(argv[2], &r, "HOLD ROWS") < 0) return;
    a = (aarr *)(r + off);
    __try {
        if (!aarr_sane(a)) { log_line("HOLD ROWS refused: the list at +%Xh is not sane", off); H.refused++; return; }
        if (n > a->max) {                       /* the game's own grow helper: num first, then (list, old num) */
            int old = a->num;
            a->num = n;
            ((grow_fn)(void *)H.grow)(a, old);
            H.grown++;
            if (a->max < n || !a->data) { a->num = old < a->max ? old : a->max; log_line("HOLD ROWS: the grow helper left max %d for %d rows", a->max, n); H.refused++; return; }
        }
        for (i = 0; i < n; i++) a->data[i] = want[i];
        a->num = n;
        H.rows++;
    } __except (EXCEPTION_EXECUTE_HANDLER) { hold_fault(GetExceptionCode()); log_line("HOLD ROWS raised exception %08lX", GetExceptionCode()); }
    return;
bad:
    log_line("HOLD ROWS refused: bad row near '%.24s'", p); H.refused++;
}

/* HOLD PROB <region> <type>:<building>:<unit>/...  or  -   (addresses in decimal or 0x hex, 0 = none) */
static void hold_prob(int argc, char **argv)
{
    static struct { uint8_t type; void *b, *u; } want[HOLD_PROB_MAX], have[HOLD_PROB_MAX];
    uint8_t *r = NULL;
    parr *pl;
    char *p, why[200];
    int n = 0, nh = 0, i, j;
    g_dirty = 1;
    if (!H.enabled || !hold_bytes_on()) { log_line("HOLD PROB refused: HOLD is not on"); H.refused++; return; }
    if (argc != 4) { log_line("HOLD PROB refused: needs <region> <problems>"); H.refused++; return; }
    p = argv[3];
    if (strcmp(p, "-") != 0) {
        while (*p) {
            char *end, tmp[24]; long long t; unsigned long long b, u; size_t L;
            if (n >= HOLD_PROB_MAX) { log_line("HOLD PROB refused: more than %d problems", HOLD_PROB_MAX); H.refused++; return; }
            t = _strtoi64(p, &end, 10); if (end == p || *end != ':' || t < 0 || t > 255) goto bad; p = end + 1;
            end = strchr(p, ':'); if (!end || (L = (size_t)(end - p)) == 0 || L >= sizeof(tmp)) goto bad;
            memcpy(tmp, p, L); tmp[L] = 0; if (strcmp(tmp, "0") == 0) b = 0; else if (!parse_u64(tmp, &b)) goto bad; p = end + 1;
            end = p; while (*end && *end != '/') end++;
            L = (size_t)(end - p); if (L == 0 || L >= sizeof(tmp)) goto bad;
            memcpy(tmp, p, L); tmp[L] = 0; if (strcmp(tmp, "0") == 0) u = 0; else if (!parse_u64(tmp, &u)) goto bad;
            if (b && !comp_sane(b, 0x100, why, sizeof(why))) { log_line("HOLD PROB refused: building %s", why); H.refused++; return; }
            if (u && !comp_sane(u, 0x100, why, sizeof(why))) { log_line("HOLD PROB refused: unit %s", why); H.refused++; return; }
            want[n].type = (uint8_t)t; want[n].b = (void *)(uintptr_t)b; want[n].u = (void *)(uintptr_t)u; n++;
            p = *end ? end + 1 : end;
        }
    }
    if (hold_region_arg(argv[2], &r, "HOLD PROB") < 0) return;
    pl = (parr *)(r + PROBLEMS_OFF);
    __try {
        if (!aarr_sane((aarr *)pl) || pl->num > HOLD_PROB_MAX) { log_line("HOLD PROB refused: the problem list is not sane (%d)", pl->num); H.refused++; return; }
        for (i = 0; i < pl->num; i++) { have[nh].type = pl->data[i].type; have[nh].b = pl->data[i].building; have[nh].u = pl->data[i].unit; nh++; }
        H.own = 1;
        for (i = 0; i < nh; i++) {              /* what the host does not have: the game's own remove */
            for (j = 0; j < n; j++) if (want[j].type == have[i].type && want[j].b == have[i].b && want[j].u == have[i].u) break;
            if (j == n) { ((hold_void_fn)(void *)H.e[6])(r, have[i].type, have[i].b, have[i].u); H.prems++; }
        }
        for (j = 0; j < n; j++) {               /* what it has and this copy does not: the game's own add */
            for (i = 0; i < nh; i++) if (want[j].type == have[i].type && want[j].b == have[i].b && want[j].u == have[i].u) break;
            if (i == nh) { ((hold_bool_fn)(void *)H.e[5])(r, want[j].type, want[j].b, want[j].u); H.padds++; }
        }
        H.own = 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) { H.own = 0; hold_fault(GetExceptionCode()); log_line("HOLD PROB raised exception %08lX", GetExceptionCode()); }
    return;
bad:
    log_line("HOLD PROB refused: bad entry near '%.24s'", p); H.refused++;
}

static void hold_dump_list(FILE *f, const char *name, const aarr *a)
{
    int j;
    fprintf(f, "%s %d:", name, a->num);
    if (aarr_sane(a)) for (j = 0; j < a->num; j++) fprintf(f, " %d%s:%.4f d%d e%d c%d", a->data[j].type, a->data[j].past ? "p" : "", a->data[j].effect, a->data[j].day, a->data[j].exp, a->data[j].count);
    fprintf(f, "\r\n");
}

static void hold_dump(void)
{
    wchar_t path[MAX_PATH];
    FILE *f;
    int i, j;
    join_path(path, g_dir, L"hold_dump.txt");
    f = _wfopen(path, L"wb");
    if (!f) return;
    __try {
        for (i = 0; i < H.n; i++) {
            uint8_t *r = H.reg[i].r;
            const parr *pl;
            fprintf(f, "region %p alive=%d\r\n", (void *)r, hold_alive(i));
            if (!hold_alive(i)) continue;
            fprintf(f, "approval %d order %d wealth %d food %.4f fuel %.4f\r\n", *(int32_t *)(r + APPROVAL_OFF), *(int32_t *)(r + ORDER_VAL_OFF), *(int32_t *)(r + WEALTH_OFF),
                    *(float *)(r + 0x59C), *(float *)(r + 0x5A0));
            hold_dump_list(f, "rowsA", (aarr *)(r + ROWS_A_OFF));
            hold_dump_list(f, "rowsO", (aarr *)(r + ROWS_O_OFF));
            hold_dump_list(f, "rowsM", (aarr *)(r + ROWS_M_OFF));
            pl = (const parr *)(r + PROBLEMS_OFF);
            fprintf(f, "problems %d:", pl->num);
            if (aarr_sane((const aarr *)pl)) for (j = 0; j < pl->num; j++) fprintf(f, " %d:%p:%p", pl->data[j].type, pl->data[j].building, pl->data[j].unit);
            fprintf(f, "\r\n");
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { fprintf(f, "exception\r\n"); }
    fclose(f);
    log_line("HOLD DUMP: %d regions written to hold_dump.txt", H.n);
}

static void hold_tick(void)
{
    if (!H.want_off) return;
    InterlockedExchange(&H.want_off, 0);
    log_line("HOLD: exception %08lX in a hook or a write: the switch is taken out (no recount)", H.fault_code);
    hold_drop(0, "exception");
    H.avail = 0; _snprintf(H.why, sizeof(H.why), "exception %08lX in a hook or a write", H.fault_code);
    g_dirty = 1;
}

/* ------------------------------------------------------------------ CURSOR (lane 26)
 * CURSOR <lord pawn> <x> <y> <z>   writes the pawn's cached cursor point (three doubles at +4E8, +4F0, +4F8)
 * CURSOR <lord pawn> GET           logs it
 * Why: the castle planner's wall tool rebuilds its draft every frame from the road start to this point (4b67950), and
 * the game writes the point only in APawnCPP::updateCursor (4b75b90) from the OS pointer, and only while the pointer
 * is over the game's window (when GetMousePosition fails it keeps the old point). So a copy where no mouse is on the
 * spot (a friend replaying a wall, or a test without the pointer) can set the point, let one frame build the draft,
 * and then confirm with the game's own commit. Nothing is patched: one write of 24 bytes into the pawn.
 * Guards: the CURSOR signature (the store itself, displacements included) has exactly one hit, the game build is the
 * known one, the pawn looks like a live object of this module (vtable inside the image, CURSOR_CHECK_BYTES readable),
 * the numbers are finite and inside the map (|x|, |y| < 1e7, |z| < 1e6). */
#define CURSOR_OFF         0x4E8
#define CURSOR_CHECK_BYTES 0x1000
#define CURSOR_LIMIT_XY    1.0e7
#define CURSOR_LIMIT_Z     1.0e6
static int      g_cursor_ok;
static char     g_cursor_why[160];
static unsigned g_cursor_n;

/* INPUT <lord pawn> LMBDOWN|LMBUP|RMBDOWN|RMBUP   runs the pawn's own mouse-button handler (the functions the game's
 * input component binds to the actions "LMB" / "RMB"), which act at the cached cursor point: with CURSOR first, a
 * click at a chosen place. Same guards as CURSOR (one hit per handler, known build, sane pawn); an exception marks
 * that handler unavailable for the rest of the run. */
#define INPUT_TYPES        4
#define INPUT_CHECK_BYTES  0x1400
static const char *const INPUT_NAME[INPUT_TYPES] = { "LMBDOWN", "LMBUP", "RMBDOWN", "RMBUP" };
static const int INPUT_SIG[INPUT_TYPES] = { S_LMBDOWN, S_LMBUP, S_RMBDOWN, S_RMBUP };
typedef void (*pawn_fn)(void *pawn);
static int      g_input_ok[INPUT_TYPES];
static char     g_input_why[INPUT_TYPES][120];
static unsigned g_input_n[INPUT_TYPES];

static int cursor_scan(void)
{
    int k, known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    g_cursor_ok = 0;
    if (g_hit[S_CURSOR].hits != 1) { _snprintf(g_cursor_why, sizeof(g_cursor_why), "CURSOR signature has %d hits (need exactly 1)", g_hit[S_CURSOR].hits); }
    else if (!known) { _snprintf(g_cursor_why, sizeof(g_cursor_why), "another game build (timestamp %X)", g_stamp); }
    else { g_cursor_ok = 1; g_cursor_why[0] = 0; }
    log_line("  CURSOR %s %s", g_cursor_ok ? "available" : "unavailable", g_cursor_why);
    for (k = 0; k < INPUT_TYPES; k++) {
        int s = INPUT_SIG[k];
        g_input_ok[k] = 0;
        if (g_hit[s].hits != 1) _snprintf(g_input_why[k], sizeof(g_input_why[k]), "%s signature has %d hits (need exactly 1)", SIGS[s].name, g_hit[s].hits);
        else if (!known) _snprintf(g_input_why[k], sizeof(g_input_why[k]), "another game build (timestamp %X)", g_stamp);
        else { g_input_ok[k] = 1; g_input_why[k][0] = 0; }
    }
    return g_cursor_ok;
}

static int cursor_status(char *buf, size_t len)
{
    int ok = !g_off && g_cursor_ok, n, k;
    n = _snprintf(buf, len, "CURSOR %s%s%s\r\n", ok ? "available" : "unavailable", ok ? "" : " ", ok ? "" : (g_off ? "dll is off" : g_cursor_why));
    for (k = 0; k < INPUT_TYPES && n >= 0 && (size_t)n < len; k++) {
        int ik = !g_off && g_input_ok[k];
        n += _snprintf(buf + n, len - (size_t)n, "INPUT %s %s%s%s\r\n", INPUT_NAME[k], ik ? "available" : "unavailable", ik ? "" : " ",
                       ik ? "" : (g_off ? "dll is off" : g_input_why[k]));
    }
    if (n >= 0 && (size_t)n < len)
        n += _snprintf(buf + n, len - (size_t)n, "calls cursor=%u lmbdown=%u lmbup=%u rmbdown=%u rmbup=%u\r\n", g_cursor_n, g_input_n[0], g_input_n[1], g_input_n[2], g_input_n[3]);
    return n;
}

static void input_cmd(int argc, char **argv)
{
    unsigned long long addr = 0;
    char why[200];
    int k, which = -1, faulted = 0;
    DWORD code = 0;
    g_dirty = 1;
    if (argc != 3 || !parse_u64(argv[1], &addr)) { g_calls_failed++; log_line("INPUT refused: needs <pawn> LMBDOWN|LMBUP|RMBDOWN|RMBUP"); return; }
    for (k = 0; k < INPUT_TYPES; k++) if (_stricmp(argv[2], INPUT_NAME[k]) == 0) which = k;
    if (which < 0) { g_calls_failed++; log_line("INPUT refused: '%s' is not LMBDOWN, LMBUP, RMBDOWN or RMBUP", argv[2]); return; }
    if (!g_input_ok[which]) { g_calls_failed++; log_line("INPUT %s refused: unavailable (%s)", INPUT_NAME[which], g_input_why[which]); return; }
    if (!comp_sane(addr, INPUT_CHECK_BYTES, why, sizeof(why))) { g_calls_failed++; log_line("INPUT refused: %s", why); return; }
    __try { ((pawn_fn)(void *)(g_base + g_hit[INPUT_SIG[which]].rva))((void *)(uintptr_t)addr); }
    __except (EXCEPTION_EXECUTE_HANDLER) { faulted = 1; code = GetExceptionCode(); }
    if (faulted) {
        g_calls_failed++; g_input_ok[which] = 0;
        _snprintf(g_input_why[which], sizeof(g_input_why[which]), "exception %08lX in an earlier call", code);
        log_line("INPUT %s(%llX) raised exception %08lX: now unavailable", INPUT_NAME[which], addr, code);
        return;
    }
    g_input_n[which]++;
    log_line("INPUT %s(%llX) called", INPUT_NAME[which], addr);
}

static int parse_coord(const char *s, double lim, double *v)
{
    char *end = NULL;
    double d;
    if (!s || !*s) return 0;
    d = strtod(s, &end);
    if (!end || *end || d != d || d > lim || d < -lim) return 0;
    *v = d;
    return 1;
}

static void cursor_cmd(int argc, char **argv)
{
    unsigned long long addr = 0;
    double p[3];
    char why[200];
    volatile double *q;
    g_dirty = 1;
    if (!g_cursor_ok) { g_calls_failed++; log_line("CURSOR refused: unavailable (%s)", g_cursor_why); return; }
    if (argc < 3 || !parse_u64(argv[1], &addr)) { g_calls_failed++; log_line("CURSOR refused: needs <pawn> <x> <y> <z> or <pawn> GET"); return; }
    if (!comp_sane(addr, CURSOR_CHECK_BYTES, why, sizeof(why))) { g_calls_failed++; log_line("CURSOR refused: %s", why); return; }
    q = (volatile double *)(uintptr_t)(addr + CURSOR_OFF);
    if (argc == 3 && _stricmp(argv[2], "GET") == 0) {
        __try { log_line("CURSOR(%llX) is %.2f %.2f %.2f", addr, q[0], q[1], q[2]); }
        __except (EXCEPTION_EXECUTE_HANDLER) { g_calls_failed++; log_line("CURSOR(%llX) read faulted", addr); }
        return;
    }
    if (argc != 5 || !parse_coord(argv[2], CURSOR_LIMIT_XY, &p[0]) || !parse_coord(argv[3], CURSOR_LIMIT_XY, &p[1]) || !parse_coord(argv[4], CURSOR_LIMIT_Z, &p[2])) {
        g_calls_failed++; log_line("CURSOR refused: needs <pawn> <x> <y> <z> (numbers inside the map)"); return;
    }
    __try { q[0] = p[0]; q[1] = p[1]; q[2] = p[2]; }
    __except (EXCEPTION_EXECUTE_HANDLER) { g_calls_failed++; log_line("CURSOR(%llX) write faulted", addr); return; }
    g_cursor_n++;
    log_line("CURSOR(%llX) set to %.2f %.2f %.2f", addr, p[0], p[1], p[2]);
}

/* ------------------------------------------------------------------ DRAW and ORDER (lane 28)
 * What a player draws with the wall tool and what a right click orders are native in this game: no reflected function
 * builds a wall from points, takes a building as a squad's target or gives a squad a path. These commands run the
 * game's own routines (signatures TOOLUPD, ROADCLICK, COMMITROAD, MOVESEL, PATHPT, and lane 26's CURSOR and RMBDOWN).
 * Source: research\2026-11-10-game-probe\lanes\lane_s21_28\report.txt.
 *
 *   WALL <token> <pawn> <flags> <x,y,z|x,y,z|...>     2 to 21 points
 *       per point: the cursor point (+4E8h, and its change at +4C0h, as updateCursor writes them), the tool's update,
 *       the tool's click. That is how the game's own AI lords draw a road (4be8fe0). The pawn must be in road mode
 *       already (the reflected setRoadMode(true, first point, false); for a wall also switchWallMode and planner mode).
 *       flags: 1 = then commitRoad, here (a replay: the script layer does not see this call); without it the caller
 *                  commits the way the game does (the reflected callCommitRoad), which the mod's own hook sees
 *              2 = clear the update's "cannot place" flag (+5FCh) before each click: a copy replaying the host's word
 *                  (the flag is set for a pawn that does not own the region, as the mod's helper lord never does)
 *   TOOL <pawn>                                        one update of the tool (before an INPUT LMBDOWN click)
 *   WALLGET <token> <road>                             the control points (+318h) and gate records (+498h) of a wall
 *   ORDERAT <token> <pawn> <x,y,z> <wp> <noArrows>     the cursor point, "not dragging" (+488h = 0), MoveSelected: the
 *       order a right click at that point gives the pawn's selected squads. With cursorMode 3 and hitBuilding set
 *       (both reflected, written by the caller) that is the attack on a building.
 *   PATH <token> <pawn> <noArrows> <x,y,z|...>         2 to 64 points: the right button's press handler at the first
 *       point, PATHPT per point, MoveSelected(waypoint): the path order of Ctrl + right drag (one selected squad)
 *   PATHGET <token> <pawn>                             the pawn's path list (+CA8h)
 *   PATHPT <pawn>                                      one run of the Ctrl + right-drag routine (what the pawn's Tick
 *       does each frame of such a drag): the cursor point joins the path list when it is far enough from the last
 *   ORDERHOOK ON | OFF                                 MoveSelected's entry jumps to a stub that notes each call the
 *       game makes itself (never this DLL's own): pawn, flags, cursor point, hover state, selected squads. The next
 *       tick adds the path list as the call left it and appends one line to patch_events.txt.
 *
 * Answers go to patch_reply.txt (replaced atomically): "R <token> <command> ok ..." or "R <token> <command> refused
 * <why>" / "... exception <code>". Every item needs its signature exactly once AND the known build: offsets are used
 * that no signature holds (+488h, +5B8h, +710h, +718h, +738h of the pawn; +318h, +498h of a road). A faulting
 * routine is marked unavailable for the rest of the session, as FINISH and INPUT are. */
#include <math.h>
#define L28_PAWN_BYTES 0x1400
#define L28_ROAD_BYTES 0x500
#define L28_PT_MAX     21          /* the game's own click refuses a 22nd point (ROADCLICK: more than 20 before it) */
#define L28_WAY_MAX    64
#define L28_SQ_MAX     16
#define L28_EV_MAX     8
#define L28_GATE_MAX   16
#define L28_REPLY_MAX  8192
#define PAWN_MOVED     0x488       /* "the pointer moved since the press": MoveSelected takes its drag branch when set */
#define PAWN_CURDELTA  0x4C0       /* three doubles: this frame's change of the cursor point (in the CURSOR pattern) */
#define PAWN_SELSQ     0x550       /* selectedSquads: { int32 *data; int num; int max } (in the MOVESEL pattern) */
#define PAWN_CURMODE   0x5B8       /* cursorMode (reflected) */
#define PAWN_NOPLACE   0x5FC       /* the tool update's "cannot place" flag (in the ROADCLICK pattern) */
#define PAWN_HITB      0x710       /* hitBuilding (reflected) */
#define PAWN_HITPART   0x718       /* hitBuildingPart (reflected) */
#define PAWN_HITRES    0x738       /* the resource node under the pointer (MoveSelected's first branch of mode 3) */
#define PAWN_ROADPTS   0x780       /* roadPoints: { FVector *data; int num; int max } (+788h is in the ROADCLICK pattern) */
#define PAWN_WAY       0xCA8       /* the path list: 88h bytes a point, its place at +8 (in the PATHPT pattern) */
#define WAY_STRIDE     0x88
#define WAY_POS        0x08
#define WAY_FAR_SQ     250000.0    /* the game appends a path point only this far (squared) from the last one */
#define ROAD_KIND      0x2B3       /* four reflected bytes: isBlueprint, roadType, wallType, platformLevel */
#define ROAD_CTL       0x318       /* the wall's control points: { FVector *data; int num; int max } */
#define ROAD_GATES     0x498       /* the wall's gate records: 60h bytes each, the gate's place at +20h */
#define GATE_STRIDE    0x60
#define GATE_POS       0x20
#define BLD_CAT        0x3CC       /* a byte of the building's Data that MoveSelected compares with 11h */
#define ORDER_HOOK_LEN 5
static const uint8_t ORDER_ORIG[ORDER_HOOK_LEN] = { 0x48, 0x89, 0x5C, 0x24, 0x20 };    /* mov [rsp+20h],rbx */

typedef void *(*commit_fn)(void *pawn);
typedef void (*movesel_fn)(void *pawn, unsigned char waypoint, unsigned char noArrows);
typedef struct { uint8_t *data; int32_t num, max; } tarr;
typedef struct { double x, y, z; } vec3;

enum { L_TOOL = 0, L_CLICK, L_COMMIT, L_MOVESEL, L_PATHPT, L_COUNT };
static const char *const L_NAME[L_COUNT] = { "TOOLUPD", "ROADCLICK", "COMMITROAD", "MOVESEL", "PATHPT" };
static const int L_SIG[L_COUNT] = { S_TOOLUPD, S_ROADCLICK, S_COMMITROAD, S_MOVESEL, S_PATHPT };
static int      g_l_ok[L_COUNT];
static char     g_l_why[L_COUNT][120];
static unsigned g_l_walls, g_l_tools, g_l_gets, g_l_orders, g_l_paths;

typedef struct {
    int pending, wp, na, mode, moved, nsq, way_before;
    uint8_t *pawn, *hb, *hp, *res;
    int32_t hbtype, hbcat;
    vec3 cur;
    int32_t sq[L28_SQ_MAX];
} order_ev;
static struct {
    int avail; char why[120];
    uint8_t *entry, *stub; uint8_t jmp[ORDER_HOOK_LEN];
    volatile LONG enabled; LONG own; DWORD thread;
    order_ev ev[L28_EV_MAX]; int nev;
    unsigned seen, written, dropped, faults, seq;
} O;

static void *l28_fn(int k) { return (void *)(g_base + g_hit[L_SIG[k]].rva); }
static int l28_draw_ok(void)  { return g_cursor_ok && g_l_ok[L_TOOL] && g_l_ok[L_CLICK] && g_l_ok[L_COMMIT]; }
static int l28_order_ok(void) { return g_cursor_ok && g_l_ok[L_MOVESEL]; }
static int l28_path_ok(void)  { return l28_order_ok() && g_l_ok[L_PATHPT] && g_input_ok[2]; }
static const char *l28_why(int which)       /* 0 draw, 1 order, 2 path: the first thing that is missing */
{
    int k;
    if (!g_cursor_ok) return g_cursor_why;
    if (which == 0) { for (k = L_TOOL; k <= L_COMMIT; k++) if (!g_l_ok[k]) return g_l_why[k]; return ""; }
    if (!g_l_ok[L_MOVESEL]) return g_l_why[L_MOVESEL];
    if (which == 2) { if (!g_l_ok[L_PATHPT]) return g_l_why[L_PATHPT]; if (!g_input_ok[2]) return g_input_why[2]; }
    return "";
}

static int l28_scan(void)
{
    int k, any = 0, known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    g_l53_dead = 0;
    for (k = 0; k < L_COUNT; k++) {
        int s = L_SIG[k];
        g_l_ok[k] = 0;
        if (g_hit[s].hits != 1) _snprintf(g_l_why[k], sizeof(g_l_why[k]), "%s signature has %d hits (need exactly 1)", SIGS[s].name, g_hit[s].hits);
        else if (!known) _snprintf(g_l_why[k], sizeof(g_l_why[k]), "another game build (timestamp %X)", g_stamp);
        else { g_l_ok[k] = 1; g_l_why[k][0] = 0; any = 1; }
    }
    O.avail = 0; O.entry = NULL;
    if (!g_l_ok[L_MOVESEL]) _snprintf(O.why, sizeof(O.why), "%s", g_l_why[L_MOVESEL]);
    else {
        uint8_t *e = g_base + g_hit[S_MOVESEL].rva;
        if (memcmp(e, ORDER_ORIG, ORDER_HOOK_LEN) != 0) _snprintf(O.why, sizeof(O.why), "MOVESEL does not start with its known first instruction");
        else if (((uintptr_t)e & 7) + ORDER_HOOK_LEN > 8) _snprintf(O.why, sizeof(O.why), "the MOVESEL hook would cross an 8-byte block");
        else { O.entry = e; O.avail = 1; O.why[0] = 0; }
    }
    log_line("  DRAW %s %s; ORDER %s %s; PATH %s %s; ORDERHOOK %s %s", l28_draw_ok() ? "available" : "unavailable", l28_why(0),
             l28_order_ok() ? "available" : "unavailable", l28_why(1), l28_path_ok() ? "available" : "unavailable", l28_why(2),
             O.avail ? "available" : "unavailable", O.why);
    return any;
}

static int order_bytes_on(void) { return O.stub && O.entry && memcmp(O.entry, O.jmp, ORDER_HOOK_LEN) == 0; }

static int l28_status(char *buf, size_t len)
{
    int n = 0, k;
    for (k = 0; k < 3 && n >= 0 && (size_t)n < len; k++) {
        static const char *const NM[3] = { "DRAW", "ORDER", "PATH" };
        int ok = !g_off && (k == 0 ? l28_draw_ok() : k == 1 ? l28_order_ok() : l28_path_ok());
        n += _snprintf(buf + n, len - (size_t)n, "%s %s%s%s\r\n", NM[k], ok ? "available" : "unavailable", ok ? "" : " ", ok ? "" : (g_off ? "dll is off" : l28_why(k)));
    }
    if (n >= 0 && (size_t)n < len) {
        if (g_off || !O.avail) n += _snprintf(buf + n, len - (size_t)n, "ORDERHOOK unavailable %s\r\n", g_off ? "dll is off" : O.why);
        else n += _snprintf(buf + n, len - (size_t)n, "ORDERHOOK %s\r\n", order_bytes_on() ? "hooked" : "idle");
    }
    if (n >= 0 && (size_t)n < len)
        n += _snprintf(buf + n, len - (size_t)n, "draw walls=%u tools=%u wallgets=%u orders=%u paths=%u seen=%u events=%u dropped=%u hookfaults=%u\r\n",
                       g_l_walls, g_l_tools, g_l_gets, g_l_orders, g_l_paths, O.seen, O.written, O.dropped, O.faults);
    return n;
}

/* ---- the answer file and the event file */
static void l28_reply(const char *fmt, ...)
{
    static char buf[L28_REPLY_MAX];
    wchar_t path[MAX_PATH], tmp[MAX_PATH];
    va_list ap;
    HANDLE h;
    DWORD wr;
    int n;
    va_start(ap, fmt);
    n = _vsnprintf(buf, sizeof(buf) - 3, fmt, ap);
    va_end(ap);
    if (n < 0 || n > (int)sizeof(buf) - 3) n = (int)sizeof(buf) - 3;
    buf[n++] = '\r'; buf[n++] = '\n';
    join_path(path, g_dir, L"patch_reply.txt"); join_path(tmp, g_dir, L"patch_reply.tmp");
    h = CreateFileW(tmp, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) { log_line("cannot write %ls (error %lu)", tmp, GetLastError()); return; }
    WriteFile(h, buf, (DWORD)n, &wr, NULL);
    CloseHandle(h);
    if (!MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) log_line("cannot replace patch_reply.txt (error %lu)", GetLastError());
    log_line("reply: %.200s", buf);
}

static void l28_event(const char *line, int n)
{
    wchar_t path[MAX_PATH];
    WIN32_FILE_ATTRIBUTE_DATA fa;
    HANDLE h;
    DWORD wr;
    join_path(path, g_dir, L"patch_events.txt");
    /* above 256 KB the file starts again (the reader sees it shrink and reads from 0, as this DLL does with commands) */
    if (GetFileAttributesExW(path, GetFileExInfoStandard, &fa) && (fa.nFileSizeHigh || fa.nFileSizeLow > LOG_CAP)) DeleteFileW(path);
    h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) { log_line("cannot append to %ls (error %lu)", path, GetLastError()); return; }
    WriteFile(h, line, (DWORD)n, &wr, NULL);
    CloseHandle(h);
}

/* ---- small readers */
static int tarr_sane(const tarr *a, int maxnum, size_t stride)
{
    if (a->num < 0 || a->num > maxnum || a->max < a->num) return 0;
    if (a->num == 0) return 1;
    return a->data != NULL && range_readable(a->data, (size_t)a->num * stride);
}

/* "x,y,z|x,y,z|..." -> pts; returns the number of points, or -1 */
static int parse_points(const char *s, vec3 *pts, int maxn)
{
    int n = 0;
    while (*s) {
        char *end = NULL;
        double v[3];
        int i;
        if (n >= maxn) return -1;
        for (i = 0; i < 3; i++) {
            v[i] = strtod(s, &end);
            if (end == s || v[i] != v[i]) return -1;
            if (i < 2) { if (*end != ',') return -1; s = end + 1; } else s = end;
        }
        if (v[0] > CURSOR_LIMIT_XY || v[0] < -CURSOR_LIMIT_XY || v[1] > CURSOR_LIMIT_XY || v[1] < -CURSOR_LIMIT_XY || v[2] > CURSOR_LIMIT_Z || v[2] < -CURSOR_LIMIT_Z) return -1;
        pts[n].x = v[0]; pts[n].y = v[1]; pts[n].z = v[2]; n++;
        if (*s == '|') { s++; if (!*s) return -1; } else if (*s) return -1;
    }
    return n;
}

static void set_cursor(uint8_t *pawn, const vec3 *p, int with_delta)
{
    volatile double *c = (volatile double *)(pawn + CURSOR_OFF), *d = (volatile double *)(pawn + PAWN_CURDELTA);
    if (with_delta) { d[0] = p->x - c[0]; d[1] = p->y - c[1]; d[2] = p->z - c[2]; }
    c[0] = p->x; c[1] = p->y; c[2] = p->z;
}

static double dist2(const vec3 *a, const vec3 *b) { return (a->x - b->x) * (a->x - b->x) + (a->y - b->y) * (a->y - b->y); }

static void l28_fault(int k, DWORD code, const char *cmd)
{
    g_calls_failed++; g_l_ok[k] = 0;
    _snprintf(g_l_why[k], sizeof(g_l_why[k]), "exception %08lX in an earlier call", code);
    if (k == L_MOVESEL) { O.avail = 0; _snprintf(O.why, sizeof(O.why), "%s", g_l_why[k]); }
    log_line("%s: %s raised exception %08lX: now unavailable", cmd, L_NAME[k], code);
}

/* the pawn's path list as text: "n x,y,z|..." (at most L28_WAY_MAX points); returns the characters written */
static int way_text(uint8_t *pawn, char *buf, size_t len)
{
    tarr a;
    int i, n = 0;
    memcpy(&a, pawn + PAWN_WAY, sizeof(a));
    if (!tarr_sane(&a, 4096, WAY_STRIDE)) return _snprintf(buf, len, "-1 -");
    n = _snprintf(buf, len, "%d ", a.num);
    if (a.num == 0) n += _snprintf(buf + n, len - (size_t)n, "-");
    for (i = 0; i < a.num && i < L28_WAY_MAX && n >= 0 && (size_t)n + 80 < len; i++) {
        vec3 p; memcpy(&p, a.data + (size_t)i * WAY_STRIDE + WAY_POS, sizeof(p));
        n += _snprintf(buf + n, len - (size_t)n, "%s%.1f,%.1f,%.1f", i ? "|" : "", p.x, p.y, p.z);
    }
    return n;
}

/* ---- WALL */
static void wall_cmd(int argc, char **argv)
{
    unsigned long long addr = 0;
    static vec3 pts[L28_PT_MAX];
    char why[200], blocked[L28_PT_MAX + 1];
    uint8_t *pawn;
    void *road = NULL;
    volatile double *d;
    int flags = 0, n, i = 0, stage = 0, num = -1, stop = -1;
    DWORD code = 0;
    const char *tok = argc > 1 ? argv[1] : "-";
    g_dirty = 1;
    if (!l28_draw_ok()) { g_calls_failed++; l28_reply("R %s WALL refused unavailable (%s)", tok, l28_why(0)); return; }
    if (argc != 5 || !parse_u64(argv[2], &addr) || !parse_i32(argv[3], &flags) || flags < 0 || flags > 3) { g_calls_failed++; l28_reply("R %s WALL refused needs <token> <pawn> <flags 0..3> <x,y,z|...>", tok); return; }
    n = parse_points(argv[4], pts, L28_PT_MAX);
    if (n < 2) { g_calls_failed++; l28_reply("R %s WALL refused needs 2 to %d points inside the map", tok, L28_PT_MAX); return; }
    if (!comp_sane(addr, L28_PAWN_BYTES, why, sizeof(why))) { g_calls_failed++; l28_reply("R %s WALL refused %s", tok, why); return; }
    pawn = (uint8_t *)(uintptr_t)addr;
    memset(blocked, 0, sizeof(blocked));
    __try {
        for (i = 0; i < n; i++) {
            stage = 0; set_cursor(pawn, &pts[i], 1);
            ((pawn_fn)l28_fn(L_TOOL))(pawn);
            blocked[i] = pawn[PAWN_NOPLACE] ? '1' : '0';
            if (pawn[PAWN_NOPLACE]) {
                if (flags & 2) pawn[PAWN_NOPLACE] = 0;
                else { stop = i; break; }                      /* the game's own routine gives up here too */
            }
            stage = 1;
            ((pawn_fn)l28_fn(L_CLICK))(pawn);
        }
        num = *(int32_t *)(pawn + PAWN_ROADPTS + 8);
        d = (volatile double *)(pawn + PAWN_CURDELTA); d[0] = 0; d[1] = 0; d[2] = 0;
        if ((flags & 1) && stop < 0) { stage = 2; road = ((commit_fn)l28_fn(L_COMMIT))(pawn); }
    } __except (EXCEPTION_EXECUTE_HANDLER) { code = GetExceptionCode(); }
    if (code) {
        l28_fault(stage == 0 ? L_TOOL : stage == 1 ? L_CLICK : L_COMMIT, code, "WALL");
        l28_reply("R %s WALL exception %08lX in %s at point %d", tok, code, L_NAME[stage == 0 ? L_TOOL : stage == 1 ? L_CLICK : L_COMMIT], i + 1);
        return;
    }
    g_l_walls++;
    l28_reply("R %s WALL ok pts=%d blocked=%s stop=%d road=%llX", tok, num, blocked, stop < 0 ? 0 : stop + 1, (unsigned long long)(uintptr_t)road);
}

/* ---- TOOL */
static void tool_cmd(int argc, char **argv)
{
    unsigned long long addr = 0;
    char why[200];
    DWORD code = 0;
    g_dirty = 1;
    if (!g_l_ok[L_TOOL]) { g_calls_failed++; log_line("TOOL refused: unavailable (%s)", g_l_why[L_TOOL]); return; }
    if (argc != 2 || !parse_u64(argv[1], &addr)) { g_calls_failed++; log_line("TOOL refused: needs <pawn>"); return; }
    if (!comp_sane(addr, L28_PAWN_BYTES, why, sizeof(why))) { g_calls_failed++; log_line("TOOL refused: %s", why); return; }
    __try { ((pawn_fn)l28_fn(L_TOOL))((void *)(uintptr_t)addr); }
    __except (EXCEPTION_EXECUTE_HANDLER) { code = GetExceptionCode(); }
    if (code) { l28_fault(L_TOOL, code, "TOOL"); return; }
    g_l_tools++;
    log_line("TOOL(%llX) called, cannot-place flag %d", addr, (int)((uint8_t *)(uintptr_t)addr)[PAWN_NOPLACE]);
}

/* ---- WALLGET */
static void wallget_cmd(int argc, char **argv)
{
    static char buf[L28_REPLY_MAX];
    unsigned long long addr = 0;
    char why[200];
    uint8_t *road;
    tarr ctl, gates;
    int n = 0, i, j;
    const char *tok = argc > 1 ? argv[1] : "-";
    g_dirty = 1;
    if (!g_l_ok[L_COMMIT]) { g_calls_failed++; l28_reply("R %s WALLGET refused unavailable (%s)", tok, g_l_why[L_COMMIT]); return; }
    if (argc != 3 || !parse_u64(argv[2], &addr)) { g_calls_failed++; l28_reply("R %s WALLGET refused needs <token> <road>", tok); return; }
    if (!comp_sane(addr, L28_ROAD_BYTES, why, sizeof(why))) { g_calls_failed++; l28_reply("R %s WALLGET refused %s", tok, why); return; }
    road = (uint8_t *)(uintptr_t)addr;
    __try {
        memcpy(&ctl, road + ROAD_CTL, sizeof(ctl)); memcpy(&gates, road + ROAD_GATES, sizeof(gates));
        if (!tarr_sane(&ctl, 256, sizeof(vec3)) || !tarr_sane(&gates, 256, GATE_STRIDE)) n = -1;
        else {
            n = _snprintf(buf, sizeof(buf), "kind=%d,%d,%d,%d ctl=%d ", (int)road[ROAD_KIND], (int)road[ROAD_KIND + 1], (int)road[ROAD_KIND + 2], (int)road[ROAD_KIND + 3], ctl.num);
            if (ctl.num == 0) n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "-");
            for (i = 0; i < ctl.num && i < 64; i++) {
                vec3 p; memcpy(&p, ctl.data + (size_t)i * sizeof(vec3), sizeof(p));
                n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "%s%.2f,%.2f,%.2f", i ? "|" : "", p.x, p.y, p.z);
            }
            n += _snprintf(buf + n, sizeof(buf) - (size_t)n, " gates=%d ", gates.num);
            if (gates.num == 0) n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "-");
            for (i = 0; i < gates.num && i < L28_GATE_MAX; i++) {
                const uint8_t *g = gates.data + (size_t)i * GATE_STRIDE;
                vec3 p; memcpy(&p, g + GATE_POS, sizeof(p));
                n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "%s%.2f,%.2f,%.4f:", i ? "|" : "", p.x, p.y, p.z);   /* lane 32: the height with 4 decimals (GATESET) */
                for (j = 0; j < GATE_STRIDE; j++) n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "%02X", g[j]);
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { n = -2; }
    if (n < 0) { g_calls_failed++; l28_reply("R %s WALLGET refused %s", tok, n == -1 ? "the object's point or gate list is not sane (not a road?)" : "reading the road faulted"); return; }
    g_l_gets++;
    l28_reply("R %s WALLGET ok %s", tok, buf);
}

/* ---- ORDERAT and PATH */
static int parse_flag(const char *s, int *v) { return parse_i32(s, v) && (*v == 0 || *v == 1); }

/* MoveSelected(waypoint) reads list[Num - 2] unguarded (lane 27's fault): the game's own gate is "two or more points" */
static int way_ready(uint8_t *pawn, const vec3 *cursor, char *why, size_t whylen)
{
    tarr a;
    vec3 last;
    memcpy(&a, pawn + PAWN_WAY, sizeof(a));
    if (!tarr_sane(&a, 4096, WAY_STRIDE) || a.num < 1) { _snprintf(why, whylen, "the pawn's path list is empty or not sane"); return 0; }
    memcpy(&last, a.data + (size_t)(a.num - 1) * WAY_STRIDE + WAY_POS, sizeof(last));
    if (a.num + (dist2(&last, cursor) > WAY_FAR_SQ ? 1 : 0) < 2) { _snprintf(why, whylen, "the path would hold fewer than two points"); return 0; }
    return 1;
}

static void orderat_cmd(int argc, char **argv)
{
    static char way[L28_REPLY_MAX - 256];
    unsigned long long addr = 0;
    vec3 p;
    char why[200];
    uint8_t *pawn;
    int wp = 0, na = 0;
    DWORD code = 0;
    const char *tok = argc > 1 ? argv[1] : "-";
    g_dirty = 1;
    if (!l28_order_ok()) { g_calls_failed++; l28_reply("R %s ORDERAT refused unavailable (%s)", tok, l28_why(1)); return; }
    if (argc != 6 || !parse_u64(argv[2], &addr) || parse_points(argv[3], &p, 1) != 1 || !parse_flag(argv[4], &wp) || !parse_flag(argv[5], &na)) {
        g_calls_failed++; l28_reply("R %s ORDERAT refused needs <token> <pawn> <x,y,z> <wp 0|1> <noArrows 0|1>", tok); return;
    }
    if (!comp_sane(addr, L28_PAWN_BYTES, why, sizeof(why))) { g_calls_failed++; l28_reply("R %s ORDERAT refused %s", tok, why); return; }
    pawn = (uint8_t *)(uintptr_t)addr;
    __try {
        if (wp && !way_ready(pawn, &p, why, sizeof(why))) code = 1;
        else {
            set_cursor(pawn, &p, 0);
            pawn[PAWN_MOVED] = 0;
            O.own++;
            __try { ((movesel_fn)l28_fn(L_MOVESEL))(pawn, (unsigned char)wp, (unsigned char)na); }
            __finally { O.own--; }
            way_text(pawn, way, sizeof(way));
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { code = GetExceptionCode(); }
    if (code == 1) { g_calls_failed++; l28_reply("R %s ORDERAT refused %s", tok, why); return; }
    if (code) { l28_fault(L_MOVESEL, code, "ORDERAT"); l28_reply("R %s ORDERAT exception %08lX", tok, code); return; }
    g_l_orders++;
    l28_reply("R %s ORDERAT ok way=%s", tok, way);
}

static void path_cmd(int argc, char **argv)
{
    static vec3 pts[L28_WAY_MAX];
    static char way[L28_REPLY_MAX - 256];
    unsigned long long addr = 0;
    char why[200];
    uint8_t *pawn;
    int na = 0, n, i = 0, stage = 0;
    DWORD code = 0;
    const char *tok = argc > 1 ? argv[1] : "-";
    g_dirty = 1;
    if (!l28_path_ok()) { g_calls_failed++; l28_reply("R %s PATH refused unavailable (%s)", tok, l28_why(2)); return; }
    if (argc != 5 || !parse_u64(argv[2], &addr) || !parse_flag(argv[3], &na)) { g_calls_failed++; l28_reply("R %s PATH refused needs <token> <pawn> <noArrows 0|1> <x,y,z|...>", tok); return; }
    n = parse_points(argv[4], pts, L28_WAY_MAX);
    if (n < 2) { g_calls_failed++; l28_reply("R %s PATH refused needs 2 to %d points inside the map", tok, L28_WAY_MAX); return; }
    if (n == 2 && !(dist2(&pts[0], &pts[1]) > WAY_FAR_SQ)) { g_calls_failed++; l28_reply("R %s PATH refused two points closer than the game's own step: a plain move", tok); return; }
    if (!comp_sane(addr, L28_PAWN_BYTES, why, sizeof(why))) { g_calls_failed++; l28_reply("R %s PATH refused %s", tok, why); return; }
    pawn = (uint8_t *)(uintptr_t)addr;
    __try {
        /* The press starts the list with one point. MoveSelected drops the list's first point when it holds more than
         * two, so with three or more points the press is made at the second point: that one is dropped again. */
        stage = 0; set_cursor(pawn, n >= 3 ? &pts[1] : &pts[0], 0);
        ((pawn_fn)(void *)(g_base + g_hit[S_RMBDOWN].rva))(pawn);
        if (n >= 3) {
            stage = 1;
            for (i = 0; i < n - 1; i++) { set_cursor(pawn, &pts[i], 0); ((pawn_fn)l28_fn(L_PATHPT))(pawn); }
            /* a last point nearer than the game's step replaces the list's last point: give it one to replace */
            if (!(dist2(&pts[n - 2], &pts[n - 1]) > WAY_FAR_SQ)) {
                vec3 q = pts[n - 2];
                double dx = pts[n - 1].x - q.x, dy = pts[n - 1].y - q.y, len2 = dx * dx + dy * dy, k;
                if (len2 < 1.0) { dx = 1.0; dy = 0.0; len2 = 1.0; }
                k = 501.0 / sqrt(len2);
                q.x += dx * k; q.y += dy * k;
                set_cursor(pawn, &q, 0); ((pawn_fn)l28_fn(L_PATHPT))(pawn);
            }
        }
        set_cursor(pawn, &pts[n - 1], 0);
        if (!way_ready(pawn, &pts[n - 1], why, sizeof(why))) code = 1;
        else {
            stage = 2;
            pawn[PAWN_MOVED] = 0;
            O.own++;
            __try { ((movesel_fn)l28_fn(L_MOVESEL))(pawn, 1, (unsigned char)na); }
            __finally { O.own--; }
            way_text(pawn, way, sizeof(way));
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { code = GetExceptionCode(); }
    if (code == 1) { g_calls_failed++; l28_reply("R %s PATH refused %s", tok, why); return; }
    if (code) {
        if (stage == 0) { g_calls_failed++; g_input_ok[2] = 0; _snprintf(g_input_why[2], sizeof(g_input_why[2]), "exception %08lX in an earlier call", code); }
        else l28_fault(stage == 1 ? L_PATHPT : L_MOVESEL, code, "PATH");
        l28_reply("R %s PATH exception %08lX in stage %d", tok, code, stage);
        return;
    }
    g_l_paths++;
    l28_reply("R %s PATH ok way=%s", tok, way);
}

static void pathget_cmd(int argc, char **argv)
{
    static char way[L28_REPLY_MAX - 256];
    unsigned long long addr = 0;
    char why[200];
    int bad = 0;
    const char *tok = argc > 1 ? argv[1] : "-";
    if (!g_l_ok[L_PATHPT]) { g_calls_failed++; l28_reply("R %s PATHGET refused unavailable (%s)", tok, g_l_why[L_PATHPT]); return; }
    if (argc != 3 || !parse_u64(argv[2], &addr)) { g_calls_failed++; l28_reply("R %s PATHGET refused needs <token> <pawn>", tok); return; }
    if (!comp_sane(addr, L28_PAWN_BYTES, why, sizeof(why))) { g_calls_failed++; l28_reply("R %s PATHGET refused %s", tok, why); return; }
    __try { way_text((uint8_t *)(uintptr_t)addr, way, sizeof(way)); }
    __except (EXCEPTION_EXECUTE_HANDLER) { bad = 1; }
    if (bad) { g_calls_failed++; l28_reply("R %s PATHGET refused reading the pawn faulted", tok); return; }
    l28_reply("R %s PATHGET ok way=%s", tok, way);
}

static void pathpt_cmd(int argc, char **argv)
{
    unsigned long long addr = 0;
    char why[200];
    uint8_t *pawn;
    tarr a;
    DWORD code = 0;
    g_dirty = 1;
    if (!g_l_ok[L_PATHPT]) { g_calls_failed++; log_line("PATHPT refused: unavailable (%s)", g_l_why[L_PATHPT]); return; }
    if (argc != 2 || !parse_u64(argv[1], &addr)) { g_calls_failed++; log_line("PATHPT refused: needs <pawn>"); return; }
    if (!comp_sane(addr, L28_PAWN_BYTES, why, sizeof(why))) { g_calls_failed++; log_line("PATHPT refused: %s", why); return; }
    pawn = (uint8_t *)(uintptr_t)addr;
    memcpy(&a, pawn + PAWN_WAY, sizeof(a));
    /* the routine reads list[Num - 1] unguarded: the game runs it only after the press made the list one point long */
    if (!tarr_sane(&a, 4096, WAY_STRIDE) || a.num < 1) { g_calls_failed++; log_line("PATHPT refused: the pawn's path list is empty or not sane"); return; }
    __try { ((pawn_fn)l28_fn(L_PATHPT))(pawn); }
    __except (EXCEPTION_EXECUTE_HANDLER) { code = GetExceptionCode(); }
    if (code) { l28_fault(L_PATHPT, code, "PATHPT"); return; }
    log_line("PATHPT(%llX) called, the path list holds %d points", addr, (int)*(int32_t *)(pawn + PAWN_WAY + 8));
}

/* ---- ORDERHOOK: called by the stub at MoveSelected's entry; frame = { r9, r8, rdx, rcx, return address } */
static void order_hook_wd(uint8_t *pawn, uint64_t *frame)
{
    if (!O.enabled || O.own || GetCurrentThreadId() != O.thread) return;
    __try {
        order_ev *e;
        tarr sq, way;
        int i;
        O.seen++;
        if (O.nev >= L28_EV_MAX) { O.dropped++; return; }
        if (!range_readable(pawn, L28_PAWN_BYTES)) { O.dropped++; return; }
        e = &O.ev[O.nev];
        memset(e, 0, sizeof(*e));
        e->pawn = pawn; e->wp = (int)(uint8_t)frame[2]; e->na = (int)(uint8_t)frame[1];
        memcpy(&e->cur, pawn + CURSOR_OFF, sizeof(e->cur));
        e->mode = pawn[PAWN_CURMODE]; e->moved = pawn[PAWN_MOVED];
        memcpy(&e->hb, pawn + PAWN_HITB, 8); memcpy(&e->hp, pawn + PAWN_HITPART, 8); memcpy(&e->res, pawn + PAWN_HITRES, 8);
        if (e->hb && range_readable(e->hb, BLD_CAT + 1)) { memcpy(&e->hbtype, e->hb + BTYPE_OFF, 4); e->hbcat = e->hb[BLD_CAT]; }
        memcpy(&sq, pawn + PAWN_SELSQ, sizeof(sq));
        if (tarr_sane(&sq, 4096, 4)) for (i = 0; i < sq.num && i < L28_SQ_MAX; i++) memcpy(&e->sq[e->nsq++], sq.data + (size_t)i * 4, 4);
        memcpy(&way, pawn + PAWN_WAY, sizeof(way));
        e->way_before = way.num;
        e->pending = 1;
        O.nev++;
    } __except (EXCEPTION_EXECUTE_HANDLER) { O.faults++; InterlockedExchange(&O.enabled, 0); }
}
static void order_hook(uint8_t *pawn, uint64_t *frame)   /* lane 51: the watchdog's marks around it */
{
    wd_in(WD_ORDER); order_hook_wd(pawn, frame); wd_out(WD_ORDER);
}

/* the tick: write what the hook noted (the path list is read now, as the call left it) */
static void order_tick(void)
{
    static char line[L28_REPLY_MAX];
    int k;
    if (O.faults && O.avail) {          /* the hook faulted and switched itself to pass-through: take it out for good */
        order_unhook("exception in the hook");
        O.avail = 0; _snprintf(O.why, sizeof(O.why), "exception in the hook");
        log_line("ORDERHOOK: exception in the hook: now unavailable");
    }
    if (O.nev == 0) return;
    for (k = 0; k < O.nev; k++) {
        order_ev *e = &O.ev[k];
        int n, i;
        n = _snprintf(line, sizeof(line), "MOVESEL %u pawn=%llX wp=%d na=%d cur=%.1f,%.1f,%.1f mode=%d moved=%d hb=%llX hbt=%d hbc=%d hp=%llX res=%llX sq=",
                      ++O.seq, (unsigned long long)(uintptr_t)e->pawn, e->wp, e->na, e->cur.x, e->cur.y, e->cur.z, e->mode, e->moved,
                      (unsigned long long)(uintptr_t)e->hb, (int)e->hbtype, (int)e->hbcat, (unsigned long long)(uintptr_t)e->hp, (unsigned long long)(uintptr_t)e->res);
        if (e->nsq == 0) n += _snprintf(line + n, sizeof(line) - (size_t)n, "-");
        for (i = 0; i < e->nsq; i++) n += _snprintf(line + n, sizeof(line) - (size_t)n, "%s%d", i ? "," : "", (int)e->sq[i]);
        n += _snprintf(line + n, sizeof(line) - (size_t)n, " waybefore=%d way=", e->way_before);
        __try {
            if (e->wp && range_readable(e->pawn, L28_PAWN_BYTES)) n += way_text(e->pawn, line + n, sizeof(line) - (size_t)n - 4);
            else n += _snprintf(line + n, sizeof(line) - (size_t)n, "0 -");
        } __except (EXCEPTION_EXECUTE_HANDLER) { n += _snprintf(line + n, sizeof(line) - (size_t)n, "-1 -"); }
        line[n++] = '\r'; line[n++] = '\n';
        l28_event(line, n);
        O.written++;
    }
    O.nev = 0;
    g_dirty = 1;
}

static void order_unhook(const char *why)
{
    char w[160];
    int r;
    InterlockedExchange(&O.enabled, 0);
    if (!O.stub || !O.entry) return;
    if (memcmp(O.entry, O.jmp, ORDER_HOOK_LEN) == 0) {
        r = write_bytes(O.entry, O.jmp, ORDER_ORIG, ORDER_HOOK_LEN, w, sizeof(w));
        if (r == 1) log_line("ORDERHOOK off (%s): MoveSelected's entry restored", why);
        else { log_line("ORDERHOOK: the MOVESEL entry could not be restored: %s", w); if (r < 0) internal_failure("order hook restore failed"); }
    }
    g_dirty = 1;
}

static void order_hook_on(void)
{
    char w[160];
    int r;
    g_dirty = 1;
    if (!O.avail) { log_line("ORDERHOOK ON refused: unavailable (%s)", O.why); return; }
    if (!O.stub) {
        uint8_t *p = alloc_near(g_base, g_imgsize);
        int32_t rel;
        DWORD old;
        if (!p) { O.avail = 0; _snprintf(O.why, sizeof(O.why), "no free memory near the game module for the stub"); log_line("ORDERHOOK ON refused: %s", O.why); return; }
        emit_stub(p, (void *)&order_hook, ORDER_ORIG, O.entry + ORDER_HOOK_LEN);
        rel = (int32_t)((intptr_t)p - (intptr_t)(O.entry + ORDER_HOOK_LEN));
        O.jmp[0] = 0xE9; memcpy(O.jmp + 1, &rel, 4);
        if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); O.avail = 0; _snprintf(O.why, sizeof(O.why), "the stub page could not be made executable"); log_line("ORDERHOOK ON refused: %s", O.why); return; }
        FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
        O.stub = p;
        log_line("ORDERHOOK: stub at %p (MOVESEL entry %p)", (void *)p, (void *)O.entry);
    }
    O.thread = GetCurrentThreadId();
    if (order_bytes_on()) { InterlockedExchange(&O.enabled, 1); log_line("ORDERHOOK already on"); return; }
    if (memcmp(O.entry, ORDER_ORIG, ORDER_HOOK_LEN) != 0) { O.avail = 0; _snprintf(O.why, sizeof(O.why), "the entry holds neither its own bytes nor this DLL's jump"); log_line("ORDERHOOK ON refused: %s", O.why); return; }
    O.nev = 0;
    InterlockedExchange(&O.enabled, 1);
    r = write_bytes(O.entry, ORDER_ORIG, O.jmp, ORDER_HOOK_LEN, w, sizeof(w));
    if (r != 1) {
        InterlockedExchange(&O.enabled, 0);
        O.avail = 0; _snprintf(O.why, sizeof(O.why), "%s", w);
        log_line("ORDERHOOK ON FAILED: %s; item marked unavailable", w);
        if (r < 0) internal_failure("order hook write failed");
        return;
    }
    log_line("ORDERHOOK on: MoveSelected at %p", (void *)O.entry);
}

/* ------------------------------------------------------------------ CHOOSE (lane 23): the job chooser runs for the villagers
 * the mod names (research\2026-11-10-game-probe\lanes\lane_s21_23\report.txt, part 2)
 *
 * Why: on a friend's copy the job board fills the engine's job list so the friend's villagers choose nothing by
 * themselves (lane 19's gate). But the game ENDS some tasks at every work cycle (selling, mining, the trader's legs) and
 * its job chooser starts the next cycle in the same think; with the list full that chooser leaves, and the villager
 * stands until the board gives the task again (7 to 26 gives per host start, the trader never on its trip). This item
 * lets the chooser run for exactly the villagers on a short list and for nobody else.
 *   CHOOSE ON           the chooser's test of the list (rva 4ddb322) jumps to a stub of this DLL: the stub runs the two
 *                       replaced instructions, and when the villager (rdi) is on the list it makes the job list look empty
 *                       to the chooser (r8 = rdx). Nobody on the list: the chooser behaves exactly as before.
 *   CHOOSE SET <hex>,<hex>,...  the list, whole (at most CHOOSE_MAX villagers; "-" = none). Addresses only: the stub
 *                       compares rdi with them and never reads through them, so a villager that died does no harm.
 *   CHOOSE OFF          the original bytes back; the list is kept (and emptied by ALLOFF).
 * Status: "CHOOSE on|off n=<on the list> hits=<chooser runs let through> sets=<SET commands>", or "CHOOSE unavailable
 * <why>" (another game build: the signature or the bytes differ). */
#define CHOOSE_MAX 256
static int on_off(const char *w, int *v);
static __declspec(align(16)) struct {
    volatile LONG n;                    /* stub: +0 the number of villagers on the list */
    volatile LONG hits;                 /* stub: +4 chooser runs let through */
    LONG64 pad;
    volatile uint64_t a[CHOOSE_MAX];    /* stub: +16 the villagers' addresses */
} g_chl;
static struct {
    int avail; char why[120];
    uint8_t *site, *stub;               /* site = the first hooked byte (pattern + CHOOSE_PATCH_OFF) */
    uint8_t jmp[CHOOSE_HOOK_LEN];
    unsigned sets, refused;
} CH;

static int choose_bytes_on(void)  { return CH.stub && CH.site && memcmp(CH.site, CH.jmp, CHOOSE_HOOK_LEN) == 0; }
static int choose_bytes_off(void) { return CH.site && memcmp(CH.site, CHOOSE_ORIG, CHOOSE_HOOK_LEN) == 0; }

static int choose_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "CHOOSE unavailable dll is off\r\n");
    if (!CH.avail) return _snprintf(buf, len, "CHOOSE unavailable %s\r\n", CH.why);
    return _snprintf(buf, len, "CHOOSE %s n=%ld hits=%ld sets=%u refused=%u\r\n", choose_bytes_on() ? "on" : "off", g_chl.n, g_chl.hits, CH.sets, CH.refused);
}

static int choose_scan(void)
{
    memset(&CH, 0, sizeof(CH));
    InterlockedExchange(&g_chl.n, 0);
    if (g_hit[S_CHOOSE].hits == 1) {
        uint8_t *p = g_base + g_hit[S_CHOOSE].rva;
        CH.avail = chooser_check(g_hit, p, (uint64_t)(uintptr_t)p, CH.why, sizeof(CH.why));
        if (CH.avail) CH.site = p + CHOOSE_PATCH_OFF;
    } else _snprintf(CH.why, sizeof(CH.why), "CHOOSE signature has %d hits (need exactly 1)", g_hit[S_CHOOSE].hits);
    log_line("  CHOOSE %s %s", CH.avail ? "off" : "unavailable", CH.avail ? "" : CH.why);
    return CH.avail;
}

/* the stub (54 bytes):
 *   push rax; push rcx; lea r8,[rdx+rcx*4]; mov rax,&g_chl; mov ecx,[rax]; test ecx,ecx; jz done
 *   loop: dec ecx; cmp rdi,[rax+rcx*8+16]; je found; test ecx,ecx; jnz loop; jmp done
 *   found: mov r8,rdx; lock inc dword [rax+4]
 *   done: pop rcx; pop rax; cmp rdx,r8; jmp <site + 7> (the je of the game) */
static int choose_make_stub(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize);
    void *tbl = (void *)&g_chl;
    uint8_t *resume;
    size_t n = 0;
    int32_t rel;
    DWORD old;
    static const uint8_t a1[] = { 0x50, 0x51, 0x4C, 0x8D, 0x04, 0x8A, 0x48, 0xB8 };
    static const uint8_t a2[] = { 0x8B, 0x08, 0x85, 0xC9, 0x74, 0x16,
                                  0xFF, 0xC9, 0x48, 0x3B, 0x7C, 0xC8, 0x10, 0x74, 0x06, 0x85, 0xC9, 0x75, 0xF3, 0xEB, 0x07,
                                  0x4C, 0x8B, 0xC2, 0xF0, 0xFF, 0x40, 0x04,
                                  0x59, 0x58, 0x49, 0x3B, 0xD0, 0xE9 };
    if (!p) return 0;
    resume = CH.site + (CHOOSE_RESUME - CHOOSE_PATCH_OFF);
    memcpy(p + n, a1, sizeof(a1)); n += sizeof(a1);
    memcpy(p + n, &tbl, 8); n += 8;
    memcpy(p + n, a2, sizeof(a2)); n += sizeof(a2);
    rel = (int32_t)((intptr_t)resume - (intptr_t)(p + n + 4));
    memcpy(p + n, &rel, 4); n += 4;
    rel = (int32_t)((intptr_t)p - (intptr_t)(CH.site + CHOOSE_HOOK_LEN));
    CH.jmp[0] = 0xE9; memcpy(CH.jmp + 1, &rel, 4);
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    CH.stub = p;
    log_line("CHOOSE: stub at %p (%Iu bytes), site %p, back to %p", (void *)p, n, (void *)CH.site, (void *)resume);
    return 1;
}

static void choose_on(void)
{
    char w[160];
    int r;
    g_dirty = 1;
    if (!CH.avail) { CH.refused++; log_line("CHOOSE ON refused: unavailable (%s)", CH.why); return; }
    if (!CH.stub && !choose_make_stub()) { CH.avail = 0; _snprintf(CH.why, sizeof(CH.why), "no free memory near the game module for the stub"); log_line("CHOOSE ON refused: %s", CH.why); return; }
    if (choose_bytes_on()) { log_line("CHOOSE already on"); return; }
    if (!choose_bytes_off()) { CH.avail = 0; _snprintf(CH.why, sizeof(CH.why), "the site holds neither its own bytes nor this DLL's jump"); log_line("CHOOSE ON refused: %s", CH.why); return; }
    r = write_bytes(CH.site, CHOOSE_ORIG, CH.jmp, CHOOSE_HOOK_LEN, w, sizeof(w));
    if (r != 1) {
        CH.avail = 0; _snprintf(CH.why, sizeof(CH.why), "%s", w);
        log_line("CHOOSE ON FAILED: %s; item marked unavailable", w);
        if (r < 0) internal_failure("choose hook write failed");
        return;
    }
    log_line("CHOOSE on at %p (stub %p), %ld villagers on the list", (void *)CH.site, (void *)CH.stub, g_chl.n);
}

static void choose_off(const char *why)
{
    char w[160];
    int r;
    if (!CH.avail || !CH.site) return;
    if (choose_bytes_on()) {
        r = write_bytes(CH.site, CH.jmp, CHOOSE_ORIG, CHOOSE_HOOK_LEN, w, sizeof(w));
        if (r != 1) { log_line("CHOOSE: the site could not be restored: %s", w); if (r < 0) internal_failure("choose restore failed"); return; }
        log_line("CHOOSE off (%s): %ld chooser runs were let through", why, g_chl.hits);
    }
    if (strcmp(why, "all patches off") == 0) InterlockedExchange(&g_chl.n, 0);
    g_dirty = 1;
}

/* CHOOSE SET a,b,c: the whole list. The count goes to 0 first, the addresses are written, then the new count: a chooser
 * run on another thread meanwhile sees a shorter list or an address being replaced (one choice more or less, no read
 * through any of them). */
static void choose_set(const char *list)
{
    uint64_t tmp[CHOOSE_MAX];
    int k = 0, i;
    const char *s = list;
    g_dirty = 1;
    if (strcmp(list, "-") != 0) {
        while (*s) {
            char *e;
            unsigned long long v = _strtoui64(s, &e, 16);
            if (e == s || v == 0 || (v & 7) != 0 || (*e != ',' && *e != 0)) { CH.refused++; log_line("CHOOSE SET refused: '%.40s' is not a list of 8-aligned hex addresses", s); return; }
            if (k >= CHOOSE_MAX) { CH.refused++; log_line("CHOOSE SET refused: more than %d villagers", CHOOSE_MAX); return; }
            tmp[k++] = (uint64_t)v;
            s = *e ? e + 1 : e;
        }
    }
    InterlockedExchange(&g_chl.n, 0);
    for (i = 0; i < k; i++) g_chl.a[i] = tmp[i];
    MemoryBarrier();
    InterlockedExchange(&g_chl.n, k);
    CH.sets++;
}

static void choose_cmd(int argc, char **argv)
{
    int v;
    if (argc == 2 && on_off(argv[1], &v)) { if (v) choose_on(); else choose_off("CHOOSE OFF"); return; }
    if (argc == 3 && _stricmp(argv[1], "SET") == 0) {
        if (!CH.avail) { CH.refused++; g_dirty = 1; log_line("CHOOSE SET refused: unavailable (%s)", CH.why); return; }
        choose_set(argv[2]); return;
    }
    CH.refused++; g_dirty = 1;
    log_line("CHOOSE refused: needs ON, OFF or SET <hex>,<hex>,... (or SET -)");
}

/* ------------------------------------------------------------------ NOREGION (the lead, 2026-11-13)
 * The game's routine for the goods of a work hit (4db43c0) hands the region of the worked building to two routines
 * that count goods for a region (4c4a960, 4c4aa70) without looking at it; the first call of both, GetWorld(region),
 * reads through it. A building taken out of the game has no region: a friend's copy crashed there twice, a villager's
 * work hit at a building demolished a moment before (research\2026-11-10-game-probe\lanes\lane_s21_0\crash_demolish_site).
 *   NOREGION ON    that first call of both routines goes to a stub of this DLL: a null region returns null at once
 *                  (the routine then leaves exactly as it does for an object without a world); any other region goes
 *                  on to the game's GetWorld untouched. Only the calls' four displacement bytes change. Both or none.
 *   NOREGION OFF   the original displacements back (also at ALLOFF).
 * Status: "NOREGION on|off hits=<null regions turned away> refused=<n>", or "NOREGION unavailable <why>". */
static volatile LONG g_nr_hits;
static const int NR_SIG[NOREGION_SITES] = { S_NOREGION, S_NOREGION2 };
static struct {
    int avail; char why[160];
    uint8_t *site[NOREGION_SITES], *stub, *target;      /* site = the four displacement bytes of a call */
    uint8_t orig[NOREGION_SITES][4], jmp[NOREGION_SITES][4];
    unsigned refused;
} NR;

static int noregion_bytes_on(void)  { int k; if (!NR.stub) return 0; for (k = 0; k < NOREGION_SITES; k++) if (!NR.site[k] || memcmp(NR.site[k], NR.jmp[k], 4) != 0) return 0; return 1; }
static int noregion_bytes_off(void) { int k; for (k = 0; k < NOREGION_SITES; k++) if (!NR.site[k] || memcmp(NR.site[k], NR.orig[k], 4) != 0) return 0; return 1; }

static int noregion_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "NOREGION unavailable dll is off\r\n");
    if (!NR.avail) return _snprintf(buf, len, "NOREGION unavailable %s\r\n", NR.why);
    return _snprintf(buf, len, "NOREGION %s hits=%ld refused=%u\r\n", noregion_bytes_on() ? "on" : "off", g_nr_hits, NR.refused);
}

static int noregion_scan(void)
{
    int k;
    memset(&NR, 0, sizeof(NR));
    NR.avail = 1;
    for (k = 0; k < NOREGION_SITES && NR.avail; k++) {
        uint8_t *p = g_base + g_hit[NR_SIG[k]].rva;
        uint64_t target = 0;
        if (!noregion_check(g_hit, NR_SIG[k], p, (uint64_t)(uintptr_t)p, (uint64_t)(uintptr_t)g_base, g_imgsize, &target, NR.why, sizeof(NR.why))) { NR.avail = 0; break; }
        if (k == 0) NR.target = (uint8_t *)(uintptr_t)target;
        else if ((uint8_t *)(uintptr_t)target != NR.target) { NR.avail = 0; _snprintf(NR.why, sizeof(NR.why), "the two routines' first calls go to different places"); break; }
        NR.site[k] = p + NOREGION_CALL_OFF + 1; memcpy(NR.orig[k], NR.site[k], 4);
    }
    log_line("  NOREGION %s %s", NR.avail ? "off" : "unavailable", NR.avail ? "" : NR.why);
    return NR.avail;
}

/* the stub (26 bytes): test rcx,rcx; jz null; jmp <the game's GetWorld>;
 *                      null: mov rax,&g_nr_hits; lock inc dword [rax]; xor eax,eax; ret */
static int noregion_make_stub(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize);
    void *cnt = (void *)&g_nr_hits;
    size_t n = 0;
    int32_t rel;
    int k;
    DWORD old;
    static const uint8_t a1[] = { 0x48, 0x85, 0xC9, 0x74, 0x05, 0xE9 };
    static const uint8_t a2[] = { 0x48, 0xB8 };
    static const uint8_t a3[] = { 0xF0, 0xFF, 0x00, 0x33, 0xC0, 0xC3 };
    if (!p) return 0;
    memcpy(p + n, a1, sizeof(a1)); n += sizeof(a1);
    rel = (int32_t)((intptr_t)NR.target - (intptr_t)(p + n + 4));
    memcpy(p + n, &rel, 4); n += 4;
    memcpy(p + n, a2, sizeof(a2)); n += sizeof(a2);
    memcpy(p + n, &cnt, 8); n += 8;
    memcpy(p + n, a3, sizeof(a3)); n += sizeof(a3);
    for (k = 0; k < NOREGION_SITES; k++) {
        rel = (int32_t)((intptr_t)p - (intptr_t)(NR.site[k] + 4));
        memcpy(NR.jmp[k], &rel, 4);
    }
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    NR.stub = p;
    log_line("NOREGION: stub at %p (%Iu bytes), calls at %p and %p, the game's routine at %p", (void *)p, n, (void *)(NR.site[0] - 1), (void *)(NR.site[1] - 1), (void *)NR.target);
    return 1;
}

/* put the original displacement back wherever this DLL's is (each on its own) */
static void noregion_unhook(void)
{
    char w[160];
    int k, r;
    if (!NR.avail || !NR.stub) return;
    for (k = 0; k < NOREGION_SITES; k++)
        if (memcmp(NR.site[k], NR.jmp[k], 4) == 0) {
            r = write_bytes(NR.site[k], NR.jmp[k], NR.orig[k], 4, w, sizeof(w));
            if (r != 1) { log_line("NOREGION: %s could not be restored: %s", SIGS[NR_SIG[k]].name, w); if (r < 0) internal_failure("noregion restore failed"); }
        }
    g_dirty = 1;
}

static void noregion_on(void)
{
    char w[160];
    int k, r = 1;
    g_dirty = 1;
    if (!NR.avail) { NR.refused++; log_line("NOREGION ON refused: unavailable (%s)", NR.why); return; }
    if (!NR.stub && !noregion_make_stub()) { NR.avail = 0; _snprintf(NR.why, sizeof(NR.why), "no free memory near the game module for the stub"); log_line("NOREGION ON refused: %s", NR.why); return; }
    if (noregion_bytes_on()) { log_line("NOREGION already on"); return; }
    if (!noregion_bytes_off()) { NR.avail = 0; _snprintf(NR.why, sizeof(NR.why), "a call holds neither its own displacement nor this DLL's"); log_line("NOREGION ON refused: %s", NR.why); return; }
    for (k = 0; k < NOREGION_SITES && r == 1; k++) {
        r = write_bytes(NR.site[k], NR.orig[k], NR.jmp[k], 4, w, sizeof(w));
        if (r != 1) log_line("NOREGION ON: %s not written: %s", SIGS[NR_SIG[k]].name, w);
    }
    if (r != 1) {
        noregion_unhook();                              /* both or none */
        NR.avail = 0; _snprintf(NR.why, sizeof(NR.why), "%s", w);
        log_line("NOREGION ON FAILED: %s; both calls put back, item marked unavailable", w);
        if (r < 0) internal_failure("noregion write failed");
        return;
    }
    log_line("NOREGION on at %p and %p (stub %p)", (void *)(NR.site[0] - 1), (void *)(NR.site[1] - 1), (void *)NR.stub);
}

static void noregion_off(const char *why)
{
    int was;
    if (!NR.avail || !NR.stub) return;
    was = noregion_bytes_on();
    noregion_unhook();
    if (was) log_line("NOREGION off (%s): %ld null regions were turned away", why, g_nr_hits);
}

static void noregion_cmd(int argc, char **argv)
{
    int v;
    if (argc == 2 && on_off(argv[1], &v)) { if (v) noregion_on(); else noregion_off("NOREGION OFF"); return; }
    NR.refused++; g_dirty = 1;
    log_line("NOREGION refused: needs ON or OFF");
}

/* ------------------------------------------------------------------ lane 32: GATESET
 * GATESET <token> <road> <index> <x,y,z>   the place of gate record <index> of a wall (+498h, 60h bytes a record, the
 * place at +20h) is set to the given one: the drawing copy's value. The copy that draws a wall and the copy that replays
 * it work the gate's height out apart (lane 28: 3989.30 against 3989.27, 3934.15 against 3934.14, with equal control
 * points); research\2026-11-10-game-probe\lanes\lane_s21_32\report.txt item 4. Only a small correction is written: x
 * and y must lie within 1.0 of the record's own, z within 5.0. Same guards as WALLGET (needs COMMITROAD's signature
 * and the known build: +498h is held by no signature). Nothing is patched; the record is plain heap memory. */
#define L32_GATE_XY 1.0
#define L32_GATE_Z  5.0
static void gateset_cmd(int argc, char **argv)
{
    unsigned long long addr = 0;
    char why[200];
    uint8_t *road;
    tarr gates;
    int idx = -1, r = 0;
    vec3 want = { 0, 0, 0 }, was = { 0, 0, 0 };
    const char *tok = argc > 1 ? argv[1] : "-";
    g_dirty = 1;
    if (!g_l_ok[L_COMMIT]) { g_calls_failed++; l28_reply("R %s GATESET refused unavailable (%s)", tok, g_l_why[L_COMMIT]); return; }
    if (argc != 5 || !parse_u64(argv[2], &addr) || !parse_i32(argv[3], &idx) || idx < 0 || parse_points(argv[4], &want, 1) != 1) {
        g_calls_failed++; l28_reply("R %s GATESET refused needs <token> <road> <index> <x,y,z>", tok); return;
    }
    if (!comp_sane(addr, L28_ROAD_BYTES, why, sizeof(why))) { g_calls_failed++; l28_reply("R %s GATESET refused %s", tok, why); return; }
    road = (uint8_t *)(uintptr_t)addr;
    __try {
        memcpy(&gates, road + ROAD_GATES, sizeof(gates));
        if (!tarr_sane(&gates, 256, GATE_STRIDE)) r = -1;
        else if (idx >= gates.num) r = -3;
        else {
            uint8_t *g = gates.data + (size_t)idx * GATE_STRIDE;
            memcpy(&was, g + GATE_POS, sizeof(was));
            if (fabs(was.x - want.x) > L32_GATE_XY || fabs(was.y - want.y) > L32_GATE_XY || fabs(was.z - want.z) > L32_GATE_Z) r = -4;
            else { memcpy(g + GATE_POS, &want, sizeof(want)); r = 1; }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { r = -2; }
    if (r != 1) {
        g_calls_failed++;
        if (r == -4) l28_reply("R %s GATESET refused gate %d is at %.2f,%.2f,%.2f: too far from %.2f,%.2f,%.2f", tok, idx, was.x, was.y, was.z, want.x, want.y, want.z);
        else l28_reply("R %s GATESET refused %s", tok, r == -1 ? "the object's gate list is not sane (not a road?)" : r == -3 ? "no gate record with that index" : "the write faulted");
        return;
    }
    log_line("GATESET(%llX, %d): height %.4f -> %.4f", addr, idx, was.z, want.z);
    l28_reply("R %s GATESET ok %d %.4f %.4f", tok, idx, was.z, want.z);
}

/* ------------------------------------------------------------------ lane 53: WALLSET
 * WALLSET <token> <road> <x,y,z|x,y,z|...>   2 to 64 points (lane 55; was 21, the draw tool's own stop, but a placed wall
 * grows past it by the game's own shift-click and gate-marker inserts): a wall of the castle plan gets these control points, the
 * way the game itself changes a placed wall. What the game does (read in the game file, lane 53's report):
 *   - a control point dragged (the planner's per-frame update, 4B30FD9): ctl[i] := the point; rebuild(road, 0)
 *   - alt-click on a control point (4B17609): the point is taken out of the list; rebuild(road, 0)
 *   - shift-click on the wall or a click on a gate marker (4B176AB, 4B17521): insert(road, &point); rebuild(road, 0)
 * with rebuild = 4cd6430 (signature WALLREB) and insert = 4ccc3e0 (signature WALLINS). Nothing else is written: the
 * spline, the gate records and the pieces all come out of the rebuild.
 * This command: the same or fewer points are written in place and the length set (the game's own removal also leaves
 * the list's memory alone but for a shrink). More points than the list's memory holds: the game's insert is called
 * with the middle of the wall's longest stretch until the list is long enough (only to let the game's allocator
 * lengthen it; every point is then written); if the list does not grow the old points are put back and the command is
 * refused. Then one rebuild.
 * Guards: both signatures exactly once and the known build (+2B3h and +318h are offsets no pattern but WALLREB's
 * holds), the road looks like a live object of this module, it is a wall of the plan (isBlueprint, +2B3h), its point
 * list is sane (2 to 64 points). A fault in a routine marks WALLSET unavailable for the rest of the run. */
#define L53_OLD_MAX 64
#define L53_PT_MAX  64          /* lane 55: a placed wall's points (the sanity limit of its list, as WALLGET reads) */
typedef void (*wallreb_fn)(void *road, unsigned char flag);
typedef int  (*wallins_fn)(void *road, const vec3 *point);
static char     g_l53_dead_why[120];
static unsigned g_l53_sets, g_l53_grown;
static const char *l53_why(void)
{
    static char why[160];
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    if (g_l53_dead) return g_l53_dead_why;
    if (!known) { _snprintf(why, sizeof(why), "another game build (timestamp %X)", g_stamp); return why; }
    if (g_hit[S_WALLREB].hits != 1) { _snprintf(why, sizeof(why), "WALLREB signature has %d hits (need exactly 1)", g_hit[S_WALLREB].hits); return why; }
    if (g_hit[S_WALLINS].hits != 1) { _snprintf(why, sizeof(why), "WALLINS signature has %d hits (need exactly 1)", g_hit[S_WALLINS].hits); return why; }
    return "";
}
static int l53_status(char *buf, size_t len)
{
    const char *why = g_off ? "dll is off" : l53_why();
    if (*why) return _snprintf(buf, len, "WALLSET unavailable %s\r\n", why);
    return _snprintf(buf, len, "WALLSET available sets=%u grown=%u\r\n", g_l53_sets, g_l53_grown);
}
static void wallset_cmd(int argc, char **argv)
{
    static vec3 pts[L53_PT_MAX], old[L53_OLD_MAX];
    unsigned long long addr = 0;
    char why[200];
    uint8_t *road;
    tarr ctl;
    int n, oldn = 0, r = 0, grown = 0, tries = 0, stage = 0;
    DWORD code = 0;
    const char *tok = argc > 1 ? argv[1] : "-";
    g_dirty = 1;
    if (*l53_why()) { g_calls_failed++; l28_reply("R %s WALLSET refused unavailable (%s)", tok, l53_why()); return; }
    if (argc != 4 || !parse_u64(argv[2], &addr)) { g_calls_failed++; l28_reply("R %s WALLSET refused needs <token> <road> <x,y,z|...>", tok); return; }
    n = parse_points(argv[3], pts, L53_PT_MAX);
    if (n < 2) { g_calls_failed++; l28_reply("R %s WALLSET refused needs 2 to %d points inside the map", tok, L53_PT_MAX); return; }
    if (!comp_sane(addr, L28_ROAD_BYTES, why, sizeof(why))) { g_calls_failed++; l28_reply("R %s WALLSET refused %s", tok, why); return; }
    road = (uint8_t *)(uintptr_t)addr;
    __try {
        memcpy(&ctl, road + ROAD_CTL, sizeof(ctl));
        if (!tarr_sane(&ctl, L53_OLD_MAX, sizeof(vec3)) || ctl.num < 2) r = -1;
        else if (road[ROAD_KIND] != 1) r = -3;
        else {
            oldn = ctl.num;
            memcpy(old, ctl.data, (size_t)oldn * sizeof(vec3));
            /* more points than the list's memory holds: the game's own insert lengthens it */
            while (ctl.max < n && tries < 2 * L53_PT_MAX) {
                vec3 cur[L53_OLD_MAX], mid;
                char used[L53_OLD_MAX];
                int best = -1, before = ctl.num, k, rank;
                memcpy(cur, ctl.data, (size_t)ctl.num * sizeof(vec3));
                memset(used, 0, sizeof(used));
                /* the middle of the longest stretch; after a refusal (nothing changed) the next longest */
                for (rank = 0; rank <= tries; rank++) {
                    double bd = -1.0;
                    best = -1;
                    for (k = 0; k + 1 < ctl.num; k++) {
                        double d = dist2(&cur[k], &cur[k + 1]);
                        if (!used[k] && d > bd) { bd = d; best = k; }
                    }
                    if (best < 0) break;
                    used[best] = 1;
                }
                if (best < 0) break;
                mid.x = (cur[best].x + cur[best + 1].x) / 2; mid.y = (cur[best].y + cur[best + 1].y) / 2; mid.z = (cur[best].z + cur[best + 1].z) / 2;
                stage = 1;
                ((wallins_fn)(void *)(g_base + g_hit[S_WALLINS].rva))(road, &mid);
                stage = 0;
                memcpy(&ctl, road + ROAD_CTL, sizeof(ctl));
                if (!tarr_sane(&ctl, L53_OLD_MAX, sizeof(vec3)) || ctl.num < 2) { r = -1; break; }
                if (ctl.num > before) grown++; else tries++;
            }
            if (r == 0 && ctl.max < n) {
                /* the list did not grow: the old points back (they fit: the list only ever grew), one rebuild */
                if (ctl.max >= oldn) {
                    memcpy(ctl.data, old, (size_t)oldn * sizeof(vec3));
                    *(int32_t *)(road + ROAD_CTL + 8) = oldn;
                    if (grown) { stage = 2; ((wallreb_fn)(void *)(g_base + g_hit[S_WALLREB].rva))(road, 0); stage = 0; }
                }
                r = -4;
            }
            if (r == 0) {
                memcpy(ctl.data, pts, (size_t)n * sizeof(vec3));
                *(int32_t *)(road + ROAD_CTL + 8) = n;
                stage = 2;
                ((wallreb_fn)(void *)(g_base + g_hit[S_WALLREB].rva))(road, 0);
                stage = 0;
                r = 1;
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { code = GetExceptionCode(); }
    if (code) {
        g_calls_failed++;
        if (stage) {
            g_l53_dead = 1;
            _snprintf(g_l53_dead_why, sizeof(g_l53_dead_why), "exception %08lX in an earlier call", code);
            log_line("WALLSET: %s raised exception %08lX: now unavailable", stage == 1 ? "WALLINS" : "WALLREB", code);
        }
        l28_reply("R %s WALLSET exception %08lX in %s", tok, code, stage == 1 ? "WALLINS" : stage == 2 ? "WALLREB" : "the write");
        return;
    }
    if (r != 1) {
        g_calls_failed++;
        l28_reply("R %s WALLSET refused %s", tok, r == -1 ? "the object's point list is not sane (not a wall?)" : r == -3 ? "the road is not a wall of the plan"
                  : "the game did not lengthen the point list (the old points are back)");
        return;
    }
    g_l53_sets++; g_l53_grown += (unsigned)grown;
    log_line("WALLSET(%llX): %d -> %d control points, %d inserted by the game, rebuilt", addr, oldn, n, grown);
    l28_reply("R %s WALLSET ok was=%d now=%d grown=%d", tok, oldn, n, grown);
}

/* UNCAMP <token> <SquadComponent> <handle>   the game's own "let go of the camp" (4d72b60, signature UNCAMP): the
 * squad's camp is cleared and its Control set to 0, so it takes orders again. On the host the enemy AI calls it when a
 * camp's brigands march out (executeArmyCommand); a friend's AI is off, so the mod calls it when the host's squad has
 * let go. The caller checks Control == 4 first (coop_patch.lua). Needs the signature once and the known build (the
 * Squad offsets inside the routine are this build's). A fault marks it unavailable for the session. */
typedef void (*uncamp_fn)(void *comp, int handle);
static int  g_uncamp_dead;
static char g_uncamp_why[120];
static void uncamp_cmd(int argc, char **argv)
{
    unsigned long long addr = 0;
    int handle = 0;
    char why[200];
    DWORD code = 0;
    const char *tok = argc > 1 ? argv[1] : "-";
    g_dirty = 1;
    if (g_hit[S_UNCAMP].hits != 1) { g_calls_failed++; l28_reply("R %s UNCAMP refused unavailable (UNCAMP signature has %d hits, need exactly 1)", tok, g_hit[S_UNCAMP].hits); return; }
    if (g_stamp != KNOWN_TIMESTAMP || g_imgsize != KNOWN_IMAGESIZE) { g_calls_failed++; l28_reply("R %s UNCAMP refused unavailable (not the known build)", tok); return; }
    if (g_uncamp_dead) { g_calls_failed++; l28_reply("R %s UNCAMP refused unavailable (%s)", tok, g_uncamp_why); return; }
    if (argc != 4 || !parse_u64(argv[2], &addr) || !parse_i32(argv[3], &handle) || handle == 0) { g_calls_failed++; l28_reply("R %s UNCAMP refused needs <token> <SquadComponent> <handle>", tok); return; }
    if (!comp_sane(addr, COMP_CHECK_BYTES, why, sizeof(why))) { g_calls_failed++; l28_reply("R %s UNCAMP refused %s", tok, why); return; }
    __try { ((uncamp_fn)(void *)(g_base + g_hit[S_UNCAMP].rva))((void *)(uintptr_t)addr, handle); }
    __except (EXCEPTION_EXECUTE_HANDLER) { code = GetExceptionCode(); }
    if (code) {
        g_calls_failed++; g_uncamp_dead = 1;
        _snprintf(g_uncamp_why, sizeof(g_uncamp_why), "exception %08lX in an earlier call", code);
        log_line("UNCAMP(%llX, %d) raised exception %08lX: UNCAMP is now unavailable", addr, handle, code);
        l28_reply("R %s UNCAMP exception %08lX", tok, code);
        return;
    }
    log_line("UNCAMP(%llX, %d) called", addr, handle);
    l28_reply("R %s UNCAMP ok", tok);
}

/* ------------------------------------------------------------------ PICK (lane 35): the chooser's pick held to the host's task
 * (research/2026-11-10-game-probe/lanes/lane_s21_35/report.txt, item 1)
 *
 * Why: with CHOOSE a friend's villager whose host task is one the game restarts every cycle (selling, mining, leading an
 * ox) chooses its next cycle itself. Its chooser does not always pick what the host's chose: a miner a fetch, an ox
 * leader another ox (lane 23 part 3: 4 to 10 gives per host start, the board giving the host's task back each time).
 * This item lets the chooser start, for a villager on its list, only the task the board names for it.
 *   PICK ON            two hooks: (1) the unit's think calls the chooser through a stub of this DLL that notes the unit
 *                      while the chooser runs; (2) setTask's first two instructions (9 bytes) move into a stub that calls
 *                      pick_hook first. Nobody on the list: everything as before.
 *   PICK SET <unit>:<type>:<target unit>,...   the list, whole (hex; target unit 0 = any; "-" = none). At most
 *                      PICK_MAX villagers. For a villager on it:
 *                        any setTask with that type (and that target unit when one is named) is kept as its task record
 *                        (the board's own give, or the chooser's pick of the same task);
 *                        when its chooser ends with a setTask of another type or target unit, that pick is let through
 *                        and, as the chooser returns, setTask runs once more with the kept record (copied to a buffer of
 *                        this DLL; kept at most PICK_FRESH_MS): the game's own setTask ends the pick with the game's own
 *                        routine (what it reserved is given back) and stores the kept task, in the same think. With
 *                        none kept the pick stays ("left": the board gives the host's task back, as before PICK).
 *                      Outside the chooser nothing is changed (the board's other gives, fleeing, fighting ...).
 *                      A villager put on the list while its current task (Tasks[0], unit +898h / +8A0h) is that task
 *                      has it kept at once.
 *   PICK GONE <hex>,<hex>,...  (lane 35, round six) objects that left the game or are leaving it (a demolished
 *                      building, a villager or an animal gone): every entry whose villager is one of them, or whose kept
 *                      record names one (target / final building +98h / +A0h, target / final unit +A8h / +B0h, resource
 *                      +C0h), is taken off the list at once; the addresses are remembered (the last PICK_GONE_MAX), and
 *                      a record naming one is never kept, seeded or set again.
 *   FOLLOW (lane 35, round seven; part of PICK ON when signature SETTHUNK is found): a Follow (task type 41, leading an
 *                      ox) that the GAME sets (setTask's return address is not the reflected setTask's call, SETTHUNK) for
 *                      a villager not on the list with type 41 and that ox is replaced: by the kept Follow of the host's
 *                      ox, else by the villager's own current task; with no task it goes through ("followleft"). The ox's own guide request
 *                      picks a villager on each copy by itself; on a friend only the host's leader may lead it (the board
 *                      gives it, through the reflected setTask). Counted as "follow=".
 *   PICK OFF           both hooks out; the list kept (emptied by ALLOFF).
 * The kept records hold object pointers the game itself put there at most PICK_FRESH_MS before; the board takes a villager
 * off the list as soon as its host task changes (a demolished workplace ends the host's task too).
 * Status: "PICK on|off n= same= subst= left= kept= other= sets= bad= faults=" and "PICKS replaced <type>x<n> ..."
 * (the types the chooser picked and this item replaced; its own first word, so the mod's status parser keeps the PICK
 * line), or "PICK unavailable <why>". */
#define PICK_MAX      256
#define PICK_REC      0xD8          /* sizeof(FTask): setTask copies 0xD8 bytes (0x80 + 0x58) */
#define PICK_TU       0xA8          /* FTask.targetUnit (the reflected struct /Script/ManorLords.Task, lane 35 d1) */
#define PICK_FRESH_MS 60000
#define PICK_RING     8
#define PICK_GONE_MAX 256           /* round six: addresses of objects that left the game, remembered */
#define PICK_TASKS    0x898         /* SMUnit Tasks: data pointer; +8A0h its count (setTask, 4e1cab0) */
typedef void (*pick_settask_fn)(uint8_t *unit, const uint8_t *rec);
typedef struct { uint8_t *unit; uint64_t tu; int type; ULONGLONG kept_t; uint8_t kept[PICK_REC]; } pick_ent;
static struct {
    int avail; char why[160];
    uint8_t *settask, *callsite, *chooser, *stub_set, *stub_call;
    uint8_t jmp_set[PICK_HOOK_LEN], call_orig[PICK_HOOK_LEN], call_new[PICK_HOOK_LEN];
    volatile LONG enabled; DWORD thread;
    pick_ent e[PICK_MAX]; volatile LONG n;
    uint8_t *cur; int depth, pend;
    uint8_t ring[PICK_RING][PICK_REC]; int ringi;
    unsigned same, subst, left, kept, other, sets, bad, faults, seeded;
    unsigned bytype[256];
    uint64_t gone[PICK_GONE_MAX]; int ngone, gonei;   /* round six: the last PICK_GONE_MAX addresses named gone */
    unsigned gonecmds, dropped, stale;                /* GONE commands; entries dropped by them; kept records refused */
    uint64_t thunk_ret; unsigned follow, followok, followleft;  /* round seven: the reflected setTask's return address; Follows replaced / the board's leader's / left (no task to keep) */
} PK;

static int pick_bytes_on(void)  { return PK.stub_set && memcmp(PK.settask, PK.jmp_set, PICK_HOOK_LEN) == 0 && memcmp(PK.callsite, PK.call_new, PICK_HOOK_LEN) == 0; }
static int pick_bytes_off(void) { return PK.settask && memcmp(PK.settask, PICK_SET_ORIG, PICK_HOOK_LEN) == 0 && memcmp(PK.callsite, PK.call_orig, PICK_HOOK_LEN) == 0; }

static int pick_status(char *buf, size_t len)
{
    int n, k, shown = 0;
    unsigned done[256];
    if (g_off) return _snprintf(buf, len, "PICK unavailable dll is off\r\n");
    if (!PK.avail) return _snprintf(buf, len, "PICK unavailable %s\r\n", PK.why);
    n = _snprintf(buf, len, "PICK %s n=%ld same=%u subst=%u left=%u kept=%u seeded=%u other=%u sets=%u bad=%u faults=%u gone=%u dropped=%u stale=%u follow=%u followok=%u followleft=%u\r\nPICKS replaced",
                  pick_bytes_on() ? "on" : "off", PK.n, PK.same, PK.subst, PK.left, PK.kept, PK.seeded, PK.other, PK.sets, PK.bad, PK.faults, PK.gonecmds, PK.dropped, PK.stale, PK.follow, PK.followok, PK.followleft);
    memcpy(done, PK.bytype, sizeof(done));
    while (shown < 8) {                 /* the most frequent picks replaced, at most 8 */
        int best = -1;
        for (k = 0; k < 256; k++) if (done[k] && (best < 0 || done[k] > done[best])) best = k;
        if (best < 0) break;
        n += _snprintf(buf + n, len - (size_t)n, " %dx%u", best, done[best]); done[best] = 0; shown++;
    }
    if (!shown) n += _snprintf(buf + n, len - (size_t)n, " -");
    n += _snprintf(buf + n, len - (size_t)n, "\r\n");
    return n;
}

static int pick_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    memset(&PK, 0, sizeof(PK));
    if (!known) _snprintf(PK.why, sizeof(PK.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_SETTASK].hits == 1 && g_hit[S_CHOOSECALL].hits == 1 && g_hit[S_CHOOSE].hits == 1) {
        uint8_t *st = g_base + g_hit[S_SETTASK].rva, *cs = g_base + g_hit[S_CHOOSECALL].rva, *ch = g_base + g_hit[S_CHOOSE].rva - PICK_CHOOSER_SITE;
        PK.avail = pick_check(g_hit, st, (uint64_t)(uintptr_t)st, cs, (uint64_t)(uintptr_t)cs, (uint64_t)(uintptr_t)(g_base + g_hit[S_CHOOSE].rva), ch, PK.why, sizeof(PK.why));
        if (PK.avail) { PK.settask = st; PK.callsite = cs + PICK_CALL_OFF; PK.chooser = ch; memcpy(PK.call_orig, PK.callsite, PICK_HOOK_LEN); }
        /* round seven: the reflected setTask's call (SETTHUNK): its E8 at +18 must reach SETTASK; else FOLLOW stays out */
        if (PK.avail && g_hit[S_SETTHUNK].hits == 1) {
            const uint8_t *tc = g_base + g_hit[S_SETTHUNK].rva + 18;
            int32_t rel; memcpy(&rel, tc + 1, 4);
            if (tc[0] == 0xE8 && tc + 5 + rel == st) PK.thunk_ret = (uint64_t)(uintptr_t)(tc + 5);
        }
    } else _snprintf(PK.why, sizeof(PK.why), "signature hits SETTASK %d CHOOSECALL %d CHOOSE %d (need exactly 1 each)", g_hit[S_SETTASK].hits, g_hit[S_CHOOSECALL].hits, g_hit[S_CHOOSE].hits);
    log_line("  PICK %s %s", PK.avail ? "off" : "unavailable", PK.avail ? "" : PK.why);
    return PK.avail;
}

static pick_ent *pick_find(const uint8_t *unit)
{
    LONG i, n = PK.n;
    for (i = 0; i < n; i++) if (PK.e[i].unit == unit) return &PK.e[i];
    return NULL;
}

/* round six: is this address one named gone? does this record (0xD8 bytes) name one? */
static int pick_is_gone(uint64_t a)
{
    int i;
    if (!a) return 0;
    for (i = 0; i < PK.ngone; i++) if (PK.gone[i] == a) return 1;
    return 0;
}
static int pick_rec_gone(const uint8_t *rec)
{
    static const int offs[5] = { 0x98, 0xA0, 0xA8, 0xB0, 0xC0 };
    int k;
    for (k = 0; k < 5; k++) { uint64_t a; memcpy(&a, rec + offs[k], 8); if (pick_is_gone(a)) return 1; }
    return 0;
}

/* called by the call stub before and after the chooser runs (the game thread only) */
static void pick_enter(uint8_t *unit)
{
    wd_in(WD_PICKC);                         /* lane 51: the stub always calls pick_enter, the chooser, pick_leave */
    if (!PK.enabled) return;
    if (GetCurrentThreadId() != PK.thread) { PK.other++; return; }
    if (PK.depth++ == 0) { PK.cur = pick_find(unit) ? unit : NULL; PK.pend = 0; }
}
/* the chooser returned: a pick of another task is followed by setTask(kept), outside the chooser (the hook keeps it) */
static void pick_leave(void)
{
    uint8_t *u;
    pick_ent *e;
    wd_out(WD_PICKC);
    if (!PK.enabled || GetCurrentThreadId() != PK.thread) return;
    if (PK.depth == 0 || --PK.depth != 0) return;
    u = PK.cur; PK.cur = NULL;
    if (!PK.pend || !u) return;
    PK.pend = 0;
    e = pick_find(u);
    if (!e || !e->kept_t || GetTickCount64() - e->kept_t >= PICK_FRESH_MS) { PK.left++; return; }
    if (pick_rec_gone(e->kept)) { e->kept_t = 0; PK.stale++; PK.left++; return; }   /* round six: never hand it over */
    __try {
        uint8_t *b = PK.ring[PK.ringi]; PK.ringi = (PK.ringi + 1) % PICK_RING;
        memcpy(b, e->kept, PICK_REC);
        ((pick_settask_fn)(void *)PK.settask)(u, b);
        PK.subst++;
    } __except (EXCEPTION_EXECUTE_HANDLER) { PK.faults++; InterlockedExchange(&PK.enabled, 0); }
}

/* called by the setTask stub; frame = { r9, r8, rdx, rcx, return address }. A return of 0 would make setTask return at
 * once (the stub can; this version always lets the call through and corrects after the chooser, see pick_leave). */
static int pick_match(const pick_ent *e, const uint8_t *rec)
{
    uint64_t tu;
    memcpy(&tu, rec + PICK_TU, 8);
    return (int)rec[0] == e->type && (e->tu == 0 || tu == e->tu);
}
static int pick_hook_wd(uint8_t *unit, uint64_t *frame)
{
    if (!PK.enabled) return 1;
    if (GetCurrentThreadId() != PK.thread) { PK.other++; return 1; }
    __try {
        pick_ent *e = pick_find(unit);
        const uint8_t *rec = (const uint8_t *)(uintptr_t)frame[2];
        int in = PK.cur != NULL && PK.cur == unit;
        /* round seven, FOLLOW: a Follow the game sets by itself only for the villager the board names for that ox */
        if (rec && rec[0] == 41 && PK.thunk_ret && frame[4] != PK.thunk_ret) {
            uint64_t tu; memcpy(&tu, rec + PICK_TU, 8);
            /* never refused (the game's guide path 4e15ab0 plans the path of the task it just set, 4e1b950, and writes
             * into Tasks[0] unchecked: a refusal left no task and three friends' games closed, writing 0x8): the call
             * gets another record instead - the host's Follow the board gave this villager (kept), else the villager's
             * own current task (Tasks[0], copied: setTask ends it first); a villager with no task gets the Follow */
            if (!e || e->type != 41 || (e->tu && tu != e->tu)) {
                const uint8_t *alt = NULL;
                if (e && e->type == 41 && e->kept_t && GetTickCount64() - e->kept_t < PICK_FRESH_MS && !pick_rec_gone(e->kept)) alt = e->kept;
                else {
                    const uint8_t *data; int32_t cnt;
                    memcpy(&data, unit + PICK_TASKS, 8); memcpy(&cnt, unit + PICK_TASKS + 8, 4);
                    if (cnt > 0 && cnt < 64 && data && data[0] != 41 && !pick_rec_gone(data)) alt = data;
                }
                if (alt) { uint8_t *b = PK.ring[PK.ringi]; PK.ringi = (PK.ringi + 1) % PICK_RING; memcpy(b, alt, PICK_REC); frame[2] = (uint64_t)(uintptr_t)b; PK.follow++; }
                else PK.followleft++;
                return 1;
            }
            PK.followok++;
        }
        if (e && rec) {
            if (pick_match(e, rec) && pick_rec_gone(rec)) { e->kept_t = 0; PK.stale++; if (in) PK.pend = 0; }
            else if (pick_match(e, rec)) {
                memcpy(e->kept, rec, PICK_REC); e->kept_t = GetTickCount64(); PK.kept++;
                if (in) { PK.same++; PK.pend = 0; }
            } else if (in) { PK.bytype[rec[0]]++; PK.pend = 1; }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { PK.faults++; InterlockedExchange(&PK.enabled, 0); }
    return 1;
}
static int pick_hook(uint8_t *unit, uint64_t *frame)   /* lane 51: the watchdog's marks around it */
{
    int r; wd_in(WD_PICK); r = pick_hook_wd(unit, frame); wd_out(WD_PICK); return r;
}

/* the setTask stub: push rcx rdx r8 r9; sub rsp,28h; lea rdx,[rsp+28h]; mov rax,pick_hook; call rax; add rsp,28h;
 * pop r9 r8 rdx rcx; test eax,eax; jz ret; push rbx; sub rsp,120h; jmp [rip+0] -> setTask + 9; ret: ret
 * the call stub: push rcx rdx r8 r9; sub rsp,28h; mov rax,pick_enter; call rax; add rsp,28h; pop r9 r8 rdx rcx;
 * sub rsp,28h; mov rax,<chooser>; call rax; add rsp,28h; push rax; sub rsp,20h; mov rax,pick_leave; call rax;
 * add rsp,20h; pop rax; ret */
static int pick_make_stubs(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize), *s2, *resume = PK.settask + PICK_SET_LEN;
    void *fn;
    size_t n = 0;
    int32_t rel;
    DWORD old;
    static const uint8_t pre[]  = { 0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x48, 0x83, 0xEC, 0x28, 0x48, 0x8D, 0x54, 0x24, 0x28, 0x48, 0xB8 };
    static const uint8_t post[] = { 0xFF, 0xD0, 0x48, 0x83, 0xC4, 0x28, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59, 0x85, 0xC0, 0x74, 0x17 };
    static const uint8_t c1[]   = { 0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x48, 0x83, 0xEC, 0x28, 0x48, 0xB8 };
    static const uint8_t c2[]   = { 0xFF, 0xD0, 0x48, 0x83, 0xC4, 0x28, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59, 0x48, 0x83, 0xEC, 0x28, 0x48, 0xB8 };
    static const uint8_t c3[]   = { 0xFF, 0xD0, 0x48, 0x83, 0xC4, 0x28, 0x50, 0x48, 0x83, 0xEC, 0x20, 0x48, 0xB8 };
    static const uint8_t c4[]   = { 0xFF, 0xD0, 0x48, 0x83, 0xC4, 0x20, 0x58, 0xC3 };
    if (!p) return 0;
    fn = (void *)&pick_hook;
    memcpy(p + n, pre, sizeof(pre)); n += sizeof(pre); memcpy(p + n, &fn, 8); n += 8;
    memcpy(p + n, post, sizeof(post)); n += sizeof(post);
    memcpy(p + n, PICK_SET_ORIG, PICK_SET_LEN); n += PICK_SET_LEN;                    /* 9 bytes */
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0;      /* jmp [rip+0]: 6 bytes */
    memcpy(p + n, &resume, 8); n += 8;                                                   /* jz above skips 9 + 6 + 8 = 0x17 */
    p[n++] = 0xC3;
    n = (n + 15) & ~(size_t)15;
    s2 = p + n;
    fn = (void *)&pick_enter; memcpy(p + n, c1, sizeof(c1)); n += sizeof(c1); memcpy(p + n, &fn, 8); n += 8;
    fn = (void *)PK.chooser;  memcpy(p + n, c2, sizeof(c2)); n += sizeof(c2); memcpy(p + n, &fn, 8); n += 8;
    fn = (void *)&pick_leave; memcpy(p + n, c3, sizeof(c3)); n += sizeof(c3); memcpy(p + n, &fn, 8); n += 8;
    memcpy(p + n, c4, sizeof(c4)); n += sizeof(c4);
    rel = (int32_t)((intptr_t)p - (intptr_t)(PK.settask + PICK_HOOK_LEN));
    PK.jmp_set[0] = 0xE9; memcpy(PK.jmp_set + 1, &rel, 4);
    rel = (int32_t)((intptr_t)s2 - (intptr_t)(PK.callsite + PICK_HOOK_LEN));
    PK.call_new[0] = 0xE8; memcpy(PK.call_new + 1, &rel, 4);
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    PK.stub_set = p; PK.stub_call = s2;
    log_line("PICK: stubs at %p (setTask) and %p (chooser call), %Iu bytes", (void *)p, (void *)s2, n);
    return 1;
}

static void pick_off(const char *why)
{
    char w[160];
    int r1 = 1, r2 = 1;
    if (!PK.avail || !PK.settask) return;
    /* the call first (no new chooser run is noted), then setTask's entry; the hook stays callable until both are out */
    if (PK.stub_call && memcmp(PK.callsite, PK.call_new, PICK_HOOK_LEN) == 0) r2 = write_bytes(PK.callsite, PK.call_new, PK.call_orig, PICK_HOOK_LEN, w, sizeof(w));
    if (r2 != 1) { log_line("PICK: the chooser call could not be restored: %s", w); if (r2 < 0) internal_failure("pick restore failed"); }
    if (PK.stub_set && memcmp(PK.settask, PK.jmp_set, PICK_HOOK_LEN) == 0) r1 = write_bytes(PK.settask, PK.jmp_set, PICK_SET_ORIG, PICK_HOOK_LEN, w, sizeof(w));
    if (r1 != 1) { log_line("PICK: setTask's entry could not be restored: %s", w); if (r1 < 0) internal_failure("pick restore failed"); }
    InterlockedExchange(&PK.enabled, 0); PK.cur = NULL; PK.depth = 0;
    if (strcmp(why, "all patches off") == 0) InterlockedExchange(&PK.n, 0);
    log_line("PICK off (%s): same %u subst %u left %u", why, PK.same, PK.subst, PK.left);
    g_dirty = 1;
}

static void pick_on(void)
{
    char w[160];
    int r;
    g_dirty = 1;
    if (!PK.avail) { PK.bad++; log_line("PICK ON refused: unavailable (%s)", PK.why); return; }
    if (!PK.stub_set && !pick_make_stubs()) { PK.avail = 0; _snprintf(PK.why, sizeof(PK.why), "no free memory near the game module for the stubs"); log_line("PICK ON refused: %s", PK.why); return; }
    PK.thread = GetCurrentThreadId();
    if (pick_bytes_on()) { InterlockedExchange(&PK.enabled, 1); log_line("PICK already on"); return; }
    if (!pick_bytes_off()) { PK.avail = 0; _snprintf(PK.why, sizeof(PK.why), "setTask's entry or the chooser call holds neither its own bytes nor this DLL's"); log_line("PICK ON refused: %s", PK.why); return; }
    PK.cur = NULL; PK.depth = 0; PK.pend = 0;
    InterlockedExchange(&PK.enabled, 1);
    r = write_bytes(PK.settask, PICK_SET_ORIG, PK.jmp_set, PICK_HOOK_LEN, w, sizeof(w));
    if (r == 1) r = write_bytes(PK.callsite, PK.call_orig, PK.call_new, PICK_HOOK_LEN, w, sizeof(w));
    if (r != 1) {
        pick_off("PICK ON failed");
        PK.avail = 0; _snprintf(PK.why, sizeof(PK.why), "%s", w);
        log_line("PICK ON FAILED: %s; item marked unavailable", w);
        if (r < 0) internal_failure("pick hook write failed");
        return;
    }
    log_line("PICK on: setTask %p, chooser call %p, %ld villagers on the list", (void *)PK.settask, (void *)PK.callsite, PK.n);
}

/* PICK SET u:t:tu,...: the whole list. A villager already on it keeps its kept record when its type and target unit stay. */
static void pick_set(const char *list)
{
    static pick_ent tmp[PICK_MAX];
    int k = 0, i;
    const char *s = list;
    g_dirty = 1;
    if (strcmp(list, "-") != 0) {
        while (*s) {
            char *e;
            unsigned long long u, t, tu;
            u = _strtoui64(s, &e, 16);
            if (e == s || *e != ':' || u == 0 || (u & 7) != 0) goto bad;
            s = e + 1; t = _strtoui64(s, &e, 16);
            if (e == s || *e != ':' || t > 255) goto bad;
            s = e + 1; tu = _strtoui64(s, &e, 16);
            if (e == s || (*e != ',' && *e != 0) || (tu & 7) != 0) goto bad;
            if (k >= PICK_MAX) { PK.bad++; log_line("PICK SET refused: more than %d villagers", PICK_MAX); return; }
            memset(&tmp[k], 0, offsetof(pick_ent, kept));
            tmp[k].unit = (uint8_t *)(uintptr_t)u; tmp[k].type = (int)t; tmp[k].tu = (uint64_t)tu;
            {   pick_ent *old = pick_find(tmp[k].unit);
                if (old && old->type == tmp[k].type && old->tu == tmp[k].tu && old->kept_t) { tmp[k].kept_t = old->kept_t; memcpy(tmp[k].kept, old->kept, PICK_REC); }
                else __try {    /* new on the list: its current task, when it is that task, is kept at once */
                    const uint8_t *u8 = tmp[k].unit, *data;
                    int32_t cnt;
                    memcpy(&data, u8 + PICK_TASKS, 8); memcpy(&cnt, u8 + PICK_TASKS + 8, 4);
                    if (cnt > 0 && cnt < 64 && data && pick_match(&tmp[k], data) && !pick_rec_gone(data) && !pick_is_gone((uint64_t)(uintptr_t)tmp[k].unit)) { memcpy(tmp[k].kept, data, PICK_REC); tmp[k].kept_t = GetTickCount64(); PK.seeded++; }
                } __except (EXCEPTION_EXECUTE_HANDLER) { tmp[k].kept_t = 0; } }
            k++;
            s = *e ? e + 1 : e;
        }
    }
    /* the hook runs on this thread only (the game thread, which also ticks this DLL): no hook runs while the list changes */
    InterlockedExchange(&PK.n, 0);
    for (i = 0; i < k; i++) PK.e[i] = tmp[i];
    InterlockedExchange(&PK.n, k);
    if (PK.cur && !pick_find(PK.cur)) PK.cur = NULL;
    PK.sets++;
    return;
bad:
    PK.bad++; log_line("PICK SET refused: '%.40s' is not a list of <unit>:<type>:<target unit> in hex", s);
}

/* PICK GONE a,b,c: see the head of this block */
static void pick_gone(const char *list)
{
    const char *s = list;
    LONG i, j, n;
    g_dirty = 1;
    while (*s) {
        char *e;
        unsigned long long v = _strtoui64(s, &e, 16);
        if (e == s || v == 0 || (*e != ',' && *e != 0)) { PK.bad++; log_line("PICK GONE refused: '%.40s' is not a list of hex addresses", s); return; }
        if (!pick_is_gone(v)) { PK.gone[PK.gonei] = v; PK.gonei = (PK.gonei + 1) % PICK_GONE_MAX; if (PK.ngone < PICK_GONE_MAX) PK.ngone++; }
        s = *e ? e + 1 : e;
    }
    n = PK.n; j = 0;
    InterlockedExchange(&PK.n, 0);
    for (i = 0; i < n; i++) {
        pick_ent *x = &PK.e[i];
        if (pick_is_gone((uint64_t)(uintptr_t)x->unit) || (x->kept_t && pick_rec_gone(x->kept)) || pick_is_gone(x->tu)) { PK.dropped++; continue; }
        if (j != i) PK.e[j] = *x;
        j++;
    }
    InterlockedExchange(&PK.n, j);
    if (PK.cur && !pick_find(PK.cur)) { PK.cur = NULL; PK.pend = 0; }
    PK.gonecmds++;
    log_line("PICK GONE: %ld of %ld entries dropped, %d addresses remembered", n - j, n, PK.ngone);
}

static void pick_cmd(int argc, char **argv)
{
    int v;
    if (argc == 2 && on_off(argv[1], &v)) { if (v) pick_on(); else pick_off("PICK OFF"); return; }
    if (argc == 3 && _stricmp(argv[1], "SET") == 0) {
        if (!PK.avail) { PK.bad++; g_dirty = 1; log_line("PICK SET refused: unavailable (%s)", PK.why); return; }
        pick_set(argv[2]); return;
    }
    if (argc == 3 && _stricmp(argv[1], "GONE") == 0) {     /* round six: works while unavailable too (nothing to drop) */
        pick_gone(argv[2]); return;
    }
    PK.bad++; g_dirty = 1;
    log_line("PICK refused: needs ON, OFF, SET <unit>:<type>:<target unit>,... (or SET -) or GONE <hex>,...");
}

/* ------------------------------------------------------------------ REGSET (lane 35, round six): a region's two building sets
 * (research/2026-11-10-game-probe/lanes/lane_s21_35/report.txt, part 2)
 *
 * Why (READ in the game file and seen in a friend's crash, the lead's run pick_run and this lane's s1on): the job chooser,
 * looking for a building to fetch from, walks two sets of its region (+5A8h, +5F8h; 4e0e480) and reads each member's
 * stock list (+460h; 4d45360). The game takes a building out of those sets in Engine::eraseBuildingReferences (4cb0e40,
 * called by demolish), through the building's region (+2B8h component); with no region there it takes it out of
 * nothing. A member left behind is freed later and the next walk reads freed memory: the friend's game closed with
 * "access violation reading 0xffffffffffffffff / 0x10000000001" in 4d45360, under the chooser.
 *   REGSET LIST <region>          writes regset.txt: one line "<set +5A8|+5F8> <member address>" per member of both
 *                                 sets (walked by its hash chains; no member is read); the region must look like an
 *                                 object of the game (committed, its vtable in the module).
 *   REGSET DROP <region> <hex>,<hex>,...   takes those addresses out of both sets with the game's own set removal (the
 *                                 routine eraseBuildingReferences' helper 4c53480 calls for these two sets, 4c4bb90): it
 *                                 hashes the address and never reads through it, so a freed member can be dropped.
 * Status: "REGSET available lists= members= drops= dropped= bad= faults=" or "REGSET unavailable <why>". */
#define REGSET_A       0x5A8
#define REGSET_B       0x5F8
#define REGSET_MAXMEM  4096
typedef int (*setremove_fn)(void *set, void *key);
static struct { int avail; char why[160]; setremove_fn rm; unsigned lists, members, drops, dropped, bad, faults; } RS;

static int regset_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "REGSET unavailable dll is off\r\n");
    if (!RS.avail) return _snprintf(buf, len, "REGSET unavailable %s\r\n", RS.why);
    return _snprintf(buf, len, "REGSET available lists=%u members=%u drops=%u dropped=%u bad=%u faults=%u\r\n", RS.lists, RS.members, RS.drops, RS.dropped, RS.bad, RS.faults);
}

static int regset_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    memset(&RS, 0, sizeof(RS));
    if (!known) _snprintf(RS.why, sizeof(RS.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_REGSETS].hits != 1) _snprintf(RS.why, sizeof(RS.why), "REGSETS signature has %d hits (need exactly 1)", g_hit[S_REGSETS].hits);
    else {
        const uint8_t *p = g_base + g_hit[S_REGSETS].rva;
        uint64_t t1 = 0, t2 = 0;
        RS.avail = regset_check(p, (uint64_t)(uintptr_t)p, &t1, &t2, RS.why, sizeof(RS.why));
        if (RS.avail && (t1 != t2 || t1 < (uint64_t)(uintptr_t)g_base || t1 >= (uint64_t)(uintptr_t)g_base + g_imgsize)) { RS.avail = 0; _snprintf(RS.why, sizeof(RS.why), "the two set calls do not reach the same routine in the module"); }
        if (RS.avail && memcmp((const void *)(uintptr_t)t1, REGSET_RM_HEAD, sizeof(REGSET_RM_HEAD)) != 0) { RS.avail = 0; _snprintf(RS.why, sizeof(RS.why), "the set removal does not start with its known instructions"); }
        if (RS.avail) RS.rm = (setremove_fn)(void *)(uintptr_t)t1;
    }
    log_line("  REGSET %s %s", RS.avail ? "available" : "unavailable", RS.avail ? "" : RS.why);
    return RS.avail;
}

/* the members of one set (TSet: elements of 16 bytes { key, next index, hash index } at [set+0], their count at +8;
 * the hash at [set+40h] or inline at set+38h when that is null, its size at +48h), by hash chain; -1 ends a chain */
static int regset_walk(const uint8_t *set, uint64_t *out, int max)
{
    const uint8_t *data, *hash;
    int32_t num, hsize, b, n = 0;
    memcpy(&data, set, 8); memcpy(&num, set + 8, 4); memcpy(&hash, set + 0x40, 8); memcpy(&hsize, set + 0x48, 4);
    if (!hash) hash = set + 0x38;
    if (num < 0 || num > 65536 || hsize < 0 || hsize > 65536) return -1;
    if (num == 0) return 0;
    if (!data || !range_readable(data, (size_t)num * 16) || !range_readable(hash, (size_t)(hsize ? hsize : 1) * 4)) return -1;
    for (b = 0; b < hsize; b++) {
        int32_t idx, guard = 0;
        memcpy(&idx, hash + (size_t)b * 4, 4);
        while (idx != -1) {
            if (idx < 0 || idx >= num || ++guard > num) return -1;
            if (n < max) memcpy(&out[n], data + (size_t)idx * 16, 8);
            n++;
            memcpy(&idx, data + (size_t)idx * 16 + 8, 4);
        }
    }
    return n;
}

static int regset_region(const char *arg, uint8_t **region)
{
    unsigned long long a = 0;
    char why[200];
    { char *e; a = _strtoui64(arg, &e, 16); if (e == arg || *e) { RS.bad++; log_line("REGSET refused: '%s' is not a hex address", arg); return 0; } }
    if (!comp_sane(a, REGSET_B + 0x50, why, sizeof(why))) { RS.bad++; log_line("REGSET refused: %s", why); return 0; }
    *region = (uint8_t *)(uintptr_t)a;
    return 1;
}

static void regset_list(const char *arg)
{
    static uint64_t m[REGSET_MAXMEM];
    uint8_t *r;
    wchar_t path[MAX_PATH];
    HANDLE h;
    DWORD wr;
    char line[64];
    int k, s, n;
    if (!regset_region(arg, &r)) return;
    join_path(path, g_dir, L"regset.txt");
    h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) { RS.faults++; log_line("REGSET LIST: cannot write regset.txt (error %lu)", GetLastError()); return; }
    for (s = 0; s < 2; s++) {
        int off = s ? REGSET_B : REGSET_A;
        __try { n = regset_walk(r + off, m, REGSET_MAXMEM); }
        __except (EXCEPTION_EXECUTE_HANDLER) { n = -1; RS.faults++; }
        if (n < 0) { k = _snprintf(line, sizeof(line), "BAD +%X\r\n", off); WriteFile(h, line, (DWORD)k, &wr, NULL); continue; }
        for (k = 0; k < n && k < REGSET_MAXMEM; k++) { int c = _snprintf(line, sizeof(line), "+%X %llX\r\n", off, (unsigned long long)m[k]); WriteFile(h, line, (DWORD)c, &wr, NULL); }
        RS.members += (unsigned)n;
    }
    WriteFile(h, "END\r\n", 5, &wr, NULL);
    CloseHandle(h);
    RS.lists++;
}

static void regset_drop(const char *arg, const char *list)
{
    uint8_t *r;
    const char *s = list;
    int got = 0;
    if (!regset_region(arg, &r)) return;
    while (*s) {
        char *e;
        unsigned long long v = _strtoui64(s, &e, 16);
        if (e == s || v == 0 || (*e != ',' && *e != 0)) { RS.bad++; log_line("REGSET DROP refused: '%.40s' is not a list of hex addresses", s); return; }
        __try { got += RS.rm(r + REGSET_A, (void *)(uintptr_t)v) & 1; got += RS.rm(r + REGSET_B, (void *)(uintptr_t)v) & 1; }
        __except (EXCEPTION_EXECUTE_HANDLER) { RS.faults++; log_line("REGSET DROP: exception %08lX", GetExceptionCode()); return; }
        RS.drops++;
        s = *e ? e + 1 : e;
    }
    RS.dropped += (unsigned)got;
    if (got) log_line("REGSET DROP: %d member(s) taken out of region %p's sets", got, (void *)r);
}

static void regset_cmd(int argc, char **argv)
{
    g_dirty = 1;
    if (!RS.avail) { RS.bad++; log_line("REGSET refused: unavailable (%s)", RS.why); return; }
    if (argc == 3 && _stricmp(argv[1], "LIST") == 0) { regset_list(argv[2]); return; }
    if (argc == 4 && _stricmp(argv[1], "DROP") == 0) { regset_drop(argv[2], argv[3]); return; }
    RS.bad++; log_line("REGSET refused: needs LIST <region> or DROP <region> <hex>,...");
}

/* ------------------------------------------------------------------ FIELD (lane 40): its own file */
#include "coop_fields.h"

/* ------------------------------------------------------------------ MEN (lane 43): its own file */
#include "coop_men.h"

/* ------------------------------------------------------------------ SNAP (lane 47): its own file */
#include "coop_snap.h"
/* ------------------------------------------------------------------ GUIDE (lane 49): its own file */
#include "coop_guide.h"
/* ------------------------------------------------------------------ FELL (lane 54): its own file */
#include "coop_fell.h"

/* ------------------------------------------------------------------ ENDHOLD (lane 49, round four): its own file */
#include "coop_endhold.h"

/* ------------------------------------------------------------------ REPORT (lane 61): the bug report, its own file */
#include "coop_report.h"

/* ------------------------------------------------------------------ DIST (lane 42): a house's market goods on the host's word
 * (research/2026-11-10-game-probe/lanes/lane_s21_42/report.txt)
 * A house's distributedGoods (SMBuildingMaster +E90h: a list of the game's 24-byte goods records) is rebuilt by the
 * region's distribution (4c3c490), which the region's market routine runs whenever a pass over its market list is done
 * (asked for by every stock change of a building: recountStorage, a family moving, a fire). Its input is a pool made from
 * the region's market buildings, which differs on a friend for seconds at a time (measured: a friend's houses showed a
 * list the host had had 5 to 20 s before). So on a friend the routine still runs (its counter, its pool, its second set
 * of buildings), and right after it every house the host named gets the host's list back, in the same call:
 *   DIST ON          the market routine's one call of the distribution (DISTCALL + 15) goes to a stub of this DLL:
 *                    the game's distribution, then the write-back (only the call's four displacement bytes change)
 *   DIST OFF         the original displacement back (also at ALLOFF)
 *   DIST SET <building> <type>:<amount>,...|-    the host's list for that house; written at once when DIST is on and
 *                    the building is the same object (address, object number +0Ch, name +18h) and still has a region
 *   DIST FORGET      every house dropped (a load, a release)
 * A write: the list's length set to 0, then each record appended the way the distribution itself does (length + 1; the
 * game's own grow helper when the room is used up; the record zeroed, type and amount written), +459h = 1, the region's
 * refresh (mode 1, no list) and the building's surplus cache, as the distribution calls them after a change. Nothing is
 * written when the list already equals the host's.
 * Status: "DIST on|off houses=<n> sets=<n> writes=<n> putbacks=<n> calls=<n> otherthread=<n> refused=<n> faults=<n>"
 * or "DIST unavailable <why>". */
#define DG_OFF        0xE90       /* SMBuildingMaster.distributedGoods (reflected): { FGood *data; int num; int max; } */
#define DG_DIRTY_OFF  0x459       /* the distribution sets this byte to 1 when a house's list changed */
#define DG_REGION_OFF 0x2C8       /* SMBuildingMaster.Region (reflected) */
#define DG_MAX        48          /* records per house */
#define DG_SLOTS      1024        /* houses */
typedef void (*dist_fn)(void *region);
typedef void (*dgrow_fn)(garr *list, int32_t oldnum);
typedef void (*dsurp_fn)(void *building);
typedef void (*drefresh_fn)(void *region, void *building, int mode, void *delta, int last);
typedef struct { uint8_t *b; uint32_t idx; uint64_t name; int32_t n; int32_t type[DG_MAX], amt[DG_MAX]; } dg_ent;
static dg_ent g_dg[DG_SLOTS];
static struct {
    int avail; char why[200];
    uint8_t *site, *stub;               /* site = the four displacement bytes of the call */
    uint8_t orig[4], jmp[4];
    dist_fn dist; dgrow_fn grow; dsurp_fn surp; drefresh_fn refresh;
    DWORD thread;
    int n;
    unsigned long long sets, writes, putbacks, calls, otherthread, refused, faults;
} DG;

static int dist_bytes_on(void)  { return DG.stub && DG.site && memcmp(DG.site, DG.jmp, 4) == 0; }
static int dist_bytes_off(void) { return DG.site && memcmp(DG.site, DG.orig, 4) == 0; }

static int dist_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "DIST unavailable dll is off\r\n");
    if (!DG.avail) return _snprintf(buf, len, "DIST unavailable %s\r\n", DG.why);
    return _snprintf(buf, len, "DIST %s houses=%d sets=%llu writes=%llu putbacks=%llu calls=%llu otherthread=%llu refused=%llu faults=%llu\r\n",
                     dist_bytes_on() ? "on" : "off", DG.n, DG.sets, DG.writes, DG.putbacks, DG.calls, DG.otherthread, DG.refused, DG.faults);
}

static int dist_scan(void)
{
    uint64_t grow = 0;
    uint8_t *cs, *gs;
    memset(&DG, 0, sizeof(DG)); memset(g_dg, 0, sizeof(g_dg));
    DG.avail = 1;
    cs = g_base + g_hit[S_DISTCALL].rva; gs = g_base + g_hit[S_DGROW].rva;
    if (!dist_check(g_hit, cs, (uint64_t)(uintptr_t)cs, (uint64_t)(uintptr_t)(g_base + g_hit[S_DIST].rva), gs, (uint64_t)(uintptr_t)gs,
                    (uint64_t)(uintptr_t)g_base, g_imgsize, &grow, DG.why, sizeof(DG.why))) DG.avail = 0;
    else if (memcmp((const void *)(uintptr_t)grow, DGROW_HEAD, sizeof(DGROW_HEAD)) != 0) { DG.avail = 0; _snprintf(DG.why, sizeof(DG.why), "the grow helper does not start with its known instructions"); }
    if (DG.avail) {
        DG.site = cs + DIST_CALL_OFF + 1; memcpy(DG.orig, DG.site, 4);
        DG.dist = (dist_fn)(void *)(g_base + g_hit[S_DIST].rva);
        DG.grow = (dgrow_fn)(void *)(uintptr_t)grow;
        DG.surp = (dsurp_fn)(void *)(g_base + g_hit[S_DGSURP].rva);
        DG.refresh = (drefresh_fn)(void *)(g_base + g_hit[S_REFRESH].rva);
    }
    log_line("  DIST %s %s", DG.avail ? "off" : "unavailable", DG.avail ? "" : DG.why);
    return DG.avail;
}

static int dg_same(const dg_ent *e) { return *(const uint32_t *)(e->b + OBJ_INDEX_OFF) == e->idx && *(const uint64_t *)(e->b + OBJ_NAME_OFF) == e->name; }
/* lane 46: a house being demolished leaves DIST (called by goods_gone) */
static void dist_gone(const uint8_t *b)
{
    int i;
    for (i = 0; i < DG_SLOTS; i++) if (g_dg[i].b == b) { memset(&g_dg[i], 0, sizeof(g_dg[i])); DG.n--; }
}

/* the host's list back into the house; 1 = written, 0 = already equal or not this house any more, -1 = refused */
static int dg_write(dg_ent *e)
{
    garr *a;
    uint8_t *region;
    int i;
    if (!e->b || !range_readable(e->b, DG_OFF + sizeof(garr)) || !dg_same(e)) return 0;
    if (gone_find(e->b)) { GD.distskip++; return 0; }       /* lane 46: a demolished house: its surplus cache (DG.surp) would register it again */
    region = *(uint8_t **)(e->b + DG_REGION_OFF);
    if (!region) return 0;                                   /* taken out of the game (a demolished building has no region) */
    a = (garr *)(e->b + DG_OFF);
    if (!list_sane(a)) { DG.refused++; return -1; }
    if (a->num == e->n) {
        for (i = 0; i < e->n; i++) if (a->data[i].type != e->type[i] || a->data[i].amt != e->amt[i]) break;
        if (i == e->n) return 0;
    }
    a->num = 0;
    for (i = 0; i < e->n; i++) {
        int32_t old = a->num;
        fgood *r;
        a->num = old + 1;
        if (a->num > a->max) DG.grow(a, old);
        r = &a->data[old];
        memset(r, 0, sizeof(*r));
        r->type = e->type[i]; r->amt = e->amt[i];
    }
    e->b[DG_DIRTY_OFF] = 1;
    DG.refresh(region, e->b, 1, NULL, 0);
    DG.surp(e->b);
    DG.writes++;
    return 1;
}

/* the market routine's call lands here (through the stub): the game's distribution, then the host's lists back */
static void __cdecl dist_wrap_wd(void *region)
{
    int i;
    DG.dist(region);
    DG.calls++;
    if (GetCurrentThreadId() != DG.thread) { DG.otherthread++; return; }
    __try {
        for (i = 0; i < DG_SLOTS; i++) {
            dg_ent *e = &g_dg[i];
            if (!e->b) continue;
            if (!range_readable(e->b, DG_OFF + sizeof(garr)) || !dg_same(e)) { memset(e, 0, sizeof(*e)); DG.n--; continue; }
            if (*(uint8_t **)(e->b + DG_REGION_OFF) != (uint8_t *)region) continue;
            if (dg_write(e) == 1) DG.putbacks++;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { DG.faults++; log_line("DIST: the write-back raised exception %08lX", GetExceptionCode()); }
}
static void __cdecl dist_wrap(void *region)   /* lane 51: the watchdog's marks around it */
{
    wd_in(WD_DIST); dist_wrap_wd(region); wd_out(WD_DIST);
}

/* the stub (12 bytes): mov rax,<dist_wrap>; jmp rax (the call's own return address goes back into the market routine) */
static int dist_make_stub(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize);
    void *fn = (void *)&dist_wrap;
    int32_t rel;
    DWORD old;
    if (!p) return 0;
    p[0] = 0x48; p[1] = 0xB8; memcpy(p + 2, &fn, 8); p[10] = 0xFF; p[11] = 0xE0;
    rel = (int32_t)((intptr_t)p - (intptr_t)(DG.site + 4));
    memcpy(DG.jmp, &rel, 4);
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    DG.stub = p;
    log_line("DIST: stub at %p, the call at %p, the distribution at %p, grow %p", (void *)p, (void *)(DG.site - 1), (void *)DG.dist, (void *)DG.grow);
    return 1;
}

static void dist_unhook(void)
{
    char w[160];
    int r;
    if (!DG.avail || !DG.stub || !dist_bytes_on()) return;
    r = write_bytes(DG.site, DG.jmp, DG.orig, 4, w, sizeof(w));
    if (r != 1) { log_line("DIST: the call could not be restored: %s", w); if (r < 0) internal_failure("dist restore failed"); }
    g_dirty = 1;
}

static void dist_on(void)
{
    char w[160];
    int r;
    g_dirty = 1;
    if (!DG.avail) { DG.refused++; log_line("DIST ON refused: unavailable (%s)", DG.why); return; }
    if (!DG.stub && !dist_make_stub()) { DG.avail = 0; _snprintf(DG.why, sizeof(DG.why), "no free memory near the game module for the stub"); log_line("DIST ON refused: %s", DG.why); return; }
    DG.thread = GetCurrentThreadId();
    if (dist_bytes_on()) { log_line("DIST already on"); return; }
    if (!dist_bytes_off()) { DG.avail = 0; _snprintf(DG.why, sizeof(DG.why), "the call holds neither its own displacement nor this DLL's"); log_line("DIST ON refused: %s", DG.why); return; }
    r = write_bytes(DG.site, DG.orig, DG.jmp, 4, w, sizeof(w));
    if (r != 1) {
        DG.avail = 0; _snprintf(DG.why, sizeof(DG.why), "%s", w);
        log_line("DIST ON FAILED: %s; item marked unavailable", w);
        if (r < 0) internal_failure("dist write failed");
        return;
    }
    log_line("DIST on at %p (stub %p)", (void *)(DG.site - 1), (void *)DG.stub);
}

static void dist_off(const char *why)
{
    int was;
    if (!DG.avail || !DG.stub) return;
    was = dist_bytes_on();
    dist_unhook();
    if (was) log_line("DIST off (%s): %llu write-backs, %llu writes", why, DG.putbacks, DG.writes);
}

static void dist_set(const char *bs, const char *list)
{
    unsigned long long a = 0;
    char why[160];
    dg_ent t, *e = NULL;
    int i, free_i = -1;
    memset(&t, 0, sizeof(t));
    if (!parse_u64(bs, &a)) { DG.refused++; log_line("DIST SET refused: needs <building> as 0x<hex>"); return; }
    if (!comp_sane(a, DG_OFF + sizeof(garr), why, sizeof(why))) { DG.refused++; log_line("DIST SET refused: %s", why); return; }
    t.b = (uint8_t *)(uintptr_t)a; t.idx = *(uint32_t *)(t.b + OBJ_INDEX_OFF); t.name = *(uint64_t *)(t.b + OBJ_NAME_OFF);
    if (strcmp(list, "-") != 0) {
        const char *s = list;
        while (*s) {
            char *e1, *e2;
            long ty = strtol(s, &e1, 10), am;
            if (e1 == s || *e1 != ':') goto bad;
            am = strtol(e1 + 1, &e2, 10);
            if (e2 == e1 + 1 || (*e2 != ',' && *e2 != 0)) goto bad;
            if (t.n >= DG_MAX) { DG.refused++; log_line("DIST SET refused: more than %d records", DG_MAX); return; }
            t.type[t.n] = (int32_t)ty; t.amt[t.n] = (int32_t)am; t.n++;
            s = *e2 ? e2 + 1 : e2;
        }
    }
    for (i = 0; i < DG_SLOTS; i++) {
        if (g_dg[i].b == t.b) { e = &g_dg[i]; break; }
        if (!g_dg[i].b && free_i < 0) free_i = i;
    }
    if (!e) {
        if (free_i < 0) { DG.refused++; log_line("DIST SET refused: %d houses named already", DG_SLOTS); return; }
        e = &g_dg[free_i]; DG.n++;
    }
    *e = t;
    DG.sets++;
    if (dist_bytes_on()) {
        __try { dg_write(e); }
        __except (EXCEPTION_EXECUTE_HANDLER) { DG.faults++; log_line("DIST SET(%llX) raised exception %08lX", a, GetExceptionCode()); }
    }
    return;
bad:
    DG.refused++; log_line("DIST SET refused: '%.40s' is not a list of <type>:<amount>", list);
}

static void dist_cmd(int argc, char **argv)
{
    int v;
    g_dirty = 1;
    if (argc == 2 && on_off(argv[1], &v)) { if (v) dist_on(); else dist_off("DIST OFF"); return; }
    if (argc == 2 && _stricmp(argv[1], "FORGET") == 0) { memset(g_dg, 0, sizeof(g_dg)); DG.n = 0; return; }
    if (argc == 4 && _stricmp(argv[1], "SET") == 0) {
        if (!DG.avail) { DG.refused++; log_line("DIST SET refused: unavailable (%s)", DG.why); return; }
        dist_set(argv[2], argv[3]); return;
    }
    DG.refused++;
    log_line("DIST refused: needs ON, OFF, FORGET or SET <building 0x hex> <type>:<amount>,...|-");
}

/* ------------------------------------------------------------------ commands */
static int split(char *s, char **argv, int max)
{
    int n = 0;
    while (*s && n < max) {
        while (*s == ' ' || *s == '\t') s++;
        if (!*s) break;
        argv[n++] = s;
        while (*s && *s != ' ' && *s != '\t') s++;
        if (*s) *s++ = 0;
    }
    return n;
}

static int on_off(const char *w, int *v)
{
    if (w && _stricmp(w, "ON") == 0) { *v = 1; return 1; }
    if (w && _stricmp(w, "OFF") == 0) { *v = 0; return 1; }
    return 0;
}

static void command(char *line)
{
    char *argv[8];
    int argc, v;
    trim(line);
    if (!line[0] || line[0] == '#') return;
    /* lane 40: FIELD POLL / SET / CHECK come several times a second: counted in the status, not logged one by one */
    if (!(_strnicmp(line, "FIELD POLL", 10) == 0 || _strnicmp(line, "FIELD SET ", 10) == 0 || _strnicmp(line, "FIELD CHECK ", 12) == 0 ||
          _strnicmp(line, "MEN POLL", 8) == 0 || _strnicmp(line, "MEN SET ", 8) == 0 || _strnicmp(line, "MEN WAYS ", 9) == 0)     /* lane 43: several times a second */
        && !snap_quiet_cmd(line) && !co_quiet_cmd(line))                                          /* lane 45: TOTALS SET, DIST SET, REGSET LIST */
        log_line("command: %.160s%s", line, strlen(line) > 160 ? " ..." : "");     /* a TOTALS SET line is long */
    argc = split(line, argv, 8);
    if (argc == 0) return;
    if (_stricmp(argv[0], "STATUS") == 0) { g_dirty = 1; co_forget_status(); return; }
    if (_stricmp(argv[0], "COST") == 0) { cost_cmd(); return; }          /* lane 45: cost.txt */
    if (_stricmp(argv[0], "REPORT") == 0) { report_cmd(argc, argv); return; }    /* lane 61: also when the DLL is off */
    if (g_off) { log_line("ignored: the DLL is off (%s)", g_off_reason); g_dirty = 1; return; }
    if (_stricmp(argv[0], "NOKILL") == 0 && argc == 2 && on_off(argv[1], &v)) { set_site(S_P1, v); return; }
    if (_stricmp(argv[0], "NOROUT") == 0 && argc == 2 && on_off(argv[1], &v)) { set_site(S_P2, v); return; }
    if (_stricmp(argv[0], "NOREFORM") == 0 && argc == 2 && on_off(argv[1], &v)) {
        /* both or neither: when one of the two cannot be switched, neither is */
        if (g_site[S_P3A].state == ST_UNAVAILABLE || g_site[S_P3B].state == ST_UNAVAILABLE) {
            log_line("NOREFORM refused: P3a %s, P3b %s (both are needed)", state_word(g_site[S_P3A].state), state_word(g_site[S_P3B].state));
            g_dirty = 1;
            return;
        }
        set_site(S_P3A, v);
        set_site(S_P3B, v);
        if (g_site[S_P3A].state != g_site[S_P3B].state) {     /* one write failed: put the other back */
            log_line("NOREFORM: P3a and P3b differ after the write; restoring both");
            if (g_site[S_P3A].state == ST_ON) set_site(S_P3A, 0);
            if (g_site[S_P3B].state == ST_ON) set_site(S_P3B, 0);
        }
        return;
    }
    if (_stricmp(argv[0], "NOFINISH") == 0 && argc == 2 && on_off(argv[1], &v)) {
        /* both or neither, as NOREFORM: with only one of the two calls jumped over a friend's building could still finish by itself */
        if (g_site[S_NF1].state == ST_UNAVAILABLE || g_site[S_NF2].state == ST_UNAVAILABLE) {
            log_line("NOFINISH refused: NF1 %s, NF2 %s (both are needed)", state_word(g_site[S_NF1].state), state_word(g_site[S_NF2].state));
            g_dirty = 1;
            return;
        }
        set_site(S_NF1, v);
        set_site(S_NF2, v);
        if (g_site[S_NF1].state != g_site[S_NF2].state) {     /* one write failed: put the other back */
            log_line("NOFINISH: NF1 and NF2 differ after the write; restoring both");
            if (g_site[S_NF1].state == ST_ON) set_site(S_NF1, 0);
            if (g_site[S_NF2].state == ST_ON) set_site(S_NF2, 0);
        }
        return;
    }
    /* lane 19: JOBGATE ON|OFF (site JG): given tasks start on a friend's copy while the job list is full */
    if (_stricmp(argv[0], "JOBGATE") == 0 && argc == 2 && on_off(argv[1], &v)) { set_site(S_JG, v); return; }
    /* lane 23: CHOOSE ON|OFF, CHOOSE SET <hex address>,<hex address>,... | CHOOSE SET - (the job chooser, per villager) */
    if (_stricmp(argv[0], "CHOOSE") == 0) { choose_cmd(argc, argv); return; }
    /* the lead: NOREGION ON|OFF (a work hit at a building without a region no longer reads through null) */
    if (_stricmp(argv[0], "NOREGION") == 0) { noregion_cmd(argc, argv); return; }
    /* lane 35: PICK ON|OFF, PICK SET <unit>:<type>:<target unit>,... | PICK SET - (the chooser's pick held to one task) */
    if (_stricmp(argv[0], "PICK") == 0) { pick_cmd(argc, argv); return; }
    /* lane 40: FIELD ... (a field's plants on the host's word) */
    if (_stricmp(argv[0], "FIELD") == 0) { field_cmd(argc, argv); return; }
    /* lane 42: DIST ON|OFF|FORGET, DIST SET <building> <type>:<amount>,...|- (a house's market goods on the host's word) */
    if (_stricmp(argv[0], "DIST") == 0) { dist_cmd(argc, argv); return; }
    /* lane 35, round six: REGSET LIST <region> | REGSET DROP <region> <hex>,... (a region's two building sets) */
    if (_stricmp(argv[0], "REGSET") == 0) { regset_cmd(argc, argv); return; }
    /* lane 43: MEN HOOK ON|OFF, SET, WATCH, UNWATCH, POLL, DROP, FORGET (a squad's man walks to the host's man's place) */
    if (_stricmp(argv[0], "MEN") == 0) { men_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "SNAP") == 0) { snap_cmd(argc, argv); return; }      /* lane 47 */
    /* lane 49: GUIDE LIST | SET <ox> <leader> [<u>,...] | CLEAR <gone>,... <u>,... (who guides which ox, +330h) */
    if (_stricmp(argv[0], "GUIDE") == 0) { guide_cmd(argc, argv); return; }
    /* lane 54: FELL <region> <x> <y> (the tree being felled at that place falls at this copy's next stroke) */
    if (_stricmp(argv[0], "FELL") == 0) { fell_cmd(argc, argv); return; }
    /* lane 49, round four: ENDHOLD ON|OFF | SET <ceiling ms> <unit>:<type>:<building>,... | RANGE <lo> <hi> */
    if (_stricmp(argv[0], "ENDHOLD") == 0) { endhold_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "ROUT") == 0) { do_call(0, argc, argv); return; }
    if (_stricmp(argv[0], "REFORM") == 0) { do_call(1, argc, argv); return; }
    if (_stricmp(argv[0], "FINISH") == 0) { do_call(2, argc, argv); return; }
    if (_stricmp(argv[0], "BURN") == 0) { do_call(3, argc, argv); return; }
    if (_stricmp(argv[0], "FIREOUT") == 0) { do_call(4, argc, argv); return; }
    if (_stricmp(argv[0], "GOODS") == 0 && argc >= 2) {
        /* GOODS ON [address of the player's lord] | OFF | AUDIT | STATS */
        if (_stricmp(argv[1], "ON") == 0 && argc <= 3) {
            unsigned long long pawn = 0;
            if (argc == 3 && !parse_u64(argv[2], &pawn)) { log_line("GOODS ON refused: '%s' is not a number", argv[2]); g_dirty = 1; return; }
            goods_on(pawn);
            return;
        }
        if (_stricmp(argv[1], "OFF") == 0 && argc == 2) { goods_off("GOODS OFF"); return; }
        if (_stricmp(argv[1], "AUDIT") == 0 && argc == 2) { goods_audit(); return; }
        if (_stricmp(argv[1], "STATS") == 0 && argc == 2) { goods_stats(); g_dirty = 1; return; }
        /* lane 46: GOODS GONE <addr>,... (a DEMOLISH, before the game removes it); GOODS DEMRULE OFF|ON (test switch) */
        if (_stricmp(argv[1], "GONE") == 0 && argc == 3) { goods_gone_cmd(argv[2]); return; }
        if (_stricmp(argv[1], "DEMRULE") == 0 && argc == 3) { GD.rule_off = _stricmp(argv[2], "OFF") == 0; log_line("GOODS DEMRULE %s", GD.rule_off ? "OFF (test)" : "ON"); g_dirty = 1; return; }
    }
    if (_stricmp(argv[0], "PILEGONE") == 0) { goods_pilegone(argc, argv); return; }
    if (_stricmp(argv[0], "TOTALS") == 0 && argc >= 2) {
        /* lane 22: TOTALS ON | OFF | FORGET | SET <region> <good>=<amount>,... | AUDIT | DUMP */
        if (_stricmp(argv[1], "ON") == 0 && argc == 2) { totals_on(); return; }
        if (_stricmp(argv[1], "OFF") == 0 && argc == 2) { totals_drop(1, "TOTALS OFF"); return; }
        if (_stricmp(argv[1], "FORGET") == 0 && argc == 2) { totals_drop(0, "TOTALS FORGET"); return; }
        if (_stricmp(argv[1], "SET") == 0) { totals_set(argc, argv, 0); return; }
        if (_stricmp(argv[1], "SETR") == 0) { totals_set(argc, argv, 1); return; }
        if (_stricmp(argv[1], "AUDIT") == 0 && argc == 2) { totals_audit(); return; }
        if (_stricmp(argv[1], "DUMP") == 0 && argc == 2) { totals_dump(); return; }
    }
    if (_stricmp(argv[0], "HOLD") == 0 && argc >= 2) {
        /* lane 31: HOLD ON | OFF | FORGET | SET <region> | ROWS <region> A|O|M <rows> | PROB <region> <problems> | DUMP */
        if (_stricmp(argv[1], "ON") == 0 && argc == 2) { hold_on(); return; }
        if (_stricmp(argv[1], "OFF") == 0 && argc == 2) { hold_drop(1, "HOLD OFF"); return; }
        if (_stricmp(argv[1], "FORGET") == 0 && argc == 2) { hold_drop(0, "HOLD FORGET"); return; }
        if (_stricmp(argv[1], "SET") == 0) { hold_set(argc, argv); return; }
        if (_stricmp(argv[1], "ROWS") == 0) { hold_rows(argc, argv); return; }
        if (_stricmp(argv[1], "PROB") == 0) { hold_prob(argc, argv); return; }
        if (_stricmp(argv[1], "DUMP") == 0 && argc == 2) { hold_dump(); return; }
    }
    if (_stricmp(argv[0], "CURSOR") == 0) { cursor_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "INPUT") == 0) { input_cmd(argc, argv); return; }
    /* lane 28: WALL, TOOL, WALLGET, ORDERAT, PATH, PATHGET, PATHPT, ORDERHOOK ON | OFF */
    if (_stricmp(argv[0], "WALL") == 0) { wall_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "TOOL") == 0) { tool_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "WALLGET") == 0) { wallget_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "ORDERAT") == 0) { orderat_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "PATH") == 0) { path_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "PATHGET") == 0) { pathget_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "PATHPT") == 0) { pathpt_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "ORDERHOOK") == 0 && argc == 2 && on_off(argv[1], &v)) { if (v) order_hook_on(); else order_unhook("ORDERHOOK OFF"); return; }
    /* lane 32: GATESET, UNCAMP */
    if (_stricmp(argv[0], "GATESET") == 0) { gateset_cmd(argc, argv); return; }
    /* lane 53: WALLSET */
    if (_stricmp(argv[0], "WALLSET") == 0) { wallset_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "UNCAMP") == 0) { uncamp_cmd(argc, argv); return; }
    if (_stricmp(argv[0], "ALLOFF") == 0) { restore_all(); log_line("all patches off"); return; }
#ifdef COOP_PATCH_TEST
    if (_stricmp(argv[0], "TESTFAULT") == 0) { RaiseException(0xE0C0FFEEu, 0, 0, NULL); return; }
#endif
    log_line("unknown command ignored");
}

/* tail patch_cmd.txt by byte offset; only complete lines are consumed; a shrunk file is read again from 0 */
static void poll_commands(void)
{
    WIN32_FILE_ATTRIBUTE_DATA fa;
    ULONGLONG size;
    HANDLE h;
    LARGE_INTEGER pos;
    static char buf[READ_CHUNK + 1];
    DWORD got = 0, want, i, start = 0;
    if (!GetFileAttributesExW(g_cmd_path, GetFileExInfoStandard, &fa)) { if (g_cmd_off) g_cmd_off = 0; return; }
    size = ((ULONGLONG)fa.nFileSizeHigh << 32) | fa.nFileSizeLow;
    if (size < g_cmd_off) { log_line("patch_cmd.txt shrank (%llu < %llu): reading from the start", size, g_cmd_off); g_cmd_off = 0; }
    if (size == g_cmd_off) return;
    h = CreateFileW(g_cmd_path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    pos.QuadPart = (LONGLONG)g_cmd_off;
    want = (DWORD)((size - g_cmd_off) > READ_CHUNK ? READ_CHUNK : (size - g_cmd_off));
    if (!SetFilePointerEx(h, pos, NULL, FILE_BEGIN) || !ReadFile(h, buf, want, &got, NULL)) { CloseHandle(h); return; }
    CloseHandle(h);
    for (i = 0; i < got; i++) {
        if (buf[i] == '\n') {
            char line[MAX_LINE];
            DWORD n = i - start;
            int ok = n < MAX_LINE;
            if (ok) { memcpy(line, buf + start, n); line[n] = 0; }
            /* consumed BEFORE it runs: a command that raises is never read again */
            g_cmd_off += (ULONGLONG)(i + 1 - start);
            start = i + 1;
            if (ok) command(line); else log_line("command line of %lu bytes ignored (too long)", n);
        }
    }
    if (start == 0 && got == READ_CHUNK) {     /* a whole chunk without a newline: skip it */
        log_line("patch_cmd.txt: %lu bytes without a newline skipped", got);
        g_cmd_off += got;
    }
    /* a partial last line (no newline yet) stays for the next tick */
}

/* ------------------------------------------------------------------ first tick (safety rule 1) */
static void init(void)
{
    HMODULE pinned = NULL;
    WIN32_FILE_ATTRIBUTE_DATA fa;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN, (LPCWSTR)(void *)&init, &pinned);
    resolve_dir();
    report_dirs();                             /* lane 61: link, link\sessions, link\reports in the mod folder */
    log_line("coop_patch %s starting in process %lu, folder %ls", COOP_PATCH_VERSION, GetCurrentProcessId(), g_dir);
    /* a command file left by an earlier run may hold old addresses: start at its current end */
    g_cmd_off = 0;
    if (GetFileAttributesExW(g_cmd_path, GetFileExInfoStandard, &fa)) g_cmd_off = ((ULONGLONG)fa.nFileSizeHigh << 32) | fa.nFileSizeLow;
    if (g_cmd_off) log_line("patch_cmd.txt already holds %llu bytes from before: skipped", g_cmd_off);
    scan_module();
    g_dirty = 1;
}

static void tick_body(void)
{
    if (!g_inited) { g_inited = 1; init(); }
    if (g_scan_busy) return;                   /* lane 47: the scan's thread is still reading .text */
    if (!g_scan_done) { g_scan_done = 1; scan_end(); g_dirty = 1; }
    goods_tick();           /* what the hooks left for the tick (before the commands: a write of the mod comes after) */
    order_tick();           /* lane 28: the orders the hook noted */
    totals_tick();
    hold_tick();
    {   unsigned long long co0 = co_now(); poll_commands(); co_add(CO_POLL, co0); }   /* lane 45 */
    report_tick();          /* lane 61: a finished bug report */
    field_tick();           /* lane 40: queued plant drawings, audits */
    men_tick();             /* lane 43: a faulted hook taken out */
    goods_tick();           /* and what an audit or a command of this tick left */
    totals_tick();
    hold_tick();
}

__declspec(dllexport) int __cdecl coop_patch_tick(void *L)
{
    (void)L;                                    /* never touched: UE4SS.dll does not export the Lua C API */
    unsigned long long co0;
    wd_frame();                                 /* lane 51: a gap over 1 s since the last call is written down */
    if (g_in_tick) return 0;
    g_in_tick = 1;
    co0 = co_now();                                       /* lane 45: the whole tick */
    wd_in(WD_TICK);
    __try {
        tick_body();
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        DWORD code = GetExceptionCode();
        __try {
            char what[64];
            _snprintf(what, sizeof(what), "exception %08lX in tick", code);
            internal_failure(what);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            g_off = 1;
        }
    }
    if (g_dirty) {
        int done = 1;
        __try { done = write_status(); } __except (EXCEPTION_EXECUTE_HANDLER) { (void)0; }
        if (done) g_dirty = 0;               /* lane 45: a status with only new counters waits (at most a second) */
    }
    co_add(CO_TICK, co0);
    wd_out(WD_TICK);
    g_in_tick = 0;
    return 0;
}

/* lane 47: the snapshot tables and the crash guard only (coop_snap.h), called by the mod at the very start of each
 * frame, before any of its modules (coop_snap.lua): every module of the frame then sees this frame's values, while the
 * commands keep their place in coop_patch_tick. Nothing happens before the first tick of coop_patch_tick and its scan. */
__declspec(dllexport) int __cdecl coop_snap_tick(void *L)
{
    unsigned long long co0;
    (void)L;
    wd_frame();                                 /* lane 51 */
    if (g_in_tick || !g_inited || g_scan_busy || !g_scan_done || g_off) return 0;
    g_in_tick = 1;
    co0 = co_now();
    wd_in(WD_SNAP);
    __try { snap_guard_tick(); snap_tick(); } __except (EXCEPTION_EXECUTE_HANDLER) { SN.faults++; }
    wd_out(WD_SNAP);
    co_add(CO_TICK, co0);
    g_in_tick = 0;
    return 0;
}

/* lane 47, round two: the crash guard alone (every frame; the tables run in coop_snap_tick at a lower rate) */
__declspec(dllexport) int __cdecl coop_guard_tick(void *L)
{
    (void)L;
    wd_frame();                                 /* lane 51 */
    if (g_in_tick || !g_inited || g_scan_busy || !g_scan_done || g_off) return 0;
    g_in_tick = 1;
    wd_in(WD_GUARD);
    __try { snap_guard_tick(); } __except (EXCEPTION_EXECUTE_HANDLER) { SN.faults++; }
    wd_out(WD_GUARD);
    g_in_tick = 0;
    return 0;
}

#ifdef COOP_PATCH_TEST
/* test build only: scan `base` (a synthetic module) instead of the game; resets all state, next tick starts over */
__declspec(dllexport) void __cdecl coop_patch_test_use_module(void *base)
{
    g_test_base = (uint8_t *)base;
    InterlockedExchange(&G.enabled, 0); memset(&G, 0, sizeof(G));      /* hooks left in an earlier module pass through */
    InterlockedExchange(&T.enabled, 0); memset(&T, 0, sizeof(T));
    InterlockedExchange(&O.enabled, 0); memset(&O, 0, sizeof(O));      /* lane 28 */
    InterlockedExchange(&H.enabled, 0); memset(&H, 0, sizeof(H));
    InterlockedExchange(&FL.enabled, 0); memset(&FL, 0, sizeof(FL));      /* lane 40 */
    g_inited = 0; g_off = 0; g_off_reason[0] = 0; g_failures = 0; g_cmd_off = 0; g_dirty = 0;
    memset(g_calls_n, 0, sizeof(g_calls_n)); g_calls_failed = 0;
    memset(g_site, 0, sizeof(g_site)); memset(g_hit, 0, sizeof(g_hit)); memset(g_call_ok, 0, sizeof(g_call_ok));
    g_base = NULL; g_text = NULL; g_text_len = 0;
}
#endif

/* report 6 / safety rule 6: nothing risky at load or unload; the process may be ending */
BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(inst);
    return TRUE;
}
