/* ------------------------------------------------------------------ MAINT (lane 67): a building's maintenance on the host's word
 * (research/2026-11-10-game-probe/lanes/lane_s21_67/report.txt). Included by coop_patch.c.
 *
 * Why (READ in the game file, 0.8.117): a building's MaintenanceComponent (SMBuildingMaster +348h) keeps, per
 * maintenance type, a tracker in a map at +A8h (TMap<FMaintenanceTypes, FMaintenanceTrackerData>, the game's TSet:
 * elements of 20h bytes, the key's goods list (TArray of int32 good types) at +0, DurabilityLeft (int32) at +10h;
 * the allocation bits inline at +B8h or on the heap at +C8h, their count at +D0h; +B0h the element count, +DCh the
 * free count). The bar is DurabilityLeft / (2 x the type's supply amount) (GetMaintenancePercentage 4b984d0). The day
 * routine (TemporalComponent::updateDay 4d77905) takes 1, 2 or 4 off every tracker of a built building with workers
 * (4bb3410, signature MDECAY: by the slider at +F8h, half / normal / double), then caches the status at +A0h (4bb2b80
 * through 4b98650: 1 maintained, 2 pending, 3 unmaintained, from the trackers; a type is maintained while its tracker is
 * above 0, pending down to minus MaintenanceSettings.MaintenancePendingDays; on a change it adds or removes the
 * region's problem 50, Unmaintained).
 * A worker's hit (performHit action 40) and a delivery take one maintenance good out of the building's own Inventory
 * and set that type's tracker to full (4d16b40 -> 4b9e180). A friend's Inventory is the host's word (GOODS), so a
 * friend's trackers can only run down; the panel's status, its bar and the yield (GetActiveMaintenanceEffect 4b959c0
 * reads +A0h and +F8h; GetActiveProductivityModifiersWithValues calls it) then differ from the host's.
 *   MAINT READ <hex>,<hex>,...   writes maint.txt: per component "<hex> <status> <slider> <goods>=<left>,..." (goods
 *                                of one type sorted and joined by '+'; '-' for none), "<hex> ?" when it does not look
 *                                like a component; "END" last. Reads only.
 *   MAINT SET <hex> <status> <goods>=<left>,...|-   the host's word for that component, kept: written now and again
 *                                at every tick while the object is the same (its number +0Ch and name +18h as at SET)
 *                                and still has its tracker. A type this copy's component lacks is counted (miss).
 *   MAINT DROP <hex>,...         those entries out.        MAINT FORGET   every entry out (a load, a world change).
 * Data only: nothing is called, no code is patched. The offsets are the ones the three signatures hold (checked at the
 * scan). Known build only. The slider (+F8h) is NOT held here: it is a player action (coop_town.lua MAINT).
 * Status: "MAINT available held=<n> sets= writes= reads= misses= gone= bad= faults=" or "MAINT unavailable <why>". */
#define MC_STATUS      0xA0        /* uint8: the cached EMaintenanceStatus */
#define MC_MAP         0xA8        /* the trackers' elements (pointer), +8 their count */
#define MC_BITS_IN     0xB8        /* allocation bits, inline (4 dwords) */
#define MC_BITS_HEAP   0xC8        /* ... or on the heap (pointer, used when not null) */
#define MC_NUMBITS     0xD0
#define MC_SLIDER      0xF8        /* int32 EMaintenanceSliderValue */
#define MC_CHECK       0x100
#define MC_ELEM        0x20
#define MC_LEFT        0x10        /* element: DurabilityLeft */
#define MC_MAXEL       64
#define MC_MAXG        8
#define MC_MAXT        8           /* trackers of one held component */
#define MC_MAXH        2048        /* held components */
#define MST_STATUS_AT  3           /* MSTAT: "movzx eax,byte [rcx+A0h]": its disp32 */
#define MST_MAP_AT     36          /* ... GetMaintenanceStatusForTypes: "lea rdi,[rcx+A8h]" */
#define MDC_SLIDER_AT  29          /* MDECAY: "movzx edx,byte [rcx+F8h]" */
#define MDC_MAP_AT     73          /* ... "lea r14,[rcx+A8h]" */
#define MDS_SHIFT_AT   3           /* MDECSUB: "shl rax,5" */
#define MDS_LEFT_AT    13          /* ... "sub [rax+10h],ebx" */
#define OBJ_FLAGS_OFF  0x08        /* UObject: its flags (the day loop at 4d77cb8 skips an object with bit 30 set) */
#define OBJ_CLASS_OFF  0x10        /* UObject: its class */
#define MC_DEADFLAGS   (0x40000000u | 0x8000u | 0x10000u)   /* garbage (bit 30, as the day loop tests), begin / finish destroyed */

