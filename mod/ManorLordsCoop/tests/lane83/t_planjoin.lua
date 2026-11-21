-- Desk test of lane 83's PLANJOIN (coop_x_build.lua): the castle planner's wall join, carried by points.
-- Runs WITHOUT the game, with made-up walls, a made-up helper lord and a made-up native piece:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane83/t_planjoin.lua mod/ManorLordsCoop/Scripts/coop_x_build.lua
-- It loads the real coop_x_build.lua into a stand-in town module and checks:
--   * the pre-hook on the local lord's joinWalls makes a PLANJOIN record (a helper's call makes none);
--   * ready waits while both walls are still in the plan, then sends <manor> <A> <B> <joined> <gates>;
--   * apply on another copy: finds both walls by their points (also drawn the other way round), calls the helper's
--     joinWalls in planning mode, leaves it; the joined wall equal to the sender's: no WALLSET; other numbers: WALLSET;
--   * a repeated line (already joined here): "ok", no game call; the walls missing: a refusal;
--   * a wall joined with itself: "<A> <A> - -", and its replay takes the wall out of the plan;
--   * the PLANWPTS scan sends nothing for an own join, and nothing for the walls a replay changed.
local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end

local nextAddr = 0x1000
local ROAD = { GetFName = function() return { ToString = function() return "Road" end } end }
local OTHER = { GetFName = function() return { ToString = function() return "StaticMeshActor" end } end }
local function obj(o, cls)
  nextAddr = nextAddr + 16; local a = nextAddr; local name = "Obj_" .. a
  o.GetAddress = function() return a end
  o.IsValid = function() return o.dead ~= true end
  o.GetClass = function() return cls or OTHER end
  o.GetFName = function() return { ToString = function() return name end } end
  return o
end
local function pt(x, y, z) return { X = x, Y = y, Z = z or 0 } end
local function wall(pts) local w = obj({ ctl = pts, gates = {} }, ROAD); return w end
local function list(t) return t end           -- the game's lists: plain Lua arrays here (#, [i])

-- the manor and its plan
local manor = obj({ blueprints = {}, walls = {}, ownerPawn = nil })
local p1 = obj({ inPlanningMode = true })
manor.ownerPawn = p1
p1.plannerModeBld = manor
local function inPlanW(w) for _, x in ipairs(manor.blueprints) do if x == w then return true end end; return false end
local function removeW(w) for i, x in ipairs(manor.blueprints) do if x == w then table.remove(manor.blueprints, i); return end end end

