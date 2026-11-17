-- Manor Lords Co-op: things that have to be MADE on a friend's copy to match the host (plug-in module "people",
-- message kind "V"). Lane 11, session 21. Evidence: research/2026-11-10-game-probe/lanes/lane_s21_11/report.txt
--
-- The host decides, friends follow. Two kinds of difference used to cost a reload of the host's save (or stayed
-- unseen), because something had to be created on the friend's copy:
--
-- 1. FAMILIES. The realm module (coop_realm.lua) tells every friend the host's family list per region (homes in list
--    order) and removes a family the host no longer has. A family the friend LACKS is made here, with the game's own
--    functions (measured on the host alone, sessions 2 and 8 of this lane):
--      RTSMultiEngineCPP:SpawnLivestock(role 0, place, region)   makes a villager (a husband) with a name of its own
--      SMUnit:equipAdequateCivilianClothes(true)                 completes him (NEVER left out: see makeVillager below;
--                                                                without it the game crashed twice)
--      Region:AddNewFamily({ villager })                         a new family at the END of the region's list
--      Region:SetFamilyHome(place - 1, house, true)              the host's home for it
--    (Region:growPopulation, the candidate named first, made no family in 180 calls with free living space.)
--    Its other people: the host's family is in the events module's people line (name, role, age per person). A person
--    the host's family has and a family MADE here lacks is made the same way and joins with
--    Region:AddNewFamilyMember(place - 1, villager), under the host's name (husband, wife or son; a daughter is never
--    made: the game's own families here have none). Families the game made itself are left to the game, as before:
--    each copy's game completes a family by itself some days after it arrived, also one made here (session 3).
--    Names follow by the events module's rule.
--    Nothing is sent for this: the friend reads Coop.realm.famHost and Coop.events.hostP.
--    When making fails nothing else is done here: the realm module asks for a reload after its 10 s, as before.
--
-- 2. THE OTHER LORDS' TOWNS. Rival lords decide on the host only, so their towns gain, upgrade and lose buildings
--    there. The host tells every building that belongs to a rival lord:
--      host -> friends   V B <lord> <buildings of that lord> <first in this line> <entry;entry;...>
--                        entry = type,x,y,z,yaw,function,built 0|1,upgrades ("2.108" or "-"); lord = A<setup index>
--                        sent when the list changes and every 60 s
--      friend -> host    V ASK <lord> <key>          "send me the lot of this house"
--      host -> friends   V LOT <lord> <key> <lot>    the house's lot in the town module's HOUSE form
--    A friend's copy compares the list with its own buildings of that lord, named type@x,y like everywhere in the mod:
--      a building it lacks          is placed through the town module's own BUILD (the helper lord: placeBuilding, bbox,
--                                   requestBuild). The game gives a building to the owner of the region it stands in
--                                   (measured: owner A2, a building site). A house is drawn with the town module's
--                                   HOUSE from the lot the host sends (border, corners, house place; the house comes
--                                   out without its backyard, so backyard upgrades cannot follow on such a house).
--      another type at that place   is an upgrade: the upgrades the host's building has and this one lacks are started
--                                   with the building's own BeginUpgrade / ChangeExtension / changeArtisanType
--      a building the host lacks    is removed through the town module's DEMOLISH (the helper's demolish list), but
--                                   only while the host still gives that region to that lord (the events module's
--                                   owner line) and never more than three buildings of a lord at one look: a region
--                                   that changes hands, or a list that comes short, must not tear a town down
--    A building made here is a site; the sites module finishes it when the host's is finished.
--    The helper is used and never the rival's own pawn: placing through the rival's pawn works too, but the game then
--    appends the building to that pawn's nearby-buildings list (measured 0 -> 1), which is the list of ledger row G49.
--    Not followed (logged once each): market stalls (each copy's families set them up), marketplaces, fields and
--    pastures (drawn plots: not exercised), animal orders.
-- Re-loadable (state lives in Coop.people).

local C = rawget(_G, "Coop")
if type(C) ~= "table" or type(C.register) ~= "function" or type(C.api) ~= "table" then return "coop_x_people: load coop.lua first" end
local A = C.api
local un, valid = A.un, A.valid
local P = C.people or {}
C.people = P
P.version = "0.5"
P.on = P.on or {}
local DEFAULT_ON = {
  families = true,      -- a family the host has and this copy lacks is made here
  members = true,       -- ... and the people the host's family has join a family made here
  rival = true,         -- the host's list of the rival lords' buildings is pushed and compared
  rivalMake = true,     -- a building this copy lacks is placed here (town module BUILD / HOUSE)
  rivalUpgrade = true,  -- an upgrade this copy lacks is started here
  rivalRemove = true,   -- a building the host no longer has is removed here (town module DEMOLISH)
  grow = true,          -- lane 36: the host names each change of its families' sizes and homes at once (V G)
  growRivals = true,    -- lane 39: ... and of every rival lord's town too
  rivalRoads = true,    -- lane 42: the roads in a rival lord's regions (V D)
  tradeLog = true,      -- lane 42 round two: the trade screen's log as the host's (V T)
}
for k, v in pairs(DEFAULT_ON) do if P.on[k] == nil then P.on[k] = v end end
P.stats = P.stats or {}
P.S = nil                                                -- a hot reload: everything is set up, told and judged again

local KEY = 60.0            -- the host repeats its lists this often
local RIVAL_EVERY = 0.5     -- seconds between two looks at the rival lords' buildings (lane 42: was 2 s)
local RIVAL_EVERY_F = 1.0   -- lane 42: a friend looks once a second (it also looks 0.3 s after each list from the host)
local RIVAL_AFTER = 0.3     -- a difference must last this long before this copy acts (lane 42: was 1.5 s; the host's
                            -- list is complete or not taken, and removals keep their guards: MAX_REMOVE, hostGives)
local TRY_AGAIN, TRIES = 20.0, 3
local MAX_REMOVE = 3        -- more buildings than this missing from the host's list at one look: none is removed
local FAM_AFTER = 5.0       -- a missing family is made after this long (the realm module asks for a reload after 10 s)
local FAM_AGAIN = 30.0
local MEMBER_AFTER = 6.0    -- a missing person joins a made family after this long
local SETTLE = 8.0          -- a family's people are not read before it has been left alone this long (lane 5's rule)

-- what a building is for (EBuildingFunction): which of the rival's buildings are followed, and how
local SKIP_FN = { [3] = "market stall", [7] = "being removed", [13] = "landscape", [19] = "cosmetic", [20] = "scenario" }
local PLOT_FN = { [10] = "pasture", [12] = "field", [15] = "marketplace" }
local HOUSE_FN = 1
-- upgrades (EUpgradeType): animal orders are each copy's own; 100 and up are backyards and workshops of a house
local ANIMAL = { [13] = true, [19] = true, [21] = true, [26] = true, [27] = true, [28] = true }
local ARTISAN = { [103] = true, [104] = true, [105] = true, [106] = true, [107] = true, [109] = true, [110] = true, [111] = true, [113] = true, [115] = true, [116] = true }
local ZT = "0.00000,0.00000,0.00000,1.00000,0.00,0.00,0.00,1.000,1.000,1.000"

local function log(fmt, ...) A.log("people: " .. fmt, ...) end
local function bump(k) P.stats[k] = (P.stats[k] or 0) + 1 end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); if ok then return a end end
local function rkey(r)
  local ok, k = pcall(function() return r.regionUniqueTag:ToString() end)
  if not ok or type(k) ~= "string" or k == "" or k == "None" then return nil end
  return (k:gsub("[^%w_%.]", "_"))