typedef struct { int ng; int32_t g[MC_MAXG]; int32_t left; } mctrk;
typedef struct { uint8_t *c; uint32_t idx; uint64_t name, cls; uint8_t status; int nt; mctrk t[MC_MAXT]; } mcent;
static struct { int avail; char why[160]; int n; mcent *e; unsigned sets, writes, reads, misses, gone, bad, faults; } MNT;

static int maint_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "MAINT unavailable dll is off\r\n");
    if (!MNT.avail) return _snprintf(buf, len, "MAINT unavailable %s\r\n", MNT.why);
    return _snprintf(buf, len, "MAINT available held=%d sets=%u writes=%u reads=%u misses=%u gone=%u bad=%u faults=%u\r\n",
                     MNT.n, MNT.sets, MNT.writes, MNT.reads, MNT.misses, MNT.gone, MNT.bad, MNT.faults);
}

static int maint_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    MNT.avail = 0; MNT.why[0] = 0; MNT.n = 0;
    if (!known) _snprintf(MNT.why, sizeof(MNT.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_MSTAT].hits != 1) _snprintf(MNT.why, sizeof(MNT.why), "MSTAT signature has %d hits (need exactly 1)", g_hit[S_MSTAT].hits);
    else if (g_hit[S_MDECAY].hits != 1) _snprintf(MNT.why, sizeof(MNT.why), "MDECAY signature has %d hits (need exactly 1)", g_hit[S_MDECAY].hits);
    else if (g_hit[S_MDECSUB].hits != 1) _snprintf(MNT.why, sizeof(MNT.why), "MDECSUB signature has %d hits (need exactly 1)", g_hit[S_MDECSUB].hits);
    else {
        const uint8_t *s = g_base + g_hit[S_MSTAT].rva, *d = g_base + g_hit[S_MDECAY].rva, *u = g_base + g_hit[S_MDECSUB].rva;
        uint32_t st, m1, sl, m2;
        memcpy(&st, s + MST_STATUS_AT, 4); memcpy(&m1, s + MST_MAP_AT, 4); memcpy(&sl, d + MDC_SLIDER_AT, 4); memcpy(&m2, d + MDC_MAP_AT, 4);
        if (st != MC_STATUS || m1 != MC_MAP || m2 != MC_MAP) _snprintf(MNT.why, sizeof(MNT.why), "the status is at +%X and the trackers at +%X / +%X, not +%X / +%X", st, m1, m2, MC_STATUS, MC_MAP);
        else if (sl != MC_SLIDER) _snprintf(MNT.why, sizeof(MNT.why), "the slider is at +%X, not +%X", sl, MC_SLIDER);
        else if (u[MDS_SHIFT_AT] != 5 || u[MDS_LEFT_AT] != MC_LEFT) _snprintf(MNT.why, sizeof(MNT.why), "a tracker is %d bytes with what is left at +%X", 1 << u[MDS_SHIFT_AT], u[MDS_LEFT_AT]);
        else MNT.avail = 1;
    }
    log_line("  MAINT %s %s", MNT.avail ? "available" : "unavailable", MNT.avail ? "" : MNT.why);
    return MNT.avail;
}

static void maint_forget(void) { if (MNT.e) free(MNT.e); MNT.e = NULL; MNT.n = 0; }

