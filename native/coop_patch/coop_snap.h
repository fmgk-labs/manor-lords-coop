/* coop_snap.h - lane 47 (SNAP): the game's values read in native code instead of through the mod loader.
 * Included once by coop_patch.c, right before its command section; everything here is this lane's own block.
 * Evidence: research\2026-11-10-game-probe\lanes\lane_s21_47\report.txt.
 *
 * Why: every value the mod's Lua reads through the mod loader costs 0.5 to 16 us (lane 47, sitting b1: an object
 * 1.5 us, an enum 14.5 us, a game function 10 to 13 us); the same value read here costs a few nanoseconds.
 *
 * THE RULE THAT KEEPS A FREED OBJECT FROM BEING READ. Nothing is read through an address before the engine's own object
 * list proves the object alive in this tick:
 *   - the engine's object array (GUObjectArray, this build's place, checked once against objects the Lua proved valid
 *     in the same frame: SNAP UOA) has at the object's number (UObject+0Ch) an entry that holds this very address,
 *     and that entry's flags say neither Garbage (1<<21) nor Unreachable (1<<28);
 *   - the object's class (UObject+10h) is the one first seen at that address (another object at a reused address is
 *     a new entry);
 *   - a list (TArray: data, count, room) is read count first; a count below 0, above its room or above the table's
 *     limit drops the whole list for this tick; nothing past the count is read;
 *   - every read runs under SEH; a fault drops the entry (and counts it); nothing is ever written through a value
 *     read here, except the crash guard's two lists (below), each of them owned by an object proved alive just before.
 * The object number at +0Ch of an address not yet proved is read under SEH and used ONLY as an index into the object
 * array (bounded by its count); the entry found there decides. The roots (the engine, the player's lord) are proved
 * the same way at every tick, with the object number and class taken when the Lua registered them.
 * A building taken out of the game (demolished) leaves the engine's list at once while it stays a valid object (lane 0,
 * crash_demolish_site): it leaves the table too, at the next tick ("gone").
 *
 *   SNAP UOA <hex>,...            the object array checked against these objects (valid in the Lua this frame): every
 *                                 one must be found there alive; else SNAP stays unavailable (reflected reads stay)
 *   SNAP TABLE <id> <root hex> <list off hex> <fields>      table id (0..3): the objects of the list at root+off, with
 *                                 these plain fields (comma list, all offsets hex, from the reflected properties):
 *                                   i<off> int32  u<off> uint8  b<off>:<mask> bool  p<off> pointer  n<off> a list's count
 *                                   f<off> float  a<off>:<max> a list of uint8 (at most max)
 *                                   g<off>:<stride> a list of goods records (type int32 +0, amount int32 +4; at most 160;
 *                                   two such fields at most)
 *                                   d<off>:<off2> a double of the object the pointer at off names (proved alive first)
 *                                   q<off>:<off2> a pointer of the object the pointer at off names (proved alive first)
 *                                   e / h / x / r <off>:<off2> an int32 / uint8 / double / pointer at +off2 of the first
 *                                   record of the struct list at off (INT64_MIN when the list is empty)
 *   SNAP TABLE <id> OFF            the table emptied and stopped
 *   SNAP FULL                      the next answer holds every entry of every table
 *   SNAP GUARD <lord hex> <helper hex|0> <list off hex> | SNAP GUARD OFF     the crash guard (below)
 *   SNAP OFF                       everything stopped (tables, guard)
 * The answer: snap_out.bin, written in place through a handle kept open (the Lua reads it right after this tick, on
 * the same thread, through a handle it keeps open: 4 us; sitting b1), only when something changed:
 *   "SNP1" u32 seq, u32 prev seq, u32 bytes, u32 tables, then per table: u8 id, u8 full, u16 fields, u32 count,
 *   u32 changed, u32 gone; per changed entry u64 address, u32 object number, u32 list place, u32 version, then per
 *   field an i64 (a float or double as its 8 bytes of a double), then per list field a u16 count and its values
 *   (uint8 lists: bytes; goods: int32 type, int32 amount); then the gone addresses (u64).
 * CRASH GUARD (the core's C.scrubClose, coop.lua; 0.1 to 0.9 ms a frame in Lua): every tick the helper lord's
 * nearby-buildings list is emptied (count 0) and every entry of the player's list that is no object alive is replaced
 * by an entry of the same list that is (count 0 when none is), as the Lua did with IsValid / IsActorBeingDestroyed.
 * Status: "SNAP on|off|unavailable ..." and "GUARD on|off fixed=<n> emptied=<n> ...".
 * Refused on another game build (the object array's place is this build's). */
#define UOA_RVA        0x92B8120u   /* GUObjectArray (UE4SS's log: absolute 0x7ff6f2698120 and 0x7ff6695b8120 in two runs; 1150 rip-relative
                                       references to its +10h in .text: lane_s21_47/tools/find_uoa.py) */
#define UOA_CHUNK      65536
#define UOI_SIZE       24           /* FUObjectItem: Object, flags (two int32 words), cluster root, serial number */
#define UOI_BAD        ((1u << 21) | (1u << 28))    /* Garbage, Unreachable (both words are looked at: the layout of 5.5's flags and ref count) */
#define SNAP_TABLES    4
#define SNAP_FMAX      24
#define SNAP_EMAX      4096
#define SNAP_GMAX      160          /* goods records of one list (a region's totals hold about 90 kinds) */
#define SNAP_AMAX      16
#define SNAP_HASH      8192         /* a power of two, twice SNAP_EMAX */
#define SNAP_OUTCAP    (4u * 1024u * 1024u)

