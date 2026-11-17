-- Manor Lords Co-op: joining and repair (plug-in module "join").
-- A copy is brought to the host's world by loading a save the host makes. Two ways:
--
--   SINGLE (the default since lane 15): only the copy that differs, or the player that joins, loads. The host saves
--   WITHOUT pausing and does not load; nobody else sees anything. The sequence:
--     host    J MARK <id>                                 written in the same call as the game's save request: the place
--                                                         in the host's line file that the save belongs to
--     host    J LOAD <save> <level> <friend,friend> <id>  when the game says "saving finished"; only the named friends load
--     friend  (loads; when its world is up) reads the host's line file again from the MARK, so everything the host
--             did and sent while this copy loaded is applied in order (coop.lua: rewind, S.replay), then
--     friend  J READY <save> <id>
--     host    sends every pushed value complete again (keyframes of all modules)
--   Why this works (lane 15 report, research/2026-11-10-game-probe/lanes/lane_s21_15/report.txt): the game takes the
--   save's state inside the request call (measured: a change made one frame later is not in the save), squad numbers
--   and the order of families survive a load, and a save plus the lines after its MARK are the host's state now.
--
--   ALL (the old way; the fallback, and "resync = all" in coop.cfg): the host pauses, saves, tells everyone, and every
--   copy (the host too) loads that save, so all copies start from the same world.
--     host    J SYNCING, J LOAD <save> <level>, (every copy loads), friends J READY <save>, host J GO <save>
--   The host falls back to ALL when a friend asks for a repair of the same kind again within cfg.failWindow seconds
--   after it loaded alone (it still differs), when it has loaded alone cfg.maxSingles times for one kind (or twice
--   that many times for any reason) within cfg.countWindow seconds, and when the save for a single load fails.
--
-- Friends never save: on a friend's copy every save request is blanked before the game acts on it.
--   status: save by name + finished signal, save block: proven live on one copy (README session 14, lane_j probes J2, J5)
--   status: load by name through OpenLevel: proven live (README sessions 6b, 8); the whole ALL sequence on two copies
--           and through the link: proven live (README session 14)
--   status: SINGLE: test copies on one PC only (lane 15 report); never run between two PCs
--   status: friend waiting at the main menu, automatic start on a friend's hello, hold time-out: not yet run live
-- Sending the save file to another PC is the link program's job; on one PC both copies share the save folder.
-- The Steam link (coop_steam.dll) sends the save before any line that starts "J LOAD <save>": the SINGLE line keeps
-- that start and those save names, and adds its two fields at the end.

local C = _G.Coop; local A = C.api
C.join = C.join or { n = 0 }
local J = C.join
if J.auto == nil then J.auto = false end      -- main.lua switches this on; the development console leaves it off

-- ---- settings. coop.cfg: "resync = single" (default) or "resync = all"; the HOST's setting decides.
-- Development: COOP_RESYNC=all|single in the environment wins over the file; Coop.join.cfg.single can be set while running.
J.cfg = J.cfg or {}
for k, v in pairs({
  single = true,        -- only the copy that differs (or joins) loads
  awayMax = 240.0,      -- seconds the host counts a friend as "loading alone" (no "left the game" notice, no second load for him)
  failWindow = 90.0,    -- a repair of the same kind asked again within this many seconds after a friend loaded alone: every copy loads
  maxSingles = 3,       -- this many loads alone of one friend for one kind of reason (twice as many for any reason) ...
  countWindow = 600.0,  -- ... within this many seconds: the next one is a load of every copy
}) do if J.cfg[k] == nil then J.cfg[k] = v end end
do
  local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
  local modDir = here:match("^(.*)/Scripts/[^/]*$")
  local v
  local f = modDir and io.open(modDir .. "/coop.cfg", "r")
  if f then
    for line in f:lines() do local k, x = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$"); if k == "resync" and not line:match("^%s*#") then v = x end end
    f:close()
  end
  v = os.getenv("COOP_RESYNC") or v
  if v == "all" then J.cfg.single = false elseif v == "single" then J.cfg.single = true end
