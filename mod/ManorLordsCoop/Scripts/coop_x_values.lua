-- Manor Lords Co-op: per-building values a panel shows that each copy's own game rolled or worked out, on the host's
-- word (lane 71; plug-in module "values", message kind "HW", host -> friends only). Loaded by coop_x_fields.lua (its
-- last lines). Re-loadable: state in Coop.values. Native side: native/coop_patch/coop_rolls.h (COLLAPSE, SITEHP).
--
-- 1. A building's collapse (a mine's daily roll, docs/coverage/values.tsv V084 V085). Read in the game file: each copy's
--    TemporalComponent::updateDay rolls GetCollapseChance against rand() per building and calls collapseBuilding, which
--    may kill a unit inside (a second roll), turns the building into a ruin (type 75) and lets its families go. So a mine
--    collapsed on one copy only; the building lists then differed and a resync followed.
--      host    COLLAPSE WATCH: every collapse of the host's game is noted by the native piece (collapse_out.txt) and
--              sent as "HW C <bkey>" (the key of the building as it was: a ruin keeps its old type in the key).
--      friend  COLLAPSE ON while the host is heard: every collapse this copy's game starts is stopped at the routine's
--              entry (its roll, a cheat, a unit), and the death roll inside is switched off. "HW C" runs the host's
--              collapse here with the game's own routine (COLLAPSE DO); the host's death comes with its family lists.
--              Nothing from the host for cfg.stale s: COLLAPSE OFF (this copy's game rolls again, as before the mod).
-- 2. A site's construction bar between 0 and 1 (V004). The bar is half the delivered goods (the host's already: GOODS)
--    and half its parts' hp (each copy's own builders; NOFINISH holds only the end).
--      host    SITEHP WATCH for every site of the sites module's list (all owners), POLL every cfg.pollEvery s: the work
--              fraction of each that changed is sent as "HW P <bkey>=<fraction>;..." (and "<bkey>=-" when a site left
--              the host's list); every site again every cfg.fullEvery s and after a join or resync.
--      friend  SITEHP HOLD <site> <fraction>: the native piece keeps this copy's parts' hp at the host's fraction every
--              tick; dropped when the site is built here or the host no longer names it.
--      (lane 87, step 2) The fraction is the host's to the last bit. Before: the host's POLL reported a fraction when
--      it had moved by 0.0005, it travelled with four decimals, and HOLD left a difference under a thousandth of the
--      max alone: a friend's bar was a number the host did not show in 101 of 1,882 readings at three decimals (run
--      p87a) and stood across a rounding edge for days (session l7b: 0.7 on the host, 0.8 here). Now POLL reports
--      every change of the bits of the fraction, the line carries the float itself (nine digits: a
--      float32 comes back bit for bit) and a friend holds with SITEHP HOLDX, which fills the parts in list order as
--      the game's own builders do until the game's own sums give those bits (cfg.exact = false, or a native piece
--      without HOLDX: the old HOLD).
--      (lane 87) Every site is named to the native piece again every cfg.nameEvery s (host: WATCH; friend: HOLD with
--      the fraction wanted). The native piece drops a site whose part list it does not take (before 0.9.13: more than
--      64 parts, which a church, a manor, a tavern and a large house have: such a site was never followed) or that
--      was not sane at one look; it says so only in its count "gone", and this module named a site once. Naming a
--      site the native piece still holds changes nothing there. An address is named only when it is an unfinished
--      building of the game's list in this tick (the native building table of this frame, else a walk of the list).
-- 3. The daily maintenance roll (4cfacc0, in the same loop of updateDay as the collapse roll): a well kept building
--    changes its lord's influence; an unmaintained one rolls a work accident for a worker at it (1 in 100 a death, else
--    an injury and its notice). Lane 64's NODEATH stops the accident's call on a friend; the influence change and the
--    injury notice were each copy's own.
--      host    MROLL WATCH: every accident of the host's game is noted (accident_out.txt); an injury is sent as "HW J
--              <bkey>" (a death goes by lane 64's E PD line, with its own notice).
--      friend  MROLL ON while the host is heard: the daily roll returns at once here (no roll, no accident, no influence
--              change of this copy: influence is the host's number, the injured mark the facts module's). "HW J" gives
--              the player the game's own injury notice for a building of his own (PawnCPP:addLog, as the accident does).
-- 4. Births, new families, sickness (native FAMROLL, coop_rolls.h). Each copy's growPopulation makes a person (and on
--    some days a family) at its own day change, with a name and looks of its own; each copy's daily step rolls a
--    family's sickness. The host's growth already travels (the people module's V G lines; a friend makes what its game
--    did not; the events module gives the names) and the sickness mark (the facts module).
--      friend  FAMROLL ON while the host is heard and the people module makes the host's growth here: growPopulation's
--              two calls of the person maker return at once (no person, no family of this copy's own), and the sickness
--              roll never makes a family sick here. Nothing new is sent.
-- Messages (after the core's "<seq> <wallclock> "):
--   HW X <collapse 1|0> <sitehp 1|0> <mroll 1|0>   the host's native piece can (sent every cfg.announceEvery s)
--   HW J <bkey>                           (3.) a worker of that building was injured on the host (a work accident)
--   HW C <bkey>                           the host's building collapsed
--   HW CF <bkey> 1                        the host observed finished rubble: a friend finishes the same ruin (FINISH)
--   HW P <bkey>=<fraction|->;...          the host's sites' work fractions
local C = rawget(_G, "Coop")
if type(C) ~= "table" or type(C.register) ~= "function" or type(C.api) ~= "table" then return "coop_x_values: load coop.lua first" end
local A = C.api
local un, valid = A.un, A.valid
local V = C.values or {}
C.values = V
V.version = "0.2"
V.cfg = V.cfg or {}
for k, v in pairs({ announceEvery = 5.0, stale = 30.0, lookEvery = 2.0, readEvery = 0.25, pollEvery = 0.5, fullEvery = 10.0,
                    applyEvery = 0.5, replayWait = 15.0, logEvery = 60.0, ruinHold = 1.0, nameEvery = 10.0, exact = true,
                    factsFresh = 3.0 }) do if V.cfg[k] == nil then V.cfg[k] = v end end
V.stats = V.stats or {}
V.t = V.t or {}
V.cf, V.finishRuins = {}, {}
local function log(fmt, ...) A.log("values: " .. fmt, ...) end
local function bump(k, n) V.stats[k] = (V.stats[k] or 0) + (n or 1) end
local function patch() local p = rawget(C, "patch"); if p and p.fn then return p end end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); if ok then return a end end
local function item(name)
  local p = patch(); if not p then return nil end
  local ok, st = pcall(p.status); if not ok or not st or st.state ~= "ready" then return nil end
  return st.items and st.items[name]
end
local function usable(name) local it = item(name); return it ~= nil and it.state ~= "unavailable" end
local function bkey(b)
  local W = rawget(C, "world")
  if W and W.bkey then return W.bkey(b) end
  local l = b:K2_GetActorLocation()
  return string.format("%d@%d,%d", A.btype(b), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5))
