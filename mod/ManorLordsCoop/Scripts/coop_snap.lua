-- Manor Lords Co-op: the game's values read by the native piece (plug-in module "snap"). Lane 47, session 21.
-- Evidence: research/2026-11-10-game-probe/lanes/lane_s21_47/report.txt; the native side: native/coop_patch/coop_snap.h.
--
-- Every value read through the mod loader costs 0.5 to 16 us (sitting b1: an object 1.5 us, an enum 14.5 us, a game
-- function 10 to 13 us). The native piece (coop_patch.dll) reads the same plain fields from memory, proves every object
-- alive in the engine's object array first, and hands over only what changed since the last frame, in snap_out.bin
-- (read here right after its tick, through a handle kept open: 4 us).
--
--   1. On each world: SNAP UOA (the object array checked against the engine and the player's lord, valid here this
--      frame), then the crash guard (SNAP GUARD) and the building table (SNAP TABLE 0: the engine's buildingArr with
--      the fields below, their offsets taken from the reflected properties).
--   2. The table is checked once, building by building, against the reflected reads (a few a frame). One difference
--      and the table is refused for this world: every module then reads as before (the fall-back is automatic; it is
--      also what another game build gets, where the native piece refuses SNAP).
--   3. Modules ask N.buildings() (nil while the table is not checked): the records in the engine's list order.
--      A record: a (address), idx, pos (0-based list place), ver, t (A.btype), rawT, tbc (typeBeforeChange), own (the
--      owner's address, 0 none), reg (the region's address), fn (buildingFunction), fire, cons (Data.constructed),
--      upg (isBeingUpgraded), nB, nR, nC (lengths of buildings, Resources, Carts), ups (upgradesDone as "a.b.c" or ""),
--      inv ({ [good] = amount } summed per good as invOf does), nInv; N.obj(rec): the building's object (found once
--      in the engine's list at its place, its address compared), N.loc(rec): x, y, z, yaw by the game's own calls,
--      once per building (a building does not move).
-- Console only: Coop.snap.test.off = true (every module reads as before), Coop.snap.shadow() (the table compared with
-- the reflected reads now; "0 differing" expected).

local C = rawget(_G, "Coop")
if type(C) ~= "table" or type(C.register) ~= "function" or type(C.api) ~= "table" then return "coop_snap: load coop.lua first" end
local A = C.api
local un, valid = A.un, A.valid
local N = C.snap or {}
C.snap = N
N.version = "0.1"
N.stats = N.stats or {}
N.test = N.test or {}
local unpack = string.unpack

local function log(fmt, ...) A.log("snap: " .. fmt, ...) end
local function bump(k, n) N.stats[k] = (N.stats[k] or 0) + (n or 1) end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); if ok then return a end end
local function hex(a) return string.format("%X", a) end
local function patch() local P = rawget(C, "patch"); if P and P.fn then return P end end

-- ---------------------------------------------------------------- reflected offsets
local function propsOf(o)
  local t = {}
  local cls = o:GetClass()
  while cls and cls:IsValid() do
    cls:ForEachProperty(function(p)
      local n = p:GetFName():ToString()
      if t[n] == nil then
        local e = { off = p:GetOffset_Internal(), kind = p:GetClass():GetFName():ToString(), p = p }
        pcall(function() e.mask = p:GetByteMask(); e.boff = p:GetByteOffset() end)
        t[n] = e
      end
    end)
    local ok, sup = pcall(function() return cls:GetSuperStruct() end)
    if not ok or not sup or not sup:IsValid() then break end
    cls = sup
  end
  return t
end
local function structProps(e)
  local t = {}
  e.p:GetStruct():ForEachProperty(function(p)
    local x = { off = p:GetOffset_Internal(), kind = p:GetClass():GetFName():ToString(), p = p }
    pcall(function() x.mask = p:GetByteMask(); x.boff = p:GetByteOffset() end)
    t[p:GetFName():ToString()] = x
  end)
  return t
end
local function boolSpec(e, base)
  local off = (base or 0) + e.off + (e.boff or 0)
  return string.format("b%X:%X", off, (e.mask and e.mask > 0) and e.mask or 0xFF)
end

