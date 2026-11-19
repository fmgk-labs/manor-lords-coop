/* coop_cost.h - lane 45 (COST): what the native piece's own tick costs, and two cuts in writing the status file.
 * Included once by coop_patch.c, before its first use (above write_status); everything here is this lane's block.
 * Evidence: research\2026-11-10-game-probe\lanes\lane_s21_45\report.txt.
 *
 * Counters (QueryPerformanceCounter, microseconds), per part of the tick: the whole tick, the command poll (the
 * commands themselves run inside it), the status writes, the log lines; and how many of each.
 *   COST           cost.txt = one line "cost <part> n=<calls> us=<microseconds in all> max=<longest>" per part
 * The status file:
 *   - is written only when its text changed since the last write;
 *   - when only numbers changed (counters), at most once a second (sitting a1: 1,889 writes in 5 minutes on a friend,
 *     1.5 ms each; an item's word that changes, "on" / "off", and the answer to a command are written at once, as
 *     before; only the frequent quiet commands below and the hooks' counters wait);
 *   - is replaced without MOVEFILE_WRITE_THROUGH (that flag waits for the disk on every write; the readers are on the
 *     same PC and read the file through the system's cache, so nothing waits for the disk any more).
 * Nothing of the game is read or written here. */
enum { CO_TICK, CO_POLL, CO_STATUS, CO_SKIP, CO_LOG, CO_N };
static const char *CO_NAME[CO_N] = { "tick", "commands", "status_written", "status_same", "log_lines" };
static struct { unsigned n; unsigned long long us, max; } g_co[CO_N];
static LARGE_INTEGER g_co_f;
static char g_status_last[16384];        /* lane 71 (merge 0.2.5): was 4096; the status passes it with the 0.2.5 items (4.1-4.2 KB
                                         * in the tests): over it the copy was never kept, so "the same text" never matched */
static int  g_status_last_n = -1;

static unsigned long long co_now(void)
{
    LARGE_INTEGER t;
    if (!g_co_f.QuadPart) QueryPerformanceFrequency(&g_co_f);
    QueryPerformanceCounter(&t);
    return g_co_f.QuadPart ? (unsigned long long)(t.QuadPart * 1000000.0 / (double)g_co_f.QuadPart) : 0;
}
static void co_add(int k, unsigned long long t0)
{
    unsigned long long d = co_now() - t0;
    g_co[k].n++; g_co[k].us += d; if (d > g_co[k].max) g_co[k].max = d;
}
/* The text without its digits: what changes when an item goes on or off (its words), not when a counter moves. */
static char g_sig_last[16384];           /* lane 71: was 4096; past it a cut signature would hide a change in the last
                                         * items' words and put the write off (not yet reached: 3.8 KB without digits) */
static int  g_sig_last_n = -1;
static ULONGLONG g_status_last_ms;
static int co_sig(const char *buf, int n, char *out, int cap)
{
    int i, k = 0;
    for (i = 0; i < n && k < cap; i++) if (buf[i] < '0' || buf[i] > '9') out[k++] = buf[i];
    return k;
}
/* 1 when buf[0..n) is the text written last time (then it is not written again) */
static int co_status_same(const char *buf, int n)
{
    return n == g_status_last_n && n > 0 && memcmp(buf, g_status_last, (size_t)n) == 0;
}
/* 1 when only numbers changed since the last write and that write is less than a second old: written later (the
 * caller keeps the status dirty). An item's state word that changed is written at once. The test build writes at
 * once always (its checks read counters right after a command). */
static int g_co_force;                      /* a command ran (not a quiet one): its answer is written at once */
static int co_status_defer(const char *buf, int n)
{
    static char sig[16384];                 /* (the game thread only) */
    int k;
    if (g_co_force) return 0;
    k = co_sig(buf, n, sig, (int)sizeof(sig));
    return g_sig_last_n == k && memcmp(sig, g_sig_last, (size_t)k) == 0 && GetTickCount64() - g_status_last_ms < 1000;
}
static void co_status_written(const char *buf, int n)
{
    g_co_force = 0;
    if (n > 0 && n <= (int)sizeof(g_status_last)) { memcpy(g_status_last, buf, (size_t)n); g_status_last_n = n; } else g_status_last_n = -1;
    g_sig_last_n = co_sig(buf, n, g_sig_last, (int)sizeof(g_sig_last));
    g_status_last_ms = GetTickCount64();
}
static void co_forget_status(void) { g_status_last_n = -1; g_sig_last_n = -1; }   /* the next status is written whatever it holds */
/* lane 45: commands that come several times a second and are not logged one by one (TOTALS SET / SETR: the host's
 * totals of a region, every second or so; DIST SET: a house's market goods; REGSET LIST: the region-set audit); they
 * are counted in cost.txt ("quiet_commands") */
static unsigned g_co_quiet;
static int co_quiet_cmd(const char *line)
{
    if (_strnicmp(line, "DIST SET ", 9) == 0) { g_co_quiet++; g_co_force = 1; return 1; }   /* its answer at once (lane 42's checks read it) */
    if (_strnicmp(line, "TOTALS SET", 10) == 0 || _strnicmp(line, "REGSET LIST ", 12) == 0) { g_co_quiet++; return 1; }
    /* (lane 65) logged like any command, but their answer is only counters in the status (no item's word changes):
     * it waits like the quiet ones (at most a second). A friend's live log: about 3 of these a second (ENDHOLD SET,
     * MEN DROP, ...), each a new status file (an open, a replace, and the mod's next read a new file to scan). No Lua
     * code reads the status right after them (it reads it again at once only after ON / OFF, whose word changes).
     * The test build writes their answer at once, as before (its checks read the counters right after a command). */
#ifndef COOP_PATCH_TEST
    if (_strnicmp(line, "ENDHOLD SET ", 12) == 0 || _strnicmp(line, "MEN DROP ", 9) == 0 || _strnicmp(line, "PICK SET ", 9) == 0 ||
        _strnicmp(line, "CHOOSE SET ", 11) == 0 || _strnicmp(line, "HOLD ROWS ", 10) == 0 || _stricmp(line, "GOODS AUDIT") == 0 ||
        _stricmp(line, "TOTALS AUDIT") == 0) return 0;
#endif
    g_co_force = 1;
    return 0;
}
static void cost_cmd(void)
{
    wchar_t path[MAX_PATH];
    FILE *f;
    int k;
    join_path(path, g_dir, L"cost.txt");
    f = _wfopen(path, L"wb");
    if (!f) return;
    for (k = 0; k < CO_N; k++) fprintf(f, "cost %s n=%u us=%llu max=%llu\r\n", CO_NAME[k], g_co[k].n, g_co[k].us, g_co[k].max);
    fprintf(f, "cost quiet_commands n=%u\r\n", g_co_quiet);
    fclose(f);
}
