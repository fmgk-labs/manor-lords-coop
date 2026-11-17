-- t7_events_dry.lua  World module self-test 7: how the friend reacts to host events and weather, as a DRY RUN.
-- Nothing in the world changes: W.dry = true makes every friend write print instead of happen. Never saves.
-- Assumes the probe helper library is prepended and coop.lua + coop_world.lua are loaded and Coop is started.
-- Feeds hand-built lines: E RAID, E FIRE / E FIREOUT on one of the lord's buildings, E MERCH (one more than here),
--   E CAMP, X (weather targets: rainMeter + 3), T (timers). Items fire, fireOut, merch, weather, holdRaid are switched
--   on for the test; driftHook is switched off (so E CAMP only logs "DRIFT").
-- PASS if: the dry log lists raid timers, StartFire <key> (only if that building is not burning), weather rainMeter,
--   spawnFreeMerchant, and the drift counter went up by one for the camp.
-- Restores (also after an error): dry run off, switches and stored values as they were.
local C = rawget(_G, "Coop"); if not (C and C.s and C.world) then return "load coop.lua and coop_world.lua and start Coop first" end
local W, S, A = C.world, C.s, C.api
if not p1.bIsPlayerPaused then p1:pauseGame() end
if not W.prepare(S) then return "no lord pawn" end
local key
for i = 1, #eng.buildingArr do local b = un(eng.buildingArr[i]); if b:IsValid() and W.isMine(b.ownerPawn) and b:IsConstructed() and not b.onFire then key = W.bkey(b); break end end
local names = { "fire", "fireOut", "merch", "weather", "holdRaid", "driftHook" }
local saved = { dry = W.dry, timers = W.fr.timers, wx = W.fr.wx, pend = W.fr.firePend, drift = W.lastDrift }
for _, k in ipairs(names) do saved[k] = W.on[k] end
local drifts0 = S.stats.w_drift or 0
local has = {}

local function body()
  W.on.fire, W.on.fireOut, W.on.merch, W.on.weather, W.on.holdRaid, W.on.driftHook = true, true, true, true, true, false
  W.dry = true; W.dryLog = {}; W.fr.firePend = {}
  local function feed(text) local line = string.format("%d %.3f %s", 0, A.now(), text); W.apply(S, A.words(line)); out("  fed:", text) end
  local T = eng.TemporalComponent
  feed(string.format("W E RAID %d %d", T.daysUntilNextRaid + 200, 0))
  if key then feed("W E FIRE " .. key); W.applyNow(S, "fire"); feed("W E FIREOUT " .. key); W.applyNow(S, "fire") end
  feed(string.format("W E MERCH %d %d", #eng.freeMerchants + 1, #eng.livestockMerchants))
  feed("W E CAMP " .. eng:getDaysTotal())
  local wx = string.format("%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,%d,%d,%d", T.targetRaining, T.targetSnowing, T.targetCloudiness, T.windTarget, T.snowTarget,
    T.droughtLevel, T.rainMeter + 3, T.daysWithoutRainVariation, T.isDrought and 1 or 0, T.enableThunderstorm and 1 or 0)
  feed(string.format("W X %d %s", eng:getDaysTotal(), wx))
  feed(string.format("W T %d %d %d -", T.daysUntilNextRaid, T.daysSinceLastRaid, T.lastBanditCampSpawnedDay))
  W.holdsNow(S)
  out("DRY LOG (what a friend would have written):")
  for _, l in ipairs(W.dryLog) do
    out("   ", l)
    if l:find("^raid timers") then has.raid = true end
    if l:find("^StartFire") then has.fire = true end
    if l:find("^weather rainMeter") then has.weather = true end
    if l:find("^spawnFreeMerchant") then has.merch = true end
  end
end

local ok, e = pcall(body)
W.dry = saved.dry; W.fr.timers = saved.timers; W.fr.wx = saved.wx; W.fr.firePend = saved.pend
for _, k in ipairs(names) do W.on[k] = saved[k] end
local drifts = (S.stats.w_drift or 0) - drifts0
out("drift reports", drifts, "last:", tostring(W.lastDrift))
W.lastDrift = saved.drift
if not ok then out("VERDICT", "FAIL (error: " .. tostring(e) .. ")"); return "error" end
local pass = has.raid and has.weather and has.merch and (has.fire or not key) and drifts == 1
out("VERDICT", pass and "PASS" or "FAIL", key and "" or "(no building for the fire part)")
return "ok"
