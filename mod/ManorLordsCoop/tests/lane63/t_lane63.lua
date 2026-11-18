-- Desk test of the Lua side of lane 63 (2026-11-17, mod 0.2.3). Runs WITHOUT the game:
--     lua mod/ManorLordsCoop/tests/lane63/t_lane63.lua <an empty folder to use>
-- (Lua 5.4, or LuaJIT / Lua 5.1.) It loads the real coop.lua and coop_join.lua with stand-ins for the game's and the
-- mod loader's functions and a clock of its own (os.clock is replaced), and drives the host's join module with the
-- lines friends send:
--   A  two friends alternating with a difference no load fixes: ONE load alone each at most, then every copy loads
--      (0.2.2: six loads alone); an equal day since the load makes the next ask a new cause (a load alone again)
--   B  the breaker: the same kind still asked for after every copy loaded: one notice, no load for 15 minutes, then
--      one load of every copy, then none for an hour; a friend's J DIFF lands in the host's log
--   C  kind "test" (COOP_TEST_REPAIR) is never held by the breaker
--   D  a new world: the host saves and loads it itself before a friend who said hello loads; a loaded world is not
--      prepared
-- What it cannot show: the game's save and load, anything on screen, the menu's own hooks firing. Those need a game run.
-- Do not run it in the game's console: C.start would restart the running mod.

local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane63/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_lane63.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end

if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout)
  local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
end

local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end

-- ---- the clock: every os.clock() in the mod reads T
local T = 1000.0
os.clock = function() return T end
local function after(s) T = T + s end

-- ---- stand-ins for the game and the mod loader
local function obj(t) t = t or {}; t.IsValid = t.IsValid or function() return true end; return t end
local function str(s) return { ToString = function() return s end } end
local saveName = ""                                   -- the game instance's savefileToLoad
local gi = obj({ GetDisplayAppVersion = function() return str("0.8.117") end })
setmetatable(gi, { __index = function(t, k) if k == "savefileToLoad" then return str(saveName) end end,
                   __newindex = function(t, k, v) if k == "savefileToLoad" then saveName = tostring(v) else rawset(t, k, v) end end })
