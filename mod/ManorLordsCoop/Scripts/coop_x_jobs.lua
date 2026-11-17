-- Manor Lords Co-op: the job board (plug-in module "jobs", message kind "U"). Lane 13, session 21; lane 19 (gaps 1, 2,
-- 5, 6: the gate, oxen, places, rival towns).
-- Evidence and numbers: research/2026-11-10-game-probe/lanes/lane_s21_13/report.txt and lanes/lane_s21_19/report.txt
--
-- THE HOST DECIDES WHICH VILLAGER TAKES WHICH JOB; EACH COPY'S OWN GAME WALKS AND WORKS IT.
--
-- What the game does (read in its code and measured):
--   SMUnit:setTask(record)   the game's own way to give a task: it ends the task before with the game's own routine
--                            and stores the new one. It plans no walk.
--   the villager's next think tick (within about half a second) ends with the game's "start this task" routine
--                            (executeTask), which plans the walk. From there on the copy's own game walks and works it.
--   The engine's debug job list (disableJobIDs) stops villagers whose workplace has a listed job type from CHOOSING a
--   task (the job chooser) and from STARTING one (executeTask).
--
-- THE GATE (lane 19, cfg.gate; friend only). coop_patch's item JOBGATE switches executeTask's test of the list off (one
-- byte, in memory, found by signature; native/coop_patch). With it on and the list filled with every job type, a
-- friend's villagers choose nothing by themselves and every task the board gives is started as before. The list is
-- keyed by job type, not by town, so the rival lords' villagers and the oxen stop choosing too: with the gate on, the
-- board carries every family villager of every region (cfg.rivals) and every ox (cfg.oxen). Order: the byte first,
-- then the list; on the way back the list is emptied first, then the byte. The list is emptied (and the byte put back)
-- while a save loads, when the host has been silent for cfg.quiet seconds, when cfg.gate is switched off and when the
-- mod stops. When the item is not available (another game build: the signature is not found) the board falls back to
-- the way of lane 13: a task the villager chose by itself is replaced by "stand here" (cfg.hold).
--
-- host -> friends   U S <unit> <type> <good> <amount> <target building> <final building> <target unit>
--                       <final unit> <resource place> <target x,y,z,floor,yaw> <final x,y,z,floor,yaw>
--                       <entity x,y,z> <paid 0|1> <host's unit x,y,z>   a unit of the host started this task
--                   U F <unit> <type>                      it started a task that cannot be named on another copy
--                   U E <unit>                             its task ended and it has nothing to do
--                   U R ...  (as U S)                      (lane 23) a running task told again (hello, a question)
--                   U L <unit> <load>                      (lane 23) its load changed: "0" or <good>x<amount>[+...]
-- friend -> host    U H                                    this friend's board started: tell every running task again
--                   U Q <unit>                             (lane 23) tell this unit's task and load again
--   unit = <region place>.<family place>.<member place> for a family villager (never a unit id: ids differ between
--          copies); o<building type>,<x>,<y>#<place in that building's oxen list> for an ox (lane 19: an ox is named
--          by the workplace it hauls for, which every copy has, and its place there). building = type,x,y.
--   The field after the place (lane 19) is optional: a friend that lacks it does not place. The last (lane 23) is the
--   host's unit's load at the start, optional too.
-- LANE 23 (third round): loads in hands are the host's word (cfg.hands: on the host's job, after cfg.handsLag s of
-- difference, the friend's unit's Inventory is written to the host's load); a unit holding goods is not given its
-- production task again and its carry is not cut (cfg.carryKeep); a resource not here yet is looked for again
-- (cfg.resWait); an idle gated unit with no word asks (cfg.ask); a unit on another task than the host's for
-- cfg.driftLag s gets the host's (cfg.drift).
--
-- On a friend's copy, for every start:
--   the unit already does that task (same type and buildings)          nothing
--   it still works on the task the host gave before                    the new one waits until that ends, at most
--                                                                      cfg.grace game seconds; at once when this
--                                                                      copy's unit is still far (cfg.waitNear) from
--                                                                      the old task's place (it would not end soon)
--   otherwise                                                          setTask(record) now
--   PLACES (lane 19, cfg.place): before the task is given, a unit that stands more than cfg.placeFar from where the
--   host's unit stands is put there (realPos and the actor's place), unless the local player's camera is within
--   cfg.placeSeen of either place or the unit is selected or under the pointer.
-- and between starts: without the gate, a task the villager chose by itself is replaced by "stand here" (cfg.hold);
-- with the gate the game chooses nothing, and a task that still starts by itself (not from the job chooser) is replaced
-- by the host's running task when the host has one (counted "self_<type>").
-- cfg.again: when the host's unit is still on its task and this copy's unit lost it while standing at its place (no
-- material here), it gets the same task once more, at most every 2 game seconds.
-- A friend's own actions are untouched: they go to the host as before; the host's villagers react; the board follows.
local C = _G.Coop; local A = C.api
local un, valid, log = A.un, A.valid, A.log
C.jobs = C.jobs or {}
local J = C.jobs
J.cfg = J.cfg or { on = true,        -- the whole board
                   hold = true,      -- friend without the gate: stop a self-chosen task ("stand here")
                   again = true,     -- friend: repeat the host's running task for a unit that stands at its place
                   gate = true,      -- friend: coop_patch JOBGATE + the engine's job list: the game chooses nothing (lane 19)
                   rivals = true,    -- host: the rival lords' villagers are on the board too (needed by the gate)
                   oxen = true,      -- host: oxen are on the board, and a villager leading an ox can be named (lane 19)
                   place = true,     -- friend: a unit far from the host's unit's place is put there before a task starts
                   placeFar = 1500,  -- ... farther than this (cm)
                   placeSeen = 6000, -- ... but not when the camera is within this (cm) of the old or the new place
                   waitNear = 2500,  -- friend: a new start waits for the old task only while the unit is within this of it
                   resNear = 500,    -- friend: a resource not at the host's place: the nearest within this (cm; 0 = off)
                   stride = 4,       -- every villager of the player's town is looked at once in this many frames
                   perFrame = 15,    -- ... but never more than this many in one frame (the stride grows with the town)
                   rstride = 12,     -- rival villagers and oxen: once in this many frames
                   rperFrame = 8,    -- ... and never more than this many in one frame
                   grace = 6.0,      -- friend: game seconds a new start waits for the task before it to end
                   quiet = 30.0,     -- friend: no board line for this many seconds: the gate is opened (list emptied)
                   refresh = 5.0,    -- seconds between rebuilds of the unit lists (families come and go)
                   -- lane 23 (third round)
                   handsTell = true, -- host tells each unit's load (U L, and with each start)
                   hands = true,     -- friend: a unit on the host's job gets that load written. Off in lane 23 (run v1: a written
                                     -- load never entered the region's totals: 11 to 13 of 18 differed); on since the
                                     -- totals are the host's word (TOTALS, lane 22)
                   boardCarry = true,-- friend: a load the host's unit does not hold is carried away by the board
                   handsLag = 1.5,   -- ... once its load has differed this many wall seconds (the start lag is under 1 s)
                   carryKeep = true, -- friend: a unit holding goods is not given its production task again, and a
                   carryGrace = 8.0, -- ... carry it is on is not cut by the next start for this many game seconds (20 until e1: 90 % of carries started 13.7 s late)
                   resWait = 12.0,   -- friend: a resource not here yet is looked for again for this many wall seconds
                   resIndexEvery = 4.0, -- ... the index of resources rebuilt at most this often (s)
                   resFar = 5000,    -- ... a felled tree not there: the nearest felled tree within this (cm; lane 46: 20 -> 50 m)
                   pickWait = 6.0,   -- (lane 46) friend: a fetch that picked its load up before the host's waits there
                                     --   (with the load) for the host's carry start, at most this many wall seconds
                   ask = true,       -- friend: a gated unit idle with no word of the host asks for its task (U Q)
                   askAfter = 4.0, askEvery = 20.0,
                   drift = true,     -- friend: a unit on another task than the host's for driftLag s gets the host's
                   driftLag = 1.5,
                   pick = true,      -- (lane 35) friend: coop_patch PICK: the chooser starts only the host's task (BACK types)
                   regAudit = true,  -- (lane 35, round six) friend: a region's building sets hold only buildings of the engine
                   regAuditEvery = 5.0,
                   speedScale = true, -- (lane 35) both: above speed 4 the look stride and the lags shrink with the speed
                   placeStanding = false } -- (lane 23, gap f) true: only a unit that stands is put at the host's place. (lane 49, round four) false: under the end hold a villager is mostly still walking its held task at the host's next start, and 149 of 176 s of the far starts were skipped as "walking"
-- endHoldSkip: the trader's legs (59 to 61) off the end hold (lead, 2026-11-16: lane 49 r6s2, the friend's trader held a load of 50 at a pause the host's had not; his step seconds fall under the user's soft bar)
for k, v in pairs({ endHoldSkip = { [59] = true, [60] = true, [61] = true }, gatherHold = true, endHold23 = true, endHoldCap = 600.0, endHoldRenew = true, arriveHold = true, arriveR = 300, arriveRs = 120, arriveF = 0.002, arriveMax = 600.0, placeScreen = true, endHold = true, endHoldCeil = 30.0, endLag = 0.5, speedScale = true, regAudit = true, regAuditEvery = 5.0, pick = true, choose = true, chooseLag = 3.0, resFar = 5000, pickWait = 6.0, placeStanding = false, handsTell = true, hands = true, boardCarry = true, handsLag = 1.5, carryKeep = true, carryGrace = 8.0, resWait = 12.0, resIndexEvery = 4.0, ask = true, askAfter = 4.0, askEvery = 20.0, drift = true, driftLag = 1.5 }) do
  if J.cfg[k] == nil then J.cfg[k] = v end                     -- a board loaded again over an older cfg
