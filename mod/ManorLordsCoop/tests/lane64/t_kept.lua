-- Desk test (lane 64, round 5): a watched building field never looks at a building handle kept from an earlier tick.
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane64/t_kept.lua mod/ManorLordsCoop/Scripts/coop_world.lua
-- Why: in the game a handle of a building that has been demolished and freed must not be touched at all. valid()
-- reads the freed memory too and has said "true" for a freed object; the call behind it ends the copy inside the mod
-- loader (lanes 35 and 47; the host of the pinned session l64pin4). Here the freed building counts every look at it,
-- and the stand-in for valid() says "true" for it: the worst case. The module must find the building's key gone
-- from the game's own list without one look at the old handle.
local t, rows, sent, mod = 0, {}, {}, nil
os.clock = function() return t end
math.type = math.type or function(n) return n == math.floor(n) and "integer" or "float" end
local freed, looks = {}, 0
local function live(o)
  if freed[o] then looks = looks + 1; return true end      -- valid() on freed memory: no proof, and here it lies
  return type(o) == "table" and o.live == true
end
Coop = {
  register = function(_, m) mod = m end, stale = function() return false end,
  api = { valid = live, un = function(o) return o end, now = os.clock, btype = function(b) return b.type end,
    log = function(fmt, ...) rows[#rows + 1] = string.format(fmt, ...) end,
    send = function(line) sent[#sent + 1] = line end }
}
assert(loadfile(ARG1))()
local check
for i = 1, 60 do local name, v = debug.getupvalue(mod.onMessage, i); if name == "Check" then check = v; break end end
assert(check and check.tick, "the check is not in the module")

local nextAddr = 0x20000
local function obj(o) nextAddr = nextAddr + 16; local a = nextAddr; o.live = true; o.GetAddress = function() return a end; return o end
local lord = obj({ silver = 100, influence = 5, kingsFavour = 0 })
local function building(typ, x, y, lv)
  return obj({ type = typ, ownerPawn = lord, lv = lv, onFire = false, sleep = false, Inventory = {}, workers = lv,
    K2_GetActorLocation = function() return { X = x * 10, Y = y * 10, Z = 0 } end, GetType = function(self) return self.type end,
    IsConstructed = function() return true end, getNumActiveWorkerFamilies = function(self) return self.workers end,
    getNumResidingFamilies = function() return 0 end })
end
-- the engine frees a building: from now on every look at the old handle is counted, and a call on it "ends the copy"
local function free(b)
  for k in pairs(b) do b[k] = nil end
  freed[b] = true
  setmetatable(b, { __index = function() looks = looks + 1; error("a freed building was touched") end })
end
local store, hut, barn = building(6, 100, 200, 1), building(89, 300, 400, 2), building(12, 500, 600, 3)
local weather = obj({ rainMeter = 0 })
local S = { role = "host", worlds = 1, stats = {}, ticks = 0, p1 = lord,
  eng = obj({ TemporalComponent = weather, regions = {}, buildingArr = { store, hut, barn } }) }
Coop.world.prepare(S); Coop.world.me = lord.GetAddress(); Coop.world.day = 41
if Coop.world.cfg then Coop.world.cfg.proof = false end

local passed, failed = 0, 0
local function ok(cond, what) if cond then passed = passed + 1; print("PASS  " .. what) else failed = failed + 1; print("FAIL  " .. what) end end
local ids = { "bl~89@300,400~lv", "B~89@300,400~workers", "bl~12@500,600~lv", "B~89@300,400~present" }
local function look()
  t = t + 1; sent = {}
  mod.onMessage(S, "friend1", "W", { "1", tostring(t), "W", "WATCH", "42", table.concat(ids, ";") })
  check.tick(S)
  local by = {}
  for _, line in ipairs(sent) do
    local items = line:match("^W OBS %S+ (.+)$")
    if items then for id, v in items:gmatch("([^;=]+)=([^;]+)") do by[id] = v end end
  end
  return by
end

t = 100
local a = look()
ok(a["bl~89@300,400~lv"] == "2" and a["B~89@300,400~workers"] == "2" and a["bl~12@500,600~lv"] == "3" and a["B~89@300,400~present"] == "1",
  "the first look finds the buildings in the game's list (lv 2, workers 2, lv 3, present)")
hut.lv = 4; hut.workers = 5
local b = look()
ok(b["bl~89@300,400~lv"] == "4" and b["B~89@300,400~workers"] == "5", "the next look reads the building's new values (lv 4, workers 5)")
local kept = Coop.world.wd.objects["89@300,400"]
ok(type(kept) ~= "table" and type(kept) ~= "userdata", "what is kept for the key between two looks is not a handle (it is " .. type(kept) .. ")")

-- the hut is demolished and freed; the barn moves up in the game's list
S.eng.buildingArr = { store, barn }; free(hut)
local c = look()
ok(looks == 0, "after the hut was freed: no look at its old handle (" .. looks .. " looks)")
ok(c["B~89@300,400~present"] == "0" and c["bl~12@500,600~lv"] == "3", "the freed hut reads as not there; the barn, moved up in the list, is still read (lv 3)")
-- a new building takes the hut's old place in the list: it is not taken for the hut
local mill = building(31, 700, 800, 7)
S.eng.buildingArr = { store, mill, barn }
ids[#ids + 1] = "bl~31@700,800~lv"
local d = look()
ok(looks == 0 and d["B~89@300,400~present"] == "0" and d["bl~31@700,800~lv"] == "7" and d["bl~12@500,600~lv"] == "3",
  "a new building at the hut's old place is not taken for the hut; it and the barn are read (lv 7, lv 3)")
-- the list shrinks below a kept place: nothing is read past its end
S.eng.buildingArr = { store }
local n0 = #S.eng.buildingArr
local e = look()
ok(#S.eng.buildingArr == n0 and e["bl~12@500,600~lv"] ~= "3", "a shorter list: nothing read past its end (" .. #S.eng.buildingArr .. " entries), the barn is gone")
-- the test switch's detector (link/dev_trace.txt, never in a player's game): it keeps handles as the old read did and
-- says when the old read would have used one of a building that is gone. It asks IsValid of it and makes no call.
Coop.traceF = {}; Coop.traceStale = true; Coop.trace = function() end
local shed = building(40, 900, 950, 1)
S.eng.buildingArr = { store, shed }; ids = { "bl~40@900,950~lv" }; t = t + 200      -- (the watches of above have run out: a watched key that misses makes the old read forget every kept handle)
look(); look()
S.eng.buildingArr = { store }; free(shed); looks = 0; rows = {}
look()
local said = table.concat(rows, " | ")
ok(looks == 2 and said:find("stale: the kept handle of 40@900,950", 1, true) ~= nil and said:find("IsValid says true", 1, true) ~= nil,
  "the detector names the stale use once, after its address and IsValid alone (" .. looks .. " looks at the freed stand-in: GetAddress, IsValid; no call made)")
rows = {}; look()
ok(not table.concat(rows, " | "):find("stale:", 1, true), "and not again: the old read would have kept this tick's handles after the miss")
local D = Coop.world.wd
ok((D.fixedUses or 0) > 0 and (D.fixedStale or 0) == 0, "the fixed read's own count under the switch: " .. tostring(D.fixedUses) .. " handles handed out, " .. tostring(D.fixedStale or 0) .. " not of this tick's list")
Coop.traceF = nil; Coop.traceStale = nil
print(string.format("RESULT: %d passed, %d failed", passed, failed))
if failed > 0 then error("t_kept failed") end
