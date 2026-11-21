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
--           (lane 82) WHO IS WHO, MAKING AND TAKING OUT: see "THE INVENTORY" below. The host names every merchant by
--           his unit id ("u<id>") and sends its whole list every 0.75 s (FI); this copy pairs each of the host's with
--           one of its own (M.plan), makes one only for a host merchant left without, and takes one out only when it
--           has more than the host (the unpaired remainder, seen so in two lists).
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
local function reset() M.last = {}; M.prev = {}; M.ends = {}; M.fullT = 0; M.sendT = 0; M.set = {}; M.cam = nil; M.sayT = M.sayT or 0; M.dropQ = nil; M.liveA = nil; M.farOn = nil; M.failed = {}; M.pair = {}; M.pairId = {}; M.pairU = {}; M.steady = false; M.leftN = {}; M.missN = {}; M.madeN = {}; M.inv = nil; M.invT = 0; M.hostW = nil; M.plans = 0; M.cnt = nil; M.snap = nil; M.snapW = nil; M.hostIds = nil; M.lv = {}; M.lvExtra = nil; M.lvGrace = nil; M.lvEnds = {}; M.lvPrev = {}; M.lvAn = {}; M.lvAnUsed = {}; M.lvAnAfter = {}; M.lvAnF = {}; M.lvAEnds = {}; M.lvN = nil; M.lvSentT = nil; M.lvLineT = nil end   -- (lane 59) dropQ: addresses of the world before are never sent to the native table
if not M.last then reset() end
M.failed = M.failed or {}
-- (lane 82b) a friend acts on the host's merchant lines (FI, FM, FV) only after this many seconds of its world
-- (core's S.worldT). Coop.m82wait = <s> on a friend's console sets another (a test switch).
-- It was 5 s (lane 58: "acting in a world's first seconds closed friends"). What lane 58 measured: friends closed
-- after a load of their own in 5 of 6 test-build runs, the control runs WITHOUT this module among them (ctl1, bis1),
-- and the shipped zip in none: the wait was never shown to protect against those closings. What it cost: by the
-- strict 3 s measure a friend showed the save's merchants for 5.1 to 5.9 s after each load of its own (proof4). Run
-- w15a (lane 82b, 9 loads, 6 of the friend alone and 3 of every copy, with the host making and taking out merchants
-- around them) at 1.5 s: the host's list acted on 1.8 to 2.3 s after the friend's attach, 0 wrong removals, no
-- difference over 3 s, the strict measure's longest stretch 1.0 s (the test's own merchant made on the friend),
-- 0 new crash records, 0 mod errors. (The events module already makes bodies 1.0 s into a world.)
M.EARLY = 1.5
function M.early() local v = tonumber(rawget(C, "m82wait")); if v and v >= 0 then return v end return M.EARLY end

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
        -- (lane 82) his key is "u<his unit id on the host>", for every merchant, as in the host's FI list. (Lane 58
        -- used his squad number, lane 73 the unit id only for a merchant without a squad. Probe P1 of lane 82: a
        -- merchant the game made after the host's load has squad 0 on the host and a squad number on a friend that
        -- loaded the save, so such a merchant looked "on this copy only" after every load of a friend.)
        local h = "u" .. tostring(math.tointeger(u.UniqueID) or u.UniqueID)
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
-- host, once a minute: "FN <role 6> <role 7> <role 15>": the unit counts the friend compares its own with (its
-- minute line). (The livestock merchants themselves: the FV line, see "THE LIVESTOCK MERCHANTS".)
function M.hostExtras(S, clock)
  if clock - (M.roleT or -100) >= 60.0 then
    M.roleT = clock
    local c = roleCounts(S); if c then send(string.format("FN %d %d %d", c[6], c[7], c[15])) end
  end
end
-- (lane 82b) The friend's minute line compared this copy's counts of NOW with the host's FN line of up to a minute
-- before (the session check l82b: "livestock merchants 1 / 0 ... DIFFERENT" and "0 / 1" a minute later, 4 of 20
-- lines, while the daily sample found no difference). Now like with like: when an FN line comes, this copy counts
-- its own at once and every 0.5 s after, for 3 s from the host's moment (the line's age taken off). A role is
-- "equal" when one of these counts was the host's; else it is DIFFERENT (for over 3 s). The minute line says the
-- verdict of the last finished window. M.fnJudge is pure: the desk test runs it.
--   win = { t = clock of the line's arrival, age = its age (s), h = { [6], [7], [15] }, c = this copy's counts at the
--   reading nearest to equal so far, eq = { [role] = true }, done = false }
local FN_WINDOW, FN_EVERY = 3.0, 0.5
function M.fnJudge(win, c, clock)
  if not win or win.done then return win end
  if c then
    win.c = win.c or {}
    for _, r in ipairs({ 6, 7, 15 }) do
      if c[r] == win.h[r] then win.eq[r] = true; win.c[r] = c[r] elseif not win.eq[r] then win.c[r] = c[r] end
    end
    win.n = (win.n or 0) + 1
  end
  if (win.eq[6] and win.eq[7] and win.eq[15]) or clock - win.t + (win.age or 0) >= FN_WINDOW then
    win.done = true
    win.verdict = (win.eq[6] and win.eq[7] and win.eq[15]) and "equal" or "DIFFERENT"
  end
  return win
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
-- (lane 82) THE INVENTORY: WHO IS WHO, MAKING A MISSING MERCHANT, TAKING OUT AN EXTRA ONE.
-- What went wrong before (lane 64 live, lane 73 run 13): a merchant's key was his squad number. A merchant the game
-- made after the host's own load has squad 0 on the host and gets a squad number on a friend that loads the save, so
-- 5 s after each load such merchants were "on this copy only"; the friend made a replacement for the host's key and
-- then took out the merchant from the save, with his animal, inside its surplus of one.
-- What holds (probe P1 and the proof run of lane 82, out/d0..d3, out/proof1_r*_before_*): a merchant's squad number,
-- when he has one in the save, is the same on every copy that loaded it. His unit id (SMUnit.UniqueID) is NOT the same
-- for ever: a load gives every unit a new id in the save's order (the host's 319, 321, 322 .. 534 were 321, 323, 324
-- .. 528 on a friend that had loaded alone twice; the host's 541 was the friend's 545 while the host had another 545),
-- so equal ids name different merchants, but the ORDER of the ids is the same on both copies. A merchant's pack
-- animal is his mountActor on both copies (8 of 8, 9 of 9).
--   host    every 0.75 s "FI <its world number> <list number> <how many merchants> <part> <parts> <entries>", an entry
--           "<unit id>:<squad number>:<his pack animal's unit id or 0>:<x>,<y>,<z>:<region tag or ->" (cm; the region
--           whose tradeRouteMerchants list holds him, lane 82b), "-" for none. The whole list,
--           in parts of under 3000 characters.
--   friend  acts on a list only when it is WHOLE (every part of one list number, as many entries as the host says), was
--           written under 2 s ago by the host's clock, is no replayed line, and this copy's world is 5 s old. Then ONE
--           plan per list (M.plan, a function of the two lists alone: the desk test runs it):
--             1 kept    the pair of the list before, while both are still there (so a merchant made here stays the
--                       one of his key, whatever his own unit id is);
--                       After a load of this copy alone the first plan's "pairs before" are WHO STOOD WHERE AT THE
--                       SAVE: the first list the host wrote after its save (the first replayed FI line, at most
--                       0.75 s after the save) against this copy's merchants at its world's first tick (the save's
--                       places), by squad, order and place under 15 m. (Proof run 2: with the lists of 5.6 s later
--                       the host's merchants had walked 85 m on, more than the 18 m between merchants walking in
--                       a line, and when the host had taken one of that line out after the save, the LAST of the
--                       line went here, 153 m from the right one, and the others moved up one.)
--             2 squad   the same squad number (not 0), under 300 m apart;
--             3 order   what is left of both lists, each sorted by unit id, aligned in that order: as many pairs
--                       under 300 m apart as can be, then the smallest sum of distances;
--             4 place   the nearest pair under 100 m apart, nearest first;
--             5 far     ONLY until this world has had one plan that paired every merchant of both copies (after a
--                       load), and for a key whose making failed: what is left on both sides is paired nearest
--                       first at any distance. So after a load no merchant is made while this copy still has an
--                       unpaired one, and none is taken out while the host still has an unpaired one.
--           What is left of the host's list is MISSING here: seen so in two lists, the merchant is made with the game's
--           own spawnFreeMerchant, ONE try per key (his animal comes with him; it is taken out again when the host's
--           has none). What is left of this copy's merchants is EXTRA: seen so in two lists at least 0.6 s apart, and
--           only as many as this copy has MORE merchants than the host's list (never more than that surplus), he is
--           taken out with the game's own destroyUnit, his pack animal (his mountActor) first.
-- A merchant the host has is paired, and a paired merchant is never taken out. Test switches, friend console:
-- Coop.m58spawn = false (nothing is made), Coop.m58destroy = false (nobody is taken out).
local NEAR = 10000                                      -- cm: "the same merchant" by place only under 100 m
local ORDER_LIM = 30000                                 -- cm: by squad number or by the order of the unit ids under 300 m
local SAVE_LIM = 1500                                   -- cm: at the save's moment under 15 m
local INV_EVERY, INV_MAX_AGE, CONFIRM = 0.75, 2.0, 0.6
-- (lane 82) ON by default since the proof runs of lane 82 (report.txt: 3 runs of 9 loads each and two sessions of
-- 30 game days, 0 wrong removals). Coop.m58destroy = false on a friend's console switches the taking out off.
local function destroyOn() return C.m58destroy ~= false end
local function iid(x) x = tonumber(x); return x and (math.tointeger(x) or x) or -1 end