static int mt_cmp(const void *a, const void *b) { int32_t x = *(const int32_t *)a, y = *(const int32_t *)b; return x < y ? -1 : x > y; }

/* the component's trackers, read (under the caller's __try). Returns the count, or -1 when the map does not look like one. */
static int maint_trackers(const uint8_t *c, mctrk *out, int maxn, uint8_t **elems, int chk)
{
    uint8_t *data = *(uint8_t *volatile *)(c + MC_MAP);
    int32_t num = *(volatile int32_t *)(c + MC_MAP + 8), nb = *(volatile int32_t *)(c + MC_NUMBITS);
    const uint32_t *bits = *(const uint32_t *volatile *)(c + MC_BITS_HEAP);
    int i, n = 0;
    if (!bits) bits = (const uint32_t *)(c + MC_BITS_IN);
    if (num < 0 || num > MC_MAXEL || nb < 0 || nb > MC_MAXEL || (num > 0 && (!data || ((uintptr_t)data & 7)))) return -1;
    if (num == 0) return 0;
    /* chk: memory queried first (SET, READ); the tick's write-back relies on its __try alone (a query costs about 1 us) */
    if (chk && (!range_readable(data, (size_t)num * MC_ELEM) || !range_readable(bits, 4 * (size_t)((nb + 31) / 32 + 1)))) return -1;
    for (i = 0; i < num && i < nb; i++) {
        const uint8_t *e = data + (size_t)i * MC_ELEM;
        const int32_t *g; int32_t ng;
        if (!(bits[i >> 5] & (1u << (i & 31)))) continue;            /* a free slot */
        g = *(const int32_t *const *)e; ng = *(const int32_t *)(e + 8);
        if (ng < 0 || ng > MC_MAXG || (ng > 0 && (!g || (chk && !range_readable(g, (size_t)ng * 4))))) return -1;
        if (n >= maxn) return -1;
        out[n].ng = ng; if (ng) memcpy(out[n].g, g, (size_t)ng * 4);
        qsort(out[n].g, (size_t)ng, 4, mt_cmp);
        out[n].left = *(const int32_t *)(e + MC_LEFT);
        if (elems) elems[n] = (uint8_t *)e;
        n++;
    }
    return n;
}

static int maint_same_key(const mctrk *a, const mctrk *b) { return a->ng == b->ng && memcmp(a->g, b->g, (size_t)a->ng * 4) == 0; }

/* the host's word into this component: every tracker of a held type, and the status only when the component's own
 * map proves it is this building's (a held type found, or both without trackers). Under the caller's __try.
 * Returns 0 when the map does not look like one (the caller drops the entry). */
static int maint_apply(mcent *m, int first)
{
    mctrk have[MC_MAXEL]; uint8_t *el[MC_MAXEL];
    int n = maint_trackers(m->c, have, MC_MAXEL, el, first), i, j, found = 0;
    if (n < 0) { MNT.bad++; return 0; }
    for (i = 0; i < m->nt; i++) {
        for (j = 0; j < n; j++) if (maint_same_key(&m->t[i], &have[j])) break;
        if (j == n) { if (first) MNT.misses++; continue; }
        found++;
        if (have[j].left != m->t[i].left) { *(volatile int32_t *)(el[j] + MC_LEFT) = m->t[i].left; MNT.writes++; }
    }
    if ((found > 0 || (m->nt == 0 && n == 0)) && m->c[MC_STATUS] != m->status) { *(volatile uint8_t *)(m->c + MC_STATUS) = m->status; MNT.writes++; }
    return 1;
}

/* still the object of SET: its number, name and class as then, and not flagged garbage or destroyed */
static int maint_live(const mcent *m)
{
    return *(const uint32_t *)(m->c + OBJ_INDEX_OFF) == m->idx && *(const uint64_t *)(m->c + OBJ_NAME_OFF) == m->name &&
           *(const uint64_t *)(m->c + OBJ_CLASS_OFF) == m->cls && !(*(const uint32_t *)(m->c + OBJ_FLAGS_OFF) & MC_DEADFLAGS);
}

