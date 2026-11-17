-- t5_building_stock.lua  World module self-test 5: a fake per-building message (lane_w W6; addToInventory +1/-1
-- proven live on one copy in README session 14). ONE copy, game PAUSED. Never saves. Changes one storage building's
-- stock by +1 and back through the module's friend path (key lookup, inventory read, signed addToInventory).
-- Assumes the probe helper library is prepended and coop.lua + coop_world.lua are loaded and Coop is started.
-- PASS if: the building's amount of good g goes a -> a+1 -> a AND its region's total goes r -> r+1 -> r.
-- Restores (also after an error): the building's stock, the module's stored values and switches.
local C = rawget(_G, "Coop"); if not (C and C.s and C.world) then return "load coop.lua and coop_world.lua and start Coop first" end
local W, S, A = C.world, C.s, C.api
if not p1.bIsPlayerPaused then p1:pauseGame() end
if not W.prepare(S) then return "no lord pawn" end
local store, g, a
for i = 1, #eng.buildingArr do
  local b = un(eng.buildingArr[i])
  if b:IsValid() and W.isMine(b.ownerPawn) and b:IsConstructed() then
    local ok, s = pcall(function() return b:isStorageTypeBuilding() end)
    if ok and s then for t, x in pairs(W.invOf(b)) do if x >= 1 and not g then store, g, a = b, t, x end end end
  end
  if store then break end
end
if not store then return "no storage building of the lord with stock" end
local k = W.bkey(store)
local region = store:GetRegion()
local function amt() return W.invOf(store)[g] or 0 end
local function reg() return region:IsValid() and region:getStockOfGood(g, false, false) or -1 end
local r0 = reg()
local saved = { bstock = W.on.bstock, dry = W.dry, E = W.fr.bld[k] }
local a1, r1, a2, r2

local function body()
  W.on.bstock, W.dry = true, false; W.fr.bld[k] = nil
  local function feed(text)
    local line = string.format("%d %.3f %s", 0, A.now(), text)
    W.apply(S, A.words(line)); W.applyNow(S, "bld")   -- the building pass only: a region pass could undo the +1
    out("  fed:", text)
  end
  out("storage", k, "region", W.rkey(region), "good", g, "building", a, "region total", r0)
  feed(string.format("W B %s|%d=%d", k, g, a + 1)); a1, r1 = amt(), reg()
  out("  after +1: building", a1, "region", r1)
  feed(string.format("W B %s|%d=%d", k, g, a)); a2, r2 = amt(), reg()
  out("  back:     building", a2, "region", r2)
end

local ok, e = pcall(body)
if amt() ~= a then pcall(function() store:addToInventory({ Type = g, amt = a - amt() }) end) end
W.fr.bld[k] = saved.E; W.fr.bdirty[k] = nil
W.on.bstock, W.dry = saved.bstock, saved.dry
out("final building", amt(), "region", reg(), "| last module error", tostring(W.lastErr))
if not ok then out("VERDICT", "FAIL (error: " .. tostring(e) .. ")"); return "error" end
local bOk = a1 == a + 1 and a2 == a
local rOk = r1 == r0 + 1 and r2 == r0
out("VERDICT", (bOk and rOk) and "PASS" or (bOk and "PARTLY: building moved, region total did not follow" or "FAIL"))
return "ok"
