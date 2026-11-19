/* coop_fields.h - lane 40 (FIELD): a field's or garden's plants on a friend's copy are the host's.
 * Included once by coop_patch.c, right before its command section; everything here is this lane's own block.
 * Evidence: research\2026-11-10-game-probe\lanes\lane_s21_40\report.txt.
 *
 * What a field is (read in the game file and the reflected struct Plant, lane 40): an SMBuildingMaster holds its plants
 * in an unreflected list at +530h (data, count +538h, capacity +53Ch), 0D0h bytes a plant: Type +0 (crop, byte), Pos +8
 * (3 doubles), plowed +20h (float), growth +24h (float), instanceID +28h, Rotation +2Ch, plowAngle +30h, typeBefore +48h
 * (byte), yield +4Ch (int), instanceTransform +50h, plantISM +B0h (the instanced mesh), +BCh (a fertility cell, not
 * reflected), FertilityWhenPlantedQuant +C1h (byte).
 * Who changes plants: the plough step (4d18360), the sow and the harvest of a villager's work hit (inline in 4dc5270),
 * the day's growth (4d156d0), eraseCrops, setCropType. Each of them calls UpdateFieldCache (FCACHE) right after.
 * What a player sees of a plant: its mesh instance (drawn by FDRAW from crop and growth) and the ploughed ground (painted
 * by FPAINT at its place).
 *
 * Friend (held fields): the host's plants are the "shadow". FCACHE's entry is hooked: before the game counts a held
 * field, every plant that differs from the shadow is put back and drawn again (and its ground painted again), in the same
 * call, so the friend's own villagers' work and growth never show. FIELD SET writes the host's changes the same way and
 * then runs the game's own UpdateFieldCache, so the panel's numbers follow.
 * Host (watched fields): FIELD POLL compares every watched field with what was last sent and writes the changes to
 * field_out.txt. Nothing of the game is patched on the host.
 *
 *   FIELD HOOK ON|OFF               friend: the FCACHE hook in or out (OFF also drops every held field)
 *   FIELD HOLD <b> / DROP <b>       friend: hold a field / let it go          FIELD FORGET   all of them (both roles)
 *   FIELD SET <b> <n> <ops>         friend: the host's changes (n = the host's number of plants)
 *   FIELD CHECK <b> <n> <crc>       friend: compare the host's checksum with this copy's plants (counted, logged)
 *   FIELD WATCH <b> / FULL <b>|ALL  host: watch a field / send all of it at the next poll
 *   FIELD POLL                      host: field_out.txt = one line per changed field: <b hex> <n> <crc> <ops>
 *   FIELD CUT <b> <list> <n>        cut a point list (660 FieldPoints, 6A8 fieldBorderPoints, 6B8 finalBorder) to n
 *   FIELD DUMP <b> <tag>            field_dump_<tag>.txt (read only)
 * ops = op;op;...   op = <ranges>=<crop>.<plowed hex>.<growth hex>.<yield>.<typeBefore>.<fertility>
 *                        g<step hex>:<ranges>    (growth = min(growth + step, 1) for these plants)
 *                        d<ranges>=<x>.<y>.<z>   (the drawn size, the doubles' bits)
 *                        c<12 x 8 hex>           (the counted numbers, FLD_CACHE_OFF order)
 *                   ranges = a-b,c,...   (plant numbers)
 * Every command is refused on another game build (the plant offsets are not held by a signature). */
#define FLD_PLANTS_OFF   0x530
#define FLD_PLANT_SIZE   0xD0
#define FLD_ENGINE_OFF   0x2E8
#define FLD_CHECK        0x1100      /* bytes of the building that must be readable */
#define FLD_MAX_PLANTS   20000
#define FLD_MAX          1024        /* fields held or watched (a large town has a few hundred gardens) */
#define FLD_REGION_OFF   0x2C8       /* SMBuildingMaster.Region: none once the building has left the game */
#define FLD_HOOK_LEN     8
#define FLD_DRAW_NOW     48          /* more plants than this put back in one call are drawn from the tick's queue */
#define FLD_DRAW_TICK    64          /* plants the tick draws at most */
#define FLD_OPS_MAX      2400        /* characters of ops per output line */
#define FLD_CACHE_N      12          /* the counted numbers of a field: +BE0h..+BFCh (sowing, ploughing, growing, planted
                                      * average growth, harvesting, ready, unplowed, sown), yield +584h, operation mode
                                      * +4DCh, plannedHarvest_DaysLeft +578h, plannedHarvest_PredictedYield +57Ch */
static const uint16_t FLD_CACHE_OFF[FLD_CACHE_N] = { 0xBE0, 0xBE4, 0xBE8, 0xBEC, 0xBF0, 0xBF4, 0xBF8, 0xBFC, 0x584, 0x4DC, 0x578, 0x57C };
static int on_off(const char *w, int *v);            /* coop_patch.c, command section */
static const uint8_t FLD_CACHE_ORIG[FLD_HOOK_LEN] = { 0x40, 0x53, 0x41, 0x55, 0x48, 0x83, 0xEC, 0x38 };
typedef struct { uint8_t *data; int32_t num, max; } fld_arr;
typedef struct { float pl, gr; int32_t yl; uint8_t crop, tb, c1, known; double ds[3]; uint8_t dsk, pad[7]; } frec;   /* ds: the drawn scale */
typedef char frec_size_ok[sizeof(frec) == 48 ? 1 : -1];
typedef char (*fupd_fn)(void *ism, int idx, const void *transform, char world, char dirty, char teleport);
#define FLD_UPDATE_VT    0xB58       /* the instanced mesh's UpdateInstanceTransform (the drawing routine's own call at 4d24800) */
typedef void (*fdraw_fn)(void *field, int idx);
typedef void (*fpaint_fn)(void *engine, const double *pos, float amount, char add);
typedef void (*fcache_fn)(void *field, char ploughing, char sowing, char growing, char harvesting);
typedef struct {
    uint8_t *b; uint32_t idx; uint64_t name;
    int mode;               /* 1 = held (friend), 2 = watched (host) */
    int n;                  /* the host's number of plants (friend) / the number last sent (host; -1 never) */
    frec *r; int cap;       /* the shadow (friend) / what was last sent (host) */
    int32_t fc[FLD_CACHE_N]; int fc_known;   /* the field's counted numbers (panel): the host's (friend) / last sent (host) */
    int full;               /* host: everything at the next poll */
    int redraw;             /* friend: plants from here on are still to be drawn by the tick (-1 none) */
    int shortnote;          /* friend: the count mismatch was logged */
    int drawing;            /* friend: the engine was drawing this field at the last tick */
} fent;

static struct {
    int avail; char why[160];
    uint8_t *cache, *draw, *paint, *stub, *tramp;
    uint8_t jmp[FLD_HOOK_LEN];
    volatile LONG enabled; int own; DWORD thread; volatile LONG want_off; DWORD fault_code;
    int n; fent e[FLD_MAX];
    ULONGLONG last_audit;
    unsigned long long dumps, refused, hookcalls, heldcalls, restored, drawn, painted, queued, nodraw, sets, setpts, grows, beyond, unknown,
                       polls, lines, outbytes, checkok, checkbad, audits, leaks, cuts, otherthread, faults, gone, countdiff, scaled, sizes, followed, sizeleaks, notlive,
                       cachefix;   /* lane 71: counted numbers put back by the audit (written outside UpdateFieldCache) */
    LONGLONG qpf, qhook, qset, qpoll;                    /* time inside the hook, SET and POLL (QueryPerformanceCounter units) */
} FL;

