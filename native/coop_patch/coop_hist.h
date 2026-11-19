/* ------------------------------------------------------------------ HIST (lane 72): the first-run probe commands for the
 * three histories Lua cannot reach (research/2026-11-10-game-probe/lanes/lane_s21_72/report.txt, sections 7 and 8).
 * Included by coop_patch.c. Known build only (every offset below was READ in the 0.8.117 game file).
 *
 * Read only:
 *   HIST SUBDUMP <subsystem> <tag> [days] [stride]   hist_sub_<tag>.txt: ProductionSubsystem's region records (+38h,
 *        count +40h, 20h each: +8 the region, +10h its day records, count +18h, 100h each, the newest first), for each
 *        region the newest <days> records (default 3): the date (+F0h/+F4h/+F8h) and the three maps good -> amount at
 *        +0h, +50h, +A0h (a set: elements +0, count +8, its allocation bits +10h (inline) / +20h (beyond) and their
 *        number +28h, free slots +34h); an element is <stride> bytes (default 16: key int32, value int32), only
 *        allocated ones are read.
 *   HIST GRIDHASH <engine> <tag> [block] [steps]     hist_grid_<tag>.txt: the fertility grid (+8E0h, count +8E8h, 10h
 *        bytes a cell, four floats) as the overlay can show it: each float clamped to 0..1 and rounded to <steps>
 *        (default 255), hashed in blocks of <block> x <block> cells (default 32); one hash a block, row by row.
 *   HIST DUMP <object> <offset> <bytes> <tag>        hist_dump_<tag>.txt: <bytes> (at most 4096) at object + offset.
 *   HIST DUMPLIST <object> <offset> <size> <max> <tag>  hist_list_<tag>.txt: the list whose header ({data, num, max})
 *        is at object + offset: its first min(num, <max>) elements of <size> bytes (at most 64 KB in all).
 *   Every object passed must pass comp_sane (committed, 8-aligned, its vtable in the game module) at the moment of the
 *   command; every list's count is checked against its capacity and a ceiling, and its elements' memory is checked
 *   readable before anything is read: nothing is read past a list's end. All reads run under __try.
 * One call of a game routine (a TEST copy only):
 *   HIST TRYADD <tracker> <good> <amount>   calls the tracker's own add routine 4bb3620 (signature HADD) once, with no
 *        worker: the game's code then finds or adds the good's list, caps it at 366, adds to today's entry or appends
 *        one, and tells the panel. Refused unless ALL of:
 *          - the environment variable COOP_ROLE is set (the test harness starts its copies with it; a player's game is
 *            started by Steam, which never sets it; the mod's own role switch does not set it either);
 *          - the file dev_hist_tryadd.txt is in this DLL's I/O folder (only a test script makes it; no package holds
 *            it, the folder is made at run time);
 *          - the known build and exactly one HADD hit;
 *          - the tracker, its owner (+90h), the owner's engine (+2E8h) and the weather master (+118h, read +160h) pass
 *            comp_sane; good 0..1023, amount -1000..1000; at most 16 calls in a process.
 *        Both gates are checked at every command, never cached.
 * Status: "HIST available reads= files= tryadd=<ready|gated|unavailable> calls= refused= bad= faults=" or
 *         "HIST unavailable <why>".
 *
 * The carries (game run, lane 72; these run in a PLAYER'S install, with no COOP_ROLE gate):
 *   TRKDUMP / TRKSET (the production log), EXP (expertise), GRIDHASH steps 0 / GRIDROWS / GRIDGET / GRIDSET (the
 *   fertility grid), HSET (the region records). Two of them call a game routine, both after the advisor's trial
 *   passed on test copies (an existing and a new key, a save, a load, both kept: report sections 13 and 15):
 *     TRKSET  the tracker's add 4bb3620 (HADD) to make room for a longer list or a missing good (its growth was in use
 *             from 482beeb1, before its trial of section 13);
 *     HSET .. ADD  the map find-or-add 14489C0 (verified at its RVA) for a good the friend's record lacks.
 *   TRYADD and MAPADD (the trials' own commands) stay test-copy only. */
#define HS_SUB_LIST    0x38
#define HS_SUB_DATE    0x48
#define HS_REGREC      0x20
#define HS_DAYREC      0x100
#define HS_DAY_DATE    0xF0
#define HS_MAXREG      256
#define HS_MAXDAYS     2000
#define HS_MAXELEM     4096
#define HS_GRID        0x8E0
#define HS_CELL        16
#define HS_MAXCELLS    (4096 * 4096)
#define HS_TRK_OWNER   0x90
#define HS_TRK_WEATHER 0x118
#define HS_WEATHER_DAY 0x160
#define HS_OWNER_ENG   0x2E8
#define HS_MAXCALLS    16
typedef void (*hadd_fn)(void *tracker, int good, int amount, void *worker);
static struct { int avail; int hadd; int mapadd; char why[160], hwhy[160]; unsigned reads, files, calls, refused, bad, faults; } HST;
static struct { unsigned sets, entries, shrunk, shorts, nokeys, grows, keyadds, expsets; } HTS;     /* TRKSET (lane 72, game run) */

static int hist_status(char *buf, size_t len)
{
    const char *ta;
    if (g_off) return _snprintf(buf, len, "HIST unavailable dll is off\r\n");
    if (!HST.avail) return _snprintf(buf, len, "HIST unavailable %s\r\n", HST.why);
    ta = !HST.hadd ? "unavailable" : "gated";
    if (HST.hadd) {
        wchar_t p[MAX_PATH]; char e[8];
        join_path(p, g_dir, L"dev_hist_tryadd.txt");
        if (GetEnvironmentVariableA("COOP_ROLE", e, sizeof(e)) > 0 && GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES) ta = "ready";
    }
    return _snprintf(buf, len, "HIST available reads=%u files=%u tryadd=%s calls=%u refused=%u bad=%u faults=%u trkset=%u/%u shrunk=%u short=%u nokey=%u grows=%u keyadds=%u\r\n",
                     HST.reads, HST.files, ta, HST.calls, HST.refused, HST.bad, HST.faults, HTS.sets, HTS.entries, HTS.shrunk, HTS.shorts, HTS.nokeys, HTS.grows, HTS.keyadds);
}

/* The game's find-or-add of a map good -> amount (16-byte elements: key +0, value +4), RVA 14489C0 of the known build,
 * (map rcx, hash edx = the key, &key r8) -> the value's address; a missing key is added with 0 (through 1447EB0).
 * Three byte-identical copies of it are in the game file (the same template), so it is not found by a scan: its RVA
 * in the known build is verified instead, all 160 bytes with the call's target. Called (HIST MAPADD on a test copy,
 * HSET ... ADD once the trial passed), never patched. */
#define HS_MAPADD_RVA  0x14489C0
#define HS_MAPADD_EMPL 0x1447EB0
typedef int32_t *(*mapadd_fn)(void *map, int32_t hash, const int32_t *key);
static const char HS_MAPADD_PAT[] =
    "40 53 48 83 EC 30 8B 41 08 48 8B D9 44 8B D2 3B 41 34 74 41 4C 8B 49 40 48 8D 41 38 8B 49 48 4D 85 C9 4C 0F 44 C8 "
    "FF C9 49 23 CA 41 8B 04 89 83 F8 FF 74 21 48 8B 0B 41 8B 10 66 0F 1F 44 00 00 48 98 48 C1 E0 04 48 03 C1 39 10 74 "
    "44 8B 40 08 83 F8 FF 75 EB 4C 89 44 24 58 4C 8D 4C 24 58 45 8B C2 48 C7 44 24 20 00 00 00 00 48 8D 54 24 40 48 8B "
    "CB E8 ?? ?? ?? ?? 48 63 4C 24 40 48 8B 03 48 C1 E1 04 48 83 C1 04 48 03 C1 48 83 C4 30 5B C3 48 85 C0 74 BF 48 83 "
    "C0 04 48 83 C4 30 5B C3";
