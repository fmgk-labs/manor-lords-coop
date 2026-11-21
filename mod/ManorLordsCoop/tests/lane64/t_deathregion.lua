-- Desk test (lane 64, task 64d; research/.../lane_s21_64/design_deathregion.txt): a soldier's body in the host's region.
-- Runs WITHOUT the game (Lua 5.1 or 5.4):
--   py -3 -I research/2026-11-10-game-probe/lanes/lane_s21_64/tools/luarun.py <lua51.dll> mod/ManorLordsCoop/tests/lane64/t_deathregion.lua <an empty folder to use>
-- It loads the real coop.lua with stand-ins. The game puts a body on the corpse list of the dead man's currentRegion
-- (SMUnit::just_die); every man of a squad has his squad centre's region (SMUnit::updateCurrentRegion), which each
-- copy works out itself. Checked here:
--   the host: bodyRegion names the region whose corpse list holds the body (by address), not the man's currentRegion;
--     a body on no list: his currentRegion; nothing readable: "-"
--   a friend: the host's death line with the regions (D <squad> <places> <marks> <regions>) gives the man that region
--     right before just_die (his body goes onto that region's list); the same region: nothing written; a region it does
--     not know: dies as before; Coop.deathRegion = false: as before; a line without regions (a host of 0.2.6 or int20):
--     as before; a named man found by his mark still takes his own region
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane64/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_deathregion.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end
if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout); local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
_G.COOP_LINK_DIR = dir
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.FindFirstOf = function() return { IsValid = function() return false end } end
_G.FName = function(s) return "FName:" .. s end
_G.Coop = nil
dofile(scripts .. "coop.lua")
local C = _G.Coop
C.start("idle", "idle", {}); C.stop()
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 250 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name and v ~= nil then return v end end
  for i = 1, 250 do
    local n, v = debug.getupvalue(fn, i); if not n then break end
    if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
  end
end
local hostKill = C.armyApi and C.armyApi.hostKill
local bodyRegion = upvalue(C.tick, "bodyRegion") or upvalue(C.sessionStep, "bodyRegion")
local friendInbox = upvalue(C.tick, "friendInbox") or upvalue(C.sessionStep, "friendInbox")
-- (the core's steps are wrapped once for their timing, lane 45: the real step is the wrapper's upvalue f)
if friendInbox then
  for i = 1, 10 do local n, v = debug.getupvalue(friendInbox, i); if not n then break end; if n == "f" and type(v) == "function" then friendInbox = v; break end end
end
check(type(hostKill) == "function" and type(bodyRegion) == "function" and type(friendInbox) == "function", "hostKill, bodyRegion and friendInbox found")