static int fld_bytes_on(void)  { return FL.stub && memcmp(FL.cache, FL.jmp, FLD_HOOK_LEN) == 0; }
static int fld_bytes_off(void) { return FL.cache && memcmp(FL.cache, FLD_CACHE_ORIG, FLD_HOOK_LEN) == 0; }

static int field_scan(void)
{
    LARGE_INTEGER qf;
    memset(&FL, 0, sizeof(FL));
    QueryPerformanceFrequency(&qf); FL.qpf = qf.QuadPart;
    if (g_hit[S_FCACHE].hits != 1 || g_hit[S_FDRAW].hits != 1 || g_hit[S_FPAINT].hits != 1)
        _snprintf(FL.why, sizeof(FL.why), "signature hits FCACHE %d FDRAW %d FPAINT %d (need exactly 1 each)", g_hit[S_FCACHE].hits, g_hit[S_FDRAW].hits, g_hit[S_FPAINT].hits);
    else if (g_stamp != KNOWN_TIMESTAMP || g_imgsize != KNOWN_IMAGESIZE)
        _snprintf(FL.why, sizeof(FL.why), "not the known game build (the plant offsets are not in a signature)");
    else {
        FL.cache = g_base + g_hit[S_FCACHE].rva; FL.draw = g_base + g_hit[S_FDRAW].rva; FL.paint = g_base + g_hit[S_FPAINT].rva;
        if (((uintptr_t)FL.cache & 7) != 0) _snprintf(FL.why, sizeof(FL.why), "FCACHE's first 8 bytes are not one aligned block");
        else if (memcmp(FL.cache, FLD_CACHE_ORIG, FLD_HOOK_LEN) != 0) _snprintf(FL.why, sizeof(FL.why), "FCACHE does not start with its known instructions");
        else FL.avail = 1;
    }
    log_line("  FIELD  %s %s", FL.avail ? "idle" : "unavailable", FL.avail ? "" : FL.why);
    return FL.avail;
}

static int field_status(char *buf, size_t len)
{
    int n = 0, held = 0, watched = 0, i;
    for (i = 0; i < FL.n; i++) { if (FL.e[i].mode == 1) held++; else watched++; }
    if (g_off || !FL.avail) n += _snprintf(buf + n, len - (size_t)n, "FIELD unavailable %s\r\n", g_off ? "dll is off" : FL.why);
    else n += _snprintf(buf + n, len - (size_t)n, "FIELD %s\r\n", fld_bytes_on() ? "hooked" : fld_bytes_off() ? "idle" : "unavailable its entry holds unknown bytes");
    n += _snprintf(buf + n, len - (size_t)n,
                   "fields held=%d watched=%d hookcalls=%llu heldcalls=%llu restored=%llu drawn=%llu painted=%llu queued=%llu nodraw=%llu sets=%llu setpts=%llu grows=%llu beyond=%llu unknown=%llu "
                   "polls=%llu lines=%llu outbytes=%llu checkok=%llu checkbad=%llu audits=%llu leaks=%llu cuts=%llu countdiff=%llu gone=%llu otherthread=%llu dumps=%llu refused=%llu faults=%llu "
                   "ushook=%lld usset=%lld uspoll=%lld scaled=%llu sizes=%llu followed=%llu sizeleaks=%llu notlive=%llu cachefix=%llu\r\n",
                   held, watched, FL.hookcalls, FL.heldcalls, FL.restored, FL.drawn, FL.painted, FL.queued, FL.nodraw, FL.sets, FL.setpts, FL.grows, FL.beyond, FL.unknown,
                   FL.polls, FL.lines, FL.outbytes, FL.checkok, FL.checkbad, FL.audits, FL.leaks, FL.cuts, FL.countdiff, FL.gone, FL.otherthread, FL.dumps, FL.refused, FL.faults,
                   FL.qpf ? FL.qhook * 1000000 / FL.qpf : 0, FL.qpf ? FL.qset * 1000000 / FL.qpf : 0, FL.qpf ? FL.qpoll * 1000000 / FL.qpf : 0, FL.scaled, FL.sizes, FL.followed, FL.sizeleaks, FL.notlive, FL.cachefix);
    return n < 0 ? 0 : n;
}

/* ---------------------------------------------------------------- plants */
static int fld_arr_sane(const fld_arr *a, size_t elem)
{
    if (a->num < 0 || a->num > FLD_MAX_PLANTS || a->max < a->num) return 0;
    if (a->num == 0) return 1;
    return a->data && range_readable(a->data, (size_t)a->num * elem);
}
static const fld_arr *fld_plants(const uint8_t *b) { return (const fld_arr *)(b + FLD_PLANTS_OFF); }
static void fld_read(const uint8_t *q, frec *r)
{
    r->crop = q[0]; r->pl = *(const float *)(q + 0x20); r->gr = *(const float *)(q + 0x24); r->tb = q[0x48];
    r->yl = *(const int32_t *)(q + 0x4C); r->c1 = q[0xC1]; r->known = 1;
    memcpy(r->ds, q + 0x90, 24); r->dsk = 1;
}
static int fld_ds_differ(const frec *cur, const frec *s) { return s->dsk && memcmp(cur->ds, s->ds, 24) != 0; }
static int fld_same(const frec *a, const frec *b)
{
    return a->crop == b->crop && a->tb == b->tb && a->c1 == b->c1 && a->yl == b->yl &&
           memcmp(&a->pl, &b->pl, 4) == 0 && memcmp(&a->gr, &b->gr, 4) == 0;
}
static uint32_t fld_crc_rec(uint32_t h, const frec *r)
{
    uint8_t k[14]; int i;
    k[0] = r->crop; k[1] = r->tb; k[2] = r->c1; memcpy(k + 3, &r->pl, 4); memcpy(k + 7, &r->gr, 4); memcpy(k + 11, &r->yl, 3);
    for (i = 0; i < 14; i++) { h ^= k[i]; h *= 16777619u; }
    return h;
}

static fent *fld_find(const uint8_t *b) { int i; for (i = 0; i < FL.n; i++) if (FL.e[i].b == b) return &FL.e[i]; return NULL; }
static int fld_alive(const fent *e)
{
    if (!range_readable(e->b, FLD_CHECK)) return 0;
    return *(const uint32_t *)(e->b + OBJ_INDEX_OFF) == e->idx && *(const uint64_t *)(e->b + OBJ_NAME_OFF) == e->name;
}
/* the held object is still this field and still in the game: object index and name as when it was held, and a region
 * (a demolished building stays a valid object for a while but has none: lanes/lane_s21_0/crash_demolish_site). Cheap:
 * no memory query (the callers run under __try) */
