-- t2_stock_fake.lua  World module self-test 2: a fake host message moves the home region's stock, treasury and
-- regional wealth on THIS copy, then a second message puts them back. ONE copy, game PAUSED. Never saves.
-- Uses only the session-9-proven calls (grantResources / consumeGood / silver / regionalWealth).
-- Assumes the probe helper library is prepended and coop.lua + coop_world.lua are loaded and Coop is started.
-- Best started as "friend": the lines then go through the real entry point (Coop.dispatch -> onMessage with its role,
--   sender and stale checks). As "host" the test falls back to Coop.world.apply and says so.
--   Note: as friend the core also runs friendUpkeep on this copy (disableAI flag, soldier stat writes).
-- Also two negatives (friend only): a line stamped before this copy started is dropped (w_stale +1, no change), and a
--   W line from a sender other than "host" is ignored (w_ignored +1, no change).
-- PASS if: good g goes v -> v+1 -> v, silver s -> s+7 -> s, wealth w -> w+3 -> w, and the negatives behave.
-- Restores (also after an error): the stock, silver and wealth, the module's stored host values and switches.
local C = rawget(_G, "Coop"); if not (C and C.s and C.world) then return "load coop.lua and coop_world.lua and start Coop first" end
local W, S, A = C.world, C.s, C.api
if not p1.bIsPlayerPaused then p1:pauseGame() end
if not W.prepare(S) then return "no lord pawn" end
local home = p1:getClosestOwnedRegion()
if not home:IsValid() then return "no home region" end
local rk = W.rkey(home)
local g, v
for _, t in ipairs(W.goodsList(S)) do local x = home:getStockOfGood(t, false, false); if x >= 1 then g, v = t, x; break end end
if not g then return "no good with stock >= 1 in the home region" end
local s0, w0 = p1.silver, home.regionalWealth
local saved = { reg = W.fr.reg[rk], lord = W.fr.lord, stock = W.on.stock, silver = W.on.silver, wealth = W.on.wealth, dry = W.dry, capture = W.capture }
local viaCore = S.role == "friend"
local pass = true

local function body()
  W.on.stock, W.on.silver, W.on.wealth, W.dry, W.capture = true, true, true, false, nil
  W.fr.reg[rk] = nil; W.fr.lord = {}
  local function feed(text, wall, from)
    local line = string.format("%d %.3f %s", 0, wall or A.now(), text)
    local w = A.words(line)
    local t0 = os.clock()
    if viaCore then C.dispatch(from or "host", w, line) else W.apply(S, w) end
    W.applyNow(S, "reg")
    out("  fed:", text, viaCore and "(via Coop.dispatch)" or "(via Coop.world.apply)", string.format("%.2f ms", (os.clock() - t0) * 1000))
  end
  local function check(tag, got, want) local ok = got == want; pass = pass and ok; out(" ", tag, "got", got, "want", want, ok and "ok" or "WRONG") end
  out("home region", rk, "good", g, "stock", v, "silver", s0, "wealth", w0, "| role", S.role)
  feed(string.format("W R %s h %d=%d", rk, g, v + 1));  check("stock after +1", home:getStockOfGood(g, false, false), v + 1)
  feed(string.format("W R %s h %d=%d", rk, g, v));      check("stock back", home:getStockOfGood(g, false, false), v)
  feed(string.format("W L s=%d", s0 + 7));             check("silver after +7", p1.silver, s0 + 7)
  feed(string.format("W L s=%d", s0));                 check("silver back", p1.silver, s0)
  feed(string.format("W R %s h w=%d", rk, w0 + 3));    check("wealth after +3", home.regionalWealth, w0 + 3)
  feed(string.format("W R %s h w=%d", rk, w0));        check("wealth back", home.regionalWealth, w0)
  if viaCore then
    local st0, ig0 = S.stats.w_stale or 0, S.stats.w_ignored or 0
    feed(string.format("W R %s h %d=%d", rk, g, v + 1), S.startWall - 10)
    check("old line dropped: stock", home:getStockOfGood(g, false, false), v); check("w_stale +1", (S.stats.w_stale or 0) - st0, 1)
    feed(string.format("W R %s h %d=%d", rk, g, v + 1), nil, "someone")
    check("foreign sender ignored: stock", home:getStockOfGood(g, false, false), v); check("w_ignored +1", (S.stats.w_ignored or 0) - ig0, 1)
  else
    out("  negatives skipped: Coop is not started as friend")
  end
end

local ok, err = pcall(body)
-- restore unconditionally
local cur = home:getStockOfGood(g, false, false)
if cur ~= v then local d = v - cur; if d > 0 then home:grantResources({ { Type = g, amt = d } }, false) else pcall(function() home:consumeGood(g, -d, un(eng.buildingArr[1]), false, false, false) end) end end
p1.silver = s0; home.regionalWealth = w0
W.fr.reg[rk] = saved.reg; W.fr.lord = saved.lord
W.on.stock, W.on.silver, W.on.wealth, W.dry, W.capture = saved.stock, saved.silver, saved.wealth, saved.dry, saved.capture
out("final stock", home:getStockOfGood(g, false, false), "silver", p1.silver, "wealth", home.regionalWealth, "| last module error", tostring(W.lastErr))
if not ok then out("VERDICT", "FAIL (error: " .. tostring(err) .. ")"); return "error" end
out("VERDICT", pass and "PASS" or "FAIL")
return "ok"
