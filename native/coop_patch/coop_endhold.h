/* ------------------------------------------------------------------ ENDHOLD (lane 49, round four): a task ends on the host's word
 * (research/2026-11-10-game-probe/lanes/lane_s21_49/report.txt, desk round item 4). Included by coop_patch.c.
 *
 * Why (measured on the samples of seven runs): 73 % of the friend's lasting differences are the SAME task as the host's
 * villager, mostly ended first on the friend's copy (its villager then stands, 40 % / 43 % at speed 4 / 8).
 * READ: the game's end of a unit's task is 4dfb960 (signature ENDTASK: its entry; it clears every task of the unit,
 * gives back what they reserved, sets the task count +8A0h to 0, then lets the unit think again). setTask (4e1cab0)
 * calls it first for the task before; the unit's own task steps call it when a task is done (the work-hit routine
 * 4dc5270, the walk and carry steps 4db0000..4de0000); destroyUnit, a demolish's eraseBuildingReferences, a squad's
 * call-up, a family's removal ... call it from elsewhere.
 *   ENDHOLD ON | OFF            the entry's first 5 bytes ("mov r11,rsp; push rbp; push rsi") move into a stub of
 *                               this DLL (a trampoline runs them and jumps back); every call goes to endhold_wrap.
 *   ENDHOLD SET <ceiling ms> <unit>:<type>:<building>,... | SET <ceiling ms> -     the list, whole (hex). For a unit
 *                               on it whose current task (Tasks[0]) is that type at that target building (0 = any),
 *                               an end called from the unit's own task steps (the return address in the range below)
 *                               is let through and the same task is set again at once with the game's own setTask (a
 *                               copy of the record taken before the end): the unit goes on with it. Every other end
 *                               passes untouched: from setTask (a new task), from outside the task steps (death,
 *                               demolish, call-up, removal), a dead unit (+30Ch), a unit whose first held end of this
 *                               task is longer ago than the ceiling ("expired"; such units counted once in
 *                               "ceilunits"), and the re-set's own end (no recursion). An optional fourth field
 *                               <unit>:<type>:<building>:<n> is the host's start number: a new start of the same task
 *                               at the same building is a new entry (v1 counted the ceiling from the listing and kept
 *                               it over the host's next start of the same task: 1389 to 1768 ends of a sitting passed
 *                               as expired, nearly every remaining early end was a task older than 7.5 s).
 *   ENDHOLD RANGE <lo> <hi>     the callers' range (absolute hex); by default 4db0000..4de0000 of the known build
 *                               (ENDTASK -4B960h .. -1B960h). For the offline test.
 * Known build only; ENDTASK and SETTASK exactly once; the moved bytes checked; an exception in the hook takes the item
 * out (ENDHOLD off). Status: "ENDHOLD on|off n= held= passed= expired= skipped= faults= other=" or "ENDHOLD
 * unavailable <why>". */
#define EH_LEN       5
#define EH_MAX       512                /* open addressing, by unit address */
#define EH_REC       0xD8
#define EH_TASKS     0x898
#define EH_DEAD      0x30C
#define EH_TB        0x98               /* FTask.targetBuilding */
static const uint8_t EH_ORIG[EH_LEN] = { 0x4C, 0x8B, 0xDC, 0x55, 0x56 };
typedef uint64_t (*eh_fn)(uint8_t *unit, uint64_t a2, uint64_t a3, uint64_t a4);
typedef void (*eh_settask_fn)(uint8_t *unit, const uint8_t *rec);
typedef struct { uint8_t *unit; uint64_t bld; int type; unsigned seq; ULONGLONG first; unsigned held; int exp; } eh_ent;   /* first: the unit's first held end of this task (0: none yet) */
static struct {
    int avail; char why[160];
    uint8_t *entry, *stub, *tramp; eh_settask_fn settask;
    uint8_t jmp[EH_LEN];
    volatile LONG enabled; DWORD thread; int inset;
    uint64_t lo, hi, extra; ULONGLONG ceil_ms;      /* extra: the return address of the end-and-notify wrapper's call (4dfbe90) */
    eh_ent t[EH_MAX]; int n;
    uint8_t rec[EH_REC];
    unsigned held, passed, expired, skipped, faults, other, sets, bad, ceilunits, skt, skb;
    unsigned ceilty[64];                        /* the units released at the ceiling, by task type */
    uint64_t outret[12]; unsigned outn[12];     /* the callers outside the range that ended a listed task (diagnosis) */
} EH;
static volatile uint64_t g_eh_ret;

