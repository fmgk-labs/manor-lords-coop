/* coop_men.h - lane 43 (MEN): a man of a squad walks to the place the host's game gave its own man.
 * Included once by coop_patch.c, right before its command section; everything here is this lane's own block.
 * Evidence: research\2026-11-10-game-probe\lanes\lane_s21_43\report.txt (item 1).
 *
 * What the game does (read in the game file, lane 38 round 3 and lane 43): every walk of a man (SMUnit) starts in ONE
 * routine, MPATH (4dbc910, "newAsyncPathRequest"): rcx = the man, rdx = a point record (0x88 bytes; the place at +8,
 * +10h, +18h as doubles, cm; a level byte at +7Eh; the callee owns it: it frees its lists +20h, +30h, +48h), r8b = a flag,
 * r9 = a list record (the callee frees it too). Its 14 callers include the squad's own AI (updateSquadAI 4d6baf0: attack,
 * follow, charge, the place at the man's +BD8h; tickSquad 4d87a40: each man to his slot) and the men's own actions.
 *
 * Friend (held men): the host's place for a man replaces the place in the record before the routine runs, so this copy's
 * game itself walks the man there, with its own path and its own pace. MEN SET hands the host's places over (from the
 * mod's Lua, which has just checked in this frame that each man is alive and in his squad); a place that moved by
 * MEN_GO_CM or more since the man was last sent is given at once with the game's own routine (a record built as tickSquad
 * builds it), so the man does not wait for this copy's squad AI to ask.
 * Host (watched men): the hook only notes the place each call asks for (nothing is changed); MEN POLL writes men_out.txt,
 * one line per watched man whose asked place moved by MEN_STEP_CM or more since it was last written.
 * The table holds addresses that are only COMPARED, never read through (a dead man stays a "valid" object for a while and
 * is then freed). Only MEN SET reads through an address (vtable, +CE0h), in the frame the Lua checked it.
 *
 *   MEN HOOK ON|OFF                       MPATH's entry jumps to this DLL's stub / its own bytes back (OFF: table emptied)
 *   MEN SET <hex>=<x>,<y>,<z>[,1];...     friend: the host's place for each man (cm); added to the table when new. ",1" (lane 52,
 *                                         round 2): the place is the host's man's OWN place this round (a walking squad's line),
 *                                         not a place he asked for: PACE lets the man catch up with it (below). ",2" (round 3):
 *                                         the same for a man of another lord's muster: his pace is this rule's alone
 *   MEN WATCH <hex>,... / UNWATCH <hex>,...   host: men whose asked places are noted
 *   MEN POLL                              host: men_out.txt = "<hex> <x> <y> <z>" per watched man with a new place
 *   MEN DROP <hex>,...                    out of the table (dead, routed, left the squad, squad gone)
 *   MEN LET <hex>,...                     friend (lane 52): let go at an order (his requests pass), still watched by the
 *                                         run-off check until a SET holds him again or 3 s pass without one
 *   MEN FORGET                            the whole table emptied (resync, load, role change, the mod stopping)
 *   MEN HEREAT <hex>                      host (lane 48): each POLL also writes "H <hex> <x> <y> <z>" per watched man whose
 *                                         own place (SMUnit.realPos at this offset) moved 1 m (below)
 *   MEN PACE ON|OFF                       friend (lane 52, round 2; on by default, OFF is the console's test switch): after
 *                                         the game's pace rule ran for a squad, a held man's speed factor from the lengths of the ways is 1 (PACE)
 *   MEN KEEP ON|OFF                       friend (lane 52, round 2; on by default): a held man's own request is not run
 *                                         again while his way already leads to the host's place (KEEP)
 * Refused on another game build (the record's layout and the man's +CE0h are not held by a signature). */
#include <intrin.h>                /* _ReturnAddress (lane 52: the ring notes who asked) */
#define MEN_HOOK_LEN   8
#define MEN_MAX        1536        /* men in the table (both roles); a large battle has about 600 */
#define MEN_STEP_CM    50.0        /* host: a new asked place is written when it moved this far (round 1: 25 cm; round 2: 1 m made the walks lag, fA1-fA4) */
#define MEN_GO_CM      50.0        /* friend: a host place this far from the last one given is given at once */
#define MEN_REC        0x88        /* the point record */
#define MEN_MAN_BYTES  0xE60       /* bytes of a man that must be readable for a GO (the routine reads +E3Ch, +E50h) */
#define MEN_SKIP_OFF   0xCE0       /* tickSquad gives no slot to a man whose qword here is not 0 */
static const uint8_t MEN_ORIG[MEN_HOOK_LEN] = { 0x40, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41, 0x56 };   /* push rbp/rsi/rdi/r12/r14 */
typedef void (*mpath_fn)(void *man, uint8_t *rec, uint64_t flag, void *list);

#define MF_HOLD   1                /* friend: the host's place is substituted */
#define MF_WATCH  2                /* host: asked places noted */
#define MF_SEEN   4                /* host: a place was asked since it was watched */
#define MF_SENT   8                /* host: a place was written */
#define MF_GIVEN 16                /* friend: a place was given to him (hook or GO) */
#define MF_TRACE 32                /* friend (lane 52): let go at an order (MEN LET), still watched by the run-off check */
#define MF_HERE  64                /* host: the man's own place was written (HERE, lane 48) */
#define MF_SANE 128                /* host: the man's bytes were found committed and readable (HERE, lane 48) */
typedef struct { uintptr_t a; double ht[3], seen[3], sent[3], given[3], here[3]; uint32_t tcall, tgo, tset, tfar, tfar6, tpos, trun; uint8_t lvl, flags, fired, pend, follow; float dfar, dfar6, px, py, vel; } ment;
/* a man's fields read here beside realPos (the known build only: MEN is refused on another one) */
#define MEN_DEST_OFF   0x510       /* the place of the request he walks by (a copy of the record at +508h; set by the path request) */
#define MEN_DESTLVL    0x586       /* its level byte */
#define MEN_FACTOR_OFF 0x5A8       /* SMUnit.speedFactor */
#define MEN_PATH_OFF   0x7D0       /* SMUnit.Path (data, count at +7D8h), PathPoint at +7E0h */
#define MEN_BUSY_OFF   0xE3C       /* the path request leaves at once while this byte is set (he sits, or is busy) */
#define PACE_HOOK_LEN  8
static const uint8_t PACE_ORIG[PACE_HOOK_LEN] = { 0x40, 0x53, 0x57, 0x41, 0x55, 0x48, 0x81, 0xEC };   /* push rbx / push rdi / push r13 / sub rsp,.. (its first 3 bytes) */

/* lane 52: the ring of path requests of the men in the table (friend: held or traced), for the run-off dump */
#define MEN_RING 4096
typedef struct { uint32_t t, ret; uintptr_t man; float x, y, z; uint8_t kind; } mring;   /* kind: 0 own request passed, 1 substituted, 2 GO, 3 not run (KEEP) */
static mring men_ring[MEN_RING];
static unsigned long long men_ringn;

static struct {
    int avail; char why[160];
    uint8_t *entry, *stub, *tramp;
    const uint8_t *k1, *k2;       /* the constants tickSquad puts at the record's +58h (16 bytes) and +68h (8 bytes) */
    uint8_t jmp[MEN_HOOK_LEN];
    volatile LONG enabled; int own; DWORD thread; volatile LONG want_off; DWORD fault_code;
    int n; ment e[MEN_MAX];       /* sorted by address */
    unsigned long long calls, subst, seen, gos, gofail, ce0, sets, setmen, lines, outbytes, polls, drops, other, refused, faults, full, forgets;
    LONGLONG qpf, qhook, qgo, qpoll;
    uint32_t hoff; unsigned long long heres, herelines, herebad; LONGLONG qhere;   /* lane 48: HERE */
    int rego_off; uint32_t rego_t; unsigned long long regos, regolooks;              /* lane 48: REGO (friend) */
    unsigned long long runoffs, lets, diags; uintptr_t rlast; uint32_t ro_t;          /* lane 52: the run-off check (friend) */
    unsigned long long land[6], supers, landed, foreign, fdiags, e3cwait, e3cgos; uint32_t pw_t;                         /* lane 52 round 2: how long a GO takes to become his path (friend) */
    /* lane 52 round 2: PACE (the squad's pace rule, hooked) and KEEP */
    int pace_avail, pace_off, keep_off, catch_off; char pace_why[120];
    uint8_t *p_entry, *p_tramp; void *p_find; uint8_t p_jmp[PACE_HOOK_LEN];
    unsigned long long raised, sped, mustered, pcalls, pother, keeps, ro6, seated, stood; LONGLONG qpace;
} MV;

static int men_bytes_on(void)  { return MV.stub && memcmp(MV.entry, MV.jmp, MEN_HOOK_LEN) == 0; }
static int pace_bytes_on(void) { return MV.pace_avail && MV.stub && MV.p_tramp && memcmp(MV.p_entry, MV.p_jmp, PACE_HOOK_LEN) == 0; }
static int men_bytes_off(void) { return MV.entry && memcmp(MV.entry, MEN_ORIG, MEN_HOOK_LEN) == 0; }