typedef struct { char kind; uint32_t off, arg, arg2; } snap_field;   /* arg2: the element size of an a-list (1 when not given) */
typedef struct {
    uintptr_t a; int32_t idx; uintptr_t cls;
    uint32_t pos, ver, seen;
    int64_t v[SNAP_FMAX];
    uint16_t na, ng[2]; uint8_t arr[SNAP_AMAX]; int32_t g[2][SNAP_GMAX * 2];
} snap_ent;
typedef struct {
    int on; uintptr_t root; int32_t ridx; uintptr_t rcls; uint32_t list_off;
    int nf; snap_field f[SNAP_FMAX]; int fa, fg[2];   /* the uint8 list field and the (at most two) goods fields (-1: none) */
    snap_ent *e; int ne, nfree, tomb;                  /* slots (0..ne), free slots below ne, removed marks in the hash */
    int32_t *hash;                                     /* address -> slot + 1 (0 empty, -1 removed) */
    uint32_t gen, count; int full;
    unsigned long long reads, changed, gone, faults, dropped, rootbad, us;
} snap_tab;

static struct {
    int avail; char why[160];
    uint8_t *uoa; int uoa_ok;
    snap_tab t[SNAP_TABLES];
    HANDLE out; uint8_t *buf; uint32_t seq, prev; int want_full;
    unsigned long long writes, bytes, ticks, us, maxus, refused, faults, tabus[SNAP_TABLES];
    /* crash guard */
    int g_on; uintptr_t g_p, g_h; int32_t g_pidx, g_hidx; uintptr_t g_pcls, g_hcls; uint32_t g_off;
    unsigned long long g_fixed, g_emptied, g_helper, g_ticks, g_faults, g_gone;
} SN;

#ifdef COOP_PATCH_TEST
static uint8_t *g_snap_test_uoa;     /* test build: SNAP TESTUOA <hex> puts a synthetic object array in place */
#endif

static int snap_build_ok(void)
{
#ifdef COOP_PATCH_TEST
    if (g_snap_test_uoa) return 1;
#endif
    return g_base && g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
}
static uint8_t *snap_uoa_addr(void)
{
#ifdef COOP_PATCH_TEST
    if (g_snap_test_uoa) return g_snap_test_uoa;
#endif
    return g_base + UOA_RVA;
}

/* the entry of object number idx, or NULL (caller is inside __try) */
static const uint8_t *uoa_item(int32_t idx)
{
    const uint8_t *u = SN.uoa;
    uint8_t **chunks; int32_t num, nch;
    if (!u || idx < 0) return NULL;
    chunks = *(uint8_t ***)(u + 0x10); num = *(const int32_t *)(u + 0x24); nch = *(const int32_t *)(u + 0x2C);
    if (!chunks || idx >= num || idx / UOA_CHUNK >= nch) return NULL;
    if (!chunks[idx / UOA_CHUNK]) return NULL;
    return chunks[idx / UOA_CHUNK] + (size_t)(idx % UOA_CHUNK) * UOI_SIZE;
}
/* 1 = the object array holds `a` at number idx and its flags are clean (caller is inside __try) */
static int uoa_holds(uintptr_t a, int32_t idx)
{
    const uint8_t *it = uoa_item(idx);
    if (!it || *(const uintptr_t *)it != a) return 0;
    return ((*(const uint32_t *)(it + 8) | *(const uint32_t *)(it + 12)) & UOI_BAD) == 0;
}
/* an address not yet proved: its object number read (the only read before the proof), then the entry decides; fills
 * idx and class. 0 = not an object alive. (caller is inside __try) */
static int uoa_prove(uintptr_t a, int32_t *idx, uintptr_t *cls)
{
    int32_t i;
    if (!a || (a & 7)) return 0;
    i = *(const int32_t *)(a + OBJ_INDEX_OFF);
    if (!uoa_holds(a, i)) return 0;
    *idx = i; *cls = *(const uintptr_t *)(a + 0x10);
    return 1;
}
/* an object proved before (number and class known): still the same and alive? (caller is inside __try) */
static int uoa_still(uintptr_t a, int32_t idx, uintptr_t cls)
{
    if (!uoa_holds(a, idx)) return 0;
    return *(const int32_t *)(a + OBJ_INDEX_OFF) == idx && *(const uintptr_t *)(a + 0x10) == cls;
}
/* a pointer read from a proved object, proved in turn (for d / q fields); 0 = null or not alive */
static int uoa_ptr_ok(uintptr_t p)
{
    int32_t i; uintptr_t c;
    return p && uoa_prove(p, &i, &c);
}
static int snap_tarr(uintptr_t at, uintptr_t *data, int32_t *num, int32_t cap)
{
    int32_t n = *(const int32_t *)(at + 8), mx = *(const int32_t *)(at + 12);
    uintptr_t d = *(const uintptr_t *)at;
    if (n < 0 || mx < n || n > cap || (n > 0 && !d)) return 0;
    *data = d; *num = n;
    return 1;
}

