/* ------------------------------------------------------------------ COLLAPSE (lane 71): a building collapses on the host's word
 * Included once by coop_patch.c; everything here is this lane's own block.
 *
 * Why (READ in the game file, lane 71): a mine's collapse is a roll of each copy. TemporalComponent::updateDay
 * (4d775c0) calls, for every building whose daily check applies (4d78247), the roll 4cfac70: GetCollapseChance(b), then
 * rand() & 7FFFh scaled against it, then collapseBuilding(b) (4d2ee10). collapseBuilding marks the building (+3A0h = 1),
 * then either collapses the parts (one kind of building) or rolls a death among the units inside (rand against the
 * type's byte +29Ch; SMUnit::just_die and a notice), turns the building into a ruin (type 4Bh) and lets its families go.
 * Four other callers: the cheats CollapseNumBuildings / CollapseAllBuildings, a unit's proximityAction (4dcdc61) and a
 * thunk. Each copy rolls by itself, so a mine collapses on one copy only (seen only when the building lists differ,
 * and then it costs a resync).
 *
 *   COLLAPSE WATCH        host: collapseBuilding's entry (5 bytes "mov [rsp+20h],rbx") moves into a stub of this DLL;
 *                         every call runs as before and the building's address and its type before the call (Data.bType
 *                         +3B8h: the collapse makes it a ruin, 4Bh) are noted; the tick appends one line per collapse to
 *                         collapse_out.txt ("<building hex> <type>"), which the mod reads and deletes.
 *   COLLAPSE ON           friend: the same hook, and every call the game makes returns at once (counted: blocked): no
 *                         roll of this copy, no cheat, no unit collapses a building here. The death roll inside is
 *                         switched off as well (one byte: "cmp edx,eax" before the roll's jge becomes "cmp edx,edx", so
 *                         the jump over the death is always taken): the host's death comes with its family lists.
 *                         One caller is let through on a friend (PASS): a soldier's GrabLootOrDismantle (task 58) at its
 *                         target building, in SMUnit::proximityAction (the call at 4dcdc61, READ: currentUnitRole 5,
 *                         Tasks[0].Type 58, the building not marked yet, the soldier in reach; the tasks at it ended,
 *                         then the collapse, then the soldier's loot). Stopping it would leave the building unmarked and
 *                         the loot code after the call running again and again; let through, this copy's soldier
 *                         dismantles what the host's soldier dismantles (the death roll inside stays off).
 *   COLLAPSE DO <b>       friend, ON only: the host's collapse here, the game's own routine (through the trampoline); a
 *                         building already marked (+3A0h) is left (counted "already").
 *   COLLAPSE PASS <ret>   the return address of the caller let through (hex; by default that of the call above, checked
 *                         at the scan to be an E8 to the entry). For the offline test.
 *   COLLAPSE OFF          the entry and the byte as they were.
 * Known build only; the two signatures exactly once (COLLENT, CKILL); the moved and the patched bytes checked first.
 * Status: "COLLAPSE off|watch|on blocked= seen= done= pending= faults= bad=" or "COLLAPSE unavailable <why>". */
#define CL_LEN        5
#define CL_KILL_AT    59            /* CKILL: the ModRM byte of "cmp edx,eax" (3B D0) right before the death's jge */
#define CL_MAXQ       64
#define CL_CHECK      0x400         /* bytes of a building that must be readable for DO */
#define CL_TYPE       0x3B8         /* Data.bType: the type GetType names (collapseBuilding reads it there itself) */
static const uint8_t CL_ORIG[CL_LEN] = { 0x48, 0x89, 0x5C, 0x24, 0x20 };
typedef void (*cl_fn)(uint8_t *b);
static struct {
    int avail; char why[160];
    uint8_t *entry, *kill, *stub, *tramp;
    uint8_t jmp[CL_LEN];
    volatile LONG mode;             /* 0 off, 1 on (friend: block), 2 watch (host) */
    int killed;                     /* the death byte is patched */
    uintptr_t q[CL_MAXQ]; int32_t qt[CL_MAXQ]; int nq;
    unsigned blocked, seen, done, faults, bad, dropped, passed, already;
    uint64_t passret;               /* the return address of the caller let through (0: none) */
} CL;
static volatile uint64_t g_cl_ret;  /* the return address of the call being wrapped (the stub writes it) */
#define CL_PASS_SITE  0x9EE51       /* the soldier's call (4dcdc61) less the entry (4d2ee10), known build */

static int collapse_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "COLLAPSE unavailable dll is off\r\n");
    if (!CL.avail) return _snprintf(buf, len, "COLLAPSE unavailable %s\r\n", CL.why);
    return _snprintf(buf, len, "COLLAPSE %s blocked=%u seen=%u done=%u pending=%d dropped=%u faults=%u bad=%u kill=%d passed=%u already=%u pass=%d\r\n",
                     CL.mode == 1 ? "on" : CL.mode == 2 ? "watch" : "off", CL.blocked, CL.seen, CL.done, CL.nq, CL.dropped, CL.faults, CL.bad, CL.killed,
                     CL.passed, CL.already, CL.passret ? 1 : 0);
}

static int collapse_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    uint8_t *keepstub = CL.stub, *keeptramp = CL.tramp, keepjmp[CL_LEN];
    memcpy(keepjmp, CL.jmp, CL_LEN); memset(&CL, 0, sizeof(CL)); CL.stub = keepstub; CL.tramp = keeptramp; memcpy(CL.jmp, keepjmp, CL_LEN);
    if (!known) _snprintf(CL.why, sizeof(CL.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_COLLENT].hits != 1) _snprintf(CL.why, sizeof(CL.why), "COLLENT signature has %d hits (need exactly 1)", g_hit[S_COLLENT].hits);
    else if (g_hit[S_CKILL].hits != 1) _snprintf(CL.why, sizeof(CL.why), "CKILL signature has %d hits (need exactly 1)", g_hit[S_CKILL].hits);
    else {
        CL.entry = g_base + g_hit[S_COLLENT].rva;
        CL.kill = g_base + g_hit[S_CKILL].rva + CL_KILL_AT;
        if (memcmp(CL.entry, CL_ORIG, CL_LEN) != 0 && !(CL.stub && CL.entry[0] == 0xE9)) _snprintf(CL.why, sizeof(CL.why), "collapseBuilding does not start with its known bytes");
        else if (((uintptr_t)CL.entry & 7) + CL_LEN > 8) _snprintf(CL.why, sizeof(CL.why), "collapseBuilding's first bytes would cross an 8-byte block");
        else if (CL.kill[-1] != 0x3B || (CL.kill[0] != 0xD0 && CL.kill[0] != 0xD2)) _snprintf(CL.why, sizeof(CL.why), "the death roll's compare is not 3B D0");
        else {
            const uint8_t *c = CL.entry + CL_PASS_SITE; int32_t rel;
            CL.avail = 1;
            if (range_readable(c, 5) && c[0] == 0xE8) { memcpy(&rel, c + 1, 4); if (c + 5 + rel == CL.entry) CL.passret = (uint64_t)(uintptr_t)(c + 5); }
            if (!CL.passret) log_line("  COLLAPSE: the soldier's call is not where it was read: no caller is let through on a friend");
        }
    }
    log_line("  COLLAPSE %s %s", CL.avail ? "available" : "unavailable", CL.avail ? "" : CL.why);
    return CL.avail;
}

/* every call of collapseBuilding comes here (the stub jumps here with the game's own arguments and return address) */
static void collapse_wrap(uint8_t *b)
{
    LONG m = CL.mode;
    if (m == 1) {                                              /* friend: only the host's collapse (DO) happens here ... */
        if (CL.passret && g_cl_ret == CL.passret) { CL.passed++; ((cl_fn)(void *)CL.tramp)(b); return; }   /* ... and a soldier's dismantling */
        CL.blocked++; return;
    }
    if (m == 2) {
        if (CL.nq < CL_MAXQ) {
            int32_t t = -1;
            __try { t = *(const int32_t *)(b + CL_TYPE); } __except (EXCEPTION_EXECUTE_HANDLER) { CL.faults++; }
            CL.q[CL.nq] = (uintptr_t)b; CL.qt[CL.nq] = t; CL.nq++;
        } else CL.dropped++;
        CL.seen++;
    }
    ((cl_fn)(void *)CL.tramp)(b);
}

/* stub: mov rax,[rsp]; mov [g_cl_ret],rax; mov rax,collapse_wrap; jmp rax. Trampoline: mov [rsp+20h],rbx; jmp [rip+0] -> entry + 5 */
static int collapse_make_stubs(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize), *resume = CL.entry + CL_LEN;
    void *fn = (void *)&collapse_wrap; volatile uint64_t *gr = &g_cl_ret;
    size_t n = 0; int32_t rel; DWORD old;
    if (!p) return 0;
    p[n++] = 0x48; p[n++] = 0x8B; p[n++] = 0x04; p[n++] = 0x24;                  /* mov rax,[rsp] */
    p[n++] = 0x48; p[n++] = 0xA3; memcpy(p + n, &gr, 8); n += 8;                   /* mov [moffs64],rax */
    p[n++] = 0x48; p[n++] = 0xB8; memcpy(p + n, &fn, 8); n += 8;                   /* mov rax,imm64 */
    p[n++] = 0xFF; p[n++] = 0xE0;                                                  /* jmp rax */
    n = (n + 15) & ~(size_t)15;
    CL.tramp = p + n;
    memcpy(p + n, CL_ORIG, CL_LEN); n += CL_LEN;
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0; memcpy(p + n, &resume, 8); n += 8;
    rel = (int32_t)((intptr_t)p - (intptr_t)(CL.entry + CL_LEN));
    CL.jmp[0] = 0xE9; memcpy(CL.jmp + 1, &rel, 4);
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    CL.stub = p;
    log_line("COLLAPSE: stub at %p, trampoline at %p", (void *)p, (void *)CL.tramp);
    return 1;
}

