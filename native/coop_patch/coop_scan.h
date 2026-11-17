/* coop_scan.h - signature table and scan code shared by coop_patch.dll (in memory) and tools\sigcheck.exe (file on disk).
 *
 * Source of every byte below: research\2026-11-10-game-probe\registry\native5\sigs5.txt ("== PATCHES ==" and
 * "== FUNCTION ENTRY SIGNATURES ==") and registry\native4_sigs.txt (reformSquad 4d7cce0).
 * Report sections followed: native5\report.txt answer 4 (P1), answer 5 (P2, P3a, P3b, TriggerSquadRetreat),
 * answer 6 (method: .text only, exactly one hit, original bytes, call target check, one aligned qword).
 *
 * Nothing in this file writes memory or calls Windows. The caller hands in a view of .text:
 *   text      pointer to the first byte of .text (in memory, or the raw bytes read from the file)
 *   text_rva  RVA of that first byte
 *   text_len  number of bytes to scan
 */
#ifndef COOP_SCAN_H
#define COOP_SCAN_H

#include <stdint.h>
#include <string.h>
#include <stdio.h>

#define KNOWN_TIMESTAMP 0x6836C1BAu     /* sigs5.txt line 1: the build the report was made from */
#define KNOWN_IMAGESIZE 0x9DFD000u
#define SIG_MAX         128             /* longest pattern in bytes (ADDINV is 105) */
#define PATCH_MAX       8

/* kind of a signature */
#define K_ENTRY   0     /* a function entry: only "exactly one hit" matters (and it is the call target of a patch) */
#define K_FIXED   1     /* patch with fixed original bytes (P1, ALT-A, ALT-B) */
#define K_CALL    2     /* patch "E8 rel32 -> EB 03": original byte 1 is the low byte of rel32, checked through the target */
#define K_SITE    3     /* a recognised call site (never written): patch_off = offset of its E8, call_target = the entry it must reach */

typedef struct {
    const char *name;           /* short name used in the status file and the log */
    const char *what;           /* plain words */
    const char *pattern;        /* "44 0F ?? ..." */
    int         kind;
    int         patch_off;      /* offset of the patch inside the pattern (-1 for K_ENTRY) */
    int         patch_len;
    uint8_t     orig[PATCH_MAX];    /* K_FIXED: original bytes. K_CALL: orig[0] = E8, orig[1] = this build's value (sigs5) */
    uint8_t     patched[PATCH_MAX];
    int         call_target;    /* K_CALL: index (in the same table) of the entry signature the call must reach */
    uint32_t    ref_rva;        /* RVA of the first pattern byte in sigs5.txt / native4_sigs.txt */
    int         used_by_dll;    /* 1 = the DLL uses it; 0 = only checked by the offline tool */
} sig_def;

/* Indexes used by the DLL. Keep the order: entries first (the patches point at them). */
enum { S_TSR = 0, S_REFORM, S_P1, S_P2, S_P3A, S_P3B, S_NF1, S_NF2, S_JG /* lane 19 */, S_FINISH, S_BURN, S_FIREOUT, S_RECOUNT, S_REFRESH, S_ADDINV,
       S_ADDLIST /* lane 22 */, S_NOTIFY, S_TS1, S_TS2, S_TS3, S_TS4, S_TS5, S_TS6,
       S_CURSOR /* lane 26 */, S_LMBDOWN, S_LMBUP, S_RMBDOWN, S_RMBUP /* lane 26 */,
       S_CHOOSE /* lane 23 */,
       S_TOOLUPD /* lane 28 */, S_ROADCLICK, S_COMMITROAD, S_MOVESEL, S_PATHPT /* lane 28 */,
       S_HAPPR /* lane 31 (HOLD) */, S_HORDER, S_HSUPPL, S_HWADD, S_HWSUB, S_HPADD, S_HPREM, S_HWMON, S_HPRMALL /* lane 31 */,
       S_HEMIG /* lane 36 (HOLD) */, S_HHOUSE /* lane 36 */,
       S_UNCAMP /* lane 32 */,
       S_NOREGION /* the lead, 2026-11-13 */, S_NOREGION2,
       S_SETTASK /* lane 35 */, S_CHOOSECALL /* lane 35 */,
       S_FCACHE /* lane 40 (FIELD) */, S_FDRAW, S_FPAINT /* lane 40 */,
       S_DISTCALL /* lane 42 (DIST) */, S_DIST, S_DGROW, S_DGSURP /* lane 42 */,
       S_REGSETS /* lane 35, round six */,
       S_MPATH /* lane 43 (MEN) */, S_MSLOT /* lane 43 */,
       S_SETTHUNK /* lane 35, round seven */,
       S_DEMREF /* lane 46 */,
       S_GUIDE /* lane 49 */,
       S_WALLREB /* lane 53 (WALLSET) */, S_WALLINS /* lane 53 */, S_PACE /* lane 52 (MEN: the squad's pace rule) */,
       S_TREEFIND /* lane 54 (FELL) */, S_FELLHIT /* lane 54 */,
       S_ENDTASK /* lane 49, round four */, S_DLL_COUNT };
#define HOLD_GATES 10                   /* lane 31: S_HAPPR .. S_HPREM and S_HPRMALL are hooked at their entry; S_HWMON is a store site; lane 36: S_HEMIG */
#define TOTALS_SITES 6
#define S_PATCH_LAST S_JG      /* the patch sites are S_P1..S_PATCH_LAST */

