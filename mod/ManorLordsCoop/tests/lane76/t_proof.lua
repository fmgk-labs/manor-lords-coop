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
local function hostRun(proof, perTick, stockEvery)
  S.worlds = S.worlds + 1; S.role = "host"; rows, sent = {}, {}; t = 100
  Coop.world.prepare(S); Coop.world.me = lord.GetAddress(); Coop.world.day = 41
  Coop.world.cfg.proof = proof; Coop.world.cfg.proofMs = perTick and 0 or 4
  Coop.world.cfg.proofStockEvery = stockEvery or 0.25      -- (0.25: the stock pass falls on the ticks the rounds start in)
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
  -- (task 76e) the host's first dated read lay 4 s before: not a reading of the check's start
  if ownProof then mod.onMessage(S, "host", "W", { "1", "99.0", "W", "PROOF", "99.100" }) end
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

-- (task 76f) a stock read between two rounds is kept with its own time: a value the host held for less than a round
hostRun(true)
Pr = Coop.world.wd.proof
h = Pr.hist["bs~" .. key]
local n0 = h.n
store.Inventory[1].amt = 7; t = t + 0.01
assert(Coop.world.proofNote(store) == true, "the note was not taken")
store.Inventory[1].amt = 9
assert(h.n == n0 + 1 and h.t[h.n] == t and tostring(h.v[h.n]):find("27:7", 1, true), "the noted row is not in the kept reads: " .. tostring(h.v[h.n]))
for i = 1, 8 do t = t + 0.05; check.tick(S) end
local seen7, ordered = false, true
for i = h.i, h.n do if tostring(h.v[i]):find("27:7", 1, true) then seen7 = true end; if i > h.i and h.t[i] < h.t[i - 1] then ordered = false end end
assert(seen7 and ordered, "the noted value is lost or the reads are out of order")
print("PASS a stock value the host held between two rounds (27:7) is in its kept reads, dated, in order")

-- (task 76g) the stock pass: with a round that takes over a second (one step a tick, a tick every 0.15 s) the stock
-- rows are still read every 0.3 s or less, and with the pass off they are not
local function slowRun(every)
  S.worlds = S.worlds + 1; S.role = "host"; rows, sent = {}, {}; t = 200
  Coop.world.prepare(S); Coop.world.me = lord.GetAddress(); Coop.world.day = 41
  Coop.world.cfg.proof = true; Coop.world.cfg.proofMs = 0; Coop.world.cfg.proofStockEvery = every
  S.eng.buildingArr = { store, cleared, hut }
  for i = 1, 60 do t = 200 + i * 0.15; check.tick(S) end
  local P2 = Coop.world.wd.proof; local worst = 0
  for _, name in ipairs({ "bs~" .. key, "S", "rw~hof" }) do
    local hh = assert(P2.hist[name], "no kept reads of " .. name)
    for i = hh.i + 1, hh.n do if hh.t[i] - hh.t[i - 1] > worst then worst = hh.t[i] - hh.t[i - 1] end end
  end
  return worst, P2.stat.maxCycle or 0
end
local worstOn, roundOn = slowRun(0.2)
local worstOff, roundOff = slowRun(0)
assert(roundOn > 0.6 and worstOn <= 0.31, "stock rows late with the stock pass: " .. worstOn .. " (round " .. roundOn .. ")")
assert(worstOff > 0.6, "the test's round is not slow: " .. worstOff)
print(string.format("PASS a round of %.2f s: the stock rows are read every %.2f s by the stock pass (without it every %.2f s)", roundOn, worstOn, worstOff))

