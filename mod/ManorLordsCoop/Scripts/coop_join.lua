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
--   The host falls back to ALL (lane 63) when a friend asks again for a repair of the same kind of reason after he
--   loaded alone for it and nothing since says that load put him right, whatever the time in between: ONE failed load
--   alone is enough. "Put right" is known for the daily comparison only: the friend's REPAIR line says how many of
--   his days compared equal since his last load (eq<n>); for every other kind a second ask is a failure. Also when he
--   has loaded alone cfg.maxSingles times for one kind (or twice that many for any reason) within cfg.countWindow
--   seconds, and when the save for a single load fails. (Before lane 63 the rule was "asked again within 90 s of his
--   load". A friend's daily comparison can ask again only after his catch-up, two counted days and 75 s of the same
--   difference, so it nearly always came later than that. On the first public new game, 2026-11-17, two friends
--   alternated through six loads alone, three each; the 7th ask, his 4th, came 85 s after his load and met the 90 s
--   rule by 5 s; the count rule, 3 per friend in 600 s, would have caught that same ask.)
--
--   THE BREAKER (lane 63): when a difference of a kind is still there after every copy loaded for that kind, no more
--   loads for it: no repair of that kind for cfg.breakFirst s, then at most one load of every copy per cfg.breakEvery s.
--   The players are told once, in plain words; the host logs the ask, each friend logs its whole difference and
--   sends it to the host's log (J BREAK, J DIFF). Reason kind "test" (COOP_TEST_REPAIR) is never held by either rule.
--
--   A NEW WORLD (lane 63): a world the game GENERATED differs from the same world loaded from its save (the first
--   public new game: five buildings near the start camp had no owner on the host and the player as owner on every
--   friend, who had loaded it). So a host whose world was generated saves and loads it itself (J.begin, every copy
--   loads) cfg.freshSettle s after it is up, before any friend may load alone; the player is told why. Once per new
--   world, never for a world that was loaded.
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
  failWindow = 90.0,    -- kind "test" only (COOP_TEST_REPAIR): asked again within this many seconds after he loaded alone: every copy loads
  maxSingles = 3,       -- this many loads alone of one friend for one kind of reason (twice as many for any reason) ...
  countWindow = 600.0,  -- ... within this many seconds: the next one is a load of every copy
  breakFirst = 900.0,   -- (lane 63) the breaker: no repair of a kind that every copy's load did not fix, for this many seconds ...
  breakEvery = 3600.0,  -- ... then at most one load of every copy for it per this many seconds
  freshSettle = 10.0,   -- (lane 63) a generated world: seconds after it is up before the host saves and loads it
}) do if J.cfg[k] == nil then J.cfg[k] = v end end
local TEXT_PREP = "Preparing the new game for co-op..."
local TEXT_READY = "The new game is ready for co-op"
-- (two lines of the game's banner: in one line the 125 letters ran off both sides of the screen, lane 63 test copies)
local TEXT_BREAK = "The games differ in a way a resync cannot fix (%s). Play goes on.\nPlease send a bug report: Co-op > Make Bug Report."
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
-- (lane 63) the breaker's state, by reason kind, for this host's role: allFor = when a load of every copy that was
-- asked for because of that kind ended; brk = { t = tripped, next = the next load allowed, n = loads since }; wantKinds
-- = the kinds a wanted load of every copy is for; goKinds = those of the load under way
J.allFor = J.allFor or {}; J.brk = J.brk or {}; J.brkSaid = J.brkSaid or {}; J.wantKinds = J.wantKinds or {}

local function gi() return FindFirstOf("MLGameInstance") end
local function GS() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
local function enc(s) return (tostring(s):gsub("[^%w]", function(ch) return string.format("%%%02X", ch:byte()) end)) end
local function dec(s) return (tostring(s):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

-- (lane 81) a player's join, leave or return is told on EVERY copy, once: the host shows it and sends
--   J PN <id> <kind> <player> <text>        (id = this host's run and a number; kind "joined", "left" or "back")
-- A friend shows each id once (J.pnSeen): a friend that loads alone reads the host's lines again from the save's mark,
-- and would otherwise show the same notice twice. A friend is never told that it itself left or came back.
J.pnSeen = J.pnSeen or {}; J.pnList = J.pnList or {}
function J.tellAll(kind, who, text)
  local S = C.s; if not (S and S.role == "host") then return nil end
  J.pnRun = J.pnRun or string.format("%d", math.floor(tonumber(A.now()) or 0))
  J.pnN = (J.pnN or 0) + 1
  local id = J.pnRun .. "." .. J.pnN
  -- the player is sent by his slot ("friend1"), not by the Steam name a join path holds: a friend's log then names
  -- the slot only (lane 61's rule; the friend learns slot -> name from the text, see J.pnLine)
  local slot = who
  if S.display then for sl, nm in pairs(S.display) do if nm == who then slot = sl end end end
  A.send(string.format("J PN %s %s %s %s", id, tostring(kind), enc(slot), enc(text)))
  return id
end
function J.pnLine(S, w)
  local id, kind, who, text = w[5], w[6], dec(w[7] or ""), dec(w[8] or "")
  if not (id and kind and w[8]) then return "bad" end
  if J.pnSeen[id] then return "again" end
  J.pnSeen[id] = true; J.pnList[#J.pnList + 1] = id
  if #J.pnList > 200 then J.pnSeen[table.remove(J.pnList, 1)] = nil end
  if who == S.name and kind ~= "joined" then return "self" end
  -- the name a player sees, so that this copy's log names only the slot (C.notify writes the log through S.display)
  local nm = text:match("^(.-) left the game$") or text:match("^(.-) joined the game$") or text:match("^(.-) is back$")
  if nm and nm ~= "" and nm ~= who and who:match("^friend%d+$") then S.display = S.display or {}; S.display[who] = nm end
  if C.notify then C.notify(kind == "back" and "joined" or kind, text) end
  return "shown"
end

-- ---- hooks (registered from tick; callbacks only record or blank a parameter)
-- (lane 63) how the next world starts ("new" / "load"), stamped with the number of worlds attached so far (the core's
-- S.loads): the world it speaks for is the next one, S.loads + 1. A copy attaches a world as idle without telling the
-- modules (no onWorld), so the note cannot be handed on at a world change; it is matched by that number instead.
function J.noteStart(how)
  local S = C.s
  J.lastStart = { how = how, t = os.clock(), loads = (S and S.loads) or 0 }
end

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
  -- (lane 63) how the next world starts: the menu's own "start a new game" and "load this save" (title screen and
  -- pause menu are the same widget). Only a note of which came last; savefileToLoad is the second witness (M.onWorld).
  -- The menu's class exists only once a menu was shown: tried every 2 s, apart from the three above.
  local MW = "/Game/UI/Main_Menu/mainMenu_widget.mainMenu_widget_C:"
  if not H.ng and (H.ngTries or 0) < 600 then
    H.ngTries = (H.ngTries or 0) + 1
    H.ng = pcall(RegisterHook, MW .. "startNewGame", function() local Jn = _G.Coop and _G.Coop.join; if Jn and Jn.noteStart then Jn.noteStart("new") end end) or nil
  end
  if not H.lg and (H.lgTries or 0) < 600 then
    H.lgTries = (H.lgTries or 0) + 1
    H.lg = pcall(RegisterHook, MW .. "LoadGame", function() local Jn = _G.Coop and _G.Coop.join; if Jn and Jn.noteStart then Jn.noteStart("load") end end) or nil
  end
  if H.block and H.thumb and H.fin and not H.said then H.said = true; A.log("join hooks registered") end
  if H.ng and H.lg and not H.saidM then H.saidM = true; A.log("join: the menu's new-game and load-game hooks are registered") end
  if H.block and H.thumb and H.fin and ((H.ng and H.lg) or (H.ngTries or 0) >= 600) then H.done = true end
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
  J.loading = { name = name, t = os.clock() }; J.lastLoaded = name; J.noteStart("load")
  if C.men and C.men.loadBegins then pcall(C.men.loadBegins) end   -- (lane 43) the native table of held men empties now
  if C.visit and C.visit.beforeLoad then pcall(C.visit.beforeLoad) end   -- (lane 86) a walker leaves visit mode before the load
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
  -- (lane 63) a generated world that has not been through a load yet: this load is the one that prepares it
  -- (J.fresh ends when the host's own load is done: M.onWorld). The player was told why a moment ago (prepStep).
  if J.fresh then J.prep = true end
  if C.notify and not J.prep then C.notify("syncing", "Syncing with the host") end
  A.send("J SYNCING")
  A.setPaused(true)
  J.finished = nil; J.ready = {}; J.t = os.clock(); J.state = "saving"; J.want = nil; J.lastBegin = os.clock()
  J.goKinds = J.wantKinds or {}; J.wantKinds = {}                   -- (lane 63) the kinds of reason this load is for (the breaker)
  for _, q in pairs(J.q) do if q.join then J.joiner = q.join end end   -- a player who waited to join comes in with this load
  J.q = {}                                                          -- whoever waited for a load of his own is served by this one
  if C.scrubQuests then pcall(C.scrubQuests, S) end                 -- the save reads every quest's regions without a null check (crash guard 2)
  local ok = S.p1:requestSaveFile(J.name, J.name)
  A.log("join: saving as %s (accepted %s); every copy will load it", J.name, tostring(ok))
  if not ok then
    J.state = nil; J.wantKinds = J.goKinds or {}; J.goKinds = nil
    if not J.before.paused then A.setPaused(false) end              -- (lane 63) not left paused by a save that never began
    return "the game refused to save"
  end
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
J.reasonKind = reasonKind
-- (lane 63) did the load this friend made since he last asked for this kind put him right? The daily comparison says
-- so: eq = the friend's days that compared equal since his last load (his REPAIR line). No equal day in between: the
-- load did not fix it, however long ago it was. (For a kind the daily comparison does not cover, such as the lord's
-- settings, an equal day is taken as "put right" too; the count rule below stays the limit for those.)
local function putRight(kind, eq) return eq ~= nil and eq > 0 end
local function singleFailed(p, reason, clock, eq)
  local H = J.hist[p]; if not H then return nil end
  local kind = reasonKind(reason)
  -- ONE failed load alone of this kind is enough, whatever the time since (lane 63). Kind "test" (COOP_TEST_REPAIR)
  -- is a new cause each time by design: only the count rules below apply to it.
  local last = H.byKind and H.byKind[kind]
  if last and kind ~= "test" and not putRight(kind, eq) then
    return string.format("he still differs after he loaded alone for the same kind of reason (%s, %.0f s ago; equal days since: %s)", kind, clock - last, eq and tostring(eq) or "not known")
  end
  if last and putRight(kind, eq) then H.byKind[kind] = nil end         -- that load had put him right: a new cause
  -- kind "test" keeps the rule of before lane 63 (asked again within cfg.failWindow s of his load), so the test runs
  -- that use COOP_TEST_REPAIR go on as they did
  if kind == "test" and H.lastEnd and H.lastKind == kind and clock - H.lastEnd < J.cfg.failWindow then return string.format("he still differs %.0f s after he loaded alone for the same kind of reason", clock - H.lastEnd) end
  local same, all = 0, 0
  for _, e in ipairs(H.ends) do if clock - e.t < J.cfg.countWindow then all = all + 1; if e.kind == kind then same = same + 1 end end end
  if same >= J.cfg.maxSingles then return string.format("he has loaded alone %d times for this kind of reason in the last %.0f s", same, J.cfg.countWindow) end
  if all >= 2 * J.cfg.maxSingles then return string.format("he has loaded alone %d times in the last %.0f s", all, J.cfg.countWindow) end
end
J.singleFailed = singleFailed

-- (lane 63) words for a kind of reason, for the players' notice: the daily comparison names its sections
local FP_WORDS = { B = "buildings", C = "building sites", F = "families", O = "region owners", W = "weather", M = "merchants",
                   silver = "treasury", influence = "influence", favour = "king's favour", wealth = "regional wealth",
                   approval = "approval", order = "public order", good = "stock", soldiers = "soldiers" }
local function kindWords(kind, reason)
  if kind == "fingerprint" then
    local seen, t = {}, {}
    local list = tostring(reason):match(":_?(.*)$") or ""
    for w in list:gmatch("[^_%s]+") do
      local key = w:match("^(%a+)") or w
      local word = FP_WORDS[key] or FP_WORDS[w]
      if word and not seen[word] then seen[word] = true; t[#t + 1] = word end
    end
    return #t > 0 and table.concat(t, ", ") or "the daily comparison"
  end
  if kind:sub(1, 11) == "bandit_camp" then return "a bandit camp" end
  local words = { families = "families", realm = "the lord's settings", refused = "a refused action", settled = "a settled region" }
  return words[kind] or kind
end
J.kindWords = kindWords

-- (lane 63) the breaker trips: a difference of this kind is still there after every copy loaded for it
local function trip(S, kind, from, reason, clock)
  local B = { t = clock, next = clock + J.cfg.breakFirst, n = 0, reason = reason, from = from }
  J.brk[kind] = B
  A.log("join: THE BREAKER HOLDS %s: %s asks for a repair (%s) %.0f s after every copy loaded for this kind of reason; no repair of this kind for %.0f s, then at most one load of every copy per %.0f s",
    kind, from, tostring(reason), clock - (J.allFor[kind] or clock), J.cfg.breakFirst, J.cfg.breakEvery)
  -- every friend writes its whole difference into its log and sends it to this host's log (J DIFF); both copies log
  -- the daily comparison's building entries for 5 minutes (Coop.fpLog), so the two logs can be set side by side
  A.send("J BREAK " .. kind .. " " .. tostring(reason))
  C.fpLog = true; J.fpLogOff = os.clock() + 300.0
  if not J.brkSaid[kind] then
    J.brkSaid[kind] = true
    local text = string.format(TEXT_BREAK, kindWords(kind, reason))
    if C.notify then C.notify("info", text) end
    A.send("J NOTE " .. enc(text))
  end
end
J.trip = trip

-- (lane 63) a repair request of a kind the breaker holds: nil = not held; else what to do ("held" / "again")
local function breakerSays(kind, clock)
  local B = J.brk[kind]; if not B then return nil end
  if clock < B.next then return "held" end
  B.next = clock + J.cfg.breakEvery; B.n = B.n + 1
  return "again"
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

-- (lane 63) a generated world: the host saves and loads it itself (J.begin: every copy loads, so a friend who is
-- already waiting comes in with it). cfg.freshSettle s after the world is up the player is told why; 3 s later (the
-- game still runs, so the notice is drawn: a notice is not drawn while the game stands) the save is asked for. A save
-- the game refuses is asked for again every 5 s. J.fresh ends when the host's own load is done (M.onWorld).
local function prepStep(S, clock)
  local F = J.fresh
  if not F or J.state or J.loading or not A.valid(S.p1) then return end
  if not F.said then
    if clock - F.t < J.cfg.freshSettle then return end
    -- the notice is drawn only while the game runs: while it stands (the pause menu is open, the player paused) this
    -- waits, up to 60 s more; a friend who said hello meanwhile waits too (the Co-op panel says why: coop_ui.lua)
    local standing = false; pcall(function() standing = A.isPaused() end)
    if standing and clock - F.t < J.cfg.freshSettle + 60.0 then
      if not F.waitSaid then F.waitSaid = true; A.log("join: the new world waits for the game to run before it is prepared (the player is told then)") end
      return
    end
    F.said = clock
    A.log("join: this host's world was made by the game, not loaded from a save: it saves it and loads it once before any friend may load it alone")
    if C.notify then C.notify("syncing", TEXT_PREP) end
    return
  end
  if clock - F.said < 3.0 or clock - (F.tryT or -100) < 5.0 then return end
  F.tryT = clock; F.tries = (F.tries or 0) + 1
  local r = J.begin()
  if J.state == "saving" then A.log("join: preparing the new world for co-op: %s (try %d)", tostring(r), F.tries)
  elseif F.tries == 1 or F.tries % 12 == 0 then A.log("join: preparing the new world for co-op: %s (try %d); asked again every 5 s", tostring(r), F.tries) end
end
J.prepStep = prepStep

local function hostTick(S, clock)
  -- every copy loads: not while a friend is loading alone (he would be told to load in the middle of a load)
  if J.want and not J.state and next(J.away) == nil and clock - (J.lastBegin or -100) > 20.0 then J.begin() end
  prepStep(S, clock)
  local Rs = J.restore
  if Rs and not J.state then
    if clock - Rs.t > 12.0 or Rs.n >= 2 then J.restore = nil
    elseif clock - Rs.t > 0.5 and not A.isPaused() and math.abs((tonumber(S.eng.gameSpeed) or 1.0) - 1.0) < 0.02 then
      S.p1:setGameSpeed(Rs.speed); Rs.n = Rs.n + 1
      A.log("join: the game went back to speed 1 after the load; set %.1f again", Rs.speed)
    end
  end
  -- SINGLE: friends that wait for a load of their own
  -- (lane 63) not while a generated world waits for its first load: the friend would load the save of a world the
  -- host has not been through itself (J.begin serves him instead)
  if next(J.q) ~= nil and not J.state and not J.want and not J.fresh then beginOne(S, clock) end
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
      if not J.finished.ok then
        -- (lane 63) the game as the players had it, and the kinds of reason still wanted (a new world asks again: prepStep)
        A.log("join: save failed"); J.state = nil; J.wantKinds = J.goKinds or {}; J.goKinds = nil
        if J.before and not J.before.paused then A.setPaused(false) end
        return
      end
      J.level = levelOf(J.name)
      A.send(string.format("J LOAD %s %s", J.name, J.level))
      A.log("join: saved in %.2f s, told friends, reloading", clock - J.t)
      J.state = "loading"; J.t = clock
      loadSave(S, J.name, J.level)
    elseif clock - J.t > 15.0 then
      A.log("join: save timed out"); J.state = nil; J.wantKinds = J.goKinds or {}; J.goKinds = nil
      if J.before and not J.before.paused then A.setPaused(false) end   -- (lane 63)
    end
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
      -- (lane 63) the breaker: the kinds of reason this load of every copy was for. A friend that asks for one of them
      -- again without an equal day since is a difference this load did not fix.
      local kinds = {}
      for k in pairs(J.goKinds or {}) do J.allFor[k] = clock; kinds[#kinds + 1] = k end
      J.goKinds = nil; table.sort(kinds)
      A.log("join: go (%s), back to %s%s", all and "all friends ready" or "timed out waiting for a friend", B.paused and "paused" or ("speed " .. B.speed),
        #kinds > 0 and (" (this load was for: " .. table.concat(kinds, ", ") .. ")") or "")
      local came = false; for _, peer in ipairs(S.peers) do if J.ready[peer] then came = true end end
      local prep = J.prep; J.prep = nil
      if prep and C.notify then C.notify("synced", TEXT_READY) end
      if J.joiner and not came then J.joiner = nil; if C.notify then C.notify("synced", "The player did not finish joining") end
      elseif J.joiner then                               -- this resync brought a player in: say so on every copy
        local text = J.joiner .. " joined the game"
        J.tellAll("joined", J.joiner, text)                -- (lane 81) once on every friend (was J NOTE: an info notice)
        if C.notify then C.notify("joined", text) end
        J.joiner = nil
      elseif C.notify and not prep then C.notify("synced", "Synced") end
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
  -- (lane 63) and how many of this copy's days compared equal since its last load: the host's word for "that load
  -- put him right" (a later ask is then a new cause, not a failed load)
  local eq = math.max(0, ((S.stats and S.stats.w_fpOk) or 0) - (J.eqBase or 0))
  A.send(string.format("J REPAIR %s eq%d", (tostring(reason):gsub("%s+", "_")), eq))
  A.log("join: asked the host for a repair (%s); days equal since this copy's last load: %d", tostring(reason), eq)
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

-- (lane 63) the first world of a host role (C.setRole gives every role a new S.startWall): what the last co-op game
-- left in the breaker ends here, and was this world made by the game (a new game) or loaded from a save?
-- Two witnesses, both logged: the menu's own call that came last before the world (startNewGame / LoadGame, hooked
-- above; the mod's own loads count as "load"), and the game instance's savefileToLoad ("" for a new game: coop_ui.lua
-- sets it so before the New Game screen opens; a save's name after a load). The hook decides when it was seen.
-- the friends that said hello in THIS role (a hello of an earlier co-op game must not hold up this one's loads; one
-- of this role, also one that came before the host's world, is kept)
local function expectFor(S)
  if J.expectKey ~= S.startWall then J.expect = {}; J.expectKey = S.startWall end
  return J.expect
end
local function hostRoleBegins(S)
  J.fresh = nil; J.prep = nil; J.allFor = {}; J.brk = {}; J.brkSaid = {}; J.wantKinds = {}; J.goKinds = nil
  expectFor(S)
  local nm; pcall(function() nm = gi().savefileToLoad:ToString() end)
  -- the menu's last call counts only when it came just before THIS world (its stamp is this world's number - 1)
  local ls = J.lastStart
  local how = (ls and ls.loads == (S.loads or 0) - 1) and ls.how or nil
  local byName = (nm == "") and "new" or (nm ~= nil and "load" or nil)
  -- When the two witnesses differ, the world is prepared: a needless load of its own costs the host a few seconds,
  -- a generated world that is not prepared costs every friend a resync every few minutes (the first public new game).
  local generated = (how == "new") or (byName == "new") or (how == nil and byName == nil)
  local differ = how and byName and how ~= byName
  A.log("join: this host's first world: the menu's last call %s, the game's save name '%s'%s: %s",
    how and ("'" .. how .. "' " .. string.format("%.0f s ago", os.clock() - ls.t)) or (ls and string.format("'%s' (for world %d, this is world %d: not counted)", ls.how, (ls.loads or 0) + 1, S.loads or 0) or "not seen"),
    tostring(nm), differ and " - THE TWO DIFFER: prepared to be safe" or "",
    generated and "a world the game made (a new game): it is saved and loaded once before friends load it" or "a world loaded from a save: nothing to prepare")
  if generated then J.fresh = { t = os.clock() } end
end
J.hostRoleBegins = hostRoleBegins

function M.onWorld(S)
  if S.role == "host" and J.roleKey ~= S.startWall then
    J.roleKey = S.startWall
    if not J.loading then hostRoleBegins(S) end
  end
  if S.role == "host" and J.loading and J.fresh then
    J.fresh = nil
    A.log("join: the new world has been through a load on this host: friends may load it alone from now on")
  end
  if S.role == "friend" and J.loading then J.eqBase = (S.stats and S.stats.w_fpOk) or 0 end   -- (lane 63) equal days are counted from this load on
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
  if J.fpLogOff and os.clock() > J.fpLogOff then J.fpLogOff = nil; C.fpLog = nil end   -- (lane 63) the breaker's 5 minutes of building entries
  if S.role == "host" then hostTick(S, clock) else friendHello(S, clock) end
  if S.role == "friend" and J.repairLater and not C.hold and not J.loading and os.clock() - (J.repairT or -100) >= 30.0 then J.requestRepair(J.repairLater) end
  if TEST_REPAIR and S.role == "friend" and not C.hold and not J.loading and A.valid(S.p1) then
    J.testT = J.testT or clock
    if clock - J.testT > TEST_REPAIR then J.testT = clock; J.testN = (J.testN or 0) + 1; J.requestRepair("test resync " .. J.testN) end
  elseif TEST_REPAIR then J.testT = nil end
end

-- no world yet (a friend waiting at the main menu): keep saying hello so the host starts a join
function M.idle(S, clock)
  ensureHooks(S)                                   -- (lane 63) the menu's new-game / load-game hooks are needed at the title screen
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
    elseif w[4] == "PN" then J.pnLine(S, w)                -- (lane 81) a player joined, left or is back
    elseif w[4] == "NOTE" and w[5] then if C.notify then C.notify("info", (w[5]:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))) end
    elseif w[4] == "BREAK" and w[5] then
      -- (lane 63) the host's breaker holds a kind of reason: this copy's whole difference into this log, and to the
      -- host's log (one line, cut at 900 characters there: encoded, a line stays under 3,000); the daily comparison's
      -- building entries for 5 minutes
      local wt = C.world and C.world.diffText
      local ok, text = pcall(function() return wt and wt() or "the world module gives no difference text" end)
      text = ok and tostring(text) or ("the difference could not be read: " .. tostring(text))
      A.log("join: the host's breaker holds %s (%s): this copy's difference: %s", tostring(w[5]), tostring(w[6]), text)
      A.send(string.format("J DIFF %s %s", tostring(w[5]), enc(text:sub(1, 900))))
      C.fpLog = true; J.fpLogOff = os.clock() + 300.0
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
        local H = J.hist[from] or { ends = {}, byKind = {} }; J.hist[from] = H
        H.ends[#H.ends + 1] = { t = clock, kind = reasonKind(a.reason) }; H.lastEnd = clock; H.lastKind = reasonKind(a.reason)
        H.byKind = H.byKind or {}; H.byKind[reasonKind(a.reason)] = clock      -- (lane 63) one failed load alone of a kind is enough
        while #H.ends > 12 do table.remove(H.ends, 1) end
        keyframes()
        if C.announceAll then pcall(C.announceAll) end   -- a squad his load did not bring back is made on his copy
        A.log("join: %s loaded %s alone and is back %.1f s after asking (%s); every value is sent again; this copy did not pause or load", from, a.name, clock - a.asked, tostring(a.reason))
        if a.join then                                   -- a new player: say so on every copy
          local text = a.join .. " joined the game"
          J.tellAll("joined", a.join, text)              -- (lane 81) once on every friend
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
      expectFor(S)[from] = true
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
          -- (lane 63) a generated world not yet through a load: he waits in the queue; the host's own save and load
          -- (prepStep, a load of every copy) brings him in
          if J.fresh then A.log("join: %s waits: this new world is being prepared for co-op (the host saves and loads it first), he comes in with that load", from) end
        end
      else
        J.joiner = who                                           -- shown as "<name> joined the game" after the load
        -- a hello while this host is still saving for a join is served by that join ("load this save" has not gone out
        -- yet); only a hello that comes after it needs a join of its own (session 19: one return caused three joins)
        if J.auto and J.state ~= "saving" then J.want = true end
      end
    elseif w[4] == "DIFF" and w[5] then
      -- (lane 63) a friend's whole difference, sent when the breaker began to hold its kind
      A.log("join: the difference a resync did not fix, as %s has it (%s): %s", from, tostring(w[5]), ((w[6] or "-"):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)))
    elseif w[4] == "REPAIR" then
      local reason = tostring(w[5]); local kind = reasonKind(reason)
      local eq = tonumber((w[6] or ""):match("^eq(%d+)$"))
      if J.state == "saving" or J.state == "loading" or J.state == "waiting" or J.want or (J.lastGo and os.clock() - J.lastGo < 15.0) or queued(from) then
        -- (the old answers below)
      elseif kind ~= "test" then
        -- (lane 63) the breaker. A kind it holds gets no repair (log only, once a minute) until its time comes, then
        -- one load of every copy; a kind every copy loaded for and that this friend still asks for, without one equal
        -- day since, makes it hold.
        local says = breakerSays(kind, clock)
        if says == "held" then
          local B = J.brk[kind]
          if clock - (B.logT or -100) >= 60.0 then B.logT = clock; A.log("join: %s asks for a repair (%s): the breaker holds this kind for %.0f s more; no load", from, reason, B.next - clock) end
          return true
        elseif says == "again" then
          A.log("join: %s asks for a repair (%s): the breaker's time for this kind is up: every copy loads once more (time %d; the next in %.0f s at the earliest)", from, reason, J.brk[kind].n, J.cfg.breakEvery)
          J.want = true; J.wantKinds[kind] = true
          return true
        elseif J.allFor[kind] then
          if putRight(kind, eq) then J.allFor[kind] = nil       -- that load of every copy put him right: this is a new cause
          else trip(S, kind, from, reason, clock); return true end
        end
      end
      local why = J.cfg.single and singleFailed(from, reason, clock, eq) or nil
      -- Several friends see the same difference in the same second and each asks. When every copy loads, the resync
      -- that the first one starts answers them all: a request that comes while one is under way, or within 15 s
      -- after it ended (still on its way from a copy that has reloaded since), starts no second one. (2026-11-12,
      -- host and three friends: every cause cost two reloads, 20 s apart.) A copy that still differs afterwards asks
      -- again: its comparison needs two game days and 75 s.
      if J.state == "saving" or J.state == "loading" or J.state == "waiting" or J.want or (J.lastGo and os.clock() - J.lastGo < 15.0) then
        A.log("join: %s asks for a repair (%s): a resync is under way or has just ended, no second one", from, tostring(w[5]))
      elseif not J.cfg.single then
        A.log("join: %s asks for a repair (%s)", from, tostring(w[5]))
        J.want = true; if kind ~= "test" then J.wantKinds[kind] = true end
      elseif queued(from) then
        A.log("join: %s asks for a repair (%s): he is loading alone already", from, tostring(w[5]))
      elseif why then
        -- the fallback: the load of his own did not put him right
        A.log("join: %s asks for a repair (%s): %s, so every copy loads", from, tostring(w[5]), why)
        J.want = true; if kind ~= "test" then J.wantKinds[kind] = true end
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
  if J.fresh then t[#t + 1] = string.format("a new world waits for its first load (%d tries)", J.fresh.tries or 0) end
  for k, B in pairs(J.brk or {}) do t[#t + 1] = string.format("the breaker holds %s (%.0f s more)", k, math.max(0, B.next - os.clock())) end
  return string.format("join: %s, state %s%s%s", J.cfg.single and "single loads" or "every copy loads", tostring(J.state), J.want and ", a load of every copy is wanted" or "", #t > 0 and (" | " .. table.concat(t, "; ")) or "")
end

C.register("join", M)
return "coop join module loaded"
