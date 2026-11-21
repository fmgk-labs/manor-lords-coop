-- Desk test of the friend's removal of a YOUNG squad (lane 90, coop.lua youngStir / youngTick / youngQuiet). Runs
-- WITHOUT the game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane90/t90_young.lua <an empty folder>
-- It loads the real coop.lua and feeds the host's lines (N, S, G) through the real inbox; squads, men, the lords and
-- the clock are the test's own tables.
-- What it shows: a squad the host made and took away within half a second ("blink", lane 90's logs: l86jb, l7v,
-- r27cf, l7b) is made here, and at the host's word it is removed the short way, under 1 s after the word (it was 4.1 to
-- 4.5 s). Every case with any doubt keeps the 4 s rule: the host's entry named a target, a raid or a rout; the squad
-- had a fight flag for one frame; a man has a task or a fighting stance; a read fails; the squad flees here; it was
-- made in another world; it starts to fight after the word; C.rmYoung = false.
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane90/[^/]*$") or ".") .. "/Scripts/"
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
local squads, nextH, removed, halted = {}, 500, {}, {}
local lord = { IsValid = function() return true end, GetAddress = function() return 1 end, bIsPlayerPaused = false, commandedSquads = {} }
local rival = { IsValid = function() return true end, GetAddress = function() return 2 end, commandedSquads = {}, isBandit = false }
_G.FindAllOf = function() return { lord, rival } end
local sizes = { Brigands = 18, mercenary_infantry = 36, mercenary_spearmen = 36, Mercenary_Archers = 36 }
local function man() return { IsValid = function() return true end, dead = false, fightingStance = false, Tasks = {} } end
local sc = { IsValid = function() return true end }
local failRead = {}
function sc:IsValidSquad(k) return squads[k.Value] ~= nil end
function sc:GetSquad(k) if failRead[k.Value] then error("read failed") end; return squads[k.Value] end
function sc:GetUnitCount(k) return #squads[k.Value].unitArr end
function sc:RequestRemoveSquad(k) removed[k.Value] = T; squads[k.Value] = nil end
function sc:SetSkillActive(k) halted[k.Value] = (halted[k.Value] or 0) + 1 end
local eng = { IsValid = function() return true end, gameSpeed = 1.0 }
function eng:getPawnBySetupIndex(i) return i == 1 and rival or nil end
function eng:spawnCompleteUnit(name, loc, rot, owner)
  nextH = nextH + 1
  local s = { unitType = { ToString = function() return name end }, Control = 0, isEngaged = false, targetSquad = { Value = 0 }, engagedSquads = {}, activeSkills = {}, unitArr = {} }
  for i = 1, sizes[name] or 30 do s.unitArr[i] = man() end
  squads[nextH] = s
  owner.commandedSquads[#owner.commandedSquads + 1] = { Value = nextH }
  return { Value = nextH }
end
local polls = {}
C.devLink = { recv = function() local p = table.remove(polls, 1) or {}; local ends = {}; for i = 1, #p do ends[i] = i end; return p, ends end }
local function world()
  C.start("friend", "friend1", {})
  local S = C.s
  S.p1 = lord; S.sc = sc; S.eng = eng; S.cfg.followSpeed = false
  S.pawns = { lord, rival }; S.pawnsT = T
  squads, removed, halted, failRead = {}, {}, {}, {}; rival.commandedSquads = {}; lord.commandedSquads = {}; polls = {}; C.hold = nil; C.rmYoung = nil
  return S
end
local seq = 0
local function N(h, typ) seq = seq + 1; return string.format("%d %.3f N %d %s A1 100 200 0 %d -", seq, T, h, typ, sizes[typ] or 30) end
local function G(h) seq = seq + 1; return string.format("%d %.3f G %d", seq, T, h) end
-- the host's state entry of one squad (partial list): h,n,ctl,tgt,tx,ty,tz,push,behav,skills,cx,cy,eng,rs
local function St(h, o) o = o or {}
  seq = seq + 1
  return string.format("%d %.3f S 1.00 0 400.5000 %d,18,%d,%d,0,0,0,0,0,%s,100,200,%d,0 P", seq, T, h, o.ctl or 0, o.tgt or 0, o.sk or "-", o.eng and 1 or 0)
end
-- the friend's frames: every 0.05 s the inbox (when lines wait) and the young look; every 0.5 s the removal tick
local nextRm = 0
local function frames(seconds, each)
  for _ = 1, math.floor(seconds / 0.05 + 0.5) do
    T = T + 0.05; C.s.pawnsT = T
    if #polls > 0 then C.friendInboxFn() end
    C.friendInboxFn()                                   -- a waiting N line is made 0.15 s after it came
    C.youngTickFn()
    if T >= nextRm then nextRm = T + 0.5; C.removeTickFn(T) end
    if each then each() end
  end
end
local function lines(list) polls[#polls + 1] = list end
-- one case: the host announces a squad, (what happens), the host's word "gone" 0.55 s after the announcement;
-- returns the seconds from the word to the removal, and the local squad
local function case(setup)
  T = T + 30; nextRm = T; local S = world()
  frames(1.0)                                           -- this copy's quiet clock runs in this world
  lines({ N(41, "Brigands") }); frames(0.3)
  local h = S.h2l[41]
  if setup then setup(S, h) end
  frames(0.25)
  local t0 = T; lines({ G(41) })
  for _ = 1, 160 do if removed[h] then break end; frames(0.05) end
  return removed[h] and (removed[h] - t0) or nil, h, S
end

-- 1. the blink: made, quiet all its life, gone on the host 0.55 s after the announcement
local d, h, S = case()
check(h ~= nil and S.l2h[h] == 41 and removed[h] ~= nil, "the squad was made here for the host and is gone again")
check(d and d <= 1.0 and halted[h] == 1, "a blink squad, quiet all its life: halted and removed " .. tostring(d) .. " s after the host's word (was 4.1 to 4.5 s)")
check(S.stats.removedYoung == 1 and S.stats.removedFast == 1, "counted as a young and a short removal")

-- 2. the switch
d = case(function() C.rmYoung = false end)
check(d and d >= 4.0, "C.rmYoung = false: the 4 s rule of before (" .. tostring(d) .. " s)")

-- 3. the host's entry named a target
d = case(function() lines({ St(41, { tgt = 77 }) }) end)
check(d and d >= 4.0, "the host's entry named a target: the 4 s rule (" .. tostring(d) .. " s)")

-- 4. the host's entry carried the raid skill
d = case(function() lines({ St(41, { sk = "19" }) }) end)
check(d and d >= 4.0, "the host's entry carried the raid skill: the 4 s rule (" .. tostring(d) .. " s)")

-- 5. the host's entry said it routs, or that it fights
d = case(function() lines({ St(41, { ctl = 3 }) }) end)
check(d and d >= 4.0, "the host's entry said it routs: the 4 s rule (" .. tostring(d) .. " s)")
d = case(function() lines({ St(41, { eng = true }) }) end)
check(d and d >= 4.0, "the host's entry said it fights: the 4 s rule (" .. tostring(d) .. " s)")

-- 6. a fight flag here for one frame, between two of the removal tick's notes
d = case(function(S2, hh) local s = squads[hh]; s.isEngaged = true; frames(0.05); s.isEngaged = false end)
check(d and d >= 4.0, "a fight flag for one frame between two notes: the 4 s rule (" .. tostring(d) .. " s)")

-- 7. a man with a task at the word; a man in a fighting stance for one frame
d = case(function(S2, hh) squads[hh].unitArr[3].Tasks = { { type = 51 } } end)
check(d and d >= 4.0, "a man with a task of his own at the word: the 4 s rule (" .. tostring(d) .. " s)")
d = case(function(S2, hh) local u = squads[hh].unitArr[1]; u.fightingStance = true; frames(0.05); u.fightingStance = false end)
check(d and d >= 4.0, "a man in a fighting stance for one frame: the 4 s rule (" .. tostring(d) .. " s)")

-- 8. a target building part
d = case(function(S2, hh) squads[hh].targetBuildingPart = { IsValid = function() return true end }; frames(0.05); squads[hh].targetBuildingPart = nil end)
check(d and d >= 4.0, "a building target for one frame: the 4 s rule (" .. tostring(d) .. " s)")

-- 9. a read that fails
d = case(function(S2, hh) failRead[hh] = true; frames(0.05); failRead[hh] = nil end)
check(d and d >= 4.0, "a read that failed once: the 4 s rule (" .. tostring(d) .. " s)")

-- 10. it flees here
d, h = case(function(S2, hh) squads[hh].Control = 3 end)
check(d and d >= 4.0 and not halted[h], "it flees here: 4 s without a halt, as before (" .. tostring(d) .. " s)")

-- 11. starts to fight after the word, in the 0.4 s wait
T = T + 30; nextRm = T; S = world(); frames(1.0)
lines({ N(41, "Brigands") }); frames(0.55)
h = S.h2l[41]; local t0 = T; lines({ G(41) }); frames(0.1)
squads[h].isEngaged = true
for _ = 1, 160 do if removed[h] then break end; frames(0.05, function() if T - t0 > 2.0 and squads[h] then squads[h].isEngaged = false end end) end
check(removed[h] and removed[h] - t0 >= 4.0, "starts to fight right after the word: the short way is dropped, the 4 s rule (" .. tostring(removed[h] and removed[h] - t0) .. " s)")

-- 12. made in another world
d = case(function(S2) S2.worlds = (S2.worlds or 0) + 1 end)
check(d and d >= 4.0, "made in another world: the young way is closed (" .. tostring(d) .. " s)")

-- 13. a squad this copy did not make (from the save), seen for 1 s: the 4 s rule, unchanged
T = T + 30; nextRm = T; S = world()
squads[41] = { unitType = { ToString = function() return "Brigands" end }, Control = 0, isEngaged = false, targetSquad = { Value = 0 }, engagedSquads = {}, activeSkills = {}, unitArr = { man(), man() } }
rival.commandedSquads = { { Value = 41 } }
frames(1.0); t0 = T; lines({ G(41) })
for _ = 1, 160 do if removed[41] then break end; frames(0.05) end
check(removed[41] and removed[41] - t0 >= 4.0, "a squad of the save seen for 1 s: the 4 s rule, unchanged (" .. tostring(removed[41] and removed[41] - t0) .. " s)")

-- 14. a young squad watched quiet for over 4.5 s: lane 76's quiet rule has it, the young mark is dropped
T = T + 30; nextRm = T; S = world(); frames(1.0)
lines({ N(41, "Brigands") }); frames(6.0)
h = S.h2l[41]
check(S.young[h] == nil, "after 4.5 s of quiet watching the young mark is dropped")
t0 = T; lines({ G(41) })
for _ = 1, 160 do if removed[h] then break end; frames(0.05) end
check(removed[h] and removed[h] - t0 <= 1.0 and (S.stats.removedYoung or 0) == 0, "and the quiet rule removes it the short way (" .. tostring(removed[h] and removed[h] - t0) .. " s)")

print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t90_young failed") end
