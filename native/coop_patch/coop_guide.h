/* ------------------------------------------------------------------ GUIDE (lane 49): which villager guides which ox
 * (research/2026-11-10-game-probe/lanes/lane_s21_49/report.txt, section 2). Included by coop_patch.c.
 *
 * Why (READ in the game file): the game links a guide to its ox in a field of the villager that is not reflected,
 * +330h. The game's guide assignment (4e15ab0, signature GUIDE: its first instructions up to "mov [villager+330h],ox")
 * writes it first, then gives the Follow. The Follow's own check (4dd72e0, from the Follow task 4db0d80) ends the Follow
 * at once when +330h is null, and the ox's think (4dd74c0) waits for the first unit of its region whose +330h is the ox.
 * On a friend the job board gives the host's Follow through the reflected setTask, which does not write +330h: when this
 * copy's own guide choice left another villager holding the ox (+330h), the ox waits for that one and the host's
 * leader's Follow ends at every give. The game itself clears every unit's +330h that names a unit being destroyed
 * (Engine::destroyUnit, 4cad613), so a value written here is never left pointing at a freed ox.
 *   GUIDE LIST <u>,<u>,...                writes guide.txt: "<u> <its +330h>" per unit, then END (read only)
 *   GUIDE SET <ox> <leader> [<u>,<u>,...] every listed unit other than the leader whose +330h is the ox gets 0, then the
 *                                         leader's +330h = the ox (what the game's guide assignment writes first)
 *   GUIDE CLEAR <gone>,... <u>,<u>,...    every listed unit whose +330h is one of the gone addresses gets 0
 * Every address must look like an object of the game (committed, 8-aligned, its vtable in the module). The offset is the
 * one the signature holds (checked at the scan). Known build only.
 * Status: "GUIDE available sets= taken= clears= cleared= lists= bad= faults=" or "GUIDE unavailable <why>". */
#define GUIDE_OFF      0x330
#define GUIDE_DISP_AT  64          /* the pattern's "cmp rbx,[rdi+330h]": its disp32 */
#define GUIDE_DISP_AT2 73          /* and "mov [rdi+330h],rbx" */
#define GUIDE_MAXU     512
static struct { int avail; char why[160]; unsigned sets, taken, clears, cleared, lists, bad, faults; } GDE;

static int guide_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "GUIDE unavailable dll is off\r\n");
    if (!GDE.avail) return _snprintf(buf, len, "GUIDE unavailable %s\r\n", GDE.why);
    return _snprintf(buf, len, "GUIDE available sets=%u taken=%u clears=%u cleared=%u lists=%u bad=%u faults=%u\r\n", GDE.sets, GDE.taken, GDE.clears, GDE.cleared, GDE.lists, GDE.bad, GDE.faults);
}

static int guide_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    memset(&GDE, 0, sizeof(GDE));
    if (!known) _snprintf(GDE.why, sizeof(GDE.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_GUIDE].hits != 1) _snprintf(GDE.why, sizeof(GDE.why), "GUIDE signature has %d hits (need exactly 1)", g_hit[S_GUIDE].hits);
    else {
        const uint8_t *p = g_base + g_hit[S_GUIDE].rva;
        uint32_t d1, d2;
        memcpy(&d1, p + GUIDE_DISP_AT, 4); memcpy(&d2, p + GUIDE_DISP_AT2, 4);
        if (d1 != GUIDE_OFF || d2 != GUIDE_OFF) _snprintf(GDE.why, sizeof(GDE.why), "the guide assignment writes +%X, not +%X", d2, GUIDE_OFF);
        else GDE.avail = 1;
    }
    log_line("  GUIDE %s %s", GDE.avail ? "available" : "unavailable", GDE.avail ? "" : GDE.why);
    return GDE.avail;
}

/* one address of a unit (hex, no 0x); 0 when refused */
static uint8_t *guide_obj(const char *s, const char **end)
{
    char *e; char why[200];
    unsigned long long a = _strtoui64(s, &e, 16);
    if (end) *end = e;
    if (e == s || (*e != ',' && *e != 0)) { GDE.bad++; log_line("GUIDE refused: '%.40s' is not a hex address", s); return NULL; }
    if (!comp_sane(a, GUIDE_OFF + 8, why, sizeof(why))) { GDE.bad++; log_line("GUIDE refused: %s", why); return NULL; }
    return (uint8_t *)(uintptr_t)a;
}
/* a comma list of unit addresses; returns the count or -1 */
static int guide_list(const char *s, uint8_t **out, int max)
{
    int n = 0;
    if (strcmp(s, "-") == 0) return 0;
    while (*s) {
        const char *e; uint8_t *u = guide_obj(s, &e);
        if (!u) return -1;
        if (n < max) out[n++] = u;
        s = *e ? e + 1 : e;
    }
    return n;
}

