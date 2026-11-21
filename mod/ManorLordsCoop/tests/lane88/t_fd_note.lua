-- Desk test of lane 88's field note (coop_world.lua W.proofNote(b, "fd"); called by coop_x_fields.lua at the host's
-- poll that sent a field's change, and on a friend after it wrote the host's change).
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane88/t_fd_note.lua mod/ManorLordsCoop/Scripts/coop_world.lua
-- The case of the lead's run r27m83 (day 371, 3@9318,-8330): during a harvest the host's sown count went 196 -> 194
-- -> 192 inside one round of the host's reads (every 0.25 s); the friend showed 194 (the host's poll had sent it) and
-- the check said "the host never had it". With the note the host's kept reads hold 194 at its own moment, and the
-- friend's 194 is judged an ordinary delay; without it the same reading is a value the host never had.
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
for i = 1, 60 do local name, v = debug.getupvalue(mod.onMessage, i); if name == "Check" then check = v; break end end
assert(check and check.proofTick, "the proof is not in the module")
local pass = 0
local function ok(c, what) assert(c, "FAIL " .. what); pass = pass + 1; print("PASS " .. what) end

local nextAddr = 0x20000
local function obj(o) nextAddr = nextAddr + 16; local a = nextAddr; o.live = true; o.GetAddress = function() return a end; return o end
local lord = obj({ silver = 100, influence = 5, kingsFavour = 0 })
local garden = obj({ type = 3, ownerPawn = lord, lv = 1, onFire = false, sleep = false, Inventory = {}, numStoredGeneric = 0, numStoredLarge = 0,
  numStoredPantry = 0, animals = {}, animalsOnPasture = {}, oxen = {}, activeOxen = 0, Carts = {},
  bRotateCrops = true, fieldOperationMode = 3, forceHarvest = true, field_ploughingPerc = 0.9, field_sowingPerc = 0.9, field_growingPerc = 0,
  field_harvestingPerc = 0.3, field_numReadyToHarvest = 196, field_numUnplowed = 180, field_numSown = 196, yield = 9, plannedHarvest_PredictedYield = 0,
  plannedHarvest_DaysLeft = 0, cropType2 = 0, cropType3 = 0, fieldWorkersNeeded = 0,
  K2_GetActorLocation = function() return { X = 93180, Y = -83300, Z = 0 } end, GetType = function(self) return self.type end,
  IsConstructed = function() return true end, getNumActiveWorkerFamilies = function() return 1 end, getNumResidingFamilies = function() return 1 end })
local bare = obj({ type = 89, ownerPawn = lord, lv = 1, onFire = false, sleep = false, Inventory = {}, numStoredGeneric = 0, numStoredLarge = 0,
  numStoredPantry = 0, animals = {}, animalsOnPasture = {}, oxen = {}, activeOxen = 0, Carts = {},
  bRotateCrops = true, fieldOperationMode = 0, forceHarvest = false, field_ploughingPerc = 0, field_sowingPerc = 0, field_growingPerc = 0,
  field_harvestingPerc = 0, field_numReadyToHarvest = 0, field_numUnplowed = 0, field_numSown = 0, yield = 0, plannedHarvest_PredictedYield = 0,
  K2_GetActorLocation = function() return { X = 3000, Y = 4000, Z = 0 } end, GetType = function(self) return self.type end,
  IsConstructed = function() return true end, getNumActiveWorkerFamilies = function() return 1 end, getNumResidingFamilies = function() return 0 end })
local region = obj({ ownerPawn = lord, regionUniqueTag = { ToString = function() return "hof" end }, workerFamilies = {},
  regionalWealth = 253, Approval = 50, publicOrder = 60, settlementLevel = 1, residents = {}, corpses = {}, squadsPresent = {},
  getNumHomelessFamilies = function() return 0 end, getNumTotalPopulation = function() return 2 end, getNumFamiliesOfLv = function(_, n) return n == 1 and 1 or 0 end,
  getStockOfGood = function() return 0 end })
local weather = obj({ Season = 1, month = 3, rainMeter = 0, isDrought = false, isWinter = false, daysWithoutRainVariation = 0 })
local S = { role = "host", worlds = 0, stats = {}, p1 = lord,
  eng = obj({ TemporalComponent = weather, freeMerchants = {}, livestockMerchants = {}, tradeableGoods = { 16 },
    regions = { region }, buildingArr = { garden, bare } }) }
local key = "3@9318,-8330"
local id = "fd~" .. key .. "~field_numSown"

