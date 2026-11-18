-- Desk test: "written before this session" without comparing two PCs' clocks (lane 62, from lane 73's finding).
-- Runs WITHOUT the game:   lua mod/ManorLordsCoop/tests/lane62/t_clock.lua <an empty folder to use>
-- It loads the real coop.lua with stand-ins, writes another player's line file with that player's clock 5 s AHEAD of,
-- 5 s BEHIND and equal to this copy's clock, and asks the real reader and C.stale. The rule before (the sender's stamp
-- against this copy's start time minus 1 s) is computed beside it, to show what it threw away.
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane62/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_clock.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end
if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout); local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function spit(p, s, mode) local f = assert(io.open(p, mode or "wb")); f:write(s); f:close() end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
_G.COOP_LINK_DIR = dir
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.FindFirstOf = function() return { IsValid = function() return false end } end
_G.Coop = nil
dofile(scripts .. "coop.lua")
local C = _G.Coop; local L = C.link
C.start("idle", "idle", {}); C.stop()                       -- (the core sets its wall clock at its first start)
local function words(line) local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end; return w end
local function oldRule(S, w) local wall = tonumber(w[2]); return wall and wall < S.startWall - 1 end   -- what the seven places asked until now

-- one pass: this copy is <role>, the other player <peer> writes with its clock <d> seconds off this copy's
local function pass1(role, me, peer, d)
  local tag = string.format("%s reads %s, whose clock is %+d s", role, peer, d)
  local file = dir .. peer .. ".txt"
  local t = C.api.now() + d                              -- the other player's clock
  -- three lines that player wrote before this copy starts (10 to 8 s ago by its own clock)
  spit(file, string.format("1 %.3f X old a\n2 %.3f X old b\n3 %.3f X old c\n", t - 10, t - 9, t - 8))
  C.start(role, me, role == "host" and { peer } or {})
  local S = C.s
  t = C.api.now() + d
  -- its lines after this copy started: the first one in the same second, as a friend's first order or the host's first lines are
  spit(file, string.format("4 %.3f X new a\n5 %.3f X new b\n6 %.3f X new c\n", t + 0.05, t + 0.4, t + 2.0), "ab")
  local lines = L.recv(peer)
  local keptNew, keptOld = 0, 0
  for _, l in ipairs(lines) do local w = words(l); if not C.stale(peer, w) then keptNew = keptNew + 1 end; if not oldRule(S, w) then keptOld = keptOld + 1 end end
  check(#lines == 3 and keptNew == 3, tag .. ": the 3 lines written after this copy started all count (the rule before kept " .. keptOld .. " of 3)")
  -- the whole file read again from its start (as after a reader that lost its place): the 3 old lines are history, the 3 new ones not
  S.readers[peer].off = 0; S.readers[peer].part = ""; S.readers[peer].head = nil
  lines = L.recv(peer)
  local hist, fresh, oldHist = 0, 0, 0
  for _, l in ipairs(lines) do local w = words(l); if C.stale(peer, w) then hist = hist + 1 else fresh = fresh + 1 end; if oldRule(S, w) then oldHist = oldHist + 1 end end
  check(#lines == 6 and hist == 3 and fresh == 3, tag .. ": read again from the start, the 3 lines from before are history and the 3 new ones are not (the rule before called " .. oldHist .. " of 6 history)")
  -- that player starts again: its file is written anew from line 1, with a clock that even went back 20 s. Nothing in it is history.
  t = C.api.now() + d - 20
  spit(file, string.format("1 %.3f X again a\n2 %.3f X again b\n", t, t + 0.1))
  lines = L.recv(peer)
  local kept = 0; for _, l in ipairs(lines) do if not C.stale(peer, words(l)) then kept = kept + 1 end end
  check(#lines == 2 and kept == 2, tag .. ": that player started again (file written anew from line 1, its clock 20 s back): both lines count")
  C.stop()
end
for _, d in ipairs({ 5, -5, 0 }) do pass1("friend", "friend1", "host", d); pass1("host", "host", "friend1", d) end

-- a file that was missing or empty when this copy started has no history
os.remove(dir .. "host.txt")
C.start("friend", "friend1", {})
local t = C.api.now() - 5
spit(dir .. "host.txt", string.format("1 %.3f X first\n", t))
local lines = L.recv("host")
check(#lines == 1 and not C.stale("host", words(lines[1])), "no file of that player at the start: its first line counts, whatever its clock (5 s behind here)")
C.stop()

-- every place that asked the clocks asks C.stale now
local n = 0
for _, f in ipairs({ "coop.lua", "coop_facts.lua", "coop_world.lua", "coop_session.lua", "coop_x_fields.lua", "coop_join.lua", "coop_town.lua", "coop_realm.lua" }) do
  local s = slurp(scripts .. f) or ""
  for _ in s:gmatch("startWall %- 1") do n = n + 1 end
end
local core = slurp(scripts .. "coop.lua")
local _, uses = core:gsub("not stale%(peer, w%)", "")
check(n == 0 and uses == 3, "no place compares a sender's stamp with this copy's start time any more (0 left; the host's three checks ask the reader's mark)")
print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