static int endhold_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "ENDHOLD unavailable dll is off\r\n");
    if (!EH.avail) return _snprintf(buf, len, "ENDHOLD unavailable %s\r\n", EH.why);
    {
        int n = _snprintf(buf, len, "ENDHOLD %s n=%d held=%u passed=%u expired=%u skipped=%u faults=%u other=%u sets=%u bad=%u ceilunits=%u skt=%u skb=%u\r\nENDHOLDR wrap=%d", EH.enabled ? "on" : "off", EH.n, EH.held, EH.passed, EH.expired, EH.skipped, EH.faults, EH.other, EH.sets, EH.bad, EH.ceilunits, EH.skt, EH.skb, EH.extra ? 1 : 0);
        int k;
        for (k = 0; k < 12 && n > 0 && (size_t)n < len; k++) if (EH.outret[k]) n += _snprintf(buf + n, len - (size_t)n, " %X:%u", (unsigned)(EH.outret[k] - (uint64_t)(uintptr_t)g_base), EH.outn[k]);
        for (k = 0; k < 64 && n > 0 && (size_t)n < len; k++) if (EH.ceilty[k]) n += _snprintf(buf + n, len - (size_t)n, " c%d:%u", k, EH.ceilty[k]);
        if (n > 0 && (size_t)n < len) n += _snprintf(buf + n, len - (size_t)n, "\r\n");
        return n;
    }
}

static int endhold_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    uint8_t *keepstub = EH.stub, *keeptramp = EH.tramp, keepjmp[EH_LEN];
    memcpy(keepjmp, EH.jmp, EH_LEN); memset(&EH, 0, sizeof(EH)); EH.stub = keepstub; EH.tramp = keeptramp; memcpy(EH.jmp, keepjmp, EH_LEN);
    if (!known) _snprintf(EH.why, sizeof(EH.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_ENDTASK].hits != 1) _snprintf(EH.why, sizeof(EH.why), "ENDTASK signature has %d hits (need exactly 1)", g_hit[S_ENDTASK].hits);
    else if (g_hit[S_SETTASK].hits != 1) _snprintf(EH.why, sizeof(EH.why), "SETTASK signature has %d hits (need exactly 1)", g_hit[S_SETTASK].hits);
    else {
        EH.entry = g_base + g_hit[S_ENDTASK].rva;
        EH.settask = (eh_settask_fn)(void *)(g_base + g_hit[S_SETTASK].rva);
        if (memcmp(EH.entry, EH_ORIG, EH_LEN) != 0 && !(EH.stub && EH.entry[0] == 0xE9)) _snprintf(EH.why, sizeof(EH.why), "the end-task entry does not start with its known bytes");
        else if (((uintptr_t)EH.entry & 7) + EH_LEN > 8) _snprintf(EH.why, sizeof(EH.why), "the end-task entry's bytes would cross an 8-byte block");
        else {
            EH.avail = 1;
            EH.lo = (uint64_t)(uintptr_t)EH.entry - 0x4B960; EH.hi = (uint64_t)(uintptr_t)EH.entry - 0x1B960;
            EH.ceil_ms = 7500;
            /* the end-and-notify wrapper right after the end-task (4dfbe90, called by the work-hit routine and
             * animationLoopEnded 4df35d0): its call of the end-task at +0x53D (E8 to the entry); seen as the caller of
             * most natural ends in sitting e1 (245 of 302 out-of-range ends of a listed task) */
            {
                const uint8_t *c = EH.entry + 0x53D; int32_t rel;
                if (range_readable(c, 5) && c[0] == 0xE8) { memcpy(&rel, c + 1, 4); if (c + 5 + rel == EH.entry) EH.extra = (uint64_t)(uintptr_t)(c + 5); }
            }
        }
    }
    log_line("  ENDHOLD %s %s", EH.avail ? "available" : "unavailable", EH.avail ? "" : EH.why);
    return EH.avail;
}

