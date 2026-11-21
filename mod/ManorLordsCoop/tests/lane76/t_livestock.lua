-- Desk test of a rival town's livestock on a friend (lane 76, coop_facts.lua liveApply). Runs WITHOUT the game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_livestock.lua mod/ManorLordsCoop/Scripts/coop_facts.lua
-- Session l76i: a rival town's new animal stood on a friend 4.8 s and more after the host had it. In exact mode the
-- friend now looks every 0.5 s, waits one more look (0.5 s) and makes every missing animal of a kind in that look.
local T = 500.0
os.clock = function() return T end
local logs, mod = {}, nil
local function live(o) return type(o) == "table" and o.live == true end
Coop = {
  register = function(name, m) if name == "facts" then mod = m end end, stale = function() return false end,
  api = { valid = live, un = function(o) return o end, now = os.clock,
    log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function() end }
}
assert(loadfile(ARG1))()
local F = Coop.facts
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 200 do
    local n, v = debug.getupvalue(fn, i)
    if not n then break end
    if n == name then return v end
  end
  for i = 1, 200 do
    local n, v = debug.getupvalue(fn, i)
    if not n then break end
    if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
  end
end
local liveApply = assert(upvalue(mod.tick, "liveApply"), "liveApply not found")

local nextAddr = 0x30000
local function obj(o) nextAddr = nextAddr + 16; local a = nextAddr; o.live = true; o.GetAddress = function() return a end; return o end
local lord, other = obj({}), obj({})
local units = {}
local function region(tag, owner)
  local r = obj({ ownerPawn = owner, regionUniqueTag = { ToString = function() return tag end } })
  function r:GetTotalLivestockCountOfType(role) local n = 0; for _, u in ipairs(units) do if u.currentRegion == r and u.currentUnitRole == role and not u.dead then n = n + 1 end end; return n end
  function r:getTotalLivestockCount() local n = 0; for _, u in ipairs(units) do if u.currentRegion == r and not u.dead then n = n + 1 end end; return n end
  function r:getSettledRegionCenter() return { X = 1000.0, Y = 2000.0, Z = 0.0 } end   -- (lane 64: a kind with none here is made in its own town)
  return r
