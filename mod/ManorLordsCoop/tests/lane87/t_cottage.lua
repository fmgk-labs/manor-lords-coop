-- Lane 87 desk test (no game): the cottage pieces (lanes/lane_s21_87/design_cottage.txt), coop_x_scene.lua.
--   py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane87/t_cottage.lua
-- A piece's other mesh components (a cottage part's door) are read with it on both copies, travel in its wire item and
-- are drawn by a friend on the made actor itself. A piece without other components reads as before. Run 21 of lane 83:
-- the friend drew the host's cottage part with its root mesh only, no door.
local SCRIPTS = HERE .. "../../Scripts/"
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
local T = 100.0
os.clock = function() return T end
local function valid(o) return type(o) == "table" and not o.dead end
local nextAddr = 0x5000
local function addr() nextAddr = nextAddr + 0x40; return nextAddr end

-- made-up engine objects
local CLASS_SMC = { name = "StaticMeshComponent" }
local CLASS_SMA = { name = "StaticMeshActor" }
local function obj(t) t.addr = t.addr or addr(); t.GetAddress = function(self) return self.addr end; t.IsValid = function(self) return not self.dead end; return t end
local function mesh(path) return obj({ path = path, GetFullName = function(self) return "StaticMesh " .. self.path end }) end
local function mat(path) return obj({ path = path, GetFullName = function(self) return "MaterialInstanceConstant " .. self.path end }) end
local MESHES, MATS = {}, {}
local function M(path) MESHES[path] = MESHES[path] or mesh(path); return MESHES[path] end
local function MT(path) MATS[path] = MATS[path] or mat(path); return MATS[path] end
_G.StaticFindObject = function(path)
  if path == "/Script/Engine.StaticMeshComponent" then return obj(CLASS_SMC) end
  if path == "/Script/Engine.StaticMeshActor" then return obj(CLASS_SMA) end
  return MESHES[path] or MATS[path]
end
_G.LoadAsset = function(path) return MESHES[path] end
-- a mesh component: mesh, world place, turn, scale, visible
local function comp(m, L, R, Sc, vis)
  local c = obj({ StaticMesh = m and M(m) or nil, L = L, R = R or { Pitch = 0, Yaw = 0, Roll = 0 }, Sc = Sc or { X = 1, Y = 1, Z = 1 }, vis = vis ~= false,
                  bHiddenInGame = false, RuntimeVirtualTextures = {}, mats = { MT("/Game/M_" .. (m or "none"):match("([%w_]+)$")) } })
  function c:IsVisible() return self.vis end
  function c:K2_GetComponentLocation() return self.L end
  function c:K2_GetComponentRotation() return self.R end
  function c:K2_GetComponentScale() return self.Sc end
  function c:GetNumMaterials() return #self.mats end
  function c:GetMaterial(i) return self.mats[i + 1] end
  return c
