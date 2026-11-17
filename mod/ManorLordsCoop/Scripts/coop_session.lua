-- Manor Lords Co-op: the host is gone -> every friend goes back to the main menu (plug-in module "session", lane 44).
-- The owner (2026-11-13): "if the host disconnects -> route everyone to main menu". Only the host's save counts, so a
-- friend never plays on alone. A friend decides "the host is gone" when
--   (a) the host said goodbye: "BYE <why>" in the host's line file. The host sends it when its player uses the
--       pause menu's "Main Menu" or "Quit Game" button (both hooked here, the line is written inside the hook), and
--       whenever the host's copy sits at the title screen after it had a world (any other way back to the menu);
--   (b) nothing at all came from the host for SILENCE seconds (wall clock). A running or paused host sends its state
--       line four times a second (coop.lua hostSnapshot, also while paused or behind a full screen); a host that loads
--       a world says "HL" first (hook on the engine's OpenLevel) and every 3 s while it has no world, and the friend
--       then waits LOAD_SILENCE seconds instead. A friend that lost its own link to a living host goes the same way;
--   (c) the Steam link says this friend is no longer in the host's lobby (coop_ui.lua roleTick calls P.gone).
-- Then, at once: the notice, the job gate closed (list emptied, byte off), Steam told, the role idle (the link file
-- closed, ALLOFF to the native piece); this copy's saves stay blocked until it is at the title screen. After EXIT_AFTER
-- seconds the engine's OpenLevel to the title level: the call the pause menu's "Main Menu" button makes
-- (mainMenu_widget_C, BndEvt ... menuButton_mainMenu: closeLevel, then GameplayStatics:OpenLevel; read in the game's
-- blueprint bytes, lane 44 report). Never a process kill, never a save.
-- Coop.session.cfg.silence etc. may be changed from the development channel; nothing here can be switched off.

local C = _G.Coop; local A = C.api
C.session = C.session or {}
local P = C.session
P.cfg = P.cfg or {}
for k, v in pairs({
  silence = 30.0,        -- s of silence from the host that cannot be a pause, a hitch or a load (lane 44 report: measured gaps)
  loadSilence = 120.0,   -- s, after the host said "HL" (it loads a world)
  loadWindow = 150.0,    -- s an "HL" counts for
  exitAfter = 5.0,       -- s between the notice and the way back to the main menu
  bannerEvery = 2.5,     -- s between two showings of the notice while it waits
  hostBeat = 3.0,        -- s between two "HL" lines of a host without a world
}) do if P.cfg[k] == nil then P.cfg[k] = v end end
local TITLE = "MainMenu"                     -- the title screen's level (logged by coop_ui: "title screen level is MainMenu")
local TEXT_BYE = "The host left the game. Returning to the main menu."
local TEXT_SILENT = "The host left the game (no answer for %d s). Returning to the main menu."
local TEXT_MENU = "Co-op: the host left the game"
local MENU = "/Game/UI/Main_Menu/mainMenu_widget.mainMenu_widget_C:BndEvt__mainMenu_widget_menuButton_"
local H_MAIN = MENU .. "mainMenu_K2Node_ComponentBoundEvent_19_OnClicked__DelegateSignature"
local H_QUIT = MENU .. "quit_K2Node_ComponentBoundEvent_24_OnClicked__DelegateSignature"

local function log(fmt, ...) A.log("session: " .. fmt, ...) end
local function valid(o) return A.valid(o) end
local function GS() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
local function levelName()
  local n = nil
  pcall(function() n = GS():GetCurrentLevelName(FindFirstOf("MLGameInstance"), true):ToString() end)
  return n
end
local function noWorld() local e = FindFirstOf("RTSMultiEngineCPP"); return not (e and e:IsValid()) end
local function titleLevel() return (C.ui and C.ui.titleMap) or TITLE end

-- ---------------------------------------------------------------- hooks (callbacks write one line or blank a save)
local function hostSays(line)
  local S = rawget(_G, "Coop") and _G.Coop.s
  if S and S.on and S.role == "host" then pcall(_G.Coop.api.send, line); return true end
  return false
end
-- (lane 51) a friend leaving through the same buttons says goodbye too: the host then tells "left the game" at once
-- (without it, the host waits Coop.leftSilence s of silence)
local function friendSays(line)
  local S = rawget(_G, "Coop") and _G.Coop.s
  if S and S.on and S.role == "friend" then pcall(_G.Coop.api.send, line) end
end
local function ensureHooks()
  local H = rawget(_G, "__coop_session_hooks"); if not H then H = {}; _G.__coop_session_hooks = H end
  if H.done or (H.t and os.clock() - H.t < 2.0) then return end
  H.t = os.clock()
  local function reg(key, path, fn) if not H[key] then local ok = pcall(RegisterHook, path, fn); if ok then H[key] = true end end end
  -- the host's player leaves to the menu or quits with the game's own buttons: the goodbye is written at once (after
  -- "Quit Game" this copy gets no further tick)
  reg("main", H_MAIN, function() if hostSays("BYE menu") then local Pp = _G.Coop.session; Pp.byeSent = true else friendSays("BYE menu") end end)
  reg("quit", H_QUIT, function() if hostSays("BYE quit") then local Pp = _G.Coop.session; Pp.byeSent = true else friendSays("BYE quit") end end)
  -- every world change goes through the engine's OpenLevel (the game's load screen, the join, the title button):
  -- the host says "loading" before its game thread stops for the load
  reg("open", "/Script/Engine.GameplayStatics:OpenLevel", function() hostSays("HL") end)
  -- a friend that is leaving writes no save (the role is idle by then, so the join module's block no longer applies)
  reg("save", "/Script/ManorLords.PawnCPP:requestSaveFile", function(self, slot)
    local Pp = rawget(_G, "Coop") and _G.Coop.session
    if Pp and Pp.leaving then pcall(function() slot:set("") end); Pp.blocked = (Pp.blocked or 0) + 1 end
    if rawget(_G, "Coop") then _G.Coop.saveT = os.clock() end          -- (lane 51) the watchdog's "a save ran"
  end)
  reg("thumb", "/Script/ManorLords.MLGameInstance:ExportSaveThumbnailRT", function(self, wc, rt, nameP)
    local Pp = rawget(_G, "Coop") and _G.Coop.session
    if Pp and Pp.leaving then pcall(function() nameP:set("") end) end
  end)
  if H.main and H.quit and H.open and H.save and H.thumb then H.done = true; log("hooks registered (menu, quit, OpenLevel, save block)")
  else
    H.tries = (H.tries or 0) + 1
    if H.tries == 30 then log("hooks still missing after 60 s (tried again every 2 s): main %s quit %s open %s save %s thumb %s", tostring(H.main), tostring(H.quit), tostring(H.open), tostring(H.save), tostring(H.thumb)) end
  end
end

-- ---------------------------------------------------------------- friend: the host's lines (called from coop.lua)
function P.line(S, w)
  if S.role ~= "friend" then return end
  local wall = tonumber(w[2])
  if wall and S.startWall and wall < S.startWall - 1 then return end         -- written before this session: history
  if w[3] == "HL" then
    if not P.loadT or os.clock() - P.loadT > 10.0 then log("the host says it loads a world: a silence of up to %.0f s is a load", P.cfg.loadSilence) end
    P.loadT = os.clock(); P.lastHL = P.loadT
  elseif w[3] == "BYE" then
    if (S.stats.states or 0) > 0 or (C.join and C.join.lastLoaded) then P.gone(S, "bye", w[4] or "?")
    else log("the host said goodbye (%s) before this copy was in its game: nothing to leave", tostring(w[4])) end
  end
end

-- ---------------------------------------------------------------- friend: leave
local function restoreHoldLine()
  local U = C.ui; if not U then return end
  if valid(U.pauseLbl) then pcall(function() U.pauseLbl:SetText(StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):Conv_StringToText(U.pauseOrig or "Game Paused")) end) end
  U.holdShown = false