end
local function animal(r, role) local u = obj({ currentRegion = r, currentUnitRole = role, dead = false, realPos = { X = 0, Y = 0, Z = 0 }, Tasks = {} }); units[#units + 1] = u; return u end
local zwei, hof = region("zwei", other), region("hof", lord)
local eng = obj({ regions = { hof, zwei }, unitArr = units })
function eng:SpawnLivestock(role, pos, r) return animal(r, role) end
function eng:destroyUnit(u) u.dead = true end
local S = { role = "friend", worlds = 1, stats = {}, p1 = lord, eng = eng }
Coop.world = { rivalTown = function(r) return r == zwei end }
local function setup(exact)
  for i = #units, 1, -1 do units[i] = nil end
  for _ = 1, 3 do animal(zwei, 12) end; animal(hof, 12)
  F.S = S; F.world = 1; F.me = lord.GetAddress(); F.exact = exact; F.on.rivals = true; F.on.livestock = true
  F.host = { b = {}, a = { zwei = { [12] = 3 }, hof = { [12] = 1 } }, m = {} }
  F.made = {}; F.liveSince = {}; F.liveFull = {}; F.liveSeen = {}; F.liveHold = {}; F.holdR = {}; F.stats = F.stats or {}; logs = {}
end
local function count(r) return r:GetTotalLivestockCountOfType(12) end
-- looks every `every` s from the moment the host's word says `n`; returns seconds until this copy has n
local function follow(r, tag, n, every, limit)
  local t0 = T; F.host.a[tag] = { [12] = n }
  for _ = 1, math.floor(limit / every) do
    T = T + every; liveApply(S, T)
    if count(r) == n then return T - t0 end
  end
end

check(F.cfg.exactLiveEvery == 0.5 and F.cfg.rivalLiveSettle == 0.5, "exact mode: a look every 0.5 s, a rival town waits 0.5 s")
setup(true)
local d = follow(zwei, "zwei", 4, F.cfg.exactLiveEvery, 12)
check(d and d <= 1.01, "a rival town's new animal is here " .. tostring(d) .. " s after the host's word (was 4.8 s and more)")
setup(true)
d = follow(zwei, "zwei", 6, F.cfg.exactLiveEvery, 12)
check(d and d <= 1.01 and count(zwei) == 6, "three new animals at once are all made in that look (" .. tostring(d) .. " s), none too many")
setup(true)
d = follow(zwei, "zwei", 12, F.cfg.exactLiveEvery, 12)
check(d and d > 1.01 and d <= 2.6 and count(zwei) == 12, "nine at once: four a look, all here after " .. tostring(d) .. " s, none too many")
-- (lane 64, task 64d2) the player's own town: the making side follows the host in exact mode as a rival town does;
-- with Coop.facts.on.liveFastMake = false it keeps the 25 s wait of before
setup(true)
d = follow(hof, "hof", 2, F.cfg.exactLiveEvery, 20)
check(d and d <= 1.01 and count(hof) == 2 and #F.made == 1, "the player's own town: the host's new animal is here " .. tostring(d) .. " s after the host's word (was 25 s: sitting l64d1, 25.7 s)")
setup(true)
d = follow(hof, "hof", 4, F.cfg.exactLiveEvery, 20)
check(d and d <= 1.01 and count(hof) == 4, "three new animals of the player's town at once: all made in that look (" .. tostring(d) .. " s), none too many")
setup(true); F.on.liveFastMake = false
d = follow(hof, "hof", 2, F.cfg.exactLiveEvery, 20)
check(d == nil, "with the switch off the player's own town keeps its 25 s wait: none made in 20 s, as before")
F.on.liveFastMake = true
setup(false)
d = follow(hof, "hof", 2, F.cfg.liveEvery, 20)
check(d == nil, "outside exact mode the player's town keeps its 25 s wait as well")
-- an order carried to every copy: this copy's own game brings the same animal a moment after the stand-in was made
do
  setup(true)
  local lw = assert(upvalue(mod.tick, "liveWatch"), "liveWatch not found")
  d = follow(hof, "hof", 2, F.cfg.exactLiveEvery, 4); lw(S)
  local own = animal(hof, 12)                                 -- the ordered ox arrives here by this copy's own game
  check(count(hof) == 3, "(this copy's own ordered ox arrives after the stand-in: 3 where the host has 2)")
  lw(S)
  check(count(hof) == 2 and not own.dead and #F.made == 0, "the next tick takes the stand-in out: 2 here, this copy's own ox lives")
  for _ = 1, 40 do T = T + F.cfg.exactLiveEvery; liveApply(S, T); lw(S) end
  check(count(hof) == 2, "and 20 s of looks later the town still has the host's count")
end
-- the losing side of the player's town is not changed: one too many here waits 25 s (the host's E AD / E AG come first)
setup(true); animal(hof, 12)
d = follow(hof, "hof", 1, F.cfg.exactLiveEvery, 20)
check(d == nil and count(hof) == 2, "the host has one fewer in the player's town: nothing is taken here in 20 s, as before")
setup(false)
d = follow(zwei, "zwei", 4, F.cfg.liveEvery, 20)
check(d == nil, "outside exact mode a rival town is not touched, as before")
-- one too many here (the host lost an animal): the long wait stays, so the host's own word of a death comes first
setup(true)
d = follow(zwei, "zwei", 2, F.cfg.exactLiveEvery, 4)
check(d == nil and count(zwei) == 3, "the host has one animal fewer: nothing is taken away in the first 4 s")
d = follow(zwei, "zwei", 2, F.cfg.exactLiveEvery, 3)
check(d ~= nil and count(zwei) == 2, "and one is taken away once the difference has lasted 5 s, as before")
-- (task 76h) ONE OWNER. Sessions l76q, l76s: this step made a rival house's two new animals, then the people module's
-- upgrade brought two more by the game itself: 4 where the host had 2 for 5 s and 10 s.
local liveWatch = assert(upvalue(mod.tick, "liveWatch"), "liveWatch not found")
local function countOf(r, role) return r:GetTotalLivestockCountOfType(role) end
local function looks(n) for _ = 1, n do T = T + F.cfg.exactLiveEvery; liveApply(S, T) end end
setup(true)
F.host.a.zwei = { [12] = 3, [13] = 2 }
looks(2)
check(countOf(zwei, 13) == 2 and #F.made == 2, "the race, this step first: the host's two new goats are made here as stand-ins (" .. countOf(zwei, 13) .. ")")
local g1, g2 = animal(zwei, 13), animal(zwei, 13)          -- the upgrade started here: the game's own two
check(countOf(zwei, 13) == 4, "(the upgrade's own two are here as well: 4, the state of l76q)")
local back = F.liveUpgraded(S, zwei)
check(back == 2 and countOf(zwei, 13) == 2 and not g1.dead and not g2.dead and #F.made == 0, "the people module's call takes the two stand-ins out in the same tick: 2 here, the game's own two live")
looks(30)
check(countOf(zwei, 13) == 2 and countOf(zwei, 12) == 3, "and 15 s of looks later the town still has the host's counts")
setup(true)
F.host.a.zwei = { [12] = 3, [13] = 2 }
animal(zwei, 13); animal(zwei, 13)                           -- the people module first (l76s, upgrade 28)
check(F.liveUpgraded(S, zwei) == 0, "the race, the upgrade first: nothing to take back")
looks(4)
check(countOf(zwei, 13) == 2 and #F.made == 0, "... and nothing is made")
-- another maker without a call (a backyard finished here, an ordered animal arriving): the tick sees the count rise
setup(true)
F.host.a.zwei = { [12] = 3, [9] = 3 }
looks(2); liveWatch(S)
check(countOf(zwei, 9) == 3 and #F.made == 3, "three hens of the host made here as stand-ins")
local hens = { animal(zwei, 9), animal(zwei, 9), animal(zwei, 9) }
check(countOf(zwei, 9) == 6, "(this copy's own game brings its three: 6)")
liveWatch(S)
check(countOf(zwei, 9) == 3 and not hens[1].dead and not hens[2].dead and not hens[3].dead, "the next tick takes the three stand-ins out: 3 here, the game's own live")
-- a stand-in is not taken at once when the HOST loses an animal (no rise here): the wait of 5 s stays
setup(true)
F.host.a.zwei = { [12] = 4 }
looks(2); liveWatch(S)
check(countOf(zwei, 12) == 4 and #F.made == 1, "one stand-in of kind 12")
F.host.a.zwei = { [12] = 3 }
liveWatch(S); looks(4); liveWatch(S)
check(countOf(zwei, 12) == 4, "the host has one fewer and nothing rose here: nothing is taken in 2 s (the host's word of a death comes first)")
looks(8)
check(countOf(zwei, 12) == 3, "and the wait of 5 s takes one, as before")
-- an animal of the game's own of ANOTHER kind arrives: no stand-in of that kind, nothing taken
setup(true)
F.host.a.zwei = { [12] = 4 }
looks(2); liveWatch(S)
animal(zwei, 13); liveWatch(S)
check(countOf(zwei, 12) == 4 and countOf(zwei, 13) == 1 and #F.made == 1, "a rise of another kind takes no stand-in at once")
-- lane 64: the host's word of an animal's death (E AD) killed one here; the host's count line still says 3
setup(true)
units[1].dead = true; F.liveDied("zwei", 12)
looks(2)
check(countOf(zwei, 12) == 2, "after the host's word of a death no animal is made for 1.5 s while the count line still shows the old count (" .. countOf(zwei, 12) .. ")")
F.host.a.zwei = { [12] = 2 }
looks(6)
check(countOf(zwei, 12) == 2 and #F.made == 0, "the count line follows: nothing made, nothing taken")
setup(true)
units[1].dead = true; F.liveDied("zwei", 12)
looks(5)
check(countOf(zwei, 12) == 3, "a count line that stays above this copy's count is followed again after 1.5 s (the hold is not a stop)")
-- (task 76e round 3; lane 88's session l88e) two houses with three hens each here; on the host one house lost its coop
-- (an=0) and the other kept its three (an=3). The hens that go are the first house's, never the second's.
setup(true)
for i = #units, 1, -1 do units[i] = nil end
local function house(k, n)
  local b = obj({ animals = {} })
  for _ = 1, n do b.animals[#b.animals + 1] = animal(zwei, 9) end
  F.idx.list[#F.idx.list + 1] = { b = b, k = k }
  return b
end
F.idx = { list = {}, map = {} }
local lost = house("3@9692,7530", 3)
local kept = house("3@9746,7476", 3)                     -- (made last: the old way took the last free hen, one of these)
F.host.b["3@9746,7476"] = { g = {}, v = { an = 3 } }
F.host.b["3@9692,7530"] = { g = {}, v = { an = 0 } }
F.host.a.zwei = { [9] = 3 }
looks(14)
local function alive(b) local n = 0; for _, u in ipairs(b.animals) do if not u.dead then n = n + 1 end end; return n end
check(alive(kept) == 3 and alive(lost) < 3, "the hens that go are those of the house that lost its coop on the host (kept " .. alive(kept) .. ", lost " .. alive(lost) .. ")")
-- without the host's per-house counts, a hen of a house whose count is not known is taken as before
setup(true)
for i = #units, 1, -1 do units[i] = nil end
F.idx = { list = {}, map = {} }
local only = house("3@9746,7476", 3)
F.host.a.zwei = { [9] = 2 }
looks(14)
check(alive(only) == 2, "no per-house count from the host: one free hen is taken, as before")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_livestock failed") end