static int hist_mapadd_check(void)
{
    const uint8_t *f = g_base + HS_MAPADD_RVA; const char *q = HS_MAPADD_PAT; int i = 0, call = -1;
    if (!range_readable(f, 160)) return 0;
    while (*q) {
        while (*q == ' ') q++;
        if (!*q) break;
        if (q[0] == '?') { if (call < 0) call = i; q += 2; i++; continue; }
        { unsigned v; if (sscanf_s(q, "%2x", &v) != 1 || f[i] != (uint8_t)v) return 0; }
        q += 2; i++;
    }
    if (i != 160 || call < 1) return 0;
    return (size_t)(HS_MAPADD_RVA + call + 4) + (size_t)(intptr_t)*(const int32_t *)(f + call) == HS_MAPADD_EMPL;
}
static int32_t *hist_mapadd(uint8_t *map, int32_t key)
{
    int32_t k = key;
    return ((mapadd_fn)(void *)(g_base + HS_MAPADD_RVA))(map, key, &k);
}

static int hist_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    memset(&HST, 0, sizeof(HST)); memset(&HTS, 0, sizeof(HTS));
    if (!known) _snprintf(HST.why, sizeof(HST.why), "another game build (timestamp %X)", g_stamp);
    else HST.avail = 1;
    if (HST.avail && g_hit[S_HADD].hits == 1) HST.hadd = 1;
    else _snprintf(HST.hwhy, sizeof(HST.hwhy), "HADD signature has %d hits (need exactly 1)", g_hit[S_HADD].hits);
    if (HST.avail) HST.mapadd = hist_mapadd_check();
    log_line("  HIST %s %s", HST.avail ? "available" : "unavailable", HST.avail ? (HST.hadd ? "(TRYADD: HADD found)" : HST.hwhy) : HST.why);
    log_line("  HIST map add (1448 9C0): %s", HST.mapadd ? "verified" : "not verified (HSET adds nothing)");
    return 0;                      /* read only: does not count as a patch */
}