static void collapse_kill(int on)
{
    static const uint8_t orig = 0xD0, patched = 0xD2;
    char w[160]; int r;
    if (!CL.avail || !CL.kill || CL.killed == on) return;
    r = write_bytes(CL.kill, on ? &orig : &patched, on ? &patched : &orig, 1, w, sizeof(w));
    if (r == 1) CL.killed = on;
    else { log_line("COLLAPSE: the death roll's byte not %s: %s", on ? "patched" : "restored", w); if (r < 0) internal_failure("collapse byte write failed"); }
}

static void collapse_off(const char *why)
{
    char w[160]; int r = 1;
    if (!CL.avail || !CL.entry) return;
    InterlockedExchange(&CL.mode, 0);
    if (CL.stub && memcmp(CL.entry, CL.jmp, CL_LEN) == 0) r = write_bytes(CL.entry, CL.jmp, CL_ORIG, CL_LEN, w, sizeof(w));
    if (r != 1) { log_line("COLLAPSE: the entry could not be restored: %s", w); if (r < 0) internal_failure("collapse restore failed"); }
    collapse_kill(0);
    log_line("COLLAPSE off (%s): blocked %u seen %u done %u", why, CL.blocked, CL.seen, CL.done);
    g_dirty = 1;
}

static void collapse_on(int mode)
{
    char w[160]; int r;
    g_dirty = 1;
    if (!CL.avail) { CL.bad++; log_line("COLLAPSE %s refused: unavailable (%s)", mode == 1 ? "ON" : "WATCH", CL.why); return; }
    if (!CL.stub && !collapse_make_stubs()) { CL.avail = 0; _snprintf(CL.why, sizeof(CL.why), "no free memory near the game module for the stub"); return; }
    if (memcmp(CL.entry, CL.jmp, CL_LEN) != 0) {
        if (memcmp(CL.entry, CL_ORIG, CL_LEN) != 0) { CL.avail = 0; _snprintf(CL.why, sizeof(CL.why), "the entry holds neither its own bytes nor this DLL's"); log_line("COLLAPSE refused: %s", CL.why); return; }
        InterlockedExchange(&CL.mode, mode);
        r = write_bytes(CL.entry, CL_ORIG, CL.jmp, CL_LEN, w, sizeof(w));
        if (r != 1) { InterlockedExchange(&CL.mode, 0); CL.avail = 0; _snprintf(CL.why, sizeof(CL.why), "%s", w); log_line("COLLAPSE FAILED: %s", w); if (r < 0) internal_failure("collapse hook write failed"); return; }
    } else InterlockedExchange(&CL.mode, mode);
    collapse_kill(mode == 1);                                  /* the death roll off on a friend only */
    log_line("COLLAPSE %s: collapseBuilding %p", mode == 1 ? "on (friend: only the host's collapses)" : "watch (host)", (void *)CL.entry);
}

static void collapse_do(const char *arg)
{
    unsigned long long a = 0; char why[200];
    g_dirty = 1;
    if (!CL.avail || CL.mode != 1 || !CL.killed) { CL.bad++; log_line("COLLAPSE DO refused: COLLAPSE is not on"); return; }
    if (!parse_u64(arg, &a) || !comp_sane(a, CL_CHECK, why, sizeof(why))) { CL.bad++; log_line("COLLAPSE DO refused: %s", a ? why : "not an address"); return; }
    if (*(const uint8_t *)(uintptr_t)(a + 0x3A0) != 0) { CL.already++; log_line("COLLAPSE DO %llX: already collapsed here (marked)", a); return; }
    __try { ((cl_fn)(void *)CL.tramp)((uint8_t *)(uintptr_t)a); CL.done++; log_line("COLLAPSE DO %llX: the host's collapse, here", a); }
    __except (EXCEPTION_EXECUTE_HANDLER) { CL.faults++; log_line("COLLAPSE DO %llX raised exception %08lX", a, GetExceptionCode()); }
}

/* the tick: the host's collapses of this tick to collapse_out.txt (appended; the mod reads it once and deletes it) */
static void collapse_tick(void)
{
    char buf[CL_MAXQ * 32]; int n = 0, i;
    wchar_t path[MAX_PATH]; HANDLE h; DWORD wr;
    if (!CL.avail || CL.nq == 0) return;
    for (i = 0; i < CL.nq; i++) n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "%IX %d\r\n", CL.q[i], (int)CL.qt[i]);
    CL.nq = 0;
    join_path(path, g_dir, L"collapse_out.txt");
    h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) { if (n > 0) WriteFile(h, buf, (DWORD)n, &wr, NULL); CloseHandle(h); }
    g_dirty = 1;
}

static void collapse_cmd(int argc, char **argv)
{
    int v;
    g_dirty = 1;
    if (!CL.avail) { CL.bad++; log_line("COLLAPSE refused: unavailable (%s)", CL.why); return; }
    if (argc == 2 && on_off(argv[1], &v)) { if (v) collapse_on(1); else collapse_off("COLLAPSE OFF"); return; }
    if (argc == 2 && _stricmp(argv[1], "WATCH") == 0) { collapse_on(2); return; }
    if (argc == 3 && _stricmp(argv[1], "DO") == 0) { collapse_do(argv[2]); return; }
    if (argc == 3 && _stricmp(argv[1], "PASS") == 0) { char *e; unsigned long long r = _strtoui64(argv[2], &e, 16); if (*e) { CL.bad++; return; } CL.passret = r; return; }
    CL.bad++; log_line("COLLAPSE refused: needs ON | OFF | WATCH | DO <building>");
}

/* ------------------------------------------------------------------ MROLL (lane 71): the daily maintenance roll on the host's word
 * Why (READ): in the same per-building loop of updateDay as the collapse roll, 4d78212 calls 4cfacc0 for every building
 * whose check 4d16750 applies: GetActiveMaintenanceEffect (lane 67's status), then
 *   effects 1 and 2 (well kept): PawnCPP::changeInfluence of the building's owner by the effect's table value;
 *   effect 6 (unmaintained, the worst): rand() & 7FFFh against the effect's table chance, then the first worker whose
 *     current task is at this building gets the work accident 4db9c80(worker, 1, building): its own rand, 1 in 100 a
 *     death (just_die, notice "worker_death_due_to_bad_maintenance"), else the family's injured mark and the notice
 *     "worker_injured".
 * Each copy rolls its own. Lane 64's NODEATH (NDACC) jumps over the accident call on a friend (no death, no injury of
 * its own); the influence change still ran there, and the host's injury notice never reached a friend.
 *   MROLL ON      friend: 4cfacc0's entry (5 bytes "mov [rsp+18h],rbx") into a stub: every call returns at once
 *                 (blocked): no roll, no accident, no influence change of this copy. The outcome is the host's: a death
 *                 by lane 64's E PD line, the injured mark by the facts module, influence by the lord's numbers.
 *   MROLL WATCH   host: 4db9c80's entry (5 bytes "mov [rsp+10h],rbx") into a stub: the accident runs as before, then
 *                 its worker and building and whether the worker died are noted; the tick appends one line per
 *                 accident to accident_out.txt ("<building hex> <worker hex> <died 0|1>"): the mod sends the injury.
 *   MROLL OFF     both entries as they were.
 * Signatures MRDAY (4cfacc0, the entry to the effect's switch) and MRACC (4db9c80, the entry to its place test).
 * Known build only. Status: "MROLL off|on|watch blocked= seen= dropped= faults= bad=" or "MROLL unavailable <why>". */
#define MR_LEN        5
#define MR_MAXQ       64
#define MR_DEAD       0x30C          /* SMUnit: dead (as lane 64 / ENDHOLD read it) */
typedef struct { uint8_t *entry, *stub, *tramp; const uint8_t *orig; uint8_t jmp[MR_LEN]; } mr_hook;
static const uint8_t MR_DAY_ORIG[MR_LEN] = { 0x48, 0x89, 0x5C, 0x24, 0x18 };
static const uint8_t MR_ACC_ORIG[MR_LEN] = { 0x48, 0x89, 0x5C, 0x24, 0x10 };
typedef void (*mr_day_fn)(uint8_t *b);
typedef void (*mr_acc_fn)(uint8_t *u, int a2, uint8_t *b);
static struct {
    int avail; char why[160];
    mr_hook day, acc;
    volatile LONG mode;            /* 0 off, 1 on (friend), 2 watch (host) */
    uintptr_t qb[MR_MAXQ], qu[MR_MAXQ]; int qd[MR_MAXQ], nq;
    unsigned blocked, seen, dropped, faults, bad;
} MR;

static int mroll_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "MROLL unavailable dll is off\r\n");
    if (!MR.avail) return _snprintf(buf, len, "MROLL unavailable %s\r\n", MR.why);
    return _snprintf(buf, len, "MROLL %s blocked=%u seen=%u pending=%d dropped=%u faults=%u bad=%u\r\n",
                     MR.mode == 1 ? "on" : MR.mode == 2 ? "watch" : "off", MR.blocked, MR.seen, MR.nq, MR.dropped, MR.faults, MR.bad);
}

