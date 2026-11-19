-- Manor Lords Co-op: the numbers a player reads on his own buildings (plug-in module "facts", message kind "F",
-- host -> friends only). Load after coop.lua, coop_town.lua and coop_world.lua. Re-loadable: state lives in Coop.facts.
--
-- Why. Each copy runs its own villagers, so what they make, carry and use differs between copies within seconds. The
-- world module already keeps equal: each region's total of every tradeable good, the stock of storage buildings and
-- of building sites, the treasury. This module adds what was each copy's own (lane 0 notes, session 21: 45 values of
-- the player's buildings differ after 2 minutes at speed 4; study docs/design/host_run_villagers_study.txt 6, 7b, 8):
--   1. the stock of every finished building that is not a storage building (workshops, houses, stalls, trading post);
--   2. simple values of houses a player reads (fuel day, refuelled, water, market supply days ...): a table of rules
--      over reflected properties, written by name;
--   3. the cold and sickness marks of families;
--   4. livestock per region and kind.
-- The friend's own villagers keep working, so every value drifts again: the writes never stop. Evidence for every
-- number in this file: research/2026-11-10-game-probe/lanes/lane_s21_10/report.txt.
--
-- THE RULE OF EVERY FACT (one row per property in RULES; stock, livestock and family marks have the same parts in cfg)
--   owner   the host. A friend never sends a fact.
--   sent    when it changed, at most once per "floor" seconds; every building complete again every cfg.keyEvery s,
--           after a world was loaded and when a join or resync ends (a keyframe), so a friend that joined late or
--           reloaded catches up.
--   margin  a difference up to the margin is left alone while it is younger than "settle" seconds: most small
--           differences are the same work done a moment earlier or later on the two copies and close by themselves;
--           correcting them at once is what makes a number flicker. A larger difference is corrected at once; a
--           small one that lasts is corrected exactly. While the game is paused everything is corrected exactly.
--   hold    for cfg.hold seconds after the local player acted on a building (any town action this copy sent that
--           names it), nothing of that building is written: his own change is on its way to the host, and the host's
--           older values must not undo it. The host's values that arrive meanwhile are kept and used afterwards.
--
-- STOCK, AND THE WORLD MODULE'S TWO STOCK RULES (measured, session 1 of this lane)
--   Region:getStockOfGood(g) is the sum of the inventories of ALL the lord's buildings in the region (storage, others,
--   sites) plus what his people carry. The world module makes that total equal to the host's (grant / consume) and
--   makes sites exact. Its grant can land in any building (measured: planks and timber went into a stable), its
--   consume takes from the building it names. So this module must never change a region's total, or the two rules
--   would chase each other (lane 5 measured such a chase between the region rule and the storage rule: 9,566 units
--   added and 8,479 removed in 12 minutes). Therefore, for a good the region rule covers (eng.tradeableGoods):
--     a building that holds too many gives them to a storage building of its region; a building that is short takes
--     them from the storage buildings of its region; what storage cannot give is left for a later pass (the region
--     rule grants what the region lacks). Goods are only MOVED, with the game's own SMBuildingMaster:addToInventory
--     (+n on one building, -n on the other). Measured on 16 building types: it makes and removes the list record, never
--     goes below nothing, works while paused, and the counts numStoredGeneric / Large / Pantry follow in the same call.
--   A good the region rule does not cover (timber, water) is made exact with addToInventory alone, in every finished
--   building, storage included (for storage the host's amounts are read from the world module's own store).
--   Consequence: with the totals equal and every other building equal, a storage building differs from the host's
--   only by what is in hands at that moment on the two copies.
--
-- EXACT MODE (lane 14: research/2026-11-10-game-probe/lanes/lane_s21_14/report.txt)
--   With the native switch GOODS (coop_patch) a friend's copy no longer changes a building's stock by itself: the
--   game's own changes are put back in the same call, and only SMBuildingMaster:addToInventory (the mod's write)
--   stays. Then margin, settle time and moving goods between buildings have no purpose, and they would only blur an
--   exact number. So when the switch is on:
--     host    sends the stock of EVERY building of the lord: storage buildings, building sites, upgrades, burning
--             buildings and the piles demolished buildings leave, complete every cfg.keyEvery s and each change
--             within a second; it says so with "F X 1", again every cfg.exactEvery s (item "exact", on by default;
--             it needs the host's own DLL to find the three signatures: the same game build finds them on every
--             copy).
--     friend  switches GOODS on when the host has said "F X 1" (coop_patch does it), registers every building of the
--             lord with the DLL (a write of amount 0) and writes every amount exactly as the host has it, at once:
--             no margin, no settle time, no hold. The world module's region rule and its storage and site rules
--             stand down (coop_world.lua asks Coop.facts.exact), so there is one writer of stock only.
--             A pile the host no longer has is emptied and removed with the game's own routine (coop_patch pilegone).
--             When "F X 1" has not come for cfg.exactStale s the host is taken to be gone and the switch is
--             released: this copy's own game moves its stock again, as it would without the mod's switch.
--   What villagers carry stays each copy's own; so a region's total (buildings plus what is in hands) differs from
--   the host's by what is in hands.
--   Without the switch (no DLL, "native = off" or "goods = off" in coop.cfg, a signature not found, item "exact"
--   off on the host) nothing of this runs and the module works as described above.
--
-- Messages (after the core's "<seq> <wallclock> "; no field holds a space):
--   F X <1|0>                 the host sends every building's stock for exact mode (1) or not (0)
--   F B <entry>;<entry>;...   entry = <bkey>|<item>,...  changed items  |  <bkey>!|<item>,...  the complete building
--                             | <bkey>-  no longer sent (gone, burning, a site again)
--                             item = <good number>=<amount>  or  <rule code>=<value>      bkey = <type>@<x/10>,<y/10>
--   F A <region tag> <role>=<count>,...          livestock of an owned region by kind (EUnitRole number; none = 0)
--   F M <region tag> <i>:<cold>:<sickness>:<home bkey>;...     families by their place in the region's list
-- Names used: registry.tsv SMBuildingMaster.addToInventory / IsConstructed / isStorageTypeBuilding /
--   isResidentialBuilding, Region.GetTotalLivestockCountOfType, RTSMultiEngineCPP.SpawnLivestock / destroyUnit;
--   dumps/SMBuildingMaster.txt (Inventory, refuelDay, refueled, needsRefueling, waterSupply, marketDaysLeft,
--   mourningPeriod, onFire, isBeingUpgraded, Region, ownerPawn), SMUnit.txt (currentUnitRole, currentRegion, realPos,
--   animalAssignedTo, chosenPasture, Tasks, dead); struct WorkerFamily (familyHome, ConsumptionStatus: lane 8 census).

local C = rawget(_G, "Coop")
if type(C) ~= "table" or type(C.register) ~= "function" or type(C.api) ~= "table" then return "coop_facts: load coop.lua first" end
local A = C.api
local un, valid = A.un, A.valid
local F = C.facts or {}
C.facts = F
F.version = "0.5"

-- ---------------------------------------------------------------- switches and numbers
local DEFAULT_ON = {
  stock = true,           -- stock of finished buildings that are not storage
  storeExtra = true,      -- storage buildings: the goods the region rule does not cover
  values = true,          -- the RULES table
  families = true,        -- cold / sickness of families
  livestock = true,       -- animals per region and kind: a missing one is made here
  livestockRemove = true, -- ... and one too many is removed here (only an animal with no work: see liveApply)
  hold = true,            -- the hold after a local action
  exact = true,           -- exact mode: every building's stock, written exactly, when the native switch GOODS can be used
  levels = true,          -- every building's level (SMBuildingMaster.lv) is the host's (lane 24: a burnt house's level is lost in the save)
  rivals = true,          -- lane 39: in exact mode the rival lords' buildings too (stock, house values, fuel setting, levels)
  rivalWorkers = true,    -- lane 39: ... and which families work in each of them (F W)
  dist = true,            -- lane 42: a house's market goods (distributedGoods) as the host has them (F D; native DIST)
  camps = true,           -- lane 42 round two: the stock of bandit camps too, in exact mode (their loot changed on each copy)
}
local DEFAULT_CFG = {
  budgetMs = 0.5,         -- work per tick: at least this (os.clock has 1 ms steps on Windows: a tick may reach about 1 ms) ...
  budgetShare = 0.03,     -- ... or this share of the last frame's length (at 15 frames a second: 2 ms), so that a slow
  budgetMax = 3.0,        --     game still gets its passes done in time, but never more than this
  maxSteps = 80,
  maxLine = 3000,
  passEvery = 1.0,        -- host: one pass over the lord's buildings per second = the floor of every stock number
  valuesEvery = 2.0,      -- host: the rule values of a building are read this often = the floor of every rule value
  keyEvery = 45.0,        -- host: every building complete again this often
  applyEvery = 1.0,       -- friend: one pass over all the host's values this often ...
  quickEvery = 0.3,       -- ... and one over the buildings the host has just sent new values for this often
  indexAge = 5.0,         -- the number of buildings is looked at this often (a change rebuilds the list of the lord's buildings)
  indexMax = 60.0,        -- ... and the list is rebuilt after this long in any case
  hold = 2.0,             -- seconds a building is left alone after the local player acted on it
  -- Stock margin and settle time, chosen from the measured series (report, "flicker"): a cart takes 10 units and a
  -- workshop makes a batch of 5, on each copy at its own moment, 2 to 15 s apart. A difference of up to one cart
  -- load is given 6 s to close by itself; with a margin of 2 and 2.5 s (the first build) every such load was
  -- corrected and corrected back: 52 reversals a minute in the town's workshops against 19 with the module off.
  settle = 6.0,           -- stock: a difference within the margin is corrected after it lasted this long
  stockMargin = 10,       -- stock margin: units ...
  stockPct = 0.10,        -- ... or this part of the amount, whichever is larger
  liveEvery = 5.0,        -- livestock counts are read (host) and judged (friend) this often
  liveSettle = 25.0,      -- a livestock difference must last this long (ordered animals arrive at each copy's own time)
  famEvery = 5.0,         -- family marks are read (host) and judged (friend) this often
  logEvery = 60.0,        -- a line with counts and cost in the log this often
  exactEvery = 10.0,      -- exact mode: the host says "F X 1" this often ...
  exactStale = 30.0,      -- ... and a friend that has not heard it for this long leaves exact mode (its own game takes
                          --     the stock over again, as before): a player whose host is gone must not sit on frozen stock
  pileWait = 20.0,        -- exact mode: a pile the host has not named for this long is removed here
  exactIndexAge = 1.0,    -- exact mode: the number of buildings is looked at this often (a new building is registered at once)
  -- lane 42: in exact mode a value the host changed must reach a friend within the link's delay (the owner's bar: what
  -- players see is the same on every copy, a second or two apart). The floors and waits above made a friend show the
  -- host's value of 3 to 15 s before (measured: refueled 3 s, family cold 5.6 s, rival sickness never, rival livestock
  -- 15 s, rival workers 2.2 s). In exact mode these are used instead:
  exactValuesEvery = 1.0, -- host: the rule values of houses and of rival buildings are read this often; a friend writes them
                          --   at once (no margin, no settle time)
  exactFamEvery = 1.0,    -- host: family marks read this often (rival towns too); a friend writes them on the first look
  rivalLiveSettle = 2.0,  -- friend: a rival town's livestock (its AI orders on the host only) is made equal after this long
  rivalWorkWait = 0.5,    -- friend: a rival building's workers that differ this long get the host's list
}
F.on = F.on or {}
for k, v in pairs(DEFAULT_ON) do if F.on[k] == nil then F.on[k] = v end end
F.cfg = F.cfg or {}
for k, v in pairs(DEFAULT_CFG) do if F.cfg[k] == nil then F.cfg[k] = v end end
F.stats = F.stats or {}

-- The generic part: reflected properties of a building, read on the host and written on a friend by name.
--   c code in the line; p property; k kind (i number, b switch); margin and settle as above. Every rule value is sent
--   when it changed, at most once per cfg.valuesEvery (2 s).
-- They are read on houses and on every building that says it needs fuel (the index marks those "res").
-- Not in this table on purpose: values a player sets himself, which travel as actions both ways (stockFuelFor,
-- buildPriority, supplyOverstocking, sleep, allowMarketStalls, work area, selling types); counts the game derives from
-- its lists (numStoredGeneric / Large / Pantry follow the inventory, numActiveWorkerFamilies the families); approval,
-- which the game recomputes within a frame; field numbers (the plants are native: a written percentage would be
-- recomputed, and the test town has no field to measure it on).
local RULES = {
  { c = "rd", p = "refuelDay",      k = "i", margin = 1, settle = 3.0 },
  { c = "rf", p = "refueled",       k = "b", margin = 1, settle = 3.0 },
  { c = "nr", p = "needsRefueling", k = "b", margin = 1, settle = 3.0 },
  { c = "ws", p = "waterSupply",    k = "i", margin = 1, settle = 3.0 },
  -- (lane 64, game run v5e) daily = true: a count of days that each copy's own game takes one off at its day change.
  -- In exact mode (lane 42) the host's new value was written here the moment its line came. When that line beat this
  -- copy's own day change, this copy's game then took one off the host's NEW value: one day ahead. Seen: three homes
  -- in mourning at 1 on the host and 0 on the friend on day 322; the friend's families had their next person one day
  -- before the host's (days 323 to 326) and its three old bodies went one day before the host's. So for these the
  -- margin of 1 and the settle time stay in exact mode too: a difference of one day is this copy's own day change
  -- about to come (or just gone), and is written only when it has lasted 3 s.
  { c = "md", p = "marketDaysLeft", k = "i", margin = 1, settle = 3.0, daily = true },
  { c = "mp", p = "mourningPeriod", k = "i", margin = 1, settle = 3.0, daily = true },
  -- lane 39: a rival lord's own setting (its AI decides on the host only): read and written on a rival's building only
  { c = "sf", p = "stockFuelFor",   k = "i", margin = 0, settle = 0.0, rival = true },
  { c = "bp", p = "buildPriority",  k = "i", margin = 0, settle = 0.0, rival = true },
  -- lane 42: how many oxen a rival's building keeps at work (his AI sets it on the host only; measured: the rival's
  -- trading post 3 / 2, its oxen list 3 / 2). Set with the game's own changeActiveLivestockWorkers (see setAO).
  { c = "ao", p = "activeOxen",     k = "i", margin = 0, settle = 0.0, rival = true, set = "ao" },
  -- lane 71: a rival's paused workplace or site (his AI pauses it on the host only; live r5/r9: 4@-7660,5660 sleep 0/1
  -- for days). Set with the game's own setSleep (the panel's pause button), quietly (see setRule).
  { c = "sl", p = "sleep",          k = "b", margin = 0, settle = 0.0, rival = true, set = "sleep" },
}
F.rules = F.rules or RULES
local RULE = {}; for _, R in ipairs(F.rules) do RULE[R.c] = R end
-- lane 42: write a rule's value. activeOxen goes through the game's own SMBuildingMaster.changeActiveLivestockWorkers
-- (Int amt), which moves the building's oxen with it. Whether amt is a change or the new number is not known from the
-- registry: it is called with the change first; when the result shows the number was taken as it is, it is called
-- again with the wanted number (both outcomes end at the host's value or leave it as the game allows).
local function setRule(b, R, want)
  if R.set == "ao" then
    local cur = b[R.p]
    if type(cur) ~= "number" or cur == want then return end
    b:changeActiveLivestockWorkers(want - cur)
    local now = b[R.p]
    if now ~= want and now == want - cur then b:changeActiveLivestockWorkers(want) end
    return
  end
  -- lane 71: sleep through the game's own setSleep inside the town module's quiet wrapper (its SLEEP hook must not
  -- report the write as this player's action); the flag itself only when the call did not take
  if R.set == "sleep" then
    local v = (want == 1)
    local T = C.town
    if T and T.quiet then T.quiet(function() b:setSleep(v) end) else b:setSleep(v) end
    if (b.sleep and true or false) ~= v then b.sleep = v end
    return
  end
  if R.k == "b" then b[R.p] = (want == 1) else b[R.p] = want end
end
local FAM = { "cold", "sickness", "injured", "hunger" }   -- (hunger: lane 42 round two, a rival family 1 / 2 in spring, a6) Region.workerFamilies[i].ConsumptionStatus.<field> (injured: lane 36, the friend's own work accident showed 0 / 29)
local ROLE_MIN, ROLE_MAX, ROLE_HARE = 9, 22, 20      -- EUnitRole: chicken 9 ... calf 22 (lane 8 census); hares are wild

-- ---------------------------------------------------------------- small helpers
local function log(fmt, ...) A.log("facts: " .. fmt, ...) end
local function bump(k, n) F.stats[k] = (F.stats[k] or 0) + (n or 1) end
local function fail(what, e)
  bump("err"); local msg = what .. ": " .. tostring(e)
  if F.lastErr ~= msg then log("error %s", msg) end      -- a failing pass would otherwise log every second
  F.lastErr = msg
end
-- where the time goes: per piece of work, how often, how long in all, and the longest single piece (os.clock has
-- 1 ms steps on Windows, so only the sums and the long pieces mean something)
F.prof = F.prof or {}
local function prof(name, ms)
  local P = F.prof[name]; if not P then P = { n = 0, ms = 0, max = 0 }; F.prof[name] = P end
  P.n = P.n + 1; P.ms = P.ms + ms; if ms > P.max then P.max = ms end
end
local function timed(name, fn, ...)
  local t0 = os.clock(); local ok, e = pcall(fn, ...)
  prof(name, (os.clock() - t0) * 1000)
  if not ok then fail(name, e) end
  return ok, e
end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); if ok then return a end end
local function mine(o) return F.me ~= nil and valid(o) and addr(o) == F.me end
-- lane 39: another lord (not bandits): his buildings are carried in exact mode too
local function rivalLord(o)
  if F.me == nil or not valid(o) or addr(o) == F.me then return false end
  local ok, res = pcall(function() return (not o.isBandit) and type(o:getPawnSetupIndex()) == "number" end)
  return ok and res == true
end
local function num(x) local i = math.tointeger(x); if i then return tostring(i) end; return string.format("%.3f", x) end
local function rkey(r)
  local ok, k = pcall(function() return r.regionUniqueTag:ToString() end)
  if not ok or type(k) ~= "string" or k == "" or k == "None" then return nil end
  return (k:gsub("[^%w_%.]", "_"))
end
local function parseKey(k)
  local t, x, y = (k or ""):match("^(%d+)@(%-?%d+),(%-?%d+)$")
  return tonumber(t), tonumber(x), tonumber(y)
end
local function keyOf(b)
  local l = b:K2_GetActorLocation()
  local x, y = math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5)
  return string.format("%d@%d,%d", A.btype(b), x, y), x, y
end
-- a building's inventory as { [good] = amount } (records of the same good are added up)
-- A record is read directly; un() is tried only for a record that does not read so (the world module's way: lane 9
-- measured 8 against 360 microseconds per building, the same goods both ways).
local function invOf(b)
  local m = {}; local inv = b.Inventory
  for j = 1, #inv do
    local x = inv[j]; local t, a = x.Type, x.amt
    if type(t) ~= "number" then x = un(x); t, a = x.Type, x.amt end
    if type(t) == "number" and type(a) == "number" and a ~= 0 then m[t] = (m[t] or 0) + a end
  end
  return m
end
-- (lane 47) the host's pass: a building's stock from the native building table (coop_snap.lua: read at the start of
-- this frame, checked against the reflected reads); the host writes no stock, so it is this frame's stock. A building
-- with more records than the table keeps, or one it does not hold, is read as before.
local function invHost(b)
  local N = rawget(C, "snap")
  if N and N.buildings and F.S and F.S.role == "host" and N.buildings() then
    local r = N.building(addr(b) or 0)
    if r and type(r.inv) == "table" and (r.invN or 999) <= 160 then local m = {}; for g, a in pairs(r.inv) do m[g] = a end; return m end
  end
  return invOf(b)
end
-- lane 42: a house's distributedGoods as "<type>:<amount>,..." in the list's order ("-" when empty)
local function distOf(b)
  local t = {}; local arr = b.distributedGoods
  for j = 1, #arr do
    local x = arr[j]; local ty, a = x.Type, x.amt
    if type(ty) ~= "number" then x = un(x); ty, a = x.Type, x.amt end
    t[#t + 1] = string.format("%d:%d", math.floor(ty), math.floor(a))
  end
  return #t > 0 and table.concat(t, ",") or "-"
end
local function stockOf(b, g)
  local s = 0; local inv = b.Inventory
  for j = 1, #inv do
    local x = inv[j]; local t = x.Type
    if type(t) ~= "number" then x = un(x); t = x.Type end
    if t == g then s = s + x.amt end
  end
  return s
end
-- exact mode, this copy's side of it (see EXACT MODE at the top)
local function patch() return rawget(C, "patch") end
local function hostExact()        -- host: the stock of every building is sent
  local P = patch()
  if not (F.on.exact and F.on.stock and P ~= nil and type(P.goodsAvail) == "function") then return false end
  -- whether the switch could be used is in the DLL's status file: asked every 2 s, not on every tick
  local clock = os.clock()
  if F.hxAt == nil or clock - F.hxAt >= 2.0 or clock < F.hxAt then F.hxAt = clock; F.hxVal = P.goodsAvail() == true end
  return F.hxVal
end
local function friendExact()      -- friend: the host said so and the switch is on in this copy
  local P = patch()
  return F.on.exact and F.on.stock and F.hostExact == true and P ~= nil and type(P.goodsOn) == "function" and P.goodsOn() == true
end
local exactSwitch                 -- (defined below friendTick's helpers)
local function setHostExact(v)    -- friend: what the host said; coop_patch switches GOODS on only after "F X 1"
  local was = F.hostExact
  F.hostExact = v
  local P = patch(); if P then P.hostExact = v end
  -- (lane 55) at the join the host's "F X 1" came 70 to 270 ms before this copy's next patch step and facts tick
  -- switched GOODS, TOTALS and exact mode on; a region pass of the world module in that window ran the old grant /
  -- consume rule once (lead22, lead23, lead25: "stock hof: added 8 removed 0 failed 1 (... 237:-11)": good 237, a
  -- felled tree's branches, lies on the ground and cannot be consumed from a building). Now the switches and exact
  -- mode go on in the same call, so no region pass can see the in-between state.
  if v == true and was ~= true and P and type(P.friendNow) == "function" and not rawget(C, "hold") then
    pcall(P.friendNow, C.s)
    if exactSwitch then pcall(exactSwitch, os.clock()) end
  end
end
local function tradeable(S)
  if F.trade then return F.trade end
  local t = {}; local arr = S.eng.tradeableGoods
  for i = 1, #arr do local v = arr[i]; if type(v) == "number" then t[v] = true end end
  F.trade = t
  return t
end

local function send(line)
  if F.capture then F.capture[#F.capture + 1] = line; return end
  A.send(line); bump("sent"); bump("bytes", #line + 20)      -- + the core's prefix (sequence number and clock)
end
local function sendList(head, items, sep)
  local buf, n = {}, #head
  for _, it in ipairs(items) do
    if #buf > 0 and n + #sep + #it > F.cfg.maxLine then send(head .. table.concat(buf, sep)); buf = {}; n = #head end
    buf[#buf + 1] = it; n = n + #it + #sep
  end
  if #buf > 0 then send(head .. table.concat(buf, sep)) end
end

-- ---------------------------------------------------------------- jobs: work spread over ticks (the world module's way)
local function addJob(name, step, st)
  for _, j in ipairs(F.jobs) do if j.name == name then return false end end
  F.jobs[#F.jobs + 1] = { name = name, step = step, st = st or {} }
  return true
end
local function runJobs(budget)
  local t0 = os.clock(); local n = 0
  while #F.jobs > 0 do
    if os.clock() - t0 >= budget or n >= F.cfg.maxSteps then break end
    local j = F.jobs[1]; local s0 = os.clock()
    local ok, done = pcall(j.step, j.st)
    prof(j.name, (os.clock() - s0) * 1000)
    n = n + 1
    if not ok then fail("job " .. j.name, done); table.remove(F.jobs, 1)
    elseif done then table.remove(F.jobs, 1) end
  end
end

-- ---------------------------------------------------------------- session / world reset
local function fresh(S)
  if F.S == S and F.world == S.worlds then return end
  F.S = S; F.world = S.worlds
  F.jobs = {}; F.idx = nil; F.trade = nil; F.me = nil
  F.sent = {}; F.sentA = {}; F.sentM = {}; F.sentL = {}   -- host: everything is sent again (a keyframe)
  F.hostL = {}; F.lvSaid = {}                             -- friend: the host's building levels
  F.hostW = {}; F.wSince = {}                             -- friend: the host's workers of rival buildings (lane 39)
  F.hostD = {}; F.dDirty = {}; F.dGen = nil               -- friend: the host's market goods of houses (lane 42)
  F.host = { b = {}, a = {}, m = {} }; F.dirty = {}       -- friend: the host's values; stale after a load, dropped
  F.holds = {}; F.holdR = {}; F.heldSaid = {}; F.last = {}; F.made = {}; F.liveSince = {}; F.famSince = {}; F.famDay = {}; F.refused = {}
  F.liveTot = {}; F.liveFull = {}; F.passNo = 0
  F.t = { pass = 0, apply = 0, quick = 0, index = -1e9, live = 0, fam = 0, log = os.clock(), miss = 0, prune = 0 }
  F.wasHold = nil
  -- exact mode: nothing is known of the new world; the host says "F X 1" again with its first complete pass
  F.exact = false; F.sentX = nil; F.regd = {}; F.pileGone = {}; F.dumpSeen = {}; F.exactAt = nil
  setHostExact(nil)
  log("reset for world %d", S.worlds)
end

-- ---------------------------------------------------------------- the lord's buildings (both roles)
-- list of { b, k (name), t (type), x, y, store, res, reg (region address), dump, dup }, a map by name and the storage
-- buildings by region. Built a building per step, every cfg.indexAge seconds.
local function indexJob(st)
  local arr = F.S.eng.buildingArr
  if not st.list then
    st.list = {}; st.map = {}; st.store = {}; st.i = 0
    -- lane 39: the rival lords (by address on this copy), looked up once per build of the list
    st.lords = {}
    if F.on.rivals then
      local hp = F.S.hp and valid(F.S.hp) and addr(F.S.hp) or nil          -- the mod's helper lord owns nothing
      pcall(function() for _, pw in ipairs(A.pawns()) do if rivalLord(pw) and addr(pw) ~= hp then st.lords[addr(pw)] = true end end end)
    end
  end
  st.i = st.i + 1
  if st.i <= #arr then
    local b = un(arr[st.i])
    if valid(b) then
      pcall(function()
        local op = b.ownerPawn
        local rival, camp = false, false
        if not mine(op) then
          if F.on.rivals and st.lords and st.lords[addr(op) or 0] then rival = true
          -- lane 42 round two: a bandit camp's stock (owner B) is carried in exact mode like a rival's, stock only
          elseif F.on.camps and valid(op) and op.isBandit then camp = true
          else return end
        end
        local k, x, y = keyOf(b)
        local e = { b = b, k = k, t = A.btype(b), x = x, y = y, rival = rival or nil, camp = camp or nil }
        -- lane 42 round two: a market stall (EBuildingFunction 3) gets its distributedGoods from the region's distribution
        -- as a house does (4c3c490 walks the region's market list, houses and stalls: READ), so DIST carries it too
        pcall(function() e.stall = tonumber(b.buildingFunction) == 3 or nil end)
        e.dump = b:GetType() == 88                          -- the pile a demolished building leaves: each copy's carriers empty it
        local okS, s = pcall(function() return b:isStorageTypeBuilding() end); e.store = okS and s == true
        local okH, h = pcall(function() return b:isResidentialBuilding() or b.needsRefueling end); e.res = okH and h == true
        e.reg = addr(b.Region)
        if st.map[k] then st.map[k].dup = true; e.dup = true else st.map[k] = e end      -- two buildings with one name: neither is written
        st.list[#st.list + 1] = e
        if e.store and e.reg and not e.dump and not rival and not camp then local L = st.store[e.reg] or {}; st.store[e.reg] = L; L[#L + 1] = e end
      end)
    end
    return false
  end
  F.idx = { list = st.list, map = st.map, store = st.store, t = os.clock(), n = #arr }
  return true
end
-- The list is built again when the number of buildings in the world changed (looked at every cfg.indexAge seconds),
-- when a name the host sent is not on it (at most every 2 s), and every cfg.indexMax seconds in any case: one build
-- costs about 20 ms of reading for 110 buildings, spread over ticks.
local function needIndex(clock, force)
  if force and clock - F.t.miss < 2.0 then return end
  local due = force or not F.idx
  if not due and clock - F.t.index >= F.cfg.indexAge then
    F.t.index = clock
    local ok, n = pcall(function() return #F.S.eng.buildingArr end)
    due = (not ok) or n ~= F.idx.n or clock - F.idx.t >= F.cfg.indexMax
  end
  if due and addJob("index", indexJob, {}) then F.t.index = clock; if force then F.t.miss = clock end end
end
-- the building with that name on this copy (exact, else a neighbour within 10 cm: a rounding edge), alive and unique
local function byKey(k)
  local X = F.idx; if not X then return nil end
  local e = X.map[k]
  if not e then
    local t, x, y = parseKey(k); if not t then return nil end
    for dx = -1, 1 do for dy = -1, 1 do
      if not e then e = X.map[string.format("%d@%d,%d", t, x + dx, y + dy)] end
    end end
  end
  if not e or e.dup or not valid(e.b) then return nil end
  return e
end
-- still that building, at that place? (asked before a write: an object can be gone and its address used again)
local function same(e)
  if not valid(e.b) then return false end
  -- (lane 46) a building this copy is demolishing (the town module named it, coop_x_jobs J.gone) is never written:
  -- stock written into it makes the game register it in its region's building sets again (the chooser crash). 30 s:
  -- the index has dropped it by then; a demolish that failed is written again after that.
  local G = C and C.goneB
  if G and next(G) ~= nil then
    if e.addr == nil then local ok, a = pcall(function() return e.b:GetAddress() end); e.addr = ok and a or false end
    local gb = e.addr and G[e.addr]
    if gb and os.clock() - gb < 30 then bump("goneSkip"); return false end
  end
  local ok, k = pcall(keyOf, e.b)
  return ok and k == e.k
end
-- finished and not burning, read now (a site, an upgrade and a fire are the world module's business)
-- lane 42: a house being upgraded is lived in (its family stays, a villager refuels it: measured on the host, refuelDay
-- -1 -> 5 and refueled 0 -> 1 during a rival house's upgrade) but is not "finished"; in exact mode its house values
-- are carried then too
local function upgNow(e)
  local ok, u = pcall(function() return (not e.b.onFire) and e.b.isBeingUpgraded and true or false end)
  return ok and u == true
end
local function liveNow(e)
  local ok, live = pcall(function() return (not e.b.onFire) and e.b:IsConstructed() end)
  return ok and live == true
end
-- a storage building goods may be moved to and from: finished (or being upgraded: it keeps working), not burning
local function partnerOk(p)
  if not valid(p.b) then return false end
  local ok, good = pcall(function() return not p.b.onFire and (p.b:IsConstructed() or (p.b.isBeingUpgraded and true or false)) end)
  return ok and good
end

-- ---------------------------------------------------------------- host: read and send
-- Reading costs about 25 us per property (measured: 10 ms for 38 buildings each second), so not everything is read
-- on every pass: whether the building is finished and not burning every 4th pass; the rule values every 2 s (their
-- floor); a building whose stock has not changed on 6 passes in a row only every 4th pass (a house, an idle
-- workshop), until it changes again.
local function hostOne(st, e)
  local b = e.b
  local exact = st.exact                                    -- exact mode: the stock of every building, whatever it is
  if e.rival and not exact then return end                  -- lane 39: a rival's building only in exact mode
  if e.camp and not exact then return end                   -- lane 42: a bandit camp's stock only in exact mode
  if e.store and not e.res and not exact then return end    -- nothing of a plain storage building is sent from here
  local clock = st.clock
  local L = F.sent[e.k]
  if e.liveAt == nil or st.n - e.liveAt >= 4 then
    local live = (not b.onFire) and b:IsConstructed() and true or false
    local t = A.btype(b)
    if t ~= e.t then st.stale = true; live = false; e.gone = true end      -- another type now (a house that grew): its name changed
    e.live = live; e.liveAt = st.n
    e.upg = exact and not live and upgNow(e) or nil                           -- lane 42
  end
  if e.gone then return end                                 -- its old name is told "no longer sent"; the new list has its new name
  if not e.live and not exact then return end               -- burning; a site or an upgrade (the world module's rule)
  local full = false
  if not L then L = { g = {}, v = {}, tFull = clock - math.random() * F.cfg.keyEvery * 0.5, tR = -1e9, quiet = 0, phase = math.random(0, 3) }; F.sent[e.k] = L; full = true
  elseif clock - L.tFull >= F.cfg.keyEvery then full = true end
  st.seen[e.k] = true
  -- (exact mode reads every building on every pass: a change must not wait up to 4 s for its turn)
  if not full and not exact and L.quiet >= 6 and (st.n + L.phase) % 4 ~= 0 then return end
  local items = {}
  if F.on.stock and (exact or not e.store) then
    local inv = invHost(b); local n0 = #items
    for g, a in pairs(inv) do if full or L.g[g] ~= a then items[#items + 1] = g .. "=" .. num(a) end end
    if not full then for g in pairs(L.g) do if inv[g] == nil then items[#items + 1] = g .. "=0" end end end
    L.g = inv
    if #items > n0 and not full then L.quiet = 0 else L.quiet = L.quiet + 1 end
    -- lane 41 (scene module): the shown goods follow the stock; a building whose stock changed is read again there
    if #items > n0 then local Qs = rawget(C, "scene"); if Qs and Qs.stockSeen then pcall(Qs.stockSeen, e.k) end end
  end
  -- lane 42: in exact mode every 1 s (exactValuesEvery), and a rival's own settings (build priority, fuel) also on his
  -- sites and upgrades: his AI sets a site's priority on the host only (measured: 4 sites 1 / 4, 2 / 4, 3 / 4)
  local vEvery = exact and F.cfg.exactValuesEvery or F.cfg.valuesEvery
  if F.on.values and (e.res or e.rival) and (e.live or e.upg or (e.rival and exact and not e.dump)) and (full or clock - L.tR >= vEvery) then
    L.tR = clock
    for _, R in ipairs(F.rules) do
      if R.on ~= false and (not R.rival or e.rival) and (R.rival or e.res) and (e.live or R.rival or (e.upg and not R.rival)) then
        local x = b[R.p]
        if R.k == "b" then x = x and 1 or 0 end
        if type(x) == "number" and (full or L.v[R.c] ~= x) then items[#items + 1] = R.c .. "=" .. num(x); L.v[R.c] = x end
      end
    end
  end
  -- lane 42: a house's market goods (distributedGoods: the goods records the region's distribution gave it), in the
  -- host's order, on change and with the keyframe: F D <bkey>=<type>:<amount>,...|-;...
  if exact and F.on.dist and (e.res or e.stall) and not e.dump then   -- (stalls: lane 42 round two)
    local okD, d = pcall(distOf, b)
    if okD and (full or L.dg ~= d) then L.dg = d; st.dist = st.dist or {}; st.dist[#st.dist + 1] = e.k .. "=" .. d end
  end
  if full then L.tFull = clock; st.entries[#st.entries + 1] = e.k .. "!|" .. table.concat(items, ",")
  elseif #items > 0 then st.entries[#st.entries + 1] = e.k .. "|" .. table.concat(items, ",") end
  -- lane 39: which families work in a rival's building (its AI assigns them on the host only), every 2 s and with the
  -- keyframe: <bkey>=<family ids rising, or ->/<active families>
  if e.rival and F.on.rivalWorkers and e.live and not e.dump and (full or clock - (L.tW or -1e9) >= vEvery) then
    L.tW = clock
    local ids = {}; local a = b.assignedFamilyIDs
    for j = 1, #a do local v = a[j]; if type(v) ~= "number" then v = un(v) end; v = math.tointeger(tonumber(v)); if v then ids[#ids + 1] = v end end
    table.sort(ids)
    local s = (#ids > 0 and table.concat(ids, ",") or "-") .. "/" .. num(tonumber(b.numActiveWorkerFamilies) or 0)
    if full or L.w ~= s then L.w = s; st.workers = st.workers or {}; st.workers[#st.workers + 1] = e.k .. "=" .. s end
  end
end

local function hostPassJob(st)
  local X = F.idx; if not X then return true end
  if not st.list then
    F.passNo = (F.passNo or 0) + 1
    st.list = X.list; st.i = 0; st.entries = {}; st.seen = {}; st.clock = os.clock(); st.n = F.passNo
    st.exact = hostExact()
    return false
  end
  st.i = st.i + 1
  local e = st.list[st.i]
  if e then
    if not valid(e.b) then st.stale = true
    elseif not e.dup and (st.exact or not e.dump) then
      local ok, err = pcall(hostOne, st, e)
      if not ok then fail("read " .. e.k, err) end
    end
    return false
  end
  if st.stale then needIndex(st.clock, true) end           -- a building of the list is gone or has another type: build the list again
  for k in pairs(F.sent) do if not st.seen[k] then st.entries[#st.entries + 1] = k .. "-"; F.sent[k] = nil end end
  if #st.entries > 0 then bump("entries", #st.entries); sendList("F B ", st.entries, ";") end
  if st.workers and #st.workers > 0 then bump("workersSent", #st.workers); sendList("F W ", st.workers, ";") end
  if st.dist and #st.dist > 0 then bump("distSent", #st.dist); sendList("F D ", st.dist, ";") end      -- lane 42
  bump("passes")
  return true
end

-- livestock of every owned region by kind
local function ownedRegions(S)
  local t = {}; local arr = S.eng.regions
  for i = 1, #arr do local r = un(arr[i]); if valid(r) and mine(r.ownerPawn) then local k = rkey(r); if k then t[#t + 1] = { r = r, k = k } end end end
  return t
end
-- lane 39: livestock also of every rival lord's town in exact mode (a rival's animals, oxen and horses included, are
-- counted among the region's residents: Schenfurt showed 89 / 88 with one horse more on the host)
local function liveRegions(S, exact)
  local t = ownedRegions(S)
  local W = rawget(C, "world")
  if exact and F.on.rivals and W and W.rivalTown then
    local arr = S.eng.regions
    for i = 1, #arr do local r = un(arr[i]); if valid(r) and W.rivalTown(r) then local k = rkey(r); if k then t[#t + 1] = { r = r, k = k, rival = true } end end end
  end
  return t
end
local function liveCounts(r)
  local t = {}
  for role = ROLE_MIN, ROLE_MAX do
    if role ~= ROLE_HARE then
      local ok, c = pcall(function() return r:GetTotalLivestockCountOfType(role) end)
      if ok and type(c) == "number" then t[role] = c end
    end
  end
  return t
end
-- The count per kind costs 13 calls a region, so it is made only when the region's total changed (one call) and
-- with every keyframe.
local function hostLive(S, clock)
  local key = clock - (F.t.liveKey or -1e9) >= F.cfg.keyEvery
  if key then F.t.liveKey = clock end
  for _, R in ipairs(liveRegions(S, hostExact())) do
    local tot = R.r:getTotalLivestockCount()
    if key or F.sentA[R.k] == nil or F.liveTot[R.k] ~= tot then
      F.liveTot[R.k] = tot
      local c = liveCounts(R.r); local items = {}
      for role = ROLE_MIN, ROLE_MAX do if c[role] and c[role] ~= 0 then items[#items + 1] = role .. "=" .. c[role] end end
      local line = #items > 0 and table.concat(items, ",") or "-"
      if key or F.sentA[R.k] ~= line then F.sentA[R.k] = line; send("F A " .. R.k .. " " .. line) end
    end
  end
end

-- the family marks, a family per step
local function famEntry(f, i)
  local cs = f.ConsumptionStatus
  local home = "-"; local h = f.familyHome
  if valid(h) then local ok, k = pcall(keyOf, h); if ok then home = k end end
  local v = {}
  for j, p in ipairs(FAM) do local x = cs[p]; if type(x) == "boolean" then x = x and 1 or 0 end; v[j] = type(x) == "number" and num(x) or "-" end
  return i .. ":" .. table.concat(v, ":") .. ":" .. home
end
local function hostFamJob(st)
  if not st.regs then st.regs = liveRegions(F.S, hostExact()); st.ri = 1; st.i = 0; st.cur = {}; return false end   -- lane 42: rival towns too (exact mode)
  local R = st.regs[st.ri]; if not R then return true end
  if not valid(R.r) then st.ri = st.ri + 1; st.i = 0; st.cur = {}; return false end
  local fams = R.r.workerFamilies
  st.i = st.i + 1
  if st.i <= #fams then st.cur[st.i] = famEntry(fams[st.i], st.i); return false end
  local last = F.sentM[R.k] or {}; local items = {}
  for i, s in ipairs(st.cur) do if st.key or last[i] ~= s then items[#items + 1] = s end end
  F.sentM[R.k] = st.cur
  if #items > 0 then sendList("F M " .. R.k .. " ", items, ";") end
  st.ri = st.ri + 1; st.i = 0; st.cur = {}
  return false
end

-- ---------------------------------------------------------------- building levels (lane 24)
-- A house that burns becomes a ruin (type 75) that keeps the house's level (lv 2) in the running game, but the save
-- the host hands out holds level 1 for it (measured: host 75@9786,-7826 lv 2; a friend that loaded that save alone:
-- lv 1, everything else of the ruin equal). The level is what the daily comparison reads and what the house is built
-- back to, so a friend that loaded alone differed again within two days and asked again (4 loads in a row in one
-- sitting). So the host says every building's level (on change, and complete with every keyframe: after a load, a
-- join, a resync), and a friend writes the host's level on a finished building that is not being upgraded.
--   F L <bkey>=<lv>;...
local function hostLevels(clock)
  local X = F.idx; if not X then return end
  F.sentL = F.sentL or {}
  local items = {}
  for _, e in ipairs(X.list) do
    if not e.dup and valid(e.b) then
      local ok, lv = pcall(function() return e.b.lv end)
      if ok and type(lv) == "number" and F.sentL[e.k] ~= lv then F.sentL[e.k] = lv; items[#items + 1] = e.k .. "=" .. num(lv) end
    end
  end
  if #items > 0 then sendList("F L ", items, ";"); bump("lvSent", #items) end
end
local function friendLevels(clock)
  F.lvSaid = F.lvSaid or {}
  for k, want in pairs(F.hostL or {}) do
    local e = byKey(k)
    if e then
      local ok, fixed, was = pcall(function()
        local b = e.b
        if b.onFire or b.isBeingUpgraded or not b:IsConstructed() then return false end
        local cur = b.lv
        if cur == want then return false end
        b.lv = want
        return b.lv == want, cur
      end)
      if ok and fixed then
        bump("lvFix")
        if (F.stats.lvFix or 0) <= 30 or F.lvSaid[k] ~= want then F.lvSaid[k] = want; log("level of %s set to the host's %s (was %s)", k, tostring(want), tostring(was)) end
      elseif not ok then fail("level " .. k, fixed) end
    end
  end
end

function F.keyframe()
  F.sent = {}; F.sentA = {}; F.sentM = {}; F.sentX = nil; F.sentL = {}
  if F.t then F.t.pass = 0; F.t.liveKey = nil; F.t.famKey = nil; F.t.live = 0; F.t.fam = 0 end
  return "keyframe queued"
end

local function hostTick(S, clock)
  local cfg = F.cfg
  -- a join or resync: friends drop every line while they load. When it ends, everything is sent complete again.
  if rawget(C, "hold") then F.wasHold = true; return end
  if F.wasHold then F.wasHold = nil; F.keyframe(); log("a join or resync ended: every value is sent again") end
  -- exact mode: say that every building's stock is being sent (again with every keyframe: a friend switches its
  -- native switch on only after it has heard this). A host that never is in exact mode never sends the line.
  local ex = hostExact()
  if ex then
    if F.sentX ~= true or clock - (F.t.x or -1e9) >= cfg.exactEvery then
      if F.sentX ~= true then log("exact mode: the stock of every building is sent (the native switch GOODS can be used)") end
      F.sentX = true; F.t.x = clock; send("F X 1")
    end
  elseif F.sentX == true then F.sentX = false; send("F X 0"); log("exact mode ended on the host") end
  needIndex(clock, false)
  if F.on.levels and F.idx and clock - (F.t.lv or -1e9) >= 2.0 then F.t.lv = clock; timed("hostLevels", hostLevels, clock) end
  if (F.on.stock or F.on.values) and F.idx and clock - F.t.pass >= cfg.passEvery then
    if addJob("hostPass", hostPassJob, {}) then F.t.pass = clock end
  end
  if F.on.livestock and clock - F.t.live >= cfg.liveEvery then F.t.live = clock; timed("hostLive", hostLive, S, clock) end
  if F.on.families and clock - F.t.fam >= (hostExact() and cfg.exactFamEvery or cfg.famEvery) then   -- lane 42: 1 s in exact mode
    local key = clock - (F.t.famKey or -1e9) >= cfg.keyEvery
    if addJob("hostFam", hostFamJob, { key = key }) then F.t.fam = clock; if key then F.t.famKey = clock end end
  end
end

-- ---------------------------------------------------------------- the hold after a local action
-- Every town action this copy sends goes through Coop.town.emitAction(S, action, fields), in the tick (never in a
-- hook). Its fields name the buildings ("type,x,y,z...") and the region (its tag) the player acted on.
function F.noteLocal(act, fields)
  if not F.holds then return end
  local clock = os.clock()
  for f in tostring(fields or ""):gmatch("%S+") do
    local t, x, y = f:match("^(%d+),(%-?%d+%.?%d*),(%-?%d+%.?%d*)")
    if t then F.holds[#F.holds + 1] = { t = tonumber(t), x = tonumber(x) / 10, y = tonumber(y) / 10, at = clock, act = act }
    elseif not f:find(",", 1, true) then F.holdR[f] = clock end
  end
  bump("localActions")
end
local function wrapTown()
  local T = C.town
  if not (T and T.emitAction) or T.emitAction == F.wrapFn then return end
  local orig = T.emitAction
  F.wrapFn = function(S, act, fields)
    local Fc = rawget(_G, "Coop") and _G.Coop.facts
    if Fc and Fc.noteLocal then pcall(Fc.noteLocal, act, fields) end
    return orig(S, act, fields)
  end
  T.emitAction = F.wrapFn
end
-- the local action that holds this building, or nil
local function heldBy(e, clock)
  if not F.on.hold then return nil end
  for _, h in ipairs(F.holds) do
    if clock - h.at < F.cfg.hold and h.t == e.t and math.abs(h.x - e.x) <= 1.5 and math.abs(h.y - e.y) <= 1.5 then return h end
  end
end

-- ---------------------------------------------------------------- friend: the decision and the writes
-- true when a difference d of item id must be corrected now (see "margin" at the top)
local function due(since, id, d, margin, settle, clock, paused)
  if d == 0 then since[id] = nil; return false end
  if paused or math.abs(d) > margin then since[id] = nil; return true end
  local s = since[id]
  if not s then since[id] = clock; return false end
  if clock - s >= settle then since[id] = nil; return true end
  return false
end
-- (lane 64) THE RULE FOR A VALUE THAT THIS COPY'S OWN DAY STEP ALSO CHANGES (a count of days, a family's mark): a
-- difference of ONE is this copy's own day step about to come or just gone, and is written only when it has lasted
-- 3 s; more than one, or a paused copy, at once. Written at once (exact mode), the host's new value could land here
-- ahead of this copy's own day step, which then worked on it and went a day further (game run v5e; desk test
-- lanes/lane_s21_64/probes/offline_facts_day_test.lua).
function F.dayRule(since, id, d, clock, paused) return due(since, id, d, 1, 3.0, clock, paused) end
F.famDay = F.famDay or {}
-- what this copy's value was when a new host value arrived: the difference a player would have seen
local function seen(kind, d, margin)
  bump(kind .. "_in")
  if d ~= 0 then bump(kind .. "_inDiff"); bump(kind .. "_inSum", math.abs(d)) end
  if math.abs(d) > margin then bump(kind .. "_inOver") end
  if math.abs(d) > (F.stats[kind .. "_inMax"] or 0) then F.stats[kind .. "_inMax"] = math.abs(d) end
end
-- a correction that undoes the one before on the same item within 20 s is what a player sees as flicker
local function flip(id, d, clock)
  local L = F.last[id]
  if L and clock - L.t < 20.0 and (L.d > 0) ~= (d > 0) then bump("flips"); if clock - L.t < 3.0 then bump("flipsFast") end end
  F.last[id] = { t = clock, d = d }
end

-- exact mode: every amount of this building as the host has it, now. No margin, no settle time, no hold: with the
-- native switch on nothing but these writes changes the building, so there is nothing to wait for.
local function evalExact(st, k, H, e)
  if not H.full then return end                            -- the host's complete building has not arrived yet
  local inv = invOf(e.b)
  for g, want in pairs(H.g) do
    local d = want - (inv[g] or 0)
    if H.new[g] then H.new[g] = nil; seen("stock", d, 0) end
    if d ~= 0 then st.ops[#st.ops + 1] = { e = e, k = k, g = g, want = want, d = d, exact = true } end
  end
  for g, have in pairs(inv) do
    if H.g[g] == nil then st.ops[#st.ops + 1] = { e = e, k = k, g = g, want = 0, d = -have, exact = true } end
  end
end

-- lane 42: a rival's site or upgrade (not finished, or being upgraded): only his own settings (the rival rules: build
-- priority, fuel setting), as the host has them, at once, as plain values (the construction panel's own priority
-- arrows write buildPriority the same way, coop_town.lua PRIO). Only a building that is still in this copy's building
-- list (byKey found it there), still that building (same) and still in a region is touched: a demolished building
-- stays a valid object for a while on a friend, without a region (the crash of 2026-11-13).
-- lane 71: a site the sites module paused itself on this copy (its fallback without the native switch: coop_sites.lua
-- B.mine) keeps its pause: the sleep rule must not undo it
local function sitesPaused(k) local B = rawget(C, "sites"); return B ~= nil and type(B.mine) == "table" and B.mine[k] ~= nil end
local function rivalSiteRules(st, k, H, e)
  if not (F.on.values and next(H.v) ~= nil and same(e)) then return end
  local b = e.b
  local okR, inGame = pcall(function() return valid(b.Region) end)
  if not (okR and inGame) then return end
  local paused = sitesPaused(k)
  for code, want in pairs(H.v) do
    local R = RULE[code]
    if R and R.rival and R.on ~= false and not (paused and R.set == "sleep") then
      local cur = b[R.p]; if R.k == "b" then cur = cur and 1 or 0 end      -- (lane 71: a switch rule, sleep, on a site too)
      if type(cur) == "number" and cur ~= want then
        local ok = pcall(setRule, b, R, want)
        local back = b[R.p]; if R.k == "b" then back = back and 1 or 0 end
        if ok and back == want then bump("valFix"); bump("fix_" .. code .. "_site") else bump("err") end
      end
    end
  end
end

local function evalBuilding(st, k)
  local H = F.host.b[k]; if not H or H.storage then return end
  local e = byKey(k)
  if not e then bump("noBuilding"); st.miss = true; return end
  local b = e.b
  if st.exact then evalExact(st, k, H, e) end              -- stock of every building, sites and piles too; below: the rule values
  if e.dump then return end
  local clock, paused = st.clock, st.paused
  -- finished and not burning: read on every 4th pass here, and again right before anything is written
  if e.live == nil or paused or st.n % 4 == 0 then e.live = liveNow(e) end
  e.upg = nil
  if not e.live then
    if e.rival and st.exact then rivalSiteRules(st, k, H, e) end         -- lane 42: a rival's site or upgrade: his own settings
    if not (st.exact and upgNow(e)) then return end                       -- lane 42: a house being upgraded: its house values below
    e.upg = true
  end
  local h = heldBy(e, clock)
  if h then
    bump("held")
    if F.heldSaid[k] ~= h.at then
      F.heldSaid[k] = h.at
      log("held %s: the local player's %s was %.2f s ago; the host's values (%.2f s old) wait", k, tostring(h.act), clock - h.at, clock - (H.t or clock))
    end
    return
  end
  -- A building where nothing differed on 6 looks in a row and nothing new came from the host is looked at only
  -- every 4th pass (reading is what costs), until something differs again; never while paused.
  local fresh = H.fresh; H.fresh = nil
  if not fresh and not paused and not st.quick and H.quiet >= 6 and (st.n + H.phase) % 4 ~= 0 then bump("skipped"); return end
  local differs = false
  if F.on.stock and not st.exact and not e.store and not e.rival and not e.camp and H.full then   -- (camp: lane 42)
    local inv = invOf(b)
    for g, want in pairs(H.g) do
      local d = want - (inv[g] or 0)
      local margin = math.max(F.cfg.stockMargin, math.floor(want * F.cfg.stockPct))
      if d ~= 0 then differs = true end
      if H.new[g] then H.new[g] = nil; seen("stock", d, margin) end
      if due(H.since, g, d, margin, F.cfg.settle, clock, paused) then st.ops[#st.ops + 1] = { e = e, k = k, g = g, want = want, d = d } end
    end
    for g, have in pairs(inv) do
      if H.g[g] == nil then
        differs = true
        if due(H.since, g, -have, F.cfg.stockMargin, F.cfg.settle, clock, paused) then st.ops[#st.ops + 1] = { e = e, k = k, g = g, want = 0, d = -have } end
      end
    end
  end
  -- the rule values: when the host sent new ones, while one waits out its settle time, every 3rd pass, and paused
  if F.on.values and next(H.v) ~= nil and (fresh or paused or next(H.sinceV) ~= nil or st.n % 3 == 0) then
    for code, want in pairs(H.v) do
      local R = RULE[code]
      if R and R.on ~= false and not (R.set == "sleep" and sitesPaused(k)) then
        local cur = b[R.p]; if R.k == "b" then cur = cur and 1 or 0 end
        if type(cur) == "number" then
          local d = want - cur
          if d ~= 0 then differs = true end
          if H.new[code] then H.new[code] = nil; seen("val", d, R.margin) end
          -- lane 42: in exact mode the host's value is written at once (no margin, no settle time)
          local mg, stl = R.margin, R.settle; if st.exact and not R.daily then mg, stl = 0, 0.0 end
          -- counted once per value the host sent: its lower value came before this copy's own day change (the case
          -- that ran a day ahead), or its higher one after it (harmless)
          if st.exact and R.daily and d ~= 0 and math.abs(d) <= mg and H.sinceV[code] == nil then bump(d < 0 and "val_dayHeldLower" or "val_dayHeldHigher") end
          if due(H.sinceV, code, d, mg, stl, clock, paused) then
            -- (lane 42: a house being upgraded gets its house values too; a rival's own settings then go by rivalSiteRules)
            e.live = liveNow(e); local can = e.live or (e.upg and not R.rival and upgNow(e))
            if not can and not e.upg then return end
            if can then
            setRule(b, R, want)                                  -- (lane 42: activeOxen through the game's own function)
            local back = b[R.p]; if R.k == "b" then back = back and 1 or 0 end
            if back ~= want and R.set then bump("setShort_" .. code)   -- lane 42: the game kept fewer (no free ox): looked at again next pass
            elseif back ~= want then R.on = false; bump("err"); log("rule %s switched off: the write did not stick (%s, wanted %s)", R.p, tostring(back), tostring(want))
            else bump("valFix"); bump("fix_" .. code); flip(k .. ":" .. code, d, clock); if F.cfg.verbose then log("value %s %s %s -> %s", k, R.p, tostring(cur), tostring(want)) end end
            end
          end
        end
      end
    end
  end
  if differs then H.quiet = 0 else H.quiet = H.quiet + 1 end
end

-- storage buildings: only the goods the region rule does not cover, from the world module's store of the host's values
local function evalStorage(st)
  local W = C.world; local X = F.idx
  if not (F.on.storeExtra and W and W.fr and W.fr.bld and X) then return end
  local trade = tradeable(F.S)
  for k, E in pairs(W.fr.bld) do
    local e = X.map[k]
    if e and e.store and not e.dup and not e.dump and E.full and partnerOk(e) and not heldBy(e, st.clock) then
      local H = F.host.b[k]; if not H then H = { g = {}, v = {}, since = {}, sinceV = {}, new = {}, storage = true }; F.host.b[k] = H end
      local inv = invOf(e.b)
      for g, want in pairs(E.g) do
        if not trade[g] and due(H.since, g, want - (inv[g] or 0), F.cfg.stockMargin, F.cfg.settle, st.clock, st.paused) then
          st.ops[#st.ops + 1] = { e = e, k = k, g = g, want = want, d = want - (inv[g] or 0), plain = true }
        end
      end
      for g, have in pairs(inv) do
        if not trade[g] and E.g[g] == nil and due(H.since, g, -have, F.cfg.stockMargin, F.cfg.settle, st.clock, st.paused) then
          st.ops[#st.ops + 1] = { e = e, k = k, g = g, want = 0, d = -have, plain = true }
        end
      end
    end
  end
end

local function put(b, g, d) b:addToInventory({ Type = g, amt = d }) end

-- one correction. The difference is read again (ticks have passed since it was planned).
local function doOp(op, clock)
  local e = op.e
  if not same(e) then bump("stale"); return end
  local b = e.b
  if op.exact then                                          -- exact mode: the amount itself, with the game's own addToInventory
    local have = stockOf(b, op.g); local d = op.want - have
    if d == 0 then return end
    put(b, op.g, d)
    bump("exactFix"); bump("exactUnits", math.abs(d)); bump("stockFix"); bump("stockUnits", math.abs(d))
    local now = stockOf(b, op.g)
    if now ~= op.want then
      local id = op.k .. ":" .. op.g
      bump("stockRefused")
      if not F.refused[id] then F.refused[id] = true; log("exact stock %s good %d: asked %+d, went from %d to %d (host %d)", op.k, op.g, d, have, now, op.want) end
    end
    if F.cfg.verbose then log("exact stock %s good %d %+d (host %d)", op.k, op.g, d, op.want) end
    return
  end
  if not op.plain then e.live = liveNow(e); if not e.live then return end end
  local have = stockOf(b, op.g); local d = op.want - have
  if d == 0 then return end
  local moved = 0
  if op.plain or not tradeable(F.S)[op.g] then
    put(b, op.g, d); moved = d
  else
    local P = F.idx.store[e.reg]
    if not P or #P == 0 then bump("noStorage"); return end
    if d < 0 then
      -- too many here: to the storage building of the region that already holds most of this good
      local best, bestN
      for _, p in ipairs(P) do
        if partnerOk(p) then local n = stockOf(p.b, op.g); if not best or n > bestN then best, bestN = p, n end end
      end
      if not best then bump("noStorage"); return end
      put(b, op.g, d); put(best.b, op.g, -d); moved = d
    else
      local left = d
      for _, p in ipairs(P) do
        if left <= 0 then break end
        if partnerOk(p) then
          local n = stockOf(p.b, op.g)
          if n > 0 then local take = math.min(n, left); put(p.b, op.g, -take); put(b, op.g, take); left = left - take end
        end
      end
      moved = d - left
      if left > 0 then bump("stockWait", left) end      -- storage has none: the region rule grants what the region lacks
    end
  end
  if moved ~= 0 then
    bump("stockFix"); bump("stockUnits", math.abs(moved)); if math.abs(moved) <= 2 then bump("stockSmall") end
    bump("fixT_" .. e.t)
    flip(op.k .. ":" .. op.g, moved, clock)
    local now = stockOf(b, op.g)
    if now ~= have + moved then
      local id = op.k .. ":" .. op.g
      bump("stockRefused")
      if not F.refused[id] then F.refused[id] = true; log("stock %s good %d: asked %+d, went from %d to %d", op.k, op.g, moved, have, now) end
    end
    if F.cfg.verbose then log("stock %s good %d %+d (host %d)", op.k, op.g, moved, op.want) end
  end
end

-- st.quick: only the buildings the host has just sent new values for (a large difference is then corrected within a
-- fraction of a second); everything else is the business of the full pass
local function friendPassJob(st)
  if not st.keys then
    st.keys = {}
    if st.quick then
      for k in pairs(F.dirty) do st.keys[#st.keys + 1] = k end
      st.n = 1                                               -- (not a multiple of 3 or 4: a quick pass reads nothing it need not)
    else
      for k, H in pairs(F.host.b) do if not H.storage then st.keys[#st.keys + 1] = k end end
      F.passNo = (F.passNo or 0) + 1; st.n = F.passNo
    end
    F.dirty = {}
    st.i = 0; st.ops = {}; st.clock = os.clock(); st.paused = A.isPaused() and true or false
    st.exact = F.exact == true
    return false
  end
  if not st.plan then
    st.i = st.i + 1
    local k = st.keys[st.i]
    if k then
      local ok, err = pcall(evalBuilding, st, k)
      if not ok then fail("apply " .. k, err) end
      return false
    end
    -- (exact mode: storage buildings come complete from the host like every other building; nothing to do here)
    if not st.exact and not st.quick and (st.paused or st.n % 3 == 0) then local ok, err = pcall(evalStorage, st); if not ok then fail("storage", err) end end
    -- what is too much goes to storage first, so that what is short can come out of storage in the same pass
    table.sort(st.ops, function(a, b) return a.d < b.d end)
    st.plan = true; st.j = 0
    if st.miss then needIndex(st.clock, true) end
    return false
  end
  st.j = st.j + 1
  local op = st.ops[st.j]
  if not op then bump(st.quick and "quickPasses" or "passes"); return true end
  local ok, err = pcall(doOp, op, st.clock)
  if not ok then fail("write " .. op.k .. " good " .. op.g, err) end
  return false
end

-- ---------------------------------------------------------------- friend: exact mode (the native switch GOODS)
-- Every building of the lord is registered with the DLL once per world by a write of amount 0 through the game's own
-- addToInventory: the DLL remembers the building as it is at that moment and from then on puts the game's own
-- changes back. (The DLL also takes in a building of the lord by itself the first time the game changes it; the
-- registration here comes before any change.) A building per step.
local function regJob(st)
  local X = F.idx; if not X or not F.exact then return true end
  if not st.list then st.list = X.list; st.i = 0; st.n = 0; return false end
  st.i = st.i + 1
  local e = st.list[st.i]
  if not e then
    if st.n > 0 then bump("registered", st.n); log("exact mode: %d building(s) registered with the native switch", st.n) end
    return true
  end
  if valid(e.b) then
    local a = addr(e.b)
    if a and not F.regd[a] then
      local ok, err = pcall(put, e.b, 16, 0)
      if ok then F.regd[a] = true; st.n = st.n + 1 else fail("register " .. e.k, err) end
    end
  end
  return false
end
-- the host's entry for a building of this copy (its name, or a neighbour within 10 cm: a rounding edge)
local function hostHas(e)
  if F.host.b[e.k] then return true end
  for dx = -1, 1 do for dy = -1, 1 do
    if F.host.b[string.format("%d@%d,%d", e.t, e.x + dx, e.y + dy)] then return true end
  end end
  return false
end
-- Piles (what a demolished building leaves, type 88). With the switch on a pile never empties by itself here, so it
-- must go when the host's is gone: when the host says "no longer sent" for it, and when the host has not named it
-- for cfg.pileWait seconds although its lines arrive. It is emptied and removed by the game's own routines (native).
local function pilesStep(S, clock)
  local X = F.idx; if not X then return end
  local P = patch(); if not (P and P.pilegone) then return end
  for _, e in ipairs(X.list) do
    if e.dump and not e.dup and valid(e.b) and same(e) then
      local seenAt = F.dumpSeen[e.k]; if not seenAt then seenAt = clock; F.dumpSeen[e.k] = clock end
      local why
      if F.pileGone[e.k] then why = "the host's pile is gone"
      elseif not hostHas(e) and clock - seenAt >= F.cfg.pileWait and clock - (F.exactAt or clock) >= F.cfg.pileWait and clock - (F.t.lineIn or -1e9) < 3.0 then
        why = string.format("the host has not named it for %.0f s", clock - seenAt)
      end
      if why then
        local ok, msg = P.pilegone(e.b)
        F.pileGone[e.k] = nil; F.dumpSeen[e.k] = nil
        bump(ok and "pilesGone" or "pilesFailed")
        log("exact mode: pile %s removed here (%s): %s", e.k, why, tostring(msg))
        needIndex(clock, true)
      end
    end
  end
  for k, t in pairs(F.pileGone) do if clock - t > 60.0 then F.pileGone[k] = nil end end
end

-- ---------------------------------------------------------------- friend: livestock
-- An animal the host has and this copy lacks is made with the engine's own SpawnLivestock beside one of its kind
-- (measured: the region's count rises at once; an ox gets a home by itself, a chicken stays without one). One too
-- many is removed with the engine's own destroyUnit (measured: the count falls, no dead entry stays in any
-- building's animal list): first an animal this module made, else one of that kind that no workplace, no pasture
-- and no task holds. One animal per kind per cfg.liveSettle, and only when the difference has lasted that long.
local function animals(S, r, role)
  local t = {}; local ra = addr(r); local arr = S.eng.unitArr
  for i = 1, #arr do
    local u = un(arr[i])
    if valid(u) then
      local ok, hit = pcall(function() return u.currentUnitRole == role and addr(u.currentRegion) == ra and not u.dead end)
      if ok and hit then t[#t + 1] = u end
    end
  end
  return t
end
local function liveOne(S, r, k, role, have, n, clock)
  local list = animals(S, r, role)
  if n > have then
    local pos
    if list[1] then local p = list[1].realPos; pos = { X = p.X + 150.0, Y = p.Y + 0.0, Z = p.Z + 0.0 }
    else
      local X = F.idx; local e = X and X.list[1]
      if e and valid(e.b) then local l = e.b:K2_GetActorLocation(); pos = { X = l.X + 300.0, Y = l.Y + 0.0, Z = l.Z + 0.0 } end
    end
    if not pos then return end
    local ok, u = pcall(function() return S.eng:SpawnLivestock(role, pos, r) end)
    if ok and valid(u) then
      F.made[#F.made + 1] = { u = u, role = role, k = k }; bump("liveMade")
      log("livestock %s kind %d: %d here, %d on the host: one made", k, role, have, n)
    else bump("liveFailed"); log("livestock %s kind %d: could not be made (%s)", k, role, tostring(u)) end
  elseif F.on.livestockRemove then
    local victim
    for i = #F.made, 1, -1 do
      local m = F.made[i]
      if not valid(m.u) then table.remove(F.made, i)
      elseif not victim and m.role == role and m.k == k then victim = m.u; table.remove(F.made, i) end
    end
    if not victim then
      for i = #list, 1, -1 do
        local u = list[i]
        local ok, free = pcall(function() return not valid(u.animalAssignedTo) and not valid(u.chosenPasture) and #u.Tasks == 0 end)
        if ok and free then victim = u; break end
      end
    end
    if not victim then bump("liveNoVictim"); return end
    local ok, e = pcall(function() S.eng:destroyUnit(victim) end)
    if ok then bump("liveRemoved"); log("livestock %s kind %d: %d here, %d on the host: one removed", k, role, have, n)
    else bump("liveFailed"); log("livestock %s kind %d: could not be removed (%s)", k, role, tostring(e)) end
  end
end
local function liveApply(S, clock)
  local T = C.town
  for _, R in ipairs(liveRegions(S, F.exact == true)) do
    local want = F.host.a[R.k]
    local heldAt = T and T.rkey and F.holdR[T.rkey(R.r)]
    -- the count per kind (13 calls) only when the totals differ, a difference is being waited out, or 30 s have passed
    local look = want and not (F.on.hold and heldAt and clock - heldAt < F.cfg.hold)
    if look then
      local wantTot = 0; for _, n in pairs(want) do wantTot = wantTot + n end
      local pending = false; for id in pairs(F.liveSince) do if id:sub(1, #R.k + 1) == R.k .. ":" then pending = true end end
      if R.r:getTotalLivestockCount() == wantTot and not pending and clock - (F.liveFull[R.k] or -1e9) < 30.0 then look = false end
    end
    if look then
      F.liveFull[R.k] = clock
      local have = liveCounts(R.r)
      for role = ROLE_MIN, ROLE_MAX do
        if have[role] then
          local n = want[role] or 0; local id = R.k .. ":" .. role
          if n == have[role] then F.liveSince[id] = nil
          else
            F.liveSince[id] = F.liveSince[id] or clock
            if clock - F.liveSince[id] >= ((R.rival and F.exact) and F.cfg.rivalLiveSettle or F.cfg.liveSettle) then   -- lane 42: a rival town 2 s
              F.liveSince[id] = clock
              liveOne(S, R.r, R.k, role, have[role], n, clock)
            end
          end
        end
      end
    end
  end
end

-- family marks: a family is its place in the region's list (the rule of the whole mod); a mark is written only when
-- the family at that place lives in the same home as on the host, and only when it differed on two looks in a row
local function friendFamJob(st)
  if not st.regs then st.regs = liveRegions(F.S, F.exact == true); st.ri = 1; st.i = 0; return false end   -- lane 42: rival towns too (exact mode)
  local R = st.regs[st.ri]; if not R then return true end
  local M = F.host.m[R.k]
  if not M or not valid(R.r) then st.ri = st.ri + 1; st.i = 0; return false end
  local fams = R.r.workerFamilies
  st.i = st.i + 1
  if st.i > #fams then st.ri = st.ri + 1; st.i = 0; return false end
  local i = st.i; local want = M[i]; if not want then return false end
  local f = fams[i]
  local home = "-"; local h = f.familyHome
  if valid(h) then local ok, hk = pcall(keyOf, h); if ok then home = hk end end
  if home ~= want.home then bump("famOtherHome"); return false end
  local cs = f.ConsumptionStatus
  for j, p in ipairs(FAM) do
    local w = want.v[j]
    if w then
      local cur = cs[p]; local isB = type(cur) == "boolean"; if isB then cur = cur and 1 or 0 end
      local id = R.k .. ":" .. i .. ":" .. p
      if type(cur) == "number" and cur ~= w then
        -- lane 42: exact mode: on the first look. (lane 64) ... but a difference of one waits 3 s for this copy's
        -- own day step (F.dayRule): the marks are counted by each copy's daily step too (hunger and cold go down a
        -- day without food or fuel, sickness and an injury run out by days).
        local go
        if F.exact then go = F.dayRule(F.famDay, id, w - cur, os.clock(), st.paused); if not go then bump("fam_dayHeld") end
        else go = st.paused or F.famSince[id] end
        if go then
          F.famSince[id] = nil
          if isB then cs[p] = (w == 1) else cs[p] = w end
          local back = f.ConsumptionStatus[p]; if type(back) == "boolean" then back = back and 1 or 0 end
          if back == w then bump("famFix"); if F.cfg.verbose then log("family %s %d %s %s -> %s", R.k, i, p, tostring(cur), tostring(w)) end
          else F.on.families = false; bump("err"); log("item families switched off: %s of family %d did not take %s (%s)", p, i, tostring(w), tostring(back)) end
        else F.famSince[id] = st.clock end
      else F.famSince[id] = nil; F.famDay[id] = nil end
    end
  end
  return false
end

-- lane 39: the workers of a rival's buildings, as the host has them. A building whose families differ from the host's
-- on two looks at least a second apart (a change on the host reaches this copy a moment later, and this copy's own
-- game may still be moving a family) gets the host's list with the town module's own fixFamilies (the game's
-- unassignFamily / assignFamily / reassignFamily, as for the player's own buildings).
local function workersOf(b)
  local ids = {}; local a = b.assignedFamilyIDs
  for j = 1, #a do local v = a[j]; if type(v) ~= "number" then v = un(v) end; v = math.tointeger(tonumber(v)); if v then ids[#ids + 1] = v end end
  table.sort(ids)
  return ids
end
local function friendWorkers(clock)
  local T = C.town; if not (T and T.fixFamilies) then return end
  F.wSince = F.wSince or {}
  for k, Wt in pairs(F.hostW or {}) do
    local e = byKey(k)
    if e and e.rival and same(e) then
      local cur = workersOf(e.b)
      local curS = #cur > 0 and table.concat(cur, ",") or "-"
      local act = tonumber(e.b.numActiveWorkerFamilies) or -1
      if curS == Wt.ids and act == Wt.act then F.wSince[k] = nil
      elseif F.wSince[k] and clock - F.wSince[k] >= F.cfg.rivalWorkWait then   -- lane 42: 0.5 s (was 1 s)
        F.wSince[k] = nil
        -- the number of families the building wants (the rival's own setting on the host): without it this copy's
        -- game fills the place again at once (seen: a building the host's rival keeps empty got a family every 2 s)
        if act ~= Wt.act and Wt.act then pcall(function() e.b.numActiveWorkerFamilies = Wt.act end); bump("wActive") end
        local want = {}; if Wt.ids ~= "-" then for x in Wt.ids:gmatch("[^,]+") do want[#want + 1] = math.tointeger(tonumber(x)) end end
        local ok, r = pcall(T.fixFamilies, e.b, want)
        bump(ok and r == "ok" and "wFix" or "wFail")
        if not (ok and r == "ok") or (F.stats.wFix or 0) <= 20 then log("workers of %s set to the host's %s (were %s): %s", k, Wt.ids, curS, tostring(ok and r or ("error " .. tostring(r)))) end
      elseif not F.wSince[k] then F.wSince[k] = clock end
    end
  end
end

-- lane 42: the host's market goods of a house to the native DIST (coop_patch.lua P.distSet), which writes them at once
-- and again right after each run of the game's own distribution on this copy. Only a house that is in this copy's
-- building list, still that building and still in a region; everything again when DIST was switched on anew.
local function friendDist()
  local Pt = patch(); if not (Pt and Pt.distOn and Pt.distOn()) then return end
  if F.dGen ~= Pt.dGen then F.dGen = Pt.dGen; for k in pairs(F.hostD) do F.dDirty[k] = true end end
  for k in pairs(F.dDirty) do
    local e = byKey(k)
    if not e then F.dDirty[k] = nil
    elseif same(e) then
      local okR, inGame = pcall(function() return valid(e.b.Region) end)
      if okR and inGame then
        local a = addr(e.b)
        if a and Pt.distSet(a, F.hostD[k]) then bump("distSet") end
      end
      F.dDirty[k] = nil
    end
  end
end

-- ---------------------------------------------------------------- friend: store the host's lines
local function onLine(S, w)
  local sub = w[4]; local clock = os.clock()
  if sub == "B" then
    for ent in (w[5] or ""):gmatch("[^;]+") do
      local k, rest = ent:match("^(%d+@%-?%d+,%-?%d+)(.*)$")
      if k then
        if rest == "-" then
          F.host.b[k] = nil; F.dirty[k] = nil
          if k:sub(1, 3) == "88@" then F.pileGone[k] = clock end      -- the host's pile is gone (exact mode: pilesStep)
        else
          local full = rest:sub(1, 1) == "!"; local body = rest:match("|(.*)$") or ""
          local H = F.host.b[k]
          if not H or H.storage then H = { g = {}, v = {}, since = {}, sinceV = {}, new = {}, quiet = 0, phase = math.random(0, 3) }; F.host.b[k] = H end
          if full then H.g = {}; H.full = true end
          H.t = clock; H.fresh = true; F.dirty[k] = true
          for code, val in body:gmatch("(%w+)=(%-?[%d%.]+)") do
            local g = tonumber(code); local v = tonumber(val)
            if v then
              v = math.tointeger(v) or v
              if g then H.g[g] = v; H.new[g] = true else H.v[code] = v; H.new[code] = true end
              bump("items")
            end
          end
          -- lane 41 (scene module): this stock is written here soon; the friend's own shown goods follow it
          if body ~= "" then local Qs = rawget(C, "scene"); if Qs and Qs.stockSeen then pcall(Qs.stockSeen, k) end end
        end
      end
    end
  elseif sub == "D" then                                    -- lane 42: a house's market goods (written by the native DIST)
    F.hostD = F.hostD or {}; F.dDirty = F.dDirty or {}
    for k, d in (w[5] or ""):gmatch("(%d+@%-?%d+,%-?%d+)=([%d:,%-]+)") do F.hostD[k] = d; F.dDirty[k] = true end
    F.t.dist = -1e9                                         -- handed over on the next tick
  elseif sub == "W" then                                    -- lane 39: the workers of a rival's buildings
    F.hostW = F.hostW or {}
    for k, ids, act in (w[5] or ""):gmatch("(%d+@%-?%d+,%-?%d+)=([%d,%-]+)/(%d+)") do F.hostW[k] = { ids = ids, act = tonumber(act), t = clock } end
    F.t.wk = -1e9                                           -- looked at on the next tick
  elseif sub == "L" then
    F.hostL = F.hostL or {}
    for k, v in (w[5] or ""):gmatch("(%d+@%-?%d+,%-?%d+)=(%-?%d+)") do F.hostL[k] = tonumber(v) end
    F.t.lv = -1e9                                           -- apply at once
  elseif sub == "X" then
    local v = w[5] == "1"
    if F.hostExact ~= v then log("the host %s", v and "sends every building's stock (exact mode)" or "no longer sends every building's stock") end
    setHostExact(v); F.t.xSilent = 0
  elseif sub == "A" then
    local k = w[5]; if not k then return end
    local t = {}
    for role, n in (w[6] or ""):gmatch("(%d+)=(%d+)") do t[tonumber(role)] = tonumber(n) end
    F.host.a[k] = t
  elseif sub == "M" then
    local k = w[5]; if not k then return end
    local M = F.host.m[k]; if not M then M = {}; F.host.m[k] = M end
    for ent in (w[6] or ""):gmatch("[^;]+") do
      local parts = {}; for x in ent:gmatch("[^:]+") do parts[#parts + 1] = x end
      local i = tonumber(parts[1])
      if i and #parts >= 2 + #FAM then
        local v = {}; for j = 1, #FAM do v[j] = tonumber(parts[1 + j]) end
        M[i] = { v = v, home = parts[2 + #FAM] }
      end
    end
  else bump("unknown") end
end

-- this copy's exact mode follows the host's word and the native switch (called each tick, and at once when "F X 1"
-- arrives: see setHostExact)
exactSwitch = function(clock)
  local ex = friendExact()
  if ex ~= F.exact then
    F.exact = ex
    if ex then
      F.regd = {}; F.exactAt = clock; F.dumpSeen = {}
      for _, H in pairs(F.host.b) do if H.storage then H.storage = nil; H.full = nil end end   -- (entries the storage rule made for itself)
      log("exact mode ON: the native switch holds every building's stock; amounts are written exactly as the host has them")
    else log("exact mode OFF: back to margin, settle time and moving goods (host exact: %s)", tostring(F.hostExact)) end
    if F.t then F.t.apply = 0; F.t.reg = 0 end
  end
  return ex
end

local function friendTick(S, clock)
  if rawget(C, "hold") then return end                     -- a join or repair is loading a save
  local cfg = F.cfg
  wrapTown()
  -- exact mode: on while the host sends every building's stock AND the native switch is on in this copy.
  -- The host repeats "F X 1" every cfg.exactEvery s; when it has not come for cfg.exactStale s the host is taken to
  -- be gone and the switch is released (coop_patch switches GOODS off when P.hostExact is no longer true).
  -- The silence is counted in this copy's own ticks, at most a second per tick: when this copy itself stood still
  -- for a while (a long console call, a hitch) the host's lines are waiting to be read and that is not silence.
  F.t.xSilent = (F.t.xSilent or 0) + math.min(math.max(clock - (F.t.xTick or clock), 0), 1.0); F.t.xTick = clock
  if F.hostExact == true and F.t.xSilent > cfg.exactStale then
    log("nothing from the host for %.0f s: exact mode is released, this copy's own game moves its stock again", F.t.xSilent)
    setHostExact(nil)
  end
  local ex = exactSwitch(clock)
  if ex and F.idx and clock - (F.t.idxN or 0) >= cfg.exactIndexAge then        -- a new building: seen within a second
    F.t.idxN = clock
    local okN, n = pcall(function() return #S.eng.buildingArr end)
    if okN and n ~= F.idx.n then needIndex(clock, true) end
  end
  needIndex(clock, false)
  if ex and F.idx and (F.regIdx ~= F.idx or clock - (F.t.reg or 0) >= 5.0) then
    if addJob("register", regJob, {}) then F.regIdx = F.idx; F.t.reg = clock end
  end
  if ex and clock - (F.t.piles or 0) >= 1.0 then F.t.piles = clock; timed("piles", pilesStep, S, clock) end
  if clock - F.t.prune >= 2.0 then
    F.t.prune = clock
    local keep = {}; for _, h in ipairs(F.holds) do if clock - h.at < 10.0 then keep[#keep + 1] = h end end
    F.holds = keep
    for k, t in pairs(F.holdR) do if clock - t > 10.0 then F.holdR[k] = nil end end
  end
  if (F.on.stock or F.on.values) and F.idx and next(F.host.b) ~= nil then
    if clock - F.t.apply >= cfg.applyEvery then
      if addJob("friendPass", friendPassJob, {}) then F.t.apply = clock; F.t.quick = clock end
    elseif next(F.dirty) ~= nil and clock - F.t.quick >= cfg.quickEvery then
      if addJob("friendPass", friendPassJob, { quick = true }) then F.t.quick = clock end
    end
  end
  if F.on.livestock and next(F.host.a) ~= nil and clock - F.t.live >= cfg.liveEvery then F.t.live = clock; timed("friendLive", liveApply, S, clock) end
  if F.on.levels and F.idx and F.hostL and next(F.hostL) ~= nil and clock - (F.t.lv or -1e9) >= 1.0 then F.t.lv = clock; timed("friendLevels", friendLevels, clock) end
  if ex and F.on.dist and F.idx and F.hostD and next(F.hostD) ~= nil and clock - (F.t.dist or -1e9) >= 0.25 then F.t.dist = clock; timed("friendDist", friendDist) end   -- lane 42
  if ex and F.on.rivalWorkers and F.idx and F.hostW and next(F.hostW) ~= nil and clock - (F.t.wk or -1e9) >= 0.5 then F.t.wk = clock; timed("friendWorkers", friendWorkers, clock) end
  if F.on.families and next(F.host.m) ~= nil and clock - F.t.fam >= (F.exact and cfg.exactFamEvery or cfg.famEvery) then   -- lane 42: 1 s in exact mode
    if addJob("friendFam", friendFamJob, { clock = clock, paused = A.isPaused() and true or false }) then F.t.fam = clock end
  end
end

-- ---------------------------------------------------------------- plug-in
-- one line a minute: what was sent or corrected and what it cost (the report's numbers come from these lines)
local function costLine(S, clock)
  local st = F.stats; local dt = clock - F.t.log; F.t.log = clock
  local P = F.prev or {}; local function d(k) return (st[k] or 0) - (P[k] or 0) end
  local ticks = d("ticks")
  local line
  if S.role == "host" then
    line = string.format("host, last %.0f s: %d lines, %d bytes (%.0f B/s, %.2f lines/s), %d passes, %d building entries", dt, d("sent"), d("bytes"), d("bytes") / dt, d("sent") / dt, d("passes"), d("entries"))
  else
    line = string.format("friend, last %.0f s: %d lines in (%d bytes), %d items; stock: %d corrections of %d units (%d of 1 or 2 units), waiting on storage %d; values %d; families %d; livestock +%d -%d; corrections undoing the one before within 20 s: %d (within 3 s: %d); held %d; skipped looks %d; at arrival: stock %d of %d differed (%d over the margin, sum %d units, largest %d), values %d of %d",
      dt, d("in"), d("inBytes"), d("items"), d("stockFix"), d("stockUnits"), d("stockSmall"), d("stockWait"), d("valFix"), d("famFix"), d("liveMade"), d("liveRemoved"), d("flips"), d("flipsFast"), d("held"), d("skipped"),
      d("stock_inDiff"), d("stock_in"), d("stock_inOver"), d("stock_inSum"), st.stock_inMax or 0, d("val_inDiff"), d("val_in"))
    if F.exact then line = line .. string.format("; EXACT mode: %d writes of %d units, %d buildings registered, piles removed %d", d("exactFix"), d("exactUnits"), st.registered or 0, st.pilesGone or 0) end
  end
  if S.role == "host" and F.sentX == true then line = line .. "; exact mode: every building's stock is sent" end
  log("%s | tick: %.3f ms mean over %d ticks, longest %.1f ms | errors %d", line, ticks > 0 and d("tickMs") / ticks or 0, ticks, st.tickMax or 0, st.err or 0)
  st.tickMax = 0; st.stock_inMax = 0
  F.prev = {}; for k, v in pairs(st) do F.prev[k] = v end
end

local function tick(S, clock)
  if S.role ~= "host" and S.role ~= "friend" then return end
  local t0 = os.clock()
  fresh(S)
  F.me = addr(S.p1)
  if not F.me then return end
  if S.role == "host" then hostTick(S, clock) else friendTick(S, clock) end
  local frame = (clock - (F.t.tick or clock)) * 1000; F.t.tick = clock
  runJobs(math.min(F.cfg.budgetMax, math.max(F.cfg.budgetMs, frame * F.cfg.budgetShare)) / 1000)
  local ms = (os.clock() - t0) * 1000
  bump("ticks"); bump("tickMs", ms); if ms > (F.stats.tickMax or 0) then F.stats.tickMax = ms end
  if ms > (F.stats.tickMaxEver or 0) then F.stats.tickMaxEver = ms end
  if clock - F.t.log >= F.cfg.logEvery then
    local okC, eC = pcall(costLine, S, clock)
    if not okC then F.t.log = clock; fail("minute line", eC) end
  end
end

local function onMessage(S, from, kind, w, line)
  if kind ~= "F" then return false end
  if S.role ~= "friend" or from ~= "host" then bump("ignored"); return true end      -- facts run host -> friends only
  local wall = tonumber(w[2])
  if C.stale("host", w) then bump("staleLine"); return true end      -- (lane 62: by the host's own stamps, not by two clocks; coop.lua C.stale)
  fresh(S)
  bump("in"); bump("inBytes", #line)
  F.t.lineIn = os.clock()
  timed("line", onLine, S, w)
  return true
end

-- ---------------------------------------------------------------- console helpers
function F.set(name, v)
  if DEFAULT_ON[name] == nil then return "unknown item " .. tostring(name) end
  F.on[name] = v and true or false
  log("item %s %s", name, F.on[name] and "on" or "off")
  return name .. "=" .. tostring(F.on[name])
end
function F.profile()
  local t = {}
  for name, P in pairs(F.prof) do t[#t + 1] = string.format("%s: %d times, %.0f ms in all (%.3f ms each), longest %.0f ms", name, P.n, P.ms, P.ms / math.max(1, P.n), P.max) end
  table.sort(t)
  return table.concat(t, " | ")
end
function F.status()
  local S = F.S; if not S then return "facts: not attached yet" end
  local on = {}; for k, v in pairs(F.on) do if v then on[#on + 1] = k end end; table.sort(on)
  local st = {}
  for k, v in pairs(F.stats) do st[#st + 1] = k .. "=" .. (type(v) == "number" and (math.tointeger(v) and tostring(math.tointeger(v)) or string.format("%.1f", v)) or tostring(v)) end
  table.sort(st)
  local nb = 0; for _ in pairs(S.role == "host" and F.sent or F.host.b) do nb = nb + 1 end
  local off = {}; for _, R in ipairs(F.rules) do if R.on == false then off[#off + 1] = R.p end end
  local exact = S.role == "host" and (F.sentX == true) or (S.role ~= "host" and F.exact == true)
  return string.format("facts %s role=%s exact=%s (host said %s) buildings=%d jobs=%d rules off=[%s] err=%s | on: %s | %s", F.version, tostring(S.role), tostring(exact), tostring(F.hostExact), nb, #F.jobs, table.concat(off, ","), tostring(F.lastErr), table.concat(on, ","), table.concat(st, " "))
end

C.register("facts", { onWorld = function(S) fresh(S) end, tick = tick, onMessage = onMessage })

-- ---------------------------------------------------------------- lane 40: the fields module
-- coop_x_fields.lua (fields and gardens on the host's word) is loaded from here: main.lua's module list is fixed and
-- this file is loaded after every module it needs.
do
  local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):gsub("\\", "/")
  local chunk, err = loadfile((here:match("^(.*)/[^/]*$") or ".") .. "/coop_x_fields.lua")
  if chunk then
    local ok, r = pcall(chunk)
    if not ok then A.log("fields: coop_x_fields.lua failed: %s", tostring(r)) end
  elseif err and not tostring(err):find("No such file") then A.log("fields: coop_x_fields.lua cannot be read: %s", tostring(err)) end
end

return "coop_facts " .. F.version .. " loaded"
