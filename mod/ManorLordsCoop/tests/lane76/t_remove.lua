-- Desk test of the friend's squad removal (lane 76, 2026-11-18). Runs WITHOUT the game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_remove.lua <an empty folder>
-- It loads the real coop.lua; squads, men, the lord and the clock are the test's own tables.
-- What it shows: a squad gone on the host that has been quiet for over 4 s of running game is removed at the next
-- look (0.5 s), every other squad by the old 4 s rule: one that fought lately, one seen for under 4 s, one whose
-- quiet seconds passed while the game was paused, one with a man in a fighting stance, one that raids, one that
-- only just began to flee, one that starts to fight after the word, and every squad with C.rmFast = false.
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
_G.Coop = nil
local T = 900.0
os.clock = function() return T end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end

dofile(scripts .. "coop.lua")
local C = _G.Coop
local live = { IsValid = function() return true end }
local squads, removed, halted = {}, {}, {}
local lord = { IsValid = function() return true end, GetAddress = function() return 1 end, bIsPlayerPaused = false, commandedSquads = {} }
local rival = { IsValid = function() return true end, GetAddress = function() return 2 end, commandedSquads = {} }
local function man(stance, task) return { IsValid = function() return true end, dead = false, fightingStance = stance or false, Tasks = task and { { type = 51 } } or {} } end
local function squad(h, n, t)
  t = t or {}
  local s = { Control = t.flee and 3 or 0, isEngaged = t.engaged or false, targetSquad = { Value = 0 }, engagedSquads = {}, activeSkills = t.skills or {}, unitArr = {} }
  for i = 1, n do s.unitArr[i] = man(t.stance and i == 1, t.task and i == n) end
  squads[h] = s; rival.commandedSquads[#rival.commandedSquads + 1] = { Value = h }
  return s
end
local sc = { IsValid = function() return true end }
function sc:IsValidSquad(k) return squads[k.Value] ~= nil end
function sc:GetSquad(k) return squads[k.Value] end
function sc:GetUnitCount(k) return #squads[k.Value].unitArr end
function sc:RequestRemoveSquad(k) removed[k.Value] = T; squads[k.Value] = nil end
function sc:SetSkillActive(k, skill) halted[k.Value] = (halted[k.Value] or 0) + 1 end

local function world()
  C.start("friend", "friend1", {})
  local S = C.s
  S.p1 = lord; S.sc = sc; S.eng = { IsValid = function() return true end, gameSpeed = 1.0 }
  S.pawns = { lord, rival }; S.pawnsT = 1e9
  squads, removed, halted = {}, {}, {}; rival.commandedSquads = {}; lord.bIsPlayerPaused = false
  return S
end
local function run(seconds) for _ = 1, math.floor(seconds / 0.5 + 0.5) do T = T + 0.5; S_pawnsKeep(); C.removeTickFn(T) end end
function S_pawnsKeep() C.s.pawnsT = T end
-- seconds from the host's word to the removal of squad h (the tick looks every 0.5 s)
local function gone(h, limit)
  local t0 = T
  C.removeSafe(h, "gone on the host")
  for _ = 1, math.floor((limit or 12) / 0.5) do if removed[h] then break end; T = T + 0.5; S_pawnsKeep(); C.removeTickFn(T) end
  return removed[h] and (removed[h] - t0) or nil
end

T = T + 20; world(); squad(11, 36); run(6)
local d = gone(11)
check(d and d <= 1.0 and halted[11] == 1, "quiet for 6 s: halted and removed " .. tostring(d) .. " s after the host's word (was 4 to 4.5 s)")
check(C.s.stats.removedFast == 1, "counted as a short removal")

T = T + 20; world(); squad(12, 36); run(2)
d = gone(12)
check(d and d >= 4.0, "seen for only 2 s: the 4 s rule (" .. tostring(d) .. " s)")

T = T + 20; world(); local s = squad(13, 36, { engaged = true }); run(6); s.isEngaged = false; run(2)
d = gone(13)
check(d and d >= 4.0, "fought 2 s ago: the 4 s rule (" .. tostring(d) .. " s)")

T = T + 20; world(); s = squad(14, 36, { engaged = true }); run(3); s.isEngaged = false
lord.bIsPlayerPaused = true; C.s.eng.gameSpeed = 0; run(10); lord.bIsPlayerPaused = false; C.s.eng.gameSpeed = 1.0; run(1)
d = gone(14)
check(d and d >= 4.0, "fought, then 10 s of PAUSE and 1 s of game: its arrows may still hang in the air, the 4 s rule (" .. tostring(d) .. " s)")

T = T + 20; world(); squad(15, 36, { stance = true }); run(6)
d = gone(15)
check(d and d >= 4.0, "a man in a fighting stance: the 4 s rule (" .. tostring(d) .. " s)")

T = T + 20; world(); squad(22, 12, { task = true }); run(6)
d = gone(22)
check(d and d >= 4.0, "a man with a task of his own (a torch thrower): the 4 s rule (" .. tostring(d) .. " s)")

T = T + 20; world(); s = squad(23, 36, { engaged = true }); run(3); s.isEngaged = false
C.s.eng.gameSpeed = 0; run(10); C.s.eng.gameSpeed = 1.0; run(1)
d = gone(23)
check(d and d >= 4.0, "fought, then 10 s at speed 0 without the pause flag: no quiet time counted, the 4 s rule (" .. tostring(d) .. " s)")

T = T + 20; world(); squad(16, 12, { skills = { 19 } }); run(6)
d = gone(16, 20)
check(d and d >= 4.0, "a raiding squad (skill 19): the 4 s rule, unchanged (" .. tostring(d) .. " s)")

T = T + 20; world(); squad(17, 8, { flee = true, engaged = true }); run(6)
d = gone(17)
check(d and d <= 1.0 and not halted[17], "fleeing for 6 s: removed " .. tostring(d) .. " s after the word, never halted")

T = T + 20; world(); s = squad(18, 8, { engaged = true }); run(6); s.Control = 3; run(1)
d = gone(18)
check(d and d >= 4.0 and not halted[18], "began to flee 1 s ago: 4 s without a halt, as before (" .. tostring(d) .. " s)")

T = T + 20; world(); s = squad(19, 36); run(6)
C.removeSafe(19, "gone on the host"); s.isEngaged = true
local t0 = T
for _ = 1, 30 do if removed[19] then break end; T = T + 0.5; S_pawnsKeep(); C.removeTickFn(T); if T - t0 >= 2.0 then s.isEngaged = false end end
check(removed[19] and removed[19] - t0 >= 4.0, "starts to fight right after the word: the short way is dropped, removed by the 4 s rule (" .. tostring(removed[19] and removed[19] - t0) .. " s)")

T = T + 20; world(); squad(20, 36); run(6); C.rmFast = false
d = gone(20); C.rmFast = nil
check(d and d >= 4.0, "C.rmFast = false: the rule of before (" .. tostring(d) .. " s)")

T = T + 20; world(); s = squad(21, 36); s.unitArr = {}; run(1)
d = gone(21)
check(d == 0, "an empty squad is removed at once, as before")

print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_remove failed") end