end
-- this copy's building of a key: the world module's index first (on a friend in exact mode it may never be built), then
-- the town module's finder (its index, then a live look through the engine's list), as the job board finds buildings
local function byKey(k)
  local W = rawget(C, "world")
  if W and W.buildingByKey then local ok, b = pcall(W.buildingByKey, k); if ok and b then return b end end
  local t, x, y = (k or ""):match("^(%d+)@(%-?%d+),(%-?%d+)$")
  local T = rawget(C, "town")
  if t and T and T.findB then local ok, b = pcall(T.findB, tonumber(t), tonumber(x) * 10, tonumber(y) * 10, 20); if ok and b and valid(b) then return b end end
end
local function busy() return rawget(C, "hold") or (C.join and C.join.state) end
local function send(line) A.send(line); bump("sent") end
local function bits(f) return (string.unpack("<I4", string.pack("<f", f))) end
local function float(u) return (string.unpack("<f", string.pack("<I4", u))) end
-- a file the native piece appends to: read once, then gone
local function take(name)
  local p = patch(); if not p then return nil end
  local f = io.open(p.dir .. name, "rb"); if not f then return nil end
  local text = f:read("a") or ""; f:close(); os.remove(p.dir .. name)
  return text
end
-- a building of this copy by its address (a rare look: a collapse)
local function byAddr(S, a)
  local arr = S.eng.buildingArr
  local n = #arr
  for i = 1, n do local b = un(arr[i]); if valid(b) and addr(b) == a then return b end end
end

-- (lane 87) is this address an unfinished building of the game's list in THIS tick, in a region? By the native building
-- table of this frame (coop_snap.lua: every record is an object the engine's own list proved alive at the frame's
-- start), else by a walk of the game's list (its length read first). An address is named to SITEHP only after this.
-- A building without a region is never named: the native piece refuses it (a resource spot, type 85, is unfinished for
-- ever and has none; named again every 10 s it was refused again every time: run p87c, the host's "gone" count at 88
-- after two minutes).
local function siteNow(S, a)
  local N = rawget(C, "snap")
  if N and N.buildings and N.building and N.buildings() then
    local r = N.building(a)
    return r ~= nil and r.cons == false and type(r.reg) == "number" and r.reg ~= 0
  end
  local arr = S.eng.buildingArr
  local n = #arr
  for i = 1, n do
    local b = un(arr[i])
    if valid(b) and addr(b) == a then
      local ok, good = pcall(function() return b.Data.constructed == false and valid(b.Region) end)
      return ok and good == true
    end
  end
  return false
end
V.siteNow = siteNow
-- (lane 87, run p87d) is the building at this address unfinished in the game itself, in this tick? The native table
-- is read ten times a second (coop_snap.lua), so a building finished in the last 0.1 s still reads "unfinished" there,
-- while SITEHP POLL reads the parts themselves. Run p87d: the host sent the fraction 1 of a building finished in that
-- tick three times; a friend held it and its site read 1.0 for up to 0.9 s where the host's went from 0.997 straight
-- to finished (3@9011,7790: three readings that the host never had). The building of this tick's list at that
-- address (the table's record: the engine's list at its place, the address compared; else a walk of the list, its
-- length read first), then its own word.
local function unfinishedNow(S, a)
  local N = rawget(C, "snap")
  local b = nil
  if N and N.building and N.obj then local r = N.building(a); if r then b = N.obj(r) end end
  if not b then
    local arr = S.eng.buildingArr
    local n = #arr
    for i = 1, n do local x = un(arr[i]); if valid(x) and addr(x) == a then b = x; break end end
  end
  if not (b and valid(b)) then return false end
  local ok, c = pcall(function() return b.Data.constructed end)
  return ok and c == false
end
-- (lane 87, cure 1) the building at this address in THIS tick, from the game's own list: the native table's record and
-- its object (N.obj: the list's place, the address compared), else a walk of the list (its length read first). Never a
-- handle of an earlier tick.
local function objNow(S, a)
  local N = rawget(C, "snap")
  if N and N.building and N.obj and N.buildings and N.buildings() then
    local r = N.building(a)
    if r then local b = N.obj(r); if b and valid(b) and addr(b) == a then return b end end
  end
  local arr = S.eng.buildingArr
  local n = #arr
  for i = 1, n do local x = un(arr[i]); if valid(x) and addr(x) == a then return x end end
end
-- (lane 87, cure 1) a site as the sites module counts one, by the building's own word in this tick (the native table
-- is up to 0.1 s old: an upgrade begun since still reads "finished" there): unfinished, not burning, not rubble, in a
-- region
local function siteByWord(b)
  local ok, good = pcall(function() return b.Data.constructed == false and not b.onFire and not b:IsRubble() and valid(b.Region) end)
  return ok and good == true
end
-- (lane 87, cure 1) is this address a site of this tick? As siteNow, and also when the table (up to 0.1 s old) still
-- shows it finished while the building itself says it is a site now (an upgrade begun since the table was read)
local function siteLive(S, a)
  if siteNow(S, a) then return true end
  local N = rawget(C, "snap")
  if not (N and N.building and N.buildings and N.buildings()) then return false end
  if N.building(a) == nil then return false end
  local b = objNow(S, a)
  return b ~= nil and siteByWord(b)
end

-- (run b) did the accident hurt its worker? The routine returns early when the worker is not at the building (READ:
-- 4db9ca6, a place test): then nothing happened. The worker's family (the one whose members hold him) has its injured
-- mark set when it did.
local function injuredHere(b, ua)
  local ok, res = pcall(function()
    local fams = b.Region.workerFamilies; local n = #fams
    for i = 1, n do
      local F = fams[i]; local m = F.familyMembers; local nm = #m
      for j = 1, nm do local u = un(m[j]); if valid(u) and addr(u) == ua then local x = F.ConsumptionStatus.injured; return x == true or (type(x) == "number" and x > 0) end end
    end
    return false
  end)
  return ok and res == true
end

-- ---------------------------------------------------------------- host
-- SITEHP POLL now: the fraction of every watched site whose bits changed since the native piece's last report, into
-- V.frac (the others keep theirs). At most once a tick: a second ask in the same tick changes nothing.
local function pollNow(p)
  local n = (C.s and C.s.ticks) or os.clock()                -- the core's tick count
  if V.polledAt == n then return end
  V.polledAt = n
  p.send("SITEHP POLL"); p.tick()
  V.frac = V.frac or {}
  for h, fb in (take("sitehp_out.txt") or ""):gmatch("(%x+) (%x+)") do
    local k = V.wa and V.wa[h:upper()]
    if k then local u = tonumber(fb, 16); V.frac[k] = (u == 0xFFFFFFFF) and -1 or float(u) end
  end
