# Lane guide: testing and building the co-op mod without the user's mouse

Read this whole file before you start. It is the only context a lane helper gets besides its own brief.

## What this project is

A co-op mod for Manor Lords 0.8.117 (UE 5.5, UE4SS Lua). Each player runs the game; friends play the host's lord and
town on the host's save. Each copy watches its own player's actions, sends them to the host, the host replays them and
tells every copy. `ledger.md` is the work list; its section "Everything still open" is why the lanes exist.

| Where | What |
|---|---|
| `mod/ManorLordsCoop/Scripts/` | the mod: `coop.lua` (core, army orders), `coop_town.lua` (town actions), `coop_realm.lua` (lord: perks, taxes, policies, claims), `coop_world.lua` (stock, events, daily comparison), `coop_join.lua`, `coop_sites.lua`, `coop_ui.lua`, `coop_patch.lua`, `coop_steam.lua`, and one `coop_x_<area>.lua` per lane |
| `research/2026-11-10-game-probe/registry/registry.tsv` | every game class and function with its parameters (grep it first) |
| `research/2026-11-10-game-probe/dumps/*.txt` | fields and functions of the main game classes |
| `research/2026-11-10-game-probe/README.md` | lab notes; the "Session 21" sections describe the method used here |
| `research/2026-11-10-game-probe/probes/p6-call-recorder/` | records which game functions run during an action |
| `docs/coverage/coverage.tsv` | the 119 player actions (the checklist; partly out of date) |
| `tools/dev/` | this harness; `tools/dev/CoopProbe/` is the test console mod that `up.sh` installs into a test copy |

`research/`, `ledger.md` and `docs/coverage/` are the maintainers' notes and are not in the public repository. The
harness itself needs none of them; the rows above that point there are reading for the lead's lanes only.

## Hard rules

1. **The user is working on this PC.** Never send mouse or keyboard input, never move the pointer, never bring a
   window to the front. Everything here works on background windows.
2. **Never touch the real game** (the Steam install of Manor Lords) or the real saves (`%LOCALAPPDATA%\ManorLords\Saved`).
   You only use your lane's copy of the game and your lane's save profile; `env.sh` holds the paths (from `local.env`).
3. **Never kill by image name.** Use `down` (it kills only the copies your lane started).
4. **Memory is the limit: only a few game copies fit on this PC at once, all lanes together** (see "Game slots").
   Run `down` whenever you are reading, thinking or writing code. Use `ONLY=host` when one copy is enough.
5. **Edit only your own files** (your brief names them). Never edit `ledger.md`, the research `README.md`, `main.lua`,
   `tools/` or another lane's files; write what you need changed into your report instead.
6. **Git:** commit in your own worktree as you go. Never push, never switch branches, never touch `main`.
7. **Do not write game lists or records from the console** (it corrupted a copy once). Change state through the game's
   own functions (see "Preparing a state").
8. **A scripted pass is not proof.** Say exactly how each thing was exercised (see "The loop").

## First-time setup (a new PC)

