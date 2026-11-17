-- Manor Lords Co-op: the free merchants walk where the host's do (lane 58). Loaded after coop_x_men.lua.
--
-- Why (research/2026-11-10-game-probe/lanes/lane_s21_58/report.txt): the free merchants (eng.freeMerchants; one man
-- each, squadType 6 "Merchants", no lord) were carried by nothing. Each copy walked its own: after a friend loaded
-- alone they were a fixed distance apart along the same path (26 to 43 m), and at each path's end each copy rolled its
-- own next destination: after 10 minutes without a resync up to 2.3 km apart, 10 of 20 in another region.
-- (The rp line's squadsPresent count of the daily sample is another matter: each copy's list is filled at its own
--  last load; all 264 entries that differed in lane 58's samples were these merchants. That field stays as it is.)
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
--           lists do not hold is logged (run acc1: one, after a rejoin). Both have code that is OFF and never proven:
--           Coop.m58spawn = true makes the missing one with spawnFreeMerchant, Coop.m58destroy = true takes the extra
--           one out with destroyUnit.
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
local function reset() M.last = {}; M.prev = {}; M.ends = {}; M.fullT = 0; M.sendT = 0; M.set = {}; M.h2l = {}; M.missT = {}; M.extra = {}; M.cam = nil; M.sayT = M.sayT or 0; M.dropQ = nil end   -- (lane 59) dropQ: addresses of the world before are never sent to the native table
if not M.last then reset() end

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
          out[#out + 1] = string.format("%d:%d,%d,%d:%d,%d,%d:%d,%d", h, math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5), math.floor(tx + 0.5), math.floor(ty + 0.5), math.floor(tz + 0.5),
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
-- the local merchant tied to a host number: the same number when that is a merchant here, else one made for it
local function localOf(S, hh, clock, full, x, y, z)
  local lh = M.h2l[hh] or hh
  local u = unitOf(S, lh)
  if u then return u, lh end
  if not full or not C.m58spawn then return nil end      -- (off: never ran; switch Coop.m58spawn = true)
  -- (only from a full list) a host merchant this copy has not: after 2 s, one made with the game's own call
  M.missT[hh] = M.missT[hh] or clock
  if clock - M.missT[hh] < 2.0 then return nil end
  M.missT[hh] = clock + 30.0                                             -- one try, then a wait of 30 s
  local okR, reg = pcall(function() return S.p1:getClosestOwnedRegion() end)
  if not (okR and valid(reg)) then return nil end
  local okS, nu = pcall(function() return S.eng:spawnFreeMerchant(reg) end)
  local v = okS and un(nu)
  if not valid(v) then log("merchants: host merchant %d has none here; spawnFreeMerchant gave nothing", hh); stat(S, "m58spawnFail"); return nil end
  local okH, nh = pcall(function() return v.assignedSquadID.Value end)
  if okH and nh and nh ~= 0 then M.h2l[hh] = nh; M.missT[hh] = nil end
  pcall(function() v.realPos = { X = x, Y = y, Z = z }; v:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true) end)
  stat(S, "m58spawned"); log("merchants: host merchant %d had none here: made one (squad %s) at the host's place", hh, tostring(nh))
  return v, nh
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
  -- the line's age (the sender's wall clock in its second word): on one PC exact; between PCs whose clocks differ it
  -- is held to 0 .. 0.4 s, so a wrong clock moves a merchant by at most 0.4 s of his walk
  local age = (A.now() - (tonumber(w[2]) or A.now())); if age ~= age or age < 0 then age = 0 elseif age > 0.4 then age = 0.4 end
  for e in (w[5] or ""):gmatch("[^;]+") do
    local hh, x, y, z, tx, ty, tz, vx, vy = e:match("^(%d+):(%-?%d+),(%-?%d+),(%-?%d+):(%-?%d+),(%-?%d+),(%-?%d+):(%-?%d+),(%-?%d+)$")
    hh = tonumber(hh)
    if hh then
      x, y, z, tx, ty, tz = tonumber(x), tonumber(y), tonumber(z), tonumber(tx), tonumber(ty), tonumber(tz)
      x, y = x + tonumber(vx) * age, y + tonumber(vy) * age          -- where the host's merchant is now
      if seenH then seenH[hh] = true end
      local u, lh = localOf(S, hh, clock, full, x, y, z)
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
          elseif d2 > PUT * PUT then stat(S, "m58seenSkip") end
        end
        if P and a then
          local s = M.set[a]
          local moved = not s or (tx - s[1]) ^ 2 + (ty - s[2]) ^ 2 >= 50 * 50
          if moved or regive then
            cmds[#cmds + 1] = string.format("MEN SET %s=%d,%d,%d", a, tx, ty, tz); M.set[a] = { tx, ty }; stat(S, "m58set")
            newQ[#newQ + 1] = a
          end
        end
      else stat(S, "m58missing") end
    end
  end
  if P and #cmds > 0 then P.send(table.concat(cmds, "\n")) end
  if #newQ > 0 then M.dropQ = newQ end
  -- a merchant here that the host's full list does not hold (this copy's game made one at a rejoin: taken out)
  if seenH then
    local hl = {}; for hh in pairs(seenH) do hl[M.h2l[hh] or hh] = true end
    local okL, list = pcall(function() return S.eng.freeMerchants end)
    if okL and list then
      local n = #list
      for i = 1, n do
        local u = un(list[i])
        if valid(u) then
          local ok, h = pcall(function() return u.assignedSquadID.Value end)
          if ok and h and h ~= 0 and not hl[h] then
            -- (lane 58, run acc1) after a rejoin the friend had a merchant the host had not (made by this copy's game
            -- in the world's first frames, before the hold below): it walked on its own. Seen in two full lists in a
            -- row (2 s apart): taken out with the game's own destroyUnit
            if not M.extra[h] then M.extra[h] = clock; stat(S, "m58extra"); log("merchants: merchant %d is on this copy only (not on the host's list)", h)
            elseif clock - M.extra[h] >= 1.5 and C.m58destroy then      -- (off: not proven alone yet; switch Coop.m58destroy = true)
              local okD, e = pcall(function() S.eng:destroyUnit(u) end)
              stat(S, okD and "m58destroyed" or "m58destroyFail")
              log("merchants: merchant %d (this copy only) taken out with destroyUnit: %s", h, okD and "ok" or tostring(e))
              M.extra[h] = clock + 30.0                                -- not again for 30 s
            end
          elseif ok and h then M.extra[h] = nil end
        end
      end
    end
  end
end
local function friendTick(S, clock)
  if C.m58off then return end
  -- this copy's game makes no merchants of its own: the host's are made here when needed (onFM)
  pcall(function() if S.eng.spawnMerchants then S.eng.spawnMerchants = false; log("merchants: this copy's own new merchants held off (the host's are made here)") end end)
  if clock - M.sayT >= 60.0 then
    M.sayT = clock; local t = S.stats
    log("merchants: sets %d, puts %d (far %d, seen and kept %d), missing %d, made %d, here only %d (taken out %d), native %s; off as a line came: <2 m %d, 2-5 m %d, 5-10 m %d, more %d",
      t.m58set or 0, t.m58put or 0, t.m58putFar or 0, t.m58seenSkip or 0, t.m58missing or 0, t.m58spawned or 0, t.m58extra or 0, t.m58destroyed or 0, tostring(M.av),
      t.m58d2 or 0, t.m58d5 or 0, t.m58d10 or 0, t.m58dfar or 0)
  end
end

local function tick(S, clock)
  if not (valid(S.eng) and valid(S.p1) and S.sc and valid(S.sc)) then return end
  if S.role == "host" then hostTick(S, clock) elseif S.role == "friend" then friendTick(S, clock) end
end
local function onMessage(S, from, kind, w)
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
