-- t00_status.lua  (town module: status only; changes nothing)
-- Assumes: the probe helper library is prepended (eng, p1, sc, nm, v3, un, out), Coop is started
-- (Coop.start("host", "host", {}) for one-copy tests) and coop_town.lua is loaded.
-- CONFIRMED = the module is registered; the default actions are on (live: BUILD ROAD FIELD; live1: PLIM PUNLIM TTARGET
-- TGLOBAL TRULE TPART SLEEP PRIO MAINT ADDW REMW, FAMS follows) and their hooks registered (about 2 s after load);
-- 0 hook errors; the index holds about as many buildings and roads as the world.
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
out(T.status())
out("actions:", T.list())
out("core:", Coop.status())
for path in pairs(_G.__coop_town_hooks or {}) do out("hook registered:", path) end
for path, n in pairs(T.hookFail or {}) do out("hook failed so far", n, "times:", path) end
out("world: buildings", #eng.buildingArr, "roads", #eng.roads, "regions", #eng.regions, "gameSpeed", eng.gameSpeed)
return "ok"