end

function P.gone(S, why, detail)
  if P.leaving or not S or S.role ~= "friend" then return end
  local clock = os.clock()
  local text = why == "silent" and string.format(TEXT_SILENT, math.floor(P.cfg.silence + 0.5)) or TEXT_BYE
  if why == "silent" and P.limit and P.limit > P.cfg.silence + 1 then text = string.format(TEXT_SILENT, math.floor(P.limit + 0.5)) end
  P.leaving = { t = clock, why = why, text = text, shownT = -100 }
  log("THE HOST IS GONE (%s%s): this copy leaves the co-op game and goes back to the main menu in %.0f s", why,
      detail and (", " .. tostring(detail)) or "", P.cfg.exitAfter)
  -- the notice is drawn only while the game runs (lane 24): a host that paused and then died left this copy paused
  pcall(function() if valid(S.p1) and A.isPaused() then A.setPaused(false) end end)
  pcall(function() if valid(S.p1) then local g = GS(); if g:IsGamePaused(S.p1) then g:SetGamePaused(S.p1, false) end; g:SetGlobalTimeDilation(S.p1, 1.0) end end)
  S.hostHold = false; restoreHoldLine()
  -- the job gate: the list first, then the byte (coop_x_jobs.lua)
  if C.jobs and C.jobs.gateClose then local ok, e = pcall(C.jobs.gateClose, "the host is gone"); if not ok then log("job gate: %s", tostring(e)) end end
  if C.steam and C.steam.on then pcall(C.steam.leave) end
  if C.ui then C.ui.viaSteam = nil; C.ui.frWorld = nil; C.ui.frNoT = nil end
  C.hold = false
  if C.join then C.join.loading = nil; C.join.single = nil end
  -- the role: idle closes this copy's link file, stops reading the host and sends ALLOFF to the native piece
  if C.setRole then C.setRole("idle", "idle", {}) end
  if C.patch and C.patch.fn and C.patch.send then pcall(C.patch.send, "ALLOFF"); pcall(C.patch.tick) end
  C.notify("left", text)
  P.n = (P.n or 0) + 1
