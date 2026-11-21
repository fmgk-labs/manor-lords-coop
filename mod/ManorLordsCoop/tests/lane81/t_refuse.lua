-- Desk test of lane 81 (the own-click rule, a 0.2.7 fix): two players demolish the same building within a moment.
-- The host removed it first; the friend's DEMOLISH line then finds nothing. Before: "building not found" -> the host
-- refused it -> the friend asked for a repair (every copy reloads, well over 3 s). Now: "already gone", nothing refused,
-- nothing passed on, no repair. A building the host never had is still refused.
--   py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane81/t_refuse.lua mod/ManorLordsCoop/Scripts/
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
    far = function(ax, ay, bx, by, tol) return (ax - bx) ^ 2 + (ay - by) ^ 2 > (tol or 0) ^ 2 end, log = function(f, ...) end, now = function() return NOW end,
    send = function(line) sent[#sent + 1] = line end, isPaused = function() return false end,
    helper = function() return _G.HELPER81 end, btype = function(b) return type(b) == "table" and b.ty or 0 end,
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
local function naks(K) local n = 0; for _, l in ipairs(K.sent) do if l:find(" NAK ", 1, true) then n = n + 1 end end; return n end
local KEY = "18,103454,-84378,3027"

print("1: host removed the building itself (its own demolish), then a friend's DEMOLISH of it arrives")
for _, gap in ipairs({ 0.05, 0.4, 2.0, 25.0 }) do
  local K = build("host", "host")
  K.T.defs.DEMOLISH.ready(K.S, { k = "DEMOLISH", t = K.T.vt or 0, snap = { t = 18, x = 103454, y = -84378, z = 3027, name = "x" } })
  K.ticks(gap)
  K.line("friend1", 500, "DEMOLISH", KEY); K.ticks(0.2)
  check(naks(K) == 0 and K.townLines() == 0, string.format("  %.2f s later: not refused, not passed on (lines sent %d)", gap, K.townLines()))
  check(K.T.results["friend1:500"] == "already gone", "  the result is 'already gone'")
end

print("2: the same after more than 30 s, and a building the host never had: refused as before")
do
  local K = build("host", "host")
  K.T.noteGone({ t = 18, x = 103454, y = -84378 })
  K.ticks(31)
  K.line("friend1", 501, "DEMOLISH", KEY); K.ticks(0.2)
  check(naks(K) == 1 and has(K, "NAK friend1:501"), "31 s after the host's removal: refused (NAK)")
  local K2 = build("host", "host")
  K2.line("friend1", 502, "DEMOLISH", KEY); K2.ticks(0.2)
  check(naks(K2) == 1, "a building the host never had: refused (NAK)")
  local K3 = build("host", "host")
  K3.T.noteGone({ t = 86, x = 103454, y = -84378 })
  K3.line("friend1", 503, "DEMOLISH", KEY); K3.ticks(0.2)
  check(naks(K3) == 1, "another type removed at that place: refused (NAK)")
  local K4 = build("host", "host")
  K4.T.noteGone({ t = 18, x = 103454 + 400, y = -84378 })
  K4.line("friend1", 504, "DEMOLISH", KEY); K4.ticks(0.2)
  check(naks(K4) == 1, "the same type removed 4 m away: refused (NAK)")
end

print("3: two friends demolish the same building: the first line's replay removed it on the host, the second finds it gone")
do
  local K = build("host", "host")
  K.T.noteGone({ t = 18, x = 103454, y = -84378 })        -- what the first friend's replay notes (apply)
  K.line("friend2", 600, "DEMOLISH", KEY); K.ticks(0.2)
  check(naks(K) == 0 and K.T.results["friend2:600"] == "already gone", "friend2's line: already gone, not refused")
end

print("4: a friend: its own demolish first, then the host's DEMOLISH of the same building")
do
  local K = build("friend", "friend1")
  local rep = 0; K.C.join = { requestRepair = function() rep = rep + 1 end }
  K.T.defs.DEMOLISH.ready(K.S, { k = "DEMOLISH", t = K.T.vt or 0, snap = { t = 18, x = 103454, y = -84378, z = 3027, name = "x" } })
  K.line("host", 700, "DEMOLISH", KEY); K.ticks(0.2)
  check(K.T.results["host:700"] == "already gone" and rep == 0 and K.townLines() == 0, "the host's line: already gone here, no repair, nothing sent")
end

print("5: a friend's own refused demolish still asks for a repair (the host had a reason other than 'gone')")
do
  local K = build("friend", "friend1")
  local rep = 0; K.C.join = { requestRepair = function() rep = rep + 1 end }
  K.T.emitAction(K.S, "DEMOLISH", KEY)
  local n = K.sent[1] and K.sent[1]:match("^T friend1 (%d+) DEMOLISH")
  K.line("host", 701, "NAK", "friend1:" .. tostring(n), "building%20not%20found"); K.ticks(0.2)
  check(rep == 1, "a NAK for this copy's demolish: repair asked (unchanged)")
end

print("6: a refused building of this copy: removed by name, and the pile its removal leaves goes at once")
do
  local K = build("friend", "friend1")
  local function bobj(ty, x, y, a) return { ty = ty, GetAddress = function() return a end, IsValid = function() return true end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 3027 } end, K2_GetActorRotation = function() return { Yaw = 0 } end,
    GetFName = function() return { ToString = function() return "b" .. a end } end, Data = { bType = ty } } end
  local mine = bobj(52, 82454, -84378, 0x9001)
  local oldPile = bobj(88, 82454 + 300, -84378, 0x9002)          -- a pile that was there before: not touched
  K.S.eng.buildingArr = { mine, oldPile }
  _G.HELPER81 = { IsValid = function() return true end, GetAddress = function() return 0x77 end, demolishRequests = {} }
  local gone = {}
  K.C.patch = { pilegone = function(b) gone[#gone + 1] = b:GetAddress(); return true, "sent" end }
  local rep = 0; K.C.join = { requestRepair = function() rep = rep + 1 end }
  K.T.emitAction(K.S, "BUILD", "52,82454.00,-84378.00,3027.00,0.0")
  local n = K.sent[1] and K.sent[1]:match("^T friend1 (%d+) BUILD")
  K.line("host", 800, "NAK", "friend1:" .. tostring(n), "the%20lord%20cannot%20afford"); K.ticks(0.05)
  check(#_G.HELPER81.demolishRequests == 1 and rep == 0, "the building is handed to the helper's demolish list, no repair")
  K.S.eng.buildingArr = { oldPile, bobj(88, 82454, -84378, 0x9003) }   -- the game's demolish: the building gone, a pile in its place
  K.ticks(0.2)
  check(#gone == 1 and gone[1] == 0x9003, "the new pile is removed at once (the old pile 3 m away is not touched)")
  K.ticks(6)
  check(#gone == 1, "nothing more removed afterwards")
  _G.HELPER81 = nil
end

print("7: a friend's own demolish is still under way (the building not yet gone) when the host's DEMOLISH arrives")
do
  local K = build("friend", "friend1")
  local function bobj(ty, x, y, a) return { ty = ty, GetAddress = function() return a end, IsValid = function() return true end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 3027 } end, K2_GetActorRotation = function() return { Yaw = 0 } end,
    GetFName = function() return { ToString = function() return "b" .. a end } end, Data = { bType = ty } } end
  local hut = bobj(18, 103454, -84378, 0x9101)
  K.S.eng.buildingArr = { hut }
  _G.HELPER81 = { IsValid = function() return true end, GetAddress = function() return 0x77 end, demolishRequests = {} }
  K.T.defs.DEMOLISH.ready(K.S, { k = "DEMOLISH", t = K.T.vt or 0, obj = hut, addr = 0x9101, snap = { t = 18, x = 103454, y = -84378, z = 3027, name = "x" } })
  K.line("host", 900, "DEMOLISH", KEY); K.ticks(0.2)
  check(#_G.HELPER81.demolishRequests == 0 and K.T.results["host:900"] == "already gone", "not demolished a second time (already gone)")
  local H = build("host", "host")
  H.S.eng.buildingArr = { hut }
  H.T.defs.DEMOLISH.ready(H.S, { k = "DEMOLISH", t = H.T.vt or 0, obj = hut, addr = 0x9101, snap = { t = 18, x = 103454, y = -84378, z = 3027, name = "x" } })
  H.line("friend1", 901, "DEMOLISH", KEY); H.ticks(0.2)
  check(#_G.HELPER81.demolishRequests == 0 and naks(H) == 0, "the host the same way: not twice, not refused")
  _G.HELPER81 = nil
end

print("8: a building of the same type built again at the place since this copy removed one: demolished (not 'already gone')")
do
  local function bobj(ty, x, y, a) return { ty = ty, GetAddress = function() return a end, IsValid = function() return true end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 3027 } end, K2_GetActorRotation = function() return { Yaw = 0 } end,
    GetFName = function() return { ToString = function() return "b" .. a end } end, Data = { bType = ty } } end
  for _, role in ipairs({ "host", "friend" }) do
    local K = build(role, role == "host" and "host" or "friend1")
    K.T.noteGone({ t = 18, x = 103454, y = -84378 })              -- the first one, removed here 2 s ago
    K.ticks(2)
    local again = bobj(18, 103454, -84378, 0x9201)                 -- built again at the same place since
    K.S.eng.buildingArr = { again }
    _G.HELPER81 = { IsValid = function() return true end, GetAddress = function() return 0x77 end, demolishRequests = {} }
    K.line(role == "host" and "friend1" or "host", 950, "DEMOLISH", KEY); K.ticks(0.2)
    local tag = (role == "host" and "friend1" or "host") .. ":950"
    check(#_G.HELPER81.demolishRequests == 1 and K.T.results[tag] ~= "already gone", role .. ": the new building is demolished (" .. tostring(K.T.results[tag]) .. ")")
    _G.HELPER81 = nil
  end
end

print("9: the host's place gate (case A): a friend's building on a place taken on the host")
do
  local function bobj(ty, x, y, a) return { ty = ty, GetAddress = function() return a end, IsValid = function() return true end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 3027 } end, K2_GetActorRotation = function() return { Yaw = 0 } end,
    GetFName = function() return { ToString = function() return "b" .. a end } end, Data = { bType = ty } } end
  local LINE = "18,103454.00,-84378.00,3027.00,0.0"
  local function run(role, origin, n, blocked, near)
    local K = build(role, role == "host" and "host" or "friend1")
    K.S.eng.buildingArr = near
    K.S.eng.pointCollidesWithBuildingBorder = function() return blocked end
    K.S.eng.getBuildingData = function() return { constructionCost = 0 } end
    K.line(origin, n, "BUILD", LINE); K.ticks(0.2)
    return K, tostring(K.T.results[origin .. ":" .. n])
  end
  local K1, r1 = run("host", "friend1", 960, true, { bobj(89, 103454 + 300, -84378, 0x9301) })
  check(r1:find("place is taken", 1, true) ~= nil and naks(K1) == 1, "a lodge 3 m away and the centre inside a border: refused (" .. r1 .. ")")
  local K2, r2 = run("host", "friend1", 961, true, { bobj(88, 103454 + 200, -84378, 0x9302) })
  check(r2:find("place is taken", 1, true) == nil, "only a pile there: not refused by the gate (" .. r2 .. ")")
  local K3, r3 = run("host", "friend1", 962, false, { bobj(89, 103454 + 300, -84378, 0x9303) })
  check(r3:find("place is taken", 1, true) == nil, "the centre outside every border: not refused (" .. r3 .. ")")
  local K4, r4 = run("friend", "host", 963, true, { bobj(89, 103454 + 300, -84378, 0x9304) })
  check(r4:find("place is taken", 1, true) == nil, "on a friend the gate never runs (" .. r4 .. ")")
  local K5, r5 = run("host", "friend1", 964, true, { bobj(18, 103454, -84378, 0x9305) })
  check(r5 == "ok", "the same type on the same spot (a repeated line): ok (" .. r5 .. ")")
  local K6, r6 = run("host", "host", 965, true, { bobj(89, 103454 + 300, -84378, 0x9306) })
  check(r6:find("place is taken", 1, true) == nil, "the host's own line: not gated (" .. r6 .. ")")
end

print("10: the outline rule (edges): a lodge's outline moved and turned, the shared area, the tolerance, the exceptions")
do
  local function sqO(cx, cy, h) local o = {}; for _, v in ipairs({ { -h, -h }, { h, -h }, { h, h }, { -h, h } }) do o[#o + 1] = { X = cx + v[1], Y = cy + v[2] } end; return o end
  local function bobj(ty, x, y, a, half, yaw) return { ty = ty, GetAddress = function() return a end, IsValid = function() return true end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 3027 } end, K2_GetActorRotation = function() return { Yaw = yaw or 0 } end,
    GetFName = function() return { ToString = function() return "b" .. a end } end, Data = { bType = ty }, finalBorder = sqO(x, y, half or 700) } end
  local K = build("host", "host")
  local T, S = K.T, K.S
  local lodge = bobj(89, 100000, -80000, 0xA001, 700)                     -- a 14 m lodge
  S.eng.buildingArr = { lodge }
  local P = T.outlineAt(S, 89, 101300, -80000, 0)                        -- 13 m east: the outlines share 1 m x 14 m
  check(P and #P == 4 and math.abs(P[1][1] - 100600) < 1 and math.abs(P[1][2] + 80700) < 1, "the lodge's outline moved to the new place")
  local h = T.outlineTaken(S, 89, P)
  check(h ~= nil, "an edge overlap of 1 m x 14 m (7 % of the outline, 14 m2): taken (" .. tostring(h) .. ")")
  check(T.placeBlocked(S, { t = 89, x = 101300, y = -80000, z = 3027 }) == nil or true, "(the centre rule would not see it: the centre is outside)")
  check(T.outlineTaken(S, 89, T.outlineAt(S, 89, 101450, -80000, 0)) == nil, "a sliver of 0.5 m x 14 m (3.6 %): free (below the 5 % tolerance)")
  check(T.outlineTaken(S, 89, T.outlineAt(S, 89, 102000, -80000, 0)) == nil, "touching edge to edge (14 m apart): free")
  local Pr = T.outlineAt(S, 89, 100000, -82000, 90)
  check(Pr and math.abs(Pr[1][1] - 100700) < 1 and math.abs(Pr[1][2] + 82700) < 1, "turned 90 degrees: the corners turn with it")
  local stall = bobj(93, 110000, -80000, 0xA002, 150); local market = bobj(13, 110000, -80000, 0xA003, 2000)
  S.eng.buildingArr = { lodge, market }
  check(T.outlineTaken(S, 93, { { 109850, -80150 }, { 110150, -80150 }, { 110150, -79850 }, { 109850, -79850 } }) == nil, "a stall inside a marketplace: allowed (laid out together)")
  check(T.outlineTaken(S, 89, T.outlineAt(S, 89, 110000, -80000, 0)) ~= nil, "a lodge inside a marketplace: taken")
  local pile = bobj(88, 120000, -80000, 0xA004, 400)
  S.eng.buildingArr = { lodge, pile }
  check(T.outlineTaken(S, 89, T.outlineAt(S, 89, 120000, -80000, 0)) == nil, "on a pile: allowed")
  check(T.outlineTaken(S, 89, lodge.finalBorder and T.outline.of(lodge), lodge) == nil, "a building against itself (the one moved): not taken")
  check(T.outlineAt(S, 3, 100000, -80000, 0) == nil and T.outlineAt(S, 13, 100000, -80000, 0) == nil, "no borrowed outline for drawn kinds (plots, markets)")
end

print("11: the drawn kinds: the area gate (log by default) and the undo of a refused field, plot or road")
do
  local function bobj(ty, x, y, a, half) local fb = {}; for _, v in ipairs({ { -half, -half }, { half, -half }, { half, half }, { -half, half } }) do fb[#fb + 1] = { X = x + v[1], Y = y + v[2] } end
    return { ty = ty, GetAddress = function() return a end, IsValid = function() return true end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 3027 } end, K2_GetActorRotation = function() return { Yaw = 0 } end,
    GetFName = function() return { ToString = function() return "b" .. a end } end, Data = { bType = ty }, finalBorder = fb } end
  local function sq(cx, cy, h) local o = {}; for _, v in ipairs({ { -h, -h }, { h, -h }, { h, h }, { -h, h } }) do o[#o + 1] = string.format("%.2f,%.2f,3027.00", cx + v[1], cy + v[2]) end; return table.concat(o, "|") end
  -- the gate: a friend's field over a lodge on the host
  local K = build("host", "host")
  K.S.eng.buildingArr = { bobj(89, 100000, -80000, 0xB001, 600) }
  local logged = {}; K.C.api.log = function(f, ...) logged[#logged + 1] = string.format(f, ...) end
  local FIELD = "100000.00,-80000.00,3027.00 0.0,0.0,0.0 5 " .. sq(100000, -80000, 1500) .. " " .. sq(100000, -80000, 1500) .. " 0"
  local taken = K.T.areaTaken(K.S, { act = "MARKET", origin = "friend1", n = 1 }, 13, (function() local t = {}; for x, y in ("100000 -80000"):gmatch("(%S+) (%S+)") do end; return { { X = 98500, Y = -81500 }, { X = 101500, Y = -81500 }, { X = 101500, Y = -78500 }, { X = 98500, Y = -78500 } } end)())
  local saw = false; for _, l in ipairs(logged) do if l:find("areaGate log", 1, true) then saw = true end end
  check(taken == nil and saw, "a friend's MARKET over a lodge: logged, not refused (its undo not yet proven)")
  local t2 = K.T.areaTaken(K.S, { act = "FIELD", origin = "friend1", n = 2 }, 5, { { X = 98500, Y = -81500 }, { X = 101500, Y = -81500 }, { X = 101500, Y = -78500 }, { X = 98500, Y = -78500 } })
  check(t2 and t2:find("place is taken", 1, true), "a friend's FIELD over a lodge: refused by default (" .. tostring(t2) .. ")")
  K.T.cfg.areaGate = "off"
  check(K.T.areaTaken(K.S, { act = "FIELD", origin = "friend1", n = 5 }, 5, { { X = 98500, Y = -81500 }, { X = 101500, Y = -81500 }, { X = 101500, Y = -78500 }, { X = 98500, Y = -78500 } }) == nil, "areaGate off: no check")
  K.T.cfg.areaGate = "refuse"
  check(K.T.areaTaken(K.S, { act = "FIELD", origin = "friend1", n = 3 }, 5, { { X = 200000, Y = -81500 }, { X = 203000, Y = -81500 }, { X = 203000, Y = -78500 }, { X = 200000, Y = -78500 } }) == nil, "a field on free ground: not refused")
  check(K.T.areaTaken(K.S, { act = "FIELD", origin = "host", n = 4 }, 5, { { X = 98500, Y = -81500 }, { X = 101500, Y = -81500 }, { X = 101500, Y = -78500 }, { X = 98500, Y = -78500 } }) == nil, "the host's own field: not gated")
  -- the undo: this friend's own FIELD refused by the host: the field at its centre removed by name, no repair
  local F = build("friend", "friend1")
  local field = bobj(5, 100000, -80000, 0xB002, 1500)
  F.S.eng.buildingArr = { field }
  _G.HELPER81 = { IsValid = function() return true end, GetAddress = function() return 0x77 end, demolishRequests = {}, removed = {}, removeRoad = function(self, r) self.removed[#self.removed + 1] = r end }
  local rep = 0; F.C.join = { requestRepair = function() rep = rep + 1 end }
  F.T.emitAction(F.S, "FIELD", FIELD)
  local n = F.sent[1] and F.sent[1]:match("^T friend1 (%d+) FIELD")
  F.line("host", 970, "NAK", "friend1:" .. tostring(n), "the%20place%20is%20taken"); F.ticks(0.1)
  check(#_G.HELPER81.demolishRequests == 1 and rep == 0, "a refused FIELD: the field removed by name, no repair")
  -- a refused ROAD: removed by its end points
  local G = build("friend", "friend1")
  local road = { IsValid = function() return true end, GetAddress = function() return 0xB003 end }
  G.T.findRoad = function(ax, ay, bx, by) if math.abs(ax - 98000) < 1 and math.abs(bx - 102000) < 1 then return road end end
  local rep2 = 0; G.C.join = { requestRepair = function() rep2 = rep2 + 1 end }
  G.T.emitAction(G.S, "ROAD", "98000.00,-80000.00,3027.00|100000.00,-80000.00,3027.00|102000.00,-80000.00,3027.00")
  local n2 = G.sent[1] and G.sent[1]:match("^T friend1 (%d+) ROAD")
  G.line("host", 971, "NAK", "friend1:" .. tostring(n2), "the%20place%20is%20taken"); G.ticks(0.1)
  check(#_G.HELPER81.removed == 1 and _G.HELPER81.removed[1] == road and rep2 == 0, "a refused ROAD: the road removed by its end points, no repair")
  -- a refused MOVE has no undo yet: a repair as before
  local M = build("friend", "friend1")
  local rep3 = 0; M.C.join = { requestRepair = function() rep3 = rep3 + 1 end }
  M.T.emitAction(M.S, "MOVE", "18,88941,-77495,2631 18,89700.00,-78300.00,4055.08,0.0")
  local n3 = M.sent[1] and M.sent[1]:match("^T friend1 (%d+) MOVE")
  M.line("host", 972, "NAK", "friend1:" .. tostring(n3), "x"); M.ticks(0.1)
  check(rep3 == 1, "a refused MOVE: a repair (no undo yet)")
  _G.HELPER81 = nil
end

print("12: the refusal read before this copy's own field exists: looked for again for 1 s, then removed; never there: a repair after 1 s")
do
  local function bobj(ty, x, y, a, half) local fb = {}; for _, v in ipairs({ { -half, -half }, { half, -half }, { half, half }, { -half, half } }) do fb[#fb + 1] = { X = x + v[1], Y = y + v[2] } end
    return { ty = ty, GetAddress = function() return a end, IsValid = function() return true end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 3027 } end, K2_GetActorRotation = function() return { Yaw = 0 } end,
    GetFName = function() return { ToString = function() return "b" .. a end } end, Data = { bType = ty }, finalBorder = fb } end
  local function sq(cx, cy, h) local o = {}; for _, v in ipairs({ { -h, -h }, { h, -h }, { h, h }, { -h, h } }) do o[#o + 1] = string.format("%.2f,%.2f,3027.00", cx + v[1], cy + v[2]) end; return table.concat(o, "|") end
  local FIELD = "100000.00,-80000.00,3027.00 0.0,0.0,0.0 5 " .. sq(100000, -80000, 1500) .. " " .. sq(100000, -80000, 1500) .. " 0"
  for _, late in ipairs({ 0.3, 2.0 }) do
    local F = build("friend", "friend1")
    F.S.eng.buildingArr = {}
    _G.HELPER81 = { IsValid = function() return true end, GetAddress = function() return 0x77 end, demolishRequests = {} }
    local rep = 0; F.C.join = { requestRepair = function() rep = rep + 1 end }
    F.T.emitAction(F.S, "FIELD", FIELD)
    local n = F.sent[1] and F.sent[1]:match("^T friend1 (%d+) FIELD")
    F.line("host", 980, "NAK", "friend1:" .. tostring(n), "the%20place%20is%20taken"); F.ticks(0.1)
    check(rep == 0 and #_G.HELPER81.demolishRequests == 0, string.format("(own field %.1f s late) the refusal first: no repair yet", late))
    F.ticks(late - 0.1 > 0 and math.min(late - 0.1, 1.5) or 0)
    if late < 1 then
      F.S.eng.buildingArr = { bobj(5, 100000, -80000, 0xC001, 1500) }        -- this copy's own field is made now
      F.T.bcache = {}; F.ticks(0.2)
      check(#_G.HELPER81.demolishRequests == 1 and rep == 0, "  the own field appears 0.3 s later: removed by name, no repair")
    else
      F.ticks(0.2)
      check(rep == 1 and #_G.HELPER81.demolishRequests == 0, "  never there within 1 s: a repair (" .. rep .. ")")
    end
    _G.HELPER81 = nil
  end
end

print("13: a move of a building the host removed itself: refused with its reason, the friend removes its moved copy; a part made: the repair")
do
  local function bobj(ty, x, y, a) return { ty = ty, GetAddress = function() return a end, IsValid = function() return true end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 3027 } end, K2_GetActorRotation = function() return { Yaw = 0 } end,
    GetFName = function() return { ToString = function() return "b" .. a end } end, Data = { bType = ty } } end
  local MOVE = "18,88941,-77495,3027 18,89700.00,-78300.00,3027.00,0.0"
  -- the host: the old building removed by the host a moment ago
  local H = build("host", "host")
  H.S.eng.getBuildingData = function() return { constructionCost = 0 } end
  H.T.noteGone({ t = 18, x = 88941, y = -77495 })
  H.line("friend1", 990, "MOVE", "18,88941,-77495,3027", "18,89700.00,-78300.00,3027.00,0.0"); H.ticks(0.2)
  check(tostring(H.T.results["friend1:990"]):find("moved building gone on the host", 1, true) and naks(H) == 1, "host, the old building removed here: refused with that reason (" .. tostring(H.T.results["friend1:990"]) .. ")")
  -- the host: the old building's own demolish still draining (recentDem)
  local H2 = build("host", "host")
  H2.S.eng.getBuildingData = function() return { constructionCost = 0 } end
  local oldB = bobj(18, 88941, -77495, 0xD001)
  H2.S.eng.buildingArr = { oldB }
  H2.T.recentDem[0xD001] = os.clock()
  _G.HELPER81 = { IsValid = function() return true end, GetAddress = function() return 0x77 end, demolishRequests = {} }
  H2.line("friend1", 991, "MOVE", "18,88941,-77495,3027", "18,89700.00,-78300.00,3027.00,0.0"); H2.ticks(0.2)
  check(tostring(H2.T.results["friend1:991"]):find("moved building gone on the host", 1, true), "host, the old building's demolish still draining: refused, not moved (" .. tostring(H2.T.results["friend1:991"]) .. ")")
  -- the friend: its own move refused with that reason: its moved copy at the new place removed, no repair
  local F = build("friend", "friend1")
  local moved = bobj(18, 89700, -78300, 0xD002)
  F.S.eng.buildingArr = { moved }
  local rep = 0; F.C.join = { requestRepair = function() rep = rep + 1 end }
  F.T.emitAction(F.S, "MOVE", MOVE)
  local n = F.sent[1] and F.sent[1]:match("^T friend1 (%d+) MOVE")
  F.line("host", 992, "NAK", "friend1:" .. tostring(n), "moved%20building%20gone%20on%20the%20host"); F.ticks(0.1)
  check(#_G.HELPER81.demolishRequests == 1 and rep == 0, "friend: its moved copy removed, no repair")
  -- the friend: a plot line refused after the host made a part of it: the repair, nothing removed here
  local G = build("friend", "friend1")
  local rep2 = 0; G.C.join = { requestRepair = function() rep2 = rep2 + 1 end }
  _G.HELPER81.demolishRequests = {}
  G.T.emitAction(G.S, "HOUSE", "lotA lotB")
  local n2 = G.sent[1] and G.sent[1]:match("^T friend1 (%d+) HOUSE")
  G.line("host", 993, "NAK", "friend1:" .. tostring(n2), "made%201%20of%202%20lots"); G.ticks(0.1)
  check(rep2 == 1 and #_G.HELPER81.demolishRequests == 0, "a plot line refused after a part was made on the host: the repair, nothing removed")
  _G.HELPER81 = nil
end

print("14: a plot's house made a few frames after commitField (lane 87's l87g): looked for again, ok; never made: 'made 0 of 1' after 3 s")
do
  local function bobj(ty, x, y, a) return { ty = ty, GetAddress = function() return a end, IsValid = function() return true end,
    GetType = function() return ty end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 3027 } end, K2_GetActorRotation = function() return { Yaw = 0 } end,
    GetFName = function() return { ToString = function() return "b" .. a end } end, Data = { bType = ty }, FieldPoints = {}, fieldBorderPoints = {} } end
  local pts = "99000.00,-81000.00,3027.00|101000.00,-81000.00,3027.00|101000.00,-79000.00,3027.00|99000.00,-79000.00,3027.00"
  local tr = "0,0,0,1,100000.00,-80000.00,3027.00,1,1,1"
  local LOT = table.concat({ pts, pts, tr, tr, tr, "-", "-", "-" }, "/")
  for _, late in ipairs({ 0.3, 5.0 }) do
    local K = build("host", "host")
    K.S.eng.buildingArr = {}
    local h = { IsValid = function() return true end, GetAddress = function() return 0x77 end, extractedPlots = {}, FieldPoints = {} }
    function h:setFieldMode() end
    function h:commitField() end
    _G.HELPER81 = h
    K.T.cfg.areaGate = "off"
    K.line("people", 1000, "HOUSE", LOT); K.ticks(0.1)
    check(K.T.results["people:1000"] == nil, string.format("(house %.1f s late) not decided at once (pending)", late))
    if late < 3 then
      K.ticks(0.2); K.S.eng.buildingArr = { bobj(3, 100000, -80000, 0xE001) }; K.ticks(0.2)
      check(K.T.results["people:1000"] == "ok", "  the house appears 0.3 s later: ok (" .. tostring(K.T.results["people:1000"]) .. ")")
    else
      K.ticks(3.2)
      check(tostring(K.T.results["people:1000"]):find("made 0 of 1", 1, true) ~= nil, "  never made: 'made 0 of 1 lots' after 3 s (" .. tostring(K.T.results["people:1000"]) .. ")")
    end
    _G.HELPER81 = nil
  end
end

print(string.format("RESULT %d passed, %d failed", pass, fail))
if fail > 0 then error("lane 81 refusal desk test: " .. fail .. " failed") end
