# How it works

For developers. Plain words, about two pages. The detail is in the module headers and the two native READMEs.

## The idea

Manor Lords has no multiplayer and no network code we can use. So **every player runs the full game**.
The mod keeps the copies in line, and **the host is the referee**.

```
Friend's PC                                   Host's PC
-----------                                   ---------
player clicks  -> shows at once on his copy
mod sees the action -> one text line   ---->  mod replays it with the game's own function,
                                              through an invisible "helper lord"
copy follows the host   <----  text lines     host sends results and the numbers that matter
own villagers keep working (follow the host)  own villagers keep working (the truth)
copy differs too much  ---->  asks             host saves; that copy loads the save
```

Rule for all work: **keep the game as vanilla as possible.** Use the game's own functions first.
Write own code only where the game has nothing. Every native piece checks itself at start-up and switches off after a game update.

## The three parts

| Part | What | Where | Job |
|---|---|---|---|
| Lua mod | Lua scripts run by the UE4SS mod loader | `mod/ManorLordsCoop/Scripts/` | Everything about the game: watch actions, replay them, push values, joins, the menu |
| Native patch | `coop_patch.dll`, plain C, x64 | `native/coop_patch/` | Small in-memory patches and hooks, mostly on a friend's copy; calls to game routines; fast reads |
| Steam piece | `coop_steam.dll`, plain C, x64 | `native/coop_steam/` | Invite-only Steam lobby, messages between players, the save sent to a joining friend |
| Mod loader | UE4SS 3.0.1-1218 (third party, MIT) | bundled in the zip | Loads the Lua mod into the game |

Both DLLs have **one export** each (`coop_patch_tick`, `coop_steam_tick`). The Lua mod loads them with `package.loadlib` and calls them once per frame on the game thread. They talk to the Lua mod **through files** only.

- `coop_patch.dll` has **no network code**. It never changes the game file on disk. Each item is found by a code signature (77 today); an item whose signature does not match is never written.
- `coop_steam.dll` uses the game's **own, already loaded** Steam library. It never starts Steam itself. No other host, no server, no update check, no telemetry.

## How a copy is kept in line

1. **Actions.** A player's action shows at once on their own copy. One line goes to the host. The host replays it with the game's own function, through an invisible helper lord, so the host's own mouse and selection are not disturbed. All copies get the result.
2. **Pushed values ("exact mode").** The host sends the numbers players read: each building's stock, the region's totals, approval and its factors, public order, wealth, population, what each villager holds. On a friend's copy, native hooks stop the game from changing those values by itself (items `GOODS`, `TOTALS`, `HOLD`).
3. **Host-only outcomes.** Where a result must be exact, the friend's game is stopped from deciding it, and the host's result is applied: deaths and routs in battle (`NOKILL`, `NOROUT`), the end of a building site (`NOFINISH`), a tree falling (`FELL`), the end of a villager's task (`ENDHOLD`), which job a villager picks (`CHOOSE`, `PICK`).
4. **Made on friends.** What exists on the host but not on a friend is made there: a family, a rival lord's building, a squad.
5. **Resync (last resort).** When a copy differs in a way values cannot repair, the host saves, and **only that copy** loads the save (`single`, the default). `resync = all` in `coop.cfg` makes every copy load. **Joining is the same operation.**

Places of squads and villagers are not pushed as hard facts. Each copy walks its own men. They are steered to the host's places (item `MEN`, the job board). That is why squads and villagers can be a few metres or a few seconds off ([KNOWN_ISSUES.md](KNOWN_ISSUES.md), section B).

## The link

- Every copy **appends text lines** to its own file in the mod's `link/` folder: `host.txt`, `friend1.txt`, `friend2.txt` and so on.
- It reads the other files from a remembered offset. On one PC (tests) the copies share the folder.
- Between PCs, `coop_steam.dll` mirrors the files: **one Steam message per line**. Star layout: friends talk only to the host.
- A line is `<sequence> <clock> <kind> <fields>`.
- A file starts a new file at 4 MB (`host.2.txt`, ...). The old one ends with a `~NEXT <k>` line. Older files are deleted.
- The save for a joining friend goes in chunks of up to 64 KB, checked by SHA-256. The `J LOAD` line waits until the files are complete.

## Message kinds

The third word of a line. Most kinds go one way: from the host to friends (H→F), or from a friend to the host (F→H).