-- THE PLAN (pure: no game object is read). host = { { key, id, sq, x, y, mount }, ... } (the host's whole list; mount
-- = his pack animal's unit id or 0), here = { { ref, id, sq, x, y, mount }, ... } (this copy's merchants; ref is any
-- value that names the unit, mount = true with a pack animal), prior = key -> ref of the plan before, opt.far = true
-- (pair what is left at any distance), opt.farKeys[key] = true (for that key only).
-- Returns { pair = key -> ref, how = key -> "kept" | "squad" | "order" | "place" | "far", make = { key, ... } (the
-- host's without one here), left = { ref, ... } (this copy's without one on the host), n = counts per how }.
function M.plan(host, here, prior, opt)
  opt = opt or {}
  local LIM, NEARL = opt.lim or ORDER_LIM, opt.near or NEAR            -- (opt.lim, opt.near: the save-moment pairing asks for 15 m)
  local P = { pair = {}, how = {}, make = {}, left = {}, n = { kept = 0, squad = 0, order = 0, place = 0, far = 0 } }
  local used, byRef = {}, {}
  for _, l in ipairs(here) do byRef[l.ref] = l end
  local function take(h, l, how) P.pair[h.key] = l.ref; P.how[h.key] = how; used[l.ref] = true; P.n[how] = P.n[how] + 1 end
  local function d2(h, l) return (h.x - l.x) ^ 2 + (h.y - l.y) ^ 2 end
  -- (a pair of one with and one without a pack animal is the last choice at any step: it costs 10 km more)
  local function cost(h, l) local d = math.sqrt(d2(h, l)); if ((h.mount or 0) ~= 0) ~= (l.mount and true or false) then d = d + 1e6 end; return d end
  -- 1 kept
  for _, h in ipairs(host) do
    local ref = prior and prior[h.key]
    if ref ~= nil and byRef[ref] and not used[ref] then take(h, byRef[ref], "kept") end
  end
  -- 2 squad: the same squad number (not 0), under 300 m apart
  for _, h in ipairs(host) do
    if P.pair[h.key] == nil and h.sq and h.sq ~= 0 then
      for _, l in ipairs(here) do
        if not used[l.ref] and l.sq == h.sq and d2(h, l) < LIM * LIM then take(h, l, "squad"); break end
      end
    end
  end
  -- 3 order: what is left of both lists, each in the order of its unit ids, is aligned in that order (a load gives
  -- every unit a new id in the save's order: the numbers differ between a copy that loaded and one that did not, the
  -- order does not). As many pairs as can be under 300 m apart, then the smallest sum of distances.
  do
    local hs, ls = {}, {}
    for _, h in ipairs(host) do if P.pair[h.key] == nil and h.id and h.id >= 0 then hs[#hs + 1] = h end end
    for _, l in ipairs(here) do if not used[l.ref] and l.id and l.id >= 0 then ls[#ls + 1] = l end end
    table.sort(hs, function(a, b) return a.id < b.id end); table.sort(ls, function(a, b) return a.id < b.id end)
    local n, m = #hs, #ls
    if n > 0 and m > 0 then
      local SKIP = 1e9
      local dp, mv = {}, {}
      for i = 0, n do dp[i] = {}; mv[i] = {}; for j = 0, m do dp[i][j] = 0; mv[i][j] = 0 end end
      for i = 1, n do dp[i][0] = i * SKIP; mv[i][0] = 1 end
      for j = 1, m do dp[0][j] = j * SKIP; mv[0][j] = 2 end
      for i = 1, n do
        for j = 1, m do
          local best, how = dp[i - 1][j] + SKIP, 1                      -- the host's i-th has none here
          local c = dp[i][j - 1] + SKIP; if c < best then best, how = c, 2 end      -- this copy's j-th has none on the host
          if d2(hs[i], ls[j]) < LIM * LIM then c = dp[i - 1][j - 1] + cost(hs[i], ls[j]); if c <= best then best, how = c, 3 end end
          dp[i][j] = best; mv[i][j] = how
        end
      end
      local i, j = n, m
      while i > 0 and j > 0 do
        local how = mv[i][j]
        if how == 3 then take(hs[i], ls[j], "order"); i = i - 1; j = j - 1 elseif how == 1 then i = i - 1 else j = j - 1 end
      end
    end
  end
  -- 4 place, 5 far: nearest first (the same order on every run: cost, then the two lists' own order)
  local function byPlace(how, limit2, only)
    local c = {}
    for hi, h in ipairs(host) do
      if P.pair[h.key] == nil and (not only or only[h.key]) then
        for li, l in ipairs(here) do
          if not used[l.ref] and (not limit2 or d2(h, l) < limit2) then c[#c + 1] = { cost(h, l), hi, li } end
        end
      end
    end
    table.sort(c, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end; if a[2] ~= b[2] then return a[2] < b[2] end; return a[3] < b[3] end)
    for _, e in ipairs(c) do
      local h, l = host[e[2]], here[e[3]]
      if P.pair[h.key] == nil and not used[l.ref] then take(h, l, how) end
    end
  end
  byPlace("place", NEARL * NEARL)
  if opt.far then byPlace("far") elseif opt.farKeys and next(opt.farKeys) ~= nil then byPlace("far", nil, opt.farKeys) end
  for _, h in ipairs(host) do if P.pair[h.key] == nil then P.make[#P.make + 1] = h.key end end
  for _, l in ipairs(here) do if not used[l.ref] then P.left[#P.left + 1] = l.ref end end
  return P
end

-- host: the whole list, every 0.75 s
-- (lane 82b) the region a free merchant belongs to: the region whose tradeRouteMerchants list holds him. Lane 83's
-- audit (sessions r27m83, r27cf): "rs tradeRouteMerchants" 3 on one copy, 4 on the other for the whole session. A
-- merchant is made with spawnFreeMerchant(<region>) and is put on THAT region's list; a friend made every missing
-- merchant at its player's nearest region, so one the host's game had made for another region stood on the wrong
-- list. Now the host names each merchant's region (its tag, "-" for none) in its FI entry and a friend makes him there.
local function regionTags(S)
  local t = {}
  pcall(function()
    local regs = S.eng.regions; local nr = #regs
    for i = 1, nr do
      local r = un(regs[i])
      if valid(r) then
        local okN, n = pcall(function() return #r.tradeRouteMerchants end)
        if okN and n and n > 0 then
          local tag = "-"; pcall(function() tag = (r.regionUniqueTag:ToString()):gsub("[^%w_]", "_") end)
          for j = 1, n do local okE, a = pcall(function() local u = un(r.tradeRouteMerchants[j]); if valid(u) then return hex(u) end end); if okE and a then t[a] = tag end end
        end
      end
    end
  end)
  return t
end
local function regionByTag(S, tag)
  local hit
  pcall(function() local regs = S.eng.regions; local nr = #regs; for i = 1, nr do local r = un(regs[i]); if valid(r) and (r.regionUniqueTag:ToString()):gsub("[^%w_]", "_") == tag then hit = r; return end end end)
  return hit
end
M.regionByTag = regionByTag
local function hostInventory(S, clock)
  if clock - (M.invT or 0) < INV_EVERY then return end
  M.invT = clock
  local ent = {}
  local rt = regionTags(S)
  local ok = pcall(function()
    local list = S.eng.freeMerchants; local n = #list
    for i = 1, n do
      local u = un(list[i])
      if valid(u) then
        local p = u.realPos; local mount = 0
        pcall(function() local ma = un(u.mountActor); if valid(ma) and tonumber(ma.currentUnitRole) == 15 then mount = iid(ma.UniqueID) end end)
        ent[#ent + 1] = string.format("%d:%d:%d:%d,%d,%d:%s", iid(u.UniqueID), iid(u.assignedSquadID.Value), mount, math.floor(p.X + 0.5), math.floor(p.Y + 0.5), math.floor(p.Z + 0.5), rt[hex(u) or "-"] or "-")
      end
    end
  end)
  if not ok then return end
  -- said in this host's log whenever its list changes (not for the first list of a world): every making and taking
  -- out on a friend can be tied to a line here
  local ids = {}; for _, e in ipairs(ent) do ids[e:match("^(%-?%d+):") or "?"] = true end
  if M.hostIds then
    local t = {}
    for id in pairs(ids) do if not M.hostIds[id] then t[#t + 1] = "+u" .. id end end
    for id in pairs(M.hostIds) do if not ids[id] then t[#t + 1] = "-u" .. id end end
    if #t > 0 then table.sort(t); log("merchants: this host's list changed: %s (now %d)", table.concat(t, " "), #ent) end
  end
  M.hostIds = ids
  M.invSeq = (M.invSeq or 0) + 1
  local parts, part, len = {}, {}, 0
  for _, e in ipairs(ent) do part[#part + 1] = e; len = len + #e + 1; if len > 2900 then parts[#parts + 1] = table.concat(part, ";"); part, len = {}, 0 end end
  if #part > 0 or #parts == 0 then parts[#parts + 1] = #part > 0 and table.concat(part, ";") or "-" end
  for i, t in ipairs(parts) do send(string.format("FI %d %d %d %d %d %s", S.worlds or 0, M.invSeq, #ent, i, #parts, t)) end
  stat(S, "m82invSent")
end

-- friend: this copy's merchants as the plan wants them, and the unit of each ref
local function hereList(S)
  local here, unit = {}, {}
  local ok = pcall(function()
    local list = S.eng.freeMerchants; local n = #list
    for i = 1, n do
      local u = un(list[i])
      if valid(u) then
        local a = hex(u)
        if a and not unit[a] then
          local p = u.realPos
          local mt = false; pcall(function() local ma = un(u.mountActor); mt = valid(ma) and tonumber(ma.currentUnitRole) == 15 end)
          here[#here + 1] = { ref = a, id = iid(u.UniqueID), sq = iid(u.assignedSquadID.Value), x = p.X, y = p.Y, mount = mt }
          unit[a] = u
        end
      end
    end
  end)
  if not ok then return nil end
  return here, unit
end
local function mountOf(u)
  local m
  pcall(function() local ma = un(u.mountActor); if valid(ma) and tonumber(ma.currentUnitRole) == 15 then m = ma end end)
  return m
end
local function role15(S)
  local t = {}
  pcall(function()
    local arr = S.eng.unitArr; local n = #arr
    for i = 1, n do local u = un(arr[i]); if valid(u) and tonumber(u.currentUnitRole) == 15 then local a = hex(u); if a then t[a] = u end end end
  end)
  return t
end
-- a host merchant this copy lacks: ONE try per key with the game's own spawnFreeMerchant, at the host's place
local function makeOne(S, h)
  local key = h.key
  M.failed[key] = "tried"
  local okR, reg = true, h.rg and regionByTag(S, h.rg)          -- (82b) the region the host's merchant belongs to
  local where = reg and ("region " .. h.rg) or "this player's nearest region"
  if not valid(reg) then okR, reg = pcall(function() return S.p1:getClosestOwnedRegion() end) end
  if not (okR and valid(reg)) then log("merchants: the host's merchant %s has none here; no region of this player's to make him at: left missing", tostring(key)); stat(S, "m58spawnFail"); return nil end
  local before = role15(S)
  local okS, nu = pcall(function() return S.eng:spawnFreeMerchant(reg) end)
  local v = okS and un(nu)
  if not valid(v) then log("merchants: the host's merchant %s has none here; spawnFreeMerchant gave nothing (%s): left missing", tostring(key), okS and "no unit" or tostring(nu)); stat(S, "m58spawnFail"); return nil end
  local animal = mountOf(v)
  if not animal then for a, u in pairs(role15(S)) do if not before[a] then animal = u end end end
  pcall(function() v.realPos = { X = h.x, Y = h.y, Z = h.z }; v:K2_SetActorLocation({ X = h.x, Y = h.y, Z = h.z }, false, {}, true) end)
  local said = "none found"
  if valid(animal) then
    if (h.mount or 0) == 0 then
      -- the host's merchant has no pack animal: the one the game made with this one goes again
      local okD = pcall(function() S.eng:destroyUnit(animal) end); said = okD and "taken out again (the host's has none)" or "NOT taken out"; stat(S, "m82animalNotWanted")
    else
      said = "unit id " .. tostring(iid(animal.UniqueID))
      pcall(function() animal.realPos = { X = h.x + 150, Y = h.y, Z = h.z }; animal:K2_SetActorLocation({ X = h.x + 150, Y = h.y, Z = h.z }, false, {}, true) end)
    end
  end
  M.failed[key] = nil
  stat(S, "m58spawned")
  log("merchants: the host's merchant %s had none here (%d here, %d on the host): made one with spawnFreeMerchant at %s (unit id %d, address %s; pack animal %s), put at the host's place", tostring(key), M.cnt and M.cnt[1] or -1, M.cnt and M.cnt[2] or -1,
      where, iid(v.UniqueID), tostring(hex(v)), said)
  return v
end
-- an extra merchant of this copy: his pack animal first, then he (out of the native table before: his address is free
-- for another unit the moment he is destroyed)
local function takeOut(S, ref, u, P, nHere, nHost)
  local id = iid(u.UniqueID); local sq = -1; pcall(function() sq = iid(u.assignedSquadID.Value) end)
  local px, py = 0, 0; pcall(function() local q = u.realPos; px, py = math.floor(q.X + 0.5), math.floor(q.Y + 0.5) end)
  if M.set[ref] then M.set[ref] = nil; if P then pcall(P.send, "MEN DROP " .. ref) end end
  local animal = mountOf(u); local asaid = "no pack animal"
  if animal then
    local aid = iid(animal.UniqueID)
    local okA = pcall(function() S.eng:destroyUnit(animal) end)
    asaid = string.format("his pack animal (unit id %d) %s", aid, okA and "taken out first" or "NOT taken out"); if okA then stat(S, "m73animalOut") end
  end
  local okD, e = pcall(function() S.eng:destroyUnit(u) end)
  stat(S, okD and "m58destroyed" or "m58destroyFail")
  log("merchants: unit id %d (squad %d, address %s) is paired with none of the host's %d merchants and this copy has %d: taken out with destroyUnit: %s; %s; he stood at %d,%d", id, sq, tostring(ref), nHost, nHere, okD and "ok" or tostring(e), asaid, px, py)
end
local function parseInv(text, host)
  local bad = false
  for e in text:gmatch("[^;]+") do
    local id, sq, mount, x, y, z, rg = e:match("^(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+),(%-?%d+),(%-?%d+):?([%w_%-]*)$")
    if id then host[#host + 1] = { key = "u" .. id, id = tonumber(id), sq = tonumber(sq), mount = tonumber(mount), x = tonumber(x), y = tonumber(y), z = tonumber(z), rg = (rg ~= "" and rg ~= "-") and rg or nil }
    else bad = true end
  end
  return not bad
end
-- (lane 82c) why a friend's first list in a world came late (w15b: 12.6 s after a 61 s load, 6 s after the replay
-- ended): every list left out is counted by its reason, and the first list acted on in a world says them all once.
local function skipFI(S, k)
  stat(S, k)
  if M.skipW ~= S.worlds then M.skipW = S.worlds; M.skip = {}; M.skipAge = 0; M.skipFirstT = os.clock() end
  M.skip[k] = (M.skip[k] or 0) + 1
end
local function onFI(S, w)
  if C.hold or C.m58off then if C.hold then skipFI(S, "hold") end; return end
  -- a replayed list (the host wrote it while this copy loaded): nothing is done by it. The FIRST one of this world
  -- is kept: it is the host's list of the save's moment (see "pairs before" above). One-part lists only.
  if S.replay then
    skipFI(S, "m58replaySkip")
    if (not M.rep or M.rep.world ~= S.worlds) and w[7] == "1" and w[8] == "1" and w[9] then
      local host = {}
      if w[9] == "-" or parseInv(w[9], host) then if #host == tonumber(w[6]) then M.rep = { world = S.worlds, hw = tonumber(w[4]), host = host } end end
    end
    return
  end
  if not (valid(S.eng) and valid(S.p1)) then skipFI(S, "m58notReady"); return end
  local clock = os.clock()
  if clock - (S.worldT or 0) < M.early() then skipFI(S, "m58early"); return end
  -- a list written over 2 s ago (by the host's clock as this copy measured it) is not a list of now
  local age
  if C.men and C.men.lineLag then age = C.men.lineLag(w[2], 60.0) else age = A.now() - (tonumber(w[2]) or A.now()); if age ~= age or age < 0 then age = 0 end end
  if age > INV_MAX_AGE then skipFI(S, "m82invOld"); M.skipAge = math.max(M.skipAge or 0, age); return end
  local hw, seq, n, part, parts = tonumber(w[4]), tonumber(w[5]), tonumber(w[6]), tonumber(w[7]), tonumber(w[8])
  if not (hw and seq and n and part and parts and w[9]) then skipFI(S, "m82invBad"); return end
  -- every part of ONE list number, in order
  local I = M.inv
  if part == 1 then I = { seq = seq, hw = hw, n = n, parts = parts, got = 0, host = {} }; M.inv = I end
  if not I or I.seq ~= seq or I.hw ~= hw or I.got ~= part - 1 or I.parts ~= parts then M.inv = nil; skipFI(S, "m82invBroken"); return end
  I.got = part
  if w[9] ~= "-" and not parseInv(w[9], I.host) then I.bad = true end
  if I.got < I.parts then return end
  M.inv = nil
  if I.bad or #I.host ~= I.n then skipFI(S, "m82invShort"); return end
  -- the host loaded a save: its ids may have moved (probe P1); every pair is found again
  if M.hostW ~= hw then
    if M.hostW ~= nil then log("merchants: the host is in another world (%s, was %s): every merchant is paired again", tostring(hw), tostring(M.hostW)) end
    M.hostW = hw; M.pair = {}; M.pairId = {}; M.pairU = {}; M.steady = false; M.leftN = {}; M.missN = {}
  end
  local here, unit = hereList(S)
  if not here then skipFI(S, "m58notReady"); return end
  -- (a pair is kept only while the unit at that address still has the unit id it was paired with: an address is
  --  given to another unit after a unit is destroyed)
  local hereBy = {}; for _, l in ipairs(here) do hereBy[l.ref] = l end
  local prior = {}
  for key, ref in pairs(M.pair) do local l = hereBy[ref]; if l and M.pairId[key] == l.id then prior[key] = ref end end
  -- the first plan of this world after a load of this copy alone: who stood where at the save
  if (M.plans or 0) == 0 and M.rep and M.rep.world == S.worlds and M.rep.hw == hw and M.snap and M.snapW == S.worlds then
    local P0 = M.plan(M.rep.host, M.snap, {}, { lim = SAVE_LIM, near = SAVE_LIM })
    local snapBy = {}; for _, l in ipairs(M.snap) do snapBy[l.ref] = l end
    local n0 = 0
    for key, ref in pairs(P0.pair) do
      local l = hereBy[ref]
      if l and l.id == snapBy[ref].id and prior[key] == nil then prior[key] = ref; n0 = n0 + 1 end
    end
    stat(S, "m82bySave", n0)
    log("merchants: %d of the host's %d merchants of the save's moment paired with this copy's %d by where they stood at the save (squad %d, order %d, place %d)", n0, #M.rep.host, #M.snap, P0.n.squad, P0.n.order, P0.n.place)
  end
  M.rep = nil
  local farKeys = {}; for key, why in pairs(M.failed) do if why then farKeys[key] = true end end
  local Pn = M.plan(I.host, here, prior, { far = not M.steady, farKeys = farKeys })
  local nHere, nHost = #here, #I.host
  M.cnt = { nHere, nHost }; M.plans = (M.plans or 0) + 1
  if M.plans == 1 then
    local t = {}; if M.skipW == S.worlds and M.skip then for k, n in pairs(M.skip) do t[#t + 1] = k .. " " .. n end end; table.sort(t)
    log("merchants: the first whole list of world %s acted on %.1f s into it; lists left out before it: %s%s", tostring(S.worlds), clock - (S.worldT or clock), #t > 0 and table.concat(t, ", ") or "none",
        (M.skipW == S.worlds and (M.skipAge or 0) > 0) and string.format(" (the oldest list %.1f s old)", M.skipAge) or "")
  end
  M.pair = Pn.pair; M.pairU = {}; M.pairId = {}
  for key, ref in pairs(Pn.pair) do M.pairU[key] = unit[ref]; M.pairId[key] = hereBy[ref].id end
  for how, c in pairs(Pn.n) do if c > 0 and how ~= "kept" then stat(S, "m82by_" .. how, c) end end
  if Pn.n.far > 0 or Pn.n.place > 0 then
    local t = {}; for key, how in pairs(Pn.how) do if how == "far" or how == "place" then t[#t + 1] = key .. " by " .. how end end
    table.sort(t)
    log("merchants: paired by place, not by squad or the order of the unit ids (%d here, %d on the host): %s", nHere, nHost, table.concat(t, ", "))
  end
  -- a pair found by order or place of one with and one without a pack animal (the last choice of the plan): this
  -- copy's animal goes when the host's merchant has none; the other way is counted and said (an animal alone cannot be made)
  for key, how in pairs(Pn.how) do
    if how == "order" or how == "place" or how == "far" then
      local u = unit[Pn.pair[key]]; local hm = 0; for _, h in ipairs(I.host) do if h.key == key then hm = h.mount or 0 end end
      local an = u and mountOf(u)
      if an and hm == 0 then
        local aid = iid(an.UniqueID); local okD = pcall(function() S.eng:destroyUnit(an) end); stat(S, "m82animalNotWanted")
        log("merchants: the host's merchant %s has no pack animal, this copy's (paired by %s) has one (unit id %d): %s", tostring(key), how, aid, okD and "taken out" or "NOT taken out")
      elseif not an and hm ~= 0 then stat(S, "m82animalLack"); log("merchants: the host's merchant %s has a pack animal, this copy's (paired by %s) has none: left so", tostring(key), how) end
    end
  end
  if #Pn.make == 0 and #Pn.left == 0 and not M.steady then
    M.steady = true
    log("merchants: every merchant of this copy is paired with one of the host's (%d; by squad %d, by the order of the unit ids %d, by place %d, far %d): from now a host merchant with none here is made, one here with none on the host is taken out%s",
        nHost, Pn.n.squad, Pn.n.order, Pn.n.place, Pn.n.far, destroyOn() and "" or " (the taking out is switched off: Coop.m58destroy = false)")
  end
  S.stats.m58extraNow = #Pn.left; S.stats.m82missingNow = #Pn.make
  local P = menOk()
  -- MISSING here: seen in two lists, then ONE try per key
  local mk = {}; for _, key in ipairs(Pn.make) do mk[key] = true end
  for key in pairs(M.missN) do if not mk[key] then M.missN[key] = nil end end
  local byKey = {}; for _, h in ipairs(I.host) do byKey[h.key] = h end
  for _, key in ipairs(Pn.make) do
    M.missN[key] = (M.missN[key] or 0) + 1
    if M.missN[key] == 1 then stat(S, "m58missing") end
    if M.missN[key] >= 2 and C.m58spawn ~= false and not M.failed[key] then
      -- (a made merchant the game takes away again is made once more, then never again for that key in this world)
      if (M.madeN[key] or 0) >= 2 then
        M.failed[key] = "twice"; stat(S, "m73madeGone")
        log("merchants: the merchant made here for the host's %s was taken away by the game twice: not made again", tostring(key))
      else
        M.madeN[key] = (M.madeN[key] or 0) + 1
        local v = makeOne(S, byKey[key])
        if v then local a = hex(v); if a then M.pair[key] = a; M.pairU[key] = v; M.pairId[key] = iid(v.UniqueID) end; M.missN[key] = nil end
      end
    end
  end
  -- a key the host no longer names is forgotten (its one try with it)
  for key in pairs(M.failed) do if not byKey[key] then M.failed[key] = nil end end
  for key in pairs(M.madeN) do if not byKey[key] then M.madeN[key] = nil end end
  -- EXTRA here: seen in two lists 0.6 s apart, and never more than this copy has over the host's count
  local lf = {}; for _, ref in ipairs(Pn.left) do lf[ref] = true end
  for ref in pairs(M.leftN) do if not lf[ref] then M.leftN[ref] = nil end end
  local surplus = nHere - nHost
  for _, ref in ipairs(Pn.left) do
    local L = M.leftN[ref]
    if not L then
      L = { n = 0, t = clock }; M.leftN[ref] = L; stat(S, "m58extra")
      local u = unit[ref]; log("merchants: unit id %d (address %s) is paired with none of the host's %d merchants (%d here)", iid(u.UniqueID), tostring(ref), nHost, nHere)
    end
    L.n = L.n + 1
    if L.n >= 2 and clock - L.t >= CONFIRM then
      if surplus <= 0 then stat(S, "m73extraHeld")
      elseif not destroyOn() then stat(S, "m82extraOff")
      else takeOut(S, ref, unit[ref], P, nHere, nHost); surplus = surplus - 1; nHere = nHere - 1; M.leftN[ref] = nil end
    end
  end
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
  if os.clock() - (S.worldT or 0) < M.early() then stat(S, "m58early"); return end
  local clock = os.clock()
  local full = w[4] == "1"
  local P = menOk()
  local cam = camera(S, clock)
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
      x, y, z, tx, ty, tz = tonumber(x), tonumber(y), tonumber(z), tonumber(tx), tonumber(ty), tonumber(tz)
      x, y = x + tonumber(vx) * age, y + tonumber(vy) * age          -- where the host's merchant is now
      -- (lane 82) the merchant of this key is the one the last plan paired with it (onFI); a number is a host of
      -- before lane 82 (his squad number)
      local u = M.pairU[hh]; if u ~= nil and not valid(u) then u = nil end
      if not u and type(hh) == "number" then u = unitOf(S, hh) end
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
      else stat(S, "m82noPair") end
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
  end
  if P and #cmds > 0 then P.send(table.concat(cmds, "\n")) end
  if #newQ > 0 then M.dropQ = newQ end
end
-- (lane 82) THE LIVESTOCK MERCHANTS (unit role 7, the engine's livestockMerchants list).
-- What the game does (probes P1 to P3 of lane 82, lanes/lane_s21_82/livestock_merchant.txt):
--   - an order makes a merchant at the map's trade point with a task of type 61. He lives exactly as long as he has
--     a task: without one the game takes him away within 0.1 to 0.4 s, on the host as on a friend (spawned alone:
--     gone after 0.13 s; with a walk of 8 m: gone 0.3 s after he arrived; an order the region cannot pay: 1.1 to
--     1.4 s on both copies). An order that is paid walks him to the building: minutes.
--   - a rival lord's order is made by the host's game alone, so a friend never had that man ("livestock merchants
--     0 / 1" in the minute line, the M line of the daily sample 1/0 for as long as he walked).
--   - a player's order is carried to every copy and each game makes its own merchant.
-- So:
--   host    every 0.5 s "FV <unit id>:<x>,<y>,<z>:<way's end x>,<y>,<z>:<vx>,<vy>:<building type,x,y or ->;..." ("-"
--           for none): every livestock merchant, the end of his way (read once per way, as the free merchants'),
--           his velocity, and the building his task ends at; (lane 82b) then ":<x>,<y>,<z>,<kind>" of the animal he leads, or
--           ":-".
--   friend  per host merchant, by his unit id:
--           1 this copy's own merchant that no other id holds, within 300 m of the host's (a carried order): he is the
--             one. He keeps his own task; he is only put where the host's is when over 2.5 m off (15 m when seen).
--           2 none here once the host's has lived 1.5 s: a STAND-IN is made with the game's own
--             spawnLivestockMerchant (at the building the host names) and given, in the same call, a walk (a task of
--             type 17, no building, no goods: nothing is ordered, paid or delivered here) to the end of the host's
--             way, at the host's place (82b: no lead). Off the host's 2.5 s track in two lines (15 m at once; in the
--             1.5 s after a walk only beyond 15 m), or a steady 4 m behind: put, his way kept (see THE 3-SECOND
--             TRACK below); a new walk when the host's end changes and when he has none. A stand-in the game took
--             away (he arrived first) is made again after 2.5 s while the host's still walks, at most 5 times.
--             (82b) The animal the host's merchant leads: see THE ANIMAL below.
--           A host merchant no line has named for 1 s: his stand-in goes (destroyUnit); this copy's own merchant of
--           a carried order is left to his own game for 10 s more (he arrives a moment later). A merchant of this
--           copy that no host merchant holds for 1.5 s while the host's lines come: taken out (lane 73's rule).
-- Test switches, friend console: Coop.m73lvspawn = false (no stand-in is made), Coop.m73lvdestroy = false.
local LV_EVERY, LV_AFTER, LV_GONE, LV_REMAKE, LV_TRIES, LV_NEAR = 0.5, 1.5, 1.0, 2.5, 5, 30000
local LV_SILENT = 5.0
-- (run P5) A stand-in stands for about half a second after every walk he is given (his way is being found) while the
-- host's walks on (7 m a second of real time at speed 4): put where the host's was and given a walk, he was 3.5 to
-- 5.4 m behind at the next line and was put again, 14 times in his first 25 s. So with every walk he was put where the
-- host's would be LV_LEAD seconds later (0.6 s until lane 82b; now 0: the lead put him ahead of the host, a place the
-- host had not had, and at speed 8 it looped), and for LV_GRACE seconds after a walk he is put again only beyond 15 m.
local LV_LEAD, LV_GRACE = 0.0, 1.5         -- (lane 82b: no lead, see THE 3-SECOND TRACK)
-- a unit's way's end: the game's own getTargetPos while his PathPoint is the last index for that one call (see
-- hostTick); read again only when his way's length changes or his PathPoint goes back
local function wayEnd(u, key, cache)
  local np = #u.Path; local pp = u.PathPoint; local t
  local E = cache[key]
  if np > 0 and E and E.np == np and pp >= E.pp then E.pp = pp; return E.x, E.y, E.z end
  if np > 0 then
    if pp ~= np - 1 then u.PathPoint = np - 1; local okT, tt = pcall(function() return u:getTargetPos() end); u.PathPoint = pp; if okT then t = tt end
    else t = u:getTargetPos() end
  end
  if t then cache[key] = { np = np, pp = pp, x = t.X, y = t.Y, z = t.Z } else cache[key] = nil end
  t = t or u:getTargetPos()
  return t.X, t.Y, t.Z
end
-- (lane 82b, run lvA1) THE ANIMAL HE BRINGS. On the host the merchant does not bring a new animal: the animal that
-- stood at the map's trade point (from the save: unit 488 in coop_test_1) gets a task of type 41 and walks beside him
-- to the stable, and the game puts a NEW animal at the trade point in its place. On a friend the stand-in leads no
-- animal: the trade point's animal stays where it stood (right: the host has its new one there), and the region's
-- count is made equal by the facts module, which makes the missing animal AT THE STABLE at once (0.5 s): an animal
-- the host has at the merchant's side, minutes before it arrives. So the host names the animal he leads (a unit of
-- any kind (lane 82b: the rival orders mules, kind 15; a player orders oxen, kind 12, and more) whose first task is of type 41, the nearest within 40 m of him; looked for at most every 2 s while none is
-- known), and a friend keeps one at that place (see lvAnimal below).
local function hostAnimal(S, u, id, p, clock)
  M.lvAn = M.lvAn or {}
  local c = M.lvAn[id]
  if c and c.u then
    local okA, keep = pcall(function() if not valid(c.u) then return false end; local ts = c.u.Tasks; return tonumber(c.u.currentUnitRole) ~= 7 and #ts > 0 and tonumber(ts[1].Type) == 41 end)
    if okA and keep then return c.u end
    -- (lane 82c) delivered: its task is no longer of type 41; it walks on to its stable by itself: named for a while yet
    if valid(c.u) then M.lvAnAfter = M.lvAnAfter or {}; if not M.lvAnAfter[id] then M.lvAnAfter[id] = { u = c.u, t = clock } end end
    c = nil; M.lvAn[id] = nil
  end
  if c and clock - c.t < 2.0 then return nil end
  local taken = {}; for k, x in pairs(M.lvAn) do if k ~= id and x.u then local a = hex(x.u); if a then taken[a] = true end end end
  local best, bd
  pcall(function()
    local arr = S.eng.unitArr; local n = #arr
    for i = 1, n do
      local a = un(arr[i])
      if valid(a) and tonumber(a.currentUnitRole) ~= 7 then
        local ts = a.Tasks
        if #ts > 0 and tonumber(ts[1].Type) == 41 then
          local q = a.realPos; local d = (q.X - p.X) ^ 2 + (q.Y - p.Y) ^ 2
          if d < 4000 * 4000 and (not bd or d < bd) and not taken[hex(a) or "-"] then best, bd = a, d end
        end
      end
    end
  end)
  M.lvAn[id] = { u = best, t = clock }
  if best and M.lvAnAfter then local ab = hex(best); for k, x in pairs(M.lvAnAfter) do if valid(x.u) and hex(x.u) == ab then M.lvAnAfter[k] = nil end end end   -- (82c: led again)
  return best
end
local function hostLv(S, clock)
  if clock - (M.lvT or 0) < LV_EVERY then return end
  M.lvT = clock
  M.lvEnds = M.lvEnds or {}; M.lvPrev = M.lvPrev or {}
  local ent, seen = {}, {}
  local ok = pcall(function()
    local lv = S.eng.livestockMerchants; local n = #lv
    for i = 1, n do
      local u = un(lv[i])
      if valid(u) then
        local okE, e = pcall(function()
          local id = iid(u.UniqueID); local p = u.realPos
          local tx, ty, tz = wayEnd(u, id, M.lvEnds)
          local vx, vy = 0, 0
          local pv = M.lvPrev[id]; M.lvPrev[id] = { p.X, p.Y, clock }
          if pv and clock - pv[3] > 0.05 and clock - pv[3] < 1.5 then vx, vy = (p.X - pv[1]) / (clock - pv[3]), (p.Y - pv[2]) / (clock - pv[3]) end
          if vx * vx + vy * vy > 3000 * 3000 then vx, vy = 0, 0 end
          local bk = "-"
          pcall(function()
            local ts = u.Tasks; if #ts < 1 then return end
            local t = ts[1]; local b = t.finalBuilding; if not valid(b) then b = t.targetBuilding end
            if valid(b) then local l = b:K2_GetActorLocation(); bk = string.format("%d,%d,%d", A.btype(b), math.floor(l.X + 0.5), math.floor(l.Y + 0.5)) end
          end)
          seen[id] = true
          local ak = "-"
          pcall(function() local a = hostAnimal(S, u, id, p, clock); if a then local q = a.realPos; ak = string.format("%d,%d,%d,%d", math.floor(q.X + 0.5), math.floor(q.Y + 0.5), math.floor(q.Z + 0.5), tonumber(a.currentUnitRole) or 0) end end)
          return string.format("%d:%d,%d,%d:%d,%d,%d:%d,%d:%s:%s", id, math.floor(p.X + 0.5), math.floor(p.Y + 0.5), math.floor(p.Z + 0.5), math.floor(tx + 0.5), math.floor(ty + 0.5), math.floor(tz + 0.5),
            math.floor(vx + 0.5), math.floor(vy + 0.5), bk, ak)
        end)
        if okE and e then ent[#ent + 1] = e end
      end
    end
  end)
  if not ok then return end
  for id in pairs(M.lvEnds) do if not seen[id] then M.lvEnds[id] = nil end end
  for id in pairs(M.lvPrev) do if not seen[id] then M.lvPrev[id] = nil end end
  if M.lvAn then for id, c in pairs(M.lvAn) do if not seen[id] then
    if c.u and valid(c.u) then M.lvAnAfter = M.lvAnAfter or {}; if not M.lvAnAfter[id] then M.lvAnAfter[id] = { u = c.u, t = clock } end end
    M.lvAn[id] = nil
  end end end
  -- (lane 82c) THE ANIMAL AFTER THE DELIVERY. Run lvD1: once delivered, the host's animal (no longer of task type 41)
  -- walked on to the rival's stable for about 30 s while the friend's stood where the merchant had left it: up to
  -- 15 m apart. So the host names a delivered animal for as long as it moves (until it has stood still 30 s, at most
  -- 150 s; run lvE2: one stood 10 s and walked on), as "A<merchant id>:<x>,<y>,<z>,<kind>:<its way's end x>,<y>,<z>" in the same FV line.
  if M.lvAnAfter then
    M.lvAEnds = M.lvAEnds or {}
    for id, rec in pairs(M.lvAnAfter) do
      local okR, e = pcall(function()
        if not valid(rec.u) or clock - rec.t > 150.0 then return nil end
        local a = rec.u; local q = a.realPos
        if rec.px and (q.X - rec.px) ^ 2 + (q.Y - rec.py) ^ 2 < 50 * 50 then rec.stillT = rec.stillT or clock else rec.stillT = nil end
        rec.px, rec.py = q.X, q.Y
        if rec.stillT and clock - rec.stillT > 30.0 then return nil end
        local tx, ty, tz = q.X, q.Y, q.Z
        local okW, n = pcall(function() return #a.Path end)
        if okW and n and n > 0 then local okE, x, y, z = pcall(wayEnd, a, "a" .. tostring(id), M.lvAEnds); if okE and x then tx, ty, tz = x, y, z end end
        return string.format("A%d:%d,%d,%d,%d:%d,%d,%d", id, math.floor(q.X + 0.5), math.floor(q.Y + 0.5), math.floor(q.Z + 0.5), tonumber(a.currentUnitRole) or 0, math.floor(tx + 0.5), math.floor(ty + 0.5), math.floor(tz + 0.5))
      end)
      if okR and e then ent[#ent + 1] = e else M.lvAnAfter[id] = nil; M.lvAEnds["a" .. tostring(id)] = nil end
    end
  end
  -- with none: said at once when the last one went, then every 2 s
  if #ent == 0 and (M.lvN or 0) == 0 and clock - (M.lvSentT or 0) < 2.0 then return end
  M.lvN = #ent; M.lvSentT = clock
  send("FV " .. (#ent > 0 and table.concat(ent, ";") or "-")); stat(S, "m82lvSent")
end
local function findBuilding(S, key, x, y)
  local bt, bx, by = (key or ""):match("^(%d+),(%-?%d+),(%-?%d+)$"); bt, bx, by = tonumber(bt), tonumber(bx), tonumber(by)
  local best, bd, any
  pcall(function()
    local arr = S.eng.buildingArr; local n = #arr
    for i = 1, n do
      local b = un(arr[i])
      if valid(b) then
        any = any or b
        local l = b:K2_GetActorLocation()
        if bt and A.btype(b) == bt and math.abs(l.X - bx) < 60 and math.abs(l.Y - by) < 60 then best = b; return end
        if not bt and A.btype(b) == 79 then local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2; if not bd or d < bd then best, bd = b, d end end
      end
    end
  end)
  return best or any            -- (he is put where the host's stands: any building of this copy serves the call)
end
-- a walk to a place: no building, no goods (the jobs module's "walk there", type 17). Made anew for every give: a
-- record holds nothing of an earlier world.
local function lvWalk(x, y, z)
  local function P() return { Pos = { X = x + 0.0, Y = y + 0.0, Z = z + 0.0 }, floor = 0, Rotation = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 } } end
  return { Type = 17, TargetLocation = P(), finalLocation = P(), targetEntityLocation = { X = x + 0.0, Y = y + 0.0, Z = z + 0.0 }, resourceType = 0, resourceAmt = 0, executed = false, ID = -1, bPaidInAdvance = false }
end
-- (lane 82b) THE 3-SECOND TRACK. Run lvA1 (speed 8, host merchant 15 m a second): the stand-in walked the host's way
-- within 1.6 m for 21 s; then a line found him "over 2.5 m off" (the host's place moved on by his velocity for the
-- line's age misses by a few metres at that pace), he was put 0.6 s AHEAD (9 m) and given a new walk, stood while his
-- way was found, fell 4 m behind, was put ahead again: 19 of 105 readings over 3 m, up to 10 m, half of them ahead
-- (places the host had not had yet). So now:
--   - "off" is measured against the host's TRACK: the places of his lines of the last LV_TRACK seconds and his place
--     now (each line's place moved on by his velocity for the line's age), as a chain of segments. A stand-in a few
--     metres behind on the host's way stands where the host stood a moment ago: not off.
--   - off in two lines in a row (or beyond 15 m at once): he is put where the host's is now, with no lead, and his
--     way is KEPT: his PathPoint is set to the point of his way just ahead of that place (the game's getTargetPos
--     read for each point, PathPoint put back on any failure). Only a stand-in without a way (or when the host's way
--     has another end) is given a new walk; he then stands while it is found and falls behind on the host's track,
--     not ahead of it.
local alignWayFwd
local LV_TRACK, LV_BEHIND = 2.5, 250      -- (s; cm: a stand-in or an animal on the track but this far from the host's place now is caught up;
                                           --  400 until lane 82c: run lvE1, a stand-in 3.7 m behind at speed 8 for his whole walk)
-- (lane 82c) a unit on the host's track but a steady distance behind (run lvE1: an animal 12.5 m behind its host animal for
-- the whole walk, at the same pace): over LV_BEHIND from the host's place now in two lines, at most every 3 s (an animal:
-- every 1 s; run lvE2: a friend's ox walks slower than the host's beside its merchant), it is put
-- there with its way kept (PathPoint set first; no put when that fails: a new walk would stall it)
local function catchUp(S, st, u, px, py, hx, hy, hz, clock, statName, every)
  st.behind = ((px - hx) ^ 2 + (py - hy) ^ 2 > LV_BEHIND * LV_BEHIND) and (st.behind or 0) + 1 or 0
  if st.behind < 2 or clock - (st.catchT or -100) < (every or 3.0) then return end
  st.behind = 0; st.catchT = clock
  if alignWayFwd and alignWayFwd(u, hx, hy) then
    local okW = pcall(function() u.realPos = { X = hx, Y = hy, Z = hz }; u:K2_SetActorLocation({ X = hx, Y = hy, Z = hz }, false, {}, true) end)
    stat(S, okW and statName or "m82lvPutFail")
  end
end
local function trackPush(t, x, y, clock)
  t[#t + 1] = { x, y, clock }
  while #t > 1 and clock - t[1][3] > LV_TRACK + 0.6 do table.remove(t, 1) end
end
-- the distance (cm) from place (px, py) to the chain of the track's places of the last LV_TRACK s (pure: the desk
-- test runs it)
function M.trackDist(trk, px, py, clock)
  local pts = {}
  for _, q in ipairs(trk or {}) do if clock - q[3] <= LV_TRACK + 0.6 then pts[#pts + 1] = q end end
  if #pts == 0 then return 1e9 end
  local best = 1e18
  for i = 1, #pts do
    local a = pts[i]; local d = (px - a[1]) ^ 2 + (py - a[2]) ^ 2; if d < best then best = d end
    local b = pts[i + 1]
    if b then
      local ux, uy = b[1] - a[1], b[2] - a[2]; local L2 = ux * ux + uy * uy
      if L2 > 1 then
        local f = ((px - a[1]) * ux + (py - a[2]) * uy) / L2
        if f > 0 and f < 1 then local qx, qy = a[1] + f * ux, a[2] + f * uy; d = (px - qx) ^ 2 + (py - qy) ^ 2; if d < best then best = d end end
      end
    end
  end
  return math.sqrt(best)
end
-- set his PathPoint to the point of his way just ahead of (x, y); false when he has no way or a read failed
local function alignWay(u, x, y)
  local okN, np, pp0 = pcall(function() return #u.Path, u.PathPoint end)
  if not okN or not np or np < 2 then return false end
  local ok, k = pcall(function()
    local best, bd, bp
    for k = 0, np - 1 do
      u.PathPoint = k; local t = u:getTargetPos(); local d = (t.X - x) ^ 2 + (t.Y - y) ^ 2
      if not bd or d < bd then best, bd, bp = k, d, { t.X, t.Y } end
    end
    if best < np - 1 then
      u.PathPoint = best + 1; local t2 = u:getTargetPos()
      if (t2.X - bp[1]) * (x - bp[1]) + (t2.Y - bp[2]) * (y - bp[2]) > 0 then best = best + 1 end
    end
    return best
  end)
  if ok and k then u.PathPoint = k; return true end
  pcall(function() u.PathPoint = pp0 end)
  return false
end
alignWayFwd = alignWay
-- (lane 82b) THE ANIMAL. Per stand-in whose host merchant leads an animal: one animal of this copy is kept at the
-- host animal's place: the one the facts module made for that count (C.facts.made, of the host animal's kind; it stands at the stable,
-- run lvA1), else none (nothing is made here: the count is the facts module's business). It is given a walk to the
-- end of the host merchant's way (type 17, as the stand-in; again every 2 s while it has no task) and put where the
-- host's animal is when off that animal's track in two lines (beyond 15 m at once). When the host's merchant is gone
-- (the animal delivered) it is left where it is: by the stable. Switch: Coop.m82lvanimal = false (friend console).
local function lvAnimal(S, L, h, clock, held)
  local a = L.an
  if a and not valid(a) then a = nil; L.an = nil end
  if not a then
    -- (run lvC1, advisor) only an animal the facts module made IN THE REGION OF THE BUILDING the host's merchant goes
    -- to, with no home building yet, never one an earlier merchant of this world led (a delivered animal stays in the
    -- facts module's list)
    local F = rawget(C, "facts"); local list = F and F.made
    if type(list) ~= "table" then stat(S, "m82lvAnNone"); return end
    local reg
    if h.bk ~= "-" then local b = findBuilding(S, h.bk, h.x, h.y); if b and h.bk:match("^(%d+),") then pcall(function() local r = b:getRegion(); if valid(r) then reg = hex(r) end end) end end
    M.lvAnUsed = M.lvAnUsed or {}
    for i = #list, 1, -1 do
      local m = list[i]
      if type(m) == "table" and m.role == h.arole and valid(m.u) then
        local ad = hex(m.u)
        local okD, fit = pcall(function() return not m.u.dead and not valid(m.u.animalAssignedTo) and (not reg or (valid(m.r) and hex(m.r) == reg)) end)
        if ad and not held[ad] and not M.lvAnUsed[ad] and okD and fit then a = m.u; break end
      end
    end
    if not a then stat(S, "m82lvAnNone"); return end
    L.an = a; L.anTrk = {}; L.anOff = 0; L.anWalkT = nil; L.anE = nil
    M.lvAnUsed[hex(a) or "-"] = true
    stat(S, "m82lvAnTaken")
    log("merchants: the host's livestock merchant u%s leads an animal: this copy's animal unit id %d (made by the facts module%s) is kept at its place", h.id, iid(a.UniqueID), reg and " in his building's region" or "")
  end
  local ad = hex(a); if ad then held[ad] = true end
  trackPush(L.anTrk, h.ax, h.ay, clock)
  local okP, p = pcall(function() local q = a.realPos; return { q.X, q.Y } end)
  if not (okP and p) then return end
  local d = M.trackDist(L.anTrk, p[1], p[2], clock)
  stat(S, d < 200 and "m82lvAd2" or (d < 500 and "m82lvAd5" or (d < 1000 and "m82lvAd10" or "m82lvAdfar")))
  L.anOff = d > PUT and (L.anOff or 0) + 1 or 0
  local idle = true; pcall(function() idle = #a.Tasks == 0 end)
  -- (run lvC1) the walk of the first line went to the host's FIRST end (the trade point, 8 m off): after each put the
  -- animal walked BACK to it at full pace. Now: a new end of the host's way gives a new walk, and a put keeps the way
  -- (PathPoint set) or gives a new walk.
  local newEnd = not L.anE or (h.tx - L.anE[1]) ^ 2 + (h.ty - L.anE[2]) ^ 2 >= 50 * 50
  if L.anOff >= 2 or d > PUT_SEEN then
    L.anOff = 0
    local okW = pcall(function() a.realPos = { X = h.ax, Y = h.ay, Z = h.az }; a:K2_SetActorLocation({ X = h.ax, Y = h.ay, Z = h.az }, false, {}, true) end)
    stat(S, okW and "m82lvAnPut" or "m82lvAnPutFail")
    if not idle and not newEnd and alignWay(a, h.ax, h.ay) then stat(S, "m82lvAnAlign") else idle = true end
  elseif not idle and not newEnd then
    L.anSt = L.anSt or {}; catchUp(S, L.anSt, a, p[1], p[2], h.ax, h.ay, h.az, clock, "m82lvAnCatch", 1.0)
  end
  if newEnd or (idle and clock - (L.anWalkT or -100) >= 1.0) then
    L.anWalkT = clock
    local okT = pcall(function() a:setTask(lvWalk(h.tx, h.ty, h.tz)) end)
    local now = false; pcall(function() now = #a.Tasks > 0 end)
    if okT and now then L.anE = { h.tx, h.ty }; stat(S, "m82lvAnWalk") else stat(S, "m82lvAnWalkFail") end
  end
end
-- (lane 82c) one animal of this copy kept on the track of a host animal that is named with its place and its way's end
-- (rec = { a = unit, trk = {}, off = n, e = end given }, A = { ax, ay, az, tx, ty, tz }): off the 2.5 s track in two
-- lines (15 m at once): put, its way kept or a new walk; a new end of the host animal's way: a new walk to it.
function M.animalFollow(S, rec, Aa, clock)
  local a = rec.a
  if not valid(a) then return end
  trackPush(rec.trk, Aa.ax, Aa.ay, clock)
  local okP, p = pcall(function() local q = a.realPos; return { q.X, q.Y } end)
  if not (okP and p) then return end
  local d = M.trackDist(rec.trk, p[1], p[2], clock)
  stat(S, d < 200 and "m82lvAAd2" or (d < 500 and "m82lvAAd5" or (d < 1000 and "m82lvAAd10" or "m82lvAAdfar")))
  rec.off = d > PUT and (rec.off or 0) + 1 or 0
  local idle = true; pcall(function() idle = #a.Tasks == 0 end)
  local newEnd = not rec.e or (Aa.tx - rec.e[1]) ^ 2 + (Aa.ty - rec.e[2]) ^ 2 >= 50 * 50
  if rec.off >= 2 or d > PUT_SEEN then
    rec.off = 0
    local okW = pcall(function() a.realPos = { X = Aa.ax, Y = Aa.ay, Z = Aa.az }; a:K2_SetActorLocation({ X = Aa.ax, Y = Aa.ay, Z = Aa.az }, false, {}, true) end)
    stat(S, okW and "m82lvAAPut" or "m82lvAnPutFail")
    if not idle and not newEnd and alignWay(a, Aa.ax, Aa.ay) then stat(S, "m82lvAnAlign") else idle = true end
  elseif not idle and not newEnd then
    rec.st = rec.st or {}; catchUp(S, rec.st, a, p[1], p[2], Aa.ax, Aa.ay, Aa.az, clock, "m82lvAACatch", 1.0)
  end
  local far = (Aa.tx - Aa.ax) ^ 2 + (Aa.ty - Aa.ay) ^ 2 >= 100 * 100        -- (the host's stands at its end: no walk)
  if far and (newEnd or (idle and clock - (rec.walkT or -100) >= 1.0)) then
    rec.walkT = clock
    local okT = pcall(function() a:setTask(lvWalk(Aa.tx, Aa.ty, Aa.tz)) end)
    local now = false; pcall(function() now = #a.Tasks > 0 end)
    if okT and now then rec.e = { Aa.tx, Aa.ty }; stat(S, "m82lvAAWalk") else stat(S, "m82lvAnWalkFail") end
  end
end
local function onFV(S, w)
  if C.hold or C.m58off or S.replay then return end
  if not (valid(S.eng) and valid(S.p1)) or os.clock() - (S.worldT or 0) < M.early() then return end
  local clock = os.clock()
  local age
  if C.men and C.men.lineLag then age = C.men.lineLag(w[2], 0.4)
  else age = (A.now() - (tonumber(w[2]) or A.now())); if age ~= age or age < 0 then age = 0 elseif age > 0.4 then age = 0.4 end end
  local host = {}
  for e in (w[4] or ""):gmatch("[^;]+") do
    local id, x, y, z, tx, ty, tz, vx, vy, bk, ak = e:match("^(%d+):(%-?%d+),(%-?%d+),(%-?%d+):(%-?%d+),(%-?%d+),(%-?%d+):(%-?%d+),(%-?%d+):([^:]+):([^:]+)$")
    if id then
      local h = { id = id, x = tonumber(x) + tonumber(vx) * age, y = tonumber(y) + tonumber(vy) * age, z = tonumber(z), tx = tonumber(tx), ty = tonumber(ty), tz = tonumber(tz), bk = bk, vx = tonumber(vx), vy = tonumber(vy) }
      local ax, ay, az, ar = ak:match("^(%-?%d+),(%-?%d+),(%-?%d+),(%d+)$")
      if ax then h.ax, h.ay, h.az, h.arole = tonumber(ax) + tonumber(vx) * age, tonumber(ay) + tonumber(vy) * age, tonumber(az), tonumber(ar) end
      host[#host + 1] = h
    end
  end
  local hostA = {}
  for e in (w[4] or ""):gmatch("[^;]+") do
    local mid, ax, ay, az, ar, tx, ty, tz = e:match("^A(%d+):(%-?%d+),(%-?%d+),(%-?%d+),(%d+):(%-?%d+),(%-?%d+),(%-?%d+)$")
    if mid then hostA[#hostA + 1] = { id = mid, ax = tonumber(ax), ay = tonumber(ay), az = tonumber(az), arole = tonumber(ar), tx = tonumber(tx), ty = tonumber(ty), tz = tonumber(tz) } end
  end
  local here = {}
  local okL = pcall(function() local lv = S.eng.livestockMerchants; local n = #lv; for i = 1, n do local u = un(lv[i]); if valid(u) then here[#here + 1] = u end end end)
  if not okL then return end
  M.lv = M.lv or {}
  M.lvHost, M.lvHere = #host, #here
  -- whom the ids hold; a held merchant that is gone (the game took him: he arrived, or his order could not be paid)
  local held = {}
  -- (lane 82c) session l82g: the game took a stand-in off its livestockMerchants list while his handle stayed valid;
  -- he was walked on (91 walks) and made again only 45 s later (the M line 1/0 past 3 s 8 times). A held merchant
  -- that is not on the engine's list is gone.
  local onList = {}; for _, u in ipairs(here) do local a = hex(u); if a then onList[a] = true end end
  for _, L in pairs(M.lv) do
    if L.u and valid(L.u) and not onList[hex(L.u) or "-"] then
      if L.puppet then pcall(function() S.eng:destroyUnit(L.u) end) end
      log("merchants: the %s of the host's livestock merchant is off this copy's livestock merchant list (unit id %d): taken as gone", L.puppet and "stand-in" or "own merchant", iid(L.u.UniqueID))
      stat(S, "m82lvOffList"); L.u = false
    end
    if L.u == false or (L.u and not valid(L.u)) then L.u = nil; L.goneT = clock; L.e = nil; if L.puppet then stat(S, "m82lvStandInEnded") end end
    if L.u then local a = hex(L.u); if a then held[a] = true end end
    if L.an and valid(L.an) then local a = hex(L.an); if a then held[a] = true end end
  end
  local cam = camera(S, clock)
  for _, h in ipairs(host) do
    local L = M.lv[h.id]; if not L then L = { seenT = clock, trk = {} }; M.lv[h.id] = L end
    L.lastT = clock
    trackPush(L.trk, h.x, h.y, clock)
    if not L.u then
      -- 1 this copy's own merchant of the same order
      local best, bd
      for _, u in ipairs(here) do
        local a = hex(u)
        if a and not held[a] then
          local okP, d = pcall(function() local q = u.realPos; return (q.X - h.x) ^ 2 + (q.Y - h.y) ^ 2 end)
          if okP and d < LV_NEAR * LV_NEAR and (not bd or d < bd) then best, bd = u, d end
        end
      end
      if best then
        L.u = best; L.puppet = false; held[hex(best)] = true; stat(S, "m82lvOwn")
        log("merchants: the host's livestock merchant u%s is this copy's own (unit id %d, %.0f m from the host's): no stand-in is made", h.id, iid(best.UniqueID), math.sqrt(bd) / 100)
      elseif C.m73lvspawn ~= false and clock - L.seenT >= LV_AFTER and (L.madeN or 0) < LV_TRIES and clock - (L.goneT or -100) >= LV_REMAKE then
        -- 2 a stand-in: the game's own spawn and, in the same call, a walk to the end of the host's way
        L.madeN = (L.madeN or 0) + 1
        local b = findBuilding(S, h.bk ~= "-" and h.bk or nil, h.x, h.y)
        local v, why
        if not b then why = "no building here to make him at"
        else
          local okS, nu = pcall(function() return S.eng:spawnLivestockMerchant(b) end)
          v = okS and un(nu); if not valid(v) then v = nil; why = "spawnLivestockMerchant gave nothing (" .. (okS and "no unit" or tostring(nu)) .. ")" end
        end
        if v then
          local lx, ly = h.x + h.vx * LV_LEAD, h.y + h.vy * LV_LEAD
          pcall(function() v.realPos = { X = lx, Y = ly, Z = h.z }; v:K2_SetActorLocation({ X = lx, Y = ly, Z = h.z }, false, {}, true) end)
          local okT, eT = pcall(function() v:setTask(lvWalk(h.tx, h.ty, h.tz)) end)
          L.u = v; L.puppet = true; L.e = { h.tx, h.ty }; L.giveT = clock; L.off = 0; local a = hex(v); if a then held[a] = true end
          stat(S, "m73lvMade")
          log("merchants: the host's livestock merchant u%s has none here: a stand-in made (unit id %d, try %d) at the host's place %d,%d, walking to %d,%d (%s)", h.id, iid(v.UniqueID), L.madeN, math.floor(h.x), math.floor(h.y),
              math.floor(h.tx), math.floor(h.ty), okT and "walk given" or ("walk NOT given: " .. tostring(eT)))
        else
          stat(S, "m73lvSpawnFail"); log("merchants: the host's livestock merchant u%s has none here and no stand-in could be made: %s (try %d of %d)", h.id, tostring(why), L.madeN, LV_TRIES)
        end
      end
    elseif L.u then
      local u = L.u
      local okP, p = pcall(function() local q = u.realPos; return { q.X, q.Y } end)
      if okP and p then
        local d2 = (p[1] - h.x) ^ 2 + (p[2] - h.y) ^ 2
        stat(S, d2 < 200 * 200 and "m82lvd2" or (d2 < 500 * 500 and "m82lvd5" or (d2 < 1000 * 1000 and "m82lvd10" or "m82lvdfar")))
        local seenC = cam and ((p[1] - cam[1]) ^ 2 + (p[2] - cam[2]) ^ 2 < CAM * CAM or (h.x - cam[1]) ^ 2 + (h.y - cam[2]) ^ 2 < CAM * CAM)
        local lim = seenC and PUT_SEEN or PUT
        if L.puppet then
          -- a stand-in: off the host's track of the last 2.5 s in two lines (beyond 15 m at once; in the LV_GRACE
          -- seconds after a walk only beyond 15 m): put where the host's is, his way kept (PathPoint set); a walk only
          -- when he has none or the host's way has another end
          local dt = M.trackDist(L.trk, p[1], p[2], clock)
          stat(S, dt < 200 and "m82lvT2" or (dt < 500 and "m82lvT5" or (dt < 1000 and "m82lvT10" or "m82lvTfar")))
          L.off = dt > lim and (L.off or 0) + 1 or 0
          local off = L.off >= 2 or dt > PUT_SEEN
          if off and clock - (L.giveT or -100) < LV_GRACE and dt <= PUT_SEEN then off = false end
          local idle = false; pcall(function() idle = #u.Tasks == 0 end)
          local newEnd = not L.e or (h.tx - L.e[1]) ^ 2 + (h.ty - L.e[2]) ^ 2 >= 50 * 50
          -- (lane 82c) WHILE HIS WAY IS FOUND. Run lvD1: made at the host's place and given his walk, he stood about
          -- 1.8 s (no way yet) while the host's walked on: up to 11 m behind in his first 4 s. Now, as long as he has
          -- a walk but no way yet, he is put at the host's place at every line he is over 2.5 m from it; the first
          -- line that finds his way after such a put sets his PathPoint to the point just ahead of where he stands.
          local np = 0; pcall(function() np = #u.Path end)
          if not off and not idle and np < 2 and d2 > lim * lim then
            local okW = pcall(function() u.realPos = { X = h.x, Y = h.y, Z = h.z }; u:K2_SetActorLocation({ X = h.x, Y = h.y, Z = h.z }, false, {}, true) end)
            stat(S, okW and "m82lvStallPut" or "m82lvPutFail"); L.stallPut = true
          elseif L.stallPut and np >= 2 then
            L.stallPut = nil
            local okA = pcall(function() local q = u.realPos; return alignWay(u, q.X, q.Y) end)
            stat(S, okA and "m82lvStallAlign" or "m82lvStallAlignFail")
          end
          if off then
            L.off = 0
            local okW = pcall(function() u.realPos = { X = h.x, Y = h.y, Z = h.z }; u:K2_SetActorLocation({ X = h.x, Y = h.y, Z = h.z }, false, {}, true) end)
            stat(S, okW and "m82lvPut" or "m82lvPutFail")
            if not idle and not newEnd and alignWay(u, h.x, h.y) then stat(S, "m82lvAlign") else idle = true end
          elseif not idle and not newEnd and clock - (L.giveT or -100) >= LV_GRACE then
            -- (run lvC1) on the host's track but a steady second behind (7.7 m at speed 4: the stall after his first
            -- walk): over LV_BEHIND from the host's place now in two lines, at most every 3 s, he is put there with his
            -- way kept (PathPoint set first; no put when that fails: a new walk would stall him again)
            L.behind = d2 > LV_BEHIND * LV_BEHIND and (L.behind or 0) + 1 or 0
            if L.behind >= 2 and clock - (L.catchT or -100) >= 3.0 then
              L.behind = 0; L.catchT = clock
              if alignWay(u, h.x, h.y) then
                local okW = pcall(function() u.realPos = { X = h.x, Y = h.y, Z = h.z }; u:K2_SetActorLocation({ X = h.x, Y = h.y, Z = h.z }, false, {}, true) end)
                stat(S, okW and "m82lvCatch" or "m82lvPutFail")
              else stat(S, "m82lvCatchNoWay") end
            end
          end
          if idle or newEnd then
            local okT = pcall(function() u:setTask(lvWalk(h.tx, h.ty, h.tz)) end)
            if okT then L.e = { h.tx, h.ty }; L.giveT = clock; stat(S, "m82lvWalk") else stat(S, "m82lvWalkFail") end
          end
          if h.ax and C.m82lvanimal ~= false then local okA, eA = pcall(lvAnimal, S, L, h, clock, held); if not okA then stat(S, "m82lvAnErr"); M.lvAnErr = tostring(eA) end end
        elseif d2 > lim * lim then
          -- this copy's own merchant of a carried order: only put (he keeps his own task and way)
          local okW = pcall(function() u.realPos = { X = h.x, Y = h.y, Z = h.z }; u:K2_SetActorLocation({ X = h.x, Y = h.y, Z = h.z }, false, {}, true) end)
          stat(S, okW and "m82lvPut" or "m82lvPutFail")
        end
      end
    end
  end
  -- (lane 82c) a delivered animal the host still names: this copy's animal of that merchant follows its track
  M.lvAnF = M.lvAnF or {}
  for _, Aa in ipairs(hostA) do
    local rec = M.lvAnF[Aa.id]
    if not rec then local L = M.lv[Aa.id]; if L and L.an and valid(L.an) then rec = { a = L.an, trk = {}, off = 0 }; M.lvAnF[Aa.id] = rec end end
    if rec and C.m82lvanimal ~= false then rec.lastT = clock; local okF, eF = pcall(M.animalFollow, S, rec, Aa, clock); if not okF then stat(S, "m82lvAnErr"); M.lvAnErr = tostring(eF) end end
  end
  for id, rec in pairs(M.lvAnF) do if not valid(rec.a) or ((rec.lastT or clock) < clock and clock - rec.lastT > 2.0) then M.lvAnF[id] = nil end end   -- (run per line: a line that no longer names it)
  M.lvLineT = clock
  M.lvSweep(S, clock)
end
-- friend, with every line and every tick: a host merchant no line has named for 1 s: his stand-in goes (an own
-- merchant is left to his own game). A merchant of this copy that no host merchant holds, for 1.5 s while the host's
-- lines come: taken out (lane 73's rule).
function M.lvSweep(S, clock)
  if not M.lv or C.hold or C.m58off then return end
  local held = {}
  for id, L in pairs(M.lv) do
    -- (lane 82c) gone only when a LATER line of the host's no longer names him (or no line at all for LV_SILENT s).
    -- Session l82f: on a loaded PC both copies had frame gaps of 1 to 2.7 s; the host's lines paused for over 1 s
    -- and the stand-in of a merchant who still walked was taken out and made again 11 times in 100 s.
    if (clock - L.lastT >= LV_GONE and (M.lvLineT or -1) > L.lastT) or clock - L.lastT >= LV_SILENT then
      if L.puppet and L.u and valid(L.u) then
        local uid = iid(L.u.UniqueID)
        local okD, e = pcall(function() S.eng:destroyUnit(L.u) end)
        stat(S, okD and "m73lvGone" or "m73lvGoneFail")
        log("merchants: the host's livestock merchant u%s is gone: his stand-in here (unit id %d) taken out with destroyUnit: %s", tostring(id), uid, okD and "ok" or tostring(e))
      elseif L.u and valid(L.u) then
        -- this copy's own merchant of a carried order: he arrives a moment after the host's and is left to his own
        -- game for 10 s (kept within 2.5 m of the host's he needs about 2)
        local a = hex(L.u); if a then M.lvGrace = M.lvGrace or {}; M.lvGrace[a] = clock + 10.0 end
      end
      if L.an and valid(L.an) then M.lvAnF = M.lvAnF or {}; if not M.lvAnF[id] then M.lvAnF[id] = { a = L.an, trk = {}, off = 0, lastT = clock } end end   -- (82c: followed on by the host's A entries)
      M.lv[id] = nil
    elseif L.u and valid(L.u) then local a = hex(L.u); if a then held[a] = true end end
  end
  if clock - (M.lvLineT or -100) > 3.0 then M.lvExtra = nil; return end        -- (no word of the host's: nothing is judged)
  local free
  pcall(function() local lv = S.eng.livestockMerchants; local n = #lv; for i = 1, n do local u = un(lv[i]); if valid(u) then local a = hex(u); if a and not held[a] and not (M.lvGrace and (M.lvGrace[a] or 0) > clock) then free = { u, a } end end end end)
  if not free then M.lvExtra = nil
  elseif not M.lvExtra or M.lvExtra.a ~= free[2] then M.lvExtra = { a = free[2], t = clock }
  elseif clock - M.lvExtra.t >= 1.5 and C.m73lvdestroy ~= false then
    local uid = iid(free[1].UniqueID)
    local okD, e = pcall(function() S.eng:destroyUnit(free[1]) end)
    M.lvExtra = nil; stat(S, okD and "m73lvGone" or "m73lvGoneFail")
    log("merchants: this copy has a livestock merchant (unit id %d) that none of the host's holds: taken out with destroyUnit: %s", uid, okD and "ok" or tostring(e))
  end
end
local function friendTick(S, clock)
  if C.m58off then return end
  -- (lane 82) this copy's merchants as its world began (the save's places): for the first plan's "pairs before"
  if M.snapW ~= S.worlds then M.snapW = S.worlds; M.snap = hereList(S) end
  -- this copy's game makes no merchants of its own: the host's are made here when needed (onFM)
  pcall(function() if S.eng.spawnMerchants then S.eng.spawnMerchants = false; log("merchants: this copy's own new merchants held off (the host's are made here)") end end)
  -- (lane 82b) the counts of the 3 s after an FN line (M.fnJudge)
  local W = M.fnWin
  if W and not W.done and clock >= W.nextT then W.nextT = clock + FN_EVERY; M.fnJudge(W, roleCounts(S), clock); if W.done then M.fnLast = W end end
  if clock - M.sayT >= 60.0 then
    M.sayT = clock; local t = S.stats
    -- (lane 64) "here only": how many the host's last full list left over NOW, then how often one was seen so (a
    -- count that only grows, over every load of the session). The live session of 2026-11-17: "here only 24" was
    -- 3 + 6 + 15 sightings, each 5 s after one of three loads, and each time EVERY merchant of this copy was named at
    -- once, while the daily sample showed this copy one merchant SHORT of the host's (freeMerchants 4/3, 7/6, 16/15).
    -- So the first full list a friend acts on after a load is not a list to remove by: two such lists 1.5 s apart
    -- would take out every merchant of this copy. (Lane 82) Who is who is the plan's business now (M.plan, onFI).
    log("merchants: %d here / %d on the host, lists planned %d (paired by squad %d, by the order of the unit ids %d, by place %d, far %d; %s), missing now %d (seen so %d times, made %d), paired with none now %d (seen so %d times, taken out %d, held for the count %d, switched off %d); sets %d, puts %d (far %d, seen and kept %d), native %s; off as a line came: <2 m %d, 2-5 m %d, 5-10 m %d, more %d; put from behind the host's %d, from ahead %d, from beside %d",
      M.cnt and M.cnt[1] or -1, M.cnt and M.cnt[2] or -1, M.plans or 0, t.m82by_squad or 0, t.m82by_order or 0, t.m82by_place or 0, t.m82by_far or 0, M.steady and "all paired once in this world" or "NOT all paired yet in this world",
      t.m82missingNow or 0, t.m58missing or 0, t.m58spawned or 0, t.m58extraNow or 0, t.m58extra or 0, t.m58destroyed or 0, t.m73extraHeld or 0, t.m82extraOff or 0,
      t.m58set or 0, t.m58put or 0, t.m58putFar or 0, t.m58seenSkip or 0, tostring(M.av) .. (M.farOn and ", held in the table" or ""),
      t.m58d2 or 0, t.m58d5 or 0, t.m58d10 or 0, t.m58dfar or 0, t.m58putBehind or 0, t.m58putAhead or 0, t.m58putBeside or 0)
    -- (lane 73) the unit counts the host has and this copy has: free merchants (role 6), livestock merchants (7), pack animals (15)
    -- (lane 82b) like with like: the host's counts of its FN line against this copy's in the 3 s from that moment
    local L = M.fnLast
    if L and L.c then
      log("merchants: units here / on the host (the host's count of %.0f s ago, this copy's within 3 s of it): free merchants %d / %d, livestock merchants %d / %d, pack animals %d / %d: %s; livestock merchants: stand-ins made %d (ended by the game %d), this copy's own taken as the host's %d, taken out %d, puts %d, walks given %d; off as a line came: <2 m %d, 2-5 m %d, 5-10 m %d, more %d",
          clock - L.t + (L.age or 0), L.c[6] or -1, L.h[6], L.c[7] or -1, L.h[7], L.c[15] or -1, L.h[15], L.verdict or "?", t.m73lvMade or 0, t.m82lvStandInEnded or 0, t.m82lvOwn or 0, t.m73lvGone or 0, t.m82lvPut or 0, t.m82lvWalk or 0,
          t.m82lvd2 or 0, t.m82lvd5 or 0, t.m82lvd10 or 0, t.m82lvdfar or 0)
    end
  end
end

local function tick(S, clock)
  if not (valid(S.eng) and valid(S.p1) and S.sc and valid(S.sc)) then return end
  if S.role == "host" then hostTick(S, clock); hostInventory(S, clock); hostLv(S, clock) elseif S.role == "friend" then friendTick(S, clock); M.lvSweep(S, clock) end
end
local function onMessage(S, from, kind, w)
  if kind == "FV" then if S.role == "friend" and from == "host" then onFV(S, w) end; return true end
  if kind == "FL" then return true end      -- (the line of before lane 82: nothing is done by it)
  if kind == "FN" then
    if S.role == "friend" and from == "host" then
      M.hostRoles = { tonumber(w[4]) or 0, tonumber(w[5]) or 0, tonumber(w[6]) or 0 }
      -- (lane 82b) this copy's own counts in the 3 s from the host's moment (M.fnJudge)
      local age = 0
      if C.men and C.men.lineLag then age = C.men.lineLag(w[2], FN_WINDOW) or 0 end
      local clock = os.clock()
      if M.fnWin and M.fnWin.done then M.fnLast = M.fnWin end
      M.fnWin = { t = clock, age = age, h = { [6] = M.hostRoles[1], [7] = M.hostRoles[2], [15] = M.hostRoles[3] }, eq = {}, done = false, nextT = clock }
      if C.m58off or S.replay then M.fnWin = nil end
    end
    return true
  end
  if kind == "FI" then if S.role == "friend" and from == "host" then onFI(S, w) end; return true end
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
