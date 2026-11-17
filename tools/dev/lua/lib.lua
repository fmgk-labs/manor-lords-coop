local eng = FindFirstOf("RTSMultiEngineCPP"); local lord = eng.playerRef
local function un(x) local ok, v = pcall(function() return x:get() end); if ok and v ~= nil then return v end; return x end
local function cname(w) return (w:GetClass():GetFullName():match("([^%.]+)$") or "?") end
local function buildings() local t = {}; local a = eng.buildingArr; for i = 1, #a do local b = un(a[i]); if b and b:IsValid() then t[#t+1] = b end end; return t end
local function mine(b) local ok, r = pcall(function() return b.ownerPawn:GetAddress() == lord:GetAddress() end); return ok and r end
local function bAt(x, y) for _, b in ipairs(buildings()) do local L = b:K2_GetActorLocation(); if math.abs(L.X - x) < 5 and math.abs(L.Y - y) < 5 then return b end end end
local function bType(t, nth) local n = 0; for _, b in ipairs(buildings()) do if b:GetType() == t and mine(b) then n = n + 1; if n == (nth or 1) then return b end end end end
local function bkey(b) local L = b:K2_GetActorLocation(); return string.format("%d@%.0f,%.0f", b:GetType(), L.X, L.Y) end
local CLICK = "BndEvt__W_MaterialButton_Button_K2Node_ComponentBoundEvent_4_OnButtonClickedEvent__DelegateSignature"
local function press(w) return pcall(function() w[CLICK](w) end) end
-- every widget under root (user widgets are entered), as a flat list of { w, depth, path }
local function under(root, maxd)
  local out = {}
  local function walk(w, d)
    if d > (maxd or 12) or #out > 1500 then return end
    local v = 99; pcall(function() v = w:GetVisibility() end); if v == 1 or v == 2 then return end      -- hidden subtrees are skipped
    out[#out + 1] = { w = w, d = d }
    local okN, n = pcall(function() return w:GetChildrenCount() end)
    if okN and type(n) == "number" then for i = 0, n - 1 do local c = w:GetChildAt(i); if c and c:IsValid() then walk(c, d + 1) end end; return end
    local okC, c = pcall(function() return w:GetContent() end)
    if okC and c and c:IsValid() then walk(c, d + 1); return end
    local okT, r = pcall(function() return w.WidgetTree.RootWidget end)
    if okT and r and r:IsValid() and cname(w):sub(1, 3) ~= "MD_" then walk(r, d + 1) end
  end
  walk(root, 0); return out
end
local function shown(w) local v = 99; pcall(function() v = w:GetVisibility() end); return v ~= 1 and v ~= 2 end
local function panel() local p; for _, w in ipairs(FindAllOf("Inventory_C") or {}) do if w:IsValid() and shown(w) then local okV, iv = pcall(function() return w:IsInViewport() end); p = w end end; return p end
-- find a widget by object name under root, only through shown ancestors
local function find(root, name, cls)
  local hit
  local function walk(w, d)
    if hit or d > 40 or not shown(w) then return end
    if w:GetFName():ToString() == name and (not cls or cname(w) == cls) then hit = w; return end
    local okN, n = pcall(function() return w:GetChildrenCount() end)
    if okN and type(n) == "number" then for i = 0, n - 1 do local c = w:GetChildAt(i); if c and c:IsValid() then walk(c, d + 1) end end; return end
    local okC, c = pcall(function() return w:GetContent() end)
    if okC and c and c:IsValid() then walk(c, d + 1); return end
    local okT, r = pcall(function() return w.WidgetTree.RootWidget end)
    if okT and r and r:IsValid() and cname(w):sub(1, 3) ~= "MD_" then walk(r, d + 1) end
  end
  walk(root, 0); return hit
end
-- the game's own cheat manager (settlement level, perks, raiders, bandits, rebellion, influence, favour, items ...):
-- not created in the shipped game, so it is made here once. Use it ON THE HOST to prepare a test state; friends follow.
-- Functions: grep MLCheatManager research/2026-11-10-game-probe/registry/registry.tsv (the maintainers' notes, optional)
local function cheat()
  local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(lord, 0)
  local cm; pcall(function() cm = pc.CheatManager end)
  if cm and cm:IsValid() then return cm end
  cm = FindFirstOf("MLCheatManager_C"); if cm and cm:IsValid() then return cm end
  cm = StaticConstructObject(StaticFindObject("/Game/CPP_BP/MLCheatManager.MLCheatManager_C"), pc)
  pcall(function() pc.CheatManager = cm end)
  return cm
end
