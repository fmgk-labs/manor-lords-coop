-- Manor Lords Co-op: lord decisions that change rarely (plug-in module "realm").
-- Development perks, tax rates, policies and region names of the player's own regions.
-- These are caught by comparing state, not by hooking a button: every copy reads the few values twice a second.
--   a friend's copy sees one of its own values change  -> tells the host            (R SET region item value)
--   the host applies it, and tells everyone what holds -> all copies end up equal   (R IS  region item value)
-- The host's word is final. A copy that cannot take the host's value asks for a repair (a reload of the host's world).
-- Catching by state works whichever function the game's own window calls, and nothing here costs silver, so there is
-- no money race.
--   status: perk read (PerkComponent:GetActivePerkInSlot) and perk pick through a never-shown panel
--           (BP_PerkSelectionPanel_C: SetRegion, PerkSlot, SetSelectedPerkName, PerkSelectionAccepted): run live on one
--           copy (README session 17). Tax (Region:getTaxRate / changeTaxRate), name (regionName / renameRegion): see
--           the status line at each item below. Policy (Region.policiesSigned / setPolicySigned): see the policy
--           rule below and lanes/lane_s21_3/report.md.

local C = _G.Coop; local A = C.api
local un, valid, log = A.un, A.valid, A.log
C.realm = C.realm or {}
local R = C.realm
R.on = R.on or { perk = true, tax = true, policy = true, name = true, fams = true, mercs = true, lords = true, notices = true }
if R.on.logAll == nil then R.on.logAll = true end   -- (lane 66) a joining or reloading friend gets the host's whole notice list once (needs NOLOG on)
R.stats = R.stats or { set = 0, is = 0, applied = 0, failed = 0, repairs = 0 }
R.gHost = R.gHost or {}; R.claimSent = R.claimSent or {}; R.claimAck = R.claimAck or {}; R.famHost = R.famHost or {}; R.known = R.known or {}; R.want = R.want or {}
local POLL, KEYFRAME, VERIFY = 0.5, 30.0, 3.0
local TAXES = { "land", "tithe" }          -- names read in the game's own tax routine (lane_t2 report, T11a)
local famKeys                               -- defined with the family rule below
local signedStr                             -- defined with the policy rule below
local townReplayed                          -- defined before the poll

local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); if ok then return a end end
local function rkey(r)
  local ok, k = pcall(function() return r.regionUniqueTag:ToString() end)
  if not ok or type(k) ~= "string" or k == "" or k == "None" then return nil end
  return (k:gsub("[^%w_%.]", "_"))