static int men_scan(void)
{
    LARGE_INTEGER qf;
    memset(&MV, 0, sizeof(MV));
    QueryPerformanceFrequency(&qf); MV.qpf = qf.QuadPart;
    if (g_hit[S_MPATH].hits != 1 || g_hit[S_MSLOT].hits != 1)
        _snprintf(MV.why, sizeof(MV.why), "signature hits MPATH %d MSLOT %d (need exactly 1 each)", g_hit[S_MPATH].hits, g_hit[S_MSLOT].hits);
    else if (g_stamp != KNOWN_TIMESTAMP || g_imgsize != KNOWN_IMAGESIZE) _snprintf(MV.why, sizeof(MV.why), "not the known game build (the record's layout is not in a signature)");
    else {
        const uint8_t *s = g_base + g_hit[S_MSLOT].rva;
        MV.entry = g_base + g_hit[S_MPATH].rva;
        MV.k1 = s + 10 + *(const int32_t *)(s + 6);
        MV.k2 = s + 34 + *(const int32_t *)(s + 30);
        if (((uintptr_t)MV.entry & 7) != 0) _snprintf(MV.why, sizeof(MV.why), "MPATH's first 8 bytes are not one aligned block");
        else if (memcmp(MV.entry, MEN_ORIG, MEN_HOOK_LEN) != 0) _snprintf(MV.why, sizeof(MV.why), "MPATH does not start with its known instructions");
        else if (s + 111 + *(const int32_t *)(s + 107) != MV.entry) _snprintf(MV.why, sizeof(MV.why), "MSLOT's call does not reach MPATH");
        else if (MV.k1 < g_base || MV.k1 + 16 > g_base + g_imgsize || MV.k2 < g_base || MV.k2 + 8 > g_base + g_imgsize || !range_readable(MV.k1, 16) || !range_readable(MV.k2, 8))
            _snprintf(MV.why, sizeof(MV.why), "MSLOT's constants are not in the game module");
        else MV.avail = 1;
    }
    log_line("  MEN    %s %s", MV.avail ? "idle" : "unavailable", MV.avail ? "" : MV.why);
    /* lane 52 round 2, PACE: the squad's pace rule; both its calls before it reads the squad's men reach one routine
     * (the squad lookup), inside the module. Without it MEN works as before (no pace floor). */
    if (MV.avail) {
        if (g_hit[S_PACE].hits != 1) _snprintf(MV.pace_why, sizeof(MV.pace_why), "signature hits PACE %d (need exactly 1)", g_hit[S_PACE].hits);
        else {
            uint8_t *e = g_base + g_hit[S_PACE].rva;
            uint8_t *f1 = e + 22 + *(const int32_t *)(e + 18), *f2 = e + 76 + *(const int32_t *)(e + 72);
            if (((uintptr_t)e & 7) != 0) _snprintf(MV.pace_why, sizeof(MV.pace_why), "its first 8 bytes are not one aligned block");
            else if (memcmp(e, PACE_ORIG, PACE_HOOK_LEN) != 0) _snprintf(MV.pace_why, sizeof(MV.pace_why), "it does not start with its known instructions");
            else if (f1 != f2 || f1 < g_base || f1 >= g_base + g_imgsize) _snprintf(MV.pace_why, sizeof(MV.pace_why), "its two calls do not reach one routine in the module");
            else { MV.p_entry = e; MV.p_find = (void *)f1; MV.pace_avail = 1; }
        }
        log_line("  MEN    pace rule %s %s", MV.pace_avail ? "found" : "not usable:", MV.pace_avail ? "" : MV.pace_why);
    }
    return MV.avail;
}

static int men_status(char *buf, size_t len)
{
    int n = 0, held = 0, watched = 0, i;
    for (i = 0; i < MV.n; i++) { if (MV.e[i].flags & MF_HOLD) held++; if (MV.e[i].flags & MF_WATCH) watched++; }
    /* never the word "on" (the host's "everything off" rule looks for it; on the host the hook only reads) */
    if (g_off || !MV.avail) n += _snprintf(buf + n, len - (size_t)n, "MEN unavailable %s\r\n", g_off ? "dll is off" : MV.why);
    else n += _snprintf(buf + n, len - (size_t)n, "MEN %s\r\n", men_bytes_on() ? "hooked" : men_bytes_off() ? "idle" : "unavailable its entry holds unknown bytes");
    n += _snprintf(buf + n, len - (size_t)n,
                   "menstat held=%d watched=%d calls=%llu subst=%llu seen=%llu gos=%llu gofail=%llu ce0=%llu sets=%llu setmen=%llu polls=%llu lines=%llu outbytes=%llu "
                   "drops=%llu forgets=%llu full=%llu other=%llu refused=%llu faults=%llu ushook=%lld usgo=%lld uspoll=%lld "
                   "hoff=%X heres=%llu herelines=%llu herebad=%llu ushere=%lld regos=%llu regolooks=%llu rego=%d runoffs=%llu rlast=%IX lets=%llu diags=%llu landms=%llu/%llu/%llu/%llu/%llu/%llu supers=%llu foreign=%llu e3cwait=%llu e3cgos=%llu "
                   "ro6=%llu seated=%llu pace=%s raised=%llu pcalls=%llu pother=%llu uspace=%lld keep=%d keeps=%llu catch=%d sped=%llu mustered=%llu stood=%llu\r\n",
                   held, watched, MV.calls, MV.subst, MV.seen, MV.gos, MV.gofail, MV.ce0, MV.sets, MV.setmen, MV.polls, MV.lines, MV.outbytes,
                   MV.drops, MV.forgets, MV.full, MV.other, MV.refused, MV.faults,
                   MV.qpf ? MV.qhook * 1000000 / MV.qpf : 0, MV.qpf ? MV.qgo * 1000000 / MV.qpf : 0, MV.qpf ? MV.qpoll * 1000000 / MV.qpf : 0,
                   MV.hoff, MV.heres, MV.herelines, MV.herebad, MV.qpf ? MV.qhere * 1000000 / MV.qpf : 0, MV.regos, MV.regolooks, MV.rego_off ? 0 : 1,
                   MV.runoffs, MV.rlast, MV.lets, MV.diags, MV.land[0], MV.land[1], MV.land[2], MV.land[3], MV.land[4], MV.land[5], MV.supers, MV.foreign, MV.e3cwait, MV.e3cgos,
                   MV.ro6, MV.seated, !MV.pace_avail ? "na" : MV.pace_off ? "off" : pace_bytes_on() ? "in" : "out", MV.raised, MV.pcalls, MV.pother,
                   MV.qpf ? MV.qpace * 1000000 / MV.qpf : 0, MV.keep_off ? 0 : 1, MV.keeps, MV.catch_off ? 0 : 1, MV.sped, MV.mustered, MV.stood);
    return n < 0 ? 0 : n;
}

/* ---------------------------------------------------------------- the table (sorted; addresses compared only) */
static int men_pos(uintptr_t a, int *found)
{
    int lo = 0, hi = MV.n;
    while (lo < hi) { int mid = (lo + hi) / 2; if (MV.e[mid].a < a) lo = mid + 1; else hi = mid; }
    *found = lo < MV.n && MV.e[lo].a == a;
    return lo;
}
static ment *men_find(uintptr_t a) { int f, i = men_pos(a, &f); return f ? &MV.e[i] : NULL; }
static ment *men_add(uintptr_t a)
{
    int f, i = men_pos(a, &f);
    if (f) return &MV.e[i];
    if (MV.n >= MEN_MAX) { MV.full++; return NULL; }
    memmove(&MV.e[i + 1], &MV.e[i], (size_t)(MV.n - i) * sizeof(ment));
    memset(&MV.e[i], 0, sizeof(ment)); MV.e[i].a = a; MV.n++;
    return &MV.e[i];
}
static void men_del(int i) { memmove(&MV.e[i], &MV.e[i + 1], (size_t)(MV.n - i - 1) * sizeof(ment)); MV.n--; memset(&MV.e[MV.n], 0, sizeof(ment)); }
static double men_d2(const double *a, const double *b) { double x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2]; return x * x + y * y + z * z; }

/* ---------------------------------------------------------------- the hook */
static void men_fault(DWORD code)
{
    InterlockedExchange(&MV.enabled, 0);
    MV.faults++; MV.fault_code = code;
    InterlockedExchange(&MV.want_off, 1);
}
/* lane 52 round 2, KEEP: is a held man's own request one the game itself would not make? The game's "go to my task's
 * place" (4db1850) asks only when the place of the request he walks by (+510h) is not his task's place, or his way is
 * used up (PathPoint > the way's points). With the host's place put into every request of his, +510h never is his
 * task's place: the game asked again at every look of the task (0.2 to 1.3 s), and each request empties his way until
 * the path finder answers: a man who stood with a way to the host's place and did not walk (d2's dumps: real=0.00,
 * path n=3 at=1, "subst by 4DB1C2B" every 0.2-0.9 s). So: he was given this place, the request he walks by is for it,
 * his way has points left: nothing to ask. Only a request whose lists are empty (nothing for the routine to free). */
