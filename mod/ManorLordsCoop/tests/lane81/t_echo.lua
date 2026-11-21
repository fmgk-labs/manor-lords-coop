-- Desk test of lane 81: the town module's echo guard and its order rule (coop_town.lua), WITHOUT the game.
-- Run from the repository root:
--   py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane81/t_echo.lua mod/ManorLordsCoop/Scripts/
-- The argument is the folder holding coop_town.lua (give the folder of an older copy to see the old code fail).
-- A made-up region "hof" with trade limits, trade rules, tax rates and a trade route; its setters call the module's hook
-- callback the way the game's hook does (before the routine, also inside a replay). One copy per run of build():
--   1  G22: a REAL change made 0.1 to 0.7 s after the other player's change to the same region is sent (old: dropped)
--   2  an echo (the same value on the same slot, after the replay returned) is still dropped, also twice
--   3  the player going 34 -> 35 -> 34 within 3 s: both changes sent (old: the second was taken for an echo)
--   4  another good of the same region inside 0.75 s: sent; the same value on another good is not an echo
--   5  several value kinds: TRULE, TAX (FName + int), PLIM, and a relative kind (TROUTE) inside 0.75 s: sent
--   6  the host: a host press 0.1 to 0.7 s after a friend's line it applied is sent; exactly one line per change
--   7  the order rule: own line and another player's line crossed: the friend ends with the host's last value (both
--      orders), a refused own line puts nothing back
--   8  nobody acting: 0 lines in 10 s of ticks
local dir = ARG1 or (arg and arg[1]) or "mod/ManorLordsCoop/Scripts/"
if dir:sub(-1) ~= "/" and dir:sub(-1) ~= "\\" then dir = dir .. "/" end
math.tointeger = math.tointeger or function(v) if type(v) == "number" and v == math.floor(v) then return v end; return nil end
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end
table.unpack = table.unpack or unpack

local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end

local NOW = 1000.0
os.clock = function() return NOW end
_G.RegisterHook = function() return 1, 2 end
_G.FName = function(s) return { ToString = function() return s end } end
_G.StaticFindObject = function() return nil end
_G.FindAllOf = function() return {} end

local P = "/Script/ManorLords.Region:"
local function param(v) return { get = function() return v end } end