/* ------------------------------------------------------------------ output: one file per command, in the I/O folder */
typedef struct { char *p; size_t n, cap; int over; } hbuf;
static void hb_put(hbuf *b, const char *fmt, ...)
{
    va_list ap; int k;
    if (b->over) return;
    if (b->cap - b->n < 512) {
        size_t nc = b->cap ? b->cap * 2 : 65536; char *q;
        if (nc > (64u << 20)) { b->over = 1; return; }
        q = (char *)realloc(b->p, nc); if (!q) { b->over = 1; return; }
        b->p = q; b->cap = nc;
    }
    va_start(ap, fmt); k = _vsnprintf(b->p + b->n, b->cap - b->n - 1, fmt, ap); va_end(ap);
    if (k < 0) { b->over = 1; return; }
    b->n += (size_t)k;
}
static int hist_tag(const char *s)
{
    size_t i, n = strlen(s);
    if (n == 0 || n > 24) return 0;
    for (i = 0; i < n; i++) { char c = s[i]; if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) return 0; }
    return 1;
}
static void hb_write(hbuf *b, const char *kind, const char *tag)
{
    wchar_t path[MAX_PATH]; HANDLE h; DWORD wr = 0;
    _snwprintf(path, MAX_PATH - 1, L"%shist_%S_%S.txt", g_dir, kind, tag); path[MAX_PATH - 1] = 0;
    if (b->over) hb_put(b, "");        /* (nothing more fits: what is there is written, marked below) */
    h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) { log_line("HIST: cannot write hist_%s_%s.txt (error %lu)", kind, tag, GetLastError()); }
    else {
        if (b->n) WriteFile(h, b->p, (DWORD)b->n, &wr, NULL);
        if (b->over) WriteFile(h, "TRUNCATED\r\n", 11, &wr, NULL);
        WriteFile(h, "END\r\n", 5, &wr, NULL);
        CloseHandle(h); HST.files++;
    }
    free(b->p); b->p = NULL; b->n = b->cap = 0;
}
/* an address: hex, with or without 0x (the mod writes %X); a number: decimal, or hex with 0x */
static int hist_hex(const char *s, unsigned long long *v)
{
    char *end;
    if (!s || !*s || *s == '-' || *s == '+') return 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    if (!*s) return 0;
    *v = _strtoui64(s, &end, 16);
    return *end == 0;
}
static int hist_num(const char *s, int *v)
{
    unsigned long long x;
    if (s && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { if (!hist_hex(s, &x) || x > 0x7FFFFFFFull) return 0; *v = (int)x; return 1; }
    return parse_i32(s, v);
}
static int hist_obj(const char *s, unsigned long long *a, size_t bytes, const char *what)
{
    char why[200];
    if (!hist_hex(s, a)) { HST.bad++; log_line("HIST refused: %s '%.40s' is not a hex address", what, s); return 0; }
    if (!comp_sane(*a, bytes, why, sizeof(why))) { HST.bad++; log_line("HIST refused: %s: %s", what, why); return 0; }
    return 1;
}
/* a list header { data, int32 num, int32 max }: sane and its elements readable (nothing past the end is touched) */
static int hist_list(const uint8_t *hdr, size_t elem, int32_t ceil, uint8_t **data, int32_t *num)
{
    uint8_t *d = *(uint8_t *const volatile *)hdr;
    int32_t n = *(const volatile int32_t *)(hdr + 8), mx = *(const volatile int32_t *)(hdr + 12);
    if (n < 0 || n > mx || n > ceil || (n > 0 && (d == NULL || !range_readable(d, (size_t)n * elem)))) return 0;
    *data = d; *num = n;
    return 1;
}
/* a set's allocation bit i (TBitArray: inline words at +0, the words beyond at +10h when set, the bit count at +18h) */
static int hist_bit(const uint8_t *bits, int32_t i)
{
    const uint32_t *w = *(const uint32_t *const volatile *)(bits + 0x10);
    int32_t nb = *(const volatile int32_t *)(bits + 0x18);
    if (i < 0 || i >= nb) return 0;
    if (!w) w = (const uint32_t *)bits;
    else if (!range_readable(w, ((size_t)(i >> 5) + 1) * 4)) return 0;
    return (int)((w[i >> 5] >> (i & 31)) & 1u);
}
static void hist_map(hbuf *b, const uint8_t *m, size_t stride, const char *name)
{
    uint8_t *d; int32_t n, i, nfree = *(const volatile int32_t *)(m + 0x34), shown = 0;
    if (!hist_list(m, stride, HS_MAXELEM, &d, &n)) { hb_put(b, " %s=BAD", name); HST.bad++; return; }
    hb_put(b, " %s[%d/%d]", name, (int)(n - nfree), (int)n);
    for (i = 0; i < n; i++) {
        if (!hist_bit(m + 0x10, i)) continue;
        hb_put(b, "%s%d=%d", shown++ ? "," : ":", *(int32_t *)(d + (size_t)i * stride), *(int32_t *)(d + (size_t)i * stride + 4));
    }
}

static void hist_subdump(int argc, char **argv)
{
    unsigned long long a; int days = 3, stride = 16; hbuf b = { 0 };
    if (argc < 4 || argc > 6 || !hist_tag(argv[3])) { HST.bad++; log_line("HIST refused: SUBDUMP <subsystem> <tag> [days] [stride]"); return; }
    if ((argc >= 5 && (!hist_num(argv[4], &days) || days < 1 || days > HS_MAXDAYS)) || (argc == 6 && (!hist_num(argv[5], &stride) || stride < 8 || stride > 64 || (stride & 3)))) {
        HST.bad++; log_line("HIST refused: SUBDUMP days 1..%d, stride 8..64", HS_MAXDAYS); return;
    }
    if (!hist_obj(argv[2], &a, HS_SUB_DATE + 12, "SUBDUMP subsystem")) return;
    __try {
        const uint8_t *s = (const uint8_t *)(uintptr_t)a; uint8_t *recs; int32_t nr, i;
        hb_put(&b, "subsystem %llX date %d/%d/%d\r\n", a, *(int32_t *)(s + HS_SUB_DATE), *(int32_t *)(s + HS_SUB_DATE + 4), *(int32_t *)(s + HS_SUB_DATE + 8));
        if (!hist_list(s + HS_SUB_LIST, HS_REGREC, HS_MAXREG, &recs, &nr)) { HST.bad++; log_line("HIST SUBDUMP: the region list does not look like one"); hb_put(&b, "regions BAD\r\n"); }
        else {
            hb_put(&b, "regions %d\r\n", (int)nr);
            for (i = 0; i < nr; i++) {
                const uint8_t *r = recs + (size_t)i * HS_REGREC; uint8_t *dr; int32_t nd, j;
                if (!hist_list(r + 0x10, HS_DAYREC, HS_MAXDAYS, &dr, &nd)) { hb_put(&b, "region %d %llX days BAD\r\n", (int)i, *(unsigned long long *)(r + 8)); HST.bad++; continue; }
                hb_put(&b, "region %d %llX name %llX days %d\r\n", (int)i, *(unsigned long long *)(r + 8), *(unsigned long long *)r, (int)nd);
                for (j = 0; j < nd && j < days; j++) {
                    const uint8_t *dd = dr + (size_t)j * HS_DAYREC;
                    hb_put(&b, "  day %d date %d/%d/%d", (int)j, *(int32_t *)(dd + HS_DAY_DATE), *(int32_t *)(dd + HS_DAY_DATE + 4), *(int32_t *)(dd + HS_DAY_DATE + 8));
                    hist_map(&b, dd + 0x00, (size_t)stride, "m0"); hist_map(&b, dd + 0x50, (size_t)stride, "m50"); hist_map(&b, dd + 0xA0, (size_t)stride, "mA0");
                    hb_put(&b, "\r\n");
                }
            }
        }
        HST.reads++;
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST SUBDUMP: exception %08lX", GetExceptionCode()); hb_put(&b, "FAULT\r\n"); }
    hb_write(&b, "sub", argv[3]);
}

static uint32_t hist_fnv(uint32_t h, uint32_t v) { int k; for (k = 0; k < 4; k++) { h ^= (v >> (8 * k)) & 0xFFu; h *= 16777619u; } return h; }
static void hist_gridhash(int argc, char **argv)
{
    unsigned long long a; int blk = 32, steps = 255; hbuf b = { 0 };
    if (argc < 4 || argc > 6 || !hist_tag(argv[3])) { HST.bad++; log_line("HIST refused: GRIDHASH <engine> <tag> [block] [steps]"); return; }
    if ((argc >= 5 && (!hist_num(argv[4], &blk) || blk < 1 || blk > 1024)) || (argc == 6 && (!hist_num(argv[5], &steps) || steps < 0 || steps > 65535))) {
        HST.bad++; log_line("HIST refused: GRIDHASH block 1..1024, steps 0..65535 (0: exact bits)"); return;
    }
    if (!hist_obj(argv[2], &a, HS_GRID + 16, "GRIDHASH engine")) return;
    __try {
        const uint8_t *e = (const uint8_t *)(uintptr_t)a; uint8_t *g; int32_t n, side = 0, bx, by, x, y, k;
        unsigned capped = 0;
        if (!hist_list(e + HS_GRID, HS_CELL, HS_MAXCELLS, &g, &n)) { HST.bad++; log_line("HIST GRIDHASH: the grid does not look like a list"); hb_put(&b, "grid BAD\r\n"); }
        else {
            while ((long long)side * side < n) side++;
            if ((long long)side * side != n || side == 0 || side % blk) { HST.bad++; log_line("HIST GRIDHASH: %d cells is no square of a multiple of %d", (int)n, blk); hb_put(&b, "grid %d cells: not square\r\n", (int)n); }
            else {
                hb_put(&b, "grid %d cells side %d block %d steps %d\r\n", (int)n, (int)side, blk, steps);
                for (by = 0; by < side / blk; by++) {
                    for (bx = 0; bx < side / blk; bx++) {
                        uint32_t h = 2166136261u;
                        for (y = by * blk; y < (by + 1) * blk; y++) for (x = bx * blk; x < (bx + 1) * blk; x++) {
                            const float *c = (const float *)(g + ((size_t)y * (size_t)side + (size_t)x) * HS_CELL);
                            if (steps == 0) { for (k = 0; k < 4; k++) h = hist_fnv(h, ((const uint32_t *)c)[k]); if (c[0] >= 1.0f) capped++; continue; }
                            for (k = 0; k < 4; k++) {
                                float v = c[k]; uint32_t q;
                                if (!(v > 0.0f)) v = 0.0f;              /* (a NaN counts as 0) */
                                if (v >= 1.0f) { v = 1.0f; capped++; }
                                q = (uint32_t)(v * (float)steps + 0.5f);
                                h = hist_fnv(h, q);
                            }
                        }
                        hb_put(&b, "%s%08X", bx ? " " : "", h);
                    }
                    hb_put(&b, "\r\n");
                }
                hb_put(&b, "capped %u\r\n", capped);
            }
        }
        HST.reads++;
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST GRIDHASH: exception %08lX", GetExceptionCode()); hb_put(&b, "FAULT\r\n"); }
    hb_write(&b, "grid", argv[3]);
}

static void hist_dump(int argc, char **argv)
{
    unsigned long long a; int off, len; hbuf b = { 0 };
    if (argc != 6 || !hist_num(argv[3], &off) || !hist_num(argv[4], &len) || off < 0 || off > 0x100000 || len < 1 || len > 4096 || !hist_tag(argv[5])) {
        HST.bad++; log_line("HIST refused: DUMP <object> <offset> <bytes 1..4096> <tag>"); return;
    }
    if (!hist_obj(argv[2], &a, 16, "DUMP object")) return;
    if (!range_readable((const uint8_t *)(uintptr_t)a + off, (size_t)len)) { HST.bad++; log_line("HIST refused: DUMP %X bytes at +%X are not readable", len, off); return; }
    __try {
        const uint8_t *p = (const uint8_t *)(uintptr_t)a + off; int i;
        hb_put(&b, "object %llX offset %X bytes %X\r\n", a, off, len);
        for (i = 0; i < len; i++) hb_put(&b, "%s%02X%s", (i % 16) == 0 ? "" : " ", p[i], (i % 16) == 15 || i == len - 1 ? "\r\n" : "");
        HST.reads++;
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST DUMP: exception %08lX", GetExceptionCode()); hb_put(&b, "FAULT\r\n"); }
    hb_write(&b, "dump", argv[5]);
}

static void hist_dumplist(int argc, char **argv)
{
    unsigned long long a; int off, size, mx; hbuf b = { 0 };
    if (argc != 7 || !hist_num(argv[3], &off) || !hist_num(argv[4], &size) || !hist_num(argv[5], &mx) || off < 0 || off > 0x100000 || size < 1 || size > 4096
        || mx < 1 || (long long)size * mx > 65536 || !hist_tag(argv[6])) {
        HST.bad++; log_line("HIST refused: DUMPLIST <object> <offset> <size> <max> <tag> (size x max at most 64 KB)"); return;
    }
    if (!hist_obj(argv[2], &a, (size_t)off + 16, "DUMPLIST object")) return;
    __try {
        uint8_t *d; int32_t n, i, k, show;
        if (!hist_list((const uint8_t *)(uintptr_t)a + off, (size_t)size, 1 << 26, &d, &n)) { HST.bad++; log_line("HIST DUMPLIST: the list at +%X does not look like one", off); hb_put(&b, "list BAD\r\n"); }
        else {
            show = n < mx ? n : mx;
            hb_put(&b, "object %llX list +%X num %d max %d element %X shown %d\r\n", a, off, (int)n, *(int32_t *)((uint8_t *)(uintptr_t)a + off + 12), size, (int)show);
            for (i = 0; i < show; i++) {
                hb_put(&b, "%d:", (int)i);
                for (k = 0; k < size; k++) hb_put(&b, " %02X", d[(size_t)i * size + k]);
                hb_put(&b, "\r\n");
            }
        }
        HST.reads++;
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST DUMPLIST: exception %08lX", GetExceptionCode()); hb_put(&b, "FAULT\r\n"); }
    hb_write(&b, "list", argv[6]);
}

static void hist_tryadd(int argc, char **argv)
{
    unsigned long long t; int good, amount; char e[8], why[200]; wchar_t p[MAX_PATH];
    uint8_t *own = NULL, *eng = NULL, *wm = NULL;
    if (!HST.hadd) { HST.refused++; log_line("HIST TRYADD refused: %s", HST.hwhy); return; }
    /* the two gates of a test copy, at every command */
    if (GetEnvironmentVariableA("COOP_ROLE", e, sizeof(e)) == 0) { HST.refused++; log_line("HIST TRYADD refused: not a test copy (no COOP_ROLE)"); return; }
    join_path(p, g_dir, L"dev_hist_tryadd.txt");
    if (GetFileAttributesW(p) == INVALID_FILE_ATTRIBUTES) { HST.refused++; log_line("HIST TRYADD refused: no dev_hist_tryadd.txt in the I/O folder"); return; }
    if (HST.calls >= HS_MAXCALLS) { HST.refused++; log_line("HIST TRYADD refused: %d calls already", HS_MAXCALLS); return; }
    if (argc != 5 || !hist_num(argv[3], &good) || !hist_num(argv[4], &amount) || good < 0 || good > 1023 || amount < -1000 || amount > 1000) {
        HST.bad++; log_line("HIST TRYADD refused: needs <tracker> <good 0..1023> <amount -1000..1000>"); return;
    }
    if (!hist_obj(argv[2], &t, HS_TRK_WEATHER + 8, "TRYADD tracker")) return;
    __try {
        own = *(uint8_t *volatile *)((uint8_t *)(uintptr_t)t + HS_TRK_OWNER);
        wm = *(uint8_t *volatile *)((uint8_t *)(uintptr_t)t + HS_TRK_WEATHER);
        if (own && comp_sane((unsigned long long)(uintptr_t)own, HS_OWNER_ENG + 8, why, sizeof(why))) eng = *(uint8_t *volatile *)(own + HS_OWNER_ENG);
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST TRYADD: exception %08lX reading the tracker", GetExceptionCode()); return; }
    if (!own || !comp_sane((unsigned long long)(uintptr_t)own, HS_OWNER_ENG + 8, why, sizeof(why))) { HST.bad++; log_line("HIST TRYADD refused: the tracker's owner (+90h): %s", own ? why : "none"); return; }
    if (!eng || !comp_sane((unsigned long long)(uintptr_t)eng, 0x10A8, why, sizeof(why))) { HST.bad++; log_line("HIST TRYADD refused: the owner's engine (+2E8h): %s", eng ? why : "none"); return; }
    if (!wm || !comp_sane((unsigned long long)(uintptr_t)wm, HS_WEATHER_DAY + 8, why, sizeof(why))) { HST.bad++; log_line("HIST TRYADD refused: the weather master (+118h): %s", wm ? why : "none"); return; }
    __try {
        ((hadd_fn)(void *)(g_base + g_hit[S_HADD].rva))((void *)(uintptr_t)t, good, amount, NULL);
        HST.calls++;
        log_line("HIST TRYADD %llX good %d amount %d: called", t, good, amount);
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST TRYADD: exception %08lX inside the game's add routine", GetExceptionCode()); }
}

/* HIST TRKDUMP <tag> <tracker>[,<tracker>...]   hist_trk_<tag>.txt: each tracker's production log, read from its map
 * at +0C8h (elements 20h: key +0, its list +8 {data, num, max}; entries 10h: int64 day +0, int32 amount +8), only
 * allocated elements, at most HS_TRK_MAXE entries a good. One line a tracker:
 *   <tracker hex> <goods> | <good>:<n>:<day>/<amount>,... | ...        or  <tracker hex> BAD <why>
 * (GetEntriesOfItemType through the mod loader crashed both copies in run l72a: this reads the same memory itself.) */
#define HS_TRK_MAP     0xC8
#define HS_TRK_ELEM    0x20
#define HS_TRK_ENTRY   0x10
#define HS_TRK_MAXE    1000
static void hist_trkdump(int argc, char **argv)
{
    hbuf b = { 0 }; char *list, *tok, *ctx = NULL; int n = 0;
    if (argc != 4 || !hist_tag(argv[2])) { HST.bad++; log_line("HIST refused: TRKDUMP <tag> <tracker>,<tracker>,..."); return; }
    list = _strdup(argv[3]); if (!list) return;
    for (tok = strtok_s(list, ",", &ctx); tok && n < 4096; tok = strtok_s(NULL, ",", &ctx), n++) {
        unsigned long long a; char why[200];
        if (!hist_hex(tok, &a) || !comp_sane(a, HS_TRK_MAP + 0x50, why, sizeof(why))) { hb_put(&b, "%s BAD %s\r\n", tok, hist_hex(tok, &a) ? why : "not hex"); HST.bad++; continue; }
        __try {
            const uint8_t *t = (const uint8_t *)(uintptr_t)a; uint8_t *el; int32_t ne, i, ng = 0;
            if (!hist_list(t + HS_TRK_MAP, HS_TRK_ELEM, HS_MAXELEM, &el, &ne)) { hb_put(&b, "%llX BAD the map\r\n", a); HST.bad++; }
            else {
                for (i = 0; i < ne; i++) if (hist_bit(t + HS_TRK_MAP + 0x10, i)) ng++;
                hb_put(&b, "%llX %d", a, (int)ng);
                for (i = 0; i < ne; i++) {
                    const uint8_t *e = el + (size_t)i * HS_TRK_ELEM; uint8_t *d; int32_t m, j;
                    if (!hist_bit(t + HS_TRK_MAP + 0x10, i)) continue;
                    if (!hist_list(e + 8, HS_TRK_ENTRY, HS_TRK_MAXE, &d, &m)) { hb_put(&b, " | %d:BAD", *(int32_t *)e); HST.bad++; continue; }
                    hb_put(&b, " | %d:%d:", *(int32_t *)e, (int)m);
                    for (j = 0; j < m; j++) hb_put(&b, "%s%lld/%d", j ? "," : "", *(long long *)(d + (size_t)j * HS_TRK_ENTRY), *(int32_t *)(d + (size_t)j * HS_TRK_ENTRY + 8));
                }
                hb_put(&b, "\r\n");
            }
            HST.reads++;
        }
        __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST TRKDUMP: exception %08lX at %llX", GetExceptionCode(), a); hb_put(&b, "%llX FAULT\r\n", a); }
    }
    free(list);
    hb_write(&b, "trk", argv[2]);
}

/* HIST TRKSET <tracker> <good> <from> <day>/<amount>,...|-   the good's list in the tracker's map from entry <from>
 * (0-based) on becomes the given entries, and its count from + their number: written in place, never past the list's
 * capacity (a list is never grown or moved here: "short" when the capacity is too small, "nokey" when the map has no
 * such good; the mod then leaves it to the game's own add). <from> must be at most the list's count (no hole). */
/* TRKSET's helpers: a good's element in the tracker's map (allocated slots only), and the game's own add (4bb3620,
 * amount 0, no worker), which the run's gate 2 showed safe from outside (an existing good, a new good) */
static uint8_t *hist_trk_find(uint8_t *t, int good)
{
    uint8_t *el; int32_t ne, i;
    if (!hist_list(t + HS_TRK_MAP, HS_TRK_ELEM, HS_MAXELEM, &el, &ne)) return NULL;
    for (i = 0; i < ne; i++) { uint8_t *e = el + (size_t)i * HS_TRK_ELEM; if (hist_bit(t + HS_TRK_MAP + 0x10, i) && *(int32_t *)e == good) return e; }
    return NULL;
}
static int hist_hadd_sane(uint8_t *t)
{
    char why[200]; uint8_t *own = NULL, *eng = NULL, *wm = NULL;
    __try { own = *(uint8_t *volatile *)(t + HS_TRK_OWNER); wm = *(uint8_t *volatile *)(t + HS_TRK_WEATHER); } __except (EXCEPTION_EXECUTE_HANDLER) { return 0; }
    if (!own || !comp_sane((unsigned long long)(uintptr_t)own, HS_OWNER_ENG + 8, why, sizeof(why))) return 0;
    __try { eng = *(uint8_t *volatile *)(own + HS_OWNER_ENG); } __except (EXCEPTION_EXECUTE_HANDLER) { return 0; }
    if (!eng || !comp_sane((unsigned long long)(uintptr_t)eng, 0x10A8, why, sizeof(why))) return 0;
    return wm && comp_sane((unsigned long long)(uintptr_t)wm, HS_WEATHER_DAY + 8, why, sizeof(why));
}
static void hist_hadd(uint8_t *t, int good) { ((hadd_fn)(void *)(g_base + g_hit[S_HADD].rva))((void *)t, good, 0, NULL); }

static void hist_trkset(int argc, char **argv)
{
    unsigned long long a; int good, from, k = 0; char *ctx = NULL, *tok, *list;
    long long days[HS_TRK_MAXE]; int32_t amts[HS_TRK_MAXE];
    if (argc != 6 || !hist_num(argv[3], &good) || !hist_num(argv[4], &from) || from < 0 || from > HS_TRK_MAXE) { HST.bad++; log_line("HIST refused: TRKSET <tracker> <good> <from> <day>/<amount>,...|-"); return; }
    if (strcmp(argv[5], "-") != 0) {
        list = _strdup(argv[5]); if (!list) return;
        for (tok = strtok_s(list, ",", &ctx); tok; tok = strtok_s(NULL, ",", &ctx)) {
            char *sl = strchr(tok, '/'), *e1, *e2; long long d; long q;
            if (!sl || k + from >= HS_TRK_MAXE) { k = -1; break; }
            *sl = 0; d = _strtoi64(tok, &e1, 10); q = strtol(sl + 1, &e2, 10);
            if (*e1 || *e2 || e1 == tok || e2 == sl + 1 || d < 0 || q < INT_MIN / 2 || q > INT_MAX / 2) { k = -1; break; }
            days[k] = d; amts[k] = (int32_t)q; k++;
        }
        free(list);
        if (k < 0) { HST.bad++; log_line("HIST TRKSET refused: an entry is not <day>/<amount> (or too many)"); return; }
    }
    if (!hist_obj(argv[2], &a, HS_TRK_MAP + 0x50, "TRKSET tracker")) return;
    {
        uint8_t *t = (uint8_t *)(uintptr_t)a, *e; int grows = 0, canAdd = HST.hadd && hist_hadd_sane(t);
        __try {
            e = hist_trk_find(t, good);
            if (!e && canAdd && k > 0) { hist_hadd(t, good); HTS.keyadds++; e = hist_trk_find(t, good); }   /* the game's own add makes the key */
            if (!e) { HTS.nokeys++; g_dirty = 1; return; }
            for (;;) {
                uint8_t *d; int32_t m, mx, j;
                mx = *(volatile int32_t *)(e + 0x14);
                if (!hist_list(e + 8, HS_TRK_ENTRY, HS_TRK_MAXE, &d, &m)) { HST.bad++; log_line("HIST TRKSET: good %d's list does not look like one", good); return; }
                if (from > m) { HST.bad++; log_line("HIST TRKSET refused: from %d is past the list's %d entries", from, (int)m); return; }
                if (from + k > mx) {
                    /* too small: the game's own add grows it by one (its last entry's day is made "not today" first, so
                     * the routine appends; the entries are all written over below) */
                    long long keep = 0; uint8_t *d2; int32_t m2;
                    if (!canAdd || grows >= 64 || m >= 366) { HTS.shorts++; g_dirty = 1; return; }
                    if (m > 0) { keep = *(volatile long long *)(d + (size_t)(m - 1) * HS_TRK_ENTRY); *(volatile long long *)(d + (size_t)(m - 1) * HS_TRK_ENTRY) = -1; }
                    hist_hadd(t, good); grows++; HTS.grows++;
                    e = hist_trk_find(t, good); if (!e) { HST.bad++; return; }
                    /* the old last entry's own day back (the list may have moved; the entry stays at its place m - 1;
                     * run l72g: left at -1 it stayed when the host's entries began after it) */
                    if (m > 0 && hist_list(e + 8, HS_TRK_ENTRY, HS_TRK_MAXE, &d2, &m2) && m2 >= m) *(volatile long long *)(d2 + (size_t)(m - 1) * HS_TRK_ENTRY) = keep;
                    continue;
                }
                if (from + k > 0 && (d == NULL || !range_readable(d, (size_t)(from + k) * HS_TRK_ENTRY))) { HTS.shorts++; g_dirty = 1; return; }
                for (j = 0; j < k; j++) {
                    uint8_t *q = d + (size_t)(from + j) * HS_TRK_ENTRY;
                    *(volatile long long *)q = days[j]; *(volatile int32_t *)(q + 8) = amts[j];
                }
                if (from + k < m) HTS.shrunk++;
                *(volatile int32_t *)(e + 0x10) = from + k;
                HTS.sets++; HTS.entries += (unsigned)k; g_dirty = 1;
                return;
            }
        }
        __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST TRKSET: exception %08lX at %llX", GetExceptionCode(), a); }
    }
}

/* HIST EXP <tag> <component>[=<value>],...   an ExpertiseComponent's expertise: a float at +0B8h that is not reflected
 * (GetExpertise 4bee7f0 truncates it; the game run showed 10 of 15 artisans' values apart). An item with "=value" is
 * written (the value must be a finite number from 0 to 100000), every item is read back into hist_exp_<tag>.txt:
 * "<component> <value as %.9g>" or "<component> BAD <why>". */
#define HS_EXP_OFF     0xB8
static void hist_exp(int argc, char **argv)
{
    hbuf b = { 0 }; char *list, *tok, *ctx = NULL; int n = 0;
    if (argc != 4 || !hist_tag(argv[2])) { HST.bad++; log_line("HIST refused: EXP <tag> <component>[=<value>],..."); return; }
    list = _strdup(argv[3]); if (!list) return;
    for (tok = strtok_s(list, ",", &ctx); tok && n < 4096; tok = strtok_s(NULL, ",", &ctx), n++) {
        unsigned long long a; char why[200]; char *eq = strchr(tok, '='); double v = 0; int set = 0;
        if (eq) { char *e; *eq = 0; v = strtod(eq + 1, &e); if (*e || e == eq + 1 || !(v >= 0.0 && v <= 100000.0)) { hb_put(&b, "%s BAD value\r\n", tok); HST.bad++; continue; } set = 1; }
        if (!hist_hex(tok, &a) || !comp_sane(a, HS_EXP_OFF + 4, why, sizeof(why))) { hb_put(&b, "%s BAD %s\r\n", tok, hist_hex(tok, &a) ? why : "not hex"); HST.bad++; continue; }
        __try {
            volatile float *p = (volatile float *)((uint8_t *)(uintptr_t)a + HS_EXP_OFF);
            if (set) { *p = (float)v; HTS.expsets++; }
            hb_put(&b, "%llX %.9g\r\n", a, (double)*p);
            HST.reads++;
        }
        __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; hb_put(&b, "%llX FAULT\r\n", a); }
    }
    free(list);
    hb_write(&b, "exp", argv[2]);
}

/* ------------------------------------------------------------------ the fertility grid carried (lane 72, block summaries)
 * The grid: engine +8E0h {data, num, max}, 16 bytes a cell (four floats), side x side cells (1024 x 1024). The game's
 * redraw queue: engine +1018h, a list of int32 cell indices (4cd6810 takes cells from its end and draws them; 4c9ae20
 * adds the cells it changed). Values are compared as their exact bits.
 *   HIST GRIDROWS <engine> <tag> <bx>:<by>,...        hist_grows_<tag>.txt  "<bx> <by> <h0> ... <h31>" (32-cell blocks:
 *                                                      one hash a row of the block, exact bits)
 *   HIST GRIDGET <engine> <tag> <bx> <by> <rowmask>   hist_gget_<tag>.txt   "<y> <x0> <cell hex x32>" for each row whose
 *                                                      bit is set (a cell: 32 hex digits, the four floats' bits)
 *   HIST GRIDSET <engine> <tag>                       reads hist_gin_<tag>.txt (lines as GRIDGET writes them), writes the
 *                                                      cells and puts each changed cell on the redraw queue (only while
 *                                                      the queue has room: no allocation); hist_gset_<tag>.txt the counts */
#define HS_GBLK        32
#define HS_GQUEUE      0x1018
static struct { unsigned rows, sets, cells, queued, full, bad; } HGS;
static int hist_grid(uint8_t *e, uint8_t **g, int32_t *side)
{
    int32_t n, s = 0;
    if (!hist_list(e + HS_GRID, HS_CELL, HS_MAXCELLS, g, &n)) return 0;
    while ((long long)s * s < n) s++;
    if ((long long)s * s != n || s == 0 || s % HS_GBLK) return 0;
    *side = s; return 1;
}
static uint32_t hist_rowhash(const uint8_t *g, int32_t side, int32_t y, int32_t x0)
{
    uint32_t h = 2166136261u; int x, k;
    for (x = x0; x < x0 + HS_GBLK; x++) { const uint32_t *c = (const uint32_t *)(g + ((size_t)y * (size_t)side + (size_t)x) * HS_CELL); for (k = 0; k < 4; k++) h = hist_fnv(h, c[k]); }
    return h;
}
static void hist_gridrows(int argc, char **argv)
{
    unsigned long long a; hbuf b = { 0 }; char *list, *tok, *ctx = NULL; int n = 0;
    if (argc != 5 || !hist_tag(argv[3])) { HST.bad++; log_line("HIST refused: GRIDROWS <engine> <tag> <bx>:<by>,..."); return; }
    if (!hist_obj(argv[2], &a, HS_GQUEUE + 16, "GRIDROWS engine")) return;
    list = _strdup(argv[4]); if (!list) return;
    __try {
        uint8_t *g; int32_t side;
        if (!hist_grid((uint8_t *)(uintptr_t)a, &g, &side)) { HST.bad++; hb_put(&b, "grid BAD\r\n"); }
        else for (tok = strtok_s(list, ",", &ctx); tok && n < 1024; tok = strtok_s(NULL, ",", &ctx), n++) {
            int bx, by, y; char *c = strchr(tok, ':');
            if (!c) { hb_put(&b, "%s BAD\r\n", tok); continue; }
            *c = 0;
            if (!hist_num(tok, &bx) || !hist_num(c + 1, &by) || bx < 0 || by < 0 || bx >= side / HS_GBLK || by >= side / HS_GBLK) { hb_put(&b, "%s:%s BAD\r\n", tok, c + 1); continue; }
            hb_put(&b, "%d %d", bx, by);
            for (y = 0; y < HS_GBLK; y++) hb_put(&b, " %08X", hist_rowhash(g, side, by * HS_GBLK + y, bx * HS_GBLK));
            hb_put(&b, "\r\n"); HGS.rows++;
        }
        HST.reads++;
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST GRIDROWS: exception %08lX", GetExceptionCode()); hb_put(&b, "FAULT\r\n"); }
    free(list);
    hb_write(&b, "grows", argv[3]);
}
static void hist_gridget(int argc, char **argv)
{
    unsigned long long a, mask; int bx, by; hbuf b = { 0 };
    if (argc != 7 || !hist_tag(argv[3]) || !hist_num(argv[4], &bx) || !hist_num(argv[5], &by) || !hist_hex(argv[6], &mask)) {
        HST.bad++; log_line("HIST refused: GRIDGET <engine> <tag> <bx> <by> <rowmask hex>"); return;
    }
    if (!hist_obj(argv[2], &a, HS_GQUEUE + 16, "GRIDGET engine")) return;
    __try {
        uint8_t *g; int32_t side; int y, x, k;
        if (!hist_grid((uint8_t *)(uintptr_t)a, &g, &side) || bx < 0 || by < 0 || bx >= side / HS_GBLK || by >= side / HS_GBLK) { HST.bad++; hb_put(&b, "BAD\r\n"); }
        else for (y = 0; y < HS_GBLK; y++) {
            if (!((mask >> y) & 1ull)) continue;
            hb_put(&b, "%d %d ", by * HS_GBLK + y, bx * HS_GBLK);
            for (x = bx * HS_GBLK; x < (bx + 1) * HS_GBLK; x++) {
                const uint32_t *c = (const uint32_t *)(g + ((size_t)(by * HS_GBLK + y) * (size_t)side + (size_t)x) * HS_CELL);
                for (k = 0; k < 4; k++) hb_put(&b, "%08X", c[k]);
            }
            hb_put(&b, "\r\n");
        }
        HST.reads++;
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST GRIDGET: exception %08lX", GetExceptionCode()); hb_put(&b, "FAULT\r\n"); }
    hb_write(&b, "gget", argv[3]);
}
static int hist_hex8(const char *s, uint32_t *v)
{
    int i; uint32_t x = 0;
    for (i = 0; i < 8; i++) { char c = s[i]; x <<= 4; if (c >= '0' && c <= '9') x |= (uint32_t)(c - '0'); else if (c >= 'A' && c <= 'F') x |= (uint32_t)(c - 'A' + 10); else if (c >= 'a' && c <= 'f') x |= (uint32_t)(c - 'a' + 10); else return 0; }
    *v = x; return 1;
}
/* cells written but not yet on the game's redraw queue (it was full: the game draws one cell from its front a frame,
 * and none while paused): kept here and put on the queue as it gets room (each GRIDSET, and GRIDFLUSH) */
#define HS_GPEND       65536
static int32_t g_gpend[HS_GPEND]; static int g_gpn; static uint8_t *g_gpeng;
static int hist_gq_put(uint8_t *e, int32_t idx)          /* 1: on the queue (already, or now); 0: no room */
{
    uint8_t *q = e + HS_GQUEUE; int32_t *qd = *(int32_t **)q; int32_t qn = *(int32_t *)(q + 8), qm = *(int32_t *)(q + 12), j;
    if (!qd || qn < 0 || qn > qm || !range_readable((const uint8_t *)qd, (size_t)qm * 4)) return 0;
    for (j = 0; j < qn; j++) if (qd[j] == idx) return 1;
    if (qn >= qm) return 0;
    qd[qn] = idx; *(int32_t *)(q + 8) = qn + 1;
    return 1;
}
static unsigned hist_gq_flush(uint8_t *e)                 /* -> cells moved onto the queue */
{
    int i, k = 0; unsigned moved = 0;
    if (e != g_gpeng) { g_gpn = 0; g_gpeng = e; return 0; }   /* another engine (a new world): the old list is void */
    for (i = 0; i < g_gpn; i++) { if (hist_gq_put(e, g_gpend[i])) moved++; else g_gpend[k++] = g_gpend[i]; }
    g_gpn = k;
    return moved;
}
static void hist_gridflush(int argc, char **argv)
{
    unsigned long long a; hbuf b = { 0 }; unsigned moved = 0;
    if (argc != 4 || !hist_tag(argv[3])) { HST.bad++; log_line("HIST refused: GRIDFLUSH <engine> <tag>"); return; }
    if (!hist_obj(argv[2], &a, HS_GQUEUE + 16, "GRIDFLUSH engine")) return;
    __try { moved = hist_gq_flush((uint8_t *)(uintptr_t)a); }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST GRIDFLUSH: exception %08lX", GetExceptionCode()); }
    hb_put(&b, "queued %u pending %d\r\n", moved, g_gpn);
    hb_write(&b, "gflush", argv[3]);
}
static void hist_gridset(int argc, char **argv)
{
    unsigned long long a; wchar_t p[MAX_PATH]; FILE *f = NULL; hbuf b = { 0 }; char *line; unsigned sets = 0, cells = 0, queued = 0, full = 0, bad = 0;
    if (argc != 4 || !hist_tag(argv[3])) { HST.bad++; log_line("HIST refused: GRIDSET <engine> <tag>"); return; }
    if (!hist_obj(argv[2], &a, HS_GQUEUE + 16, "GRIDSET engine")) return;
    _snwprintf(p, MAX_PATH - 1, L"%shist_gin_%S.txt", g_dir, argv[3]); p[MAX_PATH - 1] = 0;
    if (_wfopen_s(&f, p, L"rb") != 0 || !f) { HST.bad++; log_line("HIST GRIDSET: no hist_gin_%s.txt", argv[3]); return; }
    line = (char *)malloc(8192); if (!line) { fclose(f); return; }
    __try {
        uint8_t *e = (uint8_t *)(uintptr_t)a, *g; int32_t side;
        queued += hist_gq_flush(e);
        if (!hist_grid(e, &g, &side)) { bad++; }
        else while (fgets(line, 8192, f)) {
            int y, x0, x, k, pos = 0; char *s;
            if (sscanf_s(line, "%d %d %n", &y, &x0, &pos) < 2 || pos <= 0 || y < 0 || y >= side || x0 < 0 || x0 + HS_GBLK > side || (x0 % HS_GBLK)) { bad++; continue; }
            s = line + pos;
            if (strlen(s) < (size_t)HS_GBLK * 32) { bad++; continue; }
            for (x = 0; x < HS_GBLK; x++) {
                uint32_t v[4]; int ok = 1, changed = 0; size_t idx = (size_t)y * (size_t)side + (size_t)(x0 + x);
                uint32_t *c = (uint32_t *)(g + idx * HS_CELL);
                for (k = 0; k < 4; k++) ok &= hist_hex8(s + x * 32 + k * 8, &v[k]);
                if (!ok) { bad++; break; }
                for (k = 0; k < 4; k++) if (c[k] != v[k]) changed = 1;
                cells++;
                if (changed) {
                    /* the value is written at once (the game's own uses read it: yields, sowing); its redraw goes on the
                     * game's queue when there is room (never grown here), else on this piece's pending list */
                    for (k = 0; k < 4; k++) c[k] = v[k];
                    sets++;
                    if (hist_gq_put(e, (int32_t)idx)) queued++;
                    else if (g_gpn < HS_GPEND) { g_gpend[g_gpn++] = (int32_t)idx; full++; }
                    else full++;
                }
            }
        }
        HST.reads++;
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST GRIDSET: exception %08lX", GetExceptionCode()); bad++; }
    fclose(f); free(line);
    HGS.sets += sets; HGS.cells += cells; HGS.queued += queued; HGS.full += full; HGS.bad += bad;
    hb_put(&b, "cells %u changed %u queued %u deferred %u bad %u pending %d\r\n", cells, sets, queued, full, bad, g_gpn);
    hb_write(&b, "gset", argv[3]);
}

/* HIST HSET <subsystem> <tag>   the region history written in place (lane 72, the region graphs, no hook). Reads
 * hist_hin_<tag>.txt, one line a map:  <region object hex> <day>/<month>/<year> <map: 0|50|A0> <good>=<amount>,...
 * The record is found by its date among the region's newest HS_HSET_DAYS records (never by position: each copy makes
 * its record at its own day change); an amount is written where the map already holds the good (a value in place: no
 * rehash, no allocation); a good the map lacks is counted (missing), never added. hist_hset_<tag>.txt: the counts. */
#define HS_HSET_DAYS   5
static struct { unsigned lines, written, same, missing, nodate, bad, added; } HHS;
static void hist_hset(int argc, char **argv)
{
    unsigned long long a; wchar_t p[MAX_PATH]; FILE *f = NULL; hbuf b = { 0 }; char *line; unsigned lines = 0, written = 0, same = 0, missing = 0, nodate = 0, bad = 0, added = 0;
    int add = argc == 5 && _stricmp(argv[4], "ADD") == 0 && HST.mapadd;
    if ((argc != 4 && !(argc == 5 && _stricmp(argv[4], "ADD") == 0)) || !hist_tag(argv[3])) { HST.bad++; log_line("HIST refused: HSET <subsystem> <tag> [ADD]"); return; }
    if (!hist_obj(argv[2], &a, HS_SUB_DATE + 12, "HSET subsystem")) return;
    _snwprintf(p, MAX_PATH - 1, L"%shist_hin_%S.txt", g_dir, argv[3]); p[MAX_PATH - 1] = 0;
    if (_wfopen_s(&f, p, L"rb") != 0 || !f) { HST.bad++; log_line("HIST HSET: no hist_hin_%s.txt", argv[3]); return; }
    line = (char *)malloc(16384); if (!line) { fclose(f); return; }
    __try {
        const uint8_t *s = (const uint8_t *)(uintptr_t)a; uint8_t *recs; int32_t nr;
        if (!hist_list(s + HS_SUB_LIST, HS_REGREC, HS_MAXREG, &recs, &nr)) bad++;
        else while (fgets(line, 16384, f)) {
            unsigned long long reg; char rs[40]; int d, mo, y, off, pos = 0, i, j; uint8_t *rec = NULL; char *it, *ctx = NULL;
            if (sscanf_s(line, "%39s %d/%d/%d %x %n", rs, (unsigned)sizeof(rs), &d, &mo, &y, &off, &pos) < 5 || pos <= 0 || !hist_hex(rs, &reg) || (off != 0 && off != 0x50 && off != 0xA0)) { bad++; continue; }
            lines++;
            for (i = 0; i < nr && !rec; i++) {
                const uint8_t *r = recs + (size_t)i * HS_REGREC; uint8_t *dr; int32_t nd;
                if (*(const unsigned long long *)(r + 8) != reg) continue;
                if (!hist_list(r + 0x10, HS_DAYREC, HS_MAXDAYS, &dr, &nd)) break;
                for (j = 0; j < nd && j < HS_HSET_DAYS; j++) {
                    uint8_t *dd = dr + (size_t)j * HS_DAYREC;
                    if (*(int32_t *)(dd + HS_DAY_DATE) == d && *(int32_t *)(dd + HS_DAY_DATE + 4) == mo && *(int32_t *)(dd + HS_DAY_DATE + 8) == y) { rec = dd; break; }
                }
            }
            if (!rec) { nodate++; continue; }
            for (it = strtok_s(line + pos, ",\r\n", &ctx); it; it = strtok_s(NULL, ",\r\n", &ctx)) {
                int good, amt, k, found = 0; uint8_t *md; int32_t mn; char *eq = strchr(it, '=');
                if (!eq) { bad++; continue; }
                *eq = 0;
                if (!parse_i32(it, &good) || !parse_i32(eq + 1, &amt)) { bad++; continue; }
                if (!hist_list(rec + off, 16, HS_MAXELEM, &md, &mn)) { bad++; break; }
                for (k = 0; k < mn; k++) {
                    if (!hist_bit(rec + off + 0x10, k)) continue;
                    if (*(int32_t *)(md + (size_t)k * 16) == good) {
                        int32_t *v = (int32_t *)(md + (size_t)k * 16 + 4);
                        if (*v != amt) { *v = amt; written++; } else same++;
                        found = 1; break;
                    }
                }
                if (!found && add) {
                    /* the game's own find-or-add (verified at its RVA; used only after the advisor's trial passed) */
                    int32_t *v = hist_mapadd(rec + off, good);
                    if (v && hist_list(rec + off, 16, HS_MAXELEM, &md, &mn) && (uint8_t *)v >= md + 4 && (uint8_t *)v < md + (size_t)mn * 16) { *v = amt; added++; found = 1; }
                }
                if (!found) missing++;
            }
        }
        HST.reads++;
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST HSET: exception %08lX", GetExceptionCode()); bad++; }
    fclose(f); free(line);
    HHS.lines += lines; HHS.written += written; HHS.same += same; HHS.missing += missing; HHS.nodate += nodate; HHS.bad += bad; HHS.added += added;
    hb_put(&b, "lines %u written %u same %u missing %u nodate %u bad %u added %u\r\n", lines, written, same, missing, nodate, bad, added);
    hb_write(&b, "hset", argv[3]);
}

/* HIST MAPADD <subsystem> <region> <d/m/y> <0|50|A0> <good> <amount>   the advisor's trial of the game's find-or-add on a
 * region record's map (a TEST copy only: COOP_ROLE and dev_hist_mapadd.txt, as TRYADD; at most 16 calls): one call,
 * then the value written; logged. */
static unsigned g_mapadd_calls;
static void hist_mapadd_cmd(int argc, char **argv)
{
    unsigned long long a, reg; int d, mo, y, off, good, amt; char e[8]; wchar_t p[MAX_PATH];
    if (!HST.mapadd) { HST.refused++; log_line("HIST MAPADD refused: the routine is not verified"); return; }
    if (GetEnvironmentVariableA("COOP_ROLE", e, sizeof(e)) == 0) { HST.refused++; log_line("HIST MAPADD refused: not a test copy (no COOP_ROLE)"); return; }
    join_path(p, g_dir, L"dev_hist_mapadd.txt");
    if (GetFileAttributesW(p) == INVALID_FILE_ATTRIBUTES) { HST.refused++; log_line("HIST MAPADD refused: no dev_hist_mapadd.txt in the I/O folder"); return; }
    if (g_mapadd_calls >= HS_MAXCALLS) { HST.refused++; log_line("HIST MAPADD refused: %d calls already", HS_MAXCALLS); return; }
    if (argc != 8 || !hist_hex(argv[3], &reg) || sscanf_s(argv[4], "%d/%d/%d", &d, &mo, &y) != 3 || sscanf_s(argv[5], "%x", &off) != 1 || (off != 0 && off != 0x50 && off != 0xA0)
        || !parse_i32(argv[6], &good) || !parse_i32(argv[7], &amt)) { HST.bad++; log_line("HIST refused: MAPADD <subsystem> <region> <d/m/y> <0|50|A0> <good> <amount>"); return; }
    if (!hist_obj(argv[2], &a, HS_SUB_DATE + 12, "MAPADD subsystem")) return;
    __try {
        const uint8_t *s = (const uint8_t *)(uintptr_t)a; uint8_t *recs, *rec = NULL; int32_t nr, i, j;
        if (hist_list(s + HS_SUB_LIST, HS_REGREC, HS_MAXREG, &recs, &nr))
            for (i = 0; i < nr && !rec; i++) {
                const uint8_t *r = recs + (size_t)i * HS_REGREC; uint8_t *dr; int32_t nd;
                if (*(const unsigned long long *)(r + 8) != reg || !hist_list(r + 0x10, HS_DAYREC, HS_MAXDAYS, &dr, &nd)) continue;
                for (j = 0; j < nd && j < HS_HSET_DAYS; j++) { uint8_t *dd = dr + (size_t)j * HS_DAYREC; if (*(int32_t *)(dd + HS_DAY_DATE) == d && *(int32_t *)(dd + HS_DAY_DATE + 4) == mo && *(int32_t *)(dd + HS_DAY_DATE + 8) == y) { rec = dd; break; } }
            }
        if (!rec) { HST.bad++; log_line("HIST MAPADD: no record of %d/%d/%d for region %llX", d, mo, y, reg); return; }
        {
            int32_t *v = hist_mapadd(rec + off, good); g_mapadd_calls++;
            if (v) *v = amt;
            log_line("HIST MAPADD region %llX %d/%d/%d map %X good %d amount %d: called, value at %p", reg, d, mo, y, off, good, amt, (void *)v);
        }
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { HST.faults++; log_line("HIST MAPADD: exception %08lX", GetExceptionCode()); }
}

static void hist_cmd(int argc, char **argv)
{
    g_dirty = 1;
    if (!HST.avail) { HST.refused++; log_line("HIST refused: unavailable (%s)", HST.why); return; }
    if (argc < 2) { HST.bad++; log_line("HIST refused: SUBDUMP | GRIDHASH | DUMP | DUMPLIST | TRYADD"); return; }
    if (_stricmp(argv[1], "SUBDUMP") == 0) { hist_subdump(argc, argv); return; }
    if (_stricmp(argv[1], "GRIDHASH") == 0) { hist_gridhash(argc, argv); return; }
    if (_stricmp(argv[1], "DUMP") == 0) { hist_dump(argc, argv); return; }
    if (_stricmp(argv[1], "DUMPLIST") == 0) { hist_dumplist(argc, argv); return; }
    if (_stricmp(argv[1], "TRYADD") == 0) { hist_tryadd(argc, argv); return; }
    if (_stricmp(argv[1], "TRKDUMP") == 0) { hist_trkdump(argc, argv); return; }
    if (_stricmp(argv[1], "TRKSET") == 0) { hist_trkset(argc, argv); return; }
    if (_stricmp(argv[1], "EXP") == 0) { hist_exp(argc, argv); return; }
    if (_stricmp(argv[1], "GRIDROWS") == 0) { hist_gridrows(argc, argv); return; }
    if (_stricmp(argv[1], "GRIDGET") == 0) { hist_gridget(argc, argv); return; }
    if (_stricmp(argv[1], "GRIDSET") == 0) { hist_gridset(argc, argv); return; }
    if (_stricmp(argv[1], "GRIDFLUSH") == 0) { hist_gridflush(argc, argv); return; }
    if (_stricmp(argv[1], "HSET") == 0) { hist_hset(argc, argv); return; }
    if (_stricmp(argv[1], "MAPADD") == 0) { hist_mapadd_cmd(argc, argv); return; }
    HST.bad++; log_line("HIST refused: unknown '%.20s'", argv[1]);
}