Done once per PC. (On the lead's PC it is done: lane helpers skip this section.) You need Windows, Git Bash,
PowerShell 5 or newer, MSVC (see `docs/BUILDING.md`), Manor Lords 0.8.117, and about 4 GB of free memory per game copy.

1. **Make a test copy of the game.** Pick a folder for test copies outside Steam's library (here `<ML_TEST_ROOT>`).
   Copy your whole game folder (Steam: Manor Lords > Manage > Browse local files; the folder named `Manor Lords`) to
   `<ML_TEST_ROOT>\_ml_test`, so that `<ML_TEST_ROOT>\_ml_test\ManorLords\Binaries\Win64\ManorLords-Win64-Shipping.exe`
   exists. Copy, never move. The tools refuse paths inside a `steamapps` or `SteamLibrary` folder.
2. **Put the mod loader into that copy.** The build the mod is tested on: UE4SS 3.0.1-1218 (git `560411f1`), the
   GitHub archive `UE4SS_v3.0.1-1218-g560411f1.zip` (`docs/BUILDING.md`). Unzip it into the copy's `Win64` folder, so
   `dwmapi.dll` and `ue4ss\UE4SS.dll` are there. In `ue4ss\UE4SS-settings.ini` set `ConsoleEnabled = 0`,
   `GuiConsoleEnabled = 0`, `GuiConsoleVisible = 0`. Keep a copy of that `ue4ss` folder beside it as `ue4ss_dev`:
   `tools/package.ps1` takes the loader from `ue4ss`, else from `ue4ss_dev`.
3. **Fill in `local.env`.** `cp tools/dev/local.env.example tools/dev/local.env` and set:
   `ML_TEST_ROOT` (the folder of step 1), `ML_SLOTS` (an empty folder for the game-slot queue, for example
   `<ML_TEST_ROOT>/_ml_slots`; its name must contain `_ml_slots` and its path must have no spaces, because the slot
   helpers delete folders inside it), `ML_REPO` (this checkout). The file is git-ignored. Git worktrees of this
   checkout use it too. Every script stops with a message while it is missing.
4. **Build the native pieces:** `native\coop_patch\build.cmd` and `native\coop_steam\build.cmd` (`docs/BUILDING.md`).
   `up.sh` packs both DLLs; a worktree without them takes them from `ML_REPO`.
5. **A test save.** `up.sh` loads a save by name from the test save profile `%LOCALAPPDATA%\ManorLords\Saved_Coop\SaveGames`
   (lane n: `Saved_CoopL<n>`). Copy (read only) the files of one of your own saves from
   `%LOCALAPPDATA%\ManorLords\Saved\SaveGames` into that folder (make it if needed) and pass its name to `up.sh`, or,
   once a world is loaded in a test copy, save it as `coop_test_1` (the default name) from the test console:
   `lua host 'lord:requestSaveFile("coop_test_1", "coop_test_1"); return "saved"'`.
6. **Run one session** (Git Bash, in your checkout):
   ```bash
   sh tools/dev/up.sh coop_test_1     # lane 0: builds a test zip, installs it with the test console into _ml_test, starts host + friend, loads the save, waits for the join
   . tools/dev/np.sh; lua host 'return tostring(lord.silver)'     # the test console answers
   down                               # closes the copies this lane started
   ```
   More lanes: `LANE=1 sh tools/dev/lane_setup.sh` copies `_ml_test` to `_ml_test_1` (without the loader) and the
   test saves to `Saved_CoopL1`; then `LANE=1 sh tools/dev/up.sh`.

Good to know: the game windows open at x = 1920 and right of it (a second monitor right of a 1920-pixel main screen;
`wx`/`wy` in `env.sh`). The slot limit is the number in `$ML_SLOTS/count` (default 4). A run's pid files, start token,
scratch Lua and screenshots are in `.devrun/lane<N>/` of the checkout (`$RUN`), one folder per lane, so two runs on
different lanes from one checkout never close each other's copies. The checkout remembers only its last lane
(`.devrun/lane`, written by `up.sh`): when two runs share a checkout, give each its own `export LANE=n`.

## The harness

```bash
LANE=3 sh tools/dev/lane_setup.sh          # once: your copy of the game and your save profile
LANE=3 sh tools/dev/up.sh                  # build this checkout, install into your copy, start host + friend, load coop_test_1, wait for the join
LANE=3 ONLY=host sh tools/dev/up.sh        # host only
LANE=3 sh tools/dev/up.sh coop_test_1 "COOP_TEST_REPAIR=75"   # the friend asks for a resync every 75 s (to test "after a resync")
export LANE=3; . tools/dev/np.sh           # helpers in your shell (every Bash call is a new shell: source it each time)
down                                       # close your copies
```

A full `up.sh` takes about 3 minutes. Batch several changes per restart.

**Game slots.** All lanes share a few game slots (one per running copy; the number is small because of memory).
`up.sh` queues for its slots (two, or one with `ONLY=host`) and `down` gives them back. So:

- Call `up.sh` with a 10 minute timeout on the Bash call. If it answers `BUSY`, do desk work (registry, dumps, code,
  report) and try again, or start it in the background with `WAIT=3600` and carry on reading until it reports.
- Hold copies only while you are actively testing: prepare the whole test batch first, run it, `down`. Never leave
  copies up while you read, think or write code. Aim for sessions under 15 minutes.
- Do your desk research first: a lane that starts the game before it knows what to measure wastes everybody's slots.

| Helper | Does |
|---|---|
| `lua host 'return tostring(lord.silver)'` | run Lua in a copy's console with `tools/dev/lua/lib.lua` in front (`eng`, `lord`, `buildings()`, `mine(b)`, `bAt(x,y)`, `bType(t,nth)`, `bkey(b)`, `cheat()`, `panel()`, `find`, `under`, `cname`) |
| `np file.lua` / `np2 file.lua` | the same from a file, host / friend |
| `openb <type> [nth] [host\|friend]`, `openb xy <x> <y> [who]` | open a building's panel through the game's own `openBuildingTab` |
| `tab <n> [who]`, `names [who]`, `ptree [who]`, `sub <widget> [who]`, `props <class> [who]` | switch tab; list the controls, the tree, a widget's properties |
| `press <name> [who]`, `pressin <parent> <name> [who]` | run a named button's own click event |
| `call <name> <function> <args> [who]`, `callc <class> <nth> <function> <args> [who]`, `gcall <class> <function> <args> [who]` | call any function of a widget in the open panel / of a visible widget anywhere (dialogs) |
| `slide <slider> <0..1> [who]`, `apress <button> <squad> [who]` | sliders; army command buttons |
| `tsent [n]`, `repairs` | last town lines of both logs; number of resyncs |
| `shot $HP x.png` | background screenshot into `.devrun/lane<N>/` (`$RUN`; read it with the Read tool) |

Logs: `$LK/host_log.txt`, `$LK/friend1_log.txt` (what was seen, sent, applied, refused; resyncs; errors), link lines in
`$LK/host.txt`, `$LK/friend1.txt`. Building types in the test town `coop_test_1` (Wirnitz): 3 / 8 burgage plot level
1 / 2, 4 logging camp, 6 trading post, 7 mining pit, 13 marketplace, 18 sawpit, 21 well, 32 charcoal kiln, 34 church,
35 quarry, 59 fisherman, 72 storehouse, 79 livestock trader, 80 granary, 86 forester, 89 woodcutter, 91 / 93 stalls,
97 small stable. It has no manor, no farm, no pasture, no tavern, no retinue.

### A slow link and a slow friend (lane 73)

Two test copies on one PC share the link folder: a line is read some tens of ms after it was written, and `up.sh` caps
both copies at 15 frames a second. A real session over Steam is different (first one measured: 0.1 to 0.15 s each way,
the host at 59 frames a second, one friend at 14 to 22; game speed 1). Two switches of the development build
(`coop_dev.lua`, never in a zip for players) give a copy a slow link and its own frame cap. Both are files in the link
folder (`$LK`), read every 2 s, one line per copy, `#` starts a comment, a line for the copy's own name wins over `*`:

| file | line | what it does |
|---|---|---|
| `$LK/dev_linkdelay.txt` | `<name or *> <D ms> [<B ms> [<jitter ms>]]` | every line that copy READS from another copy's link file is held D ms (plus or minus the jitter) and let out at the next multiple of B ms: late and in bursts, in the order written. Every module gets its lines late. |
| `$LK/dev_fps.txt` | `<name or *> <frames a second>` | that copy's `t.MaxFPS` (0 = no cap). |

```bash
printf 'friend1 150 100 30\nhost 150 100 30\n' > "$LK/dev_linkdelay.txt"       # the default test values: 150 ms each way, bursts every 0.1 s (a real Steam link)
printf 'friend1 1000 500 100\nhost 1000 500 100\n' > "$LK/dev_linkdelay.txt"   # the stress case: 1 s each way, bursts every 0.5 s
printf 'host 60\nfriend1 15\n' > "$LK/dev_fps.txt"                             # the host fast, the friend slow
grep "dev: " "$LK/friend1_log.txt" | tail -3                                   # "dev: LINK DELAY on for friend1: ...", "dev: FRAME CAP ..."
rm "$LK/dev_linkdelay.txt" "$LK/dev_fps.txt"                                   # off again (what is held comes out at once; no frame cap)
```

Only the reading side is delayed: `friend1 1000 500` alone delays host to friend; add a `host` line for friend to
host. Run a walking test at game speed 1 as well as 4: at speed 1 a man moves 1.5 m a second and the men module's
lines come a metre apart (the live stop-and-go march showed only there). What the link really did in a session is in
a friend's log once a minute: `MEN link, last 60 s: round trip ... ms; this PC's clock is ... ms behind the host's; the
host's men lines: ... ms old as they came; longest wait between two ...`. The host's `delay_ms=` (in `APPLIED` lines)
is NOT the link's delay: it holds the difference of the two PCs' clocks (0.3 and 0.9 s in the first real session).
Self-tests without the game: `mod/ManorLordsCoop/tests/lane73/t_linkdelay.lua`, `t_menlead.lua`.

## "Panel press": how a click is exercised without the pointer

Find the shown widget by its object name and call the function a real click runs. Checked once against a real click:
the same line was sent.

- Every button whose class derives from `W_MaterialButton_C`: `press <name>` (it calls
  `BndEvt__W_MaterialButton_Button_K2Node_ComponentBoundEvent_4_OnButtonClickedEvent__DelegateSignature`).
- Other widgets have their own handler: find it with
  `grep "<WidgetClass>" research/2026-11-10-game-probe/registry/registry.tsv | grep BndEvt` (the maintainers' research
  folder) and use `call` / `callc`.
- Dialogs are widgets too (`DemolitionConfirm_C`, `TradeRouteConfirm_C`: `gcall <class> BndEvt__Button_ChoiceA_...`).
- A press also fires on a button the game shows greyed out. Read the game's own "can" first (`canUpgrade` ...).
- It cannot do clicks on the ground (placing, drawing, move orders) or anything that needs the pointer over the map.
  For those: build and test at the level of the game's own function (console call), and write in your report
  "needs a real click". The lead is building a per-copy test pointer for that.

## Preparing a state ("memory", the real way)

Use the game's own functions, on the host; friends follow or get it with the next resync.

- The game's cheat manager: `lua host 'cheat():inf(); cheat():favour(); cheat():wealth(500); return "ok"'`.
  It has `SetSettlementLevel`, `UnlockPerk`, `SpawnRaidersOfType`, `SpawnBanditSquad`, `SettleRaiders`, `Rebel`,
  `RainNow`, `SetFireToNumBuildings`, `GiveItemByName`, `GiveItemByID`, `AddItemToBuilding`, `ChangeTreasury`, `gold`,
  `plenty`, `basics`, `weapons`, `raiders`, `bandits`, `spawnOxen`, `setDay` ... (grep `MLCheatManager` in the registry).
- `lord:ChangeTreasury(n)`, `b:addToInventory({ Type = good, amt = n })` (16 wood, 17 planks, 27 stone),
  `eng:hireMercs(eng.availableMercs[i], lord)`, `eng:spawnCompleteUnit(FName(type), pos, rot, ownerPawn, 0, 0)`,
  `lord:setGameSpeed(4.0)`.
- A building you need and the town lacks: place it through the game's own request functions and give it its
  materials, or load another save. When a state is useful, keep it: `lua host 'lord:requestSaveFile("lane3_manor", "lane3_manor"); return "saved"'`
  (host only; the file lands in your lane's profile) and start later with `sh tools/dev/up.sh lane3_manor`.
- Facts: the player's lord is `eng.playerRef` (not the first `PawnCPP`); the helper lord the mod uses is another pawn;
  after a load both copies are equal, so prepare on the host and rejoin (`up.sh`) or wait for a resync.

## How an action is carried (patterns in `coop_town.lua`)

Your module file starts with `local C = _G.Coop; local T = C.town; local X = T.api` and is loaded after the town module.

```lua
-- 1. one named game function on a building or region: hook it, replay the same call
X.setter("GATE", "SMBuildingMaster", "setGateOpen", "b", "press2", "lane 2")       -- arg letters: i int, b bool, n FName, s string
-- 2. a field the panel's blueprint writes itself: hook the panel's handler, read the field a tick later, write it
X.hook("/Game/.../SomeWidget.SomeWidget_C:BndEvt__...", { "FUEL" }, X.seeWidget("FUEL"))   -- the widget must have .building
X.fieldAction("FUEL", function(b) return tostring(X.int(b.fuelReserve)) end, function(S, b, v) b.fuelReserve = X.int(v); return nil end)
-- 3. anything else: X.hook(path, { "NAME" }, function(self, a1, a2) ... return { k = "NAME", obj = b, addr = X.addrOf(b), ... } end)
--    and X.def { name = "NAME", ready = function(S, rec) return "<fields>" end, apply = function(S, job) ... return "ok" end }
```

Read `FILTER`, `STALLS`, `WAREA`, `REASSIGN` in `coop_town.lua` as worked examples. Things learned the hard way:

- A hook only fires when the game makes the call through its script layer. If a real click runs native code, hook
  the panel's handler instead and read the result a tick later.
- A button can do more than write its field (the stall switch also gives up the stalls). Measure: read the building
  before and after on the host, and compare both copies a game day later.
- The value a panel sends is not always the number the game's check uses (extension type 1 is upgrade 101).
- Lists cannot be lengthened from Lua. Let the game's own code do it (a never-shown copy of the game's widget).
- What the game rolls by itself (offers, quests, rival lords) differs per copy: the host decides and pushes.
- Lord-level values (taxes, perks, policies, claims) are in `coop_realm.lua`, caught by comparing state twice a
  second; army orders are in `coop.lua` (`O <KIND>` lines).

## The loop for one action

1. **Find it.** Registry and dumps: the panel's widget class, its handlers, the game function, the field.
2. **Measure on the host alone**: do it once (press or console call), with the call recorder if unsure; read the
   state before and after. Confirm the friend's copy did not change and nothing was sent (if it is not carried yet).
3. **Carry it** with the smallest pattern that fits.
4. **Both directions on two copies**: host to friend, friend to host; values equal on both; the line and the delay
   from the logs.
5. **After an in-process resync** (`COOP_TEST_REPAIR=75`): once more, at least one direction.
6. **Soak**: two to four minutes at speed 4 with the new controls used and a demolish; `repairs` must stay 0; compare
   the per-building lines of both copies (`np tools/dev/lua/t_bsec.lua` on both, diff); no line of your kinds that
   nobody pressed.
7. **Write it down** in your report with the evidence (lines, numbers) and how it was exercised:
   "press" (panel handler), "console" (game function called from the console), "real click" (not possible for you).

## Your report

(Lanes of the lead.) Write `research/2026-11-10-game-probe/lanes/lane_s21_<n>/report.md` (plain, short, tables): one row per action with
state (done / partly / not done), how exercised, both directions, after resync, soak, and what is left with the
reason. List every fault you found in existing code, anything you need changed in files you may not edit, and the
saves you made. Your final message to the lead is a summary of that file: do not claim more than the report shows.