-- the building table's fields: name, native spec, decode kind ("i" integer, "f" double)
local function buildingSpec(b)
  local P = propsOf(b)
  local need = { "Region", "ownerPawn", "buildings", "Resources", "onFire", "Data", "buildingFunction", "upgradesDone", "Inventory", "Carts", "typeBeforeChange", "isBeingUpgraded" }
  for _, n in ipairs(need) do if not P[n] then return nil, "no reflected property " .. n end end
  local D = structProps(P.Data)
  if not D.constructed then return nil, "no Data.constructed" end
  local f = {
    { "rawT", string.format("i%X", P.Data.off) },            -- the type GetType names (checked against it below)
    { "tbc", string.format("%s%X", P.typeBeforeChange.kind == "IntProperty" and "i" or "u", P.typeBeforeChange.off) },
    { "own", string.format("p%X", P.ownerPawn.off) },
    { "reg", string.format("p%X", P.Region.off) },
    { "fn", string.format("%s%X", P.buildingFunction.kind == "IntProperty" and "i" or "u", P.buildingFunction.off) },
    { "fire", boolSpec(P.onFire) },
    { "cons", boolSpec(D.constructed, P.Data.off) },
    { "upg", boolSpec(P.isBeingUpgraded) },
    { "nB", string.format("n%X", P.buildings.off) },
    { "nR", string.format("n%X", P.Resources.off) },
    { "nC", string.format("n%X", P.Carts.off) },
    { "ups", string.format("a%X:10:%X", P.upgradesDone.off, N.upStride or 1), "a" },   -- element size 1, or 4 after a refusal on it
    { "inv", string.format("g%X:18", P.Inventory.off), "g" },
  }
  return f
end

-- ---------------------------------------------------------------- tables (Lua side)
local TABS = {}
N.tabs = TABS
local function newTab(id, fields)
  local T = { id = id, fields = fields, by = {}, list = {}, dirty = true, ver = 0, needFull = false, n = 0 }
  TABS[id] = T
  return T
end

-- snap_out.bin, read right after each native tick (coop_patch.lua P.tick)
local readBody
function N.read()
  if not N.want then return end
  local ok, e = pcall(readBody)
  if not ok then
    -- an answer that could not be read (it should not happen: the native piece and this parser are tested together):
    -- every table asks for a whole answer again, and its records wait for it
    bump("readErr")
    if (N.stats.readErr or 0) <= 3 then log("an answer of the native piece could not be read (%s): a whole answer is asked", tostring(e)) end
    for _, T in pairs(TABS) do T.needFull = true end
    N.seq = nil; local P = patch(); if P then P.send("SNAP FULL") end
  end
end
readBody = function()
  local P = patch(); if not P then return end
  local f = N.fh
  if not f then
    if os.clock() - (N.fhT or -10) < 1.0 then return end
    N.fhT = os.clock()
    f = io.open(P.dir .. "snap_out.bin", "rb"); N.fh = f
    if f then f:setvbuf("no") end            -- unbuffered: the C library keeps a read buffer across seek (s6: the first answer read again and again)
    if not f then return end
  end
  f:seek("set", 0)
  local h = f:read(20)
  if not h or #h < 20 then return end
  local magic, seq, prev, len, nt = unpack("<c4I4I4I4I4", h)
  if magic ~= "SNP1" or seq == N.seq then if N.state == "check" then N.verify() end; if N.ustate == "check" and N.S then N.uverify(N.S) end; if N.rstate == "check" and N.S then N.rverify(N.S) end; return end
  local missed = N.seq ~= nil and prev ~= N.seq
  N.seq = seq
  local body = f:read(len - 20) or ""
  if #body < len - 20 then N.seq = nil; return end
  bump("answers")
  local pos = 1
  for _ = 1, nt do
    local id, full, nf, cnt, nch, ngone
    id, full, nf, cnt, nch, ngone, pos = unpack("<BBI2I4I4I4", body, pos)
    local T = TABS[id]
    if T == nil or #T.fields ~= nf then bump("unknownTable"); return end   -- a table this side does not know: its records cannot be read
    local skip = (missed or T.needFull) and full == 0
    if T and skip and full == 0 then T.needFull = true; if not N.askedFull then N.askedFull = true; P.send("SNAP FULL") end end
    if full == 1 and T and not skip then T.needFull = false; N.askedFull = false end
    for _ = 1, nch do
      local a, idx, lpos, ver
      a, idx, lpos, ver, pos = unpack("<I8I4I4I4", body, pos)
      local r
      if not skip then
        r = T.by[a]
        if not r or r.idx ~= idx then r = { a = a, idx = idx, inv = {} }; T.by[a] = r; T.dirty = true end
        if r.pos ~= lpos then r.pos = lpos; T.dirty = true end
        r.ver = ver
      end
      -- every field's 8 bytes first (a list field: its count), then the uint8 list, then the goods lists in field order
      for k = 1, nf do
        local fd = T.fields[k]
        local v; v, pos = unpack(fd[4] == "d" and "<d" or "<i8", body, pos)
        if r then if fd[3] then r[fd[1] .. "N"] = v else r[fd[1]] = v end end
      end
      for k = 1, nf do
        local fd = T.fields[k]
        if fd[3] == "a" then
          local n; n, pos = unpack("<I2", body, pos)
          if r then
            if n == 0 then r[fd[1]] = "" else local t = { string.byte(body, pos, pos + n - 1) }; r[fd[1]] = table.concat(t, ".") end
          end
          pos = pos + n
        end
      end
      for k = 1, nf do
        local fd = T.fields[k]
        if fd[3] == "G" then                       -- the records in their order, as the job board writes a load: "<type>x<amount>+..." or "0"
          local n; n, pos = unpack("<I2", body, pos)
          if r then
            if n == 0 then r[fd[1]] = "0"
            else
              local t, q = {}, pos
              for i = 1, n do local g, am; g, am, q = unpack("<i4i4", body, q); t[i] = g .. "x" .. am end
              r[fd[1]] = table.concat(t, "+")
            end
          end
          pos = pos + 8 * n
        elseif fd[3] == "g" then
          local n; n, pos = unpack("<I2", body, pos)
          if r then
            local inv = r[fd[1]]; if type(inv) ~= "table" then inv = {}; r[fd[1]] = inv end
            for g in pairs(inv) do inv[g] = nil end
            local q = pos
            for _ = 1, n do local g, am; g, am, q = unpack("<i4i4", body, q); if am ~= 0 then inv[g] = (inv[g] or 0) + am end end
          end
          pos = pos + 8 * n
        end
      end
      if r then
        local t = r.rawT; if t == 75 and r.tbc and r.tbc > 0 and r.tbc ~= 75 then t = r.tbc end
        r.t = t
        r.fire = r.fire == 1; r.cons = r.cons == 1; r.upg = r.upg == 1
      end
    end
    for _ = 1, ngone do
      local a; a, pos = unpack("<I8", body, pos)
      if not skip and T.by[a] then T.by[a] = nil; T.dirty = true end
    end
    if T and not skip then T.n = cnt; T.ver = T.ver + 1 end
  end
  if N.state == "check" then N.verify() end
  if N.ustate == "check" and N.S then N.uverify(N.S) end
  if N.rstate == "check" and N.S then N.rverify(N.S) end
