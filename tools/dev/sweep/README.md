# Parity sweep: what every panel draws, host against friend (lane 68)

**Status: never run in a game.** Written on 2026-11-17 while the owner was playing. The walker and the diff pass
their self-tests without the game (below). Everything that touches the game is a first run: see "First run".

## Why

The mod's own checks (the daily fingerprint and the wide sample in `coop_world.lua`) compare only the values somebody
listed. In real play a Woodcutter's Lodge read "Maintained, Fair 100 %" on the host and "Needs Maintenance, Modest
50 %" on a friend (ledger G134), and no check saw it. The sweep needs no list of fields: it compares whatever the
panels draw.

## How it works

1. `sweep.sh` pauses the game through the host, waits 6 s, and checks that both copies are paused.
2. It starts `sweep_probe.lua` in the test console of both copies. The console call returns at once. A game-thread
   loop then does one small step every 100 ms:
   1. walk the HUD once (top bar, timer, region stats, problems);
   2. for every building of the player, sorted by key:
      - open its panel with the game's own `openBuildingTab`;
      - wait 5 steps, then read tab 1;
      - press each further main tab (the harness's `tab` way), wait, read it;
      - close the panel (`deselect_buildings`);
   3. with `screens = 1`, also: each owned region's panel (`changeSelectedRegionUI`), main tabs 0 to 7
      (`switchTab`), the development panel (`toggleDevelopmentPanel`), the map (`setMapMode`). Each is put back
      afterwards.
3. `sweep_walk.lua` reads one tab in one step. For each shown widget it records:
   - texts;
   - progress bars (Percent);
   - sliders and spin boxes (value);
   - check boxes;
   - combo boxes;
   - widget switchers (which page shows);
   - images (brush name and tint): status icons and rating pips.

   It skips hidden subtrees, and of a switcher it walks only the shown page. The path of each value is
   `class:name#n` per level. Instance numbers are taken off names; `n` is the place among same-named siblings.
4. `sweep_diff.py` pairs the two dumps:
   - panels by building key (`type@x/10,y/10`, the key of the wide log lines);
   - values by tab and path.

   It prints warnings, coverage (each building type: count and how many were swept on both), every difference
   grouped by widget, and counts per building type.

## Release check (one command)

```bash
LANE=n sh tools/dev/sweep/release_check.sh                  # in the release branch's checkout; label = branch_commit
LANE=n sh tools/dev/sweep/release_check.sh rel-0.2.5_x "coop_test_field coop_test_1"
```

It does both saves one after the other. For each save it:
1. checks that no copy of the lane's test folder runs;
2. runs `up.sh` (queues for slots);
3. sweeps every building of the player, every tab, and the screens;
4. runs `down`.

The screens are:
- each owned region's panel;
- main tabs 0 to 7;
- each squad's army panel and unit cards, selected with `selectSquad`;
- the development tree with its trade view;
- the map.

The lord panel and the top bar are in the HUD walk.

It writes `$RUN/release_<label>.txt` with one line per save: PASS or FAIL, panels compared, values read, HARD and
SOFT differences, town lines sent during the sweep, resyncs. Under that line come the differing values by kind of
widget, every hard difference, and the town lines.

Exit 0 means PASS: no hard difference, no town line, no resync, and every sweep finished.

`soft.txt` lists the known differences the owner accepted. Today that is one: a villager's task label a few seconds
out of step (gate 0c). They are listed as SOFT and do not fail. Add a line only with the owner's decision.

The screens and the army panels are desk-tested only (`test_probe.lua`). Their first game run is the first release
check.

## Use

```bash
LANE=n sh tools/dev/up.sh coop_test_rich           # host + friend of your lane (save in your lane's profile)
LANE=n sh tools/dev/sweep/sweep.sh smoke 89         # smoke test: woodcutter's lodges only
LANE=n sh tools/dev/sweep/sweep.sh d20 "" 1         # every building, and the screens
py -I tools/dev/sweep/sweep_diff.py A_host.txt A_friend.txt --out d.tsv --ignore known.txt   # by hand
```

Output goes to `$RUN` (`.devrun/lane<n>/`): `sweep_<label>_host.txt`, `_friend.txt`, `_diff.txt` (the report),
`_diff.tsv` (one line per difference).

**Privacy.** Dumps hold every text the panels show, including lord, villager and player names. They stay in
`.devrun` (git-ignored). Never commit a dump. Quote only the differing widget in a report.

## Safety, as built

- It only reads, apart from the openers named above.
- Every handle is checked alive before use.
- Every game list is read as `local n = #arr; for i = 1, n`. Reading past the end grows the list (memory note).
- Nothing of the game is kept between steps. A building is found again by its key.
- A panel that does not open within 30 steps is skipped and logged (`E <panel> OPENFAIL`).
- After 20 step errors the sweep ends (`#ABORT`).
- Walk limits are 6000 widgets and 48 levels. Hitting one writes a note, never a silent cut.
- `sweep.sh` counts `TOWN sent` lines in both logs and the resyncs before and after. All three must stay 0: opening
  panels fires hooked handlers (see THRESH in `coop_x_town.lua`).
- `sweep.sh stop` is automatic after `SWEEP_MAX` seconds (default 1800).

## First run (what has never been seen working)

| Piece | Proven before? |
|---|---|
| `openBuildingTab`, `deselect_buildings`, the shown `Inventory_C`, the main-tab press, the child walk | yes: the harness's `openb`, `tab`, `ptree` |
| progress bar `Percent`, slider / spin box `GetValue`, check box `IsChecked`, combo box `GetSelectedOption` | no |
| image `Brush.ResourceObject` and `ColorAndOpacity` | no |
| `GetDisplayedEntryWidgets` (list views), `GetActiveWidget` (switchers) | no |
| a stepper started from the console (`LoopInGameThreadWithDelay`) | yes: `lanes/lane_s21_12/probes/campwatch.lua` |
| `switchTab`, `changeSelectedRegionUI`, `toggleDevelopmentPanel`, `setMapMode` as openers | no |
| `lord.selectedBld` as "is this the right panel" | no (written `selected=?` when it cannot be read) |

## Limits

- Tooltips are not walked, because they appear only under the pointer. This leaves out maintenance modifiers,
  yield modifiers, family needs and the treasury forecast. The inventory (`docs/coverage/values.tsv`) marks them
  "tooltip only".
- Only the player's own buildings can be opened. Rival towns are compared by the wide sample only.
- A building type the town does not have is not tested: the report lists the types swept.
- Floaters over buildings, map labels and the minimap depend on the camera, so they are left out.

## Self-tests (no game)

```bash
py -I tools/dev/sweep/test_diff.py       # 15 checks on made-up dumps
lua tools/dev/sweep/test_walk.lua        # 20 checks on a made-up widget tree (plain Lua 5.1 or 5.4)
```

```bash
lua tools/dev/sweep/test_probe.lua       # 6 checks: the whole stepper on a made-up engine, lord and panel
```

**First game run (lane 71, run e1, 2026-11-18): failed.** Every building gave `OPENFAIL no panel after 30 steps` on
both copies. The cause: the panel was looked for with `IsInViewport()`, which is false for the building panel (it
is a child of the main interface). Now a panel counts as open when it is shown and in the viewport or in a parent,
and it is matched by its own `building` (lane 69's way in `coop_x_panels.lua`). When no panel of the building comes
in 15 steps, the probe opens it once more the way a click does (`selectBuildingSilent`, then `openBuildingTab`;
`E ... RETRY` in the dump). The OPENFAIL line now also says how many `Inventory_C` exist and how many are on screen.
The count of town lines in `sweep.sh` printed "0" twice when nothing matched and stopped the script: fixed.
`test_probe.lua` reproduces the panel as the game showed it and passes (6 of 6).

On 2026-11-17 both passed: 15 of 15 and 20 of 20. The walker test was run through a Lua 5.1 library found on the PC,
since no Lua interpreter is installed. `sweep_probe.lua` was only parsed (Lua 5.1), not run.
