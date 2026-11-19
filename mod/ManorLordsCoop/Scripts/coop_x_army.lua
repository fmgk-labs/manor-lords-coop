-- Manor Lords Co-op: army additions (lane 4, session 21). Loaded after coop.lua; uses its order code (C.armyApi).
--
-- What is here, and how each piece was exercised, is in research/2026-11-10-game-probe/lanes/lane_s21_4/report.md.
--   NAME   a squad's name (PawnCPP:renameSquad). Both copies compare the names of the player's squads twice a second;
--          a friend sends "O NAME", the host applies it and tells every friend ("A NAME").
--   WAY    a chain of waypoints for a friend's squad. The game keeps its own chain in a list that cannot be reached
--          from Lua, so the host keeps the chain here and gives the squad its next move when it arrives.
--   command buttons: a press on a stance or skill button marks the moment (S.btnT); for 0.6 s the core's watcher
--          reports this player's stance and skill changes also during a fight (it reports nothing in a fight otherwise).
--   helper lord: made a few seconds after a world is loaded, so that the first move order finds it ready.
--   RETHIRE hire a retainer at the manor (town setter). Pressed both ways by lane 26 (coop_test_rich).
--   RNAME  a retainer's name (lane 26): see the section at the end.
--   RLOOK, RGEAR, RCOLOR, RPAY  a retainer's looks (lane 26), equipment incl. the armour upgrade, colours, and the
--          upgrade's price (lane 29): the same section.
--   PATH   the path order (Ctrl + right drag) and BLD, the order against a building (a right click on a bandit camp):
--          lane 28, read from the native piece's hook on the game's order routine and replayed with that routine. See
--          the section "PATH and BLD" near the end. A friend sends "O PATH <squad> <points>" / "O BLD <squads>
--          <building> <x> <y> <z>", the host applies it and tells every friend ("A PATH", "A BLD").
-- Messages: friend to host "O <KIND> <squad> ..." (the core's order line, answered in the host's log as APPLIED);
-- host to friends "A <KIND> <host squad> ...".

local C = rawget(_G, "Coop")
if not (C and C.register and C.api and C.armyApi) then return "coop_x_army: load coop.lua first" end
local A, R = C.api, C.armyApi
local M = rawget(C, "army") or {}; C.army = M
local valid, log, send, far = A.valid, A.log, A.send, A.far

local function enc(s) return "=" .. (tostring(s):gsub("[^%w]", function(ch) return string.format("%%%02X", ch:byte()) end)) end
local function dec(s) return (tostring(s or ""):gsub("^=", ""):gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)) end
local function stat(S, k) S.stats[k] = (S.stats[k] or 0) + 1 end

local function reset() M.names = {}; M.fresh = {}; M.way = {}; M.worldT = os.clock()
  M.form = {}; M.hostShape = {}; M.sentSeq = {}; M.sentT = {}; M.lastTag = {}; M.lent = {}; M.measQ = {}; M.pend = {}; M.pendSq = {}; M.ackWall = {} end   -- (lane 70) shapes
if not M.names then reset() end

-- ================================================================ NAME
local function nameOf(S, h)
  local ok, n = pcall(function() return S.sc:GetSquad({ Value = h }).Name:ToString() end)
  return ok and n or nil
end
local function setName(S, h, name)
  M.names[h] = name                                  -- set by the mod: not the player's own change
  return pcall(function() S.p1:renameSquad({ Value = h }, name) end)
end
local function scanNames(S, clock)
  local arr = S.p1.commandedSquads
  for i = 1, #arr do
    local h = arr[i].Value
    if R.sqValid(h) then
      local n = nameOf(S, h); local k = M.names[h]
      if n and k == nil then
        M.names[h] = n
        -- a squad made during the session gets its name from each copy's own game: the host's name counts
        if S.role == "host" and clock - M.worldT > 5.0 then M.fresh[h] = clock end
      elseif n and n ~= k then
        M.names[h] = n
        if S.role == "host" then send(string.format("A NAME %d %s", h, enc(n))); log("ARMY squad %d renamed to [%s] here: sent to friends", h, n)
        elseif not C.hold then send(string.format("O NAME %d %s", A.toHost(h), enc(n))); log("ARMY this player renamed squad %d to [%s]: sent to the host", h, n) end
        stat(S, "a_names")
      end
    end
  end
  if S.role == "host" then
    for h, t in pairs(M.fresh) do
      if clock - t > 2.0 then
        M.fresh[h] = nil
        if R.sqValid(h) then local n = nameOf(S, h); if n then M.names[h] = n; send(string.format("A NAME %d %s", h, enc(n))) end end
      end
    end
  end
end

