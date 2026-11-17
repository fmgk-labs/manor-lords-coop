-- t6_holds.lua  World module self-test 6: the friend's holds on its own random events. ONE copy, game PAUSED (no day
-- can pass, so no raid, camp or director action can happen). Never saves.
-- Raid and camp timer writes: proven live on one copy (README session 14). Director (W4c) and merchants (W4g): static.
-- Assumes the probe helper library is prepended and coop.lua + coop_world.lua are loaded and Coop is started.
-- Switches each hold on for one call, with a fake host raid value (current + 5), reads back, then restores every value.
-- PASS if: daysUntilNextRaid = old + 6, lastBanditCampSpawnedDay = today, scenario_nextActionDay = 2^30 (or no director
--   in this scenario), spawnMerchants = false after the call; every original value back at the end; no item switched
--   itself off (an item that cannot be written switches itself off and says so in the log).
-- Not tried here: ignoreRaiders (drawDebugFlags append proven live in session 14).
local C = rawget(_G, "Coop"); if not (C and C.s and C.world) then return "load coop.lua and coop_world.lua and start Coop first" end
local W, S = C.world, C.s
if not p1.bIsPlayerPaused then p1:pauseGame() end
if not W.prepare(S) then return "no lord pawn" end
local T = eng.TemporalComponent; local D = eng.questDirector
local hasD = D and D:IsValid()
local o = { u = T.daysUntilNextRaid, c = T.lastBanditCampSpawnedDay, m = eng.spawnMerchants }
if hasD then pcall(function() o.d = D.scenario_nextActionDay end) end
local today = eng:getDaysTotal()
local items = { "holdRaid", "holdCamp", "holdDirector", "holdMerchants" }
local savedOn, savedTimers, savedDry = {}, W.fr.timers, W.dry
for _, k in ipairs(items) do savedOn[k] = W.on[k] end
local a, offNow = {}, {}
out("BEFORE daysUntilNextRaid", o.u, "lastBanditCampSpawnedDay", o.c, "today", today, "spawnMerchants", tostring(o.m), "director", hasD and tostring(o.d) or "none")

local function body()
  for _, k in ipairs(items) do W.on[k] = true end
  W.fr.timers = { u = o.u + 5 }; W.dry = false
  W.holdsNow(S)
  a = { u = T.daysUntilNextRaid, c = T.lastBanditCampSpawnedDay, m = eng.spawnMerchants }
  if hasD then pcall(function() a.d = D.scenario_nextActionDay end) end
  for _, k in ipairs(items) do if not W.on[k] then offNow[#offNow + 1] = k end end
  out("AFTER  daysUntilNextRaid", a.u, "lastBanditCampSpawnedDay", a.c, "spawnMerchants", tostring(a.m), "director", hasD and tostring(a.d) or "none",
      "| switched themselves off:", #offNow == 0 and "none" or table.concat(offNow, ","))
end

local ok, e = pcall(body)
-- restore unconditionally
pcall(function() T.daysUntilNextRaid = o.u end); pcall(function() T.lastBanditCampSpawnedDay = o.c end); pcall(function() eng.spawnMerchants = o.m end)
if hasD and o.d then pcall(function() D.scenario_nextActionDay = o.d end) end
for _, k in ipairs(items) do W.on[k] = savedOn[k] end
W.fr.timers = savedTimers; W.dry = savedDry
local r = { u = T.daysUntilNextRaid, c = T.lastBanditCampSpawnedDay, m = eng.spawnMerchants }
if hasD then pcall(function() r.d = D.scenario_nextActionDay end) end
out("RESTORED daysUntilNextRaid", r.u, "lastBanditCampSpawnedDay", r.c, "spawnMerchants", tostring(r.m), "director", hasD and tostring(r.d) or "none")
if not ok then out("VERDICT", "FAIL (error: " .. tostring(e) .. ")"); return "error" end
local pass = a.u == o.u + 6 and a.c == today and a.m == false and (not hasD or a.d == W.cfg.director) and #offNow == 0
  and r.u == o.u and r.c == o.c and r.m == o.m and (not hasD or r.d == o.d)
out("VERDICT", pass and "PASS" or "FAIL")
return "ok"