end
-- (lane 87, cure 3) the host's work fraction of this site in THIS tick, as its bits (a whole number), for the facts
-- module's entry of the same tick (coop_facts.lua: wq). nil when the site is not watched at that address or has no
-- fraction yet (a new site before its first POLL). One POLL a tick at most.
function V.fracNow(k, a)
  local S = C.s
  if not (S and S.role == "host") or not V.canSh then return nil end
  local p = patch(); if not p then return nil end
  if not (V.w and V.w[k] and (a == nil or V.w[k] == a)) then return nil end
  pollNow(p)
  local f = V.frac and V.frac[k]
  if type(f) ~= "number" or f < 0 or f > 1 then return nil end
  return bits(f)
end
local function hostTick(S, clock)
  local p = patch(); if not p then return end
  if clock - (V.t.look or -99) >= V.cfg.lookEvery then
    V.t.look = clock
    local it = item("COLLAPSE")
    if it and it.state ~= "unavailable" and it.state ~= "watch" then p.send("COLLAPSE WATCH"); p.tick(); log("collapses of this game are watched (COLLAPSE WATCH)") end
    if it and it.state == "unavailable" and not V.saidCl then V.saidCl = true; log("COLLAPSE unavailable here (%s): collapses are not sent", tostring(it.why)) end
    if not it and not V.saidOld then                                       -- an older native piece (no COLLAPSE item), or none ready
      local okS, st = pcall(p.status)
      if okS and st and st.state == "ready" then V.saidOld = true; log("the native piece has no COLLAPSE / SITEHP item (an older DLL): collapses and sites' work are not sent") end
    end
    V.canCl = it ~= nil and it.state ~= "unavailable"
    V.canSh = usable("SITEHP")
    local mr = item("MROLL")                                                -- (3.) the work accidents watched
    if mr and mr.state ~= "unavailable" and mr.state ~= "watch" then p.send("MROLL WATCH"); p.tick(); log("work accidents of this game are watched (MROLL WATCH)") end
    V.canMr = mr ~= nil and mr.state ~= "unavailable"
  end
  if clock - (V.t.announce or -99) >= V.cfg.announceEvery then
    V.t.announce = clock; send(string.format("HW X %d %d %d", V.canCl and 1 or 0, V.canSh and 1 or 0, V.canMr and 1 or 0))
  end
  if rawget(C, "hold") then V.wasHold = true; return end                 -- a join or resync: nothing is sent meanwhile
  if V.wasHold then V.wasHold = nil; V.sentF = {} end
  -- the host's collapses of the last ticks
  if V.canCl and clock - (V.t.read or -99) >= V.cfg.readEvery then
    V.t.read = clock
    local text = take("collapse_out.txt")
    for h, ty in (text or ""):gmatch("(%x+) (%-?%d+)") do
      local a = tonumber(h, 16)
      local b = a and byAddr(S, a)
      local ok, k = false, nil
      -- the key of the building as it was: its type noted by the native piece before the call (the collapse makes it a
      -- ruin, type 75), its place now (a collapse does not move it)
      ty = math.tointeger(tonumber(ty))
      if b and ty and ty > 0 and ty ~= 75 then
        ok, k = pcall(function() local l = b:K2_GetActorLocation(); return string.format("%d@%d,%d", ty, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5)) end)
      elseif b then ok, k = pcall(bkey, b) end
      if ok and k then send("HW C " .. k); bump("collapsesSent"); log("%s collapsed on the host: sent", k)
        V.cf[#V.cf + 1] = { k = k, a = a, t = clock }
      else bump("collapseUnnamed"); log("a collapse of the host's building %s that is no longer in the list: not sent", tostring(h)) end
    end
  end
  -- (3.) the host's work accidents: an injury is sent (a death goes by the events module's death line)
  if V.canMr and clock - (V.t.readA or -99) >= V.cfg.readEvery then
    V.t.readA = clock
    for hb, hu, died in (take("accident_out.txt") or ""):gmatch("(%x+) (%x+) (%d)") do
      local b = byAddr(S, tonumber(hb, 16))
      local ok, k = false, nil
      if b then ok, k = pcall(bkey, b) end
      if died == "1" then bump("accidentDeaths")
      elseif ok and k and injuredHere(b, tonumber(hu, 16)) then send("HW J " .. k); bump("injuriesSent"); log("a worker of %s was injured on the host: sent", k)
      elseif ok and k then bump("accidentNothing"); log("an accident at %s left its worker unhurt (not at the building): nothing sent", k)
      else bump("injuryUnnamed") end
    end
  end
  -- (run a1) a collapsed building's ruin, finished or not on the host a moment later: the game finishes the change to a
  -- ruin by its own construction call, which NOFINISH holds on a friend (there the ruin stayed an unfinished upgrade:
  -- wide bl 52@8780,7480 built 1/0, bw isBeingUpgraded 0/1)
  if V.cf and #V.cf > 0 then
    local keep = {}
    for _, c in ipairs(V.cf) do
      -- (lane 64, round 5) the building is found again in the game's list by its address at every look; the handle
      -- of the look before is not used (a kept handle may point at freed memory, and valid() is no proof of it)
      local b = byAddr(S, c.a)
      if b then
        if b:GetType() == 75 and b.Data.constructed then send("HW CF " .. c.k .. " 1"); bump("ruinSent")
        elseif clock - c.t < V.cfg.replayWait then keep[#keep + 1] = c end
      end
    end
    V.cf = keep
  end
  -- sites: their work fractions
  if not V.canSh then return end
  local B = rawget(C, "sites")
  -- (lane 87, cure 1) A NEW SITE OR AN UPGRADE BEGUN, NAMED, POLLED AND SENT IN ITS FIRST TICK. Session l87c: a rival's
  -- house upgrade appeared on the host at 398.960; the pass below names a site once a second from the sites module's
  -- list (itself once a second), so its work went out 2 s later, after the friend's upgrade had begun (399.802): the
  -- friend showed its own old parts full (0.5) where the host had 0.488. Now every unfinished record of the native
  -- table (this frame's, up to 0.1 s old) whose address is not watched is named, polled and sent in this tick. A
  -- finished building's address was dropped at its finish, so an upgrade's building is "not watched" again. An
  -- address tried here is tried again only at the nameEvery cadence (a record SITEHP refuses or the sites module never
  -- lists is not named and polled every tick).
  if V.cfg.firstTick ~= false and B and type(B.prev) == "table" then
    local N = rawget(C, "snap"); local recs = N and N.buildings and N.obj and N.buildings()
    if recs then
      V.w = V.w or {}; V.wa = V.wa or {}; V.tried = V.tried or {}; V.wT = V.wT or {}
      local named
      for _, r in ipairs(recs) do
        if r.cons == false and type(r.reg) == "number" and r.reg ~= 0 and clock - (V.tried[r.a] or -1e9) >= V.cfg.nameEvery then
          local h = string.format("%X", r.a)
          if V.wa[h] == nil then
            V.tried[r.a] = clock
            local b = N.obj(r)
            if b and valid(b) and addr(b) == r.a and siteByWord(b) then
              local okK, k = pcall(bkey, b)
              if okK and k and V.w[k] == nil then
                V.w[k] = r.a; V.wa[h] = k; V.wT[k] = clock
                p.send("SITEHP WATCH " .. tostring(r.a))
                named = named or {}; named[#named + 1] = k
              end
            end
          end
        end
      end
      if named then
        pollNow(p)
        V.sentF = V.sentF or {}
        local items = {}
        for _, k in ipairs(named) do
          local f = V.frac and V.frac[k]
          if f and f >= 0 and (f < 1 or unfinishedNow(S, V.w[k])) then
            local s = string.format("%.9g", f); V.sentF[k] = s; items[#items + 1] = k .. "=" .. s
          end
        end
        bump("firstTick", #named)
        if #items > 0 then send("HW P " .. table.concat(items, ";")); bump("fracSent", #items); bump("firstTickSent", #items) end
      end
    end
  end
  if clock - (V.t.watch or -99) >= 1.0 and B and type(B.prev) == "table" then
    V.t.watch = clock
    V.w = V.w or {}; V.wa = V.wa or {}
    -- (lane 87) every site named again every cfg.nameEvery s: one the native piece dropped is watched again
    local again = clock - (V.t.name or -99) >= V.cfg.nameEvery
    if again then V.t.name = clock end
    if again and V.tried then for a, t in pairs(V.tried) do if clock - t > 6 * V.cfg.nameEvery then V.tried[a] = nil end end end
    for k, b in pairs(B.prev) do
      local a = valid(b) and addr(b)
      if a and (V.w[k] ~= a or again) and siteNow(S, a) then
        if V.w[k] ~= a then
          local old = V.w[k] and string.format("%X", V.w[k])
          if old and V.wa[old] == k then V.wa[old] = nil end
          V.w[k] = a
        else bump("namedAgain") end
        V.wa[string.format("%X", a)] = k                      -- (lane 87, run p87e) also when named again: see below
        p.send("SITEHP WATCH " .. tostring(a))
      end
    end
    local gone = {}
    for k, a in pairs(V.w) do
      -- (lane 87, cure 1) a key named from the native table in its first tick is spared for 3 s while its address is a
      -- site of this tick: the sites module's own look comes once a second
      local spared = false
      if V.wT and V.wT[k] then
        if B.prev[k] then V.wT[k] = nil
        elseif clock - V.wT[k] < 3.0 and siteLive(S, a) then spared = true; bump("firstTickSpared")
        else V.wT[k] = nil end
      end
      if not B.prev[k] and not spared then
        V.w[k] = nil; gone[#gone + 1] = k .. "=-"; if V.sentF then V.sentF[k] = nil end
        -- (lane 87, run p87e) A building whose type changes while it is a site keeps its object and address under a new
        -- key (a rival's storehouse upgrade: 72@9200,7300 became 99@9200,7300 in one tick). When the sites module's
        -- look caught the old key, both keys were named on one address, and the old key's end dropped the address's
        -- watch and its map: the host never read or sent that site's work again (257 readings late, 64 s). An address
        -- another key still names is not dropped, and its map is that key's.
        local h, other = string.format("%X", a), nil
        for k2, a2 in pairs(V.w) do if a2 == a then other = k2 end end
        if other then
          V.wa[h] = other; bump("addrKept")
          -- POLL reports an address only when its fraction's bits moved, so the new key takes the old key's last
          -- fraction (the same parts), sent in this line beside the old key's end: a site that stands still at its
          -- change (waiting for goods) is not left unsent, and a friend's hold of that address never lapses
          local f0 = V.frac and V.frac[k]
          if f0 and V.frac[other] == nil then
            V.frac[other] = f0
            if f0 >= 0 and (f0 < 1 or unfinishedNow(S, a)) then
              local s0 = string.format("%.9g", f0)
              V.sentF = V.sentF or {}; V.sentF[other] = s0; gone[#gone + 1] = other .. "=" .. s0
            end
          end
        else p.send("SITEHP DROP " .. tostring(a)); V.wa[h] = nil end
      end
    end
    if #gone > 0 then send("HW P " .. table.concat(gone, ";")) end
  end
  if clock - (V.t.poll or -99) >= V.cfg.pollEvery and V.wa and next(V.wa) then
    V.t.poll = clock
    pollNow(p)
    local full = clock - (V.t.full or -99) >= V.cfg.fullEvery
    if full then V.t.full = clock end
    V.sentF = V.sentF or {}
    local items = {}
    for k, f in pairs(V.frac) do
      if not V.w[k] then V.frac[k] = nil
      -- (lane 87) a building that was finished since the sites module's last look is no site any more: its fraction (all
      -- parts full: 1) is not sent. Run p87c: a friend's site read 1.0 for a moment before it was finished, where the
      -- host's own site went from 0.998 straight to finished.
      -- (run p87d) A fraction of 1 (every part full: what a site reads in the tick of its finish) is sent only when the
      -- game itself says in this tick that the building is unfinished (a site whose goods are still missing).
      elseif f >= 0 and siteNow(S, V.w[k]) and (f < 1 or unfinishedNow(S, V.w[k])) then
        local s = string.format("%.9g", f)                     -- (lane 87) nine digits: the float itself (was four decimals)
        if full or V.sentF[k] ~= s then
          -- (lane 87, cure 3; session l87f) a fraction that moved: the facts module sends that site's entry (its goods and
          -- this work, wq) in its next tick, not at its pass's end. Under load a pass took up to 2 s, and its entries
          -- carried the work of when the pass had read the building: a friend that took the stock line's work stood up
          -- to 3.4 s behind a site its builders were working on (3@9692,7530: 9 readings late)
          if V.sentF[k] ~= s then local Fm = rawget(C, "facts"); if Fm and Fm.workSeen then pcall(Fm.workSeen, V.w[k]) end end
          V.sentF[k] = s; items[#items + 1] = k .. "=" .. s
        end
      end
    end
    for i = 1, #items, 40 do send("HW P " .. table.concat(items, ";", i, math.min(#items, i + 39))); bump("fracSent", math.min(#items, i + 39) - i + 1) end
  end
end

-- ---------------------------------------------------------------- friend
-- (lane 87) The sites module is about to finish this site here (the host's word). On the host a site is finished by
-- the stroke that fills its last part; here the parts stand at the host's last fraction as a site, and the hold of
-- this site would be applied once more after the FINISH of that native tick. SITEHP FILL (sent ahead of FINISH, the
-- commands of one tick run in order) sets every part to its max and ends the hold. a: the site's address, taken by
-- the sites module from the game's list in this tick.
function V.beforeFinish(k, a)
  local p = patch(); if not p or not a then return false end
  if not (V.fill and V.cfg.exact ~= false) then return false end     -- a native piece without FILL, or the old hold
  p.send("SITEHP FILL " .. tostring(a))
  if V.held then V.held[k] = nil end; if V.heldF then V.heldF[k] = nil end
  bump("fills")
  return true
end

local function shForget(why)
  local p = patch()
  if p and V.held and next(V.held) then p.send("SITEHP FORGET"); p.tick(); log("sites: their work is this copy's own again (%s)", why) end
  V.held = {}; V.heldF = {}
  V.bq = {}; V.fresh = {}
end
-- (lane 87, run p87e) is this address held under another key too? A site whose type changes keeps its object and
-- address under a new key (see the host's watch above); a hold is dropped only when no other key holds it
local function heldElse(k, a) for k2, a2 in pairs(V.held or {}) do if k2 ~= k and a2 == a then return true end end; return false end
-- (lane 87, cure 1) the host's fraction for key k held on the building b (address a) in THIS tick, the native tick at
-- once. b is the caller's, proved in this tick (the game's list, or the call that made it a site).
local function holdAt(S, p, k, b, a)
  local f = V.want and V.want[k]
  if f == nil or busy() or not usable("SITEHP") then return false end
  V.held = V.held or {}; V.heldF = V.heldF or {}; V.fresh = V.fresh or {}
  local hx = V.hx and V.cfg.exact ~= false
  local s = (hx and "x" or "") .. string.format("%.9g", f)
  if V.held[k] == a and V.heldF[k] == s then return false end
  if V.held[k] and V.held[k] ~= a and not heldElse(k, V.held[k]) then p.send("SITEHP DROP " .. tostring(V.held[k])) end
  p.send(string.format("SITEHP %s %s %08X", hx and "HOLDX" or "HOLD", tostring(a), bits(f))); p.tick()
  local first = V.held[k] == nil
  V.held[k] = a; V.heldF[k] = s; V.fresh[a] = os.clock()
  bump("holds")
  if first and V.cfg.logFirst ~= false then log("%s held at %s in its first tick here (%s)", k, s, V.holdWhy or "?") end
  return true
end
-- (lane 87, cure 1) AN UPGRADE BEGUN HERE (the people module's doUpgrade for a rival's, the town module's UPGRADE, EXT
-- and ARTISAN for a player's), called right after the game's call, with the building of that call. Session l87c: the
-- friend began a rival's house upgrade at 399.802 and showed its own old parts full (0.5) until the host's fraction
-- was held at 400.554 (the host's: 0.488). When the host's fraction for the building's key (after the call: an upgrade
-- can change the type) is here and the building is a site by its own word, it is held in this tick. Else its address
-- (never the handle) is looked at in every tick for 1.5 s (friendTick: the call can return before the building turns
-- unfinished; l87c: the watcher first saw it 0.22 s after the call).
function V.begun(b)
  if V.cfg.begun == false then return false end
  local S = C.s
  if not (S and S.role == "friend" and S.eng and valid(S.eng)) or not (b and valid(b)) or busy() then return false end
  local p = patch(); if not p then return false end
  local a = addr(b); if not a then return false end
  bump("begun")
  local site = siteByWord(b)
  if site then
    local okK, k = pcall(bkey, b)
    if okK and k and V.want and V.want[k] ~= nil then
      V.holdWhy = "the upgrade's call"
      if holdAt(S, p, k, b, a) then bump("begunAtOnce") end
      return true
    end
  end
  V.bq = V.bq or {}; V.bq[a] = { t = os.clock(), site = site }
  return false
end
-- (lane 87, cure 3) THE HOST'S WORK FRACTION FROM ITS STOCK LINE (coop_facts.lua: an entry's wq, held in the tick that
-- entry's goods are written here). The bar's two halves then come from one moment of the host. From then on HW P gives
-- way for that key (onMessage: its fraction is not taken while the facts module carries the key, cfg.factsFresh s;
-- its "-", the site's end, is). u: the fraction's bits.
function V.factsHold(k, u)
  if V.cfg.factsWork == false then return false end
  local S = C.s
  if not (S and S.role == "friend" and S.eng and valid(S.eng)) or busy() then return false end
  local p = patch(); if not p then return false end
  local okF, f = pcall(float, u)
  if not (okF and type(f) == "number" and f >= 0 and f <= 1) then return false end
  V.want = V.want or {}; V.want[k] = f
  V.fx = V.fx or {}; V.fx[k] = os.clock()
  bump("factsIn")
  local b = byKey(k)
  if not (b and valid(b)) then return false end
  local okC, built = pcall(function() return b.Data.constructed end)
  if not (okC and built == false) then return false end
  local a = addr(b); if not a then return false end
  if not siteLive(S, a) and not (V.fresh and V.fresh[a] and os.clock() - V.fresh[a] < 1.0) then return false end
  V.holdWhy = "the stock line"
  if holdAt(S, p, k, b, a) then bump("factsHeld") end
  return true
end
-- (lane 87, cure 3) the host's stock line said this site is finished (cn=1): HW P is taken again for that key
-- ... and when the stock line no longer carries the key ("<bkey>-": the building's type changed, it is gone, a site no
-- more). The latest HW P fraction that gave way meanwhile is taken then (session l87d: a house upgrade 3 to 8; the old
-- key's last held fraction stood at 0 while the host's HW P had said 1, and the friend's own upgrade, which passes the
-- old key later than the host's, was held at 0 under it: a bar the host never had for 0.28 s).
function V.factsEnd(k)
  if V.fx then V.fx[k] = nil end
  local f = V.hwLast and V.hwLast[k]
  if f ~= nil then
    V.hwLast[k] = nil; V.want = V.want or {}
    if f == "-" then V.want[k] = nil else V.want[k] = f end
    if V.t then V.t.apply = -99 end
    bump("factsHandBack")
  end
end
local function friendTick(S, clock)
  local p = patch(); if not p then return end
  local heard = V.hostT and clock - V.hostT < V.cfg.stale
  -- collapses: stopped here while the host is heard and can watch its own
  if clock - (V.t.look or -99) >= V.cfg.lookEvery then
    V.t.look = clock
    local it = item("COLLAPSE")
    -- (kept on through a join, resync or load: the hook only stops calls, and the world that comes is the host's)
    local want = heard and V.hostCl
    if it and it.state ~= "unavailable" then
      if want and it.state ~= "on" then p.send("COLLAPSE ON"); p.tick(); log("collapses happen here only on the host's word (COLLAPSE ON)")
      elseif not want and it.state == "on" then p.send("COLLAPSE OFF"); p.tick(); log("COLLAPSE OFF (%s)", heard and "the host cannot watch its own" or "nothing from the host") end
    elseif want and not V.saidCl then V.saidCl = true; log("COLLAPSE unavailable here (%s): this copy rolls its own collapses", it and tostring(it.why) or "no native piece") end
    V.clOn = it ~= nil and it.state == "on"
    local mr = item("MROLL")                                                -- (3.) the daily maintenance roll: the host's
    local wantMr = heard and V.hostMr
    if mr and mr.state ~= "unavailable" then
      if wantMr and mr.state ~= "on" then p.send("MROLL ON"); p.tick(); log("the daily maintenance roll is the host's here (MROLL ON)")
      elseif not wantMr and mr.state == "on" then p.send("MROLL OFF"); p.tick(); log("MROLL OFF (%s)", heard and "the host cannot watch its own" or "nothing from the host") end
    end
    V.mrOn = mr ~= nil and mr.state == "on"
    -- (lane 87) the mercenary month roll (NOROLL): this copy's own roll returns at once while the host is heard and the
    -- realm module follows the host's offers with the native cut (MERCCUT) and can grow its list by the game's own roll
    -- (P.noRollPass: needs this copy's own notices dropped, NOLOG). Then the offers change here only by the host's word,
    -- a load and this player's own hire. Switch: Coop.realm.on.noroll = false.
    local nr = item("NOROLL")
    local Rm, Pm = rawget(C, "realm"), patch()
    local wantNr = (heard and Rm and Rm.on and Rm.on.mercs and Rm.on.noroll ~= false and not Rm.mercNoCut
                    and Pm.mercAvail and Pm.mercAvail() and Pm.nlOn == true) and true or false
    if nr and nr.state ~= "unavailable" then
      if wantNr and nr.state ~= "on" then p.send("NOROLL ON"); p.tick(); log("this copy's own mercenary month roll is held: the offers are the host's (NOROLL ON)")
      elseif not wantNr and nr.state == "on" then p.send("NOROLL OFF"); p.tick(); log("NOROLL OFF (%s)", heard and "the realm module does not follow the host's offers here" or "nothing from the host") end
    end
    V.nrOn = nr ~= nil and nr.state == "on"
    -- (lane 87, the bar's cure 2) BARNAN: a site of this copy with no parts yet reads its bar with no work done. The game
    -- gives 0/0, "not a number", for its first frames. Run p87g: a rival's new house held a part with no work in its
    -- first frame on the host (bar 0) and none on the friend, which read "not a number" for 0.079 s. On while the host is
    -- heard. Switch: Coop.values.cfg.barnan = false.
    local bn = item("BARNAN")
    local wantBn = (heard and V.cfg.barnan ~= false) and true or false
    if bn and bn.state ~= "unavailable" then
      if wantBn and bn.state ~= "on" then p.send("BARNAN ON"); p.tick(); log("a site with no parts yet reads its bar with no work done here (BARNAN ON)")
      elseif not wantBn and bn.state == "on" then p.send("BARNAN OFF"); p.tick(); log("BARNAN OFF (%s)", heard and "switched off" or "nothing from the host") end
    end
    V.bnOn = bn ~= nil and bn.state == "on"
    -- (4.) births, new families and sickness: the host's, while the people module makes what the host's game made (its
    -- V G lines: families, members, homes, also in rival towns) and the host is heard
    local fr = item("FAMROLL")
    local Pp = rawget(C, "people")
    local grows = Pp and Pp.on and Pp.on.grow and Pp.on.growRivals and Pp.on.families and Pp.on.members
    local wantFr = heard and grows and V.cfg.famroll ~= false and true or false   -- (cfg.famroll = false: the control run, this copy grows by itself)
    if fr and fr.state ~= "unavailable" then
      if wantFr and fr.state ~= "on" then p.send("FAMROLL ON"); p.tick(); log("births, new families and sickness are the host's here (FAMROLL ON)")
      elseif not wantFr and fr.state == "on" then p.send("FAMROLL OFF"); p.tick(); log("FAMROLL OFF (%s)", heard and "the people module does not make the host's growth here" or "nothing from the host") end
    end
    V.frOn = fr ~= nil and fr.state == "on"
    -- (lane 87) can this copy's native piece hold exactly? (its SITEHP line names "hx=" from lane 87's native piece on)
    local sh = item("SITEHP")
    V.hx = sh ~= nil and sh.state ~= "unavailable" and tostring(sh.why or ""):find("hx=", 1, true) ~= nil
    -- ... and fill a site's parts ahead of its finish (SITEHP FILL; its line names "fills="). Asked apart from "hx=": this
    -- module forgets its hold when it sends FILL, so a piece that refused FILL would hold a finished building for ever
    V.fill = V.hx and tostring(sh.why or ""):find("fills=", 1, true) ~= nil
    if not heard and V.held and next(V.held) then shForget("nothing from the host") end
  end
  if busy() then if V.held and next(V.held) then shForget("a join, resync or load") end; return end
  -- the host's collapses, replayed
  if V.q and #V.q > 0 and V.clOn then
    local keep = {}
    for _, c in ipairs(V.q) do
      local b = byKey(c.k)
      local done = false
      if b and valid(b) then
        local okT, raw = pcall(function() return b:GetType() end)
        local okF, fire = pcall(function() return b.onFire and true or false end)
        if okT and raw == 75 then done = true; bump("collapseAlready")
        elseif okT and okF and not fire and not V.finishRuins[c.k] and clock - c.t < V.cfg.ruinHold then
          -- (lane 64, 0.2.6) The collapse waits for the host's word that its ruin is finished (HW CF, 0.1 to 0.4 s after
          -- HW C; at most cfg.ruinHold s). Measured before: collapsed at once, this copy's game turned the mine into an
          -- UNFINISHED ruin (its own finishing call is held on a friend) and the mod finished it a tick later: for about
          -- 0.07 s a state the host never shows. Now the collapse and the finish run in one tick.
          bump("collapseHeld")
        elseif okT and okF and not fire then
          local a = addr(b)
          if a then
            p.send("COLLAPSE DO " .. tostring(a)); p.tick(); done = true; bump("collapsesDone"); log("%s collapsed on the host: collapsed here", c.k)
            if V.finishRuins[c.k] and p.finish then
              local okD, built = pcall(function() return b.Data.constructed end)
              if okD and built == false then
                local ok = p.finish(b)
                local okN, ty, con = pcall(function() return b:GetType(), b.Data.constructed end)
                -- (rl5: right after the two calls the building is still the mine, constructed again; this copy's game turns
                --  it into the FINISHED ruin at its next tick: the watch saw the built mine, then the finished ruin)
                if ok and okN and con == true then bump("ruinAtOnce"); log("%s: collapsed and finished here in one tick, as the host's ruin is finished (type %s now)", c.k, tostring(ty))
                else bump("ruinNotAtOnce"); log("%s: after the collapse and the finish in one tick: type %s constructed %s (finish %s): the later look finishes it", c.k, tostring(ty), tostring(con), tostring(ok)) end
              end
            end
          end
        end
      end
      if not done then
        if clock - c.t < V.cfg.replayWait then keep[#keep + 1] = c
        else bump("collapseLost"); log("%s collapsed on the host and is not here (or burning): left (a resync puts it right)", c.k) end
      end
    end
    V.q = keep
  elseif V.q and #V.q > 0 then                                            -- COLLAPSE not on here: a collapse is not kept for ever
    local keep = {}
    for _, c in ipairs(V.q) do if clock - c.t < V.cfg.replayWait then keep[#keep + 1] = c else bump("collapseLost"); log("%s collapsed on the host; COLLAPSE is not on here: left (a resync puts it right)", c.k) end end
    V.q = keep
  end
  -- The finish can arrive in the same batch as the collapse, before the local
  -- game has converted the mine to rubble. Keep it until that conversion lands.
  for k, at in pairs(V.finishRuins) do
    local b = byKey(k)
    if valid(b) and b:GetType() == 75 then
      if b.Data.constructed then V.finishRuins[k] = nil; bump("ruinSame")
      elseif p.finish then
        local ok, why = p.finish(b)
        if ok then V.finishRuins[k] = nil; bump("ruinFinished"); log("%s: the host's ruin is finished: finished here", k)
        elseif clock - at >= V.cfg.replayWait then log("%s: could not finish the host's ruin (%s)", k, tostring(why)) end
      end
    end
    if clock - at >= V.cfg.replayWait then V.finishRuins[k] = nil end
  end
  -- (lane 87, cure 1) an upgrade begun here (V.begun: the people module's or the town module's call) that was not a
  -- site yet in the call's tick, or had no word of the host then: looked at in every tick for 1.5 s by its address (the
  -- building found again in this tick's list), held in the first tick it is a site and the host's fraction is here
  if V.bq and next(V.bq) then
    for a, q in pairs(V.bq) do
      local b = objNow(S, a)
      if not b then V.bq[a] = nil; bump("begunGone")
      elseif siteByWord(b) then
        q.site = true
        local okK, k = pcall(bkey, b)
        if okK and k and V.want and V.want[k] ~= nil then
          V.holdWhy = "the upgrade, a later tick"
          if holdAt(S, p, k, b, a) then bump("begunLater") end
          V.bq[a] = nil
        end
      end
      if V.bq[a] and clock - q.t > 1.5 then V.bq[a] = nil; bump(q.site and "begunNoWord" or "begunNever") end
    end
  end
  -- (lane 87, cure 1) a building new in the game's list, in its first tick: the list's length is looked at in every
  -- tick, and walked when it changed (the native table below is up to 0.1 s old). A new site whose host fraction is
  -- here is held in this tick; its parts may not be made yet (0 parts: the native hold fills them from the tick
  -- they come).
  if V.hostSh and V.cfg.firstTick ~= false then
    local okN, n = pcall(function() return #S.eng.buildingArr end)
    if okN and type(n) == "number" and n ~= V.lastN then
      local first = V.lastN == nil
      V.lastN = n
      local arr = S.eng.buildingArr
      local known, new = {}, {}
      for i = 1, n do
        local x = un(arr[i])
        if valid(x) then local a = addr(x); if a then known[a] = true; if not first and not (V.knownA and V.knownA[a]) then new[#new + 1] = { a = a, b = x } end end end
      end
      V.knownA = known
      for _, e in ipairs(new) do
        if V.want and next(V.want) and siteByWord(e.b) then
          local okK, k = pcall(bkey, e.b)
          if okK and k and V.want[k] ~= nil then V.holdWhy = "new in the list"; if holdAt(S, p, k, e.b, e.a) then bump("newSiteAtOnce") end end
        end
      end
    end
  end
  -- (lane 87) a site that came into the game's list since the last tick is held in this tick when the host's fraction for
  -- it is here already (run p87c: an upgrade just begun here stood up to half a second at this copy's own fraction).
  -- New unfinished records of the native building table are looked at once each (their name by the game's own call).
  if V.hostSh and V.want and next(V.want) then
    local N = rawget(C, "snap"); local recs = N and N.buildings and N.buildings()
    if recs then
      V.seenA = V.seenA or {}
      if clock - (V.t.seen or -99) >= V.cfg.nameEvery then V.t.seen = clock; V.seenA = {} end
      for _, r in ipairs(recs) do
        if not r.cons and not V.seenA[r.a] then
          V.seenA[r.a] = true
          local b = N.obj(r)
          if b and valid(b) then
            local okK, k = pcall(bkey, b)
            if okK and V.want[k] ~= nil and (V.held == nil or V.held[k] ~= r.a) then V.t.apply = -99; bump("newSite") end
          end
        end
      end
    end
  end
  -- (lane 87, cure 3; the advisor's review) a key whose stock line has said nothing of its work for cfg.factsFresh s, with
  -- an HW P fraction kept aside meanwhile: that fraction is taken now (else the friend stood on the stock line's old work
  -- until the host's next HW P line, the 10 s refresh at worst)
  if V.hwLast and next(V.hwLast) then
    local now = os.clock()
    for k, f in pairs(V.hwLast) do
      if not (V.fx and V.fx[k]) or now - V.fx[k] >= V.cfg.factsFresh then
        V.hwLast[k] = nil; if V.fx then V.fx[k] = nil end
        V.want = V.want or {}; V.want[k] = f; V.t.apply = -99; bump("factsExpired")
      end
    end
  end
  -- the host's sites' work
  if V.hostSh and V.want and clock - (V.t.apply or -99) >= V.cfg.applyEvery and usable("SITEHP") then
    V.t.apply = clock
    V.held = V.held or {}; V.heldF = V.heldF or {}
    -- (lane 87) every hold named again every cfg.nameEvery s: one the native piece dropped is held again
    local again = clock - (V.t.name or -99) >= V.cfg.nameEvery
    if again then V.t.name = clock end
    -- (heldElse, above: a hold is dropped only when no other key holds that address)
    for k, f in pairs(V.want) do
      local b = byKey(k)
      local okC, built = false, true
      if b and valid(b) then okC, built = pcall(function() return b.Data.constructed end) end
      local a = (okC and built == false) and addr(b) or nil
      -- (lane 87) not an unfinished building of this tick's list. (cure 1) The table is up to 0.1 s old: a building
      -- that is a site by its own word (an upgrade begun since), or one held in its first tick (proved in the game's
      -- list then, not in the table yet), is kept.
      if a and not siteLive(S, a) and not (V.fresh and V.fresh[a] and clock - V.fresh[a] < 1.0) then a = nil end
      if a then
        local hx = V.hx and V.cfg.exact ~= false               -- (lane 87) the exact hold when this copy's native piece has it
        local s = (hx and "x" or "") .. string.format("%.9g", f)
        if V.held[k] ~= a or V.heldF[k] ~= s or again then
          if V.held[k] and V.held[k] ~= a and not heldElse(k, V.held[k]) then p.send("SITEHP DROP " .. tostring(V.held[k])) end
          if V.held[k] == a and V.heldF[k] == s then bump("namedAgain") else bump("holds") end
          p.send(string.format("SITEHP %s %s %08X", hx and "HOLDX" or "HOLD", tostring(a), bits(f))); V.held[k] = a; V.heldF[k] = s
        end
      elseif V.held[k] then
        if not heldElse(k, V.held[k]) then p.send("SITEHP DROP " .. tostring(V.held[k])) end
        V.held[k] = nil; V.heldF[k] = nil
      end
    end
    for k, a in pairs(V.held) do
      if V.want[k] == nil then
        V.held[k] = nil; V.heldF[k] = nil
        if not heldElse(k, a) then p.send("SITEHP DROP " .. tostring(a)) end
      end
    end
  end
end

-- ---------------------------------------------------------------- module
local function tick(S, clock)
  if S.role ~= "host" and S.role ~= "friend" then return end
  if not (S.eng and valid(S.eng)) then return end
  local t0 = os.clock()
  local ok, e = pcall(S.role == "host" and hostTick or friendTick, S, clock)
  if not ok then bump("errors"); V.lastErr = tostring(e) end
  local ms = (os.clock() - t0) * 1000; bump("tickMs", ms); if ms > (V.stats.tickMax or 0) then V.stats.tickMax = ms end
  if clock - (V.t.log or -99) >= V.cfg.logEvery then V.t.log = clock; log("%s", V.status()) end
end

local function onWorld(S)
  V.w, V.wa, V.frac, V.sentF, V.q, V.want, V.held, V.heldF = {}, {}, {}, {}, {}, {}, {}, {}
  V.tried, V.wT, V.bq, V.fresh, V.knownA, V.lastN, V.polledAt = {}, {}, {}, {}, nil, nil, nil   -- (lane 87, cure 1)
  V.fx, V.hwLast = {}, {}                                                -- (lane 87, cure 3)
  V.seenA = {}
  V.cf, V.finishRuins = {}, {}
  local p = patch()
  if p then pcall(function() p.send("SITEHP FORGET"); p.tick() end) end
end

local function onMessage(S, from, kind, w, line)
  if kind ~= "HW" then return false end
  if S.role ~= "friend" or from ~= "host" then bump("ignored"); return true end
  -- a line of the world before this copy's load: by the host's own stamps (coop.lua C.stale, lane 62), else by the clock
  local wall = tonumber(w[2])
  if type(C.stale) == "function" then if C.stale("host", w) then bump("staleLine"); return true end
  elseif wall and S.startWall and wall < S.startWall - 1 then bump("staleLine"); return true end
  local what = w[4]
  if what == "X" then V.hostT = os.clock(); V.hostCl = w[5] == "1"; V.hostSh = w[6] == "1"; V.hostMr = w[7] == "1"
  elseif what == "J" and w[5] then                                       -- (3.) the host's injury: the game's own notice, the player's own building only
    local b = byKey(w[5])
    local own = false
    pcall(function() own = valid(b) and valid(b.ownerPawn) and b.ownerPawn:GetAddress() == S.p1:GetAddress() end)
    local Pn = patch()
    local Rm = rawget(C, "realm")
    if own and Pn and Pn.nlOn == true and Rm and Rm.on and Rm.on.notices then bump("injuryByRealm")      -- (merge 0.2.5) lane 66: with NOLOG on the realm module's R LOG carries every
                                                                -- notice of the host's, this one too: not given twice
    elseif own and not busy() then
      local ok, e = pcall(function() local l = b:K2_GetActorLocation(); if Pn and Pn.markLog then Pn.markLog() end; S.p1:addLog(FName("injury"), "worker_injured", "worker_injured_descr", 0, { X = l.X + 0.0, Y = l.Y + 0.0, Z = l.Z + 0.0 }, b) end)
      if ok then bump("injuryNotices") else bump("injuryErr"); V.lastErr = tostring(e) end
    else bump("injuryNotMine") end
  elseif what == "C" and w[5] then V.q = V.q or {}; V.q[#V.q + 1] = { k = w[5], t = os.clock() }; bump("collapsesIn")
  elseif what == "CF" and w[5] and w[6] == "1" and not busy() then
    V.finishRuins[w[5]] = os.clock()
  elseif what == "P" and w[5] then
    V.want = V.want or {}
    local now = os.clock()
    for k, v in w[5]:gmatch("([^;=]+)=([^;]+)") do
      if v == "-" then V.want[k] = nil; if V.fx then V.fx[k] = nil end; if V.hwLast then V.hwLast[k] = nil end
      -- (lane 87, cure 3) a key the facts module carries (its stock line's wq, the same moment as its goods): HW P's
      -- fraction is not taken, which would put the work of another moment beside those goods. (session l87f) For
      -- cfg.factsFresh s after its last wq only (3 s): the stock line now comes in the tick a fraction moved (above, the
      -- host's poll), and if it stops carrying the work (the site no longer watched there), HW P is taken again
      elseif V.cfg.factsWork ~= false and V.fx and V.fx[k] and now - V.fx[k] < V.cfg.factsFresh then
        bump("fracGaveWay"); V.hwLast = V.hwLast or {}; local f = tonumber(v); if f and f >= 0 and f <= 1 then V.hwLast[k] = f end
      else local f = tonumber(v); if f and f >= 0 and f <= 1 then V.want[k] = f end end
    end
    if V.t then V.t.apply = -99 end                          -- (lane 87) held in this tick, not up to half a second later
    bump("fracIn")
  end
  return true
end

function V.status()
  local st = {}
  for k, v in pairs(V.stats) do st[#st + 1] = k .. "=" .. (math.tointeger(v) and tostring(math.tointeger(v)) or string.format("%.1f", v)) end
  table.sort(st)
  local nw, nh = 0, 0
  for _ in pairs(V.w or {}) do nw = nw + 1 end; for _ in pairs(V.held or {}) do nh = nh + 1 end
  return string.format("values %s collapse=%s sitesWatched=%d sitesHeld=%d err=%s | %s", V.version, tostring(V.clOn or V.canCl), nw, nh, tostring(V.lastErr), table.concat(st, " "))
end

C.register("values", { onWorld = onWorld, tick = tick, onMessage = onMessage,
  idle = function(S)                                                     -- the core's tick at the menu and while loading
    local p = patch()
    if p and V.clOn then pcall(function() p.send("COLLAPSE OFF"); p.tick() end); V.clOn = false end
    if p and V.mrOn then pcall(function() p.send("MROLL OFF"); p.tick() end); V.mrOn = false end
    if p and V.frOn then pcall(function() p.send("FAMROLL OFF"); p.tick() end); V.frOn = false end
    if p and V.nrOn then pcall(function() p.send("NOROLL OFF"); p.tick() end); V.nrOn = false end   -- (lane 87)
    if p and V.bnOn then pcall(function() p.send("BARNAN OFF"); p.tick() end); V.bnOn = false end   -- (lane 87, the bar's cure 2)
    if V.held and next(V.held) then shForget("no world") end
  end })
return "coop_x_values " .. V.version .. " loaded"
