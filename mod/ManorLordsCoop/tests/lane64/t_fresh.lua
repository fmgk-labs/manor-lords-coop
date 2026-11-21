-- Desk test (lane 64, task 64d): handles of NO native table are never touched once their object is freed.
-- Runs WITHOUT the game (Lua 5.1 or 5.4):
--   py -3 -I research/2026-11-10-game-probe/lanes/lane_s21_64/tools/luarun.py <lua51.dll> mod/ManorLordsCoop/tests/lane64/t_fresh.lua <an empty folder to use>
-- It loads the real coop.lua, coop_snap.lua (N.aliveNow) and coop_x_jobs.lua (the resource index: findRes, and the
-- check of a task record's resource: refHere) with stand-ins. The native piece is a stand-in: its SNAP PROBE answer
-- (snap_probe.txt) is written from a made-up object array. A made-up object counts every look at it (IsValid, its
-- place) and "ends the game" (an error) when it is looked at after it was freed.
-- What it cannot show: the real native answer and the game's own freeing. Those are a game run's part.
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane64/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_fresh.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end
if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout); local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
end
if not math.tointeger then math.tointeger = function(x) x = tonumber(x); if x and x == math.floor(x) then return x end; return nil end end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
_G.COOP_LINK_DIR = dir
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.FindFirstOf = function() return { IsValid = function() return false end } end
_G.RegisterHook = function() return 1, 1 end
_G.NotifyOnNewObject = function() end
_G.Coop = nil
dofile(scripts .. "coop.lua")
local C = _G.Coop
C.start("idle", "idle", {}); C.stop()
local r = dofile(scripts .. "coop_snap.lua")
local N = C.snap
check(type(N) == "table" and type(N.aliveNow) == "function", "coop_snap.lua loads (" .. tostring(r) .. ") and has N.aliveNow")

-- the made-up engine: an object array (address -> alive there), and objects that count looks
local array, probes, sent, asked = {}, 0, {}, 0
local function obj(a, x, y)
  local o = { looks = 0, freed = false, x = x or 0, y = y or 0 }
  local function touch() o.looks = o.looks + 1; if o.freed then error("a freed object was touched: the game ends here") end end
  o.GetAddress = function() return a end                      -- the handle's own number: the object is not touched
  o.IsValid = function() touch(); return true end
  o.IsActorBeingDestroyed = function() touch(); return false end
  o.K2_GetActorLocation = function() touch(); return { X = o.x, Y = o.y, Z = 0 } end
  array[a] = true
  return o
