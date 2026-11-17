# Reporting a bug

Thank you. A good report is the fastest way to a fix.

**Please do not report bugs to the game's developer (Slavic Magic) or publisher (Hooded Horse) while you use mods.**
Report them here:

| Where | Link |
|---|---|
| Discord, channel **#bug-reports** (crashes: **#crash-reports**) | `https://discord.gg/cK9HzVxzaY` |
| GitHub issues | https://github.com/fmgk-labs/manor-lords-coop/issues |
| Nexus Mods, Bugs tab | `<NEXUS_PAGE>` |

Before you post, look at [KNOWN_ISSUES.md](KNOWN_ISSUES.md). Your bug may be there already.

## Right after the problem: press Make Bug Report

1. Open the **Co-op** menu:
   - at the title screen: the **Co-op** button in the main menu;
   - in a game: press **Esc**, then **Co-op**.
2. Press **Make Bug Report**.
3. A folder opens. It holds `report_<date>_<time>.zip`.
4. Start a post (Discord **#bug-reports**, or a GitHub issue). Fill in the template below.
5. Drag the zip into your post.
6. Ask the other players to press **Make Bug Report** too. **Zips from the host and from the friend** help most.

**The game closed (crash)?** Start the game again and press **Make Bug Report** at the title screen.
The crashed session is kept: the mod keeps the logs of your last 5 game starts.

**No folder opened?** The zip is in `Win64\ue4ss\Mods\ManorLordsCoop\link\reports\`.
`Win64` is `<game folder>\ManorLords\Binaries\Win64` (`<game folder>` is the folder Steam opens with
**Manage > Browse local files**).

## What the zip holds

| File | What it is |
|---|---|
| `report_info.txt` | mod version, game version, mod loader version, host or friend, how many players were connected, the save's name, the time |
| `current_<name>_log.txt` | the mod's log of this game start (`host`, `friend1` ... or `idle` for the title screen) |
| `previous_<name>_....txt` | the mod's log of the game start before (after a crash: the crashed one) |
| `patch_status.txt`, `coop_patch.log` | the state and the log of the mod's native part |
| `UE4SS.log` | the mod loader's log |

Very long logs keep their start and their end; the middle is left out, so the zip stays small.
Logs written by a mod version before 0.2.2 are left out (they can hold Steam names); `report_info.txt` says how many.

## Privacy

The zip has **no Windows user name** (it is replaced by `<user>`), **no Steam names** (replaced by `host`, `friend 1` ...)
and **no whole Steam IDs** (only the last 4 digits stay). The mod's own logs are written that way too.
Nothing is sent anywhere: the zip stays on your PC until you post it.

**Do not post the raw log files** from the game folder in public. Post the zip.

The game's own crash records (`%LOCALAPPDATA%\ManorLords\Saved\Crashes\`) are **not** in the zip. They always hold your
Windows user name and details of your PC. **Never attach crash records to a public post.** Send them privately if we
ask (see [SECURITY.md](../SECURITY.md)).

## No Co-op button?

Then the mod did not start, and there is no button to press. Attach `Win64\ue4ss\UE4SS.log` (the mod loader's log).
Open it in a text editor first and replace your Windows user name with `<me>`.

## Template

Copy this, fill it in, and attach the zip.

```text
**Game version:** 0.8.117 (bottom right of the title screen)
**Mod version:** 0.2.2
**I was:** host / friend (slot number if you know it)
**Players in the session:** (how many, and were you on different PCs?)
**Other mods installed:** none / list them

**What happened:**
(one or two sentences)

**What I expected:**

**When:** (date and time on your PC's clock)
**Game day and speed:** (if you know them)

**What I did just before:**
1.
2.
3.

**Did it happen again?** yes, every time / sometimes / once

**Did the game close (crash)?** no / yes, on the host / yes, on a friend
**Did "Syncing with the host" show?** no / yes, once / yes, many times

**Attached:**
- [ ] my report_<time>.zip (from Make Bug Report)
- [ ] the other players' zips (if they could)
```

## What happens next

A moderator or the developer reads it, asks for anything missing, and tags it.
The tags on Discord are in [community/DISCORD_SETUP.md](community/DISCORD_SETUP.md).

## Where the files are (for developers)

The mod writes its log to `Win64\ue4ss\Mods\ManorLordsCoop\link\<name>_log.txt` (`idle`, `host`, `friend1` ...).
At each game start the last start's log moves to `link\sessions\<name>_<date>_<time>.txt`; the newest 5 per name are kept.
Each log starts with `session:` lines (mod version, the game start, role, game and loader versions). A log stops taking
ordinary lines at 200 MB (warnings and faults still go in). Bug reports go to `link\reports\`.