end

local function bannerNow(S, text)
  if C.ui and C.ui.banner and valid(S.p1) then
    -- the ui module's queue would show it once and late (2.5 s gap): shown here directly, again and again
    if C.ui.queue then for i = #C.ui.queue, 1, -1 do if C.ui.queue[i].text == text then table.remove(C.ui.queue, i) end end end
    return C.ui.banner(text)
  end
  return false
end

local function patchItems()
  if not (C.patch and C.patch.status) then return "no patch module" end
  local ok, st = pcall(C.patch.status); if not ok or not st or not st.items then return "status not readable" end
  local on, n = {}, 0
  for name, it in pairs(st.items) do n = n + 1; if it.state == "on" or it.state == "hooked" then on[#on + 1] = name .. "=" .. tostring(it.state) end end
  table.sort(on)
  return string.format("%d items, on: %s", n, #on > 0 and table.concat(on, ",") or "none")
end

local function leavingStep(S, clock)
  local L = P.leaving; if not L then return end
  if not L.exitT then
    if clock - L.shownT >= P.cfg.bannerEvery then L.shownT = clock; bannerNow(S, L.text) end
    if clock - L.t >= P.cfg.exitAfter then
      L.exitT = clock
      local p1 = S.p1
      pcall(function() if valid(p1) and p1:isPauseMenuVisible() then p1:ClosePauseMenu() end end)   -- no parameter in this build (sitting 2)
      local lvl = titleLevel()
      local ok, e = pcall(function() GS():OpenLevel(FindFirstOf("MLGameInstance"), FName(lvl), true, "") end)
      log("back to the main menu: the engine's OpenLevel %s %s", lvl, ok and "called" or ("failed: " .. tostring(e)))
    end
    return
  end
  -- at the title screen: say so in the log with what the native piece reports, put the reason on the menu's Co-op
  -- button, and end the save block 15 s later
  local lvl = levelName()
  if not L.atT and lvl == titleLevel() and noWorld() then
    L.atT = clock
    log("at the main menu (level %s) %.1f s after the decision; native piece: %s; saves blocked meanwhile: %d", tostring(lvl), clock - L.t, patchItems(), P.blocked or 0)
  end
  if L.atT then
    local U = C.ui
    if U and valid(U.btn) then
      local a = nil; pcall(function() a = U.btn:GetAddress() end)
      if a and a ~= L.btnA then L.btnA = a; pcall(function() U.btn:SetButtonText(StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):Conv_StringToText(TEXT_MENU)) end); log("the menu's Co-op button says: %s", TEXT_MENU) end
    end
    if clock - L.atT > 15.0 then P.left = { t = clock, why = L.why }; P.leaving = nil; log("left the co-op game (%s); native piece: %s", L.why, patchItems()) end
  elseif clock - L.exitT > 60.0 then
    log("still not at the main menu 60 s after OpenLevel (level %s): trying once more", tostring(lvl)); L.exitT = nil; L.t = clock - P.cfg.exitAfter
  end
end

-- the silence check. It runs in every state of a friend (world, load, join): S.heard.host is updated by every read of
-- the host's file. It decides only in a tick in which this copy just read the host's file (a copy that was itself
-- stopped for a while reads first), and only when the limit was passed at two checks at least 1 s apart.
local function silenceStep(S, clock)
  if S.role ~= "friend" or P.leaving then return end
  local h = S.heard and S.heard.host
  if not h then return end
  -- every gap of 3 s or more between two reads that brought something, and the longest per session (the limit's basis)
  if P.lastH and h ~= P.lastH then
    local g = h - P.lastH
    if g >= 3.0 then
      P.maxGap = math.max(P.maxGap or 0, g)
      log("the host was silent for %.1f s (longest this session %.1f s)%s", g, P.maxGap, C.hold and ", during a load or join" or "")
    end
  end
  P.lastH = h
  -- the host's load is over when its lines come again 4 s after its last "HL" (sitting 1: the long limit was still in
  -- force a minute after the host's load, and a host killed then was decided after 106 s instead of 30)
  if P.loadT and h > (P.lastHL or 0) + 4.0 then P.loadT = nil; log("the host is back from its load: the limit is %.0f s again", P.cfg.silence) end
  if (S.stats.states or 0) == 0 and not (C.join and C.join.lastLoaded) then return end   -- never in the host's game yet
  if S.tIn ~= clock then return end
  local lim = (P.loadT and clock - P.loadT < P.cfg.loadWindow) and P.cfg.loadSilence or P.cfg.silence
  P.limit = lim
  if clock - h > lim then
    if P.overT and clock - P.overT >= 1.0 then P.gone(S, "silent", string.format("nothing from the host for %.1f s, limit %.0f s", clock - h, lim))
    elseif not P.overT then P.overT = clock end
  else P.overT = nil end
end

-- ---------------------------------------------------------------- host: goodbye at the title screen, "HL" while loading
local function hostIdle(S, clock)
  if S.role ~= "host" or not P.hostHadWorld then return end
  if clock - (P.hostT or 0) < 1.0 then return end
  P.hostT = clock
  local lvl = levelName()
  if lvl == titleLevel() and noWorld() and not (C.join and (C.join.state or C.join.loading)) then
    P.titleT = P.titleT or clock
    if clock - P.titleT >= 2.0 and not P.byeSent then P.byeSent = true; A.send("BYE menu"); log("the host is at the title screen: goodbye sent") end
  else
    P.titleT = nil
    if clock - (P.beatT or 0) >= P.cfg.hostBeat then P.beatT = clock; A.send("HL") end     -- a world is loading
  end
end

local M = {}
function M.onWorld(S)
  if S.role == "host" then P.hostHadWorld = true; P.byeSent = nil; P.titleT = nil end
  P.lastH = nil
end
function M.tick(S, clock)
  ensureHooks()
  -- the limit is counted with os.clock: this line shows it keeps pace with the wall clock (os.time) on this runtime
  if clock - (P.ckT or -1e9) >= 120.0 then P.ckT = clock; log("clock check: os.time - os.clock = %.1f s", os.time() - clock) end
  if S.role == "host" then P.hostHadWorld = true; P.byeSent = nil; P.titleT = nil end
  silenceStep(S, clock)
  leavingStep(S, clock)
end
function M.idle(S, clock)
  ensureHooks()
  silenceStep(S, clock)
  leavingStep(S, clock)
  hostIdle(S, clock)
end

function P.status()
  local S = C.s
  local h = S and S.heard and S.heard.host
  return string.format("session: role %s, host heard %s s ago, limit %s, longest gap %.1f, leaving %s, left %s, saves blocked %d, hooks %s",
    S and S.role or "?", h and string.format("%.1f", os.clock() - h) or "-", tostring(P.limit), P.maxGap or 0,
    P.leaving and P.leaving.why or "no", P.left and P.left.why or "no", P.blocked or 0, tostring((rawget(_G, "__coop_session_hooks") or {}).done))
end

C.register("session", M)
return "coop session module loaded"
