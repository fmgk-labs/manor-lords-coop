/* ------------------------------------------------------------------ NODEATH (lane 64): nobody dies by a friend's own game
 * (research/2026-11-10-game-probe/lanes/lane_s21_64/report.txt). Included by coop_patch.c.
 *
 * Why (a live session of three PCs, 2026-11-17): a villager starved on two friends' copies and not on the host (each
 * copy rolls the death by itself: one in two on the family's day of the month, with its own dice). The mod repaired the
 * head count a day later; the body and the death notice stayed on the friends alone. In battles the same rule is P1
 * (NOKILL): a friend's copy kills nobody, deaths come on the host's word (the mod's Lua calls the game's own
 * SMUnit:just_die through the reflected function, which none of the sites below touches).
 *
 * READ: SMUnit::just_die (4e03010) is reached by ten direct calls and by the reflected thunk's jump (4afcc95):
 *   4dad116, 4dad193   CombatHit's kill path                    behind P1 (NOKILL)
 *   4d9026b            the daily hunger and cold step           site "hunger": its death roll is jumped over (the
 *                                                               roll, the notice death_hunger / death_cold and the kill)
 *   4db9d99            the work accident (4db9c80)              site "accident": the accident routine is not called
 *                                                               (no death, no injury, neither notice)
 *   4e1b5a5            fireDamage ("Died in a fire")            site "fire": the call is jumped over
 *   4d2f10b            a collapsing building ("crushed")        site "crush": nobody is found inside (no kill, no notice)
 *   4d63ce3            the animals' daily hunger step           site "animal": the call is jumped over (the notice
 *                                                               before it is the caller's and stays)
 * And one site that is no death but its end (game runs f1, c3: a friend buried its bodies up to a day before the host):
 *   4e0a081            a villager's "is there a body to bury"   site "bury": never; this copy starts no burial by
 *                                                               itself, a body goes when the host's goes (E PC)
 *   4da9907, 4e065d0   trade-route merchants taken out of the game by the game's own book-keeping: left alone
 *   4dc7c65            a charge's action 40 (a fight; purpose not read): left alone
 * No routine kills for illness or old age in this build (the family's sickness is a mark; Age is never a cause).
 *
 *   NODEATH ON | OFF     every available site on / all off (also at ALLOFF and when the DLL goes off)
 * Each site is one of the table's signatures (exactly one hit, the original bytes, the call's target, one aligned
 * 8-byte block: coop_scan.h eval_site, the same rule as P1); a site that does not hold is left out and named.
 * Status: "NODEATH on|off|part|unavailable hunger=<on|off|na> accident= fire= crush= animal= bury= refused=<n>"
 * ("on": all six; "part": some on, the others off or not available on this game build). */
#define ND_SITES 6
static const int   ND_SIG[ND_SITES]  = { S_NDHUNGER, S_NDACC, S_NDFIRE, S_NDCRUSH, S_NDANIMAL, S_NDBURY };
static const char *ND_NAME[ND_SITES] = { "hunger", "accident", "fire", "crush", "animal", "bury" };
static struct { int scanned; unsigned refused; } ND;

/* the state of a site is always the bytes in memory (as set_site does), never a cached flag */
static int nd_state(int k)
{
    site_eval *e = &g_site[ND_SIG[k]];
    uint8_t *addr;
    if (!ND.scanned || e->state == ST_UNAVAILABLE || !g_base || e->patch_rva == 0 || e->len == 0) return ST_UNAVAILABLE;
    addr = g_base + e->patch_rva;
    if (memcmp(addr, e->patched, (size_t)e->len) == 0) return ST_ON;
    if (memcmp(addr, e->orig, (size_t)e->len) == 0) return ST_OFF;
    return ST_UNAVAILABLE;
}

static int nodeath_status(char *buf, size_t len)
{
    int k, n, on = 0, off = 0, st[ND_SITES];
    if (g_off) return _snprintf(buf, len, "NODEATH unavailable dll is off\r\n");
    for (k = 0; k < ND_SITES; k++) { st[k] = nd_state(k); if (st[k] == ST_ON) on++; else if (st[k] == ST_OFF) off++; }
    /* "on" only when every site is on; "part" when some are on and others off or not available */
    n = _snprintf(buf, len, "NODEATH %s", on + off == 0 ? "unavailable" : on == 0 ? "off" : on == ND_SITES ? "on" : "part");
    for (k = 0; k < ND_SITES; k++)
        n += _snprintf(buf + n, len - (size_t)n, " %s=%s", ND_NAME[k], st[k] == ST_ON ? "on" : st[k] == ST_OFF ? "off" : "na");
    n += _snprintf(buf + n, len - (size_t)n, " refused=%u\r\n", ND.refused);
    return n < 0 ? 0 : n;
}

static int nodeath_scan(void)
{
    int k, any = 0;
    for (k = 0; k < ND_SITES; k++) {
        int s = ND_SIG[k];
        uint8_t *patch = g_hit[s].hits == 1 ? g_base + g_hit[s].rva + SIGS[s].patch_off : NULL;
        eval_site(&SIGS[s], &g_hit[s], g_hit, patch, (uint64_t)(uintptr_t)patch, &g_site[s]);
        log_line("  NODEATH %-8s %s %s", ND_NAME[k], state_word(g_site[s].state), g_site[s].state == ST_UNAVAILABLE ? g_site[s].why : "");
        if (g_site[s].state != ST_UNAVAILABLE) any = 1;
    }
    ND.scanned = 1; ND.refused = 0;
    return any;
}

/* every site that is on goes off (NODEATH OFF, ALLOFF, the DLL going off); each write in its own __try */
static void nodeath_off(const char *why)
{
    int k, was = 0;
    if (!ND.scanned) return;
    for (k = 0; k < ND_SITES; k++) {
        __try {
            if (nd_state(k) == ST_ON) { set_site(ND_SIG[k], 0); was = 1; }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            log_line("NODEATH %s restore raised exception %08lX", ND_NAME[k], GetExceptionCode());
        }
    }
    if (was) log_line("NODEATH off (%s)", why);
    g_dirty = 1;
}

static void nodeath_cmd(int argc, char **argv)
{
    int v, k, on = 0, na = 0;
    g_dirty = 1;
    if (argc != 2 || !on_off(argv[1], &v)) { ND.refused++; log_line("NODEATH refused: needs ON or OFF"); return; }
    if (!v) { nodeath_off("NODEATH OFF"); return; }
    for (k = 0; k < ND_SITES; k++) {
        int s = nd_state(k);
        if (s == ST_UNAVAILABLE) { na++; continue; }
        if (s == ST_OFF) set_site(ND_SIG[k], 1);
        if (nd_state(k) == ST_ON) on++;
    }
    if (on == 0) { ND.refused++; log_line("NODEATH ON refused: no site is available"); return; }
    log_line("NODEATH on: %d of %d sites%s", on, ND_SITES, na ? " (the others are not available on this game build)" : "");
}
