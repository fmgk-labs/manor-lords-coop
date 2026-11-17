/* patch_test.c - mechanism test for coop_patch.dll without the game.
 *
 * Builds synthetic "game modules" in memory: a PE header and a .text section (PAGE_EXECUTE_READ) holding small
 * hand-assembled functions that contain the exact byte patterns of coop_scan.h (P1, P2, P3a, P3b, TriggerSquadRetreat,
 * reformSquad entries). The functions really run, so a patch visibly changes what they do:
 *   combat(unit, args)  the P1 death check: returns 2 (kill path), 1 (health set to 1.0, the avoidKilling branch), 0 (alive)
 *   morale(comp, h)     the P2 site: calls the fake TriggerSquadRetreat unless jumped over
 *   p3a / p3b(comp, h)  the P3 sites: call the fake reformSquad unless jumped over
 * The fake entries keep the real prologue bytes (the signature), undo it, and jump to a C function that records its
 * arguments (or faults on handle 0xDEAD), so an exception unwinds through normal C frames.
 * The test build of the DLL (out\test\coop_patch.dll, /DCOOP_PATCH_TEST) is pointed at each synthetic module with
 * coop_patch_test_use_module() and driven only through patch_cmd.txt, exactly as the mod does.
 * Exit code 0 = every check passed.
 */
#define WIN32_LEAN_AND_MEAN
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>

typedef int  (__cdecl *tick_fn)(void *);
typedef void (__cdecl *use_fn)(void *);
typedef int  (*combat_fn)(void *unit, void *args);
typedef void (*squad_call)(void *comp, int h);

static tick_fn g_tick, g_snap, g_guard;   /* lane 47: g_snap = coop_snap_tick, g_guard = coop_guard_tick */
static use_fn  g_use;
static int g_pass, g_fail;
static wchar_t g_exedir[MAX_PATH], g_io[MAX_PATH], g_cmd[MAX_PATH], g_status[MAX_PATH], g_log[MAX_PATH];

/* ------------------------------------------------------------------ fake game functions (C side) */
static volatile LONG g_tsr_calls, g_reform_calls;
static void *volatile g_tsr_comp, *volatile g_reform_comp;
static volatile int g_tsr_h, g_reform_h;
static volatile int *volatile g_nullp;          /* stays NULL: writing through it faults */

__declspec(noinline) static void fake_tsr_impl(void *comp, int h)
{
    InterlockedIncrement(&g_tsr_calls); g_tsr_comp = comp; g_tsr_h = h;
    if (h == 0xDEAD) *g_nullp = 1;               /* access violation inside the "game" function */
}
static volatile LONG g_finish_calls;
static void *volatile g_finish_b;
static void (*volatile g_finish_then)(void *b);     /* when set: what the "game's" finishConstruction does to stock */
__declspec(noinline) static void fake_finish_impl(void *b)
{
    InterlockedIncrement(&g_finish_calls); g_finish_b = b;
    if (g_finish_then) g_finish_then(b);
    if (*(volatile uint32_t *)((uint8_t *)b + 8) == 0xDEAD) *g_nullp = 1;     /* a "building" marked to fault */
}
static volatile LONG g_burn_calls, g_fireout_calls;
static void *volatile g_burn_b, *volatile g_fireout_b;
static volatile float g_burn_dt;
__declspec(noinline) static void fake_burn_impl(void *b, float dt) { InterlockedIncrement(&g_burn_calls); g_burn_b = b; g_burn_dt = dt; }
__declspec(noinline) static void fake_fireout_impl(void *b) { InterlockedIncrement(&g_fireout_calls); g_fireout_b = b; }
__declspec(noinline) static void fake_reform_impl(void *comp, int h)
{
    InterlockedIncrement(&g_reform_calls); g_reform_comp = comp; g_reform_h = h;
    if (h == 0xDEAD) *g_nullp = 1;
}

/* GOODS: the game's add helper, recountStorage and the region's refresh, as C recorders. The synthetic module holds
 * the real entry bytes of recountStorage, refreshBuildingStorageCache and addToInventory (the signatures); the first
 * two undo their prologue and jump here, addToInventory runs whole and calls all three. */
#define INV_CAP 32
typedef struct { int32_t type, amt; void *p1, *p2; } fgood_t;
typedef struct { fgood_t *data; int32_t num, max; } garr_t;
typedef void (*recount_call)(void *b, int dl, int flag, void *arg);
typedef void (*refresh_call)(void *region, void *b, int mode, void *delta, int last);
typedef void (*addinv_call)(void *b, fgood_t *g);
static volatile LONG g_add_calls, g_rc_calls, g_rf_calls;
static void *volatile g_rc_b, *volatile g_rf_region, *volatile g_rf_b, *volatile g_rf_delta;
static volatile int g_rc_dl, g_rc_flag, g_rc_amt17, g_rf_mode;
static volatile double g_rc_k;
static int stock(uint8_t *b, int type)
{
    garr_t *a = (garr_t *)(b + 0x448); int i, n = 0;
    for (i = 0; i < a->num; i++) if (a->data[i].type == type) n += a->data[i].amt;
    return n;
}
__declspec(noinline) static void fake_add_impl(garr_t *a, int type, int amt, char prune)
{
    int i;
    InterlockedIncrement(&g_add_calls);
    if (amt == 0) return;
    for (i = 0; i < a->num; i++) if (a->data[i].type == type) break;
    if (i < a->num) a->data[i].amt += amt;
    else if (!(prune && amt <= 0)) {
        if (a->num >= a->max) a->max = INV_CAP;             /* "the list grows" */
        a->data[a->num].type = type; a->data[a->num].amt = amt; a->data[a->num].p1 = a->data[a->num].p2 = NULL; a->num++;
    }
    if (prune) for (i = 0; i < a->num; ) {
        if (a->data[i].amt <= 0) { memmove(&a->data[i], &a->data[i + 1], (size_t)(a->num - i - 1) * sizeof(fgood_t)); a->num--; } else i++;
    }
}
__declspec(noinline) static void fake_recount_impl(uint8_t *b, int dl, int flag, void *arg)
{
    InterlockedIncrement(&g_rc_calls); g_rc_b = b; g_rc_dl = dl & 0xFF; g_rc_flag = flag & 0xFF;
    g_rc_amt17 = stock(b, 17);
    g_rc_k = arg ? ((double *)arg)[2] : -1.0;
}
__declspec(noinline) static void fake_refresh_impl(void *region, uint8_t *b, int mode, void *delta)
{
    InterlockedIncrement(&g_rf_calls); g_rf_region = region; g_rf_b = b; g_rf_mode = mode; g_rf_delta = delta;
}

/* TOTALS (lane 22): the game's "add a list of goods to a list" (4b73d00) as C, the same rules: an amount is added to
 * the record of its kind or appended; with removeEmpty records at or below nothing go. And NOTIFY as a recorder. */
#define TOT_CAP 64
static volatile LONG g_al_calls, g_nt_calls;
static void *volatile g_nt_region; static volatile int g_nt_n, g_nt_type0, g_nt_amt0;
__declspec(noinline) static void fake_addlist_impl(garr_t *list, const garr_t *src, char negate, char removeEmpty)
{
    int i, j;
    InterlockedIncrement(&g_al_calls);
    if (src->data == (fgood_t *)(uintptr_t)0x10) return;            /* the fault test's list: the hook faulted on it */
    for (i = 0; i < src->num; i++) {
        int32_t d = negate ? -src->data[i].amt : src->data[i].amt;
        if (!d) continue;
        for (j = 0; j < list->num; j++) if (list->data[j].type == src->data[i].type) break;
        if (j < list->num) list->data[j].amt += d;
        else if (list->num < TOT_CAP) { list->data[j].type = src->data[i].type; list->data[j].amt = d; list->data[j].p1 = list->data[j].p2 = NULL; list->num++; if (list->max < list->num) list->max = TOT_CAP; }
    }
    if (removeEmpty) for (j = 0; j < list->num; ) {
        if (list->data[j].amt <= 0) { memmove(&list->data[j], &list->data[j + 1], (size_t)(list->num - j - 1) * sizeof(fgood_t)); list->num--; } else j++;
    }
}
__declspec(noinline) static void fake_notify_impl(void *region, const garr_t *src)
{
    InterlockedIncrement(&g_nt_calls); g_nt_region = region; g_nt_n = src->num;
    g_nt_type0 = src->num ? src->data[0].type : -1; g_nt_amt0 = src->num ? src->data[0].amt : 0;
}

/* HOLD (lane 31): the region routines the DLL holds, as C recorders that do what the game's do to the fields the
 * test reads. updateApproval writes Approval 55 and two rows; the list grow helper reallocates; add / remove a problem
 * keep Region.problems (+D80h) as the game does (one entry per type, building, unit). */
typedef struct { int32_t type, day, exp, count; uint8_t past, pad[3]; float effect; } amem_t;
typedef struct { amem_t *data; int32_t num, max; } aarr_t;
typedef struct { uint8_t type, pad[7]; void *unit; void *building; double loc[3]; int32_t day, expires; } prob_t;
typedef struct { prob_t *data; int32_t num, max; } parr_t;
static volatile LONG g_appr_calls, g_order_calls, g_suppl_calls, g_grow_calls, g_padd_calls, g_prem_calls, g_premall_calls;
__declspec(noinline) static void fake_appr_impl(uint8_t *r)
{
    aarr_t *a = (aarr_t *)(r + 0x1038);
    InterlockedIncrement(&g_appr_calls);
    *(int32_t *)(r + 0x1030) = 55;
    if (a->max >= 2) { memset(a->data, 0, 2 * sizeof(amem_t)); a->data[0].type = 12; a->data[0].effect = 8.0f; a->data[1].type = 2; a->data[1].effect = -1.0f; a->num = 2; }
}
__declspec(noinline) static void fake_order_impl(uint8_t *r) { InterlockedIncrement(&g_order_calls); *(int32_t *)(r + 0x104C) = 70; }
__declspec(noinline) static void fake_suppl_impl(uint8_t *r) { InterlockedIncrement(&g_suppl_calls); *(float *)(r + 0x59C) = 2.0f; *(float *)(r + 0x5A0) = 9.0f; }
__declspec(noinline) static void fake_grow_impl(aarr_t *a, int old)
{
    amem_t *d;
    InterlockedIncrement(&g_grow_calls);
    d = (amem_t *)calloc((size_t)a->num + 4, sizeof(amem_t));
    if (old > 0 && a->data) memcpy(d, a->data, (size_t)old * sizeof(amem_t));
    a->data = d; a->max = a->num + 4;
}
__declspec(noinline) static char fake_padd_impl(uint8_t *r, int type, void *b, void *u)
{
    parr_t *p = (parr_t *)(r + 0xD80); int i;
    InterlockedIncrement(&g_padd_calls);
    if (p->data == (prob_t *)(uintptr_t)0x10) return 0;                /* the fault test's list: the hook faulted on it */
    for (i = 0; i < p->num; i++) if (p->data[i].type == (uint8_t)type && p->data[i].building == b && p->data[i].unit == u) return 1;
    if (p->num >= p->max) return 0;
    memset(&p->data[p->num], 0, sizeof(prob_t)); p->data[p->num].type = (uint8_t)type; p->data[p->num].building = b; p->data[p->num].unit = u; p->num++;
    return 0;
}
__declspec(noinline) static void fake_premall_impl(uint8_t *r, int type)
{
    parr_t *p = (parr_t *)(r + 0xD80); int i;
    InterlockedIncrement(&g_premall_calls);
    for (i = 0; i < p->num; ) { if (p->data[i].type == (uint8_t)type) { memmove(&p->data[i], &p->data[i + 1], (size_t)(p->num - i - 1) * sizeof(prob_t)); p->num--; } else i++; }
}
/* lane 36: the daily emigration: a family leaves (the region's family count at +4F0h goes down by one) */
static volatile LONG g_emig_calls, g_house_calls;
__declspec(noinline) static void fake_house_impl(uint8_t *r, void *ignore) { (void)ignore; InterlockedIncrement(&g_house_calls); *(int32_t *)(r + 0x10F4) = 0; }   /* nobody homeless */
__declspec(noinline) static void fake_emig_impl(uint8_t *r) { InterlockedIncrement(&g_emig_calls); if (*(int32_t *)(r + 0x4F0) > 0) (*(int32_t *)(r + 0x4F0))--; }
__declspec(noinline) static void fake_prem_impl(uint8_t *r, int type, void *b, void *u)
{
    parr_t *p = (parr_t *)(r + 0xD80); int i;
    InterlockedIncrement(&g_prem_calls);
    for (i = 0; i < p->num; i++) if (p->data[i].type == (uint8_t)type && p->data[i].building == b && p->data[i].unit == u) {
        memmove(&p->data[i], &p->data[i + 1], (size_t)(p->num - i - 1) * sizeof(prob_t)); p->num--; return; }
}

/* ------------------------------------------------------------------ checks */
static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("  %s  ", ok ? "PASS" : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    if (ok) g_pass++; else g_fail++;
}

/* ------------------------------------------------------------------ synthetic module */
#define IMG_SIZE  0x20000
#define TEXT_RVA  0x1000
#define TEXT_SIZE 0xE000            /* lane 31: was 0x8000; the HOLD routines' bodies need room (still below .data) */
#define DATA_RVA  0x10000

typedef struct {
    uint8_t *base, *text;
    size_t pos;
    size_t finish, tsr, reform, stub, combat, combat2, morale, p3a, p3b;     /* offsets in .text */
    size_t nf1_patch, nf2_patch;                                             /* the two NOFINISH jumps */
    size_t jg_patch;                                                         /* lane 19: the JOBGATE je */
    size_t p1_patch, p1_patch2, p2_patch, p3a_patch, p3b_patch;
    size_t helper, recount, refresh, addinv, konst;                          /* GOODS */
    size_t addlist, notify;                                                  /* TOTALS */
    size_t l28_movesel;                                                      /* lane 28: MoveSelected's entry */
    size_t happr, horder, hsuppl, hwadd, hwsub, hpadd, hprem, hgrow, hwmon, hprmall;  /* HOLD (lane 31); hwmon: a function holding the site */
    size_t hemig, hhouse;                                                   /* lane 36: HOLD's emigration and housing gates */
    uint8_t snapshot[TEXT_SIZE];
    size_t chooser, choose_site;                                            /* lane 23: CHOOSE (the function, its hooked bytes) */
    size_t noregion, noregion2, nr_gw, nr_mg;                                           /* the lead: NOREGION (the two routines' entries) */
    size_t pk_settask, pk_chooser, pk_think, pk_call;                       /* lane 35: PICK (setTask, the chooser, the think, its call) */
    size_t fl_cache, fl_draw, fl_paint, fl_upd;                                     /* lane 40: FIELD (UpdateFieldCache, a plant's drawing, the brush) */
    size_t dist, dist_mk, dist_call, dist_grow, dist_surp;                  /* lane 42: DIST (distribution, market routine, its call's E8, grow, surplus) */
    size_t rs_site;                                                         /* lane 35, round six: the REGSETS pattern */
    size_t mv_entry, mv_site;                                               /* lane 43: MEN (the path request, tickSquad's call of it) */
    size_t pc_entry, pc_find, pc_find2;                                     /* lane 52: PACE (the squad's pace rule, the squad lookup, a second lookup) */
    size_t st_thunk;                                                        /* lane 35, round seven: a "reflected setTask" that calls setTask through SETTHUNK's call */
    size_t dem;                                                             /* lane 46: a "demolish" holding the DEMREF site */
    size_t guide;                                                           /* lane 49: a "guide assignment" holding the GUIDE pattern */
    size_t fell;                                                            /* lane 54: a "tree lookup" and a "felling stroke" holding FELL's two patterns */
    size_t eh_end, eh_in, eh_out;                                           /* lane 49, round four: an end-task, a caller in the task steps, one outside */
} img_t;

typedef struct {
    int p1_count;           /* 0 = no P1, 1 = normal, 2 = duplicate */
    int p1_misalign, p1_wrong, p1_prepatched;
    int p2_prepatched, p2_wrongtarget;
    int no_tsr, empty;
    int goods;              /* 0 = none of the GOODS routines, 1 = all three, 2 = addToInventory's first call goes elsewhere */
    int totals;             /* lane 22: 0 = none of the TOTALS routines, 1 = ADDLIST, NOTIFY and the six sites, 2 = TS3's call goes elsewhere */
    int cursor;             /* lane 26: 0 = no CURSOR site, 1 = one, 2 = two */
    int known;              /* lane 26: 1 = the header says the known game build (timestamp and size) */
    int l28;                /* lane 28: 0 = none of its five routines, 1 = all five, 2 = MoveSelected twice */
    int choose;             /* lane 23: 0 = no chooser site, 1 = one, 2 = two, 3 = one whose hooked bytes differ */
    int hold;               /* lane 31: 0 = none of the HOLD routines, 1 = all, 2 = updateApproval's grow call goes elsewhere */
    int noregion;           /* the lead: 0 = neither NOREGION routine, 1 = both, 2 = the first one twice, 3 = the first one's call leaves the image, 4 = only the first */
    int pick;               /* lane 35: 0 = none, 1 = setTask, chooser and think, 2 = the think's call goes elsewhere, 3 = setTask starts otherwise */
    int field;              /* lane 40: 0 = none of the FIELD routines, 1 = all three, 2 = all three twice */
    int dist;               /* lane 42: 0 = none, 1 = the distribution, its call, the grow call and the surplus cache, 2 = the call goes elsewhere, 3 = the grow helper starts otherwise */
    int regset;             /* lane 35, round six: 0 = no REGSETS site, 1 = one, 2 = its two calls reach different routines */
    int men;                /* lane 43: 0 = no MEN routine, 1 = the path request and tickSquad's call, 2 = the path request twice, 3 = the call reaches another routine */
    int setthunk;           /* lane 35, round seven: 0 = no SETTHUNK site, 1 = one (its call reaches the test's setTask) */
    int demref;             /* lane 46: 0 = no DEMREF site, 1 = one (a "demolish" whose call reaches REFRESH), 2 = its call goes elsewhere */
    int guide;              /* lane 49: 0 = no GUIDE pattern, 1 = one, 2 = two, 3 = one whose write is at another offset */
    int pace;               /* lane 52 (last: some tests fill this record by position): 0 = no pace rule, 1 = one (both calls reach the lookup), 2 = its second call reaches another routine */
    int fell;               /* lane 54: 0 = neither FELL pattern, 1 = both, 2 = the lookup twice, 3 = a stroke that writes +1Ch, 4 = only the lookup */
    int endtask;            /* lane 49, round four: 0 = no ENDTASK, 1 = one (and two callers) */
} opts_t;

static void emit_hex(img_t *m, const char *s)
{
    while (*s) {
        unsigned v;
        if (*s == ' ') { s++; continue; }
        sscanf(s, "%2x", &v);
        m->text[m->pos++] = (uint8_t)v;
        s += 2;
    }
}
static void emit_u8(img_t *m, uint8_t v) { m->text[m->pos++] = v; }
static void emit_imm64(img_t *m, uint64_t v) { memcpy(m->text + m->pos, &v, 8); m->pos += 8; }
static size_t emit_rel_hole(img_t *m) { size_t at = m->pos; m->pos += 4; return at; }
static void fix_rel(img_t *m, size_t at, size_t target)
{
    int32_t r = (int32_t)((int64_t)target - (int64_t)(at + 4));
    memcpy(m->text + at, &r, 4);
}
static void align_to(img_t *m, int mod, int rem) { while ((TEXT_RVA + m->pos) % (size_t)mod != (size_t)rem) emit_u8(m, 0xCC); }

static void emit_stub(img_t *m) { align_to(m, 16, 0); m->stub = m->pos; emit_u8(m, 0xC3); }

static void emit_tsr(img_t *m)
{
    align_to(m, 16, 0); m->tsr = m->pos;
    emit_hex(m, "48 89 4C 24 08 55 53 57 41 54 48 8D 6C 24 E8 48 81 EC 18 01 00 00");    /* TSR signature = real prologue */
    emit_hex(m, "48 81 C4 18 01 00 00 41 5C 5F 5B 5D 48 B8");                          /* undo it; mov rax, imm64 */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_tsr_impl);
    emit_hex(m, "FF E0");                                                              /* jmp rax */
}

static void emit_reform(img_t *m)
{
    size_t h;
    align_to(m, 16, 0); m->reform = m->pos;
    emit_hex(m, "40 53 55 41 57 48 81 EC C0 00 00 00 8B DA 4C 8B F9 E8");              /* reformSquad signature */
    h = emit_rel_hole(m); fix_rel(m, h, m->stub);
    emit_hex(m, "49 8B CF 8B D3 48 81 C4 C0 00 00 00 41 5F 5D 5B 48 B8");             /* args back, undo prologue */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_reform_impl);
    emit_hex(m, "FF E0");
}

/* finishConstruction's real prologue (the FINISH signature), undone, then a jump to the C recorder */
static void emit_finish(img_t *m)
{
    align_to(m, 16, 0); m->finish = m->pos;
    emit_hex(m, "48 8B C4 48 89 58 10 48 89 70 18 48 89 78 20 55 41 54 41 55 41 56 41 57 48 8D A8 08 FE FF FF 48 81 EC D0 02 00 00 44 0F 29 48 98");
    emit_hex(m, "48 81 C4 D0 02 00 00 41 5F 41 5E 41 5D 41 5C 5D 48 B8");    /* add rsp; pop r15 r14 r13 r12 rbp */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_finish_impl);
    emit_hex(m, "FF E0");
}

/* progressFire's real prologue (the BURN signature; its movss reads the 4 bytes after itself), undone, then a jump to
 * the C recorder. rcx and xmm1 are untouched by the prologue. */
static void emit_burn(img_t *m)
{
    align_to(m, 16, 0);
    emit_hex(m, "48 8B C4 48 89 58 20 55 56 57 41 56 41 57 48 8D 68 B8 48 81 EC 20 01 00 00 F3 0F 10 05 00 00 00 00");
    emit_hex(m, "48 81 C4 20 01 00 00 41 5F 41 5E 5F 5E 5D 48 8B 5C 24 20 48 B8");   /* add rsp; pop r15 r14 rdi rsi rbp; mov rbx,[rsp+20h] */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_burn_impl);
    emit_hex(m, "FF E0");
}
/* extinguishFire's real prologue (the FIREOUT signature; it reads [rcx+398h]), undone, then a jump to the C recorder */
static void emit_fireout(img_t *m)
{
    align_to(m, 16, 0);
    emit_hex(m, "48 89 5C 24 18 56 48 81 EC B0 00 00 00 48 8B D9 33 F6 48 8B 89 98 03 00 00");
    emit_hex(m, "48 8B CB 48 81 C4 B0 00 00 00 5E 48 8B 5C 24 18 48 B8");             /* mov rcx,rbx; add rsp; pop rsi; mov rbx,[rsp+18h] */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_fireout_impl);
    emit_hex(m, "FF E0");
}

/* The two NOFINISH sites: the exact byte patterns around the game's own calls to finishConstruction. Never run here;
 * each je sits inside one aligned 8-byte block, as in the game (4dc57d8 and 4cbdb19). */
static void emit_nofinish(img_t *m)
{
    align_to(m, 8, 3);
    emit_hex(m, "4C 8D 45 00 48 89 75 00 48 8B D7 48 89 75 08 49 8D 8F 48 04 00 00 E8 00 00 00 00 84 C0");
    m->nf1_patch = m->pos;
    emit_hex(m, "74 08 49 8B CF E8 00 00 00 00 49 8B CE E8 00 00 00 00 CC CC");
    align_to(m, 8, 3);
    emit_hex(m, "48 8B CB 4E 89 2C F0 E8 00 00 00 00 84 C0");
    m->nf2_patch = m->pos;
    emit_hex(m, "74 50 48 8B CB E8 00 00 00 00 EB 46 CC CC");
    /* lane 19: the JOBGATE site (executeTask's test of the job list), je at %8 == 3 as in the game (4df9a03) */
    align_to(m, 8, 6);
    emit_hex(m, "48 8B CF E8 00 00 00 00 48 8B 93 A8 10 00 00 48 63 8B B0 10 00 00 4C 8D 04 8A 49 3B D0");
    m->jg_patch = m->pos;
    emit_hex(m, "74 11 39 02 0F 84 00 00 00 00 CC CC");
}

/* combat(unit rcx, args rdx): rsi = unit (health at +0x2E8), rbp = args (avoidKilling byte at +0x448), xmm15 = 0 */
static size_t emit_combat(img_t *m, int misalign, int wrong, int prepatched, size_t *patch_at)
{
    size_t f, p, jb, av, k1, a1, kill, avoid, alive, epi;
    align_to(m, 8, misalign ? 5 : 2);          /* patch at f+42: %8 == 4 (like the game) or 7 (crosses a block) */
    f = m->pos;
    emit_hex(m, "56 55 48 83 EC 18 44 0F 11 3C 24 48 8B F1 48 8B EA 45 0F 57 FF");
    p = m->pos;
    emit_hex(m, "44 0F 2F BE E8 02 00 00 0F 82"); jb = emit_rel_hole(m);                /* comiss xmm15,[rsi+2E8]; jb alive */
    emit_hex(m, "80 BD 48 04 00 00 00");                                               /* cmp byte [rbp+448],0 */
    *patch_at = m->pos;
    emit_hex(m, prepatched ? "66 90" : wrong ? "74 1D" : "74 1C");                     /* je kill */
    emit_hex(m, "C7 86 E8 02 00 00 00 00 80 3F E9"); av = emit_rel_hole(m);            /* health = 1.0; jmp avoid */
    while (m->pos < p + 51) emit_u8(m, 0xCC);
    kill = m->pos;  emit_hex(m, "B8 02 00 00 00 E9"); k1 = emit_rel_hole(m);
    avoid = m->pos; emit_hex(m, "B8 01 00 00 00 E9"); a1 = emit_rel_hole(m);
    alive = m->pos; emit_hex(m, "31 C0");
    epi = m->pos;   emit_hex(m, "44 0F 10 3C 24 48 83 C4 18 5D 5E C3");
    fix_rel(m, jb, alive); fix_rel(m, av, avoid); fix_rel(m, k1, epi); fix_rel(m, a1, epi);
    (void)kill;
    return f;
}

/* morale(comp rcx, h edx): the P2 loop with an empty list, then "mov edx,edi; mov rcx,r15; call TSR; jmp end" */
static void emit_morale(img_t *m, int prepatched, int wrongtarget, int no_tsr)
{
    size_t jn, c, j, end;
    align_to(m, 8, 0);                         /* patch at f+54: %8 == 6, like the game */
    m->morale = m->pos;
    emit_hex(m, "57 41 57 48 83 EC 28 48 8B FA 4C 8B F9 48 8B D1");
    emit_hex(m, "48 3B CA 74 1C 0F 1F 00 48 8B 01 80 B8 6C 0B 00 00 00 0F 85"); jn = emit_rel_hole(m);
    emit_hex(m, "48 83 C1 08 48 3B CA 75 E7 8B D7 49 8B CF");
    m->p2_patch = m->pos;
    if (prepatched) {
        int32_t r = (int32_t)((int64_t)m->tsr - (int64_t)(m->p2_patch + 5));
        uint8_t b[4]; memcpy(b, &r, 4);
        emit_hex(m, "EB 03"); emit_u8(m, b[1]); emit_u8(m, b[2]); emit_u8(m, b[3]);
    } else {
        emit_u8(m, 0xE8); c = emit_rel_hole(m);
        fix_rel(m, c, (wrongtarget || no_tsr) ? m->stub : m->tsr);
    }
    emit_u8(m, 0xE9); j = emit_rel_hole(m);
    end = m->pos; emit_hex(m, "48 83 C4 28 41 5F 5F C3");
    fix_rel(m, jn, end); fix_rel(m, j, end);
}

static void emit_p3a(img_t *m)
{
    size_t c, j, end;
    align_to(m, 8, 7);                         /* patch at f+18: %8 == 1, like the game */
    m->p3a = m->pos;
    emit_hex(m, "57 41 57 48 83 EC 28 48 8B FA 4C 8B F9");
    emit_hex(m, "8B D7 49 8B CF");
    m->p3a_patch = m->pos;
    emit_u8(m, 0xE8); c = emit_rel_hole(m); fix_rel(m, c, m->reform);
    emit_u8(m, 0xE9); j = emit_rel_hole(m);
    emit_hex(m, "49 8B 7E 18");
    end = m->pos; emit_hex(m, "48 83 C4 28 41 5F 5F C3");
    fix_rel(m, j, end);
}

static void emit_p3b(img_t *m)
{
    size_t jb, c, end;
    align_to(m, 8, 5);                         /* patch at f+25: %8 == 6, like the game */
    m->p3b = m->pos;
    emit_hex(m, "53 57 48 83 EC 28 48 8B F9 8B DA 48 85 C9");
    emit_hex(m, "0F 86"); jb = emit_rel_hole(m);
    emit_hex(m, "8B D3 48 8B CF");
    m->p3b_patch = m->pos;
    emit_u8(m, 0xE8); c = emit_rel_hole(m); fix_rel(m, c, m->reform);
    end = m->pos; emit_hex(m, "48 83 C4 28 5F 5B C3");
    fix_rel(m, jb, end);
}

/* GOODS: the add helper (a jump to C), recountStorage and refreshBuildingStorageCache with their real entry bytes
 * (they run; then the prologue is undone and C records the call), and addToInventory whole, as in the game. */
static void emit_goods(img_t *m, int wrong_target)
{
    size_t h1, h2, h3, h4;
    align_to(m, 16, 0); m->helper = m->pos;
    emit_hex(m, "48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_add_impl); emit_hex(m, "FF E0");
    align_to(m, 16, 0); m->recount = m->pos;
    emit_hex(m, "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 41 56 41 57 48 83 EC 20 33 C0 48 8B D9 48 89 81 70 04 00 00 4D 8B F9 89 81 78 04 00 00 45 0F B6 F0 48 8B B9 48 04 00 00 0F B6 EA 48 63 81 50 04 00 00 48 8D 0C 40 48 8D 34 CF");
    emit_hex(m, "48 8B CB 48 83 C4 20 41 5F 41 5E 5F 48 8B 74 24 18 48 8B 6C 24 10 48 8B 5C 24 08 48 B8");   /* rcx back from rbx; add rsp; pop r15 r14 rdi; rsi rbp rbx back */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_recount_impl); emit_hex(m, "FF E0");
    align_to(m, 16, 0); m->refresh = m->pos;
    emit_hex(m, "48 89 5C 24 18 48 89 4C 24 08 55 56 57 41 54 41 55 41 56 41 57 48 8B EC 48 81 EC 80 00 00 00 49 8B F1 45 8B F0 4C 8B FA 4C 8B E1 48 85 D2 74 03 8B 42 08 48 8B 99 E0 01 00 00");
    emit_hex(m, "48 81 C4 80 00 00 00 41 5F 41 5E 41 5D 41 5C 5F 5E 5D 48 8B 5C 24 18 48 B8");       /* add rsp; pop r15..rbp; rbx back */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_refresh_impl); emit_hex(m, "FF E0");
    align_to(m, 16, 0); m->addinv = m->pos;
    emit_hex(m, "40 53 48 83 EC 50 44 8B 42 04 48 8B D9 8B 12 45 8B C8 41 C1 E9 1F 48 81 C1 48 04 00 00 E8"); h1 = emit_rel_hole(m);
    emit_hex(m, "F2 0F 10 0D"); h2 = emit_rel_hole(m);
    emit_hex(m, "4C 8D 4C 24 30 0F 57 C0 F2 0F 11 4C 24 40 41 B0 01 0F 29 44 24 30 33 D2 48 8B CB E8"); h3 = emit_rel_hole(m);
    emit_hex(m, "48 8B 8B C8 02 00 00 48 85 C9 74 13 45 33 C9 C6 44 24 20 00 45 33 C0 48 8B D3 E8"); h4 = emit_rel_hole(m);
    emit_hex(m, "48 83 C4 50 5B C3");
    align_to(m, 8, 0); m->konst = m->pos;
    {   double k = 1234.5; memcpy(m->text + m->pos, &k, 8); m->pos += 8; }
    fix_rel(m, h1, m->helper); fix_rel(m, h2, m->konst);
    fix_rel(m, h3, wrong_target ? m->stub : m->recount); fix_rel(m, h4, m->refresh);
}

/* TOTALS (lane 22): ADDLIST and NOTIFY with their real entry bytes (they run; then the prologue is undone and C does
 * the work / records the call), and the six call sites of the totals, exact byte patterns, never run. */
static void emit_totals(img_t *m, int wrong_ts3)
{
    static const char *const site_before[6] = {
        "48 8D 8B 28 05 00 00", "49 8D 8C 24 28 05 00 00 45 33 C0 48 8B D6", "49 8D 8C 24 28 05 00 00",
        "49 8D 8F 28 05 00 00 41 B1 01 45 33 C0 49 8B D6", "49 8D 8F 28 05 00 00 41 B1 01 45 33 C0 48 8D 55 8F",
        "48 8D 8D 28 05 00 00 45 0F B6 C1 48 8B D3" };
    static const char *const site_after[6] = {
        "48 8D 8B 38 05 00 00", "48 8B D6 49 8B CC E8 00 00 00 00", "48 8D 55 E0 49 8B CC E8 00 00 00 00",
        "41 B1 01", "48 8D 55 8F", "48 8D 53 10" };
    int i;
    size_t h;
    align_to(m, 16, 0); m->addlist = m->pos;
    emit_hex(m, "44 88 4C 24 20 53 56 57 48 83 EC 30 48 8B 32 48 8B F9 48 63 42 08 41 BB 01 00 00 00");
    emit_hex(m, "48 83 C4 30 5F 5E 5B 48 B8");                                  /* add rsp,30h; pop rdi rsi rbx */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_addlist_impl); emit_hex(m, "FF E0");
    align_to(m, 16, 0); m->notify = m->pos;
    emit_hex(m, "48 89 7C 24 18 41 56 48 83 EC 20 48 8B 81 18 03 00 00 48 8B F9 4C 8B F2 48 8B 88 B0 05 00 00 48 85 C9");
    emit_hex(m, "48 8B CF 49 8B D6 48 83 C4 20 41 5E 48 8B 7C 24 18 48 B8");    /* rcx, rdx back; add rsp; pop r14; rdi back */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_notify_impl); emit_hex(m, "FF E0");
    for (i = 0; i < 6; i++) {
        emit_hex(m, "CC CC");
        emit_hex(m, site_before[i]); emit_u8(m, 0xE8); h = emit_rel_hole(m);
        fix_rel(m, h, (wrong_ts3 && i == 2) ? m->stub : m->addlist);
        emit_hex(m, site_after[i]);
    }
}

/* HOLD (lane 31): the seven region routines with their real entry bytes (the signatures). updateApproval, the public
 * order and the months undo their prologue and jump to C, with the bytes the DLL checks in their bodies at the real
 * offsets (never run); addRegionalWealth is the game's whole routine; consumeRegionalWealth runs its real head and a
 * short tail with the game's rule (wealth -= amount; below nothing: 0 and false); add / remove a problem undo their
 * prologue and jump to C. The list grow helper has its real first bytes, then C. The monthly store site sits in a small
 * function wmon(region, amount) that keeps a value in xmm4 across the site and stores it at region+10F0h. */
static void pad_to(img_t *m, size_t start, size_t off) { while (m->pos < start + off) emit_u8(m, 0xCC); }
static void emit_hold(img_t *m, int wrong_grow)
{
    size_t h, je_end;
    align_to(m, 16, 0); m->hgrow = m->pos;
    emit_hex(m, "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 30 48 63 59 08 8B F2 48 8B F9 3B DA 0F 8C 00 00 00 00");
    emit_hex(m, "48 8B CF 8B D6 48 83 C4 30 5F 48 8B 5C 24 08 48 8B 74 24 10 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_grow_impl); emit_hex(m, "FF E0");
    align_to(m, 8, 0); { size_t k = m->pos; uint64_t z = 0; memcpy(m->text + m->pos, &z, 8); m->pos += 8;
    align_to(m, 16, 0); m->happr = m->pos;
    emit_hex(m, "40 55 53 57 41 56 48 8D AC 24 58 FF FF FF 48 81 EC A8 01 00 00 48 8B 05"); h = emit_rel_hole(m); fix_rel(m, h, k); }
    emit_hex(m, "48 33 C4 48 89 45 30 4C 8B F1 48 89 4C 24 50 48 8B 89 18 03 00 00");
    emit_hex(m, "49 8B CE 48 81 C4 A8 01 00 00 41 5E 5F 5B 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_appr_impl); emit_hex(m, "FF E0");
    pad_to(m, m->happr, 0x270); emit_hex(m, "41 C7 86 30 10 00 00 64 00 00 00");
    pad_to(m, m->happr, 0x31C); emit_u8(m, 0xE8); h = emit_rel_hole(m); fix_rel(m, h, wrong_grow ? m->stub : m->hgrow);
    pad_to(m, m->happr, 0x55D); emit_hex(m, "41 89 8E 30 10 00 00 C3");
    align_to(m, 16, 0); m->horder = m->pos;
    emit_hex(m, "48 8B C4 48 89 58 20 55 56 57 41 56 41 57 48 8D 68 A1 48 81 EC A0 00 00 00 0F 29 70 C8 4C 8B F1 48 8B 89 18 03 00 00");
    emit_hex(m, "49 8B CE 48 81 C4 A0 00 00 00 41 5F 41 5E 5F 5E 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_order_impl); emit_hex(m, "FF E0");
    pad_to(m, m->horder, 0x590); emit_hex(m, "45 89 A6 4C 10 00 00 C3");
    align_to(m, 16, 0); m->hsuppl = m->pos;
    emit_hex(m, "48 8B C4 55 53 56 57 41 55 48 8D A8 F8 FE FF FF 48 81 EC E0 01 00 00 44 0F 29 48 98 44 0F 29 A8 58 FF FF FF 44 0F 29 B0 48 FF FF FF");
    emit_hex(m, "48 81 C4 E0 01 00 00 41 5D 5F 5E 5B 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_suppl_impl); emit_hex(m, "FF E0");
    pad_to(m, m->hsuppl, 0x281); emit_hex(m, "F3 41 0F 11 85 9C 05 00 00");
    pad_to(m, m->hsuppl, 0xB20); emit_hex(m, "41 C7 85 A0 05 00 00 00 00 00 00 C3");
    align_to(m, 16, 0); m->hwadd = m->pos;
    emit_hex(m, "80 B9 E8 02 00 00 00 74 2D 33 C0 03 91 48 06 00 00 0F 48 D0 48 8B 81 50 03 00 00 89 91 48 06 00 00 48 85 C0 74 10 80 B8 4C 03 00 00 00 74 07 C6 80 1D 0D 00 00 01 C3");
    align_to(m, 16, 0); m->hwsub = m->pos;
    emit_hex(m, "40 55 57 48 83 EC 68 80 B9 E8 02 00 00 00 8B EA 48 8B F9 75 09 32 C0 48 83 C4 68 5F 5D C3 29 A9 48 06 00 00");
    emit_hex(m, "83 B9 48 06 00 00 00 7D 0E C7 81 48 06 00 00 00 00 00 00 32 C0 EB 02 B0 01 48 83 C4 68 5F 5D C3");
    align_to(m, 16, 0); m->hpadd = m->pos;
    emit_hex(m, "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 48 89 7C 24 20 41 54 41 56 41 57 48 83 EC 20 4C 8D A1 80 0D 00 00 0F B6 F2");
    emit_hex(m, "48 83 C4 20 41 5F 41 5E 41 5C 48 8B 74 24 18 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_padd_impl); emit_hex(m, "FF E0");
    align_to(m, 16, 0); m->hprem = m->pos;
    emit_hex(m, "48 83 EC 28 4D 8B D9 45 33 D2 4C 63 89 88 0D 00 00 45 85 C9 0F 8E 00 00 00 00");
    emit_hex(m, "4D 8B CB 48 83 C4 28 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_prem_impl); emit_hex(m, "FF E0");
    align_to(m, 16, 0); m->hprmall = m->pos;                /* remove all of a kind: rbp, rdi back from their home slots */
    emit_hex(m, "40 53 48 83 EC 20 48 89 6C 24 30 48 8D 99 80 0D 00 00 48 89 7C 24 40 48 8B E9 33 FF");
    emit_hex(m, "48 8B 6C 24 30 48 8B 7C 24 40 48 83 C4 20 5B 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_premall_impl); emit_hex(m, "FF E0");
    /* lane 36: the daily emigration, its real head (the HEMIG signature, je rel32 0), undone, then C */
    align_to(m, 16, 0); m->hemig = m->pos;
    emit_hex(m, "48 8B C4 55 56 48 8D 68 A1 48 81 EC C8 00 00 00 48 83 B9 50 03 00 00 00 48 8B F1 0F 84 00 00 00 00 83 B9 F0 04 00 00 00 0F 84 00 00 00 00");
    emit_hex(m, "48 8B CE 48 81 C4 C8 00 00 00 5E 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_emig_impl); emit_hex(m, "FF E0");
    /* lane 36: accomodateHomelessFamilies, its real head (the HHOUSE signature), undone, then C */
    align_to(m, 16, 0); m->hhouse = m->pos;
    emit_hex(m, "48 8B C4 48 89 50 10 55 53 48 8D A8 B8 FE FF FF 48 81 EC 38 02 00 00 48 89 70 E8 48 89 78 E0 4C 89 60 D8 4C 89 68 D0 4C 8B E9");
    emit_hex(m, "48 8B 70 E8 48 8B 78 E0 4C 8B 60 D8 4C 8B 68 D0 48 81 C4 38 02 00 00 5B 5D 48 8B 54 24 10 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_house_impl); emit_hex(m, "FF E0");
    /* wmon(region, amount): push r15 r14 rdi rbx (rsp then 8 off a 16-byte boundary: the stub must align itself) */
    align_to(m, 16, 0); m->hwmon = m->pos;
    emit_hex(m, "90 90 90 90 90 90 41 57 41 56 57 53 4C 8B F9 44 8B F2 33 FF 33 DB 33 D2 66 41 0F 6E E6");   /* 6 nops: the store lands 3 bytes into a qword, as in the game */
    emit_hex(m, "41 38 BF E8 02 00 00 74 3C"); je_end = m->pos;
    emit_hex(m, "83 FA FF 8B C7 0F 45 C3 41 03 87 48 06 00 00 41 03 C6 0F 48 C7 41 89 87 48 06 00 00 49 8B 87 50 03 00 00");
    emit_hex(m, "66 0F 7E E0 41 89 87 F0 10 00 00");
    while (m->pos < je_end + 0x3C) emit_u8(m, 0x90);
    emit_hex(m, "5B 5F 41 5E 41 5F C3");
}

/* lane 26: the four mouse-button handlers: their real prologues (the INPUT signatures, jumps with rel32 0), undone,
 * then a jump to a C recorder that keeps which handler ran on which pawn */
static volatile LONG g_input_calls[4];
static void *volatile g_input_pawn;
__declspec(noinline) static void fake_lmbdown(void *p) { InterlockedIncrement(&g_input_calls[0]); g_input_pawn = p; }
__declspec(noinline) static void fake_lmbup(void *p)   { InterlockedIncrement(&g_input_calls[1]); g_input_pawn = p; }
static void (*volatile g_rmbdown_then)(void *p);     /* lane 28: when set, what the "game's" press handler does to the path list */
__declspec(noinline) static void fake_rmbdown(void *p) { InterlockedIncrement(&g_input_calls[2]); g_input_pawn = p; if (g_rmbdown_then) g_rmbdown_then(p); }
__declspec(noinline) static void fake_rmbup(void *p)   { InterlockedIncrement(&g_input_calls[3]); g_input_pawn = p; }
static void emit_inputs(img_t *m)
{
    size_t h;
    align_to(m, 16, 0);                                   /* LMB pressed: ... mov rcx,[rcx+5A0]; call <stub> */
    emit_hex(m, "40 55 53 48 8D AC 24 18 FF FF FF 48 81 EC E8 01 00 00 80 B9 58 0A 00 00 00 48 8B D9 0F 85 00 00 00 00 48 8B 89 A0 05 00 00 E8");
    h = emit_rel_hole(m); fix_rel(m, h, m->stub);
    emit_hex(m, "48 8B CB 48 81 C4 E8 01 00 00 5B 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_lmbdown); emit_hex(m, "FF E0");
    align_to(m, 16, 0);                                   /* LMB released */
    emit_hex(m, "40 55 53 48 8B EC 48 83 EC 78 80 B9 58 0A 00 00 00 48 8B D9 0F 85 00 00 00 00 80 B9 98 05 00 00 00 0F 10 81 90 04 00 00");
    emit_hex(m, "48 83 C4 78 5B 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_lmbup); emit_hex(m, "FF E0");
    align_to(m, 16, 0);                                   /* RMB pressed (writes pawn+904) */
    emit_hex(m, "40 55 48 8D 6C 24 A9 48 81 EC B0 00 00 00 80 B9 58 0A 00 00 00 0F 85 00 00 00 00 0F 10 81 E8 04 00 00 33 C0 C6 81 04 09 00 00 01");
    emit_hex(m, "48 81 C4 B0 00 00 00 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_rmbdown); emit_hex(m, "FF E0");
    align_to(m, 16, 0);                                   /* RMB released (the cookie load reads the next bytes) */
    emit_hex(m, "4C 8B DC 55 57 49 8D 6B D8 48 81 EC 18 01 00 00 48 8B 05 00 00 00 00 48 33 C4 48 89 45 E0 80 B9 58 0A 00 00 00 48 8B F9 0F 85 00 00 00 00");
    emit_hex(m, "48 8B CF 48 81 C4 18 01 00 00 5F 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_rmbup); emit_hex(m, "FF E0");
}

/* lane 26: updateCursor's store of the cursor point (the CURSOR signature's bytes, rbp offset D7). Never run. */
static void emit_cursor(img_t *m)
{
    emit_hex(m, "F2 41 0F 5C 86 E8 04 00 00 F2 0F 10 65 D7 0F 28 DD F2 41 0F 5C 9E F0 04 00 00 0F 28 D4 F2 41 0F 5C 96 F8 04 00 00");
    emit_hex(m, "F2 41 0F 11 86 C0 04 00 00 0F 28 C1 66 0F 14 C5 F2 41 0F 11 9E C8 04 00 00 F2 41 0F 11 96 D0 04 00 00");
    emit_hex(m, "41 0F 11 86 E8 04 00 00 F2 41 0F 11 A6 F8 04 00 00 C3");
}


/* lane 28: the five routines of DRAW and ORDER: their real prologues (the signatures; conditional jumps go to the same
 * place), undone, then a jump to a C stand-in that does to a fake pawn what the game's routine does to the real one:
 *   tool update  keeps the cursor point it saw (as the "decal" the click takes) and sets the cannot-place flag (+5FC)
 *   click        appends the decal to roadPoints (+780) unless the flag is set
 *   commit       returns a fake road
 *   MoveSelected keeps its arguments; with the waypoint flag it edits the path list (+CA8) as the game does
 *   path point   appends the cursor point to the path list when it is far enough from the last one */
typedef struct { double x, y, z; } v3_t;
typedef struct { uint8_t *data; int32_t num, max; } tarr_t;
static volatile LONG g_l28_calls[5];
static v3_t g_l28_tool_cur[64], g_l28_tool_delta[64], g_l28_decal, g_l28_ms_cur;
static int g_l28_block_at = -1, g_l28_fault_in = -1;
static volatile int g_l28_click_flag[64], g_l28_wp, g_l28_na, g_l28_moved_seen;
static void *volatile g_l28_pawn;
static __declspec(align(16)) uint8_t g_l28_road[0x600];
static v3_t g_l28_rp[64];
static __declspec(align(16)) uint8_t g_l28_way[64 * 0x88];
static void l28_way_put(uint8_t *pawn, int i, const v3_t *p)
{
    tarr_t *a = (tarr_t *)(pawn + 0xCA8);
    memset(a->data + (size_t)i * 0x88, 0, 0x88);
    memcpy(a->data + (size_t)i * 0x88 + 8, p, sizeof(*p));
}
static v3_t l28_way_at(uint8_t *pawn, int i) { v3_t p; memcpy(&p, ((tarr_t *)(pawn + 0xCA8))->data + (size_t)i * 0x88 + 8, sizeof(p)); return p; }
static double l28_d2(const v3_t *a, const v3_t *b) { return (a->x - b->x) * (a->x - b->x) + (a->y - b->y) * (a->y - b->y); }
__declspec(noinline) static void fake_tool(uint8_t *pawn)
{
    LONG i = InterlockedIncrement(&g_l28_calls[0]) - 1;
    if (g_l28_fault_in == 0) RaiseException(0xE0000028u, 0, 0, NULL);
    memcpy(&g_l28_tool_cur[i & 63], pawn + 0x4E8, sizeof(v3_t)); memcpy(&g_l28_tool_delta[i & 63], pawn + 0x4C0, sizeof(v3_t));
    g_l28_decal = g_l28_tool_cur[i & 63];
    pawn[0x5FC] = (uint8_t)(i == g_l28_block_at);
}
__declspec(noinline) static void fake_click(uint8_t *pawn)
{
    LONG i = InterlockedIncrement(&g_l28_calls[1]) - 1;
    tarr_t *a = (tarr_t *)(pawn + 0x780);
    g_l28_click_flag[i & 63] = pawn[0x5FC];
    if (pawn[0x5FC] || a->num >= a->max) return;
    memcpy(a->data + (size_t)a->num * sizeof(v3_t), &g_l28_decal, sizeof(v3_t)); a->num++;
}
__declspec(noinline) static void *fake_commit(uint8_t *pawn) { InterlockedIncrement(&g_l28_calls[2]); g_l28_pawn = pawn; return g_l28_road; }
__declspec(noinline) static void fake_movesel(uint8_t *pawn, unsigned char wp, unsigned char na)
{
    tarr_t *a = (tarr_t *)(pawn + 0xCA8);
    InterlockedIncrement(&g_l28_calls[3]);
    if (g_l28_fault_in == 3) RaiseException(0xE0000028u, 0, 0, NULL);
    g_l28_pawn = pawn; g_l28_wp = wp; g_l28_na = na; g_l28_moved_seen = pawn[0x488];
    memcpy(&g_l28_ms_cur, pawn + 0x4E8, sizeof(v3_t));
    if (wp) {                                   /* the game: append the cursor when far, else it replaces the last; then drop the first of more than two */
        v3_t last = l28_way_at(pawn, a->num - 1);
        if (l28_d2(&last, &g_l28_ms_cur) > 250000.0) { l28_way_put(pawn, a->num, &g_l28_ms_cur); a->num++; }
        else l28_way_put(pawn, a->num - 1, &g_l28_ms_cur);
        if (a->num > 2) { memmove(a->data, a->data + 0x88, (size_t)(a->num - 1) * 0x88); a->num--; }
    }
}
__declspec(noinline) static void fake_pathpt(uint8_t *pawn)
{
    tarr_t *a = (tarr_t *)(pawn + 0xCA8);
    v3_t cur, last = l28_way_at(pawn, a->num - 1);
    InterlockedIncrement(&g_l28_calls[4]);
    memcpy(&cur, pawn + 0x4E8, sizeof(cur));
    if (l28_d2(&last, &cur) > 250000.0) { l28_way_put(pawn, a->num, &cur); a->num++; }
}
/* lane 53: WALLSET. The wall's rebuild and the game's insert of a control point, as functions that RUN. */
static volatile LONG g_l53_reb, g_l53_ins;
static int g_l53_refuse, g_l53_fault, g_l53_flag = -1, g_l53_num_at_reb;
static v3_t g_l53_big[64];
__declspec(noinline) static void fake_wallreb(uint8_t *road, unsigned char flag)
{
    tarr_t *a = (tarr_t *)(road + 0x318);
    InterlockedIncrement(&g_l53_reb);
    if (g_l53_fault == 2) RaiseException(0xE0000053u, 0, 0, NULL);
    g_l53_flag = flag; g_l53_num_at_reb = a->num;
}
__declspec(noinline) static int fake_wallins(uint8_t *road, const v3_t *p)
{
    tarr_t *a = (tarr_t *)(road + 0x318);
    InterlockedIncrement(&g_l53_ins);
    if (g_l53_fault == 1) RaiseException(0xE0000053u, 0, 0, NULL);
    if (g_l53_refuse > 0) { g_l53_refuse--; return -1; }
    if (a->num >= a->max) { memcpy(g_l53_big, a->data, (size_t)a->num * sizeof(v3_t)); a->data = (uint8_t *)g_l53_big; a->max = a->num + 1; }
    memmove(a->data + 2 * sizeof(v3_t), a->data + sizeof(v3_t), (size_t)(a->num - 1) * sizeof(v3_t));
    memcpy(a->data + sizeof(v3_t), p, sizeof(v3_t)); a->num++;
    return 1;
}
static void emit_l53(img_t *m)
{
    size_t h, ret, flt;
    align_to(m, 16, 0); ret = m->pos; emit_hex(m, "C3");
    align_to(m, 4, 0); flt = m->pos; emit_hex(m, "00 00 80 BF");            /* -1.0f: the insert's "far enough along the wall" test passes */
    align_to(m, 16, 0);                                   /* the rebuild */
    emit_hex(m, "48 89 5C 24 10 48 89 74 24 18 55 57 41 56 48 8D 6C 24 B9 48 81 EC A0 00 00 00 44 0F B6 F2 48 8B F9 E8"); h = emit_rel_hole(m); fix_rel(m, h, ret);
    emit_hex(m, "48 8B 8F C0 02 00 00 48 8D 97 18 03 00 00 41 B1 01 41 B8 01 00 00 00");
    emit_hex(m, "48 8B CF 41 0F B6 D6 48 81 C4 A0 00 00 00 41 5E 5F 5D 48 8B 5C 24 10 48 8B 74 24 18 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_wallreb); emit_hex(m, "FF E0");
    align_to(m, 16, 0);                                   /* the insert */
    emit_hex(m, "40 55 41 57 48 83 EC 78 0F 10 02 4C 8B FA 48 8B E9 F2 0F 10 4A 10 48 8D 54 24 30 0F 29 44 24 30 0F 29 7C 24 50 F2 0F 11 4C 24 40 E8"); h = emit_rel_hole(m); fix_rel(m, h, ret);
    emit_hex(m, "0F 28 F8 0F 2F 3D"); h = emit_rel_hole(m); fix_rel(m, h, flt);
    emit_hex(m, "73 0F 33 C0 0F 28 7C 24 50 48 83 C4 78 41 5F 5D C3 48 63 85 20 03 00 00");
    emit_hex(m, "48 8B CD 49 8B D7 0F 28 7C 24 50 48 83 C4 78 41 5F 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_wallins); emit_hex(m, "FF E0");
}
static void l28_press(void *p)                  /* the game's press handler: the path list becomes one point, the cursor */
{
    uint8_t *pawn = (uint8_t *)p;
    v3_t cur;
    memcpy(&cur, pawn + 0x4E8, sizeof(cur));
    l28_way_put(pawn, 0, &cur); ((tarr_t *)(pawn + 0xCA8))->num = 1;
}
static void emit_l28_movesel(img_t *m)
{
    align_to(m, 16, 0); m->l28_movesel = m->pos;
    emit_hex(m, "48 89 5C 24 20 55 56 57 41 56 41 57 48 8D AC 24 E0 FE FF FF 48 81 EC 20 02 00 00 48 8B 05 00 00 00 00 48 33 C4 48 89 85 C0 00 00 00 48 8B 99 50 05 00 00");
    emit_hex(m, "48 81 C4 20 02 00 00 41 5F 41 5E 5F 5E 5D 48 8B 5C 24 20 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_movesel); emit_hex(m, "FF E0");
}
static void emit_l28(img_t *m)
{
    size_t h1, h2;
    align_to(m, 16, 0);                                   /* the tool's update */
    emit_hex(m, "48 8B C4 55 57 48 8D A8 78 FE FF FF 48 81 EC 78 02 00 00 80 B9 A0 07 00 00 00 48 8B F9 0F 84"); h1 = emit_rel_hole(m);
    emit_hex(m, "48 89 58 E8 48 89 70 E0 4C 89 60 D8");
    fix_rel(m, h1, m->pos);
    emit_hex(m, "48 8B CF 48 81 C4 78 02 00 00 5F 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_tool); emit_hex(m, "FF E0");
    align_to(m, 16, 0);                                   /* the tool's click */
    emit_hex(m, "48 8B C4 48 89 58 20 55 48 8B EC 48 83 EC 70 80 B9 A0 07 00 00 00 48 8B D9 0F 84"); h1 = emit_rel_hole(m);
    emit_hex(m, "80 B9 FC 05 00 00 00 0F 85"); h2 = emit_rel_hole(m);
    emit_hex(m, "44 8B 89 88 07 00 00 41 83 F9 14");
    fix_rel(m, h1, m->pos); fix_rel(m, h2, m->pos);
    emit_hex(m, "48 8B CB 48 8B 9C 24 98 00 00 00 48 83 C4 70 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_click); emit_hex(m, "FF E0");
    align_to(m, 16, 0);                                   /* commitRoad (the cookie load reads the next bytes) */
    emit_hex(m, "40 55 53 56 57 41 57 48 8D AC 24 00 FF FF FF 48 81 EC 00 02 00 00 48 8B 05 00 00 00 00 48 33 C4 48 89 85 D0 00 00 00 80 B9 A0 07 00 00 00 48 8B F1 0F 84"); h1 = emit_rel_hole(m);
    emit_hex(m, "80 B9 C0 07 00 00 00");
    fix_rel(m, h1, m->pos);
    emit_hex(m, "48 8B CE 48 81 C4 00 02 00 00 41 5F 5F 5E 5B 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_commit); emit_hex(m, "FF E0");
    emit_l28_movesel(m);                                  /* MoveSelected */
    align_to(m, 16, 0);                                   /* the path routine */
    emit_hex(m, "48 89 5C 24 18 48 89 74 24 20 57 48 81 EC 30 01 00 00 48 8B F9 48 8D 99 A8 0C 00 00 48 63 4B 08 48 8B 03 48 8B F1 48 69 D1 88 00 00 00");
    emit_hex(m, "48 8B CF 48 81 C4 30 01 00 00 5F 48 8B 5C 24 18 48 8B 74 24 20 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_pathpt); emit_hex(m, "FF E0");
}

/* lane 23: the job chooser's test of the job list, as a function that RUNS: chooser(unit rcx, unused rdx, job type r8d)
 * returns 1 when the type is in the engine's list (the chooser would leave), 0 when not. The unit holds the engine at
 * +318h, the engine its list at +10A8h (data) / +10B0h (count), exactly the game's bytes from "mov rcx,[rdi+318h]" to
 * the loop's end (4ddb30a-4ddb341); the hooked bytes sit at %8 == 2 as in the game (4ddb322). */
typedef unsigned char (*chooser_fn)(void *unit, void *unused, int jobtype);
static void emit_chooser(img_t *m, int wrong)
{
    size_t f, hole, listed, epi_hole;
    align_to(m, 16, 0); f = m->pos;
    emit_hex(m, "53 57 41 57 48 8B F9 45 8B F8");               /* push rbx; push rdi; push r15; mov rdi,rcx; mov r15d,r8d */
    while ((TEXT_RVA + m->pos + 1 + 22) % 8 != 2) emit_u8(m, 0x90);
    emit_hex(m, "48 8B 8F 18 03 00 00 48 8B D8 48 8B 91 A8 10 00 00 48 63 89 B0 10 00 00");
    m->choose_site = m->pos;
    emit_hex(m, wrong ? "4C 8D 04 8B 49 3B D0 74 17 0F 1F 44 00 00 44 39 3A 0F 84" : "4C 8D 04 8A 49 3B D0 74 17 0F 1F 44 00 00 44 39 3A 0F 84");
    hole = emit_rel_hole(m);
    emit_hex(m, "48 83 C2 04 49 3B D0 75 EE");
    emit_hex(m, "31 C0 EB"); epi_hole = m->pos; emit_u8(m, 0);   /* not listed: xor eax,eax; jmp epi */
    listed = m->pos; emit_hex(m, "B0 01");                       /* listed: mov al,1 */
    m->text[epi_hole] = (uint8_t)(m->pos - (epi_hole + 1));
    emit_hex(m, "41 5F 5F 5B C3");
    fix_rel(m, hole, listed);
    if (!m->chooser) m->chooser = f;
}

/* the lead: the routine that counts goods made in a region (the game's 4c4a960), as a function that RUNS:
 * f(region rcx, list rdx): GetWorld(region); null -> leave; manager(world); null -> leave; (the pattern's last three
 * instructions); returns the manager (so the test sees the body ran). The game's bytes up to "shl rdx,5"; both calls
 * go to thunks inside the image that jump to the C stand-ins below. The call's displacement sits at %8 == 2 as in the
 * game (4c4a972). The stand-in for GetWorld counts a null object instead of reading through it. */
typedef void *(*noregion_fn)(void *region, void *list);
static int g_gw_calls, g_gw_null, g_mgr_calls;
static struct { uint8_t pad[0x38]; void *data; int32_t num; } g_fake_mgr;
static void *fake_getworld(void *obj) { g_gw_calls++; if (!obj) { g_gw_null++; return NULL; } return *(void **)((uint8_t *)obj + 8); }
static void *fake_mgr(void *world) { g_mgr_calls++; return world ? (void *)&g_fake_mgr : NULL; }
static void emit_noregion(img_t *m, int twin, int outside)
{
    size_t f, gw, mg, h1, h2, j1, j2, jj, epi1, epi2;
    align_to(m, 16, 0);
    if (!m->nr_gw) {                                             /* one pair of thunks for every copy of the routines */
        m->nr_gw = m->pos; emit_hex(m, "48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_getworld); emit_hex(m, "FF E0");
        m->nr_mg = m->pos; emit_hex(m, "48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_mgr); emit_hex(m, "FF E0");
    }
    gw = m->nr_gw; mg = m->nr_mg;
    align_to(m, 16, 0); f = m->pos;
    emit_hex(m, "48 89 5C 24 18 41 56 48 83 EC 20 4C 8B F2 48 8B D9 E8"); h1 = emit_rel_hole(m);
    emit_hex(m, "48 85 C0 0F 84"); j2 = emit_rel_hole(m);
    emit_hex(m, "48 8B C8 48 89 7C 24 38 E8"); h2 = emit_rel_hole(m);
    emit_hex(m, "48 8B F8 48 85 C0 0F 84"); j1 = emit_rel_hole(m);
    emit_hex(m, "48 8B 48 38 48 63 50 40 48 C1 E2 05");
    emit_hex(m, "48 8B C7");                                     /* mov rax,rdi */
    epi1 = m->pos; emit_hex(m, "48 8B 7C 24 38 E9"); jj = emit_rel_hole(m);   /* mov rdi,[rsp+38h]; jmp epi2 */
    /* the game's first jump is DA 00 00 00 in the one routine and D7 00 00 00 in its twin: filler up to that distance */
    while (m->pos < j2 + 4 + (twin ? 0xD7u : 0xDAu)) emit_u8(m, 0xCC);
    epi2 = m->pos; emit_hex(m, "48 8B 5C 24 40 48 83 C4 20 41 5E C3");
    fix_rel(m, h1, gw); fix_rel(m, h2, mg); fix_rel(m, j1, epi1); fix_rel(m, j2, epi2); fix_rel(m, jj, epi2);
    if (outside) { int32_t far_rel = 0x60000000; memcpy(m->text + h1, &far_rel, 4); }
    if (twin) { if (!m->noregion2) m->noregion2 = f; } else if (!m->noregion) m->noregion = f;
}

/* lane 35: PICK. setTask(unit rcx, record rdx) with the game's first 31 bytes, then: unit+0 counts its runs, unit+8 gets
 * the record's type (byte 0), unit+10h its target unit (+A8h). chooser(unit rcx) with the game's first 8 bytes calls
 * setTask(unit, *g_pick_rec) and returns 1; CHOOSE's pattern lies at +1DCh in it (dead bytes, as in the game). think(unit)
 * holds the CHOOSECALL pattern; unit+AB0h is 0, so it calls the chooser through the call at +22. */
static uint8_t *g_pick_rec;
typedef void (*settask_fn)(void *unit, void *rec);
typedef void (*think_fn)(void *unit);
static void emit_pick(img_t *m, int variant)
{
    size_t f, c, t, hole, other;
    uint64_t a;
    align_to(m, 16, 0); f = m->pos;
    if (variant == 3) emit_hex(m, "40 53 48 83 EC 20 90 90 90");                 /* another build: push rbx; sub rsp,20h */
    else emit_hex(m, "40 53 48 81 EC 20 01 00 00");
    emit_hex(m, "83 B9 A0 08 00 00 00 48 8B D9 48 89 BC 24 38 01 00 00 48 8B FA 7E 00");
    emit_hex(m, "8A 07 88 43 08 48 8B 87 A8 00 00 00 48 89 43 10 FF 03 48 8B BC 24 38 01 00 00");
    emit_hex(m, variant == 3 ? "48 83 C4 20 5B C3" : "48 81 C4 20 01 00 00 5B C3");
    m->pk_settask = f;
    align_to(m, 16, 0); c = m->pos; m->pk_chooser = c;
    emit_hex(m, "48 89 5C 24 18 55 56 57 48 83 EC 20 48 BA");
    a = (uint64_t)(uintptr_t)&g_pick_rec; emit_imm64(m, a);
    emit_hex(m, "48 8B 12 48 B8"); a = (uint64_t)(uintptr_t)(m->text + f); emit_imm64(m, a);
    emit_hex(m, "FF D0 48 83 C4 20 5F 5E 5D 48 8B 5C 24 18 B0 01 C3");
    while (m->pos < c + 0x1DC) emit_u8(m, 0xCC);
    emit_hex(m, "8F 18 03 00 00 48 8B D8 48 8B 91 A8 10 00 00 48 63 89 B0 10 00 00 4C 8D 04 8A 49 3B D0 74 17 0F 1F 44 00 00 44 39 3A 0F 84 00 00 00 00");
    align_to(m, 16, 0); other = m->pos; emit_hex(m, "31 C0 C3");               /* a routine that is not the chooser */
    align_to(m, 16, 0); t = m->pos; m->pk_think = t;
    emit_hex(m, "57 48 83 EC 20 48 8B F9");
    while ((TEXT_RVA + m->pos + 22) % 8 != 0) emit_u8(m, 0x90);
    emit_hex(m, "80 BF B0 0A 00 00 05 75 0A 48 8B CF E8"); hole = emit_rel_hole(m); fix_rel(m, hole, c);
    emit_hex(m, "EB 08 48 8B CF E8"); m->pk_call = m->pos - 1; hole = emit_rel_hole(m); fix_rel(m, hole, variant == 2 ? other : c);
    emit_hex(m, "84 C0 75 00 80 BF A8 08 00 00 02 48 83 C4 20 5F C3");
}

/* lane 40: FIELD. Each routine has the game's first bytes (its signature), undoes them, and jumps to a C recorder:
 * UpdateFieldCache(field, 4 flags) records the growth of plant 2 it sees (the hook must have put it back before);
 * the drawing routine (field, index) and the brush (engine, place, amount, add) record their arguments. */
#define FL_PLANT 0xD0
static volatile LONG g_fc_calls, g_fd_calls, g_fp_calls;
static volatile float g_fc_seen_gr2, g_fp_amt_last;
static volatile int g_fd_last, g_fp_add_last;
static volatile LONG g_fu_calls; static volatile int g_fu_idx, g_fu_world, g_fu_dirty; static volatile double g_fu_sx;
__declspec(noinline) static char fake_fupd_impl(void *ism, int idx, const uint8_t *t, char world, char dirty, char teleport)
{
    (void)ism; (void)teleport;
    InterlockedIncrement(&g_fu_calls); g_fu_idx = idx; g_fu_world = world; g_fu_dirty = dirty; g_fu_sx = *(const double *)(t + 0x40);
    return 1;
}
__declspec(noinline) static void fake_fcache_impl(uint8_t *field, char a, char b, char c, char d)
{
    uint8_t *plants = *(uint8_t **)(field + 0x530);
    (void)a; (void)b; (void)c; (void)d;
    InterlockedIncrement(&g_fc_calls);
    if ((uintptr_t)plants > 0x10000 && *(int32_t *)(field + 0x538) > 2) g_fc_seen_gr2 = *(float *)(plants + 2 * FL_PLANT + 0x24);
    *(int32_t *)(field + 0xBF4) = 777;                       /* the "game" counts: its own number of ready plants */
}
__declspec(noinline) static void fake_fdraw_impl(uint8_t *field, int idx)
{
    (void)field;
    InterlockedIncrement(&g_fd_calls); g_fd_last = idx;
}
__declspec(noinline) static void fake_fpaint_impl(uint8_t *eng, const double *pos, float amt, char add)
{
    (void)eng; (void)pos;
    InterlockedIncrement(&g_fp_calls); g_fp_amt_last = amt; g_fp_add_last = add;
}
typedef void (*fcache_call)(void *field, char a, char b, char c, char d);
static void emit_field(img_t *m)
{
    size_t at;
    int32_t rel;
    align_to(m, 16, 0); m->fl_cache = m->pos;
    emit_hex(m, "40 53 41 55 48 83 EC 38 0F 29 74 24 20 4C 8D 91 38 05 00 00 45 33 ED 4C 89 64 24 68 45 0F B6 E1 45 0F B6 D8 48 8B D9");
    emit_hex(m, "4C 8B 64 24 68 0F 28 74 24 20 48 83 C4 38 41 5D 5B 48 B8");   /* r12, xmm6 back; add rsp,38h; pop r13; pop rbx */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_fcache_impl); emit_hex(m, "FF E0");
    align_to(m, 16, 0); m->fl_draw = m->pos;
    emit_hex(m, "4C 8B DC 55 57 41 56 49 8D AB F8 FE FF FF 48 81 EC F0 01 00 00 45 0F 29 AB 58 FF FF FF 45 0F 29 B3 48 FF FF FF 48 8B 05");
    at = emit_rel_hole(m);                                                   /* the game's security cookie: here in .data */
    rel = (int32_t)((intptr_t)(m->base + DATA_RVA + 0x800) - (intptr_t)(m->text + at + 4));   /* a qword in .data */
    memcpy(m->text + at, &rel, 4);
    emit_hex(m, "48 33 C4 48 89 45 40 49 89 5B 18 4C 8B F1 49 89 73 20 33 F6 89 74 24 50 48 8B 81 E8 02 00 00 4D 89 63 E0 4D 89 7B D8 4C 63 FA 48 8B 98 98 10 00 00");
    emit_hex(m, "49 8B 5B 18 49 8B 73 20 4D 8B 63 E0 4D 8B 7B D8 45 0F 28 AB 58 FF FF FF 45 0F 28 B3 48 FF FF FF 49 8D 63 E8 41 5E 5F 5D 48 B8");
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_fdraw_impl); emit_hex(m, "FF E0");
    align_to(m, 16, 0); m->fl_paint = m->pos;
    emit_hex(m, "48 8B C4 48 89 68 18 48 89 70 20 41 56 48 83 EC 60 48 8B A9 28 06 00 00 45 0F B6 F1 44 0F 29 40 C8 44 0F 28 C2 48 8B F1");
    emit_hex(m, "44 0F 28 40 C8 48 8B 68 18 48 8B 70 20 48 83 C4 60 41 5E 48 B8");  /* xmm8, rbp, rsi back; add rsp,60h; pop r14 */
    emit_imm64(m, (uint64_t)(uintptr_t)&fake_fpaint_impl); emit_hex(m, "FF E0");
    align_to(m, 16, 0); m->fl_upd = m->pos;                                  /* the mesh's UpdateInstanceTransform (a vtable entry) */
    emit_hex(m, "48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_fupd_impl); emit_hex(m, "FF E0");
}

/* lane 42: DIST. The distribution (the game's 4c3c490) with the game's first 28 bytes (they decrement region+1130h), then
 * fake_dist_impl(region): the stand-in rebuilds g_dist_house's list (+E90h) to the friend's own result, one record of
 * good 216. The market routine (callable as f(region)) holds the DISTCALL pattern, entered at its "mov rcx,r13"; the call's
 * displacement sits at %8 == 0 as in the game (4c49220). The grow helper has the game's first 26 bytes, then grows the
 * list in C; DGROW's pattern (dead bytes) calls it at +68. The surplus cache has the game's first 40 bytes (its call goes
 * to a "ret") and then counts. */
typedef void (*dist_mk_fn)(void *region);
static volatile LONG g_dist_calls, g_dgrow_calls, g_dsurp_calls;
static uint8_t *volatile g_dist_house, *volatile g_dsurp_b;
__declspec(noinline) static void fake_dist_impl(uint8_t *region)
{
    garr_t *a;
    (void)region;
    InterlockedIncrement(&g_dist_calls);
    if (!g_dist_house) return;
    a = (garr_t *)(g_dist_house + 0xE90);
    if (a->max < 1) return;
    a->num = 1; memset(&a->data[0], 0, sizeof(fgood_t)); a->data[0].type = 216; a->data[0].amt = 1;
}
__declspec(noinline) static void fake_dgrow_impl(garr_t *a, int old)
{
    fgood_t *n;
    int nm = a->num + 4;
    InterlockedIncrement(&g_dgrow_calls);
    n = (fgood_t *)calloc((size_t)nm, sizeof(fgood_t));
    if (old > 0) memcpy(n, a->data, (size_t)old * sizeof(fgood_t));
    a->data = n; a->max = nm;
}
__declspec(noinline) static void fake_dsurp_impl(uint8_t *b) { InterlockedIncrement(&g_dsurp_calls); g_dsurp_b = b; }
static void emit_dist(img_t *m, int variant)
{
    size_t d, mk, jmpat, pat, hole, gr, other, ret, sp;
    align_to(m, 16, 0); ret = m->pos; emit_hex(m, "C3");
    align_to(m, 16, 0); other = m->pos; emit_hex(m, "C3");                             /* a routine that is not the distribution */
    align_to(m, 16, 0); d = m->pos; m->dist = d;
    emit_hex(m, "48 8B C4 48 89 48 08 53 48 81 EC C0 00 00 00 FF 89 30 11 00 00 48 89 68 F0 48 8B E9");
    emit_hex(m, "48 8B CD 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_dist_impl);
    emit_hex(m, "FF D0 48 8B AC 24 B8 00 00 00 48 81 C4 C0 00 00 00 5B C3");
    align_to(m, 16, 0); mk = m->pos; m->dist_mk = mk;
    emit_hex(m, "55 41 55 41 56 48 83 EC 20 4C 8B E9 48 8B EC EB"); jmpat = m->pos; emit_u8(m, 0);
    while ((TEXT_RVA + m->pos + 16) % 8 != 0) emit_u8(m, 0xCC);
    pat = m->pos;
    emit_hex(m, "C7 85 34 11 00 00 01 00 00 00 EB 0B 49 8B CD E8"); m->dist_call = m->pos - 1; hole = emit_rel_hole(m); fix_rel(m, hole, variant == 2 ? other : d);
    emit_hex(m, "45 33 F6 44 89 75 08 48 83 C4 20 41 5E 41 5D 5D C3");
    m->text[jmpat] = (uint8_t)(pat + 12 - (jmpat + 1));
    align_to(m, 16, 0); gr = m->pos; m->dist_grow = gr;
    emit_hex(m, variant == 3 ? "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 40 48 63 59 08 8B F2 48 8B F9 3B DA"
                             : "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 30 48 63 59 08 8B F2 48 8B F9 3B DA");
    emit_hex(m, "48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_dgrow_impl);
    emit_hex(m, variant == 3 ? "FF D0 48 8B 5C 24 50 48 8B 74 24 58 48 83 C4 40 5F C3" : "FF D0 48 8B 5C 24 40 48 8B 74 24 48 48 83 C4 30 5F C3");
    align_to(m, 16, 0);                                                                  /* DGROW's pattern: dead bytes */
    emit_hex(m, "48 81 C3 90 0E 00 00 48 63 43 08 48 8B 13 48 8D 0C 40 48 8D 04 CA 48 3B D0 74 11 39 32 0F 84 00 00 00 00 48 83 C2 18 48 3B D0 75 EF 85 FF 7E 3F 48 63 6B 08 8D 45 01 89 43 08 3B 43 0C 76 0A 8B D5 48 8B CB E8");
    hole = emit_rel_hole(m); fix_rel(m, hole, gr);
    emit_hex(m, "C3");
    align_to(m, 16, 0); sp = m->pos; m->dist_surp = sp;
    emit_hex(m, "48 89 4C 24 08 57 41 55 41 56 48 83 EC 70 48 8D B9 60 04 00 00 4C 89 64 24 58 4C 8B E9 48 8D 91 48 04 00 00 48 8B CF E8");
    hole = emit_rel_hole(m); fix_rel(m, hole, ret);
    emit_hex(m, "49 8B CD 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_dsurp_impl);
    emit_hex(m, "FF D0 4C 8B 64 24 58 48 83 C4 70 41 5E 41 5D 5F C3");
}

/* lane 35, round six: REGSET. A set removal with the game's first 16 bytes that jumps to fake_setrm (it records the
 * call and removes the key from the test's member list), and the REGSETS pattern whose two calls reach it. */
static void *g_rs_set[16]; static uint64_t g_rs_key[16]; static int g_rs_n;
static uint64_t g_rs_members[2][8]; static int g_rs_count[2];
static uint8_t *g_rs_region;
static int fake_setrm(void *set, void *key)
{
    int which = (uint8_t *)set == g_rs_region + 0x5A8 ? 0 : ((uint8_t *)set == g_rs_region + 0x5F8 ? 1 : -1), i;
    if (g_rs_n < 16) { g_rs_set[g_rs_n] = set; g_rs_key[g_rs_n] = (uint64_t)(uintptr_t)key; g_rs_n++; }
    if (which < 0) return 0;
    for (i = 0; i < g_rs_count[which]; i++) if (g_rs_members[which][i] == (uint64_t)(uintptr_t)key) { g_rs_members[which][i] = g_rs_members[which][--g_rs_count[which]]; return 1; }
    return 0;
}
static void emit_regset(img_t *m, int variant)
{
    size_t rm, rm2, site, hole;
    align_to(m, 16, 0); rm = m->pos;
    emit_hex(m, "48 83 EC 28 8B 41 08 4C 8B DA 4C 8B D1 3B 41 34 48 83 C4 28 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_setrm); emit_hex(m, "FF E0");
    align_to(m, 16, 0); rm2 = m->pos; emit_hex(m, "31 C0 C3");
    align_to(m, 16, 0); site = m->pos; m->rs_site = site;
    emit_hex(m, "48 8B 5C 24 38 48 8D 8F A8 05 00 00 48 8B D3 E8"); hole = emit_rel_hole(m); fix_rel(m, hole, rm);
    emit_hex(m, "48 8D 8F F8 05 00 00 48 8B D3 E8"); hole = emit_rel_hole(m); fix_rel(m, hole, variant == 2 ? rm2 : rm);
    emit_hex(m, "48 39 9F 58 03 00 00 C3");
}
/* a TSet of 8-byte keys as the game keeps it: elements { key, next, hash index } at [set+0], their count at +8, the
 * hash inline at +38h (one bucket, [set+40h] null), its size at +48h */
static void rs_make_set(uint8_t *set, uint8_t *elems, const uint64_t *keys, int n)
{
    int i;
    memset(set, 0, 0x50);
    for (i = 0; i < n; i++) { int32_t next = i + 1 < n ? i + 1 : -1, zero = 0; memcpy(elems + i * 16, &keys[i], 8); memcpy(elems + i * 16 + 8, &next, 4); memcpy(elems + i * 16 + 12, &zero, 4); }
    *(uint8_t **)set = elems; *(int32_t *)(set + 8) = n;
    *(int32_t *)(set + 0x38) = n ? 0 : -1; *(int32_t *)(set + 0x48) = 1;
}

/* lane 43: MEN. The path request (the game's 4dbc910) with the game's first 64 bytes (its cookie read points into .data,
 * its je goes to the next instruction), then its frame undone and a jump to fake_mpath_impl(man, record, flag, list),
 * which records the man and the record's place, +58h..+77h. tickSquad's call (MSLOT pattern) as dead bytes: its two
 * rip-relative constants point at .data +A00h / +A20h, its E8 at the request (variant 3: at a "ret"). */
#define MV_K1 0xA00
#define MV_K2 0xA20
typedef void (*mpath_call)(void *man, uint8_t *rec, uint64_t flag, void *list);
static volatile LONG g_mp_calls; static void *volatile g_mp_man; static double g_mp_pt[3]; static uint8_t g_mp_rest[0x20]; static uint64_t g_mp_flag;
__declspec(noinline) static void fake_mpath_impl(void *man, uint8_t *rec, uint64_t flag, void *list)
{
    (void)list;
    InterlockedIncrement(&g_mp_calls); g_mp_man = man; g_mp_flag = flag;
    if ((uintptr_t)rec > 0x10000) { memcpy(g_mp_pt, rec + 8, 24); memcpy(g_mp_rest, rec + 0x58, 0x20); }
}
static void emit_men(img_t *m, int variant)
{
    size_t at, hole, ret;
    int32_t rel;
    int k;
    for (k = 0; k < (variant == 2 ? 2 : 1); k++) {
        align_to(m, 16, 0); if (k == 0) m->mv_entry = m->pos;
        emit_hex(m, "40 55 56 57 41 54 41 56 48 8D AC 24 50 FC FF FF 48 81 EC B0 04 00 00 48 8B 05");
        at = emit_rel_hole(m);
        rel = (int32_t)((intptr_t)(m->base + DATA_RVA + 0x800) - (intptr_t)(m->text + at + 4)); memcpy(m->text + at, &rel, 4);
        emit_hex(m, "48 33 C4 48 89 85 E0 02 00 00 80 B9 3C 0E 00 00 00 4D 8B F1 45 0F B6 E0 48 8B F2 48 8B F9 74 00");
        emit_hex(m, "48 81 C4 B0 04 00 00 41 5E 41 5C 5F 5E 5D 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_mpath_impl); emit_hex(m, "FF E0");
    }
    align_to(m, 16, 0); ret = m->pos; emit_hex(m, "C3");
    align_to(m, 16, 0); m->mv_site = m->pos;
    emit_hex(m, "49 8B CF 0F 10 05"); at = emit_rel_hole(m);
    rel = (int32_t)((intptr_t)(m->base + DATA_RVA + MV_K1) - (intptr_t)(m->text + at + 4)); memcpy(m->text + at, &rel, 4);
    emit_hex(m, "48 89 55 38 48 89 55 40 0F 11 45 70 48 89 55 48 F2 0F 10 05"); at = emit_rel_hole(m);
    rel = (int32_t)((intptr_t)(m->base + DATA_RVA + MV_K2) - (intptr_t)(m->text + at + 4)); memcpy(m->text + at, &rel, 4);
    emit_hex(m, "48 89 55 50 88 55 58 48 89 55 60 48 89 55 68 66 89 95 94 00 00 00 88 95 96 00 00 00 89 95 98 00 00 00 48 8D 55 18 F2 0F 11 85 80 00 00 00 F2 0F 11 4D 30 C7 85 88 00 00 00 20 BC BE 4C 48 C7 85 8C 00 00 00 FF FF FF FF E8");
    hole = emit_rel_hole(m); fix_rel(m, hole, variant == 3 ? ret : m->mv_entry);
    emit_hex(m, "C3");
    for (k = 0; k < 16; k++) m->base[DATA_RVA + MV_K1 + k] = (uint8_t)(0xA0 + k);
    for (k = 0; k < 8; k++) m->base[DATA_RVA + MV_K2 + k] = (uint8_t)(0xB0 + k);
}

/* lane 52, PACE: the squad's pace rule (the game's 4d8db70) with the game's first 110 bytes: both calls reach a lookup
 * that returns the test's squad record (men at +18h, their count at +20h; null while g_pc_squad is null); then
 * fake_pace_impl(component, squad number) (the "rule": it writes g_pc_give into every man's +5A8h), the frame undone
 * as the game undoes it. Variant 2: the second call reaches another lookup. */
static uint8_t *volatile g_pc_squad; static volatile LONG g_pc_calls; static uint32_t g_pc_id; static float g_pc_give = 0.5f;
__declspec(noinline) static void fake_pace_impl(void *comp, uint32_t id)
{
    uint8_t *sq = g_pc_squad; int i;
    (void)comp; InterlockedIncrement(&g_pc_calls); g_pc_id = id;
    if (sq) for (i = 0; i < *(int32_t *)(sq + 0x20); i++) { uint8_t *mn = (*(uint8_t ***)(sq + 0x18))[i]; if ((uintptr_t)mn > 0x10000) *(float *)(mn + 0x5A8) = g_pc_give; }
}
static void emit_pace(img_t *m, int variant)
{
    size_t h1, h2, x1, x2, out;
    int k;
    for (k = 0; k < 2; k++) {
        align_to(m, 16, 0); if (k == 0) m->pc_find = m->pos; else m->pc_find2 = m->pos;
        emit_hex(m, "48 A1"); emit_imm64(m, (uint64_t)(uintptr_t)&g_pc_squad); emit_hex(m, "C3");      /* mov rax,[g_pc_squad]; ret */
    }
    align_to(m, 16, 0); m->pc_entry = m->pos;
    emit_hex(m, "40 53 57 41 55 48 81 EC 80 00 00 00 8B DA 4C 8B E9 E8"); h1 = emit_rel_hole(m);
    emit_hex(m, "48 8B F8 48 85 C0 0F 84"); x1 = emit_rel_hole(m);
    emit_hex(m, "83 78 20 00 0F 84"); x2 = emit_rel_hole(m);
    emit_hex(m, "4C 89 B4 24 B0 00 00 00 8B D3 44 0F 29 5C 24 20 49 8B CD 48 89 B4 24 A8 00 00 00 E8"); h2 = emit_rel_hole(m);
    emit_hex(m, "45 33 F6 48 85 C0 74 0F 44 39 70 20 74 09 48 8B 40 18 48 8B 30 EB 03 49 8B F6 48 8B 4F 18 48 63 47 20");
    emit_hex(m, "49 8B CD 8B D3 48 B8"); emit_imm64(m, (uint64_t)(uintptr_t)&fake_pace_impl); emit_hex(m, "FF D0");   /* mov rcx,r13; mov edx,ebx; call the rule */
    emit_hex(m, "44 0F 28 5C 24 20 48 8B B4 24 A8 00 00 00 4C 8B B4 24 B0 00 00 00");                             /* xmm11, rsi, r14 back */
    out = m->pos; emit_hex(m, "48 81 C4 80 00 00 00 41 5D 5F 5B C3");
    fix_rel(m, h1, m->pc_find); fix_rel(m, h2, variant == 2 ? m->pc_find2 : m->pc_find); fix_rel(m, x1, out); fix_rel(m, x2, out);
}

/* lane 35, round seven: thunk(unit rcx, rec rdx) holds the SETTHUNK pattern; its call at +18 reaches the test's setTask
 * (rcx and rdx are passed through: the pattern's own instructions touch only rax, rdi and [rbx+20h], rbx -> a scratch) */
static uint8_t g_th_scratch[0x40];
static void emit_setthunk(img_t *m)
{
    size_t hole;
    align_to(m, 16, 0); m->st_thunk = m->pos;
    emit_hex(m, "53 57 56 48 81 EC 00 01 00 00 48 BB"); emit_imm64(m, (uint64_t)(uintptr_t)g_th_scratch); emit_hex(m, "31 FF");
    emit_hex(m, "48 8B 43 20 48 85 C0 40 0F 95 C7 48 03 F8 48 89 7B 20 E8"); hole = emit_rel_hole(m); fix_rel(m, hole, m->pk_settask);
    emit_hex(m, "4C 8D 9C 24 00 01 00 00 49 8B 5B 10 49 8B 73 18");
    emit_hex(m, "48 81 C4 00 01 00 00 5E 5F 5B C3");
}

/* lane 46: demolish(building rcx, pile rdx, region r8) holding the DEMREF pattern (the game's 4d34336): refresh(region,
 * building) through the call at +22, then refresh(region, pile); both calls reach the test's refresh. With o->demref
 * == 2 the first call goes elsewhere (the stub). */
static void emit_demref(img_t *m, int variant)
{
    size_t h1, h2;
    align_to(m, 16, 0); m->dem = m->pos;
    emit_hex(m, "53 57 41 54 48 83 EC 30 48 8B F9 48 8B DA 4D 8B E0");
    emit_hex(m, "4D 85 E4 74 35 45 33 C9 C6 44 24 20 00 45 33 C0 48 8B D7 49 8B CC E8"); h1 = emit_rel_hole(m);
    emit_hex(m, "45 33 C9 C6 44 24 20 00 45 33 C0 48 8B D3 49 8B CC E8"); h2 = emit_rel_hole(m);
    emit_hex(m, "EB 07 90 90 90 90 90 90 90 48 83 C4 30 41 5C 5F 5B C3");
    fix_rel(m, h1, variant == 2 ? m->stub : m->refresh); fix_rel(m, h2, m->refresh);
}

/* lane 49: GUIDE. The game's guide assignment from its entry to its first write (the game's 4e15ab0); the lea and the
 * two calls are dead (the DLL never calls it). Variant 2: the pattern twice; variant 3: "cmp/mov [rdi+338h]" (a build
 * whose field moved: the pattern does not match, no site). */
static void emit_guide(img_t *m, int variant)
{
    align_to(m, 16, 0); m->guide = m->pos;
    emit_hex(m, "48 89 5C 24 10 48 89 7C 24 18 55 48 8D 6C 24 B0 48 81 EC 50 01 00 00 48 8B FA 48 8B D9 48 8D 15 00 00 00 00 48 8D 4C 24 20 E8 00 00 00 00 48 8B 4C 24 20 48 85 C9 74 05 E8 00 00 00 00");
    emit_hex(m, variant == 3 ? "48 3B 9F 38 03 00 00 74 07 48 89 9F 38 03 00 00" : "48 3B 9F 30 03 00 00 74 07 48 89 9F 30 03 00 00");
    emit_hex(m, "C3");
}

/* lane 54: FELL. The lookup of a tree being felled from its entry to the read of a record's first double (the game's
 * 4c63c60), and a felling stroke (4dc5a97); both dead code here (the DLL never calls them). Variant 2: the lookup
 * twice; variant 3: a stroke that writes the record's +1Ch (a build whose record changed: no site); 4: no stroke. */
static void emit_fell(img_t *m, int variant)
{
    int k;
    for (k = 0; k < (variant == 2 ? 2 : 1); k++) {
        align_to(m, 16, 0); m->fell = m->pos;
        emit_hex(m, "48 83 EC 18 48 63 81 D8 0C 00 00 0F 29 34 24 85 C0 7E 70 F2 0F 10 1A 45 33 C0 F2 0F 10 62 08 F2 0F 10 6A 10 48 8B D0 48 8B 89 D0 0C 00 00 41 8B C0 F2 0F 10 35 00 00 00 00 0F 1F 80 00 00 00 00 F2 0F 10 11");
        emit_hex(m, "C3");
    }
    if (variant == 4) return;
    align_to(m, 16, 0);
    emit_hex(m, variant == 3 ? "48 8D 14 BF 48 8B 80 D0 0C 00 00 F3 0F 10 44 D0 1C F3 0F 5C 05 00 00 00 00 F3 0F 11 44 D0 1C"
                             : "48 8D 14 BF 48 8B 80 D0 0C 00 00 F3 0F 10 44 D0 18 F3 0F 5C 05 00 00 00 00 F3 0F 11 44 D0 18");
    emit_hex(m, "C3");
}

/* lane 49, round four: ENDHOLD. An end-task with the game's first bytes (ENDTASK) that sets the unit's task count
 * (+8A0h) to 0, and two callers of it (unit rcx): one the test names as the task steps' range, one outside it. */
static void emit_endtask(img_t *m)
{
    size_t h;
    align_to(m, 16, 0); m->eh_end = m->pos;
    emit_hex(m, "4C 8B DC 55 56 49 8D 6B A1 48 81 EC B8 00 00 00 4D 89 6B D8 48 8B F1 45 33 ED C6 81 25 0D 00 00 00 41 8B C5 4C 89 6D 67 48 89 81 90 08 00 00");
    emit_hex(m, "C7 81 A0 08 00 00 00 00 00 00 48 81 C4 B8 00 00 00 5E 5D C3");
    align_to(m, 16, 0); m->eh_in = m->pos;
    emit_hex(m, "48 83 EC 28 E8"); h = emit_rel_hole(m); fix_rel(m, h, m->eh_end); emit_hex(m, "48 83 C4 28 C3");
    align_to(m, 256, 0x90); m->eh_out = m->pos;
    emit_hex(m, "48 83 EC 28 E8"); h = emit_rel_hole(m); fix_rel(m, h, m->eh_end); emit_hex(m, "48 83 C4 28 C3");
}

static img_t *build_image(const opts_t *o)
{
    img_t *m = (img_t *)calloc(1, sizeof(img_t));
    IMAGE_DOS_HEADER *dos;
    IMAGE_NT_HEADERS64 *nt;
    IMAGE_SECTION_HEADER *sec;
    DWORD old;
    m->base = (uint8_t *)VirtualAlloc(NULL, IMG_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    m->text = m->base + TEXT_RVA;
    dos = (IMAGE_DOS_HEADER *)m->base;
    dos->e_magic = IMAGE_DOS_SIGNATURE; dos->e_lfanew = 0x80;
    nt = (IMAGE_NT_HEADERS64 *)(m->base + 0x80);
    nt->Signature = IMAGE_NT_SIGNATURE;
    nt->FileHeader.Machine = IMAGE_FILE_MACHINE_AMD64;
    nt->FileHeader.NumberOfSections = 2;
    nt->FileHeader.TimeDateStamp = o->known ? 0x6836C1BAu : 0x5EED0001;
    nt->FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER64);
    nt->FileHeader.Characteristics = IMAGE_FILE_EXECUTABLE_IMAGE | IMAGE_FILE_LARGE_ADDRESS_AWARE;
    nt->OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR64_MAGIC;
    nt->OptionalHeader.SizeOfImage = o->known ? 0x9DFD000u : IMG_SIZE;
    nt->OptionalHeader.SizeOfHeaders = 0x400;
    sec = IMAGE_FIRST_SECTION(nt);
    memcpy(sec[0].Name, ".text", 5); sec[0].VirtualAddress = TEXT_RVA; sec[0].Misc.VirtualSize = TEXT_SIZE;
    sec[0].Characteristics = IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ;
    memcpy(sec[1].Name, ".data", 5); sec[1].VirtualAddress = DATA_RVA; sec[1].Misc.VirtualSize = 0x1000;
    sec[1].Characteristics = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE;
    memset(m->text, 0xCC, TEXT_SIZE);
    m->pos = 0x40;
    if (!o->empty) {
        emit_stub(m);
        if (!o->no_tsr) emit_tsr(m);
        emit_reform(m);
        emit_finish(m);
        emit_burn(m);
        emit_fireout(m);
        emit_nofinish(m);
        if (o->p1_count >= 1) m->combat = emit_combat(m, o->p1_misalign, o->p1_wrong, o->p1_prepatched, &m->p1_patch);
        if (o->p1_count >= 2) m->combat2 = emit_combat(m, 0, 0, 0, &m->p1_patch2);
        emit_morale(m, o->p2_prepatched, o->p2_wrongtarget, o->no_tsr);
        emit_p3a(m);
        emit_p3b(m);
        if (o->goods) emit_goods(m, o->goods == 2);
        if (o->totals) emit_totals(m, o->totals == 2);
        if (o->cursor >= 1) { emit_cursor(m); emit_inputs(m); }
        if (o->cursor >= 2) emit_cursor(m);
        if (o->l28 >= 1) emit_l28(m);
        if (o->l28 >= 1) emit_l53(m);                 /* lane 53: with lane 28's routines */
        if (o->l28 >= 2) emit_l28_movesel(m);
        if (o->choose >= 1) emit_chooser(m, o->choose == 3);
        if (o->choose == 2) { size_t keep = m->choose_site; emit_chooser(m, 0); m->choose_site = keep; }
        if (o->hold) emit_hold(m, o->hold == 2);
        if (o->noregion >= 1) emit_noregion(m, 0, o->noregion == 3);
        if (o->noregion == 2) emit_noregion(m, 0, 0);
        if (o->noregion >= 1 && o->noregion != 4) emit_noregion(m, 1, 0);
        if (o->pick) emit_pick(m, o->pick);
        if (o->field >= 1) emit_field(m);                       /* lane 40 */
        if (o->field == 2) { size_t keep = m->fl_cache; emit_field(m); m->fl_cache = keep; }
        if (o->dist) emit_dist(m, o->dist);                  /* lane 42 */
        if (o->regset) emit_regset(m, o->regset);
        if (o->men) emit_men(m, o->men);            /* lane 43 */
        if (o->pace) emit_pace(m, o->pace);         /* lane 52 */
        if (o->setthunk && o->pick) emit_setthunk(m);
        if (o->demref && o->goods) emit_demref(m, o->demref);  /* lane 46 */
        if (o->endtask) emit_endtask(m);                        /* lane 49, round four */
        if (o->guide) { emit_guide(m, o->guide); if (o->guide == 2) { size_t keep = m->guide; emit_guide(m, 1); m->guide = keep; } }   /* lane 49 */
        if (o->fell) emit_fell(m, o->fell);         /* lane 54 */
        if (m->pos > TEXT_SIZE - 0x100) { printf("synthetic .text too small (%Iu bytes used)\n", m->pos); exit(3); }
    }
    memcpy(m->snapshot, m->text, TEXT_SIZE);
    VirtualProtect(m->base, 0x1000, PAGE_READONLY, &old);
    VirtualProtect(m->text, TEXT_SIZE, PAGE_EXECUTE_READ, &old);
    FlushInstructionCache(GetCurrentProcess(), m->text, TEXT_SIZE);
    return m;
}

/* ------------------------------------------------------------------ files */
static char g_buf[1048576];   /* the log of one scenario passed 64 KB when the item count grew (2026-11-13) */

static const char *read_file(const wchar_t *p)
{
    HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    DWORD got = 0;
    g_buf[0] = 0;
    if (h == INVALID_HANDLE_VALUE) return g_buf;
    ReadFile(h, g_buf, sizeof(g_buf) - 1, &got, NULL);
    g_buf[got] = 0;
    CloseHandle(h);
    return g_buf;
}

/* status has a line that starts with `prefix` (whole line when exact) */
static int status_line(const char *prefix, int exact)
{
    const char *s = read_file(g_status), *p = s;
    size_t n = strlen(prefix);
    while (*p) {
        const char *e = strstr(p, "\r\n");
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len >= n && strncmp(p, prefix, n) == 0 && (!exact || len == n)) return 1;
        if (!e) break;
        p = e + 2;
    }
    return 0;
}

/* lane 35: the status file holds the text anywhere */
static int status_has(const char *sub) { const char *s = read_file(g_status); return strstr(s, sub) != NULL; }
/* (lane 52) the number after <key> in the status file as it is (-1: not there) */
static long status_val(const char *key) { const char *t = read_file(g_status), *p = strstr(t, key); return p ? strtol(p + strlen(key), NULL, 10) : -1; }

static void append_raw(const char *text)
{
    FILE *f = _wfopen(g_cmd, L"ab");
    if (f) { fputs(text, f); fclose(f); }
}

static void cmd(const char *fmt, ...)
{
    char line[5000];
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf(line, sizeof(line) - 2, fmt, ap);
    line[sizeof(line) - 2] = 0;
    va_end(ap);
    strcat(line, "\n");
    append_raw(line);
    g_tick(NULL); if (g_snap) g_snap(NULL);       /* lane 47: the snapshot tick after each command, as the mod calls it each frame */
}

static void start(const char *title, img_t *m, const wchar_t *coop_name, const wchar_t *coop_role, const char *stale)
{
    printf("\n[%s]\n", title);
    SetEnvironmentVariableW(L"COOP_NAME", coop_name);
    SetEnvironmentVariableW(L"COOP_ROLE", coop_role);
    if (coop_name) _snwprintf(g_io, MAX_PATH, L"%sio\\%s\\", g_exedir, coop_name);
    else if (coop_role) _snwprintf(g_io, MAX_PATH, L"%sio\\%s\\", g_exedir, coop_role);
    else _snwprintf(g_io, MAX_PATH, L"%sio\\", g_exedir);
    _snwprintf(g_cmd, MAX_PATH, L"%spatch_cmd.txt", g_io);
    _snwprintf(g_status, MAX_PATH, L"%spatch_status.txt", g_io);
    _snwprintf(g_log, MAX_PATH, L"%scoop_patch.log", g_io);
    DeleteFileW(g_cmd); DeleteFileW(g_status);
    if (stale) append_raw(stale);
    g_tsr_calls = g_reform_calls = g_finish_calls = 0;
    g_use(m->base);
    g_tick(NULL);                               /* first tick: scan, status */
}

static int bytes_are(const uint8_t *p, const char *hex)
{
    uint8_t want[8]; int n = 0;
    while (*hex) { unsigned v; if (*hex == ' ') { hex++; continue; } sscanf(hex, "%2x", &v); want[n++] = (uint8_t)v; hex += 2; }
    return memcmp(p, want, (size_t)n) == 0;
}

static int run_combat(img_t *m, size_t f, float health, float *after)
{
    static __declspec(align(16)) uint8_t unit[0x400], args[0x500];
    int r;
    memset(unit, 0, sizeof(unit)); memset(args, 0, sizeof(args));
    memcpy(unit + 0x2E8, &health, 4);
    r = ((combat_fn)(void *)(m->text + f))(unit, args);
    memcpy(after, unit + 0x2E8, 4);
    return r;
}

/* ------------------------------------------------------------------ GOODS: buildings and the "game" that writes them */
static uint8_t *g_region;
static uint32_t g_next_index = 100;
static uint8_t *mk_building(img_t *m, int type, void *owner)
{
    uint8_t *b = (uint8_t *)VirtualAlloc(NULL, 0x2000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    garr_t *a = (garr_t *)(b + 0x448);
    if (!g_region) g_region = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    *(uint64_t *)b = (uint64_t)(uintptr_t)(m->base + DATA_RVA);             /* "vtable" inside the module */
    *(uint32_t *)(b + 0x0C) = g_next_index++;
    *(uint64_t *)(b + 0x18) = 0x700000000ull + g_next_index;
    *(void **)(b + 0x2C8) = g_region;
    *(void **)(b + 0x2E0) = owner;
    *(int32_t *)(b + 0x3B8) = type;
    a->data = (fgood_t *)calloc(INV_CAP, sizeof(fgood_t)); a->num = 0; a->max = INV_CAP;
    return b;
}
/* the game changing a building's stock: the add helper, then recountStorage, then the region's refresh */
static void game_write(img_t *m, uint8_t *b, int type, int amt, void *delta)
{
    double arg[3] = { 0.0, 0.0, 0.0 };
    fake_add_impl((garr_t *)(b + 0x448), type, amt, 1);
    ((recount_call)(void *)(m->text + m->recount))(b, 1, 1, arg);
    ((refresh_call)(void *)(m->text + m->refresh))(*(void **)(b + 0x2C8), b, 0, delta, 0);
}
/* what finishConstruction does to stock: it uses the site's goods up and hands the region its OWN list of them (the
 * site's list of materials, negated), whatever the building held */
static img_t *g_fin_m;
static int g_fin_list = 1;
static void finish_uses_up(void *b)
{
    garr_t *a = (garr_t *)((uint8_t *)b + 0x448); int i;
    for (i = 0; i < a->num; i++) a->data[i].amt = 0;
    ((refresh_call)(void *)(g_fin_m->text + g_fin_m->refresh))(*(void **)((uint8_t *)b + 0x2C8), b, 0, &g_fin_list, 0);
}
/* the mod writing stock: the game's own addToInventory, whole (what the reflected function runs) */
static void mod_write(img_t *m, uint8_t *b, int type, int amt)
{
    fgood_t g; g.type = type; g.amt = amt; g.p1 = g.p2 = NULL;
    ((addinv_call)(void *)(m->text + m->addinv))(b, &g);
}
typedef struct { img_t *m; uint8_t *b; } thr_t;
static DWORD WINAPI other_thread(LPVOID p) { thr_t *t = (thr_t *)p; game_write(t->m, t->b, 17, -2, NULL); return 0; }
static void cmd(const char *fmt, ...);
/* a counter of the status file's "goods" line (the file is rewritten on a command, not by the hooks: ask for it first) */
/* lane 47: a number of the status line that starts with "SNAP " */
static unsigned long long snap_num(const char *key)
{
    const char *s, *p, *e;
    cmd("STATUS");
    s = read_file(g_status); p = strstr(s, "\nSNAP "); if (!p) return 0;
    e = strstr(p + 1, "\r\n"); p = strstr(p, key); if (!p || (e && p > e)) return 0;
    return _strtoui64(p + strlen(key), NULL, 10);
}
static unsigned long long status_num(const char *key)
{
    const char *s, *p;
    cmd("STATUS");
    s = read_file(g_status); p = strstr(s, key);
    return p ? _strtoui64(p + strlen(key), NULL, 10) : 0;
}

/* ------------------------------------------------------------------ TOTALS: regions and the "game" that changes their totals */
typedef void (*addlist_call)(garr_t *list, const garr_t *src, int negate, int removeEmpty);
static uint8_t *mk_region(img_t *m)
{
    uint8_t *r = (uint8_t *)VirtualAlloc(NULL, 0x2000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    garr_t *t = (garr_t *)(r + 0x528);
    *(uint64_t *)r = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
    *(uint32_t *)(r + 0x0C) = g_next_index++;
    *(uint64_t *)(r + 0x18) = 0x800000000ull + g_next_index;
    t->data = (fgood_t *)calloc(TOT_CAP, sizeof(fgood_t)); t->num = 0; t->max = TOT_CAP;
    t = (garr_t *)(r + 0x538);                                      /* the totals minus what is reserved */
    t->data = (fgood_t *)calloc(TOT_CAP, sizeof(fgood_t)); t->num = 0; t->max = TOT_CAP;
    return r;
}
static int tot(uint8_t *r, int type)
{
    garr_t *t = (garr_t *)(r + 0x528); int i, n = 0;
    for (i = 0; i < t->num; i++) if (t->data[i].type == type) n += t->data[i].amt;
    return n;
}
static int tot538(uint8_t *r, int type)
{
    garr_t *t = (garr_t *)(r + 0x538); int i, n = 0;
    for (i = 0; i < t->num; i++) if (t->data[i].type == type) n += t->data[i].amt;
    return n;
}
/* sets an amount in place, as no routine of the game does (the audit's "leak") */
static void tot_put(uint8_t *r, int type, int amt)
{
    garr_t *t = (garr_t *)(r + 0x528); int i;
    for (i = 0; i < t->num; i++) if (t->data[i].type == type) { t->data[i].amt = amt; return; }
    t->data[t->num].type = type; t->data[t->num].amt = amt; t->num++;
}
static void good_one(fgood_t *d, int type, int amt) { d[0].type = type; d[0].amt = amt; d[0].p1 = d[0].p2 = NULL; }
typedef struct { img_t *m; garr_t *list; } thr_tot_t;
static DWORD WINAPI other_thread_tot(LPVOID p)
{
    thr_tot_t *t = (thr_tot_t *)p; fgood_t g; garr_t d;
    good_one(&g, 16, 1); d.data = &g; d.num = 1; d.max = 1;
    ((addlist_call)(void *)(t->m->text + t->m->addlist))(t->list, &d, 0, 1);
    return 0;
}
/* a counter of the status file's "totals" line */
static unsigned long long tot_num(const char *key)
{
    const char *s, *p;
    cmd("STATUS");
    s = read_file(g_status); p = strstr(s, "\ntotals ");
    if (!p) return 999999;
    p = strstr(p, key);
    return p ? _strtoui64(p + strlen(key), NULL, 10) : 999999;
}

/* ------------------------------------------------------------------ HOLD (lane 31): regions with approval lists and problems */
typedef void (*hreg_call)(void *r);
typedef void (*hwadd_call)(void *r, int amt);
typedef char (*hwsub_call)(void *r, int amt);
typedef char (*hpadd_call)(void *r, int type, void *b, void *u);
typedef void (*hprem_call)(void *r, int type, void *b, void *u);
typedef void (*hwmon_call)(void *r, int amt);
typedef void (*hpall_call)(void *r, int type);
static uint8_t *mk_hregion(img_t *m)
{
    uint8_t *r = mk_region(m);
    aarr_t *a; parr_t *p; int k;
    static const uint32_t offs[3] = { 0x1038, 0x1050, 0x1060 };
    for (k = 0; k < 3; k++) { a = (aarr_t *)(r + offs[k]); a->data = (amem_t *)calloc(4, sizeof(amem_t)); a->num = 0; a->max = 4; }
    p = (parr_t *)(r + 0xD80); p->data = (prob_t *)calloc(16, sizeof(prob_t)); p->num = 0; p->max = 16;
    r[0x2E8] = 1;                                         /* settled */
    *(int32_t *)(r + 0x648) = 100;                        /* regional wealth */
    *(int32_t *)(r + 0x1030) = 77; *(int32_t *)(r + 0x104C) = 80;
    return r;
}
static int nprob(uint8_t *r) { return ((parr_t *)(r + 0xD80))->num; }
static int has_prob(uint8_t *r, int type, void *b, void *u)
{
    parr_t *p = (parr_t *)(r + 0xD80); int i;
    for (i = 0; i < p->num; i++) if (p->data[i].type == type && p->data[i].building == b && p->data[i].unit == u) return 1;
    return 0;
}
typedef struct { img_t *m; uint8_t *r; } thr_hold_t;
static DWORD WINAPI other_thread_hold(LPVOID p) { thr_hold_t *t = (thr_hold_t *)p; ((hwadd_call)(void *)(t->m->text + t->m->hwadd))(t->r, 3); return 0; }
static unsigned long long hold_num(const char *key)
{
    const char *s, *p;
    cmd("STATUS");
    s = read_file(g_status); p = strstr(s, "\nhold ");
    if (!p) return 999999;
    p = strstr(p, key);
    return p ? _strtoui64(p + strlen(key), NULL, 10) : 999999;
}

/* ------------------------------------------------------------------ main */

/* lane 28: the answer file and the event file of the DRAW / ORDER commands */
static const char *l28_file(const wchar_t *name)
{
    wchar_t path[MAX_PATH];
    _snwprintf(path, MAX_PATH, L"%s%s", g_io, name);
    return read_file(path);
}
static int reply_is(const char *prefix) { const char *r = l28_file(L"patch_reply.txt"); return strncmp(r, prefix, strlen(prefix)) == 0; }
static int event_lines(void) { const char *r = l28_file(L"patch_events.txt"); int n = 0; while (*r) { if (*r == '\n') n++; r++; } return n; }
static int event_has(const char *text) { return strstr(l28_file(L"patch_events.txt"), text) != NULL; }
static void l28_reset(void)
{
    memset((void *)g_l28_calls, 0, sizeof(g_l28_calls)); memset((void *)g_l28_click_flag, 0, sizeof(g_l28_click_flag));
    g_l28_block_at = -1; g_l28_fault_in = -1; g_l28_pawn = NULL; g_l28_wp = g_l28_na = g_l28_moved_seen = -1;
}
static void l28_pawn_init(uint8_t *pawn, img_t *m, int32_t *squads, int nsq)
{
    tarr_t a;
    memset(pawn, 0, 0x2000);
    *(uint64_t *)pawn = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
    a.data = (uint8_t *)g_l28_rp; a.num = 0; a.max = 64; memcpy(pawn + 0x780, &a, sizeof(a));
    a.data = g_l28_way; a.num = 0; a.max = 64; memcpy(pawn + 0xCA8, &a, sizeof(a));
    a.data = (uint8_t *)squads; a.num = nsq; a.max = nsq; memcpy(pawn + 0x550, &a, sizeof(a));
}
typedef void (*movesel_call)(void *pawn, unsigned char wp, unsigned char na);
typedef struct { img_t *m; uint8_t *pawn; } thr28_t;
static DWORD WINAPI l28_other_thread(void *arg)
{
    thr28_t *t = (thr28_t *)arg;
    ((movesel_call)(void *)(t->m->text + t->m->l28_movesel))(t->pawn, 0, 0);
    return 0;
}

/* ------------------------------------------------------------------ lane 61: REPORT, the bug report */
static void rp_utf8(const wchar_t *w, char *out, int cap) { WideCharToMultiByte(CP_UTF8, 0, w, -1, out, cap, NULL, NULL); }
static void rp_write(const wchar_t *path, const char *text) { FILE *f = _wfopen(path, L"wb"); if (f) { fputs(text, f); fclose(f); } }
static void rp_rmdir(const wchar_t *dir)          /* the test's own report folder: its files, then the folder */
{
    wchar_t pat[MAX_PATH], p[MAX_PATH];
    WIN32_FIND_DATAW fd;
    HANDLE h;
    _snwprintf(pat, MAX_PATH, L"%s*", dir);
    h = FindFirstFileW(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do { if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) { _snwprintf(p, MAX_PATH, L"%s%s", dir, fd.cFileName); DeleteFileW(p); } } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryW(dir);
}
/* ticks until the status's REPORT line is no longer "running" (the report's own thread is done), at most 30 s */
static int rp_wait(void)
{
    int i;
    for (i = 0; i < 600; i++) { cmd("STATUS"); if (status_has("REPORT ") && !status_has("REPORT running")) return 1; Sleep(50); }
    return 0;
}
static long long rp_size(const wchar_t *p) { WIN32_FILE_ATTRIBUTE_DATA a; if (!GetFileAttributesExW(p, GetFileExInfoStandard, &a)) return -1; return ((long long)a.nFileSizeHigh << 32) | a.nFileSizeLow; }

static void test_report(void)
{
    opts_t o = { 1 };
    img_t *m = build_image(&o);
    wchar_t src1[MAX_PATH], src2[MAX_PATH], job[MAX_PATH], reports[MAX_PATH], d1[MAX_PATH], p[MAX_PATH], zip[MAX_PATH], oldUser[256], oldProf[MAX_PATH];
    char s1[MAX_PATH * 3], s2[MAX_PATH * 3], text[4096];
    const char *t;
    FILE *f;
    int i;
    DWORD nu = GetEnvironmentVariableW(L"USERNAME", oldUser, 256), np = GetEnvironmentVariableW(L"USERPROFILE", oldProf, MAX_PATH);
    /* a user name with a space and a profile folder in its short form (both are seen on real PCs) */
    SetEnvironmentVariableW(L"USERNAME", L"Test Person");
    SetEnvironmentVariableW(L"USERPROFILE", L"C:\\Users\\TESTPE~1");
    _snwprintf(src1, MAX_PATH, L"%srp_src1.txt", g_exedir);
    _snwprintf(src2, MAX_PATH, L"%srp_src2.txt", g_exedir);
    _snwprintf(reports, MAX_PATH, L"%slink\\reports\\", g_exedir);
    _snwprintf(d1, MAX_PATH, L"%sreport_r1-test\\", reports);
    rp_rmdir(d1);
    _snwprintf(p, MAX_PATH, L"%sreport_r2-test\\", reports); rp_rmdir(p);
    _snwprintf(zip, MAX_PATH, L"%sreport_r2-test.zip", reports); DeleteFileW(zip);
    rp_write(src1,
        "a C:\\Users\\Real Name\\AppData\\Local\\x.txt b\r\n"
        "c D:\\Games\\Test Person\\ManorLords and /c/users/Someone/y and D:\\Games\\test person\r\n"
        "d C:\\Users\\TESTPE~1\\AppData e\r\n"
        "f id 76561198012345678 end, 176561198012345678 stays, 7656119801234567 stays\r\n"
        "g Wilhelmina joined; wilhelmina again; Bo stays\r\n");
    f = _wfopen(src2, L"wb");
    for (i = 0; i < 40000; i++) fprintf(f, "line %06d of a long log, nothing private in it ..........................\r\n", i);
    fclose(f);
    rp_utf8(src1, s1, sizeof(s1)); rp_utf8(src2, s2, sizeof(s2));

    start("RP1: REPORT, folder only (zip 0): every copy scrubbed, a long file cut in the middle", m, NULL, NULL, NULL);
    check(status_line("REPORT idle", 1), "status has 'REPORT idle' before any report");
    check(GetFileAttributesW(reports) != INVALID_FILE_ATTRIBUTES, "the first tick made link\\reports (and link\\sessions) in the DLL's own folder");
    _snwprintf(p, MAX_PATH, L"%slink\\sessions", g_exedir);
    check(GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES, "link\\sessions is there");
    _snwprintf(job, MAX_PATH, L"%spatch_report_job.txt", g_io);
    _snprintf(text, sizeof(text), "open 0\nzip 0\nname Wilhelmina\tfriend 1\nname Bo\tfriend 2\nfile %s\tcopy1.txt\t0\nfile %s\tbig.txt\t1048576\nfile %s.none\tmissing.txt\t0\nfile %s\tfrom2.txt\t0\t%u\n",
              s1, s2, s1, s1, (unsigned)strlen("a C:\\Users\\Real Name\\AppData\\Local\\x.txt b\r\n"));
    rp_write(job, text);
    cmd("REPORT r1-test");
    check(rp_wait(), "the report's thread finished within 30 s");
    if (!status_line("REPORT folder report_r1-test 3 no zip asked", 1)) printf("%s\n", read_file(g_status));
    check(status_line("REPORT folder report_r1-test 3 no zip asked", 1), "status: folder kept, 3 files copied (the missing one skipped), not opened");
    _snwprintf(p, MAX_PATH, L"%sfrom2.txt", d1);
    t = read_file(p);
    check(strncmp(t, "c D:\\Games\\<user>\\ManorLords", 28) == 0 && strstr(t, "Real Name") == NULL && strstr(t, "AppData\\Local\\x.txt") == NULL,
          "a file asked from a byte on: the lines above it are left out (an earlier run's lines that could not be moved)");
    _snwprintf(p, MAX_PATH, L"%scopy1.txt", d1);
    t = read_file(p);
    check(strstr(t, "a C:\\Users\\<user>\\AppData\\Local\\x.txt b") != NULL, "the folder after \\Users\\ is <user> (any name)");
    check(strstr(t, "D:\\Games\\<user>\\ManorLords") != NULL && strstr(t, "D:\\Games\\<user>\r\n") != NULL, "USERNAME after a separator is <user>, also in another case and at the end of a line");
    check(strstr(t, "/c/users/<user>/y") != NULL, "a / path with lower-case users is scrubbed too");
    check(strstr(t, "d C:\\Users\\<user>\\AppData e") != NULL, "the short profile folder (TESTPE~1) is <user>");
    check(strstr(t, "id <id..5678> end, 176561198012345678 stays, 7656119801234567 stays") != NULL, "a Steam id keeps its last 4 digits; a longer or shorter number stays");
    check(strstr(t, "g friend 1 joined; friend 1 again; Bo stays") != NULL, "a Steam name (any case) becomes its slot; a name under 3 letters is left");
    check(strstr(t, "Real Name") == NULL && strstr(t, "Test Person") == NULL && strstr(t, "Someone") == NULL && strstr(t, "Wilhelmina") == NULL, "none of the names is left in the copy");
    _snwprintf(p, MAX_PATH, L"%sbig.txt", d1);
    {
        long long sz = rp_size(p), full = rp_size(src2);
        t = read_file(p);
        check(full > 3000000 && sz > 1000000 && sz < 1100000, "a 3 MB file with a 1 MB cap is cut to about 1 MB (%lld of %lld bytes)", sz, full);
        check(strncmp(t, "line 000000 ", 12) == 0 && strstr(t, "MB of this file are left out here") != NULL, "its start is kept, then the note of what was left out");
        f = _wfopen(p, L"rb");
        if (f) { char tail[200] = { 0 }; size_t got; _fseeki64(f, -(long long)sizeof(tail) + 1, SEEK_END); got = fread(tail, 1, sizeof(tail) - 1, f); tail[got] = 0; fclose(f);
                 check(strstr(tail, "line 039999 ") != NULL, "its end is kept (the last line)"); }
        t = read_file(p);
        {   const char *nt = strstr(t, "left out here");
            const char *nl = nt ? strstr(nt, "...\r\n") : NULL;
            check(nl && strncmp(nl + 5, "line ", 5) == 0, "the end starts at a whole line"); }
    }
    _snwprintf(p, MAX_PATH, L"%smissing.txt", d1);
    check(GetFileAttributesW(p) == INVALID_FILE_ATTRIBUTES, "no file for a missing source");

    start("RP2: REPORT, the zip (Windows' own tar.exe, no window); the folder goes", m, NULL, NULL, NULL);
    _snprintf(text, sizeof(text), "open 0\nfile %s\tcopy1.txt\t0\nfile %s\tbig.txt\t1048576\n", s1, s2);
    rp_write(job, text);
    cmd("REPORT r2-test");
    check(rp_wait(), "the report's thread finished within 30 s");
    if (!status_line("REPORT done report_r2-test.zip 2", 1)) printf("%s\n", read_file(g_status));
    check(status_line("REPORT done report_r2-test.zip 2", 1), "status: done, the zip's name, 2 files, not opened");
    t = read_file(zip);
    check(rp_size(zip) > 1000 && memcmp(t, "PK\x03\x04", 4) == 0, "report_r2-test.zip is a zip (%lld bytes)", rp_size(zip));
    {   long long n = rp_size(zip); int found1 = 0, found2 = 0; long long k;
        for (k = 0; k + 9 < n && k < (long long)sizeof(g_buf) - 10; k++) { if (memcmp(g_buf + k, "copy1.txt", 9) == 0) found1 = 1; if (memcmp(g_buf + k, "big.txt", 7) == 0) found2 = 1; }
        check(found1 && found2, "the zip names copy1.txt and big.txt"); }
    _snwprintf(p, MAX_PATH, L"%sreport_r2-test", reports);
    check(GetFileAttributesW(p) == INVALID_FILE_ATTRIBUTES, "the folder the zip was made of is removed");
    t = read_file(g_log);
    check(strstr(t, "REPORT done report_r2-test.zip 2") != NULL, "coop_patch.log has the result line");

    start("RP3: REPORT refusals; the DLL's own log lines are scrubbed", m, NULL, NULL, NULL);
    cmd("REPORT ../up");
    check(status_line("REPORT refused - needs REPORT <stamp>", 0), "a stamp with a path in it is refused");
    _snprintf(text, sizeof(text), "open 0\nzip 0\nfile %s\t..\\..\\evil.txt\t0\n", s1);
    rp_write(job, text);
    cmd("REPORT r3-test");
    check(status_line("REPORT refused report_r3-test a file name in the job is not a plain name", 1), "a copy name with a path in it refuses the whole job");
    _snwprintf(p, MAX_PATH, L"%sreport_r3-test", reports);
    check(GetFileAttributesW(p) == INVALID_FILE_ATTRIBUTES, "and no folder was made for it");
    _snprintf(text, sizeof(text), "open 0\nzip 0\nfile %s\tcopy1.txt\t0\n", s1);
    rp_write(job, text);
    CreateDirectoryW(d1, NULL);
    cmd("REPORT r1-test");
    check(status_line("REPORT refused report_r1-test a report of that name is there already", 1), "a report of a name that is there already is refused (nothing overwritten)");
    cmd("STATUS C:\\Users\\Real Name\\x and D:\\Games\\Test Person\\y");
    t = read_file(g_log);
    check(strstr(t, "command: STATUS C:\\Users\\<user>\\x and D:\\Games\\<user>\\y") != NULL && strstr(t, "Real Name") == NULL && strstr(t, "Test Person") == NULL,
          "coop_patch.log: a path in a logged line has <user> in place of the user name");

    rp_rmdir(d1);
    DeleteFileW(zip); DeleteFileW(src1); DeleteFileW(src2); DeleteFileW(job);
    SetEnvironmentVariableW(L"USERNAME", nu ? oldUser : NULL);
    SetEnvironmentVariableW(L"USERPROFILE", np ? oldProf : NULL);
}


int main(void)
{
    wchar_t dll[MAX_PATH], cfg[MAX_PATH];
    HMODULE h;
    wchar_t *sl;
    FILE *f;
    uint8_t *comp, *badvt, *reserved, *bld, *bldfault, *bldshort;
    unsigned long long good;
    float hp;
    char p2orig[8];

    setvbuf(stdout, NULL, _IONBF, 0);       /* lane 35: every line out before a fault */
    GetModuleFileNameW(NULL, g_exedir, MAX_PATH);
    sl = wcsrchr(g_exedir, L'\\'); sl[1] = 0;
    _snwprintf(dll, MAX_PATH, L"%scoop_patch.dll", g_exedir);
    _snwprintf(cfg, MAX_PATH, L"%scoop_patch.cfg", g_exedir);
    f = _wfopen(cfg, L"wb"); fputs("# test only\r\ndir = io\r\n", f); fclose(f);     /* tests the dir= override */
    {   wchar_t io[MAX_PATH]; _snwprintf(io, MAX_PATH, L"%sio", g_exedir); CreateDirectoryW(io, NULL); }
    { wchar_t lg[MAX_PATH]; _snwprintf(lg, MAX_PATH, L"%sio\\coop_patch.log", g_exedir); DeleteFileW(lg);
      _snwprintf(lg, MAX_PATH, L"%sio\\t2\\coop_patch.log", g_exedir); DeleteFileW(lg); }

    h = LoadLibraryW(dll);
    if (!h) { printf("cannot load %ls\n", dll); return 2; }
    g_tick = (tick_fn)(void *)GetProcAddress(h, "coop_patch_tick");
    g_snap = (tick_fn)(void *)GetProcAddress(h, "coop_snap_tick");
    g_guard = (tick_fn)(void *)GetProcAddress(h, "coop_guard_tick");
    g_use = (use_fn)(void *)GetProcAddress(h, "coop_patch_test_use_module");
    if (!g_tick || !g_use) { printf("exports missing (is this the test build?)\n"); return 2; }

    /* fake SquadComponent objects: a good one (first qword = a "vtable" inside the synthetic image), one with a bad
     * vtable, and an address that is reserved but not committed */
    comp = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    badvt = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    reserved = (uint8_t *)VirtualAlloc(NULL, 0x10000, MEM_RESERVE, PAGE_READWRITE);
    /* buildings: a good one, one marked to fault, and one whose object runs off the end of committed memory */
    bld = (uint8_t *)VirtualAlloc(NULL, 0x2000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    bldfault = (uint8_t *)VirtualAlloc(NULL, 0x2000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    bldshort = (uint8_t *)VirtualAlloc(NULL, 0x10000, MEM_RESERVE, PAGE_READWRITE);
    VirtualAlloc(bldshort, 0x1000, MEM_COMMIT, PAGE_READWRITE);
    bldshort += 0x1000 - 0x100;          /* 0x100 readable bytes, then uncommitted */
    *(uint32_t *)(bldfault + 8) = 0xDEAD;
    *(uint64_t *)badvt = 0x123456789ABCDEF0ull;

    /* ======================================================== A: a good module */
    {
        opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0 };
        img_t *m = build_image(&o);
        squad_call morale = (squad_call)(void *)(m->text + m->morale);
        squad_call p3a = (squad_call)(void *)(m->text + m->p3a);
        squad_call p3b = (squad_call)(void *)(m->text + m->p3b);
        *(uint64_t *)comp = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
        good = (unsigned long long)(uintptr_t)comp;
        start("A: good synthetic module (a stale 'NOKILL ON' already in patch_cmd.txt)", m, NULL, NULL, "NOKILL ON\n");
        check(status_line("ready 5EED0001 20000", 1), "status line 1 is 'ready <timestamp> <size>' of the synthetic module");
        check(status_line("P1 off", 1) && status_line("P2 off", 1) && status_line("P3a off", 1) && status_line("P3b off", 1), "P1 P2 P3a P3b off after the scan");
        check(status_line("ROUT available", 1) && status_line("REFORM available", 1) && status_line("FINISH available", 1), "ROUT, REFORM and FINISH available");
        check(status_line("calls rout=0 reform=0 finish=0 burn=0 fireout=0 failed=0", 1), "counter line present");
        check(status_line("GOODS unavailable RECOUNT signature has 0 hits (need exactly 1)", 1), "GOODS unavailable in a module without recountStorage; the other items are unaffected");
        check(status_line("TOTALS unavailable ADDLIST signature has 0 hits (need exactly 1)", 1), "TOTALS unavailable in a module without ADDLIST (another game build); nothing of it is written");
        check(bytes_are(m->text + m->p1_patch, "74 1C"), "the stale NOKILL ON from before the first tick was skipped");
        check(strstr(read_file(g_log), "game build differs") != NULL, "log notes the build differs from the known one");
        check(strstr(read_file(g_log), "skipped") != NULL, "log notes the skipped old commands");

        check(run_combat(m, m->combat, -5.0f, &hp) == 2, "combat(health -5) unpatched takes the kill path");
        g_tsr_calls = 0; morale(comp, 11);
        check(g_tsr_calls == 1 && g_tsr_h == 11 && g_tsr_comp == comp, "morale() unpatched calls TriggerSquadRetreat(comp, 11)");
        g_reform_calls = 0; p3a(comp, 12); p3b(comp, 13);
        check(g_reform_calls == 2 && g_reform_h == 13, "p3a()/p3b() unpatched call reformSquad");

        cmd("NOKILL ON");
        check(bytes_are(m->text + m->p1_patch, "66 90"), "NOKILL ON wrote 66 90");
        check(status_line("P1 on", 1), "status P1 on");
        check(run_combat(m, m->combat, -5.0f, &hp) == 1 && hp == 1.0f, "combat(health -5) now leaves health = 1.0 (avoidKilling branch)");
        check(run_combat(m, m->combat, 50.0f, &hp) == 0 && hp == 50.0f, "combat(health 50) still the alive path");
        cmd("NOKILL ON");
        check(strstr(read_file(g_log), "P1 already on") != NULL, "NOKILL ON twice: 'already on', nothing written");
        cmd("NOKILL OFF");
        check(bytes_are(m->text + m->p1_patch, "74 1C") && run_combat(m, m->combat, -5.0f, &hp) == 2, "NOKILL OFF restored 74 1C, kill path back");
        check(status_line("P1 off", 1), "status P1 off");

        memcpy(p2orig, m->text + m->p2_patch, 2);
        cmd("NOROUT ON");
        check(bytes_are(m->text + m->p2_patch, "EB 03"), "NOROUT ON wrote EB 03");
        g_tsr_calls = 0; morale(comp, 21);
        check(g_tsr_calls == 0, "morale() no longer calls TriggerSquadRetreat");
        check(status_line("P2 on", 1), "status P2 on");
        cmd("NOROUT OFF");
        check(memcmp(m->text + m->p2_patch, p2orig, 2) == 0, "NOROUT OFF restored E8 + the original low byte");
        g_tsr_calls = 0; morale(comp, 22);
        check(g_tsr_calls == 1 && g_tsr_h == 22, "morale() calls TriggerSquadRetreat again with the right arguments");

        cmd("NOREFORM ON");
        check(bytes_are(m->text + m->p3a_patch, "EB 03") && bytes_are(m->text + m->p3b_patch, "EB 03"), "NOREFORM ON wrote EB 03 at P3a and P3b");
        g_reform_calls = 0; p3a(comp, 31); p3b(comp, 32);
        check(g_reform_calls == 0, "p3a()/p3b() no longer call reformSquad");
        check(status_line("P3a on", 1) && status_line("P3b on", 1), "status P3a on, P3b on");
        cmd("NOREFORM OFF");
        g_reform_calls = 0; p3a(comp, 33); p3b(comp, 34);
        check(g_reform_calls == 2, "NOREFORM OFF: both calls back");

        cmd("NOKILL ON"); cmd("NOROUT ON"); cmd("NOREFORM ON");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) != 0, "three patches on: .text differs from the original");
        cmd("ALLOFF");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "ALLOFF: the whole .text is byte-identical to the original again");
        check(status_line("P1 off", 1) && status_line("P2 off", 1) && status_line("P3a off", 1) && status_line("P3b off", 1), "status: all off");

        append_raw("NOKILL O"); g_tick(NULL);
        check(bytes_are(m->text + m->p1_patch, "74 1C"), "a line without its newline is not consumed");
        append_raw("N\r\n"); g_tick(NULL);
        check(bytes_are(m->text + m->p1_patch, "66 90"), "once the newline arrives the whole line runs (CRLF accepted)");
        cmd("NOKILL OFF");
        {   /* truncation: the mod (or the player) empties the file and writes a shorter one */
            FILE *t = _wfopen(g_cmd, L"wb"); fputs("NOKILL ON\n", t); fclose(t); g_tick(NULL);
            check(bytes_are(m->text + m->p1_patch, "66 90"), "patch_cmd.txt truncated and rewritten shorter: read again from 0");
            cmd("NOKILL OFF");
        }
        cmd("nokill on");
        check(bytes_are(m->text + m->p1_patch, "66 90"), "commands are case-insensitive");
        cmd("NOKILL OFF");

        g_tsr_calls = 0;
        cmd("ROUT");
        cmd("ROUT %llu", good);
        cmd("ROUT 0 5");
        cmd("ROUT %llu 5", good + 4);
        cmd("ROUT %llu 5", (unsigned long long)(uintptr_t)reserved);
        cmd("ROUT %llu 5", (unsigned long long)(uintptr_t)badvt);
        cmd("ROUT %llu 4294967296", good);
        cmd("ROUT abc 5");
        cmd("ROUT %llu 0", good);
        cmd("ROUT %llu 5 9", good);
        check(g_tsr_calls == 0, "ROUT refused 10 bad forms (no args, 1 arg, null, unaligned, uncommitted, bad vtable, handle > int32, not a number, handle 0, 3 args)");
        check(status_line("calls rout=0 reform=0 finish=0 burn=0 fireout=0 failed=10", 1), "failed=10 counted");
        {   const char *lg = read_file(g_log);
            check(strstr(lg, "not 8-aligned") && strstr(lg, "not committed readable") && strstr(lg, "no vtable in the game module") &&
                  strstr(lg, "needs exactly 2 arguments") && strstr(lg, "not a 32-bit integer"), "log gives a plain reason for each refusal"); }

        cmd("ROUT %llu 42", good);
        check(g_tsr_calls == 1 && g_tsr_comp == comp && g_tsr_h == 42, "ROUT <decimal address> 42 called TriggerSquadRetreat(comp, 42) once");
        cmd("ROUT 0x%llX -7", good);
        check(g_tsr_calls == 2 && g_tsr_h == -7, "ROUT <0x hex address> -7 called it again with handle -7");
        g_reform_calls = 0;
        cmd("REFORM %llu 7", good);
        check(g_reform_calls == 1 && g_reform_comp == comp && g_reform_h == 7, "REFORM called reformSquad(comp, 7) once");
        check(status_line("calls rout=2 reform=1 finish=0 burn=0 fireout=0 failed=10", 1), "counters rout=2 reform=1");

        cmd("ROUT %llu %d", good, 0xDEAD);
        check(g_tsr_calls == 3, "ROUT with a faulting target: the target ran");
        check(status_line("ROUT unavailable", 0), "the exception was caught, ROUT marked unavailable, this process is alive");
        check(status_line("REFORM available", 1), "REFORM still available");
        cmd("ROUT %llu 44", good);
        check(g_tsr_calls == 3, "ROUT is no longer called after the exception");
        check(status_line("ready", 0), "an exception in a game call does not switch the DLL off");

        /* FINISH <building address>: finishConstruction(SMBuildingMaster*) */
        *(uint64_t *)bld = *(uint64_t *)bldfault = *(uint64_t *)bldshort = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
        g_finish_calls = 0;
        cmd("FINISH");
        cmd("FINISH %llu 5", (unsigned long long)(uintptr_t)bld);
        cmd("FINISH 0");
        cmd("FINISH %llu", (unsigned long long)(uintptr_t)bld + 4);
        cmd("FINISH %llu", (unsigned long long)(uintptr_t)reserved);
        cmd("FINISH %llu", (unsigned long long)(uintptr_t)badvt);
        cmd("FINISH %llu", (unsigned long long)(uintptr_t)bldshort);
        cmd("FINISH xyz");
        check(g_finish_calls == 0, "FINISH refused 8 bad forms (no arg, 2 args, null, unaligned, uncommitted, bad vtable, object running off committed memory, not a number)");
        check(status_line("calls rout=2 reform=1 finish=0 burn=0 fireout=0 failed=20", 1), "failed counted (12 + 8)");
        check(strstr(read_file(g_log), "FINISH refused: needs exactly 1 argument") != NULL, "log: FINISH needs exactly 1 argument");
        cmd("FINISH %llu", (unsigned long long)(uintptr_t)bld);
        check(g_finish_calls == 1 && g_finish_b == bld, "FINISH <decimal address> called finishConstruction(building) once with the right pointer");
        cmd("FINISH 0x%llX", (unsigned long long)(uintptr_t)bld);
        check(g_finish_calls == 2, "FINISH <0x hex address> called it again");
        check(status_line("calls rout=2 reform=1 finish=2 burn=0 fireout=0 failed=20", 1), "counter finish=2");
        cmd("FINISH %llu", (unsigned long long)(uintptr_t)bldfault);
        check(g_finish_calls == 3, "FINISH with a faulting target: the target ran");
        check(status_line("FINISH unavailable", 0), "the exception was caught, FINISH marked unavailable, this process is alive");
        check(status_line("REFORM available", 1) && status_line("ready", 0), "REFORM still available, the DLL still ready");
        cmd("FINISH %llu", (unsigned long long)(uintptr_t)bld);
        check(g_finish_calls == 3, "FINISH is no longer called after the exception");
        check(status_line("calls rout=2 reform=1 finish=2 burn=0 fireout=0 failed=22", 1), "counters after the exception");

        /* BURN <building address>: progressFire(building, 1e6); refused unless the building's onFire byte (+0x388) is set */
        check(status_line("BURN available", 1) && status_line("FIREOUT available", 1), "BURN and FIREOUT available");
        g_burn_calls = g_fireout_calls = 0;
        bld[0x388] = 0;
        cmd("BURN %llu", (unsigned long long)(uintptr_t)bld);
        check(g_burn_calls == 0, "BURN refused for a building that is not on fire");
        check(strstr(read_file(g_log), "BURN refused: the building is not on fire") != NULL, "log: BURN refused, not on fire");
        cmd("BURN"); cmd("BURN 0"); cmd("BURN %llu", (unsigned long long)(uintptr_t)bldshort);
        check(g_burn_calls == 0, "BURN refused 3 bad forms (no arg, null, object running off committed memory)");
        bld[0x388] = 1;
        cmd("BURN %llu", (unsigned long long)(uintptr_t)bld);
        check(g_burn_calls == 1 && g_burn_b == bld && g_burn_dt == 1000000.0f, "BURN called progressFire(building, 1e6) once with the right pointer");
        /* FIREOUT <building address>: extinguishFire(building) */
        cmd("FIREOUT"); cmd("FIREOUT 0"); cmd("FIREOUT %llu", (unsigned long long)(uintptr_t)bldshort);
        check(g_fireout_calls == 0, "FIREOUT refused 3 bad forms");
        cmd("FIREOUT %llu", (unsigned long long)(uintptr_t)bld);
        check(g_fireout_calls == 1 && g_fireout_b == bld, "FIREOUT called extinguishFire(building) once with the right pointer");
        check(status_line("calls rout=2 reform=1 finish=2 burn=1 fireout=1 failed=29", 1), "counters burn=1 fireout=1 failed=29 (22 + 1 + 3 + 3)");
        bld[0x388] = 0;

        /* NOFINISH ON|OFF: the game's two own calls to finishConstruction are jumped over (je -> jmp), both or neither */
        check(status_line("NF1 off", 1) && status_line("NF2 off", 1), "NF1 and NF2 found exactly once, off");
        cmd("NOFINISH ON");
        check(bytes_are(m->text + m->nf1_patch, "EB 08") && bytes_are(m->text + m->nf2_patch, "EB 50"), "NOFINISH ON wrote EB 08 and EB 50");
        check(status_line("NF1 on", 1) && status_line("NF2 on", 1), "status NF1 on, NF2 on");
        cmd("NOFINISH OFF");
        check(bytes_are(m->text + m->nf1_patch, "74 08") && bytes_are(m->text + m->nf2_patch, "74 50"), "NOFINISH OFF restored 74 08 and 74 50");
        cmd("NOFINISH ON"); cmd("ALLOFF");
        check(bytes_are(m->text + m->nf1_patch, "74 08") && bytes_are(m->text + m->nf2_patch, "74 50") && status_line("NF1 off", 1) && status_line("NF2 off", 1), "ALLOFF restores NF1 and NF2");

        /* lane 19: JOBGATE ON|OFF (one je -> jmp in executeTask) */
        check(status_line("JG off", 1), "JG found exactly once, off");
        cmd("JOBGATE ON");
        check(bytes_are(m->text + m->jg_patch, "EB 11") && status_line("JG on", 1), "JOBGATE ON wrote EB 11, status JG on");
        cmd("JOBGATE OFF");
        check(bytes_are(m->text + m->jg_patch, "74 11") && status_line("JG off", 1), "JOBGATE OFF restored 74 11");
        cmd("JOBGATE ON"); cmd("ALLOFF");
        check(bytes_are(m->text + m->jg_patch, "74 11") && status_line("JG off", 1), "ALLOFF restores JG");

        cmd("NOKILL ON"); cmd("NOROUT ON");
        cmd("TESTFAULT");
        check(status_line("ready", 0), "1 internal failure: still ready");
        cmd("TESTFAULT");
        check(status_line("ready", 0), "2 internal failures: still ready");
        cmd("TESTFAULT");
        check(status_line("off 3 internal failures", 1), "3 internal failures: status 'off'");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "going off restored every patched byte");
        cmd("NOKILL ON");
        check(bytes_are(m->text + m->p1_patch, "74 1C"), "while off, NOKILL ON is ignored");
        DeleteFileW(g_status);
        cmd("STATUS");
        check(status_line("off 3 internal failures", 1), "while off, STATUS still rewrites the status file");
        check(status_line("ROUT unavailable dll is off", 1), "while off, ROUT reported unavailable");
    }

    /* ======================================================== B: duplicate P1 pattern, COOP_NAME subfolder */
    {
        opts_t o = { 2, 0, 0, 0, 0, 0, 0, 0 };
        img_t *m = build_image(&o);
        start("B: P1 pattern twice (COOP_NAME=t2: files go to io\\t2\\)", m, L"t2", L"friend", NULL);
        check(GetFileAttributesW(g_status) != INVALID_FILE_ATTRIBUTES, "status file written in the COOP_NAME subfolder");
        check(status_line("P1 unavailable signature has 2 hits", 0), "P1 unavailable: 2 hits");
        check(status_line("P2 off", 1) && status_line("ROUT available", 1), "the other items are unaffected");
        cmd("NOKILL ON");
        check(bytes_are(m->text + m->p1_patch, "74 1C") && bytes_are(m->text + m->p1_patch2, "74 1C"), "NOKILL ON wrote nothing at either copy");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, ".text untouched");
    }

    /* ======================================================== C: wrong original byte, wrong call target */
    {
        opts_t o = { 1, 0, 1, 0, 0, 1, 0, 0 };
        img_t *m = build_image(&o);
        start("C: P1 has 74 1D instead of 74 1C; P2's call goes somewhere else (COOP_ROLE=host only: files go to io\\host\\)", m, NULL, L"host", NULL);
        check(GetFileAttributesW(g_status) != INVALID_FILE_ATTRIBUTES, "without COOP_NAME the COOP_ROLE subfolder is used");
        check(status_line("P1 unavailable", 0), "P1 unavailable (wrong original byte)");
        check(status_line("P2 unavailable call goes to", 0), "P2 unavailable (call target is not TriggerSquadRetreat)");
        check(status_line("P3a off", 1) && status_line("P3b off", 1), "P3a/P3b unaffected");
        cmd("NOKILL ON"); cmd("NOROUT ON");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "NOKILL ON / NOROUT ON wrote nothing");
    }

    /* ======================================================== D: patch across an 8-byte block */
    {
        opts_t o = { 1, 1, 0, 0, 0, 0, 0, 0 };
        img_t *m = build_image(&o);
        start("D: P1 patch placed across an aligned 8-byte block", m, NULL, NULL, NULL);
        check(((uintptr_t)(m->text + m->p1_patch) & 7) == 7, "(setup) the patch really starts at the last byte of a block");
        check(status_line("P1 unavailable patch at rva", 0) && strstr(read_file(g_status), "crosses an 8-byte block") != NULL, "P1 unavailable: crosses an 8-byte block");
        cmd("NOKILL ON");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "NOKILL ON wrote nothing");
    }

    /* ======================================================== E: already patched (e.g. by an earlier copy of the DLL) */
    {
        opts_t o = { 1, 0, 0, 1, 1, 0, 0, 0 };
        img_t *m = build_image(&o);
        squad_call morale = (squad_call)(void *)(m->text + m->morale);
        start("E: P1 and P2 already patched in memory", m, NULL, NULL, NULL);
        check(status_line("P1 on", 1) && status_line("P2 on", 1), "found as 'on'");
        check(run_combat(m, m->combat, -5.0f, &hp) == 1, "(setup) combat behaves patched");
        cmd("NOKILL OFF");
        check(bytes_are(m->text + m->p1_patch, "74 1C") && run_combat(m, m->combat, -5.0f, &hp) == 2, "NOKILL OFF wrote 74 1C, kill path back");
        cmd("NOROUT OFF");
        g_tsr_calls = 0; *(uint64_t *)comp = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
        morale(comp, 51);
        check(m->text[m->p2_patch] == 0xE8 && g_tsr_calls == 1 && g_tsr_h == 51, "NOROUT OFF rebuilt the call byte from the TSR hit: the call works");
    }

    /* ======================================================== F: TriggerSquadRetreat missing */
    {
        opts_t o = { 1, 0, 0, 0, 0, 0, 1, 0 };
        img_t *m = build_image(&o);
        start("F: no TriggerSquadRetreat in the module", m, NULL, NULL, NULL);
        check(status_line("P2 unavailable call target TSR has 0 hits", 1), "P2 unavailable: its call target is missing");
        check(status_line("ROUT unavailable entry signature has 0 hits", 1), "ROUT unavailable");
        check(status_line("REFORM available", 1) && status_line("P1 off", 1), "REFORM and P1 unaffected");
        *(uint64_t *)comp = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
        cmd("ROUT %llu 5", (unsigned long long)(uintptr_t)comp);
        check(status_line("calls rout=0 reform=0 finish=0 burn=0 fireout=0 failed=1", 1), "ROUT refused");
    }

    /* ======================================================== G: nothing matches */
    {
        opts_t o = { 0, 0, 0, 0, 0, 0, 0, 1 };
        img_t *m = build_image(&o);
        start("G: a module where nothing matches (a game update that moved everything)", m, NULL, NULL, NULL);
        check(status_line("off nothing matches this game build (timestamp 5EED0001)", 1), "status 'off nothing matches this game build'");
        check(status_line("P1 unavailable signature has 0 hits", 0), "items say why");
        cmd("NOKILL ON");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "nothing written");
    }

    /* ======================================================== H: GOODS, the outcome switch for building stock */
    {
        opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 1 };
        img_t *m = build_image(&o);
        uint8_t *lord = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        uint8_t *b1 = mk_building(m, 72, NULL), *b2 = mk_building(m, 18, NULL), *b3 = mk_building(m, 80, lord);
        uint8_t *pile = mk_building(m, 0x58, NULL), *notpile = mk_building(m, 72, NULL);
        garr_t *a1 = (garr_t *)(b1 + 0x448);
        int delta_dummy = 1;
        unsigned long long n0;
        start("H: GOODS on a module with recountStorage, refreshBuildingStorageCache and addToInventory", m, NULL, NULL, NULL);
        check(status_line("GOODS off", 1), "status GOODS off after the scan");
        check(status_line("goods frozen=0 calls=0", 0), "status has the goods counter line");
        mod_write(m, b1, 17, 5);
        check(stock(b1, 17) == 5 && g_rc_calls == 1 && g_rf_calls == 1 && g_rc_b == b1 && g_rc_dl == 0 && g_rc_flag == 1 && g_rc_k == 1234.5 && g_rf_region == g_region && g_rf_b == b1 && g_rf_mode == 0 && g_rf_delta == NULL,
              "(setup) addToInventory runs whole, unhooked: add helper, recount(b, 0, 1, block), refresh(region, b, 0, no list)");
        game_write(m, b1, 17, -2, &delta_dummy);
        check(stock(b1, 17) == 3 && g_rf_delta == &delta_dummy, "(setup) unhooked, the game's own change stays and its list reaches the refresh");

        cmd("GOODS ON");
        check(m->text[m->recount] == 0xE9 && m->text[m->refresh] == 0xE9 && status_line("GOODS on", 1), "GOODS ON wrote a jump at both entries; status GOODS on");
        check(memcmp(m->text + m->recount + 5, m->snapshot + m->recount + 5, 64) == 0 && memcmp(m->text + m->addinv, m->snapshot + m->addinv, 105) == 0, "only the 5 entry bytes changed; addToInventory is untouched");
        g_rc_calls = g_rf_calls = 0;
        game_write(m, b1, 17, -1, &delta_dummy);
        check(stock(b1, 17) == 2 && g_rc_calls == 1 && g_rf_calls == 1 && g_rf_delta == &delta_dummy, "a building the mod has not written yet is left alone (the hooks pass the call on unchanged)");
        mod_write(m, b1, 17, 3);
        check(stock(b1, 17) == 5 && status_num("frozen=") == 1 && status_num(" own=") >= 2, "the mod's write goes through and is remembered (frozen=1)");
        check(g_rc_b == b1 && g_rc_dl == 0 && g_rc_flag == 1 && g_rc_k == 1234.5 && g_rf_region == g_region && g_rf_b == b1 && g_rf_mode == 0 && g_rf_delta == NULL, "through the hooks every argument arrives as sent");
        g_rc_amt17 = -1;
        game_write(m, b1, 17, -3, &delta_dummy);
        check(stock(b1, 17) == 5, "the game's own change (-3) is put back: 5 again");
        check(g_rc_amt17 == 5, "recountStorage itself already saw 5 (the hook runs before the routine)");
        check(g_rf_delta == NULL && status_num("nodelta=") == 1, "the game's list of what changed is dropped for the region's refresh");
        game_write(m, b1, 17, 4, NULL);
        check(stock(b1, 17) == 5, "a delivery (+4) is put back too");
        game_write(m, b1, 17, -5, NULL);
        check(stock(b1, 17) == 5 && a1->num == 1 && status_num("appended=") == 1, "the game took everything and removed the record: the record is back (appended, the list had room)");
        game_write(m, b1, 27, 6, NULL);
        check(stock(b1, 27) == 0 && a1->num == 1 && status_num("dropped=") == 1, "a kind the host's word does not have, added at the end: cut off again");
        {   /* a kind added in the MIDDLE of the list (code written out in place does that): amount 0 at once, record removed at the tick */
            double arg[3] = { 0.0, 0.0, 0.0 };
            a1->data[1] = a1->data[0]; a1->data[0].type = 99; a1->data[0].amt = 7; a1->num = 2;
            ((recount_call)(void *)(m->text + m->recount))(b1, 1, 1, arg);
            check(stock(b1, 99) == 0 && stock(b1, 17) == 5 && a1->num == 2, "a record added in the middle: its amount is 0 at once, the list is not moved inside the hook");
            g_tick(NULL);
            check(a1->num == 1 && a1->data[0].type == 17 && a1->data[0].amt == 5 && status_num("fixed=") == 1, "at the next tick the game's own addToInventory removed it; 5 planks stay");
        }
        {   /* the record removed and no room left in the list: repaired at the tick (the game's routine grows the list) */
            double arg[3] = { 0.0, 0.0, 0.0 };
            a1->num = 0; a1->max = 0;
            ((recount_call)(void *)(m->text + m->recount))(b1, 1, 1, arg);
            check(stock(b1, 17) == 0 && a1->num == 0, "record gone and the list has no room: nothing is grown inside the hook");
            g_tick(NULL);
            check(stock(b1, 17) == 5 && status_num("fixed=") == 2, "at the next tick it is back: 5");
        }
        mod_write(m, b1, 17, -2);
        game_write(m, b1, 17, 9, NULL);
        check(stock(b1, 17) == 3, "after the mod's next write (-2) the remembered amount is 3");
        mod_write(m, b2, 16, 0);
        check(status_num("frozen=") == 2, "a write of amount 0 registers a building (frozen=2)");
        game_write(m, b2, 16, 8, NULL);
        check(stock(b2, 16) == 0, "... and the game's change of it is put back (stays empty)");

        cmd("GOODS ON %llu", (unsigned long long)(uintptr_t)lord);
        game_write(m, b3, 17, 4, NULL);
        check(stock(b3, 17) == 4 && status_num("autoreg=") == 1, "GOODS ON <lord>: a building of that lord is remembered the first time it is seen (its first change stays)");
        game_write(m, b3, 17, 4, NULL);
        check(stock(b3, 17) == 4, "... its next change is put back");

        a1->data[0].amt = 44;                                   /* a change that reaches neither hook */
        n0 = status_num("leaks=");
        cmd("GOODS AUDIT");
        check(stock(b1, 17) == 3 && status_num("leaks=") == n0 + 1 && strstr(read_file(g_log), "GOODS leak: building") != NULL, "GOODS AUDIT finds a change that reached no hook, logs it and repairs it");

        {   thr_t t; HANDLE th; t.m = m; t.b = b1;
            n0 = status_num("otherthread=");
            th = CreateThread(NULL, 0, other_thread, &t, 0, NULL); WaitForSingleObject(th, 5000); CloseHandle(th);
            cmd("STATUS");
            check(stock(b1, 17) == 1 && status_num("otherthread=") == n0 + 2, "calls from another thread are passed through and counted (the change stays)");
            mod_write(m, b1, 17, 2);
        }

        {   /* the object at a remembered address is another one now */
            *(uint32_t *)(b2 + 0x0C) += 1000;
            game_write(m, b2, 16, 8, NULL);
            cmd("STATUS");
            check(stock(b2, 16) == 8 && status_num("stale=") == 1, "another object at a remembered address: forgotten, its change stays");
        }

        /* FINISH is the host's word: what it does to stock is remembered */
        *(uint64_t *)bld = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
        {   garr_t *ab = (garr_t *)(bld + 0x448);
            ab->data = (fgood_t *)calloc(INV_CAP, sizeof(fgood_t)); ab->num = 0; ab->max = INV_CAP;
            *(uint32_t *)(bld + 0x0C) = 7777; *(uint64_t *)(bld + 0x18) = 7777; *(void **)(bld + 0x2C8) = g_region;
            mod_write(m, bld, 17, 10);
            g_fin_m = m; g_finish_then = finish_uses_up;        /* the "game's" finishConstruction uses the goods up and tells the region */
            n0 = status_num("nodelta="); g_rf_delta = NULL;
            cmd("FINISH %llu", (unsigned long long)(uintptr_t)bld);
            check(stock(bld, 17) == 0 && g_rf_b == bld && g_rf_delta == NULL && status_num("nodelta=") == n0 + 1,
                  "FINISH: the list finishConstruction hands the region is dropped (the region takes the building as it is)");
            game_write(m, bld, 17, 3, NULL);
            check(stock(bld, 17) == 0, "after FINISH the building is remembered as FINISH left it (0), and the game's next change is put back to that");
        }
        {   /* FINISH on a building the mod never wrote and that is not the lord's (a rival lord's house): not taken in */
            uint8_t *rival = mk_building(m, 3, NULL);
            n0 = status_num("frozen=");
            cmd("FINISH %llu", (unsigned long long)(uintptr_t)rival);
            check(g_rf_b == rival && g_rf_delta == &g_fin_list, "FINISH on another lord's building: the game's list reaches the region unchanged");
            g_finish_then = NULL;
            game_write(m, rival, 17, 3, NULL);
            check(stock(rival, 17) == 3 && status_num("frozen=") == n0, "FINISH on another lord's building the mod never wrote does not freeze it");
        }

        /* PILEGONE */
        mod_write(m, pile, 17, 6); mod_write(m, pile, 27, 2); mod_write(m, notpile, 17, 6);
        g_rc_calls = 0;
        cmd("PILEGONE"); cmd("PILEGONE 0"); cmd("PILEGONE %llu", (unsigned long long)(uintptr_t)notpile);
        check(stock(notpile, 17) == 6 && g_rc_calls == 0 && strstr(read_file(g_log), "not a pile") != NULL, "PILEGONE refused 3 bad forms (no address, null, a building that is not a pile)");
        cmd("PILEGONE %llu", (unsigned long long)(uintptr_t)pile);
        check(((garr_t *)(pile + 0x448))->num == 0 && g_rc_b == pile && g_rc_dl == 1 && g_rc_k == 1234.5 && status_num("pilegone=") == 1,
              "PILEGONE emptied the pile and called recountStorage(pile, 1, 1, block): the game's branch that removes an empty pile");

        cmd("GOODS STATS");
        {   wchar_t sp[MAX_PATH]; _snwprintf(sp, MAX_PATH, L"%sgoods_stats.txt", g_io);
            check(strstr(read_file(sp), "caller_rva") != NULL, "GOODS STATS wrote goods_stats.txt"); }

        cmd("GOODS OFF");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("GOODS off", 1), "GOODS OFF: the whole .text is byte-identical to the original; status GOODS off");
        game_write(m, b1, 17, 4, &delta_dummy);
        check(stock(b1, 17) == 7 && g_rf_delta == &delta_dummy, "off: the game's change stays again");
        cmd("GOODS ON"); cmd("NOKILL ON"); cmd("ALLOFF");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("GOODS off", 1), "ALLOFF takes the hooks out too");

        {   /* a hook that faults: an object whose first page is not readable. The switch takes itself out; the game call still runs. */
            uint8_t *mem = (uint8_t *)VirtualAlloc(NULL, 0x3000, MEM_RESERVE, PAGE_READWRITE), *bad;
            double arg[3] = { 0.0, 0.0, 0.0 };
            VirtualAlloc(mem + 0x1000, 0x2000, MEM_COMMIT, PAGE_READWRITE);
            bad = mem + 0x1000 - 0x400;                         /* +448h is readable, +2E0h is not */
            ((garr_t *)(bad + 0x448))->num = 0;
            cmd("GOODS ON %llu", (unsigned long long)(uintptr_t)lord);
            g_rc_calls = 0;
            ((recount_call)(void *)(m->text + m->recount))(bad, 0, 1, arg);
            check(g_rc_calls == 1 && g_rc_b == bad, "a hook that faults is caught and the game's routine still runs");
            g_tick(NULL);
            check(status_line("GOODS unavailable exception C0000005 in a hook", 1) && memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "at the next tick the switch is out (GOODS unavailable), every byte restored");
            check(status_line("ready", 0) && status_line("P1 off", 1), "the DLL itself stays ready");
            cmd("GOODS ON");
            check(m->text[m->recount] == 0x48, "GOODS ON is refused after that");
        }
    }

    /* ======================================================== I: GOODS when addToInventory does not call recountStorage */
    {
        opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 2 };
        img_t *m = build_image(&o);
        start("I: addToInventory's first call goes somewhere else", m, NULL, NULL, NULL);
        check(status_line("GOODS unavailable ADDINV's first call does not reach RECOUNT", 1), "GOODS unavailable, with the reason");
        cmd("GOODS ON");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "GOODS ON wrote nothing");
        check(status_line("P1 off", 1) && status_line("ROUT available", 1), "the other items are unaffected");
    }

    /* ======================================================== J: TOTALS (lane 22) */
    {
        opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        img_t *m = build_image(&o);
        addlist_call game_add = (addlist_call)(void *)(m->text + m->addlist);
        uint8_t *r1 = mk_region(m), *r2 = mk_region(m), *eng = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        garr_t *t1 = (garr_t *)(r1 + 0x528), *t2 = (garr_t *)(r2 + 0x528), unitlist, d;
        fgood_t ud[TOT_CAP], dd[4];
        unsigned long long n0;
        *(void **)(r1 + 0x318) = eng; *(void **)(r2 + 0x318) = eng;
        unitlist.data = ud; unitlist.num = 0; unitlist.max = TOT_CAP;
        tot_put(r1, 16, 40); tot_put(r1, 17, 10); tot_put(r1, 99, 3);           /* 99: a kind the host never names */
        tot_put(r2, 16, 5);
        d.data = dd; d.num = 1; d.max = 4;
        start("J: TOTALS, a region's totals change only on the host's word", m, NULL, NULL, NULL);
        check(status_line("TOTALS off", 1), "TOTALS off after the scan (ADDLIST, NOTIFY and the six sites found, each site's call reaches ADDLIST)");
        check(status_line("GOODS unavailable", 0) && status_line("P1 off", 1), "the other items are unaffected");
        cmd("TOTALS SET %llu 16=1", (unsigned long long)(uintptr_t)r1);
        check(tot(r1, 16) == 40 && strstr(read_file(g_log), "TOTALS SET refused: TOTALS is not on") != NULL, "TOTALS SET refused while the switch is off");

        cmd("TOTALS ON");
        check(m->text[m->addlist] == 0xE9 && memcmp(m->text, m->snapshot, m->addlist) == 0 &&
              memcmp(m->text + m->addlist + 5, m->snapshot + m->addlist + 5, TEXT_SIZE - m->addlist - 5) == 0 && status_line("TOTALS on", 1),
              "TOTALS ON: a jump at ADDLIST's entry (5 bytes) and nothing else changed; status TOTALS on");
        good_one(dd, 16, 2); game_add(t1, &d, 0, 1);
        check(tot(r1, 16) == 42, "a region nobody has named yet is left to the game (its change stays)");

        g_al_calls = 0; g_nt_calls = 0;
        cmd("TOTALS SET %llu 16=50,17=7", (unsigned long long)(uintptr_t)r1);
        check(tot(r1, 16) == 50 && tot(r1, 17) == 7 && tot(r1, 99) == 3, "TOTALS SET wrote the host's amounts (16: 42 -> 50, 17: 10 -> 7); a kind not named stays");
        check(g_al_calls == 1 && g_nt_calls == 1 && g_nt_region == r1 && g_nt_n == 2, "... with the game's own ADDLIST (it ran: the DLL's own call passes the hook) and then NOTIFY(region, the change)");
        check(tot_num("sets=") == 1 && tot_num("regions=") == 1, "status: 1 region tracked, 1 set");

        g_al_calls = 0;
        good_one(dd, 16, 5); game_add(t1, &d, 0, 1);
        check(tot(r1, 16) == 50 && g_al_calls == 0, "the game's change of a tracked region's totals is not run (16 stays 50)");
        good_one(dd, 17, 4); game_add(t1, &d, 1, 1);
        check(tot(r1, 17) == 7, "... also a change that takes away (negate: a building removed)");
        good_one(dd, 30, 9); game_add(t1, &d, 0, 1);
        check(tot(r1, 30) == 0 && t1->num == 3, "... also a new kind (no record appended)");
        check(tot_num("skipped=") == 3 && tot_num("skipunits=") == 18, "status: 3 calls skipped, 18 units into the shadow");
        good_one(dd, 16, 5); game_add(&unitlist, &d, 0, 1); game_add(t2, &d, 0, 1);
        check(unitlist.num == 1 && unitlist.data[0].amt == 5 && tot(r2, 16) == 10, "another list (a unit's) and another region's totals are left to the game");

        {   thr_tot_t tt; HANDLE th; n0 = tot_num("otherthread=");
            tt.m = m; tt.list = t1; th = CreateThread(NULL, 0, other_thread_tot, &tt, 0, NULL); WaitForSingleObject(th, INFINITE); CloseHandle(th);
            check(tot(r1, 16) == 51 && tot_num("otherthread=") == n0 + 1, "a call from another thread is passed through and counted"); }
        cmd("TOTALS SET %llu 16=50,17=7", (unsigned long long)(uintptr_t)r1);
        check(tot(r1, 16) == 50, "the next SET writes it back");

        cmd("TOTALS AUDIT");
        check(tot_num("leaks=") == 0 && tot_num("audits=") == 1, "TOTALS AUDIT: nothing changed outside ADDLIST, 0 leaks");
        tot_put(r1, 17, 8);                                                         /* a change that never went through ADDLIST */
        cmd("TOTALS AUDIT");
        check(tot_num("leaks=") == 1 && tot(r1, 17) == 7 && strstr(read_file(g_log), "TOTALS leak") != NULL, "TOTALS AUDIT finds a change outside ADDLIST, logs it, counts it and writes the last value back");

        cmd("TOTALS DUMP");
        {   wchar_t sp[MAX_PATH]; _snwprintf(sp, MAX_PATH, L"%stotals_dump.txt", g_io);
            check(strstr(read_file(sp), "shadow 16=47 17=6 99=3 30=9") != NULL, "TOTALS DUMP: the shadow is the game's own totals (16: 42+5, 17: 10-4, 99: 3, 30: 9; the other thread's +1 went to the list)"); }

        {   /* a whole region's list, longer than 512 bytes, with ALL: the totals become exactly the list */
            char big[4000]; int q, nb = 0;
            nb += _snprintf(big + nb, sizeof(big) - (size_t)nb, "16=50,17=7");
            for (q = 0; q < 150; q++) nb += _snprintf(big + nb, sizeof(big) - (size_t)nb, ",%d=0", 1000 + q);
            cmd("TOTALS SET %llu %s ALL", (unsigned long long)(uintptr_t)r1, big);
            check(nb > 1000 && tot(r1, 16) == 50 && tot(r1, 17) == 7 && tot(r1, 99) == 0 && t1->num == 2,
                  "TOTALS SET ... ALL with a list of %d bytes: every good it does not name goes to nothing (99: 3 -> 0)", nb);
            cmd("TOTALS SET %llu 16=50,17=7,99=3", (unsigned long long)(uintptr_t)r1);
            check(tot(r1, 99) == 3, "... and back");
        }
        {   /* the second list, totals minus what is reserved (+538h): kept and written the same way */
            garr_t *t1r = (garr_t *)(r1 + 0x538);
            good_one(dd, 16, 4); game_add(t1r, &d, 0, 1);
            check(tot538(r1, 16) == 0, "the game's change of the list minus reserved (+538h) of a tracked region is not run either");
            cmd("TOTALS SETR %llu 16=30,17=2,340=-14", (unsigned long long)(uintptr_t)r1);
            check(tot538(r1, 16) == 30 && tot538(r1, 17) == 2 && tot538(r1, 340) == -14 && tot(r1, 16) == 50, "TOTALS SETR writes that list (16: 30, 17: 2, and 340: -14 stays, as the game keeps a negative amount there) and leaves the totals (16 stays 50)");
        }
        cmd("TOTALS SET 0 16=1"); cmd("TOTALS SET %llu 16=x", (unsigned long long)(uintptr_t)r2); cmd("TOTALS SET %llu", (unsigned long long)(uintptr_t)r2);
        cmd("TOTALS SET %llu 16=1", (unsigned long long)(uintptr_t)badvt);
        check(tot_num("regions=") == 1 && tot(r2, 16) == 10, "TOTALS SET refused 4 bad forms (null, a bad list, no list, an object with no vtable in the module)");

        g_nt_calls = 0;
        cmd("TOTALS OFF");
        check(tot(r1, 16) == 47 && tot(r1, 17) == 6 && tot(r1, 99) == 3 && tot(r1, 30) == 9 && tot538(r1, 16) == 4 && tot538(r1, 17) == 0 && g_nt_calls == 2,
              "TOTALS OFF, the recount: both lists are the game's own again (totals 16: 47 ...; minus reserved 16: 4, 17: 0; each written back with ADDLIST, then NOTIFY)");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("TOTALS off", 1) && tot_num("recounts=") == 2 && tot_num("recountbad=") == 0, "... read back equal to the shadow (recountbad=0); the whole .text is byte-identical to the original; status TOTALS off");
        good_one(dd, 16, 1); game_add(t1, &d, 0, 1);
        check(tot(r1, 16) == 48, "off: the game's change stays again");

        cmd("TOTALS ON"); cmd("TOTALS SET %llu 16=60", (unsigned long long)(uintptr_t)r1);
        game_add(t1, &d, 0, 1);
        cmd("TOTALS FORGET");
        check(tot(r1, 16) == 60 && memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && tot_num("forgot=") == 1, "TOTALS FORGET: nothing written back (a load made new regions), the hook out");

        cmd("TOTALS ON"); cmd("TOTALS SET %llu 16=70", (unsigned long long)(uintptr_t)r1);
        *(uint32_t *)(r1 + 0x0C) += 1000;                                           /* another object at that address now */
        cmd("TOTALS OFF");
        check(tot(r1, 16) == 70 && tot_num("forgot=") == 2, "a region that is no longer the same object is forgotten at OFF, not written");
        *(uint32_t *)(r1 + 0x0C) -= 1000;

        cmd("TOTALS ON"); cmd("TOTALS SET %llu 16=80", (unsigned long long)(uintptr_t)r1);
        game_add(t1, &d, 0, 1);
        cmd("NOKILL ON"); cmd("ALLOFF");
        check(tot(r1, 16) == 71 && memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "ALLOFF recounts too (16: 70 + 1) and takes the hook out");

        {   /* a hook that faults: a list whose data pointer cannot be read */
            fgood_t *badp = (fgood_t *)(uintptr_t)0x10;
            garr_t bl; bl.data = badp; bl.num = 1; bl.max = 1;
            cmd("TOTALS ON"); cmd("TOTALS SET %llu 16=80", (unsigned long long)(uintptr_t)r1);
            g_al_calls = 0;
            game_add(t1, &bl, 0, 1);
            check(g_al_calls == 1, "a hook that faults is caught and the game's routine still runs");
            g_tick(NULL);
            check(status_line("TOTALS unavailable exception C0000005 in the hook or a write", 1) && memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && tot(r1, 16) == 80,
                  "at the next tick the switch is out (TOTALS unavailable), every byte restored, nothing written back");
            check(status_line("ready", 0) && status_line("P1 off", 1), "the DLL itself stays ready");
            cmd("TOTALS ON");
            check(m->text[m->addlist] == 0x44, "TOTALS ON is refused after that");
        }
    }

    /* ======================================================== K: TOTALS when a site's call goes elsewhere */
    {
        opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
        img_t *m = build_image(&o);
        start("K: TOTALS, the third site's call goes somewhere else", m, NULL, NULL, NULL);
        check(status_line("TOTALS unavailable TS3's call does not reach ADDLIST", 1), "TOTALS unavailable, with the reason");
        cmd("TOTALS ON");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "TOTALS ON wrote nothing");
        check(status_line("P1 off", 1) && status_line("ROUT available", 1), "the other items are unaffected");
    }

    /* ======================================================== J: CURSOR (lane 26) */
    {
        static __declspec(align(16)) uint8_t pawn[0x1000];
        double *pt = (double *)(pawn + 0x4E8);
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1 };
            img_t *m = build_image(&o);
            start("J1: CURSOR on the known build with one site", m, NULL, NULL, NULL);
            check(status_line("CURSOR available", 1), "CURSOR available");
            memset(pawn, 0, sizeof(pawn));
            *(uint64_t *)pawn = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
            cmd("CURSOR %llu 108200.5 88200 3787.25", (unsigned long long)(uintptr_t)pawn);
            check(pt[0] == 108200.5 && pt[1] == 88200.0 && pt[2] == 3787.25, "CURSOR wrote x, y, z at +4E8, +4F0, +4F8");
            check(*(uint64_t *)(pawn + 0x4E0) == 0 && *(uint64_t *)(pawn + 0x500) == 0, "nothing written before +4E8 or after +4FF");
            cmd("CURSOR %llu GET", (unsigned long long)(uintptr_t)pawn);
            check(strstr(read_file(g_log), "is 108200.50 88200.00 3787.25") != NULL, "CURSOR GET logs the point");
            cmd("CURSOR %llu 1 2", (unsigned long long)(uintptr_t)pawn);
            cmd("CURSOR %llu 1 2 x", (unsigned long long)(uintptr_t)pawn);
            cmd("CURSOR %llu 1e9 2 3", (unsigned long long)(uintptr_t)pawn);
            cmd("CURSOR %llu nan 2 3", (unsigned long long)(uintptr_t)pawn);
            cmd("CURSOR 0 1 2 3");
            cmd("CURSOR %llu 1 2 3", (unsigned long long)(uintptr_t)pawn + 4);
            check(pt[0] == 108200.5 && pt[1] == 88200.0 && pt[2] == 3787.25, "CURSOR refused 6 bad forms (missing z, z not a number, x off the map, NaN, null, unaligned)");
            check(status_line("calls cursor=1 ", 0), "status counts one CURSOR write");
            check(status_line("P1 off", 1) && status_line("ROUT available", 1), "the other items are unaffected");
            /* INPUT */
            check(status_line("INPUT LMBDOWN available", 1) && status_line("INPUT LMBUP available", 1) && status_line("INPUT RMBDOWN available", 1) && status_line("INPUT RMBUP available", 1), "INPUT: all four handlers available");
            cmd("INPUT %llu LMBDOWN", (unsigned long long)(uintptr_t)pawn);
            cmd("INPUT %llu LMBUP", (unsigned long long)(uintptr_t)pawn);
            cmd("INPUT %llu RMBDOWN", (unsigned long long)(uintptr_t)pawn);
            cmd("INPUT %llu RMBUP", (unsigned long long)(uintptr_t)pawn);
            check(g_input_calls[0] == 1 && g_input_calls[1] == 1 && g_input_calls[2] == 1 && g_input_calls[3] == 1 && g_input_pawn == pawn, "INPUT ran each handler once with the pawn");
            check(pawn[0x904] == 1, "the RMB pressed handler's own first write landed in the pawn");
            cmd("INPUT %llu MMB", (unsigned long long)(uintptr_t)pawn);
            cmd("INPUT %llu", (unsigned long long)(uintptr_t)pawn);
            cmd("INPUT 0 LMBDOWN");
            cmd("INPUT %llu LMBDOWN", (unsigned long long)(uintptr_t)pawn + 8);
            check(g_input_calls[0] == 1, "INPUT refused 4 bad forms (unknown button, missing button, null, pawn whose first qword is no vtable)");
            check(status_line("calls cursor=1 lmbdown=1 lmbup=1 rmbdown=1 rmbup=1", 1), "status counts the four calls");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 };
            img_t *m = build_image(&o);
            start("J2: CURSOR site present, but another game build", m, NULL, NULL, NULL);
            check(status_line("CURSOR unavailable another game build", 0), "CURSOR unavailable on another build");
            memset(pawn, 0, sizeof(pawn)); *(uint64_t *)pawn = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
            cmd("CURSOR %llu 1 2 3", (unsigned long long)(uintptr_t)pawn);
            check(pt[0] == 0.0, "CURSOR wrote nothing");
            check(status_line("INPUT LMBDOWN unavailable another game build", 0), "INPUT unavailable on another build");
            cmd("INPUT %llu LMBDOWN", (unsigned long long)(uintptr_t)pawn);
            check(g_input_calls[0] == 1, "INPUT called nothing");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1 };
            img_t *m = build_image(&o);
            start("J3: CURSOR site twice", m, NULL, NULL, NULL);
            check(status_line("CURSOR unavailable CURSOR signature has 2 hits (need exactly 1)", 1), "CURSOR unavailable with two hits");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
            img_t *m = build_image(&o);
            start("J4: no CURSOR site", m, NULL, NULL, NULL);
            check(status_line("CURSOR unavailable CURSOR signature has 0 hits (need exactly 1)", 1), "CURSOR unavailable with no hit");
            check(status_line("ROUT available", 1), "the rest still works");
        }
    }


    /* ======================================================== K: DRAW and ORDER (lane 28) */
    {
        static __declspec(align(16)) uint8_t pawn[0x2000], kbld[0x600], junk[0x600];
        static int32_t squads[2] = { 7, 9 };
        unsigned long long pa = (unsigned long long)(uintptr_t)pawn;
        tarr_t *rp = (tarr_t *)(pawn + 0x780), *way = (tarr_t *)(pawn + 0xCA8);
        double *cur = (double *)(pawn + 0x4E8), *delta = (double *)(pawn + 0x4C0);
        g_rmbdown_then = l28_press;
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1 };
            img_t *m = build_image(&o);
            movesel_call game_movesel = (movesel_call)(void *)(m->text + m->l28_movesel);
            start("K1: DRAW and ORDER on the known build", m, NULL, NULL, NULL);
            { wchar_t ev[MAX_PATH]; _snwprintf(ev, MAX_PATH, L"%spatch_events.txt", g_io); DeleteFileW(ev); }
            check(status_line("DRAW available", 1) && status_line("ORDER available", 1) && status_line("PATH available", 1), "DRAW, ORDER and PATH available");
            check(status_line("ORDERHOOK idle", 1), "ORDERHOOK idle (nothing written yet)");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "the scan changed nothing in .text");
            /* WALL */
            l28_reset(); l28_pawn_init(pawn, m, squads, 2);
            cur[0] = 50; cur[1] = 60; cur[2] = 1;
            cmd("WALL t1 %llu 0 100,200,3|1100,200,3|1100,1200,4", pa);
            check(g_l28_calls[0] == 3 && g_l28_calls[1] == 3 && g_l28_calls[2] == 0, "WALL: three updates, three clicks, no commit");
            check(g_l28_tool_cur[0].x == 100 && g_l28_tool_cur[1].x == 1100 && g_l28_tool_cur[2].y == 1200 && g_l28_tool_cur[2].z == 4, "each update saw its point as the cursor point");
            check(g_l28_tool_delta[0].x == 50 && g_l28_tool_delta[0].y == 140 && g_l28_tool_delta[1].x == 1000 && g_l28_tool_delta[2].y == 1000, "each update saw the change of the cursor point (+4C0)");
            check(delta[0] == 0 && delta[1] == 0 && delta[2] == 0, "the change is zero again afterwards");
            check(rp->num == 3 && g_l28_rp[0].x == 100 && g_l28_rp[2].y == 1200, "the clicks took the three points");
            check(reply_is("R t1 WALL ok pts=3 blocked=000 stop=0 road=0\r\n"), "the answer names the points taken");
            l28_reset(); rp->num = 0;
            cmd("WALL t2 %llu 1 100,200,3|1100,200,3", pa);
            { char want[96]; _snprintf(want, sizeof(want), "R t2 WALL ok pts=2 blocked=00 stop=0 road=%llX\r\n", (unsigned long long)(uintptr_t)g_l28_road);
              check(g_l28_calls[2] == 1 && g_l28_pawn == pawn && reply_is(want), "flag 1: commitRoad ran once with the pawn; the answer holds the road"); }
            l28_reset(); rp->num = 0; g_l28_block_at = 1;
            cmd("WALL t3 %llu 1 100,200,3|1100,200,3|1100,1200,4", pa);
            check(g_l28_calls[0] == 2 && g_l28_calls[1] == 1 && g_l28_calls[2] == 0 && rp->num == 1, "a blocked point stops the drawing: no click, no commit");
            check(reply_is("R t3 WALL ok pts=1 blocked=01 stop=2 road=0\r\n"), "the answer names the blocked point");
            l28_reset(); rp->num = 0; g_l28_block_at = 1;
            cmd("WALL t4 %llu 3 100,200,3|1100,200,3|1100,1200,4", pa);
            check(g_l28_calls[0] == 3 && g_l28_calls[1] == 3 && g_l28_calls[2] == 1 && rp->num == 3 && g_l28_click_flag[1] == 0, "flag 2: the cannot-place flag is cleared before the click, all points taken, committed");
            check(reply_is("R t4 WALL ok pts=3 blocked=010 stop=0 road="), "the answer still names the point that was blocked");
            l28_reset(); rp->num = 0;
            cmd("WALL t5 %llu 0 100,200,3", pa);
            cmd("WALL t5 %llu 0 1,1,1|2,2,2|3,3,3|4,4,4|5,5,5|6,6,6|7,7,7|8,8,8|9,9,9|10,10,10|11,11,11|12,12,12|13,13,13|14,14,14|15,15,15|16,16,16|17,17,17|18,18,18|19,19,19|20,20,20|21,21,21|22,22,22", pa);
            cmd("WALL t5 %llu 0 100,200,3|x,200,3", pa);
            cmd("WALL t5 %llu 0 100,200,3|1e9,200,3", pa);
            cmd("WALL t5 %llu 4 100,200,3|1100,200,3", pa);
            cmd("WALL t5 0 0 100,200,3|1100,200,3");
            cmd("WALL t5 %llu 0 100,200,3|1100,200,3", pa + 4);
            cmd("WALL t5 %llu 0", pa);
            check(g_l28_calls[0] == 0 && g_l28_calls[1] == 0 && reply_is("R t5 WALL refused"), "WALL refused 8 bad forms (one point, 22 points, not a number, off the map, flags 4, null, unaligned, no points)");
            /* TOOL */
            cmd("TOOL %llu", pa);
            cmd("TOOL 0");
            check(g_l28_calls[0] == 1, "TOOL ran one update; a null pawn is refused");
            /* WALLGET */
            {
                static v3_t ctl[2] = { { 1, 2, 3 }, { 4, 5, 6 } };
                static __declspec(align(16)) uint8_t gate[0x60];
                v3_t gp = { 7, 8, 9 };
                tarr_t a;
                memset(g_l28_road, 0, sizeof(g_l28_road)); memset(gate, 0, sizeof(gate));
                *(uint64_t *)g_l28_road = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
                g_l28_road[0x2B3] = 1; g_l28_road[0x2B4] = 3; g_l28_road[0x2B5] = 2; g_l28_road[0x2B6] = 0;
                a.data = (uint8_t *)ctl; a.num = 2; a.max = 2; memcpy(g_l28_road + 0x318, &a, sizeof(a));
                gate[0] = 0xAB; memcpy(gate + 0x20, &gp, sizeof(gp));
                a.data = gate; a.num = 1; a.max = 1; memcpy(g_l28_road + 0x498, &a, sizeof(a));
                cmd("WALLGET t6 %llu", (unsigned long long)(uintptr_t)g_l28_road);
                check(reply_is("R t6 WALLGET ok kind=1,3,2,0 ctl=2 1.00,2.00,3.00|4.00,5.00,6.00 gates=1 7.00,8.00,9.0000:AB00"), "WALLGET: kind, control points, gate place (height with 4 decimals, lane 32) and record");
                /* lane 32: GATESET writes the drawing copy's place of a gate record (small corrections only) */
                cmd("GATESET t6b %llu 0 7.5,8,9.03", (unsigned long long)(uintptr_t)g_l28_road);
                check(reply_is("R t6b GATESET ok 0 9.0000 9.0300") && ((v3_t *)(gate + 0x20))->z == 9.03 && ((v3_t *)(gate + 0x20))->x == 7.5 && gate[0] == 0xAB, "GATESET: the gate's place set, the rest of the record untouched");
                cmd("GATESET t6c %llu 0 7,8,19", (unsigned long long)(uintptr_t)g_l28_road);
                check(reply_is("R t6c GATESET refused gate 0") && ((v3_t *)(gate + 0x20))->z == 9.03, "GATESET refused a height 10 away (nothing written)");
                cmd("GATESET t6d %llu 1 7,8,9", (unsigned long long)(uintptr_t)g_l28_road);
                cmd("GATESET t6d %llu 0 7,8", (unsigned long long)(uintptr_t)g_l28_road);
                cmd("GATESET t6d 0 0 7,8,9");
                check(reply_is("R t6d GATESET refused"), "GATESET refused index 1 of 1 record, two numbers, a null road");
                memcpy(gate + 0x20, &gp, sizeof(gp));
                /* lane 32: UNCAMP is refused (and calls nothing) while its signature has no hit (the synthetic module
                 * holds none); the real routine's single hit is checked by the offline signature check */
                cmd("UNCAMP t6e %llu 31", pa);
                check(reply_is("R t6e UNCAMP refused unavailable (UNCAMP signature has 0 hits"), "UNCAMP refused without its signature");
                memset(junk, 0, sizeof(junk)); *(uint64_t *)junk = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
                a.data = NULL; a.num = -1; a.max = 0; memcpy(junk + 0x318, &a, sizeof(a));
                cmd("WALLGET t7 %llu", (unsigned long long)(uintptr_t)junk);
                cmd("WALLGET t7 0");
                check(reply_is("R t7 WALLGET refused"), "WALLGET refused an object whose list is not sane, and null");
            }
            /* lane 53: WALLSET */
            {
                static v3_t ctl[8];
                static const v3_t c0[3] = { { 0, 0, 5 }, { 1000, 0, 5 }, { 1000, 2000, 5 } };
                tarr_t *a = (tarr_t *)(g_l28_road + 0x318);
                unsigned long long ra = (unsigned long long)(uintptr_t)g_l28_road;
                LONG reb0, ins0;
                check(status_line("WALLSET available sets=0 grown=0", 1), "WALLSET available: the rebuild and the insert found once each");
                memset(g_l28_road, 0, sizeof(g_l28_road));
                *(uint64_t *)g_l28_road = (uint64_t)(uintptr_t)(m->base + DATA_RVA);
                g_l28_road[0x2B3] = 1; g_l28_road[0x2B5] = 2;
                memcpy(ctl, c0, sizeof(c0)); a->data = (uint8_t *)ctl; a->num = 3; a->max = 3;
                g_l53_reb = 0; g_l53_ins = 0; g_l53_refuse = 0; g_l53_fault = 0;
                cmd("WALLSET w1 %llu 0,0,5|1500,250,6|1000,2000,5", ra);
                check(reply_is("R w1 WALLSET ok was=3 now=3 grown=0") && g_l53_reb == 1 && g_l53_ins == 0 && g_l53_flag == 0 && a->num == 3 && a->data == (uint8_t *)ctl && ctl[1].x == 1500 && ctl[1].y == 250 && ctl[1].z == 6 && ctl[2].y == 2000,
                      "a moved point: written in place, one rebuild with flag 0, no insert");
                cmd("WALLSET w2 %llu 0,0,5|1000,2000,5", ra);
                check(reply_is("R w2 WALLSET ok was=3 now=2 grown=0") && g_l53_reb == 2 && a->num == 2 && a->max == 3 && ctl[1].y == 2000 && g_l53_num_at_reb == 2, "a point taken away: two points left in the same memory, one rebuild");
                cmd("WALLSET w3 %llu 0,0,5|400,100,5|1000,2000,5", ra);
                check(reply_is("R w3 WALLSET ok was=2 now=3 grown=0") && g_l53_ins == 0 && a->num == 3 && ctl[1].x == 400, "a point added where the memory holds it: no insert");
                cmd("WALLSET w4 %llu 0,0,5|400,100,5|700,900,5|1000,2000,5|1200,2600,5", ra);
                check(reply_is("R w4 WALLSET ok was=3 now=5 grown=2") && g_l53_ins == 2 && a->num == 5 && a->data == (uint8_t *)g_l53_big && g_l53_big[2].x == 700 && g_l53_big[4].y == 2600 && g_l53_big[0].z == 5 && g_l53_num_at_reb == 5,
                      "two points more than the memory holds: the game's insert ran twice, then every point written, one rebuild");
                reb0 = g_l53_reb; ins0 = g_l53_ins;
                g_l53_refuse = 1000;
                cmd("WALLSET w5 %llu 0,0,5|400,100,5|700,900,5|1000,2000,5|1200,2600,5|1300,2700,5|1400,2800,5", ra);
                check(reply_is("R w5 WALLSET refused the game did not lengthen") && a->num == 5 && g_l53_big[4].y == 2600 && g_l53_reb == reb0 && g_l53_ins > ins0, "the insert refuses every stretch: the old points stay, no rebuild, refused");
                g_l53_refuse = 1; ins0 = g_l53_ins;
                cmd("WALLSET w6 %llu 0,0,5|400,100,5|700,900,5|1000,2000,5|1200,2600,5|1300,2700,5", ra);
                check(reply_is("R w6 WALLSET ok was=5 now=6 grown=1") && g_l53_ins == ins0 + 2 && a->num == 6 && g_l53_big[5].x == 1300, "one refusal: the next longest stretch is asked");
                reb0 = g_l53_reb;
                cmd("WALLSET w7 %llu 0,0,5", ra);
                cmd("WALLSET w7 %llu 0,0,5|1,2", ra);
                cmd("WALLSET w7 %llu 0,0,5|1e9,0,0", ra);
                cmd("WALLSET w7 0 0,0,5|9,9,5");
                cmd("WALLSET w7 %llu", ra);
                check(reply_is("R w7 WALLSET refused") && g_l53_reb == reb0 && a->num == 6, "WALLSET refused 5 bad forms (one point, two numbers, off the map, null, no points)");
                g_l28_road[0x2B3] = 0;
                cmd("WALLSET w8 %llu 0,0,5|9,9,5", ra);
                check(reply_is("R w8 WALLSET refused the road is not a wall of the plan") && a->num == 6, "a real road (not a blueprint) is refused");
                g_l28_road[0x2B3] = 1; a->num = 1;
                cmd("WALLSET w9 %llu 0,0,5|9,9,5", ra);
                check(reply_is("R w9 WALLSET refused the object's point list is not sane") && g_l53_reb == reb0, "a wall with one control point is refused");
                {   /* lane 55: a placed wall grows past the draw tool's 21 points by the game's own inserts */
                    static char big[64 * 32 + 64];
                    int k, bo = 0;
                    a->num = 6;
                    for (k = 0; k < 30; k++) bo += sprintf(big + bo, "%s%d,%d,5", k ? "|" : "", 100 * k, 50 * k);
                    ins0 = g_l53_ins;
                    cmd("WALLSET w12 %llu %s", ra, big);
                    check(reply_is("R w12 WALLSET ok was=6 now=30 grown=24") && a->num == 30 && g_l53_ins == ins0 + 24 && ((v3_t *)a->data)[29].x == 2900 && ((v3_t *)a->data)[29].y == 1450 && g_l53_num_at_reb == 30,
                          "a 30-point wall: the game's insert lengthened the list, every point written, one rebuild");
                    bo = 0;
                    for (k = 0; k < 65; k++) bo += sprintf(big + bo, "%s%d,%d,5", k ? "|" : "", 100 * k, 50 * k);
                    reb0 = g_l53_reb;
                    cmd("WALLSET w13 %llu %s", ra, big);
                    check(reply_is("R w13 WALLSET refused needs 2 to 64 points") && a->num == 30 && g_l53_reb == reb0, "65 points: refused, the wall unchanged");
                }
                check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "WALLSET never writes to .text");
                a->num = 6; g_l53_fault = 2;
                cmd("WALLSET w10 %llu 0,0,5|9,9,5", ra);
                check(reply_is("R w10 WALLSET exception E0000053 in WALLREB") && status_line("WALLSET unavailable exception E0000053 in an earlier call", 1), "a faulting rebuild is caught: WALLSET unavailable");
                g_l53_fault = 0;
                cmd("WALLSET w11 %llu 0,0,5|9,9,5", ra);
                check(reply_is("R w11 WALLSET refused unavailable"), "and stays unavailable for the run");
            }
            /* ORDERAT */
            l28_reset(); pawn[0x488] = 1;
            cmd("ORDERAT t8 %llu 500,600,7 0 1", pa);
            check(g_l28_calls[3] == 1 && g_l28_pawn == pawn && g_l28_wp == 0 && g_l28_na == 1, "ORDERAT: MoveSelected ran once with the pawn, no waypoint, no arrows");
            check(g_l28_ms_cur.x == 500 && g_l28_ms_cur.y == 600 && g_l28_ms_cur.z == 7 && g_l28_moved_seen == 0, "it saw the point as the cursor point and the drag flag (+488) cleared");
            check(reply_is("R t8 ORDERAT ok way=0 -\r\n"), "the answer");
            l28_reset(); way->num = 0;
            cmd("ORDERAT t9 %llu 500,600,7 1 1", pa);
            check(g_l28_calls[3] == 0 && reply_is("R t9 ORDERAT refused"), "a waypoint order with an empty path list is refused (the game would read before the list)");
            cmd("ORDERAT t9 %llu 500,600 0 1", pa);
            cmd("ORDERAT t9 %llu 500,600,7 2 1", pa);
            cmd("ORDERAT t9 0 500,600,7 0 1");
            check(g_l28_calls[3] == 0, "ORDERAT refused 3 bad forms (two coordinates, flag 2, null)");
            /* PATH */
            l28_reset();
            cmd("PATH t10 %llu 1 0,0,0|1000,0,0|2000,0,0|3000,0,5", pa);
            check(g_input_calls[2] >= 1 && g_l28_calls[4] == 3 && g_l28_calls[3] == 1 && g_l28_wp == 1 && g_l28_na == 1, "PATH: press, three path points, MoveSelected with the waypoint flag");
            check(way->num == 4 && l28_way_at(pawn, 0).x == 0 && l28_way_at(pawn, 1).x == 1000 && l28_way_at(pawn, 3).x == 3000, "the path list holds exactly the four points");
            check(reply_is("R t10 PATH ok way=4 0.0,0.0,0.0|1000.0,0.0,0.0|2000.0,0.0,0.0|3000.0,0.0,5.0\r\n"), "the answer lists them");
            l28_reset();
            cmd("PATH t11 %llu 0 0,0,0|1000,0,0", pa);
            check(way->num == 2 && l28_way_at(pawn, 0).x == 0 && l28_way_at(pawn, 1).x == 1000 && g_l28_calls[4] == 0, "two points: press at the first, the order appends the second");
            l28_reset();
            cmd("PATH t12 %llu 0 0,0,0|1000,0,0|2000,0,0|2100,0,0", pa);
            check(way->num == 4 && l28_way_at(pawn, 2).x == 2000 && l28_way_at(pawn, 3).x == 2100, "a last point nearer than the game's step still ends the path");
            l28_reset(); way->num = 0;
            cmd("PATH t13 %llu 0 0,0,0|100,0,0", pa);
            cmd("PATH t13 %llu 0 0,0,0", pa);
            cmd("PATH t13 0 0 0,0,0|1000,0,0");
            check(g_l28_calls[3] == 0 && reply_is("R t13 PATH refused"), "PATH refused 3 bad forms (two points too close, one point, null)");
            cmd("PATHGET t14 %llu", pa);
            check(reply_is("R t14 PATHGET ok way=0 -"), "PATHGET");
            l28_reset();
            cmd("PATHPT %llu", pa);
            check(g_l28_calls[4] == 0, "PATHPT with an empty path list is refused (the routine would read before the list)");
            l28_press(pawn); cur[0] += 2000;
            cmd("PATHPT %llu", pa);
            check(g_l28_calls[4] == 1 && way->num == 2, "PATHPT ran the path routine once: the cursor point joined the list");
            way->num = 0;
            check(status_line("draw walls=4 tools=1 wallgets=1 orders=1 paths=3 ", 0), "status counts the calls");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "none of this wrote to .text");
            /* ORDERHOOK */
            cmd("ORDERHOOK ON");
            check(status_line("ORDERHOOK hooked", 1) && m->text[m->l28_movesel] == 0xE9, "ORDERHOOK ON: a jump at MoveSelected's entry");
            { size_t i; int same = 1; for (i = 0; i < TEXT_SIZE; i++) if ((i < m->l28_movesel || i >= m->l28_movesel + 5) && m->text[i] != m->snapshot[i]) same = 0;
              check(same, "nothing else in .text changed"); }
            l28_reset(); l28_pawn_init(pawn, m, squads, 2);
            memset(kbld, 0, sizeof(kbld)); *(int32_t *)(kbld + 0x3B8) = 100; kbld[0x3CC] = 0x11;
            cur[0] = 11; cur[1] = 22; cur[2] = 33; pawn[0x5B8] = 3; *(void **)(pawn + 0x710) = kbld;
            game_movesel(pawn, 0, 0);
            check(g_l28_calls[3] == 1 && g_l28_pawn == pawn && g_l28_wp == 0, "the game's own call still reaches MoveSelected with its arguments");
            check(event_lines() == 0, "nothing is written inside the call");
            g_tick(NULL);
            { char want[160]; _snprintf(want, sizeof(want), "MOVESEL 1 pawn=%llX wp=0 na=0 cur=11.0,22.0,33.0 mode=3 moved=0 hb=%llX hbt=100 hbc=17 hp=0 res=0 sq=7,9 waybefore=0 way=0 -\r\n", pa, (unsigned long long)(uintptr_t)kbld);
              check(event_lines() == 1 && event_has(want), "the next tick writes the order: pawn, point, hover state, squads"); }
            l28_press(pawn); cur[0] = 1000;
            game_movesel(pawn, 1, 0);
            g_tick(NULL);
            check(event_lines() == 2 && event_has("wp=1 na=0 cur=1000.0,22.0,33.0") && event_has("waybefore=1 way=2 11.0,22.0,33.0|1000.0,22.0,33.0\r\n"), "a waypoint order is written with the path as the call left it");
            cmd("ORDERAT t15 %llu 500,600,7 0 1", pa);
            g_tick(NULL);
            check(g_l28_calls[3] == 3 && event_lines() == 2, "this DLL's own order is not written");
            { thr28_t t; HANDLE th; t.m = m; t.pawn = pawn; th = CreateThread(NULL, 0, l28_other_thread, &t, 0, NULL); WaitForSingleObject(th, 5000); CloseHandle(th); }
            g_tick(NULL);
            check(g_l28_calls[3] == 4 && event_lines() == 2, "a call from another thread passes through and is not written");
            check(status_line("draw walls=4 tools=1 wallgets=1 orders=2 paths=3 seen=2 events=2 dropped=0 hookfaults=0", 1), "status counts what the hook saw");
            cmd("ORDERHOOK OFF");
            check(status_line("ORDERHOOK idle", 1) && memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "ORDERHOOK OFF: .text is byte-identical to the original");
            game_movesel(pawn, 0, 0); g_tick(NULL);
            check(g_l28_calls[3] == 5 && event_lines() == 2, "after OFF the game's call is not written");
            cmd("ORDERHOOK ON"); cmd("NOKILL ON"); cmd("ALLOFF");
            check(status_line("ORDERHOOK idle", 1) && memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "ALLOFF takes the hook out too");
            /* faults */
            l28_reset(); g_l28_fault_in = 3;
            cmd("ORDERAT t16 %llu 500,600,7 0 1", pa);
            check(reply_is("R t16 ORDERAT exception E0000028") && status_line("ORDER unavailable exception E0000028 in an earlier call", 1) && status_line("ready", 0), "a faulting MoveSelected is caught: ORDER unavailable, the DLL stays ready");
            check(status_line("ORDERHOOK unavailable", 0) && status_line("DRAW available", 1), "ORDERHOOK goes with it, DRAW is unaffected");
            cmd("ORDERHOOK ON");
            check(m->text[m->l28_movesel] == 0x48, "ORDERHOOK ON is refused after that");
            l28_reset(); g_l28_fault_in = 0; rp->num = 0;
            cmd("WALL t17 %llu 0 100,200,3|1100,200,3", pa);
            check(reply_is("R t17 WALL exception E0000028 in TOOLUPD at point 1") && status_line("DRAW unavailable exception E0000028 in an earlier call", 1), "a faulting tool update is caught: DRAW unavailable");
            l28_reset();
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1 };
            img_t *m = build_image(&o);
            start("K2: the routines present, but another game build", m, NULL, NULL, NULL);
            check(status_line("DRAW unavailable another game build", 0) && status_line("ORDER unavailable another game build", 0) && status_line("ORDERHOOK unavailable another game build", 0), "DRAW, ORDER and ORDERHOOK unavailable on another build");
            check(status_line("WALLSET unavailable another game build", 0), "WALLSET unavailable on another build");
            cmd("WALLSET t1 %llu 0,0,5|9,9,5", (unsigned long long)(uintptr_t)g_l28_road);
            check(reply_is("R t1 WALLSET refused unavailable (another game build"), "and refused");
            l28_reset(); l28_pawn_init(pawn, m, squads, 2);
            cmd("WALL t1 %llu 0 100,200,3|1100,200,3", pa);
            cmd("ORDERAT t1 %llu 500,600,7 0 1", pa);
            cmd("ORDERHOOK ON");
            check(g_l28_calls[0] == 0 && g_l28_calls[3] == 0 && memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "nothing is called, nothing is written");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2 };
            img_t *m = build_image(&o);
            start("K3: MoveSelected twice", m, NULL, NULL, NULL);
            check(status_line("ORDER unavailable MOVESEL signature has 2 hits (need exactly 1)", 1) && status_line("ORDERHOOK unavailable MOVESEL signature has 2 hits (need exactly 1)", 1), "ORDER and ORDERHOOK unavailable with two hits");
            check(status_line("DRAW available", 1), "DRAW is unaffected");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0 };
            img_t *m = build_image(&o);
            start("K4: none of the routines", m, NULL, NULL, NULL);
            check(status_line("DRAW unavailable TOOLUPD signature has 0 hits (need exactly 1)", 1) && status_line("PATH unavailable MOVESEL signature has 0 hits (need exactly 1)", 1), "DRAW and PATH unavailable with no hit");
            check(status_line("CURSOR available", 1) && status_line("ROUT available", 1), "the rest still works");
        }
        g_rmbdown_then = NULL;
    }

    /* ======================================================== L: CHOOSE (lane 23): the job chooser, per villager */
    {
        static __declspec(align(16)) uint8_t eng[0x1100], ua[0x400], ub[0x400];
        static int32_t list[3] = { 5, 7, 0 };
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1 };
            img_t *m = build_image(&o);
            chooser_fn ch = (chooser_fn)(void *)(m->text + m->chooser);
            char line[300];
            start("L1: CHOOSE, the job chooser runs for the villagers the mod names", m, NULL, NULL, NULL);
            memset(eng, 0, sizeof(eng)); memset(ua, 0, sizeof(ua)); memset(ub, 0, sizeof(ub));
            *(int32_t **)(eng + 0x10A8) = list; *(int32_t *)(eng + 0x10B0) = 3;
            *(uint8_t **)(ua + 0x318) = eng; *(uint8_t **)(ub + 0x318) = eng;
            check(status_line("CHOOSE off n=0 hits=0 sets=0 refused=0", 1), "CHOOSE found exactly once with its known bytes, off");
            check(ch(ua, NULL, 7) == 1 && ch(ua, NULL, 9) == 0 && ch(ub, NULL, 5) == 1, "the game's own test: a listed job type stops the chooser (7, 5), another does not (9)");
            cmd("CHOOSE ON");
            check(m->text[m->choose_site] == 0xE9 && memcmp(m->text, m->snapshot, m->choose_site) == 0 &&
                  memcmp(m->text + m->choose_site + 5, m->snapshot + m->choose_site + 5, TEXT_SIZE - m->choose_site - 5) == 0 && status_line("CHOOSE on n=0 hits=0 sets=0 refused=0", 1),
                  "CHOOSE ON: a jump over the 5 bytes of the chooser's test and nothing else changed; status on");
            check(ch(ua, NULL, 7) == 1 && ch(ua, NULL, 9) == 0 && ch(ub, NULL, 5) == 1, "on, nobody named: exactly as before (7 and 5 stop, 9 passes)");
            cmd("CHOOSE SET %llX", (unsigned long long)(uintptr_t)ua);
            check(ch(ua, NULL, 7) == 0 && ch(ua, NULL, 5) == 0 && ch(ua, NULL, 9) == 0, "the named villager: its chooser runs whatever its job type");
            check(ch(ub, NULL, 7) == 1 && ch(ub, NULL, 9) == 0, "another villager: still stopped by the list");
            cmd("STATUS");
            check(status_line("CHOOSE on n=1 hits=3 sets=1 refused=0", 1), "status counts 1 on the list and 3 chooser runs let through (7, 5 and 9)");
            _snprintf(line, sizeof(line), "CHOOSE SET 7FF00000000,%llX,7FF00001000", (unsigned long long)(uintptr_t)ub);
            cmd("%s", line);
            check(ch(ub, NULL, 7) == 0 && ch(ua, NULL, 7) == 1, "a new list replaces the old one (ub let through, ua stopped again); addresses of no object do no harm (compared only)");
            cmd("CHOOSE SET xyz"); cmd("CHOOSE SET %llX", (unsigned long long)(uintptr_t)ub + 4); cmd("CHOOSE SET 0"); cmd("CHOOSE SET"); cmd("CHOOSE MAYBE");
            check(status_line("CHOOSE on n=3 hits=4 sets=2 refused=5", 1) && ch(ub, NULL, 7) == 0, "5 bad forms refused (not hex, unaligned, null, no list, no verb); the list stays");
            {   static char big[300 * 13]; int k, n = 0;
                for (k = 0; k < 257; k++) n += _snprintf(big + n, sizeof(big) - (size_t)n, "%s%llX", k ? "," : "", 0x100000ull + (unsigned long long)k * 8);
                cmd("CHOOSE SET %s", big);
                check(status_line("CHOOSE on n=3 hits=5 sets=2 refused=6", 1), "a list of 257 refused (at most 256); the list stays"); }
            cmd("CHOOSE SET -");
            check(ch(ub, NULL, 7) == 1 && status_line("CHOOSE on n=0 ", 0), "CHOOSE SET - empties the list: everybody stopped again");
            cmd("CHOOSE SET %llX", (unsigned long long)(uintptr_t)ua);
            cmd("CHOOSE OFF");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("CHOOSE off n=1 ", 0) && ch(ua, NULL, 7) == 1, "CHOOSE OFF: .text byte-identical to the original; the list kept but not used (ua stopped)");
            cmd("CHOOSE ON"); cmd("ALLOFF");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("CHOOSE off n=0 ", 0), "ALLOFF takes the jump out and empties the list");
            check(status_line("P1 off", 1) && status_line("JG off", 1) && status_line("ROUT available", 1), "the other items are unaffected");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2 };
            img_t *m = build_image(&o);
            start("L2: CHOOSE site twice", m, NULL, NULL, NULL);
            check(status_line("CHOOSE unavailable CHOOSE signature has 2 hits (need exactly 1)", 1), "CHOOSE unavailable with two hits");
            cmd("CHOOSE ON"); cmd("CHOOSE SET 1000");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("CHOOSE unavailable", 0), "CHOOSE ON and SET wrote nothing");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 3 };
            img_t *m = build_image(&o);
            start("L3: CHOOSE site with other bytes where the hook goes (another build, or hooked before)", m, NULL, NULL, NULL);
            check(status_line("CHOOSE unavailable the chooser's list test does not hold its known bytes (hooked before?)", 1), "CHOOSE unavailable, with the reason");
            cmd("CHOOSE ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "CHOOSE ON wrote nothing");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0 };
            img_t *m = build_image(&o);
            start("L4: no chooser site (another game build)", m, NULL, NULL, NULL);
            check(status_line("CHOOSE unavailable CHOOSE signature has 0 hits (need exactly 1)", 1), "CHOOSE unavailable with no hit");
            check(status_line("ROUT available", 1) && status_line("JG off", 1), "the rest still works");
        }
    }

    /* ======================================================== N: NOREGION (the lead): a work hit at a building without a region */
    {
        static __declspec(align(16)) uint8_t world[0x40], region[0x40], lost[0x40];
        {
            opts_t o = { 1 };
            img_t *m;
            noregion_fn nr, nr2;
            size_t d, d2;
            o.noregion = 1;
            m = build_image(&o);
            nr = (noregion_fn)(void *)(m->text + m->noregion); nr2 = (noregion_fn)(void *)(m->text + m->noregion2);
            d = m->noregion + 18; d2 = m->noregion2 + 18;        /* the calls' four displacement bytes */
            start("N1: NOREGION, a null region is turned away before the game reads through it (both routines)", m, NULL, NULL, NULL);
            memset(world, 0, sizeof(world)); memset(region, 0, sizeof(region)); memset(lost, 0, sizeof(lost));
            *(void **)(region + 8) = world;                      /* the stand-in for GetWorld returns [object + 8] */
            g_gw_calls = g_gw_null = g_mgr_calls = 0;
            check(m->noregion && m->noregion2 && d < d2 && status_line("NOREGION off hits=0 refused=0", 1), "both routines found exactly once, their first calls go into the image, off");
            check(nr(region, NULL) == (void *)&g_fake_mgr && nr2(region, NULL) == (void *)&g_fake_mgr && g_gw_calls == 2 && g_mgr_calls == 2, "the game's own routines: a region with a world runs to the end");
            check(nr(lost, NULL) == NULL && nr2(lost, NULL) == NULL && g_gw_calls == 4 && g_mgr_calls == 2, "the game's own routines: a region without a world leaves");
            check(nr(NULL, NULL) == NULL && nr2(NULL, NULL) == NULL && g_gw_calls == 6 && g_gw_null == 2, "unpatched, a null region reaches GetWorld (there the game reads through it: the crash)");
            cmd("NOREGION ON");
            check(m->text[d - 1] == 0xE8 && m->text[d2 - 1] == 0xE8 && memcmp(m->text, m->snapshot, d) == 0 && memcmp(m->text + d, m->snapshot + d, 4) != 0 &&
                  memcmp(m->text + d + 4, m->snapshot + d + 4, d2 - d - 4) == 0 && memcmp(m->text + d2, m->snapshot + d2, 4) != 0 &&
                  memcmp(m->text + d2 + 4, m->snapshot + d2 + 4, TEXT_SIZE - d2 - 4) == 0 && status_line("NOREGION on hits=0 refused=0", 1),
                  "NOREGION ON: the two calls' four displacement bytes changed and nothing else; status on");
            check(nr(region, NULL) == (void *)&g_fake_mgr && nr2(region, NULL) == (void *)&g_fake_mgr && g_gw_calls == 8 && g_mgr_calls == 4, "on: a region with a world still goes through GetWorld and runs to the end");
            check(nr(lost, NULL) == NULL && nr2(lost, NULL) == NULL && g_gw_calls == 10 && g_mgr_calls == 4, "on: a region without a world still leaves by the game's own check");
            check(nr(NULL, NULL) == NULL && nr2(NULL, NULL) == NULL && g_gw_calls == 10 && g_gw_null == 2 && g_mgr_calls == 4, "on: a null region never reaches GetWorld and both routines leave");
            cmd("STATUS");
            check(status_line("NOREGION on hits=2 refused=0", 1), "status counts the two null regions turned away");
            cmd("NOREGION MAYBE"); cmd("NOREGION");
            check(status_line("NOREGION on hits=2 refused=2", 1), "2 bad forms refused; still on");
            cmd("NOREGION ON");
            check(status_line("NOREGION on hits=2 refused=2", 1) && memcmp(m->text + d2 + 4, m->snapshot + d2 + 4, TEXT_SIZE - d2 - 4) == 0, "ON twice changes nothing");
            cmd("NOREGION OFF");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("NOREGION off hits=2 refused=2", 1), "NOREGION OFF: .text byte-identical to the original");
            check(nr(NULL, NULL) == NULL && nr2(NULL, NULL) == NULL && g_gw_null == 4, "off again: a null region reaches GetWorld as in the game");
            cmd("NOREGION ON"); cmd("ALLOFF");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("NOREGION off ", 0), "ALLOFF puts both calls back");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.noregion = 2;
            m = build_image(&o);
            start("N2: the first NOREGION routine twice", m, NULL, NULL, NULL);
            check(status_line("NOREGION unavailable NOREGION signature has 2 hits (need exactly 1)", 1), "NOREGION unavailable with two hits");
            cmd("NOREGION ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("NOREGION unavailable", 0), "NOREGION ON wrote nothing");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.noregion = 3;
            m = build_image(&o);
            start("N3: a NOREGION routine whose first call leaves the image (another build, or redirected before)", m, NULL, NULL, NULL);
            check(status_line("NOREGION unavailable NOREGION: the routine's first call does not go into the game (redirected before?)", 1), "NOREGION unavailable, with the reason");
            cmd("NOREGION ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "NOREGION ON wrote nothing");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.noregion = 4;
            m = build_image(&o);
            start("N4: only the first NOREGION routine (the twin is not there)", m, NULL, NULL, NULL);
            check(status_line("NOREGION unavailable NOREGION2 signature has 0 hits (need exactly 1)", 1), "NOREGION unavailable: both or none");
            cmd("NOREGION ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "NOREGION ON wrote nothing");
        }
        {
            opts_t o = { 1 };
            img_t *m = build_image(&o);
            start("N5: no NOREGION routine (another game build)", m, NULL, NULL, NULL);
            check(status_line("NOREGION unavailable NOREGION signature has 0 hits (need exactly 1)", 1), "NOREGION unavailable with no hit");
            check(status_line("ROUT available", 1) && status_line("JG off", 1), "the rest still works");
        }
    }

    /* ======================================================== L: HOLD (lane 31) */
    {
        opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        img_t *m = build_image(&o);
        hreg_call appr = (hreg_call)(void *)(m->text + m->happr), order = (hreg_call)(void *)(m->text + m->horder), suppl = (hreg_call)(void *)(m->text + m->hsuppl);
        hwadd_call wadd = (hwadd_call)(void *)(m->text + m->hwadd);
        hwsub_call wsub = (hwsub_call)(void *)(m->text + m->hwsub);
        hpadd_call padd = (hpadd_call)(void *)(m->text + m->hpadd);
        hprem_call prem = (hprem_call)(void *)(m->text + m->hprem);
        hpall_call premall = (hpall_call)(void *)(m->text + m->hprmall);
        hwmon_call wmon = (hwmon_call)(void *)(m->text + m->hwmon);
        hreg_call emig = (hreg_call)(void *)(m->text + m->hemig), house = (hreg_call)(void *)(m->text + m->hhouse);   /* lane 36 */
        uint8_t *r1 = mk_hregion(m), *r2 = mk_hregion(m);
        uint8_t *b1 = mk_building(m, 72, NULL), *b2 = mk_building(m, 6, NULL);
        aarr_t *ra = (aarr_t *)(r1 + 0x1038), *ro = (aarr_t *)(r1 + 0x1060), *rm = (aarr_t *)(r1 + 0x1050);
        char line[2000]; int q, nb;
        start("L: HOLD, a region's panel numbers change only on the host's word", m, NULL, NULL, NULL);
        check(status_line("HOLD off", 1), "HOLD off after the scan (seven entries, the store site, the body offsets and the grow helper found)");
        check(status_line("P1 off", 1) && status_line("TOTALS unavailable", 0), "the other items are unaffected");
        cmd("HOLD SET %llu", (unsigned long long)(uintptr_t)r1);
        check(hold_num("refused=") == 1 && hold_num("regions=") == 0, "HOLD SET refused while the switch is off");

        /* the routines run as the game's while nothing is held */
        g_appr_calls = g_order_calls = g_suppl_calls = 0;
        appr(r1); order(r1); suppl(r1);
        check(g_appr_calls == 1 && g_order_calls == 1 && g_suppl_calls == 1 && *(int32_t *)(r1 + 0x1030) == 55 && *(int32_t *)(r1 + 0x104C) == 70 && *(float *)(r1 + 0x5A0) == 9.0f,
              "unhooked: updateApproval, the public order and the months run (approval 55, order 70, fuel 9)");
        wadd(r1, 5); check(*(int32_t *)(r1 + 0x648) == 105, "unhooked: addRegionalWealth adds (100 + 5)");
        check(wsub(r1, 10) == 1 && *(int32_t *)(r1 + 0x648) == 95, "unhooked: consumeRegionalWealth takes (105 - 10) and says true");
        wmon(r1, 7); check(*(int32_t *)(r1 + 0x648) == 102 && *(int32_t *)(r1 + 0x10F0) == 7, "unhooked: the monthly store adds (95 + 7)");
        *(int32_t *)(r1 + 0x4F0) = 20; *(int32_t *)(r2 + 0x4F0) = 20; g_emig_calls = 0;
        emig(r1); check(g_emig_calls == 1 && *(int32_t *)(r1 + 0x4F0) == 19, "lane 36, unhooked: the daily emigration runs (a family leaves: 20 -> 19)");
        *(int32_t *)(r1 + 0x10F4) = 2; house(r1); check(g_house_calls == 1 && *(int32_t *)(r1 + 0x10F4) == 0, "lane 36, unhooked: accomodateHomelessFamilies runs (2 homeless -> 0)");

        cmd("HOLD ON");
        {   size_t sites[11] = { m->happr, m->horder, m->hsuppl, m->hwadd, m->hwsub, m->hpadd, m->hprem, m->hprmall, 0, m->hemig, m->hhouse };
            int lens[11] = { 6, 7, 5, 7, 7, 5, 7, 6, 5, 5, 7 }, k, other = 1, jumps = 1; size_t i;
            for (i = 0; i + 1 < (size_t)m->pos; i++) if (m->snapshot[i] == 0x41 && m->snapshot[i + 1] == 0x89 && m->snapshot[i + 2] == 0x87 && m->snapshot[i + 3] == 0x48 && m->snapshot[i + 4] == 0x06) sites[8] = i;
            for (k = 0; k < 11; k++) if (m->text[sites[k]] != 0xE9) jumps = 0;
            for (i = 0; i < TEXT_SIZE; i++) {
                int inside = 0;
                for (k = 0; k < 11; k++) if (i >= sites[k] && i < sites[k] + (size_t)lens[k]) inside = 1;
                if (!inside && m->text[i] != m->snapshot[i]) other = 0;
            }
            check(jumps && other && status_line("HOLD on", 1), "HOLD ON: a jump at each of the seven entries and at the store site, nothing else changed; status HOLD on"); }
        appr(r2); check(g_appr_calls == 2 && *(int32_t *)(r2 + 0x1030) == 55, "a region nobody has named is left to the game (its approval rebuilt)");

        cmd("HOLD SET %llu", (unsigned long long)(uintptr_t)r1);
        check(hold_num("regions=") == 1 && hold_num("sets=") == 1, "HOLD SET: 1 region held");
        *(int32_t *)(r1 + 0x1030) = 76; *(int32_t *)(r1 + 0x104C) = 90; *(float *)(r1 + 0x5A0) = 18.0f;
        appr(r1); order(r1); suppl(r1);
        check(g_appr_calls == 2 && g_order_calls == 1 && g_suppl_calls == 1 && *(int32_t *)(r1 + 0x1030) == 76 && *(int32_t *)(r1 + 0x104C) == 90 && *(float *)(r1 + 0x5A0) == 18.0f,
              "held: updateApproval, the public order and the months do not run (76, 90, 18 stay)");
        wadd(r1, 5); check(*(int32_t *)(r1 + 0x648) == 102, "held: addRegionalWealth does not add");
        check(wsub(r1, 10) == 1 && *(int32_t *)(r1 + 0x648) == 102, "held: consumeRegionalWealth takes nothing and says true (102 covers 10)");
        check(wsub(r1, 500) == 0 && *(int32_t *)(r1 + 0x648) == 102, "held: ... and says false when the wealth does not cover it, without setting it to 0");
        r1[0x2E8] = 0; check(wsub(r1, 1) == 0, "held: ... and false for a region not settled"); r1[0x2E8] = 1;
        wmon(r1, 7); check(*(int32_t *)(r1 + 0x648) == 102 && *(int32_t *)(r1 + 0x10F0) == 7, "held: the monthly store is not made; xmm4 survives the stub (7)");
        g_emig_calls = 0; emig(r1);
        check(g_emig_calls == 0 && *(int32_t *)(r1 + 0x4F0) == 19 && hold_num("emigration=") == 1, "lane 36, held: the daily emigration does not run (nobody leaves: 19 stays; counted)");
        emig(r2); check(g_emig_calls == 1 && *(int32_t *)(r2 + 0x4F0) == 19, "lane 36: another region's emigration runs (20 -> 19)");
        *(int32_t *)(r1 + 0x10F4) = 3; g_house_calls = 0; house(r1);
        check(g_house_calls == 0 && *(int32_t *)(r1 + 0x10F4) == 3 && hold_num("housing=") == 1, "lane 36, held: accomodateHomelessFamilies does not run (3 homeless stay; counted)");
        *(int32_t *)(r2 + 0x10F4) = 3; house(r2); check(g_house_calls == 1 && *(int32_t *)(r2 + 0x10F4) == 0, "lane 36: another region's housing runs (3 -> 0)");
        wmon(r2, 9); check(*(int32_t *)(r2 + 0x648) == 109, "another region's monthly store is made (100 + 9)");
        wadd(r2, 1); check(*(int32_t *)(r2 + 0x648) == 110 && wsub(r2, 10) == 1 && *(int32_t *)(r2 + 0x648) == 100, "another region's wealth routines run");
        g_padd_calls = g_prem_calls = 0;
        check(padd(r1, 31, b1, NULL) == 0 && nprob(r1) == 0 && g_padd_calls == 0, "held: add a problem does not add it and says it was not there");
        check(padd(r2, 31, b1, NULL) == 0 && nprob(r2) == 1, "another region's problem is added");
        {   thr_hold_t tt; HANDLE th; unsigned long long n0 = hold_num("otherthread=");
            tt.m = m; tt.r = r1; th = CreateThread(NULL, 0, other_thread_hold, &tt, 0, NULL); WaitForSingleObject(th, INFINITE); CloseHandle(th);
            check(*(int32_t *)(r1 + 0x648) == 105 && hold_num("otherthread=") == n0 + 1, "a call from another thread is passed through and counted (102 + 3)"); }
        *(int32_t *)(r1 + 0x648) = 102;

        /* the host's lists */
        cmd("HOLD ROWS %llu A 12:0:8:302:307:1/32:0:4.25:302:307:1/12:1:4:297:302:1", (unsigned long long)(uintptr_t)r1);
        check(ra->num == 3 && ra->max == 4 && ra->data[1].type == 32 && ra->data[1].effect == 4.25f && ra->data[2].past == 1 && ra->data[2].day == 297 && ra->data[2].exp == 302 && ra->data[2].count == 1,
              "HOLD ROWS A: 3 rows written in place (32 at 4.25; the third a past row of day 297)");
        g_grow_calls = 0; nb = 0;
        for (q = 0; q < 9; q++) nb += _snprintf(line + nb, sizeof(line) - (size_t)nb, "%s%d:%d:%d.5:%d:%d:1", q ? "/" : "", q, q & 1, -q, 300 + q, 305 + q);
        cmd("HOLD ROWS %llu A %s", (unsigned long long)(uintptr_t)r1, line);
        check(ra->num == 9 && ra->max >= 9 && g_grow_calls == 1 && ra->data[8].type == 8 && ra->data[8].effect == -8.5f && ra->data[7].past == 1 && hold_num("grown=") == 1,
              "HOLD ROWS A: 9 rows, more than the list holds: grown once with the game's helper, all written");
        cmd("HOLD ROWS %llu A 2:0:-1:300:305:1", (unsigned long long)(uintptr_t)r1);
        check(ra->num == 1 && ra->data[0].type == 2 && ra->data[0].effect == -1.0f, "HOLD ROWS A: one row: the list is cut to it");
        cmd("HOLD ROWS %llu O 17:0:-10:302:307:1/20:0:-10:302:307:1", (unsigned long long)(uintptr_t)r1);
        cmd("HOLD ROWS %llu M -", (unsigned long long)(uintptr_t)r1);
        check(ro->num == 2 && ro->data[1].type == 20 && rm->num == 0, "HOLD ROWS O (2 rows) and M (empty, '-')");
        cmd("HOLD ROWS %llu X 1:0:1:1:1:1", (unsigned long long)(uintptr_t)r1);
        cmd("HOLD ROWS %llu A 1:2:1:1:1:1", (unsigned long long)(uintptr_t)r1);
        cmd("HOLD ROWS %llu A 1:0:abc:1:1:1", (unsigned long long)(uintptr_t)r1);
        cmd("HOLD ROWS %llu A 1:0:1:1:1", (unsigned long long)(uintptr_t)r1);
        cmd("HOLD ROWS %llu A 1:0:1:1:1:1", (unsigned long long)(uintptr_t)r2);
        check(ra->num == 1 && ((aarr_t *)(r2 + 0x1038))->num == 2 && hold_num("refused=") == 6, "HOLD ROWS refused 5 bad forms (list X, past 2, effect not a number, a row too short, a region not held)");

        g_padd_calls = g_prem_calls = 0;
        cmd("HOLD PROB %llu 31:%llu:0/26:0:0/31:%llu:0", (unsigned long long)(uintptr_t)r1, (unsigned long long)(uintptr_t)b1, (unsigned long long)(uintptr_t)b2);
        check(nprob(r1) == 3 && has_prob(r1, 31, b1, NULL) && has_prob(r1, 26, NULL, NULL) && has_prob(r1, 31, b2, NULL) && g_padd_calls == 3,
              "HOLD PROB: three problems added with the game's own routine (it ran: the DLL's own call passes the hook)");
        cmd("HOLD PROB %llu 26:0:0/38:0:0", (unsigned long long)(uintptr_t)r1);
        check(nprob(r1) == 2 && has_prob(r1, 26, NULL, NULL) && has_prob(r1, 38, NULL, NULL) && !has_prob(r1, 31, b1, NULL) && g_prem_calls == 2 && g_padd_calls == 4,
              "HOLD PROB: the list becomes exactly the host's (two removed with the game's own routine, one added, one kept)");
        prem(r1, 26, NULL, NULL); check(nprob(r1) == 2 && g_prem_calls == 2, "held: the game's own remove does not run");
        check(padd(r1, 26, NULL, NULL) == 1 && nprob(r1) == 2, "held: the game's own add says the problem was there");
        g_premall_calls = 0; premall(r1, 26);
        check(nprob(r1) == 2 && g_premall_calls == 0, "held: the game's own remove-all-of-a-kind does not run");
        premall(r2, 31);
        check(nprob(r2) == 0 && g_premall_calls == 1, "another region's remove-all-of-a-kind runs (its kind 31 gone)");
        cmd("HOLD PROB %llu 31:%llu:0", (unsigned long long)(uintptr_t)r1, (unsigned long long)(uintptr_t)badvt);
        cmd("HOLD PROB %llu 31:xyz:0", (unsigned long long)(uintptr_t)r1);
        cmd("HOLD PROB %llu 300:0:0", (unsigned long long)(uintptr_t)r1);
        check(nprob(r1) == 2 && hold_num("refused=") == 9, "HOLD PROB refused 3 bad forms (a building with no vtable in the module, not a number, type over 255)");
        cmd("HOLD PROB %llu -", (unsigned long long)(uintptr_t)r1);
        check(nprob(r1) == 0, "HOLD PROB -: no problems");

        cmd("HOLD DUMP");
        {   wchar_t sp[MAX_PATH]; _snwprintf(sp, MAX_PATH, L"%shold_dump.txt", g_io);
            check(strstr(read_file(sp), "approval 76 order 90 wealth 102") != NULL && strstr(g_buf, "rowsO 2: 17:-10.0000") != NULL, "HOLD DUMP: the region's numbers and lists"); }

        g_appr_calls = 0;
        cmd("HOLD OFF");
        check(g_appr_calls == 1 && *(int32_t *)(r1 + 0x1030) == 55 && hold_num("recounts=") == 1, "HOLD OFF, the recount: the game's own updateApproval ran once for the held region (approval 55 from its own families)");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("HOLD off", 1), "... every byte back; the whole .text is byte-identical to the original; status HOLD off");
        wadd(r1, 5); order(r1); check(*(int32_t *)(r1 + 0x648) == 107 && *(int32_t *)(r1 + 0x104C) == 70, "off: the routines run again (wealth 102 + 5, order 70)");

        cmd("HOLD ON"); cmd("HOLD SET %llu", (unsigned long long)(uintptr_t)r1);
        g_appr_calls = 0; cmd("HOLD FORGET");
        check(g_appr_calls == 0 && memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && hold_num("forgot=") == 1, "HOLD FORGET: no recount (a load made new regions), the hooks out");

        cmd("HOLD ON"); cmd("HOLD SET %llu", (unsigned long long)(uintptr_t)r1);
        *(uint32_t *)(r1 + 0x0C) += 1000;
        g_appr_calls = 0; cmd("HOLD OFF");
        check(g_appr_calls == 0 && hold_num("forgot=") == 2, "a region that is no longer the same object is forgotten at OFF, not recounted");
        *(uint32_t *)(r1 + 0x0C) -= 1000;

        cmd("HOLD ON"); cmd("HOLD SET %llu", (unsigned long long)(uintptr_t)r1);
        g_appr_calls = 0; cmd("ALLOFF");
        check(g_appr_calls == 1 && memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "ALLOFF recounts too and takes the hooks out");

        {   /* a hook that faults: a held region whose problem list cannot be read */
            parr_t *pl = (parr_t *)(r1 + 0xD80); prob_t *keep = pl->data;
            cmd("HOLD ON"); cmd("HOLD SET %llu", (unsigned long long)(uintptr_t)r1);
            pl->data = (prob_t *)(uintptr_t)0x10; pl->num = 1;
            g_padd_calls = 0;
            padd(r1, 31, b1, NULL);
            check(g_padd_calls == 1, "a hook that faults is caught and the game's routine still runs");
            pl->data = keep; pl->num = 0;
            g_tick(NULL);
            check(status_line("HOLD unavailable exception C0000005 in a hook or a write", 1) && memcmp(m->text, m->snapshot, TEXT_SIZE) == 0,
                  "at the next tick the switch is out (HOLD unavailable), every byte restored");
            check(status_line("ready", 0) && status_line("P1 off", 1), "the DLL itself stays ready");
            cmd("HOLD ON");
            check(m->text[m->happr] == 0x40, "HOLD ON is refused after that");
        }
    }

    /* ======================================================== M: HOLD when updateApproval's grow call goes elsewhere */
    {
        opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
        img_t *m = build_image(&o);
        start("M: HOLD, the grow helper is not the known one", m, NULL, NULL, NULL);
        check(status_line("HOLD unavailable the list grow helper at rva", 0), "HOLD unavailable, with the reason");
        cmd("HOLD ON");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "HOLD ON wrote nothing");
        check(status_line("P1 off", 1) && status_line("ROUT available", 1), "the other items are unaffected");
    }
    {
        opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0 };
        img_t *m = build_image(&o);
        start("M2: HOLD, none of its routines in the module", m, NULL, NULL, NULL);
        check(status_line("HOLD unavailable HAPPR signature has 0 hits (need exactly 1)", 1), "HOLD unavailable when its signatures are not there (another game build)");
    }

    /* ======================================================== M: PICK (lane 35): the chooser's pick held to the host's task */
    {
        static __declspec(align(16)) uint8_t ua[0x1000], ub[0x1000];
        static __declspec(align(16)) uint8_t r27[0xD8], r27b[0xD8], r22[0xD8], r41a[0xD8], r41b[0xD8];
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
            img_t *m = build_image(&o);
            settask_fn st = (settask_fn)(void *)(m->text + m->pk_settask);
            think_fn th = (think_fn)(void *)(m->text + m->pk_think);
            uint64_t ox1 = 0x7FF0000A000ull, ox2 = 0x7FF0000B000ull;
            memset(ua, 0, sizeof(ua)); memset(ub, 0, sizeof(ub));
            memset(r27, 0, 0xD8); memset(r27b, 0, 0xD8); memset(r22, 0, 0xD8); memset(r41a, 0, 0xD8); memset(r41b, 0, 0xD8);
            r27[0] = 27; r27b[0] = 27; r27b[8] = 1; r22[0] = 22; r41a[0] = 41; r41b[0] = 41;
            memcpy(r41a + 0xA8, &ox1, 8); memcpy(r41b + 0xA8, &ox2, 8); memcpy(r27 + 0xA8, &ox2, 8);
            start("M1: PICK, the chooser's pick held to one task (known build)", m, NULL, NULL, NULL);
            check(status_line("PICK off n=0 same=0 subst=0 left=0 kept=0 seeded=0 other=0 sets=0 bad=0 faults=0 gone=0 dropped=0 stale=0 follow=0 followok=0 followleft=0", 1), "PICK found (SETTASK, CHOOSECALL, the chooser), off");
            g_pick_rec = r22; th(ua);
            check(*(int32_t *)ua == 1 && ua[8] == 22, "the game's own think: the chooser's pick (22) is set");
            cmd("PICK ON");
            check(m->text[m->pk_settask] == 0xE9 && m->text[m->pk_call] == 0xE8 && memcmp(m->text, m->snapshot, m->pk_settask) == 0 &&
                  memcmp(m->text + m->pk_settask + 5, m->snapshot + m->pk_settask + 5, m->pk_call - m->pk_settask - 5) == 0 &&
                  memcmp(m->text + m->pk_call + 5, m->snapshot + m->pk_call + 5, TEXT_SIZE - m->pk_call - 5) == 0 &&
                  memcmp(m->text + m->pk_call + 1, m->snapshot + m->pk_call + 1, 4) != 0 && status_line("PICK on n=0 ", 0),
                  "PICK ON: a jump at setTask's entry, the chooser call pointed elsewhere, nothing else changed");
            th(ua);
            check(*(int32_t *)ua == 2 && ua[8] == 22, "on, nobody named: as before");
            cmd("PICK SET %llX:1B:0", (unsigned long long)(uintptr_t)ua);
            th(ua); cmd("STATUS");
            check(*(int32_t *)ua == 3 && ua[8] == 22 && status_line("PICK on n=1 same=0 subst=0 left=1 ", 0), "named for 27, nothing kept yet: the chooser's 22 stays (left to the board)");
            st(ua, r27); cmd("STATUS");
            check(*(int32_t *)ua == 4 && ua[8] == 27 && status_has("kept=1 "), "a setTask of 27 outside the chooser (the board's give) is done and kept");
            th(ua); cmd("STATUS");
            check(*(int32_t *)ua == 6 && ua[8] == 27 && *(uint64_t *)(ua + 0x10) == ox2 && status_has("subst=1 left=1 "), "the chooser's 22 is followed by setTask(kept 27) as it returns (its target too)");
            g_pick_rec = r27b; th(ua); cmd("STATUS");
            check(*(int32_t *)ua == 7 && ua[8] == 27 && status_has("same=1 "), "the chooser's own 27 is done once and kept");
            st(ua, r22);
            check(*(int32_t *)ua == 8 && ua[8] == 22, "outside the chooser a 22 is done (the board's other gives)");
            g_pick_rec = r22; th(ub);
            check(*(int32_t *)ub == 1 && ub[8] == 22, "another villager: as before");
            cmd("PICK SET %llX:29:%llX", (unsigned long long)(uintptr_t)ua, (unsigned long long)ox1);
            g_pick_rec = r41b; th(ua); cmd("STATUS");
            check(*(int32_t *)ua == 9 && *(uint64_t *)(ua + 0x10) == ox2 && status_has("left=2 "), "named for 41 with ox 1: the chooser's 41 with ox 2 stays while nothing is kept for that task");
            st(ua, r41a); th(ua); cmd("STATUS");
            check(*(int32_t *)ua == 12 && ua[8] == 41 && *(uint64_t *)(ua + 0x10) == ox1 && status_has("subst=2 "), "after the board's 41 with ox 1, the chooser's ox 2 is followed by ox 1");
            cmd("PICK SET %llX:29:%llX", (unsigned long long)(uintptr_t)ua, (unsigned long long)ox1); th(ua); cmd("STATUS");
            check(*(int32_t *)ua == 14 && *(uint64_t *)(ua + 0x10) == ox1 && status_has("subst=3 "), "the same entry sent again keeps its kept record");
            *(uint8_t **)(ub + 0x898) = r27; *(int32_t *)(ub + 0x8A0) = 1;
            cmd("PICK SET %llX:29:%llX,%llX:1B:0", (unsigned long long)(uintptr_t)ua, (unsigned long long)ox1, (unsigned long long)(uintptr_t)ub);
            g_pick_rec = r22; th(ub); cmd("STATUS");
            check(*(int32_t *)ub == 3 && ub[8] == 27 && status_has("seeded=1 ") && status_has("subst=4 "), "a villager put on the list while on that task has it kept at once (its first 22 is followed by 27)");
            cmd("PICK SET xyz"); cmd("PICK SET 1000:1B"); cmd("PICK SET 1001:1B:0"); cmd("PICK SET 1000:1FF:0"); cmd("PICK MAYBE");
            check(status_line("PICK on n=2 ", 0) && status_has("bad=5 "), "5 bad forms refused (not hex, no target, unaligned, type over 255, no verb); the list stays");
            check(status_line("PICKS replaced 22x3 41x3", 1), "the status names the picks followed: 22 three times, 41 three times");
            cmd("PICK OFF");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("PICK off n=2 ", 0), "PICK OFF: .text byte-identical to the original; the list kept");
            g_pick_rec = r22; th(ua);
            check(ua[8] == 22, "off: the chooser's pick is done again");
            cmd("PICK ON"); cmd("ALLOFF");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("PICK off n=0 ", 0), "ALLOFF takes both hooks out and empties the list");
            check(status_line("CHOOSE off", 0) && status_line("JG off", 1), "the other items are unaffected");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
            img_t *m = build_image(&o);
            start("M2: PICK on another game build", m, NULL, NULL, NULL);
            check(status_line("PICK unavailable another game build", 0), "PICK unavailable: another build");
            cmd("PICK ON"); cmd("PICK SET 1000:1B:0");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "PICK ON and SET wrote nothing");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 2 };
            img_t *m = build_image(&o);
            start("M3: the think's call reaches another routine", m, NULL, NULL, NULL);
            check(status_line("PICK unavailable CHOOSECALL's call does not reach the chooser", 1), "PICK unavailable, with the reason");
            cmd("PICK ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "PICK ON wrote nothing");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 3 };
            img_t *m = build_image(&o);
            start("M4: setTask starts otherwise (another build)", m, NULL, NULL, NULL);
            check(status_line("PICK unavailable signature hits SETTASK 0 CHOOSECALL 1 CHOOSE 1 (need exactly 1 each)", 1), "PICK unavailable: no setTask hit");
            check(status_line("ROUT available", 1), "the rest still works");
        }
    }

    /* ======================================================== Q: FIELD (lane 40): a field's plants on the host's word */
    {
        static __declspec(align(16)) uint8_t fb[0x2000], fb2[0x2000], fb3[0x2000], eng[0x2000], ism[0x200];
        static __declspec(align(16)) uint8_t pl[4 * FL_PLANT], pl2[4 * FL_PLANT], pts[16 * 24];
        {
            opts_t o = { 1 };
            img_t *m;
            fcache_call fc;
            const char *out;
            wchar_t outp[MAX_PATH];
            int i;
            float stp = 0.03125f;
            o.known = 1; o.field = 1;
            m = build_image(&o);
            fc = (fcache_call)(void *)(m->text + m->fl_cache);
            memset(fb, 0, sizeof(fb)); memset(fb2, 0, sizeof(fb2)); memset(fb3, 0, sizeof(fb3)); memset(eng, 0, sizeof(eng)); memset(ism, 0, sizeof(ism));
            memset(pl, 0, sizeof(pl)); memset(pl2, 0, sizeof(pl2)); memset(pts, 0, sizeof(pts));
            *(uint8_t **)fb = m->base + 0x100; *(uint8_t **)fb2 = m->base + 0x100; *(uint8_t **)fb3 = m->base + 0x100;   /* "vtables" in the module */
            *(uint32_t *)(fb + 0x0C) = 11; *(uint64_t *)(fb + 0x18) = 0x1111; *(uint32_t *)(fb2 + 0x0C) = 12; *(uint64_t *)(fb2 + 0x18) = 0x2222;
            *(uint32_t *)(fb3 + 0x0C) = 13; *(uint64_t *)(fb3 + 0x18) = 0x3333;
            *(uint8_t **)ism = m->base + 0x100;
            *(uint8_t **)(eng + 0x628) = eng;                       /* the brush's target */
            for (i = 0; i < 4; i++) { *(uint8_t **)(pl + i * FL_PLANT + 0xB0) = ism; *(uint8_t **)(pl2 + i * FL_PLANT + 0xB0) = ism; *(double *)(pl + i * FL_PLANT + 8) = 100.0 * i; }
            *(uint8_t **)(fb + 0x530) = pl; *(int32_t *)(fb + 0x538) = 4; *(int32_t *)(fb + 0x53C) = 4; *(uint8_t **)(fb + 0x2E8) = eng;
            *(uint8_t **)(fb + 0x2C8) = eng; *(uint8_t **)(fb2 + 0x2C8) = eng; *(uint8_t **)(fb3 + 0x2C8) = eng;   /* a region: the field is in the game */
            *(uint8_t **)(fb2 + 0x530) = pl2; *(int32_t *)(fb2 + 0x538) = 4; *(int32_t *)(fb2 + 0x53C) = 4; *(uint8_t **)(fb2 + 0x2E8) = eng;
            *(uint8_t **)(fb3 + 0x660) = pts; *(int32_t *)(fb3 + 0x668) = 16; *(int32_t *)(fb3 + 0x66C) = 16;
            start("Q1: FIELD, a field's plants on the host's word (known build)", m, NULL, NULL, NULL);
            _snwprintf(outp, MAX_PATH, L"%sfield_out.txt", g_io);
            check(status_line("FIELD idle", 1), "FIELD found (FCACHE, FDRAW, FPAINT), idle");
            g_fc_calls = g_fd_calls = g_fp_calls = 0;
            fc(fb, 1, 1, 1, 1);
            check(g_fc_calls == 1, "the game's own UpdateFieldCache runs");
            cmd("FIELD HOOK ON"); cmd("STATUS");
            check(status_line("FIELD hooked", 1) && m->text[m->fl_cache] == 0xE9 && bytes_are(m->text + m->fl_cache + 5, "90 90 90") &&
                  memcmp(m->text + m->fl_cache + 8, m->snapshot + m->fl_cache + 8, TEXT_SIZE - m->fl_cache - 8) == 0 && memcmp(m->text, m->snapshot, m->fl_cache) == 0,
                  "FIELD HOOK ON: only FCACHE's first 8 bytes changed (a jump and 3 NOPs); status hooked (never the word on)");
            cmd("FIELD HOLD %llu", (unsigned long long)(uintptr_t)fb);
            cmd("FIELD SET %llu 4 c000000000000000000000000000000000000000000000005000000000000000000000000000000000000000000000000", (unsigned long long)(uintptr_t)fb);
            cmd("FIELD SET %llu 4 0-3=10.3F800000.3E800000.0.0.5", (unsigned long long)(uintptr_t)fb);
            check(pl[0] == 10 && *(float *)(pl + 3 * FL_PLANT + 0x20) == 1.0f && *(float *)(pl + 2 * FL_PLANT + 0x24) == 0.25f && pl[3 * FL_PLANT + 0xC1] == 5,
                  "FIELD SET: the host's crop, plough, growth and fertility in every plant");
            check(g_fd_calls == 4 && g_fp_calls == 8 && g_fp_add_last == 1 && g_fp_amt_last == 1.0f && g_fc_calls == 3 && *(int32_t *)(fb + 0xBF4) == 5,
                  "each plant drawn by the game's routine, its ground cleared and ploughed again by the game's brush, then the game's own count once (the host's counted numbers over the game's own)");
            g_fd_calls = g_fp_calls = 0; g_fc_seen_gr2 = -1.0f;
            *(float *)(pl + 2 * FL_PLANT + 0x24) = 0.9f; *(float *)(pl + 2 * FL_PLANT + 0x20) = 0.0f;      /* this copy's villager harvested plant 2 */
            fc(fb, 1, 1, 1, 1);
            check(g_fc_seen_gr2 == 0.25f && *(int32_t *)(fb + 0xBF4) == 5 && *(float *)(pl + 2 * FL_PLANT + 0x20) == 1.0f && g_fd_calls == 1 && g_fd_last == 2 && g_fp_calls == 2,
                  "this copy's own change of a held field is put back before the game's count sees it, plant 2 drawn again, its ground painted again");
            g_fd_calls = 0;
            fc(fb, 1, 1, 1, 1);
            check(g_fd_calls == 0 && g_fc_calls == 5, "nothing differs: nothing drawn");
            fc(fb2, 1, 1, 1, 1);
            check(g_fc_calls == 6 && g_fd_calls == 0, "a field that is not held passes untouched");
            *(uint8_t **)(fb + 0x2C8) = NULL; *(float *)(pl + 2 * FL_PLANT + 0x24) = 0.7f; g_fd_calls = 0;      /* demolished: no region */
            fc(fb, 1, 1, 1, 1);
            check(*(float *)(pl + 2 * FL_PLANT + 0x24) == 0.7f && g_fd_calls == 0 && g_fc_calls == 7, "a held field that has left the game (no region) is not written, drawn or painted; the game's routine still runs");
            *(uint8_t **)(fb + 0x2C8) = eng; *(float *)(pl + 2 * FL_PLANT + 0x24) = 0.25f;
            cmd("FIELD SET %llu 4 g3D000000:0-1,3", (unsigned long long)(uintptr_t)fb);
            check(*(float *)(pl + 0x24) == 0.25f + stp && *(float *)(pl + 2 * FL_PLANT + 0x24) == 0.25f && *(float *)(pl + 3 * FL_PLANT + 0x24) == 0.25f + stp,
                  "a growth step: growth = growth + step for the named plants only");
            *(float *)(pl + 1 * FL_PLANT + 0x24) = 0.5f;            /* a change that reaches no count */
            Sleep(2100); g_tick(NULL); cmd("STATUS");
            check(*(float *)(pl + 1 * FL_PLANT + 0x24) == 0.25f + stp && status_has(" leaks=1 "), "the audit finds a change that reached no count and puts it back");
            cmd("FIELD SET 12345 4 0=1.0.0.0.0.0"); cmd("FIELD SET %llu 4 0=bad", (unsigned long long)(uintptr_t)fb); cmd("FIELD HOLD 8"); cmd("STATUS");
            check(status_has(" refused=3 "), "a field that is not held, a bad record and a bad address are refused");
            /* host side */
            for (i = 0; i < 4; i++) { pl2[i * FL_PLANT] = 12; *(float *)(pl2 + i * FL_PLANT + 0x20) = 1.0f; *(float *)(pl2 + i * FL_PLANT + 0x24) = 0.5f; }
            cmd("FIELD WATCH %llu", (unsigned long long)(uintptr_t)fb2);
            cmd("FIELD POLL"); out = read_file(outp); DeleteFileW(outp);   /* the mod reads it once and deletes it */
            check(strstr(out, " 4 ") && strstr(out, "0-3=12.3F800000.3F000000.0.0.0"), "POLL: a new watched field is sent whole, equal plants in one run");
            cmd("FIELD POLL"); out = read_file(outp); DeleteFileW(outp);   /* the mod reads it once and deletes it */
            check(out[0] == 0, "POLL again: nothing changed, nothing written");
            for (i = 0; i < 4; i++) *(float *)(pl2 + i * FL_PLANT + 0x24) = 0.5f + stp;
            pl2[3 * FL_PLANT] = 13;
            cmd("FIELD POLL"); out = read_file(outp); DeleteFileW(outp);   /* the mod reads it once and deletes it */
            check(strstr(out, "g3D000000:0-2") && strstr(out, ";3=13."), "POLL: the day's growth as one step for a run of plants, another change as a record");
            {
                char crc[16]; const char *sp;
                sp = strchr(out, ' '); sp = sp ? strchr(sp + 1, ' ') : NULL; crc[0] = 0;
                if (sp) sscanf(sp + 1, "%15s", crc);
                for (i = 0; i < 4; i++) memcpy(pl + i * FL_PLANT, pl2 + i * FL_PLANT, FL_PLANT);
                cmd("FIELD HOOK OFF"); cmd("FIELD HOOK ON"); cmd("FIELD HOLD %llu", (unsigned long long)(uintptr_t)fb);
                cmd("FIELD CHECK %llu 4 0x%s", (unsigned long long)(uintptr_t)fb, crc);
                cmd("FIELD CHECK %llu 4 0x1", (unsigned long long)(uintptr_t)fb); cmd("STATUS");
                check(status_has(" checkok=1 checkbad=1 "), "CHECK: the host's checksum matches equal plants, a wrong one is counted");
            }
            cmd("FIELD CUT %llu 0x660 12", (unsigned long long)(uintptr_t)fb3);
            cmd("FIELD CUT %llu 0x660 12", (unsigned long long)(uintptr_t)fb3);
            cmd("FIELD CUT %llu 0x700 2", (unsigned long long)(uintptr_t)fb3); cmd("STATUS");
            check(*(int32_t *)(fb3 + 0x668) == 12 && status_has(" cuts=1 "), "CUT: a point list cut to the host's length once; not longer, not another list");
            {   /* the drawn size: a mesh whose vtable (in the module's .data) has UpdateInstanceTransform at +B58h */
                static __declspec(align(16)) uint8_t ism2[0x200];
                uint8_t *vt = m->base + DATA_RVA + 0x100;
                double half = 0.5, sx;
                DWORD o2;
                VirtualProtect(m->base + DATA_RVA, 0x1000, PAGE_READWRITE, &o2);
                *(uint8_t **)(vt + 0xB58) = m->text + m->fl_upd;
                memset(ism2, 0, sizeof(ism2)); *(uint8_t **)ism2 = vt;
                for (i = 0; i < 4; i++) { *(uint8_t **)(pl + i * FL_PLANT + 0xB0) = ism2; *(int32_t *)(pl + i * FL_PLANT + 0x28) = 40 + i; *(double *)(pl + i * FL_PLANT + 0x90) = 0.25; }
                g_fu_calls = 0;
                cmd("FIELD SET %llu 4 0-2=12.3F800000.3F080000.0.0.0;3=13.3F800000.3F080000.0.0.0;d1-2=3FE0000000000000.3FE0000000000000.3FE0000000000000", (unsigned long long)(uintptr_t)fb);
                memcpy(&sx, pl + 2 * FL_PLANT + 0x90, 8);
                check(g_fu_calls == 2 && g_fu_idx == 42 && g_fu_world == 1 && g_fu_dirty == 1 && g_fu_sx == half && sx == half && *(double *)(pl + 0x90) == 0.25,
                      "the host's drawn size: the mesh's own UpdateInstanceTransform for plants 1 and 2 (world space, dirty), kept in the plant");
                *(double *)(pl + 1 * FL_PLANT + 0x90) = 0.3;          /* this copy's own drawing changed the size */
                g_fu_calls = 0; fc(fb, 1, 1, 1, 1);
                check(g_fu_calls == 1 && *(double *)(pl + 1 * FL_PLANT + 0x90) == 0.5, "a size this copy drew otherwise is put back at the count");
                for (i = 0; i < 4; i++) *(uint8_t **)(pl + i * FL_PLANT + 0xB0) = ism;
            }
            cmd("FIELD HOOK OFF"); cmd("STATUS");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("FIELD idle", 1) && status_has("fields held=0 watched=1 "),
                  "FIELD HOOK OFF: .text byte-identical, the held fields dropped, the watched one kept");
            cmd("FIELD HOOK ON"); cmd("ALLOFF"); cmd("STATUS");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("FIELD idle", 1), "ALLOFF takes the hook out");
            /* a fault inside the hook */
            cmd("FIELD HOOK ON"); cmd("FIELD HOLD %llu", (unsigned long long)(uintptr_t)fb);
            cmd("FIELD SET %llu 4 0-3=10.3F800000.3E800000.0.0.5", (unsigned long long)(uintptr_t)fb);
            *(uint8_t **)(fb + 0x530) = (uint8_t *)(uintptr_t)0x10;   /* a list the hook cannot read */
            fc(fb, 1, 1, 1, 1);
            *(uint8_t **)(fb + 0x530) = pl;
            g_tick(NULL); cmd("STATUS");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("FIELD unavailable exception C0000005 in the hook", 1) && status_line("ROUT available", 1),
                  "an exception in the hook is caught, the hook goes out at the next tick, the item stays off, the rest works");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.field = 1;
            m = build_image(&o);
            start("Q2: the FIELD routines on another game build", m, NULL, NULL, NULL);
            check(status_line("FIELD unavailable not the known game build (the plant offsets are not in a signature)", 1), "FIELD unavailable: another build");
            cmd("FIELD HOOK ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "FIELD HOOK ON wrote nothing");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.known = 1; o.field = 2;
            m = build_image(&o);
            start("Q3: the FIELD routines twice", m, NULL, NULL, NULL);
            check(status_line("FIELD unavailable signature hits FCACHE 2 FDRAW 2 FPAINT 2 (need exactly 1 each)", 1), "FIELD unavailable with two hits");
            cmd("FIELD HOOK ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "FIELD HOOK ON wrote nothing");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.known = 1;
            m = build_image(&o);
            start("Q4: no FIELD routine", m, NULL, NULL, NULL);
            check(status_line("FIELD unavailable signature hits FCACHE 0 FDRAW 0 FPAINT 0 (need exactly 1 each)", 1), "FIELD unavailable with no hit");
            check(status_line("ROUT available", 1), "the rest still works");
        }
    }

    /* ======================================================== D: DIST (lane 42): a house's market goods on the host's word */
    {
        static __declspec(align(16)) uint8_t region[0x1200], region2[0x1200], house[0x1000];
        {
            opts_t o = { 1 };
            img_t *m;
            dist_mk_fn mk;
            fgood_t *two = (fgood_t *)calloc(2, sizeof(fgood_t));
            garr_t *a = (garr_t *)(house + 0xE90);
            size_t d;
            o.goods = 1; o.dist = 1;
            m = build_image(&o);
            mk = (dist_mk_fn)(void *)(m->text + m->dist_mk); d = m->dist_call + 1;
            start("D1: DIST, the host's list back into a house right after the game's own distribution", m, NULL, NULL, NULL);
            memset(region, 0, sizeof(region)); memset(region2, 0, sizeof(region2)); memset(house, 0, sizeof(house));
            *(void **)house = m->base + 0x1000;                  /* a vtable inside the module: the object looks like one */
            *(uint32_t *)(house + 0x0C) = 77; *(uint64_t *)(house + 0x18) = 0x1234;
            *(uint8_t **)(house + 0x2C8) = region;
            a->data = two; a->num = 0; a->max = 2;
            *(int32_t *)(region + 0x1130) = 5;
            g_dist_house = house; g_dist_calls = g_dgrow_calls = g_dsurp_calls = 0; g_rf_calls = 0;
            check(status_line("DIST off houses=0 sets=0 writes=0 putbacks=0 calls=0 otherthread=0 refused=0 faults=0", 1), "all four found exactly once, the call reaches the distribution, off");
            mk(region); cmd("STATUS");
            check(g_dist_calls == 1 && *(int32_t *)(region + 0x1130) == 4 && a->num == 1 && a->data[0].type == 216, "the game's own: the market routine's call runs the distribution (counter down, the friend's own list)");
            cmd("DIST ON");
            check(m->text[d - 1] == 0xE8 && memcmp(m->text, m->snapshot, d) == 0 && memcmp(m->text + d, m->snapshot + d, 4) != 0 &&
                  memcmp(m->text + d + 4, m->snapshot + d + 4, TEXT_SIZE - d - 4) == 0 && status_line("DIST on houses=0 ", 0),
                  "DIST ON: the call's four displacement bytes changed and nothing else; status on");
            mk(region); cmd("STATUS");
            check(g_dist_calls == 2 && *(int32_t *)(region + 0x1130) == 3 && a->num == 1 && a->data[0].type == 216 && status_line("DIST on houses=0 sets=0 writes=0 putbacks=0 calls=1 ", 0),
                  "on, nobody named: the distribution runs as before, through the stub");
            cmd("DIST SET 0x%llX 13:1,30:1,340:1", (unsigned long long)(uintptr_t)house);
            check(a->num == 3 && a->max >= 3 && a->data[0].type == 13 && a->data[1].type == 30 && a->data[2].type == 340 && a->data[2].amt == 1 && g_dgrow_calls == 1 &&
                  house[0x459] == 1 && g_rf_calls == 1 && g_rf_region == region && g_rf_b == house && g_rf_mode == 1 && g_dsurp_calls == 1 && g_dsurp_b == house &&
                  status_line("DIST on houses=1 sets=1 writes=1 putbacks=0 ", 0),
                  "DIST SET writes at once: three records (the game's grow helper once), +459h set, the region's refresh (mode 1) and the surplus cache");
            mk(region); cmd("STATUS");
            check(g_dist_calls == 3 && a->num == 3 && a->data[0].type == 13 && a->data[1].type == 30 && a->data[2].type == 340 && g_rf_calls == 2 && g_dsurp_calls == 2 &&
                  status_line("DIST on houses=1 sets=1 writes=2 putbacks=1 calls=2 ", 0), "the distribution's own list (216) is replaced by the host's in the same call");
            house[0x459] = 0; *(uint8_t **)(house + 0x2C8) = region2; mk(region); cmd("STATUS");
            check(g_dist_calls == 4 && a->num == 1 && a->data[0].type == 216 && g_rf_calls == 2 && status_line("DIST on houses=1 sets=1 writes=2 putbacks=1 calls=3 ", 0),
                  "another region's distribution leaves a house of a region it did not run for alone");
            *(uint8_t **)(house + 0x2C8) = region; mk(region); cmd("STATUS");
            check(a->num == 3 && a->data[2].type == 340 && status_line("DIST on houses=1 sets=1 writes=3 putbacks=2 ", 0), "its own region's run puts it back");
            mk(region); cmd("STATUS");
            g_dist_house = NULL; mk(region); g_dist_house = house; cmd("STATUS");
            check(a->num == 3 && status_line("DIST on houses=1 sets=1 writes=4 putbacks=3 calls=6 ", 0) && g_rf_calls == 4, "a list already equal to the host's is not written again");
            cmd("DIST SET 0x%llX -", (unsigned long long)(uintptr_t)house);
            check(a->num == 0 && status_line("DIST on houses=1 sets=2 writes=5 ", 0), "an empty list from the host empties the house's list");
            *(uint8_t **)(house + 0x2C8) = NULL; cmd("DIST SET 0x%llX 13:2", (unsigned long long)(uintptr_t)house);
            check(a->num == 0 && status_line("DIST on houses=1 sets=3 writes=5 ", 0), "a house without a region (taken out of the game) is not written");
            *(uint8_t **)(house + 0x2C8) = region; *(uint32_t *)(house + 0x0C) = 78; mk(region); cmd("STATUS");
            check(a->num == 1 && a->data[0].type == 216 && status_line("DIST on houses=0 ", 0), "another object at that address: the entry is dropped, nothing written");
            *(uint32_t *)(house + 0x0C) = 77;
            cmd("DIST SET 0 -"); cmd("DIST SET 0x%llX 13x", (unsigned long long)(uintptr_t)house); cmd("DIST SET 0x%llX 13:1,", (unsigned long long)(uintptr_t)(house + 1)); cmd("DIST MAYBE"); cmd("DIST SET");
            check(status_line("DIST on houses=0 sets=3 writes=5 ", 0) && status_has("refused=5 "), "5 bad forms refused (address 0, not a list, unaligned, no verb, no arguments)");
            cmd("DIST SET 0x%llX 30:1", (unsigned long long)(uintptr_t)house); cmd("DIST FORGET"); mk(region); cmd("STATUS");
            check(a->num == 1 && a->data[0].type == 216 && status_line("DIST on houses=0 ", 0), "DIST FORGET drops every house");
            cmd("DIST OFF");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("DIST off ", 0), "DIST OFF: .text byte-identical to the original");
            mk(region); cmd("STATUS");
            check(g_dist_calls == 10, "off: the market routine calls the distribution directly again");
            cmd("DIST ON"); cmd("ALLOFF");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("DIST off ", 0), "ALLOFF puts the call back");
            check(status_line("GOODS off", 0) && status_line("JG off", 1), "the other items are unaffected");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.goods = 1; o.dist = 2;
            m = build_image(&o);
            start("D2: the market routine's call reaches another routine", m, NULL, NULL, NULL);
            check(status_line("DIST unavailable DISTCALL's call does not reach the distribution (redirected before?)", 1), "DIST unavailable, with the reason");
            cmd("DIST ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "DIST ON wrote nothing");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.goods = 1; o.dist = 3;
            m = build_image(&o);
            start("D3: the grow helper starts otherwise (another build)", m, NULL, NULL, NULL);
            check(status_line("DIST unavailable the grow helper does not start with its known instructions", 1), "DIST unavailable, with the reason");
            cmd("DIST ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "DIST ON wrote nothing");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.dist = 1;
            m = build_image(&o);
            start("D4: no refresh routine (GOODS's REFRESH missing)", m, NULL, NULL, NULL);
            check(status_line("DIST unavailable REFRESH signature has 0 hits (need exactly 1)", 1), "DIST unavailable: it needs the region's refresh");
        }
        {
            opts_t o = { 1 };
            img_t *m = build_image(&o);
            start("D5: no DIST routines (another game build)", m, NULL, NULL, NULL);
            check(status_line("DIST unavailable DISTCALL signature has 0 hits (need exactly 1)", 1), "DIST unavailable with no hit");
            check(status_line("ROUT available", 1), "the rest still works");
        }
    }

    /* ======================================================== R: REGSET and PICK GONE (lane 35, round six) */
    {
        static __declspec(align(16)) uint8_t region[0x700], ea[16 * 8], eb[16 * 8], ua[0x1000], r27[0xD8];
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1 };
            img_t *m = build_image(&o);
            settask_fn st = (settask_fn)(void *)(m->text + m->pk_settask);
            think_fn th = (think_fn)(void *)(m->text + m->pk_think);
            uint64_t ka[3] = { 0x7FF00011000ull, 0x7FF00012000ull, 0x7FF00013000ull }, kb[1] = { 0x7FF00012000ull }, rbld = 0x7FF00012000ull;
            const char *rf;
            wchar_t rp[MAX_PATH];
            memset(region, 0, sizeof(region)); *(uint64_t *)region = (uint64_t)(uintptr_t)(m->text + 0x40);   /* a vtable in the module */
            g_rs_region = region;
            rs_make_set(region + 0x5A8, ea, ka, 3); rs_make_set(region + 0x5F8, eb, kb, 1);
            memcpy(g_rs_members[0], ka, sizeof(ka)); g_rs_count[0] = 3; memcpy(g_rs_members[1], kb, sizeof(kb)); g_rs_count[1] = 1; g_rs_n = 0;
            start("R1: REGSET, a region's two building sets (known build); PICK GONE", m, NULL, NULL, NULL);
            check(status_line("REGSET available lists=0 members=0 drops=0 dropped=0 bad=0 faults=0", 1), "REGSET found (both calls reach the set removal with its known first bytes)");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "the scan wrote nothing");
            cmd("REGSET LIST %llX", (unsigned long long)(uintptr_t)region);
            cmd("STATUS"); _snwprintf(rp, MAX_PATH, L"%sregset.txt", g_io); rf = read_file(rp); if (!strstr(rf, "END")) printf("regset.txt: [%s] status: %s\n", rf, read_file(g_status));
            check(strstr(rf, "+5A8 7FF00011000") && strstr(rf, "+5A8 7FF00012000") && strstr(rf, "+5A8 7FF00013000") && strstr(rf, "+5F8 7FF00012000") && strstr(rf, "END") && status_has("members=4 "),
                  "LIST writes the four members of both sets, walked by the hash chain (no member read: they are no objects)");
            cmd("REGSET DROP %llX %llX", (unsigned long long)(uintptr_t)region, (unsigned long long)rbld); cmd("STATUS");
            check(g_rs_n == 2 && g_rs_set[0] == region + 0x5A8 && g_rs_set[1] == region + 0x5F8 && g_rs_key[0] == rbld && g_rs_key[1] == rbld && g_rs_count[0] == 2 && g_rs_count[1] == 0 && status_has("dropped=2 "),
                  "DROP calls the game's set removal for +5A8h and +5F8h with the address; both members gone");
            cmd("REGSET DROP %llX 7FF00099000", (unsigned long long)(uintptr_t)region); cmd("STATUS");
            check(status_has("drops=2 dropped=2 "), "an address in neither set: two removals, nothing taken out");
            cmd("REGSET LIST 0"); cmd("REGSET LIST 1001"); cmd("REGSET DROP %llX xyz", (unsigned long long)(uintptr_t)region); cmd("REGSET LIST %llX", (unsigned long long)(uintptr_t)ua); cmd("REGSET MAYBE"); cmd("STATUS");
            check(status_has("bad=5 "), "5 bad forms refused (null, unaligned, not hex, an object with no vtable in the module, no verb)");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "REGSET never writes to .text");
            /* PICK GONE */
            memset(ua, 0, sizeof(ua)); memset(r27, 0, 0xD8); r27[0] = 27; memcpy(r27 + 0x98, &rbld, 8);
            cmd("PICK ON"); cmd("PICK SET %llX:1B:0", (unsigned long long)(uintptr_t)ua);
            st(ua, r27); cmd("STATUS");
            check(status_line("PICK on n=1 ", 0) && status_has("kept=1 "), "PICK keeps the board's 27 at building B");
            cmd("PICK GONE %llX", (unsigned long long)rbld); cmd("STATUS");
            check(status_line("PICK on n=0 ", 0) && status_has("gone=1 dropped=1 "), "PICK GONE B: the entry whose kept record names B is taken off the list");
            cmd("PICK SET %llX:1B:0", (unsigned long long)(uintptr_t)ua);
            st(ua, r27); cmd("STATUS"); if (!status_has("stale=1 ")) printf("%s\n", read_file(g_status));
            check(status_has("stale=1 ") && status_has("kept=1 "), "a record naming B is never kept again");
            { static uint8_t r22[0xD8]; memset(r22, 0, 0xD8); r22[0] = 22; g_pick_rec = r22; th(ua); cmd("STATUS");
              check(ua[8] == 22 && status_has("subst=0 "), "so the chooser's other pick is not followed by a task at B"); }
            cmd("PICK GONE xyz"); cmd("STATUS");
            check(status_has("bad=1 "), "a bad GONE list refused");
            cmd("ALLOFF");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "ALLOFF: .text byte-identical");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
            img_t *m = build_image(&o);
            start("R2: REGSET on another game build", m, NULL, NULL, NULL);
            check(status_line("REGSET unavailable another game build", 0), "REGSET unavailable: another build");
            cmd("REGSET LIST 1000"); cmd("STATUS"); check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("REGSET unavailable", 0), "a command is refused, nothing written");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2 };
            img_t *m = build_image(&o);
            start("R3: the two set calls reach different routines", m, NULL, NULL, NULL);
            check(status_line("REGSET unavailable the two set calls do not reach the same routine in the module", 1), "REGSET unavailable, with the reason");
        }
        {
            opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
            img_t *m = build_image(&o);
            start("R4: no REGSETS site", m, NULL, NULL, NULL);
            check(status_line("REGSET unavailable REGSETS signature has 0 hits (need exactly 1)", 1), "REGSET unavailable with no hit");
        }
    }

    /* ======================================================== V: MEN (lane 43): a squad's man walks to the host's man's place */
    {
        static __declspec(align(16)) uint8_t ma[0x1000], mb[0x1000], mc[0x1000], rec[0x88], lst[16];
        {
            opts_t o = { 1 };
            img_t *m;
            mpath_call mp;
            wchar_t outp[MAX_PATH];
            const char *out;
            char line[256];
            uintptr_t A = (uintptr_t)ma, B = (uintptr_t)mb, Cm = (uintptr_t)mc;
            o.known = 1; o.men = 1;
            m = build_image(&o);
            mp = (mpath_call)(void *)(m->text + m->mv_entry);
            memset(ma, 0, sizeof(ma)); memset(mb, 0, sizeof(mb)); memset(mc, 0, sizeof(mc));
            *(uint8_t **)ma = m->base + 0x100; *(uint8_t **)mb = m->base + 0x100; *(uint8_t **)mc = m->base + 0x100;   /* "vtables" in the module */
            *(uint64_t *)(mb + 0xCE0) = 1;                                 /* B: a man tickSquad gives no slot */
#define MV_CALL(man, x, y, z) do { memset(rec, 0, sizeof(rec)); memset(lst, 0, sizeof(lst)); ((double *)(rec + 8))[0] = (x); ((double *)(rec + 8))[1] = (y); ((double *)(rec + 8))[2] = (z); mp((void *)(man), rec, 1, lst); } while (0)
            start("V1: MEN, a held man walks to the host's place (known build)", m, NULL, NULL, NULL);
            _snwprintf(outp, MAX_PATH, L"%smen_out.txt", g_io);
            check(status_line("MEN idle", 1), "MEN found (MPATH, MSLOT; the call reaches the request), idle");
            g_mp_calls = 0; MV_CALL(A, 1, 2, 3);
            check(g_mp_calls == 1 && g_mp_pt[0] == 1 && g_mp_pt[2] == 3, "the synthetic request runs unhooked");
            cmd("MEN HOOK ON"); cmd("STATUS");
            check(status_line("MEN hooked", 1) && m->text[m->mv_entry] == 0xE9 && bytes_are(m->text + m->mv_entry + 5, "90 90 90") &&
                  memcmp(m->text + m->mv_entry + 8, m->snapshot + m->mv_entry + 8, TEXT_SIZE - m->mv_entry - 8) == 0 && memcmp(m->text, m->snapshot, m->mv_entry) == 0,
                  "MEN HOOK ON: only the entry's first 8 bytes changed (a jump and three nops)");
            MV_CALL(A, 1, 2, 3); cmd("STATUS");
            check(g_mp_calls == 2 && g_mp_man == ma && g_mp_pt[0] == 1 && g_mp_pt[1] == 2 && g_mp_pt[2] == 3 && g_mp_flag == 1 && status_has("calls=1 subst=0 "),
                  "a man not in the table passes untouched (the four arguments reach the routine)");
            cmd("MEN SET %IX=100.5,200,-300", A); cmd("STATUS");
            check(g_mp_calls == 3 && g_mp_man == ma && g_mp_pt[0] == 100.5 && g_mp_pt[1] == 200 && g_mp_pt[2] == -300 && g_mp_flag == 0 &&
                  g_mp_rest[0] == 0xA0 && g_mp_rest[15] == 0xAF && g_mp_rest[0x10] == 0xB0 && *(uint32_t *)(g_mp_rest + 0x18) == 0x4CBEBC20u && *(uint32_t *)(g_mp_rest + 0x1C) == 0xFFFFFFFFu &&
                  status_has("held=1 ") && status_has(" gos=1 gofail=0 ce0=0 sets=1 setmen=1 "),
                  "MEN SET: the man is given the host's place at once with the routine, the record built as tickSquad builds it");
            MV_CALL(A, 1, 2, 3); cmd("STATUS");
            check(g_mp_calls == 4 && g_mp_pt[0] == 100.5 && g_mp_pt[1] == 200 && g_mp_pt[2] == -300 && status_has(" subst=1 "),
                  "this copy's own request for a held man gets the host's place");
            cmd("MEN SET %IX=110,200,-300", A); cmd("STATUS");
            check(g_mp_calls == 4 && status_has(" gos=1 "), "a host place under 50 cm from the last one given is not given again at once");
            MV_CALL(A, 1, 2, 3);
            check(g_mp_pt[0] == 110, "but the next request of this copy gets it");
            cmd("MEN SET %IX=5,5,5", B); cmd("STATUS");
            check(g_mp_calls == 6 && g_mp_man == mb && g_mp_pt[0] == 5 && status_has(" gos=2 gofail=0 ce0=1 ") && status_has("held=2 "),
                  "a man tickSquad gives no slot (+CE0h; the fight's calls do not test it) is given the place too, and counted");
            MV_CALL(B, 1, 2, 3);
            check(g_mp_calls == 7 && g_mp_man == mb && g_mp_pt[0] == 5, "and his own request gets the host's place");
            cmd("MEN SET zz=1,2,3;%IX=1,2;%IX=1,2,3,4;%IX=1,2,3x;0=1,2,3", A, A, A); cmd("STATUS");
            check(status_has(" refused=5 ") && g_mp_calls == 7, "five bad forms refused, nothing called");
            *(uint8_t **)mc = (uint8_t *)(uintptr_t)0x1234;               /* no vtable in the module */
            cmd("MEN SET %IX=7,7,7", Cm); cmd("STATUS");
            check(g_mp_calls == 7 && status_has(" gofail=1 "), "a man that does not look like an object of the game is not given anything");
            *(uint8_t **)mc = m->base + 0x100;
            cmd("MEN DROP %IX,%IX", A, Cm); cmd("STATUS");
            MV_CALL(A, 1, 2, 3);
            check(g_mp_pt[0] == 1 && status_has("held=1 ") && status_has(" drops=2 "), "MEN DROP: the man's own request passes again");
            /* host: watched men */
            cmd("MEN WATCH %IX", Cm); MV_CALL(Cm, 500, 600, 700); cmd("MEN POLL"); out = read_file(outp);
            _snprintf(line, sizeof(line), "%IX 500 600 700\r\n", Cm);
            check(g_mp_pt[0] == 500 && strcmp(out, line) == 0, "a watched man's request passes unchanged; POLL writes its place");
            cmd("MEN POLL"); out = read_file(outp);
            check(out[0] == 0, "nothing new: POLL writes nothing");
            MV_CALL(Cm, 500, 600, 710); cmd("MEN POLL"); out = read_file(outp);
            check(out[0] == 0, "a place moved under 50 cm is not written");
            MV_CALL(Cm, 500, 600, 820); cmd("MEN POLL"); out = read_file(outp);
            _snprintf(line, sizeof(line), "%IX 500 600 820\r\n", Cm);
            check(strcmp(out, line) == 0, "a place moved 1.2 m is written");
            {   /* lane 48: HERE, the watched men's own places (SMUnit.realPos, 3 doubles) read here, not through the mod loader */
                double *rp = (double *)(mc + 0x4E8);
                rp[0] = 1000; rp[1] = 2000; rp[2] = 300;
                cmd("MEN POLL"); out = read_file(outp);
                check(out[0] == 0, "without HEREAT a POLL writes no own places");
                cmd("MEN HEREAT E50"); cmd("MEN HEREAT 4E9"); cmd("MEN HEREAT zz"); cmd("STATUS");
                check(status_has(" refused=8 ") && status_has(" hoff=0 "), "HEREAT past the man's bytes, not 8-aligned or no number: refused");
                cmd("MEN HEREAT 4E8"); cmd("MEN POLL"); out = read_file(outp);
                _snprintf(line, sizeof(line), "H %IX 1000 2000 300\r\n", Cm);
                check(strcmp(out, line) == 0, "MEN HEREAT: the POLL writes a watched man's own place (a man not watched: nothing)");
                rp[0] = 1090; cmd("MEN POLL"); out = read_file(outp);
                check(out[0] == 0, "moved under 1 m: not written");
                rp[1] = 2150; cmd("MEN POLL"); out = read_file(outp);
                _snprintf(line, sizeof(line), "H %IX 1090 2150 300\r\n", Cm);
                check(strcmp(out, line) == 0, "moved 1.5 m: written");
                {   /* (lane 52, round 3) with a way: the point he walks to now follows on the line */
                    static uint8_t way[2 * 0x88]; double keep1 = rp[1];
                    memset(way, 0, sizeof(way)); ((double *)(way + 0x88 + 8))[0] = 7000; ((double *)(way + 0x88 + 8))[1] = -8000;
                    *(uint8_t **)(mc + 0x7D0) = way; *(int32_t *)(mc + 0x7D8) = 2; *(int32_t *)(mc + 0x7E0) = 1;
                    rp[1] = keep1 + 200; cmd("MEN POLL"); out = read_file(outp);
                    _snprintf(line, sizeof(line), "H %IX %.0f %.0f %.0f 7000 -8000\r\n", Cm, rp[0], rp[1], rp[2]);
                    check(strcmp(out, line) == 0, "HERE with a way: the point he walks to now is on the line");
                    *(int32_t *)(mc + 0x7E0) = 2; rp[1] = keep1 + 400; cmd("MEN POLL"); out = read_file(outp);
                    _snprintf(line, sizeof(line), "H %IX %.0f %.0f %.0f\r\n", Cm, rp[0], rp[1], rp[2]);
                    check(strcmp(out, line) == 0, "a way that is used up: the place alone");
                    *(uint8_t **)(mc + 0x7D0) = NULL; *(int32_t *)(mc + 0x7D8) = 0; *(int32_t *)(mc + 0x7E0) = 0; rp[1] = keep1; cmd("MEN POLL");
                }
                { uint64_t qn = 0x7FF8000000000000ull; memcpy(&rp[0], &qn, 8); }   /* a quiet NaN */
                rp[1] = 5000; cmd("MEN POLL"); out = read_file(outp); cmd("STATUS");
                check(out[0] == 0 && status_has(" herebad=1 "), "a place that is no number is not written");
                rp[0] = 1090;
                *(uint8_t **)mc = (uint8_t *)(uintptr_t)0x1234;
                cmd("MEN POLL"); out = read_file(outp); cmd("STATUS");
                check(out[0] == 0 && status_has(" herebad=2 "), "a man whose first qword is no vtable of the game module is not read");
                *(uint8_t **)mc = m->base + 0x100;
                cmd("MEN POLL"); out = read_file(outp);
                _snprintf(line, sizeof(line), "H %IX 1090 5000 300\r\n", Cm);
                check(strcmp(out, line) == 0, "and read again once he looks like one");
                cmd("MEN HEREAT 0"); rp[1] = 9000; cmd("MEN POLL"); out = read_file(outp); cmd("STATUS");
                check(out[0] == 0 && status_has(" hoff=0 "), "HEREAT 0: no own places any more");
            }
            {   /* lane 48: REGO, a held man standing 2 m or more from his place, idle 1.5 s, is given it again */
                double *bp = (double *)(mb + 0x4E8);
                LONG c0;
                bp[0] = 1000; bp[1] = 1000; bp[2] = 0;
                cmd("MEN HEREAT 4E8"); Sleep(1700); c0 = g_mp_calls; g_tick(NULL); cmd("STATUS");
                check(g_mp_calls == c0 + 1 && g_mp_man == mb && g_mp_pt[0] == 5 && status_has(" regos=1 "), "REGO: a held man 14 m from his place, idle, gets a GO to it");
                c0 = g_mp_calls; g_tick(NULL); cmd("STATUS");
                check(g_mp_calls == c0 && status_has(" regos=1 "), "and not again at once");
                bp[0] = 5; bp[1] = 6; Sleep(1700); c0 = g_mp_calls; g_tick(NULL); cmd("STATUS");
                check(g_mp_calls == c0 && status_has(" regos=1 "), "a held man within 2 m of his place: no GO");
                bp[0] = 1000; cmd("MEN REGO OFF"); Sleep(1700); c0 = g_mp_calls; g_tick(NULL); cmd("STATUS");
                check(g_mp_calls == c0 && status_has(" rego=0"), "MEN REGO OFF: none");
                cmd("MEN REGO ON"); cmd("MEN HEREAT 0");
            }
            {   /* lane 52: LET (let go, still watched) and the run-off check with its dump */
                double *bp = (double *)(mb + 0x4E8);
                wchar_t dp[MAX_PATH];
                const char *dt;
                LONG c0;
                _snwprintf(dp, MAX_PATH, L"%smen_diag.txt", g_io); DeleteFileW(dp);
                cmd("MEN REGO OFF");
                bp[0] = 5; bp[1] = 5; bp[2] = 5;                           /* B stands on his place (5,5,5) */
                cmd("MEN HEREAT 4E8"); cmd("MEN DROP %IX", B); cmd("MEN SET %IX=5,5,5", B); Sleep(300); g_tick(NULL); cmd("STATUS");
                check(status_has(" runoffs=0 "), "RUNOFF: a held man on his place is not counted");
                bp[0] = 5000; Sleep(300); g_tick(NULL); Sleep(300); g_tick(NULL); cmd("STATUS");
                check(status_has(" runoffs=0 "), "RUNOFF: 50 m off for under 2 s: not yet");
                Sleep(2100); g_tick(NULL); cmd("STATUS");
                _snprintf(line, sizeof(line), " runoffs=1 rlast=%IX ", B);
                check(status_has(line) && status_has(" diags=1"), "RUNOFF: 50 m off his place for 2 s: counted once, written out");
                dt = read_file(dp);
                check(strstr(dt, "== RUNOFF 1") && strstr(dt, "OFF  man=") && strstr(dt, " d=4995 ") && strstr(dt, "req -") && strstr(dt, " GO by FFFFFFFF at 5,5,5"),
                      "RUNOFF: the dump has the man, his distance and his path requests from the ring");
                Sleep(300); g_tick(NULL); cmd("STATUS");
                check(status_has(" runoffs=1 "), "RUNOFF: not again while he stays off");
                bp[0] = 5; Sleep(300); g_tick(NULL); bp[0] = 5000; Sleep(300); g_tick(NULL); Sleep(2100); g_tick(NULL); cmd("STATUS");
                check(status_has(" runoffs=2 "), "RUNOFF: back on his place, then off again for 2 s: counted again");
                cmd("MEN LET %IX", B); cmd("STATUS");
                c0 = g_mp_calls; MV_CALL(B, 1, 2, 3); cmd("STATUS");
                check(g_mp_calls == c0 + 1 && g_mp_pt[0] == 1 && status_has(" lets=1 ") && status_has("held=0 "), "MEN LET: his own request passes again (no longer held)");
                cmd("MEN SET %IX=5,5,5", B); cmd("STATUS");
                check(g_mp_pt[0] == 5 && g_mp_man == mb && status_has("held=1 "), "MEN SET after LET: held again with a GO at once");
                cmd("MEN LET %IX", B); Sleep(3200); g_tick(NULL); cmd("STATUS");
                c0 = g_mp_calls; MV_CALL(B, 1, 2, 3); cmd("MEN LET %IX", B); cmd("STATUS");
                check(g_mp_pt[0] == 1 && status_has(" lets=2 "), "a man let go with no SET for 3 s leaves the table (a LET then finds nobody)");
                cmd("MEN SET %IX=5,5,5", B); bp[0] = 5;
                /* lane 52, round 2: a man whose +E3Ch is set gets no GO (the routine would leave at once); it is given
                 * the moment the byte clears */
                mb[0xE3C] = 1; c0 = g_mp_calls; cmd("MEN SET %IX=900,900,0", B); cmd("STATUS");
                check(g_mp_calls == c0 && status_has(" e3cwait=1 "), "E3C: a GO for a man whose +E3Ch is set is held back, counted");
                g_tick(NULL); cmd("STATUS");
                check(g_mp_calls == c0 && status_has(" e3cgos=0"), "E3C: not given while the byte stays set");
                mb[0xE3C] = 0; g_tick(NULL); cmd("STATUS");
                check(g_mp_calls == c0 + 1 && g_mp_man == mb && g_mp_pt[0] == 900 && status_has(" e3cgos=1"), "E3C: given at once when it clears");
                *(float *)(mb + 0x594) = 15.0f; cmd("MEN SET %IX=5,5,5", B); *(float *)(mb + 0x594) = 0.0f;   /* (given at once: he "walks") */
                /* lane 52, round 2: KEEP. B walks by a request for the place he was given (+510h), his way has points
                 * left: his own request is not run again. Not so when his way is used up, when he walks by another
                 * request, when the request has a list to free, or with MEN KEEP OFF. */
                {
                    double *ds = (double *)(mb + 0x510); int32_t *pn = (int32_t *)(mb + 0x7D8), *pp = (int32_t *)(mb + 0x7E0);
                    static uint8_t junk[16];
                    ds[0] = 5; ds[1] = 5; ds[2] = 5; *pn = 3; *pp = 1; *(float *)(mb + 0x594) = 15.0f;
                    c0 = g_mp_calls; MV_CALL(B, 1, 2, 3); cmd("STATUS");
                    check(g_mp_calls == c0 && status_has(" keep=1 keeps=1"), "KEEP: a held man's own request is not run while his way leads to the host's place");
                    {   /* a kept request counts as his asking: REGO leaves him alone (2 m off, 1.7 s after his GO, asked 0.3 s ago) */
                        LONG r0; cmd("MEN REGO ON"); bp[0] = 1000; Sleep(1400); MV_CALL(B, 1, 2, 3); Sleep(300); c0 = g_mp_calls; cmd("STATUS"); r0 = status_val(" regos="); g_tick(NULL); cmd("STATUS");
                        check(g_mp_calls == c0 && status_val(" regos=") == r0, "KEEP: a man whose request was kept is not idle for REGO");
                        cmd("MEN REGO OFF"); bp[0] = 5; c0 = g_mp_calls;
                    }
                    *pp = 4; c0 = g_mp_calls; MV_CALL(B, 1, 2, 3);
                    check(g_mp_calls == c0 + 1 && g_mp_pt[0] == 5, "KEEP: run (with the host's place) when his way is used up");
                    *pp = 1; *pn = 0; c0 = g_mp_calls; MV_CALL(B, 1, 2, 3);
                    check(g_mp_calls == c0 + 1, "KEEP: run when he has no way");
                    *pn = 3; ds[0] = 7; c0 = g_mp_calls; MV_CALL(B, 1, 2, 3);
                    check(g_mp_calls == c0 + 1 && g_mp_pt[0] == 5, "KEEP: run when the request he walks by is for another place");
                    ds[0] = 5; memset(rec, 0, sizeof(rec)); memset(lst, 0, sizeof(lst)); *(uint8_t **)(rec + 0x30) = junk; ((double *)(rec + 8))[0] = 1;
                    c0 = g_mp_calls; mp((void *)B, rec, 1, lst);
                    check(g_mp_calls == c0 + 1, "KEEP: run when the request carries a list (the routine frees it)");
                    cmd("MEN KEEP OFF"); c0 = g_mp_calls; MV_CALL(B, 1, 2, 3); cmd("STATUS");
                    check(g_mp_calls == c0 + 1 && status_has(" keep=0 keeps=2"), "MEN KEEP OFF: every request runs");
                    cmd("MEN KEEP ON"); c0 = g_mp_calls; MV_CALL(B, 1, 2, 3); cmd("STATUS");
                    check(g_mp_calls == c0 && status_has(" keep=1 keeps=3"), "MEN KEEP ON: again");
                    *(float *)(mb + 0x594) = 0.0f; Sleep(800); c0 = g_mp_calls; MV_CALL(B, 1, 2, 3);
                    check(g_mp_calls == c0 + 1 && g_mp_pt[0] == 5, "KEEP: a man who stands with a way (0.8 s after his last request ran): the request runs");
                    c0 = g_mp_calls; MV_CALL(B, 1, 2, 3); cmd("STATUS");
                    check(g_mp_calls == c0 && status_has(" keeps=4"), "KEEP: and is kept again while the path finder answers");
                    *(float *)(mb + 0x594) = 15.0f; c0 = g_mp_calls;
                    cmd("MEN SET %IX=105,5,5", B);
                    {   /* (lane 52, round 3) a man who stands and was given a way under a second ago gets no new one yet */
                        LONG c1 = g_mp_calls; *(float *)(mb + 0x594) = 0.0f;
                        cmd("MEN SET %IX=205,5,5", B);
                        check(g_mp_calls == c1 + 1, "a standing man of the player's own squads is given every place at once");
                        c1 = g_mp_calls; cmd("MEN SET %IX=305,5,5,2", B); cmd("STATUS");
                        check(g_mp_calls == c1 && status_has(" stood=1"), "a standing man of a muster given a way 0 s ago: the new place waits (stood=1)");
                        Sleep(1100); cmd("MEN SET %IX=406,5,5,2", B);
                        check(g_mp_calls == c1 + 1 && g_mp_pt[0] == 406, "a second later the next SET gives it");
                        *(float *)(mb + 0x594) = 15.0f; cmd("MEN SET %IX=105,5,5", B); c0 = g_mp_calls - 1;
                    }
                    check(g_mp_calls == c0 + 1 && g_mp_pt[0] == 105, "KEEP never stops a GO (a new host place is given at once)");
                    ds[0] = 0; ds[1] = 0; ds[2] = 0; *pn = 0; *pp = 0; *(float *)(mb + 0x594) = 0.0f; cmd("MEN SET %IX=5,5,5", B);
                }
                /* lane 52, round 2: a man who sits (+E3Ch) off his place is not a run-off (seated=); the 6 m check */
                {
                    long r6;
                    cmd("STATUS"); r6 = status_val(" ro6=");
                    bp[0] = 5000; mb[0xE3C] = 1; Sleep(300); g_tick(NULL); Sleep(300); g_tick(NULL); Sleep(2100); g_tick(NULL); cmd("STATUS");
                    check(status_has(" runoffs=2 ") && status_val(" ro6=") == r6 && status_has(" seated=1 "), "a man who sits 50 m from his place is not counted as held off it (seated=1)");
                    mb[0xE3C] = 0; g_tick(NULL); Sleep(260); mb[0xE3C] = 1; g_tick(NULL); Sleep(260); mb[0xE3C] = 0; g_tick(NULL); cmd("STATUS");
                    check(status_has(" runoffs=2 "), "up for a moment: his clock runs only while he is up (not counted yet)");
                    Sleep(2300); g_tick(NULL); cmd("STATUS");
                    check(status_has(" runoffs=3 "), "up for 2 s and still 50 m off: counted");
                    mb[0xE3C] = 0; bp[0] = 5; Sleep(300); g_tick(NULL); cmd("STATUS"); r6 = status_val(" ro6=") - 1;
                    bp[0] = 705; Sleep(300); g_tick(NULL); Sleep(300); g_tick(NULL); Sleep(300); g_tick(NULL); Sleep(2100); g_tick(NULL); cmd("STATUS");
                    check(status_has(" runoffs=3 ") && status_val(" ro6=") == r6 + 2, "7 m off for 2 s, standing: the 6 m check counts him (ro6), the 15 m one does not");
                    bp[0] = 5; Sleep(300); g_tick(NULL);
                    bp[0] = 1205; Sleep(300); g_tick(NULL); Sleep(300); g_tick(NULL); Sleep(300); g_tick(NULL); bp[0] = 1005; Sleep(2100); g_tick(NULL); cmd("STATUS");
                    check(status_val(" ro6=") == r6 + 2, "12 m off and 2 m closer after 2 s: closing, not counted");
                    /* a man on the move: 7 m from his place while he walks 12 m a second (0.8 s of it is 9.6 m): beside it */
                    bp[0] = 5; bp[1] = 5; Sleep(300); g_tick(NULL);
                    { int k; for (k = 0; k < 10; k++) { bp[0] = 705; bp[1] = 5 + 300.0 * (k + 1); cmd("MEN SET %IX=5,%d,5", B, 5 + 300 * (k + 1)); Sleep(250); g_tick(NULL); } }
                    cmd("STATUS");
                    check(status_val(" ro6=") == r6 + 2, "7 m from a place that moves with him at 12 m a second for 2.5 s: not counted");
                    bp[1] = 5; cmd("MEN SET %IX=5,5,5", B);
                    bp[0] = 5; Sleep(300); g_tick(NULL);
                }
                cmd("MEN REGO ON"); cmd("MEN HEREAT 0");
            }
            cmd("MEN UNWATCH %IX", Cm); MV_CALL(Cm, 1, 1, 1); cmd("MEN POLL"); out = read_file(outp); cmd("STATUS");
            check(out[0] == 0 && status_has("watched=0 "), "MEN UNWATCH: not noted any more");
            cmd("MEN FORGET"); cmd("STATUS");
            check(status_has("held=0 watched=0 ") && status_has(" forgets=1 "), "MEN FORGET empties the table");
            cmd("MEN HOOK OFF"); cmd("STATUS");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("MEN idle", 1) && status_has(" pace=na "), "MEN HOOK OFF: .text byte-identical (an image without the pace rule: pace=na)");
            cmd("MEN HOOK ON"); cmd("MEN SET %IX=9,9,9", A); cmd("ALLOFF"); cmd("STATUS");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("MEN idle", 1) && status_has("held=0 "), "ALLOFF: the hook out, the table emptied");
            /* a fault inside the hook */
            cmd("MEN HOOK ON"); cmd("MEN SET %IX=9,9,9", A);
            mp(ma, (uint8_t *)(uintptr_t)0x10, 0, lst);                     /* a record the hook cannot write */
            g_tick(NULL); cmd("STATUS");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("MEN unavailable exception C0000005 in the hook", 1) && status_has("held=0 ") && status_line("ROUT available", 1),
                  "an exception in the hook is caught, the hook goes out at the next tick, the table is emptied, the rest works");
            cmd("MEN HOOK ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "and the item stays off");
#undef MV_CALL
        }
        {   /* lane 52, round 2: PACE, the squad's pace rule: a held man's speed factor is at least 1 after it ran */
            opts_t o = { 1 };
            img_t *m;
            static uint8_t sq[0x410]; static uint8_t *arr[3];
            void (*pace)(void *, uint32_t);
            uintptr_t B = (uintptr_t)mb;
            float *fa = (float *)(ma + 0x5A8), *fb = (float *)(mb + 0x5A8), *fc = (float *)(mc + 0x5A8);
            o.known = 1; o.men = 1; o.pace = 1;
            m = build_image(&o);
            pace = (void (*)(void *, uint32_t))(void *)(m->text + m->pc_entry);
            memset(ma, 0, sizeof(ma)); memset(mb, 0, sizeof(mb)); memset(mc, 0, sizeof(mc)); memset(sq, 0, sizeof(sq));
            *(uint8_t **)ma = m->base + 0x100; *(uint8_t **)mb = m->base + 0x100; *(uint8_t **)mc = m->base + 0x100;
            arr[0] = ma; arr[1] = mb; arr[2] = mc; *(uint8_t ***)(sq + 0x18) = arr; *(int32_t *)(sq + 0x20) = 3;
            start("V1b: MEN PACE, a held man is not slowed by the squad's pace rule (known build)", m, NULL, NULL, NULL);
            check(status_line("MEN idle", 1) && status_has(" pace=out "), "MEN idle, the pace rule found (not hooked)");
            g_pc_squad = sq; g_pc_calls = 0; g_pc_give = 0.5f; pace((void *)0x1234, 77);
            check(g_pc_calls == 1 && g_pc_id == 77 && *fa == 0.5f && *fb == 0.5f, "the synthetic pace rule runs unhooked (every man 0.5)");
            cmd("MEN HOOK ON"); cmd("STATUS");
            check(status_line("MEN hooked", 1) && status_has(" pace=in ") && m->text[m->pc_entry] == 0xE9 && bytes_are(m->text + m->pc_entry + 5, "48 81 EC") &&
                  memcmp(m->text + m->pc_entry + 8, m->snapshot + m->pc_entry + 8, m->mv_entry > m->pc_entry ? m->mv_entry - m->pc_entry - 8 : TEXT_SIZE - m->pc_entry - 8) == 0,
                  "MEN HOOK ON: the pace rule's entry is a jump, its next bytes as they were");
            *fa = *fb = *fc = 0; pace((void *)0x1234, 78); cmd("STATUS");
            check(g_pc_calls == 2 && g_pc_id == 78 && *fa == 0.5f && *fb == 0.5f && status_has(" raised=0 "), "hooked, nobody held: the rule's values stand");
            cmd("MEN SET %IX=5,5,5", B); pace((void *)0x1234, 78); cmd("STATUS");
            check(g_pc_calls == 3 && *fa == 0.5f && *fb == 1.0f && *fc == 0.5f && status_has(" raised=1 "), "a held man's factor is raised to 1, the others keep theirs");
            g_pc_give = 1.8f; pace((void *)0x1234, 78); cmd("STATUS");
            check(*fb == 1.0f && *fa == 1.8f && status_has(" raised=2 "), "a held man's factor over 1 from the lengths: 1 too");
            g_pc_give = 3.0f; pace((void *)0x1234, 78); cmd("STATUS");
            check(*fb == 3.0f && *fa == 3.0f && status_has(" raised=2 "), "a factor of 3 (a man far behind, a rout) is left alone");
            g_pc_give = 0.5f; mb[0x3B4] = 1; pace((void *)0x1234, 78); cmd("STATUS");
            check(*fb == 0.5f && status_has(" raised=2 "), "a factor the rule set for another reason (its mark at +3B4h) is left alone");
            mb[0x3B4] = 0;
            {   /* CATCH-UP: only for a place that is the host's man's own (SET's ",1"), by his distance to it */
                double *bp = (double *)(mb + 0x4E8);
                cmd("MEN HEREAT 4E8"); bp[0] = 5 + 150; bp[1] = 5; bp[2] = 5;
                pace((void *)0x1234, 78);
                check(*fb == 1.0f, "1.5 m from a place he asked for: 1");
                cmd("MEN SET %IX=5,5,5,1", B); pace((void *)0x1234, 78); cmd("STATUS");
                check(*fb == 1.25f && status_has(" catch=1 sped=1"), "1.5 m from the host's man's own place: 1.25");
                bp[0] = 5 + 3000; pace((void *)0x1234, 78);
                check(*fb == 1.5f, "30 m from it: 1.5, no more");
                bp[0] = 5 + 40; pace((void *)0x1234, 78);
                check(*fb == 1.0f, "0.4 m from it: 1");
                bp[0] = 5 + 3000; cmd("MEN CATCH OFF"); pace((void *)0x1234, 78);
                check(*fb == 1.0f, "MEN CATCH OFF: 1");
                cmd("MEN CATCH ON"); cmd("MEN SET %IX=5,5,5", B); pace((void *)0x1234, 78);
                check(*fb == 1.0f, "a SET without the mark: a place he asked for again");
                cmd("MEN SET %IX=5,5,5,3;%IX=5,5,5,1,1", B, B); cmd("STATUS");
                check(status_has(" refused=2 "), "a SET with another fourth value is refused");
                /* MUSTER (",2"): his pace is this rule's alone, also over a 3 and over the rule's mark; up to 3 */
                bp[0] = 5; cmd("MEN SET %IX=5,5,5,2", B); g_pc_give = 3.0f; pace((void *)0x1234, 78); cmd("STATUS");
                check(*fb == 1.0f && *fa == 3.0f && status_has(" mustered=1"), "a muster's man at his place walks at 1 where the rule said 3");
                mb[0x3B4] = 1; g_pc_give = 0.5f; pace((void *)0x1234, 78);
                check(*fb == 1.0f, "also over the rule's mark");
                mb[0x3B4] = 0; bp[0] = 5 + 250; pace((void *)0x1234, 78);
                check(*fb == 2.0f, "2.5 m from his place: 2");
                bp[0] = 5 + 3000; pace((void *)0x1234, 78);
                check(*fb == 3.0f, "30 m from it: 3, no more");
                cmd("MEN SET %IX=5,5,5", B); g_pc_give = 0.5f;
                bp[0] = 5; cmd("MEN HEREAT 0");
            }
            g_pc_give = 0.5f; cmd("MEN LET %IX", B); pace((void *)0x1234, 78);
            check(*fb == 0.5f, "a man let go: the rule's value");
            cmd("MEN SET %IX=5,5,5", B); cmd("MEN PACE OFF"); pace((void *)0x1234, 78); cmd("STATUS");
            check(*fb == 0.5f && status_has(" pace=off "), "MEN PACE OFF: the rule's values stand");
            cmd("MEN PACE ON"); pace((void *)0x1234, 78);
            check(*fb == 1.0f, "MEN PACE ON: raised again");
            g_pc_squad = NULL; *fb = 0.25f; pace((void *)0x1234, 78);
            check(*fb == 0.25f, "a squad the lookup does not find: nothing written");
            g_pc_squad = sq; *(int32_t *)(sq + 0x20) = 0; pace((void *)0x1234, 78);
            check(*fb == 0.25f, "a squad without men: nothing written");
            *(int32_t *)(sq + 0x20) = 3; arr[2] = (uint8_t *)(uintptr_t)0x10; cmd("MEN SET 10=1,1,1");   /* a "man" that cannot be written, held */
            pace((void *)0x1234, 78); g_tick(NULL); cmd("STATUS");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0 && status_line("MEN unavailable exception C0000005 in the hook", 1),
                  "an exception in the pace hook is caught: both hooks out at the next tick, .text byte-identical");
            arr[2] = mc;
            pace((void *)0x1234, 79);
            check(g_pc_id == 79 && *fb == 0.5f, "and the rule runs as the game's own");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            uintptr_t B = (uintptr_t)mb;
            o.known = 1; o.men = 1; o.pace = 2;
            m = build_image(&o);
            start("V1c: the pace rule's second call reaches another routine", m, NULL, NULL, NULL);
            check(status_line("MEN idle", 1) && status_has(" pace=na "), "MEN works, the pace rule is not used");
            cmd("MEN HOOK ON"); cmd("MEN SET %IX=5,5,5", B); cmd("STATUS");
            check(status_line("MEN hooked", 1) && status_has(" pace=na ") && memcmp(m->text + m->pc_entry, m->snapshot + m->pc_entry, 16) == 0, "MEN HOOK ON: the pace rule's entry untouched");
            cmd("MEN HOOK OFF");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "MEN HOOK OFF: .text byte-identical");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.men = 1;
            m = build_image(&o);
            start("V2: MEN on another game build", m, NULL, NULL, NULL);
            check(status_line("MEN unavailable not the known game build (the record's layout is not in a signature)", 1), "MEN unavailable: another build");
            cmd("MEN HOOK ON"); cmd("MEN SET %IX=1,2,3", (uintptr_t)ma);
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "MEN HOOK ON and SET wrote nothing");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.known = 1; o.men = 2;
            m = build_image(&o);
            start("V3: the path request twice", m, NULL, NULL, NULL);
            check(status_line("MEN unavailable signature hits MPATH 2 MSLOT 1 (need exactly 1 each)", 1), "MEN unavailable with two hits");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.known = 1; o.men = 3;
            m = build_image(&o);
            start("V4: tickSquad's call reaches another routine", m, NULL, NULL, NULL);
            check(status_line("MEN unavailable MSLOT's call does not reach MPATH", 1), "MEN unavailable, with the reason");
            cmd("MEN HOOK ON");
            check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "MEN HOOK ON wrote nothing");
        }
        {
            opts_t o = { 1 };
            img_t *m;
            o.known = 1;
            m = build_image(&o);
            start("V5: no MEN routine", m, NULL, NULL, NULL);
            check(status_line("MEN unavailable signature hits MPATH 0 MSLOT 0 (need exactly 1 each)", 1), "MEN unavailable with no hit");
            check(status_line("ROUT available", 1), "the rest still works");
        }
    }

    /* lane 47: SNAP (the tables, the crash guard). A synthetic object array (one chunk, 24-byte entries), objects in
     * pages of their own; the answer snap_out.bin is parsed here as the mod's Lua parses it. */
    {
        opts_t o = { 1 };
        img_t *m;
        uint8_t *uoa, **chunks, *items, *cls = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE), *cls2 = cls + 0x800;
        uint8_t *ob[8];
        uintptr_t *list;
        int i;
        wchar_t outp[MAX_PATH];
        m = build_image(&o);
        start("SN1: SNAP (lane 47)", m, NULL, NULL, NULL);
        _snwprintf(outp, MAX_PATH, L"%ssnap_out.bin", g_io);
        DeleteFileW(outp);
        uoa = (uint8_t *)VirtualAlloc(NULL, 0x10000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        chunks = (uint8_t **)(uoa + 0x100); items = uoa + 0x200;
        *(uint8_t ***)(uoa + 0x10) = chunks; chunks[0] = items;
        *(int32_t *)(uoa + 0x20) = 65536; *(int32_t *)(uoa + 0x24) = 64; *(int32_t *)(uoa + 0x28) = 1; *(int32_t *)(uoa + 0x2C) = 1;
        for (i = 0; i < 8; i++) {
            ob[i] = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            *(int32_t *)(ob[i] + 0x0C) = 10 + i; *(uint8_t **)(ob[i] + 0x10) = cls;
            *(uint8_t **)(items + (size_t)(10 + i) * 24) = ob[i];
        }
        /* ob[0] = the root (an engine): its list at +0x100 holds ob[1..4]; ob[5] the lord, ob[6] the helper */
        list = (uintptr_t *)VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        for (i = 0; i < 4; i++) list[i] = (uintptr_t)ob[1 + i];
        *(uintptr_t **)(ob[0] + 0x100) = list; *(int32_t *)(ob[0] + 0x108) = 4; *(int32_t *)(ob[0] + 0x10C) = 8;
        for (i = 1; i <= 4; i++) { *(int32_t *)(ob[i] + 0x200) = 100 + i; *(uint8_t *)(ob[i] + 0x210) = (uint8_t)(i & 1 ? 0x40 : 0); }
        check(status_line("SNAP unavailable not the known game build", 0), "lane 47: SNAP unavailable before the test object array is put in (another build: the real one is not this build's)");
        cmd("SNAP TESTUOA %IX", (uintptr_t)uoa);
        cmd("SNAP TABLE 0 %IX 100 i200", (uintptr_t)ob[0]);
        check(status_line("SNAP off uoa=unchecked tables=0", 0), "lane 47: TABLE refused before SNAP UOA");
        {   /* SNAP UOA with an address the array does not hold: off */
            uint8_t *stray = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            *(int32_t *)(stray + 0x0C) = 20;
            cmd("SNAP UOA %IX,%IX", (uintptr_t)ob[0], (uintptr_t)stray);
            check(status_line("SNAP off uoa=unchecked", 0), "lane 47: SNAP UOA with an object the array does not hold: stays off");
        }
        cmd("SNAP UOA %IX,%IX", (uintptr_t)ob[0], (uintptr_t)ob[5]);
        check(status_line("SNAP on uoa=ok", 0), "lane 47: SNAP UOA with two objects found alive: on");
        cmd("SNAP TABLE 0 %IX 100 i200,b210:40,n100", (uintptr_t)ob[0]);
        {
            /* parse the answer: header, table 0, its entries */
            const uint8_t *b; uint32_t seq, prev, len, ntab, cnt, nch, ngone; uint16_t nf; int full, k;
            int64_t v[3]; uintptr_t a[8]; int n = 0;
            b = (const uint8_t *)read_file(outp);
            memcpy(&seq, b + 4, 4); memcpy(&prev, b + 8, 4); memcpy(&len, b + 12, 4); memcpy(&ntab, b + 16, 4);
            check(memcmp(b, "SNP1", 4) == 0 && seq == 1 && prev == 0 && ntab == 1, "lane 47: answer 1: SNP1, seq 1, one table");
            b += 20; full = b[1]; memcpy(&nf, b + 2, 2); memcpy(&cnt, b + 4, 4); memcpy(&nch, b + 8, 4); memcpy(&ngone, b + 12, 4); b += 16;
            check(b[-16] == 0 && full == 1 && nf == 3 && cnt == 4 && nch == 4 && ngone == 0, "lane 47: table 0 full, 3 fields, 4 entries, 4 changed");
            for (k = 0; k < (int)nch; k++) {
                uint64_t ad; uint32_t idx, pos, ver;
                memcpy(&ad, b, 8); memcpy(&idx, b + 8, 4); memcpy(&pos, b + 12, 4); memcpy(&ver, b + 16, 4); memcpy(v, b + 20, 24); b += 44;
                a[n++] = (uintptr_t)ad;
                if (ad == (uintptr_t)ob[3]) check(idx == 13 && pos == 2 && ver == 1 && v[0] == 103 && v[1] == 1 && v[2] == 0, "lane 47: ob3: number 13, place 2, version 1, int 103, bool 1");
            }
            check(n == 4, "lane 47: four entries read");
        }
        {   unsigned long long w0 = snap_num("writes=");
            g_tick(NULL); g_snap(NULL); cmd("STATUS");
            check(snap_num("writes=") == w0, "lane 47: nothing changed: no answer written");
            *(int32_t *)(ob[2] + 0x200) = 555; g_tick(NULL); g_snap(NULL); cmd("STATUS");
            check(snap_num("writes=") == w0 + 1, "lane 47: a field changed: one answer");
            {   const uint8_t *b = (const uint8_t *)read_file(outp); uint32_t nch, cnt; uint64_t ad; int64_t v0;
                memcpy(&cnt, b + 24, 4); memcpy(&nch, b + 28, 4); memcpy(&ad, b + 36, 8); memcpy(&v0, b + 36 + 20, 8);
                check(b[21] == 0 && cnt == 4 && nch == 1 && ad == (uintptr_t)ob[2] && v0 == 555, "lane 47: the answer holds only that entry, with the new value"); }
        }
        {   /* a freed object: its array entry emptied and its page unreadable: it leaves the table, nothing is read from it */
            DWORD old; unsigned long long f0 = snap_num("faults=");
            *(uint8_t **)(items + (size_t)12 * 24) = NULL;           /* ob[2] */
            (void)old;                                                 /* its page stays readable with its old bytes, as freed memory does */
            g_tick(NULL); g_snap(NULL); cmd("STATUS");
            {   const uint8_t *b = (const uint8_t *)read_file(outp); uint32_t nch, cnt, ngone; uint64_t ad;
                memcpy(&cnt, b + 24, 4); memcpy(&nch, b + 28, 4); memcpy(&ngone, b + 32, 4); memcpy(&ad, b + 36, 8);
                check(cnt == 3 && nch == 0 && ngone == 1 && ad == (uintptr_t)ob[2], "lane 47: freed (its entry emptied, its old bytes still there): gone, 3 left"); }
            check(snap_num("faults=") == f0, "lane 47: ... and no fault: its memory was never read (the array said no first)");
            g_tick(NULL); g_snap(NULL); cmd("STATUS");
            check(snap_num("faults=") == f0, "lane 47: ... nor at the next tick (it is no longer known; its number is read under SEH: the array decides)");
        }
        {   /* the Garbage and Unreachable flags, each word */
            uint32_t *fl = (uint32_t *)(items + (size_t)11 * 24 + 8);  /* ob[1] */
            fl[0] = 1u << 21; g_tick(NULL); g_snap(NULL);
            {   const uint8_t *b = (const uint8_t *)read_file(outp); uint32_t ngone, cnt; memcpy(&cnt, b + 24, 4); memcpy(&ngone, b + 32, 4);
                check(cnt == 2 && ngone == 1, "lane 47: Garbage (1<<21) in the first flags word: gone"); }
            fl[0] = 0; fl[1] = 1u << 28; g_tick(NULL); g_snap(NULL);
            {   const uint8_t *b = (const uint8_t *)read_file(outp); uint32_t cnt; memcpy(&cnt, b + 24, 4);
                check(cnt == 2, "lane 47: Unreachable (1<<28) in the second word: still out"); }
            fl[1] = 0; g_tick(NULL); g_snap(NULL);
            {   const uint8_t *b = (const uint8_t *)read_file(outp); uint32_t cnt, nch; memcpy(&cnt, b + 24, 4); memcpy(&nch, b + 28, 4);
                check(cnt == 3 && nch == 1, "lane 47: flags clean again: back as a new entry"); }
        }
        {   /* another object at a reused address: another number (the array holds it there) and another class */
            *(int32_t *)(ob[3] + 0x0C) = 30; *(uint8_t **)(ob[3] + 0x10) = cls2;
            *(uint8_t **)(items + (size_t)13 * 24) = NULL; *(uint8_t **)(items + (size_t)30 * 24) = ob[3];
            g_tick(NULL); g_snap(NULL);                                              /* this tick: the old one gone */
            g_tick(NULL); g_snap(NULL);
            {   const uint8_t *b = (const uint8_t *)read_file(outp); uint32_t cnt, nch, idx, ver; uint64_t ad;
                memcpy(&cnt, b + 24, 4); memcpy(&nch, b + 28, 4); memcpy(&ad, b + 36, 8); memcpy(&idx, b + 44, 4); memcpy(&ver, b + 52, 4);
                check(cnt == 3 && nch == 1 && ad == (uintptr_t)ob[3] && idx == 30 && ver == 1, "lane 47: a new object at a reused address: a new entry (number 30, version 1)"); }
        }
        {   /* the list's count out of bounds: the table stops, every entry gone */
            *(int32_t *)(ob[0] + 0x108) = 9;                          /* count above its room (8) */
            g_tick(NULL); g_snap(NULL); cmd("STATUS");
            {   const uint8_t *b = (const uint8_t *)read_file(outp); uint32_t ngone; memcpy(&ngone, b + 32, 4);
                check(ngone == 3 && status_line("SNAP on uoa=ok tables=0", 0), "lane 47: a count above the list's room: the table stops, its 3 entries gone"); }
            *(int32_t *)(ob[0] + 0x108) = 4;
        }
        {   /* a list element whose memory is unreadable and that the array does not hold: a fault, not an entry */
            unsigned long long f0;
            uint8_t *bad = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_NOACCESS);
            list[3] = (uintptr_t)bad;
            cmd("SNAP TABLE 0 %IX 100 i200,b210:40,n100", (uintptr_t)ob[0]);
            cmd("STATUS"); f0 = snap_num("faults=");
            {   const uint8_t *b = (const uint8_t *)read_file(outp); uint32_t cnt; memcpy(&cnt, b + 24, 4);
                check(cnt == 2 && f0 >= 1, "lane 47: an unreadable element the array does not hold: a fault caught, not in the table (2 entries)"); }
            list[3] = (uintptr_t)ob[4];
        }
        {   /* the crash guard */
            uintptr_t *pl = (uintptr_t *)VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE), *hl = pl + 64;
            pl[0] = (uintptr_t)ob[1]; pl[1] = (uintptr_t)ob[2]; pl[2] = 0; pl[3] = (uintptr_t)ob[4];
            *(uintptr_t **)(ob[5] + 0x740) = pl; *(int32_t *)(ob[5] + 0x748) = 4; *(int32_t *)(ob[5] + 0x74C) = 8;
            hl[0] = (uintptr_t)ob[1]; *(uintptr_t **)(ob[6] + 0x740) = hl; *(int32_t *)(ob[6] + 0x748) = 1; *(int32_t *)(ob[6] + 0x74C) = 4;
            cmd("SNAP GUARD %IX %IX 740", (uintptr_t)ob[5], (uintptr_t)ob[6]);
            cmd("STATUS");
            check(status_line("GUARD on fixed=2 emptied=0 helper=1", 0), "lane 47: GUARD: 2 entries of the lord's list (a freed object, a null) replaced, the helper's list emptied");
            check(pl[1] == (uintptr_t)ob[1] && pl[2] == (uintptr_t)ob[1] && pl[0] == (uintptr_t)ob[1] && pl[3] == (uintptr_t)ob[4] && *(int32_t *)(ob[5] + 0x748) == 4 && *(int32_t *)(ob[6] + 0x748) == 0,
                  "lane 47: ... by the first living entry; the count stays 4; the helper's count 0");
            {   /* round two: coop_guard_tick alone does the guard's work (the tables run at a lower rate) */
                tick_fn gg = g_guard;
                hl[0] = (uintptr_t)ob[1]; *(int32_t *)(ob[6] + 0x748) = 1;
                if (gg) gg(NULL);
                check(gg != NULL && *(int32_t *)(ob[6] + 0x748) == 0, "lane 47: coop_guard_tick alone empties the helper's list again");
            }
            pl[0] = 0; pl[1] = 0; pl[2] = 0; pl[3] = 0;
            g_tick(NULL); g_snap(NULL); cmd("STATUS");
            check(status_line("GUARD on fixed=2 emptied=4", 0) && *(int32_t *)(ob[5] + 0x748) == 0, "lane 47: no living entry: the lord's list emptied (count 0)");
            *(uint8_t **)(items + (size_t)15 * 24) = NULL;            /* the lord freed */
            g_tick(NULL); g_snap(NULL); cmd("STATUS");
            check(status_line("GUARD off", 0), "lane 47: the lord no longer in the object array: the guard goes off (nothing written)");
        }
        {   /* a uint8 list and two goods lists (24-byte records): the answer's order (8 bytes a field, then the lists) */
            uint8_t *ug = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            int32_t *g1 = (int32_t *)(ug + 0x100), *g2 = (int32_t *)(ug + 0x400);
            ug[0] = 3; ug[1] = 7;
            g1[0] = 17; g1[1] = 5; g1[6] = 18; g1[7] = 9;        /* records of 24 bytes: type, amount at +0, +4 */
            g2[0] = 2; g2[1] = 40;
            cmd("SNAP TABLE 0 OFF");
            list[0] = (uintptr_t)ob[1]; *(int32_t *)(ob[0] + 0x108) = 1;
            *(uint8_t **)(ob[1] + 0x300) = ug; *(int32_t *)(ob[1] + 0x308) = 2; *(int32_t *)(ob[1] + 0x30C) = 4;
            *(int32_t **)(ob[1] + 0x310) = g1; *(int32_t *)(ob[1] + 0x318) = 2; *(int32_t *)(ob[1] + 0x31C) = 4;
            *(int32_t **)(ob[1] + 0x320) = g2; *(int32_t *)(ob[1] + 0x328) = 1; *(int32_t *)(ob[1] + 0x32C) = 4;
            cmd("SNAP TABLE 1 %IX 100 i200,a300:10,g310:18,g320:18", (uintptr_t)ob[0]);
            {   const uint8_t *b = (const uint8_t *)read_file(outp), *e; uint32_t nch; uint16_t na, n1, n2; int64_t v[4]; int32_t q[6];
                memcpy(&nch, b + 28, 4); e = b + 36;
                memcpy(v, e + 20, 32); e += 52;
                memcpy(&na, e, 2); e += 2; e += na;
                memcpy(&n1, e, 2); e += 2; memcpy(q, e, 16); e += 16;
                memcpy(&n2, e, 2); e += 2; memcpy(q + 4, e, 8);
                check(b[20] == 1 && nch == 1 && v[1] == 2 && v[2] == 2 && v[3] == 1 && na == 2 && b[36 + 52 + 2] == 3 && b[36 + 52 + 3] == 7 && n1 == 2 && q[0] == 17 && q[1] == 5 && q[2] == 18 && q[3] == 9 && n2 == 1 && q[4] == 2 && q[5] == 40,
                      "lane 47: table 1: counts as fields, then the uint8 list (3, 7), then goods 17x5, 18x9, then 2x40");
            }
            cmd("SNAP TABLE 1 OFF");
        }
        cmd("SNAP OFF"); cmd("STATUS");
        check(status_line("SNAP off", 0), "lane 47: SNAP OFF");
    }

    /* ======================================================== O: PICK FOLLOW (lane 35, round seven: the ox) */
    {
        static __declspec(align(16)) uint8_t ua[0x1000], ub[0x1000], r41a[0xD8], r41b[0xD8], r22[0xD8];
        opts_t o = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        img_t *m = build_image(&o);
        settask_fn st = (settask_fn)(void *)(m->text + m->pk_settask);
        settask_fn thunk = (settask_fn)(void *)(m->text + m->st_thunk);
        uint64_t ox1 = 0x7FF0000A000ull, ox2 = 0x7FF0000B000ull;
        memset(ua, 0, sizeof(ua)); memset(ub, 0, sizeof(ub)); memset(r41a, 0, 0xD8); memset(r41b, 0, 0xD8); memset(r22, 0, 0xD8);
        r41a[0] = 41; r41b[0] = 41; r22[0] = 22; memcpy(r41a + 0xA8, &ox1, 8); memcpy(r41b + 0xA8, &ox2, 8);
        start("O1: PICK FOLLOW, a Follow the game sets by itself only for the board's leader of that ox", m, NULL, NULL, NULL);
        cmd("PICK ON"); cmd("PICK SET %llX:29:%llX", (unsigned long long)(uintptr_t)ua, (unsigned long long)ox1);
        *(uint8_t **)(ub + 0x898) = r22; *(int32_t *)(ub + 0x8A0) = 1;
        st(ub, r41a); cmd("STATUS");
        check(*(int32_t *)ub == 1 && ub[8] == 22 && status_has("follow=1 followok=0 followleft=0"), "the game's own Follow for a villager not on the list: its own task (22) set instead");
        *(int32_t *)(ub + 0x8A0) = 0;
        st(ub, r41a); cmd("STATUS");
        check(*(int32_t *)ub == 2 && ub[8] == 41 && status_has("followleft=1"), "the same with no task: the Follow goes through (never refused)");
        thunk(ua, r41a); cmd("STATUS");
        check(*(int32_t *)ua == 1 && ua[8] == 41 && *(uint64_t *)(ua + 0x10) == ox1, "a Follow through the reflected setTask (the board's give): done and kept");
        st(ua, r41b); cmd("STATUS");
        check(*(int32_t *)ua == 2 && ua[8] == 41 && *(uint64_t *)(ua + 0x10) == ox1 && status_has("follow=2 "), "the game's own Follow of another ox for the board's leader: the kept Follow of the host's ox instead");
        st(ua, r41a); cmd("STATUS");
        check(*(int32_t *)ua == 3 && ua[8] == 41 && status_has("followok=1 "), "the game's own Follow of the host's ox for the board's leader: done");
        st(ub, r22);
        check(*(int32_t *)ub == 3 && ub[8] == 22, "other task types: as before");
        cmd("ALLOFF");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "ALLOFF: .text byte-identical");
    }

    /* ======================================================== P: GOODS and a demolished building (lane 46) */
    {
        typedef void (*dem_call)(void *b, void *pile, void *region);
        opts_t o = { 1 };
        img_t *m;
        uint8_t *lord = (uint8_t *)VirtualAlloc(NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        uint8_t *b, *b2, *b3, *pile;
        unsigned long long fr, fx;
        o.goods = 1; o.demref = 1;
        m = build_image(&o);
        b = mk_building(m, 72, lord); b2 = mk_building(m, 72, lord); b3 = mk_building(m, 72, lord); pile = mk_building(m, 0x58, lord);
#define DEMOLISH_SIM(x) do { garr_t *a_ = (garr_t *)((x) + 0x448); a_->num = 0; a_->max = 0;          /* emptied in place, no room */ \
                             ((dem_call)(void *)(m->text + m->dem))((x), pile, g_region); } while (0)
        start("P1: GOODS, the demolish's refresh of the building (DEMREF): never given its stock back", m, NULL, NULL, NULL);
        cmd("GOODS ON %llu", (unsigned long long)(uintptr_t)lord);
        check(status_has("goodsgone site=1 rule=on demolished=0"), "status: the DEMREF site is found, the rule on");
        mod_write(m, b, 17, 5);
        fr = status_num("frozen="); fx = status_num("fixed=");
        check(stock(b, 17) == 5 && fr >= 1, "(setup) the host's word: 5 planks, remembered");
        g_rf_calls = 0;
        DEMOLISH_SIM(b);
        check(g_rf_calls == 2 && g_rf_b == pile, "the demolish ran both refreshes (building, then pile)");
        check(stock(b, 17) == 0 && status_num("demolished=") == 1, "the building being demolished is not given its planks back and is forgotten (demolished=1)");
        g_rc_calls = 0; g_tick(NULL); g_tick(NULL);
        check(stock(b, 17) == 0 && g_rc_calls == 0 && status_num("fixed=") == fx, "no repair at the next ticks: addToInventory and recountStorage are not run for it (the region's sets stay without it)");
        fr = status_num("frozen=");
        game_write(m, b, 17, 3, NULL);
        check(stock(b, 17) == 3 && status_num("frozen=") == fr && status_num("takeskip=") >= 1, "a later change of the game's own: left alone, the lord's building is NOT taken in again");
        cmd("GOODS AUDIT");
        check(status_num("leaks=") == 0, "the audit finds nothing to repair in it");
        mod_write(m, b, 17, 2);
        check(status_num("modwrites=") == 2 && status_num("frozen=") == fr, "a mod write into it is counted (its two hooked calls: modwrites=2) and does not freeze it again");
        cmd("ALLOFF");

        start("P2: the same with the rule switched off (GOODS DEMRULE OFF, test switch): the fault of 2026-11-13", m, NULL, NULL, NULL);
        cmd("GOODS ON %llu", (unsigned long long)(uintptr_t)lord);
        mod_write(m, b2, 17, 5);
        cmd("GOODS DEMRULE OFF");
        check(status_has("rule=off"), "status rule=off");
        fx = status_num("fixed=");
        DEMOLISH_SIM(b2);
        check(stock(b2, 17) == 0, "inside the demolish the list has no room: nothing put back in place");
        g_rc_calls = 0; g_tick(NULL);
        check(stock(b2, 17) == 5 && g_rc_calls >= 1 && status_num("fixed=") == fx + 1, "without the rule the tick repairs it: 5 planks back through addToInventory and recountStorage (the call that registers it again)");
        cmd("GOODS DEMRULE ON");
        check(status_has("rule=on"), "GOODS DEMRULE ON: status rule=on");
        cmd("ALLOFF");

        start("P3: GOODS GONE <addr>,... (the Lua side at a DEMOLISH)", m, NULL, NULL, NULL);
        cmd("GOODS ON %llu", (unsigned long long)(uintptr_t)lord);
        mod_write(m, b3, 17, 5);
        cmd("GOODS GONE 0x%llX,0x10", (unsigned long long)(uintptr_t)b3);
        check(status_num("marks=") == 1, "one mark (the second address is refused: not readable)");
        game_write(m, b3, 17, -2, NULL);
        g_tick(NULL);
        check(stock(b3, 17) == 3, "the game's own change of a marked building stays (no put-back, no repair)");
        cmd("ALLOFF");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "ALLOFF: .text byte-identical");
#undef DEMOLISH_SIM
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.goods = 1; o.demref = 2;
        m = build_image(&o);
        start("P4: DEMREF's call goes elsewhere: GOODS works, the demolish rule is out", m, NULL, NULL, NULL);
        cmd("GOODS ON");
        check(status_line("GOODS on", 1) && status_has("goodsgone site=0"), "GOODS on, goodsgone site=0");
        cmd("ALLOFF");
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.goods = 1;
        m = build_image(&o);
        start("P5: no DEMREF site at all", m, NULL, NULL, NULL);
        cmd("GOODS ON");
        check(status_line("GOODS on", 1) && status_has("goodsgone site=0"), "GOODS on, goodsgone site=0");
        cmd("ALLOFF");
    }

    /* ======================================================== G: GUIDE, who guides which ox (lane 49) */
    {
        static __declspec(align(16)) uint8_t ox[0x400], ox2[0x400], v1[0x400], v2[0x400], v3[0x400], novt[0x400];
        opts_t o = { 1 };
        img_t *m;
        const char *gf;
        wchar_t gp[MAX_PATH];
        uint64_t vt;
        o.known = 1; o.guide = 1;
        m = build_image(&o);
        vt = (uint64_t)(uintptr_t)(m->text + 0x40);
        memset(ox, 0, sizeof(ox)); memset(ox2, 0, sizeof(ox2)); memset(v1, 0, sizeof(v1)); memset(v2, 0, sizeof(v2)); memset(v3, 0, sizeof(v3)); memset(novt, 0, sizeof(novt));
        memcpy(ox, &vt, 8); memcpy(ox2, &vt, 8); memcpy(v1, &vt, 8); memcpy(v2, &vt, 8); memcpy(v3, &vt, 8);
        start("G1: GUIDE (known build)", m, NULL, NULL, NULL);
        check(status_line("GUIDE available sets=0 taken=0 clears=0 cleared=0 lists=0 bad=0 faults=0", 1), "GUIDE found: the guide assignment's pattern once, both writes at +330h");
        *(uint8_t **)(v2 + 0x330) = ox; *(uint8_t **)(v3 + 0x330) = ox2;       /* v2 holds the ox (this copy's own choice) */
        cmd("GUIDE SET %llX %llX %llX,%llX,%llX", (unsigned long long)(uintptr_t)ox, (unsigned long long)(uintptr_t)v1, (unsigned long long)(uintptr_t)v1, (unsigned long long)(uintptr_t)v2, (unsigned long long)(uintptr_t)v3); cmd("STATUS");
        check(*(uint8_t **)(v1 + 0x330) == ox && *(uint8_t **)(v2 + 0x330) == NULL && *(uint8_t **)(v3 + 0x330) == ox2 && status_has("sets=1 taken=1 "),
              "SET: the leader's +330h is the ox; the other unit that held this ox lets go; a unit holding another ox is left alone");
        cmd("GUIDE SET %llX %llX", (unsigned long long)(uintptr_t)ox2, (unsigned long long)(uintptr_t)v2); cmd("STATUS");
        check(*(uint8_t **)(v2 + 0x330) == ox2 && *(uint8_t **)(v3 + 0x330) == ox2 && status_has("sets=2 taken=1 "), "SET with no list: only the leader is written");
        cmd("GUIDE LIST %llX,%llX,%llX", (unsigned long long)(uintptr_t)v1, (unsigned long long)(uintptr_t)v2, (unsigned long long)(uintptr_t)v3); cmd("STATUS");
        _snwprintf(gp, MAX_PATH, L"%sguide.txt", g_io); gf = read_file(gp);
        { char e1[64]; _snprintf(e1, sizeof(e1), "%llX %llX", (unsigned long long)(uintptr_t)v1, (unsigned long long)(uintptr_t)ox);
          check(strstr(gf, e1) != NULL && strstr(gf, "END") != NULL && status_has("lists=1 "), "LIST writes each unit's +330h"); }
        cmd("GUIDE CLEAR %llX %llX,%llX,%llX", (unsigned long long)(uintptr_t)ox2, (unsigned long long)(uintptr_t)v1, (unsigned long long)(uintptr_t)v2, (unsigned long long)(uintptr_t)v3); cmd("STATUS");
        check(*(uint8_t **)(v1 + 0x330) == ox && *(uint8_t **)(v2 + 0x330) == NULL && *(uint8_t **)(v3 + 0x330) == NULL && status_has("clears=1 cleared=2 "), "CLEAR: every unit naming a gone ox lets go, the others keep theirs");
        cmd("GUIDE SET %llX %llX", (unsigned long long)(uintptr_t)ox, (unsigned long long)(uintptr_t)ox);
        cmd("GUIDE SET 0 %llX", (unsigned long long)(uintptr_t)v1);
        cmd("GUIDE SET %llX %llX", (unsigned long long)(uintptr_t)ox, (unsigned long long)(uintptr_t)novt);
        cmd("GUIDE LIST 1001"); cmd("GUIDE CLEAR xyz %llX", (unsigned long long)(uintptr_t)v1); cmd("GUIDE MAYBE"); cmd("STATUS");
        check(status_has("bad=6 ") && *(uint8_t **)(novt + 0x330) == NULL, "6 bad forms refused (leader = ox, null, no vtable in the module, unaligned, not hex, no verb); nothing written");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "GUIDE never writes to .text");
        cmd("ALLOFF");
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.guide = 1;
        m = build_image(&o);
        start("G2: GUIDE on another game build", m, NULL, NULL, NULL);
        check(status_line("GUIDE unavailable another game build", 0), "GUIDE unavailable: another build");
        cmd("GUIDE LIST 1000"); cmd("STATUS"); check(status_line("GUIDE unavailable", 0), "a command is refused");
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.known = 1; o.guide = 2;
        m = build_image(&o);
        start("G3: GUIDE's pattern twice", m, NULL, NULL, NULL);
        check(status_line("GUIDE unavailable GUIDE signature has 2 hits", 0), "GUIDE unavailable: two hits");
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.known = 1; o.guide = 3;
        m = build_image(&o);
        start("G4: the guide assignment writes another offset", m, NULL, NULL, NULL);
        check(status_line("GUIDE unavailable GUIDE signature has 0 hits", 0), "GUIDE unavailable: no site");
    }

    /* ======================================================== F: FELL, a tree being felled falls at the next stroke (lane 54) */
    {
        static __declspec(align(16)) uint8_t reg[0x1000], reg0[0x1000], novt[0x1000];
        static __declspec(align(16)) uint8_t recs[3 * 0x28];
        opts_t o = { 1 };
        img_t *m;
        uint64_t vt;
        double p[3][3] = { { 81947.0, -85327.0, 1970.0 }, { 79761.4, -78288.3, 2011.0 }, { 78687.0, -78058.0, 2017.0 } };
        float left[3] = { 60.0f, 35.0f, -5.0f }, f0, f1, f2;
        int i, n = 3;
        o.known = 1; o.fell = 1;
        m = build_image(&o);
        vt = (uint64_t)(uintptr_t)(m->text + 0x40);
        memset(reg, 0, sizeof(reg)); memset(reg0, 0, sizeof(reg0)); memset(novt, 0, sizeof(novt)); memset(recs, 0, sizeof(recs));
        memcpy(reg, &vt, 8); memcpy(reg0, &vt, 8);
        for (i = 0; i < 3; i++) { memcpy(recs + i * 0x28, p[i], 24); memcpy(recs + i * 0x28 + 0x18, &left[i], 4); }
        *(uint8_t **)(reg + 0xCD0) = recs; memcpy(reg + 0xCD8, &n, 4);
        *(uint8_t **)(novt + 0xCD0) = recs; memcpy(novt + 0xCD8, &n, 4);
        start("F1: FELL (known build)", m, NULL, NULL, NULL);
        check(status_line("FELL available fells=0 already=0 misses=0 bad=0 faults=0", 1), "FELL found: the lookup and the stroke once each, the list at +CD0h, what is left at +18h");
        cmd("FELL %llX 79761 -78288", (unsigned long long)(uintptr_t)reg); cmd("STATUS");
        memcpy(&f0, recs + 0x18, 4); memcpy(&f1, recs + 0x28 + 0x18, 4); memcpy(&f2, recs + 0x50 + 0x18, 4);
        check(f0 == 60.0f && f1 == 0.0f && f2 == -5.0f && status_has("fells=1 already=0 misses=0 "), "the tree at that place (rounded to cm) has 0 left; the others keep theirs");
        cmd("FELL %llX 79761 -78288", (unsigned long long)(uintptr_t)reg); cmd("FELL %llX 78687 -78058", (unsigned long long)(uintptr_t)reg); cmd("STATUS");
        memcpy(&f2, recs + 0x50 + 0x18, 4);
        check(f2 == -5.0f && status_has("fells=1 already=2 "), "a tree with nothing left is not written again");
        cmd("FELL %llX 81950 -85327", (unsigned long long)(uintptr_t)reg); cmd("FELL %llX 81947 -85327", (unsigned long long)(uintptr_t)reg0); cmd("STATUS");
        memcpy(&f0, recs + 0x18, 4);
        check(f0 == 60.0f && status_has("misses=2 "), "no record within 1.5 cm (3 cm off), and a region with an empty list: nothing written");
        n = 30000; memcpy(reg0 + 0xCD8, &n, 4); *(uint8_t **)(reg0 + 0xCD0) = recs;
        cmd("FELL %llX 81947 -85327", (unsigned long long)(uintptr_t)reg0);                 /* a count no list has */
        cmd("FELL %llX 81947 -85327", (unsigned long long)(uintptr_t)novt);                 /* no vtable in the module */
        cmd("FELL 0 81947 -85327"); cmd("FELL %llX 81947", (unsigned long long)(uintptr_t)reg); cmd("FELL %llX x -85327", (unsigned long long)(uintptr_t)reg); cmd("STATUS");
        memcpy(&f0, recs + 0x18, 4);
        check(f0 == 60.0f && status_has("bad=5 ") && status_has("faults=0"), "5 bad forms refused (a count of 30000, no vtable, null, a missing number, not a number); nothing written");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "FELL never writes to .text");
        cmd("ALLOFF");
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.fell = 1;
        m = build_image(&o);
        start("F2: FELL on another game build", m, NULL, NULL, NULL);
        check(status_line("FELL unavailable another game build", 0), "FELL unavailable: another build");
        cmd("FELL 1000 1 1"); cmd("STATUS"); check(status_line("FELL unavailable", 0), "a command is refused");
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.known = 1; o.fell = 2;
        m = build_image(&o);
        start("F3: FELL's lookup pattern twice", m, NULL, NULL, NULL);
        check(status_line("FELL unavailable TREEFIND signature has 2 hits", 0), "FELL unavailable: two hits");
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.known = 1; o.fell = 3;
        m = build_image(&o);
        start("F4: a stroke that writes another offset", m, NULL, NULL, NULL);
        check(status_line("FELL unavailable FELLHIT signature has 0 hits", 0), "FELL unavailable: no stroke site");
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.known = 1; o.fell = 4;
        m = build_image(&o);
        start("F5: the lookup without the stroke", m, NULL, NULL, NULL);
        check(status_line("FELL unavailable FELLHIT signature has 0 hits", 0), "FELL unavailable: one of its two patterns is missing");
    }
    /* ======================================================== E: ENDHOLD, a task ends on the host's word (lane 49, round four) */
    {
        static __declspec(align(16)) uint8_t unit[0x1000], rec[0xD8 * 2];
        opts_t o = { 1 };
        img_t *m;
        typedef void (*callfn)(void *u);
        callfn ein, eout;
        uint64_t ehb = 0x7FF00055000ull, ehx = 0x7FF00066000ull;
        uint8_t *recp = rec;
        o.known = 1; o.pick = 1; o.endtask = 1;
        m = build_image(&o);
        ein = (callfn)(void *)(m->text + m->eh_in); eout = (callfn)(void *)(m->text + m->eh_out);
#define EH_ARM(ty, b) do { memset(unit, 0, sizeof(unit)); memset(rec, 0, sizeof(rec)); rec[0] = (ty); memcpy(rec + 0x98, &(b), 8); memcpy(unit + 0x898, &recp, 8); *(int32_t *)(unit + 0x8A0) = 1; } while (0)
        start("E1: ENDHOLD (known build)", m, NULL, NULL, NULL);
        check(status_line("ENDHOLD off n=0 held=0", 0), "ENDHOLD found: ENDTASK once, SETTASK once, the entry's bytes its own");
        cmd("ENDHOLD RANGE %llX %llX", (unsigned long long)(uintptr_t)(m->text + m->eh_in), (unsigned long long)(uintptr_t)(m->text + m->eh_in + 0x20));
        cmd("ENDHOLD ON"); cmd("ENDHOLD SET 7530 %llX:4:%llX", (unsigned long long)(uintptr_t)unit, (unsigned long long)ehb); cmd("STATUS");
        check(status_line("ENDHOLD on n=1 ", 0), "ON, one unit on the list");
        check(memcmp(m->text + m->eh_end, m->snapshot + m->eh_end, 5) != 0, "the entry's first 5 bytes are the jump to the stub");
        EH_ARM(4, ehb); ein(unit); cmd("STATUS");
        check(*(int32_t *)(unit + 0x8A0) == 0 && unit[8] == 4 && *(int32_t *)unit == 1 && status_has("held=1 "), "an end from the task steps: the game's end ran, then setTask set the same task again (type 4)");
        EH_ARM(4, ehb); eout(unit); cmd("STATUS");
        check(*(int32_t *)(unit + 0x8A0) == 0 && *(int32_t *)unit == 0 && status_has("held=1 ") && status_has("passed=1 "), "an end from outside the task steps (death, demolish, call-up): passes, nothing set");
        EH_ARM(22, ehb); ein(unit); cmd("STATUS");
        check(*(int32_t *)unit == 0 && status_has("held=1 ") && status_has("skipped=1 "), "another task type than the listed one: passes");
        EH_ARM(4, ehx); ein(unit); cmd("STATUS");
        check(*(int32_t *)unit == 0 && status_has("skipped=2 "), "the same type at another building: passes");
        EH_ARM(4, ehb); unit[0x30C] = 1; ein(unit); cmd("STATUS");
        check(*(int32_t *)unit == 0 && status_has("skipped=3 "), "a dead unit: passes");
        cmd("ENDHOLD SET 1 %llX:4:%llX", (unsigned long long)(uintptr_t)unit, (unsigned long long)ehb); Sleep(20);
        EH_ARM(4, ehb); ein(unit); cmd("STATUS");
        check(*(int32_t *)unit == 0 && status_has("expired=1 ") && status_has("ceilunits=1 "), "its first held end longer ago than the ceiling: passes (counted expired, the unit counted once)");
        EH_ARM(4, ehb); ein(unit); cmd("STATUS");
        check(*(int32_t *)unit == 0 && status_has("expired=2 ") && status_has("ceilunits=1 ") && status_has("skt=1 skb=1"), "the next end passes too; the unit is counted once; the skips by reason");
        cmd("ENDHOLD SET 1 %llX:4:%llX:2", (unsigned long long)(uintptr_t)unit, (unsigned long long)ehb); Sleep(20);
        EH_ARM(4, ehb); ein(unit); cmd("STATUS");
        check(*(int32_t *)unit == 1 && status_has("held=2 ") && status_has("expired=2 "), "the host's next start of the same task (another start number): a new entry, held again however long it was listed");
        Sleep(20); EH_ARM(4, ehb); ein(unit); cmd("STATUS");
        check(*(int32_t *)unit == 0 && status_has("expired=3 ") && status_has("ceilunits=2 "), "and it passes once its own first held end is older than the ceiling");
        cmd("ENDHOLD SET 7530 -"); EH_ARM(4, ehb); ein(unit); cmd("STATUS");
        check(*(int32_t *)unit == 0 && status_line("ENDHOLD on n=0 ", 0), "the unit off the list (the host's end or next start): passes");
        cmd("ENDHOLD SET 7530 xyz"); cmd("ENDHOLD SET zz -"); cmd("ENDHOLD MAYBE"); cmd("STATUS");
        if (!status_has("sets=4 bad=3")) printf("%s\n", read_file(g_status));
        check(status_has("sets=4 bad=3"), "3 bad forms refused");
        cmd("ALLOFF");
        check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "ALLOFF: .text byte-identical");
        EH_ARM(4, ehb); ein(unit);
        check(*(int32_t *)(unit + 0x8A0) == 0 && *(int32_t *)unit == 0, "after ALLOFF the end runs as the game's own");
#undef EH_ARM
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.pick = 1; o.endtask = 1;
        m = build_image(&o);
        start("E2: ENDHOLD on another game build", m, NULL, NULL, NULL);
        check(status_line("ENDHOLD unavailable another game build", 0), "ENDHOLD unavailable: another build");
        cmd("ENDHOLD ON"); cmd("STATUS"); check(memcmp(m->text, m->snapshot, TEXT_SIZE) == 0, "ON refused, nothing written");
    }
    {
        opts_t o = { 1 };
        img_t *m;
        o.known = 1; o.endtask = 1;
        m = build_image(&o);
        start("E3: ENDHOLD without setTask's signature", m, NULL, NULL, NULL);
        check(status_line("ENDHOLD unavailable SETTASK signature has 0 hits", 0), "ENDHOLD unavailable without setTask");
    }

    test_report();                              /* lane 61 */
    printf("\nRESULT: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
