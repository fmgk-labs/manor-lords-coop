-- Manor Lords Co-op: the free merchants walk where the host's do (lane 58). Loaded after coop_x_men.lua.
--
-- Why (research/2026-11-10-game-probe/lanes/lane_s21_58/report.txt): the free merchants (eng.freeMerchants; one man
-- each, squadType 6 "Merchants", no lord) were carried by nothing. Each copy walked its own: after a friend loaded
-- alone they were a fixed distance apart along the same path (26 to 43 m), and at each path's end each copy rolled its
-- own next destination: after 10 minutes without a resync up to 2.3 km apart, 10 of 20 in another region.
-- (The region's squadsPresent list is another matter: each copy's list is filled at its own last load; all 264
--  entries that differed in lane 58's samples were these merchants. Since lane 79 the daily sample does not compare
--  its length; it compares the two answers the game takes from it, "enemies present" and "under attack" (rp line).)
--   host    four times a second, for every free merchant with a man: "FM <full> <squad>:<x>,<y>,<z>:<ex>,<ey>,<ez>:<vx>,<vy>;..."
--           (cm) his own place (SMUnit.realPos; the actor's place stays where he was made), his path's end (where he
--           is going; read once per path) and his velocity (cm/s); only merchants whose place moved 1 m or whose end changed,
--           all of them every 2 s (full = 1).
--   friend  each merchant is found by his squad number (the same on both copies: from the host's save). The host's
--           path end is given with the native MEN SET (coop_x_men's item): its GO gives him the path there at once;
--           a line later he is DROPped from the table again and walks that path by himself at the game's own pace.
--           So he goes where the host's goes (at a path's end, until the host's next end arrives, he may turn
--           towards one of his own for a moment). More than 2.5 m from where the host's merchant is now (his
--           place in the line, moved on by his velocity for the line's age): put there (realPos and
--           the actor, as the men module does), then a fresh GO from there; when the camera sees him (60 m) only
--           beyond 15 m. (First version: the point he walked to now, a GO every few metres: each GO slowed him, 25 %
--           of the lines found him 5 to 10 m behind and he was put back about 17 times a second over 20 merchants.)
--           This copy's game makes no merchants of its own (eng.spawnMerchants held false from the world's start).
--           A host merchant with none of that number here is counted (missing); a merchant here that the host's full
--           lists do not hold is logged (run acc1: one, after a rejoin). The missing one is made with
--           spawnFreeMerchant (off: Coop.m58spawn = false). Removal requires Coop.m58destroy = true.
--           After a reload, making a replacement can turn the saved original into an apparent surplus.
--           Without the native MEN item: the place rule alone.
-- Switch (test, friend): Coop.m58off = true stops the friend's side (the merchants walk on their own, as before).

local C = rawget(_G, "Coop")
if not (C and C.register and C.api) then return "coop_x_merch: load coop.lua first" end
local A = C.api
local M = rawget(C, "merch") or {}; C.merch = M
local valid, log, send, un = A.valid, A.log, A.send, A.un

local PUT, PUT_SEEN, CAM = 250, 1500, 6000          -- cm: put outright beyond 2.5 m (15 m when the camera is within 60 m)
-- (3 m with the DROP after a line, run mod5: 99 % 4.0 m, one merchant 5.1 s over 3 m; 2.5 m since)
local function stat(S, k, n) S.stats[k] = (S.stats[k] or 0) + (n or 1) end
local function hex(u) local ok, a = pcall(function() return u:GetAddress() end); if ok and a and a ~= 0 then return string.format("%X", math.tointeger(a) or a) end end
local function reset() M.last = {}; M.prev = {}; M.ends = {}; M.fullT = 0; M.sendT = 0; M.set = {}; M.h2l = {}; M.missT = {}; M.extra = {}; M.cam = nil; M.sayT = M.sayT or 0; M.dropQ = nil; M.liveA = nil; M.farOn = nil; M.made = {}; M.failed = {}; M.seenK = nil; M.hostNum = nil; M.heldSaid = nil end   -- (lane 59) dropQ: addresses of the world before are never sent to the native table
if not M.last then reset() end
M.made = M.made or {}; M.failed = M.failed or {}

-- the merchant of a squad number on this copy, read in this frame (nil when there is none)
local function unitOf(S, h)
  local ok, u = pcall(function()
    if not S.sc:IsValidSquad({ Value = h }) then return nil end
    local s = S.sc:GetSquad({ Value = h })
    if (tonumber(s.squadType) or 0) ~= 6 then return nil end
    local a = s.unitArr; if #a < 1 then return nil end
    local x = un(a[1]); if valid(x) then return x end
  end)
  if ok then return u end
end

