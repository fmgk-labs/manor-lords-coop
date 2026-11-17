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

local function reset() M.names = {}; M.fresh = {}; M.way = {}; M.worldT = os.clock() end
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
      if nameOf(S, h) ~= name then setName(S, h, name); stat(S, "a_named"); log("ARMY squad %d is called [%s] on the host: named here", h, name) end
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
  local ok, e = pcall(function() R.issuer(s):formALineArmy({ { Value = h } }, { A = a, B = b }, FName("None"), { A = a, B = b }); R.commit(h) end)
  if not ok then return "error " .. tostring(e) end
  stat(S, "a_lines")
  return "ok"
end
local function decLine(w, i)
  local n = {}; for k = i, i + 4 do n[#n + 1] = tonumber(w[k]) end
  if #n < 5 then return nil end
  return { X = n[1], Y = n[2], Z = n[5] }, { X = n[3], Y = n[4], Z = n[5] }
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
  if moved and mode == 0 and hb == 0 and #mine == 1 then
    local h = mine[1]; local s = S.sc:GetSquad({ Value = h })
    local tx, ty = s.TargetLocation.X, s.TargetLocation.Y
    local d = math.sqrt((tx - cx) ^ 2 + (ty - cy) ^ 2)
    if s.lastSquadTargetType == 1 and s.targetSquad.Value == 0 and d > 150 and d < 30000 then
      R.touch(h)                                             -- the core's watcher must not also send it as a plain move
      local line2 = string.format("%.0f %.0f %.0f %.0f %.0f", 2 * tx - cx, 2 * ty - cy, cx, cy, cz)
      if S.role == "host" then send("A LINE " .. h .. " " .. line2); log("ARMY this player dragged squad %d into a line %.0f long: sent to friends", h, 2 * d)
      else send(string.format("O LINE %d %s", A.toHost(h), line2)); S.localOrderT[h] = clock; log("ARMY this player dragged squad %d into a line %.0f long: sent to the host", h, 2 * d) end
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
      if s.lastSquadTargetType == 1 and s.targetSquad.Value == 0 then t[#t + 1] = { h = h, x = s.TargetLocation.X, y = s.TargetLocation.Y } end
    end
    if #t < 2 then return end
    local far, fd = t[1], -1
    for _, e in ipairs(t) do local d = (e.x - cx) ^ 2 + (e.y - cy) ^ 2; if d > fd then far, fd = e, d end end
    local dx, dy = cx - far.x, cy - far.y; local len = math.sqrt(dx * dx + dy * dy)
    if len < 150 or len > 60000 then return end
    dx, dy = dx / len, dy / len
    for _, e in ipairs(t) do e.p = (cx - e.x) * dx + (cy - e.y) * dy end     -- distance from cur back along the line
    table.sort(t, function(a, b) return a.p < b.p end)
    local hw = math.max(150, t[1].p)
    for i, e in ipairs(t) do
      if i > 1 then hw = math.max(150, (e.p - t[i - 1].p) - hw) end
      R.touch(e.h)
      local line2 = string.format("%.0f %.0f %.0f %.0f %.0f", e.x - dx * hw, e.y - dy * hw, e.x + dx * hw, e.y + dy * hw, cz)
      if S.role == "host" then send("A LINE " .. e.h .. " " .. line2) else send(string.format("O LINE %d %s", A.toHost(e.h), line2)); S.localOrderT[e.h] = clock end
      stat(S, "a_lineSent")
    end
    log("ARMY this player dragged %d squads into one line %.0f long: each squad's piece sent to %s", #t, t[#t].p + hw, S.role == "host" and "friends" or "the host")
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
  if kind == "PATH" then
    if not (h and R.sqValid(h)) then return "no such squad" end
    if S.sc:GetUnitCount({ Value = h }) == 0 then return "empty" end
    local pts = C.patch and C.patch.decPoints and C.patch.decPoints(w[6]) or {}
    local r = applyPath(S, h, pts, os.clock())
    if r == "ok" then send(string.format("A PATH %d %s", h, w[6])) end
    return r
  elseif kind == "LINE" then                                  -- O LINE <squad> <ax> <ay> <bx> <by> <z> (lane 34)
    local a, b = decLine(w, 6); if not a then return "bad line" end
    local r = applyLine(S, h, a, b, os.clock())
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

local armyTick, armyMsg = tick, onMessage
local function tick2(S, clock)
  armyTick(S, clock)
  if C.hold or not valid(S.p1) then return end
  if clock - (M.tRet or 0) >= 0.5 then M.tRet = clock; local ok, e = pcall(scanRetinue, S, clock); if not ok then log("RETINUE scan error: %s", tostring(e)) end; hookPay(S, clock); pcall(function() M.silv = S.p1.silver end); pcall(function() M.rwealth = rmanors(S)[1]:GetRegion().regionalWealth end) end
end
local function onMessage2(S, from, kind, w, line)
  if kind == "K" then return onRetinue(S, from, w) end
  if kind == "A" and (w[4] == "PATH" or w[4] == "BLD" or w[4] == "LINE") then
    if S.role == "friend" and from == "host" and not C.hold then local ok, e = pcall(onOrderMsg, S, w); if not ok then log("ARMY %s from the host: error %s", tostring(w[4]), tostring(e)) end end
    return true
  end
  return armyMsg(S, from, kind, w, line)
end

C.register("army", { onWorld = function(S) reset(); rreset() end, tick = tick2, onMessage = onMessage2 })
return "coop_x_army loaded"