-- the made-up world: regions with a tag and a corpse list; units with a region, a name, a squad
local nextA = 0x5000
local function obj(o) nextA = nextA + 16; local a = nextA; o.GetAddress = function() return a end; o.IsValid = function() return not o.gone end; return o end
local function region(tag) local r = obj({ corpses = {} }); r.regionUniqueTag = { ToString = function() return tag end }; return r end
local wald, sel, hof = region("wald"), region("sel"), region("hof")
local dead = {}
local function unit(id, reg, name)
  local u = obj({ UniqueID = id, currentRegion = reg, dead = false, Tags = {}, DisplayName = { ToString = function() return name or "" end }, workerFamilyID = 3 })
  function u:just_die()
    self.dead = true; dead[#dead + 1] = self
    local r = self.currentRegion; r.corpses[#r.corpses + 1] = self      -- the game's rule: the body onto its region's list
  end
  return u
end
local S = C.s
S.eng = obj({ regions = { wald, sel, hof } })
S.stats = S.stats or {}
S.role = "friend"

-- 1. the host's side: the region of a body
local b1 = unit(1, sel, ""); b1.dead = true; wald.corpses[#wald.corpses + 1] = b1     -- listed in wald, its own region says sel
check(bodyRegion(b1) == "wald", "the host: the region whose corpse list holds the body (wald), not his currentRegion (sel): " .. tostring(bodyRegion(b1)))
local b2 = unit(2, hof, ""); b2.dead = true
check(bodyRegion(b2) == "hof", "a body on no list: his currentRegion (hof)")
local b3 = unit(3, nil, ""); b3.gone = true
check(bodyRegion(b3) == "-", "nothing readable: \"-\"")

-- 2. a friend: hostKill with the host's region
local u1 = unit(11, sel, "")
hostKill(u1, "wald")
check(u1.dead and u1.currentRegion == wald and #wald.corpses == 2 and #sel.corpses == 0, "a friend: the man takes the host's region (wald) before he dies; his body is on wald's list, not sel's")
check((S.stats.deathRegionSet or 0) == 1, "counted: deathRegionSet 1")
local hadTag = false; for _, t in ipairs(u1.Tags) do if t == "FName:deathInCombat" then hadTag = true end end
check(hadTag, "the deathInCombat mark is still set first")
local u2 = unit(12, wald, "")
hostKill(u2, "wald")
check(u2.dead and (S.stats.deathRegionSame or 0) == 1 and (S.stats.deathRegionSet or 0) == 1, "the same region already: nothing written (deathRegionSame 1)")
local u3 = unit(13, sel, "")
hostKill(u3, "nowhere")
check(u3.dead and u3.currentRegion == sel and (S.stats.deathRegionUnknown or 0) == 1, "a region this copy does not know: he dies as before, in his own (sel)")
local u4 = unit(14, sel, "")
hostKill(u4, nil)
check(u4.dead and u4.currentRegion == sel, "no region given (the head-count trim, an old host): as before")
C.deathRegion = false
local u5 = unit(15, sel, "")
hostKill(u5, "wald")
check(u5.dead and u5.currentRegion == sel, "Coop.deathRegion = false: as before")
C.deathRegion = nil

-- 3. a friend reads the host's death line (friendInbox with a made-up line)
local squadUnits = {}
S.sc = { IsValidSquad = function(_, q) return q.Value == 77 end, GetSquad = function(_, q) return { unitArr = squadUnits } end }
S.h2l, S.l2h, S.madeHere = {}, {}, {}
local function setSquad(list) for i = #squadUnits, 1, -1 do squadUnits[i] = nil end; for i, u in ipairs(list) do squadUnits[i] = u end end
local line
for i = 1, 250 do
  local n = debug.getupvalue(friendInbox, i); if not n then break end
  if n == "recv" then debug.setupvalue(friendInbox, i, function() return { line }, { #line } end) end
end
local function read(l) line = l; local ok, e = pcall(friendInbox); if not ok then print("  friendInbox: " .. tostring(e)) end; return ok end
local m1, m2, m3 = unit(21, sel, ""), unit(22, sel, ""), unit(23, sel, "")
setSquad({ m3, m1, m2 })                                   -- in the game's order; the line names them by id order
local before = #wald.corpses
check(read("1 2 D 77 2 -,- wald") and m2.dead and not m1.dead and not m3.dead and m2.currentRegion == wald and #wald.corpses == before + 1, "the line D 77 2 -,- wald: the man at place 2 (id 22) dies in wald, his body on wald's list")
local m4 = unit(24, sel, "")
setSquad({ m1, m3, m4 })
check(read("1 2 D 77 3") and m4.dead and m4.currentRegion == sel, "a line without regions (a host of 0.2.6 or int20): the man at place 3 dies where he is, as before")
local n1 = unit(31, sel, "Hans"); local n2 = unit(32, sel, "Otto")
setSquad({ n1, n2 })
check(read("1 2 D 77 1 3.Otto hof") and n2.dead and not n1.dead and n2.currentRegion == hof, "a named man found by his mark (3.Otto) takes his own region (hof)")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
return fail == 0