static int fld_live(const fent *e)
{
    return *(const uint32_t *)(e->b + OBJ_INDEX_OFF) == e->idx && *(const uint64_t *)(e->b + OBJ_NAME_OFF) == e->name &&
           *(void *const *)(e->b + FLD_REGION_OFF) != NULL;
}
static void fld_remove(fent *e)
{
    if (e->r) free(e->r);
    *e = FL.e[--FL.n];
    memset(&FL.e[FL.n], 0, sizeof(fent));
}
static int fld_grow(fent *e, int n)
{
    frec *p;
    if (n <= e->cap) return 1;
    p = (frec *)realloc(e->r, (size_t)n * sizeof(frec));
    if (!p) return 0;
    memset(p + e->cap, 0, (size_t)(n - e->cap) * sizeof(frec));
    e->r = p; e->cap = n;
    return 1;
}

/* the game's own drawing of one plant (its mesh instance from crop and growth); only with a mesh that looks alive */
static int fld_draw(uint8_t *b, int i)
{
    const fld_arr *p = fld_plants(b);
    uint8_t *q = p->data + (size_t)i * FLD_PLANT_SIZE;
    uintptr_t ism = *(const uintptr_t *)(q + 0xB0), vt;
    if (!ism || (ism & 7) || !range_readable((const void *)ism, 0x100)) { FL.nodraw++; return 0; }
    vt = *(const uintptr_t *)ism;
    if (vt < (uintptr_t)g_base || vt >= (uintptr_t)g_base + g_imgsize) { FL.nodraw++; return 0; }
    FL.own++;
    ((fdraw_fn)(void *)FL.draw)(b, i);
    FL.own--;
    FL.drawn++;
    return 1;
}
/* the drawn size as the host's: the drawing routine skips a change below 5 % of the size (constant at 7202d28), so
 * the size a plant shows depends on when it was last drawn; the host's size is written with the mesh's own
 * UpdateInstanceTransform, as the drawing routine calls it (world space, render state dirty, no teleport), and kept in the
 * plant's transform (+50h; its scale at +90h) */
static int fld_setscale(uint8_t *b, int i, const double *ds)
{
    const fld_arr *p = fld_plants(b);
    uint8_t *q = p->data + (size_t)i * FLD_PLANT_SIZE;
    uintptr_t ism = *(const uintptr_t *)(q + 0xB0), vt, fn;
    __declspec(align(16)) uint8_t t[0x60];
    if (!ism || (ism & 7) || !range_readable((const void *)ism, 0x100)) { FL.nodraw++; return 0; }
    vt = *(const uintptr_t *)ism;
    if (vt < (uintptr_t)g_base || vt >= (uintptr_t)g_base + g_imgsize || !range_readable((const void *)(vt + FLD_UPDATE_VT), 8)) { FL.nodraw++; return 0; }
    fn = *(const uintptr_t *)(vt + FLD_UPDATE_VT);
    if (fn < (uintptr_t)g_text || fn >= (uintptr_t)g_text + g_text_len) { FL.nodraw++; return 0; }
    memcpy(t, q + 0x50, 0x60);
    memcpy(t + 0x40, ds, 24);
    FL.own++;
    ((fupd_fn)(void *)fn)((void *)ism, *(const int32_t *)(q + 0x28), t, 1, 1, 0);
    FL.own--;
    memcpy(q + 0x90, ds, 24);
    FL.scaled++;
    return 1;
}

/* the ploughed ground at the plant's place: cleared (the harvest's own stroke), then the plant's plough painted (the
 * plough step's own stroke) */
static void fld_paint(uint8_t *b, int i, float pl)
{
    const fld_arr *p = fld_plants(b);
    const double *pos = (const double *)(p->data + (size_t)i * FLD_PLANT_SIZE + 8);
    uint8_t *eng = *(uint8_t *const *)(b + FLD_ENGINE_OFF);
    if (!eng || ((uintptr_t)eng & 7) || !range_readable(eng, 0x700)) return;
    FL.own++;
    ((fpaint_fn)(void *)FL.paint)(eng, pos, -10.0f, 0);
    if (pl > 0.0f) ((fpaint_fn)(void *)FL.paint)(eng, pos, pl, 1);
    FL.own--;
    FL.painted++;
}

/* put the shadow into the plants that differ; draw = 1: draw them now (up to FLD_DRAW_NOW, the rest from the tick) */
static unsigned long long g_fld_sizefix;                 /* sizes put back by the last fld_restore (the rest: plants) */
static int fld_restore(fent *e, int draw_now)
{
    const fld_arr *p = fld_plants(e->b);
    int m, i, k = 0;
    if (p->num < 0 || p->num > FLD_MAX_PLANTS || (p->num && !p->data)) return 0;
    if (p->num != e->n && e->n >= 0) {
        FL.countdiff++;
        if (!e->shortnote) { e->shortnote = 1; log_line("FIELD: %p has %d plants here, %d on the host", (void *)e->b, p->num, e->n); }
    }
    m = p->num < e->n ? p->num : e->n;
    if (m > e->cap) m = e->cap;
    for (i = 0; i < m; i++) {
        uint8_t *q = p->data + (size_t)i * FLD_PLANT_SIZE;
        const frec *s = &e->r[i];
        frec cur;
        int look, plough;
        if (!s->known) continue;
        fld_read(q, &cur);
        if (fld_same(&cur, s)) {
            if (fld_ds_differ(&cur, s)) { fld_setscale(e->b, i, s->ds); k++; g_fld_sizefix++; }    /* drawn otherwise: the host's size */
            continue;
        }
        look = cur.crop != s->crop || cur.tb != s->tb || memcmp(&cur.gr, &s->gr, 4) != 0;
        plough = memcmp(&cur.pl, &s->pl, 4) != 0;
        q[0] = s->crop; *(float *)(q + 0x20) = s->pl; *(float *)(q + 0x24) = s->gr; q[0x48] = s->tb; *(int32_t *)(q + 0x4C) = s->yl; q[0xC1] = s->c1;
        if (plough) fld_paint(e->b, i, s->pl);
        if (look) {
            if (draw_now && k < FLD_DRAW_NOW) { fld_draw(e->b, i); fld_read(q, &cur); if (fld_ds_differ(&cur, s)) fld_setscale(e->b, i, s->ds); }
            else { if (e->redraw < 0 || e->redraw > i) e->redraw = i; FL.queued++; }
        } else if (fld_ds_differ(&cur, s)) fld_setscale(e->b, i, s->ds);
        k++;
    }
    return k;
}

/* ---------------------------------------------------------------- the hook (friend) */
static void fld_cache_read(const uint8_t *b, int32_t *v) { int i; for (i = 0; i < FLD_CACHE_N; i++) v[i] = *(const int32_t *)(b + FLD_CACHE_OFF[i]); }
static void fld_cache_put(fent *e) { int i; if (e->fc_known) for (i = 0; i < FLD_CACHE_N; i++) *(int32_t *)(e->b + FLD_CACHE_OFF[i]) = e->fc[i]; }