-- (task 76g) a note goes to an open watch at once, with the note's own time; a pile that is gone is dated at the word
hostRun(true)
local nSent = #sent
store.Inventory[1].amt = 5; t = t + 0.01
assert(Coop.world.proofNote(store) == true, "the note was not taken")
store.Inventory[1].amt = 9
local told = observations(nSent + 1)[ids[1]]
assert(told and #told == 1 and told[1].v == "5" and math.abs(told[1].t - t) < 1e-6, "the note did not reach the open watch")
print("PASS a note of a value the host held for a moment (27:5) goes to the open watch at once, dated")
nSent = #sent; t = t + 0.01
assert(Coop.world.proofGone(key) == true, "the gone note was not taken")
local goneRow = observations(nSent + 1)[ids[1]]
Pr = Coop.world.wd.proof; h = Pr.hist["bs~" .. key]
assert(h.v[h.n] == false and h.t[h.n] == t and goneRow and goneRow[1].v == "absent", "a building told gone is not dated absent")
assert(Coop.world.proofGone(key) == false, "a second gone note was taken")
S.eng.buildingArr = { cleared, hut }
local nGone = h.n
for i = 1, 12 do t = t + 0.05; check.tick(S) end
local goneGap = 0; for i = nGone + 1, h.n do assert(h.v[i] == false, "a gone building came back"); if h.t[i] - h.t[i - 1] > goneGap then goneGap = h.t[i] - h.t[i - 1] end end
assert(h.n - nGone >= 2 and goneGap <= 0.31, "a gone building is not dated absent at every stock pass: " .. (h.n - nGone) .. " reads, gap " .. goneGap)
S.eng.buildingArr = { store, cleared, hut }
print("PASS a building told gone is dated absent in that tick, once, and the open watch is told")
Coop.world.cfg.proof = false
assert(Coop.world.proofNote(store) == false and Coop.world.proofGone(key) == false, "a note was taken with the proof off")
print("PASS with the proof off no note is taken")

-- (task 76h) STALLS: the 0.6 s rule counts only the time outside dated stalls; the 3 s of the bar stay wall time
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 200 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name then return v end end
  for i = 1, 200 do
    local n, v = debug.getupvalue(fn, i); if not n then break end
    if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
  end
end
local classify = assert(upvalue(check.tick, "classify"), "classify not found")
local D = Coop.world.wd
-- a friend's readings every 0.18 s from <at>, with one wait of <wait> s after <hole>; the host's reads every 0.2 s
local function series(at0, hole, wait, value, step, len)
  local list, x = {}, at0
  while x <= at0 + (len or 4.6) do
    list[#list + 1] = { t = x, v = type(value) == "function" and value(x) or value }
    x = x + ((hole and x <= hole and x + step > hole) and wait or step)
  end
  return list
end
local function judge(friend, host) return classify({ at = 500, w = { k = "k", f = "f", friend = friend, host = host, seen = {} } }) end
local hostEven = function() return series(496.9, nil, nil, "7", 0.2, 8) end
D.stalls, D.hostStalls = nil, nil
local ok, past, foreign, stale, unknown = judge(series(500, nil, nil, "7", 0.18), hostEven())
assert(ok and not unknown, "an even series is not proven")
local holed = series(500, 501.5, 0.72, "7", 0.18)
ok, past, foreign, stale, unknown = judge(holed, hostEven())
assert(not ok and unknown, "a wait of 0.72 s between two readings was taken without a dated stall (the control: l76s)")
local a; for i = 2, #holed do if holed[i].t - holed[i - 1].t > 0.7 then a = holed[i - 1].t end end
D.stalls = { { a = a + 0.004, b = a + 0.716 } }                      -- the friend's own ticks: one stall inside the wait
ok, past, foreign, stale, unknown = judge(holed, hostEven())
assert(ok and not unknown and not foreign and not past, "a wait that is one dated stall leaves the reading undecided")
print("PASS a friend's wait of 0.72 s between two readings: undecided without a dated stall, proven with it")
D.stalls = { { a = a + 0.004, b = a + 0.09 } }                       -- a stall that covers only 0.09 s of the wait
ok, past, foreign, stale, unknown = judge(holed, hostEven())
assert(not ok and unknown, "a wait of which 0.63 s lie outside the stall was taken")
D.stalls = { { a = a + 0.004, b = a + 0.716 } }
local wide = series(500, 501.5, 1.4, "7", 0.18)                      -- 1.4 s without a reading, 0.7 s of it a stall
ok, past, foreign, stale, unknown = judge(wide, hostEven())
assert(not ok and unknown, "1.4 s without a reading, half of it a stall, was taken")
print("PASS the time outside the stall still counts: 0.63 s and 0.7 s outside stay undecided")
-- a value the host never had, shown after the stall: still a fault
local odd = series(500, 501.5, 0.72, function(x) return (x > 501.6 and x < 502.6) and "9" or "7" end, 0.18)
ok, past, foreign, stale, unknown = judge(odd, hostEven())
assert(foreign and not unknown, "a value the host never had was hidden by a stall")
print("PASS a value the host never had, shown after a stall, is still counted as one")
-- the host's own wait between two reads: only its dated stall excuses it
local hostHoled = series(496.9, 498.4, 0.68, "7", 0.2, 8)
local late = series(500, nil, nil, function(x) return x < 500.5 and "6" or "7" end, 0.18)   -- the friend shows 6, which no host read has
D.stalls = nil; D.hostStalls = nil
ok, past, foreign, stale, unknown = judge(late, hostHoled)
assert(unknown and not foreign, "a value missing from a host series with a hole was called foreign")
local ha; for i = 2, #hostHoled do if hostHoled[i].t - hostHoled[i - 1].t > 0.6 then ha = hostHoled[i - 1].t end end
D.hostStalls = { { a = ha + 0.002, b = ha + 0.675 } }
ok, past, foreign, stale, unknown = judge(late, hostHoled)
assert(foreign and not unknown, "with the host's stall dated, the value no host read has is not called foreign")
print("PASS the host's wait of 0.68 s: undecided without its dated stall; with it the host's series is whole (a foreign value is named)")
-- the 3 s stay wall time: a value the host last had 3.3 s before is outside, stall or not
local old = function() return series(496.9, nil, nil, function(x) return x < 497.3 and "5" or "7" end, 0.2, 8) end
local behind = series(500, nil, nil, function(x) return x < 500.7 and "5" or "7" end, 0.18)
D.stalls = { { a = 499.0, b = 499.7 } }; D.hostStalls = { { a = 499.0, b = 499.7 } }
ok, past, foreign, stale, unknown = judge(behind, old())
assert((stale or foreign) and not unknown, "a stall stretched the 3 s of the bar")
print("PASS a stall does not stretch the 3 s: a value the host last had 3.3 s before is outside")
-- dating: two ticks of the core that follow each other over 0.25 s apart; the host tells the friends
hostRun(true)
D = Coop.world.wd; S.ticks = 1000
-- (after each check tick the module itself counts its wide ticks in wd.tickN: the stall dating must not use that field)
local function ticks(n, step) for _ = 1, n do t = t + step; S.ticks = S.ticks + 1; check.tick(S); D.tickN = (D.tickN or 0) + 1 end end
ticks(5, 0.05)
local n0 = #sent; ticks(1, 0.66); ticks(3, 0.05)
local told = 0; for i = n0 + 1, #sent do if sent[i]:match("^W STALL ") then told = told + 1 end end
assert(D.stalls and #D.stalls == 1 and math.abs((D.stalls[1].b - D.stalls[1].a) - 0.66) < 1e-6 and told == 1, "a wait of 0.66 s between two ticks is not dated once and told")
t = t + 0.66; S.ticks = S.ticks + 2; check.tick(S)                      -- a tick of the core in between that did not come here
assert(#D.stalls == 1, "a wait with a tick of the core in between was dated as a stall")
ticks(3, 0.2)
assert(#D.stalls == 1, "ticks 0.2 s apart were dated as stalls")
print("PASS a wait of 0.66 s between two following ticks is dated and told to the friends once; not when a tick lay between; not at 0.2 s")
-- the host's word of a stall reaches a friend through the module's own message handler (session l76x: it did not)
S.role = "friend"; Coop.world.wd.hostStalls = nil
local wline = "host 7 W STALL 612.250 612.910 1"
local words = {}; for word in wline:gmatch("%S+") do words[#words + 1] = word end
mod.onMessage(S, "host", "W", words, wline)
local HS = Coop.world.wd.hostStalls
assert(HS and #HS == 1 and HS[1].a == 612.25 and HS[1].b == 612.91, "the host's stall line is not taken by a friend")
print("PASS the host's W STALL line is taken by a friend through the module's message handler")
S.role = "host"
Coop.world.cfg.proof = false

-- (task 76e) THE CHECK'S START: the host tells its first dated read at once and every 10 s; a friend marks a reading
-- taken less than 3 s after it early=1 (sessions l76a, l76b: the first day's sample came before the host's first read)
hostRun(true)
local proofLines = {}
for _, line in ipairs(sent) do local x = line:match("^W PROOF (%S+)$"); if x then proofLines[#proofLines + 1] = tonumber(x) end end
assert(#proofLines == 1 and math.abs(proofLines[1] - 100) < 1e-6, "the host's first dated read is not told once in 8 s: " .. #proofLines)
local firstT = Coop.world.wd.proof.firstT
for i = 1, 50 do t = t + 0.25; check.tick(S) end                   -- 12.5 s more: told again, the same time
local again = 0; for _, line in ipairs(sent) do local x = line:match("^W PROOF (%S+)$"); if x then again = again + 1; assert(tonumber(x) == proofLines[1], "the first read moved") end end
assert(again >= 2 and Coop.world.wd.proof.firstT == firstT, "the host does not tell its first read again")
t = t + 6; check.tick(S)                                               -- the proof did not run for 6 s: a new start
assert(Coop.world.wd.proof.firstT and Coop.world.wd.proof.firstT > firstT + 5, "a proof that stopped for 6 s kept its old first read")
print("PASS the host tells its first dated read at once and every 10 s, and a new one after the proof stopped for 6 s")
local function startRun(proofAt, at0, friendProof)
  S.worlds = S.worlds + 1; S.role = "friend"; rows, sent = {}, {}; t = at0
  Coop.world.prepare(S); Coop.world.me = lord.GetAddress(); Coop.world.cfg.proof = friendProof; Coop.world.cfg.proofMs = 4
  if proofAt then
    local line = "host 7 W PROOF " .. proofAt
    local words = {}; for word in line:gmatch("%S+") do words[#words + 1] = word end
    mod.onMessage(S, "host", "W", words, line)
  end
  check.section("42", "bs", { { k = key, f = "g27", at = at0, h = "0", m = "9" } })
  for i = 1, 40 do t = at0 + i * 0.15; check.tick(S) end
  local field, sum
  for _, r in ipairs(rows) do if r:find("settle%-field 42 bs") then field = r elseif r:find("settle 42 bs sample") then sum = r end end
  return assert(field, "no field line"), sum
end
local f1, s1 = startRun("103.000", 105.9, true)
assert(f1:find(" early=1$") and s1:find(" early=1$"), "a reading 2.9 s after the host's first read is not marked early: " .. f1)
local f2 = startRun("103.000", 106.0, true)
assert(not f2:find("early="), "a reading 3.0 s after the host's first read is marked early")
local f3 = startRun(nil, 106.0, true)
assert(f3:find(" early=1$"), "a reading with no word of the host's first read is not marked early")
local f4 = startRun(nil, 106.0, false)
assert(not f4:find("early="), "with the proof off a reading is marked early")
assert(Coop.world.wd.hostProofAt == nil and table.concat(rows, " | "):find("proof host first read", 1, true) == nil, "a host word appeared from nowhere")
startRun("103.000", 106.0, true)
assert(Coop.world.wd.hostProofAt == 103 and table.concat(rows, " | "):find("proof host first read 103.000", 1, true), "the host's word is not taken through the message handler")
print("PASS a friend marks readings before 3 s of the host's dated reads early=1 (2.9 s: early, 3.0 s: not, no word: early, proof off: never)")
S.role = "host"
Coop.world.cfg.proof = false

-- (task 76e) DENSE PASSES: a building that comes or goes is dated in the tick the list changed, in every row that
-- names it (bs, bl, B), and with the same count (one in, one out) after a town action (W.proofDense)
hostRun(true)
Pr = Coop.world.wd.proof
local hk = "89@300,400"
local function last(name) local hh = Pr.hist[name]; if hh then return hh.t[hh.n], hh.v[hh.n] end end
t = t + 0.05; check.tick(S)                                              -- an ordinary tick: no change
S.eng.buildingArr = { store, cleared, hut }; t = t + 0.05; check.tick(S)
local tb, vb = last("bl~" .. hk); local ts, vs = last("bs~" .. hk)
assert(tb == t and vb and ts == t and vs ~= nil, "a building that came is not dated in the tick the list changed: bl " .. tostring(tb) .. " bs " .. tostring(ts) .. " now " .. t)
for i = 1, 3 do t = t + 0.05; check.tick(S) end
S.eng.buildingArr = { store, cleared }; t = t + 0.05; check.tick(S)
tb, vb = last("bl~" .. hk); ts, vs = last("bs~" .. hk); local tB, vB = last("B~" .. hk)
assert(tb == t and vb == false and ts == t and vs == false and tB == t and vB == false, "a building that went is not dated absent in every row in that tick")
for i = 1, 40 do t = t + 0.05; check.tick(S) end                         -- 2 s on: the dense time is over
local other = building(18, 500, 600, { [16] = 1 })
S.eng.buildingArr = { store, other }; t = t + 0.05; check.tick(S)          -- the same count: no dense pass by itself
local tc = last("bl~18@500,600")
assert(tc == nil or tc < t, "the test's swap was dated without a town action (the count did not change)")
for i = 1, 10 do t = t + 0.05; check.tick(S) end
local third = building(19, 700, 800, { [16] = 1 })
assert(Coop.world.proofDense(1.5) == true, "the dense call was refused")
S.eng.buildingArr = { store, third }; t = t + 0.02; check.tick(S)
tc = last("bl~19@700,800"); local to, vo = last("bs~18@500,600")
assert(tc == t and to == t and vo == false, "after a town action a swap of one building for another is not dated in that tick")
assert(Coop.world.proofStat():find("dense ticks", 1, true), "the dense count is not in the status")
print("PASS a building that comes or goes is dated in that tick in its bs, bl and B rows; a swap of the same count after a town action too")
S.eng.buildingArr = { store, cleared, hut }
Coop.world.cfg.proof = false

-- (task 76e) THE STOCK AS SENT: the host sends from the native table of a frame's start; that row is dated at the
-- table's moment too, in order, with its counters and record count (session l76y, day 402)
hostRun(true)
Pr = Coop.world.wd.proof
local hs = Pr.hist["bs~" .. key]
store.Inventory[1].amt = 9; store.numStoredGeneric = 13
local nOld = hs.n; local tLast = hs.t[hs.n]
Coop.snap = { tabT = os.clock() - 0.04, building = function(a) if a == store.GetAddress() then return { inv = { [27] = 6, [16] = 4 }, invN = 2, nsg = 10, nsl = 0, nsp = 0 } end end }
t = t + 0.05; Coop.snap.tabT = t - 0.04
local nSent = #sent
assert(Coop.world.proofNote(store, true) == true, "the note was not taken")
local rowAt
for i = hs.i, hs.n do if hs.v[i] == "10|0|0|2|16:4,27:6" then rowAt = hs.t[i] end; if i > hs.i then assert(hs.t[i] >= hs.t[i - 1], "the kept reads are out of order") end end
assert(rowAt and math.abs(rowAt - (t - 0.04)) < 1e-6, "the table's row is not dated at the table's moment: " .. tostring(rowAt))
assert(hs.v[hs.n] ~= "10|0|0|2|16:4,27:6" and hs.t[hs.n] == t, "the live read is not the last one")
local toldSnap = false
for i = nSent + 1, #sent do if sent[i]:find("W OBS " .. string.format("%.3f", t - 0.04), 1, true) then toldSnap = true end end
assert(toldSnap or not Coop.world.wd.watches[ids[1]], "the open watch is not told of the table's row")
local nNow = hs.n
assert(Coop.world.proofNote(store, false) == true and hs.n == nNow + 1, "a note without the table took a table row")
Coop.snap = nil
print("PASS the stock as sent from the native table is dated at the table's moment, in order, as a row of the live form")
Coop.world.cfg.proof = false