end
J.q = J.q or {}; J.away = J.away or {}; J.hist = J.hist or {}

local function gi() return FindFirstOf("MLGameInstance") end
local function GS() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
local function enc(s) return (tostring(s):gsub("[^%w]", function(ch) return string.format("%%%02X", ch:byte()) end)) end

-- ---- hooks (registered from tick; callbacks only record or blank a parameter)
local function ensureHooks(S)
  _G.__coop_join_hooks = _G.__coop_join_hooks or {}
  local H = _G.__coop_join_hooks
  if H.done or (H.t and os.clock() - H.t < 2.0) then return end
  H.t = os.clock()
  local ok1 = H.block or pcall(RegisterHook, "/Script/ManorLords.PawnCPP:requestSaveFile", function(self, slot, name)
    local Jn = _G.Coop and _G.Coop.join; local S2 = _G.Coop and _G.Coop.s
    if Jn and S2 and S2.on and S2.role == "friend" then        -- a friend's copy must never write a save
      pcall(function() slot:set("") end); Jn.blocked = (Jn.blocked or 0) + 1
    end
  end)
  if ok1 then H.block = true end
  local ok2 = H.thumb or pcall(RegisterHook, "/Script/ManorLords.MLGameInstance:ExportSaveThumbnailRT", function(self, wc, rt, nameP)
    local S2 = _G.Coop and _G.Coop.s
    if S2 and S2.on and S2.role == "friend" then pcall(function() nameP:set("") end) end
  end)
  if ok2 then H.thumb = true end
  local ok3 = H.fin or pcall(RegisterHook, "/Script/ManorLords.PawnCPP:onSavingFinished", function(self, slot, idx, success)
    local Jn = _G.Coop and _G.Coop.join; if not Jn then return end
    local s, okS = "?", false
    pcall(function() s = slot:get():ToString() end); pcall(function() okS = success:get() end)
    Jn.finished = { name = s, ok = okS, t = os.clock() }
  end)
  if ok3 then H.fin = true end
  if H.block and H.thumb and H.fin then H.done = true; A.log("join hooks registered") end
end

local function levelOf(name)
  local level = "Mission01_ROBBER"
  pcall(function()
    local d = StaticFindObject("/Script/ManorLords.Default__IoHandler"):LoadGameFromSlot(name .. "_descr")
    local l = d.levelName:ToString(); if l ~= "" then level = l end
  end)
  return level
end

-- works with or without a world: at the main menu there is no lord, so the game instance is the context object
local function loadSave(S, name, level)
  J.loading = { name = name, t = os.clock() }; J.lastLoaded = name
  if C.men and C.men.loadBegins then pcall(C.men.loadBegins) end   -- (lane 43) the native table of held men empties now
  C.hold = true                                   -- ignore the host's state until the new world is up (and, when every copy loads, until the host says go)
  S.replay = nil
  local g = gi(); if not A.valid(g) then A.log("join: no game instance, cannot load"); J.loading = nil; return end
  if A.valid(S.p1) then pcall(function() S.p1:ClosePauseMenu() end) end
  g.savefileToLoad = name
  GS():OpenLevel(g, FName(level), true, "")
  A.log("loading %s into %s", name, level)
end

-- Host: every copy loads (the old way). Console: Coop.join.begin(). It is the fallback of the single load.
function J.begin()
  local S = C.s; if not S or S.role ~= "host" then return "only the host can start a join" end
  if J.state then return "already busy: " .. J.state end
  if not A.valid(S.p1) then return "the host has no game loaded" end
  J.n = (J.n % 3) + 1; J.name = "coop_join_" .. J.n                 -- three rotating names keep the game's write cache small
  -- the game comes back from a load at speed 1 and running: remember how the players had it, to put it back after "go"
  J.before = { paused = A.isPaused(), speed = tonumber(S.eng.gameSpeed) or 1.0 }
  if J.before.speed <= 0.001 then J.before.speed = 1.0 end
  if C.notify then C.notify("syncing", "Syncing with the host") end
  A.send("J SYNCING")
  A.setPaused(true)
  J.finished = nil; J.ready = {}; J.t = os.clock(); J.state = "saving"; J.want = nil; J.lastBegin = os.clock()
  J.q = {}                                                          -- whoever waited for a load of his own is served by this one
  if C.scrubQuests then pcall(C.scrubQuests, S) end                 -- the save reads every quest's regions without a null check (crash guard 2)
  local ok = S.p1:requestSaveFile(J.name, J.name)
  A.log("join: saving as %s (accepted %s); every copy will load it", J.name, tostring(ok))
  if not ok then J.state = nil; return "the game refused to save" end
  return "saving as " .. J.name
