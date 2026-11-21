/* ------------------------------------------------------------------ MERCCUT (lane 88): a friend's list of mercenary
 * offers as long as the host's (research\2026-11-10-game-probe\lanes\lane_s21_88\design_mercs.txt). Included by
 * coop_patch.c.
 *
 * Why: a hire takes the company off the offer list of the copy whose game ran the hire. A rival lord's hire (and the
 * host's own player's) runs on the host only; a friend makes the squads from the host's word and keeps the company on
 * offer (lead runs r27m83 and r27cf: 2 offers on the host, 3 on the friend for the rest of the session). The game has
 * no call that takes an offer off without hiring it, and a script cannot shorten a game list. The mod writes the
 * host's records into the friend's first slots, field by field (coop_realm.lua, proven safe); this command then
 * shortens the list to the host's length.
 *   MERCCUT <engine> <array> <count now> <count wanted>
 *     engine: the RTSMultiEngineCPP object (must look like a game object: committed, 8-aligned, vtable in the module)
 *     array:  the address the script layer gives for engine.availableMercs: must be engine + MC_LIST (the reflected
 *             offset, dumps/RTSMultiEngineCPP.txt), so a moved field is refused, never written
 *     the list's count must equal <count now>, its capacity at least that, its data pointer 8-aligned and non-null,
 *     and 0 <= <count wanted> < <count now> <= MC_MAXN.
 *   Writes <count wanted> into the list's count. Nothing is freed, called or hooked. The records past the new end
 *   stay whole in the list's own memory; the game reads only up to the count (its loops and its save), and a record
 *   it adds later is built over that slot (the old record's texts are then lost memory, never freed twice).
 * Known game build only. Status: "MERCCUT available cuts= refused= faults=" or "MERCCUT unavailable <why>". */
#define MC_LIST        0xBF0       /* RTSMultiEngineCPP.availableMercs (TArray: data +0, count +8, capacity +0Ch) */
#define MC_MAXN        64
static struct { int avail; char why[160]; unsigned cuts, refused, faults; } MCC;

static int merc_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "MERCCUT unavailable dll is off\r\n");
    if (!MCC.avail) return _snprintf(buf, len, "MERCCUT unavailable %s\r\n", MCC.why);
    return _snprintf(buf, len, "MERCCUT available cuts=%u refused=%u faults=%u\r\n", MCC.cuts, MCC.refused, MCC.faults);
}

static int merc_scan(void)
{
    memset(&MCC, 0, sizeof(MCC));
    if (g_stamp != KNOWN_TIMESTAMP || g_imgsize != KNOWN_IMAGESIZE) _snprintf(MCC.why, sizeof(MCC.why), "another game build (timestamp %X)", g_stamp);
    else MCC.avail = 1;
    log_line("  MERCCUT %s %s", MCC.avail ? "available" : "unavailable", MCC.avail ? "" : MCC.why);
    return MCC.avail;
}

/* the checks without the write (also the desk test's entry): 1 = may be cut */
static int merc_check(unsigned long long eng, unsigned long long arr, int now, int want, char *why, size_t wl)
{
    const uint8_t *e = (const uint8_t *)(uintptr_t)eng;
    void *data; int32_t n, cap;
    if (!comp_sane(eng, MC_LIST + 16, why, wl)) return 0;
    if (arr != eng + MC_LIST) { _snprintf(why, wl, "the list is at %llX, not at the engine + %X (%llX)", arr, MC_LIST, eng + MC_LIST); return 0; }
    if (now < 1 || now > MC_MAXN || want < 0 || want >= now) { _snprintf(why, wl, "counts %d -> %d are not a cut", now, want); return 0; }
    __try {
        data = *(void *volatile *)(e + MC_LIST); n = *(volatile int32_t *)(e + MC_LIST + 8); cap = *(volatile int32_t *)(e + MC_LIST + 12);
    } __except (EXCEPTION_EXECUTE_HANDLER) { _snprintf(why, wl, "reading the list faulted"); return 0; }
    if (n != now) { _snprintf(why, wl, "the list holds %d, not %d", (int)n, now); return 0; }
    if (cap < n || data == NULL || ((uintptr_t)data & 7)) { _snprintf(why, wl, "the list does not look like one (%p, %d of %d)", data, (int)n, (int)cap); return 0; }
    return 1;
}

static void merc_cmd(int argc, char **argv)
{
    char why[200]; char *e1, *e2;
    unsigned long long eng, arr; int now, want;
    g_dirty = 1;
    if (!MCC.avail) { MCC.refused++; log_line("MERCCUT refused: unavailable (%s)", MCC.why); return; }
    if (argc != 5) { MCC.refused++; log_line("MERCCUT refused: needs <engine> <array> <count now> <count wanted>"); return; }
    eng = _strtoui64(argv[1], &e1, 16); arr = _strtoui64(argv[2], &e2, 16);
    if (e1 == argv[1] || *e1 || e2 == argv[2] || *e2 || !parse_i32(argv[3], &now) || !parse_i32(argv[4], &want)) {
        MCC.refused++; log_line("MERCCUT refused: '%.40s %.40s %.12s %.12s' is not <hex> <hex> <n> <n>", argv[1], argv[2], argv[3], argv[4]); return;
    }
    if (!merc_check(eng, arr, now, want, why, sizeof(why))) { MCC.refused++; log_line("MERCCUT refused: %s", why); return; }
    __try { *(volatile int32_t *)((uint8_t *)(uintptr_t)eng + MC_LIST + 8) = (int32_t)want; MCC.cuts++; log_line("MERCCUT: the offer list %d -> %d", now, want); }
    __except (EXCEPTION_EXECUTE_HANDLER) { MCC.faults++; log_line("MERCCUT: exception %08lX", GetExceptionCode()); }
}