/* before the game counts a held field: its plants as the host's */
static fent *field_event(uint8_t *b)
{
    fent *e;
    int k;
    FL.hookcalls++;
    if (!FL.enabled || !FL.n) return NULL;
    if (GetCurrentThreadId() != FL.thread) { FL.otherthread++; return NULL; }
    e = fld_find(b);
    if (!e || e->mode != 1) return NULL;
    if (!fld_live(e)) { FL.notlive++; return NULL; }        /* another object at the address, or the field left the game */
    FL.heldcalls++;
    { LARGE_INTEGER t0, t1; QueryPerformanceCounter(&t0);
      k = fld_restore(e, 1);
      QueryPerformanceCounter(&t1); FL.qhook += t1.QuadPart - t0.QuadPart; }
    FL.restored += (unsigned long long)k;
    return e;
}
static void fld_fault(DWORD code)
{
    InterlockedExchange(&FL.enabled, 0);
    FL.faults++; FL.fault_code = code;
    InterlockedExchange(&FL.want_off, 1);
}
/* UpdateFieldCache's entry jumps here (same arguments): the host's plants first, then the game's own routine (the
 * moved first bytes and a jump back: the trampoline), then the host's counted numbers over the ones it computed (it
 * counts with this call's flags, the host counted with its own: a number the host left standing must stand here too) */
static void field_wrap_wd(uint8_t *b, char ploughing, char sowing, char growing, char harvesting)
{
    fent *e = NULL;
    __try { e = field_event(b); }
    __except (EXCEPTION_EXECUTE_HANDLER) { fld_fault(GetExceptionCode()); e = NULL; }
    ((fcache_fn)(void *)FL.tramp)(b, ploughing, sowing, growing, harvesting);
    if (e) {
        __try { fld_cache_put(e); }
        __except (EXCEPTION_EXECUTE_HANDLER) { fld_fault(GetExceptionCode()); }
    }
}
static void field_wrap(uint8_t *b, char ploughing, char sowing, char growing, char harvesting)   /* lane 51: the watchdog's marks around it */
{
    wd_in(WD_FIELD); field_wrap_wd(b, ploughing, sowing, growing, harvesting); wd_out(WD_FIELD);
}

/* stub (at the page start): mov rax,<field_wrap>; jmp rax. Trampoline (+20h): the entry's first 8 bytes; jmp [rip+0]
 * -> entry + 8 */
static int fld_make_stub(void)
{
    uint8_t *p = alloc_near(g_base, g_imgsize), *resume;
    void *fn = (void *)&field_wrap;
    size_t n = 0;
    int32_t rel;
    DWORD old;
    if (!p) return 0;
    resume = FL.cache + FLD_HOOK_LEN;
    p[n++] = 0x48; p[n++] = 0xB8; memcpy(p + n, &fn, 8); n += 8; p[n++] = 0xFF; p[n++] = 0xE0;
    n = 0x20;
    memcpy(p + n, FLD_CACHE_ORIG, FLD_HOOK_LEN); n += FLD_HOOK_LEN;
    p[n++] = 0xFF; p[n++] = 0x25; p[n++] = 0; p[n++] = 0; p[n++] = 0; p[n++] = 0;
    memcpy(p + n, &resume, 8); n += 8;
    if (!VirtualProtect(p, 0x1000, PAGE_EXECUTE_READ, &old)) { VirtualFree(p, 0, MEM_RELEASE); return 0; }
    FlushInstructionCache(GetCurrentProcess(), p, 0x1000);
    rel = (int32_t)((intptr_t)p - (intptr_t)(FL.cache + 5));
    FL.jmp[0] = 0xE9; memcpy(FL.jmp + 1, &rel, 4); FL.jmp[5] = 0x90; FL.jmp[6] = 0x90; FL.jmp[7] = 0x90;
    FL.stub = p; FL.tramp = p + 0x20;
    log_line("FIELD: stub at %p (%Iu bytes)", (void *)p, n);
    return 1;
}

static void fld_unhook(void)
{
    char w[160];
    int r;
    InterlockedExchange(&FL.enabled, 0);
    if (!FL.avail || !FL.stub) return;
    if (memcmp(FL.cache, FL.jmp, FLD_HOOK_LEN) == 0) {
        r = write_bytes(FL.cache, FL.jmp, FLD_CACHE_ORIG, FLD_HOOK_LEN, w, sizeof(w));
        if (r != 1) { log_line("FIELD: FCACHE could not be restored: %s", w); if (r < 0) internal_failure("field restore failed"); }
        else log_line("FIELD hook out");
    }
    g_dirty = 1;
}

static void fld_drop_held(void)
{
    int i;
    for (i = FL.n - 1; i >= 0; i--) if (FL.e[i].mode == 1) fld_remove(&FL.e[i]);
}

/* ALLOFF and going off: the hook out, the held fields dropped (the host's watched fields stay: nothing of the game is
 * patched for them) */
static void field_off(void) { fld_unhook(); fld_drop_held(); }

static void field_hook(int on)
{
    char w[160];
    int r;
    g_dirty = 1;
    if (!on) { fld_unhook(); fld_drop_held(); return; }
    if (!FL.avail) { log_line("FIELD HOOK ON refused: unavailable (%s)", FL.why); FL.refused++; return; }
    if (!FL.stub && !fld_make_stub()) { FL.avail = 0; _snprintf(FL.why, sizeof(FL.why), "no free memory near the game module for the stub"); log_line("FIELD HOOK ON refused: %s", FL.why); return; }
    FL.thread = GetCurrentThreadId();
    InterlockedExchange(&FL.want_off, 0);
    if (fld_bytes_on()) { InterlockedExchange(&FL.enabled, 1); log_line("FIELD already hooked"); return; }
    if (!fld_bytes_off()) { FL.avail = 0; _snprintf(FL.why, sizeof(FL.why), "FCACHE holds neither its own bytes nor this DLL's jump"); log_line("FIELD HOOK ON refused: %s", FL.why); return; }
    InterlockedExchange(&FL.enabled, 1);
    r = write_bytes(FL.cache, FLD_CACHE_ORIG, FL.jmp, FLD_HOOK_LEN, w, sizeof(w));
    if (r != 1) {
        InterlockedExchange(&FL.enabled, 0);
        FL.avail = 0; _snprintf(FL.why, sizeof(FL.why), "%s", w);
        log_line("FIELD HOOK ON FAILED: %s; item marked unavailable", w);
        if (r < 0) internal_failure("field hook write failed");
        return;
    }
    log_line("FIELD hooked: FCACHE %p", (void *)FL.cache);
}