static int men_same_way(const uint8_t *m, const ment *e, const uint8_t *rec, const void *list, uint32_t now)
{
    const double *d = (const double *)(m + MEN_DEST_OFF);
    int pn = *(const int32_t *)(m + MEN_PATH_OFF + 8), pp = *(const int32_t *)(m + MEN_PATH_OFF + 0x10);
    if (!(e->flags & MF_GIVEN) || memcmp(e->given, e->ht, sizeof(e->given)) != 0) return 0;
    if (d[0] != e->ht[0] || d[1] != e->ht[1] || d[2] != e->ht[2] || m[MEN_DESTLVL] != rec[0x7E]) return 0;
    if (m[0x7FA] != 0 || pn <= 0 || pp > pn) return 0;
    if (*(const uint64_t *)(rec + 0x20) || *(const uint64_t *)(rec + 0x30) || *(const uint64_t *)(rec + 0x48)) return 0;
    if (list && *(const uint64_t *)list) return 0;
    /* (lane 52, round 3) and only while he walks, or a request of his ran in the last 700 ms (the path finder's answer
     * takes 100 to 250 ms): a man who STANDS with a way is the one man who needs the request */
    if (*(const float *)(m + 0x594) < 1.0f && now - e->trun > 700) return 0;
    return 1;
}
/* MPATH's entry jumps here (same arguments): a held man's record gets the host's place, a watched man's asked place is
 * noted; then the game's routine (its moved first bytes and a jump back: the trampoline) */
static void men_wrap_wd(void *man, uint8_t *rec, uint64_t flag, void *list)
{
    int keep = 0;
    if (MV.enabled) {
        if (GetCurrentThreadId() != MV.thread) MV.other++;
        else {
            LARGE_INTEGER t0, t1; QueryPerformanceCounter(&t0);
            __try {
                ment *e;
                MV.calls++;
                e = MV.n ? men_find((uintptr_t)man) : NULL;
                if (e) {
                    double *p = (double *)(rec + 8);
                    if (e->flags & (MF_HOLD | MF_TRACE)) {   /* lane 52: the ring (before the place is changed) */
                        mring *r = &men_ring[men_ringn++ % MEN_RING];
                        uintptr_t ra = (uintptr_t)_ReturnAddress();
                        r->t = GetTickCount(); r->man = e->a; r->x = (float)p[0]; r->y = (float)p[1]; r->z = (float)p[2];
                        r->ret = (ra >= (uintptr_t)g_base && ra < (uintptr_t)g_base + g_imgsize) ? (uint32_t)(ra - (uintptr_t)g_base) : 0xFFFFFFFFu;
                        r->kind = MV.own ? 2 : (e->flags & MF_HOLD) ? 1 : 0;
                        if (r->kind == 1 && !MV.keep_off && men_same_way((const uint8_t *)man, e, rec, list, r->t)) { r->kind = 3; keep = 1; MV.keeps++; e->tcall = r->t; }   /* (he asked: not idle for REGO. h1-h3: without this stamp REGO gave a walking man a GO every 1.5 s, regos 17-75 a sitting became 870-1450, and each GO empties his way for a moment) */
                    }
                    if (keep) { /* his way already leads there: the request is not run */ }
                    else if (e->flags & MF_HOLD) {
                        e->trun = GetTickCount();
                        p[0] = e->ht[0]; p[1] = e->ht[1]; p[2] = e->ht[2];
                        memcpy(e->given, e->ht, sizeof(e->given)); e->flags |= MF_GIVEN; e->lvl = rec[0x7E]; e->tcall = GetTickCount();
                        if (!MV.own) MV.subst++;
                    }
                    if (e->flags & MF_WATCH) { memcpy(e->seen, p, sizeof(e->seen)); e->flags |= MF_SEEN; MV.seen++; }
                }
            } __except (EXCEPTION_EXECUTE_HANDLER) { men_fault(GetExceptionCode()); }
            QueryPerformanceCounter(&t1); MV.qhook += t1.QuadPart - t0.QuadPart;
        }
    }
    if (keep) return;
    ((mpath_fn)(void *)MV.tramp)(man, rec, flag, list);
}
static void men_wrap(void *man, uint8_t *rec, uint64_t flag, void *list)   /* lane 51: the watchdog's marks around it */
{
    wd_in(WD_MEN); men_wrap_wd(man, rec, flag, list); wd_out(WD_MEN);
}

/* lane 52 round 2, PACE: the squad's pace rule (4d8db70) jumps here. The rule gives each man of a squad a speed factor:
 * the length of the way he has left over the squad's mean, 0.5 to 3, so that a squad arrives together (it waits for a
 * man behind). On a friend a held man's way is the few metres to the host's place; ONE man of the squad with the
 * squad's own way to its target (not held, or standing) makes the mean long and every held man walk at half pace
 * (d1: "factor=0.500 sprint=1 real=19.53" on twelve men, the thirteenth "lpath=147978 real=0.00": the militia fell
 * 147 m behind the host's). The host's squad did not wait: after the rule ran, a held man whose factor came from the
 * lengths (the rule's own mark at +3B4h is 0) walks at 1, the pace of a man in his place. Only raising the factors
 * under 1 (the first form, sitting h1) left those over 1: a mean of 1.33, the bandits' chase 6 m AHEAD of the host's.
 * A factor of 3 stays (the rule's word for a man far behind, a rout, a call-up), and so does any factor the rule set
 * for another reason (mark 1). The men are read from the squad's own list (the rule has just walked it), found by
 * the game's own lookup.
 * CATCH-UP: the rule's own idea (a longer way, a faster man) kept for a man whose place is the host's man's own place
 * of this round (a walking squad: SET's ",1"): from 1 at 0.5 m behind it to 1.5 at 2.5 m and more (the law is at its use).
 * Without it nothing but the squad-wide pace pulled a man who was behind (h1: a rival militia's men 6 to 12 m behind
 * their places at realSpeed 12 to 14 for seconds; h2: the rival militia 9.5 m and the retinue 8.3 m behind at the
 * host's own pace, 6 and 4 s late at that pace, off the 3 s track for 9.4 and 4.2 s; b5: the militia 5 to 9 m behind).
 * Not for a place a man asked for
 * (a fight, a camp): the host's man walks there at his own pace too. */
#define PACE_NEAR_CM   50.0
#define PACE_MAX       1.5
/* (round 3) MUSTER (SET's ",2"): a man of another lord's militia or retinue, on the way to its muster and on its march.
 * The rule gives such a man 3 on a friend (the call-up's pace) where the host's walks; the core used to take that back
 * by lowering every man's Speed until the squad's MEAN speed was the host's (lanes 38 and 48, "musterPace"): equal
 * speed, so a squad that was behind stayed behind (h2: 9.5 m at the host's own pace; k2-k4: the retinue 10 m, 3 s
 * late), and it took the catch-up back too. Now such a man's factor is this rule's alone, whatever the game's rule
 * said: 1 at his place, up to PACE_MAX_MUS when he is far (a host man who runs in from his home at 3). */