end

-- ---- SINGLE, host side
-- everything the host pushes goes out complete on the modules' next scans (a friend has just come out of a load).
-- When every copy loads, the host's own load does this (each module starts afresh in a new world); here the host
-- did not load, so each module's "send again" switch is set by hand.
local function keyframes()
  if C.world and C.world.keyframe then pcall(C.world.keyframe) end              -- stock, treasury, timers, weather, the wide sample
  if C.facts and C.facts.keyframe then pcall(C.facts.keyframe) end              -- every building's values, livestock, family marks
  if C.realm then C.realm.tKey = -1e9 end                                       -- perks, taxes, policies, names, family lists
  if C.lord then C.lord.tKey = -1e9 end                                         -- wars
  local E = C.events; if E then E.tKey = -1e9; E.tKeyK = -1e9; E.tKeyO = -1e9; E.tKeyP = -1e9 end   -- quests, camps, region owners, people
  if C.people then C.people.tKeyB = -1e9 end                                    -- the rival lords' buildings
  if C.sites then C.sites.last = nil end                                        -- the list of unfinished sites
  if C.scene and C.scene.keyframe then pcall(C.scene.keyframe) end              -- lane 41: every building's drawn pieces, every cart
end
J.keyframes = keyframes

local function queued(p) return J.away[p] or J.q[p] or (J.one and J.one.targets[p]) end

-- why this friend's next load must be a load of every copy (nil: he may load alone)
-- The kind of a reason. A bandit camp is a cause of its own, named by its place (the same camp cannot fall twice):
-- the whole reason is its kind. Every other reason counts by its first word (fingerprint, families, realm, refused,
-- settled, test ...): "the daily comparison still differs" is the same kind whichever numbers it names.
local function reasonKind(r) r = tostring(r); if r:sub(1, 11) == "bandit_camp" then return r end; return r:match("^[^_:]+") or r end
local function singleFailed(p, reason, clock)
  local H = J.hist[p]; if not H then return nil end
  local kind = reasonKind(reason)
  if H.lastEnd and H.lastKind == kind and clock - H.lastEnd < J.cfg.failWindow then return string.format("he still differs %.0f s after he loaded alone for the same kind of reason", clock - H.lastEnd) end
  local same, all = 0, 0
  for _, e in ipairs(H.ends) do if clock - e.t < J.cfg.countWindow then all = all + 1; if e.kind == kind then same = same + 1 end end end
  if same >= J.cfg.maxSingles then return string.format("he has loaded alone %d times for this kind of reason in the last %.0f s", same, J.cfg.countWindow) end
  if all >= 2 * J.cfg.maxSingles then return string.format("he has loaded alone %d times in the last %.0f s", all, J.cfg.countWindow) end
end

