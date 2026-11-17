-- t02_build.lua  (town module: BUILD seen on the local lord, replayed through the funded helper, T14 cost charged to the lord)
-- Run it four times on ONE copy (stages 1 to 4). Speed is set to 0; nothing is saved.
-- Stage 1: the local lord places a building (placeBuilding + bbox + requestBuild on p1: the same flag the click sets,
--          README session 7b). This stands for the player's click. It clears the player's own building draft.
--          If the lord cannot pay the type twice, the test first gives him the missing silver (taken back at the end).
-- Stage 2: prints what the module sent (expect one line "T host <n> BUILD t,x,y,z,yaw"), then feeds the same BUILD, moved
--          to a second spot, into the module as if a friend had sent it (Coop.town.inject). The host checks the lord can
--          afford it, funds the helper with exactly the cost, and sets requestBuild on the helper.
-- Stage 3: prints the replay result, the forwarded line ("T selftest <n> BUILD ..."), the lord's and the helper's silver,
--          then asks the helper to demolish both test buildings (its demolishRequests list, as the click does).
-- Stage 4: checks both are gone and puts the lord's silver back.
-- CONFIRMED = stage 2: exactly one BUILD line with the right type and position; stage 3: result "ok", a building of the type
--   at the second spot owned by the lord, the forwarded line, the lord's silver lower by the cost once more (host charge,
--   ChangeTreasury) and the helper at 0; stage 4: both gone (a goods pile of type 88 may remain: refund).
-- RISK: the costed helper placement crashed twice while the helper was unfunded; funded with cost + 100 it worked (README
--   session 14). The module funds it with EXACTLY the cost: this test is the first to show that exact funding is enough.
--   If unsure, run TYPE = 4 (cost-free) first.
local TYPE = 52                               -- 52 costs 50 in the test save; 4 (logging camp) for a cost-free run
local OFF_A = { X = -7000.0, Y = 6000.0 }     -- acting placement, relative to the lord pawn at stage 1
local OFF_B = { X = -7000.0, Y = 9500.0 }     -- replay placement
local YAW = 20.0
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
-- placements were only proven at speed 0, never under pauseGame (t05-t07 pause): un-pause, then speed 0
if p1.bIsPlayerPaused then p1:unPauseGame() end
if eng.gameSpeed ~= 0.0 then p1:setGameSpeed(0.0) end
_G.__tt = _G.__tt or {}
local st = _G.__tt.build
if not st then
  local t = TYPE
  local cost = T.buildCost(t)
  if cost == nil then return "cost of type " .. t .. " unreadable: pick another TYPE" end
  local L = p1:K2_GetActorLocation()
  st = { t = t, cost = cost, ax = L.X + OFF_A.X, ay = L.Y + OFF_A.Y, bx = L.X + OFF_B.X, by = L.Y + OFF_B.Y, z = L.Z, s0 = p1.silver, flags = T.test.flags() }
  if p1.silver < 2 * cost then p1:changeSilver(2 * cost - p1.silver); out("lord given silver for the test:", st.s0, "->", p1.silver) end
  _G.__tt.build = st
  T.enable("BUILD", true); T.test.hooksNow()
  T.test.cap()
  p1.placeBuilding = t
  p1.bbox:K2_SetWorldLocationAndRotation({ X = st.ax, Y = st.ay, Z = st.z }, { Pitch = 0.0, Yaw = YAW, Roll = 0.0 }, false, {}, true)
  p1.requestBuild = true
  st.stage = 1
  return string.format("stage 1: lord places type %d (cost %d) at %.0f,%.0f; run again", t, cost, st.ax, st.ay)
elseif st.stage == 1 then
  p1.placeBuilding = 0
  local a = T.findB(st.t, st.ax, st.ay)
  out("acting placement made:", tostring(a ~= nil), "| lord silver now", p1.silver)
  for _, l in ipairs(T.test.lines()) do out("SENT", l) end
  st.s1 = p1.silver
  local fields = string.format("%d,%.0f,%.0f,%.0f,%.1f", st.t, st.bx, st.by, st.z, YAW)
  local id, r = T.inject("BUILD", fields)
  st.id = id; st.stage = 2
  out("injected BUILD", fields, "->", r, "| helper silver", T.test.helper().silver)
  return "stage 2: replay requested through the helper; run again"
elseif st.stage == 2 then
  local r = T.test.result(st.id)
  local a = T.findB(st.t, st.ax, st.ay); local b = T.findB(st.t, st.bx, st.by)
  local h = T.test.helper()
  out("replay result:", tostring(r), "| building at the second spot:", tostring(b ~= nil), "owner is the lord:", b and tostring(nm(b.ownerPawn) == nm(p1)) or "-")
  out("lord silver", st.s1, "->", p1.silver, "(expected change", -st.cost, ") | helper silver now", h.silver, "(expected 0)")
  for _, l in ipairs(T.test.lines()) do out("SENT", l) end
  out("cleanup requested:", tostring(T.test.demolish(a)), tostring(T.test.demolish(b)))
  st.stage = 3
  return "stage 3: run again to check the cleanup"
else
  out("acting building still there:", tostring(T.findB(st.t, st.ax, st.ay) ~= nil), "| replica still there:", tostring(T.findB(st.t, st.bx, st.by) ~= nil))
  p1:changeSilver(st.s0 - p1.silver)
  out("lord silver back to", p1.silver)
  T.test.uncap(); T.test.restoreFlags(st.flags); _G.__tt.build = nil
  return "done"
end
