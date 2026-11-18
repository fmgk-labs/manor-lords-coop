-- Manor Lords Co-op: every building's maintenance is the host's (lane 67). Loaded after coop_world.lua.
--
-- Why (research/2026-11-10-game-probe/lanes/lane_s21_67/report.txt; read in the game file, 0.8.117): a building's
-- MaintenanceComponent (SMBuildingMaster.MaintenanceComponent) keeps one tracker per maintenance type (a set of goods,
-- for example tools): what is left of it (DurabilityLeft). Each day a built building with workers loses 1, 2 or 4 of
-- every tracker (by its slider: half, normal, double); a worker's hit or a delivery takes one maintenance good out of
-- the building's own stock and sets that tracker to full again. The status (maintained, pending, unmaintained) is
-- cached from the trackers at the day change; the panel's status, its bar (left / full) and the yield (the active
-- maintenance effect) follow from them. On a friend the building's stock is the host's word, so the goods the host's
-- workers fetch and use within a second never reach it there: a friend's trackers only ran down (live, 2026-11-17: the
-- same lodge "Maintained", a full bar and yield 100 % on the host, "Needs Maintenance", an empty bar and 50 % on a
-- friend). The component has no reflected fields and its per-type functions take a struct that crashed both copies
-- from the console (lane 35, d1): the values are read and written by the native piece (coop_patch.dll, item MAINT).
--   both    once a second every component is read (MAINT READ, in batches, one batch a frame): status, slider and
--           each tracker as <goods joined by +>=<left>. The friend keeps its own reading for the log and the wide sample.
--   host    "MC <full> <bkey>|<status>|<slider>|<trackers>;..." for every building whose values changed since the
--           last line, all of them every cfg.fullEvery s and after a join or resync (the world module's keyframe),
--           "<bkey>|!" for one that is gone. Every owner's buildings (rival towns' too): the sync works off the
--           component, never off a list of building types.
--   friend  each entry goes to MAINT SET for this copy's component of that building: the DLL writes the host's trackers
--           and status at once and puts them back at every frame while the object is the same (this copy's own day
--           wear and refills cannot fight it). A key with no building here is counted ("missing"). The slider is a
--           player action (coop_town.lua MAINT, any player's change goes to the host and from there to all): this
--           module only puts the host's slider back when this copy's has differed for cfg.sliderAfter s (a lost action).
-- Without the native item (another game build, native = off) nothing is carried; the log says so once.
-- Console: Coop.maint.status(); test switch (friend): Coop.maint.off = true stops writing the host's word (a control run:
-- the copy's own maintenance again), false puts it back (every entry is set again from the host's next whole line)

local C = rawget(_G, "Coop")
if not (C and C.register and C.api) then return "coop_x_maint: load coop.lua first" end
local A = C.api
local MC = rawget(C, "maint") or {}; C.maint = MC
local valid, log, send, un = A.valid, A.log, A.send, A.un

MC.cfg = MC.cfg or {}
for k, v in pairs({ readEvery = 1.0, fullEvery = 15.0, indexEvery = 10.0, slice = 40, batch = 40, sliderAfter = 4.0, sayEvery = 60.0, diffAfter = 3.0 }) do
  if MC.cfg[k] == nil then MC.cfg[k] = v end
end
local function stat(S, k, n) S.stats[k] = (S.stats[k] or 0) + (n or 1) end
local function hexOf(o) local ok, a = pcall(function() return o:GetAddress() end); if ok and a and a ~= 0 then return string.format("%X", math.tointeger(a) or a) end end
local function say(fmt, ...) log("maint: " .. fmt, ...) end

local function reset()
  MC.idx = nil; MC.ix = nil; MC.cur = {}; MC.curT = 0; MC.rd = nil
  MC.sent = {}; MC.fullT = -1e9; MC.host = {}; MC.set = {}; MC.missing = {}; MC.slT = {}; MC.diffT = {}; MC.diffSaid = {}
  MC.sayT = MC.sayT or 0; MC.noNative = nil
end
if not MC.cur then reset() end

-- the native item, when it is there (its status is read at most twice a second by coop_patch.lua)
local function native()
  local P = rawget(C, "patch"); if not (P and P.fn and P.send and P.tick and P.status) then return nil end
  local it = P.status().items.MAINT
  if it and it.state == "available" then return P end
  return nil, it and (it.state .. " " .. tostring(it.why)) or "no MAINT line (an older coop_patch.dll)"
end

