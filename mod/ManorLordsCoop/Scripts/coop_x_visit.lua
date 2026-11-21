-- Manor Lords Co-op: visit mode for every player (lane 86, for 0.2.8). Plug-in module "visit".
--
-- What the player gets (docs/plans/2026-11-19-visit-mode-plan.md; the agreed behaviour: locked_decisions_draft.md 6e):
--   * any player, host or friend, presses the walk key (coop.cfg "visit_key", default B) or the game's Explore button
--     and walks the game's own walker, on the ground under the camera. Nobody's game speed changes (the game's
--     visitModeOn is the entry without the speed change; lane 84). The key again, or the game's Enter / Escape, leaves.
--   * every other copy shows a body for each walking player at its place, with the player's name above it, whether
--     that copy walks or is in the normal view. Up to 8 players. The body vanishes when its player leaves.
--   * the host walks as the save's own lord; the host hands each friend a look (2 bodies x 4 colours) at random
--     without repeats, kept for that friend's slot (a reload keeps it). A friend's own walker takes its look.
--   * walkers are visitors: no fighting, cannot be hit, carry nothing; never saved (the game does not save them).
-- Host authority: a copy sends only its OWN walker; the host relays every walker to every friend. A walker changes
-- nothing in the town.
--
-- Lines (kinds free in the core and the other modules):
--   any copy -> host   VW 1 <x> <y> <z> <yaw> <v>      its own walker (cm, degrees, cm/s), 10 a second while it moves,
--                                                      1 a second while it stands
--                      VW 0                            its walker is gone (left, a load)
--   host -> friends    VH <entry> <entry> ...          every 100 ms, the walkers that changed since the last VH
--                      VF <entry> <entry> ...          every second: every player the host knows (its looks), walking
--                                                      or not; a body whose player is not walking in it is removed
--   entry  <who>,<look>,<age ms>,<x>,<y>,<z>,<yaw>,<v>   a walking player (age: how old the place is on the host's
--                                                        clock when the line leaves)
--          <who>,<look>,-                               a player that does not walk
--   look   body * 10 + colour: body 0 the lord's, 1 the lady's; colour 0 none (the host), 1 to 4
-- The host keys a friend's walker by the line's sender, never by a name inside a line.
--
-- Game objects: nothing is kept past the tick it is used in. Bodies are found again every tick in the game's own
-- list of walker-class actors (GetAllActorsOfClass) by their address; one that is no longer there is gone.
-- Not used anywhere here (each ended a test copy in lane 84's study): loading every listed mesh, asking a villager
-- part's instanced component for its class or owner. A widget's parents and outers are read only with every handle
-- checked before the next call (the study's two ends there were calls on null handles). Our key row (step 8) writes
-- only ActionName and MappingGroup on the game's key widget, and puts it into a row that is already in the list.
-- The key: coop.cfg "visit_key" is the first default; a key chosen in the game's Controls screen wins (step 8).
--
-- Switch: coop.cfg "visit = off": nothing of this module runs (no hooks, no lines, no key, no bodies); the mod is 0.2.7.
-- Console: Coop.visit.toggle() (what the key does), Coop.visit.status(), Coop.visit.enter(), Coop.visit.leave()

local C = rawget(_G, "Coop")
if not (C and C.register and C.api) then return "coop_x_visit: load coop.lua first" end
local A = C.api
local V = rawget(C, "visit") or {}; C.visit = V
local valid, log, send = A.valid, A.log, A.send
local atan2 = math.atan2 or math.atan

-- ---------------------------------------------------------------- settings
local function readCfg(path)
  local t = {}
  local f = path and io.open(path, "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if k and not line:match("^%s*#") then t[k] = v end
    end
    f:close()
  end
  return t
end
local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):gsub("\\", "/")
local modDir = (here:match("^(.*)/[^/]*/[^/]*$"))
V.cfg = V.cfg or {}
for k, v in pairs({ moveEvery = 0.1, standEvery = 1.0, hostEvery = 0.1, fullEvery = 1.0, delay = 0.0, snap = 300,
                    silence = 10.0, old = 2.0, standV = 5, gain = 150, walkMax = 115, runV = 180, sprintV = 420, ring = 200, rings = 10, showUI = true, gameKeys = true, row = true, rowEvery = 2.0, idleFullEvery = 10.0,
                    nudge = true, nudgeNear = 150, nudgeDirs = 3, camBack = 300, nudgeStep = 200, nudgeRings = 5 }) do
  if V.cfg[k] == nil then V.cfg[k] = v end
end
if V.wanted == nil then
  local f = readCfg(modDir and (modDir .. "/coop.cfg"))
  V.wanted = (os.getenv("COOP_VISIT") or f.visit or ""):lower() ~= "off"     -- (COOP_VISIT: the test harness, both copies)
  local key = (f.visit_key or ""):upper()
  V.key = key:match("^%u$") and key or "B"
end

-- ---------------------------------------------------------------- the line format (pure: no game calls; desk test)
local function r0(x) x = tonumber(x) or 0; if x >= 0 then return math.floor(x + 0.5) end; return -math.floor(-x + 0.5) end
-- e = { who, look, on, age (s), x, y, z, yaw, v }
function V.encEntry(e)
  if not e.on then return string.format("%s,%d,-", e.who, e.look or 0) end
  return string.format("%s,%d,%d,%d,%d,%d,%d,%d", e.who, e.look or 0, math.max(0, r0((e.age or 0) * 1000)), r0(e.x), r0(e.y), r0(e.z), r0(e.yaw) % 360, math.max(0, r0(e.v)))
end
function V.decEntry(s)
  if type(s) ~= "string" then return nil end
  local p = {}
  for x in s:gmatch("[^,]+") do p[#p + 1] = x end
  local who, look = p[1], tonumber(p[2])
  if not who or not who:match("^[%w_]+$") or not look then return nil end
  if p[3] == "-" and #p == 3 then return { who = who, look = look, on = false } end
  if #p ~= 8 then return nil end
  local n = {}
  for i = 3, 8 do n[i] = tonumber(p[i]); if not n[i] then return nil end end
  return { who = who, look = look, on = true, age = n[3] / 1000, x = n[4], y = n[5], z = n[6], yaw = n[7], v = n[8] }
end
function V.encOwn(on, x, y, z, yaw, v)
  if not on then return "VW 0" end
  return string.format("VW 1 %d %d %d %d %d", r0(x), r0(y), r0(z), r0(yaw) % 360, math.max(0, r0(v)))
end
-- w: the words of a line (w[1] seq, w[2] the sender's time, w[3] "VW")
function V.decOwn(w)
  if w[4] == "0" then return { on = false } end
  if w[4] ~= "1" then return nil end
  local n = {}
  for i = 5, 9 do n[i] = tonumber(w[i]); if not n[i] then return nil end end
  return { on = true, x = n[5], y = n[6], z = n[7], yaw = n[8], v = n[9] }
end
-- (ENTRIES, for desk test) the entries of a VH / VF line
function V.decList(w)
  local t = {}
  for i = 4, #w do local e = V.decEntry(w[i]); if e then t[#t + 1] = e end end
  return t
end

-- the clock of another copy against ours: the smallest seen difference (fastest delivery), let up slowly
function V.offFeed(off, sample)
  if off == nil or sample < off then return sample end
  if sample - off < 1.0 then return off + (sample - off) * 0.01 end
  return off
end

-- looks: the host deals the 8 looks of 2 bodies x 4 colours to friends at random without repeats, per slot
V.looks = V.looks or {}
V.pool = V.pool or nil
local seed = (os.time() % 100000) + 17
local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return (math.floor(seed / 65536) % n) + 1 end
V.rnd = rnd
function V.lookFor(who)
  if who == "host" then return V.hostLook or 0 end
  local l = V.looks[who]; if l then return l end
  if not V.pool or #V.pool == 0 then
    V.pool = { 1, 2, 3, 4, 11, 12, 13, 14 }
    for _, used in pairs(V.looks) do for i = #V.pool, 1, -1 do if V.pool[i] == used then table.remove(V.pool, i) end end end
    if #V.pool == 0 then V.pool = { 1, 2, 3, 4, 11, 12, 13, 14 } end      -- more than 8 friends: repeats
  end
  l = table.remove(V.pool, rnd(#V.pool)); V.looks[who] = l
  return l
end

-- ---------------------------------------------------------------- state
-- V.W: the host's table of every walker (also its own): who -> { look, on, x, y, z, yaw, v, t (host clock), dirty }
-- V.B: bodies drawn on this copy: who -> { addr, look, samples, tele, vanished, lastT }
local function reset(keepWalk)
  V.B = {}; V.W = V.W or {}
  if not keepWalk then V.W = {} end
  V.off = V.off or {}
  V.me = V.me or { was = false, sendT = -1e9 }
  V.hT = V.hT or -1e9; V.fT = V.fT or -1e9
  V.cost = V.cost or { n = 0, ms = 0, max = 0 }
end
reset(true)
local function stat(S, k, n) if S and S.stats then S.stats[k] = (S.stats[k] or 0) + (n or 1) end end
local function say(fmt, ...) log("visit: " .. fmt, ...) end

-- ---------------------------------------------------------------- game side (V.game can be swapped by a desk test)
local G = {}
V.game = V.game or G
local ALS = "/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/ALS_AnimMan_CharacterBP.ALS_AnimMan_CharacterBP_C"
local BODY = { [0] = "/Game/Characters/lord_01_v2/m_lord_001.m_lord_001", [1] = "/Game/Characters/Lady_01/Lady_T_posa_v5_End.Lady_T_posa_v5_End" }
local COLOUR = { { R = 0.55, G = 0.04, B = 0.03 }, { R = 0.04, G = 0.12, B = 0.65 }, { R = 0.06, G = 0.40, B = 0.06 }, { R = 0.80, G = 0.58, B = 0.04 } }
local function cs(o) local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end); return ok and n or "?" end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); return ok and a or nil end
local function GS() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
local function KSL() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
function G.pc(S) local pc = GS():GetPlayerController(S.p1, 0); if valid(pc) then return pc end end
-- the local walker: player 0's pawn when it is of the walker's class
function G.walker(S)
  local pc = G.pc(S); if not pc then return nil end
  local p = pc:K2_GetPawn()
  if valid(p) and cs(p) == "ALS_AnimMan_CharacterBP_C" then return p end
end
local function loc(a) local L = a:K2_GetActorLocation(); return L.X, L.Y, L.Z end
local function yawOf(a) return a:K2_GetActorRotation().Yaw end
local function speedOf(a) local v = a:GetVelocity(); return math.sqrt(v.X * v.X + v.Y * v.Y) end
function G.sample(w) local x, y, z = loc(w); return x, y, z, yawOf(w), speedOf(w) end
function G.mainUI() local m = FindFirstOf("MainUICPP_C"); if valid(m) then return m end end
-- ON SCREEN, not what a widget says of itself (the lead's real-key check on lane 9, 2026-11-20: after the pause menu,
-- its Save Game screen, Return and Continue, B was refused for good with "the settings screen is open": the pause
-- menu's own copy of the settings screen, made by menu_settingsWrapper_C, keeps IsVisible() true after the menu
-- closed; IsVisible looks at the widget alone). On screen = the widget and every panel and widget it sits in are
-- visible, a widget switcher on the way shows that branch, and the outermost widget is in the viewport. Bounded, and
-- every handle is checked before the next call on it (lane 84's study lost copies at 20:18 and 20:47 to UE4SS reading
-- the name or class of a null handle that GetOuter / GetParent gave back: lane_s21_86/report.txt, STEP 8).
-- Gives nil when it cannot decide (the UMG classes not found).
local UWCLS, WSCLS = "/Script/UMG.UserWidget", "/Script/UMG.WidgetSwitcher"
function G.onScreen(w)
  local uw, ws = StaticFindObject(UWCLS), StaticFindObject(WSCLS)
  if not valid(uw) then return nil end
  local function isA(o, c) if not valid(c) then return false end; local ok, r = pcall(function() return o:IsA(c) end); return ok and r == true end
  for _ = 1, 40 do
    if not valid(w) then return false end
    local okV, vis = pcall(function() return w:IsVisible() end)
    if not (okV and vis == true) then return false end
    if isA(w, uw) then
      local okI, inv = pcall(function() return w:IsInViewport() end)
      if okI and inv == true then return true end
    end
    local p; pcall(function() p = w:GetParent() end)
    if valid(p) then
      if isA(p, ws) then                                    -- a switcher paints only its active branch
        local a; pcall(function() a = p:GetActiveWidget() end)
        if not (valid(a) and addr(a) == addr(w)) then return false end
      end
      w = p
    else                                                    -- the root of a widget's own tree: on to the widget that owns it
      local t; pcall(function() t = w:GetOuter() end)
      if not (valid(t) and cs(t) == "WidgetTree") then return false end
      local o; pcall(function() o = t:GetOuter() end)
      if not (valid(o) and isA(o, uw)) then return false end   -- a class's template tree ends here
      w = o
    end
  end
  return false
end
-- a screen over the normal view (lane 86 dev4: the key path with the settings screen open walked with the screen
-- still on top): the pause menu (with the screens it opens: Save, Load, Settings, Co-op), a full screen that pauses
-- the engine, a settings screen on screen (the HUD's own or the pause menu's), or the main interface not in its
-- normal state. The HUD's own pause is not one: a walker walks on pause.
function G.busy(S, m)
  local r
  pcall(function() if S.p1:isPauseMenuVisible() then r = "the pause menu is open" end end)
  if r then return r end
  pcall(function() if GS():IsGamePaused(S.p1) then r = "a full screen is open" end end)
  if r then return r end
  -- every settings widget, by what is on screen (FindFirstOf can give one that is not on screen: dev5b walked under
  -- the open screen; IsVisible alone kept the pause menu's closed copy "open": the lead's check above)
  pcall(function()
    for _, q in ipairs(FindAllOf("quickSettings_C") or {}) do
      if valid(q) then
        local on = G.onScreen(q)
        if on == nil then local okV, v = pcall(function() return q:IsVisible() end); on = okV and v == true end
        if on then r = "the settings screen is open"; break end
      end
    end
  end)
  if r then return r end
  pcall(function() local v = m:GetVisibility(); if v ~= 4 then r = "the interface is not in its normal state (" .. tostring(v) .. ")" end end)
  return r
end
-- ---------------------------------------------------------------- (step 8: L27, L28) the walk key's row in the game's Controls screen
-- What the game has (lane 86, game runs on test copy 6, scripts only; report.txt STEP 8): its settings screen
-- (quickSettings_C: the HUD's own, and the pause menu's own copy made by menu_settingsWrapper_C) shows the key rows on
-- its Controls page in bindings_vb, a VerticalBox of InputRow_C placed by hand in the screen's design (no function
-- builds rows from a list), closed by a divider image. A row: an InputRow_C (Label: a translation key; Index 0; its
-- stripe, AlternatingRowBorder, shown on even places and hidden on odd ones) holding the AutoSettings plugin's key
-- widget StyledActionMapping_C for mapping group 0 in Content1 and for group 1 in Content2_1. Ours is made the same way
-- from the same classes, after the last game row and before the divider; the plugin's own key widget shows the key the
-- plugin holds for our action, its own capture button rebinds it, and the plugin saves the choice in the profile.
-- Only ActionName and MappingGroup are written on a key widget. Never ActionLabel: it holds the key widget's own label
-- sub-widget, and a TEXT written there from Lua ended a test copy inside AddChild (11:11:56); the same write alone
-- did it again at the same crash site (15:06:55), while the same build without it lived: report.txt, ROOT CAUSE TEST.
-- Each key widget goes into the row once the row is in the list; nothing is left unparented.
V.ROWLABEL = "Walk (co-op visit mode)"
local ROWCLS = "/Game/UI/Settings/InputRow.InputRow_C"
local MAPCLS = "/Game/UI/StyledAutoSettings/Input/StyledActionMapping.StyledActionMapping_C"
local function nameOf(o) local ok, n = pcall(function() return o:GetFName():ToString() end); return ok and n or "" end
-- the widget that owns w's tree (made by the game); nil for a class's template tree
local function treeOwner(w)
  local uw = StaticFindObject("/Script/UMG.UserWidget"); if not valid(uw) then return nil end
  local t; pcall(function() t = w:GetOuter() end)
  if not (valid(t) and cs(t) == "WidgetTree") then return nil end
  local o; pcall(function() o = t:GetOuter() end)
  if valid(o) then local ok, r = pcall(function() return o:IsA(uw) end); if ok and r == true then return o end end
end
-- the key rows' list of a settings screen
function G.bindings(q)
  local l; pcall(function() l = q.bindings_vb end)
  if valid(l) then return l end
  local page; pcall(function() page = q.settings_controls end)
  if not valid(page) then return nil end
  local n = 0; pcall(function() n = page:GetChildrenCount() end)
  for i = 0, n - 1 do local c; pcall(function() c = page:GetChildAt(i) end); if valid(c) and nameOf(c) == "bindings_vb" then return c end end
end
-- our row in a list (the InputRow_C with our label), its place, the list's length
function G.ourRow(list)
  local n = 0; pcall(function() n = list:GetChildrenCount() end)
  for i = n - 1, 0, -1 do
    local c; pcall(function() c = list:GetChildAt(i) end)
    if valid(c) and cs(c) == "InputRow_C" then local ok, l = pcall(function() return c.Label:ToString() end); if ok and l == V.ROWLABEL then return c, i, n end end
  end
  return nil, nil, n
end
-- player 0's controller, also at the title screen and in a solo game (no lord pawn there: the game instance's world)
function G.pcAny(S)
  local pc; pcall(function() pc = G.pc(S) end)
  if valid(pc) then return pc end
  pcall(function() pc = GS():GetPlayerController(FindFirstOf("MLGameInstance"), 0) end)
  if valid(pc) then return pc end
end
function G.addRow(S, q, list)
  local pc = G.pcAny(S); if not pc then return "no player controller" end
  local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
  local rowCls, mapCls = StaticFindObject(ROWCLS), StaticFindObject(MAPCLS)
  if not (valid(WBL) and valid(rowCls) and valid(mapCls)) then return "the game's row classes were not found" end
  local n = list:GetChildrenCount()
  local model, mi
  for i = n - 1, 0, -1 do local c; pcall(function() c = list:GetChildAt(i) end); if valid(c) and cs(c) == "InputRow_C" then model, mi = c, i; break end end
  if not model then return "no game row in the list" end
  -- the divider after the last game row: out, and back after our row, with its own slot values
  local tail, tv
  if mi == n - 2 then
    local c; pcall(function() c = list:GetChildAt(n - 1) end)
    if valid(c) then
      tail = c
      pcall(function() local s = c.Slot; local P, Z = s.Padding, s.Size; tv = { P = { Left = P.Left, Top = P.Top, Right = P.Right, Bottom = P.Bottom }, H = s.HorizontalAlignment, V = s.VerticalAlignment, Z = { Value = Z.Value, SizeRule = Z.SizeRule } } end)
    end
  end
  local mv; pcall(function() local s = model.Slot; local P, Z = s.Padding, s.Size; mv = { P = { Left = P.Left, Top = P.Top, Right = P.Right, Bottom = P.Bottom }, H = s.HorizontalAlignment, V = s.VerticalAlignment, Z = { Value = Z.Value, SizeRule = Z.SizeRule } } end)
  local function slotLike(s, v) if valid(s) and v then pcall(function() s:SetPadding(v.P) end); pcall(function() s:SetHorizontalAlignment(v.H) end); pcall(function() s:SetVerticalAlignment(v.V) end); pcall(function() s:SetSize(v.Z) end) end end
  local row = WBL:Create(q, rowCls, pc)
  if not valid(row) then return "row not made" end
  pcall(function() row.Label = StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):Conv_StringToText(V.ROWLABEL) end)
  pcall(function() row.Index = model.Index end)
  pcall(function() row:SetVisibility(model:GetVisibility()) end)      -- the game's rows are Visible (0); the class's own is 4
  local okA, s1 = pcall(function() return list:AddChild(row) end)
  if not okA then return "row not added: " .. tostring(s1) end
  slotLike(s1, mv)
  -- the divider moved back to the end, after our row (only once our row is in)
  if tail and pcall(function() list:RemoveChild(tail) end) then local okT, s2 = pcall(function() return list:AddChild(tail) end); slotLike(okT and s2 or nil, tv) end
  local _, at = G.ourRow(list)
  if at then pcall(function() row.AlternatingRowBorder:SetVisibility((at % 2 == 0) and 0 or 2) end) end
  local put = 0
  for _, sg in ipairs({ { "Content1", 0 }, { "Content2_1", 1 } }) do
    local sw; pcall(function() sw = row[sg[1]] end)
    if valid(sw) then
      local w = WBL:Create(q, mapCls, pc)
      if valid(w) then
        w.ActionName = FName(V.ACTION)
        pcall(function() w.MappingGroup = sg[2] end)
        if pcall(function() sw:SetContent(w) end) then
          local back; pcall(function() back = sw:GetContent() end)
          if valid(back) and addr(back) == addr(w) then put = put + 1 end
        end
      end
    end
  end
  -- a row without both key widgets is not a game row: out again, and it counts as a refusal
  if put < 2 then pcall(function() list:RemoveChild(row) end); return string.format("row taken out again: %d of 2 key widgets", put) end
  return string.format("added at %s of %d, 2 key widgets", tostring(at), list:GetChildrenCount())
end
-- every live settings screen (the HUD's, the pause menu's) gets our row once. A list that refused it twice is left
-- alone (V.rowFails, by the list's address; cleared with every new world: a join or a load makes new screens, and an
-- address can be used again). V.rowsAdded counts the rows added since the last world.
V.rowFails = V.rowFails or {}
V.rowsAdded = V.rowsAdded or 0
function G.rows(S)
  local made = 0
  local qs = FindAllOf("quickSettings_C") or {}
  -- a different set of settings screens (a new world, the title screen, a solo game: also in the idle step, where no
  -- world event comes) clears the refusals
  local sigT = {}
  for _, q in ipairs(qs) do local a = valid(q) and addr(q); if a then sigT[#sigT + 1] = tostring(a) end end
  table.sort(sigT); local sig = table.concat(sigT, ",")
  if sig ~= V.rowSig then V.rowSig = sig; V.rowFails = {} end
  for _, q in ipairs(qs) do
    local owner = valid(q) and treeOwner(q)
    if owner then
      local list = G.bindings(q)
      local la = list and addr(list)
      if la and (V.rowFails[la] or 0) < 2 and not G.ourRow(list) then
        local ok, r = pcall(G.addRow, S, q, list)
        local good = ok and type(r) == "string" and r:find("^added") ~= nil and G.ourRow(list) ~= nil
        if good then V.rowsAdded = V.rowsAdded + 1 else V.rowFails[la] = (V.rowFails[la] or 0) + 1 end
        say("our row in the Controls screen of %s: %s", cs(owner), tostring(ok and r or ("error " .. tostring(r))))
        made = made + 1
      end
    end
  end
  return made
end
-- the save's lord body (host): 1 when the game's walker body is the lady's
-- (read from the walker's own mesh: the game's getLordVisitModeSkeletalMesh gives a soft pointer Lua cannot read)
function G.hostBody(S, w)
  local ok, n = pcall(function() return w.Mesh.SkeletalMesh:GetFName():ToString() end)
  if ok and type(n) == "string" and n:find("Lady") then return 1 end
  return 0
end

-- The ground under the camera: a line trace down; only the hit's height is read (no component, no actor).
-- Buildings do not stop the walker (lane 86, dev2: no trace channel hits the storehouse, and a walker put inside it
-- walked out, 337 cm in 3 s), so the place under the camera is always taken; with no hit there (off the map's
-- ground), the nearest point with ground in rings of cfg.ring cm.
local function traceDown(ctx, x, y, z0, z1, ignore)
  local hit = {}
  local ok, r = pcall(function() return KSL():LineTraceSingle(ctx, { X = x, Y = y, Z = z0 }, { X = x, Y = y, Z = z1 }, 0, false, ignore, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0) end)
  if not (ok and r) then return nil end
  local z; pcall(function() z = hit.ImpactPoint.Z end)
  if not z then pcall(function() z = hit.Location.Z end) end
  return z
end
function G.ground(ctx, x, y, zc, ignore) return traceDown(ctx, x, y, (zc or 0) + 100000, (zc or 0) - 100000, ignore) end
function G.freeGround(S, ctx, x, y, zc, ignore)
  local z = G.ground(ctx, x, y, zc, ignore); if z then return x, y, z, 0 end
  for k = 1, V.cfg.rings do
    local r = k * V.cfg.ring; local n = 8 * k
    for i = 0, n - 1 do
      local a = 2 * math.pi * i / n
      local px, py = x + r * math.cos(a), y + r * math.sin(a)
      z = G.ground(ctx, px, py, zc, ignore); if z then return px, py, z, k end
    end
  end
  return nil
end
-- (the lead's real-input check 1, 2026-11-20: over a cattle pen the walker started inside the pen's fence twice, the
-- view pressed against the fence) A place under the camera whose view is blocked is moved to the nearest open ground
-- (a nudge, not a refusal). The walker walks through buildings and fences (dev2) and the camera does not collide with
-- them, so this is about the view only. Measured (s8d, the save's own camera start 93780,-80876, the lead's pen): the
-- walker's camera stands 300 cm behind it along the control rotation's yaw and 55 cm above the walker (about 135 cm
-- above the ground), and a trace of the camera's type (1) from the walker's head to the camera met the fence at
-- 226 cm; the camera's trace type sees buildings and fences (a stable at 0 in all 8 directions from its middle), the
-- other trace types do not. Blocked view = that head-to-camera line (cfg.camBack cm back) hits, or cfg.nudgeDirs of 8
-- directions are blocked within cfg.nudgeNear cm (inside a building). Open = a clear head-to-camera line and nothing
-- within cfg.nudgeNear cm. Rings of cfg.nudgeStep cm, 8 places each, up to cfg.nudgeRings rings; none open: it stays.
local function blockedDirs(ctx, x, y, z, reach, ignore)
  local n = 0
  for k = 0, 7 do
    local a = k * math.pi / 4
    local hit = {}
    local ok, r = pcall(function() return KSL():LineTraceSingle(ctx, { X = x, Y = y, Z = z + 100 }, { X = x + reach * math.cos(a), Y = y + reach * math.sin(a), Z = z + 100 }, 1, false, ignore, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0) end)
    if ok and r == true then n = n + 1 end
  end
  return n
end
G.blockedDirs = blockedDirs
-- the head-to-camera line of a walker standing on the ground at x, y, z, its camera looking along yaw (degrees)
local function viewBlocked(ctx, x, y, z, yaw, ignore)
  local a = math.rad((yaw or 0) + 180)
  local hit = {}
  local ok, r = pcall(function() return KSL():LineTraceSingle(ctx, { X = x, Y = y, Z = z + 140 }, { X = x + V.cfg.camBack * math.cos(a), Y = y + V.cfg.camBack * math.sin(a), Z = z + 135 }, 1, false, ignore, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0) end)
  return ok and r == true
end
G.viewBlocked = viewBlocked
function G.openGround(S, ctx, x, y, z, ignore, yaw)
  if not V.cfg.nudge then return x, y, z, 0 end
  if not viewBlocked(ctx, x, y, z, yaw, ignore) and blockedDirs(ctx, x, y, z, V.cfg.nudgeNear, ignore) < V.cfg.nudgeDirs then return x, y, z, 0 end
  for k = 1, V.cfg.nudgeRings do
    local r = k * V.cfg.nudgeStep
    for i = 0, 7 do
      local a = 2 * math.pi * i / 8 + (k % 2) * math.pi / 8
      local px, py = x + r * math.cos(a), y + r * math.sin(a)
      local pz = G.ground(ctx, px, py, z, ignore)
      if pz and not viewBlocked(ctx, px, py, pz, yaw, ignore) and blockedDirs(ctx, px, py, pz, V.cfg.nudgeNear, ignore) == 0 then return px, py, pz, r end
    end
  end
  return x, y, z, 0
end

-- a look on a character's mesh: body and colour (the lord: RColorTint / GColorTint on body, cloth and scabbard; the
-- lady: ColorTint on dress and cape). Only the two body meshes are ever loaded.
function G.applyLook(a, look)
  local body, col = math.floor((look or 0) / 10), (look or 0) % 10
  local m; pcall(function() m = LoadAsset(BODY[body] or BODY[0]) end)
  if not valid(m) then return false end
  local okS = pcall(function() a.Mesh:SetSkinnedAssetAndUpdate(m, false) end)
  local c = COLOUR[col]
  if c then
    local c2 = { R = c.R * 0.45, G = c.G * 0.45, B = c.B * 0.45, A = 1 }
    local c1 = { R = c.R, G = c.G, B = c.B, A = 1 }
    if body == 0 then
      for _, i in ipairs({ 0, 1, 6 }) do pcall(function() local mi = a.Mesh:CreateDynamicMaterialInstance(i, nil, FName("None")); mi:SetVectorParameterValue(FName("RColorTint"), c1); mi:SetVectorParameterValue(FName("GColorTint"), c2) end) end
    else
      for _, i in ipairs({ 2, 3, 5, 6 }) do pcall(function() local mi = a.Mesh:CreateDynamicMaterialInstance(i, nil, FName("None")); mi:SetVectorParameterValue(FName("ColorTint"), c1) end) end
    end
  end
  return okS
end

-- a body: the walker's class, no controller (a controller hid the local player's cursor: lane 84), physics without
-- one, the ground only (it does not block walkers or other bodies), a name label
function G.spawnBody(S, who, look, x, y, z, label)
  local cls = StaticFindObject(ALS); if not valid(cls) then return nil, "no walker class" end
  local a
  local ok, e = pcall(function() a = S.p1:GetWorld():SpawnActor(cls, { X = x, Y = y, Z = z + 400 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)   -- above any walker standing there
  if not ok or not valid(a) then return nil, "spawn failed: " .. tostring(e) end
  pcall(function() a:SetActorScale3D({ X = 0.85, Y = 0.85, Z = 0.85 }) end)
  pcall(function() a.CharacterMovement.bRunPhysicsWithNoController = true end)
  pcall(function()
    local cap = a.CapsuleComponent
    for _, ch in ipairs({ 1, 2, 5 }) do cap:SetCollisionResponseToChannel(ch, 0) end     -- WorldDynamic, Pawn, PhysicsBody: ignore
  end)
  pcall(function() a.Mesh:SetCollisionEnabled(0) end)
  pcall(function() a:K2_SetActorLocation({ X = x, Y = y, Z = z + 20 }, false, {}, true) end)   -- then down at its place, through walkers
  G.applyLook(a, look)
  pcall(function()
    local tc = StaticFindObject("/Script/Engine.TextRenderComponent")
    local c = a:AddComponentByClass(tc, false, { Translation = { X = 0, Y = 0, Z = 125 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    c:K2_SetText(FText(label or who)); c:SetTextRenderColor({ R = 255, G = 230, B = 120, A = 255 })
    c:SetWorldSize(28); c:SetHorizontalAlignment(1)
  end)
  return addr(a)
end
-- this tick's walker-class actors by address (the bodies are taken from here, never kept)
function G.actors(S)
  local cls = StaticFindObject(ALS); if not valid(cls) then return {} end
  local out, t = {}, {}
  pcall(function() GS():GetAllActorsOfClass(S.p1, cls, out) end)
  for i = 1, #out do
    local a; pcall(function() a = out[i]:get() end)
    if a == nil then a = out[i] end
    if valid(a) then local ad = addr(a); if ad then t[ad] = a end end
  end
  return t
end
function G.destroy(a) pcall(function() a:K2_DestroyActor() end) end
function G.camera(S)
  local ok, x, y, z = pcall(function() local cm = G.pc(S).PlayerCameraManager; local L = cm:GetCameraLocation(); return L.X, L.Y, L.Z end)
  if ok then return x, y, z end
end
-- move one body one frame toward a target (lane 84's steering: input scaled by the sent pace and the distance)
-- The body takes the walker's gait from its pace (the walker's own: walk 115 cm/s, run 350; lane 86 dev3: a body
-- left in the walk gait trailed a running walker by 2 m and snapped 21 times in 25 s). B.gait: the gait last set.
function G.steer(a, tx, ty, tz, sp, yaw, B)
  local x, y = loc(a)
  local dx, dy = tx - x, ty - y; local d = math.sqrt(dx * dx + dy * dy)
  if d > V.cfg.snap then a:K2_SetActorLocation({ X = tx, Y = ty, Z = tz + 20 }, false, {}, true); return "snap", d end
  local g = 0
  if (sp or 0) > V.cfg.sprintV then g = 2 elseif (sp or 0) > V.cfg.runV or d > 150 then g = 1 end
  if B and B.gait ~= g then B.gait = g; pcall(function() a.DesiredGait = g end) end
  local maxv = V.cfg.walkMax
  pcall(function() maxv = math.max(V.cfg.walkMax, a.CharacterMovement.MaxWalkSpeed) end)
  if d > 20 then
    local scale = math.min(1.0, math.max(0.15, (sp or maxv) / maxv + d / V.cfg.gain))
    if d < 40 and (sp or 0) < 10 then scale = scale * d / 40 end
    a:AddMovementInput({ X = dx / d, Y = dy / d, Z = 0 }, scale, true)
  elseif (sp or 0) < 10 and yaw then a:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false) end
  return nil, d
end
function G.label(a, cx, cy)
  local tc = StaticFindObject("/Script/Engine.TextRenderComponent")
  local c = a:GetComponentByClass(tc)
  if valid(c) and cx then
    local x, y = loc(a)
    c:K2_SetWorldRotation({ Pitch = 0, Yaw = math.deg(atan2(cy - y, cx - x)), Roll = 0 }, false, {}, true)
  end
end
-- the global time dilation (a friend's catch-up scales it 0.5 to 16): walkers and bodies are held at 1 by their own
-- dilation, so the walking pace never follows it
function G.dilation(S) local ok, d = pcall(function() return GS():GetGlobalTimeDilation(S.p1) end); return ok and tonumber(d) or 1.0 end
function G.holdPace(a, gd) if V.cfg.holdPace ~= false and gd and gd > 0 then pcall(function() if math.abs(a.CustomTimeDilation - 1 / gd) > 0.001 then a.CustomTimeDilation = 1 / gd end end) end end

-- the names above the bodies: the player's name when this copy knows it (the Steam list), else "host", "friend 2"
function V.nameOf(S, who)
  local st = rawget(C, "steam")
  if st and st.on and st.status then
    local ok, s = pcall(st.status)
    if ok and s and s.players then
      local slot = who == "host" and 0 or tonumber((who:match("^friend(%d+)$")))
      for _, p in ipairs(s.players) do if p.slot == slot and type(p.name) == "string" and p.name ~= "" then return p.name end end
    end
  end
  if S.display and S.display[who] then return S.display[who] end
  if who == "host" then return "host" end
  return (who:gsub("^friend(%d+)$", "friend %1"))
end

-- ---------------------------------------------------------------- enter and leave
-- Enter: the game's own visitModeOn (no speed change), then the walker on free ground under the camera.
function V.enter(why)
  local S = C.s
  if not (V.wanted and S and S.on and valid(S.p1)) then return "visit mode is off or no world" end
  if C.hold then return "a load is under way" end
  if V.game.walker(S) then return "already walking" end
  local m = V.game.mainUI(); if not m then return "no main interface" end
  local busy = V.game.busy(S, m); if busy then stat(S, "visit_refused"); return "not now: " .. busy end
  local okV, e = pcall(function() m:visitModeOn() end)
  if not okV then return "visitModeOn failed: " .. tostring(e) end
  local w = V.game.walker(S)
  if not w then return "no walker after visitModeOn" end
  V.placeNew(S, w, why or "key")
  return "walking"
end
-- a new walker (ours or the game's Explore button): on the nearest free ground under the camera, the player's look
function V.placeNew(S, w, why)
  local ok, e = pcall(function()
    local L = S.p1:K2_GetActorLocation()
    local x, y, z, ring = V.game.freeGround(S, w, L.X, L.Y, L.Z, { w })
    local moved = 0
    local yaw = 0; pcall(function() yaw = V.game.pc(S):GetControlRotation().Yaw end)
    if x and V.game.openGround then x, y, z, moved = V.game.openGround(S, w, x, y, z, { w }, yaw) end
    if x then
      w:K2_SetActorLocation({ X = x, Y = y, Z = z + 100 }, false, {}, true)
      say("%s: walker on the ground under the camera%s%s (%.0f,%.0f,%.0f)", why, ring > 0 and string.format(" (no ground right under it: %d m away)", ring * V.cfg.ring / 100) or "",
        moved > 0 and string.format(" (moved %d m to open ground: a building or a tight fence there)", math.floor(moved / 100 + 0.5)) or "", x, y, z)
    else
      say("%s: no free ground found near the camera; the walker stays at the game's place", why)
    end
  end)
  if not ok then say("%s: placing the walker failed: %s", why, tostring(e)) end
  if S.role ~= "host" and V.myLook then pcall(V.game.applyLook, w, V.myLook); V.me.lookOn = V.myLook end
  -- (L12) notices while walking: the interface stays on screen but takes no clicks (HitTestInvisible), the cursor stays
  -- hidden; the game puts its own visibility back when the walker leaves
  if V.cfg.showUI then pcall(function() local m = V.game.mainUI(); if m then m:SetVisibility(3) end end) end
  V.me.placedT = os.clock()
  stat(S, "visit_enter")
end
-- Leave: the walker's own leave event (the game's Enter / Escape), then by hand if it is still there
function V.leave(why)
  local S = C.s
  if not (S and valid(S.p1)) then return "no world" end
  local w = V.game.walker(S); if not w then return "not walking" end
  pcall(function() w:InpActEvt_unposses_K2Node_InputActionEvent_2({ KeyName = FName("None") }) end)
  if V.game.walker(S) then
    local pc = V.game.pc(S)
    pcall(function() pc:Possess(S.p1) end)
    pcall(function() local m = V.game.mainUI(); if m then m:SetVisibility(4) end end)
    pcall(function() StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameAndUIEx(pc, nil, 0, false, false); pc.bShowMouseCursor = true end)
    pcall(function() w:K2_DestroyActor() end)
    say("%s: left by hand (the walker's own leave did not end it)", tostring(why))
  else say("%s: left", tostring(why)) end
  stat(S, "visit_leave")
  return V.game.walker(S) and "still walking" or "left"
end
function V.toggle(why) local S = C.s; if S and valid(S.p1) and V.game.walker(S) then return V.leave(why or "key") end; return V.enter(why or "key") end
-- before a load or a resync (coop_join.lua): the walker goes first
function V.beforeLoad() if V.wanted then local S = C.s; if S and valid(S.p1) and V.game.walker(S) then pcall(V.leave, "load") end end end

-- ---------------------------------------------------------------- the key
-- (step 8; L27, L28) our own input action "CoopVisit" in the game's input settings, added at run time WITHOUT the
-- key-map rebuild (a rebuild puts every player's input back to the project defaults for the session: a player's own
-- rebound game keys would stop working until the next start). The game's key system (the AutoSettings plugin) then
-- holds the player's keys for it as for the game's own actions: a first key (mapping group 0; its default is
-- coop.cfg's visit_key) and a second one (group 1, none by default), both shown and rebound in our row of the game's
-- Controls screen (below) and saved by the plugin in the profile (UserSettings.ini). Every 2 s both are read back; the
-- player's choice wins over coop.cfg. A key the player took away (the plugin answers None) is not polled, but only
-- once our action is confirmed in the input settings: without it the plugin answers None for both (it does so before
-- the add), and the coop.cfg key stays. With no answer from the plugin at all the coop.cfg key stays.
V.ACTION = "CoopVisit"
-- our action in the input settings: true when it is there (added now or before); tried again on later calls
function V.ensureAction()
  if V.actionIn then return true end
  local have = false
  pcall(function()
    local IS = StaticFindObject("/Script/Engine.Default__InputSettings")
    local function find() local n = #IS.ActionMappings; for i = 1, n do pcall(function() if IS.ActionMappings[i].ActionName:ToString() == V.ACTION then have = true end end) end end
    find()
    if not have and (V.actionTries or 0) < 5 then
      V.actionTries = (V.actionTries or 0) + 1
      IS:AddActionMapping({ ActionName = FName(V.ACTION), Key = { KeyName = FName(V.key) }, bShift = false, bCtrl = false, bAlt = false, bCmd = false }, false)
      find()
      say("input action %s added with key %s (no key-map rebuild): %s", V.ACTION, V.key, have and "there" or "NOT there")
    end
  end)
  V.actionIn = have
  return have
end
-- MODIFIERS (lane 86 s8g): the plugin's prompt captures chords (capture mode OnReleased: hold Ctrl, press K), the row
-- then shows "CTRL + K" and the game's own actions need the modifier held. UE4SS reads the plugin's packed modifier
-- flags wrongly (all true when one is set), so they are read from the profile file the plugin writes at once:
-- UserSettings.ini, PlayerInputOverrides of the local player (PlayerId="0"), mapping groups in order (group 0, 1).
-- Pure (desk test): the text of the file -> { [group] = { key, shift, ctrl, alt, cmd } } for our action.
function V.parseOverrides(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for line in text:gmatch("[^\r\n]+") do
    if line:match("^%s*PlayerInputOverrides=") and line:find('PlayerId="0"', 1, true) then
      local s0 = line:find("MappingGroups=(", 1, true)
      if s0 then
        local depth, g, gs = 0, -1, nil
        for p = s0 + #"MappingGroups=", #line do
          local ch = line:sub(p, p)
          if ch == "(" then
            depth = depth + 1
            if depth == 2 then g = g + 1; gs = p end
          elseif ch == ")" then
            if depth == 2 and gs then
              for e in line:sub(gs, p):gmatch('%(ActionName="' .. V.ACTION .. '"([^()]*)%)') do
                local key = e:match("Key=([^,%)]+)")
                if key then out[g] = { key = key, shift = e:find("bShift=True", 1, true) ~= nil, ctrl = e:find("bCtrl=True", 1, true) ~= nil, alt = e:find("bAlt=True", 1, true) ~= nil, cmd = e:find("bCmd=True", 1, true) ~= nil } end
              end
            end
            depth = depth - 1
            if depth <= 0 then break end
          end
        end
      end
    end
  end
  return out
end
-- the text of the profile's UserSettings.ini (the game's own saved folder: also the test profiles' Saved_<suffix>)
function G.profileText()
  local dir
  pcall(function() local v = KSL():GetProjectSavedDirectory(); dir = type(v) == "string" and v or v:ToString() end)
  if type(dir) ~= "string" or dir == "" then return nil end
  local f = io.open(dir .. "Config/Windows/UserSettings.ini", "r")
  if not f then return nil end
  local t = f:read("*a"); f:close()
  return t
end
local MODKEYS = { shift = { "LeftShift", "RightShift" }, ctrl = { "LeftControl", "RightControl" }, alt = { "LeftAlt", "RightAlt" }, cmd = { "LeftCommand", "RightCommand" } }
local MODWORD = { { "ctrl", "Ctrl" }, { "shift", "Shift" }, { "alt", "Alt" }, { "cmd", "Cmd" } }
local function actionKey(S, pc)
  if os.clock() - (V.akT or -10) < 2.0 then return end
  V.akT = os.clock()
  local inSettings = V.ensureAction()
  local M = StaticFindObject("/Script/AutoSettingsInput.Default__InputMappingManager")
  if not valid(M) then return end
  local binds, answered = {}, false
  local ov
  for _, grp in ipairs({ 0, 1 }) do
    local ok, k = pcall(function() return M:GetPlayerActionMappingStatic(pc, FName(V.ACTION), grp).Key.KeyName:ToString() end)
    if ok and type(k) == "string" then
      answered = true
      if k ~= "" and k ~= "None" then
        if ov == nil then local okP, t = pcall(V.game.profileText or G.profileText); ov = V.parseOverrides(okP and t or nil) end
        local o = ov[grp]
        binds[#binds + 1] = { key = k, mods = (o and o.key == k) and { shift = o.shift, ctrl = o.ctrl, alt = o.alt, cmd = o.cmd } or {} }
      end
    end
  end
  if not answered then return end
  local fromCfg = false
  if #binds == 0 and not inSettings then binds = { { key = V.key, mods = {} } }; fromCfg = true end      -- not our action's None: the coop.cfg key stays
  V.keyFromCfg = fromCfg
  local words = {}
  for i, b in ipairs(binds) do
    local w = {}
    for _, m in ipairs(MODWORD) do if b.mods[m[1]] then w[#w + 1] = m[2] end end
    w[#w + 1] = b.key; words[i] = table.concat(w, "+")
  end
  local sig = table.concat(words, ", ")
  if sig ~= V.keyFrom then
    say("the game's key setting for %s: %s (was %s)", V.ACTION, sig ~= "" and sig or "no key", tostring(V.keyFrom or V.key))
    V.keyFrom = sig; V.keyNames = {}; V.keyMods = {}
    for i, b in ipairs(binds) do V.keyNames[i] = FName(b.key); V.keyMods[i] = b.mods end
  end
end
-- the modifiers a binding needs are held (either side); a modifier it does not name does not matter (as the engine's
-- own action keys: a binding without Ctrl also fires with Ctrl held)
local function modsHeld(pc, mods)
  for m, names in pairs(MODKEYS) do
    if mods and mods[m] then
      local down = false
      for _, n in ipairs(names) do local ok, r = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(n) }) end); if ok and r == true then down = true end end
      if not down then return false end
    end
  end
  return true
end
local function keyPressed(S)
  local pc = V.game.pc(S); if not pc then return false end
  if V.cfg.gameKeys then pcall(actionKey, S, pc) end
  V.keyNames = V.keyNames or { FName(V.key) }
  for i, kn in ipairs(V.keyNames) do
    local ok, r = pcall(function() return pc:WasInputKeyJustPressed({ KeyName = kn }) end)
    if ok and r == true and modsHeld(pc, V.keyMods and V.keyMods[i]) then return true end
  end
  return false
end
-- a text box with the keyboard focus (chat, a name field): the key is the box's
local function typing()
  for _, cls in ipairs({ "EditableTextBox", "EditableText", "MultiLineEditableTextBox" }) do
    for _, b in ipairs(FindAllOf(cls) or {}) do
      if valid(b) then local ok, f = pcall(function() return b:HasKeyboardFocus() end); if ok and f then return true end end
    end
  end
  return false
end

-- ---------------------------------------------------------------- bodies
local function sampleAt(B, t)
  local s = B.samples; local n = #s
  if n == 0 then return nil end
  local s1, s2
  for i = n, 1, -1 do if s[i].t <= t then s1 = s[i]; s2 = s[i + 1]; break end end
  if not s1 then s1 = s[1]; return s1.x, s1.y, s1.z, s1.v, s1.yaw end
  if s2 then
    local f = (t - s1.t) / math.max(0.001, s2.t - s1.t)
    return s1.x + (s2.x - s1.x) * f, s1.y + (s2.y - s1.y) * f, s1.z + (s2.z - s1.z) * f, s2.v, s2.yaw
  end
  local s0 = s[n - 1]; local ex = math.min(0.3, t - s1.t)
  if s0 and s1.t > s0.t and s1.v > V.cfg.standV then
    return s1.x + (s1.x - s0.x) / (s1.t - s0.t) * ex, s1.y + (s1.y - s0.y) / (s1.t - s0.t) * ex, s1.z, s1.v, s1.yaw
  end
  return s1.x, s1.y, s1.z, s1.v, s1.yaw
end
V.sampleAt = sampleAt
-- a sample for who's body (t: this copy's clock)
function V.feed(who, look, t, x, y, z, yaw, v)
  local B = V.B[who]
  if not B then B = { samples = {}, look = look, tele = 0, vanished = 0 }; V.B[who] = B end
  B.gone = nil
  if B.look ~= look then B.look = look; B.relook = true end
  local s = B.samples
  if #s > 0 and t <= s[#s].t then return end
  s[#s + 1] = { t = t, x = x, y = y, z = z, yaw = yaw, v = v }
  while #s > 10 do table.remove(s, 1) end
  B.lastT = A.now()
end
function V.drop(who, why)
  local B = V.B[who]; if not B then return end
  B.gone = why or "off"
end
local function drawBodies(S, t, gd)
  local any = false
  for _ in pairs(V.B) do any = true; break end
  if not any then return end
  local list = V.game.actors(S)
  local me = V.game.walker(S); local meA = me and addr(me)
  local cx, cy = V.game.camera(S)
  for who, B in pairs(V.B) do
    local a = B.addr and list[B.addr]
    if a and B.addr == meA then a = nil end
    if B.gone or (B.lastT and t - B.lastT > V.cfg.silence) then
      if a then V.game.destroy(a) end
      say("body of %s removed (%s)", who, B.gone or "silent 10 s"); stat(S, "visit_bodyGone")
      V.B[who] = nil
    else
      local x, y, z, v, yaw = sampleAt(B, t - V.cfg.delay)
      if x then
        if B.addr and not a then B.vanished = B.vanished + 1; B.addr = nil; stat(S, "visit_bodyVanished") end
        if not B.addr then
          local ad, e = V.game.spawnBody(S, who, B.look, x, y, z, V.nameOf(S, who))
          B.addr = ad; B.relook = false
          if ad then say("body of %s made (look %d)", who, B.look); stat(S, "visit_bodyMade") else say("body of %s: %s", who, tostring(e)) end
        elseif a then
          if B.relook then V.game.applyLook(a, B.look); B.relook = false end
          local ok, r, d = pcall(V.game.steer, a, x, y, z, v, yaw, B)
          if ok and r == "snap" then B.tele = B.tele + 1; stat(S, "visit_snap"); say("body of %s snapped %.0f cm (dilation %.2f)", who, d or 0, gd or 1) end
          pcall(V.game.holdPace, a, gd)
          pcall(V.game.label, a, cx, cy)
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- the host's table and its lines
function V.hostSet(who, e, t)
  local W = V.W[who]
  if not W then W = {}; V.W[who] = W end
  W.look = V.lookFor(who)
  if e.on then W.on = true; W.x, W.y, W.z, W.yaw, W.v = e.x, e.y, e.z, e.yaw, e.v; W.t = t
  else if W.on then W.on = false end end
  W.dirty = true
end
function V.hostEntries(all, t, known)
  local out = {}
  local seen = {}
  local function add(who, W)
    seen[who] = true
    if W and W.on then out[#out + 1] = V.encEntry({ who = who, look = W.look or V.lookFor(who), on = true, age = math.max(0, t - (W.t or t)), x = W.x, y = W.y, z = W.z, yaw = W.yaw, v = W.v })
    else out[#out + 1] = V.encEntry({ who = who, look = V.lookFor(who), on = false }) end
  end
  local names = {}
  for who in pairs(V.W) do names[#names + 1] = who end
  table.sort(names)
  for _, who in ipairs(names) do local W = V.W[who]; if all or W.dirty then add(who, W) end; W.dirty = false end
  if all then for _, who in ipairs(known or {}) do if not seen[who] then add(who, nil) end end end
  return out
end
local function hostLines(S, t)
  if t - V.hT >= V.cfg.hostEvery * 0.9 then
    V.hT = t
    local dirty = false
    for _, W in pairs(V.W) do if W.dirty then dirty = true; break end end
    if dirty and t - V.fT < V.cfg.fullEvery then local e = V.hostEntries(false, t); if #e > 0 then send("VH " .. table.concat(e, " ")) end end
  end
  -- the full list every second while anybody walks (and 5 s after the last one stopped); with nobody walking only
  -- every cfg.idleFullEvery s, for the looks (lane 86, l86m0: nobody walking should cost the session next to nothing)
  local anyOn = false
  for _, W in pairs(V.W) do if W.on then anyOn = true; break end end
  if anyOn then V.lastOnT = t end
  local every = (anyOn or t - (V.lastOnT or -1e9) < 5.0) and V.cfg.fullEvery or V.cfg.idleFullEvery
  if t - V.fT >= every then
    V.fT = t
    local known = { "host" }
    for _, p in ipairs(S.peers or {}) do if S.heard and S.heard[p] and os.clock() - S.heard[p] < 30 then known[#known + 1] = p end end
    send("VF " .. table.concat(V.hostEntries(true, t, known), " "))
  end
end

-- ---------------------------------------------------------------- tick
local function ownWalker(S, t, gd)
  local w = V.game.walker(S)
  local me = V.me
  if w then
    if not me.was then
      me.was = true; me.sendT = -1e9
      if os.clock() - (me.placedT or -10) > 2.0 then V.placeNew(S, w, "the game's Explore") end
      if S.role == "host" then V.hostLook = V.game.hostBody(S, w) * 10 end     -- a look: body * 10, no colour
    end
    if S.role ~= "host" and V.myLook and me.lookOn ~= V.myLook then pcall(V.game.applyLook, w, V.myLook); me.lookOn = V.myLook end
    pcall(V.game.holdPace, w, gd)
    local x, y, z, yaw, v = V.game.sample(w)
    local moving = v > V.cfg.standV or (me.x and (math.abs(x - me.x) > 5 or math.abs(y - me.y) > 5 or math.abs(((yaw - me.yaw) + 540) % 360 - 180) > 3))
    if t - me.sendT >= (moving and V.cfg.moveEvery or V.cfg.standEvery) * 0.9 then   -- (a frame early rather than one late)
      me.sendT = t; me.x, me.y, me.yaw = x, y, yaw
      if S.role == "host" then V.hostSet("host", { on = true, x = x, y = y, z = z, yaw = yaw, v = v }, t)
      else send(V.encOwn(true, x, y, z, yaw, v)) end
    end
  elseif me.was then
    me.was = false; me.lookOn = nil
    if S.role == "host" then V.hostSet("host", { on = false }, t) else send("VW 0") end
    say("walker gone: back in the normal view")
  end
end

local function tick(S, clock)
  if not V.wanted then return end
  if not (S.on and valid(S.p1)) then return end
  local c0 = os.clock()
  local t = A.now()
  local gd = V.game.dilation(S)
  if keyPressed(S) then
    if typing() then stat(S, "visit_keyInText")
    else local ok, r = pcall(V.toggle, "key"); say("key %s: %s", tostring(V.keyFrom or V.key), tostring(ok and r or ("error " .. tostring(r)))) end
  end
  -- (step 8) our row in every live settings screen, looked after every cfg.rowEvery s, and every 0.25 s for 3 s after
  -- the pause menu opened (its screens are made then, partly after a load of their classes: the row is in before a
  -- player can reach its Controls tab)
  local Fo = rawget(C, "focus"); local lo = Fo and type(Fo.last) == "table" and Fo.last.openMenu
  if lo and lo ~= V.rowOpenSeen then V.rowOpenSeen = lo; V.rowBurst = os.clock() + 3.0 end
  local every = (V.rowBurst and os.clock() < V.rowBurst) and 0.25 or V.cfg.rowEvery
  if V.cfg.row and V.game.rows and os.clock() - (V.rowT or -1e9) >= every then V.rowT = os.clock(); pcall(V.game.rows, S) end
  ownWalker(S, t, gd)
  if S.role == "host" then
    for who, W in pairs(V.W) do
      if who ~= "host" and W.on and t - (W.t or t) > V.cfg.silence then W.on = false; W.dirty = true; say("walker of %s silent 10 s: removed", who) end
    end
    for who, W in pairs(V.W) do
      if who ~= "host" then if W.on then V.feed(who, W.look, W.t, W.x, W.y, W.z, W.yaw, W.v) elseif V.B[who] then V.drop(who, "off") end end
    end
    hostLines(S, t)
  end
  drawBodies(S, t, gd)
  local ms = (os.clock() - c0) * 1000
  if next(V.B) or V.me.was then local K = V.cost; K.n = K.n + 1; K.ms = K.ms + ms; if ms > K.max then K.max = ms end end
end

-- a line older than cfg.old on the sender's clock is history (a join's replay): it moves nothing
local function onMessage(S, from, kind, w, line)
  if kind ~= "VW" and kind ~= "VH" and kind ~= "VF" then return false end
  if not V.wanted then return true end
  -- a resync's replay (coop.lua S.replay: the host's lines since the save, read again in order) is history: the
  -- host's next lines say where everybody walks now
  if S.replay then stat(S, "visit_replayLine"); return true end
  local t = A.now()
  local lt = tonumber(w[2]); if not lt then return true end
  V.off[from] = V.offFeed(V.off[from], t - lt)
  local age = t - lt - V.off[from]
  if C.men and C.men.hostClock and from == "host" then
    local hc, known = C.men.hostClock(); if known then age = hc - lt end
  end
  if age > V.cfg.old then stat(S, "visit_oldLine"); return true end
  if kind == "VW" then
    if S.role ~= "host" then return true end
    local e = V.decOwn(w); if not e then stat(S, "visit_badLine"); return true end
    V.hostSet(from, e, lt + V.off[from])                         -- by the sender, on the host's clock
    return true
  end
  if S.role == "host" or from ~= "host" then return true end
  local seen = {}
  for _, e in ipairs(V.decList(w)) do
    seen[e.who] = true
    if e.who == S.name then
      V.myLook = e.look
      if not e.on and V.me.was and kind == "VF" then V.me.sendT = -1e9 end   -- the host does not know we walk: send our place again
      if e.on and not V.me.was and kind == "VF" then send("VW 0") end      -- the host thinks we walk: say again that we do not
    elseif e.on then V.feed(e.who, e.look, lt - e.age + V.off[from], e.x, e.y, e.z, e.yaw, e.v)
    else V.drop(e.who, "off") end
  end
  if kind == "VF" then for who in pairs(V.B) do if not seen[who] then V.drop(who, "not in the host's list") end end end
  return true
end

local function onWorld(S)
  V.B = {}                                                   -- the bodies went with the old world
  V.me.lookOn = nil
  V.hostLook = nil
  if S and S.role == "host" then for who, W in pairs(V.W) do if W.on and who == "host" then W.on = false; W.dirty = true end end end
  V.rowFails = {}; V.rowsAdded = 0; V.rowT = nil                -- new screens come with the new world: look again at once
end

function V.status()
  local S = C.s
  local o = { "visit " .. (V.wanted and "on" or "OFF (coop.cfg visit = off)") .. ", key " .. tostring(V.keyFrom or V.key) .. ((V.keyFrom and not V.keyFromCfg) and " (the game's key setting)" or " (coop.cfg)") }
  local nf = 0; for _ in pairs(V.rowFails or {}) do nf = nf + 1 end
  o[#o + 1] = "our row added to " .. tostring(V.rowsAdded or 0) .. " Controls list(s) in this world" .. (nf > 0 and (", refused by " .. nf) or "")
  pcall(function() o[#o + 1] = (V.game.walker(S) and "walking" or "normal view") end)
  if V.myLook then o[#o + 1] = "my look " .. V.myLook end
  local b = {}
  for who, B in pairs(V.B) do b[#b + 1] = string.format("%s(look %d, %s, snaps %d, vanished %d)", who, B.look or -1, B.addr and "drawn" or "not drawn", B.tele, B.vanished) end
  o[#o + 1] = "bodies: " .. (#b > 0 and table.concat(b, " ") or "none")
  if S and S.role == "host" then
    local h = {}
    for who, W in pairs(V.W) do h[#h + 1] = who .. (W.on and " walks" or " -") .. " look " .. tostring(W.look) end
    o[#o + 1] = "host table: " .. table.concat(h, ", ")
  end
  local K = V.cost
  o[#o + 1] = string.format("cost %.3f ms avg, %.3f max (%d ticks)", K.n > 0 and K.ms / K.n or 0, K.max, K.n)
  return table.concat(o, " | ")
end

-- (step 8) the title screen and a solo game (the core's "idle" step): no walking there (visit mode is for co-op
-- games), but the game's Controls screen is the same one, and a player sets keys there too (before hosting): our action
-- and our row are put in the same way, so the row is in every Controls screen the game shows.
local function idle(S, clock)
  if not (V.wanted and V.cfg.row and V.game.rows) then return end
  if os.clock() - (V.rowT or -1e9) < V.cfg.rowEvery then return end
  V.rowT = os.clock()
  pcall(V.ensureAction)
  pcall(V.game.rows, S)
end
if V.wanted then C.register("visit", { tick = tick, onMessage = onMessage, onWorld = onWorld, idle = idle }) end
V.tickFn, V.msgFn, V.worldFn = tick, onMessage, onWorld        -- (desk test)
V.realGame = G                                                 -- (desk test: the game side's own checks, onScreen and busy)
V.keyFn = keyPressed                                           -- (desk test: the key read back from the game's key system)
return "coop visit module loaded (" .. (V.wanted and ("on, key " .. V.key) or "off: coop.cfg has visit = off") .. ")"
