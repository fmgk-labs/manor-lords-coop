-- Manor Lords Co-op: world state module (message kind "W", host -> friends only).
-- Load after coop.lua (loadfile / dofile through the console). Re-loadable: state lives in Coop.world, functions are
-- defined again on every load.
--
-- Why: two copies that load the same save drift apart (the simulation draws from a shared random stream and runs daily
-- code on frame-dependent moments: lane_w report_W.txt "HOW THE DAY RUNS"). The host is the referee: it reads what
-- matters and sends it; each friend moves its own copy to those values by name, and reports when it has drifted too far
-- for that (so another module can reload the host's save). This module never reloads anything itself.
--
-- Host (S.role == "host"), all reads spread over ticks (budget cfg.budgetMs per tick):
--   every 2 s   per owned region: stock of every tradeable good that changed, regional wealth; the lord's treasury
--               (influence and king's favour behind flag lordExtra)
--   every 2 s   per-building inventories of storage buildings and construction sites, as changes (flag bstock)
--   each day    clock, raid / bandit-camp / director timers, weather targets (flag weather), drift fingerprint;
--               the wide sample (flag wide): about 5,000 values of every owner's buildings, the regions, families,
--               units and the lord, LOG ONLY: the friend compares and logs it, it never asks for a resync
--   events      raid, bandit camp, director action, fire start / end, new free merchant (read-only polling)
--   every 30 s  a keyframe: every value again, so a friend that started late or reloaded catches up
-- Friend: stores the host's latest values (latest wins) and corrects its copy to them; holds its own random events off
--   (flags hold*); compares fingerprints paired by day and calls Coop.onDrift(reason) after cfg.driftAfter consecutive
--   mismatches (flag driftHook).
--
-- Evidence. Every replay function has a status line.
--   proven live  = README session 9: Region:getStockOfGood(g,false,false), Region:grantResources({ { Type = g, amt = d } },
--                  false), Region:consumeGood(g, -d, eng.buildingArr[1], false, false, false), PawnCPP.silver and
--                  Region.regionalWealth written directly. Home region only. Two copies stayed within 2 units at speed 4.
--   one copy     = README session 14 (coordinator's live run on one copy): addToInventory on a construction site and on
--                  a storage building (+1/-1, building and region totals follow), daysUntilNextRaid and
--                  lastBanditCampSpawnedDay writes, drawDebugFlags append/restore, the lane_w fingerprint (191 bytes,
--                  5 ms; every section equal on two fresh loads except owners, which used object names: fixed here).
--                  ON by default, but not yet run with two copies.
--   static       = lane_w (research/2026-11-10-game-probe/lanes/lane_w/report_W.txt, recipes.tsv, row ids W2a..W7).
--                  Not run live. These items are OFF by default; switch them on one at a time: Coop.world.set("weather", true).
--                  Everything that spawns or removes things (fire, merchant) stays off.
-- Copy-independent names only: object names, addresses, UniqueIDs and squad numbers differ between copies. Regions are
-- named by tag, buildings by type + position, lords by "our lord" / bandit / setup index. This module spawns no pawn.
-- Names used and where they come from:
--   registry.tsv: Region.getStockOfGood/grantResources/consumeGood/getNumHomelessFamilies/getNumTotalPopulation/
--     getNumFamiliesOfLv, PawnCPP.getClosestOwnedRegion/getPawnSetupIndex, RTSMultiEngineCPP.getDaysTotal/
--     spawnFreeMerchant, SMBuildingMaster.addToInventory/StartFire/isStorageTypeBuilding/getNumActiveWorkerFamilies/
--     getNumResidingFamilies, TemporalComponent.getTotalDaysAndHours.
--   dumps: Region.txt (regionUniqueTag, regionName, ownerPawn, workerFamilies, regionalWealth, Approval, publicOrder,
--     settlementLevel, bAnyBuildingOnFire), TemporalComponent.txt (daysUntilNextRaid, daysSinceLastRaid,
--     lastBanditCampSpawnedDay, weather fields), SMBuildingMaster.txt (ownerPawn, Inventory, onFire, fireAmt, lv, sleep),
--     PawnCPP.txt (silver, influence, kingsFavour, isAI), RTSMultiEngineCPP.txt (TemporalComponent, buildingArr, regions,
--     tradeableGoods, freeMerchants, livestockMerchants, spawnMerchants, questDirector, drawDebugFlags).
--   lane_w READ claim only (no dump of class Director): Director.scenario_nextActionDay (recipes.tsv W4c).
--   Good struct field names Type / amt: README session 9 (Type with a capital T).
--
-- Message formats (the core puts "<seq> <wallclock> " in front; no field contains a space):
--   W R <regionKey> <h|-> <g>=<amt>,...,w=<wealth>    absolute values of what changed; h = the host's home region
--   W L s=<silver>[,i=<influence>,f=<favour>]
--   W B <entry>;<entry>;...   entry = <bkey>|g=a,...  (changed goods)  or <bkey>!|g=a,... (complete inventory)
--                             or <bkey>-  (no longer tracked)            bkey = <type>@<x/10>,<y/10>
--   W T <daysUntilNextRaid> <daysSinceLastRaid> <lastBanditCampSpawnedDay> <scenario_nextActionDay|->
--   W D <daysTotal> <getTotalDaysAndHours>
--   W X <daysTotal> <v1>,<v2>,...   weather targets in the order of WX below
--   W F <daysTotal> D.. B.. C.. F.. O.. W.. M.. N.. R.. S.. Q..   daily comparison, one word per section; F, R and S hold one entry per owned region, by tag
--   W E RAID <until> <since> | W E CAMP <day> | W E DIRECTOR <next> | W E FIRE <bkey> | W E FIREOUT <bkey> | W E MERCH <free> <livestock>
--   W G <tag> <section> <key>|<v>|<v>...;<key>|...   and   W G <tag> END <serial> <base> <lines> <ms> <ticks> <day>
--                             the wide daily sample, LOG ONLY: it is compared and written to the friend's log, it never
--                             asks for a resync (see "the wide daily sample" below)

local C = rawget(_G, "Coop")
if type(C) ~= "table" or type(C.register) ~= "function" or type(C.api) ~= "table" then return "coop_world: load coop.lua first" end
local A = C.api
local W = C.world or {}
C.world = W
W.version = "0.1-dev"

-- ---------------------------------------------------------------- per-item switches
-- An item switch means "the host sends it and the friend applies it": set it the same way on every copy.
local DEFAULT_ON = {
  -- proven live (README session 9), home region only
  stock = true, silver = true, wealth = true,
  -- read only on the host, log only on the friend: they cannot change the world
  events = true, fp = true,
  -- same calls as session 9 but not measured: other owned regions; influence / king's favour (read live, never written)
  -- lordExtra (influence, king's favour): on since lane 31, the lord panel's numbers must be the host's
  otherRegions = true, lordExtra = true,    -- otherRegions: no longer read (every owned region is pushed and corrected by its tag since lane 5)
  -- proven live on one copy (README session 14): the write works; two-copy behaviour not measured yet
  bstock = true,         -- W6 / W2a per-building inventories and construction deliveries (addToInventory +1/-1)
  holdRaid = true,       -- W4a raid countdown held one day behind the host (daysUntilNextRaid write)
  holdCamp = true,       -- W4b bandit-camp timer held (lastBanditCampSpawnedDay write)
  -- static only (lane_w); off until a live test has switched each one on
  weather = true,        -- W4f weather targets (on by default since session 18: proven on two copies, session 17)
  holdDirector = false,  -- W4c scenario director pushed to a far day (property not in any dump)
  holdMerchants = false, -- W4g eng.spawnMerchants = false
  holdMonths = true,     -- lane 36: the count of months (TemporalComponent.monthsTotal) is the host's (the friend's ran one ahead after its join load)
  ignoreRaiders = false, -- W4a alternative to holdRaid: drawDebugFlags "ignoreRaiders" (the append is proven live,
                         -- session 14; its effect on raids is READ only, and it drops the raider quest on friends)
  fire = true,           -- a host building catches fire: b:StartFire() here; this copy's own fire clock is stopped (lane_f)
  fireOut = true,        -- the host's fire ended: burn down or put out here with the game's own routine (native, lane_f Q3)
  ownFire = true,        -- a fire only this copy has (its stand-in brigands threw torches) is put out here (lane 5)
  merch = false,         -- W4g eng:spawnFreeMerchant(home region) when the host gets a free merchant (region GUESS)
  -- the consequences of drift: off until the fingerprint is shown stable on two fresh loads (TESTPLAN step 9)
  driftHook = true,      -- call Coop.onDrift(reason): automatic resync when the daily comparison fails twice (on by default since session 18)
  clockDrift = false,    -- count a day gap as drift (a reload itself makes a gap of up to a day: see TESTPLAN)
  -- log only: the wide daily sample (buildings of every owner, units, families, livestock, stock per building, house
  -- values, approval, wealth, the raid schedule). It never asks for a resync (lane 9).
  wide = true,
  -- lane 31: the region panel's numbers (approval and its factors, public order and its factors, the problem list) are
  -- the host's on a friend in exact mode (coop_patch.dll HOLD keeps the friend's own routines from running)
  hold = true,
  -- lane 39: the same for every other lord's town (a settled region of a rival lord, with families): its totals, months,
  -- wealth, approval, public order, problems, land tax and trade route levels are the host's on a friend in exact mode
  rivals = true,
}
local DEFAULT_CFG = {
  budgetMs = 1.5,        -- work per tick (os.clock has 1 ms steps on Windows, so a tick may reach about 2 ms)
  maxSteps = 200,        -- second guard on the work per tick
  maxLine = 3800,        -- characters per line before the core's prefix (keep a line under 4 KB)
  pollEvery = 0.5, stockEvery = 2.0, exactStockEvery = 1.0, keyEvery = 30.0, bldEvery = 2.0, bldKeyEvery = 120.0, holdEvery = 1.0, fireEvery = 2.0,
  confirm = 0.3,         -- (lane 51) a changed region total goes out once it held this long (the 4-a-second check sees it then)
  confirmEvery = 0.05,   -- (lane 51) ... looked at again this often (only the pending ones)
  confirmMax = 1.0,      -- (lane 51, round two) ... but one that keeps changing goes out at most this long after its first
  confirmMin = 0.1,      --   change, as it is now, once it held 2 frames and this long (the native table is up to 0.1 s old)
  indexAge = 20.0,       -- friend's building index is rebuilt after this many seconds
  driftAfter = 2,        -- consecutive fingerprint mismatches before Coop.onDrift
  tol = 2,               -- tolerance for numbers in the fingerprint (session 9: within 2 units)
  maxDayGap = 0.5,       -- clock gap (days) logged as a mismatch
  director = 1073741824, -- 2^30: the scenario director's next action day on friends (lane_w W4c)
  wideWork = 2,          -- wide sample: objects read per tick (a building counts 1, four families 1, 25 units 1)
  wideFull = 30,         -- wide sample: every this many samples the host sends the whole sample (19 KB for the test town), else only what changed (about 1 KB)
  wideLogMax = 12,       -- wide sample: differences named per section line in the friend's log (the rest is counted)
  wideKeep = 60,         -- wide sample: days of summaries kept for Coop.world.wide()
  wideUnits = true,      -- wide sample: count the world's units per kind (false: section "un" stays empty)
  -- (lane 76) the timing proof, a TEST TOOL (see Check.proofTick): off for players
  proof = false,         -- keep dated reads of the rows players see: the host sends them when a friend names a field, a friend fills its own series
  proofEvery = 0.25,     --   a round over every row starts this many seconds after the last one started
  proofMs = 12,          --   and takes at most this many milliseconds of a tick
  proofKeep = 20,        --   seconds of reads kept
  proofSecs = "bl bs an cs rp rw li ap fa fc",   --   wide sections read (the fingerprint's parts are always read)
}
W.on = W.on or {}
for k, v in pairs(DEFAULT_ON) do if W.on[k] == nil then W.on[k] = v end end
W.cfg = W.cfg or {}
for k, v in pairs(DEFAULT_CFG) do if W.cfg[k] == nil then W.cfg[k] = v end end
W.dryLog = W.dryLog or {}
local DERIVF = { sf = "supplies_food", sw = "supplies_wood" }   -- (lane 45) one table, not a new one at every look

-- weather targets pushed once per day (lane_w W4f; all in dumps/TemporalComponent.txt): name, kind f/i/b
local WX = { { "targetRaining", "f" }, { "targetSnowing", "f" }, { "targetCloudiness", "f" }, { "windTarget", "f" },
             { "snowTarget", "f" }, { "droughtLevel", "f" }, { "rainMeter", "i" }, { "daysWithoutRainVariation", "i" },
             { "isDrought", "b" }, { "enableThunderstorm", "b" },
             { "Season", "i" }, { "isWinter", "b" }, { "wind", "f" }, { "snowLevel", "f" }, { "snowing", "f" },
             { "raining", "f" }, { "wetness", "f" }, { "cloudiness", "f" }, { "rainfall", "f" }, { "snowfall", "f" }, { "fogLevel", "f" }, { "month", "i" } }

-- ---------------------------------------------------------------- small helpers
local un, valid = A.un, A.valid
local function log(fmt, ...) A.log("world: " .. fmt, ...) end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); if ok then return a end end
local function mine(o) return W.me ~= nil and valid(o) and addr(o) == W.me end
local function bump(k, n) local S = W.S; if S and S.stats then S.stats[k] = (S.stats[k] or 0) + (n or 1) end end
-- Exact mode (lane 14): the native switch GOODS holds every building's stock on this friend's copy and the facts
-- module writes every amount exactly as the host has it. The three stock rules of this module then stand down
-- (the region's totals, the storage and site rule, and the stock section of the daily comparison): see each place.
local function exactStock() local X = rawget(C, "facts"); return type(X) == "table" and X.exact == true end
-- lane 39: a region another lord holds with a town of its own (settled, with families). Rival lords decide on the host
-- only (their AI is off on a friend), and each copy's villagers work on their own, so such a region's panel numbers
-- differed (lane 36: approval 69 / 73, wealth 47 / 344, problems, months, land tax, trade route levels).
local function rivalTown(r)
  local ok, res = pcall(function()
    local o = r.ownerPawn
    if not valid(o) or addr(o) == W.me then return false end
    if o.isBandit then return false end
    if type(o:getPawnSetupIndex()) ~= "number" then return false end
    return r.isSettled and #r.workerFamilies > 0
  end)
  return ok and res == true
end
W.rivalTown = rivalTown
-- the rival towns, looked up again every 5 s
local function rivalList(S)
  local now = os.clock()
  if W.rv and now - W.rv.t < 5.0 and W.rv.S == S then return W.rv.list end
  local t = {}
  pcall(function() local arr = S.eng.regions; for i = 1, #arr do local r = un(arr[i]); if valid(r) and rivalTown(r) then t[#t + 1] = r end end end)
  W.rv = { t = now, list = t, S = S }
  return t
end
local function H(s) local h = 5381; for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end; return h end

local function try(name, fn, ...)
  local ok, e = pcall(fn, ...)
  if not ok then
    bump("w_err"); local msg = name .. ": " .. tostring(e)
    if W.lastErr ~= msg then log("%s", msg) end   -- a failing poll would otherwise log twice a second
    W.lastErr = msg
  end
  return ok
end

local function send(line)
  if W.capture then W.capture[#W.capture + 1] = line; return end   -- self-tests: show what would be sent
  A.send(line); bump("w_sent"); bump("w_bytes", #line)
end

-- a long list goes out over several lines, each under cfg.maxLine (a friend may be on a slow link)
local function sendList(head, items, sep)
  local buf, n = {}, #head
  for _, it in ipairs(items) do
    if #buf > 0 and n + #sep + #it > W.cfg.maxLine then send(head .. table.concat(buf, sep)); buf = {}; n = #head end
    buf[#buf + 1] = it; n = n + #it + #sep
  end
  if #buf > 0 then send(head .. table.concat(buf, sep)) end
end

-- every write on the friend's world goes through here, so a dry run (W.dry = true) can show it without doing it
local function act(desc, fn)
  if W.dry then W.dryLog[#W.dryLog + 1] = desc; return true end
  local ok, e = pcall(fn)
  if not ok then bump("w_err"); W.lastErr = desc .. ": " .. tostring(e); log("FAILED %s: %s", desc, tostring(e)) end
  return ok
end

-- ---------------------------------------------------------------- jobs: heavy scans spread over ticks
-- A job is a step function called again and again until it returns true; one call does a small, bounded piece of work.
-- No coroutines: UE4SS calls from inside a coroutine were never tried in this game.
-- (lane 51) The region's totals (the top bar) are what players see: their two jobs go before every other job in the
-- queue, also before one that is half done. The others are scans of the whole building list, one building per step
-- (hostBld every 2 s, hostFire every 6 s, the day's fingerprint, the index, friendOwnFire every 4 s); a scan takes
-- 5 to 20 ticks of this queue's budget, and the totals waited behind it. A wait counted in ticks is seconds when the
-- frame rate falls: lead25, speed 8, a busy PC at 3 to 5 frames a second, a host value on the friend after up to
-- 6.2 s (65 of the 70 changes over 3 s were in those minutes). Nothing more is done per tick, only in another order;
-- a scan keeps its place in its list between steps, so it may be paused by a region pass like by a frame.
local PRIO = { hostRegions = true, friendRegions = true }
local function addJob(name, step, st)
  for _, j in ipairs(W.jobs) do if j.name == name then return false end end
  local job = { name = name, step = step, st = st or {}, prio = PRIO[name] }
  if job.prio then
    local at = #W.jobs + 1
    for i, j in ipairs(W.jobs) do if not j.prio then at = i; break end end
    table.insert(W.jobs, at, job)
  else W.jobs[#W.jobs + 1] = job end
  return true
end

-- (lane 51) ... but they never starve the others: when a tick's whole budget went to region jobs while another job
-- waited, the next tick begins with that other job (at 4 frames a second the day's fingerprint was compared on 39 of
-- 76 days with the region jobs always first; a region job waits one tick at most for this).
local function runJobs(budget)
  local t0 = os.clock(); local n = 0
  if budget and W.yieldTo then
    W.yieldTo = false
    for i, j in ipairs(W.jobs) do
      if not j.prio then if i > 1 then table.remove(W.jobs, i); table.insert(W.jobs, 1, j) end; break end
    end
  else
    -- the job that was let first for one tick goes back behind the region jobs (else it kept the head to its end)
    local seenOther = false
    for _, j in ipairs(W.jobs) do
      if not j.prio then seenOther = true
      elseif seenOther then
        local p, o = {}, {}
        for _, x in ipairs(W.jobs) do if x.prio then p[#p + 1] = x else o[#o + 1] = x end end
        for i = 1, #o do p[#p + 1] = o[i] end
        W.jobs = p
        break
      end
    end
  end
  local onlyPrio = true
  while #W.jobs > 0 do
    if budget and (os.clock() - t0 >= budget or n >= W.cfg.maxSteps) then break end
    if not budget and n >= 1000000 then log("flush stopped after %d steps", n); break end
    local j = W.jobs[1]; local s0 = os.clock()
    if not j.prio then onlyPrio = false end
    local ok, done = pcall(j.step, j.st)
    local ms = (os.clock() - s0) * 1000
    if ms > (W.maxStepMs or 0) then W.maxStepMs = ms; W.maxStepJob = j.name end
    W.lastJob = j.name                                  -- (lane 51) the watchdog's "last world job"
    n = n + 1
    if not ok or done then
      if not ok then bump("w_err"); W.lastErr = j.name .. ": " .. tostring(done); log("job %s failed: %s", j.name, tostring(done)) end
      -- (lane 51) the job that ran, by itself: a region job queued during its step stands in front of it now
      for i = 1, #W.jobs do if W.jobs[i] == j then table.remove(W.jobs, i); break end end
    end
  end
  if budget and n > 0 and onlyPrio then
    for _, j in ipairs(W.jobs) do if not j.prio then W.yieldTo = true; break end end
  end
  local ms = (os.clock() - t0) * 1000
  if budget and ms > (W.maxTickMs or 0) then W.maxTickMs = ms end
end

-- ---------------------------------------------------------------- identity (own copy; same style as the town module)
-- A region by its unique tag (Region.regionUniqueTag, NameProperty in dumps/Region.txt; first read live by self-test t1),
-- falling back to its name (regionName: read live in probes/p5-sync-tests/lib.lua). Only [%w_.] so it is one word.
function W.rkey(r)
  local ok, k = pcall(function() return r.regionUniqueTag:ToString() end)
  if not ok or type(k) ~= "string" or k == "" or k == "None" then
    local ok2, n = pcall(function() return r.regionName:ToString() end)
    k = "n_" .. ((ok2 and type(n) == "string") and n or "unknown")
  end
  return (k:gsub("[^%w_%.]", "_"))
end

-- A building by type plus position rounded to 10 cm: unique in every recorded fingerprint (README session 8);
-- building ids are regenerated on every load (COMMON_BRIEF), so they cannot be used.
function W.bkey(b)
  local l = b:K2_GetActorLocation()
  return string.format("%d@%d,%d", A.btype(b), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5))
end

local function parseKey(k)
  local t, x, y = (k or ""):match("^(%d+)@(%-?%d+),(%-?%d+)$")
  return tonumber(t), tonumber(x), tonumber(y)
end

local function regionMap(force)
  local X = W.ridx; local now = os.clock()
  if X and now - X.t < 30 and not (force and now - X.t >= 5) then return X.map end
  local map = {}; local arr = W.S.eng.regions
  for i = 1, #arr do local r = un(arr[i]); if valid(r) then map[W.rkey(r)] = r end end
  W.ridx = { map = map, t = now }
  return map
end

function W.regionByKey(k)
  local r = regionMap(false)[k]
  if not valid(r) then r = regionMap(true)[k] end
  if valid(r) then return r end
end

-- the friend's index of buildings by key is built by a job (a full scan is too long for one tick)
local function indexJob(st)
  local arr = W.S.eng.buildingArr
  st.map = st.map or {}; st.i = (st.i or 0) + 1
  if st.i <= #arr then local b = un(arr[st.i]); if valid(b) then st.map[W.bkey(b)] = b end; return false end
  W.bidx = { map = st.map, t = os.clock() }
  return true
end

local function needIndex(force)
  local X = W.bidx
  if force or not X or os.clock() - X.t >= W.cfg.indexAge then addJob("index", indexJob, {}) end
end

-- the same building on this copy: exact key, else a neighbour within 10 cm (a rounding edge); the cached object is
-- checked again (still valid, still at that place) before anyone writes to it
function W.buildingByKey(k)
  local X = W.bidx; if not X then return nil end
  local t, x, y = parseKey(k); if not t then return nil end
  local b = X.map[k]
  if not valid(b) then
    b = nil
    for dx = -1, 1 do for dy = -1, 1 do
      if not b then local c = X.map[string.format("%d@%d,%d", t, x + dx, y + dy)]; if valid(c) then b = c end end
    end end
  end
  if not valid(b) then return nil end
  local ok, k2 = pcall(W.bkey, b); if not ok then return nil end
  local t2, x2, y2 = parseKey(k2)
  if t2 ~= t or math.abs(x2 - x) > 1 or math.abs(y2 - y) > 1 then return nil end
  return b
end

-- tradeable good types: the list session 9 pushed (probes/p9-live-sync/libA.lua goodtypes())
local function goods(S)
  if W.goods then return W.goods end
  local t = {}; local arr = S.eng.tradeableGoods
  for i = 1, #arr do local v = arr[i]; if type(v) == "number" then t[#t + 1] = v end end
  W.goods = t
  return t
end

-- a building's inventory as { [goodType] = amount }
-- status: proven live on one copy (README session 14, W6 / W2 probes read Inventory this way)
-- A record is read directly. It used to go through un() first: a protected call of a "get" that a record of this
-- list does not have, which fails and costs about 0.3 ms per record (lane 9, measured on 92 buildings with 102
-- records: 360 against 8 microseconds per building, the same goods both ways). After the failed "get" the old code
-- read the record directly too, so what is read has not changed; un() is kept for a record that does not read so.
local function invOf(b)
  local m = {}; local inv = b.Inventory
  for j = 1, #inv do
    local x = inv[j]; local t, a = x.Type, x.amt
    if type(t) ~= "number" then x = un(x); t, a = x.Type, x.amt end
    if type(t) == "number" and type(a) == "number" then m[t] = (m[t] or 0) + a end
  end
  return m
end

-- a lord by copy-independent facts only (live session 14: object names such as PawnCPP_AI_2147470076 differ between
-- copies). The address is used only to recognise this copy's own lord (S.p1), never written out.
local function ownerCode(o)
  if not valid(o) then return "-" end
  if addr(o) == W.me then return "P" end
  local okB, bandit = pcall(function() return o.isBandit end)            -- PawnCPP.isBandit (dumps/PawnCPP.txt)
  if okB and bandit then return "B" end
  local okI, idx = pcall(function() return o:getPawnSetupIndex() end)   -- registry.tsv; also used by the core's N message
  if okI and type(idx) == "number" then return "A" .. idx end
  return "X"
end

-- ---------------------------------------------------------------- session / world reset
-- Called from onWorld and from every tick: a module loaded in the middle of a world never gets onWorld, and a new
-- Coop.start() makes a new S. Every cached game object is dropped here.
local function fresh(S)
  if W.S == S and W.world == S.worlds then return end
  local session = W.S ~= S
  W.S = S; W.world = S.worlds
  W.uRole = nil                                              -- (lane 59) the units of a role, kept up to 2 s: not past a load
  W.jobs = {}; W.ridx = nil; W.bidx = nil; W.goods = nil; W.tradeSetF = nil; W.owned = nil; W.day = nil; W.ev = nil; W.merch = nil; W.fires = {}; W.pref = nil; W.ruins = nil; W.rv = nil; W.rivalsOut = nil
  W.sent = { reg = {}, bld = {}, lord = {} }; W.pend = {}      -- host: everything is sent again after a load (a keyframe)
  W.fp = { mine = {}, host = {} }; W.miss = 0; W.missT = nil; W.aheadT = nil; W.clockMiss = 0
  W.t = { poll = 0, stock = 0, key = os.clock(), bld = 0, bkey = os.clock(), hold = 0, fire = 0, fstock = 0, fbld = 0 }
  -- friend: a load usually comes with a core hold (C.hold), during which W lines are dropped, so stored host values may
  -- be stale; forget them and wait for the host's next keyframe (at most cfg.keyEvery s; the loaded save is the host's)
  W.fr = { reg = {}, lord = {}, bld = {}, bdirty = {}, firePend = {}, hostFires = {}, ownFire = {}, ownOut = {}, hadHostFire = {}, dirty = false,
           hold = {}, holdGen = {}, holdDirty = false }
  -- the wide sample (log only): the sample being taken, the host's lines, both copies' samples, what the host last sent
  W.fpLater = nil
  W.wd = { watches = {}, batches = {}, samples = {}, fpSamples = {}, details = {}, early = {}, objects = {}, run = nil, posts = {}, inb = {}, host = {}, mine = {}, sent = {}, serial = (W.wd and W.wd.serial) or 0, tickN = 0 }
  log("reset for world %d (%s)", S.worlds, session and "new session" or "world loaded")
end

local function drift(S, reason)
  bump("w_drift"); W.lastDrift = reason
  log("DRIFT %s", reason)
  local hook = rawget(C, "onDrift")
  if type(hook) ~= "function" then log("no Coop.onDrift hook registered")
  elseif not W.on.driftHook then log("Coop.onDrift not called: item driftHook is off")
  else local ok, e = pcall(hook, reason); if not ok then log("Coop.onDrift failed: %s", tostring(e)) end end
end

-- ---------------------------------------------------------------- drift fingerprint (lane_w W7, fingerprint_w.lua)
-- status: static read only (lane_w W7; probe_W7 not run). Section forms follow the live-run p5 lib.lua where they differ
-- (owners by our-lord / AI instead of object names; ownership by address against S.p1, since the helper lord is a
-- second pawn of the same class). Sampled once per day change on each copy and paired by day number.
-- Everything a region has (families, wealth, approval, public order, stock) is read for EVERY region the lord owns
-- and named by the region's tag. It used to be read for "the owned region nearest to this copy's camera": with two
-- owned regions and two players looking at different towns, the copies compared different regions and asked for a
-- resync every two game days (lane 3). Region ids are not used either: they differ per copy and per load.
local Check = {}  -- read-only three-second follow-ups, shared by the fingerprint and wide checks
local FP_ORDER = { "D", "B", "C", "F", "O", "W", "M", "N", "R", "S", "Q" }
local function fpEncode(P) local t = {}; for _, s in ipairs(FP_ORDER) do t[#t + 1] = s .. (P[s] or "-") end; return table.concat(t, " ") end
local function fpDecode(w, from) local P = {}; for i = from, #w do local s = w[i]; P[s:sub(1, 1)] = s:sub(2) end; return P end
local function sec(P, tag, fn) local ok, v = pcall(fn); P[tag] = ok and tostring(v) or "ERR" end

local function fpSoldiers(S)
  if not valid(S.sc) then return "ERR" end
  local sum = {}
  for _, pw in ipairs(A.pawns()) do
    if valid(pw) then
      local code = ownerCode(pw); local arr = pw.commandedSquads
      for i = 1, #arr do
        local h = arr[i].Value
        if h and h ~= 0 and S.sc:IsValidSquad({ Value = h }) then
          local fleeing = false
          pcall(function() fleeing = S.sc:GetSquad({ Value = h }).Control == 3 end)          -- 3 = Fleeing
          if not fleeing and S.role == "friend" and S.mir and S.mir[h] and S.mir[h].routed then fleeing = true end
          if not fleeing then sum[code] = (sum[code] or 0) + S.sc:GetUnitCount({ Value = h }) end
        end
      end
    end
  end
  local t = {}; for code, n in pairs(sum) do if n > 0 then t[#t + 1] = code .. "=" .. n end end
  table.sort(t); return table.concat(t, ",")
end

local function fpOwners(eng, P)
  local t, arr = {}, eng.regions
  for i = 1, #arr do
    local r = un(arr[i])
    if valid(r) then
      local k, owner = W.rkey(r), ownerCode(r.ownerPawn)
      t[#t + 1] = k .. "=" .. owner
      P.detail.O[k] = owner
    end
  end
  table.sort(t); return string.format("%x", H(table.concat(t, ",")))
end

local function fpBuilding(st, b)
  -- The pile a demolished or moved building leaves behind (type 88, "supply_dump") is not compared: each copy's own
  -- carriers empty it at their own pace, so one copy still has it when the other does not. Seen in session 21: after
  -- a demolish at speed 4 the pile stayed on one copy for days and forced a resync. Its goods are stock, which the
  -- stock rules already keep equal.
  local dump = false; if valid(b) then pcall(function() dump = b:GetType() == 88 end) end
  if valid(b) and not dump and mine(b.ownerPawn) then
    local ok, e = pcall(function()
      local k = W.bkey(b); local built = b:IsConstructed()
      local lv, workers, residents = b.lv, b:getNumActiveWorkerFamilies(), b:getNumResidingFamilies()
      local fire, sleep = b.onFire, b.sleep
      st.B[#st.B + 1] = k .. (built and "B" or "u") .. lv .. "w" .. workers .. "r" .. residents .. (fire and "F" or "") .. (sleep and "S" or "")
      local P = st.P
      P.detail.B[k] = P.detail.B[k] and "?" or table.concat({ built and 1 or 0, lv, workers, residents, fire and 1 or 0, sleep and 1 or 0 }, "|")
      P.at.rows[k] = Check.clock(W.S)
      -- A building being upgraded (storehouse, granary, house level) keeps working: its inventory is its normal
      -- stock, which each copy's own carriers move, not construction deliveries. Comparing it forced a resync
      -- every two days for as long as the upgrade lasted (session 21). Only fresh sites are compared here; the
      -- end of an upgrade comes from the host through the sites rule.
      local upgrading = false; pcall(function() upgrading = b.isBeingUpgraded and true or false end)
      if W.on.bstock and not built and not upgrading then
        local g = {}; for t, a in pairs(invOf(b)) do g[#g + 1] = t .. ":" .. a end
        table.sort(g); local inventory = table.concat(g, ","); st.C[#st.C + 1] = k .. "=" .. inventory
        P.detail.C[k] = P.detail.C[k] and "?" or (inventory ~= "" and inventory or "0")
      end
    end)
    if not ok then if st.B then st.B[#st.B + 1] = "ERR" end; st.err = tostring(e) end
  end
end

-- one owned region's three parts of the fingerprint (families, numbers, stock), each "<tag>:<body>" or "<tag>:ERR".
-- Shared by the day sample and the timing proof (Check.proof), so both read a region the same way.
local function fpRegionWords(S, r, k)
  local okF, f = pcall(function()
    return k .. ":" .. #r.workerFamilies .. "/" .. r:getNumHomelessFamilies() .. "/" .. r:getNumTotalPopulation() .. "/L" .. r.settlementLevel
      .. "/" .. r:getNumFamiliesOfLv(1) .. "," .. r:getNumFamiliesOfLv(2) .. "," .. r:getNumFamiliesOfLv(3) .. "," .. r:getNumFamiliesOfLv(4)
  end)
  local okR, x = pcall(function() return string.format("%s:%d/%d/%d", k, r.regionalWealth, r.Approval, r.publicOrder) end)
  local okS, s = pcall(function()
    local t = {}
    for _, g in ipairs(goods(S)) do local v = r:getStockOfGood(g, false, false); if v ~= 0 then t[#t + 1] = g .. "=" .. v end end
    return k .. ":" .. table.concat(t, ",")
  end)
  return okF and f or (k .. ":ERR"), okR and x or (k .. ":ERR"), okS and s or (k .. ":ERR")
end

local function fpJob(st)
  local S = W.S; local eng = S.eng
  if not st.P then                                   -- step 1: calendar, weather, merchants, lord numbers, home stock
    local P = { at = { rows = {} }, detail = { B = {}, C = {}, O = {} } }; st.P = P; st.B = {}; st.C = {}; st.i = 0
    st.day = eng:getDaysTotal(); P.D = tostring(st.day)
    local T = eng.TemporalComponent
    sec(P, "W", function() if not valid(T) then return "ERR" end; return string.format("%d,%d,%d,%d,%d,%d", T.Season, T.month, T.rainMeter, T.isDrought and 1 or 0, T.isWinter and 1 or 0, T.daysWithoutRainVariation) end)
    sec(P, "M", function() return string.format("%d,%d", #eng.freeMerchants, #eng.livestockMerchants) end)
    -- N: the lord's own numbers (treasury, influence, king's favour)
    sec(P, "N", function() return string.format("%d,%d,%d", S.p1.silver, S.p1.influence, S.p1.kingsFavour) end)
    -- Q: soldiers under arms per lord (our lord P, bandits B, other lords A<index>): squads are not part of any
    -- region, so without this section a copy whose armies differ would still look equal. Added after the 24-day run
    -- of README session 15, where fights between other lords were mirrored but never compared.
    -- A squad that is routing is counted on neither copy: on the host it drops out of its lord's list while it
    -- flees, on a friend's copy it stays in the list (the rout is the game's own there, or imitated), so a rout
    -- that lasted over two day checks looked like drift (lane 4: 36 against 45) and cost a resync.
    sec(P, "Q", function() return fpSoldiers(S) end)
    P.at.world = Check.clock(S)
    st.regs = {}; st.ri = 0; st.F = {}; st.R = {}; st.S = {}
    local arr = eng.regions
    for i = 1, #arr do local r = un(arr[i]); if valid(r) and mine(r.ownerPawn) then st.regs[#st.regs + 1] = r end end
    return false
  end
  if not st.regionsDone then                         -- step 2: one owned region per step (families, numbers, stock)
    st.ri = st.ri + 1
    local r = st.regs[st.ri]
    if r then
      if valid(r) then
        local k = W.rkey(r)
        st.P.at[k] = Check.clock(S)
        st.F[#st.F + 1], st.R[#st.R + 1], st.S[#st.S + 1] = fpRegionWords(S, r, k)
      end
      return false
    end
    st.regionsDone = true                            -- then the owner of every region
    local P = st.P
    table.sort(st.F); table.sort(st.R); table.sort(st.S)
    P.F = (table.concat(st.F, "|"):gsub("%s", "_"))  -- readable on purpose: when it differs the log shows what (session 20)
    P.R = #st.R > 0 and table.concat(st.R, "|") or "-"
    P.S = #st.S > 0 and table.concat(st.S, "|") or "-"
    sec(P, "O", function() return fpOwners(eng, P) end)
    P.at.O = Check.clock(S)
    return false
  end
  local arr = eng.buildingArr                         -- then one building per step
  st.i = st.i + 1
  if st.i <= #arr then
    local b = un(arr[st.i])
    fpBuilding(st, b)
    return false
  end
  -- (lane 63, test switch, console on a friend only: Coop.fpSkew = true) a lasting difference that no load can fix:
  -- one made-up entry in this copy's building section, so the join module's escalation and breaker can be run
  if rawget(C, "fpSkew") and S.role == "friend" then st.B[#st.B + 1] = "TEST@skew" end
  table.sort(st.B); table.sort(st.C)
  st.P.B = string.format("%x/%d", H(table.concat(st.B, "|")), #st.B)
  -- (lane 52, test switch, console on both copies: Coop.fpLog = true) the building section's entries of each day, so
  -- a differing "B" can be read line by line from the two logs
  if rawget(C, "fpLog") then log("FPB day %s %s %s", tostring(st.day), st.P.B, table.concat(st.B, " ")) end
  st.P.C = W.on.bstock and string.format("%x/%d", H(table.concat(st.C, "|")), #st.C) or "-"
  st.P.at.buildings = Check.clock(S)
  if st.done then st.done(st.day, st.P) end
  return true
end

local function nums(s) local t = {}; for x in (s or ""):gmatch("[^,]+") do t[#t + 1] = tonumber(x) end; return t end
local function kv(s) local t = {}; for g, a in (s or ""):gmatch("(%d+)=(%-?%d+)") do t[tonumber(g)] = tonumber(a) end; return t end

-- a = host, b = this copy. A section is compared only when the item that corrects it is on; otherwise it would differ
-- by design (for example merchants held off on friends) and fire Coop.onDrift every few days.
function W.compareFp(a, b)
  local bad = {}; local tol = W.cfg.tol
  local function eq(s) if (a[s] or "") ~= (b[s] or "") then bad[#bad + 1] = s; if s == "F" then log("families differ: host %s, here %s", tostring(a.F), tostring(b.F)) end end end
  eq("B"); eq("F"); eq("O")                     -- not correctable by name: families, buildings, owners -> reload
  if W.on.bstock then eq("C") end
  if W.on.weather and a.W ~= "ERR" and b.W ~= "ERR" then
    -- season, month, rain counter, drought, winter, dry-spell variation. The rain counter steps once a day on each copy
    -- and the host's value is re-applied within a second, but this sample is taken right at the day change, so it may
    -- be one step off (session 17: two needless repairs in a row). One step is allowed; the rest must be equal.
    local x, y = nums(a.W), nums(b.W); local same = #x == #y
    for i = 1, #x do if same and math.abs((x[i] or 0) - (y[i] or 0)) > (i == 3 and 1 or 0) then same = false end end
    if not same then bad[#bad + 1] = "W" end
  end
  if W.on.merch then eq("M") end
  if a.N and b.N and a.N ~= "ERR" and b.N ~= "ERR" then      -- the lord's own numbers
    local x, y = nums(a.N), nums(b.N)
    local use = { W.on.silver, W.on.lordExtra, W.on.lordExtra }
    local names = { "silver", "influence", "favour" }
    for i = 1, 3 do if use[i] and x[i] and y[i] and math.abs(x[i] - y[i]) > tol then bad[#bad + 1] = names[i] .. ":" .. x[i] .. "/" .. y[i] end end
  end
  -- per region, by tag; a region only one copy's lord owns is not compared here (the owners section says so)
  local function byTag(s) local t = {}; for tag, body in (s or ""):gmatch("([^|:]+):([^|]*)") do t[tag] = body end; return t end
  local ra, rb = byTag(a.R), byTag(b.R)
  for tag, body in pairs(ra) do
    local here = rb[tag]
    if here and body ~= "ERR" and here ~= "ERR" then
      local x, y = {}, {}
      for v in body:gmatch("[^/]+") do x[#x + 1] = tonumber(v) end
      for v in here:gmatch("[^/]+") do y[#y + 1] = tonumber(v) end
      -- approval and public order cannot be written: the game rebuilds them from the town within a frame (README
      -- session 17: a written value was gone 0.2 s later; the factor list is rebuilt each day). They are a symptom
      -- only, measured within 4 on matching towns, so they get a wider margin; a larger gap means the towns differ.
      local use = { W.on.wealth, true, true }; local names = { "wealth", "approval", "order" }; local tols = { tol, 10, 10 }
      for i = 1, 3 do if use[i] and x[i] and y[i] and math.abs(x[i] - y[i]) > tols[i] then bad[#bad + 1] = names[i] .. "@" .. tag .. ":" .. x[i] .. "/" .. y[i] end end
    end
  end
  if W.on.stock and not exactStock() then        -- (exact mode: the totals differ by what is in hands, by design)
    -- stock is corrected every 2 s of real time, so at game speed 4 the two samples can be four times as far apart in
    -- game time: the margin grows with the speed and with the size of the pile (session 20: 79 against 76 loaves at
    -- speed 4 forced a resync)
    local sp = 1; pcall(function() sp = math.max(1, math.floor((tonumber(C.s.eng.gameSpeed) or 1) + 0.5)) end)
    local function tolS(v) return math.max(tol * sp, math.ceil(math.abs(v) * 0.04)) end
    local sa, sb = byTag(a.S), byTag(b.S)
    for tag, body in pairs(sa) do
      local here = sb[tag]
      if here and body ~= "ERR" and here ~= "ERR" then
        local p, q = kv(body), kv(here); local seen = {}
        for g, v in pairs(p) do seen[g] = true; local m = q[g] or 0; if math.abs(v - m) > tolS(math.max(v, m)) then bad[#bad + 1] = "good" .. g .. "@" .. tag .. ":" .. v .. "/" .. m end end
        for g, v in pairs(q) do if not seen[g] and math.abs(v) > tolS(v) then bad[#bad + 1] = "good" .. g .. "@" .. tag .. ":0/" .. v end end
      end
    end
  end
  if a.Q and b.Q and a.Q ~= "ERR" and b.Q ~= "ERR" then      -- soldiers per lord; a death can be a second late, so allow 3
    local p, q = {}, {}
    for code, n in a.Q:gmatch("([%w%-]+)=(%d+)") do p[code] = tonumber(n) end
    for code, n in b.Q:gmatch("([%w%-]+)=(%d+)") do q[code] = tonumber(n) end
    for code, n in pairs(p) do if math.abs(n - (q[code] or 0)) > 3 then bad[#bad + 1] = "soldiers" .. code .. ":" .. n .. "/" .. (q[code] or 0) end end
    for code, n in pairs(q) do if not p[code] and n > 3 then bad[#bad + 1] = "soldiers" .. code .. ":0/" .. n end end
  end
  return bad
end

-- (lane 71) the families part of the fingerprint as it is now, for the regions the host's part names (same text as the
-- sample's step 2 builds)
function W.famNow(S, hostF)
  local t = {}
  for part in tostring(hostF):gmatch("[^|]+") do
    local tag = part:match("^([^:]+):")
    local r = tag and W.regionByKey(tag)
    if r and valid(r) then
      local k = W.rkey(r)
      local okF, f = pcall(function()
        return k .. ":" .. #r.workerFamilies .. "/" .. r:getNumHomelessFamilies() .. "/" .. r:getNumTotalPopulation() .. "/L" .. r.settlementLevel
          .. "/" .. r:getNumFamiliesOfLv(1) .. "," .. r:getNumFamiliesOfLv(2) .. "," .. r:getNumFamiliesOfLv(3) .. "," .. r:getNumFamiliesOfLv(4)
      end)
      t[#t + 1] = okF and f or (k .. ":ERR")
    end
  end
  table.sort(t)
  return (table.concat(t, "|"):gsub("%s", "_"))
end

local judgeFp
local function tryCompare(S, day)
  local a, b = W.fp.host[day], W.fp.mine[day]
  if not (a and b) then return end
  W.fp.host[day] = nil; W.fp.mine[day] = nil
  for d in pairs(W.fp.host) do if d < day - 3 then W.fp.host[d] = nil end end
  for d in pairs(W.fp.mine) do if d < day - 3 then W.fp.mine[d] = nil end end
  if W.on.wide then Check.fingerprint(day, a, b) end
  judgeFp(S, day, a, b, false)
end
-- (lane 71) a pair whose families part waits for the host's growth of the day (see below): judged again later
function W.fpLaterStep(S)
  local L = W.fpLater; if not (L and #L > 0) then return end
  local now = os.clock()
  for i = #L, 1, -1 do
    local x = L[i]
    if now >= x.t then
      table.remove(L, i)
      local b2 = {}; for k, v in pairs(x.b) do b2[k] = v end
      local okF, f = pcall(W.famNow, S, x.a.F); if okF and f and x.a.F then b2.F = f end
      local okR, rr = pcall(W.regNow, S, x.a.R); if okR and rr and x.a.R then b2.R = rr end
      local was = W.compareFp(x.a, x.b)
      local before = table.concat(was, " ")
      local after = W.compareFp(x.a, b2)
      if #after == 0 then bump("w_fpTimingOk"); log("fingerprint day %d: %s at the sample, the host's 2 s later (the host's word came after the sample): not a difference", x.day, before)
      else
        -- (lane 76) a timing part beside another part: say which timing parts were the host's 2 s later
        local left = {}; for _, y in ipairs(after) do left[y] = true end
        local t = {}; for _, y in ipairs(was) do if W.onlyTiming({ y }) and not left[y] then t[#t + 1] = y end end
        if #t > 0 then bump("w_fpTimingOk"); log("fingerprint day %d: %s at the sample, the host's 2 s later (the host's word came after the sample): not a difference; the rest is judged as it was sampled", x.day, table.concat(t, " ")) end
      end
      judgeFp(S, x.day, x.a, b2, true)
    end
  end
end
-- (lane 71) a day's differences are all timing parts (see judgeFp): the families part, a region's wealth
function W.onlyTiming(bad)
  if #bad == 0 then return false end
  for _, x in ipairs(bad) do if x ~= "F" and not tostring(x):find("^wealth@") then return false end end
  return true
end
-- (lane 76) a day with a timing part among its differences (session l76i, days 364 and 395: "W wealth@hof:259/253":
-- the weather part differed too, so the wealth was not taken again and stood in the log as a difference; the friend
-- had the host's 259 0.7 s after its sample)
function W.anyTiming(bad)
  for _, x in ipairs(bad) do if W.onlyTiming({ x }) then return true end end
  return false
end
-- (lane 71) the region part of the fingerprint as it is now, for the regions the host's part names (same text as the
-- sample's step 2 builds: wealth / approval / public order)
function W.regNow(S, hostR)
  local t = {}
  for part in tostring(hostR):gmatch("[^|]+") do
    local tag = part:match("^([^:]+):")
    local r = tag and W.regionByKey(tag)
    if r and valid(r) then
      local k = W.rkey(r)
      local okR, x = pcall(function() return string.format("%s:%d/%d/%d", k, r.regionalWealth, r.Approval, r.publicOrder) end)
      t[#t + 1] = okR and x or (k .. ":ERR")
    end
  end
  table.sort(t)
  return #t > 0 and table.concat(t, "|") or "-"
end
judgeFp = function(S, day, a, b, again)
  local bad = W.compareFp(a, b)
  -- (lane 71) TIMING PARTS. Two parts of this copy's sample can be a step behind the host's at the day change itself,
  -- by how the host's word reaches this copy, not by a real difference:
  --   families: with FAMROLL on this copy's game makes no person or family; the host's growth of the day comes as the
  --             people module's V G lines and is made here half a second after this copy's own day change (sessions
  --             l71a, l71b: "families differ", one person or family behind, up to 3 days in a row);
  --   wealth:   the host's day change consumes and adds regional wealth in its own updateDay; this copy's wealth is
  --             held (HOLD) and written from the host's push, which goes out when the host's value has settled (lane
  --             51: "waits like a total", up to a second). So this copy's sample at its own day change holds the
  --             wealth of before the host's day (every lane's checks: wealth@hof 99/93, 428/412, 545/539, 233/227: the
  --             host a day's net income ahead; lane 74: two days in a row, a repair).
  -- A day that has such a part among its differences is judged once more 2 s later, with those two parts of this copy
  -- taken again then (W.famNow, W.regNow); every other part keeps its sample. (lane 76: also when another part
  -- differs beside it; before, only when nothing else differed. The 3 s check of each field, Check.fingerprint, has
  -- already been started from the samples themselves and is not touched by this.)
  if #bad > 0 and not again and W.anyTiming(bad) then
    W.fpLater = W.fpLater or {}; W.fpLater[#W.fpLater + 1] = { day = day, a = a, b = b, t = os.clock() + 2.0 }
    bump("w_fpTimingWait"); return
  end
  -- (lane 63) the last differing pair, for the join module's breaker (W.diffText)
  if #bad > 0 then W.lastBad = { day = day, text = table.concat(bad, " "), host = fpEncode(a), here = fpEncode(b), t = os.clock() } end
  -- (join, lane 15) A copy that loaded the host's save ALONE starts at the beginning of the save's day, and the
  -- host did not wait for it: it runs behind the host's clock until it has caught up (the core's follow-speed
  -- block). While it is more than cfg.maxDayGap days behind, its own day N is compared with numbers the host has
  -- pushed days later, so a difference then says nothing: such a day is not counted. (The core keeps the gap from
  -- every state line of the host in S.clockGap.) Other tests of a difference (families, camps, the lord's values,
  -- refused actions) do not depend on the day and keep working.
  local behind = W.S and tonumber(W.S.clockGap)
  if #bad > 0 and behind and behind > W.cfg.maxDayGap then
    W.miss = 0; W.missT = nil; bump("w_fpBehind")
    log("fingerprint day %d differs: %s, with this copy %.2f days behind the host's clock: not counted", day, table.concat(bad, " "), behind)
    return
  end
  -- Only the building sections differ, and this copy has buildings finished ahead of the host: expected for a while,
  -- not drift. Each copy's builders pick their sites in their own order, so the lead can last (session 20: 17 game
  -- days for a storehouse the host had no timber for). It is tolerated for 5 minutes of real time; after that the
  -- normal rule below counts it and a resync puts this copy back on the host's state.
  if #bad == 0 then W.aheadT = nil end
  if #bad > 0 and C.sites and C.sites.ahead and not (W.aheadT and os.clock() - W.aheadT > 300.0) then
    local onlyBuildings = true
    for _, x in ipairs(bad) do if x ~= "B" and x ~= "C" then onlyBuildings = false end end
    if onlyBuildings then
      local okA, n = pcall(C.sites.ahead, S)
      if okA and n and n > 0 then
        W.aheadT = W.aheadT or os.clock()
        W.miss = 0; W.missT = nil; bump("w_fpAhead")
        log("fingerprint day %d differs: %s, with %d building(s) here finished ahead of the host: not counted", day, table.concat(bad, " "), n)
        return
      end
    end
  end
  if #bad == 0 then
    W.miss = 0; W.missT = nil; bump("w_fpOk"); log("fingerprint day %d equal", day)
  else
    W.miss = W.miss + 1; bump("w_fpBad"); W.missT = W.missT or os.clock()
    log("fingerprint day %d differs: %s (%d in a row)", day, table.concat(bad, " "), W.miss)
    -- "two days in a row" is 80 s at normal speed but only 20 s at speed 4, less than a building site needs to settle
    -- on both copies (session 20: two needless resyncs). The difference must also have lasted 75 s of real time.
    if W.miss >= W.cfg.driftAfter and os.clock() - W.missT >= 75.0 then
      W.miss = 0; W.missT = nil
      drift(S, string.format("fingerprint differs for %d days in a row: %s", W.cfg.driftAfter, table.concat(bad, " ")))
    end
  end
end

-- ---------------------------------------------------------------- the wide daily sample: LOG ONLY (lane 9)
-- The daily comparison above decides about resyncs and reads the player's own town only. A 50-day run said "equal" on
-- every day while whole buildings stood on one copy only (a rival lord's town) and many values of the player's own
-- buildings differed (docs/design/host_run_villagers_study.txt section 6; tools/dev/statediff.sh). This part makes
-- those differences visible and does nothing else:
--   * it never asks for a resync and never writes to the game;
--   * it has its own wire line (W G), its own store and its own stepper: nothing here reaches compareFp, W.miss or
--     the job queue of the pushes (a long job in that queue would delay the 2 s stock push);
--   * switch: item "wide" (Coop.world.set("wide", false) stops the sampling, the sending and the comparing).
-- Each copy takes the sample at its own day change, a few objects per tick (cfg.wideWork; a building counts 1). The
-- host sends it (the whole sample after a load, a join and every cfg.wideFull days; in between only the entries that
-- changed); the friend compares by key and logs, per day, one line per section that differs and one summary line.
--   W G <tag> <section> <key>|<v1>|<v2>...;<key>|...      <key>|! = the entry is gone        tag = day number, or n<k>
--   W G <tag> END <serial> <base serial, 0 = whole sample> <lines> <ms> <ticks> <day>
-- Keys are copy-independent: a building is type@x,y (W.bkey), a region its tag, a family <region tag>:F<place in the
-- region's list>. A field that is one property of the game carries that property's name, so the lines can be set
-- beside the output of tools/dev/statediff.sh (a list is its length, an object a building key or 1 / 0).
-- sparse = an entry of zeros only is not stored (most buildings have no animals and no fuel day).
-- The sections, as the log names them:
--   bl buildings: owner, built, level, on fire, asleep     bw workers and work settings      bs stock
--   hv house values (fuel day, water, market days)         an animals and carts              bd lists the game derives
--   bx what the players set on a building                  fd fields                         ro regions: owner, kind
--   mt maintenance of a building that has it: status, slider, need, each tracker (lane 67; trk per type as t<goods>)
--   rp people of a region    ap approval and its inputs    rw wealth, supplies               li livestock per kind
--   rs what the players set on a region                    fa families: home, workplace, stall, members
--   fc families: hunger, cold, sickness ...                un units of the world per kind    sc raid and camp schedule
--   wx calendar and weather  en the engine's lists         lo the player's lord
-- A line of the friend's log:  wide <day> <section> differ=<n> player=<of them on the player's own> held=<by design>
--   max=<largest gap> sum=<all gaps> onlyHost=<entries> onlyHere=<entries>: <key> <field> <host>/<here>[(held)] [<owner>]; ...
-- and per day:                 wide <day> summary <section>=<n>[p<player's own>][+<held>h] ... | values, milliseconds, ticks
local WIDE = {
  -- every building of every owner
  { "bl", { "owner", "built", "lv", "onFire", "sleep" } },
  { "bw", { "numActiveWorkerFamilies", "assignedFamilyIDs", "occupantFamilyIDs", "buildPriority", "secondaryPriority", "stockFuelFor",
            "upgradesDone", "Extensions", "artisanJob", "isBeingUpgraded", "constructionGoods" } },
  { "bs", { "numStoredGeneric", "numStoredLarge", "numStoredPantry", "Inventory", "goods" } },   -- goods: per good, the player's buildings only
  { "hv", { "refuelDay", "refueled", "needsRefueling", "waterSupply", "marketDaysLeft", "mourningPeriod" }, sparse = true },
  { "an", { "animals", "animalsOnPasture", "oxen", "activeOxen", "Carts" }, sparse = true },
  { "bd", { "buildings", "Resources", "distributedGoods", "roadDecals", "additionalWorkPositions", "snappedToRoad", "freeStallTransforms" } },   -- lists the game derives
  -- what the players set on a building (docs/coverage/fingerprint_gaps.md S053, S054, S060, S063)
  { "bx", { "allowMarketStalls", "supplyOverstocking", "workAreaLimited", "workAreaRange", "sellingType", "muleTrain_buyingType", "muleTrain_sellingType",
            "allowLabourers", "targetSquadSize", "storageFilter", "TargetStock", "customBuildingFlags", "recruits", "blueprints", "walls" } },
  -- crops (S055). In the test saves these are the vegetable gardens behind houses (8 of 110 buildings); no save has a
  -- crop field proper. An entry that is the game's default (crop rotation on, nothing else) is not stored.
  { "fd", { "bRotateCrops", "fieldOperationMode", "forceHarvest", "field_ploughingPerc", "field_sowingPerc", "field_growingPerc",
            "field_harvestingPerc", "field_numReadyToHarvest", "field_numUnplowed", "field_numSown", "yield", "plannedHarvest_PredictedYield",
            "plannedHarvest_DaysLeft", "cropType2", "cropType3", "fieldWorkersNeeded" }, sparse = true },   -- (lane 71: the last four)
  -- (lane 71) a site's construction bar (one decimal) and a ruin (type 75: burnt, or a collapse); only sites and ruins
  { "cs", { "progress", "ruin" }, sparse = true },
  -- (lane 67) maintenance, for every building that has a MaintenanceComponent: the game's GetMaintenanceStatus (0 none
  -- needed, 1 maintained, 2 pending, 3 unmaintained), GetSliderValue (0 half, 1 normal, 2 double),
  -- DoesBuildingNeedMaintaining, and each tracker as <goods joined by +>=<what is left> (read by the native piece
  -- through coop_x_maint.lua, at most a second old; "-" without it). A building without the component has no entry.
  { "mt", { "status", "slider", "need", "trk" } },
  -- every region
  { "ro", { "regionName", "owner", "isSettled", "settlementLevel", "tier" } },
  { "rp", { "workerFamilies", "residents", "population", "homeless", "corpses", "squadsPresent" } },
  { "ap", { "Approval", "publicOrder", "summedApprovalFactors", "factors", "summedPublicOrderFactors", "problems" } },
  { "rw", { "regionalWealth", "supplies_food", "supplies_wood", "expenses", "marketAtt", "nextLivestockOrderIn" } },
  { "li", { "livestock", "role9", "role10", "role11", "role12", "role13", "role14", "role15", "role16", "role17", "role18", "role19", "role21", "role22" }, sparse = true },
  -- what the players set on a region (S020 to S026): taxes by the game's own getTaxRate, the rest as list lengths
  { "rs", { "taxLand", "taxTithe", "policies", "policiesSigned", "Tech", "tradeRules", "targetInventory", "tradePartnerLimits", "forbidGlobalTradeGoodTypes",
            "tradeRouteMerchants", "overstockedGoods", "autoBuyCommodities", "claimCost", "tradeRouteLevels" } },
  -- every family of every region
  { "fa", { "familyHome", "assignedTo", "familyStall", "familyMembers" } },
  { "fc", { "ConsumptionStatus.hunger", "ConsumptionStatus.cold", "ConsumptionStatus.ale", "ConsumptionStatus.garments", "ConsumptionStatus.footwear",
            "ConsumptionStatus.sickness", "ConsumptionStatus.injured" } },
  -- units of the world per kind (SMUnit.currentUnitRole): key role<n>
  { "un", { "units" } },
  -- the raid and bandit-camp schedule, the calendar and weather, the engine's lists
  { "sc", { "daysUntilNextRaid", "daysSinceLastRaid", "lastBanditCampSpawnedDay", "damagingRain", "scenario_nextActionDay" } },
  { "wx", { "day", "daysTotal", "dayOfTheMonth", "month", "monthsTotal", "Year", "Season", "isDrought", "isWinter", "rainMeter", "daysWithoutRainVariation",
            "enableThunderstorm", "grassCulled", "fertilityUpdateTimer",                 -- from here on: numbers with a fraction, compared to one decimal
            "wind", "windTarget", "snowLevel", "snowTarget", "snowing", "targetSnowing", "raining", "targetRaining", "targetCloudiness", "wetness",
            "cloudiness", "rainfall", "snowfall", "droughtLevel", "fogLevel" } },
  { "en", { "buildingArr", "unitArr", "roads", "tradeLog", "freeMerchants", "livestockMerchants", "availableMercs", "fieldArr", "openClaims",
            "landscapeDeformationBuildings", "kingsFavour_daysLeft", "lastUniqueID" } },
  -- the player's lord: numbers and the lengths of his lists (S035 to S041)
  { "lo", { "silver", "influence", "kingsFavour", "numTimesInDebt", "claims", "quests", "proposedQuests", "questOpportunities", "InBox", "outbox",
            "letterHistory", "diplomaticTags", "enemies", "recruitmentPool_Militia", "recruitmentPool_Mercs", "traits", "availablePolicies" } },
  -- (lane 71) what work areas hold: the world's Resource actors per class (berries, mushrooms, fish, stone, felled
  -- trees ...), the engine's deposits and deer lairs (keys: the class name, "deposits", "lairs")
  { "rr", { "count" } },
  -- lane 72 (coop_x_stats.lua fills these): a building's production tracker (goods in its log | entries | hash of every
  -- entry | the time pie's per cents) and its expertise; prices and supply per region and of the foreign market
  -- (count | hash); the player's squads by the host's squad number (men | sums of morale, stamina, experience | gear hash)
  { "pt", { "nGoods", "entries", "hash", "timePct" }, sparse = true },
  { "ex", { "expertise" }, sparse = true },
  { "mk", { "count", "hash" } },
  { "uv", { "men", "morale", "stamina", "experience", "gear" } },
}
local WIDE_LOLEN = 5                                                          -- "lo": lists from the fifth field on
local WIDE_BY = {}
for _, s in ipairs(WIDE) do WIDE_BY[s[1]] = s; if s.sparse then s.zero = string.rep("0", #s[2], "|") end end
WIDE_BY.hv.zero = "-1|0|0|0|0|0"      -- a building that is not a house: fuel day -1 (79 of the test save's 110 buildings)
WIDE_BY.fd.zero = "1|0|0|0|0|0|0|0|0|0|0|0"   -- no crops: crop rotation on (the game's default), nothing else
-- (lane 71) the four fields added after these twelve are stored only with an entry of the twelve (a building that is
-- no field keeps no entry, whatever the game's defaults of the four are); a missing entry reads as this
local WIDE_FD_BASE = WIDE_BY.fd.zero
WIDE_BY.fd.zero = WIDE_FD_BASE .. "|-|-|-|-"
-- The sections and fields as one word. It goes out with every sample: a friend whose build has other sections or
-- fields would set the host's values beside the wrong names, so it does not compare such a sample.
local WIDE_SPEC
do
  local t = {}; for _, s in ipairs(WIDE) do t[#t + 1] = s[1] .. ":" .. table.concat(s[2], ",") end
  WIDE_SPEC = string.format("%x", H(table.concat(t, ";")))
end
local WIDE_LIVE = { 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22 }      -- EUnitRole of farm animals (20 is the hare)
local WIDE_ENLEN = 10                                                         -- the first ten "en" fields are lists (length)
-- per-section counters and the last days' summaries live through a reload (a resync must not empty them)
W.wideCnt = W.wideCnt or {}; W.wideDays = W.wideDays or {}; W.wideLast = W.wideLast or {}; W.wideStat = W.wideStat or { compared = 0 }

local function gField(o, n) return o[n] end
local function gLen(o, n) return #o[n] end
local function gBuilt(b) return b:IsConstructed() end
-- does this stored object pointer look like one? (its number only; the object is not touched: coop_x_events.lua, lane 5)
local function ptrOk(o) local a = addr(o); return type(a) == "number" and a > 0x10000 and a < 0x7FFFFFFFFFFF end
local function wFmt(v)
  local t = type(v)
  if t == "number" then
    if math.type(v) == "integer" then return v end       -- as it is: every use puts it into a string with ".."
    if v ~= v then return "nan" end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    local s = string.format("%.1f", v)                   -- one decimal; "1.0" is written "1", as a whole number is
    if s:sub(-2) == ".0" then s = s:sub(1, -3); if s == "-0" then s = "0" end end
    return s
  end
  if t == "boolean" then return v and "1" or "0" end
  if t == "string" then return (v:gsub("[%s;|]", "_")) end
  return "?"
end
local function wv(o, n) local ok, v = pcall(gField, o, n); if ok then return wFmt(v) end; return "?" end                                   -- a simple value
local function wl(o, n) local ok, v = pcall(gLen, o, n); if ok and type(v) == "number" then return v end; return "?" end                   -- a list: its length
local function wp(o, n) local ok, x = pcall(gField, o, n); if not ok then return "?" end; return (ptrOk(x) and valid(x)) and "1" or "0" end  -- an object: there or not
local function wo(o, n, P)                                                                                                             -- a building: its key
  local ok, x = pcall(gField, o, n); if not ok then return "?" end
  if not (ptrOk(x) and valid(x)) then return "-" end
  local known = P.keyOf[addr(x)]; if known then return known end   -- read in this sample's pass over the buildings
  local ok2, k = pcall(W.bkey, x); return ok2 and k or "?"
end

local function wideWorld(P, S, only)
  if not (valid(S.eng) and valid(S.p1)) then error("world or lord is gone") end
  local eng = S.eng; local T = eng.TemporalComponent
  if not valid(T) then error("world clock is gone") end
  local t
  if not only or only == "sc" then
    local d = "-"; pcall(function() local D = eng.questDirector; if valid(D) then d = wFmt(D.scenario_nextActionDay) end end)
    P.sc.TIME = wv(T, "daysUntilNextRaid") .. "|" .. wv(T, "daysSinceLastRaid") .. "|" .. wv(T, "lastBanditCampSpawnedDay") .. "|" .. wv(T, "damagingRain") .. "|" .. d
  end
  if not only or only == "wx" then
    t = {}; for i, f in ipairs(WIDE_BY.wx[2]) do t[i] = wv(T, f) end
    P.wx.TIME = table.concat(t, "|")
  end
  if not only or only == "en" then
    t = {}; for i, f in ipairs(WIDE_BY.en[2]) do t[i] = (i <= WIDE_ENLEN) and wl(eng, f) or wv(eng, f) end
    P.en.ENGINE = table.concat(t, "|")
  end
  if not only or only == "lo" then
    t = {}; for i, f in ipairs(WIDE_BY.lo[2]) do t[i] = (i >= WIDE_LOLEN) and wl(S.p1, f) or wv(S.p1, f) end
    P.lo.LORD = table.concat(t, "|")
  end
  if not only or only == "rr" then
    -- (lane 71) Resource actors per class, deposits, deer lairs: a difference here is a work area that holds other things
    pcall(function()
      local cls = {}
      for _, r in ipairs(FindAllOf("Resource") or {}) do
        if valid(r) then
          local okN, n = pcall(function() local c = r:GetClass(); if valid(c) then return c:GetFName():ToString() end end)
          n = (okN and type(n) == "string") and n:gsub("[%s;|]", "_") or "?"
          cls[n] = (cls[n] or 0) + 1
        end
      end
      for n, c in pairs(cls) do P.rr[n] = tostring(c) end
    end)
    P.rr.deposits = wl(eng, "deposits")
    pcall(function() P.rr.lairs = tostring(#eng:getDeerLairLocations()) end)
  end
  local X = rawget(C, "stats"); if (not only or only == "mk" or only == "uv") and X and X.wideWorld then pcall(X.wideWorld, P, S) end      -- lane 72: sections mk, uv
  Check.note(P, "world")
end

local function wideRegion(P, r, only)
  local k = W.rkey(r); local own = ownerCode(r.ownerPawn)
  if not only or only == "ro" then
    local name = "?"; pcall(function() name = r.regionName:ToString() end)
    P.ro[k] = wFmt(name) .. "|" .. own .. "|" .. wv(r, "isSettled") .. "|" .. wv(r, "settlementLevel") .. "|" .. wv(r, "tier")
  end
  local town = own ~= "-" and own ~= "X"            -- the region's own counting functions are called for a lord's region only
  if not only or only == "rp" then
    local pop, homeless = "-", "-"
    if town then pcall(function() pop = wFmt(r:getNumTotalPopulation()); homeless = wFmt(r:getNumHomelessFamilies()) end) end
    P.rp[k] = wl(r, "workerFamilies") .. "|" .. wl(r, "residents") .. "|" .. pop .. "|" .. homeless .. "|" .. wl(r, "corpses") .. "|" .. wl(r, "squadsPresent")
  end
  if not only or only == "ap" then
    -- approval's inputs as the game sums them: <factor type>[p = past]:<effect>, one per row of summedApprovalFactors
    local fac = "-"
    local okF = pcall(function()
      local arr = r.summedApprovalFactors; local t = {}
      for i = 1, #arr do local m = arr[i]; t[#t + 1] = string.format("%d%s:%d", m.Type, m.past and "p" or "", math.floor(m.effectByPopulation + 0.5)) end
      table.sort(t); if #t > 0 then fac = table.concat(t, ",") end
    end)
    if not okF then fac = "?" end
    P.ap[k] = wv(r, "Approval") .. "|" .. wv(r, "publicOrder") .. "|" .. wl(r, "summedApprovalFactors") .. "|" .. fac .. "|" .. wl(r, "summedPublicOrderFactors") .. "|" .. wl(r, "problems")
  end
  if not only or only == "rw" then
    P.rw[k] = wv(r, "regionalWealth") .. "|" .. wv(r, "supplies_food") .. "|" .. wv(r, "supplies_wood") .. "|" .. wv(r, "expenses") .. "|" .. wv(r, "marketAtt") .. "|" .. wv(r, "nextLivestockOrderIn")
  end
  if not only or only == "rs" then
    local land, tithe = "-", "-"
    if town then pcall(function() land = wFmt(r:getTaxRate(FName("land"))); tithe = wFmt(r:getTaxRate(FName("tithe"))) end) end
    P.rs[k] = land .. "|" .. tithe .. "|" .. wl(r, "policies") .. "|" .. wl(r, "policiesSigned") .. "|" .. wl(r, "Tech") .. "|" .. wl(r, "tradeRules") .. "|" .. wl(r, "targetInventory")
      .. "|" .. wl(r, "tradePartnerLimits") .. "|" .. wl(r, "forbidGlobalTradeGoodTypes") .. "|" .. wl(r, "tradeRouteMerchants") .. "|" .. wl(r, "overstockedGoods")
      .. "|" .. wv(r, "autoBuyCommodities") .. "|" .. wv(r, "claimCost") .. "|" .. wl(r, "tradeRouteLevels")
  end
  if town and (not only or only == "li") then
    local t = { "?" }; pcall(function() t[1] = wFmt(r:getTotalLivestockCount()) end)
    for i, role in ipairs(WIDE_LIVE) do t[i + 1] = "?"; pcall(function() t[i + 1] = wFmt(r:GetTotalLivestockCountOfType(role)) end) end
    local s = table.concat(t, "|"); if s ~= WIDE_BY.li.zero then P.li[k] = s end
  end
  local X = rawget(C, "stats"); if (not only or only == "mk") and X and X.wideRegion then pcall(X.wideRegion, P, r, k) end     -- lane 72: section mk
  Check.note(P, "region", k)
end

-- a family is its place in the region's list (the realm module keeps the lists equal); its people are not touched
local function wideFamily(P, k, F, i)
  local key = k .. ":F" .. i
  P.fa[key] = wo(F, "familyHome", P) .. "|" .. wo(F, "assignedTo", P) .. "|" .. wo(F, "familyStall", P) .. "|" .. wl(F, "familyMembers")
  local ok, cs = pcall(gField, F, "ConsumptionStatus")
  if ok and cs ~= nil then
    P.fc[key] = wv(cs, "hunger") .. "|" .. wv(cs, "cold") .. "|" .. wv(cs, "ale") .. "|" .. wv(cs, "garments") .. "|" .. wv(cs, "footwear") .. "|" .. wv(cs, "sickness") .. "|" .. wv(cs, "injured")
  else P.fc[key] = "?|?|?|?|?|?|?" end
  Check.note(P, "family", key)
end

local function wideBuilding(P, b, only)
  local k = W.bkey(b)
  if P.bl[k] then P.dup = P.dup + 1; k = k .. "#" .. P.dup end        -- two buildings of one type on one spot
  local ba = addr(b); if ba then P.keyOf[ba] = k end                  -- for the families' homes and workplaces
  local op = b.ownerPawn; local oa = valid(op) and addr(op) or 0      -- a lord's code is worked out once per sample
  local own = P.own[oa]; if own == nil then own = ownerCode(op); P.own[oa] = own end
  local okB, built, s
  if not only or only == "bl" or only == "cs" then okB, built = pcall(gBuilt, b) end
  if not only or only == "bl" then
    P.bl[k] = own .. "|" .. ((okB and built) and "1" or "0") .. "|" .. wv(b, "lv") .. "|" .. wv(b, "onFire") .. "|" .. wv(b, "sleep")
  end
  if not only or only == "bw" then
    P.bw[k] = wv(b, "numActiveWorkerFamilies") .. "|" .. wl(b, "assignedFamilyIDs") .. "|" .. wl(b, "occupantFamilyIDs") .. "|" .. wv(b, "buildPriority") .. "|" .. wv(b, "secondaryPriority")
      .. "|" .. wv(b, "stockFuelFor") .. "|" .. wl(b, "upgradesDone") .. "|" .. wl(b, "Extensions") .. "|" .. wv(b, "artisanJob") .. "|" .. wv(b, "isBeingUpgraded")
      .. "|" .. wl(b, "constructionGoods")
  end
  if not only or only == "bs" then
    local goodsStr = "-"
    if own == "P" then                                                   -- what each good is, for the player's buildings
      local okI, m = pcall(invOf, b)
      if okI then
        local g = {}; for t, a in pairs(m) do if a ~= 0 then g[#g + 1] = string.format("%d:%d", t, a) end end
        table.sort(g); goodsStr = #g > 0 and table.concat(g, ",") or "0"
      else goodsStr = "?" end
    end
    P.bs[k] = wv(b, "numStoredGeneric") .. "|" .. wv(b, "numStoredLarge") .. "|" .. wv(b, "numStoredPantry") .. "|" .. wl(b, "Inventory") .. "|" .. goodsStr
  end
  if not only or only == "hv" then
    s = wv(b, "refuelDay") .. "|" .. wv(b, "refueled") .. "|" .. wv(b, "needsRefueling") .. "|" .. wv(b, "waterSupply") .. "|" .. wv(b, "marketDaysLeft") .. "|" .. wv(b, "mourningPeriod")
    if s ~= WIDE_BY.hv.zero then P.hv[k] = s end
  end
  if not only or only == "an" then
    s = wl(b, "animals") .. "|" .. wl(b, "animalsOnPasture") .. "|" .. wl(b, "oxen") .. "|" .. wv(b, "activeOxen") .. "|" .. wl(b, "Carts")
    if s ~= WIDE_BY.an.zero then P.an[k] = s end
  end
  if not only or only == "bd" then
    P.bd[k] = wl(b, "buildings") .. "|" .. wl(b, "Resources") .. "|" .. wl(b, "distributedGoods") .. "|" .. wl(b, "roadDecals") .. "|" .. wl(b, "additionalWorkPositions") .. "|" .. wp(b, "snappedToRoad")
      .. "|" .. wl(b, "freeStallTransforms")
  end
  if not only or only == "bx" then
    P.bx[k] = wv(b, "allowMarketStalls") .. "|" .. wv(b, "supplyOverstocking") .. "|" .. wv(b, "workAreaLimited") .. "|" .. wv(b, "workAreaRange") .. "|" .. wv(b, "sellingType")
      .. "|" .. wv(b, "muleTrain_buyingType") .. "|" .. wv(b, "muleTrain_sellingType") .. "|" .. wv(b, "allowLabourers") .. "|" .. wv(b, "targetSquadSize")
      .. "|" .. wl(b, "storageFilter") .. "|" .. wl(b, "TargetStock") .. "|" .. wl(b, "customBuildingFlags") .. "|" .. wl(b, "recruits") .. "|" .. wl(b, "blueprints") .. "|" .. wl(b, "walls")
  end
  if not only or only == "fd" then
    s = wv(b, "bRotateCrops") .. "|" .. wv(b, "fieldOperationMode") .. "|" .. wv(b, "forceHarvest") .. "|" .. wv(b, "field_ploughingPerc") .. "|" .. wv(b, "field_sowingPerc")
      .. "|" .. wv(b, "field_growingPerc") .. "|" .. wv(b, "field_harvestingPerc") .. "|" .. wv(b, "field_numReadyToHarvest") .. "|" .. wv(b, "field_numUnplowed")
      .. "|" .. wv(b, "field_numSown") .. "|" .. wv(b, "yield") .. "|" .. wv(b, "plannedHarvest_PredictedYield")
    if s ~= WIDE_FD_BASE then                                            -- (lane 71) planned days, crop of the next years, workers
      P.fd[k] = s .. "|" .. wv(b, "plannedHarvest_DaysLeft") .. "|" .. wv(b, "cropType2") .. "|" .. wv(b, "cropType3") .. "|" .. wv(b, "fieldWorkersNeeded")
    end
  end
  if not only or only == "cs" then
    -- (lane 71) a site's bar (the game's own getConstructionProgress, only on a site) and a ruin
    local okR, raw = pcall(function() return b:GetType() end)
    local ruin = (okR and raw == 75) and "1" or "0"
    if (okB and built == false) or ruin == "1" then
      local pr = "-"
      if okB and built == false then local okP, v = pcall(function() return b:getConstructionProgress() end); pr = okP and wFmt(v) or "?" end
      s = pr .. "|" .. ruin
      if s ~= WIDE_BY.cs.zero then P.cs[k] = s end
    end
  end
  if not only or only == "mt" then
    local okm, mc = pcall(gField, b, "MaintenanceComponent")
    if okm and mc and valid(mc) then
      local st, sl, nd = "?", "?", "?"
      pcall(function() st = wFmt(mc:GetMaintenanceStatus()) end)
      pcall(function() sl = wFmt(mc:GetSliderValue()) end)
      pcall(function() nd = wFmt(mc:DoesBuildingNeedMaintaining()) end)
      local M = rawget(C, "maint"); local trk = (M and M.trkOf) and M.trkOf(k) or "-"
      P.mt[k] = st .. "|" .. sl .. "|" .. nd .. "|" .. trk
    end
  end
  local X = rawget(C, "stats"); if (not only or only == "pt" or only == "ex") and X and X.wideBuilding then pcall(X.wideBuilding, P, b, k) end -- lane 72: sections pt, ex
  if P.tag then W.wd.objects[k] = b end
  Check.note(P, "building", k)
end

local function wideNew(tag, day, done)
  local P = { times = {}, dup = 0, unc = {}, keyOf = {}, own = {} }
  if tag ~= "bench" then P.tag = tostring(tag) end
  for _, s in ipairs(WIDE) do P[s[1]] = {} end
  return { tag = tag, day = day, done = done, P = P, phase = 1, i = 0, ri = 0, fi = 0, ms = 0, ticks = 0, t0 = os.clock() }
end

-- one piece of work. Returns its weight (a building is 1), or nil when the sample is complete.
local function wideStep(S, st)
  local P = st.P; local eng = S.eng
  if st.phase == 1 then                                  -- the world's own numbers; the list of regions
    local ok, e = pcall(wideWorld, P, S); if not ok then P.err = tostring(e) end
    st.regs = {}; local arr = eng.regions
    for i = 1, #arr do local r = un(arr[i]); if valid(r) then st.regs[#st.regs + 1] = r end end
    st.phase = 2; return 1
  elseif st.phase == 2 then                              -- one region per step; then the buildings (part 4), then the families (part 3)
    st.ri = st.ri + 1; local r = st.regs[st.ri]
    if not r then st.phase = 4; st.i = 0; return 0 end
    if valid(r) then local ok, e = pcall(wideRegion, P, r); if not ok then P.err = tostring(e) end end
    return 1
  elseif st.phase == 3 then                              -- four families per step (after the buildings: their keys are known by then)
    local r = st.regs[st.ri]
    if not r then st.phase = 5; st.i = 0; return 0 end
    local n = 0
    local ok, e = pcall(function()
      if not valid(r) then st.ri = st.ri + 1; st.fi = 0; return end
      local fams = r.workerFamilies; local cnt = #fams; local k = W.rkey(r)
      -- a region's families are read into a list of their own and taken over when the region is done: a family is
      -- its place in the list, so when the list grew or shrank while it was read (over several ticks) the region is
      -- read again, once
      if st.fi == 0 then st.fcnt = cnt; st.ft = { fa = {}, fc = {}, keyOf = P.keyOf, tag = P.tag, times = P.times } end
      while st.fi < cnt and n < 4 do st.fi = st.fi + 1; n = n + 1; wideFamily(st.ft, k, fams[st.fi], st.fi) end
      if st.fi >= cnt then
        if cnt ~= st.fcnt and st.fredo ~= st.ri then st.fredo = st.ri; st.fi = 0; bump("w_wideRedo"); return end
        for key, v in pairs(st.ft.fa) do P.fa[key] = v end
        for key, v in pairs(st.ft.fc) do P.fc[key] = v end
        st.ri = st.ri + 1; st.fi = 0
      end
    end)
    if not ok then P.err = tostring(e); st.ri = st.ri + 1; st.fi = 0 end
    return n > 0 and 1 or 0.1
  elseif st.phase == 4 then                              -- one building per step
    local arr = eng.buildingArr
    -- The list is read over many ticks. When a building before the place reached is taken out meanwhile (a demolish,
    -- a pile cleared), every later one moves up and one is skipped: the sample then lacks a building that is there
    -- (session 8, day 305: one of the player's own was named as standing on the friend's copy only). So: is the
    -- building read last still where it was? If not, the buildings are read again from the start, at most twice.
    -- (the length is looked at first: a read past the end of a game list would GROW it by an empty entry)
    if st.i > 0 and st.lastB and (st.i > #arr or addr(arr[st.i]) ~= st.lastB) then
      st.redo = (st.redo or 0) + 1; bump("w_wideRedo")
      if st.redo <= 2 then
        for _, s in ipairs({ "bl", "bw", "bs", "hv", "an", "bd", "bx", "fd", "mt", "cs", "pt", "ex" }) do P[s] = {} end   -- (lane 67: mt; lane 71: cs; lane 72: pt, ex)
        P.keyOf = {}; P.dup = 0; st.i = 0; st.lastB = nil
        return 0.5
      end
      P.unstable = true
    end
    st.i = st.i + 1
    if st.i > #arr then st.phase = 3; st.ri = 1; st.fi = 0; return 0 end
    local raw = arr[st.i]; st.lastB = addr(raw)
    local b = un(raw)
    if valid(b) then local ok, e = pcall(wideBuilding, P, b); if not ok then P.err = tostring(e); P.berr = (P.berr or 0) + 1 end end
    return 1
  elseif st.phase == 5 then                              -- 25 units per step: how many of each kind
    local arr = eng.unitArr; local n = #arr
    if st.i == 0 then st.ucnt = n end
    if st.i >= n and n ~= st.ucnt and not st.uredo and W.cfg.wideUnits then   -- the list changed while it was counted: once more
      st.uredo = true; st.i = 0; st.ucnt = n; P.unc = {}; bump("w_wideRedo")
      return 0.5
    end
    if st.i >= n or not W.cfg.wideUnits then st.phase = 6; return 0 end   -- cfg.wideUnits = false leaves the units out (a fifth of the cost)
    local to = math.min(n, st.i + 25)
    for i = st.i + 1, to do
      -- the list holds the units themselves: no un() (its "get" fails on them and costs 17 microseconds a unit)
      local u = arr[i]; local rk = "none"
      if ptrOk(u) and valid(u) then local ok, role = pcall(gField, u, "currentUnitRole"); rk = ok and wFmt(role) or "?" end
      P.unc[rk] = (P.unc[rk] or 0) + 1
    end
    st.i = to
    return 1
  end
  for rk, c in pairs(P.unc) do P.un["role" .. rk] = string.format("%d", c) end
  Check.note(P, "units")
  return nil
end

local function wideFinish(st)
  local smp = { tag = st.tag, day = st.day, sec = {}, times = st.P.times, ms = st.ms, ticks = st.ticks, span = os.clock() - st.t0, n = 0, err = st.P.err }
  for _, s in ipairs(WIDE) do local m = st.P[s[1]]; smp.sec[s[1]] = m; for _ in pairs(m) do smp.n = smp.n + #s[2] end end
  if smp.err and W.lastWideErr ~= smp.err then W.lastWideErr = smp.err; log("wide %s: a read failed: %s", tostring(st.tag), smp.err) end
  if st.redo or st.uredo or st.fredo then
    log("wide %s: a list changed while it was read; read again (buildings %d times%s%s)%s", tostring(st.tag), st.redo or 0, st.uredo and ", units" or "",
      st.fredo and ", families" or "", st.P.unstable and ": the building list did not hold still, a building may be named wrongly today" or "")
  end
  smp.finish = Check.clock(W.S)
  if st.P.tag then
    if W.S.role == "host" then Check.remember(W.wd.samples, tostring(smp.tag), smp)
    else Check.absent(smp) end
  end
  if st.done then st.done(smp) end
  return smp
end

-- the whole sample in one call (on demand and for measuring: about as long as a day's sample in all its ticks together);
-- smp.phase = milliseconds per part: 1 world, 2 regions, 3 families, 4 buildings, 5 units
local function wideSync(S, tag, day)
  local st = wideNew(tag, day, nil); local t0 = os.clock(); local ph = {}; local last, lp = t0, st.phase
  while true do
    local w = wideStep(S, st)
    if st.phase ~= lp or w == nil then local t = os.clock(); ph[lp] = (ph[lp] or 0) + (t - last) * 1000; last = t; lp = st.phase end
    if w == nil then break end
  end
  st.ms = (os.clock() - t0) * 1000; st.ticks = 1
  local smp = wideFinish(st); smp.phase = ph
  return smp
end

-- Called at this copy's day change. The pace follows the length of a game day in ticks: the sample is to be read
-- within four tenths of a day, so that at a high game speed and a low frame rate it is still done before the next day
-- (session 2 of lane 9: at speed 4 and under 10 frames a second six of 48 days were left out at the fixed pace).
local function wideStart(S, tag, day, done)
  local D = W.wd
  local clock = os.clock()
  if D.lastDayTime then D.daySeconds = clock - D.lastDayTime end
  D.lastDayTime = clock
  local tpd = D.dayTick and (D.tickN - D.dayTick) or nil; D.dayTick = D.tickN
  -- the shorter of the last two days: ticks go on while the game is paused, so one day can look far longer than it is
  if tpd and D.tpdLast and D.tpdLast < tpd then tpd, D.tpdLast = D.tpdLast, tpd else D.tpdLast = tpd end
  D.tpd = tpd
  if D.run then bump("w_wideSkip"); log("wide %s: the sample %s is still being taken: this one is left out", tostring(tag), tostring(D.run.tag)); return false end
  D.run = wideNew(tag, day, done)
  local rate = W.cfg.wideWork
  if tpd and tpd > 0 then
    local est = 0
    pcall(function() est = #S.eng.buildingArr + 3 * #S.eng.regions + (W.cfg.wideUnits and (#S.eng.unitArr / 25) or 0) end)
    if est / (tpd * 0.4) > rate then rate = est / (tpd * 0.4) end
  end
  D.run.rate = rate
  return true
end

-- host: the sample goes out, one section per tick. Whole after a load, a join (W.keyframe) and every cfg.wideFull
-- samples; else only the entries that changed since the sample before.
local function wideSendStep(J)
  local D = W.wd; local cfg = W.cfg; local smp = J.smp
  if J.i == 0 then                                       -- decided when its turn comes, not when it was queued
    D.serial = (D.serial or 0) + 1; J.serial = D.serial
    J.full = (D.wantFull or D.sentSerial == nil or (D.serial - (D.fullSerial or 0)) >= cfg.wideFull) and true or false
    D.wantFull = nil
    J.base = J.full and 0 or D.sentSerial
  end
  J.i = J.i + 1
  local spec = WIDE[J.i]
  if spec then
    local sec = spec[1]; local map = smp.sec[sec]; local old = (not J.full) and D.sent[sec] or nil
    local items = {}
    for k, v in pairs(map) do if not old or old[k] ~= v then items[#items + 1] = k .. "|" .. v end end
    if old then for k in pairs(old) do if map[k] == nil then items[#items + 1] = k .. "|!" end end end
    table.sort(items)
    local head = string.format("W G %s %s ", smp.tag, sec)
    local buf, n = {}, #head
    local function out() local l = head .. table.concat(buf, ";"); send(l); J.lines = J.lines + 1; J.bytes = J.bytes + #l; buf = {}; n = #head end
    for _, it in ipairs(items) do
      if #buf > 0 and n + 1 + #it > cfg.maxLine then out() end
      buf[#buf + 1] = it; n = n + #it + 1
    end
    if #buf > 0 then out() end
    D.sent[sec] = map
    return false
  end
  send(string.format("W G %s END %d %d %d %d %d %d %s", smp.tag, J.serial, J.base, J.lines, math.floor(smp.ms + 0.5), smp.ticks, smp.day, WIDE_SPEC))
  if J.full then D.fullSerial = J.serial end
  D.sentSerial = J.serial
  bump("w_wideSent"); bump("w_wideBytes", J.bytes)
  W.wideStat.lastSend = { tag = smp.tag, bytes = J.bytes, lines = J.lines, full = J.full, ms = smp.ms, ticks = smp.ticks, n = smp.n, span = smp.span }
  log("wide %s sent: %d values, %d bytes in %d lines (%s), read in %.0f ms over %d ticks (%.1f s)", tostring(smp.tag), smp.n, J.bytes, J.lines,
    J.full and "whole" or "changes", smp.ms, smp.ticks, smp.span or 0)
  return true
end

-- friend: is this difference one the mod makes on purpose (held), or one that is per copy by nature?
local function wideMark(sec, field, hv, mv)
  if sec == "sc" then
    if field == "daysUntilNextRaid" and W.on.holdRaid and tonumber(hv) and tonumber(mv) == tonumber(hv) + 1 then return "held" end
    if field == "lastBanditCampSpawnedDay" and W.on.holdCamp then return "held" end
    if field == "damagingRain" and W.on.fire and mv == "0" then return "held" end
    if field == "scenario_nextActionDay" and W.on.holdDirector then return "held" end
  elseif sec == "en" and field == "lastUniqueID" then return "per-copy"
  -- (lane 67) a tracker read within a day step of the other copy's (1, 2 or 4 a day by the slider): the two samples
  -- are taken at each copy's own day change and the friend's held value can be up to a second behind the host's
  elseif sec == "mt" and field:sub(1, 1) == "t" and field ~= "trk" and tonumber(hv) and tonumber(mv) and math.abs(tonumber(hv) - tonumber(mv)) <= 4 then return "dayStep" end
end

-- friend: whose is the thing a difference is about? A building's owner (section bl), a region's owner (section ro; a
-- family is its region's). P = the player's own town: that is what a later resync rule would look at first.
local WIDE_KIND = { bl = "b", bw = "b", bs = "b", hv = "b", an = "b", bd = "b", bx = "b", fd = "b", mt = "b", cs = "b", ro = "r", rp = "r", ap = "r", rw = "r", li = "r", rs = "r", fa = "f", fc = "f",
                    pt = "b", ex = "b", mk = "r" }   -- (lane 72)
local function wideOwner(sec, key, Hs, Ms)
  local kind = WIDE_KIND[sec]; if not kind then return nil end
  if kind == "b" then
    local e = (Ms.sec.bl and Ms.sec.bl[key]) or (Hs.sec.bl and Hs.sec.bl[key])
    return e and e:match("^([^|]*)") or "?"
  end
  local tag = kind == "f" and key:match("^(.-):F%d+$") or key
  local e = (Ms.sec.ro and Ms.sec.ro[tag]) or (Hs.sec.ro and Hs.sec.ro[tag])
  return e and e:match("^[^|]*|([^|]*)") or "?"
end

-- friend: one section of the host's sample against this copy's, by key.
-- Returns { n = differences, nP = of them on the player's own, held, max = largest gap, sum = all gaps, onlyH, onlyF,
--           items = { k, f, h, m, d, mark, o = owner } }.
local function wideCompareSec(spec, Hs, Ms, onlyKey)
  local sec, fields = spec[1], spec[2]
  local a, b = Hs.sec[sec] or {}, Ms.sec[sec] or {}
  local R = { n = 0, nP = 0, held = 0, max = 0, sum = 0, onlyH = 0, onlyF = 0, items = {} }
  local function item(key, field, hv, mv)
    local mark = wideMark(sec, field, hv, mv)
    local x, y = tonumber(hv), tonumber(mv); local d = (x and y) and (y - x) or nil
    -- Preserve the old wide count. The timed check also examines adjacent
    -- displayed tenths, just as it examines all other marked differences.
    if sec == "wx" and d and math.abs(d) < 0.15 then mark = "roundStep" end
    local own = wideOwner(sec, key, Hs, Ms)
    R.items[#R.items + 1] = { k = key, f = field, h = hv, m = mv, d = d, mark = mark, o = own }
    if mark then R.held = R.held + 1; return end
    R.n = R.n + 1
    if own == "P" then R.nP = R.nP + 1 end
    if d then local ad = math.abs(d); R.sum = R.sum + ad; if ad > R.max then R.max = ad end end
  end
  local function entry(key, hv, mv)
    local x, y = {}, {}
    for v in (hv .. "|"):gmatch("([^|]*)|") do x[#x + 1] = v end
    for v in (mv .. "|"):gmatch("([^|]*)|") do y[#y + 1] = v end
    for i, f in ipairs(fields) do
      local p, q = x[i] or "", y[i] or ""
      if p ~= q then
        if f == "trk" and p ~= "?" and q ~= "?" then      -- (lane 67) per maintenance type: t<goods> host/here
          local tp, tq = {}, {}
          for g, n in p:gmatch("([%d+]+)=(%-?%d+)") do tp[g] = n end
          for g, n in q:gmatch("([%d+]+)=(%-?%d+)") do tq[g] = n end
          for g, n in pairs(tp) do if tq[g] ~= n then item(key, "t" .. g, n, tq[g] or "absent") end end
          for g, n in pairs(tq) do if tp[g] == nil then item(key, "t" .. g, "absent", n) end end
          if next(tp) == nil and next(tq) == nil then item(key, f, p, q) end
        elseif f == "goods" and p ~= "?" and q ~= "?" and p ~= "-" and q ~= "-" then
          local gp, gq = {}, {}
          for g, n in p:gmatch("(%d+):(%-?%d+)") do gp[g] = n end
          for g, n in q:gmatch("(%d+):(%-?%d+)") do gq[g] = n end
          for g, n in pairs(gp) do if gq[g] ~= n then item(key, "g" .. g, n, gq[g] or "0") end end
          for g, n in pairs(gq) do if gp[g] == nil then item(key, "g" .. g, "0", n) end end
        else item(key, f, p, q) end
      end
    end
  end
  local function compareKey(k, hv, mv)
    if hv == mv then return end
    if hv == nil then
      if spec.zero then entry(k, spec.zero, mv) else R.onlyF = R.onlyF + 1; item(k, "*", "absent", mv) end
      return
    end
    if mv == nil and spec.zero then mv = spec.zero end
    if mv == nil then R.onlyH = R.onlyH + 1; item(k, "*", hv, "absent") elseif mv ~= hv then entry(k, hv, mv) end
  end
  if onlyKey then compareKey(onlyKey, a[onlyKey], b[onlyKey]); return R end
  for k, hv in pairs(a) do compareKey(k, hv, b[k]) end
  for k, mv in pairs(b) do if a[k] == nil then compareKey(k, nil, mv) end end
  -- The order in the log line, where cfg.wideLogMax cuts: first what stands on one copy only, then the player's own,
  -- then the rest; within each the largest gap first (a difference that is not a number, such as another workplace,
  -- before any number); then by key and field, so that the order is the same every day.
  for _, it in ipairs(R.items) do
    it.r = (it.f == "*") and 0 or ((it.o == "P") and 1 or 2)
    it.a = it.d and math.abs(it.d) or math.huge
  end
  table.sort(R.items, function(p, q)
    if p.r ~= q.r then return p.r < q.r end
    if p.a ~= q.a then return p.a > q.a end
    if p.k ~= q.k then return p.k < q.k end
    return p.f < q.f
  end)
  return R
end

-- The daily scans are spread over frames. Keep the time of the actual field read, and
-- open a short, read-only watch as soon as that row differs. The host samples just the
-- requested fields. Neither receiving a watch nor receiving its answer can write game state.
do
local groups = {
  building = { "bl", "bw", "bs", "hv", "an", "bd", "bx", "fd", "cs", "mt", "pt", "ex" },
  region = { "ro", "rp", "ap", "rw", "li", "rs", "mk" }, family = { "fa", "fc" },
  world = { "sc", "wx", "en", "lo", "rr", "mk", "uv" }, units = { "un" }
}
local function groupOf(s, k)
  if s == "mk" and (k == "FMS" or k == "BASE") then return "world" end
  local kind = WIDE_KIND[s]
  return kind == "b" and "building" or kind == "r" and "region" or kind == "f" and "family" or s == "un" and "units" or "world"
end
function Check.clock(S)
  if S.role == "friend" and C.steam and C.steam.on then
    if not (C.men and C.men.hostClock) then return nil end
    local t, known = C.men.hostClock()
    if known then return t end
    return nil
  end
  return A.now()
end
function Check.remember(store, tag, sample)
  store.order = store.order or {}
  if not store[tag] then store.order[#store.order + 1] = tag end
  store[tag] = sample
  if #store.order > 8 then store[table.remove(store.order, 1)] = nil end
end
local function part(row, index)
  local i = 0
  for v in (row .. "|"):gmatch("([^|]*)|") do i = i + 1; if i == index then return v end end
end
local function fieldValue(s, f, row)
  local spec = WIDE_BY[s]
  row = row or spec.zero
  if not row then return "absent" end
  if f == "*" then return row end
  local good = s == "bs" and f:match("^g(%d+)$")
  local tracker = s == "mt" and f:match("^t([%d+]+)$")
  for i, name in ipairs(spec[2]) do
    if name == f then return part(row, i) end
    if (good and name == "goods") or (tracker and name == "trk") then
      local word = part(row, i)
      if not word or word == "?" then return "?" end
      for key, amt in word:gmatch(good and "(%d+):(%-?%d+)" or "([%d+]+)=(%-?%d+)") do
        if key == (good or tracker) then return amt end
      end
      return good and "0" or "absent"
    end
  end
end
local weather = { "Season", "month", "rainMeter", "isDrought", "isWinter", "daysWithoutRainVariation" }
local lord = { "silver", "influence", "kingsFavour" }
local region = { "regionalWealth", "Approval", "publicOrder" }
local bfields = { "built", "lv", "workers", "residents", "fire", "sleep" }
local function detailValue(s, row, f)
  if row == "?" then return "?" end
  if f == "present" then return row and "1" or "0" end
  if not row then return "absent" end
  if s == "O" then return row end
  if s == "B" then for i, field in ipairs(bfields) do if field == f then return part(row, i) end end end
  for g, v in row:gmatch("(%d+):(%-?%d+)") do if "g" .. g == f then return v end end
  return "0"
end
local function fingerprintFields(s, word)
  local rows = {}
  if s == "Q" then
    for k, v in word:gmatch("([%w%-]+)=(%d+)") do rows[k] = v end
  elseif s == "F" or s == "R" or s == "S" then
    for k, body in word:gmatch("([^|:]+):([^|]*)") do
      if s == "S" then
        for g, v in body:gmatch("(%d+)=(%-?%d+)") do rows[k .. ":" .. g] = v end
      else
        local n = 0
        for v in body:gmatch("[^/,]+") do n = n + 1; rows[k .. ":" .. n] = v end
      end
    end
  elseif s == "W" or s == "M" or s == "N" then
    local n = 0
    for v in word:gmatch("[^,]+") do n = n + 1; rows[tostring(n)] = v end
  else rows.value = word end
  return rows
end
local function fpTime(P, s, k)
  if not P.at then return nil end
  if s == "B" or s == "C" then return P.at.buildings end
  if s == "O" then return P.at.O end
  return P.at[k:match("^([^:]+):") or "world"]
end
local findBuilding
local function fpRead(S, s, k, f, memo)
  local e, i = S.eng, tonumber(k)
  if s == "W" then local t = e.TemporalComponent; if valid(t) and weather[i] then return wv(t, weather[i]) end
  elseif s == "N" then if valid(S.p1) and lord[i] then return wv(S.p1, lord[i]) end
  elseif s == "M" then if i == 1 or i == 2 then return wl(e, i == 1 and "freeMerchants" or "livestockMerchants") end
  elseif s == "D" then return e:getDaysTotal()
  elseif s == "Q" then
    if not memo.Q then local word = fpSoldiers(S); if word == "ERR" then return "?" end; memo.Q = fingerprintFields(s, word) end
    return memo.Q[k] or "0"
  elseif s == "O" then
    local r = W.regionByKey(k)
    return detailValue(s, valid(r) and ownerCode(r.ownerPawn) or nil, f)
  elseif s == "B" or s == "C" then
    local b = findBuilding(S, k, memo)
    if not valid(b) or b:GetType() == 88 or not mine(b.ownerPawn) then return detailValue(s, nil, f) end
    if s == "C" and (b:IsConstructed() or b.isBeingUpgraded or not W.on.bstock) then return detailValue(s, nil, f) end
    if f == "present" then return "1" end
    if s == "C" then return invOf(b)[tonumber(f:match("^g(%d+)$"))] or 0 end
    if f == "built" then return b:IsConstructed() and "1" or "0"
    elseif f == "lv" then return b.lv elseif f == "workers" then return b:getNumActiveWorkerFamilies()
    elseif f == "residents" then return b:getNumResidingFamilies()
    elseif f == "fire" then return b.onFire and "1" or "0" elseif f == "sleep" then return b.sleep and "1" or "0" end
  else
    local tag, col = k:match("^([^:]+):(%d+)$")
    local r = tag and W.regionByKey(tag)
    if not valid(r) or not mine(r.ownerPawn) then return "absent" end
    col = tonumber(col)
    if s == "S" then
      for _, g in ipairs(goods(S)) do if g == col then return r:getStockOfGood(g, false, false) end end
      return "?"
    elseif s == "R" and region[col] then return wv(r, region[col])
    elseif s == "F" then
      if col == 1 then return #r.workerFamilies elseif col == 2 then return r:getNumHomelessFamilies()
      elseif col == 3 then return r:getNumTotalPopulation() elseif col == 4 then return "L" .. r.settlementLevel
      elseif col and col >= 5 and col <= 8 then return r:getNumFamiliesOfLv(col - 4) end
    end
  end
  return "?"
end
findBuilding = function(S, k, memo)
  local objects = W.wd.objects
  local b = objects[k]
  if valid(b) and W.bkey(b) == k then return b end
  if not memo.buildings then
    memo.buildings = {}; local arr = S.eng.buildingArr; local duplicates = 0
    for i = 1, #arr do
      local x = un(arr[i])
      if valid(x) then
        local key = W.bkey(x)
        if memo.buildings[key] then duplicates = duplicates + 1; key = key .. "#" .. duplicates end
        memo.buildings[key] = x
      end
    end
    W.wd.objects = memo.buildings
  end
  return memo.buildings[k]
end
local function read(S, s, k, f, memo)
  if not (valid(S.eng) and valid(S.p1)) then return "?" end
  if not WIDE_BY[s] then return fpRead(S, s, k, f, memo) end
  local group = groupOf(s, k)
  local obj
  if group == "building" then obj = findBuilding(S, k, memo)
  elseif group == "region" then obj = W.regionByKey(k)
  elseif group == "family" then
    local tag, n = k:match("^(.-):F(%d+)$"); n = tonumber(n)
    local r = tag and W.regionByKey(tag)
    if valid(r) and n and n >= 1 and n <= #r.workerFamilies then obj = r.workerFamilies[n] end
  end
  if group == "building" or group == "region" then
    if not valid(obj) then return fieldValue(s, f, nil) end
  elseif group == "family" and not obj then return fieldValue(s, f, nil) end
  -- Only schema fields get here. The common scalar and length reads need no row allocation.
  if f ~= "*" then
    if s == "wx" or (s == "sc" and f ~= "scenario_nextActionDay") then
      local t = S.eng.TemporalComponent; if valid(t) then return wv(t, f) end; return "?"
    elseif s == "an" then return f == "activeOxen" and wv(obj, f) or wl(obj, f)
    elseif s == "bd" then return f == "snappedToRoad" and wp(obj, f) or wl(obj, f)
    elseif s == "bs" then
      local g = f:match("^g(%d+)$")
      if g then return invOf(obj)[tonumber(g)] or 0 end
      if f == "Inventory" then return wl(obj, f) elseif f ~= "goods" then return wv(obj, f) end
    elseif s == "hv" then return wv(obj, f)
    elseif s == "rw" then return (f == "expenses" or f == "marketAtt") and wl(obj, f) or wv(obj, f)
    elseif s == "en" or s == "lo" then
      local o = s == "en" and S.eng or S.p1
      for i, name in ipairs(WIDE_BY[s][2]) do
        if f == name then return ((s == "en" and i <= WIDE_ENLEN) or (s == "lo" and i >= WIDE_LOLEN)) and wl(o, f) or wv(o, f) end
      end
    end
  end
  -- A compound row or count uses the same reader as the first pass, once per object
  -- in this tick. A role count must inspect the bounded unit list to count that role.
  local mk = s .. "/" .. ((group == "world" or group == "units") and "" or k)
  if not memo[mk] then
    local P = { dup = 0, keyOf = {}, own = {} }
    P[s] = {}; P.bl = P.bl or {}
    if group == "building" then wideBuilding(P, obj, s); if k:find("#", 1, true) then P[s][k] = P[s][W.bkey(obj)] end
    elseif group == "region" then wideRegion(P, obj, s)
    elseif group == "family" then local tag, n = k:match("^(.-):F(%d+)$"); P.fa = P.fa or {}; P.fc = P.fc or {}; wideFamily(P, tag, obj, tonumber(n))
    elseif group == "units" then
      local arr = S.eng.unitArr
      for i = 1, #arr do
        local u = arr[i]; local role = "none"
        if ptrOk(u) and valid(u) then role = wv(u, "currentUnitRole") end
        local key = "role" .. role; P.un[key] = (P.un[key] or 0) + 1
      end
    elseif valid(S.eng.TemporalComponent) then wideWorld(P, S, s) else return "?" end
    memo[mk] = P
  end
  local row = memo[mk][s][k]; return fieldValue(s, f, row and tostring(row))
end
local function descriptor(id)
  local s, k, f = id:match("^([A-Za-z]+)~([%w@:,%.#_%-]+)~([%w%._+*]+)$")
  if not s then return end
  local spec = WIDE_BY[s]
  if spec then
    if f == "*" or (s == "bs" and f:match("^g%d+$")) or (s == "mt" and f:match("^t[%d+]+$")) then return s, k, f end
    for _, name in ipairs(spec[2]) do if name == f then return s, k, f end end
  elseif s == "B" or s == "C" or s == "O" then
    if f == "present" or (s == "O" and f == "owner") or (s == "C" and f:match("^g%d+$")) then return s, k, f end
    if s == "B" then for _, field in ipairs(bfields) do if field == f then return s, k, f end end end
  elseif f == "value" then
    for _, section in ipairs(FP_ORDER) do if s == section then return s, k, f end end
  end
end
local function record(w, side, t, v)
  if not t or v == nil then return end
  v = tostring(v)
  local a = w[side]; a[#a + 1] = { t = t, v = v }
  if side == "host" and v ~= "?" and (not w.seen[v] or t < w.seen[v]) then w.seen[v] = t end
end
local weatherCol, fpCol = {}, {}
for i, field in ipairs(WX) do weatherCol[field[1]] = i end
for i, name in ipairs(weather) do fpCol[name] = tostring(i) end
function Check.weatherWord(t, v)
  local D = W.wd
  if not t or not W.on.wide then return end
  D.weatherWords = D.weatherWords or {}
  local words = D.weatherWords
  words[#words + 1] = { t = t, v = v }
  while words[1] and t - words[1].t > 15 do table.remove(words, 1) end
  for i, raw in ipairs(v) do
    local field = WX[i]
    if field then
      local name = field[1]
      local a = D.watches["wx~TIME~" .. name]
      local b = fpCol[name] and D.watches["W~" .. fpCol[name] .. "~value"]
      if a then record(a, "host", t, wFmt(raw)) end
      if b then record(b, "host", t, wFmt(raw)) end
    end
  end
end
local function watch(s, k, f, tag)
  local D = W.wd; local id = s .. "~" .. k .. "~" .. f; local w = D.watches[id]
  if not w then
    w = { s = s, k = k, f = f, host = {}, friend = {}, seen = {} }; D.watches[id] = w
    local name = (s == "wx" and k == "TIME" and f) or (s == "W" and weather[tonumber(k)])
    local col = name and weatherCol[name]
    if col then for _, word in ipairs(D.weatherWords or {}) do
      if word.v[col] ~= nil then record(w, "host", word.t, wFmt(word.v[col])) end
    end end
  end
  if tag and w.tag ~= tag then
    w.tag = tag; D.ask = D.ask or {}; D.ask[tag] = D.ask[tag] or {}; D.ask[tag][id] = true
  end
  -- A recurring fault needs the host's history from BEFORE the next day's
  -- sample as well. Let a watch expire when the following day stops naming it.
  local lease = math.max(4.5, math.min(90, (D.daySeconds or 0) + 4))
  w.untilT = math.max(w.untilT or 0, os.clock() + lease)
  return w
end
local function earlyPair(tag, s, k, hostRow, hereRow, ht, ft)
  if hostRow == hereRow then return end
  local host = { sec = { [s] = { [k] = hostRow } } }
  local here = { sec = { [s] = { [k] = hereRow } } }
  for _, x in ipairs(wideCompareSec(WIDE_BY[s], host, here, k).items) do
    local w = watch(s, k, x.f, tag)
    record(w, "friend", ft, x.m); record(w, "host", ht, x.h)
  end
end
local function sampleTime(times, s, k)
  local group = groupOf(s, k)
  return times[group .. "/" .. ((group == "world" or group == "units") and "" or k)]
end
-- Both copies keep their original independent day scan. Preview changed host rows
-- as each is read, so the slower of the two reads can open the watch that frame.
-- The ordinary complete, serial-checked sample alone decides which rows count.
function Check.note(P, group, k)
  if not P.tag then return end
  local D, S = W.wd, W.S
  local t = Check.clock(S); P.times[group .. "/" .. (k or "")] = t
  for _, s in ipairs(groups[group]) do
    local map = P[s]
    local base = (S.role == "host" and D.sent[s]) or (D.base and D.base[s])
    local early = D.early[P.tag] and D.early[P.tag][s]
    local paired = D.host[P.tag]
    local function observe(key)
      local row = map[key]
      if S.role == "host" then
        if t and row ~= (base and base[key]) then
          D.preview = D.preview or {}; local head = "W PRE " .. P.tag .. string.format(" %.3f ", t)
          D.preview[head] = D.preview[head] or {}
          D.preview[head][#D.preview[head] + 1] = s .. "~" .. key .. "=" .. (row or "!")
        end
      elseif paired then earlyPair(P.tag, s, key, paired.sec[s][key], row, nil, t)
      elseif early and early[key] then
        local x = early[key]; earlyPair(P.tag, s, key, x.row, row, x.t, t)
      elseif base then earlyPair(P.tag, s, key, base[key], row, nil, t) end
    end
    if k then observe(k) else
      for key in pairs(map) do if groupOf(s, key) == group then observe(key) end end
      for key in pairs(base or {}) do if groupOf(s, key) == group and not map[key] then observe(key) end end
      for key in pairs(early or {}) do if groupOf(s, key) == group and not map[key] and not (base and base[key]) then observe(key) end end
    end
  end
end
function Check.absent(sample)
  local D, tag = W.wd, tostring(sample.tag); local h = D.host[tag]
  for _, spec in ipairs(WIDE) do
    local s = spec[1]
    local early = D.early[tag] and D.early[tag][s]
    local base = h and h.sec[s] or (D.base and D.base[s]) or {}
    local function absent(k)
      local group = groupOf(s, k)
      if (group == "building" or group == "region" or group == "family") and not sampleTime(sample.times, s, k) then
        local x = early and early[k]
        if h or not x then earlyPair(tag, s, k, base[k], nil, nil, sample.finish)
        else earlyPair(tag, s, k, x.row, nil, x.t, sample.finish) end
      end
    end
    for k in pairs(base) do absent(k) end
    for k in pairs(early or {}) do if not base[k] then absent(k) end end
  end
end
local function rowTime(sample, s, k)
  return sampleTime(sample.times, s, k) or sample.finish
end
function Check.section(tag, s, items, sample)
  if #items == 0 then return end
  local batch = { tag = tag, s = s, items = {}, due = os.clock() }
  for _, x in ipairs(items) do
    local at = x.at or (sample and rowTime(sample, s, x.k))
    local w = watch(s, x.k, x.f, tostring(tag))
    record(w, "friend", at, x.m)
    Check.proofFill(w, at)
    batch.items[#batch.items + 1] = { w = w, at = at, initial = x.m, hostInitial = x.h }
    -- Allow final host observations to travel. Classification uses their read stamps.
    local now = Check.clock(W.S)
    local remaining = now and at and math.max(0, math.min(3, at + 3 - now)) or 3
    batch.due = math.max(batch.due, os.clock() + remaining + 1)
  end
  W.wd.batches[#W.wd.batches + 1] = batch
  log("settle %s %s sample=%d", tostring(tag), s, #items)
end
function Check.fingerprint(day, a, b)
  for _, s in ipairs(FP_ORDER) do
    if (a[s] or ""):find("ERR", 1, true) or (b[s] or ""):find("ERR", 1, true) then
      log("settle-invalid %s %s unreadable fingerprint", tostring(day), s)
    elseif a[s] ~= b[s] and (s == "B" or s == "C" or s == "O") then
      local tag = tostring(day)
      W.wd.details[tag .. s] = { mine = b, host = {}, count = 0, since = os.clock() }
      log("settle-detail %s %s requested", tag, s)
      send("W FPASK " .. tag .. " " .. s)
    elseif a[s] ~= b[s] then
      local x, y = fingerprintFields(s, a[s] or "ERR"), fingerprintFields(s, b[s] or "ERR")
      local keys, items = {}, {}
      for k in pairs(x) do keys[k] = true end; for k in pairs(y) do keys[k] = true end
      local missing = (s == "Q" or s == "S") and "0" or "absent"
      for k in pairs(keys) do
        if (x[k] or missing) ~= (y[k] or missing) then
          items[#items + 1] = { k = k, f = "value", h = x[k] or missing, m = y[k] or missing, at = fpTime(b, s, k) }
        end
      end
      Check.section(day, s, items)
    end
  end
end
-- Positive evidence is a dated host read in the closed interval. For a negative
-- result require observations across that interval. A gap, an error, or a late
-- reply cannot establish either equality or a foreign value.
local function evidence(history, t, v)
  if v == "?" or v == "ERR" then return "unknown" end
  local left, prev, gap = t - 3, nil, false
  for _, h in ipairs(history) do
    if h.t > t then break end
    if h.t >= left then
      if h.v == v then return "match" end
      if h.v == "?" or h.v == "ERR" or h.t - (prev or left) > 0.6 then gap = true end
      prev = h.t
    end
  end
  if not prev or gap or t - prev > 0.6 then return "unknown" end
  return "outside"
end
local function classify(x)
  local w, start = x.w, x.at
  if not start then return false, false, false, false, true, "no-clock", "-", "-" end
  local deadline = start + 3
  local last, firstMatch, foreign, stale, unknown = nil, nil, false, false, false
  table.sort(w.friend, function(a, b) return a.t < b.t end)
  for _, f in ipairs(w.friend) do
    if f.t >= deadline and f.t <= deadline + 0.6 and (not last or f.t < last.t) then last = f end
  end
  table.sort(w.host, function(a, b) return a.t < b.t end)
  local previous = start
  for _, f in ipairs(w.friend) do
    if f.t >= start and f.t <= (last and last.t or deadline) then
      if f.t - previous > 0.6 then unknown = true end
      previous = f.t
      local result = evidence(w.host, f.t, f.v)
      if result == "match" then
        if f.t <= deadline then firstMatch = math.min(firstMatch or f.t, f.t) end
      elseif result == "outside" then
        if w.seen[f.v] and w.seen[f.v] <= f.t then stale = true else foreign = true end
      else unknown = true end
    end
  end
  local atEnd = last and evidence(w.host, last.t, last.v) or "unknown"
  unknown = unknown or atEnd == "unknown" or (atEnd == "match" and not firstMatch)
  local latest
  if last then for _, h in ipairs(w.host) do if h.t > last.t then break end; latest = h end end
  if not latest or last.t - latest.t > 0.6 or latest.v == "?" or latest.v == "ERR" then unknown = true end
  return firstMatch ~= nil and atEnd == "match" and not unknown, atEnd == "outside", foreign, stale, unknown,
    last and string.format("%s@+%.3f", last.v, last.t - start) or "missing",
    latest and string.format("%s@%+.3f", latest.v, latest.t - start) or "missing",
    firstMatch and string.format("%.3f", firstMatch - start) or "-"
end
-- Both sides use the host time scale. Keep every distinct read, including
-- unchanged values, so gaps and the preceding three seconds can be audited.
local function timeline(history, start, lead)
  if not start then return "-" end
  local words, previous = {}, nil
  for _, r in ipairs(history) do
    local ms = math.floor((r.t - start) * 1000 + 0.5)
    if ms >= lead and ms <= 3600 then
      local word = tostring(ms) .. ":" .. r.v
      if word ~= previous then words[#words + 1] = word; previous = word end
    end
  end
  return #words > 0 and table.concat(words, ";") or "-"
end
local function finish(batch)
  local delay, past, foreign, stale, unknown = 0, 0, 0, 0, 0
  for _, x in ipairs(batch.items) do
    local ok, p, f, old, u, value, hostValue, firstMatch = classify(x)
    if ok then delay = delay + 1 end; if p then past = past + 1 end
    if f then foreign = foreign + 1 end; if old then stale = stale + 1 end; if u then unknown = unknown + 1 end
    log("settle-field %s %s %s %s initial=%s/%s recheck=%s/%s firstMatch=%s past=%d foreign=%d stale=%d unverified=%d at=%.3f hostMs=%s friendMs=%s",
      tostring(batch.tag), batch.s, x.w.k, x.w.f, tostring(x.hostInitial), x.initial, hostValue, value, firstMatch,
      p and 1 or 0, f and 1 or 0, old and 1 or 0, u and 1 or 0, x.at or 0,
      timeline(x.w.host, x.at, -3000), timeline(x.w.friend, x.at, 0))
  end
  log("settle %s %s sample=%d settled=%d past3=%d foreign=%d stale=%d unverified=%d",
    tostring(batch.tag), batch.s, #batch.items, delay, past, foreign, stale, unknown)
end
local function prior(tag, s, k, f)
  local sample = W.wd.samples[tag]
  if WIDE_BY[s] then
    if sample then return rowTime(sample, s, k), fieldValue(s, f, sample.sec[s][k]) end
  else
    local P = W.wd.fpSamples[tag]
    if P then
      if P.detail[s] then
        local stamp = s == "O" and P.at.O or P.at.rows[k]
        return stamp, detailValue(s, P.detail[s][k], f)
      end
      local missing = (s == "Q" or s == "S") and "0" or "absent"
      return fpTime(P, s, k), fingerprintFields(s, P[s] or "ERR")[k] or missing
    end
  end
end
local function compareDetails(tag, s, pending)
  local P, a = pending.mine, pending.host
  local b, keys, items = P.detail[s], {}, {}
  for k in pairs(a) do keys[k] = true end; for k in pairs(b) do keys[k] = true end
  for k in pairs(keys) do
    if a[k] ~= b[k] then
      local fields = {}
      if not a[k] or not b[k] then fields.present = true
      elseif s == "O" then fields.owner = true
      elseif s == "B" then for _, f in ipairs(bfields) do fields[f] = true end
      else for g in (a[k] .. "," .. b[k]):gmatch("(%d+):") do fields["g" .. g] = true end end
      for f in pairs(fields) do
        local h, m = detailValue(s, a[k], f), detailValue(s, b[k], f)
        if h ~= m then items[#items + 1] = { k = k, f = f, h = h, m = m,
          at = s == "O" and P.at.O or (P.at.rows[k] or P.at.buildings) } end
      end
    end
  end
  if #items == 0 then log("settle-detail %s %s unverified", tag, s); return end
  log("settle-detail %s %s complete", tag, s)
  Check.section(tag, s, items)
end
-- ---- the timing proof (lane 76): the host's own dated history of the rows players see. TEST TOOL, off for players
-- (cfg.proof; the session check switches it on with Coop.world.cfg.proof = true on both copies). Read only.
-- Why: a friend's reading can be judged only against host reads of the 3 s BEFORE it. The host began reading a row
-- 0.2 to 0.5 s after the friend named it, so the friend's first readings had nothing to be judged against (session
-- l76i: 2,184 readings "unverified"). With the proof on, the host reads every row of the sections below again and
-- again (one round every cfg.proofEvery s, at most cfg.proofMs ms a tick), keeps cfg.proofKeep s of dated reads and,
-- when a friend names a field (W WATCH), sends the kept reads of that field as ordinary W OBS lines with their own
-- read times. Nothing here reaches compareFp, W.miss or the game.
--   rows: the fingerprint's parts (W M N Q as one word each, F R S per owned region, B C per own building, O per
--   region) and the wide sections named in cfg.proofSecs.
--   a row that a finished round did not find is kept as "not there" for that round (false), so "absent" is dated too.
local proofGroup = {}
for group, list in pairs(groups) do for _, s in ipairs(list) do if s ~= "mk" then proofGroup[s] = group end end end
local function proofState()
  local D = W.wd
  if not D.proof then
    D.proof = { hist = {}, ends = {}, cyc = 0, served = {}, stat = { c0 = os.clock(), ms = 0, maxTick = 0, maxGap = 0, gaps = 0, cycles = 0, rows = 0, ids = 0, reads = 0 } }
  end
  return D.proof
end
local function proofSecs(Pr)
  local text = tostring(W.cfg.proofSecs or "")
  if Pr.secText ~= text then
    Pr.secText = text; Pr.secs = { building = {}, region = {}, family = {} }; Pr.secOn = {}
    for s in text:gmatch("%l+") do
      local group = proofGroup[s]
      if WIDE_BY[s] and Pr.secs[group] then Pr.secs[group][#Pr.secs[group] + 1] = s; Pr.secOn[s] = true end
    end
  end
  return Pr.secs
end
local function proofPut(Pr, key, row, t)
  local h = Pr.hist[key]
  if not h then
    h = { t = {}, v = {}, i = 1, n = 0 }; Pr.hist[key] = h
    for _, e in ipairs(Pr.ends) do h.n = h.n + 1; h.t[h.n] = e; h.v[h.n] = false end      -- not there in the rounds before
  elseif h.n >= h.i then
    local gap = t - h.t[h.n]
    if gap > Pr.stat.maxGap then Pr.stat.maxGap = gap end
    if gap > 0.55 then Pr.stat.gaps = Pr.stat.gaps + 1 end
  end
  h.n = h.n + 1; h.t[h.n] = t; h.v[h.n] = row or false; h.c = Pr.cyc
  Pr.stat.reads = Pr.stat.reads + 1
end
-- a building's key as the day scan names it; nil for an actor the game has cleared (type 0 or place 0,0)
local function proofKey(b)
  local ok, k = pcall(W.bkey, b)
  if not ok or type(k) ~= "string" or k:match("^0@") or k:match("@0,0$") then return nil end
  return k
end
local function proofStep(S, J, Pr, t)
  local eng = S.eng; local secs = proofSecs(Pr)
  if J.phase == 1 then                                   -- the world's words and the regions
    local T = eng.TemporalComponent
    local P = {}
    sec(P, "W", function() if not valid(T) then return "ERR" end; return string.format("%d,%d,%d,%d,%d,%d", T.Season, T.month, T.rainMeter, T.isDrought and 1 or 0, T.isWinter and 1 or 0, T.daysWithoutRainVariation) end)
    sec(P, "M", function() return string.format("%d,%d", #eng.freeMerchants, #eng.livestockMerchants) end)
    sec(P, "N", function() return string.format("%d,%d,%d", S.p1.silver, S.p1.influence, S.p1.kingsFavour) end)
    sec(P, "Q", function() return fpSoldiers(S) end)
    for _, s in ipairs({ "W", "M", "N", "Q" }) do proofPut(Pr, s, P[s] ~= "ERR" and P[s] or "?", t) end
    J.regs = {}; J.F = {}; J.R = {}; J.S = {}; J.ri = 0
    local arr = eng.regions
    for i = 1, #arr do local r = un(arr[i]); if valid(r) then J.regs[#J.regs + 1] = r end end
    J.phase = 2; return false
  elseif J.phase == 2 then                               -- one region per step
    J.ri = J.ri + 1
    local r = J.regs[J.ri]
    if r then
      if valid(r) then
        local k = W.rkey(r)
        proofPut(Pr, "O~" .. k, ownerCode(r.ownerPawn), t)
        if mine(r.ownerPawn) then J.F[#J.F + 1], J.R[#J.R + 1], J.S[#J.S + 1] = fpRegionWords(S, r, k) end
        for _, s in ipairs(secs.region) do
          local P = { [s] = {} }
          if pcall(wideRegion, P, r, s) then proofPut(Pr, s .. "~" .. k, P[s][k], t) else proofPut(Pr, s .. "~" .. k, "?", t) end
        end
      end
      return false
    end
    table.sort(J.F); table.sort(J.R); table.sort(J.S)
    proofPut(Pr, "F", (table.concat(J.F, "|"):gsub("%s", "_")), t)
    proofPut(Pr, "R", #J.R > 0 and table.concat(J.R, "|") or "-", t)
    proofPut(Pr, "S", #J.S > 0 and table.concat(J.S, "|") or "-", t)
    J.phase = 3; J.ri = 1; J.fi = 0; J.keyOf = {}; J.own = {}; J.seen = {}; J.dup = 0; J.i = 0
    return false
  elseif J.phase == 4 then                               -- last: eight families per step
    local r = J.regs[J.ri]
    if not r then return true end
    local n = 0
    if valid(r) then
      local okK, k = pcall(W.rkey, r); local fams = r.workerFamilies
      local P = { fa = {}, fc = {}, keyOf = J.keyOf }
      while okK and J.fi < #fams and n < 8 do
        J.fi = J.fi + 1; n = n + 1
        local key = k .. ":F" .. J.fi
        if pcall(wideFamily, P, k, fams[J.fi], J.fi) then
          for _, s in ipairs(secs.family) do proofPut(Pr, s .. "~" .. key, P[s][key], t) end
        end
      end
    end
    if n < 8 then J.ri = J.ri + 1; J.fi = 0 end
    return false
  end
  local arr = eng.buildingArr                            -- phase 3: one building per step
  J.i = J.i + 1
  if J.i > #arr then
    if #secs.family == 0 then return true end
    J.phase = 4; return false
  end
  local b = un(arr[J.i])
  if not valid(b) then return false end
  local k = proofKey(b); if not k then return false end
  local base = k
  if J.seen[k] then J.dup = J.dup + 1; k = k .. "#" .. J.dup end; J.seen[base] = true
  local ba = addr(b); if ba then J.keyOf[ba] = k end
  for _, s in ipairs(secs.building) do
    local P = { dup = 0, keyOf = J.keyOf, own = J.own, bl = {} }; P[s] = {}
    if pcall(wideBuilding, P, b, s) then proofPut(Pr, s .. "~" .. k, P[s][base], t) else proofPut(Pr, s .. "~" .. k, "?", t) end
  end
  -- the fingerprint's building rows (as fpBuilding makes them): the lord's own buildings, not a pile (type 88)
  local okD, dump = pcall(function() return b:GetType() == 88 end)
  if okD and not dump and mine(b.ownerPawn) then
    local okB, brow, crow = pcall(function()
      local built = b:IsConstructed()
      local row = table.concat({ built and 1 or 0, b.lv, b:getNumActiveWorkerFamilies(), b:getNumResidingFamilies(), b.onFire and 1 or 0, b.sleep and 1 or 0 }, "|")
      local inventory
      if W.on.bstock and not built and not b.isBeingUpgraded then
        local g = {}; for g2, a in pairs(invOf(b)) do g[#g + 1] = g2 .. ":" .. a end
        table.sort(g); inventory = table.concat(g, ","); if inventory == "" then inventory = "0" end
      end
      return row, inventory
    end)
    proofPut(Pr, "B~" .. k, okB and brow or "?", t)
    if okB and crow then proofPut(Pr, "C~" .. k, crow, t) elseif not okB then proofPut(Pr, "C~" .. k, "?", t) end
  end
  return false
end
local function proofEnd(Pr, t)
  local keep = W.cfg.proofKeep; local rows = 0
  for key, h in pairs(Pr.hist) do
    if h.c ~= Pr.cyc then h.n = h.n + 1; h.t[h.n] = t; h.v[h.n] = false end              -- not found in this round
    while h.i <= h.n and t - h.t[h.i] > keep do h.t[h.i] = nil; h.v[h.i] = nil; h.i = h.i + 1 end
    if h.i > 64 then                                                                      -- move the kept reads to the front
      local nt, nv, m = {}, {}, 0
      for i = h.i, h.n do m = m + 1; nt[m] = h.t[i]; nv[m] = h.v[i] end
      h.t, h.v, h.i, h.n = nt, nv, 1, m
    end
    local live = false
    for i = h.i, h.n do if h.v[i] then live = true; break end end
    if live then rows = rows + 1 else Pr.hist[key] = nil end                               -- nothing but "not there": forget it
  end
  local e = Pr.ends; e[#e + 1] = t
  while e[1] and t - e[1] > keep do table.remove(e, 1) end
  Pr.stat.rows = rows; Pr.stat.cycles = Pr.stat.cycles + 1
end
function Check.proofTick(S)
  local Pr = proofState(); local c0 = os.clock(); local st = Pr.stat
  if not Pr.job then
    if c0 - (Pr.startC or -1e9) < W.cfg.proofEvery then return end
    Pr.cyc = Pr.cyc + 1; Pr.startC = c0; Pr.job = { phase = 1 }
  end
  local t = Check.clock(S); if not t then return end
  local budget = W.cfg.proofMs / 1000; local done = false; local part = Pr.job.phase; local failed = false
  repeat
    local ok, r = pcall(proofStep, S, Pr.job, Pr, t)
    if not ok then st.err = tostring(r); st.errs = (st.errs or 0) + 1; done = true; failed = true else done = r end
  until done or os.clock() - c0 >= budget
  if done then
    local long = os.clock() - Pr.startC
    if long > (st.maxCycle or 0) then st.maxCycle = long end
    -- a round that broke off is not a finished round: the rows it did not reach get no "not there" (they keep a
    -- hole, which the check reads as "cannot be timed")
    Pr.job = nil; if not failed then proofEnd(Pr, t) end
  end
  local ms = (os.clock() - c0) * 1000
  st.ms = st.ms + ms; if ms > st.maxTick then st.maxTick = ms end
  st.part = st.part or { 0, 0, 0, 0 }; st.part[part] = st.part[part] + ms      -- by the part the tick began in
  if c0 - st.c0 >= 60 then
    log("proof parts (ms a second): world %.1f, regions %.1f, buildings %.1f, families %.1f", st.part[1] / (c0 - st.c0), st.part[2] / (c0 - st.c0), st.part[3] / (c0 - st.c0), st.part[4] / (c0 - st.c0))
    log("proof: %d rounds in %.0f s, %d rows, %d reads, %.2f ms a second, worst tick %.1f ms, longest round %.3f s, longest gap between two reads of a row %.3f s, gaps over 0.55 s %d, fields served %d%s",
      st.cycles, c0 - st.c0, st.rows, st.reads, st.ms / (c0 - st.c0), st.maxTick, st.maxCycle or 0, st.maxGap, st.gaps, st.ids, st.err and (", read errors " .. tostring(st.errs) .. " (" .. st.err .. ")") or "")
    Pr.total = Pr.total or { ms = 0, s = 0, maxTick = 0, maxGap = 0, gaps = 0, cycles = 0, reads = 0, ids = 0, errs = 0 }
    local T = Pr.total
    T.ms = T.ms + st.ms; T.s = T.s + (c0 - st.c0); T.cycles = T.cycles + st.cycles; T.reads = T.reads + st.reads; T.gaps = T.gaps + st.gaps; T.ids = T.ids + st.ids
    T.errs = T.errs + (st.errs or 0)
    if st.maxTick > T.maxTick then T.maxTick = st.maxTick end; if st.maxGap > T.maxGap then T.maxGap = st.maxGap end
    Pr.stat = { c0 = c0, ms = 0, maxTick = 0, maxGap = 0, gaps = 0, cycles = 0, rows = st.rows, ids = 0, reads = 0 }
  end
end
-- the kept value of one field at one kept read (row: the row's text, or false = not there)
local function proofValue(s, k, f, row)
  if WIDE_BY[s] then return fieldValue(s, f, row or nil) end
  if s == "B" or s == "C" or s == "O" then return detailValue(s, row or nil, f) end
  if not row or row == "?" then return "?" end
  return fingerprintFields(s, row)[k] or ((s == "Q" or s == "S") and "0" or "absent")
end
local function proofReads(Pr, s, k, f, add)
  local row = WIDE_BY[s] or s == "B" or s == "C" or s == "O"
  local h = Pr.hist[row and (s .. "~" .. k) or s]
  if h then for i = h.i, h.n do add(h.t[i], proofValue(s, k, f, h.v[i])) end
  elseif row then for _, e in ipairs(Pr.ends) do add(e, proofValue(s, k, f, false)) end end   -- never there in the kept rounds
end
-- friend: this copy's own kept reads of a field since its day sample read it (at). The friend opens its watch of a
-- field only when the day's comparison is made, up to seconds after the sample read the row; without these its own
-- series had a hole there and the field stayed "unverified" (session l76j: 0 ms, then 943 ms).
function Check.proofFill(w, at)
  if not (W.cfg.proof and at) then return end
  local Pr = W.wd.proof; if not Pr then return end
  if WIDE_BY[w.s] and not (Pr.secOn and Pr.secOn[w.s]) then return end
  if w.f == "*" and not WIDE_BY[w.s] then return end
  proofReads(Pr, w.s, w.k, w.f, function(t, v) if t > at and v ~= nil then record(w, "friend", t, v) end end)
end
-- host: the kept reads of a field a friend has just named go into the reply (history[<read time>] = { "<id>=<value>" })
function Check.proofServe(id, s, k, f, history)
  if not W.cfg.proof then return 0 end
  local Pr = proofState(); local wide = WIDE_BY[s]
  if wide and not (Pr.secOn and Pr.secOn[s]) then return 0 end
  if f == "*" and not wide then return 0 end
  local after = Pr.served[id] or -1; local last = after; local n = 0
  proofReads(Pr, s, k, f, function(t, v)
    if t > after and v ~= nil then
      history[t] = history[t] or {}; history[t][#history[t] + 1] = id .. "=" .. tostring(v); n = n + 1
      if t > last then last = t end
    end
  end)
  Pr.served[id] = last
  if n > 0 then Pr.stat.ids = Pr.stat.ids + 1 end
  return n
end
function W.proofStat()
  local D = W.wd; local Pr = D and D.proof
  if not Pr then return "proof: off or no round yet" end
  local st, T = Pr.stat, Pr.total or { ms = 0, s = 0, maxTick = 0, maxGap = 0, gaps = 0, cycles = 0, reads = 0, ids = 0, errs = 0 }
  local s = T.s + (os.clock() - st.c0)
  return string.format("proof %s: %d rounds in %.0f s, %d rows, %d reads, %.2f ms a second, worst tick %.1f ms, longest gap %.3f s, gaps over 0.55 s %d, fields served %d, read errors %d",
    W.cfg.proof and "on" or "off", T.cycles + st.cycles, s, st.rows, T.reads + st.reads, s > 0 and (T.ms + st.ms) / s or 0, math.max(T.maxTick, st.maxTick), math.max(T.maxGap, st.maxGap),
    T.gaps + st.gaps, T.ids + st.ids, T.errs + (st.errs or 0))
end
function Check.receive(S, from, msg)
  local D = W.wd
  local tag, section = msg[5], msg[6]
  if msg[4] ~= "OBS" and (not tag or not tag:match("^n?%d+$")) then return end
  if S.role == "friend" and from == "host" and msg[4] == "PRE" then
    local stamp = tonumber(section)
    if not stamp or (tonumber(tag) and W.day and math.abs(tonumber(tag) - W.day) > 4) then return end
    local e = D.early[tag] or {}; D.early[tag] = e
    local mine = D.mine[tag]; local active = D.run and D.run.tag == tag and D.run.P
    for s, k, v in (msg[7] or ""):gmatch("(%l+)~([^=;]+)=([^;]+)") do
      if WIDE_BY[s] then
        local row; if v ~= "!" then row = v end
        e[s] = e[s] or {}; e[s][k] = { row = row, t = stamp }
        local times = mine and mine.times or (active and active.times)
        local ft = times and sampleTime(times, s, k) or (mine and mine.finish)
        local maps = mine and mine.sec or active
        if ft and maps then earlyPair(tag, s, k, row, maps[s][k], stamp, ft) end
      end
    end
  elseif S.role == "host" and msg[4] == "FPASK" then
    local P = D.fpSamples[tag]
    if P and P.detail[section] then
      local items = {}
      for k, row in pairs(P.detail[section]) do items[#items + 1] = k .. "~" .. row end
      local head = "W FPROWS " .. tag .. " " .. section .. " "
      sendList(head, items, ";"); send(head .. "END " .. #items)
    end
  elseif S.role == "friend" and from == "host" and msg[4] == "FPROWS" then
    local key = tostring(tag) .. tostring(section); local pending = D.details[key]
    if not pending then return end
    if msg[7] == "END" then
      D.details[key] = nil
      if pending.count == tonumber(msg[8]) then compareDetails(tag, section, pending)
      else log("settle-detail %s %s unverified", tag, section) end
    else
      for k, row in (msg[7] or ""):gmatch("([^~;]+)~([^;]+)") do
        if pending.host[k] == nil then pending.count = pending.count + 1 end
        pending.host[k] = row
      end
    end
  elseif S.role == "host" and msg[4] == "WATCH" and tag and (D.samples[tag] or D.fpSamples[tag] or (D.run and D.run.tag == tag)
      or (W.day and tonumber(tag) and (tonumber(tag) == W.day or tonumber(tag) == W.day + 1))) then
    local history = {}
    for id in (msg[6] or ""):gmatch("[^;]+") do
      local s, k, f = descriptor(id)
      if s then
        watch(s, k, f)
        Check.proofServe(id, s, k, f, history)
        for _, tag in ipairs((WIDE_BY[s] and D.samples.order or D.fpSamples.order) or {}) do
          local t, v = prior(tag, s, k, f)
          if t and v ~= nil then
            history[t] = history[t] or {}; history[t][#history[t] + 1] = id .. "=" .. v
          end
        end
      end
    end
    for t, items in pairs(history) do sendList(string.format("W OBS %.3f ", t), items, ";") end
  elseif S.role == "friend" and from == "host" and msg[4] == "OBS" then
    local t = tonumber(msg[5])
    for id, v in (msg[6] or ""):gmatch("([^;=]+)=([^;]+)") do
      local w = D.watches[id]; if w then record(w, "host", t, v) end
    end
  end
end
function Check.tick(S)
  local D, now = W.wd, os.clock()
  if D.preview then
    for head, items in pairs(D.preview) do sendList(head, items, ";") end
    D.preview = nil
  end
  if D.ask then
    for tag, ids in pairs(D.ask) do
      local words = {}; for id in pairs(ids) do words[#words + 1] = id end
      sendList("W WATCH " .. tag .. " ", words, ";")
    end
    D.ask = nil
  end
  if W.cfg.proof then Check.proofTick(S) end
  if now < (D.checkNext or 0) then return end
  D.checkNext = now + 0.18
  local memo, frames = {}, {}; local t = Check.clock(S)
  for id, w in pairs(D.watches) do
    if now <= w.untilT then
      local ok, v = pcall(read, S, w.s, w.k, w.f, memo)
      v = (ok and v ~= nil) and tostring(v) or "?"
      local stamp = Check.clock(S)
      if S.role == "host" and stamp then
        local ms = string.format("%.3f", stamp)
        frames[ms] = frames[ms] or {}; frames[ms][#frames[ms] + 1] = id .. "=" .. v
      else record(w, "friend", stamp, v) end
    elseif now - w.untilT > 45 then D.watches[id] = nil end
    if #w.host > 350 or #w.friend > 350 then
      for _, side in ipairs({ "host", "friend" }) do
        local keep = {}; for _, r in ipairs(w[side]) do if t and t - r.t < 35 then keep[#keep + 1] = r end end
        w[side] = keep
      end
    end
  end
  for stamp, items in pairs(frames) do sendList("W OBS " .. stamp .. " ", items, ";") end
  for i = #D.batches, 1, -1 do if now >= D.batches[i].due then finish(table.remove(D.batches, i)) end end
  for key, pending in pairs(D.details) do if now - pending.since > 8 then
    log("settle-detail %s %s unverified", key:sub(1, -2), key:sub(-1)); D.details[key] = nil
  end end
end
end

-- friend: one section per tick is compared, counted and logged; then the day's summary line.
-- LOG ONLY: nothing here asks for a resync.
local function wideCmpStep(J)
  local Hs, Ms, tag = J.Hs, J.Ms, J.tag
  J.i = J.i + 1
  local spec = WIDE[J.i]
  if spec then
    local sec = spec[1]; local R = wideCompareSec(spec, Hs, Ms); J.res[sec] = R
    Check.section(tag, sec, R.items, Ms)
    local Cn = W.wideCnt[sec]; if not Cn then Cn = { days = 0, bad = 0, items = 0, held = 0, max = 0, badP = 0, itemsP = 0 }; W.wideCnt[sec] = Cn end
    Cn.days = Cn.days + 1; Cn.items = Cn.items + R.n; Cn.held = Cn.held + R.held; Cn.itemsP = Cn.itemsP + R.nP
    if R.n > 0 then Cn.bad = Cn.bad + 1 end
    if R.nP > 0 then Cn.badP = Cn.badP + 1 end
    if R.max > Cn.max then Cn.max = R.max end
    J.day.n[sec] = R.n; J.day.nP[sec] = R.nP; J.day.held[sec] = R.held; J.day.max[sec] = R.max
    -- <section>=<differences>[p<of them on the player's own>][+<held by design>h]
    J.sum[#J.sum + 1] = sec .. "=" .. R.n .. ((WIDE_KIND[sec] and R.n > 0) and ("p" .. R.nP) or "") .. (R.held > 0 and ("+" .. R.held .. "h") or "")
    local extra = ""
    if sec == "bl" then                                    -- buildings per owner, host / here
      local ca, cb, codes = {}, {}, {}
      for _, v in pairs(Hs.sec.bl or {}) do local o = v:match("^([^|]*)") or "?"; ca[o] = (ca[o] or 0) + 1; codes[o] = true end
      for _, v in pairs(Ms.sec.bl or {}) do local o = v:match("^([^|]*)") or "?"; cb[o] = (cb[o] or 0) + 1; codes[o] = true end
      local t = {}; for o in pairs(codes) do t[#t + 1] = o .. "=" .. (ca[o] or 0) .. "/" .. (cb[o] or 0) end
      table.sort(t); extra = " owners " .. table.concat(t, " ")
    end
    if R.n > 0 or R.held > 0 or sec == "bl" then
      local t = {}; local cap = W.cfg.wideLogMax
      for i, it in ipairs(R.items) do
        if i > cap then t[#t + 1] = string.format("(+%d more)", #R.items - cap); break end
        t[#t + 1] = it.k .. " " .. it.f .. " " .. it.h .. "/" .. it.m .. (it.mark and ("(" .. it.mark .. ")") or "") .. (it.o and (" " .. it.o) or "")
      end
      -- one difference = <key> <field> <host>/<here>[(held)] [<owner>]
      log("wide %s %s differ=%d player=%d held=%d max=%s sum=%s onlyHost=%d onlyHere=%d%s: %s", tostring(tag), sec, R.n, R.nP, R.held, wFmt(R.max), wFmt(R.sum), R.onlyH, R.onlyF, extra,
        #t > 0 and table.concat(t, "; ") or "-")
    end
    return false
  end
  W.wideStat.compared = W.wideStat.compared + 1; bump("w_wideCmp")
  W.wideDays[#W.wideDays + 1] = J.day
  while #W.wideDays > W.cfg.wideKeep do table.remove(W.wideDays, 1) end
  W.wideLast[#W.wideLast + 1] = { tag = tag, day = Ms.day, res = J.res, names = Ms.sec.ro }
  while #W.wideLast > 4 do table.remove(W.wideLast, 1) end
  log("wide %s summary %s | %d values; host %.0f ms / %d ticks, here %.0f ms / %d ticks", tostring(tag), table.concat(J.sum, " "), Ms.n, Hs.ms or 0, Hs.ticks or 0, Ms.ms or 0, Ms.ticks or 0)
  return true
end

-- friend: both samples of a day are here: queue the comparison
local function wideTry(S, tag)
  local D = W.wd; local Hs, Ms = D.host[tag], D.mine[tag]
  if not (Hs and Ms) then return end
  D.host[tag] = nil; D.mine[tag] = nil; D.early[tag] = nil
  local nt = tonumber(tag)
  if nt then
    for t in pairs(D.host) do local x = tonumber(t); if x and x < nt - 3 then D.host[t] = nil end end
    for t in pairs(D.mine) do local x = tonumber(t); if x and x < nt - 3 then D.mine[t] = nil end end
  end
  D.posts[#D.posts + 1] = { kind = "cmp", tag = tag, Hs = Hs, Ms = Ms, i = 0, res = {}, sum = {}, day = { tag = tag, day = Ms.day, n = {}, nP = {}, held = {}, max = {} } }
end

local function widePostStep(J) if J.kind == "send" then return wideSendStep(J) end; return wideCmpStep(J) end

-- A sample whose sending stopped half way (an error, the switch turned off) has already replaced, for the sections
-- that went out, what "changes only" are worked out against: the next sample must go out whole.
local function widePostFailed(J, e)
  bump("w_err"); log("wide: sending or comparing failed: %s", tostring(e))
  if J.kind == "send" then W.wd.wantFull = true end
end

-- everything that is queued, in one call (on demand only)
local function wideDrain()
  local D = W.wd
  while D.posts[1] do
    local J = D.posts[1]
    local ok, done = pcall(widePostStep, J)
    if not ok then widePostFailed(J, done) end
    if not ok or done then table.remove(D.posts, 1) end
  end
end

-- friend, at its day change: what waits for a partner that never comes is dropped. A host with the switch off or
-- with an older build sends nothing, and each day's own sample would stay for ever; a sample whose END line never
-- arrives would too.
local function widePrune(day)
  local D = W.wd; local now = os.clock()
  for _, t in ipairs({ D.mine, D.host, D.early }) do
    for tag in pairs(t) do local x = tonumber(tag); if x and x < day - 3 then t[tag] = nil end end
  end
  for tag, I in pairs(D.inb) do if now - (I.t or now) > 300.0 then D.inb[tag] = nil end end
end

-- every tick while there is something to do: one section of a finished sample (sent or compared), else a few objects
-- of the sample that is being taken
local function wideTick(S)
  local D = W.wd; local t0 = os.clock()
  local J = D.posts[1]
  if J then
    for _ = 1, ((D.tpd and D.tpd < 240) and 2 or 1) do   -- two sections per tick when a game day is short in ticks
      local ok, done = pcall(widePostStep, J)
      if not ok then widePostFailed(J, done) end
      if not ok or done then table.remove(D.posts, 1); break end
    end
  elseif D.run then
    local st = D.run; local work = 0; st.ticks = st.ticks + 1; local fin = false
    while work < (st.rate or W.cfg.wideWork) do
      local w = wideStep(S, st)
      if w == nil then fin = true; break end
      work = work + w
      if os.clock() - t0 >= 0.002 then break end         -- second guard: never much more than 2 ms in one tick
    end
    st.ms = st.ms + (os.clock() - t0) * 1000
    if fin then
      D.run = nil
      local ok, e = pcall(wideFinish, st); if not ok then bump("w_err"); log("wide %s failed: %s", tostring(st.tag), tostring(e)) end
    end
  end
  -- os.clock is the wall clock here and steps in milliseconds: a tick in which Windows gave the processor to another
  -- program reads long. So the ticks over 2 and over 5 ms are counted, beside the longest one.
  local ms = (os.clock() - t0) * 1000
  if ms > (W.wideMaxTickMs or 0) then W.wideMaxTickMs = ms end
  W.wideTicks = (W.wideTicks or 0) + 1; W.wideMs = (W.wideMs or 0) + ms
  if ms > 2.5 then W.wideOver2 = (W.wideOver2 or 0) + 1 end
  if ms > 5.5 then W.wideOver5 = (W.wideOver5 or 0) + 1 end
end

local function wideParse(map, body)
  for e in body:gmatch("[^;]+") do
    local k, v = e:match("^([^|]+)|(.*)$")
    if k then if v == "!" then map[k] = nil else map[k] = v end end
  end
end

-- friend: one W G line. A sample counts only when every line of it arrived (lines are dropped while a save loads).
local function wideRecv(S, w)
  local D = W.wd; local tag, sec = w[5], w[6]
  if not (tag and sec) then return end
  local I = D.inb[tag]; if not I then I = { lines = 0, sec = {}, t = os.clock() }; D.inb[tag] = I end
  if sec ~= "END" then
    I.lines = I.lines + 1
    local P = I.sec[sec]; if not P then P = {}; I.sec[sec] = P end
    P[#P + 1] = w[7] or ""
    return
  end
  D.inb[tag] = nil
  if w[13] ~= WIDE_SPEC then                              -- another build's sections or fields: nothing to set beside
    D.base = nil; D.baseSerial = nil; bump("w_wideOther")
    if D.otherLogged ~= tostring(w[13]) then
      D.otherLogged = tostring(w[13])
      log("wide %s: the host's sample has other sections or fields than this copy's (another build of the mod): not compared", tostring(tag))
    end
    return
  end
  local serial, base, lines = tonumber(w[7]), tonumber(w[8]), tonumber(w[9])
  if not (serial and base and lines) or lines ~= I.lines then
    D.base = nil; D.baseSerial = nil; bump("w_wideLost")
    log("wide %s: %d of %s lines arrived: not compared", tostring(tag), I.lines, tostring(w[9]))
    return
  end
  local maps = {}
  if base == 0 then
    for _, spec in ipairs(WIDE) do local m = {}; for _, body in ipairs(I.sec[spec[1]] or {}) do wideParse(m, body) end; maps[spec[1]] = m end
  elseif D.base and D.baseSerial == base then
    for _, spec in ipairs(WIDE) do
      local s = spec[1]; local parts = I.sec[s]
      if parts then
        local m = {}; for k, v in pairs(D.base[s] or {}) do m[k] = v end
        for _, body in ipairs(parts) do wideParse(m, body) end
        maps[s] = m
      else maps[s] = D.base[s] or {} end                  -- nothing changed in this section: the map is shared, never written
    end
  else
    D.base = nil; D.baseSerial = nil; bump("w_wideNoBase")
    log("wide %s: the host sent changes only and this copy has no whole sample to apply them to: not compared (a whole one follows)", tostring(tag))
    return
  end
  D.base = maps; D.baseSerial = serial
  D.host[tag] = { tag = tag, sec = maps, ms = tonumber(w[10]) or 0, ticks = tonumber(w[11]) or 0, day = tonumber(w[12]) }
  if tag:sub(1, 1) == "n" then                           -- asked for on the host (W.wideNow): this copy's sample is taken now
    local ok, smp = pcall(wideSync, S, tag, S.eng:getDaysTotal())
    if ok then D.mine[tag] = smp else D.host[tag] = nil; log("wide %s failed here: %s", tag, tostring(smp)); return end
  end
  wideTry(S, tag)
end

-- ---------------------------------------------------------------- host: reads and sends
local function readTimers(S)
  local T = S.eng.TemporalComponent
  local t = { u = T.daysUntilNextRaid, s = T.daysSinceLastRaid, c = T.lastBanditCampSpawnedDay, m = T.monthsTotal, day = S.eng:getDaysTotal() }
  local ok, v = pcall(function() local D = S.eng.questDirector; if valid(D) then return D.scenario_nextActionDay end end)
  if ok then t.d = v end
  return t
end

local function sendTimers(S)
  local t = readTimers(S)
  send(string.format("W T %d %d %d %s %d %d", t.u, t.s, t.c, t.d and string.format("%d", t.d) or "-", t.m, t.day))      -- lane 36: monthsTotal and the day it was read on
end

local function sendWeather(S, changed)
  if not valid(S.eng) then return end
  local T = S.eng.TemporalComponent; local v = {}
  if not valid(T) then return end
  local exact = C.facts and C.facts.sentX == true
  for i, f in ipairs(WX) do
    if i > 10 and not exact then break end
    local x = T[f[1]]
    if f[2] == "b" then v[i] = x and "1" or "0" elseif f[2] == "i" then v[i] = string.format("%d", x) else v[i] = string.format("%.9g", x) end
  end
  local line = string.format("W X %d %s", S.eng:getDaysTotal(), table.concat(v, ","))
  if changed and W.sent.weather == line and os.clock() - (W.t.weatherSent or 0) < 1 then return end
  W.sent.weather = line; W.t.weatherSent = os.clock(); send(line)
end

-- ---------------------------------------------------------------- HOLD (lane 31): the region panel's numbers
-- Host (exact mode): per owned region one line, sent whenever any part changes (looked at 10 times a second, in
-- hostTick) and again with every keyframe:
--   W H <region key> <Approval>|<publicOrder>|<rows A>|<rows O>|<rows M>|<problems>
-- rows (A summedApprovalFactors, O summedPublicOrderFactors, M publicOrderMemory): type:past:effect:day:expires:count
-- joined by "/", "-" when empty; the effect with 9 digits (a float survives the trip exactly). problems: type:<building
-- key or ->:<u when a unit is named, else -> joined by "/", "-" when empty.
-- Friend: coop_patch.dll HOLD keeps this copy's own routines for the region from running (approval, public order, the
-- months, the wealth routines, the problem list); W.friendHold writes the host's values.
local function aT(x) local i = math.tointeger(x); if i then return string.format("%d", i) end; return string.format("%.0f", x or 0) end
local function rowsText(arr)
  local t = {}
  for i = 1, #arr do
    local m = arr[i]
    t[#t + 1] = string.format("%d:%d:%.9g:%d:%d:%d", m.Type, m.past and 1 or 0, m.effectByPopulation, m.day, m.expirationDay, m.count)
  end
  return #t > 0 and table.concat(t, "/") or "-"
end
-- a villager named by its family: f<place in the region's family list, from 0>.<place among the family's members, from
-- 1> (the realm and people modules keep both lists in the host's order); any other unit (an ox, an animal) by its role
-- and place to 10 m: r<role>@<x>,<y> (the friend takes its own unit of that role nearest to that place); "u" if neither
local function unitKey(r, u)
  local k = "u"
  pcall(function()
    local fid = math.tointeger(u.workerFamilyID) or -1
    local fams = r.workerFamilies
    if fid >= 0 and fid + 1 <= #fams then                     -- never read a game list past its end (it would grow)
      local m = fams[fid + 1].familyMembers; local ua = addr(u)
      for j = 1, #m do if addr(un(m[j])) == ua then k = string.format("f%d.%d", fid, j); break end end
    end
  end)
  if k == "u" then
    pcall(function()
      local L = u:K2_GetActorLocation()
      k = string.format("r%d@%d,%d", u.currentUnitRole, math.floor(L.X / 1000 + 0.5), math.floor(L.Y / 1000 + 0.5))
    end)
  end
  return k
end
local function unitByKey(r, k, used)
  local fid, j = k:match("^f(%d+)%.(%d+)$"); fid, j = tonumber(fid), tonumber(j)
  local hit
  if fid then
    pcall(function()
      local fams = r.workerFamilies
      if fid + 1 <= #fams then local m = fams[fid + 1].familyMembers; if j >= 1 and j <= #m then local u = un(m[j]); if valid(u) then hit = u end end end
    end)
    return hit
  end
  local role, x, y = k:match("^r(%d+)@(%-?%d+),(%-?%d+)$"); role, x, y = tonumber(role), tonumber(x), tonumber(y)
  if not role then return nil end
  W.uRole = W.uRole or {}                                    -- this copy's units of a role, looked up at most every 2 s
  local C2 = W.uRole[role]
  if not C2 or os.clock() - C2.t > 2.0 then
    C2 = { t = os.clock(), list = {} }; W.uRole[role] = C2
    pcall(function()
      local arr = W.S.eng.unitArr
      for i = 1, #arr do
        local u = un(arr[i])
        if valid(u) then local okR, ro = pcall(function() return u.currentUnitRole end); if okR and ro == role then local L = u:K2_GetActorLocation(); C2.list[#C2.list + 1] = { u = u, x = L.X, y = L.Y } end end
      end
    end)
  end
  local best, bd = nil, nil
  for _, e in ipairs(C2.list) do
    if valid(e.u) and not used[addr(e.u)] then
      local d = (e.x - x * 1000) ^ 2 + (e.y - y * 1000) ^ 2
      if not bd or d < bd then best, bd = e.u, d end
    end
  end
  return best
end
local function probKeyText(r)
  local t = {}; local arr = r.problems
  for i = 1, #arr do
    local m = arr[i]; local b, u = "-", "-"
    pcall(function() local x = m.building; if valid(x) then b = W.bkey(x) end end)
    pcall(function() local x = m.unit; if valid(x) then u = unitKey(r, x) end end)
    t[#t + 1] = string.format("%d:%s:%s", m.Type, b, u)
  end
  table.sort(t)
  return #t > 0 and table.concat(t, "/") or "-"
end
function W.holdPayload(r)
  return string.format("%d|%d|%s|%s|%s|%s", r.Approval, r.publicOrder, rowsText(r.summedApprovalFactors), rowsText(r.summedPublicOrderFactors),
    rowsText(r.publicOrderMemory), probKeyText(r))
end

-- every owned region: stock of the goods that changed, regional wealth; then the lord's numbers
-- (reads only; the replay status is on friendRegionJob)
-- (lane 47) a region's amount of a good: from the native region table (coop_snap.lua) once it was checked against
-- getStockOfGood for every good of every region; else the game's own call, as before (host passes only: the host
-- writes no totals, so this frame's table is this frame's game)
local function stockOf(r, g, reserved)
  local N = rawget(C, "snap"); local v = N and N.regionStock and N.regionStock(r, g, reserved)
  if v ~= nil then return v end
  return r:getStockOfGood(g, reserved, false)
end
-- (lane 51) A changed region total goes out only once it has held for cfg.confirm s (0.3). Every "value the host
-- never had" seen on a friend (lead27, lane 49, this lane's runs: 23 of 23 looked up) was a value the host's own
-- pass read and sent, but that the host held for one to four frames only (good 216's reserved list most often: a
-- carrier reserves what was just put down); the friend then showed it for a whole second, until the next pass.
-- Pending changes are read again (only those, a few calls) every cfg.confirmEvery s; one that went back to the
-- value sent before is dropped, one that changed again starts its wait again. A keyframe sends the value last sent
-- for a number that has such a change pending.
-- (round two) The wait has a cap: a number that keeps changing faster than every 0.3 s goes out cfg.confirmMax s
-- (1 s) after its first change, with the value it has then, once that value held 2 frames and cfg.confirmMin s.
-- From half of that on, such a number is read every frame (not every 0.05 s), so 2 frames are 2 frames.
local function pendKey(key) if type(key) == "number" then return key, false end; return tonumber(key:sub(2)), true end
local function settle(k, r, last, key, v, full, items)
  W.pend = W.pend or {}
  local P = W.pend[k]; if not P then P = {}; W.pend[k] = P end
  local was = last[key]
  if was == v then P[key] = nil; if full then items[#items + 1] = key .. "=" .. v end; return end
  -- first look: in a whole list (after a load, a new region) as it is, since the friend sets a good missing from a
  -- whole list to 0; in a pass of changes (a good first seen in mid-session, or its reserved list) it waits like any
  -- change (the host had 0 or nothing there before)
  if was == nil and full then items[#items + 1] = key .. "=" .. v; last[key] = v; P[key] = nil; return end
  if full then items[#items + 1] = key .. "=" .. was end
  local p = P[key]
  local c = os.clock()
  if not p then P[key] = { v = v, t = c, t0 = c, f = W.frameN or 0, r = r }
  elseif p.v ~= v then p.v = v; p.t = c; p.f = W.frameN or 0; p.r = r end   -- the first change's time (t0) stays
end
local function confirmTick(clock)
  local cfg = W.cfg
  W.pend = W.pend or {}
  W.frameN = (W.frameN or 0) + 1                    -- (round two) this tick's number: "held 2 frames"
  if next(W.pend) == nil then W.pendOld = nil; return end
  if clock - (W.t.pend or -1e9) < cfg.confirmEvery and not W.pendOld then return end
  W.t.pend = clock; W.pendOld = nil
  for k, P in pairs(W.pend) do
    local last = W.sent.reg[k]; local items = {}
    for key, p in pairs(P) do
      local ok, v = pcall(function() if valid(p.r) then if key == "w" then return p.r.regionalWealth end; local g, res = pendKey(key); return stockOf(p.r, g, res) end end)
      if not ok or type(v) ~= "number" or not last then P[key] = nil
      elseif v == last[key] then P[key] = nil
      elseif v ~= p.v then p.v = v; p.t = clock; p.f = W.frameN
      elseif clock - p.t >= cfg.confirm then items[#items + 1] = key .. "=" .. v; last[key] = v; P[key] = nil
      elseif clock - (p.t0 or p.t) >= cfg.confirmMax and W.frameN - (p.f or W.frameN) >= 1 and clock - p.t >= cfg.confirmMin then
        items[#items + 1] = key .. "=" .. v; last[key] = v; P[key] = nil; bump("w_confirmCap")
      end
      if P[key] and clock - (p.t0 or p.t) >= 0.5 * cfg.confirmMax then W.pendOld = true end
    end
    if #items > 0 then send(string.format("W R %s %s %s", k, k == W.homeKey and "h" or "-", table.concat(items, ","))); bump("w_confirmed", #items) end
    if next(P) == nil then W.pend[k] = nil end
  end
end
local function hostRegionJob(st)
  local S = W.S
  if not st.list then
    st.list = {}; st.i = 0
    local home = S.p1:getClosestOwnedRegion(); st.home = valid(home) and W.rkey(home) or nil; W.homeKey = st.home
    local arr = S.eng.regions
    for i = 1, #arr do local r = un(arr[i]); if valid(r) and mine(r.ownerPawn) then st.list[#st.list + 1] = r end end
    W.owned = st.list                              -- also the fire gate's region list
    -- lane 39: the rival lords' towns, in exact mode only (a friend writes their totals with TOTALS), every 2nd pass
    local Xf = rawget(C, "facts")
    st.rivals = {}
    if W.on.rivals and Xf and Xf.sentX == true and (st.key or (W.rvPass or 0) % 2 == 0) then
      local list = {}; for _, r in ipairs(W.owned) do list[#list + 1] = r end
      for _, r in ipairs(rivalList(S)) do list[#list + 1] = r; st.rivals[r] = true end
      st.list = list
    end
    W.rvPass = (W.rvPass or 0) + 1
    W.rivalsOut = (next(st.rivals) ~= nil) and true or W.rivalsOut
    return false
  end
  st.i = st.i + 1
  local r = st.list[st.i]
  if r then
    if valid(r) then
      local k = W.rkey(r); local last = W.sent.reg[k]; local full = st.key or last == nil
      if not last then last = {}; W.sent.reg[k] = last end
      if full then last.hp = nil end                 -- lane 31: the region panel's line goes out again with a keyframe
      local items = {}
      if W.on.stock then
        for _, g in ipairs(goods(S)) do
          local v = stockOf(r, g, false)
          settle(k, r, last, g, v, full, items)
        end
        -- lane 22: the totals also hold goods that are not in the tradeable list (timber 16 and others: what is
        -- carried). A friend in exact mode takes the host's totals as they are, so those are sent too: 64 good types
        -- are looked at on each pass (all of 0..511 in 8 passes), and a type once seen is sent from then on.
        local Xf = rawget(C, "facts")
        if Xf and Xf.sentX == true then
          W.extra = W.extra or {}; W.extraCur = W.extraCur or {}       -- per region: types seen, and where its look is
          local ex = W.extra[k]; if not ex then ex = {}; W.extra[k] = ex end
          local trade = W.tradeSet
          if not trade then trade = {}; for _, g in ipairs(goods(S)) do trade[g] = true end; W.tradeSet = trade end
          local cur = W.extraCur[k] or 0
          for _ = 1, 64 do
            local g = cur; cur = (cur + 1) % 512
            if not trade[g] and not ex[g] then
              local okG, v = pcall(stockOf, r, g, false)
              local okR, w = pcall(stockOf, r, g, true)   -- the list minus reserved can
              if (okG and type(v) == "number" and v ~= 0) or (okR and type(w) == "number" and w ~= 0) then ex[g] = true end   -- hold a good the totals do not (a reservation)
            end
          end
          W.extraCur[k] = cur
          for g in pairs(ex) do
            local v = stockOf(r, g, false)
            settle(k, r, last, g, v, full, items)
          end
          -- the region's second list, the totals minus what is reserved (getStockOfGood(g, true): what the top bar
          -- shows while the player's surplus view is on), sent as r<good>=<amount>
          local function res(g)
            local okR, v = pcall(stockOf, r, g, true)
            if okR and type(v) == "number" then settle(k, r, last, "r" .. g, v, full, items) end
          end
          for _, g in ipairs(goods(S)) do res(g) end
          for g in pairs(ex) do res(g) end
          -- the months of food and fuel (supplies_food / supplies_wood): the game counts them once a day from the
          -- totals (4c70030, called by updateDay); a friend's day change comes a moment after the host's, so it
          -- takes the host's numbers as they are (lane 22)
          for key, field in pairs(DERIVF) do
            local okS, v = pcall(function() return r[field] end)
            if okS and type(v) == "number" then local s = string.format("%.4f", v); if full or last[key] ~= s then items[#items + 1] = key .. "=" .. s; last[key] = s end end
          end
          if full then items[#items + 1] = "k=1" end         -- a whole list: the friend may set every other good to 0
        end
      end
      -- (lane 51, round two) the regional wealth waits like a total: l51h4, the host held 334 for 0.13 s between 367
      -- and 434 (a day's consume, then its income) and the friend showed it
      if W.on.wealth then local v = r.regionalWealth; if type(v) == "number" then settle(k, r, last, "w", v, full, items) end end
      -- lane 39: a rival's decisions the friend's copy never makes (its AI is off there): the land tax and the tithe
      -- (lt, tt) and the trade route level of each good (q<good>)
      if st.rivals and st.rivals[r] then
        for key, tn in pairs({ lt = "land", tt = "tithe" }) do
          local okT, v = pcall(function() return r:getTaxRate(FName(tn)) end)
          if okT and type(v) == "number" and (full or last[key] ~= v) then items[#items + 1] = key .. "=" .. v; last[key] = v end
        end
        -- lane 42: the days until the rival may order livestock again (his AI sets it to 30 when it orders, orderLivestock
        -- 4d47ff0 READ; the day routine counts it down on every copy): nl
        local okN, nl = pcall(function() return r.nextLivestockOrderIn end)
        if okN and type(nl) == "number" and (full or last.nl ~= nl) then items[#items + 1] = "nl=" .. nl; last.nl = nl end
        local rules = r.tradeRules; local nr = #rules              -- (read below its length only)
        for _, g in ipairs(goods(S)) do
          local okQ, v = pcall(function() return r:getTradeRouteLevel(g) end)
          local kk = "q" .. g
          if okQ and type(v) == "number" and (full or (last[kk] or 0) ~= v) then items[#items + 1] = kk .. "=" .. v; last[kk] = v end
          -- the trade rule and the target stock of each good: another region's import price on the trade screen comes
          -- from a rival that exports (rule 2 or 3) a good it holds more of than its target (getLowestImportPrice 4cc7490)
          if g + 1 <= nr then
            local okU, u = pcall(function() local x = rules[g + 1]; if type(x) ~= "number" then x = un(x) end; return tonumber(x) end)
            kk = "u" .. g
            if okU and type(u) == "number" and (full or (last[kk] or 0) ~= u) then items[#items + 1] = kk .. "=" .. u; last[kk] = u end
          end
          local okV, tv = pcall(function() return r:GetTargetInventory(g) end)
          kk = "v" .. g
          if okV and type(tv) == "number" and (full or (last[kk] or 0) ~= tv) then items[#items + 1] = kk .. "=" .. tv; last[kk] = tv end
        end
      end
      if #items > 0 then sendList(string.format("W R %s %s ", k, k == st.home and "h" or "-"), items, ",") end
    end
    return false
  end
  local L = W.sent.lord; local p = S.p1; local items = {}
  if W.on.silver then local v = p.silver; if st.key or L.s ~= v then items[#items + 1] = "s=" .. v; L.s = v end end
  if W.on.lordExtra then
    local v = p.influence; if st.key or L.i ~= v then items[#items + 1] = "i=" .. v; L.i = v end
    v = p.kingsFavour; if st.key or L.f ~= v then items[#items + 1] = "f=" .. v; L.f = v end
  end
  if #items > 0 then send("W L " .. table.concat(items, ",")) end
  return true
end

-- the lord's storage buildings and construction sites, one building per step; sends changes only
local function hostBldJob(st)
  local S = W.S; local arr = S.eng.buildingArr
  st.new = st.new or {}; st.i = (st.i or 0) + 1
  if st.i <= #arr then
    local b = un(arr[st.i])
    if valid(b) and mine(b.ownerPawn) then
      local keep = not b:IsConstructed()
      if not keep then local ok, s = pcall(function() return b:isStorageTypeBuilding() end); keep = ok and s == true end
      if keep then st.new[W.bkey(b)] = invOf(b) end
    end
    return false
  end
  local old = W.sent.bld; local entries = {}
  for k, inv in pairs(st.new) do
    local o = old[k]; local full = st.key or o == nil; local items = {}
    for g, a in pairs(inv) do if full or o[g] ~= a then items[#items + 1] = g .. "=" .. a end end
    if not full then for g in pairs(o) do if inv[g] == nil then items[#items + 1] = g .. "=0" end end end
    if full then entries[#entries + 1] = k .. "!|" .. table.concat(items, ",")
    elseif #items > 0 then entries[#entries + 1] = k .. "|" .. table.concat(items, ",") end
  end
  for k in pairs(old) do if not st.new[k] then entries[#entries + 1] = k .. "-" end end   -- finished site, demolished store
  W.sent.bld = st.new
  sendList("W B ", entries, ";")
  return true
end

-- the lord's burning buildings (b.onFire, reflected: dumps/SMBuildingMaster.txt); started only when a region says so
-- A building can also become a ruin without ever being seen burning: this scan used to run only while a region said
-- "a building is on fire", every 2 s. Lane 5 saw it twice: the cheat manager's fire left a ruined market stall on the
-- host within 8 s at speed 4 (session 3), and brigands raiding the town ruined the same kind of stall (session 7);
-- no fire message went out, the friend kept the stall, and the daily comparison asked for a resync ("B"). So the
-- scan also runs every 6 s without a fire and remembers the lord's ruins; a new ruin that was not in the burning
-- list is told as a fire that ended "burnt" (the friend lights its building and burns it down at once).
-- (Taken out for sessions 5 to 7 after a host crash in session 4. The host crashes of this lane, four in all, are not
-- explained: see the lane 5 report. The watch ran on the host in sessions 9 to 11 without one.)
local function hostFireJob(st)
  local arr = W.S.eng.buildingArr
  st.now = st.now or {}; st.ruins = st.ruins or {}; st.i = (st.i or 0) + 1
  if st.i <= #arr then
    local b = un(arr[st.i])
    if valid(b) and mine(b.ownerPawn) then
      if b.onFire then st.now[W.bkey(b)] = b
      else
        local ruin = false
        pcall(function() ruin = b:GetType() == 75 and b:IsRubble() and true or false end)   -- 75 = debris (lane_f)
        if ruin then st.ruins[W.bkey(b)] = true end
      end
    end
    return false
  end
  -- (lane 64) the word that a fire ended goes out AFTER a look at the families (as before a DEMOLISH line, lane 39): the
  -- host's game houses the family of a burnt house in the frame of the burn-down, so a friend reads the new homes
  -- first and its own burn-down finds the house empty. (A friend does not depend on this order: E.homesNow.)
  local flushed = false
  local function familiesFirst()
    if flushed then return end
    flushed = true
    local Pp = rawget(C, "people"); if Pp and Pp.flushGrow then pcall(Pp.flushGrow) end
  end
  if W.ruins then
    for k in pairs(st.ruins) do
      if not W.ruins[k] and not W.fires[k] then familiesFirst(); send("W E FIREOUT " .. k .. " BURNT"); bump("w_ruinTold"); log("a building fell to ruin on the host with no fire seen: %s", k) end
    end
  end
  W.ruins = st.ruins
  for k in pairs(st.now) do if not W.fires[k] then send("W E FIRE " .. k); log("fire on the host: %s", k) end end
  for k, b in pairs(W.fires) do
    if not st.now[k] then
      -- how it ended: a ruin (burnt down) or the old building as an unfinished site (put out) (lane_f Q2)
      local how = "OUT"
      if type(b) ~= "boolean" and valid(b) then pcall(function() if b:IsRubble() then how = "BURNT" end end) else how = "GONE" end
      familiesFirst()
      send("W E FIREOUT " .. k .. " " .. how); log("fire ended on the host: %s (%s)", k, how)
    end
  end
  W.fires = st.now
  return true
end

-- events seen by polling named values (no hooks: the daily code runs natively, lane_w report "HOW THE DAY RUNS")
local function hostEvents(S)
  local ok, t = pcall(readTimers, S)
  if ok then
    local L = W.ev
    if L then
      if t.s < L.s or t.u > L.u then send(string.format("W E RAID %d %d", t.u, t.s)); log("raid on the host (next in %d days)", t.u) end
      if t.c ~= L.c then send(string.format("W E CAMP %d", t.c)); log("bandit camp on the host (day %d)", t.c) end
      if t.d and L.d and t.d ~= L.d then send(string.format("W E DIRECTOR %d", t.d)); log("scenario director acted on the host") end
    end
    W.ev = t
  else try("timers", error, t) end
  local okM, f, l = pcall(function() return #S.eng.freeMerchants, #S.eng.livestockMerchants end)
  if okM then
    if W.merch and f > W.merch.f then send(string.format("W E MERCH %d %d", f, l)) end
    W.merch = { f = f, l = l }
  end
  local fire = next(W.fires) ~= nil
  if not fire and W.owned then
    for _, r in ipairs(W.owned) do if valid(r) then local okF, v = pcall(function() return r.bAnyBuildingOnFire end); if okF and v then fire = true end end end
  end
  local since = os.clock() - W.t.fire
  if (fire and since >= W.cfg.fireEvery) or since >= 6.0 then W.t.fire = os.clock(); addJob("hostFire", hostFireJob, {}) end
end

local function onHostDay(S, day)
  local ok, clk = pcall(function() return S.eng.TemporalComponent:getTotalDaysAndHours() end)
  send(string.format("W D %d %s", day, ok and string.format("%.4f", clk) or "-"))
  try("timers", sendTimers, S)
  if W.on.weather then try("weather", sendWeather, S) end
  if W.on.fp then addJob("fp", fpJob, { done = function(d, P) Check.remember(W.wd.fpSamples, tostring(d), P); send("W F " .. d .. " " .. fpEncode(P)) end }) end
  if W.on.wide then                                              -- log only
    wideStart(S, tostring(day), day, function(smp) local D = W.wd; D.posts[#D.posts + 1] = { kind = "send", smp = smp, i = 0, lines = 0, bytes = 0 } end)
  end
end

local function hostPoll(S)
  local day = S.eng:getDaysTotal()
  if W.day == nil then W.day = day elseif day ~= W.day then W.day = day; onHostDay(S, day) end
  if W.on.events then hostEvents(S) end
end

local function hostTick(S, clock)
  local cfg = W.cfg
  if clock - W.t.poll >= cfg.pollEvery then W.t.poll = clock; try("hostPoll", hostPoll, S) end
  -- the treasury is pushed at once when it changes (at most 10 times a second), not with the 2 s stock push: a friend's
  -- copy uses it to refuse what the lord cannot pay for, so a stale number is what lets two players spend the same silver
  if W.on.silver and clock - (W.t.silverFast or 0) >= 0.1 then
    local okS, v = pcall(function() return S.p1.silver end)
    if okS and type(v) == "number" and W.sent.lord.s ~= nil and W.sent.lord.s ~= v then
      W.t.silverFast = clock; W.sent.lord.s = v; send("W L s=" .. v); bump("w_silverFast")
    end
  end
  -- exact mode (the facts module says "F X 1"): a friend's region totals are this host's, written as they arrive
  -- (lane 22, TOTALS), so they are read and sent every cfg.exactStockEvery s instead of every cfg.stockEvery s
  local every = cfg.stockEvery
  local Xf = rawget(C, "facts"); if Xf and Xf.sentX == true and cfg.exactStockEvery then every = math.min(every, cfg.exactStockEvery) end
  if Xf and Xf.sentX == true and W.on.weather and clock - (W.t.weatherRead or 0) >= 0.2 then
    W.t.weatherRead = clock; try("weather", sendWeather, S, true)
  end
  -- exact mode: the months of food and fuel and the regional wealth are pushed at once when they change (looked at 10
  -- times a second): the game writes the months in its day routine, and a friend's day comes a moment after the
  -- host's, so the host's new value must be there before the friend's own one is shown (lane 22)
  if Xf and Xf.sentX == true and W.owned and clock - (W.t.derivFast or 0) >= 0.1 then
    W.t.derivFast = clock
    local regs = W.owned
    if W.on.rivals and W.rivalsOut then          -- lane 39: the rival towns too, once their first region line went out
      regs = {}; for _, r in ipairs(W.owned) do regs[#regs + 1] = r end
      for _, r in ipairs(rivalList(S)) do regs[#regs + 1] = r end
    end
    for _, r in ipairs(regs) do
      if valid(r) then
        local k = W.rkey(r); local last = W.sent.reg[k]
        if last then
          local items = {}
          for key, field in pairs(DERIVF) do
            local okS, v = pcall(function() return r[field] end)
            if okS and type(v) == "number" then local s = string.format("%.4f", v); if last[key] ~= nil and last[key] ~= s then items[#items + 1] = key .. "=" .. s; last[key] = s end end
          end
          if W.on.wealth then local okW, v = pcall(function() return r.regionalWealth end); if okW and type(v) == "number" and last.w ~= nil and last.w ~= v then settle(k, r, last, "w", v, false, items) end end   -- (lane 51) held like a total
          if #items > 0 then send(string.format("W R %s %s %s", k, k == W.homeKey and "h" or "-", table.concat(items, ","))); bump("w_derivFast") end
          -- lane 31: approval, public order, their factor lists and the problems, at once on a change
          -- (lane 45) the panel's lists twice a second, not ten times: reading them is the dear part of this look
          -- (factor rows and problems of every region: world:rowsText was among the dearest functions of b0); the
          -- owner's window for what players see is 3 s
          if W.on.hold and clock - (last.hpT or -1e9) >= 0.5 then
            last.hpT = clock
            local okP, pay = pcall(W.holdPayload, r)
            if okP and type(pay) == "string" and last.hp ~= pay then last.hp = pay; send(string.format("W H %s %s", k, pay)); bump("w_holdSent") end
          end
        end
      end
    end
  end
  try("confirm", confirmTick, clock)                -- (lane 51) region totals that held long enough go out
  if (W.on.stock or W.on.silver or W.on.wealth or W.on.lordExtra) and clock - W.t.stock >= every then
    local key = clock - W.t.key >= cfg.keyEvery
    if addJob("hostRegions", hostRegionJob, { key = key }) then
      W.t.stock = clock
      if key then W.t.key = clock; try("timers", sendTimers, S); if W.on.weather then try("weather", sendWeather, S) end end
    end
  end
  if W.on.bstock and clock - W.t.bld >= cfg.bldEvery then
    local key = clock - W.t.bkey >= cfg.bldKeyEvery
    if addJob("hostBld", hostBldJob, { key = key }) then W.t.bld = clock; if key then W.t.bkey = clock end end
  end
end

-- ---------------------------------------------------------------- friend: apply the host's values
-- status: proven live (README session 9) for the home region: grantResources / consumeGood with eng.buildingArr[1],
-- regionalWealth and silver written directly. Every region the lord owns is corrected, each by its tag (two owned regions: lane 5 session 8).
-- influence / kingsFavour writes: not run live (item lordExtra).
-- (lane 51 round two, lane 55's item 3, from lane 10's report section 7) the friend's region rule (only when exact
-- mode is not possible: the native piece unavailable or switched off, or a host that stopped saying "F X 1"):
--   - an animal is a good to the region's count, but the facts module makes or removes the animal itself; granting or
--     consuming it here made a stray item "42 x1" in a storehouse, or failed every second (lane 10, 7b). A good is an
--     animal when the engine's getAnimalRoleFromGoodType gives it another role than planks (17, no animal);
--   - a grant goes into the region's storage building of the lord that holds most of that good (the game's
--     grantResources put planks and logs into a small stable, lane 10, 7a); grantResources only when no storage
--     building holds any of it (a storage building that never held the good may not be its kind: planks in a granary);
--   - a removal takes from the lord's building of the region that holds most of the good; a good counted by the
--     region but held by none of the lord's buildings (237, a felled tree with branches: lead22, 23, 25 "237:-11")
--     is left to the game: the removal could only fail.
local function animalGood(S, g)
  W.animal = W.animal or {}
  local a = W.animal[g]; if a ~= nil then return a end
  local ok, role = pcall(function() return S.eng:getAnimalRoleFromGoodType(g) end)
  local ok0, none = pcall(function() return S.eng:getAnimalRoleFromGoodType(17) end)
  if not (ok and ok0) or role == nil then return false end      -- (not kept: asked again next time)
  a = role ~= none; W.animal[g] = a
  return a
end
local function holders(S, r, g)                 -- the storage building with most of g, and the building with most of g
  local arr = S.eng.buildingArr; local ra = addr(r); local store, sn, best, bn
  for i = 1, #arr do
    local b = un(arr[i])
    if valid(b) then
      local ok, same = pcall(function() return mine(b.ownerPawn) and addr(b.Region) == ra end)
      if ok and same then
        local okI, m = pcall(invOf, b); local n = (okI and m[g]) or 0
        local okS, isS = pcall(function() return b:isStorageTypeBuilding() end)
        if okS and isS == true and n > 0 and (not sn or n > sn) then store, sn = b, n end   -- one that holds it already
        if n > 0 and (not bn or n > bn) then best, bn = b, n end
      end
    end
  end
  return store, best
end

local function friendRegionJob(st)
  local S = W.S; local F = W.fr
  if not st.keys then
    st.keys = {}; for k in pairs(F.reg) do st.keys[#st.keys + 1] = k end
    table.sort(st.keys); st.i = 0
    return false
  end
  st.i = st.i + 1
  local k = st.keys[st.i]
  if k then
    local R = F.reg[k]
    if R then                                        -- every region the host's lord owns, by its tag (not only "home")
      local r = W.regionByKey(k)
      if not r then bump("w_noRegion"); return false end
      local rival = false
      if not mine(r.ownerPawn) then
        -- lane 39: a rival's town is taken only in exact mode with TOTALS (its totals as they are); the grant / consume
        -- rule below never touches another lord's region
        local Pt0 = rawget(C, "patch")
        if not (W.on.rivals and exactStock() and Pt0 and Pt0.tOn and rivalTown(r)) then bump("w_notOurRegion"); return false end
        rival = true
      end
      local up, down, failed, kept = 0, 0, 0, 0
      local det = {}                               -- which goods (the first few), so a log shows what keeps moving
      -- Exact mode: a region's total is the stock of its buildings plus what its people carry. The buildings are
      -- exact and held natively; a grant or a consume here would be put back at once, for ever. What is left
      -- differing is what is in hands on the two copies.
      -- Exact mode with TOTALS (lane 22): the region's totals change only on the host's word (coop_patch.dll keeps
      -- the game's own changes in a shadow), so the host's totals are written as they are, with the game's own
      -- routine, whenever one differs here. The grant / consume rule below would move buildings: not used then.
      local Pt = rawget(C, "patch")
      if W.on.stock and exactStock() and Pt and Pt.tOn and Pt.totalsSet and next(R.g) ~= nil then
        -- (lane 45) the region's totals are read and compared only when the host's list changed since the last
        -- look, and at least every 0.5 s (TOTALS keeps them otherwise; its own audit runs every 5 s): the W R lines
        -- that bring only the months or the wealth (ten a second) made a whole comparison each (b0: friendRegionJob).
        -- (2 s at first: a total that moved on this copy by itself - good 216 - then waited up to 4 to 5 s, sittings
        -- a1, a2, p1; the lead's check looks back 2 s)
        local due = R.gvSeen ~= R.gv or os.clock() - (R.cmpT or -1e9) >= 0.5
        if due then R.gvSeen = R.gv; R.cmpT = os.clock() end
        local diff = 0
        if due then for g, want in pairs(R.g) do
          local okG, v = pcall(function() return r:getStockOfGood(g, false, false) end)
          if not okG or v ~= want then diff = diff + 1; if #det < 6 then det[#det + 1] = string.format("%d:%s>%d", g, tostring(v), want) end end
        end end
        if diff > 0 or R.tracked ~= Pt.tGen or (R.full and R.allDone ~= Pt.tGen) then
          local ok, msg = Pt.totalsSet(r, R.g, R.full == true)   -- after the host's whole list: every other good is 0
          if ok then R.tracked = Pt.tGen; if R.full then R.allDone = Pt.tGen end; bump("w_totalsSet"); bump("w_totalsGoods", diff) else bump("w_totalsRefused"); log("totals %s: not written (%s)", k, tostring(msg)) end
        end
        -- the second list, the totals minus what is reserved (what the top bar shows in the surplus view)
        if R.gr and next(R.gr) ~= nil then
          local diffR = 0
          if due then for g, want in pairs(R.gr) do
            local okG, v = pcall(function() return r:getStockOfGood(g, true, false) end)
            if not okG or v ~= want then diffR = diffR + 1 end
          end end
          if diffR > 0 or R.trackedR ~= Pt.tGen or (R.full and R.allDoneR ~= Pt.tGen) then
            local ok, msg = Pt.totalsSet(r, R.gr, R.full == true, true)
            if ok then R.trackedR = Pt.tGen; if R.full then R.allDoneR = Pt.tGen end; bump("w_totalsSetR"); bump("w_totalsGoodsR", diffR) end
          end
        end
        -- the months of food and fuel the game counts from the totals once a day: the host's (reflected floats; the
        -- game writes them only in its day routine, so a write stays until the next day)
        for key, field in pairs(DERIVF) do
          local want = R[key]
          if want then
            local okS, v = pcall(function() return r[field] end)
            if okS and type(v) == "number" and math.abs(v - want) > 1e-4 then
              if act(string.format("%s %s %.4f", field, k, want), function() r[field] = want end) then bump("w_suppliesSet") end
            end
          end
        end
      end
      if rival and R.decDirty then                   -- lane 39: the rival's own decisions, as the host's (when a line named one)
        R.decDirty = false
        for key, tn in pairs({ lt = "land", tt = "tithe" }) do
          local want = R[key]
          if want then
            local okT, v = pcall(function() return r:getTaxRate(FName(tn)) end)
            if okT and v ~= want and act(string.format("%s tax %s %d", tn, k, want), function() r:changeTaxRate(FName(tn), want) end) then bump("w_rivalTax") end
          end
        end
        if R.nl then                                     -- lane 42: the rival's livestock order wait (a plain value)
          local okN, v = pcall(function() return r.nextLivestockOrderIn end)
          if okN and v ~= R.nl and act(string.format("livestock wait %s %d", k, R.nl), function() r.nextLivestockOrderIn = R.nl end) then bump("w_rivalLiveWait") end
        end
        for g, want in pairs(R.q or {}) do
          local okQ, v = pcall(function() return r:getTradeRouteLevel(g) end)
          if okQ and v ~= want and act(string.format("route %s good %d %d", k, g, want), function() r:setTradeRouteLevelForGood(g, want) end) then bump("w_rivalRoute") end
        end
        local rules = r.tradeRules; local nr = #rules
        for g, want in pairs(R.u or {}) do
          if g + 1 <= nr then
            local okU, u = pcall(function() local x = rules[g + 1]; if type(x) ~= "number" then x = un(x) end; return tonumber(x) end)
            if okU and u ~= want and act(string.format("trade rule %s good %d %d", k, g, want), function() r:changeTradeRule(g, want) end) then bump("w_rivalRule") end
          end
        end
        for g, want in pairs(R.v or {}) do
          local okV, tv = pcall(function() return r:GetTargetInventory(g) end)
          if okV and tv ~= want and act(string.format("target %s good %d %d", k, g, want), function() r:changeTargetInventory(g, want) end) then bump("w_rivalTarget") end
        end
      end
      if W.on.stock and not exactStock() and not rival then
        local trade = W.tradeSetF
        if not trade then trade = {}; for _, g0 in ipairs(goods(S)) do trade[g0] = true end; W.tradeSetF = trade end
        for g, want in pairs(R.g) do
          -- (lane 51) animals: the facts module; a good outside the tradeable list (timber 16, 218, 228, 237, 257: the
          -- host sends them for exact mode) is mostly in carriers' hands: a grant only churned (g4: +16 timber a pass)
          local d = (animalGood(S, g) or not trade[g]) and 0 or (want - r:getStockOfGood(g, false, false))
          if d ~= 0 and #det < 6 then det[#det + 1] = string.format("%d:%+d", g, d) end
          if d > 0 then
            local store = holders(S, r, g)           -- (lane 51) into the storage building with most of it
            if valid(store) then
              if act(string.format("store %s good %d +%d", k, g, d), function() store:addToInventory({ Type = g, amt = d }) end) then up = up + d; bump("w_stockStored", d) end
            elseif act(string.format("grant %s good %d +%d", k, g, d), function() r:grantResources({ { Type = g, amt = d } }, false) end) then up = up + d end
          elseif d < 0 then
            local _, pref = holders(S, r, g)         -- (lane 51) the lord's building of THIS region with most of it
            if not valid(pref) then bump("w_stockNotHeld"); kept = kept + 1   -- in none of the lord's buildings (237): left
            else
              local res
              local ok = act(string.format("consume %s good %d %d", k, g, d), function() res = r:consumeGood(g, -d, pref, false, false, false) end)
              if ok and res ~= false then down = down - d else failed = failed + 1 end
            end
          end
        end
      end
      if W.on.wealth and R.w and r.regionalWealth ~= R.w then act("wealth " .. k .. " " .. R.w, function() r.regionalWealth = R.w end) end
      if up + down + failed > 0 then bump("w_stockFix"); bump("w_stockUnits", up + down); log("stock %s: added %d removed %d failed %d, in no building %d (%s)", k, up, down, failed, kept, table.concat(det, " ")) end
    end
    return false
  end
  local L = F.lord; local p = S.p1
  -- The lord's numbers at the top right are drawn when the game announces a change, not when the value is written
  -- (session 21: after a refused hire the treasury was right, 285, and the screen still said 270). After a correction
  -- the game's own "stats changed" event of that panel is run, which redraws it from the values.
  local redraw = false
  if W.on.silver and L.s and p.silver ~= L.s then act("silver " .. L.s, function() p.silver = L.s end); bump("w_silverFix"); redraw = true end
  if W.on.lordExtra then
    if L.i and p.influence ~= L.i then act("influence " .. L.i, function() p.influence = L.i end); redraw = true end
    if L.f and p.kingsFavour ~= L.f then act("favour " .. L.f, function() p.kingsFavour = L.f end); redraw = true end
  end
  if redraw then
    pcall(function()
      for _, w in ipairs(FindAllOf("W_HUD_LordPanel_V2_C") or {}) do
        if A.valid(w) then pcall(function() w:OnStatUpdateRequested_Event() end) end
      end
    end)
  end
  return true
end

-- status: proven live on one copy (README session 14): addToInventory +1/-1 on a storage building moves the building
-- and the region total; on a construction site it moves progress and can be taken back. Not yet run with two copies:
-- whether the friend's builders then finish the site at the same time (lane_w W2b) is untested.
--
-- Two rules pull on the same goods: the region's total of each good (friendRegionJob) and what each storage building
-- holds (this job). They cannot both be exact, because the goods outside the storage buildings (being carried, in
-- homes and workshops) differ between two copies. Lane 5 measured the result on two idle copies: every 2 s this job
-- took out what the region pass had just put in ("added 5 removed 0" for minutes; 9566 units added and 8479 removed
-- in 12 minutes), and one daily comparison failed on stock. So:
--   a construction site is made exact (its goods are progress, and the daily comparison reads them);
--   among finished storage buildings goods are only MOVED: for each good, as much is added to the buildings that are
--   short as is taken from the buildings that hold too much. The region's total is left to the region pass alone.
local function friendBldJob(st)
  local F = W.fr
  if not st.keys then
    st.keys = {}; local src = st.all and F.bld or F.bdirty
    for k in pairs(src) do st.keys[#st.keys + 1] = k end
    F.bdirty = {}; st.i = 0; st.plan = {}
    return false
  end
  if not st.ops then
    st.i = st.i + 1
    local k = st.keys[st.i]
    if not k then                                   -- every building read: plan the moves, good by good
      st.ops = {}; st.j = 0
      for _, P in pairs(st.plan) do                 -- one plan per region and good: goods never move between regions
        local m = math.min(P.up, P.down)
        if m > 0 then
          for _, side in ipairs({ { P.plus, 1 }, { P.minus, -1 } }) do
            local left = m
            for _, e in ipairs(side[1]) do
              if left <= 0 then break end
              local d = math.min(e.d, left); left = left - d
              st.ops[#st.ops + 1] = { b = e.b, k = e.k, g = P.g, d = d * side[2] }
            end
          end
        end
        if P.up ~= P.down then bump("w_bldLeft", math.abs(P.up - P.down)) end
      end
      return false
    end
    local E = F.bld[k]; if not E then return false end
    local b = W.buildingByKey(k)
    if not b then bump("w_noBuilding"); return false end
    local site = false
    pcall(function() site = not b:IsConstructed() and not (b.isBeingUpgraded and true or false) end)
    local inv = invOf(b); local n = 0
    local reg = "?"; pcall(function() reg = tostring(addr(b.Region)) end)
    local function fix(g, d)
      if site then act(string.format("site %s good %d %+d", k, g, d), function() b:addToInventory({ Type = g, amt = d }) end); n = n + 1; return end
      local pk = reg .. "|" .. g
      local P = st.plan[pk]; if not P then P = { g = g, up = 0, down = 0, plus = {}, minus = {} }; st.plan[pk] = P end
      if d > 0 then P.up = P.up + d; P.plus[#P.plus + 1] = { b = b, k = k, d = d }
      else P.down = P.down - d; P.minus[#P.minus + 1] = { b = b, k = k, d = -d } end
    end
    for g, want in pairs(E.g) do local d = want - (inv[g] or 0); if d ~= 0 then fix(g, d) end end
    if E.full then for g, have in pairs(inv) do if E.g[g] == nil and have ~= 0 then fix(g, -have) end end end
    if n > 0 then bump("w_bldFix", n) end
    return false
  end
  st.j = st.j + 1
  local op = st.ops[st.j]
  if not op then F.dirty = true; return true end   -- the region pass follows the per-building pass (lane_w W2a risk note)
  if valid(op.b) then
    act(string.format("building %s good %d %+d", op.k, op.g, op.d), function() op.b:addToInventory({ Type = op.g, amt = op.d }) end)
    bump("w_bldMove")
  end
  return false
end

-- Fires on a friend's copy follow the host (lane_f). The host says when a building catches fire and how the fire ended.
--   FIRE k          light the same building here (b:StartFire(), the game's own; it does nothing if already burning)
--   FIREOUT k BURNT burn it down here now (native progressFire through coop_patch); lit first if it never burnt here
--   FIREOUT k OUT   put it out here now (native extinguishFire); the building is then an unfinished site, as on the host
-- Both native calls wait until the building's change to the "debris" type has landed (it can take a few frames).
--   status: start mirrored and both endings: see README session 20
local function friendFireJob(st)
  local F = W.fr
  if not st.keys then st.keys = {}; for k in pairs(F.firePend) do st.keys[#st.keys + 1] = k end; st.i = 0; return false end
  st.i = st.i + 1
  local k = st.keys[st.i]; if not k then return true end
  local P = F.firePend[k]; if not P then return false end
  local b = W.buildingByKey(k)
  if not b then F.firePend[k] = nil; bump("w_noBuilding"); log("fire %s: no building with that name here", k); return false end
  local burning = b.onFire and true or false
  local rubble = false; pcall(function() rubble = b:IsRubble() and true or false end)
  local function light()
    if not valid(b.Region) then log("fire %s: the building has no region here: not lit", k); return false end
    act("StartFire " .. k, function() b:StartFire() end); log("fire started here to match the host: %s", k)
    return true
  end
  if P.what == "on" then
    F.firePend[k] = nil
    if not W.on.fire or burning or rubble then return false end
    light()
    return false
  end
  if not W.on.fireOut then F.firePend[k] = nil; return false end
  P.t = P.t or os.clock()
  if os.clock() - P.t > 15.0 then F.firePend[k] = nil; log("fire %s: could not be ended here within 15 s (%s)", k, P.what); return false end
  if P.what == "burnt" then
    if not burning then
      if rubble then F.firePend[k] = nil; return false end              -- already a ruin here
      if not P.lit then P.lit = true; if not light() then F.firePend[k] = nil end end
      return false                                                       -- next pass burns it down
    end
  elseif not burning then F.firePend[k] = nil; return false end          -- "out", and not burning here: nothing to do
  if not rubble then return false end                                    -- the type change has not landed yet: next pass
  F.firePend[k] = nil
  local Pt = C.patch
  if not (Pt and Pt.fn and Pt.burn) then log("fire %s ended on the host (%s) but the native piece is not loaded: it keeps burning here", k, P.what); return false end
  local ok, done, msg = pcall(P.what == "burnt" and Pt.burn or Pt.fireout, b)
  if ok and done then bump("w_fireEnded"); log("fire %s ended here as on the host: %s", k, P.what == "burnt" and "burnt down" or "put out")
    -- (lane 64, lane 66's run 4) the game's burn-down puts every family of the house out (progressFire, READ) and this
    -- copy houses nobody by itself: the families get the host's homes now, in this tick (coop_x_events.lua, E.homesNow).
    -- The host's word of the burn-down can come seconds after the growth line that moved a family INTO the house.
    local Ev = rawget(C, "events")
    if Ev and Ev.homesNow then pcall(Ev.homesNow, (P.what == "burnt" and "the burn-down of " or "the put-out of ") .. k) end
  else
    log("fire %s could not be ended here (%s): %s", k, P.what, tostring(ok and msg or done))
    if P.what == "out" then F.ownStop = true end   -- the native put-out failed: no more put-outs of this copy's own fires in this world
  end
  return false
end

-- A friend's copy does not run fires of its own: its fire clock (the engine's 1 s "propagation" timer, which is the
-- only thing that makes a fire grow, spread and burn stock) is paused after every load, its villagers are not sent
-- for water (the region's "a building is on fire" flag is held off), and damaging lightning is held off. Fires start
-- and end only when the host says so (lane_f Q4).
local function firePassive(S)
  if not W.on.fire then return end
  if W.firePausedFor ~= S.worlds then
    W.firePausedFor = S.worlds
    local ok, was = pcall(function()
      local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
      local active = KSL:K2_IsTimerActiveHandle(S.eng, S.eng.propagationHandle)
      if active then KSL:K2_PauseTimerHandle(S.eng, S.eng.propagationHandle) end
      return active
    end)
    log("fire: this copy's own fire clock %s", ok and (was and "paused" or "was not running") or ("could not be paused: " .. tostring(was)))
  end
  local arr = S.eng.regions
  for i = 1, #arr do local r = un(arr[i]); if valid(r) then pcall(function() if r.bAnyBuildingOnFire then r.bAnyBuildingOnFire = false end end) end end
  pcall(function() local T = S.eng.TemporalComponent; if T.damagingRain then T.damagingRain = false end end)
end

-- A fire the host does not have. The brigands on a friend's copy are stand-ins that follow the host's groups, but
-- their men still throw torches by themselves, at buildings of their own choosing (lane 5 sessions 3 and 9: after a
-- raid the friend had two and then five buildings burning that never burnt on the host). With the fire clock paused
-- such a fire never ends, the building lists differ day after day, and the daily comparison asks for a resync.
-- The host's burning buildings are known from its FIRE / FIREOUT lines; one of this lord's buildings that burns here
-- for 12 s without being on that list is put out the way a host fire that was put out is (FIREOUT ... OUT).
-- Session 10: 26 such fires were put out during one raid (each building is then an unfinished site and the sites
-- rule finishes it); then one put-out raised an exception inside the game's routine (the native piece caught it and
-- switched its put-out off), and five fires stayed. The three calls it can have been were second put-outs of the
-- same building, or a building that had burnt on the host before. So: once per building and world, never a building
-- that had a host fire in this world, and the rule stops for this world when the native put-out reports a failure
-- (friendFireJob). Session 11 with the first two limits: 12 put out, no exception. A building lit again after its
-- put-out stays burning here (not put out twice), so a long raid can still end with a few such fires and a resync.
-- The cause itself, the stand-ins' torches, needs a switch in the native piece.
-- (The stop on a failed native put-out was written after the last session and has not run.)
local function friendOwnFireJob(st)
  local F = W.fr; local arr = W.S.eng.buildingArr
  if F.ownStop then return true end
  st.seen = st.seen or {}; st.i = (st.i or 0) + 1
  if st.i <= #arr then
    local b = un(arr[st.i])
    if valid(b) and b.onFire and mine(b.ownerPawn) then
      local ok, k = pcall(W.bkey, b)
      if ok and not F.hostFires[k] and not F.firePend[k] then
        if not F.ownOut[k] and not F.hadHostFire[k] then
          st.seen[k] = true
          F.ownFire[k] = F.ownFire[k] or os.clock()
          if os.clock() - F.ownFire[k] >= 12.0 then
            F.ownFire[k] = nil; F.ownOut[k] = os.clock(); F.firePend[k] = { what = "out" }; bump("w_ownFireOut")
            log("fire %s burns here but not on the host: put out here", k)
          end
        end
      end
    end
    return false
  end
  for k in pairs(F.ownFire) do if not st.seen[k] then F.ownFire[k] = nil end end
  return true
end

-- status: static read only (lane_w W4f): the per-frame weather update only moves current values toward these targets
-- (READ); that a write takes effect is a GUESS. A write that does not stick switches the item off.
local function weatherApply(S)
  local X = W.fr.wx; if not (X and W.on.weather) then return end
  if not valid(S.eng) then return end
  local T = S.eng.TemporalComponent; local n = 0
  if not valid(T) then return end
  for i, f in ipairs(WX) do
    local want = X.v[i]
    if want ~= nil then
      local name, kind = f[1], f[2]
      if kind == "b" then want = want == 1 end
      local cur = T[name]
      local same = cur == want or (kind == "f" and string.format("%.9g", cur) == string.format("%.9g", want))
      if not same then
        if W.dry then W.dryLog[#W.dryLog + 1] = "weather " .. name .. "=" .. tostring(want)
        else
          local ok, e = pcall(function() T[name] = want end)
          local back = ok and T[name]
          local stuck = ok and ((kind == "f" and math.abs(back - want) < 1e-3) or (kind ~= "f" and back == want))
          if not stuck then W.on.weather = false; log("item weather switched off: %s did not take %s (%s)", name, tostring(want), ok and tostring(back) or tostring(e)); return end
          n = n + 1
        end
      end
    end
  end
  if n > 0 then bump("w_weather", n) end
end

-- the friend's own daily roll may overwrite the targets after the host's message: keep them for the whole day
local function weatherKeep(S)
  local X = W.fr.wx
  if X and W.on.weather and S.eng:getDaysTotal() == X.day then weatherApply(S) end
end

-- write one held value; if it cannot be read or does not stick, switch the item off (and say so) instead of retrying
local function hold(item, read, want, write)
  local ok, cur = pcall(read)
  if not ok then W.on[item] = false; log("item %s switched off: cannot read (%s)", item, tostring(cur)); return end
  if want == nil or cur == want then return end
  if W.dry then W.dryLog[#W.dryLog + 1] = item .. " " .. tostring(cur) .. "->" .. tostring(want); return end
  local okW, e = pcall(write, want)
  local okR, back = pcall(read)
  if not okW or not okR or back ~= want then
    W.on[item] = false; log("item %s switched off: the write did not stick (%s)", item, okW and tostring(back) or tostring(e)); return
  end
  bump("w_hold_" .. item)
end

-- hold the friend's own random events off; called every second, so a new world is covered within a second of loading
-- status: raid and camp timer writes proven live on one copy (README session 14); that holding them stops the friend's
-- own raid / camp over days is lane_w W4a/W4b READ, not yet run. Director (W4c) and merchants (W4g): static read only.
-- ignoreRaiders: the drawDebugFlags append is proven live (session 14, and the core's disableAI); its effect is READ only.
local function holds(S)
  local eng = S.eng; local T = eng.TemporalComponent; local Ht = W.fr.timers
  if W.on.holdRaid then
    -- one day behind the host, so this copy never reaches 0 first; before the host's first value, at least 2
    local want
    if Ht and Ht.u then want = Ht.u + 1 elseif T.daysUntilNextRaid < 2 then want = 2 end
    hold("holdRaid", function() return T.daysUntilNextRaid end, want, function(v) T.daysUntilNextRaid = v end)
  end
  if W.on.holdCamp then
    -- a camp spawns when daysTotal > lastBanditCampSpawnedDay + 180 (lane_w W4b READ)
    hold("holdCamp", function() return T.lastBanditCampSpawnedDay end, eng:getDaysTotal(), function(v) T.lastBanditCampSpawnedDay = v end)
  end
  if W.on.holdDirector then
    local big = W.cfg.director
    hold("holdDirector", function() local D = eng.questDirector; if not valid(D) then return big end; return D.scenario_nextActionDay end, big,
      function(v) eng.questDirector.scenario_nextActionDay = v end)
  end
  if W.on.holdMonths and Ht and Ht.m and Ht.mday and Ht.mday == eng:getDaysTotal() then
    -- read by the host on this same day: a month change between the host's read and here cannot be mixed in
    hold("holdMonths", function() return T.monthsTotal end, Ht.m, function(v) T.monthsTotal = v end)
  end
  if W.on.holdMerchants then
    hold("holdMerchants", function() return eng.spawnMerchants end, false, function(v) eng.spawnMerchants = v end)
  end
  if W.on.ignoreRaiders then
    local f = eng.drawDebugFlags; local has = false
    for i = 1, #f do if un(f[i]):ToString() == "ignoreRaiders" then has = true end end
    if not has then act("flag ignoreRaiders", function() f[#f + 1] = FName("ignoreRaiders") end); log("raid countdown switched off (ignoreRaiders)") end
  end
end

local function friendFpDone(day, P)
  W.fp.mine[day] = P
  tryCompare(W.S, day)
end

local function friendDayPoll(S)
  local day = S.eng:getDaysTotal()
  if W.day == nil then W.day = day; return end      -- baseline after a load: no sample half-way into a day
  if day ~= W.day then
    W.day = day
    if W.on.fp then addJob("fp", fpJob, { done = friendFpDone }) end
    if W.on.wide then                                            -- log only
      widePrune(day)
      wideStart(S, tostring(day), day, function(smp) W.wd.mine[smp.tag] = smp; wideTry(S, smp.tag) end)
    end
  end
end

-- status: RAID / CAMP / DIRECTOR: log and timers only. eng:spawnRaiders is NOT called: the core already announces
-- every new host squad (N) and the friend creates it, so a replay here would double the raiders.
-- MERCH: static read only (lane_w W4g); the region the host's merchant belongs to is not readable by name, so the
-- home region is a GUESS.
local function friendEvent(S, w)
  local e = w[5]; local F = W.fr
  if e == "RAID" then
    local u, s = tonumber(w[6]), tonumber(w[7])
    F.timers = F.timers or {}; F.timers.u = u; F.timers.s = s
    log("raid on the host: its raider squads reach this copy through the core's N messages")
    if W.on.holdRaid and u then
      local T = S.eng.TemporalComponent
      act("raid timers " .. (u + 1), function() T.daysUntilNextRaid = u + 1; if s then T.daysSinceLastRaid = s end end)
    end
  elseif e == "CAMP" then
    -- the events module (coop_x_events.lua) follows the host's camps by name and place; without it, a reload
    local Ev = rawget(C, "events")
    if Ev and Ev.on and Ev.on.camps then log("bandit camp spawned on the host: followed by the events module")
    else drift(S, "bandit camp spawned on the host (its place is rolled; no named replay)") end
  elseif e == "DIRECTOR" then
    log("scenario director acted on the host (next action day %s); its squads come by N messages", tostring(w[6]))
  elseif e == "FIRE" or e == "FIREOUT" then
    local k = w[6]
    log("host fire %s %s", e == "FIRE" and "started" or "ended", tostring(k))
    if k then F.hostFires[k] = (e == "FIRE") and true or nil; F.hadHostFire[k] = true end   -- what burns, and what has burnt, on the host (for friendOwnFireJob)
    if k and e == "FIRE" and W.on.fire then F.firePend[k] = { what = "on" }
    elseif k and e == "FIREOUT" and W.on.fireOut and w[7] ~= "GONE" then F.firePend[k] = { what = (w[7] == "BURNT") and "burnt" or "out" } end
  elseif e == "MERCH" then
    local f = tonumber(w[6])
    if W.on.merch and f and #S.eng.freeMerchants < f then
      local home = S.p1:getClosestOwnedRegion()
      if valid(home) then act("spawnFreeMerchant", function() S.eng:spawnFreeMerchant(home) end); log("free merchant spawned here to match the host") end
    end
  end
  bump("w_events")
end

-- store a host line; corrections happen in the friend's jobs (latest value wins, so a backlog costs nothing)
function W.apply(S, w)
  fresh(S)
  local F = W.fr; local sub = w[4]
  if sub == "R" then
    local k = w[5]; if not k then return end
    local R = F.reg[k]; if not R then R = { g = {} }; F.reg[k] = R end
    R.home = w[6] == "h"
    for key, v in (w[7] or ""):gmatch("(%w+)=(%-?[%d%.]+)") do
      if key == "w" then R.w = tonumber(v) elseif key == "k" then R.full = true elseif key == "sf" or key == "sw" then R[key] = tonumber(v)
      elseif key == "lt" or key == "tt" or key == "nl" then R[key] = tonumber(v); R.decDirty = true   -- (nl: lane 42)
      elseif (key:sub(1, 1) == "q" or key:sub(1, 1) == "u" or key:sub(1, 1) == "v") and tonumber(key:sub(2)) then
        local c = key:sub(1, 1); R[c] = R[c] or {}; R[c][tonumber(key:sub(2))] = tonumber(v); R.decDirty = true   -- lane 39: a rival's route levels, trade rules, targets
      elseif key:sub(1, 1) == "r" and tonumber(key:sub(2)) then R.gr = R.gr or {}; R.gr[tonumber(key:sub(2))] = tonumber(v); R.gv = (R.gv or 0) + 1 else local g = tonumber(key); if g then R.g[g] = tonumber(v); R.gv = (R.gv or 0) + 1 end end   -- (R.gv: lane 45)
    end
    F.dirty = true
  elseif sub == "H" then                                   -- lane 31: the region panel's numbers (W.friendHold writes them)
    local k, pay = w[5], w[6]
    if k and pay then F.hold[k] = pay; F.holdDirty = true end
  elseif sub == "L" then
    for key, v in (w[5] or ""):gmatch("(%a)=(%-?[%d%.]+)") do F.lord[key] = tonumber(v) end
    F.dirty = true
  elseif sub == "B" then
    for e in (w[5] or ""):gmatch("[^;]+") do
      local k, rest = e:match("^(%d+@%-?%d+,%-?%d+)(.*)$")
      if k then
        if rest == "-" then F.bld[k] = nil; F.bdirty[k] = nil
        else
          local full = rest:sub(1, 1) == "!"; local body = rest:match("|(.*)$") or ""
          local E = F.bld[k]
          if full or not E then E = { g = {}, full = full }; F.bld[k] = E end   -- partial without a full one: correct only what is named
          for g, a in body:gmatch("(%d+)=(%-?%d+)") do E.g[tonumber(g)] = tonumber(a) end
          F.bdirty[k] = true
        end
      end
    end
  elseif sub == "T" then
    F.timers = { u = tonumber(w[5]), s = tonumber(w[6]), c = tonumber(w[7]), d = tonumber(w[8]), m = tonumber(w[9]), mday = tonumber(w[10]) }
  elseif sub == "D" then
    local day, hc = tonumber(w[5]), tonumber(w[6])
    F.hostDay = day
    local ok, lc = pcall(function() return S.eng.TemporalComponent:getTotalDaysAndHours() end)
    if hc and ok and lc then
      local gap = hc - lc; W.gap = gap; S.stats.w_gapDays = string.format("%.2f", gap)
      if math.abs(gap) > W.cfg.maxDayGap then
        W.clockMiss = W.clockMiss + 1
        log("clock: host %.3f here %.3f, gap %.2f days (%d in a row); time of day is not settable by name", hc, lc, gap, W.clockMiss)
        if W.on.clockDrift and W.clockMiss >= W.cfg.driftAfter then W.clockMiss = 0; drift(S, string.format("clock gap %.2f days", gap)) end
      else W.clockMiss = 0 end
    end
  elseif sub == "X" then
    local X = { day = tonumber(w[5]), received = os.clock(), v = {} }; local i = 0
    for x in (w[6] or ""):gmatch("[^,]+") do i = i + 1; X.v[i] = tonumber(x) end
    Check.weatherWord(tonumber(w[2]), X.v)
    F.wx = X
    weatherApply(S)
  elseif sub == "F" then
    local day = tonumber(w[5])
    if day then W.fp.host[day] = fpDecode(w, 6); tryCompare(S, day) end
  elseif sub == "E" then
    friendEvent(S, w)
  elseif sub == "G" then
    if W.on.wide then wideRecv(S, w) end                 -- log only: the host's wide sample
  else
    bump("w_unknown")
  end
end

-- lane 31: the host's region panel numbers, written on a friend whose coop_patch.dll holds the region (HOLD). At once
-- when a line came, else every 0.5 s (a keep: nothing of this copy's own may move them while held, so a write then is
-- counted as a repair, w_holdKeep, and logged). Approval and publicOrder through reflection; the lists and the
-- problems through the DLL (a list longer than the game's is grown with the game's own helper; problems with the
-- game's own add / remove). A problem names its building by key (this copy's building there); a problem with a unit
-- takes the unit of this copy's own entry of that type and building when there is one, else it is left out and
-- counted (w_holdNoUnit).
function W.friendHold(S)
  local F = W.fr; local Pt = rawget(C, "patch")
  if not (Pt and Pt.hOn) then return end
  local now = os.clock()
  if not F.holdDirty and now - (W.t.holdKeep or 0) < 0.5 then return end
  local dirty = F.holdDirty
  W.t.holdKeep = now; F.holdDirty = false
  for k, pay in pairs(F.hold) do
    local r = W.regionByKey(k)
    if r and (mine(r.ownerPawn) or (W.on.rivals and rivalTown(r))) then      -- lane 39: a rival's town too
      local a, o, ra, ro, rm, pb = pay:match("^(%-?%d+)|(%-?%d+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
      if a then
        if F.holdGen[k] ~= Pt.hGen then
          local okH = Pt.holdSet(r)
          if okH then F.holdGen[k] = Pt.hGen; log("hold %s: this copy's own approval, order, months, wealth and problems stand still from now on", k) end
        end
        local n, parts = 0, {}
        a, o = tonumber(a), tonumber(o)
        if r.Approval ~= a then act("approval " .. k .. " " .. a, function() r.Approval = a end); n = n + 1; parts[#parts + 1] = "approval" end
        if r.publicOrder ~= o then act("order " .. k .. " " .. o, function() r.publicOrder = o end); n = n + 1; parts[#parts + 1] = "order" end
        for _, L in ipairs({ { "A", "summedApprovalFactors", ra }, { "O", "summedPublicOrderFactors", ro }, { "M", "publicOrderMemory", rm } }) do
          local okC, cur = pcall(rowsText, r[L[2]])
          if not okC or cur ~= L[3] then Pt.holdRows(r, L[1], L[3]); n = n + 1; parts[#parts + 1] = L[2] end
        end
        -- problems: the host's, with this copy's buildings
        local want, miss = {}, 0
        if pb ~= "-" then
          needIndex()
          local own = {}                                   -- this copy's entries with a unit: type:building address -> unit address
          pcall(function() local arr = r.problems; for i = 1, #arr do local m = arr[i]; if valid(m.unit) then own[m.Type .. ":" .. aT(addr(m.building) or 0)] = addr(m.unit) end end end)
          local used = {}
          for e in pb:gmatch("[^/]+") do
            local t, bk, u = e:match("^(%d+):([^:]+):([^:]+)$")
            if t then
              local ba = 0
              if bk ~= "-" then
                local b = W.buildingByKey(bk)
                if not b then                               -- not in the index yet (a pile a demolition just left, a new
                  local t0, x0, y0 = parseKey(bk)           -- site): this copy's buildings of that type are looked at now
                  pcall(function()
                    local arr = W.S.eng.buildingArr
                    for i = 1, #arr do
                      local c = un(arr[i])
                      if valid(c) and A.btype(c) == t0 then local k2 = W.bkey(c); local t2, x2, y2 = parseKey(k2); if t2 == t0 and math.abs(x2 - x0) <= 1 and math.abs(y2 - y0) <= 1 then b = c; break end end
                    end
                  end)
                end
                ba = b and addr(b) or nil
              end
              if ba == nil then
                miss = miss + 1
                -- a building the index does not know yet (a pile a demolition just left, a new site): the index is
                -- built again, at most every 2 s
                if now - (W.t.holdIdx or 0) >= 2.0 then W.t.holdIdx = now; needIndex(true) end
              elseif u == "-" then want[#want + 1] = t .. ":" .. aT(ba) .. ":0"
              else
                local x = unitByKey(r, u, used)             -- a villager by its family, another unit by its role and place
                local ua = x and addr(x) or own[t .. ":" .. aT(ba)]
                if ua then used[ua] = true; want[#want + 1] = t .. ":" .. aT(ba) .. ":" .. aT(ua) else miss = miss + 1; bump("w_holdNoUnit") end
              end
            end
          end
        end
        table.sort(want)
        local have = {}
        pcall(function() local arr = r.problems; for i = 1, #arr do local m = arr[i]; local ba, ua = 0, 0; if valid(m.building) then ba = addr(m.building) or 0 end; if valid(m.unit) then ua = addr(m.unit) or 0 end; have[#have + 1] = string.format("%d:%s:%s", m.Type, aT(ba), aT(ua)) end end)
        table.sort(have)
        local wantT = #want > 0 and table.concat(want, "/") or "-"
        local haveT = #have > 0 and table.concat(have, "/") or "-"
        if wantT ~= haveT then Pt.holdProb(r, wantT); n = n + 1; parts[#parts + 1] = "problems (" .. haveT:sub(1, 120) .. " -> " .. wantT:sub(1, 120) .. ")" end
        if miss > 0 then bump("w_holdMiss", miss); if (W.holdMissLog or 0) < 10 then W.holdMissLog = (W.holdMissLog or 0) + 1; log("hold %s: %d of the host's problems not found here (%s)", k, miss, pb:sub(1, 200)) end end
        if n > 0 then
          pcall(function() S.p1.shouldUpdateApprovalUI = true end)
          bump(dirty and "w_holdSet" or "w_holdKeep", n)
          if not dirty and (W.holdKeepLog or 0) < 20 then W.holdKeepLog = (W.holdKeepLog or 0) + 1; log("hold %s: %d part(s) had moved and were written back: %s", k, n, table.concat(parts, ", ")) end
        end
      end
    end
  end
end

local function friendTick(S, clock)
  local F = W.fr; local cfg = W.cfg
  if rawget(C, "hold") then return end   -- a join or repair is loading a save: the host's values are not arriving
  if clock - W.t.poll >= cfg.pollEvery then W.t.poll = clock; try("dayPoll", friendDayPoll, S) end
  local liveWeather = F.wx and F.wx.v[11] ~= nil and exactStock() and clock - F.wx.received <= 3
  if liveWeather then try("weather", weatherApply, S) end
  if clock - W.t.hold >= cfg.holdEvery then
    W.t.hold = clock; try("holds", holds, S); try("firePassive", firePassive, S)
    if not liveWeather and not (F.wx and F.wx.v[11]) then try("weather", weatherKeep, S) end
  end
  -- exact mode with TOTALS (lane 22): the months of food and fuel and the regional wealth are kept at the host's on
  -- every tick: the game writes the months in its own day routine and moves the wealth itself; written back in the
  -- same frame they are not shown
  local Pt = rawget(C, "patch")
  if exactStock() and Pt and Pt.tOn then
    for k, R in pairs(F.reg) do
      -- (lane 45) a region the native HOLD holds (its months and wealth routines do not run here: lane 31) is looked
      -- at twice a second, not every frame; one not held yet keeps the every-frame look
      local heldNow = Pt.hOn and F.holdGen and F.holdGen[k] == Pt.hGen
      if heldNow and clock - (R.keepT or -1e9) < 0.5 then
      elseif R.sf or R.sw or R.w then
        R.keepT = clock
        local r = W.regionByKey(k)
        if r and (mine(r.ownerPawn) or (W.on.rivals and rivalTown(r))) then   -- lane 39: a rival's town too
          for key, field in pairs(DERIVF) do
            local want = R[key]
            if want then local okS, v = pcall(function() return r[field] end); if okS and type(v) == "number" and math.abs(v - want) > 1e-4 then pcall(function() r[field] = want end); bump("w_derivKeep") end end
          end
          if W.on.wealth and R.w then local okW, v = pcall(function() return r.regionalWealth end); if okW and type(v) == "number" and v ~= R.w then pcall(function() r.regionalWealth = R.w end); bump("w_derivKeep") end end
        end
      end
    end
  end
  if W.on.hold and Pt and Pt.hOn and next(F.hold) ~= nil then try("hold", W.friendHold, S) end   -- lane 31
  if (W.on.stock or W.on.silver or W.on.wealth or W.on.lordExtra)
     and (clock - W.t.fstock >= cfg.stockEvery or (F.dirty and clock - W.t.fstock >= 0.25)) then
    if addJob("friendRegions", friendRegionJob, {}) then W.t.fstock = clock; F.dirty = false end
  end
  -- (exact mode: the facts module writes storage buildings and sites too, from one stream of the host's values; two
  -- writers with values of different moments would make a number go back and forth)
  if W.on.bstock and next(F.bld) ~= nil and not exactStock() then
    local all = clock - W.t.fbld >= cfg.bldEvery
    if all or (next(F.bdirty) ~= nil and clock - W.t.fbld >= 0.5) then
      needIndex()
      if addJob("friendBld", friendBldJob, { all = all }) then W.t.fbld = clock end
    end
  end
  if (W.on.fire or W.on.fireOut) and next(F.firePend) ~= nil then needIndex(); addJob("friendFire", friendFireJob, {}) end
  if W.on.ownFire and W.on.fire and W.on.fireOut and clock - (W.t.ownFire or 0) >= 4.0 then W.t.ownFire = clock; addJob("friendOwnFire", friendOwnFireJob, {}) end
end

-- ---------------------------------------------------------------- plug-in
local function tick(S, clock)
  fresh(S)
  W.me = addr(S.p1)
  if not W.me then return end
  if S.role == "host" then hostTick(S, clock) elseif S.role == "friend" then friendTick(S, clock) end
  if S.role == "friend" and W.fpLater then pcall(W.fpLaterStep, S) end      -- (lane 71)
  runJobs(W.cfg.budgetMs / 1000)
  if W.on.wide and not rawget(C, "hold") then Check.tick(S) end
  -- the wide sample has its own stepper (not the job queue above: it must never delay a push); not while a save loads
  W.wd.tickN = W.wd.tickN + 1
  if (W.wd.run or W.wd.posts[1]) and not (S.role == "friend" and rawget(C, "hold")) then
    if W.on.wide then wideTick(S) else W.wd.run = nil; W.wd.posts = {}; W.wd.wantFull = true end   -- dropped half way: next time whole
  end
end

local function onMessage(S, from, kind, w, line)
  if kind ~= "W" then return false end
  if w[4] == "PRE" or w[4] == "WATCH" or w[4] == "OBS" or w[4] == "FPASK" or w[4] == "FPROWS" then
    if W.on.wide and not C.stale(from, w) and not rawget(C, "hold") then fresh(S); Check.receive(S, from, w) end
    return true
  end
  if S.role ~= "friend" or from ~= "host" then bump("w_ignored"); return true end   -- W runs host -> friends only
  -- the core's friendInbox does not drop lines from before this copy started (hostInbox does): do it here,
  -- so a late friend does not replay an old raid or fire; the next keyframe brings the current values
  local wall = tonumber(w[2])
  if C.stale("host", w) then bump("w_stale"); return true end      -- (lane 62: by the host's own stamps, not by two clocks; coop.lua C.stale)
  W.apply(S, w)
  bump("w_in")
  return true
end

-- ---------------------------------------------------------------- console helpers (switches, status, self-tests)
function W.set(name, v)
  if DEFAULT_ON[name] == nil then return "unknown item " .. tostring(name) end
  W.on[name] = v and true or false
  log("item %s %s", name, W.on[name] and "on" or "off")
  return name .. "=" .. tostring(W.on[name])
end
-- also clears the test-only states (dry run, captured sending) in case a self-test stopped half-way
function W.defaults()
  for k, v in pairs(DEFAULT_ON) do W.on[k] = v end; for k, v in pairs(DEFAULT_CFG) do W.cfg[k] = v end
  W.dry = false; W.capture = nil
  return "defaults restored"
end

function W.status()
  local S = W.S; if not S then return "world: not attached yet" end
  local on = {}; for k, v in pairs(W.on) do if v then on[#on + 1] = k end end; table.sort(on)
  local st = {}; for k, v in pairs(S.stats) do if type(k) == "string" and k:sub(1, 2) == "w_" then st[#st + 1] = k .. "=" .. tostring(v) end end; table.sort(st)
  return string.format("world %s role=%s day=%s jobs=%d miss=%d maxStep=%.2fms(%s) maxTick=%.2fms dry=%s capturing=%s drift=%s err=%s | on: %s | %s",
    W.version, tostring(S.role), tostring(W.day), #W.jobs, W.miss or 0, W.maxStepMs or 0, tostring(W.maxStepJob), W.maxTickMs or 0,
    tostring(W.dry == true), tostring(W.capture ~= nil),
    tostring(W.lastDrift), tostring(W.lastErr), table.concat(on, ","), table.concat(st, " "))
end

-- host: send every value again on the next scans (for the join / repair module, right after a friend finished loading;
-- without it the friend waits up to cfg.keyEvery s for the periodic keyframe)
function W.keyframe()
  -- (lane 51) the region values sent are kept: the forced whole list below (W.t.key) sends each of them again, and a
  -- change still waiting its 0.3 s goes out as the value sent before, not as a first look (which goes out as it is)
  W.sent = { reg = (W.sent and W.sent.reg) or {}, bld = {}, lord = {} }; W.pend = W.pend or {}
  if W.t then W.t.stock = 0; W.t.bld = 0; W.t.key = -1e9 end   -- -1e9: the next region scan also resends timers / weather
  if W.wd then W.wd.wantFull = true end                        -- the next wide sample goes out whole (log only)
  -- (join, lane 15) A friend that loaded a save ALONE has forgotten which buildings burn on the host (its list of
  -- the host's fires starts empty in a new world), and the host, which did not load, would not say it again: the
  -- friend would put such a fire out as "burning here but not on the host". So the fires that burn now are told
  -- once more. A copy whose building already burns does nothing with the line (friendFireJob, "on").
  -- When every copy loads, the host's own list is empty here and its next look tells every fire anyway.
  if W.S and W.S.role == "host" and W.fires then for k in pairs(W.fires) do send("W E FIRE " .. k) end end
  return "keyframe queued"
end

-- for self-tests only: they run inside one console call on the game thread and cannot wait for a tick
function W.prepare(S) fresh(S); W.me = addr(S.p1); return W.me ~= nil end
function W.flush() runJobs(nil) end
W.isMine, W.invOf, W.goodsList, W.fpEncode, W.fpDecode = mine, invOf, goods, fpEncode, fpDecode
function W.indexNow(S) W.prepare(S); needIndex(true); W.flush(); return W.bidx end
function W.applyNow(S, what)
  W.prepare(S); what = what or "all"
  if what == "bld" or what == "all" then needIndex(true); addJob("friendBld", friendBldJob, {}) end
  if what == "fire" or what == "all" then needIndex(true); addJob("friendFire", friendFireJob, {}) end
  if what == "reg" or what == "all" then addJob("friendRegions", friendRegionJob, {}) end
  W.flush()
end
function W.hostScanNow(S, which, key)
  W.prepare(S)
  if which == "regions" then addJob("hostRegions", hostRegionJob, { key = key })
  elseif which == "bld" then addJob("hostBld", hostBldJob, { key = key })
  elseif which == "fire" then addJob("hostFire", hostFireJob, {})
  elseif which == "day" then onHostDay(S, S.eng:getDaysTotal())
  elseif which == "events" then hostEvents(S) end
  W.flush()
end
function W.fingerprintNow(S)
  W.prepare(S); local P
  addJob("fpNow", fpJob, { done = function(_, p) P = p end }); W.flush()
  if P then P.at = nil; P.detail = nil end
  return P, P and fpEncode(P)
end
function W.holdsNow(S) W.prepare(S); holds(S) end

-- ---- the wide sample (log only): what a console or the development channel can ask
-- Coop.world.wide()             counters per section and the last days, as text
-- Coop.world.wideDetail([tag])  every difference of the last comparison (or of that tag), one per line, tab-separated:
--                               section, key, field, host, here, mark (held / per-copy / empty)
-- Coop.world.wideNow()          host: take a sample now, in one call, and send it; each friend then takes its own at once
--                               and logs the comparison under the tag n<k>. Friend: this copy's sample only (no comparison).
-- Coop.world.wideBench(n)       n samples in one call each, nothing sent: milliseconds per sample
function W.wide()
  local S = W.S; if not S then return "wide: not attached yet" end
  local st = S.stats or {}
  local t = { string.format("wide: on=%s role=%s compared=%d sent=%s bytes=%s lost=%s nobase=%s skipped=%s ticks=%d ms=%.0f over2ms=%d over5ms=%d maxTick=%.1fms err=%s",
    tostring(W.on.wide), tostring(S.role), W.wideStat.compared, tostring(st.w_wideSent or 0), tostring(st.w_wideBytes or 0), tostring(st.w_wideLost or 0),
    tostring(st.w_wideNoBase or 0), tostring(st.w_wideSkip or 0), W.wideTicks or 0, W.wideMs or 0, W.wideOver2 or 0, W.wideOver5 or 0, W.wideMaxTickMs or 0, tostring(W.lastWideErr)) }
  local L = W.wideStat.lastSend
  if L then t[#t + 1] = string.format("last sent: %s, %d values, %d bytes in %d lines (%s), %.0f ms over %d ticks", tostring(L.tag), L.n, L.bytes, L.lines, L.full and "whole" or "changes", L.ms, L.ticks) end
  t[#t + 1] = "section samples differing differences held largest | on the player's own: samples differing, differences"
  for _, spec in ipairs(WIDE) do
    local c = W.wideCnt[spec[1]]
    if c then t[#t + 1] = string.format("%s %d %d %d %d %s | %d %d", spec[1], c.days, c.bad, c.items, c.held, wFmt(c.max), c.badP or 0, c.itemsP or 0) end
  end
  local head = { "day" }; for _, spec in ipairs(WIDE) do head[#head + 1] = spec[1] end
  t[#t + 1] = table.concat(head, " ") .. "   (differences; p<n> = of them on the player's own)"
  for _, d in ipairs(W.wideDays) do
    local row = { tostring(d.tag) }
    for _, spec in ipairs(WIDE) do
      local n = d.n[spec[1]]; local p = d.nP and d.nP[spec[1]] or 0
      row[#row + 1] = n and (tostring(n) .. ((p > 0) and ("p" .. p) or "")) or "-"
    end
    t[#t + 1] = table.concat(row, " ")
  end
  return table.concat(t, "\n")
end

function W.settlePending()
  local D = W.wd
  if not D then return -1 end
  local n = #D.batches + #D.posts + (D.run and 1 or 0)
  for _, pending in ipairs({ D.details, D.inb, D.mine, D.host, W.fp.mine, W.fp.host, W.fpLater or {} }) do
    for _ in pairs(pending) do n = n + 1 end
  end
  return n
end
function W.wideDetail(tag)
  local L
  for i = #W.wideLast, 1, -1 do if tag == nil or tostring(W.wideLast[i].tag) == tostring(tag) then L = W.wideLast[i]; break end end
  if not L then return "wide: no comparison" .. (tag and (" with tag " .. tostring(tag)) or " yet") end
  local t = { "# wide detail tag " .. tostring(L.tag) .. " day " .. tostring(L.day) }
  for k, v in pairs(L.names or {}) do t[#t + 1] = "#region\t" .. k .. "\t" .. (v:match("^([^|]*)") or "?") end
  for _, spec in ipairs(WIDE) do
    local R = L.res[spec[1]]
    t[#t + 1] = string.format("#section\t%s\t%d\t%d\t%s\t%s", spec[1], R.n, R.held, wFmt(R.max), wFmt(R.sum))
    for _, it in ipairs(R.items) do t[#t + 1] = table.concat({ spec[1], it.k, it.f, it.h, it.m, it.mark or "", it.o or "" }, "\t") end
  end
  return table.concat(t, "\n")
end
-- (lane 63) a friend's whole difference in one line, for the join module's breaker: the last daily comparison that
-- differed (both fingerprints), and every difference of the last wide comparison (not cut at cfg.wideLogMax)
function W.diffText()
  local t = {}
  local LB = W.lastBad
  if LB then t[#t + 1] = string.format("daily comparison day %s (%.0f s ago) differs: %s; host %s; here %s", tostring(LB.day), os.clock() - LB.t, LB.text, LB.host, LB.here)
  else t[#t + 1] = "no daily comparison has differed yet" end
  local L = W.wideLast[#W.wideLast]
  if L then
    local n = 0
    for _, spec in ipairs(WIDE) do
      local R = L.res[spec[1]]
      if R and #R.items > 0 then
        local u = {}
        for _, it in ipairs(R.items) do u[#u + 1] = it.k .. " " .. it.f .. " " .. it.h .. "/" .. it.m .. (it.mark and ("(" .. it.mark .. ")") or "") .. (it.o and (" " .. it.o) or "") end
        n = n + #u
        t[#t + 1] = string.format("wide %s %s: %s", tostring(L.tag), spec[1], table.concat(u, "; "))
      end
    end
    if n == 0 then t[#t + 1] = string.format("wide %s: no difference", tostring(L.tag)) end
  else t[#t + 1] = "no wide comparison yet" end
  return table.concat(t, " | ")
end
function W.wideNow()
  local S = W.S; if not (S and W.wd and valid(S.eng)) then return "wide: not attached yet" end
  W.me = addr(S.p1)
  W.wideSeq = (W.wideSeq or 0) + 1
  local tag = "n" .. W.wideSeq
  local smp = wideSync(S, tag, S.eng:getDaysTotal())
  if S.role == "host" then local D = W.wd; D.posts[#D.posts + 1] = { kind = "send", smp = smp, i = 0, lines = 0, bytes = 0 }; wideDrain() end
  return string.format("wide %s: %d values in %.0f ms on day %s%s", tag, smp.n, smp.ms, tostring(smp.day), S.role == "host" and ", sent" or "")
end
function W.wideBench(n)
  local S = W.S; if not (S and W.wd and valid(S.eng)) then return "wide: not attached yet" end
  W.me = addr(S.p1)
  n = n or 5; local t = {}; local sum, vals = 0, 0; local ph = {}
  for i = 1, n do
    local smp = wideSync(S, "bench", S.eng:getDaysTotal()); t[i] = string.format("%.0f", smp.ms); sum = sum + smp.ms; vals = smp.n
    for p, ms in pairs(smp.phase or {}) do ph[p] = (ph[p] or 0) + ms end
  end
  local nb, nu, nf = 0, 0, 0
  pcall(function() nb = #S.eng.buildingArr; nu = #S.eng.unitArr; local a = S.eng.regions; for i = 1, #a do nf = nf + #un(a[i]).workerFamilies end end)
  return string.format("wide bench: %d samples, %.1f ms each on average (%s), %d values, %d buildings, %d units, %d families; per part: world %.1f, regions %.1f, families %.1f, buildings %.1f, units %.1f ms",
    n, sum / n, table.concat(t, " "), vals, nb, nu, nf, (ph[1] or 0) / n, (ph[2] or 0) / n, (ph[3] or 0) / n, (ph[4] or 0) / n, ((ph[5] or 0) + (ph[6] or 0)) / n)
end

C.register("world", { onWorld = function(S) fresh(S) end, tick = tick, onMessage = onMessage })
return "coop_world " .. W.version .. " loaded"
