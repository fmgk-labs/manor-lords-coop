-- Manor Lords Co-op: things the game rolls by itself (plug-in module "events", message kind "E").
-- Each copy's own game starts quests, raids, bandit camps and unrest for itself, so two copies differ unless one
-- decides. The host decides; this module pushes what the host has and carries a friend's answer back.
--
-- Who owns what (lane 5 decisions; evidence in research/2026-11-10-game-probe/lanes/lane_s21_5/report.md):
--   quests     The host owns the lord's three lists (running, offered, opportunities).
--              host -> friends   E Q <running> <offered> <opportunities>      when they change and every 30 s
--                                each a comma list of <name>:<region tag>, "-" = empty
--                                E DID <who> A|R <name>
--                                an answer was given on the host's copy (by the host or, relayed, by <who>)
--              friend -> host    E A <name> (first answer: accept)   E R <name> (second answer: refuse)
--              An offer the host has and a friend lacks is started there with the director's own
--              Director:startQuestFromPreset; an answer is replayed through the copy's own message widgets.
--   camps      The host owns the bandit camps (buildings of type 100 owned by the bandit lord).
--              host -> friends   E K <type@x,y~z>;...   ("-" = none) when the list changes and every 30 s
--              A camp gone on the host is removed on a friend's copy through the town module's own DEMOLISH (the
--              helper lord's demolish list), never with a direct SMBuildingMaster:demolish: see campGone below.
--              A camp the friend lacks: see campMake below.
--   owners     The host owns who holds each region (a rival lord winning a claim, rebels).
--              host -> friends   E O <tag>=<P|B|A<n>|->,...   when it changes and every 30 s
--   people     The host owns who the villagers are (names). host -> friends  E P ...  (see "people" below)
--   thefts     (lane 66) The host owns the bandits' theft. host -> friends  E T <serial> <camp> <good> <amount> <victim> <region>
--              when a camp's loot grows on the host's theft day; a friend's copy never rolls one (native NOTHEFT) and
--              gets the game's own notice "theft" like every notice, by the realm module's R LOG. See "thefts".
-- Re-loadable (state lives in Coop.events).

local C = rawget(_G, "Coop")
if type(C) ~= "table" or type(C.register) ~= "function" or type(C.api) ~= "table" then return "coop_x_events: load coop.lua first" end
local A = C.api
local un, valid = A.un, A.valid
local E = C.events or {}
C.events = E
E.version = "0.27"
E.on = E.on or {}
local DEFAULT_ON = {
  quests = true,       -- the host's quest lists are pushed and compared
  questStart = true,   -- a quest the host has is started on a friend's copy (Director:startQuestFromPreset)
  answers = true,      -- answers travel friend -> host -> every copy
  extraClose = true,   -- (lane 66) an offer this copy has more often than the host: the extra messages are closed unanswered
  popups = true,       -- (lane 66) the host's event windows (Cold!, Hunger!, royal tax) are opened on a friend (E POP)
  camps = true,        -- the host's bandit camps are pushed and compared
  campRemove = true,   -- a camp gone on the host is removed here: the town module's DEMOLISH through the helper lord (lane 12)
  campMake = true,     -- a camp the friend lacks is made here: the engine's own spawnBanditCamp, then moved to the host's place (5 of 5 in sessions 4 to 7)
  campRepair = true,   -- ... and when making or removing fails (or removing is switched off) the friend asks for a resync
  campLeftover = true, -- (lane 90) E.campAt found no camp after the game's spawn: the one squad that spawn made is asked away at once
  owners = true,       -- the host's region owners are pushed and compared
  ownerSet = true,     -- a region whose owner differs is given to the host's owner here (PawnCPP:finalizeClaim)
  people = true,       -- the host's villagers (name, role, age per family) are pushed and compared
  names = true,        -- a villager whose name differs takes the host's name (SMUnit.DisplayName)
  rivalPeople = true,  -- lane 64: the other lords' towns are in the people line too (a friend takes names only there)
  homes = true,        -- a family lives where it lives on the host (Region:SetFamilyHome)
  deaths = true,       -- a family member the host's family no longer has dies here too (SMUnit:just_die)
  vdeaths = true,      -- a villager who dies on the host is named at once (E PD) and dies here too (lane 24)
  notices = true,      -- lane 64: ... with the cause, and the friend's player gets the game's own death notice (PawnCPP:addLog)
  corpses = true,      -- lane 64: the host's bodies per region are pushed and compared (E PC, E PZ)
  corpseRemove = true, -- lane 64: a body here that the host has not is taken out (RTSMultiEngineCPP:destroyUnit)
  corpseElsewhere = true, -- (lane 64, task 64d) ... but not one the host has unpaired in another region (the same person lying elsewhere)
  census = true,       -- lane 64: a friend counts its units nobody knows once a minute (logged when the count changes)
  thefts = true,       -- (lane 66) the host's bandit thefts are told (E T); a friend watches its camps' loot for a theft of its own
  animalGone = true,   -- (lane 64, task 64d) an animal of a town gone from the host without a body is told (E AG) and taken out here
}
for k, v in pairs(DEFAULT_ON) do if E.on[k] == nil then E.on[k] = v end end
E.stats = E.stats or {}
E.S = nil                                              -- a hot reload: state is set up again, everything is told and judged again
local LISTS = { "quests", "proposedQuests", "questOpportunities" }
local POLL, KEY, CAMP_EVERY, OWNER_EVERY, PEOPLE_EVERY, CAMP_TYPE = 1.0, 30.0, 3.0, 2.0, 5.0, 100
local OFFER_WAIT = 3.0       -- (lane 66) an offer the host has and this copy lacks is started after this many seconds
-- (lane 88) ... but only an offer this copy's own game can make by itself (it would come here a moment later and the
-- player would get two). Every other offer is started at once: lead runs r27m83 and r27cf, day 365, the host's
-- "raiders_near" (made by the host's raid countdown; a friend's countdown is held one day behind the host's) came
-- 4.3 s after the host's (the wait plus two 1 s looks): a list the host did not have for more than 3 s. Known own
-- offers: "spoils_of_war" (soldiers that loot a bandit camp: SMUnit::proximityAction on every copy). An offer this
-- copy is seen making by itself (more often here than on the host) is added for the rest of the session (E.ownMade).
local OWN_OFFERS = { spoils_of_war = true }
local POLL_HOST = 0.25       -- (lane 88) the host looks at its quest lists this often (a look reads three short lists)

local function log(fmt, ...) A.log("events: " .. fmt, ...) end
local function bump(k, d) E.stats[k] = (E.stats[k] or 0) + (d or 1) end
local function enc(s) return (tostring(s):gsub("[^%w]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function dec(s) return (tostring(s):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); if ok then return a end end
local function rkey(r)
  local ok, k = pcall(function() return r.regionUniqueTag:ToString() end)
  if not ok or type(k) ~= "string" or k == "" or k == "None" then return nil end
  return (k:gsub("[^%w_%.]", "_"))
end
local function regionByKey(S, k)
  local arr = S.eng.regions
  for i = 1, #arr do local r = un(arr[i]); if valid(r) and rkey(r) == k then return r end end
end
-- a lord by facts that are the same on every copy (the world module's rule)
local function ownerCode(S, o)
  if not valid(o) then return "-" end
  if addr(o) == addr(S.p1) then return "P" end
  local okB, bandit = pcall(function() return o.isBandit end); if okB and bandit then return "B" end
  local okI, idx = pcall(function() return o:getPawnSetupIndex() end); if okI and type(idx) == "number" then return "A" .. idx end
  return "X"
end
local function pawnByCode(S, code)
  if code == "P" then return S.p1 end
  if code == "B" then for _, pw in ipairs(A.pawns()) do if valid(pw) and pw.isBandit then return pw end end; return nil end
  local i = tonumber((code or ""):match("^A(%-?%d+)$")); if not i then return nil end
  local ok, pw = pcall(function() return S.eng:getPawnBySetupIndex(i) end)
  if ok and valid(pw) then return pw end
end

-- ---------------------------------------------------------------- quests
local function qname(q) local ok, n = pcall(function() return q.Name:ToString() end); return (ok and type(n) == "string" and n ~= "") and n or nil end
local function qregion(q)
  -- NEVER read a game list past its end: in this scripting layer that read GROWS the list by an empty entry (measured
  -- 2026-11-12: length 0, after reading [1] length 1). The game's offer "raiders_near" has no region; this line used
  -- to give it an empty one, and the game's next save died on it (coop.lua, crash guard 2).
  local ok, k = pcall(function() local rs = q.regions; if #rs < 1 then return nil end; local r = un(rs[1]); if valid(r) then return rkey(r) end end)
  return ok and k or nil
end

-- the lord's lists as { list = { { n = name, r = region tag }, ... } } (sorted by name) and as one line
-- (lane 83) the day a quest was issued (Quest.issuedOnDay: with adjustDaysLeftToIssuedDay its countdown counts from it)
local function qissued(q) local ok, d = pcall(function() return q.issuedOnDay end); return (ok and type(d) == "number") and math.floor(d) or nil end
local function readQuests(S)
  local t, parts, days = {}, {}, {}
  for _, l in ipairs(LISTS) do
    local a = S.p1[l]; local items = {}
    for i = 1, #a do local n = qname(a[i]); if n then items[#items + 1] = { n = n, r = qregion(a[i]), d = qissued(a[i]) } end end
    table.sort(items, function(x, y) if x.n ~= y.n then return x.n < y.n end; return (x.d or -1) < (y.d or -1) end); t[l] = items
    local e, dd = {}, {}; for i, it in ipairs(items) do e[i] = enc(it.n) .. ":" .. (it.r or ""); dd[i] = it.d and tostring(it.d) or "-" end
    parts[#parts + 1] = #e > 0 and table.concat(e, ",") or "-"
    days[#days + 1] = #dd > 0 and table.concat(dd, ",") or "-"
  end
  -- (lane 83) the issued days go as a fourth word, in the items' order, lists apart by "|" (an older friend reads three)
  return t, table.concat(parts, " ") .. " " .. table.concat(days, "|")
end
-- (lane 83) friend: a quest the host has with the same name gets the host's issued day (run 22: the friend started the
-- host's "raiders_near" a moment before its own day change, so its warning counted from day 364, the host's from 365;
-- equal only after a load). Same names are paired in the order of their days on each copy.
local function friendIssued(S, H)
  local n = 0
  for _, l in ipairs(LISTS) do
    local want = {}
    for _, it in ipairs(H[l] or {}) do if it.d then want[it.n] = want[it.n] or {}; want[it.n][#want[it.n] + 1] = it.d end end
    if next(want) then
      local a = S.p1[l]; local mine = {}
      for i = 1, #a do local q = a[i]; local nm = qname(q); if nm and want[nm] then mine[nm] = mine[nm] or {}; mine[nm][#mine[nm] + 1] = q end end
      for nm, qs in pairs(mine) do
        local hd = want[nm]; table.sort(qs, function(x, y) return (qissued(x) or -1) < (qissued(y) or -1) end)
        if #qs == #hd then
          for k, q in ipairs(qs) do
            local d = qissued(q)
            if d and d ~= hd[k] then
              local ok = pcall(function() q.issuedOnDay = hd[k] end)
              if ok and qissued(q) == hd[k] then n = n + 1; log("quest %s (%s): issued day %d -> the host's %d", nm, l, d, hd[k]); bump("q_issued") else bump("q_issuedFail") end
            end
          end
        end
      end
    end
  end
  return n
end

local function findQuest(S, list, name)
  local a = S.p1[list]
  for i = 1, #a do if qname(a[i]) == name then return a[i], i end end
end

local function fresh(S)
  if E.S == S and E.world == S.worlds then return end
  E.S = S; E.world = S.worlds
  E.sentQ = nil; E.tKey = -1e9; E.tPoll = 0; E.hostQ = nil; E.hostQline = nil; E.quiet = 0; E.lastDiff = nil; E.tried = {}; E.rows = nil
  E.offerSince = {}; E.extraSince = {}; E.extraDone = {}; E.extraShut = {}; E.extraBase = nil
  E.sentK = nil; E.tKeyK = -1e9; E.tCamp = 0; E.scan = nil; E.hostK = nil; E.campSince = {}; E.campAsked = {}
  E.campGone = {}; E.hostKline = nil; E.listSig = nil; E.tQuick = 0
  E.sentO = nil; E.tKeyO = -1e9; E.tOwner = 0; E.hostO = nil; E.ownSince = {}; E.ownTried = {}
  E.pscan = nil; E.sentP = {}; E.tKeyP = -1e9; E.tPeople = 0; E.hostP = {}; E.lastKind = nil; E.peopleNow = nil
  E.homeT = {}; E.deadSig = {}; E.deadT = {}; E.famSeen = {}
  E.hh = {}; E.hhDirty = {}; E.homeM = {}; E.homeTry = {};E.homeBusyT = {}; E.homeSaid = {}; E.tHomes = 0   -- lane 64: where a family lives
  E.vill = nil; E.tVill = 0; E.pdQ = {}; E.pdMiss = {}; E.keptSaid = {}
  E.vSeen = {}; E.sentC = {}; E.tKeyC = -1e9; E.tCorpse = 0; E.tCorpseF = 0; E.hostC = {}; E.cState = {}; E.askedCorpses = false; E.tCensus = os.clock(); E.censusSig = nil; E.censusOdd = nil   -- lane 64: corpses, census
  E.vill = nil; E.tVill = 0; E.pdQ = {}
  E.animalBodies = {}; E.lastAnimalDeath = 0
  E.animalLive = {}; E.lastAnimalGone = 0; E.animalTot = {}; E.animalScanT = {}            -- (task 64d) animals gone without a body
  E.campMap = nil; E.loot = {}; E.tTheft = 0; E.theftN = 0; E.theftSeen = {}; E.theftWant = {}; E.theftDay = nil; E.ownGrow = {}
  log("reset for world %d", S.worlds)
end

local function hostQuests(S, clock)
  local _, line = readQuests(S)
  if line ~= E.sentQ or clock - E.tKey >= KEY then
    if line ~= E.sentQ then log("quests on the host: %s", line); bump("q_sent") end
    E.sentQ = line; E.tKey = clock
    A.send("E Q " .. line)
  end
end

local function index(items) local s = {}; for _, it in ipairs(items) do s[it.n] = it end; return s end
-- (lane 88) can this copy's own game offer this quest by itself? (then the host's is started only after OFFER_WAIT)
function E.ownOffer(name) return OWN_OFFERS[name] == true or (E.ownMade ~= nil and E.ownMade[name] == true) end

-- the presets the director can start (row names of its quest table). (lane 81) A quest's own name is not always its
-- row's name: the row "weapons_delivery_complete" makes the quest "weapons_delivery" (live u4d: the host's offer
-- of it never reached the friend: no row of that name). Of the table's 47 rows, 3 more do so (victory_conquest_OLD,
-- techQuest_21_1, restoring_the_peace_storyonly). The table is the game's own data, the same on every copy, so each
-- copy reads it once: the row of a quest name is the row of that name, else the ONE row whose quest has that name.
-- A name made by more than one row of other names (live: "No_Title" by three message rows) is not guessed: not
-- started, as before (logged once). presetOf(S, name) returns the row to start, or nil.
local function readRows(S)
  E.rows = {}; E.rowOf = {}
  local byQ = {}
  pcall(function()
    S.eng.questDirector.DT_Quests:ForEachRow(function(rowName, row)
      local rn = type(rowName) == "string" and rowName or nil; if not rn then pcall(function() rn = rowName:ToString() end) end   -- (live: the row name comes as a Lua string)
      if rn and rn ~= "" then
        E.rows[rn] = true
        local qn; pcall(function() qn = row.Name:ToString() end)
        if qn and qn ~= "" and qn ~= rn then byQ[qn] = byQ[qn] or {}; local t = byQ[qn]; t[#t + 1] = rn end
      end
    end)
  end)
  if next(E.rows) == nil then                   -- the older way (row names only), should the table walk not work
    pcall(function()
      local names = {}
      StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary"):GetDataTableRowNames(S.eng.questDirector.DT_Quests, names)
      for i = 1, #names do local n = names[i]; local s; pcall(function() s = n:get():ToString() end); if not s then pcall(function() s = n:ToString() end) end; if s then E.rows[s] = true end end
    end)
  end
  local amb = {}
  for qn, t in pairs(byQ) do
    if #t == 1 or E.rows[qn] then E.rowOf[qn] = t[1] else table.sort(t); amb[#amb + 1] = qn .. " (" .. table.concat(t, ",") .. ")" end
  end
  local nm = 0; for _ in pairs(E.rowOf) do nm = nm + 1 end
  table.sort(amb)
  log("quest table: %d rows, %d quest names made by one row of another name; not started (made by several): %s", (function() local n = 0; for _ in pairs(E.rows) do n = n + 1 end; return n end)(), nm, #amb > 0 and table.concat(amb, "; ") or "none")
end
local function presetOf(S, name)
  if not E.rows then readRows(S) end
  if E.rows[name] then return name end
  return E.rowOf and E.rowOf[name] or nil
end
E.presetOf = presetOf

-- friend: start here what the host has (the director's own function), and say what still differs
-- (lane 66) is a quest message (questMessageElaborate_C) on screen? One the mod closed (taken out of its grid) keeps its
-- own visibility and is still found by FindAllOf: measured lane 66 run 1, the host's answer was replayed on such a
-- closed message and the open one stayed. Only a message with a living parent is on screen.
local function onScreen(w)
  local ok, r = pcall(function() local p = w:GetParent(); return p ~= nil and p:IsValid() end)
  return ok and r == true
end
local function friendQuests(S, clock)
  local H = E.hostQ; if not H then return end
  if clock < (E.quiet or 0) then return end            -- an answer was just given here: the host's word is on its way
  -- the same quest can be on offer more than once (a second looted camp: two "spoils_of_war"), and an answered
  -- offer stays in the list, so the lists are compared by how often each name is in them
  local function counts(items) local c = {}; for _, it in ipairs(items) do c[it.n] = (c[it.n] or 0) + 1 end; return c end
  local mine = readQuests(S)
  local any = {}
  for _, l in ipairs(LISTS) do for _, it in ipairs(mine[l]) do any[it.n] = true end end
  if E.on.questStart then
    for li, l in ipairs(LISTS) do
      if li <= 2 then
        local offer = l == "proposedQuests"
        local cH, cM = counts(H[l]), counts(mine[l]); local done = {}
        for _, it in ipairs(H[l]) do
          local key = l .. "|" .. it.n
          local tried = E.tried[key] or 0
          -- an offer: as many as the host has. A running quest: once per world, and only if this copy has it nowhere
          -- (a quest this copy already finished is not started again)
          -- (lane 66 run 2) an extra entry this copy closed still counts in its list: it is not one of the host's offers
          local mineN = (cM[it.n] or 0) - (offer and (E.extraShut[it.n] or 0) or 0)
          local want = offer and (mineN < cH[it.n] and tried < cH[it.n]) or (not offer and not any[it.n] and tried == 0)
          -- (lane 66) an offer is started here only after it has been missing for OFFER_WAIT s. The game offers some by
          -- itself on every copy where the same thing happens: soldiers that loot a bandit camp (SMUnit::proximityAction
          -- 4dcd8c5: collapseBuilding, then Director startQuestFromPreset "spoils_of_war" for the soldiers' lord). The
          -- host's word comes about as fast as this copy's own offer (live, 2026-11-17: the mod's start 0.1 s before the
          -- camp went here, this copy's own offer a second later: two offers, two messages).
          if want and offer and E.ownOffer(it.n) then
            local sk = l .. "|" .. it.n .. "|" .. (mineN + 1)
            E.offerSince[sk] = E.offerSince[sk] or clock
            if clock - E.offerSince[sk] < OFFER_WAIT then want = false; E.tPoll = clock - POLL + 0.5 end
          end
          local preset = want and not done[it.n] and presetOf(S, it.n)
          if preset then
            done[it.n] = true; E.tried[key] = tried + 1    -- one per second
            local D = S.eng.questDirector
            -- (lane 83) the host's region, or NONE when the host's record has none: the game's own "raiders_near" has
            -- an empty region list, and this line used to give the friend's copy the lord's closest region (run 22,
            -- day 365: host 0 regions, friend 1). The closest region stays only for a region the host named that this
            -- copy cannot find.
            local reg = nil
            if it.r then reg = regionByKey(S, it.r) or S.p1:getClosestOwnedRegion() end
            local ok, r = pcall(function() return D:startQuestFromPreset(FName(preset), S.p1, {}, reg, offer, -1) end)
            S.modQuestT = os.clock()                             -- the speed watcher (coop.lua): the game answers a new quest message with one speed step down; that is not the player's
            log("quest %s (%s on the host): started here%s%s", it.n, offer and "offered" or "running", preset ~= it.n and (" from the row " .. preset) or "", (ok and r) and "" or (" FAILED " .. tostring(r))); bump("q_started")
          end
        end
      end
    end
  end
  local diff = {}
  mine = readQuests(S)
  for _, l in ipairs(LISTS) do
    local a, b = counts(H[l]), counts(mine[l])
    for n, k in pairs(a) do if (b[n] or 0) < k then diff[#diff + 1] = l .. "+" .. n end end
    for n, k in pairs(b) do if (a[n] or 0) < k then diff[#diff + 1] = l .. "-" .. n end end
  end
  table.sort(diff); local d = table.concat(diff, " ")
  if d ~= E.lastDiff then E.lastDiff = d; if d == "" then log("quests equal to the host's") else log("quests differ from the host's: %s", d); bump("q_diff") end end
  do local okI, eI = pcall(friendIssued, S, H); if not okI then bump("q_issuedErr"); if E.issuedErr ~= tostring(eI) then E.issuedErr = tostring(eI); log("issued days: %s", tostring(eI)) end end end   -- (lane 83)
  -- (lane 66) an offer this copy has more often than the host: its game made one of its own. The extra entry cannot be
  -- taken out of the lord's list by name (the game's removal and answer calls take the quest record by reference, which
  -- a script cannot hand over), and an answered offer stays in the list on every copy anyway; what the player sees and
  -- can answer is the message. So the extra open messages are closed, unanswered (questMessageElaborate_C, taken off
  -- the screen), once the surplus has stood for 2 s: as many as this copy has more than the host, never more.
  if E.on.extraClose then
    local cH, cM = {}, {}
    for _, it in ipairs(H.proposedQuests) do cH[it.n] = (cH[it.n] or 0) + 1 end
    for _, it in ipairs(mine.proposedQuests) do cM[it.n] = (cM[it.n] or 0) + 1 end
    if not E.extraBase then                            -- the first comparison in this world (or after a hot reload): what
      E.extraBase = true                               -- differs already is not new and is never closed
      for n, k in pairs(cM) do local x = k - (cH[n] or 0); if x > 0 then E.extraShut[n] = x end end
    end
    for n, k in pairs(cM) do
      local extra = k - (cH[n] or 0) - (E.extraShut[n] or 0)   -- (lane 66 run 1) an extra entry stays in the list after its message was closed: counted once
      local ek = n .. "|" .. k
      if extra > 0 and not E.ownOffer(n) then                  -- (lane 88) this copy's game makes this offer by itself: wait for it from now on
        E.ownMade = E.ownMade or {}; E.ownMade[n] = true; bump("q_ownLearned")
        log("quest %s: this copy's own game offered it (%d here, %d on the host): the host's next one of it is started only after %.1f s", n, k, cH[n] or 0, OFFER_WAIT)
      end
      if extra > 0 then
        E.extraSince[ek] = E.extraSince[ek] or clock
        if clock - E.extraSince[ek] >= 2.0 and not E.extraDone[ek] then
          E.extraDone[ek] = true
          local open = {}
          for _, w in ipairs(FindAllOf("questMessageElaborate_C") or {}) do
            local okN, wn = pcall(function() return w.Quest.Name:ToString() end)
            if valid(w) and okN and wn == n then
              local pressed = false; pcall(function() pressed = w.Pressed and true or false end)
              if not pressed and onScreen(w) then open[#open + 1] = w end
            end
          end
          local shut = 0
          for i = #open, math.max(1, #open - extra + 1), -1 do
            local ok = pcall(function() open[i]:RemoveFromParent() end)
            if ok then shut = shut + 1 end
          end
          E.extraShut[n] = (E.extraShut[n] or 0) + extra      -- this surplus is dealt with (its message closed, or none was open)
          log("quest %s: offered %d time(s) here, %d on the host: %d extra message(s) of this copy's own closed unanswered (%d open before)", n, k, cH[n] or 0, shut, #open)
          bump(shut > 0 and "q_extraClosed" or "q_extraNone")
        end
      end
    end
  end
end

-- ---- answers. The game's own calls on a copy's lord are seen by hooks; E.seen runs for each (on every copy).
--
-- What a click on a quest message does (lane 5 session 2, call trace on both copies): the first answer button calls
-- PawnCPP:acceptQuest(quest), the second PawnCPP:refuseQuest(quest), each with the message's own quest record; the
-- "choices" of a quest are only the two button texts. The offer stays in the list of offers afterwards.
-- Both calls take the quest record by reference, which a script cannot hand over (it arrives empty), and
-- PawnCPP:setChoice is not an answer: it adds a choice text to every quest with that number (seen: all three running
-- quests got it). So an answer is replayed the way the player gives it: through the copy's own message widgets. The
-- scroll under the top bar (questMessageElaborate_C) is opened with its own click handler, and the answer button of
-- the message (MessageFullscreen_C) is pressed with its own handler. The message shows for a moment on that copy.
local SCROLL = "BndEvt__scrollButton_K2Node_ComponentBoundEvent_0_OnButtonReleasedEvent__DelegateSignature"
local BUTTON = { A = "BndEvt__Button_ChoiceA_K2Node_ComponentBoundEvent_1_OnButtonReleasedEvent__DelegateSignature",
                 R = "BndEvt__Button_ChoiceB_K2Node_ComponentBoundEvent_0_OnButtonReleasedEvent__DelegateSignature" }
local VERB = { A = "accept", R = "refuse" }
local function wquest(w) local ok, n = pcall(function() return w.Quest.Name:ToString() end); return ok and n or nil end
local function wshown(w) local ok, v = pcall(function() return w:IsVisible() end); return ok and v == true end

-- press the answer on an open message for this quest; true when one was found
local function pressAnswer(name, verb)
  for _, w in ipairs(FindAllOf("MessageFullscreen_C") or {}) do
    if valid(w) and wshown(w) and wquest(w) == name then
      E.replayT = os.clock() + 1.5; E.replayQ = { n = name, v = verb }
      w[BUTTON[verb]](w)
      return true
    end
  end
  return false
end

-- give the answer on this copy; done(ok, how) is called when it is known (the message needs a moment to open)
local function doAnswer(S, verb, name, done)
  if not BUTTON[verb] then done(false, "unknown answer"); return end
  local ok, hit = pcall(pressAnswer, name, verb)
  if ok and hit then done(true, "message was open"); return end
  local scroll
  for _, w in ipairs(FindAllOf("questMessageElaborate_C") or {}) do
    if valid(w) and wquest(w) == name then
      local pressed = false; pcall(function() pressed = w.Pressed and true or false end)
      if not pressed and onScreen(w) then scroll = w end   -- (lane 66) a message the mod closed is no longer on screen: never that one
    end
  end
  if not scroll then done(false, "no message for this quest on this copy"); return end
  E.replayT = os.clock() + 3.0; E.replayQ = { n = name, v = verb }
  local okS, eS = pcall(function() scroll[SCROLL](scroll) end)
  if not okS then done(false, "the scroll could not be opened: " .. tostring(eS)); return end
  local tries = 0
  local function try()
    tries = tries + 1
    local okP, hitP = pcall(pressAnswer, name, verb)
    if okP and hitP then done(true, "through the scroll")
    elseif tries < 8 then A.later(0.25, try)
    else done(false, "the message did not open") end
  end
  A.later(0.25, try)
end

function E.seen(fn, self, a1)
  local S = C.s
  if fn ~= "acceptQuest" and fn ~= "refuseQuest" then return end
  if not (S and S.on and E.on.answers) or rawget(C, "hold") then return end
  local okL, isLord = pcall(function() return self:get():GetAddress() == S.p1:GetAddress() end)
  if not (okL and isLord) then return end
  local verb = fn == "acceptQuest" and "A" or "R"
  local a = qname(a1:get()); if not a then return end
  -- (lane 81) the answer the mod is replaying here is told by WHAT it is (that quest, that answer), not by time alone:
  -- before, every answer of this player to ANY quest in the 1.5 to 3 s after a replayed answer was dropped
  local Q = E.replayQ
  if Q and os.clock() < (E.replayT or 0) and Q.n == a and Q.v == verb then bump("q_replayEcho"); return end
  bump("q_seen")
  if S.role == "friend" then
    A.send(string.format("E %s %s", verb, enc(a))); E.quiet = os.clock() + 3.0
    log("this player's answer (%s %s): sent to the host", VERB[verb], a)
  elseif S.role == "host" then
    A.send(string.format("E DID host %s %s", verb, enc(a))); E.sentQ = nil
    log("the host's answer (%s %s): told to the friends", VERB[verb], a)
  end
end

local function ensureHooks()
  local G = rawget(_G, "__coop_events_hooks2"); if not G then G = {}; _G.__coop_events_hooks2 = G end
  if G.done or (G.t and os.clock() - G.t < 2.0) then return end
  G.t = os.clock(); local all = true
  for _, fn in ipairs({ "acceptQuest", "refuseQuest" }) do
    if not G[fn] then
      local ok, e = pcall(RegisterHook, "/Script/ManorLords.PawnCPP:" .. fn, function(self, a1, a2)
        local Ev = rawget(_G, "Coop") and _G.Coop.events
        if Ev and Ev.seen then local okH, eH = pcall(Ev.seen, fn, self, a1, a2); if not okH then Ev.lastErr = fn .. ": " .. tostring(eH) end end
      end)
      if ok then G[fn] = true else all = false; G.err = tostring(e) end
    end
  end
  -- (lane 66) the game's event window ("Cold!", "Hunger!", the royal tax increase): the blueprint's own
  -- playPopupMessageGUI runs for every one the game opens on this copy (its native stub 4ac7a90 calls it); E.popup sees it
  if not G.popup then
    local ok, e = pcall(RegisterHook, "/Game/CPP_BP/MyPawnCPP_BP3.MyPawnCPP_BP3_C:playPopupMessageGUI", function(self, a1, a2)
      local Ev = rawget(_G, "Coop") and _G.Coop.events
      if Ev and Ev.popup then local okH, eH = pcall(Ev.popup, self, a1, a2); if not okH then Ev.lastErr = "popup: " .. tostring(eH) end end
    end)
    if ok then G.popup = true else all = false; G.err = tostring(e) end
  end
  if all then G.done = true; log("answer and event window hooks registered") elseif not G.said then G.said = true; log("answer hooks not registered yet: %s", tostring(G.err)) end
end

-- (lane 66) the game's event windows. Each copy's game opens them by itself: the cold and hunger ones from its own daily
-- routine (4d8f6d4: playPopupMessageIfNotPlayedRecently, once in 180 days per kind and region, from what that copy
-- computes for fuel and food), the royal tax one from recalculateRoyalTaxes. Live (lane 66 run 4): "Cold!" on a friend
-- only. The rule is the notices' one: a window opens on a friend only when it opens on the host. The friend's own are
-- held by the native piece (NOLOG holds the window's native stub too); the host tells each one it opens (E POP) and a
-- friend opens it through the blueprint's own function (the script call does not pass the stub).
function E.popup(self, a1, a2)
  local S = C.s
  if not (S and S.on and S.role == "host" and E.on.popups) then return end
  local okL, isLord = pcall(function() return self:get():GetAddress() == S.p1:GetAddress() end)
  if not (okL and isLord) then return end
  local okT, kind = pcall(function() return a1:get():ToString() end)
  if not okT or type(kind) ~= "string" or kind == "" then return end
  local tag = "-"; pcall(function() local r = a2:get(); if valid(r) then tag = rkey(r) or "-" end end)
  A.send(string.format("E POP %s %s", enc(kind), tag)); bump("pop_sent")
  log("event window %s (region %s) opened on the host: told", kind, tag)
end
local function friendPopup(S, w)
  local kind, tag = dec(w[5] or ""), w[6]
  if kind == "" then return end
  local P = rawget(C, "patch")
  if not (P and P.nlOn == true) then              -- the native hold is not on: this copy's game opens its own, as before
    bump("pop_ownGame"); log("event window %s of the host: not opened here (NOLOG is not on: this copy's game opens its own)", kind); return
  end
  local reg = (tag and tag ~= "-") and regionByKey(S, tag) or nil
  local ok, e = pcall(function() S.p1:playPopupMessageGUI(FName(kind), reg) end)
  bump(ok and "pop_shown" or "pop_failed")
  log("event window %s (region %s) of the host: %s", kind, tostring(tag), ok and "opened here" or ("NOT opened: " .. tostring(e)))
end

-- host: a friend's answer. Run it here, then tell every copy (the sender skips it: it already ran there).
local function hostAnswer(S, from, w)
  local verb = w[4]; if not VERB[verb] then return end
  local a = dec(w[5] or "")
  doAnswer(S, verb, a, function(ok, how)
    log("%s's answer (%s %s): %s here (%s)", tostring(from), VERB[verb], a, ok and "given" or "NOT given", tostring(how))
    bump(ok and "q_answers" or "q_refused")
    if ok then A.send(string.format("E DID %s %s %s", tostring(from), verb, enc(a)))
    -- (lane 66) not given here: another player's answer to the same offer came first (both inside the link's second),
    -- or the offer was this copy's own duplicate. The host's first answer stands; the sender is told.
    else A.send(string.format("E NOTGIVEN %s %s %s", tostring(from), verb, enc(a))) end
    E.sentQ = nil                                      -- and the lists as they are now
  end)
end

local function friendDid(S, w)
  local who, verb = w[5], w[6]; if who == S.name or not VERB[verb] then return end
  local a = dec(w[7] or "")
  doAnswer(S, verb, a, function(ok, how)
    log("answer given on the host by %s (%s %s): %s here (%s)", tostring(who), VERB[verb], a, ok and "given" or "NOT given", tostring(how))
    bump(ok and "q_did" or "q_didFailed")
  end)
end

-- ---------------------------------------------------------------- bandit camps
-- the same name as the world module's: type plus position rounded to 10 cm
local function bkey(b)
  local l = b:K2_GetActorLocation()
  return string.format("%d@%d,%d", A.btype(b), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5)), l.Z
end

-- this copy's camps as { key = { b = building, z = height } }, read a few buildings per tick; done(map) when complete
local function campScan(S, done)
  local st = E.scan
  local arr = S.eng.buildingArr; local n = 0
  if not st then st = { i = 0, map = {}, done = done, n0 = #arr }; E.scan = st end
  while st.i < #arr and n < 30 do
    st.i = st.i + 1; n = n + 1
    local b = un(arr[st.i])
    if valid(b) then
      pcall(function()
        if b:GetType() == CAMP_TYPE and ownerCode(S, b.ownerPawn) == "B" then local k, z = bkey(b); st.map[k] = { b = b, z = z } end
      end)
    end
  end
  if st.i >= #arr then
    -- The list is read over several ticks. When a building left it meanwhile, every later one moved up a place and
    -- one was not looked at: a camp could be missing from this reading (and a friend would take the host's word
    -- for it). So a reading during which the length changed is not used; the list is read again (three times at most).
    if #arr ~= st.n0 and (st.again or 0) < 3 then st.i = 0; st.map = {}; st.n0 = #arr; st.again = (st.again or 0) + 1; return end
    E.scan = nil; st.done(st.map)
  end
end

local function hostCamps(S, clock, map)
  local t = {}
  for k, c in pairs(map) do t[#t + 1] = string.format("%s~%d", k, math.floor(c.z + 0.5)) end
  table.sort(t); local line = #t > 0 and table.concat(t, ";") or "-"     -- ";" between camps: a camp's name holds a comma
  if line ~= E.sentK or clock - E.tKeyK >= KEY then
    if line ~= E.sentK then log("bandit camps on the host: %s", line); bump("k_sent") end
    E.sentK = line; E.tKeyK = clock
    A.send("E K " .. line)
  end
end

-- experiment (item campMake): the game's own spawnBanditCamp puts a camp at a place it rolls; the new camp is then
-- moved to the host's place. Returns true when a camp stands there afterwards.
local function campMake(S, key, z, have)
  local t, x, y = key:match("^(%d+)@(%-?%d+),(%-?%d+)$"); if not t then return false end
  local before = {}; for _, c in pairs(have) do before[addr(c.b)] = true end
  -- (lane 48, round 3) the squad the game makes with the camp is not the host's (that one came by the core's N line):
  -- asked away at once, so it does not stand where the game rolled the camp (k1: 4.3-4.6 s, 0.6-1.4 km off)
  local bl, sqBefore = nil, {}
  pcall(function() for _, pw in ipairs(FindAllOf("PawnCPP") or {}) do local ok, b = pcall(function() return pw.isBandit end); if ok and b then bl = pw end end end)
  pcall(function() local a = bl.commandedSquads; for i = 1, #a do sqBefore[a[i].Value] = true end end)
  S.eng:spawnBanditCamp()
  pcall(function()
    local a = bl.commandedSquads
    for i = 1, #a do
      local v = a[i].Value
      if v ~= 0 and not sqBefore[v] and not (S.l2h and S.l2h[v]) then
        S.madeHere = S.madeHere or {}; S.madeHere[v] = true
        S.sc:RequestRemoveSquad({ Value = v }); log("campMake: the camp's own squad %d asked away at once (the host's squad came by its announcement)", v)
      end
    end
  end)
  local arr = S.eng.buildingArr; local new
  for i = #arr, 1, -1 do
    local b = un(arr[i])
    if valid(b) and not before[addr(b)] and b:GetType() == CAMP_TYPE and ownerCode(S, b.ownerPawn) == "B" then new = b; break end
  end
  if not new then return false, "the game made no camp" end
  new:K2_SetActorLocation({ X = tonumber(x) * 10.0, Y = tonumber(y) * 10.0, Z = (z or 0) + 0.0 }, false, {}, true)
  local k2 = bkey(new)
  return k2 == key, "camp made at " .. k2
end

-- (lane 48, round 3) a camp and ITS squad, made the moment the host announces the camp's brigands (the core's N line
-- for an encamped bandit squad carries the camp's place). spawnBanditCamp makes a camp and a squad of brigands at a
-- place it rolls; campMake above moved only the building, so the squad stood 0.6-1.4 km away until the core took it
-- away 4.4 s later (lane 48 m2, t7: a squad the host never had), beside the squad the N line had made for the host's.
-- Here the building goes to the host's camp place and the game's own squad becomes the host's squad: its men are put
-- at the host's squad's place in the same frame and sent there (the caller ties it to the host's number). Returns the
-- squad's handle, or nil and why.
-- (lane 90) THE TRY'S LEFT-OVER SQUAD. l83r7c, day 361: spawnBanditCamp made its squad of brigands (a new squad of
-- the bandit lord) but no new camp was in the building list in that frame ("the game made no camp"). The core then
-- made the host's squad itself, and the game's squad of the try stood beside it, holding a camp at the place the
-- game rolled: the next full list found it "exists here but not on the host", the 4 s rule took 4.2 s, and the
-- bandits read 72 (once 90) here against the host's 54. That squad is asked away at once, as campMake does with the
-- camp's own squad (lane 48, round 3): this copy made it in this frame, nothing of it is in the air. The camp it holds
-- is then taken away by the camp rule (its squad first, the camp after: lane 12). Only when the list was read before
-- and after the try and exactly one squad is new; never a squad tied to a host number. -> text for the caller's log
local function campLeftover(S, owner, before)
  local okA, fresh = pcall(function()
    local t, a = {}, owner.commandedSquads
    for i = 1, #a do local v = a[i].Value; if v and v ~= 0 and not before[v] and not (S.l2h and S.l2h[v]) then t[#t + 1] = v end end
    return t
  end)
  if not okA then return "; the bandit lord's squads could not be read after the try: nothing asked away" end
  if #fresh == 0 then return "" end
  if #fresh > 1 then return string.format("; %d new squads of the bandit lord after the try: none asked away", #fresh) end
  local v = fresh[1]
  if not E.on.campLeftover then return string.format("; the try's squad %d is left (item campLeftover is off)", v) end
  S.madeHere = S.madeHere or {}; S.madeHere[v] = true
  S.rmDone = S.rmDone or {}; S.rmDone[v] = os.clock()            -- the core's own removal does not ask a second time
  local okR, e = pcall(function() S.sc:RequestRemoveSquad({ Value = v }) end)
  bump("k_leftover")
  return string.format("; the try's own squad %d asked away at once%s", v, okR and "" or (" (FAILED: " .. tostring(e) .. ")"))
end
function E.campAt(S, bx, by, bz, sx, sy, sz, owner)
  local before = {}
  local okBefore = pcall(function() local a = owner.commandedSquads; for i = 1, #a do before[a[i].Value] = true end end)
  local bb = {}
  pcall(function() local arr = S.eng.buildingArr; for i = 1, #arr do local b = un(arr[i]); if valid(b) then bb[addr(b)] = true end end end)
  S.eng:spawnBanditCamp()
  local new
  local arr = S.eng.buildingArr
  for i = #arr, 1, -1 do
    local b = un(arr[i])
    if valid(b) and not bb[addr(b)] and b:GetType() == CAMP_TYPE and ownerCode(S, b.ownerPawn) == "B" then new = b; break end
  end
  if not new then return nil, "the game made no camp" .. (okBefore and campLeftover(S, owner, before) or "; the bandit lord's squads were not read before the try: nothing asked away") end
  new:K2_SetActorLocation({ X = bx, Y = by, Z = bz }, false, {}, true)
  local key = bkey(new); E.campAsked[key] = true      -- the camp list will find it here: nothing more to make
  local h
  pcall(function() local a = owner.commandedSquads; for i = 1, #a do local v = a[i].Value; if v ~= 0 and not before[v] then h = v end end end)
  if not h or not S.sc:IsValidSquad({ Value = h }) then return nil, "camp made at " .. key .. ", but no new squad of the bandit lord" end
  local n = 0
  pcall(function()
    local ua = S.sc:GetSquad({ Value = h }).unitArr
    for i = 1, #ua do
      local u = un(ua[i])
      if valid(u) then
        local ox, oy = ((i - 1) % 6 - 2.5) * 150, (math.floor((i - 1) / 6) - 1) * 150    -- a small block, 1.5 m apart
        local p = { X = sx + ox, Y = sy + oy, Z = sz }
        u.realPos = p; u:K2_SetActorLocation(p, false, {}, true); n = n + 1
      end
    end
  end)
  -- (lane 48, round 4) the squad's centre too (the game works it out again from its men at its next tick; until then
  -- it still named the place the game rolled: k2, one sample at 576 m)
  -- (lane 55, item 5) round 4 wrote the squad's centre here, but GetSquad hands back the squad record BY VALUE
  -- (docs/nexus/loader_test_2026-11-12.md): the write changed a copy only (k4: a first sample at 188 m again). The
  -- game's own centre names the rolled place until its next squad update. Logged: that centre and the men's mean,
  -- both against the host's place, so a far first sample can be told apart from men not yet placed.
  local cd, md = -1, -1
  pcall(function()
    local s = S.sc:GetSquad({ Value = h }); local c = s.WeightedCenter; cd = math.sqrt((c.X - sx) ^ 2 + (c.Y - sy) ^ 2) / 100
    local ua, mx, my, k = s.unitArr, 0, 0, 0
    for i = 1, #ua do local u = un(ua[i]); if valid(u) then local p = u.realPos; mx = mx + p.X; my = my + p.Y; k = k + 1 end end
    if k > 0 then md = math.sqrt((mx / k - sx) ^ 2 + (my / k - sy) ^ 2) / 100 end
  end)
  return h, string.format("camp made at %s with its squad %d (%d men put at the host's squad's place; the game's centre %.1f m, the men's mean %.1f m from it)", key, h, n, cd, md)
end

-- ---- a camp that is gone on the host (lane 12; research/2026-11-10-game-probe/lanes/lane_s21_12/report.txt)
-- What a camp is (measured on a host alone and on two copies): a building of type 100 of the bandit lord in the
-- engine's lists buildingArr and independentBuildings, with a stock of loot, and ONE squad of brigands that holds on
-- to it (Squad.camp is the building, Squad.Control is 4, encamped). On the host the brigands let go of their camp
-- when they march out to meet an attacker (camp empty, Control 0), hold on to it again when they rout, and the game
-- folds the tents and takes the building out of both lists; the routing squad goes some seconds after its camp.
-- Nothing is left at the place.
-- A friend's brigands never let go (enemies decide nothing on a friend's copy): encamped or routing, in their lord's
-- list or no longer in it, they hold on to the camp until their squad is gone.
-- THE HAZARD (lane 12, session 3, one test host): a camp that is removed while a squad still holds on to it kills
-- the copy at one of the engine's next clean-ups. The squad keeps pointing at the removed building; the crash is in
-- the engine's unit update. It happened with the helper lord's demolish list, so it is not a matter of which
-- demolish is called. (The direct demolish of just-made camps that was switched off here after test hosts had
-- died fits the same picture: reasoned, not run again.) So the order is: the squad first, the camp after it.
-- The removal itself is the town module's own DEMOLISH (the helper lord's demolish list: the path of a player's
-- demolish click, and what lane 11 uses for a rival lord's buildings). Rules:
--   1. the camp must be missing from the host's list at two looks, the second at least 0.4 s after the first;
--   2. never while a squad of this copy still holds on to the camp. A squad the host no longer has is taken away
--      by the core (4 s after the host's word); a holder that is routing here is handed to the core's safe removal
--      by this rule, because the host's word about a routing squad comes some seconds after its camp went;
--   3. never while the helper lord is busy with a player's action;
--   4. refused, or the camp still stands 10 s after it was first seen missing: a resync (item campRepair), once.
-- A direct SMBuildingMaster:demolish on a camp is not used.
-- (2026-11-12, the user asked for it to be faster: the second look came 1 s after the first and the looks 0.5 s
-- apart, which made 1.5 s before the removal was even asked for. Hiding the camp at the first look was tried and
-- is NOT done: SetActorHiddenInGame(true) left the tent, the fire and the tripod on the screen and only took the
-- trodden ground away; pictures in research/2026-11-10-game-probe/lanes/lane_s21_0/camp_hide_test/)
local GONE_LOOK, GONE_LIMIT, GONE_AGAIN = 0.4, 10.0, 0.2

-- does squad h of this copy hold on to the building at address ba? nil when that could not be read
local function holds(S, h, ba)
  local ok, r = pcall(function()
    if not S.sc:IsValidSquad({ Value = h }) then return false end
    local c = un(S.sc:GetSquad({ Value = h }).camp)
    return valid(c) and addr(c) == ba
  end)
  if ok then return r == true end
end

-- The squads of this copy that hold on to a building; nil when that could not be read.
-- Every squad is asked: the ones in the lords' lists AND the squad of every unit, because a routing squad drops out
-- of its lord's list and lives on until its men have left the map (measured: such a squad of 10 brigands, in no
-- lord's list, still held on to its camp). The squad component has no reflected list of its squads.
-- Reading every unit's squad number costs about 12 ms with 560 units, so campGone asks the holders it already
-- knows first and comes here only when it knows none.
local function campSquads(S, b)
  local ba = addr(b); if not ba then return nil end
  local hs, okAll = {}, true
  for _, pw in ipairs(A.pawns()) do
    if valid(pw) then
      local ok = pcall(function()
        local arr = pw.commandedSquads; local n = #arr
        for i = 1, n do local h = arr[i].Value; if h and h ~= 0 then hs[h] = true end end
      end)
      if not ok then okAll = false end
    end
  end
  local ok = pcall(function()
    local arr = S.eng.unitArr; local n = #arr
    for i = 1, n do
      local u = un(arr[i])
      if valid(u) then local h = u.assignedSquadID.Value; if h and h ~= 0 then hs[h] = true end end
    end
  end)
  if not ok then okAll = false end
  local t = {}
  for h in pairs(hs) do
    local r = holds(S, h, ba)
    if r == nil then okAll = false elseif r then t[#t + 1] = h end
  end
  if okAll then return t end
end

-- The join module drops a request that follows another within 30 s (coop_join.lua, requestRepair): the camp is then
-- looked at again until the request can go out (or the reload that is already on its way has taken the camp away).
local function campResync(S, k, st, why)
  local J = C.join
  local can = E.on.campRepair and J and J.requestRepair
  if can and os.clock() - (J.repairT or -100) < 30.0 then
    if not st.saidWait then st.saidWait = true; log("bandit camp %s is gone on the host: %s: a resync was asked for less than 30 s ago, waiting for it", k, why) end
    return
  end
  st.asked = true
  log("bandit camp %s is gone on the host: %s: %s", k, why, can and "asking for a resync" or "no resync is asked for (item campRepair is off)"); bump("k_resync")
  if can then J.requestRepair("bandit camp " .. k .. " gone on the host") end
end

-- one look at a camp this copy has and the host's list lacks; st = { t0 = when it was first seen missing }
local function campGone(S, clock, k, c, st)
  if st.asked then return end
  if not valid(c.b) then return end                    -- (lane 47 round four) the camp list is read over several ticks                          -- a resync was asked for: the reload takes it from here
  local age = clock - st.t0
  if not E.on.campRemove then if age >= GONE_LOOK then campResync(S, k, st, "removing is switched off") end; return end
  local T = rawget(C, "town")
  if st.id then
    local r = T and T.results and T.results[st.id]
    if r ~= nil and r ~= "ok" and r ~= "queued/pending" then campResync(S, k, st, "the removal was refused (" .. tostring(r) .. ")"); return end
  elseif not (T and T.inject and T.results) then st.why = "the town module is not there"
  else
    -- the holders known from the last look are asked first; every squad is looked at only when none of them is left
    local held
    if st.held then
      local ba = addr(c.b); held = {}
      for _, h in ipairs(st.held) do if holds(S, h, ba) ~= false then held[#held + 1] = h end end
      if #held == 0 then held = campSquads(S, c.b) end
    else held = campSquads(S, c.b) end
    st.held = (held and #held > 0) and held or nil
    if not held then st.why = "the squads here could not be read"
    elseif #held > 0 then
      st.why = string.format("%d squad(s) here still hold on to it (%s)", #held, table.concat(held, ","))
      if not st.saidHeld then st.saidHeld = true; log("bandit camp %s is gone on the host; %s: waiting for the core to take them away", k, st.why) end
      -- A holder that is routing here (the game's own rout, started with the host's) is on its way out: on the host
      -- the camp goes some seconds BEFORE the host says that the routing squad is gone. Such a squad is handed to the
      -- core's safe removal now (4 s, no halt), at the first look already, so that the camp does not have to wait
      -- for that word as well.
      st.sent = st.sent or {}
      for _, h in ipairs(held) do
        if not st.sent[h] then
          local fleeing = false; pcall(function() fleeing = S.sc:GetSquad({ Value = h }).Control == 3 end)
          if fleeing and type(rawget(C, "removeSafe")) == "function" then
            st.sent[h] = true; pcall(C.removeSafe, h, "it routs and its camp is gone on the host"); bump("k_squad")
          end
        end
      end
    elseif age < GONE_LOOK then st.why = "seen missing only once so far"   -- nobody holds on to it: the second look removes it
    elseif T.pend or #(T.aq or {}) > 0 then st.why = "the helper lord was busy"
    else
      -- (lane 76) the camp's place from the town module's safe name (a cleared actor reads 0,0,0)
      local l = T.api.bident(c.b) or { x = 0, y = 0, z = 0 }
      local ok, id = pcall(T.inject, "DEMOLISH", string.format("%d,%.0f,%.0f,%.0f", CAMP_TYPE, l.x, l.y, l.z), "events")
      if not ok then campResync(S, k, st, "the town module could not take the removal (" .. tostring(id) .. ")"); return end
      st.id = id; st.why = "the town module's DEMOLISH did not take it away"; bump("k_demolish")
      log("bandit camp %s is gone on the host: removal handed to the town module (%s, %.1f s after it was seen missing)", k, tostring(id), age)
    end
  end
  if age >= GONE_LIMIT then campResync(S, k, st, string.format("it still stands here after %.0f s (%s)", age, tostring(st.why))) end
end

local function friendCamps(S, clock, map)
  local H = E.hostK; if not H then return end
  local G = E.campGone
  for k, c in pairs(map) do
    if not H[k] then
      local st = G[k]; if not st then st = { t0 = clock }; G[k] = st end
      campGone(S, clock, k, c, st)
    elseif G[k] then G[k] = nil end                    -- the host has it (again)
  end
  for k, st in pairs(G) do
    if not map[k] then                                 -- it no longer stands here
      if st.id and not st.asked then log("bandit camp %s is gone on the host: removed here (seen gone %.1f s after it was seen missing)", k, clock - st.t0); bump("k_removed") end
      G[k] = nil
    end
  end
  for _, st in pairs(G) do if not st.asked then E.tCamp = clock - CAMP_EVERY + GONE_AGAIN; break end end   -- a removal is under way: the next look comes sooner
  for k, z in pairs(H) do
    if not map[k] then
      E.campSince["+" .. k] = E.campSince["+" .. k] or clock
      if clock - E.campSince["+" .. k] >= 1.0 and not E.campAsked[k] then      -- (3 s until 2026-11-12)
        E.campAsked[k] = true
        local made, how = false, nil
        if E.on.campMake then local ok, r, m = pcall(campMake, S, k, z, map); made = ok and r; how = ok and m or tostring(r) end
        if made then log("bandit camp %s on the host: %s", k, tostring(how)); bump("k_made")
        else
          log("bandit camp %s on the host is missing here%s", k, how and (" (" .. tostring(how) .. ")") or ""); bump("k_missing")
          if E.on.campRepair and C.join and C.join.requestRepair then C.join.requestRepair("bandit camp " .. k .. " on the host") end
        end
      end
    else E.campSince["+" .. k] = nil end
  end
end

-- ---------------------------------------------------------------- region owners
local function readOwners(S)
  local t, arr = {}, S.eng.regions
  for i = 1, #arr do local r = un(arr[i]); if valid(r) then local k = rkey(r); if k then t[k] = ownerCode(S, r.ownerPawn) end end end
  return t
end

local function hostOwners(S, clock)
  local t = {}; for k, c in pairs(readOwners(S)) do t[#t + 1] = k .. "=" .. c end
  table.sort(t); local line = table.concat(t, ",")
  if line ~= E.sentO or clock - E.tKeyO >= KEY then
    if line ~= E.sentO then log("region owners on the host: %s", line); bump("o_sent") end
    E.sentO = line; E.tKeyO = clock
    A.send("E O " .. (line ~= "" and line or "-"))
  end
end

local function friendOwners(S, clock)
  local H = E.hostO; if not H then return end
  local mine = readOwners(S)
  for k, want in pairs(H) do
    local have = mine[k]
    if have and have ~= want then
      local key = k .. "=" .. want
      E.ownSince[key] = E.ownSince[key] or clock
      if clock - E.ownSince[key] >= 3.0 and not E.ownTried[key] then
        E.ownTried[key] = true
        log("region %s is held by %s on the host, by %s here", k, want, have); bump("o_diff")
        if E.on.ownerSet then
          -- the game's own end of a claim: the lord takes the region (session 2: PawnCPP:finalizeClaim(region, false)
          -- on a friend's copy gave the region to the bandit lord, as on the host). A region nobody holds on the host
          -- cannot be given away by name: the daily comparison (owners) asks for a resync.
          local ok, e = pcall(function()
            local reg, pw = regionByKey(S, k), pawnByCode(S, want)
            if not valid(reg) then error("no such region here") end
            if not valid(pw) then error("no lord " .. want .. " here") end
            pw:finalizeClaim(reg, false)
          end)
          local now = readOwners(S)[k]
          log("region %s given to %s here: %s", k, want, (ok and now == want) and "done" or ("NOT done (" .. tostring(ok and now or e) .. ")")); bump(now == want and "o_set" or "o_failed")
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- people (villager names)
-- A villager's name is rolled when the villager is made (SMUnit:pickRandomName, field SMUnit.DisplayName). A family
-- that arrives after the join, and a new family member, is made on every copy by that copy's own game, so the same
-- person has another name on each copy; the mod's family rules carry where a family lives and works, not who they are.
-- The host's people are pushed and a friend's copy takes the names:
--   E P <region> <families in the region> <first family in this line> <family>;<family>;...
--       family = <home key>|<name>~<role>~<age>|...      (names encoded; "-" = no family in this line)
-- A family is its place in the region's list (the realm module keeps the lists equal), checked by its home; a person
-- is the place in the family. A person whose role differs (son against daughter) is not renamed: counted and logged.
-- does this stored object pointer look like a pointer? (its number only; the object is not touched)
local function ptrOk(o)
  local ok, a = pcall(function() return o:GetAddress() end)
  return ok and type(a) == "number" and a > 0x10000 and a < 0x7FFFFFFFFFFF
end
local function peopleScan(S, done)
  local st = E.pscan
  if not st then
    st = { regs = {}, ri = 1, fi = 0, out = {}, own = {}, done = done }
    local arr = S.eng.regions; local me = addr(S.p1)
    for i = 1, #arr do
      local r = un(arr[i])
      if valid(r) and valid(r.ownerPawn) then
        -- (lane 64, lane 71's run h: in a rival lord's town 1 name differed at the start and 3 after 10 days, the
        -- player's town none) the other lords' towns are in the people line too: a person the people module makes
        -- there on a friend (a growth line of the host: a count, no name) had no way to get the host's name, because
        -- this scan and the line were for the player's own regions only. Read with the same care (below); a friend
        -- takes only NAMES from a rival town's line: no home, no death (those are the growth lines' and E PD's).
        local own = addr(r.ownerPawn) == me
        local nf = 0; if not own and E.on.rivalPeople then pcall(function() nf = #r.workerFamilies end) end
        if own or nf > 0 then local k = rkey(r); if k then st.regs[#st.regs + 1] = { k = k, r = r, own = own } end end
      end
    end
    E.pscan = st
  end
  local n = 0
  while n < 4 do                                       -- four families per tick
    local Rg = st.regs[st.ri]
    if not Rg then E.pscan = nil; st.done(st.out, st.own); return end
    st.out[Rg.k] = st.out[Rg.k] or {}; st.own[Rg.k] = Rg.own
    local fams = valid(Rg.r) and Rg.r.workerFamilies or nil
    if not fams or st.fi >= #fams then st.ri = st.ri + 1; st.fi = 0
    else
      st.fi = st.fi + 1; n = n + 1
      -- Care with a family that is just arriving or just changed (two host crashes in sessions 4 and 5 were inside
      -- the script layer, reading address -1; the cause was not isolated, and this scan was one of the candidates):
      -- a family's people are read only after its number of people has been the same for 8 s, and a person only
      -- when the stored pointer looks like one (checked without touching the object). Until then the family is
      -- marked "wait" and nobody compares it.
      local rec = { home = "-", m = {} }
      pcall(function()
        local F = fams[st.fi]
        local h = F.familyHome; if ptrOk(h) and valid(h) then rec.home = (bkey(h)) end
        local m = F.familyMembers; local count = #m
        local key = Rg.k .. "|" .. st.fi; local seen = E.famSeen[key]
        if not seen or seen.n ~= count then E.famSeen[key] = { n = count, t = os.clock() }; rec.wait = true; return end
        if os.clock() - seen.t < 8.0 then rec.wait = true; return end
        for j = 1, count do
          local raw = m[j]
          local u = ptrOk(raw) and un(raw) or nil
          if u and valid(u) then rec.m[j] = { u = u, n = u.DisplayName:ToString(), role = tonumber(u.assignedUnitRole) or -1, age = tonumber(u.Age) or -1 }
          else rec.m[j] = { n = "", role = -1, age = -1 } end
        end
      end)
      st.out[Rg.k][st.fi] = rec
    end
  end
end

local function hostPeople(S, clock, out)
  local key = clock - E.tKeyP >= KEY; if key then E.tKeyP = clock end
  for rk, fams in pairs(out) do
    local parts = {}
    for i, rec in ipairs(fams) do
      local t = { rec.home }
      if rec.wait then t[2] = "?"                       -- its people are not read yet
      else for _, p in ipairs(rec.m) do t[#t + 1] = string.format("%s~%d~%d", enc(p.n), math.floor(p.role), math.floor(p.age)) end end
      parts[i] = table.concat(t, "|")
    end
    local sig = table.concat(parts, ";")
    if sig ~= E.sentP[rk] or key then
      if sig ~= E.sentP[rk] then bump("p_sent") end
      E.sentP[rk] = sig
      local i = 1
      repeat                                           -- lines under 3000 characters
        local buf, len, first = {}, 0, i
        while i <= #parts and (len == 0 or len + #parts[i] + 1 <= 3000) do buf[#buf + 1] = parts[i]; len = len + #parts[i] + 1; i = i + 1 end
        A.send(string.format("E P %s %d %d %s", rk, #parts, first, #buf > 0 and table.concat(buf, ";") or "-"))
      until i > #parts
    end
  end
end

-- Which of this copy's family members the host's family no longer has: the places (in this copy's list) that are left
-- over when the host's people are found in order, each by role AND name. nil = not every one of the host's people
-- was found, and then nobody is touched: who dies is never decided by the place in the list alone.
local function extrasOf(hm, fm)
  local ex, i = {}, 1
  for j, p in ipairs(fm) do
    local h = hm[i]
    if h and h.role == p.role and h.n ~= "" and h.n == p.n then i = i + 1 else ex[#ex + 1] = j end
  end
  if i == #hm + 1 and #ex > 0 then return ex end
end
local function findBuilding(S, key)
  local arr = S.eng.buildingArr
  for i = 1, #arr do local b = un(arr[i]); if valid(b) then local ok, k = pcall(bkey, b); if ok and k == key then return b end end end
end
local function inSquad(S, u)
  local ok, r = pcall(function() local v = u.assignedSquadID.Value; return v ~= nil and v ~= 0 and S.sc:IsValidSquad({ Value = v }) end)
  return ok and r == true
end

-- Session 3 (brigands set the town on fire): two more things about people differ after a raid, and each asked for a
-- resync. (1) A family whose house burns is homeless on the host long before the house is a ruin on the friend's copy
-- (a friend's fire only ends when the host's does), and after the fire each copy's game re-houses its homeless by
-- itself. The host's home of every family is in the people line, so a friend's copy gives the family the host's home
-- with the game's own Region:SetFamilyHome (no home = homeless). (2) Villagers killed on the host stay alive here.
-- When the host's family is this copy's family minus some people (each of the host's found here by role and name, the
-- family in the same home), for two looks in a row, those people die here too
-- (SMUnit:just_die, the game's own death; not while they stand in a called-up unit).
-- (lane 64) ... but only a person whose death the host TOLD (E PD) and whose mark was not found here: see below.
local function friendPeople(S, clock, out, own)
  local fixed, kind, same, waiting = 0, 0, 0, 0
  E.namesBy = E.namesBy or {}
  for rk, fams in pairs(out) do
    local H = E.hostP[rk]
    local reg = H and regionByKey(S, rk)
    local isOwn = not own or own[rk] ~= false          -- false: another lord's town (names only)
    local mine, hostN, whole = {}, {}, true             -- every person's name here and on the host (lane 64: the proof by lists)
    if H and reg and #fams == (H.n or -1) then         -- the two lists are the same families only when equally long
      for i, rec in ipairs(fams) do
        local h = H.fams[i]
        if not h then waiting = waiting + 1; whole = false
        else
          local fk = rk .. "|" .. i
          if h.wait or rec.wait then whole = false end
          if isOwn and h.home ~= rec.home then
            -- (lane 64, after lane 66's run 4) the home is NOT set from this line any more: the people line is a
            -- sample that can be older than a growth line already taken here, and setting from it moved two families
            -- back into the houses they had just left, one of them a house that then burnt down. The homes rule
            -- below (friendHomes) gives every family the host's home, from the newest word of the host.
            waiting = waiting + 1; E.deadSig[fk] = nil   -- people are compared only once the family lives where it does on the host
          elseif h.wait or rec.wait then waiting = waiting + 1; E.deadSig[fk] = nil   -- one side has not read its people yet
          elseif #rec.m ~= #h.m and not (isOwn and #rec.m > #h.m and extrasOf(h.m, rec.m)) then
            waiting = waiting + 1; E.deadSig[fk] = nil   -- another number of people and no clear answer who is missing: left to the daily comparison
                                                         -- (another lord's town: always left; nobody dies there by this rule)
          elseif #rec.m > #h.m then
            local extras = extrasOf(h.m, rec.m)
            local sig = table.concat(extras, ",") .. "/" .. #h.m
            if E.deadSig[fk] ~= sig then E.deadSig[fk] = sig; E.deadT[fk] = clock; E.tPeople = clock - PEOPLE_EVERY + 4.0   -- look again in 4 s
            elseif clock - E.deadT[fk] >= 3.5 and E.on.deaths then
              E.deadSig[fk] = nil
              for _, j in ipairs(extras) do
                local p = rec.m[j]
                -- (lane 64) THE RULE: a villager dies here only when the host said so. The host tells every death at
                -- once (E PD); this rule is the net for a death whose villager was not found by its mark (a line of
                -- the last 5 minutes that was dropped: same region, same role, and the same name or family number).
                -- A person the host's family simply has not is NOT dead: this copy's own game made him a day early
                -- (game run r1: "family 17: Ernst is dead on the host: dies here" for a son the host never had; the
                -- host's family got its third person two days later). He lives; the host's next growth is his.
                local told
                for q, mz in ipairs(E.pdMiss or {}) do
                  if clock - mz.t < 300.0 and (mz.rk == nil or mz.rk == rk) and (mz.role < 0 or mz.role == p.role) and
                     (mz.name == (p.n:gsub("[^%w]", "_")) or mz.fam == i - 1) then told = q; break end
                end
                if not told then
                  if not E.keptSaid[fk .. "|" .. p.n] then
                    E.keptSaid[fk .. "|" .. p.n] = true; bump("p_extraKept")
                    log("people: %s family %d: %s is here and not in the host's family, and the host told no death: he lives (this copy's own game made him; the host's next growth takes him)", rk, i, p.n)
                  end
                elseif p.u and valid(p.u) and not inSquad(S, p.u) then
                  table.remove(E.pdMiss, told)
                  local ok, e = pcall(function() p.u:just_die() end)
                  log("people: %s family %d: %s is dead on the host (a death told and not found by its mark): dies here%s", rk, i, p.n, ok and "" or (" FAILED " .. tostring(e))); bump("p_died")
                else bump("p_diedSkipped") end
              end
            end
          else
            E.deadSig[fk] = nil
            for j, p in ipairs(rec.m) do
              local hp = h.m[j]
              if hp and p.u and valid(p.u) then
                if hp.role ~= p.role then kind = kind + 1
                elseif hp.n == p.n then same = same + 1
                elseif hp.n ~= "" and E.on.names then
                  local ok, back = pcall(function() p.u.DisplayName = hp.n; return p.u.DisplayName:ToString() end)
                  if ok and back == hp.n then
                    fixed = fixed + 1; bump("p_named"); if not isOwn then bump("p_namedRival") end
                    log("people: %s family %d person %d is %s on the host (was %s here)", rk, i, j, hp.n, p.n)
                    p.n = hp.n
                  else E.on.names = false; log("people: item names switched off: a name could not be written (%s)", tostring(back)) end
                end
              end
            end
          end
          if not h.wait and not rec.wait then
            for _, p in ipairs(rec.m) do mine[#mine + 1] = p.n end
            for _, hp in ipairs(h.m) do hostN[#hostN + 1] = hp.n end
          end
        end
      end
    elseif H then waiting = waiting + #fams; whole = false end   -- the family lists are not equally long yet (the realm module's rule)
    -- (lane 64) this region's names here against the host's, as two sorted lists: how many names are in one list
    -- and not in the other (0 = the lists are equal). Kept in E.namesBy for the tests; logged when it changes.
    if H then
      local cnt, left, d = {}, 0, 0
      for _, n in ipairs(hostN) do cnt[n] = (cnt[n] or 0) + 1 end
      for _, n in ipairs(mine) do if (cnt[n] or 0) > 0 then cnt[n] = cnt[n] - 1 else d = d + 1 end end
      for _, c in pairs(cnt) do left = left + c end
      if left > d then d = left end
      local N = { here = #mine, host = #hostN, differ = d, whole = whole, own = isOwn, t = clock }
      local sig = N.here .. "/" .. N.host .. "/" .. d .. "/" .. tostring(whole)
      local old = E.namesBy[rk]
      if (not old or old.sig ~= sig) and (d > 0 or (old and old.differ > 0)) then
        log("people: %s names: %d here, %d on the host, %d differ as sorted lists%s", rk, N.here, N.host, d, whole and "" or " (not every family read yet)")
      end
      N.sig = sig; E.namesBy[rk] = N
    end
  end
  local sum = string.format("%d equal, %d renamed, %d of another kind, %d families not matched", same, fixed, kind, waiting)
  E.peopleNow = sum
  if kind ~= (E.lastKind or 0) then E.lastKind = kind; log("people: %d differ in kind from the host's (a son here, a daughter there): not renamed", kind); bump("p_kind") end
end

-- ---------------------------------------------------------------- where a family lives (lane 64, after lane 66's run 4)
-- THE RULE: ON A FRIEND'S COPY A FAMILY LIVES WHERE IT LIVES ON THE HOST, AND IS NEVER LEFT HOMELESS WHEN IT HAS A HOME
-- THERE. A friend's game houses nobody by itself (the native HOLD holds accomodateHomelessFamilies), but its own
-- routines still put a family OUT: the burn-down (progressFire 4d49af0, READ: every family of the house gets home
-- none, each of its people's home pointer is cleared, then the held housing call), a demolition, an upgrade.
-- Lane 66's run 4, brigands' fires, both logs: two houses burnt down on the host in the same moment. Its game housed
-- family 5 (of 8@9634) in the ruin 8@9460 and family 8 (of 8@9786) in the ruin 8@9634 (a ruin is a free house to the
-- game: every burn-down of that run moved its family into the ruin of the fire before). The friend took the two growth
-- lines at once (...842.973). Then two things went wrong here:
--   1. ...844.002: the people rule moved both families BACK, from a people line that was older than the growth lines
--      (and forward again a second later, from the next people line).
--   2. ...845.285: the host's word that 8@9634 had burnt down came 2.2 s after the growth lines (the host's fire scan
--      runs every 2 s and walks the building list a slice per tick; the growth look runs twice a second). The burn-down
--      here put family 8 out of the house it had just been given. The people rule had set that same home 0.28 s
--      before and would not set one home twice within 10 s; the realm module's 10 s ran out first and asked for a
--      repair ("11 of the host's are missing here" = the lists differ from place 8 on).
-- So the order of the host's two words cannot be relied on (two polls), and this rule does not need it:
--   * the host's homes are ONE list per region, the newest word wins in the order the lines arrive: the realm
--     module's whole list (R IS <region> fams, read fresh as it is sent) with every growth line's home (V G .. M,
--     read fresh as it is sent) written over its place. Without the realm's list: the people line's homes, the same way.
--     After a family arrived or left (V G F / X: places move) the list waits for the realm's next whole one (5 s at most).
--   * a family that lives elsewhere here (or nowhere) is given the host's home with the game's own Region:SetFamilyHome:
--     once a second, and AT ONCE, in the same tick, after this copy burnt a house down, put a fire out, or replayed a
--     town action (E.homesNow: the world and town modules call it).
--   * the same move is not repeated within 5 s only when nothing changed since it was tried (it did not take, or the
--     host's house is not a building here yet); a home lost again is given again at once (6 times in 10 s at most).
local HOMES_EVERY, HOME_AGAIN, HOME_DIRTY = 1.0, 5.0, 5.0
E.hh = E.hh or {}; E.hhDirty = E.hhDirty or {}; E.homeM = E.homeM or {}; E.homeTry = E.homeTry or {}   -- (a module loaded again in a running world)
E.homeBusyT = E.homeBusyT or {}; E.homeSaid = E.homeSaid or {}
local function hhSync(rk)
  local R = rawget(C, "realm"); local H = R and R.famHost and R.famHost[rk]
  local v = H and type(H.v) == "string" and H.v or nil
  if v then
    local X = E.hh[rk]
    if not X or X.src ~= v then
      X = { src = v, list = {} }
      for k in v:gmatch("[^;]+") do if k ~= "0" then X.list[#X.list + 1] = k end end
      E.hh[rk] = X; E.hhDirty[rk] = nil
    end
    return X
  end
  local P = E.hostP[rk]
  if P and P.n and P.fams then
    -- (a people line can be older than a growth line taken before it: for 5 s the growth line's home stands)
    local list, now = {}, os.clock()
    for i = 1, P.n do
      local f = P.fams[i]; if not f then return nil end
      local G = E.homeM[rk .. "|" .. i]
      list[i] = (G and now - G.t < 5.0) and G.home or f.home
    end
    return { list = list, people = true }
  end
end
-- a growth line of the host, the moment a friend reads it (the people module calls this, in the line's order)
function E.noteGrow(rk, kind, place, home)
  if kind == "M" then
    if not E.hhDirty[rk] then
      local X = hhSync(rk)
      if X and not X.people and place <= #X.list then X.list[place] = home end
      local P = E.hostP[rk]; if P and P.fams and P.fams[place] then P.fams[place].home = home end
      E.homeM[rk .. "|" .. place] = { home = home, t = os.clock() }
    end
  else
    E.hhDirty[rk] = os.clock()
    for k in pairs(E.homeM) do if k:sub(1, #rk + 1) == rk .. "|" then E.homeM[k] = nil end end
    local P = E.hostP[rk]; if P then P.n = nil end        -- the people line's places are the old ones: wait for the next line
  end
  E.tHomes = -1e9
end
local function homeKeyOf(F) local h = F.familyHome; if ptrOk(h) and valid(h) then return (bkey(h)) end; return "-" end
local function friendHomes(S, clock, why)
  local seen, moved = {}, 0
  local function one(rk)
    if seen[rk] then return end
    seen[rk] = true
    local X = hhSync(rk); if not X then return end      -- (a new whole list of the realm ends the wait below)
    if E.hhDirty[rk] then if clock - E.hhDirty[rk] < HOME_DIRTY then return end; E.hhDirty[rk] = nil end
    local reg = regionByKey(S, rk); if not reg then return end
    -- the player's own regions only: another lord's town is in the people line for its NAMES (its families' homes
    -- are the people module's, by the growth lines)
    local okO, mineR = pcall(function() return valid(reg.ownerPawn) and addr(reg.ownerPawn) == addr(S.p1) end)
    if not (okO and mineR) then return end
    local fams = reg.workerFamilies
    if #fams ~= #X.list then return end                 -- not the same families yet (the people and realm modules' rule)
    for i = 1, #X.list do
      local want = X.list[i]
      local okH, here = pcall(homeKeyOf, fams[i])
      if okH and want ~= "?" and here ~= want then
        local fk = rk .. "|" .. i
        local T = E.homeTry[fk]
        if not (T and T.want == want) then T = { want = want, n = 0, t0 = clock }; E.homeTry[fk] = T end
        if clock - T.t0 > 10.0 then T.n = 0; T.t0 = clock end
        if T.here == here and T.t and clock - T.t < HOME_AGAIN then bump("p_homeWait")   -- tried, and nothing changed since
        elseif T.n >= 6 then
          if not E.homeSaid[fk .. "|loop"] then E.homeSaid[fk .. "|loop"] = true; log("people: %s family %d: its home %s was given 6 times in 10 s and lost each time: left for 10 s", rk, i, want) end
          bump("p_homeLoop")
        else
          T.n = T.n + 1; T.t = clock; T.here = here
          local b, ok, e = nil, true, nil
          if want ~= "-" then b = findBuilding(S, want) end
          if want ~= "-" and not b then ok, e = false, "no such building here"
          else ok, e = pcall(function() reg:SetFamilyHome(i - 1, b, true) end) end   -- the game counts families from 0
          E.homeBusyT[rk] = clock
          if ok then
            moved = moved + 1
            -- did it take? Then a home lost again later is a new case, given again at once (not "tried, nothing changed")
            local okN, now = pcall(homeKeyOf, fams[i]); if okN and now == want then T.here = nil end
          end
          if ok or not E.homeSaid[fk .. "|" .. want] then
            if not ok then E.homeSaid[fk .. "|" .. want] = true end
            log("people: %s family %d lives in %s on the host (%s here): %s%s", rk, i, want, here, ok and "moved" or ("NOT moved: " .. tostring(e)), why and (" (after " .. tostring(why) .. ")") or "")
          end
          bump(ok and "p_home" or "p_homeFailed")
        end
      elseif okH and E.homeTry[rk .. "|" .. i] then E.homeTry[rk .. "|" .. i].here = nil   -- it lives there: a home lost later is a new case
      end
    end
  end
  local R = rawget(C, "realm")
  if R and R.famHost then for rk in pairs(R.famHost) do one(rk) end end
  for rk in pairs(E.hostP) do one(rk) end
  return moved
end
-- this copy just put families out by a routine of its own game (a burn-down, a put-out, a replayed town action):
-- they get the host's homes now, in this tick
function E.homesNow(why)
  local S = E.S
  if not (S and S.role == "friend" and E.on.homes and E.world == S.worlds and valid(S.eng)) or rawget(C, "hold") then return 0 end   -- (not during a join or load)
  local ok, n = pcall(friendHomes, S, os.clock(), why)
  if not ok then E.lastErr = "homes: " .. tostring(n); bump("err"); return 0 end
  return n
end
-- is a home of this region being put right just now? (the realm module waits with its family check meanwhile)
function E.homeBusy(rk, clock)
  local t = E.homeBusyT and E.homeBusyT[rk]; local d = E.hhDirty and E.hhDirty[rk]
  return (t ~= nil and clock - t < 3.0) or (d ~= nil and clock - d < HOME_DIRTY)
end
-- the host's home of the family at this place, by its newest word (nil = not known), and how many families its list has
function E.hostHomeOf(rk, place) local X = hhSync(rk); if not X then return nil end; return X.list[place], #X.list end

-- ---------------------------------------------------------------- villagers who die (lane 24; lane 64)
-- A raid on the town (lane 24, sitting 3): brigands killed 5 villagers on the host; on the friend's copy they stayed
-- alive (families 49 people against 54), because the rule above needs the family in the same home on both copies, and
-- burning houses had just made families homeless at different moments. The realm module then asked for a resync.
-- So the host names each villager the moment he is dead (his mark: family number and name, the same mark the core uses
-- for militia men, with role and age), and a friend's copy lets the same villager die, the way the core does
-- for a soldier the host lost in a fight (the game's own death, marked "in combat"). A man in a called-up unit is left
-- to the core's death line (D). A mark nobody here has is tried again for 10 s, then dropped.
--
-- LANE 64 (live session of 2026-11-17, three PCs: a villager starved on two friends' copies and not on the host; the
-- head count was repaired a day later, the body and the death notice stayed on the friends alone).
-- THE RULE: ON A FRIEND'S COPY A VILLAGER NEVER DIES BY THAT COPY'S OWN GAME. coop_patch's NODEATH takes the game's
-- own deaths out there (hunger and cold, a work accident, a fire, a collapse, the animals' hunger: coop_die.h), as
-- NOKILL does in a fight; a villager dies when the host says so:
--   host -> friends   E PD <mark> <role> <age> <fight 0|1> <region> <tag> <text> <x>,<y>,<z>
--                       mark = <family number>.<name>; region = the region's tag (the player's own regions and the
--                       other lords' towns: a rival's villager died on the host only before, "imm corpses 1/0");
--                       tag, text = the notice the host's game gave its player for this death ("death" "death_hunger",
--                       "death" "death_cold", "death" "worker_death_due_to_bad_maintenance", "crushed" "crushed";
--                       "-" "-" = none: a fight, a fire); the place = where the host's villager died.
--   A friend finds the same villager (region, mark, role, age within a year) and calls the game's own SMUnit:just_die
--   (the body, the family's grief, the home's mourning, the region's corpse list: all the game's), then gives its
--   player the same notice with the game's own PawnCPP:addLog (READ in the game: the hunger step calls
--   addLog("death", "death_hunger", "death_hunger_descr", 0, <place>, none) before just_die; the descr key is always
--   the text key .. "_descr").
-- THE CAUSE on the host: the newest entries of the lord's own log (PawnCPP.log) with the tag "death" or "crushed" at
-- the dead villager's place; when the log cannot be read (its struct's fields are found by reflection, once), from
-- the family's marks (hunger 0: death_hunger, cold 0: death_cold); else no notice.
-- CORPSES (the same lane): the host's list of bodies per region is pushed (E PC); a body on a friend's copy that the
-- host has not is taken out with the engine's own destroyUnit (READ 4cad1f0: a dead unit is taken out of every
-- region's corpse list there). See "corpses" below.
local function villTok(u)
  local n = u.DisplayName:ToString()
  if type(n) ~= "string" or n == "" then return nil end
  return tostring(u.workerFamilyID) .. "." .. (n:gsub("[^%w]", "_"))
end
-- the regions whose villagers are named: the player's own, and every other lord's region with families
local function famRegions(S)
  local t = {}; local arr = S.eng.regions; local me = addr(S.p1)
  for i = 1, #arr do
    local r = un(arr[i])
    if valid(r) and valid(r.ownerPawn) then
      local own = addr(r.ownerPawn) == me
      local n = 0; pcall(function() n = #r.workerFamilies end)
      local k = (own or n > 0) and rkey(r) or nil
      if k then t[#t + 1] = { k = k, r = r, own = own } end
    end
  end
  return t
end
-- the living villagers by "<region>|<mark>": { u = unit, rk = region tag, own = the player's region }
-- Another lord's families (new with lane 64) are read by lane 5's rule: a family's people only after its number of
-- people has been the same for 8 s (a family just arriving or changing was a candidate for two host crashes inside
-- the script layer, see peopleScan). A villager who dies is still told: he was in the look before, and his own
-- handle says that he is dead. The player's own town is read every look, as since lane 24. (The rule is for the
-- host's look of every second; a friend reads only while a death from the host waits for its villager.)
local function villagers(S)
  local t, waitFam = {}, {}
  E.vSeen = E.vSeen or {}
  local clock = os.clock()
  local settle = S.role == "host"
  for _, R in ipairs(famRegions(S)) do
    local fams = R.r.workerFamilies
    for f = 1, #fams do
      pcall(function()
        local m = fams[f].familyMembers
        if settle and not R.own then
          local count = #m; local key = R.k .. "|" .. f; local seen = E.vSeen[key]
          if not seen or seen.n ~= count then E.vSeen[key] = { n = count, t = clock }; waitFam[key] = true; return end
          if clock - seen.t < 8.0 then waitFam[key] = true; return end
        end
        for j = 1, #m do
          local raw = m[j]
          local u = ptrOk(raw) and un(raw) or nil
          if u and valid(u) and not u.dead then local k = villTok(u); if k then t[R.k .. "|" .. k] = { u = u, rk = R.k, own = R.own, tok = k, fk = R.k .. "|" .. f } end end      -- the living only
        end
      end)
    end
  end
  return t, waitFam
end

-- the lord's log (PawnCPP.log, an array of the struct LogEntry): which of its fields are the tag, the text and the
-- place. Found once by reflection (the struct's field names are not in the project's dumps); false = not readable.
local LOG_KEYS = { death = true, crushed = true }
local function logFields()
  if E.logF ~= nil then return E.logF end
  E.logF = false
  local ok, e = pcall(function()
    local st = StaticFindObject("/Script/ManorLords.LogEntry")
    if not valid(st) then error("no struct LogEntry") end
    -- by name where the struct has the names of addLog's own parameters (Tag, Text, Pos); else the first field of
    -- the kind (a text field whose name says "descr" is never the text)
    local tag, text, pos, tagN, textN, posN
    st:ForEachProperty(function(p)
      local n = p:GetFName():ToString(); local ty = p:GetClass():GetFName():ToString(); local l = n:lower()
      if ty == "NameProperty" then tag = tag or n; if l == "tag" then tagN = n end
      elseif ty == "StrProperty" or ty == "TextProperty" then
        if not l:find("descr", 1, true) then text = text or n end
        if l == "text" then textN = n end
      elseif ty == "StructProperty" then pos = pos or n; if l == "pos" or l == "position" or l == "location" then posN = n end end
    end)
    tag, text, pos = tagN or tag, textN or text, posN or pos
    if not (tag and text) then error("no tag or text field") end
    E.logF = { tag = tag, text = text, pos = pos }
  end)
  log("people: the lord's log entries %s", E.logF and string.format("are read by the fields %s, %s, %s", E.logF.tag, E.logF.text, tostring(E.logF.pos)) or ("cannot be read (" .. tostring(e) .. "): a death's cause comes from the family's marks"))
  return E.logF
end
-- the notice the host's game gave for a death at this place: tag, text (nil when none is found)
local function logCause(S, x, y)
  local F = logFields(); if not F then return nil end
  local ok, tag, text = pcall(function()
    local L = S.p1.log; local n = #L
    for i = n, math.max(1, n - 7), -1 do               -- the newest eight; never an index outside 1..n
      local e = L[i]
      local tg = e[F.tag]:ToString()
      if LOG_KEYS[tg] then
        local near = true
        if F.pos then local p = e[F.pos]; local dx, dy = (tonumber(p.X) or 1e9) - x, (tonumber(p.Y) or 1e9) - y; near = dx * dx + dy * dy < 300 * 300 end
        if near then
          local tx = e[F.text]:ToString()
          if type(tx) == "string" and tx:match("^[%w_]+$") and not tx:match("_descr$") then return tg, tx end   -- a plain key, and not the description's
        end
      end
    end
  end)
  if not ok then E.logF = false; log("people: the lord's log could not be read (%s): a death's cause comes from the family's marks from now on", tostring(tag)); bump("pd_logFail"); return nil end
  return tag, text
end
-- ... and from the dead villager's family's marks, when the log gave nothing
local function markCause(reg, u)
  local tag, text
  pcall(function()
    local f = math.floor(tonumber(u.workerFamilyID) or -1); local fams = reg.workerFamilies
    if f < 0 or f + 1 > #fams then return end
    local cs = fams[f + 1].ConsumptionStatus
    if (tonumber(cs.hunger) or 9) <= 0 then tag, text = "death", "death_hunger"
    elseif (tonumber(cs.cold) or 9) <= 0 then tag, text = "death", "death_cold" end
  end)
  return tag, text
end
local function placeOf(u)
  local x, y, z
  pcall(function() local p = u.realPos; x, y, z = p.X, p.Y, p.Z end)
  if not (x and x == x and y and y == y) then pcall(function() local p = u:K2_GetActorLocation(); x, y, z = p.X, p.Y, p.Z end) end
  if x and y and x == x and y == y and math.abs(x) < 1e8 and math.abs(y) < 1e8 then return x, y, (z and z == z and math.abs(z) < 1e8) and z or 0 end
end

local function hostVillagers(S)
  local now, waitFam = villagers(S); local old = E.vill; E.vill = now
  if not old then return end
  local regs
  for k, v in pairs(old) do
    if not now[k] then
      local u = v.u
      local dead, alive = false, false; pcall(function() if valid(u) then dead = u.dead == true; alive = not dead end end)
      -- a living villager of a family that is not read just now (another lord's, its number of people changed under
      -- 8 s ago) stays known by his own handle: a second death in that family is told too
      if alive and waitFam[v.fk] then now[k] = v end
      if dead then
        local role, age, fight = -1, -1, 0; pcall(function() role = tonumber(u.assignedUnitRole) or -1; age = tonumber(u.Age) or -1 end)
        -- killed in a fight (the game's combat code tags him) or another death: told, so that a friend's copy books
        -- the same grief or none
        pcall(function() local tg = u.Tags; for i = 1, #tg do if un(tg[i]):ToString() == "deathInCombat" then fight = 1 end end end)
        local x, y, z = placeOf(u)
        local tag, text
        if fight == 0 and E.on.notices then
          if v.own and x then tag, text = logCause(S, x, y) end
          if not tag then
            if not regs then regs = {}; for _, R in ipairs(famRegions(S)) do regs[R.k] = R.r end end
            if regs[v.rk] then tag, text = markCause(regs[v.rk], u) end
          end
        end
        A.send(string.format("E PD %s %d %d %d %s %s %s %d,%d,%d", enc(v.tok), math.floor(role), math.floor(age), fight, v.rk, tag or "-", text or "-",
          math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5), math.floor((z or 0) + 0.5)))
        bump("pd_sent"); E.tCorpse = -1e9                             -- the corpse list follows at once
        log("people: villager %s of %s died on the host (%s): told", v.tok, v.rk, fight == 1 and "a fight" or (text or "no notice"))
      end
    end
  end
end
local function friendVillagers(S, clock)
  if not next(E.pdQ) then return end
  local now = villagers(S)
  for k, q in pairs(E.pdQ) do
    -- the host's region and mark; a line without a region (an older host) is looked for in the player's own regions
    local v = q.rk and now[q.rk .. "|" .. q.tok] or nil
    if not q.rk then for _, x in pairs(now) do if x.own and x.tok == q.tok then v = x; break end end end
    -- (game run r4) the LAST person of a family: when he dies the host's family leaves its list, and the people
    -- module's line for that (V G X) can be carried out here before the death: the family is gone from this copy's
    -- list and its people wait 5 s to be taken out without a body ("hof|9.Albrecht died on the host and is not found
    -- here", then "corpses 14/13" for 11 days). He is looked for among those people too (name and role), and dies.
    local leaving = false
    if not v then
      local PP = rawget(C, "people"); local nameOnly = q.tok:match("^%-?%d+%.(.*)$")
      for _, x in ipairs(PP and PP.leaving or {}) do
        local okL, hit = pcall(function() return valid(x.u) and not x.u.dead and (x.u.DisplayName:ToString():gsub("[^%w]", "_")) == nameOnly end)
        if okL and hit then
          local own = true
          if q.rk then own = false; pcall(function() local r = regionByKey(S, q.rk); own = valid(r) and valid(r.ownerPawn) and addr(r.ownerPawn) == addr(S.p1) end) end
          v = { u = x.u, rk = q.rk, own = own, tok = q.tok }; leaving = true; bump("pd_leaving"); break
        end
      end
    end
    local u = v and v.u
    -- the mark (family number and name) is not proof alone: the same name occurs in several families, and family
    -- numbers can change with a load. Role and age (within a year) must agree too, or nobody dies here.
    if u then
      local okM, same = pcall(function() return (q.role < 0 or tonumber(u.assignedUnitRole) == q.role) and (q.age < 0 or math.abs((tonumber(u.Age) or -99) - q.age) <= 1) end)
      if not (okM and same) then u = nil end
    end
    if u then
      E.pdQ[k] = nil
      -- only a man of a CALLED-UP unit is left to the unit's death line: every militia man keeps his unit's number at
      -- home too (sitting 4: ten villagers at home were skipped that way and stayed alive here)
      local inUnit = false; pcall(function() local s = u.assignedSquadID.Value; inUnit = s ~= nil and s ~= 0 and S.sc:IsValidSquad({ Value = s }) and (tonumber(S.sc:GetSquad({ Value = s }).rallyingStatus) or 0) ~= 0 end)
      if inUnit then bump("pd_inUnit"); log("people: villager %s died on the host; here he stands in a called-up unit: left to the unit's death line", k)
      else
        local x, y, z = placeOf(u)
        -- (a person of a family that has left the list has no family to grieve: marked like a fight's death, so his
        --  old family number books no grief with whichever family stands at that place now)
        local ok, e = pcall(function() if q.fight or leaving then local tg = u.Tags; tg[#tg + 1] = FName("deathInCombat") end; u:just_die() end)
        bump(ok and "pd_died" or "pd_failed")
        -- the game's own notice, as the host's player got it (only for the player's own town: the game gives the
        -- lord of a region its notices, and this copy's player is that lord)
        local said = ""
        -- (lane 64, sitting v5f: the friend's log held 5 death notices for the host's 3) the realm module carries the
        -- host's new notices too (R LOG, the entry itself, twice a second): with it on, the notice is the realm's and
        -- none is given here, or the player reads it twice.
        local Rm = rawget(C, "realm"); local relayed = Rm and Rm.on and Rm.on.notices
        if ok and v.own and q.tag and q.text and relayed then bump("pd_noticeRealm"); said = ", notice " .. q.text .. " left to the realm module's line"
        elseif ok and v.own and q.tag and q.text and E.on.notices and x then
          -- (after the merge of rel-0.2.5: lane 66's NOLOG drops a notice on a friend that the mod did not mark)
          local okN, eN = pcall(function() local Pt = rawget(C, "patch"); if Pt and Pt.markLog then Pt.markLog() end; S.p1:addLog(FName(q.tag), q.text, q.text .. "_descr", 0, { X = x + 0.0, Y = y + 0.0, Z = z + 0.0 }, nil) end)
          bump(okN and "pd_notice" or "pd_noticeFail"); said = okN and (", notice " .. q.text) or (", notice NOT shown: " .. tostring(eN))
        end
        local far = ""
        if x and q.x then local d = math.sqrt((x - q.x) ^ 2 + (y - q.y) ^ 2) / 100; if d > 10 then far = string.format(", %.0f m from the host's place", d); bump("pd_far") end end
        log("people: villager %s died on the host%s (%.1f s after the word): dies here%s%s%s%s", k, q.fight and " in a fight" or "", math.max(0, os.clock() - q.t), ok and "" or (" FAILED " .. tostring(e)), said, far,
          leaving and " (the last of his family: found among the people of a family that had just left the list)" or "")
        E.tCorpseF = -1e9
      end
    elseif clock - q.t > 10.0 then
      E.pdQ[k] = nil; bump("pd_notFound"); log("people: villager %s died on the host and is not found here: dropped (the family rule looks for him for 5 minutes)", k)
      -- kept for the family rule of friendPeople: a person the host's family lacks may die there only by such a line
      E.pdMiss = E.pdMiss or {}
      for i = #E.pdMiss, 1, -1 do if clock - E.pdMiss[i].t > 300.0 then table.remove(E.pdMiss, i) end end
      E.pdMiss[#E.pdMiss + 1] = { t = clock, rk = q.rk, role = q.role, fam = tonumber(q.tok:match("^(%-?%d+)%.")), name = q.tok:match("^%-?%d+%.(.*)$") }
    end
  end
end

-- ---------------------------------------------------------------- corpses (lane 64)
-- A body on one copy only: after the live session's starvation both friends kept a body the host never had ("zwei
-- corpses 0/1" for days; nobody buries on a friend: its villagers choose no task by themselves), and one of them
-- stood by a hitching post, not to be hovered or selected (a dead unit the job board had still given the host's
-- task: coop_x_jobs.lua, "live"). The host's bodies are its word like everything else:
--   host -> friends   E PC <region> <bodies> <1 = the whole list | 0 = cut> <name>~<role>~<x>~<y>;...   ("-" = none)
--                     followed, on a complete list with known ages, by the host day and comma-separated corpse days
--                     E PZ <region>,<region>,...        regions with no body (with the keyframe, every 30 s)
--                     a region's line when its list changed (looked at every second and right after a death is told)
-- A friend compares each region's bodies with the host's, by role (names differ where each copy rolled them): where
-- it has MORE bodies of a role than the host, the surplus ones are taken out, those first whose name no body of the
-- host has: after CORPSE_AFTER s of standing difference, never while a death from the host still waits, never more
-- than CORPSE_MAX at one look, never from a cut list, with the engine's own destroyUnit (the game's own removal of a
-- unit; for a dead one it also leaves every region's corpse list: READ).
-- A body the host has and this copy lacks is NOT made: a body can only be made by making a person and letting him
-- die in sight; the two nets above (E PD, and the family rule of friendPeople) let the same person die here, and what
-- they miss is counted and logged ("c_missing").
-- (after the game runs) BURIAL is the host's too: a friend's villagers start no burial by themselves (coop_patch's
-- NODEATH site "bury"), so a body the host has buried is a body here that the host has not: it goes by this rule,
-- as soon as a complete list drops a body previously identified on both copies. An unexplained extra still waits.
local CORPSE_EVERY, CORPSE_AFTER, CORPSE_MAX = 1.0, 3.0, 3
local function corpseDaysAvailable()
  if E.corpseDaysReady == nil and RegisterCustomProperty and PropertyTypes and C.patch and C.patch.status().knownBuild then
    -- The 0.8.117 daily corpse loop reads this integer between SMUnit.dead and masterPtr.
    E.corpseDaysReady = pcall(RegisterCustomProperty, { Name = "MLCoopCorpseDays", Type = PropertyTypes.IntProperty,
        BelongsToClass = "/Script/ManorLords.SMUnit", OffsetInternal = 0x310 })
    if not E.corpseDaysReady then log("body age property could not be registered") end
  end
  return E.corpseDaysReady
end
local function corpsesOf(reg)
  local t, complete = {}, true
  local c = reg.corpses
  local readDays = #c > 0 and corpseDaysAvailable()
  for i = 1, #c do
    local raw = c[i]
    local u = ptrOk(raw) and un(raw) or nil
    if u and valid(u) then
      local e = { u = u, n = "", role = -1 }
      local ok = pcall(function() e.n = u.DisplayName:ToString(); e.role = math.floor(tonumber(u.assignedUnitRole) or -1) end)
      if not ok or e.role < 0 then complete = false end
      if readDays and u.dead then
        local d = u.MLCoopCorpseDays
        if type(d) == "number" and d >= 0 and d <= 30 then e.days = d end
      end
      e.x, e.y, e.z = placeOf(u)
      t[#t + 1] = e
    end
  end
  return t, complete and #t == #c
end
local function allRegions(S)
  local t = {}; local arr = S.eng.regions
  for i = 1, #arr do local r = un(arr[i]); if valid(r) then local k = rkey(r); if k then t[#t + 1] = { k = k, r = r } end end end
  return t
end
-- EUnitRole includes a bandit and None between the mule and the pig.
local function animalRole(role)
  return role and ((role >= 8 and role <= 16) or (role >= 19 and role <= 22))
end
-- THE OX (12). SMUnit:just_die on a working ox ends the copy within seconds, and the plain game does the same with
-- the mod not loaded (lane 2, sitting ox1: access violation reading 0xD88, the same frames as in an2, an3, an4).
-- READ: a villager is "reserved as ox guide" by a link to its ox (+330h, not reflected); just_die sets the ox's own
-- region (+328h) to 0 and leaves the guide's link; the guide's next idle tick (4E057F0 -> newTask_setGuideTask
-- 4E15AB0) takes a problem off that region: a read of 0 + D88h. The engine's destroyUnit clears every such link
-- (4CAD613). Measured in ox1: an ox that was made and killed in one call (it never lived a tick, no guide holds it)
-- and a working ox whose guide's link was cleared first both left a body and the copy ran on for 7 game days.
-- So a host's ox death is carried out here as: the engine's destroyUnit on this copy's living ox, then a new ox made
-- at its place and killed in the same call (oxDies). just_die is never called on an ox that has lived a tick.
-- THE HARE (20) is wild: no town's list holds it (Region.residents has none) and its own region is a region without
-- a town. Measured (ox2, rl5, px1): both copies have the same number of hares per region (104 in five regions), a
-- hare's reflected currentRegion is its own region (104 of 104), a host hare killed with just_die leaves its body on
-- that region's corpse list, and the game itself puts a new hare there within 15 to 46 s. A host hare death is
-- carried out on the nearest living hare of that region here (just_die: no link names a hare). The engine's
-- SpawnLivestock does make a hare (px1), so a body this copy lacks after a reload is made like any other.
-- DEER (8): the test save has no deer unit at all, so no deer death was measured; a deer is left alone.
local function wildRole(role) return role == 20 end
local function animalKillable(role) return animalRole(role) and role ~= 8 end
local function wildAnimals(S, reg, role)
  local list, units, ra = {}, S.eng.unitArr, addr(reg)
  for i = 1, #units do
    local raw = units[i]
    local u = ptrOk(raw) and un(raw) or nil
    if u and valid(u) and not u.dead and u.currentUnitRole == role then
      local cr = u.currentRegion
      if ptrOk(cr) and valid(cr) and addr(cr) == ra then list[#list + 1] = u end
    end
  end
  return list
end
-- The town's own list (Region.residents) is what the game counts its livestock by (measured: equal to
-- GetTotalLivestockCountOfType for six kinds on both copies). SMUnit.currentRegion is where the animal stands: an
-- animal the facts module made beside a building of another region was "elsewhere", stayed alive and kept its count.
local function livingAnimals(S, reg, role)
  local list, units = {}, reg.residents
  for i = 1, #units do
    local raw = units[i]
    local u = ptrOk(raw) and un(raw) or nil
    if u and valid(u) and not u.dead and u.currentUnitRole == role then list[#list + 1] = u end
  end
  return list
end
-- Announce an actual addition to a complete corpse list. An animal sold or run away leaves no body.
local function hostAnimalDeaths(S, R, list)
  local old, now, counts = E.animalBodies[R.k], {}, {}
  for _, e in ipairs(list) do
    if animalRole(e.role) and valid(e.u) then
      now[addr(e.u)] = true
      counts[e.role] = (counts[e.role] or 0) + 1
    end
  end
  if old then
    for _, e in ipairs(list) do
      if animalRole(e.role) and valid(e.u) and not old[addr(e.u)] and e.x then
        local entry = C.jobs and C.jobs.byAddr and C.jobs.byAddr[addr(e.u)]
        E.animalSerial = (E.animalSerial or 0) + 1
        A.send(string.format("E AD %d %s %d '%s %d %d %d,%d,%d %s", E.animalSerial, R.k, e.role,
            enc(e.n), #livingAnimals(S, R.r, e.role), counts[e.role], math.floor(e.x + 0.5),
            math.floor(e.y + 0.5), math.floor(e.z + 0.5), entry and entry.key or "-"))
        bump("animalSent")
      end
    end
  end
  E.animalBodies[R.k] = now
end
local function friendAnimalDeath(S, w)
  local serial, role, name = tonumber(w[5]), tonumber(w[7]), (w[8] or ""):match("^'(.*)$")
  local living, bodies = tonumber(w[9]), tonumber(w[10])
  local x, y, z = (w[11] or ""):match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
  if not serial or serial <= E.lastAnimalDeath or not animalKillable(role) or role ~= math.floor(role) or not name
      or not living or living < 0 or not bodies or bodies < 1 or not x or not valid(S.eng) then return end
  E.lastAnimalDeath = serial
  local reg = regionByKey(S, w[6])
  if not valid(reg) then return end
  local seen, complete = corpsesOf(reg)
  if not complete then return end
  local count = 0
  for _, e in ipairs(seen) do if e.role == role then count = count + 1 end end
  if count >= bodies then return end  -- a replay overlapping the save, or a death already carried in combat
  name, x, y, z = dec(name), tonumber(x), tonumber(y), tonumber(z)
  local wild = wildRole(role)
  local live = wild and wildAnimals(S, reg, role) or livingAnimals(S, reg, role)
  local victim, spawned
  if #live > living or (wild and #live > 0) then
    local best, distance, tied = -1, math.huge, false
    for _, u in ipairs(live) do
      if valid(u) then
        local key = C.jobs and C.jobs.byAddr and C.jobs.byAddr[addr(u)]
        local ux, uy = placeOf(u)
        local d = ux and (ux - x)^2 + (uy - y)^2 or math.huge
        local rank = (name ~= "" and u.DisplayName:ToString() == name) and 2 or 0
        if (key and key.key or "-") == (w[12] or "-") then rank = rank + 1 end   -- the same place on the job board, or none on both
        if rank > best or (rank == best and d < distance) then
          victim, best, distance, tied = u, rank, d, false
        elseif rank == best and d == distance then tied = true end
      end
    end
    -- Animals of one kind look alike and are not paired between the copies. When neither a name nor the job board
    -- singles out the host's animal, the nearest of its kind dies here: the count and the body follow the host
    -- within 3 s. Leaving it alive kept the herd one too many for 25 s and never gave the body.
    if valid(victim) and (tied or (best <= 1 and distance > 100^2)) then bump("animalNearest") end
  else
    -- No spare living animal here. Preserve the host's survivors and create only the missing body.
    -- (made and killed in the same call: an ox that lived a tick may have a guide, and its just_die ends the copy)
    pcall(function()
      victim = S.eng:SpawnLivestock(role, {X=x, Y=y, Z=z}, reg)
      if valid(victim) then victim:just_die() end
    end)
    spawned = true
    if valid(victim) and not victim.dead then pcall(function() S.eng:destroyUnit(victim) end); bump("animalFailed"); return end
  end
  if not valid(victim) or (victim.dead and not spawned) then bump("animalUnmatched"); log("animal death: %s role %d had no identified animal here", w[6], role); return end
  if role == 12 and not spawned then
    -- a living ox is never killed (see animalKillable): it is taken out with its guide's link, and its body is made
    local px, py, pz = placeOf(victim)
    if not px then bump("animalFailed"); return end
    local gone = pcall(function() S.eng:destroyUnit(victim) end)
    if not gone then bump("animalFailed"); log("animal death: %s: this copy's ox could not be taken out; nothing done", w[6]); return end
    victim, spawned = nil, true
    local made = pcall(function()
      victim = S.eng:SpawnLivestock(role, { X = px + 0.0, Y = py + 0.0, Z = pz + 0.0 }, reg)
      if valid(victim) then victim:just_die() end
    end)
    if not made or not valid(victim) or not victim.dead then
      if valid(victim) and not victim.dead then pcall(function() S.eng:destroyUnit(victim) end) end
      bump("animalFailed"); log("animal death: %s: the ox was taken out here, its body could not be made", w[6]); return
    end
    bump("oxReplaced")
  end
  local ok = victim.dead or pcall(function() victim:just_die() end)
  if not ok or not valid(victim) or not victim.dead then
    if spawned and valid(victim) and not victim.dead then S.eng:destroyUnit(victim) end
    bump("animalFailed"); return
  end
  if victim.DisplayName:ToString() ~= name then victim.DisplayName = name end
  bump("animalDied"); log("animal death: %s role %d died here on the host's word", w[6], role)
  -- (lane 76, task 76h) the facts module owns the town's animal count: it is told, so that it makes no animal in the
  -- moment before the host's count line follows the death
  pcall(function() local Fm = rawget(C, "facts"); if Fm and Fm.liveDied then Fm.liveDied(w[6], role) end end)
end
-- (lane 64, task 64d) AN ANIMAL GONE WITHOUT A BODY. An animal of a town that the game takes out without a death (a
-- sale, any destroyUnit of the game's own) leaves no body, so no E AD line: a friend lost it only by the facts
-- module's count rule, after cfg.liveSettle (25 s; a rival's town 5 s), longer than the owner's 3 s. Now the host
-- tells it at its next look (CORPSE_EVERY): an animal that was on the town's list (Region.residents) at the look before
-- and is no longer a unit of the engine at all (not in this tick's unit list, read by address only):
--   E AG <serial> <region> <role> '<name> <living of that kind now> <x>,<y>,<z> <job board key or ->
-- Not told: an animal that died (its body stays a unit: the E AD line is its word), one that only left the town's list
-- (it is still a unit), wild animals (hares, deer), the young (lamb 11, calf 22: whether the game grows them up by a
-- new unit was not read; each copy's own game grows its own), and an animal whose home building has left the game's
-- list too (a demolished or burnt house or pen: the host's DEMOLISH or fire word takes this copy's animals with it; an
-- extra one taken here would be one too many). A friend takes out the same animal the death rule would choose (the
-- host's name, then the job board's place, then the nearest of the kind) with the engine's destroyUnit (no body; for
-- an ox it clears the guide's link), only while it has more of that kind than the host has now.
local GONE_SKIP = { [11] = true, [22] = true }
-- (cost: the scan of a town's list read every unit's fields once a second: 0.68 ms a frame on the host of session
-- l64pin12. Now the town's own animal count (one call) is asked first and the list is read again only when that count
-- changed, or 10 s after the last read. An animal that left in the same second another came keeps the count: it is
-- told at the next full read, up to 10 s later, and a friend that already has no more than the host does nothing.)
local function hostAnimalsGone(S, R, U)
  local tot = nil; pcall(function() tot = R.r:getTotalLivestockCount() end)
  local clock = os.clock()
  if E.animalLive[R.k] and tot and tot == E.animalTot[R.k] and clock - (E.animalScanT[R.k] or -1e9) < 10.0 then return end
  E.animalTot[R.k] = tot; E.animalScanT[R.k] = clock
  local now = {}
  local res = R.r.residents; local n = #res
  for i = 1, n do
    local raw = res[i]; local u = ptrOk(raw) and un(raw) or nil
    if u and valid(u) and not u.dead then
      local role = tonumber(u.currentUnitRole)
      if animalKillable(role) and not wildRole(role) and not GONE_SKIP[role] then
        local a = addr(u)
        if a then
          local x, y, z = placeOf(u); local nm = ""; pcall(function() nm = u.DisplayName:ToString() end)
          local entry = C.jobs and C.jobs.byAddr and C.jobs.byAddr[a]
          local home = nil; pcall(function() local h = u.animalAssignedTo; if ptrOk(h) and valid(h) then home = addr(h) end end)
          now[a] = { role = role, n = nm, x = x, y = y, z = z, key = entry and entry.key or "-", home = home }
        end
      end
    end
  end
  local old = E.animalLive[R.k]
  E.animalLive[R.k] = now
  if not old then return end
  for a, e in pairs(old) do
    if not now[a] and e.x then
      if not U.set then
        U.set = {}
        local arr = S.eng.unitArr; local m = #arr
        for i = 1, m do local raw = arr[i]; local u = ptrOk(raw) and un(raw) or nil; local ua = u and addr(u); if ua then U.set[ua] = true end end
      end
      local homeGone = false
      if not U.set[a] and e.home then
        if not U.bset then
          U.bset = {}
          local arr = S.eng.buildingArr or {}; local m = #arr
          for i = 1, m do local raw = arr[i]; local b = ptrOk(raw) and un(raw) or nil; local ba = b and addr(b); if ba then U.bset[ba] = true end end
        end
        homeGone = not U.bset[e.home]
        if homeGone then bump("animalGoneWithHome"); log("animal gone: %s role %d left with its home building (demolished or burnt): not told", R.k, e.role) end
      end
      if not U.set[a] and not homeGone then
        local living = 0; for _, x in pairs(now) do if x.role == e.role then living = living + 1 end end
        E.goneSerial = (E.goneSerial or 0) + 1
        A.send(string.format("E AG %d %s %d '%s %d %d,%d,%d %s", E.goneSerial, R.k, e.role, enc(e.n), living,
            math.floor(e.x + 0.5), math.floor(e.y + 0.5), math.floor((e.z or 0) + 0.5), e.key))
        bump("animalGoneSent")
        log("animal gone: %s role %d left the town without a body (no longer a unit): told (%d of the kind left)", R.k, e.role, living)
      end
    end
  end
end
local function friendAnimalGone(S, w)
  local serial, role, name = tonumber(w[5]), tonumber(w[7]), (w[8] or ""):match("^'(.*)$")
  local living = tonumber(w[9])
  local x, y = (w[10] or ""):match("^(%-?%d+),(%-?%d+),%-?%d+$")
  if not serial or serial <= (E.lastAnimalGone or 0) or not animalKillable(role) or wildRole(role) or GONE_SKIP[role] or role ~= math.floor(role)
      or not name or not living or living < 0 or not x or not valid(S.eng) then return end
  E.lastAnimalGone = serial
  local reg = regionByKey(S, w[6]); if not valid(reg) then return end
  local live = livingAnimals(S, reg, role)
  if #live <= living then bump("animalGoneEqual"); return end   -- no more of the kind here than the host has now
  name, x, y = dec(name), tonumber(x), tonumber(y)
  local victim, best, distance = nil, -1, math.huge
  for _, u in ipairs(live) do
    if valid(u) then
      local key = C.jobs and C.jobs.byAddr and C.jobs.byAddr[addr(u)]
      local ux, uy = placeOf(u)
      local d = ux and (ux - x)^2 + (uy - y)^2 or math.huge
      local rank = 0; pcall(function() if name ~= "" and u.DisplayName:ToString() == name then rank = 2 end end)
      if (key and key.key or "-") == (w[11] or "-") then rank = rank + 1 end
      if rank > best or (rank == best and d < distance) then victim, best, distance = u, rank, d end
    end
  end
  if not valid(victim) then bump("animalGoneUnmatched"); log("animal gone: %s role %d had no animal to take out here", w[6], role); return end
  local ok, er = pcall(function() S.eng:destroyUnit(victim) end)
  if not ok then bump("animalGoneFailed"); log("animal gone: %s role %d: destroyUnit failed here (%s)", w[6], role, tostring(er)); return end
  bump("animalGone"); log("animal gone: %s role %d left the host's town without a body: taken out here (destroyUnit), %d of the kind left on the host", w[6], role, living)
  -- the facts module's count line may still show the host's count of before for a moment: no stand-in for 1.5 s
  pcall(function() local Fm = rawget(C, "facts"); if Fm and Fm.liveDied then Fm.liveDied(w[6], role) end end)
end
local function hostCorpses(S, clock)
  local key = clock - (E.tKeyC or -1e9) >= KEY; if key then E.tKeyC = clock end
  local none = {}
  local U = {}                                                -- (task 64d) this tick's unit addresses, read once when needed
  for _, R in ipairs(allRegions(S)) do
    local ok, list, complete = pcall(corpsesOf, R.r)
    if ok then
      if complete and E.on.vdeaths then
        hostAnimalDeaths(S, R, list)
        if E.on.animalGone then local okG, eG = pcall(hostAnimalsGone, S, R, U); if not okG then bump("animalGoneErr"); E.lastErr = "animal gone: " .. tostring(eG) end end
      end
      local parts, ages, hasAge, len, whole = {}, {}, false, 0, complete and 1 or 0
      for _, e in ipairs(list) do
        local p = string.format("%s~%d~%d~%d", enc(e.n), e.role, math.floor((e.x or 0) + 0.5), math.floor((e.y or 0) + 0.5))
        local age = tostring(e.days or "-")
        len = len + #p + #age + 2
        if len > 2800 then whole = 0; break end
        parts[#parts + 1] = p; ages[#ages + 1] = age
        if e.days then hasAge = true end
      end
      local sig = #list .. " " .. whole .. " " .. (#parts > 0 and table.concat(parts, ";") or "-")
      if whole == 1 and hasAge then sig = sig .. " " .. S.eng:getDaysTotal() .. " " .. table.concat(ages, ",") end
      if #list == 0 and complete then none[#none + 1] = R.k end
      if sig ~= E.sentC[R.k] or (key and #list > 0) then
        if E.sentC[R.k] ~= nil or #list > 0 then                  -- (a region that never had a body is in the keyframe's PZ line)
          if sig ~= E.sentC[R.k] then bump("c_sent") end
          A.send("E PC " .. R.k .. " " .. sig)
        end
        E.sentC[R.k] = sig
      end
    end
  end
  if key and #none > 0 then
    local i = 1
    repeat local part = {}; local len = 0
      while i <= #none and len < 2800 do part[#part + 1] = none[i]; len = len + #none[i] + 1; i = i + 1 end
      A.send("E PZ " .. table.concat(part, ","))
    until i > #none
  end
end
-- (lane 64, for 0.2.6) An animal's body the host has and this copy lacks. Measured: a friend's reload brings no
-- animal body back (the host had 2, the reloaded friend 0), and a death line can find no animal to kill. The body is
-- made the way the death line makes it: the engine's own SpawnLivestock at the host's place, then the game's own
-- just_die. The host's list has no height: the nearest unit's height stands in for the ground.
local BODY_MAX = 12
local function makeAnimalBody(S, reg, role, h)
  local z, best = nil, math.huge
  local units = S.eng.unitArr
  for i = 1, #units do
    local u = un(units[i])
    if valid(u) then
      local ux, uy, uz = placeOf(u)
      if ux then local d = (ux - h.x)^2 + (uy - h.y)^2; if d < best then best, z = d, uz end end
    end
  end
  if not z then return false end
  local u
  local ok = pcall(function()
    u = S.eng:SpawnLivestock(role, { X = h.x + 0.0, Y = h.y + 0.0, Z = z + 0.0 }, reg)
    if valid(u) then u:just_die() end
  end)
  if not ok or not valid(u) or not u.dead then
    if valid(u) and not u.dead then pcall(function() S.eng:destroyUnit(u) end) end
    bump("animalBodyFailed"); return false
  end
  pcall(function() if h.n ~= "" and u.DisplayName:ToString() ~= h.n then u.DisplayName = h.n end end)
  -- the host's age of the body, so that the game's own age rule takes it away on the host's day (as for people)
  if h.days and corpseDaysAvailable() then pcall(function() u.MLCoopCorpseDays = h.days end) end
  bump("animalBodyMade"); log("corpses: the host has the body of an animal (role %d) at %d,%d that this copy lacks: made here", role, math.floor(h.x / 100), math.floor(h.y / 100))
  return true
end
local function friendCorpses(S, clock)
  if S.replay then return end
  local waiting = next(E.pdQ) ~= nil
  local taken = 0
  -- (lane 64, task 64d; research/.../lane_s21_64/design_deathregion.txt) every region's bodies first, and for each role
  -- and name the host's bodies that no body of this copy pairs with in THEIR region. A person's body here that the
  -- host has not in this region but has unpaired in another one is the same person lying elsewhere (a fight across a
  -- border: l64pin20, sel and wald): it is not taken out, as many of them as the host has unpaired. Taken out, a
  -- person's body is never made again here (only an animal's is), and the units count stays short for as long as the
  -- host's body lies (lane 83's run A fits that: unproven). A body the host removed goes as before; a true extra goes
  -- as before; a kept one goes by the rule as before once the host's pair is gone.
  local regions, pre, elsewhere = allRegions(S), {}, {}
  if E.on.corpseElsewhere ~= false then
    for _, R in ipairs(regions) do
      local okP, listP, completeP = pcall(corpsesOf, R.r)
      pre[R.k] = { ok = okP, list = listP, complete = completeP }
      local H = E.hostC[R.k]
      if okP and completeP and H and H.whole then
        local hk, lk = {}, {}
        for _, h in ipairs(H.list) do local k = h.role .. "~" .. h.n; hk[k] = (hk[k] or 0) + 1 end
        for _, e in ipairs(listP) do local k = e.role .. "~" .. e.n; lk[k] = (lk[k] or 0) + 1 end
        for k, n in pairs(hk) do local d = n - (lk[k] or 0); if d > 0 then elsewhere[k] = (elsewhere[k] or 0) + d end end
      end
    end
  end
  for _, R in ipairs(regions) do
    local H = E.hostC[R.k]
    local P0 = pre[R.k]
    local ok, list, complete
    if P0 then ok, list, complete = P0.ok, P0.list, P0.complete else ok, list, complete = pcall(corpsesOf, R.r) end
    if H and ok then
      -- per role: the host's count and names; this copy's bodies
      local hostN, hostNames, hostDays, mine, localNames = {}, {}, {}, {}, {}
      for _, h in ipairs(H.list) do
        local k = h.role .. "~" .. h.n
        hostN[h.role] = (hostN[h.role] or 0) + 1; hostNames[k] = (hostNames[k] or 0) + 1; hostDays[k] = h.days
      end
      for _, e in ipairs(list) do
        e.key = e.role .. "~" .. e.n
        localNames[e.key] = (localNames[e.key] or 0) + 1
        mine[e.role] = mine[e.role] or {}; table.insert(mine[e.role], e)
      end
      local st = E.cState[R.k] or {}; E.cState[R.k] = st
      local sameDay = H.day and H.day == S.eng:getDaysTotal()
      if not sameDay or st.ageDay ~= H.day or not st.ageSince then st.ageSince = {}; st.ageDay = H.day end
      local seen = {}
      for _, e in ipairs(list) do
        if complete and H.whole and e.n ~= "" and localNames[e.key] == 1 and valid(e.u) then
          local a = addr(e.u)
          if hostNames[e.key] == 1 then
            seen[e.key] = a
            local target = hostDays[e.key]
            if sameDay and e.days and target and C.facts and C.facts.dayRule and
                C.facts.dayRule(st.ageSince, e.key, target - e.days, clock, A.isPaused()) and valid(e.u) and e.u.dead then
              e.u.MLCoopCorpseDays = target; bump("c_ageSet")
            end
          elseif not hostNames[e.key] and a and st.seen and st.seen[e.key] == a then
            e.hostRemoved = true; seen[e.key] = a
          end
        end
      end
      st.seen = seen
      local surplus, missing = {}, 0
      for role, L in pairs(mine) do
        local over = #L - (hostN[role] or 0)
        for _, e in ipairs(L) do
          if over > 0 and e.hostRemoved then surplus[#surplus + 1] = e; over = over - 1 end
        end
        if over > 0 then
          -- which ones: first those whose name no body of the host has (each host name pairs with one body here)
          local names = {}; for k2, n2 in pairs(hostNames) do names[k2] = n2 end
          local unnamed, named = {}, {}
          for _, e in ipairs(L) do
            if not e.hostRemoved then
              if (names[e.key] or 0) > 0 then names[e.key] = names[e.key] - 1; named[#named + 1] = e
              else unnamed[#unnamed + 1] = e end
            end
          end
          for _, e in ipairs(unnamed) do if over > 0 then surplus[#surplus + 1] = e; over = over - 1 end end
          for i = #named, 1, -1 do if over > 0 then surplus[#surplus + 1] = named[i]; over = over - 1 end end
        end
      end
      for role, n in pairs(hostN) do local have = mine[role] and #mine[role] or 0; if n > have then missing = missing + (n - have) end end
      -- (an6) a body this copy's own game has just taken away (its age, at this copy's day turn) is not made again: the
      -- host's list still had it for 0.7 s, the body was made anew and stood here 3.5 s longer than on the host
      st.have = st.have or {}; st.lost = st.lost or {}
      for role, n in pairs(st.have) do if (mine[role] and #mine[role] or 0) < n then st.lost[role] = clock end end
      st.have = {}; for role, L in pairs(mine) do st.have[role] = #L end
      -- a body the host has and this copy lacks: counted and logged once per standing difference, after 15 s
      if missing > 0 and not waiting then
        st.missT = st.missT or clock
        if clock - st.missT >= 15.0 and st.missSaid ~= missing then
          st.missSaid = missing; bump("c_missing", missing)
          log("corpses: %s has %d body(ies) on the host that this copy lacks: not made here (the person lives here or was never here; see the report of lane 64)", R.k, missing)
        end
      else st.missT = nil; if missing == 0 then st.missSaid = nil end end
      if missing > 0 and st.missT and clock - st.missT < 0.4 then E.tCorpseF = clock - CORPSE_EVERY + 0.45 end   -- look again as soon as the wait is over
      if missing > 0 and not waiting and complete and H.whole and E.on.vdeaths and not C.hold and st.missT
          and clock - st.missT >= 0.4 and clock - (S.worldT or 0) >= 1.0 and clock - (st.bodyTry or -1e9) >= 5.0 then   -- (an5: with 1.0 and 3.0 the bodies were back 3.3 s after a reload)
        -- (ox2: six animal bodies after a reload came three at 1.2 s and three at 6.7 s: at most CORPSE_MAX were made at
        --  one look and the next look waited 5 s. Up to BODY_MAX are made at one look; the 5 s wait follows a failure only.)
        local tried, madeN = 0, 0
        for role, n in pairs(hostN) do
          local have = mine[role] and #mine[role] or 0
          if animalKillable(role) and n > have and clock - (st.lost[role] or -1e9) >= 2.5 then
            local names, lack = {}, {}
            for _, e in ipairs(mine[role] or {}) do names[e.n] = (names[e.n] or 0) + 1 end
            for _, h in ipairs(H.list) do
              if h.role == role then
                if (names[h.n] or 0) > 0 then names[h.n] = names[h.n] - 1 else lack[#lack + 1] = h end
              end
            end
            for i = 1, math.min(#lack, n - have) do
              if tried < BODY_MAX and lack[i].x and lack[i].y then
                tried = tried + 1
                if makeAnimalBody(S, R.r, role, lack[i]) then taken = taken + 1; madeN = madeN + 1 end
              end
            end
          end
        end
        if tried > 0 then st.bodyTry = madeN == tried and (clock - 4.5) or clock; st.missT = nil end
      end
      -- bodies here that the host has not
      -- (lane 64, task 64d) a person's body the host has unpaired in another region stays (see the head of this function)
      if #surplus > 0 and E.on.corpseElsewhere ~= false then
        local rest = {}
        for _, e in ipairs(surplus) do
          if not e.hostRemoved and not animalKillable(e.role) and (elsewhere[e.key] or 0) > 0 then
            elsewhere[e.key] = elsewhere[e.key] - 1; bump("c_elsewhere")
            E.elseSaid = (E.elseSaid or 0) + 1
            if E.elseSaid <= 10 then log("corpses: %s: the body of %s (role %d) at %d,%d is not on the host's list of this region, and the host has one of that role and name unpaired in another region: kept (the same person lying elsewhere)", R.k, e.n ~= "" and e.n or "?", e.role, math.floor((e.x or 0) / 100), math.floor((e.y or 0) / 100)) end
          else rest[#rest + 1] = e end
        end
        surplus = rest
      end
      if #surplus > 0 and complete and H.whole and not waiting and E.on.corpseRemove then
        local sig = #surplus .. "/" .. #list .. "/" .. #H.list
        if st.sig ~= sig then st.sig = sig; st.t = clock end
        local settled = clock - (S.worldT or 0) >= 10.0 and clock - st.t >= CORPSE_AFTER and clock - H.t >= 0.5
        local removed = 0
        for _, e in ipairs(surplus) do
          if removed < CORPSE_MAX and (e.hostRemoved or (settled and #surplus <= CORPSE_MAX)) then
            local isDead = false; pcall(function() isDead = valid(e.u) and e.u.dead == true end)
            if isDead then
              local okD, er = pcall(function() S.eng:destroyUnit(e.u) end)
              removed = removed + 1
              taken = taken + 1; bump(okD and "c_removed" or "c_removeFail")
              log("corpses: %s: the body of %s (role %d) at %d,%d is on this copy only (%.0f s): %s", R.k, e.n ~= "" and e.n or "?", e.role, math.floor((e.x or 0) / 100), math.floor((e.y or 0) / 100), clock - st.t,
                okD and "taken out (the engine's own destroyUnit)" or ("NOT taken out: " .. tostring(er)))
            else bump("c_notDead") end
          end
        end
        if removed > 0 then st.sig = nil
        elseif settled and #surplus > CORPSE_MAX and st.tooMany ~= sig then
          st.tooMany = sig; bump("c_tooMany"); log("corpses: %s has %d bodies more than the host (%d here, %d there): more than %d at one look, none is taken out", R.k, #surplus, #list, #H.list, CORPSE_MAX)
        end
      else st.sig = nil end
    end
  end
  if taken > 0 then E.tCorpseF = clock - CORPSE_EVERY + 1.0 end
end

-- ---------------------------------------------------------------- units nobody knows (lane 64)
-- The live session's "ghost": a person drawn on a friend's copy who cannot be hovered or selected. READ in the game:
-- the lord's hover (PawnCPP.hoverUnit, 4b34880..) takes its unit from the engine's unit list (unitArr) or from the
-- engine's place index; a dead unit is a body, not a person, to the panels. So this copy's units are counted by what
-- the lists say about them, on a friend once a minute (logged when the numbers change) and from the test console
-- (Coop.events.census(S, true) returns the lines):
--   dead units on the unit list that no region's corpse list holds   ("dead, on no list": a body the game forgot)
--   dead units that stand (their speed and place say nothing; their count is the corpse lists' sum: see "corpses")
--   villagers (a family number, human) that their family's member list does not hold, alive ("of no family")
--   SMUnit objects alive in memory that the unit list does not hold ("off the unit list"; with the console only:
--   FindAllOf walks every object)
-- Nothing is removed here: the one class the live session showed (a dead unit standing) is a body the host has not,
-- and "corpses" above takes it out; the other classes were never seen, and this count is what will show them.
local function census(S, deep)
  local out = { dead = 0, deadNoList = 0, noFamily = 0, units = 0, corpses = 0, off = 0, lines = {} }
  local function note(s) if #out.lines < 12 then out.lines[#out.lines + 1] = s end end
  local function desc(u)
    local n, role, fam, x, y = "?", -1, -1, nil, nil
    pcall(function() n = u.DisplayName:ToString(); role = math.floor(tonumber(u.assignedUnitRole) or -1); fam = math.floor(tonumber(u.workerFamilyID) or -1) end)
    x, y = placeOf(u)
    return string.format("%s role %d family %d at %d,%d m", n ~= "" and n or "?", role, fam, math.floor((x or 0) / 100), math.floor((y or 0) / 100))
  end
  local inCorpses, member, regOf = {}, {}, {}
  for _, R in ipairs(allRegions(S)) do
    pcall(function()
      local c = R.r.corpses
      for i = 1, #c do local raw = c[i]; local u = ptrOk(raw) and un(raw) or nil; if u and valid(u) then inCorpses[addr(u)] = true; out.corpses = out.corpses + 1 end end
    end)
    pcall(function()
      local fams = R.r.workerFamilies
      for f = 1, #fams do
        local m = fams[f].familyMembers
        for j = 1, #m do local raw = m[j]; local u = ptrOk(raw) and un(raw) or nil; if u and valid(u) then member[addr(u)] = true end end
      end
    end)
    regOf[addr(R.r)] = R.k
  end
  local onList = {}
  local arr = S.eng.unitArr
  for i = 1, #arr do
    local raw = arr[i]
    local u = ptrOk(raw) and un(raw) or nil
    if u and valid(u) then
      local a = addr(u); onList[a] = true; out.units = out.units + 1
      local dead, human, fam = false, false, -1
      pcall(function() dead = u.dead == true; fam = math.floor(tonumber(u.workerFamilyID) or -1) end)
      if dead then
        out.dead = out.dead + 1
        if not inCorpses[a] then out.deadNoList = out.deadNoList + 1; note("dead, on no corpse list: " .. desc(u)) end
      elseif fam >= 0 and not member[a] then
        pcall(function() human = u:isHumanCivilian(false) == true end)
        if human then out.noFamily = out.noFamily + 1; note("alive, of no family's list: " .. desc(u)) end
      end
    end
  end
  if deep then
    pcall(function()
      for _, u in ipairs(FindAllOf("SMUnit") or {}) do
        if valid(u) and not onList[addr(u)] then
          local name = ""; pcall(function() name = u:GetFullName() end)
          if not name:find("Default__", 1, true) then out.off = out.off + 1; note("off the unit list: " .. desc(u)) end
        end
      end
    end)
  end
  out.sig = string.format("%d units, %d dead (%d on no corpse list), %d bodies on the regions' lists, %d villagers of no family%s", out.units, out.dead, out.deadNoList, out.corpses, out.noFamily,
    deep and string.format(", %d off the unit list", out.off) or "")
  return out
end
function E.census(S, deep)
  S = S or C.s
  local ok, r = pcall(census, S, deep)
  if not ok then return "census failed: " .. tostring(r) end
  return r.sig .. (#r.lines > 0 and ("\n" .. table.concat(r.lines, "\n")) or "")
end
local function friendCensus(S, clock)
  local ok, r = pcall(census, S, false)
  if not ok then if E.lastErr ~= "census: " .. tostring(r) then E.lastErr = "census: " .. tostring(r); log("%s", E.lastErr); bump("err") end; return end
  local odd = r.deadNoList + r.noFamily
  local sig = r.deadNoList .. "/" .. r.noFamily
  if sig ~= E.censusSig then
    E.censusSig = sig
    if odd > 0 or E.censusOdd then
      log("units: %s", r.sig); for _, l in ipairs(r.lines) do log("units:   %s", l) end
      bump("u_odd")
    end
    E.censusOdd = odd > 0
  end
end

-- ---------------------------------------------------------------- bandit thefts (lane 66)
-- What the game does (lane 66, static read of the game file with dumpbin; rvas of this build, exe 560451df):
--   The raids-and-camps job (4d63380, queued once a game day by updateDay) ends with a jump into the theft routine
--   (4d64460). That routine acts only on the theft day: daysTotal > 90, an even month, and
--   dayOfTheMonth == ((30 // month + month - 1) % 29) + 1 (the debug flag "overdriveStealing" skips the date test,
--   "stealing" only logs). Then, for every bandit squad that is ENCAMPED (Control 4, its camp set), it finds the
--   nearest settled region of any lord but the off-map one, picks one random good the region holds (rand), takes
--   min(stock, 3 + 0..12) of it with Region::consumeGood(good, n, none, true, true, true), ADDS it to the camp's
--   Inventory (the loot a player gets back by looting the camp) and, only when consumeGood said yes, gives the
--   region's lord the notice PawnCPP:addLog("theft", "goods_stolen+(+<n> <img id="ItemID_<good>"></> +)",
--   "goods_stolen_descr", 0, <camp's place>, none): the banner. The call is native, so no hook sees it.
-- In co-op every copy reached that day with its own encamped squads and rolled its own good: the banner on every copy,
-- each copy taking from its own stock; a friend's stock and its camps' loot are then put back to the host's (facts
-- module, exact mode, item camps). Rule now: the theft happens only on the host, by the game's own code. A friend's
-- copy never rolls one (coop_patch item NT, NOTHEFT: the routine's walk over the squads is jumped over). The host
-- sees a theft as a camp whose loot grew on its theft day and tells it (E T); the stock and the loot reach the friend
-- through the facts module as before; the notice "theft" reaches a friend by the realm module's R LOG.
local THEFT_EVERY = 0.5
local function invOf(b)
  local m = {}; local inv = b.Inventory; local n = #inv
  for j = 1, n do
    local x = inv[j]; local t, a = x.Type, x.amt
    if type(t) ~= "number" then x = un(x); t, a = x.Type, x.amt end
    if type(t) == "number" and type(a) == "number" and a ~= 0 then m[t] = (m[t] or 0) + a end
  end
  return m
end
-- the game's theft day, read from the calendar as the theft routine does; also true while "overdriveStealing" is set
local function theftDay(S)
  local T = S.eng.TemporalComponent
  local total, month, dom = tonumber(S.eng:getDaysTotal()), tonumber(T.month), tonumber(T.dayOfTheMonth)
  local over = false
  pcall(function() local f = S.eng.drawDebugFlags; local n = #f; for i = 1, n do if un(f[i]):ToString() == "overdriveStealing" then over = true end end end)
  local want = (month and month > 0) and ((math.floor(30 / month) + month - 1) % 29) + 1 or -1
  local day = total and month and dom and total > 90 and month % 2 == 0 and dom == want
  return (day or over) and true or false, over, total, month, dom, want
end
-- the region the theft routine would rob for a camp at (x, y): the nearest settled region with a lord who is not the
-- off-map one (the routine's further test, a count above 1 in an unreflected list, is not checked here)
local function victimOf(S, x, y)
  local best, bd
  local arr = S.eng.regions; local n = #arr
  for i = 1, n do
    local r = un(arr[i])
    if valid(r) then
      pcall(function()
        if not r.isSettled then return end
        local o = r.ownerPawn; if not valid(o) then return end
        -- the lord's traits on their own: a failed read does not drop the region (the off-map lord holds no settled town)
        local off = false
        pcall(function() local tr = o.traits; local tn = #tr; for j = 1, tn do if un(tr[j]):ToString() == "off_map_lord" then off = true end end end)
        if off then return end
        local l = r:K2_GetActorLocation(); local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2
        if not bd or d < bd then bd = d; best = r end
      end)
    end
  end
  if best then return ownerCode(S, best.ownerPawn), rkey(best) or "-" end
  return "-", "-"
end
local function noTheft()
  local P = rawget(C, "patch")
  if P and type(P.noTheft) == "function" then local ok, s = pcall(P.noTheft); if ok then return s end end
  return "missing"
end
local function logLen(S) local ok, n = pcall(function() return #S.p1.log end); return ok and n or -1 end

-- one look at the camps' loot (every 0.5 s, on the handles of the last camp list)
local function theftTick(S, clock, host)
  local map = E.campMap; if not map then return end
  -- once a game day: say when it is the theft day, and (host) what was seen on the last one
  -- (the calendar and the debug flags are read once a game day; the theft runs in the day's queued job, after the change)
  local okT, today = pcall(function() return tonumber(S.eng:getDaysTotal()) end)
  if okT and today and today ~= (E.theftDay and E.theftDay.total) then
    local okD, isDay, over, total, month, dom = pcall(theftDay, S)
    if not okD then isDay, total = false, today end
    local last = E.theftDay
    if host and last and last.is then log("thefts: theft day %d over: %d theft(s) seen on the host", last.total, last.n) end
    E.theftDay = { total = total, is = isDay, n = 0 }
    if isDay then
      local enc = 0
      for _, c in pairs(map) do if valid(c.b) then enc = enc + 1 end end
      log("thefts: day %d (month %s, day %s of the month%s) is the game's theft day; %d camp(s) here; %s", total, tostring(month), tostring(dom),
        over and ", overdriveStealing is set" or "", enc, host and "the host's game takes the goods" or ("this copy's own theft: NOTHEFT " .. noTheft()))
    end
  end
  for k, c in pairs(map) do
    if valid(c.b) then
      local okI, now = pcall(invOf, c.b)
      if okI then
        local old = E.loot[k]; E.loot[k] = now
        if old then
          for g, a in pairs(now) do
            local d = a - (old[g] or 0)
            if d > 0 then
              if host then
                local okV, vc, vr = pcall(function() local l = c.b:K2_GetActorLocation(); return victimOf(S, l.X, l.Y) end)
                if not okV then vc, vr = "?", "-" end
                if E.theftDay and E.theftDay.is then
                  E.theftN = E.theftN + 1; if E.theftDay then E.theftDay.n = E.theftDay.n + 1 end
                  A.send(string.format("E T %d %s %d %d %s %s", E.theftN, k, g, d, vc, vr)); bump("t_sent")
                  -- the region's stock of that good now (Region:getStockOfGood), so the log shows the loss, not only the camp's gain
                  local left = "?"
                  pcall(function() local r = regionByKey(S, vr); if valid(r) then left = tostring(r:getStockOfGood(g, false, false)) end end)
                  log("thefts: bandits of camp %s stole %d of good %d from region %s (lord %s) on the host: told (the region holds %s of it now; the lord's log has %d entries)", k, d, g, vr, vc, left, logLen(S))
                else
                  bump("t_offDay"); log("thefts: camp %s gained %d of good %d on the host outside a theft day: not told as a theft", k, d, g)
                end
              else
                -- a friend: the host's word (E T) for this camp and good, before or within 10 s after, makes it the host's
                local wk = k .. "|" .. g
                local w = E.theftWant[wk]
                if w and w.left > 0 then w.left = w.left - d; if w.left <= 0 then E.theftWant[wk] = nil end
                else E.ownGrow[wk] = { t = clock, d = d, day = E.theftDay and E.theftDay.is } end
              end
            end
          end
        end
      end
    end
  end
  if not host then
    for wk, o in pairs(E.ownGrow) do
      local w = E.theftWant[wk]
      if w and w.left > 0 then E.ownGrow[wk] = nil; w.left = w.left - o.d; if w.left <= 0 then E.theftWant[wk] = nil end
      elseif clock - o.t > 10.0 and not o.day then
        E.ownGrow[wk] = nil; bump("t_otherGrow")       -- not a theft day (the facts module catching up after a load): not a theft
      elseif clock - o.t > 10.0 then
        E.ownGrow[wk] = nil; bump("t_ownHere")
        log("thefts: camp %s gained %d of good %s HERE without the host's word (%s; NOTHEFT %s)", wk:match("^(.-)|") or wk, o.d, wk:match("|(.*)$") or "?",
          o.day and "on the theft day: a theft of this copy's own" or "not a theft day", noTheft())
      end
    end
    for wk, w in pairs(E.theftWant) do if clock - w.t > 30.0 then E.theftWant[wk] = nil end end
  end
end

-- friend: the host's theft. The stock and the camp's loot come through the facts module; here the notice, once.
local function friendTheft(S, w)
  local serial, k, g, d, vc, vr = tonumber(w[5]), w[6], tonumber(w[7]), tonumber(w[8]), w[9], w[10]
  if not (serial and k and g and d) then bump("t_badLine"); return end
  if E.theftSeen[serial] then return end
  E.theftSeen[serial] = true; bump("t_heard")
  local wk = k .. "|" .. g
  local cur = E.theftWant[wk]; E.theftWant[wk] = { t = os.clock(), left = (cur and cur.left or 0) + d }
  -- (lane 66, part two) the notice itself ("theft") comes like every other notice by the realm module's R LOG, the one
  -- source of notices on a friend; this line only names the theft for the log and the loot watch above
  log("thefts: the host's bandits of camp %s stole %d of good %d from region %s (lord %s): its notice comes by R LOG; stock and loot by the facts module (NOTHEFT %s)", k, d, g, tostring(vr), tostring(vc), noTheft())
end

-- ---------------------------------------------------------------- development console
-- Two copies on one PC are started with COOP_X_DEV=1 (tools/dev): a file <link>/<name>_x.lua is then run inside the
-- mod's own Lua state and its result written to <name>_x_out.txt (hot reload of this file, switches, status). Without
-- that variable this does nothing.
local DEV = false   -- the development console is not part of shipped code any more (lead, 2026-11-11): test builds use coop_dev.lua
local function devTick(S, clock)
  if not DEV or clock - (E.devT or 0) < 0.2 then return end
  E.devT = clock
  local dir = rawget(_G, "COOP_LINK_DIR"); if not dir then return end
  local path = dir .. S.name .. "_x.lua"
  local f = io.open(path, "r"); if not f then return end
  local src = f:read("a"); f:close(); os.remove(path)
  local chunk, err = load(src, "x", "t")
  local ok, res; if chunk then ok, res = pcall(chunk) else ok, res = false, err end
  local o = io.open(dir .. S.name .. "_x_out.tmp", "w")
  if o then o:write((ok and "OK: " or "ERR: ") .. tostring(res) .. "\n"); o:close(); os.remove(dir .. S.name .. "_x_out.txt"); os.rename(dir .. S.name .. "_x_out.tmp", dir .. S.name .. "_x_out.txt") end
end

-- ---------------------------------------------------------------- plug-in
local function guarded(what, fn, ...)
  local ok, e = pcall(fn, ...)
  if not ok and E.lastErr ~= what .. ": " .. tostring(e) then E.lastErr = what .. ": " .. tostring(e); log("%s", E.lastErr); bump("err") end
end

local M = {}
function M.onWorld(S) fresh(S) end
function M.tick(S, clock)
  fresh(S)
  pcall(devTick, S, clock)
  if rawget(C, "hold") or not valid(S.p1) or not valid(S.eng) then return end
  if S.role ~= "host" and S.role ~= "friend" then return end
  local host = S.role == "host"
  if E.on.answers then ensureHooks() end
  if E.on.camps then
    -- The host, four times a second: when the number of buildings or of independent buildings (the list the camps
    -- stand in) has changed, the camps are read now, so that a friend hears of a camp that went within a second and
    -- not after up to 3 s. (Asking the camp object itself is no use: a camp that has left the list stays a living
    -- object for some time. Measured with such a look: the host's word came 2.6 s after the camp had left the list.)
    if host and not E.scan and clock - (E.tQuick or 0) >= 0.25 then
      E.tQuick = clock
      local okN, sig = pcall(function() return #S.eng.buildingArr .. "/" .. #S.eng.independentBuildings end)
      if okN and sig ~= E.listSig then if E.listSig then E.tCamp = -1e9 end; E.listSig = sig end
    end
    if E.scan then guarded("camps", campScan, S)
    elseif clock - E.tCamp >= CAMP_EVERY then
      E.tCamp = clock
      guarded("camps", campScan, S, function(map) E.campMap = map; if host then hostCamps(S, os.clock(), map) else friendCamps(S, os.clock(), map) end end)
    end
  end
  if E.on.thefts and E.on.camps and clock - (E.tTheft or 0) >= THEFT_EVERY then E.tTheft = clock; guarded("thefts", theftTick, S, clock, host) end
  if E.on.owners and clock - E.tOwner >= OWNER_EVERY then
    E.tOwner = clock
    guarded("owners", host and hostOwners or friendOwners, S, clock)
  end
  if E.on.people then
    if E.pscan then guarded("people", peopleScan, S)
    elseif clock - E.tPeople >= (host and 3.0 or PEOPLE_EVERY) then   -- the host looks every 3 s, a friend every 5 s and after each line
      E.tPeople = clock
      guarded("people", peopleScan, S, function(out, own) if host then hostPeople(S, os.clock(), out) else friendPeople(S, os.clock(), out, own) end end)
    end
  end
  -- (lane 64) a friend: every family lives where it lives on the host, looked at once a second
  if not host and E.on.homes and clock - (E.tHomes or 0) >= HOMES_EVERY then
    E.tHomes = clock
    guarded("homes", friendHomes, S, clock)
  end
  -- (lane 64, game run s2) the game's hunger and cold step kills inside its day routine: the host looks in the tick
  -- after its day changed, not up to a second later. Measured before this: told 0.05 to 0.07 s -> dead on the friend,
  -- but the host's look came up to 1 s after the death, and on 2 of 33 days the friend's daily sample was taken in
  -- between ("population 57/58", "corpses 3/2" for that one sample).
  if host and E.on.vdeaths then
    local okD, d = pcall(function() return S.eng:getDaysTotal() end)
    if okD and d ~= E.vDay then E.vDay = d; E.tVill = -1e9 end
  end
  if E.on.vdeaths and clock - E.tVill >= 1.0 then E.tVill = clock; guarded("villagers", host and hostVillagers or friendVillagers, S, clock) end
  -- lane 64: the bodies (the host tells its lists; a friend takes out a body the host has not), and a friend's count
  -- of units nobody knows
  if E.on.corpses then
    if not host and not E.askedCorpses then A.send("E CASK"); E.askedCorpses = true end
    if host then if clock - (E.tCorpse or 0) >= CORPSE_EVERY then E.tCorpse = clock; guarded("corpses", hostCorpses, S, clock) end
    elseif clock - (E.tCorpseF or 0) >= CORPSE_EVERY then E.tCorpseF = clock; guarded("corpses", friendCorpses, S, clock) end
  end
  if not host and E.on.census and clock - (E.tCensus or 0) >= 60.0 then E.tCensus = clock; friendCensus(S, clock) end
  if clock - E.tPoll < (host and POLL_HOST or POLL) then return end
  E.tPoll = clock
  if E.on.quests then guarded("quests", host and hostQuests or friendQuests, S, clock) end
end
function M.idle(S, clock) pcall(devTick, S, clock) end
function M.onMessage(S, from, kind, w, line)
  if kind ~= "E" then return false end
  fresh(S)
  if S.role == "friend" and from == "host" then
    local sub = w[4]
    if sub == "Q" then
      local H = {}
      local dayParts = {}; for p in ((w[8] or "") .. "|"):gmatch("([^|]*)|") do dayParts[#dayParts + 1] = p end   -- (lane 83)
      for i, l in ipairs(LISTS) do
        local items = {}; local s = w[4 + i] or "-"
        if s ~= "-" then for n, r in s:gmatch("([^,:]+):([^,]*)") do items[#items + 1] = { n = dec(n), r = r ~= "" and r or nil } end end
        local dl = {}; for d in (dayParts[i] or ""):gmatch("[^,]+") do dl[#dl + 1] = tonumber(d) or false end
        if #dl == #items then for k, it in ipairs(items) do it.d = dl[k] or nil end end
        H[l] = items
      end
      E.hostQ = H
      -- (lane 88) a changed list from the host is looked at in this copy's next tick, not up to 1 s later
      local qline = table.concat({ w[5] or "-", w[6] or "-", w[7] or "-" }, " ")
      if qline ~= E.hostQline then E.hostQline = qline; E.tPoll = -1e9 end
    elseif sub == "DID" then
      local ok, e = pcall(friendDid, S, w); if not ok then log("answer from the host failed: %s", tostring(e)) end
    elseif sub == "POP" then
      if E.on.popups then local ok, e = pcall(friendPopup, S, w); if not ok then log("event window from the host failed here: %s", tostring(e)) end end
    elseif sub == "NOTGIVEN" then
      -- (lane 66) this player's answer did not count on the host (another player answered that offer first)
      if w[5] == S.name then
        local a = dec(w[7] or ""); bump("q_notGiven")
        log("this player's answer (%s %s) was NOT counted on the host: the offer was already answered there", VERB[w[6]] or tostring(w[6]), a)
        if C.notify then pcall(C.notify, "info", "Co-op: another player answered that offer first; the host's answer counts") end
      end
    elseif sub == "K" then
      -- only a list in which every entry is a whole camp name is taken (session 2: a list cut at the commas inside
      -- the names made a friend's copy demolish its two real camps)
      local H, good = {}, true
      if w[5] and w[5] ~= "-" then
        for e in w[5]:gmatch("[^;]+") do
          local k, z = e:match("^(%d+@%-?%d+,%-?%d+)~(%-?%d+)$")
          if k then H[k] = tonumber(z) else good = false end
        end
      end
      if good then
        E.hostK = H
        if (w[5] or "-") ~= E.hostKline then E.hostKline = w[5] or "-"; E.tCamp = -1e9 end   -- a changed list: look at this copy's camps now
      else bump("k_badLine"); log("bandit camps: a line from the host could not be read: %s", tostring(w[5])) end
    elseif sub == "O" then
      local H = {}
      for k, c in (w[5] or ""):gmatch("([^,=]+)=([^,]+)") do H[k] = c end
      E.hostO = H
    elseif sub == "T" then
      if E.on.thefts then local ok, e = pcall(friendTheft, S, w); if not ok then log("thefts: the host's line failed here: %s", tostring(e)) end end
    elseif sub == "AD" then
      if E.on.vdeaths and not C.hold and not (C.stale and C.stale("host", w)) then guarded("animal death", friendAnimalDeath, S, w) end
    elseif sub == "AG" then                                    -- (task 64d) an animal gone from the host's town without a body
      if E.on.vdeaths and E.on.animalGone and not C.hold and not (C.stale and C.stale("host", w)) then guarded("animal gone", friendAnimalGone, S, w) end
    elseif sub == "PD" then
      if w[5] and E.on.vdeaths then
        -- (lane 64) the region, the notice (tag and text key: plain words only, or none) and the host's place
        local tok = dec(w[5])
        local rk = (w[9] and w[9] ~= "" and w[9] ~= "-") and w[9] or nil
        local tag = (w[10] and w[10]:match("^[%w_]+$")) and w[10] or nil
        local text = (tag and w[11] and w[11]:match("^[%w_]+$")) and w[11] or nil
        local x, y = (w[12] or ""):match("^(%-?%d+),(%-?%d+),%-?%d+$")
        E.pdQ[(rk or "") .. "|" .. tok] = { t = os.clock(), tok = tok, rk = rk, role = tonumber(w[6]) or -1, age = tonumber(w[7]) or -1, fight = w[8] ~= "0",
                                           tag = text and tag or nil, text = text, x = tonumber(x), y = tonumber(y) }
        E.tVill = -1e9
      end
    elseif sub == "PC" then
      -- (lane 64) E PC <region> <bodies> <whole 0|1> <name>~<role>~<x>~<y>;...
      local rk, n, whole = w[5], tonumber(w[6]), w[7] == "1"
      if rk and n then
        local list, good = {}, true
        if w[8] and w[8] ~= "-" then
          for e in w[8]:gmatch("[^;]+") do
            local nm, role, x, y = e:match("^([^~]*)~(%-?%d+)~(%-?%d+)~(%-?%d+)$")
            if nm then list[#list + 1] = { n = dec(nm), role = tonumber(role), x = tonumber(x), y = tonumber(y) } else good = false end
          end
        end
        -- a line that cannot be read whole, or whose count is not its entries, is no word to take a body out by
        local day
        if whole and good and #list == n and w[9] and w[9]:match("^%d+$") and w[10] then
          day = tonumber(w[9])
          local i = 0
          for token in (w[10] .. ","):gmatch("([^,]*),") do
            i = i + 1
            local age = token:match("^%d+$") and tonumber(token)
            if not list[i] or (token ~= "-" and (not age or age > 30)) then day = nil; break end
            list[i].days = age
          end
          if i ~= n then day = nil end
        end
        E.hostC[rk] = { t = os.clock(), n = n, whole = whole and good and #list == n, list = list, day = day }
        E.tCorpseF = -1e9
      end
    elseif sub == "PZ" then
      for rk in (w[5] or ""):gmatch("[^,]+") do
        local H = E.hostC[rk]
        if not H or H.n ~= 0 or not H.whole then E.hostC[rk] = { t = os.clock(), n = 0, whole = true, list = {} }; E.tCorpseF = -1e9 end
      end
    elseif sub == "P" then
      local rk, n, first = w[5], tonumber(w[6]), tonumber(w[7])
      if rk and n and first then
        local H = E.hostP[rk]; if not H then H = { fams = {} }; E.hostP[rk] = H end
        H.n = n
        E.tPeople = math.min(E.tPeople or 0, os.clock() - PEOPLE_EVERY + 0.5)   -- compare half a second from now
        for i in pairs(H.fams) do if i > n then H.fams[i] = nil end end
        local i = first
        if w[8] and w[8] ~= "-" then
          for fam in w[8]:gmatch("[^;]+") do
            local rec = { m = {} }; local k = 0
            for part in fam:gmatch("[^|]+") do
              k = k + 1
              if k == 1 then rec.home = part
              elseif part == "?" then rec.wait = true
              else
                local nm, role, age = part:match("^([^~]*)~(%-?%d+)~(%-?%d+)$")
                rec.m[#rec.m + 1] = { n = dec(nm or ""), role = tonumber(role) or -1, age = tonumber(age) or -1 }
              end
            end
            H.fams[i] = rec; i = i + 1
          end
        end
      end
    end
  elseif S.role == "host" and from ~= "host" then
    if w[4] == "CASK" then E.tKeyC = -1e9; E.tCorpse = -1e9; return true end
    local ok, e = pcall(hostAnswer, S, from, w)
    if not ok then log("answer from %s failed: %s", tostring(from), tostring(e)) end
  end
  return true
end

function E.status()
  local t = {}; for k, v in pairs(E.stats) do t[#t + 1] = k .. "=" .. tostring(v) end; table.sort(t)
  local on = {}; for k, v in pairs(E.on) do if v then on[#on + 1] = k end end; table.sort(on)
  return string.format("events %s: %s | on: %s | last error %s | last quest difference %s | people: %s", E.version, table.concat(t, " "), table.concat(on, ","), tostring(E.lastErr), tostring(E.lastDiff), tostring(E.peopleNow))
end

C.register("events", M)
return "coop_x_events " .. E.version .. " loaded"
