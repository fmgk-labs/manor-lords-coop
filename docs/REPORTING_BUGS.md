# Reporting a bug

Thank you. A good report is the fastest way to a fix.

**Please do not report bugs to the game's developer (Slavic Magic) or publisher (Hooded Horse) while you use mods.**
Report them here:

| Where | Link |
|---|---|
| Discord, channel **#bug-reports** (crashes: **#crash-reports**) | `<DISCORD_INVITE>` |
| GitHub issues | https://github.com/manor-lords-coop/manor-lords-coop/issues |
| Nexus Mods, Bugs tab | `<NEXUS_PAGE>` |

Before you post, look at [KNOWN_ISSUES.md](KNOWN_ISSUES.md). Your bug may be there already.

## Right after the problem

1. **Write down the time** (your PC's clock). The logs use it.
2. **Copy the files below** to another folder **before you start the game again.** Some are emptied or turned over at the next start.
3. Ask the other players to do the same. **Files from the host and from the friend** help most.

## The files to attach

`Win64` is `<game folder>\ManorLords\Binaries\Win64` (`<game folder>` is the folder Steam opens with **Manage > Browse local files**).

**Always these three:**

| File | Folder |
|---|---|
| `patch_status.txt` | `Win64\ue4ss\Mods\ManorLordsCoop\` |
| `coop_patch.log` | `Win64\ue4ss\Mods\ManorLordsCoop\` |
| `host_log.txt` (if you were the host) **or** `friend<N>_log.txt` (if you joined) | `Win64\ue4ss\Mods\ManorLordsCoop\link\` |

`<N>` is your slot: `friend1_log.txt` for the first friend, `friend2_log.txt` for the second, and so on. If there are several, send the newest.

**Also useful:**

| File | Folder | When |
|---|---|---|
| `UE4SS.log` | `Win64\ue4ss\` | always helpful; needed if there is no Co-op button |
| `idle_log.txt` | `Win64\ue4ss\Mods\ManorLordsCoop\link\` | the problem was at the title screen or during a join |
| `coop_steam.log` and `steam_status.txt` | `Win64\ue4ss\Mods\ManorLordsCoop\link\` | the problem was with an invite, a join or a disconnect |
| `coop_patch.log.old` | `Win64\ue4ss\Mods\ManorLordsCoop\` | if it exists (the log turns over at 256 KB) |
| The newest folder in `%LOCALAPPDATA%\ManorLords\Saved\Crashes\` | (see the folder name) | **only if the game closed**, and only after you read the privacy warning |

## Privacy warning: check before you post in public

These files can contain:

- your **Windows user name** (inside folder paths, for example of the save folder);
- **Steam names** and **Steam IDs** of you and your friends (`coop_steam.log`, `steam_status.txt`, the mod's log);
- the game's **crash records**, which always hold your Windows user name and details of your PC.

Before you post them in a public place:

- open each file in a text editor and replace names with `<me>`, `<friend>`; **or**
- post the report in public and send the files privately: to a moderator in a **private message** on Discord, or as in [SECURITY.md](../SECURITY.md).

**Never attach crash records to a public post.**

## Template

Copy this, fill it in, and attach the files.

```text
**Game version:** 0.8.117 (bottom right of the title screen)
**Mod version:** 0.2.1
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

**Files attached:**
- [ ] patch_status.txt
- [ ] coop_patch.log
- [ ] host_log.txt or friend<N>_log.txt
- [ ] UE4SS.log (optional)
- [ ] I checked the files for my Windows user name and Steam names
```

## What happens next

A moderator or the developer reads it, asks for anything missing, and tags it.
The tags on Discord are in [community/DISCORD_SETUP.md](community/DISCORD_SETUP.md).
