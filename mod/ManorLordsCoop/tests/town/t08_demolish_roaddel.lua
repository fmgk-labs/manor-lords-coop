-- t08_demolish_roaddel.lua  (town module: DEMOLISH and ROADDEL; ONE copy; run it five times; speed 0; nothing saved)
-- Both actions are static recipes (lane_t1 T5 / T5b). Only throwaway objects made by this test are removed.
-- Stage 1: the helper makes a logging camp (type 4) and a short road (proven recipes), "X".
-- Stage 2: DEMOLISH and ROADDEL are switched on. The lord demolishes camp X the way the UI does (append to
--          p1.demolishRequests; the pawn Tick drains it - lane_t1 T5, GUESS that the append works from Lua) and removes
--          road X with p1:removeRoad (the call the confirm button makes, GUESS which pawn it is called on).
-- Stage 3: prints the lines sent (expect "DEMOLISH 4,x,y,z" and "ROADDEL ax,ay,bx,by"), checks X is gone, makes camp and road
--          "Y" with the helper for the replay test.
-- Stage 4: feeds DEMOLISH / ROADDEL for Y as if a friend sent them (the host appends camp Y to the HELPER's
--          demolishRequests; never a direct demolish). Stage 5: checks the results and that Y is gone.
-- CONFIRMED = stage 3 shows both lines with X's keys and X gone; stage 5 shows both replays "ok" and Y gone, and no extra line.
-- RISK: medium-low: demolish and removeRoad on throwaway objects; a refund pile (type 88) may appear at the camp spot.
local OFF = { X = -7000.0, Y = 6000.0 }
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
-- placements were only proven at speed 0, never under pauseGame (t05-t07 pause): un-pause, then speed 0
if p1.bIsPlayerPaused then p1:unPauseGame() end
if eng.gameSpeed ~= 0.0 then p1:setGameSpeed(0.0) end
_G.__tt = _G.__tt or {}
local st = _G.__tt.dem
local function make(tag, dx)
  if T.buildCost(4) ~= 0 then error("type 4 has a treasury cost here: an unfunded helper placement can crash (HAZARDS); not placed") end
  local h = T.test.helper(); local L = p1:K2_GetActorLocation()
  local c = { X = L.X + OFF.X + dx, Y = L.Y + OFF.Y, Z = L.Z }
  h.placeBuilding = 4
  h.bbox:K2_SetWorldLocationAndRotation(c, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, false, {}, true)
  h.requestBuild = true
  local A = { X = c.X + 2500.0, Y = c.Y, Z = c.Z }; local B = { X = c.X + 4000.0, Y = c.Y + 600.0, Z = c.Z }
  h:setRoadMode(true, A, true); h.roadPoints[1] = A; h.roadPoints[2] = B
  local sp = h.dummyRoad.Spline; sp:ClearSplinePoints(true); sp:AddSplinePoint(A, 1, true); sp:AddSplinePoint(B, 1, true)
  local r = h:commitRoad()
  h:setRoadMode(false, { X = 0.0, Y = 0.0, Z = 0.0 }, false)
  out("made camp", tag, "at", v3(c), "and road", nm(r))
  return { c = c, A = A, B = B }
end
if not st then
  st = { flags = T.test.flags(), stage = 1 }; _G.__tt.dem = st
  st.X = T.quiet(make, "X", 0.0)
  return "stage 1 done; run again"
elseif st.stage == 1 then
  T.test.helper().placeBuilding = 0
  T.enable("DEMOLISH", true); T.enable("ROADDEL", true); out(T.test.hooksNow())
  local camp = T.findB(4, st.X.c.X, st.X.c.Y); local road = T.findRoad(st.X.A.X, st.X.A.Y, st.X.B.X, st.X.B.Y)
  out("camp X", nm(camp), "road X", nm(road))
  T.test.clearEcho(); T.test.cap()
  if camp then local ok, e = pcall(function() p1.demolishRequests[#p1.demolishRequests + 1] = camp end); out("appended camp X to p1.demolishRequests:", tostring(ok), e or "") end
  if road then p1:removeRoad(road) end
  T.test.pump()
  st.stage = 2
  return "stage 2 done (camp X is demolished by the lord's next Tick); run again"
elseif st.stage == 2 then
  T.test.pump()
  for _, l in ipairs(T.test.lines()) do out("SENT", l) end
  out("camp X still there:", tostring(T.findB(4, st.X.c.X, st.X.c.Y) ~= nil), "| road X still there:", tostring(T.findRoad(st.X.A.X, st.X.A.Y, st.X.B.X, st.X.B.Y) ~= nil))
  st.Y = T.quiet(make, "Y", 6000.0)
  st.n = #T.test.lines(); st.stage = 3
  return "stage 3 done; run again"
elseif st.stage == 3 then
  T.test.helper().placeBuilding = 0
  local c, A, B = st.Y.c, st.Y.A, st.Y.B
  local camp = T.findB(4, c.X, c.Y)
  local key = camp and (function() local l = camp:K2_GetActorLocation(); return string.format("4,%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end)() or "?"
  T.test.clearEcho()
  st.id1 = T.inject("DEMOLISH", key)
  st.id2 = T.inject("ROADDEL", string.format("%.0f,%.0f,%.0f,%.0f", A.X, A.Y, B.X, B.Y))
  st.stage = 4
  return "stage 4: DEMOLISH (helper demolish list) and ROADDEL fed in; run again"
else
  local c, A, B = st.Y.c, st.Y.A, st.Y.B
  T.test.pump()
  out("DEMOLISH replay ->", tostring(T.test.result(st.id1)), "| camp Y still there:", tostring(T.findB(4, c.X, c.Y) ~= nil))
  out("ROADDEL replay ->", tostring(T.test.result(st.id2)), "| road Y still there:", tostring(T.findRoad(A.X, A.Y, B.X, B.Y) ~= nil))
  local lines = T.test.lines()
  for i = st.n + 1, #lines do out("SENT after the replays", lines[i]) end
  T.test.uncap(); T.test.restoreFlags(st.flags); _G.__tt.dem = nil
  return "done"
end