static int snap_status(char *buf, size_t len)
{
    int n = 0, k, ntab = 0; unsigned long long ent = 0, ch = 0, gone = 0, fl = 0;
    for (k = 0; k < SNAP_TABLES; k++) if (SN.t[k].on) { ntab++; ent += SN.t[k].count; ch += SN.t[k].changed; gone += SN.t[k].gone; fl += SN.t[k].faults + SN.t[k].dropped; }
    if (!SN.avail) n += _snprintf(buf, len, "SNAP unavailable %s\r\n", SN.why[0] ? SN.why : "-");
    else n += _snprintf(buf, len, "SNAP %s uoa=%s tables=%d entries=%llu changed=%llu gone=%llu writes=%llu faults=%llu refused=%llu ticks=%llu us=%llu maxus=%llu bytes=%llu us0=%llu us1=%llu us2=%llu\r\n",
                        SN.uoa_ok ? "on" : "off", SN.uoa_ok ? "ok" : "unchecked", ntab, ent, ch, gone, SN.writes, SN.faults + fl, SN.refused, SN.ticks, SN.us, SN.maxus, SN.bytes, SN.tabus[0], SN.tabus[1], SN.tabus[2]);
    if (n < 0 || (size_t)n >= len) return (int)strlen(buf);
    k = _snprintf(buf + n, len - (size_t)n, "GUARD %s fixed=%llu emptied=%llu helper=%llu gone=%llu faults=%llu\r\n",
                  SN.g_on ? "on" : "off", SN.g_fixed, SN.g_emptied, SN.g_helper, SN.g_gone, SN.g_faults);
    if (k > 0) n += k;
    return n;
}

static int snap_scan(void)
{
    memset(&SN, 0, sizeof(SN));
    if (!snap_build_ok()) { _snprintf(SN.why, sizeof(SN.why), "not the known game build (the object array's place is this build's)"); return 0; }
    SN.uoa = snap_uoa_addr();
    if (!range_readable(SN.uoa, 0x30)) { _snprintf(SN.why, sizeof(SN.why), "the object array is not readable"); SN.uoa = NULL; return 0; }
    SN.avail = 1;
    return 1;
}

static void snap_tab_free(snap_tab *t)
{
    if (t->e) VirtualFree(t->e, 0, MEM_RELEASE);
    if (t->hash) VirtualFree(t->hash, 0, MEM_RELEASE);
    memset(t, 0, sizeof(*t));
}
static void snap_all_off(const char *why)
{
    int k;
    for (k = 0; k < SNAP_TABLES; k++) snap_tab_free(&SN.t[k]);
    SN.g_on = 0;
    if (why) log_line("SNAP off: %s", why);
    g_dirty = 1;
}

static int snap_hex(const char *s, uintptr_t *v)
{
    unsigned long long x; char *end;
    if (!s || !*s) return 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    x = _strtoui64(s, &end, 16);
    if (*end) return 0;
    *v = (uintptr_t)x;
    return 1;
}

