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
deliver(H, F)
-- ================================================================ lane 83: the grid carry's row hashes with "BAD" in one
-- (a block hash or row hash is 8 hex digits: ECBAD263 holds "BAD"; gridRows dropped such a line, so that block was never
-- answered and the friend's fertility stayed apart there: the lead's int5 check, two fields' rye 1 % lower)
print("[grid rows with BAD in a hash]")
local DIR = os.getenv("TEMP") .. "\\"
local rowsOf = {}             -- [copy] = 32 row hashes of block 29:6, as the fake native piece reports them
local function fakePatch(X, tag)
  local P = { dir = DIR .. tag .. "_", cmds = {}, fn = function() end }
  function P.send(l) P.cmds[#P.cmds + 1] = l end
  function P.tick()
    local l = P.cmds[#P.cmds]; if not l then return end
    local t = l:match("^HIST GRIDROWS %S+ (%S+) ")
    if t then local f = io.open(P.dir .. "hist_grows_" .. t .. ".txt", "w"); f:write("29 6 " .. table.concat(rowsOf[tag], " ") .. "\r\nEND\r\n"); f:close() end
    local tg = l:match("^HIST GRIDHASH %S+ (%S+) ")
    if tg then
      local f = io.open(P.dir .. "hist_grid_" .. tg .. ".txt", "w"); f:write("grid 1048576 cells side 1024 block 32 steps 0\r\n")
      for by = 0, 31 do local r = {}; for bx = 0, 31 do r[#r + 1] = (bx == 29 and by == 6) and (tag == "h" and "AAAAAAAA" or "BBBBBBBB") or "00000000" end; f:write(table.concat(r, " "), "\r\n") end
      f:write("capped 0\r\nEND\r\n"); f:close()
    end
  end
  X.C.patch = P; return P
end
local base = {}; for i = 1, 32 do base[i] = string.format("%08X", 0x10000000 + i) end
rowsOf.h = {}; rowsOf.f = {}; for i = 1, 32 do rowsOf.h[i] = base[i]; rowsOf.f[i] = base[i] end
rowsOf.h[4] = "ECBAD263"; rowsOf.f[4] = "DB798375"                  -- row 4 differs, and the host's hash holds "BAD"
H.S.eng.GetAddress = H.S.eng.GetAddress or function() return 0x1000 end
F.S.eng.GetAddress = F.S.eng.GetAddress or function() return 0x2000 end
fakePatch(H, "h"); fakePatch(F, "f")
-- the host gets a friend's ask for block 29:6 with the friend's row hashes
H.sent = {}
_G.Coop = H.C
local line = "ST GA 29:6 " .. table.concat(rowsOf.f, ",")
local w = { "1", "0" }; for x in line:gmatch("%S+") do w[#w + 1] = x end
H.M.onMessage(H.S, "friend1", "ST", w, line)
local gr = table.concat(H.sent, "\n"):match("ST GR 29:6 %x+")
check(gr ~= nil, "host: a friend's ask for a block whose own row hash holds BAD is answered (" .. tostring(gr) .. ")")
check(gr == "ST GR 29:6 8", "... with exactly the differing row (row 4 -> mask 8)")
-- the friend: its own row hashes hold BAD (swap): it still asks
rowsOf.f[4] = "ECBAD263"; rowsOf.h[4] = "DB798375"
F.sent = {}
_G.Coop = F.C
local gh = "ST GH " .. (6 * 32 + 29) .. "=AAAAAAAA"
local w2 = { "1", "0" }; for x in gh:gmatch("%S+") do w2[#w2 + 1] = x end
F.M.onMessage(F.S, "host", "ST", w2, gh)
F.C.stats.cfg.gridSettle = 0
for _ = 1, 4 do clock = clock + 1.1; F.M.tick(F.S, clock) end
local ga = table.concat(F.sent, "\n"):match("ST GA 29:6 [%x,]+")
check(ga ~= nil and ga:find("ECBAD263", 1, true) ~= nil, "friend: a block whose own row hash holds BAD is still asked for (" .. tostring(ga and ga:sub(1, 40)) .. ")")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