-- the game's joinWalls, as run 1 measured it: A keeps the joined points, B leaves the plan; A with itself: A leaves
local gameCalls = 0
local joinShift = 0          -- > 0: this copy's game makes slightly other numbers (the replay must write the sender's)
local function gameJoin(a, b)
  gameCalls = gameCalls + 1
  if a == b then removeW(a); return true end
  local t = {}; for _, q in ipairs(a.ctl) do t[#t + 1] = pt(q.X, q.Y, q.Z) end
  for i = 2, #b.ctl do t[#t + 1] = pt(b.ctl[i].X + joinShift, b.ctl[i].Y, b.ctl[i].Z) end
  a.ctl = t; removeW(b); return true
end
local helper = obj({ inPlanningMode = false, isAI = false })
function helper:setPlannerMode(m) self.inPlanningMode = m ~= nil; self.plannerModeBld = m end
function helper:joinWalls(a, b) self.joinedIn = self.inPlanningMode; return gameJoin(a, b) end
function helper:switchWallMode() end
function helper:selectCastleBlueprint(w) self.sel = w end
function helper:destroySelectedCastleBlueprint() if self.sel then removeW(self.sel) end end
function helper:deselectCastleBlueprint() self.sel = nil end

-- the native piece
local wallSets = 0
local Patch = {
  drawAvail = function() return true end, wallSetAvail = function() return true end,
  wallGet = function(w) if not (w and w.ctl) then return nil end; local c = {}; for i, q in ipairs(w.ctl) do c[i] = q end; return { ctl = c, gates = w.gates, kind = { 1, 3, 2, 0 } } end,
  wallSet = function(w, pts) wallSets = wallSets + 1; local c = {}; for i, q in ipairs(pts) do c[i] = pt(q.X, q.Y, q.Z) end; w.ctl = c; return true, "ok" end,
  decPoints = function(s) local t = {}; if not s or s == "-" then return t end; for a in s:gmatch("[^|]+") do local x, y, z = a:match("^(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)$"); if x then t[#t + 1] = pt(tonumber(x), tonumber(y), tonumber(z)) end end; return t end,
}

-- a stand-in town module (only what coop_x_build.lua uses)
local defs, hooks, emitted, touched = {}, {}, {}, {}
local regs = {}
local now = 100.0
os.clock = function() return now end
local T
local X = {
  P = "/Script/ManorLords.",
  valid = function(o) return o ~= nil and type(o) == "table" and o.dead ~= true end,
  un = function(o) return o end,
  addrOf = function(o) return o and o.GetAddress and o:GetAddress() end,
  int = function(v) return math.floor(tonumber(v) or 0) end,
  def = function(d) defs[d.name] = d; T.enabled[d.name] = T.enabled[d.name] == nil and true or T.enabled[d.name]; return d end,
  hook = function(path, names, see) hooks[path] = see end,
  setter = function(name) defs[name] = { name = name, apply = function() return "ok" end } end,
  isLocal = function(p) return p == p1 end,
  owned = function(o) return o == manor end,
  bkeyOf = function() return "98,97700,-70300,3469" end,
  bident = function(o) return o end,
  findBkey = function(k) if k == "98,97700,-70300,3469" then return manor end end,
  touch = function(o) touched[o:GetAddress()] = now end,
}
T = { api = X, enabled = {}, defs = defs, touched = touched, own = {}, ownList = {},
  isOn = function(n) return T.enabled[n] == true end,
  emitAction = function(S, act, fields) emitted[#emitted + 1] = act .. " " .. fields end,
  place = { vnow = function() return now end, clearMoved = function() return true end,
    encPts = function(t) local o = {}; for i, v in ipairs(t) do o[i] = string.format("%.2f,%.2f,%.2f", v.X, v.Y, v.Z) end; return table.concat(o, "|") end,
    decPts = function() return {} end, decB = function() return nil end, bkeyYaw = function() return "" end } }
_G.Coop = { town = T, api = { helper = function() return helper end, log = function() end }, patch = Patch,
  register = function(name, m) regs[name] = m end }
local ok, res = pcall(dofile, ARG1)
check(ok and tostring(res):match("loaded"), "coop_x_build.lua loads in the stand-in (" .. tostring(res) .. ")")
local B = T.xbuild
local D = defs.PLANJOIN
check(D ~= nil and type(D.ready) == "function" and type(D.apply) == "function", "PLANJOIN is defined")
local see = hooks["/Script/ManorLords.PawnCPP:joinWalls"]
check(see ~= nil, "the hook on PawnCPP:joinWalls is there")
check(T.enabled.PLANJOIN == true, "PLANJOIN is on by default")

local function param(v) return { get = function() return v end } end
local S = { p1 = p1, name = "host", eng = {} }

-- the scan's baseline with the planner open
local A1 = wall({ pt(100, 0, 1), pt(100, 1000, 2) }); local B1 = wall({ pt(100, 1000, 2), pt(350, 1500, 3) })
manor.blueprints = { A1, B1 }
now = now + 1; regs.planwpts.tick(S, now)
emitted = {}

-- an own join
local rec = see({ get = function() return p1 end }, param(A1), param(B1))
check(rec and rec.k == "PLANJOIN" and rec.wa == A1 and rec.wb == B1, "the hook makes a PLANJOIN record for the local lord")
check(see({ get = function() return helper end }, param(A1), param(B1)) == nil, "a helper's joinWalls makes no record")
rec.obj = manor; rec.t = now; rec.snap = manor
check(D.ready(S, rec) == "wait", "ready waits while both walls are still in the plan")
gameJoin(A1, B1)
now = now + 0.6; regs.planwpts.tick(S, now)
check(#emitted == 0, "the scan sends no PLANWPTS for the own join (kept wall changed, B gone)")
local line = D.ready(S, rec)
check(type(line) == "string" and line:match("^98,97700,%-70300,3469 100%.00,0%.00,1%.00|100%.00,1000%.00,2%.00 100%.00,1000%.00,2%.00|350%.00,1500%.00,3%.00 100%.00,0%.00,1%.00|100%.00,1000%.00,2%.00|350%.00,1500%.00,3%.00 %-$") ~= nil,
  "ready sends <manor> <A> <B> <the joined points> <gates>: " .. tostring(line))
now = now + 1; regs.planwpts.tick(S, now)
check(#emitted == 0, "and nothing later either")

-- the replay on another copy (the same plan before the join; B drawn the other way round here)
local function split(s) local t = {}; for x in s:gmatch("%S+") do t[#t + 1] = x end; return t end
local f = split(line)
local A2 = wall({ pt(100, 0, 1), pt(100, 1000, 2) }); local B2 = wall({ pt(350, 1500, 3), pt(100, 1000, 2) })
manor.blueprints = { A2, B2 }; gameCalls = 0; wallSets = 0
-- this copy's game joins B the way it stands: A + B's points from its second on (here: 100,1000 again) -> other numbers
local r = D.apply(S, { f = f })
check(r == "ok", "apply: ok (" .. tostring(r) .. ")")
check(gameCalls == 1 and helper.joinedIn == true and helper.inPlanningMode == false, "the helper joined in planning mode and left it")
check(#manor.blueprints == 1 and #A2.ctl == 3 and A2.ctl[3].X == 350 and A2.ctl[3].Y == 1500, "the joined wall has the sender's points")
check(wallSets == 1, "the game here made other numbers: the sender's written once (WALLSET)")
-- the same plan, the walls the same way round: no WALLSET
local A3 = wall({ pt(100, 0, 1), pt(100, 1000, 2) }); local B3 = wall({ pt(100, 1000, 2), pt(350, 1500, 3) })
manor.blueprints = { A3, B3 }; gameCalls = 0; wallSets = 0
r = D.apply(S, { f = f })
check(r == "ok" and gameCalls == 1 and wallSets == 0, "the game here joined to the same numbers: no WALLSET")
-- a repeated line
gameCalls = 0
r = D.apply(S, { f = f })
check(r == "ok" and gameCalls == 0, "a repeated line: ok, no game call")
-- the walls not here
manor.blueprints = { wall({ pt(5, 5, 0), pt(6, 6, 0) }) }
r = D.apply(S, { f = f })
check(r ~= "ok" and tostring(r):match("not in the plan"), "the walls missing here: refused (" .. tostring(r) .. ")")
-- a shift of 1 unit in this copy's game: WALLSET puts the sender's numbers
joinShift = 1.0
local A4 = wall({ pt(100, 0, 1), pt(100, 1000, 2) }); local B4 = wall({ pt(100, 1000, 2), pt(350, 1500, 3) })
manor.blueprints = { A4, B4 }; wallSets = 0
r = D.apply(S, { f = f })
check(r == "ok" and wallSets == 1 and A4.ctl[3].X == 350, "the game here put a point 1 unit off: the sender's numbers written")
joinShift = 0

-- a wall joined with itself (the widget spawned over an old one)
local W = wall({ pt(0, 0, 0), pt(0, 500, 0), pt(200, 700, 0) })
manor.blueprints = { W }
now = now + 1; regs.planwpts.tick(S, now); emitted = {}
local rs = see({ get = function() return p1 end }, param(W), param(W)); rs.obj = manor; rs.t = now; rs.snap = manor
gameJoin(W, W)
now = now + 0.6; regs.planwpts.tick(S, now)
check(#emitted == 0, "the scan sends no removal for the own self-join")
local l2 = D.ready(S, rs)
check(type(l2) == "string" and l2:match(" %- %-$") ~= nil, "a self-join is sent as <A> <A> - -: " .. tostring(l2))
local W2 = wall({ pt(0, 0, 0), pt(0, 500, 0), pt(200, 700, 0) })
manor.blueprints = { W2, wall({ pt(9, 9, 0), pt(10, 10, 0) }) }
r = D.apply(S, { f = split(l2) })
check(r == "ok" and not inPlanW(W2) and #manor.blueprints == 1, "its replay takes that wall out of the plan, and only it")

-- a replay changes a wall while this copy's own planner is open: the scan does not send it back
local K = wall({ pt(0, 0, 0), pt(0, 900, 0) }); local L = wall({ pt(0, 900, 0), pt(300, 1300, 0) })
manor.blueprints = { K, L }
now = now + 1; regs.planwpts.tick(S, now); emitted = {}
local fl = { "98,97700,-70300,3469", "0.00,0.00,0.00|0.00,900.00,0.00", "0.00,900.00,0.00|300.00,1300.00,0.00", "0.00,0.00,0.00|0.00,900.00,0.00|300.00,1300.00,0.00", "-" }
r = D.apply(S, { f = fl })
now = now + 0.6; regs.planwpts.tick(S, now)
check(r == "ok" and #emitted == 0, "a replayed join here: the scan sends nothing back")
-- and a real change of this copy's own player later is still sent
now = now + 3; regs.planwpts.tick(S, now)
K.ctl = { pt(0, 0, 0), pt(0, 900, 0), pt(500, 1500, 0) }
now = now + 0.6; regs.planwpts.tick(S, now)
check(#emitted == 1 and emitted[1]:match("^PLANWPTS "), "a later own drag of a point is still sent as PLANWPTS (" .. tostring(emitted[1]) .. ")")

-- a replay here while this copy's own player changes ANOTHER wall in the same half second: that change is still sent
local K2 = wall({ pt(0, 3000, 0), pt(0, 3900, 0) }); local L2 = wall({ pt(0, 3900, 0), pt(300, 4300, 0) }); local M2 = wall({ pt(800, 0, 0), pt(800, 900, 0) })
manor.blueprints = { K2, L2, M2 }
now = now + 3; regs.planwpts.tick(S, now); emitted = {}
M2.ctl = { pt(800, 0, 0), pt(900, 950, 0) }
r = D.apply(S, { f = { "98,97700,-70300,3469", "0.00,3000.00,0.00|0.00,3900.00,0.00", "0.00,3900.00,0.00|300.00,4300.00,0.00", "0.00,3000.00,0.00|0.00,3900.00,0.00|300.00,4300.00,0.00", "-" } })
now = now + 0.6; regs.planwpts.tick(S, now)
check(r == "ok" and #emitted == 1 and emitted[1]:match("800%.00,0%.00,0%.00|900%.00,950%.00"), "a replay does not swallow this copy's own change of another wall (" .. tostring(emitted[1]) .. ")")
emitted = {}
-- CASTLE on the host: the game's answer is worked out when a lord enters planning mode, and kept outside it (run 12)
do
  local cached, fresh = true, false          -- a stale "true" outside the planner, "false" once worked out
  manor.canConstructCastle = function() return cached end
  local plainSet = helper.setPlannerMode
  helper.setPlannerMode = function(self, m) if m then cached = fresh end; return plainSet(self, m) end
  local SH = { p1 = p1, name = "host", role = "host", eng = {} }
  local r1 = defs.CASTLE.apply(SH, { f = { "98,97700,-70300,3469", "1" } })
  check(tostring(r1):match("cannot be constructed") and helper.inPlanningMode == false, "CASTLE on the host: refused by the answer worked out in planning mode, not the stale one; the helper left (" .. tostring(r1) .. ")")
  cached, fresh = false, true
  local r2 = defs.CASTLE.apply(SH, { f = { "98,97700,-70300,3469", "1" } })
  check(r2 == "ok", "CASTLE on the host: a stale false outside the planner does not refuse a plan the game allows (" .. tostring(r2) .. ")")
  helper.setPlannerMode = plainSet
end
-- the planner window is redrawn after a replay changed the plan while this copy's own planner is open (run 13)
do
  local calls = 0
  local win = obj({ updateCostAndConstructionAbility = function() calls = calls + 1 end, IsVisible = function() return true end })
  win.GetFullName = function() return "castlePlanner_C /Engine/Transient.GameEngine.castlePlanner_C_1" end
  _G.FindAllOf = function(c) if c == "castlePlanner_C" then return { win } end; return {} end
  p1.inPlanningMode = true; p1.plannerModeBld = manor
  for _ = 1, 4 do now = now + 1; regs.planwpts.tick(S, now) end      -- the earlier replays of this test: settled
  calls = 0; now = now + 5; regs.planwpts.tick(S, now)
  check(calls == 0, "no replay: the window is left alone")
  touched[manor:GetAddress()] = now
  now = now + 0.1; regs.planwpts.tick(S, now); check(calls == 0, "not at once (the replay finishes first)")
  now = now + 0.3; regs.planwpts.tick(S, now); check(calls == 1, "redrawn 0.3 s after the replay")
  now = now + 1.0; regs.planwpts.tick(S, now); check(calls == 2, "and again 1.3 s after it")
  now = now + 3.0; regs.planwpts.tick(S, now); check(calls == 2, "then no more")
  p1.inPlanningMode = false; touched[manor:GetAddress()] = now; now = now + 2; regs.planwpts.tick(S, now)
  check(calls == 2, "the planner closed: nothing")
  p1.inPlanningMode = true
end
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
