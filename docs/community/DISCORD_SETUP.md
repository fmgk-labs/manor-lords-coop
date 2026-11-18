# Discord server setup

A ready-to-click plan for the Manor Lords Co-op Discord server, with every text ready to paste.

## Placeholders

Replace these before you post anything.

| Placeholder | Put in |
|---|---|
| `https://discord.gg/cK9HzVxzaY` | the server's permanent invite link |
| `https://www.nexusmods.com/manorlords/mods/454` | the mod's Nexus Mods page |
| `2026-11-17` | the date 0.2.1 goes public |
| `2026-11-17` | the date 0.2.2 goes public |

The GitHub links are already filled in: the repository is https://github.com/fmgk-labs/manor-lords-coop.

**Tip:** when you paste a text, Discord does not link `#channel` names by itself. Type each `#` name again and pick the channel from the list.

---

## 1. Setup, step by step

1. **Create the server.** Discord > **+** > **Create My Own** > **For a club or community**. Name: `Manor Lords Co-op`.
2. **Turn on Community.** Server Settings > **Enable Community**. Follow the steps:
   - verification level **Medium** or higher;
   - explicit media filter **on for all members**;
   - rules channel: `#rules`;
   - community updates channel: a private `#discord-updates` in the DEV category (Discord needs one; only moderators see it).
3. **Default notifications:** Server Settings > Overview > **Only `@mentions`**.
4. **Make the roles** (section 2), in that order from top to bottom.
5. **Make the categories and channels** (section 3). Set the permissions on each **category** (section 4); its channels then follow.
6. **Channel types:** `#announcements` and `#changelog` as **Announcement** channels. `#bug-reports` and `#test-sessions` as **Forum** channels.
7. **Forum tags and guidelines** (section 5).
8. **Rules screening:** Server Settings > Safety Setup > **members must accept the rules** before they can talk. This is the gate: nobody can write before they accept `#rules`.
9. **Onboarding (optional):** Server Settings > Onboarding. Default channels: everything in INFO, SUPPORT and TESTING (Discord asks for several default channels where `@everyone` can write; SUPPORT and TESTING give that). One question: "Do you play the mod?", answer "Yes, I play co-op" gives the role **Player**.
   **If Discord does not let you turn Onboarding on, skip it.** Rules screening alone is enough, and a Moderator gives the Player role by hand.
10. **AutoMod** (Server Settings > AutoMod): turn on "Block mention spam" and "Block suspected spam content".
11. **Post the texts** (section 6). Pin the welcome, rules, known-issues and how-to-join messages.
12. **Make the invite:** right-click `#welcome` > Invite People > Edit invite link > **Expire after: Never**. That link is `https://discord.gg/cK9HzVxzaY`.

---

## 2. Roles

| Role | Who | How they get it | Colour (suggestion) |
|---|---|---|---|
| **Owner** | the mod's author | by hand | gold |
| **Moderator** | trusted helpers | by the Owner | red |
| **Tester** | players who join test sessions and send good reports | by a Moderator | green |
| **Player** | members who play the mod | by Onboarding, or by a Moderator | blue |

Tick **Display role members separately** for Owner, Moderator and Tester.

Player gives no extra rights. It shows who plays the mod, and lets you call them for a session with `@Player`.
Tester adds writing in `#dev-talk`.

---

## 3. Categories and channels