end

-- the frame's snapshot: the native piece's coop_snap_tick (the tables and the crash guard, nothing else), then its
-- answer; called by the core at the start of each frame, before any module (coop.lua)
function N.frame()
  local P = patch(); if not P then return end
  if N.sfn == nil then
    local fn = package.loadlib(P.dll, "coop_snap_tick")
    N.sfn = fn or false
    if not fn then log("the native piece has no coop_snap_tick (an older DLL): reflected reads stay") end
  end
  if not N.sfn then return end
  if not (N.want or N.guardFor) then return end
  -- (round two) the tables ten times a second (they cost the native piece 60 to 100 us a read; at 60 frames a second
  -- every frame was 4 to 6 ms a second): a module reads values at most 0.1 s old; the crash guard every frame, alone
  -- (coop_guard_tick), as before; while a table is being checked, every frame (the check reads right after it)
  local t = os.clock()
  local checking = N.state == "check" or N.rstate == "check"
  if checking or t - (N.tabT or -1) >= 0.1 then
    N.tabT = t
    pcall(N.sfn)
    if N.want then N.read() end
  else
    if N.gfn == nil then N.gfn = package.loadlib(P.dll, "coop_guard_tick") or false end
    if N.gfn then pcall(N.gfn) else pcall(N.sfn) end
  end
end

