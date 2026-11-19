-- Manor Lords Co-op: the numbers a copy keeps a history of, or works out from its own play, on the host's word
-- (plug-in module "stats", message kind "ST", host -> friends; a friend sends only "ST ASK"). Lane 72, 2026-11-17.
-- Loaded from main.lua after the module list (it needs coop_world.lua's building and region keys).
--
-- Why (docs/coverage/values.tsv V020-V023, V093, V136-V138; VALUES_SUMMARY.md "Most likely wrong today" 3-6, 11, 15):
-- each of these values is kept by every copy for itself and moves with that copy's own villagers, traders and
-- soldiers. No module carried them, so a friend's panel showed its own numbers.
--
-- WHERE THE GAME KEEPS THEM (READ in the game file of a test copy with lane 14's dis.sh; offsets of 0.8.117)
--   ProductionTrackerComponent (one per building, SMBuildingMaster.ProductionTrackerComponent):
--     +0C8h  a map good type -> list of ProductionTrackerEntry: the goods made (getGoodsProducedOver walks it and keeps
--            the entries of the last N days by the day counter of the component's weather master, +118h -> +160h;
--            GetNumberOfGoodTypesInLog = the map's count). PROBABLY NOT REFLECTED: the game file's property names next
--            to the tracker's are DateCreated, OnNewTimeTracked, OnNewProductionAdded, weatherMasterPtr, timeEntries
--            (five, the count game_classes.txt gives) and none for the map. If so, the map part below stays idle
--            (Coop.stats.probe() says so on the first run) and item 1 needs a native item (lane 72 report).
--     +120h  timeEntries: ProductionTimeEntry, 30h bytes each, a double of time at +0: one entry per work category of
--            ProductionTrackerSettings (running totals, not one entry per event); the pie's percentages are worked
--            out again from it on every read (4bb3110: total at +130h, the per-cent list at +138h)
--   ExpertiseComponent: one float at +0B8h (GetExpertise truncates it; GetArtisanLevel finds its bracket)
--   SMUnit.morale, stamina, combatExperience, Equipment (dumps/SMUnit.txt): plain values per man
--   RTSMultiEngineCPP.ForeignMarketSupply and Region.price (dumps): reflected lists
--   NOT reachable from Lua (each needs a native item; research/2026-11-10-game-probe/lanes/lane_s21_72/report.txt):
--     ProductionSubsystem (the region's production and stock graphs) keeps its history in an UNREFLECTED list at
--       +38h (20h bytes a region: +0 a name, +8 the region, +10h the region's day records; read in OnRegionRenamed
--       4c46fd0). ASSUMED, not checked: the save carries it (MLSaveGame.productionLogs), so a join starts from the
--       host's history at the time of its save.
--     the fertility grid: an UNREFLECTED list of the engine at +8E0h (count +8E8h), 10h bytes a cell, 1024 cells a
--       row (redrawFertilitySlow 4cd6810: cell = x + 1024 y); fertilityGridUpdateRequests (+1018h) is the reflected
--       list of cells to draw again.
--   The names of the reflected properties and struct members are read at run time (ForEachProperty), never assumed.
--
-- THE RULE (the owner's: what a player sees is the host's within 3 s; a friend's copy decides nothing)
--   owner   the host. A friend never sends a value; it asks ("ST ASK ALL" 3 s into a world, "ST ASK T" for a list
--           whose lines it missed).
--   time    the host reads every building's time list once a second and sends it whole when the pie's whole per
--           cents change (as GetTimePercentagesForAllCategories gives them), and after an ASK ALL. A friend whose
--           pie differs from the host's writes the host's totals in place (its own work since is dropped).
--   map     (only when the map is reflected) the host looks at each good's list (count, first and last entry) and
--           sends what changed: new entries at the end, a drop at its front, or the list from the first entry that
--           differs. After an ASK ALL it sends a digest of every list (count and hash); the friend compares it with
--           its own (equal after a load of the host's save) and asks for those that differ. A friend writes the host's
--           entries in place. Growing a list, emptying and rebuilding it, adding or removing a key are switches that
--           stay OFF until Coop.stats.trial("grow") has shown on a test copy that a list reached through the map holds
--           its growth (else the map would point at freed memory: a crash no pcall can catch). With them off a friend's
--           own entry at a list's end stays until the host's next entry is written over it.
--   others  expertise, prices and supply, a man's morale / stamina / experience / gear: the host sends a value when
--           it changed (each with its own floor and tolerance below), all of them after an ASK ALL and every
--           cfg.keyEvery s; a friend writes the host's value whenever its own differs. A man's experience goes by
--           his family place (villagers, militia) or retinue place; a mercenary's is not carried.
--   gates   nothing is written while the mod holds the game (C.hold, a resync) and in a world's first 5 s.
--
-- Messages (after the core's "<seq> <clock> "; no field holds a space; numbers as %d / %.9g / %.17g):
--   ST SPEC <what> <hash> <member names>        what a list's entries hold (a friend of another build does not write)
--   ST T <bkey> <good> <n> <from> <e>;<e>;...   a good's list has n entries; these are entries from..; "-" none
--   ST C <bkey> <good> <d>                      the list lost its first d entries
--   ST U <bkey> <n> <pie> <i>=<e>;...           the time list (n entries) whole; pie = the host's per cents a.b.c
--   ST D <bkey> <good>=<n>:<hash>,...|<n>:<hash>   digest of every good's list | of the time list (after ASK ALL)
--   ST E <bkey>=<v>;...                         expertise
--   ST GONE <bkey>;...                          buildings that left the host's list (the friend drops what it holds)
--   ST GH / GA / GC                             the fertility grid's block hashes, a friend's ask, the host's rows
--   ST H <rkey> <d/m/y> <map> <good>=<n>;...    a region's day record (the region graphs)
--   ST M <key> <n> <i>=<v>;...                  FMS = eng.ForeignMarketSupply, BASE = eng.basePrice, <region tag> = its price list
--   ST Q <host squad> <n> <i>=<morale>,<stamina>;...   the men of a squad of the player's lord, by place in the squad
--                                               (experience goes by the man's family or retinue place: R and X; the men's
--                                               order in a squad may differ between copies)
--   ST G <host squad> <n> <i>=<m1>,<m2>,...;... a raised militia man's Equipment (members as SMUnit.Equipment names them)
--   ST R <manor bkey> <n> <i>=<experience>;...  the manor's retainers (getBoundRetinue order)
--   ST X <region tag> <F>.<M>=<experience>;...  a family member of the player's lord (family and member by place)
--   ST ASK ALL | ST ASK T <bkey>|<good>,...     friend -> host
-- Console: Coop.stats.status(), Coop.stats.probe() (the first-run reads: names, kinds, sizes), Coop.stats.trial(step),
-- Coop.stats.on.<item> = false.

local C = rawget(_G, "Coop")
if not (C and C.register and C.api) then return "coop_x_stats: load coop.lua first" end
local A = C.api
local un, valid = A.un, A.valid
local X = rawget(C, "stats") or {}; C.stats = X
X.version = "0.1"
X.stats = X.stats or {}
X.bytes = X.bytes or {}

local DEFAULT_ON = {
  trk = true,      -- items 1: the goods a building made (its tracker's map; runs only when the map is a reflected property:
                   --   the game file's names suggest it is NOT: see the header)
  time = true,     -- item 2: the time allocation pie (its tracker's time list)
  -- structural changes to a list inside the map, OFF until X.trial() has shown them on a test copy (a list reached
  -- through the map's value may be a copy of the list's header: growing it would leave the map pointing at freed
  -- memory, a crash no pcall can catch). Off: entries are only written in place, so a friend's own entry at a list's
  -- end stays until the host's next entry is written over it, and a list the host has longer waits for this copy's
  -- game to add one.
  grow = false,    -- append the host's missing entries (a read one past the end)
  rebuild = false, -- empty a list with entries of this copy's own and build it again as the host's (plain entries only)
  addKey = false,  -- a good the host's map has and this copy's has not: map Add
  removeKey = false, -- a good only this copy's map has: map Remove
  exp = true,      -- item 6: a building's expertise
  mkt = true,      -- item 4: foreign supply, base price, every region's prices
  men = true,      -- item 7: morale, stamina, experience of the player's squads
  gear = true,     -- item 7: a raised militia man's equipment
  ret = true,      -- item 7: retainers' experience
  fam = true,      -- item 6: a family member's experience (per worker)
}
local DEFAULT_CFG = {
  budgetMs = 1.0,   -- work per tick, host and friend each
  hostEvery = 1.0,  -- host: a pass over the buildings at most this often
  applyEvery = 0.5, -- friend: a pass over the host's values at most this often
  ownWait = 2.0,    -- friend: an entry of its own at a list's end waits this long for the host's
  expFloor = 1.0,   -- host: a building's expertise at most this often (it grows with every work hit)
  mktEvery = 2.0,   -- host: prices and supply this often
  menEvery = 0.5,   -- host: squads' men this often
  menTol = 0.01,    -- ... a change smaller than this (or 0.5 % of the value) is not sent
  gearSettle = 1.5, -- host: a man's equipment must hold this long before it is sent
  famEvery = 5.0,   -- host: family members' and retainers' experience this often
  keyEvery = 60.0,  -- host: every value but the lists again this often
  askAfter = 3.0,   -- friend: "ASK ALL" this long into a world
  maxLine = 3000,
  logEvery = 60.0,
}
X.on = X.on or {}; for k, v in pairs(DEFAULT_ON) do if X.on[k] == nil then X.on[k] = v end end
X.cfg = X.cfg or {}; for k, v in pairs(DEFAULT_CFG) do if X.cfg[k] == nil then X.cfg[k] = v end end
local cfg, on = X.cfg, X.on

local function log(fmt, ...) A.log("stats: " .. fmt, ...) end
local function bump(k, n) X.stats[k] = (X.stats[k] or 0) + (n or 1) end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); if ok then return a end end
local function hash(s) local h = 5381; for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end; return string.format("%x", h) end
local function sendL(sec, line) A.send(line); X.bytes[sec] = (X.bytes[sec] or 0) + #line + 12; bump("lines") end
-- lines under cfg.maxLine: head .. items joined by ";" (an empty list sends "-")
local function sendParts(sec, head, items)
  local buf, n = {}, #head
  for _, it in ipairs(items) do
    if #buf > 0 and n + #it + 1 > cfg.maxLine then sendL(sec, head .. table.concat(buf, ";")); buf, n = {}, #head end
    buf[#buf + 1] = it; n = n + #it + 1
  end
  sendL(sec, head .. (#buf > 0 and table.concat(buf, ";") or "-"))
end
local function W() return rawget(C, "world") end
local function bkey(b) local w = W(); if not (w and w.bkey) then return nil end; local ok, k = pcall(w.bkey, b); return ok and k or nil end
local function rkey(r) local w = W(); if not (w and w.rkey) then return nil end; local ok, k = pcall(w.rkey, r); return ok and k or nil end

-- ---------------------------------------------------------------- values and reflected members
local PLAIN = { IntProperty = "i", Int64Property = "i", UInt32Property = "i", UInt64Property = "i", Int16Property = "i", UInt16Property = "i",
                Int8Property = "i", ByteProperty = "i", EnumProperty = "i", BoolProperty = "b", FloatProperty = "f", DoubleProperty = "d",
                NameProperty = "n", ObjectProperty = "o", StructProperty = "s" }
local function kindOf(p) return p:GetClass():GetFName():ToString() end
-- a struct's members, nested structs flattened ("Date.day"): { list = { { path, k, name } }, plain = every member carried }
local function structFields(st, pre, out, depth, base)
  out = out or { list = {}, plain = true, skipped = {} }
  st:ForEachProperty(function(p)
    local n = p:GetFName():ToString(); local kn = kindOf(p); local k = PLAIN[kn]
    local okO, o = pcall(function() return p:GetOffset_Internal() end); local off = (base or 0) + ((okO and tonumber(o)) or 0)
    local path = {}; for i, x in ipairs(pre or {}) do path[i] = x end; path[#path + 1] = n
    if k == "s" and (depth or 0) < 3 then
      local okS, sub = pcall(function() return p:GetStruct() end)
      if okS and sub then structFields(sub, path, out, (depth or 0) + 1, off) else out.plain = false; out.skipped[#out.skipped + 1] = n .. ":" .. kn end
    elseif k and k ~= "s" then out.list[#out.list + 1] = { path = path, k = k, name = table.concat(path, "."), off = off }
    else out.plain = false; out.skipped[#out.skipped + 1] = n .. ":" .. kn end
  end)
  -- in the order of the members' places in the record (the order ForEachProperty gives is not promised)
  if not depth or depth == 0 then table.sort(out.list, function(a, b) if a.off ~= b.off then return a.off < b.off end; return a.name < b.name end) end
  local t = {}; for i, f in ipairs(out.list) do t[i] = f.name .. ":" .. f.k end
  out.spec = table.concat(t, ",")
  return out
end
local function fmtV(k, v)
  if k == "b" then return v and "1" or "0" end
  if k == "n" then local ok, s = pcall(function() return v:ToString() end); return ok and ((s:gsub("[%s,;|=]", "_"))) or "?" end
  if k == "o" then if not valid(v) then return "-" end; return ((bkey(v) or "?"):gsub(",", "/")) end
  if type(v) ~= "number" then return "?" end
  if v ~= v then return "nan" end
  if k == "i" or math.type(v) == "integer" then return string.format("%d", math.tointeger(v) or math.floor(v)) end
  if k == "f" then return string.format("%.9g", v) end
  return string.format("%.17g", v)
end
local function getPath(o, path) local v = o; for i = 1, #path do v = v[path[i]] end; return v end
local function setPath(o, path, v) for i = 1, #path - 1 do o = o[path[i]] end; o[path[#path]] = v end
-- one record as a string: its carried members, comma-separated
local function rec(r, F)
  local t = {}
  for i, f in ipairs(F.list) do local ok, v = pcall(getPath, r, f.path); t[i] = ok and fmtV(f.k, v) or "?" end
  return table.concat(t, ",")
end
local BYKEY = nil   -- this copy's buildings by key (filled where an object reference must be written back)
-- one record written from its string (only the members whose value here differs)
local function putRec(r, F, s, plainOnly)
  local i = 0
  for x in (s .. ","):gmatch("([^,]*),") do
    i = i + 1; local f = F.list[i]
    if f and x ~= "?" and x ~= "nan" and not (plainOnly and (f.k == "n" or f.k == "o")) then
      local ok, cur = pcall(getPath, r, f.path)
      if not ok or fmtV(f.k, cur) ~= x then
        local v
        if f.k == "b" then v = x == "1"
        elseif f.k == "n" then v = FName(x)
        elseif f.k == "o" then v = BYKEY and BYKEY[(x:gsub("/", ","))] or nil
        else v = tonumber(x) end
        if v ~= nil then pcall(setPath, r, f.path, v) end
      end
    end
  end
end

-- a class's own properties by name: { [name] = { kind, p } }
local function classProps(path)
  local t = {}
  pcall(function()
    local cls = StaticFindObject(path)
    if cls and cls:IsValid() then cls:ForEachProperty(function(p) t[p:GetFName():ToString()] = { kind = kindOf(p), p = p } end) end
  end)
  return t
end
local function structByPath(path)
  local ok, st = pcall(function() local s = StaticFindObject(path); if s and s:IsValid() then return s end end)
  return ok and st or nil
end
-- a reflected list's element: { num = <kind letter> } for numbers, { F = struct fields } for records
local function listElem(e)
  local ok, inner = pcall(function() return e.p:GetInner() end)
  if not (ok and inner) then return nil end
  local kn = kindOf(inner)
  if kn == "StructProperty" then local okS, st = pcall(function() return inner:GetStruct() end); if okS and st then return { F = structFields(st) } end; return nil end
  if PLAIN[kn] and PLAIN[kn] ~= "s" and PLAIN[kn] ~= "o" then return { num = PLAIN[kn] } end
  return nil
end
local function elemStr(E, v)
  if E.num then if type(v) ~= "number" and type(v) ~= "boolean" then local ok, g = pcall(function() return v:get() end); if ok then v = g end end; return fmtV(E.num, v) end
  return rec(v, E.F)
end

-- ---------------------------------------------------------------- the tracker's layout (learned once per world)
local L = nil
local function learn()
  if L then return L end
  L = { ok = false }
  local P = classProps("/Script/ManorLords.ProductionTrackerComponent")
  local names = {}
  for n, e in pairs(P) do
    names[#names + 1] = n .. ":" .. e.kind
    if e.kind == "MapProperty" then L.map = n
    elseif e.kind == "ArrayProperty" then
      local okI, sn = pcall(function() return e.p:GetInner():GetStruct():GetFName():ToString() end)
      if okI and sn == "ProductionTimeEntry" then L.time = n end
    end
  end
  table.sort(names); L.props = table.concat(names, " ")
  local te = structByPath("/Script/ManorLords.ProductionTrackerEntry")
  local ti = structByPath("/Script/ManorLords.ProductionTimeEntry")
  if te then L.TE = structFields(te); for _, f in ipairs(L.TE.list) do if f.k == "o" then L.TE.hasObj = true end end end
  if ti then L.TI = structFields(ti) end
  -- the time list is written in place only: its numbers (the category and any text stay as they are)
  -- (the pie reads only the time, a double: only top-level numbers are carried; the colour struct and the category
  --  enum are left as each copy has them, both are fixed per category)
  if L.TI then local t = { list = {}, plain = true }; for _, f in ipairs(L.TI.list) do if (f.k == "d" or f.k == "f") and #f.path == 1 then t.list[#t.list + 1] = f end end
    -- ti: the time member: the game reads a double at +0 of each entry (4bb3110); else the first number with a fraction
    local s = {}; for i, f in ipairs(t.list) do s[i] = f.name; if f.k == "d" and f.off == 0 then t.ti = i end end
    if not t.ti then for i, f in ipairs(t.list) do if not t.ti and (f.k == "d" or f.k == "f") then t.ti = i end end end
    t.spec = table.concat(s, ","); L.TIw = t end
  local EP = classProps("/Script/ManorLords.ExpertiseComponent")
  for n, e in pairs(EP) do if e.kind == "FloatProperty" or e.kind == "DoubleProperty" then L.exp = n end end
  local ER = classProps("/Script/ManorLords.RTSMultiEngineCPP")
  if ER.ForeignMarketSupply then L.FMS = listElem(ER.ForeignMarketSupply) end
  local RR = classProps("/Script/ManorLords.Region")
  if RR.price then L.PRICE = listElem(RR.price) end
  -- Equipment's members (as coop_x_army reads them for the rally set)
  local UR = classProps("/Script/ManorLords.SMUnit")
  if UR.Equipment then local okS, st = pcall(function() return UR.Equipment.p:GetStruct() end); if okS and st then L.EQ = structFields(st) end end
  L.specT = L.TE and ("m=" .. tostring(L.map) .. ":" .. L.TE.spec) or nil
  L.specU = L.TIw and ("t=" .. tostring(L.time) .. ":" .. L.TIw.spec) or nil
  L.ok = (L.map and L.TE) and true or false
  log("tracker map %s (entry %s%s), time list %s (%s), expertise %s, supply %s, price %s, equipment %d members; tracker properties: %s",
    tostring(L.map), L.TE and L.TE.spec or "?", (L.TE and not L.TE.plain) and (" NOT PLAIN: " .. table.concat(L.TE.skipped, " ")) or "",
    tostring(L.time), L.TIw and L.TIw.spec or "?", tostring(L.exp), L.FMS and (L.FMS.num or ("record " .. L.FMS.F.spec)) or "?",
    L.PRICE and (L.PRICE.num or ("record " .. L.PRICE.F.spec)) or "?", L.EQ and #L.EQ.list or 0, L.props)
  return L
end

-- ---------------------------------------------------------------- this copy's buildings
-- the list of buildings with their keys, made again every 10 s or when the count changes; an object is taken from the
-- engine's list anew at every use and its address compared (a handle is never kept across frames)
local IX = nil
local function index(S, force)
  local now = os.clock()
  local okN, n = pcall(function() return #S.eng.buildingArr end); if not okN then return nil end
  if IX and not force and IX.n == n and now - IX.t < 10.0 then return IX end
  local by, list = {}, {}
  pcall(function()
    local arr = S.eng.buildingArr; local m = #arr
    for i = 1, m do
      local b = un(arr[i])
      if valid(b) then local k = bkey(b); local a = addr(b); if k and a then if by[k] then k = k .. "#" .. i end; by[k] = { i = i, a = a }; list[#list + 1] = k end end
    end
  end)
  IX = { n = n, t = now, by = by, list = list }
  return IX
end
local function bObj(S, k)
  local I = IX and IX.by[k]; if not I then return nil end
  local ok, b = pcall(function() local arr = S.eng.buildingArr; if I.i > #arr then return nil end; return un(arr[I.i]) end)
  if ok and b and valid(b) and addr(b) == I.a then return b end
  return nil
end
local function byKey(S)            -- for an object member of a record (rare)
  local t = {}; local I = index(S); if not I then return t end
  for k in pairs(I.by) do local b = bObj(S, k); if b then t[k] = b end end
  return t
end
local function comp(b, name) local ok, c = pcall(function() return b[name] end); if ok and c and valid(c) then return c end end

-- ---------------------------------------------------------------- host: the tracker
-- HT[bkey] = { g = { [good] = { list of entry strings } }, t = { time entry strings } }   what the friends have been sent
local HT = X.HT or {}; X.HT = HT
local function readList(arr, F, from, to) local t = {}; for i = from, to do local ok, s = pcall(rec, arr[i], F); t[#t + 1] = ok and s or "?" end; return t end
-- the pie's numbers from a time list: each entry's share in whole per cent (the game: entry / total x 100, cut off)
local function pctOf(list)
  if not (L.TIw and L.TIw.ti) then return "" end
  local v, tot = {}, 0
  for i, s in ipairs(list) do local x = 0; local j = 0; for p in (s .. ","):gmatch("([^,]*),") do j = j + 1; if j == L.TIw.ti then x = tonumber(p) or 0 end end; v[i] = x; tot = tot + x end
  local t = {}; for i, x in ipairs(v) do t[i] = tot > 0 and string.format("%d", math.floor(x / tot * 100)) or "0" end
  return table.concat(t, ".")
end
-- the pie's numbers as the game draws them (GetTimePercentagesForAllCategories, the game's own single-float sums),
-- "a.b.c"; nil when the call fails (then pctOf on the totals stands in)
local function gamePct(c)
  local ok, s = pcall(function()
    local a = c:GetTimePercentagesForAllCategories(); local t = {}
    for i = 1, #a do local v = a[i]; if type(v) ~= "number" then v = v:get() end; t[i] = string.format("%d", math.floor(v)) end
    return table.concat(t, ".")
  end)
  return ok and s or nil
end
-- A building seen for the first time (a world's first pass, or the role became host later, or a new building) is only
-- noted: what it holds then is the save's, which a friend that loads has too; a friend that asks gets digests.
local function hostTrkB(S, k, b, digest)
  local c = comp(b, "ProductionTrackerComponent"); if not c then return end
  local R = HT[k]; local prime = false
  if not R then R = { g = {}, t = nil }; HT[k] = R; prime = true end
  if on.trk and L.map then
    local seen = {}
    pcall(function()
      c[L.map]:ForEach(function(kk, vv)
        local g = kk:get(); local arr = vv:get(); local n = #arr
        seen[g] = true
        local E = R.g[g]
        if prime then R.g[g] = readList(arr, L.TE, 1, n); return end
        local from
        if E and n > 0 and #E > 0 and rec(arr[1], L.TE) ~= E[1] then
          -- cut at its front (the game keeps the last days only): the same entries further up = a drop, else whole
          local first = rec(arr[1], L.TE); local drop
          for d = 1, math.min(8, #E - 1) do if E[d + 1] == first then drop = d; break end end
          if drop then for _ = 1, drop do table.remove(E, 1) end; sendL("trk", string.format("ST C %s %d %d", k, g, drop)); bump("t_drop")
          else from = 1 end
        end
        if not E then from = 1
        elseif not from then
          -- the common case: entries added at the end, or the last one grew (both: read back to the first that equals)
          local m = math.min(n, #E); local i = m
          while i >= 1 and rec(arr[i], L.TE) ~= E[i] do i = i - 1 end
          if i < m or n ~= #E then from = i + 1 end
        end
        if from then
          local part = (from <= n) and readList(arr, L.TE, from, n) or {}
          E = E or {}; for j = #E, n + 1, -1 do E[j] = nil end
          for j, s in ipairs(part) do E[from + j - 1] = s end
          R.g[g] = E
          sendParts("trk", string.format("ST T %s %d %d %d ", k, g, n, math.min(from, n + 1)), part); bump("t_sent", #part)
        end
      end)
    end)
    for g in pairs(R.g) do if not seen[g] then R.g[g] = nil; if not prime then sendL("trk", string.format("ST T %s %d -1 1 -", k, g)) end end end   -- -1: the key is gone
  end
  if on.time and L.time and L.TIw then
    pcall(function()
      local arr = c[L.time]; local n = #arr
      local cur = readList(arr, L.TIw, 1, n)
      -- sent when the pie's whole per cents change (the totals grow with every second of work: sending each change
      -- would cost a line a second per workplace) and after an ASK ALL
      local p = gamePct(c) or pctOf(cur)
      if prime then R.t = cur; R.tp = p; return end
      if digest or p ~= R.tp or not R.t or #R.t ~= n then
        local ch = {}; for i = 1, n do ch[#ch + 1] = i .. "=" .. cur[i] end
        R.t = cur; R.tp = p; sendParts("time", string.format("ST U %s %d %s ", k, n, p ~= "" and p or "-"), ch); bump("u_sent")
      end
    end)
  end
  if digest then
    local d = {}
    for g, E in pairs(R.g) do d[#d + 1] = string.format("%d=%d:%s", g, #E, hash(table.concat(E, ";"))) end
    table.sort(d)
    sendL("trk", string.format("ST D %s %s|%s", k, #d > 0 and table.concat(d, ",") or "-", R.t and (#R.t .. ":" .. hash(table.concat(R.t, ";"))) or "-"))
  end
end

-- ---------------------------------------------------------------- host: expertise
local HE = X.HE or {}; X.HE = HE      -- [bkey] = { v, t }
local function hostExpB(S, k, b, clock, out, full)
  if not (on.exp and L.exp) then return end
  local c = comp(b, "ExpertiseComponent"); if not c then return end
  local ok, v = pcall(function() return c[L.exp] end); if not (ok and type(v) == "number") then return end
  local E = HE[k]
  -- sent when its whole number changes (what GetExpertise gives and the artisan level's bracket reads) or it moved by
  -- a tenth, at most every cfg.expFloor s; it grows a little with every work hit
  if full or not E or math.floor(E.v) ~= math.floor(v) or (math.abs(E.v - v) >= 0.1 and clock - E.t >= cfg.expFloor) then
    if v ~= 0 or (E and E.v ~= 0) then out[#out + 1] = k .. "=" .. fmtV("f", v) end   -- a building that never had any: not sent
    HE[k] = { v = v, t = clock }
  end
end

-- ---------------------------------------------------------------- host: prices and supply
local HM = X.HM or {}; X.HM = HM      -- [key] = { strings }
local function hostList(key, arr, E, full)
  local n = #arr; local cur = {}
  for i = 1, n do local ok, s = pcall(elemStr, E, arr[i]); cur[i] = ok and s or "?" end
  local old = HM[key]; local ch = {}
  for i = 1, n do if full or not old or #old ~= n or old[i] ~= cur[i] then ch[#ch + 1] = i .. "=" .. cur[i] end end
  if #ch > 0 then HM[key] = cur; sendParts("mkt", string.format("ST M %s %d ", key, n), ch) end
end
local function hostMkt(S, full)
  if not on.mkt then return end
  if L.FMS then pcall(function() hostList("FMS", S.eng.ForeignMarketSupply, L.FMS, full) end) end
  pcall(function()
    local v = S.eng.basePrice; local s = fmtV("f", v)
    if full or not HM.BASE or HM.BASE[1] ~= s then HM.BASE = { s }; sendL("mkt", "ST M BASE 1 1=" .. s) end
  end)
  if L.PRICE then
    local regs = S.eng.regions
    for i = 1, #regs do local r = un(regs[i]); if valid(r) then local rk = rkey(r); if rk then pcall(function() hostList(rk, r.price, L.PRICE, full) end) end end end
  end
end

-- ---------------------------------------------------------------- host: men, retinue, families
local HQ = X.HQ or {}; X.HQ = HQ      -- [host squad] = { [i] = { m, s, x } }
local HG = X.HG or {}; X.HG = HG      -- [host squad] = { [i] = { str, since, sent } }
local function retinueSet(S)
  local set, list = {}, {}
  pcall(function()
    local ms = S.p1:getManors()
    for i = 1, #ms do
      local m = un(ms[i])
      if valid(m) then
        local mk = bkey(m); local rs = m:getBoundRetinue(); local t = {}
        for j = 1, #rs do local u = un(rs[j]); t[j] = u; local a = addr(u); if a then set[a] = true end end
        if mk then list[#list + 1] = { k = mk, men = t } end
      end
    end
  end)
  return set, list
end
local function gearStr(u)
  if not L.EQ then return nil end
  local ok, st = pcall(function() return u.Equipment end); if not ok or st == nil then return nil end
  local ok2, s = pcall(rec, st, L.EQ); return ok2 and s or nil
end
-- a militia squad that is called up (squadType 1, rallying status not 0 = not at home): the only men whose Equipment
-- travels (a mercenary's is his company's; a retainer's rally set is RGEAR's; a man at home works in his worn set and
-- the game changes it by itself: coop_x_army.lua's RGEAR notes)
local function raisedMilitia(R, h)
  local ok, st = pcall(R.sqState, h)
  return ok and type(st) == "table" and st.mil and (st.rs or 0) ~= 0 or false
end
local function hostMen(S, clock, full)
  if not (on.men or on.gear) then return end
  local R = C.armyApi; if not (R and R.sqValid and R.unitsOf) then return end
  local rset = on.gear and retinueSet(S) or {}
  local okL, sq = pcall(function() return S.p1.commandedSquads end); if not okL or not sq then return end
  local seen = {}
  for i = 1, #sq do
    local h = sq[i].Value
    if h and h ~= 0 and R.sqValid(h) then
      seen[h] = true
      local okU, men = pcall(R.unitsOf, h)
      if okU and men then
        local n = #men
        if on.men then
          local Q = HQ[h] or {}; HQ[h] = Q; local ch = {}
          for j, u in ipairs(men) do
            local okV, m, s = pcall(function() return u.morale, u.stamina end)
            if okV and type(m) == "number" then
              local o = Q[j]
              local function moved(a, b) return math.abs(a - b) > math.max(cfg.menTol, 0.005 * math.abs(a)) end
              if full or not o or moved(m, o[1]) or moved(s, o[2]) or #Q ~= n then
                Q[j] = { m, s }; ch[#ch + 1] = string.format("%d=%s,%s", j, fmtV("f", m), fmtV("f", s))
              end
            end
          end
          for j = #Q, n + 1, -1 do Q[j] = nil end
          if #ch > 0 then sendParts("men", string.format("ST Q %d %d ", h, n), ch) end
        end
        if on.gear and L.EQ and not raisedMilitia(R, h) then HG[h] = nil end
        if on.gear and L.EQ and raisedMilitia(R, h) then
          local Gq = HG[h] or {}; HG[h] = Gq; local ch = {}
          for j, u in ipairs(men) do
            if not rset[addr(u) or 0] then
              local s = gearStr(u)
              if s then
                local o = Gq[j]
                if not o or o.str ~= s then Gq[j] = { str = s, since = clock, sent = o and o.sent } ; o = Gq[j] end
                if (full and o.sent) or (o.sent ~= o.str and clock - o.since >= cfg.gearSettle) then o.sent = o.str; ch[#ch + 1] = j .. "=" .. o.str end
              end
            end
          end
          if #ch > 0 then sendParts("gear", string.format("ST G %d %d ", h, n), ch) end
        end
      end
    end
  end
  for h in pairs(HQ) do if not seen[h] then HQ[h] = nil end end
  for h in pairs(HG) do if not seen[h] then HG[h] = nil end end
end
local HR = X.HR or {}; X.HR = HR      -- [key] = { [i] = exp string }
local function hostExpList(sec, kind, key, vals, full)
  local old = HR[key]; local ch = {}
  for id, s in pairs(vals) do if full or not old or old[id] ~= s then ch[#ch + 1] = id .. "=" .. s end end
  table.sort(ch)
  if #ch > 0 then HR[key] = vals; sendParts(sec, string.format("ST %s %s %d ", kind, key, 0), ch) end
end
local function hostRetFam(S, full)
  if on.ret then
    local _, list = retinueSet(S)
    for _, m in ipairs(list) do
      local v = {}
      for j, u in ipairs(m.men) do local ok, x = pcall(function() return u.combatExperience end); if ok and type(x) == "number" then v[tostring(j)] = fmtV("f", x) end end
      hostExpList("ret", "R", m.k, v, full)
    end
  end
  if on.fam then
    local regs = S.eng.regions
    for i = 1, #regs do
      local r = un(regs[i])
      local mine = false; pcall(function() mine = valid(r) and addr(r.ownerPawn) == addr(S.p1) end)
      if mine then
        local rk = rkey(r)
        local v = {}
        pcall(function()
          local fams = r.workerFamilies
          for fi = 1, #fams do
            local mem = fams[fi].familyMembers
            for mi = 1, #mem do local u = un(mem[mi]); if valid(u) then local ok, x = pcall(function() return u.combatExperience end); if ok and type(x) == "number" then v[fi .. "." .. mi] = fmtV("f", x) end end end
          end
        end)
        if rk then hostExpList("fam", "X", "R:" .. rk, v, full) end
      end
    end
  end
end

-- ---------------------------------------------------------------- host: the driver
local HS = X.HS or {}; X.HS = HS
local function hostTick(S, clock)
  learn()
  local t0 = os.clock()
  -- the spec, after every ASK ALL and once a minute (a friend of another build does not write the lists)
  if HS.wantSpec or ((L.specT or L.specU) and clock - (HS.specT or -1e9) >= 60.0) then
    HS.specT = clock; HS.wantSpec = nil
    if not (L.specT or L.specU) then sendL("trk", "ST SPEC NONE 0 -") end   -- an answer all the same (the friend stops asking)
    if L.specT then sendL("trk", "ST SPEC T " .. hash(L.specT) .. " " .. L.specT) end
    if L.specU then sendL("time", "ST SPEC U " .. hash(L.specU) .. " " .. L.specU) end
  end
  -- the keyframe (every value but the lists again): due after an ASK ALL and every cfg.keyEvery s; the buildings' part
  -- goes with the next pass over them, the other parts at once (each once)
  if HS.wantFull or clock - (HS.keyT or -1e9) >= cfg.keyEvery then HS.keyT = clock; HS.wantFull = nil; HS.fullB = true; HS.fullO = true; HS.fullE = true end
  local full = HS.fullO; HS.fullO = nil
  -- the buildings: one pass at most every hostEvery s, spread over ticks
  if not HS.pass and clock - (HS.passT or -1e9) >= cfg.hostEvery then
    local I = index(S)
    if I then pcall(X.hostGone, I, S) end
    if I then HS.pass = { i = 0, list = I.list, digest = HS.wantDigest, full = HS.fullB, exp = {} }; HS.wantDigest = nil; HS.fullB = nil; HS.passT = clock end
  end
  local P = HS.pass
  if P then
    while (os.clock() - t0) * 1000 < cfg.budgetMs do
      P.i = P.i + 1
      local k = P.list[P.i]
      if not k then
        if #P.exp > 0 then sendParts("exp", "ST E ", P.exp) end
        HS.pass = nil; break
      end
      local b = bObj(S, k)
      if b then
        if L.ok or L.TIw then local ok, e = pcall(hostTrkB, S, k, b, P.digest); if not ok then bump("h_err"); X.lastErr = tostring(e) end end
        pcall(hostExpB, S, k, b, clock, P.exp, P.full)
      end
    end
  end
  if clock - (HS.mktT or -1e9) >= cfg.mktEvery or full then HS.mktT = clock; pcall(hostMkt, S, full) end
  if clock - (HS.menT or -1e9) >= cfg.menEvery or full then HS.menT = clock; pcall(hostMen, S, clock, full) end
  if clock - (HS.famT or -1e9) >= cfg.famEvery or full then HS.famT = clock; pcall(hostRetFam, S, full) end
  local okL, eL = pcall(X.hostLog, S, clock); if not okL then bump("l_err"); X.lastErr = tostring(eL) end   -- (defined below)
  local okE, eE = pcall(X.hostExpN, S, clock); if not okE then bump("e_err"); X.lastErr = tostring(eE) end  -- (defined below)
  local okG, eG = pcall(X.hostGrid, S, clock); if not okG then bump("g_err"); X.lastErr = tostring(eG) end    -- (defined below)
  local okH, eH = pcall(X.hostHist, S, clock); if not okH then bump("h_err"); X.lastErr = tostring(eH) end    -- (defined below)
end

-- ---------------------------------------------------------------- friend: what the host said
-- FT[bkey] = { g = { [good] = { n = <count>, list = { strings } } }, t = { n, list }, ownT = { [good] = clock } }
local FT = X.FT or {}; X.FT = FT
local FE = X.FE or {}; X.FE = FE
local FM = X.FM or {}; X.FM = FM
local FQ = X.FQ or {}; X.FQ = FQ
local FG = X.FG or {}; X.FG = FG
local FR = X.FR or {}; X.FR = FR
local FD = X.FD or {}; X.FD = FD      -- digests waiting to be compared: [bkey] = line
local FS = X.FS or {}; X.FS = FS      -- the host's specs
local ASKQ = {}
local function fT(k) local R = FT[k]; if not R then R = { g = {}, ownT = {} }; FT[k] = R end; return R end
local function items(s, fn) if not s or s == "-" then return end; for it in s:gmatch("[^;]+") do local a, b = it:match("^([^=]+)=(.*)$"); if a then fn(a, b) end end end
local function onT(w)
  local k, g, n, from = w[5], tonumber(w[6]), tonumber(w[7]), tonumber(w[8])
  if not (k and g and n and from) then return end
  local R = fT(k)
  if n < 0 then R.g[g] = { n = 0, list = {}, gone = true }; return end
  local E = R.g[g]
  if from > 1 and (not E or #E.list + 1 < from) then ASKQ[#ASKQ + 1] = k .. "|" .. g; bump("t_gap"); return end   -- lines missed: ask for the whole
  E = E or { list = {} }; R.g[g] = E; E.gone = nil; E.wait = nil
  local i = from
  if w[9] and w[9] ~= "-" then for e in w[9]:gmatch("[^;]+") do E.list[i] = e; i = i + 1 end end
  for j = #E.list, n + 1, -1 do E.list[j] = nil end
  E.n = n; if from == 1 then E.whole = true end      -- a whole list: compared record by record once
  bump("t_got")
end
local function onC(w)              -- the host's list lost its first entries (the game keeps the last days only)
  local k, g, d = w[5], tonumber(w[6]), tonumber(w[7]); if not (k and g and d) then return end
  local E = fT(k).g[g]; if not E then return end
  for _ = 1, math.min(d, #E.list) do table.remove(E.list, 1) end
  E.n = (E.n or d) - d; if E.n < 0 then E.n = 0 end
end
local function onU(w)              -- the time list is sent whole, with the host's pie as its game drew it
  local k, n, p = w[5], tonumber(w[6]), w[7]; if not (k and n and p) then return end
  local R = fT(k); local t = { n = n, list = {} }
  items(w[8], function(i, e) i = tonumber(i); if i then t.list[i] = e end end)
  if #t.list == n then t.p = (p ~= "-") and p or pctOf(t.list); R.t = t else bump("u_badLine") end
end
local function onM(w) local key, n = w[5], tonumber(w[6]); if not (key and n) then return end; local E = FM[key] or { list = {} }; FM[key] = E; E.n = n; items(w[7], function(i, v) i = tonumber(i); if i then E.list[i] = v end end); E.dirty = true end
local function onIdx(T, w) local key, n = tonumber(w[5]) or w[5], tonumber(w[6]); if not key then return end; local E = T[key] or { list = {} }; T[key] = E; E.n = n; E.t = os.clock(); E.up = nil; items(w[7], function(i, v) E.list[tonumber(i) or i] = v end) end

-- ---------------------------------------------------------------- the production log through the native piece (game run)
-- The log's map is not reflected and GetEntriesOfItemType through the mod loader crashed both copies (run l72a), so the
-- log is read with HIST TRKDUMP and a friend's is written with HIST TRKSET (in place, never past a list's capacity).
-- The save carries the log (run l72d: right after a join every building's log was the host's up to the save's day; only
-- the 1 or 2 days since differed). So:
--   host    reads every tracker's log every cfg.logReadEvery s (one native read for all) and sends, per good, the entries
--           from the first one that changed: ST L <bkey> <good> <n> <from> <day>/<amount>,...|-   (from 0-based; n -1:
--           the good is gone). After an ASK ALL: the last cfg.logTail entries of every good, and ST LD <bkey>
--           <good>=<n>:<hash>,... once a game day (a digest; a friend whose list differs asks: ST ASK L <bkey>|<good>,...).
--   friend  reads its own logs the same way every cfg.logReadEvery s; a good whose entries differ from the host's from entry
--           i on gets the host's from i on (TRKSET); the friend's own entries of today are written over by the next pass.
local HL = X.HL or {}; X.HL = HL      -- host: [bkey] = { [good] = { entries } }   what was sent
local FL = X.FL or {}; X.FL = FL      -- friend: [bkey] = { [good] = { n = , list = { entries } } }
cfg.logReadEvery = cfg.logReadEvery or 1.0; cfg.logTail = cfg.logTail or 8
cfg.missDrop = cfg.missDrop or 30.0
-- friend: a building's held values dropped (gone on the host, or not on this copy for cfg.missDrop s)
-- (the miss mark stays: values the host sends again for a building still missing here are dropped on the next pass
-- without counting again; it is cleared when the building is found)
function X.dropKey(k) FT[k] = nil; FE[k] = nil; FD[k] = nil; FL[k] = nil end
-- host: the keys of buildings that left the index since the last pass, sent as ST GONE <k>;... (rare: a building
-- demolished or burnt down)
function X.hostGone(I, S)
  local prev = HS.keys; local now = {}
  if HS.keysWorld ~= S.worldT then prev = nil; HS.keysWorld = S.worldT end   -- a new world: nothing gone
  for _, k in ipairs(I.list) do now[k] = true end
  HS.keys = now
  if not prev then return end
  local gone = {}; for k in pairs(prev) do if not now[k] then gone[#gone + 1] = k; HL[k] = nil; HE[k] = nil end end
  if #gone > 0 then table.sort(gone); sendParts("trk", "ST GONE ", gone) end
end
on.log = (on.log == nil) and true or on.log
local function patchP() local P = rawget(C, "patch"); if P and P.fn and P.send and P.tick and P.dir then return P end end
-- every tracker of this copy: { [bkey] = { a = hex address, log = { [good] = { "d/a", ... } } } } (nil without the native piece)
local function readLogs(S, tag)
  local P = patchP(); if not P then return nil end
  local I = index(S); if not I then return nil end
  local addrs, keyOf = {}, {}
  for _, k in ipairs(I.list) do
    local b = bObj(S, k)
    local ok, a = pcall(function() local c = b.ProductionTrackerComponent; if c and c:IsValid() then return string.format("%X", c:GetAddress()) end end)
    if ok and a then addrs[#addrs + 1] = a; keyOf[a] = k end
  end
  local out = {}
  for s = 1, #addrs, 200 do
    local part = {}; for i = s, math.min(#addrs, s + 199) do part[#part + 1] = addrs[i] end
    local t = tag .. math.floor((s - 1) / 200)
    local path = P.dir .. "hist_trk_" .. t .. ".txt"
    os.remove(path)
    P.send("HIST TRKDUMP " .. t .. " " .. table.concat(part, ",")); P.tick()
    local f = io.open(path, "r")
    if f then
      for l in f:lines() do
        local a, rest = l:match("^(%x+) %d+(.*)$")
        local k = a and keyOf[a]
        if k then
          local log = {}
          for g, body in rest:gmatch("| (%-?%d+):%d+:([^|]*)") do
            local e = {}; for x in body:gmatch("[^,%s]+") do e[#e + 1] = x end
            log[tonumber(g)] = e
          end
          out[k] = { a = a, log = log }
        end
      end
      f:close()
    else bump("l_noFile") end
  end
  return out
end
local function firstDiff(a, b) local n = math.min(#a, #b); for i = 1, n do if a[i] ~= b[i] then return i end end; if #a ~= #b then return n + 1 end; return nil end
local function hostLog(S, clock)
  if not on.log or clock - (X.HS.logT or -1e9) < cfg.logReadEvery then return end
  X.HS.logT = clock
  local now = readLogs(S, "h"); if not now then return end
  local tail = X.HS.logAll; X.HS.logAll = nil
  for k, B in pairs(now) do
    local R = HL[k]
    local first = not R
    if first then HL[k] = B.log; R = B.log end            -- seen first: noted (the save is the same on a friend)
    if not first or tail then
    for g, e in pairs(B.log) do
      local old = (R ~= B.log) and R[g] or nil
      local from
      -- a full list (366 days) loses its first entries as days are added: said as a shift (ST LS), not resent whole
      if old and not tail and #old > 0 and #e > 0 and old[1] ~= e[1] then
        for s = 1, math.min(8, #old - 1) do
          -- old[s+1 ..] must equal e[1 ..] (but for the last common entry: today's amount may have grown)
          local same, n = true, math.min(#old - s, #e)
          for i = 1, n - 1 do if old[s + i] ~= e[i] then same = false; break end end
          if same and n >= 2 then
            sendL("log", string.format("ST LS %s %d %d", k, g, s)); bump("l_shift")
            local o2 = {}; for i = s + 1, #old do o2[#o2 + 1] = old[i] end; old = o2
            break
          end
        end
      end
      if tail then from = math.max(1, #e - cfg.logTail + 1) elseif not old then from = 1 else from = firstDiff(old, e) end
      if from then
        -- in lines of at most 200 entries, each with its own start (run l72 cap: one head on every split line wrote the
        -- second part of a long list over its first entries on the friend)
        for c = from, #e, 200 do
          local part = {}; for i = c, math.min(#e, c + 199) do part[#part + 1] = e[i] end
          sendL("log", string.format("ST L %s %d %d %d %s", k, g, #e, c - 1, table.concat(part, ";")))
          bump("l_sent", #part)
        end
        if from > #e then sendL("log", string.format("ST L %s %d %d %d -", k, g, #e, #e)) end   -- (shorter: the count alone)
      end
      R[g] = e
    end
    for g in pairs(R) do if not B.log[g] then R[g] = nil; sendL("log", string.format("ST L %s %d -1 0 -", k, g)) end end
    end
  end
  -- a digest a game day (n and hash of each good's list): a friend that differs asks for the whole list
  local okD, day = pcall(function() return math.floor(S.eng.TemporalComponent.daysTotal) end)
  if okD and day ~= X.HS.logDay then
    X.HS.logDay = day
    for k, R in pairs(HL) do
      local d = {}; for g, e in pairs(R) do d[#d + 1] = string.format("%d=%d:%s", g, #e, hash(table.concat(e, ","))) end
      if #d > 0 then table.sort(d); sendL("log", "ST LD " .. k .. " " .. table.concat(d, ",")) end
    end
  end
end
X.hostLog = hostLog; X.readLogs = readLogs; X.firstDiff = firstDiff     -- (console and tests)
-- ---------------------------------------------------------------- expertise through the native piece (game run)
-- ExpertiseComponent's float (+0B8h) is not reflected (its one property is ProficiencySettings): read and written with
-- HIST EXP. Host: every building's value once a second, a change sent as before (ST E, whole-number or 0.1 rule).
-- Friend: a value that differs from the host's is written.
local function expNative(S, tag, writes)
  local P = patchP(); if not P then return nil end
  local I = index(S); if not I then return nil end
  local items, keyOf = {}, {}
  for _, k in ipairs(I.list) do
    local b = bObj(S, k)
    local c = b and comp(b, "ExpertiseComponent")
    local ok, a = pcall(function() if c then return string.format("%X", c:GetAddress()) end end)
    if ok and a then keyOf[a] = k; if not writes then items[#items + 1] = a elseif writes[k] then items[#items + 1] = a .. "=" .. writes[k] end end
  end
  local out = {}
  for s = 1, #items, 150 do
    local part = {}; for i = s, math.min(#items, s + 149) do part[#part + 1] = items[i] end
    local t = tag .. math.floor((s - 1) / 150)
    local path = P.dir .. "hist_exp_" .. t .. ".txt"
    os.remove(path)
    P.send("HIST EXP " .. t .. " " .. table.concat(part, ",")); P.tick()
    local f = io.open(path, "r")
    if f then for l in f:lines() do local a, v = l:match("^(%x+) ([%d%.e%+%-]+)$"); if a and keyOf[a] then out[keyOf[a]] = tonumber(v) end end; f:close() end
  end
  return out
end
local function hostExpN(S, clock)
  if not on.exp or L.exp or clock - (X.HS.expT or -1e9) < cfg.expFloor then return end
  X.HS.expT = clock
  local vals = expNative(S, "he"); if not vals then return end
  local out, all = {}, X.HS.fullE
  for k, v in pairs(vals) do
    local E = HE[k]
    if all or not E or math.floor(E.v) ~= math.floor(v) or math.abs(E.v - v) >= 0.1 then
      if v ~= 0 or (E and E.v ~= 0) then out[#out + 1] = k .. "=" .. fmtV("f", v) end
      HE[k] = { v = v, t = clock }
    end
  end
  X.HS.fullE = nil
  if #out > 0 then sendParts("exp", "ST E ", out) end
end
X.hostExpN = hostExpN; X.index = index; X.bObj = bObj   -- (the last two for the test probes)
local function friendExpN(S, clock)
  if not on.exp or L.exp or not next(FE) or clock - (X.fexpT or -1e9) < cfg.applyEvery then return end
  X.fexpT = clock
  local mine = expNative(S, "fe"); if not mine then return end
  local w, n = {}, 0
  for k, v in pairs(FE) do local m = mine[k]; if m and fmtV("f", m) ~= v then w[k] = v; n = n + 1 end end
  if n > 0 then expNative(S, "fw", w); bump("e_put", n) end
end

local function onL(w)
  local k, g, n, from = w[5], tonumber(w[6]), tonumber(w[7]), tonumber(w[8]); if not (k and g and n and from) then return end
  local R = FL[k]; if not R then R = {}; FL[k] = R end
  if n < 0 then R[g] = { n = 0, list = {}, gone = true }; return end
  local E = R[g]
  if from > 0 and (not E or #E.list < from) then ASKQ[#ASKQ + 1] = "L|" .. k .. "|" .. g; bump("l_gap"); return end
  E = E or { list = {} }; R[g] = E; E.gone = nil
  local i = from + 1
  if w[9] and w[9] ~= "-" then for x in w[9]:gmatch("[^;]+") do E.list[i] = x; i = i + 1 end end
  for j = #E.list, n + 1, -1 do E.list[j] = nil end
  E.n = n
end
local function onLS(w)            -- the host's full list lost its first <s> entries (the game keeps 366 days)
  local k, g, s = w[5], tonumber(w[6]), tonumber(w[7]); if not (k and g and s and s > 0) then return end
  local E = FL[k] and FL[k][g]; if not (E and E.n and #E.list == E.n) then return end
  for _ = 1, math.min(s, #E.list) do table.remove(E.list, 1) end
  E.n = #E.list; bump("l_shift")
end
local function onLD(w, mine)
  local k = w[5]; if not (k and w[6]) then return end
  local R = FL[k]
  local set = {}; X.FLD = X.FLD or {}; X.FLD[k] = set     -- the host's goods of this building (a good only here is emptied)
  for g, n, h in w[6]:gmatch("(%-?%d+)=(%d+):(%x+)") do
    g = tonumber(g); n = tonumber(n); set[g] = true
    local E = R and R[g]
    if not (E and #E.list == n and hash(table.concat(E.list, ",")) == h) then ASKQ[#ASKQ + 1] = "L|" .. k .. "|" .. g; bump("l_digestDiffers") end
  end
end
local function friendLog(S, clock)
  if not on.log or clock - (X.flogT or -1e9) < cfg.logReadEvery then return end
  X.flogT = clock
  if not next(FL) then return end
  local mine = readLogs(S, "f"); if not mine then return end
  local P = patchP()
  for k, R in pairs(FL) do
    local B = mine[k]
    if B then
      for g, E in pairs(R) do
        if E.n and #E.list == E.n then
          local m = B.log[g] or {}
          local i = firstDiff(m, E.list)
          if i and not (E.gone and #m == 0) then
            -- (a good this copy's log has not, or a list too small: the native piece lets the game's own add make the
            --  key or the room first)
            local part = {}; for j = i, #E.list do part[#part + 1] = E.list[j] end
            P.send(string.format("HIST TRKSET %s %d %d %s", B.a, g, i - 1, #part > 0 and table.concat(part, ",") or "-")); bump("l_set")
          end
        end
      end
    end
  end
  -- a good only this copy's log holds (not in the host's last digest of the building, not sent since): its list emptied
  -- (the key stays: removing a map key would need another game routine; an empty list counts nothing in the yield)
  for k, D in pairs(X.FLD or {}) do
    local B = mine[k]
    if B then
      for g, m in pairs(B.log) do
        local E = FL[k] and FL[k][g]
        if #m > 0 and not D[g] and not (E and not E.gone) then P.send(string.format("HIST TRKSET %s %d 0 -", B.a, g)); bump("l_clear") end
      end
    end
  end
  P.tick()
end

-- ---------------------------------------------------------------- friend: writing
local function syncList(R, k, g, arr, E, clock)
  local n, hn = #arr, E.n or #E.list
  if #E.list ~= hn then return "wait" end               -- a split line still on its way
  if n == hn and n > 0 and not E.whole then
    local okA, a1, an = pcall(function() return rec(arr[1], L.TE), rec(arr[n], L.TE) end)
    if okA and a1 == E.list[1] and an == E.list[n] then R.ownT[g] = nil; return "same" end
  elseif n == 0 and hn == 0 then return "same" end
  if n > hn then
    -- entries of this copy's own at the end: the host's may come in a moment (the same work done earlier here)
    R.ownT[g] = R.ownT[g] or clock
    if clock - R.ownT[g] < cfg.ownWait then bump("t_ownWait"); return "wait" end
    if on.rebuild and L.TE.plain then arr:Empty(); n = 0; bump("t_rebuilt")
    else bump("t_ownKept") end                         -- (switch off) the host's entries in place; the extra ones stay
  end
  R.ownT[g] = nil
  -- in place up to this copy's count (only the records that differ), then appended. Usually only the end differs:
  -- read back from the end to the first record that equals; when the first record differs too (the list was cut at
  -- its front at another moment here), or the host's whole list just came (a digest that differed), every record
  local m = math.min(n, hn)
  if E.whole or (m > 0 and rec(arr[1], L.TE) ~= E.list[1]) then
    for i = 1, m do local r = arr[i]; if rec(r, L.TE) ~= E.list[i] then putRec(r, L.TE, E.list[i]); bump("t_put") end end
    E.whole = nil
  else
    local i = m
    while i >= 1 do local r = arr[i]; if rec(r, L.TE) == E.list[i] then break end; putRec(r, L.TE, E.list[i]); bump("t_put"); i = i - 1 end
  end
  if hn > n then
    if on.grow then for i = n + 1, hn do local r = arr[#arr + 1]; putRec(r, L.TE, E.list[i]); bump("t_add") end
    else bump("t_short") end                            -- (switch off) this copy's game adds the entry; written then
  end
  return "written"
end
local function friendTrkB(S, k, b, R, clock)
  local c = comp(b, "ProductionTrackerComponent"); if not c then return end
  if on.trk and L.ok and FS.T == hash(L.specT or "") then
    local seen, extra = {}, {}
    c[L.map]:ForEach(function(kk, vv)
      local g = kk:get(); seen[g] = true
      local E = R.g[g]
      if E and E.wait then                                  -- asked for after a digest: its list is on its way
      elseif E and not E.gone then local okS, r = pcall(syncList, R, k, g, vv:get(), E, clock); if not okS then bump("t_err"); X.lastErr = tostring(r) end
      elseif (E and E.gone) or (not E and R.full) then extra[#extra + 1] = g end
    end)
    -- a good only this copy made (none in the host's list): emptied after the wait, then taken out of the map
    for _, g in ipairs(extra) do
      R.ownT[g] = R.ownT[g] or clock
      if clock - R.ownT[g] >= cfg.ownWait then
        if on.removeKey then local okR = pcall(function() c[L.map]:Remove(g) end); R.ownT[g] = nil; bump(okR and "t_keyRemoved" or "t_keyRemoveFail")
        else bump("t_keyOnlyHere") end                  -- (switch off) it stays
      end
    end
    -- a good the host's list has and this copy's map has not: added (filled in the next pass)
    for g, E in pairs(R.g) do
      if not seen[g] and not E.gone and not E.wait and (E.n or 0) > 0 and on.addKey then
        local okA = pcall(function() c[L.map]:Add(g, {}) end); bump(okA and "t_keyAdded" or "t_keyAddFail")
      end
    end
  end
  if on.time and L.TIw and R.t and FS.U == hash(L.specU or "") then
    -- the pie as this copy would draw it against the host's: when the per cents differ, the host's totals are written
    -- (this copy's own work since then is dropped; its per cents are the host's at once)
    local arr = c[L.time]; local n = #arr
    if n ~= R.t.n then bump("u_countDiffers")
    elseif (gamePct(c) or pctOf(readList(arr, L.TIw, 1, n))) ~= R.t.p then
      for i = 1, n do local h = R.t.list[i]; if h then local r = arr[i]; if rec(r, L.TIw) ~= h then putRec(r, L.TIw, h, true); bump("u_put") end end end
    end
  end
end
-- a digest of the host's: equal lists are taken as the host's here (so later lines continue them), others are asked for
local function friendDigest(S, k, b, line)
  local R = fT(k); R.full = true
  local c = comp(b, "ProductionTrackerComponent"); if not c then return end
  local gs, ts = line:match("^([^|]*)|(.*)$"); if not gs then return end
  local mine = {}
  -- (run l72c: without this guard c[nil] closed the friend's game inside the mod loader at its first digest: a
  --  property name that is not there must never reach a game object's index)
  if L.map then pcall(function() c[L.map]:ForEach(function(kk, vv) local arr = vv:get(); mine[kk:get()] = readList(arr, L.TE, 1, #arr) end) end) end
  for g, n, h in gs:gmatch("(%-?%d+)=(%d+):(%x+)") do
    g = tonumber(g); n = tonumber(n)
    local m = mine[g]
    if m and #m == n and hash(table.concat(m, ";")) == h then R.g[g] = { n = n, list = m }; bump("d_same")      -- equal here: the host's
    elseif R.g[g] and R.g[g].n == n and #R.g[g].list == n and hash(table.concat(R.g[g].list, ";")) == h then bump("d_stored")  -- lines had it
    else ASKQ[#ASKQ + 1] = k .. "|" .. g; R.g[g] = { list = {}, wait = true }; bump("d_differs") end
  end
  local okT = pcall(function()
    local tn, th = ts:match("^(%d+):(%x+)$")
    if tn and L.TIw then local arr = c[L.time]; local t = readList(arr, L.TIw, 1, #arr); if #t == tonumber(tn) and hash(table.concat(t, ";")) == th then R.t = { n = #t, list = t, p = gamePct(c) or pctOf(t) } end end
  end)
  if not okT then bump("d_timeErr") end
end
local function friendBuildings(S, clock, t0)
  local F = X.fpass
  if not F then
    if clock - (X.fpassT or -1e9) < cfg.applyEvery then return true end
    local I = index(S); if not I then return true end
    local keys = {}; for k in pairs(FT) do keys[#keys + 1] = k end; for k in pairs(FE) do if not FT[k] then keys[#keys + 1] = k end end; for k in pairs(FD) do if not FT[k] and not FE[k] then keys[#keys + 1] = k end end
    F = { i = 0, keys = keys }; X.fpass = F; X.fpassT = clock
    BYKEY = (L.TE and L.TE.hasObj) and byKey(S) or nil     -- only when an entry names a building (not seen yet)
  end
  while (os.clock() - t0) * 1000 < cfg.budgetMs do
    F.i = F.i + 1; local k = F.keys[F.i]
    if not k then X.fpass = nil; return true end
    local b = bObj(S, k)
    if not b then
      -- not on this copy (gone, or not built here yet): counted once; dropped after cfg.missDrop s (the host's
      -- keyframe sends a building's values again if it turns up); a building gone on the host is dropped at once (ST GONE)
      local M = X.miss; if not M then M = {}; X.miss = M end
      if not M[k] then M[k] = clock; if FT[k] or FE[k] then bump("f_noBuilding") end
      elseif clock - M[k] >= cfg.missDrop then X.dropKey(k); bump("f_dropped") end
    else
      if X.miss then X.miss[k] = nil end
      if FD[k] then local line = FD[k]; FD[k] = nil; local ok, e = pcall(friendDigest, S, k, b, line); if not ok then X.lastErr = tostring(e) end end
      if FT[k] then local ok, e = pcall(friendTrkB, S, k, b, FT[k], clock); if not ok then bump("f_err"); X.lastErr = tostring(e) end end
      local E = FE[k]
      if E and on.exp and L.exp then
        local c = comp(b, "ExpertiseComponent")
        if c then pcall(function() if fmtV("f", c[L.exp]) ~= E then c[L.exp] = tonumber(E); bump("e_put") end end) end
      end
    end
  end
  return false
end
local function friendList(arr, E, H)
  if (H.n or #H.list) ~= #arr then bump("m_countDiffers"); return end
  for i = 1, #arr do
    local h = H.list[i]
    if h and h ~= "?" then
      if E.num then
        local v = arr[i]; if type(v) ~= "number" and type(v) ~= "boolean" then local ok, g = pcall(function() return v:get() end); if ok then v = g end end
        if fmtV(E.num, v) ~= h then
          local nv; if E.num == "b" then nv = (h == "1") else nv = tonumber(h) end
          if nv ~= nil then arr[i] = nv; bump("m_put") end
        end
      else local r = arr[i]; if rec(r, E.F) ~= h then putRec(r, E.F, h, true); bump("m_put") end end
    end
  end
end
local function friendMkt(S)
  if not on.mkt then return end
  for key, H in pairs(FM) do
    if key == "FMS" then if L.FMS then pcall(friendList, S.eng.ForeignMarketSupply, L.FMS, H) end
    elseif key == "BASE" then pcall(function() local h = H.list[1]; if h and fmtV("f", S.eng.basePrice) ~= h then S.eng.basePrice = tonumber(h); bump("m_put") end end)
    elseif L.PRICE then local w = W(); local r = w and w.regionByKey and w.regionByKey(key); if r then pcall(friendList, r.price, L.PRICE, H) end end
  end
end
local function friendMen(S)
  local R = C.armyApi; if not (R and R.sqValid and R.unitsOf) then return end
  if on.men then
    for hh, H in pairs(FQ) do
      local h = A.toLocal(hh)
      if h and R.sqValid(h) then
        local okU, men = pcall(R.unitsOf, h)
        if okU and men then
          if #men ~= H.n then bump("q_countDiffers")
          else
            for j, s in pairs(H.list) do
              local u = men[j]; local m, st = s:match("^([^,]+),([^,]+)$")
              if u and m then pcall(function()
                if fmtV("f", u.morale) ~= m then u.morale = tonumber(m); bump("q_put") end
                if fmtV("f", u.stamina) ~= st then u.stamina = tonumber(st); bump("q_put") end
              end) end
            end
          end
        end
      end
    end
  end
  if on.gear and L.EQ then
    for hh, H in pairs(FG) do
      local h = A.toLocal(hh)
      local up = h and R.sqValid(h) and raisedMilitia(R, h)
      if up then H.up = true end
      -- home again or gone: not written any more (one not called up here yet waits for its call-up, 30 s at most)
      if not up then if H.up or os.clock() - (H.t or 0) > 30.0 then FG[hh] = nil; bump("g_dropped") end
      else
        local okU, men = pcall(R.unitsOf, h)
        if okU and men and #men == H.n then
          for j, s in pairs(H.list) do
            local u = men[j]
            if u and gearStr(u) ~= s then
              pcall(function() putRec(u.Equipment, L.EQ, s, true); u:SetVAMPVariationsToEquipment() end); bump("g_put")
            end
          end
        elseif okU and men then bump("g_countDiffers") end
      end
    end
  end
end
local function friendRetFam(S)
  for key, H in pairs(FR) do
    if key:sub(1, 2) == "R:" then
      if on.fam then
        local w = W(); local r = w and w.regionByKey and w.regionByKey(key:sub(3))
        if r then pcall(function()
          local fams = r.workerFamilies
          for id, s in pairs(H.list) do
            local fi, mi = tostring(id):match("^(%d+)%.(%d+)$"); fi, mi = tonumber(fi), tonumber(mi)
            if fi and fi <= #fams then
              local mem = fams[fi].familyMembers
              if mi <= #mem then local u = un(mem[mi]); if valid(u) and fmtV("f", u.combatExperience) ~= s then u.combatExperience = tonumber(s); bump("x_put") end end
            end
          end
        end) end
      end
    elseif on.ret then
      local _, list = retinueSet(S)
      for _, m in ipairs(list) do
        if m.k == key then
          for id, s in pairs(H.list) do local u = m.men[tonumber(id) or 0]; if valid(u) then pcall(function() if fmtV("f", u.combatExperience) ~= s then u.combatExperience = tonumber(s); bump("r_put") end end) end end
        end
      end
    end
  end
end
local function friendTick(S, clock)
  -- "send me everything": 3 s into a world, and again every 30 s until the host's spec came (a host not ready yet)
  if os.clock() - (S.worldT or 0) > cfg.askAfter and (not X.asked or (not X.gotSpec and clock - X.asked >= 30.0)) then
    X.asked = clock; A.send("ST ASK ALL"); log("asked the host for every list and value")
  end
  if #ASKQ > 0 and clock - (X.askT or -1e9) >= 1.0 then
    X.askT = clock; local q = ASKQ; ASKQ = {}
    local seen, t = {}, {}; for _, x in ipairs(q) do if not seen[x] then seen[x] = true; t[#t + 1] = x end end
    sendParts("ask", "ST ASK T ", t)
  end
  if C.hold or os.clock() - (S.worldT or 0) < 5.0 then return end
  if X.noWrite then return end           -- (test switch link/dev_stats_nowrite.txt: the friend stores, writes nothing)
  learn()
  local t0 = os.clock()
  do local okL, eL = pcall(friendLog, S, clock); if not okL then bump("l_err"); X.lastErr = tostring(eL) end end
  do local okE, eE = pcall(friendExpN, S, clock); if not okE then bump("e_err"); X.lastErr = tostring(eE) end end
  do local okG, eG = pcall(X.friendGrid, S, clock); if not okG then bump("g_err"); X.lastErr = tostring(eG) end end
  do local okH, eH = pcall(X.friendHist, S, clock); if not okH then bump("h_err"); X.lastErr = tostring(eH) end end
  local done = friendBuildings(S, clock, t0)
  if done and clock - (X.otherT or -1e9) >= cfg.applyEvery then
    X.otherT = clock
    pcall(friendMkt, S); pcall(friendMen, S); pcall(friendRetFam, S)
  end
end

-- ---------------------------------------------------------------- the wide daily sample (coop_world.lua calls these)
-- pt  a building's tracker: goods in its map | entries in all | hash of every entry | the time list's percentages
-- ex  a building's expertise              mk  supply, base price, a region's prices: count | hash
-- uv  the player's squads' men: count | morale | stamina | experience (sums, one decimal) | gear hash   (key: host squad)
function X.wideBuilding(P, b, k)
  learn()
  if P.pt then
    local c = comp(b, "ProductionTrackerComponent")
    if c then
      local ng, ne, hs = 0, "-", "-"
      if L.ok then
        local parts, n = {}, 0
        pcall(function() c[L.map]:ForEach(function(kk, vv) local arr = vv:get(); ng = ng + 1; n = n + #arr; parts[#parts + 1] = kk:get() .. ":" .. table.concat(readList(arr, L.TE, 1, #arr), ";") end) end)
        table.sort(parts); ne = tostring(n); hs = hash(table.concat(parts, "/"))
      else
        -- the map is not reflected: the game's own count of goods in the log (compared, not carried)
        pcall(function() ng = math.floor(tonumber(c:GetNumberOfGoodTypesInLog()) or 0) end)
      end
      local pct = "-"
      if L.time and L.TIw then pcall(function() local arr = c[L.time]; pct = gamePct(c) or pctOf(readList(arr, L.TIw, 1, #arr)) end) end
      if ng > 0 or (pct ~= "-" and pct:find("[1-9]")) then P.pt[k] = ng .. "|" .. ne .. "|" .. hs .. "|" .. pct end
    end
  end
  if P.ex and L.exp then
    local c = comp(b, "ExpertiseComponent")
    -- its whole number, as GetExpertise gives it (the host sends a change of a tenth at most once a second)
    if c then local ok, v = pcall(function() return c[L.exp] end); if ok and type(v) == "number" and math.floor(v) ~= 0 then P.ex[k] = string.format("%d", math.floor(v)) end end
  end
end
function X.wideRegion(P, r, k)
  learn(); if not (P.mk and L.PRICE) then return end
  local ok, s = pcall(function() local arr = r.price; local t = {}; for i = 1, #arr do t[i] = elemStr(L.PRICE, arr[i]) end; return #arr .. "|" .. hash(table.concat(t, ",")) end)
  if ok then P.mk[k] = s end
end
function X.wideWorld(P, S)
  learn()
  if P.mk then
    if L.FMS then pcall(function() local arr = S.eng.ForeignMarketSupply; local t = {}; for i = 1, #arr do t[i] = elemStr(L.FMS, arr[i]) end; P.mk.FMS = #arr .. "|" .. hash(table.concat(t, ",")) end) end
    pcall(function() P.mk.BASE = "1|" .. fmtV("f", S.eng.basePrice) end)
  end
  local R = C.armyApi
  if P.uv and R and R.unitsOf then
    pcall(function()
      local sq = S.p1.commandedSquads
      for i = 1, #sq do
        local h = sq[i].Value
        if h and h ~= 0 and R.sqValid(h) then
          local men = R.unitsOf(h); local m, s, x, g = 0, 0, 0, {}
          for j, u in ipairs(men) do m = m + (u.morale or 0); s = s + (u.stamina or 0); x = x + (u.combatExperience or 0); g[j] = gearStr(u) or "-" end
          table.sort(g)                                     -- the men's order in a squad may differ between copies
          -- as carried: the squad's mean morale and stamina to two places (each man is sent within 0.5 %); experience
          -- not for mercenaries (not carried); gear only for a called-up militia
          local okS, st = pcall(R.sqState, h); local merc = okS and type(st) == "table" and st.merc
          local n = math.max(#men, 1)
          P.uv["sq" .. tostring(A.toHost(h))] = string.format("%d|%.2g|%.2g|%s|%s", #men, m / n, s / n, merc and "-" or string.format("%.1f", x),
            raisedMilitia(R, h) and hash(table.concat(g, "/")) or "-")
        end
      end
    end)
  end
end

-- ---------------------------------------------------------------- the first-run reads (console)
function X.probe()
  local S = C.s; if not (S and valid(S.eng)) then return "no world" end
  L = nil; learn()
  local out = { "tracker props: " .. tostring(L.props), "map=" .. tostring(L.map) .. " entry=" .. (L.TE and L.TE.spec or "?") .. " plain=" .. tostring(L.TE and L.TE.plain),
    "time=" .. tostring(L.time) .. " entry=" .. (L.TI and L.TI.spec or "?") .. " skipped=" .. (L.TI and table.concat(L.TI.skipped, ",") or "?"), "expertise=" .. tostring(L.exp),
    "supply=" .. (L.FMS and (L.FMS.num or L.FMS.F.spec) or "?"), "price=" .. (L.PRICE and (L.PRICE.num or L.PRICE.F.spec) or "?"), "equipment=" .. (L.EQ and L.EQ.spec or "?") }
  pcall(function() out[#out + 1] = "lengths: supply " .. #S.eng.ForeignMarketSupply .. ", base price " .. tostring(S.eng.basePrice) end)
  -- one tracker: its goods and the ends of each list, and its time list
  local I = index(S, true)
  local shown = 0
  for _, k in ipairs(I and I.list or {}) do
    local b = bObj(S, k); local c = b and comp(b, "ProductionTrackerComponent")
    if c and L.map and shown < 3 then
      local t = {}
      pcall(function() c[L.map]:ForEach(function(kk, vv) local arr = vv:get(); local n = #arr; t[#t + 1] = kk:get() .. ":" .. n .. (n > 0 and (" [" .. rec(arr[1], L.TE) .. "] .. [" .. rec(arr[n], L.TE) .. "]") or "") end) end)
      if #t > 0 then
        shown = shown + 1
        local tl = "-"; pcall(function() local arr = c[L.time]; tl = #arr .. ": " .. table.concat(readList(arr, L.TI, 1, #arr), " ; ") end)
        out[#out + 1] = "building " .. k .. " goods " .. table.concat(t, " | ") .. " || time " .. tl
      end
    end
  end
  -- what the two native items will need: the save's struct of the region history and the fertility grid
  local SG = classProps("/Script/ManorLords.MLSaveGame")
  for _, n in ipairs({ "productionLogs", "fertilityGrid", "fertilityGridQuantized" }) do
    local e = SG[n]
    if e then
      local d = "?"
      pcall(function()
        local inner = e.p:GetInner(); local kn = kindOf(inner); d = kn
        if kn == "StructProperty" then local f = structFields(inner:GetStruct()); d = "struct " .. f.spec .. (f.plain and "" or (" + " .. table.concat(f.skipped, ","))) end
      end)
      out[#out + 1] = "MLSaveGame." .. n .. ": " .. d
    end
  end
  local SP = classProps("/Script/ManorLords.ProductionSubsystem"); local nsp = 0; for _ in pairs(SP) do nsp = nsp + 1 end
  out[#out + 1] = "ProductionSubsystem reflected properties: " .. nsp
  pcall(function() out[#out + 1] = "fertility redraw requests now: " .. #S.eng.fertilityGridUpdateRequests .. ", grid on: " .. tostring(S.eng.enableFertilityGrid) end)
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------- the write trial (console, a TEST copy only)
-- Coop.stats.trial("inplace"): one time entry (and one map entry, when the map is reflected) written with its time
-- +1 and read again through a fresh look, then put back. Coop.stats.trial("grow"): one map list grown by one record
-- through the map's value, counted through a fresh ForEach, then emptied and rebuilt as it was. Only after "grow" says
-- "kept" on a test copy may the switches grow / rebuild be set on.
function X.trial(step)
  local S = C.s; if not (S and valid(S.eng)) then return "no world" end
  learn(); local I = index(S, true); local out = {}
  for _, k in ipairs(I and I.list or {}) do
    local b = bObj(S, k); local c = b and comp(b, "ProductionTrackerComponent")
    if c and step == "inplace" and L.TIw and L.TIw.ti then
      local okT, res = pcall(function()
        local arr = c[L.time]; if #arr == 0 then return nil end
        local before = rec(arr[1], L.TIw); local f = L.TIw.list[L.TIw.ti]
        local v = getPath(arr[1], f.path); setPath(arr[1], f.path, v + 1.0)
        local after = rec(c[L.time][1], L.TIw); local pct = gamePct(c)
        putRec(c[L.time][1], L.TIw, before, true)
        return string.format("time list of %s: before [%s], written [%s] (pie %s), put back [%s]", k, before, after, tostring(pct), rec(c[L.time][1], L.TIw))
      end)
      if okT and res then out[#out + 1] = res; break elseif not okT then out[#out + 1] = "time list: " .. tostring(res); break end
    elseif c and step == "grow" and L.ok then
      local okG, res = pcall(function()
        local first
        c[L.map]:ForEach(function(kk, vv) if first == nil then local arr = vv:get(); if #arr > 0 then first = { g = kk:get(), list = readList(arr, L.TE, 1, #arr) } end end end)
        if not first then return nil end
        c[L.map]:ForEach(function(kk, vv) if kk:get() == first.g then local arr = vv:get(); local r = arr[#arr + 1]; putRec(r, L.TE, first.list[#first.list]) end end)
        local n2; c[L.map]:ForEach(function(kk, vv) if kk:get() == first.g then n2 = #vv:get() end end)
        c[L.map]:ForEach(function(kk, vv) if kk:get() == first.g then local arr = vv:get(); arr:Empty(); for _, s in ipairs(first.list) do putRec(arr[#arr + 1], L.TE, s) end end end)
        local n3; c[L.map]:ForEach(function(kk, vv) if kk:get() == first.g then n3 = #vv:get() end end)
        return string.format("map list %s good %d: %d records, grown to %s (%s), rebuilt to %s", k, first.g, #first.list, tostring(n2), n2 == #first.list + 1 and "kept" or "NOT kept", tostring(n3))
      end)
      if okG and res then out[#out + 1] = res; break elseif not okG then out[#out + 1] = "grow: " .. tostring(res); break end
    end
  end
  if step == "grow" and not L.ok then out[#out + 1] = "the map is not a reflected property here: nothing to grow" end
  return #out > 0 and table.concat(out, "\n") or "nothing found to try"
end

-- ---------------------------------------------------------------- the module
local function status()
  local t = {}; for k, v in pairs(X.stats) do t[#t + 1] = k .. "=" .. tostring(v) end; table.sort(t)
  local b = {}; for k, v in pairs(X.bytes) do b[#b + 1] = k .. "=" .. v end; table.sort(b)
  local nt = 0; for _ in pairs(FT) do nt = nt + 1 end; local nh = 0; for _ in pairs(HT) do nh = nh + 1 end
  return string.format("stats %s: %s | bytes %s | host lists %d, friend's store %d | err %s", X.version, table.concat(t, " "), table.concat(b, " "), nh, nt, tostring(X.lastErr))
end
X.status = status

local function tick(S, clock)
  if not (valid(S.eng) and valid(S.p1)) then return end
  if S.role == "host" then local ok, e = pcall(hostTick, S, clock); if not ok then bump("err"); X.lastErr = tostring(e) end
  elseif S.role == "friend" then local ok, e = pcall(friendTick, S, clock); if not ok then bump("err"); X.lastErr = tostring(e) end end
  -- a line a minute, and the bytes of each game day (the owner asked for the bytes a game day costs)
  if clock - (X.logT or 0) >= cfg.logEvery then X.logT = clock; log("%s", status()) end
  local okD, day = pcall(function() return math.floor(S.eng.TemporalComponent.daysTotal) end)
  if okD and day and S.role == "host" then
    if X.day and day ~= X.day then
      local tot, t = 0, {}; for k, v in pairs(X.bytes) do tot = tot + v - ((X.dayBytes or {})[k] or 0); t[#t + 1] = k .. "=" .. (v - ((X.dayBytes or {})[k] or 0)) end
      table.sort(t); log("day %d: %d bytes sent (%s)", X.day, tot, table.concat(t, " "))
      X.dayBytes = {}; for k, v in pairs(X.bytes) do X.dayBytes[k] = v end
    end
    X.day = day
  end
end

-- ---------------------------------------------------------------- the fertility grid (V061, V116), native, no hook
-- The grid (1024 x 1024 cells, four floats each) is compared in 32 x 32-cell blocks by a hash of the exact bits
-- (HIST GRIDHASH steps 0). Host: every cfg.gridEvery s, the blocks whose hash changed: ST GH <i>=<hash>;... (i = by *
-- 32 + bx; all of them after an ASK ALL). Friend: a block whose hash differs from the host's (the host's at least
-- cfg.gridSettle s old) is asked for with its 32 row hashes: ST GA <bx>:<by> <h0>,...,<h31>; the host answers with the
-- rows that differ, exact: ST GC <y> <x0> <cells>; the friend writes them (HIST GRIDSET) and the game redraws them.
cfg.gridEvery = cfg.gridEvery or 2.0; cfg.gridSettle = cfg.gridSettle or 1.0; cfg.gridAskAgain = cfg.gridAskAgain or 6.0
on.grid = (on.grid == nil) and true or on.grid
local GRH = X.GRH or {}; X.GRH = GRH      -- host: [i] = hash sent
local GRF = X.GRF or { h = {}, t = {}, asked = {}, rows = {} }; X.GRF = GRF   -- friend: the host's hashes, when, asked, rows to write
local function engHex(S) local ok, a = pcall(function() return string.format("%X", S.eng:GetAddress()) end); return ok and a or nil end
local function gridHashes(S, tag)
  local P = patchP(); local e = engHex(S); if not (P and e) then return nil end
  local path = P.dir .. "hist_grid_" .. tag .. ".txt"; os.remove(path)
  P.send("HIST GRIDHASH " .. e .. " " .. tag .. " 32 0"); P.tick()
  local f = io.open(path, "r"); if not f then return nil end
  local t, i, side = {}, 0, nil
  for l in f:lines() do
    if not side then side = l:match("^grid %d+ cells side (%d+) block 32 steps 0")
    elseif l:match("^%x%x%x%x%x%x%x%x") then for h in l:gmatch("%x+") do t[i] = h; i = i + 1 end end
  end
  f:close()
  if not side or i ~= (tonumber(side) / 32) ^ 2 then return nil end
  return t, math.floor(tonumber(side) / 32)   -- (an integer: the block keys are written with it)
end
local function gridRows(S, tag, list)
  local P = patchP(); local e = engHex(S); if not (P and e) then return {} end
  local path = P.dir .. "hist_grows_" .. tag .. ".txt"; os.remove(path)
  P.send("HIST GRIDROWS " .. e .. " " .. tag .. " " .. table.concat(list, ",")); P.tick()
  local out, f = {}, io.open(path, "r"); if not f then return out end
  for l in f:lines() do local bx, by, rest = l:match("^(%d+) (%d+) (.*)$"); if bx and rest and not rest:find("BAD") then local r = {}; for h in rest:gmatch("%x+") do r[#r + 1] = h end; out[bx .. ":" .. by] = r end end
  f:close(); return out
end
function X.hostGrid(S, clock)
  if not on.grid or clock - (HS.gridT or -1e9) < cfg.gridEvery then return end
  HS.gridT = clock
  local t = gridHashes(S, "hg"); if not t then bump("g_noGrid"); return end
  local out, all = {}, HS.gridAll; HS.gridAll = nil
  for i = 0, #t do local h = t[i]; if h and (all or GRH[i] ~= h) then GRH[i] = h; out[#out + 1] = i .. "=" .. h end end
  if #out > 0 then sendParts("grid", "ST GH ", out) end
end
local function hostGridAsk(S, w)
  local key, rows = w[5], w[6]; if not (key and rows) then return end
  local bx, by = key:match("^(%d+):(%d+)$"); if not bx then return end
  local fr = {}; for h in rows:gmatch("%x+") do fr[#fr + 1] = h end
  local mine = gridRows(S, "ha", { key })[key]; if not mine then return end
  local mask = 0
  for y = 1, 32 do if mine[y] ~= fr[y] then mask = mask + math.floor(2 ^ (y - 1)) end end
  if mask == 0 then bump("g_askSame"); return end
  local P = patchP(); local e = engHex(S); if not (P and e) then return end
  local path = P.dir .. "hist_gget_hc.txt"; os.remove(path)
  P.send(string.format("HIST GRIDGET %s hc %s %s %X", e, bx, by, mask)); P.tick()
  local f = io.open(path, "r"); if not f then return end
  for l in f:lines() do local y, x0, cells = l:match("^(%d+) (%d+) (%x+)$"); if cells then sendL("grid", "ST GC " .. y .. " " .. x0 .. " " .. cells); bump("g_rows") end end
  f:close()
end
local function friendGrid(S, clock)
  if not on.grid or not next(GRF.h) then return end
  -- rows from the host ([<y> <x0>] = line, the newest of a row): written in one native call. Every changed cell is
  -- written at once; its redraw goes on the game's queue when it has room, else the native piece keeps it pending and
  -- this asks it every 0.25 s to move pending cells onto the queue (the game draws one a frame, none while paused)
  local P = patchP(); local e = engHex(S)
  if P and e and next(GRF.rows) then
    local f = io.open(P.dir .. "hist_gin_fw.txt", "w")
    if f then
      local n = 0
      for _, l in pairs(GRF.rows) do f:write(l, "\n"); n = n + 1 end; f:close()
      local out = P.dir .. "hist_gset_fw.txt"; os.remove(out)
      P.send("HIST GRIDSET " .. e .. " fw"); P.tick(); bump("g_set", n)
      local g = io.open(out, "r"); local s = g and g:read("a") or ""; if g then g:close() end
      GRF.pend = tonumber(s:match("pending (%d+)") or "0") > 0; GRF.setT = os.clock()
    end
    GRF.rows = {}
  elseif P and e and GRF.pend and os.clock() - (GRF.setT or -1e9) >= 0.25 then
    GRF.setT = os.clock()
    local out = P.dir .. "hist_gflush_ff.txt"; os.remove(out)
    P.send("HIST GRIDFLUSH " .. e .. " ff"); P.tick()
    local g = io.open(out, "r"); local s = g and g:read("a") or ""; if g then g:close() end
    GRF.pend = tonumber(s:match("pending (%d+)") or "0") > 0
  end
  if clock - (X.fgridT or -1e9) < cfg.gridEvery then return end
  X.fgridT = clock
  local t, nb = gridHashes(S, "fg"); if not t then return end
  local ask = {}
  for i, h in pairs(GRF.h) do
    if t[i] and t[i] ~= h and clock - (GRF.t[i] or clock) >= cfg.gridSettle and clock - (GRF.asked[i] or -1e9) >= cfg.gridAskAgain and #ask < 8 then
      ask[#ask + 1] = (i % nb) .. ":" .. math.floor(i / nb); GRF.asked[i] = clock
    end
  end
  if #ask == 0 then return end
  local rows = gridRows(S, "fr", ask)
  for _, key in ipairs(ask) do local r = rows[key]; if r then sendL("grid", "ST GA " .. key .. " " .. table.concat(r, ",")); bump("g_ask") end end
end
X.friendGrid = friendGrid

-- ---------------------------------------------------------------- the region graphs (V111), native, no hook
-- The production subsystem keeps, per region, a day record (newest first) with three maps good -> amount: +0 the
-- region's stock, +50h and +0A0h the day's counts. Host: every cfg.histEvery s the newest 2 records of every region
-- (HIST SUBDUMP); a map that changed is sent whole: ST H <region key> <d/m/y> <m0|m50|mA0> <good>=<n>;... Friend: its
-- own newest 3 records the same way; for a record of the same date (each copy makes its record at its own day change)
-- the host's amounts are written in place (HIST HSET); a good the friend's map lacks is not added (counted), a good
-- only the friend has is set to 0.
cfg.histEvery = cfg.histEvery or 1.0
-- a good the friend's map lacks is added with the game's own find-or-add (the advisor's trial passed: HIST MAPADD, an
-- existing and a new good, save, load, both kept; section 15 of the lane 72 report); false: counted only (h_missing)
if cfg.histAdd == nil then cfg.histAdd = true end
on.hist = (on.hist == nil) and true or on.hist
local HH = X.HH or {}; X.HH = HH          -- host: [rkey|date|map] = the items sent
local FH = X.FH or {}; X.FH = FH          -- friend: [rkey|date|map] = { t = clock, v = { [good] = n } }
local MAPOFF = { m0 = "0", m50 = "50", mA0 = "A0" }
local function regionKeys(S)
  local t = {}
  pcall(function() local arr = S.eng.regions; for i = 1, #arr do local r = un(arr[i]); if valid(r) then local a = addr(r); local k = rkey(r); if a and k then t[string.format("%X", a)] = k end end end end)
  return t
end
-- this copy's newest <days> records: { { reg = hex, key = rkey, date = "d/m/y", maps = { m0 = "items", ... } }, ... }
local function readHist(S, tag, days)
  local P = patchP(); if not P then return nil end
  local ss = rawget(X, "subsys"); if not (ss and ss:IsValid()) then ss = FindFirstOf("ProductionSubsystem"); X.subsys = ss end
  if not (ss and ss:IsValid()) then return nil end
  local sa = string.format("%X", ss:GetAddress())
  local path = P.dir .. "hist_sub_" .. tag .. ".txt"; os.remove(path)
  P.send("HIST SUBDUMP " .. sa .. " " .. tag .. " " .. days); P.tick()
  local f = io.open(path, "r"); if not f then return nil end
  local keys = regionKeys(S)
  local out, cur = {}, nil
  for l in f:lines() do
    local ra = l:match("^region %d+ (%x+) name")
    if ra then cur = keys[ra] and { reg = ra, key = keys[ra] } or nil
    elseif cur then
      local date, rest = l:match("^%s+day %d+ date (%S+) (.*)$")
      if date then
        local R = { reg = cur.reg, key = cur.key, date = date, maps = {} }
        for name, items in rest:gmatch("(m%w+)%[%d+/%d+%]:?([^ ]*)") do local t = {}; for g, n in items:gmatch("(%-?%d+)=(%-?%d+)") do t[#t + 1] = g .. "=" .. n end; table.sort(t); R.maps[name] = table.concat(t, ";") end
        out[#out + 1] = R
      end
    end
  end
  f:close()
  return out, sa
end
function X.hostHist(S, clock)
  if not on.hist or clock - (HS.histT or -1e9) < cfg.histEvery then return end
  HS.histT = clock
  local recs = readHist(S, "hh", 2); if not recs then bump("h_noSub"); return end
  local all = HS.histAll; HS.histAll = nil
  for _, R in ipairs(recs) do
    for name, items in pairs(R.maps) do
      local k = R.key .. "|" .. R.date .. "|" .. name
      if all or HH[k] ~= items then HH[k] = items; sendL("hist", "ST H " .. R.key .. " " .. R.date .. " " .. name .. " " .. (items ~= "" and items or "-")); bump("h_sent") end
    end
  end
end
local function onH(w)
  local k, date, name, items = w[5], w[6], w[7], w[8]; if not (k and date and name and MAPOFF[name]) then return end
  local v = {}; if items and items ~= "-" then for g, n in items:gmatch("(%-?%d+)=(%-?%d+)") do v[tonumber(g)] = tonumber(n) end end
  FH[k .. "|" .. date .. "|" .. name] = { t = os.clock(), v = v }
end
local function friendHist(S, clock)
  if not on.hist or not next(FH) or clock - (X.fhistT or -1e9) < cfg.histEvery then return end
  X.fhistT = clock
  local recs, sa = readHist(S, "fh", 3); if not recs then return end
  local lines, nmiss = {}, 0
  for _, R in ipairs(recs) do
    for name, items in pairs(R.maps) do
      local H = FH[R.key .. "|" .. R.date .. "|" .. name]
      if H then
        local mine = {}; for g, n in items:gmatch("(%-?%d+)=(%-?%d+)") do mine[tonumber(g)] = tonumber(n) end
        local w = {}
        -- a good this map lacks goes in too when the add is on (HSET ... ADD adds it with the game's find-or-add)
        for g, n in pairs(H.v) do if mine[g] == nil and not cfg.histAdd then nmiss = nmiss + 1 elseif mine[g] ~= n then w[#w + 1] = g .. "=" .. n end end
        for g, n in pairs(mine) do if H.v[g] == nil and n ~= 0 then w[#w + 1] = g .. "=0" end end
        if #w > 0 then lines[#lines + 1] = R.reg .. " " .. R.date .. " " .. MAPOFF[name] .. " " .. table.concat(w, ",") end
      end
    end
  end
  if nmiss > 0 then bump("h_missing", nmiss) end
  -- the host's maps of days no copy shows any more: dropped after 10 minutes
  do local now = os.clock(); for k, H in pairs(FH) do if now - H.t > 600 then FH[k] = nil end end end
  if #lines == 0 then return end
  local P = patchP(); if not P then return end
  local f = io.open(P.dir .. "hist_hin_fw.txt", "w"); if not f then return end
  for _, l in ipairs(lines) do f:write(l, "\n") end; f:close()
  P.send("HIST HSET " .. sa .. " fw" .. (cfg.histAdd and " ADD" or "")); P.tick(); bump("h_set", #lines)
end
X.friendHist = friendHist

local function onMessage(S, from, kind, w)
  if kind ~= "ST" then return false end
  local sub = w[4]
  if S.role == "friend" and from == "host" then
    if sub == "GH" then local now = os.clock(); items(w[5], function(i, h) i = tonumber(i); if i then GRF.h[i] = h; GRF.t[i] = now end end)
    elseif sub == "H" then onH(w)
    elseif sub == "GC" then if w[5] and w[6] and w[7] then GRF.rows[w[5] .. " " .. w[6]] = w[5] .. " " .. w[6] .. " " .. w[7]; GRF.rowsT = GRF.rowsT or os.clock() end
    elseif sub == "T" then onT(w)
    elseif sub == "C" then onC(w)
    elseif sub == "L" then onL(w)
    elseif sub == "LD" then onLD(w)
    elseif sub == "LS" then onLS(w)
    elseif sub == "U" then onU(w)
    elseif sub == "D" then if w[5] and w[6] then FD[w[5]] = w[6]; bump("d_got") end
    elseif sub == "GONE" then if w[5] and w[5] ~= "-" then for k in w[5]:gmatch("[^;]+") do X.dropKey(k); if X.miss then X.miss[k] = nil end; bump("f_gone") end end
    elseif sub == "E" then items(w[5], function(k, v) FE[k] = v end)
    elseif sub == "M" then onM(w)
    elseif sub == "Q" then onIdx(FQ, w)
    elseif sub == "G" then onIdx(FG, w)
    elseif sub == "R" or sub == "X" then local key = w[5]; if key then local E = FR[key] or { list = {} }; FR[key] = E; items(w[7], function(i, v) E.list[i] = v end) end
    elseif sub == "SPEC" then
      local what, h, spec = w[5], w[6], w[7]
      X.gotSpec = true                                    -- the host answers: no more asking (a wrong spec is logged once)
      if what and h then
        learn(); local mine = what == "T" and L.specT or (what == "U" and L.specU) or nil
        if mine and hash(mine) == h then FS[what] = h
        else FS[what] = nil; if X.specSaid ~= (what .. h) then X.specSaid = what .. h; log("the host's %s lists hold %s, this copy's %s: not written", what, tostring(spec), tostring(mine)) end end
      end
    end
  elseif S.role == "host" and from ~= "host" and sub == "GA" then
    local ok, e = pcall(hostGridAsk, S, w); if not ok then bump("g_err"); X.lastErr = tostring(e) end
  elseif S.role == "host" and from ~= "host" and sub == "ASK" then
    if w[5] == "ALL" then HS.gridAll = true; HS.histAll = true; HS.logAll = true; HS.wantDigest = true; HS.wantFull = true; HS.wantSpec = true; for k in pairs(HM) do HM[k] = nil end; for k in pairs(HR) do HR[k] = nil end; bump("ask_all"); log("%s asked for every list and value", tostring(from))
    elseif w[5] == "T" then
      -- (production log) "L|<bkey>|<good>": its whole list again at the next look
      for k, g in (w[6] or ""):gmatch("L|([^|;]+)|(%-?%d+)") do local R = HL[k]; if R then R[tonumber(g)] = nil end; bump("ask_l") end
      items(((w[6] or ""):gsub("L|[^;]*;?", ""):gsub("|", "=")), function(k, g) local R = HT[k]; g = tonumber(g); if R and g then R.g[g] = nil end; bump("ask_t") end)
    end
  end
  return true
end

C.register("stats", {
  onWorld = function(S)
    -- a new world: this copy's buildings, the friend's own-entry timers and its store of the host's lists start again
    -- (after a load the lists here are the save's; the digests after ASK ALL say which equal the host's)
    do local f = io.open((rawget(_G, "COOP_LINK_DIR") or "") .. "dev_stats_nowrite.txt", "rb"); X.noWrite = f ~= nil or os.getenv("COOP_STATS_NOWRITE") == "1"; if f then f:close() end end
    IX = nil; L = nil; X.asked = nil; X.gotSpec = nil; X.fpass = nil; HS.pass = nil; for k in pairs(FS) do FS[k] = nil end
    for k in pairs(FT) do FT[k] = nil end; for k in pairs(FD) do FD[k] = nil end
    if S.role == "host" then for k in pairs(HT) do HT[k] = nil end; for k in pairs(HE) do HE[k] = nil end; for k in pairs(HM) do HM[k] = nil end; for k in pairs(HQ) do HQ[k] = nil end; for k in pairs(HG) do HG[k] = nil end; for k in pairs(HR) do HR[k] = nil end end
  end,
  tick = tick, onMessage = onMessage })
return "coop_x_stats " .. X.version .. " loaded"
