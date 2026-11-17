-- Manor Lords Co-op: the small things a player sees standing in the town are the host's (plug-in module "scene",
-- message kind "Q"). Lane 41, session 21. Evidence: research/2026-11-10-game-probe/lanes/lane_s21_41/report.txt
--
-- 1. PIECES. Every building is drawn from pieces: the actors of its list "buildings" (walls, the yard gate, fences, a
--    stall's body and dressing, clutter) and of its list "Resources" (the goods shown: a stall's wares, the firewood
--    stacks and logs piled at a workshop, the goods in a storehouse). The game picks many of them with the C library's
--    rand() (one sequence for the whole program; the yard gate's pick is the call at 4D1FF0F in 4d1e900) when it
--    builds, loads or re-stocks a building, and it shows and hides the goods' meshes as the stock changes. None of
--    these choices is saved and no game routine takes one as input, so a friend that loads the host's save draws its
--    own. So the host tells what it DRAWS, per building, and a friend makes its own picture the same:
--      host -> friends   Q M <n> <mesh path> <material paths>          a mesh named once (index n)
--                        Q P <bkey> <part>/<parts> <z> <n:piece;...>    every drawn piece of a building (z: its height)
--                        Q D <bkey> <pieces after> <+n:piece;-n:piece>  a change of a few pieces
--                        Q G <bkey>                                     that building is gone on the host
--                        piece = x:y:z:yaw[:pitch:roll:sx:sy:sz]  (cm from the building, degrees, scale x100)
--      friend -> host    Q W <n,n,...> <bkey|bkey...>                   "I miss these meshes / these buildings"
--    A friend compares its drawn pieces with the host's by exact text (pieces of the same save stand at the same cm):
--      a piece of its own the host does not draw   is hidden (SetActorHiddenInGame; shown again when the host draws it)
--      a piece the host draws and it lacks         is drawn by an actor of this module (a StaticMeshActor with that
--                                                  mesh and materials, no collision), removed when the host stops
--    The game's own pieces are never moved, changed or destroyed: only hidden.
--
--    COST. Nothing of the game is kept from one frame to the next: a building is found again each time by its key
--    (its place in the engine's list, checked by type and place), a piece by its place in the building's list,
--    checked by its address. What is kept is plain data: per building and list place the piece's address, its text
--    and whether it was drawn. So reading a building again costs two reflected reads a piece (hidden, visible); a
--    piece is read in full only when a new actor stands at that list place. All work is paid from a budget a frame:
--      - every building's look-up number (list lengths and stock) once in cfg.lenEvery seconds, spread over frames;
--      - a building whose number changed, and one the host changed (friend), is read again (a big storehouse over
--        several frames: the read goes on where it stopped);
--      - a round reads every building once in cfg.roundEvery seconds (a fence hidden by a neighbour);
--      - a friend's actions (hide, show, draw, remove) at most cfg.spawnPerFrame new actors a frame.
--    The first read after a world was loaded runs on cfg.budgetFirst until every building was read once.
--
-- 2. CARTS. A handcart (Resource_Handcart_C) is made for a carrier's trip, pulled, and left standing at the trip's
--    storage building (SMBuildingMaster.Carts); each copy's carriers make their own trips. The friend's carts keep
--    serving its own carriers (never moved, never removed); the picture is drawn from the host's word:
--      host -> friends   Q C <id>:<x>:<y>:<z>:<yaw>:<pitch>:<roll>:<standing 0|1>;...   carts that appeared or moved
--                        Q C - <id>,<id>,...                                             carts that are gone
--                        Q K <id>:...;...                                                every cart (a keyframe)
--    A friend shows its own standing cart where the host has a standing cart at the same place (3 cm, 1 degree); every
--    other cart of its own is hidden (actor and drawn mesh), and every other host cart is drawn by an actor of this
--    module with the cart's mesh, materials and scale, moved smoothly to each new place. A cart is kept from look to
--    look only while it reads valid at every look (four to ten looks a second; a destroyed actor is freed only at the
--    engine's next garbage collection, so it is dropped before); everything kept of a dropped cart goes with it.
-- Re-loadable (state lives in Coop.scene).

local C = rawget(_G, "Coop")
if type(C) ~= "table" or type(C.register) ~= "function" or type(C.api) ~= "table" then return "coop_x_scene: load coop.lua first" end
local A = C.api
local un, valid = A.un, A.valid
local Q = C.scene or {}
C.scene = Q
Q.version = "0.3"
Q.stats = Q.stats or {}
Q.S = nil

local cfg = {
  budget = 0.30,       -- milliseconds a frame for pieces (look-ups, reads, a friend's actions)
  budgetFirst = 3.0,   -- ... until every building was read once after a world was loaded
  budgetBusy = 1.0,    -- ... while work has waited over a second (the owner's window is 3 s: a friend's picture may
                       -- follow the host's within 2 to 3 s, so the work is spread rather than done at once)
  lenEvery = 3.0,      -- seconds: every building's look-up number this often
  goodsEvery = 1.5,    -- seconds: a building's shown goods read again at most this often
  roundEvery = 30.0,   -- seconds: every building read once in a round this often
  spawnPerFrame = 2,   -- new actors a frame (friend)
  keyBurst = 4,        -- buildings sent a frame when everything is sent again (host)
  maxLine = 2500,      -- characters of pieces in one line
  cartEvery = 0.4,     -- seconds between two looks at the carts (host)
  cartEveryF = 0.2,    -- ... on a friend (its own cart that starts to move is hidden within this time)
  cartFind = 30.0,     -- seconds between two searches of every handcart object (a safety net besides NotifyOnNewObject)
  cartGlide = 0.4,     -- seconds a drawn cart takes to move to the host's next place
  cartTol = 3,         -- cm: a friend's own standing cart stands for the host's only at the very same place
  askEvery = 2.0,      -- a friend asks for missing meshes or buildings at most this often
}
Q.cfg = cfg
local CART_CLASS = "/Game/CPP_BP/Resources/Resource_Handcart.Resource_Handcart_C"

local function log(fmt, ...) A.log("scene: " .. fmt, ...) end
local function bump(k, n) Q.stats[k] = (Q.stats[k] or 0) + (n or 1) end
local function rnd(v) return math.floor(v + 0.5) end
local function yawDiff(a, b) local d = math.abs(a - b) % 360; if d > 180 then d = 360 - d end; return d end
local function keyOf(b)
  local l = b:K2_GetActorLocation()
  return string.format("%d@%d,%d", A.btype(b), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5)), l
end
-- (lane 47, round two) the same hash, kept per text: a piece's text is hashed byte by byte in Lua (0.14 ms a frame on
-- a friend, sitting p1) and the same texts come again at every read of a building; the value is the same as before
local HC, HCN = {}, 0
local function strHash(s)
  local h = HC[s]; if h then return h end
  h = 5381; for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
  if HCN >= 50000 then HC = {}; HCN = 0 end
  HC[s] = h; HCN = HCN + 1
  return h
end
local function ms(t0) return (os.clock() - t0) * 1000 end

-- ================================================================ 1. pieces: reading
-- a building found again by its key: its place in the engine's list (from the look-up pass), checked by type and place
local KEYN = {}                                                        -- key -> { type, x, y } (plain numbers)
local function keyNums(key)
  local k = KEYN[key]
  if not k then local t, x, y = key:match("^(%d+)@(%-?%d+),(%-?%d+)$"); k = { tonumber(t), tonumber(x), tonumber(y) }; KEYN[key] = k end
  return k
end
local function atIndex(arr, i) return un(arr[i]) end
local function placeOf(b) return b:K2_GetActorLocation() end
local function resolve(S, key)
  local i = Q.hint[key]; if not i then return nil end
  local arr = S.eng.buildingArr
  if i > #arr then return nil end
  local ok, b = pcall(atIndex, arr, i)
  if not ok or not valid(b) then return nil end
  local okL, l = pcall(placeOf, b); if not okL then return nil end
  local k = keyNums(key)
  if math.floor(l.X / 10 + 0.5) ~= k[2] or math.floor(l.Y / 10 + 0.5) ~= k[3] then return nil end
  local okT, t = pcall(A.btype, b)
  if not okT or t ~= k[1] then return nil end
  return b, l
end

local function meshPath(mo)
  local p
  pcall(function() p = mo:GetFullName():match("^%S+%s+(.+)$") end)   -- the mod loader has no GetPathName
  return p
end
local function matsOf(c)
  local t = {}
  pcall(function()
    for i = 0, c:GetNumMaterials() - 1 do
      local mt = c:GetMaterial(i); local p = "-"
      if mt and mt:IsValid() then pcall(function() local s = mt:GetFullName():match("^%S+%s+(.+)$"); if s and not s:find("Transient", 1, true) then p = s end end) end
      t[#t + 1] = p
    end
  end)
  return table.concat(t, ",")
end

-- a piece read in full: its record (text, hash, mesh path) or false (not to be counted: a ground-texture piece)
local function readRec(x, c, B)
  local nv = 0; pcall(function() nv = #c.RuntimeVirtualTextures end)
  if nv > 0 then return false end
  local mo = c.StaticMesh; if not mo:IsValid() then return nil end
  local m = meshPath(mo); if not m then return nil end
  if Q.matsOf[m] == nil then Q.matsOf[m] = matsOf(c) end
  local L = x:K2_GetActorLocation(); local R = x:K2_GetActorRotation(); local Sc = x:GetActorScale3D()
  local p, r = rnd(R.Pitch), rnd(R.Roll)
  local sx, sy, sz = rnd(Sc.X * 100), rnd(Sc.Y * 100), rnd(Sc.Z * 100)
  local tail = string.format("%d:%d:%d:%d", rnd(L.X - B.X), rnd(L.Y - B.Y), rnd(L.Z - B.Z), rnd(R.Yaw) % 360)
  if p ~= 0 or r ~= 0 or sx ~= 100 or sy ~= 100 or sz ~= 100 then tail = tail .. string.format(":%d:%d:%d:%d:%d", p, r, sx, sy, sz) end
  local s = m .. ":" .. tail
  return { m = m, t = tail, s = s, h = strHash(s) }
end

-- read list place j of the building (x the actor there now): visibility only when the same actor stands there
-- read list place j of the building (x the actor there now): visibility only when the same actor stands there.
-- No closures here (they are made anew at every call: garbage for the collector, whose steps land in any tick): the
-- reads go through these plain functions. The game never hides a piece's actor (only its mesh); this module hides
-- actors on a friend, so the actor's flag is read only for the pieces this module hid.
local function addrOf(x) return x:GetAddress() end
local function visOf(x) return x.StaticMeshComponent:IsVisible() end
local function hiddenOf(x) return x.bHidden end
local function fullOf(x, B)
  local c = x.StaticMeshComponent
  return (not x.bHidden) and c:IsVisible(), readRec(x, c, B)
end
local function readSlot(Bd, j, x, B, trust)
  local slot = Bd.slots[j]
  -- trust: the building's lists kept their lengths since its last read and this read is one of three of four goods
  -- reads: the actor at this place is taken to be the same one (its address read costs as much as its visibility)
  local a
  if trust and slot and slot.rec ~= nil then a = slot.a
  else local okA, aa = pcall(addrOf, x); if not okA or not aa then Bd.slots[j] = nil; return end; a = aa end
  if slot and slot.rec ~= nil and (slot.a == a) then
    if slot.rec then
      local okV, v = pcall(visOf, x)
      local on = okV and v == true
      if on and slot.mine then local okH, h = pcall(hiddenOf, x); on = okH and h == false end
      slot.on = on
    end
    Q.nFast = Q.nFast + 1; return
  end
  local okF, on, rec = pcall(fullOf, x, B)
  if not okF then on, rec = false, nil end
  if rec == nil then rec = false end                                   -- not readable as a piece: not counted
  Bd.slots[j] = { a = a, rec = rec, on = on and rec and true or false }
  bump("readFull")
end

-- the sum of the hashes and the number of what this copy draws of a building (game pieces and, on a friend, its own)
local function drawnSum(key, Bd)
  local sum, n = 0, 0
  for j = 1, Bd.n do local s = Bd.slots[j]; if s and s.on and s.rec then sum = (sum + s.rec.h) % 9007199254740881; n = n + 1 end end
  local md = Q.made[key]
  if md then for _, e in ipairs(md) do sum = (sum + e.h) % 9007199254740881; n = n + 1 end end
  return sum, n
end

local setHost, stalls                                                  -- defined further down
local function bld(key) local Bd = Q.B[key]; if not Bd then Bd = { slots = {}, n = 0 }; Q.B[key] = Bd end; return Bd end

-- ================================================================ host: sending
local function numbered(m)
  local n = Q.meshNo[m]
  if not n then Q.nMesh = Q.nMesh + 1; n = Q.nMesh; Q.meshNo[m] = n end
  if not Q.meshSaid[n] then Q.meshSaid[n] = true; A.send(string.format("Q M %d %s %s", n, m, (Q.matsOf[m] and Q.matsOf[m] ~= "") and Q.matsOf[m] or "-")); bump("sentM") end
  return n
end

-- counts of the drawn texts: { [text] = { n = count, m = mesh, t = tail } }
local function countsOf(Bd)
  local c = {}
  for j = 1, Bd.n do
    local s = Bd.slots[j]
    if s and s.on and s.rec then local e = c[s.rec.s]; if e then e.n = e.n + 1 else c[s.rec.s] = { n = 1, m = s.rec.m, t = s.rec.t } end end
  end
  return c
end

local function sendFull(key, cnt, z)
  local parts, buf, len = {}, {}, 0
  for _, e in pairs(cnt) do
    local it = numbered(e.m) .. ":" .. e.t
    for _ = 1, e.n do
      if len + #it + 1 > cfg.maxLine and #buf > 0 then parts[#parts + 1] = table.concat(buf, ";"); buf = {}; len = 0 end
      buf[#buf + 1] = it; len = len + #it + 1
    end
  end
  parts[#parts + 1] = table.concat(buf, ";")
  for i, l in ipairs(parts) do
    local s = string.format("Q P %s %d/%d %d %s", key, i, #parts, rnd(z or 0), l ~= "" and l or "-")
    A.send(s); bump("sentP"); bump("bytes", #s + 20)
  end
end

local function sendDelta(key, old, cnt, total)
  local d, len = {}, 0
  for s, e in pairs(cnt) do
    local o = old[s]; local diff = e.n - (o and o.n or 0)
    if diff ~= 0 then local it = numbered(e.m) .. ":" .. e.t; for _ = 1, math.abs(diff) do d[#d + 1] = (diff > 0 and "+" or "-") .. it; len = len + #it + 2 end end
  end
  for s, o in pairs(old) do
    if not cnt[s] then local it = numbered(o.m) .. ":" .. o.t; for _ = 1, o.n do d[#d + 1] = "-" .. it; len = len + #it + 2 end end
  end
  if #d == 0 then return true end
  if len > cfg.maxLine or #d * 2 > total + 2 then return false end
  local s = string.format("Q D %s %d %s", key, total, table.concat(d, ";"))
  A.send(s); bump("sentD"); bump("bytes", #s + 20)
  return true
end

local function hostFinish(key, Bd, B)
  local sum, n = drawnSum(key, Bd)
  if Bd.sentSum == sum and Bd.sentN == n then return end
  local cnt = countsOf(Bd)
  if not (Bd.sent and sendDelta(key, Bd.sent, cnt, n)) then sendFull(key, cnt, B.Z) end
  Bd.sent = cnt; Bd.sentSum = sum; Bd.sentN = n; Bd.z = B.Z
end

function Q.keyframe()
  Q.meshSaid = {}; Q.resend = {}
  for k in pairs(Q.B or {}) do Q.resend[#Q.resend + 1] = k end
  Q.cartKey = true
  return "keyframe queued"
end

-- ================================================================ friend: actions
local SMA
local function alive(o) if not o then return false end; local ok, v = pcall(function() return o:IsValid() end); return ok and v == true end
local function meshObj(path)
  local o                                                             -- looked up each time, never kept
  pcall(function() local m = StaticFindObject(path); if m and m:IsValid() then o = m end end)
  if not o and not Q.noMesh[path] then pcall(function() local m = LoadAsset(path); if m and m:IsValid() then o = m end end) end
  if not o and not Q.noMesh[path] then Q.noMesh[path] = true; log("mesh %s not found here: such pieces are not drawn", path); bump("noMesh") end
  return o
end
local function matsFor(path)
  local hm = Q.hostMats[path]
  if hm == "-" then return {} end
  if not hm or hm == "" then return nil end
  local r = {}
  for p in hm:gmatch("[^,]+") do
    local o
    if p ~= "-" then pcall(function() local x = StaticFindObject(p); if x and x:IsValid() then o = x end end) end
    if not o then return nil end
    r[#r + 1] = o
  end
  return r
end

-- a StaticMeshActor of this module: mesh, place, rotation, scale; nil when it could not be made
local function newActor(S, mesh, L, R, sx, sy, sz)
  SMA = SMA or StaticFindObject("/Script/Engine.StaticMeshActor")
  local a
  local ok, e = pcall(function()
    a = S.p1:GetWorld():SpawnActor(SMA, L, R)
    local c = a.StaticMeshComponent
    c:SetMobility(2)
    if not alive(mesh) then error("mesh no longer loaded") end
    c:SetStaticMesh(mesh)
    c:SetCollisionEnabled(0)
    if sx ~= 1 or sy ~= 1 or sz ~= 1 then a:SetActorScale3D({ X = sx, Y = sy, Z = sz }) end
    a:K2_SetActorRotation(R, true)
  end)
  if not ok then
    bump("spawnFail"); if not Q.saidSpawn then Q.saidSpawn = true; log("a piece could not be drawn: %s", tostring(e)) end
    if a then pcall(function() if a:IsValid() then a:K2_DestroyActor() end end) end
    return nil
  end
  return a
end

local function spawnPiece(S, B, m, tail)
  local mesh = meshObj(m); if not mesh then return nil end
  local mats = matsFor(m)
  if not mats then bump("noMat"); if not Q.saidMat[m] then Q.saidMat[m] = true; log("no materials for %s here: such a piece is not drawn", m) end; return nil end
  local x, y, z, yaw, p, r, sx, sy, sz = tail:match("^(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):?(%-?%d*):?(%-?%d*):?(%-?%d*):?(%-?%d*):?(%-?%d*)$")
  if not x then return nil end
  local a = newActor(S, mesh, { X = B.X + tonumber(x), Y = B.Y + tonumber(y), Z = B.Z + tonumber(z) },
    { Pitch = tonumber(p) or 0, Yaw = tonumber(yaw), Roll = tonumber(r) or 0 },
    (tonumber(sx) or 100) / 100, (tonumber(sy) or 100) / 100, (tonumber(sz) or 100) / 100)
  if a then
    bump("made")
    pcall(function() local c = a.StaticMeshComponent; for i, mt in ipairs(mats) do if alive(mt) then c:SetMaterial(i - 1, mt) end end end)
  end
  return a
end

-- the plan for one building: which own pieces to hide / show again, which actors to make / remove
local function plan(key, Bd)
  local want = Q.hostCnt[key]; if not want then return end
  local on, hid = {}, {}
  for j = 1, Bd.n do
    local s = Bd.slots[j]
    if s and s.rec then
      local t = s.rec.s
      if s.on then local l = on[t]; if l then l[#l + 1] = j else on[t] = { j } end
      elseif s.mine then local l = hid[t]; if l then l[#l + 1] = j else hid[t] = { j } end end
    end
  end
  local mk = {}
  for i, e in ipairs(Q.made[key] or {}) do local l = mk[e.s]; if l then l[#l + 1] = i else mk[e.s] = { i } end end
  local acts = {}
  local seen = {}
  local function one(t)
    if seen[t] then return end; seen[t] = true
    local w = want[t]; local wn = w and w.n or 0
    local own, made = on[t] or {}, mk[t] or {}
    local have = #own + #made
    if have > wn then
      local extra = have - wn
      for k = #made, 1, -1 do if extra == 0 then break end; acts[#acts + 1] = { "remove", key, made[k] }; extra = extra - 1 end
      for k = #own, 1, -1 do if extra == 0 then break end; acts[#acts + 1] = { "hide", key, own[k] }; extra = extra - 1 end
    elseif have < wn then
      local need = wn - have
      for _, j in ipairs(hid[t] or {}) do if need == 0 then break end; acts[#acts + 1] = { "show", key, j }; need = need - 1 end
      for _ = 1, need do acts[#acts + 1] = { "make", key, t, w.m, w.t } end
    end
  end
  for t in pairs(want) do one(t) end
  for t in pairs(on) do one(t) end
  for t in pairs(mk) do one(t) end
  -- removals first (by falling index), so the made list's places stay right
  table.sort(acts, function(a, b) if a[1] == "remove" and b[1] == "remove" then return a[3] > b[3] end; return a[1] == "remove" and b[1] ~= "remove" end)
  return acts
end

local function doAct(S, act, spawns)
  local kind, key = act[1], act[2]
  if kind == "remove" then
    local l = Q.made[key]; local e = l and l[act[3]]
    if e then pcall(function() if e.a:IsValid() then e.a:K2_DestroyActor() end end); table.remove(l, act[3]); bump("removed") end
    return true
  end
  if kind == "make" and spawns <= 0 then return false end
  local b, B = resolve(S, key)
  if not b and kind == "make" and Q.ghostAt[key] then B = Q.ghostAt[key]; b = true end   -- a stall the host has alone
  if not b then return true end                                       -- the building is not (or no longer) here
  local Bd = Q.B[key]
  if kind == "make" then
    local a = spawnPiece(S, B, act[4], act[5])
    if a then local l = Q.made[key] or {}; Q.made[key] = l; l[#l + 1] = { a = a, s = act[3], h = strHash(act[3]) } end
    return true
  end
  if b == true then return true end
  local j = act[3]; local slot = Bd and Bd.slots[j]; if not slot then return true end
  pcall(function()
    -- the lists are read with their lengths of now: reading a game array past its end GROWS it (sitting b1: an index
    -- of an older read, after a rival's upgrade had shortened the parts list, left an empty entry there and the
    -- game's own getConstructionProgress read through it: the friend's game closed)
    local P, R = b.buildings, b.Resources
    local n1, n2 = #P, #R
    if n1 ~= Bd.n1 or j > n1 + n2 then return end
    local x; if j <= n1 then x = P[j] else x = R[j - n1] end
    if not x or x:GetAddress() ~= slot.a then return end              -- another actor stands there now: next read
    if kind == "hide" then x:SetActorHiddenInGame(true); slot.on = false; slot.mine = true; bump("hid")
    else x:SetActorHiddenInGame(false); slot.mine = nil; slot.on = true; bump("shown") end
  end)
  return true
end

local function friendFinish(S, key, Bd)
  local want = Q.hostCnt[key]; if not want then return end
  local sum, n = drawnSum(key, Bd)
  if sum == Q.hostSum[key] and n == Q.hostN[key] then Bd.ok = true; return end
  Bd.ok = false
  -- a new plan for this building replaces the actions of an older one still waiting
  local keep = {}; for _, a in ipairs(Q.acts) do if a[2] ~= key then keep[#keep + 1] = a end end; Q.acts = keep
  local acts = plan(key, Bd)
  if acts and #acts > 0 then for _, a in ipairs(acts) do Q.acts[#Q.acts + 1] = a end; bump("fixes") end
end

-- this module's actors of a building go
local function dropKey(key)
  for _, e in ipairs(Q.made[key] or {}) do pcall(function() if e.a:IsValid() then e.a:K2_DestroyActor() end end); bump("removed") end
  Q.made[key] = nil; Q.B[key] = nil
end

-- ================================================================ the work of a frame (both roles)
-- the stock of a building changed (the facts module tells: on the host when it reads the change, on a friend when
-- the host's line comes, which is written a moment later): its shown goods are read again, twice on a friend (0.3 s
-- and 1.2 s later), at most every cfg.goodsEvery seconds per building. Reading every building's stock here as well
-- cost 0.1 ms a building (sitting p1: two thirds of the look-up pass).
function Q.stockSeen(key)
  if not Q.stockDue then return end
  local now = os.clock()
  local d = Q.stockDue[key]; if not d then d = {}; Q.stockDue[key] = d end
  if Q.S and Q.S.role == "friend" then d[#d + 1] = now + 0.6 else d[#d + 1] = now + 0.1 end
end
local function stockDueStep(clock)
  local now = os.clock()
  for key, d in pairs(Q.stockDue) do
    local due = false
    for i = #d, 1, -1 do if d[i] <= now then due = true; table.remove(d, i) end end
    if due and now - (Q.goodsAt[key] or -1e9) >= cfg.goodsEvery then
      Q.goodsAt[key] = now
      if not Q.pri[key] then Q.pri[key] = "goods" end
    elseif due then d[#d + 1] = (Q.goodsAt[key] or now) + cfg.goodsEvery end    -- too soon: once more after the gap
    if #d == 0 then Q.stockDue[key] = nil end
  end
end

local function lensOf(b)
  local n1, n2, st = -1, -1, 0
  pcall(function() n1 = #b.buildings end)
  pcall(function() n2 = #b.Resources end)
  return n1 * 1000003 + n2 * 7, st
end

-- one step of the look-up pass: building i of the engine's list
local function lensStep(S, clock, i, arr)
  local b = un(arr[i])
  if not valid(b) then return end
  -- the key is known by the object's address at this list place; it is worked out again (type and place: about
  -- 60 microseconds) when another object stands there, and every 5th pass (an address taken over by a new building)
  local okA, a = pcall(addrOf, b); if not okA then return end
  local key = Q.keyAt[i]
  if not key or key[1] ~= a or (Q.pass + i) % 5 == 0 then
    local okK, k = pcall(keyOf, b); if not okK then return end
    key = { a, k }; Q.keyAt[i] = key
  end
  key = key[2]
  Q.hint[key] = i; Q.seen[key] = Q.pass
  -- lists changed: the whole building is read again; only the stock changed: its shown goods (the game shows and
  -- hides the goods' meshes as the stock changes; the parts stay) - a storehouse's 141 goods instead of 250 pieces
  local l = lensOf(b)
  if Q.lens[key] ~= l then Q.lens[key] = l; Q.pri[key] = true end
end

-- MARKET STALLS that stand on one copy only: each copy's families set their stalls up, and a rival lord's town is
-- followed by the people module without its stalls (lane 39). The host names its stalls (Q L <key|key...>, when the
-- list changed and every 10 s); a friend draws a stall the host has and it lacks with actors of this module at the
-- host's place and height (the building's key: 10 cm), and hides the pieces of a stall of its own the host lacks.
-- Who keeps which stall is not touched; only what is drawn.
local STALL = { [91] = true, [93] = true }
local function stallType(key) return STALL[tonumber(key:match("^(%d+)@"))] end
stalls = function(S)
  if S.role == "host" then
    local t = {}; for key in pairs(Q.seen) do if stallType(key) then t[#t + 1] = key end end
    table.sort(t); local l = table.concat(t, "|")
    if l ~= Q.stallSaid or os.clock() - (Q.tStall or -1e9) >= 10 then Q.stallSaid = l; Q.tStall = os.clock(); A.send("Q L " .. (l ~= "" and l or "-")); bump("sentL") end
    return
  end
  if not Q.hostStalls then return end
  -- a stall of this copy the host lacks: nothing of it drawn
  for key in pairs(Q.seen) do
    if stallType(key) and not Q.hostStalls[key] and not Q.hostCnt[key] then setHost(key, {}); Q.stallOwn[key] = true; bump("stallHid") end
  end
  -- a stall of the host this copy lacks: drawn at the host's place
  for key in pairs(Q.hostStalls) do
    if not Q.seen[key] and Q.hostCnt[key] and Q.hostZ[key] then
      local x, y = key:match("@(%-?%d+),(%-?%d+)$")
      Q.ghostAt[key] = { X = tonumber(x) * 10, Y = tonumber(y) * 10, Z = Q.hostZ[key] }
      local Bd = bld(key)
      local sum, n = drawnSum(key, Bd)
      if sum ~= Q.hostSum[key] or n ~= Q.hostN[key] then
        local pending = false; for _, a in ipairs(Q.acts) do if a[2] == key then pending = true; break end end
        if not pending then friendFinish(S, key, Bd); bump("stallDrawn") end
      end
    elseif Q.seen[key] then Q.ghostAt[key] = nil end
  end
  for key in pairs(Q.ghostAt) do if not Q.hostStalls[key] then Q.ghostAt[key] = nil; dropKey(key) end end
end

local function passEnd(S)
  -- buildings not met in a whole pass have left the game
  for key, p in pairs(Q.seen) do
    if p ~= Q.pass then
      Q.seen[key] = nil; Q.hint[key] = nil; Q.lens[key] = nil; Q.stock[key] = nil; Q.pri[key] = nil
      if S.role == "host" then if Q.B[key] and Q.B[key].sent then A.send("Q G " .. key); bump("sentG") end; Q.B[key] = nil
      else dropKey(key) end
    end
  end
  Q.order = {}; for key in pairs(Q.seen) do Q.order[#Q.order + 1] = key end
  stalls(S)
  Q.pass = Q.pass + 1
  if not Q.firstDone and Q.passes >= 1 and not next(Q.pri) and not Q.job then Q.firstDone = true; log("first read of every building done (%d buildings)", #Q.order) end
  Q.passes = Q.passes + 1
end

local function work(S, clock)
  local t0 = os.clock()
  -- the budget: small while nothing waits; larger while buildings wait to be read or a friend's actions wait (a
  -- house built anew: 57 pieces read in full at about 0.3 ms each), so the picture follows within a second or two
  local waiting = Q.job or next(Q.pri) or #Q.acts > 0
  if waiting then Q.busySince = Q.busySince or clock else Q.busySince = nil end
  local busy = Q.busySince and clock - Q.busySince > 1.0                -- work waiting for more than a second
  local budget = (not Q.firstDone) and cfg.budgetFirst or (busy and cfg.budgetBusy or cfg.budget)
  local arr; pcall(function() arr = S.eng.buildingArr end); if not arr then return end
  local N = #arr
  -- 1. the look-up pass: N buildings in cfg.lenEvery seconds
  local dt = math.min(0.5, math.max(0, clock - (Q.tLen or clock))); Q.tLen = clock
  Q.lenDebt = math.min(Q.lenDebt + N * dt / cfg.lenEvery, N)
  while Q.lenDebt >= 1 and ms(t0) < budget do
    Q.lenDebt = Q.lenDebt - 1
    if Q.lenI > N then Q.lenI = 1; passEnd(S) end
    pcall(lensStep, S, clock, Q.lenI, arr)
    Q.lenI = Q.lenI + 1
  end
  stockDueStep(clock)
  local t1 = os.clock(); Q.stats.msLens = (Q.stats.msLens or 0) + (t1 - t0) * 1000
  -- 2. the round: one building every roundEvery / N seconds
  if #Q.order > 0 and clock - Q.tRound >= cfg.roundEvery / #Q.order then
    Q.tRound = clock; Q.roundI = Q.roundI % #Q.order + 1
    local k = Q.order[Q.roundI]; if k and not Q.pri[k] then Q.low[k] = true end
  end
  -- 3. a friend's actions
  if S.role == "friend" then
    local spawns = cfg.spawnPerFrame
    while #Q.acts > 0 and ms(t0) < budget do
      local act = Q.acts[1]
      if not doAct(S, act, spawns) then break end
      if act[1] == "make" then spawns = spawns - 1 end
      Q.lastWhat = "act " .. act[1] .. " " .. act[2]
      table.remove(Q.acts, 1)
    end
  end
  local t2 = os.clock(); Q.stats.msActs = (Q.stats.msActs or 0) + (t2 - t1) * 1000
  -- 4. reading buildings (a read goes on next frame where it stopped)
  while ms(t0) < budget do
    local J = Q.job
    if not J then
      local key, what = next(Q.pri)
      if key then Q.pri[key] = nil else key = next(Q.low); if key then Q.low[key] = nil end end
      if not key then break end
      J = { key = key, j = 1, goods = what == "goods" }; Q.job = J
    end
    local b, B = resolve(S, J.key)
    if not b then Q.job = nil
    else
      local Bd = bld(J.key)
      local P, R, n1, n2
      pcall(function() P = b.buildings; R = b.Resources; n1 = #P; n2 = #R end)
      if not n1 then Q.job = nil
      else
        if J.goods and Bd.n1 == n1 and J.j <= n1 then
          J.j = n1 + 1                                                  -- the parts were read before and stay
          Bd.gr = (Bd.gr or 0) + 1
          J.trust = Bd.n == n1 + n2 and Bd.gr % 4 ~= 0
        end
        Bd.n1 = n1
        while J.j <= n1 + n2 and ms(t0) < budget do
          local j = J.j
          local x; pcall(function() if j <= n1 then x = P[j] else x = R[j - n1] end end)
          if x then readSlot(Bd, j, x, B, J.trust) end
          J.j = j + 1
        end
        if J.j > n1 + n2 then
          for j = n1 + n2 + 1, Bd.n do Bd.slots[j] = nil end
          Bd.n = n1 + n2
          Q.job = nil; bump("reads"); Q.lastWhat = "read " .. J.key
          local tf = os.clock()
          if S.role == "host" then hostFinish(J.key, Bd, B) else friendFinish(S, J.key, Bd) end
          local f = (os.clock() - tf) * 1000; Q.stats.msFinish = (Q.stats.msFinish or 0) + f
          if f > (Q.stats.maxFinish or 0) then Q.stats.maxFinish = f; Q.maxFinishWhat = J.key .. " n=" .. Bd.n end
        end
      end
    end
  end
  local t3 = os.clock(); Q.stats.msRead = (Q.stats.msRead or 0) + (t3 - t2) * 1000
  -- 5. the host sends everything again (a join), a few buildings a frame
  if S.role == "host" and Q.resend and #Q.resend > 0 then
    for _ = 1, cfg.keyBurst do
      local k = table.remove(Q.resend); if not k then break end
      local Bd = Q.B[k]; if Bd and Bd.sent then sendFull(k, Bd.sent, Bd.z) end
    end
  end
  -- 6. a friend asks for what it misses
  if S.role == "friend" and (next(Q.want) or next(Q.wantKeys)) and clock - (Q.tAsk or -1e9) >= cfg.askEvery then
    Q.tAsk = clock
    local ns = {}; for n in pairs(Q.want) do ns[#ns + 1] = tostring(n) end
    local keys = {}; for k in pairs(Q.wantKeys) do keys[#keys + 1] = k end
    A.send("Q W " .. (#ns > 0 and table.concat(ns, ",") or "0") .. " " .. table.concat(keys, "|"))   -- a key holds a comma
    bump("asked"); Q.want = {}; Q.wantKeys = {}
  end
  local t = ms(t0); bump("ms", t); if t > (Q.stats.maxMs or 0) then Q.stats.maxMs = t; Q.maxWhat = Q.lastWhat end
end

-- ================================================================ 2. carts
local function dropCart(a)
  Q.carts[a] = nil; Q.cartComp[a] = nil; Q.ownLast[a] = nil; Q.ownShown[a] = nil; Q.compHid[a] = nil; Q.cartId[a] = nil
end
local function cartFind(clock)
  Q.tFind = clock
  pcall(function() for _, x in ipairs(FindAllOf("Resource_Handcart_C") or {}) do if x:IsValid() then Q.carts[x:GetAddress()] = x end end end)
  bump("cartFind")
end
if not rawget(_G, "__coopSceneNotify") then
  local okN = pcall(function()
    NotifyOnNewObject(CART_CLASS, function(x)
      local Qn = rawget(_G, "Coop") and _G.Coop.scene
      if Qn and Qn.newCarts then pcall(function() Qn.newCarts[#Qn.newCarts + 1] = x end) end
    end)
  end)
  rawset(_G, "__coopSceneNotify", okN)
end
local function isValidCart(x) local ok, v = pcall(function() return x:IsValid() end); return ok and v == true end

-- the drawn mesh component of a cart (not the root: the root holds the same mesh, hidden in game by the game itself)
-- and its world place, or { origin = true } for a spare at the world's origin, or nil
local function cartView(a, x)
  local r
  pcall(function()
    local c = Q.cartComp[a]
    if not c then
      local arr = x:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.StaticMeshComponent"))
      local root; pcall(function() root = x.RootComponent:GetAddress() end)
      for i = 1, #arr do local k = arr[i]:get(); if k.StaticMesh:IsValid() and k:GetAddress() ~= root then c = k end end
      if not c then return end
      Q.cartComp[a] = c
    end
    local L = c:K2_GetComponentLocation()
    if math.abs(L.X) + math.abs(L.Y) < 100 then r = { origin = true, c = c }; return end
    local R = c:K2_GetComponentRotation()
    r = { x = rnd(L.X), y = rnd(L.Y), z = rnd(L.Z), yaw = rnd(R.Yaw) % 360, p = rnd(R.Pitch), r = rnd(R.Roll), c = c }
  end)
  return r
end

local function cartsTake(clock)
  for _, x in ipairs(Q.newCarts) do pcall(function() local a = x:GetAddress(); dropCart(a); Q.carts[a] = x end) end
  Q.newCarts = {}
  if clock - (Q.tFind or -1e9) >= cfg.cartFind then cartFind(clock) end
end

local function hostCarts(S, clock)
  if clock - (Q.tCart or -1e9) < cfg.cartEvery then return end
  Q.tCart = clock
  cartsTake(clock)
  local t0 = os.clock()
  local now, ch = {}, {}
  for a, x in pairs(Q.carts) do
    if not isValidCart(x) then dropCart(a); bump("cartGone")
    else
      local v = cartView(a, x)
      local hidden = false
      if v and not v.origin then pcall(function() hidden = x.bHidden or v.c.bHiddenInGame or not v.c:IsVisible() end) end
      if v and not v.origin and not hidden then
        local id = Q.cartId[a]; if not id then Q.nCart = Q.nCart + 1; id = Q.nCart; Q.cartId[a] = id end
        local last = Q.cartLast[id]
        local standing = (last and last.x == v.x and last.y == v.y and last.z == v.z) and 1 or 0
        local s = string.format("%d:%d:%d:%d:%d:%d:%d:%d", id, v.x, v.y, v.z, v.yaw, v.p, v.r, standing)
        now[id] = s
        if Q.cartSaid[id] ~= s then ch[#ch + 1] = s end
        Q.cartLast[id] = v
      end
    end
  end
  local gone = {}
  for id in pairs(Q.cartSaid) do if not now[id] then gone[#gone + 1] = tostring(id); Q.cartLast[id] = nil end end
  if Q.cartKey then
    Q.cartKey = nil
    local all = {}; for _, s in pairs(now) do all[#all + 1] = s end
    A.send("Q K " .. (#all > 0 and table.concat(all, ";") or "-")); bump("sentK")
  else
    if #ch > 0 then local s = "Q C " .. table.concat(ch, ";"); A.send(s); bump("sentC"); bump("bytesC", #s + 20) end
    if #gone > 0 then A.send("Q C - " .. table.concat(gone, ",")); bump("sentC") end
  end
  Q.cartSaid = now
  local t = ms(t0); bump("msC", t); if t > (Q.stats.maxMsC or 0) then Q.stats.maxMsC = t end
end

local function parseCart(s)
  local id, x, y, z, yaw, p, r, st = s:match("^(%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%d)$")
  if not id then return nil end
  return tonumber(id), { x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw), p = tonumber(p), r = tonumber(r), st = st == "1" }
end

local function setOwnShown(a, x, want)
  local okH, hid = pcall(function() return x.bHidden end)
  if okH and hid == (not want) and Q.ownShown[a] == want then return end
  -- the game shows a cart's actor again by itself many times a minute (sitting b2: 1,472 times in 7 minutes); its
  -- meshes this module hid stay hidden, so it is not drawn and nothing needs doing
  if not want and Q.ownShown[a] == false and Q.compHid[a] then
    local c = Q.cartComp[a]; local okC, hg = pcall(function() return c.bHiddenInGame end)
    if okC and hg == true then bump("cartStillHidden"); return end
  end
  local ok = pcall(function()
    x:SetActorHiddenInGame(not want)
    -- only the components this module hid are shown again (the root is hidden in game by the game itself)
    if want then
      for _, k in ipairs(Q.compHid[a] or {}) do pcall(function() if k:IsValid() then k:SetHiddenInGame(false, false) end end) end
      Q.compHid[a] = nil
    else
      local l = Q.compHid[a] or {}
      local arr = x:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.StaticMeshComponent"))
      for i = 1, #arr do local k = arr[i]:get(); if k:IsValid() and not k.bHiddenInGame then k:SetHiddenInGame(true, false); l[#l + 1] = k end end
      Q.compHid[a] = l
    end
  end)
  if ok then
    if Q.ownShown[a] == want then bump("cartAgain") end
    Q.ownShown[a] = want; bump(want and "cartShown" or "cartHid")
  end
end

local function friendCarts(S, clock)
  -- glide the drawn carts every frame
  for _, d in pairs(Q.cartDraw) do
    if not d.done then
      local f = math.min(1, (clock - d.t0) / cfg.cartGlide)
      d.done = f >= 1
      pcall(function()
        if not d.a:IsValid() then return end   -- (lane 47 round four) our own drawn cart, kept across frames
        local L = { X = d.from.x + (d.to.x - d.from.x) * f, Y = d.from.y + (d.to.y - d.from.y) * f, Z = d.from.z + (d.to.z - d.from.z) * f }
        local dy = ((d.to.yaw - d.from.yaw + 540) % 360) - 180
        d.a:K2_SetActorLocationAndRotation(L, { Pitch = d.to.p, Yaw = d.from.yaw + dy * f, Roll = d.to.r }, false, {}, true)
      end)
    end
  end
  if clock - (Q.tCart or -1e9) < cfg.cartEveryF then return end
  Q.tCart = clock
  if not Q.cartHostSeen then return end
  cartsTake(clock)
  local t0 = os.clock()
  local own = {}
  for a, x in pairs(Q.carts) do
    if not isValidCart(x) then dropCart(a); bump("cartGone")
    else
      local v = cartView(a, x)
      if not v or v.origin then Q.ownLast[a] = nil; own[#own + 1] = { a = a, x = x, v = { x = 1e9, y = 1e9, z = 1e9, yaw = 0, st = false, c = v and v.c } }   -- a spare still lends its mesh (sitting s1: with every own cart a spare, no host cart could be drawn for 9 s)
      else
        local last = Q.ownLast[a]
        v.st = last and last.x == v.x and last.y == v.y and last.z == v.z
        Q.ownLast[a] = v
        if not Q.cartScale then pcall(function() local x = v.c:K2_GetComponentScale(); if x.X > 0.1 then Q.cartScale = { x.X, x.Y, x.Z } end end) end
        own[#own + 1] = { a = a, x = x, v = v }
      end
    end
  end
  local stands, usedOwn = {}, {}
  for id, h in pairs(Q.cartHost) do
    if h.st then
      for i, o in ipairs(own) do
        if not usedOwn[i] and o.v.st and math.abs(o.v.x - h.x) <= cfg.cartTol and math.abs(o.v.y - h.y) <= cfg.cartTol and math.abs(o.v.z - h.z) <= cfg.cartTol and yawDiff(o.v.yaw, h.yaw) <= 1 then
          usedOwn[i] = true; stands[id] = o; break
        end
      end
    end
  end
  for i, o in ipairs(own) do setOwnShown(o.a, o.x, usedOwn[i] and true or false) end
  for id, h in pairs(Q.cartHost) do
    local d = Q.cartDraw[id]
    if stands[id] then
      if d then pcall(function() if d.a:IsValid() then d.a:K2_DestroyActor() end end); Q.cartDraw[id] = nil; bump("cartUndrawn") end
    elseif not d then
      -- the mesh, materials and scale of a cart of this copy, read now (never kept)
      local mesh, mats, sc
      for _, o in ipairs(own) do
        if o.v.c then
          pcall(function() local c = o.v.c; if c:IsValid() and c.StaticMesh:IsValid() then mesh = c.StaticMesh; mats = {}; for k = 0, c:GetNumMaterials() - 1 do mats[#mats + 1] = c:GetMaterial(k) end; local x = c:K2_GetComponentScale(); if x.X > 0.1 then Q.cartScale = { x.X, x.Y, x.Z } end end end)
          if mesh then break end
        end
      end
      if mesh then
        -- the scale of a cart in the world (kept as plain numbers): a spare at the origin has scale 0 (sitting f1: a cart
        -- drawn with a spare's scale was not to be seen); none known yet: the game's 0.88
        local k = Q.cartScale or { 0.88, 0.88, 0.88 }
        local a = newActor(S, mesh, { X = h.x, Y = h.y, Z = h.z }, { Pitch = h.p, Yaw = h.yaw, Roll = h.r }, k[1], k[2], k[3])
        if a then
          pcall(function() local c = a.StaticMeshComponent; for k, mt in ipairs(mats or {}) do if alive(mt) then c:SetMaterial(k - 1, mt) end end end)
          Q.cartDraw[id] = { a = a, from = h, to = h, t0 = clock, done = true }; bump("cartDrawn")
        end
      end
    elseif d.to ~= h then
      d.from = d.to; d.to = h; d.t0 = clock; d.done = false
    end
  end
  for id, d in pairs(Q.cartDraw) do
    if not Q.cartHost[id] then pcall(function() if d.a:IsValid() then d.a:K2_DestroyActor() end end); Q.cartDraw[id] = nil; bump("cartUndrawn") end
  end
  local t = ms(t0); bump("msC", t); if t > (Q.stats.maxMsC or 0) then Q.stats.maxMsC = t end
end

-- ================================================================ link
setHost = function(key, cnt)
  local sum, n = 0, 0
  for s, e in pairs(cnt) do local h = strHash(s); sum = (sum + h * e.n) % 9007199254740881; n = n + e.n end
  Q.hostCnt[key] = cnt; Q.hostSum[key] = sum; Q.hostN[key] = n
  Q.pri[key] = true
end

local function onMessage(S, from, kind, w, line)
  if kind ~= "Q" then return false end
  local sub = w[4]
  if S.role == "host" then
    if sub == "W" and from ~= "host" then
      for n in (w[5] or ""):gmatch("%d+") do Q.meshSaid[tonumber(n)] = nil end
      for k in (w[6] or ""):gmatch("[^|]+") do if Q.B[k] and Q.B[k].sent then Q.resend[#Q.resend + 1] = k end end
      bump("askedHere")
    end
    return true
  end
  if S.role ~= "friend" or from ~= "host" then return true end
  if not Q.hostCnt then return true end
  if sub == "M" then
    local n = tonumber(w[5]); if n and w[6] then Q.meshPath[n] = w[6]; Q.hostMats[w[6]] = w[7] or "" end
  elseif sub == "P" then
    local key, part = w[5], w[6]; local i, of = (part or ""):match("^(%d+)/(%d+)$"); i, of = tonumber(i), tonumber(of)
    if not (key and i and of) then return true end
    if i == 1 then Q.part[key] = { n = 0, cnt = {} } end
    local acc = Q.part[key]; if not acc or acc.n ~= i - 1 then Q.part[key] = nil; return true end
    acc.n = i; Q.hostZ[key] = tonumber(w[7])
    local body = w[8] or "-"
    if body ~= "-" then
      for item in body:gmatch("[^;]+") do
        local n, tail = item:match("^(%d+):(.*)$")
        local m = n and Q.meshPath[tonumber(n)]
        if m then local s = m .. ":" .. tail; local e = acc.cnt[s]; if e then e.n = e.n + 1 else acc.cnt[s] = { n = 1, m = m, t = tail } end
        else acc.bad = true; if n then Q.want[tonumber(n)] = true end end
      end
    end
    if i == of then
      Q.part[key] = nil
      if acc.bad then Q.wantKeys[key] = true; bump("incomplete") else setHost(key, acc.cnt); bump("in") end
    end
  elseif sub == "D" then
    local key, nn = w[5], tonumber(w[6])
    local cur = key and Q.hostCnt[key]
    if not (cur and nn and w[7]) then if key then Q.wantKeys[key] = true end; bump("deltaLost"); return true end
    local cnt = {}; for s, e in pairs(cur) do cnt[s] = { n = e.n, m = e.m, t = e.t } end
    local ok, total = true, 0
    for it in w[7]:gmatch("[^;]+") do
      local sign, n, tail = it:match("^([%+%-])(%d+):(.*)$")
      local m = n and Q.meshPath[tonumber(n)]
      if not m then ok = false; if n then Q.want[tonumber(n)] = true end
      else
        local s = m .. ":" .. tail; local e = cnt[s]
        if not e then e = { n = 0, m = m, t = tail }; cnt[s] = e end
        e.n = e.n + (sign == "+" and 1 or -1); if e.n < 0 then ok = false end
        if e.n == 0 then cnt[s] = nil end
      end
    end
    for _, e in pairs(cnt) do total = total + e.n end
    if not ok or total ~= nn then Q.wantKeys[key] = true; bump("deltaLost") else setHost(key, cnt); bump("inD") end
  elseif sub == "G" then
    local key = w[5]; if key then Q.hostCnt[key] = nil; Q.hostSum[key] = nil; Q.hostN[key] = nil; dropKey(key) end
  elseif sub == "L" then
    local t = {}; for k in (w[5] or ""):gmatch("[^|]+") do if k ~= "-" then t[k] = true end end
    Q.hostStalls = t
    -- a stall of this copy that was hidden because the host lacked it, and that the host has now: its own values come
    for k in pairs(Q.stallOwn) do if t[k] then Q.stallOwn[k] = nil; Q.hostCnt[k] = nil; Q.wantKeys[k] = true end end
  elseif sub == "C" or sub == "K" then
    if sub == "K" then Q.cartHost = {} end
    Q.cartHostSeen = true
    if w[5] == "-" and sub == "C" then
      for id in (w[6] or ""):gmatch("%d+") do Q.cartHost[tonumber(id)] = nil end
    elseif w[5] and w[5] ~= "-" then
      for s in w[5]:gmatch("[^;]+") do local id, h = parseCart(s); if id then Q.cartHost[id] = h end end
    end
  end
  return true
end

-- ================================================================ session
local function fresh(S)
  if Q.S == S and Q.world == S.worlds then return end
  Q.S = S; Q.world = S.worlds
  Q.hint = {}; Q.seen = {}; Q.lens = {}; Q.stock = {}; Q.stockDue = {}; Q.goodsAt = {}; Q.keyAt = {}; Q.pri = {}; Q.low = {}; Q.order = {}; Q.B = {}; Q.job = nil
  Q.lenI = 1; Q.lenDebt = 0; Q.tLen = nil; Q.pass = 1; Q.passes = 0; Q.tRound = 0; Q.roundI = 0; Q.firstDone = false
  Q.matsOf = {}; Q.noMesh = {}; Q.saidMat = {}; Q.nFast = 0
  Q.meshNo = Q.meshNo or {}; Q.nMesh = Q.nMesh or 0; Q.meshSaid = {}; Q.resend = {}                     -- host
  Q.hostCnt = {}; Q.hostSum = {}; Q.hostN = {}; Q.hostZ = {}; Q.part = {}; Q.meshPath = Q.meshPath or {}
  Q.hostMats = Q.hostMats or {}; Q.want = {}; Q.wantKeys = {}; Q.made = {}; Q.acts = {}                  -- friend
  Q.hostStalls = nil; Q.stallOwn = {}; Q.ghostAt = {}; Q.stallSaid = nil; Q.tStall = nil
  Q.carts = {}; Q.newCarts = {}; Q.cartComp = {}; Q.tFind = nil; Q.tCart = nil
  Q.cartId = {}; Q.nCart = Q.nCart or 0; Q.cartSaid = {}; Q.cartLast = {}; Q.cartKey = true              -- host
  Q.cartHost = {}; Q.cartHostSeen = false; Q.cartDraw = {}; Q.ownLast = {}; Q.ownShown = {}; Q.compHid = {}   -- friend
  log("reset for world %d (%s)", S.worlds or 0, tostring(S.role))
end

local function tick(S, clock)
  if not (S and S.eng and S.p1) then return end
  fresh(S)
  if rawget(C, "hold") then return end
  -- the tick's own time, and whether the Lua collector ran in it (the heap shrank): a collector step lands in
  -- whatever code allocates at that moment, in any module, so a long tick with a collector step is counted apart
  local kb0, t0 = collectgarbage("count"), os.clock()
  if S.role == "host" then work(S, clock); hostCarts(S, clock)
  elseif S.role == "friend" then work(S, clock); friendCarts(S, clock) end
  local t, gc = (os.clock() - t0) * 1000, collectgarbage("count") < kb0 - 1
  local st = Q.stats
  st.ticks = (st.ticks or 0) + 1
  if gc then st.gcTicks = (st.gcTicks or 0) + 1; if t > (st.maxTickGC or 0) then st.maxTickGC = t end; if t > 8 then st.over8GC = (st.over8GC or 0) + 1 end
  else if t > (st.maxTickOwn or 0) then st.maxTickOwn = t end; if t > 8 then st.over8Own = (st.over8Own or 0) + 1 end end
end

function Q.status()
  local st = { "readFast=" .. tostring(Q.nFast or 0) }
  for k, v in pairs(Q.stats) do st[#st + 1] = k .. "=" .. (math.tointeger(v) and tostring(math.tointeger(v)) or string.format("%.1f", v)) end
  table.sort(st)
  local nh, nm, nd, nc = 0, 0, 0, 0
  for _ in pairs(Q.hostCnt or {}) do nh = nh + 1 end
  for _, l in pairs(Q.made or {}) do nm = nm + #l end
  for _ in pairs(Q.cartDraw or {}) do nd = nd + 1 end
  for _ in pairs(Q.carts or {}) do nc = nc + 1 end
  return string.format("scene %s passes=%d first=%s buildings=%d host buildings=%d made=%d acts=%d carts here=%d drawn=%d longest=[%s] finish=[%s] | %s", Q.version, Q.passes or 0,
    tostring(Q.firstDone), #(Q.order or {}), nh, nm, #(Q.acts or {}), nc, nd, tostring(Q.maxWhat), tostring(Q.maxFinishWhat), table.concat(st, " "))
end

-- (lane 59) onWorld empties the tables itself (it only marked them before, and the next tick emptied them: a host
-- line "Q G <key>" read before that tick made dropKey call the actors this module spawned in the world before)
C.register("scene", { onWorld = function(S) Q.S = nil; fresh(S) end, tick = tick, onMessage = onMessage })
return "coop_x_scene " .. Q.version .. " loaded"
