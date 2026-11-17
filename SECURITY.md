# Security

## Supported versions

| Version | Supported |
|---|---|
| 0.2.1 | yes |
| older | no (players on another version are refused at the join anyway) |

## What counts as a security problem

Please report **privately** anything that could let another player, a file or a web page:

- run code on your PC;
- write or read files outside the mod's own folders and the game's save folder;
- crash another player's game **on purpose** (for example through the Steam link or the save sent at a join);
- show your personal data to others.

Also report privately if one of the two DLLs does more than its README says.

What the mod is meant to do, for comparison:

- `coop_steam.dll` talks only to the players in an **invite-only** Steam lobby. It has no server, no update check and no telemetry. It **never runs** anything it receives. It writes received saves only into the game's save folder, under fixed names, after a size and SHA-256 check.
- `coop_patch.dll` has **no network code**. It changes the running game in memory only, never the game file on disk.

## How to report privately

Use one of these. **Do not open a public issue.**

1. GitHub: the repository's **Security** tab > **Report a vulnerability**: https://github.com/fmgk-labs/manor-lords-coop/security
2. E-mail or message: **`<CONTACT>`**
3. Discord: a direct message to a moderator on `https://discord.gg/cK9HzVxzaY`.

Say what you found, how to make it happen, and which version. We answer as soon as we can, fix it, and name you in the release notes if you want.

## Crashes

An ordinary crash is a bug, not a security problem: use [docs/REPORTING_BUGS.md](docs/REPORTING_BUGS.md).

But **crash records and logs are private data**:

- The game's crash records (`%LOCALAPPDATA%\ManorLords\Saved\Crashes\`) always contain your **Windows user name**.
- The mod's logs can contain your Windows user name (in folder paths), and **Steam names and Steam IDs**.

So:

- **Never post logs with personal paths or names in public.** Replace names with `<me>` and `<friend>` first.
- Send crash records **only privately**, by one of the ways above.
