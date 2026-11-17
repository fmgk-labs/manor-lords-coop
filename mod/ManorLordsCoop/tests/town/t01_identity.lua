-- t01_identity.lua  (town module: identity helpers; read-only, changes nothing)
-- Checks that each identity names the same object again:
--   building = type + position (T.findB), region = unique tag or #id (T.rkey / T.findR), road = its two end points (T.findRoad),
--   family = index in Region.workerFamilies (printed for one workplace), good = int.
-- CONFIRMED = every "same" column says true; region keys are tags (not "#...") and "duplicate region keys 0"; no two buildings print the same key.
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
local function addr(o) return o and o:GetAddress() or 0 end
-- buildings: the first 8 lord-owned ones
local n, keys, dup = 0, {}, 0
for i = 1, #eng.buildingArr do
  local b = un(eng.buildingArr[i])
  if n < 8 and b:IsValid() and nm(b.ownerPawn) == nm(p1) then
    n = n + 1
    local l = b:K2_GetActorLocation(); local t = b:GetType()
    local key = string.format("%d,%.0f,%.0f,%.0f", t, l.X, l.Y, l.Z)
    if keys[key] then dup = dup + 1 end; keys[key] = true
    local f = T.findB(t, l.X, l.Y)
    out("building", key, "same", tostring(addr(f) == addr(b)))
  end
end
out("duplicate keys among those", dup)
-- regions: every key must be unique (region setters are on by default and find their region by this key)
local home; local rk, rdup = {}, 0
for i = 1, #eng.regions do
  local r = un(eng.regions[i])
  if r:IsValid() then
    local k = T.rkey(r); local f = T.findR(k)
    if rk[k] then rdup = rdup + 1; out("DUPLICATE region key", k, r.regionName:ToString(), "and", rk[k]) end; rk[k] = r.regionName:ToString()
    local mine = nm(r.ownerPawn) == nm(p1)
    if mine and not home then home = r end
    if mine or i <= 3 then out("region", r.regionName:ToString(), "key", k, "same", tostring(addr(f) == addr(r)), mine and "(lord's)" or "") end
  end
end
out("regions", #eng.regions, "duplicate region keys", rdup)
-- roads: the first 4
for i = 1, math.min(4, #eng.roads) do
  local r = un(eng.roads[i])
  local sp = r.Spline; local m = sp:GetNumberOfSplinePoints()
  local a = sp:GetLocationAtSplinePoint(0, 1); local b = sp:GetLocationAtSplinePoint(m - 1, 1)
  local f = T.findRoad(a.X, a.Y, b.X, b.Y); local fr = T.findRoad(b.X, b.Y, a.X, a.Y)
  out("road", string.format("%.0f,%.0f -> %.0f,%.0f (%d pts)", a.X, a.Y, b.X, b.Y, m), "same", tostring(addr(f) == addr(r)), "reversed same", tostring(addr(fr) == addr(r)))
end
-- families: one workplace of the home region
if home then
  out("home region families", #home.workerFamilies)
  local bs = home:GetBuildings()
  for i = 1, #bs do
    local b = un(bs[i])
    if b:IsValid() and #b.assignedFamilyIDs > 0 then
      local ids = {}; for j = 1, #b.assignedFamilyIDs do ids[#ids + 1] = tostring(un(b.assignedFamilyIDs[j])) end
      out("workplace", b:GetType(), v3(b:K2_GetActorLocation()), "numActive", b.numActiveWorkerFamilies, "assignedFamilyIDs", table.concat(ids, ","))
      break
    end
  end
end
out(T.status())
return "ok"
