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

**Note:** the roles Triage and Maintain exist only for repositories owned by a GitHub **organization**.
On a personal account every collaborator gets the same access (about Write).
To use these roles, create a free organization and move the repository there (**Settings** > **Transfer**). The owner stays Admin.

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

1. Did they use the template? Are the log files there? If not: label `needs-logs` and ask for them.
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
7. **Tag** the commit `v<new version>` and make a GitHub release with the zip, its SHA-256 and the changes.
8. **Upload the same zip** to Nexus Mods. Update the version and the changes on the Nexus page.
9. **Announce** it on Discord in `#announcements` and `#changelog`.

Never send a test build to players: test builds contain `coop_dev.lua`.