local function observations(from)
  local by = {}
  for i = from or 1, #sent do
    local stamp, items = sent[i]:match("^W OBS (%S+) (.+)$")
    if stamp then for k, v in items:gmatch("([^;=]+)=([^;]+)") do by[k] = by[k] or {}; by[k][#by[k] + 1] = { t = tonumber(stamp), v = v } end end
  end
  for _, list in pairs(by) do table.sort(list, function(a, b) return a.t < b.t end) end
  return by
end

-- the host: rounds every 0.25 s from 100.0 and the fields module's note of every field every 0.25 s; at 103.02 the poll
-- sends 194 (noted when withNote: the note at the poll), at 103.06 the count is
-- 192 before the next round; the friend names the field at 105.0
local function hostRun(withNote)
  S.worlds = S.worlds + 1; S.role = "host"; rows, sent = {}, {}; t = 100
  garden.field_numSown = 196
  Coop.world.prepare(S); Coop.world.me = lord.GetAddress(); Coop.world.day = 371
  Coop.world.cfg.proof = true; Coop.world.cfg.proofMs = 4; Coop.world.cfg.proofStockEvery = 0.2
  local asked, noted = false, nil
  for i = 0, 140 do
    t = 100 + i * 0.05
    if t >= 103.0 and t < 103.04 then
      t = 103.02; garden.field_numSown = 194
      if withNote then noted = Coop.world.proofNote(garden, nil, "fd") end
      t = 103.06; garden.field_numSown = 192
    end
    if not asked and t >= 105.0 then asked = true; mod.onMessage(S, "friend1", "W", { "1", tostring(t), "W", "WATCH", "371", id }) end
    if i % 5 == 0 then Coop.world.proofNote(garden, nil, "fd") end   -- the fields module notes every field every 0.25 s (fd is not read by the rounds)
    check.tick(S)
  end
  return noted
end

ok(hostRun(true) == true, "the host takes a note of the field row (section fd) between two rounds")
do local inRounds = false; for _, s in ipairs(Coop.world.wd.proof.secs.building) do if s == "fd" then inRounds = true end end
  ok(not inRounds and Coop.world.wd.proof.secOn.fd == true, "fd is kept by notes only: the rounds do not read it (cfg.proofNoted)") end
local reads = observations()[id]
local had194 = false
for _, r in ipairs(reads or {}) do if r.v == "194" and math.abs(r.t - 103.02) < 1e-6 then had194 = true end end
ok(had194, "the noted value 194 is in the host's kept reads with its own time, and is sent to the friend's watch")
local Pr = Coop.world.wd.proof
local h = Pr.hist["fd~" .. key]
local ordered = true; for i = h.i + 1, h.n do if h.t[i] < h.t[i - 1] then ordered = false end end
ok(ordered, "the kept reads stay in time order with the note among them")
ok(Pr.hist["fd~89@300,400"] == nil, "a building that is no field (the default fd row) keeps no fd row")
ok(Coop.world.proofNote(bare, nil, "fd") == true and Pr.hist["fd~89@300,400"] and Pr.hist["fd~89@300,400"].v[Pr.hist["fd~89@300,400"].n] == false,
  "a note of a building with the default fd row dates it as not there")

-- the friend's reading of 194 at 103.9 (its 0.9 s delay) judged against the host's reads, with and without the note
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 200 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name then return v end end
  for i = 1, 200 do local n, v = debug.getupvalue(fn, i); if not n then break end; if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end end
end
local classify = assert(upvalue(check.tick, "classify"), "classify not found")
local function friendSeries()
  local list = {}
  for x = 103.9, 108.0, 0.18 do list[#list + 1] = { t = x, v = (x < 104.1) and "194" or "192" } end
  return list
end
local function judge(host)
  local hs = {}; for _, r in ipairs(host) do hs[#hs + 1] = { t = r.t, v = r.v } end
  Coop.world.wd.stalls, Coop.world.wd.hostStalls = nil, nil
  return classify({ at = 103.9, w = { k = key, f = "field_numSown", friend = friendSeries(), host = hs, seen = {} } })
end
local okA, pastA, foreignA = judge(reads)
ok(not foreignA and not pastA, "with the note the friend's 194 is an ordinary delay (the host had it 0.9 s before)")
hostRun(false)
local readsB = observations()[id]
local okB, pastB, foreignB = judge(readsB)
ok(foreignB == true, "without the note the same reading is a value the host never had (the fault the lead's runs counted)")
Coop.world.cfg.proof = false
ok(Coop.world.proofNote(garden, nil, "fd") == false, "with the proof off no note is taken (players' builds)")
print(string.format("ALL %d PASS", pass))
