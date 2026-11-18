/* ------------------------------------------------------------------ NOLOG (lane 66): a friend's game adds no notice of its own
 * Included by coop_patch.c after ENDHOLD; uses its helpers (g_hit, g_base, g_imgsize, alloc_near, write_bytes, log_line,
 * internal_failure, g_off, g_dirty, on_off).
 *
 * The game adds a notice to the lord's log (the corner list and the banner with its sound) in PawnCPP::addLog (4b29190)
 * and PawnCPP::addLogIfNew (4b292b0). 58 call sites in the game's own code reach them (theft, deaths, drought, stocks
 * soaked, crafting botched, rotting crops, animals, harvest, mercenaries, tithe, emigration, approval, royal tax, ...).
 * The only other way in is each one's exec thunk (the script layer). No blueprint calls either (lane 16's dump of the
 * script bytes of all 3980 loaded blueprint functions: 0 callers of either), but that is not relied on: the mod marks
 * its own call (coop_patch_mark, below), and the entry a call came through is not looked at.
 *   NOLOG ON    the first whole instructions of both entries (5 and 8 bytes; 16-aligned, so one qword each) become a
 *               jump to a stub: a call that follows the mod's mark on the same thread within 50 ms goes on into the
 *               game's routine (the host's notice, shown with the game's own function), and the mark is used up; any
 *               other call returns at once (the game's own notice on this copy is not added and its alert does not
 *               play). Both are void, and the return comes before either has built anything: what addLogIfNew's own
 *               "already shown" exit leaves too. None of the 71 call sites reads the log in the 256 bytes after
 *               its call. Both or none.
 *   NOLOG OFF   the original bytes back (also at ALLOFF).
 * Status: "NOLOG on|off dropped=<game's own notices not added> passed=<the mod's> refused=<n>", or "NOLOG unavailable <why>".
 * Not covered (they append inline, without either function): addResourceAddedLogs, ChangeTreasury, constructionComplete,
 * settleRegion, updateSquadVisibility. Each follows an outcome the host already decides on a friend's copy (goods and
 * silver by the facts module, construction by FINISH, settling by the town module, enemy squads seen on this copy's
 * own map), and the host's same notice is folded into it by addLogIfNew. */
#define NOLOG_SITES 2
static const int NL_SIG[NOLOG_SITES]  = { S_LOGADD, S_LOGNEW };
static const int NL_BACK[NOLOG_SITES] = { 5, 8 };             /* the pattern starts this far after the entry */
static const uint8_t NL_ORIG[NOLOG_SITES][8] = {
    { 0x48, 0x89, 0x5C, 0x24, 0x08 },                          /* mov [rsp+8],rbx */
    { 0x4C, 0x8B, 0xDC, 0x55, 0x49, 0x8D, 0x6B, 0xB9 } };      /* mov r11,rsp; push rbp; lea rbp,[r11-47h] */
static volatile LONG g_nl_drop[NOLOG_SITES], g_nl_pass[NOLOG_SITES], g_nl_faults, g_nl_marks;
static struct {
    int avail; char why[160];
    uint8_t *e[NOLOG_SITES], *stub;
    uint8_t jmp[NOLOG_SITES][8];
    unsigned refused;
} NL;

static int nolog_bytes_on(void)  { int k; if (!NL.stub) return 0; for (k = 0; k < NOLOG_SITES; k++) if (!NL.e[k] || memcmp(NL.e[k], NL.jmp[k], (size_t)NL_BACK[k]) != 0) return 0; return 1; }
static int nolog_bytes_off(void) { int k; for (k = 0; k < NOLOG_SITES; k++) if (!NL.e[k] || memcmp(NL.e[k], NL_ORIG[k], (size_t)NL_BACK[k]) != 0) return 0; return 1; }

static int nolog_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "NOLOG unavailable dll is off\r\n");
    if (!NL.avail) return _snprintf(buf, len, "NOLOG unavailable %s\r\n", NL.why);
    return _snprintf(buf, len, "NOLOG %s dropped=%ld passed=%ld marks=%ld refused=%u faults=%ld\r\n", nolog_bytes_on() ? "on" : "off",
                     g_nl_drop[0] + g_nl_drop[1], g_nl_pass[0] + g_nl_pass[1], g_nl_marks, NL.refused, g_nl_faults);
}