local function ordered(T)
  if T.dirty then
    local L = T.list; for i = #L, 1, -1 do L[i] = nil end
    for _, r in pairs(T.by) do L[#L + 1] = r end
    table.sort(L, function(x, y) return x.pos < y.pos end)
    T.dirty = false
  end
  return T.list
end

-- the building records in the engine's list order, or nil (not checked, refused, switched off for a test)
function N.buildings()
  if N.test.off or N.state ~= "ok" then return nil end
  local T = TABS[0]; if not T or T.needFull then return nil end
  return ordered(T)
end
function N.building(a) if N.test.off or N.state ~= "ok" then return nil end; local T = TABS[0]; if not T or T.needFull then return nil end; return T.by[a] end
-- the object of a record: the engine's list at its place, the address compared; nil when it is not there
-- (round two) the object is taken from the engine's list anew at every call, never kept from an earlier frame: a handle
-- kept across frames could name an object the engine freed since (sitting p2: a friend's game closed inside the mod
-- loader at the test's forced engine clean-up, after a rival building's upgrade)
function N.obj(r)
  local S = C.s; if not (S and S.eng) then return nil end
  local ok, b = pcall(function() local arr = S.eng.buildingArr; if r.pos < 0 or r.pos + 1 > #arr then return nil end; return un(arr[r.pos + 1]) end)
  if ok and b and addr(b) == r.a then return b end
  -- not at its place (the list moved since the answer): the list's places by address, made at most once a frame
  if N.pmT ~= S.ticks then
    N.pmT = S.ticks; local pm = {}; N.pm = pm
    pcall(function() local arr = S.eng.buildingArr; for i = 1, #arr do local x = un(arr[i]); local a = x and addr(x); if a then pm[a] = i end end end)
  end
  local i = N.pm and N.pm[r.a]
  if not i then return nil end
  local okS, hit = pcall(function() local arr = S.eng.buildingArr; if i > #arr then return nil end; return un(arr[i]) end)
  if okS and hit and addr(hit) == r.a then return hit end
  return nil
end
-- place and turn by the game's own calls, once per building
function N.loc(r)
  if r.lx and r.locIdx == r.idx then return r.lx, r.ly, r.lz, r.yaw end
  local b = N.obj(r); if not b then return nil end
  local l = b:K2_GetActorLocation(); local yaw = b:K2_GetActorRotation().Yaw
  r.lx, r.ly, r.lz, r.yaw, r.locIdx = l.X, l.Y, l.Z, yaw, r.idx
  return r.lx, r.ly, r.lz, r.yaw
end

-- ---------------------------------------------------------------- the check against the reflected reads
local function upsOf(b)
  local t = {}; local a = b.upgradesDone
  for i = 1, #a do local v = a[i]; if type(v) ~= "number" then v = v:get() end; t[#t + 1] = math.floor(tonumber(v) or -1) end
  return table.concat(t, ".")
end
local function invOf(b)
  local t = {}; local a = b.Inventory
  for i = 1, #a do local x = un(a[i]); local g, am = x.Type, x.amt; if type(g) == "number" and type(am) == "number" and am ~= 0 then t[g] = (t[g] or 0) + am end end
  return t
end
-- the record against its building now: nil when equal, else the first field that differs
local function differs(r, b)
  local function a0(o) if not valid(o) then return 0 end; return addr(o) or 0 end
  if r.rawT ~= b:GetType() then return "type" end
  if r.t ~= A.btype(b) then return "btype" end
  if r.own ~= a0(b.ownerPawn) then return "ownerPawn" end
  if r.reg ~= a0(b.Region) then return "Region" end
  if r.fn ~= (tonumber(b.buildingFunction) or -1) then return "buildingFunction" end
  if r.fire ~= (b.onFire and true or false) then return "onFire" end
  if r.cons ~= (b.Data.constructed and true or false) then return "Data.constructed" end
  if r.upg ~= (b.isBeingUpgraded and true or false) then return "isBeingUpgraded" end
  if r.nB ~= #b.buildings then return "buildings" end
  if r.nR ~= #b.Resources then return "Resources" end
  if r.nC ~= #b.Carts then return "Carts" end
  if r.ups ~= upsOf(b) then return "upgradesDone" end
  local inv = invOf(b)
  for g, v in pairs(inv) do if r.inv[g] ~= v then return "Inventory" end end
  for g, v in pairs(r.inv) do if inv[g] ~= v then return "Inventory" end end
  return nil
end
N.differs = differs

-- console: the whole table against the reflected reads now
function N.shadow()
  local T = TABS[0]; if not T then return "no table" end
  local n, bad, miss, why = 0, 0, 0, {}
  for _, r in ipairs(ordered(T)) do
    local b = N.obj(r)
    if not b or not valid(b) then miss = miss + 1
    else
      n = n + 1
      local ok, d = pcall(differs, r, b)
      if not ok then d = "error " .. tostring(d) end
      if d then bad = bad + 1; why[d] = (why[d] or 0) + 1 end
    end
  end
  local t = {}; for k, v in pairs(why) do t[#t + 1] = k .. "=" .. v end
  local okC, cnt = pcall(function() return #C.s.eng.buildingArr end)
  return string.format("%d records compared, %d differing (%s), %d without object; engine list %s, table %d", n, bad, table.concat(t, " "), miss, tostring(okC and cnt), T.n)
end

-- ---------------------------------------------------------------- per world
-- ---------------------------------------------------------------- the unit table (table 2: the engine's unitArr)
-- for the job board's looks (coop_x_jobs.lua, lane 47 adapter): a unit's task count, its first task's type, target
-- place x, target building, final building, target unit, and its load ("<type>x<amount>+..." or "0")
local function innerStruct(e)                 -- an ArrayProperty of structs: the struct's properties
  local t = {}
  e.p:GetInner():GetStruct():ForEachProperty(function(p)
    t[p:GetFName():ToString()] = { off = p:GetOffset_Internal(), kind = p:GetClass():GetFName():ToString(), p = p }
  end)
  return t
end
local function unitSpec(u)
  local P = propsOf(u)
  if not (P.Tasks and P.Inventory) then return nil, "no reflected Tasks or Inventory" end
  local T = innerStruct(P.Tasks)
  for _, n in ipairs({ "Type", "TargetLocation", "targetBuilding", "finalBuilding", "targetUnit" }) do if not T[n] then return nil, "no Task." .. n end end
  local L = structProps(T.TargetLocation); if not L.Pos then return nil, "no TargetLocation.Pos" end
  local V = structProps(L.Pos); if not V.X then return nil, "no Pos.X" end
  local tk = P.Tasks.off
  local tyk = (T.Type.kind == "IntProperty") and "e" or "h"
  return {
    { "tn", string.format("n%X", tk) },
    { "tty", string.format("%s%X:%X", tyk, tk, T.Type.off) },
    { "tx", string.format("x%X:%X", tk, T.TargetLocation.off + L.Pos.off + V.X.off), nil, "d" },
    { "ttb", string.format("r%X:%X", tk, T.targetBuilding.off) },
    { "tfb", string.format("r%X:%X", tk, T.finalBuilding.off) },
    { "ttu", string.format("r%X:%X", tk, T.targetUnit.off) },
    { "hands", string.format("g%X:18", P.Inventory.off), "G" },
  }
end
local function handsLive(u)
  local a = u.Inventory; local n = #a
  if n == 0 then return "0" end
  local s = {}
  for i = 1, n do local x = a[i]; s[#s + 1] = tostring(math.tointeger(x.Type) or x.Type) .. "x" .. tostring(math.tointeger(x.amt) or x.amt) end
  return table.concat(s, "+")
end
local function a0(o) if o == nil then return 0 end; local ok, x = pcall(function() return o:GetAddress() end); return (ok and x) or 0 end
local function unitDiffers(r, u)
  local ts = u.Tasks; local n = #ts
  if r.tn ~= n then return "Tasks count" end
  if n > 0 then
    local t = ts[1]
    if r.tty ~= (tonumber(t.Type) or -1) then return "Task.Type" end
    if r.tx ~= t.TargetLocation.Pos.X then return "Task.TargetLocation.Pos.X" end
    if r.ttb ~= a0(t.targetBuilding) then return "Task.targetBuilding" end
    if r.tfb ~= a0(t.finalBuilding) then return "Task.finalBuilding" end
    if r.ttu ~= a0(t.targetUnit) then return "Task.targetUnit" end
  end
  if r.hands ~= handsLive(u) then return "Inventory (hands)" end
  return nil
end
N.unitDiffers = unitDiffers
-- a unit's record (nil while the unit table is not checked, refused, or switched off for a test)
function N.unit(a)
  if N.test.off or N.test.unitsOff or N.ustate ~= "ok" then return nil end
  local T = TABS[2]; if not T or T.needFull then return nil end
  return T.by[a]
end
-- 40 units against the reflected reads, a few a frame, right after the native tick (as the buildings)
function N.uverify(S)
  if N.ustate ~= "check" then return end
  local T = TABS[2]; if not T or T.n == 0 or T.needFull then return end
  local P = patch(); if not P then return end
  local okA, arr = pcall(function() return S.eng.unitArr end); if not okA or not arr then return end
  N.ui = N.ui or 0; N.un = N.un or 0
  local n = #arr; local k = 0
  while k < 6 and N.un < 40 and N.ui < n do
    N.ui = N.ui + 1; k = k + 1
    local u = un(arr[N.ui])
    if valid(u) then
      local r = T.by[addr(u) or 0]
      if r then
        local ok, d = pcall(unitDiffers, r, u)
        if not ok then d = "error " .. tostring(d) end
        if d then
          N.ustate = "refused"
          log("unit table REFUSED: unit %s differs from the reflected read in %s: the job board reads as before", hex(r.a), d)
          P.send("SNAP TABLE 2 OFF")
          return
        end
        N.un = N.un + 1
      end
    end
  end
  if N.un >= 40 or (N.ui >= n and N.un >= 5) then N.ustate = "ok"; log("unit table checked against the reflected reads: %d units equal; the job board reads it from now on", N.un)
  elseif N.ui >= n then N.ustate = "refused"; log("unit table: only %d units found in it: the job board reads as before", N.un) end
end
local function unitsAsk(S, P)
  local u
  pcall(function() local arr = S.eng.unitArr; for i = 1, math.min(#arr, 200) do local x = un(arr[i]); if valid(x) then local okT = pcall(function() return #x.Tasks end); if okT then u = x; break end end end end)
  if not u then N.ustate = "refused"; log("unit table not set up: no unit with Tasks"); return end
  local okF, fields, why = pcall(unitSpec, u)
  if not okF or not fields then N.ustate = "refused"; log("unit table not set up: %s", tostring(okF and why or fields)); return end
  local okE, eo = pcall(function() return propsOf(S.eng).unitArr.off end)
  if not okE or not eo then N.ustate = "refused"; log("no reflected unitArr: %s", tostring(eo)); return end
  local spec = {}; for i, fd in ipairs(fields) do spec[i] = fd[2] end
  newTab(2, fields)
  P.send(string.format("SNAP TABLE 2 %s %X %s", hex(addr(S.eng)), eo, table.concat(spec, ",")))
  N.ustate = "check"; N.ui = 0; N.un = 0
  log("unit table asked (%d fields)", #fields)
end

-- ---------------------------------------------------------------- the region table (table 1: the engine's regions)
-- a region's two goods lists, the totals and the totals minus what is reserved (Region +528h and +538h: the lists the
-- native TOTALS item already writes, coop_scan.h TOTALS_OFF / TOTALS_OFF_R; not reflected): checked against the game's
-- own Region:getStockOfGood(g, false / true, false) for every good 0..511 of every region before any module uses them
local REG_TOT, REG_RES = 0x528, 0x538
local function regionsAsk(S, P)
  local okE, eo = pcall(function() return propsOf(S.eng).regions.off end)
  if not okE or not eo then N.rstate = "refused"; log("no reflected regions: %s", tostring(eo)); return end
  local fields = { { "tot", string.format("g%X:18", REG_TOT), "g" }, { "res", string.format("g%X:18", REG_RES), "g" } }
  local spec = {}; for i, fd in ipairs(fields) do spec[i] = fd[2] end
  newTab(1, fields)
  P.send(string.format("SNAP TABLE 1 %s %X %s", hex(addr(S.eng)), eo, table.concat(spec, ",")))
  N.rstate = "check"; N.rq = nil
  log("region table asked")
end
-- 64 game calls a frame: region by region, good by good, both lists
function N.rverify(S)
  if N.rstate ~= "check" then return end
  local T = TABS[1]; if not T or T.n == 0 or T.needFull then return end
  local P = patch(); if not P then return end
  if not N.rq then
    N.rq = { list = {}, i = 1, g = 0 }
    -- only the regions the world module itself asks (the player's own, the rival lords' towns): getStockOfGood on any
    -- other region is a call the mod never made before (s2: a friend's game closed while every region was asked)
    local me = addr(S.p1); local W = rawget(C, "world")
    pcall(function() local arr = S.eng.regions; for i = 1, #arr do local r = un(arr[i]); if valid(r) then
      local own = valid(r.ownerPawn) and addr(r.ownerPawn) == me
      local rv = (not own) and W and W.rivalTown and W.rivalTown(r)
      if own or rv then N.rq.list[#N.rq.list + 1] = r; N.rok = N.rok or {}; N.rok[addr(r)] = true end
    end end end)
    N.rn = 0
  end
  local Q = N.rq; local k = 0
  while Q.i <= #Q.list and k < 64 do
    local r = Q.list[Q.i]
    local rec = valid(r) and T.by[addr(r) or 0]
    if not rec then Q.i = Q.i + 1; Q.g = 0
    else
      local g = Q.g
      local ok, v = pcall(function() return r:getStockOfGood(g, false, false) end); local w = "-"
      k = k + 2
      if not ok then N.rstate = "refused"; log("region table: getStockOfGood failed (%s): the world module reads as before", tostring(v)); P.send("SNAP TABLE 1 OFF"); return end
      if v ~= (rec.tot[g] or 0) or math.type(v) ~= "integer" then   -- (the totals only: the reserved amounts are not taken from the table)
        N.rstate = "refused"
        log("region table REFUSED: region %s good %d: game %s / %s, table %s / %s: the world module reads as before", hex(rec.a), g, tostring(v), tostring(w), tostring(rec.tot[g]), tostring(rec.res[g]))
        P.send("SNAP TABLE 1 OFF")
        return
      end
      Q.g = g + 1
      if Q.g > 511 then Q.i = Q.i + 1; Q.g = 0; N.rn = N.rn + 1 end
    end
  end
  if Q.i > #Q.list then
    if N.rn > 0 then N.rstate = "ok"; log("region table checked against getStockOfGood: %d regions, goods 0..511 equal; the host's region passes read it from now on", N.rn)
    else N.rstate = "refused"; log("region table: no region found in it") end
  end
end
-- a region's amount of good g (reserved: the list minus what is reserved), or nil (no table: the caller asks the game)
function N.regionStock(r, g, reserved)
  if N.test.off or N.test.regionsOff or N.rstate ~= "ok" then return nil end
  local T = TABS[1]; if not T or T.needFull then return nil end
  local ra = addr(r) or 0
  if not (N.rok and N.rok[ra]) then return nil end                 -- a region that was not checked
  local rec = T.by[ra]; if not rec then return nil end
  if (rec.totN or 0) > 160 or (rec.resN or 0) > 160 then return nil end      -- more records than the table keeps
  -- the reserved amount is the game's own call always: getStockOfGood(g, true) is not a plain read of the list at
  -- +538h (s3: the game 0 where the list held -2; s6: -13 and -13), so only the totals come from the table
  if reserved then return nil end
  return rec.tot[g] or 0
end

local function reset(S)
  if N.fh then pcall(io.close, N.fh); N.fh = nil end
  for id in pairs(TABS) do TABS[id] = nil end
  N.S = S; N.world = S.worlds; N.state = "start"; N.seq = nil; N.askedFull = false; N.want = false
  N.vq = nil; N.guardFor = nil; N.uoaOk = false; N.t0 = os.clock(); N.tries = 0; N.ustate = nil; N.ui = 0; N.un = 0; N.rstate = nil; N.rq = nil; N.rok = nil
end

local function statusOf()
  local P = patch(); if not P then return nil end
  local st = P.status(); return st and st.items or nil, st
end

local function step(S, clock)
  local P = patch()
  if not P then return end
  if N.world ~= S.worlds or N.S ~= S then reset(S) end
  if N.state == "refused" or N.state == "unavailable" then return end
  local items, st = statusOf()
  if not st or st.state ~= "ready" then return end
  local it = items and items.SNAP
  if N.state == "start" then
    if N.sfn == false then N.state = "unavailable"; return end
    if not it then N.state = "unavailable"; log("the native piece has no SNAP item (an older DLL): reflected reads stay"); return end
    if it.state == "unavailable" then N.state = "unavailable"; log("SNAP unavailable (%s): reflected reads stay", tostring(it.why)); return end
    if clock - N.t0 < 2.0 then return end                       -- the world's first moments: the engine's lists settle
    local p1, eng = S.p1, S.eng
    if not (valid(p1) and valid(eng)) then return end
    local list = { hex(addr(eng)), hex(addr(p1)) }
    pcall(function() local arr = eng.buildingArr; for i = 1, math.min(#arr, 6) do local b = un(arr[i]); if valid(b) then list[#list + 1] = hex(addr(b)) end end end)
    P.send("SNAP UOA " .. table.concat(list, ",")); P.send("STATUS")
    N.state = "uoa"; N.tS = clock
    return
  end
  if N.state == "uoa" then
    if it and it.state == "on" then
      N.uoaOk = true
      -- the building table, its fields from the reflected properties of one building
      local b
      pcall(function() local arr = S.eng.buildingArr; for i = 1, #arr do local x = un(arr[i]); if valid(x) then b = x; break end end end)
      if not b then return end
      local okF, fields, why = pcall(buildingSpec, b)
      if not okF or not fields then N.state = "refused"; log("building table not set up: %s", tostring(okF and why or fields)); return end
      local okE, eo = pcall(function() return propsOf(S.eng).buildingArr.off end)
      if not okE or not eo then N.state = "refused"; log("no reflected buildingArr: %s", tostring(eo)); return end
      local spec = {}; for i, fd in ipairs(fields) do spec[i] = fd[2] end
      newTab(0, fields)
      N.want = true
      P.send(string.format("SNAP TABLE 0 %s %X %s", hex(addr(S.eng)), eo, table.concat(spec, ",")))
      N.guardSet(S)
      -- (the unit table, table 2, for the job board is NOT asked: in sittings s2 to s5 with it a friend's game closed in
      -- the game's own unit update, SMUnit::proximityAction, reading a null building; s6 without it ran clean. Its
      -- code stays below for the next lane, unused: N.unit answers nil)
      if not N.test.regionsOff then pcall(regionsAsk, S, P) end
      P.send("STATUS")
      N.state = "check"; N.vq = nil; N.tS = clock
      log("building table asked (%d fields); the crash guard handed to the native piece", #fields)
    elseif clock - N.tS > 5.0 then N.state = "refused"; log("SNAP UOA not confirmed in 5 s (%s %s): reflected reads stay", tostring(it and it.state), tostring(it and it.why)) end
    return
  end
  if N.state == "check" then
    local T = TABS[0]
    if not T or T.n == 0 or T.needFull then
      if clock - N.tS > 10.0 then
        N.tries = (N.tries or 0) + 1
        if N.tries <= 2 then N.state = "uoa"; N.tS = clock; log("no building table from the native piece in 10 s (%s): asked again", tostring(it and it.why))
        else N.state = "refused"; log("no building table from the native piece in 10 s, three times (%s): reflected reads stay", tostring(it and it.why)) end
      end
      return
    end
    -- the check itself runs right after the native tick (N.verify, from N.read): no game code and no other module
    -- ran in between, so a value that differs is a wrong offset, not a change
  end
end

-- a few buildings a frame against the reflected reads, right after the answer was read (N.read)
function N.verify()
  if N.state ~= "check" then return end
  local T = TABS[0]
  if not T or T.n == 0 or T.needFull then return end
  local P = patch(); if not P then return end
  if not N.vq then N.vq = {}; for _, r in ipairs(ordered(T)) do N.vq[#N.vq + 1] = r.a end; N.vi = 0; N.vn = 0 end
  local k = 0
  while N.vi < #N.vq and k < 6 do
    N.vi = N.vi + 1; k = k + 1
    local r = T.by[N.vq[N.vi]]
    local b = r and N.obj(r)
    if r and b and valid(b) then
      local ok, d = pcall(differs, r, b)
      if not ok then d = "error " .. tostring(d) end
      if d == "upgradesDone" and (N.upStride or 1) == 1 then
        -- the list's elements are not single bytes: the table is asked again with 4-byte elements (once)
        N.upStride = 4; N.state = "uoa"; N.tS = os.clock(); N.vq = nil
        log("building table: upgradesDone differs with 1-byte elements: asked again with 4-byte elements")
        return
      end
      if d then
        N.state = "refused"
        log("building table REFUSED: building %s (type %s) differs from the reflected read in %s: every module reads as before", hex(r.a), tostring(r.t), d)
        P.send("SNAP TABLE 0 OFF")      -- (the unit and region tables are still read)
        return
      end
      N.vn = N.vn + 1
    end
  end
  if N.vi >= #N.vq then
    N.state = "ok"
    log("building table checked against the reflected reads: %d buildings equal; modules read it from now on", N.vn)
  end
end

-- ---------------------------------------------------------------- the crash guard (the core's C.scrubClose)
function N.guardSet(S)
  local P = patch(); if not P then return end
  local okO, off = pcall(function() return propsOf(S.p1).closeBuildings.off end)
  if not okO or not off then log("crash guard stays in Lua: no reflected closeBuildings"); return end
  local p, h = addr(S.p1), (S.hp and valid(S.hp)) and addr(S.hp) or 0
  if not p then return end
  P.send(string.format("SNAP GUARD %s %s %X", hex(p), hex(h or 0), off)); P.send("STATUS")
  N.guardFor = { p = p, h = h or 0, t = os.clock() }
end
-- true when the native guard holds this lord and this helper now (the Lua guard then does nothing)
function N.guardOn(S)
  if N.test.off or N.test.guardOff or not N.sfn then return false end   -- (no snapshot tick: nothing would run the guard)
  local g = N.guardFor
  if not g then
    -- not handed over (switched off by the dev file, or refused): asked again at most every 5 s once SNAP is checked
    if (N.state == "check" or N.state == "ok" or N.state == "refused") and N.uoaOk and os.clock() - (N.gAsk or 0) >= 5.0 then N.gAsk = os.clock(); N.guardSet(S) end
    return false
  end
  local items = statusOf()
  local it = items and items.GUARD
  if not it or it.state ~= "on" then return false end
  -- the lord or the helper changed (a new helper made, a world): handed over again; until it is confirmed the Lua guard runs
  local t = os.clock()
  -- every frame (1 us): a helper made since the hand-over (or another lord) is handed over again, and the Lua guard
  -- runs until the native piece confirms it (the helper's list must be empty from its first frame)
  local p, h = addr(S.p1), (S.hp and valid(S.hp)) and addr(S.hp) or 0
  if p ~= g.p or h ~= g.h then if t - (N.gChk or 0) >= 0.2 then N.gChk = t; N.guardSet(S) end; return false end
  if t - g.t < 0.6 then return false end                         -- the status of the hand-over is not read yet
  -- the counters of the native guard into the mod's stats and log (the Lua guard's lines)
  local fx = tonumber((it.why or ""):match("fixed=(%d+)")) or 0
  local em = tonumber((it.why or ""):match("emptied=(%d+)")) or 0
  local hp = tonumber((it.why or ""):match("helper=(%d+)")) or 0
  local S2 = C.s
  if S2 and S2.stats then
    if fx > (N.gFx or 0) then S2.stats.closeFixed = (S2.stats.closeFixed or 0) + fx - (N.gFx or 0); log("crash guard (native): %d entries of the player's nearby-buildings list were gone and were replaced (total so far %d)", fx - (N.gFx or 0), fx) end
    if hp > (N.gHp or 0) then S2.stats.helperCloseEmptied = (S2.stats.helperCloseEmptied or 0) + hp - (N.gHp or 0) end
    if em > (N.gEm or 0) then log("crash guard (native): the player's list held no living entry: emptied (%d entries)", em - (N.gEm or 0)) end
  end
  N.gFx, N.gEm, N.gHp = fx, em, hp
  return true
end
function N.guardOff() local P = patch(); if P and N.guardFor then P.send("SNAP GUARD OFF"); N.guardFor = nil end end

local M = {}
function M.tick(S, clock)
  if S.role ~= "host" and S.role ~= "friend" and S.role ~= "idle" then return end
  local ok, e = pcall(step, S, clock)
  if not ok then bump("err"); if (N.stats.err or 0) <= 3 then log("step: %s", tostring(e)) end end
end
function M.onWorld(S) reset(S) end
function N.status()
  local T = TABS[0]
  return string.format("state %s, table %s records, answers %d, guard %s", tostring(N.state), T and tostring(T.n) or "-", N.stats.answers or 0, N.guardFor and "native" or "lua")
end
C.register("snap", M)
return "coop_snap loaded"
