-- Manor Lords Co-op: a SECOND copy of the game on this install (lane 62; coop_guard.lua decided it).
-- Nothing of the mod runs in this process: no core, no modules, no link files, no logs, no status files, no Steam
-- link, no native piece, no hello to anybody. The first process is not touched. This file only tells the player, with
-- two rows in the game's own menu column (the title menu and the pause menu are one widget), above Quit Game:
--     Manor Lords is already running
--     with co-op on this PC. Close this copy.
-- (two rows: one menu button does not hold the whole sentence). The rows are the game's own menu buttons; a click on
-- them does nothing. Solo play in this copy goes on as without the mod.
local TEXT = { "Manor Lords is already running", "with co-op on this PC. Close this copy." }
local X = { rows = {}, made = 0 }
_G.COOP_SECOND = X
X.text = TEXT

local function valid(o) if o == nil then return false end; local ok, r = pcall(function() return o:IsValid() end); return ok and r == true end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); return ok and a or nil end
local function ftext(s) return StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):Conv_StringToText(s) end

local function step()
  -- (lane 64, task 64d) the menu is found afresh at every step (once a second): a menu widget kept from a step before
  -- may have been freed with its level, and valid() on freed memory can say "true"; this process has no native piece
  -- to ask. The rows were made on the menu at one address: they are kept, and looked at, only while the menu found now
  -- is at that address
  local m
  for _, w in ipairs(FindAllOf("mainMenu_widget_C") or {}) do if valid(w) then m = w end end
  local ma = m and addr(m) or nil
  if ma ~= X.menuA then X.rows = {}; X.menuA = ma end
  X.menu = m
  if not valid(m) then return end
  local shown = false; pcall(function() shown = m:IsInViewport() end)
  if not shown then return end
  local quit = m.menuButton_quit; if not valid(quit) then return end
  local col = quit:GetParent(); if not valid(col) then return end
  if valid(X.rows[1]) and addr(X.rows[1]:GetParent()) == addr(col) then return end        -- the rows are there
  local gi = FindFirstOf("MLGameInstance")
  local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
  local pc = nil; pcall(function() pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0) end)
  local al = quit.Slot.HorizontalAlignment
  X.rows = {}
  for i, s in ipairs(TEXT) do
    local b = WBL:Create(gi, quit:GetClass(), pc)
    if not valid(b) then return end
    b:SetButtonText(ftext(s))
    local slot = col:AddChild(b)
    pcall(function() slot:SetHorizontalAlignment(al) end)
    X.rows[i] = b
  end
  col:RemoveChild(quit); local slot = col:AddChild(quit); pcall(function() slot:SetHorizontalAlignment(al) end)     -- Quit Game stays last
  pcall(function() m:RebuildNaviGrid() end)
  X.made = X.made + 1
end

function X.tick() local ok, e = pcall(step); if not ok then X.err = tostring(e) end end
if rawget(_G, "LoopInGameThreadWithDelay") then X.handle = LoopInGameThreadWithDelay(1000, function() _G.COOP_SECOND.tick() end) end
return "coop: a second copy on this install; the mod is off in this process"