-- ---------------------------------------------------------------- host
local function hostTick(S, clock)
  if clock - M.sendT < 0.25 then return end
  M.sendT = clock
  local full = clock - M.fullT >= 2.0; if full then M.fullT = clock end
  local out, seen = {}, {}
  local okL, list = pcall(function() return S.eng.freeMerchants end)
  if not okL or not list then return end
  local n = #list
  for i = 1, n do
    local u = un(list[i])
    if valid(u) then
      -- his path's end: the path's points are not reflected (PathPoint struct), so the game's own getTargetPos is
      -- asked while his PathPoint is set to the last index for that one call and put back at once (no game tick in
      -- between; lane 58: the end read so stays the same while he walks one path, and PathPoint is back each time).
      -- Read once per path: again only when his path's length changes or his PathPoint goes back (a new path)
      M.ends = M.ends or {}
      local ok, h, x, y, z, tx, ty, tz = pcall(function()
        local h = u.assignedSquadID.Value
        -- (lane 73) a merchant the game made AFTER the save has no squad at all (probe run 10: assignedSquadID 0 on the
        -- host's 21st merchant, and on one made on a friend): he was never sent, so a friend never heard of him. His
        -- key is then "u<his unit id on the host>".
        if h == 0 then h = "u" .. tostring(math.tointeger(u.UniqueID) or u.UniqueID) end
        local p = u.realPos; local np = #u.Path; local pp = u.PathPoint; local t
        local E = M.ends[h]
        if np > 0 and E and E.np == np and pp >= E.pp then E.pp = pp; return h, p.X, p.Y, p.Z, E.x, E.y, E.z end
        if np > 0 then
          if pp ~= np - 1 then u.PathPoint = np - 1; local okT, tt = pcall(function() return u:getTargetPos() end); u.PathPoint = pp; if okT then t = tt end
          else t = u:getTargetPos() end
        end
        if t then M.ends[h] = { np = np, pp = pp, x = t.X, y = t.Y, z = t.Z }; stat(S, "m58endReads") else M.ends[h] = nil end
        t = t or u:getTargetPos()
        return h, p.X, p.Y, p.Z, t.X, t.Y, t.Z end)
      if ok and h and h ~= 0 then
        seen[h] = true
        -- his velocity (cm per second of real time, from the last read): the friend puts him where he is when the line
        -- is read (the line's age times this). A fixed lead of 0.5 s (second version) left the friend's merchants
        -- 3 to 4 m ahead for as long as they walked (the line is under 0.1 s old on one PC).
        M.prev = M.prev or {}
        local pv = M.prev[h]; M.prev[h] = { x, y, clock }
        local vx, vy = 0, 0
        if pv and clock - pv[3] > 0.05 and clock - pv[3] < 1.0 then vx, vy = (x - pv[1]) / (clock - pv[3]), (y - pv[2]) / (clock - pv[3]) end
        if vx * vx + vy * vy > 3000 * 3000 then vx, vy = 0, 0 end      -- over 30 m/s: a jump, not a walk
        local L = M.last[h]
        local moved = not L or (x - L[1]) ^ 2 + (y - L[2]) ^ 2 > 100 * 100 or (tx - L[4]) ^ 2 + (ty - L[5]) ^ 2 > 50 * 50
        if full or moved then
          M.last[h] = { x, y, z, tx, ty }
          out[#out + 1] = string.format("%s:%d,%d,%d:%d,%d,%d:%d,%d", tostring(h), math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5), math.floor(tx + 0.5), math.floor(ty + 0.5), math.floor(tz + 0.5),
            math.floor(vx + 0.5), math.floor(vy + 0.5))
        end
      end
    end
  end
  for h in pairs(M.last) do if not seen[h] then M.last[h] = nil end end
  for h in pairs(M.prev or {}) do if not seen[h] then M.prev[h] = nil end end
  for h in pairs(M.ends or {}) do if not seen[h] then M.ends[h] = nil end end
  if #out == 0 and not full then return end
  -- lines under 3000 characters; the full flag on the last one only (the friend's list check runs after it)
  local part, len = {}, 0
  local function put(f) send("FM " .. f .. " " .. (#part > 0 and table.concat(part, ";") or "-")); stat(S, "m58lines"); part, len = {}, 0 end
  for _, e in ipairs(out) do part[#part + 1] = e; len = len + #e + 1; if len > 3000 then put("0") end end
  put(full and "1" or "0")
  stat(S, "m58sent", #out)
  if full then M.hostExtras(S, clock) end
end

-- (lane 73) unit counts by role (SMUnit.currentUnitRole): 6 the free merchant, 7 the livestock merchant, 15 the pack
-- animal. Read from the engine's unit list (its length first, never past its end).
local function roleCounts(S)
  local c = { [6] = 0, [7] = 0, [15] = 0 }
  local ok = pcall(function()
    local arr = S.eng.unitArr; local n = #arr
    for i = 1, n do
      local u = un(arr[i])
      if valid(u) then local r = tonumber(u.currentUnitRole); if r and c[r] then c[r] = c[r] + 1 end end
    end
  end)
  return ok and c or nil
end
-- host, with every full list: "FL <x>,<y>,<z>:<his workplace: type,x,y or ->;..." (or "-"): the livestock merchants;
-- once a minute "FN <role 6> <role 7> <role 15>": the unit counts the friend compares its own with
function M.hostExtras(S, clock)
  local ent = {}
  pcall(function()
    local lv = S.eng.livestockMerchants; local n = #lv
    for i = 1, n do
      local u = un(lv[i])
      if valid(u) then
        local p = u.realPos; local bk = "-"
        pcall(function() local b = u:getWorkplace(); if valid(b) then local l = b:K2_GetActorLocation(); bk = string.format("%d,%d,%d", A.btype(b), math.floor(l.X + 0.5), math.floor(l.Y + 0.5)) end end)
        ent[#ent + 1] = string.format("%d,%d,%d:%s", math.floor(p.X + 0.5), math.floor(p.Y + 0.5), math.floor(p.Z + 0.5), bk)
      end
    end
  end)
  send("FL " .. (#ent > 0 and table.concat(ent, ";") or "-"))
  if clock - (M.roleT or -100) >= 60.0 then
    M.roleT = clock
    local c = roleCounts(S); if c then send(string.format("FN %d %d %d", c[6], c[7], c[15])) end
  end
end

-- ---------------------------------------------------------------- friend
local function menOk()
  local P = C.patch; if not (P and P.fn) then return nil end
  local now = os.clock()
  if M.avT and now - M.avT < 2.0 then return M.av and P or nil end
  M.avT = now
  local ok, st = pcall(P.status); local it = ok and st and st.items and st.items.MEN
  M.av = it ~= nil and it.state ~= "unavailable"
  return M.av and P or nil
end
local function camera(S, clock)
  local c = M.cam
  if not c or clock - c.t > 0.2 then
    local ok, l = pcall(function() local q = S.p1.Camera:K2_GetComponentLocation(); return { q.X, q.Y } end)
    c = { t = clock, c = ok and l or nil }; M.cam = c
  end
  return c.c
end
-- (lane 73) THE MERCHANT OF THIS COPY FOR A HOST KEY, AND THE MAKING OF A MISSING ONE.
-- What the game does (read in the game file, 4ce4600, and probe run 10 on a friend): spawnFreeMerchant(region) makes
-- the merchant at the map's trade point nearest to the region, with a pack animal (a second unit, role 15), puts him
-- on the engine's freeMerchants list and gives him a way within a second. He gets NO squad (assignedSquadID 0), so
-- lane 58's tie "host squad number -> this copy's squad number" could never hold a made merchant (and the host,
-- which sent only merchants with a squad, never named its own new ones: that is why a friend stayed at 20 against
-- 21). Taken out with destroyUnit, his pack animal STAYS (probe: role 15 one up after each take-out): a stray.
-- spawnLivestockMerchant's unit is taken off its list by the game itself 0.3 to 0.6 s later on a friend and is gone
-- after 7 to 9 s (there is no purchase here for him to deliver): he cannot be made; the 149 of run 4 left nothing.
-- So, per host key (a squad number, or "u<unit id>" for a merchant without a squad):
--   1 the merchant made here for that key (M.made), while the unit lives;
--   2 a number: the merchant of that squad; "u<id>": a merchant of this copy without a squad whose unit id is that
--     id (after this copy loaded the host's save both have the same ids) and that no other key holds;
--   3 else he is missing: after 1 s ONE try with the game's own spawnFreeMerchant. The pack animal is the unit of
--     role 15 that was not there before the call. Both are put at the host's place. A try that gives nothing, or a
--     made merchant the game takes away, is said once and never tried again for that key in this world.
-- He leaves (the animal first, then he, both out of the native table) when two full lists of the host's in a row,
-- 1.5 s apart, do not name his key. Test switch, friend console: Coop.m58spawn = false (nothing is made).
local function role15(S)
  local t = {}
  pcall(function()
    local arr = S.eng.unitArr; local n = #arr
    for i = 1, n do local u = un(arr[i]); if valid(u) and tonumber(u.currentUnitRole) == 15 then local a = hex(u); if a then t[a] = u end end end
  end)
  return t
end
local function ownedByOther(u, key)
  for k, m in pairs(M.made) do if k ~= key and valid(m.u) and m.u:GetAddress() == u:GetAddress() then return true end end
  return false
end
local function localOf(S, hh, clock, x, y, z)
  local m = M.made[hh]
  if m then
    if valid(m.u) then return m.u end
    M.made[hh] = nil
    if not m.adopted then M.failed[hh] = "gone"; stat(S, "m73madeGone"); log("merchants: the merchant made here for the host's %s is gone (the game took him): not made again", tostring(hh)) end
  end
  if type(hh) == "number" then
    local u = unitOf(S, hh)
    if u then return u end
  elseif not M.failed[hh] then
    local id = tonumber(tostring(hh):match("^u(%d+)$"))
    -- (and, when no unit id matches: the nearest merchant of this copy without a squad that no key holds, within 30 m
    -- of where the host's stands: right after a load both copies' merchants stand where the save has them)
    local found, near, nd
    if id then
      pcall(function()
        local list = S.eng.freeMerchants; local n = #list
        for i = 1, n do
          local u = un(list[i])
          -- (game run 11: after this copy loaded the host's save, the host's merchant without a squad had a squad
          -- number HERE (1523397618): he was not taken as the one for the key, a second one was made, and the saved
          -- one was taken out as "on this copy only" without his animal. So: any merchant of this copy that no key
          -- holds and whose squad number the host's last full list does not name.)
          local sq = valid(u) and u.assignedSquadID.Value
          if sq and not found and (sq == 0 or (M.hostNum and not M.hostNum[sq])) and not ownedByOther(u, hh) then
            if tonumber(u.UniqueID) == id then found = u
            else local q = u.realPos; local d = (q.X - x) ^ 2 + (q.Y - y) ^ 2; if d < 3000 * 3000 and (not nd or d < nd) then near, nd = u, d end end
          end
        end
      end)
    end
    if not found and near then found = near; stat(S, "m73adoptedNear") end
    if found then
      M.made[hh] = { u = found, adopted = true }; stat(S, "m73adopted")
      log("merchants: the host's merchant %s is this copy's unit %s (a merchant without a squad, %s): none is made", tostring(hh), tostring(hex(found)), found == near and string.format("%.0f m from the host's", math.sqrt(nd) / 100) or "the same unit id")
      return found
    end
  end
  if C.m58spawn == false or M.failed[hh] or not M.hostNum then return nil end      -- (not before the host's first full list of this world)
  M.missT[hh] = M.missT[hh] or clock
  if clock - M.missT[hh] < 1.0 then return nil end
  M.failed[hh] = "tried"                                -- ONE try per key, whatever comes of it
  local okR, reg = pcall(function() return S.p1:getClosestOwnedRegion() end)
  if not (okR and valid(reg)) then log("merchants: the host's merchant %s has none here; no region of this player's to make him at: left missing", tostring(hh)); stat(S, "m58spawnFail"); return nil end
  local before = role15(S)
  local okS, nu = pcall(function() return S.eng:spawnFreeMerchant(reg) end)
  local v = okS and un(nu)
  if not valid(v) then log("merchants: the host's merchant %s has none here; spawnFreeMerchant gave nothing (%s): left missing", tostring(hh), okS and "no unit" or tostring(nu)); stat(S, "m58spawnFail"); return nil end
  local animal
  for a, u in pairs(role15(S)) do if not before[a] then animal = u end end
  pcall(function() v.realPos = { X = x, Y = y, Z = z }; v:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true) end)
  if valid(animal) then pcall(function() animal.realPos = { X = x + 150, Y = y, Z = z }; animal:K2_SetActorLocation({ X = x + 150, Y = y, Z = z }, false, {}, true) end) end
  M.made[hh] = { u = v, animal = animal }; M.failed[hh] = nil; M.missT[hh] = nil
  stat(S, "m58spawned")
  -- (for the next step: is his pack animal the unit his mountActor names? Then a merchant not made here could be taken out with his animal too)
  local mnt = "no mountActor"
  pcall(function() local ma = un(v.mountActor); if valid(ma) then mnt = (valid(animal) and ma:GetAddress() == animal:GetAddress()) and "his mountActor is that animal" or "his mountActor is another object" end end)
  log("merchants: the host's merchant %s had none here: made one (unit %s, pack animal %s; %s) with spawnFreeMerchant, put at the host's place", tostring(hh), tostring(hex(v)), valid(animal) and tostring(hex(animal)) or "none found", mnt)
  return v
end
-- a merchant made here whose key the host no longer names: his pack animal, then he (both out of the native table)
local function takeOut(S, key, m, cmds)
  local parts = {}
  for _, who in ipairs({ { "pack animal", m.animal }, { "merchant", m.u } }) do
    local u = who[2]
    if valid(u) then
      local a = hex(u)
      if a then cmds[#cmds + 1] = "MEN DROP " .. a; M.set[a] = nil end
      local okD, e = pcall(function() S.eng:destroyUnit(u) end)
      parts[#parts + 1] = who[1] .. " " .. tostring(a) .. (okD and " taken out" or (" NOT taken out: " .. tostring(e)))
    end
  end
  M.made[key] = nil; M.failed[key] = nil; M.missT[key] = nil
  stat(S, "m73madeOut")
  log("merchants: the host no longer names %s: the merchant made here for it goes with the game's destroyUnit (%s)", tostring(key), #parts > 0 and table.concat(parts, "; ") or "he was gone already")
end
local function onFM(S, w)
  if C.hold or C.m58off then return end
  -- the core's engine, lord and squad component are kept from earlier frames: alive in this one, or nothing is done
  if not (valid(S.eng) and valid(S.p1) and S.sc and valid(S.sc)) then stat(S, "m58notReady"); return end
  -- the first 5 s of a world: nothing (the game and the other modules settle first; three friend crashes in this
  -- lane's runs came 3 to 81 s after a friend-alone load, one of them before this module existed)
  -- (the core reads the host's lines BEFORE the modules' onWorld in a world's first tick, and right after a load it
  --  reads again every line the host sent meanwhile (S.replay): so the world's time is the core's S.worldT, and no
  --  replayed line is acted on: run mod5's friend closed 0.3 s after a friend-alone load)
  if S.replay then stat(S, "m58replaySkip"); return end
  if os.clock() - (S.worldT or 0) < 5.0 then stat(S, "m58early"); return end
  local clock = os.clock()
  local full = w[4] == "1"
  local P = menOk()
  local cam = camera(S, clock)
  local seenH = full and {} or nil
  local cmds = {}
  -- (lane 58, acc1 and acc3) a merchant left in the MEN table with his SET place at his path's end, often a kilometre
  -- off, was counted by the native run-off check ("MEN RUNOFF ... not in the table of host places": 21 to 30 lines a
  -- session, using up its 40 dumps): he is in the table only from his SET (its GO gives him the path) to the next
  -- line, then DROPped; he walks the given path by himself. At his path's end he may roll his own next one for the
  -- moment until the host's new end arrives (a line later) and its GO turns him.
  if P and M.dropQ and #M.dropQ > 0 then
    local dl = {}; for _, a in ipairs(M.dropQ) do dl[#dl + 1] = a end
    cmds[#cmds + 1] = "MEN DROP " .. table.concat(dl, ","); stat(S, "m58drop", #dl)
  end
  M.dropQ = nil
  local newQ = {}
  -- (lane 73) HELD, NOT DROPPED. Live (a real session, a friend at 16 to 18 frames a second): about 200 merchants a
  -- minute were put outright, each walking one again every 1.5 to 2.5 s (the native log's MEN DROP storm: 868 of 1082
  -- waits between two drops of the same man were 1.5 to 2.5 s). 2.5 m in 2 s is his whole walking pace: he did not
  -- walk the host's way at all. Taken out of the table a line (0.25 s) after his SET, (a) a GO that waited because he
  -- was busy was lost with him, (b) his own game's "go to my task's place" asks again at every look of his task while
  -- the way he has is not to his task's place (lane 52, KEEP), and no longer got the host's place: he walked to his own
  -- end or stood, and was put back when 2.5 m off. (Lane 58 measured him better while he was held, s8; the DROP came
  -- only to keep him out of the native run-off dumps.) With a native piece that knows the far-held mark ("fars=" in
  -- its status; SET ...,3: held, but no pace rule, run-off check, REGO or halt count for him) he stays in the table.
  -- He leaves it when a full list of the host's no longer names him (his address may be given to another unit), and
  -- with every MEN FORGET. Test switch, friend console: Coop.m73merch = false (the SET and DROP of before).
  local far = P and C.men and C.men.farOk and C.m73merch ~= false or false
  if P and M.farOn and not far then                    -- switched off: nobody stays held
    local dl = {}; for a in pairs(M.set) do dl[#dl + 1] = a end
    if #dl > 0 then cmds[#cmds + 1] = "MEN DROP " .. table.concat(dl, ",") end
    M.set = {}
  end
  M.farOn = far
  M.liveA = M.liveA or {}
  -- the line's age (the sender's wall clock in its second word): on one PC exact; between PCs whose clocks differ it
  -- is held to 0 .. 0.4 s, so a wrong clock moves a merchant by at most 0.4 s of his walk
  -- (lane 73) by the HOST's clock as this copy measured it (coop_x_men.lua, lineLag): in the first real session the
  -- friends' clocks were 0.3 and 0.9 s behind the host's and this age was 0 for every line
  local age
  if C.men and C.men.lineLag then age = C.men.lineLag(w[2], 0.4)
  else age = (A.now() - (tonumber(w[2]) or A.now())); if age ~= age or age < 0 then age = 0 elseif age > 0.4 then age = 0.4 end end
  for e in (w[5] or ""):gmatch("[^;]+") do
    local hh, x, y, z, tx, ty, tz, vx, vy = e:match("^(%w+):(%-?%d+),(%-?%d+),(%-?%d+):(%-?%d+),(%-?%d+),(%-?%d+):(%-?%d+),(%-?%d+)$")
    hh = tonumber(hh) or hh                              -- (lane 73) a squad number, or "u<unit id>" (a merchant without a squad)
    if hh then
      M.seenK = M.seenK or {}; M.seenK[hh] = true
      x, y, z, tx, ty, tz = tonumber(x), tonumber(y), tonumber(z), tonumber(tx), tonumber(ty), tonumber(tz)
      x, y = x + tonumber(vx) * age, y + tonumber(vy) * age          -- where the host's merchant is now
      if seenH then seenH[hh] = true end
      local u = localOf(S, hh, clock, x, y, z)
      if u then
        local a = hex(u)
        local okP, p = pcall(function() local q = u.realPos; return { q.X, q.Y } end)
        local regive = false
        if okP and p then
          local d2 = (p[1] - x) ^ 2 + (p[2] - y) ^ 2
          -- (test numbers) how far from the host's place, as the line arrives: under 2 m, 2 to 5, 5 to 10, beyond
          stat(S, d2 < 200 * 200 and "m58d2" or (d2 < 500 * 500 and "m58d5" or (d2 < 1000 * 1000 and "m58d10" or "m58dfar")))
          local seen = cam and ((p[1] - cam[1]) ^ 2 + (p[2] - cam[2]) ^ 2 < CAM * CAM or (x - cam[1]) ^ 2 + (y - cam[2]) ^ 2 < CAM * CAM)
          local lim = seen and PUT_SEEN or PUT
          if d2 > lim * lim then
            local okW = pcall(function() u.realPos = { X = x, Y = y, Z = z }; u:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true) end)
            if okW then regive = true; stat(S, "m58put"); if d2 > 4000 * 4000 then stat(S, "m58putFar") end else stat(S, "m58putFail") end
            -- (lane 73) where he was against the host's merchant's walk when he was put: behind him, ahead of him, or
            -- beside (or the host's stood). Live, a friend put about 200 merchants a minute (each followed by a MEN DROP
            -- in the native log) and nothing said on which side they had been.
            if okW then
              local hvx, hvy = tonumber(vx) or 0, tonumber(vy) or 0; local hv = math.sqrt(hvx * hvx + hvy * hvy)
              local al = hv > 20 and ((p[1] - x) * hvx + (p[2] - y) * hvy) / hv or 0
              stat(S, (al < -150 and "m58putBehind") or (al > 150 and "m58putAhead") or "m58putBeside")
            end
          elseif d2 > PUT * PUT then stat(S, "m58seenSkip") end
        end
        if P and a then
          M.liveA[a] = true
          local s = M.set[a]
          local moved = not s or (tx - s[1]) ^ 2 + (ty - s[2]) ^ 2 >= 50 * 50
          if moved or regive then
            if far then
              -- put outright: out of the table first, so the SET gives him a GO from where he is now (the same place
              -- again is not given twice; the men module does the same for a man it puts)
              if regive and s then cmds[#cmds + 1] = "MEN DROP " .. a end
              cmds[#cmds + 1] = string.format("MEN SET %s=%d,%d,%d,3", a, tx, ty, tz); M.set[a] = { tx, ty }; stat(S, "m58set")
            else
              cmds[#cmds + 1] = string.format("MEN SET %s=%d,%d,%d", a, tx, ty, tz); M.set[a] = { tx, ty }; stat(S, "m58set")
              newQ[#newQ + 1] = a
            end
          end
        end
      else stat(S, "m58missing") end
    end
  end
  -- (lane 73) a held merchant no line since the last full list named (gone, or another unit by now): out of the table
  if full then
    if far then
      local dl = {}
      for a in pairs(M.set) do if not M.liveA[a] then dl[#dl + 1] = a end end
      for _, a in ipairs(dl) do M.set[a] = nil end
      if #dl > 0 then cmds[#cmds + 1] = "MEN DROP " .. table.concat(dl, ","); stat(S, "m58goneDrop", #dl) end
    end
    M.liveA = {}
    -- (lane 73) a merchant made here whose key no line since the last full list named: after two such lists he goes
    for key, m in pairs(M.made) do
      do
        if not m.animal then pcall(function() local ma = un(m.u.mountActor); if valid(ma) and tonumber(ma.currentUnitRole) == 15 then m.animal = ma end end) end
        if M.seenK and M.seenK[key] then m.miss = nil; m.missT = nil
        else
          m.miss = (m.miss or 0) + 1; m.missT = m.missT or clock
          if m.miss >= 2 and clock - m.missT >= 1.5 and C.m58destroy == true then takeOut(S, key, m, cmds) end
        end
      end
    end
    M.hostNum = {}; for k in pairs(M.seenK or {}) do if type(k) == "number" then M.hostNum[k] = true end end
    -- (every key the host named since its last full list: a full list over 3000 characters comes in several lines and
    --  only the last one carries the full flag, so that line's own keys alone are not the whole list)
    seenH = M.seenK or seenH
    M.seenK = {}
  end
  if P and #cmds > 0 then P.send(table.concat(cmds, "\n")) end
  if #newQ > 0 then M.dropQ = newQ end
  -- a merchant here that the host's full list does not hold (this copy's game made one at a rejoin: taken out)
  if seenH then
    local hl, nHost = {}, 0; for hh in pairs(seenH) do hl[M.h2l[hh] or hh] = true; nHost = nHost + 1 end
    local okL, list = pcall(function() return S.eng.freeMerchants end)
    if okL and list then
      local n = #list
      local extraNow = 0                                               -- (lane 64) how many this full list leaves over, now
      -- (lane 73, after lane 64's live finding: 5 s after each of three loads EVERY merchant of a friend's copy was
      -- "on this copy only" at once (3, 6, 15), while that copy had one merchant FEWER than the host.) A copy has
      -- merchants to take out only when it has MORE than the host names; so no more go than that surplus. A list that
      -- leaves over more than the surplus is a list whose numbers do not tie (a load), not a list to remove by:
      -- nobody goes, and the 1.5 s start again.
      local nHere, flagged = 0, 0
      for i = 1, n do
        local u = un(list[i])
        if valid(u) then
          nHere = nHere + 1
          local ok, h = pcall(function() return u.assignedSquadID.Value end)
          if ok and h and h ~= 0 and not hl[h] and not ownedByOther(u, false) then flagged = flagged + 1 end
        end
      end
      local removeOk = flagged > 0 and flagged <= nHere - nHost
      if flagged > 0 and not removeOk then
        stat(S, "m73extraHeld")
        if not M.heldSaid then M.heldSaid = true; log("merchants: %d of this copy's %d merchants are not on the host's list of %d: more than this copy has over the host's, so none is taken out (said once a world)", flagged, nHere, nHost) end
      end
      -- (from the list's end to its start, and never past its end: a merchant taken out leaves the list at once)
      for i = n, 1, -1 do
        local u = i <= #list and un(list[i]) or nil
        if valid(u) then
          local ok, h = pcall(function() return u.assignedSquadID.Value end)
          if ok and h and h ~= 0 and not hl[h] and not ownedByOther(u, false) then      -- (not a merchant a key holds)
            extraNow = extraNow + 1
            -- (lane 58, run acc1) after a rejoin the friend had a merchant the host had not (made by this copy's game
            -- in the world's first frames, before the hold below): it walked on its own. Seen in two full lists in a
            -- row (2 s apart): taken out with the game's own destroyUnit
            if not M.extra[h] then M.extra[h] = clock; stat(S, "m58extra"); log("merchants: merchant %d is on this copy only (not on the host's list)", h)
            elseif not removeOk then if M.extra[h] < clock then M.extra[h] = clock end      -- (the 1.5 s start again)
            elseif clock - M.extra[h] >= 1.5 and C.m58destroy == true then
              -- out of the native table first (his address is free for another unit the moment he is destroyed)
              local a0 = hex(u); if a0 and M.set[a0] then M.set[a0] = nil; if P then pcall(P.send, "MEN DROP " .. a0) end end
              -- (lane 73) his pack animal first (his mountActor: run 11), or it stays behind as a stray
              pcall(function() local ma = un(u.mountActor); if valid(ma) and tonumber(ma.currentUnitRole) == 15 then S.eng:destroyUnit(ma); stat(S, "m73animalOut") end end)
              local okD, e = pcall(function() S.eng:destroyUnit(u) end)
              stat(S, okD and "m58destroyed" or "m58destroyFail")
              log("merchants: merchant %d (this copy only) taken out with destroyUnit: %s", h, okD and "ok" or tostring(e))
              M.extra[h] = clock + 30.0                                -- not again for 30 s
            end
          elseif ok and h then M.extra[h] = nil end
        end
      end
      S.stats.m58extraNow = extraNow
    end
  end
end
-- (lane 73) THE LIVESTOCK MERCHANTS (unit role 7; nobody made or named one on a friend: "role7 1/absent" in every
-- long run). They are told apart by their place in the engine's list (there is one, seldom two). Fewer here than on
-- the host for 1 s: one is made with the game's own spawnLivestockMerchant at the building the host names (his
-- workplace; else the building of that type nearest to where the host's stands), and put where the host's stands.
-- More here than on the host in two lists in a row: the last one goes (destroyUnit). His walk is NOT carried yet.
-- Test switches, friend console: Coop.m73lvspawn = false, Coop.m73lvdestroy = false.
local function findBuilding(S, key, x, y)
  local bt, bx, by = (key or ""):match("^(%d+),(%-?%d+),(%-?%d+)$"); bt, bx, by = tonumber(bt), tonumber(bx), tonumber(by)
  local best, bd
  pcall(function()
    local arr = S.eng.buildingArr; local n = #arr
    for i = 1, n do
      local b = un(arr[i])
      if valid(b) then
        local l = b:K2_GetActorLocation()
        if bt and A.btype(b) == bt and math.abs(l.X - bx) < 60 and math.abs(l.Y - by) < 60 then best = b; return end
        if not bt and A.btype(b) == 79 then local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2; if not bd or d < bd then best, bd = b, d end end
      end
    end
  end)
  return best
end
local function onFL(S, w)
  if C.hold or C.m58off or S.replay then return end
  if not (valid(S.eng) and valid(S.p1)) or os.clock() - (S.worldT or 0) < 5.0 then return end
  local clock = os.clock()
  local host = {}
  for e in (w[4] or ""):gmatch("[^;]+") do
    local x, y, z, bk = e:match("^(%-?%d+),(%-?%d+),(%-?%d+):(.+)$")
    if x then host[#host + 1] = { tonumber(x), tonumber(y), tonumber(z), bk } end
  end
  local here = {}
  local okL = pcall(function() local lv = S.eng.livestockMerchants; local n = #lv; for i = 1, n do local u = un(lv[i]); if valid(u) then here[#here + 1] = u end end end)
  if not okL then return end
  M.lvHost, M.lvHere = #host, #here
  if #here < #host then
    M.lvExtraT = nil; M.lvMissT = M.lvMissT or clock
    -- (game run 4: the unit spawnLivestockMerchant gave did NOT show in this copy's list of livestock merchants, nor
    -- as a unit of role 7, so one was made at every list: 149 in 20 minutes. ONE try per number the host has; when
    -- this copy's list does not grow by it, that is said once and nothing more is made until the host's number changes.)
    if M.lvTried == #host then
      if not M.lvTriedSaid then M.lvTriedSaid = true; log("merchants: the livestock merchant made here did not join this copy's list (%d here, %d on the host): no more are made until the host's number changes", #here, #host); stat(S, "m73lvNoJoin") end
      return
    end
    if C.m73lvspawn ~= true or clock - M.lvMissT < 1.0 or clock < (M.lvWait or 0) then return end      -- (off by default: see localOf; Coop.m73lvspawn = true)
    M.lvTried = #host; M.lvTriedSaid = nil
    local h = host[#here + 1]
    local b = findBuilding(S, h[4] ~= "-" and h[4] or nil, h[1], h[2])
    if not b then
      M.lvWait = clock + 30.0
      log("merchants: the host has a livestock merchant this copy lacks, and no building to make him at was found here (%s)", tostring(h[4])); stat(S, "m73lvNoBuilding"); return
    end
    local okS, nu = pcall(function() return S.eng:spawnLivestockMerchant(b) end)
    local v = okS and un(nu)
    if not valid(v) then
      M.lvWait = clock + 30.0
      log("merchants: the host has a livestock merchant this copy lacks; spawnLivestockMerchant gave nothing (%s)", okS and "no unit" or tostring(nu)); stat(S, "m73lvSpawnFail"); return
    end
    pcall(function() v.realPos = { X = h[1], Y = h[2], Z = h[3] }; v:K2_SetActorLocation({ X = h[1], Y = h[2], Z = h[3] }, false, {}, true) end)
    M.lvMissT = nil; stat(S, "m73lvMade")
    log("merchants: livestock merchant %d of %d on the host had none here: made one (unit %s) at the host's place, building %s", #here + 1, #host, tostring(hex(v)), tostring(h[4]))
  elseif #here > #host then
    M.lvMissT = nil
    if not M.lvExtraT then M.lvExtraT = clock; return end
    if C.m73lvdestroy == false or clock - M.lvExtraT < 1.5 then return end
    local u = here[#here]
    local a = hex(u)
    local okD, e = pcall(function() S.eng:destroyUnit(u) end)
    M.lvExtraT = nil; stat(S, okD and "m73lvGone" or "m73lvGoneFail")
    log("merchants: this copy has %d livestock merchant(s), the host %d: the last one (unit %s) taken out with destroyUnit: %s", #here, #host, tostring(a), okD and "ok" or tostring(e))
  else M.lvMissT = nil; M.lvExtraT = nil; M.lvTried = nil end
end
local function friendTick(S, clock)
  if C.m58off then return end
  -- this copy's game makes no merchants of its own: the host's are made here when needed (onFM)
  pcall(function() if S.eng.spawnMerchants then S.eng.spawnMerchants = false; log("merchants: this copy's own new merchants held off (the host's are made here)") end end)
  if clock - M.sayT >= 60.0 then
    M.sayT = clock; local t = S.stats
    -- (lane 64) "here only": how many the host's last full list left over NOW, then how often one was seen so (a
    -- count that only grows, over every load of the session). The live session of 2026-11-17: "here only 24" was
    -- 3 + 6 + 15 sightings, each 5 s after one of three loads, and each time EVERY merchant of this copy was named at
    -- once, while the daily sample showed this copy one merchant SHORT of the host's (freeMerchants 4/3, 7/6, 16/15).
    -- So the first full list a friend acts on after a load is not a list to remove by: two such lists 1.5 s apart
    -- would take out every merchant of this copy. (Lane 73) The removal is on, and held by three rules in onFM: a
    -- merchant a host key holds (taken by unit id or place after a load) is never "here only"; no more are taken out
    -- than this copy has over the host's count; a list that leaves over more than that takes out nobody.
    log("merchants: sets %d, puts %d (far %d, seen and kept %d), missing %d, made %d, here only now %d (seen so %d times, taken out %d), native %s; off as a line came: <2 m %d, 2-5 m %d, 5-10 m %d, more %d; put from behind the host's %d, from ahead %d, from beside %d",
      t.m58set or 0, t.m58put or 0, t.m58putFar or 0, t.m58seenSkip or 0, t.m58missing or 0, t.m58spawned or 0, t.m58extraNow or 0, t.m58extra or 0, t.m58destroyed or 0, tostring(M.av) .. (M.farOn and ", held in the table" or ""),
      t.m58d2 or 0, t.m58d5 or 0, t.m58d10 or 0, t.m58dfar or 0, t.m58putBehind or 0, t.m58putAhead or 0, t.m58putBeside or 0)
    -- (lane 73) the unit counts the host has and this copy has: free merchants (role 6), livestock merchants (7), pack animals (15)
    local c = roleCounts(S); local h = M.hostRoles
    if c and h then
      log("merchants: units here / on the host: free merchants %d / %d, livestock merchants %d / %d, pack animals %d / %d: %s; livestock merchants made %d, taken out %d",
          c[6], h[1], c[7], h[2], c[15], h[3], (c[6] == h[1] and c[7] == h[2] and c[15] == h[3]) and "equal" or "DIFFERENT", t.m73lvMade or 0, t.m73lvGone or 0)
    end
  end
end

local function tick(S, clock)
  if not (valid(S.eng) and valid(S.p1) and S.sc and valid(S.sc)) then return end
  if S.role == "host" then hostTick(S, clock) elseif S.role == "friend" then friendTick(S, clock) end
end
local function onMessage(S, from, kind, w)
  if kind == "FL" then if S.role == "friend" and from == "host" then onFL(S, w) end; return true end
  if kind == "FN" then
    if S.role == "friend" and from == "host" then M.hostRoles = { tonumber(w[4]) or 0, tonumber(w[5]) or 0, tonumber(w[6]) or 0 } end
    return true
  end
  if kind ~= "FM" then return false end
  if S.role == "friend" and from == "host" then onFM(S, w) end
  return true
end

-- a world was loaded: the men module's MEN FORGET emptied the native table (every merchant is set again)
C.register("merch", { onWorld = function(S)
  -- (lane 59) entries this module put into the native table of held men in the world before (their addresses): out,
  -- whichever of this module's and the men module's onWorld runs first
  if M.set and next(M.set) then local P = C.patch; if P and P.fn and P.send then pcall(P.send, "MEN FORGET") end end
  reset(); M.worldT = os.clock(); if S.role == "friend" and not C.m58off then pcall(function() S.eng.spawnMerchants = false end) end end, tick = tick, onMessage = onMessage })
return "coop_x_merch loaded"