static int mroll_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    mr_hook kd = MR.day, ka = MR.acc;
    memset(&MR, 0, sizeof(MR)); MR.day = kd; MR.acc = ka;            /* stubs made once are kept (as ENDHOLD's) */
    if (!known) _snprintf(MR.why, sizeof(MR.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_MRDAY].hits != 1) _snprintf(MR.why, sizeof(MR.why), "MRDAY signature has %d hits (need exactly 1)", g_hit[S_MRDAY].hits);
    else if (g_hit[S_MRACC].hits != 1) _snprintf(MR.why, sizeof(MR.why), "MRACC signature has %d hits (need exactly 1)", g_hit[S_MRACC].hits);
    else {
        MR.day.entry = g_base + g_hit[S_MRDAY].rva; MR.day.orig = MR_DAY_ORIG;
        MR.acc.entry = g_base + g_hit[S_MRACC].rva; MR.acc.orig = MR_ACC_ORIG;
        if ((memcmp(MR.day.entry, MR_DAY_ORIG, MR_LEN) != 0 && !(MR.day.stub && MR.day.entry[0] == 0xE9)) ||
            (memcmp(MR.acc.entry, MR_ACC_ORIG, MR_LEN) != 0 && !(MR.acc.stub && MR.acc.entry[0] == 0xE9)))
            _snprintf(MR.why, sizeof(MR.why), "an entry does not start with its known bytes");
        else if (((uintptr_t)MR.day.entry & 7) + MR_LEN > 8 || ((uintptr_t)MR.acc.entry & 7) + MR_LEN > 8)
            _snprintf(MR.why, sizeof(MR.why), "an entry's first bytes would cross an 8-byte block");
        else MR.avail = 1;
    }
    log_line("  MROLL %s %s", MR.avail ? "available" : "unavailable", MR.avail ? "" : MR.why);
    return MR.avail;
}

static void mroll_day_wrap(uint8_t *b)
{
    if (MR.mode == 1) { MR.blocked++; return; }                 /* friend: the roll is the host's */
    ((mr_day_fn)(void *)MR.day.tramp)(b);
}
static void mroll_acc_wrap(uint8_t *u, int a2, uint8_t *b)
{
    ((mr_acc_fn)(void *)MR.acc.tramp)(u, a2, b);
    if (MR.mode != 2) return;
    MR.seen++;
    if (MR.nq >= MR_MAXQ) { MR.dropped++; return; }
    {
        int dead = 0;
        __try { dead = u && *(const uint8_t *)(u + MR_DEAD) != 0; } __except (EXCEPTION_EXECUTE_HANDLER) { MR.faults++; }
        MR.qb[MR.nq] = (uintptr_t)b; MR.qu[MR.nq] = (uintptr_t)u; MR.qd[MR.nq] = dead; MR.nq++;
    }
}

/* stub: mov rax,<wrapper>; jmp rax. Trampoline: the entry's first 5 bytes; jmp [rip+0] -> entry + 5 */
static int mr_make(mr_hook *h, void *fn)
{
    uint8_t *p = alloc_near(g_base, g_imgsize), *resume = h->entry + MR_LEN;
    size_t n = 0; int32_t rel; DWORD old;
    if (!p) return 0;
    p[n++] = 0x48; p[n++] = 0xB8; memcpy(p + n, &fn, 8); n += 8; p[n++] = 0xFF; p[n++] = 0xE0;
    n = (n + 15) & ~(size_t)15;
    h->tramp = p + n;
    memcpy(p + n, h->orig, MR_LEN); n += MR_LEN;
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0; memcpy(p + n, &resume, 8); n += 8;
    rel = (int32_t)((intptr_t)p - (intptr_t)(h->entry + MR_LEN));
    h->jmp[0] = 0xE9; memcpy(h->jmp + 1, &rel, 4);
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    h->stub = p;
    return 1;
}
/* the hook in (1) or out (0); 1 when it is as asked */
static int mr_set(mr_hook *h, void *fn, int on)
{
    char w[160]; int r = 1;
    if (on) {
        if (!h->stub && !mr_make(h, fn)) { log_line("MROLL: no free memory near the game module for a stub"); return 0; }
        if (memcmp(h->entry, h->jmp, MR_LEN) == 0) return 1;
        r = write_bytes(h->entry, h->orig, h->jmp, MR_LEN, w, sizeof(w));
    } else {
        if (!h->stub || memcmp(h->entry, h->jmp, MR_LEN) != 0) return 1;
        r = write_bytes(h->entry, h->jmp, h->orig, MR_LEN, w, sizeof(w));
    }
    if (r != 1) { log_line("MROLL: an entry not %s: %s", on ? "hooked" : "restored", w); if (r < 0) internal_failure("mroll write failed"); return 0; }
    return 1;
}

static void mroll_off(const char *why)
{
    if (!MR.avail) return;
    InterlockedExchange(&MR.mode, 0);
    mr_set(&MR.day, (void *)&mroll_day_wrap, 0); mr_set(&MR.acc, (void *)&mroll_acc_wrap, 0);
    log_line("MROLL off (%s): blocked %u seen %u", why, MR.blocked, MR.seen);
    g_dirty = 1;
}

static void mroll_on(int mode)
{
    int ok;
    g_dirty = 1;
    if (!MR.avail) { MR.bad++; log_line("MROLL %s refused: unavailable (%s)", mode == 1 ? "ON" : "WATCH", MR.why); return; }
    InterlockedExchange(&MR.mode, mode);
    if (mode == 1) ok = mr_set(&MR.acc, (void *)&mroll_acc_wrap, 0) && mr_set(&MR.day, (void *)&mroll_day_wrap, 1);
    else ok = mr_set(&MR.day, (void *)&mroll_day_wrap, 0) && mr_set(&MR.acc, (void *)&mroll_acc_wrap, 1);
    if (!ok) { mroll_off("a hook could not be set"); MR.avail = 0; _snprintf(MR.why, sizeof(MR.why), "an entry could not be written"); return; }
    log_line("MROLL %s", mode == 1 ? "on (friend: the daily maintenance roll is the host's)" : "watch (host: accidents noted)");
}

static void mroll_tick(void)
{
    char buf[MR_MAXQ * 48]; int n = 0, i;
    wchar_t path[MAX_PATH]; HANDLE h; DWORD wr;
    if (!MR.avail || MR.nq == 0) return;
    for (i = 0; i < MR.nq; i++) n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "%IX %IX %d\r\n", MR.qb[i], MR.qu[i], MR.qd[i]);
    MR.nq = 0;
    join_path(path, g_dir, L"accident_out.txt");
    h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) { if (n > 0) WriteFile(h, buf, (DWORD)n, &wr, NULL); CloseHandle(h); }
    g_dirty = 1;
}

static void mroll_cmd(int argc, char **argv)
{
    int v;
    g_dirty = 1;
    if (!MR.avail) { MR.bad++; log_line("MROLL refused: unavailable (%s)", MR.why); return; }
    if (argc == 2 && on_off(argv[1], &v)) { if (v) mroll_on(1); else mroll_off("MROLL OFF"); return; }
    if (argc == 2 && _stricmp(argv[1], "WATCH") == 0) { mroll_on(2); return; }
    /* test (host, WATCH only): the game's own work accident for that worker at that building, through the hooked entry
     * (so it is noted and sent like one the daily roll gave) */
    if (argc == 4 && _stricmp(argv[1], "ACC") == 0) {
        unsigned long long u = 0, b = 0; char why[200];
        if (MR.mode != 2) { MR.bad++; log_line("MROLL ACC refused: not WATCH"); return; }
        if (!parse_u64(argv[2], &u) || !comp_sane(u, MR_DEAD + 8, why, sizeof(why)) || !parse_u64(argv[3], &b) || !comp_sane(b, 0x400, why, sizeof(why))) { MR.bad++; log_line("MROLL ACC refused: %s", why); return; }
        /* the building is passed as none: the routine's place test (4db9ca6: is the worker inside the building?) is then
         * skipped and its roll runs (run b: workers next to their hut failed the test and nothing happened); the note
         * gets the building named here */
        __try {
            int before = MR.nq;
            ((mr_acc_fn)(void *)MR.acc.entry)((uint8_t *)(uintptr_t)u, 1, NULL);
            if (MR.nq > before) MR.qb[before] = (uintptr_t)b;
            log_line("MROLL ACC %llX %llX: the game's work accident (test)", u, b);
        }
        __except (EXCEPTION_EXECUTE_HANDLER) { MR.faults++; log_line("MROLL ACC raised exception %08lX", GetExceptionCode()); }
        return;
    }
    MR.bad++; log_line("MROLL refused: needs ON | OFF | WATCH | ACC <worker> <building>");
}

/* ------------------------------------------------------------------ NOROLL (lane 87): a friend's own mercenary month roll
 * Why (READ, lanes/lane_s21_87/design_noroll.txt): Engine::rerollMercenaries (4cd83e0, engine rcx) empties the offer list
 * (engine +BF0h, availableMercs), adds at most three companies of the company table (+BE8h) picked with rand(), and gives
 * this copy's player (+5B0h) the notice "mercenaries_available"; it writes nothing else of the engine. Its callers: the
 * month block of TemporalComponent::updateDay (4d78bf0), RTSMultiEngineCPP::BeginPlay (4c83bfa, engine +301h zero only)
 * and the script layer's thunk (4ae9d60). On a friend the month roll drew three companies the host never had for one look
 * (66 ms, lane 88's run p88a) before the realm module wrote the host's list back; a hook on the reflected function never
 * fires there (updateDay calls the C++ routine). Engine::refillMercenaries (40a70e0) is the linker's shared empty stub
 * (C2 00 00): nothing to stop there, and it must not be written.
 *   NOROLL ON     friend: the roll's entry, 7 bytes ("mov rax,rsp; mov [rax+20h],rbx"), into a stub (a 5-byte jmp and two
 *                 int3): every call returns at once (blocked), unless a pass is set. The offers then change only by the
 *                 host's word (the realm module), a load and a hire.
 *   NOROLL PASS   the next call goes through, once (passed): the realm module's own call when this copy holds fewer offers
 *                 than the host (a script cannot add a record; the game's roll makes the slots, written over with the
 *                 host's records in the same tick). A pass not used before the next tick of this piece begins is dropped
 *                 (expired).
 *   NOROLL OFF    the entry as it was.
 * Signature MERCROLL (4cd83e0, the entry up to "lea rbx,[rcx+0BF0h]"). Known build only. Status:
 * "NOROLL off|on blocked= passed= expired= bad=" or "NOROLL unavailable <why>". */
