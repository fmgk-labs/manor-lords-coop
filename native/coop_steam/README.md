# coop_steam.dll — the Steam link for Manor Lords Co-op

A small native DLL (plain C, x64) that does the job of `link/coop-link.ps1` for players who start the game through Steam,
without port forwarding or a VPN. It runs inside the game process, uses the game's own already-initialised
`steam_api64.dll`, and keeps the same on-disk contract as the PowerShell link, so the Lua mod does not change:
the mod appends lines to its own file and tails the others.

- Joining: an invite-only Steam lobby (up to 8 players: the host and 7 friends, `MAX_FRIENDS`; nothing shows on the host's friends list). The host sends invites through the Steam overlay.
- Data: Steam P2P through `ISteamNetworkingMessages` (Valve's relay; no ports, no IP addresses).
- Wire meaning: coop-link.ps1 protocol 1, one Steam message per protocol line.
- It never calls `SteamAPI_Init`, `SteamAPI_Shutdown`, `SteamAPI_RunCallbacks` or manual dispatch (the game owns those).
  It never loads `steam_api64.dll` itself.

Design source: `research/2026-11-10-game-probe/lanes/lane_s1/steam_feasibility.txt`. Where the task's fixed decisions
differ from that report (no `<seq>` on commands, `KICK <steamid>`, status format), the decisions below win.

## Files

| File | What |
|---|---|
| `coop_steam.c` | all of the DLL (about 2,100 lines) |
| `coop_steam_api.h` | the hand-written Steam declarations, each marked [C] certain or [U] uncertain |
| `build.cmd` | finds MSVC, builds `out\coop_steam.dll` and `out\coop_steam_test.exe`; `build.cmd test` also runs the test |
| `test\coop_steam_test.c` | the mock test (the same `coop_steam.c` compiled with `COOP_STEAM_MOCK` against a fake Steam) |
| `probes\probe_step1.lua`, `probes\probe_step2.lua` | live probes for the game's Lua console |
| `../../mod/ManorLordsCoop/Scripts/coop_steam.lua` | the Lua glue (a plug-in module, off unless `steam = on`) |

## How Lua drives it

The DLL has one export, `coop_steam_tick`, with the `lua_CFunction` shape `int f(void *L)`. It never touches `L`,
always returns 0, and does not link against Lua.

```lua
local tick = package.loadlib([[...\Scripts\coop_steam.dll]], "coop_steam_tick")
-- then, once per frame, on the game thread:
pcall(tick)
```

On the first call it does the following:

- **Pins itself** (`GetModuleHandleExW` with `PIN`), so Lua can never unload it while Steam holds pointers to its
  callback objects.
- **Finds its folder** and reads `coop_steam.cfg` there.
- **Empties `steam_cmd.txt`.** Commands from an earlier run are never replayed.
- **Looks up all 39 Steam functions** by name in the loaded `steam_api64.dll`.

All real work happens inside the tick, on the game thread. Steam callbacks only copy their event into a locked queue,
since they may run on another thread. Every tick is wrapped in SEH. Any exception switches the link off for good with
`off internal fault 0x... during <phase>` instead of crashing the game. Once off, a tick returns at once.

## Configuration: `coop_steam.cfg`

Put this file beside the DLL. It is optional, and lines take the form `key=value`.

| Key | Meaning |
|---|---|
| `linkdir=` | The link folder. The default is `<dll folder>\..\link`. With the DLL in `Mods\ManorLordsCoop\Scripts\`, the default is the mod's own `link` folder. |
| `savedir=` | This PC's save folder. It turns save transfer on. Without it, nothing is sent or written. |
| `sendrate_kb=` | Optional. Sets Steam's global SendRateMin/Max in KB/s. [U] |
| `sendbuffer_kb=` | Optional. Sets Steam's global SendBufferSize. [U] Leave both unset unless the 3 MB join is too slow. |

## Files in the link folder

The DLL touches only `host.txt`, `friend1.txt` to `friend7.txt`, the later files of their chains `host.<k>.txt` and
`friend<n>.<k>.txt` (k from 2, see "Link file turnover"), `steam_cmd.txt`, `steam_status.txt` (and `.tmp`),
`coop_steam.log` (and `.old`). On a friend PC it also touches, inside `savedir`, only
`coop_join_[1-3](_descr|_extradata[0-9]{1,2})?.sav`, the coat-of-arms pictures `coop_join_[1-3]_coat_[0-3].png`, and
their `.cooppart` temporary files.

### Link file turnover (lane 33, 2026-11-13; mock-tested only, NOT run in the game)

A player's link file is a chain: `host.txt`, then `host.2.txt`, `host.3.txt`, ... (the same for `friend<n>`). When the
file the mod writes is over its limit, the mod makes the next file, writes `<seq> <wallclock> ~NEXT <k>` as the last
line of the old one, and goes on in file k. The DLL's tail follows that line (on the host for `host`, on a friend for
its own `friend<n>`), sends it on like any other line, and the far side's mirror then writes file k. 30 s after the last
turnover (and 300 ticks), files older than the two before the current one are deleted, and the first file becomes the
one-line pointer `0 0.000 ~NEXT <oldest file kept>`, so a reader that starts finds the newest file by following the
chain. A writer that starts again empties its first file and deletes the numbered ones: a tail or reader whose file is
gone, with no later file, reads the first file from its start (the DLL sends `T`, as for a file that got shorter). A
mirror file that is locked keeps its lines and up to 16 waiting turnovers until it is free. The limit is set by the mod
(`coop.lua`): 4 MB by default while the Steam link (this DLL, 0.2 or later) is in a game. The wire format did not change,
but a friend's DLL older than 0.2 mirrors the `~NEXT` line without following it, and that friend's mod then waits for a
file nobody writes: every player needs DLL 0.2 (it ships with the mod, which already demands one version for all).

### Commands: `steam_cmd.txt`

The mod appends one command per line. The DLL reads them from a stored offset and logs each one.

| Command | Effect |
|---|---|
| `HOST` | Create the lobby (invite-only, 4 members). Lobby data `mlcoop=1` (protocol), `mlcoop_build=<game build>`, `mlcoop_slots=<sid>:<slot>,...` |
| `INVITE` | Open the Steam overlay invite dialog for our lobby (host only) |
| `JOIN <lobbyid>` | Join that lobby. Also happens by itself for a `+connect_lobby <id>` on the command line, or for an invite accepted in the overlay (callback 333). |
| `LEAVE` | Send `BYE` to the peers, leave the lobby, close the sessions 1.5 s later |
| `KICK <steamid>` | Host only. Steam has no lobby kick. The host sends `REFUSE kicked ...`, frees the slot and ignores that id for the rest of this lobby. The friend's DLL then leaves by itself. |
| `QUIT` | Like `LEAVE`, then the DLL switches itself off (`off stopped by the QUIT command`) |

### Status: `steam_status.txt`

The DLL rewrites this file atomically (temp file, then `MoveFileEx` with replace) whenever its content changes, at
most 10 times a second. It is UTF-8, with `\n` line ends.

```
<state> <my steamid64> [state arguments]                  line 1, always
info appid <n> overlay <0|1> relay <word> loggedon <0|1> build <n> proto <n> dll <version>    when Steam is usable
note <plain sentence, rest of line>                        optional: the last thing the player should know
<slot> <steamid64> <player state> <ping_ms> <persona name, rest of line>      one per player
```

Line 1, one of:

| Line 1 | Meaning |
|---|---|
| `off <id or 0> <plain reason, rest of line>` | Not usable. Examples: `waiting for the game to start Steam`, `the game has not started Steam (was it started outside Steam?)`, `steam api mismatch: <export> is missing ...`, `internal fault ...`, `stopped by the QUIT command`. |
| `idle <id>` | Also shown while a lobby is being created; the note then says `creating the game's Steam lobby`. |
| `hosting <id> <lobbyid>` | |
| `joining <id> <lobbyid>` | |
| `joined <id> <lobbyid> slot <n>` | `<n>` is 1–3. It is `-` until the host's `WELCOME` arrives. **A friend's mod must write `friend<n>.txt`.** |

Player lines:

- **Slots:** slot 0 is the host and 1–3 are friends.
- **States the DLL writes:** `connecting` (in the lobby, no handshake yet), `connected` and `disconnected`. The mod
  adds `loading` and `playing` itself (`Coop.steam.setPlayerState`). `invited` is never written, because the overlay
  dialog does not say who was invited.
- **Ping:** -1 when unknown. A friend sees the other friends with ping -1.
- **Persona name:** comes last, so spaces are safe. Control characters become `?` and the name is cut to 64 bytes.
- **Telling lines apart:** a player line starts with a digit; `info` and `note` lines start with those words.

This format adds three things to the one in the task brief:

- The SteamID is the second word of **every** header line, including `off`. This keeps the header parseable as
  `state id rest`.
- The `info` and `note` lines are new.
- A friend's slot reads `slot -` until `WELCOME` arrives.

`relay` words: `ok`, `waiting`, `attempting`, `retrying`, `failed`, `cannot-try`, `previously-worked`, `never-tried`,
`unknown`.

### Log: `coop_steam.log`

Each line is `YYYY-MM-DD HH:MM:SS.mmm text`. At 1 MB it moves to `coop_steam.log.old`. It holds SteamIDs and persona
names only, stays local and is never sent.

## Wire protocol (inside Steam messages, channel 0, reliable + no-Nagle)

| Message | Direction | Meaning |
|---|---|---|
| `HELLO 1 <nonce>` | friend → host | repeated every 2 s until welcomed. A new nonce after each loss of the link. |
| `WELCOME <slot> <nonce>` | host → friend | the host picks the slot (lowest free, the same slot again for the same SteamID) |
| `REFUSE <code> <reason>` | host → friend | codes `bad-version`, `host-full`, `kicked`. The friend leaves and shows the reason. |
| `HI` | host → lobby member | every 2 s until the member says hello. This opens the session from the host's side even if no callback arrives. |
| `L <mod line>` | both | one line, byte for byte, up to 64 KB |
| `T` | both | the sender's file was emptied (the mod restarted). The copy is emptied, then new lines follow. |
| `PING <ms>` / `PONG <ms>` | both | every 2 s. Any message counts as alive. After 10 s of silence the peer is `disconnected`. |
| `F <name> <size> <sha256>` / `C <raw bytes>` / `E <name>` | host → friend | a save file, sent in chunks of up to 64 KB |
| `BYE` | both | leaving now |

Rules carried over from coop-link.ps1:

- **Star layout.** Friends talk only to the host. A friend ignores everybody else, and the host accepts files from
  nobody.
- **Lines go to friends connected at read time.** A line from `host.txt` goes only to the friends connected when it
  was read.
- **S coalescing.** When a peer's link is behind (Steam answers `LimitExceeded`), only the newest unsent `S` state
  line is kept. Every other line is kept, in order.
- **Queue caps.** At more than 16 MB queued, the host cuts the peer, and the friend drops its backlog.
- **Save before `J LOAD`.** A `J LOAD coop_join_N <level>` line is held, along with every line after it, until the
  save files are complete. Complete means all files exist and have stayed unchanged for 300 ms. The main file must not
  be older than its `_descr` file by more than 2 s, and both must be non-empty. The files are read once into memory,
  hashed (SHA-256), and sent before the line. After 15 s the line goes anyway, and the log says why.
- **A single load names its friends (lane 15, 2026-11-12; mock-tested only, never run on real Steam).** The mod's
  single resync writes `J LOAD coop_join_N <level> <friendN,friendM> <id>`. The save then goes only to the named
  friends; the others get the line (their mod ignores it) and no file, so their lines are not held behind a transfer.
  A line without that field (every copy loads) sends the save to every friend, as before. A DLL built before this
  change reads only the first six words of the line and sends the save to every friend: it still works with the
  single resync, but every friend's lines then wait behind a save it does not need.
- **Friend side of the transfer.** The friend writes `<name>.cooppart` and checks size and SHA-256 on disk, then
  renames it over the final name.
- **Coat-of-arms pictures (lane 33, 2026-11-13; mock-tested only).** The four pictures `<save>_coat_0.png` to
  `_coat_3.png` go with the save, after its other files, with the same checks (still on disk, 64 MB cap, SHA-256, the
  name pattern, never outside `savedir`). A picture the host does not have is not sent and is not an error (the friend
  keeps whatever picture of that name it had). A friend on an older DLL refuses the picture names in its log and goes
  on: the rest of the save and every line still arrive.
- **Refusals.** Bad names, sizes over 64 MB, non-numeric sizes, malformed checksums and checksum mismatches are all
  refused and logged. Nothing is ever written outside `savedir`. Nothing received is ever executed.

## Build

```
native\coop_steam\build.cmd          builds out\coop_steam.dll and out\coop_steam_test.exe
native\coop_steam\build.cmd test     ... and runs the mock test
```

The script finds MSVC through `vswhere`, falling back to VS 18 Community and then VS 2019 BuildTools. It built here
with MSVC 14.51 (VS 18 Community) using `/O2 /MT /W4 /WX /GS /std:c11`, with zero warnings. No Steamworks SDK is used.

`dumpbin` on `out\coop_steam.dll` (built 2026-11-10):

- **`/exports`:** one export, `coop_steam_tick`.
- **`/dependents`:** `KERNEL32.dll` and `bcrypt.dll` only. Both are Windows system DLLs, and there is no CRT DLL
  (`/MT`).

## Test results (mock Steam, 2026-11-10)

`build.cmd test` reported **69 passed, 0 failed**, and the temporary folder `%TEMP%\coop_steam_test_<pid>` was removed.
(2026-11-13, lane 33: **97 passed, 0 failed**; 77 before its change. The 20 new checks: coat pictures sent, received,
a missing one, eight bad names refused, the name pattern; link file turnover: names, the `~NEXT` line, three turnovers
with two in a row, the old files kept and then cleaned, a friend that loads alone while the file turns over twice and
reads again from its MARK, a mirror file locked across two turnovers, the host's game starting again, the friend's
own file turning over. Details: `research/2026-11-10-game-probe/lanes/lane_s21_33/report.txt`.)

The fake Steam runs five or more "PCs" in one process, each with its own link and save folders, on virtual time. It
provides:

- lobbies, with call results and callbacks; callbacks go through the hand-built objects, alternating vtable slots 0
  and 1, with the size getter checked;
- session requests, which are held until accepted;
- a send buffer that fills up, and a bandwidth limit;
- a switch that cuts the network.

The test proves the following:

- **Lines, both ways.** 500 lines `host.txt` → friend and 300 lines `friend1.txt` → host, each arriving all, once and
  in order.
- **Truncate.** `T` works both ways.
- **Oversize lines.** A line over 64 KB is skipped and logged, and the next line arrives.
- **S coalescing on a slow link.** All 30 non-state lines arrive in order, 18 of 270 S lines are sent, and the newest
  S line arrives last.
- **Slots.** Friends get slots 1, 2 and 3. A 5th player gets "the lobby is full". A non-member's session is not
  accepted and gets no slot. Friends see each other through the host's slot list. Control characters are cleaned out
  of names.
- **3 MB save** (3 files) to 3 friends. On every step the test checked whether the `J LOAD` line had appeared. When it
  appeared, all files were already there with the host's SHA-256. No temporary file was left.
- **20 MB save written after the `J LOAD` line.** The line is held while the file is missing or still changing. The
  files arrive complete before the line. The lines after it keep their order.
- **A save that never appears.** The line goes after 15 s, with the reason logged.
- **Refusals.** A path in the name, a name outside `coop_join_[1-3]`, a size over 64 MB, a size that is not a number,
  and a wrong checksum are all refused. The temporary file is deleted and the existing save is untouched. A friend
  sending files to the host is ignored.
- **Ping/time-out.** After 10 s of silence both sides show `disconnected` and the others stay connected. When the
  network is back, the friend returns to the same slot and lines flow again both ways.
- **`KICK` and `LEAVE`.** `KICK` gives a plain reason and removes the player. A friend's `LEAVE` shows `disconnected`
  on the host at once. The host's `LEAVE` gives the friends "the host closed the game", and the lobby is gone.
- **Joining paths.** `+connect_lobby <id>` on the command line works, and so does the overlay invite (callback 333).
  Joining works with only the callback and also with only the call result.
- **Refused lobbies.** Another co-op version, no co-op key, another game build, and a lobby that does not exist are
  each refused in plain words.
- **Fail closed.** With no Steam, the status is `off` while waiting, then `off` for good after 60 s. A missing export
  gives `off steam api mismatch ...`. An access violation inside the DLL gives `off internal fault 0xC0000005 ...`
  without crashing. Once off, 1000 ticks write nothing.
- **Callback object.** Both vtable slots were used, with 0 size mismatches.
- **File names.** Only the allowed names exist in the link folders.

The test can fail. Two deliberate mutations were checked:

- Sending the `J LOAD` line before its save gave 4 FAILs.
- Turning off S coalescing gave 1 FAIL.

### Other checks on the real binary

- **Real-DLL harness.** A throwaway harness, kept in the session scratchpad and not in the repo, loaded a copy of
  `out\coop_steam.dll` with `LoadLibraryW`. It called `coop_steam_tick(NULL)` 5 times, then called `FreeLibrary`.
  - The DLL stayed loaded, so the pin works.
  - The status was `off 0 steam_api64.dll is not loaded in this game (...)`, which is the correct fail-closed answer
    outside the game.
  - With no cfg, the files went to `<dll folder>\..\link`.
  - With a cfg written with a UTF-8 BOM, a comment line and `linkdir = ...\my link dir` (spaces), the DLL used that
    folder and created `savedir`.
- **Export names.** All 39 export names in the code were compared mechanically with
  `steam_api64_v157_exports.txt`, and all are present.

### Not run here

- **The Lua code.** No Lua interpreter is installed on this PC, so `coop_steam.lua` and both probes have never been
  parsed or run. The first console run is also their syntax check.
- **Tick cost.** It is not measured. An idle tick polls one small file and rewrites nothing. When connected, it also
  opens the mod's own file and the mirror files.
- **Real Steam.** The mock cannot prove anything about the real Steam ABI: layouts, ids, vtable order, or which thread
  runs callbacks. That is what the live steps are for.
- **Faults.** If a fault switches the link off while it is in a lobby, the lobby stays joined until the game exits.
  Nothing is sent after the fault.

## Steam facts used: certain [C] / uncertain [U]

| Fact | Mark | How the live run settles it |
|---|---|---|
| All 39 export names (`SteamAPI_SteamUser_v021`, `..._SteamNetworkingMessages_SteamAPI_v002`, `SteamAPI_ISteamMatchmaking_CreateLobby`, ...) | [C] seen in the DLL's export table | a missing one gives `off steam api mismatch: <name>` |
| Flat calling shape: interface pointer first; C++ references passed as pointers; `bool` is one byte | [C] | |
| `SteamNetworkingMessage_t`: `m_pData`@0, `m_cbSize`@8, `m_identityPeer`@16 (136 bytes), `m_nChannel`@192; freed with the `_Release` export | [C] stable since SDK 1.47; static asserts in the code | |
| `SteamNetworkingIdentity` filled and read only through the `SetSteamID64`/`GetSteamID64` exports (oversized buffer) | [C] | |
| `LobbyCreated_t` (16 bytes), `LobbyEnter_t` (24), `LobbyChatUpdate_t` (32), `GameLobbyJoinRequested_t` (16), pack 8 | [C] fields; static asserts | `CreateLobby call completed: got=1` in the log |
| ELobbyType FriendsOnly = 1; send flags Reliable 8 / NoNagle 1; EResult OK 1, LimitExceeded 25; chat-member flags; relay availability values | [C] | |
| `SendMessageToUser` implicitly accepts a pending session request | [C] (header text, read in lane S1) | |
| Callback ids 331, 333, 504, 506, 513, 1251, 1252 | [U] the offsets were read in the headers, but the bases 300/500/1250 are from memory | the first time each id fires, the log says `first callback <id> (<name>, our size N, thread T): first bytes ...` |
| CCallbackBase layout (vtable, flags@8, id@12) and vtable order | [U] the order is disputed, so one handler sits in slots 0 and 1 and the size getter in slot 2 | after registering, the log lists each callback's flags. `0x01` means Steam accepted the object. Step 2's overlay test fires callback 331. |
| Whether steam_api compares our `GetCallbackSizeBytes` with the real size before calling us | [U] | a callback that never shows up in the log may have the wrong size. Every path that depends on a callback also has a polled twin: members every 500 ms, `HI` for sessions, call results polled. |
| `GameOverlayActivated_t` size 8 (`m_bActive`, `m_bUserInitiated`, `m_nAppID`) | [U] | only `m_bActive` is read; the first-bytes log line shows it |
| `SteamNetworkingMessagesSessionFailed_t` advertised as 696 bytes | [U] | only its first 136 bytes (the identity) are read; the 10 s silence rule does the real work |
| The game's own `RunCallbacks` leaves our call results for `GetAPICallResult` | [U] (R3 in the report) | log `CreateLobby call completed: got=1`. Otherwise the LobbyCreated/LobbyEnter callbacks do the job. Both paths are tested in the mock. |
| `GetRelayNetworkStatus(NULL)` is allowed | [U] (believed from the docs) | `relay` in `info` |
| `SendRateMin/Max/SendBufferSize` enum values 10/11/9 | [U] | only used when the cfg asks |
| `+connect_lobby <id>` reaches `ManorLords-Win64-Shipping.exe` through the bootstrap exe | [U] | log `the command line has +connect_lobby ...` |
| The engine's own OnlineSubsystemSteam ignores our invites and lobby | [U] (R5) | watch the game when the invite is accepted |
| The thread that runs callbacks | [U] (expected: UE's online thread) | the first-callback log line prints `delivered on thread N, game thread M`, with `N` recorded inside the handler |
| The size Steam actually delivers for a callback | not observable | `Run(void*)` receives no size, so the log shows the first 24 bytes instead |

## Lua glue

`mod/ManorLordsCoop/Scripts/coop_steam.lua` is a plug-in module like `coop_join.lua`, and it is off unless
`coop.cfg` has `steam = on`.

- **Loading.** It loads the DLL from `Scripts\coop_steam.dll`, or else from the mod folder. It ticks the DLL inside
  `pcall` from both `tick` (world) and `idle` (main menu, where a friend accepts an invite).
- **Calls.** It exposes `Coop.steam.host()`, `.invite()`, `.join(id)`, `.leave()`, `.kick(id)`, `.quit()` and
  `.status()`. `status()` parses the file at most 4 times a second.
- **Commands at start-up.** Commands given before the DLL's first tick are held, because the DLL empties
  `steam_cmd.txt` at start.
- **Link folder.** It warns if the DLL's link folder is not `_G.COOP_LINK_DIR`.
- **Slot.** On a friend's copy it switches the mod's own file to `friend<slot>.txt` when the status gives the slot.
  Turn this off with `Coop.steam.followSlot = false`.

To wire it in, add these two lines. They are not added yet.

1. In `main.lua`, add `coop_steam.lua` to the module list:

   ```lua
   for _, m in ipairs({ "coop_town.lua", "coop_world.lua", "coop_join.lua", "coop_steam.lua" }) do
   ```

2. In `coop.cfg`:

   ```
   steam = on
   ```

`main.lua` still returns early when `role = off`, so the module only runs with `role = host` or `role = friend`.

## Live test steps

### One Steam account

Step 0 (`package.loadlib`) is already confirmed live.

1. **`probes/probe_step1.lua`.** Copy the DLL to a folder of its own outside the game folder, for example
   `C:\coop_steam_probe\bin\`, then start the game **through Steam**. Expect `idle`, a SteamID, app id 1363080,
   overlay 1, and relay `ok` after a few seconds. In the log, check that all 7 callbacks show `flags 0x01`. A copy
   started outside Steam should give `off ... the game has not started Steam` after 60 s.
2. **`probes/probe_step2.lua`.** It runs HOST, shows the lobby id, keeps the lobby for 30 s, then runs LEAVE. While
   the lobby is open, press Shift+Tab twice. Expect these log lines:
   - `hosting lobby ... read back '1'; members 1`
   - `CreateLobby call completed: got=1` and/or `LobbyCreated callback`
   - `first callback 331 ... thread N`, followed by `overlay opened` and `overlay closed`

   Then repeat the run with `OPEN_INVITE = true` once, to see the invite window.

### Two accounts on two PCs

Each Steam account must own the game, and each PC needs the mod plus `steam = on`.

3. **Invites.**
   - With the friend's game closed: the host invites, the friend accepts in Steam, and the game starts. The friend's
     log should show `the command line has +connect_lobby ...`, then `joined lobby`, then `connected to the host as
     friend1`.
   - With the friend's game running: accept the invite in the overlay. Expect callback 333, then joined.
   - In both cases, note anything the game itself does when the invite is accepted.
4. **P2P.** Look for `session request ... accepted=1` or the `HI` path, PING round trips in the status, and
   `disconnected` within 10 s when one side pulls its cable.
5. **Link files.** Run the README session 11 play test over Steam instead of TCP. Every line should arrive once and in
   order, and the tick cost should stay small.
6. **Save at join.** Set `savedir=` on both PCs, then have a friend join a running game. Expect `received
   coop_join_N.sav ... checksum OK` before `the J LOAD line ... arrived after its files`. Repeat 10 times.
7. **Menu commands end to end, and failure drills.** Run `KICK`, `LEAVE`, host quit, a friend without the mod (the
   30 s note), and a version mismatch. Then play once with 3 friends.