/* every tick: the held entries again (a cheap check of the object; the read and write run under __try) */
static void maint_tick(void)
{
    int i;
    if (g_off || !MNT.avail || MNT.n == 0) return;
    for (i = 0; i < MNT.n; ) {
        mcent *m = &MNT.e[i]; int ok = 0;
        __try { ok = maint_live(m) && maint_apply(m, 0); }
        __except (EXCEPTION_EXECUTE_HANDLER) { MNT.faults++; ok = 0; }
        if (!ok) { MNT.gone++; MNT.e[i] = MNT.e[--MNT.n]; g_dirty = 1; continue; }
        i++;
    }
}

/* "g+g=left,g=left" -> trackers; 0 on a bad form */
static int maint_parse(const char *s, mctrk *t, int *nt)
{
    *nt = 0;
    if (strcmp(s, "-") == 0) return 1;
    while (*s) {
        mctrk *x; char *e;
        if (*nt >= MC_MAXT) return 0;
        x = &t[(*nt)++]; x->ng = 0;
        for (;;) {
            long v = strtol(s, &e, 10);
            if (e == s || x->ng >= MC_MAXG) return 0;
            x->g[x->ng++] = (int32_t)v; s = e;
            if (*s == '+') { s++; continue; }
            if (*s == '=') { s++; break; }
            return 0;
        }
        x->left = (int32_t)strtol(s, &e, 10);
        if (e == s) return 0;
        s = e;
        qsort(x->g, (size_t)x->ng, 4, mt_cmp);
        if (*s == ',') { s++; if (!*s) return 0; continue; }
        if (*s) return 0;
    }
    return 1;
}

/* one component's line into buf (under the caller's __try); its length, 0 when it does not look like a component */
static int maint_line(const uint8_t *c, unsigned long long a, char *buf, int len)
{
    mctrk t[MC_MAXEL];
    int n = maint_trackers(c, t, MC_MAXEL, NULL, 1), i, j, k;
    if (n < 0) return 0;
    k = _snprintf(buf, (size_t)len, "%llX %u %d ", a, (unsigned)c[MC_STATUS], *(const int32_t *)(c + MC_SLIDER));
    if (n == 0) k += _snprintf(buf + k, (size_t)(len - k), "-");
    for (i = 0; i < n && k < len - 64; i++) {
        if (i) buf[k++] = ',';
        for (j = 0; j < t[i].ng; j++) k += _snprintf(buf + k, (size_t)(len - k), j ? "+%d" : "%d", t[i].g[j]);
        k += _snprintf(buf + k, (size_t)(len - k), "=%d", t[i].left);
    }
    buf[k++] = '\r'; buf[k++] = '\n';
    return k;
}

static void maint_read(int argc, char **argv)
{
    wchar_t path[MAX_PATH];
    HANDLE h; DWORD wr;
    char *p, *q, line[1024];
    join_path(path, g_dir, L"maint.txt");
    h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) { MNT.bad++; log_line("MAINT READ: cannot write maint.txt (error %lu)", GetLastError()); return; }
    if (argc == 3) for (p = argv[2]; p && *p; p = q) {
        unsigned long long a; char *e; char why[200]; int k = 0;
        q = strchr(p, ','); if (q) *q++ = 0;
        a = _strtoui64(p, &e, 16);
        if (e != p && !*e && comp_sane(a, MC_CHECK, why, sizeof(why))) {
            __try { k = maint_line((const uint8_t *)(uintptr_t)a, a, line, (int)sizeof(line)); }
            __except (EXCEPTION_EXECUTE_HANDLER) { MNT.faults++; k = 0; }
        }
        if (k > 0) MNT.reads++;
        else k = _snprintf(line, sizeof(line), "%.40s ?\r\n", p);
        WriteFile(h, line, (DWORD)k, &wr, NULL);
    }
    WriteFile(h, "END\r\n", 5, &wr, NULL);
    CloseHandle(h);
}