#define NOR_LEN        7
static const uint8_t NOR_ORIG[NOR_LEN] = { 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x20 };
typedef void (*nor_fn)(uint8_t *eng);
static struct {
    int avail; char why[160];
    uint8_t *entry, *stub, *tramp; uint8_t jmp[NOR_LEN];
    volatile LONG on, pass;
    unsigned blocked, passed, expired, bad;
} NOR;

static int noroll_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "NOROLL unavailable dll is off\r\n");
    if (!NOR.avail) return _snprintf(buf, len, "NOROLL unavailable %s\r\n", NOR.why);
    return _snprintf(buf, len, "NOROLL %s blocked=%u passed=%u expired=%u bad=%u\r\n",
                     NOR.on ? "on" : "off", NOR.blocked, NOR.passed, NOR.expired, NOR.bad);
}

static int noroll_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    uint8_t *ks = NOR.stub, *kt = NOR.tramp, kj[NOR_LEN];
    memcpy(kj, NOR.jmp, NOR_LEN);
    memset(&NOR, 0, sizeof(NOR)); NOR.stub = ks; NOR.tramp = kt; memcpy(NOR.jmp, kj, NOR_LEN);   /* a stub made once is kept */
    if (!known) _snprintf(NOR.why, sizeof(NOR.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_MERCROLL].hits != 1) _snprintf(NOR.why, sizeof(NOR.why), "MERCROLL signature has %d hits (need exactly 1)", g_hit[S_MERCROLL].hits);
    else {
        NOR.entry = g_base + g_hit[S_MERCROLL].rva;
        if (memcmp(NOR.entry, NOR_ORIG, NOR_LEN) != 0 && !(NOR.stub && NOR.entry[0] == 0xE9))
            _snprintf(NOR.why, sizeof(NOR.why), "the entry does not start with its known bytes");
        else if (((uintptr_t)NOR.entry & 7) + NOR_LEN > 8)
            _snprintf(NOR.why, sizeof(NOR.why), "the entry's first bytes would cross an 8-byte block");
        else NOR.avail = 1;
    }
    log_line("  NOROLL %s %s", NOR.avail ? "available" : "unavailable", NOR.avail ? "" : NOR.why);
    return NOR.avail;
}

/* every call of the roll while the stub is in: blocked, or through once on a pass */
static void noroll_wrap(uint8_t *eng)
{
    if (NOR.on && InterlockedExchange(&NOR.pass, 0) == 0) { NOR.blocked++; g_dirty = 1; return; }   /* friend: the host's offers */
    if (NOR.on) { NOR.passed++; g_dirty = 1; }
    ((nor_fn)(void *)NOR.tramp)(eng);
}

/* stub: mov rax,<wrapper>; jmp rax. Trampoline: the entry's 7 bytes; jmp [rip+0] -> entry + 7. The entry gets a 5-byte
 * jmp to the stub (relative to entry + 5) and two int3 (never run: the trampoline resumes at entry + 7). */
static int nor_make(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize), *resume = NOR.entry + NOR_LEN;
    void *fn = (void *)&noroll_wrap;
    size_t n = 0; int32_t rel; DWORD old;
    if (!p) return 0;
    p[n++] = 0x48; p[n++] = 0xB8; memcpy(p + n, &fn, 8); n += 8; p[n++] = 0xFF; p[n++] = 0xE0;
    n = (n + 15) & ~(size_t)15;
    NOR.tramp = p + n;
    memcpy(p + n, NOR_ORIG, NOR_LEN); n += NOR_LEN;
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0; memcpy(p + n, &resume, 8); n += 8;
    rel = (int32_t)((intptr_t)p - (intptr_t)(NOR.entry + 5));
    NOR.jmp[0] = 0xE9; memcpy(NOR.jmp + 1, &rel, 4); NOR.jmp[5] = 0xCC; NOR.jmp[6] = 0xCC;
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    NOR.stub = p;
    return 1;
}
/* the stub in (1) or out (0); 1 when it is as asked */
static int nor_set(int on)
{
    char w[160]; int r = 1;
    if (on) {
        if (!NOR.stub && !nor_make()) { log_line("NOROLL: no free memory near the game module for a stub"); return 0; }
        if (memcmp(NOR.entry, NOR.jmp, NOR_LEN) == 0) return 1;
        r = write_bytes(NOR.entry, NOR_ORIG, NOR.jmp, NOR_LEN, w, sizeof(w));
    } else {
        if (!NOR.stub || memcmp(NOR.entry, NOR.jmp, NOR_LEN) != 0) return 1;
        r = write_bytes(NOR.entry, NOR.jmp, NOR_ORIG, NOR_LEN, w, sizeof(w));
    }
    if (r != 1) { log_line("NOROLL: the entry not %s: %s", on ? "hooked" : "restored", w); if (r < 0) internal_failure("noroll write failed"); return 0; }
    return 1;
}

static void noroll_off(const char *why)
{
    if (!NOR.avail) return;
    InterlockedExchange(&NOR.on, 0); InterlockedExchange(&NOR.pass, 0);
    nor_set(0);
    log_line("NOROLL off (%s): blocked %u passed %u expired %u", why, NOR.blocked, NOR.passed, NOR.expired);
    g_dirty = 1;
}

static void noroll_on(void)
{
    g_dirty = 1;
    if (!NOR.avail) { NOR.bad++; log_line("NOROLL ON refused: unavailable (%s)", NOR.why); return; }
    InterlockedExchange(&NOR.on, 1);                       /* before the stub goes in: its first call is blocked */
    if (!nor_set(1)) { noroll_off("the hook could not be set"); NOR.avail = 0; _snprintf(NOR.why, sizeof(NOR.why), "the entry could not be written"); return; }
    log_line("NOROLL on (friend: the mercenary month roll is the host's)");
}

/* at the start of every tick, before the commands: a pass not used since the tick that set it is dropped */
static void noroll_tick(void)
{
    if (InterlockedExchange(&NOR.pass, 0)) { NOR.expired++; g_dirty = 1; }
}

static void noroll_cmd(int argc, char **argv)
{
    int v;
    g_dirty = 1;
    if (!NOR.avail) { NOR.bad++; log_line("NOROLL refused: unavailable (%s)", NOR.why); return; }
    if (argc == 2 && on_off(argv[1], &v)) { if (v) noroll_on(); else noroll_off("NOROLL OFF"); return; }
    if (argc == 2 && _stricmp(argv[1], "PASS") == 0) { InterlockedExchange(&NOR.pass, 1); return; }
    NOR.bad++; log_line("NOROLL refused: needs ON | OFF | PASS");
}

/* ------------------------------------------------------------------ BARNAN (lane 87, the bar's cure 2): a friend's site with
 * no parts yet reads its bar with no work done, not "not a number"
 * Why (READ, lanes/lane_s21_87/design_cures.txt 7; run p87g): SMBuildingMaster::getConstructionProgress (4d3d940,
 * building rcx) gives (work + G) * 0.5 (70ef0e0), G = (sum needed - sum short) / sum needed in double, 1.0 (70da508)
 * when nothing is needed, with the shortages from 4c663a0 (inventory +448h, needed goods +3D0h: it reads their list
 * headers and records and writes only its own out-list), work = sum of the parts' hp (+314h) / sum of their max (+318h)
 * over the list at +2F8h (count +300h), with no check: an empty list gives 0/0. A friend makes a rival's site through
 * the player's placement path, whose parts come a few frames after the building; the host's AI site had a part with no
 * work in its first frame (3@8981,7789: bar 0), the friend's none: "not a number" for 0.079 s, a value the host never
 * had. Its callers: the script layer's thunk (4af596e: the panel's widget) and PawnCPP::drawBuildingOverlays (4b3b161:
 * the bars over the sites).
 *   BARNAN ON     friend: the function's entry, 7 bytes ("mov rax,rsp; mov [rax+8],rbx"), into a stub. For a building
 *                 whose part list is empty, the wrapper runs the game's own function on a COPY of the building's first
 *                 0x500 bytes (on its own stack) whose part list is one made-up part with hp 0 and max 1: the game
 *                 itself works out G (its goods routine reads the real lists through the copied headers) and the work
 *                 half is 0. Nothing of the game's object is written. Every other call runs the original (the trampoline).
 *   BARNAN OFF    the entry as it was. The host never switches it on: its own first frames stay the game's.
 * Signature SITEPROG (4d3d940, the entry up to "add rcx,448h"). Known build only. Status:
 * "BARNAN off|on zeroed= faults= bad=" or "BARNAN unavailable <why>". */