end
local function enc(s) return (s:gsub("[^%w]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function dec(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

-- the player's own regions, by key
local function owned(S)
  local me = addr(S.p1); local t = {}
  local arr = S.eng.regions
  for i = 1, #arr do
    local r = un(arr[i])
    if valid(r) and me and valid(r.ownerPawn) and addr(r.ownerPawn) == me then local k = rkey(r); if k then t[k] = r end end
  end
  return t
end

-- ---- policies: the list Region.policiesSigned is the state (lane 3, session 21)
-- Measured on 0.8.117 through the policy card's own handler (policyWidget_C, Button_22 released):
--   a card pressed with a free slot calls Region:setPolicySigned(id, true); pressed again, setPolicySigned(id, false);
--   pressed with every slot used, it calls nothing. Slots: Region:getMaxPolicies() is 0 without a manor and 1 with one
--   (settlement level 2 to 5 made no difference). No silver, influence or favour is spent.
--   Region:hasPolicy(id) stays false and Region.policies stays empty after signing, and PawnCPP:enactPolicy returns
--   false even with a free slot: the older "enact" path is dead in this version, so it is neither read nor replayed.
-- The value is the signed ids in rising order ("2.12"), or "none".
local function signedIds(r)
  local t = {}; local a = r.policiesSigned
  for i = 1, #a do
    local v = a[i]
    if type(v) ~= "number" then v = v:get() end
    t[#t + 1] = math.floor(v)
  end
  table.sort(t)
  return t
end
signedStr = function(r)
  local t = signedIds(r)
  return #t == 0 and "none" or table.concat(t, ".")
end
local function policySet(value) local t, n = {}, 0; for id in tostring(value):gmatch("%d+") do t[tonumber(id)] = true; n = n + 1 end; return t, n end
-- may the host take this list from a friend? Never more signed policies than the region has slots (the card's own rule).
local function policyFits(r, value)
  local _, n = policySet(value)
  local ok, max = pcall(function() return r:getMaxPolicies() end)
  return ok and type(max) == "number" and n <= max
end

-- ---- read: every item of one region as { item = value }, values are single words
local function readRegion(r)
  local t = {}
  if R.on.perk then
    for s = 1, 3 do
      local ok, v = pcall(function() return r.PerkComponent:GetActivePerkInSlot(s):ToString() end)
      if ok and type(v) == "string" then t["perk" .. s] = (v == "" and "None" or enc(v)) end
    end
  end
  if R.on.tax then
    for _, n in ipairs(TAXES) do
      local ok, v = pcall(function() return r:getTaxRate(FName(n)) end)
      if ok and type(v) == "number" then t["tax_" .. n] = tostring(v) end
    end
  end
  if R.on.policy then
    local ok, v = pcall(signedStr, r)
    if ok then t.policy = v end
  end
  if R.on.name then
    local ok, v = pcall(function() return r.regionName:ToString() end)
    if ok and type(v) == "string" and v ~= "" then t.name = enc(v) end
  end
  if R.on.fams then
    local ok, v = pcall(function() local k = famKeys(r); return #k == 0 and "0" or table.concat(k, ";") end)
    if ok then t.fams = v end
  end
  return t
end

-- ---- families: the host's list is the truth (host -> friends only)
-- Arrivals follow from the town and come out equal; departures are rolled by each copy on its own dice (lane_w W3,
-- seen live in session 17: after 20 days the host had 18 families, the friend 19, the lists equal but for one entry).
-- A family is named by its home (type@x,y), in list order. When the friend's list is the host's list plus extras,
-- the friend removes the extras with the game's own Region:removeWorkerFamilyAt; when the friend lacks a family
-- there is no named way to make one, so it asks for a repair.
--   status: see README session 17
local FAM_WAIT = 10.0                       -- seconds a difference must last (a day change lands a moment apart on two copies)
local function bkey(b)
  local l = b:K2_GetActorLocation()
  return string.format("%d@%d,%d", A.btype(b), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5))
end
famKeys = function(r)
  local t = {}; local fams = r.workerFamilies
  for i = 1, #fams do
    local ok, k = pcall(function() local h = fams[i].familyHome; return valid(h) and bkey(h) or "-" end)
    t[i] = ok and k or "?"
  end
  return t
end
local function famCheck(S, rk, r, mineStr, clock)
  local H = R.famHost and R.famHost[rk]; if not H then return end
  if mineStr == H.v then H.since = nil; return end
  H.since = H.since or clock
  -- (lane 64, lane 66's run 4) while the events module is putting a home of this region right (a family put out by
  -- this copy's own burn-down, a house that is not a building here yet, a family that just arrived or left), the
  -- repair waits: 3 s after the last such move, for 30 s at most.
  local Ev = rawget(C, "events")
  if Ev and Ev.homeBusy and clock - H.since < 30.0 then
    local okB, busy = pcall(Ev.homeBusy, rk, clock)
    if okB and busy then if not H.busy then H.busy = true; R.stats.famWaits = (R.stats.famWaits or 0) + 1 end; return end
  end
  H.busy = nil
  if clock - H.since < FAM_WAIT then return end
  H.since = clock                                           -- one attempt per wait
  local host, mine = {}, famKeys(r)
  for k in H.v:gmatch("[^;]+") do if k ~= "0" then host[#host + 1] = k end end
  local extra, j = {}, 1                                    -- is the host's list inside mine, in order?
  for i = 1, #mine do if j <= #host and mine[i] == host[j] then j = j + 1 else extra[#extra + 1] = i end end
  if j <= #host then
    log("realm: %s families differ and %d of the host's are missing here: asking for a repair", rk, #host - j + 1)
    R.stats.repairs = R.stats.repairs + 1
    if C.join and C.join.requestRepair then C.join.requestRepair("families") end
    return
  end
  for n = #extra, 1, -1 do                                  -- from the end, so earlier places keep their numbers
    local idx = extra[n] - 1                                -- the game counts families from 0
    local people = {}                                       -- the family's villagers leave with it
    pcall(function() local fams = r.workerFamilies; if extra[n] > #fams then return end; local m = fams[extra[n]].familyMembers; for i = 1, #m do local u = un(m[i]); if valid(u) then people[#people + 1] = u end end end)
    local ok, e = pcall(function() r:removeWorkerFamilyAt(idx) end)
    if ok then
      R.stats.famRemoved = (R.stats.famRemoved or 0) + 1
      -- The family's villagers are removed 5 s LATER, not at once: lane 36 lost a friend's copy when a villager was
      -- destroyed in the middle of a work action (its own removal, coop_x_people.lua, waits the same 5 s). The
      -- family is off its work by then. A world loaded meanwhile drops the list (S.later is emptied).
      if #people > 0 and A.later then
        A.later(5.0, function()
          local gone = 0
          for _, u in ipairs(people) do if valid(u) and not u.dead and pcall(function() S.eng:destroyUnit(u) end) then gone = gone + 1 end end
          R.stats.famUnitsGone = (R.stats.famUnitsGone or 0) + gone
        end)
      end
    end
    log("realm: %s family %d (%s) is gone on the host: removed here; its %d villagers leave in 5 s%s", rk, extra[n], mine[extra[n]], #people, ok and "" or (" FAILED " .. tostring(e)))
  end
end

-- ---- apply one value; returns true when the call went through (the next reads decide whether it took)
local function panelClass()
  local cls = StaticFindObject("/Game/UI/Development/Panels/BP_PerkSelectionPanel.BP_PerkSelectionPanel_C")
  if valid(cls) then return cls end
  for _, c in ipairs(FindAllOf("WidgetBlueprintGeneratedClass") or {}) do
    local ok, n = pcall(function() return c:GetFName():ToString() end)
    if ok and n == "BP_PerkSelectionPanel_C" then return c end
  end
end

local function applyPerk(S, r, slot, name)
  if name == "None" then return false, "a perk cannot be taken back" end
  local cls = panelClass(); if not valid(cls) then return false, "perk panel class not loaded" end
  local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
  local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
  local panel = WBL:Create(S.p1, cls, GS:GetPlayerController(S.p1, 0))
  if not valid(panel) then return false, "perk panel not created" end
  panel:SetRegion(r); panel.PerkSlot = slot
  panel:GeneratePerks()
  panel:SetSelectedPerkName(FName(dec(name)))
  panel:PerkSelectionAccepted()
  return true
end

local function apply(S, r, item, value)
  local slot = item:match("^perk(%d)$")
  if slot then return applyPerk(S, r, tonumber(slot), value) end
  local tax = item:match("^tax_(%w+)$")
  if tax then r:changeTaxRate(FName(tax), tonumber(value)); return true end
  if item == "policy" then
    local want = policySet(value); local have = {}
    for _, id in ipairs(signedIds(r)) do have[id] = true end
    for id in pairs(have) do if not want[id] then r:setPolicySigned(id, false) end end      -- give slots back first
    for id in pairs(want) do if not have[id] then r:setPolicySigned(id, true) end end
    return true
  end
  if item == "name" then r:renameRegion(dec(value)); return true end
  return false, "unknown item"
end

local function take(S, key, rk, item, value, why)
  local r = R.regions and R.regions[rk]
  R.known[key] = value
  if not valid(r) then return end
  local cur = readRegion(r)[item]
  if cur == value then R.want[key] = nil; return end
  -- (lane 81) inside the town module's quiet wrapper: its TAX hook must not take this write for the player's own change
  -- (it was dropped only by the 0.75 s time rule before, lane_s21_3 friend log 1794434507.249)
  local Tn = C.town
  local ok, done, err
  if Tn and Tn.quiet then ok, done, err = pcall(Tn.quiet, apply, S, r, item, value) else ok, done, err = pcall(apply, S, r, item, value) end
  if ok and done then R.stats.applied = R.stats.applied + 1 else R.stats.failed = R.stats.failed + 1 end
  if ok and done and C.panels and C.panels.touched then pcall(C.panels.touched, "R:" .. (item:match("^(%a+)") or item), nil) end   -- (lane 69) open panels redraw
  log("realm: %s %s %s -> %s (%s)%s", why, rk, item, value, tostring(cur), (ok and done) and "" or (" FAILED " .. tostring(ok and err or done)))
  R.want[key] = { v = value, t = os.clock() }       -- the next reads check that it took
end

-- ---- world-level values that only the host decides (host -> friends; region word "_")
-- Mercenary companies on offer are rolled by each copy (session 17: host had vultures, greencaps, brigands; the friend
-- brigands_small, vultures, battle_brothers). Rival lords do not decide anything on a friend's copy, so their numbers
-- and claims come from the host too. A friend's own new claim is the one thing sent the other way (R SET _ claim).
--   status: see README session 17
local GRACE = 3.0
local function enc2(s) return (tostring(s):gsub("[^%w_]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function split(s, sep) local t = {}; for part in (s .. sep):gmatch("(.-)" .. sep) do t[#t + 1] = part end; return t end
local function names(arr) local t = {}; for i = 1, #arr do t[#t + 1] = enc2(arr[i]:ToString()) end; return table.concat(t, ",") end
local function regionByKey(S, k)
  local arr = S.eng.regions
  for i = 1, #arr do local r = un(arr[i]); if valid(r) and rkey(r) == k then return r end end
end
local function lordCode(S, o)
  if not valid(o) then return nil end
  if addr(o) == addr(S.p1) then return "P" end
  local okB, b = pcall(function() return o.isBandit end); if okB and b then return nil end
  if addr(o:GetClass()) == addr(S.p1:GetClass()) then return nil end           -- the mod's helper lord: not a lord of the game
  local okI, i = pcall(function() return o:getPawnSetupIndex() end)
  return (okI and type(i) == "number") and ("A" .. i) or nil
end
local function lords(S)
  local t = {}
  for _, pw in ipairs(A.pawns()) do local c = lordCode(S, pw); if c then t[c] = pw end end
  return t
end

-- A company record: name, cost, colours, emblems, days until it arrives, where it arrives, its banner, its unit types
-- and traits. Session 17, on a friend's copy:
--   replacing the whole list with new records crashed the game;
--   asking the game for new offers until the names matched (rerollMercenaries) works but each call adds a
--     "mercenaries available" notice to the player's list (dozens of them);
--   writing each field of an existing record in place is safe (number, text, list of names, object reference: each
--     tried separately). That is what is done here: the copy's own records are edited to become the host's.
-- `only`: compare just these names (the host may hold fewer records than this copy; records cannot be added or removed).
-- (lane 88) With the native MERCCUT a friend's list is cut to the host's length and its records are put in the host's
-- order (lead runs r27m83, r27cf: a rival lord's hire on the host left the friend with 3 offers against 2 for the
-- whole session; the hire window shows the cards in list order). Then the whole list is compared, in list order
-- (`ordered`); without MERCCUT (another game build) as before: sorted, only the host's names.
local function mercsStr(S, only, ordered)
  local a = S.eng.availableMercs; local t = {}
  for i = 1, #a do
    local m = a[i]; local n = m.Name:ToString()
    if not only or only[n] then
      local banner = "-"; if valid(m.banner) then banner = m.banner:GetFullName():match("^%S+%s+(.+)$") or "-" end
      local reg = valid(m.arrivalRegion) and rkey(m.arrivalRegion) or "-"
      t[#t + 1] = table.concat({ enc2(n), m.cost, m.colorA, m.colorB, m.emblemA, m.emblemB, m.arrivesIn, enc2(reg), enc2(banner), names(m.units), names(m.traits) }, ";")
    end
  end
  if not ordered then table.sort(t) end
  return #t == 0 and "0" or table.concat(t, "|")
end
-- (lane 88) can this copy cut its offer list (the native MERCCUT is there)? Only a friend asks.
-- R.mercNoCut: a cut or a refill did not take once in this session: the old rule (the host's companies only) from then on,
-- so that a list this copy cannot make equal never asks for a resync
local function mercCutOk() if R.mercNoCut then return false end; local P = rawget(C, "patch"); return P ~= nil and P.mercAvail ~= nil and P.mercAvail() == true end
-- (lane 88) may this player's own hire be on its way to the host? Only that makes this copy's list SHORTER than the
-- host's (the hired company left here first; coop.lua S.mercGone names it, for 5 s, until the host hires it too).
-- A longer list or other companies are never this player's doing: taken from the host at once.
local function recCount(v) if not v or v == "0" then return 0 end; local n = 1; for _ in v:gmatch("|") do n = n + 1 end; return n end
local function ownHireOnWay(S, clock, mine, hostv)
  if recCount(mine) >= recCount(hostv) then return false end
  if (S.hireSent ~= nil and next(S.hireSent) ~= nil) or S.freshT ~= nil then return true end
  -- this copy's list got shorter at a look of the mod in the last 5 s, by nobody's write of the mod (mercHold): the
  -- player's hire, seen before the core's own offer scan has named the company
  if R.mercDropT and clock - R.mercDropT < 5.0 then return true end
  -- the company gone from this list must still be on the host's (the host has not hired it yet)
  local g = S.mercGone
  return g ~= nil and clock - (g.t or -99) < 5.0 and hostv ~= nil and ("|" .. hostv):find("|" .. enc2(g.name) .. ";", 1, true) ~= nil
end
local function mercNames(value)
  local set = {}
  if value and value ~= "0" then for _, rec in ipairs(split(value, "|")) do local nm = rec:match("^([^;]*);"); if nm then set[dec(nm)] = true end end end
  return set
end
local function nameList(s) local t = {}; for u in (s or ""):gmatch("[^,]+") do t[#t + 1] = FName(dec(u)) end; return t end
local function mercsApply(S, value)
  local a = S.eng.availableMercs
  local want = {}; if value ~= "0" then for _, rec in ipairs(split(value, "|")) do want[#want + 1] = split(rec, ";") end end
  local cut = mercCutOk()
  -- (lane 88) fewer offers here than on the host (the host's game refilled its offers, or this copy's list was cut
  -- after a hire on the host and the host refilled since): the game's own refill first; if the list is still shorter
  -- after it, the old rule from then on (below)
  -- (run l88c: 263 calls while the friend stood shorter) once for each list of the host, never at every look
  local rolled = false
  if cut and #a < #want and R.mercRefillFor ~= value then
    R.mercRefillFor = value
    local n0 = #a
    -- (lane 87) Engine::refillMercenaries is an empty routine in this build (the linker's shared stub, C2 00 00: it never
    -- made an offer, lane 88's runs l88b and l88c). With NOROLL on here (coop_x_values.lua) the game's own roll is let
    -- through once (P.noRollPass): it empties the list and makes up to three offers, which take the host's records
    -- below in this same tick (no frame shows them); what it made beyond the host's count is cut at once. Without
    -- NOROLL: the refill as before (R.mercShort when it makes none).
    local P = rawget(C, "patch")
    local how, ok, e = "refillMercenaries", nil, nil
    if P and P.noRollPass and P.noRollPass() then
      how = "rerollMercenaries (NOROLL PASS)"
      R.mercRolling = true                                               -- (lane 88's hook on the routine: not entered)
      ok, e = pcall(function() S.eng:rerollMercenaries() end)
      R.mercRolling = nil
      rolled = ok
      R.stats.mercRoll = (R.stats.mercRoll or 0) + 1
    else
      ok, e = pcall(function() S.eng:refillMercenaries() end)
      R.stats.mercRefill = (R.stats.mercRefill or 0) + 1
    end
    a = S.eng.availableMercs
    log("realm: offers %d here, %d on the host: the game's %s %s (now %d)", n0, #want, how, ok and "ran" or ("failed: " .. tostring(e)), #a)
  end
  local wanted = mercNames(value); local byName, free = {}, {}
  local slots = {}
  if cut then
    -- (lane 88) the host's records go into this copy's first slots, in the host's order (each slot's fields written
    -- in place, as before); the slots past the host's count are cut off below
    -- (run l88b) still fewer after the game's refill (it makes no offer when the game sees no reason): the host's
    -- first records go into the slots there are; the rest cannot be made by script. That is no failure of this copy
    -- (R.mercShort: not counted towards a resync, which the old rule asked for here)
    R.mercShort = #a < #want
    if R.mercShort then
      R.stats.mercShort = (R.stats.mercShort or 0) + 1
      if R.mercShortFor ~= value then R.mercShortFor = value; log("realm: offers %d here, %d on the host after the game's refill: the host's first %d are written, the rest cannot be made here", #a, #want, #a) end
    end
    for i = 1, math.min(#a, #want) do slots[i] = a[i] end
  end
  if not cut then
    for i = 1, #a do local n = a[i].Name:ToString(); if wanted[n] and not byName[n] then byName[n] = a[i] else free[#free + 1] = a[i] end end
  end
  for j, f in ipairs(want) do
    local n = dec(f[1]); local m = slots[j] or byName[n] or table.remove(free, 1)
    if not m and cut then break end                                     -- (lane 88: R.mercShort, above)
    if not m then error("this copy holds fewer offers than the host") end
    if m.Name:ToString() ~= n then m.Name = n end
    local nums = { cost = f[2], colorA = f[3], colorB = f[4], emblemA = f[5], emblemB = f[6], arrivesIn = f[7] }
    for k, v in pairs(nums) do v = tonumber(v); if v and m[k] ~= v then m[k] = v end end
    local reg = regionByKey(S, dec(f[8])); if reg and (not valid(m.arrivalRegion) or rkey(m.arrivalRegion) ~= dec(f[8])) then m.arrivalRegion = reg end
    local b = dec(f[9])
    if b ~= "-" and (not valid(m.banner) or (m.banner:GetFullName():match("^%S+%s+(.+)$")) ~= b) then local tex = StaticFindObject(b); if valid(tex) then m.banner = tex end end
    if names(m.units) ~= (f[10] or "") then m.units = nameList(f[10]) end
    if names(m.traits) ~= (f[11] or "") then m.traits = nameList(f[11]) end
  end
  -- (lane 88) more offers here than on the host: the list is cut to the host's count (native MERCCUT: the count only;
  -- the records past it stay whole in the list's memory). The list is read again in this tick, never past its end.
  if cut then
    a = S.eng.availableMercs
    local now = #a
    -- (run l88b) the host's list stood shorter for 0.6 s at its own month roll, the friend cut to it and then could
    -- not grow again: a cut only once the host's shorter count has stood for 1.5 s (R.mercHostN, set when it came)
    -- (run l88c) nor within 2 s after this copy's own game changed its list (its month roll: the host rolls in the same
    -- moment and its new list comes a moment later; cut to the host's old count, this copy could not grow again)
    local stood = R.mercHostN == #want and os.clock() - (R.mercHostNT or -99) >= 1.5 and os.clock() - (R.mercOwnT or -99) >= 2.0
    -- (lane 87) the slots this copy's own roll has just made (NOROLL PASS above) beyond the host's count are cut at once:
    -- the waits are for a host list that may still grow and for this copy's own month roll, not for records made now.
    -- And with NOROLL on here no wait at all: the waits came from a copy that could not grow its list again after a cut
    -- (the refill makes nothing) and from its own month roll; with NOROLL this copy does not roll by itself and grows by
    -- the pass above. Waiting showed, after a rival's hire on the host (3 offers to 2), the host's two records over the
    -- first two slots and the third slot of before for 1.5 s: a list the host never had.
    local Pn = rawget(C, "patch")
    if rolled or (Pn and Pn.noRollOn and Pn.noRollOn()) then stood = true end
    if now > #want and not stood then R.stats.mercCutWait = (R.stats.mercCutWait or 0) + 1 end
    if now > #want and stood then
      local okA, la = pcall(function() return a:GetArrayAddress() end)
      local ea = S.eng:GetAddress()
      if not (okA and type(la) == "number") then la = ea + 0xBF0; R.stats.mercAddrGuess = (R.stats.mercAddrGuess or 0) + 1 end
      local P = rawget(C, "patch")
      local sent = P.mercCut(ea, la, now, #want)
      local after = #S.eng.availableMercs
      R.stats.mercCut = (R.stats.mercCut or 0) + 1
      log("realm: offers %d here, %d on the host: cut to the host's (MERCCUT %s; now %d)", now, #want, sent and "sent" or "unavailable", after)
      if after ~= #want then R.mercNoCut = true; log("realm: the cut did not take: from now on only the host's companies are compared (as before lane 88)") end
    end
    -- the names this copy now offers are the core's "last seen" names (coop.lua): a company the mod wrote over or cut
    -- off is not "gone from this copy's offers" (that is how the core tells this player's own hire)
    local okN, set = pcall(function() local t = {}; local b = S.eng.availableMercs; for i = 1, #b do t[b[i].Name:ToString()] = true end; return t end)
    if okN and S.role == "friend" then S.mercNames = set end
    R.mercPrevN = #S.eng.availableMercs                                  -- (mercHold: the mod's own cut is no drop)
    local okS, ms = pcall(mercsStr, S, nil, true); if okS then R.mercPrevS = ms end
  end
  pcall(function() S.p1:updateMercenayCompanyUI() end)                  -- the game's own spelling
end

local function claimsStr(pw)
  local a = pw.claims; local t = {}
  for i = 1, #a do local c = a[i]; if valid(c.Region) then t[#t + 1] = string.format("%s:%d:%d:%.2f", rkey(c.Region), c.DaysLeft, c.blocked and 1 or 0, c.Score) end end
  -- by region, not in list order: a copy that had to lay one of the host's claims again holds the same claims in
  -- another order (lane 3, session C: "here gold/nus, host nus/gold" never took, and the item was switched off)
  table.sort(t)
  return #t == 0 and "0" or table.concat(t, "/")
end
local function claimTags(value) local t = {}; if value and value ~= "0" then for rec in value:gmatch("[^/]+") do t[rec:match("^([^:]+)")] = true end end; return t end
-- A claim record holds a reference to a region, and writing records with references into a list crashed the game for
-- mercenaries, so claims are made with the game's own PawnCPP:layClaim (no favour, no influence spent: the host's
-- numbers are pushed separately) and only the plain numbers are written afterwards. A claim this copy has and the host
-- does not is dropped by emptying the list and laying the host's claims again.
local function claimsApply(S, pw, value)
  -- (lane 32) a region may stand on the list more than once: the region view's claim buttons stay shown and enabled on a
  -- region already claimed and the game lays a second claim (lane 29 part 2; lane 32 s5: the host's own press made
  -- "nus" twice). So the host's list is taken as a list, region by region with its count: want[k] = the records of k.
  local want, order = {}, {}
  if value ~= "0" then
    for rec in value:gmatch("[^/]+") do
      local k, d, b, sc = rec:match("^([^:]+):(%-?%d+):(%d):(%-?[%d%.]+)$")
      if k then want[k] = want[k] or {}; local t = want[k]; t[#t + 1] = { d = tonumber(d), b = b == "1", sc = tonumber(sc) }; order[#order + 1] = k end
    end
  end
  local haveN = {}
  pcall(function() local a = pw.claims; for i = 1, #a do local c = a[i]; if valid(c.Region) then local k = rkey(c.Region); haveN[k] = (haveN[k] or 0) + 1 end end end)
  -- a region this copy holds and the host does not, or holds a different number of times (the friend that pressed a
  -- second claim the host did not lay, lane 29; or the host's second claim): the list is laid again from the host's
  local extra = false
  for k, n in pairs(haveN) do if not want[k] or #want[k] ~= n then extra = true end end
  local have = {}
  if extra then pw.claims = {} else for k, n in pairs(haveN) do have[k] = n end end
  for _, k in ipairs(order) do
    if (have[k] or 0) > 0 then have[k] = have[k] - 1
    else
      local reg = regionByKey(S, k)
      -- Inside the town module's quiet wrapper: the lord module's hook on layClaim notes "this player laid a claim on
      -- <region>", and the mod's own call here must not be taken for the player's (lane 16; see the claim rule in
      -- pollGlobal below).
      if reg then
        if C.town and C.town.quiet then C.town.quiet(function() pw:layClaim(reg, false, false) end) else pw:layClaim(reg, false, false) end
      end
    end
  end
  local a = pw.claims; local used = {}
  for i = 1, #a do
    local c = a[i]; local k = valid(c.Region) and rkey(c.Region); local w
    if k and want[k] then used[k] = (used[k] or 0) + 1; w = want[k][used[k]] end
    if w then
      if c.DaysLeft ~= w.d then c.DaysLeft = w.d end
      if (c.blocked and true or false) ~= w.b then c.blocked = w.b end
      if math.abs(c.Score - w.sc) > 0.005 then c.Score = w.sc + 0.0 end
    end
  end
  pcall(function() S.p1.shouldUpdateClaimUI = true end)
end

local function readGlobal(S)
  local t = {}
  if R.on.mercs then local ok, v = pcall(mercsStr, S, nil, true); if ok then t.mercs = v end end     -- (lane 88) in list order
  if R.on.lords then
    for code, pw in pairs(lords(S)) do
      local ok, v = pcall(function()
        if code == "P" then return string.format("%d,%d", pw.influence, pw.kingsFavour) end   -- the treasury is the world module's
        return string.format("%d,%d,%d", pw.influence, pw.kingsFavour, pw.silver)
      end)
      if ok then t["lord_" .. code] = v end
      local ok2, v2 = pcall(claimsStr, pw); if ok2 then t["claims_" .. code] = v2 end
    end
  end
  return t
end
local function applyGlobal(S, item, value)
  if item == "mercs" then mercsApply(S, value); return end
  local kind, code = item:match("^(%a+)_(%w+)$")
  local pw = code and lords(S)[code]; if not valid(pw) then error("no lord " .. tostring(code)) end
  if kind == "lord" then
    local n = {}; for x in value:gmatch("[^,]+") do n[#n + 1] = tonumber(x) end
    if n[1] and pw.influence ~= n[1] then pw.influence = n[1] end
    if n[2] and pw.kingsFavour ~= n[2] then pw.kingsFavour = n[2] end
    if n[3] and pw.silver ~= n[3] then pw.silver = n[3] end
  elseif kind == "claims" then claimsApply(S, pw, value) end
end
local function switchKind(item) return item == "mercs" and "mercs" or "lords" end

-- (lane 79) is a claim of this player's on its way to the host (see the claims rule in pollGlobal)?
local CLAIM_GRACE = 1.0
local function claimPending(clock)
  local H = R.gHost.claims_P
  local theirs = H and H.v and claimTags(H.v) or {}
  for tag, t in pairs(R.claimSent) do
    -- answered "laid": on its way only until the host's list has shown it once (at most GRACE after the answer)
    local ack = R.claimAck[tag]
    if ack and ack ~= "seen" and theirs[tag] then R.claimAck[tag] = "seen"; ack = "seen" end
    local onWay = (ack == nil) or (ack ~= "seen" and clock - ack < GRACE)
    if clock - t < 10.0 and onWay then return true end
  end
  local Lm = C.lord
  if Lm and Lm.letterT and clock - Lm.letterT < 10.0 then return true end
  if Lm and Lm.claimHow then for _, x in pairs(Lm.claimHow) do if x.t and clock - x.t < 30.0 then return true end end end
  return false
end
local function pollGlobal(S, clock, key30)
  local cur = readGlobal(S)
  if S.role == "host" then
    for item, v in pairs(cur) do
      local key = "_|" .. item
      if R.known[key] ~= v or key30 then
        if R.known[key] ~= v then R.stats.is = R.stats.is + 1 end
        R.known[key] = v; A.send(string.format("R IS _ %s %s", item, v))
      end
    end
    return
  end
  -- (lane 88) the mercenary offers: with MERCCUT the whole list in list order against the host's; without it, as
  -- before, the host's companies only and sorted (so the host's list, which now comes in list order, is sorted too)
  local cutOk = R.on.mercs and mercCutOk()
  local function hostV(item, H)
    if item ~= "mercs" or cutOk or H.v == "0" then return H.v end
    local t = split(H.v, "|"); table.sort(t); return table.concat(t, "|")
  end
  local function mine(item, H)
    if item == "mercs" then if cutOk then return mercsStr(S, nil, true) end; return mercsStr(S, (mercNames(H.v))) end
    return readGlobal(S)[item]
  end
  for item, v in pairs(cur) do
    local H = R.gHost[item]
    if H then
      if item == "mercs" then v = mine(item, H) end          -- compare only the companies the host has
      if item == "claims_P" then                             -- the player's own new claim, laid on this copy: tell the host
        local theirs = claimTags(H.v)
        for tag in pairs(claimTags(v)) do
          local sent = R.claimSent[tag]
          local Lm = C.lord
          if not theirs[tag] and Lm and Lm.letterT and clock - Lm.letterT < 10.0 then
            H.since = clock      -- this claim came from a letter this player just sent: the host makes it when it sends the same letter (lord module)
          elseif not theirs[tag] and (not sent or clock - sent > 10.0) then
            -- Only a claim this player laid HIMSELF is sent (lane 16): the lord module's hook saw the game's own
            -- layClaim call on his lord within the last 30 s. The region view's claim button is the only graph of
            -- the game that makes that call (read in the game's blueprint scripts), so every claim of the player
            -- passes the hook; it also gives the "use favour" flag, so nothing is guessed any more.
            -- A claim that is on this copy's list and not on the host's WITHOUT that call is not his: the claim ended
            -- on the host first (claims end at each copy's own day change), or a rival lord refuted it there (rivals
            -- act on the host only). Sent as "laid", it makes the host lay the claim AGAIN, on a region it has just
            -- won; the game accepts a claim on an own region (measured on the plain game: claims 0 -> 1, 14 days).
            -- Such a claim is left to the correction below, which takes the host's list after 3 s.
            local seen = Lm and Lm.claimHow and Lm.claimHow[tag]
            if seen and os.clock() - seen.t < 30.0 then
              local how = seen.fav and "f" or "i"
              R.claimSent[tag] = clock; R.claimAck[tag] = nil; H.since = clock      -- give the host a moment before this copy is put back
              A.send(string.format("R SET _ claim %s:%s", tag, how)); R.stats.set = R.stats.set + 1
              log("realm: this player laid a claim on %s (%s): sent to the host", tag, how == "f" and "king's favour" or "influence")
            elseif R.claimNote ~= tag then
              R.claimNote = tag; R.stats.claimNotMine = (R.stats.claimNotMine or 0) + 1
              log("realm: the claim on %s is on this copy's list and not on the host's, and this player did not lay it: not sent, the host's list is taken", tag)
            end
          end
        end
      end
      local hv = hostV(item, H)
      if v == hv then H.since = nil; H.fails = 0
      else
        H.since = H.since or clock
        -- (lane 79) the player's claims: GRACE is there for a claim of this player's on its way to the host. With
        -- none on its way (none sent in the last 10 s and not yet answered, no letter, no own layClaim in 30 s) a
        -- difference is the host's own change (a claim that ended, a war that took it) and is taken after 1 s: the
        -- 3 s of GRACE plus a poll left a claim on the friend 3.5 s after the host's had gone (lane 79 run g).
        local grace = GRACE
        if item == "claims_P" and not claimPending(clock) then grace = CLAIM_GRACE end
        -- (lane 88) the offers: GRACE is there for this player's own hire on its way to the host (this copy's list is
        -- one shorter until the host has hired the same company). With no company gone from this copy's list in the
        -- last 10 s (coop.lua S.mercGone) the host's list is taken at the next look: a rival's hire on the host left
        -- the friend's list longer for the whole session (lead runs r27m83, r27cf)
        if item == "mercs" and cutOk and not ownHireOnWay(S, clock, v, hv) then grace = 0 end
        if clock - H.since >= grace then
          H.since = clock
          local ok, e = pcall(applyGlobal, S, item, H.v)
          local after = mine(item, H)
          if ok and item == "mercs" and cutOk and (R.mercShort or recCount(after) > recCount(hv)) then H.fails = 0   -- (lane 88) fewer than the host, or a cut not yet due: no failure
          elseif ok and after == hv then R.stats.applied = R.stats.applied + 1; H.fails = 0
          else
            H.fails = (H.fails or 0) + 1; R.stats.failed = R.stats.failed + 1
            log("realm: %s did not take the host's value (%s); here %s, host %s", item, ok and "no error" or tostring(e), tostring(after):sub(1, 80), H.v:sub(1, 80))
            if H.fails >= 3 then
              -- A copy that cannot take the host's value differs from the host. First time: ask for the host's world
              -- (a resync). Only when the same item fails again after that is it switched off here, so that a value
              -- this copy can never take does not cause one resync after another.
              local kind = switchKind(item)
              R.strikes = R.strikes or {}; R.strikes[kind] = (R.strikes[kind] or 0) + 1
              H.fails = 0
              if R.strikes[kind] == 1 then
                log("realm: %s did not take the host's value 3 times: asking for a repair", item)
                R.stats.repairs = R.stats.repairs + 1
                if C.join and C.join.requestRepair then C.join.requestRepair("realm " .. item) end
              else
                R.on[kind] = false; log("realm: item %s switched off on this copy (it failed again after a repair)", kind)
                if C.notify then C.notify("info", "Co-op: this copy can no longer follow the host's " .. kind .. " values") end
              end
            end
          end
        end
      end
    end
  end
end

-- ---- notices: the host's new entries in the game's notice list go to the friends
-- The lord keeps its notices in PawnCPP.log (struct LogEntry: Tag, LogText, fullDescr, opensMenu, Location, ...). The
-- texts are the game's own keys ("army_sighted", "mercenaries_available", "claiming_region+ (Eberhart, Nusslohe)"), so
-- each copy shows them in its own language. The game adds them without a hookable call (recording hooks on the
-- notice functions stayed at 0 through two claims, session 17), so the host watches the list itself. Friends add an
-- entry with the game's own addLogIfNew, which skips what that copy already shows.
--   status: see README session 17
-- (lane 66) notices a friend's game adds by itself outside PawnCPP:addLog / addLogIfNew (they append to the list inline:
-- addResourceAddedLogs "reward", ChangeTreasury "treasury", settleRegion "outpost" / "settling", updateSquadVisibility
-- "Enemy" (enemy_squad_spotted, which coop.lua's speed watcher reads) and "Army" (army_sighted), constructionComplete
-- "construction_finished"; measured lane 66 run 1: without "Army" a friend showed army_sighted twice).
-- NOLOG does not hold them: with NOLOG on, this copy's own entries of these kinds are taken out (ownLocalPrune) and the
-- host's lines are added like every other notice.
local LOCAL_TAGS = { reward = true, treasury = true, outpost = true, settling = true, enemy = true, army = true }   -- compared in lower case (the game writes "Enemy", "Army")
-- one entry by its text, place and time (the place and the time differ between this copy's own entry and the host's)
local function logKey(e)
  local x, y = 0, 0; pcall(function() x, y = e.Location.X, e.Location.Y end)
  return e.LogText:ToString() .. "|" .. string.format("%.0f,%.0f|%.2f", x, y, e.Timestamp)
end
local function isLocalKind(e)
  local ok, r = pcall(function() return LOCAL_TAGS[e.Tag:ToString():lower()] or e.LogText:ToString():find("^construction_finished") ~= nil end)
  return ok and r and true or false
end
-- (lane 66, release re-check) a notice's actor: the game shows its name in brackets after the text ("Construction
-- finished. (Burgage Plot (Level 1))") and jumps to it on a click. Carried by a building's copy-independent key (type and
-- place, the town module's way); an actor that is not a building of the world's list is not carried ("-"). Before
-- lane 66 R LOG carried no actor at all (0.2.3: the friend's own line, with its actor, stood beside the host's).
local function actorKey(e)
  local ok, k = pcall(function()
    local a = e.Actor
    if not (a and a:IsValid()) then return "-" end
    local t = A.btype(a); if type(t) ~= "number" then return "-" end
    local l = a:K2_GetActorLocation()
    return string.format("%d@%d,%d", t, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5))
  end)
  return (ok and k) or "-"
end
local function buildingByKey(S, key)
  if not key or key == "-" or not valid(S.eng) then return nil end
  local hit = R.bCache and R.bCache[key]
  if hit and valid(hit) then return hit end
  R.bCache = R.bCache or {}
  local arr = S.eng.buildingArr; local n = #arr
  for i = 1, n do
    local b = un(arr[i])
    if valid(b) then
      local ok, k = pcall(function() local l = b:K2_GetActorLocation(); return string.format("%d@%d,%d", A.btype(b), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5)) end)
      if ok and k == key then R.bCache[key] = b; return b end
    end
  end
end
-- add one of the host's notices here through the mod's mark (NOLOG on) with its actor; remembered as the host's
local function addHostLine(S, P, h)
  local actor = buildingByKey(S, h.actor)
  P.markLog(); S.p1:addLog(FName(h.tag), h.text, h.descr, h.opens, h.pos, actor)
  local la = S.p1.log; local n = #la
  if n > 0 then
    local e = la[n]
    R.relayed[logKey(e)] = true
    if not e.IsDisplayed then R.pendingLogDraw = true end
  end
end
-- (lane 66, release re-check) the kinds this copy's game adds by itself outside the two notice routines (LOCAL_TAGS):
-- the host's line is the only one, as for every other notice. This copy's own line of such a kind is taken out at the
-- next look (ten times a second) with the game's own PawnCPP:removeLogEntry and then the game's own updateLogUI, so the
-- list on screen follows in the same frame (removal alone left a line on screen for seconds: 0.2.4 re-check, 06:27:10
-- to 06:27:16). Measured lane 66 run 4 with the other way (keep this copy's own line when it comes within 0.9 s, else
-- the host's): the own line often came later than that, and both stood for 1.5 s; each copy sees armies, squads and
-- finished sites at its own moment, so waiting for it can never be exact.
-- This copy's own "enemy_squad_spotted" also drops its game speed (updateSquadVisibility calls SetGameSpeed): the speed
-- watcher in coop.lua is told (S.spotT) before the line is taken out, so the drop is never sent as the player's.
-- (lane 66, real-click re-check of 0.2.4) the drawn line. Taking an entry out of the lord's list and updateLogUI did not
-- take its line off the screen (two lines for 2 to 6 s): each drawn notice is its own widget, LogEntry_C (in the HUD's
-- notice box), which holds a copy of its entry and has its own Remove / RemoveWithAnimation. So the widget that shows
-- the taken-out entry is removed too, with its own Remove, in the same tick. The widget's entry is found by the type of
-- its field (a struct property of the struct LogEntry), read once per class.
local LOGW_FIELD
local function logWidgetField(w)
  if LOGW_FIELD ~= nil then return LOGW_FIELD or nil end
  LOGW_FIELD = false
  pcall(function()
    local cls = w:GetClass()
    while cls and cls:IsValid() and not LOGW_FIELD do
      cls:ForEachProperty(function(p)
        if LOGW_FIELD then return end
        local okS, sn = pcall(function() return p:GetStruct():GetFName():ToString() end)
        if okS and sn == "LogEntry" then LOGW_FIELD = p:GetFName():ToString() end
      end)
      local ok, sup = pcall(function() return cls:GetSuperStruct() end)
      if not ok or not sup or not sup:IsValid() then break end
      cls = sup
    end
  end)
  log("realm: the notice widget's entry field is %s", tostring(LOGW_FIELD))
  return LOGW_FIELD or nil
end
-- the drawn notice widgets (on screen: a parent) as { w = widget, e = its entry }
local function drawnLines()
  local t = {}
  for _, w in ipairs(FindAllOf("LogEntry_C") or {}) do
    if valid(w) then
      local okP, on = pcall(function() local p = w:GetParent(); return p ~= nil and p:IsValid() end)
      if okP and on then
        local f = logWidgetField(w)
        local e; if f then pcall(function() e = w[f] end) end
        t[#t + 1] = { w = w, e = e }
      end
    end
  end
  return t
end
R.drawnLines = drawnLines
-- take the drawn line of entry e off the screen with the widget's own Remove; returns how many
local function removeDrawn(e)
  local key = logKey(e)                                  -- Remove may erase e from the lord's array
  local n = 0
  for _, d in ipairs(drawnLines()) do
    if valid(d.w) and d.e and logKey(d.e) == key then
      local ok = pcall(function() d.w:Remove() end)
      if ok then n = n + 1 end
    end
  end
  return n
end
local function ownLocalPrune(S, clock)
  local P = rawget(C, "patch")
  if not (P and P.nlOn == true and R.on.notices and valid(S.p1)) then return end
  -- A join can deliver the list before the HUD can draw it. The game leaves
  -- those entries undisplayed until its next refresh, even while paused.
  if R.pendingLogDraw then
    R.pendingLogDraw = nil
    local pending = S.p1.log
    for i = 1, #pending do
      if not pending[i].IsDisplayed then
        R.pendingLogDraw = true
        S.p1:updateLogUI()
        break
      end
    end
  end
  local la = S.p1.log; local n = #la
  if not R.pruneBase then                              -- the first look in this world: what the loaded list holds (the
    R.pruneBase = true                                 -- host's save) stays; only what comes after is judged
    for i = 1, n do local ok, k = pcall(logKey, la[i]); if ok then R.relayed[k] = true end end
    return
  end
  local out = 0
  for i = n, math.max(1, n - 29), -1 do
    local e = la[i]
    if isLocalKind(e) then
      local ok, k = pcall(logKey, e)
      if ok and not R.relayed[k] then
        local text = e.LogText:ToString()
        if text:find("enemy_squad_spotted", 1, true) then S.spotT = os.clock(); S.spGameWhy = "enemy squad spotted" end
        -- the drawn line first (the widget's own Remove), then the entry: found again by its key, because the widget's
        -- removal may already have changed the list (an entry read before is then another one)
        local drawn = removeDrawn(e)
        local okR, eR = true, "gone with its line"
        local la2 = S.p1.log; local n2 = #la2
        for j = n2, math.max(1, n2 - 29), -1 do
          local okK, k2 = pcall(logKey, la2[j])
          if okK and k2 == k then local e2 = la2[j]; okR, eR = pcall(function() S.p1:removeLogEntry(e2) end); break end
        end
        out = out + 1; R.stats.ownOut = (R.stats.ownOut or 0) + 1; R.stats.ownDrawnOut = (R.stats.ownDrawnOut or 0) + drawn
        log("realm: notice %s of this copy's own game taken out (%s; %d drawn line(s) removed); the host's line is the one shown", text, okR and "ok" or ("FAILED " .. tostring(eR)), drawn)
        break                                           -- the list changed: one at a time, the next one at the next look
      end
    end
  end
  if out > 0 then pcall(function() S.p1:updateLogUI() end) end
  -- A local dismissal or an inline writer of any other kind can change the
  -- count without going through NOLOG. Ask for the current list once.
  if R.expectedLogN then
    local entries = S.p1.log; local count = #entries
    if count ~= R.expectedLogN or (count == 100 and not R.relayed[logKey(entries[count])]) then
      R.askWorld = nil; R.expectedLogN = nil
    end
  end
end
local function logSig(e) return e.Tag:ToString() .. "|" .. logKey(e) end
local hostLogAll
local function logPoll(S)
  if not valid(S.p1) then return end
  local arr = S.p1.log; local n = #arr
  local last = n > 0 and logSig(arr[n]) or ""
  if not R.logN then R.logN = n; R.logLast = last; return end          -- first look in this world: nothing is new
  if n == R.logN and last == R.logLast then return end
  local from
  if n >= R.logN then
    if R.logN == 0 or logSig(arr[R.logN]) == R.logLast then
      from = R.logN + 1
    elseif n == 100 then                                -- at the cap the oldest entries fall off
      for i = n - 1, 1, -1 do
        if logSig(arr[i]) == R.logLast then from = i + 1; break end
      end
    end
  end
  if not from then                                       -- a dismissal or replacement needs a full list
    R.logN = n; R.logLast = last
    for _, serial in pairs(R.logSubscribers) do hostLogAll(S, serial) end
    return
  end
  for i = from, n do
    local e = arr[i]
    local x, y, z = 0, 0, 0; pcall(function() x, y, z = e.Location.X, e.Location.Y, e.Location.Z end)
    -- (lane 66) the 12th word: the notice's actor, a building by its key ("-": none)
    A.send(string.format("R LOG %s %s %s %d %.0f %.0f %.0f %s", enc(e.Tag:ToString()), enc(e.LogText:ToString()), enc(e.fullDescr:ToString()) .. "-", e.opensMenu, x, y, z, actorKey(e)))
    R.stats.notices = (R.stats.notices or 0) + 1
  end
  R.logN = n; R.logLast = last
end

-- ---- the host's whole notice list after a join, reload or change to existing rows
-- A load keeps none of the lord's notices (a copy that has just loaded holds only what came after: lane 64 a1, lane 66
-- run 1), so a friend that joined or reloaded lacked every notice the host had before (lane 64: host 23, friend 19).
-- The friend asks (R LOGASK) once per world while NOLOG is on; the host first sends what its poll has not sent yet, then
-- its whole list in order: R LOGALL <serial> <i> <n> <tag> <text> <descr> <opens> <x> <y> <z> <actor> <time> <day>,
-- ended by R LOGEND <serial> <n>. The friend applies it all or nothing when every line has come: its own list is
-- emptied (every entry and its drawn line), then the host's entries are added in order, each through the mod's mark,
-- with the alert sound held (the lord's DT_Alerts, the table playAlertFromTag reads, is empty for those calls only:
-- with no table the routine plays nothing). Both HUDs refresh from the active list. Dismissing a row removes its
-- entry from the lord's log. The restored widgets must be built after the entries have their host times and days.
hostLogAll = function(S, serial)
  if not valid(S.p1) then return end
  S.p1:updateLogUI()                                     -- draw pending entries on the authoritative HUD first
  local arr = S.p1.log; local n = #arr
  for i = 1, n do
    local e = arr[i]
    local x, y, z = 0, 0, 0; pcall(function() x, y, z = e.Location.X, e.Location.Y, e.Location.Z end)
    local okD, day = pcall(function() return e.DayOfTheYear end)
    A.send(string.format("R LOGALL %s %d %d %s %s %s %d %.0f %.0f %.0f %s %.3f %d", serial, i, n, enc(e.Tag:ToString()), enc(e.LogText:ToString()),
      enc(e.fullDescr:ToString()) .. "-", e.opensMenu, x, y, z, actorKey(e), e.Timestamp, okD and tonumber(day) or -1))
  end
  A.send(string.format("R LOGEND %s %d", serial, n))
  log("realm: the whole notice list (%d entries) sent for a friend's join or reload (%s)", n, serial)
end
local function friendLogApply(S, L)
  local P = rawget(C, "patch")
  if not (P and P.nlOn == true) then log("realm: the host's whole notice list came but NOLOG is not on here: not applied"); return end
  if L.n < 0 or L.n > 200 or L.got ~= L.n then
    log("realm: the host's whole notice list came incomplete (%d of %d): not applied", L.got, L.n)
    R.askWorld = nil
    return
  end
  for i = 1, L.n do if not L.items[i] then R.askWorld = nil; return end end
  local p1 = S.p1
  if not valid(p1) or not valid(S.eng) then return end
  while #p1.log > 0 do
    local la = p1.log; local n = #la
    p1:removeLogEntry(la[n])
    if #p1.log >= n then error("could not clear the local notice list") end
  end
  R.relayed = {}
  -- the host's entries in order, with the alert table held empty for these calls only
  local alerts = p1.DT_Alerts
  local added = 0
  local okAll, eAll = pcall(function()
    p1.DT_Alerts = nil
    for i = 1, L.n do
      local h = L.items[i]
      local actor = buildingByKey(S, h.actor)
      P.markLog(); p1:addLog(FName(h.tag), h.text, h.descr, h.opens, h.pos, actor)
      local la = p1.log; local n = #la
      if n ~= i then error("could not append notice " .. i) end
      local e = la[i]
      e.Timestamp = h.time
      if h.day >= 0 then e.DayOfTheYear = h.day end
      e.IsDisplayed = true
      R.relayed[logKey(e)] = true
      added = i
    end
    -- addLog may have drawn rows with the local clock. RemoveFromParent only detaches their widgets.
    -- LogEntry_C:Remove also erases the lord's matching record, invalidating a reference into the array.
    for _, d in ipairs(drawnLines()) do if valid(d.w) then d.w:RemoveFromParent() end end
    local la = p1.log
    for i = 1, #la do la[i].IsDisplayed = false end
    p1:updateLogUI()
  end)
  p1.DT_Alerts = alerts                                  -- the alert table back, whatever happened above
  log("realm: the host's whole notice list applied: %d of %d added with the host's time and day (%s)",
    added, L.n, okAll and "ok" or ("FAILED " .. tostring(eAll)))
  if not okAll then R.askWorld = nil; return end
  R.expectedLogN = L.n
  R.pendingLogDraw = L.n > 0
  R.stats.logAll = (R.stats.logAll or 0) + 1
end

-- did the town module replay an action on this region a moment ago? (its echo table, keyed by the object's address)
townReplayed = function(r)
  local Tn = C.town; local a = addr(r)
  local t = Tn and Tn.touched and a and Tn.touched[a]
  return t ~= nil and os.clock() - t < 1.5
end

local function fresh(S)
  if R.S == S and R.world == S.worlds and R.logSubscribers then return end
  R.S = S; R.world = S.worlds; R.logN = nil; R.logLast = nil; R.relayed = {}; R.pruneBase = nil; R.bCache = {}; R.logAll = nil
  R.logSubscribers = {}; R.askWorld = nil; R.logSerial = nil; R.expectedLogN = nil; R.pendingLogDraw = nil
  R.known = {}; R.want = {}; R.famHost = {}; R.gHost = {}; R.claimSent = {}; R.claimAck = {}; R.atkHost = {}; R.atkMine = {}; R.atkSince = {}; R.atkKeyT = nil; R.regions = nil; R.tPoll = 0; R.tKey = -1e9
end

local function poll(S, clock)
  R.regions = owned(S)
  local key30 = S.role == "host" and clock - R.tKey >= KEYFRAME
  if key30 then R.tKey = clock end
  for rk, r in pairs(R.regions) do
    for item, v in pairs(readRegion(r)) do
      local key = rk .. "|" .. item
      local w = R.want[key]
      if item == "fams" and S.role ~= "host" then          -- host -> friends only: a friend never reports its own list
        famCheck(S, rk, r, v, clock)
      elseif w then                                        -- a value this copy was told to take: wait for it, then judge
        if v == w.v then R.want[key] = nil
        elseif clock - w.t > VERIFY then
          R.want[key] = nil; R.stats.failed = R.stats.failed + 1
          log("realm: %s %s stayed %s, wanted %s", rk, item, v, w.v)
          if S.role == "host" then R.known[key] = v; A.send(string.format("R IS %s %s %s", rk, item, v))      -- the host's real value holds
          else R.stats.repairs = R.stats.repairs + 1; if C.join and C.join.requestRepair then C.join.requestRepair("realm " .. item) end end
        end
      else
        local k = R.known[key]
        if k == nil then R.known[key] = v                  -- first sight in this world: the loaded save is the host's
        elseif v ~= k then
          R.known[key] = v
          if S.role == "host" then A.send(string.format("R IS %s %s %s", rk, item, v)); R.stats.is = R.stats.is + 1; log("realm: local change %s %s %s -> %s", rk, item, tostring(k), v)
          elseif item:sub(1, 4) == "tax_" and townReplayed(r) then
            -- Tax changes are also carried by the town module (its hook on Region:changeTaxRate). A value that module
            -- just replayed here is the host's, not this player's: sending it back as this player's change could put
            -- an older rate over a newer one on the host when the host presses the tax button several times quickly.
            R.stats.echo = (R.stats.echo or 0) + 1
            log("realm: %s %s %s -> %s came with the host's town action: not sent back", rk, item, tostring(k), v)
          else A.send(string.format("R SET %s %s %s", rk, item, v)); R.stats.set = R.stats.set + 1; log("realm: local change %s %s %s -> %s", rk, item, tostring(k), v) end
        end
        if key30 then A.send(string.format("R IS %s %s %s", rk, item, R.known[key])) end
      end
    end
  end
  local okG, eG = pcall(pollGlobal, S, clock, key30)
  if not okG then R.lastErr = tostring(eG) end
  -- (lane 66) the host's notices are looked at ten times a second in M.tick (they were every 0.5 s here: a friend showed a
  -- notice up to a second after the host)
end

local M = {}
function M.onWorld(S) fresh(S) end
-- ---- (lane 79) a region's "under attack" flag (Region.isUnderAttack: keeps villagers at home, mutes the fire call)
-- The game sets it only when it recomputes it: at a squad's border crossing, a removal, a war or peace, a load, a
-- retreat, and its 50 s "villager stuck at home" rule. It is not recomputed when the last enemy squad is taken away:
-- in lane 79's run g both copies kept "under attack" with no enemy present (the host 3, 15 and 43 s), and each copy
-- cleared it at its own next recompute. The host's came when a rival's re-raised squads entered the region's list,
-- which the friend's list never gets (lane 79 report, case b), so the friend kept it 17 s longer than the host
-- (82 s in all). No reflected routine recomputes it (Region's functions: dumps/Region.txt). So the host tells its
-- flags, and a friend whose own flag has differed from the host's for over ATK_WAIT s takes the host's value (a
-- plain bool field; the friend's game may set it again at its own next recompute, which is then corrected again).
-- Host: every ATK_POLL s, the regions whose flag changed ("R ATK <tag>=<0|1>,..."), all of them every 30 s.
-- Switch: Coop.realm.on.attack = false (both sides).
local ATK_POLL, ATK_WAIT, ATK_KEY = 0.25, 1.0, 30.0
if R.on.attack == nil then R.on.attack = true end
R.atkHost = R.atkHost or {}; R.atkMine = R.atkMine or {}; R.atkSince = R.atkSince or {}
R.stats.atkWrites = R.stats.atkWrites or 0
local function atkRead(r) local ok, v = pcall(function() return r.isUnderAttack end); if ok and type(v) == "boolean" then return v end end
local function attackTick(S, clock)
  local arr = S.eng.regions; local n = #arr
  if S.role == "host" then
    local key = clock - (R.atkKeyT or -1e9) >= ATK_KEY
    if key then R.atkKeyT = clock end
    local out = {}
    for i = 1, n do
      local r = un(arr[i])
      if valid(r) then
        local k = rkey(r); local v = atkRead(r)
        if k and v ~= nil and (key or R.atkMine[k] ~= v) then R.atkMine[k] = v; out[#out + 1] = k .. "=" .. (v and "1" or "0") end
      end
    end
    if #out > 0 then A.send("R ATK " .. table.concat(out, ",")) end
    return
  end
  for i = 1, n do
    local r = un(arr[i])
    if valid(r) then
      local k = rkey(r); local h = k and R.atkHost[k]; local v = atkRead(r)
      if h == nil or v == nil or v == h then R.atkSince[k or "?"] = nil
      else
        R.atkSince[k] = R.atkSince[k] or clock
        if clock - R.atkSince[k] >= ATK_WAIT then
          local ok, e = pcall(function() r.isUnderAttack = h end)
          R.atkSince[k] = nil
          R.stats.atkWrites = R.stats.atkWrites + 1
          R.atkN = R.atkN or {}; R.atkN[k] = (R.atkN[k] or 0) + 1
          log("realm: %s under attack here %s, the host's %s for over %.1f s: the host's taken (%d in this region)%s", k, tostring(v), tostring(h), ATK_WAIT, R.atkN[k], ok and "" or (" FAILED " .. tostring(e)))
        end
      end
    end
  end
end

-- (lane 88) friend: the offer list looked at every 0.1 s, and the host's last list written at once when it differs.
-- A friend's own game rolls new offers at its own month change (run l88a: the host's list changed at +0.000 s, the
-- friend's own game rolled three other companies at +0.085 s, and the friend showed them until +3.9 s); the host's
-- new list arrives up to 0.5 s after the host's change. So the friend writes back the host's last list (which the
-- host had a moment ago) in the tick its own game changed it, and the host's new list in the tick after it arrives.
-- Left to the 0.5 s look (and its grace) while this player's own hire may be on its way (ownHireOnWay: this copy's
-- list got shorter at one of these looks by nobody's write of the mod, or the core has named the hired company). A
-- list that does not take is tried again after 2 s, not at every look.
local function mercHold(S, clock)
  local H = R.gHost and R.gHost.mercs
  if not (H and H.v) or clock - (R.mercT or -99) < 0.1 then return end
  R.mercT = clock
  if not mercCutOk() then return end
  local mine = mercsStr(S, nil, true)
  local n = recCount(mine)
  if R.mercPrevN and n < R.mercPrevN then R.mercDropT = clock end      -- shorter since the last look, and not by the mod
  if R.mercPrevS and mine ~= R.mercPrevS then R.mercOwnT = clock end   -- changed since the last look, and not by the mod
  R.mercPrevS = mine
  R.mercPrevN = n
  if mine == H.v then R.mercTry = nil; return end
  if ownHireOnWay(S, clock, mine, H.v) then return end
  local key = mine .. "/" .. H.v
  if R.mercTry and R.mercTry.k == key and clock - R.mercTry.t < 2.0 then return end
  R.mercTry = { k = key, t = clock }
  local ok, e = pcall(applyGlobal, S, "mercs", H.v)
  local after = mercsStr(S, nil, true)
  R.mercPrevN = recCount(after)                                         -- the mod's own write is no drop
  R.mercPrevS = after
  R.stats.mercHold = (R.stats.mercHold or 0) + 1
  if ok and after == H.v then H.since = nil; R.mercTry = nil else log("realm: the host's offers did not take at once (%s): the 0.5 s look follows", ok and "no error" or tostring(e)) end
end

-- (lane 88, round 2) the game's own roll of offers on a friend (its month change) is shown for one frame before the
-- next 0.1 s look writes the host's list back (66 ms, run p88a). If the game calls its roll through the script layer,
-- these hooks run in the same frame and write the host's list back at once. Registered once; each call is counted and
-- logged once, so a run shows whether the game's month roll passes here at all.
local function mercRollHooks(S)
  if R.mercHooked or S.role ~= "friend" then return end
  R.mercHooked = true
  for _, fn in ipairs({ "rerollMercenaries", "refillMercenaries" }) do
    local ok, e = pcall(RegisterHook, "/Script/ManorLords.RTSMultiEngineCPP:" .. fn, function()
      R.stats["mercRollHook_" .. fn] = (R.stats["mercRollHook_" .. fn] or 0) + 1
      if not R.mercRollSaid then R.mercRollSaid = true; log("realm: the game's %s passed the hook: the host's offers are written in the same frame", fn) end
      local S2 = C.s
      if S2 and S2.role == "friend" and R.on.mercs and not C.hold and not R.mercRolling then R.mercT = nil; pcall(mercHold, S2, os.clock()) end   -- (lane 87: not inside the mod's own roll)
    end)
    if not ok then log("realm: no hook on %s (%s)", fn, tostring(e)) end
  end
end

function M.tick(S, clock)
  fresh(S)
  pcall(mercRollHooks, S)                                  -- (lane 88, round 2)
  if C.hold then return end                                -- a join or repair is running
  if S.role == "friend" and R.on.mercs then local okM, eM = pcall(mercHold, S, clock); if not okM then R.lastErr = tostring(eM) end end   -- (lane 88)
  if R.on.attack and clock - (R.atkT or 0) >= ATK_POLL then R.atkT = clock; local okA, eA = pcall(attackTick, S, clock); if not okA then R.lastErr = tostring(eA) end end
  if clock - R.tPoll >= POLL then R.tPoll = clock; poll(S, clock) end
  if S.role == "host" and R.on.notices and clock - (R.tLog or 0) >= 0.1 then R.tLog = clock; local okL, eL = pcall(logPoll, S); if not okL then R.lastErr = tostring(eL) end end
  -- (lane 66) a friend asks once per world for the host's whole notice list, once NOLOG is on here
  if S.role == "friend" and R.on.notices and R.on.logAll and R.askWorld ~= S.worlds then
    local P = rawget(C, "patch")
    if P and P.nlOn == true then
      R.askWorld = S.worlds
      local serial = tostring(S.name) .. "." .. tostring(S.worlds) .. "." .. tostring(math.floor(os.clock() * 1000))
      R.logSerial = serial; R.logAll = nil
      A.send("R LOGASK " .. serial)
      log("realm: the host's whole notice list asked for (%s)", serial)
    end
  end
  if S.role == "friend" and clock - (R.tPrune or 0) >= 0.1 then R.tPrune = clock; local okP, eP = pcall(ownLocalPrune, S, clock); if not okP then R.lastErr = tostring(eP) end end   -- (lane 66)
end
-- ---- (lane 79) "no claim while enemy units are present", asked on the host
-- The map's region view (regionViewOverlay_C:updateRegionDetails) asks the region Region:areAnyEnemySquadsPresent and
-- switches both claim buttons off (by influence, by king's favour) while it is true, with the tooltip below. The rule
-- lives in that screen only: the game's layClaim does not ask again (lane 79: on the host, with raiders in the region
-- and the buttons off, layClaim still laid the claim). The host carries out a friend's claim through layClaim, so a
-- friend whose copy does not (yet) hold an enemy squad the host holds could lay a claim the host's screen forbids.
-- So the host asks its own game first. The region view's flag is read only for these two buttons (lane 79,
-- out/bp_enemiesPresent.txt: four reads, all in updateRegionDetails / updateOptionVisibility, for claim_inf and
-- claim_favour); no other friend action the host replays is switched off by it. A host player's own claim goes
-- through the game's screen as before.
local CLAIM_ENCAMPED = true                     -- includeEncamped, as the region view asks it (see the lane 79 report)
local CLAIM_ENEMY_TEXT = "Can't claim when enemy units are present"   -- the claim box's tooltip, the game's own words
local function claimForbidden(reg)
  local ok, v = pcall(function() return reg:areAnyEnemySquadsPresent(CLAIM_ENCAMPED) end)
  if not ok then
    -- the question could not be asked: the claim goes through as before (logged, so a run shows it)
    log("realm: the game's \"enemies present\" question failed (%s): the claim is not checked", tostring(v))
    return nil
  end
  if v == true then return CLAIM_ENEMY_TEXT end
  return nil
end
-- friend: the host refused this player's claim. Tell the player, and take the host's claims and the lord's influence
-- and favour at once (this copy's own layClaim already laid the claim and spent the favour or influence here); the
-- usual correction would come only after GRACE.
local function claimRefused(S, value, to, text)
  if to ~= S.name then return end
  local tag = tostring(value):match("^([^:]+)")
  local why = text and dec(text) or CLAIM_ENEMY_TEXT
  log("realm: the host refused this player's claim on %s: %s", tostring(tag), why)
  R.stats.refusedHere = (R.stats.refusedHere or 0) + 1
  local Lm = C.lord
  if tag then
    if Lm and Lm.claimHow then Lm.claimHow[tag] = nil end      -- not sent again by the 10 s rule
    R.claimSent[tag] = os.clock()
  end
  for _, item in ipairs({ "claims_P", "lord_P" }) do
    local H = R.gHost[item]
    if H and H.v then
      local ok, e = pcall(applyGlobal, S, item, H.v)
      if ok then H.since = nil else log("realm: after the refused claim, %s not taken from the host at once (%s): the usual correction follows", item, tostring(e)) end
    end
  end
  if C.notify then C.notify("refused", why) end
end

-- friend: the host laid this player's claim. From now on the host's list decides about it: the claim is no longer
-- "on its way" (claimPending), so a later change of the host's (a war that takes the claim) is followed after 1 s.
local function claimAccepted(S, value, to)
  if to ~= S.name then return end
  local tag = tostring(value):match("^([^:]+)")
  if not tag then return end
  local Lm = C.lord
  if Lm and Lm.claimHow then Lm.claimHow[tag] = nil end
  R.claimAck[tag] = os.clock()
  log("realm: the host laid this player's claim on %s", tag)
end

function M.onMessage(S, from, kind, w, line)
  if kind ~= "R" then return false end
  fresh(S)
  local verb, rk, item, value = w[4], w[5], w[6], w[7]
  if verb == "ATK" then                                     -- (lane 79) the host's "under attack" flags
    if S.role == "friend" and w[5] then for k, v in w[5]:gmatch("([^,=]+)=([01])") do R.atkHost[k] = (v == "1") end end
    return true
  end
  if verb == "LOGASK" then                                  -- (lane 66) a friend's join or reload: the whole list once
    if S.role == "host" and R.on.notices and w[5] then
      logPoll(S)
      R.logSubscribers[from] = w[5]
      local ok, e = pcall(hostLogAll, S, w[5]); if not ok then log("realm: whole notice list not sent: %s", tostring(e)) end
    end
    return true
  elseif verb == "LOGALL" or verb == "LOGEND" then
    if S.role ~= "friend" or not R.logSerial or w[5] ~= R.logSerial then return true end
    local L = R.logAll or { items = {}, n = -1, got = 0 }
    R.logAll = L
    if verb == "LOGALL" then
      local i, n = tonumber(w[6]), tonumber(w[7])
      if i and n and i >= 1 and i <= n and n <= 200 and not L.items[i] then
        L.n = n; L.got = L.got + 1
        L.items[i] = { tag = dec(w[8] or ""), text = dec(w[9] or ""), descr = dec(((w[10] or "-"):gsub("%-$", ""))), opens = tonumber(w[11]) or 0,
          pos = { X = (tonumber(w[12]) or 0) + 0.0, Y = (tonumber(w[13]) or 0) + 0.0, Z = (tonumber(w[14]) or 0) + 0.0 },
          actor = w[15] or "-", time = tonumber(w[16]) or 0, day = tonumber(w[17]) or -1 }
      end
    else
      L.n = tonumber(w[6]) or L.n
      R.logAll = nil
      local ok, e = pcall(friendLogApply, S, L)
      if not ok then R.askWorld = nil; log("realm: the host's whole notice list not applied: %s", tostring(e)) end
    end
    return true
  end
  if verb == "LOG" then
    if S.role == "friend" and R.on.notices and valid(S.p1) and w[5] and w[6] and w[7] then
      local tag, text, descr = dec(w[5]), dec(w[6]), dec((w[7]:gsub("%-$", "")))
      local pos = { X = (tonumber(w[9]) or 0) + 0.0, Y = (tonumber(w[10]) or 0) + 0.0, Z = (tonumber(w[11]) or 0) + 0.0 }
      local P = rawget(C, "patch")
      local nl = P and P.nlOn == true
      local opens, akey = tonumber(w[8]) or 0, w[12] or "-"
      local ok, e = pcall(function()
        if nl then
          -- (lane 66) NOLOG on: this copy has no notice of its own (the kinds its game adds by itself are taken out by
          -- ownLocalPrune), the host's line is the only one. addLog, not addLogIfNew, so that two equal notices of the
          -- host in the same moment are two here too; the mark lets exactly this call into the game's routine; the
          -- actor (the name in brackets, the click target) by its key
          addHostLine(S, P, { tag = tag, text = text, descr = descr, opens = opens, pos = pos, actor = akey })
          if R.expectedLogN then R.expectedLogN = math.min(100, R.expectedLogN + 1) end
        else
          S.p1:addLogIfNew(FName(tag), text, descr, opens, pos, buildingByKey(S, akey))
        end
      end)
      R.stats.notices = (R.stats.notices or 0) + 1
      if not ok then log("realm: notice %s / %s not added: %s", tag, text, tostring(e)) end
    end
    return true
  end
  if not (rk and item and value) then return true end
  if not R.regions then R.regions = owned(S) end
  if rk == "_" then                                          -- world-level values
    if S.role == "friend" and verb == "IS" then
      local H = R.gHost[item]; if not H then H = {}; R.gHost[item] = H end
      if H.v ~= value then H.v = value; if not (item == "claims_P" and H.since) then H.since = nil end end
      if item == "mercs" then local n = recCount(value); if n ~= R.mercHostN then R.mercHostN = n; R.mercHostNT = os.clock() end end   -- (lane 88)
    elseif S.role == "friend" and verb == "NO" and item == "claim" then
      claimRefused(S, value, w[8], w[9])
    elseif S.role == "friend" and verb == "OK" and item == "claim" then
      claimAccepted(S, value, w[8])
    elseif S.role == "host" and verb == "SET" and item == "claim" then
      local tag, how = value:match("^([^:]+):(%a)$")
      local reg = tag and regionByKey(S, tag)
      -- a region the lord already holds is never claimed from a message: the game itself would take the claim
      -- (lane 16, measured: layClaim on the own home region adds a claim of 14 days)
      local own = reg and valid(reg.ownerPawn) and addr(reg.ownerPawn) == addr(S.p1)
      local why = (reg and not own) and claimForbidden(reg) or nil
      if reg and own then log("realm: %s's claim on %s refused: the lord already holds that region", tostring(from), tag)
      elseif why then
        -- (lane 79) the region view's own rule, asked on the host's game: the friend is told in the game's words
        log("realm: %s's claim on %s with %s refused: %s (the host's game: enemy units of the region's owner stand in it)",
          tostring(from), tag, how == "f" and "king's favour" or "influence", why)
        A.send(string.format("R NO _ claim %s:%s %s %s", tag, how or "i", tostring(from), enc(why)))
        R.stats.refused = (R.stats.refused or 0) + 1
      elseif reg and not claimTags(claimsStr(S.p1))[tag] then
        local ok, e = pcall(function() S.p1:layClaim(reg, how == "f", true) end)
        log("realm: %s lays a claim on %s with %s%s", tostring(from), tag, how == "f" and "king's favour" or "influence", ok and "" or (" FAILED " .. tostring(e)))
        if ok then A.send(string.format("R OK _ claim %s:%s %s", tag, how or "i", tostring(from))) end   -- (lane 79) the sender's claim is the host's now
        if ok and C.panels and C.panels.touched then pcall(C.panels.touched, "R:claim", nil) end   -- (lane 69) open panels redraw
      end
    end
    return true
  end
  local key = rk .. "|" .. item
  if S.role == "host" and verb == "SET" then
    local r = R.regions[rk]
    if item == "policy" and valid(r) and not policyFits(r, value) then      -- two players signed in the same moment: the host's list holds
      local cur = readRegion(r).policy or "none"
      log("realm: from %s %s policy %s refused (more than the region's policy slots); the host keeps %s", tostring(from), rk, value, cur)
      A.send(string.format("R IS %s %s %s", rk, item, cur)); R.stats.is = R.stats.is + 1
      return true
    end
    take(S, key, rk, item, value, "from " .. tostring(from))
    A.send(string.format("R IS %s %s %s", rk, item, value)); R.stats.is = R.stats.is + 1
  elseif S.role == "friend" and verb == "IS" then
    if item == "fams" then
      R.famHost = R.famHost or {}
      local H = R.famHost[rk]; if not H then H = {}; R.famHost[rk] = H end
      if H.v ~= value then H.v = value; H.since = nil end
    else take(S, key, rk, item, value, "host says") end
  end
  return true
end

function R.status()
  local n = 0; for _ in pairs(R.known or {}) do n = n + 1 end
  local s = R.stats
  return string.format("realm: %d values watched, sent set %d / is %d, applied %d, failed %d, repairs %d", n, s.set, s.is, s.applied, s.failed, s.repairs)
end

-- what the lord module (coop_x_lord.lua) uses
R.api = { addr = addr, rkey = rkey, lords = lords, lordCode = lordCode, regionByKey = regionByKey, claimsStr = claimsStr, claimTags = claimTags, enc = enc, dec = dec }

C.register("realm", M)
return "coop realm module loaded"
