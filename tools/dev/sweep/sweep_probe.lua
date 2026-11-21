-- Parity sweep (lane 68): the in-game stepper. Test console only (tools/dev/CoopProbe), never in the players' mod.
-- The driver (sweep.sh) writes a header in front of this file and runs it with `np` / `np2`:
--   SW_CMD  = "start" | "status" | "stop"
--   SW_DIR  = folder of this file (sweep_walk.lua is loaded from there)
--   SW_OUT  = the dump file this copy writes (start only; it is emptied first)
--   SW_ONLY = "" or a comma list of building types and / or keys (type@x,y) to sweep (a smoke test); "" = all
--   SW_SCREENS = "1" to also open the screens of SCREENS below (first run: each is tried, skipped and logged on error)
--   SW_WAIT = steps (of SW_STEP ms) after an open or a tab change before the panel is read (default 5)
-- The console call returns at once; a loop of the game thread (LoopInGameThreadWithDelay, as lanes/lane_s21_12's
-- campwatch.lua) does one small step per call: open a panel, wait, read one tab (the whole tab inside one step), press
-- the next tab, wait, ..., close it, go to the next. Nothing of the game is kept from one step to the next: a building
-- is found again by its key each step, the panel again by its class.
--
-- SAFETY (the rules of this project):
--   * reads only, through sweep_walk.lua; the only calls with an effect are the game's own panel openers listed here:
--     PawnCPP:deselect_buildings, PawnCPP:openBuildingTab(b, false) (both used by the harness's `openb`), a press of a
--     panel's main tab button (the harness's `tab`), and in SCREENS: switchTab, changeSelectedRegionUI,
--     toggleDevelopmentPanel, setMapMode (first run, each in its own pcall; the screen is left as it was);
--   * every handle is checked alive before use; every game list is read as "local n = #arr; for i = 1, n";
--   * one panel action per step, a step every SW_STEP ms; a panel that does not open within SW_TRIES steps is skipped
--     and logged ("E <key> OPENFAIL"); 20 errors in steps end the sweep ("#ABORT");
--   * the game must be paused (the driver pauses it through the host); a copy that is not paused writes "#WARN".
-- Dump lines (tab separated):
--   #H key=value ...                         header: role, day, hour, paused, speed, building counts per type
--   P <panel> <tab> <path> <kind> <value>     one drawn value (kinds: sweep_walk.lua)
--   E <panel> <what>                          a panel that failed, a truncated walk, a read note
--   #END key=value ...                        footer
-- <panel> is "B <bkey>" for a building (bkey as the mod's world module writes it, type@x/10,y/10, so a difference
-- can be set beside the "wide" lines of the friend's log), "HUD", "TAB <n>", "REGION <tag>", "DEV", "MAP", "VIEW <class>".
local G = rawget(_G, "__l68")
local CMD = rawget(_G, "SW_CMD") or "status"

if CMD == "status" then
  if not G then return "idle (no sweep in this game)" end
  return string.format("%s job %d/%d %s records=%d fails=%d errors=%d out=%s", G.done and "done" or (G.aborted and "aborted" or "running"),
    G.ji or 0, #(G.jobs or {}), tostring(G.phase), G.nrec or 0, G.fails or 0, G.errs or 0, tostring(G.out))
end
if CMD == "stop" then
  if not G then return "idle" end
  G.stop = true; pcall(function() if G.handle and rawget(_G, "CancelDelayedAction") then CancelDelayedAction(G.handle) end end)
  pcall(function() local lord = FindFirstOf("RTSMultiEngineCPP").playerRef; lord:deselect_buildings() end)
  return "stopped"
end
if CMD ~= "start" then return "unknown SW_CMD " .. tostring(CMD) end
if G and not G.done and not G.aborted and not G.stop then return "a sweep is running already: SW_CMD=stop first" end

local DIR = rawget(_G, "SW_DIR") or ""
local OUT = rawget(_G, "SW_OUT")
if not OUT or OUT == "" then return "no SW_OUT" end
local okW, WALK = pcall(dofile, DIR .. "sweep_walk.lua")
if not okW or type(WALK) ~= "table" then return "cannot load sweep_walk.lua from " .. DIR .. ": " .. tostring(WALK) end
local alive, cname = WALK.alive, WALK.cname

local STEP = tonumber(rawget(_G, "SW_STEP") or "") or 100
local WAIT = tonumber(rawget(_G, "SW_WAIT") or "") or 5
local TRIES = 30
local CLICK = "BndEvt__W_MaterialButton_Button_K2Node_ComponentBoundEvent_4_OnButtonClickedEvent__DelegateSignature"
-- not compared: what depends on the camera or the pointer (floaters over buildings, map labels, minimap, tooltips),
-- and the building panel inside the HUD walk (each building is walked on its own)
local SKIP_HUD = { BuildingFloater_C = true, castleFloater_C = true, castleFloater_platformLevel_C = true, castleFloater_wallOptionWidget_C = true,
  minimapIcon_C = true, MinimapTree_C = true, TownName_C = true, regionName_BP_C = true, GateControl_C = true, workAreaConfirmationBlop_C = true,
  constructionFeedbackWidget_C = true, W_ToolTipContainer_C = true, W_ToolTipV2_C = true, MLSharedToolTipContainerWidget = true, CustomTooltip_C = true,
  CustomTooltipLarge_C = true, squadTooltip_C = true, Inventory_C = true, HideCursorWidget_C = true, MD_NaviConsoleCursor_C = true,
  -- (lane 81) the control hints ("Town Centers [T]", ...) follow what the owner's real mouse pointer hovers in that
  -- window: each player's own pointer rightly decides them; they are not game state and differ by where the pointer is
  ControlTooltipPanel_C = true }
local SKIP_PANEL = { W_ToolTipContainer_C = true, W_ToolTipV2_C = true, MLSharedToolTipContainerWidget = true, CustomTooltip_C = true, CustomTooltipLarge_C = true }
-- screens that are not inside the main HUD; dumped when one is in the viewport after an opener
local VIEW_CLASSES = { "mercenaryScreen_C", "retinueEditor_C", "census_C", "legacyViewWidget_C", "BP_PerkOverviewPanel_C", "BP_PerkSelectionPanel_C",
  "developmentPanelTree_C", "regionProductionPanel_Widget_C", "transactionLog_C", "MessageFullscreen_C" }

local function ok1(f, ...) local ok, v = pcall(f, ...); if ok then return v end; return nil end
local function eng() local e = FindFirstOf("RTSMultiEngineCPP"); if alive(e) then return e end end
local function lordOf(e) local l = ok1(function() return e.playerRef end); if alive(l) then return l end end
local function un(x) local g = ok1(function() return x:get() end); if g ~= nil then return g end; return x end
local function addr(o) return ok1(function() return o:GetAddress() end) end
local function btype(b) return ok1(function() return b:GetType() end) end
local function bkey(b)
  local C = rawget(_G, "Coop")
  if C and C.world and C.world.bkey then local k = ok1(C.world.bkey, b); if k then return k end end
  local l = ok1(function() return b:K2_GetActorLocation() end); local t = btype(b)
  if not l or not t then return nil end
  return string.format("%d@%d,%d", t, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5))
end
local function rkey(r)
  local C = rawget(_G, "Coop")
  if C and C.world and C.world.rkey then local k = ok1(C.world.rkey, r); if k then return k end end
  return ok1(function() return r.regionUniqueTag:ToString() end) or "?"
end
local function mine(b, lord) local a, m = ok1(function() return b.ownerPawn:GetAddress() end), addr(lord); return a ~= nil and a == m end
local function shown(w) local v = ok1(function() return w:GetVisibility() end); return v == nil or (v ~= 1 and v ~= 2) end
-- on screen: in the viewport itself, or placed in a parent. The building panel (Inventory_C) is a child of the main
-- interface, so IsInViewport() is false for it while it shows: the first run (lane 71, run e1) took every panel as
-- closed because of that (OPENFAIL on all 15 buildings). A closed panel is taken off its parent (lane 69's
-- coop_x_panels.lua openPanels: DestroyInventoryWindow).
local function onScreen(w)
  if ok1(function() return w:IsInViewport() end) == true then return true end
  local p = ok1(function() return w:GetParent() end)
  return p ~= nil and alive(p)
end
local function visibleOf(cls)
  local t = {}
  local all = ok1(function() return FindAllOf(cls) end) or {}
  for i = 1, #all do local w = all[i]; if alive(w) and shown(w) and onScreen(w) then t[#t + 1] = w end end
  return t
end
-- the open building panel: of the shown ones, the one whose own "building" is the building of key (any, without key)
local function panel(key)
  local last
  for _, w in ipairs(visibleOf("Inventory_C")) do
    local b = ok1(function() return w.building end)
    if alive(b) then
      if not key then last = w elseif bkey(b) == key then return w end
    end
  end
  return last
end
local function hud() local p = visibleOf("MainUICPP_C"); return p[#p] end

-- the engine's building list, read once per call (never past its end); the building of a key
local function findB(e, key)
  local arr = e.buildingArr; local n = #arr
  for i = 1, n do local b = un(arr[i]); if alive(b) and bkey(b) == key then return b end end
end
local function findR(e, tag)
  local arr = e.regions; local n = #arr
  for i = 1, n do local r = un(arr[i]); if alive(r) and rkey(r) == tag then return r end end
end

-- the shown main tab buttons of the open panel, in order (as the harness's `tab`)
local function tabs(p)
  local sel
  local function find(w, d)
    if sel or d > 40 or not alive(w) or not shown(w) then return end
    if WALK.oname(w) == "HorizontalRadioSelect_MainTabs" then sel = w; return end
    local n = ok1(function() return w:GetChildrenCount() end)
    if type(n) == "number" then for i = 0, n - 1 do find(ok1(function() return w:GetChildAt(i) end), d + 1) end; return end
    local c = ok1(function() return w:GetContent() end); if alive(c) then find(c, d + 1); return end
    if cname(w):sub(1, 3) ~= "MD_" then local r = ok1(function() return w.WidgetTree.RootWidget end); if alive(r) then find(r, d + 1) end end
  end
  find(p, 0)
  local out = {}
  if not sel then return out end
  local function collect(w, d)
    if d > 12 or not alive(w) or not shown(w) then return end
    if cname(w) == "W_InventoryRadioButton_C" then out[#out + 1] = w; return end
    local n = ok1(function() return w:GetChildrenCount() end)
    if type(n) == "number" then for i = 0, n - 1 do collect(ok1(function() return w:GetChildAt(i) end), d + 1) end; return end
    local c = ok1(function() return w:GetContent() end); if alive(c) then collect(c, d + 1); return end
    local r = ok1(function() return w.WidgetTree.RootWidget end); if alive(r) then collect(r, d + 1) end
  end
  collect(sel, 0)
  return out
end
local function tabLabel(btn)
  local recs = WALK.walk(btn, { maxNodes = 80 })
  for _, r in ipairs(recs) do if r.kind == "T" and r.val ~= "" then return r.val end end
  return "?"
end
local function pressTab(btn)
  local inner
  local function find(w, d)
    if inner or d > 12 or not alive(w) then return end
    if cname(w) == "W_MaterialButton_C" and WALK.oname(w) == "Button" then inner = w; return end
    local n = ok1(function() return w:GetChildrenCount() end)
    if type(n) == "number" then for i = 0, n - 1 do find(ok1(function() return w:GetChildAt(i) end), d + 1) end; return end
    local c = ok1(function() return w:GetContent() end); if alive(c) then find(c, d + 1); return end
    local r = ok1(function() return w.WidgetTree.RootWidget end); if alive(r) then find(r, d + 1) end
  end
  find(btn, 0)
  local b = inner or btn
  return pcall(function() b[CLICK](b) end)
end

-- ------------------------------------------------------------------ the run
G = { jobs = {}, ji = 0, phase = "init", wait = 0, nrec = 0, fails = 0, errs = 0, out = OUT, t0 = os.clock(), panels = 0 }
_G.__l68 = G
local f = io.open(OUT, "w"); if not f then _G.__l68 = nil; return "cannot write " .. OUT end; f:close()
local buf = {}
local function emit(line) buf[#buf + 1] = line end
local function flush()
  if #buf == 0 then return end
  local fh = io.open(OUT, "a"); if fh then fh:write(table.concat(buf, "\n"), "\n"); fh:close() end
  buf = {}
end
local function dump(panelKey, tab, root, skip)
  local recs, st = WALK.walk(root, { skip = skip })
  for _, r in ipairs(recs) do
    if r.kind == "!" then emit("E\t" .. panelKey .. "\t" .. tab .. " " .. r.path .. " " .. r.val)
    else emit("P\t" .. panelKey .. "\t" .. tab .. "\t" .. r.path .. "\t" .. r.kind .. "\t" .. r.val); G.nrec = G.nrec + 1 end
  end
  emit(string.format("E\t%s\t%s walked nodes=%d values=%d failed=%d skipped=%d%s", panelKey, tab, st.nodes, st.values, st.failed, st.skipped, st.truncated and " TRUNCATED" or ""))
end
local function dumpViews(prefix)
  for _, cls in ipairs(VIEW_CLASSES) do
    for i, w in ipairs(visibleOf(cls)) do dump("VIEW " .. cls .. "#" .. i, prefix, w, SKIP_PANEL) end
  end
end

-- header and the job list (keys only)
local e = eng(); if not e then _G.__l68 = nil; return "no engine" end
local lord = lordOf(e); if not lord then _G.__l68 = nil; return "no lord" end
local only = {}; for x in (rawget(_G, "SW_ONLY") or ""):gmatch("[^,%s]+") do only[x] = true end
local useOnly = next(only) ~= nil
local keys, types, all = {}, {}, 0
do
  local arr = e.buildingArr; local n = #arr
  for i = 1, n do
    local b = un(arr[i])
    if alive(b) then
      all = all + 1
      if mine(b, lord) then
        local k = bkey(b); local t = btype(b)
        if k and t then
          types[t] = (types[t] or 0) + 1
          if not useOnly or only[tostring(t)] or only[k] then keys[#keys + 1] = k end
        end
      end
    end
  end
end
table.sort(keys)
-- (lane 81) nothing of the sweep may depend on the owner's real mouse pointer: edge scrolling off (a pointer resting at
-- a window's edge scrolled that copy's camera to the map's edge in some starts), the camera on the place SW_CAM gives
-- (the host's, the same on both copies), and the town region chosen by name (the lowest tag among the player's own
-- regions), so that the development tree and the map view open on it and not on the region under the pointer
G.setup = {}
pcall(function() local l = lord:K2_GetActorLocation(); G.setup[#G.setup + 1] = string.format("camera before %.0f,%.0f,%.0f", l.X, l.Y, l.Z) end)
pcall(function() local gi = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetGameInstance(lord); gi:SetEdgeScrolling(false); G.setup[#G.setup + 1] = "edge scrolling off" end)
if rawget(_G, "SW_CAM") and SW_CAM ~= "" then
  local x, y, z = SW_CAM:match("^(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)$")
  if x then pcall(function() lord:K2_SetActorLocation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, false, {}, true); G.setup[#G.setup + 1] = "camera " .. SW_CAM end) end
end
do
  local tags = {}
  local arr = e.regions; local n = #arr
  for i = 1, n do local r = un(arr[i]); if alive(r) and mine(r, lord) then tags[#tags + 1] = rkey(r) end end
  table.sort(tags); G.town = tags[1]; G.setup[#G.setup + 1] = "town region " .. tostring(G.town)
end
local tl, nmine = {}, 0; for t, c in pairs(types) do tl[#tl + 1] = t .. ":" .. c; nmine = nmine + c end; table.sort(tl)
local C = rawget(_G, "Coop")
local role = (C and C.s and C.s.role) or rawget(_G, "SW_ROLE") or "?"
local day = ok1(function() return e:getDaysTotal() end)
local T = ok1(function() return e.TemporalComponent end)
local hour = ok1(function() return T.day end)
local paused = ok1(function() return lord.bIsPlayerPaused end)
local speed = ok1(function() return e.gameSpeed end)
emit(string.format("#H role=%s day=%s dayfield=%s paused=%s speed=%s buildings=%d mine=%d swept=%d types=%s only=%s screens=%s ver=1",
  tostring(role), tostring(day), tostring(hour), tostring(paused), tostring(speed), all, nmine, #keys, table.concat(tl, ","), tostring(rawget(_G, "SW_ONLY") or ""), tostring(rawget(_G, "SW_SCREENS") or "0")))
if not (paused and (tonumber(speed) or 1) <= 0.001) then emit("#WARN this copy is not paused: values move while the sweep reads them") end
emit("#S setup: " .. table.concat(G.setup or {}, ", "))          -- (lane 81) what the sweep set so that the pointer decides nothing
flush()

G.jobs[#G.jobs + 1] = { kind = "hud" }
for _, k in ipairs(keys) do G.jobs[#G.jobs + 1] = { kind = "b", key = k } end
if rawget(_G, "SW_SCREENS") == "1" then
  local arr = e.regions; local n = #arr
  for i = 1, n do local r = un(arr[i]); if alive(r) and mine(r, lord) then G.jobs[#G.jobs + 1] = { kind = "region", tag = rkey(r) } end end
  -- the army panel and unit cards, once per squad of the player's lord: the squad is selected the game's own way
  -- (selectSquad, as the harness's `apress`); a squad is named by its number, the same on every copy (from the save)
  do
    local sq = ok1(function() return lord.commandedSquads end)
    local ns = sq and ok1(function() return #sq end) or 0
    local hs = {}
    for i = 1, ns do local h = ok1(function() return sq[i].Value end); if type(h) == "number" and h ~= 0 then hs[#hs + 1] = h end end
    table.sort(hs)
    for _, h in ipairs(hs) do G.jobs[#G.jobs + 1] = { kind = "army", h = h } end
  end
  for i = 0, 7 do G.jobs[#G.jobs + 1] = { kind = "tab", i = i } end
  G.jobs[#G.jobs + 1] = { kind = "dev" }
  G.jobs[#G.jobs + 1] = { kind = "map" }
end

-- one step: returns nothing; G.phase / G.wait carry the state
local function nextJob()
  G.ji = G.ji + 1; G.phase = "start"; G.wait = 0; G.tab = nil; G.ntabs = nil; G.tries = 0; G.second = nil
end
local function finish()
  pcall(function() local l = lordOf(eng()); l:deselect_buildings() end)
  emit(string.format("#END jobs=%d panels=%d records=%d fails=%d errors=%d seconds=%.1f", #G.jobs, G.panels, G.nrec, G.fails, G.errs, os.clock() - G.t0))
  flush(); G.done = true
end

local function stepB(J, e2, l2)
  local pk = "B " .. J.key
  if G.phase == "start" then
    pcall(function() l2:deselect_buildings() end)
    local b = findB(e2, J.key)
    if not b then emit("E\t" .. pk .. "\tGONE (not in the building list)"); G.fails = G.fails + 1; nextJob(); return end
    local ok, er = pcall(function() l2:openBuildingTab(b, false) end)
    if not ok then emit("E\t" .. pk .. "\tOPENFAIL " .. tostring(er)); G.fails = G.fails + 1; nextJob(); return end
    G.phase = "open"; G.wait = WAIT; return
  end
  if G.phase == "open" or G.phase == "tabwait" then
    local p = panel(J.key)
    if not p then
      G.tries = G.tries + 1
      -- half way: open it the way a click does (the lord selects the building, then opens its tab), once
      if G.phase == "open" and G.tries == math.floor(TRIES / 2) and not G.second then
        G.second = true
        local b = findB(e2, J.key)
        if b then
          pcall(function() l2:deselect_buildings() end)
          local okS = pcall(function() l2:selectBuildingSilent(b) end)
          local okO = pcall(function() l2:openBuildingTab(b, false) end)
          emit("E\t" .. pk .. "\tRETRY select=" .. tostring(okS) .. " open=" .. tostring(okO))
        end
      end
      if G.tries > TRIES then
        local seen = #visibleOf("Inventory_C"); local any = ok1(function() return #FindAllOf("Inventory_C") end) or 0
        emit("E\t" .. pk .. "\tOPENFAIL no panel of this building after " .. TRIES .. " steps (Inventory_C: " .. any .. " made, " .. seen .. " on screen)")
        G.fails = G.fails + 1; G.phase = "close"
      end
      return
    end
    -- the panel is found by its own building, so it is this building's panel
    local sel = G.second and "ok-after-select" or "ok"
    if G.phase == "open" then
      local list = tabs(p); G.ntabs = #list; G.tab = 1
      local lab = (#list > 0) and tabLabel(list[1]) or "-"
      emit("E\t" .. pk .. "\tOPENED tabs=" .. #list .. " selected=" .. sel)
      dump(pk, "1:" .. lab, p, SKIP_PANEL); G.panels = G.panels + 1
    else
      local list = tabs(p)
      local lab = list[G.tab] and tabLabel(list[G.tab]) or "?"
      dump(pk, G.tab .. ":" .. lab, p, SKIP_PANEL)
    end
    if G.tab < (G.ntabs or 0) then G.phase = "tabpress" else G.phase = "close" end
    return
  end
  if G.phase == "tabpress" then
    local p = panel(J.key); if not p then emit("E\t" .. pk .. "\tPANEL CLOSED before tab " .. (G.tab + 1)); G.fails = G.fails + 1; G.phase = "close"; return end
    local list = tabs(p); local btn = list[G.tab + 1]
    if not btn then emit("E\t" .. pk .. "\tTAB " .. (G.tab + 1) .. " gone (" .. #list .. " tabs now)"); G.phase = "close"; return end
    local ok, er = pressTab(btn)
    if not ok then emit("E\t" .. pk .. "\tTABFAIL " .. (G.tab + 1) .. " " .. tostring(er)); G.phase = "close"; return end
    G.tab = G.tab + 1; G.phase = "tabwait"; G.wait = WAIT; G.tries = 0; return
  end
  if G.phase == "close" then
    pcall(function() l2:deselect_buildings() end)
    G.phase = "closed"; G.wait = 1; return
  end
  if G.phase == "closed" then
    if panel(J.key) then emit("E\t" .. pk .. "\tSTILL OPEN after deselect") end
    nextJob(); return
  end
end

local function stepScreen(J, e2, l2)
  local pk = (J.kind == "tab" and ("TAB " .. J.i)) or (J.kind == "region" and ("REGION " .. J.tag)) or (J.kind == "dev" and "DEV")
    or (J.kind == "army" and ("ARMY " .. J.h)) or "MAP"
  if G.phase == "start" then
    pcall(function() l2:deselect_buildings() end)
    local ok, er = true, nil
    if J.kind == "tab" then
      ok, er = pcall(function() l2:switchTab(J.i) end)
    elseif J.kind == "region" then
      G.prevRegion = nil; pcall(function() local s = l2.selectedRegion; if alive(s) then G.prevRegion = rkey(s) end end)
      local r = findR(e2, J.tag); if not r then ok, er = false, "region gone" else ok, er = pcall(function() l2:changeSelectedRegionUI(r) end) end
    elseif J.kind == "army" then ok, er = pcall(function() l2:selectSquad({ Value = J.h }, true, false) end)
    elseif J.kind == "dev" then
      -- (lane 81) on the town region by name (the game's own openDevelopmentPanel(Region)); the toggle opens it on the
      -- region under the pointer
      local r = G.town and findR(e2, G.town)
      if r then ok, er = pcall(function() l2:openDevelopmentPanel(r) end) end
      if not (r and ok) then ok, er = pcall(function() l2:toggleDevelopmentPanel() end) end
    else
      local r = G.town and findR(e2, G.town); if r then pcall(function() l2:changeSelectedRegionUI(r) end) end   -- (lane 81) the town region selected first
      ok, er = pcall(function() l2:setMapMode(true) end)
    end
    if not ok then emit("E\t" .. pk .. "\tOPENFAIL " .. tostring(er)); G.fails = G.fails + 1; G.phase = "undo"; return end
    G.phase = "read"; G.wait = WAIT; return
  end
  if G.phase == "read" then
    local h = hud()
    if h then dump(pk, "-", h, SKIP_HUD); G.panels = G.panels + 1 else emit("E\t" .. pk .. "\tno HUD") end
    dumpViews(pk)
    G.phase = "undo"; return
  end
  if G.phase == "undo" then
    if J.kind == "tab" then pcall(function() l2:switchTab(0) end)
    elseif J.kind == "region" then if G.prevRegion then local r = findR(e2, G.prevRegion); if r then pcall(function() l2:changeSelectedRegionUI(r) end) end end
    elseif J.kind == "dev" then pcall(function() l2:toggleDevelopmentPanel() end)
    elseif J.kind == "army" then pcall(function() l2:deselectSquad({ Value = J.h }) end)
    elseif J.kind == "map" then pcall(function() l2:setMapMode(false) end) end
    G.phase = "done"; G.wait = 2; return
  end
  nextJob()
end

local function step()
  if G.stop or G.done or G.aborted then return true end
  if G.wait > 0 then G.wait = G.wait - 1; return end
  if G.ji == 0 then nextJob() end
  local J = G.jobs[G.ji]
  if not J then finish(); return true end
  local e2 = eng(); local l2 = e2 and lordOf(e2)
  if not (e2 and l2) then emit("#ABORT the world is gone"); flush(); G.aborted = true; return true end
  if J.kind == "hud" then
    if G.phase == "start" then pcall(function() l2:deselect_buildings() end); G.phase = "read"; G.wait = WAIT; return end
    local h = hud(); if h then dump("HUD", "-", h, SKIP_HUD); G.panels = G.panels + 1 else emit("E\tHUD\tno HUD") end
    nextJob(); return
  end
  if J.kind == "b" then stepB(J, e2, l2) else stepScreen(J, e2, l2) end
  if #buf > 200 then flush() end
end

local okL, h = pcall(LoopInGameThreadWithDelay, STEP, function()
  if G.stop or G.done or G.aborted then return true end
  local ok, er = pcall(step)
  if not ok then
    G.errs = G.errs + 1; emit("E\t-\tstep error " .. tostring(er)); flush()
    if G.errs >= 20 then emit("#ABORT 20 errors"); flush(); G.aborted = true; pcall(function() lordOf(eng()):deselect_buildings() end); return true end
  end
  if G.done or G.aborted then flush(); return true end
end)
if not okL then _G.__l68 = nil; return "could not start the loop: " .. tostring(h) end
G.handle = h
return string.format("sweep started: %d jobs (%d buildings of %d mine, %d in the world), out=%s", #G.jobs, #keys, nmine, all, OUT)