#define BN_LEN         7
#define BN_COPY        0x500
static const uint8_t BN_ORIG[BN_LEN] = { 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x08 };
typedef float (*bn_fn)(uint8_t *b);
static struct {
    int avail; char why[160];
    uint8_t *entry, *stub, *tramp; uint8_t jmp[BN_LEN];
    volatile LONG on;
    unsigned zeroed, faults, bad;
} BN;
static __declspec(align(16)) uint8_t BN_PART[0x320];      /* the made-up part: hp 0.0 at +314h, max 1.0 at +318h */
static uint8_t *BN_LIST[1];

static int barnan_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "BARNAN unavailable dll is off\r\n");
    if (!BN.avail) return _snprintf(buf, len, "BARNAN unavailable %s\r\n", BN.why);
    return _snprintf(buf, len, "BARNAN %s zeroed=%u faults=%u bad=%u\r\n", BN.on ? "on" : "off", BN.zeroed, BN.faults, BN.bad);
}

static int barnan_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    uint8_t *ks = BN.stub, *kt = BN.tramp, kj[BN_LEN];
    float zero = 0.0f, one = 1.0f;
    memcpy(kj, BN.jmp, BN_LEN);
    memset(&BN, 0, sizeof(BN)); BN.stub = ks; BN.tramp = kt; memcpy(BN.jmp, kj, BN_LEN);   /* a stub made once is kept */
    memset(BN_PART, 0, sizeof(BN_PART)); memcpy(BN_PART + 0x314, &zero, 4); memcpy(BN_PART + 0x318, &one, 4);
    BN_LIST[0] = BN_PART;
    if (!known) _snprintf(BN.why, sizeof(BN.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_SITEPROG].hits != 1) _snprintf(BN.why, sizeof(BN.why), "SITEPROG signature has %d hits (need exactly 1)", g_hit[S_SITEPROG].hits);
    else {
        BN.entry = g_base + g_hit[S_SITEPROG].rva;
        if (memcmp(BN.entry, BN_ORIG, BN_LEN) != 0 && !(BN.stub && BN.entry[0] == 0xE9))
            _snprintf(BN.why, sizeof(BN.why), "the entry does not start with its known bytes");
        else if (((uintptr_t)BN.entry & 7) + BN_LEN > 8)
            _snprintf(BN.why, sizeof(BN.why), "the entry's first bytes would cross an 8-byte block");
        else BN.avail = 1;
    }
    log_line("  BARNAN %s %s", BN.avail ? "available" : "unavailable", BN.avail ? "" : BN.why);
    return BN.avail;
}

/* every call of the progress function while the stub is in */
static float barnan_wrap(uint8_t *b)
{
    if (BN.on && b) {
        int32_t n = -1;
        __try { n = *(volatile int32_t *)(b + 0x300); } __except (EXCEPTION_EXECUTE_HANDLER) { n = -1; BN.faults++; }
        if (n == 0) {
            __declspec(align(16)) uint8_t copy[BN_COPY];
            int ok = 0;
            __try { memcpy(copy, b, BN_COPY); ok = 1; } __except (EXCEPTION_EXECUTE_HANDLER) { BN.faults++; }
            if (ok) {
                *(uint8_t ***)(copy + 0x2F8) = BN_LIST; *(int32_t *)(copy + 0x300) = 1;
                BN.zeroed++; g_dirty = 1;
                return ((bn_fn)(void *)BN.tramp)(copy);
            }
        }
    }
    return ((bn_fn)(void *)BN.tramp)(b);
}

/* stub: mov rax,<wrapper>; jmp rax. Trampoline: the entry's 7 bytes; jmp [rip+0] -> entry + 7. The entry gets a 5-byte
 * jmp to the stub (relative to entry + 5) and two int3 (never run: the trampoline resumes at entry + 7). */
static int bn_make(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize), *resume = BN.entry + BN_LEN;
    void *fn = (void *)&barnan_wrap;
    size_t n = 0; int32_t rel; DWORD old;
    if (!p) return 0;
    p[n++] = 0x48; p[n++] = 0xB8; memcpy(p + n, &fn, 8); n += 8; p[n++] = 0xFF; p[n++] = 0xE0;
    n = (n + 15) & ~(size_t)15;
    BN.tramp = p + n;
    memcpy(p + n, BN_ORIG, BN_LEN); n += BN_LEN;
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0; memcpy(p + n, &resume, 8); n += 8;
    rel = (int32_t)((intptr_t)p - (intptr_t)(BN.entry + 5));
    BN.jmp[0] = 0xE9; memcpy(BN.jmp + 1, &rel, 4); BN.jmp[5] = 0xCC; BN.jmp[6] = 0xCC;
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    BN.stub = p;
    return 1;
}
/* the stub in (1) or out (0); 1 when it is as asked */
static int bn_set(int on)
{
    char w[160]; int r = 1;
    if (on) {
        if (!BN.stub && !bn_make()) { log_line("BARNAN: no free memory near the game module for a stub"); return 0; }
        if (memcmp(BN.entry, BN.jmp, BN_LEN) == 0) return 1;
        r = write_bytes(BN.entry, BN_ORIG, BN.jmp, BN_LEN, w, sizeof(w));
    } else {
        if (!BN.stub || memcmp(BN.entry, BN.jmp, BN_LEN) != 0) return 1;
        r = write_bytes(BN.entry, BN.jmp, BN_ORIG, BN_LEN, w, sizeof(w));
    }
    if (r != 1) { log_line("BARNAN: the entry not %s: %s", on ? "hooked" : "restored", w); if (r < 0) internal_failure("barnan write failed"); return 0; }
    return 1;
}

static void barnan_off(const char *why)
{
    if (!BN.avail) return;
    InterlockedExchange(&BN.on, 0);
    bn_set(0);
    log_line("BARNAN off (%s): zeroed %u faults %u", why, BN.zeroed, BN.faults);
    g_dirty = 1;
}

static void barnan_on(void)
{
    g_dirty = 1;
    if (!BN.avail) { BN.bad++; log_line("BARNAN ON refused: unavailable (%s)", BN.why); return; }
    InterlockedExchange(&BN.on, 1);
    if (!bn_set(1)) { barnan_off("the hook could not be set"); BN.avail = 0; _snprintf(BN.why, sizeof(BN.why), "the entry could not be written"); return; }
    log_line("BARNAN on (friend: a site with no parts yet reads its bar with no work done)");
}

static void barnan_cmd(int argc, char **argv)
{
    int v;
    g_dirty = 1;
    if (!BN.avail) { BN.bad++; log_line("BARNAN refused: unavailable (%s)", BN.why); return; }
    if (argc == 2 && on_off(argv[1], &v)) { if (v) barnan_on(); else barnan_off("BARNAN OFF"); return; }
    BN.bad++; log_line("BARNAN refused: needs ON | OFF");
}

/* ------------------------------------------------------------------ SITEHP (lane 71): a site's work done is the host's
 * Why (READ, getConstructionProgress 4d3d940, signature SPROG): a site's progress bar is
 *   0.5 * ( delivered goods / needed goods  +  sum of its parts' hp / sum of their max hp )
 * over the building's parts (the object list at +2F8h, count +300h; a part's hp float at +314h, its max at +318h, not
 * reflected). The goods half is the host's already (GOODS, exact mode); the hp half is each copy's own builders: so the
 * bar between 0 and 1 is the friend's own (NOFINISH holds only the end).
 *   SITEHP WATCH <b>        host: the site is read at every POLL
 *   SITEHP POLL             host: sitehp_out.txt = one line per watched site whose work fraction changed since the last
 *                           poll: "<b hex> <fraction bits hex>" (sum hp / sum max; FFFFFFFF = no parts)
 *   SITEHP HOLD <b> <frac>  friend: the work fraction (float bits, hex) to hold; every tick, when this copy's sum of hp
 *                           differs from frac * sum of max (more than a thousandth of it), the parts' hp are scaled to it
 *                           (each part in proportion, the rest filled in list order, never above a part's max)
 *   SITEHP HOLDX <b> <frac> friend (lane 87): the exact hold. Run p87a: with POLL's threshold (a fraction was reported
 *                           when it had moved by 0.0005), four decimals on the way and HOLD's margin (a thousandth of
 *                           the max) a friend's bar was a number the host did not show in 101 of 1,882 readings at
 *                           three decimals, and stood across a rounding edge of the proof's one decimal for days
 *                           (session l7b). HOLDX: every tick, when the fraction's bits (float sums in list order, one
 *                           float division: as the game makes them, 4d3da16) are neither the wanted ones nor the ones
 *                           this hold reached at its last write, the parts are filled IN LIST ORDER, as the game's own
 *                           builders fill them (4d27780: the first part that is not full up to its max, then the next):
 *                           full parts, one partial part, the rest 0, so that the game's sum over the game's max sum
 *                           is the wanted fraction bit for bit. The partial part is moved by one step of the sum's
 *                           float grid (at most 8 times) until it is. Where no sum of this copy's grid gives those
 *                           bits (the two copies can have different part counts, so different max sums) the nearest is
 *                           taken (one float step of the fraction, about 0.0000001 of the bar; counted "near"). A
 *                           part with max <= 0 is left alone (the game's adder skips it). Never above a part's max.
 *   POLL (lane 87): a site is reported when the BITS of its fraction changed.
 *   SITEHP FILL <b>         friend (lane 87): every part of this site to its max, at once (in the command, so ahead of
 *                           a FINISH that follows it in the same tick), and the site is no longer held. On the host a
 *                           site is finished by the stroke that fills its last part: a finished building's parts are
 *                           all full there. A friend's site is finished on the host's word, while its parts stand at
 *                           the host's last fraction as a site, and a hold still named would be applied once more
 *                           after the FINISH of that tick (the commands of a tick run before sitehp_tick).
 *   SITEHP DROP <b> | FORGET
 * Every site is checked alive at every use (object number and name as when it was named, a region, the part list's
 * count 0..1024, every part committed with a vtable in the module). Known build only.
 * (lane 87) The count's limit was 64 before 0.9.13. A church has 85 parts, a manor 69, a tavern 75, a large house 73, the
 * most seen 120 (game runs p87a, l7b): such a site was refused at its first POLL or HOLD on both copies, so a friend's
 * bar of every big building was its own builders' work. Status: "SITEHP available held=
 * watched= writes= polls= lines= gone= bad= faults=" or "SITEHP unavailable <why>". */