end
J.n = J.n or {}
local function bump(k, d) J.n[k] = (J.n[k] or 0) + (d or 1) end
local function got(f, d) local ok, v = pcall(f); if ok and v ~= nil then return v end; return d end
local function rnd(x) return math.floor(x + 0.5) end
local FOLLOW = 41                   -- "Follow" (leading an ox): its target place moves every frame
-- (lane 19) the task types the board gives: the ones given on two copies without harm (lane 13's runs, lane 19's).
-- Any other type is sent as "cannot be named" (U F). Why: a rival's villager given type 65 (no name in ETaskType, at a
-- building of type 52) on a gated friend was most likely what crashed it (lane 19 report, run v3a: null + 0x14c4 in
-- the routine executeTask calls for type 65). A plain record of such a type lacks something the game's own code expects.
local GIVE = {}
for _, t in ipairs({ 1, 3, 4, 11, 12, 17, 22, 23, 25, 26, 27, 41, 46, 47, 52, 53, 60, 61, 62 }) do GIVE[t] = true end
J.GIVE = GIVE                       -- (lane 54) the console of a watched test may add a type (59, the trader's MountHorse)
GIVE[59] = true                     -- (lane 54, round two) the trader's MountHorse: given from the host's word (THE TRADER)
local LAZY = 30                     -- the game's own "nothing to do": never sent; the friend's villager stands and waits
local CARRY = { [4] = true, [22] = true }   -- PickupGoods (a load to a building), MovingItemBetweenBuilding
local TAKES = { [4] = true, [22] = true, [61] = true, [47] = true }   -- tasks that take a load in hands away (61 TradeStock, 47 DropResource)
-- (lane 23, the cause of "a given task ends at once") tasks the game ENDS at every cycle and its own job chooser starts
-- again in the same think (selling, mining, the trader's legs). On a gated friend the job list stops that chooser, so
-- the task ends after one cycle (two copies: a seller and a miner given once by hand lost their task after 8 to 19 s
-- with every other friend-side part off, and kept it only with the job list emptied; sitting d2). cfg.choose (lane
-- 23, part 3): the villagers whose host task is one of these are named to coop_patch's item CHOOSE, which lets the
-- game's chooser run for exactly them (the list stays full for everybody else); the board leaves the re-pick to the
-- game (cfg.chooseLag s before it gives the host's task itself). 41 (leading an ox) is in it: 1.5 gives per host start
-- at speed 4, 14.3 at speed 8 (lane 23, d5).
local CYCLE = { [26] = true, [27] = true, [41] = true, [59] = true, [60] = true, [61] = true }
-- (lane 23, e1 and f2) what the chooser does once allowed: for a seller, a miner or an ox leader it may pick something
-- the host's villager did not (a miner: a fetch to the storehouse every cycle; an ox leader: another ox), so those get the
-- host's task back at once; the trader's own legs (59, 60, 61 and its carries) are its chooser's (given back, the
-- trader agreed 75 % against 97 %).
local BACK = { [26] = true, [27] = true, [41] = true }
local NOCUT = { [17] = true, [23] = true }  -- (lane 35) tree work: keeps lane 23's end lag
local CUT = { [4] = true, [22] = true, [25] = true }  -- (lane 35) a new start cuts only these (carry, fetch, crafting: measured, m2 A); the rest waits as before (f6, f7: gathering fell with a wider cut)

-- (lane 23) a unit's load, as text: "0" (nothing) or "<good>x<amount>" per record, joined by "+". Read inside #a.
local function handsOf(u)
  local a = u.Inventory; local n = #a
  if n == 0 then return "0" end
  local s = {}
  for i = 1, n do local x = a[i]; s[#s + 1] = tostring(math.tointeger(x.Type) or x.Type) .. "x" .. tostring(math.tointeger(x.amt) or x.amt) end
  return table.concat(s, "+")
end
-- (lane 23) a friend's unit gets the host's load: its Inventory written (records changed in place, appended at #a + 1,
-- or emptied), then the carried goods' meshes made again by the game's own functions. A deviation of hard rule 7 like
-- the job list: a game list written by the shipped mod, on a friend's copy only.
-- (lane 54, round two) a trader that is not mounted while the host's trader is on its trip gets no load written (a
-- MountHorse with goods in hands ends at once: t54a1, 3.17.1 looped 59 > 61 > carry for 43 s); see THE TRADER below
local function traderNoLoad(u, s)
  if J.cfg.trader == false or s == "0" or not (J.mnt and J.byAddr) then return false end
  local ok, a = pcall(function() return u:GetAddress() end); local e = ok and J.byAddr[a]
  if not (e and J.mnt[e.key] and e.host) then return false end
  local hty = tonumber(e.host.rec.Type) or -1
  if hty ~= 59 and hty ~= 60 and hty ~= 61 then return false end
  local m = got(function() return u.mountActor end, nil)
  if m ~= nil and got(function() return m:IsValid() end, false) then return false end
  J.n.trader_no_load = (J.n.trader_no_load or 0) + 1; return true
end
local function setHands(u, s)
  if traderNoLoad(u, s) then return end                        -- (lane 54, round two)
  local want = {}
  if s ~= "0" then for g, n in s:gmatch("(%-?%d+)x(%-?%d+)") do want[#want + 1] = { Type = math.tointeger(tonumber(g)), amt = math.tointeger(tonumber(n)) } end end
  local a = u.Inventory; local n = #a
  local old = n > 0 and (math.tointeger(a[1].Type) or 0) or 0
  if #want == 0 then if n > 0 then a:Empty() end
  else
    if n > #want then a:Empty(); n = 0 end
    for i = 1, #want do
      if i <= n then local x = a[i]; x.Type = want[i].Type; x.amt = want[i].amt else a[#a + 1] = want[i] end
    end
  end
  -- what a player sees: the carried good is the equipment of its slot (lane 23 probe: slot 1 holds the good carried,
  -- e.g. 228 while 228x1 is in hands, 0 when empty): the game's own equip / unequip
  if #want > 0 then pcall(function() u:equip(want[1].Type, true, true) end)
  elseif old ~= 0 then pcall(function() u:unequip(u:GetItemEquipmentSlot(old, true)) end) end
end

-- (the lead, 2026-11-13) "still in the game". A demolished building stays a valid object for a while: seen on a
-- friend 1 s and 4 s after a demolish (lanes/lane_s21_0/crash_demolish_site, run1): IsValid true,
-- IsActorBeingDestroyed false, GetRegion nothing, no longer in the engine's list of buildings. A task given at it makes
-- the game run its work-hit code on a building without a region, and that closed a friend's game twice. No task is
-- given at such a building and none is looked up.
--   here(o)    any actor: valid and not being destroyed
--   bHere(b)   a building: here(b) and it has a region; one without a region counts only while the engine still lists it
-- (test only: Coop.jobs.test = { noHere = true }, set from the console, gives the check as it was before: valid only)
local function here(o)
  if not valid(o) then return false end
  if J.test and J.test.noHere then return true end
  local ok, gone = pcall(function() return o:IsActorBeingDestroyed() end)
  return not (ok and gone == true)
end
local function bHere(b)
  if not here(b) then return false end
  if J.test and J.test.noHere then return true end
  local ok, r = pcall(function() return b:GetRegion() end)
  if not ok then return true end                         -- no such function: not a building, nothing to judge by
  if valid(r) then return true end
  local a = b:GetAddress()
  local arr = C.s.eng.buildingArr
  for i = 1, #arr do local x = un(arr[i]); if valid(x) and x:GetAddress() == a then return true end end
  bump("building_left")
  return false
end
local BREF = { targetBuilding = true, finalBuilding = true }
local function refHere(k, o) if BREF[k] then return bHere(o) end; return here(o) end

-- ---------------------------------------------------------------- names that are equal on every copy
local function bkey(b) local l = b:K2_GetActorLocation(); return string.format("%d,%d,%d", A.btype(b), rnd(l.X), rnd(l.Y)) end
local function findB(key)
  local t, x, y = key:match("^(%-?%d+),(%-?%d+),(%-?%d+)$"); if not t then return nil end
  t, x, y = tonumber(t), tonumber(x), tonumber(y)
  local T = C.town
  if T and T.findB then local ok, b = pcall(T.findB, t, x, y); if ok and bHere(b) then return b end end
  local arr = C.s.eng.buildingArr
  for i = 1, #arr do
    local b = un(arr[i])
    if here(b) and A.btype(b) == t then local l = b:K2_GetActorLocation(); if math.abs(l.X - x) < 60 and math.abs(l.Y - y) < 60 then return b end end
  end
  return nil
end

-- a resource (berries, stone, fish, a felled tree ...) by its place: an index of every Resource actor, by whole metres,
-- rebuilt when a place is not found (at most every 10 s). The engine's findResourceByPos did not find them.
local function resKey(x, y) return rnd(x / 100) .. ":" .. rnd(y / 100) end
local function findRes(s, clock)
  local x, y = s:match("^(%-?%d+),(%-?%d+),"); if not x then return nil end
  x, y = tonumber(x), tonumber(y)
  for pass = 1, 2 do
    local idx = J.res
    if idx then
      for dx = -1, 1 do for dy = -1, 1 do
        local r = idx[resKey(x + dx * 100, y + dy * 100)]
        if valid(r) then local l = r:K2_GetActorLocation(); if math.abs(l.X - x) < 60 and math.abs(l.Y - y) < 60 then return r end end
      end end
    end
    if idx and (J.cfg.resNear or 0) > 0 and (pass == 2 or clock - (J.resT or -100) < 10.0) then   -- after a rebuild only
      -- (lane 19, gap 3) not at that place: the nearest resource within cfg.resNear (a felled tree lies where it fell
      -- on this copy, a hand cart where this copy's villager left it)
      local R = math.ceil(J.cfg.resNear / 100); local best, bd
      for dx = -R, R do for dy = -R, R do
        local r = idx[resKey(x + dx * 100, y + dy * 100)]
        if valid(r) then local l = r:K2_GetActorLocation(); local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2
          if d <= J.cfg.resNear * J.cfg.resNear and (not bd or d < bd) then best, bd = r, d end end
      end end
      if best then bump("res_near"); return best end
      -- (lane 23, gap b) a felled tree falls another way on each copy: the probe on two copies (out/bfix_pend_friend1.txt)
      -- found the friend's felled tree 5 to 20 m from the host's in 50 of 78 waits. The nearest felled tree within
      -- cfg.resFar is taken (only felled trees: other resources keep the 5 m rule)
      local RF = J.cfg.resFar or 0
      if RF > 0 and J.fallen then
        local fb, fd
        for _, r in ipairs(J.fallen) do
          if valid(r) then local l = r:K2_GetActorLocation(); local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2
            if d <= RF * RF and (not fd or d < fd) then fb, fd = r, d end end
        end
        if fb then bump("res_fallen_near"); return fb end
      end
    end
    if pass == 2 or (idx and clock - (J.resT or -100) < (J.cfg.resIndexEvery or 10.0)) then return nil end
    idx = {}; J.resT = clock
    for _, r in ipairs(FindAllOf("Resource") or {}) do
      if valid(r) then local ok, l = pcall(function() return r:K2_GetActorLocation() end); if ok and l then idx[resKey(l.X, l.Y)] = r end end
    end
    J.res = idx; bump("resource_index")
    local fl = {}; for _, r in ipairs(FindAllOf("FallenTreeBP_C") or {}) do if valid(r) then fl[#fl + 1] = r end end
    J.fallen = fl
  end
  return nil
end

-- the units on the board, by name. A game list is only read inside "for i = 1, #list".
--   J.list   the villagers of the player's town (looked at every cfg.stride frames)
--   J.rlist  the rival lords' villagers (cfg.rivals) and the oxen (cfg.oxen) (looked at every cfg.rstride frames)
local function build(S)
  local list, rlist, byKey, byAddr = {}, {}, {}, {}
  local la = S.p1:GetAddress()
  local function add(key, u, own)
    local addr = u:GetAddress()
    local old = J.byKey and J.byKey[key]
    local e = (old and old.addr == addr) and old or { key = key, addr = addr }
    e.u = u; e.own = own; byKey[key] = e; byAddr[addr] = e
    if own then list[#list + 1] = e else rlist[#rlist + 1] = e end
  end
  local regs = S.eng.regions
  for i = 1, #regs do
    local r = un(regs[i])
    if valid(r) then
      local own = got(function() return r.ownerPawn:GetAddress() == la end, false)
      if own or J.cfg.rivals then
        local wf = got(function() return r.workerFamilies end, nil)
        if wf then
          for f = 1, #wf do
            local m = wf[f].familyMembers
            for j = 1, #m do
              local u = un(m[j])
              if valid(u) then add(i .. "." .. f .. "." .. j, u, own) end
            end
          end
        end
      end
    end
  end
  if J.cfg.oxen then
    -- every ox, by the workplace whose oxen list holds it ("o"); then every other animal, by the building whose animals
    -- list holds it ("a": a stable, a burgage plot). Session 1 of lane 19 saw oxen led by villagers that are in a
    -- stable's animals list only, with no workplace. Which stable an animal lives in can differ between copies (lane 10).
    local bs = S.eng.buildingArr
    for pass = 1, 2 do
      local field, tag = pass == 1 and "oxen" or "animals", pass == 1 and "o" or "a"
      for i = 1, #bs do
        local b = un(bs[i])
        if valid(b) then
          local ox = got(function() return b[field] end, nil)
          if ox then
            local n = #ox
            if n > 0 then
              local bk = bkey(b)
              for j = 1, n do local u = un(ox[j]); if valid(u) and not byAddr[u:GetAddress()] then add(tag .. bk .. "#" .. j, u, false) end end
            end
          end
        end
      end
    end
  end
  -- (lane 46, round two) an animal that was on the board and is on no building's list now (its workplace or stable was
  -- demolished: l46s9, the host's ox still dragged its log, good 16, and no copy named it any more) keeps its key while
  -- it lives, on both copies alike, so its tasks and load stay the host's word
  -- (lane 47, round three) found again by its address in the engine's unit list, with a handle of this build; the old
  -- handle is never touched again. Carried by its old handle, the animal of a demolished small stable was called on
  -- (fillList) after the game had destroyed it and an engine clean-up had freed it: the friend's game closed inside
  -- the mod loader at speed 8 (lane 47 round three: hk_2, hl_1, key a97,94195,-74321#2)
  if J.byAddr then
    local want
    for a, e in pairs(J.byAddr) do
      if not byAddr[a] and (e.key:sub(1, 1) == "o" or e.key:sub(1, 1) == "a") and not byKey[e.key] then want = want or {}; want[a] = e.key end
    end
    if want then
      local t0 = os.clock()
      local ua = S.eng.unitArr
      for q = 1, #ua do
        local u = un(ua[q])
        if valid(u) then local a = u:GetAddress(); local k = want[a]; if k and not byAddr[a] and not byKey[k] then add(k, u, false); bump("animal_kept"); want[a] = nil end end
      end
      for _ in pairs(want) do bump("animal_lost") end
      bump("kept_scan_us", math.floor((os.clock() - t0) * 1e6))
    end
  end
  -- (lane 35, round six) a villager or animal no longer on the lists (dead, gone with its family): PICK lets go of it
  local old = J.byAddr; J.goneU = nil
  if old then for a in pairs(old) do if not byAddr[a] then J.goneU = J.goneU or {}; J.goneU[#J.goneU + 1] = a end end end
  J.list, J.rlist, J.byKey, J.byAddr, J.listT = list, rlist, byKey, byAddr, os.clock()
  if J.goneU and C.patch and C.patch.pickGone then pcall(C.patch.pickGone, J.goneU); J.chDirty = true; bump("gone_units_left", #J.goneU) end
end

-- a unit's task right now: count, type, target x (0 for a moving target), the live record
local function peek(u)
  local ts = u.Tasks; local n = #ts
  if n == 0 then return 0, -1, 0, nil end
  local t = ts[1]; local ty = tonumber(t.Type) or -1
  return n, ty, ty == FOLLOW and 0 or rnd(t.TargetLocation.Pos.X), t
end
local function identOf(t, ty)
  local tb, fb = t.targetBuilding, t.finalBuilding
  local s = ty .. "|" .. (valid(tb) and bkey(tb) or "-") .. "|" .. (valid(fb) and bkey(fb) or "-")
  if ty == FOLLOW then local tu = t.targetUnit; local x = valid(tu) and J.byAddr and J.byAddr[tu:GetAddress()]; s = s .. "|" .. (x and x.key or "-") end
  return s
end

-- ---------------------------------------------------------------- host: tell every task start
-- (lane 46) a place too large for %d stopped a host's start line once (l46d5: "bad argument #2 to 'format' (number has
-- no integer representation)", the target place's X): every place and the floors are checked for size in encTask
local function encPT(p) return string.format("%d,%d,%d,%d,%d", rnd(p.Pos.X), rnd(p.Pos.Y), rnd(p.Pos.Z), rnd(tonumber(p.floor) or 0), rnd(p.Rotation.Yaw)) end
-- (lane 54, round two) PLOT WORK NAMED. Since the merge of coop-mod a1d63485 / b31693ac the host cannot name 600 to 790
-- starts a sitting for "place" (a non-finite or huge value in the record; 0 to 1 a sitting on the earlier base, 600 to 860
-- in lane 49's earlier runs), nearly all of them the house plot's garden work (46 PloughManual, 11, 12): the friend's
-- villager stands or walks ("friend 17 or idle / host 46", 97 + 33 s of class b + c at speed 8 over t54b1..5). For those
-- types a start whose bad value is only in the final place, the entity place, a floor or a yaw is sent with 0 there
-- (as the plot's own named starts already are: final place 0,0,0); a bad target place or unit place still goes unnamed.
local PLOTPLACE = { [11] = true, [12] = true, [46] = true }
local function fin(v) v = tonumber(v) or 0; return v == v and v < 1e12 and v > -1e12 end
local function z(v) return fin(v) and rnd(v) or 0 end
local function encPlot(e, t, ty, tu, fu, res)
  local TL, FL, el, p = t.TargetLocation, t.finalLocation, t.targetEntityLocation, e.u.realPos
  if not (fin(TL.Pos.X) and fin(TL.Pos.Y) and fin(TL.Pos.Z) and fin(p.X) and fin(p.Y) and fin(p.Z)) then bump("plot_bad_tl"); return nil end
  local tb, fb = t.targetBuilding, t.finalBuilding
  local function pt(P) return string.format("%d,%d,%d,%d,%d", z(P.Pos.X), z(P.Pos.Y), z(P.Pos.Z), z(P.floor), z(P.Rotation.Yaw)) end
  local bad = false
  for k, v in pairs({ fl = { FL.Pos.X, FL.Pos.Y, FL.Pos.Z }, el = { el.X, el.Y, el.Z }, fy = { TL.Rotation.Yaw, FL.Rotation.Yaw }, ff = { TL.floor, FL.floor } }) do
    for _, x in ipairs(v) do if not fin(x) then bad = true; bump("plot_bad_" .. k); break end end
  end
  if bad then bump("plot_named") end
  return string.format("%s %d %d %d %s %s %s %s %s %s %s %d,%d,%d %d %d,%d,%d %s", e.key, ty, t.resourceType, t.resourceAmt, valid(tb) and bkey(tb) or "-", valid(fb) and bkey(fb) or "-",
    tu, fu, res, pt(TL), pt(FL), z(el.X), z(el.Y), z(el.Z), t.bPaidInAdvance and 1 or 0, z(p.X), z(p.Y), z(p.Z), e.hs or "0")
end
local function encTask(e, t, ty)
  if not GIVE[ty] then return nil, "type" .. ty end
  local function uref(o) if not valid(o) then return "-" end; local x = J.byAddr[o:GetAddress()]; return x and x.key or nil end
  local tu, fu = uref(t.targetUnit), uref(t.finalUnit)
  if not tu or not fu then return nil, ty == FOLLOW and "animal" or "unit" end
  if valid(t.targetBuildingPart) then return nil, "part" end
  local res = "-"; local ro = t.Resource
  if valid(ro) then
    local ok, l = pcall(function() return ro:K2_GetActorLocation() end); if not ok then return nil, "resource" end
    res = string.format("%d,%d,%d", rnd(l.X), rnd(l.Y), rnd(l.Z))
  end
  local tb, fb = t.targetBuilding, t.finalBuilding; local el = t.targetEntityLocation
  -- (lane 23) a place that is not a finite number (seen once a run on the host: "bad argument #13 to 'format'", the
  -- entity place) cannot be named: the start goes out as unnamed instead of failing in format
  -- (seen again in d4 at encPT: the target or final place) every place of the line is checked
  if PLOTPLACE[ty] and J.cfg.plotPlace ~= false then local okP, sP = pcall(encPlot, e, t, ty, tu, fu, res); if okP and sP then return sP end end   -- (lane 54, round two)
  local p0, TL, FL = e.u.realPos, t.TargetLocation, t.finalLocation
  for _, v in ipairs({ el.X, el.Y, el.Z, TL.Pos.X, TL.Pos.Y, TL.Pos.Z, TL.Rotation.Yaw, FL.Pos.X, FL.Pos.Y, FL.Pos.Z, FL.Rotation.Yaw, p0.X, p0.Y, p0.Z, tonumber(TL.floor) or 0, tonumber(FL.floor) or 0 }) do
    if v ~= v or v > 1e12 or v < -1e12 then return nil, "place" end   -- (lane 46) also a finite place too large for %d
  end
  local p = e.u.realPos
  return string.format("%s %d %d %d %s %s %s %s %s %s %s %d,%d,%d %d %d,%d,%d %s", e.key, ty, t.resourceType, t.resourceAmt, valid(tb) and bkey(tb) or "-", valid(fb) and bkey(fb) or "-",
    tu, fu, res, encPT(t.TargetLocation), encPT(t.finalLocation), rnd(el.X), rnd(el.Y), rnd(el.Z), t.bPaidInAdvance and 1 or 0, rnd(p.X), rnd(p.Y), rnd(p.Z), e.hs or "0")
end

local function hostOne(e)
  if J.cfg.handsTell then                                      -- (lane 23) its load changed: U L <unit> <load>
    local hs = handsOf(e.u)
    if hs ~= e.hs then e.hs = hs; local l = "U L " .. e.key .. " " .. hs; A.send(l); bump("sent_hands"); bump("bytes", #l + 20) end
  end
  local n, ty, tx, t = peek(e.u)
  if n == e.n and ty == e.ty and tx == e.tx then return end
  e.n, e.ty, e.tx = n, ty, tx
  if n == 0 or ty == LAZY then                                 -- its task ended (nothing to do, or the game's "Lazy")
    if ty == LAZY then bump("lazy") end
    if e.told then e.told = nil; A.send("U E " .. e.key); bump("sent_end"); bump("bytes", #e.key + 28) end
    e.retell = nil
    return
  end
  local line, why = encTask(e, t, ty)
  if line then
    -- (lane 23) a running task told again (a friend's hello or its question U Q) goes as U R: not a new start
    local k = e.retell and "U R " or "U S "; e.retell = nil
    A.send(k .. line); e.freeSent = nil; e.told = true; bump(k == "U R " and "sent_retell" or (e.own and "sent" or "sent_rival")); bump("bytes", #line + 24)
  else
    e.told = nil; e.retell = nil
    bump("unnamed_" .. why)
    if e.freeSent ~= ty then
      e.freeSent = ty; local p = e.u.realPos                   -- (lane 19) where the host's unit stands: a gated friend walks there
      local l = string.format("U F %s %d %d,%d,%d", e.key, ty, rnd(p.X), rnd(p.Y), rnd(p.Z))
      A.send(l); bump("sent_free"); bump("bytes", #l + 20)
    end
  end
end

-- one pass over a list: every unit once in `st` frames, at most `cap` units in one frame
local function each(list, st, cap, fn)
  local n = #list; if n == 0 then return end
  st = math.max(st, math.ceil(n / cap))
  for i = 1 + (J.tickN % st), n, st do
    local e = list[i]
    if valid(e.u) then local ok, er = pcall(fn, e); if not ok then bump("errors"); J.lastErr = tostring(er) end end
  end
end

-- ---------------------------------------------------------------- friend: the gate (coop_patch JOBGATE + the job list)
-- every job type of a unit or a building on this copy, and 0 (no workplace). Numbers only, appended; never read past #a.
local function fillList(S)
  local a = S.eng.disableJobIDs
  local have = {}; for i = 1, #a do have[a[i]] = true end
  local want = { [0] = true }
  -- (lane 47, round three) only units still valid (as every other use of the board's entries: each)
  for _, l in ipairs({ J.list or {}, J.rlist or {} }) do for _, e in ipairs(l) do if valid(e.u) then local j = got(function() return e.u:getJobType() end, -1); if j >= 0 then want[j] = true end end end end
  local bs = S.eng.buildingArr
  for i = 1, #bs do local b = un(bs[i]); if valid(b) then local j = got(function() return b:getJobType() end, -1); if j >= 0 then want[j] = true end end end
  local added = 0
  for j in pairs(want) do if not have[j] then a[#a + 1] = j; added = added + 1 end end
  return added, #S.eng.disableJobIDs
end
local function emptyList(eng)                                  -- the engine whose list this module filled
  if not valid(eng) then return 0 end
  local a = eng.disableJobIDs; local n = #a
  if n > 0 then a:Empty() end
  return n
end
-- (lane 23, part 3) CHOOSE: the villagers on a cyclic host task are named to coop_patch, whose hook lets the game's own
-- chooser run for them (and only them) while the list is full. The list is sent whole when it changes.
-- (lane 49, round four) ENDHOLD: every board villager on the host's task as the board gave it (e.given is the host's
-- ident) is named to coop_patch's ENDHOLD with that task's type and target building: this copy's game cannot end that
-- task by itself (its end is followed at once by the same task again, natively) until the host's end or next start
-- takes it off the list, at most cfg.endHoldCeil game seconds. The desk round: 73 / 74 % of the lasting seconds were
-- the same task, 40 / 43 % of them "ended first here, the villager stands". Not the Follow (GUIDE), not the game's own
-- "Lazy". cfg.endHold = false empties the list (for a measure's before only).
local function endHoldOff()
  if not J.ehOn then return end
  if C.patch and C.patch.endHoldSet then pcall(C.patch.endHoldSet, 1000, {}) end
  if C.patch and C.patch.endHold then pcall(C.patch.endHold, false) end
  J.ehOn = nil; J.ehSent = nil; bump("endhold_off")
end
local function endHoldStep(S)
  if not J.gateOn then endHoldOff(); return end
  if not J.ehOn then
    if os.clock() - (J.ehTry or -100) < 10.0 then return end
    J.ehTry = os.clock()
    if not (C.patch and C.patch.endHold and C.patch.endHold(true)) then bump("endhold_unavailable"); return end
    J.ehOn = true; J.ehSent = nil; log("jobs: endhold on: a board villager's task ends on the host's word")
  end
  local lst, sig = {}, {}
  local clock = os.clock(); J.ehRT = clock
  local sp = math.max(1.0, got(function() return S.eng.gameSpeed end, 1.0))
  local ceilG = J.cfg.endHoldCeil or 30.0
  -- (round five) J.cfg.endHoldSkip (console, a test's arm): task types kept off the list besides 23, e.g. { [59] = true }
  local skip = J.cfg.endHoldSkip
  if J.cfg.endHold ~= false then
    for _, e in ipairs(J.list or {}) do
      local h = e.host
      if h and not e.free and e.given == h.ident and e.addr then
        local ty = tonumber(h.rec.Type) or -1
        if skip and skip[ty] then ty = -1 end
        -- (round five) THE CEILING IS A SAFETY NET: while the host's start is the same one and the host speaks (the
        -- gate is on: it closes after cfg.quiet s of silence and empties this list), the entry's number changes every
        -- half ceiling, which the native piece takes as a new entry (its ceiling counts anew). So a villager is
        -- released at the ceiling only when this board stops renewing: the host silent, this mod stopped or hung. A
        -- start older than cfg.endHoldCap game seconds is held no longer (counted endhold_capped): a lost end of the
        -- host must not hold a villager for good.
        local age = (clock - (h.t or clock)) * sp
        local rn = 0
        if age > (J.cfg.endHoldCap or 600.0) then
          if not h.capped then h.capped = true; bump("endhold_capped") end
          ty = -1
        elseif J.cfg.endHoldRenew ~= false then rn = math.floor(age / (ceilG * 0.5)) % 256 end
        local f4 = (h.sq or 0) * 256 + rn
        -- not the tree work 23 (the gatherer's task on a felled tree): held after its end it works on or picks the
        -- log up, AHEAD of the host's villager (six sittings a side at speed 8: tree seconds 477 -> 934, load
        -- differing 93 -> 288). Not a unit whose felling (3) waits for its tree (lane 54's FELL owns it: by then the
        -- host has ended that felling, so e.given is no longer the host's ident; said here as well).
        -- (round five) 23 is held again: its yield is held by gatherHold below, so a held gatherer can no longer run
        -- ahead; cfg.endHold23 = false is round four's exclusion (with cfg.gatherHold = false: round four's board)
        if ty ~= FOLLOW and ty ~= LAZY and (ty ~= 23 or (J.cfg.endHold23 ~= false and J.cfg.gatherHold ~= false)) and ty >= 0 and not (J.fellP and J.fellP[e.key]) then
          local b = h.tbA or 0                                 -- the address taken at the host's start (no old handle touched)
          lst[#lst + 1] = { e.addr, ty, b, f4 }; sig[#sig + 1] = e.key .. ":" .. ty .. ":" .. tostring(b) .. ":" .. tostring(f4)   -- sq: the host's start number (its next start of the same task is held anew)
        end
      end
    end
  end
  table.sort(sig); local s = table.concat(sig, " ")
  local ceil = ceilG / sp * 1000
  if s ~= J.ehSent or math.abs(ceil - (J.ehCeil or 0)) > 1 then
    J.ehSent = s; J.ehCeil = ceil; C.patch.endHoldSet(ceil, lst); bump("endhold_lists"); bump("endhold_named", #lst)
  end
end
-- (lane 49, round five) ARRIVE HOLD: goods change hands on the host's word. The two tasks whose goods move at an
-- ARRIVAL: the fetch (22 MovingItemBetweenBuilding: at its source the villager takes the goods and the game turns the
-- task into the carry) and the carry (4 PickupGoods: at its building the load goes in). On a friend the villager often
-- arrives first: it then stood with the load while the host's still walked (the board's pick-up wait: 143 s of the 1134
-- lasting seconds of six sittings at speed 4, 85 of 493 at speed 8), or it walked the carry with empty hands, having
-- delivered first (carry "the host holds, the friend does not" 76 s). Lane 54's workHold does this for the stroke tasks
-- (25, 27: the stroke count held one short); here the villager is held on its WALK: within cfg.arriveR + cfg.arriveRs x
-- speed cm of the task's place, while the host's villager is on the same task and has not yet taken (22: the host's
-- hands empty) or not yet delivered (4: the host's hands full), its own walking Speed is cfg.arriveF of what it was, so
-- it stays on the task, a few metres short, with the hands the host's has. Its Speed comes back when the host's hands
-- change or the host's next start or end arrives, on another task, when the gate closes or the mod stops, after
-- cfg.arriveMax game seconds (counted arrive_back_over), or when a look has not confirmed the hold for 3 s.
-- J.arrB: per unit address its own Speed and the unit of the last look (checked valid in the frame it is written).
local ARRIVE = { [22] = true, [4] = true }
local function arriveRestore(a, why)
  local x = J.arrB and J.arrB[a]; if not x then return end
  J.arrB[a] = nil
  if valid(x.u) then pcall(function() x.u.Speed = x.b end) end
  bump("arrive_back_" .. why)
end
local function arriveAll(why) if J.arrB then for a in pairs(J.arrB) do arriveRestore(a, why) end; J.arrB = nil end end
local function arriveHold(e, u, n, ty, t, clock, speed)
  local a = e.addr; if not a then return end
  local x = J.arrB and J.arrB[a]
  local want = false
  local h = e.host
  if J.cfg.arriveHold ~= false and J.gateOn and n > 0 and ARRIVE[ty] and h and not e.free and not e.q and e.given == h.ident
     and tonumber(h.rec.Type) == ty and e.arrOver ~= h.sq then
    local hl = e.hl or "0"
    if (ty == 22 and hl == "0" and handsOf(u) == "0") or (ty == 4 and hl ~= "0") then
      local tp = t.TargetLocation.Pos; local p = u.realPos
      local R = (J.cfg.arriveR or 300) + (J.cfg.arriveRs or 120) * speed
      want = (p.X - tp.X) ^ 2 + (p.Y - tp.Y) ^ 2 < R * R
    end
  end
  if want then
    if not x then
      local b = tonumber(u.Speed) or 0; if b <= 0 then return end
      x = { b = b, u = u, t0 = clock, t = clock }; J.arrB = J.arrB or {}; J.arrB[a] = x
      if not pcall(function() u.Speed = b * (J.cfg.arriveF or 0.002) end) then J.arrB[a] = nil; return end
      bump("arrive_held_" .. ty)
    elseif (clock - x.t0) * speed > (J.cfg.arriveMax or 600.0) then e.arrOver = h.sq; arriveRestore(a, "over"); return
    end
    x.u = u; x.t = clock
  elseif x then arriveRestore(a, "go") end
end
-- (lane 49, round five) GATHER HOLD: lane 54's workHold (its text above friendOne) for the third stroke task with a
-- yield, 23 Gathering (fish, firewood, berries, a felled tree's logs: targetRepetitions 4, read on a running copy; the
-- goods come into the hands at the last stroke). While the host's villager is on the same gathering with empty hands,
-- this copy's villager's stroke count is written back one short of the end, so it does not take the goods first
-- ("friend 23 with the load / host 23": 39 and 33 s of the six after-sittings v5a at speed 4 and 8); the host's yield
-- arrives as its load (U L), and the hold ends. Kept apart from workHold (lane 54's block): its own switch and count.
local function gatherHold(e, u, n, ty)
  if J.cfg.gatherHold == false or ty ~= 23 or n == 0 or not (e.host and J.gateOn) then return end
  if tonumber(e.host.rec.Type) ~= 23 or (e.hl or "0") ~= "0" or e.given ~= e.host.ident then return end
  local tg = got(function() return u.targetRepetitions end, 0); if tg < 3 then return end
  local r = got(function() return u.repetitions end, 0)
  if r >= tg - 1 and r < tg + 50 then
    local ok = pcall(function() u.repetitions = tg - 2 end)
    bump(ok and "gather_held" or "errors")
  end
end
local function arriveSweep(clock)                              -- every friend tick: a hold no look confirmed for 3 s (at speed 8 a look can be over a second apart: 160 false "lost" in sitting p2)
  for a, x in pairs(J.arrB) do if clock - x.t > 3.0 then arriveRestore(a, "lost") end end
  if next(J.arrB) == nil then J.arrB = nil end
end
local function chooseOff()
  pcall(arriveAll, "off")                                      -- (lane 49, round five)
  pcall(endHoldOff)
  if not J.chOn then return end
  if C.patch and C.patch.chooseSet then pcall(C.patch.chooseSet, {}) end
  if C.patch and C.patch.choose then pcall(C.patch.choose, false) end
  if J.pkOn then                                               -- (lane 35) PICK goes with CHOOSE
    if C.patch and C.patch.pickSet then pcall(C.patch.pickSet, {}) end
    if C.patch and C.patch.pick then pcall(C.patch.pick, false) end
    J.pkOn = nil; J.pkSent = nil
  end
  J.chOn = nil; J.chSet = nil; J.chSent = nil; bump("choose_off")
end
local function chooseStep(S, clock)
  if not (J.cfg.choose and J.gateOn) then chooseOff(); return end
  if not J.chOn then
    if clock - (J.chTry or -100) < 10.0 then return end
    J.chTry = clock
    if not (C.patch and C.patch.choose) then J.chWhy = "no patch module"; return end
    local ok, msg = C.patch.choose(true)
    if not ok then J.chWhy = msg; bump("choose_unavailable"); return end
    J.chOn = true; J.chSent = nil; log("jobs: choose on (%s): the game's chooser runs for the villagers on a cyclic host task", tostring(msg))
  end
  if J.ehOn and clock - (J.ehRT or 0) > 1.0 then J.chDirty = true end   -- (lane 49, round five) the end hold's renewal
  if not J.chDirty and clock - (J.chT or 0) < J.cfg.refresh then return end
  J.chDirty = nil; J.chT = clock
  local set, addrs, keys = {}, {}, {}
  for _, l in ipairs({ J.list or {}, J.rlist or {} }) do for _, e in ipairs(l) do
    if e.host and not e.free and CYCLE[tonumber(e.host.rec.Type) or -1] and valid(e.u) then set[e.key] = true; addrs[#addrs + 1] = e.addr; keys[#keys + 1] = e.key end
  end end
  table.sort(keys); local sig = table.concat(keys, " ")
  J.chSet = set
  if sig ~= J.chSent then J.chSent = sig; C.patch.chooseSet(addrs); bump("choose_lists"); bump("choose_named", #addrs) end
  pcall(endHoldStep, S)                                        -- (lane 49, round four)
  -- (lane 35, item 1) PICK: for the villagers whose host task is in BACK (selling, mining, an ox) the chooser may start
  -- only that task (type; for an ox, that ox); any other pick gets the board's last record of it (coop_patch PICK)
  if not J.cfg.pick and J.pkOn then                             -- switched off (console): the list emptied, the hooks out
    pcall(C.patch.pickSet, {}); pcall(C.patch.pick, false); J.pkOn = nil; J.pkSent = nil
  end
  if J.cfg.pick then
    if not J.pkOn then
      if clock - (J.pkTry or -100) < 10.0 then return end
      J.pkTry = clock
      if not (C.patch and C.patch.pick) then return end
      local ok, msg = C.patch.pick(true)
      if not ok then J.pkWhy = msg; bump("pick_unavailable"); return end
      J.pkOn = true; J.pkSent = nil; log("jobs: pick on (%s): the chooser starts only the host's task for selling, mining, the ox", tostring(msg))
    end
    local lst, pk = {}, {}
    for _, l in ipairs({ J.list or {}, J.rlist or {} }) do for _, e in ipairs(l) do
      local ty = e.host and tonumber(e.host.rec.Type) or -1
      if set[e.key] and BACK[ty] then
        local tu = 0
        if ty == FOLLOW then tu = got(function() local x = e.host.rec.targetUnit; return valid(x) and x:GetAddress() or 0 end, 0) end
        lst[#lst + 1] = { e.addr, ty, tu }; pk[#pk + 1] = e.key .. ":" .. ty .. ":" .. tostring(tu)
      end
    end end
    table.sort(pk); local psig = table.concat(pk, " ")
    if psig ~= J.pkSent then J.pkSent = psig; C.patch.pickSet(lst); bump("pick_lists") end
  end
end

-- (lane 35, round six) objects leaving the game (a demolished building; villagers and animals no longer on the board's
-- lists): every unit whose host task, waiting task or carry names one forgets it (it leaves the CHOOSE and PICK lists),
-- PICK drops every entry and kept record that names one (coop_patch PICK GONE), and both lists are sent again NOW,
-- before the game removes the object. A friend's game closed inside the job chooser 10 s after the host demolished a
-- listed villager's workplace (the lead's run pick_run, 2026-11-13).
local GREF = { "targetBuilding", "finalBuilding", "targetUnit", "finalUnit", "Resource" }
function J.gone(objs, why)
  local addrs, set = {}, {}
  for _, o in ipairs(objs) do local a = got(function() return o:GetAddress() end, nil); if a and not set[a] then set[a] = true; addrs[#addrs + 1] = a end end
  if #addrs == 0 then return 0 end
  local function names(rec) if not rec then return false end
    for _, k in ipairs(GREF) do local x = rec[k]; if x ~= nil and set[got(function() return x:GetAddress() end, -1)] then return true end end
    return false end
  local n = 0
  for _, l in ipairs({ J.list or {}, J.rlist or {} }) do for _, e in ipairs(l) do
    local hit = set[e.addr] or (e.host and names(e.host.rec)) or (e.q and names(e.q.rec))
    if not hit and valid(e.u) then hit = set[got(function() local w = e.u:getWorkplace(); return valid(w) and w:GetAddress() or -1 end, -1)] end
    if hit then e.host = nil; e.q = nil; e.pend = nil; e.free = true; n = n + 1 end
    if e.carry then for g, c in pairs(e.carry) do if names(c.rec) then e.carry[g] = nil end end end
  end end
  if J.carryTo then for k, c in pairs(J.carryTo) do if names(c.rec) then J.carryTo[k] = nil end end end
  if C.patch and C.patch.pickGone then pcall(C.patch.pickGone, addrs) end
  -- (lane 46) GOODS / DIST let go of it, and the stock writer (coop_facts same()) never writes into it again
  if why == "demolish" or why == "demolish_own" then
    if C.patch and C.patch.goodsGone then pcall(C.patch.goodsGone, addrs) end
    C.goneB = C.goneB or {}; local now = os.clock()
    for a, t in pairs(C.goneB) do if now - t > 60 then C.goneB[a] = nil end end
    for _, a in ipairs(addrs) do C.goneB[a] = now end
  end
  bump("gone_" .. tostring(why or "?")); bump("gone_units", n)
  J.chDirty = true; J.chT = -100
  if C.s and C.s.role == "friend" and J.gateOn then pcall(chooseStep, C.s, os.clock()) end   -- the lists without them, now
  local t = os.clock(); J.raDue = { t + 0.5, t + 1.5, t + 4.0 }                     -- the region-set audit soon after the demolish
  return n
end
-- (lane 35, round six) THE CAUSE OF THE CHOOSER CRASH (read in the game file, coop_patch README "REGSET"): the job chooser
-- walks two building sets of the villager's region and reads each member's stock. The game takes a demolished
-- building out of them only through the building's region; on a friend a demolished building has none (the lead's
-- notes), so it stays a member, is freed later, and the chooser reads freed memory. Every cfg.regAuditEvery seconds,
-- and 0.5, 1.5 and 4 s after a demolish, every region's sets are listed and a member that is no longer a building of
-- the engine (eng.buildingArr) is taken out with the game's own set removal (counter regset_dropped).
-- (lane 35, round seven) test probe, either copy: how many members of the regions' building sets are no building of
-- the engine right now (nothing dropped). Returns "<total> r<i>=<n> ..." or "unavailable".
function J.regCount()
  local S = C.s; if not (S and C.patch and C.patch.regsetClean) then return "unavailable" end
  local alive = {}
  local arr = S.eng.buildingArr
  for i = 1, #arr do local b = un(arr[i]); if valid(b) then local a = got(function() return b:GetAddress() end, nil); if a then alive[a] = true end end end
  local regs = S.eng.regions; local tot, out = 0, {}
  for i = 1, #regs do local r = un(regs[i]); if valid(r) then local n, l = C.patch.regsetClean(r:GetAddress(), alive, true); if n == nil then return "unavailable" end; if n > 0 then out[#out + 1] = "r" .. i .. "=" .. n .. ":" .. table.concat(l or {}, ",") end; tot = tot + n end end
  return tostring(tot) .. " " .. table.concat(out, " ")
end
function J.regAudit(S, clock)
  if not J.cfg.regAudit or not (C.patch and C.patch.regsetClean) then return end
  local due = clock - (J.raT or -100) >= (J.cfg.regAuditEvery or 5.0)
  if not due and J.raDue then for i, t in ipairs(J.raDue) do if clock >= t then table.remove(J.raDue, i); due = true; break end end end
  if not due then return end
  J.raT = clock
  local alive = {}
  local arr = S.eng.buildingArr
  for i = 1, #arr do local b = un(arr[i]); if valid(b) then local a = got(function() return b:GetAddress() end, nil); if a then alive[a] = true end end end
  local regs = S.eng.regions
  for i = 1, #regs do
    local r = un(regs[i])
    if valid(r) then
      local n = C.patch.regsetClean(r:GetAddress(), alive)
      if n == nil then bump("regset_unavailable"); return end
      if n > 0 then bump("regset_dropped", n); log("jobs: %d member(s) of region %d's building sets were no building of the engine any more: taken out", n, i) end
    end
  end
  bump("regset_audits")
end

local function gateClose(S, why)                               -- the plain game again: the list first, then the byte
  if not J.gateOn then return end
  chooseOff()
  local n = got(function() return emptyList(J.gateEng) end, -1)
  local ok, msg = false, "no patch module"
  if C.patch and C.patch.jobGate then ok, msg = C.patch.jobGate(false) end
  J.gateOn = nil; bump("gate_closed")
  log("jobs: gate closed (%s): job list emptied (%s ids), %s", why, tostring(n), tostring(msg))
end
J.gateClose = function(why) gateClose(C.s, why or "console") end
local function gateStep(S, clock)
  local want = J.cfg.on and J.cfg.gate and S.role == "friend" and not C.hold and clock - (J.lastU or -1e9) < J.cfg.quiet
  if not want then
    if J.gateOn then gateClose(S, not (J.cfg.on and J.cfg.gate) and "switched off" or (C.hold and "a load" or "the host is quiet")) end
    return
  end
  if J.gateOn then
    if clock - (J.gateT or 0) > J.cfg.refresh then J.gateT = clock; local add = fillList(S); if add > 0 then bump("gate_ids_added", add) end end
    return
  end
  if clock - (J.gateTry or -100) < 10.0 then return end      -- not available: tried again every 10 s (status file)
  J.gateTry = clock
  if not (C.patch and C.patch.jobGate) then J.gateWhy = "no patch module"; return end
  local ok, msg = C.patch.jobGate(true)
  if not ok then J.gateWhy = msg; bump("gate_unavailable"); return end
  J.gateOn = true; J.gateT = clock; J.gateEng = S.eng
  local add, n = fillList(S)
  bump("gate_opened")
  log("jobs: gate on (%s): %d job ids in the list; this copy's villagers choose nothing, the host's starts are given", tostring(msg), n)
end

-- ---------------------------------------------------------------- friend: give what the host says
local function decPT(s)
  local x, y, z, fl, yaw = (s or ""):match("^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$"); if not x then return nil end
  return { Pos = { X = x + 0.0, Y = y + 0.0, Z = z + 0.0 }, floor = math.tointeger(tonumber(fl)) or 0, Rotation = { Pitch = 0.0, Yaw = yaw + 0.0, Roll = 0.0 } }
end
-- may this copy's unit be put at the host's unit's place now? Not when the local player could see it happen.
local function seen(S, u, p, h)
  local p1 = S.p1
  J.placeVis = nil
  if got(function() local hv = p1.hoverUnit; return valid(hv) and hv:GetAddress() == u:GetAddress() end, false) then return "hover" end
  local sel = got(function() local a = p1.selectedArr; local n = #a; for i = 1, n do local x = un(a[i]); if valid(x) and x:GetAddress() == u:GetAddress() then return true end end; return false end, false)
  if sel then return "selected" end
  local c = got(function() return p1.Camera:K2_GetComponentLocation() end, nil)
  if not c then return "no camera" end
  local lim = J.cfg.placeSeen
  local function near(q) local dx, dy, dz = q.X - c.X, q.Y - c.Y, q.Z - c.Z; return dx * dx + dy * dy + dz * dz < lim * lim end
  if near(p) or near(h) then return "camera" end
  -- (lane 49, round five) ON THE SCREEN: the distance rule above never fired with the camera over the town (measured:
  -- the camera 114 m from a villager in the middle of the picture; 0 skips in every sitting), so villagers jumped in
  -- the player's view. Neither the old nor the new place may lie in the picture (the game's own projection, a tenth
  -- of the picture as margin). No controller or no picture size: only the distance rule.
  local scr = got(function()
    local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(p1, 0)
    if not valid(pc) then return nil end
    local a, b = {}, {}; pc:GetViewportSize(a, b)
    local vw, vh = tonumber(a.SizeX or a[1]) or 0, tonumber(b.SizeY or b[1]) or 0
    if vw < 16 or vh < 16 then return nil end
    local mx, my = vw * 0.1, vh * 0.1
    local function on(q)
      local o = {}
      if not pc:ProjectWorldLocationToScreen({ X = q.X, Y = q.Y, Z = q.Z }, o, false) then return false end
      local x, y = tonumber(o.X), tonumber(o.Y); if not (x and y) then return false end
      return x > -mx and x < vw + mx and y > -my and y < vh + my
    end
    return on(p) or on(h)
  end, nil)
  if scr == nil then bump("place_screen_unknown") end
  if scr then
    if J.cfg.placeScreen ~= false then return "screen" end
    J.placeVis = true                                          -- the rule switched off (a test's before): counted when placed
  end
  return nil
end
local function place(S, e, h)
  if not (J.cfg.place and h) then return end
  local u = e.u; local rp = u.realPos; local p = { X = rp.X, Y = rp.Y, Z = rp.Z }   -- a copy: the struct is read live
  local dx, dy = h.X - p.X, h.Y - p.Y
  if dx * dx + dy * dy < J.cfg.placeFar * J.cfg.placeFar then return end
  local why = seen(S, u, p, h)
  if why then bump("place_not_" .. why); return end
  -- (lane 23, gap f) only a unit that stands: a walking one keeps its planned path and was seen back at its old place
  -- (lane 19: 86 of 456 within 8 s; lane 23 v2: 90 of 657)
  if J.cfg.placeStanding and got(function() return u.realSpeed end, 0) > 10 then bump("place_not_walking"); return end
  local ok = pcall(function()
    u.realPos = { X = h.X, Y = h.Y, Z = h.Z }
    u:K2_SetActorLocation({ X = h.X, Y = h.Y, Z = h.Z }, false, {}, true)
  end)
  if J.placeVis then J.placeVis = nil; if ok then bump("placed_in_view") end end
  if ok then bump("placed"); bump("placed_m", math.floor(math.sqrt(dx * dx + dy * dy) / 100)); e.pchk = { t = os.clock(), x = h.X, y = h.Y, ox = p.X, oy = p.Y, lx = h.X, ly = h.Y } else bump("place_failed") end
end
-- (lane 49, cause 1) GUIDE. The game links a guide to its ox in a field of the villager that is not reflected (+330h,
-- coop_patch GUIDE): its own guide assignment writes it before the Follow, and the Follow ends at once when it is not
-- this ox (4dd72e0); the ox waits for the first unit of its region that holds it. The board's Follow (the reflected
-- setTask) does not write it, so on a friend a Follow of the host's leader ended at every give while another villager
-- of this copy (its own guide choice) held the ox (lasting "friend idle / host 41", up to 60 s a run). After the board
-- gives the host's Follow, the leader holds the ox and every other villager on the board lets go of it, as the host's
-- game did; the label is the game's ("task_guideOx"). (The game clears every +330h naming a unit it destroys:
-- Engine::destroyUnit, so nothing written here outlives the ox.) cfg.guide = false (console only) for a test's before.
local function villagerAddrs()
  if J.vaFor ~= J.listT then
    local a = {}
    for _, l in ipairs({ J.list or {}, J.rlist or {} }) do for _, x in ipairs(l) do if x.key:match("^%d") then a[#a + 1] = x.addr end end end
    J.va, J.vaFor = a, J.listT
  end
  return J.va
end
local function guideGive(e, rec)
  if not (J.cfg.guide ~= false and J.gateOn and C.patch and C.patch.guideSet) then return end
  local ox = rec.targetUnit; if not valid(ox) then return end
  local ok = C.patch.guideSet(ox:GetAddress(), e.addr, villagerAddrs())
  if ok then bump("guide_set") else bump("guide_unavailable") end
  if J.guideFN == nil then J.guideFN = got(function() return FName("task_guideOx") end, false) end
  if J.guideFN then pcall(function() e.u.taskLabelOverride = J.guideFN end) end
end
-- (lane 54) FELL: the host's tree falls on a friend at the host's moment. A felling (task 3) does not end at a stroke
-- count: each stroke takes 5.0 from what is left of the tree (a record in its region's list, not reflected; coop_patch
-- FELL) and the tree falls at the first stroke after that is no longer above 0. Each copy's woodcutter reaches its tree
-- at its own moment, so on a friend the tree still stood when the host's fell; the host's next start then cut the
-- felling after cfg.grace (or its U E stood it down) and the tree never fell here: the host's gatherers then worked a
-- felled tree this copy has not got (lane 49: 5 of 104 host falls never on the friend; "friend idle or walking / host
-- 23" the largest class-c cause). At the host's end of a felling (its next start of another task, U F or U E) a friend's
-- unit still on that felling gets the tree's rest set to 0: its next stroke fells it by the game's own code. A unit
-- still walking to its tree has no record yet (lane 49 r4b1 3.14.1: 20 m off when the host's fell; the host's gather
-- start then found no felled tree here and walkThere ended the felling: the tree never fell): until its tree has
-- fallen here (its felling ends) the felling is not cut by the board (every give and walkThere waits; the host's
-- latest start is queued and given at the felling's end) and FELL is sent again every 0.2 s, at most cfg.fellWait game s.
-- Coop.jobs.cfg.fell = false (console only) gives the before of a test.
local function fellRegion(t)
  local b = t.targetBuilding; if not bHere(b) then return nil end
  local rg = got(function() return b:GetRegion() end, nil); if not valid(rg) then return nil end
  return rg:GetAddress()
end
local function fellAtHostEnd(w, clock)
  if J.cfg.fell == false or not (C.patch and C.patch.fell) then return end
  local e = J.byKey and J.byKey[w[5]]; local h = e and e.host
  if not h or tonumber(h.rec.Type) ~= 3 then return end
  local el = h.rec.targetEntityLocation
  if (w[4] == "S" or w[4] == "R") and tonumber(w[6]) == 3 then           -- the same felling told again: not its end
    local ex, ey = (w[16] or ""):match("^(%-?%d+),(%-?%d+),")
    if ex and math.abs(tonumber(ex) - el.X) < 2 and math.abs(tonumber(ey) - el.Y) < 2 then return end
  end
  local u = e.u; if not valid(u) then return end
  local n, ty, _, t = peek(u)
  if n == 0 or ty ~= 3 then bump("fell_not_felling"); return end
  local te = t.targetEntityLocation
  if math.abs(te.X - el.X) > 2 or math.abs(te.Y - el.Y) > 2 then bump("fell_other_tree"); return end
  local rg = fellRegion(t); if not rg then bump("fell_no_region"); return end
  J.fellP = J.fellP or {}
  J.fellP[e.key] = { x = te.X, y = te.Y, t0 = clock, tl = clock }
  bump(C.patch.fell(rg, te.X, te.Y) and "fell_sent" or "fell_unavailable")
end
-- every friend tick: each pending felling still on its tree gets FELL again (0.2 s); one whose felling ended is done
local function fellTick(clock, speed)
  for k, p in pairs(J.fellP) do
    local e = J.byKey and J.byKey[k]; local u = e and e.u; local done = not (u and valid(u))   -- (never a handle kept from an earlier list)
    local n, ty, tx, t
    if not done then n, ty, tx, t = peek(u); done = n == 0 or ty ~= 3 or math.abs(t.targetEntityLocation.X - p.x) > 2 or math.abs(t.targetEntityLocation.Y - p.y) > 2 end
    if done then
      -- the board's next look sees the end and gives the queued start (after_prev); the felled tree: the index again
      J.fellP[k] = nil; bump("fell_done"); bump("fell_done_ms", math.floor((clock - p.t0) * 1000)); J.resT = nil
    elseif (clock - p.t0) * speed > (J.cfg.fellWait or 30.0) then J.fellP[k] = nil; bump("fell_timeout")
    elseif clock - p.tl >= 0.2 then
      p.tl = clock; local rg = fellRegion(t); if rg then C.patch.fell(rg, p.x, p.y); bump("fell_again") end
    end
  end
  if next(J.fellP) == nil then J.fellP = nil end
end
-- give() and walkThere() ask this first: a unit whose felling waits for its tree gets nothing else; a start of the
-- host is kept as the queued one (given when the felling ends), a "stand here" is dropped
local function fellHolds(e, q)
  local p = J.fellP and J.fellP[e.key]; if not p then return false end
  if q and not q.hold and not q.again then e.q = { rec = q.rec, ident = q.ident, t = q.t or os.clock(), hp = q.hp, carry = q.carry } end
  if q and not q.hold and q.again and e.host then e.q = { rec = e.host.rec, ident = e.host.ident, t = e.host.t or os.clock(), hp = e.host.hp } end
  bump("fell_held"); return true
end
-- (lane 54, round two) THE TRADER. Its trip is 59 MountHorse > 60 CollectStock > 61 TradeStock (out and back) > 4
-- unloading. The game ends a 60 or 61 at once on a trader that is not mounted (watch w1: the host's 60 given to an
-- unmounted friend's trader ended within 0.4 s; once mounted, every 60 and 61 given held). The board never gave 59
-- (not in GIVE), so after a dismount the friend's trader stood (7 to 9 s a speed-4 phase), its given leg ended, and its
-- own chooser (the trader is on CHOOSE) took its own 60 / 61, often another good to another market for minutes
-- ("chosen_own_61", up to 282 s). Now: 59 is given from the host's word; a 60 or 61 for a trader that is not mounted
-- first gives the host's last 59 of that unit (the leg waits as the queued one; while it mounts nothing else is given);
-- and while the host's trader is on 59 / 60 / 61, this copy's chooser's own other leg is replaced by the host's (at
-- most every 2 game s, for at most cfg.tradeHold game s after the host's start). (Lane 23 gave every leg back with the
-- trader unmounted: the legs ended at once and it fell to 75 %.) Coop.jobs.cfg.trader = false (console) for a before.
local TRIP = { [59] = true, [60] = true, [61] = true }
local function mounted(u) local m = got(function() return u.mountActor end, nil); return m ~= nil and valid(m) end
-- (lane 59) A TASK RECORD BELONGS TO THE WORLD IT WAS MADE IN. A record made from a host line holds game objects (its
-- target and final building, target and final unit, resource) as handles of the world it was made in. Kept past a load
-- (a join, a resync, a rejoin) those name freed memory; valid() cannot tell (the address may hold another object by
-- then), and setTask with such a record closes the game inside the game's setTask (4dd38c3 <- 4e1cc41), where 4 of
-- lane 58's 6 friend closes were, each within 6 s of a friend-alone load. The record that outlived its world was the
-- trader's mount record (J.mnt, never emptied: lane 54 round two); every other kept record went with the board's
-- entries in fresh(). Now: each record is stamped with its world (RW, weak keys: nothing is added to the record the
-- game reads), every setTask of a kept record asks stale() first and refuses (counted stale_*_refused, one log line
-- each), and fresh() drops every table that holds an object or a record.
local RW = setmetatable({}, { __mode = "k" })
-- (the number is the core's S.loads: it counts loaded worlds, not C.setRole's attach of the same world again)
local function stamp(rec) RW[rec] = C.s.loads; return rec end
local function stale(rec) local w = RW[rec]; return w ~= nil and w ~= C.s.loads end
local REFS = { "targetBuilding", "finalBuilding", "targetUnit", "finalUnit", "Resource" }
local function traderHolds(e, q, clock)
  if J.cfg.trader == false or not q or q.hold or not q.rec then return false end
  local ty = tonumber(q.rec.Type)
  if ty == 59 then J.mnt = J.mnt or {}; J.mnt[e.key] = { rec = q.rec, ident = q.ident }; return false end
  if (ty ~= 60 and ty ~= 61) or mounted(e.u) then return false end
  local m = J.mnt and J.mnt[e.key]; if not m then bump("trader_no_mount_record"); return false end
  -- (lane 59) the mount record of an earlier world, or one whose horse or building has gone since: dropped, never
  -- given (the leg is then given as to a trader with no mount record; the host's next 59 makes a new one)
  if stale(m.rec) then
    J.mnt[e.key] = nil; bump("stale_mount_refused")
    log("jobs: refused the mount record of loaded world %s for %s in loaded world %s (kept past a load: its objects are gone)", tostring(RW[m.rec]), e.key, tostring(C.s.loads))
    return false
  end
  for _, k in ipairs(REFS) do if m.rec[k] ~= nil and not refHere(k, m.rec[k]) then J.mnt[e.key] = nil; bump("mount_record_gone"); return false end end
  e.q = { rec = q.rec, ident = q.ident, t = q.t or clock, hp = q.hp }        -- the leg, given after the mount
  local n, cty = peek(e.u)
  if n > 0 and cty == 59 then bump("trader_mounting"); return true end     -- it is mounting: the leg waits
  if handsOf(e.u) ~= "0" then pcall(setHands, e.u, "0"); bump("trader_mount_cleared") end   -- a mount needs empty hands
  if C.traceF then C.trace("jobs setTask mount " .. e.key) end
  local ok = pcall(function() e.u:setTask(m.rec) end)
  if ok then e.given = m.ident; e.givenT = clock; e.isHold = nil; local n2, ty2, tx2 = peek(e.u); e.n, e.ty, e.tx = n2, ty2, tx2; bump("trader_mount") else bump("errors") end
  return true
end
-- (lane 52, round 3) a villager who is a soldier of a called-up unit right now (the game's own isSoldier) gets no task
-- from the board and is never put at a host unit's place: his place is his squad's. fin2, the end of the rival battle:
-- one man of the player's militia stood 1159 m from his place, at the village (his way began there; the men module's
-- table held him at the battlefield), 2 s after the squad halted; the unit's centre read 18 m off for 37 s while he ran
-- back. In that minute the board put 40 units outright (7354 m in all). p1: a rival militia man with a board task of
-- type 17 (the board's "stay here"). The board names a villager by region.family.member; who gave this man a villager's
-- start is not traced (the friend's full log of that sitting is gone). Counted: skip_soldier in the jobs line.
local function soldierNow(e) return J.cfg.soldiers ~= true and got(function() return e.u:isSoldier() end, false) == true end
local function give(e, q, clock)
  if stale(q.rec) then                                         -- (lane 59) a record of an earlier world: dropped, never given
    e.q = nil; e.host = nil; bump("stale_record_refused")
    log("jobs: refused a record of loaded world %s for %s in loaded world %s (ident %s)", tostring(RW[q.rec]), e.key, tostring(C.s.loads), tostring(q.ident))
    return false
  end
  if soldierNow(e) then e.q = nil; e.host = nil; bump("skip_soldier"); return false end
  if J.fellP and fellHolds(e, q) then return false end          -- (lane 54) a felling waits for its tree here
  if traderHolds(e, q, clock) then return false end            -- (lane 54, round two) a trade leg waits for the mount
  local why = J.why; J.why = nil                              -- (lane 23) the reason of this give, for the give log
  -- A record may have waited (at most cfg.grace game seconds): a building demolished or a felled tree used up in that
  -- time must not reach the game.
  for _, k in ipairs(REFS) do if q.rec[k] ~= nil and not refHere(k, q.rec[k]) then e.q = nil; e.host = nil; bump("skip_gone"); return false end end
  if not q.hold and not q.again then place(C.s, e, q.hp) end
  if C.traceF then C.trace("jobs setTask give " .. e.key .. " " .. tostring(q.ident)) end
  local ok, er = pcall(function() e.u:setTask(q.rec) end)
  e.q = nil
  if not ok then bump("errors"); J.lastErr = tostring(er); return false end
  if tonumber(q.rec.Type) == FOLLOW then pcall(guideGive, e, q.rec) end   -- (lane 49) the leader holds the ox
  -- (lane 23, diagnosis) test only: every give, one line, when J.giveLog is an open file (set from the console)
  if J.giveLog then pcall(function() J.giveLog:write(string.format("G\t%.3f\t%s\t%s\t%s\t%s\n", A.now(), e.key, tostring(q.rec.Type), q.hold and "hold" or (q.again and "again" or "given"), why or "-")) end) end
  e.given = q.ident; e.givenT = clock; e.isHold = q.hold or nil
  local n, ty, tx = peek(e.u); e.n, e.ty, e.tx = n, ty, tx
  if not q.hold then local gt = tonumber(q.rec.Type) or -1; e.gty = gt; bump("give_" .. gt) end
  bump(q.hold and "held" or (q.again and "given_again" or (e.own and "given" or "given_rival")))
  return true
end
-- The host's unit is still on its task and this copy's unit lost it (no material in this copy's workshop, the stall
-- empty here ...) while it stands at the task's place: the same task once more, so it keeps working there.
local function again(e, u, clock, speed)
  local h = e.host; if not h or not J.cfg.again then return false end
  if clock - (e.againT or -100) < 2.0 / speed then return false end
  local r = h.rec; local p = u.realPos; local tp = r.TargetLocation.Pos
  if math.abs(p.X - tp.X) > 500 or math.abs(p.Y - tp.Y) > 500 then return false end
  for _, k in ipairs(REFS) do if r[k] ~= nil and not refHere(k, r[k]) then e.host = nil; bump("again_gone"); return false end end
  e.againT = clock
  return give(e, { rec = r, ident = h.ident, again = true }, clock)
end
local function walkRec(e, p)
  local function P() return { Pos = { X = p.X, Y = p.Y, Z = p.Z }, floor = got(function() return e.u.floor end, 0), Rotation = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 } } end
  return { Type = 17, TargetLocation = P(), finalLocation = P(), targetEntityLocation = { X = p.X, Y = p.Y, Z = p.Z }, resourceType = 0, resourceAmt = 0, executed = false, ID = -1, bPaidInAdvance = false }
end
local function holdHere(e, clock)
  local p = e.u.realPos
  return give(e, { hold = true, ident = "17|-|-", rec = walkRec(e, { X = p.X, Y = p.Y, Z = p.Z }) }, clock)
end
-- (lane 46) a pickup wait is on: this unit's fetch reached its goods before the host's unit did and it stands there
-- with the load until the host's carry starts (cfg.pickWait wall seconds at speed 4, less above)
local function pwOn(e, clock) return e.pw ~= nil and clock - e.pw.t < (J.cfg.pickWait or 0) * (J.lagF or 1) end
-- (lane 19) with the gate on, a unit whose host task cannot be given here (no such resource, an unnamed animal ...)
-- would stand where it is: it walks to the place the host's unit is going to (or stands) instead
local function walkThere(e, p, clock)
  if J.fellP and J.fellP[e.key] then return end                  -- (lane 54) a felling waits for its tree here
  if not (J.gateOn and p) then return end
  if soldierNow(e) then bump("skip_soldier"); return end           -- (lane 52, round 3) see give()
  local u = e.u; local q = u.realPos
  if (q.X - p.X) ^ 2 + (q.Y - p.Y) ^ 2 < 300 * 300 then return end
  if got(function() return #u.Inventory end, 1) > 0 then return end
  if C.traceF then C.trace("jobs setTask walk " .. e.key) end
  local ok = pcall(function() u:setTask(walkRec(e, p)) end)
  if ok then e.given = "17|-|-"; e.givenT = clock; e.isHold = nil; local n, ty, tx = peek(u); e.n, e.ty, e.tx = n, ty, tx; bump("walk_instead") end
end

local function onStart(S, w, clock)
  if J.skip and J.skip[w[5]] then J.skipW = J.skipW or {}; J.skipW[w[5]] = w; bump("skip_test"); return end   -- (lane 23, diagnosis) test only
  local e = J.byKey and J.byKey[w[5]]
  if not e or not valid(e.u) then build(S); e = J.byKey[w[5]] end
  if not e or not valid(e.u) then bump("skip_no_unit_here"); return end
  if not J.retry then e.pend = nil end
  e.hostIdle = nil; e.pw = nil                                   -- (lane 46) a pickup wait ends at the host's next start
  if w[19] and w[19] ~= e.hl then e.hl = w[19]; e.hlT = clock end   -- (lane 23) the host's unit's load
  local ty = tonumber(w[6]); local T, F = decPT(w[14]), decPT(w[15])
  local ex, ey, ez = (w[16] or ""):match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
  if not (ty and T and F and ex) then bump("skip_bad_line"); return end
  if not GIVE[ty] then bump("skip_type" .. ty); return end      -- an older host: never give a type not known to be safe
  local rec = { Type = ty, TargetLocation = T, finalLocation = F, targetEntityLocation = { X = ex + 0.0, Y = ey + 0.0, Z = ez + 0.0 },
                resourceType = math.tointeger(tonumber(w[7])) or 0, resourceAmt = math.tointeger(tonumber(w[8])) or 0, executed = false, ID = -1, bPaidInAdvance = w[17] == "1" }
  local hp; local hx, hy, hz = (w[18] or ""):match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
  if hx then hp = { X = hx + 0.0, Y = hy + 0.0, Z = hz + 0.0 } end
  local function skip(why) bump(why); bump(why .. (e.own and "_own" or "_other")); e.free = true; e.host = nil; e.q = nil; walkThere(e, ty == FOLLOW and hp or T.Pos, clock) end
  if w[9] ~= "-" then rec.targetBuilding = findB(w[9]); if not rec.targetBuilding then return skip("skip_no_building") end end
  if w[10] ~= "-" then rec.finalBuilding = findB(w[10]); if not rec.finalBuilding then return skip("skip_no_building") end end
  if w[11] ~= "-" then local x = J.byKey[w[11]]; if not (x and valid(x.u)) then return skip(w[11]:match("^[oa]") and "skip_no_animal" or "skip_no_unit") end; rec.targetUnit = x.u end
  if w[12] ~= "-" then local x = J.byKey[w[12]]; if not (x and valid(x.u)) then return skip("skip_no_unit") end; rec.finalUnit = x.u end
  if w[13] ~= "-" then
    local r = findRes(w[13], clock)
    if not valid(r) then
      -- (lane 23, gap b) a felled tree exists here only once this copy's own villager has felled it (it may still be
      -- chopping: the start lag): the start waits and the resource is looked for again, for cfg.resWait seconds
      local t0 = J.retry and e.pend0 or clock
      if (J.cfg.resWait or 0) > 0 and clock - t0 < J.cfg.resWait then
        e.pend = { w = w, tl = clock }; e.pend0 = t0; e.host = nil; e.q = nil
        if not J.retry then bump("res_wait"); walkThere(e, T.Pos, clock) end
        return
      end
      if J.retry then bump("res_gave_up") end
      e.pend = nil
      bump("skip_no_resource_ty" .. ty); return skip("skip_no_resource")
    end
    rec.Resource = r
    if J.retry then bump("res_late") end
  end
  e.pend = nil
  e.free = nil; bump("received"); if e.own then bump("received_own") end
  local q = { rec = rec, ident = ty .. "|" .. w[9] .. "|" .. w[10] .. (ty == FOLLOW and ("|" .. w[11]) or ""), t = clock, hp = hp }
  stamp(rec)                                                   -- (lane 59) this record is this world's
  -- (lane 49, round four) the target building's address, taken now while the handle is this frame's (ENDHOLD's list
  -- is made later from addresses only: no call on a handle kept from an earlier frame)
  q.tbA = rec.targetBuilding and got(function() return rec.targetBuilding:GetAddress() end, 0) or 0
  J.ehSeq = ((J.ehSeq or 0) % 0xFFFF) + 1; q.sq = J.ehSeq
  e.host = q; J.chDirty = true                                                -- what the host's unit is on, until U E or the next start
  if ty == 4 and rec.resourceType ~= 0 then                    -- (lane 23) where loads of this good go: for the board's carry
    local c = { rec = rec, ident = q.ident }
    e.carry = e.carry or {}; e.carry[rec.resourceType] = c; J.carryTo = J.carryTo or {}; J.carryTo[(e.key:match("^(%d+)%.") or "x") .. ":" .. rec.resourceType] = c   -- by region: never a carry into another lord's town
  end
  local n, cty, ctx, t = peek(e.u)
  local cur = n > 0 and identOf(t, cty) or nil
  if cur == q.ident and (w[9] ~= "-" or ty == FOLLOW) then    -- its own game is already there (a load picked up, the next leg)
    e.given = cur; e.givenT = clock; e.isHold = nil; e.q = nil; bump("already"); return
  end
  -- (lane 35, item 3) a carry, fetch or crafting: the host's unit ended its task before (that is why it starts this one), so this
  -- copy's unit ends it too, now. Waiting for it (a carry with goods up to cfg.carryGrace, any other task while near its
  -- end up to cfg.grace) made one carry start in ten more than 10 s late (lane 23 f4: 90 % of "grace" carries 9.3 s).
  -- Building stock, the region's totals and the load in hands are the host's word (GOODS, TOTALS, cfg.hands), so what
  -- this copy's task would have delivered is not needed; the load the host's unit holds now is written at once.
  -- Not tree work (17 felling, 23 cutting a felled tree): cut short, this copy's tree never falls (or is never cut up)
  -- and the gatherers that follow find no felled tree here (f2, f3: gathering 61 % with the cut, 92 % without, m1)
  if e.given and cur == e.given and not e.isHold and CUT[cty] then
    if J.cfg.hands and w[19] and got(function() return handsOf(e.u) end, w[19]) ~= w[19] then
      local okH = pcall(setHands, e.u, w[19]); bump(okH and "hands_at_start" or "errors")
    end
    bump("cut_prev"); J.why = "cut"; give(e, q, clock); return
  end
  if e.given and cur == e.given and not e.isHold then
    -- (lane 23, gap a) a carry with goods in hands is not cut: the load would stay in the hands (lane 19, 401 samples)
    if J.cfg.carryKeep and CARRY[cty] and got(function() return #e.u.Inventory end, 0) > 0 then q.carry = true; e.q = q; bump("queued_carry"); return end
    local tp = t.TargetLocation.Pos; local p = e.u.realPos       -- still on the host's task before: wait only when near its end
    local far = cty ~= FOLLOW and ((p.X - tp.X) ^ 2 + (p.Y - tp.Y) ^ 2 > J.cfg.waitNear * J.cfg.waitNear)
    if not far then e.q = q; bump("queued"); return end
    bump("queue_skipped_far")
  end
  J.why = J.retry and "retry" or "direct"; give(e, q, clock)
end

-- (lane 54, round two) WORK CYCLES. A crafter (25) yields its goods when its strokes reach targetRepetitions (25 or 20),
-- a miner (27) may yield at the end of each 4-stroke cycle (a roll of its own copy). On a friend the crafter's cycle
-- started earlier or later than the host's (watch w2, 3.10.3: 14 of 25 here while the host's was at 3 of 25: it yielded
-- 17 s first, carried and stood; "friend idle+L / host 25") and the miner's rolls are this copy's own (3.8.1 yielded
-- 15x1+27x1 at 371 s, the host's at 388 s: "friend 27+L or 4 / host 27", 4 to 5 s each, about 10 a phase). While the
-- host's villager is on that same task holding nothing, this copy's villager's strokes are held one short of the
-- cycle's end (the game's own counter, repetitions, written back to target - 2), so it never yields by itself; the
-- host's yield arrives as its next start (the carry, which cuts the task and writes the host's load: lane 35's rule).
-- Coop.jobs.cfg.workHold = false (console) for a test's before.
local WORKHOLD = { [25] = true, [27] = true }
local function workHold(e, u, n, ty, t)
  if J.cfg.workHold == false or n == 0 or not WORKHOLD[ty] or not (e.host and J.gateOn) then return end
  if tonumber(e.host.rec.Type) ~= ty or (e.hl or "0") ~= "0" or e.given ~= e.host.ident then return end
  local tg = got(function() return u.targetRepetitions end, 0); if tg < 3 then return end
  local r = got(function() return u.repetitions end, 0)
  if r >= tg - 1 and r < tg + 50 then
    local ok = pcall(function() u.repetitions = tg - 2 end)
    bump(ok and ("work_held_" .. ty) or "errors")
  end
end
-- (lane 54, round two) the trader: this copy's chooser picked another leg than the host's running one (see THE TRADER)
local function traderBack(e, cur, clock, speed)
  if J.cfg.trader == false or not (e.host and J.gateOn) then return false end
  local hty = tonumber(e.host.rec.Type) or -1
  if not TRIP[hty] or cur == e.host.ident then return false end
  if (clock - (e.host.t or clock)) * speed > (J.cfg.tradeHold or 60.0) then bump("trader_hold_over"); return false end
  if clock - (e.againT or -100) < 2.0 / speed then return true end
  e.againT = clock; J.why = "trader_back"; bump("trader_back_" .. tostring(hty))
  give(e, { rec = e.host.rec, ident = e.host.ident, again = true }, clock)
  return true
end
local function friendOne(e, clock, speed, grace)
  if J.skip and J.skip[e.key] then return end                  -- (lane 23, diagnosis) test only: a villager the board leaves alone
  local u = e.u
  local n, ty, tx, t = peek(u)
  pcall(workHold, e, u, n, ty, t)                              -- (lane 54, round two) a work cycle ends on the host's word
  pcall(arriveHold, e, u, n, ty, t, clock, speed)              -- (lane 49, round five) goods change hands on the host's word
  pcall(gatherHold, e, u, n, ty)                               -- (lane 49, round five) ... and a gatherer's yield
  -- (lane 23) the host's unit is on a cyclic task and this unit's job type is out of the list: the game re-picks it
  local slow = J.chOn and J.chSet and J.chSet[e.key] or false
  if n ~= e.n or ty ~= e.ty or tx ~= e.tx then
    e.n, e.ty, e.tx = n, ty, tx
    -- (lane 19, gap 4) a given task that ended within 2 game seconds: this copy lacked what it needs (stock, an empty stall)
    if e.gty then if (clock - (e.givenT or 0)) * speed < 2.0 then bump("quick_end_" .. e.gty) end; e.gty = nil end
    if n == 0 then
      if e.q then J.why = "after_prev"; give(e, e.q, clock)                          -- the task before ended: the waiting one starts
      elseif pwOn(e, clock) then bump("pick_waiting")              -- (lane 46) it waits with its load for the host's carry
      elseif J.cfg.carryKeep and J.gateOn and e.host and not TAKES[tonumber(e.host.rec.Type) or -1] and got(function() return #u.Inventory end, 0) > 0 then
        -- (lane 23, gap a) it ended holding goods (a tree felled, a log picked up): given the same task again it would
        -- take a second load (lane 19: 257x2 up to x8 in hands). It waits for the host's next start (the carry).
        bump("again_skipped_load")
      elseif slow then bump("left_to_game")                    -- (lane 23) its own chooser starts the next cycle
      elseif J.gateOn and e.host and not e.free and clock - (e.againT or -100) >= 2.0 / speed then
        -- (lane 19) gated: the given task ended here but the host's unit is still on it (no material in this copy's
        -- workshop, an empty stall): the same task once more, at most every 2 game seconds (the unit cannot choose)
        e.againT = clock; local h = e.host; J.why = "again_end"; give(e, { rec = h.rec, ident = h.ident, again = true }, clock)
      end
    else
      local cur = identOf(t, ty)
      -- (lane 46) the fetch the host's unit is on (given here) has turned into its carry on this copy first: this unit
      -- reached the goods earlier (it started nearer). Carried on, it delivers seconds before the host's unit and stands
      -- (lane 35's lasting differences: "friend 4 / host 22", "friend idle / host 4 with the load", 40 to 60 a run). It
      -- stands at the goods with its load instead, until the host's carry starts (onStart gives it: both then walk the
      -- same carry from the same place), at most cfg.pickWait.
      if J.cfg.pickWait and J.cfg.pickWait > 0 and J.gateOn and ty == 4 and not e.q and e.host and e.given == e.host.ident
         and e.given:sub(1, 3) == "22|" and (e.hl or "0") == "0" then
        local hf = e.host.ident:match("^%d+|[^|]*|([^|]*)"); local ct = cur:match("^%d+|([^|]*)|")
        if hf and hf ~= "-" and hf == ct and handsOf(u) ~= "0" then
          local hs = handsOf(u)
          if holdHere(e, clock) then e.pw = { t = clock, hs = hs }; bump("pick_wait"); return end
        end
      end
      if e.q and cur == e.q.ident and cur:sub(-4) ~= "|-|-" then e.given = cur; e.givenT = clock; e.isHold = nil; e.q = nil; bump("self")
      elseif cur ~= e.given then                               -- a task the unit took by itself
        if e.q then J.why = "after_prev_self"; give(e, e.q, clock)
        elseif slow then                                       -- (lane 23) the game's own re-pick of a cyclic task
          if traderBack(e, cur, clock, speed) then return end      -- (lane 54, round two) the host's trip, not its own
          if cur == e.host.ident then e.given = cur; e.givenT = clock; e.isHold = nil; bump("chosen_same")
          elseif BACK[tonumber(e.host.rec.Type) or -1] then        -- (lane 23, e1: a miner's fetch, an ox leader's other ox)
            bump("chosen_back_" .. tostring(ty)); local h = e.host; J.why = "chosen_back"
            bump("chosenlab_" .. tostring(h.rec.Type) .. "_" .. tostring(ty) .. "_" .. tostring(got(function() return u:getTaskLabel():ToString() end, "?")))   -- (lane 35) what the chooser picked
            give(e, { rec = h.rec, ident = h.ident, again = true }, clock)
          else e.given = cur; e.givenT = clock; e.isHold = nil; bump("chosen_own_" .. tostring(ty)) end   -- the trader's own leg
        elseif J.gateOn then                                   -- not from the job chooser (the gate stops that)
          bump("self_" .. ty)
          if e.host and not e.free and got(function() return #u.Inventory end, 1) == 0 and clock - (e.againT or -100) >= 2.0 / speed then
            e.againT = clock; local h = e.host; J.why = "again_self"; give(e, { rec = h.rec, ident = h.ident, again = true }, clock)
          end
        elseif J.cfg.hold and e.own and not e.free and got(function() return #u.Inventory end, 1) == 0 then
          if not again(e, u, clock, speed) then holdHere(e, clock) end
        else bump("own") end
      end
    end
  end
  if e.q and clock - e.q.t > ((e.q.carry and J.cfg.carryGrace) and (J.cfg.carryGrace / speed) or grace) then bump(e.q.carry and "grace_over_carry" or "grace_over"); J.why = "grace"; give(e, e.q, clock) end
  -- (lane 23, gap b) a start that waits for its resource: looked for again every half second
  if e.pend and clock - e.pend.tl > 0.5 then
    local w = e.pend.w; e.pend = nil
    J.retry = true; local ok, er = pcall(onStart, C.s, w, clock); J.retry = nil
    if not ok then bump("errors"); J.lastErr = tostring(er) end
    n, ty, tx, t = peek(u)
  end
  local cur = n > 0 and identOf(t, ty) or nil
  -- (lane 23, gap d) a gated unit with nothing to do and no word of the host about it asks the host (U Q)
  if J.cfg.ask and J.gateOn and n == 0 and not e.host and not e.q and not e.pend and not e.hostIdle and not e.free then
    if not e.idleT then e.idleT = clock
    elseif clock - e.idleT > J.cfg.askAfter and clock - (e.askT or -100) > J.cfg.askEvery then e.askT = clock; A.send("U Q " .. e.key); bump("asked") end
  else e.idleT = nil end
  -- (lane 23) on another task than the host's unit (and not holding a load the host's does not): the host's task
  if J.cfg.drift and J.gateOn and e.host and not e.free and not e.q and not e.pend and cur ~= e.host.ident then
    local hs = handsOf(u)
    -- idle with a load: it waits for the host's carry, unless the host's task is itself one that takes a load away
    if hs == "0" or (hs == e.hl and (n > 0 or TAKES[tonumber(e.host.rec.Type) or -1])) then
      if e.drT and e.drI == cur then
        if clock - e.drT > (slow and J.cfg.chooseLag or J.cfg.driftLag) * (J.lagF or 1) and clock - (e.againT or -100) >= 2.0 / speed then
          e.againT = clock; e.drT = nil; bump("drift_" .. tostring(ty)); local h = e.host; J.why = "drift"; give(e, { rec = h.rec, ident = h.ident, again = true }, clock)
          n, ty, tx, t = peek(u); cur = n > 0 and identOf(t, ty) or nil
        end
      else e.drT = clock; e.drI = cur end
    else e.drT = nil end
  -- (lane 46) "not e.isHold" only while the hold itself runs (type 17): a hold ends at once (it walks to where the unit
  -- stands), the mark stayed, and a Follow the ox's own guide request gave afterwards (PICK FOLLOW lets it through for a
  -- villager with no task) was never stood down: "friend 41 / host idle", up to 28 s (lane 35's oxd / oxe)
  elseif J.cfg.drift and J.gateOn and e.hostIdle and n > 0 and not e.q and not e.pend and not (e.isHold and ty == 17) and ty ~= LAZY then
    -- (lane 23) the host's unit has nothing to do (U E) and this one still works: after cfg.driftLag s it stands too
    -- (not with a load the host's unit does not hold: the carry ends by itself)
    -- (lane 35) after cfg.endLag (0.5 s; it was driftLag, 1.5 s): an ox leader whose host unit stood still led its ox on
    -- for 1.5 s and more (lane 23 f4: 84 samples "friend on 41, host idle")
    -- (not tree work: stopped early, this copy's tree does not fall; it keeps lane 23's driftLag)
    -- (lane 46) e.endT is cleared at each stand-down: a task this unit takes after that (the ox's own guide request:
    -- "friend 41 / host idle" 36 s in a1, no second stand-down) starts the lag again instead of never reaching it
    if not e.endT then e.endT = clock end
    if clock - e.endT > (NOCUT[ty] and J.cfg.driftLag or (J.cfg.endLag or J.cfg.driftLag)) * (J.lagF or 1) and handsOf(u) == (e.hl or "0") then
      e.endT = nil; bump("drift_idle_" .. tostring(ty)); holdHere(e, clock); n, ty, tx, t = peek(u); cur = n > 0 and identOf(t, ty) or nil
    end
    e.drT = nil
  else e.drT = nil end
  -- (lane 23) a load this unit holds and the host's unit does not, not on a carry, for cfg.handsLag s: the board gives
  -- the carry the host's units made last with that good (to the same building), and the host's task waits behind it.
  -- The game's own carry: hands and the region's books change the game's way (writing hands does not: run v1).
  if J.cfg.boardCarry and J.gateOn and e.hl == "0" and not e.q and not e.pend and not (n > 0 and CARRY[ty]) and not pwOn(e, clock) then
    local hs = handsOf(u)
    if hs ~= "0" then
      if not e.bcT then e.bcT = clock
      elseif clock - e.bcT >= J.cfg.handsLag * (J.lagF or 1) and clock - (e.bcLast or -100) > 4.0 * (J.lagF or 1) then
        e.bcT = nil; e.bcLast = clock
        local g = tonumber(hs:match("^(%-?%d+)x")); local c = (e.carry and e.carry[g]) or (J.carryTo and J.carryTo[(e.key:match("^(%d+)%.") or "x") .. ":" .. tostring(g)])
        local okRefs = c ~= nil
        if c and stale(c.rec) then okRefs = false; bump("stale_carry_refused"); if e.carry then e.carry[g] = nil end end   -- (lane 59)
        if c and okRefs then for _, k in ipairs(REFS) do if c.rec[k] ~= nil and not valid(c.rec[k]) then okRefs = false end end end
        if okRefs then
          local r = {}; for k, v in pairs(c.rec) do r[k] = v end; r.resourceType = g; r.resourceAmt = -1; RW[r] = RW[c.rec]
          local back = e.host
          J.why = "board_carry"; if give(e, { rec = r, ident = c.ident, again = true }, clock) then
            bump("board_carry"); if back then e.q = { rec = back.rec, ident = back.ident, t = clock, carry = true } end
            n, ty, tx, t = peek(u); cur = n > 0 and identOf(t, ty) or nil
          end
        else bump("board_carry_nowhere") end
      end
    else e.bcT = nil end
  else e.bcT = nil end
  -- (lane 23) the load in hands: the host's word, once this unit is on the host's job (or both idle) and the two loads
  -- have differed for cfg.handsLag seconds. OFF by default: written hands do not reach the region's books, which then
  -- drift (run v1: 12 to 13 of 18 totals differing); usable once the totals are the host's word on a friend.
  -- (lane 46, round two) paused, a villager in its pickup wait gets the host's load too (l46s1, l46s4: one villager's
  -- good 16 off by 1 at the act phase's pause)
  if J.cfg.hands and e.hl and (J.paused or not pwOn(e, clock)) then
    -- on the host's job, or standing with nothing to do (a given task that ended at once for want of the load: the
    -- trader's TradeStock (61) with empty hands, lane 23 baseline 0 of 30 samples). Not while on another job.
    local same = (e.host and cur == e.host.ident) or n == 0
    -- (lane 46) but not the load of a carry the host's unit is still on into this unit's hands when it stands: its own
    -- carry ended first (delivered) and the written load made a state the host's unit never had (standing with the
    -- load: "friend idle+L / host 4+L"), then the same carry given again from the target (lane 35's oxd / oxe)
    if same and n == 0 and not J.paused and e.host and CARRY[tonumber(e.host.rec.Type) or -1] and e.hl ~= "0" then same = false; bump("hands_not_standing") end
    -- (lane 35, round seven, item 2) also: the host's unit has nothing to do (U E), or both are on the same carry chain
    -- (fetch 22 or carry 4 to the same final building: a friend's villager that reached the goods first picked them up
    -- and its fetch went on as a carry while the host's still walked there empty: hands1 looks 2 and 6, 17x9 / 17x10)
    if not same and e.hostIdle then same = true end
    -- (lane 46) not while the host's unit is still on its way empty (e.hl "0"): this unit, ahead, would carry nothing
    -- (lane 35's oxd / oxe: "friend 4 without a load / host 22", 21 and 22 lasting differences a run); only paused
    if not same and e.host and n > 0 and CARRY[ty] and CARRY[tonumber(e.host.rec.Type) or -1] and (e.hl ~= "0" or J.paused) then
      local hf = e.host.ident:match("^%d+|[^|]*|([^|]*)")
      local ct, cf = (cur or ""):match("^%d+|([^|]*)|([^|]*)")
      if hf and hf ~= "-" and (hf == ct or hf == cf) then same = true; bump("hands_same_chain") end
    end
    -- (lane 46) paused, a load is what a player looks at for as long as the pause lasts: every unit gets the host's
    if not same and J.paused then same = true; bump("hands_paused") end
    local hs = same and handsOf(u) or nil
    if hs and hs ~= e.hl then
      if not e.hmT then e.hmT = clock
      elseif J.paused or (clock - e.hmT >= J.cfg.handsLag * (J.lagF or 1) and clock - (e.hlT or 0) >= J.cfg.handsLag * (J.lagF or 1)) then   -- (lane 46) paused: at the next look
        e.hmT = nil
        local ok, er = pcall(setHands, u, e.hl)
        if ok then bump(e.hl == "0" and "hands_cleared" or (hs == "0" and "hands_given" or "hands_changed")) else bump("errors"); J.lastErr = "hands: " .. tostring(er) end
      end
    else e.hmT = nil end
  end
  local pc = e.pchk                                            -- a placed unit, at every look for 8 s: does it stay?
  if pc then
    local p = u.realPos
    local step = math.sqrt((p.X - pc.lx) ^ 2 + (p.Y - pc.ly) ^ 2); pc.lx, pc.ly = p.X, p.Y
    if step > 1000 then pc.jump = true end                      -- more than 10 m between two looks (0.3 s): not a walk
    if (p.X - pc.ox) ^ 2 + (p.Y - pc.oy) ^ 2 < 500 * 500 then pc.back = true end
    if clock - pc.t > 8.0 then
      e.pchk = nil
      bump(pc.back and "placed_back_at_old_place" or (pc.jump and "placed_jumped" or "placed_kept"))
    end
  end
end

-- ---------------------------------------------------------------- the module
-- a new world, or the same world attached again under another role (coop.lua setRole): a list this module filled is
-- emptied first (with the byte off and the list full, nothing would start at all)
-- (lane 59) Everything that holds a game object or a task record goes: besides the lists, the mount records (J.mnt),
-- the arrive holds (J.arrB: a unit each), the pending fellings, the units gone from the list, the address list of the
-- villagers. After a load (the core's S.loads moved; not C.setRole's attach of the same world) the arrive holds and the engine the
-- gate was opened on are dropped BEFORE the gate closes: closing wrote each held unit's Speed back and emptied that
-- engine's job list, on objects of the world that is gone.
local function fresh(S)
  local nm, na = 0, 0; for _ in pairs(J.mnt or {}) do nm = nm + 1 end; for _ in pairs(J.arrB or {}) do na = na + 1 end
  if nm + na > 0 then log("jobs: world %s: dropped %d mount record(s) and %d arrive hold(s) kept from the world before", tostring(S.worlds), nm, na) end
  if J.loadN ~= S.loads then J.arrB = nil; J.gateEng = nil end   -- another loaded world (S.loads): nothing of the old one is called
  if J.gateOn then gateClose(S, "world attached again") end
  J.list, J.rlist, J.byKey, J.byAddr, J.listT, J.res, J.helloFor, J.carryTo, J.fallen, J.chSent = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
  J.mnt, J.arrB, J.fellP, J.goneU, J.va, J.vaFor, J.chSet, J.skipW, J.resT = nil, nil, nil, nil, nil, nil, nil, nil, nil
  J.world = S.worlds; J.loadN = S.loads
end
local function tick(S, clock)
  if J.world ~= S.worlds then fresh(S) end                     -- (lane 59) a module loaded in the middle of a world gets no onWorld
  if S.role ~= "friend" and J.gateOn then gateClose(S, "this copy is no longer a friend") end
  if not (S.role == "host" or S.role == "friend") then return end
  if S.role == "friend" and valid(S.eng) then gateStep(S, os.clock()); pcall(chooseStep, S, os.clock()); pcall(J.regAudit, S, os.clock()) end
  if not J.cfg.on or C.hold then return end
  if not (valid(S.eng) and valid(S.p1)) then return end
  local t0 = os.clock()
  J.tickN = (J.tickN or 0) + 1
  if not J.list or clock - (J.listT or 0) > J.cfg.refresh then build(S) end
  local cfg = J.cfg
  -- (lane 35, item 5) above speed 4 the board's wall-second windows and its look stride shrink with the speed, so they
  -- stay the same in game time (cfg.speedScale; at speed 8: villagers looked at every 2 frames instead of 4, at most twice
  -- as many in one frame, and the drift, choose and hands lags halved)
  local sp = math.max(1.0, got(function() return S.eng.gameSpeed end, 1.0))
  J.lagF = cfg.speedScale and math.min(1.0, 4.0 / sp) or 1.0
  J.paused = got(function() return A.isPaused() and true or false end, false)    -- (lane 46) the hands rule while paused
  -- (lane 46, round two) a friend paused 3 s: once per pause, one log line naming the villagers whose load is still not
  -- the host's as told (or whose host load was never told), for the paused-loads check
  if not J.paused then J.pzT = nil else
    -- (round two) both roles, once per pause: every board unit holding a load, with the region it stands in (the
    -- region dump counts by the unit's current region: a unit crossing a border counts elsewhere on one copy)
    J.pzT = J.pzT or clock
    if clock - J.pzT > 3.0 and not J.pzAll then
      J.pzAll = true; local all = {}
      for _, l in ipairs({ J.list or {}, J.rlist or {} }) do for _, e in ipairs(l) do
        local hs = got(function() return handsOf(e.u) end, "0")
        if hs ~= "0" then all[#all + 1] = e.key .. "=" .. hs .. "@" .. got(function() return e.u.currentRegion.regionUniqueTag:ToString() end, "?") end
      end end
      table.sort(all)
      log("jobs: paused 3 s, every board unit with a load (%d): %s", #all, table.concat(all, " "))
    end
  end
  if not J.paused then J.pzAll = nil end
  if not J.paused then J.pzT = nil elseif S.role == "friend" then
    J.pzT = J.pzT or clock
    if clock - J.pzT > 3.0 and not J.pzSaid then
      J.pzSaid = true; local o, n = {}, 0
      for _, l in ipairs({ J.list or {}, J.rlist or {} }) do for _, e in ipairs(l) do
        local hs = got(function() return handsOf(e.u) end, "?")
        if (e.hl == nil and hs ~= "0") or (e.hl ~= nil and hs ~= e.hl) then n = n + 1; if #o < 8 then o[#o + 1] = string.format("%s have %s host %s%s", e.key, hs, tostring(e.hl), pwOn(e, clock) and " (pickup wait)" or "") end end
      end end
      -- (round two) and every unit with a load that is on none of the board's lists (once per pause: the region dump's
      -- "units standing in the region" count units the board never names: l46s4..6, one good 16 off)
      local x = {}
      pcall(function()
        local ua = S.eng.unitArr
        for q = 1, #ua do
          local u = un(ua[q])
          if valid(u) and not (J.byAddr and J.byAddr[u:GetAddress()]) then
            local hs = got(function() return handsOf(u) end, "0")
            if hs ~= "0" and #x < 6 then x[#x + 1] = string.format("%s %s at %d,%d", got(function() return u:GetClass():GetFName():ToString() end, "?"), hs, math.floor(u.realPos.X / 100), math.floor(u.realPos.Y / 100)) end
          end
        end
      end)
      log("jobs: paused 3 s, loads not the host's word: %d%s | units on no list with a load: %s", n, n > 0 and (": " .. table.concat(o, "; ")) or "", #x > 0 and table.concat(x, "; ") or "none")
    end
  end
  if not J.paused then J.pzSaid = nil end
  local stride, perFrame = math.max(1, math.floor(cfg.stride * J.lagF + 0.5)), math.ceil((cfg.perFrame or 15) / J.lagF)
  if S.role == "host" then
    each(J.list, stride, perFrame, hostOne)
    each(J.rlist, cfg.rstride or 12, cfg.rperFrame or 8, hostOne)
  else
    -- a friend's board that just started (a join, a reload, the module loaded late) asks for every unit's running task
    if J.helloFor ~= S.worlds then J.helloFor = S.worlds; A.send("U H"); bump("hello") end
    local speed = math.max(1.0, got(function() return S.eng.gameSpeed end, 1.0))
    local grace = cfg.grace / speed
    local fn = function(e) friendOne(e, t0, speed, grace) end
    if J.fellP then local ok, er = pcall(fellTick, t0, speed); if not ok then bump("errors"); J.lastErr = "fell: " .. tostring(er) end end   -- (lane 54)
    if J.arrB then pcall(arriveSweep, t0) end                  -- (lane 49, round five)
    -- (lane 23) the host quiet for cfg.quiet s (gone, or paused): the gate is open and this copy's game is the plain
    -- game: no "stand here", no task given again (lane 19's paths still held villagers then)
    if t0 - (J.lastU or -1e9) < cfg.quiet then
      if J.wasQuiet then J.wasQuiet = nil; A.send("U H"); bump("hello_after_quiet") end   -- every running task told again
      each(J.list, stride, perFrame, fn)
      each(J.rlist, cfg.rstride or 12, cfg.rperFrame or 8, fn)
    else bump("quiet_ticks"); if J.lastU then J.wasQuiet = true end end
  end
  local dt = os.clock() - t0
  J.cost = (J.cost or 0) + dt; J.costN = (J.costN or 0) + 1; if dt > (J.costMax or 0) then J.costMax = dt end
  if clock - (J.logT or 0) >= 60.0 then
    if J.logT then
      local keys = {}; for k in pairs(J.n) do keys[#keys + 1] = k end; table.sort(keys)
      local s = {}; for _, k in ipairs(keys) do s[#s + 1] = k .. " " .. J.n[k] end
      log("jobs: %s, last 60 s, %d + %d units%s: %s | tick %.3f ms mean over %d ticks, longest %.1f ms%s", S.role, #J.list, #(J.rlist or {}),
        S.role == "friend" and (J.gateOn and ", gate on" or (", gate off: " .. tostring(J.gateWhy or "-"))) or "", #s > 0 and table.concat(s, ", ") or "nothing",
        J.cost / math.max(1, J.costN) * 1000, J.costN, (J.costMax or 0) * 1000, J.lastErr and (" | last error: " .. J.lastErr:sub(1, 160)) or "")
    end
    J.logT = clock; J.n = {}; J.cost = 0; J.costN = 0; J.costMax = 0; J.lastErr = nil
  end
end
local function onMessage(S, from, kind, w, line)
  if kind ~= "U" then return false end
  if S.role == "host" then                                     -- U H: a friend's board started: tell every running task again
    if w[4] == "H" then
      for _, l in ipairs({ J.list or {}, J.rlist or {} }) do for _, e in ipairs(l) do e.n = nil; e.freeSent = nil; e.hs = nil; e.retell = true end end
      bump("hello")
    elseif w[4] == "Q" then                                    -- (lane 23) U Q <unit>: tell this unit's task and load again
      local e = J.byKey and J.byKey[w[5]]
      if e then e.n = nil; e.freeSent = nil; e.hs = nil; e.retell = true; e.told = true; bump("asked") end
    end
    return true
  end
  if S.role ~= "friend" or not J.cfg.on or not (valid(S.eng) and valid(S.p1)) then return true end
  if J.world ~= S.worlds then fresh(S) end                     -- (lane 59) never a line onto another world's entries
  local clock = os.clock()
  J.lastU = clock
  if w[4] == "S" or w[4] == "R" or w[4] == "E" or w[4] == "F" then local ok, er = pcall(fellAtHostEnd, w, clock); if not ok then bump("errors"); J.lastErr = "fell: " .. tostring(er) end end   -- (lane 54)
  if w[4] == "S" or w[4] == "R" then local ok, er = pcall(onStart, S, w, clock); if not ok then bump("errors"); J.lastErr = tostring(er) end
  elseif w[4] == "L" then                                      -- (lane 23) U L <unit> <load>
    local e = J.byKey and J.byKey[w[5]]
    if e and w[6] and w[6] ~= e.hl then e.hl = w[6]; e.hlT = clock end
  elseif w[4] == "F" then
    local e = J.byKey and J.byKey[w[5]]
    if e and valid(e.u) then
      e.free = true; e.q = nil; e.host = nil; e.pend = nil; J.chDirty = true; bump("free")
      local x, y, z = (w[7] or ""):match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
      if x then pcall(walkThere, e, { X = x + 0.0, Y = y + 0.0, Z = z + 0.0 }, clock) end
    end
  elseif w[4] == "E" then local e = J.byKey and J.byKey[w[5]]; if e then e.host = nil; e.hostIdle = true; e.endT = clock; e.pend = nil; e.pw = nil; J.chDirty = true; bump("ended") end end
  return true
end
-- the mod stopping: the job list is emptied before coop_patch puts its bytes back (modules get no stop call)
if C.stop ~= J.stopWrap then
  local orig = C.stop
  J.stopWrap = function(...)
    local Jj = rawget(_G, "Coop") and _G.Coop.jobs
    if Jj and Jj.gateOn then pcall(function() emptyList(Jj.gateEng) end); Jj.gateOn = nil end
    return orig(...)
  end
  C.stop = J.stopWrap
end
-- (lane 59) idle: when the world the gate was opened in is gone, its units and engine are not called
C.register("jobs", { onWorld = function(S) fresh(S) end, tick = tick, idle = function(S, clock) if J.gateOn then if not S.eng or J.loadN ~= S.loads then J.arrB = nil; J.gateEng = nil end; gateClose(S, "no world") end end, onMessage = onMessage })
return "coop job board loaded"
