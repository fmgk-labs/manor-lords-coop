-- t03_road.lua  (town module: ROAD seen on the local lord and replayed through the helper; one run)
-- 1. The local lord commits a 3-point road with the proven named recipe (README session 7c r1.lua / session 8 A_road.lua);
--    this stands for the player's click and fires the commitRoad hook on p1. It replaces the player's own road draft.
-- 2. Coop.town.test.pump() processes the hook record now: expect one line "T host <n> ROAD x,y,z|x,y,z|x,y,z" whose points
--    are the new road's spline points (this two-phase capture is the part that has not run live yet).
-- 3. The same line, moved by SHIFT, is fed in as if a friend sent it: the host replays it through the helper (proven recipe).
-- 4. CLEANUP removes both roads with helper:removeRoad (lane_t1 T5b, static: if that fails, the two short test roads stay
--    until the save is reloaded; nothing is saved).
-- CONFIRMED = one ROAD line with 3 points near the asked ones; replay result "ok"; a road with the shifted ends exists;
--   the forwarded line "T selftest <n> ROAD ..." was captured; no second ROAD line was sent for the replay (echo blocked).
-- RISK: low (proven road path).
local OFF = { X = 3500.0, Y = -3000.0 }
local SHIFT = { X = 0.0, Y = -2500.0 }
local CLEANUP = true
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
if eng.gameSpeed ~= 0.0 then p1:setGameSpeed(0.0) end
local flags = T.test.flags()
T.enable("ROAD", true); T.test.hooksNow()
local L = p1:K2_GetActorLocation()
local A = { X = L.X + OFF.X, Y = L.Y + OFF.Y, Z = L.Z }
local M = { X = A.X + 700.0, Y = A.Y - 600.0, Z = L.Z }
local E = { X = A.X + 1500.0, Y = A.Y - 800.0, Z = L.Z }
local n0 = #eng.roads
T.test.cap()
p1.placeBuilding = 0
p1:setRoadMode(true, A, true); p1.roadPoints[1] = A; p1.roadPoints[2] = M; p1.roadPoints[3] = E
local sp = p1.dummyRoad.Spline; sp:ClearSplinePoints(true); sp:AddSplinePoint(A, 1, true); sp:AddSplinePoint(M, 1, true); sp:AddSplinePoint(E, 1, true)
local r1 = p1:commitRoad()
p1:setRoadMode(false, { X = 0.0, Y = 0.0, Z = 0.0 }, false)
out("acting road:", nm(r1), "roads", n0, "->", #eng.roads)
T.test.pump()
local lines = T.test.lines()
for _, l in ipairs(lines) do out("SENT", l) end
local act, fields = T.test.fieldsOf(lines[1] or "")
if act ~= "ROAD" then T.test.uncap(); T.test.restoreFlags(flags); return "no ROAD line was sent: SEE failed" end
local moved = T.test.shift("ROAD", fields, SHIFT.X, SHIFT.Y)
local id, res = T.inject("ROAD", moved)
local r2 = T.findRoad(A.X + SHIFT.X, A.Y + SHIFT.Y, E.X + SHIFT.X, E.Y + SHIFT.Y)
out("replay result:", res, "| shifted road found:", nm(r2), "| roads now", #eng.roads)
for i = #lines + 1, #T.test.lines() do out("SENT after replay", T.test.lines()[i]) end
if CLEANUP then
  local h = T.test.helper()
  local ok, e = pcall(function() T.quiet(function() if r1 and r1:IsValid() then h:removeRoad(r1) end; if r2 and r2:IsValid() then h:removeRoad(r2) end end) end)
  out("cleanup removeRoad:", tostring(ok), e or "", "| roads now", #eng.roads, "(was", n0, ")")
end
T.test.uncap(); T.test.restoreFlags(flags)
return "done"
