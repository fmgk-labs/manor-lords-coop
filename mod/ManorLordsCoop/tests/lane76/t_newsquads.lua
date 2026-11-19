-- Desk test of the friend's making of new squads (lane 76, 2026-11-19). Runs WITHOUT the game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_newsquads.lua <an empty folder>
-- It loads the real coop.lua; squads, the lords, the host's lines and the clock are the test's own.
-- What it shows: the squads the host made in one tick (N lines in a row) are made here in ONE call of the inbox, so
-- no frame of this copy shows a part of a new army (session l76i: 18 soldiers for a frame where the host had 126).
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane76/[^/]*$") or ".") .. "/Scripts/"
local dir = (arg and arg[1]) or ARG1
if not dir then print("give an empty folder"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end
if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout)
  local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
  math.tointeger = math.tointeger or function(x) x = tonumber(x); if x and x == math.floor(x) then return x end end
end
_G.COOP_LINK_DIR = dir
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.FName = function(s) return s end
_G.Coop = nil
local T = 900.0
os.clock = function() return T end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end

dofile(scripts .. "coop.lua")
local C = _G.Coop
local squads, nextH, removedAsk = {}, 500, {}
local lord = { IsValid = function() return true end, GetAddress = function() return 1 end, bIsPlayerPaused = false, commandedSquads = {} }
local rival = { IsValid = function() return true end, GetAddress = function() return 2 end, commandedSquads = {}, isBandit = false }
local sizes = { Brigands = 18, mercenary_infantry = 36, mercenary_spearmen = 36, Mercenary_Archers = 36 }
local sc = { IsValid = function() return true end }
function sc:IsValidSquad(k) return squads[k.Value] ~= nil end
function sc:GetSquad(k) return squads[k.Value] end
function sc:GetUnitCount(k) return squads[k.Value].n end
function sc:RequestRemoveSquad(k) removedAsk[k.Value] = true; squads[k.Value] = nil end
function sc:SetSkillActive() end
local eng = { IsValid = function() return true end, gameSpeed = 1.0 }
function eng:getPawnBySetupIndex(i) return i == 1 and rival or nil end
function eng:spawnCompleteUnit(name, loc, rot, owner)
  nextH = nextH + 1
  squads[nextH] = { n = sizes[name] or 30, unitType = { ToString = function() return name end }, Control = 0, isEngaged = false, targetSquad = { Value = 0 }, engagedSquads = {}, activeSkills = {}, unitArr = {} }
  owner.commandedSquads[#owner.commandedSquads + 1] = { Value = nextH }
  return { Value = nextH }
end
-- soldiers of the rival lord on this copy, as the daily comparison counts them
local function rivalMen() local n = 0; for _, e in ipairs(rival.commandedSquads) do if squads[e.Value] then n = n + squads[e.Value].n end end; return n end
local polls = {}
C.devLink = { recv = function() local p = table.remove(polls, 1) or {}; local ends = {}; for i = 1, #p do ends[i] = i end; return p, ends end }
local function world()
  C.start("friend", "friend1", {})
  local S = C.s
  S.p1 = lord; S.sc = sc; S.eng = eng
  S.pawns = { lord, rival }; S.pawnsT = 1e9
  squads, removedAsk = {}, {}; rival.commandedSquads = {}; lord.commandedSquads = {}; polls = {}; C.hold = nil; C.nBatch = nil
  return S
end
local seq = 0
local function N(h, typ, owner, n) seq = seq + 1; return string.format("%d %.3f N %d %s %s 100 200 0 %d -", seq, T, h, typ, owner or "A1", n or sizes[typ] or 30) end
local function other(kind, rest) seq = seq + 1; return string.format("%d %.3f %s %s", seq, T, kind, rest or "") end
-- one poll of the inbox, 20 ms later; returns the rival's soldiers after it (what the next frame shows)
local function poll(lines) polls[#polls + 1] = lines or {}; T = T + 0.02; C.s.pawnsT = T; C.friendInboxFn(); return rivalMen() end
local army = function() return { N(21, "Brigands"), N(22, "mercenary_infantry"), N(23, "mercenary_spearmen"), N(24, "Mercenary_Archers") } end

-- 1. the l76i case: the first line arrives alone, the other three and the state of that look in the next poll
T = T + 20; local S = world(); local a = army()
local seen = { poll({ a[1] }), poll({ a[2], a[3], a[4], other("ZZ") }) }
check(seen[1] == 0 and seen[2] == 126, "an army announced as four lines over two polls: this copy shows " .. seen[1] .. " then " .. seen[2] .. " soldiers (never a part of it)")
check(S.h2l[21] and S.h2l[22] and S.h2l[23] and S.h2l[24] and S.stats.created == 4, "all four squads are tied to the host's numbers")

-- 2. the old way (C.nBatch = false) shows the fault the hold removes
T = T + 20; S = world(); a = army(); C.nBatch = false
seen = { poll({ a[1] }), poll({ a[2], a[3], a[4], other("ZZ") }) }
check(seen[1] == 18 and seen[2] == 126, "with C.nBatch = false, as before: " .. seen[1] .. " then " .. seen[2] .. " (18 is a count the host never had)")

-- 3. nothing else arrives: made 0.15 s after the first line waited, not later
T = T + 20; S = world(); a = army()
local t0 = T; poll({ a[1], a[2] }); local madeAt
for _ = 1, 20 do local n = poll({}); if n > 0 and not madeAt then madeAt = T - t0 end end
check(madeAt and madeAt >= 0.15 and madeAt <= 0.20 and rivalMen() == 54, "no other line: both squads made together " .. string.format("%.2f", madeAt or -1) .. " s after the first line (limit 0.15 s plus one poll)")

-- 4. deaths in another squad do not end the wait; a line that names a waiting squad does
T = T + 20; S = world(); a = army()
seen = { poll({ a[1], other("D", "999 1") }), poll({ a[2], other("D", "22 1"), a[3] }) }
check(seen[1] == 0, "a death line of another squad lets the new squads wait")
check(seen[2] == 54 and S.pendN and #S.pendN == 1, "a death line that names a waiting squad makes the waiting ones first (" .. seen[2] .. " soldiers), the next waits again")
poll({ other("ZZ") })
check(rivalMen() == 90 and not S.pendN, "and the last one is made at the next other line")

-- 5. a squad announced and gone again at once (G for a waiting squad): made, then handed to the removal, in order
T = T + 20; S = world(); a = army()
poll({ a[1], other("G", "21") })
check(S.stats.created == 1 and not S.pendN, "N then G for the same squad: made first, then the removal rule has it")

-- 6. a join begins while squads wait: they are dropped (the join brings the host's squads), nothing is made
T = T + 20; S = world(); a = army()
poll({ a[1], a[2] }); C.hold = true
for _ = 1, 10 do poll({}) end
check(rivalMen() == 0 and not S.pendN and (S.stats.created or 0) == 0, "a join holds this copy: the waiting lines are dropped, nothing made")
C.hold = nil

-- 7. a new world while squads wait
T = T + 20; S = world(); a = army()
poll({ a[1] }); S.worlds = (S.worlds or 0) + 1
for _ = 1, 10 do poll({}) end
check(rivalMen() == 0 and not S.pendN, "another world: the waiting lines of the old one are dropped")

-- 8. the host names a squad again (R) that this copy has: nothing is made; an empty squad: nothing is made
T = T + 20; S = world(); a = army()
poll({ a[1], other("ZZ") }); local before = S.stats.created
seq = seq + 1; poll({ string.format("%d %.3f N 21 Brigands A1 100 200 0 18 - R", seq, T), N(30, "retinue_tier1", "A1", 0), other("ZZ") })
check(S.stats.created == before and rivalMen() == 18, "a repeated announcement of a squad this copy has and an empty squad make nothing")

print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_newsquads failed") end
