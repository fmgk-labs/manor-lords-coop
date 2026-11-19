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

Since 0.5 (lane 65) there is a second export of the same shape, `coop_steam_flush`. The mod calls `coop_steam_tick`
FIRST in its frame (what came over Steam is in the link files before the mod reads them) and `coop_steam_flush` LAST
(it only reads this copy's own file and sends what waits), so a line received is read in the frame it came and a line
the mod wrote leaves in the frame it was written. Before, the tick ran among the mod's modules: a frame later each way
(about 60 ms a hop at 16 fps). The mock counts it: a host line to the friend's read 2 frames before, 1 after; a friend
module's line to the host's read 3 before, 1 after (one frame of each is the mock's network).

On the first call it does the following:

- **Pins itself** (`GetModuleHandleExW` with `PIN`), so Lua can never unload it while Steam holds pointers to its
  callback objects.
- **Finds its folder** and reads `coop_steam.cfg` there.
- **Empties `steam_cmd.txt`.** Commands from an earlier run are never replayed.
- **Looks up all 40 Steam functions** by name in the loaded `steam_api64.dll` (39 until DLL 0.4; the 40th,
  `SteamAPI_ISteamMatchmaking_SetLobbyOwner`, is optional and is in the game's export list).

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

### File opens (0.5, lane 65; mock-tested only, NOT run in the game)

On a friend's PC whose real-time scan checks every file opened after a write, each open of a link file cost
milliseconds, and DLL 0.4 opened about 2 to 3 files a tick (the command file, the tail's file, the mirror file at every
write, the log at every line). Since 0.5 a handle is kept while its file is in use and let go after 1 s without use
(`HANDLE_IDLE_MS`), on a turnover, on a clear and on a failure. A tail without a handle looks at its file's attributes
first (no open) and opens it only when the size changed; its read handle shares delete, so a writer that starts again
can delete the file meanwhile (that file grows no more, and the handle is let go). A mirror's write handle does not share
delete (nobody else deletes a mirror file); a write that fails keeps its lines and is tried again with a new handle (a
part written is not written twice). The mock test counts the opens (`INFO file opens a second ...`): with a host's mod
writing about 40 lines a second and a friend's one a second, 132 (host) and 173 (friend) opens a second at 62 ticks a
second with 0.4, 0.2 and 0.2 with 0.5.

### Commands: `steam_cmd.txt`

The mod appends one command per line. The DLL reads them from a stored offset and logs each one.

| Command | Effect |
|---|---|
| `HOST` | Create the lobby (invite-only, 4 members). Lobby data `mlcoop=1` (protocol), `mlcoop_build=<game build>`, `mlcoop_slots=<sid>:<slot>,...` |
| `INVITE` | Open the Steam overlay invite dialog for our lobby. Since 0.3 only for a lobby this copy is in right now (owner and member, asked of Steam at that moment). Without one (never hosted, or the lobby was lost) a new lobby is made first and the dialog opens for that one. While Steam is offline nothing is made or opened; the note says so and the dialog opens when Steam is back (it waits up to 2 minutes). Refused with a note on a copy that is in another player's game. See "The host's own place in its lobby". |
| `JOIN <lobbyid>` | Join that lobby. Also happens by itself for a `+connect_lobby <id>` on the command line, or for an invite accepted in the overlay (callback 333). |
| `LEAVE` | Send `BYE` to the peers, leave the lobby, close the sessions 1.5 s later |
| `KICK <steamid>` | Host only. Steam has no lobby kick. The host sends `REFUSE kicked ...`, frees the slot and ignores that id for the rest of this lobby. The friend's DLL then leaves by itself. |
| `QUIT` | Like `LEAVE`, then the DLL switches itself off (`off stopped by the QUIT command`) |

### Status: `steam_status.txt`

The DLL rewrites this file atomically (temp file, then `MoveFileEx` with replace) whenever its content changes, at
most 10 times a second; a change of the pings alone at most every 5 s (0.5). The mod reads it at most twice a second. It is UTF-8, with `\n` line ends.

```
<state> <my steamid64> [state arguments]                  line 1, always
info appid <n> overlay <0|1> relay <word> loggedon <0|1> build <n> proto <n> dll <version>    when Steam is usable
note <plain sentence, rest of line>                        optional: the last thing the player should know
lost <times> <friends>                                     since 0.3, once a host lost its own lobby in this run: how often,
                                                           and how many friends were connected at the last time
reconnecting <seconds>                                     since 0.4, state hosting: the host's place in its lobby is lost and
                                                           it tries to get back in (the window's length, 30)
hostlost <seconds>                                         since 0.4, state joined: the host is out of the lobby and this
                                                           friend waits for it (the window's length, 30)
back <times>                                               since 0.4: how often the link came back inside the window, in this run
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
- **Telling lines apart:** a player line starts with a digit; `info`, `note`, `lost`, `reconnecting`, `hostlost` and
  `back` lines start with those words.

This format adds three things to the one in the task brief:

- The SteamID is the second word of **every** header line, including `off`. This keeps the header parseable as
  `state id rest`.
- The `info` and `note` lines are new.
- A friend's slot reads `slot -` until `WELCOME` arrives.

`relay` words: `ok`, `waiting`, `attempting`, `retrying`, `failed`, `cannot-try`, `previously-worked`, `never-tried`,
`unknown`.

### Log: `coop_steam.log`

Each line is `YYYY-MM-DD HH:MM:SS.mmm text`. At 1 MB it moves to `coop_steam.log.old`. It holds SteamIDs; since 0.3 it
holds no persona names (0.2 wrote `<name> (<id>) connected as friendN` and the "has not answered" note with the name).
The DLL never sends it. Since mod 0.2.3 the player's **Make Bug Report** copies it and `steam_status.txt` into the
report zip: the native piece (`native/coop_patch/coop_scrub.h`, `scrub_steam`) takes the names out by the shape of the
line (a name becomes its slot, `host` / `friend 1`, or `<name>`), also in lines an older DLL wrote, and cuts every
SteamID to its last 4 digits.

### The host's own place in its lobby (0.3, lane 62; mock-tested only, NOT seen on real Steam)

First public session, two PCs (2026-11-17): the host switched a VPN on. Steam took the HOST out of its own lobby (a
lobby chat update for the host's own id, change 0x4). DLL 0.2 went on as `hosting`: it called the friend "left the
Steam lobby" and opened the invite dialog for the dead lobby, so no invite ever reached the friend.

Since 0.3 a host is "in its lobby" only while Steam says it is the lobby's owner and a member. (Since 0.4 a sign does
not end the lobby at once: it starts a 30 s window in which the host tries to get back in, see the next section. What
this section says happens "then" happens at the window's end, or at once when Steam says the lobby is gone.)

| Sign | When it counts |
|---|---|
| Steam's word: a lobby chat update for the host's own id with left (0x2), disconnected (0x4), kicked (0x8) or banned (0x10) | at once |
| The polled twin, every 500 ms: `GetLobbyOwner` is not this host, or this host is not in the member list | after 6 failed checks in a row (3 s). Never seen on real Steam, and acting on it ends the lobby for good, so one bad answer is not enough. |
| Steam was offline (`BLoggedOn` 0) and is back | one failed owner/member check right then. While Steam is offline nothing is decided (a short break may leave the lobby whole) and the member list is not read. |

Then (`host_lost_lobby`): `BYE` to the friends, `LeaveLobby` on the old lobby (never a second lobby beside a half-dead
one), every peer dropped, state `idle`, the log line `THIS HOST LOST ITS OWN PLACE IN LOBBY ...`, the status line
`lost <times> <friends>` and the note `Your Steam connection dropped. Your friends were sent to the main menu. Press
Invite Friends to bring them back.` (without friends: `... Press Invite Friends to open a new lobby.`). The mod tells
the player once per `lost` count (`coop_ui.lua`). A member list without this host never makes a friend "left the Steam
lobby". The next `INVITE` makes a new lobby and opens the dialog for it; a friend that accepts joins as usual.

Not known until two PCs repeat it: whether real Steam always sends the own-id update, and what `GetLobbyOwner` and the
member list answer on the host after such a drop (the polled twin depends on it).

### A short drop does not end the session (0.4, lane 62 part two; mock-tested only, NOT seen on real Steam)

In that live case the host's game and Steam were back within seconds, yet the friend was sent home at once (its own
check: lobby owner is not the host, or the host is not a member, asked every 500 ms). Since 0.4 a loss sign starts a
window of `GRACE_MS` (30 s, the number of the mod's silence rule) on both sides instead of ending anything.

**Host.** The three signs of the section above are unchanged; they now start the window (`host_window_begin`):

- status `reconnecting 30`, note `Your Steam connection dropped. Trying to reconnect (30 s)...`, state stays `hosting`;
- the peers and their slots are kept; the member list is not read (it may be stale: in the live fault it made the
  friend "left the Steam lobby"); a `HELLO` and a session request from a friend that has a slot are accepted though
  the lobby does not list it;
- `JoinLobby(the same lobby)` every 2 s while Steam is online (the friends keep the lobby alive);
- **back** only on Steam's answer to such a call (LobbyEnter, success; by callback or by call result): never on the
  host's own member list. Then `back <n>` goes up and the note says `Reconnected.`;
- Steam's answer "the lobby does not exist" (every friend left): `host_lost_lobby` at once; the window over without
  an answer: `host_lost_lobby` (the outcome of 0.3: peers dropped, `lost`, the notice, a new lobby at the next INVITE);
- `INVITE` inside the window waits: no invite window for a lobby the host is not in, and no second lobby beside it.

**Ownership.** Steam gives the lobby to another member when the host is out. The host is named in the lobby's data
(`mlcoop_host=<steamid>`, set at creation), so a player that joins meanwhile does not take that member for the host.
Back in the lobby, the host is a member and a friend's copy is the owner: that copy hands the ownership back
(`SetLobbyOwner`, once a second until Steam shows the host as owner). Until then the host works as a member
(`memberOnly`: it may invite; only the slot list in the lobby's data waits, since `SetLobbyData` is the owner's). Why
this way: the session's survival rests on `JoinLobby` alone; the hand-back is an extra that may fail without harm
(the export is optional, and whether Steam honours it was never seen).

**Friend.** When the host is not in the member list (and there was no `BYE`): status `hostlost 30`, state stays
`joined`; it stays in the lobby, keeps the host's Steam id trusted (messages and session requests go by Steam id, not
by lobby), and goes on saying hello if the link breaks. The host a member again: `back <n>` goes up. 30 s without the
host: it leaves as before (`the host left the game`). A `BYE` for this lobby still ends the game at once. A friend
that is itself out of the lobby leaves at once, as before (its own way back is not built).

**The mod** (`coop_session.lua`, `coop_ui.lua`): the friend's game is held (paused, pause line "Host connection lost")
while nothing comes from the host, and asks for one repair after a gap of more than 2 s; neither side's 30 s silence
rule runs inside the window, and both start afresh after it.

Not known until two PCs repeat the VPN test: whether Steam lets a host back into an invite-only lobby by its id;
whether `SetLobbyOwner` works as its header says; what the host's Steam answers about its lobby right after its own
drop (the mock has a switch for "as before the drop"); whether a P2P session that failed with the drop opens again
by itself; how long Steam keeps a message for a closed session.

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
| `BYE <lobby id>` | both | leaving now. Since 0.3 it names its lobby: a goodbye for another lobby is ignored (it was sent before this game and waited in Steam; found in the mock: a friend that joined the host's new lobby was sent home by the goodbye for the old one). `BYE` without a number (an older DLL) counts as before. |

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

- **`/exports`:** one export, `coop_steam_tick` (since 0.5 also `coop_steam_flush`).
- **`/dependents`:** `KERNEL32.dll` and `bcrypt.dll` only. Both are Windows system DLLs, and there is no CRT DLL
  (`/MT`).

## Test results (mock Steam, 2026-11-10)

`build.cmd test` reported **69 passed, 0 failed**, and the temporary folder `%TEMP%\coop_steam_test_<pid>` was removed.
(2026-11-13, lane 33: **97 passed, 0 failed**; 77 before its change. The 20 new checks: coat pictures sent, received,
a missing one, eight bad names refused, the name pattern; link file turnover: names, the `~NEXT` line, three turnovers
with two in a row, the old files kept and then cleaned, a friend that loads alone while the file turns over twice and
reads again from its MARK, a mirror file locked across two turnovers, the host's game starting again, the friend's
own file turning over. Details: `research/2026-11-10-game-probe/lanes/lane_s21_33/report.txt`.)

(2026-11-17, lane 62, DLL 0.3: **140 passed, 0 failed**; 97 before its change. 6 of the 43 new checks, section "an old goodbye must not end the next game" (two PCs of their own; with the rule taken out, 1 FAIL: the friend does not stay in the new lobby). The other 37, section "the host
loses its own lobby": INVITE on a friend's copy opens nothing; (a) the host's own id in a chat update, change 0x4: state
`idle` at once, every peer dropped, the notice text, `lost 1 2`, nobody called "left the Steam lobby", both friends
leave, nothing opens by itself; (b) INVITE after it, twice: one new lobby, the dialog once and for the NEW id, a third
INVITE opens it for the same lobby, a friend accepts and lines flow both ways; the polled check: 1.2 s of a wrong owner
ends nothing; (c) the owner changed away with no update: `hosting` after 2 s, given up after 3 s, the host left the old
lobby, `lost 2 0`; a 2.5 s Steam break with the lobby whole: nothing lost; (d) Steam offline, the lobby lost without a
word, INVITE while offline: the note, no dialog, no lobby, not given up in 5.5 s; Steam back: within 1.5 s a new lobby
and the dialog for its id, `lost 3 1`. The fake Steam got: `BLoggedOn` per PC, the lobby id of the last invite dialog,
and a member taken out by Steam itself with the update also sent to that member. Three deliberate mutations, each run
once: Steam's own-id word ignored gave 13 FAILs in (a) and (b), then the test program stopped; the check after Steam
came back removed gave 5 FAILs; the polled check never acting gave 11 FAILs in (c) and (d).)

(2026-11-17, lane 62 part two, DLL 0.4: **168 passed, 0 failed**; 140 before. The section "the host loses its own
place in its lobby" was written again for the window, 65 checks: (1) a 5 s drop with two friends, messages cut, Steam
offline on the host, the ownership moved to friend1: both friends stay `joined` with `hostlost 30`; the host, told by
Steam, shows `reconnecting 30`, keeps its peers, tries again after a refused JoinLobby, then `Reconnected.` and
`back 1`; no `lost`, no new lobby, no invite window; friend1 hands the ownership back; lines flow both ways again.
(2) the owner changed away with no word (case (c) of 0.3): nothing for 2 s, then the window, a confirmed JoinLobby,
the host works as a member (a friend's copy without SetLobbyOwner) and may invite; with SetLobbyOwner back it owns the
lobby again; nothing is lost. So (c) no longer ends the lobby. (3) 1.2 s of "not a member" starts nothing. (4) the
outcome of 0.3 at the window's end: own id 0x4, the host's Steam answering member and owner questions as before the
drop, every JoinLobby refused: no `Reconnected.` on its own member list, INVITE pressed twice opens nothing for 28.5 s,
at 30 s `THIS HOST LOST ITS OWN PLACE`, the notice word for word, `lost 1 2`, one new lobby, the invite window for the
new id, both friends leave, a friend accepts the new invite and lines flow. (5) a 2.5 s Steam break with the lobby
whole starts no window. (6) Steam offline for 35 s with the lobby lost silently and INVITE pressed while offline: the
note, no window, the friend leaves at 30 s (`the host left the game`), the host decides nothing while offline; back
online its JoinLobby is answered "does not exist": given up at once, a new lobby and the invite window for it within
1.5 s, `lost 2 1`. (7) a host back after 32 s with no INVITE waiting: `idle`, `lost 3 1`, the notice in the status,
nothing opens by itself. (8) a goodbye inside the window: the friend leaves at once. (9) a player that joins while
friend1 holds the ownership takes the named host (`mlcoop_host`), waits, and gets slot 2 when the host is back. The
fake Steam got: SetLobbyOwner, a JoinLobby answer per PC, member and owner answers frozen per PC, the own-id update
sent later. Two mutations, each run once: the host taking its own member list for "back" gave 12 FAILs in (4) and
(5), then the test program stopped; the friend leaving half a second after the host is out gave 35 FAILs.)

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
| A host that Steam took out of its invite-only lobby gets back in with `JoinLobby(<the same id>)` while a friend is still in it (0.4) | [U] never tried | the VPN test on two PCs: log `THIS HOST IS BACK IN LOBBY ...`, or `Steam did not let this host back into its lobby (<why>)` |
| `SetLobbyOwner(lobby, newOwner)` flat shape (two 64-bit ids, returns bool) and that Steam honours it for a member (0.4) | [U] the export is in the game's list; never called | the friend's log `handing it back to the host ... (SetLobbyOwner said 1 ...)`, then the host's `this host is the owner of lobby ... again` |
| Steam keeps a message sent to a player whose session is closed until that player talks to the sender again (the old goodbye, 0.3) | [U] the mock does | the friend's log `a goodbye from ... for another lobby ... was ignored` |
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