static void guide_cmd(int argc, char **argv)
{
    static uint8_t *us[GUIDE_MAXU];
    g_dirty = 1;
    if (!GDE.avail) { GDE.bad++; log_line("GUIDE refused: unavailable (%s)", GDE.why); return; }
    if (argc == 3 && _stricmp(argv[1], "LIST") == 0) {
        wchar_t path[MAX_PATH]; HANDLE h; DWORD wr; char line[64]; int k, n = guide_list(argv[2], us, GUIDE_MAXU);
        if (n < 0) return;
        join_path(path, g_dir, L"guide.txt");
        h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h == INVALID_HANDLE_VALUE) { GDE.faults++; log_line("GUIDE LIST: cannot write guide.txt (error %lu)", GetLastError()); return; }
        for (k = 0; k < n; k++) {
            uint64_t v = 0; int c;
            __try { memcpy(&v, us[k] + GUIDE_OFF, 8); } __except (EXCEPTION_EXECUTE_HANDLER) { GDE.faults++; v = 1; }
            c = _snprintf(line, sizeof(line), "%llX %llX\r\n", (unsigned long long)(uintptr_t)us[k], (unsigned long long)v);
            WriteFile(h, line, (DWORD)c, &wr, NULL);
        }
        WriteFile(h, "END\r\n", 5, &wr, NULL); CloseHandle(h);
        GDE.lists++;
        return;
    }
    if ((argc == 4 || argc == 5) && _stricmp(argv[1], "SET") == 0) {
        uint8_t *ox = guide_obj(argv[2], NULL), *ld = ox ? guide_obj(argv[3], NULL) : NULL;
        int k, n = 0;
        if (!ox || !ld) return;
        if (ox == ld) { GDE.bad++; log_line("GUIDE SET refused: the leader is the ox"); return; }
        if (argc == 5 && (n = guide_list(argv[4], us, GUIDE_MAXU)) < 0) return;
        __try {
            for (k = 0; k < n; k++) if (us[k] != ld && *(uint8_t *volatile *)(us[k] + GUIDE_OFF) == ox) { *(uint8_t *volatile *)(us[k] + GUIDE_OFF) = NULL; GDE.taken++; }
            *(uint8_t *volatile *)(ld + GUIDE_OFF) = ox;
        }
        __except (EXCEPTION_EXECUTE_HANDLER) { GDE.faults++; log_line("GUIDE SET: exception %08lX", GetExceptionCode()); return; }
        GDE.sets++;
        return;
    }
    if (argc == 4 && _stricmp(argv[1], "CLEAR") == 0) {
        static uint64_t gone[64];
        const char *s = argv[2]; int ng = 0, k, j, n;
        while (*s) {
            char *e; unsigned long long v = _strtoui64(s, &e, 16);
            if (e == s || v == 0 || (*e != ',' && *e != 0)) { GDE.bad++; log_line("GUIDE CLEAR refused: '%.40s' is not a list of hex addresses", s); return; }
            if (ng < 64) gone[ng++] = v;
            s = *e ? e + 1 : e;
        }
        if ((n = guide_list(argv[3], us, GUIDE_MAXU)) < 0) return;
        __try {
            for (k = 0; k < n; k++) { uint64_t v = *(volatile uint64_t *)(us[k] + GUIDE_OFF); for (j = 0; j < ng; j++) if (v && v == gone[j]) { *(volatile uint64_t *)(us[k] + GUIDE_OFF) = 0; GDE.cleared++; break; } }
        }
        __except (EXCEPTION_EXECUTE_HANDLER) { GDE.faults++; log_line("GUIDE CLEAR: exception %08lX", GetExceptionCode()); return; }
        GDE.clears++;
        return;
    }
    GDE.bad++; log_line("GUIDE refused: needs LIST <u>,... | SET <ox> <leader> [<u>,...] | CLEAR <gone>,... <u>,...");
}