-- ================================================================ WAY (host keeps the chain)
local ARRIVE = 600          -- the squad's centre within 6 m of the point: arrived
local function wayAdd(S, h, x, y, z)
  if not R.sqValid(h) then return "no such squad" end
  if S.sc:GetUnitCount({ Value = h }) == 0 then return "empty" end
  local clock = os.clock(); local q = M.way[h]
  if not q then
    local st = R.sqState(h)
    -- still walking to an earlier point: the new one waits until it arrives there
    local walking = st.tgt == 0 and not (st.tx == 0 and st.ty == 0) and far(st.cx, st.cy, st.tx, st.ty, ARRIVE)
    q = { list = {}, cur = walking and { x = st.tx, y = st.ty, z = st.tz } or nil, took = walking and { x = st.tx, y = st.ty } or nil,
          t = clock, cx = st.cx, cy = st.cy, mt = clock }
    M.way[h] = q
  end
  if #q.list >= 16 then return "too many waypoints" end
  q.list[#q.list + 1] = { x = x, y = y, z = z or 0 }
  stat(S, "a_ways")
  return "queued " .. #q.list
end
local function wayTick(S, clock)
  for h, q in pairs(M.way) do
    if not R.sqValid(h) or S.sc:GetUnitCount({ Value = h }) == 0 then M.way[h] = nil
    else
      local st = R.sqState(h)
      if far(st.cx, st.cy, q.cx, q.cy, 50) then q.cx, q.cy, q.mt = st.cx, st.cy, clock end        -- it is still walking
      if st.eng or st.tgt ~= 0 or st.ctl == 3 then
        M.way[h] = nil; log("ARMY waypoints of squad %d dropped: it fights or flees", h)
      else
        -- The target the squad takes is not the point asked for (the game sets its own, up to some metres away: asked
        -- 98509,-77711, taken 98498,-77314). So the target it took is remembered (q.took: the first target that differs
        -- from the one before the move), and "another order" means: its target is no longer that one.
        local dropped = false
        if q.cur and not q.took then
          if q.pre and far(st.tx, st.ty, q.pre.x, q.pre.y, 30) then q.took = { x = st.tx, y = st.ty }
          elseif q.pre and clock - q.t > 1.0 and far(st.cx, st.cy, q.cur.x, q.cur.y, ARRIVE) then
            -- the move did not take (the target is still the one from before): give it again, three times at most
            if (q.tries or 0) < 3 then
              q.tries = (q.tries or 0) + 1; q.t = clock; q.mt = clock
              R.moveOrder(h, { X = q.cur.x, Y = q.cur.y, Z = q.cur.z })
              log("ARMY squad %d did not take the move to %.0f,%.0f: given again (%d)", h, q.cur.x, q.cur.y, q.tries)
            else M.way[h] = nil; dropped = true; log("ARMY waypoints of squad %d dropped: it does not take the move", h) end
          end
        elseif q.cur and far(st.tx, st.ty, q.took.x, q.took.y, 60) then
          M.way[h] = nil; dropped = true; log("ARMY waypoints of squad %d dropped: it has another order", h)       -- the host player ordered it meanwhile
        end
        local goal = q.took or q.cur
        local arrived = not dropped and ((not q.cur) or not far(st.cx, st.cy, q.cur.x, q.cur.y, ARRIVE) or (q.took and not far(st.cx, st.cy, goal.x, goal.y, ARRIVE))
                        or (q.took and clock - q.t > 3.0 and clock - q.mt > 3.0))
        if arrived then
          local nx = table.remove(q.list, 1)
          if not nx then M.way[h] = nil
          else
            q.cur = nx; q.t = clock; q.mt = clock; q.pre = { x = st.tx, y = st.ty }; q.tries = 0; q.took = nil
            R.moveOrder(h, { X = nx.x, Y = nx.y, Z = nx.z })
            log("ARMY squad %d goes to its next waypoint %.0f,%.0f (%d left)", h, nx.x, nx.y, #q.list)
          end
        end
      end
    end
  end
end
-- for the console and for the watcher: add a waypoint for a squad of this player (local squad number)
function M.waypoint(h, x, y, z)
  local S = C.s; if not S then return "not started" end
  if S.role == "host" then return wayAdd(S, h, x, y, z or 0) end
  send(string.format("O WAY %d %.0f %.0f %.0f", A.toHost(h), x, y, z or 0)); S.localOrderT[h] = os.clock()
  return "sent"
end

-- ================================================================ host: orders of this module
C.armyOrder = function(S, kind, h, w)
  if kind == "NAME" then
    if not (h and R.sqValid(h)) then return "no such squad" end
    local name = dec(w[6]); if #name > 64 then name = name:sub(1, 64) end
    if nameOf(S, h) == name then return "ok (same)" end
    local old = M.names[h]
    local ok, e = setName(S, h, name)
    M.names[h] = old                               -- the scan sees the change and tells every friend
    return ok and "ok" or ("ERR " .. tostring(e))
  end
  if kind == "WAY" then return wayAdd(S, h, tonumber(w[6]) or 0, tonumber(w[7]) or 0, tonumber(w[8]) or 0) end
  -- (lane 27) spread out, from a friend: set here and told to every friend (the core's mirror leaves skill 4 alone)
  if kind == "SKILL" and w[6] == "4" then
    if not (h and R.sqValid(h)) then return "no such squad" end
    if S.sc:GetUnitCount({ Value = h }) == 0 then return "empty" end
    local on = w[7] == "on"
    S.sc:SetSkillActive({ Value = h }, 4, on, true)
    local now = S.sc:IsSkillActiveForSquad({ Value = h }, 4) and true or false
    send(string.format("A SPREAD %d %s", h, now and "on" or "off")); stat(S, "a_spread")
    return now == on and "ok" or ("not taken here (" .. (now and "on" or "off") .. ")")
  end
  -- any other order for the squad ends its chain of waypoints
  if h and M.way[h] and (kind == "MOVE" or kind == "ATTACK" or kind == "STOP" or kind == "HOME" or kind == "REMOVE" or (kind == "SKILL" and w[6] == "8" and w[7] == "on")) then
    M.way[h] = nil; log("ARMY waypoints of squad %d ended by the player's %s order", h, kind)
  end
  return nil
end

-- ================================================================ friend: what the host says
local function onMessage(S, from, kind, w, line)
  if kind ~= "A" then return false end
  if S.role ~= "friend" or from ~= "host" or C.hold then return true end
  local act, hh = w[4], tonumber(w[5])
  if act == "NAME" and hh then
    local h = A.toLocal(hh)
    if R.sqValid(h) then
      local name = dec(w[6])
      if nameOf(S, h) ~= name then setName(S, h, name); stat(S, "a_named"); log("ARMY squad %d is called [%s] on the host: named here", h, name); if C.panels and C.panels.touched then pcall(C.panels.touched, "A:NAME", nil) end end
    end
  elseif act == "SPREAD" and hh then
    local h = A.toLocal(hh)
    if R.sqValid(h) and S.sc:GetUnitCount({ Value = h }) > 0 then
      local on = w[6] == "on"
      if (S.sc:IsSkillActiveForSquad({ Value = h }, 4) and true or false) ~= on then
        -- the squad's formation (and with it its target point) changes a moment later: not this player's move (seen in
        -- the first run: two stray O MOVE lines). The core's watcher skips a squad the mirror touched; 1.6 s here.
        if S.mirT then S.mirT[h] = os.clock() + 1.0 end
        S.sc:SetSkillActive({ Value = h }, 4, on, true); stat(S, "a_spreadSet")
        if C.panels and C.panels.touched then pcall(C.panels.touched, "A:SPREAD", nil) end   -- (lane 69) open army panels redraw
        log("ARMY squad %d spread out %s on the host: set here", h, w[6])
      end
    end
  end
  return true
end

-- ================================================================ input window for the army command buttons
local BTN = { "/Game/UI/HUD/W_HUD_ArmySkillButtonV2.W_HUD_ArmySkillButtonV2_C:HandleClicked",
              "/Game/UI/HUD/W_HUD_ArmyStanceButtonV2.W_HUD_ArmyStanceButtonV2_C:HandleClicked" }
local RM = { "/Game/UI/HUD/W_HUD_ArmyUnitCardV2.W_HUD_ArmyUnitCardV2_C:TryRemoveMySquad",
             "/Game/UI/HUD/W_HUD_ArmyCommandList.W_HUD_ArmyCommandList_C:RemoveSelectedSquads" }
local function ensureHooks(S, clock)
  if rawget(_G, "__coop_army_hooks_done") or clock - (M.hookT or -10) < 3.0 then return end
  M.hookT = clock
  _G.__coop_army_hooked = rawget(_G, "__coop_army_hooked") or {}
  local all = true
  for _, path in ipairs(BTN) do
    if not _G.__coop_army_hooked[path] then
      local ok = pcall(RegisterHook, path, function(self)
        local S2 = _G.Coop and _G.Coop.s
        -- (lane 27) the spread-out button, on every copy: its squads' new state is read and sent in the tick (SPREAD below)
        if S2 and S2.on then
          local okS, nmS = pcall(function() return self:get():GetFName():ToString() end)
          if okS and nmS == "Skill_SpreadOut" then _G.Coop.army.spreadT = os.clock() end
        end
        if S2 and S2.on and S2.role == "friend" then
          S2.btnT = os.clock(); S2.stats.a_btn = (S2.stats.a_btn or 0) + 1
          -- the halt button leaves no lasting skill on the squad, and what it does to the target is not read as a
          -- move after a button press: it is passed on by name (tick, below)
          local okN, nm = pcall(function() return self:get():GetFName():ToString() end)
          if okN and nm == "Skill_Halt" then _G.Coop.army.haltT = os.clock() end
          -- the send-home button: the core's watcher passes on "went home" and "is gone" only after this press
          -- (lane 16: the game also sends units home and removes them by itself)
          if okN and nm == "Skill_Disband" then S2.disbandT = os.clock() end
        end
      end)
      if ok then _G.__coop_army_hooked[path] = true else all = false end
    end
  end
  -- (lane 16) the army panel's two ways to remove a unit (read in the game's blueprint scripts: the unit card's
  -- TryRemoveMySquad calls PawnCPP:removeSquad, the command list's RemoveSelectedSquads calls
  -- SquadComponent:RequestRemoveSquad). They only note the moment, for the core's watcher.
  for _, path in ipairs(RM) do
    if not _G.__coop_army_hooked[path] then
      local ok = pcall(RegisterHook, path, function(self)
        local S2 = _G.Coop and _G.Coop.s
        if S2 and S2.on and S2.role == "friend" then S2.rmInT = os.clock() end
      end)
      if ok then _G.__coop_army_hooked[path] = true else all = false end
    end
  end
  if all then _G.__coop_army_hooks_done = true; log("ARMY command button hooks registered") end
end

local function tick(S, clock)
  if C.hold or not (valid(S.p1) and valid(S.sc)) then return end
  ensureHooks(S, clock)
  if (S.stats.a_btn or 0) ~= (M.btnSeen or 0) then M.btnSeen = S.stats.a_btn; log("ARMY command button pressed: stance and skill changes are reported for a moment (%d)", M.btnSeen) end
  -- Halt pressed on a friend's copy: the host halts the same squads (the player's selected ones). Seen in the last
  -- session of lane 4: a halt pressed during a chain of waypoints never reached the host.
  if M.haltT and S.role == "friend" then
    M.haltT = nil
    local okS, e = pcall(function()
      local sel = S.p1.selectedSquads; local n = 0
      for i = 1, #sel do
        local h = sel[i].Value
        if h and h ~= 0 and S.mine[h] and R.sqValid(h) then send(string.format("O SKILL %d 8 on", A.toHost(h))); S.localOrderT[h] = clock; n = n + 1 end
      end
      log("ARMY halt pressed: sent to the host for %d squad(s)", n)
    end)
    if not okS then log("ARMY halt pressed: could not read the selection (%s)", tostring(e)) end
  end
  -- The helper lord through which moves are given is made a few seconds after a world is loaded, not with the first
  -- order: a move given through a helper made in the same moment did nothing (lane 4, session 21: the first move
  -- after a resync was lost on the host; "helper lord created" stood in the log beside it).
  -- (lane 27) SPREAD: the spread-out button (skill 4) was pressed on this copy. The core never sends skill 4 (it uses
  -- it itself to make an order take: commit() switches it and back in one call), so the state of the selected squads
  -- is read here a moment after the press: a friend sends it to the host (O SKILL <squad> 4 on|off, applied in
  -- C.armyOrder above), the host tells every friend (A SPREAD <squad> on|off).
  if M.spreadT and clock - M.spreadT >= 0.15 then
    M.spreadT = nil
    pcall(function()
      local sel = S.p1.selectedSquads; local n = 0
      for i = 1, #sel do
        local h = sel[i].Value
        if h and h ~= 0 and R.sqValid(h) and (S.role == "host" or S.mine[h]) then
          local st = S.sc:IsSkillActiveForSquad({ Value = h }, 4) and "on" or "off"
          if S.role == "host" then send(string.format("A SPREAD %d %s", h, st))
          else send(string.format("O SKILL %d 4 %s", A.toHost(h), st)); S.localOrderT[h] = clock end
          n = n + 1
        end
      end
      log("ARMY spread-out pressed: %d squad(s) sent", n)
    end)
  end
  if not valid(S.hp) and clock - M.worldT > 3.0 and clock - (M.helpT or 0) > 5.0 then M.helpT = clock; pcall(A.helper) end
  if clock - (M.tName or 0) >= 0.5 then M.tName = clock; scanNames(S, clock) end
  if S.role == "host" and next(M.way) and clock - (M.tWay or 0) >= 0.25 then M.tWay = clock; wayTick(S, clock) end
end

-- ================================================================ RETHIRE (retinue: "hire a retainer" at the manor)
-- One named game call on the manor (SMBuildingMaster:hireExtraRetinue, no arguments): caught and replayed with the town
-- module's setter pattern. Each copy's game makes its own retainer (name and looks are rolled per copy).
--   status: see the lane report (the test town has no manor)
local X = C.town and C.town.api
if X and X.setter then X.setter("RETHIRE", "SMBuildingMaster", "hireExtraRetinue", "", "press2", "lane 26 report", true) end

-- ================================================================ RNAME (lane 26): the names of the manor's retainers
-- The retinue editor's name box writes the retainer's DisplayName (measured: lane_s21_26 out/r2_retainer_measure.txt).
-- A retainer is named by its manor and its place in getBoundRetinue() (both copies append a hire at the end).
-- Every copy compares the names twice a second. A change on a friend goes to the host ("K RNAME <manor> <n> <name>");
-- the host writes it and tells every friend; a change on the host goes to every friend. A retainer hired during the
-- session gets a name rolled by each copy's own game: the host sends its name 1.5 s after it appears, so all agree.
-- Looks, equipment and colours: RLOOK, RGEAR, RCOLOR below (lanes 26 and 29).
local RT = {}
local function rreset() RT = {}; M.rfresh = {} end
rreset()
local function rmanors(S)
  local t = {}; local ok, a = pcall(function() return S.p1:getManors() end)
  if ok and a then for i = 1, #a do local m = A.un(a[i]); if valid(m) then t[#t + 1] = m end end end
  return t
end
local function retinue(m)
  local ok, a = pcall(function() return m:getBoundRetinue() end); if not ok or not a then return {} end
  local t = {}; for i = 1, #a do t[i] = A.un(a[i]) end          -- within the list only (a read past its end grows it)
  return t
end
local function rname(u) local ok, n = pcall(function() return u.DisplayName:ToString() end); return ok and n or nil end
-- RLOOK (lane 26, second part): the editor's look buttons write the retainer's equipmentMeshVariations and
-- equipmentTextureVariations maps (slot -> variation); a hire rolls them per copy (lane 26 fault 1). A copy writes them
-- with the maps' Add and the game's own SetVAMPVariationsToEquipment() (measured: out/s4_looks_planchg.txt step 2).
-- Same rules as the name: compared twice a second, host decides, the host's roll goes out 1.5 s after a hire.
local LOOKMAPS = { m = "equipmentMeshVariations", t = "equipmentTextureVariations" }
local function rlook(u)
  local parts = {}
  for _, tag in ipairs({ "m", "t" }) do
    local kv = {}
    local ok = pcall(function() u[LOOKMAPS[tag]]:ForEach(function(k, v) kv[#kv + 1] = { tonumber(k:get()), tonumber(v:get()) } end) end)
    if not ok then return nil end
    table.sort(kv, function(x, y) return x[1] < y[1] end)
    local s = {}; for _, e in ipairs(kv) do s[#s + 1] = e[1] .. ":" .. e[2] end
    parts[#parts + 1] = tag .. table.concat(s, ".")
  end
  return table.concat(parts, "/")
end
local function setLook(u, look)
  for tag, body in look:gmatch("(%a)([%d:%.]*)") do
    local mp = LOOKMAPS[tag]
    if mp then for k, v in body:gmatch("(%d+):(%d+)") do u[mp]:Add(tonumber(k), tonumber(v)) end end
  end
  u:SetVAMPVariationsToEquipment()
end
-- RGEAR and RCOLOR (lane 29): the rest of the retinue editor. Measured on coop_test_rich (lane_s21_29 out/h1_measures.txt):
-- the "upgrade armour" buttons write two members of the retainer's equipmentOnRally struct (bodyType 164 -> 293,
-- helmetType 276 -> 294) and take the price; a hire rolls Equipment.helmetType per copy (282 / 292, lane 26 fault 1);
-- the colour drop-downs call the game's setVAMPColorSchemeUVsForSlot (7 slots, a vector each). Both structs are read
-- and written by their members' names (the struct is opaque only to GetEquippedID, which lane 26 read). Same rules as
-- the name and looks: compared twice a second, host decides, a hire takes the host's values.
-- Only the rally set travels. Equipment (what the retainer wears and carries now) is changed by the game itself while
-- the retainer works (lane 29 s2 soak: its wpnType went 0 -> 22 / 223 / 263 and back on each copy at its own time, and
-- the first version sent and wrote those: 29 lines in 2 minutes, a host value written over a working retainer). So the
-- per-hire roll of the worn helmet (282 / 292) is NOT carried; the rally set (what the retainer fights in, and what the
-- armour upgrade writes) is.
local GEARS = { r = "equipmentOnRally" }
local GEARM = nil
local function gearMembers()
  if GEARM then return GEARM end
  local names = {}
  pcall(function()
    StaticFindObject("/Script/ManorLords.SMUnit"):ForEachProperty(function(p)
      if p:GetFName():ToString() == "Equipment" then p:GetStruct():ForEachProperty(function(q) names[#names + 1] = q:GetFName():ToString() end) end
    end)
  end)
  if #names > 0 then GEARM = names end
  return names
end
local function rgear(u)
  local ms = gearMembers(); if #ms == 0 then return nil end
  local parts = {}
  for _, tag in ipairs({ "r" }) do
    local s = {}
    local ok = pcall(function() local st = u[GEARS[tag]]; for i, n in ipairs(ms) do s[i] = tostring(math.floor(tonumber(st[n]) or 0)) end end)
    if not ok then return nil end
    parts[#parts + 1] = tag .. table.concat(s, ",")
  end
  return table.concat(parts, "/")
end
local function setGear(u, v)
  local ms = gearMembers()
  for tag, body in v:gmatch("(%a)([%d,%-]*)") do
    local sp = GEARS[tag]
    if sp then local i = 0; for x in body:gmatch("[^,]+") do i = i + 1; local n = ms[i]; if n then u[sp][n] = tonumber(x) end end end
  end
end
local function rcolor(u)
  local s = {}
  for sl = 0, 6 do
    local ok, c = pcall(function() return u:getVAMPColorSchemeUVsForSlot(sl) end)
    if not (ok and c) then return nil end
    s[#s + 1] = string.format("%.3f,%.3f,%.3f", c.X, c.Y, c.Z)
  end
  return table.concat(s, ";")
end
local function setColor(u, v)
  local sl = 0
  for x, y, z in v:gmatch("([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)") do
    if sl > 6 then break end                          -- (lane 55) the game has slots 0 to 6 (rcolor)
    u:setVAMPColorSchemeUVsForSlot(sl, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }); sl = sl + 1
  end
end
local FIELDS = {
  RNAME = { read = rname, write = function(u, v) u.DisplayName = v end, what = "name" },
  RLOOK = { read = rlook, write = setLook, what = "looks" },
  RGEAR = { read = rgear, write = setGear, what = "equipment" },
  RCOLOR = { read = rcolor, write = setColor, what = "colours" },
  -- (lane 29, round 2) the worn helmet a hire rolls per copy (282 / 292): the host's roll is sent with the hire and
  -- written once; never compared later (the worn set changes by itself while the retainer works).
  RHELM = { read = function(u) local ok, v = pcall(function() return u.Equipment.helmetType end); return ok and v and tostring(math.floor(v)) or nil end,
            write = function(u, v) u.Equipment.helmetType = tonumber(v); u:SetVAMPVariationsToEquipment() end, what = "worn helmet", hireOnly = true },
}
-- The armour upgrade's price: the editor's upgradeCurrentRetainersArmor(buyLocally, price) pays on the copy that pressed
-- it. A friend's payment would be undone by the host's treasury (the host's silver is the truth), so a friend tells the
-- host the price ("K RPAY <manor> <price> <buyLocally 0|1>") and the host takes it from the lord's treasury. Paid with
-- the region's goods (buyLocally), the host makes the game's own goods branch: one armour (good 293) consumed from the
-- manor's region and the price added to its wealth.
local RE = "/Game/UI/Army/retinueEditor.retinueEditor_C:upgradeCurrentRetainersArmor"
local rpayHooked, rpayTry = false, -100
local function hookPay(S, clock)
  if rpayHooked or S.role ~= "friend" or clock - rpayTry < 10.0 then return end
  rpayTry = clock                                           -- the editor's class may load late: tried every 10 s until it hooks
  rpayHooked = pcall(function()
    RegisterHook(RE, function(self, a1, a2)
      if C.hold then return end
      local okL, local1 = pcall(function() return a1:get() end); local okP, price = pcall(function() return a2:get() end)
      local mk = "-"
      pcall(function() local m = rmanors(C.s)[1]; if m then mk = X.bkeyOf(X.bident(m)) end end)
      price = okP and math.floor(tonumber(price) or 0) or 0
      -- s1 (lane 29): the hook read the price argument as 0. The treasury drop since the last scan (at most 0.5 s ago)
      -- is what this copy paid.
      if price <= 0 and M.silv then local okS, now = pcall(function() return C.s.p1.silver end); if okS and now then price = math.floor(M.silv - now) end end
      -- (round 2) paid with the region's goods: the game consumes one armour (good 293) of the manor's region and adds the
      -- price to that region's wealth, only when the good was there (read in the blueprint). The wealth gain since the last
      -- scan is the price; none = nothing was bought, nothing is sent.
      local fee = 0
      if okL and local1 then
        -- (s5) the goods branch also takes silver from the treasury (13 of 2850 there): sent as the fee
        fee = (price > 0) and price or 0
        price = 0
        pcall(function() local m = rmanors(C.s)[1]; local w = m:GetRegion().regionalWealth; if M.rwealth then price = math.floor(w - M.rwealth) end end)
      end
      if price <= 0 then log("RETINUE armour upgrade pressed, nothing paid on this copy (not bought): nothing sent"); return end
      send(string.format("K RPAY %s %d %d %d", mk, price, (okL and local1) and 1 or 0, fee))
      log("RETINUE this player paid %d for an armour upgrade (%s): sent to the host", price, (okL and local1) and "goods" or "silver")
    end)
  end)
end
local function rline(kind, mk, i, v) return string.format("K %s %s %d %s", kind, mk, i, enc(v)) end
local function scanRetinue(S, clock)
  if not (X and X.bkeyOf) then return end
  for _, m in ipairs(rmanors(S)) do
    local mk = X.bkeyOf(X.bident(m))
    if mk == "-" then return end                        -- (lane 76) a manor without a usable name (a cleared actor): nothing read, nothing sent
    local arr = retinue(m)
    local n0 = RT[mk]                                   -- the list's length when last read
    if n0 ~= #arr then
      -- The list grew (a hire) or shrank (a retainer died or left): values are read again and nothing is sent, since a
      -- shifted list would look like changes. The host marks the new end of a grown list: its values go to the friends.
      for i, u in ipairs(arr) do
        for kind, f in pairs(FIELDS) do RT[kind .. mk .. "#" .. i] = f.read(u) end
        if S.role == "host" and n0 and i > n0 and clock - M.worldT > 5.0 then M.rfresh[mk .. "#" .. i] = { t = clock, mk = mk, i = i } end
      end
      for i = #arr + 1, (n0 or 0) do for kind in pairs(FIELDS) do RT[kind .. mk .. "#" .. i] = nil end; M.rfresh[mk .. "#" .. i] = nil end
      RT[mk] = #arr
      arr = {}
    end
    for i, u in ipairs(arr) do
      for kind, f in pairs(FIELDS) do
        local key = kind .. mk .. "#" .. i; local v = (not f.hireOnly) and f.read(u) or nil; local k = RT[key]
        if v and k == nil then RT[key] = v
        elseif v and v ~= k then
          RT[key] = v
          if S.role == "host" then send(rline(kind, mk, i, v)); log("RETINUE retainer %d of %s: %s changed here to [%s]: sent to friends", i, mk, f.what, v)
          elseif not C.hold then send(rline(kind, mk, i, v)); log("RETINUE this player changed the %s of retainer %d of %s to [%s]: sent to the host", f.what, i, mk, v) end
          stat(S, "k_" .. kind)
        end
      end
    end
  end
  if S.role == "host" then
    for key, e in pairs(M.rfresh) do
      if clock - e.t > 1.5 then
        M.rfresh[key] = nil
        for kind, f in pairs(FIELDS) do local v = RT[kind .. key]; if v then send(rline(kind, e.mk, e.i, v)); log("RETINUE new retainer %d of %s: %s [%s] here: sent to friends", e.i, e.mk, f.what, v) end end
      end
    end
  end
end
local function applyField(S, kind, mk, i, v)
  local f = FIELDS[kind]
  local m = X and X.findBkey(mk); if not m then return "manor not found" end
  local arr = retinue(m); i = tonumber(i)
  if not i or i < 1 or i > #arr then return "no retainer number " .. tostring(i) .. " (" .. #arr .. " here)" end
  local u = arr[i]; RT[kind .. mk .. "#" .. i] = v
  if f.read(u) == v then return "same" end
  local ok, e = pcall(f.write, u, v); if not ok then return "error " .. tostring(e) end
  RT[kind .. mk .. "#" .. i] = f.read(u) or v
  if C.panels and C.panels.touched then pcall(C.panels.touched, "RETINUE", m) end   -- (lane 69) another player's retinue change: open panels redraw
  return "ok"
end
local function onRetinue(S, from, w)
  local kind = w[4]
  if kind == "RPAY" then
    if S.role == "host" and from ~= "host" then
      local price, goods = tonumber(w[6]), w[7] == "1"
      if price and price > 0 and price < 100000 and not goods then
        local s0 = S.p1.silver; local ok, e = pcall(function() S.p1:ChangeTreasury(-price) end)
        log("RETINUE from %s: armour upgrade paid %d silver: lord's treasury %s -> %s (%s)", from, price, tostring(s0), tostring(S.p1.silver), ok and "ok" or tostring(e))
      elseif price and price > 0 and goods then
        -- the game's own goods branch, on the host: one armour (293) from the manor's region, the price to its wealth
        local m = X and X.findBkey(w[5]); local r; pcall(function() r = m:GetRegion() end)
        local ok, got = pcall(function() return r:consumeGood(293, 1, nil, false, true, true) end)
        if ok and got then pcall(function() r:addRegionalWealth(price) end) end
        local fee = tonumber(w[8] or "0") or 0
        if ok and got and fee > 0 and fee < 100000 then pcall(function() S.p1:ChangeTreasury(-fee) end); log("RETINUE from %s: the goods upgrade's silver part %d taken from the lord's treasury", from, fee) end
        log("RETINUE from %s: armour upgrade paid with the region's goods: one armour taken here %s, wealth +%d", from, tostring(ok and got), (ok and got) and price or 0)
      else log("RETINUE from %s: armour upgrade paid %s: nothing taken here", from, tostring(w[6])) end
    end
    return true
  end
  if not FIELDS[kind] then return true end
  local mk, i, v = w[5], w[6], dec(w[7])
  if S.role == "host" and from ~= "host" then
    local r = applyField(S, kind, mk, i, v)
    log("RETINUE from %s: %s of retainer %s of %s -> [%s]: %s", from, FIELDS[kind].what, tostring(i), tostring(mk), v, r)
    if r == "ok" or r == "same" then send(rline(kind, mk, tonumber(i), v)) end
  elseif S.role == "friend" and from == "host" and not C.hold then
    local r = applyField(S, kind, mk, i, v)
    log("RETINUE host says the %s of retainer %s of %s is [%s]: %s", FIELDS[kind].what, tostring(i), tostring(mk), v, r)
  end
  return true
end

-- ================================================================ PATH and BLD (lane 28)
-- Both orders are given by the game's native MoveSelected (a right click): with the waypoint flag it gives the one
-- selected squad the path drawn with Ctrl + right drag; with the pointer on a building a squad may be sent against
-- (a bandit camp: building type 100 or buildingFunction 17) it gives the selected squads that building as target;
-- with the pointer on a part of a building (cursorMode 7) the building and that part ("O BLD ... 7 <x,y of the part>").
-- Neither leaves the path or the building where a script can read it. So:
--   capture  the native piece hooks MoveSelected (coop_patch ORDERHOOK) and writes each call of the game's own to
--            patch_events.txt: the lord, the flags, the cursor point, the hover state, the selected squads and, for a
--            path, the path list as the call left it. This module reads the lines every tick (C.preOrders, called
--            by the core before its own order watcher), keeps those of this copy's own lord, and checks on the squad
--            that the order was really taken.
--   replay   the mod's helper lord gets the squads as its selection (and the building as hitBuilding with cursorMode
--            3), and the native piece runs the same routine: PATH (the press handler, the game's own path routine per
--            point, MoveSelected with the waypoint flag) or ORDERAT (cursor point, MoveSelected).
-- The outcome of a fight or of what happens at the building stays the host's (deaths, routs, fires, stock: the rules
-- that hold for every fight).
--   status: lanes/lane_s21_28/report.txt (two copies, both ways, after a resync)
local Xt = function() return C.town and C.town.api end
local function near2(ax, ay, bx, by, tol) return math.abs(ax - bx) <= tol and math.abs(ay - by) <= tol end
local function encPts1(pts) local t = {}; for i, q in ipairs(pts) do t[i] = string.format("%.1f,%.1f,%.1f", q.X, q.Y, q.Z) end; return table.concat(t, "|") end
local function quiet(S, h, clock)          -- this squad's next change is the mod's own: not the player's order, and the mirror waits a moment
  R.touch(h)
  local m = S.mir[h]; if m then m.t = clock end
end
-- the squads of a list that this copy can order now
local function liveSquads(S, list)
  local t = {}
  for _, h in ipairs(list) do if h and h ~= 0 and R.sqValid(h) and S.sc:GetUnitCount({ Value = h }) > 0 then t[#t + 1] = h end end
  return t
end
local function selTable(list) local t = {}; for i, h in ipairs(list) do t[i] = { Value = h } end; return t end
local function helperFor(S)
  if C.town and C.town.pend then return nil, "the helper is placing a building" end
  local hp = A.helper(); if not valid(hp) or hp.requestBuild then return nil, "no helper" end
  return hp
end
-- give squad h the path pts on this copy (the game's own routines, through the helper)
local function applyPath(S, h, pts, clock)
  local Pt = C.patch
  if not (Pt and Pt.pathAvail and Pt.pathAvail()) then return "the native piece (coop_patch PATH) is not available here" end
  if #pts < 2 or #pts > 64 then return "bad points" end
  local hp, why = helperFor(S); if not hp then return why end
  M.way[h] = nil                                         -- the older stand-in chain of this squad ends
  quiet(S, h, clock)
  local okC, ok, r = pcall(function()
    hp.selectedSquads = selTable({ h })
    hp.cursorMode = 0; hp.hitBuilding = nil
    return Pt.path(hp, true, pts)
  end)
  pcall(function() hp.selectedSquads = {}; hp.RMB_pressed_b = false end)
  if not okC then return "error " .. tostring(ok) end
  if not ok then return "refused: " .. tostring(r) end
  stat(S, "a_paths")
  return "ok", r
end
-- the part of building b that stands at x, y (its parts are its `buildings`), within 150
local function partAt(b, x, y)
  local best, bd
  local okP = pcall(function()
    local arr = b.buildings
    for i = 1, #arr do
      local a = A.un(arr[i])
      if valid(a) then local l = a:K2_GetActorLocation(); local d = math.abs(l.X - x) + math.abs(l.Y - y); if d <= 150 and (not bd or d < bd) then best, bd = a, d end end
    end
  end)
  return okP and best or nil
end
-- send the squads against building b on this copy. mode 3: the building itself (a bandit camp); mode 7: one of its
-- parts (the routine then also notes the part on the squad, Squad.targetBuildingPart)
local function applyBld(S, list, b, q, clock, mode, part)
  local Pt = C.patch
  if not (Pt and Pt.orderAvail and Pt.orderAvail()) then return "the native piece (coop_patch ORDER) is not available here" end
  if mode == 7 and not valid(part) then return "the building has no part at that place" end
  local hp, why = helperFor(S); if not hp then return why end
  for _, h in ipairs(list) do M.way[h] = nil; quiet(S, h, clock) end
  local okC, ok, r = pcall(function()
    hp.selectedSquads = selTable(list)
    hp.cursorMode = mode == 7 and 7 or 3; hp.hitBuilding = b
    if mode == 7 then hp.hitBuildingPart = part end
    return Pt.orderAt(hp, q, false, true)
  end)
  pcall(function() hp.cursorMode = 0; hp.hitBuilding = nil; hp.hitBuildingPart = nil; hp.selectedSquads = {} end)
  if not okC then return "error " .. tostring(ok) end
  if not ok then return "refused: " .. tostring(r) end
  stat(S, "a_blds")
  return "ok"
end
-- (lane 37, A082) the attack as a right click on an enemy gives it: the helper hovers one of the enemy's soldiers
-- (hoverUnit, bHoversEnemy, cursorMode 4, as the real click on the host showed) and the native piece runs MoveSelected
-- at that soldier's place. The squad's targetSquad is then the enemy at once; projectAttackFormation (the core's
-- stand-in) set only the target place, and targetSquad stayed 0 until the squads met (lane 34). nil = not done here
-- (the core then uses its stand-in).
-- Run in the game (lane 37, second sitting): the friend's mirror gave 27 attacks this way, every one left targetSquad =
-- the enemy (no miss, no fault). A clean real right click on an enemy far away was not achieved in that sitting.
C.attackNative = function(h, e)
  local S = C.s; local Pt = C.patch
  if not (Pt and Pt.orderAvail and Pt.orderAvail()) then return nil end
  local s = S.sc:GetSquad({ Value = h })
  local hp = helperFor(S); if not hp then return nil end
  local is = R.issuer(s); if not (valid(is) and is:GetAddress() == hp:GetAddress()) then return nil end   -- another lord's squad
  local d = R.unitsOf(e); if #d == 0 then return nil end
  local u = d[1]
  -- (lane 38) C.attackAim = { X, Y }: the enemy man nearest to that point is hovered (a friend aims where the host's
  -- squad aims, its TargetLocation: with the first man of the list each copy charged at another man of a camp whose
  -- men walk about on each copy, and its militia marched 4-9 m beside the host's, lane 38 s14)
  local aim = C.attackAim; C.attackAim = nil
  if aim then
    local bd = nil
    for _, m in ipairs(d) do local okL, l = pcall(function() return m:K2_GetActorLocation() end)
      if okL then local dd = (l.X - aim.X) ^ 2 + (l.Y - aim.Y) ^ 2; if not bd or dd < bd then bd = dd; u = m end end end
  end
  local q = u:K2_GetActorLocation()
  local okC, ok = pcall(function()
    hp.selectedSquads = selTable({ h }); hp.hitBuilding = nil; hp.hoverUnit = u; hp.bHoversEnemy = true; hp.cursorMode = 4
    return Pt.orderAt(hp, q, false, true)
  end)
  pcall(function() hp.cursorMode = 0; hp.hoverUnit = nil; hp.bHoversEnemy = false; hp.selectedSquads = {} end)
  if not (okC and ok) then return nil end
  if S.sc:GetSquad({ Value = h }).targetSquad.Value ~= e then stat(S, "a_attackNativeMiss"); return nil end
  stat(S, "a_attackNative")
  return "ok"
end
-- (lane 34, A081) give squad h the formation line a-b on this copy, the way the core's move does (formALineArmy).
-- A squad in a fight gets the core's move instead (halt first, then the move): the shape is lost there, the place not.
local function applyLine(S, h, a, b, clock)
  if not (h and R.sqValid(h)) or S.sc:GetUnitCount({ Value = h }) == 0 then return "no such squad" end
  quiet(S, h, clock)
  local s = S.sc:GetSquad({ Value = h })
  local mid = { X = (a.X + b.X) / 2, Y = (a.Y + b.Y) / 2, Z = (a.Z + b.Z) / 2 }
  if s.isEngaged or s.targetSquad.Value ~= 0 then R.moveOrder(h, mid); return "ok (in a fight: a plain move)" end
  local ok, e = pcall(function() R.issuer(s):formALineArmy({ { Value = h } }, { A = a, B = b }, FName("None"), { A = a, B = b }); (R.commitLine or R.commit)(h) end)
  if not ok then return "error " .. tostring(e) end
  stat(S, "a_lines")
  return "ok"
end
local function decLine(w, i)
  local n = {}; for k = i, i + 4 do n[#n + 1] = tonumber(w[k]) end
  if #n < 5 then return nil end
  return { X = n[1], Y = n[2], Z = n[5] }, { X = n[3], Y = n[4], Z = n[5] }
end

-- ================================================================ SHAPE (lane 70): the formation a line order ends in
-- Read in the game file (lanes/lane_70/report.txt; RVAs of 0.8.117). A line order on ONE squad, formALineArmy(P, Q):
--   * the squad's own line is P .. P + (L - 240) along P->Q (L = |Q - P| on the ground; half = L/2 - 120 at 4b459c4),
--     so a drag is 2.4 m wider than the formation it gives, and the formation starts at the press place P;
--   * files: fi = RoundToInt(segment / spread) clamped to 1..150 (4b43962); a rank holds fi + 1 men (columns 0..fi,
--     4b43f27); ranks = ceil(men / (fi + 1)); rows go to the left of P->Q, one spread apart; a part-filled last rank
--     is shifted (fi - m + 0.5) / 2 spreads along the line (4b43fbe); only men with their decals count (+0x440);
--   * spread (Squad.spread) is set by the game on every skill change (4d8d780): 120 when the squad's FIRST man has
--     meleeTraining <= 0.6, else 180 with spread out (skill 4), 95 with shield wall (skill 2), 180 mounted, else 120;
--     with the first man's meleeTraining <= 0.5 the squad forms a heap without ranks (4b43a1d);
--   * the target place the squad gets (TargetLocation) is the mean of its men's places (4b51eb0), not the middle of
--     the drag: so "2 * target - release place" (lane 34) came out about 2.4 m too long and turned by the ranks'
--     depth, and the host fitted about two files more than the player saw (the fault of G135);
--   * SetSkillActive forms the squad again on its stored line (Squad+0x158, the last segment) with its new spread
--     (4d83e11): a shield wall or spread out changes the files on the same line.
-- So a line order is carried by its RESULT: the copy that knows the line (the host for a friend's drag, the dragging
-- copy for its own) gives it with the game's routine, the host works out the shape it ended in and sends it to every
-- copy, also the one that gave the order ("A SHAPE"); each copy forms its squad on the host's line with the length
-- that gives the host's files with its own spread. The host sends the shape again whenever it changes (a skill, a
-- head count during a muster). Log lines: "ARMY shape ...".
local CUT, FMAX = 240.0, 150
local F06, F05 = 0.60000002384185791, 0.5                  -- the game's float constants 0.6 and 0.5
local function rhe(v)                                       -- round half to even (cvtsd2si)
  local fl = math.floor(v); local d = v - fl
  if d > 0.5 then return fl + 1 elseif d < 0.5 then return fl end
  return (fl % 2 == 0) and fl or fl + 1
end
local function filesOf(seg, sp)                             -- the game's fi for a segment of this length (cm)
  if not sp or sp <= 0 then sp = 100.0 end
  local fi = math.floor(rhe(2.0 * (math.abs(seg) * (1.0 / sp)) + 0.5) / 2)
  if fi > FMAX then fi = FMAX elseif fi < 1 then fi = 1 end
  return fi
end
local function ranksOf(n, fi) if n <= 0 then return 0 end; return math.ceil(n / (fi + 1)) end
-- the mean of the slots, in spreads: along the line from its start and across it (to the left)
local function centroidOf(n, fi)
  local per = fi + 1; local full = math.floor(n / per); local m = n - full * per
  local sa, sr = full * per * (fi / 2), per * (full * (full - 1) / 2)
  if m > 0 then sa = sa + m * ((m - 1) / 2 + (fi - m + 0.5) / 2); sr = sr + m * full end
  return sa / n, sr / n
end
M.shapeMath = { filesOf = filesOf, ranksOf = ranksOf, centroidOf = centroidOf, CUT = CUT }
local atan2 = math.atan2 or math.atan                -- (Lua 5.4: math.atan(y, x); 5.1 for the desk test: atan2)
local function angD(a, b) local d = math.abs(a - b) % (2 * math.pi); return math.min(d, 2 * math.pi - d) end
-- The press place behind a drag: the inverse of the game's one-squad line. Given the release place c, the squad's new
-- target t (the slots' mean), its men n and spread sp: every files value fi whose line length L = along + sqrt(|t-c|^2 -
-- across^2) gives fi back is a candidate; its direction follows from the same triangle. The men's own direction (dir,
-- set by the order to the line's direction) picks one. Returns P, L, how ("exact" one candidate near the men's
-- direction, "guess" otherwise) or nil.
local function dragFrom(n, sp, cx, cy, tx, ty, hx, hy)
  if n < 1 or not sp or sp <= 0 then return nil end
  local ux, uy = tx - cx, ty - cy; local rho2 = ux * ux + uy * uy
  local phi = atan2(uy, ux); local cands = {}
  for fi = 1, FMAX do
    local al, ac = centroidOf(n, fi)
    local b = ac * sp; local d2 = rho2 - b * b
    if d2 >= 0 then
      local L = al * sp + math.sqrt(d2)
      if L > CUT + 2 and filesOf(L - CUT, sp) == fi then cands[#cands + 1] = { fi = fi, L = L, th = phi - atan2(b, al * sp - L) } end
    end
  end
  if #cands == 0 then return nil end
  local pick, how = cands[1], (#cands == 1) and "exact" or "guess"
  if hx then
    local hth = atan2(hy, hx); local near = 0
    table.sort(cands, function(a, b) return angD(a.th, hth) < angD(b.th, hth) end)
    pick = cands[1]
    for _, c in ipairs(cands) do if angD(c.th, hth) < math.rad(4) then near = near + 1 end end
    how = (near == 1) and "exact" or "guess"
  end
  return { X = cx - pick.L * math.cos(pick.th), Y = cy - pick.L * math.sin(pick.th) }, pick.L, how, pick.fi, #cands
end
M.dragFrom = dragFrom
-- the same when the line's direction (hx, hy) is known exactly (the order writes it into every man's dir): the target's
-- part along the line gives L for each files value, its part across the line picks the files value. Offline
-- (lanes/lane_70/tools/shape_model.py, 6000 drags): exact without the men's random offsets; with them one file off in
-- 3.6 % (two ranks, nearly full: the offsets move the target as much as one file does); the drag's copy then follows
-- the line it sent (see onOrderEvent)
local function dragAlong(n, sp, cx, cy, tx, ty, hx, hy)
  if n < 1 or not sp or sp <= 0 then return nil end
  local a = (tx - cx) * hx + (ty - cy) * hy; local b = (tx - cx) * -hy + (ty - cy) * hx
  local best
  for fi = 1, FMAX do
    local al, ac = centroidOf(n, fi); local L = al * sp - a
    if L > CUT + 2 and filesOf(L - CUT, sp) == fi then
      local res = math.abs(b - ac * sp)
      if not best or res < best.res then best = { res = res, fi = fi, L = L } end
    end
  end
  if not best then return nil end
  return { X = cx - best.L * hx, Y = cy - best.L * hy }, best.L, best.res < 20 and "exact" or "guess", best.fi, best.res
end
M.dragAlong = dragAlong
-- this copy's squad: men (those of unitArr), spread, its first man's training, fight state, target place
local function shapeState(S, h)
  local s = S.sc:GetSquad({ Value = h })
  local arr = s.unitArr; local n = #arr; local units = {}
  for i = 1, n do local u = A.un(arr[i]); if valid(u) then units[#units + 1] = u end end
  local tr = -1; pcall(function() tr = tonumber(units[1].meleeTraining) or -1 end)
  local sk = {}; pcall(function() for i = 1, #s.activeSkills do sk[tonumber(A.un(s.activeSkills[i])) or -1] = true end end)
  local mount = false; pcall(function() mount = valid(units[1].mountActor) end)
  -- the spread the game's own rule gives (4d8d780), for the log: the squad's field is what counts
  local rule = 120.0
  if tr > F06 then if sk[4] then rule = 180.0 elseif sk[2] then rule = 95.0 elseif mount then rule = 180.0 end end
  return { s = s, n = #units, units = units, sp = tonumber(s.spread) or 0, rule = rule, train = tr, mob = tr >= 0 and tr <= F05,
           eng = s.isEngaged and true or false, tgt = s.targetSquad.Value, tx = s.TargetLocation.X, ty = s.TargetLocation.Y, ctl = s.Control }
end
-- the men's mean direction, and whether every man has the same one (the order has just written it: exact)
local function menDir(units)
  local fx, fy, ds = 0, 0, {}
  for _, u in ipairs(units) do local okD, d = pcall(function() return u.dir end); if okD and d then fx = fx + d.X; fy = fy + d.Y; ds[#ds + 1] = { d.X, d.Y } end end
  local l = math.sqrt(fx * fx + fy * fy); if l < 0.01 then return nil end
  local hx, hy = fx / l, fy / l; local same = #ds > 0
  for _, d in ipairs(ds) do if math.abs(d[1] - hx) > 1e-4 or math.abs(d[2] - hy) > 1e-4 then same = false; break end end
  return hx, hy, same
end
-- the press place of a drag from the squad's state (exact direction when the men all have it, else the angle fit)
local function pressOf(st, cx, cy, tx, ty)
  if st.mob then return nil, nil, "a heap" end
  local hx, hy, same = menDir(st.units)
  if hx and same then
    local P, L, how, fi, res = dragAlong(st.n, st.sp, cx, cy, tx, ty, hx, hy)
    if P then return P, L, how .. string.format(" (direction from the men, off by %.0f cm across)", res) end
  end
  local P, L, how, fi, nc = dragFrom(st.n, st.sp, cx, cy, tx, ty, hx, hy)
  if P then return P, L, how .. string.format(" (%d candidates%s)", nc, hx and "; the men's directions differ" or "") end
  return nil, nil, "no fit"
end
-- the segment the game forms on for a one-squad line P -> Q (signed: a line under 2.4 m turns round)
local function segOf(P, Q)
  local dx, dy = Q.X - P.X, Q.Y - P.Y; local L = math.sqrt(dx * dx + dy * dy); if L < 1 then return nil end
  local ux, uy = dx / L, dy / L; local sg = L - CUT
  if math.abs(sg) < 2 then return nil end
  return { ax = P.X, ay = P.Y, bx = P.X + ux * sg, by = P.Y + uy * sg, z = P.Z or Q.Z or 0 }
end
local function segLen(g) return math.sqrt((g.bx - g.ax) ^ 2 + (g.by - g.ay) ^ 2) end
-- the shape of squad h on this copy on segment g: files (fi), ranks, men, spread; key for "did it change"
local function shapeOn(S, h, g)
  local st = shapeState(S, h)
  local fi = filesOf(segLen(g), st.sp)
  local sh = { fi = fi, n = st.n, ranks = st.mob and 1 or ranksOf(st.n, fi), sp = st.sp, rule = st.rule, train = st.train, mob = st.mob, st = st }
  sh.key = string.format("%d|%d|%d|%.0f|%s|%.0f,%.0f,%.0f,%.0f", sh.fi, sh.n, sh.ranks, sh.sp, tostring(sh.mob), g.ax / 10, g.ay / 10, g.bx / 10, g.by / 10)
  return sh
end
-- "files" for a player: the men a full rank holds (fi + 1), or all the men when they fit in one rank
local function filesSeen(n, fi) return math.min(n, fi + 1) end
local function shapeText(sh) return string.format("%d men, %d files x %d ranks, spread %.0f (rule %.0f), first man's training %.2f%s", sh.n, filesSeen(sh.n, sh.fi), sh.ranks, sh.sp, sh.rule, sh.train, sh.mob and " (a heap: no ranks)" or "") end
M.form = M.form or {}; M.hostShape = M.hostShape or {}
-- note the line this copy just gave squad h (the mod's own orders: applyLine, the core's doMove and lineAt)
local function hold(S, h, P, Q, src, tag)
  local g = segOf(P, Q); if not g then M.form[h] = nil; return nil end
  g.src, g.tag, g.t = src, tag, os.clock()
  -- the target the order left (the stale test compares with it, not with the model)
  pcall(function() local s = S.sc:GetSquad({ Value = h }); g.tx, g.ty = s.TargetLocation.X, s.TargetLocation.Y end)
  M.form[h] = g
  return g
end
-- (host) tell every copy the shape squad h is in now, on its held line
local function sendShape(S, h, tag, why)
  local g = M.form[h]; if not g or not R.sqValid(h) then return false end
  local okS, sh = pcall(shapeOn, S, h, g); if not okS then log("ARMY shape squad %d: could not be read (%s)", h, tostring(sh)); return false end
  g.key = sh.key; g.sentT = os.clock()
  send(string.format("A SHAPE %d %s %d %d %d %.2f %.1f %.1f %.1f %.1f %.1f %d", h, tag or "host:-", sh.n, sh.fi, sh.ranks, sh.sp, g.ax, g.ay, g.bx, g.by, g.z, sh.mob and 1 or 0))
  stat(S, "a_shapeSent")
  log("ARMY shape squad %d (%s, %s): %s, line %.0f: sent to friends", h, tag or "-", why or "-", shapeText(sh), segLen(g))
  return true, sh
end
-- the line P -> Q that gives, on this copy (spread sp), the host's files on the host's line, with the front rank's
-- middle where the host's is
local function lineForShape(H, sp)
  local L = math.sqrt((H.bx - H.ax) ^ 2 + (H.by - H.ay) ^ 2); if L < 1 then return nil end
  local ux, uy = (H.bx - H.ax) / L, (H.by - H.ay) / L
  local seg, half, halfH = L, L / 2, L / 2
  if not H.mob and sp and sp > 0 and H.sp > 0 then seg = H.fi * sp; half = seg / 2; halfH = H.fi * H.sp / 2 end
  local mx, my = H.ax + ux * halfH, H.ay + uy * halfH
  local ax, ay = mx - ux * half, my - uy * half
  return { X = ax, Y = ay, Z = H.z }, { X = ax + ux * (seg + CUT), Y = ay + uy * (seg + CUT), Z = H.z }
end
M.shapeMath.lineForShape = lineForShape; M.shapeMath.segOf = segOf        -- (for the desk test, tests/lane70)
local function sameSeg(g, P, Q, tol)
  local g2 = segOf(P, Q); if not (g and g2) then return false end
  return math.abs(g.ax - g2.ax) <= tol and math.abs(g.ay - g2.ay) <= tol and math.abs(g.bx - g2.bx) <= tol and math.abs(g.by - g2.by) <= tol
end
-- give squad h the line P -> Q on this copy and hold it (see hold)
local function giveLine(S, h, P, Q, clock, src, tag)
  local r = applyLine(S, h, P, Q, clock)
  if r == "ok" then hold(S, h, P, Q, src, tag) else M.form[h] = nil end
  return r
end
-- (friend) form squad h as the host's shape H says. why: for the log. Returns what was done.
local function formAsHost(S, h, H, clock, why)
  local st = shapeState(S, h)
  if st.n == 0 then return "empty here" end
  if st.eng or st.tgt ~= 0 or st.ctl == 3 then return "in a fight or fleeing here: left to the fight rules" end
  if H.mob ~= st.mob then
    stat(S, "a_shapeLeader")
    return string.format("the first man differs (host %s, here %s): not fitted", H.mob and "a heap" or "ranks", st.mob and "a heap" or "ranks")
  end
  local P, Q = lineForShape(H, st.sp)
  if not P then return "bad line" end
  local g = M.form[h]
  local fiHere = g and filesOf(segLen(g), st.sp)
  -- the same start, direction and files: the same slots (the far ends may differ by up to half a spread: the held line
  -- is the drag as drawn, the host's fitted one ends at fi spreads)
  local same = false
  if g and fiHere == H.fi then
    local g2 = segOf(P, Q)
    if g2 then
      local L1, L2 = segLen(g), segLen(g2)
      local cr = ((g.bx - g.ax) * (g2.by - g2.ay) - (g.by - g.ay) * (g2.bx - g2.ax)) / (L1 * L2)
      local dt = ((g.bx - g.ax) * (g2.bx - g2.ax) + (g.by - g.ay) * (g2.by - g2.ay)) / (L1 * L2)
      same = math.abs(g.ax - g2.ax) <= 5 and math.abs(g.ay - g2.ay) <= 5 and dt > 0 and math.abs(cr) < 0.004     -- 5 cm, 0.23 degrees
    end
  end
  if same then
    if st.n ~= H.n then stat(S, "a_shapeHeads"); return string.format("same line and files; head count differs (host %d, here %d)", H.n, st.n) end
    stat(S, "a_shapeSame"); return "same"
  end
  local r = giveLine(S, h, P, Q, clock, "shape", H.tag)
  if r ~= "ok" then return "not formed: " .. tostring(r) end
  -- the order's own skill switch sets the spread again (4d8d780): when it moved, the length follows once more
  local st2 = shapeState(S, h)
  if math.abs(st2.sp - st.sp) > 0.5 then
    local P2, Q2 = lineForShape(H, st2.sp)
    if P2 then giveLine(S, h, P2, Q2, clock, "shape", H.tag) end
  end
  stat(S, "a_shapeFormed")
  local sh = shapeOn(S, h, M.form[h] or { ax = P.X, ay = P.Y, bx = Q.X, by = Q.Y, z = P.Z })
  local heads = (sh.n ~= H.n) and string.format("; head count differs (host %d, here %d)", H.n, sh.n) or ""
  return string.format("formed as the host's (%s)%s", shapeText(sh), heads)
end
-- (friend) "A SHAPE <h> <tag> <men> <fi> <ranks> <spread> <ax> <ay> <bx> <by> <z> <heap>"
local function onShape(S, w)
  local h = A.toLocal(tonumber(w[5]) or 0); if not (h and R.sqValid(h)) then return end
  if w[7] == "0" then M.hostShape[h] = nil; return end           -- the host dropped its line (another order, a fight)
  local H = { tag = w[6] or "-", n = tonumber(w[7]) or 0, fi = tonumber(w[8]) or 1, ranks = tonumber(w[9]) or 0, sp = tonumber(w[10]) or 0,
              ax = tonumber(w[11]), ay = tonumber(w[12]), bx = tonumber(w[13]), by = tonumber(w[14]), z = tonumber(w[15]) or 0, mob = w[16] == "1", t = os.clock() }
  if not (H.ax and H.ay and H.bx and H.by) then return end
  local clock = os.clock()
  M.hostShape[h] = H
  -- an order of this player's that is newer than the one this shape answers: its own shape comes next
  local who, sq = H.tag:match("^(%S+):(%d+)$")
  local mine = who == S.name
  local last = M.sentSeq and M.sentSeq[h]
  if mine and last and tonumber(sq) < last then log("ARMY shape squad %d (%s): an older order of this player's; a newer one is on its way", h, H.tag); return end
  if not mine and ((S.localOrderT[h] and clock - S.localOrderT[h] < 3.0) or (C.orderPending and C.orderPending(h))) then log("ARMY shape squad %d (%s): this player has just ordered it: the host's next shape counts", h, H.tag); return end
  local rtt = ""
  if mine and M.sentT and M.sentT[h] and last and tonumber(sq) == last then rtt = string.format("; %.0f ms after this player's order (this PC's clock)", (clock - M.sentT[h]) * 1000) end
  local ok, r = pcall(formAsHost, S, h, H, clock, "shape")
  log("ARMY shape squad %d (%s): host %d men, %d files x %d ranks, spread %.0f: %s%s", h, H.tag, H.n, filesSeen(H.n, H.fi), H.ranks, H.sp, ok and tostring(r) or ("error " .. tostring(r)), rtt)
end
-- (friend) the core's doMove and the mirror's lineAt ask for a line (C.formLine): when the host's shape of this squad
-- stands near that place, the host's line (fitted to this copy's spread) is given instead of one of this copy's own
-- making (the mirror's own line was the men's extent: two files fewer, lane 70)
C.formLine = function(h, x, y)
  local S = C.s; if not S or S.role ~= "friend" then return nil end
  local H = M.hostShape[h]; if not H or os.clock() - H.t > 120.0 then return nil end
  local mx, my = (H.ax + H.bx) / 2, (H.ay + H.by) / 2
  if far(mx, my, x, y, 800) then return nil end
  local okS, st = pcall(shapeState, S, h); if not okS or st.mob ~= H.mob then return nil end
  local P, Q = lineForShape(H, st.sp)
  if P then stat(S, "a_shapeLent"); M.lent = M.lent or {}; M.lent[h] = { P = P, Q = Q, tag = H.tag } end
  return P, Q
end
-- every copy: the core gave squad h the line P -> Q (doMove, lineAt): held, so the host's watcher sends its shape
-- (tagged with the friend's order it answers, when it does: C.armyOrder notes every order's sender)
C.formed = function(h, P, Q, why)
  local S = C.s; if not S then return end
  local src, tag = why or "core", nil
  local lt = M.lastTag and M.lastTag[h]
  if S.role == "host" and lt and os.clock() - lt.t < 0.3 then tag = lt.tag end
  local ln = M.lent and M.lent[h]
  if ln and sameSeg(segOf(ln.P, ln.Q), P, Q, 1) then src, tag = "shape", ln.tag end
  if M.lent then M.lent[h] = nil end
  hold(S, h, P, Q, src, tag)
end
-- the shape of squad h on this copy now, for the console and the test scripts: held line, computed shape and the
-- shape the men stand in (their places on the held line, in spreads: rows and the most men in one row)
function M.shape(h)
  local S = C.s; if not S then return "not started" end
  if not R.sqValid(h) then return "no such squad" end
  local g = M.form[h]
  local st = shapeState(S, h)
  local out = { string.format("squad %d: %d men, spread %.0f (rule %.0f), training %.2f, engaged %s, target %.0f,%.0f", h, st.n, st.sp, st.rule, st.train, tostring(st.eng), st.tx, st.ty) }
  if g then
    local sh = shapeOn(S, h, g)
    out[#out + 1] = string.format("held line (%s %s) %.0f,%.0f -> %.0f,%.0f (%.0f): %s", tostring(g.src), tostring(g.tag), g.ax, g.ay, g.bx, g.by, segLen(g), shapeText(sh))
    local L = segLen(g); local ux, uy = (g.bx - g.ax) / L, (g.by - g.ay) / L; local rows = {}; local nr, most = 0, 0
    for _, u in ipairs(st.units) do
      local okP, q = pcall(function() return u.realPos end)
      if okP and q then
        local row = math.floor(((q.X - g.ax) * -uy + (q.Y - g.ay) * ux) / st.sp + 0.5)
        if not rows[row] then rows[row] = 0; nr = nr + 1 end
        rows[row] = rows[row] + 1; if rows[row] > most then most = rows[row] end
      end
    end
    out[#out + 1] = string.format("men stand in %d rows, at most %d in one", nr, most)
  else out[#out + 1] = "no held line" end
  local H = M.hostShape[h]
  if H then out[#out + 1] = string.format("host's last shape (%s, %.1f s ago): %d men, %d files x %d ranks, spread %.0f", H.tag, os.clock() - H.t, H.n, filesSeen(H.n, H.fi), H.ranks, H.sp) end
  return table.concat(out, " | ")
end
-- (host, every 0.25 s) a held line whose shape changed (a skill, a head count) goes out again; a squad that has got
-- another order (its target is no longer the held line's), or is in a fight, drops its line
local function shapeWatch(S, clock)
  for h, g in pairs(M.form) do
    if not R.sqValid(h) then M.form[h] = nil
    else
      local okS, sh = pcall(shapeOn, S, h, g)
      -- a dropped line on the host: the friends forget its shape too (their mirror would give it again nearby)
      local function drop(why)
        M.form[h] = nil
        if S.role == "host" and g.key then send(string.format("A SHAPE %d - 0", h)); log("ARMY shape squad %d: held line dropped (%s): friends told", h, why) end
      end
      if not okS or sh.n == 0 then drop("no men")
      elseif sh.st.eng or sh.st.tgt ~= 0 or sh.st.ctl == 3 then drop("a fight")
      else
        -- the target the order left, kept from the give (hold); a change of the shape itself (a skill's spread, the head
        -- count) moves it with the game's own forming again, so it is taken anew then
        if g.wkey ~= sh.key then g.wkey = sh.key; if g.wkey0 then g.tx, g.ty = sh.st.tx, sh.st.ty end; g.wkey0 = true end
        if g.tx and far(sh.st.tx, sh.st.ty, g.tx, g.ty, 400) and clock - g.t > 0.5 then
          g.off = (g.off or 0) + 1
          if g.off >= 3 then drop(string.format("its target moved %.0f m: another order", math.sqrt((sh.st.tx - g.tx) ^ 2 + (sh.st.ty - g.ty) ^ 2) / 100)) end
        else g.off = 0 end
        if M.form[h] and S.role == "host" and sh.key ~= g.key then
          -- a head count alone (a muster) at most every 2 s
          local onlyN = g.key and g.key:gsub("^(%d+)|%d+|%d+", "%1") == sh.key:gsub("^(%d+)|%d+|%d+", "%1")
          -- tagged with the order that changed it (a friend's skill) when there was one this second
          local lt = M.lastTag and M.lastTag[h]
          local tag = (lt and clock - lt.t < 1.0) and lt.tag or g.tag or ("host:" .. tostring(g.src))
          if not onlyN or clock - (g.sentT or 0) >= 2.0 then sendShape(S, h, tag, g.key and "changed" or "new line") end
        end
      end
    end
  end
end
-- ---------------------------------------------------------------- measured shapes (lane 70, part B)
-- Orders whose line the mod cannot know: the host's own plain right click (the game projects the line itself; the
-- stored line Squad+0x158 is not reflected), an Alt drag (formation type "lock", another branch of formALineArmy),
-- the end of a path. Their shape is MEASURED: every man's dir is the line's direction (written by formALine), and his
-- target place (SMUnit:getTargetPos, a moment after the order; his place once he stands, at a path's end) lies on the
-- game's grid: rows one spread apart to the left of the line, columns one spread apart from its start. From those the
-- rows, the files and the line's start come back; the shape goes out as the equivalent one-squad line (start A', fi
-- spreads long): on the host as A SHAPE, on a friend (its own Alt drag) as O LINE.
-- returns { fi, ranks, n, P, Q } or nil, why
local function measureShape(S, h, useReal)
  local st = shapeState(S, h)
  if st.n == 0 then return nil, "no men" end
  if st.mob then return nil, "a heap" end
  local hx0, hy0, same = menDir(st.units)
  if not hx0 then return nil, "no direction" end
  local sp = st.sp; if sp <= 0 then return nil, "no spread" end
  local pts = {}
  for _, u in ipairs(st.units) do
    local okP, q = pcall(function() if useReal then return u.realPos end; return u:getTargetPos() end)
    if okP and q and q.X then pts[#pts + 1] = { x = q.X, y = q.Y, z = q.Z } end
  end
  if #pts < st.n then return nil, string.format("%d of %d places read", #pts, st.n) end
  -- the places must be this order's: their mean is the squad's target (measured: 1 cm); in the order's own tick the
  -- men still have the last order's places (a whole grid, 8-12 m off), from about 0.3 s on the new ones
  if not useReal then
    local mx, my = 0, 0; for _, p in ipairs(pts) do mx = mx + p.x; my = my + p.y end
    mx, my = mx / #pts, my / #pts
    if (mx - st.tx) ^ 2 + (my - st.ty) ^ 2 > 100 * 100 then return nil, "the men's places are not yet this order's" end
  end
  -- (game run, lane 70) after a plain right click or at a path's end the men's dir is NOT the grid's axis (measured:
  -- dir -140 degrees, the grid's axes at -84 / 6): the grid's own axis is found from each man's nearest neighbour
  -- (their directions, modulo 90 degrees), and of its four ways the one nearest the men's dir is tried first; a full
  -- grid read along either axis is the same set of places
  local C4, S4 = 0, 0
  for i, p in ipairs(pts) do
    local bd, bx, by
    for j, q in ipairs(pts) do if i ~= j then local d = (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2; if not bd or d < bd then bd, bx, by = d, q.x - p.x, q.y - p.y end end end
    if bd and bd > 1 then local a = atan2(by, bx); C4 = C4 + math.cos(4 * a); S4 = S4 + math.sin(4 * a) end
  end
  local th0 = (C4 * C4 + S4 * S4 > 0) and atan2(S4, C4) / 4 or atan2(hy0, hx0)
  local hdir = atan2(hy0, hx0); local ways = {}
  for k = 0, 3 do local a = th0 + k * math.pi / 2; ways[#ways + 1] = { a = a, d = angD(a, hdir) } end
  if #pts < 2 then ways = { { a = hdir, d = 0 } } end
  table.sort(ways, function(x, y) return x.d < y.d end)
  if same then table.insert(ways, 1, { a = hdir, d = 0 }) end     -- every man has one dir (a line order): that axis first
  local why
  for _, w in ipairs(ways) do
    local m, w2 = M.gridOn(pts, math.cos(w.a), math.sin(w.a), sp, st.n, same and w.d < 0.01)
    if m then return m end
    why = why or w2
  end
  return nil, why
end
-- the grid on axis (hx, hy): rows across it one spread apart, the front rank's columns one spread apart from its first man
function M.gridOn(pts, hx, hy, sp, n, exactDir)
  for _, p in ipairs(pts) do p.a = p.x * hx + p.y * hy; p.c = -p.x * hy + p.y * hx end
  local cmin = math.huge; for _, p in ipairs(pts) do if p.c < cmin then cmin = p.c end end
  local rows, R = {}, 0
  for _, p in ipairs(pts) do
    local r = math.floor((p.c - cmin) / sp + 0.5); p.r = r
    if r > 80 then return nil, "not a grid (rows)" end
    rows[r] = rows[r] or {}; table.insert(rows[r], p); if r + 1 > R then R = r + 1 end
  end
  for r = 0, R - 1 do if not rows[r] then return nil, "not a grid (a row is empty)" end end
  local most = 0; for r = 0, R - 1 do if #rows[r] > most then most = #rows[r] end end
  for r = 0, R - 2 do if #rows[r] ~= most then return nil, "not a grid (a front row is not full)" end end
  -- the front rank's columns: one spread apart from its first man
  local front = rows[0]; local amin = math.huge; local c0 = 0
  for _, p in ipairs(front) do if p.a < amin then amin = p.a end; c0 = c0 + p.c end
  c0 = c0 / #front
  local off = 0
  for _, p in ipairs(front) do local k = (p.a - amin) / sp; if math.abs(k - math.floor(k + 0.5)) > 0.35 then off = off + 1 end end
  if off > math.max(1, math.floor(#front / 10)) then return nil, "not a grid (columns)" end
  local fi = (R == 1) and math.max(1, n - 1) or (most - 1)
  local ax, ay = amin * hx - c0 * hy, amin * hy + c0 * hx
  local z = pts[1].z or 0
  local P = { X = ax, Y = ay, Z = z }
  local Q = { X = ax + hx * (fi * sp + CUT), Y = ay + hy * (fi * sp + CUT), Z = z }
  return { fi = fi, ranks = R, n = n, P = P, Q = Q, exactDir = exactDir }
end
M.measureShape = measureShape
M.measQ = M.measQ or {}
-- measure squad h a moment from now: kind "order" (target places, tries at 0.3 / 0.7 / 1.5 / 3 s) or "arrive" (its
-- places once it stands near (ex, ey), up to 120 s). what: "host" sends A SHAPE, "friend" sends O LINE
local function measureLater(S, h, kind, tag, what, ex, ey)
  M.measQ[h] = { t0 = os.clock(), kind = kind, tag = tag, what = what, ex = ex, ey = ey, n = 0 }
end
local MTRIES = { 0.3, 0.7, 1.5, 3.0 }
local function measureTick(S, clock)
  for h, q in pairs(M.measQ) do
    if not R.sqValid(h) then M.measQ[h] = nil
    else
      local due, useReal = false, false
      if q.kind == "order" then due = clock - q.t0 >= MTRIES[q.n + 1]
      else
        due = clock - (q.lt or 0) >= 0.5
        if due then
          q.lt = clock
          local okA, standing = pcall(function()
            local s = S.sc:GetSquad({ Value = h }); local c = s.WeightedCenter
            if q.ex and far(c.X, c.Y, q.ex, q.ey, 1500) then return false end
            local arr = s.unitArr; local n, v = #arr, 0
            for i = 1, n do local u = A.un(arr[i]); if valid(u) then v = v + (tonumber(u.realSpeed) or 0) end end
            return n > 0 and v / n < 0.5
          end)
          due = okA and standing; useReal = true
          if clock - q.t0 > 120.0 then M.measQ[h] = nil; due = false; log("ARMY shape squad %d: never stood still at its path's end in 120 s: not measured", h) end
        end
      end
      if due and M.measQ[h] then
        local okM, m, why = pcall(measureShape, S, h, useReal)
        if not okM then why = "error " .. tostring(m); m = nil end
        q.n = q.n + 1
        if m then
          M.measQ[h] = nil
          if q.what == "host" then
            hold(S, h, m.P, m.Q, "measured", q.tag)
            local okH, sent = pcall(sendShape, S, h, q.tag, "measured (" .. q.kind .. ")")
            if not (okH and sent) then log("ARMY shape squad %d: measured, but the shape could not be sent", h) end
          else
            send(string.format("O LINE %d %.1f %.1f %.1f %.1f %.1f", A.toHost(h), m.P.X, m.P.Y, m.Q.X, m.Q.Y, m.P.Z or 0)); S.localOrderT[h] = clock
            M.sentSeq[h] = S.seq; M.sentT[h] = clock
            hold(S, h, m.P, m.Q, "measured", nil)
            log("ARMY this player's Alt drag of squad %d measured: %d files x %d ranks: sent to the host as its line (%d)", h, filesSeen(m.n, m.fi), m.ranks, S.seq)
          end
        elseif q.kind == "order" and q.n >= #MTRIES then
          M.measQ[h] = nil; log("ARMY shape squad %d: not measured (%s): left to the mirror", h, tostring(why))
        end
      end
    end
  end
end
-- (friend, every 0.5 s) this copy's squad on the host's line no longer has the host's files (this copy's skill
-- changed the spread after the host's did, or the other way): formed again, at most once a second and 4 times a shape
local function shapeCheck(S, clock)
  for h, H in pairs(M.hostShape) do
    if not R.sqValid(h) or clock - H.t > 120.0 then M.hostShape[h] = nil
    else
      local g = M.form[h]
      if g and g.src == "shape" and g.tag == H.tag and clock - (H.fixT or 0) >= 1.0 and (H.fixN or 0) < 4 and not (S.localOrderT[h] and clock - S.localOrderT[h] < 3.0) then
        local okS, sh = pcall(shapeOn, S, h, g)
        if okS and sh.n > 0 and not (sh.st.eng or sh.st.tgt ~= 0) and sh.mob == H.mob and sh.fi ~= H.fi then
          H.fixT = clock; H.fixN = (H.fixN or 0) + 1
          local ok, r = pcall(formAsHost, S, h, H, clock, "check")
          log("ARMY shape squad %d: here %d files, the host's %d (spread here %.0f, host %.0f): %s", h, filesSeen(sh.n, sh.fi), filesSeen(H.n, H.fi), sh.sp, H.sp, ok and tostring(r) or ("error " .. tostring(r)))
        end
      end
    end
  end
end
local function buildingByAddr(S, a)
  local arr = S.eng.buildingArr
  for i = 1, #arr do local b = A.un(arr[i]); if valid(b) and b:GetAddress() == a then return b end end
  return nil
end
-- one line of the hook: "MOVESEL <n> pawn=<hex> wp=<0|1> na=<0|1> cur=<x,y,z> mode=<n> moved=<0|1> hb=<hex> hbt=<type>
--   hbc=<function> hp=<hex> res=<hex> sq=<h,h,...> waybefore=<n> way=<n> <x,y,z|...>"
local function onOrderEvent(S, line, clock)
  local pawn = tonumber(line:match(" pawn=(%x+)") or "", 16)
  if not pawn or pawn ~= math.tointeger(S.p1:GetAddress()) then return end        -- another lord's (the helper's replays are never written)
  local wp = line:match(" wp=(%d)") == "1"
  local cx, cy, cz = line:match(" cur=(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)"); cx, cy, cz = tonumber(cx), tonumber(cy), tonumber(cz)
  if not cx then return end
  local sq = {}; for v in (line:match(" sq=(%S+)") or ""):gmatch("%-?%d+") do sq[#sq + 1] = tonumber(v) end
  local mine = {}
  for _, h in ipairs(liveSquads(S, sq)) do if S.role == "host" or S.mine[h] then mine[#mine + 1] = h end end
  if #mine == 0 then return end
  if wp then
    local pts = C.patch.decPoints(line:match(" way=%-?%d+ (%S+)"))
    if #pts < 2 then return end
    local last = pts[#pts]
    for _, h in ipairs(mine) do
      -- taken: the squad's order shows no target point (type 0) and it heads for the path's end
      local s = S.sc:GetSquad({ Value = h })
      if s.lastSquadTargetType == 0 and near2(s.TargetLocation.X, s.TargetLocation.Y, last.X, last.Y, 1500) then
        R.touch(h)                                           -- the core's watcher must not also send it as a plain move
        if S.role == "host" then send(string.format("A PATH %d %s", h, encPts1(pts))); log("ARMY this player gave squad %d a path of %d points: sent to friends", h, #pts)
          measureLater(S, h, "arrive", "host:path", "host", last.X, last.Y)      -- (lane 70, B) its shape at the path's end
        else send(string.format("O PATH %d %s", A.toHost(h), encPts1(pts))); S.localOrderT[h] = clock; log("ARMY this player gave squad %d a path of %d points: sent to the host", h, #pts) end
        stat(S, "a_pathSent")
        return                                               -- the game gives a path to one squad only
      end
    end
    return
  end
  local mode = tonumber(line:match(" mode=(%d+)")); local moved = line:match(" moved=(%d)") == "1"
  local hb = tonumber(line:match(" hb=(%x+)") or "0", 16) or 0; local res = line:match(" res=(%x+)")
  -- (lane 34, A081) a formation drag: right button dragged without Ctrl over open ground. The game forms a line from the
  -- press place to the release place (cur). The core's watcher sends only the new target, so the line's shape was lost
  -- on the other copies (lane 30: a one-rank line on the host, a block on the friend). The press place is not in the
  -- hook line; for ONE squad the new target is the line's middle, so press place = 2 * target - cur. Several squads
  -- dragged at once share the line: see the next branch (lane 37).
  -- (lane 70) The press place is worked out from the squad's new target with the game's own line rule (dragFrom), the
  -- squad is given that line again here (so this copy's squad stands on a line every copy knows; normally the same
  -- line, as the player drew it), and the line goes out: a friend's to the host, which forms it and sends its shape
  -- to every copy (A SHAPE); the host's own as its shape at once.
  -- (lane 70, B) an Alt drag ("lock" formation: another branch of formALineArmy, not the line rule above): measured
  -- (measureShape) a moment later, then sent as its equivalent line
  if moved and mode == 0 and hb == 0 then
    local alt = false; pcall(function() alt = S.p1.alt_pressed_b and true or false end)
    if alt then
      for _, h in ipairs(mine) do
        local s = S.sc:GetSquad({ Value = h })
        if (s.lastSquadTargetType == 1 or M.testDrag) and s.targetSquad.Value == 0 then
          R.touch(h); if S.role ~= "host" then S.localOrderT[h] = clock end
          measureLater(S, h, "order", S.role == "host" and "host:altdrag" or nil, S.role == "host" and "host" or "friend")
          log("ARMY this player dragged squad %d with Alt: its shape is measured in a moment", h)
        end
      end
      return
    end
  end
  -- (lane 70, B) the host's own plain right click on open ground: the game picks the line; measured and sent
  if not moved and mode == 0 and hb == 0 and S.role == "host" then
    for _, h in ipairs(mine) do
      local s = S.sc:GetSquad({ Value = h })
      if s.lastSquadTargetType == 1 and s.targetSquad.Value == 0 then measureLater(S, h, "order", "host:move", "host") end
    end
    return
  end
  if moved and mode == 0 and hb == 0 and #mine == 1 then
    local h = mine[1]; local s = S.sc:GetSquad({ Value = h })
    local tx, ty = s.TargetLocation.X, s.TargetLocation.Y
    local d = math.sqrt((tx - cx) ^ 2 + (ty - cy) ^ 2)
    if (s.lastSquadTargetType == 1 or M.testDrag) and s.targetSquad.Value == 0 and d > 150 and d < 30000 then
      R.touch(h)                                             -- the core's watcher must not also send it as a plain move
      -- every new step in a pcall: a fault here must not lose the drag (then the old line, as 0.2.2 sent it)
      local okP, P, L, how = pcall(function() return pressOf(shapeState(S, h), cx, cy, tx, ty) end)
      if not okP then how = "error " .. tostring(P); P = nil end
      if not P then P = { X = 2 * tx - cx, Y = 2 * ty - cy }; how = tostring(how) .. ": the old rule"; L = 2 * d end
      P.Z = cz
      local Q = { X = cx, Y = cy, Z = cz }
      local okG, r = pcall(giveLine, S, h, P, Q, clock, "drag", nil)
      if not okG then r = "error " .. tostring(r); M.form[h] = nil end
      local g = M.form[h]
      local okS, sh = pcall(function() return g and shapeOn(S, h, g) end); if not okS then sh = nil end
      -- the check that the press place is the one the player drew: the target moves (next to) nothing when the line is
      -- given again
      local moved2 = -1; pcall(function() local s2 = S.sc:GetSquad({ Value = h }); moved2 = math.sqrt((s2.TargetLocation.X - tx) ^ 2 + (s2.TargetLocation.Y - ty) ^ 2) end)
      local line2 = string.format("%.1f %.1f %.1f %.1f %.1f", P.X, P.Y, cx, cy, cz)
      local what = string.format("a line %.0f long (%s): given again here %s, target moved %.0f cm: %s", L, how, tostring(r), moved2, sh and shapeText(sh) or "-")
      if S.role == "host" then
        local okH, sent = false, false
        if g then g.tag = "host:drag"; okH, sent = pcall(sendShape, S, h, "host:drag", "this player's drag") end
        if not (okH and sent) then send("A LINE " .. h .. " " .. line2) end
        log("ARMY this player dragged squad %d into %s: sent to friends (%s)", h, what, (okH and sent) and "its shape" or "the line")
      else
        send(string.format("O LINE %d %s", A.toHost(h), line2)); S.localOrderT[h] = clock
        M.sentSeq = M.sentSeq or {}; M.sentT = M.sentT or {}; M.sentSeq[h] = S.seq; M.sentT[h] = clock
        log("ARMY this player dragged squad %d into %s: sent to the host (%d)", h, what, S.seq)
      end
      stat(S, "a_lineSent")
    end
    return
  end
  -- (lane 37, item 6) several squads dragged at once: the game cuts the line press..release (cur) into one piece per
  -- squad, each squad's new target the middle of its piece. Walking from the release end: the squad nearest cur has its
  -- far end at cur, so its half width is its distance to cur along the line; each next squad's half width is the gap to
  -- the one before minus that one's half width. Each squad's piece goes out as its own LINE (the same wire as one squad).
  -- Real drags of two squads (lane 37): host to friend 2 LINE lines (one squad in a fight got the plain move, as for one
  -- squad), friend to host applied 7 and 9 ms, targets 2-3 m apart and the lines the same way round on both copies.
  if moved and mode == 0 and hb == 0 and #mine > 1 then
    local t = {}
    for _, h in ipairs(mine) do
      local s = S.sc:GetSquad({ Value = h })
      if (s.lastSquadTargetType == 1 or M.testDrag) and s.targetSquad.Value == 0 then t[#t + 1] = { h = h, x = s.TargetLocation.X, y = s.TargetLocation.Y } end
    end
    if #t < 2 then return end
    local far, fd = t[1], -1
    for _, e in ipairs(t) do local d = (e.x - cx) ^ 2 + (e.y - cy) ^ 2; if d > fd then far, fd = e, d end end
    local dx, dy = cx - far.x, cy - far.y; local len = math.sqrt(dx * dx + dy * dy)
    if len < 150 or len > 60000 then return end
    dx, dy = dx / len, dy / len
    for _, e in ipairs(t) do e.p = (cx - e.x) * dx + (cy - e.y) * dy end     -- distance from cur back along the line
    table.sort(t, function(a, b) return a.p < b.p end)
    -- (lane 70) the game cuts the drag P..cur into #t equal pieces (4b45bdf: piece k from P + k L/n, each formed like
    -- one squad's line). The piece of the squad nearest cur ends at cur: the inverse of the one-squad line on that squad
    -- gives the piece's length and the line's direction; every piece follows. Without a fit: the old rule (halves).
    local near = t[1]
    local okN, stN = pcall(shapeState, S, near.h)
    local P0, l, how
    if okN then
      local okP, a1, a2, a3 = pcall(pressOf, stN, cx, cy, near.x, near.y)
      if okP then P0, l, how = a1, a2, a3 else how = "error " .. tostring(a1) end
    end
    local pieces = {}
    if P0 then
      local ux, uy = (cx - P0.X) / l, (cy - P0.Y) / l
      for i, e in ipairs(t) do
        local ex, ey = cx - ux * l * (i - 1), cy - uy * l * (i - 1)
        pieces[i] = { h = e.h, P = { X = ex - ux * l, Y = ey - uy * l, Z = cz }, Q = { X = ex, Y = ey, Z = cz } }
      end
    else
      how = "no fit: the old rule"
      local hw = math.max(150, t[1].p)
      for i, e in ipairs(t) do
        if i > 1 then hw = math.max(150, (e.p - t[i - 1].p) - hw) end
        pieces[i] = { h = e.h, P = { X = e.x - dx * hw, Y = e.y - dy * hw, Z = cz }, Q = { X = e.x + dx * hw, Y = e.y + dy * hw, Z = cz } }
      end
    end
    for _, pc in ipairs(pieces) do
      R.touch(pc.h)
      local okG, r = pcall(giveLine, S, pc.h, pc.P, pc.Q, clock, "drag", nil)
      if not okG then r = "error " .. tostring(r); M.form[pc.h] = nil end
      local line2 = string.format("%.1f %.1f %.1f %.1f %.1f", pc.P.X, pc.P.Y, pc.Q.X, pc.Q.Y, cz)
      if S.role == "host" then
        local okH, sent = false, false
        if r == "ok" then okH, sent = pcall(sendShape, S, pc.h, "host:drag", "this player's drag") end
        if not (okH and sent) then send("A LINE " .. pc.h .. " " .. line2) end
      else
        send(string.format("O LINE %d %s", A.toHost(pc.h), line2)); S.localOrderT[pc.h] = clock
        M.sentSeq = M.sentSeq or {}; M.sentT = M.sentT or {}; M.sentSeq[pc.h] = S.seq; M.sentT[pc.h] = clock
      end
      local g = M.form[pc.h]; local okS, sh = pcall(function() return g and shapeOn(S, pc.h, g) end)
      log("ARMY this player dragged squad %d (one of %d) into its piece %.0f long (%s): given again here %s: %s", pc.h, #t,
          math.sqrt((pc.Q.X - pc.P.X) ^ 2 + (pc.Q.Y - pc.P.Y) ^ 2), tostring(how), tostring(r), (okS and sh) and shapeText(sh) or "-")
      stat(S, "a_lineSent")
    end
    log("ARMY this player dragged %d squads into one line: each squad's piece sent to %s", #t, S.role == "host" and "friends" or "the host")
    return
  end
  local hbt, hbc = tonumber(line:match(" hbt=(%-?%d+)")), tonumber(line:match(" hbc=(%-?%d+)"))
  -- the routine's two building branches: mode 3 with a building of type 100 or function 17 and no resource node under
  -- the pointer; mode 7 with any building (the part under the pointer goes with it)
  local as3 = mode == 3 and res == "0" and (hbt == 100 or hbc == 17)
  if moved or hb == 0 or not (as3 or mode == 7) then return end
  local X = Xt(); if not X then return end
  local b = buildingByAddr(S, hb); if not b then return end
  local tail = ""
  if mode == 7 then
    local hpa = tonumber(line:match(" hp=(%x+)") or "0", 16) or 0
    local part
    pcall(function() local arr = b.buildings; for i = 1, #arr do local a = A.un(arr[i]); if valid(a) and a:GetAddress() == hpa then part = a end end end)
    if not part then return end                              -- no part under the pointer: the routine's order is then a plain one
    local l = part:K2_GetActorLocation()
    tail = string.format(" 7 %.0f,%.0f", l.X, l.Y)
  end
  local taken = {}
  for _, h in ipairs(mine) do
    local s = S.sc:GetSquad({ Value = h })
    if s.lastSquadTargetType == 2 and near2(s.lastSquadTargetPosition.X, s.lastSquadTargetPosition.Y, cx, cy, 5) then taken[#taken + 1] = h; R.touch(h) end
  end
  if #taken == 0 then return end
  local key = X.bkeyOf(X.bident(b))
  if key == "-" then log("ARMY order against a building without a usable name (a cleared actor): not sent"); return end   -- (lane 76)
  local hs = {}
  for i, h in ipairs(taken) do hs[i] = tostring(S.role == "host" and h or A.toHost(h)); if S.role ~= "host" then S.localOrderT[h] = clock end end
  send(string.format("%s BLD %s %s %.1f %.1f %.1f%s", S.role == "host" and "A" or "O", table.concat(hs, ","), key, cx, cy, cz, tail))
  log("ARMY this player sent %d squad(s) against building %s%s: sent to %s", #taken, key, mode == 7 and " (a part of it)" or "", S.role == "host" and "friends" or "the host")
  stat(S, "a_bldSent")
end
-- Called by the core every tick before the host's snapshot and before a friend's order watcher: the native piece is
-- ticked (it writes what its hook noted since the last tick) and the new lines are read. So a path or building order
-- is known, and its squads marked, before the watcher could report the same click as a plain move, and before the
-- host's snapshot carries the squad's new target to friends.
-- (lane 70) for the test scripts: a drag line handed in as if read from the hook; M.testDrag = true lets a line given
-- by the console count as a drag (the console cannot set Squad.lastSquadTargetType, which only MoveSelected sets)
M.orderEvent = function(S, line, clock) return onOrderEvent(S, line, clock or os.clock()) end
C.preOrders = function(S, clock)
  local Pt = C.patch
  if C.hold or not (Pt and Pt.fn and Pt.orderEvents) or not (valid(S.p1) and valid(S.sc)) then return end
  Pt.tick()
  for _, line in ipairs(Pt.orderEvents()) do
    local ok, e = pcall(onOrderEvent, S, line, clock)
    if not ok then log("ARMY order event error: %s", tostring(e)) end
  end
end
-- host: a friend's PATH or BLD (the core hands every order to C.armyOrder first)
local armyOrder0 = C.armyOrder
C.armyOrder = function(S, kind, h, w)
  -- (lane 70, C) a friend's round-trip probe: answered at once ("A PONG <friend> <its stamp>")
  if kind == "PING" then send(string.format("A PONG %s %s", tostring(S.curPeer or "?"), tostring(w[6]))); return "ok" end
  -- (lane 70) who gave the order now applied to squad h: a line the core gives for it (doMove) is that order's shape
  if h and (kind == "MOVE" or kind == "SKILL" or kind == "STOP" or kind == "WAY") then M.lastTag = M.lastTag or {}; M.lastTag[h] = { tag = tostring(S.curPeer or "?") .. ":" .. tostring(w[1]), t = os.clock() } end
  if kind == "PATH" then
    if not (h and R.sqValid(h)) then return "no such squad" end
    if S.sc:GetUnitCount({ Value = h }) == 0 then return "empty" end
    local pts = C.patch and C.patch.decPoints and C.patch.decPoints(w[6]) or {}
    local r = applyPath(S, h, pts, os.clock())
    if r == "ok" then
      send(string.format("A PATH %d %s", h, w[6]))
      local last = pts[#pts]
      if last then measureLater(S, h, "arrive", tostring(S.curPeer or "?") .. ":" .. tostring(w[1]), "host", last.X, last.Y) end   -- (lane 70, B)
    end
    return r
  elseif kind == "LINE" then                                  -- O LINE <squad> <ax> <ay> <bx> <by> <z> (lane 34)
    local a, b = decLine(w, 6); if not a then return "bad line" end
    local tag = tostring(S.curPeer or "?") .. ":" .. tostring(w[1])
    local okG, r = pcall(giveLine, S, h, a, b, os.clock(), "line", tag)
    if not okG then r = "error " .. tostring(r); M.form[h] = nil end
    -- (lane 70) formed: its shape goes to every copy, also to the one that dragged; in a fight (a plain move), or when
    -- the shape cannot be read, the line as before
    if r == "ok" and M.form[h] then
      local okH, sent, sh = pcall(sendShape, S, h, tag, "a friend's drag")
      if okH and sent then return "ok (" .. shapeText(sh) .. ")" end
    end
    if r:sub(1, 2) == "ok" then send(string.format("A LINE %d %s %s %s %s %s", h, w[6], w[7], w[8], w[9], w[10])) end
    return r
  elseif kind == "BLD" then
    local list = {}; for v in tostring(w[5]):gmatch("%d+") do list[#list + 1] = tonumber(v) end
    list = liveSquads(S, list)
    if #list == 0 then return "no such squad" end
    local X = Xt(); local b = X and X.findBkey(w[6])
    if not b then return "building not found" end
    local q = { X = tonumber(w[7]), Y = tonumber(w[8]), Z = tonumber(w[9]) }
    if not (q.X and q.Y and q.Z) then return "bad point" end
    local mode, part = tonumber(w[10]) or 3, nil
    if mode == 7 then local px, py = tostring(w[11]):match("^(-?[%d%.]+),(-?[%d%.]+)$"); part = px and partAt(b, tonumber(px), tonumber(py)) end
    local r = applyBld(S, list, b, q, os.clock(), mode, part)
    if r == "ok" then
      local hs = {}; for i, x in ipairs(list) do hs[i] = tostring(x) end
      send(string.format("A BLD %s %s %.1f %.1f %.1f%s", table.concat(hs, ","), w[6], q.X, q.Y, q.Z, mode == 7 and (" 7 " .. tostring(w[11])) or ""))
    end
    return r
  end
  if armyOrder0 then return armyOrder0(S, kind, h, w) end
  return nil
end
-- friend: the host's "A PATH <host squad> <points>" and "A BLD <host squads> <building> <x> <y> <z>"
local function onOrderMsg(S, w)
  local act = w[4]; local clock = os.clock()
  if act == "PATH" then
    local h = A.toLocal(tonumber(w[5]) or 0)
    if not (h and R.sqValid(h)) then return end
    if S.localOrderT[h] and clock - S.localOrderT[h] < 3.0 then return end        -- this copy's player gave it: it already runs here
    local r = applyPath(S, h, C.patch and C.patch.decPoints and C.patch.decPoints(w[6]) or {}, clock)
    log("ARMY host says squad %d follows a path: %s", h, tostring(r))
  elseif act == "LINE" then
    local h = A.toLocal(tonumber(w[5]) or 0)
    if not (h and R.sqValid(h)) then return end
    if S.localOrderT[h] and clock - S.localOrderT[h] < 3.0 then return end        -- this copy's player gave it: it already runs here
    local a, b = decLine(w, 6); if not a then return end
    log("ARMY host says squad %d forms a line: %s", h, tostring(applyLine(S, h, a, b, clock)))
  elseif act == "BLD" then
    local list = {}
    for v in tostring(w[5]):gmatch("%d+") do
      local h = A.toLocal(tonumber(v))
      if h and not (S.localOrderT[h] and clock - S.localOrderT[h] < 3.0) then list[#list + 1] = h end
    end
    list = liveSquads(S, list)
    if #list == 0 then return end
    local X = Xt(); local b = X and X.findBkey(w[6])
    local q = { X = tonumber(w[7]), Y = tonumber(w[8]), Z = tonumber(w[9]) }
    local mode, part = tonumber(w[10]) or 3, nil
    if b and mode == 7 then local px, py = tostring(w[11]):match("^(-?[%d%.]+),(-?[%d%.]+)$"); part = px and partAt(b, tonumber(px), tonumber(py)) end
    local r = (b and q.X and q.Y and q.Z) and applyBld(S, list, b, q, clock, mode, part) or "building not found"
    log("ARMY host says %d squad(s) go against building %s: %s", #list, tostring(w[6]), tostring(r))
  end
end

-- ================================================================ ORDER ANSWERS (lane 70, G139)
-- Every order a friend sends ("O <KIND> <host squad(s)> ...", any kind the order path knows) is logged when it leaves
-- (C.orderSent, called by the core's send) and answered by the host for every kind, also "ok" (C.orderAnswer, called
-- by hostInbox after its APPLIED line): "A ACK <friend> <seq> <kind> ok|changed|refused <answer>". The sequence number
-- (the first word of the friend's line; the host's APPLIED line prints it) is the key. The host's lines come in the
-- order the host wrote them, so on the friend every host line read BEFORE the answer is from before the order was
-- applied, every line after it from after: until the answer (at most 3 s) the order is this player's (C.orderPending:
-- the mirror leaves the squad alone), and C.orderAckWall(h) gives the host's clock of the answer line, so a host line
-- stamped earlier is older than the order (for the men module, lane 73). A changed or refused order puts a notice in
-- the game's notice list. No answer in 3 s: logged, the mirror follows the host again.
local ORDER_NOSQ = { SPEED = true, RAISE = true, HIRE = true, PING = true }      -- word 3 is not a host squad number
M.pend = M.pend or {}; M.pendSq = M.pendSq or {}; M.ackWall = M.ackWall or {}
local function orderKindText(k)
  local t = { MOVE = "move", ATTACK = "attack", STOP = "halt", PUSH = "stance", BEHAV = "stance", SKILL = "command", LINE = "line",
              PATH = "path", BLD = "attack on a building", WAY = "waypoint", RALLY = "call-up", HOME = "send home",
              REMOVE = "remove", RAISE = "raise a unit", HIRE = "hire", NAME = "rename" }
  return t[k] or string.lower(tostring(k))
end
-- the host's answer in plain words: ok / changed / refused, and why
local function classify(kind, ok, r)
  r = tostring(r)
  if not ok then return "refused", "the host's game raised an error" end
  if r:find("plain move", 1, true) then return "changed", "the unit is in a fight there, so it only moves to that place" end
  if r == "true" or r == "ok" or r:sub(1, 3) == "ok " or r:sub(1, 6) == "queued" or r == "same" then return "ok", r end
  local why = ({ ["building not found"] = "the building is no longer there", empty = "the unit has no men there",
                 ["no such squad"] = "the unit no longer exists there", gone = "the target is gone", refused = "the host's game did not allow it",
                 ["false"] = "the host's game did not allow it right now", ["unknown order"] = "the host does not know this order" })[r]
  return "refused", why or r
end
M.classify = classify
-- (host) the answer to one applied order of a friend's
C.orderAnswer = function(S, peer, w, ok, r)
  local kind = tostring(w[4])
  if kind == "PING" then return end
  local cl, why = classify(kind, ok, r)
  send(string.format("A ACK %s %s %s %s %s", tostring(peer), tostring(w[1]), kind, cl, enc(cl == "ok" and tostring(r) or why)))
  stat(S, "a_ack_" .. cl)
end
-- (friend) an order of this player's leaves (every "O" line the core's send writes)
C.orderSent = function(seq, line)
  local S = C.s; if not S or S.role ~= "friend" then return end
  local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end
  local kind = w[2]; if not kind or kind == "PING" then return end
  local lhs, hs = {}, {}
  if not ORDER_NOSQ[kind] and w[3] then
    for v in w[3]:gmatch("%d+") do local hh = tonumber(v); hs[#hs + 1] = hh; local lh = A.toLocal(hh); if lh then lhs[#lhs + 1] = lh end end
  end
  local clock = os.clock()
  M.pend[seq] = { kind = kind, hs = hs, lhs = lhs, t = clock }
  for _, lh in ipairs(lhs) do M.pendSq[lh] = seq end
  local here = {}; for i, lh in ipairs(lhs) do here[i] = tostring(lh) end
  log("ORDER %d sent: %s %s (here %s)", seq, kind, (#hs > 0) and ("host squad " .. table.concat(hs, ",")) or tostring(w[3] or "-"), (#here > 0) and table.concat(here, ",") or "-")
end
-- (friend) the host's answer
local function onAck(S, w)
  if S.role ~= "friend" or w[5] ~= S.name then return end
  local seq = tonumber(w[6]); local p = seq and M.pend[seq]
  local kind, cl, txt = w[7], w[8], dec(w[9])
  local rtt = p and string.format("%.0f ms", (os.clock() - p.t) * 1000) or "an order not in the list (older than 3 s?)"
  log("ORDER %s answered: %s %s: %s (%s); round trip %s (this PC's clock)", tostring(w[6]), tostring(kind), tostring(cl), txt, p and table.concat(p.hs, ",") or "-", rtt)
  stat(S, "a_answer_" .. tostring(cl))
  if p then
    M.pend[seq] = nil
    for _, lh in ipairs(p.lhs) do if M.pendSq[lh] == seq then M.pendSq[lh] = nil; M.ackWall[lh] = tonumber(w[2]) end end
    if cl ~= "ok" and C.notify then
      local who = {}
      for _, lh in ipairs(p.lhs) do local n = R.sqValid and R.sqValid(lh) and nameOf(S, lh); who[#who + 1] = (n and n ~= "") and n or ("unit " .. lh) end
      local unit = (#who > 0) and table.concat(who, ", ") or "your units"
      if cl == "changed" then C.notify("info", string.format("Your order (%s) for %s was changed by the host: %s.", orderKindText(kind), unit, txt))
      else C.notify("info", string.format("Your order (%s) for %s was not carried out: %s.", orderKindText(kind), unit, txt)) end
    end
  end
end
M.onAck = onAck
-- (friend) orders with no answer in 3 s: the mirror follows the host again
function M.orderTick(S, clock)
  for seq, p in pairs(M.pend) do
    if clock - p.t >= 3.0 then
      M.pend[seq] = nil
      for _, lh in ipairs(p.lhs) do if M.pendSq[lh] == seq then M.pendSq[lh] = nil end end
      log("ORDER %d (%s %s): no answer from the host in 3 s: the mirror follows the host again", seq, p.kind, table.concat(p.hs, ","))
      stat(S, "a_answer_none")
    end
  end
end
C.orderPending = function(lh) return M.pendSq[lh] ~= nil end
C.orderAckWall = function(lh) return M.ackWall[lh] end
local armyTick, armyMsg = tick, onMessage
local function tick2(S, clock)
  armyTick(S, clock)
  if C.hold or not valid(S.p1) then return end
  if clock - (M.tRet or 0) >= 0.5 then M.tRet = clock; local ok, e = pcall(scanRetinue, S, clock); if not ok then log("RETINUE scan error: %s", tostring(e)) end; hookPay(S, clock); pcall(function() M.silv = S.p1.silver end); pcall(function() M.rwealth = rmanors(S)[1]:GetRegion().regionalWealth end) end
  -- (lane 70) shapes: the host's watcher every 0.25 s, a friend's check every 0.5 s
  if next(M.form) and clock - (M.tShape or 0) >= 0.25 then M.tShape = clock; local ok, e = pcall(shapeWatch, S, clock); if not ok then log("ARMY shape watch error: %s", tostring(e)) end end
  -- (lane 70, C) once a minute a friend measures the real round trip ("O PING", answered by the host's army module)
  if S.role == "friend" and clock - (M.pingT or (clock - 50.0)) >= 60.0 then M.pingT = clock; send(string.format("O PING 0 %.4f", clock)) end
  if not M.pingT then M.pingT = clock - 50.0 end
  if S.role == "friend" and next(M.pend) then local ok, e = pcall(M.orderTick, S, clock); if not ok then log("ORDER tick error: %s", tostring(e)) end end
  if next(M.measQ) then local ok, e = pcall(measureTick, S, clock); if not ok then log("ARMY shape measure error: %s", tostring(e)) end end
  if S.role == "friend" and next(M.hostShape) and clock - (M.tShapeC or 0) >= 0.5 then M.tShapeC = clock; local ok, e = pcall(shapeCheck, S, clock); if not ok then log("ARMY shape check error: %s", tostring(e)) end end
end
local function onMessage2(S, from, kind, w, line)
  if kind == "K" then return onRetinue(S, from, w) end
  -- (lane 70, C) the host's answer to this friend's probe: the real round trip on this PC's own clock, and how far the
  -- host's clock is from this one (the host's stamp against the middle of the round trip). The APPLIED lines' delay_ms
  -- on the host is the host's clock minus this PC's: it holds this offset (about 0.9 s in the 2026-11-17 session).
  if kind == "A" and w[4] == "ACK" then local ok, e = pcall(onAck, S, w); if not ok then log("ORDER answer error: %s", tostring(e)) end; return true end
  if kind == "A" and w[4] == "PONG" then
    if S.role == "friend" and from == "host" and w[5] == S.name then
      local sent = tonumber(w[6]); local ht = tonumber(w[2])
      if sent then
        local rtt = os.clock() - sent
        local mid = A.now() - rtt / 2
        log("link: round trip to the host and back %.0f ms (this PC's clock); the host's clock is %+.0f ms from this PC's", rtt * 1000, ht and (ht - mid) * 1000 or 0)
        stat(S, "a_pings")
      end
    end
    return true
  end
  if kind == "A" and w[4] == "SHAPE" then
    if S.role == "friend" and from == "host" and not C.hold then local ok, e = pcall(onShape, S, w); if not ok then log("ARMY SHAPE from the host: error %s", tostring(e)) end end
    return true
  end
  if kind == "A" and (w[4] == "PATH" or w[4] == "BLD" or w[4] == "LINE") then
    if S.role == "friend" and from == "host" and not C.hold then local ok, e = pcall(onOrderMsg, S, w); if not ok then log("ARMY %s from the host: error %s", tostring(w[4]), tostring(e)) end end
    return true
  end
  return armyMsg(S, from, kind, w, line)
end

C.register("army", { onWorld = function(S) reset(); rreset() end, tick = tick2, onMessage = onMessage2 })
return "coop_x_army loaded"