end
local function free(o) o.freed = true; array[o.GetAddress()] = nil end
local answer = "array"
C.patch = { fn = true, dir = dir,
  send = function(line) sent[#sent + 1] = line end,
  tick = function()
    local line = sent[#sent]; local list = line and line:match("^SNAP PROBE (.+)$"); if not list then return end
    probes = probes + 1
    local f = assert(io.open(dir .. "snap_probe.txt", "wb"))
    if answer == "refused" then f:write("refused: not the known game build\r\n"); f:close(); return end
    f:write("uoa 00007FF600000000 objects=0000000000001000 max=1 num=1 maxchunks=1 numchunks=1\r\n")
    for tok in list:gmatch("[^,]+") do
      local a = tonumber(tok:sub(3), 16); asked = asked + 1
      if answer == "unreadable" then f:write(string.format("%X unreadable\r\n", a))
      else
        f:write(string.format("%X flags=00000000 idx=7 class=0000000000002000\r\n", a))
        f:write("   stride 16: obj=0000000000000001 other w8=0 wC=0 w10=0 w14=0\r\n")
        f:write(string.format("   stride 24: obj=%016X %s w8=0 wC=0 w10=0 w14=0\r\n", array[a] and a or 0, array[a] and "SAME" or "other"))
        f:write("   stride 32: obj=0000000000000002 other w8=0 wC=0 w10=0 w14=0\r\n")
      end
    end
    f:close()
  end }
C.s = C.s or {}; C.s.ticks = 100
local function tick() C.s.ticks = C.s.ticks + 1 end

-- 1. N.aliveNow itself
local a1, a2 = obj(0x2A000010), obj(0x2A000020)
N.uoaOk = false
local now = N.aliveNow({ 0x2A000010, 0x2A000020 })
check(now[0x2A000010] == nil and probes == 0, "before the native piece has checked the object array in this world: no look, no answer (valid() decides)")
N.uoaOk = true
now = N.aliveNow({ 0x2A000010, 0x2A000020 })
check(now[0x2A000010] == true and now[0x2A000020] == true and probes == 1 and a1.looks == 0 and a2.looks == 0, "two living addresses: one native look, both alive, neither object touched")
now = N.aliveNow({ 0x2A000010 })
check(now[0x2A000010] == true and probes == 1, "the same address again in the same tick: the answer of this tick, no second look")
free(a2); now = N.aliveNow({ 0x2A000020 })
check(now[0x2A000020] == true and probes == 1, "(within one tick the answer stands: the look is per tick, as the guard's)")
tick(); now = N.aliveNow({ 0x2A000010, 0x2A000020 })
check(now[0x2A000010] == true and now[0x2A000020] == false and probes == 2, "the next tick: looked at again; the freed one is false")
answer = "unreadable"; tick(); now = N.aliveNow({ 0x2A000010 })
check(now[0x2A000010] == false, "an address the native piece cannot read: false (never touched)")
answer = "refused"; tick(); now = N.aliveNow({ 0x2A000010 })
check(now[0x2A000010] == nil and (N.stats.aliveNoLook or 0) >= 1, "the look refused (another game build): no answer (nil): the caller decides with valid() as before")
answer = "array"; local P0 = C.patch; C.patch = nil; tick(); now = N.aliveNow({ 0x2A000010 })
check(now[0x2A000010] == nil, "no native piece: no answer")
C.patch = P0
N.test.goneOff = true; tick(); local p0 = probes; now = N.aliveNow({ 0x2A000010 })
check(now[0x2A000010] == nil and probes == p0, "the guard switched off (keptguard = off, Coop.snap.test.goneOff): no look, no answer, as before")
N.test.goneOff = nil
local many = {}; for i = 1, 160 do many[i] = 0x2B000000 + i * 16; obj(many[i]) end
tick(); p0 = probes; local a0 = asked; now = N.aliveNow(many)
local n150 = 0; for i = 1, 160 do if now[many[i]] == true then n150 = n150 + 1 end end
check(probes == p0 + 1 and asked - a0 == 150 and n150 == 150 and now[many[160]] == nil, "160 addresses: one look with 150 of them, the rest without an answer (valid() decides for them)")

-- 2. the job board's resource index (coop_x_jobs.lua findRes) and a task record's resource (refHere)
local res, fallen = {}, {}
_G.FindAllOf = function(cls)
  if cls == "Resource" then local t = {}; for _, o in ipairs(res) do if not o.freed then t[#t + 1] = o end end; return t end
  if cls == "FallenTreeBP_C" then local t = {}; for _, o in ipairs(fallen) do if not o.freed then t[#t + 1] = o end end; return t end
  return {}
end
local rj = dofile(scripts .. "coop_x_jobs.lua")
local J = C.jobs
check(type(J) == "table" and type(J.testFns) == "table" and type(J.testFns.findRes) == "function", "coop_x_jobs.lua loads (" .. tostring(rj) .. ") and hands findRes to the desk test")
local findRes, refHere = J.testFns.findRes, J.testFns.refHere
local berry = obj(0x2C000010, 1000, 2000); res[#res + 1] = berry
local stone = obj(0x2C000020, 1300, 2000); res[#res + 1] = stone
local tree = obj(0x2C000030, 4000, 2000); fallen[#fallen + 1] = tree; res[#res + 1] = tree
tick(); p0 = probes
local clock = 1000.0
local got = findRes("1000,2000,0", clock)
check(got == berry and probes == p0, "the first look builds the index in this tick and finds the berry bush at its place; no native look for an index of this tick")
tick(); p0 = probes; local lb = berry.looks
got = findRes("1000,2000,0", clock + 1)
check(got == berry and probes == p0 + 1, "a later tick: the candidates' addresses are looked up first (one native look), then the living one is used")
-- the berry bush is used up and freed; the index is younger than resIndexEvery, so it is not built again
free(berry); tick(); lb = berry.looks
local ok, v = pcall(findRes, "1000,2000,0", clock + 2)
check(ok and v ~= berry and berry.looks == lb, "the berry bush freed: it is never touched (" .. (berry.looks - lb) .. " looks); " .. (ok and ("the answer: " .. tostring(v == stone and "the stone 3 m away (cfg.resNear)" or v)) or ("ERROR " .. tostring(v))))
check(J.res and (function() for _, e in pairs(J.res) do if e.a == 0x2C000010 then return false end end; return true end)(), "the freed one has left the index")
-- the felled tree is cut up and freed
free(tree); tick(); local lt = tree.looks
ok, v = pcall(findRes, "4100,2000,0", clock + 3)
check(ok and tree.looks == lt, "the felled tree freed: never touched in the nearest-felled-tree look (" .. (tree.looks - lt) .. " looks)")
-- the control: with the look switched off (keptguard = off: the way before this change) a freed resource of the index
-- IS touched: the made-up object ends the game, as a freed one could in a real game
local bush1 = obj(0x2C000050, 9000, 2000); res[#res + 1] = bush1
J.res = nil; J.resT = nil; tick(); got = findRes("9000,2000,0", clock + 10)
check(got == bush1, "(control setup: the bush is in a new index)")
free(bush1); N.test.goneOff = true; tick(); local lc = bush1.looks
ok, v = pcall(findRes, "9000,2000,0", clock + 11)
check(bush1.looks > lc, "CONTROL, the look off (as before this change): the freed bush IS touched (" .. (bush1.looks - lc) .. " looks; valid()'s own pcall hides the made-up error, a real game would have ended)")
N.test.goneOff = nil
-- a new index after that
local bush2 = obj(0x2C000040, 7000, 2000); res[#res + 1] = bush2
J.res = nil; J.resT = nil; tick(); got = findRes("7000,2000,0", clock + 20)
check(got == bush2, "a new bush is found after the index is built again")
-- a task record's resource: refHere asks the object array before it touches the handle
tick(); local lr = bush2.looks
check(refHere("Resource", bush2) == true and bush2.looks > lr, "a task record's living resource: looked up, then checked as before (valid, not being destroyed)")
free(bush2); tick(); lr = bush2.looks
ok, v = pcall(refHere, "Resource", bush2)
check(ok and v == false and bush2.looks == lr, "a task record's freed resource: false, not touched (the record is dropped, nothing reaches the game)")

-- 2b. lane 74's J.cartMoved (the cart module moved a hand cart): the index keeps its records, the old entry is compared
-- by address only, and the moved cart is covered by the look like every other entry
local function key(x, y) return math.floor(x / 100 + 0.5) .. ":" .. math.floor(y / 100 + 0.5) end
local cart = obj(0x2D000010, 12000, 2000); res[#res + 1] = cart
local other = obj(0x2D000020, 15000, 2000); res[#res + 1] = other
J.res = nil; J.resT = nil; tick(); got = findRes("12000,2000,0", clock + 30)
check(got == cart and type(J.res[key(12000, 2000)]) == "table", "(setup: a hand cart in a new index, as a record)")
tick(); local lk = cart.looks
J.cartMoved(other, { X = 12000, Y = 2000, Z = 0 }, { X = 15000, Y = 2000, Z = 0 })
check(type(J.res[key(12000, 2000)]) == "table" and J.res[key(12000, 2000)].a == 0x2D000010 and cart.looks == lk, "a move named from a place whose entry is another object: that entry stays (compared by address; the kept handle in it not touched, " .. (cart.looks - lk) .. " looks)")
cart.x, cart.y = 13000, 2500; tick(); lk = cart.looks
J.cartMoved(cart, { X = 12000, Y = 2000, Z = 0 }, { X = 13000, Y = 2500, Z = 0 })
local ne = J.res[key(13000, 2500)]
check(J.res[key(12000, 2000)] == nil and type(ne) == "table" and ne.r == cart and ne.a == 0x2D000010 and ne.k == key(13000, 2500), "the cart moved: its old entry leaves the index, the new place holds a RECORD with the cart's address (not a bare handle)")
tick(); p0 = probes; got = findRes("13000,2500,0", clock + 31)
check(got == cart and probes == p0 + 1, "the moved cart is found at its new place after the native look (the index was not built again)")
free(cart); tick(); lk = cart.looks
ok, v = pcall(findRes, "13000,2500,0", clock + 32)
check(ok and cart.looks == lk and J.res[key(13000, 2500)] == nil, "the moved cart freed: never touched (" .. (cart.looks - lk) .. " looks), its record leaves the index")

-- 3. the board's units on the paused-loads line are checked first (no look at a unit's load after it left)
local src = io.open(scripts .. "coop_x_jobs.lua", "rb"):read("*a")
local n1 = select(2, src:gsub("if live%(e%.u%) then", ""))
check(n1 >= 2, "both once-per-pause loops over the board's units go through live(e.u) first (" .. n1 .. " places)")
-- 4. lane 74's cart module reads the board's kept records (a host task and a queued one) by address only: no valid()
-- on a handle kept past its tick (its named(): which carts a task names)
local fcs = io.open(scripts .. "coop_cart_stands.lua", "rb")
if fcs then
  local cs = fcs:read("*a"); fcs:close()
  local kept = select(2, cs:gsub("keptAddr%(e%.host%.rec%.Resource%)", "")) + select(2, cs:gsub("keptAddr%(e%.q%.rec%.Resource%)", ""))
  local touch = select(2, cs:gsub("[^t]addr%(e%.host%.rec%.Resource%)", "")) + select(2, cs:gsub("[^t]addr%(e%.q%.rec%.Resource%)", ""))
  check(kept == 2 and touch == 0, "the cart module's named() takes the board records' resources by address only (" .. kept .. " such reads, " .. touch .. " through valid())")
end

print(string.format("RESULT: %d passed, %d failed", pass, fail))
return fail == 0
