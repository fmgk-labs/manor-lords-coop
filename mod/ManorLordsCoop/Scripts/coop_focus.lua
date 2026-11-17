-- Manor Lords Co-op: a window that loses focus does not pause a co-op game (plug-in module "focus", lane 44).
-- STEP 1 (measurement): every way the game's pause menu opens or the game pauses is noted with its cause, so that a
-- pause by the player (the pause key or button, Esc, the game's own full screens) is told apart from one that came
-- with a focus change. The callbacks only note the moment; the work is in the tick.
local C = _G.Coop; local A = C.api
C.focus = C.focus or {}
local F = C.focus
local BPL = "/Game/CPP_BP/MyPawnCPP_BP3.MyPawnCPP_BP3_C:"
local WATCH = {
  { "focus", BPL .. "OnWindowFocusChanged" },
  { "esc", BPL .. "InpActEvt_esc_K2Node_InputActionEvent_13" },
  { "toggleMenu", BPL .. "togglePauseMenu" },
  { "tabPressed", BPL .. "tabBpPressed" },
  { "openMenu", BPL .. "OpenPauseMenu" },
  { "closeMenu", BPL .. "ClosePauseMenu" },
  { "pauseKey", BPL .. "InpActEvt_pause_K2Node_InputActionEvent_1" },
  { "togglePause", BPL .. "toggleTimePause" },
  { "pausedInclVamp", BPL .. "setGamePausedInclVamp" },
  { "menuReopen", "/Game/UI/Main_Menu/mainMenu_widget.mainMenu_widget_C:OnPauseMenuReopen" },
}
local function log(fmt, ...) A.log("focus: " .. fmt, ...) end

local function ensureHooks()
  local H = rawget(_G, "__coop_focus_hooks"); if not H then H = {}; _G.__coop_focus_hooks = H end
  if H.done or (H.t and os.clock() - H.t < 2.0) then return end
  H.t = os.clock()
  local all = true
  for _, d in ipairs(WATCH) do
    local key, path = d[1], d[2]
    if not H[key] then
      local ok = pcall(RegisterHook, path, function(self, a1)
        local Fm = rawget(_G, "Coop") and _G.Coop.focus; if not Fm then return end
        local v = nil; if a1 ~= nil then pcall(function() v = a1:get() end) end
        Fm.ev = Fm.ev or {}
        if #Fm.ev < 200 then Fm.ev[#Fm.ev + 1] = { k = key, t = os.clock(), v = v } end
        Fm.last = Fm.last or {}; Fm.last[key] = os.clock()
        -- read at once by the host's state line; lostClear: the game was running with no menu at the last tick
        -- before the loss (a pause the player made earlier is never undone)
        if key == "focus" and v == false then Fm.lostT = os.clock(); Fm.lostClear = Fm.clearNow == true end
      end)
      if ok then H[key] = true else all = false end
    end
  end
  if all then H.done = true; log("hooks registered (%d)", #WATCH) end
end

local function menuVisible(S)
  local v = nil; pcall(function() v = S.p1:isPauseMenuVisible() end)
  return v
end

local function report(S, clock)
  if F.ev and #F.ev > 0 then
    local list = F.ev; F.ev = {}
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = string.format("%s%s@%.2f", e.k, e.v ~= nil and ("(" .. tostring(e.v) .. ")") or "", e.t) end
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local eng = false; pcall(function() eng = GS:IsGamePaused(S.p1) end)
    log("%s | now: menu %s, paused %s, speed %.2f, engine paused %s", table.concat(parts, " "), tostring(menuVisible(S)), tostring(A.isPaused()), tonumber(S.eng.gameSpeed) or -1, tostring(eng))
  end
  -- the pause menu's state, and every change of it
  local mv = menuVisible(S)
  if mv ~= F.menuWas then
    log("pause menu %s (last focus event %s, esc %s, toggle %s, open %s)", mv and "OPEN" or "closed",
      F.last and F.last.focus and string.format("%.2f s ago", clock - F.last.focus) or "never",
      F.last and F.last.esc and string.format("%.2f s ago", clock - F.last.esc) or "never",
      F.last and F.last.toggleMenu and string.format("%.2f s ago", clock - F.last.toggleMenu) or "never",
      F.last and F.last.openMenu and string.format("%.2f s ago", clock - F.last.openMenu) or "never")
    F.menuWas = mv
  end
end

-- STEP 2: what can pause a game on a focus loss, and what this module does about each (lane 44 report):
--   * the engine's own setting UEngine.bPauseOnLossOfFocus. It was OFF on both test copies (read in sitting 2), so the
--     plain game does not use it; should a player's copy have it on, it is switched off while this copy plays a co-op
--     game (host or friend, in a world) and put back as soon as it does not (title screen, solo game, mod stopped);
--   * the lord blueprint's OnWindowFocusChanged: it acts only when the window GETS focus (input mode, mouse lock);
--     on a loss it does nothing (its script bytes; a recording of lane 30 with four real focus losses shows no
--     pause-menu call either);
--   * anything else nobody has found: the guard below undoes a pause menu or an engine pause that comes within 3 s
--     of a focus loss with no pause control of the player.
local FLAG = "bPauseOnLossOfFocus"
local function gengine()
  if F.ge and A.valid(F.ge) then return F.ge end
  F.ge = FindFirstOf("GameEngine"); if not A.valid(F.ge) then F.ge = nil end
  return F.ge
end
local function flagGet()
  local ge = gengine(); if not ge then return nil end
  local ok, v = pcall(function() return ge[FLAG] end)
  if ok and type(v) == "boolean" then return v end
  return nil
end
local function flagSet(v)
  local ge = gengine(); if not ge then return false end
  local ok = pcall(function() ge[FLAG] = v end)
  return ok and flagGet() == v
end
-- want = true: the co-op setting (off); want = false: the player's own setting back
function F.apply(want)
  if want then
    if F.saved == nil then
      local cur = flagGet()
      if cur == nil then if not F.saidNo then F.saidNo = true; log("the engine's %s cannot be read: nothing changed", FLAG) end; return end
      F.saved = cur
      if cur == false then log("the engine's %s is already off (the player's own setting): nothing to change", FLAG)
      else log("the engine's %s was on: %s for the co-op game", FLAG, flagSet(false) and "now off" or "COULD NOT be switched off") end
    elseif F.saved == true and flagGet() ~= false then
      log("the engine's %s was on again: off again (%s)", FLAG, tostring(flagSet(false)))
    end
  elseif F.saved ~= nil then
    local back = F.saved; F.saved = nil
    if back == true then log("the engine's %s put back on (no co-op game on this copy now): %s", FLAG, tostring(flagSet(true))) end
  end
end

-- A pause that came with a focus loss (within 3 s; the game had no menu open and was not paused before it) and with
-- no pause control of the player since: undone (the menu
-- closed with the game's own ClosePauseMenu, the engine's pause lifted). Logged, so a cause nobody knows shows up.
-- Explicit = the keyboard's Esc (input action "esc"), the pause key and the HUD's pause button (toggleTimePause). The
-- gamepad's Start (togglePauseMenu, called by the game's native ControlHook) is not counted within 3 s of a focus loss:
-- it is the only other way the game's code reaches OpenPauseMenu (lane 44 report), so a focus pause would come that way.
local EXPLICIT = { "esc", "pauseKey", "togglePause" }
local function guard(S, clock)
  local lost = F.lostT; if not lost or clock - lost > 3.0 or not F.lostClear then return end
  for _, k in ipairs(EXPLICIT) do if F.last and F.last[k] and F.last[k] >= lost - 0.5 then return end end
  local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
  local eng = false; pcall(function() eng = GS:IsGamePaused(S.p1) end)
  local mv = menuVisible(S)
  if not eng and not mv then return end
  local okC, eC = true, nil
  if mv then okC, eC = pcall(function() S.p1:ClosePauseMenu() end) end          -- no parameter in this build (sitting 2)
  if eng then pcall(function() if GS:IsGamePaused(S.p1) then GS:SetGamePaused(S.p1, false) end end) end
  F.undone = (F.undone or 0) + 1
  local eng2 = nil; pcall(function() eng2 = GS:IsGamePaused(S.p1) end)
  log("a pause that came with the window's focus loss %.2f s ago (menu %s, engine paused %s) was undone (%d): now menu %s, engine paused %s, speed %.2f%s",
    clock - lost, tostring(mv), tostring(eng), F.undone, tostring(menuVisible(S)), tostring(eng2), tonumber(S.eng.gameSpeed) or -1, okC and "" or (", close failed: " .. tostring(eC)))
end

local M = {}
function M.onWorld(S) F.menuWas = nil end
function M.tick(S, clock)
  ensureHooks()
  local inGame = S.on and (S.role == "host" or S.role == "friend") and A.valid(S.p1)
  if clock - (F.tA or -10) >= 1.0 then F.tA = clock; pcall(F.apply, inGame) end
  -- the focus events seen by the hooks: a loss is noted for the guard
  if F.ev then for _, e in ipairs(F.ev) do if e.k == "focus" and e.v == false then F.lostT = e.t end end end
  if clock - (F.tR or 0) >= 0.1 then F.tR = clock; local ok, e = pcall(report, S, clock); if not ok and F.err ~= tostring(e) then F.err = tostring(e); log("report: %s", F.err) end end
  if inGame then local ok, e = pcall(guard, S, clock); if not ok and F.gerr ~= tostring(e) then F.gerr = tostring(e); log("guard: %s", F.gerr) end end
  -- this tick's state, for the next focus loss: running, no pause menu, engine not paused (a full screen pauses it)
  local clear = false
  pcall(function() clear = not menuVisible(S) and not StaticFindObject("/Script/Engine.Default__GameplayStatics"):IsGamePaused(S.p1) end)
  if not (F.lostT and clock - F.lostT <= 3.0) then F.clearNow = clear end
end
function M.idle(S, clock)
  ensureHooks()
  if clock - (F.tA or -10) >= 1.0 then F.tA = clock; pcall(F.apply, false) end
end
-- the host's state line asks this (coop.lua hostStopped): a world stopped within 3 s of a focus loss with no pause
-- control of the player is not told to the friends as "held"; the guard undoes it in the same frame
function F.focusStop(clock)
  local lost = F.lostT; if not lost or clock - lost > 3.0 or not F.lostClear then return false end
  for _, k in ipairs(EXPLICIT) do if F.last and F.last[k] and F.last[k] >= lost - 0.5 then return false end end
  return true
end
function F.status() return string.format("focus: engine %s = %s, saved %s, focus pauses undone %d", FLAG, tostring(flagGet()), tostring(F.saved), F.undone or 0) end

-- the mod stopping: the player's own setting back (modules get no stop call, so C.stop is wrapped, as coop_patch does)
if C.stop ~= F.stopWrap then
  local orig = C.stop
  F.stopWrap = function(...)
    local Fm = rawget(_G, "Coop") and _G.Coop.focus
    if Fm and Fm.apply then pcall(Fm.apply, false) end
    return orig(...)
  end
  C.stop = F.stopWrap
end
C.register("focus", M)
return "coop focus module loaded"
