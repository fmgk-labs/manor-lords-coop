-- (lane 83) Desk test of the time pie's own looks (coop_x_stats.lua hostTimeLook, friendTimeLook): lane 72's t_stats_desk.lua
-- setup (copied, lines 1-131), then: a host pie change goes out within a look (no pass over the buildings needed),
-- the friend writes it in the tick after, the friend's own work is set back within a look, nothing during a hold.
--   py -3 -I ../lane67/luacheck.py run t83_time.lua        (HERE = this folder)
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
deliver(F, H); tick(H, 4); deliver(H, F); tick(F, 6); deliver(F, H); tick(H, 3); deliver(H, F); tick(F, 4)   -- (as t_stats_desk: ask, digests, the host's lists in)
local function fine(X, n, dt) for _ = 1, n do clock = clock + (dt or 0.1); _G.Coop = X.C; X.M.tick(X.S, clock) end end
local hc, fc = H.b1.ProductionTrackerComponent, F.b1.ProductionTrackerComponent
local function pie(c) return table.concat(c:GetTimePercentagesForAllCategories(), ".") end
check(pie(hc) == pie(fc), "before: the friend's pie is the host's (" .. pie(fc) .. ")")

print("[the host: a pie change goes out within a look]")
H.C.stats.cfg.hostEvery = 1e9; F.C.stats.cfg.applyEvery = 1e9   -- the passes over the buildings never come again
fine(H, 3); H.sent = {}
hc.timeEntries[1].time = 40                                       -- 25 % -> 57 %
fine(H, 4)
local u = table.concat(H.sent, "\n"):match("ST U 40@100,200 [^\n]*")
check(u ~= nil, "host: ST U sent within 0.4 s of the change, with no pass over the buildings (" .. tostring(u) .. ")")

print("[the friend: written in the tick after it came]")
deliver(H, F); fine(F, 1)
check(pie(fc) == pie(hc) and fc.timeEntries[1].time == 40, "friend: the host's totals written in the next tick (" .. pie(fc) .. ")")

print("[the friend's own work: set back within a look]")
fc.timeEntries[2].time = fc.timeEntries[2].time + 60          -- this copy's own villagers worked
check(pie(fc) ~= pie(hc), "friend: its own work moved its pie (" .. pie(fc) .. ")")
fine(F, 4)
check(pie(fc) == pie(hc), "friend: the host's totals written back within 0.4 s (" .. pie(fc) .. ")")

print("[the foreign supply: the friend's own roll set back, without waiting for a pass over the buildings]")
local fms = F.S.eng.ForeignMarketSupply
check(fms[1] == H.S.eng.ForeignMarketSupply[1], "before: the friend's supply is the host's (" .. tostring(fms[1]) .. ")")
fms[1] = 9.5                                                     -- this copy's own daily roll
fine(F, 4)
check(fms[1] == H.S.eng.ForeignMarketSupply[1], "the friend's own roll is set back within 0.4 s with the passes held back (" .. tostring(fms[1]) .. ")")
print("[gates]")
F.C.hold = true; fc.timeEntries[2].time = fc.timeEntries[2].time + 60; local held = pie(fc)
fine(F, 6)
check(pie(fc) == held, "friend during a hold: its own pie left as it is (" .. pie(fc) .. ")")
F.C.hold = false; fine(F, 4)
check(pie(fc) == pie(hc), "friend after the hold: the host's again (" .. pie(fc) .. ")")
local line
for _, l in ipairs(F.logs) do if l:find("friend time", 1, true) then line = l end end
F.C.stats.cfg.logEvery = 0; fine(F, 1)
for _, l in ipairs(F.logs) do if l:find("friend time", 1, true) then line = l end end
check(line ~= nil, "the friend's status line names its time looks (" .. tostring(line and line:match("passes: [^|]*")) .. ")")
print("[a building seen after the first pass]")
local b2 = obj({ key = "117@974,646", ProductionTrackerComponent = tracker({}, { T(0, 0), T(5, 1) }), ExpertiseComponent = obj({ expertise = 0 }) })
H.S.eng.buildingArr[#H.S.eng.buildingArr + 1] = b2
H.C.stats.cfg.hostEvery = 1.0; H.sent = {}; fine(H, 40)
local u2 = table.concat(H.sent, "\n"):match("ST U 117@974,646 [^\n]*")
check(u2 ~= nil, "host: a building first seen after the world's first pass sends its time list at once (" .. tostring(u2) .. ")")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
