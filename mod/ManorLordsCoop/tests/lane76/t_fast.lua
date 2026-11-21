-- Desk test of the stock path's fast ends (lane 76, task 76e, coop_facts.lua hostFast / friendFast / doOp). No game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_fast.lua mod/ManorLordsCoop/Scripts/coop_facts.lua
-- (the harness is t_piles.lua's)
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
local hostPassJob = assert(upvalue(mod.tick, "hostPassJob"), "hostPassJob not found")
local hostFast = assert(upvalue(mod.tick, "hostFast"), "hostFast not found")
local friendFast = assert(upvalue(mod.tick, "friendFast"), "friendFast not found")
local doOp = assert(upvalue(mod.tick, "doOp"), "doOp not found")
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
local arr, S
local CH
local function pass1() local st = {}; for _ = 1, 500 do if hostPassJob(st) then return end end end
local function setup(role)
  arr = {}
  for i = 1, 10 do arr[i] = building(18, 1000 * i, 5000, { [16] = 3 }) end
  S = { role = role, worlds = 1, stats = {}, p1 = lord, eng = obj({ buildingArr = arr }) }
  Coop.patch = { goodsAvail = function() return true end }
  Coop.snap = { takeChanged = function() local c = CH; CH = nil; return c end }
  F.S = S; F.world = 1; F.me = lord.GetAddress(); F.exact = role == "friend"; F.on.stock = true; F.on.exact = true
  F.host = { b = {}, a = {}, m = {} }; F.sent = {}; F.dirty = {}; F.catchMourning = {}; F.dumpSeen = {}; F.pileGone = {}
  F.stats = {}; F.t = { miss = -1e9, index = T, piles = T, lineIn = T }; F.jobs = {}; F.refused = {}; F.holds = {}
  local list, map = {}, {}
  for _, b in ipairs(arr) do
    local k = string.format("%d@%d,%d", b.type, b.x / 10, b.y / 10)
    local e = { b = b, k = k, t = b.type, x = b.x / 10, y = b.y / 10, dump = false, store = false, res = false }
    list[#list + 1] = e; map[k] = e
  end
  F.idx = { list = list, map = map, store = {}, t = T, n = #arr, dumps = {}, lords = {} }
  F.hxAt = nil
  if role == "host" then pass1() end
  sent = {}; logs = {}
end
local function line(body) onLine(S, { "1", "0", "F", "B", body }) end
-- host: a building whose native record changed goes out in that tick
setup("host")
arr[5].Inventory[1].amt = 4; CH = { [arr[5].GetAddress()] = true }
T = T + 0.02; hostFast(S, T)
check(#sent == 1 and sent[1] == "F B 18@500,500|16=4", "host: a changed building is sent in the tick its record changed (" .. tostring(sent[1]) .. ")")
sent = {}; T = T + 1; pass1()
check(#sent == 0, "host: the next pass does not send it again")
-- a running pass that has already read a building: its entry goes first, in the same line
arr[6].Inventory[1].amt = 5
local st = {}; F.jobs = { { name = "hostPass", st = st } }; for _ = 1, 8 do hostPassJob(st) end   -- the pass (a job) has read buildings 1 to 6 or so
check(st.entries and #st.entries == 1 and st.entries[1] == "18@600,500|16=5", "host: the running pass holds its entry of building 6")
arr[6].Inventory[1].amt = 6; CH = { [arr[6].GetAddress()] = true }
sent = {}; hostFast(S, T)
check(#sent == 1 and sent[1] == "F B 18@600,500|16=5;18@600,500|16=6", "host: the pass's older entry first, the new one after it, one line (" .. tostring(sent[1]) .. ")")
sent = {}; for _ = 1, 50 do if hostPassJob(st) then break end end
check(#sent == 0, "host: the pass's end sends nothing of it again")
-- a building never sent waits for the pass; not in exact mode nothing is sent at once
local nb = building(18, 20000, 5000, { [16] = 1 }); arr[#arr + 1] = nb
F.idx.list[#F.idx.list + 1] = { b = nb, k = "18@2000,500", t = 18, x = 2000, y = 500 }; F.idx.byAddr = nil
CH = { [nb.GetAddress()] = true }; sent = {}; hostFast(S, T)
check(#sent == 0, "host: a building never sent yet is left to the pass (it goes whole)")
F.cfg.fastHost = false; arr[5].Inventory[1].amt = 9; CH = { [arr[5].GetAddress()] = true }; sent = {}; hostFast(S, T)
check(#sent == 0, "host: switch fastHost off: nothing at once"); F.cfg.fastHost = true
-- friend: the host's line is written in the tick it came
setup("friend")
line("18@1000,500!|16=3"); line("18@200,500!|16=3")
friendFast(T); line("18@1000,500|16=7")
T = T + 0.01; friendFast(T)
check(stock(arr[10]) == "16=7", "friend: the building is written in the tick the host's line came (" .. stock(arr[10]) .. ")")
check(next(F.dirty) == nil, "friend: nothing left waiting")
-- a write planned with an older amount takes the host's amount as it stands
local e = F.idx.map["18@200,500"]
line("18@200,500|16=5")
doOp({ e = e, k = "18@200,500", g = 16, want = 4, d = 1, exact = true }, T)
check(stock(arr[2]) == "16=5", "friend: a write planned for 4 writes the host's newer 5 (" .. stock(arr[2]) .. ")")
-- (round 3) a building whose type changed in place (a rival's storehouse 72 becomes 99): renamed at once
setup("host")
arr[3].type = 19; CH = { [arr[3].GetAddress()] = true }; sent = {}
T = T + 0.02; hostFast(S, T)
check(#sent == 1 and sent[1] == "F B 18@300,500-;19@300,500!|16=3", "host: type changed in place: old name 'no longer sent' and the new name whole, one line, in that tick (" .. tostring(sent[1]) .. ")")
check(F.idx.map["19@300,500"] and F.idx.map["19@300,500"].b == arr[3] and F.idx.map["18@300,500"] == nil, "host: the list has the new name for that object")
sent = {}; T = T + 1; pass1()
check(#sent == 0, "host: the next pass sends neither name again (" .. tostring(sent[1]) .. ")")
setup("host")
arr[7].type = 19; sent = {}; T = T + 1; pass1()
check(#sent == 1 and sent[1] == "F B 18@700,500-;19@700,500!|16=3", "host: the pass (not only the fast path) renames at its read (" .. tostring(sent[1]) .. ")")
-- host: the fast path renames a building the RUNNING pass has already read: the pass's end must not send the new
-- name as "no longer sent" (nor forget it was sent)
setup("host")
local stR = {}; F.jobs = { { name = "hostPass", st = stR } }; for _ = 1, 8 do hostPassJob(stR) end   -- read 1 to 6 or so
arr[3].type = 19; CH = { [arr[3].GetAddress()] = true }; sent = {}; hostFast(S, T)
for _ = 1, 50 do if hostPassJob(stR) then break end end
local all = table.concat(sent, " ")
check(all:find("19@300,500!", 1, true) and not all:find("19@300,500-", 1, true) and F.sent["19@300,500"] ~= nil,
  "host: renamed by the fast path while a pass runs: the pass's end keeps the new name (" .. all .. ")")
F.jobs = {}
-- failure side, host: the new name is already another building's: nothing renamed (the rebuilt list decides)
setup("host")
local other = building(19, 4000, 5000, { [16] = 1 })
F.idx.map["19@400,500"] = { b = other, k = "19@400,500", t = 19, x = 400, y = 500 }
arr[4].type = 19; CH = { [arr[4].GetAddress()] = true }; sent = {}; hostFast(S, T)
check(F.idx.map["19@400,500"].b == other and not (sent[1] or ""):find("19@400,500!", 1, true), "host: a new name already taken is not renamed onto (" .. tostring(sent[1]) .. ")")
-- friend: the host names the new name; the list still has the old: found at its place, renamed, written in that tick
setup("friend")
arr[4].type = 19
line("19@400,500!|16=8"); T = T + 0.01; friendFast(T)
check(stock(arr[4]) == "16=8", "friend: the host's new name is found at its place under the old name and written at once (" .. stock(arr[4]) .. ")")
check(F.idx.map["19@400,500"] and F.idx.map["19@400,500"].b == arr[4] and F.idx.map["18@400,500"] == nil, "friend: the list has the new name")
-- failure side, friend: a building at that place whose own type is not the host's new type is never taken for it
setup("friend")
line("19@500,500!|16=8"); T = T + 0.01; friendFast(T)
check(stock(arr[5]) == "16=3" and F.idx.map["18@500,500"] ~= nil, "friend: a building of another type at that place is not written (" .. stock(arr[5]) .. ")")
-- friend: the host's new name came BEFORE this copy's own upgrade made the change (the people module's BeginUpgrade):
-- not taken while the object here is still the old type; renamed and written in the tick the upgrade starts here
setup("friend")
line("19@600,500!|16=9"); T = T + 0.01; friendFast(T)
check(stock(arr[6]) == "16=3" and F.idx.map["18@600,500"] ~= nil, "friend: the host's new name while the object here is still the old type: nothing written (" .. stock(arr[6]) .. ")")
arr[6].type = 19; F.recountSoon(arr[6], 2.0); friendFast(T)
check(stock(arr[6]) == "16=9" and F.idx.map["19@600,500"] and F.idx.map["19@600,500"].b == arr[6], "friend: its own upgrade starts (recountSoon): renamed and written in that tick (" .. stock(arr[6]) .. ")")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_fast failed") end
