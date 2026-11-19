-- Desk test of the timing proof (lane 76, coop_world.lua Check.proofTick / Check.proofServe).
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_proof.lua mod/ManorLordsCoop/Scripts/coop_world.lua
-- A made-up town on the host: the host keeps dated reads of every row; when a friend names a field, the reads of
-- BEFORE the request go out as W OBS lines; a friend's first reading is then judged (without them it is "unverified").
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

-- every W OBS line the host sent, as id -> list of { t, v } in sending order
local function observations(from)
  local by = {}
  for i = from or 1, #sent do
    local stamp, items = sent[i]:match("^W OBS (%S+) (.+)$")
    if stamp then for id, v in items:gmatch("([^;=]+)=([^;]+)") do by[id] = by[id] or {}; by[id][#by[id] + 1] = { t = tonumber(stamp), v = v } end end
  end
  for _, list in pairs(by) do table.sort(list, function(a, b) return a.t < b.t end) end
  return by
end
local function at(list, time) local v; for _, r in ipairs(list) do if r.t <= time then v = r.v end end; return v end
local function maxGap(list, from, to)
  local gap, prev = 0, nil
  for _, r in ipairs(list) do if r.t >= from and r.t <= to then if prev and r.t - prev > gap then gap = r.t - prev end; prev = r.t end end
  return gap
end
local key = "6@100,200"
local ids = { "bs~" .. key .. "~g27", "R~hof:1~value", "B~" .. key .. "~workers", "bs~9@1,1~numStoredGeneric", "an~" .. key .. "~Carts",
  "F~hof:3~value", "S~hof:27~value", "bs~89@300,400~numStoredGeneric", "B~89@300,400~present", "N~1~value" }
local function ask(tag) mod.onMessage(S, "friend1", "W", { "1", tostring(t), "W", "WATCH", tag, table.concat(ids, ";") }) end

-- the host's session: stock 0 -> 9 at 103.0, wealth 253 -> 259 at 103.5, the hut demolished at 104.0, the friend asks at 105.0
local function hostRun(proof, perTick)
  S.worlds = S.worlds + 1; S.role = "host"; rows, sent = {}, {}; t = 100
  Coop.world.prepare(S); Coop.world.me = lord.GetAddress(); Coop.world.day = 41
  Coop.world.cfg.proof = proof; Coop.world.cfg.proofMs = perTick and 0 or 4
  store.Inventory[1], store.Inventory[2] = { Type = 27, amt = 0 }, { Type = 16, amt = 4 }
  stock[27] = 0; region.regionalWealth = 253; S.eng.buildingArr = { store, cleared, hut }
  local asked = false
  for i = 0, 160 do
    t = 100 + i * 0.05
    if t >= 103.0 then for _, x in ipairs(store.Inventory) do if x.Type == 27 then x.amt = 9 end end; stock[27] = 9 end
    if t >= 103.5 then region.regionalWealth = 259 end
    if t >= 104.0 then S.eng.buildingArr = { store, cleared } end
    if not asked and t >= 105.0 then asked = true; ask("42") end
    check.tick(S)
  end
end

hostRun(true)
local by = observations()
local g27 = assert(by[ids[1]], "no kept reads of the stock field were sent")
assert(g27[1].t <= 102.0, "the kept reads do not reach 3 s before the request: first " .. g27[1].t)
assert(at(g27, 102.9) == "0" and at(g27, 103.4) == "9", "the stock change is not dated: " .. tostring(at(g27, 102.9)) .. " " .. tostring(at(g27, 103.4)))
assert(maxGap(g27, 101, 108) <= 0.45, "reads of one row are too far apart: " .. maxGap(g27, 101, 108))
local wealth = assert(by[ids[2]])
assert(at(wealth, 103.4) == "253" and at(wealth, 103.9) == "259", "the wealth change is not dated")
assert(at(by[ids[3]], 104) == "1", "a fingerprint building field is missing")
assert(by[ids[4]] and at(by[ids[4]], 104) == "absent", "a building the host never had must be dated as absent")
assert(at(by[ids[5]], 104) == "0", "a row left out as all zero must read as its zero")
assert(at(by[ids[6]], 104) == "2" and at(by[ids[7]], 102) == "0" and at(by[ids[7]], 104) == "9", "family or stock words are wrong")
assert(at(by[ids[8]], 103.9) == "0" and at(by[ids[8]], 104.6) == "absent", "a demolished building must become absent")
assert(at(by[ids[9]], 103.9) == "1" and at(by[ids[9]], 104.6) == "0", "a demolished building's fingerprint row must go")
assert(at(by[ids[10]], 104) == "100", "the lord's silver is missing")
for id in pairs(by) do assert(not id:find("~0@0,0~", 1, true), "a cleared actor was recorded") end
for name in pairs(Coop.world.wd.proof.hist) do assert(not name:find("0@0,0", 1, true), "a cleared actor was kept: " .. name) end
print("PASS the host sends dated reads of before the request: stock, wealth, families, absent and demolished rows")

-- a second request for the same fields sends no read twice
local n0 = #sent; local before = {}
for id, list in pairs(by) do before[id] = list[#list].t end
ask("43"); check.tick(S)
for id, list in pairs(observations(n0 + 1)) do for _, r in ipairs(list) do assert(r.t > 105.0, "a kept read was sent twice: " .. id .. " " .. r.t) end end
print("PASS a repeated request sends only reads the friend does not have")
local hostLines = {}; for _, line in ipairs(sent) do if line:find("^W OBS ") then hostLines[#hostLines + 1] = line end end
local stat = Coop.world.proofStat()
assert(stat:find("gaps over 0.55 s 0", 1, true) and stat:find("read errors 0", 1, true), stat)
print("PASS " .. stat)

-- one step a tick (the tick's budget used up at once): a round takes several ticks and still finishes
hostRun(true, true)
by = observations()
assert(by[ids[1]] and at(by[ids[1]], 103.6) == "9" and maxGap(by[ids[1]], 101, 108) <= 0.55, "a sliced round lost reads")
assert(Coop.world.wd.proof.stat.cycles > 10, "sliced rounds do not finish")
print("PASS a round cut into one step a tick keeps every row's reads under 0.55 s apart")

-- proof off: nothing of before the request can be sent (the old behaviour)
hostRun(false)
local old = observations()
assert(not Coop.world.wd.proof, "the proof ran while switched off")
for _, r in ipairs(old[ids[1]] or {}) do assert(r.t >= 105.0, "an old read without the proof") end
local oldLines = {}; for _, line in ipairs(sent) do if line:find("^W OBS ") then oldLines[#oldLines + 1] = line end end
print("PASS with the proof off the host has no reads of before the request")

-- the friend: it read stock 9 at 103.1 where the host's day sample said 0. With the host's kept reads the reading is
-- judged (the host had 9 from 103.0 on: ordinary delay); with only the reads from the request on it cannot be.
-- late: the day's comparison is made 0.9 s after the friend's sample read the row (as in the game); ownProof: the
-- friend keeps its own dated reads meanwhile
local function friendRun(lines, want, desc, late, ownProof)
  S.worlds = S.worlds + 1; S.role = "friend"; rows, sent = {}, {}; t = 103.1
  Coop.world.prepare(S); Coop.world.me = lord.GetAddress(); Coop.world.cfg.proof = ownProof or false; Coop.world.cfg.proofMs = 4
  for _, x in ipairs(store.Inventory) do if x.Type == 27 then x.amt = 9 end end
  S.eng.buildingArr = { store, cleared }
  local at = t
  if late then for i = -20, 18 do t = 103.1 + i * 0.05; check.tick(S) end end
  check.section("42", "bs", { { k = key, f = "g27", at = at, h = "0", m = "9" } })
  for _, line in ipairs(lines) do
    local stamp, items = line:match("^W OBS (%S+) (.+)$")
    mod.onMessage(S, "host", "W", { "1", stamp, "W", "OBS", stamp, items })
  end
  local from = t
  for i = 1, 40 do t = from + i * 0.15; check.tick(S) end
  local result = table.concat(rows, "\n")
  assert(result:find(want, 1, true), desc .. "\n" .. result)
  print("PASS " .. desc)
end
friendRun(hostLines, "settle 42 bs sample=1 settled=1 past3=0 foreign=0 stale=0 unverified=0", "with the host's kept reads the friend's first reading is proven inside 3 s")
friendRun(oldLines, "unverified=1", "without them the same reading cannot be timed")
friendRun(hostLines, "settle 42 bs sample=1 settled=1 past3=0 foreign=0 stale=0 unverified=0", "a comparison made 0.9 s after the sample: the friend's own kept reads fill its series", true, true)
friendRun(hostLines, "unverified=1", "without the friend's own kept reads the 0.9 s hole leaves the field unverified", true, false)

-- a round that breaks off (a read fails outside every guard) must not date the rows it did not reach as "not there"
hostRun(true)
local Pr = Coop.world.wd.proof
local reads0 = #Pr.hist["bs~" .. key].t
S.eng.regions = nil                                           -- the next round fails in its first step
for i = 1, 20 do t = t + 0.05; check.tick(S) end
S.eng.regions = { region }
local h = Pr.hist["bs~" .. key]
local absent = 0; for i = h.i, h.n do if h.v[i] == false then absent = absent + 1 end end
assert(absent == 0 and (Pr.stat.errs or 0) > 0, "a broken round dated a row as absent (" .. absent .. ") or was not counted")
print("PASS a round that breaks off leaves a hole, not an absent row (" .. tostring(Pr.stat.errs) .. " broken rounds counted)")
