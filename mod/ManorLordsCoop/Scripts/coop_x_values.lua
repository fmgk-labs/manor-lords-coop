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
V.version = "0.1"
V.cfg = V.cfg or {}
for k, v in pairs({ announceEvery = 5.0, stale = 30.0, lookEvery = 2.0, readEvery = 0.25, pollEvery = 0.5, fullEvery = 10.0,
                    applyEvery = 0.5, replayWait = 15.0, logEvery = 60.0 }) do if V.cfg[k] == nil then V.cfg[k] = v end end
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
        V.cf[#V.cf + 1] = { k = k, b = b, a = a, t = clock }
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
      if valid(c.b) and addr(c.b) == c.a then
        if c.b:GetType() == 75 and c.b.Data.constructed then send("HW CF " .. c.k .. " 1"); bump("ruinSent")
        elseif clock - c.t < V.cfg.replayWait then keep[#keep + 1] = c end
      end
    end
    V.cf = keep
  end
  -- sites: their work fractions
  if not V.canSh then return end
  local B = rawget(C, "sites")
  if clock - (V.t.watch or -99) >= 1.0 and B and type(B.prev) == "table" then
    V.t.watch = clock
    V.w = V.w or {}; V.wa = V.wa or {}
    for k, b in pairs(B.prev) do
      local a = valid(b) and addr(b)
      if a and V.w[k] ~= a then
        if V.w[k] then V.wa[string.format("%X", V.w[k])] = nil end
        V.w[k] = a; V.wa[string.format("%X", a)] = k; p.send("SITEHP WATCH " .. tostring(a))
      end
    end
    local gone = {}
    for k, a in pairs(V.w) do
      if not B.prev[k] then p.send("SITEHP DROP " .. tostring(a)); V.w[k] = nil; V.wa[string.format("%X", a)] = nil; gone[#gone + 1] = k .. "=-"; if V.sentF then V.sentF[k] = nil end end
    end
    if #gone > 0 then send("HW P " .. table.concat(gone, ";")) end
  end
  if clock - (V.t.poll or -99) >= V.cfg.pollEvery and V.wa and next(V.wa) then
    V.t.poll = clock
    p.send("SITEHP POLL"); p.tick()
    V.frac = V.frac or {}
    for h, fb in (take("sitehp_out.txt") or ""):gmatch("(%x+) (%x+)") do
      local k = V.wa[h:upper()]
      if k then local u = tonumber(fb, 16); V.frac[k] = (u == 0xFFFFFFFF) and -1 or float(u) end
    end
    local full = clock - (V.t.full or -99) >= V.cfg.fullEvery
    if full then V.t.full = clock end
    V.sentF = V.sentF or {}
    local items = {}
    for k, f in pairs(V.frac) do
      if not V.w[k] then V.frac[k] = nil
      elseif f >= 0 then
        local s = string.format("%.4f", f)
        if full or V.sentF[k] ~= s then V.sentF[k] = s; items[#items + 1] = k .. "=" .. s end
      end
    end
    for i = 1, #items, 40 do send("HW P " .. table.concat(items, ";", i, math.min(#items, i + 39))); bump("fracSent", math.min(#items, i + 39) - i + 1) end
  end
end

-- ---------------------------------------------------------------- friend
local function shForget(why)
  local p = patch()
  if p and V.held and next(V.held) then p.send("SITEHP FORGET"); p.tick(); log("sites: their work is this copy's own again (%s)", why) end
  V.held = {}; V.heldF = {}
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
        elseif okT and okF and not fire then
          local a = addr(b)
          if a then p.send("COLLAPSE DO " .. tostring(a)); p.tick(); done = true; bump("collapsesDone"); log("%s collapsed on the host: collapsed here", c.k) end
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
  -- the host's sites' work
  if V.hostSh and V.want and clock - (V.t.apply or -99) >= V.cfg.applyEvery and usable("SITEHP") then
    V.t.apply = clock
    V.held = V.held or {}; V.heldF = V.heldF or {}
    for k, f in pairs(V.want) do
      local b = byKey(k)
      local okC, built = false, true
      if b and valid(b) then okC, built = pcall(function() return b.Data.constructed end) end
      local a = (okC and built == false) and addr(b) or nil
      if a then
        local s = string.format("%.4f", f)
        if V.held[k] ~= a or V.heldF[k] ~= s then
          if V.held[k] and V.held[k] ~= a then p.send("SITEHP DROP " .. tostring(V.held[k])) end
          p.send(string.format("SITEHP HOLD %s %08X", tostring(a), bits(f))); V.held[k] = a; V.heldF[k] = s; bump("holds")
        end
      elseif V.held[k] then p.send("SITEHP DROP " .. tostring(V.held[k])); V.held[k] = nil; V.heldF[k] = nil end
    end
    for k, a in pairs(V.held) do if V.want[k] == nil then p.send("SITEHP DROP " .. tostring(a)); V.held[k] = nil; V.heldF[k] = nil end end
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
    for k, v in w[5]:gmatch("([^;=]+)=([^;]+)") do
      if v == "-" then V.want[k] = nil else local f = tonumber(v); if f and f >= 0 and f <= 1 then V.want[k] = f end end
    end
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
    if V.held and next(V.held) then shForget("no world") end
  end })
return "coop_x_values " .. V.version .. " loaded"
