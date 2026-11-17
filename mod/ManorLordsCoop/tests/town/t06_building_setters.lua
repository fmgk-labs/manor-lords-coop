-- t06_building_setters.lua  (town module: building setters SEE + REPLAY round trips on ONE copy; one run; restores values)
-- Same pattern as t05: call the setter on a lord building with a changed value (SEE, prints the line), then feed the action
-- back with the ORIGINAL value as if a friend sent it (REPLAY on the building found by type + position), check the value.
-- Targets: a construction site for SLEEP / CPAUSE / PRIO (fewer side effects: on a workplace setSleep(true) unassigns its
-- families, lane_t1 T8e), any building that answers for PROTECT, a field for FERTILIZE, a building with an active recipe for
-- RECIPE_OFF / RECIPE_ON, the first building with a maintenance component for MAINT. CROP only when DO_CROP (changing a field's crop may reset its work; not read).
-- CONFIRMED = each action prints one SEE line, "replay ok", "value back: true" and "extra lines 0".
-- RISK: low. SetPriority aborts the builders' current task on that site (READ lane_t1 T8f); they pick it up again.
local DO_CROP = false
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
if not p1.bIsPlayerPaused then p1:pauseGame() end
local flags = T.test.flags()
for _, a in ipairs({ "SLEEP", "CPAUSE", "PRIO", "PROTECT", "FERTILIZE", "RECIPE_ON", "RECIPE_OFF", "CROP", "MAINT" }) do T.enable(a, true) end
out(T.test.hooksNow())
local function key(b) local l = b:K2_GetActorLocation(); return string.format("%d,%.0f,%.0f,%.0f", b:GetType(), l.X, l.Y, l.Z) end
local function step(act, b, see, args0, back)
  T.test.clearEcho()
  T.test.cap(); local ok, e = pcall(see); T.test.pump(); local seen = T.test.uncap()
  out(act, key(b), "SEE call ok", tostring(ok), e or "", "| line:", seen[1] or "NOTHING SENT")
  T.test.cap(); local _, res = T.inject(act, key(b) .. " " .. args0); T.test.pump(); local after = T.test.uncap()
  local extra = 0; for _, l in ipairs(after) do if not l:find("T selftest", 1, true) then extra = extra + 1 end end
  local okb, isBack = pcall(back)
  out(act, "REPLAY", args0, "->", tostring(res), "| value back:", tostring(okb and isBack), "| forwarded:", tostring(after[1] ~= nil), "| extra lines", extra)
end
local site, prot, field, rec, recGood, maint
for i = 1, #eng.buildingArr do
  local b = un(eng.buildingArr[i])
  if b:IsValid() and nm(b.ownerPawn) == nm(p1) then
    if not site and not b:IsConstructed() then site = b end
    if not prot then local ok, v = pcall(function() return b:GetProtectResourceArea() end); if ok and type(v) == "boolean" and b:GetType() ~= 5 then prot = b end end
    if not field and b:GetType() == 5 then field = b end
    if not maint then local ok, v = pcall(function() local mc = b.MaintenanceComponent; return mc:IsValid() and mc:GetSliderValue() end); if ok and type(v) == "number" then maint = b end end
    if not rec then local ok, a = pcall(function() return b:GetActiveRecipes() end); if ok and a and #a > 0 then rec = b; recGood = un(a[1]) end end
  end
end
if site then
  local s0 = site.sleep
  step("SLEEP", site, function() site:setSleep(not s0) end, s0 and "1" or "0", function() return site.sleep == s0 end)
  local c0 = site:getConstructionPaused()
  step("CPAUSE", site, function() site:setConstructionPaused(not c0) end, c0 and "1" or "0", function() return site:getConstructionPaused() == c0 end)
  local p0 = site:GetPriority()
  step("PRIO", site, function() site:SetPriority(p0 + 1) end, tostring(p0), function() return site:GetPriority() == p0 end)
else out("no construction site: SLEEP / CPAUSE / PRIO skipped (place any building first)") end
if prot then
  local v0 = prot:GetProtectResourceArea()
  step("PROTECT", prot, function() prot:SetProtectResourceArea(not v0) end, v0 and "1" or "0", function() return prot:GetProtectResourceArea() == v0 end)
end
if field then
  local f0 = field:GetAllowFertilization()
  step("FERTILIZE", field, function() field:SetAllowFertilization(not f0) end, f0 and "1" or "0", function() return field:GetAllowFertilization() == f0 end)
  if DO_CROP then
    local c0 = field:getCropType(); local c1 = (c0 == 1) and 2 or 1
    step("CROP", field, function() field:setCropType(c1) end, tostring(c0), function() return field:getCropType() == c0 end)
  end
end
if rec then
  local function active() local a = rec:GetActiveRecipes(); for i = 1, #a do if un(a[i]) == recGood then return true end end; return false end
  step("RECIPE_OFF", rec, function() rec:DisableRecipe(recGood) end, tostring(recGood), function() return not active() end)
  step("RECIPE_ON", rec, function() end, tostring(recGood), function() return active() end)
  out("recipe", recGood, "active again:", tostring(active()))
else out("no building with an active recipe: RECIPE skipped") end
if maint then
  -- the hook is on the component; the module names the building by scanning its index (not yet run live)
  local mc = maint.MaintenanceComponent; local m0 = mc:GetSliderValue(); local m1 = (m0 == 1) and 2 or 1
  step("MAINT", maint, function() mc:SetSliderValue(m1) end, tostring(m0), function() return mc:GetSliderValue() == m0 end)
else out("no building with a maintenance component: MAINT skipped") end
T.test.restoreFlags(flags)
return "done"
