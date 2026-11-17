-- t12_purchases.lua  (town module: TROUTE = buy a trade route, LIVESTOCK = order livestock; ONE copy; irreversible)
-- Default run: read-only. Prints, for good G in the lord's region: trade route level and unlock price, regional wealth,
-- nextLivestockOrderIn, and whether the two hooks are registered.
-- DO_TROUTE = true (coop_test_1 only, reload after): R:unlockOneTradeLevel(G) as the confirm button would - pays regional
--   wealth natively (lane_t2 T9e) - then pumps: expect "T host <n> TROUTE <regionkey> <G>". The replay is the same generic
--   region call as in t05; it is NOT run here because on one copy it would buy a second level.
-- DO_LIVESTOCK = true with LIVE_BUILDING_TYPE and LIVE_ANIMAL set (coop_test_1 only): b:orderLivestock(LIVE_ANIMAL) on the
--   first lord building of that type - spawns a livestock merchant (lane_t2 T9f) - then pumps: expect "LIVESTOCK <b> <type>".
--   Livestock bought as an upgrade ("Order oxen" ...) goes through UPGRADE instead (t10).
-- CONFIRMED = one line per purchase with the right key and value, wealth lower by the printed price.
-- RISK: changes the world (wealth spent, a merchant spawned). Never saves.
local G = 16
local DO_TROUTE = false
local DO_LIVESTOCK = false
local LIVE_BUILDING_TYPE, LIVE_ANIMAL = nil, nil
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
local R
for i = 1, #eng.regions do local r = un(eng.regions[i]); if r:IsValid() and nm(r.ownerPawn) == nm(p1) then if r.isSettled then R = r; break end; R = R or r end end
if not R then return "no region owned by the lord" end
local flags = T.test.flags()
T.enable("TROUTE", true); T.enable("LIVESTOCK", true); out(T.test.hooksNow())
local lvl, price = "?", "?"
pcall(function() lvl = R:getTradeRouteLevel(G) end); pcall(function() price = R:getUnlockTradeLevelPriceForGoodType(G) end)
out("region", T.rkey(R), "good", G, "route level", tostring(lvl), "unlock price", tostring(price), "wealth", R.regionalWealth, "nextLivestockOrderIn", R.nextLivestockOrderIn)
T.test.clearEcho(); T.test.cap()
if DO_TROUTE then local w0 = R.regionalWealth; local ok = R:unlockOneTradeLevel(G); out("unlockOneTradeLevel ->", tostring(ok), "wealth", w0, "->", R.regionalWealth) end
if DO_LIVESTOCK and LIVE_BUILDING_TYPE and LIVE_ANIMAL then
  for i = 1, #eng.buildingArr do
    local b = un(eng.buildingArr[i])
    if b:IsValid() and b:GetType() == LIVE_BUILDING_TYPE and nm(b.ownerPawn) == nm(p1) then out("orderLivestock ->", tostring(b:orderLivestock(LIVE_ANIMAL))); break end
  end
end
T.test.pump()
for _, l in ipairs(T.test.uncap()) do out("SENT", l) end
T.test.restoreFlags(flags)
return "done"
