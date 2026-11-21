-- Desk test of the Lua side of lane 62 (2026-11-17, mod 0.2.3). Runs WITHOUT the game:
--     lua mod/ManorLordsCoop/tests/lane62/t_lane62.lua <an empty folder to use>
-- (Lua 5.4, or LuaJIT / Lua 5.1: the few 5.4 library forms the mod uses are stood in for below.) It loads the real
-- coop.lua, coop_steam.lua, coop_session.lua and coop_ui.lua with stand-ins for the game's and the mod loader's
-- functions, points the link folder at the folder given, and drives:
--   A  every counted error leaves a log line (Coop.countErr through the driver's own counting places)
--   B  C.setRole clears what the last co-op game left in the join module; C.friendsLost
--   C  the Steam status line "lost <n> <friends>", and leavePending after a LEAVE of the mod's own
--   D  a host that lost its Steam lobby: told once per loss (coop_ui), friends marked as gone, no second notice
--   E  a friend's host-gone exit: the menu button's words come back after the set time, at once when the panel is
--      opened, and a new co-op game ends what the last one left (the way out under way, the silence rule's memory)
--   F  the stale "joined" right after the mod's own LEAVE does not make this copy a friend again; a real one does
--   G  the bug report's job lists the Steam piece's log and status first, as "steamlog" / "steamstatus"
--   H  part two, a short drop does not end the session: the status lines of the window; the host is told when the
--      window starts and when it worked, and no friend is told as gone meanwhile; a friend is told once, its game is
--      held (paused, marked as the mod's own pause) only while the host's lines are missing, the silence rule stands
--      still inside the window and starts afresh after it, one repair after a gap of more than 2 s; the pause line's words
-- It never touches the game, a save, or the mod's real link folder. What it cannot show: anything on screen (the
-- menu, the banner), the game's objects, real Steam. Those need a game run.
-- Do not run it in the game's console: C.start would restart the running mod.

local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane62/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_lane62.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end

-- ---- Lua 5.1 / LuaJIT: the 5.4 forms the mod uses
if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout)
  local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
end

local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function spit(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function wait(s) local t = os.clock(); while os.clock() - t < s do end end
local function count(text, needle) local n, i = 0, 1; while true do local a, b = text:find(needle, i, true); if not a then break end; n = n + 1; i = b + 1 end; return n end

-- ---- stand-ins for the game and the mod loader
local world = false                                   -- is a world loaded
local level = "MainMenu"
local opened = {}                                     -- levels asked for with OpenLevel
local function obj(t) t = t or {}; t.IsValid = t.IsValid or function() return true end; return t end
local function str(s) return { ToString = function() return s end } end
local engine = obj({ playerRef = nil })
local GS = obj({
  OpenLevel = function(self, gi, name) opened[#opened + 1] = tostring(name) end,
  GetCurrentLevelName = function() return str(level) end,
  IsGamePaused = function() return false end, SetGamePaused = function() end, SetGlobalTimeDilation = function() end,
  GetPlayerController = function() return nil end,
})
local KTL = obj({ Conv_StringToText = function(self, s) return s end })
_G.StaticFindObject = function(path)
  if path:find("GameplayStatics", 1, true) then return GS end
  if path:find("KismetTextLibrary", 1, true) then return KTL end
  return obj({})
end
_G.FindFirstOf = function(cls)
  if cls == "RTSMultiEngineCPP" then return world and engine or obj({ IsValid = function() return false end }) end
  if cls == "MLGameInstance" then return obj({ savefileToLoad = str(""), GetDisplayAppVersion = function() return str("0.8.117") end }) end
  return obj({ IsValid = function() return false end })
end
local allOf = {}                                      -- what FindAllOf answers, by class name
_G.FindAllOf = function(cls) return allOf[cls] or {} end
_G.FName = function(s) return s end
_G.RegisterHook = function() return 1, 2 end
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.COOP_LINK_DIR = dir
_G.Coop = nil

-- coop_steam.lua looks for coop_steam.dll beside itself and reads / writes coop_steam.cfg there: both are stood in
-- for (nothing is written into the Scripts folder), and the "DLL" is a function that does nothing
local open0 = io.open
io.open = function(path, mode)
  local p = tostring(path):gsub("\\", "/")
  if p:match("/coop_steam%.dll$") then return open0(here(), "rb") end
  if p:match("/coop_steam%.cfg$") then return open0(dir .. "coop_steam.cfg", mode) end
  return open0(path, mode)
end
package.loadlib = function() return function() end end
spit(dir .. "coop_steam.cfg", "linkdir=" .. dir:gsub("/", "\\"):gsub("\\$", "") .. "\r\n")

dofile(scripts .. "coop.lua")
local C = _G.Coop
-- (lane 64, 2026-11-19) the version is no longer written out here (the test failed from 0.2.4 on for that alone)
check(C and type(C.version) == "string" and C.version:match("^%d+%.%d+%.%d+$") ~= nil and type(C.countErr) == "function", "coop.lua loads outside the game; it has a version (" .. tostring(C and C.version) .. ")")
C.start("idle", "idle", {})
local S = C.s
for _, f in ipairs({ "coop_steam.lua", "coop_session.lua", "coop_ui.lua" }) do
  local r = dofile(scripts .. f)
  check(type(r) == "string" and r:find("loaded", 1, true) ~= nil, f .. " loads: " .. tostring(r))
end
local ST, P, U = C.steam, C.session, C.ui
check(ST.on and ST.link:lower() == dir:lower(), "the Steam module is on, its link folder is the test folder")
local function status(text) spit(dir .. "steam_status.txt", text); ST.readT = nil end
status("idle 76561190000000001\ninfo appid 1363080 overlay 1 relay ok loggedon 1 build 1 proto 1 dll 0.3\n")
local function logOf(name) return slurp(dir .. name .. "_log.txt") or "" end
local function ticks(n) for _ = 1, n do C.tick() end end

-- ---------------------------------------------------------------- A: every counted error leaves a line
do
  local boom = { n = 0 }
  C.register("boom", { idle = function() boom.n = boom.n + 1; error("idle went wrong") end })
  ticks(12)
  local lg = logOf("idle")
  check(S.nerr == 12 and boom.n == 12, "12 failing idle steps are counted (" .. tostring(S.nerr) .. ")")
  check(count(lg, " in boom.idle (role idle): ") == 5 and lg:find("error 1 in boom.idle", 1, true) and lg:find("error 5 in boom.idle", 1, true) and not lg:find("error 6 in boom.idle", 1, true),
        "the first five get a line each (the same text again after that does not)")
  C.errFlush(true)
  lg = logOf("idle")
  check(lg:find("errors: 7 more since the last such line", 1, true) ~= nil and lg:find("(12 this run)", 1, true) ~= nil, "the other seven are told in one line: every counted error is in the log")
  C.modules.boom = nil
  C.register("msg", { onMessage = function(S2, from, kind) if kind == "ZZ" then error("message went wrong") end; return false end })
  C.dispatch("host", { "1", "1.0", "ZZ" }, "1 1.0 ZZ")
  lg = logOf("idle")
  check(S.nerr == 13 and lg:find("error 13 in msg.onMessage (a ZZ line from host) (role idle): ", 1, true) ~= nil, "a failing message handler (counted without a line before): a line, though five were written already")
  C.modules.msg = nil
  local ff = _G.FindFirstOf
  _G.FindFirstOf = function(cls) if cls == "RTSMultiEngineCPP" then error("the tick itself went wrong") end; return ff(cls) end
  ticks(1)
  _G.FindFirstOf = ff
  lg = logOf("idle")
  check(S.nerr == 14 and lg:find("error 14 in the tick (role idle): ", 1, true) ~= nil and S.lastErr:find("the tick: ", 1, true) == 1, "an error of the tick itself: a line, and the last error is kept for the report")
  -- a role change inside a tick ends that tick's module loop (the modules after it ran without their world before)
  local src = slurp(scripts .. "coop.lua")
  check(src:find("if S.roleN ~= roleN0 then break end", 1, true) ~= nil, "the driver's module loop stops after a role change inside the tick (source check: the loop needs a world to run)")
  check(not src:find("S.nerr = S.nerr + 1", 1, true) and not src:find("C.s.nerr = C.s.nerr + 1", 1, true), "no place in coop.lua counts an error by itself any more (all go through countErr)")
end

-- ---------------------------------------------------------------- B: C.setRole and C.friendsLost
do
  C.join = C.join or {}
  local J = C.join
  J.repairLater = "families"; J.repairT = os.clock(); J.lastLoaded = "coop_join_2"; J.single = { id = "x" }
  local n0 = S.roleN or 0
  C.setRole("friend", "friend1", {})
  check(S.roleN == n0 + 1 and J.repairLater == nil and J.repairT == nil and J.lastLoaded == nil and J.single == nil,
        "a new friend role: the repair asked for in the last game, and the save loaded for the last join, are forgotten")
  J.lastLoaded = "coop_join_1"
  C.setRole("host", "host", { "friend1", "friend2", "friend3" })
  check(J.lastLoaded == "coop_join_1", "(a host keeps the name of the save it loaded)")
  S.heard = { friend1 = os.clock(), friend2 = os.clock() }
  J.away = { friend2 = { t = os.clock(), name = "coop_join_1" } }; J.q = { friend1 = {} }; J.state = "saving1"; J.one = { targets = {} }
  local n = C.friendsLost("this host lost its Steam lobby")
  check(n == 2 and S.gone.friend1 and S.gone.friend2 and not S.gone.friend3 and S.goneWhy.friend1 == "steam", "friendsLost: the two friends heard so far are gone on Steam's word; the empty place is not")
  check(next(J.away) == nil and next(J.q) == nil and J.state == nil and J.one == nil, "friendsLost: no friend is waited for any more (no load alone, no save for one)")
  check(#C.notices == 0 or not tostring(C.notices[#C.notices].text):find("left the game", 1, true), "friendsLost: no 'left the game' notice per friend")
  check(C.friendsLost("again") == 0, "friendsLost a second time marks nobody again")
  C.setRole("idle", "idle", {})
end

-- ---------------------------------------------------------------- C: the Steam status and leavePending
do
  status("hosting 76561190000000001 109775240000000007\ninfo appid 1363080 overlay 1 relay ok loggedon 1 build 1 proto 1 dll 0.3\nnote Your Steam connection dropped.\nlost 2 1\n0 76561190000000001 connected 0 Host Player\n1 76561190000000002 connected 30 Friend One\n")
  local s = ST.status()
  check(s.state == "hosting" and s.lost == 2 and s.lostFriends == 1 and #s.players == 2 and s.note == "Your Steam connection dropped." and s.info.dll == "0.3",
        "status: 'lost 2 1' is read (times, friends then); the lines around it as before")
  status("joined 76561190000000002 109775240000000007 slot 1\n0 76561190000000001 connected 20 Host Player\n1 76561190000000002 connected 20 Friend One\n")
  check(ST.status().lost == nil and ST.leavePending() == false, "status without a 'lost' line: nil; no LEAVE sent: not pending")
  ST.tick()                                                  -- (commands are held until the DLL's first tick)
  ST.leave()
  check(ST.leavePending() == true and (slurp(dir .. "steam_cmd.txt") or ""):find("LEAVE", 1, true) ~= nil, "after the mod's own LEAVE, while the status still says 'joined': pending")
  status("idle 76561190000000002\nnote left the game\n")
  check(ST.leavePending() == false and ST.leaveT == nil, "the status shows 'idle' once: no longer pending")
  status("joined 76561190000000002 109775240000000009 slot 1\n")
  check(ST.leavePending() == false, "a 'joined' after that is a new game (an invite accepted): not pending")
  ST.leave(); ST.leaveT = os.clock() - 6
  check(ST.leavePending() == false, "5 s after a LEAVE that the status never showed: not pending either (no copy is locked out)")
  status("idle 76561190000000001\n")
end

-- ---------------------------------------------------------------- D: the host's lobby is lost
do
  local M = C.modules.ui
  C.setRole("host", "host", { "friend1", "friend2" })
  S.heard = { friend1 = os.clock() }
  status("hosting 76561190000000001 109775240000000007\n0 76561190000000001 connected 0 Host Player\n1 76561190000000002 connected 30 Friend One\n")
  M.idle(S, os.clock())
  local n0 = #C.notices
  status("idle 76561190000000001\nnote Your Steam connection dropped. Your friends were sent to the main menu. Press Invite Friends to bring them back.\nlost 1 1\n")
  M.idle(S, os.clock())
  local last = C.notices[#C.notices]
  check(#C.notices == n0 + 1 and last.kind == "left" and last.text == "Your Steam connection dropped. Your friends were sent to the main menu. Press Invite Friends to bring them back.",
        "host, 'lost 1 1': the player is told once, in these words")
  check(S.gone.friend1 == true and S.goneWhy.friend1 == "steam" and S.role == "host", "the friend is marked as gone on Steam's word; this copy stays the host")
  for _ = 1, 5 do ST.readT = nil; M.idle(S, os.clock()) end
  check(#C.notices == n0 + 1, "the same 'lost 1 1' read again and again: no second notice")
  status("hosting 76561190000000001 109775240000000008\nlost 1 1\n0 76561190000000001 connected 0 Host Player\n")
  M.idle(S, os.clock())
  check(#C.notices == n0 + 1, "a new lobby, the counter still 1: no notice")
  status("idle 76561190000000001\nlost 2 0\n")
  M.idle(S, os.clock())
  last = C.notices[#C.notices]
  check(#C.notices == n0 + 2 and last.text == "Your Steam connection dropped. Press Invite Friends to open a new lobby.", "'lost 2 0': told again, in the words for a host without friends")
  C.setRole("idle", "idle", {})
  status("idle 76561190000000001\nlost 2 0\n")
  M.idle(S, os.clock())
  check(#C.notices == n0 + 2, "a copy that is not a host is never told")
end

-- ---------------------------------------------------------------- E: a friend's host-gone exit, the button, the next game
local btn = obj({ text = "Co-op", GetAddress = function() return 4242 end, GetParent = function() return nil end })
btn.SetButtonText = function(self, t) self.text = tostring(t) end
do
  local M = C.modules.session
  P.cfg.exitAfter = 0.05; P.cfg.labelFor = 0.3
  status("joined 76561190000000002 109775240000000007 slot 1\n")
  C.setRole("friend", "friend1", {})
  U.viaSteam = true
  S.stats.states = 5
  status("idle 76561190000000002\nnote the host left the game\n")
  P.gone(S, "steam", "idle the host left the game")
  check(S.role == "idle" and P.leaving and P.leaving.why == "steam" and P.lastEndText() == "Last co-op game: the host left the game", "host gone: this copy is idle and leaving; the panel's line is ready")
  wait(0.06); M.idle(S, os.clock())
  check(#opened == 1 and opened[1] == "MainMenu", "after the set time the title level is asked for (the engine's OpenLevel)")
  U.btn = btn
  M.idle(S, os.clock()); M.idle(S, os.clock())
  check(btn.text == "Co-op: the host left the game" and P.label ~= nil, "at the title screen the menu button says 'Co-op: the host left the game'")
  wait(0.35); M.idle(S, os.clock())
  check(btn.text == "Co-op" and P.label == nil, "after the set time (20 s in the game, 0.3 s here) the button says 'Co-op' again")
  M.idle(S, os.clock())
  check(btn.text == "Co-op", "and the words do not come back on the same button")
  check(P.lastEndText() == "Last co-op game: the host left the game", "the panel's line stays until a new co-op game starts")

  -- again, and this time the player opens the panel: at once
  P.leaving = nil; P.lastEnd = nil
  C.setRole("friend", "friend1", {}); S.stats.states = 5
  P.gone(S, "silent", "nothing from the host for 31 s")
  wait(0.06); M.idle(S, os.clock())
  btn = obj({ text = "Co-op", GetAddress = function() return 4343 end, GetParent = function() return nil end }); btn.SetButtonText = function(self, t) self.text = tostring(t) end
  U.btn = btn
  M.idle(S, os.clock()); M.idle(S, os.clock())
  check(btn.text == "Co-op: the host left the game" and P.lastEndText() == "Last co-op game: the host stopped answering", "a silent host: the button says the host left; the panel's line says it stopped answering")
  P.labelBack("the player opened the Co-op panel")
  M.idle(S, os.clock())
  check(btn.text == "Co-op" and P.label == nil and P.leaving ~= nil and P.leaving.labelOff == true, "the panel was opened: the button says 'Co-op' at once and keeps it while the way out goes on")

  -- a new co-op game while the way out of the last one is still under way: C.setRole alone (the Steam link's word,
  -- the menu, or the development console on a test copy without Steam) ends what the last game left
  P.overT = os.clock() - 5; P.loadT = os.clock()
  C.setRole("friend", "friend1", {})
  check(P.leaving == nil and P.left and P.left.why == "silent" and P.lastEnd == nil and P.lastEndText() == nil and P.overT == nil and P.loadT == nil,
        "a new friend role (C.setRole): the way out ends, the panel's line goes, the silence rule starts afresh")
  local n = #opened
  wait(0.06); M.idle(S, os.clock())
  check(#opened == n, "no title level is asked for after that (it was, in the middle of the new join)")
  S.stats.states = 3
  P.gone(S, "bye", "menu")
  check(P.leaving ~= nil and P.leaving.why == "bye", "and the new host's goodbye is acted on (it did nothing while the old way out was kept)")
  P.newGame("test end"); P.label = nil
end

-- ---------------------------------------------------------------- F: the stale "joined" after the mod's own LEAVE
do
  local M = C.modules.ui
  C.setRole("idle", "idle", {})
  U.viaSteam = nil; U.hostNext = true
  status("joined 76561190000000002 109775240000000007 slot 1\n")
  ST.leave()                                                 -- (as P.gone and the Leave button do), the status still says "joined"
  M.idle(S, os.clock())
  check(S.role == "idle" and not U.viaSteam, "right after the mod's own LEAVE the old 'joined' status does not make this copy a friend again")
  status("idle 76561190000000002\nnote left the game\n")
  M.idle(S, os.clock())
  check(S.role == "idle", "idle while the Steam piece is idle")
  P.lastEnd = { t = os.clock(), why = "bye" }
  status("joined 76561190000000002 109775240000000011 slot 2\n")
  M.idle(S, os.clock())
  check(S.role == "friend" and S.name == "friend2" and U.viaSteam == true, "a new invite accepted (joined, slot 2): this copy is friend2")
  check(P.lastEnd == nil and U.hostNext == nil and C.hold == true, "the new game starts clean: no 'last game' line, no 'host the next game' left over, waiting for the host's save")
  -- a bounced join (second live session): one second after the join the status reads "idle" with no reason
  status("idle 76561190000000002\n")
  M.idle(S, os.clock()); wait(2.2); ST.readT = nil; M.idle(S, os.clock())
  check(S.role == "friend" and U.viaSteam == true and P.leaving == nil, "a bare 'idle' status right after the join (2.2 s of it): not taken for the host leaving")
  status("joined 76561190000000002 109775240000000011 slot 2\n")
  M.idle(S, os.clock())
  status("idle 76561190000000002\nnote the host left the game\n")
  S.stats.states = 4
  M.idle(S, os.clock())
  check(S.role == "friend" and P.leaving == nil, "'idle' with a reason, read once: not yet")
  wait(2.1); ST.readT = nil; M.idle(S, os.clock())
  check(S.role == "idle" and P.leaving ~= nil and P.leaving.why == "steam", "'idle' with a reason for 2 s: the host is gone, the game ends as before")
  P.newGame("test end"); P.label = nil
  C.setRole("idle", "idle", {}); U.viaSteam = nil
  status("idle 76561190000000002\n")
end

-- ---------------------------------------------------------------- G: the bug report's job
do
  spit(dir .. "coop_steam.log", "2026-11-17 20:01:05.300 Friend One (76561190000000002) connected as friend1\n")
  local sent
  C.patch = { fn = function() end, dir = dir, statusPath = dir .. "patch_status.txt", send = function(l) sent = l; return true end, tick = function() end,
              status = function() return { state = "on", text = "ready 0 0\r\nprocess 4242 version 0.9.2\r\n", items = {} } end }
  spit(dir .. "patch_status.txt", "on\r\n")
  -- which process this is: the native piece's status names it; the session step takes it once
  C.sess.stepT = nil; C.sess.pidT = nil
  C.sessionStep(S)
  check(C.sess.pid == 4242 and (logOf("idle")):find("session: process 4242, run " .. tostring(C.runT), 1, true) ~= nil, "the process id comes from the native piece's status and is written to the log once ('session: process 4242, run ...')")
  local r = C.report({ open = false })
  local job = slurp(dir .. "patch_report_job.txt") or ""
  check(tostring(r):find("^making the bug report") ~= nil and tostring(sent):find("^REPORT ") ~= nil, "Coop.report with the native piece: the job is written and REPORT sent (" .. tostring(r) .. ")")
  local first = job:match("\n(%a+) [^\n]*\treport_info%.txt\t") and job:match("report_info%.txt\t[^\n]*\n(%a+) ")
  local d = dir:gsub("/", "\\")
  check(job:find("steamlog " .. d .. "coop_steam.log\tcoop_steam.log\t2097152\t0\n", 1, true) ~= nil and job:find("steamstatus " .. d .. "steam_status.txt\tsteam_status.txt\t0\t0\n", 1, true) ~= nil,
        "the job has the Steam piece's log as 'steamlog' and its status as 'steamstatus' (names out by line shape in the native piece)")
  check(first == "steamlog", "they are listed first, right after report_info.txt (the first after it is '" .. tostring(first) .. "')")
  check(not job:find("steamlog " .. d .. "coop_steam.log.old", 1, true), "a file that is not there (coop_steam.log.old) is not listed")
  local info = slurp(dir .. "patch_report_info.txt") or ""
  check(info:find("Mod version:       " .. C.version, 1, true) ~= nil and info:find("Steam piece files: 2 file(s), Steam names taken out by the shape of the line", 1, true) ~= nil and
        info:find("14 tick error(s) this run; the last: the tick: ", 1, true) ~= nil and info:find("  coop_steam.log  ", 1, true) ~= nil,
        "report_info.txt: the mod's version, the Steam files, the error count with the last error")
  check((logOf("idle")):find("errors: ", 1, true) ~= nil, "the log has its error lines before the report copies it")
  check(info:find("This process:      pid 4242, run " .. tostring(C.runT), 1, true) ~= nil and info:find("current_idle_log.txt  this run's log as idle; written by process 4242, run " .. tostring(C.runT), 1, true) ~= nil,
        "report_info.txt says which process this is and which process and run wrote each log")
  check(info:find("UE4SS.log", 1, true) == nil or info:find("the log of the copy started LAST", 1, true) ~= nil, "(the loader's log, when there is one, is marked as the last started copy's)")
  -- without the native piece the Steam files are left out (the list of known names is not enough for them)
  C.sess.rep = nil
  C.patch = nil
  r = C.report({ open = false })
  local found
  for _, base in ipairs({ dir .. "reports/", dir }) do
    local stamp = tostring(r):match("report_([%d_%-]+)_%*")
    local t = stamp and slurp(base .. "report_" .. stamp .. "_report_info.txt")
    if t then found = t end
    check(not stamp or slurp(base .. "report_" .. stamp .. "_coop_steam.log") == nil, "no native piece: no copy of coop_steam.log in " .. (base == dir and "the link folder" or "link/reports"))
  end
  check(found ~= nil and found:find("Steam piece files: left out", 1, true) ~= nil, "no native piece: report_info.txt says the Steam files are left out (" .. tostring(r) .. ")")
end

-- ---------------------------------------------------------------- H: part two, a short drop does not end the session
do
  local UI, SE = C.modules.ui, C.modules.session
  C.patch = nil; C.sess.rep = nil
  -- the status lines of the window
  status("hosting 76561190000000001 109775240000000007\nreconnecting 30\nback 2\n0 76561190000000001 connected 0 Host Player\n")
  local s = ST.status()
  check(s.state == "hosting" and s.reconnecting == 30 and s.back == 2 and s.hostLost == nil and #s.players == 1, "status: 'reconnecting 30' and 'back 2' are read")
  status("joined 76561190000000002 109775240000000007 slot 1\nhostlost 30\n0 76561190000000001 connected 20 Host Player\n")
  s = ST.status()
  check(s.state == "joined" and s.slot == 1 and s.hostLost == 30 and s.reconnecting == nil, "status: 'hostlost 30' is read; the state stays 'joined'")

  -- HOST: told when the window starts and when it worked; no friend is told as gone meanwhile
  C.setRole("host", "host", { "friend1", "friend2" })
  status("hosting 76561190000000001 109775240000000007\nlost 2 0\nback 2\n0 76561190000000001 connected 0 Host Player\n1 76561190000000002 connected 30 Friend One\n")
  UI.idle(S, os.clock())
  S.heard = { friend1 = os.clock() - 25, friend2 = os.clock() - 100 }; S.gone = { friend2 = true }
  local n0 = #C.notices
  status("hosting 76561190000000001 109775240000000007\nnote Your Steam connection dropped. Trying to reconnect (30 s)...\nlost 2 0\nreconnecting 30\nback 2\n0 76561190000000001 connected 0 Host Player\n1 76561190000000002 connected 30 Friend One\n")
  UI.idle(S, os.clock())
  check(#C.notices == n0 + 1 and C.notices[#C.notices].text == "Your Steam connection dropped. Trying to reconnect (30 s)..." and S.linkWait == true,
        "host, 'reconnecting 30': told once, in these words; the 'left the game' rule stands still (S.linkWait)")
  for _ = 1, 4 do ST.readT = nil; UI.idle(S, os.clock()) end
  check(#C.notices == n0 + 1, "the window read again and again: no second notice")
  local src = slurp(scripts .. "coop.lua")
  check(src:find("if h and not C.hold and not (C.join and C.join.state) and not S.linkWait then", 1, true) ~= nil, "the host's 'left the game' rule is skipped while S.linkWait is set (source check: the rule needs a world to run)")
  status("hosting 76561190000000001 109775240000000007\nnote Reconnected.\nlost 2 0\nback 3\n0 76561190000000001 connected 0 Host Player\n1 76561190000000002 connected 30 Friend One\n")
  UI.idle(S, os.clock())
  check(#C.notices == n0 + 2 and C.notices[#C.notices].text == "Reconnected." and S.linkWait == nil, "host, the window over and 'back' one higher: 'Reconnected.'; the rule runs again")
  check(os.clock() - S.heard.friend1 < 1.0 and os.clock() - S.heard.friend2 > 50, "the friend's silence clock starts afresh (30 s from now); a friend that had left before is not touched")
  -- the window ends without the host getting back: no 'Reconnected.', the part-one notice
  status("hosting 76561190000000001 109775240000000007\nlost 2 0\nreconnecting 30\nback 3\n0 76561190000000001 connected 0 Host Player\n1 76561190000000002 connected 30 Friend One\n")
  UI.idle(S, os.clock())
  status("idle 76561190000000001\nnote Your Steam connection dropped. Your friends were sent to the main menu. Press Invite Friends to bring them back.\nlost 3 1\nback 3\n")
  UI.idle(S, os.clock())
  local t1, t2 = C.notices[#C.notices - 1].text, C.notices[#C.notices].text
  check(#C.notices == n0 + 4 and t1 == "Your Steam connection dropped. Trying to reconnect (30 s)..." and t2 == "Your Steam connection dropped. Your friends were sent to the main menu. Press Invite Friends to bring them back." and S.linkWait == nil,
        "host, the window ends with the lobby lost: no 'Reconnected.', the notice of part one; the rule runs again")
  check(S.gone.friend1 == true, "the friend is marked as gone with the lobby")

  -- FRIEND: a world to pause (stand-ins: the lord's pause flag and the engine's speed, as the core's isPaused reads them)
  local eng = obj({ gameSpeed = 1.0 })
  local p1 = obj({ bIsPlayerPaused = false })
  p1.pauseGame = function(self) self.bIsPlayerPaused = true; eng.gameSpeed = 0.0 end
  p1.unPauseGame = function(self) self.bIsPlayerPaused = false; eng.gameSpeed = 1.0 end
  local repairs = {}
  C.join.requestRepair = function(why) repairs[#repairs + 1] = why end
  local function friendWorld()
    C.setRole("friend", "friend1", {}); C.hold = false
    S.p1 = p1; S.eng = eng; S.stats.states = 10; S.heard = { host = os.clock() }
    p1.bIsPlayerPaused = false; eng.gameSpeed = 1.0
  end
  local function paused() return p1.bIsPlayerPaused and eng.gameSpeed <= 0.001 end
  status("joined 76561190000000002 109775240000000007 slot 1\n0 76561190000000001 connected 20 Host Player\n")
  friendWorld()
  SE.tick(S, os.clock())
  check(P.link == nil and not S.linkHold and not paused(), "friend, no window: nothing held")
  -- only the lobby membership dropped; the host's lines still flow
  n0 = #C.notices
  status("joined 76561190000000002 109775240000000007 slot 1\nhostlost 30\n0 76561190000000001 connected 20 Host Player\n")
  SE.tick(S, os.clock())
  check(P.link ~= nil and #C.notices == n0 + 1 and C.notices[#C.notices].text == "Connection to the host lost. Waiting up to 30 s..." and C.notices[#C.notices].kind == "left",
        "friend, 'hostlost 30': the player is told once, in these words")
  for _ = 1, 3 do S.heard.host = os.clock(); ST.readT = nil; SE.tick(S, os.clock()) end
  check(not S.linkHold and not paused() and #C.notices == n0 + 1 and S.role == "friend", "the host's lines still flow: the game is not held, no second notice, nobody leaves")
  status("joined 76561190000000002 109775240000000007 slot 1\nback 1\n0 76561190000000001 connected 20 Host Player\n")
  S.heard.host = os.clock(); SE.tick(S, os.clock())
  check(P.link == nil and #repairs == 0 and C.notices[#C.notices].text == "Connection to the host is back", "the host is back in the lobby, no line was missed: told so, no repair asked")

  -- the host's lines stop: the game is held
  status("joined 76561190000000002 109775240000000007 slot 1\nhostlost 30\nback 1\n0 76561190000000001 connected 20 Host Player\n")
  P.cfg.silence = 0.5                                       -- (30 s in the game) so the silence rule would fire inside the window
  S.heard.host = os.clock(); S.tIn = os.clock(); SE.tick(S, S.tIn)
  wait(1.6)
  S.tIn = os.clock(); SE.tick(S, S.tIn)
  check(S.linkHold == true and paused(), "nothing from the host for 1.6 s inside the window: the game on this copy is held (paused)")
  check(S.setPaused == true and S.agree == false and (S.speedHold or 0) > os.clock(), "the pause is marked as the mod's own (setPaused, agree, speedHold): the watcher sends nothing to the host")
  p1:unPauseGame()                                          -- the player presses the pause key during the hold
  S.tIn = os.clock(); SE.tick(S, S.tIn)
  check(paused() and S.setPaused == true and S.agree == false and (S.speedHold or 0) > os.clock(), "the player un-pauses during the hold: paused again in the next tick, still marked as the mod's own")
  wait(1.1)
  S.tIn = os.clock(); SE.tick(S, S.tIn)
  check(S.role == "friend" and P.leaving == nil and P.overT == nil, "the silence rule (0.5 s here) does not end the game inside the window: the Steam piece's 30 s decide")
  -- the host is back in the lobby, its lines not yet: still held; the silence rule counts from now
  status("joined 76561190000000002 109775240000000007 slot 1\nback 2\n0 76561190000000001 connected 20 Host Player\n")
  S.tIn = os.clock(); SE.tick(S, S.tIn)
  check(S.linkHold == true and paused() and P.link ~= nil and P.link.backT ~= nil and S.role == "friend" and P.leaving == nil, "the host is back in the lobby but its lines are not: still held, and the silence rule starts afresh (no leave)")
  -- its lines come again
  S.hostHold = true; S.hostPaused = false
  S.heard.host = os.clock(); S.tIn = os.clock(); SE.tick(S, S.tIn)
  check(S.linkHold == nil and S.speedHold == 0 and P.link == nil, "the host's lines come again: the hold ends (the host's next state line sets pause and speed)")
  check(#repairs == 1 and tostring(repairs[1]):find("^linklost%d+$") ~= nil, "a gap of more than 2 s: one repair is asked for (the join module's single load)")
  check(S.hostHold == false, "the host runs: a 'screen is open' hold whose end may have been lost is over")
  check(C.notices[#C.notices].text == "Connection to the host is back", "the player is told the connection is back")
  P.cfg.silence = 30.0

  -- the window ends without the host: the Steam piece leaves, the game ends as before, the hold with it
  status("joined 76561190000000002 109775240000000007 slot 1\nhostlost 30\nback 2\n")
  friendWorld(); S.heard.host = os.clock() - 5
  S.tIn = os.clock(); SE.tick(S, S.tIn)
  check(S.linkHold == true and paused(), "(a new drop: held)")
  status("idle 76561190000000002\nnote the host left the game\nback 2\n")
  -- the session module may tick before the menu module calls P.gone (the modules run in no fixed order): with the
  -- Steam piece no longer "joined" that is not "the host is back", though the host's lines may still flow
  n0 = #C.notices; local rep0 = #repairs
  S.heard.host = os.clock(); S.tIn = os.clock(); SE.tick(S, S.tIn)
  check(P.link == nil and S.linkHold == nil and #C.notices == n0 and #repairs == rep0 and S.role == "friend",
        "the Steam piece left (state idle) and the session module ticks first: no 'Connection to the host is back', no repair asked; the wait just ends")
  check((logOf("friend1")):find("the wait is over, the game ends", 1, true) ~= nil and paused(), "the log says the wait is over; the game stays paused until the way out lifts it")
  -- (game run s2/E6) the silence rule, held back through the window, must not jump in before the menu module ends the
  -- game on the Steam piece's word: here the host was last heard 40 s ago and the rule's limit is 0.5 s
  P.cfg.silence = 0.5
  S.heard.host = os.clock() - 40
  S.tIn = os.clock(); SE.tick(S, S.tIn); wait(1.1); S.tIn = os.clock(); SE.tick(S, S.tIn)
  check(S.role == "friend" and P.leaving == nil and P.linkBackT ~= nil, "after the wait ended that way the silence rule does not end the game first (it counts from that moment): the Steam piece's word decides")
  P.cfg.silence = 30.0
  P.gone(S, "steam", "idle the host left the game")
  check(S.role == "idle" and P.leaving ~= nil and P.link == nil and S.linkHold == nil and not paused(), "the window ends without the host: the game ends as before (notice, way out); the hold is released")
  P.newGame("test end")

  -- the pause line's words (coop_ui.lua holdTick)
  local label = obj({ t = "Game Paused", IsVisible = function() return true end })
  label.GetText = function(self) return str(self.t) end
  label.SetText = function(self, t) self.t = tostring(t) end
  allOf.TextBlock = { label }
  friendWorld()
  status("joined 76561190000000002 109775240000000007 slot 1\n")
  S.linkHold = true
  UI.tick(S, os.clock())
  check(label.t == "Host connection lost", "the game's pause line says 'Host connection lost' while a lost link holds the game (it said '" .. label.t .. "')")
  S.linkHold = nil; S.hostHold = true
  UI.tick(S, os.clock())
  check(label.t == "Waiting for the host", "the host's open screen holds the game: the line says 'Waiting for the host'")
  S.hostHold = false
  UI.tick(S, os.clock())
  check(label.t == "Game Paused", "no hold: the game's own words are back")
  C.setRole("idle", "idle", {})
end

C.stop()
print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
