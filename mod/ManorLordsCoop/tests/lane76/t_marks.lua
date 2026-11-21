-- Desk test of the family marks on a friend (lane 76 task 76f, coop_facts.lua friendFamJob). Runs WITHOUT the game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_marks.lua mod/ManorLordsCoop/Scripts/coop_facts.lua
-- Session l76k: 25 of 62 differing readings of a family's marks stood past 3 s (the host read every second, the friend
-- looked every second and a mark one off waited 3 s more); garments was carried by nothing.
local T = 500.0
os.clock = function() return T end
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
local logs, sent, mod = {}, {}, nil
local function live(o) return type(o) == "table" and o.live == true end
Coop = {
  register = function(name, m) if name == "facts" then mod = m end end, stale = function() return false end,
  api = { valid = live, un = function(o) return o end, now = os.clock, isPaused = function() return false end, btype = function(b) return b.type end,
    log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function(line) sent[#sent + 1] = line end }
}
assert(loadfile(ARG1))()
local F = Coop.facts
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 250 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name and v ~= nil then return v end end
  for i = 1, 250 do
    local n, v = debug.getupvalue(fn, i); if not n then break end
    if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
  end
end
local friendFamJob = assert(upvalue(mod.tick, "friendFamJob"), "friendFamJob not found")
local hostFamJob = assert(upvalue(mod.tick, "hostFamJob"), "hostFamJob not found")
local onLine = assert(upvalue(mod.onMessage, "onLine"), "onLine not found")
local nextAddr = 0x30000
local function obj(o) nextAddr = nextAddr + 16; local a = nextAddr; o.live = true; o.GetAddress = function() return a end; return o end
local lord = obj({})
local fam = { ConsumptionStatus = { hunger = 1, cold = 0, ale = 0, garments = 1, footwear = 0, sickness = 0, injured = 0 } }
local region = obj({ ownerPawn = lord, regionUniqueTag = { ToString = function() return "hof" end }, workerFamilies = { fam } })
local S = { role = "friend", worlds = 1, stats = {}, p1 = lord, eng = obj({ regions = { region } }) }
local function setup(role)
  S.role = role
  F.S = S; F.world = 1; F.me = lord.GetAddress(); F.exact = true; F.on.families = true; F.famOff = nil
  F.host = { b = {}, a = {}, m = {} }; F.famDay = {}; F.famSince = {}; F.sentM = {}; F.stats = {}; sent = {}; logs = {}
  fam.ConsumptionStatus = { hunger = 1, cold = 0, ale = 0, garments = 1, footwear = 0, sickness = 0, injured = 0 }
end
local function look() local st = { clock = T, paused = false }; for _ = 1, 20 do if friendFamJob(st) then return end end end
local function hostSays(text) onLine(S, { "1", "0", "F", "M", "hof", text }) end
-- what the host sends: all seven marks, in the order cold sickness injured hunger garments footwear ale
setup("host")
do local st = { key = true }; for _ = 1, 20 do if hostFamJob(st) then break end end end
check(#sent == 1 and sent[1] == "F M hof 1:0:0:0:1:1:0:0:-", "host: a family's line carries seven marks, garments, footwear and ale too (" .. tostring(sent[1]) .. ")")
check(F.cfg.exactFamEvery == 0.5 and F.cfg.famWait == 0.4, "exact mode: marks are read and looked at every 0.5 s; a mark one off waits 0.4 s")
-- a mark one off the host's: not at once, but within 1.5 s of the host's word (with a look every 0.5 s)
setup("friend")
hostSays("1:0:0:0:2:1:0:0:-")                                   -- hunger 2 on the host, 1 here
look(); local first = fam.ConsumptionStatus.hunger
local took
for i = 1, 6 do T = T + 0.5; look(); if not took and fam.ConsumptionStatus.hunger == 2 then took = i * 0.5 end end
check(first == 1 and took and took <= 1.01, "friend: hunger one off is written " .. tostring(took) .. " s after the first look (was 3 s), not at once")
-- this copy's own day step comes 0.2 s after the host's word: nothing is written, nothing is a day ahead
setup("friend")
hostSays("1:0:0:0:2:1:0:0:-")
look(); T = T + 0.2; fam.ConsumptionStatus.hunger = 2            -- the own step
local worst = 2
for _ = 1, 6 do T = T + 0.5; look(); if fam.ConsumptionStatus.hunger ~= 2 then worst = fam.ConsumptionStatus.hunger end end
check(worst == 2 and (F.stats.famFix or 0) == 0, "friend: its own day step 0.2 s after the host's word: equal, no write")
-- garments: carried now
setup("friend")
hostSays("1:0:0:0:1:2:0:0:-")                                   -- garments 2 on the host, 1 here
look(); for _ = 1, 3 do T = T + 0.5; look() end
check(fam.ConsumptionStatus.garments == 2, "friend: garments takes the host's value (was carried by nothing)")
-- more than one off: at once
setup("friend")
hostSays("1:0:0:0:3:1:0:0:-")
look()
check(fam.ConsumptionStatus.hunger == 3, "friend: a mark two off is written on the first look")
-- a new mark that does not take the host's value is left alone; the old marks go on
setup("friend")
setmetatable(fam.ConsumptionStatus, { __newindex = function() end })
local cs = fam.ConsumptionStatus; local ale = cs.ale; cs.ale = nil      -- reads 0 through the metatable, writes are lost
getmetatable(cs).__index = function(_, k) if k == "ale" then return 0 end end
hostSays("1:0:0:0:3:1:0:2:-")
look()
check(F.on.families == true and F.famOff and F.famOff.ale == true and cs.hunger == 3, "friend: ale does not take the value: that mark is left alone, the item stays on, hunger is written")
-- (task 76e) this copy's own day change: its day step moved a mark one off the host's last word: set back in that tick
local famDayChange = assert(upvalue(mod.tick, "famDayChange"), "famDayChange not found")
setmetatable(fam.ConsumptionStatus, nil)
local day = 368
S.eng.getDaysTotal = function() return day end
setup("friend"); F.famDayLast = nil
hostSays("1:0:0:0:1:1:0:0:-")                                   -- hunger 1 on the host
famDayChange(S, T)                                              -- the day as it was: nothing written
check(fam.ConsumptionStatus.hunger == 1 and (F.stats.famDayFix or 0) == 0, "friend: no day change, no write")
day = 369; fam.ConsumptionStatus.hunger = 2                     -- this copy's own day step: hunger 2 (l76b, day 369)
famDayChange(S, T)
check(fam.ConsumptionStatus.hunger == 1 and F.stats.famDayFix == 1, "friend: its day step's hunger 2 is set back to the host's 1 in the tick of its day change")
fam.ConsumptionStatus.hunger = 2; famDayChange(S, T)            -- the same day: the rule for a difference of one again
check(fam.ConsumptionStatus.hunger == 2 and F.stats.famDayFix == 1, "friend: later in the same day nothing is written by this rule")
day = 370; F.on.families = true; fam.familyHome = nil; hostSays("1:0:0:0:1:1:0:0:other")
fam.ConsumptionStatus.hunger = 2; famDayChange(S, T)
check(fam.ConsumptionStatus.hunger == 2, "friend: a family whose home is not the host's is left alone")
-- (task 76e) the world module calls F.famDayNow at the start of its tick (it ticks before this module)
fam.familyHome = nil; F.on.families = true; hostSays("1:0:0:0:1:1:0:0:-")
day = 371; fam.ConsumptionStatus.hunger = 2; F.S = S
F.famDayNow(S)
check(fam.ConsumptionStatus.hunger == 1, "friend: F.famDayNow sets the mark back at the day change, for the world module's tick")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_marks failed") end
