-- Desk test (lane 64, task 64d: l64pin20's bw row, sitting l64d8): a new building in the facts module's list in the tick
-- the native table shows it (coop_facts.lua addNew, hostFast, friendTick). No game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane64/t_newb.lua mod/ManorLordsCoop/Scripts/coop_facts.lua
-- (the harness is lane 76's t_fast.lua's) Checked: the host sends a rival's new site whole, with its priority, in the
-- tick it shows up; a running pass's end does not call it "no longer sent"; a building of another owner is not taken and
-- is looked at once; the switch off: the list waits for its build as before; a friend writes the host's priority in the
-- tick its own new site shows up, when the host's line came first, and in the tick the line comes, when the site came
-- first; a name the list holds for a building that is gone is the new one's; two living buildings of one name: neither
-- is written (as the build of the list).
local T = 500.0
os.clock = function() return T end
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
local logs, sent, mod = {}, {}, nil
local function live(o) return type(o) == "table" and o.live == true end
Coop = {
  register = function(name, m) if name == "facts" then mod = m end end, stale = function() return false end,
  api = { valid = live, un = function(o) return o end, now = os.clock, isPaused = function() return false end,
    btype = function(b) return b.type end, pawns = function() return {} end,
    log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function(line) sent[#sent + 1] = line end }
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
local hostPassJob = assert(upvalue(mod.tick, "hostPassJob"), "hostPassJob not found")
local hostFast = assert(upvalue(mod.tick, "hostFast"), "hostFast not found")
local friendFast = assert(upvalue(mod.tick, "friendFast"), "friendFast not found")
local friendTick = assert(upvalue(mod.tick, "friendTick"), "friendTick not found")
local addNew = assert(upvalue(mod.tick, "addNew"), "addNew not found")
local onLine = assert(upvalue(mod.onMessage, "onLine"), "onLine not found")

local nextAddr = 0x30000
local function obj(o) nextAddr = nextAddr + 16; local a = nextAddr; o.live = true; o.GetAddress = function() return a end; return o end
local lord, rival, other = obj({}), obj({}), obj({})
local region = obj({})
local function building(t, x, y, owner, site, prio)
  local b = obj({ type = t, x = x, y = y, ownerPawn = owner, Region = region, Inventory = {}, onFire = false, buildPriority = prio or 4, site = site })
  b.Data = { constructed = not site }
  function b:GetType() return self.type end
  function b:K2_GetActorLocation() return { X = self.x, Y = self.y, Z = 0 } end
  function b:IsConstructed() return not self.site end
  function b:isStorageTypeBuilding() return false end
  function b:isResidentialBuilding() return false end
  function b:addToInventory(r) end
  return b
end
local arr, S, CH, recs
local function setup(role)
  arr = {}; recs = {}
  for i = 1, 6 do arr[i] = building(18, 1000 * i, 5000, lord) end
  S = { role = role, worlds = 1, stats = {}, p1 = lord, eng = obj({ buildingArr = arr }) }
  function S.eng:getDaysTotal() return 400 end
  Coop.patch = { fn = true, goodsAvail = function() return true end, goodsOn = function() return true end }
  Coop.snap = { takeChanged = function() local c = CH; CH = nil; return c end,
    building = function(a) return recs[a] end, obj = function(r) return r.b end }
  F.S = S; F.world = 1; F.me = lord.GetAddress(); F.exact = role == "friend"; F.on.stock = true; F.on.exact = true
  F.on.bar = false; F.on.newAtOnce = true; F.on.rivals = true; F.on.values = true
  F.host = { b = {}, a = {}, m = {} }; F.sent = {}; F.dirty = {}; F.catchMourning = {}; F.dumpSeen = {}; F.pileGone = {}
  F.stats = {}; F.jobs = {}; F.refused = {}; F.holds = {}; F.holdR = {}; F.made = {}; F.hostW = {}; F.hostD = {}; F.hostL = {}; F.recountList = {}
  F.t = { miss = -1e9, index = T, piles = T, lineIn = T, idxN = T, apply = T, dist = T, fam = T, live = T, lv = T, prune = T, quick = T, reg = T, wk = T, xSilent = 0, xTick = T }
  F.hostExact = role == "friend" or nil; F.regIdx = nil
  local list, map = {}, {}
  for _, b in ipairs(arr) do
    local k = string.format("%d@%d,%d", b.type, b.x / 10, b.y / 10)
    local e = { b = b, k = k, t = b.type, x = b.x / 10, y = b.y / 10, dump = false, store = false, res = false }
    list[#list + 1] = e; map[k] = e
  end
  F.idx = { list = list, map = map, store = {}, t = T, n = #arr, dumps = {}, lords = { [rival.GetAddress()] = true } }
  F.hxAt = nil
  sent = {}; logs = {}
end
local function newOne(t, x, y, owner, prio)            -- the game places a building: in its list and in the native table
  local b = building(t, x, y, owner, true, prio); arr[#arr + 1] = b
  recs[b.GetAddress()] = { a = b.GetAddress(), b = b }
  return b
end
local function hostLine(body) onLine(S, { "1", "0", "F", "B", body }) end
local function all() return table.concat(sent, " | ") end

-- 1. host: a rival's new site goes out whole, its priority with it, in the tick the native table shows it
setup("host")
local site = newOne(91, 92490, 74030, rival, 2)
CH = { [site.GetAddress()] = true }; T = T + 0.02; hostFast(S, T)
check(F.idx.map["91@9249,7403"] and F.idx.map["91@9249,7403"].rival and (F.stats.newAtOnce or 0) == 1, "host: the new site is in the list at once, as a rival's (newAtOnce 1)")
check(all():find("91@9249,7403!|", 1, true) and all():find("bp=2", 1, true), "host: its whole line goes in that tick, with its priority bp=2 (" .. all() .. ")")
sent = {}; T = T + 1; local st = {}; for _ = 1, 200 do if hostPassJob(st) then break end end
check(not all():find("91@9249,7403-", 1, true), "host: the next pass does not call it no longer sent (" .. all() .. ")")
-- 2. a pass that runs while the site comes: its end keeps the name
setup("host")
local stR = {}; F.jobs = { { name = "hostPass", st = stR } }; for _ = 1, 4 do hostPassJob(stR) end
local site2 = newOne(93, 92600, 74210, rival, 1)
CH = { [site2.GetAddress()] = true }; sent = {}; hostFast(S, T)
for _ = 1, 200 do if hostPassJob(stR) then break end end
check(all():find("93@9260,7421!|", 1, true) and not all():find("93@9260,7421-", 1, true) and F.sent["93@9260,7421"] ~= nil, "host: a pass running while the site comes: its end keeps the new name (" .. all() .. ")")
F.jobs = {}
-- 3. another owner's building: not taken, looked at once
setup("host")
local foreign = newOne(3, 50000, 60000, other)
CH = { [foreign.GetAddress()] = true }; sent = {}; hostFast(S, T)
check(F.idx.map["3@5000,6000"] == nil and #sent == 0 and F.idx.skip and F.idx.skip[foreign.GetAddress()] == 1, "host: a building of another owner is not taken (looked at once)")
for _ = 1, 4 do CH = { [foreign.GetAddress()] = true }; hostFast(S, T) end
check(F.idx.skip[foreign.GetAddress()] == 3 and #sent == 0, "host: ... looked at on three changes of its record, then not again (" .. tostring(F.idx.skip[foreign.GetAddress()]) .. ")")
-- 4. the switch off: the list waits for its build, as before
setup("host"); F.on.newAtOnce = false
local site3 = newOne(91, 92540, 74740, rival, 2)
CH = { [site3.GetAddress()] = true }; sent = {}; hostFast(S, T)
check(F.idx.map["91@9254,7474"] == nil and #sent == 0, "host: Coop.facts.on.newAtOnce = false: nothing at once")
F.on.newAtOnce = true

-- 5. friend: the host's line came first; the friend's own site shows up: written in that tick
setup("friend")
hostLine("91@9249,7403!|bp=2")
local fs = newOne(91, 92490, 74030, rival, 4)
CH = { [fs.GetAddress()] = true }; T = T + 0.02; friendTick(S, T)
check(F.idx.map["91@9249,7403"] and (F.stats.newFriend or 0) == 1, "friend: its new site is in the list at once (newFriend 1)")
check(fs.buildPriority == 2, "friend: the host's priority 2 written in the tick the site showed up (" .. tostring(fs.buildPriority) .. ")")
-- 6. friend: the site came first; the host's line comes: written in that tick
setup("friend")
local fs2 = newOne(93, 92600, 74210, rival, 4)
CH = { [fs2.GetAddress()] = true }; T = T + 0.02; friendTick(S, T)
hostLine("93@9260,7421!|bp=1"); T = T + 0.01; friendFast(T)
check(fs2.buildPriority == 1, "friend: the site first, the host's line after: written in the tick the line came (" .. tostring(fs2.buildPriority) .. ")")
-- 7. a name the list holds for a building that is gone: the new one takes it
setup("friend")
local oldB = building(91, 92490, 74030, rival, true, 4)
F.idx.map["91@9249,7403"] = { b = oldB, k = "91@9249,7403", t = 91, x = 9249, y = 7403, rival = true }
oldB.live = false
local fs3 = newOne(91, 92490, 74030, rival, 4)
CH = { [fs3.GetAddress()] = true }; friendTick(S, T)
check(F.idx.map["91@9249,7403"].b == fs3 and not F.idx.map["91@9249,7403"].dup, "a name held for a building that is gone: the new building takes it")
-- 8. two living buildings of one name: neither is written (as the build of the list)
setup("friend")
local twin = building(91, 92490, 74030, rival, true, 4)
F.idx.map["91@9249,7403"] = { b = twin, k = "91@9249,7403", t = 91, x = 9249, y = 7403, rival = true }
local fs4 = newOne(91, 92490, 74030, rival, 4)
hostLine("91@9249,7403!|bp=2")
CH = { [fs4.GetAddress()] = true }; T = T + 0.02; friendTick(S, T)
check(F.idx.map["91@9249,7403"].dup and fs4.buildPriority == 4 and twin.buildPriority == 4, "two living buildings of one name: both marked, neither written")
-- 9. lane 87's site entry with it (bar and wq on): the new site's first line, in its first tick, says "not finished"
--    (cn=0) and carries the work fraction of that tick (wq, from the values module's own poll of the tick)
setup("host"); F.on.bar = true; F.on.wq = true
Coop.values = { fracNow = function() return 1056964608 end }   -- (the bits of 0.5)
local site9 = newOne(91, 92320, 74380, rival, 3)
CH = { [site9.GetAddress()] = true }; sent = {}; T = T + 0.02; hostFast(S, T)
check(all():find("91@9232,7438!|", 1, true) and all():find("cn=0", 1, true) and all():find("wq=1056964608", 1, true) and all():find("bp=3", 1, true),
  "host, lane 87's bar on: the new site's first line has cn=0, the tick's work fraction and its priority (" .. all() .. ")")
Coop.values = nil; F.on.bar = false
print(string.format("RESULT: %d passed, %d failed", pass, fail))
return fail == 0
