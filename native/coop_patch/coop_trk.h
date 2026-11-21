/* ------------------------------------------------------------------ TRK (lane 83, 0.9.15): a friend's production log and
 * time list are the host's only. Design: research/2026-11-10-game-probe/lanes/lane_s21_83/design_trkhold.txt.
 * The game writes a building's production tracker in three routines:
 *   HADD  4bb3620 AddProduction(tracker, good, amount, ...): the goods made (the panel's goods made and yield status)
 *   TADD1 4bcf780 (tracker, category dl, time xmm2 float) and TADD2 4bcf7f0 (the same and the unit r9): work time added
 *         to a category of the time list (the panel's time pie); both broadcast OnNewTimeTracked as a tail call
 * None of their callers uses a return value. On a friend each copy's own villagers' work went into its own tracker
 * before the host's carry (TRKSET, the time lists) wrote the host's back: values the host never had.
 *   TRKHOLD ON    (friend) each routine's first instruction jumps to a stub of this DLL (HADD: 48 89 5C 24 18, 5 bytes;
 *                 TADD1: 4C 8B 89 20 01 00 00, 7; TADD2: 41 80 B9 B0 0A 00 00 05, 8; none rip-relative): the game's own
 *                 call returns at once (skipped, counted). Passed through (the routine runs as before): a call made by
 *                 this DLL itself (TRKSET's growth, TRYADD: g_trk_native), a call from another thread than the ticking
 *                 one (counted), and every call once no TRKHOLD ON has come for TRK_ALIVE_MS (the mod stopped
 *                 answering: counted, logged once): the dead-man. The time routines are hooked only when both of their
 *                 signatures have exactly one hit; the production one alone otherwise (said in the status).
 *   TRKHOLD ON is also the keepalive (the mod sends it every second while it wants the hold).
 *   TRKHOLD OFF   the original bytes back (also at ALLOFF and when the DLL switches itself off).
 * Status: "TRK on|off skipped=<n> passed=<n> native=<n> other=<n> stale=<n> tskipped=<n> time=on|off|<why>", or
 * "TRK unavailable <why>". */
#define TRK_ALIVE_MS   5000
#define TRK_SITES      3
static const uint8_t TRK_ORIG0[5] = { 0x48, 0x89, 0x5C, 0x24, 0x18 };
static const uint8_t TRK_ORIG1[7] = { 0x4C, 0x8B, 0x89, 0x20, 0x01, 0x00, 0x00 };
static const uint8_t TRK_ORIG2[8] = { 0x41, 0x80, 0xB9, 0xB0, 0x0A, 0x00, 0x00, 0x05 };
static const uint8_t *const TRK_ORIG[TRK_SITES] = { TRK_ORIG0, TRK_ORIG1, TRK_ORIG2 };
static const int TRK_LEN[TRK_SITES] = { 5, 7, 8 };
static const int TRK_SIG[TRK_SITES] = { S_HADD, S_TADD1, S_TADD2 };
static struct {
    int avail, tried, nsites; char why[160], twhy[120];
    uint8_t *e[TRK_SITES], *stub; uint8_t jmp[TRK_SITES][8];
    volatile LONG on; DWORD thread; ULONGLONG alive; int staleSaid;
    unsigned skipped, tskipped, passed, native, other, stale;
} TK;

/* the gate: 1 = the routine runs, 0 = the call returns at once (kind 0: production, 1 and 2: time) */
static int __cdecl trk_gate(void *tracker, int a, int b, int kind)
{
    (void)tracker; (void)a; (void)b;
    if (!TK.on) { TK.passed++; return 1; }
    if (g_trk_native) { TK.native++; return 1; }
    if (GetCurrentThreadId() != TK.thread) { TK.other++; return 1; }
    if (GetTickCount64() - TK.alive > TRK_ALIVE_MS) {
        TK.stale++;
        if (!TK.staleSaid) { TK.staleSaid = 1; log_line("TRK: no TRKHOLD ON for %u ms: the game's own production and time calls pass through", (unsigned)TRK_ALIVE_MS); }
        return 1;
    }
    if (kind == 0) TK.skipped++; else TK.tskipped++;
    return 0;
}

