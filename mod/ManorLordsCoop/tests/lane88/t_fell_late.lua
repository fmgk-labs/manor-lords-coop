-- Desk test of lane 88's late felling (coop_x_jobs.lua, lane 54's FELL block: fellAtHostEnd, fellTick, fellHolds).
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane88/t_fell_late.lua mod/ManorLordsCoop/Scripts/coop_x_jobs.lua
-- The real module is loaded; its felling functions are taken from it; the board's give (J.giveLate) is stood in for
-- by a recorder that puts the task on the villager as the game would at its next think. Case of probe p88c: the
-- host's felling ends (its next start line comes) while the friend's woodcutter is on another task: before, nothing
-- was sent and the tree never fell here. Now: the host's felling is given; once the woodcutter fells, FELL is sent
-- (and again every 0.2 s); a tree already fallen here is not given; the 30 game s limit holds; the pending felling
-- lets its own give pass and holds any other.
local pass = 0
local function ok(c, what) assert(c, "FAIL " .. what); pass = pass + 1; print("PASS " .. what) end
if not math.tointeger then math.tointeger = function(x) x = tonumber(x); if x and x == math.floor(x) then return x end; return nil end end
table.unpack = table.unpack or unpack
local t = 100
os.clock = function() return t end
local mod
local fallen = {}
_G.FindAllOf = function(cls) if cls == "FallenTreeBP_C" then return fallen end; return {} end
_G.RegisterHook = function() end
_G.FName = function(s) return { ToString = function() return s end } end
local fells = {}
local function valid(o) return type(o) == "table" and o._valid == true end
Coop = { s = { role = "friend", worlds = 1 }, api = { valid = valid, un = function(o) return o end, log = function(...) end, send = function() end, now = os.clock,
  btype = function() return 0 end, pawns = function() return {} end },
  register = function(n, m) mod = m end, stale = function() return false end,
  patch = { fell = function(rg, x, y) fells[#fells + 1] = { x = x, y = y, t = t }; return true end } }
assert(loadfile(ARG1))()
assert(mod, "the board did not register")
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 300 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name then return v end end
  for i = 1, 300 do local n, v = debug.getupvalue(fn, i); if not n then break end; if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end end
end
local fellAtHostEnd = assert(upvalue(mod.onMessage, "fellAtHostEnd"), "fellAtHostEnd")
local fellTick = assert(upvalue(mod.tick, "fellTick") or upvalue(mod.onMessage, "fellTick"), "fellTick")
local fellHolds = assert(upvalue(mod.onMessage, "fellHolds") or upvalue(mod.tick, "fellHolds"), "fellHolds")
local J = Coop.jobs
J.cfg.fell = true
-- a region and a building the felling's target building names
local region = { _valid = true, GetAddress = function() return 0x5000 end }
local camp = { _valid = true, GetRegion = function() return region end, GetAddress = function() return 0x6000 end, IsActorBeingDestroyed = function() return false end }
local TREE = { X = 80400.0, Y = -73800.0, Z = 0 }
local function felling() return { Type = 3, targetEntityLocation = { X = TREE.X, Y = TREE.Y, Z = 0 }, targetBuilding = camp, TargetLocation = { Pos = TREE } } end
local u = { _valid = true, Tasks = { { Type = 4, targetEntityLocation = { X = 0, Y = 0, Z = 0 }, TargetLocation = { Pos = { X = 0, Y = 0, Z = 0 } } } } }
local hostRec = felling()
local e = { key = "1.F3.1", u = u, host = { rec = hostRec, ident = "3|x|-", t = t, hp = nil } }
J.byKey = { [e.key] = e }
local given = {}
J.giveLate = function(ee, q, clock) given[#given + 1] = { e = ee, q = q, t = clock }; return true end
-- the host's next start for the woodcutter (an S line with another task): its felling ended there
local function hostNext() fellAtHostEnd({ "1", "0", "U", "S", e.key, "4" }, t) end
hostNext()
ok(#given == 1 and given[1].q.rec == hostRec, "the woodcutter on another task gets the host's felling (it would never fall here)")
ok(J.fellP and J.fellP[e.key] and J.fellP[e.key].late, "... and the felling is pending (late)")
ok(fellHolds(e, { rec = hostRec }) == false, "the pending felling lets its own give pass")
ok(fellHolds(e, { rec = { Type = 4 } }) == true, "... and holds any other start of the host's (queued for after the felling)")
-- the woodcutter has not started it yet: nothing sent, kept
for i = 1, 10 do t = t + 0.25; if J.fellP then fellTick(t, 4) end end
ok(#fells == 0 and J.fellP and J.fellP[e.key], "while the woodcutter walks (not felling yet): no FELL, the felling waits")
-- it starts felling that tree (the game's think): FELL every 0.2 s from now
u.Tasks = { felling() }
for i = 1, 4 do t = t + 0.25; if J.fellP then fellTick(t, 4) end end
ok(#fells >= 2 and math.abs(fells[1].x - TREE.X) < 1, "once it fells that tree: FELL sent, and again (" .. #fells .. " times)")
-- the tree falls here: its felling ends
u.Tasks = {}
fallen[1] = { _valid = true, TreeFallingInitialTransform = { Translation = { X = TREE.X, Y = TREE.Y, Z = 0 } } }
t = t + 0.25; if J.fellP then fellTick(t, 4) end
ok(J.fellP == nil, "the felling ended (the tree fell): nothing pending")
-- a tree already fallen here is not given again
given = {}; u.Tasks = { { Type = 4, targetEntityLocation = { X = 0, Y = 0, Z = 0 }, TargetLocation = { Pos = { X = 0, Y = 0, Z = 0 } } } }
hostNext()
ok(#given == 0, "a tree that has fallen here already is not given again")
-- the 30 game s limit: a woodcutter that never starts
fallen = {}; given = {}; fells = {}
hostNext()
for i = 1, 40 do t = t + 0.25; if J.fellP then fellTick(t, 4) end end       -- 10 s at speed 4 = 40 game s
ok(J.fellP == nil and #fells == 0 and (J.n.fell_late_timeout or 0) >= 1, "a woodcutter that never starts it: dropped after 30 game s")
-- switched off
J.cfg.fellLate = false; given = {}
hostNext()
ok(#given == 0, "with cfg.fellLate = false nothing is given (the board as before)")
print(string.format("ALL %d PASS", pass))