/* ---------------------------------------------------------------- commands */
static int fld_building(const char *s, uint8_t **b, const char *what)
{
    unsigned long long a = 0;
    char why[200];
    if (g_stamp != KNOWN_TIMESTAMP || g_imgsize != KNOWN_IMAGESIZE) { log_line("%s refused: not the known game build", what); FL.refused++; return 0; }
    if (!parse_u64(s, &a)) { log_line("%s refused: '%s' is not an address", what, s); FL.refused++; return 0; }
    if (!comp_sane(a, FLD_CHECK, why, sizeof(why))) { log_line("%s refused: %s", what, why); FL.refused++; return 0; }
    *b = (uint8_t *)(uintptr_t)a;
    if (!fld_arr_sane(fld_plants(*b), FLD_PLANT_SIZE)) { log_line("%s refused: %llX has no sane plant list", what, a); FL.refused++; return 0; }
    return 1;
}
/* the field named in a command, held or watched in this mode, still the same object */
static fent *fld_entry(const char *s, int mode, const char *what)
{
    unsigned long long a = 0;
    fent *e;
    if (!parse_u64(s, &a)) { log_line("%s refused: '%s' is not an address", what, s); FL.refused++; return NULL; }
    e = fld_find((uint8_t *)(uintptr_t)a);
    if (!e || e->mode != mode) { log_line("%s refused: %llX is not %s", what, a, mode == 1 ? "held" : "watched"); FL.refused++; return NULL; }
    if (!fld_alive(e)) { log_line("%s refused: %llX is no longer the same object", what, a); FL.gone++; fld_remove(e); FL.refused++; return NULL; }
    if (!fld_arr_sane(fld_plants(e->b), FLD_PLANT_SIZE)) { log_line("%s refused: %llX has no sane plant list", what, a); FL.refused++; return NULL; }
    return e;
}

static void field_add(const char *s, int mode)
{
    uint8_t *b;
    fent *e;
    const char *what = mode == 1 ? "FIELD HOLD" : "FIELD WATCH";
    if (!fld_building(s, &b, what)) return;
    if (mode == 1 && GetCurrentThreadId() != FL.thread && FL.thread) { log_line("%s refused: another thread", what); FL.refused++; return; }
    e = fld_find(b);
    if (e) { if (e->mode == mode && fld_alive(e)) return; fld_remove(e); }
    if (FL.n >= FLD_MAX) { log_line("%s refused: %d fields already", what, FLD_MAX); FL.refused++; return; }
    e = &FL.e[FL.n++];
    memset(e, 0, sizeof(*e));
    e->b = b; e->idx = *(uint32_t *)(b + OBJ_INDEX_OFF); e->name = *(uint64_t *)(b + OBJ_NAME_OFF);
    e->mode = mode; e->n = -1; e->full = 1; e->redraw = -1;
    log_line("%s %p (%d plants)", what, (void *)b, fld_plants(b)->num);
}

static int fld_ranges(const char *s, int *lo, int *hi, int max, const char **end)
{
    /* one range "a" or "a-b" at s; returns 1 and moves *end past it (and a following ',') */
    char *e1;
    long a = strtol(s, &e1, 10), b2 = a;
    if (e1 == s || a < 0) return 0;
    if (*e1 == '-') { const char *s2 = e1 + 1; b2 = strtol(s2, &e1, 10); if (e1 == s2 || b2 < a) return 0; }
    if (b2 >= max) return 0;
    *lo = (int)a; *hi = (int)b2;
    if (*e1 == ',') e1++;
    *end = e1;
    return 1;
}

static int fld_parse_rec(const char *s, frec *r)
{
    unsigned crop, tb, c1, plb, grb;
    int yl;
    if (sscanf(s, "%u.%8X.%8X.%d.%u.%u", &crop, &plb, &grb, &yl, &tb, &c1) != 6 || crop > 255 || tb > 255 || c1 > 255) return 0;
    r->crop = (uint8_t)crop; r->tb = (uint8_t)tb; r->c1 = (uint8_t)c1; r->yl = yl;
    memcpy(&r->pl, &plb, 4); memcpy(&r->gr, &grb, 4); r->known = 1;
    return 1;
}

/* FIELD SET <b> <n> <ops>: into the shadow, then into the plants (put back, drawn, painted), then the game's own count */
static void field_set(int argc, char **argv)
{
    fent *e;
    int n, before;
    char *op, *next;
    if (argc != 5 || !parse_i32(argv[3], &n) || n < 0 || n > FLD_MAX_PLANTS) { log_line("FIELD SET refused: needs <b> <n> <ops>"); FL.refused++; return; }
    if (!(e = fld_entry(argv[2], 1, "FIELD SET"))) return;
    if (!fld_live(e)) { FL.notlive++; FL.refused++; log_line("FIELD SET refused: %p has left the game", (void *)e->b); return; }
    if (!fld_grow(e, n)) { log_line("FIELD SET refused: no memory"); FL.refused++; return; }
    e->n = n;
    for (op = argv[4]; op && *op; op = next) {
        const char *p;
        int lo, hi, i;
        next = strchr(op, ';');
        if (next) *next++ = 0;
        if (op[0] == 'c' || op[0] == 'C') {          /* the counted numbers */
            int32_t v[FLD_CACHE_N]; int j, okc = (int)strlen(op + 1) == 8 * FLD_CACHE_N;
            for (j = 0; okc && j < FLD_CACHE_N; j++) { unsigned u; char h[9]; memcpy(h, op + 1 + 8 * j, 8); h[8] = 0; okc = sscanf(h, "%8X", &u) == 1; v[j] = (int32_t)u; }
            if (!okc) { FL.refused++; continue; }
            memcpy(e->fc, v, sizeof(v)); e->fc_known = 1;
            continue;
        }
        if (op[0] == 'd' || op[0] == 'D') {          /* the drawn size: d<ranges>=<x>.<y>.<z> (the doubles' bits) */
            char *eq = strchr(op, '=');
            unsigned long long xb[3];
            if (!eq || sscanf(eq + 1, "%16llX.%16llX.%16llX", &xb[0], &xb[1], &xb[2]) != 3) { FL.refused++; continue; }
            *eq = 0;
            for (p = op + 1; *p && fld_ranges(p, &lo, &hi, n, &p); )
                for (i = lo; i <= hi; i++) { memcpy(e->r[i].ds, xb, 24); e->r[i].dsk = 1; FL.sizes++; }
            continue;
        }
        if (op[0] == 'g' || op[0] == 'G') {
            unsigned bits; float step;
            char *colon = strchr(op, ':');
            if (!colon || sscanf(op + 1, "%8X", &bits) != 1) { FL.refused++; continue; }
            memcpy(&step, &bits, 4);
            for (p = colon + 1; *p && fld_ranges(p, &lo, &hi, n, &p); )
                for (i = lo; i <= hi; i++) {
                    if (!e->r[i].known) { FL.unknown++; continue; }
                    { float g = e->r[i].gr + step; e->r[i].gr = g < 1.0f ? g : 1.0f; }
                    FL.grows++;
                }
        } else {
            char *eq = strchr(op, '=');
            frec r;
            if (!eq || !fld_parse_rec(eq + 1, &r)) { FL.refused++; continue; }
            *eq = 0;
            for (p = op; *p && fld_ranges(p, &lo, &hi, n, &p); )
                for (i = lo; i <= hi; i++) { double d0[3]; uint8_t k0 = e->r[i].dsk; memcpy(d0, e->r[i].ds, 24); e->r[i] = r; memcpy(e->r[i].ds, d0, 24); e->r[i].dsk = k0; FL.setpts++; }
        }
    }
    FL.sets++;
    { LARGE_INTEGER t0; QueryPerformanceCounter(&t0); FL.qset -= t0.QuadPart; }
    if (fld_plants(e->b)->num < n) FL.beyond += (unsigned long long)(n - fld_plants(e->b)->num);
    before = (int)FL.restored;
    __try {
        int k = fld_restore(e, 1);
        FL.restored += (unsigned long long)k;
        FL.own++;
        ((fcache_fn)(void *)FL.cache)(e->b, 1, 1, 1, 1);     /* through the hook (the plants put back, the numbers after) */
        FL.own--;
        fld_cache_put(e);                                      /* also without the hook */
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        FL.own = 0; FL.faults++;
        log_line("FIELD SET on %p raised exception %08lX", (void *)e->b, GetExceptionCode());
    }
    (void)before;
    { LARGE_INTEGER t1; QueryPerformanceCounter(&t1); FL.qset += t1.QuadPart; }
}

