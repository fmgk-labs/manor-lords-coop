-- t11_house_plot.lua  (town module: HOUSE = residential plots; ONE copy; needs one real plot commit by hand)
-- Run 1: switches HOUSE on, registers the addCommitFieldRequest hook (shared with FIELD), starts capturing. The operator then
--   draws and commits ONE residential plot by hand.
-- Run 2: prints the captured HOUSE line (number of lots, line length) and the first lot's parts. Nothing else unless DO_REPLAY.
-- DO_REPLAY = true: feeds the captured line moved by SHIFT as if a friend sent it: the host writes extractedPlots on the
--   helper (setFieldMode(true, 3) first) and calls commitField (lane_t1 T4). Prints how many type-3 buildings appeared and
--   asks the helper to demolish them when CLEANUP (its demolishRequests list; never a direct demolish).
-- CONFIRMED = run 2 shows one HOUSE line with as many lots as the plot had; DO_REPLAY gives "ok" and the same number of new
--   type-3 buildings at the shifted spots, owned by the lord.
-- RISK: HIGH for DO_REPLAY: writing nested arrays and transforms into a struct array element from Lua is untried in this
--   UE4SS build; a wrong write could crash the game. Run it last, on coop_test_1, nothing to lose.
local DO_REPLAY = false
local SHIFT = { X = 0.0, Y = 6000.0 }
local CLEANUP = true
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
_G.__tt = _G.__tt or {}
local st = _G.__tt.house
if not st then
  st = { flags = T.test.flags() }; _G.__tt.house = st
  T.enable("HOUSE", true); out(T.test.hooksNow()); T.test.cap()
  return "capturing: commit one residential plot by hand, then run again"
end
local line
for _, l in ipairs(T.test.lines()) do if T.test.fieldsOf(l) == "HOUSE" then line = l end end
if not line then out(T.status()); return "no HOUSE line yet (the module sends it once the first lot exists); run again" end
local _, fields = T.test.fieldsOf(line)
local lots = {}; for w in fields:gmatch("%S+") do lots[#lots + 1] = w end
out("HOUSE line:", #line, "chars,", #lots, "lots")
local parts = {}; for p in (lots[1] .. "/"):gmatch("(.-)/") do parts[#parts + 1] = p end
local names = { "smoothBorder", "corners", "primary", "secondary", "extension", "backFacade", "extSmooth", "extCorners" }
for i, p in ipairs(parts) do out("  lot 1", names[i] or i, (p:sub(1, 160))) end
if DO_REPLAY then
  if eng.gameSpeed ~= 0.0 then p1:setGameSpeed(0.0) end
  local n0 = #eng.buildingArr
  local moved = T.test.shift("HOUSE", fields, SHIFT.X, SHIFT.Y)
  local _, r = T.inject("HOUSE", moved)
  local made = {}
  for i = n0 + 1, #eng.buildingArr do local b = un(eng.buildingArr[i]); if b:IsValid() and b:GetType() == 3 then made[#made + 1] = b end end
  out("replay ->", r, "| new type-3 buildings", #made)
  for _, b in ipairs(made) do out("  ", v3(b:K2_GetActorLocation()), "owner lord", tostring(nm(b.ownerPawn) == nm(p1)), "FieldPoints", #b.FieldPoints, "corners", #b.fieldBorderPoints) end
  if CLEANUP then local n = 0; for _, b in ipairs(made) do if T.test.demolish(b) then n = n + 1 end end; out("demolish requested for", n, "of", #made) end
end
T.test.uncap(); T.test.restoreFlags(st.flags); _G.__tt.house = nil
return "done"