local function build(role, name)
  local sent = {}
  local C = {}
  _G.Coop = C
  local mod
  C.register = function(n, m) if n == "town" then mod = m end end
  C.api = {
    un = function(x) return x end,
    valid = function(x) return x ~= nil and (type(x) ~= "table" or x.IsValid == nil or x:IsValid()) end,
    far = function() return false end, log = function(f, ...) end, now = function() return NOW end,
    send = function(line) sent[#sent + 1] = line end, isPaused = function() return false end,
    helper = function() return nil end, btype = function() return 0 end,
  }
  local function obj(o, a) o.GetAddress = function() return a end; o.IsValid = function() return true end; return o end
  local lord = obj({}, 0x77)
  local hof = obj({ regionUniqueTag = { ToString = function() return "hof" end }, ownerPawn = lord,
    tradeRules = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 },
    target = {}, rule = {}, tax = {}, plim = {}, route = {} }, 0x500)
  local function hookOf(fn, ...)       -- the game's hook fires before the routine, every call, also inside a replay
    local T = C.town; local args = { ... }; local ps = {}
    for i = 1, #args do ps[i] = param(args[i]) end
    T.onHook(P .. fn, param(hof), ps[1], ps[2], ps[3], ps[4])
  end
  function hof:changeTargetInventory(g, v) hookOf("changeTargetInventory", g, v); self.target[g] = v end
  function hof:changeTradeRule(g, v) hookOf("changeTradeRule", g, v); self.rule[g] = v end
  function hof:changeTaxRate(n, v) hookOf("changeTaxRate", n, v); self.tax[n:ToString()] = v end
  function hof:setProductionLimit(g, v) hookOf("setProductionLimit", g, v); self.plim[g] = v end
  function hof:setProductionUnlimited(g) hookOf("setProductionUnlimited", g); self.plim[g] = "off" end
  function hof:unlockOneTradeLevel(g) hookOf("unlockOneTradeLevel", g); self.route[g] = (self.route[g] or 0) + 1 end
  C.s = { role = role, name = name, on = true, p1 = lord, stats = {}, eng = { buildingArr = {}, roads = {}, regions = { hof } } }
  assert(loadfile(dir .. "coop_town.lua"))()
  local T = C.town
  T.reset()
  local K = { C = C, T = T, hof = hof, sent = sent, mod = mod, S = C.s, n = 0 }
  function K.tick(dt) NOW = NOW + (dt or 0.016); mod.tick(C.s, NOW) end
  function K.ticks(sec) local t = 0; while t < sec do K.tick(0.05); t = t + 0.05 end end
  function K.line(origin, n, act, ...)                      -- a T line from the host's file
    local w = { "1", "0.000", "T", origin, tostring(n), act, ... }
    mod.onMessage(C.s, role == "host" and origin or "host", "T", w, table.concat(w, " "))
  end
  function K.townLines() local c = 0; for _, l in ipairs(sent) do if l:match("^T ") then c = c + 1 end end; return c end
  function K.last() return sent[#sent] or "" end
  function K.clear() for i = #sent, 1, -1 do sent[i] = nil end end
  K.ticks(0.2)                                               -- hooks registered, p1 known
  K.clear()
  return K
end
local function has(K, pat) for _, l in ipairs(K.sent) do if l:find(pat, 1, true) then return true end end; return false end

print("1, 2: G22 and the echo (friend, Trade tab, trade limit of good 15)")
for _, gap in ipairs({ 0.1, 0.3, 0.48, 0.7 }) do
  local K = build("friend", "friend1")
  K.line("host", 100, "TTARGET", "hof", "15,34")
  K.tick(); K.tick()
  check(K.hof.target[15] == 34 and K.townLines() == 0, string.format("host's 34 applied, nothing sent back (gap %.2f)", gap))
  K.ticks(0.05); K.C.town.onHook(P .. "changeTargetInventory", param(K.hof), param(15), param(34))   -- a late repeat of the replayed value
  K.ticks(0.1)
  check(K.townLines() == 0, "  a late call with the replayed value is dropped as an echo")
  K.ticks(gap - 0.15 > 0 and gap - 0.15 or 0)
  K.hof:changeTargetInventory(15, 35)                       -- the player's + (34 -> 35)
  K.ticks(0.2)
  check(K.townLines() == 1 and has(K, "TTARGET hof 15,35"), string.format("  the player's 35, %.2f s after the host's line, is sent once", gap))
end

print("3: 34 -> 35 -> 34 within 3 s")
do
  local K = build("friend", "friend1")
  K.line("host", 101, "TTARGET", "hof", "15,34"); K.ticks(0.1)
  K.hof:changeTargetInventory(15, 35); K.ticks(0.3)
  K.hof:changeTargetInventory(15, 34); K.ticks(0.3)
  check(K.townLines() == 2 and K.sent[1]:find("15,35", 1, true) and K.sent[2]:find("15,34", 1, true), "both sent, in order (35, 34)")
  -- the echo of the same value twice after one replay
  local K2 = build("friend", "friend1")
  K2.line("host", 102, "TTARGET", "hof", "15,20"); K2.ticks(0.1)
  for _ = 1, 2 do K2.C.town.onHook(P .. "changeTargetInventory", param(K2.hof), param(15), param(20)) end
  K2.ticks(0.3)
  check(K2.townLines() == 0, "the replayed value seen twice after the replay: both dropped")
end

print("4: another good of the same region")
do
  local K = build("friend", "friend1")
  K.line("host", 103, "TTARGET", "hof", "15,34"); K.ticks(0.1)
  K.hof:changeTargetInventory(16, 34); K.ticks(0.3)
  check(K.townLines() == 1 and has(K, "TTARGET hof 16,34"), "good 16 set to 34 right after good 15's replay: sent")
end

print("5: other value kinds, and a relative one")
do
  local K = build("friend", "friend1")
  K.line("host", 104, "TRULE", "hof", "15,2"); K.ticks(0.1)
  K.hof:changeTradeRule(15, 3); K.ticks(0.3)
  check(has(K, "TRULE hof 15,3"), "TRULE: the player's rule 0.1 s after the host's: sent")
  K.clear()
  K.line("host", 105, "TAX", "hof", "land,20"); K.ticks(0.1)
  K.hof:changeTaxRate(FName("land"), 30); K.ticks(0.3)
  check(has(K, "TAX hof land,30"), "TAX: the player's rate 0.1 s after the host's: sent")
  K.clear()
  K.line("host", 106, "PLIM", "hof", "7,40"); K.ticks(0.1)
  K.hof:setProductionLimit(7, 41); K.ticks(0.3)
  check(has(K, "PLIM hof 7,41"), "PLIM: the player's limit 0.1 s after the host's: sent")
  K.clear()
  K.line("host", 107, "TROUTE", "hof", "5"); K.ticks(0.1)
  check(K.hof.route[5] == 1 and K.townLines() == 0, "TROUTE (relative): the host's route applied, not sent back")
  K.hof:unlockOneTradeLevel(5); K.ticks(0.3)
  check(K.townLines() == 1 and has(K, "TROUTE hof 5"), "TROUTE: the player's own purchase 0.1 s after: sent")
end

print("6: the host side")
do
  local K = build("host", "host")
  K.line("friend1", 200, "TTARGET", "hof", "15,33"); K.ticks(0.1)
  check(K.hof.target[15] == 33 and K.townLines() == 1 and has(K, "T friend1 200 TTARGET hof 15,33"), "the friend's 33 applied and passed on, once")
  K.ticks(0.38); K.hof:changeTargetInventory(15, 34); K.ticks(0.3)
  check(K.townLines() == 2 and has(K, "TTARGET hof 15,34"), "the host's own 34, 0.48 s after: sent (the lane 80 case: host 34, friend 33)")
end

print("7: the order rule (friend)")
do
  -- crossed: the friend sends 37, the host's 35 (sent before the host got the 37) arrives, then the friend's own back
  local K = build("friend", "friend1")
  K.hof:changeTargetInventory(15, 37); K.ticks(0.1)
  local n = K.sent[1] and K.sent[1]:match("^T friend1 (%d+) TTARGET")
  check(n ~= nil, "the friend's 37 sent")
  K.line("host", 300, "TTARGET", "hof", "15,35"); K.ticks(0.1)
  check(K.hof.target[15] == 35, "the host's 35 applied here (the host had it first)")
  K.line("friend1", n, "TTARGET", "hof", "15,37"); K.ticks(0.1)
  check(K.hof.target[15] == 37 and K.townLines() == 1, "own line back from the host: 37 put back (the host's last value), nothing sent")
  -- crossed, and both lines read in one go before the tick applies either (lane 81 game run, cross 1)
  local Kb = build("friend", "friend1")
  Kb.hof:changeTargetInventory(15, 10); Kb.ticks(0.1)
  local nb = Kb.sent[1] and Kb.sent[1]:match("^T friend1 (%d+) TTARGET")
  Kb.line("host", 310, "TTARGET", "hof", "15,12")
  Kb.line("friend1", nb, "TTARGET", "hof", "15,10")
  Kb.ticks(0.2)
  check(Kb.hof.target[15] == 10 and Kb.townLines() == 1, "both lines in one read: the host's 12 then this copy's 10 put back (host order), nothing sent")
  -- the press still waits in the hook queue when the host's line arrives: it is sent first in the next tick, the
  -- host's line is applied after it, so the host took the host's line first and this copy's value is the last one
  local Kw = build("friend", "friend1")
  Kw.line("host", 320, "TTARGET", "hof", "15,12")
  Kw.hof:changeTargetInventory(15, 10)
  Kw.ticks(0.1)
  local nw = Kw.sent[1] and Kw.sent[1]:match("^T friend1 (%d+) TTARGET")
  check(nw ~= nil and Kw.hof.target[15] == 12, "press waiting when the host's 12 arrived: 10 sent, then 12 applied")
  Kw.line("friend1", nw, "TTARGET", "hof", "15,10"); Kw.ticks(0.1)
  check(Kw.hof.target[15] == 10 and Kw.townLines() == 1, "own line back: 10 put back (the host's last value), nothing sent")
  -- not crossed: the host took 37 first, then the host's own 35: 35 is the last value
  local K2 = build("friend", "friend1")
  K2.hof:changeTargetInventory(15, 37); K2.ticks(0.1)
  local n2 = K2.sent[1] and K2.sent[1]:match("^T friend1 (%d+) TTARGET")
  K2.line("friend1", n2, "TTARGET", "hof", "15,37"); K2.ticks(0.1)
  K2.line("host", 301, "TTARGET", "hof", "15,35"); K2.ticks(0.1)
  check(K2.hof.target[15] == 35 and K2.townLines() == 1, "own line back first, then the host's 35: 35 stays")
  -- refused: the host's 35 holds
  local K3 = build("friend", "friend1")
  K3.hof:changeTargetInventory(15, 37); K3.ticks(0.1)
  local n3 = K3.sent[1] and K3.sent[1]:match("^T friend1 (%d+) TTARGET")
  K3.line("host", 302, "TTARGET", "hof", "15,35"); K3.ticks(0.1)
  K3.C.town.reset = K3.C.town.reset   -- (no repair in a desk test)
  K3.C.join = { requestRepair = function() K3.repair = true end }
  K3.line("host", 303, "NAK", "friend1:" .. n3, "no")
  K3.ticks(0.1)
  check(K3.hof.target[15] == 35, "own line refused: the host's 35 stays")
end

print("4b: kinds that undo each other (production limit and unlimited)")
do
  local K = build("friend", "friend1")
  K.line("host", 108, "PLIM", "hof", "7,40"); K.ticks(0.1)
  K.hof:setProductionUnlimited(7); K.ticks(0.3)
  K.hof:setProductionLimit(7, 40); K.ticks(0.3)
  check(has(K, "PUNLIM hof 7") and has(K, "PLIM hof 7,40") and K.townLines() == 2, "replayed 40, player unlimited, player 40 again: both sent")
end

print("8: nobody acting")
do
  local K = build("friend", "friend1")
  K.ticks(10)
  check(K.townLines() == 0, "10 s of ticks, nobody acting: 0 town lines")
end

print("9: building kinds through the shared rule (a field the panel writes, the maintenance slider)")
do
  local K = build("friend", "friend1")
  local T = K.C.town
  if T.isEcho then
    local bld = { GetAddress = function() return 0x900 end, IsValid = function() return true end }
    T.api.touch(bld, T.defs.FILTER, "15+216")
    check(T.isEcho("FILTER", 0x900, "15+216") == true, "FILTER: the replayed filter seen again: echo")
    check(T.isEcho("FILTER", 0x900, "15") == false and T.isEcho("FILTER", 0x900, "15+216") == false, "FILTER: the player's other filter ends it; going back is sent")
    T.api.touch(bld, T.defs.MAINT, "2")
    check(T.isEcho("MAINT", 0x900, "2") == true and T.isEcho("MAINT", 0x900, "0") == false, "MAINT: 2 echo, the player's 0 sent")
    NOW = NOW + 3.1
    T.api.touch(bld, T.defs.ADDW, "-")
    check(T.isEcho("MAINT", 0x900, "2") == false and T.isEcho("ADDW", 0x900, "-") == false, "after 3 s nothing is an echo; a relative kind never is")
  else
    check(false, "the value rule (T.isEcho) exists")
  end
end

print("10: three players (the other friend's line reaches this friend through the host, origin friend2)")
do
  local function own(K) return K.sent[1] and K.sent[1]:match("^T friend1 (%d+) TTARGET") end
  -- friend2's 36 taken by the host first, then friend1's own 37 back: 37 is the host's last value
  local K = build("friend", "friend1")
  K.hof:changeTargetInventory(15, 37); K.ticks(0.1); local n = own(K)
  K.line("friend2", 41, "TTARGET", "hof", "15,36"); K.ticks(0.1)
  check(K.hof.target[15] == 36, "friend2's 36 (forwarded) applied here")
  K.line("friend1", n, "TTARGET", "hof", "15,37"); K.ticks(0.1)
  check(K.hof.target[15] == 37 and K.townLines() == 1, "own 37 back after friend2's 36: 37 put back, nothing more sent")
  -- the host took friend1's 37 first, then friend2's 36: 36 stays
  local K2 = build("friend", "friend1")
  K2.hof:changeTargetInventory(15, 37); K2.ticks(0.1); local n2 = own(K2)
  K2.line("friend1", n2, "TTARGET", "hof", "15,37"); K2.ticks(0.1)
  K2.line("friend2", 42, "TTARGET", "hof", "15,36"); K2.ticks(0.1)
  check(K2.hof.target[15] == 36 and K2.townLines() == 1, "own 37 back first, then friend2's 36: 36 stays")
  -- both in one read (friend2's first)
  local K3 = build("friend", "friend1")
  K3.hof:changeTargetInventory(15, 37); K3.ticks(0.1); local n3 = own(K3)
  K3.line("friend2", 43, "TTARGET", "hof", "15,36"); K3.line("friend1", n3, "TTARGET", "hof", "15,37"); K3.ticks(0.2)
  check(K3.hof.target[15] == 37 and K3.townLines() == 1, "friend2's 36 and own 37 in one read: 37 (host order)")
  -- own refused, friend2's 36 had come: 36 stays
  local K4 = build("friend", "friend1")
  K4.hof:changeTargetInventory(15, 37); K4.ticks(0.1); local n4 = own(K4)
  K4.line("friend2", 44, "TTARGET", "hof", "15,36"); K4.ticks(0.1)
  K4.C.join = { requestRepair = function() end }
  K4.line("host", 304, "NAK", "friend1:" .. n4, "no"); K4.ticks(0.1)
  check(K4.hof.target[15] == 36, "own 37 refused: friend2's 36 stays")
  -- a real press 0.1 to 0.7 s after friend2's line was applied: sent; friend2's value seen again: an echo
  for _, gap in ipairs({ 0.1, 0.4, 0.7 }) do
    local K5 = build("friend", "friend1")
    K5.line("friend2", 45, "TTARGET", "hof", "15,36"); K5.ticks(0.1)
    K5.C.town.onHook(P .. "changeTargetInventory", param(K5.hof), param(15), param(36)); K5.ticks(gap)
    check(K5.townLines() == 0, string.format("friend2's 36 seen again (gap %.1f): echo, not sent", gap))
    K5.hof:changeTargetInventory(15, 38); K5.ticks(0.2)
    check(K5.townLines() == 1 and has(K5, "TTARGET hof 15,38"), string.format("  this friend's 38, %.1f s after friend2's line: sent once", gap))
  end
  -- the host: friend1's 33 and friend2's 34 within 0.2 s, then the host's own 35
  local H = build("host", "host")
  H.line("friend1", 210, "TTARGET", "hof", "15,33"); H.ticks(0.1)
  H.line("friend2", 211, "TTARGET", "hof", "15,34"); H.ticks(0.1)
  check(H.hof.target[15] == 34 and H.townLines() == 2 and H.sent[1]:find("T friend1 210 TTARGET hof 15,33", 1, true) and H.sent[2]:find("T friend2 211 TTARGET hof 15,34", 1, true),
    "host: both friends' lines applied and passed on in arrival order, last 34")
  H.ticks(0.2); H.hof:changeTargetInventory(15, 35); H.ticks(0.3)
  check(H.townLines() == 3 and has(H, "TTARGET hof 15,35"), "host's own 35, 0.3 s after friend2's line: sent")
end

print(string.format("RESULT %d passed, %d failed", pass, fail))
if fail > 0 then error("lane 81 echo desk test: " .. fail .. " failed") end