end
-- a piece's actor: its root component and others
local function piece(rootMesh, L, others, yaw)
  local root = comp(rootMesh, L, { Pitch = 0, Yaw = yaw or 0, Roll = 0 })
  local a = obj({ StaticMeshComponent = root, bHidden = false, comps = { root } })
  for _, c in ipairs(others or {}) do a.comps[#a.comps + 1] = c end
  function a:K2_GetActorLocation() return self.StaticMeshComponent.L end
  function a:K2_GetActorRotation() return self.StaticMeshComponent.R end
  function a:GetActorScale3D() return { X = 1, Y = 1, Z = 1 } end
  function a:K2_GetComponentsByClass(cls) return self.comps end
  return a
end
-- the actors this module makes on a friend (SpawnActor), with AddComponentByClass
local spawned = {}
local function madeActor(L, R)
  local root = obj({ L = L, R = R })
  function root:SetMobility() end
  function root:SetStaticMesh(m) self.StaticMesh = m end
  function root:SetCollisionEnabled() end
  function root:SetMaterial(i, mt) self.mat = mt end
  local a = obj({ StaticMeshComponent = root, extra = {} })
  function a:SetActorScale3D(s) self.sc = s end
  function a:K2_SetActorRotation(r) root.R = r end
  function a:K2_DestroyActor() self.dead = true end
  function a:AddComponentByClass(cls, manual, xf, deferred)
    local c = obj({})
    function c:SetMobility() end
    function c:SetStaticMesh(m) self.StaticMesh = m end
    function c:SetCollisionEnabled() end
    function c:SetMaterial(i, mt) self.mat = mt end
    function c:K2_SetWorldLocationAndRotation(L2, R2) self.L = L2; self.R = R2 end
    function c:SetWorldScale3D(s) self.sc = s end
    a.extra[#a.extra + 1] = c
    return c
  end
  spawned[#spawned + 1] = a
  return a
end

local sent, logs = {}, {}
local S = { role = "host", worlds = 1, loads = 1, eng = { buildingArr = {} }, p1 = obj({}) }
S.p1.GetWorld = function() return { SpawnActor = function(_, cls, L, R) return madeActor(L, R) end } end
local C = { s = S, modules = {} }
_G.Coop = C
function C.register(name, m) C.modules[name] = m; return m end
C.api = { un = function(x) return x end, valid = valid, btype = function(b) return b.t end, now = function() return 2000 end,
          log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function(l) sent[#sent + 1] = l end }
assert(loadfile(SCRIPTS .. "coop_x_scene.lua"))()
local Q, MOD = C.scene, C.modules.scene
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 250 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name and v ~= nil then return v end end
  for i = 1, 250 do
    local n, v = debug.getupvalue(fn, i); if not n then break end
    if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
  end
end
local readRec = assert(upvalue(MOD.tick, "readRec"), "readRec")
local wireOf = assert(upvalue(MOD.tick, "wireOf"), "wireOf")
local plan = assert(upvalue(MOD.tick, "plan"), "plan")
local doAct = assert(upvalue(MOD.tick, "doAct"), "doAct")
local parseItem = assert(upvalue(MOD.onMessage, "parseItem"), "parseItem")
MOD.onWorld(S)

print("[1. a piece's other mesh components are read with it]")
local B = { X = 95310, Y = 76630, Z = 1000 }                       -- the building's place (cm)
local DOOR = "/Game/ManorLords/Buildings/Doors/UDoor_Poor_110x170_A.UDoor_Poor_110x170_A"
local PART = "/Game/ManorLords/Buildings/Cottage/SM_MERGED_C_SG_Cottage_LV1_BPart_B_UBeam.SM_MERGED_C_SG_Cottage_LV1_BPart_B_UBeam"
local STONE = "/Game/ManorLords/Props/Small_Stones_Pack.Small_Stones_Pack"
local socket = comp(nil, { X = 95310, Y = 76630, Z = 1000 })        -- "socketMesh": no mesh
local door = comp(DOOR, { X = 95310 + 208, Y = 76630 + 114, Z = 1000 + 35 }, { Pitch = 0, Yaw = -114, Roll = 0 }, { X = 0.85, Y = 1.01, Z = 0.95 })
local part = piece(PART, { X = 95310 + 12, Y = 76630 - 40, Z = 1000 }, { socket, door }, 156)
local rec = readRec(part, part.StaticMeshComponent, B)
check(rec and rec.s == PART .. ":12:-40:0:156|" .. DOOR .. ":208:114:35:~:85:101:95", "the part's text holds its door: mesh, place and scale from the building's origin; a door's turn is not matched (" .. tostring(rec and rec.s) .. ")")
check(rec and rec.x and rec.x[1].t == "208:114:35:246:0:0:85:101:95", "... its whole tail, turn included, kept for drawing")
-- the door swings (a villager): the piece reads the same, so a friend does not hide its own part for it
door.R = { Pitch = 0, Yaw = -24, Roll = 0 }
local recSw = readRec(part, part.StaticMeshComponent, B)
check(recSw and recSw.s == rec.s, "a swung door: the same text (the turn of a door or a tool is not matched)")
door.R = { Pitch = 0, Yaw = -114, Roll = 0 }
check(rec and rec.nx == 1 and rec.x and #rec.x == 1, "one other component with a mesh (the socket without a mesh is not one)")
door.vis = false
local recH = readRec(part, part.StaticMeshComponent, B)
check(recH and recH.s == PART .. ":12:-40:0:156" and recH.nx == 1, "a hidden other component is not drawn: the text is the root's alone, nx still 1 (read again later)")
door.vis = true
local stone = piece(STONE, { X = 95310 - 100, Y = 76630 + 5, Z = 1000 })
local recS = readRec(stone, stone.StaticMeshComponent, B)
check(recS and recS.s == STONE .. ":-100:5:0:0" and recS.nx == 0 and recS.x == nil, "a piece with no other component reads as before (the same text and hash as before lane 87)")

-- a dynamic material (made at run time: no path of its own) names its parent
local parent = mat("/Game/ManorLords/Buildings/CommonAssets/Doors/MI_Door.MI_Door"); MATS[parent.path] = parent
local mid = obj({ Parent = parent, GetFullName = function() return "MaterialInstanceDynamic /Engine/Transient.MaterialInstanceDynamic_17" end })
local DOOR2 = "/Game/ManorLords/Buildings/Doors/UDoor_Rich_A.UDoor_Rich_A"
local door2 = comp(DOOR2, { X = 95310 + 50, Y = 76630 + 60, Z = 1000 }); door2.mats = { mid }
local part2 = piece(PART, { X = 95310 + 30, Y = 76630 + 30, Z = 1000 }, { door2 })
local rec2 = readRec(part2, part2.StaticMeshComponent, B)
check(rec2 and Q.matsOf[DOOR2] == parent.path, "a dynamic material is named by its parent's path (" .. tostring(Q.matsOf[DOOR2]) .. "), not '-' (which a friend cannot draw)")

print("[2. on the wire and back]")
local e = { n = 1, m = rec.m, t = rec.t, x = rec.x }
local it = wireOf(e)
check(it:match("^%d+:12:%-40:0:156|%d+:208:114:35:246:0:0:85:101:95$") ~= nil, "the wire item: root and door, each by its mesh number, the door with its turn (" .. it .. ")")
local itS = wireOf({ m = recS.m, t = recS.t })                      -- (the stone's item, made on the host too)
local nM = 0; for _, l in ipairs(sent) do if l:find("^Q M ") then nM = nM + 1 end end
check(nM == 3, "each mesh named by a Q M line once: part, door, stone (" .. nM .. ")")
-- the friend: the Q M lines, then the item
S.role = "friend"
for _, l in ipairs(sent) do
  local w = {}; for x in l:gmatch("%S+") do w[#w + 1] = x end
  table.insert(w, 1, "0"); table.insert(w, 1, "1")            -- the core's "<seq> <wallclock>"
  MOD.onMessage(S, "host", "Q", w, l)
end
local s2, m2, t2, x2 = parseItem(it)
check(s2 == rec.s and m2 == PART and t2 == rec.t and x2 and #x2 == 1 and x2[1].m == DOOR, "the friend reads the item back into the host's text (mesh paths)")
local sOld = parseItem(itS)
check(sOld == recS.s, "an item without other components reads as before")
local sBad, miss = parseItem("99:1:2:3:4|98:5:6:7:8")
check(sBad == nil and miss and #miss == 2, "mesh numbers not known here: nothing, and both asked for")

print("[3. a friend draws the piece with its door on one made actor]")
local key = "3@9531,7663"
Q.hostCnt[key] = { [rec.s] = { n = 1, m = rec.m, t = rec.t, x = rec.x } }
local Bd = { slots = {}, n = 0 }
local acts = plan(key, Bd)
check(acts and #acts == 1 and acts[1][1] == "make" and acts[1][6] and #acts[1][6] == 1, "the plan: make the piece, its door with it")
-- resolve() finds the building by its key in the engine's list
local bld = obj({ t = 3, x = 95310, y = 76630, buildings = {}, Resources = {} })
function bld:K2_GetActorLocation() return { X = 95310, Y = 76630, Z = 1000 } end
S.eng.buildingArr[1] = bld
Q.hint[key] = 1
doAct(S, acts[1], 2)
local a = spawned[#spawned]
check(a and a.StaticMeshComponent.StaticMesh == M(PART), "the made actor holds the part's mesh")
check(a and #a.extra == 1 and a.extra[1].StaticMesh == M(DOOR), "... and the door as a second component of that same actor")
local dc = a and a.extra[1]
check(dc and dc.L.X == 95310 + 208 and dc.L.Y == 76630 + 114 and dc.L.Z == 1000 + 35 and dc.R.Yaw == 246, "the door at its place and turn from the building's origin (the host's turn of its read)")
check(dc and math.abs(dc.sc.X - 0.85) < 1e-9 and math.abs(dc.sc.Y - 1.01) < 1e-9 and math.abs(dc.sc.Z - 0.95) < 1e-9, "the door's scale")
check((Q.stats.madeExtra or 0) == 1 and (Q.stats.extraFail or 0) == 0, "counted madeExtra 1, extraFail 0")
check(Q.made[key] and #Q.made[key] == 1 and Q.made[key][1].s == rec.s, "one made entry, under the piece's whole text")
-- the friend's own identical piece (door and all) is kept, nothing made
spawned = {}
local own = piece(PART, { X = 95310 + 12, Y = 76630 - 40, Z = 1000 }, { comp(nil, { X = 0, Y = 0, Z = 0 }),
  comp(DOOR, { X = 95310 + 208, Y = 76630 + 114, Z = 1000 + 35 }, { Pitch = 0, Yaw = -114, Roll = 0 }, { X = 0.85, Y = 1.01, Z = 0.95 }) }, 156)
local recOwn = readRec(own, own.StaticMeshComponent, B)
Q.made[key] = nil
local Bd2 = { slots = { { a = own.addr, rec = recOwn, on = true } }, n = 1 }
local acts2 = plan(key, Bd2)
check(recOwn.s == rec.s and #acts2 == 0, "the friend's own part with the same door: the same text, nothing to do")
-- the friend's own part WITHOUT the door (the fault's case): hidden, and the host's drawn
local bare = piece(PART, { X = 95310 + 12, Y = 76630 - 40, Z = 1000 }, {}, 156)
local recBare = readRec(bare, bare.StaticMeshComponent, B)
local Bd3 = { slots = { { a = bare.addr, rec = recBare, on = true } }, n = 1 }
local acts3 = plan(key, Bd3)
local kinds = {}; for _, x in ipairs(acts3) do kinds[#kinds + 1] = x[1] end
table.sort(kinds)
check(recBare.s ~= rec.s and table.concat(kinds, ",") == "hide,make", "a part without the host's door: its own hidden, the host's drawn (" .. table.concat(kinds, ",") .. ")")

-- (session l87e) a turn on the edge (roll 180 or -180, pitch 90 or -90) is drawn a tenth of a degree off it, so that
-- the engine reads it back in the host's form
spawned = {}
local LADDER = "/Game/ManorLords/Buildings/CommonAssets/UnifiedBeams/UBeam_LadderLong.UBeam_LadderLong"
local lad = piece(LADDER, { X = 95310 + 70, Y = 76630 + 20, Z = 1000 }, {}, 200)
lad.StaticMeshComponent.R = { Pitch = 71, Yaw = 200, Roll = -180 }
local recL = readRec(lad, lad.StaticMeshComponent, B)
local itL = wireOf({ m = recL.m, t = recL.t })
S.role = "friend"
for _, l in ipairs(sent) do
  if l:find("^Q M ") then local w = {}; for x in l:gmatch("%S+") do w[#w + 1] = x end; table.insert(w, 1, "0"); table.insert(w, 1, "1"); MOD.onMessage(S, "host", "Q", w, l) end
end
local sL, mL, tL, xL = parseItem(itL)
Q.hostCnt[key] = { [sL] = { n = 1, m = mL, t = tL, x = xL } }
Q.made[key] = nil
local actsL = plan(key, { slots = {}, n = 0 })
doAct(S, actsL[1], 2)
local aL = spawned[#spawned]
check(aL and math.abs(aL.StaticMeshComponent.R.Roll - (-179.9)) < 1e-9 and aL.StaticMeshComponent.R.Pitch == 71, "a roll of -180 is drawn at -179.9 (the engine would read -180 back as 180)")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