static void field_check(int argc, char **argv)
{
    fent *e;
    int n, i;
    unsigned long long want = 0;
    uint32_t h = 2166136261u;
    const fld_arr *p;
    if (argc != 5 || !parse_i32(argv[3], &n) || !parse_u64(argv[4], &want)) { FL.refused++; return; }
    if (!(e = fld_entry(argv[2], 1, "FIELD CHECK"))) return;
    p = fld_plants(e->b);
    for (i = 0; i < p->num; i++) { frec r; fld_read(p->data + (size_t)i * FLD_PLANT_SIZE, &r); h = fld_crc_rec(h, &r); }
    if (p->num == n && h == (uint32_t)want) FL.checkok++;
    else {
        wchar_t path[MAX_PATH];
        HANDLE fh;
        char line[40];
        DWORD wr;
        int len;
        FL.checkbad++;
        log_line("FIELD CHECK %p: here %d plants crc %08X, host %d crc %08X (asked whole)", (void *)e->b, p->num, h, n, (uint32_t)want);
        join_path(path, g_dir, L"field_ask.txt");
        len = _snprintf(line, sizeof(line), "%IX\r\n", (uintptr_t)e->b);
        fh = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (fh != INVALID_HANDLE_VALUE) { if (len > 0) WriteFile(fh, line, (DWORD)len, &wr, NULL); CloseHandle(fh); }
    }
}

/* ---------------------------------------------------------------- host: the changes since the last poll */
typedef struct { char *buf; size_t len, cap; } fsb;
static void fsb_add(fsb *s, const char *fmt, ...)
{
    va_list ap; int k;
    if (s->cap - s->len < 128) {
        size_t nc = s->cap ? s->cap * 2 : 65536;
        char *nb = (char *)realloc(s->buf, nc);
        if (!nb) return;
        s->buf = nb; s->cap = nc;
    }
    va_start(ap, fmt);
    k = _vsnprintf(s->buf + s->len, s->cap - s->len - 1, fmt, ap);
    va_end(ap);
    if (k > 0) s->len += (size_t)k;
}

/* ranges of the plants in idx[0..n) (ascending) */
static void fld_emit_ranges(fsb *o, const int *idx, int n)
{
    int i = 0, first = 1;
    while (i < n) {
        int j = i;
        while (j + 1 < n && idx[j + 1] == idx[j] + 1) j++;
        if (j > i) fsb_add(o, "%s%d-%d", first ? "" : ",", idx[i], idx[j]); else fsb_add(o, "%s%d", first ? "" : ",", idx[i]);
        first = 0; i = j + 1;
    }
}

static void fld_poll_one(fent *e, fsb *out)
{
    const fld_arr *p = fld_plants(e->b);
    int n = p->num, i, ng = 0, havestep = 0, ops = 0;
    float step = 0.0f;
    int *gidx;
    uint32_t h = 2166136261u;
    size_t line0 = out->len, opsstart;
    char head[64];
    if (!fld_grow(e, n > 0 ? n : 1)) return;
    if (n != e->n) e->full = 1;
    gidx = (int *)malloc((size_t)(n > 0 ? n : 1) * sizeof(int));
    if (!gidx) return;
    for (i = 0; i < n; i++) { frec r; fld_read(p->data + (size_t)i * FLD_PLANT_SIZE, &r); h = fld_crc_rec(h, &r); }
    _snprintf(head, sizeof(head), "%IX %d %08X ", (uintptr_t)e->b, n, h);
    fsb_add(out, "%s", head);
    opsstart = out->len;
    /* the day's growth first: every plant whose only change is growth = min(old + step, 1) with one common step */
    if (!e->full) {
        for (i = 0; i < n; i++) {
            frec cur, *old = &e->r[i];
            fld_read(p->data + (size_t)i * FLD_PLANT_SIZE, &cur);
            if (!old->known || cur.crop != old->crop || cur.tb != old->tb || cur.c1 != old->c1 || cur.yl != old->yl || memcmp(&cur.pl, &old->pl, 4) != 0) continue;
            if (memcmp(&cur.gr, &old->gr, 4) == 0) continue;
            if (!havestep && cur.gr < 1.0f) { step = cur.gr - old->gr; havestep = 1; }
            if (havestep) {
                float g = old->gr + step; g = g < 1.0f ? g : 1.0f;
                if (memcmp(&g, &cur.gr, 4) == 0) { gidx[ng++] = i; old->gr = cur.gr; }
            }
        }
        if (ng) { uint32_t sb; memcpy(&sb, &step, 4); fsb_add(out, "g%08X:", sb); fld_emit_ranges(out, gidx, ng); ops++; }
    }
    /* the field's counted numbers, when they changed */
    {
        int32_t v[FLD_CACHE_N]; int j;
        fld_cache_read(e->b, v);
        if (e->full || !e->fc_known || memcmp(v, e->fc, sizeof(v)) != 0) {
            fsb_add(out, "%sc", ops ? ";" : "");
            for (j = 0; j < FLD_CACHE_N; j++) fsb_add(out, "%08X", (uint32_t)v[j]);
            memcpy(e->fc, v, sizeof(v)); e->fc_known = 1; ops++;
        }
    }
    /* the drawn sizes that changed, runs of equal sizes */
    i = 0;
    while (i < n) {
        frec cur;
        int j;
        fld_read(p->data + (size_t)i * FLD_PLANT_SIZE, &cur);
        if (!e->full && e->r[i].dsk && !fld_ds_differ(&cur, &e->r[i])) { i++; continue; }
        j = i;
        while (j + 1 < n) {
            frec nx;
            fld_read(p->data + (size_t)(j + 1) * FLD_PLANT_SIZE, &nx);
            if (memcmp(nx.ds, cur.ds, 24) != 0 || (!e->full && e->r[j + 1].dsk && memcmp(nx.ds, e->r[j + 1].ds, 24) == 0)) break;
            j++;
        }
        if (out->len - opsstart > FLD_OPS_MAX) { fsb_add(out, "\r\n%s", head); opsstart = out->len; ops = 0; }
        {
            unsigned long long xb[3]; memcpy(xb, cur.ds, 24);
            if (j > i) fsb_add(out, "%sd%d-%d=%016llX.%016llX.%016llX", ops ? ";" : "", i, j, xb[0], xb[1], xb[2]);
            else fsb_add(out, "%sd%d=%016llX.%016llX.%016llX", ops ? ";" : "", i, xb[0], xb[1], xb[2]);
        }
        ops++;
        for (; i <= j; i++) { memcpy(e->r[i].ds, cur.ds, 24); e->r[i].dsk = 1; }
    }
    /* then every other change, runs of equal records */
    i = 0;
    while (i < n) {
        frec cur;
        int j;
        fld_read(p->data + (size_t)i * FLD_PLANT_SIZE, &cur);
        if (!e->full && e->r[i].known && fld_same(&cur, &e->r[i])) { i++; continue; }
        j = i;
        while (j + 1 < n) {
            frec nx;
            fld_read(p->data + (size_t)(j + 1) * FLD_PLANT_SIZE, &nx);
            if (!fld_same(&nx, &cur) || (!e->full && e->r[j + 1].known && fld_same(&nx, &e->r[j + 1]))) break;
            j++;
        }
        if (out->len - opsstart > FLD_OPS_MAX) {          /* a new line with the same head */
            fsb_add(out, "\r\n%s", head); opsstart = out->len; ops = 0;
        }
        {
            uint32_t pb, gb; memcpy(&pb, &cur.pl, 4); memcpy(&gb, &cur.gr, 4);
            if (j > i) fsb_add(out, "%s%d-%d=%u.%08X.%08X.%d.%u.%u", ops ? ";" : "", i, j, cur.crop, pb, gb, cur.yl, cur.tb, cur.c1);
            else fsb_add(out, "%s%d=%u.%08X.%08X.%d.%u.%u", ops ? ";" : "", i, cur.crop, pb, gb, cur.yl, cur.tb, cur.c1);
        }
        ops++;
        for (; i <= j; i++) e->r[i] = cur;
    }
    free(gidx);
    if (ops == 0 && n == e->n && !e->full) { out->len = line0; return; }       /* nothing changed */
    if (ops == 0) fsb_add(out, "-");
    fsb_add(out, "\r\n");
    e->n = n; e->full = 0;
    FL.lines++;
}