-- ---------------------------------------------------------------- the index: every building with a maintenance component
-- built in slices (cfg.slice buildings a frame); the list's length is looked at first (a read past the end grows it)
local function indexStep(S)
  local X = MC.ix
  if not X then X = { i = 0, list = {}, byKey = {}, byHex = {} }; MC.ix = X end
  local W = rawget(C, "world"); if not (W and W.bkey) then return end
  local arr = S.eng.buildingArr; local n = #arr
  local to = math.min(n, X.i + MC.cfg.slice)
  for i = X.i + 1, to do
    local b = un(arr[i])
    if valid(b) then
      local okc, mc = pcall(function() return b.MaintenanceComponent end)
      if okc and mc and valid(mc) then
        local okk, k = pcall(W.bkey, b); local h = hexOf(mc)
        if okk and k and h then
          if X.byKey[k] then k = k .. "#" .. i end                    -- two buildings of one type on one spot
          local e = { k = k, b = b, mc = mc, h = h }
          X.list[#X.list + 1] = e; X.byKey[k] = e; X.byHex[h] = e
        end
      end
    end
  end
  X.i = to
  if to >= n then MC.idx = X; MC.ix = nil; MC.idxT = os.clock(); stat(S, "mcIndex") end
end

-- ---------------------------------------------------------------- reading this copy's components
local function readFile(P)
  local f = io.open(P.dir .. "maint.txt", "rb"); if not f then return nil end
  local t = f:read("a") or ""; f:close()
  if not t:find("END") then return nil end
  return t
end
-- the trackers in one order (the game's map may hold them in another order on each copy)
local function norm(trk)
  if trk == "-" or not trk:find(",", 1, true) then return trk end
  local t = {}; for x in trk:gmatch("[^,]+") do t[#t + 1] = x end
  table.sort(t); return table.concat(t, ",")
end
-- one batch a frame; returns true when the pass is done
local function readStep(S, P)
  local R = MC.rd
  if not R then
    if not MC.idx then return false end
    R = { list = MC.idx.list, i = 0, cur = {} }; MC.rd = R
  end
  local hs, es = {}, {}
  while R.i < #R.list and #hs < MC.cfg.batch do
    R.i = R.i + 1; local e = R.list[R.i]
    if valid(e.mc) then hs[#hs + 1] = e.h; es[e.h] = e end
  end
  if #hs > 0 then
    P.send("MAINT READ " .. table.concat(hs, ",")); P.tick()
    local t = readFile(P)
    if t then
      for h, st, sl, trk in t:gmatch("(%x+) (%d) (%-?%d+) (%S+)") do
        local e = es[h]; if e then R.cur[e.k] = { st = st, sl = sl, trk = norm(trk), h = h } end
      end
      stat(S, "mcReads", #hs)
    else stat(S, "mcReadFail") end
  end
  if R.i >= #R.list then MC.cur = R.cur; MC.curT = os.clock(); MC.rd = nil; return true end
  return false
end

-- the wide sample's view of this copy (coop_world.lua section "mt"): the trackers last read here, "-" when none
function MC.trkOf(k) local c = MC.cur and MC.cur[k]; return c and c.trk or "-" end

-- ---------------------------------------------------------------- host
local function hostSend(S, clock)
  local full = clock - MC.fullT >= MC.cfg.fullEvery; if full then MC.fullT = clock end
  local out = {}
  for k, c in pairs(MC.cur) do
    local s = c.st .. "|" .. c.sl .. "|" .. c.trk
    if full or MC.sent[k] ~= s then out[#out + 1] = k .. "|" .. s; MC.sent[k] = s end
  end
  for k in pairs(MC.sent) do if not MC.cur[k] then out[#out + 1] = k .. "|!"; MC.sent[k] = nil end end
  if #out == 0 then return end
  local part, len = {}, 0
  local function put(f) send("MC " .. f .. " " .. (#part > 0 and table.concat(part, ";") or "-")); stat(S, "mcLines"); part, len = {}, 0 end
  for _, e in ipairs(out) do part[#part + 1] = e; len = len + #e + 1; if len > 3000 then put("0") end end
  put(full and "1" or "0")
  stat(S, "mcSent", #out)
end

-- ---------------------------------------------------------------- friend
local function compOf(k)
  local X = MC.idx; local e = X and X.byKey[k]
  if e and valid(e.mc) then return e end
end
local function applyOne(S, P, k, H, cmds, force)
  local e = compOf(k)
  if not e then
    if not MC.missing[k] then MC.missing[k] = true; stat(S, "mcMissing") end
    return
  end
  MC.missing[k] = nil
  local want = e.h .. " " .. H.st .. " " .. H.trk
  if force or MC.set[k] ~= want then cmds[#cmds + 1] = "MAINT SET " .. want; MC.set[k] = want; stat(S, "mcSet") end
end
local function onMC(S, w)
  if MC.off then return end
  local full = w[4] == "1"; local body = w[5] or "-"
  -- the host's clock on the line (the core's prefix): a line older than this world (sent before the load this copy
  -- just made, read after it) is not used; within a world an entry older than the one held is not used either
  local wall = tonumber(w[2]) or 0
  if MC.minWall and wall <= MC.minWall then stat(S, "mcLate"); return end
  if wall > (MC.lastWall or 0) then MC.lastWall = wall end
  local P = native()
  if not P then if not MC.noNative then MC.noNative = true; say("the native item MAINT is not available here: the host's maintenance is not written") end end
  local cmds, seen = {}, {}
  if body ~= "-" then
    for ent in body:gmatch("[^;]+") do
      local k, st, sl, trk = ent:match("^([^|]+)|(%d)|(%-?%d+)|([^|]+)$")
      if k then
        local H = MC.host[k]
        if H and wall < (H.w or 0) then stat(S, "mcOlder")
        else
          if not H or H.st ~= st or H.trk ~= trk or H.sl ~= sl then H = { st = st, sl = sl, trk = trk, t = os.clock() }; MC.host[k] = H end
          H.w = wall
          seen[k] = true
          if P then applyOne(S, P, k, H, cmds, false) end
        end
      else
        local kg = ent:match("^([^|]+)|!$")
        if kg and MC.host[kg] and wall < (MC.host[kg].w or 0) then stat(S, "mcOlder")
        elseif kg then
          MC.host[kg] = nil
          local s = MC.set[kg]; if s and P then cmds[#cmds + 1] = "MAINT DROP " .. s:match("^(%x+)"); stat(S, "mcDrop") end
          MC.set[kg] = nil
        end
      end
    end
  end
  -- MC.full lines are split: the last one says full; MC.fullSeen gathers the keys of all its parts
  MC.fullSeen = MC.fullSeen or {}
  for k in pairs(seen) do MC.fullSeen[k] = true end
  if full then
    for k, s in pairs(MC.set) do
      if not MC.fullSeen[k] then MC.host[k] = nil; MC.set[k] = nil; if P then cmds[#cmds + 1] = "MAINT DROP " .. s:match("^(%x+)"); stat(S, "mcDrop") end end
    end
    MC.fullSeen = {}
    -- every entry set again (the DLL drops its table at ALLOFF, and an entry whose object was replaced is gone there)
    if P then for k, H in pairs(MC.host) do applyOne(S, P, k, H, cmds, true) end end
  end
  if P and #cmds > 0 then P.send(table.concat(cmds, "\n")) end
end

-- the index was rebuilt (a building replaced, a component at another address): every held entry is set again
local function friendReapply(S)
  local P = native(); if not P then return end
  local cmds = {}
  for k, H in pairs(MC.host) do applyOne(S, P, k, H, cmds, false) end
  if #cmds > 0 then P.send(table.concat(cmds, "\n")) end
end

-- the slider: the host's, when this copy's has differed for cfg.sliderAfter s (an action that was lost)
local function friendSlider(S, clock)
  local T = rawget(C, "town")
  for k, H in pairs(MC.host) do
    local c = MC.cur[k]
    if c and c.sl ~= H.sl then
      local t0 = MC.slT[k]; if not t0 then MC.slT[k] = clock
      elseif clock - t0 >= MC.cfg.sliderAfter then
        local e = compOf(k)
        if e then
          local v = math.tointeger(tonumber(H.sl))
          local ok = pcall(function() if T and T.quiet then T.quiet(function() e.mc:SetSliderValue(v) end) else e.mc:SetSliderValue(v) end end)
          stat(S, ok and "mcSlider" or "mcSliderFail")
          say("%s: the slider here was %s for %.0f s, the host's is %s: set to the host's (%s)", k, c.sl, clock - t0, H.sl, ok and "ok" or "failed")
        end
        MC.slT[k] = clock + 30.0                       -- not again for 30 s
      end
    else MC.slT[k] = nil end
  end
end

-- friend: what differs now between this copy's reading and the host's word (the log, every cfg.sayEvery s; a key
-- that differs for cfg.diffAfter s is named once)
local function friendCheck(S, clock)
  local nd = 0
  for k, H in pairs(MC.host) do
    local c = MC.cur[k]
    if c and (c.st ~= H.st or c.trk ~= H.trk) then
      nd = nd + 1
      local t0 = MC.diffT[k]; if not t0 then MC.diffT[k] = clock
      elseif clock - t0 >= MC.cfg.diffAfter and not MC.diffSaid[k] then
        MC.diffSaid[k] = true; stat(S, "mcDiffer")
        say("%s differs for %.1f s: host status %s %s, here %s %s", k, clock - t0, H.st, H.trk, c.st, c.trk)
      end
    else MC.diffT[k] = nil; MC.diffSaid[k] = nil end
  end
  MC.ndiff = nd
end

-- the native table emptied: a load begins (the join module holds), or the world is gone. Every entry is set again
-- from the host's next line once the new world is up.
local function forget(why)
  local P = rawget(C, "patch")
  if next(MC.set) and P and P.fn and P.send then pcall(P.send, "MAINT FORGET"); pcall(P.tick); say("native entries forgotten: %s", why) end
  MC.set = {}
end
function MC.loadBegins() forget("a load begins") end

-- friend, after a read pass: a held building whose component is no longer valid here (demolished, burnt) is dropped
-- at once, not when the host's line says so
local function friendGone(S, P)
  local cmds = {}
  for k, s in pairs(MC.set) do
    if not compOf(k) then cmds[#cmds + 1] = "MAINT DROP " .. s:match("^(%x+)"); MC.set[k] = nil; stat(S, "mcGone") end
  end
  if #cmds > 0 then P.send(table.concat(cmds, "\n")) end
end

-- ---------------------------------------------------------------- the tick
local function tick(S, clock)
  if rawget(C, "hold") then forget("the join module holds (a load)"); return end
  if MC.off and S.role == "friend" then forget("switched off (Coop.maint.off)"); MC.host = {}; return end
  if not (valid(S.eng) and valid(S.p1)) then forget("no world"); return end
  if S.role ~= "host" and S.role ~= "friend" then return end
  local P, why = native()
  if not P then
    if not MC.noNative then MC.noNative = true; say("the native item MAINT is not available (%s): maintenance is not carried", tostring(why)) end
    return
  end
  if MC.noNative then MC.noNative = nil; say("the native item MAINT is available") end
  if MC.ix or not MC.idx or clock - (MC.idxT or -1e9) >= MC.cfg.indexEvery then
    local before = MC.idx
    indexStep(S)
    if MC.idx ~= before and S.role == "friend" then friendReapply(S) end
    if MC.ix then return end                              -- one thing a frame
  end
  if MC.rd or clock - MC.curT >= MC.cfg.readEvery then
    if readStep(S, P) then
      if S.role == "host" then hostSend(S, clock) else friendGone(S, P); friendSlider(S, clock); friendCheck(S, clock) end
    end
  end
  if clock - MC.sayT >= MC.cfg.sayEvery then
    MC.sayT = clock; local t = S.stats; local it = P.status().items.MAINT or {}
    local n = 0; for _ in pairs(MC.cur) do n = n + 1 end
    local nm = 0; for _ in pairs(MC.missing) do nm = nm + 1 end
    say("%s: %d components read here, %s; %s", S.role, n,
      S.role == "host" and string.format("lines %d, entries sent %d", t.mcLines or 0, t.mcSent or 0)
        or string.format("host entries set %d, missing here %d, differing now %d, sliders put back %d", t.mcSet or 0, nm, MC.ndiff or 0, t.mcSlider or 0),
      tostring(it.why))
  end
end

local function onMessage(S, from, kind, w)
  if kind ~= "MC" then return false end
  if S.role == "friend" and from == "host" then onMC(S, w) end
  return true
end

function MC.status()
  local n = 0; for _ in pairs(MC.cur or {}) do n = n + 1 end
  local h = 0; for _ in pairs(MC.host or {}) do h = h + 1 end
  local P, why = native()
  return string.format("maint: read %d, host entries %d, differing %d, native %s", n, h, MC.ndiff or 0, P and ((P.status().items.MAINT or {}).why or "") or tostring(why))
end

-- a join or resync: the world module's keyframe makes the host send everything again; this module too
local function wrapKeyframe()
  local W = rawget(C, "world")
  if W and W.keyframe and W.keyframe ~= MC.kfWrap then
    local kf = W.keyframe
    MC.kfWrap = function(...) MC.fullT = -1e9; return kf(...) end
    W.keyframe = MC.kfWrap
  end
end
wrapKeyframe()
local function wrapLoad()
  local Mn = rawget(C, "men")
  if Mn and Mn.loadBegins ~= MC.lbWrap then
    local lb = Mn.loadBegins
    MC.lbWrap = function(...) pcall(MC.loadBegins); if lb then return lb(...) end end
    Mn.loadBegins = MC.lbWrap
  end
end
wrapLoad()

C.register("maint", { onWorld = function(S)
  local P = rawget(C, "patch"); if P and P.fn and P.send then pcall(P.send, "MAINT FORGET") end
  reset(); MC.minWall = MC.lastWall; wrapKeyframe(); wrapLoad()
end, tick = tick, onMessage = onMessage })
return "coop_x_maint loaded"
