-- t07_families.lua  (town module: families minus/plus with the assignedFamilyIDs correction; ONE copy, one run)
-- 1. SEE: removeActiveWorkerFamily() on a lord workplace (the minus button's call, seen live in session 7c) -> pump: expect
--    "T host <n> REMW <building> <ids after> <numActive after>".
-- 2. REPLAY as host: feed "ADDW <building> <original ids> <original count>" as if a friend pressed plus. The host calls
--    addActiveWorkerFamily() and passes the action on with ITS OWN resulting list, plus a FAMS line (origin host) for the
--    friend who clicked. Both lines are printed.
-- 3. CORRECTION: feed "FAMS <building> <original ids> <count>" and check the building's list equals the original
--    (Region:unassignFamily / assignFamily / reassignFamily, lane_t2 T6 - static).
-- 4. RESTORE: the whole region's family -> workplace map is put back as it was (quietly), like lane_t2 probe_T6.
-- CONFIRMED = one REMW line; ADDW replay ok with a forwarded ADDW and a FAMS line; correction "ok" with the original list;
--   "restore left 0 differences".
-- RISK: medium-low: family assignment changes for a moment across the region (the game's job pass can move other families).
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
if not p1.bIsPlayerPaused then p1:pauseGame() end
local flags = T.test.flags()
T.enable("ADDW", true); T.enable("REMW", true)
out(T.test.hooksNow())
local R
for i = 1, #eng.regions do local r = un(eng.regions[i]); if r:IsValid() and nm(r.ownerPawn) == nm(p1) then if r.isSettled then R = r; break end; R = R or r end end
if not R then T.test.restoreFlags(flags); return "no region owned by the lord" end
local bs = {}; do local a = R:GetBuildings(); for i = 1, #a do local b = un(a[i]); if b:IsValid() then bs[#bs + 1] = b end end end
local target
for _, b in ipairs(bs) do pcall(function() if not target and b.numActiveWorkerFamilies >= 1 and #b.assignedFamilyIDs >= 1 and not b:getSleep() then target = b end end) end
if not target then T.test.restoreFlags(flags); return "no workplace with an assigned family" end
local function ids(b) local t = {}; for i = 1, #b.assignedFamilyIDs do t[#t + 1] = math.tointeger(un(b.assignedFamilyIDs[i])) or un(b.assignedFamilyIDs[i]) end; table.sort(t); return t end
-- family index -> workplace address (wrappers of the same object need not compare equal, addresses do)
local byAddr = {}; for _, b in ipairs(bs) do byAddr[b:GetAddress()] = b end
local function snap() local m = {}; for _, b in ipairs(bs) do pcall(function() for i = 1, #b.assignedFamilyIDs do m[un(b.assignedFamilyIDs[i])] = b:GetAddress() end end) end; return m end
local l = target:K2_GetActorLocation()
local key = string.format("%d,%.0f,%.0f,%.0f", target:GetType(), l.X, l.Y, l.Z)
local S0 = snap(); local orig = ids(target); local n0 = target.numActiveWorkerFamilies
local origS = (#orig > 0) and table.concat(orig, ",") or "-"
out("workplace", key, "numActive", n0, "families", origS, "| region families", #R.workerFamilies)
-- 1. SEE
T.test.clearEcho(); T.test.cap()
target:removeActiveWorkerFamily()
T.test.pump()
for _, x in ipairs(T.test.uncap()) do out("SEE line:", x) end
out("after minus: numActive", target.numActiveWorkerFamilies, "families", table.concat(ids(target), ","))
-- 2. REPLAY of a friend's plus
T.test.cap()
local _, r2 = T.inject("ADDW", key .. " " .. origS .. " " .. n0)
for _, x in ipairs(T.test.uncap()) do out("host sent:", x) end
out("ADDW replay ->", r2, "| numActive", target.numActiveWorkerFamilies, "families", table.concat(ids(target), ","))
-- 3. correction to the original list
T.test.cap()
local _, r3 = T.inject("FAMS", key .. " " .. origS .. " " .. n0)
T.test.uncap()
out("FAMS correction ->", r3, "| families now", table.concat(ids(target), ","), "want", origS)
-- 4. restore the region's assignment
local S2 = snap(); local moved = 0
T.quiet(function()
  for i = 0, #R.workerFamilies - 1 do if S2[i] and not S0[i] then R:unassignFamily(i) end end
  for i = 0, #R.workerFamilies - 1 do
    if S0[i] and S2[i] ~= S0[i] then
      if snap()[i] then R:reassignFamily(i, byAddr[S0[i]]) else R:assignFamily(i, byAddr[S0[i]]) end
    end
  end
  if target.numActiveWorkerFamilies < n0 then target:addActiveWorkerFamily() end
end)
local S3 = snap()
for i = 0, #R.workerFamilies - 1 do if S3[i] ~= S0[i] then moved = moved + 1; out("  still differs: family", i) end end
out("restore left", moved, "differences | numActive", target.numActiveWorkerFamilies, "(was", n0, ")")
T.test.restoreFlags(flags)
return "done"