| Kind | Module | What |
|---|---|---|
| `O` | `coop.lua`, `coop_x_army.lua` | army orders, militia, mercenaries, speed and pause (F→H, then the result to all) |
| `S`, `D`, `N`, `G` | `coop.lua` | squads' state, deaths, a new squad, a squad gone (H→F) |
| `T` | `coop_town.lua`, `coop_x_town.lua`, `coop_x_build.lua`, `coop_x_lord.lua` | town actions: build, roads, panels, plans, letters (F→H; the host replays, then sends it on to every friend; a refusal is `T host <n> NAK`) |
| `W` | `coop_world.lua` | region stock and totals, the daily comparison (H→F) |
| `F` | `coop_facts.lua` | every building's stock, house values, livestock (H→F) |
| `R` | `coop_realm.lua` | perks, taxes, policies |
| `L` | `coop_x_lord.lua` | war and peace |
| `A`, `K` | `coop_x_army.lua` | army panel, retinue |
| `M` | `coop_ui.lua` | the mercenary offers list |
| `E` | `coop_x_events.lua` | quests, bandit camps, region owners, villager names (H→F, answers F→H) |
| `V` | `coop_x_people.lua` | families and a rival's buildings made on friends (H→F) |
| `B` | `coop_sites.lua` | building sites finish with the host's (H→F) |
| `U` | `coop_x_jobs.lua` | the job board: which villager does which task (H→F) |
| `MM`, `MF`, `MV` and others | `coop_x_men.lua` | where each man of a squad stands (H→F) |
| `FM` | `coop_x_merch.lua` | free merchants' places (H→F) |
| `Q` | `coop_x_scene.lua` | small scene pieces: yard gates, stalls, carts (H→F) |
| `Y` | `coop_x_fields.lua` | fields and gardens (H→F) |
| `J` | `coop_join.lua` | join and resync |
| `BYE`, `HL` | `coop_session.lua` | the host leaves, or loads |

## The modules

`main.lua` reads `coop.cfg`, loads the core `coop.lua`, then every module file it finds, and starts **one driver** on the game thread.
Each module registers itself with the core and gets `onWorld` (a world attached), `tick` and `onMessage`.

| Module | Owns |
|---|---|
| `coop.lua` | Roles (idle, host, friend), the driver, the link reader and writer, squads and battles, speed and pause, crash guards, the watchdog (logs every frame gap over 1 s) |
| `coop_town.lua` | Town actions: hooks on the game's own requests, replay through the helper lord |
| `coop_x_town.lua` | Building panels: fuel reserve, crops, villager names, pack train |
| `coop_x_build.lua` | Things drawn on the ground: castle planner, walls, wall points, gates |
| `coop_world.lua` | Region stock and totals, the daily comparison, a wide daily sample for the log |
| `coop_facts.lua` | The stock of every building, house values, livestock |
| `coop_realm.lua` | Perks, taxes, policies, region names |
| `coop_x_lord.lua` | War and peace, letters, how a claim was paid, refuting a claim |
| `coop_x_army.lua` | Army panel: militia, mercenaries, retinue, squad names |
| `coop_x_men.lua` | Each man's place in a squad |
| `coop_x_merch.lua` | Free merchants |
| `coop_x_events.lua` | What the game rolls by itself: quests, raids, bandit camps, region owners |
| `coop_x_people.lua` | Families and rival buildings made on friends; population |
| `coop_x_jobs.lua` | The job board: tasks, holds, which villager does what |
| `coop_x_fields.lua` | Fields and gardens |
| `coop_x_scene.lua` | Yard gates, stalls, carts |
| `coop_sites.lua` | Building sites finish with the host's |
| `coop_join.lua` | Join and resync |
| `coop_session.lua` | The host is gone: every friend back to the main menu |
| `coop_focus.lua` | A window that loses focus does not pause the co-op game |
| `coop_ui.lua` | The Co-op button, the player panel, banners |
| `coop_patch.lua` | Loads and drives `coop_patch.dll` |
| `coop_snap.lua` | Values read by the native piece (cheaper than Lua reads) |
| `coop_steam.lua` | Loads and drives `coop_steam.dll` |
| `coop_dev.lua` | **Test builds only.** Never in a player's zip |

## Lessons that shape the code

- **Reading a game list past its end grows it** (UE4SS Lua). Always check `#arr` first. This once crashed the game's save.
- **A kept game object can be freed memory** after a load. Never keep a handle across a world change. Every module drops what it kept in `onWorld`.
- **A hook fires only when the game calls through its script layer.** A real click may run native code instead. Hook the panel's handler, or prove the click.
- **A scripted pass is not proof.** The strongest proof is a real click on two copies, both ways.

More: [BUILDING.md](BUILDING.md), `native/coop_patch/README.md`, `native/coop_steam/README.md`, `tools/dev/README.md`.