#define PACE_MAX_MUS   3.0
typedef void (*pace_fn)(void *comp, uint32_t squad);
typedef uint8_t *(*pace_find_fn)(void *comp, uint32_t squad);
static void pace_wrap(void *comp, uint32_t squad)
{
    ((pace_fn)(void *)MV.p_tramp)(comp, squad);
    if (!MV.enabled || MV.pace_off || MV.n == 0) return;
    if (GetCurrentThreadId() != MV.thread) { MV.pother++; return; }
    {
        LARGE_INTEGER t0, t1; QueryPerformanceCounter(&t0);
        __try {
            uint8_t *sq = ((pace_find_fn)MV.p_find)(comp, squad);
            MV.pcalls++;
            if (sq) {
                int n = *(const int32_t *)(sq + 0x20), i; uint8_t **men = *(uint8_t ***)(sq + 0x18);
                if (men && n > 0 && n <= 4096)
                    for (i = 0; i < n; i++) {
                        ment *e = men_find((uintptr_t)men[i]);
                        if (e && (e->flags & MF_HOLD) && (men[i][0x3B4] == 0 || e->follow == 2)) {
                            float *f = (float *)(men[i] + MEN_FACTOR_OFF), want = 1.0f;
                            double top = e->follow == 2 ? PACE_MAX_MUS : PACE_MAX;
                            if (e->follow && MV.hoff && !MV.catch_off) {
                                const double *rp = (const double *)(men[i] + MV.hoff);
                                double dx = rp[0] - e->ht[0], dy = rp[1] - e->ht[1], d2 = dx * dx + dy * dy;
                                /* (round 3) how far he is behind: his distance to the place. A place the host LED (sent ahead
                                 * of a running man) comes without the mark and so without catch-up: read as "6 m behind" it
                                 * made a runner run at 1.5 (the lead's lc53_3: 41 to 43 against the host's 31, 5.5 m off the
                                 * track at a turn; v4, v5: 7 m ahead at the charge's start). From 0.5 m on, rising:
                                 * +0.5 over 2 m (a muster: +2 over 4 m). The first form began at 3 m and left a squad walking
                                 * 3 m beside its place for 5 s (r1: the militia 3.0/3.4). */
                                double g = sqrt(d2) - PACE_NEAR_CM;   /* (a led place carries no catch-up mark: coop_x_men.lua) */
                                if (g > 0) { double r = 1.0 + g / (e->follow == 2 ? 200.0 : 400.0); want = (float)(r > top ? top : r); MV.sped++; }
                            }
                            if ((*f < 3.0f || e->follow == 2) && *f != want) { *f = want; MV.raised++; if (e->follow == 2) MV.mustered++; }
                        }
                    }
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) { men_fault(GetExceptionCode()); }
        QueryPerformanceCounter(&t1); MV.qpace += t1.QuadPart - t0.QuadPart;
    }
}

/* stub (at the page start): mov rax,<men_wrap>; jmp rax. Trampoline (+20h): the entry's first 8 bytes; jmp [rip+0] -> entry+8 */
static int men_make_stub(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize), *resume;
    void *fn = (void *)&men_wrap;
    size_t n = 0;
    int32_t rel;
    DWORD old;
    if (!p) return 0;
    resume = MV.entry + MEN_HOOK_LEN;
    p[n++] = 0x48; p[n++] = 0xB8; memcpy(p + n, &fn, 8); n += 8; p[n++] = 0xFF; p[n++] = 0xE0;
    n = 0x20;
    memcpy(p + n, MEN_ORIG, MEN_HOOK_LEN); n += MEN_HOOK_LEN;
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0;
    memcpy(p + n, &resume, 8); n += 8;
    /* lane 52 round 2, PACE: +40h mov rax,<pace_wrap>; jmp rax. +60h its entry's three pushes; jmp [rip+0] -> entry+5 */
    if (MV.pace_avail) {
        void *pf = (void *)&pace_wrap; uint8_t *pres = MV.p_entry + 5; int32_t prel; size_t k = 0x40;
        p[k++] = 0x48; p[k++] = 0xB8; memcpy(p + k, &pf, 8); k += 8; p[k++] = 0xFF; p[k++] = 0xE0;
        k = 0x60; memcpy(p + k, PACE_ORIG, 5); k += 5;
        p[k++] = 0xFF; p[k++] = 0x25; p[k++] = 0; p[k++] = 0; p[k++] = 0; p[k++] = 0;
        memcpy(p + k, &pres, 8);
        prel = (int32_t)((intptr_t)(p + 0x40) - (intptr_t)(MV.p_entry + 5));
        MV.p_jmp[0] = 0xE9; memcpy(MV.p_jmp + 1, &prel, 4); memcpy(MV.p_jmp + 5, PACE_ORIG + 5, 3);
        MV.p_tramp = p + 0x60;
    }
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    rel = (int32_t)((intptr_t)p - (intptr_t)(MV.entry + 5));
    MV.jmp[0] = 0xE9; memcpy(MV.jmp + 1, &rel, 4); MV.jmp[5] = 0x90; MV.jmp[6] = 0x90; MV.jmp[7] = 0x90;
    MV.stub = p; MV.tramp = p + 0x20;
    log_line("MEN: stub at %p (%Iu bytes)", (void *)p, n);
    return 1;
}

static void men_forget(void) { if (MV.n) MV.forgets++; MV.n = 0; memset(MV.e, 0, sizeof(MV.e)); }
static void men_unhook(void)
{
    char w[160];
    int r;
    InterlockedExchange(&MV.enabled, 0);
    if (!MV.avail || !MV.stub) return;
    if (pace_bytes_on()) {
        r = write_bytes(MV.p_entry, MV.p_jmp, PACE_ORIG, PACE_HOOK_LEN, w, sizeof(w));
        if (r != 1) { log_line("MEN: the pace rule could not be restored: %s", w); if (r < 0) internal_failure("men pace restore failed"); }
    }
    if (memcmp(MV.entry, MV.jmp, MEN_HOOK_LEN) == 0) {
        r = write_bytes(MV.entry, MV.jmp, MEN_ORIG, MEN_HOOK_LEN, w, sizeof(w));
        if (r != 1) { log_line("MEN: MPATH could not be restored: %s", w); if (r < 0) internal_failure("men restore failed"); }
        else log_line("MEN hook out");
    }
    g_dirty = 1;
}
/* ALLOFF and going off: the hook out, the table emptied */
static void men_off(void) { men_unhook(); men_forget(); }

/* lane 52 round 2: the pace rule's entry (with MEN HOOK ON; out with the hook). A refusal leaves MEN as it was before PACE. */
static void pace_hook_in(void)
{
    char w[160];
    int r;
    if (!MV.pace_avail || !MV.p_tramp || pace_bytes_on()) return;
    if (memcmp(MV.p_entry, PACE_ORIG, PACE_HOOK_LEN) != 0) { MV.pace_avail = 0; _snprintf(MV.pace_why, sizeof(MV.pace_why), "its entry holds unknown bytes"); log_line("MEN: pace rule not hooked: %s", MV.pace_why); return; }
    r = write_bytes(MV.p_entry, PACE_ORIG, MV.p_jmp, PACE_HOOK_LEN, w, sizeof(w));
    if (r != 1) { MV.pace_avail = 0; _snprintf(MV.pace_why, sizeof(MV.pace_why), "%s", w); log_line("MEN: pace rule not hooked: %s", w); if (r < 0) internal_failure("men pace hook write failed"); return; }
    log_line("MEN: pace rule hooked at %p", (void *)MV.p_entry);
}
static void men_hook(int on)
{
    char w[160];
    int r;
    g_dirty = 1;
    if (!on) { men_off(); return; }
    if (!MV.avail) { log_line("MEN HOOK ON refused: unavailable (%s)", MV.why); MV.refused++; return; }
    if (!MV.stub && !men_make_stub()) { MV.avail = 0; _snprintf(MV.why, sizeof(MV.why), "no free memory near the game module for the stub"); log_line("MEN HOOK ON refused: %s", MV.why); return; }
    MV.thread = GetCurrentThreadId();
    InterlockedExchange(&MV.want_off, 0);
    if (men_bytes_on()) { InterlockedExchange(&MV.enabled, 1); pace_hook_in(); log_line("MEN already hooked"); return; }
    if (!men_bytes_off()) { MV.avail = 0; _snprintf(MV.why, sizeof(MV.why), "MPATH holds neither its own bytes nor this DLL's jump"); log_line("MEN HOOK ON refused: %s", MV.why); return; }
    InterlockedExchange(&MV.enabled, 1);
    r = write_bytes(MV.entry, MEN_ORIG, MV.jmp, MEN_HOOK_LEN, w, sizeof(w));
    if (r != 1) {
        InterlockedExchange(&MV.enabled, 0);
        MV.avail = 0; _snprintf(MV.why, sizeof(MV.why), "%s", w);
        log_line("MEN HOOK ON FAILED: %s; item marked unavailable", w);
        if (r < 0) internal_failure("men hook write failed");
        return;
    }
    log_line("MEN hooked: MPATH %p", (void *)MV.entry);
    pace_hook_in();
}

