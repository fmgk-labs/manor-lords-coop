# Contributing

Thank you for helping. Right now the most useful help is **testing with friends**, **good bug reports**, and **fixes with proof from the game**.

Please follow the [Code of Conduct](../CODE_OF_CONDUCT.md).

## Ways to help

| You are | You can |
|---|---|
| A player | Play a session with a friend and tell us what happened. Use [REPORTING_BUGS.md](REPORTING_BUGS.md). |
| A tester | Try what nobody ran yet: 3 or more players, long sessions, a late-game town. See [KNOWN_ISSUES.md](KNOWN_ISSUES.md), section A. |
| A developer | Read [HOW_IT_WORKS.md](HOW_IT_WORKS.md) and [BUILDING.md](BUILDING.md). Open an issue before a big change. |

Questions: Discord `<DISCORD_INVITE>` (channel **#dev-talk**). Bugs and ideas: https://github.com/fmgk-labs/manor-lords-coop/issues

## 1. Set up a test copy of the game

**Never test in your real install. Never test with your real saves.**

1. Install Manor Lords **0.8.117** from Steam.
2. Copy the whole game folder (the one Steam opens with **Manage > Browse local files**) to another place, for example `<test copy>`.
3. Put the UE4SS loader build **3.0.1-1218** into `<test copy>\ManorLords\Binaries\Win64` (`dwmapi.dll` next to the `.exe`, the `ue4ss` folder beside it).
4. Give the copy its own save folder: start it with the game's `-saveddirsuffix=<name>` option. Its saves then go to a separate folder, not your real one.
5. Build the DLLs and a test zip ([BUILDING.md](BUILDING.md)) and unzip it into the copy's `Win64` folder.
6. To run a host and a friend on one PC, start the **same** test copy's `.exe` twice, both with `COOP_STEAM=off`: once with `COOP_ROLE=host`, once with `COOP_ROLE=friend` and `COOP_NAME=friend1`. Both use the same mod folder, so they talk through its `link` folder. (Two separate game folders do not talk unless `COOP_LINKDIR` points both at one folder.)

Each copy takes about 4 GB of memory. Two copies are enough for most tests.

## 2. The test harness, in short

`tools/dev/` (Git Bash) automates step 1 to 6:

| Script | Does |
|---|---|
| `lane_setup.sh` | makes a numbered test copy and save profile ("lane") |
| `up.sh` | builds a test zip, installs it into the lane's copy, starts host and friend in background windows, loads a test save, waits for the join |
| `np.sh` | helpers: run Lua in a copy, open a building's panel, "press" a button by calling the game's own click handler |
| `down` | closes only the copies this lane started |

Before you use it, copy `tools/dev/local.env.example` to `tools/dev/local.env` and fill in your PC's paths (the file is git-ignored). The full guide, with a first-time setup, is `tools/dev/README.md`.
A "press" is not a real click. A real click with the mouse on two copies is the strongest proof.

## 3. Rules for code

1. **The host is the authority.** A friend's copy never decides a result the host decides: deaths, routs, a site's end, stock, totals. **A friend must never show a value the host never had.**
2. **Keep the game vanilla.** Use the game's own functions first. Write own code only where the game has nothing.
3. **Check a handle is alive before you use it** (UE4SS). Ask `IsValid()` in the same frame you use the object. After a load, every kept object is freed memory: drop what you keep in your module's `onWorld`. Never keep a game object across a world change.
4. **Never read past the end of a game array.** In UE4SS Lua, reading `arr[n]` past the end **grows** the array with empty entries. That once crashed the game's save. Check `#arr` first.
5. **Hooks only set a flag.** All work happens in the mod's one driver tick, on the game thread.
6. **Native code checks itself.** Every patch is found by a code signature at start-up and switches itself off when the game changed. Never write to the game file on disk.
7. **Nothing ships switched off.** Code in the zip is on. If it is not ready, it does not go in.
8. **No test-only code in the player zip.** `coop_dev.lua` and the test console stay out (the packager checks this).

## 4. Proof

A change is "done" only with proof from the game. Say how you tested it:

| Word | Means |
|---|---|
| real click | you clicked it with the mouse in the game |
| press | the game's own button handler was called |
| console | the game function was called from a console |
| two copies | host and friend on one PC |
| two PCs | host and friend on two PCs over Steam |

Test **both directions** (host to friend, friend to host), once after a resync, and in a short run at speed 4 with a demolish. Give the numbers from your run.
For native changes, run `build.cmd test` for the piece you changed ([BUILDING.md](BUILDING.md)).
A scripted pass is not proof of what a player sees.

## 5. Pull requests

- Branch from the repository's default branch (`main`). Pull requests go back into it.
- One topic per pull request. Fill in the pull request template.
- If the version changes, change `C.version` in `mod/ManorLordsCoop/Scripts/coop.lua`. Every player must then use the new zip.

## 6. Privacy in commits

Never commit:

- Windows user names, real folder paths of your PC, Steam names or Steam IDs, e-mail addresses;
- crash records from the game (they hold your Windows user name);
- logs you did not check first.

Use placeholders such as `<game folder>`.

## License

The project is under the MIT licence: see [LICENSE](../LICENSE). By sending a contribution you agree that it is published under that licence.

## About `research/` and `ledger.md`

Some code comments and READMEs point to `research/...` or `ledger.md`. Those are the author's private test notes: logs of hundreds of test runs. They are not in this repo. The code and the docs here are complete without them. If a comment's reason is unclear, ask in an issue or on Discord.
