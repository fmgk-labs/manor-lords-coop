-- Manor Lords Co-op: town actions (plug-in module for coop.lua, development build).
--
-- WHAT IT DOES
--   When the local player does a town action, this copy sends one "T" line. A friend's line reaches only the host; the host
--   replays it and then sends it on to every friend with the origin kept, so the friend who did it ignores it. The host's
--   own actions go straight to every friend. A replay is never reported back as a new action (see ECHO below).
--   Line (after the core's "<seq> <wallclock> "):   T <origin> <n> <ACTION> <field> <field> ...
--     fields never contain a space: numbers inside a field are joined by ",", points by "|", parts of a house lot by "/";
--     positions are whole units (cm), angles one decimal, quaternions five decimals, names percent-encoded.
--   The host is the referee: what it cannot replay it refuses with   T host <n> NAK <origin>:<n> <reason>
--   and does not pass on. The copy that did the action then differs from the host; the repair is a reload of the host's save.
--
-- THREADING (lanes/lane_n/threading.txt, rules in COMMON_BRIEF2)
--   * Hook callbacks only read their arguments and plain properties, take object addresses (GetAddress, a UE4SS method, not a
--     game function) and push a record onto T.q. They never call game functions, open files or register hooks.
--     Consequence: anything that is destroyed before the next tick (a moved building's old copy, a demolished building, a
--     removed road) is named from an address -> identity index that tick() keeps up to date in small slices (T.bidx, T.ridx).
--   * Everything else runs in tick(S, clock), called by the core on the game thread every frame; work per tick is bounded.
--   * Hooks are registered from tick with pcall, retried every 2 s, only for enabled actions; a _G table keeps them across
--     reloads of this file, and the callbacks look up _G.Coop.town at call time so reloaded code is used.
--
-- ECHO (a replay must never be reported as a new action)
--   * pawn hooks (playBuildEffects, commitRoad, addCommitFieldRequest, removeRoad, deselectBuilding, add*Request): only calls
--     made on the LOCAL lord (S.p1) count. Replays go through the helper lord (or straight to a building), so their hooks,
--     whether they fire in the same call or a few ticks later, are ignored.
--   * object hooks (building and region setters): T.depth > 0 while a replay runs blocks the same-call echo. After it, an
--     echo is told apart from a player's action by WHAT it is, never by time alone (lane 81): an absolute value (a setter
--     that is not relative, a panel-written field, MAINT, TRAINREG) has a "slot" (kind, target, and the arguments that
--     pick the value, e.g. the good; selVal). A replay writes the value it applied into T.expect[slot] for 3 s; a
--     local record for that slot with the SAME value is the echo and is dropped; a record with ANOTHER value is the
--     player's and is sent, and it ends the expectation (so the player going back to the replayed value is sent too).
--     Until lane 81 every record on a target replayed in the last 0.75 s was dropped: a player's change to a region
--     setting inside 0.75 s of the other player's change to that region was lost (known issue G22, lane 80: host 34,
--     friend 33 for 44 s). Relative actions and actions caught on the local lord have no value to compare: the depth
--     marker and the local-lord test are their only guards, as they are the only thing that can make such a call.
--     Records for buildings or regions the local lord does not own are dropped too.
--   * other modules that call these setters to correct state must wrap the call: Coop.town.quiet(function() ... end).
--   * ORDER (lane 81): the host applies lines in the order they reach it and every copy must end with the host's last
--     value. A friend ignores its own line coming back from the host; so when another player's line for the same slot
--     is applied here AFTER this friend sent its own (the two crossed), the host applied this friend's line last, and
--     the friend puts its own value back when its own line comes back (T.ownSlot; decided in the apply queue, in the
--     host's order: ownBack). A sent local record also ends every echo expected on its target, of any kind.
--
-- STATUS (each action's def carries it; "live" and "live1" actions are on by default; Coop.town.enable(name, true) switches one on)
--   live   = SEE point and replay recipe both run live (README sessions given per action)
--   live1  = proven live on one copy (README session 14): a hook saw every scripted call with its arguments and the same
--            call replays it; the two-copy relay itself has not run yet
--   seen   = the SEE call was recorded live with real clicks, the replay was not run live
--   static = static read only (lanes/lane_t1 or lane_t2 recipe id given per action)
--
-- HAZARDS FROM LIVE RUNS (README session 14 and the coordinator's runs after it)
--   * A helper placement of a type with a treasury cost crashed the game twice on the helper's next tick when the helper
--     could not afford it (type 52, cost 50, helper.silver 0; access violation reading 0x658 in game code). Funded first
--     (helper.silver = cost + 100) the same placement worked: owner and region the lord's, the helper's silver dropped by
--     exactly the cost, the lord's did not change (T14 confirmed: the helper pays). So a BUILD / MOVE replay: reads the
--     type's cost (eng:getBuildingData(type).constructionCost); on the host refuses it (NAK to the origin) when the lord
--     cannot afford it; sets helper.silver = cost right before requestBuild (never requestBuild while helper.silver < cost);
--     once the building is there, the host charges the lord S.p1:ChangeTreasury(-cost); every copy sets helper.silver back
--     to 0. Friends do not charge their lord: the host's treasury push is the truth. T.cfg.payCost = false refuses every
--     costed type instead. Types seen with a cost in the test save: 52 (50), 107 (250).
--   * building:demolish(...) is never called directly (it was in the script that crashed first): demolish goes through the
--     helper's demolishRequests list, as the click does.
--   * A lord object made with SpawnActor starts its own 600 s autosave timer: this module never spawns a pawn, it only
--     uses A.helper(), which stops that timer.
--   * While the core holds for a join or repair (C.hold), this module records nothing and replays nothing.
--   The capture of BUILD is the proven one (session 7b/8). ROAD and FIELD replay the proven recipes, but their capture differs
--   from the proven probe because of the callback rule: ROAD reads the new road's spline in the next tick (session 8 read the
--   draft spline inside the hook), FIELD copies the pawn's draft in the hook and waits for the committed building for its
--   corners (session 8 replayed scripted values). Those two captures are therefore not yet run live.
--
-- LEFT OUT (not built), with the reason
--   claims (layClaim on the lord, paid natively; the claim completes on a native timer on each copy: the host must decide and
--   push - lane_t2 T12a), policies (setPolicySigned / enactPolicy; may be hidden in 0.8 by RemovePolicies_EarlyAccess, costs
--   partly unread - T11b), militia (addMilitiaSquad makes squads whose numbers differ per copy: belongs with the core's squad
--   map - T13a), quests and letters (Director rolls and AI replies are random per copy: host-only plus a push - T15), perks
--   (replay needs an unshown panel instance, GUESS - T10a), and also: market plots (plotType 4, T4b, not probed), work area
--   set (native click path, T7e), click-assign of a family in the world (native, T6c), property-only settings (stall toggle,
--   storage filter, fuel, overstock - T7m), gates (component target - T7l), pack-train destination
--   (native - T7n), region rename (T7o), rally / disband / mercenaries / retinue (army lane), castle planner and walls.
--
-- DEVELOPER CONSOLE
--   Coop.town.status()  Coop.town.list()  Coop.town.enable("SLEEP", true)  Coop.town.quiet(fn)
--   test aids (used by tests/town/*.lua): Coop.town.test.cap() / uncap() / pump() / hooksNow(), Coop.town.inject(act, fields)

local C = rawget(_G, "Coop")
if not (C and C.register and C.api) then return "coop_town: load coop.lua first" end
local A = C.api
C.town = C.town or {}
local T = C.town
T.version = "0.1-dev"

-- ---------------------------------------------------------------- persistent state (survives reloads of this file)
T.enabled = T.enabled or {}
if T.flagsVer ~= 3 then T.enabled = {}; T.flagsVer = 3 end   -- defaults changed in session 18 (every action on): start from them
T.cfg = T.cfg or {}
local CFG_DEFAULT = {
  tolB = 150,            -- building found by type + position within this many units (lane_t1/t2 probes use 150)
  tolR = 300,            -- road end points match within this (lane_t1 T5b)
  maxQueue = 200,        -- hook records kept at most (a stopped tick must not grow memory)
  payCost = true,        -- place types with a treasury cost through the helper, funding it first (see HAZARDS); off = refuse them
  placeGate = "refuse",  -- (lane 81) host: a friend's building on a place already taken here is refused ("log": only logged; "off")
  areaGate = "refuse",   -- (lane 81) the same for a friend's field, pasture, market or burgage plots (by the outline its line carries):
                         -- refused only for the kinds in areaRefuse (their undo proven in the game), logged for the others; "off": no check
  areaRefuse = { FIELD = true, PASTURE = true },
  moveCost = true,       -- T14 on the host: charge the lord the cost of a helper placement (friends: the host's treasury push rules)
  fieldClockwise = false,-- also write borderIsClockwise after a field replay (lane_t1 T3, static)
  retryS = 3.0,          -- a replay whose target is not there yet (BUILD then SLEEP) is retried this long
  reqWait = true,        -- (lane 76, round 4) the host's UPGRADE / EXT / ARTISAN line waits for its own game's pump
  reqRefuse = true,      -- (lane 76, round 5) ... and is not sent when its game did not carry the request out
}
if T.cfgVer ~= 2 then T.cfg.payCost = nil; T.cfgVer = 2 end          -- the payCost default changed after a live confirmation
for k, v in pairs(CFG_DEFAULT) do if T.cfg[k] == nil then T.cfg[k] = v end end
T.seq = T.seq or (os.time() % 100000) * 1000   -- origin:n must stay unique across game restarts with the same name
T.depth = 0
T.results = T.results or {}

-- ---------------------------------------------------------------- small helpers
local un, valid, far = A.un, A.valid, A.far
local function rnd(v) return math.floor(v + 0.5) end
local function addrOf(o) if o == nil then return nil end; local ok, a = pcall(function() return o:GetAddress() end); return ok and a or nil end
local function nameOf(o) local ok, n = pcall(function() return o:GetFName():ToString() end); return ok and n or "?" end
local function int(v) v = tonumber(v); if v == nil then return 0 end; return math.tointeger(v) or rnd(v) end
local function stat(S, k, d) S.stats[k] = (S.stats[k] or 0) + (d or 1) end
-- play-time clock for every timeout (placement, demolish, waiting for a commit, retries): it stops while the lord's game is
-- paused (pauseGame), when the helper's Tick and the engine's commit may not run, so nothing times out just because of a pause.
-- It advances in tick(); only speed-0 placements were proven live, a placement under pauseGame never was.
local function vnow() return T.vt or 0 end
local function advanceClock(S)
  local c = os.clock()
  local paused = false; pcall(function() paused = A.isPaused() end)
  if T.lastC and not paused then T.vt = (T.vt or 0) + (c - T.lastC) end
  T.lastC = c
end

local function split(s, sep)
  local t, i = {}, 1
  if s == nil then return t end
  while true do
    local j = s:find(sep, i, true)
    if not j then t[#t + 1] = s:sub(i); break end
    t[#t + 1] = s:sub(i, j - 1); i = j + #sep
  end
  return t
end
local function nums(s) local t = {}; for i, x in ipairs(split(s, ",")) do t[i] = tonumber(x) end; return t end
local function enc(s) return (tostring(s):gsub("[%s,|/%%]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function dec(s) return (tostring(s):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local function vcopy(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function acopy(a) local t = {}; for i = 1, #a do t[i] = vcopy(a[i]) end; return t end
-- positions travel with two decimals (0.01 cm): a building is named by its position rounded to 10 cm, and sent rounded
-- to 1 cm the two copies could land on different sides of a rounding step and name the same building differently
-- (session 20: a corpse pit was 113@-8429 on the host and 113@-8430 on the friend)
local function encV(v) return string.format("%.2f,%.2f,%.2f", v.X, v.Y, v.Z) end
local function decV(s) local n = nums(s); if not (n[1] and n[2] and n[3]) then return nil end; return { X = n[1] + 0.0, Y = n[2] + 0.0, Z = n[3] + 0.0 } end
local function encPts(t) if #t == 0 then return "-" end; local o = {}; for i, v in ipairs(t) do o[i] = encV(v) end; return table.concat(o, "|") end
local function decPts(s) local t = {}; if not s or s == "-" then return t end; for _, p in ipairs(split(s, "|")) do local v = decV(p); if v then t[#t + 1] = v end end; return t end
local function encRot(r) return string.format("%.1f,%.1f,%.1f", r.Pitch, r.Yaw, r.Roll) end
local function decRot(s) local n = nums(s); return { Pitch = (n[1] or 0) + 0.0, Yaw = (n[2] or 0) + 0.0, Roll = (n[3] or 0) + 0.0 } end
local function trcopy(x)
  local q, tr, sc = x.Rotation, x.Translation, x.Scale3D
  return { Rotation = { X = q.X, Y = q.Y, Z = q.Z, W = q.W }, Translation = vcopy(tr), Scale3D = vcopy(sc) }
end
local function encTr(x)
  local q, t, s = x.Rotation, x.Translation, x.Scale3D
  return string.format("%.5f,%.5f,%.5f,%.5f,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f", q.X, q.Y, q.Z, q.W, t.X, t.Y, t.Z, s.X, s.Y, s.Z)
end
local function decTr(s)
  local n = nums(s); for i = 1, 10 do n[i] = (n[i] or ((i == 4 or i >= 8) and 1 or 0)) + 0.0 end
  return { Rotation = { X = n[1], Y = n[2], Z = n[3], W = n[4] }, Translation = { X = n[5], Y = n[6], Z = n[7] }, Scale3D = { X = n[8], Y = n[9], Z = n[10] } }
end

-- ---------------------------------------------------------------- identity: buildings, regions, roads, families, goods
-- A building is named by type + position: unique in every fingerprint so far (README session 8), while unique ids are
-- regenerated on every load (session 7d). Key in a line: "type,x,y,z".
local function bident(b)
  local l = b:K2_GetActorLocation(); local r = b:K2_GetActorRotation()
  return { t = A.btype(b), x = l.X, y = l.Y, z = l.Z, yaw = r.Yaw }
end
-- (lane 76) The game clears a demolished building's actor before IsValid turns false: its type reads 0 and its place
-- 0,0,0 for a moment (l76d: a friend's demolish went out as "DEMOLISH 0,0,0,0", the host refused it, the friend
-- resynced). An identity is usable only with a type above 0 and a place that is not exactly the origin.
local function usableB(id)
  return type(id) == "table" and type(id.t) == "number" and id.t > 0 and type(id.x) == "number" and type(id.y) == "number" and type(id.z) == "number"
    and id.x == id.x and id.y == id.y and id.z == id.z and not (id.x == 0 and id.y == 0 and id.z == 0)
end
local function indexedB(b)
  local a = addrOf(b); local e = a and T.bidx[a]
  if usableB(e) and e.name ~= "?" and e.name == nameOf(b) then return e end
end
-- The safe name of a building in the tick (every module's X.bident): the live read when it is usable, else what the
-- index kept of this same object while it was whole, else nil (the line is then not sent, see sendTown).
local function identB(b)
  if not valid(b) then return nil end
  local ok, id = pcall(bident, b)
  if ok and usableB(id) then return id end
  return indexedB(b)
end
-- The name of a building inside a hook callback, taken while the actor is alive. A hook may only read properties.
-- The type is read live (a building's type changes in place: an upgrade, type 75 while it changes); the place comes
-- from the index (world transforms, also of attached buildings). A newly placed building that is not indexed yet
-- and has no parent: its root's relative transform is its world transform. A cleared actor (type 0): what the index
-- kept. nil = no usable name here; the tick then tries identB before the line is given up.
local function captureB(b)
  if not valid(b) then return nil end
  local e = indexedB(b)
  local t = 0
  pcall(function()
    t = b.Data.bType
    if t == 75 then local o = b.typeBeforeChange; if type(o) == "number" and o > 0 and o ~= 75 then t = o end end
  end)
  if type(t) ~= "number" or t <= 0 then return e end
  if e then
    if e.t == t then return e end
    return { t = t, x = e.x, y = e.y, z = e.z, yaw = e.yaw }
  end
  local id
  pcall(function()
    local root = b.RootComponent
    if not valid(root) or valid(root.AttachParent) then return end
    local pos, rot = root.RelativeLocation, root.RelativeRotation
    id = { t = t, x = pos.X, y = pos.Y, z = pos.Z, yaw = rot.Yaw }
  end)
  if usableB(id) then return id end
end
-- "-" for a building without a usable name: such a line is never sent (sendTown; the modules' own lines check it)
local function bkeyOf(e) if not usableB(e) then return "-" end; return string.format("%d,%.0f,%.0f,%.0f", e.t, e.x, e.y, e.z) end
local function bkeyYaw(e) if not usableB(e) then return "-" end; return string.format("%d,%.2f,%.2f,%.2f,%.1f", e.t, e.x, e.y, e.z, e.yaw or 0) end      -- a new building: exact place (see encV)
local function decB(s) local n = nums(s); if not (n[1] and n[2] and n[3]) then return nil end; return { t = int(n[1]), x = n[2], y = n[3], z = n[4] or 0, yaw = n[5] or 0 } end

-- address -> identity of every building, refreshed a slice per tick; written also whenever a building is seen or made here.
-- Only used to NAME an object that may be gone by the next tick; every use of a stored object is checked with IsValid first.
function T.addB(b, id)
  if not valid(b) then return nil end
  local a = addrOf(b); if not a then return nil end
  id = id or bident(b)
  if not usableB(id) then return nil end
  T.bidx[a] = { name = nameOf(b), t = id.t, x = id.x, y = id.y, z = id.z, yaw = id.yaw, obj = b, gen = T.bgen }
  return T.bidx[a]
end

-- find a building by type + position: rounded-key cache, then the index, then a live scan of eng.buildingArr. Never returns
-- a dead object: the candidate is re-read live (an address can be reused by a new object).
function T.findB(t, x, y, tol)
  tol = tol or T.cfg.tolB
  local S = C.s
  local ck = string.format("%d:%d:%d", t, rnd(x / 100), rnd(y / 100))
  local function check(b)
    if not valid(b) then return false end
    local ok, ct = pcall(function() return A.btype(b) end)
    if not ok or ct ~= t then return false end
    local l = b:K2_GetActorLocation()
    return not far(l.X, l.Y, x, y, tol)
  end
  local c = T.bcache[ck]
  if c and check(c) then return c end
  T.bcache[ck] = nil
  local best, bd
  for _, e in pairs(T.bidx) do
    if e.t == t and not far(e.x, e.y, x, y, tol) then
      local d = math.abs(e.x - x) + math.abs(e.y - y)
      if (not bd or d < bd) and check(e.obj) then best, bd = e.obj, d end
    end
  end
  if not best then
    local arr = S.eng.buildingArr
    for i = 1, #arr do
      local b = un(arr[i])
      if valid(b) and A.btype(b) == t then
        local l = b:K2_GetActorLocation()
        if not far(l.X, l.Y, x, y, tol) then
          local d = math.abs(l.X - x) + math.abs(l.Y - y)
          if not bd or d < bd then best, bd = b, d end
        end
      end
    end
    if best then T.addB(best) end
  end
  if best then T.bcache[ck] = best end
  return best
end
local function findBkey(s) local e = decB(s); if not e then return nil end; return T.findB(e.t, e.x, e.y) end

-- A region is named by its unique tag, never by its name (renaming is itself a player action; lane_t2 conventions).
function T.rkey(r)
  local tag = ""; pcall(function() tag = r.regionUniqueTag:ToString() end)
  if tag ~= "" and tag ~= "None" then return enc(tag) end
  local id = "?"; pcall(function() id = tostring(r:getRegionUniqueID()) end)
  return "#" .. id
end
function T.findR(key)
  local r = T.rcache[key]
  if valid(r) and T.rkey(r) == key then return r end
  T.rcache[key] = nil
  local arr = C.s.eng.regions
  for i = 1, #arr do local x = un(arr[i]); if valid(x) and T.rkey(x) == key then T.rcache[key] = x; return x end end
  return nil
end

-- A road is named by its two end points (lane_t1 T5b). Key in a line: "ax,ay,bx,by".
local function rident(r)
  local sp = r.Spline; local n = sp:GetNumberOfSplinePoints()
  if not n or n < 1 then return nil end
  local a = sp:GetLocationAtSplinePoint(0, 1); local b = sp:GetLocationAtSplinePoint(n - 1, 1)
  return { ax = a.X, ay = a.Y, bx = b.X, by = b.Y, n = n }
end
local function roadPts(r)
  local sp = r.Spline; local t = {}
  for i = 0, sp:GetNumberOfSplinePoints() - 1 do local v = sp:GetLocationAtSplinePoint(i, 1); t[#t + 1] = { X = v.X, Y = v.Y, Z = v.Z } end
  return t
end
local function rkeyOf(e) return string.format("%.0f,%.0f,%.0f,%.0f", e.ax, e.ay, e.bx, e.by) end
local function sameEnds(e, ax, ay, bx, by, tol)
  return (not far(e.ax, e.ay, ax, ay, tol) and not far(e.bx, e.by, bx, by, tol)) or (not far(e.ax, e.ay, bx, by, tol) and not far(e.bx, e.by, ax, ay, tol))
end
function T.addRoad(r, id)
  local a = addrOf(r); if not a then return nil end
  id = id or rident(r); if not id then return nil end
  T.ridx[a] = { name = nameOf(r), ax = id.ax, ay = id.ay, bx = id.bx, by = id.by, n = id.n, obj = r, gen = T.rgen }
  return T.ridx[a]
end
function T.findRoad(ax, ay, bx, by)
  local tol = T.cfg.tolR
  -- (lane 64, task 64d) the index's road handles are kept up to one pass of the slices (seconds), and roads are in no
  -- native table: the guard of kept handles in valid() cannot know when a removed road is freed. So an entry is used
  -- only with the handle of the engine's road list of THIS tick at the same address (the list is read by address
  -- only: GetAddress does not touch a road); a road removed since the index saw it is never touched
  local arr = C.s.eng.roads
  local live = {}
  for i = 1, #arr do local r = un(arr[i]); local a = addrOf(r); if a then live[a] = r end end
  for a, e in pairs(T.ridx) do
    local r = live[a]
    if r and sameEnds(e, ax, ay, bx, by, tol) and valid(r) then
      local ok, id = pcall(rident, r)
      if ok and id and sameEnds(id, ax, ay, bx, by, tol) then e.obj = r; return r end
    end
  end
  for i = 1, #arr do
    local r = un(arr[i])
    if valid(r) then local ok, id = pcall(rident, r); if ok and id and sameEnds(id, ax, ay, bx, by, tol) then T.addRoad(r, id); return r end end
  end
  return nil
end

-- A family is its index in Region.workerFamilies (= the familyID every Region function takes; lane_t2 T6). A good is its
-- int enum value as passed to the setters (setProductionLimit(16, ...) seen live, session 7c).
local function famIds(b) local t = {}; local arr = b.assignedFamilyIDs; for i = 1, #arr do t[#t + 1] = int(un(arr[i])) end; table.sort(t); return t end
local function encIds(t) return #t > 0 and table.concat(t, ",") or "-" end
local function decIds(s) local t = {}; if s and s ~= "-" then for _, x in ipairs(split(s, ",")) do if tonumber(x) then t[#t + 1] = int(x) end end end; table.sort(t); return t end
local function set(t) local s = {}; for _, v in ipairs(t) do s[v] = true end; return s end
T.good = function(v) return int(v) end

-- ---------------------------------------------------------------- per-world state
function T.reset()
  T.q = {}; T.aq = {}; T.pend = nil
  T.bidx = {}; T.bcache = {}; T.bpos = 1; T.bgen = 1
  T.ridx = {}; T.rpos = 1; T.rgen = 1
  T.rcache = {}
  T.touched = {}; T.expect = {}; T.recentDem = {}; T.ownSlot = {}; T.goneB = {}; T.olCache = {}; T.undoQ = {}
  T.p1addr = nil
  T.reassignW = nil; T.wareaB = nil      -- (lane 59) a villager / a building noted by a hook (REASSIGN: watched for 90 s; WAREA): not kept past a load
end
if not T.q then T.reset() end
T.seenMsg = T.seenMsg or {}; T.seenList = T.seenList or {}
T.hookFail = T.hookFail or {}

-- index slices: a few buildings and roads per tick. A known address with the same object name keeps its identity; a new or
-- reused address is read live. Entries not seen in a full pass are dropped.
-- (lane 47, round two; back in round four) with the native building table (coop_snap.lua) the whole list is gone over
-- four times a second from the table, with no read of the game: an entry whose object is still the same one (address
-- and object number) is kept; a new or reused address is read live (T.addB), as before. Without the table: the slices
-- below. (Taken out in round two as a suspect of the friend's speed-8 close; round three found that close in the job
-- board, coop_x_jobs fillList: brought back with its own proof run.)
local function scanSnapB(S, recs, N)
  local t = os.clock()
  if t - (T.snapBT or 0) < 0.25 then return end
  T.snapBT = t
  for _, r in ipairs(recs) do
    local e = T.bidx[r.a]
    if e and e.sidx == r.idx then e.gen = T.bgen
    else
      local b = N.obj(r)
      if b and valid(b) then local okA, ne = pcall(T.addB, b); if okA and ne then ne.sidx = r.idx end end
    end
  end
  for a, e in pairs(T.bidx) do if e.gen ~= T.bgen then T.bidx[a] = nil end end
  T.bgen = T.bgen + 1
end
local function scanStep(S)
  local arr = S.eng.buildingArr; local n = #arr
  -- (lane 47, round two) the buildings at 150 a second whatever the frame rate (10 a frame was 150 a second at the
  -- harness's 15 frames, 600 at a player's 60): the test town's 110 buildings are gone over in 0.7 s.
  local tb = os.clock(); local dtb = math.min(0.5, math.max(0, tb - (T.bT or tb))); T.bT = tb
  T.bDebt = math.min((T.bDebt or 0) + 150 * dtb, 20)
  local nb = math.floor(T.bDebt); T.bDebt = T.bDebt - nb
  local N = rawget(C, "snap"); local recs = N and N.buildings and N.buildings()
  if recs then scanSnapB(S, recs, N); nb = 0 end
  -- lane 45: 10 buildings and 4 roads a frame (were 20 and 8: 0.9 ms a frame in sitting b0); the test town's 110
  -- buildings and 75 roads are gone over in about 1 s and 1.4 s (400 buildings: about 3 s). Buildings this copy makes or sees made are indexed at once (T.addB) anyway.
  for _ = 1, nb do
    if T.bpos > n then
      for a, e in pairs(T.bidx) do if e.gen ~= T.bgen then T.bidx[a] = nil end end
      T.bgen = T.bgen + 1; T.bpos = 1; break
    end
    local b = un(arr[T.bpos]); T.bpos = T.bpos + 1
    if valid(b) then
      local a = addrOf(b); local e = a and T.bidx[a]
      if e and e.name == nameOf(b) then e.gen = T.bgen; e.obj = b
      elseif a then pcall(T.addB, b) end
    end
  end
  local ra = S.eng.roads; local rn = #ra
  -- (lane 47, round two) the roads at 60 a second whatever the frame rate (4 a frame was 60 a second at the harness's 15
  -- frames, 240 a second at a player's 60): the test town's 75 roads are gone over in 1.25 s, as before at 15 frames
  local tc = os.clock(); local dtc = math.min(0.5, math.max(0, tc - (T.rT or tc))); T.rT = tc
  T.rDebt = math.min((T.rDebt or 0) + 60 * dtc, 8)
  local nr = math.floor(T.rDebt); T.rDebt = T.rDebt - nr
  for _ = 1, nr do
    if T.rpos > rn then
      for a, e in pairs(T.ridx) do if e.gen ~= T.rgen then T.ridx[a] = nil end end
      T.rgen = T.rgen + 1; T.rpos = 1; break
    end
    local r = un(ra[T.rpos]); T.rpos = T.rpos + 1
    if valid(r) then
      local a = addrOf(r); local e = a and T.ridx[a]
      if e and e.name == nameOf(r) then e.gen = T.rgen; e.obj = r
      elseif a then pcall(T.addRoad, r) end
    end
  end
end

-- ---------------------------------------------------------------- sending
function T.out(line)
  if T.cap then
    if os.clock() - (T.capT or 0) < 300 then T.cap[#T.cap + 1] = line; return end
    T.cap = nil                               -- a forgotten test capture must not swallow real traffic for long
  end
  A.send(line)
end

-- Most building actions use their first field. MOVE, PLAN, REASSIGN and train routes
-- name buildings in other positions too. A disconnected train endpoint is explicitly "-".
local firstBuilding = { BUILD=true, MOVE=true, DEMOLISH=true, EXTEND=true, UPGRADE=true, EXT=true, ARTISAN=true,
  ADDW=true, REMW=true, FAMS=true, MAINT=true, WAREA=true, TRAINREG=true, TRAINCON=true, ANAME=true,
  GATE=true, PLAN=true, PLANWALL=true, PLANSEL=true, PLANMOVE=true, PLANWPTS=true, PLANJOIN=true }
local function wireBuilding(key)
  if not key then return false end
  local fields = split(key, ",")
  if (#fields ~= 4 and #fields ~= 5) or table.concat(fields, ",") ~= key then return false end
  for _, field in ipairs(fields) do
    local n = tonumber(field)
    if not n or n ~= n or math.abs(n) == math.huge then return false end
  end
  local t = tonumber(fields[1])
  if not (t > 0 and t == math.floor(t)) then return false end
  return not (tonumber(fields[2]) == 0 and tonumber(fields[3]) == 0 and tonumber(fields[4]) == 0)   -- a cleared actor's place
end
T.wireBuilding = wireBuilding
local function sendTown(origin, seq, act, fields)
  local d = T.defs[act]
  if firstBuilding[act] or (d and d.target == "building") or act == "REASSIGN" then
    local f = split(fields or "", " ")
    local ok = wireBuilding(f[act == "REASSIGN" and 3 or 1])
    if act == "MOVE" or act == "PLAN" then ok = ok and wireBuilding(f[2]) end
    if act == "TRAINCON" then ok = ok and (f[2] == "-" or wireBuilding(f[2])) and (f[3] == "-" or wireBuilding(f[3])) end
    if not ok then
      if C.s and C.s.stats then stat(C.s, "t_emptyKey") end
      A.log("TOWN %s not sent: empty or unreadable building key (%s)", act, tostring(fields):sub(1, 80)); return false
    end
  end
  T.out(string.format("T %s %s %s %s", origin, tostring(math.tointeger(tonumber(seq)) or seq), act, fields))
  return true
end
function T.emitAction(S, act, fields)
  if not sendTown(S.name, T.seq + 1, act, fields) then return end
  T.seq = T.seq + 1
  -- remember our own recent actions by tag, so a refusal from the host can be undone by name (see the NAK branch)
  T.own = T.own or {}; T.ownList = T.ownList or {}
  local tag = S.name .. ":" .. T.seq
  T.own[tag] = { act = act, f1 = tostring(fields):match("^(%S+)"), all = tostring(fields), t = os.clock() }   -- (lane 81) the whole line: an undo of a drawn kind needs all of it
  -- (lane 81) a friend's absolute value: noted by its slot until the host's copy of the line comes back (the order rule)
  if S.role ~= "host" then
    local slot = T.lineSlot(act, fields)
    if slot then T.ownSlot = T.ownSlot or {}; T.ownSlot[slot] = tag; T.own[tag].slot = slot; T.own[tag].fields = fields end
  end
  T.ownList[#T.ownList + 1] = tag
  if #T.ownList > 200 then T.own[table.remove(T.ownList, 1)] = nil end
  stat(S, "t_sent")
  A.log("TOWN sent %s %d %s %s", S.name, T.seq, act, fields:sub(1, 160))
  T.proofDense()
  return T.seq
end

-- (lane 76, task 76e) the timing proof (coop_world.lua, a test tool, off for players) dates every building that comes
-- or goes in the next 1.5 s within one frame: a town action changes buildings on this copy now
function T.proofDense()
  local Wd = rawget(C, "world")
  if Wd and Wd.cfg and Wd.cfg.proof and Wd.proofDense then pcall(Wd.proofDense, 1.5) end
end
-- a replay is done: host passes it on (or refuses it); everyone logs it
function T.finish(S, job, status, fwd, extra)
  local ok = status == "ok"
  -- (lane 81) a demolish of a building this copy had removed a moment before: nothing to do, nothing refused, not passed on
  if status == "already gone" then
    T.results[job.origin .. ":" .. job.n] = status; stat(S, "t_alreadyGone")
    A.log("TOWN APPLIED %s %s:%s (from %s, waited %.0f ms): already gone here (removed by this copy a moment before): nothing to do, not refused", job.act, job.origin, tostring(job.n), tostring(job.from), (vnow() - job.t) * 1000)
    return
  end
  if ok then T.proofDense() end
  -- (lane 76, task 76e) an upgrade carried out here: the storage counters of every building being upgraded are
  -- recounted for 2 s (coop_facts.lua F.recountUpgrading; the counters after an upgrade end in no recount here)
  if ok and (job.act == "UPGRADE" or job.act == "EXTEND" or job.act == "EXT" or job.act == "ARTISAN") then
    local Fm = rawget(C, "facts")
    if Fm and Fm.recountUpgrading then pcall(Fm.recountUpgrading, 2.0) end
  end
  local tag = job.origin .. ":" .. job.n
  T.results[tag] = status
  stat(S, ok and "t_applied" or "t_failed")
  A.log("TOWN %s %s %s (from %s, waited %.0f ms): %s", ok and "APPLIED" or "FAILED", job.act, tag, tostring(job.from), (vnow() - job.t) * 1000, tostring(status))
  -- (lane 64) a replayed action can put a family out here (a demolished house, an upgrade) and a friend's copy houses
  -- nobody by itself: the families get the host's homes now, in this tick (coop_x_events.lua, E.homesNow)
  if ok and S.role == "friend" then local Ev = rawget(C, "events"); if Ev and Ev.homesNow then pcall(Ev.homesNow, "the town action " .. tostring(job.act)) end end
  if ok and C.panels and C.panels.touched and not (C.modules and C.modules[job.origin]) then pcall(C.panels.touched, job.act, job.f and job.f[1]) end   -- (lane 69) another player's action (not a module's own line, e.g. "people"): open panels redraw (coop_x_panels.lua)
  if S.role == "host" and job.origin ~= S.name then
    if ok then
      sendTown(job.origin, job.n, job.act, fwd or job.fields)
      for _, e in ipairs(extra or {}) do T.emitAction(S, e[1], e[2]) end
    else
      T.emitAction(S, "NAK", tag .. " " .. enc(status))
    end
  end
end

-- run fn as a replay: hooks that fire inside it are not reported
function T.quiet(fn, ...)
  T.depth = T.depth + 1
  local r = table.pack(pcall(fn, ...))
  T.depth = T.depth - 1
  if not r[1] then error(r[2], 0) end
  return table.unpack(r, 2, r.n)
end

-- (lane 81) an absolute value's slot: what picks the value (all arguments but the last of a setter with two or more,
-- e.g. the good of a trade limit) and the value itself (the last argument; the whole text for one argument or a field)
local function selVal(d, v)
  v = tostring(v or "-")
  if d and d.argt and #d.argt >= 2 then
    local sel, val = v:match("^(.*),([^,]*)$")
    if sel then return sel, val end
  end
  return "", v
end
local function isAbs(d) return d ~= nil and not d.rel and d.abs == true end   -- setters that are not relative, fields, MAINT, TRAINREG
-- the slot as a line names it (target key, value): the same on every copy, used for the order rule (T.ownSlot)
function T.lineSlot(act, fields)
  local d = T.defs[act]; if not isAbs(d) then return nil end
  local f1, f2 = tostring(fields or ""):match("^(%S+)%s+(%S+)")
  if not f1 then return nil end
  local sel = selVal(d, f2)
  return act .. " " .. f1 .. " " .. sel
end
-- a replay applied value v of kind d on obj: the same value seen locally for that slot within 3 s is its echo
local function touch(obj, d, argstr)
  local a = addrOf(obj); if not a then return end
  T.touched[a] = os.clock()             -- still read by coop_realm.lua and coop_x_build.lua (their own watchers)
  if isAbs(d) and argstr then
    local sel, val = selVal(d, argstr)
    T.expect[d.name .. "@" .. a .. ":" .. sel] = { v = val, t = os.clock() + 3.0 }
  end
end
-- is a local record (kind name, target address, value text) the echo of a replay? Another value ends the expectation.
function T.isEcho(name, a, argstr)
  local d = T.defs[name]
  local sel, val = selVal(d, argstr)
  local k = name .. "@" .. tostring(a) .. ":" .. sel
  local e = T.expect[k]
  if not e then return false end
  if e.t < os.clock() then T.expect[k] = nil; return false end
  if e.v == val then return true end
  T.expect[k] = nil                     -- the player set another value: what follows on this slot is the player's
  return false
end

-- ---------------------------------------------------------------- actions and hooks
T.defs = {}; T.order = {}; T.hooks = {}
local P = "/Script/ManorLords."
local BP_PAWN = "/Game/CPP_BP/MyPawnCPP_BP3.MyPawnCPP_BP3_C:"
local INV = "/Game/ManorLords/UI/Widgets/Widgets_Inventory/Inventory.Inventory_C:"

local function def(d)
  T.defs[d.name] = d; T.order[#T.order + 1] = d.name
  if T.enabled[d.name] == nil then T.enabled[d.name] = true end   -- every action is on by default (the user's rule, session 18); the status line of each action says how far it is tested
  return d
end
-- one hook path can serve several actions; see(self, ...) runs in the callback and returns a record (or nil)
local function hook(path, defs, see) T.hooks[path] = { defs = defs, see = see } end

function T.isOn(name)
  local d = T.defs[name]; if not d then return false end
  if d.follows then for _, n in ipairs(d.follows) do if T.enabled[n] then return true end end; return false end
  return T.enabled[name] == true
end
local function anyOn(names) for _, n in ipairs(names) do if T.isOn(n) then return true end end; return false end
local function isLocal(p) return T.p1addr ~= nil and addrOf(p) == T.p1addr end
local function owned(o) local ok, r = pcall(function() local op = o.ownerPawn; return valid(op) and addrOf(op) == T.p1addr end); return ok and r end

local function argval(x, ty)
  local v = x and x:get()
  if ty == "n" or ty == "s" then
    local ok, s = pcall(function() return v:ToString() end); return ok and s or tostring(v)
  elseif ty == "b" then return v == true end
  return int(v)
end
local function encArgs(argt, vals)
  if #argt == 0 then return "-" end
  local o = {}
  for i = 1, #argt do
    local ty, v = argt:sub(i, i), vals[i]
    if ty == "b" then o[i] = v and "1" or "0" elseif ty == "n" or ty == "s" then o[i] = enc(v) else o[i] = tostring(int(v)) end
  end
  return table.concat(o, ",")
end
local function decArgs(argt, s)
  local raw = split(s or "-", ","); local o = {}
  for i = 1, #argt do
    local ty, v = argt:sub(i, i), raw[i] or "0"
    if ty == "b" then o[i] = (v == "1") elseif ty == "n" then o[i] = FName(dec(v)) elseif ty == "s" then o[i] = dec(v) else o[i] = int(v) end
  end
  return o
end

-- the callback every hook gets. It dispatches through _G.Coop.town at call time (a reloaded file is used at once).
local function makeCallback(path)
  return function(self, a1, a2, a3, a4)
    local Cc = rawget(_G, "Coop"); local Tt = Cc and Cc.town
    if not (Tt and Tt.onHook) then return end
    local ok, e = pcall(Tt.onHook, path, self, a1, a2, a3, a4)
    if not ok then Tt.hookErr = (Tt.hookErr or 0) + 1; Tt.lastHookErr = tostring(e) end
  end
end

local function push(rec)
  local d = T.defs[rec.k]
  if rec.k == "REASSIGN" or rec.k == "EXTEND" or (rec.obj and (firstBuilding[rec.k] or (d and d.target == "building")) and rec.k ~= "MAINT" and rec.k ~= "ANAME") then
    local b = rec.b or rec.ext or rec.obj
    local okC, snap = pcall(captureB, b)
    rec.snap = okC and snap or nil
    rec.owned = valid(b) and owned(b)
    rec.nameB = b                 -- no usable name in the hook: the tick tries once more (handleSeen)
  end
  local q = T.q
  if #q >= T.cfg.maxQueue then table.remove(q, 1); T.dropped = (T.dropped or 0) + 1 end
  q[#q + 1] = rec
end

-- runs inside a hook callback: record only
function T.onHook(path, self, a1, a2, a3, a4)
  local S = C.s; if not (S and S.on) or C.hold then return end      -- C.hold: a join or repair is loading a save
  if T.depth > 0 then T.echo = (T.echo or 0) + 1; return end
  local h = T.hooks[path]; if not (h and anyOn(h.defs)) then return end
  local rec = h.see(self, a1, a2, a3, a4)
  if not rec then return end
  if rec.k ~= "_note" and not T.isOn(rec.k) then rec = { k = "_note", msg = rec.k .. " seen but switched off here: not sent, copies now differ" } end
  rec.t = vnow()
  push(rec)
end

-- registration from tick: pcall, retry every 2 s, only for enabled actions, at most 8 per attempt
local function ensureHooks(force)
  if not force and os.clock() - (T.hookT or -10) < 2.0 then return end
  T.hookT = os.clock()
  _G.__coop_town_hooks = _G.__coop_town_hooks or {}
  local reg, n = _G.__coop_town_hooks, 0
  for path, h in pairs(T.hooks) do
    if not reg[path] and anyOn(h.defs) and n < 8 then
      n = n + 1
      local ok, pre, post = pcall(RegisterHook, path, makeCallback(path))
      if ok then reg[path] = { pre, post }; A.log("TOWN hook on %s", path)
      else
        T.hookFail[path] = (T.hookFail[path] or 0) + 1
        if T.hookFail[path] == 1 then A.log("TOWN hook not available yet %s (%s), will retry", path, tostring(pre)) end
      end
    end
  end
end

-- ================================================================ BUILD and MOVE (playBuildEffects)
-- SEE: the Blueprint event playBuildEffects fires once per placement on the placing pawn, after build() made the building:
-- hitBuilding is the new building (README session 7b, live). build() raises it BEFORE it reads and clears movedBuilding, so a
-- valid movedBuilding here means a relocation (lane_t1 T8d, static): that must never be sent as a BUILD, or the other copies
-- get a second building and keep the old one.
-- Castle planner (session 21, lane 2, measured on the host): while the lord is in planning mode (setPlannerMode(manor)) the
-- same build() adds a blueprint (a plain mesh actor, no building) to the planner building's list; hitBuilding is not a new
-- building then. That placement is the action PLAN of coop_x_build.lua: the module's type is the lord's placeBuilding, the
-- place is this event's argument.
hook(BP_PAWN .. "playBuildEffects", { "BUILD", "MOVE", "PLAN" }, function(self, a1)
  local p = self:get(); if not isLocal(p) then return nil end
  if p.inPlanningMode and valid(p.plannerModeBld) then
    local m = p.plannerModeBld
    local pos = a1 and a1:get(); local rr = p.bbox.RelativeRotation
    if not pos then return { k = "_note", msg = "planner placement without a position: not sent, copies now differ" } end
    -- (lane 83) a part placed on a wall splits the wall on every copy (the PLAN replay does the same): not sent as PLANWPTS
    local XB = T.xbuild; if XB and XB.mark then XB.mark(m) end
    -- (the record's field "t" is its time, set by onHook: the part's type is "bt")
    return { k = "PLAN", obj = m, bt = int(p.placeBuilding), x = pos.X, y = pos.Y, z = pos.Z, yaw = rr and rr.Yaw or 0, n0 = #m.blueprints }
  end
  local hb = p.hitBuilding
  if not valid(hb) then return { k = "_note", msg = "playBuildEffects without a new building" } end
  local rec = { k = "BUILD", obj = hb }
  local mb = p.movedBuilding
  if valid(mb) then
    rec.k = "MOVE"; rec.old = captureB(mb)
  end
  return rec
end)

-- a type's treasury cost (Stat.constructionCost, read as the T14 probe does); nil when it cannot be read
function T.buildCost(t)
  local ok, c = pcall(function() return C.s.eng:getBuildingData(t).constructionCost end)
  if ok and type(c) == "number" then return c end
  return nil
end

-- may this type be placed through the helper? (see HAZARDS: a costed placement by an unfunded helper crashed twice).
-- The host is the referee for money: it refuses a costed placement the lord cannot afford.
local function costGate(S, t)
  local cost = T.buildCost(t)
  if cost == nil then return nil, "cost of type " .. t .. " unreadable: refused" end
  if cost > 0 and not T.cfg.payCost then return nil, "type " .. t .. " costs " .. cost .. ": refused (cfg.payCost off)" end
  if cost > 0 and S.role == "host" and (tonumber(S.p1.silver) or 0) < cost then
    return nil, string.format("the lord cannot afford type %d (cost %d, treasury %d)", t, cost, tonumber(S.p1.silver) or 0)
  end
  return cost
end

-- the helper is one slot: one placement in flight, finished in a later tick (requestBuild is consumed by its own Tick)
local function startPlacement(S, h, job, e, old, cost)
  if cost > 0 then
    h.silver = cost               -- fund the helper right before requestBuild: an unfunded helper placement crashed (HAZARDS)
    if (tonumber(h.silver) or 0) < cost then return "helper silver could not be set to the cost: refused" end
  end
  if old then h.movedBuilding = old end
  h.placeBuilding = e.t
  h.bbox:K2_SetWorldLocationAndRotation({ X = e.x + 0.0, Y = e.y + 0.0, Z = e.z + 0.0 }, { Pitch = 0.0, Yaw = e.yaw + 0.0, Roll = 0.0 }, false, {}, true)
  h.requestBuild = true
  T.pend = { kind = "place", job = job, e = e, old = old, hpre = h.silver, cost = cost, t0 = vnow() }
  return "pending"
end

local function clearMoved(h)
  if not valid(h.movedBuilding) then return true end
  pcall(function() h:resetBuildingMode() end)        -- recorded live as part of Esc (session 7c); that it clears movedBuilding is GUESS
  if valid(h.movedBuilding) then pcall(function() h.movedBuilding = nil end) end
  return not valid(h.movedBuilding)
end

local function inBuildingArr(S, obj)
  local a = addrOf(obj); if not a then return false end
  local arr = S.eng.buildingArr
  for i = 1, #arr do local b = un(arr[i]); if valid(b) and addrOf(b) == a then return true end end
  return false
end

-- A pending helper job finishes here, in a later tick.
-- Placement, T14 (lane_t1 READ, confirmed live on one copy in README session 14): build() charges the pawn that placed it,
-- i.e. the funded helper. On the host the lord is then charged the cost (ChangeTreasury, the call build() itself makes);
-- friends only empty the helper again, because the host's treasury push is the truth for money.
-- Demolish: the helper's Tick drains demolishRequests; done when the building has left the world list.
local function checkPending(S)
  local Pd = T.pend; local h = A.helper()
  local waited = vnow() - Pd.t0
  if Pd.check then                  -- a lane module's own pending helper job (coop_x_build.lua: planner placements)
    local okC, status = pcall(Pd.check, S, Pd, h, waited)
    if not okC then status = "error " .. tostring(status) end
    if status == nil then return end
    T.pend = nil
    T.finish(S, Pd.job, status)
    return
  end
  if Pd.kind == "demolish" then
    -- the helper's Tick drains demolishRequests with demolish(b, refund=true) (lane_t1 T5 READ); done when b has left the world list
    local e = Pd.e
    local gone = not T.findB(e.t, e.x, e.y)
    if not gone and waited < 3.0 then return end
    T.pend = nil
    T.finish(S, Pd.job, gone and "ok" or "still there after the helper's demolish request")
    return
  end
  if valid(h) and h.requestBuild and waited < 3.0 then return end
  T.pend = nil
  if not valid(h) then T.finish(S, Pd.job, "helper gone"); return end
  -- a timed-out request must be disarmed BEFORE the helper's silver is emptied: a late requestBuild on an unfunded helper is
  -- exactly what crashed (HAZARDS)
  local timedOut = h.requestBuild == true
  if timedOut then h.requestBuild = false end
  local e = Pd.e
  local b = T.findB(e.t, e.x, e.y)
  local paid = Pd.hpre - (tonumber(h.silver) or Pd.hpre)     -- what the helper actually paid (logged; equals the cost when it built)
  local charged = 0
  -- T14 (README session 14, live on one copy): the helper paid; on the host the lord is charged the cost instead
  if b and Pd.cost > 0 and S.role == "host" and T.cfg.moveCost then S.p1:ChangeTreasury(-Pd.cost); charged = Pd.cost; stat(S, "t_costCharged", Pd.cost) end
  h.silver = 0
  h.placeBuilding = 0
  local status = "ok"
  if not b then status = timedOut and "the helper never took the request (timed out, disarmed)" or "not built (spot refused?)"
  else
    T.addB(b); touch(b)
    if Pd.old and valid(Pd.old) and inBuildingArr(S, Pd.old) then status = "moved copy made but the old building is still there" end
  end
  if Pd.old then clearMoved(h) end              -- success or not: a helper must never keep a moved building
  A.log("TOWN placement %s type %d at %.0f,%.0f: %s, cost %d, helper paid %d, lord charged %d", Pd.job.act, e.t, e.x, e.y, status, Pd.cost, paid, charged)
  T.finish(S, Pd.job, status)
end

-- status: proven live (README sessions 7b and 8: placeBuilding, bbox, requestBuild on the helper; session 8 relayed it);
-- costed types with the funded helper: proven live on one copy (README session 14) and on two copies in both directions
-- (lane 2, session 2: "helper paid 50, lord charged 50" on the host, "lord charged 0" on the friend, both treasuries equal)
-- (lane 81, case A of the own-click rule) a friend's building on a place the HOST already has a building on. The
-- friend's own game checked the place against ITS world, where the place was still free (the host built there a
-- moment earlier); the helper's placement does not check at all (live ca: a saw pit placed on a finished lodge, and
-- one 2 m from a site 0.3 s old, both "ok"). The host asks the engine whether the new building's centre lies inside
-- another building's border (RTSMultiEngineCPP:pointCollidesWithBuildingBorder: true on a finished building, on a
-- site at once, false 6 m away), and counts it only when a building other than a pile (type 88) stands within 15 m:
-- the point check is true on a pile too, and a player may build where a pile lies. Not caught: an overlap of the
-- edges with the centre outside every border (the footprint is not read).
function T.placeBlocked(S, e)
  local ok, hit = pcall(function() return S.eng:pointCollidesWithBuildingBorder({ X = e.x + 0.0, Y = e.y + 0.0, Z = (e.z or 0) + 0.0 }) end)
  if not (ok and hit) then return nil end
  local arr = S.eng.buildingArr
  for i = 1, #arr do
    local b = un(arr[i])
    if valid(b) then
      local okT, t = pcall(function() return A.btype(b) end)
      if okT and t ~= 88 then
        local l = b:K2_GetActorLocation()
        if not far(l.X, l.Y, e.x, e.y, 1500) then return string.format("type %d at %.0f,%.0f", t, l.X, l.Y) end
      end
    end
  end
  return nil
end
-- (lane 81) THE OUTLINE RULE (edges too). Every building has its outline (finalBorder, 4 to 60 points). A new
-- building's outline is the outline of a building of the same type already in the world (any owner), turned and moved
-- to the new place; the rule then asks how much of the smaller outline the two share (sampled on a 50 cm grid).
-- Calibrated on the clean save (lane_s21_81 out ovl): of 17 overlapping pairs, the market stalls in their marketplace
-- (91, 93 in 13: 100 %) and stall against stall (14 %), and a rival's type 115 against 115 (11 to 13 %) are how the
-- game lays them out; every other pair overlaps at most 0.1 % (0.2 m2). So: taken when the shared part is at least
-- OUTLINE_SHARE of the smaller outline and OUTLINE_M2 square metres, against a building that is not a pile and not a
-- pair the game lays out together. No building of the type in the world: the centre rule (T.placeBlocked) instead.
local OUTLINE_SHARE, OUTLINE_M2 = 0.05, 2.0
local TOGETHER = { [91] = { [13] = true, [91] = true, [93] = true }, [93] = { [13] = true, [91] = true, [93] = true },
                   [13] = { [91] = true, [93] = true }, [115] = { [115] = true } }
T.OUTLINE_SHARE, T.OUTLINE_M2, T.TOGETHER = OUTLINE_SHARE, OUTLINE_M2, TOGETHER
local function outlineOf(b)
  local o = {}
  pcall(function() local a = b.finalBorder; local n = #a; for i = 1, n do local p = a[i]; o[#o + 1] = { p.X, p.Y } end end)
  return o
end
local function inPoly(x, y, P) local c = false; local j = #P; for i = 1, #P do local a, b = P[i], P[j]; if ((a[2] > y) ~= (b[2] > y)) and (x < (b[1] - a[1]) * (y - a[2]) / (b[2] - a[2]) + a[1]) then c = not c end; j = i end; return c end
local function boxOf(P) local x0, y0, x1, y1 = 1e18, 1e18, -1e18, -1e18; for _, p in ipairs(P) do if p[1] < x0 then x0 = p[1] end; if p[2] < y0 then y0 = p[2] end; if p[1] > x1 then x1 = p[1] end; if p[2] > y1 then y1 = p[2] end end; return x0, y0, x1, y1 end
local function areaOf(P) local s2 = 0; for i = 1, #P do local a, b = P[i], P[i % #P + 1]; s2 = s2 + a[1] * b[2] - b[1] * a[2] end; return math.abs(s2) / 2 end
-- the shared area (cm2) of two outlines, sampled on a grid over the overlap of their boxes: 50 cm, coarser for a big
-- overlap box so that a pair never costs more than about 600 samples (live: a 50 cm grid over a big outline held the
-- game thread for minutes; at 2,500 a lodge beside the manor's 16,000 m2 outline took 5 ms); each sample is tested
-- against the outline with fewer points first
local function sharedArea(A, B, step)
  local ax0, ay0, ax1, ay1 = boxOf(A); local bx0, by0, bx1, by1 = boxOf(B)
  local x0, y0, x1, y1 = math.max(ax0, bx0), math.max(ay0, by0), math.min(ax1, bx1), math.min(ay1, by1)
  if x0 >= x1 or y0 >= y1 then return 0 end
  step = math.max(step or 50, math.sqrt((x1 - x0) * (y1 - y0) / 600))
  if #B < #A then A, B = B, A end
  local hit = 0
  local y = y0 + step / 2
  while y < y1 do local x = x0 + step / 2; while x < x1 do if inPoly(x, y, A) and inPoly(x, y, B) then hit = hit + 1 end; x = x + step end; y = y + step end
  return hit * step * step
end
T.outline = { of = outlineOf, inPoly = inPoly, shared = sharedArea, area = areaOf }
-- the outline a building of type t would have at x,y turned to yaw (degrees): a building of that type, moved and
-- turned; nil when none is in the world. skip = a building not to take (the one being moved). Not for the drawn
-- kinds: a burgage plot (3), its house (8), a field (5), a pasture (10), a marketplace (13) each has its own shape
-- (calibration: another plot's outline moved onto a plot shares 9 to 17 %, a house's 9 to 18 %, a market's 7 %)
local DRAWN = { [3] = true, [5] = true, [8] = true, [10] = true, [13] = true }
T.DRAWN = DRAWN
function T.outlineAt(S, t, x, y, yaw, from)
  if DRAWN[t] and not from then return nil end
  local src = from
  if not src then
    local arr = S.eng.buildingArr
    for i = 1, #arr do local b = un(arr[i]); if valid(b) then local ok, bt = pcall(function() return A.btype(b) end); if ok and bt == t then src = b; break end end end
  end
  if not valid(src) then return nil end
  local P = outlineOf(src); if #P < 3 then return nil end
  local l = src:K2_GetActorLocation(); local okR, r = pcall(function() return src:K2_GetActorRotation() end)
  local d = math.rad((yaw or 0) - ((okR and r and r.Yaw) or 0)); local c, sn = math.cos(d), math.sin(d)
  local o = {}
  for i, p in ipairs(P) do local dx, dy = p[1] - l.X, p[2] - l.Y; o[i] = { x + dx * c - dy * sn, y + dx * sn + dy * c } end
  return o
end
-- the first building (not a pile, not a pair the game lays out together, not skip) whose outline shares enough of
-- the outline P (of a building of type t); a text naming it, or nil
-- each building's outline, box and area, kept by address and read again only when the building moved, turned or
-- changed type (reading 4 to 60 points through the scripting layer per building per check was most of a check's time)
T.olCache = T.olCache or {}
local function olEntry(b, a, bt)
  local l = b:K2_GetActorLocation()
  local e = T.olCache[a]
  if e and e.t == bt and e.x == l.X and e.y == l.Y then return e end
  local Q = outlineOf(b)
  local x0, y0, x1, y1 = boxOf(Q)
  e = { t = bt, x = l.X, y = l.Y, P = Q, x0 = x0, y0 = y0, x1 = x1, y1 = y1, a = (#Q >= 3) and areaOf(Q) or 0 }
  T.olCache[a] = e
  return e
end
function T.outlineTaken(S, t, P, skip, share, m2)
  share = share or OUTLINE_SHARE; m2 = m2 or OUTLINE_M2
  if not P or #P < 3 then return nil end
  local aP = areaOf(P); if aP <= 0 then return nil end
  local px0, py0, px1, py1 = boxOf(P)
  local sa = skip and addrOf(skip)
  local arr = S.eng.buildingArr
  for i = 1, #arr do
    local b = un(arr[i])
    local a = addrOf(b)
    -- far away by the town index's own record of the building: no further read (most buildings of a check)
    local ix = a and T.bidx[a]
    local near = not ix or (ix.x > px0 - 8000 and ix.x < px1 + 8000 and ix.y > py0 - 8000 and ix.y < py1 + 8000)
    if a and a ~= sa and near and valid(b) then
      local okT, bt = pcall(function() return A.btype(b) end)
      if okT and bt ~= 88 and not (TOGETHER[t] and TOGETHER[t][bt]) then
        local e = olEntry(b, a, bt)
        if #e.P >= 3 and e.x0 < px1 and px0 < e.x1 and e.y0 < py1 and py0 < e.y1 then
          local sh = sharedArea(P, e.P)
          local small = math.min(aP, e.a)
          if small > 0 and sh >= share * small and sh >= m2 * 10000 then
            return string.format("type %d at %.0f,%.0f (%.0f %% of the smaller outline, %.1f m2)", bt, e.x, e.y, 100 * sh / small, sh / 10000)
          end
        end
      end
    end
  end
  return nil
end
-- (lane 81) a friend's drawn area (field, pasture, market: their corners; burgage plots: each lot's corners) by the
-- outline rule, on the host only. Refused (the friend removes its area by name, the NAK branch) for the kinds in
-- cfg.areaRefuse: FIELD and PASTURE, their undo proven in the game (u10b: 3 of 3 each, the friend at the host's state
-- 0.14 to 0.25 s after its line); a MARKET and burgage plots (HOUSE, EXTEND) are logged and built until theirs is.
-- Time per check in the game: median 1 to 3 ms, worst 7 ms (fields of 30 to 200 m over the manor and the town).
-- Returns the refusal or nil.
function T.areaTaken(S, job, t, pts)
  if S.role ~= "host" or job.origin == S.name or T.cfg.areaGate == "off" then return nil end
  local P = {}; for i, p in ipairs(pts or {}) do P[i] = { p.X, p.Y } end
  if #P < 3 then return nil end
  -- a drawn area's own edges may lie over a neighbour a little: calibration on the clean save (26 fields, pastures,
  -- markets and plots by their corners) gave one pair at 7 % / 11.2 m2 (a rival's plot over a rival's type 68), all
  -- others below 0.1 %: the area tolerance is 10 % of the smaller outline and 4 m2
  local ok, taken = pcall(T.outlineTaken, S, t, P, nil, 0.10, 4.0)
  if not (ok and taken) then return nil end
  stat(S, "t_areaTaken")
  if T.cfg.areaGate == "refuse" and T.cfg.areaRefuse and T.cfg.areaRefuse[job.act] then return "the place is taken on the host (" .. taken .. ")" end
  A.log("TOWN %s %s:%s: the place is taken on the host (%s): built anyway (areaGate log)", tostring(job.act), tostring(job.origin), tostring(job.n), taken)
  return nil
end
def { name = "BUILD", status = "live", ref = "README s7b, s8, s14", helper = true, wait = 1,
  ready = function(S, rec)
    if valid(rec.obj) then T.addB(rec.obj) end
    return bkeyYaw(rec.snap)
  end,
  apply = function(S, job)
    local e = decB(job.f[1]); if not e then return "bad fields" end
    -- types 100 and 483 would belong to the pawn that places them (lane_t1 T14, READ 4b9b100): refuse rather than give the helper a building
    if e.t == 100 or e.t == 483 then return "type " .. e.t .. " cannot be placed through the helper" end
    if T.findB(e.t, e.x, e.y) then return "ok" end                  -- already there (a repeated line)
    if S.role == "host" and job.origin ~= S.name and T.cfg.placeGate ~= "off" then   -- (lane 81) never on a friend
      local P = T.outlineAt(S, e.t, e.x, e.y, e.yaw)
      local taken
      if P then taken = T.outlineTaken(S, e.t, P) else taken = T.placeBlocked(S, e) end
      if taken then
        stat(S, "t_placeTaken")
        if T.cfg.placeGate == "refuse" then return "the place is taken on the host (" .. taken .. ")" end
        A.log("TOWN BUILD %s:%s: the place is taken on the host (%s): built anyway (placeGate log)", job.origin, tostring(job.n), taken)
      end
    end
    local cost, why = costGate(S, e.t); if not cost then return why end
    local h = A.helper(); if not valid(h) then return "no helper" end
    if not clearMoved(h) then return "helper still holds a moved building" end
    return startPlacement(S, h, job, e, nil, cost)
  end }

-- status: the recipe of lane_t1 T8d (movedBuilding + placeBuilding + bbox + requestBuild on the helper) run on two copies in
-- both directions from the lord's own scripted request, also after a resync (lane 2, runs s3, s4 and s8); a real click not yet
def { name = "MOVE", status = "console2", ref = "lane_t1 T8d; lane 2 runs s3, s4, s8", helper = true, wait = 1,
  ready = function(S, rec)
    if not rec.old then return nil, "old building identity unavailable at capture" end
    if valid(rec.obj) then T.addB(rec.obj) end
    return bkeyOf(rec.old) .. " " .. bkeyYaw(rec.snap)
  end,
  apply = function(S, job)
    local o, e = decB(job.f[1]), decB(job.f[2]); if not (o and e) then return "bad fields" end
    if e.t == 100 or e.t == 483 then return "type " .. e.t .. " cannot be placed through the helper" end
    local old = T.findB(o.t, o.x, o.y)
    -- (lane 81) the host removed the moved building itself a moment ago (its own demolish, or one still draining in
    -- its pawn's list): the friend's move is refused with this reason, and the friend removes its moved copy at the
    -- new place (the undo, as for a refused building). Without it the helper moved a building being demolished.
    if old then local oa = addrOf(old); if oa and T.recentDem[oa] and os.clock() - T.recentDem[oa] < 5 then return "moved building gone on the host" end end
    if not old then
      if T.findB(e.t, e.x, e.y) then return "ok" end
      if T.wasGone(o) then return "moved building gone on the host" end
      return "retry:old building not found"
    end
    local cost, why = costGate(S, e.t); if not cost then return why end   -- a move runs build() too, so it charges the same way (READ)
    local h = A.helper(); if not valid(h) then return "no helper" end
    if not clearMoved(h) then return "helper still holds a moved building" end
    return startPlacement(S, h, job, e, old, cost)
  end }

-- ================================================================ ROAD (commitRoad)
-- SEE: pre-hook PawnCPP:commitRoad on the local lord (fires for the real click: session 7). The callback keeps only the
-- addresses of the existing roads; the next tick reads the new road(s) and their spline points. (Session 8 read the draft
-- spline inside the hook; that is a game-function call and not allowed in a callback any more.)
-- Walls and palisades are drawn with the same tool (session 21, lane 2, measured): with wallMode on, commitRoad makes no
-- road in eng.roads but a wall of the castle plan (a blueprint Road with roadType 3 and the draft's wallType, kept by the
-- planner building). That is the action PLANWALL of coop_x_build.lua; the draft's points are copied here (plain array).
-- Outside the planner the game's wall tool makes an ownerless type 50 object at the map origin: not sent.
hook(P .. "PawnCPP:commitRoad", { "ROAD", "PLANWALL" }, function(self)
  local p = self:get(); if not isLocal(p) then return nil end
  if p.wallMode then
    local m = p.plannerModeBld
    if not (p.inPlanningMode and valid(m)) then return { k = "_note", msg = "wall drawn outside the castle planner: not sent" } end
    local d = p.dummyRoad
    return { k = "PLANWALL", obj = m, pts = acopy(p.roadPoints), wt = int(d.wallType), pl = int(d.platformLevel), nw = #m.walls, nb = #C.s.eng.buildingArr }
  end
  local before = {}; local arr = C.s.eng.roads
  for i = 1, #arr do local a = addrOf(un(arr[i])); if a then before[a] = true end end
  return { k = "ROAD", before = before }
end)

-- status: proven live (README session 7c r1.lua and session 8: setRoadMode, roadPoints, same points into dummyRoad.Spline, commitRoad in one call)
def { name = "ROAD", status = "live", ref = "README s7c, s8 (capture in tick: not yet run live)", helper = true, wait = 1,
  ready = function(S, rec)
    local arr = S.eng.roads; local lines = {}
    for i = 1, #arr do
      local r = un(arr[i]); local a = addrOf(r)
      if a and not rec.before[a] and valid(r) then
        local pts = roadPts(r)
        T.addRoad(r)
        if #pts >= 2 then lines[#lines + 1] = encPts(pts) end
      end
    end
    -- more than one new road would mean the commit split roads; each piece is sent as its own road (GUESS that this matches)
    if #lines == 0 then return "wait" end
    return lines
  end,
  apply = function(S, job)
    local pts = decPts(job.f[1]); if #pts < 2 then return "bad points" end
    local a, z = pts[1], pts[#pts]
    if T.findRoad(a.X, a.Y, z.X, z.Y) then return "ok" end
    local h = A.helper(); if not valid(h) then return "no helper" end
    h.placeBuilding = 0
    h:setRoadMode(true, pts[1], true)
    pcall(function() h.roadPoints:Empty() end)
    for i, p in ipairs(pts) do h.roadPoints[i] = p end
    local sp = h.dummyRoad.Spline
    sp:ClearSplinePoints(true)
    for _, p in ipairs(pts) do sp:AddSplinePoint(p, 1, true) end
    local r = h:commitRoad()
    h:setRoadMode(false, { X = 0.0, Y = 0.0, Z = 0.0 }, false)
    if not valid(r) then return "commitRoad made no road" end
    T.addRoad(r); touch(r)
    return "ok"
  end }

-- ================================================================ FIELD, PASTURE, HOUSE plots (addCommitFieldRequest)
-- SEE: pre-hook PawnCPP:addCommitFieldRequest on the local lord (recorded with real clicks, session 7). It only sets a flag;
-- the engine commits for playerRef a tick later (session 4). So the hook copies the draft, and the tick waits for the new
-- building to read its corners. placePlotType 1 = field (type 5), 2 = pasture (type 10), 3 = residential lots (type 3),
-- 4 = market (type 13; READ lane_t1 commitField 4b35773; run on two copies by lane 2). 5 (bailey) is not synced.
-- (the game spells the lot's two lists SmoothBorder and Corners, the other fields with a small first letter: the game's
-- own spelling is used for every read and write of a lot)
local function lotcopy(e)
  return { smoothBorder = acopy(e.SmoothBorder), corners = acopy(e.Corners),
           primaryBuildingTransform = trcopy(e.primaryBuildingTransform), secondaryBuildingTransform = trcopy(e.secondaryBuildingTransform),
           extensionTransform = trcopy(e.extensionTransform), backFacade = { A = vcopy(e.backFacade.A), B = vcopy(e.backFacade.B) },
           extensionSmoothBorder = acopy(e.extensionSmoothBorder), extensionCorners = acopy(e.extensionCorners) }
end
hook(P .. "PawnCPP:addCommitFieldRequest", { "FIELD", "PASTURE", "HOUSE", "MARKET", "BAILEY", "EXTEND" }, function(self)
  local p = self:get(); if not isLocal(p) then return nil end
  local pt = p.placePlotType
  local n0 = #C.s.eng.buildingArr
  -- (lane 29) a house-lot draft with the lord's extensionFor set (the house it extends): EXTEND below. Measured on
  -- 0.8.117: setFieldMode sets isExtension for every house-lot draft (plot type 3), nothing in the game's code reads or
  -- clears extensionFor, and the commit makes a NEW house from the draft's lot and leaves the named house as it was
  -- (lane_s21_29 out/h1_measures.txt). So it is carried like HOUSE, with the named house in front.
  if pt == 3 and valid(p.extensionFor) then
    if not T.isOn("EXTEND") then return { k = "EXTEND" } end   -- becomes a note in onHook
    local lots = {}; local arr = p.extractedPlots
    for i = 1, #arr do lots[i] = lotcopy(arr[i]) end
    local ext = p.extensionFor
    -- the game never clears extensionFor (and never reads it): the field would stay set and turn every later ordinary
    -- house plot of this copy into EXTEND. One draft, one extension: cleared here, after it was copied (lane 29, round 2).
    pcall(function() p.extensionFor = nil end)
    return { k = "EXTEND", ext = ext, lots = lots, n0 = n0 }
  end
  if pt == 1 or pt == 2 or pt == 4 or pt == 5 then
    local r = p.fieldRot
    local rec = { k = (pt == 1) and "FIELD" or (pt == 2 and "PASTURE" or (pt == 5 and "BAILEY" or "MARKET")), smooth = acopy(p.fieldSmoothPoints), c = vcopy(p.fieldCenter),
                  r = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, w = p.fieldWorkersNeeded, n0 = n0 }
    if pt == 4 then           -- a marketplace: the places of its stalls come with the draft (lane_t1 T4b)
      rec.shape = int(p.marketShape); rec.stalls = {}
      local mt = p.marketTransforms
      for i = 1, #mt do rec.stalls[i] = trcopy(mt[i]) end
    end
    return rec
  elseif pt == 3 then
    if not T.isOn("HOUSE") then return { k = "HOUSE" } end   -- becomes a note in onHook; skip the deep copy
    local lots = {}; local arr = p.extractedPlots
    for i = 1, #arr do lots[i] = lotcopy(arr[i]) end
    return { k = "HOUSE", lots = lots, n0 = n0 }
  end
  return { k = "_note", msg = "plot type " .. tostring(pt) .. " is not synced: copies now differ" }
end)

-- the building a commit just made: type t near (x, y), looked for among the elements added after n0 first
local function findNew(S, t, x, y, n0)
  local arr = S.eng.buildingArr
  for i = math.max(1, (n0 or 0) + 1), #arr do
    local b = un(arr[i])
    if valid(b) and b:GetType() == t then local l = b:K2_GetActorLocation(); if not far(l.X, l.Y, x, y, 400) then return b end end
  end
  return nil
end

local function readyField(S, rec, t)
  local b = findNew(S, t, rec.c.X, rec.c.Y, rec.n0)
  if not b then return "wait" end                -- not committed (yet): a refused draft times out and is never sent
  T.addB(b)
  local corners = acopy(b.fieldBorderPoints)
  local cw = b.borderIsClockwise and 1 or 0
  local line = string.format("%s %s %d %s %s %d", encV(rec.c), encRot(rec.r), int(rec.w), encPts(rec.smooth), encPts(corners), cw)
  if rec.stalls then            -- MARKET: shape and the stall places, transforms joined by "/"
    local w = {}; for i, x in ipairs(rec.stalls) do w[i] = encTr(x) end
    line = line .. " " .. int(rec.shape or 0) .. " " .. (#w > 0 and table.concat(w, "/") or "-")
  end
  return line
end

-- status: proven live for the replay (README session 7c f1.lua, session 8 u3.lua); capture, relay and replay run on two
-- copies in both directions from the lord's own scripted draft (lane 2, run s4): the copy has the same border shrubs as the
-- field on the sender's copy. A draft made by real clicks (real corner records) not yet
local function applyField(plotType, t)
  return function(S, job)
    local c, rot = decV(job.f[1]), decRot(job.f[2])
    local workers = int(job.f[3]); local smooth, corners = decPts(job.f[4]), decPts(job.f[5])
    if not c or #smooth < 3 then return "bad fields" end
    if T.findB(t, c.X, c.Y) then return "ok" end
    local taken = T.areaTaken(S, job, t, #corners >= 3 and corners or smooth)
    if taken then return taken end
    local h = A.helper(); if not valid(h) then return "no helper" end
    h.placeBuilding = 0
    h:setFieldMode(true, plotType)
    pcall(function() h.fieldSmoothPoints:Empty() end)
    for i, p in ipairs(smooth) do h.fieldSmoothPoints[i] = p end
    h.fieldCenter = c; h.fieldRot = rot; h.fieldWorkersNeeded = workers
    -- corner records cannot be written from Lua (FieldPoint has no reflected fields): append blank ones (session 7c)
    for _ = 1, math.max(#corners, 5) do pcall(function() h.FieldPoints[#h.FieldPoints + 1] = {} end) end
    if plotType == 4 then       -- MARKET: commitField copies the draft's stall places into the building (lane_t1 T4b)
      h.marketShape = int(job.f[7] or 0)
      pcall(function() h.marketTransforms:Empty() end)
      local i = 0
      if job.f[8] and job.f[8] ~= "-" then for _, w in ipairs(split(job.f[8], "/")) do i = i + 1; h.marketTransforms[i] = decTr(w) end end
    end
    local b = h:commitField()
    h:setFieldMode(false, 0)
    if not valid(b) then return "commitField made nothing" end
    -- the blank corners came out at the origin: rewrite them (session 7c). The field then renders, without border shrubs.
    for i, p in ipairs(corners) do pcall(function() b.fieldBorderPoints[i] = p end) end
    -- the game worked this flag out from the blank corners: store the sender's value (lane_t1 T3). What reads it later
    -- is not measured; in lane 2's runs it was false on both copies either way.
    pcall(function() b.borderIsClockwise = (job.f[6] == "1") end)
    -- (lane 37, F5) a field made from blank corner records has NO plants (the game makes them in SetupBuilding from the
    -- corners): the drawing copy had 132 / 59, the replaying copy 0, for good, so the host could never plough a friend's
    -- field. SetupBuilding once more, now that the corners are the sender's, makes them (measured: 0 -> 59, the drawing
    -- copy's number; the building list unchanged).
    if plotType == 1 then
      local okN, n = pcall(function() return b.field_numSown + b.field_numUnplowed end)
      if okN and n == 0 then pcall(function() b:SetupBuilding() end) end
    end
    T.addB(b); touch(b)
    return "ok"
  end
end

def { name = "FIELD", status = "console2", ref = "README s7c, s8; lane 2 run s4", helper = true, wait = 3,
  ready = function(S, rec) return readyField(S, rec, 5) end, apply = applyField(1, 5) }
-- status: the same call with plotType 2 -> building type 10 (lane_t1 T3), run on two copies in both directions (lane 2, run s4)
def { name = "PASTURE", status = "console2", ref = "lane_t1 T3; lane 2 run s4", helper = true, wait = 3,
  ready = function(S, rec) return readyField(S, rec, 10) end, apply = applyField(2, 10) }
-- a marketplace is drawn like a field (plot type 4 -> building type 13); its stall places travel with it (lane_t1 T4b, static)
def { name = "MARKET", status = "console2", ref = "lane_t1 T4b; lane 2 run s4", helper = true, wait = 3,
  ready = function(S, rec) return readyField(S, rec, 13) end, apply = applyField(4, 13) }
-- (lane 27) plot type 5, the build card of building 94 ("bailey"): measured on coop_test_rich, the game commits it as
-- a building of type 5, both through addCommitFieldRequest and commitField. Carried like a field, with plot type 5.
def { name = "BAILEY", status = "console2", ref = "lane_s21_27", helper = true, wait = 3,
  ready = function(S, rec) return readyField(S, rec, 5) end, apply = applyField(5, 5) }

-- HOUSE: one word per lot, parts joined by "/": smoothBorder / corners / primary / secondary / extension / facadeA|facadeB /
-- extensionSmoothBorder / extensionCorners
local function encLot(l)
  return table.concat({ encPts(l.smoothBorder), encPts(l.corners), encTr(l.primaryBuildingTransform), encTr(l.secondaryBuildingTransform),
    encTr(l.extensionTransform), encV(l.backFacade.A) .. "|" .. encV(l.backFacade.B), encPts(l.extensionSmoothBorder), encPts(l.extensionCorners) }, "/")
end
local function decLot(s)
  local p = split(s, "/"); if #p < 8 then return nil end
  local fa = decPts(p[6])
  return { smoothBorder = decPts(p[1]), corners = decPts(p[2]), primaryBuildingTransform = decTr(p[3]), secondaryBuildingTransform = decTr(p[4]),
           extensionTransform = decTr(p[5]), backFacade = { A = fa[1] or { X = 0.0, Y = 0.0, Z = 0.0 }, B = fa[2] or { X = 0.0, Y = 0.0, Z = 0.0 } },
           extensionSmoothBorder = decPts(p[7]), extensionCorners = decPts(p[8]) }
end
-- writing a whole ExtractedPlot element (nested arrays and transforms) from Lua is GUESS (lane_t1 T4); fallback field by field
local function writeLot(h, i, rec)
  local whole = { SmoothBorder = rec.smoothBorder, Corners = rec.corners, primaryBuildingTransform = rec.primaryBuildingTransform,
                  secondaryBuildingTransform = rec.secondaryBuildingTransform, extensionTransform = rec.extensionTransform, backFacade = rec.backFacade,
                  extensionSmoothBorder = rec.extensionSmoothBorder, extensionCorners = rec.extensionCorners }
  local ok = pcall(function() h.extractedPlots[i] = whole end)
  local good = false
  if ok then pcall(function() local e = h.extractedPlots[i]; good = (#e.SmoothBorder == #rec.smoothBorder and #e.Corners == #rec.corners) end) end
  if good then return "whole" end
  if not ok then pcall(function() h.extractedPlots[i] = {} end) end
  -- (audit 2026-11-12: when both writes above failed, this read is what makes element i, an empty lot, which the
  -- lines below fill. That growth is wanted here: the list is the helper lord's own draft, emptied before each use.)
  local e = h.extractedPlots[i]
  for j, v in ipairs(rec.smoothBorder) do e.SmoothBorder[j] = v end
  for j, v in ipairs(rec.corners) do e.Corners[j] = v end
  for j, v in ipairs(rec.extensionSmoothBorder) do e.extensionSmoothBorder[j] = v end
  for j, v in ipairs(rec.extensionCorners) do e.extensionCorners[j] = v end
  e.primaryBuildingTransform = rec.primaryBuildingTransform; e.secondaryBuildingTransform = rec.secondaryBuildingTransform
  e.extensionTransform = rec.extensionTransform; e.backFacade = rec.backFacade
  return "fields"
end

-- status: the recipe of lane_t1 T4 (setFieldMode(true, 3) clears extractedPlots, write them, commitField in the same call)
-- run on two copies in both directions and after a resync from the lord's own scripted draft (lane 2, run s6): the new
-- house has the lot's own border and corner points on both copies ("written as fields": a whole lot cannot be written
-- in one go). The back building and the extension part of a lot were empty in those drafts: not exercised.
local function readyHouse(S, rec)
  if not rec.lots or #rec.lots == 0 then return nil, "empty residential draft" end
  local tr = rec.lots[1].primaryBuildingTransform.Translation
  local b = findNew(S, 3, tr.X, tr.Y, rec.n0)
  if not b then return "wait" end
  local words = {}; for i, l in ipairs(rec.lots) do words[i] = encLot(l) end
  return table.concat(words, " ")
end
-- the house lots of job.f[first ...] made by the helper; ext = the house the draft extends (EXTEND) or nil (HOUSE)
local function applyHouse(S, job, first, ext)
    local lots = {}
    for i = first, #job.f do local l = decLot(job.f[i]); if not l then return "bad lot " .. (i - first + 1) end; lots[#lots + 1] = l end
    if #lots == 0 then return "no lots" end
    local tr = lots[1].primaryBuildingTransform.Translation
    if T.findB(3, tr.X, tr.Y) then return "ok" end
    for _, l in ipairs(lots) do
      local taken = T.areaTaken(S, job, 3, (#l.corners >= 3) and l.corners or l.smoothBorder)
      if taken then return taken end
    end
    local h = A.helper(); if not valid(h) then return "no helper" end
    h.placeBuilding = 0
    h:setFieldMode(true, 3)
    -- the same draft fields as the sender's lord (setFieldMode sets isExtension for plot type 3; extensionFor is ours)
    if ext then pcall(function() h.isExtension = true; h.extensionFor = ext end) end
    local how = {}
    for i, l in ipairs(lots) do how[i] = writeLot(h, i, l) end
    local function noExt() if ext then pcall(function() h.extensionFor = nil end) end end      -- the helper keeps nothing of it
    if #h.extractedPlots ~= #lots then h:setFieldMode(false, 0); noExt(); return "extractedPlots write failed (" .. table.concat(how, ",") .. ")" end
    local n0 = #S.eng.buildingArr
    h:commitField()
    h:setFieldMode(false, 0)
    noExt()
    -- (lane 81, lane 87's l87g) the game can make a plot's house a few frames after commitField: the lots are looked
    -- for again each tick for up to HOUSE_WAIT s (a pending helper job), not once. Before, a house made a moment later
    -- was "made 0 of 1 lots" (FAILED: no hold of the values module on the new site, so this copy's own carriers
    -- brought it a timber 22.7 s before the host had one), and the house still stood.
    local found = {}
    local function look()
      local made, got = 0, {}
      for i, l in ipairs(lots) do
        local t2 = l.primaryBuildingTransform.Translation
        local b = found[i] or findNew(S, 3, t2.X, t2.Y, n0)
        if b then
          if not found[i] then found[i] = b; T.addB(b); touch(b) end
          made = made + 1; got[#got + 1] = #b.FieldPoints .. "/" .. #b.fieldBorderPoints .. " of " .. #l.smoothBorder .. "/" .. #l.corners
        end
      end
      return made, got
    end
    local made, got = look()
    local function done(m, g, waited)
      A.log("TOWN house lots: %d of %d made%s, written as %s, border and corner points on the new houses: %s", m, #lots,
        waited and string.format(" (after %.2f s)", waited) or "", table.concat(how, ","), table.concat(g, "; "))
      if m ~= #lots then return string.format("made %d of %d lots (%s)", m, #lots, table.concat(how, ",")) end
      return "ok"
    end
    if made == #lots then return done(made, got) end
    T.pend = { kind = "house", job = job, t0 = vnow(), check = function(S2, Pd, h2, waited)
      local m, g = look()
      if m == #lots or waited >= T.HOUSE_WAIT then return done(m, g, waited) end
      return nil
    end }
    return "pending"
end
T.HOUSE_WAIT = 3.0
def { name = "HOUSE", status = "console2", ref = "lane_t1 T4; lane 2 run s6", helper = true, wait = 3,
  ready = readyHouse, apply = function(S, job) return applyHouse(S, job, 1, nil) end }
-- EXTEND <the house the draft extends> <lots as HOUSE>   (lane 29; see the addCommitFieldRequest hook above)
-- The game makes a new house from the lot and leaves the named house unchanged, so the replay is HOUSE's with the
-- helper's extensionFor set to the same house for the commit (and cleared after it). A copy that does not have the
-- named house still makes the new house (the game does not read the field), and says so in the log.
def { name = "EXTEND", status = "console2", ref = "lane_s21_29", helper = true, wait = 3,
  ready = function(S, rec)
    if not valid(rec.ext) then return nil, "the house the draft extends is gone" end
    local r, why = readyHouse(S, rec)
    if r == nil or r == "wait" then return r, why end
    return bkeyOf(rec.snap) .. " " .. r
  end,
  apply = function(S, job)
    local ext = findBkey(job.f[1])
    if not ext then A.log("TOWN EXTEND: the extended house %s is not on this copy; the new house is made anyway", tostring(job.f[1])) end
    return applyHouse(S, job, 2, ext)
  end }

-- what the lane module for ground placements (coop_x_build.lua) uses of this file's placement code
T.place = { clearMoved = clearMoved, findNew = findNew, encV = encV, decV = decV, encPts = encPts, decPts = decPts, acopy = acopy,
            decB = decB, bkeyYaw = bkeyYaw, roadPts = roadPts, vnow = vnow, stat = stat }

-- ================================================================ DEMOLISH and ROADDEL
-- SEE (lane_t1 T5, static): the confirm in the building panel adds the building to the lord's demolishRequests; the pawn Tick
-- drains that list with demolish(b, refund=true) and empties it only after the loop, so deselectBuilding(b), which fired
-- during a real confirm (session 7c), still finds b in the list. Inventory_C:confirmDemolish is a second signal (GUESS that
-- it is the final step). Both are de-duplicated by address. The building is named from the index: it is gone by the tick.
local function demRec(b)
  return { k = "DEMOLISH", obj = b, addr = addrOf(b) }
end
hook(P .. "PawnCPP:deselectBuilding", { "DEMOLISH" }, function(self, bp)
  local p = self:get(); if not isLocal(p) then return nil end
  local b = bp and bp:get(); if not valid(b) then return nil end
  local a = addrOf(b); local arr = p.demolishRequests; local listed = false
  for i = 1, #arr do if addrOf(un(arr[i])) == a then listed = true; break end end
  if not listed then return nil end             -- an ordinary deselect (or a replay's demolish on another pawn)
  return demRec(b)
end)
hook(INV .. "confirmDemolish", { "DEMOLISH" }, function(self)
  local w = self:get(); if not valid(w) then return nil end
  local b = w.Building
  if not valid(b) then return nil end
  return demRec(b)
end)

-- status: static read only (lane_t1 T5: the building is appended to the helper's demolishRequests, which the helper's Tick
-- drains with demolish(b, refund=true) - the same path as the click. A direct building:demolish() is never used: it was in
-- the script that crashed first in session 14.)
-- (lane 81, the own-click rule) two players demolish the same building within a moment: the host removed it first, the
-- friend's line finds nothing. That is no refusal (the friend wants it gone, and it is gone): "already gone", told in
-- the log, neither refused (a refusal made the friend reload every copy) nor passed on. Only a building THIS copy removed
-- in the last T.GONE_FOR s counts; a building the host never had is still refused.
T.GONE_FOR = 30.0
function T.noteGone(e)
  if not (e and e.t and e.x and e.y) then return end
  T.goneB = T.goneB or {}
  local now = os.clock()
  for i = #T.goneB, 1, -1 do if now - T.goneB[i].c > T.GONE_FOR then table.remove(T.goneB, i) end end
  T.goneB[#T.goneB + 1] = { t = e.t, x = e.x, y = e.y, c = now }
end
function T.wasGone(e)
  local now = os.clock()
  for _, g in ipairs(T.goneB or {}) do
    if g.t == e.t and now - g.c <= T.GONE_FOR and not far(g.x, g.y, e.x, e.y, T.cfg.tolB) then return true end
  end
  return false
end
-- (lane 76, task 76e round 3) A DEMOLISH ON THE HOST. Session l7p: the host's line went at the confirm, the host's
-- own game took the building out of its list a moment later (its pawn Tick drains demolishRequests), while the friend
-- removed it as soon as the line came: the friend showed the building gone 0.16 s before the host had it gone. So on
-- the host the line waits until the building has left the host's own building list, at most DEM_WAIT s (then it goes
-- as before). The checks of the first call (the job board, the duplicate) are made once.
local DEM_WAIT = 1.0
local function demStillThere(S, rec)
  local b = rec.obj
  if not valid(b) then return false end
  local okD, dying = pcall(function() return b.bActorIsBeingDestroyed end)
  if okD and dying == true then return false end
  local ok, there = pcall(function()
    local arr = S.eng.buildingArr; local a = rec.addr
    for i = 1, #arr do if addrOf(un(arr[i])) == a then return true end end   -- (the length first: no read past the end)
    return false
  end)
  return ok and there == true
end
T.demStillThere = demStillThere
def { name = "DEMOLISH", status = "static", ref = "lane_t1 T5", helper = true, wait = DEM_WAIT + 1.0,
  ready = function(S, rec)
    if not rec.demKey then
      local now = os.clock()
      if valid(rec.obj) and C.jobs and C.jobs.gone then pcall(C.jobs.gone, { rec.obj }, "demolish_own") end   -- (lane 35) this player's own demolish
      if rec.addr and T.recentDem[rec.addr] and now - T.recentDem[rec.addr] < 5 then return nil, "duplicate" end
      if rec.addr then T.recentDem[rec.addr] = now end
      T.noteGone(rec.snap)                                               -- (lane 81) this copy's own removal
      rec.demKey = bkeyOf(rec.snap)
      if not rec.demKey then return nil, "no name" end
    end
    if S.role == "host" and rec.addr and vnow() - rec.t < DEM_WAIT and demStillThere(S, rec) then return "wait" end
    return rec.demKey
  end,
  apply = function(S, job)
    local e = decB(job.f[1]); if not e then return "bad fields" end
    local b = T.findB(e.t, e.x, e.y)
    -- (lane 81) this copy's own demolish of it is under way (the pawn drains its list in its own tick): a second one
    -- here would demolish it twice (live r5c: two piles on the friend, the host one)
    -- A building that IS here is skipped only when it is that same object (its address) this copy asked to remove
    -- a moment ago; the place alone never says so: a building of the same type put up again at that place since is a
    -- new one and is demolished (the advisor's case: build, demolish, build again, demolish within 30 s)
    if b then
      local ra = addrOf(b)
      if ra and T.recentDem[ra] and os.clock() - T.recentDem[ra] < 5 then return "already gone" end
    elseif T.wasGone(e) then return "already gone"
    else return "building not found" end
    T.noteGone(e)                                                        -- (lane 81) removed here by this replay
    local h = A.helper(); if not valid(h) then return "no helper" end
    if not T.requestDemolish(h, b) then return "could not add the building to the helper's demolishRequests" end
    T.pend = { kind = "demolish", job = job, e = e, t0 = vnow() }
    return "pending"
  end }

-- append a building to the helper's demolish list (the UI path); true when the list grew. Also used by the tests' cleanup.
function T.requestDemolish(h, b)
  if C.forget then C.forget(b) end              -- crash guard (coop.lua): out of the nearby-buildings lists first
  if C.jobs and C.jobs.gone then pcall(C.jobs.gone, { b }, "demolish") end   -- (lane 35) the job board and PICK let go of it first
  local arr = h.demolishRequests; local n0 = #arr
  local ok = pcall(function() arr[n0 + 1] = b end)
  return ok and #h.demolishRequests == n0 + 1
end

-- SEE: pre-hook PawnCPP:removeRoad (its implementation has no native caller, lane_t1 T5b READ). Named from the road index.
hook(P .. "PawnCPP:removeRoad", { "ROADDEL" }, function(self, rp)
  local p = self:get(); if not isLocal(p) then return nil end
  local r = rp and rp:get(); local a = addrOf(r); local e = a and T.ridx[a]
  return { k = "ROADDEL", obj = r, snap = e and { ax = e.ax, ay = e.ay, bx = e.bx, by = e.by } or nil }
end)
-- status: static read only (lane_t1 T5b: helper:removeRoad(road), the road found by its end points)
def { name = "ROADDEL", status = "static", ref = "lane_t1 T5b", helper = true,
  ready = function(S, rec)
    local id = rec.snap
    if valid(rec.obj) then local ok, live = pcall(rident, rec.obj); if ok and live then id = live end end
    if not id then return nil, "removed road was not in the index: not sent" end
    return rkeyOf(id)
  end,
  apply = function(S, job)
    local n = nums(job.f[1]); if not n[4] then return "bad fields" end
    local r = T.findRoad(n[1], n[2], n[3], n[4]); if not r then return "road not found" end
    local h = A.helper(); if not valid(h) then return "no helper" end
    h:removeRoad(r)
    return "ok"
  end }

-- ================================================================ UPGRADE, EXT, ARTISAN (add*Request on the lord)
-- SEE: pre-hook PawnCPP:addUpgradeRequest / addExtensionChangeRequest / addArtisanChangeRequest with the UpgradeRequest
-- {buildingMaster, upgradeID, slot} (lane_t1 T8, struct READ). The engine pump applies them for playerRef only, so the
-- other copies call the building's own function, which charges the building's owner and region (READ 4d0aaa0).
-- "Order oxen/horse/mule/hound/pig/goat" are upgrades too (ids 13, 19, 21, 26, 27, 28) and reach orderLivestock natively.
-- (lane 76, task 76e round 3) AN ANIMAL ORDERED ON THE HOST. Probe o76a: an ox ordered at the player's stable reached
-- the friend 0.60 s BEFORE the host had it: the hook sends the line at the request, the host's own game carries the
-- request out in its pump a moment later, while a friend calls BeginUpgrade at once (and the animal comes inside that
-- call). So on the host an order's line waits until the order's region counts more animals than at the request, at
-- most ORDER_WAIT s (then it goes as before).
local ANIMAL_ORDER = { [13] = true, [19] = true, [21] = true, [26] = true, [27] = true, [28] = true }
local ORDER_WAIT = 2.0
local function animalsOf(b) local ok, n = pcall(function() return b.Region:getTotalLivestockCount() end); if ok and type(n) == "number" then return n end end
-- (lane 76, task 76e round 5) what a request can change on the building, read by property only (no game call: this
-- runs in the hook too): the upgrades done, being upgraded, the artisan job, the extensions' types
local function reqState(b)
  local ok, s = pcall(function()
    local t = {}
    local a = b.upgradesDone; for i = 1, #a do local v = a[i]; if type(v) ~= "number" then v = un(v) end; t[#t + 1] = tostring(v) end
    local e = {}; local ex = b.Extensions; for i = 1, #ex do local x = ex[i]; local okT, ty = pcall(function() return x.Type end); e[#e + 1] = okT and tostring(ty) or "?" end
    return table.concat(t, ",") .. "|" .. tostring(b.isBeingUpgraded) .. "|" .. tostring(b.artisanJob) .. "|" .. table.concat(e, ",")
  end)
  return ok and s or nil
end
T.reqState = reqState
-- how often the request's own id stands in upgradesDone (UPGRADE: its id; EXT and ARTISAN: 100 + the type, the game's
-- own count of them, as gateId below)
local function reqGid(rec) local id = rec.id or -1; if rec.k ~= "UPGRADE" and id < 100 then return id + 100 end; return id end
local function idCount(b, gid)
  local ok, n = pcall(function()
    local c = 0; local a = b.upgradesDone
    for i = 1, #a do local v = a[i]; if type(v) ~= "number" then v = un(v) end; if tonumber(v) == gid then c = c + 1 end end
    return c
  end)
  return ok and n or nil
end
T.reqGid, T.idCount = reqGid, idCount
local function seeRequest(kind)
  return function(self, req)
    local p = self:get(); if not isLocal(p) then return nil end
    local q = req:get(); local b = q.buildingMaster
    if not valid(b) then return nil end
    local rec = { k = kind, obj = b, addr = addrOf(b), id = int(q.upgradeID), slot = int(q.slot) }
    if kind == "UPGRADE" and ANIMAL_ORDER[rec.id] then rec.n0 = animalsOf(b) end
    rec.pre = reqState(b); rec.preN = idCount(b, reqGid(rec))
    return rec
  end
end
hook(P .. "PawnCPP:addUpgradeRequest", { "UPGRADE" }, seeRequest("UPGRADE"))
hook(P .. "PawnCPP:addExtensionChangeRequest", { "EXT" }, seeRequest("EXT"))
hook(P .. "PawnCPP:addArtisanChangeRequest", { "ARTISAN" }, seeRequest("ARTISAN"))

-- (lane 76, task 76e round 4) EVERY REQUEST OF THE KIND ON THE HOST. The animal order above was one case of a class:
-- the hook sees add*Request, the request only waits on the lord (its flag upgradeRequestPending,
-- extensionChangeRequestPending or artisanChangeRequestPending is set) until the pawn's pump carries it out, while a
-- friend calls BeginUpgrade / ChangeExtension / changeArtisanType at once when the line comes. So on the host the line
-- waits while the lord's flag of that kind is still set, at most REQ_WAIT s (then it goes as before).
local REQ_WAIT = 1.0
local REQ_GRACE = 0.3   -- (round 5) after the pump: the change of a request comes in that frame or the next (q76c)
local PENDING = { UPGRADE = "upgradeRequestPending", EXT = "extensionChangeRequestPending", ARTISAN = "artisanChangeRequestPending" }
local function reqPending(S, kind)
  local f = PENDING[kind]; if not f then return false end
  local ok, v = pcall(function() return S.p1[f] end)
  return ok and v == true
end
T.reqPending = reqPending
local function readyRequest(S, rec)
  if rec.k == "UPGRADE" and rec.n0 and S.role == "host" and valid(rec.obj) and vnow() - rec.t < ORDER_WAIT then
    local n = animalsOf(rec.obj)
    if n and n <= rec.n0 then return "wait" end
  end
  if S.role == "host" and T.cfg.reqWait and vnow() - rec.t < REQ_WAIT and reqPending(S, rec.k) then
    rec.waitedPending = true; return "wait"
  end
  -- (lane 76, task 76e round 5) A REQUEST THE HOST'S GAME DID NOT CARRY OUT. The pump clears the flag also when it did
  -- nothing with the request (q76a: a request with no valid building: flag set and cleared, no change); the line went
  -- all the same and a friend did it (its apply checks only "already has it"). So on the host, once its pump has run
  -- (the flag clear), a request whose building is unchanged after REQ_GRACE s is NOT sent: the host's game refused it.
  -- An animal order is judged by its animals above. A flag still set after REQ_WAIT: sent as before (not known).
  if S.role == "host" and T.cfg.reqRefuse and not rec.n0 and rec.pre and not reqPending(S, rec.k) then
    -- carried out: this request's own id came into upgradesDone (two requests in one frame: each judged by its own);
    -- an id the building had already (a backyard built again): the building changed at all
    local done
    local n = valid(rec.obj) and rec.preN and idCount(rec.obj, reqGid(rec))
    if n and rec.preN == 0 then done = n > 0
    else local cur = valid(rec.obj) and reqState(rec.obj); done = cur ~= rec.pre end
    if not done then
      rec.sameSince = rec.sameSince or vnow()
      if vnow() - rec.sameSince < REQ_GRACE then return "wait" end
      stat(S, "t_reqRefused")
      return nil, "the host's own game did not carry it out (not seen " .. string.format("%.1f", vnow() - rec.sameSince) .. " s after its pump): refused here, not sent"
    end
  end
  local key = bkeyOf(rec.snap)
  if rec.k == "EXT" then return key .. " " .. rec.slot .. " " .. rec.id end
  return key .. " " .. rec.id
end
-- (lane 87, cure 1) on a friend, an upgrade begun here (the host's, or this player's own) has the host's work fraction
-- held in this tick when it is here already (coop_x_values.lua V.begun)
local function begun(S, b) if S.role ~= "friend" then return end; local Vv = rawget(C, "values"); if Vv and Vv.begun then pcall(Vv.begun, b) end end
-- status: static read only (lane_t1 T8a: b:BeginUpgrade(id); BeginUpgrade does not check canUpgrade, so the host checks)
-- Animal orders (ox 13, horse 19, mule 21, hound 26, pig 27, goat 28) can be given again and again, and hasUpgrade stays
-- true after the first one. The "already has it" skip must not apply to them (session 21, panel press: a second ox
-- ordered at a stable was logged "ok" and never ordered on the other copy; the next order was refused and forced a resync).
local REPEATABLE = { [13] = true, [19] = true, [21] = true, [26] = true, [27] = true, [28] = true }
def { name = "UPGRADE", status = "static", ref = "lane_t1 T8a", ready = readyRequest, wait = ORDER_WAIT + 1.0,
  apply = function(S, job)
    local b = findBkey(job.f[1]); if not b then return "retry:building not found" end
    local id = int(job.f[2])
    local okH, has = pcall(function() return b:hasUpgrade(id) end)
    if okH and has and not REPEATABLE[id] then return "ok" end
    if S.role == "host" then
      local okC, can = pcall(function() return b:canUpgrade(id, {}) end)
      if okC and can == false then return "cannot upgrade on the host" end
    end
    b:BeginUpgrade(id); touch(b); begun(S, b)
    return "ok"
  end }
-- EXT and ARTISAN have no check of their own and no "already done" guard in the game (lane_u Q5): a line applied twice
-- would charge and rebuild twice. So every copy skips a change the building already has, and the host refuses one the
-- game's own canUpgrade says no to (the same test the game's button uses).
-- The request carries the extension or workshop TYPE (chicken coop 1, brewery 5 ...); hasUpgrade and canUpgrade count
-- these as upgrades 100 + type. Measured on the host's own panel (session 21): after "chicken coop" (sent as 1)
-- hasUpgrade(101) became true and 20 regional wealth was charged; after "brewery" (sent as 5) hasUpgrade(105), 10.
-- Before this the check asked about upgrade 1 or 5, which the game refuses, so every real click from a friend was refused.
local function gateId(t) return t < 100 and t + 100 or t end
local function upgradeGate(S, b, id)
  local okH, has = pcall(function() return b:hasUpgrade(id) end)
  if okH and has then return "ok" end
  if S.role == "host" then
    local okC, can = pcall(function() return b:canUpgrade(id, {}) end)
    if okC and can == false then return "cannot be done on the host" end
  end
  return nil
end
-- status: static read only (lane_t1 T8b: b:ChangeExtension(slot, newType))
def { name = "EXT", status = "static", ref = "lane_t1 T8b", ready = readyRequest, wait = REQ_WAIT + 1.0,
  apply = function(S, job)
    local b = findBkey(job.f[1]); if not b then return "retry:building not found" end
    local stop = upgradeGate(S, b, gateId(int(job.f[3]))); if stop then return stop end
    -- (lane 55) the slot is a place in the building's list of extensions: never past its end
    local slot = int(job.f[2]); local okE, ne = pcall(function() return #b.Extensions end)
    if not okE or slot < 0 or slot >= ne then return "retry:no extension slot " .. tostring(slot) .. " here (" .. tostring(ne) .. ")" end
    b:ChangeExtension(slot, int(job.f[3])); touch(b); begun(S, b)
    return "ok"
  end }
-- status: static read only (lane_t1 T8c: b:changeArtisanType(type))
def { name = "ARTISAN", status = "static", ref = "lane_t1 T8c", ready = readyRequest, wait = REQ_WAIT + 1.0,
  apply = function(S, job)
    local b = findBkey(job.f[1]); if not b then return "retry:building not found" end
    local stop = upgradeGate(S, b, gateId(int(job.f[2]))); if stop then return stop end
    b:changeArtisanType(int(job.f[2])); touch(b); begun(S, b)
    return "ok"
  end }

-- ================================================================ families: ADDW, REMW, FAMS
-- SEE: pre-hook SMBuildingMaster:addActiveWorkerFamily / removeActiveWorkerFamily, self = the building (plus/minus buttons,
-- recorded live, session 7c). Which family the game picks depends on homes and current tasks, which drift between copies
-- (lane_t2 T6a/T6b READ), so the line carries the resulting assignedFamilyIDs. The host's result is the referee: the host
-- passes the action on with ITS list and also sends FAMS (origin host) so the friend who clicked is corrected too.
-- Only this building's list is corrected; the same job-assignment pass can also fill vacancies elsewhere in the region.
-- status: unassignFamily + assignFamily proven live on one copy (README session 14); the reassignFamily branch static (lane_t2 T6)
function T.fixFamilies(b, want)
  local R = b.Region; if not valid(R) then return "no region" end
  local ws = set(want); local me = addrOf(b)
  for _ = 1, 2 do
    local cur = famIds(b); local cs = set(cur); local changed = 0
    for _, id in ipairs(cur) do if not ws[id] then R:unassignFamily(id); changed = changed + 1 end end
    local where = {}
    local bs = R:GetBuildings()
    for i = 1, #bs do local x = un(bs[i]); if valid(x) then pcall(function() local a = x.assignedFamilyIDs; for j = 1, #a do where[int(un(a[j]))] = x end end) end end
    cs = set(famIds(b))
    local nf = #R.workerFamilies                     -- (lane 55) a family id is a place in this list: never past its end
    for _, id in ipairs(want) do
      if not cs[id] and id >= 0 and id < nf then
        if where[id] and addrOf(where[id]) ~= me then R:reassignFamily(id, b) else R:assignFamily(id, b) end
        changed = changed + 1
      end
    end
    if changed == 0 then return "ok" end
  end
  return encIds(famIds(b)) == encIds(want) and "ok" or ("still differs: have " .. encIds(famIds(b)) .. " want " .. encIds(want))
end

local function seeObj(name, argt)
  return function(self, a1, a2, a3, a4)
    local o = self:get(); if not valid(o) then return nil end
    local raw = { a1, a2, a3, a4 }; local args = {}
    for i = 1, #argt do args[i] = argval(raw[i], argt:sub(i, i)) end
    return { k = name, obj = o, addr = addrOf(o), args = args }
  end
end

local function readyFam(S, rec)
  local b = rec.obj; if not valid(b) then return nil, "building gone" end
  if not owned(b) then return nil, "not the lord's building" end
  return bkeyOf(rec.snap) .. " " .. encIds(famIds(b)) .. " " .. int(b.numActiveWorkerFamilies)
end
-- status: the plus/minus call proven live on one copy (README session 14); host forward + FAMS correction not yet run on two copies
local function applyFam(fn)
  return function(S, job)
    local b = findBkey(job.f[1]); if not b then return "retry:building not found" end
    b[fn](b); touch(b)
    if S.role == "host" then
      local f = job.f[1] .. " " .. encIds(famIds(b)) .. " " .. int(b.numActiveWorkerFamilies)
      return "ok", f, { { "FAMS", f } }
    end
    local r = T.fixFamilies(b, decIds(job.f[2]))
    return (r == "ok") and "ok" or ("families " .. r)
  end
end
hook(P .. "SMBuildingMaster:addActiveWorkerFamily", { "ADDW" }, seeObj("ADDW", ""))
hook(P .. "SMBuildingMaster:removeActiveWorkerFamily", { "REMW" }, seeObj("REMW", ""))
-- status: proven live on one copy (README session 14: hook sees it; the game picked another family and
-- Region:unassignFamily + assignFamily restored it exactly)
def { name = "ADDW", status = "live1", ref = "README s7c, s14", rel = true, ready = readyFam, apply = applyFam("addActiveWorkerFamily") }
-- status: proven live on one copy (README session 14, as ADDW)
def { name = "REMW", status = "live1", ref = "README s7c, s14", rel = true, ready = readyFam, apply = applyFam("removeActiveWorkerFamily") }
-- status: unassignFamily + assignFamily proven live on one copy (README session 14); reassignFamily (a family that works
-- elsewhere) static (lane_t2 T6). No SEE: sent by the host only; on whenever ADDW or REMW is on.
def { name = "FAMS", status = "live1", ref = "README s14; lane_t2 T6", follows = { "ADDW", "REMW" },
  apply = function(S, job)
    local b = findBkey(job.f[1]); if not b then return "retry:building not found" end
    local r = T.fixFamilies(b, decIds(job.f[2]))
    local n = int(job.f[3])
    if int(b.numActiveWorkerFamilies) ~= n then A.log("TOWN families: active count here %d, host %d", int(b.numActiveWorkerFamilies), n) end
    return (r == "ok") and "ok" or ("families " .. r)
  end }

-- ================================================================ setters: same call on the same building or region
-- argt letters: i = int / enum / byte, b = bool, n = FName. rel = the call is relative (repeats must not be dropped as echoes).
local function readySetter(S, rec)
  local d = T.defs[rec.k]; local o = rec.obj
  if d.target == "region" or rec.late then
    if not valid(o) then return nil, "target gone" end
    if not owned(o) then return nil, "not the lord's" end
  elseif not rec.owned then return nil, "not the lord's" end
  -- "late" records come from a panel's own click handler: the value is read now, a tick after the handler ran
  if rec.late then local okL, v = pcall(function() return int(o[rec.late]) end); if not okL then return nil, "value unreadable" end; rec.args = { v } end
  local argstr = encArgs(d.argt, rec.args)
  if not d.rel and T.isEcho(rec.k, rec.addr, argstr) then return nil, "echo" end   -- (lane 81) the same value a replay just applied
  local key = d.target == "building" and bkeyOf(rec.snap) or T.rkey(o)
  if not key then return nil, "region without a name" end
  return key .. " " .. argstr
end
-- status: per action, see its setter(...) line ("live1" = README session 14, "static" = the lane recipe id given there)
local function applySetter(S, job)
  local d = T.defs[job.act]
  local o
  if d.target == "region" then o = T.findR(job.f[1]) else o = findBkey(job.f[1]) end
  if not o then return "retry:" .. d.target .. " not found" end
  local vals = decArgs(d.argt, job.f[2])
  -- (lane 55) a trade setter's first number is a good, a place in the region's list of trade rules (as the world
  -- module checks it for a rival's rules): never past that list's end
  if d.goodList then
    local g = tonumber(vals[1]); local okN, nr = pcall(function() return #o[d.goodList] end)
    if not (g and okN and g >= 0 and g + 1 <= nr) then return "good " .. tostring(vals[1]) .. " is not in this region's list (" .. tostring(nr) .. ")" end
  end
  o[d.fn](o, table.unpack(vals, 1, #d.argt))
  touch(o, d, job.f[2] or "-")
  return "ok"
end
local function setter(name, cls, fn, argt, status, ref, rel)
  hook(P .. cls .. ":" .. fn, { name }, seeObj(name, argt))
  return def { name = name, status = status, ref = ref, rel = rel, abs = not rel, fn = fn, argt = argt,
               target = (cls == "Region") and "region" or "building", ready = readySetter, apply = applySetter }
end

-- region setters (lane_t2 T7a/T7b/T9/T11a). "live1" = proven live on one copy (README session 14: a hook saw every call
-- with its arguments and the same call replays it); "static" = static read only (the lane_t2 recipe id given).
setter("PLIM", "Region", "setProductionLimit", "ii", "live1", "README s7c, s14")
setter("PUNLIM", "Region", "setProductionUnlimited", "i", "live1", "README s14")
setter("CLIM", "Region", "setCraftingConsumptionLimit", "iii", "static", "lane_t2 T7b")
setter("CUNLIM", "Region", "setCraftingConsumptionUnlimited", "ii", "static", "lane_t2 T7b")
setter("TAX", "Region", "changeTaxRate", "ni", "static", "lane_t2 T11a")
setter("TRULE", "Region", "changeTradeRule", "ii", "live1", "README s14")
setter("TTARGET", "Region", "changeTargetInventory", "ii", "live1", "README s14")
setter("TPART", "Region", "changeTradePartnerLimit", "ii", "live1", "README s14")
setter("TGLOBAL", "Region", "setGlobalTradeAllowedForGood", "ib", "live1", "README s14")
for _, k in ipairs({ "TRULE", "TTARGET", "TPART", "TGLOBAL" }) do T.defs[k].goodList = "tradeRules" end   -- (lane 55, see applySetter)
-- buying a trade route pays regional wealth natively on each copy, once (lane_t2 T9e); irreversible
setter("TROUTE", "Region", "unlockOneTradeLevel", "i", "static", "lane_t2 T9e", true)

-- building setters (lane_t1 T8e/T8f, lane_t2 T6d/T6e/T7c..T7n/T9f)
-- status: proven live on one copy (README session 7 click recorded; session 14 replay by direct call and restore)
setter("SLEEP", "SMBuildingMaster", "setSleep", "b", "live1", "README s7, s14")
setter("CPAUSE", "SMBuildingMaster", "setConstructionPaused", "b", "static", "lane_t2 T7d")
setter("PRIO", "SMBuildingMaster", "SetPriority", "i", "live1", "README s14")
-- The construction panel's priority arrows may write buildPriority without calling SetPriority (lane_u Q2: two real
-- clicks logged nothing). So the panel's own handler is hooked as well: it names the building (the tab's Building) and
-- the new value is read a tick later and sent as the same PRIO line (SetPriority with an absolute value: harmless twice).
hook("/Game/ManorLords/UI/Widgets/Widgets_Inventory/W_InventoryTab_Construction.W_InventoryTab_Construction_C:BndEvt__W_InventoryTab_Construction_constructionPriorityPlusMinus_K2Node_ComponentBoundEvent_0_priorityChanged__DelegateSignature",
  { "PRIO" }, function(self)
    local w = self:get(); if not valid(w) then return nil end
    local b = w.Building; if not valid(b) then return nil end
    return { k = "PRIO", obj = b, addr = addrOf(b), late = "buildPriority" }
  end)
setter("RECIPE_ON", "SMBuildingMaster", "EnableRecipe", "i", "static", "lane_t2 T7f")
setter("RECIPE_OFF", "SMBuildingMaster", "DisableRecipe", "i", "static", "lane_t2 T7f")
setter("CROP", "SMBuildingMaster", "setCropType", "i", "static", "lane_t2 T7h")
setter("CROPYEAR", "SMBuildingMaster", "setCropTypeForYear", "ii", "static", "lane_t2 T7h")
setter("CROPSPRING", "SMBuildingMaster", "SetSpringCropOverride", "ib", "static", "lane_t2 T7h")
setter("TSTOCK", "SMBuildingMaster", "SetTargetStock", "ii", "static", "lane_t2 T7g")
setter("TSTOCK_ON", "SMBuildingMaster", "EnableTargetStock", "i", "static", "lane_t2 T7g")
setter("TSTOCK_OFF", "SMBuildingMaster", "DisableTargetStock", "i", "static", "lane_t2 T7g")
setter("TSTOCK_BY", "SMBuildingMaster", "ChangeTargetStockBy", "ii", "static", "lane_t2 T7g", true)
setter("PROTECT", "SMBuildingMaster", "SetProtectResourceArea", "b", "static", "lane_t2 T7i")
setter("BFLAG", "SMBuildingMaster", "setCustomBuildingFlag", "ii", "static", "lane_t2 T7k")
setter("WARESET", "SMBuildingMaster", "resetWorkArea", "", "static", "lane_t2 T7e")
setter("SEASON_ADD", "SMBuildingMaster", "AddSeasonalWorker", "i", "static", "lane_t2 T6d", true)
setter("SEASON_REM", "SMBuildingMaster", "RemoveSeasonalWorker", "i", "static", "lane_t2 T6d", true)
setter("SEASON_USE", "SMBuildingMaster", "SetIsUsingSeasonalAssignment", "b", "static", "lane_t2 T6d")
setter("SEASON_SET", "SMBuildingMaster", "ChangeSeasonalWorkerAssignment", "ii", "static", "lane_t2 T6d")
setter("LSW", "SMBuildingMaster", "changeActiveLivestockWorkers", "i", "static", "lane_t2 T6e", true)
setter("MULE_SELL", "SMBuildingMaster", "changeMuleTrain_sellingType", "i", "static", "lane_t2 T7n")
setter("MULE_BUY", "SMBuildingMaster", "changeMuleTrain_buyingType", "i", "static", "lane_t2 T7n")
-- livestock orders spawn a merchant unit (new unit id, random looks) on each copy; irreversible (lane_t2 T9f)
setter("LIVESTOCK", "SMBuildingMaster", "orderLivestock", "i", "static", "lane_t2 T9f", true)
setter("LIVECANCEL", "SMBuildingMaster", "cancelOrder", "i", "static", "lane_t2 T9f", true)

-- maintenance slider: the call is on the building's MaintenanceComponent (dump: SMBuildingMaster.MaintenanceComponent).
-- The hook gives the component; the building is found by scanning the index for the one whose MaintenanceComponent has that
-- address (only names from the dumps; no GetOwner). Value: EMaintenanceSliderValue 0 Half, 1 Normal, 2 Double (lane_t2 T7j).
-- status: proven live on one copy for the hook and the call (README session 14, slider 1 -> 2 -> 1); the owner lookup by
-- scan is new and not yet run live
hook(P .. "MaintenanceComponent:SetSliderValue", { "MAINT" }, seeObj("MAINT", "i"))
def { name = "MAINT", status = "live1", ref = "README s14; lane_t2 T7j", argt = "i", abs = true,
  ready = function(S, rec)
    local argstr = encArgs("i", rec.args)
    if T.isEcho("MAINT", rec.addr, argstr) then return nil, "echo" end
    local b
    for _, e in pairs(T.bidx) do
      if valid(e.obj) then local ok, a = pcall(function() return addrOf(e.obj.MaintenanceComponent) end); if ok and a == rec.addr then b = e.obj; break end end
    end
    if not b then return nil, "building of this maintenance component not found in the index" end
    if not owned(b) then return nil, "not the lord's" end
    return bkeyOf(identB(b)) .. " " .. argstr
  end,
  apply = function(S, job)
    local b = findBkey(job.f[1]); if not b then return "retry:building not found" end
    local mc = b.MaintenanceComponent
    if not valid(mc) then return "building has no maintenance component" end
    mc:SetSliderValue(int(job.f[2])); touch(mc, T.defs.MAINT, job.f[2])
    return "ok"
  end }

-- ================================================================ fields the panel writes itself: FILTER, STALLS, OVERSTOCK
-- The storehouse and granary "Accepted Goods" filter, the "market stalls" switch of a building and the marketplace's
-- overstock number have no game function: the panel's blueprint writes the building's field. So the panel's own
-- handler is hooked (it names the building), the field is read a tick later, and the line carries the field's value
-- (session 21: found by pressing the panels; nothing was sent and the copies differed).
--   FILTER <building> <goods NOT accepted, "+"-joined, or ->     STALLS <building> <0|1>     OVERSTOCK <building> <n>
-- Receiving: STALLS and OVERSTOCK are plain writes of the same field. The filter is a list this script cannot lengthen
-- or shorten, so each good that differs is toggled through a never-shown copy of the game's own filter button
-- (storageFilterGood_C with its ItemId and building set, its own handler run): the game's code edits the list. Tried
-- live on a friend's copy: 216 -> 216,15 -> 216,15,6 -> 216,15, no panel opened, nothing selected.
--   status: capture and replay pressed on two copies without the pointer (session 21); not yet by a real click
local WI = "/Game/ManorLords/UI/Widgets/Widgets_Inventory/"
local FILTER_CLICK = "BndEvt__storageFilterGood_Button_0_K2Node_ComponentBoundEvent_2_OnButtonReleasedEvent__DelegateSignature"
local function seeWidget(kind)
  return function(self)
    local w = self:get(); if not valid(w) then return nil end
    local b = w.building; if not valid(b) then return nil end
    return { k = kind, obj = b, addr = addrOf(b) }
  end
end
-- FERTILIZE (lane 75). The field panel calls the setter in two ways: its checkbox (the player), and its own
-- UpdateFertilization, which repeats the value the field already has while the panel is alive (measured: 9 calls in
-- 1 s with the value unchanged, also after the panel was closed) and turns the setting off itself when no year of the
-- field is fallow any more. The hook runs before the game's routine, so the field still holds its old value there
-- (measured: "false > true" on a press, "false > false" on the repeats). Only a call that changes the value is sent:
-- the press, and the panel's own turn-off (a copy without that panel open would keep the old value for good: measured
-- with a checkbox-only hook, host false and friend true, no line). No address: a replay runs inside T.quiet and leaves
-- the value equal, so there is no echo to wait out, and a press right after a replay is the player's.
hook(P .. "SMBuildingMaster:SetAllowFertilization", { "FERTILIZE" }, function(self, a1)
  local b = self:get(); if not valid(b) then return nil end
  local want = a1:get() == true
  local okC, cur = pcall(function() return b:GetAllowFertilization() == true end)
  if not okC or cur == want then return nil end
  return { k = "FERTILIZE", obj = b, args = { want } }
end)
def { name = "FERTILIZE", status = "live", ref = "lane_s21_29 A031; lane_s21_75",
      fn = "SetAllowFertilization", argt = "b", target = "building", abs = true, ready = readySetter, apply = applySetter }

local function filterOf(b)
  local t = {}; local a = b.storageFilter
  for i = 1, #a do t[#t + 1] = int(un(a[i])) end
  table.sort(t)
  return #t > 0 and table.concat(t, "+") or "-"
end
T.fieldSent = T.fieldSent or {}
local function fieldAction(name, read, write)
  return def { name = name, target = "building", status = "press2", ref = "README s21 (panel press)", abs = true,
    ready = function(S, rec)
      local b = rec.obj; if not valid(b) then return nil, "building gone" end
      if not owned(b) then return nil, "not the lord's" end
      local v = read(b)
      if T.isEcho(name, rec.addr, v) then return nil, "echo" end
      -- one press of "all" or "none" runs the handler of every good: many records, one value. Send it once.
      local sk = name .. "@" .. tostring(rec.addr)
      if T.fieldSent[sk] and T.fieldSent[sk].v == v and os.clock() - T.fieldSent[sk].t < 1.0 then return nil, "same value just sent" end
      T.fieldSent[sk] = { v = v, t = os.clock() }
      return bkeyOf(rec.snap) .. " " .. v
    end,
    apply = function(S, job)
      local b = findBkey(job.f[1]); if not b then return "retry:building not found" end
      local v = job.f[2] or "-"
      local r = write(S, b, v); if r then return r end
      touch(b, T.defs[name], v)
      return "ok"
    end }
end
hook("/Game/UI/Inventory/storageFilterGood.storageFilterGood_C:" .. FILTER_CLICK, { "FILTER" }, seeWidget("FILTER"))
hook("/Game/UI/Inventory/storageFilterCategory.storageFilterCategory_C:BndEvt__storageFilterCategory_Button_86_K2Node_ComponentBoundEvent_0_OnButtonReleasedEvent__DelegateSignature", { "FILTER" }, seeWidget("FILTER"))
hook("/Game/UI/Inventory/storageFilterCategory.storageFilterCategory_C:BndEvt__storageFilterCategory_Button_52_K2Node_ComponentBoundEvent_1_OnButtonReleasedEvent__DelegateSignature", { "FILTER" }, seeWidget("FILTER"))
fieldAction("FILTER", filterOf, function(S, b, v)
  local want, have, todo = {}, {}, {}
  if v ~= "-" then for g in v:gmatch("%d+") do want[int(g)] = true end end
  local cur = filterOf(b); if cur ~= "-" then for g in cur:gmatch("%d+") do have[int(g)] = true end end
  for g in pairs(want) do if not have[g] then todo[#todo + 1] = g end end
  for g in pairs(have) do if not want[g] then todo[#todo + 1] = g end end
  if #todo == 0 then return nil end
  -- a fresh button every time (as in the spike): nothing in the game owns it, so a kept one could be collected
  local cls = StaticFindObject("/Game/UI/Inventory/storageFilterGood.storageFilterGood_C")
  if not valid(cls) then return "the game's filter button is not loaded" end
  local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(S.p1, 0)
  local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(S.p1, cls, pc)
  if not valid(w) then return "could not make the game's filter button" end
  w.building = b
  for _, g in ipairs(todo) do w.ItemId = g; w[FILTER_CLICK](w) end
  pcall(function() w:RemoveFromParent() end)
  local now = filterOf(b)
  if now ~= v then return "filter is " .. now .. " after the change, wanted " .. v end
  return nil
end)
hook(WI .. "Inventory.Inventory_C:BndEvt__Inventory_StallButton_K2Node_ComponentBoundEvent_15_OnClicked__DelegateSignature", { "STALLS" }, seeWidget("STALLS"))
-- Switching stalls off is more than the flag: the game's button also makes the building's families give up their
-- stalls at once (measured: the market went from 4 stalls to 2 on the host and stayed 4 on a friend that only got the
-- flag; a resync followed). The same game call is made here. Switching on needs nothing more: with the flag set the
-- game hands out stalls by itself, the same on both copies (seen: families 3 and 4 took the same two stalls).
fieldAction("STALLS", function(b) return b.allowMarketStalls and "1" or "0" end,
  function(S, b, v)
    local on = (v == "1")
    b.allowMarketStalls = on
    if not on then pcall(function() b:abandonAllMarketStalls() end) end
    return nil
  end)
hook(WI .. "W_InventoryTab_MarketProsperity.W_InventoryTab_MarketProsperity_C:BndEvt__W_InventoryTab_MarketProsperity_MinusButton_K2Node_ComponentBoundEvent_6_OnClicked__DelegateSignature", { "OVERSTOCK" }, seeWidget("OVERSTOCK"))
hook(WI .. "W_InventoryTab_MarketProsperity.W_InventoryTab_MarketProsperity_C:BndEvt__W_InventoryTab_MarketProsperity_PlusButton_K2Node_ComponentBoundEvent_7_OnClicked__DelegateSignature", { "OVERSTOCK" }, seeWidget("OVERSTOCK"))
fieldAction("OVERSTOCK", function(b) return tostring(int(b.supplyOverstocking)) end,
  function(S, b, v) b.supplyOverstocking = int(v); return nil end)

-- ================================================================ WAREA (work area) and REASSIGN (move a family to another workplace)
-- Both are clicks on the ground, so they could not be pressed from inside. They are caught at the game's own function
-- (SMBuildingMaster:setWorkArea(Center, range), Region:reassignFamily(familyID, workplace)) and replayed with the same
-- call. If the game makes these calls from its own native code, the hook never fires on a real click: then nothing
-- is sent, exactly as before. One real click of each settles it.
--   status: the call replayed on two copies through the test console (session 21); a real click not yet seen
hook(P .. "SMBuildingMaster:setWorkArea", { "WAREA" }, function(self, a1, a2)
  local b = self:get(); if not valid(b) then return nil end
  local c = a1 and a1:get(); local r = a2 and a2:get()
  if not c or type(r) ~= "number" then return nil end
  return { k = "WAREA", obj = b, addr = addrOf(b), x = c.X, y = c.Y, z = c.Z, r = r }
end)
-- (lane 30, real click, call recorder) The panel's "set work area" button and the click on the ground set the area in
-- native code: setWorkArea above never ran. What the script layer sees: PawnCPP:setWorkAreaMode(building) when the
-- button is pressed, then the raised event spawnWorkAreaConfirmation(centre, range) when the ground is clicked.
hook(P .. "PawnCPP:setWorkAreaMode", { "WAREA" }, function(self, a1)          -- only notes the building; sends nothing
  local p = self:get(); if not isLocal(p) then return nil end
  local b = a1 and a1:get(); if valid(b) then T.wareaB = b end
  return nil
end)
hook(BP_PAWN .. "spawnWorkAreaConfirmation", { "WAREA" }, function(self, a1, a2)
  local p = self:get(); if not isLocal(p) then return nil end
  local b = T.wareaB; if not valid(b) then return nil end
  local c = a1 and a1:get(); local r = a2 and a2:get()
  if not c or type(r) ~= "number" then return nil end
  return { k = "WAREA", obj = b, addr = addrOf(b), x = c.X, y = c.Y, z = c.Z, r = r }
end)
def { name = "WAREA", status = "console2", ref = "README s21",
  ready = function(S, rec)
    local b = rec.obj; if not valid(b) then return nil, "building gone" end
    if not owned(b) then return nil, "not the lord's" end
    return bkeyOf(rec.snap) .. " " .. string.format("%.0f,%.0f,%.0f,%.0f", rec.x, rec.y, rec.z, rec.r)
  end,
  apply = function(S, job)
    local b = findBkey(job.f[1]); if not b then return "retry:building not found" end
    local n = {}; for x in (job.f[2] or ""):gmatch("[^,]+") do n[#n + 1] = tonumber(x) end
    if #n < 4 then return "bad work area" end
    b:setWorkArea({ X = n[1], Y = n[2], Z = n[3] }, n[4]); touch(b)
    return "ok"
  end }
hook(P .. "Region:reassignFamily", { "REASSIGN" }, function(self, a1, a2)
  local r = self:get(); if not valid(r) then return nil end
  local fam = a1 and a1:get(); local b = a2 and a2:get()
  if type(fam) ~= "number" or not valid(b) then return nil end
  return { k = "REASSIGN", obj = r, addr = addrOf(r), fam = int(fam), b = b }
end)
-- (lane 30, real click, call recorder) The family card's "reassign" button and the click on the new workplace move the
-- family in native code: reassignFamily above never ran. What the script layer sees: PawnCPP:setReassignMode(member)
-- when the button is pressed. The member's family and workplace are noted; the town tick (reassignWatch) sends
-- REASSIGN when that family's workplace changes within 90 s.
hook(P .. "PawnCPP:setReassignMode", { "REASSIGN" }, function(self, a1)        -- only notes the family; sends nothing
  local p = self:get(); if not isLocal(p) then return nil end
  local u = a1 and a1:get(); if not valid(u) then return nil end
  local fam, old = -1, nil
  pcall(function() fam = int(u.workerFamilyID); old = u:getWorkplace() end)
  if fam and fam >= 0 then T.reassignW = { u = u, fam = fam, old = valid(old) and addrOf(old) or 0, t = os.clock() } end
  return nil
end)
function T.reassignWatch()
  local w = T.reassignW; if not w then return end
  if os.clock() - w.t > 90 or not valid(w.u) then T.reassignW = nil; A.log("TOWN reassign of family %d: no new workplace seen in 90 s", w.fam); return end
  local b; pcall(function() b = w.u:getWorkplace() end)
  if not valid(b) or addrOf(b) == w.old then return end
  T.reassignW = nil
  local r; pcall(function() r = b:GetRegion() end)
  if not valid(r) or not T.isOn("REASSIGN") then A.log("TOWN reassign of family %d seen, region not found or REASSIGN off: not sent", w.fam); return end
  push({ k = "REASSIGN", obj = r, addr = addrOf(r), fam = w.fam, b = b, t = vnow() })
end
def { name = "REASSIGN", status = "console2", ref = "README s21", rel = true,
  ready = function(S, rec)
    local r = rec.obj; if not valid(r) or not valid(rec.b) then return nil, "region or workplace gone" end
    if not owned(rec.b) then return nil, "not the lord's" end
    local rk = T.rkey(r); if not rk then return nil, "region without a name" end
    return rk .. " " .. rec.fam .. " " .. bkeyOf(rec.snap)
  end,
  apply = function(S, job)
    local r = T.findR(job.f[1]); if not r then return "retry:region not found" end
    local b = findBkey(job.f[3]); if not b then return "retry:workplace not found" end
    -- (lane 55) a family id is its place in the region's family list (0-based): never past its end
    local fid = int(job.f[2]); local okF, nf = pcall(function() return #r.workerFamilies end)
    if not okF or fid < 0 or fid >= nf then return "retry:no family " .. tostring(fid) .. " here (" .. tostring(nf) .. ")" end
    r:reassignFamily(fid, b); touch(r); touch(b)
    return "ok"
  end }

-- ================================================================ what lane modules (coop_x_*.lua) may use
-- A lane module adds actions in its own file, loaded after this one:
--   local X = _G.Coop.town.api
--   X.setter("NAME", "SMBuildingMaster", "gameFunction", "ib", "status", "where it was measured")   -- one named game call
--   X.fieldAction("NAME", read(b) -> string, write(S, b, value) -> nil or an error text)              -- a field the panel writes
--   X.hook(path, { "NAME" }, see)  and  X.def { name = "NAME", ready = ..., apply = ... }               -- anything else
-- Argument letters of a setter: i int / enum / byte, b bool, n FName, s string. A setter on "Region" targets the region.
T.api = { def = def, hook = hook, setter = setter, fieldAction = fieldAction, seeWidget = seeWidget, seeObj = seeObj,
          isEcho = T.isEcho, readySetter = readySetter, applySetter = applySetter, encArgs = encArgs, decArgs = decArgs,
          bident = identB, bkeyOf = bkeyOf, findBkey = findBkey, owned = owned, isLocal = isLocal, touch = touch,
          int = int, enc = enc, dec = dec, split = split, addrOf = addrOf, valid = valid, un = un, P = P, WI = WI }

-- ================================================================ tick: seen records -> lines
local function handleSeen(S, rec)
  if rec.k == "_note" then A.log("TOWN note: %s", rec.msg); stat(S, "t_notes"); return "done" end
  local d = T.defs[rec.k]; if not (d and d.ready) then return "done" end
  -- (lane 81) no drop by time here any more: a record on a target replayed in the last 0.75 s was dropped as an echo,
  -- also a player's real change (G22). Echoes are told by their value in d.ready (T.isEcho) and by T.depth.
  if rec.nameB and not rec.snap then
    rec.snap = identB(rec.nameB)
    if not rec.snap then
      stat(S, "t_noName"); A.log("TOWN %s not sent: the building had no usable name in the hook or in the tick", rec.k); return "done"
    end
  end
  local ok, res, why = pcall(d.ready, S, rec)
  if not ok then stat(S, "t_seeErr"); A.log("TOWN %s capture error: %s", rec.k, tostring(res)); return "done" end
  if res == "wait" then
    if vnow() - rec.t < (d.wait or 1) then return "wait" end
    A.log("TOWN %s not sent: the result never appeared (refused by the game?)", rec.k); return "done"
  end
  if res == nil then
    if why == "echo" then stat(S, "t_echo") end
    A.log("TOWN %s not sent: %s", rec.k, tostring(why)); return "done"
  end
  if type(res) == "table" then for _, f in ipairs(res) do T.emitAction(S, rec.k, f) end
  else T.emitAction(S, rec.k, res) end
  -- (lane 81) the player acted on this target: no echo of an earlier replay is expected on it any more, of any kind
  -- (kinds that undo each other: PLIM / PUNLIM, RECIPE_ON / OFF, TSTOCK_ON / OFF ...)
  if rec.addr then
    local mark = "@" .. tostring(rec.addr) .. ":"
    for k in pairs(T.expect) do if k:find(mark, 1, true) then T.expect[k] = nil end end
  end
  return "done"
end

local function processSeen(S, all)
  local q = T.q; T.q = {}
  local keep, n = {}, 0
  for _, rec in ipairs(q) do
    if all or n < 4 then n = n + 1; if handleSeen(S, rec) == "wait" then keep[#keep + 1] = rec end
    else keep[#keep + 1] = rec end
  end
  for _, rec in ipairs(T.q) do keep[#keep + 1] = rec end   -- anything a hook pushed meanwhile
  T.q = keep
end

-- ================================================================ tick: lines -> replays
-- (lane 81) the order rule, decided in the apply queue (the host's order): another player's line for a slot this
-- friend sent a value for marks it when it is APPLIED here (any status); this friend's own line coming back is a job
-- of the same queue: if it was marked, the host applied this friend's value last, and it is put back. Deciding when a
-- line arrives was wrong both ways: two lines can arrive in one read (game run cross 1), and a press can still wait in
-- the hook queue when the other line arrives (it is sent first in the next tick).
local function ownBack(S, job)
  local o = T.own and T.own[job.ownBack]
  if not (o and o.slot and T.ownSlot and T.ownSlot[o.slot] == job.ownBack) then return end   -- a newer own value is on its way
  T.ownSlot[o.slot] = nil
  if not o.over then return end
  local d = T.defs[job.act]
  T.depth = T.depth + 1
  local ok, status = pcall(d.apply, S, job)
  T.depth = T.depth - 1
  stat(S, "t_ownBack")
  A.log("TOWN %s %s: the host applied it after %s (lines crossed): this copy's value is put back: %s", job.act, job.ownBack, tostring(o.over), ok and tostring(status) or ("error " .. tostring(status)))
  if ok and status == "ok" and C.panels and C.panels.touched then pcall(C.panels.touched, job.act, job.f and job.f[1]) end
end
local function runJob(S, job)
  if job.ownBack then ownBack(S, job); return "done" end
  local d = T.defs[job.act]
  if S.role ~= "host" and job.origin ~= S.name and T.ownSlot then
    local slot = T.lineSlot(job.act, job.fields)
    local mine = slot and T.ownSlot[slot]
    if mine and T.own and T.own[mine] then T.own[mine].over = job.origin .. ":" .. tostring(job.n) end
  end
  T.depth = T.depth + 1
  local ok, status, fwd, extra = pcall(d.apply, S, job)
  T.depth = T.depth - 1
  if not ok then status = "error " .. tostring(status) end
  if status == "pending" then return "pending" end
  if type(status) == "string" and status:sub(1, 6) == "retry:" then
    if vnow() - job.t < T.cfg.retryS then return "retry" end
    status = status:sub(7)
  end
  T.finish(S, job, status, fwd, extra)
  return "done"
end

local function processApply(S, limit)
  if T.pend then checkPending(S) end
  local n = 0
  while #T.aq > 0 and n < (limit or 2) do
    local job = T.aq[1]; local d = T.defs[job.act]
    if d.helper and T.pend then break end             -- one helper placement at a time, in order
    if d.helper and S.helperRallyT and os.clock() - S.helperRallyT < 1.0 and valid(S.hp) and S.hp.requestBuild then break end   -- the helper is calling up a militia unit (core): wait for its tick
    local r = runJob(S, job)
    if r == "retry" then break end                     -- keep order: wait for the target (e.g. BUILD then SLEEP on it)
    table.remove(T.aq, 1); n = n + 1
  end
end

-- ================================================================ link messages
local function markSeen(id)
  T.seenMsg[id] = true; T.seenList[#T.seenList + 1] = id
  if #T.seenList > 2000 then for _ = 1, 500 do T.seenMsg[table.remove(T.seenList, 1)] = nil end end
end

local function onMessage(S, from, kind, w, line)
  if kind ~= "T" then return false end
  if C.hold then A.log("TOWN dropped a T line during a join/repair hold"); return true end
  local origin, n, act = w[4], w[5], w[6]
  if not (origin and n and act) then return true end
  if origin == S.name then                                      -- our own action coming back from the host
    -- (lane 81) the order rule: decided in the apply queue, in the host's order (runJob, ownBack)
    local tag = origin .. ":" .. tostring(n)
    local o = T.own and T.own[tag]
    if o and o.slot and T.ownSlot and T.ownSlot[o.slot] == tag and T.defs[act] then
      T.aq[#T.aq + 1] = { act = act, origin = origin, n = n, from = from, f = split(o.fields or "", " "), fields = o.fields, t = vnow(), ownBack = tag }
    end
    return true
  end
  if S.role == "host" and origin ~= from then A.log("TOWN dropped %s: origin %s sent by %s", act, origin, tostring(from)); return true end
  local id = origin .. ":" .. n
  if T.seenMsg[id] then return true end
  markSeen(id)
  if act == "NAK" then
    local tag = w[7] or ""
    do local o = T.own and T.own[tag]; if o and o.slot and T.ownSlot and T.ownSlot[o.slot] == tag then T.ownSlot[o.slot] = nil end end   -- (lane 81) refused: nothing to put back
    if tag:sub(1, #S.name + 1) == S.name .. ":" then
      local why = dec(w[8] or "?")
      stat(S, "t_refused")
      -- The player already sees the result of an action the host did not do. A refused building (typically: another
      -- player spent the silver a moment earlier) is undone by name: the building this copy placed is removed the way the
      -- demolish click does it, and the host's treasury push puts the silver right. Anything else: ask the host for a
      -- repair, i.e. everyone reloads the host's world.
      --   status: undo of a refused building: see README session 17
      local rec = T.own and T.own[tag]
      -- (lane 81) the undo: done now when this copy's own building or area is there; when it is not there yet (a line
      -- read in the same moment its own commit is still being made: a slow copy or a fast link), looked for again
      -- every tick for up to UNDO_WAIT s before the repair
      if not T.undoTry(S, tag, rec, why) then
        T.undoQ = T.undoQ or {}
        T.undoQ[#T.undoQ + 1] = { tag = tag, rec = rec, why = why, t0 = os.clock() }
        A.log("TOWN the host refused our action %s (%s): our own not found yet, looked for again for %.1f s", tag, why, T.UNDO_WAIT)
      end
    end
    return true
  end
  local d = T.defs[act]
  if not (d and d.apply) then A.log("TOWN unknown action %s from %s", act, tostring(from)); return true end
  local f = {}; for i = 7, #w do f[#f + 1] = w[i] end
  local job = { act = act, origin = origin, n = n, from = from, f = f, fields = table.concat(f, " "), t = vnow() }
  if not T.isOn(act) then T.finish(S, job, "switched off here"); return true end
  T.aq[#T.aq + 1] = job
  return true
end

-- (lane 81) the pile a refused building's undo leaves (see the NAK branch): removed as soon as it is there
local function undoPileStep(S)
  local L = T.undoPiles; if not (L and #L > 0) then return end
  local now = os.clock()
  for i = #L, 1, -1 do
    local u = L[i]; local done = false
    pcall(function()
      local arr = S.eng.buildingArr
      for j = 1, #arr do
        local b = un(arr[j])
        if valid(b) and A.btype(b) == 88 and not u.pre[addrOf(b) or 0] then
          local l = b:K2_GetActorLocation()
          if not far(l.X, l.Y, u.x, u.y, 500) then
            local Pm = rawget(C, "patch"); local ok, msg = false, "no native piece"
            if Pm and Pm.pilegone then ok, msg = Pm.pilegone(b) end
            A.log("TOWN the pile our refused building %s left: %s (%s)", tostring(u.tag), ok and "removed" or "left to the game", tostring(msg))
            stat(S, ok and "t_undonePile" or "t_undonePileLeft"); done = true; return
          end
        end
      end
    end)
    if done or now - u.t0 > 5.0 then table.remove(L, i) end
  end
end

-- ================================================================ tick
local function tick(S, clock)
  if C.hold then T.lastC = nil; return end     -- a join or repair is loading a save: S.eng may be invalid; onWorld resets after
  advanceClock(S)
  T.p1addr = addrOf(S.p1)
  ensureHooks(false)
  scanStep(S)
  if T.reassignW then T.reassignWatch() end
  if #T.q > 0 then processSeen(S, false) end
  if T.pend or #T.aq > 0 then processApply(S) end
  if T.undoQ and #T.undoQ > 0 and T.undoStep then T.undoStep(S) end
  if T.undoPiles and #T.undoPiles > 0 then undoPileStep(S) end
  if clock - (T.pruneT or 0) > 5.0 then
    T.pruneT = clock
    for k, v in pairs(T.expect) do if v.t < clock then T.expect[k] = nil end end
    for k, v in pairs(T.touched) do if clock - v > 5 then T.touched[k] = nil end end
    for k, v in pairs(T.recentDem) do if clock - v > 10 then T.recentDem[k] = nil end end
    if T.dropped and T.dropped > 0 then A.log("TOWN %d hook records dropped (queue full)", T.dropped); T.dropped = 0 end
  end
end

-- (lane 81, the own-click rule) a refused drawn kind of this copy removed by name, the way BUILD's undo removes a
-- building: the field, pasture or market at the line's centre; every burgage plot of the line's lots (EXTEND: after
-- the extended house); the road between the line's first and last points. Each under the quiet wrapper (our own
-- removal is not an action to report). true when the removal was handed to the game.
local AREA_T = { FIELD = 5, PASTURE = 10, MARKET = 13 }
local function demolishOwn(b)
  local h = A.helper(); if not (valid(b) and valid(h)) then return false end
  local a = addrOf(b); if a then T.recentDem[a] = os.clock() end
  local ok, r = pcall(T.quiet, function() return T.requestDemolish(h, b) end)
  return ok and r == true
end
local function lotsOf(rec, first)
  local w = split(rec.all or "", " "); local o = {}
  for i = first, #w do local l = decLot(w[i]); if l then o[#o + 1] = l end end
  return o
end
T.undoArea = {
  FIELD = function(S, rec) local c = decV(split(rec.all or "", " ")[1]); if not c then return "no centre" end; local b = T.findB(5, c.X, c.Y); if not b then return "not found" end; return demolishOwn(b) end,
  PASTURE = function(S, rec) local c = decV(split(rec.all or "", " ")[1]); if not c then return "no centre" end; local b = T.findB(10, c.X, c.Y); if not b then return "not found" end; return demolishOwn(b) end,
  MARKET = function(S, rec) local c = decV(split(rec.all or "", " ")[1]); if not c then return "no centre" end; local b = T.findB(13, c.X, c.Y); if not b then return "not found" end; return demolishOwn(b) end,
  HOUSE = function(S, rec)
    local n, done = 0, 0
    for _, l in ipairs(lotsOf(rec, 1)) do local tr = l.primaryBuildingTransform.Translation; n = n + 1; local b = T.findB(3, tr.X, tr.Y); if b and demolishOwn(b) then done = done + 1 end end
    return n > 0 and done == n or ("lots " .. done .. " of " .. n)
  end,
  EXTEND = function(S, rec)
    local n, done = 0, 0
    for _, l in ipairs(lotsOf(rec, 2)) do local tr = l.primaryBuildingTransform.Translation; n = n + 1; local b = T.findB(3, tr.X, tr.Y); if b and demolishOwn(b) then done = done + 1 end end
    return n > 0 and done == n or ("lots " .. done .. " of " .. n)
  end,
  -- a refused MOVE: only when the host had removed the building itself ("moved building gone on the host"): this
  -- copy's moved copy at the new place (the line's second word) is removed. Any other refusal of a move: the repair.
  MOVE = function(S, rec, why)
    if not tostring(why or ""):find("moved building gone on the host", 1, true) then return "no undo for this refusal of a move" end
    local w = split(rec.all or "", " "); local e = decB(w[2] or ""); if not e then return "no new place" end
    local b = T.findB(e.t, e.x, e.y); if not b then return "not found" end
    return demolishOwn(b)
  end,
  ROAD = function(S, rec)
    local pts = decPts(split(rec.all or "", " ")[1]); if #pts < 2 then return "no points" end
    local a, z = pts[1], pts[#pts]
    local r = T.findRoad(a.X, a.Y, z.X, z.Y); if not r then return "road not found" end
    local h = A.helper(); if not valid(h) then return "no helper" end
    local ok, e = pcall(T.quiet, function() h:removeRoad(r) end)
    return ok or tostring(e)
  end,
}
-- where a refused drawn kind of this copy stood, for the pile watch (the BUILD undo's): its centre, or its first lot
function T.undoAt(rec)
  local w = split(rec.all or "", " ")
  if rec.act == "MOVE" then local e = decB(w[2] or ""); if e then return { x = e.x, y = e.y } end end
  if AREA_T[rec.act] then local c = decV(w[1]); if c then return { x = c.X, y = c.Y } end end
  if rec.act == "HOUSE" or rec.act == "EXTEND" then
    local l = decLot(w[rec.act == "EXTEND" and 2 or 1] or ""); if l then local tr = l.primaryBuildingTransform.Translation; return { x = tr.X, y = tr.Y } end
  end
  return nil
end

-- (lane 81) one try of the undo of a refused own action: true when it is done (removed, or a kind with no undo: the
-- repair was asked), false when this copy's own object is not there yet
T.UNDO_WAIT = 1.0
-- (lane 81) the reasons a drawn kind or a move is refused for BEFORE the host made any part of it: only then is the
-- friend's removal of all of it right. Any other reason (e.g. "made 2 of 3 lots": the host keeps a part) asks for the
-- repair, as before (the friend loads alone).
local UNDO_SAFE = { "place is taken", "afford", "no helper", "bad fields", "bad lot", "bad points", "no lots",
                    "made nothing", "made no road", "write failed", "moved building gone on the host", "refused by the test" }
function T.undoSafe(why)
  why = tostring(why or "")
  for _, w in ipairs(UNDO_SAFE) do if why:find(w, 1, true) then return true end end
  return false
end
function T.undoTry(S, tag, rec, why, last)
  local undone, missing = false, false
  if rec and rec.act == "BUILD" and rec.f1 then
    local e = decB(rec.f1); local b = e and T.findB(e.t, e.x, e.y); local h = A.helper()
    if b and valid(h) then
      local a = addrOf(b); if a then T.recentDem[a] = os.clock() end      -- our own removal is not an action to report
      local ok, r = pcall(T.quiet, function() return T.requestDemolish(h, b) end)
      undone = ok and r == true
    elseif not b then missing = true end
  elseif rec and T.undoArea and T.undoArea[rec.act] and not T.undoSafe(why) then
    A.log("TOWN the host refused our %s %s after a part of it may have been made there (%s): no undo, the repair", tostring(rec.act), tag, tostring(why))
  elseif rec and T.undoArea and T.undoArea[rec.act] then
    local okU, r = pcall(T.undoArea[rec.act], S, rec, why)                  -- a drawn kind: removed by name
    undone = okU and r == true
    if not undone and okU and (r == "not found" or r == "road not found" or (type(r) == "string" and r:find("^lots 0 of"))) then missing = true end
    if not undone and not missing then A.log("TOWN the undo of our %s %s did not take (%s)", tostring(rec.act), tag, tostring(r)) end
  end
  if missing and not last then return false end
  if undone then
    -- (lane 81, the own-click rule) the game's demolish (refund) leaves a pile where the refused building stood;
    -- the host has none there. With the native goods switch on a pile never empties by itself here, and the facts
    -- module removed it only after 20 s (live r5b B1: 88 shown 0.37 s after the press, gone after 21 s). It goes
    -- now: a pile that appears at that place within 5 s is emptied and removed (P.pilegone).
    local e = (rec.act == "BUILD") and decB(rec.f1) or (T.undoAt and T.undoAt(rec))
    if e then
      local pre = {}
      pcall(function() local arr = S.eng.buildingArr; for i = 1, #arr do local x = un(arr[i]); if valid(x) and A.btype(x) == 88 then local l = x:K2_GetActorLocation(); if not far(l.X, l.Y, e.x, e.y, 500) then pre[addrOf(x) or 0] = true end end end end)
      T.undoPiles = T.undoPiles or {}
      T.undoPiles[#T.undoPiles + 1] = { x = e.x, y = e.y, t0 = os.clock(), pre = pre, tag = tag }
    end
    stat(S, "t_undone")
    A.log("TOWN the host refused our %s %s (%s): removed here", (rec.act == "BUILD") and "building" or tostring(rec.act), tag, why)
    local text = why:find("place is taken", 1, true) and "That place was already taken"
      or (why:find("afford", 1, true) and "The treasury could not pay for that building") or "The host could not do that here"
    if C.notify then C.notify("refused", text) end
  else
    A.log("TOWN the host refused our action %s: %s. This copy now differs from the host: asking for a repair", tag, why)
    if C.join and C.join.requestRepair then C.join.requestRepair("refused " .. tag) end
  end
  return true
end
local function undoStep(S)
  local L = T.undoQ; if not (L and #L > 0) then return end
  local now = os.clock()
  for i = #L, 1, -1 do
    local u = L[i]
    local last = now - u.t0 >= T.UNDO_WAIT
    if T.undoTry(S, u.tag, u.rec, u.why, last) then table.remove(L, i) end
  end
end
T.undoStep = undoStep

C.register("town", {
  onWorld = function(S) T.reset(); A.log("TOWN world reset: caches and queues cleared") end,
  tick = tick,
  onMessage = onMessage,
})

-- ================================================================ console and test aids
function T.enable(name, on)
  if not T.defs[name] then return "no action " .. tostring(name) end
  T.enabled[name] = (on ~= false); T.hookT = -10
  if C.s then A.log("TOWN %s %s", name, T.enabled[name] and "on" or "off") end
  return name .. " " .. (T.enabled[name] and "on" or "off")
end
function T.list()
  local t = {}
  for _, n in ipairs(T.order) do local d = T.defs[n]; t[#t + 1] = string.format("%s[%s,%s]", n, d.status, T.isOn(n) and "on" or "off") end
  return table.concat(t, " ")
end
function T.status()
  local reg, waiting = 0, 0; local R = _G.__coop_town_hooks or {}
  for path, h in pairs(T.hooks) do if R[path] then reg = reg + 1 elseif anyOn(h.defs) then waiting = waiting + 1 end end
  local nb, nr = 0, 0; for _ in pairs(T.bidx) do nb = nb + 1 end; for _ in pairs(T.ridx) do nr = nr + 1 end
  local on = {}; for _, n in ipairs(T.order) do if T.isOn(n) then on[#on + 1] = n end end
  return string.format("town %s | on: %s | hooks %d registered, %d waiting | seen %d, to apply %d, placement %s | index %d buildings, %d roads | echo blocked %d | hook errors %d %s",
    T.version, table.concat(on, ","), reg, waiting, #T.q, #T.aq, T.pend and T.pend.job.act or "-", nb, nr, T.echo or 0, T.hookErr or 0, T.lastHookErr or "")
end
-- remove every hook of this module (console only, never from a hook callback)
function T.unhookAll()
  local R = _G.__coop_town_hooks or {}; local n = 0
  for path, ids in pairs(R) do pcall(UnregisterHook, path, ids[1], ids[2]); n = n + 1 end
  _G.__coop_town_hooks = {}
  return n .. " hooks removed"
end

-- feed one action as if it came over the link from <origin> (default "selftest") and run it now; returns origin:n
function T.inject(act, fields, origin)
  local S = C.s; origin = origin or "selftest"
  T.seq = T.seq + 1
  local line = string.format("0 %.3f T %s %d %s %s", A.now(), origin, T.seq, act, fields)
  onMessage(S, origin, "T", A.words(line), line)
  processApply(S, 10)
  local id = origin .. ":" .. T.seq
  return id, T.results[id] or "queued/pending"
end

-- move every position in an action's fields by (dx, dy): lets a one-copy test replay a captured action on free ground
local function shiftV(v, dx, dy) return { X = v.X + dx, Y = v.Y + dy, Z = v.Z } end
local function shiftPts(s, dx, dy) local t = decPts(s); for i, v in ipairs(t) do t[i] = shiftV(v, dx, dy) end; return encPts(t) end
local function shiftTr(x, dx, dy)
  if x.Translation.X == 0 and x.Translation.Y == 0 then return x end   -- an unused transform stays zero (lane_t1 T4)
  x.Translation = shiftV(x.Translation, dx, dy); return x
end
local function shiftFields(act, fields, dx, dy)
  local f = split(fields, " ")
  if act == "BUILD" or act == "DEMOLISH" then local e = decB(f[1]); e.x = e.x + dx; e.y = e.y + dy; f[1] = (act == "BUILD") and bkeyYaw(e) or bkeyOf(e)
  elseif act == "MOVE" then for i = 1, 2 do local e = decB(f[i]); e.x = e.x + dx; e.y = e.y + dy; f[i] = (i == 2) and bkeyYaw(e) or bkeyOf(e) end
  elseif act == "ROAD" then f[1] = shiftPts(f[1], dx, dy)
  elseif act == "FIELD" or act == "PASTURE" or act == "BAILEY" then f[1] = encV(shiftV(decV(f[1]), dx, dy)); f[4] = shiftPts(f[4], dx, dy); f[5] = shiftPts(f[5], dx, dy)
  elseif act == "ROADDEL" then local n = nums(f[1]); f[1] = rkeyOf({ ax = n[1] + dx, ay = n[2] + dy, bx = n[3] + dx, by = n[4] + dy })
  elseif act == "HOUSE" then
    for i, w in ipairs(f) do
      local l = decLot(w)
      for _, k in ipairs({ "smoothBorder", "corners", "extensionSmoothBorder", "extensionCorners" }) do for j, v in ipairs(l[k]) do l[k][j] = shiftV(v, dx, dy) end end
      for _, k in ipairs({ "primaryBuildingTransform", "secondaryBuildingTransform", "extensionTransform" }) do l[k] = shiftTr(l[k], dx, dy) end
      l.backFacade = { A = shiftV(l.backFacade.A, dx, dy), B = shiftV(l.backFacade.B, dx, dy) }
      f[i] = encLot(l)
    end
  end
  return table.concat(f, " ")
end

-- the fields of a captured line "T <origin> <n> <ACT> <fields...>" (or of the core-prefixed form)
local function fieldsOf(line)
  local w = A.words(line); local i = 1
  while w[i] and w[i] ~= "T" do i = i + 1 end
  local f = {}; for j = i + 4, #w do f[#f + 1] = w[j] end
  return w[i + 3], table.concat(f, " ")
end

T.test = {
  shift = shiftFields,
  fieldsOf = fieldsOf,
  cap = function() T.cap = {}; T.capT = os.clock(); return "capturing sent lines" end,
  uncap = function() local c = T.cap or {}; T.cap = nil; return c end,
  lines = function() return T.cap or {} end,
  pump = function() T.p1addr = addrOf(C.s.p1); processSeen(C.s, true); return #T.q end,
  hooksNow = function() T.p1addr = addrOf(C.s.p1); for _ = 1, 8 do ensureHooks(true) end; return T.status() end,
  result = function(id) return T.results[id] end,
  clearEcho = function() T.touched = {}; T.expect = {}; T.recentDem = {}; T.ownSlot = {} end,   -- one-copy tests act on a target right after replaying on it
  -- test cleanup: remove a building the way the click does (helper's demolishRequests; gone after the helper's next Tick;
  -- refund=true, so a goods pile of type 88 may appear). Never building:demolish() directly (HAZARDS).
  demolish = function(b) if not valid(b) then return false end; return T.quiet(T.requestDemolish, A.helper(), b) end,
  helper = function() return A.helper() end,
  flags = function() local t = {}; for k, v in pairs(T.enabled) do t[k] = v end; return t end,
  restoreFlags = function(t) for k, v in pairs(t) do T.enabled[k] = v end end,
}

return "coop town " .. T.version .. " loaded: " .. T.list()
