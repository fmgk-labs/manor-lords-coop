-- Manor Lords Co-op: building sites finish when the host's finish (plug-in module "sites", message kind B).
-- Why: a new building, a house plot, a moved building, an upgrade, a house-plot workshop are all building jobs, and
-- each copy's own builders work on them at their own pace. Until both copies have finished a job their building
-- lists differ (a finished building here, a site there), and the daily comparison forces a resync (README session 19).
-- Rule: the host is the referee. A friend's copy never finishes a site by itself and never finishes one on a guess.
--   host   -> friends   B SITES <key;key;...>   every building of the game that is not finished on the host (sent when
--                                               it changes, every 10 s, and when a friend asks; "-" when there is none)
--   host   -> friends   B IS <key=b|s|f|n;...>  what became of a site that left the host's list, and the answer to an
--                                               ASK: built, (still a) site, burning or a ruin, no such building
--   friend -> host      B LIST                  "send your list now" (a friend's first second in a new world)
--   friend -> host      B ASK <key;key;...>     "what is this building on your copy?" (a site here that is not on the
--                                               host's list and that the host has said nothing about)
-- What a friend's copy does with one of its unfinished sites:
--   1. HELD while the host has not finished it. The hold is the native switch NOFINISH of coop_patch: the game's two
--      own calls of its finish routine are jumped over, so the builders work the site up to complete (progress 1.0,
--      the game still says "constructing") and it stays that way. Nothing of the site is written and nothing is sent.
--      This module checks every second that the switch really is on and switches it on again when it is not
--      (coop_patch sends it once when a world starts and does not look again).
--      When the switch cannot be used on this copy (native piece not loaded or switched off, the game's code not
--      found, its finish call unavailable), the site is paused shortly before its end with the game's own pause (the
--      flag of the site panel's pause button) inside the town module's quiet wrapper, so the pause is not sent to
--      anybody. Only sites this module paused itself are resumed by it; a site the player paused is left alone.
--   2. FINISHED here at once (the game's own finish routine, native: Coop.patch.finish) when the host says "built"
--      for it, and only then. That a site is missing from the host's list is never taken as "finished": the host may
--      not have it yet (this player's own placement on its way to the host), may name it differently, or it may be
--      burning there. Such a site stays held and the host is asked.
--   3. RELEASED when nothing has come from the host for 30 s: the native switch goes off and the sites this module
--      paused are resumed, so a player whose host is gone can still build. With the next list they are held again.
-- The daily comparison asks ahead() before it counts a difference in the building sections as drift.
--   status: see research/2026-11-10-game-probe/lanes/lane_s21_7/report.txt (what was exercised, how, and what was not)

local C = _G.Coop; local A = C.api
local un, valid, log = A.un, A.valid, A.log
C.sites = C.sites or {}
local B = C.sites
B.stats = B.stats or {}
for _, k in ipairs({ "sent", "finished", "failed", "held", "paused", "resumed", "switched", "asked", "told" }) do B.stats[k] = B.stats[k] or 0 end
B.cfg = B.cfg or {}
for k, v in pairs({
  poll = 1.0,            -- seconds between two looks at the sites
  rep = 10.0,            -- the host repeats its list this often
  stale = 30.0,          -- nothing from the host for this long: release every hold, do nothing
  full = 0.9995,         -- the game's progress of a site whose work is all done (it reports 1.0)
  holdAt = 0.93,         -- without the native switch: the site is paused at this progress ...
  hot = 0.75,            -- ... and looked at every frame from this progress on (measured: 2 % a second at speed 4 with
                         --     4 to 5 builders, so 0.75 to 0.93 takes several looks, and 0.93 to 1.0 many frames)
  askAfter = 3.0,        -- a site the host does not list: ask after this long ...
  askEvery = 5.0,        -- ... and again after twice this long (10 s), then every 20 s
  pauseFn = "setConstructionPaused",   -- measured (lane 7, session 3): 4 builders at work, 0 in the same frame, progress stands
                                       -- still. setSleep, the pause button's own call, writes the same flag but lets the
                                       -- builders finish what they are at (3, 2, 2, 2, 1, 0 over 5 s).
}) do if B.cfg[k] == nil then B.cfg[k] = v end end

local function bkey(b)
  local l = b:K2_GetActorLocation()
  return string.format("%d@%d,%d", A.btype(b), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5))
end

-- what a building is on this copy: "b" built, "s" an unfinished site, "f" burning or a ruin (never a site: lane_f)
local function stateOf(b)
  local ok, built = pcall(function() return b.Data.constructed end)
  if not ok then return nil end
  local fire = false; pcall(function() fire = (b.onFire and true or false) or b:IsRubble() end)
  if fire then return "f" end
  return built == false and "s" or "b"
end

-- every building that is a real site and not finished: { key = building }. Every building the game has not finished
-- counts, whatever it still needs: a site waiting for goods, a free building waiting for work, one whose fire was put
-- out. (Things the game never finishes, such as resource spots, are simply on both lists for ever.)
-- With asks = { key = true } it also says what each asked building is on this copy: { key = "b" | "s" | "f" }.
local function sites(S, asks)
  local t, ans = {}, asks and {} or nil
  -- (lane 47, round two) with the native building table (coop_snap.lua) only the buildings it shows unbuilt are read
  -- (live, as below); a finished one costs no read of the game. A site that appeared in the last 0.1 s (the table's
  -- age) waits for the next pass. Asked buildings are all read live as before.
  local N = rawget(C, "snap"); local recs = (not asks) and N and N.buildings and N.buildings()
  if recs then
    for _, r in ipairs(recs) do
      if not r.cons then
        local b = N.obj(r)
        if b and valid(b) then
          local ok, built = pcall(function() return b.Data.constructed end)
          if ok and built == false then
            local okK, k = pcall(bkey, b)
            if okK and stateOf(b) == "s" then t[k] = b end
          end
        end
      end
    end
    return t, ans
  end
  local arr = S.eng.buildingArr
  for i = 1, #arr do
    local b = un(arr[i])
    if valid(b) then
      local ok, built = pcall(function() return b.Data.constructed end)
      if ok and (built == false or asks) then
        local okK, k = pcall(bkey, b)
        if okK then
          local st = (built == false or asks[k]) and stateOf(b) or nil
          if st == "s" then t[k] = b end
          if asks and asks[k] and st then ans[k] = st end
        end
      end
    end
  end
  return t, ans
end

local function progress(b) local ok, v = pcall(function() return b:getConstructionProgress() end); return ok and tonumber(v) or 0 end
local function asleep(b) local ok, v = pcall(function() return b.sleep end); return ok and v == true end

-- the game's own site pause on this copy only: inside the town module's quiet wrapper its hooks do not report it
local function setPaused(b, on)
  local T = C.town
  if not (T and T.quiet) then return false, "the town module is not loaded" end
  return pcall(T.quiet, function() b[B.cfg.pauseFn](b, on) end)
end
local function pause(clock, k, b, p)
  local ok, e = setPaused(b, true)
  if ok and asleep(b) then
    if not B.mine[k] then
      B.stats.paused = B.stats.paused + 1
      log("sites: %s is nearly complete here (%.0f %%) and not finished on the host: paused here until the host's is", k, p * 100)
    end
    B.mine[k] = b; B.held[k] = B.held[k] or { t = clock, how = "paused" }
  elseif not B.pauseErr then
    B.pauseErr = true; log("sites: %s could not be paused here (%s)", k, tostring(e))
  end
end
local function resume(k, b, why)
  B.mine[k] = nil
  if not valid(b) or not asleep(b) then return end
  local ok, e = setPaused(b, false)
  B.stats.resumed = B.stats.resumed + 1
  log("sites: %s resumed here (%s)%s", k, why, ok and "" or (": " .. tostring(e)))
end

local function fresh(S)
  if B.S == S and B.world == S.worlds then return end
  -- sites this module paused in the world that ends: resumed when they are still there (a change of role, not a load)
  -- (lane 59) only when the SAME world is attached again (C.setRole; the core's S.loads did not move). After a load the sites of the world
  -- before are gone: they are forgotten, never called (resume read b.sleep and called setConstructionPaused on them)
  if B.loadN == S.loads then for k, b in pairs(B.mine or {}) do resume(k, b, "this world ended") end end
  B.S = S; B.world = S.worlds; B.loadN = S.loads
  B.last = nil; B.lastT = 0; B.tPoll = 0; B.warned = nil
  B.prev = nil; B.asks = nil                                 -- host: the sites of the last look, what friends asked
  B.host = nil; B.heard = false; B.hostT = os.clock()        -- friend: the host's list; "last heard" starts with the world
  B.done = {}; B.retry = {}; B.unknown = {}; B.here = {}     -- friend: "built" said by the host / next try / not listed / the sites of the last look
  B.held = {}; B.mine = {}; B.hot = {}                       -- friend, holds: seen complete / paused by this module / near the end
  B.nat = nil; B.natBad = nil; B.natSaid = nil; B.swSince = nil; B.swT = nil; B.offByUs = nil; B.staleSaid = nil; B.asked = nil; B.pauseErr = nil
end

local function hostPoll(S, clock)
  local asks = B.asks; B.asks = nil
  local t, ans = sites(S, asks)
  -- a site that left the list since the last look: say what became of it ("built": the friends finish theirs now)
  local is, any = {}, false
  for k, b in pairs(B.prev or {}) do
    if not t[k] then is[k] = valid(b) and stateOf(b) or "n"; any = true end
  end
  B.prev = t
  for k in pairs(asks or {}) do if not is[k] then is[k] = ans[k] or "n"; any = true end end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local line = #keys == 0 and "-" or table.concat(keys, ";")
  if line ~= B.last or clock - B.lastT >= B.cfg.rep then
    B.last = line; B.lastT = clock
    A.send("B SITES " .. line); B.stats.sent = B.stats.sent + 1
  end
  if any then
    local o = {}
    for k, st in pairs(is) do o[#o + 1] = k .. "=" .. st end
    table.sort(o)
    A.send("B IS " .. table.concat(o, ";")); B.stats.told = B.stats.told + #o
  end
end

-- The native switch as it really is on this copy: "on", "off", or nil and why it cannot be used. The third value says
-- that a part of it is on although it cannot be used (then it must go off, or a site could never be finished here).
local function native()
  local P = C.patch
  if not (P and P.fn and P.status and P.send and P.finish) then return nil, "the native piece is not loaded", false end
  local ok, st = pcall(P.status)
  if not ok or type(st) ~= "table" then return nil, "the native piece's status cannot be read", false end
  local a, b = st.items and st.items.NF1, st.items and st.items.NF2
  local partOn = ((a and a.state == "on") or (b and b.state == "on")) and true or false
  if st.state ~= "ready" then return nil, "the native piece reports " .. tostring(st.state) .. " " .. tostring(st.reason or ""), partOn end
  if not st.finish then return nil, "the native finish call is not available: " .. tostring(st.finishWhy or "?"), partOn end
  if not (a and b) then return nil, "the native piece does not report the switch", partOn end
  if a.state == "on" and b.state == "on" then return "on" end
  if a.state == "off" and b.state == "off" then return "off" end
  return nil, "the game's finish calls were not found (NF1 " .. tostring(a.state) .. ", NF2 " .. tostring(b.state) .. ")", partOn
end
local function switch(clock, on)
  B.swT = clock
  pcall(function() C.patch.send(on and "NOFINISH ON" or "NOFINISH OFF"); C.patch.tick() end)
  B.stats.switched = B.stats.switched + 1
end

-- the host said "built" for this site: finish it here
local function finishHere(clock, k, b)
  B.retry[k] = clock + 10.0                                      -- one try, then leave it alone for a while
  if B.mine[k] then resume(k, b, "the host's is finished") end
  local P = C.patch
  local can = false; pcall(function() can = P.fn and P.finish and P.status().finish and true or false end)
  if can then
    local ok, done, msg = pcall(P.finish, b)
    if ok and done then
      B.stats.finished = B.stats.finished + 1
      local h = B.held[k]
      log("sites: %s is finished on the host: finished here%s", k, h and string.format(" (it waited %.0f s, %s)", clock - h.t, h.how) or "")
      B.held[k] = nil
    else B.stats.failed = B.stats.failed + 1; log("sites: %s could not be finished here (%s)", k, tostring(ok and msg or done)) end
  else
    B.retry[k] = clock + 60.0
    if not B.warned then B.warned = true; log("sites: %s is finished on the host but the native finish call cannot be used on this copy: its own builders finish it", k) end
  end
end

local function friendPoll(S, clock)
  local cfg = B.cfg
  local stale = clock - B.hostT > cfg.stale
  local nat, why, partOn = native()
  B.nat = nat
  if nat then
    B.natBad = nil
    -- the switch follows the host's list: on while the host is heard, off when it is not. coop_patch switches it on
    -- itself when a world starts and its command needs a moment to show in the status; only a switch that has been
    -- wrong for 3 s is corrected here (with 1 s a busy PC logged a false "was off" at a world's start: lane 7, session 7).
    local want = stale and "off" or "on"
    if nat == want then B.swSince = nil
    else
      B.swSince = B.swSince or clock
      if clock - B.swSince >= 3.0 and clock - (B.swT or -10) >= 3.0 then
        switch(clock, want == "on")
        if want == "on" and not B.offByUs then log("sites: the native switch was off on this copy: switched on (this copy's builders must not finish a site by themselves)") end
        B.offByUs = (want == "off") or nil
      end
    end
  else
    B.natBad = B.natBad or clock
    if B.natSaid ~= why then B.natSaid = why; log("sites: the native switch cannot be used on this copy (%s): a site that is nearly complete is paused here instead until the host's is finished", tostring(why)) end
    if partOn and clock - (B.swT or -10) >= 3.0 then switch(clock, false) end      -- or nothing could ever finish such a site here
  end
  if stale then
    if not B.staleSaid then B.staleSaid = true; log("sites: nothing from the host for %.0f s: every hold is released (this copy's builders finish their sites again), nothing is finished from here", cfg.stale) end
    for k, b in pairs(B.mine) do resume(k, b, "nothing from the host") end
    B.held = {}; B.hot = {}
    return
  end
  if B.staleSaid then B.staleSaid = nil; log("sites: the host's list is back: sites are held again") end
  if not B.asked then B.asked = true; A.send("B LIST") end       -- a new world: the host's list now, not within 10 s
  local list = B.host or {}
  local mine = sites(S)
  local hot, ask = {}, nil
  for k, b in pairs(mine) do
    if B.done[k] then
      if clock >= (B.retry[k] or 0) then finishHere(clock, k, b) end
    else
      if list[k] or not B.heard then B.unknown[k] = nil
      else
        -- not on the host's list and the host has not said "built": the host may not have it yet, may name it
        -- differently, or it may be burning there. Never finished on a guess: the host is asked.
        local u = B.unknown[k]; if not u then u = { t = clock, asked = -1e9, every = cfg.askEvery }; B.unknown[k] = u end
        if clock - u.t >= cfg.askAfter and clock - u.asked >= u.every then
          u.asked = clock; u.every = math.min(20.0, u.every * 2)       -- then 10 s, then every 20 s: a building the host does not have is not asked about for ever at full pace,
                                                                        -- and an answer that got lost (the link was down) is asked for again within 20 s
          ask = ask or {}; ask[#ask + 1] = k
        end
      end
      local p = progress(b)
      if nat == "on" then
        if B.mine[k] then resume(k, b, "the native switch is on again") end
        if p >= cfg.full and not B.held[k] and not asleep(b) then
          B.held[k] = { t = clock, how = "complete" }; B.stats.held = B.stats.held + 1
          log("sites: %s is complete here and not finished on the host: it waits for the host's", k)
        end
      elseif not nat and clock - B.natBad >= 2.0 then
        if p >= cfg.holdAt then if not asleep(b) then pause(clock, k, b, p) end
        elseif p >= cfg.hot then hot[k] = b end
      end
    end
  end
  B.hot = hot; B.here = mine
  if ask then table.sort(ask); A.send("B ASK " .. table.concat(ask, ";")); B.stats.asked = B.stats.asked + #ask end
  -- forget what is no longer a site here (finished, demolished, on fire)
  for _, t in ipairs({ B.held, B.mine, B.unknown, B.done, B.retry }) do for k in pairs(t) do if not mine[k] then t[k] = nil end end end
end

local M = {}
function M.onWorld(S) fresh(S) end
function M.tick(S, clock)
  fresh(S)
  if C.hold then return end
  -- without the native switch: a site near its end is looked at every frame, so it is paused before the last blow
  if S.role == "friend" and not B.nat and next(B.hot) then
    for k, b in pairs(B.hot) do
      if not valid(b) then B.hot[k] = nil
      else local p = progress(b); if p >= B.cfg.holdAt then B.hot[k] = nil; if not asleep(b) then pause(clock, k, b, p) end end end
    end
  end
  if clock - B.tPoll < B.cfg.poll then return end
  B.tPoll = clock
  local ok, e = pcall(S.role == "host" and hostPoll or friendPoll, S, clock)
  if not ok then B.lastErr = tostring(e) end
end
-- this copy is no longer in a co-op game: the sites this module paused are resumed
function M.idle(S, clock)
  -- (lane 59) with no world attached (the title screen, a level loading) the paused sites went with their world
  if B.mine and next(B.mine) then if S and S.eng and B.loadN == S.loads then for k, b in pairs(B.mine) do resume(k, b, "the co-op game ended") end end; B.mine = {} end
end
function M.onMessage(S, from, kind, w, line)
  if kind ~= "B" then return false end
  fresh(S)
  local what = w[4]
  if S.role == "friend" then
    if what == "SITES" then
      local set = {}
      if w[5] and w[5] ~= "-" then for k in w[5]:gmatch("[^;]+") do set[k] = true end end
      B.host = set; B.hostT = os.clock(); B.heard = true
    elseif what == "IS" and w[5] then
      for k, st in w[5]:gmatch("([^;=]+)=(%a)") do
        local u = B.unknown[k]
        -- "built" counts only for a building that was a site here at the last look (a later site of the same name is another job)
        if st == "b" and B.here[k] then
          B.done[k] = true
          if u then log("sites: %s is not on the host's list; asked: it is finished on the host", k) end
        elseif st == "n" and u and not u.said then
          u.said = true
          log("sites: %s is a site here but the host has no such building: it waits (this player's own placement that the host has not made, or a building named differently on the two copies)", k)
        end
      end
    end
  elseif S.role == "host" then
    if what == "ASK" and w[5] then B.asks = B.asks or {}; for k in w[5]:gmatch("[^;]+") do B.asks[k] = true end
    elseif what == "LIST" then B.last = nil end
  end
  return true
end

-- How many of the PLAYER's buildings on this copy differ from the host's in the building sections for a reason this
-- module knows: finished here while the host still lists them as sites (only possible while the native switch was
-- off), and sites this module paused itself (the pause flag is part of the comparison). The daily comparison asks
-- this before it counts a difference in the building sections as drift. Other lords' buildings are not counted: the
-- comparison does not look at them, and they differ by design (a rival lord's upgrade happens on the host only; in
-- session 2 of lane 7 such a building made this number 1 and hid a real difference for three days).
function B.ahead(S)
  if not B.host or os.clock() - (B.hostT or 0) > B.cfg.stale then return 0 end
  local me = nil; pcall(function() me = S.p1:GetAddress() end)
  local function own(b) local ok, r = pcall(function() local o = b.ownerPawn; return valid(o) and o:GetAddress() == me end); return ok and r end
  local n = 0
  local arr = S.eng.buildingArr
  for i = 1, #arr do
    local b = un(arr[i])
    if valid(b) then
      local ok, built = pcall(function() return b.Data.constructed end)
      if ok and built == true then local okK, k = pcall(bkey, b); if okK and B.host[k] and own(b) then n = n + 1 end end
    end
  end
  for _, b in pairs(B.mine or {}) do if valid(b) and asleep(b) and own(b) then n = n + 1 end end
  return n
end

local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
function B.status()
  local st = B.stats
  return string.format("sites: host list %d, sent %d, finished here %d, failed %d, complete and waiting %d, paused here %d, not listed %d, switch %s, switched %d, asked %d, told %d, last error %s",
    count(B.host), st.sent, st.finished, st.failed, count(B.held) - count(B.mine), count(B.mine), count(B.unknown), tostring(B.nat or B.natSaid), st.switched, st.asked, st.told, tostring(B.lastErr))
end

B.S = nil                 -- this file was loaded (again): the module starts from nothing with the next tick
C.register("sites", M)
return "coop sites module loaded"