local opened = {}
local GS = obj({ OpenLevel = function(self, g, name) opened[#opened + 1] = tostring(name) end, GetCurrentLevelName = function() return str("MainMenu") end })
_G.StaticFindObject = function(path)
  if path:find("GameplayStatics", 1, true) then return GS end
  return obj({})
end
_G.FindFirstOf = function(cls)
  if cls == "MLGameInstance" then return gi end
  return obj({ IsValid = function() return false end })
end
_G.FindAllOf = function() return {} end
_G.FName = function(s) return s end
_G.RegisterHook = function() return 1, 2 end
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.COOP_LINK_DIR = dir
_G.Coop = nil

dofile(scripts .. "coop.lua")
local C = _G.Coop
C.start("idle", "idle", {})
local S = C.s
check(type(dofile(scripts .. "coop_join.lua")) == "string", "coop_join.lua loads")
local J, M, A = C.join, C.modules.join, C.api

-- the host's copy: a lord that saves, a pause switch, every line it sends kept here
local sent, saves, paused = {}, {}, false
A.send = function(line) sent[#sent + 1] = line end
A.setPaused = function(v) paused = v and true or false end
A.isPaused = function() return paused end
local valid0 = A.valid
A.valid = function(o) if o == gi then return true end; return valid0(o) end
local lord = obj({ requestSaveFile = function(self, a) saves[#saves + 1] = a; return true end, ClosePauseMenu = function() end, setGameSpeed = function() end })
local function hostWorld() S.p1 = lord; S.eng = obj({ gameSpeed = 1.0 }) end
local function sentWith(s) local n = 0; for _, l in ipairs(sent) do if l:find(s, 1, true) then n = n + 1 end end; return n end
local function noticesWith(s) local n = 0; for _, x in ipairs(C.notices) do if tostring(x.text):find(s, 1, true) then n = n + 1 end end; return n end
local function line(...) return { "1", "1.0", "J", ... } end
local function msg(from, ...) return M.onMessage(S, from, "J", line(...), "") end
local function tick() M.tick(S, os.clock()) end
-- a world comes: the core counts it (S.loads) and tells the modules
local function worldComes() S.loads = (S.loads or 0) + 1; S.sameWorld = nil; M.onWorld(S) end
local FP = "fingerprint_differs_for_2_days_in_a_row:_B"

-- a load alone runs to its end: the save, "J LOAD", the friend's "J READY"
local function singleRuns(who)
  tick()                                                   -- beginOne: the save is asked for
  if J.state ~= "saving1" then return false end
  J.finished = { name = J.one.name, ok = true, t = T }; after(1); tick()
  local a = J.away[who]; if not a then return false end
  after(30); msg(who, "READY", a.name, a.id)
  return J.away[who] == nil
end
-- a load of every copy runs to its end (no friend is waited for: J.expect is empty unless a test sets it)
local function allRuns()
  after(21); tick()                                        -- J.begin (20 s after the last one)
  if J.state ~= "saving" then return false end
  J.finished = { name = J.name, ok = true, t = T }; after(1); tick()
  if J.state ~= "loading" then return false end
  after(8); worldComes(); tick()                          -- the host's world is back; nobody to wait for: go
  return J.state == nil
end

-- ---------------------------------------------------------------- A: one failed load alone is enough
do
  C.setRole("host", "host", { "friend1", "friend2" }); hostWorld()
  J.cfg.single = true; J.auto = true; J.noteStart("load"); saveName = "my_town"
  worldComes()
  check(J.fresh == nil, "a host world loaded from a save: nothing to prepare")
  local singles = 0
  msg("friend1", "REPAIR", FP, "eq0"); if singleRuns("friend1") then singles = singles + 1 end
  after(150); msg("friend2", "REPAIR", FP, "eq0"); if singleRuns("friend2") then singles = singles + 1 end
  check(singles == 2 and not J.want, "each friend loads alone once for the difference")
  after(150); msg("friend1", "REPAIR", FP, "eq0")
  check(J.want == true and J.wantKinds.fingerprint == true and next(J.q) == nil, "friend 1 asks again 180 s after his load (0.2.2's 90 s window missed this): every copy loads")
  check(allRuns(), "the load of every copy runs to its end")
  check(J.allFor.fingerprint ~= nil and next(J.hist) == nil, "the breaker knows a load of every copy was for this kind; the loads alone before it no longer count")
  -- an equal day after a load alone: the next ask is a new cause
  after(20); msg("friend2", "REPAIR", "families_differ", "eq0"); check(singleRuns("friend2"), "another kind: a load alone")
  after(900); msg("friend2", "REPAIR", "families_differ", "eq3")
  check(not J.want and J.q.friend2 ~= nil, "the same kind asked again after 3 equal days since his load: a load alone again (a new cause)")
  singleRuns("friend2")
end

-- ---------------------------------------------------------------- B: the breaker
do
  local n0 = #C.notices
  after(60); msg("friend2", "REPAIR", FP, "eq0")
  check(J.brk.fingerprint ~= nil and not J.want and next(J.q) == nil, "the same kind still asked for after every copy loaded for it, no equal day since: the breaker holds it, no load")
  check(#C.notices == n0 + 1 and noticesWith("The games differ in a way a resync cannot fix (buildings). Play goes on.\nPlease send a bug report: Co-op > Make Bug Report.") == 1,
        "the players are told once, in these words")
  check(sentWith("J NOTE ") >= 1 and sentWith("J BREAK fingerprint " .. FP) == 1, "friends get the notice and the breaker's word (they log and send their difference)")
  local loads = #saves
  for _ = 1, 10 do after(80); msg("friend1", "REPAIR", FP, "eq0"); msg("friend2", "REPAIR", FP, "eq0"); tick() end
  check(#saves == loads and not J.want and next(J.q) == nil and #C.notices == n0 + 1, "for the next 13 minutes: no save, no load, no second notice")
  after(120); msg("friend1", "REPAIR", FP, "eq0")
  check(J.want == true, "15 minutes after it began to hold: one load of every copy")
  check(allRuns(), "... which runs")
  local saves1, notes1 = #saves, #C.notices                -- (the load's own "Synced" is in the list now)
  for _ = 1, 20 do after(150); msg("friend1", "REPAIR", FP, "eq0"); tick() end
  check(not J.want and #saves == saves1 and #C.notices == notes1 and noticesWith("cannot fix") == 1, "the next 50 minutes: no save, no load, no notice")
  msg("friend1", "DIFF", "fingerprint", "daily%20comparison%20day%2012%20differs%3A%20B")
  local lg = slurp(dir .. "host_log.txt") or ""
  check(lg:find("as friend1 has it (fingerprint): daily comparison day 12 differs: B", 1, true) ~= nil, "a friend's difference lands in the host's log, decoded")
  check(lg:find("THE BREAKER HOLDS fingerprint", 1, true) ~= nil, "the host's log names the breaker")
end

-- ---------------------------------------------------------------- C: kind "test" is never held
do
  J.brk.test = nil
  after(30); msg("friend1", "REPAIR", "test_resync_1", "eq0")
  check(J.q.friend1 ~= nil and not J.brk.test, "a test resync: a load alone, not held")
  singleRuns("friend1")
end

-- ---------------------------------------------------------------- D: a new world is prepared first
do
  after(10)
  C.setRole("host", "host", { "friend1", "friend2" }); hostWorld()
  J.noteStart("new"); saveName = ""
  local saves0, notes0 = #saves, #C.notices
  worldComes()
  check(J.fresh ~= nil and next(J.brk) == nil, "a world the game made: it is to be prepared; the last game's breaker is gone")
  after(2); msg("friend1", "HELLO", tostring(C.version))
  tick()
  check(J.q.friend1 ~= nil and J.state == nil and #saves == saves0, "a friend says hello at once: he waits, no load alone")
  after(9); tick()
  check(noticesWith("Preparing the new game for co-op...") == 1 and J.state == nil, "10 s after the world is up: the player is told why, the game still runs")
  after(3.5); tick()
  check(J.state == "saving" and J.prep == true and next(J.q) == nil and #saves == saves0 + 1, "3 s later: the host saves for a load of every copy; the waiting friend comes with it")
  J.finished = { name = J.name, ok = true, t = T }; after(1); tick()
  check(J.state == "loading" and sentWith("J LOAD " .. J.name) >= 1, "every copy (the waiting friend too) is told to load it; the host loads it")
  after(8); worldComes()
  check(J.fresh == nil and J.state == "waiting", "the host's own load is done: the new world counts as loaded")
  tick(); check(J.state == "waiting", "the friend is waited for")
  msg("friend1", "READY", J.name); tick()
  check(J.state == nil and noticesWith("The new game is ready for co-op") == 1 and noticesWith("joined the game") >= 1, "go: the host is told the new game is ready, and the friend joined")
  -- a second world of the same role (another load by the host) is not prepared again
  J.noteStart("new"); worldComes()
  check(J.fresh == nil, "the same host role, another world: not prepared again")
  -- no hook seen: the save name decides
  after(10); C.setRole("host", "host", { "friend1" }); hostWorld()
  J.lastStart = nil; saveName = ""
  worldComes(); check(J.fresh ~= nil, "no menu call seen and no save name: a new game")
  after(10); C.setRole("host", "host", { "friend1" }); hostWorld()
  J.lastStart = nil; saveName = "my_town"
  worldComes(); check(J.fresh == nil, "no menu call seen and a save name: a loaded world")
  -- a note from an earlier world (a solo new game before) does not speak for this one; the real flow: the world is
  -- attached while idle (no onWorld), then C.setRole attaches the same world as host (S.sameWorld)
  after(10); J.noteStart("new"); S.loads = (S.loads or 0) + 2; saveName = "my_town"
  C.setRole("host", "host", { "friend1" }); hostWorld(); S.sameWorld = true; M.onWorld(S)
  check(J.fresh == nil, "the menu's 'new' of two worlds ago does not count: the save name decides (loaded)")
  -- the second Host New Game of a run: the note of this world counts, though the last note was the prepare's load
  after(10); J.noteStart("new"); S.loads = S.loads + 1; saveName = ""
  C.setRole("host", "host", { "friend1" }); hostWorld(); S.sameWorld = true; M.onWorld(S)
  check(J.fresh ~= nil, "a second Host New Game in the same run: prepared")
  -- the two witnesses differ: prepared to be safe
  after(10); C.setRole("host", "host", { "friend1" }); hostWorld(); J.noteStart("load"); saveName = ""; worldComes()
  check(J.fresh ~= nil, "the menu says load, the save name is empty: prepared (and logged as differing)")
end

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
