-- t05_region_setters.lua  (town module: region setters SEE + REPLAY round trips on ONE copy; one run; restores every value)
-- These functions are called only through reflection (lane_t2 report, rule 0), so a scripted call fires the same hook as
-- the UI button. For each action:
--   SEE    : call the setter on the lord's region with a changed value (as the button would), pump the module, print the line
--            it would send (expect "T host <n> <ACT> <regionkey> <args>");
--   REPLAY : feed the action back with the ORIGINAL value as if a friend had sent it; the host runs the same call on the
--            region found by its unique tag; check the value is the original again (that is also the restore);
--   echo   : no second line may appear for the replay.
-- CONFIRMED = every action prints one SEE line with the right args, "replay ok" and "value back: true", and "extra lines 0".
-- RISK: low; values change for an instant. changeTargetInventory starts merchant tasks at once (lane_t2 T9b).
local G = 16                         -- good id for the per-good settings (setProductionLimit(16, ...) was seen live, session 7c)
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
if not p1.bIsPlayerPaused then p1:pauseGame() end
local flags = T.test.flags()
for _, a in ipairs({ "PLIM", "PUNLIM", "TTARGET", "TGLOBAL", "TAX", "TRULE", "TPART" }) do T.enable(a, true) end
out(T.test.hooksNow())
local R
for i = 1, #eng.regions do local r = un(eng.regions[i]); if r:IsValid() and nm(r.ownerPawn) == nm(p1) then if r.isSettled then R = r; break end; R = R or r end end
if not R then T.test.restoreFlags(flags); return "no region owned by the lord" end
local key = T.rkey(R)
out("region", R.regionName:ToString(), "key", key)

local function step(act, see, args0, back, prep)
  T.test.clearEcho()
  T.test.cap(); local ok, e = pcall(see); T.test.pump(); local seen = T.test.uncap()
  out(act, "SEE call ok", tostring(ok), e or "", "| line:", seen[1] or "NOTHING SENT", #seen > 1 and ("(+" .. (#seen - 1) .. " more)") or "")
  if prep then T.quiet(prep) end
  T.test.cap(); local _, res = T.inject(act, key .. " " .. args0); T.test.pump(); local after = T.test.uncap()
  local extra = 0; for _, l in ipairs(after) do if not l:find("T selftest", 1, true) then extra = extra + 1 end end
  local okb, isBack = pcall(back)
  out(act, "REPLAY", args0, "->", tostring(res), "| value back:", tostring(okb and isBack), "| forwarded:", tostring(after[1] ~= nil), "| extra lines", extra)
end

-- production limit
local wasLimited = R:isProductionLimited(G); local lim0 = R:getProductionLimit(G, -1)
out("production limit of", G, "limited", tostring(wasLimited), "limit", lim0)
step("PLIM", function() R:setProductionLimit(G, 7) end, G .. "," .. (wasLimited and lim0 or 9), function() return R:getProductionLimit(G, -1) == (wasLimited and lim0 or 9) end)
step("PUNLIM", function() R:setProductionUnlimited(G) end, tostring(G), function() return R:isProductionLimited(G) == false end,
  function() R:setProductionLimit(G, 5) end)
T.quiet(function() if wasLimited then R:setProductionLimit(G, lim0) else R:setProductionUnlimited(G) end end)
out("production limit restored:", tostring(R:isProductionLimited(G) == wasLimited), R:getProductionLimit(G, -1))
-- trade target amount
local t0 = R:GetTargetInventory(G)
step("TTARGET", function() R:changeTargetInventory(G, t0 + 5) end, G .. "," .. t0, function() return R:GetTargetInventory(G) == t0 end)
-- global trade checkbox
local a0 = R:isGlobalTradeAllowedForGood(G)
step("TGLOBAL", function() R:setGlobalTradeAllowedForGood(G, not a0) end, G .. "," .. (a0 and "1" or "0"), function() return R:isGlobalTradeAllowedForGood(G) == a0 end)
-- taxes: only keys already in the map (changeTaxRate adds a key for an unknown name, lane_t2 T11 probe)
local keys = {}
pcall(function() R.taxRates:ForEach(function(k, v) keys[#keys + 1] = k:get():ToString() end) end)
if #keys == 0 then out("TAX skipped: taxRates map not readable") end
for _, tn in ipairs(keys) do
  local f = FName(tn); local r0 = R:getTaxRate(f); local r1 = (r0 >= 5) and r0 - 1 or r0 + 1
  step("TAX", function() R:changeTaxRate(f, r1) end, tn .. "," .. r0, function() return R:getTaxRate(f) == r0 end)
end
-- trade rule and partner limit: no getter; only if the per-good arrays read as numbers (lane_t2 T9 probe)
local okr, rule0 = pcall(function() return un(R.tradeRules[G + 1]) end)
if okr and type(rule0) == "number" then
  step("TRULE", function() R:changeTradeRule(G, (rule0 == 3) and 1 or 3) end, G .. "," .. rule0, function() return un(R.tradeRules[G + 1]) == rule0 end)
else out("TRULE skipped: tradeRules not readable per good") end
local okp, part0 = pcall(function() return un(R.tradePartnerLimits[G + 1]) end)
if okp and type(part0) == "number" then
  step("TPART", function() R:changeTradePartnerLimit(G, (part0 == 2) and 1 or 2) end, G .. "," .. part0, function() return un(R.tradePartnerLimits[G + 1]) == part0 end)
else out("TPART skipped: tradePartnerLimits not readable per good") end
T.test.restoreFlags(flags)
return "done"
