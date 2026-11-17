-- Manor Lords Co-op: things a player draws or places on the ground that the town module did not carry (lane 2, session 21).
--
-- WHAT IS HERE, AND HOW FAR EACH IS TESTED (evidence: research/2026-11-10-game-probe/lanes/lane_s21_2/report.md)
--   PLAN      a part placed in the castle planner (keep, palace, gatehouse, tower ...): one blueprint added to the manor's
--             plan. ON. Run on two copies in both directions, also after a resync, from the lord's own scripted request.
--   CASTLE    the planner's "construct" step. ON. The game call was made from the test console on two copies in both
--             directions; both copies then showed the same plan. Parts were never seen finished.
--   GATE      a gate opened or closed. ON. Run on two copies by lane 28 (a gate of an upgraded wall across a road).
--   PLANWALL  a wall or palisade drawn in the castle planner. ON since lane 28: replayed with the game's own wall tool,
--             run by the native piece (coop_patch DRAW). Without the native piece a wall is logged and not carried.
--   PLANSEL   a change to the selected part of the plan (remove, level, platform level, turn a wall round). OFF: never run;
--             while off such a change is silent (not sent, not logged).
--   So a castle plan can differ between copies without any sign (walls, removed or changed parts, dragged parts), and
--   the construct step is still carried: the copies then build different castles until the next resync.
--   (a marketplace plot, MARKET, lives with the field and house plots in coop_town.lua: same hook, same replay)
--   None of these was ever done by a real click on the ground: all need one (real_click_checklist.md in the lane folder).
--
-- HOW THE GAME DOES IT (measured on the host)
--   * The manor keep itself (type 57) is an ordinary placement: BUILD of coop_town.lua carries it.
--   * PawnCPP:setPlannerMode(manor) puts a lord into planning mode (inPlanningMode, plannerModeBld). While it is on, the
--     ordinary placement (placeBuilding + bbox + requestBuild, the flag a click sets) adds a blueprint to manor.blueprints
--     and makes no building; playBuildEffects fires with the place. A blueprint is a plain mesh actor: its type and level
--     are not readable afterwards, so the type must be taken at the moment of placing (the lord's placeBuilding).
--     The plan is kept in the save: it survives a resync on both copies.
--   * The wall tool is the road tool with wallMode on (switchWallMode(true), then the road draft, then commitRoad). A wall
--     committed from a script comes out with an empty spline at the map origin outside the planner, and crashes the game
--     inside it: the tool keeps part of its draft where a script cannot put it (the control points, Road +318h: see the
--     PLANWALL section for how lane 28 lets the game's own tool fill them).
--   * Nothing is paid while planning. The construct step is SMBuildingMaster:convertBlueprintsToBuildings(bool): the manor
--     then holds one ghost actor per blueprint; no entry is added to the world's building list at that moment.
--   * A gate is a GateComponent of a building; GateComponent:ToggleGatesOpen() flips bGatesOpened. The gates of a building
--     are getControllableGates(): a gate is named by its building and its place in that list (that the order is the same
--     on every copy is assumed, not measured).
--
-- REPLAY: through the helper lord, as BUILD does. The helper enters planning mode for the same manor, does the same
-- request, and leaves planning mode again in the same step (a helper left in planning mode would turn its next ordinary
-- placement into a blueprint).
--
-- STATUS WORDS: "console2" = the game's own request was made from a script on two copies, in both directions;
-- "static" = never run; "crashes" = the replay crashed the game; "native2" = replayed by the native piece (coop_patch)
-- with the game's own routines, on two copies in both directions; "press2" = by a panel press on two copies, both ways.

local C = rawget(_G, "Coop")
local T = C and C.town
local X = T and T.api
if not (X and T.place and C.api) then return "coop_x_build: load coop_town.lua first" end
local A = C.api
local Pl = T.place
local valid, un, addrOf, int = X.valid, X.un, X.addrOf, X.int
local P = X.P
T.xbuild = T.xbuild or {}
local B = T.xbuild
B.version = "lane28-1"

local ZERO = { X = 0.0, Y = 0.0, Z = 0.0 }
local function nums(s) local t = {}; for x in tostring(s or ""):gmatch("[^,]+") do t[#t + 1] = tonumber(x) end; return t end

-- the blueprint of a plan nearest to (x, y), within tol
local function bpAt(m, x, y, tol)
  local arr = m.blueprints; local best, bi, bd
  for i = 1, #arr do
    local a = un(arr[i])
    if valid(a) then
      local l = a:K2_GetActorLocation(); local d = math.abs(l.X - x) + math.abs(l.Y - y)
      if math.abs(l.X - x) <= tol and math.abs(l.Y - y) <= tol and (not bd or d < bd) then best, bi, bd = a, i, d end
    end
  end
  return best, bi
end
-- (lane 37, F6) a wall's last control point (native WALLGET), or nil for a part that is not a wall. Two walls joined
-- at one point stand at the same place, so PLANSEL named the wrong one: a friend's delete of the new wall took the
-- gate wall away on the host (real click, lane 37 sitting 3).
local function wallEnd(a)
  local okC, cn = pcall(function() return a:GetClass():GetFName():ToString() end)
  if not okC or cn ~= "Road" then return nil end
  local Pt = C.patch; if not (Pt and Pt.wallGet) then return nil end
  local okG, g = pcall(Pt.wallGet, a)
  if okG and g and g.ctl and #g.ctl > 0 then return g.ctl[#g.ctl] end
  return nil
end
-- the wall at place x, y whose last control point is nearest ex, ey
local function wallAt(m, x, y, ex, ey)
  local arr = m.blueprints; local best, bd
  for i = 1, #arr do
    local a = un(arr[i])
    if valid(a) then
      local l = a:K2_GetActorLocation()
      if math.abs(l.X - x) <= 60 and math.abs(l.Y - y) <= 60 then
        local e = wallEnd(a)
        local d = e and (math.abs(e.X - ex) + math.abs(e.Y - ey)) or 1e12
        if not bd or d < bd then best, bd = a, d end
      end
    end
  end
  return best
end

-- the helper must never stay in planning mode
local function leave(h)
  pcall(function() h:setPlannerMode(nil) end)
  local still = false; pcall(function() still = h.inPlanningMode == true end)
  if still then pcall(function() h.inPlanningMode = false end); pcall(function() h.plannerModeBld = nil end) end
  pcall(function() if h.wallMode then h:switchWallMode(false) end end)
end
B.leave = leave

local function enter(h, m)
  h.placeBuilding = 0
  h:setPlannerMode(m)
  if not (h.inPlanningMode and valid(h.plannerModeBld) and addrOf(h.plannerModeBld) == addrOf(m)) then leave(h); return false end
  return true
end

-- ================================================================ PLAN: one part placed in the castle planner
-- SEE: coop_town.lua's playBuildEffects hook (BUILD section) makes the record when the lord is in planning mode.
--   PLAN <manor> <type,x,y,z,yaw>
local function checkPlan(S, Pd, h, waited)
  if valid(h) and h.requestBuild and waited < 3.0 then return nil end
  if not valid(h) then return "helper gone" end
  local timedOut = h.requestBuild == true
  if timedOut then h.requestBuild = false end
  h.placeBuilding = 0
  leave(h)
  if not valid(Pd.m) then return "planner building gone" end
  local a = bpAt(Pd.m, Pd.e.x, Pd.e.y, 60) or (#Pd.m.blueprints > Pd.n0)        -- there, or at least one more than before
  A.log("TOWN planner part type %d at %.0f,%.0f: %s (blueprints %d -> %d)", Pd.e.t, Pd.e.x, Pd.e.y, a and "placed" or "not placed", Pd.n0, #Pd.m.blueprints)
  if a then X.touch(Pd.m); return "ok" end
  return timedOut and "the helper never took the request (timed out, disarmed)" or "no blueprint appeared (spot refused?)"
end

X.def { name = "PLAN", status = "console2", ref = "lane 2 runs s3b, s4, s5", helper = true, wait = 1,
  ready = function(S, rec)
    local m = rec.obj; if not valid(m) then return nil, "planner building gone" end
    if not X.owned(m) then return nil, "not the lord's" end
    local e = { t = rec.bt, x = rec.x, y = rec.y, z = rec.z, yaw = rec.yaw }
    if e.t == 0 then return nil, "planner placement without a type" end
    -- The new blueprint itself gives the exact place and turn (the lord's box moves on with the pointer). A line is sent
    -- only when a blueprint really stands where the build event said: the same event also fires for other things (seen
    -- in lane 2's run s7 when a backyard extension was added while the lord was still in planning mode), and those
    -- must not put a part into every copy's plan.
    local a = bpAt(m, rec.x, rec.y, 60)
    if not valid(a) then
      if Pl.vnow() - rec.t < 0.5 then return "wait" end
      return nil, "no blueprint stands at the place of the build event"
    end
    local l, r = a:K2_GetActorLocation(), a:K2_GetActorRotation()
    e.x, e.y, e.z, e.yaw = l.X, l.Y, l.Z, r.Yaw
    return X.bkeyOf(X.bident(m)) .. " " .. Pl.bkeyYaw(e)
  end,
  apply = function(S, job)
    local m = X.findBkey(job.f[1]); if not m then return "retry:planner building not found" end
    local e = Pl.decB(job.f[2]); if not e then return "bad fields" end
    if bpAt(m, e.x, e.y, 60) then return "ok" end                    -- already there (a repeated line)
    local cost = T.buildCost(e.t)
    if cost == nil then return "cost of type " .. e.t .. " unreadable: refused" end
    if cost > 0 then return "planner part " .. e.t .. " has a treasury cost: refused (an unfunded helper crashes the game)" end
    local h = A.helper(); if not valid(h) then return "no helper" end
    if not Pl.clearMoved(h) then return "helper still holds a moved building" end
    if not enter(h, m) then return "the helper could not enter planning mode" end
    h.placeBuilding = e.t
    h.bbox:K2_SetWorldLocationAndRotation({ X = e.x + 0.0, Y = e.y + 0.0, Z = e.z + 0.0 }, { Pitch = 0.0, Yaw = e.yaw + 0.0, Roll = 0.0 }, false, {}, true)
    h.requestBuild = true
    T.pend = { kind = "plan", job = job, m = m, e = e, n0 = #m.blueprints, t0 = Pl.vnow(), check = checkPlan }
    return "pending"
  end }

-- ================================================================ PLANWALL: a wall or palisade drawn in the planner
-- SEE: coop_town.lua's commitRoad hook (ROAD section) makes the record when the lord's wallMode is on.
--   PLANWALL <manor> <wallType,platformLevel> <control points>
-- HOW THE GAME DOES IT (lane 28, read in the game file and measured; lanes/lane_s21_28/report.txt):
--   * The wall tool is the road tool. Each frame its update (4b67950) builds the draft from the lord's roadPoints (the
--     points clicked so far) and the cursor point; a click (4b6a5f0) takes the point the update left; commitRoad copies
--     the draft into a new Road and puts it into the planner building's `blueprints` (not into `walls`).
--   * The update also copies the control points into the road itself (Road +318h) and, for a wall, works out a gate
--     wherever the wall crosses a road of the region under the cursor (Road +498h). The manor's own wall code reads
--     those control points: a wall written from a script has none, which was the crash of sessions 3 and 4 of lane 2.
--   * So a wall is named by its control points, and replayed by giving the game's own tool the same points: the native
--     piece writes the cursor point and runs the update and the click per point, then commitRoad (WALL, flags 3: commit
--     there, and clear the update's "cannot place" flag, which it sets for any lord that does not own the region, as
--     the helper never does). The helper's isAI is set for that moment: the update then takes the point as it is (no
--     snapping, no "pointer did not move" shortcut), the way the game's AI lords draw their roads (4be8fe0).
--   * The native commit does not pass the script layer, so the replay raises no PLANWALL of its own.
local function clsOf(o) local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end); return ok and n or "" end
-- the walls of a planner building: the Road objects among its blueprints, in the order they were drawn
local function wallsOf(m)
  local t = {}; local arr = m.blueprints
  for i = 1, #arr do local a = un(arr[i]); if valid(a) and clsOf(a) == "Road" then t[#t + 1] = a end end
  return t
end
B.wallsOf = wallsOf
local function near1(u, v, tol) return math.abs(u.X - v.X) <= tol and math.abs(u.Y - v.Y) <= tol end
local function drawOk() local Pt = C.patch; return Pt and Pt.drawAvail and Pt.drawAvail() end
-- the wall of the plan with these control points (same number, every point within tol; drawn either way round)
local function sameWall(m, pts, tol)
  for _, w in ipairs(wallsOf(m)) do
    local g = C.patch.wallGet(w); local q = g and g.ctl
    if q and #q == #pts then
      local fwd, rev = true, true
      for i = 1, #pts do
        if not near1(q[i], pts[i], tol) then fwd = false end
        if not near1(q[#q + 1 - i], pts[i], tol) then rev = false end
      end
      if fwd or rev then return w end
    end
  end
  return nil
end
B.wallKnown = B.wallKnown or {}        -- address of a wall -> its control points as sent or applied (an address can be used again)
X.def { name = "PLANWALL", status = "native2", ref = "lane 28 report (two copies, both ways, after a resync)", helper = true, wait = 1,
  ready = function(S, rec)
    local m = rec.obj; if not valid(m) then return nil, "planner building gone" end
    if not X.owned(m) then return nil, "not the lord's" end
    if not drawOk() then return nil, "the native piece (coop_patch DRAW) is not available here: the wall stays on this copy" end
    local ws = wallsOf(m); local w = ws[#ws]             -- the commit appends the new wall to the plan
    if not valid(w) then return "wait" end
    local g = C.patch.wallGet(w); if not g or #g.ctl < 2 then return "wait" end
    local line = Pl.encPts(g.ctl)
    if B.wallKnown[addrOf(w)] == line then return "wait" end                        -- the newest wall is an older one: nothing came of this commit (yet)
    if rec.pts[1] and not near1(g.ctl[1], rec.pts[1], 1.0) then return "wait" end   -- not the wall of this commit
    B.wallKnown[addrOf(w)] = line
    -- (lane 32) the gates' places as this copy worked them out: the replaying copy takes their heights (see apply)
    local gt = {}; for i, q in ipairs(g.gates or {}) do gt[i] = string.format("%.2f,%.2f,%.4f", q.X, q.Y, q.Z) end
    return X.bkeyOf(X.bident(m)) .. " " .. g.kind[3] .. "," .. g.kind[4] .. " " .. line .. " " .. (#gt > 0 and table.concat(gt, "|") or "-")
  end,
  apply = function(S, job)
    if not drawOk() then return "the native piece (coop_patch DRAW) is not available on this copy: the wall cannot be drawn here" end
    local m = X.findBkey(job.f[1]); if not m then return "retry:planner building not found" end
    local n = nums(job.f[2]); local pts = Pl.decPts(job.f[3])
    if #pts < 2 or #pts > 21 then return "bad points" end
    if sameWall(m, pts, 0.02) then return "ok" end                  -- already there (the copy that drew it, or a repeated line)
    local h = A.helper(); if not valid(h) then return "no helper" end
    if not Pl.clearMoved(h) then return "helper still holds a moved building" end
    if not enter(h, m) then return "the helper could not enter planning mode" end
    local nb0 = #m.blueprints
    local okD, res, r = pcall(function()
      h:switchWallMode(true)
      if n[1] then h.dummyRoad.wallType = int(n[1]) end
      h:setRoadMode(true, pts[1], false)
      h.regionUnderCursor = S.eng:getRegionByPos(pts[#pts], false)      -- the gates: where the wall crosses this region's roads
      local wasAI = h.isAI; h.isAI = true
      local ok, t = C.patch.wallDraw(h, 3, pts)
      h.isAI = wasAI
      return ok, t
    end)
    pcall(function() h:setRoadMode(false, ZERO, false) end)
    pcall(function() h:switchWallMode(false) end)
    leave(h)
    if not okD then return "error " .. tostring(res) end
    if not res then return "the wall tool refused: " .. tostring(r) end
    local ws = wallsOf(m); local w = ws[#ws]
    A.log("TOWN planner wall: %d points given, %s taken (blocked %s), plan parts %d -> %d", #pts, tostring(r.pts), tostring(r.blocked), nb0, #m.blueprints)
    if #m.blueprints <= nb0 or not valid(w) then return "commitRoad made no wall" end
    local g = C.patch.wallGet(w)
    if g then
      -- (lane 55) the drawing copy's tool can move a point when it is drawn (the player's tool snaps; the replay runs
      -- as the AI, which does not: a 21-point wall on coop_test_open had its 11th point 7.7 m apart, and every later
      -- PLANWPTS of that wall was refused). The line carries the points as the drawing copy's wall holds them, so they
      -- are written as they are (coop_patch WALLSET, the game's own rebuild) when the game here took others.
      local off = #g.ctl ~= #pts
      if not off then for i = 1, #pts do if not near1(g.ctl[i], pts[i], 0.006) then off = true; break end end end
      if off and C.patch.wallSet and C.patch.wallSetAvail and C.patch.wallSetAvail() then
        local okS, r = C.patch.wallSet(w, pts)
        A.log("TOWN planner wall: the game here took other points than the drawing copy's (%d of %d): the drawing copy's written: %s", #g.ctl, #pts, okS and "ok" or ("NOT written: " .. tostring(r)))
        if okS then g = C.patch.wallGet(w) or g end
      end
      B.wallKnown[addrOf(w)] = Pl.encPts(g.ctl)
      if #g.ctl ~= #pts then A.log("TOWN planner wall: the game kept %d of the %d points", #g.ctl, #pts) end
      -- (lane 32) The gate's height as the drawing copy has it. This copy works it out apart, 0.01 to 0.03 off with the
      -- same control points (lane 28), until an upgrade or a resync. The record of the same place is set.
      local want = (job.f[4] and job.f[4] ~= "-") and C.patch.decPoints(job.f[4]) or {}
      for _, q in ipairs(want) do
        for i, have in ipairs(g.gates or {}) do
          if near1(have, q, 1.0) then
            if math.abs(have.Z - q.Z) > 0.00005 and C.patch.gateSet then
              local okG, r = C.patch.gateSet(w, i - 1, q)
              A.log("TOWN planner wall: gate at %.0f,%.0f height %.4f -> the drawing copy's %.4f: %s", q.X, q.Y, have.Z, q.Z, okG and "set" or ("NOT set: " .. tostring(r)))
            end
            break
          end
        end
      end
    end
    X.touch(m)
    return "ok"
  end }
B.wallReplayProven = true              -- lane 28: the replay runs the game's own tool (see above)
if T.enabled.PLANWALL == true and not B.wallReplayProven then T.enabled.PLANWALL = false end

-- ================================================================ PLANSEL: a change to the selected part of the plan
-- SEE: pre-hooks on the lord's own functions; the selected part is the lord's selectedBlueprint. A part is named by its
-- place (parts are plain mesh actors without a name of their own), a wall by its number in the manor's wall list.
--   PLANSEL <manor> <b:x,y | w:n> <DEL | LVL,<change> | PLAT,<change> | REV>
-- REPLAY: the helper selects the same part with the game's own selectCastleBlueprint and calls the same function.
-- NOT RUN LIVE (status static): switched off until it has been. While it is off its four hooks are not even registered
-- (hooks are only made for actions that are on), so such a change is SILENT: nothing is sent and nothing is logged, and
-- the plans of the copies differ from then on. Why off and GATE on: the replay calls planner functions on the helper,
-- and a probe that called selectCastleBlueprint and its neighbours from the console crashed the game (lane 2, session 1);
-- GATE's replay is one call of the function the gate button itself makes.
local SEL = {
  DEL = { fn = "destroySelectedCastleBlueprint" },
  LVL = { fn = "changeSelectedBuildingBlueprintUpgradeLevel", arg = true },
  PLAT = { fn = "changeSelectedBuildingPlatformLevel", arg = true },
  REV = { fn = "ReverseSelectedWall" },
}
for op, d in pairs(SEL) do
  X.hook(P .. "PawnCPP:" .. d.fn, { "PLANSEL" }, function(self, a1)
    local p = self:get(); if not X.isLocal(p) then return nil end
    local m = p.plannerModeBld; local s = p.selectedBlueprint
    if not (valid(m) and valid(s)) then return nil end
    local sa = addrOf(s); local ref
    local arr = m.walls
    for i = 1, #arr do if addrOf(un(arr[i])) == sa then ref = "w:" .. i end end
    if not ref then
      local rc = s.RootComponent
      if valid(rc) then local l = rc.RelativeLocation; ref = string.format("b:%.0f,%.0f", l.X, l.Y) end
      -- (lane 37, F6) two walls joined at one point have the same place: a wall also gets its last control point
      local e = ref and wallEnd(s)
      if e then ref = ref .. string.format(":%.0f,%.0f", e.X, e.Y) end
    end
    if not ref then return { k = "_note", msg = "planner change on a part that could not be named: not sent" } end
    local v = 0
    if d.arg then v = int(a1 and a1:get()) end
    return { k = "PLANSEL", obj = m, ref = ref, op = op, v = v }
  end)
end
X.def { name = "PLANSEL", status = "static", ref = "lane 2 report (not run)", helper = true,
  ready = function(S, rec)
    local m = rec.obj; if not valid(m) then return nil, "planner building gone" end
    if not X.owned(m) then return nil, "not the lord's" end
    return X.bkeyOf(X.bident(m)) .. " " .. rec.ref .. " " .. rec.op .. (SEL[rec.op].arg and ("," .. rec.v) or "")
  end,
  apply = function(S, job)
    local m = X.findBkey(job.f[1]); if not m then return "retry:planner building not found" end
    local kind, where = (job.f[2] or ""):match("^(%a):(.+)$")
    local op, v = (job.f[3] or ""):match("^(%u+),?(-?%d*)$")
    local d = op and SEL[op]; if not (kind and d) then return "bad fields" end
    local part
    if kind == "w" then local n, ws = int(where), m.walls; if n and n >= 1 and n <= #ws then part = un(ws[n]) end   -- within the list only: a read past its end would grow it
    else
      local x1, y1, x2, y2 = where:match("^(-?[%d%.]+),(-?[%d%.]+):(-?[%d%.]+),(-?[%d%.]+)$")
      local n = nums(where)
      if x2 then part = wallAt(m, tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2))      -- a wall: its place and its end
      elseif n[1] and n[2] then part = bpAt(m, n[1], n[2], 60) end
    end
    if not valid(part) then return (op == "DEL") and "ok" or "part of the plan not found" end
    local h = A.helper(); if not valid(h) then return "no helper" end
    if not enter(h, m) then return "the helper could not enter planning mode" end
    local okS, err = pcall(function()
      h:selectCastleBlueprint(part, false)
      if d.arg then h[d.fn](h, int(v)) else h[d.fn](h) end
    end)
    pcall(function() h:deselectCastleBlueprint() end)
    leave(h)
    if not okS then return "error " .. tostring(err) end
    X.touch(m)
    return "ok"
  end }
-- lane 26 (2026-11-12): switched on to be pressed on two copies (the floater's own buttons after the game's
-- selectCastleBlueprint); see lane_s21_26/report.txt for the result.
B.selTested = true
if T.enabled.PLANSEL == true and not B.selTested then T.enabled.PLANSEL = false end      -- see the comment above

-- ================================================================ CASTLE: the planner's construct step
-- One named game call on the manor; the same call replays it on a copy whose plan is equal. Measured (lane 2, run s5):
-- with the game's own canConstructCastle true, the call leaves one ghost actor per blueprint on the manor and empties the
-- manor's cost list, the same on both copies; the world's building list does not grow at that moment. The call does
-- not check canConstructCastle itself (run s4: it ran while that was false), so the host refuses a line the game's own
-- check says no to, as the planner's button would be greyed out.
X.setter("CASTLE", "SMBuildingMaster", "convertBlueprintsToBuildings", "b", "console2", "lane 2 runs s4, s5", true)
do
  local d = T.defs.CASTLE; local plain = d.apply
  d.apply = function(S, job)
    if S.role == "host" then
      local m = X.findBkey(job.f[1])
      if m then
        local okC, can = pcall(function() return m:canConstructCastle({}) end)
        if okC and can == false then return "the castle cannot be constructed on the host (the game's own check)" end
      end
    end
    return plain(S, job)
  end
end

-- ================================================================ GATE: open or close a gate
-- SEE: pre-hook GateComponent:ToggleGatesOpen (the floating gate button's handler calls it; the game's native code
-- never does: the routine's only caller in the game file is its script thunk, lane 28). The hook only keeps the
-- component and its state before the call; the tick finds the building that owns it.
--   GATE <building> <x,y of the gate's part> <1 open | 0 closed>     (the state AFTER the toggle, never "toggle")
-- What a gate is (lane 28, read and measured): a building's parts are its `buildings` (SMBuilding); when the building
-- is finished the game gives a part a GateComponent (`controllableGate`) if the part's mesh has a socket "gate".
-- getControllableGates() returns those PARTS. A drawn wall gets such a part where it crosses a road, once the wall is
-- upgraded (wallType 3) and constructed; the plain palisade's gate has no such socket. A gate is named by its
-- building and the place of its part (the order of the parts on another copy is not relied on).
X.hook(P .. "GateComponent:ToggleGatesOpen", { "GATE" }, function(self)
  local g = self:get(); if not valid(g) then return nil end
  return { k = "GATE", gate = g, gaddr = addrOf(g), was = g.bGatesOpened == true }
end)
local function gatesOf(b)
  local ok, arr = pcall(function() return b:getControllableGates() end)
  if not ok or arr == nil then return {} end
  local t = {}
  for i = 1, #arr do
    local part = un(arr[i])
    if valid(part) then
      local okG, g = pcall(function() return un(part.controllableGate) end)
      local okL, l = pcall(function() return part:K2_GetActorLocation() end)
      if okG and okL and valid(g) then t[#t + 1] = { part = part, gate = g, x = l.X, y = l.Y } end
    end
  end
  return t
end
B.gatesOf = gatesOf
X.def { name = "GATE", status = "press2", ref = "lane 28 report (two copies, both ways, after a resync)",
  ready = function(S, rec)
    if not valid(rec.gate) then return nil, "gate gone" end
    local b, hit
    local arr = S.eng.buildingArr
    for i = 1, #arr do
      local x = un(arr[i])
      if valid(x) and X.owned(x) then
        for _, e in ipairs(gatesOf(x)) do if addrOf(e.gate) == rec.gaddr then b, hit = x, e; break end end
      end
      if b then break end
    end
    if not b then return nil, "the gate's building was not found among the lord's buildings" end
    return X.bkeyOf(X.bident(b)) .. " " .. string.format("%.0f,%.0f", hit.x, hit.y) .. " " .. (rec.was and "0" or "1")
  end,
  apply = function(S, job)
    local b = X.findBkey(job.f[1]); if not b then return "retry:building not found" end
    local n = nums(job.f[2]); if not (n[1] and n[2]) then return "bad fields" end
    local best, bd
    for _, e in ipairs(gatesOf(b)) do
      local dd = math.abs(e.x - n[1]) + math.abs(e.y - n[2])
      if dd <= 200 and (not bd or dd < bd) then best, bd = e.gate, dd end
    end
    if not best then return "this building has no gate at " .. tostring(job.f[2]) end
    local want = (job.f[3] == "1")
    if (best.bGatesOpened == true) ~= want then best:ToggleGatesOpen() end
    X.touch(b)
    return "ok"
  end }

-- ================================================================ PLANMOVE: a planned part dragged or turned (lane 37)
-- SEE: dragging a placed part in the planner (left button held on it) runs no function of the script layer (recorder,
-- lane 37: only the LMB input events and the cost/availability UI updates) and moves the part's actor; the other copies
-- kept the old place (real drag on the friend: 100118,-70273 -> 99843,-69695 there, the host unchanged). So: while
-- this copy's own lord is in planning mode, the places and turns of its manor's planned parts (walls excepted: PLANWALL
-- and PLANSEL) are read twice a second; a part that moved (more than 5 units or 0.5 degrees) and was not just moved by
-- a replay is sent:  PLANMOVE <manor> b:<old x>,<old y> <x>,<y>,<z>,<yaw>
-- REPLAY: the part at the old place gets the new place and turn (its actor; the plan is made of these actors).
local PM = { seen = {}, t = 0 }
local function pmScan(S, clock)
  local p = S.p1; if not valid(p) then return end
  local inPlan, m = false, nil
  pcall(function() inPlan = p.inPlanningMode == true; m = p.plannerModeBld end)
  if not (inPlan and valid(m)) then PM.seen = {}; return end
  local ma = addrOf(m)
  local now = {}
  local arr = m.blueprints
  for i = 1, #arr do
    local a = un(arr[i])
    if valid(a) then
      local okC, cn = pcall(function() return a:GetClass():GetFName():ToString() end)
      if okC and cn ~= "Road" then
        local l = a:K2_GetActorLocation(); local r = a:K2_GetActorRotation(); local ad = addrOf(a)
        now[ad] = { x = l.X, y = l.Y, z = l.Z, yaw = r.Yaw }
        local w = PM.seen[ad]
        local replayed = (T.touched[ma] and clock - T.touched[ma] < 2.0) or (T.touched[ad] and clock - T.touched[ad] < 2.0)
        if w and not replayed and (math.abs(w.x - l.X) > 5 or math.abs(w.y - l.Y) > 5 or math.abs(w.yaw - r.Yaw) > 0.5) and T.isOn("PLANMOVE") then
          T.emitAction(S, "PLANMOVE", string.format("%s b:%.0f,%.0f %.1f,%.1f,%.1f,%.2f", X.bkeyOf(X.bident(m)), w.x, w.y, l.X, l.Y, l.Z, r.Yaw))
        end
      end
    end
  end
  PM.seen = now
end
C.register("planmove", {
  onWorld = function(S) PM.seen = {} end,
  tick = function(S, clock)
    if C.hold or clock - PM.t < 0.5 then return end
    PM.t = clock
    local ok, e = pcall(pmScan, S, clock); if not ok then A.log("TOWN PLANMOVE scan error: %s", tostring(e)) end
  end })
X.def { name = "PLANMOVE", status = "lane 37 (real drag on two copies)", ref = "lane_s21_37",
  ready = function(S, rec) return nil, "sent by the scan" end,
  apply = function(S, job)
    local m = X.findBkey(job.f[1]); if not m then return "retry:planner building not found" end
    local x, y = tostring(job.f[2]):match("^b:(-?[%d%.]+),(-?[%d%.]+)$")
    local nx, ny, nz, yaw = tostring(job.f[3]):match("^(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)$")
    if not (x and nx) then return "bad fields" end
    local part = bpAt(m, tonumber(x), tonumber(y), 60)
    if not valid(part) then return "part of the plan not found" end
    X.touch(m); X.touch(part)
    local ok, e = pcall(function() part:K2_SetActorLocationAndRotation({ X = tonumber(nx), Y = tonumber(ny), Z = tonumber(nz) }, { Pitch = 0.0, Yaw = tonumber(yaw), Roll = 0.0 }, false, {}, true) end)
    if not ok then return "error " .. tostring(e) end
    pcall(function() local l = part:K2_GetActorLocation(); local r = part:K2_GetActorRotation(); PM.seen[addrOf(part)] = { x = l.X, y = l.Y, z = l.Z, yaw = r.Yaw } end)
    return "ok"
  end }

-- ================================================================ PLANWPTS: a placed wall's control points changed (lane 53)
-- SEE: a wall that stands in the plan can be changed with the pointer: a control point dragged (also by a gate
-- marker), taken away (alt-click) or added (shift-click). None of it passes the script layer. Read in the game file
-- (lanes/lane_s21_53/report.txt): the planner's per-frame update (4b30c90) and its press handler (4b170f0) do one
-- thing for all of these: they change the wall's control points (Road +318h) and call the wall's own rebuild
-- (4cd6430), which sets the spline, works the gates out again and spawns the pieces again.
-- So: while this copy's own lord is in planning mode, the control points of its manor's planned walls are read twice a
-- second (coop_patch WALLGET); a wall whose points changed, once the button is up, is sent:   PLANWPTS <manor> <the old points> <the new points> <the gates' places | ->
-- The wall is named by its old points (never by a list number or a kept object). The numbers go out with two decimals
-- and the sending copy writes the same rounded numbers into its own wall first, so every copy holds the same numbers.
-- REPLAY: the wall with the old points gets the new ones through coop_patch WALLSET (the same write and the game's own
-- rebuild; more points than the list holds: the game's own insert lengthens it). No helper lord is needed. The gates'
-- heights are taken from the sending copy as PLANWALL does (lane 32).
-- A wall is told apart by its object name (an address can be used again by a new wall).
local WP = { seen = {}, m = nil, t = 0 }
B.wallPts = WP
local function ctlLine(q) local t = {}; for i, v in ipairs(q) do t[i] = string.format("%.2f,%.2f,%.2f", v.X, v.Y, v.Z) end; return table.concat(t, "|") end
local function gateLine(g) local t = {}; for i, q in ipairs(g or {}) do t[i] = string.format("%.2f,%.2f,%.4f", q.X, q.Y, q.Z) end; return #t > 0 and table.concat(t, "|") or "-" end
local function wallName(w) local ok, n = pcall(function() return w:GetFName():ToString() end); return (ok and n and n ~= "") and n or ("@" .. tostring(addrOf(w))) end
local function wallSetOk() local Pt = C.patch; return Pt and Pt.wallSet and Pt.wallGet and Pt.wallSetAvail and Pt.wallSetAvail() end
-- the wall of the plan with exactly these control points, in this order (rev: or the other way round; a wall turned
-- round on one copy then gets the sender's order with the new points)
local function wallWith(m, pts, tol, rev)
  for _, w in ipairs(wallsOf(m)) do
    local g = C.patch.wallGet(w); local q = g and g.ctl
    if q and #q == #pts then
      local fwd, bwd = true, rev == true
      for i = 1, #pts do
        if fwd and not near1(q[i], pts[i], tol) then fwd = false end
        if bwd and not near1(q[#q + 1 - i], pts[i], tol) then bwd = false end
        if not (fwd or bwd) then break end
      end
      if fwd or bwd then return w, g end
    end
  end
  return nil
end
local function wpScan(S, clock)
  local p = S.p1; if not valid(p) then return end
  local inPlan, m, busy, last = false, nil, false, false
  pcall(function() inPlan = p.inPlanningMode == true; m = p.plannerModeBld end)
  if not (inPlan and valid(m)) then
    -- the planner was just left: one last look at its walls (a change made in the last half second)
    if not WP.mkey then return end
    m = X.findBkey(WP.mkey); last = true
    if not valid(m) then WP.seen = {}; WP.m = nil; WP.mkey = nil; return end
  end
  if not wallSetOk() then return end
  local ma = addrOf(m)
  if WP.m ~= ma then WP.seen = {}; WP.m = ma end
  WP.mkey = X.bkeyOf(X.bident(m))
  -- the button still down (a drag going on): the change is looked at when it is up
  if not last then pcall(function() busy = p.LMB_pressed_b == true or valid(p.draggingBlueprint) end) end
  local now = {}
  for _, w in ipairs(wallsOf(m)) do
    local g = C.patch.wallGet(w)
    if g and #g.ctl >= 2 then
      local key = wallName(w); local line = ctlLine(g.ctl); local was = WP.seen[key]
      if was and was ~= line then
        if busy then line = was
        elseif T.isOn("PLANWPTS") and X.owned(m) then
          local okS, r = C.patch.wallSet(w, g.ctl)                  -- this copy's own wall: the rounded numbers that go out
          local g2 = okS and C.patch.wallGet(w) or g
          if not okS then A.log("TOWN PLANWPTS: this copy's own wall kept its exact numbers (%s)", tostring(r)) end
          T.emitAction(S, "PLANWPTS", string.format("%s %s %s %s", X.bkeyOf(X.bident(m)), was, line, gateLine(g2 and g2.gates)))
        end
      end
      now[key] = line
    end
  end
  -- (lane 53) a wall that left the plan: alt-click on a wall removes the whole wall in 0.8.117 (measured with the
  -- lord's own handlers on both copies, alt held or not), natively: no hook sees it. Sent as PLANWPTS <manor> <old> -
  -- unless this copy's own player just did something the mod already carries (the delete button, an upgrade, the
  -- construct step: PLANSEL, DEMOLISH, CASTLE), or a replay just changed this plan, or a wall with the same points is
  -- still there (a wall rebuilt as a new object).
  if not busy and T.isOn("PLANWPTS") and X.owned(m) then
    local replayed = T.touched[ma] and clock - T.touched[ma] < 2.0
    local ownAct = false
    for i = #(T.ownList or {}), math.max(1, #(T.ownList or {}) - 5), -1 do
      local o = T.own[T.ownList[i]]
      if o and os.clock() - o.t < 2.0 and (o.act == "PLANSEL" or o.act == "DEMOLISH" or o.act == "CASTLE" or o.act == "PLANWALL") then ownAct = true end
    end
    if not (replayed or ownAct) then
      local lines = {}
      for _, l in pairs(now) do lines[l] = true end
      for key, was in pairs(WP.seen) do
        if not now[key] then
          local q = C.patch.decPoints(was); local r = {}
          for i = #q, 1, -1 do r[#r + 1] = q[i] end
          if not (lines[was] or lines[ctlLine(r)]) then
            T.emitAction(S, "PLANWPTS", string.format("%s %s - -", X.bkeyOf(X.bident(m)), was))
          end
        end
      end
    end
  end
  -- while the button is down nothing is decided: a wall that left the plan at the press (the alt-click removes it on
  -- the press) is still looked for when the button is up
  if busy then for key, was in pairs(WP.seen) do if not now[key] then now[key] = was end end end
  WP.seen = now
  if last then WP.seen = {}; WP.m = nil; WP.mkey = nil end
end
C.register("planwpts", {
  onWorld = function(S) WP.seen = {}; WP.m = nil; WP.mkey = nil; WP.was = false end,
  tick = function(S, clock)
    if C.hold then return end
    -- the planner entered or left: looked at at once (the walls as they stand before the first change; the last
    -- change before leaving); else twice a second, and only while the planner is open
    local inPlan = false; local p = S.p1
    if not valid(p) then return end
    pcall(function() inPlan = p.inPlanningMode == true end)
    if inPlan == WP.was and (not inPlan or clock - WP.t < 0.5) then return end
    WP.was = inPlan
    WP.t = clock
    local ok, e = pcall(wpScan, S, clock); if not ok then A.log("TOWN PLANWPTS scan error: %s", tostring(e)) end
  end })
X.def { name = "PLANWPTS", status = "native2", ref = "lane 53 report (two copies, both ways)", helper = true,
  ready = function(S, rec) return nil, "sent by the scan" end,
  apply = function(S, job)
    if not wallSetOk() then return "the native piece (coop_patch WALLSET) is not available on this copy: the wall keeps its old shape here" end
    local m = X.findBkey(job.f[1]); if not m then return "retry:planner building not found" end
    if job.f[3] == "-" then
      -- the wall left the plan on the sending copy (alt-click): the helper removes it the way the delete button does
      -- (selectCastleBlueprint, destroySelectedCastleBlueprint: PLANSEL's DEL); already gone here: nothing to do
      local old = C.patch.decPoints(job.f[2]); if #old < 2 then return "bad points" end
      local w = wallWith(m, old, 0.05, true); if not w then return "ok" end
      local h = A.helper(); if not valid(h) then return "no helper" end
      if not enter(h, m) then return "the helper could not enter planning mode" end
      X.touch(m)
      local okS, err = pcall(function() h:selectCastleBlueprint(w, false); h:destroySelectedCastleBlueprint() end)
      pcall(function() h:deselectCastleBlueprint() end)
      leave(h)
      if not okS then return "error " .. tostring(err) end
      if wallWith(m, old, 0.05, true) then return "the wall is still in the plan" end
      A.log("TOWN planner wall removed (%d control points)", #old)
      return "ok"
    end
    local old, new = C.patch.decPoints(job.f[2]), C.patch.decPoints(job.f[3])
    -- (lane 55) up to 64 points (coop_patch WALLSET): the draw tool stops at 21, but a placed wall grows past that by
    -- the game's own shift-click and gate-marker inserts
    if #old < 2 or #new < 2 or #new > 64 then return "bad points" end
    local w, g = wallWith(m, new, 0.006)                            -- already so (a repeated line)
    if not w then
      w = wallWith(m, old, 0.05, true)
      if not w then
        -- (lane 55) the one wall of the plan with as many points, every one within 10 m of the old ones (a wall whose
        -- points this copy's game had put a little elsewhere before this lane's PLANWALL fix, or after a resync): it
        -- gets the sender's new points, so the two plans are the same again instead of a refusal and a resync
        local hit, n = nil, 0
        for _, x in ipairs(wallsOf(m)) do
          local gx = C.patch.wallGet(x); local q = gx and gx.ctl
          if q and #q == #old then
            local fwd, bwd = true, true
            for i = 1, #old do
              if not near1(q[i], old[i], 1000.0) then fwd = false end
              if not near1(q[#q + 1 - i], old[i], 1000.0) then bwd = false end
            end
            if fwd or bwd then hit = x; n = n + 1 end
          end
        end
        if n ~= 1 then return "no wall of the plan has the old points here" end
        w = hit; A.log("TOWN planner wall: no wall with the sender's old points; the one wall near them (%d points) is taken", #old)
      end
      X.touch(m)
      local okS, r = C.patch.wallSet(w, new)
      if not okS then return "the wall was not changed: " .. tostring(r) end
      g = C.patch.wallGet(w)
      A.log("TOWN planner wall changed: %d -> %d control points (%s)", #old, #new, tostring(r))
    end
    -- the gates' heights as the sending copy has them (each copy works them out apart: lane 28, lane 32)
    local want = (job.f[4] and job.f[4] ~= "-") and C.patch.decPoints(job.f[4]) or {}
    for _, q in ipairs(want) do
      for i, have in ipairs(g and g.gates or {}) do
        if near1(have, q, 1.0) then
          if math.abs(have.Z - q.Z) > 0.00005 and C.patch.gateSet then C.patch.gateSet(w, i - 1, q) end
          break
        end
      end
    end
    if g and WP.m == addrOf(m) then WP.seen[wallName(w)] = ctlLine(g.ctl) end
    return "ok"
  end }

-- (the development channel that was here lives in coop_dev.lua, which is never put into the zip for players)

return "coop_x_build " .. B.version .. " loaded"
