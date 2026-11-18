# coop_patch: no own kills, no own routs on a friend's copy

In co-op every player runs the game, and the host decides every death and every rout. A friend's copy must not kill
or rout on its own. `coop_patch.dll` switches that off with tiny, reversible code patches, in memory only (the game
file is never changed). It also lets the mod replay the host's routs and reforms with the game's own functions.
Since lane 14 it can also hold the stock of a friend's buildings at what the host last said (GOODS, below): that
one is two hooked function entries, not a byte patch.

| Item | Command | What changes in the running game | Source |
|---|---|---|---|
| P1 | `NOKILL ON/OFF` | CombatHit's death check `74 1C` becomes `66 90`: a hit that would kill sets health to 1.0 instead | report answer 4 (b) |
| P2 | `NOROUT ON/OFF` | calculateMorale's call to TriggerSquadRetreat `E8 FD` becomes `EB 03` (jumps over the call) | report answer 5 |
| P3a + P3b | `NOREFORM ON/OFF` | the two calls to reformSquad are jumped over the same way (both or neither) | report answer 5 (optional) |
| ROUT | `ROUT <comp> <h>` | calls TriggerSquadRetreat(SquadComponent, squad) right there, on the game thread | report answer 5 |
| REFORM | `REFORM <comp> <h>` | calls reformSquad(SquadComponent, squad) | native4 section 2 |
| FINISH | `FINISH <building>` | calls finishConstruction(SMBuildingMaster) at RVA 4d0b370: the game's own "site complete" routine | lane_w report_W answer 1 |
| NF1 + NF2 | `NOFINISH ON/OFF` | the game's two own calls of finishConstruction are jumped over (`74` becomes `EB`; both or neither) | session 20 |
| NT | `NOTHEFT ON/OFF` | the bandits' daily theft routine (4d64460) calls the squad walk that robs the nearest region for every encamped bandit squad; that call (4d646d8) becomes `EB 03` (jumped over), so a friend's copy never rolls a theft; the host's theft is told by the events module | lane 66 |
| BURN, FIREOUT | `BURN <building>`, `FIREOUT <building>` | call progressFire(building, 1e6) and extinguishFire(building) | lane_f Q3 |
| GOODS | `GOODS ON [lord]/OFF` | the first instruction (5 bytes) of recountStorage (4d18fc0) and of the region's refreshBuildingStorageCache (4c49700) becomes a jump to a stub of this DLL: the game's own changes of a building's stock are put back; the mod's own write stays | lane 14 report |
| CURSOR | `CURSOR <pawn> <x> <y> <z>`, `CURSOR <pawn> GET` | writes (or logs) the lord pawn's cached cursor point, three doubles at +4E8; the game rewrites it only while the OS pointer is over its window (updateCursor 4b75b90). Needs the CURSOR signature once and the known build | lane 26 report part 3 |
| INPUT | `INPUT <pawn> LMBDOWN\|LMBUP\|RMBDOWN\|RMBUP` | runs the pawn's own mouse-button handler (4b170f0, 4b17b60, 4b1c3d0, 4b1c510: what the input component binds to "LMB" / "RMB"), which acts at the cached cursor point. Same guards | lane 26 report part 3 |
| DRAW | `WALL <token> <pawn> <flags> <x,y,z\|...>`, `TOOL <pawn>`, `WALLGET <token> <road>` | runs the game's own road / wall tool for a pawn: per point the cursor point, the tool's update (4b67950) and its click (4b6a5f0), then (flag 1) commitRoad (4b368c0); reads a wall's control points (+318h) and gate records (+498h). Nothing is patched | lane 28 report |
| ORDER, PATH | `ORDERAT <token> <pawn> <x,y,z> <wp> <noArrows>`, `PATH <token> <pawn> <noArrows> <x,y,z\|...>`, `PATHGET <token> <pawn>`, `PATHPT <pawn>` | calls the game's order routine MoveSelected (4b4f500) for the pawn's selected squads at a point (with the pawn's hover fields set by the caller: an order against a building), or with the path list built by the game's own press handler and path routine (4b5f5c0): the path order | lane 28 report |
| ORDERHOOK | `ORDERHOOK ON/OFF` | the first instruction (5 bytes) of MoveSelected becomes a jump to a stub of this DLL that notes each call the game makes itself; the next tick appends one line per call to `patch_events.txt` | lane 28 report |
| PILEGONE | `PILEGONE <building>` | empties a pile (building type 58h) and calls recountStorage the way the game's carriers do, which removes an empty pile | lane 14 report |
| TOTALS | `TOTALS ON/OFF/FORGET/AUDIT/DUMP`, `TOTALS SET <region> <good>=<amount>,...` | the first instruction (5 bytes) of "add a list of goods to a list" (4b73d00) becomes a jump to a stub of this DLL: a change of the totals list (region +528h, the top bar) of a region the mod has written is kept in the DLL's shadow instead of the list; SET writes the host's totals with the game's own routine; OFF writes the shadow back | lane 22 report |
| HOLD | `HOLD ON/OFF/FORGET/DUMP`, `HOLD SET <region>`, `HOLD ROWS <region> A\|O\|M <rows>`, `HOLD PROB <region> <problems>` | the whole first instruction(s) (5 to 7 bytes) of eight region routines (updateApproval 4c69770, updatePublicOrder 4c4fa40, the months of food and fuel 4c70030, addRegionalWealth 4c5a530, consumeRegionalWealth 4c5e170, add a problem 4c37810, remove a problem 4c691e0, remove all problems of a kind 4c69110) and the monthly wealth store at 4c3d86b become jumps to stubs of this DLL: for a region the mod has named they do not run; ROWS writes a whole approval list (grown with the game's own helper), PROB sets the problem list with the game's own add and remove; OFF rebuilds approval once with the game's own routine | lane 31 report |

Report = `research\2026-11-10-game-probe\registry\native5\report.txt`; signatures from `sigs5.txt` and
`native4_sigs.txt`. GOODS and PILEGONE: `research\2026-11-10-game-probe\lanes\lane_s21_14\report.txt` and the section
"GOODS" below.

## How it gets in

The mod's Lua does `package.loadlib(path, "coop_patch_tick")` and calls the result once per frame on the game thread.
The function has the Lua C function shape `int coop_patch_tick(void *L)`, never touches `L`, and always returns 0.
All input and output go through files.

## Files

The folder is the DLL's own folder. A line `dir=<folder>` in `coop_patch.cfg` beside the DLL overrides it.
Relative folders are taken from the DLL's folder, and `%VARS%` are expanded.

**One addition to the brief:** when the environment variable `COOP_NAME` is set, the folder gets a subfolder
`<COOP_NAME>\`. If only `COOP_ROLE` is set, the subfolder is `<COOP_ROLE>\` instead.
- **Why:** two copies of the game on one PC share the mod folder. Without this, each copy would read the other's
  commands. The host would then run the friend's `NOKILL ON`, and could receive a `ROUT` with an address from the
  other process.
- `coop_patch.lua` and the probes use the same rule.
- Without either variable (normal play, one copy per PC) nothing changes.

| File | Who writes | Format |
|---|---|---|
| `patch_cmd.txt` | the mod (appends) | one command per line (case does not matter; CR LF or LF) |
| `patch_status.txt` | the DLL | rewritten atomically (temp file, then `MoveFileEx` replace) on every change and on `STATUS` |
| `coop_patch.log` | the DLL | one line per event with a local timestamp; above 256 KB it becomes `coop_patch.log.old` |

**Commands:** `NOKILL ON|OFF`, `NOROUT ON|OFF`, `NOREFORM ON|OFF`, `NOFINISH ON|OFF`, `NOTHEFT ON|OFF`, `ROUT <address> <handle>`,
`REFORM <address> <handle>`, `FINISH <address>`, `BURN <address>`, `FIREOUT <address>`,
`GOODS ON [address of the player's lord]`, `GOODS OFF`, `GOODS AUDIT`, `GOODS STATS`, `PILEGONE <address>`,
`TOTALS ON|OFF|FORGET|AUDIT|DUMP`, `TOTALS SET|SETR <region> <good>=<amount>,... [ALL]` (or `-` for none), `ALLOFF`,
`STATUS`. A command line may be up to 4096 bytes.

- Addresses are decimal or `0x` hex.
  - ROUT and REFORM take the SquadComponent, from `S.sc:GetAddress()`.
  - FINISH takes the SMBuildingMaster, from `building:GetAddress()`.
- The handle is the squad number on *this* copy, as a 32-bit integer.

**Tailing:** the DLL reads the file by byte offset. It only consumes complete lines; a line still missing its
newline waits for the next tick. If the file shrank, the DLL reads again from 0. On the first tick it starts at the
current end of the file, so lines left from an earlier game run are skipped: an old `ROUT` would carry a dead
address. The log says how many bytes were skipped.

**Status file**, example from a test run:
```
ready 6836C1BA 9DFD000          <- or: off <plain reason>
P1 off                          <- on | off | unavailable <reason>
P2 off
P3a off
P3b off
ROUT available                  <- or: unavailable <reason>
REFORM available
FINISH available
calls rout=0 reform=0 finish=0 burn=0 fireout=0 failed=0
GOODS off                       <- on | off | unavailable <reason>
goods frozen=0 calls=0 own=0 putback=0 units=0 appended=0 dropped=0 deferred=0 fixed=0 unfixable=0 autoreg=0 stale=0 toobig=0 otherthread=0 nodelta=0 faults=0 audits=0 leaks=0 leakunits=0 pilegone=0
process 12345 version 0.3-goods <- extra line: which process wrote it
```
(The example leaves out the lines `NF1`, `NF2`, `BURN`, `FIREOUT`, which have the same forms as `P1` and `FINISH`.)
- The `goods` line: `frozen` buildings remembered; `calls` hooked calls seen; `own` of them the mod's or this DLL's
  own (the host's word); `putback` / `units` how often and by how much the game's own change was undone; `appended`
  / `dropped` records put back or cut off inside a hook; `deferred` / `fixed` / `unfixable` repairs left for the tick;
  `autoreg` buildings of the lord taken in by themselves; `stale` remembered addresses that held another object;
  `otherthread` calls from another thread (passed through); `nodelta` refreshes whose "what changed" list was
  dropped; `faults` exceptions in a hook; `audits` / `leaks` / `leakunits` what `GOODS AUDIT` found.
- `rout`, `reform` and `finish` count calls that ran.
- `failed` counts ROUT/REFORM/FINISH commands that were refused or that raised an exception.
- `ready` shows the PE TimeDateStamp and SizeOfImage of the running game.

## Safety rules, as built

1. **First tick.** The DLL pins itself (`GetModuleHandleExW` with `PIN`). It parses the main module's PE headers in
   memory, checks that `.text` is committed and readable, and records the TimeDateStamp and SizeOfImage. On another
   build it still scans and logs the difference: the signatures are the guard.
2. **Signatures.** One pass over `.text` only.
   - Each patch signature is matched in two forms, original and already patched. It needs exactly one hit in total.
     The bytes at the patch offset must be the original bytes (state `off`) or the patched bytes (state `on`).
   - For P2/P3, the `E8` call target is decoded and must equal the unique hit of TriggerSquadRetreat or reformSquad.
     For a site found already patched, the three untouched rel32 bytes must still point at that function, and the
     original low byte is rebuilt from it.
   - Anything else makes the item `unavailable <reason>`, and nothing is ever written for it.
   - On/off is always read from the bytes in memory, never from a remembered flag.
3. **Writing.** Each write goes through `write_bytes` in `coop_patch.c`:
   - The patch must lie inside one aligned 8-byte block, checked on the real address; otherwise it is refused.
   - Read the block. `VirtualProtect` it to `PAGE_EXECUTE_READWRITE`, do one `InterlockedCompareExchange64` against
     the block as read, then restore the protection and call `FlushInstructionCache`.
   - Read back. A failed exchange re-reads the block and reports it.
   - OFF writes the original bytes the same way.
4. **ROUT/REFORM/FINISH.** These need the unique entry hit and exactly two arguments (FINISH: exactly one).
   - The address must be non-null and 8-aligned, with committed readable memory (`VirtualQuery`): 0x100 bytes for
     the SquadComponent, 0x1500 bytes for a building (finishConstruction reads fields up to +0x14C4).
   - **Added:** the object's first qword (its C++ vtable) must lie inside the game module. This refuses stale or
     foreign addresses.
   - The handle must fit int32 and must not be 0 (0 is the invalid squad).
   - The call runs inside `__try/__except`. An exception marks that call type `unavailable` and is logged.
   - **Choice:** an exception in a game call does *not* count toward the 3 internal failures. It is counted in
     `failed=`, and that call type stays off.
5. **Nothing escapes.** `coop_patch_tick` runs everything under `__try/__except`. Each command is marked as
   consumed before it runs, so a command that raises is never read again.
   - Internal failures are an exception in the tick, a failed compare-exchange, or a failed read-back.
   - After 3 internal failures the DLL goes `off 3 internal failures` and puts every patched byte back. While off it
     only answers `STATUS`.
6. **Unload.** `DllMain` only calls `DisableThreadLibraryCalls`; nothing happens on `DLL_PROCESS_DETACH`.
7. **GOODS: two hooks instead of byte patches.** Everything above holds for them too (found by signature, exactly
   one hit, in memory only, written through `write_bytes` inside one aligned 8-byte block, read back, state taken
   from the bytes), with these additions:
   - The 5 bytes replaced at each entry are one whole instruction with no address in it (`mov [rsp+8],rbx` and
     `mov [rsp+18h],rbx`); the scan refuses an entry that does not start with exactly those bytes.
   - The third signature (addToInventory) must hold too, and its two calls must reach the two hooked entries.
   - The stubs live in one page this DLL allocates within reach of a 32-bit jump from the game module (the first
     free 64 KB block below it, else above it), written once and then made `PAGE_EXECUTE_READ`. It is never freed.
   - A stub saves `rcx rdx r8 r9`, calls the hook (a C function of this DLL), restores the four, runs the replaced
     instruction and jumps to entry + 5. The hook may change only the saved `r9` (see "nodelta").
   - Both entries or neither. `GOODS OFF`, `ALLOFF`, going `off` and three internal failures write the original
     5 bytes back.
   - Every hook runs under `__try`. An exception switches both hooks to pass-through at once and takes them out at
     the next tick; the item then reads `GOODS unavailable exception ... in a hook` for the rest of the session.
   - A call from another thread than the one that ticks is passed through untouched and counted.

**Scan cost:** one pass over the 118 MB `.text` takes about 0.2 s, measured on the file by `sigcheck`. This is a
one-time hitch on the game thread at the first tick. Load the DLL at the main menu or right after a world loads.

## Build

`build.cmd` builds everything. `build.cmd test` builds, then runs checks a, b and c below. MSVC x64, `/MT /W4 /WX`.
Check a reads the game file given as the second argument (`build.cmd test <path to ManorLords-Win64-Shipping.exe>`).
Without it, it reads the test copy `<ML_TEST_ROOT>\_ml_test\...` (`ML_TEST_ROOT` from the environment or
`tools\dev\local.env`); with neither, `sigcheck.exe` prints its usage and the check fails. It never defaults to a real install.

| Output | What it is |
|---|---|
| `out\coop_patch.dll` | the shipped DLL; exports only `coop_patch_tick` |
| `out\test\coop_patch.dll` | the test build (`/DCOOP_PATCH_TEST`) |
| `out\test\patch_test.exe` | the mechanism test program |
| `out\test\image_test.exe` | runs the shipped DLL against its own image-backed `.text` |
| `out\tools\sigcheck.exe` | the offline signature checker |

The test build adds `coop_patch_test_use_module(base)`, which points the scan at a synthetic module, and a
`TESTFAULT` command. It writes its own `coop_patch.cfg` in `out\test\`. The shipped DLL has no test code, and
nothing is placed beside it.

Sources:
- `coop_patch.c`: the DLL.
- `coop_scan.h`: the signature table plus the scan and site checks, shared with `sigcheck`.
- `tools\sigcheck.c`, `test\patch_test.c`, `test\image_test.c`, `probes\*.lua`.

## Test results (2026-11-10, without the game)

### a. Offline signature check

`out\tools\sigcheck.exe` read the installed `ManorLords-Win64-Shipping.exe` as a file. Its TimeDateStamp 6836C1BA
and SizeOfImage 9DFD000 are the **same build** the report was made from. All 13 signatures in sigs5.txt, plus
reformSquad from native4 and finishConstruction from report_W, held: exactly one hit, the RVA as listed, the original bytes as listed, the call targets
right, and each patch inside one aligned qword.

```
name         dll  hits     rva      rva=  patch_rva  bytes_now   orig(sigs5) call_target  qword  result
TSR          yes  1        4D88CE0  yes   -          -           -           -            -      PASS
REFORM       yes  1        4D7CCE0  yes   -          -           -           -            -      PASS
P1           yes  1        4DAC577  yes   4DAC58C    741C        741C        -            one    PASS
P2           yes  1        4D669B8  yes   4D669DE    E8FD        E8FD        4D88CE0      one    PASS
P3a          yes  1        4D66B24  yes   4D66B29    E8B2        E8B2        4D7CCE0      one    PASS
P3b          yes  1        4D8160B  yes   4D81616    E8C5        E8C5        4D7CCE0      one    PASS
FINISH       yes  1        4D0B370  yes   -          -           -           -            -      PASS
ALT-A        no   1        4C6FA56  yes   4C6FA89    44886C2428  44886C2428  -            one    PASS
ALT-B        no   1        4DC729E  yes   4DC72B8    4088742428  4088742428  -            one    PASS
CombatHit    no   1        4DAB7F0  yes   -          -           -           -            -      PASS
recalc       no   1        4E27970  yes   -          -           -           -            -      PASS
just_die     no   1        4E03010  yes   -          -           -           -            -      PASS
updProjSite  no   1        4C6FA65  yes   -          -           -           -            -      PASS
perfHitSite  no   1        4DC72B5  yes   -          -           -           -            -      PASS
routCall     no   1        4D669D9  yes   -          -           -           -            -      PASS
15 of 15 signatures hold (all)
```

### b. Mechanism test: 87 passed, 0 failed

`out\test\patch_test.exe` builds synthetic game modules in memory: a PE header and a `PAGE_EXECUTE_READ` `.text`.
They hold small hand-assembled functions that contain the exact signatures and really run:
- `combat()` reproduces P1's death check.
- `morale()` reproduces the P2 site.
- `p3a()` and `p3b()` reproduce the P3 sites.
- The fake TriggerSquadRetreat, reformSquad and finishConstruction keep the real prologue bytes, then hand over to C functions that
  record their arguments.

The test drives the test build of the DLL only through `patch_cmd.txt`. Scenarios:
- **A, good module.**
  - A stale `NOKILL ON` from before the first tick is skipped.
  - The `ready` line is right, and the log notes that the build differs.
  - **Before any patch:** `combat` kills, and `morale`, `p3a` and `p3b` call through.
  - **NOKILL ON:** writes `66 90`, and a lethal hit leaves health at 1.0. OFF restores the kill path.
  - **NOROUT and NOREFORM:** ON stops the calls; OFF restores the exact original bytes and the calls.
  - **ALLOFF:** after three patches, `.text` is byte-identical to the original.
  - **Command file:** a partial line waits for its newline, a truncated file is read again from 0, and commands are
    case-insensitive.
  - **ROUT refusals:** 10 malformed or unsafe forms are refused with plain reasons: no args, one arg, null,
    unaligned, uncommitted, bad vtable, handle above int32, not a number, handle 0, three args.
  - **Good calls:** `ROUT` (decimal and hex) and `REFORM` each call once with the right arguments.
  - **Faulting target:** the exception is caught, ROUT becomes `unavailable`, REFORM stays available, the process
    stays alive, and the DLL stays `ready`.
  - **FINISH:** 8 bad forms are refused: no arg, two args, null, unaligned, uncommitted, bad vtable, an object
    running off committed memory within 0x1500 bytes, not a number. A good call (decimal and hex) passes the right
    pointer. A faulting target is caught: FINISH becomes `unavailable`, REFORM stays available, the DLL stays `ready`.
  - **Internal failures:** 3 `TESTFAULT`s switch the DLL `off` and restore every byte. While off, `NOKILL ON` is
    ignored and `STATUS` still answers.
- **B, duplicate P1 pattern:** P1 is `unavailable signature has 2 hits` and nothing is written. The files land in the
  `COOP_NAME` subfolder.
- **C, wrong original byte and wrong call target:** P1 and P2 are unavailable, and nothing is written.
- **D, patch across an 8-byte block:** P1 is refused.
- **E, already patched:** the sites are found `on`. OFF restores them, and P2's call byte is rebuilt correctly, so
  the call works again.
- **F, no TriggerSquadRetreat:** P2 and ROUT are unavailable, and the rest is unaffected.
- **G, nothing matches:** the status reads `off nothing matches this game build (timestamp ...)`.

Scenario C also runs with only `COOP_ROLE=host` set and checks that the files land in `io\host\`.

### b2. The shipped DLL on a real image-backed `.text`: 15 passed, 0 failed

`out\test\image_test.exe` carries the P1 pattern inside its own `.text`, merged with `/MERGE`. That is a mapped image
page, like the game's code. The test loads a copy of the **shipped** `out\coop_patch.dll` (no test switch) from
`out\test\image\`, and the DLL scans `GetModuleHandleW(NULL)` exactly as it will in the game.

Results:
- **Scan:** `ready <its timestamp>`, `P1 off`, and P2/P3/ROUT/REFORM `unavailable`, because that code is not in this
  program.
- **NOKILL ON:** writes `66 90` through the copy-on-write path of an image page, and the protection is back to
  `PAGE_EXECUTE_READ` afterwards.
- **Refusal:** ROUT is refused while unavailable.
- **NOKILL OFF / ALLOFF:** restore `74 1C`.

### c. dumpbin

- `/exports out\coop_patch.dll` shows only `coop_patch_tick`.
- `/dependents` shows only `KERNEL32.dll`. The CRT is linked in statically (`/MT`), so there is no CRT DLL.

### d. 2026-11-12, with GOODS (lane 14): `build.cmd test <path to the game file>`

The numbers above are those of 2026-11-10; the table has grown since (NF1, NF2, BURN, FIREOUT, and the three GOODS
entries). Run on 2026-11-12 against the lane's copy of the game file
(`<ML_TEST_ROOT>\_ml_test_4\...\ManorLords-Win64-Shipping.exe`, the same build 6836C1BA / 9DFD000):

- **a. Offline signature check: 22 of 22 hold**, and the GOODS check passes. The three new entries:
  ```
  RECOUNT      yes  1        4D18FC0  yes   -          -           -           -            -      PASS
  REFRESH      yes  1        4C49700  yes   -          -           -           -            -      PASS
  ADDINV       yes  1        4D28410  yes   -          -           -           -            -      PASS

  GOODS (hooks at RECOUNT and REFRESH; ADDINV's calls at +45h and +64h must reach them): PASS
  ```
  One scan pass over `.text` with the DLL's 14 signatures took 534 ms inside the game (the log's own line) and
  about 0.6 s on the file: two of the new patterns start with bytes that are common in code (`48 89`), so more
  places are looked at. It is still one pass, once, at the first tick.
- **b. Mechanism test: 145 passed, 0 failed.** New scenarios:
  - **A** also checks `GOODS unavailable RECOUNT signature has 0 hits` in a module without the three routines.
  - **H, GOODS.** The synthetic module holds recountStorage and refreshBuildingStorageCache with their real entry
    bytes (they run; then the prologue is undone and C records the call) and addToInventory whole, as in the game,
    calling an add helper, the recount and the refresh. A C "game" changes a building's list and calls recount and
    refresh; a C "mod" calls addToInventory. Checked: status off, then on with a jump at both entries and nothing
    else changed; a building the mod has not written is left alone and every argument arrives as sent; the mod's
    write is remembered; the game's change (taking, delivering, taking everything so that the record is removed,
    a new kind at the end, a new kind in the middle, a removed record with no room in the list) is put back, in
    the hook or at the next tick as designed; recountStorage itself already sees the put-back amount; the game's
    list of what changed is dropped for the refresh; a write of amount 0 registers a building; `GOODS ON <lord>`
    takes a building of that lord in by itself; `GOODS AUDIT` finds, logs and repairs a change that reached no
    hook; calls from another thread pass through and are counted; another object at a remembered address is
    forgotten; `FINISH` is remembered as the host's word and the list the "game's" finishConstruction hands the
    region is dropped; `FINISH` on another lord's building that the mod never wrote does not freeze it and its
    list reaches the region unchanged; `PILEGONE` refuses three bad forms and, for a pile,
    empties it and calls recountStorage(pile, 1, 1, block); `GOODS STATS` writes its file; `GOODS OFF` and `ALLOFF`
    leave `.text` byte-identical to the original; a hook that faults is caught, the game's routine still runs, and
    at the next tick the item reads `GOODS unavailable exception C0000005 in a hook` with every byte restored and
    the DLL still `ready`; `GOODS ON` is refused after that.
  - **I, addToInventory's first call goes elsewhere:** `GOODS unavailable ADDINV's first call does not reach
    RECOUNT`; nothing is written; the other items are unaffected.
- **b2. Image test: 15 passed, 0 failed** (unchanged).
- **c. dumpbin:** exports only `coop_patch_tick`; depends only on `KERNEL32.dll`.
- **In the game:** see the lane 14 report (one copy for ten minutes, two copies for the acceptance runs).

### e. 2026-11-13, with DRAW and ORDER (lane 28): `build.cmd test <path to the lane's game file>`

Run against the lane 5 test copy's game file (the same build 6836C1BA / 9DFD000):

- **a. Offline signature check: 41 of 41 hold.** The five new entries, each with exactly one hit at its listed RVA:
  `TOOLUPD` 4B67950, `ROADCLICK` 4B6A5F0, `COMMITROAD` 4B368C0, `MOVESEL` 4B4F500, `PATHPT` 4B5F5C0. One pass with
  the DLL's 33 signatures: about 1.0 s on the file.
- **b. Mechanism test: 261 passed, 0 failed** (205 before). New section **K**: the synthetic module holds the five
  routines with their real entry bytes; each hands over to a C stand-in that does to a fake pawn what the game's
  routine does (the update keeps the cursor point and sets the cannot-place flag, the click appends to roadPoints,
  MoveSelected edits the path list the game's way, the press handler makes the list one point long). Checked:
  - K1: `WALL` runs update and click per point in order, each update sees its point and the change of the cursor
    point, the change is zero afterwards; flag 1 calls commitRoad once and the answer holds the road; a blocked
    point stops the drawing (no click, no commit) and is named; flag 2 clears the flag before the click; 8 bad forms
    are refused; `TOOL`; `WALLGET` returns kind, control points, gate place and record and refuses an object whose
    list is not sane; `ORDERAT` passes pawn and flags, clears +488h, refuses a waypoint order on an empty path list
    and 3 bad forms; `PATH` leaves exactly the given points in the list for 4 points, 2 points and a last point
    nearer than the game's step, and refuses 3 bad forms; `PATHGET`; `PATHPT` refuses an empty list;
    `ORDERHOOK ON` changes only the 5 entry bytes, the game's own call still reaches the routine with its arguments,
    nothing is written inside the call, the next tick writes the line (pawn, point, hover state, squads, the path as
    the call left it), this DLL's own order and a call from another thread are not written, `ORDERHOOK OFF` and
    `ALLOFF` leave `.text` byte-identical to the original; a faulting MoveSelected or tool update is caught, the item
    becomes unavailable and the DLL stays ready.
  - K2: the routines present on another game build: everything unavailable, nothing called, nothing written.
  - K3: MoveSelected twice: ORDER and ORDERHOOK unavailable, DRAW unaffected. K4: none of the routines.
- **b2. Image test: 15 passed, 0 failed** (unchanged). **c. dumpbin:** unchanged.
- **In the game:** see the lane 28 report (one copy, then two copies with both directions, two in-process resyncs and
  a four-minute soak at speed 4: 0 exceptions in a hook, 0 refused calls that were not meant to be refused).

### Not tested

- **GOODS, failure paths never exercised:** no free memory near the game module for the stubs; a list with more
  than 160 kinds of goods or more than 4096 remembered buildings; a failed write of the second hook.
- **Anything inside the real game.** Use the probes below.
- **Failure paths never exercised:**
  - A failed compare-exchange, or a failed read-back after a write.
  - The "unexpected bytes" branch. In practice it cannot be reached: the signature itself fixes the patch bytes, so
    a wrong byte shows up as "0 hits".
- **The Lua files.** There is no Lua interpreter on this PC: `coop_patch.lua` and the probes were never parsed or
  run. They were only read by eye.

## Live steps (yours)

Run these on one copy with a world loaded, from the probe console:
1. `probes\probe_patch_step1.lua` loads the DLL from `out\` and prints the status. Expect `ready 6836C1BA 9DFD000`,
   P1â€“P3b `off`, and ROUT and REFORM `available`.
2. `probes\probe_patch_step2.lua` turns `NOKILL ON` (expect `P1 on`). `probes\probe_patch_step2_off.lua` undoes it.

## FINISH: what it does, and the risk

`FINISH <address>` calls `finishConstruction(SMBuildingMaster*)` (RVA 4d0b370, `rcx` = the building, returns
nothing). This is the game's own "site complete" routine.

**Its two callers in the game** (lane_w report_W answer 1):
- The builder's hammer handler 4dc5270 calls it when no part needs more work AND all construction goods are
  delivered.
- An async construction callback 4cbdb1e calls it after checking only that no part is on fire.

Calling it from FINISH means calling it from outside both. Its signature has exactly one hit in the installed exe.

**What the opening of the function does** (read on 2026-11-10 with `dumpbin /disasm`, 4d0b370..4d0b900, from the
file):
- **No precondition check at entry.**
  - There is no "already constructed" guard. `IsConstructed` (+0x3C1) is not read before the function sets it to 1
    at 4d0b6df.
  - It does not read the building's delivered goods against `constructionGoods`.
  - It does not read the parts' hp (+0x314/+0x318) anywhere in that range.
  - Statically, it neither refuses nor protects against unfinished goods or parts below full hp: the checks live in
    the callers.
- **Its first steps:**
  - It calls 4d098b0(building).
  - If the owner object at +0x2E0 has flag +0x34C set and engine (+0x2E8) +0x318 is set, it appends the building
    type (+0x3B8) to an engine list (+0x11D0) and increments engine+0x11E0. GUESS: a "buildings built" statistic.
  - It clears +0x3A1, +0x3A2, +0x3A3 and +0x700, and sets +0x3C1 = 1.
  - When +0x3A1 was 0, it writes a day value into +0x428 and through the object at +0x360. Both pointers are
    dereferenced with no null check.
  - Building type 0x1E3 takes a special branch that spawns 8 things around the site. GUESS: what they are.
- **Next it consumes the construction inventory.** The goods array at +0x3D0 is handed to the region (+0x2C8) with
  negated amounts, then emptied. Whatever was delivered is consumed; nothing checks that it was everything.
- **Then it updates every part.** It walks the parts list (+0x2F8, count +0x300). GUESS: scaffolds, visibility and
  workers. The function continues past 4d0b900; the rest was not read.

**What this means for the caller** (the mod):
1. **Call it at most once per building, and only while `Data.constructed` is false.** A second call repeats every
   side effect: the statistic, consuming the inventory, the type-0x1E3 spawn. `Coop.patch.finish` refuses an
   already-constructed building unless you pass `force`.
2. **Call it only on a valid, placed building.** The engine (+0x2E8), the region (+0x2C8) and the object at +0x360
   are dereferenced without checks. A building being demolished or not yet fully spawned can fault. The fault is
   caught, and FINISH then turns itself off for the rest of the session.
3. **Missing goods are not refused.** If goods are still missing on this copy, it completes anyway. Only what was
   delivered is removed from the region's stock. Push the host's deliveries first (`addToInventory`), so the stock
   change matches the host's.
4. **Not checked:** fire. The async caller requires that no part burns. Do not call it on a burning site.
5. **Not knowable statically:** whether later code (after 4d0b900, or in the called helpers) assumes the parts are
   at full hp. GUESS: it sets them visually complete. A live test on one cheap building is the way to find out.

## GOODS: building stock changes only on the host's word

Why and what was measured: `research\2026-11-10-game-probe\lanes\lane_s21_14\report.txt`. In short: each copy runs its
own villagers, so stock drifts between copies, and correcting it from outside makes numbers flicker. With `GOODS ON` a
friend's copy puts every change the game itself makes to a building's `Inventory` back in the same call, so the
amounts stand still between two writes of the mod; the friend's villagers go on walking, working and carrying.

**Where the game changes a building's stock** (static read of the game file with `lanes\lane_s21_14\tools\pe.py`;
tables in `lanes\lane_s21_14\static\`): two add helpers (4c5a400, 4c05d90; 23 call sites) and code written out in
place. There is no single routine to switch off. But after a change the game calls `recountStorage(building)`
(4d18fc0, 42 call sites) and / or the region's `refreshBuildingStorageCache(region, building, mode, delta, ...)`
(4c49700, 56 call sites). `SMBuildingMaster::addToInventory` (4d28410), the routine behind the reflected function the
mod writes with, has exactly one caller in the game file: its script thunk. The game's own code never calls it.

**What the hooks do** (`goods_event` in `coop_patch.c`):
- A hooked call that returns into addToInventory (+4Ah after its recount call, +69h after its refresh call) is the
  mod's own write: the host's word. The building is remembered ("frozen") as it is at that moment: per good, the
  amount. The same holds while this DLL itself runs `FINISH`, `BURN`, `FIREOUT` or `PILEGONE`, with one limit:
  such a call takes a building in that was not remembered yet only when it is the lord's (a `FINISH` of another
  lord's house must not freeze that house). For a frozen building the list of what changed that such a routine
  hands the region's refresh is set to null too: finishConstruction passes the site's own list of materials
  (+3D0h, negated), not what left the building, and on a friend the building holds the host's amounts. Before this
  rule (version 0.2) a friend's region total of planks was 6 below its own buildings after a site was finished.
- Any other hooked call for a frozen building is the game's own change. Before the routine runs, the amounts are put
  back to the remembered ones. For the region's refresh in mode 0 the game's list of what changed (`r9`) is set to
  null, which makes the routine take the building's stock as it is now instead of adding the game's change to the
  region's totals.
- A building that is not frozen is left alone. A building whose `ownerPawn` (+2E0h) is the lord named in `GOODS ON`
  is frozen the first time it is seen (its first change stays). The mod also registers every building of the lord
  with a write of amount 0, which reaches the recount call and nothing else.
- Inside a hook the list is never moved or grown, because a caller may hold a pointer into it: amounts are written
  in place; a record the game added at the end is cut off by the length; a record the game removed is put back at
  the end while the list has room. What that cannot do (a record added in the middle, no room) is repaired at the
  next tick with the game's own addToInventory, which grows the list and removes records at or below nothing.
- A remembered building is recognised by address, object index (+0Ch) and name (+18h); when those no longer match,
  the entry is dropped. At most 4096 buildings and 160 kinds of goods per building; more is left alone and counted.

**Commands.** `GOODS ON [lord]` writes both hooks (both or neither) and starts with nothing remembered (when the
hooks are already in, it only takes the lord's address). `GOODS OFF`
takes them out and forgets everything. `GOODS AUDIT` compares every remembered building with its remembered amounts:
a difference is a change that reached neither hook ("leak"); it is logged, counted and repaired. `GOODS STATS` writes
`goods_stats.txt`: per caller of the two hooked routines, how often it called and how often something was put back.

**PILEGONE.** recountStorage removes a pile (type 58h) when it is empty, but only when its second argument is 1, as
the game's carriers pass it; addToInventory passes 0. With GOODS on a pile never empties by itself, so the mod asks
for it: the pile's records are emptied with addToInventory and recountStorage is called with (pile, 1, 1, the same
block addToInventory passes). Refused for a building that is not type 58h.

**What a friend's copy loses with GOODS on.** Nothing the game makes, takes, delivers, trades or uses up changes a
frozen building; all of it must come from the host (coop_facts.lua, exact mode). A house never receives what its
family fetches, so on a copy where nothing is pushed approval falls (77 to 54 in 34 game days, measured on one copy;
77 to 78 without the switch). What villagers carry is each copy's own, and a villager can pick the same goods up
again and again from a building whose stock stands still. A region's total (buildings plus what is in hands)
therefore differs from the host's by what is in hands.

**In the game** (lane 14 report, 2026-11-12). One copy, switch on, nothing pushed, 10 minutes at speed 4: 0 stock
changes in 2,324 readings of 42 buildings, 1,104 changes put back, 0 leaks in 619 audits, no crash. Two copies, 20
minutes in three phases with the host pushing every building's stock: paused, 0 stock numbers differ between host
and friend in every phase; 2,301 changes put back on the friend, 0 leaks in 267 audits, 0 exceptions, 0 calls from
another thread, 3 piles removed with `PILEGONE`, three reloads (resyncs) survived. Two later sessions with speed 8
held for 5 minutes and 3 minutes at speed 4 (the second on version 0.3): paused, 0 stock numbers differ in all four
phases; 0 leaks in 162 and 130 audits. Five minutes with the players acting on version 0.3 (place, demolish, three
piles removed with `PILEGONE`, four sites finished with `FINISH`): paused, 0 of 45 differ. With a DLL made to miss the RECOUNT signature both copies read `GOODS
unavailable RECOUNT signature has 0 hits (need exactly 1)`, no copy entered exact mode and stock was kept by the
older rules.

## TOTALS: a region's totals change only on the host's word (lane 22)

Why and what was measured: `research\2026-11-10-game-probe\lanes\lane_s21_22\report.txt`. With GOODS a friend's
buildings hold the host's stock, but a region's totals (the numbers of the top bar and of the region panel; the list at
region +528h that `Region::getStockOfGood` reads) are its buildings plus what its people carry, and what is carried is
each copy's own. So the totals differed.

**Where the game changes the totals** (static read; `lanes\lane_s21_22\static\refs528.txt`): only through "add a list
of goods to a list" (ADDLIST, 4b73d00), at six call sites in four routines of the region (a building added, a
building's refresh twice, a unit's refresh twice, a building removed): TS1-TS6. After each the game calls the region's
"goods changed" notice (NOTIFY, 4c57ec0: it marks the good for the player's pawn). No other code of the game-class
range writes +528h or +530h of a region.

**What the hook does.** ADDLIST's first instruction (`mov [rsp+20h],r9b`, 5 bytes, no address in it) becomes a jump to
a stub. The stub calls `totals_hook`; when it returns 1 the stub returns to the caller without running the routine.
- The list is the totals of a region this DLL tracks, the call is on the thread that ticks and it is not the DLL's own:
  the change (the source list, negated when asked) is added to the DLL's SHADOW of that region and the routine does not
  run. The shadow is what the game's totals would be without the switch.
- Any other list (a building's copy, a unit's copy, another region's totals, anything else of the 57 callers): passed.
- A call from another thread: passed and counted (`otherthread`).

**Two lists per region.** Besides the totals (+528h) a region keeps the totals minus what is reserved (+538h, the
same kind of list; `getStockOfGood(good, true)` reads it, and the top bar shows it while the player's surplus view is
on). It too changes only through ADDLIST (the sites next to TS1, TS2/TS3's mode 1, the unit refresh, TS6), and it can
hold a negative amount (a good reserved that is not in stock: the game never removes records there). Both lists are
tracked and shadowed; `TOTALS SETR` writes the second one (without removing records at or below nothing).

**Commands.** `TOTALS ON` writes the hook (no region tracked yet: every call passes). `TOTALS SET <region>
<good>=<amount>,...` takes the region in the first time (its shadow starts as its totals at that moment; the region
must look like an object of the game: committed, its vtable in the module, a list at +528h), then writes the listed
amounts with ADDLIST and calls NOTIFY with the change; goods not listed stay. `TOTALS OFF` is the recount: every
tracked region that is still the same object (address, object index +0Ch, name +18h) gets its shadow written back with
ADDLIST and NOTIFY; then the hook goes. `TOTALS FORGET` drops the shadows without writing (after a load the regions are
new objects). `ALLOFF` and going `off` recount like OFF. `TOTALS AUDIT` compares every tracked region's totals with what
was last written: a difference is a change that did not go through ADDLIST (`leaks`); it is logged and written back.
`TOTALS DUMP` writes `totals_dump.txt` (per region the shadow and the totals).

**Status:** `TOTALS on|off|unavailable <reason>` and a line `totals regions= calls= skipped= skipunits= sets= setunits=
recounts= recountunits= forgot= otherthread= badsrc= faults= audits= leaks= leakunits=`.

**After a game update.** TOTALS needs ADDLIST and NOTIFY with exactly one hit, ADDLIST's known first instruction within
one aligned qword, and the six sites with exactly one hit each whose call reaches ADDLIST. The site patterns hold the
+528h offset ("lea rcx,[reg+528h]"); NOTIFY's holds +318h and the pawn's +5B0h. Anything else: `TOTALS unavailable
<reason>`, nothing written; the world module then leaves the totals to the game (the friend's totals are its own again,
as before lane 22). NOT guarded: the object index and name offsets (+0Ch, +18h; shared with GOODS).

## DRAW and ORDER: the wall tool and the army order routine (lane 28)

Why and what was measured: `research\2026-11-10-game-probe\lanes\lane_s21_28\report.txt`. In short: a wall of the
castle plan, the order against a building and the path order (Ctrl + right drag) are native. No reflected function
builds a wall from points, names a building as a squad's target or gives a squad a path, and what the player did is
not left where a script can read it. The game's own AI lords draw roads by writing the cursor point and calling the
tool's update and click per point, then commitRoad (4be8fe0): `WALL` does the same for any pawn.

**Signatures** (function entries, exactly one hit each, and the known build): `TOOLUPD` 4b67950, `ROADCLICK` 4b6a5f0,
`COMMITROAD` 4b368c0, `MOVESEL` 4b4f500, `PATHPT` 4b5f5c0; lane 26's `CURSOR` and `RMBDOWN` are used too.

**Commands that answer** write `patch_reply.txt` (replaced atomically): `R <token> <command> ok ...`, or
`R <token> <command> refused <why>`, or `R <token> <command> exception <code> ...`. The token is any word without
blanks; the mod reads the file right after its own tick call.

| Command | Does | Answer after `ok` |
|---|---|---|
| `WALL <token> <pawn> <flags> <points>` | 2 to 21 points `x,y,z\|x,y,z...`. Per point: cursor point (+4E8h) and its change (+4C0h), tool update, click. Flag 1: commitRoad afterwards. Flag 2: the update's "cannot place" flag (+5FCh) is cleared before each click. Without flag 2 a blocked point stops the drawing, as in the game's own routine | `pts=<road points now> blocked=<one digit per point> stop=<point that stopped it, 0 = none> road=<address of the new road, hex, 0 = no commit>` |
| `TOOL <pawn>` | one tool update (log only) | - |
| `WALLGET <token> <road>` | reads a road | `kind=<isBlueprint,roadType,wallType,platformLevel> ctl=<n> <points> gates=<n> <x,y,z:60h bytes hex\|...>` |
| `ORDERAT <token> <pawn> <x,y,z> <wp> <noArrows>` | cursor point, +488h = 0, MoveSelected(pawn, wp, noArrows). A waypoint order is refused unless the path list would hold two points (the game reads `list[n-2]` unguarded) | `way=<n> <points>` (the pawn's path list afterwards) |
| `PATH <token> <pawn> <noArrows> <points>` | 2 to 64 points: RMB pressed handler at the first point (it makes the path list one point long), PATHPT per point, MoveSelected(waypoint). With three or more points the press is made at the second point, because MoveSelected drops the list's first point | `way=<n> <points>` |
| `PATHGET <token> <pawn>` | the pawn's path list (+CA8h, 88h bytes a point) | `way=<n> <points>` |
| `PATHPT <pawn>` | one run of the path routine (log only); refused while the list is empty | - |
| `ORDERHOOK ON` / `OFF` | writes / removes the jump at MoveSelected's entry | status line |

**The pawn must be prepared by the caller** with the game's reflected functions and fields: for a wall
`setPlannerMode(manor)`, `switchWallMode(true)`, `setRoadMode(true, first point, false)` and `regionUnderCursor`
(the tool works out a wall's gates from that region's roads); for an order `selectedSquads`, and for an order
against a building `cursorMode = 3` and `hitBuilding`.

**ORDERHOOK.** Same rules as the GOODS hooks (found by signature, the replaced instruction `mov [rsp+20h],rbx` is
whole and holds no address, written through `write_bytes` inside one aligned 8-byte block, the stub in a page within
reach of a 32-bit jump, both `ORDERHOOK OFF` and `ALLOFF` put the 5 bytes back, an exception in the hook switches it
to pass-through at once and takes it out at the next tick). The hook only copies fields of the pawn; a call this DLL
makes itself (`ORDERAT`, `PATH`) and a call from another thread are not noted. One line per call, written by the
next tick so that a path is read as the call left it:

```
MOVESEL <n> pawn=<hex> wp=<0|1> na=<0|1> cur=<x,y,z> mode=<cursorMode> moved=<0|1> hb=<hitBuilding hex> hbt=<its type>
  hbc=<its buildingFunction> hp=<hitBuildingPart hex> res=<resource node hex> sq=<h,h,...> waybefore=<n> way=<n> <points>
```
(one line in the file). The file starts again above 256 KB. Status: `ORDERHOOK hooked | idle | unavailable <why>`
(never the word `on`: the host's "everything off" rule looks for that word) and
`draw walls= tools= wallgets= orders= paths= seen= events= dropped= hookfaults=`.

**Status lines:** `DRAW available | unavailable <why>` (CURSOR, TOOLUPD, ROADCLICK, COMMITROAD), `ORDER ...` (CURSOR,
MOVESEL), `PATH ...` (ORDER, PATHPT, RMBDOWN).

**Offsets no signature holds** (so every item also needs the known build): pawn +488h, +5B8h, +710h, +718h, +738h;
road +2B3h..+2B6h, +318h, +498h; building +3CCh. After a game update check them against a fresh dump.

**Scan cost** with these five signatures: one pass over `.text` took about 1.0 s offline for the DLL's 33 signatures
(0.6 s for 28 before): three of the new patterns start with very common bytes (`48 8B`, `48 89`, `40 55`).
## HOLD: a region's panel numbers change only on the host's word (lane 31)

Why and what was measured: `research\2026-11-10-game-probe\lanes\lane_s21_31\report.txt`. Approval, its factor rows,
public order and its rows, the months of food and fuel, the regional wealth and the problem list are each copy's own
sums. A friend's day routine rebuilds approval from its own families' memories (a home refuelled one day later there
gives one more "cold" row: 75 against 76), its villagers' market trade moves its own wealth, its own checks add and
remove problems. A value written from outside is overwritten by the friend's own routine at the next change.

**Who writes what** (static read, `lanes\lane_s21_31\static\writers.txt`): Region.Approval (+1030h) only in
updateApproval (and the constructor and the loader); publicOrder (+104Ch) only in updatePublicOrder; supplies_food /
supplies_wood (+59Ch / +5A0h) only in 4c70030; regionalWealth (+648h) in addRegionalWealth, consumeRegionalWealth and
one store inlined in the monthly routine 4c3d5f0; Region.problems (+D80h) through add 4c37810 (42 callers) and remove
4c691e0 (65 callers). Measured: a written Approval stays until the next day change (paused and at speed 1 and 4).

**What the hooks do.** Each routine's whole first instruction(s) (6, 7, 5, 7, 7, 5, 7, 6 bytes; the eighth, remove-all-of-a-kind 4c69110, added after raid1, inside one aligned qword)
becomes a jump to a stub: push the argument registers, call `hold_gate(region, frame, id)`, pop; 0 = run the replaced
instruction(s) and jump back; 1 or 2 = return at once with al = 0 or 1. A held region's routine does not run;
consumeRegionalWealth then returns what the game would (settled and the wealth covers the amount), add a problem
returns whether the problem was there, so callers branch as on the host. The monthly store becomes a jump to a stub that
saves rax, rcx, rdx, r8-r11 and xmm0-5, aligns the stack itself and calls `hold_wmon(r15, eax)`, which stores unless
the region is held. Calls from another thread pass and are counted; the DLL's own calls (PROB, the recount) pass.

**Commands.** `HOLD ON` writes all eight jumps or none. `HOLD SET <region>` holds the region (an object of the game, sane
lists at +1038h, +1050h, +1060h, +D80h). `HOLD ROWS <region> A|O|M <type>:<past>:<effect>:<day>:<expires>:<count>/...`
writes a whole ApprovalMemory list (A summedApprovalFactors, O summedPublicOrderFactors, M publicOrderMemory); a longer
list is grown with the game's own grow helper (4c4e8f0, reached through updateApproval's call at +31Ch), a shorter one
is cut by its length. `HOLD PROB <region> <type>:<building>:<unit>/...` makes the problem list exactly that with the
game's own remove and add. `HOLD OFF` runs the game's own updateApproval once per held region (approval from its own
families), then takes the jumps out; `HOLD FORGET` without that. `ALLOFF` and going off recount like OFF. `HOLD DUMP`
writes `hold_dump.txt`.

**Status:** `HOLD on|off|unavailable <reason>` and `hold regions= approval=<calls>/<held> order= supplies= wealthAdd=
wealthSub= problemAdd= problemRemove= wealthMonth= otherthread= sets= rows= grown= padds= prems= recounts= forgot=
refused= faults=`.

**After a game update.** HOLD needs its nine signatures with exactly one hit, each entry's known first bytes within one
aligned qword, the store's known bytes, the body stores at their offsets (+270h and +55Dh Approval, +590h publicOrder,
+281h and +B20h the months) and the grow helper's known first 28 bytes at updateApproval's call. Anything else: `HOLD
unavailable <reason>`, nothing written; the friend's numbers are its own game's again (as before lane 31).

## What a friend's copy loses with P1 on

The source is report answer 4. Each of these must come from the host, or be accepted as cosmetic.

**Unchanged on the friend's copy:**
- Hit and miss rolls, damage (health floors at 1.0), and combat experience.
- Hit sounds, "hitShield", and the shield `equip(252)` with its stat recalculation.
- The tickSquad reaction, and charging being cleared on a hit.

**Lost:**
- **The death itself.** No one dies in CombatHit on that copy, so the mod must apply the host's deaths, for example
  with `just_die`.
- **The `deathInCombat` tag.** CombatHit adds the FName `deathInCombat` to the unit's Tags (+0x1E0) before
  `just_die`. `just_die` adds a family grief entry (type 4, 5 days) when that tag is ABSENT. So when the host's death
  is applied with `just_die`, first append `deathInCombat` to `u.Tags`. Otherwise the friend's copy grieves where
  the host does not.
- **Mount deaths.** When a rider dies in CombatHit, the mount (+0xE58) also gets health 0 and `just_die`. Apply the
  host's mount deaths too.
- **Animals and villagers.**
  - Animals (+0xAB2 units, GUESS) hit by hunters' arrows stop dying on that copy.
  - Villagers murdered by bandits stop dying, if those murders go through CombatHit (GUESS in the report).
  - The host must send these deaths too.
- **`Squad.deathTimes`.** The append at 4dac61e is lost. It feeds the morale "recent losses" term, so the friend's
  morale drifts from the host's. This is harmless while P2 (no own rout) is on.
- **Kill counters.** engine+0x11EC and +0x11F0 are statistics and challenges; not reflected.
- **Death presentation.** The sync-kill paired animation, death cue, blood decal and death camera shake are lost.
  `just_die` still plays a death animation.
- **Killers that do not pass CombatHit still kill on that copy:** fire, building collapse, hunger and cold,
  maintenance injuries, trade merchants, and performHit action 40. Keep the town in sync, or send those deaths
  from the host as well.

## After a game update: did it switch itself off?

Read `patch_status.txt`, or call `Coop.patch.status()` in the game:
- **Line 1 `off nothing matches this game build (timestamp X)`.** Nothing was found and nothing was written.
- **Line 1 `ready <timestamp> <size>` with a timestamp other than `6836C1BA`.** The signatures still matched on a
  new build. `Coop.patch.status().knownBuild` is false. Each item says `off`/`on` or `unavailable <reason>`, for
  example `signature has 0 hits` or `call goes to rva ..., not TSR`. An unavailable item was never written.
- The log's first lines say `game build differs from the one the report was made from: ...`, followed by the hit
  count of each signature.
- **Offline, before starting the game:** run `out\tools\sigcheck.exe <path to the new ManorLords-Win64-Shipping.exe>`. It prints the same table for the new file.
- **GOODS after an update.** It needs all three of its signatures (RECOUNT, REFRESH, ADDINV) with exactly one hit,
  the two known first instructions, and addToInventory's two calls reaching the two entries. If any of that fails
  the status reads `GOODS unavailable <reason>`, nothing is written, the host does not send "F X 1" and no copy
  enters exact mode: the mod then keeps stock the way it did before (margin, settle time, moving goods). The RECOUNT
  pattern holds the offsets of `numStoredGeneric`, `numStoredPantry`, `Inventory` and its length, and the step
  from one record to the next (24 bytes); ADDINV holds those of `Inventory` and `Region` and of the record's type
  (+0) and amount (+4): a changed layout of the building class or of the record makes them miss. What the
  signatures do NOT guard: the offset of `ownerPawn` (+2E0h, used only to take a lord's building in by itself),
  the offset of the building type (+3B8h, used only by PILEGONE), and the two pointers behind the amount in the
  record (written as null when a record is put back). After an update check those against a fresh dump before
  trusting the switch.

## Lua glue: `mod\ManorLordsCoop\Scripts\coop_patch.lua`

- **On or off.** It is on unless `coop.cfg` has `native = off`. `Coop.patch.enable()` turns it on from the console;
  `Coop.patch.enable([[C:\...\coop_patch.dll]])` uses another path. `Coop.patch.disable()` sends ALLOFF.
- **Loading.** It loads `<mod folder>\coop_patch.dll` and ticks it every frame in `pcall`, including at the main
  menu (module `tick` and `idle`).
- **Friend's copy:** sends `NOKILL ON` and `NOROUT ON` once per world.
- **Host's copy:** sends `ALLOFF` at start, and again whenever the status shows an item `on` (checked every 2 s).
- **Mod stop:** `C.stop` is wrapped and sends `ALLOFF` with one tick. Modules get no stop call, hence the wrapper.
- **`Coop.patch.rout(h)` / `Coop.patch.reform(h)`.**
  - `h` is this copy's squad number.
  - They find the address from `S.sc:GetAddress()` and run the command in the same frame. They return `ok, message`.
  - `rout` refuses a squad already routing (`Control == 3`): TriggerSquadRetreat does not check this and would run
    everything again. `reform` refuses a squad that is not routing.
- **`Coop.patch.finish(building [, force])`.** `building` is the SMBuildingMaster object. It returns `ok, message`.
  - It refuses a nil or invalid building, or a building whose `Data.constructed` is already true or cannot be read.
    `force` skips the constructed check.
  - It sends `FINISH <building:GetAddress()>` and runs it in the same frame.
- **`Coop.patch.status()`.** It parses the status file at most twice a second. It returns a table: `state`,
  `reason`, `stamp`, `knownBuild`, `items.P1.state`, `rout`, `reform`, `finish`, `calls.finish` and so on. `tostring()` gives
  the raw text.
- `NOREFORM` is not sent automatically. The brief asked only for NOKILL and NOROUT. Send it with
  `Coop.patch.send("NOREFORM ON")` if the friend's own reform turns out to diverge.
- **GOODS** (lane 14).
  - **Friend's copy:** `GOODS ON <address of its lord>` while it plays in the host's world, no save is loading and
    the host has said that it sends every building's stock (`Coop.patch.hostExact`, set by `coop_facts.lua` when the
    host's line "F X 1" arrives); `GOODS OFF` otherwise, and at a new world. While on, `GOODS AUDIT` every
    `Coop.patch.cfg.auditEvery` seconds (5; 0 = never).
  - **Host's copy:** never on (the `ALLOFF` rule above covers it). `Coop.patch.goodsAvail()` tells `coop_facts.lua`
    whether the switch could be used on this game build: only then does the host send every building's stock.
  - `coop.cfg` line `goods = off` keeps it off on that copy (`native = off` does too).
  - `Coop.patch.goodsOn()`, `Coop.patch.goodsAvail()`, `Coop.patch.pilegone(building)`;
    `Coop.patch.status().goods` holds the counters, `.items.GOODS.state` the state.
  - Test only (development channel): `Coop.patch.test = { goods = true }` keeps the switch on in a copy that runs
    alone as host; `Coop.patch.test = { goodsOff = true }` keeps it off on a friend.

- **TOTALS** (lane 22).
  - **Friend's copy:** `TOTALS ON` exactly while GOODS is on (`TOTALS OFF`, the recount, when GOODS goes off: a
    release because the host is silent, a save loading, a role change); `TOTALS FORGET` at a new world. While on,
    `TOTALS AUDIT` every `Coop.patch.cfg.totalsAuditEvery` seconds (5). `coop_world.lua` (friendRegionJob, exact
    mode) writes the host's totals with `Coop.patch.totalsSet(region, map)` whenever one differs here.
  - **Host's copy:** never on; in exact mode it sends its totals every `cfg.exactStockEvery` s (1) instead of 2.
  - `coop.cfg` line `totals = off` keeps it off; `Coop.patch.test = { totalsOff = true }` too (development channel).

### Line to add to `main.lua`

Line 45 has the optional module list. Add `"coop_patch.lua"`:
```lua
for _, m in ipairs({ "coop_town.lua", "coop_world.lua", "coop_join.lua", "coop_realm.lua", "coop_patch.lua" }) do
```
Copy `out\coop_patch.dll` into the mod folder, next to `coop.cfg`.

### Where the core should call rout and reform

The place is `coop.lua`, `mirror(H)`, the `if H.ctl == FLEEING then` block at about line 424. That is where a friend
copies the host's rout. Use the native rout first, and keep the current imitation as the fallback:
```lua
  if H.ctl == FLEEING then
    if not M.routed then
      M.routed = true; M.t = clock; touch(h)
      M.native = (C.patch and C.patch.fn and st.ctl ~= FLEEING and C.patch.rout(h)) or false
      if M.native then S.stats.nativeRouts = (S.stats.nativeRouts or 0) + 1
      else
        sc:SetSkillActive({ Value = h }, HALT, true, true)
        later(0.08, function() if sqValid(h) then doMove(h, where); sc:SetSkillActive({ Value = h }, SPRINT, true, true) end end)
      end
      S.stats.routs = (S.stats.routs or 0) + 1
    elseif not M.native and clock - M.t >= 2.0 and far(st.cx, st.cy, H.cx, H.cy, 600) then M.t = clock; touch(h); doMove(h, where) end
```
The `not M.native` gate is new. A squad routed natively runs to its own retreat point, so the 2-second "keep
running after the host's squad" move orders must not be sent to it. That interplay is untested.
The host's squad stops fleeing in the line after that block (`M.routed = false`). Reform there when this copy's
squad still routs:
```lua
  if M.routed and st.ctl == FLEEING and C.patch and C.patch.fn then C.patch.reform(h) end
  M.routed = false
```
- `h` there is already this copy's number: `H.h = toLocal(...)`.
- With P1 on, `friendUpkeep`'s stat zeroing (`att = 0`, `def = 10000`) is no longer needed for deaths. It is
  harmless and can stay.

## CHOOSE: the job chooser runs for the villagers the mod names (lane 23)
Evidence: `research/2026-11-10-game-probe/lanes/lane_s21_23/report.txt` (part 2: why a task given on a friend ends at
once; part 3: this item). The game ends selling, mining and the trader's legs at every work cycle and its job chooser
(rva 4ddb130) starts the next cycle in the same think. On a friend the job board fills the engine's job list so the
villagers choose nothing (JOBGATE); the chooser then leaves at its own test of the list, and the villager stands.
- Site: signature `CHOOSE` (one hit at 4ddb30c in 0.8.117); the 5 bytes at +22 (`lea r8,[rdx+rcx*4]` and the first
  byte of `cmp rdx,r8`, rva 4ddb322, `%8 == 2`) are wildcards in the pattern and checked against their known bytes
  (`chooser_check`); anything else: unavailable, nothing written.
- `CHOOSE ON`: a 5-byte jump to a stub near the module (54 bytes). The stub runs the two replaced instructions; when
  the villager (`rdi`, set from `rcx` at 4ddb153 and not written before the test) is on the DLL's list it sets
  `r8 = rdx` (the list looks empty to the chooser), then jumps back to the `je` at +29. Nobody on the list: the
  chooser behaves exactly as before. `CHOOSE OFF` and `ALLOFF` put the bytes back (`ALLOFF` also empties the list).
- `CHOOSE SET <hex>,<hex>,...` (or `-`): the whole list, at most 256 addresses, 8-aligned, never null. The stub only
  compares; it never reads through an address, so a villager that died does no harm.
- Status: `CHOOSE on|off n=<on the list> hits=<chooser runs let through> sets=<lists> refused=<bad commands>`, or
  `CHOOSE unavailable <why>`.
- Offline: tests L1-L4 in `test/patch_test.c` (a chooser function with the game's bytes that runs: a listed type
  stops it, a named villager passes, another villager stays stopped, bad lists refused, OFF / ALLOFF byte-identical,
  two hits, other bytes, no site): 225 passed, 0 failed.


## NOREGION: a work hit at a building that has left the game no longer reads through null (the lead, 2026-11-13)

Why: a friend's game closed twice (lane 36 run fin; the lead's run lead7) with an access violation reading address 8,
in the game's own tick: a villager's work hit at a building demolished a moment before. The record is in
`research‚6-11-10-game-probe\lanes\lane_s21_0\crash_demolish_site
otes.txt`.

- What the game does: the routine for the goods of a work hit (4db43c0) asks the worked building for its region and
  hands it, unchecked, to two routines that count goods for a region (4c4a960 and its twin 4c4aa70; 12 and 26 callers).
  Both begin with `GetWorld(region)`, which reads through the region. A building taken out of the game has no region.
  The same work-hit routine checks the same value for null 0xC0 bytes after the crashing call (4db5546).
- Sites: signatures `NOREGION` (4c4a960) and `NOREGION2` (4c4aa70), each with one hit in 0.8.117. They differ first in
  the displacement of the jump after the first call (DA / D7), which the patterns hold; the four displacement bytes of
  the first call itself are wildcards, so a site already redirected is still found.
- `NOREGION ON`: the first call of both routines goes to a stub near the module (26 bytes): a null region returns
  null at once, and the routine then leaves exactly as it does for an object without a world; any other region goes on
  to the game's `GetWorld` untouched. Only the four displacement bytes of each call change (inside one 8-byte block
  each). Both or none. `NOREGION OFF` and `ALLOFF` put them back.
- Status: `NOREGION on|off hits=<null regions turned away> refused=<bad commands>`, or `NOREGION unavailable <why>`
  (a signature without exactly one hit, a first call that does not go into the game, the two calls going to different
  places).
- Used by `coop_patch.lua` on a friend's copy, with NOKILL and NOROUT, when a world attaches. The host's copy stays
  unpatched.
- Offline tests: section N of the mechanism test (both routines run in a synthetic image; a null region reaches the
  stand-in for `GetWorld` when off and never when on; byte-identical after OFF and after ALLOFF; unavailable with two
  hits, with a call that leaves the image, with only one of the two routines, with neither).

## PICK: the job chooser's pick held to the host's task (lane 35)
Evidence: `research/2026-11-10-game-probe/lanes/lane_s21_35/report.txt`, item 1. With CHOOSE a friend's seller, miner
or ox leader chooses its next work cycle itself, and its chooser does not always pick what the host's did (a miner the
fetch of maintenance supplies or a carry, an ox leader another ox or a fetch): 4 to 11 gives per host start, the board
giving the host's task back each time. PICK makes the chooser end, for a villager on its list, with exactly the task
the board names.
- Sites (offline: exactly one hit each in 0.8.117; refused on another build by the known timestamp and image size):
  `SETTASK` (SMUnit::setTask, 4e1cab0; its first 9 bytes `push rbx; sub rsp,120h` checked) and `CHOOSECALL` (the
  unit's think, 4e05a94; the call at +22, 4e05aaa, must be an E8 that reaches the routine holding CHOOSE's pattern at
  +1DCh, whose first 8 bytes are checked). Each hook fits in one 8-byte block.
- `PICK ON`: the chooser call is pointed at a stub that notes the unit while the chooser runs (`pick_enter`,
  `pick_leave`); setTask's entry jumps to a stub that calls `pick_hook` and then runs the two moved instructions.
- `PICK SET <unit>:<type>:<target unit>,...` (hex; target unit 0 = any; `-` = none; at most 256). For a villager on
  the list every setTask of that type (and target unit) is kept as its record (0xD8 bytes, the FTask; target unit at
  +A8h). When its chooser ends with another task, that pick is let through and, as the chooser returns, setTask runs
  once more with the kept record (the game's own setTask ends the pick with the game's own routine). With nothing kept
  the pick stays ("left"; the board gives the task back as before). A villager put on the list while on that task has
  it kept at once (its Tasks at +898h / +8A0h). Outside the chooser nothing is changed.
- Only the game thread that ticks the DLL is handled (others counted as `other`); an exception in the hook switches it
  to pass-through (`faults`).
- Status: `PICK on|off n= same= subst= left= kept= seeded= other= sets= bad= faults=` and `PICKS replaced <type>x<n>
  ...` (its own first word, so the mod's status parser keeps the PICK line), or `PICK unavailable <why>`.
- Offline: tests M1-M4 in `test/patch_test.c` (a setTask with the game's first 31 bytes, a chooser with the game's
  first 8 bytes and CHOOSE's pattern at +1DCh, a think with the CHOOSECALL pattern; the chooser's other pick followed
  by the kept task, the board's give kept, the target unit held for an ox, seeding, bad lists, OFF / ALLOFF
  byte-identical, another build, a call to another routine, another setTask entry): 307 passed, 0 failed; the offline
  signature check 44 of 44.

## FIELD: a field's and a garden's plants on the host's word (lane 40)

Why and what was measured: `research/2026-11-10-game-probe/lanes/lane_s21_40/report.txt`. A field or a backyard garden
is a list of plants that is not reflected (SMBuildingMaster +530h, 0D0h bytes a plant, the reflected struct `Plant`):
crop +0, place +8, plowed +20h, growth +24h, instance +28h, typeBefore +48h, yield +4Ch, the drawn transform +50h, the
instanced mesh +B0h, a fertility cell +BCh (not reflected), FertilityWhenPlantedQuant +C1h. Each copy's villagers plough,
sow and harvest point by point at their own moments, and a point grows from its sowing.

**Who changes plants** (static read, lane 40 `static/`): the plough step 4d18360 (+0.5 and a brush stroke on the
ploughed-ground target), the sow and the harvest of a villager's work hit (inline in 4dc5270), the day's growth 4d156d0
(growth + the field's daily step for every growing plant, the yield when a plant is ripe, the fertility it takes),
eraseCrops, setCropType. Every one of them calls `UpdateFieldCache` (FCACHE, 4d217d0) right after; it counts the plants
into the panel's numbers (sown, unplowed, ready, average growth, yield, operation mode).
**What a player sees:** each plant's mesh instance, drawn by FDRAW (4d241b0, field, index) from crop and growth (the
engine draws a marked field 50 plants a tick), and the ploughed ground, painted by FPAINT (4c9def0, engine, place,
amount, add): the plough step paints +0.5 with add = 1, a harvest -10 with add = 0.

**Signatures** (function entries, exactly one hit each, and the known build: the plant offsets are not in a signature):
`FCACHE` 4d217d0 (hooked: its first 8 bytes, push rbx / push r13 / sub rsp,38h, one aligned qword), `FDRAW` 4d241b0 and
`FPAINT` 4c9def0 (called).

| Command | Does |
|---|---|
| `FIELD HOOK ON` / `OFF` | friend: FCACHE's entry jumps to a stub that, for a held field, puts every plant that differs from the host's back (crop, plowed, growth, typeBefore, yield, fertility byte), draws it with FDRAW (more than 48 in one call: from the tick's queue, 64 a tick) and paints its ground again with FPAINT (cleared, then the host's plowed), then runs the routine. OFF also drops the held fields |
| `FIELD HOLD <b>` / `DROP <b>` / `FORGET` | hold a field (its object index and name are kept and checked) / let it go / all |
| `FIELD SET <b> <n> <ops>` | the host's changes into the shadow and the plants (drawn, painted), then the game's own UpdateFieldCache (this DLL's own call passes the hook) |
| `FIELD CHECK <b> <n> <crc>` | the host's checksum against this copy's plants: `checkok` / `checkbad` |
| `FIELD WATCH <b>` / `FULL <b>\|ALL` / `POLL` | host: watch a field; send all of it; write `field_out.txt`, one line per changed field `<b hex> <n> <crc> <ops>` (nothing of the game is patched on the host) |
| `FIELD CUT <b> 660\|6A8\|6B8 <n>` | cut a point list (FieldPoints, fieldBorderPoints, finalBorder) to n points |
| `FIELD DUMP <b> <tag>` | `field_dump_<tag>.txt`: the list's header and every plant (read only) |

ops = `op;op;...`, op = `<ranges>=<crop>.<plowed hex>.<growth hex>.<yield>.<typeBefore>.<fertility>` or
`g<step hex>:<ranges>` (growth = min(growth + step, 1): the day's growth of a run of plants in one op); ranges =
`a-b,c,...`. Floats travel as their bits, so a friend's plants are bit-equal to the host's.

Every half second an audit compares every held field with the shadow (`leaks`, put back). While the engine draws a
held field by itself (50 plants a tick, its own 5 % rule for the size) every drawn size is set to the host's in the
same tick (`followed`); the host's drawn size travels as `d<ranges>=<x>.<y>.<z>` and is written with the mesh's own
UpdateInstanceTransform (vtable +B58h, as the drawing routine calls it), and the counted numbers as `c<12 x 8 hex>`
(written over the game's own after its count: the hook wraps UpdateFieldCache). A plant count that differs
from the host's is counted (`countdiff`) and only the common plants are held.
**Status:** `FIELD hooked|idle|unavailable <why>` (never the word on: the host's "everything off" rule looks for it) and
`fields held= watched= hookcalls= heldcalls= restored= drawn= painted= queued= nodraw= sets= setpts= grows= beyond= unknown=
polls= lines= outbytes= checkok= checkbad= audits= leaks= cuts= countdiff= gone= otherthread= dumps= refused= faults=
ushook= usset= uspoll=` (microseconds inside the hook, SET and POLL).
**After a game update:** FIELD needs its three signatures with exactly one hit, FCACHE's first 8 bytes as known in one
aligned qword, and the known build; anything else: `FIELD unavailable <reason>`, nothing written, and the friend's
fields are its own villagers' again (as before lane 40).
**Offline:** tests Q1-Q4 in `test/patch_test.c` (the three routines with the game's first bytes that run; SET writes,
draws and paints; a change of this copy is put back before the count sees it; a growth step; the audit; refusals; POLL
whole, nothing, a step and a record; CHECK; CUT; HOOK OFF and ALLOFF byte-identical; a fault in the hook; another
build, two hits, no hit).

## DIST: a house's market goods on the host's word (lane 42)

Why and what was measured: `research\2026-11-10-game-probe\lanes\lane_s21_42\report.txt`. A house's
`distributedGoods` (SMBuildingMaster +E90h, the game's 24-byte goods records) is rebuilt by the region's distribution
(4c3c490). The region's market routine (4c485e0, a slice per tick) runs it when a pass over the market list is done; a
pass is asked for by every stock change (recountStorage), a family moving, a fire. Its input is a pool made from the
region's market buildings, which on a friend differs for seconds: the friend's houses showed a list the host had had
5 to 20 s before (lane 42 base: 0.36 differing values a day in the player's houses, 1.8 in the rival's).

**What it does.** The market routine's one call of the distribution (DISTCALL, pattern 4c49210, the call at +15) is
pointed at a stub: the game's own distribution runs as before (its counter, its pool, its second set of buildings),
and right after it every house of that region the host named gets the host's list back: length 0, then each record
appended the way the distribution itself does (length + 1, the game's own grow helper when the room is used up, the
record zeroed, type and amount), +459h = 1, the region's refresh (REFRESH, mode 1, no list) and the building's surplus
cache (DGSURP 4d24b60). A list already equal is not written. Only the call's four displacement bytes change.

**Commands.** `DIST ON` / `DIST OFF` (also ALLOFF). `DIST SET 0x<building> <type>:<amount>,...|-`: the host's list
for a house, written at once when DIST is on, the building is the same object (address, +0Ch, +18h) and has a region
(+2C8h); kept for the write-backs. `DIST FORGET`: every house dropped. Status: `DIST on|off houses= sets= writes=
putbacks= calls= otherthread= refused= faults=` or `DIST unavailable <why>`.

**Signatures** (at the end of the DLL's table): DISTCALL, DIST (4c3c490 entry), DGROW (4c3c90a: the distribution's own
call of the grow helper at +68; the helper 4a62c30 has four identical copies, so it is reached through that call and
checked by its first 26 bytes), DGSURP. REFRESH (GOODS) is needed too. After a game update anything else: `DIST
unavailable <reason>`, nothing written; a friend's market goods are then its own game's again.

**Lua.** coop_patch.lua switches DIST on with GOODS on a friend (exact mode), off and FORGET before a load and at a
release. coop_facts.lua: the host sends `F D <bkey>=<type>:<amount>,...;...` on change and with each keyframe; a friend
hands each house to `DIST SET`.

**Offline tests (2026-11-13):** 62 of 62 signatures hold on the lane's game file; mechanism test 413 passed (D1 to D5:
the call's bytes only, the write at SET with the game's grow helper, the write-back in the same call, another
region's house left alone, an equal list not written again, a house without a region not written, another object at
the address dropped, five bad forms refused, OFF and ALLOFF byte-identical, unavailable when the call reaches another
routine, when the grow helper starts otherwise, without REFRESH, on another build); image test 15 passed.

- Round six (PICK GONE): `PICK GONE <hex>,...` names objects that left the game or are leaving it (a demolished
  building, a villager or an animal gone). Every entry whose villager is one of them, or whose kept record names one
  (target / final building +98h / +A0h, target / final unit +A8h / +B0h, resource +C0h), or whose target unit is one,
  is taken off the list at once; the last 256 addresses are remembered and a record naming one is never kept, seeded
  or set again (`stale`). The job board sends it when the town module applies or sends a DEMOLISH (before the game
  removes the building) and when a villager or animal leaves its lists. Status adds `gone= dropped= stale=`.

- Round seven (FOLLOW, part of PICK ON when signature `SETTHUNK` is found: the reflected setTask's call of setTask at
  4afd42d, one hit at 4afd41b, its call must reach SETTASK): a Follow (task type 41) the GAME sets for a villager the
  board does not name for that ox (setTask's return address is not the reflected setTask's) gets another record: the
  host's Follow the board gave that villager (kept), else the villager's own current task (copied); with no task it
  goes through. Never refused: the game's guide path (4e15ab0) plans the task it has just set (4e1b950) and writes into
  Tasks[0] unchecked (a refusing first version closed 3 of 4 friends' games, writing 0x8). Status adds `follow=`
  (replaced), `followok=` (the board's leader of that ox), `followleft=`. Offline tests O1: 465 passed, 0 failed.

## REGSET: a region's two building sets (lane 35, round six)
Evidence: `research/2026-11-10-game-probe/lanes/lane_s21_35/report.txt`, part 2. A friend's game closed in the job
chooser after a demolish (access violation reading 0xffffffffffffffff / 0x10000000001 in 4d45360, stack 4d45360 <-
4da3550 <- 4e0e480 <- 4e15c10 <- 4e13b20 <- 4de1c60 <- 4ddb130). READ in the game file: looking for a building to fetch
from, the chooser walks two building sets of the workplace's region (+5A8h, +5F8h; 4e0e480 at 4e0e752 / 4e0e75f) and
reads each member's stock list (+460h, 4d45360). The game takes a building out of those sets in the routine
Engine::eraseBuildingReferences (4cb0e40, called by demolish 4d32ef0) calls at 4cb1234 (4c53480), and only through the
building's region (+2B8h, virtual +10h): with no region there, the building stays a member. On a friend a demolished
building has no region (the lead's notes, crash_demolish_site/notes.txt); freed later, the next walk reads freed memory.
- Site: signature `REGSETS` (one hit at 4c535cb in 0.8.117): in 4c53480 the two calls that take the building out of
  +5A8h and +5F8h; both must reach the same routine in the module, which must start with the 16 known bytes of the
  game's set removal (4c4bb90: it hashes the key and never reads through it). Refused on another build (known
  timestamp and image size). Nothing is ever written to the game's code.
- `REGSET LIST <region hex>`: writes `regset.txt`, one line `+5A8|+5F8 <member>` per member of both sets, walked by
  their hash chains (no member is read); `END` last. The region must look like an object of the game (committed, its
  vtable in the module).
- `REGSET DROP <region hex> <hex>,...`: the game's own set removal for both sets with each address.
- The job board (friend): every 5 s and 0.5, 1.5 and 4 s after a demolish, every region's sets are listed and a member
  that is no building of the engine any more (`eng.buildingArr`) is dropped; the friend's log says how many.
- Status: `REGSET available lists= members= drops= dropped= bad= faults=` or `REGSET unavailable <why>`.
- Offline: tests R1-R4 (a TSet laid out as the game keeps it, a set removal with the game's first bytes, the REGSETS
  pattern; LIST, DROP, bad forms, PICK GONE, another build, calls to two routines, no site): 405 passed, 0 failed; the
  offline signature check 59 of 59; image test 15 of 15.

## MEN: a squad's man walks to the place the host's game gave its own man (lane 43)
Evidence: `research/2026-11-10-game-probe/lanes/lane_s21_43/report.txt`, item 1. Each copy's squad AI gives each man his
own place (his slot, the enemy man he goes for, a walk about a camp), so in a melee and in a camp at rest the copies'
squads stood 2 to 7 m apart (bandits up to 18 m); a place written from Lua is walked back within 0.5 s (lane 38, p2).
- Sites (exactly one hit each; refused on another build: the record's layout is not in a signature): `MPATH` (the path
  request, 4dbc910: man, a point record of 0x88 bytes by value with the place at +8 / +10h / +18h, a flag, a list by
  value; its first 8 bytes push rbp/rsi/rdi/r12/r14 checked, one aligned qword) and `MSLOT` (tickSquad's call of it for
  each man, 4d8850f: its E8 at +106 must reach MPATH; its two rip-relative constants, at +6 and +30, are copied by GO).
- `MEN HOOK ON`: MPATH's entry jumps to a stub (a C wrapper, then the 8 moved bytes and a jump back). `MEN HOOK OFF` and
  `ALLOFF` put the bytes back and empty the table. The status never says "on" (on the host the hook only reads).
- Friend: `MEN SET <hex>=<x>,<y>,<z>;...` (cm): the host's place for each man, put into every request of his before the
  routine runs; a place 50 cm or more from the last one he was given is given at once ("GO": the routine called with a
  record built as tickSquad builds it, after the address passed the object check: committed, vtable in the module).
  `MEN DROP <hex>,...` and `MEN FORGET` take men out. Addresses in the table are compared only, never read through.
- Host: `MEN WATCH <hex>,...` / `UNWATCH`: the hook notes the place each request of these men asks for (nothing is
  changed). `MEN POLL` writes `men_out.txt`, one line `<hex> <x> <y> <z>` per watched man whose asked place moved 25 cm
  or more since it was last written.
- Only the thread that ticks the DLL is handled (others passed through and counted); an exception in the hook switches
  it to pass-through at once, the next tick takes the hook out and empties the table, the item stays unavailable.
- Status: `MEN hooked|idle|unavailable <why>` and `menstat held= watched= calls= subst= seen= gos= gofail= ce0= sets=
  setmen= polls= lines= outbytes= drops= forgets= full= other= refused= faults= ushook= usgo= uspoll=` (microseconds).
- Lua: `coop_x_men.lua`. Offline: tests V1-V5 in `test/patch_test.c`; the offline signature check 68 of 68.
- Own places (host, lane 48): `MEN HEREAT <hex>` (the offset of SMUnit.realPos from reflection; 0 = off). Then each
  `MEN POLL` also writes `H <hex> <x> <y> <z>` for each watched man whose own place moved 1 m since it was last written
  (memory committed when first read, vtable in the module at every read, under SEH). `menstat` adds `hoff= heres=
  herelines= herebad= ushere=`. Round 2's `MEN WAYS` (path points) was taken out by lane 48 (own places were better).

## GOODS and a demolished building (lane 46)

Why: `research\2026-11-10-game-probe\lanes\lane_s21_46\report.txt`, job 1. The only routine that puts a building into
its region's two building sets (+5A8h, +5F8h, walked by the job chooser) is the building's surplus cache (4d24b60,
DGSURP; recountStorage calls it). The game's demolish empties the building in place into its refund pile, calls
refreshBuildingStorageCache(region, building) and later takes the building out of the sets. With GOODS on, that refresh
was a "change of a frozen building": the amounts could not be put back in place (the list has no room), so the next tick
repaired the building with addToInventory, recountStorage ran, and the building was in the sets again: freed later, read
by the chooser (the friend's crashes of 2026-11-13).

**DEMREF** (K_SITE, pattern at 4d34336, its E8 at +22 must reach REFRESH): a hooked refresh that returns right after that
call names a building being demolished. It is forgotten and marked gone (address, object number, name): no put-back,
no repair at the tick, no audit, no taking in (a lord's building's first change, a mod write), no DIST write. Without
the signature GOODS works as before and only the Lua marks hold.

**Commands.** `GOODS GONE <0xaddr>,...` marks buildings from the Lua side (the town module at a DEMOLISH, before the game
removes them); such a mark lasts 15 s. `GOODS DEMRULE OFF|ON`: test switch (the site is not used).
Status line `goodsgone site=<0|1> rule=<on|off> demolished= marks= putskip= fixskip= auditskip= takeskip= modwrites=
distskip=` (modwrites: mod writes into a building gone; the Lua stock writer is meant to send none).

Offline (P1-P5): the demolish's refresh forgets the building, no repair at the next ticks, a later game change and the
audit leave it alone, a mod write is counted and does not freeze it; with DEMRULE OFF the tick repairs it (the fault);
GOODS GONE marks; DEMREF missing or its call elsewhere: GOODS on, `site=0`.

## GUIDE: who guides which ox (lane 49)

The game links a guide to its ox in a field of the villager that is not reflected, `+330h`. Its guide assignment
(4e15ab0, signature `GUIDE`: from its entry to its first write, "cmp/mov [villager+330h], ox") writes it before it gives
the Follow; the Follow itself (4db0d80 -> 4dd72e0) ends at once when the field is null, and the ox's think (4dd74c0)
waits for the first unit of its region that holds it. The job board's Follow on a friend goes through the reflected
setTask, which does not write it. `Engine::destroyUnit` clears every unit's `+330h` that names the unit it destroys.

    GUIDE LIST <u>,<u>,...                 guide.txt: "<u> <its +330h>" per unit, then END (read only)
    GUIDE SET <ox> <leader> [<u>,...|-]    each listed unit other than the leader holding the ox lets go; the leader holds it
    GUIDE CLEAR <gone>,... <u>,...         each listed unit holding one of the gone addresses lets go

Every address must look like an object of the game (8-aligned, committed, its vtable in the module); the known build and
the signature exactly once; both displacements in the matched bytes must be 330h. Nothing is patched or called.
Status: `GUIDE available sets= taken= clears= cleared= lists= bad= faults=`. Offline G1-G4.

## FELL: a tree being felled falls at the host's moment (lane 54)

A felling does not end at a stroke count. The work-hit routine (4dc5270), felling branch, finds the tree in a list of
its target building's region (`region+CD0h`, records of 28h bytes, count at `+CD8h`; the lookup is 4c63c60, signature
`TREEFIND`: a record's first three doubles are the tree's place, matched within 1 cm), takes 5.0 from the record's float
at `+18h` at every stroke (4dc5a97, signature `FELLHIT`) and lets the tree fall once that float is no longer above 0
(4dc5c73). A record is made when a villager reaches the tree. On a friend the villager reaches its tree at its own
moment, so the tree still stands there when the host's has fallen, and the job board's next task then ends the felling.

    FELL <region> <x> <y>     the record of the tree at that place (cm, within 1.5 cm on both axes) gets 0 at +18h when it
                              is above 0: this copy's villager's next stroke fells it by the game's own code

The region address must look like an object of the game (8-aligned, committed, its vtable in the module); the list must
be committed memory with at most 20000 records; the known build and both signatures exactly once; the list's
displacement in both and the stroke's two +18h must be as known. Nothing is patched or called: one float is written.
Status: `FELL available fells= already= misses= bad= faults=`. Offline F1-F5.

## ENDHOLD: a task ends on the host's word (lane 49, round four)

The game's end of a unit's tasks is 4dfb960 (signature `ENDTASK`, its entry). ENDHOLD ON moves its first 5 bytes into
a stub (a trampoline runs them and jumps back). For a unit on the list whose current task (Tasks[0]) is the listed type
at the listed building, an end called from the unit's own task steps (return address in 4db0000..4de0000 of the known
build: the work-hit routine, the walk and carry steps) is let through and the same task is set again at once with the
game's own setTask (a copy taken before the end). Every other end passes: from setTask (a new task), from outside the
task steps (death, demolish, a squad's call-up, a family's removal), a dead unit (+30Ch), a unit on the list longer
than the ceiling, the re-set's own end.

    ENDHOLD ON | OFF
    ENDHOLD SET <ceiling ms, hex> <unit>:<type>:<building>[:<start number>],... | -     the whole list; the ceiling counts from a unit's first held end of that start
    ENDHOLD RANGE <lo> <hi>                                           the callers' range (offline test)

Status: `ENDHOLD on|off n= held= passed= expired= skipped= faults= other= sets= bad=`. Offline E1-E3.

## REPORT: the player's "Make Bug Report" button (lane 61)

`coop_report.h`. The mod writes `patch_report_job.txt` in this DLL's I/O folder (UTF-8, tab-separated fields):

    open 1|0                       open the reports folder in Explorer when done (the mod sends 0 while link\dev_report_noopen.txt exists)
    zip 1|0                        make the zip (0: keep the folder; the mechanism test reads the copies)
    name <from><TAB><to>           a Steam display name (3 bytes or more) and the slot name that replaces it
    file <source><TAB><name><TAB><cap bytes>[<TAB><start byte>]    a file to copy under <name> (letters, digits, - _ . only) from <start> on; past <cap>, its start (a quarter, at most 1 MB) and its end

then sends `REPORT <stamp>` (letters, digits, `-` and `_`). Works also while the DLL is off. While a report is being made, another REPORT changes nothing. Every path written is built
from this DLL's own folder: `<mod>\link\reports\report_<stamp>\`, then `<mod>\link\reports\report_<stamp>.zip` made by
Windows' own `%SystemRoot%\System32\tar.exe -a -c -f` (Windows 10 1803 and later), started with `CREATE_NO_WINDOW` in
the reports folder with relative names only; the folder is removed after a good zip. No tar, a tar failure or more than
120 s: the folder stays, a partial zip is removed. Explorer is started as `explorer.exe /select,"<zip>"`. Copies, tar
and Explorer run on the report's own thread; the game thread only reads the job.

Every copy is scrubbed (`coop_scrub.h`, the same rules as the mod's own log): the folder after `\Users\` (any case, when
another separator follows) and the Windows user name (`USERNAME`, the last folder of `USERPROFILE`) right after a
separator become `<user>`; the job's names become their slot; a Steam id (`7656119` and 10 digits) keeps its last 4
digits (`<id..1234>`). The DLL's own log lines (`coop_patch.log`) get the same scrub when written.

The first tick makes `<mod>\link`, `link\sessions` and `link\reports` (the mod's Lua cannot make a folder without a
console window).

Status: `REPORT idle | running report_<stamp> | done report_<stamp>.zip <files> [opened] |
folder report_<stamp> <files> <why> [opened] | refused report_<stamp> <why> | refused - <why>`. Offline RP1-RP3.

**0.9.2 (lane 62): the Steam piece's two files.** Two more job verbs, with the fields of `file`: `steamlog <source><TAB><name><TAB><cap>` for `coop_steam.log` and `steamstatus ...` for `steam_status.txt`. Their Steam names are taken out by the SHAPE of the line before the common scrub (`coop_scrub.h`, `scrub_steam`), because the mod may not know those names any more (after a lobby was lost the status lists nobody; the log holds names of earlier sessions) and the name list takes only names of 3 bytes or more: in the log `<name> (<id>) connected as friendN` gets `friend N` for the name and the "is in the lobby but the co-op mod ..." note gets `<name>`; in the status a player line `<slot> <id> <state> <ping> <name>` gets `host` or `friend <slot>`; the log's `first callback ...: first bytes <hex>` lines (raw callback bytes: whole Steam ids in hex, which the rule for decimal ids does not see) lose their bytes. A job takes 40 files now (24 before). Offline RP4 (a name not in the job, a 2-letter name, a name with spaces, parentheses and digits, a last line without a line end, a first-callback line; mock names and ids): 718 passed, 0 failed (702 before).
## MAINT: a building's maintenance on the host's word (lane 67)

Evidence: `research\2026-11-10-game-probe\lanes\lane_s21_67\report.txt`. A building's MaintenanceComponent
(SMBuildingMaster +348h) has no reflected fields. Its trackers are a map at +A8h (the game's TSet: elements of 20h
bytes, the key's goods list at +0, DurabilityLeft at +10h; allocation bits inline at +B8h or on the heap at +C8h, their
count at +D0h); the cached status is the byte at +A0h, the slider the int32 at +F8h. The day routine wears each tracker
by 1, 2 or 4 (4bb3410), a work hit or a delivery refills one from the building's own stock (4d16b40). On a friend that
stock is the host's word, so its trackers only ran down.

**Commands.** `MAINT READ <c>,...` writes `maint.txt` ("<c> <status> <slider> <goods+goods>=<left>,...", "?" for
what does not look like a component, `END`). `MAINT SET <c> <status> <goods>=<left>,...|-` keeps the host's word for
that component and writes it now and at every tick while the object's number (+0Ch) and name (+18h) are as at SET (a
type the component lacks is counted as a miss). `MAINT DROP <c>,...`, `MAINT FORGET` (also ALLOFF). The slider is not
held (a player action: coop_town.lua MAINT). Data only: nothing is called, no code is patched.

**Signatures:** MSTAT (4b98590, the status +A0h and the map +A8h), MDECAY (4bb3410, the slider +F8h and the map),
MDECSUB (4bb35eb, a tracker of 20h bytes, +10h). Known build only; anything else: `MAINT unavailable <why>`.

**Status:** `MAINT available held= sets= writes= reads= misses= gone= bad= faults=`.

**Offline tests (2026-11-17):** 80 of 80 signatures hold on the lane's game file; mechanism test 727 passed (MT1 to
MT4: READ of a synthetic component, SET writes held types only, the next tick puts this copy's own wear back, another
object at the address drops the entry, DROP, FORGET, seven bad forms, ALLOFF, another build, a pattern twice, a wear at
another offset); image test 18 passed.
