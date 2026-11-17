-- t09_move.lua  (town module: MOVE = relocating a building; ONE copy; run it five times; speed 0; nothing saved)
-- Static recipe (lane_t1 T8d): build() raises playBuildEffects before it reads movedBuilding, so the BUILD hook sees a move;
-- the replay sets movedBuilding + placeBuilding + bbox + requestBuild on the helper.
-- Stage 1: the helper makes camp P at P0 (proven placement).
-- Stage 2: MOVE on; the lord relocates camp P to P1 (p1.movedBuilding = P; placeBuilding; bbox; requestBuild) - stands for the
--          relocate button and the click.
-- Stage 3: prints what was sent (expect ONE line "MOVE 4,P0... 4,P1...,yaw" and NO "BUILD" line), checks P0 empty and P1
--          taken; makes camp Q at Q0 for the replay.
-- Stage 4: feeds "MOVE Q0 -> Q1" as if a friend sent it (helper placement, pending).
-- Stage 5: result, Q0 empty, Q1 taken, silver; removes the test camps; restores the lord's silver.
-- CONFIRMED = stage 3: exactly one MOVE line, no BUILD line, one camp at P1, none at P0; stage 5: result "ok", one camp at Q1,
--   none at Q0, the helper's charge moved to the lord (lord silver lower by the move cost, helper 0).
-- RISK: medium: movedBuilding writes on pawns (static). A failed move leaves a helper with movedBuilding set; the module
--   refuses further helper placements then (clearMoved) until a reload.
local P0 = { X = -8000.0, Y = -6000.0 }; local DP = { X = 1500.0, Y = 0.0 }
local Q0 = { X = -8000.0, Y = -9000.0 }
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
-- placements were only proven at speed 0, never under pauseGame (t05-t07 pause): un-pause, then speed 0
if p1.bIsPlayerPaused then p1:unPauseGame() end
if eng.gameSpeed ~= 0.0 then p1:setGameSpeed(0.0) end
_G.__tt = _G.__tt or {}
local st = _G.__tt.move
-- positions are kept relative to where the lord pawn (the camera) was at stage 1: the camera may move between runs
local L = (st and st.L) or p1:K2_GetActorLocation()
local function camp(at)
  if T.buildCost(4) ~= 0 then error("type 4 has a treasury cost here: an unfunded helper placement can crash (HAZARDS); not placed") end
  local h = T.test.helper()
  h.placeBuilding = 4
  h.bbox:K2_SetWorldLocationAndRotation({ X = L.X + at.X, Y = L.Y + at.Y, Z = L.Z }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, false, {}, true)
  h.requestBuild = true
end
local function count(at) local n = 0; for i = 1, #eng.buildingArr do local b = un(eng.buildingArr[i]); if b:IsValid() and b:GetType() == 4 then local l = b:K2_GetActorLocation(); if math.abs(l.X - L.X - at.X) < 150 and math.abs(l.Y - L.Y - at.Y) < 150 then n = n + 1 end end end; return n end
local function plus(a, d) return { X = a.X + d.X, Y = a.Y + d.Y } end
if not st then
  st = { flags = T.test.flags(), stage = 1, s0 = p1.silver, L = { X = L.X, Y = L.Y, Z = L.Z } }; _G.__tt.move = st
  T.quiet(camp, P0)
  return "stage 1: camp P requested; run again"
elseif st.stage == 1 then
  T.test.helper().placeBuilding = 0
  T.enable("MOVE", true); T.enable("BUILD", true); out(T.test.hooksNow())
  local old = T.findB(4, L.X + P0.X, L.Y + P0.Y)
  if not old then return "camp P not found; run again or move P0" end
  T.test.clearEcho(); T.test.cap()
  local p = plus(P0, DP)
  p1.movedBuilding = old; p1.placeBuilding = 4
  p1.bbox:K2_SetWorldLocationAndRotation({ X = L.X + p.X, Y = L.Y + p.Y, Z = L.Z }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, false, {}, true)
  p1.requestBuild = true
  st.stage = 2
  return "stage 2: the lord relocates camp P; run again"
elseif st.stage == 2 then
  p1.placeBuilding = 0
  for _, l in ipairs(T.test.lines()) do out("SENT", l) end
  out("camps at P0", count(P0), "at P1", count(plus(P0, DP)), "| lord.movedBuilding now", nm(p1.movedBuilding))
  T.quiet(camp, Q0)
  st.n = #T.test.lines(); st.stage = 3
  return "stage 3: camp Q requested for the replay; run again"
elseif st.stage == 3 then
  local h = T.test.helper(); h.placeBuilding = 0
  local q = T.findB(4, L.X + Q0.X, L.Y + Q0.Y)
  if not q then return "camp Q not found; run again" end
  local ql = q:K2_GetActorLocation(); local q1 = plus(Q0, DP)
  st.s1 = p1.silver
  local fields = string.format("4,%.0f,%.0f,%.0f 4,%.0f,%.0f,%.0f,0.0", ql.X, ql.Y, ql.Z, L.X + q1.X, L.Y + q1.Y, L.Z)
  local id, r = T.inject("MOVE", fields)
  st.id = id; st.stage = 4
  out("injected MOVE", fields, "->", r)
  return "stage 4: replay requested; run again"
else
  local h = T.test.helper()
  out("replay result", tostring(T.test.result(st.id)), "| camps at Q0", count(Q0), "at Q1", count(plus(Q0, DP)), "| helper.movedBuilding", nm(h.movedBuilding))
  out("lord silver", st.s1, "->", p1.silver, "| helper silver", h.silver)
  local lines = T.test.lines(); for i = (st.n or 0) + 1, #lines do out("SENT after the replay", lines[i]) end
  T.quiet(function()
    for _, at in ipairs({ P0, plus(P0, DP), Q0, plus(Q0, DP) }) do local b = T.findB(4, L.X + at.X, L.Y + at.Y); if b then T.test.demolish(b) end end
  end)
  p1:changeSilver(st.s0 - p1.silver)
  T.test.uncap(); T.test.restoreFlags(st.flags); _G.__tt.move = nil
  return "done (test camps sent to the helper's demolish list, lord silver back to " .. p1.silver .. ")"
end
