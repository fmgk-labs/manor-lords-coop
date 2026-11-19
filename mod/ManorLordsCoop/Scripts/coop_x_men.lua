-- Manor Lords Co-op: a squad's men stand, walk and fight where the host's men do (lane 43). Loaded after coop.lua.
--
-- Why: each copy's squad AI gives each man his own place (his slot, the enemy man he goes for, a walk about the camp),
-- so inside a melee and in a camp at rest the two copies' squads were 2 to 7 m apart (bandits up to 18 m), and a place
-- written from Lua is walked back within 0.5 s (lane 38, p2). Every walk of a man starts in one routine of the game
-- (MPATH, 4dbc910); the native piece's MEN item hooks it (native/coop_patch/README.md, "MEN").
--   host    the hook notes the place each request asks for, for every man of every squad (nothing is changed). Four
--           times a second (POLL; the DLL writes a man only when his place moved 1 m) the friends get, per squad and
--           only for men whose place changed: "MM <squad> <host's men> <i>[.<mark>]:<x>,<y>,<z>;..." (i = the man's
--           place in his squad, sorted by id, as for deaths; mark = family.name of a man with a name; dm)
--             fight or camp   each man's new asked place; a man who asked for none: his own place when it moved 1 m
--             stands          its men's own places once it has stood 1 s, then whoever moved 1 m (every 2 s)
--             walks / routs   "MF ...": its men's own places (lane 48; round 2 sent path points, "MW": taken out)
--             militia walks   "MV ...": a militia called up (any owner's) on the move: its men's own places (lane 48)
--             musters         "MU ...": another lord's retinue walking: its men's own places
--           a squad that neither moves nor fights sends nothing; all of a fighting / standing squad again every 10 s.
--           A squad that is gone: "MR <squad>".
--   friend  each named man (by mark, else by place when the head counts match; the squad's list is read again when its
--           head count changes) goes into one MEN SET per frame: this copy's game walks him to the host's place itself
--           (the hook puts it into every request of his; a place 1 m from the last one he was given is given at once).
--           A man of a muster or a militia's march (MU, MV) 40 m from the host's man and not seen by the camera is put there outright.
--           While its men are held, lane 38's mirror gives the squad no corrective orders (C.men.holds); a new order
--           of the host's (its target moved) lets the squad's men go until the host's next line.
--           A man leaves the table at his death (hostKill, the events module's deaths), his squad's change of head
--           count, the squad's end (G, its removal); the whole table when a load or resync begins (the join module),
--           a new world, a role change and when the mod stops (ALLOFF).
-- (lane 73) A WALKING SQUAD'S MEN: LED POINT AND PACE. Live fault (a real session over Steam, game speed 1): on the
-- friends a marching squad went about five steps, stopped, went on; smooth on the host. A man was given the host's
-- man's own place, a round old, every metre he moved: he reached it before the next one came and stood. (Lane 52's
-- sittings ran at speed 4: places 1.5 m apart every round. The link's delay was 0.1 to 0.15 s each way in that
-- session: the host's "delay_ms" of about 1000 was the two PCs' clocks, 0.3 and 0.9 s apart.)
--   host    with the native MEN LEAD (2000 ms; Coop.m73leadMs), a walking man's line entry also carries the point of
--           his OWN way that he reaches in that time and his speed: "<i>[.<mark>]:<x>,<y>,<z>/<lx>,<ly>,<lz>,<cm/s>"
--           (never past his way's end). A man who stopped is sent at once, where he stands.
--   friend  the man walks to the led point; his pace is held to the host's man's own place (native: coop_men.h, LEAD):
--           slower when he is ahead, so he does not reach the point and stand; a new point is given to him only near
--           the end of the way he has, or at a bend. He stops where the host's man's way ends, on the host's word.
-- Test switches: Coop.m73lead = false on the host (no led points are sent: the lines of before) or on a friend (the
-- led points are not used). The link's real delay is logged once a minute on a friend ("MEN link"; the MQ lines).
-- Test switch (console only, friend): Coop.m43off = true gives the "before" (the table emptied, the hook out);
-- Coop.m43off = "ways" lets walking squads go (items 1 and 3 only).
-- Research: research/2026-11-10-game-probe/lanes/lane_s21_43/report.txt (round 2: the cost cut to a few calls a squad).

local C = rawget(_G, "Coop")
if not (C and C.register and C.api and C.armyApi) then return "coop_x_men: load coop.lua first" end
local A, R = C.api, C.armyApi
local M = rawget(C, "men") or {}; C.men = M
local valid, log, send = A.valid, A.log, A.send

local function stat(S, k, n) S.stats[k] = (S.stats[k] or 0) + (n or 1) end
-- (test numbers) the longest time of one step of this module, per step: m43max_<step> (microseconds, 1 ms steps)
local function sec(S, name, t0) local us = math.floor((os.clock() - t0) * 1e6); local k = "m43max_" .. name; if us > (S.stats[k] or 0) then S.stats[k] = us end end
local function hex(u) local ok, a = pcall(function() return u:GetAddress() end); if ok and a and a ~= 0 then return string.format("%X", math.tointeger(a) or a) end end
local function patch() local P = C.patch; if P and P.fn then return P end end
-- the item's state from the status file, looked at every 2 s (reading and parsing the file is the dearest step here)
local function avail()
  local P = patch(); if not P then return false end
  local now = os.clock()
  if M.avT and now - M.avT < 2.0 then return M.avOk, M.avState end
  local st = P.status(); local it = st.items.MEN
  M.avT = now; M.avOk = it ~= nil and it.state ~= "unavailable"; M.avState = it and it.state
  -- (lane 52) the native run-off check counted a held man far from his place for 2 s: the squad's side of it, logged
  M.paceIn = (st.text or ""):find(" pace=in ", 1, true) ~= nil      -- (lane 52, round 3) the native pace rule is hooked
  M.farOk = (st.text or ""):find(" fars=", 1, true) ~= nil          -- (lane 73) it knows the far-held mark (the merchants: SET ...,3)
  M.leadOk = (st.text or ""):find(" lead=", 1, true) ~= nil         -- (lane 73) this native piece knows led points (a SET with them)
  -- (lane 73) the native count of held men of walking squads who came to a stand under a fresh host line (the live fault)
  do local h, hm, wm = (st.text or ""):match(" halts=(%d+) haltms=(%d+) walkms=(%d+)"); if h then M.halt = { tonumber(h), tonumber(hm), tonumber(wm) } end end
  local ro, rl = (st.text or ""):match(" runoffs=(%d+) rlast=(%x+)")
  ro = tonumber(ro)
  if ro and ro > (M.roSeen or 0) then
    local was = M.roSeen or 0; M.roSeen = ro
    if M.diagFn and (M.roSaid or 0) < 200 then M.roSaid = (M.roSaid or 0) + 1; pcall(M.diagFn, rl, ro, was) end
  end
  return M.avOk, M.avState
end

local function reset()
  M.watch = {}; M.last = {}; M.sent = {}; M.here = {}; M.sq = {}; M.wsq = {}; M.pos = {}; M.asked = {}; M.wp = {}; M.hoffOn = nil   -- host
  M.ld = {}; M.stopped = {}; M.ldT = {}                                                                                                          -- host (lane 73)
  M.held = {}; M.cache = {}; M.tgt = {}; M.heldT = {}; M.heldK = {}; M.placedT = {}; M.relW = {}; M.farT = {}; M.tokP = {}; M.joinT = {}; M.emptyT = {}  -- friend
  M.heldL = {}                                                                                                                       -- friend (lane 73)
  M.polled = nil; M.pend = nil; M.needTick = nil
end
if not M.watch then reset() end
M.asked = M.asked or {}; M.wp = M.wp or {}; M.ld = M.ld or {}; M.stopped = M.stopped or {}; M.heldL = M.heldL or {}

-- commands to the DLL wait in M.cmds and go out in one append to its command file at the end of this module's tick
-- (round 2, fA3: each append cost up to 20 ms; one a frame now). cmdNow: one command at once (with what waits).
local function cmd(line) local q = M.cmds; if not q then q = {}; M.cmds = q end; q[#q + 1] = line end
local function flushCmds() local q = M.cmds; if q and #q > 0 then M.cmds = nil; local P = patch(); if P then P.send(table.concat(q, "\n")) end end end
local function sendMen(what, list)           -- MEN <what> a,b,... in lines under 3500 characters
  if #list == 0 then return end
  local sep = what == "SET" and ";" or ","
  local part, n = {}, 0
  for _, x in ipairs(list) do
    part[#part + 1] = x; n = n + #x + 1
    if n > 3500 then cmd("MEN " .. what .. " " .. table.concat(part, sep)); part, n = {}, 0 end
  end
  if #part > 0 then cmd("MEN " .. what .. " " .. table.concat(part, sep)) end
end
local function forget(why)
  local P = patch()
  local ms = C.merch and C.merch.set                           -- (lane 59) the merchants module puts its own entries into the native table
  if P and (next(M.held) or next(M.watch) or (ms and next(ms))) then M.cmds = nil; P.send("MEN FORGET"); P.tick(); log("MEN: table emptied (%s)", why) end
  -- (lane 73) the merchants are held in this table now: what the merchants module thinks is set there is not any more
  if C.merch then C.merch.set = {}; C.merch.dropQ = nil end
  M.held = {}; M.watch = {}; M.last = {}; M.sent = {}; M.here = {}; M.sq = {}; M.cache = {}; M.tgt = {}; M.heldT = {}; M.pend = nil
  M.wsq = {}; M.pos = {}; M.rehold = {}; M.farT = {}; M.who = {}; M.relog = {}; M.asked = {}; M.wp = {}; M.tokP = {}; M.joinT = {}; M.emptyT = {}
  M.ld = {}; M.stopped = {}; M.ldT = {}; M.heldL = {}
end
local function hook(on)
  local P = patch(); if not P then return end
  local ok, state = avail()
  if not ok then if M.saidNA ~= state then M.saidNA = state; log("MEN not available here (%s)", tostring(state)) end; return end
  if on and state ~= "hooked" and (not M.hookT or os.clock() - M.hookT > 2.0) then
    -- the hook was out (never in, or taken out with the table by an ALLOFF of another module): the table is empty,
    -- so everything here is sent again
    M.hookT = os.clock(); M.held = {}; M.watch = {}; M.sq = {}; M.sent = {}; M.heldT = {}; M.wsq = {}; M.pos = {}; M.hoffOn = nil; M.hoffF = nil; M.regoSaid = nil; M.paceSaid = nil; M.keepSaid = nil; M.catchSaid = nil; M.leadSaid = nil; M.ld = {}; M.stopped = {}; M.ldT = {}
    P.send("MEN HOOK ON"); P.tick(); log("MEN HOOK ON (%s)", C.s.role)
    if C.merch then C.merch.set = {}; C.merch.dropQ = nil end      -- (lane 73) the table was emptied with the hook: the merchants are set again
    M.avT = os.clock(); M.avState = "hooked"   -- (the status file is looked at again in 2 s)
  end
  if not on and state == "hooked" then P.send("MEN HOOK OFF"); P.tick(); M.held = {}; M.heldT = {}; if C.merch then C.merch.set = {}; C.merch.dropQ = nil end; M.avT = os.clock(); M.avState = "idle"; log("MEN HOOK OFF") end
end

-- ================================================================ host
-- the watched men = the men of the core's squad lists (S.sq[h].list, read again by the core the moment a squad's head
-- count changes). (lane 48) Every round, and only a squad whose list is a new one is gone through (its men's addresses
-- taken over by id from its last list): the native piece reads the watched men's own places (HERE), so the watch
-- list must be this round's (round 2: the whole list once a second)
local function hostWatch(S)
  local add, gone, now = {}, {}, {}
  local function out(a, h)
    local w = M.watch[a]
    if w and w.h == h then M.watch[a] = nil; gone[#gone + 1] = a; M.last[a] = nil; M.asked[a] = nil; M.wp[a] = nil; M.sent[a] = nil; M.here[a] = nil; M.pos[a] = nil; M.ld[a] = nil; M.stopped[a] = nil; if M.ldT then M.ldT[a] = nil end; if M.vel then M.vel[a] = nil end; if M.posT then M.posT[a] = nil end end
  end
  for h, K in pairs(S.sq or {}) do
    now[h] = true
    local W = M.wsq[h]
    if K.list and (not W or W.list ~= K.list) then
      local byId, set = {}, {}
      if W then for id, a in pairs(W.ids) do byId[id] = a end end
      local ids = {}
      for i, e in ipairs(K.list) do
        if e.addr == nil then e.addr = (e.id and byId[e.id]) or hex(e.u) or false end
        if e.addr then
          set[e.addr] = true; if e.id then ids[e.id] = e.addr end
          if not M.watch[e.addr] then add[#add + 1] = e.addr end
          M.watch[e.addr] = { h = h, i = i, tok = e.tok }
        end
      end
      if W then for a in pairs(W.set) do if not set[a] then out(a, h) end end end
      M.wsq[h] = { list = K.list, set = set, ids = ids }
    end
  end
  for h, W in pairs(M.wsq) do if not now[h] then for a in pairs(W.set) do out(a, h) end; M.wsq[h] = nil end end
  sendMen("UNWATCH", gone); sendMen("WATCH", add)
end
-- (lane 48) where a man's own place lies in him (SMUnit.realPos: its reflected offset), for the native piece's HERE
local function realPosOffset(u)
  local off
  pcall(function()
    local cls = u:GetClass()
    while cls and cls:IsValid() and not off do
      cls:ForEachProperty(function(p) if not off and p:GetFName():ToString() == "realPos" then off = p:GetOffset_Internal() end end)
      local ok, sup = pcall(function() return cls:GetSuperStruct() end)
      if not ok or not sup or not sup:IsValid() then break end
      cls = sup
    end
  end)
  return off
end
-- (lane 52, round 3) "l" after the place: it was LED (sent ahead of the man along his way, a running man)
-- (lane 73) "/<lx>,<ly>,<lz>,<cm/s>" after it: the point of his own way he reaches in the lead time, and his speed
local function entry(i, tok, q, led, ld)
  local s = string.format("%d%s:%d,%d,%d%s", i, (tok and tok ~= "-") and ("." .. tok) or "", math.floor(q[1] / 10 + 0.5), math.floor(q[2] / 10 + 0.5), math.floor(q[3] / 10 + 0.5), led and "l" or "")
  if ld then s = s .. string.format("/%d,%d,%d,%d", math.floor(ld[1] / 10 + 0.5), math.floor(ld[2] / 10 + 0.5), math.floor(ld[3] / 10 + 0.5), math.floor(ld[4] + 0.5)) end
  return s
end
-- a man's own place: (lane 48) the native piece's last word on it (HERE: written when it moved 1 m, read this round
-- by the POLL). Read it directly when HERE is unavailable or a held line needs a missing final stop.
local function luaHere(e, stoppedOnly)
  if not valid(e.u) then return nil end   -- (lane 47 round four) the core's squad list is read again only when its head count changes
  local ok, q = pcall(function()
    if stoppedOnly and e.u.realSpeed ~= 0 then return nil end
    local p = e.u.realPos
    return { p.X, p.Y, p.Z }
  end)
  if ok and q and q[1] then return q end
end
local function hereOf(e)
  if M.hoffOn then return e.addr and M.pos[e.addr] end
  return luaHere(e)
end
local function moved(a, b, cm) return not b or (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 >= cm * cm end
-- a round's squads go in one link line "MX <kind>/<squad>/<host's men>/<entries> ..." (one word a squad; a new line
-- past 3000 characters): round 2, fA3: a line a squad, each written and flushed by the core, cost the host's ticks
local function sendLines(S, kind, h, n, list)
  local words = M.mx; if not words then words = {}; M.mx = words; M.mxLen = 0 end
  local part, len = {}, 0
  local function put() local wd = string.format("%s/%d/%d/%s", kind, h, n, table.concat(part, ";")); words[#words + 1] = wd; M.mxLen = M.mxLen + #wd + 1; part, len = {}, 0 end
  for _, x in ipairs(list) do part[#part + 1] = x; len = len + #x + 1; if len > 1500 then put() end end
  if #part > 0 then put() end
  stat(S, "m43men", #list)
end
local function flushLines(S)
  local words = M.mx; if not words or #words == 0 then return end
  M.mx = nil
  local part, len = {}, 0
  local function out() local l = "MX " .. table.concat(part, " "); send(l); stat(S, "m43bytes", #l + 20); stat(S, "m43lines"); part, len = {}, 0 end
  for _, wd in ipairs(words) do part[#part + 1] = wd; len = len + #wd + 1; if len > 3000 then out() end end
  if #part > 0 then out() end
end
-- a squad's state (light: four values of the squad; its kind and owner once)
-- (lane 48) the squad's values the core read this quarter second (K.st, its snapshot) when it has them: no read here
local function readSquad(S, h, Q, K, clock)
  local ok, ctl, eng, cx, cy, rs
  local st = K and K.st
  if st and K.stT and clock - K.stT < 0.3 then
    if Q.mode and Q.rt == K.stT then return true, Q.mode end      -- the same snapshot as last time: nothing new
    ok, ctl, eng, cx, cy, rs, clock = true, st.ctl, st.eng, st.cx, st.cy, st.rs, K.stT; stat(S, "m43stCore")
  else
    ok, ctl, eng, cx, cy, rs = pcall(function() local s = S.sc:GetSquad({ Value = h }); local c = s.WeightedCenter
      return s.Control, s.isEngaged, c.X, c.Y, tonumber(s.rallyingStatus) or 0 end)
  end
  if not ok then return false end
  if Q.kind == nil then
    pcall(function() local s = S.sc:GetSquad({ Value = h }); Q.kind = tonumber(s.squadType) or 0
      local op = s.ownerPawn; Q.foreign = valid(op) and op:GetAddress() ~= S.p1:GetAddress() end)
    Q.kind = Q.kind or 0
  end
  local mv = false
  if Q.x then mv = (cx - Q.x) ^ 2 + (cy - Q.y) ^ 2 > (50 * (clock - Q.rt) / 0.5) ^ 2 and clock - Q.rt < 2.5 end
  Q.x, Q.y, Q.rt = cx, cy, clock
  local mode
  -- (lane 48) a militia called up (rallyingStatus not 0 = out of its homes: the whole time it is raised, any owner's)
  -- that walks outside a fight: "march", its men's own places, as round 1 sent them. Round 2 gave the player's own
  -- militia path points instead (only another lord's militia counted as a muster), and a man held to the point AFTER
  -- the host's man's current one walks ahead of him: the camp fight's charge 4.6-7.4 m at 99 % (round 1 0.4-0.8).
  -- A fight, a rout and a camp come first (round 2's muster of another lord's militia came before them).
  local free = not eng and ctl ~= 3 and ctl ~= 4
  if Q.kind == 1 and rs ~= 0 and free then mode = (mv or Q.mode == "march") and "march" or nil
  elseif Q.kind == 3 and Q.foreign and free then mode = (mv or Q.mode == "muster") and "muster" or nil end
  if not mode then
    if ctl == 3 then mode = "rout"
    elseif eng then mode = "fight"
    elseif ctl == 4 then mode = "camp"
    elseif mv then mode = "walk"
    else mode = "stand" end
  end
  -- a muster (and a militia's march) ends when the squad stands still 3 s
  if (mode == "muster" or mode == "march") and not mv then Q.musStill = Q.musStill or clock; if clock - Q.musStill > 3.0 then mode = "stand" end else Q.musStill = nil end
  return true, mode
end
local function hostStep(S, clock)
  local P = patch(); if not P then return end
  if clock - (M.pollT or 0) < 0.25 then return end
  M.pollT = clock
  -- (lane 48) the watch list of this round (only squads whose list is new are gone through)
  do local t0 = os.clock(); hostWatch(S); sec(S, "watch", t0) end
  -- (lane 48) the native piece reads the watched men's own places (HERE) once it knows where realPos lies in a man
  if M.hoffOn == nil then
    for _, K in pairs(S.sq or {}) do
      local e = K.list and K.list[1]
      if e and valid(e.u) then
        local off = M.hoffV or realPosOffset(e.u); M.hoffV = off      -- (looked up once a session: the same build)
        if off and off > 0 then cmd(string.format("MEN HEREAT %X", off)); M.hoffOn = true; M.hoffChk = nil; log("MEN: own places read natively (realPos at +%X)", off)
        else M.hoffOn = false; log("MEN: realPos not found in a man's class: own places read through the mod loader") end
        break
      end
    end
  end
  -- (lane 73) the native piece adds each walking man's led point to his HERE line (test switch, host console:
  -- Coop.m73lead = false; Coop.m73leadMs = the time ahead, 2000)
  do
    local lw = (M.hoffOn and C.m73lead ~= false) and math.max(0, math.min(5000, math.floor(tonumber(C.m73leadMs) or 2000))) or 0
    if lw ~= M.leadSaid then M.leadSaid = lw; cmd("MEN LEAD " .. lw); log("MEN: led points %s", lw > 0 and string.format("on (%d ms ahead along each man's own way)", lw) or "off") end
  end
  -- this round's path points for the walking squads' men (the men of the core's list this round: checked again by
  -- the native piece), then the POLL, in one append and one DLL tick a round; the answer (asked places, "W <squad>"
  -- path points, "H" own places) is read at once. (mA: answers a round late made the marches 99 % 7-8 m against round
  -- 1's 1 m; one DLL tick a round, not one per squad)
  local tw0 = os.clock()
  -- (lane 48) no DLL tick of this module's own: the answer read is the one of the POLL sent last round (the patch
  -- module's own tick ran it), then this round's POLL goes out. b1: the own tick (it runs every native item's tick)
  -- was this module's dearest step on the host, up to 59 ms. A round late (0.25 s) is inside the 3 s track.
  local t = ""
  -- (lane 48, round 2) the answer file kept open (the DLL writes it from its start each POLL; lane 47's way)
  if M.polled then
    if not M.pf then M.pf = io.open(P.dir .. "men_out.txt", "rb") end
    local f = M.pf
    if f then local ok, r = pcall(function() f:seek("set", 0); return f:read("a") end); if ok and r then t = r else pcall(function() f:close() end); M.pf = nil end end
  end
  cmd("MEN POLL"); flushCmds(); M.polled = true
  sec(S, "poll", tw0)
  local per, fresh = {}, nil
  local paused = false                                 -- (lane 73) the game stands: a man who "stopped" has not
  if A.isPaused then local okP, p = pcall(A.isPaused); paused = okP and p and true or false end
  if t ~= "" then
    for line in t:gmatch("[^\r\n]+") do
      local ha, hx, hy, hz, rest = line:match("^H (%x+) (%-?%d+) (%-?%d+) (%-?%d+)(.*)")
      if ha then
        if M.watch[ha] then
          -- (lane 52, round 3) the point of his way he walks to now, when the native piece wrote it
          local wx, wy = rest:match("^ (%-?%d+) (%-?%d+)")
          M.wp[ha] = wx and { tonumber(wx), tonumber(wy) } or nil
          -- (lane 73) his led point and speed (" L x y z cm/s end"); " S": he stopped, this is where he stands. A line
          -- without either (his way is being asked for again) leaves the last led point: it is used for 1 s more
          local lx, ly, lz, lv = rest:match(" L (%-?%d+) (%-?%d+) (%-?%d+) (%d+) %d")
          if lx then M.ld[ha] = { tonumber(lx), tonumber(ly), tonumber(lz), tonumber(lv), clock }; stat(S, "m73led") end
          -- (his exact resting place is known from a " S" line until he has moved a metre again)
          M.restAt = M.restAt or {}; M.restAt[ha] = (rest:find(" S", 1, true) and not paused) and true or nil
          -- (not while the game is paused: every man stands then, and none of them has stopped)
          if rest:find(" S", 1, true) and not paused then M.stopped[ha] = true; M.ld[ha] = nil; stat(S, "m73stop") end
          -- (lane 48, round 4) the man's velocity from his last two reports (for the lead of a walking squad's places)
          local q = { tonumber(hx), tonumber(hy), tonumber(hz) }; local p, pt = M.pos[ha], M.posT and M.posT[ha]
          M.vel = M.vel or {}; M.posT = M.posT or {}
          if p and pt and clock - pt > 0.05 and clock - pt < 1.5 then M.vel[ha] = { (q[1] - p[1]) / (clock - pt), (q[2] - p[2]) / (clock - pt) } else M.vel[ha] = nil end
          M.pos[ha] = q; M.posT[ha] = clock; fresh = fresh or ha; stat(S, "m43hpos")
        end
      else
        local a, x, y, z = line:match("^(%x+) (%-?%d+) (%-?%d+) (%-?%d+)")
        local w = a and M.watch[a]
        if w then M.last[a] = { tonumber(x), tonumber(y), tonumber(z) }; M.asked[a] = M.last[a]; M.here[a] = nil; local l = per[w.h]; if not l then l = {}; per[w.h] = l end; l[#l + 1] = a end
      end
    end
  end
  -- (lane 48) once a world: the native place of one man against the mod loader's read now (the native read ran one
  -- round ago: a running man moves a few metres); more than 5 m apart: a wrong offset, HERE goes off for the session
  if M.hoffOn and not M.hoffChk and fresh then
    local a, q = fresh, M.pos[fresh]
    local w = M.watch[a]; local K = w and S.sq[w.h]; local e = K and K.list and K.list[w.i]
    if e and e.addr == a and valid(e.u) then
      local l = luaHere(e)
      if l then
        M.hoffChk = true
        local d = math.sqrt((l[1] - q[1]) ^ 2 + (l[2] - q[2]) ^ 2 + (l[3] - q[3]) ^ 2)
        log("MEN: native own place checked against the mod loader's: %.0f cm apart", d)
        if d > 500 then M.hoffOn = false; cmd("MEN HEREAT 0"); log("MEN: native own places WRONG: read through the mod loader from now on") end
      end
    end
  end
  local tq = os.clock()
  for h, K in pairs(S.sq or {}) do
    local Q = M.sq[h]; if not Q then Q = { st = -100 }; M.sq[h] = Q end
    -- the state: twice a second; every 2 s only for a camp whose men ask for nothing (fA3: a squad that stood was looked
    -- at every 2 s, so a charge began up to 2 s before it counted as walking, its men held where they had stood)
    local busy = Q.mode ~= "camp" or per[h] ~= nil
    if clock - Q.st >= (busy and 0.5 or 2.0) then
      Q.st = clock
      local ok, mode = readSquad(S, h, Q, K, clock)
      if not ok then if Q.mode then sendLines(S, "MR", h, 0, { "-" }); stat(S, "m43release") end; M.sq[h] = nil; Q = nil
      elseif mode ~= Q.mode then Q.mode = mode; Q.since = clock; Q.key = nil end
    end
    if Q and Q.mode and K.list then
      local list, kind, mode = {}, "MM", Q.mode
      local function add(i, e, q, led, ld) M.sent[e.addr] = q; list[#list + 1] = entry(i, e.tok, q, led, ld) end
      local L73 = M.hoffOn and (M.leadSaid or 0) > 0     -- (lane 73) the native piece sends led points
      -- (lane 48, round 4) lead: a walking man's place is sent LEAD s ahead along his own velocity (from his last two
      -- native reports; at most LEAD_MAX), so the friend's man, who reaches it a round and the link later, walks beside
      -- the host's instead of behind him (h4: the bandits' chase 10-20 m behind, then 5 s late at the clash). No lead
      -- once he has not moved for 0.6 s (a man who stopped is sent where he stands).
      local LEAD, LEAD_MAX = 0.75, 600
      local function ahead(a, q)
        if C.m48lead == false then return q end   -- (test switch, host console: Coop.m48lead = false)
        local v, pt = M.vel and M.vel[a], M.posT and M.posT[a]
        if not v or not pt or clock - pt > 0.6 then return q end
        -- (lane 52, round 2: sending a man's own destination instead, 20 m or more ahead, was tried and taken out. e1, e2:
        -- on an MG line the friend put unseen men outright at that far place, the rival militia 117 and 259 m off, and
        -- nothing kept a man beside the host's along the way. What slowed a man on a short way was the squad's pace rule
        -- and the release at every order: the native PACE and friendCheck below.)
        -- only for a man who runs (over 9 m/s at the game's speed: a charge, a chase); a walking one is sent where he is
        -- (i1-i3, the lead for every walking man: the camp fights passed 5 of 5, the battles got worse: a squad that
        -- walks, closes and stops in a line overshot by the lead, the militia 2.3-2.6 m at 99 %, the company to 6 m)
        if v[1] * v[1] + v[2] * v[2] < 900 * 900 then return q end
        local dx, dy = v[1] * LEAD, v[2] * LEAD; local d = math.sqrt(dx * dx + dy * dy)
        if d > LEAD_MAX then dx, dy = dx * LEAD_MAX / d, dy * LEAD_MAX / d; d = LEAD_MAX end
        -- (lane 52, round 3) along his way: towards the point of his way he walks to now, and never past it. A lead
        -- straight on along his last motion left the host's track at every bend of the way (r2 and the lead's lc53_3:
        -- the militia 4.4 and 5.5 m off at the same bend, 15 s into the charge).
        local wp = M.wp[a]
        if wp and d > 1 and C.m52way ~= false then   -- (test switch, host console: Coop.m52way = false)
          local wxd, wyd = wp[1] - q[1], wp[2] - q[2]; local wd = math.sqrt(wxd * wxd + wyd * wyd)
          stat(S, "m52way")
          if wd < 1 then return q end
          local l = math.min(d, wd)
          dx, dy = wxd / wd * l, wyd / wd * l; d = l
        end
        -- (lane 52, round 2) never past the place his own game last asked for him (M.asked: his slot where the squad
        -- halts). h1: the company ran, halted, and the friend's stood 4.7 m past the host's line for 1.8 s, sent there
        -- by the lead. His place lies ahead and nearer than the lead: the place itself when it is within 3 m of his
        -- line of travel, else the lead cut to that length. A place behind him (an old one) changes nothing.
        local g = M.asked[a]
        if g and d > 1 and C.m52cap ~= false then   -- (test switch, host console: Coop.m52cap = false)
          local ux, uy = dx / d, dy / d
          local gx, gy = g[1] - q[1], g[2] - q[2]
          local pr = gx * ux + gy * uy
          if pr >= 0 and pr < d then
            stat(S, "m52cap")
            if gx * gx + gy * gy - pr * pr < 300 * 300 then return { g[1], g[2], g[3] } end
            dx, dy = ux * pr, uy * pr
          end
        end
        return { q[1] + dx, q[2] + dy, q[3] }
      end
      -- (lane 73) walk: a man of a walking squad (MV, MF, MG, MU). With the native led points his line entry is his own
      -- place as it is (the friend's pace is held to it) and the led point (where the friend's man walks to); the lead
      -- along his velocity (lane 48, 52: only for a man over 9 m/s, so never at game speed 1) is not added then.
      -- A man who stopped is sent where he stands at once (the native " S"), not only after a metre.
      local function follow(i, e, cm, lead, walk)
        local q = hereOf(e); local q0 = q
        local led73 = walk and L73
        if q and lead and M.hoffOn and not led73 then q = ahead(e.addr, q) end
        local st = led73 and e.addr and M.stopped[e.addr]
        if st then M.stopped[e.addr] = nil end
        if q and (moved(q, M.sent[e.addr], cm) or (st and moved(q, M.sent[e.addr], 10))) then
          local ld = led73 and not st and M.ld[e.addr] or nil
          if ld and clock - ld[5] > 1.0 then ld = nil end
          -- an older led point (his way was being asked for again this round): only while it still lies ahead of him
          if ld and ld[5] ~= clock then local v = M.vel and M.vel[e.addr]; if not v or (ld[1] - q[1]) * v[1] + (ld[2] - q[2]) * v[2] <= 0 then ld = nil end end
          -- a moving man without a led point this round (his way is being asked for again on the host) who was sent
          -- one in the last 1.5 s is NOT sent his bare place: on the friend that would be "walk to where the host's
          -- man was, and stand". The friend's man keeps the led point he has; the next round names a new one.
          M.ldT = M.ldT or {}
          -- (game run 7, the camp fights: the bandits' rout was 11 m apart for 45 s, lane 70's base 5 to 9 m; the host's
          -- men lines came up to 1.6 s apart in that minute, 23 waits over 0.6 s: routing men often have no way at the
          -- moment of a look, and waiting left the friend's men at their last led point while the host's ran on at
          -- 15 m a second.) A moving man without a way this round gets a led point straight on along his velocity
          -- (his speed x the lead time, 6 to 15 m): for the one round, until his way is there again.
          if led73 and not ld and not st and C.m73vlead ~= false then      -- (test switch, host console: Coop.m73vlead = false)
            local v = M.vel and M.vel[e.addr]; local sp = v and math.sqrt(v[1] * v[1] + v[2] * v[2]) or 0
            if sp >= 20 then
              local d = math.max(600, math.min(1500, sp * (M.leadSaid or 2000) / 1000))
              ld = { q[1] + v[1] / sp * d, q[2] + v[2] / sp * d, q[3], sp, clock }; stat(S, "m73vlead")
            end
          end
          if led73 and not ld and not st and M.ldT[e.addr] and clock - M.ldT[e.addr] < 1.5 then stat(S, "m73wait"); return end
          if ld then stat(S, "m73sent"); M.ldT[e.addr] = clock end
          M.last[e.addr] = q; M.here[e.addr] = true; add(i, e, q, q ~= q0, ld); stat(S, "m43here")
        end
      end
      local full = not Q.key or clock - Q.key >= 10.0
      if mode == "fight" or mode == "camp" then
        if full then
          Q.key = clock
          for i, e in ipairs(K.list) do if e.addr then local q = not M.here[e.addr] and M.last[e.addr]; if q then add(i, e, q) else follow(i, e, 0) end end end
        else
          for _, a in ipairs(per[h] or {}) do local w = M.watch[a]; add(w.i, { addr = a, tok = w.tok }, M.last[a]) end
          -- men who asked for no place (idlers of a camp, men pushed in a melee): their own place, every 2 s
          if clock - (Q.ft or 0) >= 2.0 then Q.ft = clock; for i, e in ipairs(K.list) do if e.addr and (M.here[e.addr] or not M.last[e.addr]) then follow(i, e, 100) end end end
        end
      elseif mode == "stand" then
        -- a new asked place (an order was given: the men ask for their new slots before the squad moves): at once
        for _, a in ipairs(per[h] or {}) do local w = M.watch[a]; add(w.i, { addr = a, tok = w.tok }, M.last[a]); M.here[a] = nil end
        if per[h] then Q.ft = clock end
        -- (lane 73) a man who has just stopped (the native " S"): where he stands, at once (the squad counts as standing
        -- before its last men have stopped; before, such a man's resting place went out with the "stood 1 s" round)
        -- (lane 73) A MAN AT REST IS SENT HIS SLOT, NOT A STALE PLACE. Lane 70 measured (20 line drags): with this module
        -- on, a friend's men stood where the host's stood in 1 to 2 of 20 drags (0.35 to 0.58 m off, up to 1.27 m);
        -- with it off 18 of 20 (0.15 to 0.22 m). The asked places (the men's new slots) went out at once and exact,
        -- and a second later the "stood 1 s" round sent every man's OWN place over them: the native piece writes an
        -- own place only when it moved a metre, so that place was up to a metre old, and the friend's man was held
        -- to it against his slot. Now a standing squad's man is sent the place his own game last asked for him (his
        -- slot; the native piece writes it to 5 cm while he rests) when it lies within 2 m of where he stands; only
        -- a man with no such place (he was pushed, he never asked) is sent where he stands. The same for a man who
        -- has just stopped (the native " S"). Test switch, host console: Coop.m73slot = false (own places, as before).
        local inPer = {}
        for _, a in ipairs(per[h] or {}) do inPer[a] = true end
        local heldLine = C.army and C.army.form and C.army.form[h]
        local function rest(i, e, cm, why)
          local q = hereOf(e); if not q or inPer[e.addr] then return end
          local g = C.m73slot ~= false and M.asked[e.addr]
          -- In game run 8 the formation was given the same on both copies in 20 of 20 drags, the men stood the same
          -- in 16; in the four misses ONE friend man stood 0.2 to 1.5 m from his host twin. A host man does not always
          -- rest IN his slot (a neighbour stands in his way). So when his exact resting place is known (the native
          -- " S"), the slot is sent only if he rests within 40 cm of it; else where he rests.
          local at = q
          if g then
            local d2 = (g[1] - q[1]) ^ 2 + (g[2] - q[2]) ^ 2
            if M.restAt and M.restAt[e.addr] then if d2 < 40 * 40 then at = g end
            elseif d2 < 200 * 200 then
              -- A line drag can leave him at rest without a final S. In three measured misses
              -- his old request was 1.41 to 1.56 m away. Check where he actually stopped.
              at = (heldLine and luaHere(e, true)) or g
            end
          end
          if moved(at, M.sent[e.addr], cm) then
            M.last[e.addr] = at; M.here[e.addr] = at ~= g or nil
            add(i, e, at); stat(S, at == g and "m73slot" or "m43here"); if why then stat(S, why) end
          end
        end
        if L73 then
          for i, e in ipairs(K.list) do if e.addr and M.stopped[e.addr] then rest(i, e, 10, "m73stopSent") end end
        end
        -- its men's places once it has stood 1 s (and every 10 s); between: whoever's place changed 10 cm, every 2 s
        if clock - Q.since >= 1.0 and not per[h] then
          if full then Q.key = clock; Q.ft = clock; for i, e in ipairs(K.list) do if e.addr then rest(i, e, 0) end end
          elseif clock - (Q.ft or 0) >= 2.0 then Q.ft = clock; for i, e in ipairs(K.list) do if e.addr then rest(i, e, 10) end end end
        end
      elseif mode == "muster" then
        kind = "MU"
        -- (lane 48) every round, as a march (round 2: every 0.5 s; t1: a retinue sprinting in the battle 2-3 s behind)
        for i, e in ipairs(K.list) do if e.addr then follow(i, e, 100, false, true) end end
      elseif mode == "march" then
        -- (lane 48) a militia on the move: its men's own places, every round (round 1's rule for it)
        -- (lane 48, round 2) "MG" for another lord's militia (its men walk in from their homes: a friend may put an
        -- unseen man 40 m off at his place); the player's own militia ("MV") is never put outright (t7: all 13 put
        -- in a charge, the squad 50 m behind after it)
        kind = Q.foreign and "MG" or "MV"
        for i, e in ipairs(K.list) do if e.addr and (M.hoffOn or valid(e.u)) then follow(i, e, 100, true, true) end end
      else
        -- (lane 48) any other squad that walks or routs: its men's own places too, every round ("MF"). Round 2 sent
        -- path points (the point after each man's current one, "MW"); sitting w1, the company's marches: own places
        -- 0.4-0.5 m at 99 %, path points 5.2 m (both answered in the same round): path points taken out
        kind = "MF"
        for i, e in ipairs(K.list) do if e.addr and (M.hoffOn or valid(e.u)) then follow(i, e, 100, true, true) end end
      end
      if #list > 0 then sendLines(S, kind, h, #K.list, list) end
    end
  end
  sec(S, "squads", tq)
  if next(M.stopped) then M.stopped = {} end     -- (lane 73) a stop is this round's word (used above, or the squad's mode has no use for it)
  flushLines(S)
end

-- ================================================================ friend
-- a squad's men here: the sorted list with marks, read again when the head count changes (or after 10 s)
-- (lane 48, round 2) one squad's list read again a frame at most (M.lb, set each tick): reading a list costs three
-- reads through the mod loader a man, and in a battle several squads lose men in one frame (t4-t7: the friend's
-- longest ticks, 13-47 ms, were these reads). A squad whose turn has not come keeps its last list meanwhile (its
-- men are matched by their marks, or wait a frame: the index match needs the head counts equal).
local function listOf(lh, clock, n)
  local c = M.cache[lh]
  local due = not c or clock - c.t >= 10.0 or (n and c.n ~= n)
  if due and c and (M.lb or 1) <= 0 then stat(C.s, "m43listWait"); return c end
  if due then
    M.lb = (M.lb or 1) - 1
    local tl = os.clock()
    local l, inSq = {}, {}
    for _, u in ipairs(R.unitsOf(lh)) do local okI, id = pcall(function() return u.UniqueID end); local a = hex(u); if okI and a then l[#l + 1] = { id = id, u = u, addr = a }; inSq[a] = true end end
    table.sort(l, function(x, y) return x.id < y.id end)
    c = { t = clock, n = #l, list = l, inSq = inSq }; M.cache[lh] = c
    sec(C.s, "list", tl)
  end
  return c
end
local function dropList(list, why)
  if #list == 0 then return end
  for _, a in ipairs(list) do M.held[a] = nil end
  -- a death goes out at once (the man is killed right after); the others with this frame's one DLL tick
  -- (lane 52) men let go at an order stay watched by the native run-off check (MEN LET): its 2 s must outlast the
  -- release and the next line's hold, or it could never see a squad that is let go and held again every second
  if why == "order" or why == "ways" then sendMen("LET", list) else sendMen("DROP", list) end
  if why == "death" then flushCmds(); local P = patch(); if P then P.tick() end end
  stat(C.s, "m43drop_" .. why, #list)
end
-- (lane 48) a squad let go at a new order keeps its men's last host places for 0.75 s: when no host line holds them
-- again by then (the host's squad stands and sends nothing new), they are held to those places again (b2: after the
-- camp fight the friend's militia got a target of its own, its men were let go and walked 6 m off for 7 s, the host's
-- standing squad sending nothing)
local function dropSquad(lh, why)
  -- (lane 52) the squad's last releases, for the run-off dump
  M.relog = M.relog or {}; local rl = M.relog[lh]; if not rl then rl = {}; M.relog[lh] = rl end
  rl[#rl + 1] = string.format("%s@%.2f", why, os.clock()); if #rl > 12 then table.remove(rl, 1) end
  -- (lane 52, round 2) releases per squad and line kind, and how long until a host line holds the squad again
  if why == "order" and M.heldT[lh] then local hh = A.toHost and A.toHost(lh) or lh; stat(C.s, "m52rel_" .. tostring(M.heldK[lh]) .. "_" .. tostring(hh)); M.relT0 = M.relT0 or {}; M.relT0[lh] = os.clock() end
  M.tgt[lh] = nil; M.heldT[lh] = nil
  local gone, keep = {}, {}
  for a, e in pairs(M.held) do if e.lh == lh then gone[#gone + 1] = a; if e.p then keep[#keep + 1] = a .. "=" .. e.p end end end
  M.rehold = M.rehold or {}
  M.rehold[lh] = (why == "order" and #keep > 0) and { t = os.clock(), set = keep } or nil
  dropList(gone, why)
end
-- (item 3) a man of a muster more than 40 m from the host's man's place, which neither the camera (60 m, as the job
-- board's "place") nor the pointer sees: put at the host's place outright (realPos and the actor, as the job board's
-- place does), at most once in 3 s; the GO that follows in the same frame gives him the host's place to walk on from
-- (lane 52, round 3, second helper) near: the distance from which he is put (cm; 40 m when not given)
local function placeFar(S, e, x, y, z, clock, near)
  -- (lane 48) each man looked at once a second at most (a march sends its men every round: a read of each man's place
  -- through the mod loader four times a second was the friend's dearest per-man step)
  M.farT = M.farT or {}
  if M.farT[e.addr] and clock - M.farT[e.addr] < 1.0 then return end
  M.farT[e.addr] = clock
  -- (lane 47 round four) e.u comes from the squad's list read up to 10 s ago (listOf): a man the game destroyed since
  -- and an engine clean-up freed would close the game at the first read below (coop_x_jobs fillList, round three)
  if not valid(e.u) then return end
  local ok, p = pcall(function() local q = e.u.realPos; return { q.X, q.Y } end)
  near = near or 4000
  if not ok or not p or (p[1] - x) ^ 2 + (p[2] - y) ^ 2 < near * near then return end
  if M.placedT[e.addr] and clock - M.placedT[e.addr] < 3.0 then return end
  if C.m48place ~= "force" then   -- (test switch, friend console: "force" puts men outright whether seen or not)
    local cam = M.cam
    if not cam or clock - cam.t > 0.2 then
      local okC, c = pcall(function() local l = S.p1.Camera:K2_GetComponentLocation(); return { l.X, l.Y, l.Z } end)
      cam = { t = clock, c = okC and c or nil }; M.cam = cam
    end
    if not cam.c then stat(S, "m43place_nocam"); return end
    local L = 6000 * 6000
    if (p[1] - cam.c[1]) ^ 2 + (p[2] - cam.c[2]) ^ 2 < L or (x - cam.c[1]) ^ 2 + (y - cam.c[2]) ^ 2 < L then stat(S, "m43place_seen"); return end
    local hov = false; pcall(function() local hv = S.p1.hoverUnit; hov = valid(hv) and hv:GetAddress() == e.u:GetAddress() end)
    if hov then stat(S, "m43place_hover"); return end
  end
  M.placedT[e.addr] = clock
  local okP = pcall(function() e.u.realPos = { X = x, Y = y, Z = z }; e.u:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true) end)
  stat(S, okP and "m43placed" or "m43place_failed")
  -- (lane 48) the man's place is given again with this frame's SET even when it is the one he was given before (the
  -- native piece gives a place at once only when it moved 50 cm since the last one: a man put outright kept the path
  -- he had from where he stood): he leaves the native table first, the SET adds him fresh, with a GO
  if okP and C.m48regive ~= false then M.regive = M.regive or {}; M.regive[e.addr] = true end   -- (test switch: Coop.m48regive = false)
end
-- MM / MF / MV / MU <host squad> <host's head count> <entries>
local function onMM(S, w, kind)
  if C.m43off == true or C.hold then return end
  local lh = A.toLocal(tonumber(w[4])); local n = tonumber(w[5])
  if not (lh and w[6]) then return end
  local clock = os.clock()
  -- (lane 73) this player's own order for the squad waits for the host's answer: a host line from before it is not taken
  local o = M.own and M.own[lh]
  if o and not o.said then
    local age = clock - o.t
    local after
    -- (lane 70's answer to a player's order, coop_x_army.lua, when it is there: while the answer is on its way no host
    -- line is from after his order; once it came, a line whose clock is 0.3 s past the answer's is (its places are
    -- up to a round older than the line))
    local ack = C.orderAckWall and C.orderAckWall(lh)
    if C.orderPending and C.orderPending(lh) then after = false
    elseif ack and M.curWall then after = M.curWall >= ack + 0.3
    elseif M.curWall and M.lkOff then after = M.curWall >= (A.now() - age) + M.lkOff + (M.lkRt or 0.25) / 2 + 0.5
    else after = age >= 0.75 end
    if not after then o.skipped = o.skipped + 1; stat(S, "m73ownSkip"); return end
    o.said = true
    log("MEN: this player's order for squad %d: its men were let go; %d line(s) of the host's from before the order were not taken; the host's first line after it came %.0f ms after the order", lh, o.skipped, age * 1000)
  end
  local cn, okN
  local Mi = S.mir and S.mir[lh]; local st = Mi and Mi.st
  local fresh = st and Mi.stT and clock - Mi.stT < 0.15     -- (lane 48) lane 38's mirror's read of this squad
  if fresh then okN, cn = true, st.n else okN = pcall(function() cn = S.sc:GetUnitCount({ Value = lh }) end) end
  if not okN or not cn or cn <= 0 then
    -- (lane 52, round 3, second helper) another lord's militia that is called up on the host and has no men here yet
    -- (this copy's call-up comes a moment later): the host's places are kept by mark (M.joined), and the unit's first
    -- 3 s with men count as its call-up (below). fin1: the friend's unit read 8.5 m from the host's in its first two
    -- looks (0.5 s); fin2, the men's own places: 3.9 to 6.7 m apart at the same instant for the first 5 s. Each copy's
    -- men start from where its own villagers stand. fin3 (the first form, only lines of the kind MG: the host's first
    -- lines of a call-up are of other kinds, nothing was kept): 6.3 m at the unit's first look, 4 men put a look later.
    -- Any line that carries marks counts, for a unit that is not the player's own (that one is never put outright:
    -- lane 48, t7).
    if okN and cn == 0 and not (S.mine and S.mine[lh]) and C.m52join ~= false then
      M.emptyT = M.emptyT or {}; M.emptyT[lh] = clock
      M.tokP = M.tokP or {}; local tp = M.tokP[lh]; if not tp then tp = {}; M.tokP[lh] = tp end
      for item in w[6]:gmatch("[^;]+") do
        local tok, x, y, z = item:match("^%d+%.([^:/]+):(%-?%d+),(%-?%d+),(%-?%d+)l?")     -- (lane 73: a led point may follow)
        if tok then tp[tok] = { tonumber(x) * 10, tonumber(y) * 10, tonumber(z) * 10, clock } end
      end
    end
    return
  end
  M.cnt = M.cnt or {}; M.cnt[lh] = { cn, n, clock }       -- (lane 73) men here / on the host, for the minute line
  if not M.tgt[lh] then if fresh then M.tgt[lh] = { st.tx, st.ty } else pcall(function() local t = S.sc:GetSquad({ Value = lh }).TargetLocation; M.tgt[lh] = { t.X, t.Y } end) end end
  local c = listOf(lh, clock, cn); local sets = M.pend or {}; M.pend = sets
  local k, ledN = 0, 0
  -- (lane 73) led points are used with the native pace rule only (it holds the man's pace to the host's man's place)
  local use73 = C.m73lead ~= false and M.leadOk and M.paceIn and C.m52pace ~= false and C.m52catch ~= false
  for item in w[6]:gmatch("[^;]+") do
    local i, tok, x, y, z, led, more = item:match("^(%d+)%.?([^:]*):(%-?%d+),(%-?%d+),(%-?%d+)(l?)(.*)$")
    local lx, ly, lz, lv
    if more and more ~= "" then
      lx, ly, lz, lv = more:match("^/(%-?%d+),(%-?%d+),(%-?%d+),(%d+)$")
      if not lx then i, tok = nil, nil; stat(S, "m73badTail") end      -- a tail this build does not know: not taken
    end
    local e
    if tok and tok ~= "" then
      -- the marks (family.name) are read only for a squad whose host lines carry them (a militia), once per list
      if not c.byTok then c.byTok = {}; for _, x in ipairs(c.list) do if valid(x.u) then local okT, tk = pcall(function() local nm = x.u.DisplayName:ToString(); return (nm ~= "" and nm) and (tostring(x.u.workerFamilyID) .. "." .. (nm:gsub("[^%w]", "_"))) or nil end); if okT and tk then c.byTok[tk] = x end end end end
      e = c.byTok[tok]
    elseif i and #c.list == n then e = c.list[tonumber(i)] end
    if e and e.addr then
      x, y, z = tonumber(x) * 10, tonumber(y) * 10, tonumber(z) * 10
      -- (lane 52, round 3, second helper) a man the core took into the unit by his mark in the last 3 s, whose host place
      -- was not known at that moment (M.joined): put from 5 m, as there
      -- and every man of such a unit in the first 3 s after it got its men here (its call-up), whatever the line's kind
      local jt = M.joinT and M.joinT[e.addr]
      if jt and clock - jt >= 3.0 then M.joinT[e.addr] = nil; jt = nil end
      local et = C.m52join ~= false and M.emptyT and M.emptyT[lh]
      if et and clock - et >= 3.0 then M.emptyT[lh] = nil; et = nil end
      if (kind == "MU" or kind == "MG" or C.m48place == "force" or jt or et) and C.m48place ~= "off" then
        placeFar(S, e, x, y, z, clock, (jt or et) and 500 or nil)
      end
      -- (lane 52, round 2) ",1": the host's man's OWN place of this round (a walking squad's line), for the native catch-up
      -- Not for another lord's muster (MG, MU): there the core holds the squad's mean speed to the host's through the
      -- men's Speed (musterPace), which takes back whatever the factor adds (h3: "speed=10.36 factor=1.500 real=15.54").
      -- (round 3) ",2" for another lord's muster and march (MG, MU) when the native pace rule is in: such a man's pace
      -- is the native rule's alone, and the core's speed matching stands down for that squad (M.musters)
      -- (round 3) no catch-up mark on a LED place: the lead is what brings a running man beside the host's, and a place
      -- 6 m ahead read as "6 m behind": at the charge's start the friend's standing men ran at 1.5 and were 7 m AHEAD of
      -- the host's forming squad (v4: 7.4 m, v5: 5.3 m, bandits 31 in v3: 6.2 m, all in the first 4 s of a charge)
      -- (round 3) THE ROUT: while the host's squad routs (the core's mirror knows: Mi.routed), its men's places come
      -- with ",2" as a muster's do: the native rule's pace alone, up to 3 (a routing man runs at 3). w1: this copy's
      -- own rout of the militia ended 8 s before the host's (its own retreat point was nearer); from then on its men
      -- were ordinary held men at pace 1 to 1.5 (16 to 23 against the host's 44), 73 m behind, 10 s late at the end.
      local routing = Mi and Mi.routed and M.paceIn and C.m52rout ~= false   -- (test switch, friend console: Coop.m52rout = false)
      local mode = routing and 2 or ((kind == "MV" or kind == "MF") and led ~= "l") and 1 or ((kind == "MG" or kind == "MU") and M.paceIn and C.m52mus ~= false) and 2 or 0
      local pl = string.format(mode == 2 and "%d,%d,%d,2" or mode == 1 and "%d,%d,%d,1" or "%d,%d,%d", x, y, z)
      local own = pl
      -- (lane 73) LED: he walks to the led point; the host's man's own place and speed follow for his pace. The place
      -- is a round old when the host sends it (the POLL's answer is read a round later): moved on towards the led
      -- point by that quarter second of his walk, and never past it.
      if lx and mode > 0 and use73 then
        lx, ly, lz, lv = tonumber(lx) * 10, tonumber(ly) * 10, tonumber(lz) * 10, tonumber(lv)
        local dx, dy = lx - x, ly - y; local d = math.sqrt(dx * dx + dy * dy)
        local ax, ay = x, y
        if d > 1 then local adv = math.min(lv * 0.25, d); ax, ay = x + dx / d * adv, y + dy / d * adv end
        pl = string.format("%d,%d,%d,%d,%d,%d,%d", lx, ly, lz, mode, math.floor(ax + 0.5), math.floor(ay + 0.5), lv)
        ledN = ledN + 1
      end
      sets[#sets + 1] = e.addr .. "=" .. pl
      M.held[e.addr] = { lh = lh, p = own }; k = k + 1      -- (p: for the rehold after an order: his own place, never a led point)
      M.who = M.who or {}; M.who[e.addr] = { lh = lh, i = i, tok = tok, kind = kind, p = pl, t = clock }   -- (lane 52, the run-off dump)
    elseif i then
      stat(S, "m43nomatch")
      -- (lane 52, round 3, second helper) the host's place for a man by his mark who is not in the unit here yet: kept
      -- 3 s for the moment the core takes him into it (M.joined)
      if tok and tok ~= "" and (kind == "MG" or kind == "MU") then
        M.tokP = M.tokP or {}; local tp = M.tokP[lh]; if not tp then tp = {}; M.tokP[lh] = tp end
        tp[tok] = { tonumber(x) * 10, tonumber(y) * 10, tonumber(z) * 10, clock }
      end
    end
  end
  if ledN > 0 then stat(S, "m73set", ledN) end
  if k > 0 then M.heldT[lh] = clock; M.heldK[lh] = kind; M.heldL[lh] = ledN > 0 or nil; stat(S, "m43set", k); if M.rehold then M.rehold[lh] = nil end
    if M.relT0 and M.relT0[lh] then local g = math.floor((clock - M.relT0[lh]) * 1000); M.relT0[lh] = nil; stat(S, "m52relGapMs", g); stat(S, "m52relGapN"); if g > (S.stats.m52relGapMax or 0) then S.stats.m52relGapMax = g end end
  end
end
-- ten times a second, per squad whose men are held: its head count (a man left: the list is read again and who is not
-- in it any more is dropped), the squad's end, and a new order of the host's (its target moved 3 m, not in a fight)
local function friendCheck(S, clock)
  if clock - (M.chkT or 0) < 0.1 then return end   -- (ten times a second: a new order of the mirror must let the men go at once; fA1-fA4 at 0.25 s lagged)
  M.chkT = clock
  local sqs = {}
  for _, e in pairs(M.held) do sqs[e.lh] = true end
  for lh in pairs(M.heldT) do if not sqs[lh] then M.heldT[lh] = nil end end   -- (lane 48) no man of it held any more
  -- (lane 73) THIS PLAYER'S OWN ORDER is not thrown away on his copy (live report: "a friend sent an order to a troop
  -- unit and right after his command got overridden"). The core notes the moment of his order (S.localOrderT, as
  -- lane 38's mirror uses it for 2 s). From that moment: the squad's men are let go at once, also while the host's
  -- lines for the old walk still come (before, such a squad stayed held to the host's men for the second until they
  -- turned); host lines from BEFORE his order are not taken (by the host's clock in the line, set against the
  -- measured difference of the two clocks; without it for 0.75 s); and the men are not held again to the host's old
  -- places 0.75 s later (the rehold below: on a real link the host's first line after an order needs 0.55 to 0.8 s,
  -- on two test copies 0.4 to 0.65). After 2 s without a host line for the squad (the host did not move it) the
  -- old rules count again. One log line per order. Test switch, friend console: Coop.m73own = false.
  M.own = M.own or {}
  if C.m73own ~= false and S.mine and S.localOrderT then
    for lh, ot in pairs(S.localOrderT) do
      if S.mine[lh] and clock - ot < 2.0 and (not M.own[lh] or M.own[lh].t ~= ot) then
        M.own[lh] = { t = ot, skipped = 0 }; stat(S, "m73own")
        if sqs[lh] then dropSquad(lh, "order"); sqs[lh] = nil end
      end
    end
  end
  for lh, o in pairs(M.own) do
    if clock - o.t >= 2.0 and not (C.orderPending and C.orderPending(lh) and clock - o.t < 3.5) then      -- (lane 70: its answer may take 3 s)
      if not o.said then log("MEN: this player's order for squad %d: no line of the host's for it in 2 s (%d from before the order not taken): the host's last places count again", lh, o.skipped) end
      M.own[lh] = nil
    end
  end
  for lh in pairs(sqs) do
    -- (lane 48) the squad's values lane 38's mirror read in the last 0.15 s when it has them (no reads here)
    local ok, n, x, y, eng
    local Mi = S.mir and S.mir[lh]; local st = Mi and Mi.st
    if st and Mi.stT and clock - Mi.stT < 0.15 then ok, n, x, y, eng = true, st.n, st.tx, st.ty, st.eng or st.ctl == 3; stat(S, "m43stMirror")
    else ok, n, x, y, eng = pcall(function() local s = S.sc:GetSquad({ Value = lh }); local t = s.TargetLocation; return S.sc:GetUnitCount({ Value = lh }), t.X, t.Y, s.isEngaged or s.Control == 3 end) end
    if not ok or not n or n <= 0 then dropSquad(lh, "gone")
    else
      local c = M.cache[lh]
      if c and c.n ~= n then
        c = listOf(lh, clock, n); local gone = {}
        for a, e in pairs(M.held) do if e.lh == lh and not c.inSq[a] then gone[#gone + 1] = a end end
        dropList(gone, "left")
      end
      -- (lane 48, round 3) not for another lord's retinue at its muster (MU): its target place changes as it walks, so
      -- it "moved 3 m" again and again and its men were let go and held again every few rounds (e1, g1-g3, with this:
      -- the retinue's muster 0.5-1.8 m, 4 of 4; round 2 without it: 2 of 3 failed)
      -- (lane 52, round 2) nor for any walking squad (MV, MG, MF) whose host line is under 1 s old: its men get the
      -- host's own places every round, so the host's next word is a quarter second away, and the release only sent
      -- them to this copy's own slots meanwhile. A squad that attacks a moving target "moved 3 m" all the time: d1,
      -- d2 176 and 206 releases of the militia in one camp fight (one every 0.7 s); b5: the militia's line turned
      -- from facing 18 to 123 degrees and walked 5 m back for a second while the host's walked on. The new target
      -- is taken as the one to compare with. A squad whose host is silent (it stands) is let go at an order as before.
      local t0 = M.tgt[lh]; local kd = M.heldK[lh]
      if t0 and not eng and kd ~= "MU" and (x - t0[1]) ^ 2 + (y - t0[2]) ^ 2 > 300 * 300 then
        -- (lane 73) a squad whose last line carried led points has way for 2 s and more: its lines may come 1 s late and
        -- in bursts (a slow link) without the squad being let go at the mirror's next corrective order
        local fed = (kd == "MV" or kd == "MG" or kd == "MF") and M.heldT[lh] and clock - M.heldT[lh] < (M.heldL[lh] and 2.5 or 1.0)
        if fed and C.m52rel ~= true then M.tgt[lh] = { x, y }; stat(S, "m52kept_" .. kd)   -- (test switch, friend console: Coop.m52rel = true lets go as before)
        else dropSquad(lh, "order") end
      end
    end
  end
  -- (lane 48) squads let go at an order and not held again by a host line in 0.75 s: their men's last host places
  -- again (men still in the squad's list only; not for a squad that routs or is gone)
  for lh, Rh in pairs(M.rehold or {}) do
    if clock - Rh.t >= 0.75 and not M.own[lh] then      -- (lane 73: not while this player's own order waits for the host's answer)
      M.rehold[lh] = nil
      local ok, n, x, y, rout
      local Mi = S.mir and S.mir[lh]; local st = Mi and Mi.st
      if st and Mi.stT and clock - Mi.stT < 0.15 then ok, n, x, y, rout = true, st.n, st.tx, st.ty, st.ctl == 3
      else ok, n, x, y, rout = pcall(function() local s = S.sc:GetSquad({ Value = lh }); local t = s.TargetLocation; return S.sc:GetUnitCount({ Value = lh }), t.X, t.Y, s.Control == 3 end) end
      if ok and n and n > 0 and not rout and not M.heldT[lh] then
        local c = listOf(lh, clock, n); local sets = M.pend or {}; M.pend = sets; local k = 0
        for _, s in ipairs(Rh.set) do local a, p = s:match("^(%x+)=(.*)$"); if a and c.inSq[a] then sets[#sets + 1] = s; M.held[a] = { lh = lh, p = p }; k = k + 1 end end
        if k > 0 then M.heldT[lh] = clock; M.tgt[lh] = { x, y }; stat(S, "m43rehold", k) end
      end
    end
  end
end

-- (lane 52) the squad's side of a run-off the native check counted (avail() calls it when runoffs= grew): the man's
-- squad, its line kind and hold, lane 38's mirror's branch, state and last orders, the squad's releases, its order and
-- target here, and the man's own fields read through the mod loader. One log line; the native dump is men_diag.txt.
M.diagFn = function(rl, ro, was)
  local S = C.s; local w = M.who and M.who[rl]
  if not w then log("MEN RUNOFF %d (+%d): man %s not in the table of host places", ro, ro - was, tostring(rl)); return end
  local lh, clock = w.lh, os.clock()
  local Mi = S.mir and S.mir[lh]; local st = Mi and Mi.st or {}
  local sq = "?"
  pcall(function() local s = S.sc:GetSquad({ Value = lh }); local t = s.TargetLocation; local c = s.WeightedCenter
    sq = string.format("ctl=%s eng=%s rs=%s tgtSq=%s tgtAt=%.0f,%.0f ctr=%.0f,%.0f n=%d", tostring(s.Control), tostring(s.isEngaged), tostring(s.rallyingStatus), tostring(s.targetSquad.Value), t.X, t.Y, c.X, c.Y, S.sc:GetUnitCount({ Value = lh })) end)
  local man = "?"
  pcall(function()
    for _, u in ipairs(R.unitsOf(lh)) do
      if hex(u) == rl then local p = u.realPos
        man = string.format("pos=%.0f,%.0f sprint=%s stamina=%.3f speed=%.2f real=%.2f def=%.2f block=%.2f", p.X, p.Y, tostring(u.sprintMode), u.stamina, u.Speed, u.realSpeed, u.def, u.block) end
    end
  end)
  log("MEN RUNOFF %d (+%d): man %s of squad %d (host %s) #%s kind %s, place %s %.1f s old; held now %s, holds()=%s, heldT %.1f s; mirror br=%s tgt=%s eng=%s ctl=%s; here: %s; man: %s; releases: %s",
      ro, ro - was, rl, lh, tostring(A.toHost and A.toHost(lh)), tostring(w.i), tostring(w.kind), tostring(w.p), clock - w.t, tostring(M.held[rl] ~= nil),
      tostring(M.holds(lh)), M.heldT[lh] and clock - M.heldT[lh] or -1, tostring(Mi and Mi.br), tostring(st.tgt), tostring(st.eng), tostring(st.ctl), sq, man,
      table.concat((M.relog and M.relog[lh]) or {}, " "))
end
-- the core and the events module call this right before a man is killed on the host's word
function M.gone(u)
  local a = hex(u)
  -- (lane 52) also a man let go at an order (still in the native table for the run-off check)
  if a and (M.held[a] or (M.who and M.who[a])) then dropList({ a }, "death"); if M.who then M.who[a] = nil end end
end
-- (lane 52, round 3, second helper) the core calls this right after it took a man into another lord's militia unit by
-- his mark (the host named him). He joins where he is on this copy, and the rival's villagers stand elsewhere on each
-- copy: x1, three men taken at once, the unit's centre jumped 5.7 m in 0.4 s (largest 7.0 m off the host's track; z3
-- 5.5 m, zb1 11.9 m at the same moment of the call-up). The host's line already carries its man of that mark
-- (M.tokP, kept 3 s): he is put there outright when he is 5 m or more from it and neither the camera nor the
-- pointer sees it (placeFar's rule; test switch, friend console: Coop.m52join = false). The next host line holds him.
function M.joined(S, lh, tok, u)
  if S.role ~= "friend" or C.m52join == false or C.m48place == "off" or C.m43off == true then return end
  local tp = M.tokP and M.tokP[lh]; local q = tp and tp[tok]
  local clock = os.clock()
  if not q or clock - q[4] > 3.0 then
    -- no word of the host's on him yet: the first host line that names him in the next 3 s puts him (onMM)
    local a0 = valid(u) and hex(u); if a0 then M.joinT = M.joinT or {}; M.joinT[a0] = clock; if M.farT then M.farT[a0] = nil end end
    stat(S, "m52joinNoPlace"); return
  end
  tp[tok] = nil
  if not valid(u) then return end
  local a = hex(u); if not a then return end
  stat(S, "m52join")
  placeFar(S, { u = u, addr = a }, q[1], q[2], q[3], clock, 500)
end
-- the core calls this when a squad ends here (the host's G line, its removal)
function M.squadGone(lh) if lh and M.heldT and M.heldT[lh] then dropSquad(lh, "squad") end end
-- the join module calls this the moment a load or a resync begins (the table empties before the world goes)
function M.loadBegins() local ms = C.merch and C.merch.set; if M.held and (next(M.held) or next(M.watch) or (ms and next(ms))) then forget("a load begins"); if ms then C.merch.set = {}; C.merch.dropQ = nil end end end   -- (lane 59) the merchants' entries too
-- lane 38's mirror asks: are this squad's men held (round 2: a host line for it in the last 2 s)? It then gives no corrective
-- orders: they would let go of the men and send them to a squad-wide place (round 1: 7 000 such releases a sitting)
-- (fA1: a walking squad without lane 38's corrections fell 3-8 m behind for a minute: they stay for walking squads)
-- (lane 48) and for a militia's march (MV) and any walk (MF), as in round 1, which gave no squad this exemption.
-- (lane 48) "held" lasts as long as the table holds the squad's men (until they are let go), not 2 s after the last
-- line: a standing squad's host sends nothing while its men stand, so the flag lapsed after 2 s and lane 38's facing
-- turn re-formed the friend's line (b2: "face30" 5.5 s after the militia stopped, its centre 6.5 m off for 7 s)
-- (lane 48) a walking squad (MV, MF) whose host sent no line for 1 s stands on the host (its men moved under 1 m):
-- held too (t1: the rival militia at the end of its muster, lane 38's face, move and aimfix took the friend's 5-8 m off)
-- (lane 52, round 3) the core asks: do this squad's men follow the host's men's own places at the native rule's pace
-- (another lord's muster or march, a host line in the last 1.5 s)? Then the core gives the squad no pace of its own.
-- (test switch, friend console: Coop.m52mus = false gives the old speed matching back)
function M.musters(lh) local t = M.heldT and M.heldT[lh]; local k = M.heldK and M.heldK[lh]; return t ~= nil and (k == "MG" or k == "MU") and os.clock() - t < 1.5 and M.paceIn == true and C.m52mus ~= false and C.m43off ~= true end
-- (lane 73) A VILLAGER TAKEN LATE INTO A MILITIA UNIT IS ARMED AS ITS SOLDIERS ARE: the safe way (the core's mirror
-- calls this; lane 52 wrote the fields there). A friend's copy closed 5 s after the fourth such man of one call-up
-- (lane 67, r1): an access violation in the game's own "play this animation" (4dee840, from the unit's tick 4de7b00).
-- Read in the game file: the unit's tick takes the ROW of its animation number from the unit's own table
-- (SMUnit.currentAnimsetDT, +DF0h; 4cc1d60) and plays the animation the row names; the name is looked up in the
-- unit's animation data (448a7e60) and the result is used unchecked: not found = -1 = a read 58h bytes before the
-- list (the dump: rax = -1, the fault address is the list's start - 58h, animation number 159). Lane 52 wrote
-- animMode = 1 and currentAnimset = "combat" but left currentAnimsetDT at the villager's work table: soldier's
-- animation numbers were then looked up in the work table. The game has no reflected function for the change
-- (SMUnit has none with "anim" or "mode" in its name; turnToSoldierJoinSquad, already called, does not do it).
-- So: the three fields are written TOGETHER and only when the table is known to be right: the reference soldier's own
-- table (ref.currentAnimsetDT) is a live object AND it is the table the engine itself gives for that set's name
-- (RTSMultiEngineCPP:getAnimsetDataTable). Table first, then the name, the mode last (the mode makes the unit ask for
-- a soldier's animations). Otherwise NOTHING is written (no training, no equipment either) and the man stays as he
-- is: the core asks again on its next pass (30 s after he was taken). Returns ok, things equipped, what was done.
-- Test switch, friend console: Coop.m73arm = false writes as lane 52 did (the probe's "old way").
function M.armLate(S, u, ref, rt, rset, rids)
  if not (valid(u) and valid(ref)) then return false, 0, "the man or the soldier is gone" end
  if C.m73arm == false then
    local n = 0
    u.meleeTraining = rt
    for s = 1, 11 do local g = rids[s]; if g and g ~= 0 and u:GetEquippedID(s) ~= g then u:equip(g, true, false); n = n + 1 end end
    u.animMode = 1; u.currentAnimset = FName(rset)
    return true, n, "the old way (mode and set name only)"
  end
  local dt = ref.currentAnimsetDT
  if not valid(dt) then return false, 0, "waits: the unit's soldier has no animation table" end
  local okE, edt = pcall(function() return S.eng:getAnimsetDataTable(FName(rset)) end)
  if not (okE and valid(edt)) then return false, 0, "waits: the game has no animation table for the set " .. tostring(rset) end
  if edt:GetAddress() ~= dt:GetAddress() then return false, 0, "waits: the soldier's animation table is not the game's table for the set " .. tostring(rset) end
  local n = 0
  u.meleeTraining = rt
  for s = 1, 11 do local g = rids[s]; if g and g ~= 0 and u:GetEquippedID(s) ~= g then u:equip(g, true, false); n = n + 1 end end
  u.currentAnimsetDT = dt; u.currentAnimset = FName(rset); u.animMode = 1
  return true, n, "animation table, set and mode written together"
end
-- (lane 73) for the core and other modules on a friend: the host's clock now, and whether it is known (the MQ lines).
-- A host line's age is hostClock() minus the line's second word; this copy's own clock minus that word is off by the
-- difference of the two PCs' clocks (0.3 and 0.9 s in the first real session).
function M.hostClock() return A.now() + (M.lkOff or 0), M.lkOff ~= nil end
-- How old a host line is (seconds; wall = its second word, the host's clock), held to 0 .. cap. EVERY place of the mod
-- that needs a host line's age on a friend asks here (lane 38's mirror in coop.lua, the merchants, the fields' count):
-- "this copy's now() minus the line's clock" gave 0 on a friend whose PC clock is behind the host's and the cap on one
-- whose clock is ahead (the mirror then aimed a marching squad a whole second ahead of the host's). Until the first
-- MQ answer (and with a host that sends none) the clocks count as equal, as before.
function M.lineLag(wall, cap)
  local d = A.now() + (M.lkOff or 0) - (tonumber(wall) or 1e18)
  if d ~= d or d < 0 then return 0 end
  if cap and d > cap then return cap end
  return d
end
-- host: " link_ms=<n>" for the log line of a friend's order: the host's clock now minus the friend's clock in the line
-- (the "delay_ms" of that line) less the difference of the two clocks as that friend measured it; "" while not known
function M.linkMs(peer, stamp)
  local off = M.peerOff and M.peerOff[peer]; stamp = tonumber(stamp)
  if not (off and stamp) then return "" end
  return string.format(" link_ms=%.0f", (A.now() - stamp - off) * 1000)
end
function M.holds(lh) local t = M.heldT and M.heldT[lh]; local k = M.heldK and M.heldK[lh]; return t ~= nil and ((k ~= "MV" and k ~= "MG" and k ~= "MF") or os.clock() - t > 1.0) and C.m43off ~= true end

-- (lane 73) THE LINK'S REAL DELAY, measured on a friend and logged once a minute ("MEN link").
-- Why: the host logs "delay_ms" for a friend's order = the host's clock now minus the friend's clock in the line. In
-- the first real session that read 1020 to 1082 for one friend and about 420 for the other, and was taken for a
-- second of link delay. It was the two PCs' clocks: the same orders' answers came back to the friend 0.22 to 0.35 s
-- after it had sent them (both ways and the frames of both copies). Nothing measured the way host to friend.
--   friend  every 5 s: "MQ <this copy's clock>"; the host answers "MQ <friend's name> <that clock>". The time until
--           the answer is the round trip (this copy's clock alone). The host's clock in the answer line, against the
--           middle of the round trip, is how far the two clocks are apart (taken from the fastest answer of the minute).
--           With that, each men line's age when it comes (host's stamp to now), the longest wait between two men
--           lines while they flow, and the frames in which two or more came together (a burst).
local function median(t) if #t == 0 then return 0 end; local c = {}; for i, v in ipairs(t) do c[i] = v end; table.sort(c); return c[math.floor((#c + 1) / 2)] end
local function linkNew(clock) return { t = clock, rt = {}, age = {}, gap = 0, gapN = 0, lines = 0, bursts = 0, inFrame = 0 } end
local function linkLine(S, w)                       -- friend: a men line of the host's came
  local K = M.lk; if not K or S.replay then return end      -- (lines read again after a load of this copy alone are old)
  local now = os.clock()
  K.lines = K.lines + 1; K.inFrame = K.inFrame + 1
  if K.lastT and now - K.lastT < 3.0 then local g = now - K.lastT; if g > K.gap then K.gap = g end; if g > 0.6 then K.gapN = K.gapN + 1 end end
  K.lastT = now
  local wall = tonumber(w[2])
  if wall and M.lkOff then K.age[#K.age + 1] = (A.now() + M.lkOff - wall) * 1000 end
end
local function linkAnswer(S, w)                     -- friend: "MQ <name> <the clock this copy sent>"
  local K = M.lk; local t0, wall = tonumber(w[5]), tonumber(w[2])
  if not (K and t0 and wall) or S.replay then return end
  local rt = A.now() - t0
  if rt < 0 or rt > 30 then return end
  K.rt[#K.rt + 1] = rt * 1000
  -- the clocks' difference from the FASTEST answer of the last 5 minutes (a slow answer is lopsided: its middle is not
  -- the moment the host stamped it). The clocks drift about 80 ms an hour against each other (the first real session).
  local c = os.clock()
  if not M.lkBest or rt <= M.lkBest or c - (M.lkBestT or 0) > 300 then M.lkBest = rt; M.lkBestT = c; M.lkOff = wall - (t0 + rt / 2); M.lkRt = rt end
end
local function linkStep(S, clock)                   -- friend, every frame
  local K = M.lk; if not K then K = linkNew(clock); K.halt0 = M.halt; M.lk = K end
  if K.inFrame >= 2 then K.bursts = K.bursts + 1 end
  K.inFrame = 0
  -- (test switch, friend console: Coop.m73probe = false: no MQ lines are sent)
  -- a new session (another host, another PC's clock): what was measured before does not count; asked again at once
  if M.lkSess ~= S.startWall then M.lkSess = S.startWall; M.lkOff = nil; M.lkRt = nil; M.lkBest = nil; M.lkAskT = nil end
  -- (the clocks' difference as this copy knows it rides along: the host's log line of this copy's orders uses it)
  if C.m73probe ~= false and clock - (M.lkAskT or -10) >= 5.0 then M.lkAskT = clock; send(string.format("MQ %.3f%s", A.now(), M.lkOff and string.format(" %.3f", M.lkOff) or "")) end
  if clock - K.t < 60.0 then return end
  if #K.rt > 0 or K.lines > 0 then
    table.sort(K.rt); table.sort(K.age)
    log("MEN link, last 60 s: round trip %.0f ms (least %.0f, most %.0f; %d answers); this PC's clock is %s; the host's men lines: %d, %s; longest wait between two %.0f ms (%d over 600 ms); frames with two or more: %d",
        median(K.rt), K.rt[1] or 0, K.rt[#K.rt] or 0, #K.rt,
        M.lkOff and string.format("%.0f ms %s the host's (the host's delay_ms for this copy's orders reads that much %s)", math.abs(M.lkOff) * 1000, M.lkOff >= 0 and "behind" or "ahead of", M.lkOff >= 0 and "more" or "less") or "not compared with the host's yet",
        K.lines, #K.age > 0 and string.format("%.0f ms old as they came (most %.0f)", median(K.age), K.age[#K.age]) or "age not known",
        K.gap * 1000, K.gapN, K.bursts)
  end
  -- the men of walking squads in that minute (the native count): how often one came to a stand while the host's walked
  local h1, h0 = M.halt, K.halt0
  if h1 and h0 and (h1[2] + h1[3]) > (h0[2] + h0[3]) then
    local st, wk = h1[2] - h0[2], h1[3] - h0[3]
    log("MEN walk, last 60 s: men of walking squads came to a stand %d times while the host's walked; they stood %.1f %% of %.0f man-seconds under a fresh host line (led points %s)",
        h1[1] - h0[1], 100 * st / math.max(1, st + wk), (st + wk) / 1000, (M.leadOk and M.paceIn and C.m73lead ~= false) and "used" or "not used")
  end
  -- what the table of held men did in that minute, by reason (for the next report: live, 14 men of two squads were
  -- taken out and held again every second or two for minutes, and no log said why)
  do
    local keys = { "m43drop_order", "m43drop_left", "m43drop_death", "m43drop_release", "m43drop_gone", "m43drop_squad", "m43placed", "m43regive", "m43rehold", "m73own", "m73ownSkip", "m43nomatch" }
    local now, was, d, any = {}, K.st0 or {}, {}, false
    for i, k in ipairs(keys) do now[k] = S.stats[k] or 0; d[i] = now[k] - (was[k] or 0); if d[i] ~= 0 then any = true end end
    if any and K.st0 then
      log("MEN table, last 60 s: men let go at an order %d, left their squad %d, died %d, released by the host %d, squad gone %d (ended %d); put outright %d (given again %d); held again after an order %d; this player's orders %d (host lines from before them not taken %d); host entries with no man here %d",
          d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12])
    end
    K.st1 = now
    -- the head count of every squad the host named in that minute, here / on the host (this player's own marked *)
    local hc, bad = {}, 0
    for lh, c in pairs(M.cnt or {}) do
      if clock - c[3] < 60.0 then hc[#hc + 1] = string.format("%s%d %d/%d", (S.mine and S.mine[lh]) and "*" or "", lh, c[1], c[2]); if c[1] ~= c[2] then bad = bad + 1 end end
    end
    table.sort(hc)
    if #hc > 0 then log("MEN heads, last 60 s (squad here/host, * this player's own): %s: %s", bad == 0 and "all equal" or (bad .. " DIFFERENT"), table.concat(hc, ", ", 1, math.min(#hc, 40))) end
  end
  local last = K.lastT; local st1 = K.st1; M.lk = linkNew(clock); M.lk.lastT = last; M.lk.halt0 = M.halt; M.lk.st0 = st1
end

local function tick(S, clock)
  M.lb = 1          -- (lane 48) one squad list read again this frame (listOf)
  if S.role == "host" then
    local th = os.clock(); hook(true); sec(S, "hook", th)
    local ok, state = avail(); if ok and state == "hooked" then hostStep(S, clock) end
    local tf = os.clock(); flushCmds(); sec(S, "flush", tf)
  elseif S.role == "friend" then
    linkStep(S, clock)                                  -- (lane 73) the link's real delay, once a minute in the log
    local want = not C.hold and C.m43off ~= true
    if want ~= M.fWant then
      M.fWant = want
      if not want then forget(C.hold and "loading" or "Coop.m43off") end
    end
    hook(want)
    if want then
      local tc = os.clock(); friendCheck(S, clock); sec(S, "check", tc)
      -- (lane 48) REGO (the native piece gives a held man standing 2 m off, idle, his place again) needs the realPos
      -- offset here too; the console's test switch Coop.m48rego = false turns it off
      if M.hoffF == nil then
        for _, c in pairs(M.cache) do
          local e = c.list and c.list[1]
          if e and valid(e.u) then
            local off = M.hoffV or realPosOffset(e.u); M.hoffV = off
            M.hoffF = (off and off > 0) and true or false
            if M.hoffF then cmd(string.format("MEN HEREAT %X", off)); log("MEN: held men given their places again when they stand 2 m off (realPos at +%X)", off) end
            break
          end
        end
      end
      local rg = C.m48rego ~= false
      if rg ~= M.regoSaid then M.regoSaid = rg; cmd(rg and "MEN REGO ON" or "MEN REGO OFF") end
      -- (lane 52, round 2) the native pace floor and the kept way: on; the console's test switches turn them off
      local pc = C.m52pace ~= false
      if pc ~= M.paceSaid then M.paceSaid = pc; cmd(pc and "MEN PACE ON" or "MEN PACE OFF") end
      local kp = C.m52keep ~= false
      if kp ~= M.keepSaid then M.keepSaid = kp; cmd(kp and "MEN KEEP ON" or "MEN KEEP OFF") end
      local ct = C.m52catch ~= false
      if ct ~= M.catchSaid then M.catchSaid = ct; cmd(ct and "MEN CATCH ON" or "MEN CATCH OFF") end
      -- the host's places that came in this frame, one SET (men dropped since: left out)
      if M.pend and #M.pend > 0 then
        local keep = {}
        for _, x in ipairs(M.pend) do local a = x:match("^(%x+)="); if a and M.held[a] then keep[#keep + 1] = x end end
        -- (lane 48) men put outright in this frame: out of the native table first, so the SET gives them a GO
        if M.regive then local dl = {}; for a in pairs(M.regive) do if M.held[a] then dl[#dl + 1] = a end end; M.regive = nil; if #dl > 0 then sendMen("DROP", dl); stat(S, "m43regive", #dl) end end
        if #keep > 0 then sendMen("SET", keep) end
      end
    end
    -- no DLL tick of its own: the patch module's own tick of this frame (or the next) runs the SET and the drops (an
    -- extra tick runs every native item's tick: round 2's first run, friend ticks up to 72 ms). A GO a frame later
    -- reads a man checked in the frame before (and by the DLL itself: committed, vtable in the module).
    M.pend = nil; M.needTick = nil
    local ts = os.clock(); flushCmds(); sec(S, "set", ts)
  end
end

local function onMessage(S, from, kind, w)
  if kind == "MQ" then
    -- (lane 73) the link's delay: the host answers a friend's question with the friend's own clock; the friend reads it
    if S.role == "host" and from ~= "host" and tonumber(w[4]) then
      send("MQ " .. tostring(from) .. " " .. w[4])
      M.peerOff = M.peerOff or {}; M.peerOff[from] = tonumber(w[5])      -- (host clock minus that friend's)
    elseif S.role == "friend" and from == "host" and w[4] == S.name then linkAnswer(S, w) end
    return true
  end
  if kind ~= "MX" then return false end
  if S.role ~= "friend" or from ~= "host" then return true end
  linkLine(S, w)
  M.curWall = tonumber(w[2])                           -- (lane 73) the host's clock in this line (onMM: this player's own order)
  local t0 = os.clock()
  for k = 4, #w do
    local kd, hs, ns, rest = w[k]:match("^(%u%u)/(%-?%d+)/(%d+)/(.*)$")
    if kd then M.onSquad(S, kd, { nil, nil, kd, hs, ns, rest }) end
  end
  local us = math.floor((os.clock() - t0) * 1e6)
  stat(S, "m43us", us); if us > (S.stats.m43maxMsg or 0) then S.stats.m43maxMsg = us end
  return true
end
function M.onSquad(S, kind, w)
  local lh = A.toLocal(tonumber(w[4]))
  if kind == "MR" then if lh then dropSquad(lh, "release") end
  elseif kind == "MF" and C.m43off == "ways" then
    -- (test) Coop.m43off = "ways": the walking squads' men are this copy's game's own (items 1 and 3 only)
    if lh and not M.relW[lh] then M.relW[lh] = true; dropSquad(lh, "ways") end
  else
    if lh then M.relW[lh] = nil end
    onMM(S, w, kind)
  end
end
-- the cost in the frame (test numbers): m43us = microseconds in this module, m43ticks = its ticks, m43max = the longest
-- tick (os.clock counts in 1 ms steps on this build), m43over2ms = ticks of 2 ms or more
local function timedTick(S, clock)
  local t0 = os.clock()
  tick(S, clock)
  local us = math.floor((os.clock() - t0) * 1e6)
  stat(S, "m43us", us); stat(S, "m43ticks")
  if us > (S.stats.m43max or 0) then S.stats.m43max = us end
  if us >= 2000 then stat(S, "m43over2ms") end
end

C.register("men", { onWorld = function(S) forget("a world was loaded"); reset() end, tick = timedTick, onMessage = onMessage })
return "coop_x_men loaded"
