-- t04_field.lua  (town module: FIELD (or PASTURE) seen on the local lord and replayed through the helper)
-- Run it twice on ONE copy (stage 1, stage 2). Speed is set to 0; nothing is saved.
-- Stage 1, MANUAL = true: the operator draws and commits one small field by hand after this run (the real SEE path).
-- Stage 1, MANUAL = false: the local lord gets a scripted draft copied from an existing lord field, moved by OFF_A
--   (setFieldMode(true, 1), fieldSmoothPoints, fieldCenter, fieldRot, fieldWorkersNeeded, blank FieldPoints: the session 7c
--   recipe), then p1:addCommitFieldRequest() - the call the click makes; the engine commits it for playerRef (session 4).
--   RISK: the lord's per-frame draft update may overwrite a scripted draft before the commit (never tried); if the made
--   field looks wrong, use MANUAL. This replaces the player's own draft.
-- Stage 2: prints the line the module sent (expect "T host <n> FIELD cx,cy,cz p,y,r workers smooth corners cw", sent only
--   after the field existed, with real corners), feeds it in moved by SHIFT as if a friend sent it, checks the replica,
--   then asks the helper to demolish the test fields (its demolishRequests list, as the click does; never a direct
--   demolish) when CLEANUP. They are gone after the helper's next Tick.
-- CONFIRMED = one FIELD line whose corner list is not "-"; replay result "ok"; a type-5 building at the shifted centre owned by
--   the lord whose fieldBorderPoints equal the shifted corners; the forwarded line captured.
-- Set PASTURE = true to test plotType 2 / type 10 the same way (static recipe; PASTURE is enabled for the test only).
local MANUAL = false
local PASTURE = false
local OFF_A = { X = -9000.0, Y = 2000.0 }
local SHIFT = { X = 0.0, Y = 4500.0 }
local CLEANUP = true
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
-- placements were only proven at speed 0, never under pauseGame (t05-t07 pause): un-pause, then speed 0
if p1.bIsPlayerPaused then p1:unPauseGame() end
if eng.gameSpeed ~= 0.0 then p1:setGameSpeed(0.0) end
local ACT, BT, PT = PASTURE and "PASTURE" or "FIELD", PASTURE and 10 or 5, PASTURE and 2 or 1
_G.__tt = _G.__tt or {}
local st = _G.__tt.field
if not st then
  st = { flags = T.test.flags(), stage = 1 }
  _G.__tt.field = st
  T.enable(ACT, true); T.test.hooksNow(); T.test.cap()
  if MANUAL then return "stage 1: draw and commit one small " .. ACT:lower() .. " by hand now, then run again" end
  local src
  for i = 1, #eng.buildingArr do local x = un(eng.buildingArr[i]); if x:IsValid() and x:GetType() == BT and nm(x.ownerPawn) == nm(p1) then src = x end end
  if not src then _G.__tt.field = nil; T.test.uncap(); return "no lord-owned building of type " .. BT .. " to copy; use MANUAL = true" end
  local sl, sr = src:K2_GetActorLocation(), src:K2_GetActorRotation()
  p1.placeBuilding = 0
  p1:setFieldMode(true, PT)
  pcall(function() p1.fieldSmoothPoints:Empty() end)
  for i = 1, #src.FieldPoints do local v = src.FieldPoints[i]; p1.fieldSmoothPoints[i] = { X = v.X + OFF_A.X, Y = v.Y + OFF_A.Y, Z = v.Z } end
  p1.fieldCenter = { X = sl.X + OFF_A.X, Y = sl.Y + OFF_A.Y, Z = sl.Z }
  p1.fieldRot = { Pitch = sr.Pitch, Yaw = sr.Yaw, Roll = sr.Roll }
  p1.fieldWorkersNeeded = src.fieldWorkersNeeded
  for _ = 1, math.max(#src.fieldBorderPoints, 5) do pcall(function() p1.FieldPoints[#p1.FieldPoints + 1] = {} end) end
  st.cx, st.cy = sl.X + OFF_A.X, sl.Y + OFF_A.Y
  p1:addCommitFieldRequest()
  return string.format("stage 1: scripted %s draft at %.0f,%.0f requested for commit; run again", ACT, st.cx, st.cy)
end
pcall(function() p1:setFieldMode(false, 0) end)
local lines = T.test.lines()
for _, l in ipairs(lines) do out("SENT", (l:sub(1, 300))) end
local line
for _, l in ipairs(lines) do local a = T.test.fieldsOf(l); if a == ACT then line = l end end
if not line then
  out(T.status())
  return "no " .. ACT .. " line yet: run again in a moment (or the commit was refused)"
end
local _, fields = T.test.fieldsOf(line)
local f = {}; for x in fields:gmatch("%S+") do f[#f + 1] = x end
out("captured: centre", f[1], "rot", f[2], "workers", f[3], "smooth points", select(2, f[4]:gsub("|", "")) + 1, "corners", f[5] == "-" and 0 or select(2, f[5]:gsub("|", "")) + 1, "clockwise", f[6])
local c = {}; for x in f[1]:gmatch("[^,]+") do c[#c + 1] = tonumber(x) end
local a = T.findB(BT, c[1], c[2])
local moved = T.test.shift(ACT, fields, SHIFT.X, SHIFT.Y)
local id, res = T.inject(ACT, moved)
local b = T.findB(BT, c[1] + SHIFT.X, c[2] + SHIFT.Y)
out("replay result:", res, "| replica:", nm(b))
if b then
  local pts = {}; for i = 1, math.min(#b.fieldBorderPoints, 5) do pts[#pts + 1] = v3(b.fieldBorderPoints[i]) end
  out("replica owner is the lord:", tostring(nm(b.ownerPawn) == nm(p1)), "FieldPoints", #b.FieldPoints, "corners", #b.fieldBorderPoints, table.concat(pts, " "))
end
for i = #lines + 1, #T.test.lines() do out("SENT after replay", (T.test.lines()[i]:sub(1, 200))) end
if CLEANUP then
  out("cleanup requested: acting field", tostring(T.test.demolish(a)), "replica", tostring(T.test.demolish(b)))
end
T.test.uncap(); T.test.restoreFlags(st.flags); _G.__tt.field = nil
return "done"
