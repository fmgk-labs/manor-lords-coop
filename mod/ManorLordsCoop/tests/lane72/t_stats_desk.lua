-- Lane 72 desk test of coop_x_stats.lua without the game: a stub core, reflection, buildings, regions and squads; the
-- module loaded twice (a host and a friend), the host's lines handed to the friend's onMessage.
--   py -3 -I luacheck.py run t_stats_desk.lua        (Lua 5.1 through ctypes; HERE = this folder)
-- Cases: no write during a hold or a world's first 5 s; digests that differ; lines out of order; a late line after a
-- load; a list whose size changed while growing and rebuilding are off; a squad whose men's order differs.
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
math.type = math.type or function(x) if type(x) ~= "number" then return nil end; return (x == math.floor(x)) and "integer" or "float" end
local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end

-- ---------------------------------------------------------------- reflection stubs (one game build for both copies)
local function nameObj(s) return { ToString = function() return s end } end
local function prop(name, kind, off, extra)
  local p = { n = name, k = kind, off = off or 0 }
  for k, v in pairs(extra or {}) do p[k] = v end
  p.GetFName = function() return nameObj(name) end
  p.GetClass = function() return { GetFName = function() return nameObj(kind) end } end
  p.GetOffset_Internal = function() return p.off end
  p.GetInner = function() return p.inner end
  p.GetStruct = function() return p.struct end
  return p
end
local function struct(name, props)
  return { GetFName = function() return nameObj(name) end, IsValid = function() return true end,
           ForEachProperty = function(self, fn) for _, p in ipairs(props) do fn(p) end end }
