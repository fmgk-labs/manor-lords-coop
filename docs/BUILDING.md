# Building from source

How to build the two native pieces, run their tests, and make the player zip.
The Lua scripts need no build: they ship as text.

In this page:

- `<repo>` is your checkout of this repository.
- `<game folder>` is a Manor Lords folder (the one Steam opens with **Manage > Browse local files**).
  **Use a copy of the game for development**, not your real install.

## What you need

| Tool | Why |
|---|---|
| Windows 10 or 11, x64 | The DLLs are Windows x64 |
| Visual Studio 2019 or newer, or the VS Build Tools, with **Desktop development with C++** (MSVC x64) | Builds the DLLs. `build.cmd` finds it by itself |
| PowerShell 5 or newer | Runs `tools\package.ps1` |
| A copy of Manor Lords **0.8.117** with the UE4SS loader build **3.0.1-1218** in its `Win64` folder | The packager copies the loader from there. The signature check reads the game file |
| Git Bash | Optional: the test harness in `tools/dev/` |

No Steamworks SDK is needed. The Steam piece uses the game's own `steam_api64.dll` at run time.

## 1. Build the native pieces

From `<repo>`:

```bat
native\coop_patch\build.cmd
native\coop_steam\build.cmd
```

| Output | What it is |
|---|---|
| `native\coop_patch\out\coop_patch.dll` | the shipped patch DLL (one export: `coop_patch_tick`) |
| `native\coop_patch\out\test\` | the test build of the same source, and its test programs |
| `native\coop_patch\out\tools\sigcheck.exe` | the offline signature checker |
| `native\coop_steam\out\coop_steam.dll` | the shipped Steam DLL (one export: `coop_steam_tick`) |
| `native\coop_steam\out\coop_steam_test.exe` | the mock Steam test |

Both build with `/MT /W4 /WX`: no C runtime DLL, and any warning fails the build.

## 2. Run the native tests

```bat
native\coop_patch\build.cmd test "<game folder>\ManorLords\Binaries\Win64\ManorLords-Win64-Shipping.exe"
native\coop_steam\build.cmd test
```

**Pass the path of the game file** to the patch test. Without it, the check reads `<ML_TEST_ROOT>\_ml_test\...` when `ML_TEST_ROOT` is set (the environment or `tools\dev\local.env`, see section 4), and otherwise prints its usage and fails.

| Test | What it checks | Last result on record |
|---|---|---|
| a. Offline signature check | Reads the game `.exe` **as a file** (it never starts the game). Every code signature must match exactly once | 77 of 77 |
| b. Mechanism test | Synthetic game modules in memory; the test build of the DLL driven through its command file | 673 of 673 |
| b2. Image test | The shipped DLL against a real image-backed code section | 18 of 18 |
| c. dumpbin | One export, no test functions in the shipped DLL | (no count) |
| Steam mock test | A fake Steam with several "PCs" in one process: lines, slots, save transfer, refusals, time-outs, file turnover | 97 passed (2026-11-13) |

The mock test cannot prove anything about real Steam. Only a game session over Steam can.

## 3. Make the player zip (Nexus)

Build both DLLs first. Then:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\package.ps1 -Variant nexus -Game "<game folder>"
```

**Pass `-Game`.** Without it the packager uses your test copy `<ML_TEST_ROOT>\_ml_test` from `tools\dev\local.env` (section 4), and stops when that is not set.

What it does:

- Reads the version from `mod\ManorLordsCoop\Scripts\coop.lua` (`C.version`).
- Copies the loader from `<game folder>\ManorLords\Binaries\Win64`: `dwmapi.dll`, `ue4ss\UE4SS.dll`, `ue4ss\UE4SS-settings.ini`, `ue4ss\LICENSE`, `ue4ss\Mods\shared\`.
- Copies the mod: the Lua scripts, both DLLs, `coop.cfg`, an empty `enabled.txt`, a `link\` folder with a short readme.
- Leaves out `coop_dev.lua` (the test console channel). It **stops** if that file is still in the zip.
- Writes **no** `mods.txt` and **no** `mods.json`, so a player's own mod list is not touched.
- Adds the player's install note `docs\INSTALL-nexus.txt` as `ManorLordsCoop-INSTALL.txt`.

Output:

| File | What |
|---|---|
| `dist\ManorLordsCoop-<version>-nexus.zip` | the upload file |
| `dist\INSTALL-nexus.txt` | the install note (also inside the zip) |

**Check before you upload:**

1. The loader in `<game folder>` must be build **3.0.1-1218** (git `560411f1`). The first lines of `ue4ss\UE4SS.log` name it. The loader's settings file must be the one the mod was tested with: console windows off (`ConsoleEnabled = 0`, `GuiConsoleEnabled = 0`, `GuiConsoleVisible = 0`).
2. Open the zip. `coop_dev.lua`, `mods.txt` and `mods.json` must not be there.
3. Write down the version and the SHA-256 of the zip.

Other variant: `-Variant full` (the default) adds a `mods.txt` and a `mods.json` and the note `docs\INSTALL.txt` (also needed at that path).
With `-Dist` other than `dist`, the full variant is a **test build** and keeps `coop_dev.lua`. Never send a test build to players.

## 4. The test harness, in one paragraph

`tools/dev/` is a set of Git Bash scripts for testing **without the real mouse and without the real install**.
`lane_setup.sh` makes a numbered copy of the game and a separate save profile. `up.sh` builds a test zip from your checkout, installs it into that copy, starts a host and a friend as background windows on one PC (Steam off, a shared link folder), loads a test save and waits for the join. `down` closes only the copies you started.
A small queue of "game slots" limits how many copies run at once (memory).
In a running copy you can run Lua through a separate test console mod, and "press" a panel button by calling the game's own click handler.
Your PC's paths go in `tools/dev/local.env` (copy `tools/dev/local.env.example`; the file is git-ignored). Every script of the harness, `tools\package.ps1` and `build.cmd test` read it.
The test console mod is in `tools/dev/CoopProbe/`; `up.sh` installs it into the test copy.
Never point the harness at your real game folder or your real saves. Full guide, with a first-time setup: `tools/dev/README.md`.

## 5. Other checks

- **Lua test scripts** in `mod/ManorLordsCoop/tests/` are old console scripts. Their plans say they were written without a game. The real proof is a session on two copies (section 4) and, best, real clicks.
- There is no Lua interpreter in the build. A Lua syntax error shows up as a load error in `ue4ss\UE4SS.log` and in the mod's log at the next game start.