static int nolog_scan(void)
{
    int k;
    memset(&NL, 0, sizeof(NL));
    NL.avail = 1;
    for (k = 0; k < NOLOG_SITES && NL.avail; k++) {
        const sig_hit *h = &g_hit[NL_SIG[k]];
        uint8_t *e;
        if (h->hits != 1) { NL.avail = 0; _snprintf(NL.why, sizeof(NL.why), "%s signature has %d hits (need exactly 1)", SIGS[NL_SIG[k]].name, h->hits); break; }
        e = g_base + h->rva - (uint32_t)NL_BACK[k];
        if ((((uintptr_t)e) & 7) + (uintptr_t)NL_BACK[k] > 8) { NL.avail = 0; _snprintf(NL.why, sizeof(NL.why), "%s: the hook would cross an 8-byte block", SIGS[NL_SIG[k]].name); break; }
        if (memcmp(e, NL_ORIG[k], (size_t)NL_BACK[k]) != 0 && e[0] != 0xE9) { NL.avail = 0; _snprintf(NL.why, sizeof(NL.why), "%s: the entry holds neither its known bytes nor a jump", SIGS[NL_SIG[k]].name); break; }
        NL.e[k] = e;
    }
    log_line("  NOLOG %s %s", NL.avail ? "off" : "unavailable", NL.avail ? "" : NL.why);
    return NL.avail;
}

/* the mod's mark: coop_patch_mark() (an export of this DLL, same shape as coop_patch_tick), called by the mod on the
 * game thread right before its own addLog / addLogIfNew. One notice call on that thread within NOLOG_MARK_MS goes in. */
#define NOLOG_MARK_MS 50
static volatile LONG g_nl_mark_n;
static volatile DWORD g_nl_mark_tid;
static volatile ULONGLONG g_nl_mark_t;
static void nolog_mark(void)
{
    g_nl_mark_tid = GetCurrentThreadId();
    g_nl_mark_t = GetTickCount64();
    InterlockedExchange(&g_nl_mark_n, 1);
    InterlockedIncrement(&g_nl_marks);
}
/* 1 = the game's routine runs (the mod's notice), 0 = it returns at once (the game's own notice on this copy) */
static int nolog_gate(int k)
{
    __try {
        if (g_nl_mark_n > 0 && g_nl_mark_tid == GetCurrentThreadId() && GetTickCount64() - g_nl_mark_t <= NOLOG_MARK_MS) {
            InterlockedExchange(&g_nl_mark_n, 0);
            InterlockedIncrement(&g_nl_pass[k]);
            return 1;
        }
        InterlockedIncrement(&g_nl_drop[k]);
        return 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) { InterlockedIncrement(&g_nl_faults); return 1; }   /* in doubt the game runs */
}

/* a stub: push rcx rdx r8 r9; sub rsp,28h; mov ecx,<k>; mov rax,<nolog_gate>; call rax; add rsp,28h; pop r9 r8 rdx rcx;
 *         test eax,eax; jnz run; ret;  run: <the entry's first bytes>; jmp [rip+0] -> entry + len
 * (the register arguments come back as they were, the stack arguments are untouched; the stack is 16-aligned at the
 * call: entry rsp = 8 mod 16, four pushes and 28h) */
static size_t nolog_emit(uint8_t *p, int k)
{
    static const uint8_t pre[]  = { 0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x48, 0x83, 0xEC, 0x28, 0xB9 };
    static const uint8_t mid[]  = { 0x48, 0xB8 };
    static const uint8_t post[] = { 0xFF, 0xD0, 0x48, 0x83, 0xC4, 0x28, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59, 0x85, 0xC0, 0x75, 0x01, 0xC3 };
    void *fn = (void *)&nolog_gate;
    uint8_t *resume = NL.e[k] + NL_BACK[k];
    int32_t kv = k;
    size_t n = 0;
    memcpy(p + n, pre, sizeof(pre)); n += sizeof(pre);
    memcpy(p + n, &kv, 4); n += 4;
    memcpy(p + n, mid, sizeof(mid)); n += sizeof(mid);
    memcpy(p + n, &fn, 8); n += 8;
    memcpy(p + n, post, sizeof(post)); n += sizeof(post);
    memcpy(p + n, NL_ORIG[k], (size_t)NL_BACK[k]); n += (size_t)NL_BACK[k];
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0;
    memcpy(p + n, &resume, 8); n += 8;
    return n;
}