| Category | Channel | Type | What it is for |
|---|---|---|---|
| **INFO** | `#welcome` | Text | the welcome message |
| | `#rules` | Text | the rules |
| | `#announcements` | Announcement | new versions, important news |
| | `#known-issues` | Text | the pinned known-issues list |
| | `#download-and-install` | Text | the download link and install steps |
| **SUPPORT** | `#install-help` | Text | help with installing and starting |
| | `#bug-reports` | Forum | one post per bug, with tags |
| | `#crash-reports` | Text | the game closed: logs and files |
| **TESTING** | `#test-sessions` | Forum | looking for a group: one post per session |
| | `#feedback` | Text | how a session went |
| | `#suggestions` | Text | ideas for the mod |
| **DEV** | `#changelog` | Announcement | what changed in each version |
| | `#dev-talk` | Text | code, builds, testing method |
| | `#discord-updates` | Text (private) | Discord's own notices; moderators only |
| **VOICE** | `Co-op session 1` | Voice | play together |
| | `Co-op session 2` | Voice | play together |
| | `Co-op session 3` | Voice | play together |

Suggested settings:

- `#suggestions`: slowmode 1 minute.
- `#crash-reports`: slowmode 30 seconds.
- Voice channels: user limit 8 (the most players a session can have).

---

## 4. Permissions

"Read" = View Channel and Read Message History. "Write" = Send Messages, Attach Files, Embed Links, Add Reactions. "Post" (forums) = Create Posts and Send Messages in Threads. A dash means the role cannot see the channel.

`@everyone` is every member. Until a member accepts the rules, rules screening stops them from writing anywhere.

| Where | `@everyone` and Player | Tester | Moderator | Owner |
|---|---|---|---|---|
| INFO (all channels) | read | read | read, write, Manage Messages (pin) | Administrator |
| `#install-help` | read, write | read, write | read, write, Manage Messages | Administrator |
| `#bug-reports` (forum) | read, post | read, post | read, post, Manage Threads, Manage Messages | Administrator |
| `#crash-reports` | read, write | read, write | read, write, Manage Messages | Administrator |
| `#test-sessions` (forum) | read, post | read, post | read, post, Manage Threads | Administrator |
| `#feedback`, `#suggestions` | read, write | read, write | read, write, Manage Messages | Administrator |
| `#changelog` | read | read | read, write | Administrator |
| `#dev-talk` | read | read, write | read, write, Manage Messages | Administrator |
| `#discord-updates` | — | — | read | Administrator |
| VOICE (all) | Connect, Speak, Video, Use Voice Activity | the same | the same, plus Mute, Deafen and Move Members | Administrator |
| Server-wide | Change Nickname | Change Nickname | Timeout Members, Kick Members, Manage Nicknames, View Audit Log | Administrator |

Nobody but Owner and Moderator may use **Mention `@everyone`, `@here` and All Roles**.

---

## 5. Forum tags and guidelines

### `#bug-reports` tags

Tick **Only moderators can apply this tag** on the status tags. Tick **Require people to select tags when posting**.

| Group | Tags |
|---|---|
| Who saw it | `host`, `friend` |
| Area | `install`, `join / invite`, `sync`, `town`, `army / battle`, `trade`, `speed / pause`, `crash`, `performance` |
| Status (moderators only) | `needs logs`, `confirmed`, `known issue`, `fixed in next version`, `not a bug`, `duplicate` |

Default sort: **Latest activity**. Default layout: **List**.

### `#test-sessions` tags

`looking for host`, `looking for friends`, `scheduled`, `full`, `done`.

### `#test-sessions` post guidelines (paste into the forum's Post Guidelines field)

```text
One post per session. Title: day, time and time zone, e.g. "Sat 18:00 UTC, host needed".
Say: host or friend, how many players, how long you can play, and your mod version (must be 0.2.2 for everyone).
Use the tags. Mark the post "full" when you have your group and "done" afterwards.
After playing: write how it went in #feedback, and one post per bug in #bug-reports.
```

### `#bug-reports` post guidelines (paste into the forum's Post Guidelines field)

