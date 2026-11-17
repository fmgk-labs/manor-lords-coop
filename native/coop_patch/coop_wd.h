/* coop_wd.h - lane 51: the frame watchdog. Always on; a few stores and two system calls per call of the mod.
 * Included once by coop_patch.c, after log_line and before the first hook.
 *
 * Why: in session l51f2 a friend copy's game thread was silent for 9 s (13 numbers 2.7 to 10.2 s late, the host told
 * "friend1 left the game"); l51c2 had 5.9 s. Nothing said whose time it was. Now:
 *   - every hook of this DLL and every export marks "entered" and "left" (which item, when; the game thread only;
 *     a hook that calls the game's own function inside, DIST / FIELD / MEN / PICK, counts that call as its time);
 *   - each export call on the game thread (coop_patch_tick, coop_snap_tick, coop_guard_tick: the mod calls one of them
 *     several times a frame) looks at the time since the last one. Over 1 s: one log line "STALL ..." with
 *       the gap; the game thread's CPU time in it (near the gap: the thread was computing, the game's own code or a
 *       hook; far below: it waited, on the disk, on paging, on a lock, or on another thread such as the render
 *       thread); the whole process's CPU time in it (other threads); the page faults in it (soft and hard) and the
 *       PC's free memory; the item last entered and the item last left (how long before the end of the gap); the
 *       longest item in the gap.
 * The Lua side writes its own line for the same gap ("watchdog: frame gap" in the mod's log).
 * Nothing of the game is read or written here. */
#include <psapi.h>

enum { WD_TICK, WD_SNAP, WD_GUARD, WD_GREC, WD_GREF, WD_TOT, WD_HGATE, WD_HWMON, WD_ORDER, WD_PICK, WD_PICKC, WD_DIST,
       WD_FIELD, WD_MEN, WD_N };
static const char *WD_NAME[WD_N] = { "tick", "snap tick", "guard tick", "GOODS recount hook", "GOODS refresh hook",
    "TOTALS hook", "HOLD hook", "HOLD wealth hook", "ORDER hook", "PICK hook", "PICK chooser (the game's call)",
    "DIST hook (with the game's call)", "FIELD hook (with the game's call)", "MEN hook (with the game's call)" };
static struct {
    DWORD tid;                               /* the game thread: the thread of the first export call */
    int in_id, out_id, max_id, depth;
    unsigned long long t_in, t_out, max_us, prev, st[8];
    unsigned long long cpu_prev, pcpu_prev, pf_t;   /* thread / process CPU (100 ns) at prev; time of the fault sample */
    DWORD pf_prev;
    unsigned n;
    unsigned long long gap_max;
} WD = { 0, -1, -1, -1, 0 };

static unsigned long long wd_ft(FILETIME f) { return ((unsigned long long)f.dwHighDateTime << 32) | f.dwLowDateTime; }
static unsigned long long wd_cpu(void)
{
    FILETIME c, e, k, u;
    if (!GetThreadTimes(GetCurrentThread(), &c, &e, &k, &u)) return 0;
    return wd_ft(k) + wd_ft(u);
}
static unsigned long long wd_pcpu(void)
{
    FILETIME c, e, k, u;
    if (!GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u)) return 0;
    return wd_ft(k) + wd_ft(u);
}
static void wd_in(int id)
{
    if (!WD.tid || GetCurrentThreadId() != WD.tid) return;
    WD.in_id = id; WD.t_in = co_now();
    if (WD.depth < 8) WD.st[WD.depth] = WD.t_in;
    WD.depth++;
}
static void wd_out(int id)
{
    unsigned long long t;
    if (!WD.tid || GetCurrentThreadId() != WD.tid) return;
    t = co_now();
    if (WD.depth > 0) {
        WD.depth--;
        if (WD.depth < 8) { unsigned long long d = t - WD.st[WD.depth]; if (d > WD.max_us) { WD.max_us = d; WD.max_id = id; } }
    }
    WD.out_id = id; WD.t_out = t;
}
static const char *wd_name(int id) { return id >= 0 && id < WD_N ? WD_NAME[id] : "none"; }
static void wd_report(unsigned long long t)
{
    unsigned long long gap = t - WD.prev, cpu = wd_cpu(), pcpu = wd_pcpu();
    unsigned long long dc = cpu > WD.cpu_prev ? (cpu - WD.cpu_prev) / 10 : 0, dp = pcpu > WD.pcpu_prev ? (pcpu - WD.pcpu_prev) / 10 : 0;
    PROCESS_MEMORY_COUNTERS m;
    MEMORYSTATUSEX ms;
    DWORD pf = 0; unsigned long long ws = 0, cm = 0;
    memset(&m, 0, sizeof(m)); m.cb = sizeof(m);
    if (K32GetProcessMemoryInfo(GetCurrentProcess(), &m, sizeof(m))) { pf = m.PageFaultCount - WD.pf_prev; ws = m.WorkingSetSize; cm = m.PagefileUsage; }
    memset(&ms, 0, sizeof(ms)); ms.dwLength = sizeof(ms); GlobalMemoryStatusEx(&ms);
    WD.n++; if (gap > WD.gap_max) WD.gap_max = gap;
    log_line("STALL %llu ms between two calls of the mod on the game thread (%u so far, longest %llu ms) | game thread CPU "
             "in it %llu ms, whole process %llu ms | page faults %lu (from %llu ms before it) | working set %llu MB, "
             "commit %llu MB, PC free %llu of %llu MB (load %lu %%) | last entered %s %lld ms before its end, last left %s "
             "%lld ms before its end, inside %d | longest item in it %s %llu ms",
             gap / 1000, WD.n, WD.gap_max / 1000, dc / 1000, dp / 1000, (unsigned long)pf, WD.pf_t ? (t - WD.pf_t) / 1000 : 0,
             ws >> 20, cm >> 20, (unsigned long long)(ms.ullAvailPhys >> 20), (unsigned long long)(ms.ullTotalPhys >> 20),
             (unsigned long)ms.dwMemoryLoad, wd_name(WD.in_id), WD.t_in ? (long long)(t - WD.t_in) / 1000 : -1LL,
             wd_name(WD.out_id), WD.t_out ? (long long)(t - WD.t_out) / 1000 : -1LL, WD.depth,
             wd_name(WD.max_id), WD.max_us / 1000);
}
/* at the start of each export call on the game thread */
static void wd_frame(void)
{
    unsigned long long t = co_now();
    if (!WD.tid) WD.tid = GetCurrentThreadId();
    if (GetCurrentThreadId() != WD.tid) return;
    if (WD.prev && t - WD.prev > 1000000ULL) wd_report(t);
    WD.prev = t; WD.cpu_prev = wd_cpu(); WD.pcpu_prev = wd_pcpu(); WD.max_us = 0; WD.max_id = -1;
    if (!WD.pf_t || t - WD.pf_t > 200000ULL) {
        PROCESS_MEMORY_COUNTERS m;
        memset(&m, 0, sizeof(m)); m.cb = sizeof(m);
        if (K32GetProcessMemoryInfo(GetCurrentProcess(), &m, sizeof(m))) WD.pf_prev = m.PageFaultCount;
        WD.pf_t = t;
    }
}