static int nolog_make_stub(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize);
    size_t n = 0;
    int k, j;
    int32_t rel;
    DWORD old;
    if (!p) return 0;
    for (k = 0; k < NOLOG_SITES; k++) {
        size_t at = n;
        n += nolog_emit(p + n, k);
        n = (n + 15) & ~(size_t)15;
        rel = (int32_t)((intptr_t)(p + at) - (intptr_t)(NL.e[k] + 5));
        NL.jmp[k][0] = 0xE9; memcpy(&NL.jmp[k][1], &rel, 4);
        for (j = 5; j < NL_BACK[k]; j++) NL.jmp[k][j] = 0x90;            /* never run: the jump comes first */
    }
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    NL.stub = p;
    log_line("NOLOG: stubs at %p (%Iu bytes), entries at %p and %p", (void *)p, n, (void *)NL.e[0], (void *)NL.e[1]);
    return 1;
}

static void nolog_unhook(void)
{
    char w[160];
    int k, r;
    if (!NL.avail || !NL.stub) return;
    for (k = 0; k < NOLOG_SITES; k++)
        if (memcmp(NL.e[k], NL.jmp[k], (size_t)NL_BACK[k]) == 0) {
            r = write_bytes(NL.e[k], NL.jmp[k], NL_ORIG[k], NL_BACK[k], w, sizeof(w));
            if (r != 1) { log_line("NOLOG: %s could not be restored: %s", SIGS[NL_SIG[k]].name, w); if (r < 0) internal_failure("nolog restore failed"); }
        }
    g_dirty = 1;
}

static void nolog_on(void)
{
    char w[160];
    int k, r = 1;
    g_dirty = 1;
    if (!NL.avail) { NL.refused++; log_line("NOLOG ON refused: unavailable (%s)", NL.why); return; }
    if (!NL.stub && !nolog_make_stub()) { NL.avail = 0; _snprintf(NL.why, sizeof(NL.why), "no free memory near the game module for the stubs"); log_line("NOLOG ON refused: %s", NL.why); return; }
    if (nolog_bytes_on()) { log_line("NOLOG already on"); return; }
    if (!nolog_bytes_off()) { NL.avail = 0; _snprintf(NL.why, sizeof(NL.why), "an entry holds neither its own bytes nor this DLL's jump"); log_line("NOLOG ON refused: %s", NL.why); return; }
    for (k = 0; k < NOLOG_SITES && r == 1; k++) {
        r = write_bytes(NL.e[k], NL_ORIG[k], NL.jmp[k], NL_BACK[k], w, sizeof(w));
        if (r != 1) log_line("NOLOG ON: %s not written: %s", SIGS[NL_SIG[k]].name, w);
    }
    if (r != 1) {
        nolog_unhook();                                 /* both or none */
        NL.avail = 0; _snprintf(NL.why, sizeof(NL.why), "%s", w);
        log_line("NOLOG ON FAILED: %s; both entries put back, item marked unavailable", w);
        if (r < 0) internal_failure("nolog write failed");
        return;
    }
    log_line("NOLOG on at %p and %p (stubs %p)", (void *)NL.e[0], (void *)NL.e[1], (void *)NL.stub);
}

static void nolog_off(const char *why)
{
    int was;
    if (!NL.avail || !NL.stub) return;
    was = nolog_bytes_on();
    nolog_unhook();
    if (was) log_line("NOLOG off (%s): %ld of the game's own notices were not added, %ld of the mod's went in", why,
                      g_nl_drop[0] + g_nl_drop[1], g_nl_pass[0] + g_nl_pass[1]);
}

static void nolog_cmd(int argc, char **argv)
{
    int v;
    if (argc == 2 && on_off(argv[1], &v)) { if (v) nolog_on(); else nolog_off("NOLOG OFF"); return; }
    NL.refused++; g_dirty = 1;
    log_line("NOLOG refused: needs ON or OFF");
}
