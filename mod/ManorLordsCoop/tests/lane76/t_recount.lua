-- Desk test of the storage counters after an upgrade started on a friend (lane 76 task 76e, coop_facts.lua
-- F.recountSoon / F.recountUpgrading / recountStep). Runs WITHOUT the game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_recount.lua mod/ManorLordsCoop/Scripts/coop_facts.lua
-- Sessions l76w and l76y: a rival storehouse's numStoredGeneric stayed 127 and 161 (values the host never had) after
-- BeginUpgrade here, until this module's next write. A write of amount 0 recounts (the game's addToInventory).
local T = 500.0
os.clock = function() return T end
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
local logs, mod = {}, nil
local function live(o) return type(o) == "table" and o.live == true end
Coop = {
  register = function(name, m) if name == "facts" then mod = m end end, stale = function() return false end,
  api = { valid = live, un = function(o) return o end, now = os.clock, isPaused = function() return false end, btype = function(b) return b.type end,
    log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function() end }
}
assert(loadfile(ARG1))()
local F = Coop.facts
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 250 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name and v ~= nil then return v end end
  for i = 1, 250 do
    local n, v = debug.getupvalue(fn, i); if not n then break end
    if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
  end
end
local recountStep = assert(upvalue(mod.tick, "recountStep"), "recountStep not found")
local nextAddr = 0x40000
-- a building whose addToInventory recounts its counter from its goods (as the game's does), and counts the calls
local function building(goods, counter, upgrading)
  nextAddr = nextAddr + 16; local a = nextAddr
  local b = { live = true, goods = goods, numStoredGeneric = counter, isBeingUpgraded = upgrading or false, writes = {}, GetAddress = function() return a end }
  b.addToInventory = function(self, x)
    self.writes[#self.writes + 1] = x.Type .. ":" .. x.amt
    self.goods[x.Type] = (self.goods[x.Type] or 0) + x.amt
    local n = 0; for _, v in pairs(self.goods) do n = n + v end; self.numStoredGeneric = n
  end
  return b
end
local store = building({ [16] = 100, [17] = 25 }, 127)            -- the goods say 125, the counter 127 (l76w)
local other = building({ [16] = 3 }, 3)
local S = { role = "friend", worlds = 1, stats = {}, eng = { buildingArr = { store, other } } }
F.S = S; F.exact = true; F.stats = {}
check(F.recountSoon(store, 2.0) == true and store.numStoredGeneric == 125 and store.writes[1] == "16:0", "the upgrade's tick: a write of amount 0 recounts the counter at once (127 -> 125)")
check(store.goods[16] == 100 and store.goods[17] == 25, "no amount is changed")
store.numStoredGeneric = 126; T = T + 0.05; recountStep(S, T)     -- the game moves the counter again a frame later
check(store.numStoredGeneric == 125, "a tick later the counter is recounted again")
local n = #store.writes
T = T + 2.1; recountStep(S, T); T = T + 0.05; recountStep(S, T)
check(#store.writes == n + 0 and F.recountList[store.GetAddress()] == nil, "after 2 s the building is no longer written")
check(#other.writes == 0, "another building is not written")
-- a town action of the upgrade kind: every building being upgraded here is taken in for 2 s
local up = building({ [16] = 10 }, 12, true)
S.eng.buildingArr = { store, other, up }
check(F.recountUpgrading(2.0) == true, "the town module's call is taken")
T = T + 0.05; recountStep(S, T)
check(up.numStoredGeneric == 10 and #other.writes == 0 and #store.writes == n, "a building being upgraded is recounted; the others are not written")
-- not on the host, not outside exact mode
S.role = "host"; local host = building({ [16] = 1 }, 5)
check(F.recountSoon(host, 2.0) == false and #host.writes == 0, "the host writes nothing")
S.role = "friend"; F.exact = false; local off = building({ [16] = 1 }, 5)
check(F.recountSoon(off, 2.0) == false and #off.writes == 0, "outside exact mode nothing is written")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_recount failed") end
