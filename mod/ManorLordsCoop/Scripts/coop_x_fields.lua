-- Manor Lords Co-op: fields and gardens on the host's word (lane 40; plug-in module "fields", message kind "Y", host ->
-- friends only). Loaded by coop_facts.lua (its last lines) after every other module. Re-loadable: state in Coop.fields.
-- Evidence: research/2026-11-10-game-probe/lanes/lane_s21_40/report.txt.
--
-- Why. A field or a backyard garden is a list of plants (native, not reflected): crop, plough, growth, yield per point.
-- Each copy's own villagers plough, sow and harvest point by point at their own moments, and a point grows from its
-- sowing, so after 100 days two gardens read ready 146 / 340 (lane 39). What a player sees of it is drawn from those
-- points: each plant's mesh (crop and growth) and the ploughed ground.
-- How. The native piece (coop_patch FIELD, coop_fields.h):
--   host    FIELD WATCH every building with plants (the player's and every other lord's), FIELD POLL four times a
--           second: the DLL writes field_out.txt, one line per field that changed since the last poll: its plant count,
--           a checksum and the changes (runs of equal points; the day's growth as one step for a run of plants). This
--           module sends each as "Y S". Nothing of the game is patched on the host.
--   friend  FIELD HOOK ON when the host says "Y X 1" and this copy's DLL can: the game's UpdateFieldCache (called after
--           every change of a field's plants) first puts back every plant of a held field that differs from the
--           host's, and draws it again, so this copy's own work and growth never show. A "Y S" line is written with
--           FIELD SET: the host's points into the plants, drawn and painted with the game's own routines, then the
--           game's own UpdateFieldCache (the panel's sown, ready, yield ... follow). Villagers still walk and swing.
-- Messages (after the core's "<seq> <wallclock> "):
--   Y X <1|0>                          the host's fields are sent (1) or not
--   Y S <bkey> <n> <ops>               changes of a field (n = its plants on the host; ops: coop_fields.h)
--   Y K <bkey> <n> <crc>               the host's checksum of a field's plants (every cfg.checkEvery s): counted
--   Y B <bkey> <points> <border> <final>   a field's point lists' lengths (FieldPoints, fieldBorderPoints, finalBorder)
--   Y V <bkey> <v1>,<v2>,...           (lane 71) the field's own values the panel shows that no player sets (VPROPS order)
--   bkey = <type>@<x/10>,<y/10> (as coop_facts.lua)
--
-- Lane 71 (live r5/r9, the player's own field 14@7992,4146: sown 5/0, sowing 1/0, operation mode 2/0, harvest planned
-- 1/0 for days although the push ran). From the code: a friend indexed a building only when ITS OWN counts said "field"
-- (type 39, or sown + unploughed above 0); a grain field is not type 39, and the friend's own one stood at 0 / 0, so it
-- was never in the friend's index: every Y S / Y K of it was dropped ("noField") and it was never held. Now:
--   * the index also takes a building with ploughed ground, ripe plants or field workers (any type);
--   * a friend takes into its index every field the host names (by key, through the world module's building index), so
--     the host's word decides what is a field, not this copy's own counts;
--   * the values of the field routine itself (operation mode, harvest planned, its days and yield, the yield) travel as
--     Y V and are written here every 0.5 s against this copy's own routine (forceHarvest is not among the native
--     piece's counted numbers; the others are, and the native audit puts them back every 0.5 s: on a field the native
--     piece holds only forceHarvest is written from here, on any other field all five).
--   Not carried here on purpose: crop per year, crop rotation, fertilizing (a player's own settings: town actions).
local C = rawget(_G, "Coop")
if type(C) ~= "table" or type(C.register) ~= "function" or type(C.api) ~= "table" then return "coop_x_fields: load coop.lua first" end
local A = C.api
local un, valid = A.un, A.valid
local P = C.fields or {}
C.fields = P
P.version = "0.1"
-- (lane 45) pollEvery 0.4 s, was 0.15 s: each poll is a command to the native piece, its tick and a file read (the
-- owner's window for what players see is 3 s); a friend looks for field_ask.txt at most every 0.4 s too
P.cfg = P.cfg or { pollEvery = 0.4, indexEvery = 5.0, checkEvery = 10.0, announceEvery = 5.0, pointsEvery = 30.0, indexPerTick = 12, hostStale = 15.0, logEvery = 60.0 }
-- lane 71: the field routine's values (host: read every valuesEvery s, valuesPerTick fields a tick; friend: written every
-- applyEvery s); a key the host names that this copy has not indexed is looked up at most every adoptEvery s
for k, v in pairs({ valuesEvery = 1.0, valuesPerTick = 12, applyEvery = 0.5, adoptEvery = 2.0 }) do if P.cfg[k] == nil then P.cfg[k] = v end end
local VPROPS = { "fieldOperationMode", "forceHarvest", "plannedHarvest_DaysLeft", "plannedHarvest_PredictedYield", "yield" }
P.VPROPS = VPROPS
P.stats = P.stats or {}
P.t = P.t or {}
local function log(fmt, ...) A.log("fields: " .. fmt, ...) end
local function bump(k, n) P.stats[k] = (P.stats[k] or 0) + (n or 1) end
local function patch() local p = rawget(C, "patch"); if p and p.fn then return p end end
local function avail()
  local p = patch(); if not p then return false end
  local ok, st = pcall(p.status); if not ok or not st or st.state ~= "ready" then return false end
  local it = st.items and st.items.FIELD
  return it ~= nil and (it.state == "idle" or it.state == "hooked")
end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); if ok then return a end end
local function keyOf(b)
  local l = b:K2_GetActorLocation()
  return string.format("%d@%d,%d", A.btype(b), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5))
end
local function send(line) A.send(line); bump("sent"); bump("bytes", #line + 20) end
-- a building that is still in the game: valid, in the engine's list (the index is rebuilt every cfg.indexEvery s) and
-- with a region (a demolished building stays a valid object for a while but has none: lanes/lane_s21_0/crash_demolish_site)
local function live(b) local ok, r = pcall(function() return valid(b) and valid(b.Region) end); return ok and r end
-- (lane 88) the session check's timing proof (a test tool, off for players): the field's row of the wide section fd
-- (sown, unploughed, ready, yield ...) noted with the moment it is known here: on the host at the poll that sent its
-- change (a friend shows exactly those values), on a friend right after it wrote the host's change. Without the
-- note the host's rounds (every 0.2 s) missed values a harvest held for less than that, and the check counted the
-- friend's value as one "the host never had" (r27m83: 22, r27cf: 17; every one lay between two host reads).
-- The building is found by its place in the engine's list (a map address -> place, made again every second) and taken
-- from the list in this tick (a fresh handle, checked against its address), never through a handle kept in the index.
local function note(k)
  local W = rawget(C, "world")
  if not (W and W.cfg and W.cfg.proof and W.proofNote) then return end
  local e = P.idx and P.idx[k]; if not (e and e.a) then return end
  local S = C.s; if not (S and valid(S.eng)) then return end
  local now = os.clock()
  if not P.noteMapT or now - P.noteMapT >= 1.0 then     -- (made again every second, not at every note: run l88b, 16 to 20 ms a frame on the host)
    P.noteMapT = now; P.noteMap = {}
    local arr = S.eng.buildingArr; local n = #arr
    for i = 1, n do local b = un(arr[i]); local a = valid(b) and addr(b); if a then P.noteMap[a] = i end end
  end
  local i = P.noteMap[e.a]; if not i then return end
  local arr = S.eng.buildingArr; if i > #arr then return end
  local b = un(arr[i])
  if live(b) and addr(b) == e.a then if pcall(W.proofNote, b, nil, "fd") then bump("proofNotes") end else P.noteMapT = nil end   -- (moved in the list: the map again)
end

-- every building that has plants or is a field (type 39): key -> { b, a }. Built a few buildings a tick (a whole pass
-- at once took up to 57 ms on the host: one hitch every 5 s); P.idx is the last complete pass. Returns true when a pass
-- has just completed.
local function indexStep(S)
  local sc = P.scan
  if not sc then sc = { i = 1, t = {}, byA = {} }; P.scan = sc end
  local arr = S.eng.buildingArr
  local n = #arr
  local stop = math.min(n, sc.i + (P.cfg.indexPerTick or 12) - 1)
  for i = sc.i, stop do
    local b = un(arr[i])
    pcall(function()
      if not live(b) then return end
      local a = addr(b)
      local old = P.byA and a and P.byA[string.format("%X", a)]        -- once a field, a field while it stands (all ploughed, none sown: both counts 0)
      -- (lane 71) the field routine's own marks, any type: ploughed ground, ripe plants, field workers (a grain field all
      -- ploughed and not sown yet has sown 0 and unploughed 0)
      if not old and A.btype(b) ~= 39 and b.field_numSown + b.field_numUnplowed <= 0 and not ((b.field_ploughingPerc or 0) > 0
         or (b.field_numReadyToHarvest or 0) > 0 or (b.fieldWorkersNeeded or 0) > 0) then return end
      local k = old or keyOf(b)
      if a and not sc.t[k] then sc.t[k] = { b = b, a = a }; sc.byA[string.format("%X", a)] = k end
    end)
  end
  sc.i = stop + 1
  if sc.i <= n then return false end
  -- (lane 71) the fields the host named and this copy took in (adopt): kept while they stand
  for k, x in pairs(P.adopted or {}) do
    if not sc.t[k] then
      if live(x.b) and addr(x.b) == x.a then sc.t[k] = { b = x.b, a = x.a }; sc.byA[string.format("%X", x.a)] = k else P.adopted[k] = nil end
    end
  end
  P.idx, P.byA, P.t.index, P.scan = sc.t, sc.byA, os.clock(), nil
  return true
end

-- (lane 71) friend: a field the host names that this copy's index lacks (its own counts do not say "field"): found by
-- its key in the world module's building index and taken in; the host's word decides what is a field here
local function adopt(S, k)
  P.adoptT = P.adoptT or {}
  local now = os.clock()
  if now - (P.adoptT[k] or -99) < P.cfg.adoptEvery then return nil end
  P.adoptT[k] = now
  -- the world module's index first (it is rebuilt on a friend only for its stock rules, not in exact mode), then the
  -- town module's finder (its index, then a live look through the engine's list), as the job board finds buildings
  local b
  local W = rawget(C, "world")
  if W and W.buildingByKey then local ok, x = pcall(W.buildingByKey, k); if ok then b = x end end
  if not b then
    local t, x, y = k:match("^(%d+)@(%-?%d+),(%-?%d+)$")
    local T = rawget(C, "town")
    if t and T and T.findB then local ok, f = pcall(T.findB, tonumber(t), tonumber(x) * 10, tonumber(y) * 10, 20); if ok then b = f end end
  end
  if not b or not live(b) then bump("adoptMiss"); return nil end
  local a = addr(b); if not a then return nil end
  local e = { b = b, a = a }
  P.idx = P.idx or {}; P.byA = P.byA or {}; P.adopted = P.adopted or {}
  P.idx[k] = e; P.byA[string.format("%X", a)] = k; P.adopted[k] = e
  bump("adopted"); log("%s: named by the host, not a field by this copy's own counts: taken into the index", k)
  return e
