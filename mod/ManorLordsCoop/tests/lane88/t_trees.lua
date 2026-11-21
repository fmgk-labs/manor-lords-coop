-- Desk test of lane 88's ground items on the host's word (coop_x_trees.lua 0.2).
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane88/t_trees.lua mod/ManorLordsCoop/Scripts/coop_x_trees.lua
-- The module loaded twice (a host's copy and a friend's), each with its own Resource actors; the host's lines carried
-- to the friend at once. Checks: a destroyed item is not counted; carts are left to their own module; the friend's
-- amounts follow the host's (the p88c fault: each copy's villagers cut a felled tree or mine a stone heap at their own
-- pace, and the faster copy lost it first); an item the host had and no longer has goes on the friend 0.5 s after (the
-- game's removeResource where the class has it, then destroyed), not before; one the host never had goes after 20 s;
-- a whole list after a friend's ask; changes only in between; nothing removed while this copy cannot tell a destroyed
-- item, during a join, or when the host has gone quiet; one call per actor.
local pass = 0
local function ok(c, what) assert(c, "FAIL " .. what); pass = pass + 1; print("PASS " .. what) end
local t = 0
os.clock = function() return t end
local world = {}
local tellFails = false
local nextA = 0x1000
local function item(cls, x, y, amt)
  local o = { live = true, cls = cls, x = x, y = y, destroyed = false, removed = 0, destroyedCalls = 0, amt = amt }
  nextA = nextA + 16; local a = nextA
  local m = {
    IsValid = function(self) return self.live end,
    GetAddress = function() return a end,
    K2_GetActorLocation = function(self) return { X = self.x, Y = self.y, Z = 0 } end,
    GetClass = function(self) return { GetFName = function() return { ToString = function() return self.cls end } end } end,
    K2_DestroyActor = function(self) self.destroyedCalls = self.destroyedCalls + 1; if not self.stays then self.destroyed = true end end,
  }
  if cls == "FallenTreeBP_C" then m.removeResource = function(self) self.removed = self.removed + 1 end end
  return setmetatable(o, { __index = function(_, k)
    if k == "bActorIsBeingDestroyed" then if tellFails then error("no such field") end; return o.destroyed end
    if k == "removeResource" and not m.removeResource then error("no such function") end
    return m[k]
  end })
end
_G.FindAllOf = function(cls) assert(cls == "Resource"); return world.list end
local lines = {}
local function load(role)
  local mod
  local C = { s = nil }
  C.api = { valid = function(o) return o ~= nil and o:IsValid() end, log = function(f, ...) print("    [" .. role .. "] " .. string.format(f, ...)) end,
    send = function(line) lines[#lines + 1] = { from = role, line = line } end }
  C.register = function(n, x) mod = x end
  C.stale = function() return false end
  _G.Coop = C
  assert(loadfile(ARG1))()
  return mod, C
end
local MH, CH = load("host")
local MF, CF = load("friend")
local eng = { IsValid = function() return true end }
local SH = { role = "host", eng = eng }
local SF = { role = "friend", eng = eng }
local host = { item("FallenTreeBP_C", 1000, -2000, 15), item("FallenTreeBP_C", 5000, -6000, 3), item("Resource_Stone_C", 9000, 3000, 12),
  item("Resource_Handcart_C", 100, 100, 1) }
local friend = { item("FallenTreeBP_C", 1000, -2000, 15), item("FallenTreeBP_C", 5000, -6000, 3), item("Resource_Stone_C", 9000, 3000, 12),
  item("Resource_Handcart_C", 300, 300, 1), item("FallenTreeBP_C", 20000, -20000, 9), item("Resource_Stone_C", 9150, 3000, 4) }
local dead = item("FallenTreeBP_C", 7000, -7000, 0); dead.destroyed = true; host[#host + 1] = dead
local function words(line) local w = { "1", "0" }; for x in line:gmatch("%S+") do w[#w + 1] = x end; return w end
local function deliver()
  local q = lines; lines = {}
  for _, l in ipairs(q) do
    local w = words(l.line)
    if l.from == "host" then MF.onMessage(SF, "host", w[3], w, l.line) else MH.onMessage(SH, "friend1", w[3], w, l.line) end
  end
end
local function frame(x)
  t = x
  world.list = host; MH.tick(SH, x); deliver()
  world.list = friend; MF.tick(SF, x); deliver()
end
local function run(a, b) local x = a; while x <= b + 1e-9 do frame(x); x = x + 0.05 end end
local function sentKinds() local n = { S = 0, D = 0 }; for _, l in ipairs(lines) do local k = l.line:match("^FT (%a)"); if k then n[k] = (n[k] or 0) + 1 end end; return n end

run(0, 2)
local whole = CH.trees.sentMap
local nh = 0; for _ in pairs(whole) do nh = nh + 1 end
ok(nh == 3, "the host tells its 3 items: no destroyed one, no cart (" .. nh .. ")")
ok(friend[5].removed == 0 and friend[6].destroyedCalls == 0, "nothing removed in the first 2 s (a tree or heap the host never had waits 20 s)")
-- the host's woodcutters cut the first tree: 15 -> 13; the friend's own are slower (still 15): the host's amt written
host[1].amt = 13
run(2.05, 2.5)
ok(friend[1].amt == 15, "the host cut its tree 15 -> 13: the friend's (15) is not written down (run l88f: written down, the friend's own cutters finished it first)")
-- the friend's own miners are faster on the stone heap (12 -> 9): the host's 12 written back, so it cannot run out first
friend[3].amt = 9
run(2.55, 3.0)
ok(friend[3].amt == 12, "the friend's stone heap gets the host's amount back (9 -> 12): it cannot run out before the host's")
-- the host's gatherers finish the second tree at 3.1 (destroyed there)
t = 3.1; host[2].destroyed = true
run(3.1, 3.5)
ok(friend[2].removed == 0, "0.4 s after the host's tree went: still there on the friend")
run(3.55, 4.2)
ok(friend[2].removed == 1 and friend[2].destroyed, "... then removed (removeResource, then destroyed)")
-- a stone heap the host never had (1.5 m from the host's heap? no: 1.5 m off counts as the host's; this one is 1.5 m off)
ok(friend[6].destroyedCalls == 0, "a stone heap 1.5 m from the host's heap is the host's (kept, amount written)")
ok(friend[6].amt == 12, "... and it has the host's amount")
run(4.25, 21.0)
ok(friend[5].destroyed and friend[5].removed == 1, "the felled tree the host never had is removed after 20 s")
ok(friend[4].destroyedCalls == 0, "the friend's cart is not touched (carts are lane 74's)")
ok(friend[1].destroyedCalls == 0 and friend[3].destroyedCalls == 0, "the host's other items stay")
-- a stone heap used up on the host: removed on the friend with K2_DestroyActor (the class has no removeResource)
host[3].destroyed = true
run(21.05, 22.7)
ok(friend[3].destroyed and friend[6].destroyed, "a stone heap the host no longer has is destroyed on the friend (no removeResource in that class)")
-- changes only between the whole lists
lines = {}
t = 23.3; host[1].amt = 12; world.list = host; MH.tick(SH, 23.3)
local k = sentKinds()
ok(k.D == 1 and k.S == 0, "between the whole lists only the change goes out (FT D)")
deliver()
-- one call per actor
local f7 = item("FallenTreeBP_C", 40000, -40000, 5); f7.stays = true; friend[#friend + 1] = f7
run(23.35, 50)
ok(f7.removed == 1, "an item that still reads as there after its removal is asked once only (" .. f7.removed .. ")")
-- a friend that reloaded asks; the host sends the whole list at its next look
local MF2, CF2 = load("friend2")
t = 60; world.list = {}; MF2.tick({ role = "friend", eng = eng }, 60)
local asked = false; for _, l in ipairs(lines) do if l.line == "FT A" then asked = true end end
ok(asked, "a friend without the host's list asks for it (FT A)")
deliver(); lines = {}
world.list = host; MH.tick(SH, 60.3)
ok(sentKinds().S == 1, "... and the host sends the whole list at its next look")
lines = {}
-- this copy cannot tell a destroyed item: nothing removed
local MF3, CF3 = load("friend3")
local f3list = { item("FallenTreeBP_C", 5000, -6000, 3) }
tellFails = true
local function frame3(x) t = x; world.list = host; MH.tick(SH, x); for _, l in ipairs(lines) do local w = words(l.line); if l.from == "host" then MF3.onMessage(SF, "host", w[3], w, l.line) end end; lines = {}; world.list = f3list; MF3.tick(SF, x) end
CH.trees.wantAll = true
for i = 0, 60 do frame3(70 + i * 0.05) end
ok(f3list[1].destroyedCalls == 0, "a copy that cannot read bActorIsBeingDestroyed removes nothing")
tellFails = false
-- a join: nothing
CF.hold = true
local f8 = item("Resource_Stone_C", 30000, -30000, 4); friend[#friend + 1] = f8
run(80, 110)
ok(f8.destroyedCalls == 0, "nothing is removed during a join or resync")
CF.hold = nil
t = 300; world.list = friend; MF.tick(SF, 300)
ok(f8.destroyedCalls == 0, "with no host line for over 30 s nothing is removed")
-- (round 2, p88d) the same log lying elsewhere on this copy (after a load): moved to the host's place, then kept
local MF4, CF4 = load("friend4"); CF4.trees.on.pair = true   -- (off by default since p88e)
local hlog = item("FallenTreeBP_C", 106000, 77500, 1)
local flog = item("FallenTreeBP_C", 106500, 77800, 1)                       -- 5.8 m from the host's
flog.K2_SetActorLocation = nil
local moved
local mt = getmetatable(flog); local oldIndex = mt.__index
mt.__index = function(o, k) if k == "K2_SetActorLocation" then return function(self, v) moved = v; self.x, self.y = v.X, v.Y end end; return oldIndex(o, k) end
local hlist4, flist4 = { hlog }, { flog }
local SF4 = { role = "friend", eng = eng }
CH.trees.wantAll = true
local function frame4(x) t = x; world.list = hlist4; MH.tick(SH, x); for _, l in ipairs(lines) do local w = words(l.line); if l.from == "host" then MF4.onMessage(SF4, "host", w[3], w, l.line) end end; lines = {}; world.list = flist4; MF4.tick(SF4, x) end
for i = 0, 40 do frame4(400 + i * 0.25) end
ok(moved and math.abs(moved.X - 106000) < 1 and math.abs(moved.Y - 77500) < 1 and flog.destroyedCalls == 0, "a log lying 5.8 m from the host's (which this copy lacked) is moved to the host's place, not removed")
for i = 41, 140 do frame4(400 + i * 0.25) end
ok(flog.destroyedCalls == 0, "... and is kept afterwards (25 s later: matched, not 'never had')")
-- (round 3, p88f) a felled tree first seen while it falls (its place moves after first sight): read again, not kept
local MF6, CF6 = load("friend6")
local hT = item("FallenTreeBP_C", 300800, 40000, 15)                         -- the host's, fallen
local fT = item("FallenTreeBP_C", 300000, 40000, 15)                         -- this copy's, 8 m off while it falls
local h6, f6 = { hT }, { fT }
local SF6 = { role = "friend", eng = eng }
CH.trees.wantAll = true
local function frame6(x) t = x; world.list = h6; MH.tick(SH, x); for _, l in ipairs(lines) do local w = words(l.line); if l.from == "host" then MF6.onMessage(SF6, "host", w[3], w, l.line) end end; lines = {}; world.list = f6; MF6.tick(SF6, x) end
frame6(800)
fT.x = 300800                                                                -- it has fallen: at the host's place
for i = 1, 120 do frame6(800 + i * 0.25) end
ok(fT.destroyedCalls == 0, "a felled tree first seen while falling is matched where it lies once fallen, not removed")
-- (round 7, the l88o crash) the host's game places a site over a felled tree and clears it: the host sends it "gone
-- under a site"; the friend leaves its tree for 10 s (its own placement of the site clears it), then removes it as before
local MF9, CF9 = load("friend9")
local engS = { IsValid = function() return true end, buildingArr = {} }
local SH9 = { role = "host", eng = engS }
local hT9 = item("FallenTreeBP_C", 900000, -90000, 6)
local fT9 = item("FallenTreeBP_C", 900000, -90000, 6)
local h9, f9 = { hT9 }, { fT9 }
local SF9 = { role = "friend", eng = eng }
CH.trees.wantAll = true
local function frame9(x) t = x; world.list = h9; MH.tick(SH9, x); for _, l in ipairs(lines) do local w = words(l.line); if l.from == "host" then MF9.onMessage(SF9, "host", w[3], w, l.line) end end; lines = {}; world.list = f9; MF9.tick(SF9, x) end
for i = 0, 8 do frame9(1200 + i * 0.25) end
-- the host's game places a site 5 m off and clears the tree there
local site = { IsValid = function() return true end, IsConstructed = function() return false end, GetAddress = function() return 0x777000 end,
  K2_GetActorLocation = function() return { X = 900500, Y = -90000, Z = 0 } end }
engS.buildingArr = { site }; hT9.destroyed = true
local sentSite = false
local oldSend = CH.api.send
CH.api.send = function(line) if line:find("=-S", 1, true) then sentSite = true end; oldSend(line) end
for i = 9, 40 do frame9(1200 + i * 0.25) end                                -- 8 s
CH.api.send = oldSend
ok(sentSite, "the host sends the tree as gone under a new site (=-S)")
ok(fT9.destroyedCalls == 0, "the friend leaves its tree for its own placement of the site (8 s: not removed)")
for i = 41, 60 do frame9(1200 + i * 0.25) end                               -- 13 s
ok(fT9.destroyedCalls == 1, "... and removes it as before when its site has not cleared it after 10 s")
-- a tree cut up next to an OLD site (seen at the host's earlier looks) is removed at once as before
local MF10 = load("friend10")
local hT10 = item("FallenTreeBP_C", 950000, -90000, 6); local fT10 = item("FallenTreeBP_C", 950000, -90000, 6)
local old = { IsValid = function() return true end, IsConstructed = function() return false end, GetAddress = function() return 0x888000 end,
  K2_GetActorLocation = function() return { X = 950300, Y = -90000, Z = 0 } end }
engS.buildingArr = { old }
local h10, f10 = { hT10 }, { fT10 }
CH.trees.wantAll = true
local function frame10(x) t = x; world.list = h10; MH.tick(SH9, x); for _, l in ipairs(lines) do local w = words(l.line); if l.from == "host" then MF10.onMessage(SF9, "host", w[3], w, l.line) end end; lines = {}; world.list = f10; MF10.tick(SF9, x) end
for i = 0, 12 do frame10(1300 + i * 0.25) end
hT10.destroyed = true
for i = 13, 20 do frame10(1300 + i * 0.25) end
ok(fT10.destroyedCalls == 1, "a tree the host's villagers used up beside an OLD site goes on the friend 0.5 s later, as before")
print(string.format("ALL %d PASS", pass))