static void field_poll(void)
{
    fsb out = { 0 };
    wchar_t path[MAX_PATH], tmp[MAX_PATH];
    HANDLE h;
    DWORD wr;
    int i;
    LARGE_INTEGER q0, q1;
    QueryPerformanceCounter(&q0);
    FL.polls++;
    for (i = FL.n - 1; i >= 0; i--) {
        fent *e = &FL.e[i];
        if (e->mode != 2) continue;
        if (!fld_alive(e) || !fld_arr_sane(fld_plants(e->b), FLD_PLANT_SIZE)) { log_line("FIELD: watched %p is gone", (void *)e->b); FL.gone++; fld_remove(e); continue; }
        __try { fld_poll_one(e, &out); }
        __except (EXCEPTION_EXECUTE_HANDLER) { FL.faults++; log_line("FIELD POLL of %p raised exception %08lX", (void *)e->b, GetExceptionCode()); }
    }
    /* the file is written only when something changed, and appended to: the mod reads it right after this tick (same
     * thread) and deletes it; a poll with no change costs no file call */
    join_path(path, g_dir, L"field_out.txt"); (void)tmp;
    if (out.len) {
        h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE) { WriteFile(h, out.buf, (DWORD)out.len, &wr, NULL); CloseHandle(h); }
    }
    FL.outbytes += out.len;
    free(out.buf);
    QueryPerformanceCounter(&q1); FL.qpoll += q1.QuadPart - q0.QuadPart;
}

static void field_cut(int argc, char **argv)
{
    uint8_t *b;
    unsigned long long off = 0;
    int n;
    fld_arr *a;
    if (argc != 5 || !parse_u64(argv[3], &off) || !parse_i32(argv[4], &n)) { FL.refused++; return; }
    if (off != 0x660 && off != 0x6A8 && off != 0x6B8) { log_line("FIELD CUT refused: list %llX is not a point list", off); FL.refused++; return; }
    if (!fld_building(argv[2], &b, "FIELD CUT")) return;
    a = (fld_arr *)(b + off);
    if (!fld_arr_sane(a, 24) || n <= 0 || n >= a->num) { log_line("FIELD CUT refused: %d of %d points", n, a->num); FL.refused++; return; }
    log_line("FIELD CUT %p +%llX: %d -> %d points", (void *)b, off, a->num, n);
    a->num = n;
    FL.cuts++;
}