/* SNAP UOA <hex>,...: each object valid in the Lua this frame must be found alive in the object array */
static void snap_uoa_cmd(const char *list)
{
    char buf[MAX_LINE], *p, *next;
    int n = 0, bad = 0;
    if (!SN.avail) { SN.refused++; return; }
    if (strlen(list) >= sizeof(buf)) { SN.refused++; return; }
    strcpy(buf, list);
    __try {
        for (p = buf; p && *p; p = next) {
            uintptr_t a; int32_t i; uintptr_t c;
            next = strchr(p, ','); if (next) *next++ = 0;
            if (!snap_hex(p, &a)) { bad++; continue; }
            n++;
            if (!uoa_prove(a, &i, &c)) bad++;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { bad = n + 1; }
    if (n >= 2 && bad == 0) { SN.uoa_ok = 1; log_line("SNAP UOA: %d objects found alive in the object array: on", n); }
    else { SN.uoa_ok = 0; snap_all_off(NULL); log_line("SNAP UOA: %d of %d objects not found in the object array: SNAP stays off", bad, n); }
    g_dirty = 1;
}

static int snap_parse_fields(snap_tab *t, char *s)
{
    char *p, *next;
    t->nf = 0; t->fa = -1; t->fg[0] = -1; t->fg[1] = -1;
    for (p = s; p && *p; p = next) {
        snap_field f; char *colon, *end;
        next = strchr(p, ','); if (next) *next++ = 0;
        if (t->nf >= SNAP_FMAX) return 0;
        f.kind = p[0]; f.arg = 0; f.arg2 = 1;
        colon = strchr(p + 1, ':'); if (colon) *colon++ = 0;
        f.off = (uint32_t)strtoul(p + 1, &end, 16); if (*end || f.off > 0x100000) return 0;
        if (colon) { char *c2 = strchr(colon, ':'); if (c2) *c2++ = 0; f.arg = (uint32_t)strtoul(colon, &end, 16); if (*end) return 0; f.arg2 = 1; if (c2) { f.arg2 = (uint32_t)strtoul(c2, &end, 16); if (*end || !f.arg2 || f.arg2 > 8) return 0; } }
        switch (f.kind) {
        case 'i': case 'u': case 'p': case 'n': case 'f': break;
        case 'b': if (!f.arg || f.arg > 0xFF) return 0; break;
        case 'a': if (t->fa >= 0 || !f.arg || f.arg > SNAP_AMAX) return 0; t->fa = t->nf; break;
        case 'g': if (t->fg[1] >= 0 || f.arg < 8 || f.arg > 0x100) return 0; t->fg[t->fg[0] >= 0 ? 1 : 0] = t->nf; break;
        case 'd': case 'q': case 'e': case 'h': case 'x': case 'r': if (f.arg > 0x100000) return 0; break;
        default: return 0;
        }
        t->f[t->nf++] = f;
    }
    return t->nf > 0;
}

static void snap_table_cmd(int argc, char **argv)
{
    int id; uintptr_t root, off; snap_tab *t;
    char fields[MAX_LINE];
    if (argc < 4) { SN.refused++; return; }
    id = atoi(argv[2]);
    if (id < 0 || id >= SNAP_TABLES) { SN.refused++; return; }
    t = &SN.t[id];
    if (argc == 4 && _stricmp(argv[3], "OFF") == 0) { snap_tab_free(t); log_line("SNAP TABLE %d off", id); g_dirty = 1; return; }
    if (!SN.avail || !SN.uoa_ok) { SN.refused++; log_line("SNAP TABLE %d refused: %s", id, SN.avail ? "the object array was not checked (SNAP UOA)" : SN.why); g_dirty = 1; return; }
    if (argc != 6 || !snap_hex(argv[3], &root) || !snap_hex(argv[4], &off) || off > 0x100000 || strlen(argv[5]) >= sizeof(fields)) { SN.refused++; log_line("SNAP TABLE %d refused: bad form", id); g_dirty = 1; return; }
    snap_tab_free(t);
    strcpy(fields, argv[5]);
    if (!snap_parse_fields(t, fields)) { SN.refused++; memset(t, 0, sizeof(*t)); log_line("SNAP TABLE %d refused: bad field list", id); g_dirty = 1; return; }
    __try {
        if (!uoa_prove(root, &t->ridx, &t->rcls)) { SN.refused++; memset(t, 0, sizeof(*t)); log_line("SNAP TABLE %d refused: the root %IX is no object alive", id, root); g_dirty = 1; return; }
    } __except (EXCEPTION_EXECUTE_HANDLER) { SN.refused++; memset(t, 0, sizeof(*t)); g_dirty = 1; return; }
    t->e = (snap_ent *)VirtualAlloc(NULL, sizeof(snap_ent) * SNAP_EMAX, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    t->hash = (int32_t *)VirtualAlloc(NULL, sizeof(int32_t) * SNAP_HASH, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!t->e || !t->hash) { snap_tab_free(t); SN.refused++; log_line("SNAP TABLE %d refused: no memory", id); g_dirty = 1; return; }
    t->root = root; t->list_off = (uint32_t)off; t->on = 1; t->full = 1;
    log_line("SNAP TABLE %d on: root %IX list +%IX, %d fields", id, root, off, t->nf);
    g_dirty = 1;
}

static uint32_t sn_h(uintptr_t a) { uint64_t x = (uint64_t)a; x ^= x >> 29; x *= 0xBF58476D1CE4E5B9ull; x ^= x >> 32; return (uint32_t)x & (SNAP_HASH - 1); }
static int sn_find(snap_tab *t, uintptr_t a)
{
    uint32_t h = sn_h(a), k;
    for (k = 0; k < SNAP_HASH; k++, h = (h + 1) & (SNAP_HASH - 1)) {
        int32_t s = t->hash[h];
        if (s == 0) return -1;
        if (s > 0 && t->e[s - 1].a == a) return s - 1;
    }
    return -1;
}
static void sn_rehash(snap_tab *t)            /* removed marks thrown away: every slot in use put in again */
{
    int i;
    memset(t->hash, 0, sizeof(int32_t) * SNAP_HASH); t->tomb = 0;
    for (i = 0; i < t->ne; i++) if (t->e[i].a) {
        uint32_t h = sn_h(t->e[i].a), k;
        for (k = 0; k < SNAP_HASH; k++, h = (h + 1) & (SNAP_HASH - 1)) if (t->hash[h] == 0) { t->hash[h] = i + 1; break; }
    }
}
static int sn_add(snap_tab *t, uintptr_t a)
{
    uint32_t h = sn_h(a), k; int slot = -1, i;
    if (t->nfree > 0) for (i = 0; i < t->ne; i++) if (!t->e[i].a) { slot = i; t->nfree--; break; }
    if (slot < 0) { if (t->ne >= SNAP_EMAX) return -1; slot = t->ne++; }
    for (k = 0; k < SNAP_HASH; k++, h = (h + 1) & (SNAP_HASH - 1)) if (t->hash[h] <= 0) { if (t->hash[h] < 0) t->tomb--; t->hash[h] = slot + 1; break; }
    memset(&t->e[slot], 0, sizeof(snap_ent));
    t->e[slot].a = a;
    return slot;
}
static void sn_del(snap_tab *t, int slot)
{
    uint32_t h = sn_h(t->e[slot].a), k;
    for (k = 0; k < SNAP_HASH; k++, h = (h + 1) & (SNAP_HASH - 1)) {
        if (t->hash[h] == 0) break;
        if (t->hash[h] == slot + 1) { t->hash[h] = -1; t->tomb++; break; }
    }
    t->e[slot].a = 0; t->nfree++;
    if (t->tomb > SNAP_HASH / 4) sn_rehash(t);
}

/* the fields of one proved object into tmp; 0 = a fault or a list out of bounds (the entry is dropped this tick) */
static int sn_read(const snap_tab *t, uintptr_t a, snap_ent *tmp)
{
    int k;
    tmp->na = 0; tmp->ng[0] = 0; tmp->ng[1] = 0;
    __try {
        for (k = 0; k < t->nf; k++) {
            const snap_field *f = &t->f[k];
            uintptr_t at = a + f->off;
            int64_t v = 0;
            switch (f->kind) {
            case 'i': v = *(const int32_t *)at; break;
            case 'u': v = *(const uint8_t *)at; break;
            case 'b': v = (*(const uint8_t *)at & f->arg) ? 1 : 0; break;
            case 'p': v = (int64_t)*(const uintptr_t *)at; break;
            case 'f': { double d = *(const float *)at; memcpy(&v, &d, 8); } break;
            case 'n': { uintptr_t d; int32_t n; if (!snap_tarr(at, &d, &n, 1 << 20)) return 0; v = n; } break;
            case 'a': { uintptr_t d; int32_t n, j; if (!snap_tarr(at, &d, &n, 4096)) return 0; v = n; if (n > (int32_t)f->arg) n = (int32_t)f->arg;
                        for (j = 0; j < n; j++) tmp->arr[j] = *(const uint8_t *)(d + (size_t)j * f->arg2); tmp->na = (uint16_t)n; } break;
            case 'g': { uintptr_t d; int32_t n, j; int w = (k == t->fg[0]) ? 0 : 1; if (!snap_tarr(at, &d, &n, 4096)) return 0; v = n; if (n > SNAP_GMAX) n = SNAP_GMAX;
                        for (j = 0; j < n; j++) { tmp->g[w][2 * j] = *(const int32_t *)(d + (size_t)j * f->arg); tmp->g[w][2 * j + 1] = *(const int32_t *)(d + (size_t)j * f->arg + 4); }
                        tmp->ng[w] = (uint16_t)n; } break;
            case 'd': { uintptr_t p = *(const uintptr_t *)at; if (uoa_ptr_ok(p)) { double d = *(const double *)(p + f->arg); memcpy(&v, &d, 8); } else v = INT64_MIN; } break;
            case 'q': { uintptr_t p = *(const uintptr_t *)at; v = uoa_ptr_ok(p) ? (int64_t)*(const uintptr_t *)(p + f->arg) : INT64_MIN; } break;
            /* the list's first record (a struct list: data, count, room): a field at +arg of record 0; INT64_MIN when empty */
            case 'e': case 'h': case 'x': case 'r': { uintptr_t d; int32_t n; if (!snap_tarr(at, &d, &n, 1 << 20)) return 0;
                        if (n == 0) v = INT64_MIN;
                        else if (f->kind == 'e') v = *(const int32_t *)(d + f->arg);
                        else if (f->kind == 'h') v = *(const uint8_t *)(d + f->arg);
                        else if (f->kind == 'r') v = (int64_t)*(const uintptr_t *)(d + f->arg);
                        else { double x = *(const double *)(d + f->arg); memcpy(&v, &x, 8); } } break;
            }
            tmp->v[k] = v;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { return 0; }
    return 1;
}
static int sn_same(const snap_tab *t, const snap_ent *e, const snap_ent *tmp)
{
    if (memcmp(e->v, tmp->v, sizeof(int64_t) * (size_t)t->nf) != 0) return 0;
    if (e->na != tmp->na || memcmp(e->arr, tmp->arr, tmp->na) != 0) return 0;
    if (e->ng[0] != tmp->ng[0] || memcmp(e->g[0], tmp->g[0], sizeof(int32_t) * 2 * (size_t)tmp->ng[0]) != 0) return 0;
    if (e->ng[1] != tmp->ng[1] || memcmp(e->g[1], tmp->g[1], sizeof(int32_t) * 2 * (size_t)tmp->ng[1]) != 0) return 0;
    return 1;
}

/* one table, one tick: the root proved, its list read (count first), every element proved, its fields read */
static void snap_tab_tick(snap_tab *t, int id)
{
    uintptr_t data = 0; int32_t num = 0, i;
    int ok = 0;
    t->gen++;
    __try {
        ok = uoa_still(t->root, t->ridx, t->rcls) && snap_tarr(t->root + t->list_off, &data, &num, SNAP_EMAX);
    } __except (EXCEPTION_EXECUTE_HANDLER) { ok = 0; t->faults++; }
    if (!ok) {
        /* the root is gone (a world unloaded) or its list is out of bounds: every entry gone, the table stops */
        t->rootbad++;
        for (i = 0; i < t->ne; i++) if (t->e[i].a) { t->e[i].seen = 0; }
        log_line("SNAP TABLE %d: its root is no object alive or its list is out of bounds: stopped", id);
        t->on = 0;
        return;
    }
    for (i = 0; i < num; i++) {
        uintptr_t p = 0; int slot, alive = 0; int32_t idx = 0; uintptr_t cls = 0;
        snap_ent tmp;
        __try { p = *(const uintptr_t *)(data + (size_t)i * 8); } __except (EXCEPTION_EXECUTE_HANDLER) { t->faults++; break; }
        if (!p) continue;
        slot = sn_find(t, p);
        if (slot >= 0 && t->e[slot].seen == t->gen) continue;              /* twice in one list: the first place counts */
        __try {
            if (slot >= 0) alive = uoa_still(p, t->e[slot].idx, t->e[slot].cls) ? 1 : 2;
            else alive = uoa_prove(p, &idx, &cls) ? 1 : 0;
        } __except (EXCEPTION_EXECUTE_HANDLER) { alive = slot >= 0 ? 2 : 0; t->faults++; }
        /* known here and no longer alive (or another object at that address): left unseen, so this tick's answer names
         * it gone; an object now at that address is a new entry at the next tick */
        if (alive != 1) continue;                                          /* not an object alive: not in the table */
        t->reads++;
        if (!sn_read(t, p, &tmp)) { t->dropped++; if (slot >= 0) { sn_del(t, slot); t->gone++; } continue; }
        if (slot < 0) {
            slot = sn_add(t, p);
            if (slot < 0) { t->dropped++; continue; }
            t->e[slot].idx = idx; t->e[slot].cls = cls; t->e[slot].ver = 0;
            memcpy(t->e[slot].v, tmp.v, sizeof(tmp.v)); t->e[slot].na = tmp.na; memcpy(t->e[slot].arr, tmp.arr, sizeof(tmp.arr)); memcpy(t->e[slot].ng, tmp.ng, sizeof(tmp.ng)); memcpy(t->e[slot].g, tmp.g, sizeof(tmp.g));
            t->e[slot].ver = 1; t->changed++;
            t->e[slot].pos = (uint32_t)i | 0x80000000u;                   /* new: sent */
        } else {
            snap_ent *e = &t->e[slot];
            if (!sn_same(t, e, &tmp)) {
                memcpy(e->v, tmp.v, sizeof(tmp.v)); e->na = tmp.na; memcpy(e->arr, tmp.arr, sizeof(tmp.arr)); memcpy(e->ng, tmp.ng, sizeof(tmp.ng)); memcpy(e->g, tmp.g, sizeof(tmp.g));
                e->ver++; t->changed++;
                e->pos = (uint32_t)i | 0x80000000u;
            } else if ((e->pos & 0x7FFFFFFFu) != (uint32_t)i) e->pos = (uint32_t)i | 0x80000000u;   /* moved in the list: sent */
        }
        t->e[slot].seen = t->gen;
    }
}

static uint8_t *sn_put(uint8_t *p, const void *v, size_t n) { memcpy(p, v, n); return p + n; }

/* every table ticked; the answer written when anything changed */
static void snap_tick(void)
{
    int k, i, any = 0, ntab = 0;
    uint8_t *p, *q;
    unsigned long long t0;
    if (!SN.avail || !SN.uoa_ok) return;
    for (k = 0; k < SNAP_TABLES; k++) if (SN.t[k].on) ntab++;
    if (!ntab) return;
    t0 = co_now();
    SN.ticks++;
    if (!SN.buf) { SN.buf = (uint8_t *)VirtualAlloc(NULL, SNAP_OUTCAP, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE); if (!SN.buf) { snap_all_off("no memory for the answer"); return; } }
    p = SN.buf + 20;
    for (k = 0; k < SNAP_TABLES; k++) {
        snap_tab *t = &SN.t[k];
        uint32_t cnt = 0, nch = 0, ngone = 0; uint16_t nf;
        int full;
        uint8_t *head;
        if (!t->on) continue;
        { unsigned long long t1 = co_now(); snap_tab_tick(t, k); t->us += co_now() - t1; SN.tabus[k] += co_now() - t1; }
        full = t->full || SN.want_full;
        head = p; p += 1 + 1 + 2 + 4 + 4 + 4;
        if (!t->on) {     /* stopped this tick: every entry gone */
            for (i = 0; i < t->ne; i++) if (t->e[i].a) { if (p + 8 > SN.buf + SNAP_OUTCAP) break; p = sn_put(p, &t->e[i].a, 8); ngone++; }
            snap_tab_free(t);
            any = 1;
        } else {
            for (i = 0; i < t->ne; i++) {
                snap_ent *e = &t->e[i];
                if (!e->a || e->seen != t->gen) continue;
                cnt++;
                if (!(full || (e->pos & 0x80000000u))) continue;
                if (p + 24 + 8 * (size_t)t->nf + 2 + SNAP_AMAX + 4 + 16 * SNAP_GMAX + 64 > SN.buf + SNAP_OUTCAP) break;
                {   uint64_t a = e->a; uint32_t idx = (uint32_t)e->idx, pos = e->pos & 0x7FFFFFFFu;
                    p = sn_put(p, &a, 8); p = sn_put(p, &idx, 4); p = sn_put(p, &pos, 4); p = sn_put(p, &e->ver, 4); }
                p = sn_put(p, e->v, 8 * (size_t)t->nf);
                if (t->fa >= 0) { p = sn_put(p, &e->na, 2); p = sn_put(p, e->arr, e->na); }
                if (t->fg[0] >= 0) { p = sn_put(p, &e->ng[0], 2); p = sn_put(p, e->g[0], 8 * (size_t)e->ng[0]); }
                if (t->fg[1] >= 0) { p = sn_put(p, &e->ng[1], 2); p = sn_put(p, e->g[1], 8 * (size_t)e->ng[1]); }
                e->pos &= 0x7FFFFFFFu;
                nch++;
            }
            for (i = 0; i < t->ne; i++) {
                snap_ent *e = &t->e[i];
                if (!e->a || e->seen == t->gen) continue;
                if (p + 8 > SN.buf + SNAP_OUTCAP) break;
                { uint64_t a = e->a; p = sn_put(p, &a, 8); }
                sn_del(t, i); t->gone++; ngone++;
            }
            t->count = cnt;
            t->full = 0;
        }
        nf = (uint16_t)t->nf;
        q = head; *q++ = (uint8_t)k; *q++ = (uint8_t)(full ? 1 : 0); q = sn_put(q, &nf, 2); q = sn_put(q, &cnt, 4); q = sn_put(q, &nch, 4); q = sn_put(q, &ngone, 4);
        if (nch || ngone || full) any = 1;
    }
    SN.want_full = 0;
    if (any) {
        uint32_t len = (uint32_t)(p - SN.buf), ntv = (uint32_t)ntab;
        DWORD wr = 0; LARGE_INTEGER z;
        SN.prev = SN.seq; SN.seq++;
        q = SN.buf; q = sn_put(q, "SNP1", 4); q = sn_put(q, &SN.seq, 4); q = sn_put(q, &SN.prev, 4); q = sn_put(q, &len, 4); q = sn_put(q, &ntv, 4);
        if (!SN.out) {
            wchar_t path[MAX_PATH];
            join_path(path, g_dir, L"snap_out.bin");
            SN.out = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
            if (SN.out == INVALID_HANDLE_VALUE) { SN.out = NULL; log_line("SNAP: cannot write snap_out.bin (error %lu)", GetLastError()); }
        }
        if (SN.out) {
            z.QuadPart = 0;
            if (SetFilePointerEx(SN.out, z, NULL, FILE_BEGIN) && WriteFile(SN.out, SN.buf, len, &wr, NULL) && wr == len) { SN.writes++; SN.bytes += len; }
            else { CloseHandle(SN.out); SN.out = NULL; SN.faults++; }
        }
    }
    {   unsigned long long d = co_now() - t0; SN.us += d; if (d > SN.maxus) SN.maxus = d; }
}

/* ---- the crash guard (the core's C.scrubClose) */
static void snap_guard_cmd(int argc, char **argv)
{
    uintptr_t p, h, off;
    g_dirty = 1;
    if (argc == 3 && _stricmp(argv[2], "OFF") == 0) { SN.g_on = 0; log_line("SNAP GUARD off"); return; }
    if (!SN.avail || !SN.uoa_ok) { SN.refused++; log_line("SNAP GUARD refused: %s", SN.avail ? "the object array was not checked" : SN.why); return; }
    if (argc != 5 || !snap_hex(argv[2], &p) || !snap_hex(argv[3], &h) || !snap_hex(argv[4], &off) || off > 0x10000) { SN.refused++; log_line("SNAP GUARD refused: bad form"); return; }
    __try {
        if (!uoa_prove(p, &SN.g_pidx, &SN.g_pcls)) { SN.refused++; SN.g_on = 0; log_line("SNAP GUARD refused: the lord %IX is no object alive", p); return; }
        SN.g_h = 0;
        if (h) { if (uoa_prove(h, &SN.g_hidx, &SN.g_hcls)) SN.g_h = h; else log_line("SNAP GUARD: the helper %IX is no object alive: left out", h); }
    } __except (EXCEPTION_EXECUTE_HANDLER) { SN.refused++; SN.g_on = 0; return; }
    SN.g_p = p; SN.g_off = (uint32_t)off; SN.g_on = 1;
    log_line("SNAP GUARD on: lord %IX, helper %IX, list +%IX", p, SN.g_h, off);
}
/* an entry of the nearby-buildings list alive? (its own SEH: a freed entry's memory may be gone) */
static int snap_guard_alive(uintptr_t b)
{
    int32_t i; uintptr_t c; int ok = 0;
    if (!b) return 0;
    __try { ok = uoa_prove(b, &i, &c); } __except (EXCEPTION_EXECUTE_HANDLER) { ok = 0; }
    return ok;
}
static void snap_guard_tick(void)
{
    if (!SN.g_on) return;
    SN.g_ticks++;
    __try {
        /* the helper: its list kept empty (count 0; the room stays the game's) */
        if (SN.g_h) {
            if (uoa_still(SN.g_h, SN.g_hidx, SN.g_hcls)) {
                uintptr_t d; int32_t n;
                if (snap_tarr(SN.g_h + SN.g_off, &d, &n, 1 << 20) && n > 0) { *(int32_t *)(SN.g_h + SN.g_off + 8) = 0; SN.g_helper += (unsigned long long)n; }
            } else { SN.g_h = 0; SN.g_gone++; log_line("SNAP GUARD: the helper is no object alive any more: left out"); g_dirty = 1; }
        }
        if (!uoa_still(SN.g_p, SN.g_pidx, SN.g_pcls)) { SN.g_on = 0; SN.g_gone++; log_line("SNAP GUARD: the lord is no object alive any more: off"); g_dirty = 1; return; }
        {
            uintptr_t d; int32_t n, i, bad = 0; uintptr_t good = 0;
            if (!snap_tarr(SN.g_p + SN.g_off, &d, &n, 4096)) { SN.g_faults++; return; }
            for (i = 0; i < n; i++) { uintptr_t b = *(const uintptr_t *)(d + (size_t)i * 8); if (snap_guard_alive(b)) { if (!good) good = b; } else bad++; }
            if (!bad) return;
            if (good) { for (i = 0; i < n; i++) { uintptr_t *s = (uintptr_t *)(d + (size_t)i * 8); if (!snap_guard_alive(*s)) *s = good; } SN.g_fixed += (unsigned long long)bad; log_line("SNAP GUARD: %d entries of the player's nearby-buildings list were gone and were replaced (total so far %llu)", bad, SN.g_fixed); }
            else { *(int32_t *)(SN.g_p + SN.g_off + 8) = 0; SN.g_emptied += (unsigned long long)n; log_line("SNAP GUARD: the player's nearby-buildings list held no living entry (%d entries): emptied", n); }
            g_dirty = 1;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { SN.g_faults++; SN.g_on = 0; log_line("SNAP GUARD: exception %08lX: off", GetExceptionCode()); g_dirty = 1; }
}

/* SNAP PROBE <hex>,...: snap_probe.txt, per address (valid in the Lua this frame) its number, class, name and the
 * object array's entry at that number with entry sizes 16, 24 and 32 (the layout check; nothing is decided by it) */
static void snap_probe(const char *list)
{
    wchar_t path[MAX_PATH];
    FILE *f;
    char buf[MAX_LINE];
    char *tok, *ctx = NULL;
    uint8_t *uoa = snap_uoa_addr();
    join_path(path, g_dir, L"snap_probe.txt");
    f = _wfopen(path, L"wb");
    if (!f) return;
    if (!snap_build_ok()) { fprintf(f, "refused: not the known game build\r\n"); fclose(f); return; }
    if (strlen(list) >= sizeof(buf)) { fclose(f); return; }
    __try {
        uint8_t **chunks = *(uint8_t ***)(uoa + 0x10);
        fprintf(f, "uoa %p objects=%p max=%d num=%d maxchunks=%d numchunks=%d\r\n", (void *)uoa, (void *)chunks,
                *(int32_t *)(uoa + 0x20), *(int32_t *)(uoa + 0x24), *(int32_t *)(uoa + 0x28), *(int32_t *)(uoa + 0x2C));
        strcpy(buf, list);
        for (tok = strtok_s(buf, ",", &ctx); tok; tok = strtok_s(NULL, ",", &ctx)) {
            uintptr_t a = 0; int stride;
            if (!snap_hex(tok, &a) || !a) { fprintf(f, "bad %s\r\n", tok); continue; }
            if (!range_readable((void *)a, 0x20)) { fprintf(f, "%IX unreadable\r\n", a); continue; }
            {
                uint8_t *o = (uint8_t *)a;
                int32_t idx = *(int32_t *)(o + OBJ_INDEX_OFF);
                fprintf(f, "%IX flags=%08X idx=%d class=%p\r\n", a, *(uint32_t *)(o + 8), idx, *(void **)(o + 0x10));
                if (idx < 0 || idx >= *(int32_t *)(uoa + 0x24)) { fprintf(f, "   index out of the array\r\n"); continue; }
                for (stride = 16; stride <= 32; stride += 8) {
                    uint8_t *ch = chunks[idx / UOA_CHUNK];
                    uint8_t *it = ch ? ch + (size_t)(idx % UOA_CHUNK) * (size_t)stride : NULL;
                    if (!it || !range_readable(it, 0x18)) { fprintf(f, "   stride %d: unreadable\r\n", stride); continue; }
                    fprintf(f, "   stride %d: obj=%p %s w8=%08X wC=%08X w10=%08X w14=%08X\r\n", stride, *(void **)it, *(uint8_t **)it == o ? "SAME" : "other",
                            *(uint32_t *)(it + 8), *(uint32_t *)(it + 0xC), *(uint32_t *)(it + 0x10), *(uint32_t *)(it + 0x14));
                }
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { fprintf(f, "exception %08lX\r\n", GetExceptionCode()); }
    fclose(f);
}

static void snap_cmd(int argc, char **argv)
{
    if (argc == 3 && _stricmp(argv[1], "PROBE") == 0) { snap_probe(argv[2]); return; }
    if (argc == 3 && _stricmp(argv[1], "UOA") == 0) { snap_uoa_cmd(argv[2]); return; }
    if (argc >= 4 && _stricmp(argv[1], "TABLE") == 0) { snap_table_cmd(argc, argv); return; }
    if (argc == 2 && _stricmp(argv[1], "FULL") == 0) { SN.want_full = 1; return; }
    if (argc >= 3 && _stricmp(argv[1], "GUARD") == 0) { snap_guard_cmd(argc, argv); return; }
    if (argc == 2 && _stricmp(argv[1], "OFF") == 0) { snap_all_off("SNAP OFF"); SN.uoa_ok = 0; return; }
#ifdef COOP_PATCH_TEST
    if (argc == 3 && _stricmp(argv[1], "TESTUOA") == 0) { uintptr_t a; if (snap_hex(argv[2], &a)) { g_snap_test_uoa = (uint8_t *)a; snap_scan(); } g_dirty = 1; return; }
#endif
    SN.refused++;
    log_line("SNAP: unknown form");
}
/* SNAP's own commands that come often (FULL) are not logged; the rest are */
static int snap_quiet_cmd(const char *line) { return _strnicmp(line, "SNAP FULL", 9) == 0; }
