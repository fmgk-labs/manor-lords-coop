# Maintainers

How the GitHub repository is run, for the owner and for helpers who look after it.

## Roles on GitHub

| Role | For whom | Can |
|---|---|---|
| **Admin** | the owner only | everything, including settings, roles and deleting the repository |
| **Maintain** | co-maintainers | manage issues, pull requests and releases, some settings; no destructive or security settings |
| **Write** | trusted contributors | push branches, merge pull requests (within the branch rules below) |
| **Triage** | issue moderators | label, assign, close and reopen issues and pull requests; no code changes |

How to add someone: repository **Settings** > **Collaborators and teams** > **Add people** > pick the role.

**Note:** the repository is owned by the GitHub organization `fmgk-labs`, so all these roles are available. The owner is the organization's Owner and stays Admin.

## Private security reports

`SECURITY.md` sends people to the **Security** tab > **Report a vulnerability**. That button shows only when the owner turns it on:
repository **Settings** > the code security section > **Private vulnerability reporting** > **Enable**.

## Branch rules for `main`

Repository **Settings** > **Rules** > **Rulesets** > **New branch ruleset**, target the default branch `main`:

- [x] **Require a pull request before merging**, with **1 approval**.
- [x] **Dismiss stale approvals** when new commits are pushed.
- [x] **Require conversation resolution** before merging.
- [x] **Block force pushes.**
- [x] **Restrict deletions.**

Bypass list: only the owner, for emergencies.

## Labels

Repository **Issues** > **Labels** > **New label**.

| Label | Colour | Use it for |
|---|---|---|
| `bug` | `#d73a4a` | something does not work as it should |
| `crash` | `#b60205` | the game closes |
| `desync` | `#e99695` | host and friend show different things |
| `needs-logs` | `#fbca04` | the report has no log files yet |
| `good first issue` | `#7057ff` | a small, clear task for a new helper |
| `help wanted` | `#008672` | we would like outside help on this |
| `native` | `#5319e7` | about `coop_patch.dll` or `coop_steam.dll` (C code) |
| `lua` | `#1d76db` | about the Lua scripts |
| `docs` | `#0075ca` | documentation |
| `wontfix` | `#ffffff` | we decided not to change this |
| `enhancement` | `#a2eeef` | an idea (GitHub's default; the feature request form uses it) |

## Handling a new issue

1. Did they use the template? Is the zip from **Make Bug Report** there (or, with no Co-op button, `UE4SS.log`)? If not: label `needs-logs` and ask for it.
2. **Privacy first.** If a post shows a Windows user name, Steam names, Steam IDs or a crash record: edit the post to remove them, or hide it, and ask the person to send the files privately ([SECURITY.md](../SECURITY.md)).
3. Is it in [KNOWN_ISSUES.md](KNOWN_ISSUES.md)? Then link it and close, or keep it open if it adds new numbers.
4. A duplicate? Link the first issue and close.
5. Label: `bug`, `crash` or `desync`, plus `lua` or `native` when that is clear.

## Cutting a release

Every player must use **the same zip**. A different mod version is refused at the join.

1. **Merge** everything for the release into `main`. Update [KNOWN_ISSUES.md](KNOWN_ISSUES.md).
2. **Bump the version** in `mod/ManorLordsCoop/Scripts/coop.lua`: `C.version = "<new version>"`.
3. **Build** both DLLs and run their tests ([BUILDING.md](BUILDING.md)):
   `native\coop_patch\build.cmd test "<game folder>\ManorLords\Binaries\Win64\ManorLords-Win64-Shipping.exe"` and `native\coop_steam\build.cmd test`.
4. **Package** the player zip:
   `powershell -NoProfile -ExecutionPolicy Bypass -File tools\package.ps1 -Variant nexus -Game "<game folder>"`.
   It puts the player's install note `docs\INSTALL-nexus.txt` into the zip: check that note for the new version first.
5. **Check the zip:** no `coop_dev.lua`, no `mods.txt`, no `mods.json`; the loader is build 3.0.1-1218. Write down the SHA-256.
6. **Test the zip itself**, installed as a player does, with no test console: a join and a resync on two copies, and on two PCs if you can.
7. **Tag** the commit `v<new version>` and publish a GitHub release with the zip `ManorLordsCoop-<version>-nexus.zip` attached. Put the changes as a list under a heading `## New in <version>`.
   Without a browser: write the notes to `docs/releases/v<version>.md`, push the tested zip and its `.sha256` to the branch `release-zips`, then push the tag; `.github/workflows/cut-release.yml` publishes the release and starts the Nexus upload.
8. **Nexus is automatic:** publishing the release runs `.github/workflows/nexus-release.yml`, which sends that zip to the Nexus page as the new main file, sets the mod version and adds the changelog. It needs the repository secret `NEXUSMODS_API_KEY`. Check the Actions tab shows it green. Longer page text is still edited by hand on Nexus.
9. **Discord:** `#github-feed` posts the release by itself. Write the announcement in `#announcements`.

Never send a test build to players: test builds contain `coop_dev.lua`.

## Discord posts to GitHub issues

`.github/workflows/discord-issues.yml` runs every 15 minutes. It reads the `#bug-reports` forum and opens an issue for every post that has the forum tag **confirmed** (a moderator adds it), with the labels `from-discord` and `bug` (`crash`, `desync`, `needs-logs` by the post's tags and files). It answers in the post with the issue's link. Player names are not copied.

One-time setup (the owner): a Discord bot in the server with View Channel, Read Message History, Send Messages in Threads, and the **Message Content intent**; its token as the repository secret `DISCORD_BOT_TOKEN`. Without the secret the workflow does nothing. Try it from the Actions tab with `dry_run` = 1.