```text
One bug per post. Title: short and clear, e.g. "Friend: road not shown on host after a resync".
Check #known-issues first. If the game closed, use #crash-reports.
1. Right after the problem, open the Co-op menu (title screen: the Co-op button; in a game: Esc, then Co-op).
2. Press Make Bug Report. A folder opens with report_<time>.zip.
3. Fill in the template from the pinned post: game version, mod version (0.2.2), host or friend, players and PCs, what happened, what you expected, the time on your PC's clock, what you did just before.
4. Drag the zip into your post. Zips from the host AND the friend help most.
5. Pick the tags for who saw it and the area. Moderators add the status tags.
After a crash: start the game again and press Make Bug Report. The crashed session is kept.
The zip has no Windows user name or Steam names. Do not post the raw log files.
```

---

## 6. Texts to paste

Each text is under Discord's 2,000-character limit.

### 6.1 Welcome (post in `#welcome`, pin)

```md
# Welcome to Manor Lords Co-op

This server is for **Manor Lords Co-op**, a fan-made mod that lets you play **one Manor Lords town together** with your friends.

**How it works:** every player runs the game on their own PC. The host's save is the town. Friends join through a Steam invite. Up to 8 players: a host and 7 friends.

**Status:** beta, version **0.2.2**. Manor Lords **0.8.117** only. Windows and Steam only.

**Start here**
1. Read #rules and accept them.
2. Install the mod: #download-and-install
3. Before you report a bug: #known-issues
4. Stuck? Ask in #install-help
5. Found a bug? Open the **Co-op** menu, press **Make Bug Report**, and drag the zip into a post in #bug-reports (game closed? #crash-reports)
6. Want to play with others? #test-sessions

**Links**
Download (Nexus Mods): https://www.nexusmods.com/manorlords/mods/454
Source code (GitHub): https://github.com/fmgk-labs/manor-lords-coop

This mod is not made by, and not connected to, Slavic Magic or Hooded Horse. Please do not report mod bugs to them.
```

### 6.2 Rules (post in `#rules`, pin)

```md
# Rules

1. **Be kind.** No insults, harassment, hate or slurs. Disagree politely.
2. **Stay on topic.** This server is about the Manor Lords Co-op mod.
3. **No piracy.** Only the Steam version of Manor Lords is supported. No links to cracked games, and no help with them.
4. **Do not report mod bugs to the game's developer or publisher.** Report them here. The developer asked players not to report bugs while they use mods.
5. **Protect privacy.** Log files and crash records can hold your Windows user name and Steam names. Check them before you post. Never post other people's personal data.
6. **Download only from the official pages:** https://www.nexusmods.com/manorlords/mods/454 or https://github.com/fmgk-labs/manor-lords-coop. Do not share other builds or re-uploads.
7. **One bug per post** in #bug-reports. Use the template.
8. **No spam and no ads.** No self-promotion, no advertising in DMs.
9. **No NSFW content.**
10. **Moderators have the last word.** Questions about a decision? Message a moderator, not the channel.

Breaking the rules can lead to a warning, a timeout or a ban.
```

### 6.3 Announcement: v1 / 0.2.1 (post in `#announcements`)

```md
# Manor Lords Co-op 0.2.1 is out (v1, beta)

Play **one Manor Lords town together**. Every player runs the game; the host's save is the town. Up to 8 players: a host and 7 friends.

**Download:** https://www.nexusmods.com/manorlords/mods/454
**Needs:** Manor Lords **0.8.117** on Steam, Windows. The mod loader is included. Everyone installs the **same** zip.

**What is shared**
- Everything you build: buildings, roads, fields, plots, upgrades, walls, gates
- The numbers you read: stock, top-bar totals, treasury, approval, public order, wealth
- Which villager does which task, and what each one carries
- The army: militia, mercenaries, retinue, orders, who dies in a fight
- Quests, bandit camps, raiders, fires, a rival lord's town
- Pause and speed: any player can change them

**What "beta" means here**
The owner has played with a friend on two PCs over Steam. Our measurements come from two copies of the game on one PC. We have **never** tested 3 or more players, sessions of hours, or a late-game town. That is what we need you for.

**Known issues:** #known-issues
**Bugs:** #bug-reports (please attach the three log files)
**Find people to play with:** #test-sessions

Thank you for testing!
```

