-- Desk test of the job board under a slow link (lane 74, 2026-11-17). Runs WITHOUT the game:
--     py -I luarun.py <lua51.dll> run t_jobs_delay.lua <Scripts/coop_x_jobs.lua> [<the board of before>] [quiet]
-- It loads the REAL coop_x_jobs.lua twice in one Lua state (a host's board and a friend's board), each with a made-up
-- world of its own (villagers, buildings, a militia unit) and a made-up link between them that delays every line by
-- d seconds each way and hands lines over in bursts. The host ticks 60 times a second, the friend 15.
-- A militia of 36 men is called up and sent home five times from the friend and five times from the host, for
-- d = 0.15 (the real link as measured), 0.3 and 1.0 s (stress), with the squad mirror of before (2 s hands-off, then the host's older state is followed)
-- and of now (the player's own call-up or send-home waits for its echo).
-- What is a MODEL here, not the game: the villager's "think" (a given task starts 1 to 10 frames later), walking and
-- working, the host's job chooser (a free villager takes a task at his next think), the squad mirror (three rules of
-- coop.lua: the watcher's 0.3 s scan, the 2 s hands-off, follow the host's state), and the cost of a give (1.5 ms).
-- What is REAL: every line of the board on both sides, the lines it sends, and what it does with them.
-- Measured per send-home and man: when the host's man got his first task, when the friend's man had the same task,
-- how long the friend's man stood while a host line for him was here, the most gives in one friend frame.
-- Passes when, for the board given first: every man has the host's task within 3 s of the host's man plus the link's
-- delay, no man stands longer than 5 s, no task is ever given to a soldier, at most cfg.giveMax + 1 gives of host
-- lines fall into one frame.
local boardFile, beforeFile = arg and arg[1], arg and arg[2]
local quiet, trace = false, false
for i = 1, 4 do if arg and arg[i] == "quiet" then quiet = true end; if arg and arg[i] == "trace" then trace = true end end
if beforeFile == "quiet" or beforeFile == "trace" then beforeFile = nil end
if not boardFile then print("give the board: t_jobs_delay.lua <coop_x_jobs.lua> [<board of before>]"); return false end

-- ---- Lua 5.1 / LuaJIT: the 5.4 forms the board uses
if not math.tointeger then math.tointeger = function(x) x = tonumber(x); if x and x == math.floor(x) then return x end; return nil end end
table.unpack = table.unpack or unpack

-- ---- the made-up clock: os.clock() is the simulation's time plus the processor time this frame has used
local simT, cpu = 100.0, 0.0
local realClock = os.clock
os.clock = function() return simT + cpu end

local seed = 12345
local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return (math.floor(seed / 65536) % n) + 1 end

local function arr(t) return setmetatable(t or {}, { __index = { Empty = function(self) for i = #self, 1, -1 do self[i] = nil end end } }) end
local addrN = 0
local function obj(t) addrN = addrN + 16; t.addr = 0x10000000 + addrN; t._valid = true
  t.GetAddress = function(self) return self.addr end
  t.IsValid = function(self) return self._valid end
  t.IsActorBeingDestroyed = function() return false end
  return t end

-- ---- a world: one region of the player's, 12 families of 3 members (36 villagers, all militia men here: the worst
-- case), 12 villagers more who never serve, 8 buildings
local TYPES = { 25, 1, 23, 62 }
local function newWorld(name)
  local W = { name = name, units = {}, men = {}, gaveToSoldier = 0, gives = 0, givesFrame = 0, givesFrameMax = 0, log = {}, sent = 0 }
  local p1 = obj({ selectedArr = {}, Camera = { K2_GetComponentLocation = function() return { X = 0, Y = 0, Z = 5000 } end } })
  local region = obj({ ownerPawn = p1, workerFamilies = arr() })
  local eng = obj({ regions = arr({ region }), buildingArr = arr(), unitArr = arr(), disableJobIDs = arr(), gameSpeed = 1.0 })
  for b = 1, 8 do
    local B = obj({ type = 20 + b, pos = { X = 20000 + b * 2500, Y = 30000 + (b % 3) * 2000, Z = 0 } })
    B.K2_GetActorLocation = function(self) return self.pos end
    B.GetRegion = function() return region end
    B.GetType = function(self) return self.type end
    B.getJobType = function(self) return self.type end
    eng.buildingArr[b] = B
  end
  local function unit(i, man)
    local U = obj({ Tasks = arr(), Inventory = arr(), realPos = { X = 15000 + (i % 9) * 300, Y = 26000 + math.floor(i / 9) * 300, Z = 0 }, realSpeed = 0, Speed = 100, floor = 0,
                    soldier = false, dead = false, man = man, idx = i, think = 0 })
    U.isSoldier = function(self) return self.soldier end
    U.getJobType = function() return 5 end
    U.getWorkplace = function() return nil end
    U.equip = function() end; U.unequip = function() end; U.GetItemEquipmentSlot = function() return 0 end
    U.K2_SetActorLocation = function(self, p) self.realPos = { X = p.X, Y = p.Y, Z = p.Z } end
    U.setTask = function(self, rec)                       -- the game's setTask: the task before ends, this one is stored; no walk yet
      local c = {}; for k, v in pairs(rec) do c[k] = v end
      self.Tasks = arr({ c }); self.started = false; self.think = rnd(10); self.workLeft = nil
      if W.onSetTask then W.onSetTask(self, c) end
    end
    W.units[#W.units + 1] = U; eng.unitArr[#eng.unitArr + 1] = U
    if man then W.men[#W.men + 1] = U end
    return U
  end
  local n = 0
  for f = 1, 16 do
    local fam = { familyMembers = arr() }
    for j = 1, 3 do n = n + 1; local U = unit(n, f <= 12); U.key = "1." .. f .. "." .. j; fam.familyMembers[j] = U end
    region.workerFamilies[f] = fam
  end
  W.S = { role = name, name = name, eng = eng, p1 = p1, worlds = 1, loads = 1, stats = {}, on = true }
  W.eng, W.region = eng, region
  return W
end
local function identOf(rec) return tostring(rec.Type) .. "@" .. tostring(rec.targetBuilding and rec.targetBuilding.type or "-") end
-- the host's game: a free villager takes a task at his next think
local function chooserTask(W, U)
  local B = W.eng.buildingArr[rnd(8)]; local ty = TYPES[rnd(#TYPES)]
  local P = { Pos = { X = B.pos.X, Y = B.pos.Y, Z = 0 }, floor = 0, Rotation = { Pitch = 0, Yaw = 0, Roll = 0 } }
  return { Type = ty, TargetLocation = P, finalLocation = { Pos = { X = B.pos.X, Y = B.pos.Y, Z = 0 }, floor = 0, Rotation = { Pitch = 0, Yaw = 0, Roll = 0 } },
           targetEntityLocation = { X = B.pos.X, Y = B.pos.Y, Z = 0 }, resourceType = 0, resourceAmt = 0, executed = false, ID = -1, bPaidInAdvance = false, targetBuilding = B }
end
local function gameStep(W, dt, isHost)
  for _, U in ipairs(W.units) do
    U.realSpeed = 0
    if not U.soldier then
      local t = U.Tasks[1]
      if not t then
        if isHost then
          U.think = U.think - 1
          if U.think <= 0 then U.Tasks = arr({ chooserTask(W, U) }); U.started = true; U.workLeft = nil; U.think = rnd(10); if W.onHostTask then W.onHostTask(U, U.Tasks[1]) end end
        end
      else
        if not U.started then U.think = U.think - 1; if U.think <= 0 then U.started = true end end
        if U.started then
          local tp = t.TargetLocation.Pos; local dx, dy = tp.X - U.realPos.X, tp.Y - U.realPos.Y; local d = math.sqrt(dx * dx + dy * dy)
          if d > 60 then
            local step = math.min(d, 320 * dt * (U.Speed / 100)); U.realPos.X = U.realPos.X + dx / d * step; U.realPos.Y = U.realPos.Y + dy / d * step; U.realSpeed = 320
          else
            U.workLeft = (U.workLeft or (6 + rnd(10))) - dt
            if U.workLeft <= 0 then U.Tasks = arr(); U.think = rnd(10); U.workLeft = nil end
          end
        end
      end
    end
  end
end

-- ---- one run: a board file, a link delay, a mirror, who presses
local function run(file, d, mirrorNew, presser, cfgOver, scen)
  simT = 100.0; cpu = 0; seed = 777; addrN = 0
  local link = { toFriend = {}, toHost = {} }
  local BURST = 0.1                                           -- lines are handed over in bursts, ten a second
  local function due(t) return math.ceil((t + d) / BURST) * BURST end
  local sides = {}
  for _, name in ipairs({ "host", "friend" }) do
    local W = newWorld(name)
    local Cx = { modules = {}, stop = function() end, s = W.S }
    Cx.register = function(nm, m) Cx.modules[nm] = m; return m end
    Cx.patch = { jobGate = function() return true, "model" end }
    Cx.men = { held = {} }
    Cx.api = { un = function(x) return x end, valid = function(o) return o ~= nil and type(o) == "table" and o._valid ~= false end,
               log = function(fmt, ...) local ok, s = pcall(string.format, fmt, ...); W.log[#W.log + 1] = ok and s or fmt end,
               send = function(line) W.sent = W.sent + 1; local q = name == "host" and link.toFriend or link.toHost; q[#q + 1] = { t = due(simT), line = line } end,
               now = function() return 1794000000 + simT end, isPaused = function() return false end, btype = function(b) return b.type end }
    _G.Coop = Cx
    FindAllOf = function() return {} end; StaticFindObject = function() error("no such object in the model") end; FName = function(s) return s end
    local chunk = assert(loadfile(file)); chunk()
    W.C, W.J, W.mod = Cx, Cx.jobs, Cx.modules.jobs
    if cfgOver then for k, v in pairs(cfgOver) do W.J.cfg[k] = v end end
    sides[name] = W
  end
  local H, F = sides.host, sides.friend
  local function words(line) local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end; return w end
  local function deliver(q, W, from)
    local keep = {}
    for _, m in ipairs(q) do
      if m.t <= simT + 1e-9 then
        _G.Coop = W.C; W.mod.onMessage(W.S, from, "U", words("1 0 " .. m.line), m.line)
        if W.trace then local k = m.line:match("^U %a (%S+)"); if k then W.trace[k] = W.trace[k] or {}; local T = W.trace[k]; T[#T + 1] = string.format("%.2f line %s", simT, m.line:sub(1, 22)) end end
      else keep[#keep + 1] = m end
    end
    return keep
  end
  -- what is measured
  local hostTask, friendTask, homeN = {}, {}, 0               -- per man index: this send-home's first host task {t, id}; the friend's {t}
  local res = { lag = {}, idle = {}, lateMen = 0, idleMen = 0, sol = 0 }
  local frRel, hoRel = {}, {}                                 -- per man index: when he became a villager on the friend / on the host
  H.onHostTask = function(U, rec) if U.man and hoRel[U.idx] and not hostTask[U.idx] then hostTask[U.idx] = { t = simT, id = identOf(rec) } end end
  F.onSetTask = function(U, rec)
    cpu = cpu + 0.0015                                        -- the give's cost (the model)
    F.gives = F.gives + 1; F.givesFrame = F.givesFrame + 1
    if U.soldier then F.gaveToSoldier = F.gaveToSoldier + 1 end
    if F.trace then F.trace[U.key] = F.trace[U.key] or {}; local T = F.trace[U.key]; T[#T + 1] = string.format("%.2f setTask %s", simT, identOf(rec)) end
    local h = hostTask[U.idx]
    if U.man and h and not friendTask[U.idx] and identOf(rec) == h.id then friendTask[U.idx] = { t = simT } end
  end
  -- the squad on each copy, and the mirror's model
  local sq = { host = { rs = 0 }, friend = { rs = 0, hostRs = 0, orderT = -100, seenRs = 0, scanT = 0, echo = nil } }
  local stateLines, toHostOrders = {}, {}
  local function setRs(W, s, rs)
    s.rs = rs
    for _, U in ipairs(W.men) do
      U.soldier = rs ~= 0; U.Tasks = arr(); U.started = false; U.think = rnd(10)
      if rs == 0 then if W == F then frRel[U.idx] = simT else hoRel[U.idx] = simT end end
    end
  end
  local function mirrorStep()
    local s = sq.friend
    for i = #stateLines, 1, -1 do if stateLines[i].t <= simT then s.hostRs = stateLines[i].rs; table.remove(stateLines, i) end end
    if simT - s.scanT >= 0.3 then                             -- the watcher's scan: the player's own change goes to the host
      s.scanT = simT
      if s.seenRs ~= s.rs then
        if s.byPlayer then toHostOrders[#toHostOrders + 1] = { t = due(simT), rs = s.rs }; s.orderT = simT; s.echo = { rs = s.rs, t = simT }; s.byPlayer = nil end
        s.seenRs = s.rs
      end
    end
    if simT - s.orderT < 2.0 then return end                  -- the player just ordered it: hands off
    if mirrorNew and s.echo then
      if s.hostRs == s.echo.rs or s.rs ~= s.echo.rs or simT - s.echo.t > 8.0 then s.echo = nil else return end
    end
    if s.hostRs ~= s.rs and s.seenRs == s.rs and not s.pend then s.pend = { t = simT + (s.hostRs ~= 0 and 0.3 or 0.1), rs = s.hostRs } end
    if s.pend and simT >= s.pend.t then local p = s.pend; s.pend = nil; if s.rs ~= p.rs then setRs(F, s, p.rs); res.bounce = (res.bounce or 0) + ((simT - s.orderT < 6.0) and 1 or 0) end end
  end
  local hostStateT = 0
  local function hostStep()
    for i = #toHostOrders, 1, -1 do if toHostOrders[i].t <= simT then local o = table.remove(toHostOrders, i); if sq.host.rs ~= o.rs then setRs(H, sq.host, o.rs) end end end
    if simT - hostStateT >= 0.25 then hostStateT = simT; stateLines[#stateLines + 1] = { t = due(simT), rs = sq.host.rs } end
  end
  local function press(rs)
    if presser == "friend" then setRs(F, sq.friend, rs); sq.friend.byPlayer = true else setRs(H, sq.host, rs) end
  end
  local function closeHome()                                  -- the numbers of the send-home that is over
    for _, U in ipairs(H.men) do
      local i = U.idx; local h, f = hostTask[i], friendTask[i]
      if h then
        local lag = (f and f.t or simT) - h.t - d
        res.lag[#res.lag + 1] = lag
        if lag > 3.0 then
          res.lateMen = res.lateMen + 1
          if F.trace and not res.story then
            res.story = string.format("%s: villager here %.2f, on the host %.2f, the host's task %s at %.2f | %s", U.key, frRel[i] or -1, hoRel[i] or -1, h.id, h.t, table.concat(F.trace[U.key] or {}, " | "))
          end
        end
        local from = math.max(frRel[i] or h.t, h.t + d)
        local idle = (f and f.t or simT) - from
        res.idle[#res.idle + 1] = idle
        if idle > 5.0 then res.idleMen = res.idleMen + 1 end
      end
    end
    hostTask, friendTask, frRel, hoRel = {}, {}, {}, {}
    if F.trace then F.trace = {} end
  end
  if trace then F.trace = {} end
  -- the script: 6 s of plain work, then five times: call-up, 12 s, send-home, 16 s
  local plan, t = {}, 106.0
  for k = 1, 5 do plan[#plan + 1] = { t = t, rs = 1 }; plan[#plan + 1] = { t = t + 12, rs = 0 }; plan[#plan + 1] = { t = t + 28, close = true }; t = t + 28.5 end
  local endT = t + 1
  -- the two other scenes of the class (no militia): a building, and a family, that this copy gets 4 s after the host
  local sc = { starts = {}, n = 0, intime = 0, fam = {} }
  if scen then
    plan = {}; endT = 130.0
    if scen == "building" then
      local h0 = H.onHostTask
      H.onHostTask = function(U, rec) if rec.targetBuilding.type == 28 and simT < 103.5 then sc.starts[U.key] = { t = simT, id = identOf(rec) } end end
      local f0 = F.onSetTask
      F.onSetTask = function(U, rec) f0(U, rec); local s = sc.starts[U.key]; if s and not s.got and identOf(rec) == s.id then s.got = simT end end
    end
  end
  local function scene()
    if scen == "building" then
      if not sc.out then sc.out = true; sc.B = table.remove(F.eng.buildingArr, 8) end
      if sc.out and not sc.back and simT >= 104.0 then sc.back = simT; F.eng.buildingArr[8] = sc.B end
    elseif scen == "family" then
      if not sc.out then sc.out = true; sc.F = table.remove(F.region.workerFamilies, 16) end
      if sc.out and not sc.back and simT >= 104.0 then sc.back = simT; F.region.workerFamilies[16] = sc.F end
      if sc.back then
        for j = 1, 3 do
          local hu, fu = H.region.workerFamilies[16].familyMembers[j], sc.F.familyMembers[j]
          local ht, ft = hu.Tasks[1], fu.Tasks[1]
          if not sc.fam[j] and ht and ft and identOf(ht) == identOf(ft) then sc.fam[j] = simT - sc.back end
        end
      end
    end
  end
  local step, k = 0, 1
  while simT < endT do
    step = step + 1; simT = 100.0 + step / 60
    while plan[k] and simT >= plan[k].t do if plan[k].close then closeHome() else press(plan[k].rs) end; k = k + 1 end
    if scen then scene() end
    -- the host's frame (60 a second)
    cpu = 0
    hostStep(); gameStep(H, 1 / 60, true)
    link.toHost = deliver(link.toHost, H, "friend")
    _G.Coop = H.C; H.mod.tick(H.S, os.clock())
    -- the friend's frame (15 a second)
    if step % 4 == 0 then
      cpu = 0; F.givesFrame = 0
      mirrorStep(); gameStep(F, 4 / 60, false)
      link.toFriend = deliver(link.toFriend, F, "host")
      _G.Coop = F.C; F.mod.tick(F.S, os.clock())
      if F.givesFrame > F.givesFrameMax then F.givesFrameMax = F.givesFrame end
      for _, U in ipairs(F.men) do if U.soldier and U.Tasks[1] then res.sol = res.sol + 1 end end
    end
  end
  res.gaveToSoldier = F.gaveToSoldier; res.givesFrameMax = F.givesFrameMax; res.gives = F.gives; res.hostSent = H.sent; res.friendSent = F.sent
  res.log = F.log; res.errors = (F.J.n.errors or 0) + (H.J.n.errors or 0); res.lastErr = F.J.lastErr or H.J.lastErr
  res.n = F.J.n
  if scen == "building" then
    for _, s in pairs(sc.starts) do sc.n = sc.n + 1; if s.got and s.got <= sc.back + 1.5 then sc.intime = sc.intime + 1 end end
    res.scN, res.scIn = sc.n, sc.intime
  elseif scen == "family" then
    local worst = 0; for j = 1, 3 do local v = sc.fam[j] or 99; if v > worst then worst = v end end
    res.famWorst = worst
  end
  return res
end
local function stats(a)
  if #a == 0 then return 0, 0, 0 end
  table.sort(a); local s = 0; for _, v in ipairs(a) do s = s + v end
  return a[math.ceil(#a * 0.5)], a[#a], s / #a
end

local fail = 0
local function line(tag, file, d, mirrorNew, presser, check)
  local ok, r = pcall(run, file, d, mirrorNew, presser)
  if not ok then print(string.format("%-7s d=%.2f %-6s mirror %-6s: RUN ERROR %s", tag, d, presser, mirrorNew and "now" or "before", tostring(r))); fail = fail + 1; return end
  local lm, lx = stats(r.lag); local im, ix = stats(r.idle)
  local verdict = ""
  if check then
    local bad = {}
    if #r.lag < 5 * 36 then bad[#bad + 1] = "only " .. #r.lag .. " of 180 men counted" end
    if r.lateMen > 0 then bad[#bad + 1] = r.lateMen .. " men over 3 s" end
    if r.idleMen > 0 then bad[#bad + 1] = r.idleMen .. " men idle over 5 s" end
    if r.gaveToSoldier > 0 then bad[#bad + 1] = r.gaveToSoldier .. " gives to a soldier" end
    if r.sol > 0 then bad[#bad + 1] = "a soldier held a task in " .. r.sol .. " looks" end
    if r.givesFrameMax > 7 then bad[#bad + 1] = r.givesFrameMax .. " gives in one frame" end
    if r.errors > 0 then bad[#bad + 1] = r.errors .. " board errors (" .. tostring(r.lastErr) .. ")" end
    verdict = #bad == 0 and "  PASS" or ("  FAIL: " .. table.concat(bad, ", "))
    if #bad > 0 then fail = fail + 1 end
  end
  print(string.format("%-7s d=%.2f %-6s mirror %-6s: task after the host's man (less the link) median %.2f worst %.2f s; stood with a line here median %.2f worst %.2f s; over 3 s %3d, idle over 5 s %3d of %d; gives to a soldier %d; most gives in a frame %2d (%.0f ms); mirror bounces %d%s",
    tag, d, presser, mirrorNew and "now" or "before", lm, lx, im, ix, r.lateMen, r.idleMen, #r.lag, r.gaveToSoldier, r.givesFrameMax, r.givesFrameMax * 1.5, r.bounce or 0, verdict))
  if r.story then print("    a late man: " .. r.story) end
  return r
end
print("36 men, 5 call-ups and send-homes a row; host 60 frames a second, friend 15; lines in bursts of 0.1 s")
local shown = false
for _, d in ipairs({ 0.15, 0.3, 1.0 }) do
  for _, presser in ipairs({ "friend", "host" }) do
    if beforeFile then line("before", beforeFile, d, false, presser, false) end
    local r = line("now", boardFile, d, true, presser, true)
    if r and not quiet and not shown and d == 1.0 then
      shown = true
      print("  the friend's log of that row (the new lines):")
      local k = 0
      for _, l in ipairs(r.log) do if l:find("send%-home here") or l:find("call%-up here") then k = k + 1; if k <= 4 then print("    " .. l) end end end
    end
  end
end
-- the board of now with the mirror of before (the bounce still happens: the board alone must cope)
line("now", boardFile, 1.0, false, "friend", true)
-- the class's two other scenes, link 1 s each way
print("a building the friend's copy gets 4 s after the host's (the starts at it meanwhile): given within 1.5 s of its arrival")
print("a family the friend's copy gets 4 s after the host's: seconds until all three do the host's task")
for _, x in ipairs({ { "before", beforeFile }, { "now", boardFile } }) do
  if x[2] then
    local ok, r = pcall(run, x[2], 1.0, true, "host", nil, "building")
    local ok2, r2 = pcall(run, x[2], 1.0, true, "host", nil, "family")
    if not (ok and ok2) then print(x[1] .. ": RUN ERROR " .. tostring(ok and r2 or r)); fail = fail + 1
    else
      local bad = x[1] == "now" and ((r.scN > 0 and r.scIn < r.scN) or r2.famWorst > 3.0 or r.errors + r2.errors > 0)
      print(string.format("%-7s building: %d of %d starts given in time; family: %.1f s; board errors %d%s", x[1], r.scIn, r.scN, r2.famWorst, r.errors + r2.errors, x[1] == "now" and (bad and "  FAIL" or "  PASS") or ""))
      if bad then fail = fail + 1 end
    end
  end
end
os.clock = realClock
print(fail == 0 and "ALL PASS" or (fail .. " FAILED"))
return fail == 0
