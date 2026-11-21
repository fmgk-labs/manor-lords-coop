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
--                             (lane 87, exact mode) item cn=0: this building is not finished on the host (with the
--                             keyframe and on change); cn=1: it was finished since the last entry, and the goods of
--                             this entry are those AFTER the finish (sent once, never with a keyframe)
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
  liveFastMake = true,    -- (lane 64, task 64d2) exact mode: a missing animal of the player's own town is made after
                          --   cfg.liveMakeSettle (0.5 s), not cfg.liveSettle (25 s); see liveMakeSettle
  newAtOnce = true,       -- (lane 64, task 64d) exact mode: a new building is put into the list in the tick the native table
                          --   shows it (host: and sent in that tick), not at the next build of the list (see addNew)
  hold = true,            -- the hold after a local action
  exact = true,           -- exact mode: every building's stock, written exactly, when the native switch GOODS can be used
  levels = true,          -- every building's level (SMBuildingMaster.lv) is the host's (lane 24: a burnt house's level is lost in the save)
  rivals = true,          -- lane 39: in exact mode the rival lords' buildings too (stock, house values, fuel setting, levels)
  rivalWorkers = true,    -- lane 39: ... and which families work in each of them (F W)
  dist = true,            -- lane 42: a house's market goods (distributedGoods) as the host has them (F D; native DIST)
  camps = true,           -- lane 42 round two: the stock of bandit camps too, in exact mode (their loot changed on each copy)
  pileFast = true,        -- lane 76: a demolished building's pile comes and goes in the tick the host's word says so (see PILES)
  bar = true,             -- lane 87: the host's entries say "not finished" / "finished now" (cn); a friend finishes its site
                          --   before it writes the goods the host's finish left (see SITES)
  wq = true,              -- lane 87 (cure 3): a site's entry also carries its work fraction of the same tick (wq); a friend
                          --   holds it in the tick it writes that entry's goods (see SITES)
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
  -- (lane 64, task 64d2) THE MAKING SIDE IN THE PLAYER'S OWN TOWN. An animal the host gained and this copy's own game
  -- did not bring stood missing here for the 25 s above (sitting l64d1: a sheep made on the host, its stand-in here
  -- 25.7 s later; the owner's bar is 3 s). In exact mode the player's town now makes a missing animal after
  -- liveMakeSettle, as a rival town does (0.5 s, one more look). An animal this copy's own game brings a moment later
  -- (an order carried to every copy, the same backyard upgrade) raises the count above the host's, and the stand-in is
  -- taken out in that tick (liveWatch, liveTakeBack: lane 76's one owner of a town's count). Only the making side:
  -- an animal too many here keeps the long wait, since the host's word of a death or of an animal gone without a body
  -- (the events module, E AD and E AG) comes first. Switch: Coop.facts.on.liveFastMake = false gives the 25 s again.
  liveMakeSettle = 0.5,
  famEvery = 5.0,         -- family marks are read (host) and judged (friend) this often
  logEvery = 60.0,        -- a line with counts and cost in the log this often
  exactEvery = 10.0,      -- exact mode: the host says "F X 1" this often ...
  exactStale = 30.0,      -- ... and a friend that has not heard it for this long leaves exact mode (its own game takes
                          --     the stock over again, as before): a player whose host is gone must not sit on frozen stock
  pileWait = 20.0,        -- exact mode: a pile the host has not named for this long is removed here
  pileEmpty = 1.5,        -- lane 76, host: an emptied pile is not sent empty for this long (the game removes it at once)
  pileTail = 12,          -- lane 76: a new pile is looked for among this many buildings at the end of the game's list
  exactIndexAge = 1.0,    -- exact mode: the number of buildings is looked at this often (a new building is registered at once)
  -- lane 42: in exact mode a value the host changed must reach a friend within the link's delay (the owner's bar: what
  -- players see is the same on every copy, a second or two apart). The floors and waits above made a friend show the
  -- host's value of 3 to 15 s before (measured: refueled 3 s, family cold 5.6 s, rival sickness never, rival livestock
  -- 15 s, rival workers 2.2 s). In exact mode these are used instead:
  exactValuesEvery = 1.0, -- host: the rule values of houses and of rival buildings are read this often; a friend writes them
                          --   at once (no margin, no settle time)
  exactFamEvery = 0.5,    -- host: family marks read this often (rival towns too); a friend looks as often (lane 76: was 1 s)
  famWait = 0.4,          -- lane 76: a family mark one off the host's is written after this long (was the day rule's 3 s: with the
                          --   host's read every second and the friend's look every second a mark stood 3.8 s and more behind,
                          --   session l76k; lane 64 measured this copy's own day step 0.2 s after the host's)
                          --   (task 76e round 2: 1.0 -> 0.4: session l7i, a rival family's hunger 2.86 s behind; this copy's own
                          --   day step is set back to the host's word in the tick it comes, F.famDayNow, so the wait need only
                          --   cover the 0.2 s by which this copy's day change follows the host's)
  rivalLiveSettle = 0.5,  -- friend: a rival town's livestock (its AI orders on the host only) is made equal after this long
  -- (lane 76) session l76i: a rival town's new animal stood on a friend 4.8 s and more after the host had it (four
  -- times in 18 minutes: "livestock zwei kind 12: 3 here, 4 on the host"). The host read the counts every 5 s, the
  -- friend looked every 5 s and waited 2 s more. In exact mode both now look every exactLiveEvery s (one call a
  -- region; the 13 calls per kind only when a total changed), a rival town waits 0.5 s (one more look) and every
  -- missing animal of a kind is made in that look (at most 4), not one a look.
  exactLiveEvery = 0.5,
  -- (lane 76, task 76e) THE STOCK PATH in exact mode. Sessions l7c to l7e: 3 to 13 stock readings a session came
  -- 3.0 to 3.35 s after the host. legs.py on l7e: host change to host send median 0.69 s (a pass once a second that
  -- sends at its end), send to the friend's write median 0.14 s, worst 1.02 s (a quick pass waits while a full pass
  -- is still being worked through); in the slow moments both copies stalled 0.25 to 0.5 s a tick.
  exactPassEvery = 0.5,   -- host, exact mode: the whole pass this often (was passEvery, 1 s)
  fastHost = true,        -- host, exact mode: a building whose record of the native table changed is sent in that tick
  fastMax = 40,           --   at most this many buildings a tick (the rest go with the pass)
  fastFriend = true,      -- friend, exact mode: a building the host has just sent is written in the tick its line came
  rekey = true,           -- (round 3) exact mode: a building whose type changed in place is renamed in the list at once
  -- ... an animal the host has NOT (one too many here) keeps a long wait: an animal's death comes on the host's own
  -- word (the events module), and this rule must not take one away ahead of it. Before lane 76 it was the 2 s wait
  -- on looks 5 s apart, so 5 s and more; that is kept.
  rivalLoseSettle = 5.0,
  rivalWorkWait = 0.5,    -- friend: a rival building's workers that differ this long get the host's list
}
F.on = F.on or {}
for k, v in pairs(DEFAULT_ON) do if F.on[k] == nil then F.on[k] = v end end
F.cfg = F.cfg or {}
for k, v in pairs(DEFAULT_CFG) do if F.cfg[k] == nil then F.cfg[k] = v end end
F.stats = F.stats or {}
F.unfin = F.unfin or {}                                   -- host (lane 87): names last seen unfinished (set anew per world in fresh)

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
    -- (lane 81) inside the town module's quiet wrapper: its LSW hook (a relative action) must not send this write as the
    -- player's own change
    local T = C.town
    local function q(n) if T and T.quiet then T.quiet(function() b:changeActiveLivestockWorkers(n) end) else b:changeActiveLivestockWorkers(n) end end
    q(want - cur)
    local now = b[R.p]
    if now ~= want and now == want - cur then q(want) end
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
local FAM = { "cold", "sickness", "injured", "hunger", "garments", "footwear", "ale" }   -- (lane 76, task 76f: the last three; session l76k: garments 2 / 1 for over 3 s in a rival town, carried by nothing)
local FAM_OLD = 4         -- a mark after this one that does not take the host's value is left alone; the item stays on   -- (hunger: lane 42 round two, a rival family 1 / 2 in spring, a6) Region.workerFamilies[i].ConsumptionStatus.<field> (injured: lane 36, the friend's own work accident showed 0 / 29)
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
local pileThere, friendPiles, hostOne      -- (lane 76; defined with the piles' fast path; hostOne further down)
local evalExactF, doOpF           -- (lane 76: evalExact and doOp, defined further down, for the piles' fast path)
local put                         -- (the write itself: addToInventory, defined with doOp)
-- lane 76: the timing proof (coop_world.lua, a test tool, off for players) is told of a stock read or write
local function proofNote(b, fromSnap)
  local Wd = rawget(C, "world")
  if Wd and Wd.cfg and Wd.cfg.proof and Wd.proofNote then pcall(Wd.proofNote, b, fromSnap) end
end
-- ... and of a building that is gone (task 76g): the host in the tick it says so, a friend in the tick it removes it
local function proofGone(k)
  local Wd = rawget(C, "world")
  if Wd and Wd.cfg and Wd.cfg.proof and Wd.proofGone then pcall(Wd.proofGone, k) end
end
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
  F.unfin = {}                                            -- host (lane 87): names last seen unfinished (kept through a keyframe)
  F.workDue = {}                                          -- host (lane 87, cure 3): sites whose work moved, for the fast step
  F.hostL = {}; F.lvSaid = {}                             -- friend: the host's building levels
  F.hostW = {}; F.wSince = {}                             -- friend: the host's workers of rival buildings (lane 39)
  F.hostD = {}; F.dDirty = {}; F.dGen = nil               -- friend: the host's market goods of houses (lane 42)
  F.host = { b = {}, a = {}, m = {} }; F.dirty = {}       -- friend: the host's values; stale after a load, dropped
  F.catchMourning = {}; F.rejoining = nil; F.gap0 = S and S.clockGap   -- (the clock gap of before this load: not a measure of this world)
  F.holds = {}; F.holdR = {}; F.heldSaid = {}; F.last = {}; F.made = {}; F.liveSince = {}; F.famSince = {}; F.famDay = {}; F.refused = {}
  F.liveTot = {}; F.liveFull = {}; F.liveSeen = {}; F.liveHold = {}; F.passNo = 0
  F.t = { pass = 0, apply = 0, quick = 0, index = -1e9, live = 0, fam = 0, log = os.clock(), miss = 0, prune = 0 }
  F.wasHold = nil
  -- exact mode: nothing is known of the new world; the host says "F X 1" again with its first complete pass
  F.exact = false; F.sentX = nil; F.regd = {}; F.pileGone = {}; F.dumpSeen = {}; F.exactAt = nil; F.pileWant = {}; F.pileN = nil; F.pileRetry = nil
  setHostExact(nil)
  log("reset for world %d", S.worlds)
end

-- ---------------------------------------------------------------- the lord's buildings (both roles)
-- list of { b, k (name), t (type), x, y, store, res, reg (region address), dump, dup }, a map by name and the storage
-- buildings by region. Built a building per step, every cfg.indexAge seconds.
-- One building's entry, or nil for a building the list does not carry (another lord's when rivals are off, nobody's).
-- (lane 64, task 64d) the build of the list and addNew below make it the same way
local function entryOf(b, lords)
  local op = b.ownerPawn
  local rival, camp = false, false
  if not mine(op) then
    if F.on.rivals and lords and lords[addr(op) or 0] then rival = true
    -- lane 42 round two: a bandit camp's stock (owner B) is carried in exact mode like a rival's, stock only
    elseif F.on.camps and valid(op) and op.isBandit then camp = true
    else return nil end
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
  return e
end
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
        local e = entryOf(b, st.lords); if not e then return end
        local k = e.k
        if st.map[k] then st.map[k].dup = true; e.dup = true else st.map[k] = e end      -- two buildings with one name: neither is written
        st.list[#st.list + 1] = e
        if e.store and e.reg and not e.dump and not e.rival and not e.camp then local L = st.store[e.reg] or {}; st.store[e.reg] = L; L[#L + 1] = e end
      end)
    end
    return false
  end
  local dumps = {}
  for _, e in ipairs(st.list) do if e.dump then dumps[#dumps + 1] = e end end
  F.idx = { list = st.list, map = st.map, store = st.store, t = os.clock(), n = #arr, dumps = dumps, lords = st.lords }
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
-- (lane 76, task 76e round 3) A BUILDING WHOSE TYPE CHANGED IN PLACE (an upgrade that makes another building of it:
-- a rival's storehouse 72 becomes 99, a house that grows). Its name (type@x,y) changes while the object stays. Before,
-- both copies waited for the whole list to be built again (one building per step, behind the running jobs): session
-- l7p, in a slow minute (two frames a second) the host's first line of the new name went 5.4 s after the change and
-- the friend, whose list still had the old name, wrote nothing for 11 s more: its numStoredGeneric stayed at 135 while
-- the host went 135, 134, 133, 134, 135 (one reading a value the host had not had for 3 s). So the entry is renamed in
-- place the moment the new name is seen (the host: its read of the building; the friend: a name the host sent that
-- the list does not have, looked for at the same place). The whole list is still built again afterwards.
local function rekey(e)
  local X = F.idx; if not (X and e and valid(e.b)) then return nil end
  local ok, k, x, y = pcall(keyOf, e.b)
  if not ok or type(k) ~= "string" or k == e.k then return nil end
  -- only a new type AT THE SAME PLACE: a removed building's actor is cleared (type 0 at 0,0) and is not renamed
  if not (e.x and x and math.abs(x - e.x) <= 1 and math.abs(y - e.y) <= 1) then return nil end
  local nt = tonumber(k:match("^(%d+)@")); if not nt or nt <= 0 then return nil end
  if X.map[k] and X.map[k] ~= e then return nil end         -- the new name is taken: the rebuilt list decides
  local old = e.k
  if X.map[old] == e then X.map[old] = nil end
  e.k = k; e.x = x; e.y = y; e.t = A.btype(e.b)
  pcall(function() e.stall = tonumber(e.b.buildingFunction) == 3 or nil end)
  local okS, s = pcall(function() return e.b:isStorageTypeBuilding() end); e.store = okS and s == true
  local okH, h = pcall(function() return e.b:isResidentialBuilding() or e.b.needsRefueling end); e.res = okH and h == true
  e.gone = nil; e.live = nil; e.liveAt = nil; e.upg = nil
  X.map[k] = e
  bump("rekeyed"); log("a building changed its type in place: %s is now %s (renamed in the list at once)", old, k)
  return old
end
F.rekey = rekey
-- (lane 64, task 64d: l64pin20's bw row, sitting l64d8) A NEW BUILDING IN THE LIST IN THE TICK THE NATIVE TABLE SHOWS
-- IT. The list was built again only at the count look (the host: every cfg.indexAge, 5 s; a friend in exact mode every
-- 1 s) and then one building a step: in l64d8 the host's first line for a rival's new building went 1.2 to 5.5 s after
-- it was placed, the friend's list had it 1.0 to 3.6 s after, and a site whose priority the rival's AI set at once
-- (91@9249,7403: 2; 93@9260,7421: 1) stood at the game's own 4 on the friend for 1.25 and 2.10 s. Now an address of the
-- native table's changed records (coop_snap.lua N.takeChanged: a new building is a new record) that the list does not
-- hold is made an entry at once, the way the build makes it (entryOf), and appended; the build of the list still
-- comes as before and replaces the whole list. A name already in the list: the old entry is replaced when it is no
-- longer a building of the list (its object gone, or gone from the list), else both are marked two of one name, as
-- the build does. An address the list does not carry (another owner) is looked at on three changes of its record (an
-- owner that is not final in the first tick gets another look), then not again until the next build.
-- (lane 87's site entry, cn=0 and wq, goes from its first tick on with it: its HW P gives way sooner, as its design
-- says, research/.../lane_s21_87/design_cures.txt.) Off: Coop.facts.on.newAtOnce = false.
local function addNew(X, a)
  if not (F.on.newAtOnce and X and X.list and a) then return nil end
  if not X.byAddr then
    X.byAddr = {}
    for _, e in ipairs(X.list) do local ea = valid(e.b) and addr(e.b); if ea then X.byAddr[ea] = e end end
  end
  if X.byAddr[a] then return nil end
  X.skip = X.skip or {}
  if (X.skip[a] or 0) >= 3 then return nil end
  local N = rawget(C, "snap")
  local b
  pcall(function() local r = N and N.building and N.building(a); if r and N.obj then b = N.obj(r) end end)
  if not (b and valid(b)) then return nil end            -- not this tick's object of that address: the next change says it again
  local okE, e = pcall(entryOf, b, X.lords)
  if not okE or not e then X.skip[a] = (X.skip[a] or 0) + 1; return nil end
  local old = X.map[e.k]
  if old then
    local oldLives = valid(old.b) and not old.gone and addr(old.b) ~= a
    if oldLives then old.dup = true; e.dup = true          -- two buildings with one name: neither is written (as the build)
    else X.map[e.k] = e end                                -- the old one is no building of the list now: the name is the new one's
  else X.map[e.k] = e end
  e.new = true
  X.list[#X.list + 1] = e; X.byAddr[a] = e
  if e.store and e.reg and not e.dump and not e.rival and not e.camp and X.store then local L = X.store[e.reg] or {}; X.store[e.reg] = L; L[#L + 1] = e end
  if e.dump and X.dumps then X.dumps[#X.dumps + 1] = e end
  bump(F.S and F.S.role == "host" and "newAtOnce" or "newFriend")
  return e
end
-- the building with that name on this copy (exact, else a neighbour within 10 cm: a rounding edge), alive and unique
local function byKey(k)
  local X = F.idx; if not X then return nil end
  local e = X.map[k]
  local t, x, y
  if not e then
    t, x, y = parseKey(k); if not t then return nil end
    for dx = -1, 1 do for dy = -1, 1 do
      if not e then e = X.map[string.format("%d@%d,%d", t, x + dx, y + dy)] end
    end end
  end
  if not e and t and F.cfg.rekey then                       -- (task 76e) the same object at that place under its old name
    for _, c in ipairs(X.list) do
      if not c.dup and c.x and math.abs(c.x - x) <= 1 and math.abs(c.y - y) <= 1 and c.t ~= t and valid(c.b) then
        local okT, ct = pcall(A.btype, c.b)
        if okT and ct == t and rekey(c) then e = c; break end
      end
    end
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

-- ---------------------------------------------------------------- PILES, fast (lane 76; both roles, exact mode)
-- Session l76k, two piles of the player's: (1) the host's pile came 0.27 s after the demolition with 2 logs; the
-- friend's pile stood empty 3.4 s (the host's next pass after its list of buildings was built again, then the
-- friend's own list). (2) the host's carriers took the last log and the pile was gone; the friend showed an empty
-- pile for 2.6 s and had it 3.4 s longer than the host. An empty pile is a state the host never shows.
-- Now: both copies look at the end of the game's list of buildings in every tick in which the number of buildings
-- changed or a demolition is under way, and take a new pile into their list at once. The host sends a new pile's
-- complete stock in that tick, never sends an emptied pile's zeros, and says "no longer sent" in the tick its pile is
-- gone. A friend writes a pile's stock in the tick the host's line and its own pile are both there, and removes its
-- pile in the tick the host's word comes.
pileThere = function(e)
  if not valid(e.b) then return false end
  local ok, k = pcall(keyOf, e.b)
  return ok and k == e.k
end
-- new piles at the end of the game's list (a new building is put at the end), taken into this copy's list
local function newPiles(S)
  local X = F.idx; local out = {}
  if not X then return out end
  local arr = S.eng.buildingArr; local n = #arr
  for i = n, math.max(1, n - F.cfg.pileTail + 1), -1 do
    local b = un(arr[i])
    if valid(b) then
      pcall(function()
        if b:GetType() ~= 88 then return end
        local k, x, y = keyOf(b)
        local old = X.map[k]
        if old and valid(old.b) and (addr(old.b) == addr(b) or pileThere(old)) then return end    -- known, or two with one name
        local op = b.ownerPawn
        local rival, camp = false, false
        if not mine(op) then
          if F.on.rivals and X.lords and X.lords[addr(op) or 0] then rival = true
          elseif F.on.camps and valid(op) and op.isBandit then camp = true
          else return end
        end
        local e = { b = b, k = k, t = 88, x = x, y = y, rival = rival or nil, camp = camp or nil, dump = true, store = false, res = false, direct = true }
        e.reg = addr(b.Region)
        X.map[k] = e; X.list[#X.list + 1] = e; X.dumps[#X.dumps + 1] = e
        out[#out + 1] = e
      end)
    end
  end
  return out
end
-- true in a tick in which a new pile may have come: the number of buildings changed, or a demolition was sent or
-- applied here in the last 3 s (coop_x_jobs J.gone marks the building; its pile can come as the building goes)
local function pileLook(S, clock)
  local X = F.idx; if not X then return false end
  local okN, n = pcall(function() return #S.eng.buildingArr end)
  if not okN then return false end
  local look = n ~= F.pileN
  F.pileN = n
  local G = C.goneB
  if not look and G then for _, t in pairs(G) do if clock - t < 3.0 then look = true; break end end end
  return look
end
-- host: a new pile's complete stock goes out in this tick; a pile that is gone is told in this tick
local function hostPiles(S, clock)
  local X = F.idx; if not X or not X.dumps then return end
  if pileLook(S, clock) or F.pileRetry then
    F.pileRetry = nil
    newPiles(S)
  end
  local st = { clock = clock, n = F.passNo or 0, entries = {}, seen = {}, exact = true }
  -- every pile this host has sent: still in the list, and still there? (the list may have been built again since)
  for k in pairs(F.sent) do
    if k:sub(1, 3) == "88@" then
      local e = X.map[k]
      if not e or not pileThere(e) then st.entries[#st.entries + 1] = k .. "-"; F.sent[k] = nil; bump("pileGoneFast"); proofGone(k) end
    end
  end
  for _, e in ipairs(X.dumps) do
    if not e.goneTold then
      if not pileThere(e) then e.goneTold = true
      elseif e.direct and not F.sent[e.k] and not e.dup then
        -- a new pile: sent when its goods are in it (read from the game itself: the native table is of the frame's start)
        local okI, inv = pcall(invOf, e.b)
        if okI and next(inv) ~= nil then
          local ok, err = pcall(hostOne, st, e)
          if not ok then fail("read new pile " .. e.k, err) else bump("pileNewFast") end
        else
          e.seenAt = e.seenAt or clock
          if clock - e.seenAt < 1.0 then F.pileRetry = true end
        end
      end
    end
  end
  if #st.entries > 0 then bump("entries", #st.entries); sendList("F B ", st.entries, ";") end
end
-- friend: the host's stock of pile k is written now (the pile and the host's complete line are both here)
local function pileNow(k, clock)
  local H = F.host.b[k]; if not (H and H.full and F.exact) then return false end
  local X = F.idx; local e = X and X.map[k]
  if not (e and e.dump and not e.dup and pileThere(e)) then return false end
  local st = { ops = {} }
  evalExactF(st, k, H, e)
  for _, op in ipairs(st.ops) do
    local ok, err = pcall(doOpF, op, clock)
    if not ok then fail("write pile " .. k .. " good " .. tostring(op.g), err) end
  end
  if #st.ops > 0 then bump("pileWriteFast"); proofNote(e.b) end
  return true
end
-- friend: new piles are taken in and filled; a pile the host's line named before this copy had it is filled as it comes
friendPiles = function(S, clock)
  local X = F.idx; if not X or not X.dumps then return end
  local look = pileLook(S, clock)
  if look or (F.pileWant and next(F.pileWant) ~= nil) then
    for _, e in ipairs(newPiles(S)) do
      bump("pileSeenFast")
      -- the pile holds what this copy's own game put into it (native rule "pilefree"). It is registered now (a write
      -- of amount 0), so this copy's carriers cannot take from it before the host's stock is written. An empty pile is
      -- not touched (the game's count after a write removes an empty pile).
      -- (task 76e round 2) ALSO when the host's line is here already: a new pile whose goods are the host's gets no
      -- write of its amounts, so without this it was never registered (session l7j, day 361: a rival's new pile
      -- 88@10000,6520 lost a large good on the friend for 0.67 s, a state the host never had)
      local okI, inv = pcall(invOf, e.b)
      if okI and next(inv) ~= nil then
        local a = addr(e.b)
        if a and not F.regd[a] and pcall(put, e.b, 16, 0) then F.regd[a] = true; bump(pileNow(e.k, clock) and "pileRegFastHost" or "pileRegFast") end
      end
    end
  end
  if F.pileWant then
    for k, t in pairs(F.pileWant) do
      if pileNow(k, clock) or clock - t > 5.0 then F.pileWant[k] = nil end
    end
  end
end

-- ---------------------------------------------------------------- SITES (lane 87; exact mode)
-- Run p87a (the player's sites, 7 of 7 finishes): a friend showed its site at HALF a bar for 0.4 to 1.4 s after the
-- host's had finished. The host's game takes the needed goods out of the Inventory at the finish; the stock line
-- with those goods gone was written into the friend's site while that site was still unfinished (its bar is half
-- goods, half work: goods 0, work 1). The host's "built" word (the sites module's B IS) travels apart from the stock.
-- Now the stock line itself says it: an unfinished building's entry carries cn=0, and the entry of the pass that
-- first sees it finished carries cn=1 beside the goods after the finish. A friend finishes its site (the sites
-- module's own finish, B.finishNow) before it writes those goods. cn=1 is sent once, on the host's own change from
-- unfinished to finished, never with a keyframe: a keyframe's "finished" could meet a new job a player has just
-- begun on that building here.
-- Is this building finished on this copy now? From the native building table of this frame (the record the stock
-- comes from: one moment), else, when asked (must), by the reflected read. nil: not known.
local function consHost(b, must)
  local N = rawget(C, "snap")
  if N and N.buildings and N.building and N.buildings() then
    local r = N.building(addr(b) or 0)
    if r then return r.cons == true end
  end
  if not must then return nil end
  local ok, c = pcall(function() return b.Data.constructed end)
  if ok then return c == true end
  return nil
end

-- ---------------------------------------------------------------- host: read and send
-- Reading costs about 25 us per property (measured: 10 ms for 38 buildings each second), so not everything is read
-- on every pass: whether the building is finished and not burning every 4th pass; the rule values every 2 s (their
-- floor); a building whose stock has not changed on 6 passes in a row only every 4th pass (a house, an idle
-- workshop), until it changes again.
hostOne = function(st, e)
  local b = e.b
  local exact = st.exact                                    -- exact mode: the stock of every building, whatever it is
  if e.rival and not exact then return end                  -- lane 39: a rival's building only in exact mode
  if e.camp and not exact then return end                   -- lane 42: a bandit camp's stock only in exact mode
  -- (task 76e) exact mode: a type changed in place is seen at this read (not at every 4th pass) and the entry renamed
  -- at once; the new name goes whole in this line, the old one is told "no longer sent" in the same line
  if exact and F.cfg.rekey and not e.dump and not e.gone then
    local okT, t = pcall(A.btype, b)
    if okT and t ~= e.t then
      local old = rekey(e)
      if old then
        if F.sent[old] then F.sent[old] = nil; st.entries[#st.entries + 1] = old .. "-" end
        st.stale = true                                     -- the whole list is still built again
      end
    end
  end
  if e.store and not e.res and not exact then return end    -- nothing of a plain storage building is sent from here
  local clock = st.clock
  local L = F.sent[e.k]
  -- (lane 76) a pile the game has taken away is not read again: its actor stays readable for a while, cleared
  if e.dump and F.on.pileFast and not pileThere(e) then st.stale = true; return end
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
  -- (lane 87, cure 3) A SITE'S GOODS AND ITS WORK FROM ONE MOMENT. The bar is half goods, half work; the goods went out
  -- in this entry, the work in the values module's HW P (its POLL every 0.5 s), and a friend wrote each in the tick it
  -- came: for up to half a second a pair the host never had at one moment (C4: 13 readings at two decimals in session
  -- l87c). Now a site's entry carries the work fraction of this tick (wq: its bits, a whole number, from a SITEHP POLL
  -- of this tick), and its goods are read through reflection in this same tick (the native table can be up to 0.1 s
  -- older). Finished or not from this moment too (the building's own word): a building the table shows unfinished, or
  -- one last sent unfinished. siteNow: true = a site now, false = finished now (it was a site), nil = not this path.
  local siteNow = nil
  if exact and F.on.bar and F.on.wq ~= false and F.on.stock and not e.dump and F.S and F.S.role == "host" then
    local was = L.v.cn == 0 or F.unfin[e.k] == true
    local tab = consHost(b, false)                          -- the table's word (nil: no table, or not in it)
    if was or tab == false or (tab == nil and not e.live) then
      local okC, c = pcall(function() return b.Data.constructed end)
      if okC and type(c) == "boolean" then siteNow = (c == false) end
    end
  end
  if F.on.stock and (exact or not e.store) then
    local refl = e.direct or siteNow ~= nil
    local inv = refl and invOf(b) or invHost(b); local n0 = #items
    -- (lane 76, task 76h) A building the game has just taken away (demolished) stays readable for a while, cleared:
    -- its list reads empty. Sent as "every good 0" it emptied a friend's building, which a friend still has until
    -- the people module removes it: session l76t, 8 demolitions of a rival's buildings on the host: the friend
    -- showed the building EMPTY for 0.28 to 1.2 s before it was gone there (a state the host never had: the host's
    -- building goes with its goods in it, in one tick). So a building whose goods are all gone at once is looked
    -- at first: still that building at that place? If not, nothing of it is sent; "no longer sent" follows with
    -- the host's next list. (A pile has its own rule above.)
    if not e.dump and L and next(inv) == nil and next(L.g) ~= nil and not pileThere(e) then
      st.stale = true; e.gone = true; bump("goneNotRead"); return
    end
    -- (lane 76) a pile whose last goods were just taken: the game removes it within a moment. Its empty state is not
    -- sent (session l76k: a friend showed the empty pile 2.6 s); "no longer sent" follows in the tick it is gone.
    -- A pile that stays empty for cfg.pileEmpty s is sent empty after all.
    if e.dump and F.on.pileFast and L and next(inv) == nil and next(L.g) ~= nil then
      L.emptyAt = L.emptyAt or clock
      if clock - L.emptyAt < F.cfg.pileEmpty then bump("pileEmptyHeld"); return end
    elseif L then L.emptyAt = nil end
    for g, a in pairs(inv) do if full or L.g[g] ~= a then items[#items + 1] = g .. "=" .. num(a) end end
    if not full then for g in pairs(L.g) do if inv[g] == nil then items[#items + 1] = g .. "=0" end end end
    L.g = inv
    if #items > n0 and not full then L.quiet = 0 else L.quiet = L.quiet + 1 end
    -- lane 41 (scene module): the shown goods follow the stock; a building whose stock changed is read again there
    if #items > n0 then local Qs = rawget(C, "scene"); if Qs and Qs.stockSeen then pcall(Qs.stockSeen, e.k) end end
    -- lane 76 (timing proof, a test tool): the stock row as it is at this read, dated. Every amount a friend writes
    -- is one this pass read, so the host's kept reads then hold every value a friend can show.
    if #items > n0 then proofNote(b, not refl) end         -- (task 76e: and the native table's row it was sent from; lane 87: not for a site's reflected read)
  end
  -- (lane 87) finished or not, in the entry that carries the stock of that moment (see SITES)
  if exact and F.on.bar and F.on.stock and not e.dump then
    local was = L.v.cn == 0 or F.unfin[e.k] == true
    local cons
    if siteNow ~= nil then cons = not siteNow else cons = consHost(b, was or not e.live) end     -- (lane 87, cure 3)
    if cons == false then
      F.unfin[e.k] = true
      if full or L.v.cn ~= 0 then items[#items + 1] = "cn=0"; L.v.cn = 0 end
      -- (lane 87, cure 3) the work fraction of this tick (a fraction of 1 is right here: every part full, goods missing)
      if siteNow == true then
        local Vv = rawget(C, "values")
        local okU, u = false, nil
        if Vv and Vv.fracNow then okU, u = pcall(Vv.fracNow, e.k, addr(b)) end
        if okU and type(u) == "number" and (full or L.v.wq ~= u) then items[#items + 1] = "wq=" .. string.format("%d", u); L.v.wq = u; bump("wqSent") end
      end
    elseif cons == true and was then
      F.unfin[e.k] = nil; L.v.cn = 1; L.v.wq = nil
      items[#items + 1] = "cn=1"; bump("builtSent")
    end
  end
  -- lane 42: in exact mode every 1 s (exactValuesEvery), and a rival's own settings (build priority, fuel) also on his
  -- sites and upgrades: his AI sets a site's priority on the host only (measured: 4 sites 1 / 4, 2 / 4, 3 / 4)
  -- (task 76e round 3) a house's or a rival building's own animal count (its animals list), for a friend's choice of
  -- which animal goes when its town has more than the host's (liveOne)
  if exact and (e.res or e.rival) and not e.dump and F.on.livestock then
    local okA, na = pcall(function() return #b.animals end)
    if okA and type(na) == "number" and (full or L.na ~= na) then L.na = na; items[#items + 1] = "an=" .. na end
  end
  local vEvery = exact and F.cfg.exactValuesEvery or F.cfg.valuesEvery
  if F.on.values and (e.res or e.rival) and (e.live or e.upg or (e.rival and exact and not e.dump)) and (full or clock - L.tR >= vEvery or (F.vNow ~= nil and L.tR < F.vNow)) then
    L.tR = clock
    for _, R in ipairs(F.rules) do
      if R.on ~= false and (not R.rival or e.rival) and (R.rival or e.res) and (e.live or R.rival or (e.upg and not R.rival)) then
        local x = b[R.p]
        if R.k == "b" then x = x and 1 or 0 end
        if type(x) == "number" and (full or L.v[R.c] ~= x) then
          items[#items + 1] = R.c .. "=" .. num(x); L.v[R.c] = x
          if R.c == "mp" and exact then items[#items + 1] = "md=" .. F.S.eng:getDaysTotal() end
        end
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
  -- (lane 64, task 64d3) also while the building is being upgraded (exact mode, e.upg): a rival house's artisan change
  -- keeps its family at work on the host (assignedFamilyIDs 1 through the conversion), and with the line held back
  -- for the whole conversion a friend stood at 0 for 28 to 33 s (sessions l64pin17, l64pin18: 8@9605,7353 and
  -- 8@9639,7581, the audit's item 6), until the conversion was finished on the host's word
  if e.rival and F.on.rivalWorkers and (e.live or e.upg) and not e.dump and (full or clock - (L.tW or -1e9) >= vEvery) then
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
  for k in pairs(F.sent) do if not st.seen[k] then st.entries[#st.entries + 1] = k .. "-"; F.sent[k] = nil; if F.unfin then F.unfin[k] = nil end end end
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

-- (task 76e) host, exact mode: the buildings whose record of the native table changed (coop_snap.lua N.takeChanged,
-- ten times a second) are read and sent in this tick, not at the end of the next pass. A building the running pass has
-- already read goes out with that pass's entry first, in the same line, so a friend never gets an older entry after a
-- newer one. A building never sent yet waits for the pass (it goes whole).
-- (lane 87, cure 3; session l87f) a site whose work moved (the values module's poll): sent in the next fast step with
-- its goods and that work (wq), as a building whose native record changed is
F.workDue = F.workDue or {}
function F.workSeen(a) if type(a) == "number" and F.S and F.S.role == "host" then F.workDue[a] = true end end
local function hostFast(S, clock)
  local N = rawget(C, "snap"); if not (N and N.takeChanged) then return end
  local ch = N.takeChanged()
  if next(F.workDue) ~= nil then ch = ch or {}; for a in pairs(F.workDue) do ch[a] = true end; F.workDue = {}; bump("workFast") end
  if not (ch and F.cfg.fastHost) then return end
  local X = F.idx; if not X then return end
  if not X.byAddr then
    X.byAddr = {}
    for _, e in ipairs(X.list) do local a = valid(e.b) and addr(e.b); if a then X.byAddr[a] = e end end
  end
  local run
  for _, j in ipairs(F.jobs) do if j.name == "hostPass" and j.st.entries then run = j.st end end
  local st = { entries = {}, seen = {}, clock = clock, n = F.passNo or 0, exact = true }
  local n = 0
  for a in pairs(ch) do
    local e = X.byAddr[a]
    if not e then e = addNew(X, a) end                       -- (lane 64, task 64d) a new building: in the list now, sent now
    if e and not e.dup and (F.sent[e.k] or e.new) and valid(e.b) then
      if run then                                            -- the running pass's entry of this building goes first
        local head1, head2 = e.k .. "|", e.k .. "!|"
        for i = #run.entries, 1, -1 do
          local x = run.entries[i]
          if x:sub(1, #head1) == head1 or x:sub(1, #head2) == head2 then st.entries[#st.entries + 1] = x; table.remove(run.entries, i) end
        end
      end
      local ok, err = pcall(hostOne, st, e)
      if not ok then fail("fast " .. e.k, err) end
      -- (round 3) a name this read gave (a rename) is one the running pass has seen: its end must not tell it
      -- "no longer sent" when the pass had read the building under its old name already
      if run and run.seen and st.seen[e.k] then run.seen[e.k] = true end
      n = n + 1; if n >= F.cfg.fastMax then break end
    end
  end
  if st.stale then needIndex(clock, true) end
  if #st.entries > 0 then bump("fastEntries", #st.entries); bump("fastTicks"); sendList("F B ", st.entries, ";") end
  if st.workers and #st.workers > 0 then sendList("F W ", st.workers, ";") end
  if st.dist and #st.dist > 0 then sendList("F D ", st.dist, ";") end
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
  if ex and F.on.pileFast and F.on.stock and F.idx then timed("hostPiles", hostPiles, S, clock) end      -- lane 76
  if F.on.levels and F.idx and clock - (F.t.lv or -1e9) >= 2.0 then F.t.lv = clock; timed("hostLevels", hostLevels, clock) end
  -- (lane 64, round 5) the host's day change: the game's day step has just changed the counts of days (a home's
  -- mourning, its market days). A friend whose own game no longer counts mourning (NOMOURN) shows the host's old
  -- value until the new one arrives, so the rule values of every building are read in a pass that starts now, not
  -- at their next turn (up to 2 s: the pass every second, a building's values at most once a second).
  local okD, dayN = pcall(function() return S.eng:getDaysTotal() end)
  if okD and dayN ~= F.hostDay then
    if F.hostDay ~= nil then F.vNow = clock; F.t.pass = -1e9; bump("dayPush") end
    F.hostDay = dayN
  end
  if (F.on.stock or F.on.values) and F.idx and clock - F.t.pass >= (ex and cfg.exactPassEvery or cfg.passEvery) then
    if addJob("hostPass", hostPassJob, {}) then F.t.pass = clock end
  end
  if ex and F.on.stock and F.idx then timed("hostFast", hostFast, S, clock) end                       -- (task 76e)
  if F.on.livestock and clock - F.t.live >= (hostExact() and cfg.exactLiveEvery or cfg.liveEvery) then F.t.live = clock; timed("hostLive", hostLive, S, clock) end
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

evalExactF = evalExact
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
  -- (lane 87) the host's entry said "finished now" (cn=1) and carries the goods after the finish: this copy's site is
  -- finished first (the sites module's own finish; it takes the building from the game's list itself). A site that is
  -- newer here than the sites module's last look waits up to 2 s for that look, its goods unwritten.
  if st.exact and H.cnT and F.on.bar then
    local Bs = rawget(C, "sites")
    local okF, r = false, nil
    if Bs and Bs.finishNow then okF, r = pcall(Bs.finishNow, k) end
    if okF and r == "new here" and os.clock() - H.cnT < 2.0 then bump("siteWaits"); F.dirty[k] = true; return end
    H.cnT = nil
    if okF and r == "finished" then bump("siteFinished")
    elseif okF and r == "not a site now" then bump("siteAlready")
    else
      bump("siteNotFinished")
      if not F.siteSaid then F.siteSaid = true; log("site %s is finished on the host (its stock line said so) and could not be finished here first (%s): its goods are written; the sites module's word finishes it", k, tostring(r)) end
    end
  end
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
          -- (lane 64, round 5) mourning days this copy's game no longer counts itself (NOMOURN): the host's value at
          -- once, in exact mode or not; no day of this copy's own can come between
          local hostOnly = code == "mp" and F.ownMourning ~= nil and not F.ownMourning()
          if hostOnly then mg, stl = 0, 0.0 end
          -- counted once per value the host sent: its lower value came before this copy's own day change (the case
          -- that ran a day ahead), or its higher one after it (harmless)
          if st.exact and R.daily and not hostOnly and d ~= 0 and math.abs(d) <= mg and H.sinceV[code] == nil then bump(d < 0 and "val_dayHeldLower" or "val_dayHeldHigher") end
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

put = function(b, g, d) b:addToInventory({ Type = g, amt = d }) end

-- one correction. The difference is read again (ticks have passed since it was planned).
local function doOp(op, clock)
  local e = op.e
  if not same(e) then bump("stale"); return end
  local b = e.b
  if op.exact then                                          -- exact mode: the amount itself, with the game's own addToInventory
    -- (task 76e) the host's amount as it stands now: a newer line may have come since this write was planned
    local H = F.host.b[op.k]; if H and H.full and H.g then op.want = H.g[op.g] or 0 end
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

doOpF = doOp
-- st.quick: only the buildings the host has just sent new values for (a large difference is then corrected within a
-- fraction of a second); everything else is the business of the full pass
-- (lane 87, cure 3) the work fraction (wq) of the host's latest entry for this building, held now: called in the tick
-- that entry's goods are written (friendFast, the pass's step of that building), and for an entry without goods to
-- write at the end of the pass. The values module finds the building itself (its own rule for a site of this tick).
local function wqHold(k)
  local H = F.host.b[k]
  if not (H and H.wqNew) then return end
  H.wqNew = nil
  local Vv = rawget(C, "values")
  if H.v and type(H.v.wq) == "number" and Vv and Vv.factsHold and F.on.bar then
    local ok, r = pcall(Vv.factsHold, k, H.v.wq)
    if ok and r then bump("wqHeld") elseif not ok then bump("wqErr") end
  end
end
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
    -- (lane 76) exact mode: by building, so that all goods of one building are written in one step (see below)
    if st.exact then table.sort(st.ops, function(a, b) if a.k ~= b.k then return a.k < b.k end; if a.g ~= b.g then return a.g < b.g end; return a.d < b.d end)
    else table.sort(st.ops, function(a, b) return a.d < b.d end) end
    st.plan = true; st.j = 0
    if st.miss then needIndex(st.clock, true) end
    return false
  end
  st.j = st.j + 1
  local op = st.ops[st.j]
  if not op then
    for _, k in ipairs(st.keys or {}) do wqHold(k) end        -- (lane 87, cure 3) entries without goods to write
    bump(st.quick and "quickPasses" or "passes"); return true
  end
  local ok, err = pcall(doOp, op, st.clock)
  if not ok then fail("write " .. op.k .. " good " .. op.g, err) end
  -- (lane 76) exact mode: every good of this building in the same tick. One good a tick showed a state the host
  -- never had between two ticks (two goods changed in one pass of the host: one written, the other not yet).
  if op.exact then
    local nx = st.ops[st.j + 1]
    while nx and nx.exact and nx.e == op.e do
      st.j = st.j + 1
      local ok2, err2 = pcall(doOp, nx, st.clock)
      if not ok2 then fail("write " .. nx.k .. " good " .. nx.g, err2) end
      nx = st.ops[st.j + 1]
    end
    proofNote(op.e.b)                                       -- (timing proof: this copy's row, dated at the write)
    wqHold(op.k)                                            -- (lane 87, cure 3) its work in the same tick
  end
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
        if ok then proofGone(e.k) end
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
      -- (lane 64) in the town itself: the first building of the index can stand in another region, and an animal made
      -- there left its body in that region's list when the host's animal died (measured: gone from there 3 s later)
      pcall(function() local c = r:getSettledRegionCenter(); if c.X == c.X and c.Y == c.Y and (c.X ~= 0 or c.Y ~= 0) then pos = { X = c.X + 150.0, Y = c.Y + 0.0, Z = c.Z + 0.0 } end end)
      if not pos then
        local X = F.idx; local e = X and X.list[1]
        if e and valid(e.b) then local l = e.b:K2_GetActorLocation(); pos = { X = l.X + 300.0, Y = l.Y + 0.0, Z = l.Z + 0.0 } end
      end
    end
    if not pos then return end
    local ok, u = pcall(function() return S.eng:SpawnLivestock(role, pos, r) end)
    if ok and valid(u) then
      F.made[#F.made + 1] = { u = u, role = role, k = k, r = r }; bump("liveMade"); F.liveSeen[k] = nil
      log("livestock %s kind %d: %d here, %d on the host: one made", k, role, have, n)
    else bump("liveFailed"); log("livestock %s kind %d: could not be made (%s)", k, role, tostring(u)) end
  elseif F.on.livestockRemove then
    local victim
    for i = #F.made, 1, -1 do
      local m = F.made[i]
      if not valid(m.u) or m.u.dead then table.remove(F.made, i)
      elseif not victim and m.role == role and m.k == k and m.u.currentUnitRole == role then victim = m.u; table.remove(F.made, i) end   -- (not by currentRegion: that is where it stands, and one made beside another region's building never matched)
    end
    -- (lane 76, task 76e round 3) WHICH ANIMAL GOES. Lane 88's session l88e: a rival house lost its chicken coop on the
    -- host (its three hens with it), the friend still had them, and this step removed three free hens: from ANOTHER
    -- house, which kept its three on the host. That house then showed 2, then 1, the whole session (133 readings a
    -- value the host never had). So the host now sends each house's and rival building's own animal count (F B
    -- item an=), and an animal of a building that has more here than on the host goes first; an animal of a building
    -- that has no more than the host's is never taken.
    local surplus, keep = nil, {}
    if not victim and F.idx then
      for _, e in ipairs(F.idx.list) do
        local H = F.host.b[e.k]; local hn = H and H.v and H.v.an
        if hn and valid(e.b) then
          local okA, arr = pcall(function() return e.b.animals end)
          local n = okA and arr and #arr or 0
          for j = 1, n do
            local u = arr[j]; if type(u) ~= "table" and type(u) ~= "userdata" then u = nil end
            if u and valid(u) then
              local okR, ro = pcall(function() return u.currentUnitRole end)
              if okR and ro == role then
                local ua = addr(u)
                if n > hn and not surplus then surplus = u elseif ua then keep[ua] = true end
              end
            end
          end
        end
      end
      if surplus then victim = surplus; bump("liveSurplusHouse") end
    end
    if not victim then
      for i = #list, 1, -1 do
        local u = list[i]
        local ok, free = pcall(function() return not valid(u.animalAssignedTo) and not valid(u.chosenPasture) and #u.Tasks == 0 end)
        local ua = addr(u)
        if ok and free and not (ua and keep[ua]) then victim = u; break end
      end
    end
    if not victim then bump("liveNoVictim"); return end
    local ok, e = pcall(function() S.eng:destroyUnit(victim) end)
    if ok then bump("liveRemoved"); log("livestock %s kind %d: %d here, %d on the host: one removed", k, role, have, n)
    else bump("liveFailed"); log("livestock %s kind %d: could not be removed (%s)", k, role, tostring(e)) end
  end
end
-- (lane 76, task 76h) ONE OWNER OF A TOWN'S ANIMAL COUNT: this step. Sessions l76q and l76s: a rival house got its
-- goats (upgrade 28: two animals of kind 13) or pigs (upgrade 27: two of kind 19) on the host; this step made the two
-- missing animals after 0.5 s, and 0.05 to 0.6 s later the people module started the same upgrade here, whose own
-- game brought two more: 4 where the host had 2, for 5 s and 10 s (values the host never had). When the people module
-- came first (l76s, upgrade 28) nothing was wrong. The upgrade's animals are the real ones (they are in the house's
-- own animal list), so the animals this step made are STAND-INS (F.made): the moment the town's count rises above
-- the host's by another maker (the people module's upgrade, a finished backyard, an ordered animal arriving), the
-- stand-ins of that kind are taken out, in the same tick: liveTakeBack. The people module calls it right after its
-- upgrade call; the tick below calls it when a town with stand-ins counts more animals than at the tick before.
-- Only stand-ins are taken, never an animal of the game's own; a count that is too high because the HOST lost an
-- animal keeps its wait (the host's word of the death comes first: the events module, E AD).
local function liveTakeBack(S, r, k, why)
  local want = F.host.a[k]; if not want or not valid(r) then return 0 end
  local have, taken = nil, 0
  for i = #F.made, 1, -1 do
    local m = F.made[i]
    if not valid(m.u) or m.u.dead then table.remove(F.made, i)
    elseif m.k == k and m.u.currentUnitRole == m.role then
      have = have or liveCounts(r)
      if (have[m.role] or 0) > (want[m.role] or 0) then
        local n = have[m.role]
        local ok = pcall(function() S.eng:destroyUnit(m.u) end)
        if ok then
          have[m.role] = n - 1; table.remove(F.made, i); taken = taken + 1; bump("liveTakenBack")
          log("livestock %s kind %d: %d here, %d on the host (%s): one made here before is taken out at once", k, m.role, n, want[m.role] or 0, tostring(why))
        end
      end
    end
  end
  if taken > 0 then F.liveSeen[k] = nil end
  return taken
end
-- every tick, one call per town that has stand-ins: did its count rise?
local function liveWatch(S)
  local done = {}
  for i = #F.made, 1, -1 do
    local m = F.made[i]
    if m and not done[m.k] and m.r and valid(m.r) and F.host.a[m.k] then
      done[m.k] = true
      local tot = m.r:getTotalLivestockCount()
      local seen = F.liveSeen[m.k]
      F.liveSeen[m.k] = tot
      if seen and tot > seen then
        local wantTot = 0; for _, n in pairs(F.host.a[m.k]) do wantTot = wantTot + n end
        if tot > wantTot then liveTakeBack(S, m.r, m.k, "this copy's own game brought animals") end
      end
    end
  end
end
-- for the people module: right after an upgrade it started on a building of region <r>
function F.liveUpgraded(S, r)
  if S.role ~= "friend" or not F.on.livestock or #F.made == 0 or not valid(r) then return 0 end
  local k = rkey(r); if not k then return 0 end
  return liveTakeBack(S, r, k, "the upgrade started here brought its own")
end
-- for the events module: the host said that an animal of this kind died in region <k>, and it died here. The host's
-- count line may still show the count of before for a moment: no animal is made for that kind for 1.5 s.
function F.liveDied(k, role) F.liveHold[tostring(k) .. ":" .. tostring(role)] = os.clock() end
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
            -- lane 42: a rival town waits less (lane 76: 0.5 s for an animal to make, 5 s for one to take away)
            -- (lane 64, task 64d2) the player's own town too, for an animal to make, in exact mode (F.on.liveFastMake)
            local make = n > have[role]
            local fast = F.exact and make and (R.rival or F.on.liveFastMake)
            if make and clock - (F.liveHold[id] or -1e9) < 1.5 then bump("liveHeldDeath")   -- (the host's word of a death just came: see F.liveDied)
            elseif clock - F.liveSince[id] >= (fast and (R.rival and F.cfg.rivalLiveSettle or F.cfg.liveMakeSettle) or ((R.rival and F.exact) and F.cfg.rivalLoseSettle or F.cfg.liveSettle)) then
              F.liveSince[id] = clock
              -- (lane 76) a rival town in exact mode: every animal the host has more, in this look (at most 4); (lane 64) the
              -- player's town as well
              local times = fast and math.min(n - have[role], 4) or 1
              for j = 1, times do liveOne(S, R.r, R.k, role, have[role] + j - 1, n, clock) end
              if fast and not R.rival then bump("liveFastMade", times) end
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
        if F.famOff and F.famOff[p] then go = false
        elseif F.exact then go = due(F.famDay, id, w - cur, 1, F.cfg.famWait, os.clock(), st.paused); if not go then bump("fam_dayHeld") end
        else go = st.paused or F.famSince[id] end
        if go then
          F.famSince[id] = nil
          if isB then cs[p] = (w == 1) else cs[p] = w end
          local back = f.ConsumptionStatus[p]; if type(back) == "boolean" then back = back and 1 or 0 end
          if back == w then bump("famFix"); if F.cfg.verbose then log("family %s %d %s %s -> %s", R.k, i, p, tostring(cur), tostring(w)) end
          elseif j > FAM_OLD then F.famOff = F.famOff or {}; F.famOff[p] = true; bump("err"); log("family mark %s is left alone from now: family %d did not take %s (%s)", p, i, tostring(w), tostring(back))
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

-- A single load restores the save's morning while the host keeps playing. Use
-- the mourning value read on the host's stated day, including across the local
-- day step that will otherwise subtract the same day twice.
-- (lane 64, round 5) does this copy's own game still take a day off a home's mourning at its day change? Not when
-- the native piece holds that step (coop_patch item NM, NOMOURN, on a friend): then the days are the host's alone,
-- its value is written the moment its line comes, and nothing here has to work around this copy's own count.
-- Asked at most once a second (the answer is the native piece's status file).
local function ownMourning()
  local clock = os.clock()
  if F.nmT == nil or clock - F.nmT >= 1.0 then
    F.nmT = clock
    local P = rawget(C, "patch"); local ok, st = pcall(function() return P and P.noMourn and P.noMourn() end)
    local held = ok and st == "on"
    if held ~= F.nmHeld then log("mourning days: %s", held and "this copy's game no longer counts them (NOMOURN on): the host's value is written as it comes" or "this copy's game counts them itself: the one-day rule applies") end
    F.nmHeld = held
  end
  return not F.nmHeld
end
F.ownMourning = ownMourning
local function mournNow(k, value)
  local e = byKey(k)
  if not e and not F.idx and C.town and C.town.findB then
    local t, x, y = parseKey(k)
    local b = C.town.findB(t, x * 10, y * 10, 10)
    if valid(b) then e = {b = b, k = k} end
  end
  if e and same(e) and (liveNow(e) or upgNow(e)) and e.b.mourningPeriod ~= value then e.b.mourningPeriod = value; bump("mourningNow") end
end
local function restoreMourning(k, day)
  local m = F.catchMourning[k]
  if day > m.day then F.catchMourning[k] = nil; return end
  if m.applied == day then return end
  local e = byKey(k)
  if not e and not F.idx and C.town and C.town.findB then
    local t, x, y = parseKey(k)
    local b = C.town.findB(t, x * 10, y * 10, 10)
    if valid(b) then e = {b = b, k = k} end
  end
  if e and same(e) and (liveNow(e) or upgNow(e)) then
    if e.b.mourningPeriod ~= m.value then e.b.mourningPeriod = m.value; bump("mourningRestored") end
    m.applied = day
    if m.value == 0 or (day == m.day and not F.rejoining) then F.catchMourning[k] = nil end
  end
end

-- ---------------------------------------------------------------- friend: store the host's lines
local function onLine(S, w)
  local sub = w[4]; local clock = os.clock()
  if S.replay then F.rejoining = true end
  if sub == "B" then
    for ent in (w[5] or ""):gmatch("[^;]+") do
      local k, rest = ent:match("^(%d+@%-?%d+,%-?%d+)(.*)$")
      if k then
        if rest == "-" then
          F.host.b[k] = nil; F.dirty[k] = nil; F.catchMourning[k] = nil
          do local Vv = rawget(C, "values"); if Vv and Vv.factsEnd then pcall(Vv.factsEnd, k) end end   -- (lane 87, cure 3) the key back to HW P
          if k:sub(1, 3) == "88@" then
            F.pileGone[k] = clock                              -- the host's pile is gone (exact mode: pilesStep)
            if F.on.pileFast then F.t.piles = -1e9; if F.pileWant then F.pileWant[k] = nil end end   -- lane 76: in the next tick
          end
        else
          local full = rest:sub(1, 1) == "!"; local body = rest:match("|(.*)$") or ""
          local H = F.host.b[k]
          if not H or H.storage then H = { g = {}, v = {}, since = {}, sinceV = {}, new = {}, quiet = 0, phase = math.random(0, 3) }; F.host.b[k] = H end
          if full then H.g = {}; H.full = true end
          H.t = clock; H.fresh = true; F.dirty[k] = true
          local mourning, day
          for code, val in body:gmatch("(%w+)=(%-?[%d%.]+)") do
            local g = tonumber(code); local v = tonumber(val)
            if v then
              v = math.tointeger(v) or v
              if g then H.g[g] = v; H.new[g] = true
              elseif code == "md" then day = v
              else
                H.v[code] = v; H.new[code] = true; if code == "mp" then mourning = v end
                if code == "cn" then H.cnT = (v == 1) and clock or nil end     -- (lane 87) the host's building was finished now
                if code == "wq" then H.wqNew = true end                           -- (lane 87, cure 3) held with this entry's goods
                if code == "cn" and v == 1 then local Vv = rawget(C, "values"); if Vv and Vv.factsEnd then pcall(Vv.factsEnd, k) end end
              end
              bump("items")
            end
          end
          -- lane 76: a pile's stock is written in the next tick (and a pile this copy does not have yet as it comes)
          if F.on.pileFast and k:sub(1, 3) == "88@" then F.pileWant = F.pileWant or {}; F.pileWant[k] = clock end
          if mourning and day and F.on.values and RULE.mp.on ~= false and (F.rejoining or F.catchMourning[k])
              and not C.hold and valid(S.eng) and ownMourning() then
            F.catchMourning[k] = { value = mourning, day = day }
            restoreMourning(k, S.eng:getDaysTotal())
          elseif mourning and F.on.values and RULE.mp.on ~= false and not C.hold and valid(S.eng) and not ownMourning() then
            -- (lane 64, round 5) NOMOURN: the host's days are written the moment the line is read, also a replayed
            -- line right after a load, before the building pass has its index (sitting rl7: the save's value, a
            -- day old by then, stood for 1.2 s until the pass wrote the host's)
            mournNow(k, mourning)
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

-- (lane 76, task 76e) friend, exact mode: the buildings the host has just sent (F.dirty) are written in this tick, all
-- goods of a building in one step, instead of by a quick pass that waits while a full pass is being worked through.
-- The full pass still looks at every building every second; a write it planned before takes the host's amount as it
-- stands when it writes (doOp).
local function friendFast(clock)
  local st = { keys = {}, ops = {}, clock = clock, paused = A.isPaused() and true or false, exact = true, quick = true, n = 1, i = 0 }
  for k in pairs(F.dirty) do st.keys[#st.keys + 1] = k end
  F.dirty = {}
  for _, k in ipairs(st.keys) do
    local ok, err = pcall(evalBuilding, st, k)
    if not ok then fail("fast apply " .. k, err) end
  end
  table.sort(st.ops, function(x, y) if x.k ~= y.k then return x.k < y.k end; if x.g ~= y.g then return x.g < y.g end; return x.d < y.d end)
  for _, op in ipairs(st.ops) do
    local ok, err = pcall(doOp, op, clock)
    if not ok then fail("fast write " .. op.k .. " good " .. op.g, err) end
  end
  for _, k in ipairs(st.keys) do wqHold(k) end               -- (lane 87, cure 3) the work of each entry, in this tick
  if st.miss then needIndex(clock, true) end
  bump("fastApplied", #st.keys)
end
-- (lane 76, task 76e) A BUILDING'S STORAGE COUNTERS AFTER AN UPGRADE STARTED HERE. Sessions l76w and l76y, the same
-- rival storehouse twice (72 becomes 99): the people module's BeginUpgrade here left numStoredGeneric at 127 and 161,
-- values the host never had (the host: 126 then 125; 162 then 160), with every good equal, until this module's next
-- write to it 1.8 s and 0.44 s later (a write recounts). The upgrade's use of materials ends in no recount here (the
-- native switch puts the goods back). So a building whose upgrade starts on this copy (the people module for a
-- rival's, the town module for a player's) gets the same write of amount 0 the registration makes (the game's
-- addToInventory recounts the three counters from the goods as they stand) in that tick and in every tick for 2 s;
-- after a town action of the upgrade kinds every building being upgraded here is taken in for 2 s. Writes no amount.
F.recountList = F.recountList or {}
function F.recountSoon(b, secs)
  if not (F.exact and F.S and F.S.role == "friend") or not valid(b) then return false end
  local a = addr(b); if not a then return false end
  -- (task 76e round 3) an upgrade started here can change the building's type (72 becomes 99): its list entry is
  -- renamed in this tick and the host's values under the new name, if they came already, are written in this tick
  -- (probe k76a: without it the friend waited for its next pass, 0.75 s after its own change)
  if F.cfg.rekey and F.idx then
    for _, e in ipairs(F.idx.list) do
      if e.b == b or addr(e.b) == a then
        if rekey(e) and F.host.b[e.k] then F.dirty[e.k] = true end
        break
      end
    end
  end
  local x = F.recountList[a]
  if not x then x = { b = b, n = 0 }; F.recountList[a] = x end
  x.untilC = math.max(x.untilC or 0, os.clock() + (secs or 2.0))
  local ok = pcall(put, b, 16, 0)
  if ok then x.n = x.n + 1; bump("upgRecount") else bump("upgRecountFailed") end
  return ok
end
function F.recountUpgrading(secs)
  if not (F.exact and F.S and F.S.role == "friend") then return false end
  F.recountScanUntil = math.max(F.recountScanUntil or 0, os.clock() + (secs or 2.0))
  return true
end
-- (lane 76, task 76e) A FAMILY'S MARKS AT THIS COPY'S OWN DAY CHANGE. Sessions l76w to l76b: 11 to 18 readings of a
-- rival family's hunger a session (fc ConsumptionStatus.hunger, "stale"): at the day sample the friend showed 2 where
-- the host had had 1 for the whole day; 0.13 s later the facts module wrote 1. This copy's own day step had changed
-- the mark (a day without food here), the host's had not. The rule for a difference of one (F.dayRule, lane 64) waits
-- because this copy's day step may still come; at this copy's own day change it HAS come and will not come again that
-- day. So in the tick this copy's day changes every followed family (the player's and, in exact mode, the rivals')
-- gets the host's last word for each mark at once. A host whose own step changed the mark too sends it within 0.5 s;
-- until then the friend shows the host's value of before its day change (held by the host until a moment ago).
local function famDayChange(S, clock)
  local okD, day = pcall(function() return S.eng:getDaysTotal() end)
  if not okD or type(day) ~= "number" then return end
  local last = F.famDayLast; F.famDayLast = day
  if not last or last == day or (F.famOff and F.famOff.all) then return end
  local n, w0 = 0, 0
  for _, R in ipairs(liveRegions(S, F.exact == true)) do
    local M = F.host.m[R.k]
    if M and valid(R.r) then
      local fams = R.r.workerFamilies
      for i = 1, #fams do
        local want = M[i]; local f = fams[i]
        if want and f then
          local home = "-"; local h = f.familyHome
          if valid(h) then local ok, hk = pcall(keyOf, h); if ok then home = hk end end
          if home == want.home then
            local cs = f.ConsumptionStatus
            for j, p in ipairs(FAM) do
              local w = want.v[j]
              if w and not (F.famOff and F.famOff[p]) then
                local cur = cs[p]; local isB = type(cur) == "boolean"; if isB then cur = cur and 1 or 0 end
                if type(cur) == "number" and cur ~= w then
                  if isB then cs[p] = (w == 1) else cs[p] = w end
                  local id = R.k .. ":" .. i .. ":" .. p
                  F.famSince[id] = nil; F.famDay[id] = nil; n = n + 1
                  if math.abs(w - cur) > 1 then w0 = w0 + 1 end
                end
              end
            end
          end
        end
      end
    end
  end
  if n > 0 then bump("famDayFix", n); log("families: %d mark(s) set back to the host's at this copy's day change (day %d; %d by more than one)", n, day, w0) end
end
-- (task 76e) for the world module, at the start of its tick on a friend: the same, before any of its reads (session
-- l7d: two readings showed this copy's own day step in the one read the world module made before the facts module)
function F.famDayNow(S)
  if not (S and S.role == "friend" and F.on.families and next(F.host.m) ~= nil and F.S == S) then return end
  timed("famDayChange", famDayChange, S, os.clock())
end
local function recountStep(S, clock)
  if F.recountScanUntil and clock < F.recountScanUntil then
    local arr = S.eng.buildingArr
    for i = 1, #arr do
      local b = un(arr[i])
      if valid(b) then
        local ok, u = pcall(function() return b.isBeingUpgraded end)
        local a = ok and u and addr(b)
        if a and not F.recountList[a] then F.recountList[a] = { b = b, n = 0, untilC = clock + 2.0 } end
      end
    end
  elseif F.recountScanUntil then F.recountScanUntil = nil end
  for a, x in pairs(F.recountList) do
    if clock > x.untilC or not valid(x.b) or not F.exact then
      if x.n > 0 then bump("upgRecountDone") end
      F.recountList[a] = nil
    else
      local ok = pcall(put, x.b, 16, 0)
      if ok then x.n = x.n + 1; bump("upgRecount") else bump("upgRecountFailed") end
    end
  end
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
  -- (rl3: the gap still held the value of before the load, so the catch-up was taken to be over at the first tick and
  --  the next day's mourning waited out the 3 s day rule: 2.986 s behind the host. Only a gap measured in this world counts.)
  if F.rejoining and not S.replay and S.clockGap and S.clockGap ~= F.gap0 and math.abs(S.clockGap) <= 0.02 then F.rejoining = nil end
  if next(F.catchMourning) and valid(S.eng) then
    if not ownMourning() then F.catchMourning = {}       -- (NOMOURN came on meanwhile: nothing to work around)
    else
      local day = S.eng:getDaysTotal()
      for k in pairs(F.catchMourning) do restoreMourning(k, day) end
    end
  end
  -- (lane 64, task 64d) a new building in the list in the tick the native table shows it (see addNew): the host's values
  -- for it, when they came first, are written in this tick (friendFast)
  if ex and F.idx and F.on.newAtOnce then
    local Ns = rawget(C, "snap"); local ch = Ns and Ns.takeChanged and Ns.takeChanged()
    if ch then
      for a in pairs(ch) do
        local e = addNew(F.idx, a)
        if e and not e.dup and F.host.b[e.k] then F.dirty[e.k] = true end
      end
    end
  end
  if ex and F.idx and clock - (F.t.idxN or 0) >= cfg.exactIndexAge then        -- a new building: seen within a second
    F.t.idxN = clock
    local okN, n = pcall(function() return #S.eng.buildingArr end)
    if okN and n ~= F.idx.n then needIndex(clock, true) end
  end
  needIndex(clock, false)
  if ex and F.idx and (F.regIdx ~= F.idx or clock - (F.t.reg or 0) >= 5.0) then
    if addJob("register", regJob, {}) then F.regIdx = F.idx; F.t.reg = clock end
  end
  if ex and F.on.pileFast and F.idx then timed("friendPiles", friendPiles, S, clock) end                 -- lane 76
  if ex and (F.recountScanUntil or next(F.recountList)) then timed("recount", recountStep, S, clock) end   -- (task 76e)
  if ex and clock - (F.t.piles or 0) >= 1.0 then F.t.piles = clock; timed("piles", pilesStep, S, clock) end
  if clock - F.t.prune >= 2.0 then
    F.t.prune = clock
    local keep = {}; for _, h in ipairs(F.holds) do if clock - h.at < 10.0 then keep[#keep + 1] = h end end
    F.holds = keep
    for k, t in pairs(F.holdR) do if clock - t > 10.0 then F.holdR[k] = nil end end
  end
  if ex and cfg.fastFriend and F.on.stock and F.idx and next(F.dirty) ~= nil then timed("friendFast", friendFast, clock) end   -- (task 76e)
  if (F.on.stock or F.on.values) and F.idx and next(F.host.b) ~= nil then
    if clock - F.t.apply >= cfg.applyEvery then
      if addJob("friendPass", friendPassJob, {}) then F.t.apply = clock; F.t.quick = clock end
    elseif next(F.dirty) ~= nil and clock - F.t.quick >= cfg.quickEvery then
      if addJob("friendPass", friendPassJob, { quick = true }) then F.t.quick = clock end
    end
  end
  if F.on.livestock and #F.made > 0 and next(F.host.a) ~= nil then local okW, eW = pcall(liveWatch, S); if not okW then bump("liveWatchErr"); F.lastErr = tostring(eW) end end
  if F.on.livestock and next(F.host.a) ~= nil and clock - F.t.live >= (F.exact == true and cfg.exactLiveEvery or cfg.liveEvery) then F.t.live = clock; timed("friendLive", liveApply, S, clock) end
  if F.on.levels and F.idx and F.hostL and next(F.hostL) ~= nil and clock - (F.t.lv or -1e9) >= 1.0 then F.t.lv = clock; timed("friendLevels", friendLevels, clock) end
  if ex and F.on.dist and F.idx and F.hostD and next(F.hostD) ~= nil and clock - (F.t.dist or -1e9) >= 0.25 then F.t.dist = clock; timed("friendDist", friendDist) end   -- lane 42
  if ex and F.on.rivalWorkers and F.idx and F.hostW and next(F.hostW) ~= nil and clock - (F.t.wk or -1e9) >= 0.5 then F.t.wk = clock; timed("friendWorkers", friendWorkers, clock) end
  if F.on.families and next(F.host.m) ~= nil then timed("famDayChange", famDayChange, S, clock) end   -- (task 76e)
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