end
local TIME = struct("ProductionTimeEntry", { prop("time", "DoubleProperty", 0), prop("category", "ByteProperty", 24) })
local TRK = struct("ProductionTrackerEntry", { prop("amount", "IntProperty", 8), prop("day", "Int64Property", 0) })   -- given out of order: sorted by place
local EQ = struct("Equipment", { prop("bodyType", "IntProperty", 4), prop("wpnType", "IntProperty", 0) })
local REG = {
  ["/Script/ManorLords.ProductionTrackerComponent"] = struct("C", {
    prop("goodsLog", "MapProperty", 0xC8),                      -- (the real game's map is NOT reflected: a map here tests that path)
    prop("timeEntries", "ArrayProperty", 0x120, { inner = prop("x", "StructProperty", 0, { struct = TIME }) }) }),
  ["/Script/ManorLords.ProductionTrackerEntry"] = TRK,
  ["/Script/ManorLords.ProductionTimeEntry"] = TIME,
  ["/Script/ManorLords.ExpertiseComponent"] = struct("C", { prop("expertise", "FloatProperty", 0xB8) }),
  ["/Script/ManorLords.RTSMultiEngineCPP"] = struct("C", { prop("ForeignMarketSupply", "ArrayProperty", 0x1400, { inner = prop("x", "FloatProperty") }) }),
  ["/Script/ManorLords.Region"] = struct("C", { prop("price", "ArrayProperty", 0xE48, { inner = prop("x", "IntProperty") }) }),
  ["/Script/ManorLords.SMUnit"] = struct("C", { prop("Equipment", "StructProperty", 0x100, { struct = EQ }) }),
}
_G.StaticFindObject = function(path) return REG[path] end
_G.FName = function(s) return nameObj(s) end

-- ---------------------------------------------------------------- game object stubs
local nextAddr = 0x10000
local function obj(t) nextAddr = nextAddr + 0x100; local a = nextAddr; t.alive = true; t.GetAddress = function() return a end; return t end
-- a game list: a read one past its end adds an empty record (the UE4SS rule); Empty
local growths = 0
local function list(t, mk)
  return setmetatable(t, { __index = function(self, k)
    if k == "Empty" then return function(s) for i = #s, 1, -1 do rawset(s, i, nil) end end end
    if type(k) == "number" and k == #self + 1 then local r = mk(); rawset(self, k, r); growths = growths + 1; return r end
  end })
end
local function E(day, amount) return { day = day, amount = amount } end
local function T(time, cat) return { time = time, category = cat } end
local function trkList(t) return list(t, function() return E(0, 0) end) end
local function map(entries)                        -- good -> list of entries
  local m = { d = entries }
  function m:ForEach(fn) local ks = {}; for k in pairs(self.d) do ks[#ks + 1] = k end; table.sort(ks)
    for _, k in ipairs(ks) do local v = self.d[k]; fn({ get = function() return k end }, { get = function() return v end }) end end
  function m:Add(k) self.d[k] = trkList({}) end
  function m:Remove(k) self.d[k] = nil end
  return m
end
local function tracker(goods, times)
  local c = obj({ goodsLog = map(goods), timeEntries = list(times, function() return T(0, 0) end) })
  function c:GetTimePercentagesForAllCategories()
    local tot = 0; for _, e in ipairs(self.timeEntries) do tot = tot + e.time end
    local r = {}; for i, e in ipairs(self.timeEntries) do r[i] = tot > 0 and math.floor(e.time / tot * 100) or 0 end
    return r
  end
  function c:GetNumberOfGoodTypesInLog() local n = 0; for _ in pairs(self.goodsLog.d) do n = n + 1 end; return n end
  return c
end
local function man(morale, stamina, exp, wpn, body)
  local u = obj({ morale = morale, stamina = stamina, combatExperience = exp, Equipment = { wpnType = wpn, bodyType = body } })
  function u:SetVAMPVariationsToEquipment() self.redrawn = (self.redrawn or 0) + 1 end
  return u
end
local function copy(role, b1spec, men)
  local lord = obj({ commandedSquads = { { Value = 5 } } })
  function lord:getManors() return {} end
  local fam = { familyMembers = { men[1], men[2] } }
  local region = obj({ tag = "wirnitz", ownerPawn = lord, workerFamilies = { fam }, price = { 10, 12, 30 } })
  local b1 = obj({ key = "40@100,200", ProductionTrackerComponent = tracker(b1spec.goods, b1spec.times), ExpertiseComponent = obj({ expertise = b1spec.exp }) })
  local eng = obj({ buildingArr = { b1 }, regions = { region }, ForeignMarketSupply = b1spec.fms, basePrice = b1spec.base, TemporalComponent = { daysTotal = 7 } })
  local S = { role = role, name = role, eng = eng, p1 = lord, stats = {}, worldT = os.clock() - 100 }
  return { S = S, b1 = b1, region = region, men = men, sent = {}, mods = {}, logs = {} }
end

local function load(X)
  local C = { register = function(n, m) X.mods[n] = m end, hold = false }
  C.api = { valid = function(o) return o ~= nil and (type(o) ~= "table" or o.alive ~= false) end, un = function(x) return x end,
            send = function(l) X.sent[#X.sent + 1] = l end, log = function(fmt, ...) X.logs[#X.logs + 1] = string.format(fmt, ...) end,
            toLocal = function(h) return h end, toHost = function(h) return h end }
  C.world = { bkey = function(b) return b.key end, rkey = function(r) return r.tag end,
              regionByKey = function(k) for _, r in ipairs(X.S.eng.regions) do if r.tag == k then return r end end end }
  C.armyApi = { sqValid = function(h) return h == 5 end, unitsOf = function(h) return X.men end,
                sqState = function(h) return { mil = true, rs = 1, merc = false } end }
  C.s = X.S
  _G.Coop = C
  local chunk = assert(loadfile(HERE .. "../../Scripts/coop_x_stats.lua"))
  local r = chunk(); X.C = C; X.M = X.mods.stats
  return r
end

-- host and friend: the same building, its lists a little apart (each copy's own villagers)
local H = copy("host", { goods = { [3] = trkList({ E(1, 5), E(2, 5) }) }, times = { T(10, 0), T(30, 1) }, exp = 2.5, fms = { 1.5, 2.25 }, base = 4 },
  { man(80, 0.9, 3.2, 7, 164), man(60, 0.5, 1.1, 9, 293) })
local F = copy("friend", { goods = { [3] = trkList({ E(1, 5), E(2, 4) }), [8] = trkList({ E(2, 1) }) }, times = { T(12, 0), T(25, 1) }, exp = 1.0, fms = { 1.0, 2.0 }, base = 4 },
  { man(10, 0.1, 0.0, 1, 1), man(20, 0.2, 0.0, 2, 2) })          -- the men in another order and with their own values
print(load(H)); print(load(F))
local clock = 100
local function deliver(from, to, filter)
  local q = from.sent; from.sent = {}
  for _, l in ipairs(q) do
    local w = { "1", "0" }; for x in l:gmatch("%S+") do w[#w + 1] = x end
    if not filter or filter(l) then to.M.onMessage(to.S, from.S.role == "host" and "host" or "friend1", w[3], w, l) end
  end
  return q
end
local function tick(X, n) for _ = 1, n or 1 do clock = clock + 0.6; _G.Coop = X.C; X.M.tick(X.S, clock) end end
local function fl(X, g) local t = {}; local a = X.b1.ProductionTrackerComponent.goodsLog.d[g]; if not a then return "none" end; for i = 1, #a do t[i] = a[i].day .. ":" .. a[i].amount end; return table.concat(t, ",") end
local function snapshot() local c = F.b1.ProductionTrackerComponent; return table.concat({ fl(F, 3), fl(F, 8), c.timeEntries[1].time, c.timeEntries[2].time,
  F.b1.ExpertiseComponent.expertise, F.S.eng.ForeignMarketSupply[1], F.men[1].morale, F.men[1].Equipment.wpnType, F.men[1].combatExperience }, "|") end

H.M.onWorld(H.S); F.M.onWorld(F.S)
tick(H, 3)                                                      -- the host's first look at each building: noted, nothing sent for the lists
check(#H.sent > 0 and not table.concat(H.sent, "\n"):find("ST T ", 1, true), "host: a building seen first is only noted (no list lines)")
deliver(H, F)

print("[the gates]")
local before = snapshot()
F.S.worldT = os.clock() - 3.5                                   -- 3.5 s into the friend's world: it asks, but writes nothing
tick(F, 2)
check(table.concat(F.sent, "\n"):find("ST ASK ALL", 1, true) ~= nil, "friend 3 s into a world: ST ASK ALL sent")
deliver(F, H); tick(H, 4); deliver(H, F)
tick(F, 4)
check(snapshot() == before, "friend in its world's first 5 s: nothing written although the host's values are in")
F.S.worldT = os.clock() - 100; F.C.hold = true
tick(F, 4)
check(snapshot() == before, "friend during a hold (a resync): nothing written")
F.C.hold = false

print("[digests that differ]")
tick(F, 3); deliver(F, H)                                       -- the digest of good 3 differs: the friend asks for it
tick(H, 3); deliver(H, F); tick(F, 4)
check(fl(F, 3) == "1:5,2:5", "a list whose digest differed: asked for and written as the host's (" .. fl(F, 3) .. ")")
check(fl(F, 8) == "2:1", "a good only the friend's map has: kept while removing a key is off (" .. fl(F, 8) .. ")")
local ft = F.b1.ProductionTrackerComponent.timeEntries
local hp = table.concat(H.b1.ProductionTrackerComponent:GetTimePercentagesForAllCategories(), "."); local fp = table.concat(F.b1.ProductionTrackerComponent:GetTimePercentagesForAllCategories(), ".")
check(hp == fp and ft[1].time == 10 and ft[2].time == 30, "time pie: the host's totals written, the pie is the host's (" .. fp .. ")")
check(F.b1.ExpertiseComponent.expertise == 2.5, "expertise: the host's")
check(F.S.eng.ForeignMarketSupply[1] == 1.5 and F.S.eng.ForeignMarketSupply[2] == 2.25, "foreign supply: the host's")
check(F.region.price[3] == 30, "a region's prices: the host's")

print("[a squad whose men's order differs]")
local function mean(men, f) local s = 0; for _, u in ipairs(men) do s = s + u[f] end; return s / #men end
local function gear(men) local t = {}; for i, u in ipairs(men) do t[i] = u.Equipment.wpnType .. "/" .. u.Equipment.bodyType end; table.sort(t); return table.concat(t, ",") end
check(mean(F.men, "morale") == mean(H.men, "morale") and mean(F.men, "stamina") == mean(H.men, "stamina"), "morale and stamina: the squad's mean is the host's")
check(gear(F.men) == gear(H.men) and (F.men[1].redrawn or 0) > 0, "called-up militia's gear: the host's set of gear, redrawn (" .. gear(F.men) .. ")")
check(F.men[1].combatExperience == 3.2 and F.men[2].combatExperience == 1.1, "experience: by family place (ST X), not by squad place")
-- the host swaps its men's order: experience still goes by family place, never written twice per man
H.men[1], H.men[2] = H.men[2], H.men[1]; H.men[1].morale = 61
tick(H, 2); deliver(H, F); tick(F, 2)
check(F.men[1].combatExperience == 3.2 and F.men[2].combatExperience == 1.1, "after the host's order changed: each man's experience unchanged (one writer)")

print("[lines out of order]")
local g3 = H.b1.ProductionTrackerComponent.goodsLog.d[3]
rawset(g3, 3, E(3, 5)); tick(H, 2); local l1 = H.sent; H.sent = {}
rawset(g3, 4, E(4, 6)); tick(H, 2); local l2 = H.sent; H.sent = {}
H.sent = l2; deliver(H, F)                                      -- the later line first: a gap
check((F.M and F.C.stats.stats.t_gap or 0) >= 1, "a line whose earlier line is missing: not applied, counted as a gap")
H.sent = l1; deliver(H, F)
tick(F, 2); deliver(F, H)                                       -- the friend asks for the whole list
tick(H, 2); deliver(H, F)
local gr0 = growths
tick(F, 3)
check(fl(F, 3) == "1:5,2:5", "the host's list is longer while growing is off: the friend's list keeps its length (" .. fl(F, 3) .. ")")
check(growths == gr0 and (F.C.stats.stats.t_short or 0) > 0, "no list grown on the friend (counted as short)")
local f3 = F.b1.ProductionTrackerComponent.goodsLog.d[3]
rawset(f3, 3, E(3, 9)); rawset(f3, 4, E(4, 1))                  -- the friend's own game adds its two entries
tick(F, 3)
check(fl(F, 3) == "1:5,2:5,3:5,4:6", "the friend's own two entries then written over with the host's (" .. fl(F, 3) .. ")")
rawset(f3, 5, E(5, 2))                                          -- one more of the friend's own: longer than the host's
tick(F, 6)
check(fl(F, 3) == "1:5,2:5,3:5,4:6,5:2" and (F.C.stats.stats.t_ownKept or 0) > 0, "the friend's list is longer while rebuilding is off: the extra entry stays, counted")

print("[a late line after a load]")
F.M.onWorld(F.S); F.S.worldT = os.clock() - 100
local w0 = fl(F, 3)
rawset(g3, 5, E(5, 7)); tick(H, 2)
deliver(H, F, function(l) return l:find("ST T ", 1, true) ~= nil end)
tick(F, 2)
check(fl(F, 3) == w0, "a list line from before the friend's load (it continues a list it no longer holds): not written")
check(table.concat(F.sent, "\n"):find("ST ASK T 40@100,200|3", 1, true) ~= nil, "... the friend asks for the whole list instead")

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("desk test failed") end