#define SH_MAX        256
#define SH_PARTS      0x2F8
#define SH_HP         0x314
#define SH_HPMAX      0x318
#define SH_PMAX       1024
#define SH_CHECK      0x400
typedef struct { uint8_t *b; uint32_t idx; uint64_t name; int mode; float want; float sent; int sentk;
                 uint32_t wbits, got; int gotk; } sh_ent;   /* mode 1 held, 2 watched, 3 held exactly (lane 87: wbits wanted, got reached) */
static struct {
    int avail; char why[160];
    sh_ent e[SH_MAX]; int n;
    unsigned writes, polls, lines, gone, bad, faults, nearn, fills;
} SH;

static float sh_abs(float x) { return x < 0.0f ? -x : x; }
static uint32_t sh_bits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float sh_float(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
/* the next float up or down, for a float that is 0 or more */
static float sh_step(float f, int up) { uint32_t u = sh_bits(f); if (up) u++; else if (u) u--; return sh_float(u); }

static int sitehp_status(char *buf, size_t len)
{
    int i, h = 0, w = 0, x = 0;
    if (g_off) return _snprintf(buf, len, "SITEHP unavailable dll is off\r\n");
    if (!SH.avail) return _snprintf(buf, len, "SITEHP unavailable %s\r\n", SH.why);
    for (i = 0; i < SH.n; i++) { if (SH.e[i].mode == 1) h++; else if (SH.e[i].mode == 3) { h++; x++; } else w++; }
    /* (lane 87) hx: of the held sites, those held exactly (HOLDX); near: exact holds that reached the nearest float only */
    return _snprintf(buf, len, "SITEHP available held=%d watched=%d writes=%u polls=%u lines=%u gone=%u bad=%u faults=%u hx=%d near=%u cap=%d fills=%u\r\n",
                     h, w, SH.writes, SH.polls, SH.lines, SH.gone, SH.bad, SH.faults, x, SH.nearn, SH_PMAX, SH.fills);
}

static int sitehp_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    memset(&SH, 0, sizeof(SH));
    if (!known) _snprintf(SH.why, sizeof(SH.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_SPROG].hits != 1) _snprintf(SH.why, sizeof(SH.why), "SPROG signature has %d hits (need exactly 1)", g_hit[S_SPROG].hits);
    else SH.avail = 1;
    log_line("  SITEHP %s %s", SH.avail ? "available" : "unavailable", SH.avail ? "" : SH.why);
    return SH.avail;
}

/* the site still that object, in the game, with a sane part list: its parts (NULL when not) */
static uint8_t *const *sh_parts(const sh_ent *e, int *n)
{
    const uint8_t *b = e->b; uint8_t *const *d; int32_t num, mx, i;
    if (!range_readable(b, SH_CHECK)) return NULL;
    if (*(const uint32_t *)(b + OBJ_INDEX_OFF) != e->idx || *(const uint64_t *)(b + OBJ_NAME_OFF) != e->name) return NULL;
    if (*(void *const *)(b + 0x2C8) == NULL) return NULL;                       /* no region: it left the game */
    d = *(uint8_t *const *const *)(b + SH_PARTS); num = *(const int32_t *)(b + SH_PARTS + 8); mx = *(const int32_t *)(b + SH_PARTS + 12);
    if (num < 0 || num > SH_PMAX || mx < num || (num && (!d || !range_readable(d, (size_t)num * 8)))) return NULL;
    for (i = 0; i < num; i++) {
        uintptr_t vt;
        if (!d[i] || ((uintptr_t)d[i] & 7) || !range_readable(d[i], SH_HPMAX + 4)) return NULL;
        vt = *(const uintptr_t *)d[i];
        if (vt < (uintptr_t)g_base || vt >= (uintptr_t)g_base + g_imgsize) return NULL;
    }
    *n = num;
    return d;
}

static void sh_sums(uint8_t *const *d, int n, float *hp, float *mx)
{
    int i; *hp = 0.0f; *mx = 0.0f;
    for (i = 0; i < n; i++) { *hp += *(const float *)(d[i] + SH_HP); *mx += *(const float *)(d[i] + SH_HPMAX); }
}

/* the parts' hp to want * max: each part in proportion, then what is left in list order */
static int sh_hold_one(sh_ent *e)
{
    int n = 0, i; uint8_t *const *d = sh_parts(e, &n);
    float hp, mx, goal, k, rest;
    if (!d) return -1;
    if (n == 0) return 0;
    sh_sums(d, n, &hp, &mx);
    if (!(mx > 0.0f)) return 0;
    goal = e->want * mx;
    if (goal < 0.0f) goal = 0.0f;
    if (goal > mx) goal = mx;
    if (sh_abs(hp - goal) <= 0.001f * mx) return 0;
    k = hp > 0.0f ? goal / hp : 0.0f;
    rest = goal;
    for (i = 0; i < n; i++) {
        float m = *(const float *)(d[i] + SH_HPMAX), v = *(const float *)(d[i] + SH_HP) * k;
        if (v > m) v = m;
        if (v < 0.0f) v = 0.0f;
        *(float *)(d[i] + SH_HP) = v; rest -= v;
    }
    for (i = 0; i < n && rest > 0.0f; i++) {
        float m = *(const float *)(d[i] + SH_HPMAX), v = *(const float *)(d[i] + SH_HP), add = m - v;
        if (add <= 0.0f) continue;
        if (add > rest) add = rest;
        *(float *)(d[i] + SH_HP) = v + add; rest -= add;
    }
    SH.writes++;
    return 1;
}

/* (lane 87) the exact hold of one site: see SITEHP HOLDX above. 1 written, 0 nothing to do, -1 the site is gone */
static int sh_hold_exact(sh_ent *e)
{
    static float t[SH_PMAX];                    /* the hp wanted, part by part (one thread: the game's tick) */
    int n = 0, i, k, part = -1, wrote = 0; uint8_t *const *d = sh_parts(e, &n);
    float S, M, want, tgt, acc, best, u; uint32_t qb; double bestd;
    if (!d) return -1;
    if (n == 0) return 0;
    sh_sums(d, n, &S, &M);
    if (!(M > 0.0f)) return 0;
    qb = sh_bits(S / M);
    if (qb == e->wbits || (e->gotk && qb == e->got)) return 0;
    want = sh_float(e->wbits);
    /* the hp sum whose division by M gives the wanted bits: the float nearest want * M, else one of its 8 neighbours */
    tgt = (float)((double)want * (double)M);
    if (tgt > M) tgt = M;
    if (!(tgt >= 0.0f)) tgt = 0.0f;
    best = tgt; bestd = 1e300;
    for (k = 0; k <= 8; k++) {
        float c = tgt; int j, s = (k + 1) / 2; double dd;
        for (j = 0; j < s; j++) c = sh_step(c, k & 1);
        if (c > M) continue;
        if (sh_bits(c / M) == e->wbits) { best = c; break; }
        dd = (double)(c / M) - (double)want; if (dd < 0.0) dd = -dd;
        if (dd < bestd) { bestd = dd; best = c; }
    }
    tgt = best;
    /* in list order: full parts while the game's own running sum stays at or under tgt, then one partial part */
    acc = 0.0f;
    for (i = 0; i < n; i++) {
        float m = *(const float *)(d[i] + SH_HPMAX), v;
        if (!(m > 0.0f)) { t[i] = *(const float *)(d[i] + SH_HP); acc += t[i]; continue; }
        if (acc + m <= tgt) v = m;
        else if (acc < tgt) { v = tgt - acc; if (v > m) v = m; part = i; }
        else v = 0.0f;
        t[i] = v; acc += v;
    }
    /* the game's sum of these must be tgt itself: the partial part moves by one step of tgt's grid until it is */
    u = sh_step(tgt, 1) - tgt;
    for (k = 0; k < 8 && part >= 0; k++) {
        float m = *(const float *)(d[part] + SH_HPMAX), sum = 0.0f, v;
        for (i = 0; i < n; i++) sum += t[i];
        if (sum == tgt) break;
        v = sum < tgt ? t[part] + u : t[part] - u;
        if (!(v >= 0.0f) || v > m) break;
        t[part] = v;
    }
    for (i = 0; i < n; i++) {
        if (!(*(const float *)(d[i] + SH_HPMAX) > 0.0f)) continue;
        if (sh_bits(*(const float *)(d[i] + SH_HP)) != sh_bits(t[i])) { *(float *)(d[i] + SH_HP) = t[i]; wrote = 1; }
    }
    sh_sums(d, n, &S, &M);
    e->got = sh_bits(S / M); e->gotk = 1;
    if (e->got != e->wbits) SH.nearn++;
    if (wrote) SH.writes++;
    return wrote;
}