static eh_ent *eh_find(const uint8_t *unit)
{
    unsigned h = (unsigned)(((uintptr_t)unit >> 4) * 2654435761u) % EH_MAX, k;
    for (k = 0; k < EH_MAX; k++) { eh_ent *e = &EH.t[(h + k) % EH_MAX]; if (!e->unit) return NULL; if (e->unit == unit) return e; }
    return NULL;
}

/* every call of the game's end-task comes here (from the stub; its return address in g_eh_ret) */
static uint64_t endhold_wrap(uint8_t *unit, uint64_t a2, uint64_t a3, uint64_t a4)
{
    uint64_t ret = g_eh_ret, r;
    eh_fn tramp = (eh_fn)(void *)EH.tramp;
    eh_ent *e = NULL;
    int hold = 0;
    if (!EH.enabled || EH.inset) return tramp(unit, a2, a3, a4);
    if (GetCurrentThreadId() != EH.thread) { EH.other++; return tramp(unit, a2, a3, a4); }
    if ((ret < EH.lo || ret >= EH.hi) && ret != EH.extra) {
        EH.passed++;
        __try {
            e = eh_find(unit);
            if (e) {
                const uint8_t *data; int32_t cnt; int k, j = -1;
                memcpy(&data, unit + EH_TASKS, 8); memcpy(&cnt, unit + EH_TASKS + 8, 4);
                if (cnt > 0 && cnt < 64 && data && (int)data[0] == e->type) {
                    for (k = 0; k < 12; k++) { if (EH.outret[k] == ret) { j = k; break; } if (!EH.outret[k] && j < 0) j = k; }
                    if (j >= 0) { if (EH.outret[j] != ret) { EH.outret[j] = ret; EH.outn[j] = 0; } EH.outn[j]++; }
                }
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) { EH.faults++; }
        return tramp(unit, a2, a3, a4);
    }
    __try {
        e = eh_find(unit);
        if (e) {
            const uint8_t *data; int32_t cnt; uint64_t tb;
            memcpy(&data, unit + EH_TASKS, 8); memcpy(&cnt, unit + EH_TASKS + 8, 4);
            if (unit[EH_DEAD] != 0) EH.skipped++;
            else if (e->first && GetTickCount64() - e->first > EH.ceil_ms) { EH.expired++; if (!e->exp) { e->exp = 1; EH.ceilunits++; EH.ceilty[(unsigned)e->type & 63]++; } }
            else if (cnt > 0 && cnt < 64 && data && (int)data[0] == e->type) {
                memcpy(&tb, data + EH_TB, 8);
                if (e->bld == 0 || tb == e->bld) { memcpy(EH.rec, data, EH_REC); hold = 1; }
                else { EH.skipped++; EH.skb++; }
            } else { EH.skipped++; EH.skt++; }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { EH.faults++; InterlockedExchange(&EH.enabled, 0); hold = 0; }
    r = tramp(unit, a2, a3, a4);
    if (hold) {
        __try { EH.inset = 1; EH.settask(unit, EH.rec); EH.inset = 0; EH.held++; e->held++; if (!e->first) e->first = GetTickCount64(); }
        __except (EXCEPTION_EXECUTE_HANDLER) { EH.inset = 0; EH.faults++; InterlockedExchange(&EH.enabled, 0); log_line("ENDHOLD: exception %08lX in the re-set: off", GetExceptionCode()); }
    } else if (e) EH.passed++;
    return r;
}

/* stub: mov rax,[rsp]; mov [g_eh_ret],rax; mov rax,endhold_wrap; jmp rax      (the wrapper returns to the caller)
 * trampoline: mov r11,rsp; push rbp; push rsi; jmp [rip+0] -> entry + 5 */
static int endhold_make_stubs(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize), *resume = EH.entry + EH_LEN;
    void *fn = (void *)&endhold_wrap; volatile uint64_t *gr = &g_eh_ret;
    size_t n = 0; int32_t rel; DWORD old;
    if (!p) return 0;
    p[n++] = 0x48; p[n++] = 0x8B; p[n++] = 0x04; p[n++] = 0x24;                  /* mov rax,[rsp] */
    p[n++] = 0x48; p[n++] = 0xA3; memcpy(p + n, &gr, 8); n += 8;                   /* mov [moffs64],rax */
    p[n++] = 0x48; p[n++] = 0xB8; memcpy(p + n, &fn, 8); n += 8;                   /* mov rax,imm64 */
    p[n++] = 0xFF; p[n++] = 0xE0;                                                  /* jmp rax */
    n = (n + 15) & ~(size_t)15;
    EH.tramp = p + n;
    memcpy(p + n, EH_ORIG, EH_LEN); n += EH_LEN;
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0; memcpy(p + n, &resume, 8); n += 8;
    rel = (int32_t)((intptr_t)p - (intptr_t)(EH.entry + EH_LEN));
    EH.jmp[0] = 0xE9; memcpy(EH.jmp + 1, &rel, 4);
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    EH.stub = p;
    log_line("ENDHOLD: stub at %p, trampoline at %p", (void *)p, (void *)EH.tramp);
    return 1;
}

static void endhold_off(const char *why)
{
    char w[160]; int r = 1;
    if (!EH.avail || !EH.entry) return;
    if (EH.stub && memcmp(EH.entry, EH.jmp, EH_LEN) == 0) r = write_bytes(EH.entry, EH.jmp, EH_ORIG, EH_LEN, w, sizeof(w));
    if (r != 1) { log_line("ENDHOLD: the entry could not be restored: %s", w); if (r < 0) internal_failure("endhold restore failed"); }
    InterlockedExchange(&EH.enabled, 0);
    if (strcmp(why, "all patches off") == 0) { memset(EH.t, 0, sizeof(EH.t)); EH.n = 0; }
    log_line("ENDHOLD off (%s): held %u passed %u expired %u", why, EH.held, EH.passed, EH.expired);
    g_dirty = 1;
}

static void endhold_on(void)
{
    char w[160]; int r;
    g_dirty = 1;
    if (!EH.avail) { EH.bad++; log_line("ENDHOLD ON refused: unavailable (%s)", EH.why); return; }
    if (!EH.stub && !endhold_make_stubs()) { EH.avail = 0; _snprintf(EH.why, sizeof(EH.why), "no free memory near the game module for the stub"); return; }
    EH.thread = GetCurrentThreadId();
    if (memcmp(EH.entry, EH.jmp, EH_LEN) == 0) { InterlockedExchange(&EH.enabled, 1); return; }
    if (memcmp(EH.entry, EH_ORIG, EH_LEN) != 0) { EH.avail = 0; _snprintf(EH.why, sizeof(EH.why), "the entry holds neither its own bytes nor this DLL's"); log_line("ENDHOLD ON refused: %s", EH.why); return; }
    InterlockedExchange(&EH.enabled, 1);
    r = write_bytes(EH.entry, EH_ORIG, EH.jmp, EH_LEN, w, sizeof(w));
    if (r != 1) { InterlockedExchange(&EH.enabled, 0); EH.avail = 0; _snprintf(EH.why, sizeof(EH.why), "%s", w); log_line("ENDHOLD ON FAILED: %s", w); if (r < 0) internal_failure("endhold hook write failed"); return; }
    log_line("ENDHOLD on: end-task %p, %d units on the list", (void *)EH.entry, EH.n);
}

/* ENDHOLD SET <ceiling ms> u:t:b,... | - : the whole list; a unit that stays with the same type and building keeps its
 * first held end (the ceiling counts from it), as long as the host's start number is the same */
static void endhold_set(const char *ceil, const char *list)
{
    static eh_ent old[EH_MAX];
    const char *s = list; char *e2;
    unsigned long long c = _strtoui64(ceil, &e2, 16);
    int k;
    g_dirty = 1;
    if (e2 == ceil || *e2 || c == 0 || c > 600000) { EH.bad++; log_line("ENDHOLD SET refused: '%s' is no ceiling (ms, hex)", ceil); return; }
    memcpy(old, EH.t, sizeof(old));
    memset(EH.t, 0, sizeof(EH.t)); EH.n = 0; EH.ceil_ms = c;
    if (strcmp(s, "-") != 0) while (*s) {
        unsigned long long u, ty, b, sq = 0; char *e;
        u = _strtoui64(s, &e, 16); if (e == s || *e != ':') goto bad; s = e + 1;
        ty = _strtoui64(s, &e, 16); if (e == s || *e != ':' || ty > 255) goto bad; s = e + 1;
        b = _strtoui64(s, &e, 16); if (e == s || (*e != ',' && *e != ':' && *e)) goto bad;
        if (*e == ':') { s = e + 1; sq = _strtoui64(s, &e, 16); if (e == s || (*e != ',' && *e)) goto bad; }
        s = *e ? e + 1 : e;
        if (u == 0 || (u & 7)) goto bad;
        if (EH.n < EH_MAX / 2) {
            unsigned h = (unsigned)(((uintptr_t)u >> 4) * 2654435761u) % EH_MAX;
            ULONGLONG first = 0; unsigned held = 0; int ex = 0;
            for (k = 0; k < EH_MAX; k++) { eh_ent *o = &old[(h + k) % EH_MAX]; if (!o->unit) break; if ((uint64_t)(uintptr_t)o->unit == u) { if (o->type == (int)ty && o->bld == b && o->seq == (unsigned)sq) { first = o->first; held = o->held; ex = o->exp; } break; } }
            for (k = 0; k < EH_MAX; k++) { eh_ent *x = &EH.t[(h + k) % EH_MAX]; if (!x->unit) { x->unit = (uint8_t *)(uintptr_t)u; x->type = (int)ty; x->bld = b; x->seq = (unsigned)sq; x->first = first; x->held = held; x->exp = ex; EH.n++; break; } }
        }
    }
    EH.sets++;
    return;
bad:
    memset(EH.t, 0, sizeof(EH.t)); EH.n = 0; EH.bad++;
    log_line("ENDHOLD SET refused: '%.40s' is not a list of unit:type:building (hex)", s);
}

static void endhold_cmd(int argc, char **argv)
{
    int v;
    g_dirty = 1;
    if (!EH.avail) { EH.bad++; log_line("ENDHOLD refused: unavailable (%s)", EH.why); return; }
    if (argc == 2 && on_off(argv[1], &v)) { if (v) endhold_on(); else endhold_off("ENDHOLD OFF"); return; }
    if (argc == 4 && _stricmp(argv[1], "SET") == 0) { endhold_set(argv[2], argv[3]); return; }
    if (argc == 4 && _stricmp(argv[1], "RANGE") == 0) {
        char *e1, *e2; unsigned long long lo = _strtoui64(argv[2], &e1, 16), hi = _strtoui64(argv[3], &e2, 16);
        if (*e1 || *e2 || lo >= hi) { EH.bad++; return; }
        EH.lo = lo; EH.hi = hi; return;
    }
    EH.bad++; log_line("ENDHOLD refused: needs ON | OFF | SET <ceiling ms> <unit>:<type>:<building>,... | RANGE <lo> <hi>");
}