### 6.4 Known issues (post in `#known-issues`, pin)

```md
# Known issues in 0.2.1

Full list, with numbers: https://github.com/fmgk-labs/manor-lords-coop/blob/HEAD/docs/KNOWN_ISSUES.md

- **Never tested:** 3 or more players, sessions of hours, a late-game town.
- **Manor Lords 0.8.117 only.** After a game update the mod may stop working.
- **Squads** can be about 3 m off for a few seconds, and up to about 12 m in a squad's first second. Accepted.
- **Villagers** can be a few seconds out of step with the host's. Stock, totals and population stay equal. Accepted.
- **Travelling merchants** stay within about 2.5 m (up to about 5 m right after a rejoin).
- **Speed drops to 1** when an enemy is spotted (the plain game does this). Some drops have no known cause. Press the speed button again.
- **9 actions were never clicked** with a real mouse, e.g. settling a region, attacking a building, a bailey plot. Let the host do them.
- **The unit editor is not synced.**
- **A friend's crash** in the first live session (older build) is still unexplained.
- **Frame rate:** friends may run slower, most at speed 8.

Before you report a bug: is it on this list?
```

### 6.5 Download and install (post in `#download-and-install`, pin)

```md
# Download and install

**Download:** https://www.nexusmods.com/manorlords/mods/454

1. Close the game.
2. Steam: right-click **Manor Lords** > **Manage** > **Browse local files**.
3. Open **ManorLords** > **Binaries** > **Win64** (you see `ManorLords-Win64-Shipping.exe`).
4. Already use the UE4SS loader with other mods? Copy `dwmapi.dll` and the `ue4ss` folder somewhere safe first.
5. Unzip everything into that folder. Say **yes** to replacing files.
6. Start the game **from Steam**. The title menu has a new **Co-op** button.

**Host:** Title > Co-op > Host From Save (or Host New Game). In the game: Esc > Co-op > Invite Friends.
**Friend:** start the game from Steam, wait at the title screen, accept the Steam invite.

**Remove:** delete `ue4ss\Mods\ManorLordsCoop`. Remove `dwmapi.dll` and `ue4ss` only if no other mod needs them.

Problems? #install-help
```

### 6.6 First post in `#bug-reports` (title: "How to report a bug: read first", pin)

```md
**How to report a bug**
1. Right after the problem, open the **Co-op** menu.
   - At the title screen: the **Co-op** button in the main menu.
   - In a game: press **Esc**, then **Co-op**.
2. Press **Make Bug Report**.
3. A folder opens. It holds `report_<date>_<time>.zip`.
4. Start a post here in #bug-reports. Copy the template below and fill it in.
5. Drag the zip into your post.
6. Pick the tags: who saw it (host / friend) and the area.

**The game closed?** Start the game again and press **Make Bug Report** at the title screen. The crashed session is kept. Post in #crash-reports.

**Ask the other players** to press the button too. Zips from the host and the friend help most.

**Privacy:** the zip has no Windows user name and no Steam names. Do not post the raw log files.

**No folder opened?** The zip is in `Win64\ue4ss\Mods\ManorLordsCoop\link\reports` (`Win64` = the folder with ManorLords-Win64-Shipping.exe).

**Template**
Game version: 0.8.117
Mod version: 0.2.2
I was: host / friend
Players and PCs:
What happened:
What I expected:
When (your clock):
What I did just before:
Did it happen again?
Did the game close?
Did "Syncing with the host" show?

Full guide: https://github.com/fmgk-labs/manor-lords-coop/blob/HEAD/docs/REPORTING_BUGS.md
```

### 6.7 How to join a test session (post in `#test-sessions` as a pinned post, or in `#welcome`)