static sh_ent *sh_find(const uint8_t *b) { int i; for (i = 0; i < SH.n; i++) if (SH.e[i].b == b) return &SH.e[i]; return NULL; }
static void sh_remove(sh_ent *e) { *e = SH.e[--SH.n]; memset(&SH.e[SH.n], 0, sizeof(sh_ent)); }

/* every tick (friend): each held site's hp as the host's fraction */
static void sitehp_tick(void)
{
    int i;
    if (!SH.avail || !SH.n) return;
    for (i = SH.n - 1; i >= 0; i--) {
        sh_ent *e = &SH.e[i];
        int r;
        if (e->mode != 1 && e->mode != 3) continue;
        __try { r = e->mode == 3 ? sh_hold_exact(e) : sh_hold_one(e); }
        __except (EXCEPTION_EXECUTE_HANDLER) { SH.faults++; r = -1; }
        if (r < 0) { SH.gone++; log_line("SITEHP: held %p is gone or not sane: dropped", (void *)e->b); sh_remove(e); g_dirty = 1; }
    }
}

static void sitehp_poll(void)
{
    char buf[SH_MAX * 32]; int n = 0, i;
    wchar_t path[MAX_PATH]; HANDLE h; DWORD wr;
    SH.polls++;
    for (i = SH.n - 1; i >= 0; i--) {
        sh_ent *e = &SH.e[i];
        int np = 0, ok = 1; uint8_t *const *d = NULL; float hp = 0.0f, mx = 0.0f, f = -1.0f; uint32_t bits;
        if (e->mode != 2) continue;
        __try {
            d = sh_parts(e, &np);
            if (d) { sh_sums(d, np, &hp, &mx); f = mx > 0.0f ? hp / mx : -1.0f; }
        } __except (EXCEPTION_EXECUTE_HANDLER) { SH.faults++; ok = 0; }
        if (!ok || !d) { SH.gone++; sh_remove(e); continue; }
        if (e->sentk && sh_bits(f) == sh_bits(e->sent)) continue;      /* (lane 87) the bits: was "moved by less than 0.0005" */
        e->sent = f; e->sentk = 1;
        if (f < 0.0f) bits = 0xFFFFFFFFu; else memcpy(&bits, &f, 4);
        n += _snprintf(buf + n, sizeof(buf) - (size_t)n, "%IX %08X\r\n", (uintptr_t)e->b, bits);
        SH.lines++;
    }
    if (n <= 0) return;
    join_path(path, g_dir, L"sitehp_out.txt");
    h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) { WriteFile(h, buf, (DWORD)n, &wr, NULL); CloseHandle(h); }
}

static void sitehp_add(const char *s, int mode, const char *fs)
{
    unsigned long long a = 0, fb = 0; char why[200]; sh_ent *e; uint8_t *b; float f = 0.0f; uint32_t u = 0;
    if (!parse_u64(s, &a) || !comp_sane(a, SH_CHECK, why, sizeof(why))) { SH.bad++; log_line("SITEHP refused: %s", a ? why : "not an address"); return; }
    if (mode == 1 || mode == 3) {
        char *end;
        fb = _strtoui64(fs, &end, 16);
        if (end == fs || *end || fb > 0xFFFFFFFFull) { SH.bad++; log_line("SITEHP HOLD refused: '%.20s' is not float bits (hex)", fs); return; }
        u = (uint32_t)fb; memcpy(&f, &u, 4);
        if (!(f >= 0.0f && f <= 1.0f)) { SH.bad++; log_line("SITEHP HOLD refused: %08X is not a fraction", u); return; }
    }
    b = (uint8_t *)(uintptr_t)a;
    e = sh_find(b);
    if (e && e->mode == mode && *(const uint32_t *)(b + OBJ_INDEX_OFF) == e->idx && *(const uint64_t *)(b + OBJ_NAME_OFF) == e->name) {
        if (e->wbits != u) e->gotk = 0;        /* (lane 87) another fraction is wanted: what the last write reached no longer counts */
        e->want = f; e->wbits = u; return;
    }
    if (e) sh_remove(e);
    if (SH.n >= SH_MAX) { SH.bad++; log_line("SITEHP refused: %d sites already", SH_MAX); return; }
    e = &SH.e[SH.n++]; memset(e, 0, sizeof(*e));
    e->b = b; e->idx = *(const uint32_t *)(b + OBJ_INDEX_OFF); e->name = *(const uint64_t *)(b + OBJ_NAME_OFF); e->mode = mode; e->want = f; e->wbits = u;
    log_line("SITEHP %s %p", mode == 1 ? "HOLD" : mode == 3 ? "HOLDX" : "WATCH", (void *)b);
}

/* (lane 87) SITEHP FILL <b>: see the head comment. The site is checked as for a hold (its own number and name of now). */
static void sitehp_fill(const char *s)
{
    unsigned long long a = 0; char why[200]; sh_ent tmp, *e; uint8_t *b; uint8_t *const *d = NULL; int n = 0, i, wrote = 0;
    if (!parse_u64(s, &a) || !comp_sane(a, SH_CHECK, why, sizeof(why))) { SH.bad++; log_line("SITEHP FILL refused: %s", a ? why : "not an address"); return; }
    b = (uint8_t *)(uintptr_t)a;
    e = sh_find(b);
    memset(&tmp, 0, sizeof(tmp));
    tmp.b = b; tmp.idx = *(const uint32_t *)(b + OBJ_INDEX_OFF); tmp.name = *(const uint64_t *)(b + OBJ_NAME_OFF);
    __try {
        d = sh_parts(&tmp, &n);
        if (d) for (i = 0; i < n; i++) {
            float m = *(const float *)(d[i] + SH_HPMAX);
            if (m > 0.0f && *(const float *)(d[i] + SH_HP) != m) { *(float *)(d[i] + SH_HP) = m; wrote = 1; }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { SH.faults++; d = NULL; }
    if (e) sh_remove(e);
    if (!d) { SH.bad++; log_line("SITEHP FILL refused: %p is not a site with a sane part list", (void *)b); return; }
    if (wrote) SH.writes++;
    SH.fills++;
}

static void sitehp_cmd(int argc, char **argv)
{
    if (argc >= 2 && _stricmp(argv[1], "POLL") == 0) { if (SH.avail) sitehp_poll(); return; }   /* the frequent one: no status file */
    g_dirty = 1;
    if (!SH.avail) { SH.bad++; log_line("SITEHP refused: unavailable (%s)", SH.why); return; }
    if (argc == 3 && _stricmp(argv[1], "WATCH") == 0) { sitehp_add(argv[2], 2, NULL); return; }
    if (argc == 4 && _stricmp(argv[1], "HOLD") == 0) { sitehp_add(argv[2], 1, argv[3]); return; }
    if (argc == 4 && _stricmp(argv[1], "HOLDX") == 0) { sitehp_add(argv[2], 3, argv[3]); return; }      /* lane 87 */
    if (argc == 3 && _stricmp(argv[1], "FILL") == 0) { sitehp_fill(argv[2]); return; }                  /* lane 87 */
    if (argc == 3 && _stricmp(argv[1], "DROP") == 0) {
        unsigned long long a = 0; sh_ent *e;
        if (parse_u64(argv[2], &a) && (e = sh_find((uint8_t *)(uintptr_t)a)) != NULL) sh_remove(e);
        return;
    }
    if (argc == 2 && _stricmp(argv[1], "FORGET") == 0) { SH.n = 0; memset(SH.e, 0, sizeof(SH.e)); log_line("SITEHP FORGET"); return; }
    SH.bad++; log_line("SITEHP refused: needs WATCH <b> | HOLD <b> <frac bits> | HOLDX <b> <frac bits> | FILL <b> | DROP <b> | FORGET | POLL");
}

/* ------------------------------------------------------------------ FAMROLL (lane 71): births, new families and sickness on the host's word
 * Why (READ):
 *   GROWTH. Region::growPopulation (4c64ee0, from updateDay 4d7775b) makes, at a day change, a person for the first family
 *   in list order with 1 or 2 people whose home is built and not in mourning (a wife for a husband alone, else a son), at
 *   4c65336, and on the days GetMonthlyPopChange names a new family in the first house with room, at 4c6590f; both
 *   through 4c51db0 (region, family or -1, role, home), which makes the villager with a name and looks of its own (rand).
 *   Each copy runs it from its own state at its own day change, so a friend's own copy can add a person or a family the
 *   host does not have, or the same person under another name (lane 64: "Niclas on the host, Wolfgang here"). The host's
 *   changes already travel (the people module's V G lines: a family arrived, a family's size, a family left), and a
 *   friend makes what its game did not (makeVillager through SpawnLivestock + AddNewFamilyMember, makeFamily: not
 *   4c51db0); the events module gives the host's names. Two callers only, both null-safe (a null result: the next family
 *   or house is tried; READ 4c65340, 4c65917); the third caller of 4c51db0 (4cdba10, from a letter) is let through.
 *   SICKNESS. In the family's daily step (4d8f670) on the family's day of the month (+2Fh): a sickness counter above 0
 *   counts down; else rand() & 7FFFh scaled to 0..30, and 0 (after day 30) makes the family sick: 4c3a410 writes the mark
 *   (+2Dh) and recomputes every member's stats (4ded390: work and walk penalties of a sick family). No notice, no death
 *   (lane 64). The mark is the host's (the facts module), but the friend's own roll still recomputed its members' stats.
 *   FAMROLL ON    friend: 4c51db0's entry (5 bytes "mov [rsp+10h],rbx") into a stub: a call from growPopulation's two
 *                 sites returns 0 at once (counted: births, families); every other call runs. And the sickness roll's
 *                 "jne" over the new sickness becomes "jmp" (one byte, 75 -> EB): this copy's game never makes a
 *                 family sick by itself; the count-down of a sickness the host gave runs as the game's own.
 *   FAMROLL OFF   both as they were (and ALLOFF).
 *   FAMROLL SITES <ret1> <ret2>   the two return addresses held (hex; by default growPopulation's, checked at the scan to be
 *                 E8 calls of the entry). For the offline test.
 * Signatures GROWMK (4c51db0's entry) and SICKROLL (the roll, 4d8f8fd); lanes 36 and 64 patch none of these bytes (their
 * sites: 4c66e20, 4c583e0, 4d8fed3, 4cfadbe, 4e1b5a5, 4d2f0bd, 4d63ce3). Known build only.
 * Status: "FAMROLL off|on births= families= passed= sick=0|1 faults= bad=" or "FAMROLL unavailable <why>". */
#define FR_LEN        5
#define FR_SICK_AT    39             /* SICKROLL: the jne over the new sickness */
#define FR_SITE1      0x1358B        /* growPopulation's return addresses less the entry (known build): a person ... */
#define FR_SITE2      0x13B64        /* ... and a new family */
static const uint8_t FR_ORIG[FR_LEN] = { 0x48, 0x89, 0x5C, 0x24, 0x10 };
typedef uint64_t (*fr_fn)(uint8_t *region, uint64_t fam, uint64_t role, uint64_t home);
static struct {
    int avail; char why[160];
    mr_hook mk; uint8_t *sick; int sickOn;
    volatile LONG on;
    uint64_t ret1, ret2;
    unsigned births, families, passed, faults, bad;
} FR;
static volatile uint64_t g_fr_ret;

static int famroll_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "FAMROLL unavailable dll is off\r\n");
    if (!FR.avail) return _snprintf(buf, len, "FAMROLL unavailable %s\r\n", FR.why);
    return _snprintf(buf, len, "FAMROLL %s births=%u families=%u passed=%u sick=%d sites=%d faults=%u bad=%u\r\n",
                     FR.on ? "on" : "off", FR.births, FR.families, FR.passed, FR.sickOn, (FR.ret1 ? 1 : 0) + (FR.ret2 ? 1 : 0), FR.faults, FR.bad);
}