end
-- a lord by facts that are the same on every copy (the world module's rule)
local function ownerCode(S, o)
  if not valid(o) then return "-" end
  if addr(o) == addr(S.p1) then return "P" end
  local okB, bandit = pcall(function() return o.isBandit end); if okB and bandit then return "B" end
  local okI, idx = pcall(function() return o:getPawnSetupIndex() end); if okI and type(idx) == "number" then return "A" .. math.floor(idx) end
  return "X"
end
-- the same name as everywhere in the mod: type plus position rounded to 10 cm
local function posKey(x, y) return string.format("%d,%d", math.floor(x / 10 + 0.5), math.floor(y / 10 + 0.5)) end
local function bkey(b) local l = b:K2_GetActorLocation(); return A.btype(b) .. "@" .. posKey(l.X, l.Y) end
local function findBuilding(S, key)
  local arr = S.eng.buildingArr
  for i = 1, #arr do local b = un(arr[i]); if valid(b) then local ok, k = pcall(bkey, b); if ok and k == key then return b end end end
end
local function ownRegions(S)
  local t = {}; local arr = S.eng.regions; local me = addr(S.p1)
  for i = 1, #arr do
    local r = un(arr[i])
    if valid(r) and valid(r.ownerPawn) and addr(r.ownerPawn) == me then local k = rkey(r); if k then t[k] = r end end
  end
  return t
end

-- lane 39: the regions whose family changes the host names at once (V G): the player's own, and every other lord's
-- town (a settled region of a rival lord, with families). A rival's families arrive, grow, move and leave on each copy
-- by its own dice and moment (lane 36: residents 89 / 88); the friend's own emigration and housing there are held by
-- the native HOLD once the world module holds that region.
local function rivalTowns(S)
  local W = rawget(C, "world")
  local t = {}
  if not (P.on.growRivals and W and W.rivalTown) then return t end
  local now = os.clock()
  if P.rvT and now - P.rvT < 5.0 and P.rvS == S then return P.rv end
  pcall(function()
    local arr = S.eng.regions
    for i = 1, #arr do local r = un(arr[i]); if valid(r) and W.rivalTown(r) then local k = rkey(r); if k then t[k] = r end end end
  end)
  P.rv = t; P.rvT = now; P.rvS = S
  return t
end
local function growRegions(S)
  local t = ownRegions(S)
  for k, r in pairs(rivalTowns(S)) do t[k] = r end
  return t
end

local function fresh(S)
  if P.S == S and P.world == S.worlds then return end
  P.rv = nil; P.rvT = nil
  P.S = S; P.world = S.worlds
  P.fam = {}; P.made = {}; P.tFam = 0
  P.scan = nil; P.tRival = 0; P.sentB = {}; P.tKeyB = -1e9; P.lastB = nil; P.keysB = {}
  P.hostB = {}; P.since = {}; P.tries = {}; P.jobs = {}; P.queued = {}; P.cur = nil; P.lots = {}; P.lotAsked = {}; P.said = {}; P.asked = false
  P.gLast = nil; P.gq = {}; P.gDay = nil; P.gDayT = nil; P.tGrow = 0; P.leaving = {}
  P.sentD = nil; P.tKeyD = nil; P.hostD = nil; P.curD = nil; P.sinceD = {}; P.triesD = {}; P.tRoad = 0; P.roadC = {}; P.tFullD = nil; P.hostK = nil; P.sentK = nil; P.tLinks = nil; P.tLinksF = nil; P.hostT = nil; P.logSig = nil; P.tKeyT = nil   -- lane 42: rival roads, links, trade log
  log("reset for world %d (%s)", S.worlds, tostring(S.role))
end

-- ================================================================ 1. families
-- the host's list as the realm module keeps it (homes in list order)
local function hostHomes(rk)
  local R = rawget(C, "realm"); local H = R and R.famHost and R.famHost[rk]
  if not (H and type(H.v) == "string") then return nil end
  local t = {}
  for k in H.v:gmatch("[^;]+") do if k ~= "0" then t[#t + 1] = k end end
  return t
end
-- the host's people of one family as the events module keeps them: { { n = name, role = , age = }, ... } or nil
local function hostPeople(rk, place, count)
  local E = rawget(C, "events"); local H = E and E.hostP and E.hostP[rk]
  if not (H and H.fams and H.n == count) then return nil end
  local h = H.fams[place]
  if not h or h.wait then return nil end
  return h.m, h.home
end

-- A villager as SpawnLivestock makes it is NOT complete. Every reflected property was compared with a villager of the
-- game's own (sessions 5 and 8 of this lane): six differ. Radius 0 instead of 35, att 0 instead of 1, range and
-- rangeSq 0 instead of 100 and 10000, no animation set ("work") and no animation table; a made wife or son also keeps
-- a queued item it cannot put on. The host of session 4 died in a unit's equip call while such villagers were in
-- its town; the host of session 8 died the same way 20 s after two such families were made. The game's own
-- SMUnit:equipAdequateCivilianClothes(true) gives a made villager the radius, the attack value, the animation set
-- and its table (measured, session 8). (att, range and rangeSq then follow what the villager holds, as on the
-- game's own: 1 and 100 with free hands, 2 and 150 with a tool, range 0 while carrying.) A villager that is not
-- complete after that call is removed again at once.
-- (Writing the values over from another villager instead was tried in session 8 and is NOT done: villagers
-- completed that way were in the town of the second crash.)
local function complete(u) return valid(u.currentAnimsetDT) and (tonumber(u.Radius) or 0) > 0 end

-- one villager of a role (0 husband, 1 wife, 2 son), made by the game and completed: nil when that did not work
local function makeVillager(S, reg, role, pos, name)
  local u = S.eng:SpawnLivestock(role, pos, reg)
  if not valid(u) then return nil, "SpawnLivestock made no unit" end
  local human = false; pcall(function() human = u:isHumanCivilian(false) end)
  if not human then pcall(function() S.eng:destroyUnit(u) end); return nil, "SpawnLivestock made no villager" end
  local okC, done = pcall(function() u:equipAdequateCivilianClothes(true); return complete(u) end)
  if not (okC and done) then pcall(function() S.eng:destroyUnit(u) end); return nil, "the villager was not complete after equipAdequateCivilianClothes (" .. tostring(done) .. "): removed again" end
  if name and name ~= "" then pcall(function() u.DisplayName = name end) end
  return u
end
local function spawnPlace(reg, home)
  if valid(home) then local l = home:K2_GetActorLocation(); return { X = l.X + 250.0, Y = l.Y + 0.0, Z = l.Z + 0.0 } end
  local c = reg:getSettledRegionCenter()
  return { X = c.X + 0.0, Y = c.Y + 0.0, Z = c.Z + 0.0 }
end

-- the host's family at <place> (home <homeKey>) is made here; true when this copy's list has it afterwards
local function makeFamily(S, clock, rk, reg, place, homeKey)
  local n0 = #reg.workerFamilies
  if n0 ~= place - 1 then return false, "this copy's list is not one short of that place" end
  local home = (homeKey ~= "-") and findBuilding(S, homeKey) or nil
  local name
  local hm = hostPeople(rk, place, place); if hm and hm[1] and hm[1].role == 0 then name = hm[1].n end
  local u, why = makeVillager(S, reg, 0, spawnPlace(reg, home), name)
  if not u then return false, why end
  local id = reg:AddNewFamily({ u })
  if #reg.workerFamilies ~= n0 + 1 then pcall(function() S.eng:destroyUnit(u) end); return false, "AddNewFamily added no family" end
  local housed = "no home on the host"
  if homeKey ~= "-" then
    if home then local ok, e = pcall(function() reg:SetFamilyHome(n0, home, true) end); housed = ok and ("home " .. homeKey) or ("home NOT set: " .. tostring(e))   -- the game counts families from 0
    else housed = "the host's home " .. homeKey .. " is not a building here" end
  end
  P.made[rk .. "|" .. place] = { t = clock, u = u, home = homeKey }
  return true, string.format("family id %s, %s", tostring(id), housed)
end

local function friendFamilies(S, clock)
  for rk, reg in pairs(ownRegions(S)) do
    local host = hostHomes(rk)
    local st = P.fam[rk]; if not st then st = {}; P.fam[rk] = st end
    local n = #reg.workerFamilies
    if host and #host > n then
      local sig = #host .. ">" .. n
      if st.sig ~= sig then st.sig = sig; st.since = clock end
      if clock - st.since >= FAM_AFTER and clock - (st.triedT or -1e9) >= FAM_AGAIN then
        st.triedT = clock
        for place = n + 1, #host do
          local ok, res, how = pcall(makeFamily, S, clock, rk, reg, place, host[place])
          local done = ok and res == true
          log("%s family %d (home %s) is on the host and not here: %s (%s)", rk, place, host[place], done and "made here" or "NOT made", tostring(done and how or (ok and how or res)))
          bump(done and "f_made" or "f_failed")
          if not done then break end                     -- the realm module asks for a reload when the lists stay different
        end
      end
    else st.sig = nil end
    -- A family made here lives where the host's lives, at once. (The events module moves every family to the host's
    -- home within its 5 to 10 s; for a family just made that is too close to the realm module's 10 s: in session 4r
    -- the host's family got its home a few seconds after it appeared, and the copies differed for 9 s.)
    if host then
      for key, M in pairs(P.made) do
        local rk2, place = key:match("^(.-)|(%d+)$"); place = tonumber(place)
        local want = rk2 == rk and place <= n and host[place] or nil
        -- still that family at that place? (its head says which family he belongs to)
        local same = false; pcall(function() same = valid(M.u) and math.floor(tonumber(M.u.workerFamilyID) or -1) == place - 1 end)
        if rk2 == rk and not same then P.made[key] = nil
        elseif want and want ~= M.home and clock - (M.homeT or -1e9) > 2.0 then
          M.homeT = clock
          local b = want ~= "-" and findBuilding(S, want) or nil
          if want == "-" or b then
            local ok, e = pcall(function() reg:SetFamilyHome(place - 1, b, true) end)
            log("%s family %d (made here) lives in %s on the host (%s here): %s", rk, place, want, tostring(M.home), ok and "moved" or ("NOT moved: " .. tostring(e)))
            if ok then M.home = want; bump("f_home") end
          end
        end
      end
    end
  end
end

-- the people of a family made here follow the host's family
local function friendMembers(S, clock)
  for key, M in pairs(P.made) do
    local rk, place = key:match("^(.-)|(%d+)$"); place = tonumber(place)
    local reg = ownRegions(S)[rk]
    local n = reg and #reg.workerFamilies or 0
    if not reg or place > n or not valid(M.u) then P.made[key] = nil      -- the family (or its head) is gone
    elseif clock - M.t >= SETTLE then
      local hm = hostPeople(rk, place, n)
      if hm then
        local ok, e = pcall(function()
          local F = reg.workerFamilies[place]; local m = F.familyMembers
          if #m < 1 then P.made[key] = nil; return end
          local first = un(m[1])
          if not valid(first) or addr(first) ~= addr(M.u) then P.made[key] = nil; return end   -- another family stands at this place now
          if #m >= #hm then M.since = nil; return end
          M.since = M.since or clock
          if clock - M.since < MEMBER_AFTER then return end
          local have = {}
          for j = 1, #m do local u = un(m[j]); if valid(u) then local r = tonumber(u.assignedUnitRole) or -1; have[r] = (have[r] or 0) + 1 end end
          local home = F.familyHome
          for _, p in ipairs(hm) do
            if (have[p.role] or 0) > 0 then have[p.role] = have[p.role] - 1
            elseif p.role == 3 then
              -- a daughter is never made: the game's own families here have sons only, and the one daughter this lane
              -- made (console, session 4) was in the town when the host died in a unit's equip call (see the report)
              if not P.said["daughter:" .. key] then P.said["daughter:" .. key] = true; log("%s family %d: %s is a daughter in the host's family: not made here", rk, place, p.n) end
            elseif p.role >= 0 and p.role <= 2 then
              local u, why = makeVillager(S, reg, p.role, spawnPlace(reg, home), p.n)
              if u then reg:AddNewFamilyMember(place - 1, u) end
              log("%s family %d: %s (role %d) is in the host's family and not here: %s", rk, place, p.n, p.role, u and "made here and joined" or ("NOT made: " .. tostring(why)))
              bump(u and "m_made" or "m_failed")
            end
          end
          M.t = clock; M.since = nil                      -- left alone again before the next look
        end)
        if not ok and P.lastErr ~= tostring(e) then P.lastErr = tostring(e); log("members: %s", P.lastErr); bump("err") end
      end
    end
  end
end

-- ================================================================ 1b. the host's growth, at once (lane 36)
-- The game grows a family by one person a day (growPopulation 4c64ee0, READ: the first family in list order with one
-- or two people, whose home is built and not in mourning and whose head has a home, gets a wife or else a son through
-- 4c51db0; at most one person a region a day) and brings a new family the same way. Each copy decides that at its own
-- day change from its own state, and a friend's state lags the host's by the link: a house the host finished two
-- seconds before the day change was not finished yet on the friend at that moment (lane 31, acc4: the friend's
-- population one game day behind the host's). So the host names each change of its families' sizes at once:
--   host -> friends   V G <region> <day> F <place> <home>          a family arrived at <place> (living in <home>, or -)
--                     V G <region> <day> M <place> <people> <home>  the family at <place> has <people> people now
--                     V G <region> <day> X <place> <home>          the family at <place> left (the list got shorter)
-- A friend's copy waits until its own day has reached <day> (its own growPopulation of that day has run) and half a
-- second more; then what its game did not do is made here: a missing person with the game's role rule (a wife when the
-- head has none, else a son) through makeVillager + AddNewFamilyMember, a family's home set to the host's. Only counts
-- and homes are read on the host (no unit of a family that is just changing: lane 5's rule).
local GROW_EVERY = 0.5      -- lane 45: the host looks at its families twice a second (it was every frame: 3.3 ms a frame in
                            -- sitting b0). The demolish case below (g3) does not need every frame: every town line that
                            -- demolishes is preceded by a look of its own (P.flushGrow, lane 39). Before, every frame:
                            -- (lane 36) the host looks at its families every frame (a demolished home's family is re-housed in the
                            -- same frame on the host; its new home must reach a friend before the town module's DEMOLISH
                            -- is applied there, or the friend shows the family homeless for a moment: g3)
local GROW_GRACE = 0.5      -- a friend acts this long after its own day reached the host's day
local GROW_PAUSED = 1.0     -- (lane 49, round five) ... but after this long when the game is paused (its day cannot come)
local GROW_GIVEUP = 8.0     -- a change this copy could not take in this time is left to the slow paths (realm, events)
local GROW_LEAVE = 5.0      -- the people of a family that left are removed this long after the family (off work first)
local function famState(reg)
  local t = {}; local fams = reg.workerFamilies
  for i = 1, #fams do
    local F = fams[i]
    -- the key is read fresh each time (a house's type changes with its level; an address can be reused)
    local h = "-"; pcall(function() local b = F.familyHome; if valid(b) then h = bkey(b) end end)
    local m = F.familyMembers; local n = #m
    -- the head's object address names the family on this copy (two families can share a house, and every homeless
    -- family reads "-"); the address is only compared, the object is not read (lane 5's rule for changing families)
    local id = h .. "/" .. n; if n >= 1 then pcall(function() local a = addr(m[1]); if a then id = tostring(a) end end) end
    t[i] = { n = n, h = h, id = id }
  end
  return t
end
local hostGrowBody
local function dayOf(eng) return eng:getDaysTotal() end
local function hostGrow(S, clock)
  -- (lane 45) every frame for 1.5 s after the day changed (the game grows, brings and houses families in its day routine,
  -- and a friend's daily comparison samples its families a moment after the host's: sitting a1, with looks only twice
  -- a second, showed 2 "B" differences in 60 days, b0 none), twice a second the rest of the day
  local okD, d = pcall(dayOf, S.eng)
  if okD and d ~= P.gDay then P.gDay = d; P.gHot = clock + 1.5 end
  if clock >= (P.gHot or 0) and clock - (P.tGrow or 0) < GROW_EVERY then return end
  P.tGrow = clock
  local t0 = os.clock()
  hostGrowBody(S, clock)
  P.gCost = P.gCost or { n = 0, ms = 0 }
  P.gCost.n = P.gCost.n + 1; P.gCost.ms = P.gCost.ms + (os.clock() - t0) * 1000
end
hostGrowBody = function(S, clock)
  local day = -1; pcall(function() day = S.eng:getDaysTotal() end)
  P.gLast = P.gLast or {}
  local regs = ownRegions(S)
  if P.on.growRivals and clock - (P.tGrowR or 0) >= 1.0 then       -- lane 39: the rival towns (lane 45: once a second, was four times)
    P.tGrowR = clock
    for k, r in pairs(rivalTowns(S)) do regs[k] = r end
  end
  for rk, reg in pairs(regs) do
    local now = famState(reg); local old = P.gLast[rk]; P.gLast[rk] = now
    if old then
      -- a family that left: the list is one shorter, and the first place whose head is another man is the one that
      -- left (the families behind it moved up one place)
      if #now == #old - 1 then
        local gone = #old
        for i = 1, #now do if old[i].id ~= now[i].id then gone = i; break end end
        A.send(string.format("V G %s %d X %d %s", rk, day, gone, old[gone].h)); bump("g_sentX")
        table.remove(old, gone)
      end
      for i = 1, #now do
        local a, b = old[i], now[i]
        if not a then A.send(string.format("V G %s %d F %d %s", rk, day, i, b.h)); bump("g_sentF")
          if b.n > 1 then A.send(string.format("V G %s %d M %d %d %s", rk, day, i, b.n, b.h)) end
        elseif a.n ~= b.n or a.h ~= b.h then A.send(string.format("V G %s %d M %d %d %s", rk, day, i, b.n, b.h)); bump("g_sentM") end
      end
      if #now < #old then for i = #now + 1, #old do A.send(string.format("V G %s %d X %d %s", rk, day, i, old[i].h)); bump("g_sentX") end end
    end
  end
end
-- lane 39: a demolished house with two families. The host's game re-houses the families in the frame it demolishes
-- the house; the town module's DEMOLISH line could then reach a friend before the V G line with the other family's new
-- home, and the friend showed one homeless family more for a moment (lane 36, fin3: host 1, friend 2 for 0.25 s). So
-- on the host every town line that demolishes is preceded by a look at the families (the V G lines go out first), and
-- a friend takes a V G line the moment it reads it (in the line's order), not in its next tick.
P.flushGrow = function() local S = P.S; if S and S.role == "host" and P.on.grow then hostGrowBody(S, os.clock()) end end
local function wrapTownOut()
  local T = rawget(C, "town"); if not (T and type(T.out) == "function") then return end
  if T.out == P.outWrap then return end
  local orig = T.out
  P.outWrap = function(line, ...)
    if type(line) == "string" and line:find(" DEMOLISH ", 1, true) then
      local Pp = rawget(_G, "Coop") and _G.Coop.people
      if Pp and Pp.flushGrow then local ok, e = pcall(Pp.flushGrow); if ok then Pp.stats.g_flushDem = (Pp.stats.g_flushDem or 0) + 1 end end
    end
    return orig(line, ...)
  end
  T.out = P.outWrap
end

-- a friend: take the host's changes once this copy's own day has run
local function growRole(F)
  local hus, wife = 0, 0
  local m = F.familyMembers
  for j = 1, #m do local u = un(m[j]); if valid(u) then local r = tonumber(u.assignedUnitRole) or -1; if r == 0 then hus = hus + 1 elseif r == 1 then wife = wife + 1 end end end
  if hus >= 1 and wife < 1 then return 1 end
  return 2
end
local function friendGrowOne(S, clock, ev)
  local reg = growRegions(S)[ev.rk]; if not reg then return true, "no such region of the player or a rival's town here" end
  local fams = reg.workerFamilies; local n = #fams
  if ev.kind == "F" or ev.kind == "M" then
    if ev.place > n then
      if ev.kind == "M" then return nil end                      -- the family is not here yet: the F line comes first
      if ev.place ~= n + 1 then return nil end
      local ok, res, how = pcall(makeFamily, S, clock, ev.rk, reg, ev.place, ev.home)
      bump(ok and res and "g_madeF" or "g_failF")
      return true, (ok and res) and ("family made here: " .. tostring(how)) or ("family NOT made: " .. tostring(ok and how or res))
    end
    local F = fams[ev.place]; local said = {}
    local hk = "-"; pcall(function() local b = F.familyHome; if valid(b) then hk = bkey(b) end end)
    if hk ~= ev.home then
      local b = ev.home ~= "-" and findBuilding(S, ev.home) or nil
      if ev.home == "-" or b then
        local ok, e = pcall(function() reg:SetFamilyHome(ev.place - 1, b, true) end)
        said[#said + 1] = ok and ("home " .. hk .. " -> " .. ev.home) or ("home NOT set: " .. tostring(e)); bump(ok and "g_home" or "g_homeFail")
      else said[#said + 1] = "the host's home " .. ev.home .. " is not a building here" end
    end
    if ev.kind == "M" then
      local have = #F.familyMembers
      if have < ev.n then
        if have < 1 or have + 1 ~= ev.n then said[#said + 1] = string.format("%d people here, %d on the host: left to the slow paths", have, ev.n)
        else
          local role = growRole(F)
          local home = F.familyHome
          local u, why = makeVillager(S, reg, role, spawnPlace(reg, valid(home) and home or nil), nil)
          if u then reg:AddNewFamilyMember(ev.place - 1, u); bump("g_madeM") else bump("g_failM") end
          said[#said + 1] = u and string.format("person %d (role %d) made here", ev.n, role) or ("person NOT made: " .. tostring(why))
        end
      elseif have > ev.n then said[#said + 1] = string.format("%d people here, %d on the host", have, ev.n); bump("g_more")
      else bump("g_same") end
    end
    return true, #said > 0 and table.concat(said, "; ") or nil
  elseif ev.kind == "X" then
    if ev.place > n then return true, nil end                    -- gone here as well
    local hk = "-"; pcall(function() local b = fams[ev.place].familyHome; if valid(b) then hk = bkey(b) end end)
    if hk ~= ev.home then return true, "the family at that place lives in " .. hk .. " here: left to the realm module" end
    local people = {}
    pcall(function() local m = fams[ev.place].familyMembers; for i = 1, #m do local u = un(m[i]); if valid(u) then people[#people + 1] = u end end end)
    -- the game's own departure (4c66e20, READ): unassignFamily, SetFamilyHome none, then removeWorkerFamilyAt; its
    -- people are not destroyed there but handed to the engine's leaving list. A villager destroyed while he works
    -- crashed a friend (lane 36, fin: a work hit of the event wheel on the destroyed unit, 4dc5270 -> 4db43c0): so the
    -- family is first taken off its work the game's way, and its people are removed only GROW_LEAVE s later
    local ok, e = pcall(function()
      pcall(function() reg:unassignFamily(ev.place - 1) end)
      pcall(function() reg:SetFamilyHome(ev.place - 1, nil, false) end)
      reg:removeWorkerFamilyAt(ev.place - 1)
    end)
    if ok then P.leaving = P.leaving or {}; for _, u in ipairs(people) do P.leaving[#P.leaving + 1] = { u = u, t = clock } end end
    bump(ok and "g_removed" or "g_removeFail")
    return true, ok and string.format("removed here (unassigned, no home, removed; its %d people go in %.0f s)", #people, GROW_LEAVE) or ("NOT removed: " .. tostring(e))
  end
  return true, nil
end
local function friendGrow(S, clock)
  local day = -1; pcall(function() day = S.eng:getDaysTotal() end)
  if day ~= P.gDay then P.gDay = day; P.gDayT = clock end              -- this copy's own day change, seen every frame
  local L = P.leaving
  if L and #L > 0 then
    local i = 1
    while i <= #L do
      local x = L[i]
      if clock - x.t >= GROW_LEAVE then
        table.remove(L, i)
        if valid(x.u) and not x.u.dead then pcall(function() S.eng:destroyUnit(x.u) end); bump("g_leftUnit") end
      else i = i + 1 end
    end
  end
  local q = P.gq; if not q or #q == 0 then return end
  -- What waits for this copy's own day: an arrival (F) and a person more (M with more people than here): this copy's
  -- own growPopulation of that day may make them. A departure (X: this copy's own emigration is held) and a new home
  -- (M with no person missing here) are taken at once: the host's game re-houses a family in the same frame it
  -- demolishes a house, and the town module's DEMOLISH must not find the family still there (fin2: homeless for a
  -- moment while this copy's day was a moment behind). The lines are taken in order: places refer to the host's list.
  local function waits(ev)
    if ev.kind == "X" then return false end
    if ev.kind == "M" then
      local more = true
      pcall(function() local reg = growRegions(S)[ev.rk]; local fs = reg.workerFamilies; if ev.place <= #fs then more = #fs[ev.place].familyMembers < ev.n end end)
      if not more then return false end
    end
    -- (lane 49, round five; the lead's session lead35: population host 60, friend 59 at a pause) the host's day changed
    -- and its family grew in the moment the game was paused: this copy, paused on the day before, cannot reach that day,
    -- so it showed one person fewer for GROW_GIVEUP (8 s) of the pause. Paused, the change is taken after GROW_PAUSED.
    if clock - ev.t >= GROW_PAUSED and select(2, pcall(C.api.isPaused)) == true then bump("g_paused"); return false end
    return not (day >= ev.day and clock - (P.gDayT or 0) >= GROW_GRACE)
  end
  local i = 1
  while i <= #q do
    local ev = q[i]
    local ready = not waits(ev) or clock - ev.t >= GROW_GIVEUP
    if not ready then break
    else
      local ok, done, what = pcall(friendGrowOne, S, clock, ev)
      if not ok then table.remove(q, i); log("growth: %s %s %d failed: %s", ev.rk, ev.kind, ev.place, tostring(done)); bump("err")
      elseif done then
        table.remove(q, i)
        if what then log("growth: %s day %d %s family %d%s on the host (%.2f s after the line): %s", ev.rk, ev.day, ev.kind, ev.place, ev.kind == "M" and (" " .. ev.n .. " people") or "", clock - ev.t, what) end
      elseif clock - ev.t >= GROW_GIVEUP then table.remove(q, i); log("growth: %s day %d %s family %d: not taken in %.0f s (left to the slow paths)", ev.rk, ev.day, ev.kind, ev.place, GROW_GIVEUP); bump("g_giveup")
      else break end                                               -- not yet (the family is not here yet): in order
    end
  end
end

-- ================================================================ 2. the other lords' towns
local function upgIds(b)
  local t = {}; local a = b.upgradesDone
  for i = 1, #a do local v = a[i]; if type(v) ~= "number" then v = v:get() end; t[#t + 1] = math.floor(tonumber(v) or -1) end
  return t
end

-- this copy's buildings of the rival lords as { code = { entry, ... } }, read a slice per tick; done(per) when complete
-- (lane 47) the same lists from the native building table (coop_snap.lua), in one frame: the owner, function, type,
-- built flag and upgrades come from the table; place and turn by the game's own calls once per building; a lord's code
-- once per owner (its object checked valid at every pass). Without the table (not checked yet, refused, another game
-- build) the reflected scan below runs as before.
local N_obj, N_loc
local function scanSnap(S, done, recs)
  local per = {}
  local me = addr(S.p1)
  local OC = P.ownC; if not OC or OC.S ~= S or OC.w ~= S.worlds then OC = { S = S, w = S.worlds, by = {} }; P.ownC = OC end
  local seen = {}
  for _, r in ipairs(recs) do
    local oa = r.own or 0
    local code
    if oa == 0 then code = "-"
    elseif oa == me then code = "P"
    else
      code = seen[oa]
      if code == nil then
        local c = OC.by[oa]
        if c and not valid(c.o) then c = nil end
        if not c then
          local b = N_obj(r); local op = b and b.ownerPawn
          c = { o = op, code = (op ~= nil and valid(op)) and ownerCode(S, op) or "-" }
          if c.code ~= "-" then OC.by[oa] = c end
        end
        code = c.code; seen[oa] = code
      end
    end
    if code:match("^A%d+$") and not SKIP_FN[r.fn] then
      local okL, x, y, z, yaw = pcall(N_loc, r)
      local b = okL and x and N_obj(r)
      if b then
        if r.uVer ~= r.ver or not r.uList then
          local u = {}; for v in (r.ups or ""):gmatch("%d+") do u[#u + 1] = math.floor(tonumber(v)) end
          r.uList = u; r.uVer = r.ver
        end
        local u = {}; for i, v in ipairs(r.uList) do u[i] = v end
        local e = { b = b, t = r.t, x = x, y = y, z = z, yaw = yaw, fn = r.fn, c = r.cons and 1 or 0, u = u }
        e.us = table.concat(e.u, "."); e.pos = posKey(x, y); e.key = e.t .. "@" .. e.pos
        local L = per[code]; if not L then L = {}; per[code] = L end
        L[#L + 1] = e
      end
    end
  end
  bump("scan_snap")
  done(per)
end
local function scan(S, done)
  -- (lane 47) the native table when it is there (a pass already begun the old way ends the old way)
  if not P.scan and done then
    local N = rawget(C, "snap"); local recs = N and N.buildings and N.buildings()
    if recs then N_obj, N_loc = N.obj, N.loc; return scanSnap(S, done, recs) end
  end
  local st = P.scan
  if not st then st = { i = 0, per = {}, done = done, own = {} }; P.scan = st end   -- (own: lane 42, a lord's code once per pass)
  local arr = S.eng.buildingArr; local n = 0
  while st.i < #arr and n < 40 do
    st.i = st.i + 1; n = n + 1
    local b = un(arr[st.i])
    if valid(b) then
      pcall(function()
        -- lane 42 round two: the scan runs every 0.5 s now, so a lord's code (a game call per building) is worked out
        -- once per pass and owner, by the owner's address
        local op = b.ownerPawn; local oa = valid(op) and addr(op) or 0
        local code = st.own[oa]; if code == nil then code = ownerCode(S, op); st.own[oa] = code end
        if not code:match("^A%d+$") then return end       -- rival lords only (the mod's helper lord reads A-1)
        local fn = tonumber(b.buildingFunction) or -1
        if SKIP_FN[fn] then return end
        local l = b:K2_GetActorLocation()
        local e = { b = b, t = A.btype(b), x = l.X, y = l.Y, z = l.Z, yaw = b:K2_GetActorRotation().Yaw, fn = fn, c = b.Data.constructed and 1 or 0, u = upgIds(b) }
        e.us = table.concat(e.u, "."); e.pos = posKey(l.X, l.Y); e.key = e.t .. "@" .. e.pos
        local L = st.per[code]; if not L then L = {}; st.per[code] = L end
        L[#L + 1] = e
      end)
    end
  end
  if st.i >= #arr then P.scan = nil; st.done(st.per) end
end

-- ---- host
local function hostRival(S, clock, per)
  P.lastB = per
  local key = clock - P.tKeyB >= KEY; if key then P.tKeyB = clock end
  local codes = {}
  for code in pairs(per) do codes[code] = true end
  for code in pairs(P.sentB) do codes[code] = true end
  for code in pairs(codes) do
    local list = per[code] or {}
    table.sort(list, function(a, b) return a.key < b.key end)
    local parts, keys = {}, {}
    for i, e in ipairs(list) do
      parts[i] = string.format("%d,%.2f,%.2f,%.2f,%.1f,%d,%d,%s", e.t, e.x, e.y, e.z, e.yaw, e.fn, e.c, e.us ~= "" and e.us or "-")
      keys[e.key] = e.us
    end
    local sig = table.concat(parts, ";")
    if sig ~= P.sentB[code] or key then
      if sig ~= P.sentB[code] then
        bump("b_sent")
        local old = P.keysB[code]
        if old then                                      -- say what changed (the first look in a world says nothing)
          local d = {}
          for k, us in pairs(keys) do if old[k] == nil then d[#d + 1] = "+" .. k elseif old[k] ~= us then d[#d + 1] = k .. " upgrades " .. (us ~= "" and us or "-") end end
          for k in pairs(old) do if keys[k] == nil then d[#d + 1] = "-" .. k end end
          if #d > 0 then log("rival %s on the host: %s", code, table.concat(d, " "):sub(1, 400)) end
          -- lane 42: a new house's lot goes out at once (a friend made a house only after asking for it: 2 s more)
          for _, e in ipairs(list) do
            if old[e.key] == nil and e.fn == HOUSE_FN and valid(e.b) then
              local okL, lot = pcall(P.lotOf, e.b)   -- (lotOf is defined below; P.lotOf is set there)
              if okL and lot then A.send(string.format("V LOT %s %s %s", code, e.key, lot)); bump("lot_pushed") end
            end
          end
        end
      end
      P.sentB[code] = sig; P.keysB[code] = keys
      local i = 1
      repeat                                             -- lines under 3000 characters
        local buf, len, first = {}, 0, i
        while i <= #parts and (len == 0 or len + #parts[i] + 1 <= 3000) do buf[#buf + 1] = parts[i]; len = len + #parts[i] + 1; i = i + 1 end
        A.send(string.format("V B %s %d %d %s", code, #parts, first, #buf > 0 and table.concat(buf, ";") or "-"))
      until i > #parts
    end
  end
end

-- a house's lot in the town module's HOUSE form (coop_town.lua encLot): border / corners / house place / back building /
-- backyard / back wall / backyard border / backyard corners. The border and the corners are the building's own lists;
-- the back building and the backyard are left empty (the house was made that way in session 2 of this lane).
local function lotOf(b)
  local function pts(a) local o = {}; for i = 1, #a do local v = a[i]; o[i] = string.format("%.2f,%.2f,%.2f", v.X, v.Y, v.Z) end; return #o > 0 and table.concat(o, "|") or "-" end
  local function tr(x) local q, t, s = x.Rotation, x.Translation, x.Scale3D; return string.format("%.5f,%.5f,%.5f,%.5f,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f", q.X, q.Y, q.Z, q.W, t.X, t.Y, t.Z, s.X, s.Y, s.Z) end
  local c = b.fieldBorderPoints
  if #b.FieldPoints < 3 or #c < 2 then return nil end
  local wall = string.format("%.2f,%.2f,%.2f|%.2f,%.2f,%.2f", c[1].X, c[1].Y, c[1].Z, c[2].X, c[2].Y, c[2].Z)
  -- lane 42 round two: the backyard. A rival house the friend drew from this lot came without its backyard (its
  -- Extensions list empty, the host's one record: Type, transf, its pieces, dirt planes; t_ext.lua). The lot's extension
  -- transform is that record's transf: the game makes the backyard slot from it when the lot is committed.
  local ext = ZT
  pcall(function() local ex = b.Extensions; if #ex > 0 then ext = tr(ex[1].transf) end end)
  return table.concat({ pts(b.FieldPoints), pts(c), tr(b:GetTransform()), ZT, ext, wall, "-", "-" }, "/")
end

P.lotOf = lotOf                                      -- lane 42: for the host's unasked lot of a new house
local function hostAsk(S, from, code, key)
  local list = P.lastB and P.lastB[code]
  for _, e in ipairs(list or {}) do
    if e.key == key and valid(e.b) then
      local ok, lot = pcall(lotOf, e.b)
      if ok and lot then A.send(string.format("V LOT %s %s %s", code, key, lot)); bump("lot_sent"); log("%s asked for the lot of %s %s: sent (%d characters)", tostring(from), code, key, #lot)
      else log("%s asked for the lot of %s %s: it has none (%s)", tostring(from), code, key, tostring(lot)) end
      return
    end
  end
  log("%s asked for the lot of %s %s: no such building here", tostring(from), tostring(code), tostring(key))
end

-- ---- friend
local function parseEntry(s)
  local t, x, y, z, yaw, fn, c, u = s:match("^(%d+),(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+),(%-?%d+),(%d),([%d%.%-]+)$")
  if not t then return nil end
  local e = { t = tonumber(t), x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw), fn = tonumber(fn), c = tonumber(c), u = {} }
  if not (e.t and e.x and e.y and e.z and e.yaw) then return nil end
  if u ~= "-" then for id in u:gmatch("%d+") do e.u[#e.u + 1] = tonumber(id) end end
  e.pos = posKey(e.x, e.y); e.key = math.floor(e.t) .. "@" .. e.pos
  return e
end

-- the upgrades of <want> that <have> lacks, in the host's order (lane 42 round two: animal orders too)
local function missing(want, have)
  local left = {}; for _, id in ipairs(have) do left[id] = (left[id] or 0) + 1 end
  local t = {}
  for _, id in ipairs(want) do
    if (left[id] or 0) > 0 then left[id] = left[id] - 1
    else t[#t + 1] = id end   -- lane 42 round two: animal upgrades too (a rival house's animal pen: upgradesDone 2 / 1, animals 2 / 0 in a6; his AI orders on the host only)
  end
  return t
end

local function sayOnce(key, fmt, ...) if not P.said[key] then P.said[key] = true; log(fmt, ...) end end

-- a difference that has lasted long enough becomes a job (one try every 20 s, three tries)
local function want(clock, seen, kind, code, key, job)
  local id = kind .. ":" .. code .. ":" .. key
  seen[id] = true
  P.since[id] = P.since[id] or clock
  if clock - P.since[id] < ((kind == "remove") and RIVAL_AFTER or 0) or P.queued[id] then return end   -- lane 42: making and upgrading at the first look (the host's list is complete or not taken)
  local tr = P.tries[id]
  if tr and (tr.n >= TRIES or clock - tr.t < TRY_AGAIN) then
    if tr.n >= TRIES then sayOnce("gaveup:" .. id, "rival %s: %s of %s was tried %d times and is given up (the copies differ there)", code, kind, key, TRIES) end
    return
  end
  job.kind = kind; job.code = code; job.key = key; job.id = id; job.since = P.since[id]
  P.queued[id] = true; P.jobs[#P.jobs + 1] = job
end

-- does the HOST give the region of this building to that lord? (the events module's owner line: tag = lord)
local function hostGives(m, code)
  local E = rawget(C, "events"); local HO = E and E.hostO
  if type(HO) ~= "table" then return false end
  if not valid(m.b) then return false end   -- (lane 47 round four) the old way's scan lists span several ticks
  local ok, tag = pcall(function() return rkey(m.b.Region) end)
  return ok and tag ~= nil and HO[tag] == code
end

local function friendRival(S, clock, per)
  local seen = {}
  for code, H in pairs(P.hostB) do
    if H.list then
      local mine = per[code] or {}
      local have, at, hostAt = {}, {}, {}
      for _, m in ipairs(mine) do have[m.key] = m; at[m.pos] = m end
      for _, h in ipairs(H.list) do
        hostAt[h.pos] = h
        local m = have[h.key] or at[h.pos]
        if m then
          -- the same building, or another type at the same place: the upgrades the host's has and this one lacks
          local miss = missing(h.u, m.u)
          if #miss > 0 then
            if P.on.rivalUpgrade then want(clock, seen, "upgrade", code, h.key, { h = h, m = m, miss = miss }) end
          elseif m.key ~= h.key then sayOnce("type:" .. code .. h.key, "rival %s: %s on the host is %s here and no upgrade explains it: left as it is", code, h.key, m.key) end
        elseif PLOT_FN[h.fn] then sayOnce("plot:" .. code .. h.key, "rival %s: %s on the host is a %s (a drawn plot): not made here", code, h.key, PLOT_FN[h.fn])
        elseif h.t == 100 or h.t == 483 then sayOnce("own:" .. code .. h.key, "rival %s: %s would belong to the lord that places it: not made here", code, h.key)
        elseif P.on.rivalMake then want(clock, seen, "make", code, h.key, { h = h }) end
      end
      if P.on.rivalRemove then
        -- A building leaves the host's list when the rival removes it, but also when its region changes hands or
        -- when a list comes short. So nothing is removed unless the host still gives that building's region to this
        -- lord (the events module's owner line), and never more than MAX_REMOVE buildings of a lord at one look.
        local gone = {}
        for _, m in ipairs(mine) do if not hostAt[m.pos] and not PLOT_FN[m.fn] then gone[#gone + 1] = m end end
        if #gone > MAX_REMOVE then
          sayOnce("many:" .. code .. #gone, "rival %s: %d of his buildings here are not in the host's list at once: none is removed (a region changed hands, or a short list)", code, #gone)
        else
          for _, m in ipairs(gone) do
            if hostGives(m, code) then want(clock, seen, "remove", code, m.key, { m = m })
            else sayOnce("held:" .. code .. m.key, "rival %s: %s is not in the host's list, but the host does not give its region to %s (any more): not removed", code, m.key, code) end
          end
        end
      end
    end
  end
  for id in pairs(P.since) do if not seen[id] then P.since[id] = nil; P.tries[id] = nil end end
end

local function tried(job, clock) local tr = P.tries[job.id]; if not tr then tr = { n = 0 }; P.tries[job.id] = tr end; tr.n = tr.n + 1; tr.t = clock end
local function regionOwnerAt(S, h)
  local ok, code = pcall(function() local r = S.eng:getRegionByPos({ X = h.x + 0.0, Y = h.y + 0.0, Z = h.z + 0.0 }, false); return valid(r) and ownerCode(S, r.ownerPawn) or "-" end)
  return ok and code or "?"
end

-- one upgrade of a building, the way the game's own request pump does it (BeginUpgrade for building upgrades,
-- changeArtisanType / ChangeExtension for a house's workshop / backyard); nil = not now
local function doUpgrade(S, job)
  local b = job.m.b
  if not valid(b) then return false, "the building is gone" end
  local busy = false; pcall(function() busy = b.isBeingUpgraded or not b.Data.constructed end)
  if busy then return nil end                            -- a site or an upgrade under way here: wait until it is finished
  local id = job.miss[1]; local how = "BeginUpgrade"
  local T = C.town
  local ok, e = pcall(T.quiet, function()
    if id >= 100 then
      if #b.Extensions < 1 then error("this house has no backyard here") end
      if ARTISAN[id] then how = "changeArtisanType"; b:changeArtisanType(id - 100) else how = "ChangeExtension"; b:ChangeExtension(0, id - 100) end
    else b:BeginUpgrade(id) end
  end)
  if not ok then return false, how .. "(" .. id .. ") failed: " .. tostring(e) end
  return true, how .. "(" .. id .. ")"
end

local function finishJob(S, clock, cur, status)
  local job = cur.job; local T = C.town
  local okay = status == "ok"
  local detail = tostring(status)
  if okay and job.kind == "make" then
    local h = job.h
    local b = T.findB(job.madeT or h.t, h.x, h.y)
    local own = b and ownerCode(S, b.ownerPawn) or "no building"
    detail = string.format("owner %s, %s", own, b and (b.Data.constructed and "built" or "a site") or "-")
    if own ~= job.code then
      okay = false; bump("b_wrongOwner")
      log("rival %s: %s was made here but belongs to %s: making is switched off", job.code, job.key, own)
      P.on.rivalMake = false
      if b and own == "P" then pcall(function() T.inject("DEMOLISH", string.format("%d,%.0f,%.0f,%.0f", job.madeT or h.t, h.x, h.y, h.z), "people") end) end
    end
  end
  if job.kind == "make" then log("rival %s: %s is on the host and was missing here: %s (%s; %.1f s after the difference was seen)", job.code, job.key, okay and "made" or "NOT made", detail, clock - job.since)
  else log("rival %s: %s is gone on the host: %s here (%s; %.1f s after the difference was seen)", job.code, job.key, okay and "removed" or "NOT removed", detail, clock - job.since) end
  bump((job.kind == "make" and "b_made" or "b_removed") .. (okay and "" or "Failed"))
  P.queued[job.id] = nil
end

-- one job handed to the town module (its own action, through the helper lord); nil when it could not be handed over
local function inject(job, act, fields)
  local ok, id, st = pcall(C.town.inject, act, fields, "people")
  if ok then return id, st end
  P.queued[job.id] = nil
  log("rival %s: the town module could not take %s for %s: %s", job.code, act, job.key, tostring(id))
end

local function runJobs(S, clock)
  local T = C.town; if not (T and T.inject and T.results) then return end
  local cur = P.cur
  if cur then
    local st = T.results[cur.id]
    if st == nil or st == "queued/pending" then
      if clock - cur.t < 12.0 then return end
      st = "no answer from the town module in 12 s"
    end
    P.cur = nil
    finishJob(S, clock, cur, st)
  end
  local i = 1
  while i <= #P.jobs do
    local job = P.jobs[i]
    if job.kind == "upgrade" then
      if C.traceF then C.trace("people:doUpgrade " .. tostring(job.key)) end   -- (lane 47, round three: test switch only)
      local ok, how = doUpgrade(S, job)
      if ok ~= nil then
        table.remove(P.jobs, i); P.queued[job.id] = nil; tried(job, clock)
        log("rival %s: %s has upgrade %d on the host and not here: %s (%s)", job.code, job.key, job.miss[1], ok and "started here" or "NOT started", tostring(how))
        bump(ok and "b_upgraded" or "b_upgradeFailed")
      elseif clock - job.since > 120.0 then table.remove(P.jobs, i); P.queued[job.id] = nil; P.since[job.id] = nil   -- still a site here: looked at again later
      else i = i + 1 end
    elseif T.pend or #T.aq > 0 then i = i + 1               -- the helper lord is busy with a player's action: those go first
    else
      table.remove(P.jobs, i)
      local id, st
      if job.kind == "make" then
        local h = job.h
        local own = regionOwnerAt(S, h)
        if own ~= job.code then
          sayOnce("region:" .. job.id, "rival %s: %s stands in a region that is held by %s here: not made yet", job.code, job.key, own)
          P.queued[job.id] = nil; P.since[job.id] = clock    -- looked at again after the usual wait
        elseif h.fn == HOUSE_FN then
          local lot = P.lots[job.code .. "|" .. job.key]
          if not lot then
            if clock - (P.lotAsked[job.id] or -1e9) > 10.0 then P.lotAsked[job.id] = clock; A.send(string.format("V ASK %s %s", job.code, job.key)); bump("lot_asked") end
            P.queued[job.id] = nil                            -- queued again by the next look, when the lot is here
          else
            tried(job, clock); job.madeT = 3                  -- a new house is level 1 (type 3); its level follows as an upgrade
            id, st = inject(job, "HOUSE", lot)
          end
        else
          tried(job, clock)
          id, st = inject(job, "BUILD", string.format("%d,%.2f,%.2f,%.2f,%.1f", h.t, h.x, h.y, h.z, h.yaw))
        end
      else
        local m = job.m
        tried(job, clock)
        id, st = inject(job, "DEMOLISH", string.format("%d,%.0f,%.0f,%.0f", m.t, m.x, m.y, m.z))
      end
      if id then P.cur = { job = job, id = id, t = clock }; return end
    end
  end
end

-- ================================================================ lane 42: the rival lords' roads
-- A rival's AI draws roads on the host only (its AI is off on a friend). Measured (lane 42, base): the engine's road
-- list 77 / 75 after 40 days; two rival buildings stood by a road on the host and by none on the friend
-- (snappedToRoad 1 / 0, connectedRoadPoints 1 / 0). The host names every road that lies in a rival lord's region
-- (the road's regionA or regionB is held by a lord other than the player, not bandits), by its two ends:
--   host -> friends   V D <roads> <first in this line> <ax,ay,bx,by=x,y,z|x,y,z|...;...>       (ends in 10 cm)
--                     when the list changes and every KEY s
-- A friend that lacks a road for RIVAL_AFTER s draws it with the town module's own ROAD (the helper lord's
-- setRoadMode, roadPoints, the draft spline, commitRoad: what a player's road replays), three tries 20 s apart.
-- A road the friend has and the host does not is left alone (a rival does not remove roads in the measured runs).
local ROAD_EVERY = 2.0
local function roadInfo(S, r)
  if not valid(r) then return nil end
  local ok, res = pcall(function()
    if r.isBlueprint or r.isBorder or r.roadType == 3 then return nil end   -- castle plans, borders: not a road of a town
    local sp = r.Spline; local n = sp:GetNumberOfSplinePoints(); if n < 2 then return nil end
    -- the region a road lies in: by its first point (a town road's regionA / regionB are not set: measured "?")
    local p0 = sp:GetLocationAtSplinePoint(0, 1)
    local g = S.eng:getRegionByPos({ X = p0.X + 0.0, Y = p0.Y + 0.0, Z = p0.Z + 0.0 }, false)
    local code = valid(g) and ownerCode(S, g.ownerPawn) or "-"
    if not code:match("^A%d+$") then return nil end
    local pts = {}
    for i = 0, n - 1 do local v = sp:GetLocationAtSplinePoint(i, 1); pts[#pts + 1] = string.format("%.2f,%.2f,%.2f", v.X, v.Y, v.Z) end
    local a = sp:GetLocationAtSplinePoint(0, 1); local z = sp:GetLocationAtSplinePoint(n - 1, 1)
    return { code = code, ax = a.X, ay = a.Y, bx = z.X, by = z.Y, pts = table.concat(pts, "|"),
             key = string.format("%d,%d,%d,%d", math.floor(a.X / 10 + 0.5), math.floor(a.Y / 10 + 0.5), math.floor(z.X / 10 + 0.5), math.floor(z.Y / 10 + 0.5)) }
  end)
  if ok then return res end
end
-- (cost, measured in a3: re-reading every road's spline every 2 s cost the host 0.7 ms a frame, and the whole list
-- repeated every 60 s 300 bytes a second. So a road is read once, by its address and name, and again only every
-- ROAD_FULL s (a region may change hands); the whole list is repeated every ROAD_KEY s and when a friend asks.)
local ROAD_FULL, ROAD_KEY = 60.0, 300.0
local function hostRoads(S, clock)
  local list = {}; local arr = S.eng.roads; local n = #arr
  local full = clock - (P.tFullD or -1e9) >= ROAD_FULL; if full then P.tFullD = clock; P.roadC = {} end
  P.roadC = P.roadC or {}
  local seen = {}
  for i = 1, n do
    local r = un(arr[i])
    if valid(r) then
      local a = addr(r); local okN, nm = pcall(function() return r:GetFName():ToString() end); local id = a and (a .. ":" .. (okN and tostring(nm) or "?")) or nil
      local e = id and P.roadC[id]
      if e == nil then e = roadInfo(S, r) or false; if id then P.roadC[id] = e end end
      if id then seen[id] = true end
      if e then list[#list + 1] = e.key .. "=" .. e.pts end
    end
  end
  for id in pairs(P.roadC) do if not seen[id] then P.roadC[id] = nil end end
  table.sort(list)
  local sig = table.concat(list, ";")
  local key = clock - (P.tKeyD or -1e9) >= ROAD_KEY
  if sig == P.sentD and not key then return end
  if sig ~= P.sentD then bump("d_sent") end
  P.sentD = sig; if key then P.tKeyD = clock end
  local i = 1
  repeat
    local buf, len, first = {}, 0, i
    while i <= #list and (len == 0 or len + #list[i] + 1 <= 3000) do buf[#buf + 1] = list[i]; len = len + #list[i] + 1; i = i + 1 end
    A.send(string.format("V D %d %d %s", #list, first, #buf > 0 and table.concat(buf, ";") or "-"))
  until i > #list
end
local function friendRoads(S, clock)
  local T = C.town; local D = P.hostD
  if not (D and D.list and T and T.findRoad and T.inject and T.results) then return end
  -- one road at a time through the town module (the helper lord); the one under way first
  if P.curD then
    local st = T.results[P.curD.id]
    if (st == nil or st == "queued/pending") and clock - P.curD.t < 12.0 then return end
    log("rival road %s: missing here, drawn with the town module's ROAD: %s (%.1f s after it was seen)", P.curD.key, tostring(st or "no answer in 12 s"), clock - P.curD.since)
    bump((st == "ok") and "d_made" or "d_failed"); P.curD = nil
  end
  if T.pend or #(T.aq or {}) > 0 or P.cur then return end   -- the helper is busy (a player's action, a rival building)
  P.sinceD = P.sinceD or {}; P.triesD = P.triesD or {}
  local seen = {}
  for _, e in ipairs(D.list) do
    seen[e.key] = true
    local okF, r = pcall(T.findRoad, e.ax, e.ay, e.bx, e.by)
    if okF and r then P.sinceD[e.key] = nil; P.triesD[e.key] = nil
    else
      P.sinceD[e.key] = P.sinceD[e.key] or clock
      local tr = P.triesD[e.key] or { n = 0, t = -1e9 }
      if clock - P.sinceD[e.key] >= RIVAL_AFTER and tr.n < TRIES and clock - tr.t >= TRY_AGAIN then
        tr.n = tr.n + 1; tr.t = clock; P.triesD[e.key] = tr
        local ok, id = pcall(T.inject, "ROAD", e.pts, "people")
        if ok and id then P.curD = { id = id, key = e.key, t = clock, since = P.sinceD[e.key] }; return end
        log("rival road %s: the town module could not take ROAD: %s", e.key, tostring(id))
      elseif tr.n >= TRIES then sayOnce("road:" .. e.key, "rival road %s: drawn %d times and still missing here: given up", e.key, TRIES) end
    end
  end
  for k in pairs(P.sinceD) do if not seen[k] then P.sinceD[k] = nil end end
end
-- lane 42 round two: a rival building's link to its road (SMBuildingMaster.snappedToRoad). Measured: 18@9400,7460 is
-- linked to the road 92473,77245-97112,73862 on the host and to none on the friend, from the friend's load on; the
-- road itself is on both copies (content probe). The host names each rival building's road by its ends with the road
-- list (V K <bkey>=<ax,ay,bx,by>;... on change and every ROAD_KEY s); a friend whose building has no road link there
-- sets it to its own road with those ends (an object property, written as the game keeps it; only on a building still
-- in this copy's list and in a region, only when the road is found).
local function hostLinks(S, clock, per)
  if clock - (P.tLinks or -1e9) < 5.0 then return end; P.tLinks = clock   -- every 5 s (the scan runs every 0.5 s)
  local items = {}
  for code, list in pairs(per or {}) do
    for _, e in ipairs(list) do
      pcall(function()
        if not valid(e.b) then return end   -- (lane 47 round four) the old way's scan lists span several ticks
        local r = e.b.snappedToRoad
        if valid(r) then
          local sp = r.Spline; local n = sp:GetNumberOfSplinePoints()
          local a = sp:GetLocationAtSplinePoint(0, 1); local z = sp:GetLocationAtSplinePoint(n - 1, 1)
          items[#items + 1] = string.format("%s=%.0f,%.0f,%.0f,%.0f", e.key, a.X, a.Y, z.X, z.Y)
        end
      end)
    end
  end
  table.sort(items)
  local sig = table.concat(items, ";")
  if sig == P.sentK and clock - (P.tKeyK or -1e9) < ROAD_KEY then return end
  P.sentK = sig; P.tKeyK = clock
  local i = 1
  repeat
    local buf, len = {}, 0
    while i <= #items and (len == 0 or len + #items[i] + 1 <= 3000) do buf[#buf + 1] = items[i]; len = len + #items[i] + 1; i = i + 1 end
    A.send("V K " .. (#buf > 0 and table.concat(buf, ";") or "-"))
  until i > #items
end
local function friendLinks(S, per)
  local now = os.clock(); if now - (P.tLinksF or -1e9) < 2.0 then return end; P.tLinksF = now
  local T = C.town; local K = P.hostK
  if not (K and T and T.findRoad) then return end
  local mine = {}
  for _, list in pairs(per or {}) do for _, e in ipairs(list) do mine[e.key] = e end end
  for key, ends in pairs(K) do
    local e = mine[key]
    if e and valid(e.b) then
      pcall(function()
        if valid(e.b.snappedToRoad) or not valid(e.b.Region) then return end
        local r = T.findRoad(ends[1], ends[2], ends[3], ends[4])
        -- (the town module's road index is built a slice at a time after a load: a7 linked 2 min late; so the
        -- world's road list is looked through too, by the two ends within 3 m)
        if not valid(r) then
          local arr = S.eng.roads
          for i = 1, #arr do
            local x = un(arr[i])
            if valid(x) then
              local ok, hit = pcall(function()
                local sp = x.Spline; local n = sp:GetNumberOfSplinePoints(); if n < 2 then return false end
                local a = sp:GetLocationAtSplinePoint(0, 1); local z = sp:GetLocationAtSplinePoint(n - 1, 1)
                local function near(p, qx, qy) return math.abs(p.X - qx) < 300 and math.abs(p.Y - qy) < 300 end
                return (near(a, ends[1], ends[2]) and near(z, ends[3], ends[4])) or (near(a, ends[3], ends[4]) and near(z, ends[1], ends[2]))
              end)
              if ok and hit then r = x; break end
            end
          end
        end
        if valid(r) then e.b.snappedToRoad = r; bump("k_linked"); log("rival building %s linked to its road here, as on the host", key) end
      end)
    end
  end
end
local function onLinkLine(w)
  P.hostK = P.hostK or {}
  for key, a, b, c, d in (w[5] or ""):gmatch("([%d]+@%-?%d+,%-?%d+)=(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)") do
    P.hostK[key] = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
  end
end
-- lane 42 round two: the trade screen's log (RTSMultiEngineCPP.tradeLog: fromBuilding, toBuilding, fromRegionIndex,
-- toRegionIndex, goodType, goodAmt, priceTotal, daysTotal, traderName, isImport; t_ext.lua). Measured: each copy logs its
-- own merchants' trades (host 48 records, friend 49, the last ones other trades on other days). The host sends its
-- log, the last LOG_MAX records, when it changed (looked at every 2 s):
--   V T <records> <first in this line> <from>,<to>,<fromIdx>,<toIdx>,<good>,<amt>,<price>,<day>,<trader>,<import 1|0>;...
--   from / to = a building key (its comma written "/") or "-"; trader = the name, "-" for none
-- A friend whose log differs from the host's rebuilds it: emptied with the list's own Empty, then each record appended
-- (a read one past the end adds an empty record: the UE4SS rule, used on purpose here) and its fields written; a
-- building is this copy's building with that key, else none.
local LOG_MAX = 60
local function bkeyOrDash(o) if not valid(o) then return "-" end; local ok, k = pcall(bkey, o); return ok and (k:gsub(",", "/")) or "-" end   -- (a key's comma as "/": the record is comma-separated)
local function logRec(r)
  local tn = "-"; pcall(function() tn = r.traderName:ToString() end); if tn == "" or tn == "None" then tn = "-" end
  return string.format("%s,%s,%d,%d,%d,%d,%d,%d,%s,%d", bkeyOrDash(r.fromBuilding), bkeyOrDash(r.toBuilding), r.fromRegionIndex, r.toRegionIndex,
    r.goodType, r.goodAmt, r.priceTotal, r.daysTotal, (tn:gsub("[%s,;]", "_")), r.isImport and 1 or 0)
end
local function logList(S)
  local t = {}; local arr = S.eng.tradeLog; local n = #arr
  for i = math.max(1, n - LOG_MAX + 1), n do local ok, x = pcall(logRec, arr[i]); t[#t + 1] = ok and x or "?" end
  return t
end
local function hostLog(S, clock)
  local n = #S.eng.tradeLog
  local lastSig = n > 0 and (n .. ":" .. (select(2, pcall(logRec, S.eng.tradeLog[n])) or "?")) or "0"
  if lastSig == P.logSig and clock - (P.tKeyT or -1e9) < ROAD_KEY then return end
  P.logSig = lastSig; P.tKeyT = clock
  local list = logList(S)
  local i = 1
  repeat
    local buf, len, first = {}, 0, i
    while i <= #list and (len == 0 or len + #list[i] + 1 <= 3000) do buf[#buf + 1] = list[i]; len = len + #list[i] + 1; i = i + 1 end
    A.send(string.format("V T %d %d %s", #list, first, #buf > 0 and table.concat(buf, ";") or "-"))
  until i > #list
  bump("t_sent")
end
local function onLogLine(w)
  local n, first = tonumber(w[5]), tonumber(w[6]); if not (n and first) then return end
  local L = P.hostT; if not L then L = {}; P.hostT = L end
  if first == 1 then L.part = {} end
  if not L.part then return end
  if w[7] and w[7] ~= "-" then for x in w[7]:gmatch("[^;]+") do L.part[#L.part + 1] = x end end
  if #L.part >= n then
    if #L.part == n then L.list = L.part; L.dirty = true else bump("t_badLine") end
    L.part = nil
  end
end
local function friendLog(S)
  local L = P.hostT; if not (L and L.list) then return end
  local now = os.clock(); if now - (P.tLogF or -1e9) < 2.0 then return end; P.tLogF = now   -- every 2 s: this copy's own trades are replaced too
  -- (cost: the whole list is read only when its length or last record changed here, or the host's list changed)
  local arr0 = S.eng.tradeLog; local n0 = #arr0
  local tip = n0 > 0 and (n0 .. ":" .. (select(2, pcall(logRec, arr0[n0])) or "?")) or "0"
  if tip == P.logTip and L.list == P.logList then return end
  P.logTip = tip; P.logList = L.list
  local mine = logList(S)
  local hs, ms = table.concat(L.list, ";"), table.concat(mine, ";")
  if ms == hs then return end
  -- after a rebuild a record can still read otherwise here (a building the host names that this copy does not have):
  -- the same host list and this copy's log unchanged since that rebuild = nothing to do (measured in a6: rebuilt
  -- every 2 s without this)
  if hs == P.logHost and ms == P.logMine then return end
  local byKey = {}
  for _, b in ipairs((function() local t = {}; local arr = S.eng.buildingArr; for i = 1, #arr do local x = un(arr[i]); if valid(x) then t[#t + 1] = x end end; return t end)()) do
    local ok, k = pcall(bkey, b); if ok then byKey[k] = b end
  end
  local arr = S.eng.tradeLog
  arr:Empty()
  for i, x in ipairs(L.list) do
    local f, t, fi, ti, g, a, pr, d, tn, imp = x:match("^([^,]+),([^,]+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),([^,]+),([01])$")
    if f then
      -- one past the end: the list grows by one empty record (lane 55: #arr + 1, not i: a host record that does not
      -- match the pattern above would otherwise leave an empty record in the middle of the game's list)
      local r = arr[#arr + 1]
      pcall(function() local b = byKey[(f:gsub("/", ","))]; if b then r.fromBuilding = b end end)
      pcall(function() local b = byKey[(t:gsub("/", ","))]; if b then r.toBuilding = b end end)
      r.fromRegionIndex = tonumber(fi); r.toRegionIndex = tonumber(ti); r.goodType = tonumber(g); r.goodAmt = tonumber(a)
      r.priceTotal = tonumber(pr); r.daysTotal = tonumber(d); r.isImport = imp == "1"
      if tn ~= "-" then pcall(function() r.traderName = FName(tn) end) end
    end
  end
  P.logHost = hs; P.logMine = table.concat(logList(S), ";")
  do local a2 = S.eng.tradeLog; local n2 = #a2; P.logTip = n2 > 0 and (n2 .. ":" .. (select(2, pcall(logRec, a2[n2])) or "?")) or "0" end
  bump("t_rebuilt")
  if (P.stats.t_rebuilt or 0) <= 5 then log("trade log rebuilt as the host's: %d records (this copy had %d)", #arr, #mine) end
end
local function onRoadLine(w)
  local n, first = tonumber(w[5]), tonumber(w[6])
  if not (n and first) then return end
  local D = P.hostD; if not D then D = {}; P.hostD = D end
  if first == 1 then D.part = {}; D.bad = false end
  if not D.part then return end
  if w[7] and w[7] ~= "-" then
    for s in w[7]:gmatch("[^;]+") do
      local key, pts = s:match("^([%d,%-]+)=(.+)$")
      local a1, a2, b1, b2 = (key or ""):match("^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
      local fx, fy = (pts or ""):match("^(%-?[%d%.]+),(%-?[%d%.]+),")
      local lx, ly = (pts or ""):match("(%-?[%d%.]+),(%-?[%d%.]+),%-?[%d%.]+$")
      if a1 and fx and lx then D.part[#D.part + 1] = { key = key, pts = pts, ax = tonumber(fx), ay = tonumber(fy), bx = tonumber(lx), by = tonumber(ly) }
      else D.bad = true end
    end
  end
  if #D.part >= n then
    if D.bad or #D.part ~= n then bump("d_badLine"); log("rival roads: a list from the host could not be read (%d of %d): not taken", #D.part, n)
    else D.list = D.part end
    D.part = nil
  end
end

-- ================================================================ plug-in
local function guarded(what, fn, ...)
  if C.traceF then C.trace("people:" .. what) end          -- (lane 47, round three: test switch dev_trace.txt only)
  local ok, e = pcall(fn, ...)
  if not ok and P.lastErr ~= what .. ": " .. tostring(e) then P.lastErr = what .. ": " .. tostring(e); log("%s", P.lastErr); bump("err") end
end

local M = {}
function M.onWorld(S) fresh(S) end
function M.tick(S, clock)
  fresh(S)
  if rawget(C, "hold") or not valid(S.p1) or not valid(S.eng) then return end
  if S.role ~= "host" and S.role ~= "friend" then return end
  local host = S.role == "host"
  if P.on.grow then
    if host then pcall(wrapTownOut); guarded("growth", hostGrow, S, clock) else guarded("growth", friendGrow, S, clock) end
  end
  if not host and clock - P.tFam >= 1.0 then
    P.tFam = clock
    if P.on.families then guarded("families", friendFamilies, S, clock) end
    if P.on.members then guarded("members", friendMembers, S, clock) end
  end
  if P.on.rival then
    if P.scan then guarded("rival", scan, S)
    elseif clock - P.tRival >= (host and RIVAL_EVERY or RIVAL_EVERY_F) then   -- (lane 42: per role)
      P.tRival = clock
      guarded("rival", scan, S, function(per)
        if host then hostRival(S, os.clock(), per) else friendRival(S, os.clock(), per) end
        if P.on.rivalRoads then if host then guarded("rival links", hostLinks, S, os.clock(), per) else guarded("rival links", friendLinks, S, per) end end   -- lane 42
      end)
    end
    -- lane 42: the rival lords' roads (host: the list every 2 s; friend: one look a second)
    if P.on.rivalRoads and clock - (P.tRoad or 0) >= (host and ROAD_EVERY or 1.0) then
      P.tRoad = clock
      if host then guarded("rival roads", hostRoads, S, clock) else guarded("rival roads", friendRoads, S, clock) end
      if P.on.tradeLog then if host then guarded("trade log", hostLog, S, clock) else guarded("trade log", friendLog, S) end end   -- lane 42
    end
    if not host then
      guarded("rival jobs", runJobs, S, clock)
      -- a friend's first seconds in a world: "send your lists now" (the host repeats them only once a minute)
      if not P.asked and clock - (S.worldT or 0) > 3.0 then P.asked = true; A.send("V LIST") end
    end
  end
end
function M.onMessage(S, from, kind, w, line)
  if kind ~= "V" then return false end
  fresh(S)
  local sub = w[4]
  if S.role == "friend" and from == "host" then
    if sub == "B" then
      local code, n, first = w[5], tonumber(w[6]), tonumber(w[7])
      if code and n and first then
        local H = P.hostB[code]; if not H then H = {}; P.hostB[code] = H end
        if first == 1 then H.part = {}; H.bad = false end
        if H.part then
          if w[8] and w[8] ~= "-" then
            for s in w[8]:gmatch("[^;]+") do
              local e = parseEntry(s)
              if e then H.part[#H.part + 1] = e else H.bad = true end
            end
          end
          if #H.part >= n then
            -- only a list in which every entry could be read is taken (lane 5: a half-read list made a copy demolish real buildings)
            if H.bad or #H.part ~= n then bump("b_badLine"); log("rival %s: a list from the host could not be read (%d of %d entries): not taken", code, #H.part, n)
            else H.list = H.part; H.t = os.clock(); P.tRival = math.min(P.tRival or 0, os.clock() - RIVAL_EVERY_F + 0.3) end   -- compare a moment from now
            H.part = nil
          end
        end
      end
    elseif sub == "G" then
      local rk, day, kind, place = w[5], tonumber(w[6]), w[7], math.tointeger(tonumber(w[8]) or 0.5)
      if place and place < 1 then place = nil end        -- (lane 55) a place in the game's family list: 1 or more, whole
      if rk and day and place and (kind == "F" or kind == "M" or kind == "X") and P.on.grow then
        local ev = { rk = rk, day = day, kind = kind, place = place, t = os.clock() }
        if kind == "M" then ev.n = tonumber(w[9]) or 0; ev.home = w[10] or "-" else ev.home = w[9] or "-" end
        P.gq = P.gq or {}; P.gq[#P.gq + 1] = ev; bump("g_got")
        -- lane 39: taken now, in the line's order (a departure or a new home does not wait; see wrapTownOut)
        if not rawget(C, "hold") and valid(S.p1) and valid(S.eng) then guarded("growth", friendGrow, S, os.clock()) end
      end
    elseif sub == "T" then                                  -- lane 42 round two: the trade log
      if P.on.tradeLog then guarded("trade log", onLogLine, w) end
    elseif sub == "K" then                                  -- lane 42 round two: the rival buildings' road links
      if P.on.rivalRoads then guarded("rival links", onLinkLine, w) end
    elseif sub == "D" then                                  -- lane 42: the rival lords' roads
      if P.on.rivalRoads then guarded("rival roads", onRoadLine, w) end
    elseif sub == "LOT" then
      if w[5] and w[6] and w[7] then P.lots[w[5] .. "|" .. w[6]] = w[7]; bump("lot_got") end
    end
  elseif S.role == "host" and from ~= "host" then
    if sub == "ASK" and w[5] and w[6] then guarded("ask", hostAsk, S, from, w[5], w[6])
    elseif sub == "LIST" then P.tKeyB = -1e9; P.tKeyD = -1e9; P.sentK = nil; P.tLinks = nil; P.tKeyT = nil end   -- (D, K, T: lane 42)           -- the next look sends every list again
  end
  return true
end

function P.status()
  local t = {}; for k, v in pairs(P.stats) do t[#t + 1] = k .. "=" .. tostring(v) end; table.sort(t)
  local on = {}; for k, v in pairs(P.on) do if v then on[#on + 1] = k end end; table.sort(on)
  local nh, nm = 0, 0
  for _, H in pairs(P.hostB or {}) do nh = nh + #(H.list or {}) end
  for _ in pairs(P.made or {}) do nm = nm + 1 end
  local gc = P.gCost or { n = 0, ms = 0 }
  return string.format("people %s: %s | on: %s | host's rival buildings %d, jobs waiting %d, families made here %d | growth look %d times, %.1f ms in all | last error %s",
    P.version, table.concat(t, " "), table.concat(on, ","), nh, #(P.jobs or {}), nm, gc.n, gc.ms, tostring(P.lastErr))
end

C.register("people", M)
return "coop_x_people " .. P.version .. " loaded"
