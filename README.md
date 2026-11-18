# Manor Lords Co-op

Play **one Manor Lords town together** with your friends.
Each player runs the game on their own PC. The host's save is the town.

| | |
|---|---|
| **Mod version** | 0.2.3 (v1, with the **Make Bug Report** button) |
| **Status** | **Beta**: for testing with friends |
| **Game version** | Manor Lords **0.8.117** on Steam, exactly |
| **Players** | up to 8: a host and 7 friends (tested: 5 copies on one PC, 2 players for real) |
| **Download** | Nexus Mods: https://www.nexusmods.com/manorlords/mods/454 |
| **Help and bug reports** | Discord: `https://discord.gg/cK9HzVxzaY` · GitHub issues: https://github.com/fmgk-labs/manor-lords-coop/issues |

> **Please do not report bugs to the game's developer while you use this mod.**
> Report them to us instead (see [Report a bug](#report-a-bug)).

## Contents

- [What it is](#what-it-is)
- [Status](#status)
- [Requirements](#requirements)
- [Install](#install)
- [How to play](#how-to-play)
- [What is synced](#what-is-synced)
- [Known issues and limitations](#known-issues-and-limitations)
- [Troubleshooting](#troubleshooting)
- [Report a bug](#report-a-bug)
- [Build from source](#build-from-source)
- [Credits](#credits)
- [License](#license)
- [Disclaimer](#disclaimer)

---

## What it is

Manor Lords has no multiplayer. This mod adds co-op.

- **Every player runs the game** on their own PC, with the mod installed.
- **The host's save is the town.** Friends join the host over Steam and get the host's town.
- **Everyone plays the same lord and the same town.** You use the game's own screens. Nothing new to learn.
- **The host decides.** A friend's action goes to the host. The host's game carries it out and tells everybody the result.
- **Only the host saves.** A friend can keep a copy of the town for solo play.
- **Up to 8 players: a host and 7 friends.** (Tested with up to 5 copies of the game; 6 to 8 never ran. See [Known issues](docs/KNOWN_ISSUES.md).)

### What is shared

| Shared | Examples |
|---|---|
| Everything you build | buildings, roads, fields, house plots, upgrades, walls, gates, demolitions |
| The numbers you read | stock of every building, the region's totals (top bar), treasury, approval and its factors, public order, months of food and fuel, regional wealth, influence, king's favour |
| The people | which villager does which task, what each villager carries, families arriving and leaving |
| The army | militia, mercenaries, retinue, move and attack orders, who dies in a fight, routs |
| The world | quests, bandit camps, raiders, fires, region owners, a rival lord's town |
| Time | pause and game speed: **any** player can pause or change speed |

What is **not** exactly the same: each copy walks its own villagers and soldiers.
They follow the host's, but can be a few seconds or a few metres apart. See [Known issues](#known-issues-and-limitations).

---

## Status

**Beta.** Version 0.2.1 is v1, the version for testing with friends. 0.2.2 adds the **Make Bug Report** button and keeps
the logs of the last 5 game starts; the game itself plays as in 0.2.1.
0.2.3 fixes the first fault from a public session: a host whose Steam connection dropped could not invite its friends back.
The known differences between host and friend are fixed, or accepted under the owner's "soft bars" (a few metres, a few seconds).
What was never tested goes to this beta.

What that means:

- **Done by the owner in live play** (two PCs, over Steam, with a friend): the Co-op button, Host From Save, and a friend joining over Steam.
- **Measured** on test sessions with **two copies of the game on one PC**: every number on these pages.
- **Never tested:** 3 or more players, sessions of hours, a late-game town, and a long tail of rare actions.
- 0.2.1 itself passed one full session and two installs from the release zip (lead's runs).

Your sessions are the real test. Please tell us what happens.
The full list: [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md).

---

## Requirements

| Need | Details |
|---|---|
| Manor Lords | **Version 0.8.117**, Steam. It shows at the bottom right of the title screen. |
| Windows | Windows only. |
| Steam | Steam must run. Start the game **through Steam** (not by a double-click on the `.exe`). |
| Same version for all | Every player installs **the same zip**. A different mod version is refused at the join. |
| Mod loader | **Included** in the zip (UE4SS, build 3.0.1-1218). Nothing else to download. |

Not supported: Game Pass and other stores. Other game versions.

---

## Install

Takes about 2 minutes.

1. **Close the game.**
2. In Steam: right-click **Manor Lords** > **Manage** > **Browse local files**.
3. Open the folders **ManorLords** > **Binaries** > **Win64**.
   You are in the right place when you see `ManorLords-Win64-Shipping.exe`.
4. **Already use the UE4SS loader with other mods?** Copy `dwmapi.dll` and the `ue4ss` folder somewhere safe first.
5. **Unzip everything** from the Nexus zip into that `Win64` folder. Say **yes** if Windows asks to replace files.
6. **Start the game from Steam.** The title menu now has a **Co-op** button.

In this guide, `<game folder>` means the folder Steam opens in step 2.
The mod ends up in `<game folder>\ManorLords\Binaries\Win64\ue4ss\Mods\ManorLordsCoop\`.

### Why the zip carries its own mod loader

The mod runs on the UE4SS mod loader. The loader build on the loader's Nexus page **closes the game** when this mod reads a squad.
The loader's own project fixed that in October 2026 (UE4SS issue 1461, fix in pull request 1462).
So the zip carries the loader build this mod was tested on: **UE4SS 3.0.1-1218** (git `560411f1`), MIT licence, with its licence file.

What the zip does to a loader you already have:

| Replaced | Not touched |
|---|---|
| `dwmapi.dll` (next to the game `.exe`) | `ue4ss\Mods\mods.txt` |
| `ue4ss\UE4SS.dll` | `ue4ss\Mods\mods.json` |
| `ue4ss\UE4SS-settings.ini` (your own settings in it are lost) | the folders of your other mods |

The mod switches itself on with the file `enabled.txt` in its own folder.
**Not known:** whether every mod made for an older loader build runs on this one. Only this mod was tested.

### Remove

- **The mod only:** close the game and delete `ue4ss\Mods\ManorLordsCoop`.
- **The loader too** (only if no other mod needs it): delete `dwmapi.dll` and the `ue4ss` folder.

The mod never changes your own save files.

---

## How to play

### Host

1. Title screen > **Co-op** > **Host From Save** (or **Host New Game**).
2. Load or start the game as usual.
3. In the game: **Esc** > **Co-op** > **Invite Friends**. Pick your friends in the Steam window.

### Join (a friend)

1. Start the game **from Steam**. Wait at the title screen.
2. **Accept the Steam invite.** The host's town loads by itself.
3. In a solo game? Save it first. Accepting the invite leaves it.

### Resync (automatic)

- When your copy differs from the host's in a way the numbers alone cannot fix, it **loads the host's state again**.
- You see the banner **"Syncing with the host"**. The game stands still for a few seconds (about 6 to 20 seconds in tests).
- By default **only the copy that differs** loads. The others play on.
- There is no button for it. Joining works the same way.
- Optional: the host can set `resync = all` in `ue4ss\Mods\ManorLordsCoop\coop.cfg`. Then every copy loads together.

### Leave

| Who | How | What happens |
|---|---|---|
| Friend | **Esc** > **Co-op** > **Leave Co-op** | The host's game goes on. |
| Host | **Main Menu** or **Quit Game**, clicked twice while friends are in (0.2.3: the first click asks) | Every friend sees "The host left the game. Returning to the main menu." |

If the host's game goes silent for 30 s, friends are sent back to the main menu too.

### What happens when the connection drops

A short drop does not end the game. Both sides wait up to **30 seconds**.

| Who | You see | What happens |
|---|---|---|
| Host, own connection dropped (internet, Steam, a VPN switched on) | "Your Steam connection dropped. Trying to reconnect (30 s)..." | Your game goes on. The mod asks Steam to let you back into the same lobby. Your friends stay. |
| Host, back in time | "Reconnected." | Nothing was lost. Friends that missed something load your save once by themselves ("Syncing with the host"). |
| Host, not back within 30 s | "Your Steam connection dropped. Your friends were sent to the main menu. Press Invite Friends to bring them back." | Your game goes on. **Esc** > **Co-op** > **Invite Friends** opens a new lobby. |
| Friend, the host dropped | "Connection to the host lost. Waiting up to 30 s..." and the pause line "Host connection lost" | Your game is held (paused) while nothing comes from the host, so the two towns stay equal. |
| Friend, the host is back in time | "Connection to the host is back" | The game runs on. After a gap of more than 2 s your copy loads the host's save once. |
| Friend, the host is not back within 30 s | "The host left the game. Returning to the main menu." | As when the host leaves. Accept the host's new invite; no restart needed. |

A host that leaves on purpose (**Main Menu**, quit) still ends the game for everyone at once.

**How far this is tested:** in the mod's own tests with a simulated Steam only. It has not run between two PCs yet (see [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md), H5a). If the drop was on a **friend's** side, that friend still leaves at once and joins again by invite.

### Keep a copy (a friend)

**Esc** > **Co-op** > **Keep a Copy of This Save**. The copy shows under **Load Game** and plays as a solo game.

### Versions must match

Every player needs the **same game version** and the **same mod version**.
A player with another mod version is not let in. The host sees: "A player's co-op mod version differs from the host's".

### Good to know

- **Your solo games are not changed.** The mod only acts in a game started from the Co-op menu or joined by invite.
- **Any player can pause** or change the speed. It changes for everyone.
- **A window that loses focus does not pause** the co-op game.
- **A tutorial window** on anyone's screen pauses the game for everyone. Tick "Skip all future tutorials".
- **The mod goes online only through Steam**, inside the game, to your friends in an invite-only lobby. No update check. Nothing sent anywhere else.

---

## What is synced

The project keeps a table of every player action in the game. Counts of 2026-11-16:

| Area | Actions | Closed | Carried, not proven both ways | Not carried | Nothing to carry |
|---|---|---|---|---|---|
| Town panels | 31 | 28 | 0 | 0 | 3 |
| Building and roads | 25 | 16 | 8 | 0 | 1 |
| Trade | 12 | 7 | 4 | 0 | 1 |
| Lord and realm | 18 | 7 | 6 | 0 | 5 |
| Army and battles | 24 | 17 | 5 | 1 | 1 |
| Events and quests | 6 | 3 | 0 | 0 | 3 |
| Menu and joining | 19 | 2 | 9 | 0 | 8 |
| Speed and saving | 5 | 3 | 0 | 0 | 2 |
| **All** | **140** | **83** | **32** | **1** | **24** |

What the columns mean:

- **Closed:** carried, and proven **both ways** (host to friend, friend to host) on two copies, by a real mouse click or by pressing the game's own button handler. 37 of the 83 are proven by a real click.
- **Carried, not proven both ways:** the mod carries it. One direction, or a test after a code change, is still missing.
- **Not carried:** only one action, the unit editor. If you use it, only your own copy changes.
- **Nothing to carry:** the screen only, or no such control in game version 0.8.117.

Examples of closed actions: placing, moving, upgrading and demolishing buildings; roads, fields, pastures, market plots; work areas, recipes, limits, workers; trade rules and routes; perks, taxes, policies, claims, letters; move, attack, charge, formation lines, militia, mercenaries, retinue; quests; pause, speed, save.

**Proven numbers (lead's test sessions, two copies on one PC):**
at every pause check of sessions lead37 to lead41 (15 of 15), stock, region totals, derived values, population and goods in hands were equal on host and friend.
In those sessions a friend never showed a value the host never had, and the longest delay was 1.86 s.

---

## Known issues and limitations

The full list, with numbers and sources: **[docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md)**.

The most important:

| Issue | In short |
|---|---|
| Never tested | 3 or more real players. Sessions of hours. A late-game town. A long tail of rare actions. |
| Game version | 0.8.117 only. After a game update the mod may stop working. |
| Squads a few metres off | Accepted: within about 3 m, for a few seconds. Up to about 12 m in a squad's first second. |
| Villagers out of step | Accepted: a villager can be a few seconds ahead or behind the host's. Stock, totals, population stay equal. |
| Merchants a few metres off | 99 % within about 2.5 m. Up to about 5 m right after a rejoin. |
| Speed drops to 1 | The plain game slows to speed 1 when an enemy is spotted. This now happens for everyone. The lead's study of one test session also found 7 drops with no known cause. Press the speed button again. |
| Hidden differences | A hidden per-region squad count differs after a resync (not shown on screen). The job board's villager names pointed at other people in 2 of 58 cases. |
| Never clicked | 9 player actions were never clicked with a real mouse, for example settling a new region, attacking a building, a bailey plot. Let the host do them. |
| Unexplained crash | A friend's crash in the first live session (2026-11-11, older build) is not explained. |
| Frame rate | Not measured as a target. Friends may run slower, most at speed 8. |

---

## Troubleshooting

| Problem | What to do |
|---|---|
| No **Co-op** button | Check that `Win64\dwmapi.dll` and `Win64\ue4ss\Mods\ManorLordsCoop\Scripts\main.lua` exist, and `enabled.txt` in the `ManorLordsCoop` folder. Restart the game through Steam. Some antivirus programs remove `dwmapi.dll`. |
| The invite does nothing | Start the game **through Steam**, not by a double-click on the `.exe`. |
| "Steam joining needs the game started through Steam" | The same: start the game from Steam. |
| "A player's co-op mod version differs from the host's" | Someone has another zip. Everyone installs the same one. |
| "Syncing with the host" shows often | Normal after a join. If it repeats every minute or two, report it: **Co-op** menu, **Make Bug Report**, attach the zip. With mod 0.2.2 after **Host New Game**: use **0.2.3**, or save the new game, load it with **Host From Save**, then invite. |
| Host: "Preparing the new game for co-op..." | Normal, once, about 10 s after **Host New Game**: the host's game saves and loads the new world once (0.2.3). Friends who join meanwhile come in with that load. |
| "The games differ in a way a resync cannot fix" | Play goes on; the mod stops resyncing for that difference. Every player: **Co-op** menu, **Make Bug Report**, send the zip. |
| Host: the **Main Menu** or **Quit Game** button says "Ends co-op: click again" | Your friends are still in: leaving ends their game too. Click it again (after a moment, within 6 s) to leave, or press **Continue** to stay. |
| The game drops to speed 1 | Usually the game's own rule when an enemy is spotted. Press the speed button again. |
| "The host left the game" | The host quit, was silent for 30 s, or the host's Steam connection dropped for more than 30 s. The host invites again (the host's own game goes on if only its connection dropped); you accept the new invite, without restarting your game. |
| "Connection to the host lost. Waiting up to 30 s..." | The host's connection dropped. Wait: your game is held and runs on when the host is back (see [What happens when the connection drops](#what-happens-when-the-connection-drops)). |
| Host: "Your Steam connection dropped. Trying to reconnect (30 s)..." | Your internet or Steam dropped for a moment (a VPN switched on does this too). Keep playing; the mod gets you back into your lobby. "Reconnected." means nothing was lost. |
| Host: "Your Steam connection dropped. Your friends were sent to the main menu..." | You were not back within 30 s. Your game goes on. Press **Esc**, **Co-op**, **Invite Friends**: a new lobby opens and the invite goes to that one. |
| Your friend did not get the invite after your internet dropped | Use mod **0.2.3** or later. Before it, the invite window could open for a lobby that no longer existed. Press **Invite Friends** again. If the game says "Steam is not online", wait: the invite window opens by itself when Steam is back. |
| The menu says "Manor Lords is already running with co-op on this PC. Close this copy." | The game was started a second time while the first copy still runs. Co-op is off in the second copy, so it cannot disturb the first one's session. Close the second copy. (If no other copy runs and the line still shows: restart the PC, or put the line `guard = off` into `coop.cfg` and tell us.) |
| The game closes (crash) | Start the game again. At the title screen open **Co-op** and press **Make Bug Report**: the crashed session is kept. Attach the zip to your report. |
| Anything else that looks wrong | Right after it: **Co-op** menu (title screen: the **Co-op** button; in a game: **Esc**, then **Co-op**), press **Make Bug Report**, attach the zip (see [Report a bug](#report-a-bug)). |
| After a game update the mod does nothing | The mod's native part switches itself off when the game changed. Wait for a new mod version. |
| You want the mod off for a while | You do not need to: it stays idle in solo games. To switch it off fully, remove the `#` before `role = disabled` in `coop.cfg`. |

### Where the log files are

You do not need to find them: **Make Bug Report** puts the right ones in one zip, without your Windows user name or
Steam names. For the curious, `Win64` below is `<game folder>\ManorLords\Binaries\Win64`.

| File | Folder | What it holds |
|---|---|---|
| `report_<date>_<time>.zip` | `Win64\ue4ss\Mods\ManorLordsCoop\link\reports\` | what **Make Bug Report** made: post this one |
| `host_log.txt` or `friend1_log.txt` | `Win64\ue4ss\Mods\ManorLordsCoop\link\` | the mod's own log of this game start (host, or friend; the number is your slot) |
| `idle_log.txt` | `Win64\ue4ss\Mods\ManorLordsCoop\link\` | the mod's log at the title screen |
| `<name>_<date>_<time>.txt` | `Win64\ue4ss\Mods\ManorLordsCoop\link\sessions\` | the logs of earlier game starts (the newest 5 per name) |
| `patch_status.txt` | `Win64\ue4ss\Mods\ManorLordsCoop\` | the state of the mod's native part |
| `coop_patch.log` | `Win64\ue4ss\Mods\ManorLordsCoop\` | the native part's log |
| `UE4SS.log` | `Win64\ue4ss\` | the mod loader's log |
| `coop_steam.log` | `Win64\ue4ss\Mods\ManorLordsCoop\link\` | the Steam part's log (holds Steam IDs and Steam names; not in the zip) |
| crash records | `%LOCALAPPDATA%\ManorLords\Saved\Crashes\` | the game's own crash reports (hold your Windows user name; not in the zip) |

**Privacy:** post the zip, not the raw files. The zip has no Windows user name and no Steam names. `UE4SS.log`,
`coop_steam.log` and the crash records can hold them.

---

## Report a bug

1. Right after the problem, open the **Co-op** menu (title screen: the **Co-op** button; in a game: **Esc**, then
   **Co-op**) and press **Make Bug Report**. A folder opens with `report_<date>_<time>.zip`.
   After a crash: start the game again and press it at the title screen. The crashed session is kept.
2. Fill in the template in [docs/REPORTING_BUGS.md](docs/REPORTING_BUGS.md) and attach the zip.
3. Post it:
   - Discord: `https://discord.gg/cK9HzVxzaY` (channel **#bug-reports**)
   - GitHub issues: https://github.com/fmgk-labs/manor-lords-coop/issues
   - Nexus Mods: https://www.nexusmods.com/manorlords/mods/454 (Bugs tab)

Please **do not** report bugs to Slavic Magic or Hooded Horse while you use mods.

A security problem, or crash records to send? Do it privately: see [SECURITY.md](SECURITY.md).

---

## Build from source

You need Windows, the Microsoft C compiler (Visual Studio or its Build Tools) and PowerShell.

```bat
native\coop_patch\build.cmd
native\coop_steam\build.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File tools\package.ps1 -Variant nexus -Game "<path to a Manor Lords folder with the loader>"
```

The `nexus` variant also needs the player's install note, which is kept outside this repository (see BUILDING.md).

Details, tests and the test harness: **[docs/BUILDING.md](docs/BUILDING.md)**.
How the mod works inside: **[docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md)**.
How to help: **[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md)**. Please follow the **[Code of Conduct](CODE_OF_CONDUCT.md)**.
For maintainers (roles, labels, releases): **[docs/MAINTAINERS.md](docs/MAINTAINERS.md)**.

---

## Credits

- **UE4SS (RE-UE4SS)**, the mod loader this mod runs on. MIT licence, Copyright (c) 2022 Narknon and contributors.
  Included in the download unchanged (build 3.0.1-1218), with its licence file `ue4ss\LICENSE`.
  Project: https://github.com/UE4SS-RE/RE-UE4SS
- **Manor Lords** is made by Slavic Magic and published by Hooded Horse.

---

## License

MIT, see [LICENSE](LICENSE).

The bundled UE4SS loader is a separate work with its own MIT licence (`ue4ss\LICENSE` in the download). See [Credits](#credits).

---

## Disclaimer

- This is a **fan-made mod**. It is **not made, endorsed or supported** by Slavic Magic or Hooded Horse.
- Use it at your own risk. Back up your saves.
- **AI disclosure:** `<AI label: owner to choose>`.
  This mod's code and documentation were written with an AI coding assistant (Claude, by Anthropic), in a long series of working sessions directed and tested by the author.
  Most of the code was written by the AI. The test results come from runs of the game.