/* one stub: push rcx,rdx,r8,r9 (rsp is 8 mod 16 at the routine's entry, still after four pushes); sub rsp,38h (16-
 * aligned, the 32-byte shadow space and xmm2 saved at +20h: the time routines take their time there); r9d = kind; call
 * trk_gate; r11 = its answer; xmm2 back; add rsp,38h; pop r9,r8,rdx,rcx; r11d = 0: ret (the call skipped, nothing of the
 * routine has run); else the moved instruction, then on at the routine's next instruction */
static size_t trk_emit(uint8_t *p, int k)
{
    static const uint8_t pre[] = { 0x51, 0x52, 0x41, 0x50, 0x41, 0x51,          /* push rcx; push rdx; push r8; push r9 */
                                   0x48, 0x83, 0xEC, 0x38,                      /* sub rsp,38h */
                                   0xF3, 0x0F, 0x7F, 0x54, 0x24, 0x20,          /* movdqu [rsp+20h],xmm2 */
                                   0x41, 0xB9 };                                /* mov r9d, imm32 (the kind) */
    static const uint8_t mid[] = { 0x48, 0xB8 };                                /* mov rax, imm64 (the gate) */
    static const uint8_t post[] = { 0xFF, 0xD0,                                 /* call rax */
                                    0x4C, 0x8B, 0xD8,                           /* mov r11,rax */
                                    0xF3, 0x0F, 0x6F, 0x54, 0x24, 0x20,         /* movdqu xmm2,[rsp+20h] */
                                    0x48, 0x83, 0xC4, 0x38,                     /* add rsp,38h */
                                    0x41, 0x59, 0x41, 0x58, 0x5A, 0x59,         /* pop r9; pop r8; pop rdx; pop rcx */
                                    0x45, 0x85, 0xDB,                           /* test r11d,r11d */
                                    0x75, 0x01,                                 /* jnz +1 */
                                    0xC3 };                                     /* ret (skipped) */
    void *fn = (void *)&trk_gate; uint8_t *resume = TK.e[k] + TRK_LEN[k]; int32_t kind = k;
    size_t n = 0;
    memcpy(p + n, pre, sizeof(pre)); n += sizeof(pre);
    memcpy(p + n, &kind, 4); n += 4;
    memcpy(p + n, mid, sizeof(mid)); n += sizeof(mid);
    memcpy(p + n, &fn, 8); n += 8;
    memcpy(p + n, post, sizeof(post)); n += sizeof(post);
    memcpy(p + n, TRK_ORIG[k], (size_t)TRK_LEN[k]); n += (size_t)TRK_LEN[k];       /* the moved instruction */
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0;  /* jmp [rip+0] */
    memcpy(p + n, &resume, 8); n += 8;
    return n;
}

static int trk_make_stubs(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize);
    size_t n = 0; int k, j; int32_t rel; DWORD old;
    if (!p) return 0;
    for (k = 0; k < TK.nsites; k++) {
        size_t at = n;
        n += trk_emit(p + n, k);
        n = (n + 15) & ~(size_t)15;
        rel = (int32_t)((intptr_t)(p + at) - (intptr_t)(TK.e[k] + 5));
        TK.jmp[k][0] = 0xE9; memcpy(&TK.jmp[k][1], &rel, 4);
        for (j = 5; j < TRK_LEN[k]; j++) TK.jmp[k][j] = 0x90;                   /* never run: the jump comes first */
    }
    if (n > 0x1000 || !VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    TK.stub = p;
    log_line("TRK: stubs at %p (%Iu bytes, %d routines)", (void *)p, n, TK.nsites);
    return 1;
}