-- the host saves while the game runs: no pause, no notice, no load of its own
local function beginOne(S, clock)
  if J.state or not A.valid(S.p1) then return end
  local used = {}; for _, a in pairs(J.away) do used[a.name] = true end
  local name
  for _ = 1, 3 do J.n = (J.n % 3) + 1; if not used["coop_join_" .. J.n] then name = "coop_join_" .. J.n; break end end
  if not name then return end                                       -- all three save names are being loaded by somebody: wait
  J.seq = (J.seq or 0) + 1
  local id = string.format("%d-%d", math.floor(S.startWall or 0) % 1000000, J.seq)   -- never the same twice, also after the host started again
  J.one = { id = id, name = name, targets = J.q, t = clock }; J.q = {}
  J.finished = nil; J.t = clock; J.state = "saving1"; J.lastOne = clock
  if C.scrubQuests then pcall(C.scrubQuests, S) end                 -- (crash guard 2)
  -- The save holds the game's state of this very call. The MARK line must be the last line before it: what was sent
  -- before the MARK is in the save, what is sent after it is not, and the loading friend reads on from the MARK.
  A.send("J MARK " .. id)
  local ok = S.p1:requestSaveFile(name, name)
  local who = {}; for p in pairs(J.one.targets) do who[#who + 1] = p end; table.sort(who)
  A.log("join: saving as %s while the game runs (accepted %s), for %s alone", name, tostring(ok), table.concat(who, ", "))
  if not ok then
    A.log("join: the game refused the save for a single load: every copy will load instead")
    J.state = nil; J.one = nil; J.want = true
  end
end

local function hostTick(S, clock)
  -- every copy loads: not while a friend is loading alone (he would be told to load in the middle of a load)
  if J.want and not J.state and next(J.away) == nil and clock - (J.lastBegin or -100) > 20.0 then J.begin() end
  local Rs = J.restore
  if Rs and not J.state then
    if clock - Rs.t > 12.0 or Rs.n >= 2 then J.restore = nil
    elseif clock - Rs.t > 0.5 and not A.isPaused() and math.abs((tonumber(S.eng.gameSpeed) or 1.0) - 1.0) < 0.02 then
      S.p1:setGameSpeed(Rs.speed); Rs.n = Rs.n + 1
      A.log("join: the game went back to speed 1 after the load; set %.1f again", Rs.speed)
    end
  end
  -- SINGLE: friends that wait for a load of their own
  if next(J.q) ~= nil and not J.state and not J.want then beginOne(S, clock) end
  if J.state == "saving1" then
    local O = J.one
    if J.finished and J.finished.name == O.name then
      J.state = nil; J.one = nil
      if not J.finished.ok then
        A.log("join: the save for a single load failed: every copy will load instead"); J.want = true
      else
        local names = {}; for p in pairs(O.targets) do names[#names + 1] = p end; table.sort(names)
        A.send(string.format("J LOAD %s %s %s %s", O.name, levelOf(O.name), table.concat(names, ","), O.id))
        for _, p in ipairs(names) do
          local q = O.targets[p]
          J.away[p] = { id = O.id, name = O.name, t = clock, asked = q.t or clock, reason = q.reason, join = q.join }
        end
        A.log("join: saved in %.2f s without stopping the game; %s load(s) %s alone, this copy and the others play on", clock - O.t, table.concat(names, ", "), O.name)
      end
    elseif clock - O.t > 15.0 then
      A.log("join: the save for a single load timed out: every copy will load instead"); J.state = nil; J.one = nil; J.want = true
    end
  end
  -- a friend that loads alone cannot say "still here" while he loads: he is not "gone" (the core's 10 s rule), until
  -- cfg.awayMax seconds have passed
  for p, a in pairs(J.away) do
    if clock - a.t > J.cfg.awayMax then
      J.away[p] = nil
      A.log("join: %s has not come back %.0f s after he was told to load alone: no longer waited for", p, clock - a.t)
    elseif S.heard then S.heard[p] = os.clock() end
  end
  if J.state == "saving" then
    if J.finished and J.finished.name == J.name then
      if not J.finished.ok then A.log("join: save failed"); J.state = nil; return end
      J.level = levelOf(J.name)
      A.send(string.format("J LOAD %s %s", J.name, J.level))
      A.log("join: saved in %.2f s, told friends, reloading", clock - J.t)
      J.state = "loading"; J.t = clock
      loadSave(S, J.name, J.level)
    elseif clock - J.t > 15.0 then A.log("join: save timed out"); J.state = nil end
  elseif J.state == "waiting" then
    local all = true
    -- a friend's load can take minutes (first session between two PCs: over 60 s, and the old 60 s limit started the
    -- game without that friend). Wait up to 5 minutes; a friend who is gone from the Steam lobby is not waited for.
    local gone = {}
    if clock - J.t > 15.0 and C.steam and C.steam.status then
      local ok, st = pcall(C.steam.status)
      if ok and type(st) == "table" and st.state == "hosting" then
        local here = {}
        for _, pl in ipairs(st.players or {}) do if pl.slot and pl.slot >= 1 and pl.state ~= "disconnected" then here["friend" .. pl.slot] = true end end
        for _, peer in ipairs(S.peers) do if not here[peer] then gone[peer] = true end end
      end
    end
    for _, peer in ipairs(S.peers) do if J.expect and J.expect[peer] and not J.ready[peer] and not gone[peer] then all = false end end
    if all or clock - J.t > 300.0 then
      A.send("J GO " .. J.name)
      -- the load took about 10 s with no heartbeat from anyone: start the "has left" clock afresh, or every resync ends with a false "left the game" notice (session 20)
      if S.heard then for p in pairs(S.heard) do S.heard[p] = os.clock() end end
      C.hold = false
      local B = J.before or { paused = false, speed = 1.0 }
      if B.paused then A.setPaused(true)
      else
        A.setPaused(false)
        if B.speed > 0 and math.abs((tonumber(S.eng.gameSpeed) or 1.0) - B.speed) > 0.02 then S.p1:setGameSpeed(B.speed) end
      end
      -- the game itself puts the speed back to 1 a few seconds after a load (seen on the host, session 17): put the
      -- players' speed back when that happens, at most twice, within 12 s
      J.restore = (not B.paused and B.speed > 0 and math.abs(B.speed - 1.0) > 0.02) and { speed = B.speed, t = clock, n = 0 } or nil
      J.lastGo = os.clock()
      J.hist = {}; J.away = {}                           -- every copy has the same world again: the single loads before it no longer count
      A.log("join: go (%s), back to %s", all and "all friends ready" or "timed out waiting for a friend", B.paused and "paused" or ("speed " .. B.speed))
      local came = false; for _, peer in ipairs(S.peers) do if J.ready[peer] then came = true end end
      if J.joiner and not came then J.joiner = nil; if C.notify then C.notify("synced", "The player did not finish joining") end
      elseif J.joiner then                               -- this resync brought a player in: say so on every copy
        local text = J.joiner .. " joined the game"
        A.send("J NOTE " .. enc(text))
        if C.notify then C.notify("joined", text) end
        J.joiner = nil
      elseif C.notify then C.notify("synced", "Synced") end
      -- friends dropped every state line while they were loading: send everything again now (session 17: a friend
      -- otherwise waited up to 30 s for the host's treasury number)
      if C.world and C.world.keyframe then pcall(C.world.keyframe) end
      if C.realm then C.realm.tKey = -1e9 end
      J.state = nil
    end
  end
end

-- Repair: a copy that knows it differs from the host asks for the host's world (a load of its own, or of every copy:
-- the host decides). Used when the host refused an action this copy already showed, and by the other modules when
-- their comparison fails (daily comparison, families, a bandit camp, a lord's value).
-- A request made within 30 s after the last one is not dropped (it used to be): it is kept and sent when the 30 s
-- are over, unless this copy has loaded a save in between.
function J.requestRepair(reason)
  local S = C.s; if not S or not S.on then return end
  if S.role == "host" then J.want = true; return end
  if os.clock() - (J.repairT or -100) < 30.0 then J.repairLater = tostring(reason); return end
  J.repairT = os.clock(); J.repairLater = nil
  A.send("J REPAIR " .. tostring(reason):gsub("%s+", "_"))
  A.log("join: asked the host for a repair (%s)", tostring(reason))
end
C.onDrift = function(reason) J.requestRepair(reason) end

local function friendHello(S, clock)
  -- say hello at start, and again every 10 s for as long as nothing has arrived from the host (the host may start later)
  local quiet = (S.stats.states or 0) == 0 and not J.loading and not C.hold
  if J.helloFor ~= S or (quiet and clock - (J.helloT or 0) > 10.0) then J.helloFor = S; J.helloT = clock; A.send("J HELLO " .. tostring(C.version)) end
  -- a lost "go" must not leave this copy deaf for ever
  if C.hold and J.holdT and clock - J.holdT > 90.0 then C.hold = false; J.holdT = nil; A.log("join: no go from the host after 90 s, listening again") end
end

local M = {}

function M.onWorld(S)
  -- (lane 27) The host loaded a world that the mod did not ask for (the player loaded another save from the menu)
  -- while friends are connected: every copy loads the host's new world, the way a join does (J.begin: the host saves
  -- it, every copy loads that save). The host's first world of a session is not such a change: nobody had another one.
  if S.role == "host" and not J.loading then
    -- "in" = heard from since the host's previous world was attached (however long the host then sat in the load
    -- menu: the first version asked for the last 60 s, and a host who chose a save for longer was not covered)
    local here = false
    for _, p in ipairs(S.peers or {}) do if S.heard and S.heard[p] and S.heard[p] >= (J.hostWorldT or math.huge) then here = true end end
    if J.hostWorlds and here then
      A.log("join: the host loaded another world (world %d) while friends are in: every copy will load it", S.worlds)
      J.want = true; J.lastBegin = -100; J.state = nil; J.one = nil; J.q = {}; J.away = {}
    end
    J.hostWorlds = (J.hostWorlds or 0) + 1; J.hostWorldT = os.clock()
  end
  if J.loading then
    local took = os.clock() - J.loading.t
    local name = J.loading.name
    local Sg = J.single
    if S.role == "host" then
      A.setPaused(true)
      J.state = "waiting"; J.t = os.clock(); J.expect = J.expect or {}
      A.log("join: host world ready after %.1f s, waiting for friends", took)
    elseif Sg and Sg.name == name then
      -- SINGLE: this copy alone loaded and the host has played on. No pause and no waiting for a "go": the host's
      -- lines since the save are read again from the save's MARK, then the live ones follow; the host's state
      -- lines set this copy's speed and pause, and its clock catches up by itself (coop.lua, the follow-speed block).
      J.single = nil
      local back = Sg.off and A.rewind and A.rewind("host", Sg.off) or nil
      if back and C.town then C.town.seenMsg = {}; C.town.seenList = {} end      -- town lines seen in the old world count again in this one
      C.hold = false; J.holdT = nil; J.helloT = os.clock(); J.repairLater = nil
      A.send(string.format("J READY %s %s", name, tostring(Sg.id)))
      if back then A.log("join: world ready after %.1f s (this copy alone loaded %s); reading again the %d bytes the host has sent since that save", took, name, back)
      else A.log("join: world ready after %.1f s (this copy alone loaded %s); the save's place in the host's lines is not known, so what the host did meanwhile is not read again: waiting for its complete values", took, name) end
      if C.notify then C.notify("synced", "Synced") end
    else
      A.setPaused(true)
      A.send("J READY " .. name); J.holdT = os.clock(); J.repairLater = nil
      A.log("join: world ready after %.1f s, told the host", took)
    end
    J.loading = nil
  end
end

-- Development only, like COOP_ROLE: COOP_TEST_REPAIR=<seconds> makes a friend's copy ask for a resync again and
-- again. It lets many resyncs run with no test console attached (session 21). Unset for players: nothing happens.
local TEST_REPAIR = tonumber(os.getenv("COOP_TEST_REPAIR") or "")
function M.tick(S, clock)
  ensureHooks(S)
  if S.role == "host" then hostTick(S, clock) else friendHello(S, clock) end
  if S.role == "friend" and J.repairLater and not C.hold and not J.loading and os.clock() - (J.repairT or -100) >= 30.0 then J.requestRepair(J.repairLater) end
  if TEST_REPAIR and S.role == "friend" and not C.hold and not J.loading and A.valid(S.p1) then
    J.testT = J.testT or clock
    if clock - J.testT > TEST_REPAIR then J.testT = clock; J.testN = (J.testN or 0) + 1; J.requestRepair("test resync " .. J.testN) end
  elseif TEST_REPAIR then J.testT = nil end
end

-- no world yet (a friend waiting at the main menu): keep saying hello so the host starts a join
function M.idle(S, clock)
  if S.role == "friend" then friendHello(S, clock) end
end

function M.onMessage(S, from, kind, w, line)
  if kind ~= "J" then return false end
  if S.role == "friend" then
    if w[4] == "MARK" and w[5] then
      -- the host is taking a save right now: remember where this line ends in the host's line file as this copy has
      -- it (every friend does, it costs nothing; the save may turn out to be for this copy)
      J.marks = J.marks or {}; J.markList = J.markList or {}
      if not J.marks[w[5]] and S.lineEnd then
        J.marks[w[5]] = S.lineEnd; J.markList[#J.markList + 1] = w[5]
        if #J.markList > 8 then J.marks[table.remove(J.markList, 1)] = nil end
      end
    elseif w[4] == "LOAD" and w[7] then
      -- SINGLE: J LOAD <save> <level> <friend,friend> <id>. Only the named friends load.
      local mine = false; for n in w[7]:gmatch("[^,]+") do if n == S.name then mine = true end end
      local id = w[8] or "?"
      J.done = J.done or {}
      if not mine then                                   -- another friend loads alone: nothing happens on this copy
      elseif J.done[id] then                             -- this line again, read after the load (the lines since the MARK): done
      elseif J.loading then A.log("join: told to load %s alone while a load is under way: ignored", tostring(w[5]))
      else
        J.done[id] = true
        J.single = { id = id, name = w[5], off = J.marks and J.marks[id] }
        if C.notify then C.notify("syncing", "Syncing with the host") end
        A.log("join: the host tells this copy to load %s alone", tostring(w[5]))
        loadSave(S, w[5], w[6] or "Mission01_ROBBER")
      end
    elseif w[4] == "LOAD" then J.single = nil; loadSave(S, w[5], w[6] or "Mission01_ROBBER")      -- every copy loads
    elseif w[4] == "SYNCING" then if C.notify then C.notify("syncing", "Syncing with the host") end
    elseif w[4] == "NOTE" and w[5] then if C.notify then C.notify("info", (w[5]:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))) end
    elseif w[4] == "GO" then
      C.hold = false; J.holdT = nil; J.helloT = os.clock()       -- the host's state follows within a moment: no new hello now (session 19: it caused a second join)
      A.log("join: go from the host"); if C.notify then C.notify("synced", "Synced") end
    end
  else
    local clock = os.clock()
    if w[4] == "READY" and w[6] ~= nil then
      -- SINGLE: J READY <save> <id>: a friend that loaded alone is back
      local a = J.away[from]
      if a and a.id == w[6] then
        J.away[from] = nil
        if S.heard then S.heard[from] = os.clock() end
        local H = J.hist[from] or { ends = {} }; J.hist[from] = H
        H.ends[#H.ends + 1] = { t = clock, kind = reasonKind(a.reason) }; H.lastEnd = clock; H.lastKind = reasonKind(a.reason)
        while #H.ends > 12 do table.remove(H.ends, 1) end
        keyframes()
        if C.announceAll then pcall(C.announceAll) end   -- a squad his load did not bring back is made on his copy
        A.log("join: %s loaded %s alone and is back %.1f s after asking (%s); every value is sent again; this copy did not pause or load", from, a.name, clock - a.asked, tostring(a.reason))
        if a.join then                                   -- a new player: say so on every copy
          local text = a.join .. " joined the game"
          A.send("J NOTE " .. enc(text))
          if C.notify then C.notify("joined", text) end
        end
      else
        keyframes()
        if C.announceAll then pcall(C.announceAll) end
        A.log("join: %s says ready for the single load %s, which this host no longer waits for: every value is sent again", from, tostring(w[6]))
      end
    elseif w[4] == "READY" and w[5] ~= nil and w[5] ~= J.name then A.log("join: %s says ready for %s, not for this join (%s): ignored", from, tostring(w[5]), tostring(J.name))
    elseif w[4] == "READY" then J.ready = J.ready or {}; J.ready[from] = true; A.log("join: %s is ready", from)
    elseif w[4] == "HELLO" and (w[5] or "?") ~= tostring(C.version) then
      -- every player must run the same build of the mod: a different one is not let in, and both sides are told
      J.badV = J.badV or {}
      if not J.badV[from] or os.clock() - J.badV[from] > 30.0 then
        J.badV[from] = os.clock()
        local who = (S.display and S.display[from]) or from
        A.log("join: %s runs mod version %s, this host runs %s: not let in", from, tostring(w[5]), tostring(C.version))
        if C.notify then C.notify("info", who .. " has a different version of the co-op mod") end
        A.send("J NOTE " .. enc("A player's co-op mod version differs from the host's"))
      end
    elseif w[4] == "HELLO" then
      J.expect = J.expect or {}; J.expect[from] = true
      local who = (S.display and S.display[from]) or from
      A.log("join: hello from %s", from)
      if J.auto and J.cfg.single then
        -- SINGLE: the new player loads alone; nobody else is stopped. A second hello while he is already queued or
        -- loading changes nothing; one that comes 15 s or more after he was told to load means he started again.
        local a = J.away[from]
        if a and clock - a.t >= 15.0 then J.away[from] = nil; a = nil end
        if not a and not (J.q[from] or (J.one and J.one.targets[from])) and J.state ~= "saving" and J.state ~= "loading" and J.state ~= "waiting" then
          local q = { reason = "join", t = clock, join = who }
          if J.state == "saving1" then J.one.targets[from] = q else J.q[from] = q end
        end
      else
        J.joiner = who                                           -- shown as "<name> joined the game" after the load
        -- a hello while this host is still saving for a join is served by that join ("load this save" has not gone out
        -- yet); only a hello that comes after it needs a join of its own (session 19: one return caused three joins)
        if J.auto and J.state ~= "saving" then J.want = true end
      end
    elseif w[4] == "REPAIR" then
      local why = J.cfg.single and singleFailed(from, tostring(w[5]), clock) or nil
      -- Several friends see the same difference in the same second and each asks. When every copy loads, the resync
      -- that the first one starts answers them all: a request that comes while one is under way, or within 15 s
      -- after it ended (still on its way from a copy that has reloaded since), starts no second one. (2026-11-12,
      -- host and three friends: every cause cost two reloads, 20 s apart.) A copy that still differs afterwards asks
      -- again: its comparison needs two game days and 75 s.
      if J.state == "saving" or J.state == "loading" or J.state == "waiting" or J.want or (J.lastGo and os.clock() - J.lastGo < 15.0) then
        A.log("join: %s asks for a repair (%s): a resync is under way or has just ended, no second one", from, tostring(w[5]))
      elseif not J.cfg.single then
        A.log("join: %s asks for a repair (%s)", from, tostring(w[5]))
        J.want = true
      elseif queued(from) then
        A.log("join: %s asks for a repair (%s): he is loading alone already", from, tostring(w[5]))
      elseif why then
        -- the fallback: the load of his own did not put him right
        A.log("join: %s asks for a repair (%s): %s, so every copy loads", from, tostring(w[5]), why)
        J.want = true
      else
        -- SINGLE: he loads alone. Friends that ask while the save is being written load the same save.
        A.log("join: %s asks for a repair (%s): he alone will load", from, tostring(w[5]))
        local q = { reason = tostring(w[5]), t = clock }
        if J.state == "saving1" then J.one.targets[from] = q else J.q[from] = q end
      end
    end
  end
  return true
end

function J.status()
  local S = C.s; if not S then return "join: not started" end
  local t = {}
  for p, a in pairs(J.away) do t[#t + 1] = string.format("%s loads %s alone since %.0f s", p, a.name, os.clock() - a.t) end
  for p in pairs(J.q) do t[#t + 1] = p .. " waits for a load of his own" end
  return string.format("join: %s, state %s%s%s", J.cfg.single and "single loads" or "every copy loads", tostring(J.state), J.want and ", a load of every copy is wanted" or "", #t > 0 and (" | " .. table.concat(t, "; ")) or "")
end

C.register("join", M)
return "coop join module loaded"