end
local function indexDue(clock) return P.scan ~= nil or not P.idx or clock - (P.t.index or -99) >= P.cfg.indexEvery end

local function pointCounts(b)
  local ok, a, c, d = pcall(function() return #b.FieldPoints, #b.fieldBorderPoints, #b.finalBorder end)
  if ok then return a, c, d end
end

-- ---------------------------------------------------------------- lane 71: the field routine's values (Y V)
local function busy() return rawget(C, "hold") or (C.join and C.join.state) end     -- (moved up from the friend part)
local function vals(b)
  local t = {}
  for i, p in ipairs(VPROPS) do
    local v = b[p]
    if type(v) == "boolean" then v = v and 1 or 0 end
    v = math.tointeger(v) or v
    if type(v) ~= "number" then return nil end
    t[i] = v
  end
  return t
end
-- host: a few fields a tick, every field each cfg.valuesEvery s; a line when its values changed (all again with the
-- point counts' cfg.pointsEvery, after a join or resync, and for a field a friend asked whole)
local function hostValues(S, clock)
  if not P.idx then return end
  local q = P.vq
  if not q then
    if clock - (P.t.vals or -99) < P.cfg.valuesEvery then return end
    P.t.vals = clock
    q = { i = 0 }; for k in pairs(P.idx) do q[#q + 1] = k end
    P.vq = q
  end
  P.sentV = P.sentV or {}
  local stop = math.min(#q, q.i + P.cfg.valuesPerTick)
  for i = q.i + 1, stop do
    local k = q[i]; local e = P.idx[k]
    if e and live(e.b) then
      local ok, t = pcall(vals, e.b)
      if ok and t then
        local line = table.concat(t, ",")
        if P.sentV[k] ~= line then P.sentV[k] = line; send("Y V " .. k .. " " .. line); bump("valsSent") end
      end
    end
  end
  q.i = stop
  if q.i >= #q then P.vq = nil end
end
-- friend: the host's values written into every field of the index that differs, a few fields a tick
local function friendValues(S, clock)
  if not (P.hv and next(P.hv)) or busy() then return end
  local q = P.wq
  if not q then
    if clock - (P.t.apply or -99) < P.cfg.applyEvery then return end
    P.t.apply = clock
    -- the host sends every field's values again every cfg.pointsEvery s: one it has not named for 2.5 times that is gone there
    for k in pairs(P.hv) do if clock - ((P.hvT or {})[k] or clock) > 2.5 * P.cfg.pointsEvery then P.hv[k] = nil; P.hvT[k] = nil end end
    q = { i = 0 }; for k in pairs(P.hv) do q[#q + 1] = k end
    P.wq = q
  end
  local stop = math.min(#q, q.i + P.cfg.valuesPerTick)
  for i = q.i + 1, stop do
    local k = q[i]; local want = P.hv[k]
    local e = want and (P.idx and P.idx[k] or adopt(S, k))
    if e and live(e.b) then
      -- a field the native piece holds gets its counted numbers (mode, planned days and yield, yield) from the host's
      -- c-op with every change and its 0.5 s audit: only forceHarvest (in no counted list) is written here then, or the
      -- two writers would hand a number back and forth for up to a second after a host change
      local nat = P.hooked and P.held and P.held[k] ~= nil
      local ok, err = pcall(function()
        for j, p in ipairs(VPROPS) do
          local cur = e.b[p]; local isB = type(cur) == "boolean"
          local c = isB and (cur and 1 or 0) or cur
          if want[j] ~= nil and c ~= want[j] and (not nat or p == "forceHarvest") then
            if isB then e.b[p] = (want[j] == 1) else e.b[p] = want[j] end
            bump("valFix"); bump("valFix_" .. p); P.noteQ = P.noteQ or {}; P.noteQ[k] = true
          end
        end
      end)
      if not ok then bump("valErr"); P.lastErr = tostring(err) end
    end
  end
  q.i = stop
  if q.i >= #q then P.wq = nil end
end

-- ---------------------------------------------------------------- host
local function hostTick(S, clock)
  local p = patch()
  if p and clock - (P.t.announce or -99) >= P.cfg.announceEvery then
    P.t.announce = clock; P.hostOk = avail(); send("Y X " .. (P.hostOk and "1" or "0"))
  end
  if rawget(C, "hold") then P.wasHold = true; return end            -- a join or resync: nothing is sent meanwhile
  if P.wasHold then P.wasHold = nil; P.sentB = {}; P.sentV = {}; log("a join or resync ended: the point counts are sent again") end
  if clock - (P.t.bAll or -99) >= P.cfg.pointsEvery then P.t.bAll = clock; P.sentB = {}; P.sentV = {} end   -- the point counts again (a friend that came later)
  if not (p and P.hostOk) then                                      -- (lane 71) no native piece here: the field values still go out
    if indexDue(clock) then indexStep(S) end
    hostValues(S, clock)
    return
  end
  if indexDue(clock) and indexStep(S) then
    P.watched = P.watched or {}
    for k, e in pairs(P.idx) do
      if P.watched[k] ~= e.a then P.watched[k] = e.a; p.send("FIELD WATCH " .. tostring(e.a)) end
      -- (lane 47 round four) the index is built over several ticks: a field demolished since is not read
      local fp, bp, fb
      if live(e.b) then fp, bp, fb = pointCounts(e.b) end
      local line = string.format("%d %d %d", fp or -1, bp or -1, fb or -1)
      P.sentB = P.sentB or {}
      if P.sentB[k] ~= line then P.sentB[k] = line; send("Y B " .. k .. " " .. line) end
    end
    for k in pairs(P.watched) do if not P.idx[k] then P.watched[k] = nil end end
  end
  if not P.idx then return end
  hostValues(S, clock)                                               -- (lane 71)
  if clock - (P.t.poll or -99) < P.cfg.pollEvery then return end
  P.t.poll = clock
  p.send("FIELD POLL"); p.tick()
  local f = io.open(p.dir .. "field_out.txt", "rb")
  if not f then return end
  local text = f:read("a") or ""; f:close()
  os.remove(p.dir .. "field_out.txt")                               -- the DLL appends; read once, then gone
  P.crc = P.crc or {}
  for line in text:gmatch("[^\r\n]+") do
    local a, n, crc, ops = line:match("^(%x+) (%d+) (%x+) (%S+)$")
    local k = a and P.byA[a:upper()]
    if k then
      P.crc[k] = n .. " " .. crc
      if ops ~= "-" then send(string.format("Y S %s %s %s", k, n, ops)); bump("lines"); note(k) end
    elseif a then bump("unknownField") end
  end
  if clock - (P.t.check or -99) >= P.cfg.checkEvery then
    P.t.check = clock
    for k, v in pairs(P.crc) do if P.idx[k] then send("Y K " .. k .. " " .. v:gsub(" ", " 0x")) end end
  end
end

-- ---------------------------------------------------------------- friend
local function friendField(S, k)
  local e = P.idx and P.idx[k]                                       -- a field not in the index yet: its next line (and "Y F")
  if not e then e = adopt(S, k) end                                  -- (lane 71) named by the host: taken in by its key
  if not e or not live(e.b) then bump("noField"); return nil end
  return e
end

-- the hook is in whenever this copy's DLL can and the host has not said it cannot (a hook with no held field changes
-- nothing); a field is held, and asked for whole ("Y F"), when its first line arrives
-- a join, a resync or a load on this copy: the hook out at once (the held fields go with it; the load makes new
-- objects, and the game's own UpdateFieldCache runs on them while loading)
local function hookOff(why)
  local p = patch()
  if p and P.hooked then p.send("FIELD HOOK OFF"); p.tick(); log("fields: hook off (%s)", why); bump("hookOff") end
  P.hooked = false; P.held = {}
end
local function hookWanted(S, clock)
  local p = patch(); if not p then return end
  if busy() then if P.hooked then hookOff("a join, resync or load") end; return end
  if clock - (P.t.hookLook or -99) < 1.0 then return end
  P.t.hookLook = clock
  local want = P.hostSays ~= false and avail()
  if want and not P.hooked then p.send("FIELD HOOK ON"); p.tick(); P.hooked = true; P.held = {}; P.t.index = -99; log("the host's fields are held here (FIELD HOOK ON)")
  elseif not want and P.hooked then p.send("FIELD HOOK OFF"); p.tick(); P.hooked = false; P.held = {}; log("fields: hook off (host silent or not able)") end
end

local function friendTick(S, clock)
  hookWanted(S, clock)
  friendValues(S, clock)                                             -- (lane 71) with or without the native piece
  -- a checksum that did not match (FIELD CHECK wrote field_ask.txt): ask the host for that field whole
  local pa = patch()
  if pa and P.hooked and clock - (P.t.ask or -99) >= P.cfg.pollEvery then
    P.t.ask = clock
    local f = io.open(pa.dir .. "field_ask.txt", "rb")
    if f then
      local text = f:read("a") or ""; f:close(); os.remove(pa.dir .. "field_ask.txt")
      for a in text:gmatch("(%x+)") do
        local k = P.byA and P.byA[a:upper()]
        if k then send("Y F " .. k); bump("askedAgain") end
      end
    end
  end
  if indexDue(clock) and indexStep(S) and P.hooked then
    local p = patch()
    for k, a in pairs(P.held or {}) do
      local e = P.idx[k]
      if not e or e.a ~= a then p.send("FIELD DROP " .. tostring(a)); P.held[k] = nil; bump("dropped") end
    end
    -- every field of the index is held at once and asked whole (after a hook on: the end of a join, a resync, a load),
    -- not only when its next change comes: a field that is not held shows this copy's own work meanwhile
    for k, e in pairs(P.idx) do
      if not P.held[k] then p.send("FIELD HOLD " .. tostring(e.a)); P.held[k] = e.a; send("Y F " .. k); bump("heldAhead") end
    end
  end
end

local function cut(S, k, want, have, list, off, b)
  -- the friend's own load appended the field's corners again (12 -> 16 -> 20 border points, 60 -> 80 -> 100 points):
  -- cut to the host's length when the extra points repeat the first ones
  if not want or want < 0 or not have or have <= want or want == 0 then return end
  local ok, same = pcall(function()
    local arr = b[list]
    if #arr ~= have then return false end
    for i = want + 1, have do
      local x, y = arr[i], arr[i - want]
      if math.abs(x.X - y.X) > 0.5 or math.abs(x.Y - y.Y) > 0.5 then return false end
    end
    return true
  end)
  if ok and same then
    local p = patch(); p.send(string.format("FIELD CUT %s %d %d", tostring(addr(b)), off, want)); p.tick()
    bump("cuts"); log("%s %s %d -> %d points (the host's)", k, list, have, want)
  else bump("cutRefused"); log("%s %s: %d here, %d on the host, and the extra points are not a repeat: left", k, list, have, want) end
end

local function onLine(S, w)
  local what, k = w[4], w[5]
  if what == "X" then P.hostSays = w[5] == "1"; P.t.hostX = os.clock(); return end
  if what == "V" then                                                -- (lane 71) the field routine's values: written by friendValues
    local t = {}
    for v in (w[6] or ""):gmatch("[^,]+") do t[#t + 1] = tonumber(v) end
    if #t ~= #VPROPS then bump("valBad"); return end
    P.hv = P.hv or {}; P.hv[k] = t; P.hvT = P.hvT or {}; P.hvT[k] = os.clock()
    if not (P.idx and P.idx[k]) then friendField(S, k) end           -- a field this copy did not know: taken in now
    return
  end
  if not P.hooked then bump("notHooked"); return end
  local p = patch()
  if what == "S" or what == "K" then
    local e = friendField(S, k); if not e then return end
    if not P.held[k] or P.held[k] ~= e.a then
      p.send("FIELD HOLD " .. tostring(e.a)); P.held[k] = e.a
      send("Y F " .. k); bump("askedWhole")                     -- this copy holds it from now on: the host sends it whole
    end
    if what == "S" then p.send(string.format("FIELD SET %s %s %s", tostring(e.a), w[6], w[7])); bump("sets"); P.noteQ = P.noteQ or {}; P.noteQ[k] = true
    else p.send(string.format("FIELD CHECK %s %s %s", tostring(e.a), w[6], w[7])); bump("checks") end
    P.dirty = true
  elseif what == "B" then
    local e = friendField(S, k); if not e then return end
    local fp, bp, fb = pointCounts(e.b)
    cut(S, k, tonumber(w[6]), fp, "FieldPoints", 0x660, e.b)
    cut(S, k, tonumber(w[7]), bp, "fieldBorderPoints", 0x6A8, e.b)
    cut(S, k, tonumber(w[8]), fb, "finalBorder", 0x6B8, e.b)
  end
end

-- ---------------------------------------------------------------- module
local function tick(S, clock)
  if S.role ~= "host" and S.role ~= "friend" then return end
  if S.role == "friend" and P.hooked and busy() then hookOff("a join, resync or load") end
  if not (S.eng and valid(S.eng)) then if P.hooked then hookOff("no world") end; return end
  local t0 = os.clock()
  if S.role == "host" then hostTick(S, clock) else friendTick(S, clock) end
  if P.dirty then P.dirty = false; local p = patch(); if p then p.tick() end end
  if P.noteQ then local q = P.noteQ; P.noteQ = nil; for k in pairs(q) do note(k) end end   -- (lane 88) after the writes of this tick
  -- (lane 88) and every field every 0.25 s (the check's rounds do not read fd: coop_world.lua cfg.proofNoted)
  local Wn = rawget(C, "world")
  if P.idx and Wn and Wn.cfg and Wn.cfg.proof and clock - (P.t.notes or -99) >= 0.25 then
    P.t.notes = clock
    for k in pairs(P.idx) do note(k) end
  end
  local ms = (os.clock() - t0) * 1000
  bump("ticks"); bump("tickMs", ms); if ms > (P.stats.tickMax or 0) then P.stats.tickMax = ms end
  if clock - (P.t.log or -99) >= P.cfg.logEvery then P.t.log = clock; log("%s", P.status()) end
end

local function onWorld(S)
  P.idx, P.byA, P.scan, P.watched, P.held, P.crc, P.sentB = nil, nil, nil, {}, {}, {}, {}
  P.adopted, P.adoptT, P.hv, P.sentV, P.vq, P.wq = {}, {}, {}, {}, nil, nil  -- (lane 71)
  local p = patch()
  if p then if P.hooked then p.send("FIELD HOOK OFF") end; p.send("FIELD FORGET"); p.tick() end
  P.hooked = false
end

local function onMessage(S, from, kind, w, line)
  if kind ~= "Y" then return false end
  if S.role == "host" and w[4] == "F" then                        -- a friend holds a field from now on: send it whole
    local e = P.idx and P.idx[w[5]]; local p = patch()
    if e and p then p.send("FIELD FULL " .. tostring(e.a)); bump("wholeAsked") end
    if P.sentB then P.sentB[w[5]] = nil end                        -- and its point counts again (a friend that reloaded)
    if P.sentV then P.sentV[w[5]] = nil end                        -- (lane 71) and its values
    return true
  end
  if S.role ~= "friend" or from ~= "host" then bump("ignored"); return true end
  local wall = tonumber(w[2])
  if C.stale("host", w) then bump("staleLine"); return true end      -- (lane 62: by the host's own stamps, not by two clocks; coop.lua C.stale)
  bump("in"); bump("inBytes", #line)
  if wall and w[4] == "S" then                                       -- how late the host's changes arrive here (link + frames)
    local d = (C.men and C.men.hostClock and C.men.hostClock() or A.now()) - wall     -- (lane 73) by the host's clock, not this PC's
    if d > (P.stats.delayMax or 0) then P.stats.delayMax = d end
    if d > 1 then bump("late1s") end; if d > 2 then bump("late2s") end
  end
  local t0 = os.clock()
  local ok, e = pcall(onLine, S, w)
  if not ok then bump("errors"); P.lastErr = tostring(e) end
  local ms = (os.clock() - t0) * 1000; bump("lineMs", ms)
  return true
end

function P.status()
  local st = {}
  for k, v in pairs(P.stats) do st[#st + 1] = k .. "=" .. (math.tointeger(v) and tostring(math.tointeger(v)) or string.format("%.1f", v)) end
  table.sort(st)
  local nh = 0; for _ in pairs(P.held or {}) do nh = nh + 1 end
  local nw = 0; for _ in pairs(P.watched or {}) do nw = nw + 1 end
  return string.format("fields %s hostOk=%s hostSays=%s hooked=%s held=%d watched=%d err=%s | %s", P.version, tostring(P.hostOk), tostring(P.hostSays),
    tostring(P.hooked), nh, nw, tostring(P.lastErr), table.concat(st, " "))
end

C.register("fields", { onWorld = onWorld, tick = tick, onMessage = onMessage,
  idle = function(S) if P.hooked then hookOff("no world") end end })     -- the core's tick at the menu and while loading
-- (lane 71) the values module (coop_x_values.lua: collapses and sites' work on the host's word) is loaded from here, the
-- way this file is loaded from coop_facts.lua: main.lua's module list is fixed
do
  local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):gsub("\\", "/")
  local chunk, err = loadfile((here:match("^(.*)/[^/]*$") or ".") .. "/coop_x_values.lua")
  if chunk then
    local ok, r = pcall(chunk)
    if not ok then A.log("values: coop_x_values.lua failed: %s", tostring(r)) end
  elseif err and not tostring(err):find("No such file") then A.log("values: coop_x_values.lua cannot be read: %s", tostring(err)) end
  -- (lane 88) the felled trees module (coop_x_trees.lua), the same way
  local tchunk, terr = loadfile((here:match("^(.*)/[^/]*$") or ".") .. "/coop_x_trees.lua")
  if tchunk then
    local ok, r = pcall(tchunk)
    if not ok then A.log("trees: coop_x_trees.lua failed: %s", tostring(r)) end
  elseif terr and not tostring(terr):find("No such file") then A.log("trees: coop_x_trees.lua cannot be read: %s", tostring(terr)) end
end

return "coop_x_fields " .. P.version .. " loaded"
