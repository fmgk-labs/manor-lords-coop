/* ------------------------------------------------------------------ FELL (lane 54): a tree being felled falls at the host's moment
 * (research/2026-11-10-game-probe/lanes/lane_s21_54/report.txt). Included by coop_patch.c.
 *
 * Why (READ in the game file): a felling does not end at a stroke count. The work-hit routine (4dc5270), felling
 * branch, finds the tree in a list of its target building's region (region +CD0h: records of 28h bytes, the count at
 * +CD8h; the lookup is 4c63c60, signature TREEFIND: a record's first three doubles are the tree's place, compared with
 * the task's place within 1 cm), takes 5.0 from the record's float at +18h at every stroke (4dc5a97, signature FELLHIT:
 * "movss xmm0,[rax+rdx*8+18h]; subss xmm0,5.0; movss [rax+rdx*8+18h],xmm0") and lets the tree fall only once that
 * float is no longer above 0 (4dc5c73 "comiss 0,[..+18h]; jb leave"). The record is made when a villager reaches the
 * tree. Each copy's villager reaches its tree at its own moment, so on a friend the tree is still standing when the
 * host's has fallen; the board's next task then ends the felling and the tree never falls there.
 *   FELL <region> <x> <y>     the record of the tree at that place (cm, within FELL_TOL on both axes) in that region's
 *                             list gets 0 at +18h when it is above 0: this copy's villager's next stroke fells it, by
 *                             the game's own code (the fall, the felled tree, the task's end). No record there (no
 *                             villager of this copy has reached the tree yet, or it has fallen): nothing is written.
 * The region address must look like an object of the game (committed, 8-aligned, its vtable in the module); the list
 * must be committed memory and hold at most FELL_MAXN records. Nothing is called, no code is patched: one float.
 * The offsets are the ones the two signatures hold (checked at the scan). Known build only.
 * Status: "FELL available fells= already= misses= bad= faults=" or "FELL unavailable <why>". */
#define FELL_LIST      0xCD0       /* region: the records' address; the count (int32) 8 bytes on (the game's array) */
#define FELL_REC       0x28
#define FELL_LEFT      0x18        /* record: what is left of the tree (float; 5.0 off at every stroke) */
#define FELL_MAXN      20000
#define FELL_TOL       1.5         /* cm: the board's line carries the place rounded to whole cm */
#define TF_COUNT_AT    7           /* TREEFIND: "movsxd rax,[rcx+CD8h]": its disp32 */
#define TF_LIST_AT     42          /* ... "mov rcx,[rcx+CD0h]" */
#define FH_LIST_AT     7           /* FELLHIT: "mov rax,[rax+CD0h]" */
#define FH_LEFT_AT     16          /* ... "movss xmm0,[rax+rdx*8+18h]": its disp8 */
#define FH_LEFT_AT2    30          /* ... "movss [rax+rdx*8+18h],xmm0" */
static struct { int avail; char why[160]; unsigned fells, already, misses, bad, faults; } FLL;

static int fell_status(char *buf, size_t len)
{
    if (g_off) return _snprintf(buf, len, "FELL unavailable dll is off\r\n");
    if (!FLL.avail) return _snprintf(buf, len, "FELL unavailable %s\r\n", FLL.why);
    return _snprintf(buf, len, "FELL available fells=%u already=%u misses=%u bad=%u faults=%u\r\n", FLL.fells, FLL.already, FLL.misses, FLL.bad, FLL.faults);
}

static int fell_scan(void)
{
    int known = g_stamp == KNOWN_TIMESTAMP && g_imgsize == KNOWN_IMAGESIZE;
    memset(&FLL, 0, sizeof(FLL));
    if (!known) _snprintf(FLL.why, sizeof(FLL.why), "another game build (timestamp %X)", g_stamp);
    else if (g_hit[S_TREEFIND].hits != 1) _snprintf(FLL.why, sizeof(FLL.why), "TREEFIND signature has %d hits (need exactly 1)", g_hit[S_TREEFIND].hits);
    else if (g_hit[S_FELLHIT].hits != 1) _snprintf(FLL.why, sizeof(FLL.why), "FELLHIT signature has %d hits (need exactly 1)", g_hit[S_FELLHIT].hits);
    else {
        const uint8_t *t = g_base + g_hit[S_TREEFIND].rva, *h = g_base + g_hit[S_FELLHIT].rva;
        uint32_t c, l, l2;
        memcpy(&c, t + TF_COUNT_AT, 4); memcpy(&l, t + TF_LIST_AT, 4); memcpy(&l2, h + FH_LIST_AT, 4);
        if (l != FELL_LIST || l2 != FELL_LIST || c != FELL_LIST + 8) _snprintf(FLL.why, sizeof(FLL.why), "the tree list is at +%X / +%X (count +%X), not +%X", l, l2, c, FELL_LIST);
        else if (h[FH_LEFT_AT] != FELL_LEFT || h[FH_LEFT_AT2] != FELL_LEFT) _snprintf(FLL.why, sizeof(FLL.why), "a stroke writes +%X, not +%X", h[FH_LEFT_AT2], FELL_LEFT);
        else FLL.avail = 1;
    }
    log_line("  FELL %s %s", FLL.avail ? "available" : "unavailable", FLL.avail ? "" : FLL.why);
    return FLL.avail;
}

static void fell_cmd(int argc, char **argv)
{
    char why[200]; char *e1, *e2, *e3;
    unsigned long long reg; double x, y;
    g_dirty = 1;
    if (!FLL.avail) { FLL.bad++; log_line("FELL refused: unavailable (%s)", FLL.why); return; }
    if (argc != 4) { FLL.bad++; log_line("FELL refused: needs <region> <x> <y>"); return; }
    reg = _strtoui64(argv[1], &e1, 16); x = strtod(argv[2], &e2); y = strtod(argv[3], &e3);
    if (e1 == argv[1] || *e1 || e2 == argv[2] || *e2 || e3 == argv[3] || *e3) { FLL.bad++; log_line("FELL refused: '%.40s %.20s %.20s' is not <hex address> <x> <y>", argv[1], argv[2], argv[3]); return; }
    if (!comp_sane(reg, FELL_LIST + 16, why, sizeof(why))) { FLL.bad++; log_line("FELL refused: %s", why); return; }
    __try {
        const uint8_t *r = (const uint8_t *)(uintptr_t)reg;
        uint8_t *a = *(uint8_t *volatile *)(r + FELL_LIST);
        int32_t n = *(volatile int32_t *)(r + FELL_LIST + 8), i;
        if (n == 0) { FLL.misses++; return; }
        if (n < 0 || n > FELL_MAXN || a == NULL || ((uintptr_t)a & 7) || !range_readable(a, (size_t)n * FELL_REC)) {
            FLL.bad++; log_line("FELL refused: the region's tree list does not look like one (%p, %d records)", (void *)a, (int)n); return;
        }
        for (i = 0; i < n; i++) {
            uint8_t *rec = a + (size_t)i * FELL_REC;
            double rx, ry; float left;
            memcpy(&rx, rec, 8); memcpy(&ry, rec + 8, 8);
            if (rx - x > FELL_TOL || x - rx > FELL_TOL || ry - y > FELL_TOL || y - ry > FELL_TOL) continue;
            memcpy(&left, rec + FELL_LEFT, 4);
            if (left > 0.0f) { *(volatile float *)(rec + FELL_LEFT) = 0.0f; FLL.fells++; } else FLL.already++;
            return;
        }
        FLL.misses++;
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { FLL.faults++; log_line("FELL: exception %08lX", GetExceptionCode()); }
}