static int trk_ready(void)
{
    int k;
    if (TK.tried) return TK.avail;
    TK.tried = 1;
    if (!(g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE)) { _snprintf(TK.why, sizeof(TK.why), "another game build (timestamp %X)", g_stamp); return 0; }
    if (g_hit[S_HADD].hits != 1) { _snprintf(TK.why, sizeof(TK.why), "HADD signature has %d hits (need exactly 1)", g_hit[S_HADD].hits); return 0; }
    TK.nsites = 1;
    if (g_hit[S_TADD1].hits == 1 && g_hit[S_TADD2].hits == 1) TK.nsites = 3;
    else _snprintf(TK.twhy, sizeof(TK.twhy), "TADD1/TADD2 hits %d/%d", g_hit[S_TADD1].hits, g_hit[S_TADD2].hits);
    for (k = 0; k < TK.nsites; k++) {
        TK.e[k] = g_base + g_hit[TRK_SIG[k]].rva;
        if (memcmp(TK.e[k], TRK_ORIG[k], (size_t)TRK_LEN[k]) != 0) {
            if (k == 0) { _snprintf(TK.why, sizeof(TK.why), "AddProduction does not start as expected"); return 0; }
            _snprintf(TK.twhy, sizeof(TK.twhy), "a time routine does not start as expected"); TK.nsites = 1; break;
        }
    }
    if (!trk_make_stubs()) { _snprintf(TK.why, sizeof(TK.why), "no room for the stubs near the game's code"); return 0; }
    TK.avail = 1;
    return 1;
}

static void trk_off(const char *why)
{
    char w[160]; int r, k;
    InterlockedExchange(&TK.on, 0);
    if (!TK.avail) return;
    for (k = 0; k < TK.nsites; k++) {
        if (TK.e[k] && memcmp(TK.e[k], TK.jmp[k], (size_t)TRK_LEN[k]) == 0) {
            r = write_bytes(TK.e[k], TK.jmp[k], TRK_ORIG[k], TRK_LEN[k], w, sizeof(w));
            if (r == 1) log_line("TRK %s off (%s)", SIGS[TRK_SIG[k]].name, why);
            else { log_line("TRK: %s could not be restored: %s", SIGS[TRK_SIG[k]].name, w); if (r < 0) internal_failure("trk restore failed"); }
        }
    }
    g_dirty = 1;
}

static void trk_on(void)
{
    char w[160]; int r, k;
    if (!trk_ready()) { log_line("TRK on refused: %s", TK.why); g_dirty = 1; return; }
    TK.alive = GetTickCount64(); TK.staleSaid = 0;
    if (memcmp(TK.e[0], TK.jmp[0], 5) == 0) { InterlockedExchange(&TK.on, 1); return; }     /* the keepalive */
    TK.thread = GetCurrentThreadId();
    InterlockedExchange(&TK.on, 1);
    for (k = 0; k < TK.nsites; k++) {
        r = write_bytes(TK.e[k], TRK_ORIG[k], TK.jmp[k], TRK_LEN[k], w, sizeof(w));
        if (r == 1) log_line("TRK %s on at %p", SIGS[TRK_SIG[k]].name, (void *)TK.e[k]);
        else {
            log_line("TRK %s on FAILED: %s", SIGS[TRK_SIG[k]].name, w);
            trk_off("a site could not be written");
            TK.avail = 0; _snprintf(TK.why, sizeof(TK.why), "%s", w);
            if (r < 0) internal_failure("trk write failed");
            break;
        }
    }
    g_dirty = 1;
}

static void trk_reset(void) { memset((void *)&TK, 0, sizeof(TK)); }

static int trk_status(char *buf, size_t len)
{
    if (!TK.tried) return _snprintf(buf, len, "TRK off skipped=0 passed=0 native=0 other=0 stale=0 tskipped=0\r\n");
    if (!TK.avail) return _snprintf(buf, len, "TRK unavailable %s\r\n", TK.why);
    return _snprintf(buf, len, "TRK %s skipped=%u passed=%u native=%u other=%u stale=%u tskipped=%u time=%s\r\n",
                     (TK.on && memcmp(TK.e[0], TK.jmp[0], 5) == 0) ? "on" : "off", TK.skipped, TK.passed, TK.native, TK.other, TK.stale, TK.tskipped,
                     TK.nsites == 3 ? "hooked" : TK.twhy);
}