/* ---------------------------------------------------------------- GO: the game's own routine for one man, now */
static int men_force;      /* (lane 52, round 3) 1 while REGO or the GO of a man who stood up runs: given whatever he does */
static int men_go(ment *e)
{
    uint8_t rec[MEN_REC], list[16];
    char why[200];
    int ok = 0;
    LARGE_INTEGER t0, t1;
    if (!comp_sane(e->a, MEN_MAN_BYTES, why, sizeof(why))) { MV.gofail++; return 0; }
    QueryPerformanceCounter(&t0);
    __try {
        /* tickSquad gives no slot to a man whose +CE0h is set; updateSquadAI's four calls do not test it (a man in a
         * fight may have it): counted, not refused */
        /* lane 52, round 2: the routine leaves at once for a man whose byte +E3Ch is set (he sits, or is busy): a GO
         * then is lost and he stays where he is. Not given now: noted, and given the moment the byte clears (men_landwatch) */
        if (*(const uint8_t *)(e->a + 0xE3C) != 0) { if (!(e->fired & 4)) MV.e3cwait++; e->fired |= 4; QueryPerformanceCounter(&t1); MV.qgo += t1.QuadPart - t0.QuadPart; return 0; }
        if (*(const uint64_t *)(e->a + MEN_SKIP_OFF) != 0) MV.ce0++;
        /* (lane 52, round 3) a man who STANDS and was given a way under a second ago gets no new one yet: his place
         * stays noted and is given with the next SET after that second. A new request every quarter second kept such
         * a man standing for as long as his host twin walked (s1, s2: 14 and 10 of another lord's militia at their
         * homes at the call-up, "real=0.00 path n=15 at=1", a GO every 0.25 s for 10 to 22 s; the player's militia man
         * who stood at his home in d1 and s3). A walking man is given every place at once.
         * Only for a man of another lord's muster (SET's ",2"). For every held man (t1-t5) it cost the player's militia
         * its place on the charge: a man who paused at a bend waited out the second, the squad fell 10 m behind and cut
         * the bend at 1.5 (largest 5.9, 5.0, 4.7 m against 1.3 to 2.7 m without the rule, s1-s5). */
        if (MV.hoff && !men_force && e->follow == 2 && (e->flags & MF_GIVEN) && GetTickCount() - e->tgo < 1000 && *(const float *)(e->a + 0x594) < 1.0f) { MV.stood++; QueryPerformanceCounter(&t1); MV.qgo += t1.QuadPart - t0.QuadPart; return 0; }
        {
            memset(rec, 0, sizeof(rec)); memset(list, 0, sizeof(list));
            memcpy(rec + 8, e->ht, 24);
            memcpy(rec + 0x58, MV.k1, 16);
            memcpy(rec + 0x68, MV.k2, 8);
            *(uint32_t *)(rec + 0x70) = 0x4CBEBC20u;               /* 1e8f, as every caller writes */
            *(uint64_t *)(rec + 0x74) = 0xFFFFFFFFFFFFFFFFull;
            rec[0x7E] = e->lvl;
            MV.own++;
            ((mpath_fn)(void *)MV.entry)((void *)e->a, rec, 0, list);    /* through the hook when it is in: the same place */
            MV.own--;
            if (e->pend) MV.supers++;   /* lane 52: a GO while the last one has not become his path yet */
            memcpy(e->given, e->ht, sizeof(e->given)); e->flags |= MF_GIVEN; e->tgo = GetTickCount(); e->pend = 1;
            MV.gos++; ok = 1;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        MV.own = 0; MV.faults++; MV.gofail++;
        log_line("MEN GO of %IX raised exception %08lX: hook out, table emptied, item unavailable", e->a, GetExceptionCode());
        men_off(); MV.avail = 0; _snprintf(MV.why, sizeof(MV.why), "exception %08lX in a GO", GetExceptionCode());
        return 0;
    }
    QueryPerformanceCounter(&t1); MV.qgo += t1.QuadPart - t0.QuadPart;
    return ok;
}

/* ---------------------------------------------------------------- commands */
static int men_hex(const char *s, uintptr_t *a)
{
    unsigned long long v = 0;
    char *end;
    if (!s || !*s) return 0;
    v = _strtoui64(s, &end, 16);
    if (*end || v == 0 || (v & 7)) return 0;
    *a = (uintptr_t)v;
    return 1;
}
/* MEN SET <hex>=<x>,<y>,<z>;...  (friend) */
static void men_set(const char *arg)
{
    char buf[MAX_LINE], *p, *next;
    if (strlen(arg) >= sizeof(buf)) { MV.refused++; return; }
    strcpy(buf, arg);
    MV.sets++;
    for (p = buf; p && *p; p = next) {
        char *eq, *end; uintptr_t a; double v[3]; int k, fol; ment *e;
        next = strchr(p, ';'); if (next) *next++ = 0;
        eq = strchr(p, '='); if (!eq) { MV.refused++; continue; }
        *eq = 0;
        if (!men_hex(p, &a)) { MV.refused++; continue; }
        end = eq + 1;
        for (k = 0; k < 3; k++) { v[k] = strtod(end, &end); if (k < 2) { if (*end != ',') break; end++; } }
        fol = 0; if (k == 3 && end[0] == ',' && (end[1] == '1' || end[1] == '2') && end[2] == 0) { fol = end[1] - '0'; end += 2; }
        if (k < 3 || *end || !(v[0] == v[0]) || fabs(v[0]) > 1e8 || fabs(v[1]) > 1e8 || fabs(v[2]) > 1e8) { MV.refused++; continue; }
        e = men_add(a); if (!e) continue;
        e->follow = (uint8_t)fol;
        e->flags |= MF_HOLD; e->flags &= (uint8_t)~MF_TRACE; memcpy(e->ht, v, sizeof(v)); e->tset = GetTickCount();
        MV.setmen++;
        if (MV.enabled && (!(e->flags & MF_GIVEN) || men_d2(e->ht, e->given) >= MEN_GO_CM * MEN_GO_CM)) {
            if (!men_go(e)) { if (!MV.avail) return; }
        }
    }
}
static void men_list(const char *arg, int what)   /* what: 1 = WATCH, 2 = UNWATCH, 3 = DROP, 4 = LET (lane 52) */
{
    char buf[MAX_LINE], *p, *next;
    if (strlen(arg) >= sizeof(buf)) { MV.refused++; return; }
    strcpy(buf, arg);
    for (p = buf; p && *p; p = next) {
        uintptr_t a; int f, i;
        next = strchr(p, ','); if (next) *next++ = 0;
        if (!men_hex(p, &a)) { MV.refused++; continue; }
        if (what == 1) { ment *e = men_add(a); if (e && !(e->flags & MF_WATCH)) { e->flags |= MF_WATCH; e->flags &= (uint8_t)~(MF_SEEN | MF_SENT); } continue; }
        i = men_pos(a, &f); if (!f) continue;
        if (what == 2) { MV.e[i].flags &= (uint8_t)~(MF_WATCH | MF_SEEN | MF_SENT | MF_HERE | MF_SANE); if (!MV.e[i].flags || MV.e[i].flags == MF_GIVEN) men_del(i); }
        /* lane 52: let go (his own requests pass again, as after a DROP) but still watched by the run-off check, which
         * keeps his last host place; the next SET holds him again with a GO at once (GIVEN cleared, as a new man) */
        else if (what == 4) { if (MV.e[i].flags & MF_HOLD) { MV.e[i].flags &= (uint8_t)~(MF_HOLD | MF_GIVEN); MV.e[i].flags |= MF_TRACE; MV.lets++; } }
        else { men_del(i); MV.drops++; }
    }
}
/* lane 48: HERE, the watched men's own places (host). MEN HEREAT <hex> gives where a man's own place lies (SMUnit.realPos,
 * 3 doubles, cm: the offset of the reflected property, sent by the Lua; 0 = off). Then every POLL adds, for each watched
 * man (the Lua's watch list is the core's squad lists of this round) whose own place moved MEN_HERE_CM or more since it
 * was last written, "H <hex> <x> <y> <z>". A man is read only when his memory was committed and readable when first
 * read and his first qword is a vtable in the game module (checked at every read), always under SEH; a fault or a bad
 * value skips him (and the full check runs again). Lane 43's round 2 read these places through the mod loader: tens of
 * microseconds a man, host ticks of 50-72 ms; here a few nanoseconds a man. */
#define MEN_HERE_CM    100.0
static void men_hereat(const char *arg)
{
    char *end; unsigned long v = strtoul(arg, &end, 16);
    if (*end || (v != 0 && (v + 24 > MEN_MAN_BYTES || (v & 7)))) { MV.refused++; log_line("MEN HEREAT refused: %s", arg); return; }
    MV.hoff = (uint32_t)v; log_line("MEN HEREAT %X", MV.hoff);
}
static int men_here_feed(char *out, int n, int cap)
{
    int i;
    LARGE_INTEGER t0, t1;
    if (!MV.hoff) return n;
    QueryPerformanceCounter(&t0);
    MV.heres++;
    for (i = 0; i < MV.n; i++) {
        ment *e = &MV.e[i]; double q[3]; uintptr_t vt = 0; char why[200];
        if (!(e->flags & MF_WATCH)) continue;
        if (!(e->flags & MF_SANE)) { if (!comp_sane(e->a, MV.hoff + 24, why, sizeof(why))) { MV.herebad++; continue; } e->flags |= MF_SANE; }
        __try { vt = *(const uintptr_t *)e->a; memcpy(q, (const void *)(e->a + MV.hoff), sizeof(q)); }
        __except (EXCEPTION_EXECUTE_HANDLER) { MV.faults++; e->flags &= (uint8_t)~MF_SANE; continue; }
        if (vt < (uintptr_t)g_base || vt >= (uintptr_t)g_base + g_imgsize || (vt & 7) ||
            !(q[0] == q[0]) || !(q[1] == q[1]) || !(q[2] == q[2]) || fabs(q[0]) > 1e8 || fabs(q[1]) > 1e8 || fabs(q[2]) > 1e8) { MV.herebad++; e->flags &= (uint8_t)~MF_SANE; continue; }
        if ((e->flags & MF_HERE) && men_d2(q, e->here) < MEN_HERE_CM * MEN_HERE_CM) continue;
        if (n > cap - 96) break;
        n += _snprintf(out + n, (size_t)(cap - n), "H %IX %.0f %.0f %.0f", e->a, q[0], q[1], q[2]);
        /* (lane 52, round 3) and the point of his way he walks to now (SMUnit.Path[PathPoint]), when he has one: the
         * Lua leads a running man's place ALONG his way, never past that point (a lead straight on at a bend of the
         * way sent the friend's man off the host's track: the militia 4.4 to 5.5 m at the same bend, r2, lc53_3) */
        if (MV.hoff + 24 <= MEN_PATH_OFF && comp_sane(e->a, MEN_PATH_OFF + 0x18, why, sizeof(why))) {
            __try {
                const uint8_t *pd = *(const uint8_t *const *)(e->a + MEN_PATH_OFF); int pn = *(const int32_t *)(e->a + MEN_PATH_OFF + 8), pp = *(const int32_t *)(e->a + MEN_PATH_OFF + 0x10);
                if (pd && pn > 0 && pn < 4096 && pp >= 0 && pp < pn && range_readable(pd + (size_t)pp * 0x88, 0x88)) {
                    const double *pc = (const double *)(pd + (size_t)pp * 0x88 + 8);
                    if (pc[0] == pc[0] && pc[1] == pc[1] && fabs(pc[0]) < 1e8 && fabs(pc[1]) < 1e8) n += _snprintf(out + n, (size_t)(cap - n), " %.0f %.0f", pc[0], pc[1]);
                }
            } __except (EXCEPTION_EXECUTE_HANDLER) { MV.faults++; }
        }
        n += _snprintf(out + n, (size_t)(cap - n), "\r\n");
        memcpy(e->here, q, sizeof(e->here)); e->flags |= MF_HERE;
        MV.herelines++;
    }
    QueryPerformanceCounter(&t1); MV.qhere += t1.QuadPart - t0.QuadPart;
    return n;
}
static void men_poll(void)
{
    wchar_t path[MAX_PATH];
    static char out[MEN_MAX * 48 + MEN_MAX * 80 + 128];
    int n = 0, i;
    HANDLE h; DWORD wr;
    LARGE_INTEGER t0, t1; QueryPerformanceCounter(&t0);
    MV.polls++;
    for (i = 0; i < MV.n; i++) {
        ment *e = &MV.e[i];
        if ((e->flags & (MF_WATCH | MF_SEEN)) != (MF_WATCH | MF_SEEN)) continue;
        if ((e->flags & MF_SENT) && men_d2(e->seen, e->sent) < MEN_STEP_CM * MEN_STEP_CM) continue;
        if (n > (int)sizeof(out) - 64) break;
        n += _snprintf(out + n, sizeof(out) - (size_t)n, "%IX %.0f %.0f %.0f\r\n", e->a, e->seen[0], e->seen[1], e->seen[2]);
        memcpy(e->sent, e->seen, sizeof(e->sent)); e->flags |= MF_SENT;
        MV.lines++;
    }
    n = men_here_feed(out, n, (int)sizeof(out));   /* lane 48 */
    MV.outbytes += (unsigned long long)n;
    /* written in place (no temporary file and rename: 1.5 ms a poll in the game, sitting f1): the Lua reads it right
     * after this tick, on the same thread */
    /* (lane 48, round 2) the file is kept open and written from its start (lane 47's way for its answer): opening and
     * closing it each round was part of the host's longest poll steps */
    {
        static HANDLE hk = INVALID_HANDLE_VALUE;
        if (hk == INVALID_HANDLE_VALUE) {
            join_path(path, g_dir, L"men_out.txt");
            hk = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        }
        h = hk;
        if (h != INVALID_HANDLE_VALUE) {
            if (SetFilePointer(h, 0, NULL, FILE_BEGIN) == INVALID_SET_FILE_POINTER || !WriteFile(h, out, (DWORD)n, &wr, NULL) || !SetEndOfFile(h)) { CloseHandle(h); hk = INVALID_HANDLE_VALUE; }
        }
    }
    QueryPerformanceCounter(&t1); MV.qpoll += t1.QuadPart - t0.QuadPart;
}


/* lane 48, REGO (friend): a held man who stands MEN_REGO_CM or more from the host's place he was given, and has asked
 * for no path for MEN_REGO_IDLE ms (and had no GO for as long), is given it again with the game's routine (a GO). Why
 * (sitting t7): after the call-up the friend's militia stood in a line 6.7 m from the host's for the whole rest with
 * all its men held: a GO given while the call-up's own behaviour still had the men was lost, and the next host places
 * moved under MEN_GO_CM, so none was given again. His own place: SMUnit.realPos at the HEREAT offset (the Lua sends
 * it on the friend too), read under SEH after the same check as HERE. Four times a second at most. MEN REGO OFF|ON:
 * the console's test switch (on by default). */
#define MEN_REGO_CM    200.0
#define MEN_REGO_IDLE  1500
static void men_rego(void)
{
    uint32_t now = GetTickCount();
    int i;
    if (MV.rego_off || !MV.hoff || !MV.enabled || MV.n == 0 || now - MV.rego_t < 250) return;
    if (GetCurrentThreadId() != MV.thread) return;
    MV.rego_t = now;
    for (i = 0; i < MV.n; i++) {
        ment *e = &MV.e[i]; double q[3]; uintptr_t vt = 0; char why[200];
        if ((e->flags & (MF_HOLD | MF_GIVEN)) != (MF_HOLD | MF_GIVEN)) continue;
        if (now - e->tcall < MEN_REGO_IDLE || now - e->tgo < MEN_REGO_IDLE) continue;
        MV.regolooks++;
        if (!(e->flags & MF_SANE)) { if (!comp_sane(e->a, MV.hoff + 24, why, sizeof(why))) continue; e->flags |= MF_SANE; }
        __try { vt = *(const uintptr_t *)e->a; memcpy(q, (const void *)(e->a + MV.hoff), sizeof(q)); }
        __except (EXCEPTION_EXECUTE_HANDLER) { MV.faults++; e->flags &= (uint8_t)~MF_SANE; continue; }
        if (vt < (uintptr_t)g_base || vt >= (uintptr_t)g_base + g_imgsize || !(q[0] == q[0]) || !(q[1] == q[1])) { e->flags &= (uint8_t)~MF_SANE; continue; }
        if ((q[0] - e->ht[0]) * (q[0] - e->ht[0]) + (q[1] - e->ht[1]) * (q[1] - e->ht[1]) < MEN_REGO_CM * MEN_REGO_CM) continue;
        e->tgo = now;   /* at most once per idle span, also when the GO fails */
        men_force = 1; if (men_go(e)) { men_force = 0; MV.regos++; } else { men_force = 0; if (!MV.avail) return; }
    }
}

/* lane 52, RUN-OFF CHECK (friend): a man held (or let go at an order, MF_TRACE, and given a place in the last 2 s) who
 * stands more than MEN_RO_CM from the host's place he was last given for MEN_RO_MS, and has not come 3 m closer to it meanwhile, is counted (runoffs=, rlast= in the
 * status line) and, for the first MEN_RO_DUMPS times a session, written out with one healthy held man beside him into
 * men_diag.txt: his place, speeds, stamina, the path he walks (SMUnit.Path +7D0h: entries 0x88 bytes, the point at +8;
 * PathPoint +7E0h), the place the squad's own AI keeps for him (+BD8h), the bytes the path routine tests (+E3Ch,
 * +CE0h) and every path request of his in the last 3 s from the ring (who asked: the caller's address in the game file;
 * substituted or passed; the place asked; the last 5 s). Four times a second, with REGO. Reads: under SEH, after the same check as
 * HERE (committed, a vtable of the game module). A traced man with no SET for 3 s leaves the table. */
#define MEN_RO_CM      1500.0
#define MEN_RO6_CM     600.0       /* lane 52 round 2: the same check at 6 m, counted apart (ro6=): a lag like b5's (5 to 9 m for seconds) */
#define MEN_RO_MS      2000
#define MEN_RO_DUMPS   40
#define MEN_TRACE_MS   3000
static int men_read_pos(ment *e, double *q)
{
    uintptr_t vt = 0; char why[200];
    if (!(e->flags & MF_SANE)) { if (!comp_sane(e->a, MEN_MAN_BYTES, why, sizeof(why))) return 0; e->flags |= MF_SANE; }
    __try { vt = *(const uintptr_t *)e->a; memcpy(q, (const void *)(e->a + MV.hoff), 24); }
    __except (EXCEPTION_EXECUTE_HANDLER) { MV.faults++; e->flags &= (uint8_t)~MF_SANE; return 0; }
    if (vt < (uintptr_t)g_base || vt >= (uintptr_t)g_base + g_imgsize || !(q[0] == q[0]) || !(q[1] == q[1]) || fabs(q[0]) > 1e8 || fabs(q[1]) > 1e8) { e->flags &= (uint8_t)~MF_SANE; return 0; }
    return 1;
}
static double men_dxy(const double *a, const double *b) { double x = a[0] - b[0], y = a[1] - b[1]; return sqrt(x * x + y * y); }
static uint32_t men_ring_win = 5000;    /* lane 52: how far back a dump lists his requests (ms) */
static int men_dump_man(char *out, int n, int cap, const char *tag, ment *e, uint32_t now)
{
    const uint8_t *m = (const uint8_t *)e->a;
    int k;
    if (n > cap - 2048) return n;
    __try {
        const double *rp = (const double *)(m + MV.hoff), *bd = (const double *)(m + 0xBD8);
        const uint8_t *pd = *(const uint8_t *const *)(m + 0x7D0); int pn = *(const int32_t *)(m + 0x7D8), pp = *(const int32_t *)(m + 0x7E0);
        n += _snprintf(out + n, (size_t)(cap - n),
            "%s man=%IX flags=%02X d=%.0f pos=%.0f,%.0f,%.0f host=%.0f,%.0f,%.0f given=%.0f,%.0f,%.0f lvl=%u floor=%u\r\n"
            "  speed=%.2f real=%.2f factor=%.3f velo=%.2f lpath=%.1f stamina=%.3f def=%.2f block=%.2f sprint=%u e3c=%u ce0=%llX ai=%.0f,%.0f,%.0f ailvl=%u\r\n"
            "  ages ms: call=%u go=%u set=%u far=%u  path n=%d at=%d",
            tag, e->a, e->flags, men_dxy(rp, e->ht), rp[0], rp[1], rp[2], e->ht[0], e->ht[1], e->ht[2], e->given[0], e->given[1], e->given[2], e->lvl, m[0x5B0],
            *(const float *)(m + 0x590), *(const float *)(m + 0x594), *(const float *)(m + 0x5A8), *(const float *)(m + 0x6F8), *(const float *)(m + 0x3B0),
            *(const float *)(m + 0x928), *(const float *)(m + 0x8FC), *(const float *)(m + 0x910), m[0x994], m[0xE3C], (unsigned long long)*(const uint64_t *)(m + MEN_SKIP_OFF),
            bd[0], bd[1], bd[2], m[0xBF0],
            e->tcall ? now - e->tcall : 0, e->tgo ? now - e->tgo : 0, e->tset ? now - e->tset : 0, e->tfar ? now - e->tfar : 0, pn, pp);
        if (pd && pn > 0 && pn < 4096 && range_readable(pd, (size_t)pn * 0x88)) {
            const double *p0 = (const double *)(pd + 8), *pe = (const double *)(pd + (size_t)(pn - 1) * 0x88 + 8);
            double len = 0; int j;
            for (j = (pp > 0 && pp < pn ? pp : 0); j + 1 < pn; j++) len += men_dxy((const double *)(pd + (size_t)j * 0x88 + 8), (const double *)(pd + (size_t)(j + 1) * 0x88 + 8));
            n += _snprintf(out + n, (size_t)(cap - n), " first=%.0f,%.0f end=%.0f,%.0f end-host=%.0f left=%.0f", p0[0], p0[1], pe[0], pe[1], men_dxy(pe, e->ht), len);
            if (pp >= 0 && pp < pn) { const double *pc = (const double *)(pd + (size_t)pp * 0x88 + 8); n += _snprintf(out + n, (size_t)(cap - n), " cur=%.0f,%.0f", pc[0], pc[1]); }
        }
        { const double *ds = (const double *)(m + MEN_DEST_OFF); n += _snprintf(out + n, (size_t)(cap - n), " dest=%.0f,%.0f far6=%u\r\n", ds[0], ds[1], e->tfar6 ? now - e->tfar6 : 0); }
    } __except (EXCEPTION_EXECUTE_HANDLER) { MV.faults++; n += _snprintf(out + n, (size_t)(cap - n), "  (read fault)\r\n"); }
    /* his path requests of the last 5 s, oldest first */
    for (k = MEN_RING; k >= 1; k--) {
        unsigned long long idx; mring *r;
        if ((unsigned long long)k > men_ringn) continue;
        idx = men_ringn - (unsigned long long)k; r = &men_ring[idx % MEN_RING];
        if (r->man != e->a || now - r->t > (r->kind == 2 ? 5000u : men_ring_win)) continue;
        if (n > cap - 128) break;
        n += _snprintf(out + n, (size_t)(cap - n), "  req -%ums %s by %X at %.0f,%.0f,%.0f\r\n", now - r->t, r->kind == 2 ? "GO" : r->kind == 3 ? "kept" : r->kind == 1 ? "subst" : "PASSED", r->ret, r->x, r->y, r->z);
    }
    return n;
}
static void men_runoff(void)
{
    uint32_t now = GetTickCount(), step;
    int i;
    if (!MV.hoff || !MV.enabled || MV.n == 0 || now - MV.ro_t < 250) return;
    if (GetCurrentThreadId() != MV.thread) return;
    step = MV.ro_t ? now - MV.ro_t : 0; if (step > 1000) step = 1000;
    MV.ro_t = now;
    for (i = 0; i < MV.n; i++) {
        ment *e = &MV.e[i]; double q[3], d; int big = 0, six = 0;
        if (!(e->flags & (MF_HOLD | MF_TRACE))) continue;
        if (!(e->flags & MF_HOLD) && now - e->tset > MEN_TRACE_MS) {   /* traced, no word of the host's for 3 s: out */
            e->flags &= (uint8_t)~MF_TRACE; if (!(e->flags & ~(MF_GIVEN | MF_SANE))) { men_del(i); i--; } continue;
        }
        if (!men_read_pos(e, q)) continue;
        d = men_dxy(q, e->ht);
        /* lane 52 round 2: a man who sits or is busy (+E3Ch set: the path request leaves at once for him, his GO waits
         * until it clears) cannot walk: not a man held off his place. Counted apart once per sitting-down (seated=).
         * His clocks STAND while the byte is set (they are not started again: a byte that flickers must not hide a man
         * who is off his place for 2 s of the time he could walk). */
        {
            uint8_t busy = 0;
            __try { busy = *(const uint8_t *)(e->a + MEN_BUSY_OFF); } __except (EXCEPTION_EXECUTE_HANDLER) { MV.faults++; e->flags &= (uint8_t)~MF_SANE; continue; }
            if (busy) { if (d > MEN_RO6_CM && !(e->fired & 16)) { e->fired |= 16; MV.seated++; } if (e->tfar) e->tfar += step; if (e->tfar6) e->tfar6 += step; continue; }
            e->fired &= (uint8_t)~16;
        }
        /* the 6 m check (the same rule: 2 s over 6 m and not 1.2 m closer in that time). A man on the move follows a
         * place that moves: only when he is also more than 0.8 s of his own speed from it (his speed from his last two
         * places here; a running man 8 m behind the place sent 6 m ahead of the host's man is beside him) */
        if (e->tpos && now - e->tpos >= 200 && now - e->tpos < 2000) e->vel = (float)(sqrt((q[0] - e->px) * (q[0] - e->px) + (q[1] - e->py) * (q[1] - e->py)) * 1000.0 / (double)(now - e->tpos));
        else if (!e->tpos || now - e->tpos >= 2000) e->vel = 0;
        if (!e->tpos || now - e->tpos >= 200) { e->px = (float)q[0]; e->py = (float)q[1]; e->tpos = now; }
        if (d < MEN_RO6_CM * 2 / 3 || d < 0.8 * e->vel * 2 / 3) { e->tfar6 = 0; e->fired &= (uint8_t)~8; }
        else if (d > MEN_RO6_CM && d > 0.8 * e->vel && !(e->fired & 8)) {
            if (!e->tfar6) { e->tfar6 = now; e->dfar6 = (float)d; }
            else if (now - e->tfar6 >= MEN_RO_MS) {
                if (d < e->dfar6 - 120.0) { e->tfar6 = now; e->dfar6 = (float)d; }
                else { e->fired |= 8; MV.ro6++; six = 1; }
            }
        }
        if (d < MEN_RO_CM * 2 / 3) { e->tfar = 0; e->fired &= (uint8_t)~1; }
        else if (d > MEN_RO_CM && !(e->fired & 1)) {
            if (!e->tfar) { e->tfar = now; e->dfar = (float)d; }
            else if (now - e->tfar >= MEN_RO_MS) {
                if (d < e->dfar - 300.0) { e->tfar = now; e->dfar = (float)d; }   /* closing on his place (a camp man walking to a new one): not a run-off; watched again from here */
                else { e->fired |= 1; MV.runoffs++; MV.rlast = e->a; big = 1; }
            }
        }
        if (!big && !six) continue;
        if (MV.diags < MEN_RO_DUMPS) {
            static char out[16384];
            wchar_t path[MAX_PATH]; HANDLE h; DWORD wr; int n = 0, j; ment *ok = NULL;
            for (j = 0; j < MV.n && !ok; j++) { ment *o = &MV.e[j]; double p[3]; if (o != e && (o->flags & MF_HOLD) && men_read_pos(o, p) && men_dxy(p, o->ht) < 300) ok = o; }
            if (big) n += _snprintf(out + n, sizeof(out) - (size_t)n, "== RUNOFF %llu at tick %u (%d men in the table)\r\n", MV.runoffs, now, MV.n);
            else n += _snprintf(out + n, sizeof(out) - (size_t)n, "== RUNOFF6 %llu at tick %u (%d men in the table)\r\n", MV.ro6, now, MV.n);
            n = men_dump_man(out, n, (int)sizeof(out), "OFF ", e, now);
            if (ok) n = men_dump_man(out, n, (int)sizeof(out), "WELL", ok, now);
            join_path(path, g_dir, L"men_diag.txt");
            h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
            if (h != INVALID_HANDLE_VALUE) { WriteFile(h, out, (DWORD)n, &wr, NULL); CloseHandle(h); MV.diags++; }
        }
    }
}

/* lane 52, round 2 (friend): how long after a GO the man's path (SMUnit.Path +7D0h) ends at the place given. Every
 * tick, for held men with a GO not yet seen in their path: landms=<50/<100/<250/<500/<1000/later or never (3 s) ms;
 * supers = GOs given while the one before had not become the path yet. Reads under SEH after the HERE check. */
static void men_landwatch(void)
{
    uint32_t now = GetTickCount();
    int i;
    if (!MV.enabled || MV.n == 0 || GetCurrentThreadId() != MV.thread) return;
    for (i = 0; i < MV.n; i++) {
        ment *e = &MV.e[i]; char why[200]; double end[2] = { 0, 0 }; int ok = 0; uint32_t age;
        if (!(e->flags & MF_HOLD)) { e->pend = 0; e->fired &= (uint8_t)~4; continue; }
        if (e->fired & 4) {   /* a GO not given while +E3Ch was set: given now that it is clear */
            uint8_t busy = 1;
            if (!(e->flags & MF_SANE)) { if (!comp_sane(e->a, MEN_MAN_BYTES, why, sizeof(why))) continue; e->flags |= MF_SANE; }
            __try { busy = *(const uint8_t *)(e->a + 0xE3C); } __except (EXCEPTION_EXECUTE_HANDLER) { MV.faults++; e->flags &= (uint8_t)~MF_SANE; continue; }
            if (busy) continue;
            e->fired &= (uint8_t)~4;
            men_force = 1; if (men_go(e)) { men_force = 0; MV.e3cgos++; } else { men_force = 0; if (!MV.avail) return; }
            continue;
        }
        if (!e->pend) {
            /* a held man whose path ends 15 m or more from the place he was last given, 1 s after it was given: someone
             * else wrote his path (FOREIGN; counted, the first MEN_RO_DUMPS written out with his requests of 60 s) */
            uint32_t last = e->tgo > e->tcall ? e->tgo : e->tcall;
            if (now - last < 1000 || !(e->flags & MF_SANE)) continue;
            __try {
                const uint8_t *pd = *(const uint8_t *const *)(e->a + 0x7D0); int pn = *(const int32_t *)(e->a + 0x7D8);
                if (pd && pn > 0 && pn < 4096) { const double *pe = (const double *)(pd + (size_t)(pn - 1) * 0x88 + 8); end[0] = pe[0]; end[1] = pe[1]; ok = 1; }
            } __except (EXCEPTION_EXECUTE_HANDLER) { MV.faults++; e->flags &= (uint8_t)~MF_SANE; continue; }
            if (!ok || men_dxy(end, e->given) < 1500.0) { e->fired &= (uint8_t)~2; continue; }
            if (e->fired & 2) continue;
            e->fired |= 2; MV.foreign++;
            if (MV.fdiags < MEN_RO_DUMPS) {
                static char out[24576];
                wchar_t path[MAX_PATH]; HANDLE h; DWORD wr; int n = 0;
                n += _snprintf(out + n, sizeof(out) - (size_t)n, "== FOREIGN %llu at tick %u: path end %.0f,%.0f, %.0f cm from his place\r\n", MV.foreign, now, end[0], end[1], men_dxy(end, e->given));
                men_ring_win = 60000; n = men_dump_man(out, n, (int)sizeof(out), "PATH", e, now); men_ring_win = 5000;
                join_path(path, g_dir, L"men_diag.txt");
                h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
                if (h != INVALID_HANDLE_VALUE) { WriteFile(h, out, (DWORD)n, &wr, NULL); CloseHandle(h); MV.fdiags++; }
            }
            continue;
        }
        age = now - e->tgo;
        if (!(e->flags & MF_SANE)) { if (!comp_sane(e->a, MEN_MAN_BYTES, why, sizeof(why))) continue; e->flags |= MF_SANE; }
        __try {
            const uint8_t *pd = *(const uint8_t *const *)(e->a + 0x7D0); int pn = *(const int32_t *)(e->a + 0x7D8);
            if (pd && pn > 0 && pn < 4096) { const double *pe = (const double *)(pd + (size_t)(pn - 1) * 0x88 + 8); end[0] = pe[0]; end[1] = pe[1]; ok = 1; }
        } __except (EXCEPTION_EXECUTE_HANDLER) { MV.faults++; e->flags &= (uint8_t)~MF_SANE; continue; }
        if (ok && men_dxy(end, e->given) < 150.0) {
            MV.land[age < 50 ? 0 : age < 100 ? 1 : age < 250 ? 2 : age < 500 ? 3 : age < 1000 ? 4 : 5]++; MV.landed++; e->pend = 0;
        } else if (age > 3000) { MV.land[5]++; e->pend = 0; }
    }
}

/* tick: a faulted hook is taken out, the table emptied, the item unavailable for the rest of the session */
static void men_tick(void)
{
    if (MV.avail && !MV.want_off) { men_landwatch(); men_rego(); men_runoff(); return; }
    if (!MV.avail || !MV.want_off) return;
    InterlockedExchange(&MV.want_off, 0);
    log_line("MEN: exception %08lX in the hook: hook taken out, table emptied", MV.fault_code);
    men_off();
    MV.avail = 0; _snprintf(MV.why, sizeof(MV.why), "exception %08lX in the hook", MV.fault_code);
    g_dirty = 1;
}

static void men_cmd(int argc, char **argv)
{
    int v;
    if (argc >= 2 && (_stricmp(argv[1], "POLL") == 0 || _stricmp(argv[1], "SET") == 0)) {
        /* the frequent ones: not logged one by one, no status file for them */
        if (!MV.avail) { MV.refused++; return; }
        if (argc == 2 && _stricmp(argv[1], "POLL") == 0) men_poll();
        else if (argc == 3 && _stricmp(argv[1], "SET") == 0) men_set(argv[2]);
        else MV.refused++;
        return;
    }
    g_dirty = 1;
    if (argc == 2 && _stricmp(argv[1], "FORGET") == 0) { men_forget(); log_line("MEN FORGET"); return; }
    if (!MV.avail) { log_line("MEN %s refused: unavailable (%s)", argc >= 2 ? argv[1] : "", MV.why); MV.refused++; return; }
    if (argc == 3 && _stricmp(argv[1], "HOOK") == 0 && on_off(argv[2], &v)) { men_hook(v); return; }
    if (argc == 3 && _stricmp(argv[1], "WATCH") == 0) { men_list(argv[2], 1); return; }
    if (argc == 3 && _stricmp(argv[1], "UNWATCH") == 0) { men_list(argv[2], 2); return; }
    if (argc == 3 && _stricmp(argv[1], "DROP") == 0) { men_list(argv[2], 3); return; }
    if (argc == 3 && _stricmp(argv[1], "LET") == 0) { men_list(argv[2], 4); return; }
    if (argc == 2 && _stricmp(argv[1], "DIAG") == 0) { MV.diags = 0; MV.fdiags = 0; log_line("MEN DIAG: run-off dumps written again (up to %d)", MEN_RO_DUMPS); return; }   /* lane 52: a new budget of dumps (test sittings) */
    if (argc == 3 && _stricmp(argv[1], "HEREAT") == 0) { men_hereat(argv[2]); return; }
    if (argc == 3 && _stricmp(argv[1], "REGO") == 0 && on_off(argv[2], &v)) { MV.rego_off = !v; log_line("MEN REGO %s", v ? "on" : "off"); return; }
    if (argc == 3 && _stricmp(argv[1], "PACE") == 0 && on_off(argv[2], &v)) { MV.pace_off = !v; log_line("MEN PACE %s", v ? "on" : "off"); return; }
    if (argc == 3 && _stricmp(argv[1], "KEEP") == 0 && on_off(argv[2], &v)) { MV.keep_off = !v; log_line("MEN KEEP %s", v ? "on" : "off"); return; }
    if (argc == 3 && _stricmp(argv[1], "CATCH") == 0 && on_off(argv[2], &v)) { MV.catch_off = !v; log_line("MEN CATCH %s", v ? "on" : "off"); return; }
    log_line("MEN: unknown form"); MV.refused++;
}