```md
# How to join a test session

**Before the session**
1. Install the mod: #download-and-install. Everyone needs mod **0.2.2** and Manor Lords **0.8.117**.
2. Add the host as a friend on Steam. The invite comes through Steam.
3. Make a post in #test-sessions, or reply to one: your time zone and when you can play.

**At the session**
1. Join the voice channel the host names (Co-op session 1, 2 or 3).
2. Start Manor Lords **from Steam** and wait at the title screen.
3. Host: Title > **Co-op** > **Host From Save** (or **Host New Game**), then Esc > **Co-op** > **Invite Friends**.
4. Friends: accept the Steam invite. The town loads by itself.
5. Something odd? Say it in voice and write down the time.

**After the session**
- Tell us how it went in #feedback. One message is fine.
- One post per bug in #bug-reports, with the log files.
- Host: tell us how long you played, how many players, and at which speed.

**What we need most right now:** 3 or more players, long sessions, late-game towns.
```

### 6.8 Changelog entry (post in `#changelog`)

For 0.2.3:

```md
# 0.2.3 (`<date it goes public>`)

- Fixed: a host whose Steam connection dropped for a moment (for example a VPN switched on) could not invite friends back: the invite window opened for a lobby that no longer existed, and no invite arrived. Now the host is told **"Your Steam connection dropped"**, and **Invite Friends** opens a new lobby and invites to that one. The host's game goes on.
- Fixed: after "The host left the game" a friend can accept a new invite without restarting the game.
- Fixed: the title menu's Co-op button no longer keeps saying "Co-op: the host left the game". The Co-op menu says why the last game ended.
- **Make Bug Report** now also takes the Steam link's log and state, with every player's name taken out.
- Every error the mod counts now has a line in its log.
- Fixed: after **Host New Game**, friends were resynced again and again (a new world differs from the same world loaded from its save). Now the host's game says **"Preparing the new game for co-op..."** and saves and loads the new world once, about 10 s after it starts. A game loaded from a save is not touched.
- Fixed: a friend whose resync did not help now gets a resync of every copy at once (it could take six resyncs before).
- New: when a difference is still there after every copy loaded, the mod stops resyncing for it and says so once: **"The games differ in a way a resync cannot fix"**. Play goes on; please send a bug report.
- New: while friends are in, the host's **Main Menu** and **Quit Game** ask first. Click again to leave.

Everyone must use 0.2.3. Older versions are refused at the join.
```

For 0.2.2:

```md
# 0.2.2 (2026-11-17)

- New: **Make Bug Report** in the Co-op menu (title screen, and Esc > Co-op in a game). It makes one zip with the logs and opens its folder. Drag the zip into your post in #bug-reports.
- The logs of your last 5 game starts are kept, so a crashed session is still there after you start the game again.
- The logs and the zip have no Windows user name and no Steam names.
- The game plays as in 0.2.1.

Everyone must use 0.2.2. Older versions are refused at the join.
```

For 0.2.1:

```md
# 0.2.1 (2026-11-17), first public version

Compared with the private test builds (0.1.0 to 0.1.6):
- A friend's own drop to speed 1 when an enemy is spotted is no longer sent to the others as a player's speed change (new in 0.2.1).
- The numbers you read follow the host's: stock of every building, the region's totals, approval and its factors, public order, months of food and fuel, wealth, influence, king's favour, population.
- The job board: which villager does which task, what each one carries, trees fall at the host's moment.
- Squads and their men stand and walk where the host's do; routs and deaths are the host's.
- Walls, wall points, gates and the castle planner are carried. Fields and gardens follow the host's.
- A rival lord's town, quests, bandit camps, raiders and free merchants follow the host's.
- Only the copy that differs reloads the host's state; the others play on.
- When the host leaves, every friend goes back to the main menu. A window that loses focus does not pause the co-op game.
- Many crash fixes (after a demolish, at speed 8, after a resync).

Everyone must use 0.2.1. Older versions are refused at the join.
```
