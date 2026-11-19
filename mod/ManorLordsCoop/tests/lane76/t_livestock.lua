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
  F.made = {}; F.liveSince = {}; F.liveFull = {}; F.holdR = {}; F.stats = F.stats or {}; logs = {}
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
setup(true)
d = follow(hof, "hof", 2, F.cfg.exactLiveEvery, 20)
check(d == nil, "the player's own town keeps its 25 s wait (an ordered animal arrives on each copy by itself): none made in 20 s")
setup(false)
d = follow(zwei, "zwei", 4, F.cfg.liveEvery, 20)
check(d == nil, "outside exact mode a rival town is not touched, as before")
-- one too many here (the host lost an animal): the long wait stays, so the host's own word of a death comes first
setup(true)
d = follow(zwei, "zwei", 2, F.cfg.exactLiveEvery, 4)
check(d == nil and count(zwei) == 3, "the host has one animal fewer: nothing is taken away in the first 4 s")
d = follow(zwei, "zwei", 2, F.cfg.exactLiveEvery, 3)
check(d ~= nil and count(zwei) == 2, "and one is taken away once the difference has lasted 5 s, as before")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_livestock failed") end