static uint64_t fr_site(const uint8_t *entry, uint32_t off)
{
    const uint8_t *c = entry + off - 5; int32_t rel;
    if (!range_readable(c, 5) || c[0] != 0xE8) return 0;
    memcpy(&rel, c + 1, 4);
    return c + 5 + rel == entry ? (uint64_t)(uintptr_t)(c + 5) : 0;
}

static int famroll_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    mr_hook km = FR.mk;
    memset(&FR, 0, sizeof(FR)); FR.mk = km;
    if (!known) _snprintf(FR.why, sizeof(FR.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_GROWMK].hits != 1) _snprintf(FR.why, sizeof(FR.why), "GROWMK signature has %d hits (need exactly 1)", g_hit[S_GROWMK].hits);
    else if (g_hit[S_SICKROLL].hits != 1) _snprintf(FR.why, sizeof(FR.why), "SICKROLL signature has %d hits (need exactly 1)", g_hit[S_SICKROLL].hits);
    else {
        FR.mk.entry = g_base + g_hit[S_GROWMK].rva; FR.mk.orig = FR_ORIG;
        FR.sick = g_base + g_hit[S_SICKROLL].rva + FR_SICK_AT;
        if (memcmp(FR.mk.entry, FR_ORIG, FR_LEN) != 0 && !(FR.mk.stub && FR.mk.entry[0] == 0xE9)) _snprintf(FR.why, sizeof(FR.why), "the person maker does not start with its known bytes");
        else if (((uintptr_t)FR.mk.entry & 7) + FR_LEN > 8) _snprintf(FR.why, sizeof(FR.why), "the person maker's first bytes would cross an 8-byte block");
        else if (FR.sick[0] != 0x75 && FR.sick[0] != 0xEB) _snprintf(FR.why, sizeof(FR.why), "the sickness roll's jump is not 75");
        else {
            FR.avail = 1;
            FR.ret1 = fr_site(FR.mk.entry, FR_SITE1); FR.ret2 = fr_site(FR.mk.entry, FR_SITE2);
            if (!FR.ret1 || !FR.ret2) log_line("  FAMROLL: growPopulation's calls are not where they were read: only the sickness roll is held");
        }
    }
    log_line("  FAMROLL %s %s", FR.avail ? "available" : "unavailable", FR.avail ? "" : FR.why);
    return FR.avail;
}

static uint64_t famroll_wrap(uint8_t *region, uint64_t fam, uint64_t role, uint64_t home)
{
    uint64_t ret = g_fr_ret;
    if (FR.on && ret && (ret == FR.ret1 || ret == FR.ret2)) { if (ret == FR.ret1) FR.births++; else FR.families++; return 0; }
    if (FR.on) FR.passed++;
    return ((fr_fn)(void *)FR.mk.tramp)(region, fam, role, home);
}

/* stub: mov rax,[rsp]; mov [g_fr_ret],rax; mov rax,famroll_wrap; jmp rax. Trampoline: the 5 bytes; jmp [rip+0] -> entry+5 */
static int fr_make(void)
{
    mr_hook *h = &FR.mk;
    uint8_t *p = alloc_near(g_base, g_imgsize), *resume = h->entry + FR_LEN;
    void *fn = (void *)&famroll_wrap; volatile uint64_t *gr = &g_fr_ret;
    size_t n = 0; int32_t rel; DWORD old;
    if (!p) return 0;
    p[n++] = 0x48; p[n++] = 0x8B; p[n++] = 0x04; p[n++] = 0x24;
    p[n++] = 0x48; p[n++] = 0xA3; memcpy(p + n, &gr, 8); n += 8;
    p[n++] = 0x48; p[n++] = 0xB8; memcpy(p + n, &fn, 8); n += 8; p[n++] = 0xFF; p[n++] = 0xE0;
    n = (n + 15) & ~(size_t)15;
    h->tramp = p + n;
    memcpy(p + n, FR_ORIG, FR_LEN); n += FR_LEN;
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0; memcpy(p + n, &resume, 8); n += 8;
    rel = (int32_t)((intptr_t)p - (intptr_t)(h->entry + FR_LEN));
    h->jmp[0] = 0xE9; memcpy(h->jmp + 1, &rel, 4);
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    h->stub = p;
    return 1;
}

static int fr_sick(int on)
{
    static const uint8_t jne = 0x75, jmp = 0xEB;
    char w[160]; int r;
    if (FR.sickOn == on) return 1;
    r = write_bytes(FR.sick, on ? &jne : &jmp, on ? &jmp : &jne, 1, w, sizeof(w));
    if (r == 1) { FR.sickOn = on; return 1; }
    log_line("FAMROLL: the sickness roll's byte not %s: %s", on ? "patched" : "restored", w); if (r < 0) internal_failure("famroll byte write failed");
    return 0;
}

static void famroll_off(const char *why)
{
    char w[160]; int r = 1;
    if (!FR.avail) return;
    InterlockedExchange(&FR.on, 0);
    if (FR.mk.stub && memcmp(FR.mk.entry, FR.mk.jmp, FR_LEN) == 0) r = write_bytes(FR.mk.entry, FR.mk.jmp, FR_ORIG, FR_LEN, w, sizeof(w));
    if (r != 1) { log_line("FAMROLL: the entry could not be restored: %s", w); if (r < 0) internal_failure("famroll restore failed"); }
    fr_sick(0);
    log_line("FAMROLL off (%s): births %u families %u held, %u passed", why, FR.births, FR.families, FR.passed);
    g_dirty = 1;
}

static void famroll_on(void)
{
    char w[160]; int r = 1;
    g_dirty = 1;
    if (!FR.avail) { FR.bad++; log_line("FAMROLL ON refused: unavailable (%s)", FR.why); return; }
    if (!FR.mk.stub && !fr_make()) { FR.avail = 0; _snprintf(FR.why, sizeof(FR.why), "no free memory near the game module for the stub"); return; }
    InterlockedExchange(&FR.on, 1);
    if (memcmp(FR.mk.entry, FR.mk.jmp, FR_LEN) != 0) r = write_bytes(FR.mk.entry, FR_ORIG, FR.mk.jmp, FR_LEN, w, sizeof(w));
    if (r != 1 || !fr_sick(1)) { log_line("FAMROLL ON FAILED: %s", r != 1 ? w : "the sickness byte"); famroll_off("a write failed"); FR.avail = 0; _snprintf(FR.why, sizeof(FR.why), "a write failed"); if (r < 0) internal_failure("famroll hook write failed"); return; }
    log_line("FAMROLL on (friend: births, new families and sickness are the host's)");
}

static void famroll_cmd(int argc, char **argv)
{
    int v;
    g_dirty = 1;
    if (!FR.avail) { FR.bad++; log_line("FAMROLL refused: unavailable (%s)", FR.why); return; }
    if (argc == 2 && on_off(argv[1], &v)) { if (v) famroll_on(); else famroll_off("FAMROLL OFF"); return; }
    if (argc == 4 && _stricmp(argv[1], "SITES") == 0) {
        char *e1, *e2; unsigned long long a = _strtoui64(argv[2], &e1, 16), b = _strtoui64(argv[3], &e2, 16);
        if (*e1 || *e2) { FR.bad++; return; }
        FR.ret1 = a; FR.ret2 = b; return;
    }
    FR.bad++; log_line("FAMROLL refused: needs ON | OFF | SITES <ret1> <ret2>");
}