static void field_dump(int argc, char **argv)
{
    uint8_t *b;
    wchar_t path[MAX_PATH], name[80];
    FILE *f;
    const fld_arr *p, *fp, *tri, *bp, *fb, *comp, *res;
    int i, j;
    if (argc != 4) { log_line("FIELD DUMP refused: needs <building> <tag>"); FL.refused++; return; }
    if (!fld_building(argv[2], &b, "FIELD DUMP")) return;
    for (i = 0; argv[3][i] && i < 40; i++) { char c = argv[3][i]; name[i] = (wchar_t)(((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) ? c : '_'); }
    name[i] = 0;
    _snwprintf(path, MAX_PATH - 1, L"%sfield_dump_%s.txt", g_dir, name); path[MAX_PATH - 1] = 0;
    f = _wfopen(path, L"wb");
    if (!f) { log_line("FIELD DUMP: cannot write the file"); return; }
    __try {
        p = fld_plants(b);
        fp = (const fld_arr *)(b + 0x660); tri = (const fld_arr *)(b + 0x678); bp = (const fld_arr *)(b + 0x6A8); fb = (const fld_arr *)(b + 0x6B8);
        comp = (const fld_arr *)(b + 0x550); res = (const fld_arr *)(b + 0x1018);
        fprintf(f, "building %p plants %d/%d pending %d cursor %d comps %d reserved %d FieldPoints %d tri %d border %d final %d cache sown %d unplowed %d ready %d yield %d mode %d\r\n",
                (void *)b, p->num, p->max, *(int32_t *)(b + 0x570), *(int32_t *)(b + 0x574), comp->num, res->num, fp->num, tri->num, bp->num, fb->num,
                *(int32_t *)(b + 0xBFC), *(int32_t *)(b + 0xBF8), *(int32_t *)(b + 0xBF4), *(int32_t *)(b + 0x584), *(int32_t *)(b + 0x4DC));
        for (i = 0; i < p->num; i++) {
            const uint8_t *q = p->data + (size_t)i * FLD_PLANT_SIZE;
            const double *pos = (const double *)(q + 8);
            fprintf(f, "%d c%u x%.1f y%.1f z%.1f pl%.4f g%.4f in%d r%.3f y%d b%d c1%u w%.1f,%.1f m%p sc%.3f,%.3f,%.3f\r\n", i, q[0], pos[0], pos[1], pos[2],
                    *(const float *)(q + 0x20), *(const float *)(q + 0x24), *(const int32_t *)(q + 0x28), *(const float *)(q + 0x2C), *(const int32_t *)(q + 0x4C),
                    *(const int32_t *)(q + 0xBC), q[0xC1], *(const double *)(q + 0x30), *(const double *)(q + 0x38), *(void *const *)(q + 0xB0),
                    *(const double *)(q + 0x90), *(const double *)(q + 0x98), *(const double *)(q + 0xA0));
            if (i < 3) {
                fprintf(f, "  hex");
                for (j = 0; j < FLD_PLANT_SIZE; j++) fprintf(f, "%s%02X", (j % 16) ? "" : " ", q[j]);
                fprintf(f, "\r\n");
            }
        }
        if (fld_arr_sane(fp, 24) && fp->num) {
            fprintf(f, "FieldPoints");
            for (i = 0; i < fp->num; i++) fprintf(f, " %.1f,%.1f", ((const double *)fp->data)[i * 3], ((const double *)fp->data)[i * 3 + 1]);
            fprintf(f, "\r\n");
        }
        if (fld_arr_sane(bp, 24) && bp->num) {
            fprintf(f, "border");
            for (i = 0; i < bp->num; i++) fprintf(f, " %.1f,%.1f", ((const double *)bp->data)[i * 3], ((const double *)bp->data)[i * 3 + 1]);
            fprintf(f, "\r\n");
        }
        FL.dumps++;
    } __except (EXCEPTION_EXECUTE_HANDLER) { fprintf(f, "exception %08lX while reading\r\n", GetExceptionCode()); }
    fclose(f);
    log_line("FIELD DUMP %p written", (void *)b);
}

/* ---------------------------------------------------------------- tick: queued drawings, audits, a faulted hook */
static void field_tick(void)
{
    int i, budget = FLD_DRAW_TICK;
    if (!FL.avail) return;
    if (FL.want_off) {
        InterlockedExchange(&FL.want_off, 0);
        log_line("FIELD: exception %08lX in the hook: hook taken out, fields dropped", FL.fault_code);
        fld_unhook(); fld_drop_held();
        FL.avail = 0; _snprintf(FL.why, sizeof(FL.why), "exception %08lX in the hook", FL.fault_code);
        return;
    }
    if (!FL.n) return;
    __try {
        for (i = 0; i < FL.n && budget > 0; i++) {
            fent *e = &FL.e[i];
            const fld_arr *p;
            if (e->mode != 1 || e->redraw < 0) continue;
            if (!fld_alive(e) || !fld_live(e)) { e->redraw = -1; continue; }
            p = fld_plants(e->b);
            while (e->redraw >= 0 && budget > 0) {
                if (e->redraw >= p->num) { e->redraw = -1; break; }
                fld_draw(e->b, e->redraw); budget--;
                if (e->redraw < e->cap && e->r[e->redraw].dsk) {
                    frec cur; fld_read(p->data + (size_t)e->redraw * FLD_PLANT_SIZE, &cur);
                    if (fld_ds_differ(&cur, &e->r[e->redraw])) fld_setscale(e->b, e->redraw, e->r[e->redraw].ds);
                }
                e->redraw++;
            }
        }
        /* the engine draws a marked field 50 plants a tick (+570h = plants still to draw), from this copy's plants (the
         * host's) but with its own 5 % rule: while a held field is being drawn, and in the tick after, every drawn size
         * is set to the host's at once (the 0.5 s audit below would find it later) */
        for (i = 0; i < FL.n; i++) {
            fent *e = &FL.e[i];
            int32_t pend;
            if (e->mode != 1 || !FL.enabled) continue;
            if (!fld_alive(e) || !fld_live(e)) continue;
            pend = *(const int32_t *)(e->b + 0x570);
            if (pend > 0 || e->drawing) {
                int k = fld_restore(e, 1);
                if (k) { FL.followed += (unsigned long long)k; }
            }
            e->drawing = pend > 0;
        }
        if (FL.enabled && GetTickCount64() - FL.last_audit >= 500) {
            FL.last_audit = GetTickCount64();
            for (i = FL.n - 1; i >= 0; i--) {
                fent *e = &FL.e[i];
                int k;
                if (e->mode != 1) continue;
                if (!fld_alive(e) || !fld_live(e) || !fld_arr_sane(fld_plants(e->b), FLD_PLANT_SIZE)) { FL.gone++; fld_remove(e); continue; }
                g_fld_sizefix = 0;
                k = fld_restore(e, 0);
                FL.audits++;
                FL.sizeleaks += g_fld_sizefix; k -= (int)g_fld_sizefix;
                if (k) { FL.leaks += (unsigned long long)k; log_line("FIELD AUDIT %p: %d plants differed from the host's without a count (put back)", (void *)e->b, k); }
                /* lane 71: the counted numbers (operation mode, planned harvest, yield ...) as the host's too: this copy's own field
                 * routine may write one of them outside UpdateFieldCache, where the hook does not see it */
                if (e->fc_known) {
                    int32_t v[FLD_CACHE_N];
                    fld_cache_read(e->b, v);
                    if (memcmp(v, e->fc, sizeof(v)) != 0) { fld_cache_put(e); FL.cachefix++; }
                }
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { FL.faults++; log_line("FIELD tick raised exception %08lX", GetExceptionCode()); }
}

static void field_cmd(int argc, char **argv)
{
    int v;
    if (argc >= 2 && (_stricmp(argv[1], "POLL") == 0 || _stricmp(argv[1], "SET") == 0 || _stricmp(argv[1], "CHECK") == 0)) {
        /* the frequent ones: no status file for them (the counters reach it with the next other change or STATUS) */
        if (!FL.avail) { FL.refused++; return; }
        if (argc == 2 && _stricmp(argv[1], "POLL") == 0) field_poll();
        else if (_stricmp(argv[1], "SET") == 0) field_set(argc, argv);
        else field_check(argc, argv);
        return;
    }
    g_dirty = 1;
    if (argc >= 2 && _stricmp(argv[1], "DUMP") == 0) { field_dump(argc, argv); return; }
    if (!FL.avail) { log_line("FIELD %s refused: unavailable (%s)", argc >= 2 ? argv[1] : "", FL.why); FL.refused++; return; }
    if (argc == 3 && _stricmp(argv[1], "HOOK") == 0 && on_off(argv[2], &v)) { field_hook(v); return; }
    if (argc == 3 && _stricmp(argv[1], "HOLD") == 0) { field_add(argv[2], 1); return; }
    if (argc == 3 && _stricmp(argv[1], "WATCH") == 0) { field_add(argv[2], 2); return; }
    if (argc == 3 && _stricmp(argv[1], "DROP") == 0) {
        unsigned long long a = 0; fent *e;
        if (parse_u64(argv[2], &a) && (e = fld_find((uint8_t *)(uintptr_t)a)) != NULL) { log_line("FIELD DROP %llX", a); fld_remove(e); }
        return;
    }
    if (argc == 2 && _stricmp(argv[1], "FORGET") == 0) { while (FL.n) fld_remove(&FL.e[FL.n - 1]); log_line("FIELD FORGET"); return; }
    if (argc == 3 && _stricmp(argv[1], "FULL") == 0) {
        int i; unsigned long long a = 0;
        if (_stricmp(argv[2], "ALL") == 0) { for (i = 0; i < FL.n; i++) FL.e[i].full = 1; return; }
        if (parse_u64(argv[2], &a)) { fent *e = fld_find((uint8_t *)(uintptr_t)a); if (e) e->full = 1; }
        return;
    }
    if (_stricmp(argv[1], "CUT") == 0) { field_cut(argc, argv); return; }
    log_line("FIELD: unknown form"); FL.refused++;
}
