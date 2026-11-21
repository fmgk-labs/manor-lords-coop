-- Desk test of the piles' fast path (lane 76, coop_facts.lua "PILES, fast"). Runs WITHOUT the game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_piles.lua mod/ManorLordsCoop/Scripts/coop_facts.lua
-- Session l76k: after a demolition a friend showed an EMPTY pile, a state the host never had: 3.4 s until the host's
-- stock was written into a new pile, and 2.6 s after the host's carriers had taken the last log.
local T = 500.0
os.clock = function() return T end
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
local logs, sent, mod = {}, {}, nil
local function live(o) return type(o) == "table" and o.live == true end
Coop = {
  register = function(name, m) if name == "facts" then mod = m end end, stale = function() return false end,
  api = { valid = live, un = function(o) return o end, now = os.clock, isPaused = function() return false end,
    btype = function(b) return b.type end,
    log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function(line) sent[#sent + 1] = line end }
}
assert(loadfile(ARG1))()
local F = Coop.facts
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 250 do
    local n, v = debug.getupvalue(fn, i)
    if not n then break end
    if n == name and v ~= nil then return v end
  end
  for i = 1, 250 do
    local n, v = debug.getupvalue(fn, i)
    if not n then break end
    if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
  end
end
local hostPiles = assert(upvalue(mod.tick, "hostPiles"), "hostPiles not found")
local friendPiles = assert(upvalue(mod.tick, "friendPiles"), "friendPiles not found")
local hostPassJob = assert(upvalue(mod.tick, "hostPassJob"), "hostPassJob not found")
local pilesStep = assert(upvalue(mod.tick, "pilesStep"), "pilesStep not found")
local onLine = assert(upvalue(mod.onMessage, "onLine"), "onLine not found")

local nextAddr = 0x30000
local function obj(o) nextAddr = nextAddr + 16; local a = nextAddr; o.live = true; o.GetAddress = function() return a end; return o end
local lord = obj({})
local region = obj({})
local function building(t, x, y, goods)
  local b = obj({ type = t, x = x, y = y, ownerPawn = lord, Region = region, Inventory = {}, onFire = false })
  for g, a in pairs(goods or {}) do b.Inventory[#b.Inventory + 1] = { Type = g, amt = a } end
  function b:GetType() return self.type end
  function b:K2_GetActorLocation() return { X = self.x, Y = self.y, Z = 0 } end
  function b:IsConstructed() return true end
  function b:isStorageTypeBuilding() return false end
  function b:isResidentialBuilding() return false end
  function b:addToInventory(r)
    for i, x in ipairs(self.Inventory) do
      if x.Type == r.Type then x.amt = x.amt + r.amt; if x.amt == 0 then table.remove(self.Inventory, i) end; return end
    end
    if r.amt ~= 0 then self.Inventory[#self.Inventory + 1] = { Type = r.Type, amt = r.amt } end
  end
  return b
end
local function clear(b) b.type = 0; b.x = 0; b.y = 0 end      -- what the game does to a removed building's actor
local function stock(b) local t = {}; for _, x in ipairs(b.Inventory) do t[#t + 1] = x.Type .. "=" .. x.amt end; table.sort(t); return table.concat(t, ",") end
local arr, S, gone
local function pass1()                                    -- one whole pass of the host over its list
  local st = {}; for _ = 1, 500 do if hostPassJob(st) then return end end
end
local function setup(role)
  arr = {}
  for i = 1, 30 do arr[i] = building(18, 1000 * i, 5000, { [16] = 3 }) end
  S = { role = role, worlds = 1, stats = {}, p1 = lord, eng = obj({ buildingArr = arr }) }
  gone = {}
  Coop.patch = { goodsAvail = function() return true end, pilegone = function(b) gone[#gone + 1] = b; for i = #arr, 1, -1 do if arr[i] == b then table.remove(arr, i) end end; clear(b); return true, "sent" end }
  Coop.goneB = nil
  F.S = S; F.world = 1; F.me = lord.GetAddress(); F.exact = role == "friend"; F.on.pileFast = true; F.on.stock = true
  F.host = { b = {}, a = {}, m = {} }; F.sent = {}; F.dirty = {}; F.pileGone = {}; F.catchMourning = {}; F.dumpSeen = {}; F.pileWant = {}; F.pileN = #arr; F.pileRetry = nil
  F.stats = {}; F.t = { miss = -1e9, index = T, piles = T, lineIn = T }; F.jobs = {}; F.refused = {}; F.holds = {}
  local list, map = {}, {}
  for _, b in ipairs(arr) do
    local k = string.format("%d@%d,%d", b.type, b.x / 10, b.y / 10)
    local e = { b = b, k = k, t = b.type, x = b.x / 10, y = b.y / 10, dump = false, store = false, res = false }
    list[#list + 1] = e; map[k] = e
  end
  F.idx = { list = list, map = map, store = {}, t = T, n = #arr, dumps = {}, lords = {} }
  F.hxAt = nil; F.on.exact = true
  if role == "host" then pass1() end                      -- the first pass sends every building complete
  sent = {}; logs = {}
end
local function line(body) onLine(S, { "1", "0", "F", "B", body }) end

-- ---- host
setup("host")
T = T + 0.07; hostPiles(S, T)
check(#sent == 0, "host: nothing changed, nothing sent")
local p = building(88, 7000, 5000, { [16] = 2 }); arr[#arr + 1] = p
T = T + 0.07; hostPiles(S, T)
check(#sent == 1 and sent[1] == "F B 88@700,500!|16=2", "host: a new pile's complete stock goes out in the tick it is seen (" .. tostring(sent[1]) .. ")")
sent = {}; T = T + 0.07; hostPiles(S, T)
check(#sent == 0, "host: and only once")
-- carriers take one log, then the last: no empty pile is ever sent
p.Inventory[1].amt = 1; T = T + 1.0; pass1()
check(#sent == 1 and sent[1] == "F B 88@700,500|16=1", "host: a pass sends the pile's change (" .. tostring(sent[1]) .. ")")
sent = {}; p.Inventory = {}; T = T + 1.0; pass1()
check(#sent == 0, "host: the emptied pile's zeros are NOT sent by the pass (was: 16=0, and the friend showed an empty pile)")
table.remove(arr); clear(p); T = T + 0.07; hostPiles(S, T)
check(#sent == 1 and sent[1] == "F B 88@700,500-", "host: the pile is gone: told in that tick (" .. tostring(sent[1]) .. ")")
sent = {}; T = T + 1.0; pass1(); hostPiles(S, T)
check(#sent == 0, "host: a cleared pile is not read or named again")
-- a pile that really stays empty is sent empty after 1.5 s
setup("host")
p = building(88, 7000, 5000, { [16] = 2 }); arr[#arr + 1] = p
T = T + 0.07; hostPiles(S, T); sent = {}
p.Inventory = {}; T = T + 1.0; pass1(); T = T + 1.0; pass1(); local early = #sent
T = T + 1.0; pass1()
check(early == 0 and #sent == 1 and sent[1] == "F B 88@700,500|16=0", "host: a pile that stays empty 1.5 s is sent empty after all (" .. tostring(sent[1]) .. ")")
-- a new pile read before its goods are in it is not sent empty
setup("host")
p = building(88, 7000, 5000, {}); arr[#arr + 1] = p
T = T + 0.07; hostPiles(S, T)
local n0 = #sent
p.Inventory[1] = { Type = 16, amt = 2 }; T = T + 0.07; hostPiles(S, T)
check(n0 == 0 and #sent == 1 and sent[1] == "F B 88@700,500!|16=2", "host: a new pile still empty is not sent; one tick later with its goods it is")
-- the number of buildings did not change (the building went as the pile came): a demolition mark makes the look
setup("host")
p = building(88, 7000, 5000, { [16] = 2 }); arr[30] = p
T = T + 0.07; hostPiles(S, T); n0 = #sent
Coop.goneB = { [1] = T }; T = T + 0.07; hostPiles(S, T)
check(n0 == 0 and #sent == 1, "host: same number of buildings: the pile is found because a demolition is under way")
-- the list was built again without the pile (it went while the list was built)
setup("host")
p = building(88, 7000, 5000, { [16] = 2 }); arr[#arr + 1] = p
T = T + 0.07; hostPiles(S, T); sent = {}
F.idx.map["88@700,500"] = nil; F.idx.dumps = {}; table.remove(arr); clear(p)
T = T + 0.07; hostPiles(S, T)
check(#sent == 1 and sent[1] == "F B 88@700,500-", "host: a sent pile that is no longer in a new list is told gone")

-- ---- friend
setup("friend")
p = building(88, 7000, 5000, {}); arr[#arr + 1] = p            -- this copy's pile, empty (the native switch holds it)
line("88@700,500!|16=2,13=1")
T = T + 0.07; friendPiles(S, T)
check(stock(p) == "13=1,16=2", "friend: the pile is in the game's list but not in this copy's: taken in and filled in the tick after the host's line (" .. stock(p) .. ")")
line("88@700,500|16=1")
T = T + 0.07; friendPiles(S, T)
check(stock(p) == "13=1,16=1", "friend: a change of the pile's stock is written in the next tick")
line("88@700,500-")
check(F.t.piles < 0, "friend: the host's pile is gone: the removal is due in the next tick")
pilesStep(S, T)
check(#gone == 1 and gone[1] == p, "friend: the pile is removed with its goods still in it (never shown empty)")
-- the host's line comes before this copy has the pile
setup("friend")
line("88@700,500!|16=2")
T = T + 0.07; friendPiles(S, T)
p = building(88, 7000, 5000, {}); arr[#arr + 1] = p
T = T + 0.07; friendPiles(S, T)
check(stock(p) == "16=2", "friend: the host's line came first: the pile is filled in the tick it appears")
-- this copy's pile comes first (its own player demolished): taken in at once, filled when the line comes
setup("friend")
p = building(88, 7000, 5000, {}); arr[#arr + 1] = p
T = T + 0.07; friendPiles(S, T)
check(F.idx.map["88@700,500"] ~= nil and stock(p) == "", "friend: its own new pile is taken into the list at once")
line("88@700,500!|16=2")
T = T + 0.07; friendPiles(S, T)
check(stock(p) == "16=2", "friend: and filled in the tick after the host's line")
-- its own new pile that holds goods (the native rule lets this copy's own game fill it) is registered at once
setup("friend"); F.regd = {}
p = building(88, 7000, 5000, { [17] = 4 }); arr[#arr + 1] = p
local writes = 0; local add0 = p.addToInventory
p.addToInventory = function(self, r) writes = writes + 1; if r.amt ~= 0 then add0(self, r) end end
T = T + 0.07; friendPiles(S, T)
check(writes == 1 and F.regd[p.GetAddress()] == true and stock(p) == "17=4", "friend: its own new pile with goods is registered in the tick it is seen (one write of amount 0), its goods stay")
T = T + 0.07; friendPiles(S, T)
check(writes == 1, "friend: and only once")
line("88@700,500!|17=3,16=2")
T = T + 0.07; friendPiles(S, T)
check(stock(p) == "16=2,17=3", "friend: the host's stock replaces its own in the tick after the host's line")
-- (task 76e round 2, session l7j) the host's line came first and the new pile already holds the host's goods: no write
-- of an amount is needed, and it is registered all the same (else this copy's carriers could take from it)
setup("friend"); F.regd = {}
line("88@700,500!|17=4")
p = building(88, 7000, 5000, { [17] = 4 }); arr[#arr + 1] = p
writes = 0; add0 = p.addToInventory
p.addToInventory = function(self, r) writes = writes + 1; if r.amt ~= 0 then add0(self, r) end end
T = T + 0.07; friendPiles(S, T)
check(writes == 1 and F.regd[p.GetAddress()] == true and stock(p) == "17=4", "friend: a new pile with the host's goods (the host's line first) is registered too (" .. writes .. " write)")
-- exact mode: every good of one building is written in one step of the pass (one good a tick showed a state the
-- host never had: two goods changed in one pass of the host)
setup("friend")
local friendPassJob = assert(upvalue(mod.tick, "friendPassJob"), "friendPassJob not found")
local w1, w2 = arr[3], arr[7]
line("18@300,500!|16=1,13=4,27=2;18@700,500!|16=5,13=1")
do
  local st = { quick = true }; local mixed, steps = 0, 0
  for _ = 1, 50 do
    local done = friendPassJob(st); steps = steps + 1
    local a1, a2 = stock(w1), stock(w2)
    if (a1 ~= "16=3" and a1 ~= "13=4,16=1,27=2") or (a2 ~= "16=3" and a2 ~= "13=1,16=5") then mixed = mixed + 1 end
    if done then break end
  end
  check(mixed == 0 and stock(w1) == "13=4,16=1,27=2" and stock(w2) == "13=1,16=5", "friend: after every step of the pass a building has its old stock or the host's complete stock, never a mix (" .. steps .. " steps)")
end
-- with the switch off nothing of this runs
setup("friend"); F.on.pileFast = false
p = building(88, 7000, 5000, {}); arr[#arr + 1] = p
line("88@700,500!|16=2")
check(next(F.pileWant) == nil, "switch off: a pile line is not marked (the old way: the passes)")
F.on.pileFast = true
-- (task 76h, session l76t) a building the game has taken away reads empty for a while: the host must not send
-- "every good 0" for it (a friend's copy of a rival's building stood emptied until the people module removed it)
setup("host")
pass1(); sent = {}
local taken = arr[7]; local takenKey = "18@" .. math.floor(taken.x / 10 + 0.5) .. "," .. math.floor(taken.y / 10 + 0.5)
taken.Inventory = {}; clear(taken)                        -- demolished: the actor is cleared, its handle still reads
T = T + 1.0; pass1()
local zeros = false
for _, line in ipairs(sent) do if line:find(takenKey .. "|16=0", 1, true) or line:find(takenKey .. "!|", 1, true) then zeros = true end end
check(not zeros and (F.stats.goneNotRead or 0) == 1, "a demolished building's cleared actor is not sent as 'every good 0' (goneNotRead " .. tostring(F.stats.goneNotRead) .. ")")
setup("host")
pass1(); sent = {}
local emptied = arr[9]; local emptiedKey = "18@" .. math.floor(emptied.x / 10 + 0.5) .. "," .. math.floor(emptied.y / 10 + 0.5)
emptied.Inventory = {}                                    -- a building that is still there and really empty now
T = T + 1.0; pass1()
zeros = false
for _, line in ipairs(sent) do if line:find(emptiedKey .. "|16=0", 1, true) then zeros = true end end
check(zeros and (F.stats.goneNotRead or 0) == 0, "a building that is still there and was emptied is sent with its good at 0, as before")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_piles failed") end