static void maint_set(int argc, char **argv)
{
    unsigned long long a; char *e; char why[200];
    mcent m; int i, nt;
    memset(&m, 0, sizeof(m));
    if (argc != 5) { MNT.bad++; log_line("MAINT SET refused: needs <component> <status> <trackers>"); return; }
    a = _strtoui64(argv[2], &e, 16);
    if (e == argv[2] || *e) { MNT.bad++; log_line("MAINT SET refused: '%.40s' is not an address", argv[2]); return; }
    i = (int)strtol(argv[3], &e, 10);
    if (e == argv[3] || *e || i < 0 || i > 3) { MNT.bad++; log_line("MAINT SET refused: status '%.10s'", argv[3]); return; }
    m.status = (uint8_t)i;
    if (!maint_parse(argv[4], m.t, &nt)) { MNT.bad++; log_line("MAINT SET refused: trackers '%.80s'", argv[4]); return; }
    m.nt = nt;
    if (!comp_sane(a, MC_CHECK, why, sizeof(why))) { MNT.bad++; log_line("MAINT SET refused: %s", why); return; }
    m.c = (uint8_t *)(uintptr_t)a;
    __try {
        mctrk t[MC_MAXEL];
        if (maint_trackers(m.c, t, MC_MAXEL, NULL, 1) < 0) { MNT.bad++; log_line("MAINT SET refused: %llX has no tracker map that looks like one", a); return; }
        m.idx = *(const uint32_t *)(m.c + OBJ_INDEX_OFF); m.name = *(const uint64_t *)(m.c + OBJ_NAME_OFF); m.cls = *(const uint64_t *)(m.c + OBJ_CLASS_OFF);
        if (*(const uint32_t *)(m.c + OBJ_FLAGS_OFF) & MC_DEADFLAGS) { MNT.bad++; log_line("MAINT SET refused: %llX is flagged garbage or destroyed", a); return; }
        for (i = 0; i < MNT.n; i++) if (MNT.e[i].c == m.c) break;
        if (i == MNT.n) {
            mcent *ne;
            if (MNT.n >= MC_MAXH) { MNT.bad++; log_line("MAINT SET refused: %d components held already", MNT.n); return; }
            ne = (mcent *)realloc(MNT.e, (size_t)(MNT.n + 1) * sizeof(mcent));
            if (!ne) { MNT.bad++; return; }
            MNT.e = ne; MNT.n++;
        }
        MNT.e[i] = m; MNT.sets++;
        (void)maint_apply(&MNT.e[i], 1);
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { MNT.faults++; log_line("MAINT SET: exception %08lX", GetExceptionCode()); }
}

static void maint_cmd(int argc, char **argv)
{
    g_dirty = 1;
    if (!MNT.avail) { MNT.bad++; log_line("MAINT refused: unavailable (%s)", MNT.why); return; }
    if (argc >= 2 && _stricmp(argv[1], "READ") == 0) { maint_read(argc, argv); return; }
    if (argc >= 2 && _stricmp(argv[1], "SET") == 0) { maint_set(argc, argv); return; }
    if (argc == 2 && _stricmp(argv[1], "FORGET") == 0) { maint_forget(); log_line("MAINT FORGET: every entry out"); return; }
    if (argc == 3 && _stricmp(argv[1], "DROP") == 0) {
        char *p, *q;
        for (p = argv[2]; p && *p; p = q) {
            unsigned long long a; char *e; int i;
            q = strchr(p, ','); if (q) *q++ = 0;
            a = _strtoui64(p, &e, 16);
            if (e == p || *e) { MNT.bad++; continue; }
            for (i = 0; i < MNT.n; i++) if ((uintptr_t)MNT.e[i].c == (uintptr_t)a) { MNT.e[i] = MNT.e[--MNT.n]; break; }
        }
        return;
    }
    MNT.bad++; log_line("MAINT refused: READ, SET, DROP or FORGET");
}