static const sig_def SIGS[] = {
    /* report 5 / sigs5 "FUNCTION ENTRY": TriggerSquadRetreat(USquadComponent*, int handle), void */
    { "TSR", "TriggerSquadRetreat entry",
      "48 89 4C 24 08 55 53 57 41 54 48 8D 6C 24 E8 48 81 EC 18 01 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d88ce0, 1 },
    /* native4_sigs.txt line 11: reformSquad(USquadComponent*, int handle) */
    { "REFORM", "reformSquad entry",
      "40 53 55 41 57 48 81 EC C0 00 00 00 8B DA 4C 8B F9 E8 ?? ?? ?? ??",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d7cce0, 1 },
    /* report 4 (b): je 4dac5aa -> 2-byte NOP: CombatHit always takes the avoidKilling branch */
    { "P1", "never kill (CombatHit death check)",
      "44 0F 2F BE E8 02 00 00 0F 82 ?? ?? ?? ?? 80 BD 48 04 00 00 00 74 1C C7 86 E8 02 00 00 00 00 80 3F E9 ?? ?? ?? ??",
      K_FIXED, 21, 2, {0x74, 0x1C}, {0x66, 0x90}, -1, 0x4dac577, 1 },
    /* report 5: calculateMorale's call to TriggerSquadRetreat -> jmp over it */
    { "P2", "no own rout (calculateMorale)",
      "48 3B CA 74 1C 0F 1F 00 48 8B 01 80 B8 6C 0B 00 00 00 0F 85 ?? ?? ?? ?? 48 83 C1 08 48 3B CA 75 E7 8B D7 49 8B CF E8 ?? ?? ?? ?? E9 ?? ?? ?? ??",
      K_CALL, 38, 2, {0xE8, 0xFD}, {0xEB, 0x03}, S_TSR, 0x4d669b8, 1 },
    /* report 5 (optional): calculateMorale's call to reformSquad */
    { "P3a", "no own reform (calculateMorale)",
      "8B D7 49 8B CF E8 ?? ?? ?? ?? E9 ?? ?? ?? ?? 49 8B 7E 18",
      K_CALL, 5, 2, {0xE8, 0xB2}, {0xEB, 0x03}, S_REFORM, 0x4d66b24, 1 },
    /* report 5 (optional): updateFleeingSquad's call to reformSquad */
    { "P3b", "no own reform (updateFleeingSquad)",
      "0F 86 ?? ?? ?? ?? 8B D3 48 8B CF E8 ?? ?? ?? ??",
      K_CALL, 11, 2, {0xE8, 0xC5}, {0xEB, 0x03}, S_REFORM, 0x4d8160b, 1 },
    /* NOFINISH (session 20): the game's two own calls to finishConstruction are jumped over on a friend's copy, so a
     * building there is finished only by the host (FINISH). Both are "test al,al; je over; mov rcx,<building>; call":
     * the je becomes a jmp. NF1 = the builder's hammer handler (call at 4dc57dd), NF2 = the construction visuals'
     * async callback (call at 4cbdb1e). After the jump both continue exactly as after the call. */
    { "NF1", "no own finish (builder's hammer)",
      "4C 8D 45 00 48 89 75 00 48 8B D7 48 89 75 08 49 8D 8F 48 04 00 00 E8 ?? ?? ?? ?? 84 C0 74 08 49 8B CF E8 ?? ?? ?? ?? 49 8B CE E8 ?? ?? ?? ??",
      K_FIXED, 29, 2, {0x74, 0x08}, {0xEB, 0x08}, -1, 0x4dc57bb, 1 },
    { "NF2", "no own finish (construction callback)",
      "48 8B CB 4E 89 2C F0 E8 ?? ?? ?? ?? 84 C0 74 50 48 8B CB E8 ?? ?? ?? ?? EB 46",
      K_FIXED, 14, 2, {0x74, 0x50}, {0xEB, 0x50}, -1, 0x4cbdb0b, 1 },
    /* ---- lane 19 (JOBGATE): SMUnit::executeTask ("start this task", rva 4df9940) returns when the villager's job type
     * is in the engine's debug list disableJobIDs (+0x10A8 data, +0x10B0 count). "je list-empty" becomes "jmp": the
     * routine never looks at the list. The job chooser (4ddb130) keeps its own copy of the test (other registers, 74 17),
     * so with the list filled a friend's villagers choose nothing and a task given with setTask still starts.
     * Source: lanes\lane_s21_13\dis\gate_executeTask_bytes.txt; the pattern starts at "mov rcx,rdi; call getJobType". */
    { "JG", "given tasks start while the job list is full (executeTask)",
      "48 8B CF E8 ?? ?? ?? ?? 48 8B 93 A8 10 00 00 48 63 8B B0 10 00 00 4C 8D 04 8A 49 3B D0 74 11 39 02 0F 84",
      K_FIXED, 29, 2, {0x74, 0x11}, {0xEB, 0x11}, -1, 0x4df99e6, 1 },
    /* lanes\lane_w\report_W.txt answer 1: finishConstruction(SMBuildingMaster*), called by the builder's hammer
     * handler 4dc5270 and the async construction callback 4cbdb1e */
    { "FINISH", "finishConstruction entry",
      "48 8B C4 48 89 58 10 48 89 70 18 48 89 78 20 55 41 54 41 55 41 56 41 57 48 8D A8 08 FE FF FF 48 81 EC D0 02 00 00 44 0F 29 48 98",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d0b370, 1 },
    /* lanes/lane_f/report.txt Q3 (a): progressFire(SMBuildingMaster*, float dt). With a huge dt one call burns the
     * building down the game's own way. It does not test onFire itself: the caller must. */
    { "BURN", "progressFire entry",
      "48 8B C4 48 89 58 20 55 56 57 41 56 41 57 48 8D 68 B8 48 81 EC 20 01 00 00 F3 0F 10 05 ?? ?? ?? ??",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d49af0, 1 },
    /* lanes/lane_f/report.txt Q3 (b): extinguishFire(SMBuildingMaster*). Returns by itself when the building is not
     * burning; null-checks Region and owner. */
    { "FIREOUT", "extinguishFire entry",
      "48 89 5C 24 18 56 48 81 EC B0 00 00 00 48 8B D9 33 F6 48 8B 89 98 03 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d4a530, 1 },
    /* GOODS (lane 14, research/2026-11-10-game-probe/lanes/lane_s21_14/report.txt): the outcome switch for building
     * stock. Three function entries. The first two are hooked at their first instruction (5 bytes, one whole
     * instruction, replaced by a jump to a stub of this DLL); the third is only recognised.
     *   RECOUNT  SMBuildingMaster::recountStorage(building, bool, bool, void*): the game calls it after it changed a
     *            building's Inventory (42 call sites). Its pattern holds the offsets +470h, +478h, +448h and +450h
     *            (numStoredGeneric, numStoredPantry, Inventory and its length) and the step from one record to the
     *            next (24 bytes: "lea rcx,[rax+rax*2]; lea rsi,[rdi+rcx*8]"): a changed class or record layout
     *            makes it miss.
     *   REFRESH  Region::refreshBuildingStorageCache(region, building, mode, delta, bool): the region's copy of a
     *            building's stock (56 call sites; a few writers call only this one).
     *   ADDINV   SMBuildingMaster::addToInventory(building, FGood*): the routine behind the reflected function the
     *            mod writes stock with. Only the script layer calls it (one caller in the game file: its exec thunk),
     *            so a RECOUNT or REFRESH call that returns into it is the mod's own write. The DLL checks that its
     *            calls at +45h and +64h reach the RECOUNT and REFRESH hits (goods_check). */
    { "RECOUNT", "recountStorage entry (hooked by GOODS)",
      "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 41 56 41 57 48 83 EC 20 33 C0 48 8B D9 48 89 81 70 04 00 00 4D 8B F9 89 81 78 04 00 00 45 0F B6 F0 48 8B B9 48 04 00 00 0F B6 EA 48 63 81 50 04 00 00 48 8D 0C 40 48 8D 34 CF",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d18fc0, 1 },
    { "REFRESH", "refreshBuildingStorageCache entry (hooked by GOODS)",
      "48 89 5C 24 18 48 89 4C 24 08 55 56 57 41 54 41 55 41 56 41 57 48 8B EC 48 81 EC 80 00 00 00 49 8B F1 45 8B F0 4C 8B FA 4C 8B E1 48 85 D2 74 03 8B 42 08 48 8B 99 E0 01 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c49700, 1 },
    { "ADDINV", "addToInventory entry (the mod's own write)",
      "40 53 48 83 EC 50 44 8B 42 04 48 8B D9 8B 12 45 8B C8 41 C1 E9 1F 48 81 C1 48 04 00 00 E8 ?? ?? ?? ?? F2 0F 10 0D ?? ?? ?? ?? 4C 8D 4C 24 30 0F 57 C0 F2 0F 11 4C 24 40 41 B0 01 0F 29 44 24 30 33 D2 48 8B CB E8 ?? ?? ?? ?? 48 8B 8B C8 02 00 00 48 85 C9 74 13 45 33 C9 C6 44 24 20 00 45 33 C0 48 8B D3 E8 ?? ?? ?? ??",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d28410, 1 },
    /* TOTALS (lane 22, research/2026-11-10-game-probe/lanes/lane_s21_22/report.txt): the region's totals of goods (the
     * top bar; the list at region +528h that Region::getStockOfGood reads) change only on the host's word.
     *   ADDLIST  "add a list of goods to a list of goods" (list*, src*, bool negate, bool removeEmpty), 57 callers.
     *            Hooked at its first instruction (mov [rsp+20h],r9b: 5 bytes, no address in it): a call whose list is
     *            the totals of a region this DLL tracks is not run but applied to the DLL's shadow of those totals.
     *   NOTIFY   the region's "these goods changed" notice to the player's pawn (region, list*): the game calls it after
     *            each change of the totals; the DLL calls it after its own write. Holds +318h and the pawn's +5B0h.
     *   TS1-TS6  the only six places the game changes the totals (lane 14 6a; lane 22 refs528): each "lea rcx,[reg+528h]
     *            ... call ADDLIST". Never written: they pin the +528h offset and that the calls reach ADDLIST. */
    { "ADDLIST", "add a list of goods to a list (hooked by TOTALS)",
      "44 88 4C 24 20 53 56 57 48 83 EC 30 48 8B 32 48 8B F9 48 63 42 08 41 BB 01 00 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b73d00, 1 },
    { "NOTIFY", "the region's goods-changed notice",
      "48 89 7C 24 18 41 56 48 83 EC 20 48 8B 81 18 03 00 00 48 8B F9 4C 8B F2 48 8B 88 B0 05 00 00 48 85 C9",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c57ec0, 1 },
    /* (the site patterns start at the ModRM byte of "lea rcx,[reg+528h]": first byte pairs that are rare in code keep
     *  the one scan pass short; starting at the REX byte 48/49 made the pass about four times longer) */
    { "TS1", "totals: a building is added (call at 4c49638)",
      "8D 8B 28 05 00 00 E8 ?? ?? ?? ?? 48 8D 8B 38 05 00 00",
      K_SITE, 6, 0, {0}, {0}, S_ADDLIST, 0x4c49632, 1 },
    { "TS2", "totals: a building's refresh with a list (call at 4c49821)",
      "8C 24 28 05 00 00 45 33 C0 48 8B D6 E8 ?? ?? ?? ?? 48 8B D6 49 8B CC E8",
      K_SITE, 12, 0, {0}, {0}, S_ADDLIST, 0x4c49815, 1 },
    { "TS3", "totals: a building's refresh as it is (call at 4c498b9)",
      "8C 24 28 05 00 00 E8 ?? ?? ?? ?? 48 8D 55 E0 49 8B CC E8",
      K_SITE, 6, 0, {0}, {0}, S_ADDLIST, 0x4c498b3, 1 },
    { "TS4", "totals: a unit's refresh with a list (call at 4c49d29)",
      "8F 28 05 00 00 41 B1 01 45 33 C0 49 8B D6 E8 ?? ?? ?? ?? 41 B1 01",
      K_SITE, 14, 0, {0}, {0}, S_ADDLIST, 0x4c49d1b, 1 },
    { "TS5", "totals: a unit's refresh as it is (call at 4c4a086)",
      "8F 28 05 00 00 41 B1 01 45 33 C0 48 8D 55 8F E8 ?? ?? ?? ?? 48 8D 55 8F",
      K_SITE, 15, 0, {0}, {0}, S_ADDLIST, 0x4c4a077, 1 },
    { "TS6", "totals: a building is removed (call at 4c4a7f1)",
      "8D 28 05 00 00 45 0F B6 C1 48 8B D3 E8 ?? ?? ?? ?? 48 8D 53 10",
      K_SITE, 12, 0, {0}, {0}, S_ADDLIST, 0x4c4a7e5, 1 },
    /* lane 26: the store of the lord pawn's cached cursor point inside APawnCPP::updateCursor (4b75b90): the new point
     * minus the old one into +4C0/+4C8/+4D0, then the point itself into +4E8 (X, Y) and +4F8 (Z), all doubles. The
     * displacements are part of the pattern, so one hit proves this build keeps the point at +4E8. Readers of +4E8: the
     * road / wall tool's per-frame update (4b67950), getMouse3d (4b48da0). Used by CURSOR (never patched). */
    { "CURSOR", "updateCursor's store of the cursor point (+4E8)",
      "F2 41 0F 5C 86 E8 04 00 00 F2 0F 10 65 ?? 0F 28 DD F2 41 0F 5C 9E F0 04 00 00 0F 28 D4 F2 41 0F 5C 96 F8 04 00 00 F2 41 0F 11 86 C0 04 00 00 0F 28 C1 66 0F 14 C5 F2 41 0F 11 9E C8 04 00 00 F2 41 0F 11 96 D0 04 00 00 41 0F 11 86 E8 04 00 00 F2 41 0F 11 A6 F8 04 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b75da2, 1 },
    /* lane 26: the lord pawn's own mouse-button handlers, as SetupPlayerInputComponent (4b235a0) binds them to the
     * actions "LMB" and "RMB" (pressed / released). Each takes only the pawn (rcx) and reads the cached cursor point.
     * Used by INPUT (a click where CURSOR put the point; never patched). */
    { "LMBDOWN", "the pawn's LMB pressed handler",
      "40 55 53 48 8D AC 24 18 FF FF FF 48 81 EC E8 01 00 00 80 B9 58 0A 00 00 00 48 8B D9 0F 85 ?? ?? ?? ?? 48 8B 89 A0 05 00 00 E8",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b170f0, 1 },
    { "LMBUP", "the pawn's LMB released handler",
      "40 55 53 48 8B EC 48 83 EC 78 80 B9 58 0A 00 00 00 48 8B D9 0F 85 ?? ?? ?? ?? 80 B9 98 05 00 00 00 0F 10 81 90 04 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b17b60, 1 },
    { "RMBDOWN", "the pawn's RMB pressed handler",
      "40 55 48 8D 6C 24 A9 48 81 EC B0 00 00 00 80 B9 58 0A 00 00 00 0F 85 ?? ?? ?? ?? 0F 10 81 E8 04 00 00 33 C0 C6 81 04 09 00 00 01",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b1c3d0, 1 },
    { "RMBUP", "the pawn's RMB released handler (onRMBReleased: MoveSelected)",
      "4C 8B DC 55 57 49 8D 6B D8 48 81 EC 18 01 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 45 E0 80 B9 58 0A 00 00 00 48 8B F9 0F 85 ?? ?? ?? ??",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b1c510, 1 },
    /* ---- lane 23 (CHOOSE): the job chooser (rva 4ddb130) leaves without choosing when the villager's job type is in the
     * engine's job list (+0x10A8 data, +0x10B0 count). The villager is rdi there (set from rcx at 4ddb153, not written
     * again before 4ddb342). The 5 bytes at +22 ("lea r8,[rdx+rcx*4]" and the first byte of "cmp rdx,r8") become a jump
     * to this DLL's stub, which runs the lea, makes the list look empty (r8 = rdx) when rdi is one of the villagers the
     * mod named, runs the cmp and jumps back to the je at +29. The patch bytes are wildcards in the pattern so a site
     * already hooked is still found; chooser_check then reads them. Source: research\2026-11-10-game-probe\lanes\
     * lane_s21_23\report.txt part 2 and out\listrefs.txt. Pattern starts at the ModRM byte of "mov rcx,[rdi+318h]". */
    { "CHOOSE", "the job chooser's test of the job list (hooked by CHOOSE)",
      "8F 18 03 00 00 48 8B D8 48 8B 91 A8 10 00 00 48 63 89 B0 10 00 00 ?? ?? ?? ?? ?? 3B D0 74 17 0F 1F 44 00 00 44 39 3A 0F 84",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4ddb30c, 1 },

    /* lane 28 (research/2026-11-10-game-probe/lanes/lane_s21_28/report.txt): the routines the game itself draws a road or
     * wall with, and its army order routine. Function entries, never patched except MOVESEL, whose first instruction
     * (5 bytes, "mov [rsp+20h],rbx", no address in it) can be replaced by a jump to a stub of this DLL (ORDERHOOK).
     *   TOOLUPD    the road / wall tool's per-frame update (4b67950): builds the draft road from the pawn's roadPoints
     *              (+780h) and the cached cursor point (+4E8h); the pattern holds roadmode (+7A0h).
     *   ROADCLICK  the click of that tool (4b6a5f0): takes the point the update left as a road point; the pattern holds
     *              roadmode, the update's "cannot place" flag (+5FCh), the length of roadPoints (+788h) and the limit
     *              of 20 points.
     *   COMMITROAD PawnCPP::commitRoad (4b368c0): the draft becomes a road, or with wallMode a wall of the castle plan;
     *              the pattern holds roadmode and roadStarted (+7C0h).
     *   MOVESEL    Pawn::MoveSelected(pawn, bWaypoint, bNoArrows) (4b4f500): the order a right click gives the selected
     *              squads; the pattern holds selectedSquads (+550h).
     *   PATHPT     the routine the pawn's Tick runs while Ctrl and the right button are held (4b5f5c0): appends the
     *              cursor point to the pawn's path list (+CA8h, 88h bytes a point; both in the pattern).
     * The game's own AI lords draw roads with exactly these calls (4be8fe0: cursor point, TOOLUPD, ROADCLICK per point,
     * then COMMITROAD). */
    { "TOOLUPD", "the road / wall tool's per-frame update",
      "48 8B C4 55 57 48 8D A8 78 FE FF FF 48 81 EC 78 02 00 00 80 B9 A0 07 00 00 00 48 8B F9 0F 84 ?? ?? ?? ?? 48 89 58 E8 48 89 70 E0 4C 89 60 D8",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b67950, 1 },
    { "ROADCLICK", "the road / wall tool's click (add a road point)",
      "48 8B C4 48 89 58 20 55 48 8B EC 48 83 EC 70 80 B9 A0 07 00 00 00 48 8B D9 0F 84 ?? ?? ?? ?? 80 B9 FC 05 00 00 00 0F 85 ?? ?? ?? ?? 44 8B 89 88 07 00 00 41 83 F9 14",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b6a5f0, 1 },
    { "COMMITROAD", "PawnCPP::commitRoad entry",
      "40 55 53 56 57 41 57 48 8D AC 24 00 FF FF FF 48 81 EC 00 02 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 D0 00 00 00 80 B9 A0 07 00 00 00 48 8B F1 0F 84 ?? ?? ?? ?? 80 B9 C0 07 00 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b368c0, 1 },
    { "MOVESEL", "Pawn::MoveSelected entry (hooked by ORDERHOOK)",
      "48 89 5C 24 20 55 56 57 41 56 41 57 48 8D AC 24 E0 FE FF FF 48 81 EC 20 02 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 C0 00 00 00 48 8B 99 50 05 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b4f500, 1 },
    { "PATHPT", "the Ctrl + right-drag path routine (append the cursor point)",
      "48 89 5C 24 18 48 89 74 24 20 57 48 81 EC 30 01 00 00 48 8B F9 48 8D 99 A8 0C 00 00 48 63 4B 08 48 8B 03 48 8B F1 48 69 D1 88 00 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4b5f5c0, 1 },
    /* ---- lane 31 (HOLD, research/2026-11-10-game-probe/lanes/lane_s21_31/report.txt): on a friend's copy the numbers of
     * a region's panel change only on the host's word. Seven routines of the region are hooked at their entry (a whole
     * first instruction or two, 5 to 7 bytes, inside one aligned qword); for a region the mod has named they do not run:
     *   HAPPR   updateApproval (region): rebuilds summedApprovalFactors (+1038h) from the families' memories, writes
     *           Approval (+1030h); called by the day routine and setPolicySigned. Its body is checked (hold_check):
     *           +270h "mov [r14+1030h],64h", +55Dh "mov [r14+1030h],ecx", +31Ch the call of the list grow helper.
     *   HORDER  updatePublicOrder (region): appends to publicOrderMemory (+1050h), rebuilds summedPublicOrderFactors
     *           (+1060h), writes publicOrder (+104Ch, checked at +590h); called only by the day routine.
     *   HSUPPL  the months of food and fuel (region): supplies_food (+59Ch, checked at +281h) and supplies_wood (+5A0h,
     *           checked at +B20h); called by the day routine and BeginPlay.
     *   HWADD   addRegionalWealth (region, amount) (+648h in the pattern), HWSUB consumeRegionalWealth (region, amount),
     *           returns bool: when held it returns what the game would (settled and the wealth covers the amount).
     *   HPADD   add a problem (region, type, building, unit) to Region.problems (+D80h), returns bool (it was there);
     *           HPREM remove a problem (region, type, building, unit) (+D88h in the pattern).
     *   HWMON   the one store of regional wealth outside those two (the monthly income, 4c3d5f0): "mov [r15+648h],eax",
     *           replaced by a jump to a stub that stores unless the region is held. */
    { "HAPPR", "updateApproval entry (held by HOLD)",
      "40 55 53 57 41 56 48 8D AC 24 58 FF FF FF 48 81 EC A8 01 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 45 30 4C 8B F1 48 89 4C 24 50 48 8B 89 18 03 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c69770, 1 },
    { "HORDER", "updatePublicOrder entry (held by HOLD)",
      "48 8B C4 48 89 58 20 55 56 57 41 56 41 57 48 8D 68 A1 48 81 EC A0 00 00 00 0F 29 70 C8 4C 8B F1 48 8B 89 18 03 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c4fa40, 1 },
    { "HSUPPL", "months of food and fuel entry (held by HOLD)",
      "48 8B C4 55 53 56 57 41 55 48 8D A8 F8 FE FF FF 48 81 EC E0 01 00 00 44 0F 29 48 98 44 0F 29 A8 58 FF FF FF 44 0F 29 B0 48 FF FF FF",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c70030, 1 },
    { "HWADD", "addRegionalWealth entry (held by HOLD)",
      "80 B9 E8 02 00 00 00 74 2D 33 C0 03 91 48 06 00 00 0F 48 D0 48 8B 81 50 03 00 00 89 91 48 06 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c5a530, 1 },
    { "HWSUB", "consumeRegionalWealth entry (held by HOLD)",
      "40 55 57 48 83 EC 68 80 B9 E8 02 00 00 00 8B EA 48 8B F9 75 09 32 C0 48 83 C4 68 5F 5D C3 29 A9 48 06 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c5e170, 1 },
    { "HPADD", "add a region problem entry (held by HOLD)",
      "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 48 89 7C 24 20 41 54 41 56 41 57 48 83 EC 20 4C 8D A1 80 0D 00 00 0F B6 F2",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c37810, 1 },
    { "HPREM", "remove a region problem entry (held by HOLD)",
      "48 83 EC 28 4D 8B D9 45 33 D2 4C 63 89 88 0D 00 00 45 85 C9 0F 8E",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c691e0, 1 },
    /* (the pattern starts inside "cmp [r15+2E8h],dil" at its ModRM byte: rarer first bytes; the store is at +1Ch) */
    { "HWMON", "the monthly wealth store (mov [r15+648h],eax at 4c3d86b)",
      "BF E8 02 00 00 74 3C 83 FA FF 8B C7 0F 45 C3 41 03 87 48 06 00 00 41 03 C6 0F 48 C7 41 89 87 48 06 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c3d84f, 1 },
    /* remove every problem of one kind (region, kind): 6 callers (unassignFamily, finishConstruction, the unburied
     * routine 4d8b880 three times, 4c309c0); seen live moving a held friend's list (raid1, kind 47 Unburied) */
    { "HPRMALL", "remove all problems of a kind entry (held by HOLD)",
      "40 53 48 83 EC 20 48 89 6C 24 30 48 8D 99 80 0D 00 00 48 89 7C 24 40 48 8B E9 33 FF",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c69110, 1 },
    /* ---- lane 36 (research/2026-11-10-game-probe/lanes/lane_s21_36/report.txt): the region's daily emigration
     * (4c66e20, called only by the day routine after updateApproval and updatePublicOrder): a crime roll on public order
     * and, when GetMonthlyPopChange is below 0, on the days of the month it names a family picked with rand leaves
     * (SetFamilyHome none, removeWorkerFamilyAt). Each copy rolled its own family; held, a friend's copy lets nobody
     * leave by itself and removes the family the host names (the people module, V G X). */
    { "HEMIG", "the region's daily emigration entry (held by HOLD)",
      "48 8B C4 55 56 48 8D 68 A1 48 81 EC C8 00 00 00 48 83 B9 50 03 00 00 00 48 8B F1 0F 84 ?? ?? ?? ?? 83 B9 F0 04 00 00 00 0F 84",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c66e20, 1 },
    /* accomodateHomelessFamilies (region, ignoreBuilding): gives each homeless family a free house (SetFamilyHome); called
     * by BeginPlay, finishConstruction, BeginUpgrade, demolish, progressFire and 4ceaad0. Each copy housed its homeless at
     * its own moment (lane 36, g1: after a raid the friend housed a family 1 s before the host). Held, a friend's copy
     * houses nobody by itself; the host names every home (the people module, V G M). */
    { "HHOUSE", "accomodateHomelessFamilies entry (held by HOLD)",
      "48 8B C4 48 89 50 10 55 53 48 8D A8 B8 FE FF FF 48 81 EC 38 02 00 00 48 89 70 E8 48 89 78 E0 4C 89 60 D8 4C 89 68 D0 4C 8B E9",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c583e0, 1 },
    /* ---- lane 32 (research\2026-11-10-game-probe\lanes\lane_s21_32\report.txt item 1) ----
     *   UNCAMP     the squad lets go of its camp (4d72b60, (USquadComponent*, int handle), void): GetSquadMutable, then
     *              Squad.camp (+370h) = null, Squad.Control (+368h) = 0, and a call per unit (4dfb960). Its only caller
     *              is the enemy AI's executeArmyCommand (4c144d0), which "disableAI" stops on a friend's copy. The
     *              pattern holds both stores. */
    { "UNCAMP", "a squad lets go of its camp (Control 4 -> 0)",
      "40 56 48 83 EC 20 E8 ?? ?? ?? ?? 48 8B F0 48 85 C0 74 ?? 48 89 5C 24 30 48 C7 80 70 03 00 00 00 00 00 00 C6 80 68 03 00 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d72b60, 1 },
    /* ---- the lead, 2026-11-13 (research\2026-11-10-game-probe\lanes\lane_s21_0\crash_demolish_site\notes.txt) ----
     *   NOREGION   4c4a960 (UObject *region, list of goods), void: adds the goods to one of the world's counts for that
     *              region (the map at +A0h of the region's record).
     *   NOREGION2  4c4aa70, its twin: the same code for the other count (the map at +50h).
     * Each begins with GetWorld(region), which reads through the region. The routine for the goods of a work hit
     * (4db43c0) calls both with what the worked building's part at +2B8h returns, unchecked (4db49d7, 4db4ab2, 4db4d1c,
     * 4db4f21, 4db50ab, 4db5486), and that is null for a building taken out of the game: a friend's copy crashed at
     * 4db5486 twice (lane 36 run fin; the lead's run lead7), a villager's work hit at a building demolished a moment
     * before. The same routine checks the same value for null 0xC0 bytes later (4db5546). The four displacement bytes
     * of the first call (pattern offset 18) are wildcards, so a site already redirected is still found; the two
     * routines differ first in the displacement of the jump that follows (DA / D7), which the patterns hold. */
    { "NOREGION", "a count of goods for a region (map +A0h): its first call (redirected by NOREGION)",
      "48 89 5C 24 18 41 56 48 83 EC 20 4C 8B F2 48 8B D9 E8 ?? ?? ?? ?? 48 85 C0 0F 84 DA 00 00 00 48 8B C8 48 89 7C 24 38 E8 ?? ?? ?? ?? 48 8B F8 48 85 C0 0F 84 ?? ?? ?? ?? 48 8B 48 38 48 63 50 40 48 C1 E2 05",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c4a960, 1 },
    { "NOREGION2", "a count of goods for a region (map +50h): its first call (redirected by NOREGION)",
      "48 89 5C 24 18 41 56 48 83 EC 20 4C 8B F2 48 8B D9 E8 ?? ?? ?? ?? 48 85 C0 0F 84 D7 00 00 00 48 8B C8 48 89 7C 24 38 E8 ?? ?? ?? ?? 48 8B F8 48 85 C0 0F 84 ?? ?? ?? ?? 48 8B 48 38 48 63 50 40 48 C1 E2 05",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c4aa70, 1 },
    /* ---- lane 35 (PICK): the job chooser's pick held to the host's task type (research/2026-11-10-game-probe/lanes/
     * lane_s21_35/report.txt, item 1).
     *   SETTASK    SMUnit::setTask(unit, const FTask&) (4e1cab0): every task the game (or the mod, through the reflected
     *              setTask) gives a unit passes here. Its first two instructions (push rbx; sub rsp,120h: 9 bytes) are
     *              moved into a stub of this DLL that may hand the routine another record or return at once.
     *   CHOOSECALL the one call of the job chooser (4ddb130, CHOOSE's routine) in the unit's think (4e05aaa): the call is
     *              pointed at a stub of this DLL that notes which unit is choosing, calls the chooser, and clears the note.
     *              Pattern starts at "cmp byte [rdi+0AB0h],5" (4e05a94); the call is at +22. */
    { "SETTASK", "SMUnit::setTask entry (hooked by PICK)",
      "40 53 48 81 EC 20 01 00 00 83 B9 A0 08 00 00 00 48 8B D9 48 89 BC 24 38 01 00 00 48 8B FA 7E",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4e1cab0, 1 },
    { "CHOOSECALL", "the unit's think: its call of the job chooser (hooked by PICK)",
      "80 BF B0 0A 00 00 05 75 0A 48 8B CF E8 ?? ?? ?? ?? EB 08 48 8B CF E8 ?? ?? ?? ?? 84 C0 75 ?? 80 BF A8 08 00 00 02",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4e05a94, 1 },
    /* ---- lane 40 (FIELD): a field's plants on a friend's copy are the host's (research/2026-11-10-game-probe/lanes/
     * lane_s21_40/report.txt).
     *   FCACHE  SMBuildingMaster::UpdateFieldCache(field, ploughing, sowing, growing, harvesting) (4d217d0): the game
     *           calls it right after every change of a field's plants (the plough step, the sow and harvest of a work
     *           hit, the day's growth, eraseCrops). Its first three instructions (push rbx; push r13; sub rsp,38h: 8
     *           bytes, one aligned qword) are moved into a stub of this DLL that first puts the host's plants back.
     *           The pattern holds the plant list's length offset (+538h).
     *   FDRAW   the per-plant drawing routine (4d241b0, field, index): the instance of the plant's mesh from its crop
     *           and growth; the game's engine tick calls it for the plants of a field it marked (50 a tick). Called.
     *           The pattern holds +2E8h (engine) and the engine's +1098h.
     *   FPAINT  the engine's ploughed-ground brush (4c9def0, engine, place, amount, add): the plough step paints +0.5
     *           with add = 1, a harvest -10 with add = 0. Called. The pattern holds the engine's +628h (the target). */
    { "FCACHE", "UpdateFieldCache entry (hooked by FIELD)",
      "40 53 41 55 48 83 EC 38 0F 29 74 24 20 4C 8D 91 38 05 00 00 45 33 ED 4C 89 64 24 68 45 0F B6 E1 45 0F B6 D8 48 8B D9",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d217d0, 1 },
    { "FDRAW", "a plant's drawing routine entry (called by FIELD)",
      "4C 8B DC 55 57 41 56 49 8D AB F8 FE FF FF 48 81 EC F0 01 00 00 45 0F 29 AB 58 FF FF FF 45 0F 29 B3 48 FF FF FF 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 45 40 49 89 5B 18 4C 8B F1 49 89 73 20 33 F6 89 74 24 50 48 8B 81 E8 02 00 00 4D 89 63 E0 4D 89 7B D8 4C 63 FA 48 8B 98 98 10 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d241b0, 1 },
    { "FPAINT", "the ploughed-ground brush entry (called by FIELD)",
      "48 8B C4 48 89 68 18 48 89 70 20 41 56 48 83 EC 60 48 8B A9 28 06 00 00 45 0F B6 F1 44 0F 29 40 C8 44 0F 28 C2 48 8B F1",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c9def0, 1 },
    /* ---- lane 42 (DIST): a house's market goods (SMBuildingMaster.distributedGoods, +E90h) on the host's word
     * (research/2026-11-10-game-probe/lanes/lane_s21_42/report.txt).
     *   DISTCALL   the market routine of a region (4c485e0, run a slice per tick) calls the distribution (4c3c490) when a
     *              pass over the region's market list is done: "mov [rbp+1134h],1; jmp; mov rcx,r13; call; xor r14d,r14d;
     *              mov [rbp+8],r14d" (4c49210; the call at +15). Its only other caller is the load's synchronous run
     *              (4c485a0, from BeginPlay). DIST points this call at a stub of this DLL that calls the distribution and
     *              then writes back the lists the host named.
     *   DIST       the distribution (4c3c490, (region), void): dec [region+1130h]; per house of the region's market list
     *              the old list is moved out, the new one built from the region's pool, compared with the old one, and on a
     *              change +459h = 1, the region's refresh (mode 1) and the building's surplus cache (4d24b60) run.
     *   DGROW      the distribution's own "one record more" (4c3c90a): "add rbx,0E90h ... inc num; cmp max; jbe; mov edx,ebp;
     *              mov rcx,rbx; call <grow>" (the call at +68). The grow helper (4a62c30, (list, old num)) has four
     *              identical copies in the game file, so it is reached through this call and checked by its first bytes.
     *   DGSURP     the building's surplus cache (4d24b60, (building), void), which the distribution calls after a change. */
    { "DISTCALL", "the market routine's call of the distribution (redirected by DIST)",
      "C7 85 34 11 00 00 01 00 00 00 EB 0B 49 8B CD E8 ?? ?? ?? ?? 45 33 F6 44 89 75 08",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c49210, 1 },
    { "DIST", "the distribution of market goods to a region's houses (entry)",
      "48 8B C4 48 89 48 08 53 48 81 EC C0 00 00 00 FF 89 30 11 00 00 48 89 68 F0 48 8B E9",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c3c490, 1 },
    { "DGROW", "the distribution's own call of the list grow helper",
      "48 81 C3 90 0E 00 00 48 63 43 08 48 8B 13 48 8D 0C 40 48 8D 04 CA 48 3B D0 74 11 39 32 0F 84 ?? ?? ?? ?? 48 83 C2 18 48 3B D0 75 EF 85 FF 7E ?? 48 63 6B 08 8D 45 01 89 43 08 3B 43 0C 76 0A 8B D5 48 8B CB E8 ?? ?? ?? ??",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c3c90a, 1 },
    { "DGSURP", "a building's surplus cache (entry; the distribution calls it after a change)",
      "48 89 4C 24 08 57 41 55 41 56 48 83 EC 70 48 8D B9 60 04 00 00 4C 89 64 24 58 4C 8B E9 48 8D 91 48 04 00 00 48 8B CF E8",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d24b60, 1 },
    /* ---- lane 35, round six (REGSET): in the routine Engine::eraseBuildingReferences calls for a building's region
     * (4c53480), the two calls that take the building out of the region's sets +5A8h and +5F8h (both reach the game's
     * set removal 4c4bb90, which only hashes the key). Pattern starts at "mov rbx,[rsp+38h]" (4c535cb). */
    { "REGSETS", "a region's two building sets and the game's set removal (used by REGSET)",
      "48 8B 5C 24 38 48 8D 8F A8 05 00 00 48 8B D3 E8 ?? ?? ?? ?? 48 8D 8F F8 05 00 00 48 8B D3 E8 ?? ?? ?? ?? 48 39 9F 58 03 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c535cb, 1 },
    /* ---- lane 43 (MEN): a squad's man walks to the place the host's game gave its own man (research/2026-11-10-game-probe/
     * lanes/lane_s21_43/report.txt).
     *   MPATH  SMUnit's path request (4dbc910, "newAsyncPathRequest": man, point record by value, flag, list by value):
     *          every walk of a man starts here (14 callers: the squad AI's slot and attack places, the men's own actions).
     *          Its first five instructions (push rbp/rsi/rdi/r12/r14: 8 bytes, one aligned qword) are moved into a stub of
     *          this DLL. The pattern holds +E3Ch (its own early exit) and the moves of the four arguments.
     *   MSLOT  tickSquad's call of MPATH for each man of a squad (4d8850f; the E8 at +106 must reach MPATH): the record as
     *          the game builds it (the two rip-relative constants at +6 and +30 are what MEN's own GO copies). */
    { "MPATH", "SMUnit's path request entry (hooked by MEN)",
      "40 55 56 57 41 54 41 56 48 8D AC 24 50 FC FF FF 48 81 EC B0 04 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 E0 02 00 00 80 B9 3C 0E 00 00 00 4D 8B F1 45 0F B6 E0 48 8B F2 48 8B F9 74",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4dbc910, 1 },
    { "MSLOT", "tickSquad's call of the path request for each man (read by MEN)",
      "49 8B CF 0F 10 05 ?? ?? ?? ?? 48 89 55 38 48 89 55 40 0F 11 45 70 48 89 55 48 F2 0F 10 05 ?? ?? ?? ?? 48 89 55 50 88 55 58 48 89 55 60 48 89 55 68 66 89 95 94 00 00 00 88 95 96 00 00 00 89 95 98 00 00 00 48 8D 55 18 F2 0F 11 85 80 00 00 00 F2 0F 11 4D 30 C7 85 88 00 00 00 20 BC BE 4C 48 C7 85 8C 00 00 00 FF FF FF FF E8 ?? ?? ?? ??",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d8850f, 1 },
    /* ---- lane 35, round seven (PICK, the ox): the reflected setTask's call of SMUnit::setTask (4afd42d, in the exec
     * thunk 4afd350): a setTask whose return address is right after this call came through the reflected function (the
     * mod's job board); any other came from the game's own code. Pattern starts at "mov rax,[rbx+20h]" (4afd41b); the
     * call is at +18 and must reach SETTASK. */
    { "SETTHUNK", "the reflected setTask's call of SMUnit::setTask (used by PICK)",
      "48 8B 43 20 48 85 C0 40 0F 95 C7 48 03 F8 48 89 7B 20 E8 ?? ?? ?? ?? 4C 8D 9C 24 00 01 00 00 49 8B 5B 10 49 8B 73 18",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4afd41b, 1 },
    /* ---- lane 46 (GOODS): the demolish (4d32ef0) after it emptied the building into its refund pile: recountStorage(pile)
     * (just before), then refreshBuildingStorageCache(region, BUILDING) (E8 at +22, must reach REFRESH) and (region,
     * pile). A GOODS hook call returning right after the +22 call names a building being demolished (never given stock
     * back). Pattern starts at "test r12,r12" (4d34336). */
    { "DEMREF", "the demolish's refresh of the building it takes away (used by GOODS)",
      "4D 85 E4 74 35 45 33 C9 C6 44 24 20 00 45 33 C0 48 8B D7 49 8B CC E8 ?? ?? ?? ?? 45 33 C9 C6 44 24 20 00 45 33 C0 48 8B D3 49 8B CC E8",
      K_SITE, 22, 0, {0}, {0}, S_REFRESH, 0x4d34336, 1 },
    /* ---- lane 49 (GUIDE): the game's guide assignment (4e15ab0, ox rcx, villager rdx) from its entry to its first write,
     * "cmp rbx,[rdi+330h]; je; mov [rdi+330h],rbx": villager+330h = the ox it guides (not reflected). The DLL never
     * calls or patches it; it checks that both displacements (+64, +73) are still 330h and writes that field (GUIDE). */
    { "GUIDE", "the game's guide assignment: the villager's +330h is the ox it guides (used by GUIDE)",
      "48 89 5C 24 10 48 89 7C 24 18 55 48 8D 6C 24 B0 48 81 EC 50 01 00 00 48 8B FA 48 8B D9 48 8D 15 ?? ?? ?? ?? 48 8D 4C 24 20 E8 ?? ?? ?? ?? 48 8B 4C 24 20 48 85 C9 74 05 E8 ?? ?? ?? ?? 48 3B 9F 30 03 00 00 74 07 48 89 9F 30 03 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4e15ab0, 1 },
    /* ---- lane 53 (WALLSET, research/2026-11-10-game-probe/lanes/lane_s21_53/report.txt): a wall of the castle plan
     * changed after it was placed. The planner's per-frame update (4b30c90) and its press handler (4b170f0) change a
     * placed wall in one way only: they write the wall's control points (Road +318h) and call the wall's rebuild.
     *   WALLREB  the rebuild (4cd6430: road rcx, flag dl = 0): the spline is set from the control points, the gates
     *            are worked out again, the wall's pieces are spawned again. The pattern holds the spline (+2C0h) and
     *            the control points (+318h). Called by the drag (4B30FFA), by the alt-click that takes a point away
     *            (4B17657) and by the shift-click that adds one (4B176B5).
     *   WALLINS  the game's "insert a control point at this place of the wall" (4ccc3e0: road rcx, FVector* rdx;
     *            returns the index): what the shift-click and the click on a gate marker call. The pattern holds the
     *            length of the control point list (+320h). Used only to let the game itself lengthen the list. */
    { "WALLREB", "the rebuild of a wall from its control points (used by WALLSET)",
      "48 89 5C 24 10 48 89 74 24 18 55 57 41 56 48 8D 6C 24 B9 48 81 EC A0 00 00 00 44 0F B6 F2 48 8B F9 E8 ?? ?? ?? ?? 48 8B 8F C0 02 00 00 48 8D 97 18 03 00 00 41 B1 01 41 B8 01 00 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4cd6430, 1 },
    { "WALLINS", "the insert of a control point into a wall (used by WALLSET)",
      "40 55 41 57 48 83 EC 78 0F 10 02 4C 8B FA 48 8B E9 F2 0F 10 4A 10 48 8D 54 24 30 0F 29 44 24 30 0F 29 7C 24 50 F2 0F 11 4C 24 40 E8 ?? ?? ?? ?? 0F 28 F8 0F 2F 3D ?? ?? ?? ?? 73 0F 33 C0 0F 28 7C 24 50 48 83 C4 78 41 5F 5D C3 48 63 85 20 03 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4ccc3e0, 1 },
    /* ---- lane 52 (MEN, PACE): the squad's pace rule (4d8db70; squad component rcx, squad number edx; two callers in
     * the squad tick). It gives each man a speed factor: his way's length over the squad's mean, 0.5 to 3. From its
     * entry to where it reads the squad's men: both calls (+17, +71) reach the squad lookup (4d63100, returns the
     * squad record: its men at +18h, their count at +20h, both displacements in the pattern). Hooked at its entry by
     * MEN (5 bytes: three whole pushes); after it ran, a held man's factor is at least 1. */
    { "PACE", "the squad's pace rule entry (hooked by MEN)",
      "40 53 57 41 55 48 81 EC 80 00 00 00 8B DA 4C 8B E9 E8 ?? ?? ?? ?? 48 8B F8 48 85 C0 0F 84 ?? ?? ?? ?? 83 78 20 00 0F 84 ?? ?? ?? ?? 4C 89 B4 24 B0 00 00 00 8B D3 44 0F 29 5C 24 20 49 8B CD 48 89 B4 24 A8 00 00 00 E8 ?? ?? ?? ?? 45 33 F6 48 85 C0 74 0F 44 39 70 20 74 09 48 8B 40 18 48 8B 30 EB 03 49 8B F6 48 8B 4F 18 48 63 47 20",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d8db70, 1 },
    /* ---- lane 54 (FELL): the lookup of a tree being felled in its region's list (4c63c60, region rcx, place rdx) from
     * its entry to the read of a record's first double: "movsxd rax,[rcx+CD8h]" (the count), "mov rcx,[rcx+CD0h]" (the
     * records). The DLL never calls or patches it; it checks both displacements (+7, +42). */
    { "TREEFIND", "the lookup of a tree being felled: the region's list at +CD0h, a record's place first (used by FELL)",
      "48 83 EC 18 48 63 81 D8 0C 00 00 0F 29 34 24 85 C0 7E ?? F2 0F 10 1A 45 33 C0 F2 0F 10 62 08 F2 0F 10 6A 10 48 8B D0 48 8B 89 D0 0C 00 00 41 8B C0 F2 0F 10 35 ?? ?? ?? ?? 0F 1F 80 00 00 00 00 F2 0F 10 11",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c63c60, 1 },
    /* ---- lane 54 (FELL): a felling stroke in the work-hit routine (4dc5a97, inside 4dc5270): "lea rdx,[rdi+rdi*4]; mov
     * rax,[rax+CD0h]; movss xmm0,[rax+rdx*8+18h]; subss xmm0,[5.0]; movss [rax+rdx*8+18h],xmm0": a record is 28h bytes
     * and what is left of the tree is its float at +18h. Never called or patched: the list's displacement (+7) and
     * both +18h (+16, +30) are checked. Not a function entry (K_ENTRY here only means: exactly one hit). */
    { "FELLHIT", "a felling stroke: 5.0 off the tree record's float at +18h (used by FELL)",
      "48 8D 14 BF 48 8B 80 D0 0C 00 00 F3 0F 10 44 D0 18 F3 0F 5C 05 ?? ?? ?? ?? F3 0F 11 44 D0 18",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4dc5a97, 1 },
    /* ---- lane 49, round four (ENDHOLD): the game's end of a unit's tasks (4dfb960, unit rcx): its entry up to "mov
     * [rcx+890h],rax" (the task label cleared). The first 5 bytes are moved into a stub of this DLL by ENDHOLD ON. */
    { "ENDTASK", "the end of a unit's tasks (entry; hooked by ENDHOLD)",
      "4C 8B DC 55 56 49 8D 6B A1 48 81 EC B8 00 00 00 4D 89 6B D8 48 8B F1 45 33 ED C6 81 25 0D 00 00 00 41 8B C5 4C 89 6D 67 48 89 81 90 08 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4dfb960, 1 },

    /* ---- below: only checked by the offline tool (sigs5.txt lists them; the DLL does not use them) ---- */
    { "ALT-A", "arrows pass avoidKilling=1 (updateProj)",
      "41 BD 00 00 00 00 4D 85 F6 0F 84 ?? ?? ?? ?? F2 0F 10 4F 38 41 B1 01 F2 0F 10 47 40 4D 8B C6 F2 0F 5C 47 28 F2 0F 5C 4F 20 48 8B 97 88 00 00 00 49 8B CE 44 88 6C 24 28 F2 0F 59 C0 F2 0F 59 C9 F2 0F 58 C1 66 0F 51 C0 66 0F 5A C8 F3 0F 11 4C 24 20 E8 ?? ?? ?? ??",
      K_FIXED, 51, 5, {0x44, 0x88, 0x6C, 0x24, 0x28}, {0xC6, 0x44, 0x24, 0x28, 0x01}, -1, 0x4c6fa56, 0 },
    { "ALT-B", "melee passes avoidKilling=1 (performHit)",
      "49 39 B6 58 0E 00 00 74 0E 41 80 BE 79 08 00 00 12 0F 84 ?? ?? ?? ?? 0F 57 F6 40 88 74 24 28 45 33 C9 F3 0F 11 74 24 20 4C 8B C3 49 8B D6 49 8B CE E8 ?? ?? ?? ??",
      K_FIXED, 26, 5, {0x40, 0x88, 0x74, 0x24, 0x28}, {0xC6, 0x44, 0x24, 0x28, 0x01}, -1, 0x4dc729e, 0 },
    { "CombatHit", "CombatHit impl entry",
      "48 85 D2 0F 84 ?? ?? ?? ?? 4C 8B DC 55 56 41 54 41 55",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4dab7f0, 0 },
    { "recalc", "recalcStatsFromEquipment entry",
      "48 8B C4 55 57 48 8D 68 A1 48 81 EC 98 00 00 00 F3 0F 10 89 E0 0A 00 00",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4e27970, 0 },
    { "just_die", "just_die impl entry",
      "48 89 5C 24 10 48 89 74 24 18 48 89 7C 24 20 55 41 54 41 55 41 56 41 57 48 8B EC 48 81 EC 80 00 00 00 48 8B 05 ?? ?? ?? ??",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4e03010, 0 },
    { "updProjSite", "updateProj CombatHit site",
      "F2 0F 10 4F 38 41 B1 01 F2 0F 10 47 40 4D 8B C6",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4c6fa65, 0 },
    { "perfHitSite", "performHit CombatHit site",
      "0F 57 F6 40 88 74 24 28 45 33 C9 F3 0F 11 74 24 20",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4dc72b5, 0 },
    { "routCall", "calcMorale rout call",
      "8B D7 49 8B CF E8 ?? ?? ?? ?? E9 ?? ?? ?? ?? 8B D7",
      K_ENTRY, -1, 0, {0}, {0}, -1, 0x4d669d9, 0 },
};
#define SIG_COUNT ((int)(sizeof(SIGS) / sizeof(SIGS[0])))
typedef char SIG_COUNT_CHECK[(sizeof(SIGS) / sizeof(SIGS[0])) <= 128 ? 1 : -1];    /* scan_text's bucket has 128 bits (two words) */

/* ------------------------------------------------------------------ parsed patterns */
typedef struct {
    int     len;
    uint8_t b[2][SIG_MAX];      /* form 0 = original, form 1 = patched (patch bytes substituted) */
    uint8_t m[SIG_MAX];         /* 1 = fixed byte, 0 = wildcard */
    int     forms;              /* 1 for entries, 2 for patches */
} sig_pat;

typedef struct {
    int      hits;              /* total hits, both forms */
    uint32_t rva;               /* RVA of the first hit */
    int      form;              /* form of the first hit: 0 original, 1 patched */
} sig_hit;

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

/* returns 0 on success */
static int sig_parse(const sig_def *d, sig_pat *p)
{
    const char *s = d->pattern;
    memset(p, 0, sizeof(*p));
    while (*s) {
        if (*s == ' ') { s++; continue; }
        if (p->len >= SIG_MAX) return -1;
        if (s[0] == '?' && s[1] == '?') { p->m[p->len] = 0; p->len++; s += 2; continue; }
        if (hexval(s[0]) < 0 || hexval(s[1]) < 0) return -1;
        p->b[0][p->len] = (uint8_t)(hexval(s[0]) * 16 + hexval(s[1]));
        p->m[p->len] = 1; p->len++; s += 2;
    }
    if (p->len < 2 || !p->m[0] || !p->m[1]) return -1;     /* the scan anchors on the first two bytes */
    memcpy(p->b[1], p->b[0], (size_t)p->len);
    p->forms = 1;
    if (d->kind == K_FIXED || d->kind == K_CALL) {
        int i;
        if (d->patch_off < 2 || d->patch_off + d->patch_len > p->len) return -1;
        for (i = 0; i < d->patch_len; i++) {
            /* the patched form has the patched bytes fixed, even where the original form has a wildcard (K_CALL byte 1) */
            p->b[1][d->patch_off + i] = d->patched[i];
        }
        p->forms = 2;
    }
    return 0;
}

static int sig_match(const uint8_t *at, const sig_pat *p, const sig_def *d, int form)
{
    int i;
    for (i = 0; i < p->len; i++) {
        int fixed = p->m[i];
        if (form == 1 && (d->kind == K_FIXED || d->kind == K_CALL) && i >= d->patch_off && i < d->patch_off + d->patch_len) fixed = 1;
        if (fixed && at[i] != p->b[form][i]) return 0;
    }
    return 1;
}

/* One pass over .text for all signatures in [0, count). Signatures are bucketed by their first two bytes, so each
 * position costs one table lookup. Report 6 step 2: "the signature must have exactly ONE hit". */
static uint64_t g_bucket2[65536];   /* signatures 64 .. 127 (2026-11-13: lanes 40 and 42 took the count past 64) */
static uint64_t g_bucket[65536];    /* bit i = signature i starts with this byte pair (count <= 64; it was 32 until the
                                     * table grew past 32 entries: the offline tool then lost its last four) */

static void scan_text(const uint8_t *text, uint32_t text_rva, size_t text_len,
                      const sig_def *defs, const sig_pat *pats, int count, sig_hit *out)
{
    size_t i, maxlen = 0;
    int k;
    int w;
    memset(g_bucket, 0, sizeof(g_bucket)); memset(g_bucket2, 0, sizeof(g_bucket2));
    for (k = 0; k < count; k++) {
        out[k].hits = 0; out[k].rva = 0; out[k].form = -1;
        if (k >= 128) continue;         /* never reached: see SIG_COUNT_CHECK */
        (k < 64 ? g_bucket : g_bucket2)[pats[k].b[0][0] | (pats[k].b[0][1] << 8)] |= (uint64_t)1 << (k & 63);
        if ((size_t)pats[k].len > maxlen) maxlen = (size_t)pats[k].len;
    }
    if (text_len < 2) return;
    for (i = 0; i + 1 < text_len; i++) {
        for (w = 0; w < 2; w++) {
        uint64_t bits = (w ? g_bucket2 : g_bucket)[text[i] | (text[i + 1] << 8)];
        while (bits) {
            int s = 0, f;
            while (!(bits & ((uint64_t)1 << s))) s++;
            bits &= ~((uint64_t)1 << s);
            s += w * 64;
            if (i + (size_t)pats[s].len > text_len) continue;
            for (f = 0; f < pats[s].forms; f++) {
                if (sig_match(text + i, &pats[s], &defs[s], f)) {
                    if (out[s].hits == 0) { out[s].rva = text_rva + (uint32_t)i; out[s].form = f; }
                    out[s].hits++;
                    break;
                }
            }
        }
        }
    }
    (void)maxlen;
}

/* ------------------------------------------------------------------ evaluation of one patch site
 * Report 6 step 3: bytes at the patch offset equal ORIGINAL -> off; equal PATCHED -> on; else unavailable.
 * For K_CALL also: the call target (patch + 5 + rel32) must be the unique hit of the entry signature.
 * Report 6 step 4: the patch must lie inside one aligned 8-byte block. `addr` is the real address of the patch
 * (in memory) or its RVA (on disk: the image base is 64 KB aligned, so the qword alignment is the same). */
#define ST_UNAVAILABLE 0
#define ST_OFF         1
#define ST_ON          2

typedef struct {
    int      state;
    char     why[120];
    uint32_t patch_rva;
    uint8_t  orig[PATCH_MAX];       /* the bytes to write back for OFF */
    uint8_t  patched[PATCH_MAX];
    int      len;
} site_eval;

static void eval_site(const sig_def *d, const sig_hit *h, const sig_hit *hits_all, const uint8_t *patch_ptr,
                      uint64_t patch_addr, site_eval *e)
{
    int i;
    memset(e, 0, sizeof(*e));
    e->state = ST_UNAVAILABLE;
    e->len = d->patch_len;
    if (h->hits != 1) { snprintf(e->why, sizeof(e->why), "signature has %d hits (need exactly 1)", h->hits); return; }
    e->patch_rva = h->rva + (uint32_t)d->patch_off;
    if ((patch_addr & ~(uint64_t)7) != ((patch_addr + (uint64_t)d->patch_len - 1) & ~(uint64_t)7)) {
        snprintf(e->why, sizeof(e->why), "patch at rva %X crosses an 8-byte block", e->patch_rva);
        return;
    }
    memcpy(e->patched, d->patched, (size_t)d->patch_len);
    if (d->kind == K_FIXED) {
        memcpy(e->orig, d->orig, (size_t)d->patch_len);
    } else {    /* K_CALL */
        const sig_hit *t = &hits_all[d->call_target];
        int32_t want_rel;
        uint8_t wb[4];
        if (t->hits != 1) { snprintf(e->why, sizeof(e->why), "call target %s has %d hits", SIGS[d->call_target].name, t->hits); return; }
        want_rel = (int32_t)((int64_t)t->rva - ((int64_t)e->patch_rva + 5));
        memcpy(wb, &want_rel, 4);
        if (patch_ptr[0] == 0xE8) {
            int32_t rel; uint32_t target;
            memcpy(&rel, patch_ptr + 1, 4);
            target = (uint32_t)((int64_t)e->patch_rva + 5 + rel);
            if (target != t->rva) {
                snprintf(e->why, sizeof(e->why), "call goes to rva %X, not %s at %X", target, SIGS[d->call_target].name, t->rva);
                return;
            }
        } else if (patch_ptr[0] == 0xEB && patch_ptr[1] == 0x03) {
            /* already patched: bytes 2..4 of the call are untouched and must still be the high bytes of the rel32 */
            if (patch_ptr[2] != wb[1] || patch_ptr[3] != wb[2] || patch_ptr[4] != wb[3]) {
                snprintf(e->why, sizeof(e->why), "patched site's remaining call bytes do not lead to %s", SIGS[d->call_target].name);
                return;
            }
        }
        e->orig[0] = 0xE8; e->orig[1] = wb[0];
    }
    if (memcmp(patch_ptr, e->orig, (size_t)d->patch_len) == 0) { e->state = ST_OFF; return; }
    if (memcmp(patch_ptr, e->patched, (size_t)d->patch_len) == 0) { e->state = ST_ON; return; }
    {
        char hex[3 * PATCH_MAX + 1]; int n = 0;
        for (i = 0; i < d->patch_len; i++) n += snprintf(hex + n, sizeof(hex) - (size_t)n, "%02X", patch_ptr[i]);
        snprintf(e->why, sizeof(e->why), "unexpected bytes %s at rva %X", hex, e->patch_rva);
    }
}

/* ------------------------------------------------------------------ GOODS: what must hold before a hook is written
 * `at(rva)` gives the bytes at an RVA (in memory: base + rva; on disk: the .text buffer). Returns 1 when everything
 * holds, else 0 with a plain reason. */
#define GOODS_HOOK_LEN      5           /* bytes replaced at each hooked entry: its whole first instruction */
#define ADDINV_CALL_RECOUNT 0x45        /* addToInventory + 45h: call recountStorage   (returns to +4Ah) */
#define ADDINV_CALL_REFRESH 0x64        /* addToInventory + 64h: call refreshBuilding...(returns to +69h) */
static const uint8_t GOODS_ORIG_RECOUNT[GOODS_HOOK_LEN] = { 0x48, 0x89, 0x5C, 0x24, 0x08 };    /* mov [rsp+8],rbx  */
static const uint8_t GOODS_ORIG_REFRESH[GOODS_HOOK_LEN] = { 0x48, 0x89, 0x5C, 0x24, 0x18 };    /* mov [rsp+18h],rbx */

static int goods_call_target(const uint8_t *p, uint32_t rva, uint32_t *target)
{
    int32_t rel;
    if (p[0] != 0xE8) return 0;
    memcpy(&rel, p + 1, 4);
    *target = (uint32_t)((int64_t)rva + 5 + rel);
    return 1;
}

static int goods_check(const sig_hit *hits, const uint8_t *recount, const uint8_t *refresh, const uint8_t *addinv,
                       uint64_t recount_addr, uint64_t refresh_addr, char *why, size_t whylen)
{
    uint32_t t;
    if (hits[S_RECOUNT].hits != 1) { snprintf(why, whylen, "RECOUNT signature has %d hits (need exactly 1)", hits[S_RECOUNT].hits); return 0; }
    if (hits[S_REFRESH].hits != 1) { snprintf(why, whylen, "REFRESH signature has %d hits (need exactly 1)", hits[S_REFRESH].hits); return 0; }
    if (hits[S_ADDINV].hits != 1) { snprintf(why, whylen, "ADDINV signature has %d hits (need exactly 1)", hits[S_ADDINV].hits); return 0; }
    if (memcmp(recount, GOODS_ORIG_RECOUNT, GOODS_HOOK_LEN) != 0) { snprintf(why, whylen, "RECOUNT does not start with its known first instruction"); return 0; }
    if (memcmp(refresh, GOODS_ORIG_REFRESH, GOODS_HOOK_LEN) != 0) { snprintf(why, whylen, "REFRESH does not start with its known first instruction"); return 0; }
    if ((recount_addr & 7) + GOODS_HOOK_LEN > 8) { snprintf(why, whylen, "the RECOUNT hook would cross an 8-byte block"); return 0; }
    if ((refresh_addr & 7) + GOODS_HOOK_LEN > 8) { snprintf(why, whylen, "the REFRESH hook would cross an 8-byte block"); return 0; }
    if (!goods_call_target(addinv + ADDINV_CALL_RECOUNT, hits[S_ADDINV].rva + ADDINV_CALL_RECOUNT, &t) || t != hits[S_RECOUNT].rva) {
        snprintf(why, whylen, "ADDINV's first call does not reach RECOUNT"); return 0; }
    if (!goods_call_target(addinv + ADDINV_CALL_REFRESH, hits[S_ADDINV].rva + ADDINV_CALL_REFRESH, &t) || t != hits[S_REFRESH].rva) {
        snprintf(why, whylen, "ADDINV's second call does not reach REFRESH"); return 0; }
    why[0] = 0;
    return 1;
}

/* ------------------------------------------------------------------ TOTALS (lane 22): what must hold before the hook is written
 * `at(rva)` is replaced by the caller handing in a function that maps an RVA to its bytes (memory or file buffer). */
#define TOTALS_HOOK_LEN 5
#define TOTALS_OFF      0x528           /* Region: the totals list { FGood *data; int num; int max; } (in TS1-TS6) */
#define TOTALS_OFF_R    0x538           /* Region: the totals minus what is reserved (the same kind of list; in TS1) */
static const uint8_t TOTALS_ORIG_ADDLIST[TOTALS_HOOK_LEN] = { 0x44, 0x88, 0x4C, 0x24, 0x20 };   /* mov [rsp+20h],r9b */

typedef const uint8_t *(*rva_bytes_fn)(uint32_t rva, void *ctx);

static int totals_check(const sig_hit *hits, rva_bytes_fn at, void *ctx, uint64_t addlist_addr, char *why, size_t whylen)
{
    int k;
    uint32_t t;
    if (hits[S_ADDLIST].hits != 1) { snprintf(why, whylen, "ADDLIST signature has %d hits (need exactly 1)", hits[S_ADDLIST].hits); return 0; }
    if (hits[S_NOTIFY].hits != 1) { snprintf(why, whylen, "NOTIFY signature has %d hits (need exactly 1)", hits[S_NOTIFY].hits); return 0; }
    if (memcmp(at(hits[S_ADDLIST].rva, ctx), TOTALS_ORIG_ADDLIST, TOTALS_HOOK_LEN) != 0) { snprintf(why, whylen, "ADDLIST does not start with its known first instruction"); return 0; }
    if ((addlist_addr & 7) + TOTALS_HOOK_LEN > 8) { snprintf(why, whylen, "the ADDLIST hook would cross an 8-byte block"); return 0; }
    for (k = S_TS1; k < S_TS1 + TOTALS_SITES; k++) {
        uint32_t site;
        if (hits[k].hits != 1) { snprintf(why, whylen, "%s signature has %d hits (need exactly 1)", SIGS[k].name, hits[k].hits); return 0; }
        site = hits[k].rva + (uint32_t)SIGS[k].patch_off;
        if (!goods_call_target(at(site, ctx), site, &t) || t != hits[S_ADDLIST].rva) {
            snprintf(why, whylen, "%s's call does not reach ADDLIST", SIGS[k].name); return 0; }
    }
    why[0] = 0;
    return 1;
}

/* ------------------------------------------------------------------ CHOOSE (lane 23): what must hold before the hook is written */
#define CHOOSE_PATCH_OFF 22             /* the hooked bytes inside the CHOOSE pattern */
#define CHOOSE_HOOK_LEN  5
#define CHOOSE_RESUME    29             /* the je the stub returns to (pattern offset) */
static const uint8_t CHOOSE_ORIG[CHOOSE_HOOK_LEN] = { 0x4C, 0x8D, 0x04, 0x8A, 0x49 };    /* lea r8,[rdx+rcx*4]; (cmp rdx,r8) */

static int chooser_check(const sig_hit *hits, const uint8_t *site, uint64_t site_addr, char *why, size_t whylen)
{
    if (hits[S_CHOOSE].hits != 1) { snprintf(why, whylen, "CHOOSE signature has %d hits (need exactly 1)", hits[S_CHOOSE].hits); return 0; }
    if (memcmp(site + CHOOSE_PATCH_OFF, CHOOSE_ORIG, CHOOSE_HOOK_LEN) != 0) { snprintf(why, whylen, "the chooser's list test does not hold its known bytes (hooked before?)"); return 0; }
    if (((site_addr + CHOOSE_PATCH_OFF) & 7) + CHOOSE_HOOK_LEN > 8) { snprintf(why, whylen, "the CHOOSE hook would cross an 8-byte block"); return 0; }
    why[0] = 0;
    return 1;
}

/* ------------------------------------------------------------------ NOREGION (the lead, 2026-11-13): what must hold before
 * a call is redirected. sig = S_NOREGION or S_NOREGION2; site = the first byte of its pattern (the routine's entry).
 * *target = where the call goes now. */
#define NOREGION_SITES 2
#define NOREGION_CALL_OFF 17            /* the E8 of the routine's first call (GetWorld) inside the pattern */
static int noregion_check(const sig_hit *hits, int sig, const uint8_t *site, uint64_t site_addr, uint64_t img_addr, uint64_t img_size, uint64_t *target, char *why, size_t whylen)
{
    int32_t rel;
    if (hits[sig].hits != 1) { snprintf(why, whylen, "%s signature has %d hits (need exactly 1)", SIGS[sig].name, hits[sig].hits); return 0; }
    if (site[NOREGION_CALL_OFF] != 0xE8) { snprintf(why, whylen, "%s: the routine's first call is not a call", SIGS[sig].name); return 0; }
    memcpy(&rel, site + NOREGION_CALL_OFF + 1, 4);
    *target = site_addr + NOREGION_CALL_OFF + 5 + (uint64_t)(int64_t)rel;
    if (*target < img_addr || *target >= img_addr + img_size) { snprintf(why, whylen, "%s: the routine's first call does not go into the game (redirected before?)", SIGS[sig].name); return 0; }
    if (((site_addr + NOREGION_CALL_OFF + 1) & 7) + 4 > 8) { snprintf(why, whylen, "%s: the bytes would cross an 8-byte block", SIGS[sig].name); return 0; }
    why[0] = 0;
    return 1;
}

/* ------------------------------------------------------------------ HOLD (lane 31): what must hold before the hooks are written
 * Each gate replaces its whole first instruction(s) (HOLD_LEN bytes) with a jump; the entries are 16-byte aligned in
 * this build, and the check refuses any that would cross an aligned qword. The body checks pin the field offsets the
 * mod relies on. GROW is the list grow helper the DLL uses to lengthen an approval list (no signature of its own: its
 * bytes have 38 look-alikes), reached through updateApproval's own call at +31Ch and checked by its first bytes. */
static const int     HOLD_SIG[HOLD_GATES] = { S_HAPPR, S_HORDER, S_HSUPPL, S_HWADD, S_HWSUB, S_HPADD, S_HPREM, S_HPRMALL, S_HEMIG, S_HHOUSE };
static const char *const HOLD_NAME[HOLD_GATES] = { "approval", "order", "supplies", "wealthAdd", "wealthSub", "problemAdd", "problemRemove", "problemRemoveAll", "emigration", "housing" };
static const int     HOLD_LEN[HOLD_GATES] = { 6, 7, 5, 7, 7, 5, 7, 6, 5, 7 };
static const uint8_t HOLD_ORIG[HOLD_GATES][8] = {
    { 0x40, 0x55, 0x53, 0x57, 0x41, 0x56 },                 /* push rbp; push rbx; push rdi; push r14 */
    { 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x20 },           /* mov rax,rsp; mov [rax+20h],rbx */
    { 0x48, 0x8B, 0xC4, 0x55, 0x53 },                       /* mov rax,rsp; push rbp; push rbx */
    { 0x80, 0xB9, 0xE8, 0x02, 0x00, 0x00, 0x00 },           /* cmp byte ptr [rcx+2E8h],0 (flags live into the je after it) */
    { 0x40, 0x55, 0x57, 0x48, 0x83, 0xEC, 0x68 },           /* push rbp; push rdi; sub rsp,68h */
    { 0x48, 0x89, 0x5C, 0x24, 0x08 },                       /* mov [rsp+8],rbx */
    { 0x48, 0x83, 0xEC, 0x28, 0x4D, 0x8B, 0xD9 },           /* sub rsp,28h; mov r11,r9 */
    { 0x40, 0x53, 0x48, 0x83, 0xEC, 0x20 },                 /* push rbx; sub rsp,20h */
    { 0x48, 0x8B, 0xC4, 0x55, 0x56 },                       /* lane 36, HEMIG: mov rax,rsp; push rbp; push rsi */
    { 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x50, 0x10 } };         /* lane 36, HHOUSE: mov rax,rsp; mov [rax+10h],rdx */
#define HOLD_WMON_OFF  0x1C                                 /* the store inside the HWMON pattern */
#define HOLD_WMON_LEN  7
static const uint8_t HOLD_WMON_ORIG[HOLD_WMON_LEN] = { 0x41, 0x89, 0x87, 0x48, 0x06, 0x00, 0x00 };   /* mov [r15+648h],eax */
#define HOLD_GROW_CALL 0x31C
static const uint8_t HOLD_GROW_HEAD[28] = { 0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48, 0x83, 0xEC, 0x30,
                                            0x48, 0x63, 0x59, 0x08, 0x8B, 0xF2, 0x48, 0x8B, 0xF9, 0x3B, 0xDA, 0x0F, 0x8C };
typedef struct { int sig; uint32_t off; int len; uint8_t b[12]; } hold_body;
static const hold_body HOLD_BODY[] = {
    { S_HAPPR,  0x270, 11, { 0x41, 0xC7, 0x86, 0x30, 0x10, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00 } },   /* mov [r14+1030h],64h */
    { S_HAPPR,  0x55D, 7,  { 0x41, 0x89, 0x8E, 0x30, 0x10, 0x00, 0x00 } },                         /* mov [r14+1030h],ecx */
    { S_HORDER, 0x590, 7,  { 0x45, 0x89, 0xA6, 0x4C, 0x10, 0x00, 0x00 } },                         /* mov [r14+104Ch],r12d */
    { S_HSUPPL, 0x281, 9,  { 0xF3, 0x41, 0x0F, 0x11, 0x85, 0x9C, 0x05, 0x00, 0x00 } },             /* movss [r13+59Ch],xmm0 */
    { S_HSUPPL, 0xB20, 7,  { 0x41, 0xC7, 0x85, 0xA0, 0x05, 0x00, 0x00 } },                         /* mov dword [r13+5A0h],... */
};
#define HOLD_BODIES ((int)(sizeof(HOLD_BODY) / sizeof(HOLD_BODY[0])))

/* returns 1 when every gate, the store site and the grow helper hold; *grow_rva gets the helper's RVA */
static int hold_check(const sig_hit *hits, rva_bytes_fn at, void *ctx, uint32_t *grow_rva, char *why, size_t whylen)
{
    int k;
    uint32_t t, site;
    for (k = S_HAPPR; k <= S_HHOUSE; k++)
        if (hits[k].hits != 1) { snprintf(why, whylen, "%s signature has %d hits (need exactly 1)", SIGS[k].name, hits[k].hits); return 0; }
    for (k = 0; k < HOLD_GATES; k++) {
        uint32_t rva = hits[HOLD_SIG[k]].rva;
        if (memcmp(at(rva, ctx), HOLD_ORIG[k], (size_t)HOLD_LEN[k]) != 0) { snprintf(why, whylen, "%s does not start with its known first instruction", SIGS[HOLD_SIG[k]].name); return 0; }
        if ((rva & 7) + (uint32_t)HOLD_LEN[k] > 8) { snprintf(why, whylen, "the %s hook would cross an 8-byte block", SIGS[HOLD_SIG[k]].name); return 0; }
    }
    site = hits[S_HWMON].rva + HOLD_WMON_OFF;
    if (memcmp(at(site, ctx), HOLD_WMON_ORIG, HOLD_WMON_LEN) != 0) { snprintf(why, whylen, "HWMON's store is not the known one"); return 0; }
    if ((site & 7) + 5 > 8) { snprintf(why, whylen, "the HWMON jump would cross an 8-byte block"); return 0; }
    for (k = 0; k < HOLD_BODIES; k++)
        if (memcmp(at(hits[HOLD_BODY[k].sig].rva + HOLD_BODY[k].off, ctx), HOLD_BODY[k].b, (size_t)HOLD_BODY[k].len) != 0) {
            snprintf(why, whylen, "%s +%Xh is not the known store", SIGS[HOLD_BODY[k].sig].name, HOLD_BODY[k].off); return 0; }
    site = hits[S_HAPPR].rva + HOLD_GROW_CALL;
    if (!goods_call_target(at(site, ctx), site, &t)) { snprintf(why, whylen, "HAPPR +%Xh is not a call", HOLD_GROW_CALL); return 0; }
    if (memcmp(at(t, ctx), HOLD_GROW_HEAD, sizeof(HOLD_GROW_HEAD)) != 0) { snprintf(why, whylen, "the list grow helper at rva %X is not the known one", t); return 0; }
    *grow_rva = t;
    why[0] = 0;
    return 1;
}

/* ------------------------------------------------------------------ PICK (lane 35): what must hold before the hooks are written */
#define PICK_SET_LEN    9               /* setTask's first two instructions, moved into the stub */
#define PICK_HOOK_LEN   5
#define PICK_CALL_OFF   22              /* the chooser's call inside the CHOOSECALL pattern */
#define PICK_CHOOSER_SITE 0x1DC         /* CHOOSE's pattern lies this far into the chooser routine */
static const uint8_t PICK_SET_ORIG[PICK_SET_LEN] = { 0x40, 0x53, 0x48, 0x81, 0xEC, 0x20, 0x01, 0x00, 0x00 };   /* push rbx; sub rsp,120h */
static const uint8_t PICK_CHOOSER_HEAD[8] = { 0x48, 0x89, 0x5C, 0x24, 0x18, 0x55, 0x56, 0x57 };              /* mov [rsp+18h],rbx; push rbp rsi rdi */

/* the call at CHOOSECALL + 22 must be an E8 whose target is the routine that holds CHOOSE's pattern (at +1DCh) and that
 * starts with the chooser's known bytes; both hooked places must not cross an 8-byte block */
static int pick_check(const sig_hit *hits, const uint8_t *settask, uint64_t settask_addr, const uint8_t *callsite, uint64_t call_addr,
                      uint64_t choose_addr, const uint8_t *chooser, char *why, size_t whylen)
{
    int32_t rel;
    if (hits[S_SETTASK].hits != 1) { snprintf(why, whylen, "SETTASK signature has %d hits (need exactly 1)", hits[S_SETTASK].hits); return 0; }
    if (hits[S_CHOOSECALL].hits != 1) { snprintf(why, whylen, "CHOOSECALL signature has %d hits (need exactly 1)", hits[S_CHOOSECALL].hits); return 0; }
    if (hits[S_CHOOSE].hits != 1) { snprintf(why, whylen, "CHOOSE signature has %d hits (need exactly 1)", hits[S_CHOOSE].hits); return 0; }
    if (memcmp(settask, PICK_SET_ORIG, PICK_SET_LEN) != 0) { snprintf(why, whylen, "SETTASK does not start with its known instructions"); return 0; }
    if ((settask_addr & 7) + PICK_HOOK_LEN > 8) { snprintf(why, whylen, "the SETTASK hook would cross an 8-byte block"); return 0; }
    if (callsite[PICK_CALL_OFF] != 0xE8) { snprintf(why, whylen, "CHOOSECALL holds no call where the chooser's call was"); return 0; }
    if (((call_addr + PICK_CALL_OFF) & 7) + PICK_HOOK_LEN > 8) { snprintf(why, whylen, "the CHOOSECALL hook would cross an 8-byte block"); return 0; }
    memcpy(&rel, callsite + PICK_CALL_OFF + 1, 4);
    if (call_addr + PICK_CALL_OFF + 5 + (int64_t)rel != choose_addr - PICK_CHOOSER_SITE) { snprintf(why, whylen, "CHOOSECALL's call does not reach the chooser"); return 0; }
    if (memcmp(chooser, PICK_CHOOSER_HEAD, sizeof(PICK_CHOOSER_HEAD)) != 0) { snprintf(why, whylen, "the chooser does not start with its known instructions"); return 0; }
    why[0] = 0;
    return 1;
}

/* ------------------------------------------------------------------ DIST (lane 42): what must hold before the call is redirected
 * The call at DISTCALL + 15 must be an E8 that reaches DIST's entry; its four displacement bytes must lie inside one aligned
 * 8-byte block; the call at DGROW + 68 must be an E8 whose target lies in the image and starts with the grow helper's
 * known first 26 bytes. *grow = that target. */
#define DIST_CALL_OFF   15
#define DGROW_CALL_OFF  68
static const uint8_t DGROW_HEAD[26] = { 0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48, 0x83, 0xEC, 0x30,
                                        0x48, 0x63, 0x59, 0x08, 0x8B, 0xF2, 0x48, 0x8B, 0xF9, 0x3B, 0xDA };
static int dist_check(const sig_hit *hits, const uint8_t *callsite, uint64_t call_addr, uint64_t dist_addr, const uint8_t *growsite, uint64_t grow_site_addr,
                      uint64_t img_addr, uint64_t img_size, uint64_t *grow, char *why, size_t whylen)
{
    static const int need[5] = { S_DISTCALL, S_DIST, S_DGROW, S_DGSURP, S_REFRESH };
    int32_t rel;
    int k;
    for (k = 0; k < 5; k++)
        if (hits[need[k]].hits != 1) { snprintf(why, whylen, "%s signature has %d hits (need exactly 1)", SIGS[need[k]].name, hits[need[k]].hits); return 0; }
    if (callsite[DIST_CALL_OFF] != 0xE8) { snprintf(why, whylen, "DISTCALL holds no call where the distribution's call was"); return 0; }
    memcpy(&rel, callsite + DIST_CALL_OFF + 1, 4);
    if (call_addr + DIST_CALL_OFF + 5 + (uint64_t)(int64_t)rel != dist_addr) { snprintf(why, whylen, "DISTCALL's call does not reach the distribution (redirected before?)"); return 0; }
    if (((call_addr + DIST_CALL_OFF + 1) & 7) + 4 > 8) { snprintf(why, whylen, "DISTCALL: the bytes would cross an 8-byte block"); return 0; }
    if (growsite[DGROW_CALL_OFF] != 0xE8) { snprintf(why, whylen, "DGROW holds no call where the grow helper's call was"); return 0; }
    memcpy(&rel, growsite + DGROW_CALL_OFF + 1, 4);
    *grow = grow_site_addr + DGROW_CALL_OFF + 5 + (uint64_t)(int64_t)rel;
    if (*grow < img_addr || *grow + sizeof(DGROW_HEAD) > img_addr + img_size) { snprintf(why, whylen, "DGROW's call does not go into the game"); return 0; }
    why[0] = 0;
    return 1;
}

/* ------------------------------------------------------------------ REGSET (lane 35, round six) */
static const uint8_t REGSET_RM_HEAD[16] = { 0x48, 0x83, 0xEC, 0x28, 0x8B, 0x41, 0x08, 0x4C, 0x8B, 0xDA, 0x4C, 0x8B, 0xD1, 0x3B, 0x41, 0x34 };
/* the two calls (E8 at +15 and +30 of the pattern): their targets, for the DLL to compare */
static int regset_check(const uint8_t *p, uint64_t addr, uint64_t *t1, uint64_t *t2, char *why, size_t whylen)
{
    int32_t r1, r2;
    if (p[15] != 0xE8 || p[30] != 0xE8) { snprintf(why, whylen, "REGSETS holds no calls where the set removals were"); return 0; }
    memcpy(&r1, p + 16, 4); memcpy(&r2, p + 31, 4);
    *t1 = addr + 20 + (int64_t)r1; *t2 = addr + 35 + (int64_t)r2;
    why[0] = 0;
    return 1;
}

#endif
