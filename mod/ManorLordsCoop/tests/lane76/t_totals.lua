-- Desk test of the region totals' fast path (lane 76, task 76e round 3; coop_world.lua W.hostFastTotals and the
-- friend's write in W.apply). The harness is t_proof.lua's.
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_totals.lua mod/ManorLordsCoop/Scripts/coop_world.lua
local t, rows, sent, mod = 0, {}, {}, nil
os.clock = function() return t end
math.type = math.type or function(n) return n == math.floor(n) and "integer" or "float" end
local function live(o) return type(o) == "table" and o.live == true end
Coop = {
  register = function(_, m) mod = m end, stale = function() return false end,
  api = { valid = live, un = function(o) return o end, now = os.clock, btype = function(b) return b.type end,
    log = function(fmt, ...) rows[#rows + 1] = string.format(fmt, ...) end,
    send = function(line) sent[#sent + 1] = line end }
}
assert(loadfile(ARG1))()
local check
for i = 1, 60 do
  local name, v = debug.getupvalue(mod.onMessage, i)
  if name == "Check" then check = v; break end
end
assert(check and check.proofTick and check.proofServe, "the proof is not in the module")

local nextAddr = 0x20000
local function obj(o) nextAddr = nextAddr + 16; local a = nextAddr; o.live = true; o.GetAddress = function() return a end; return o end
local lord = obj({ silver = 100, influence = 5, kingsFavour = 0 })
local function building(typ, x, y, goods)
  local inv = {}
  for g, a in pairs(goods or {}) do inv[#inv + 1] = { Type = g, amt = a } end
  return obj({ type = typ, ownerPawn = lord, lv = 1, onFire = false, sleep = false, Inventory = inv, workers = 1,
    numStoredGeneric = 0, numStoredLarge = 0, numStoredPantry = 0, animals = {}, animalsOnPasture = {}, oxen = {}, activeOxen = 0, Carts = {},
    K2_GetActorLocation = function() return { X = x * 10, Y = y * 10, Z = 0 } end, GetType = function(self) return self.type end,
    IsConstructed = function() return true end, getNumActiveWorkerFamilies = function(self) return self.workers end,
    getNumResidingFamilies = function() return 0 end })
end
local store = building(6, 100, 200, { [27] = 0, [16] = 4 })
local hut = building(89, 300, 400, { [16] = 2 })
local cleared = building(0, 0, 0, {})                       -- an actor the game has cleared: type 0 at 0,0
local family = { familyHome = hut, familyMembers = { 1, 2 }, ConsumptionStatus = { hunger = 0, cold = 0, ale = 0, garments = 0, footwear = 0, sickness = 0, injured = 0 } }
local stock = { [16] = 6, [27] = 0 }
local region = obj({ ownerPawn = lord, regionUniqueTag = { ToString = function() return "hof" end }, workerFamilies = { family },
  regionalWealth = 253, Approval = 50, publicOrder = 60, settlementLevel = 1, residents = {}, corpses = {}, squadsPresent = {},
  getNumHomelessFamilies = function() return 0 end, getNumTotalPopulation = function() return 2 end, getNumFamiliesOfLv = function(_, n) return n == 1 and 1 or 0 end,
  getStockOfGood = function(_, g) return stock[g] or 0 end })
local weather = obj({ Season = 1, month = 3, rainMeter = 0, isDrought = false, isWinter = false, daysWithoutRainVariation = 0 })
local S = { role = "host", worlds = 0, stats = {}, p1 = lord,
  eng = obj({ TemporalComponent = weather, freeMerchants = {}, livestockMerchants = {}, tradeableGoods = { 16, 27 },
    regions = { region }, buildingArr = { store, cleared, hut } }) }


local pass, fail = 0, 0
local function chk(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
S.role = "host"; t = 100
Coop.world.prepare(S); Coop.world.me = lord.GetAddress()
local W = Coop.world
local k = W.rkey(region)
W.sent.reg[k] = { [30] = 4, [16] = 6 }
local changed
Coop.snap = { tabs = { [1] = { by = { [region.GetAddress()] = { tot = { [30] = 5 }, totN = 1 } } } },
  takeChangedRegions = function() local c = changed; changed = nil; return c end }
changed = { [region.GetAddress()] = true }
W.hostFastTotals(S)
local P = W.pend and W.pend[k]
chk(P and P[30] and P[30].v == 5, "host: a changed total named by the native region table enters the wait in that tick")
chk(P and P[16] and P[16].v == 0, "host: a good the table no longer holds enters the wait as 0")
W.pend = {}; W.hostFastTotals(S)
chk(next(W.pend) == nil, "host: no region named, nothing looked at")
W.sent.reg[k] = nil; changed = { [region.GetAddress()] = true }; W.hostFastTotals(S)
chk(next(W.pend) == nil, "host: a region the pass never sent is left to the pass")
-- friend: the host's line is written at once with the native TOTALS switch
S.role = "friend"; Coop.world.prepare(S); Coop.world.me = lord.GetAddress()
local calls = {}
Coop.facts = { exact = true }
Coop.patch = { tOn = true, tGen = 1, totalsSet = function(r, g, full, res) calls[#calls + 1] = { r = r, g = g, full = full, res = res }; return true end }
W.regionByKey = function(key) if key == k then return region end end
mod.onMessage(S, "host", "W", { "1", tostring(t), "W", "R", k, "h", "30=7,r30=6" })
chk(#calls == 2 and calls[1].g[30] == 7 and not calls[1].res and calls[2].res and calls[2].g[30] == 6, "friend: the host's totals and reserved list are written in the tick the line came (" .. #calls .. " writes)")
calls = {}; W.cfg.fastTotals = false
mod.onMessage(S, "host", "W", { "1", tostring(t), "W", "R", k, "h", "30=8" })
chk(#calls == 0, "friend: switch fastTotals off: left to the region job"); W.cfg.fastTotals = nil
calls = {}; Coop.facts.exact = false
mod.onMessage(S, "host", "W", { "1", tostring(t), "W", "R", k, "h", "30=9" })
chk(#calls == 0, "friend: not in exact mode: nothing written at once")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_totals failed") end
