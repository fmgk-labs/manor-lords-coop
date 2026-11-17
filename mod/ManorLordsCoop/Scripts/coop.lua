-- Manor Lords Co-op core (development build).
-- Rules (see research/.../lanes/lane_n/threading.txt):
--   * exactly one driver, on the game thread (LoopInGameThreadAfterFrames); never LoopAsync / ExecuteAsync
--   * hook callbacks only set a flag; all work happens in the driver's tick
--   * every squad read is guarded by IsValidSquad; every unit by IsValid
-- Roles: "host" (referee: applies friends' orders, sends state) and "friend" (sends own orders, follows the host).
-- Link (development): text files in a shared folder, one per player. The real link replaces send()/recv() only.

local C = rawget(_G, "Coop") or {}
_G.Coop = C
C.version = "0.2.2"

-- where the link files live: set by main.lua to "<this mod's folder>/link/"; the development console uses the probe's folder
local LINK = rawget(_G, "COOP_LINK_DIR")
if not LINK then      -- main.lua always sets it; this is the same default (the "link" folder beside Scripts), never a fixed path
  local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
  LINK = (here:match("^(.*)/Scripts/[^/]*$") or ".") .. "/link/"
end
local HALT, SPRINT, SPREAD, SHIELDWALL, RAIDING = 8, 9, 4, 2, 19
local FLEEING = 3
local ENCAMPED = 4                      -- Squad.Control 4: a bandit camp's squad holds its camp

-- ---------------------------------------------------------------- small helpers
-- (lane 45) un and valid call plain functions through pcall: a closure made at every call was garbage for the
-- collector at every array element and every validity check of every module (the two rows were 1.6 ms a frame in the
-- b0 profile, most of it the reflected calls themselves)
local function getOf(x) return x:get() end
local function isValidOf(o) return o:IsValid() end
local function un(x) local ok, v = pcall(getOf, x); if ok and v ~= nil then return v end; return x end
-- (lane 45) the engine and the player's lord, once checked at the start of this copy's tick (objs), count as valid
-- for the rest of that tick (every module asked again each frame); cleared when the tick ends (hooks run between ticks)
local FR = { p1 = false, eng = false }
local function valid(o) if o == nil then return false end; if o == FR.p1 or o == FR.eng then return true end; local ok, r = pcall(isValidOf, o); return ok and r == true end
local function now() return (C.clk or 0) + os.clock() end
C.leftSilence = C.leftSilence or 30.0   -- (lane 51) s of silence after which the host tells that a friend left (host tick)
local function far(ax, ay, bx, by, tol) return math.abs(ax - bx) > tol or math.abs(ay - by) > tol end
local function words(line) local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end; return w end

-- The log file lives in the link folder. On the very first start after unzipping, that folder may not exist yet for
-- a few seconds (session 21: the first lines of a fresh install were lost). Lines that cannot be written are kept
-- and written with the next line that can.
-- (lane 47) the log file stays open: an open, append and close cost 160 us a line (lane 47, sitting b1: x47_probe.lua
-- "chan"), a write and flush on a kept handle 5 us. Opened again every 5 s and whenever the name changes, so a file
-- that was removed or emptied elsewhere is written again as before.
local LOGF = { f = nil, path = nil, t = -1e9, size = 0 }
local function logFile(path)
  local t = os.clock()
  if LOGF.f and LOGF.path == path and t - LOGF.t < 5.0 then return LOGF.f end
  if LOGF.f then pcall(io.close, LOGF.f); LOGF.f = nil; LOGF.path = nil end
  local f = io.open(path, "ab")
  if f then LOGF.f, LOGF.path, LOGF.t = f, path, t; LOGF.size = f:seek("end") or 0 end    -- (lane 61) the size, for the cap
  return f
end
C.logClose = function() if LOGF.f then pcall(io.close, LOGF.f) end; LOGF.f = nil; LOGF.path = nil end

-- (lane 61) SESSIONS. A session is one run of the game (this process). Each name this copy writes a log under (idle,
-- host, friend1 ...) is turned over the first time this run writes it: the file an earlier run left, <name>_log.txt,
-- moves to link\sessions\<name>_<the time of its first line, YYYY-MM-DD_HH-MM-SS>.txt and the newest 5 per name are kept
-- (link\sessions\<name>_index.txt lists them, oldest first). So the log of a run that crashed is still there after the
-- next start, also when this run never becomes host again. The current file keeps its name (the test scripts read
-- <name>_log.txt). The sessions folder is made by the native piece at its first tick (Lua cannot make a folder without
-- a console window): while it is missing, nothing is moved and the run goes on in the same file.
-- HEADER: a session's file starts with "session:" lines (mod version, the run and its start, role, UE4SS); the game's
-- version, the role, the players connected (a count, never names) and the save follow as "session:" lines when known.
-- SIZE CAP: past C.logCapMB (200, or COOP_LOG_CAP_MB) a session's file takes only warnings, faults and "session:" lines,
-- and once a minute a line that counts the lines left out.
-- PRIVACY: every line is scrubbed before it is written, with the rules of the native piece (native\coop_patch\
-- coop_scrub.h): a folder after \Users\ and the Windows user name after a separator become <user>, Steam display names
-- (3 letters or more) their slot ("friend 1"), a Steam id keeps its last 4 digits. Notices drop display names of any length.
local MODDIR = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")):match("^(.*)/Scripts/[^/]*$") or "."
local SESS = rawget(C, "sess") or { names = {}, keep = 5 }
C.sess = SESS
C.runT = C.runT or os.time()                                -- this run's start (the first load of this file in the process)
C.logCapMB = C.logCapMB or tonumber(os.getenv("COOP_LOG_CAP_MB") or "") or 200
C.reportLogCap = C.reportLogCap or 12 * 1048576             -- per log in a bug report: its start and its end past this (logs zip about 7:1; Discord takes 10 MB)
local function fexists(p) local f = io.open(p, "rb"); if f then f:close(); return true end; return false end
local function firstLine(p)
  local f = io.open(p, "rb"); if not f then return nil, 0 end
  local size = f:seek("end") or 0
  if size == 0 then f:close(); return nil, 0 end
  f:seek("set", 0); local l = f:read("l"); f:close()
  return l, size
end
-- a log's first line: its time (s since 1970; every line starts with it) and the run named in its header (nil before 0.2.2)
local function logStart(l)
  if not l then return nil end
  return tonumber(l:match("^(%d+)%.%d+ ") or ""), tonumber(l:match("^%S+ session: .- run (%d+)") or "")
end
local function rotate(name)
  SESS.names[name] = true
  local cur = LINK .. name .. "_log.txt"
  local l, size = firstLine(cur)
  if size == 0 then return end
  local t = logStart(l)
  if not t or t < 1000000000 then t = os.time() end
  local dir = LINK .. "sessions/"
  local base = name .. "_" .. os.date("%Y-%m-%d_%H-%M-%S", t)
  local file = base .. ".txt"
  for k = 2, 99 do if not fexists(dir .. file) then break end; file = base .. "_" .. k .. ".txt" end
  if LOGF.path == cur then C.logClose() end
  if not os.rename(cur, dir .. file) then                -- (no sessions folder): this run goes on below the last one's lines
    SESS.notMoved = name; SESS.from = SESS.from or {}; SESS.from[name] = size  -- a bug report takes this run's part only
    return
  end
  local idx, list = dir .. name .. "_index.txt", {}
  local f = io.open(idx, "rb")
  if f then
    for x in f:lines() do
      x = x:gsub("%s+$", "")
      if x ~= file and x:sub(1, #name + 1) == name .. "_" and x:match("^[%w_%-]+%.txt$") and not x:match("_index%.txt$") then list[#list + 1] = x end
    end
    f:close()
  end
  list[#list + 1] = file
  while #list > SESS.keep do os.remove(dir .. table.remove(list, 1)) end      -- only files this list named
  f = io.open(idx, "wb"); if f then f:write(table.concat(list, "\n"), "\n"); f:close() end
  SESS.moved = (SESS.moved or 0) + 1
end

-- privacy (see above)
local PRIV = { t = -10, names = {} }
local function ciPat(s)                         -- a plain text as a Lua pattern, letters in either case
  return (s:gsub("[%a%p]", function(c) if c:match("%a") then return "[" .. c:lower() .. c:upper() .. "]" end; return "%" .. c end))
end
local function userNames()
  if PRIV.users then return PRIV.users end
  local u = {}
  local function add(n) if n and n ~= "" then u[#u + 1] = { low = n:lower(), pat = "([\\/])" .. ciPat(n) } end end
  add(os.getenv("USERNAME"))
  local prof = (os.getenv("USERPROFILE") or ""):gsub("[\\/]+$", "")
  local leaf = prof:match("[\\/]([^\\/]+)$")
  if leaf and leaf:lower() ~= (os.getenv("USERNAME") or ""):lower() then add(leaf) end
  PRIV.users = u
  return u
end
local function slotName(slot) slot = tostring(slot); if slot == "0" or slot == "host" then return "host" end; return ((slot:gsub("^friend", "")):gsub("^(%d+)$", "friend %1")) end
-- Steam display names this copy knows (the host's player list, the Steam status), longest first; read at most every 2 s
local function steamNames()
  local t = os.clock()
  local S = C.s
  local disp = S and S.display
  if t - PRIV.t < 2.0 and disp == PRIV.disp then return PRIV.names end     -- (the host's list is a new table when it changes)
  PRIV.t = t; PRIV.disp = disp
  local list = {}
  if S and S.display then for slot, nm in pairs(S.display) do if type(nm) == "string" and #nm >= 3 then list[#list + 1] = { nm, slotName(slot) } end end end
  local st = rawget(C, "steam")
  if st and st.on and st.status then
    local ok, s = pcall(st.status)
    if ok and s and s.players then for _, p in ipairs(s.players) do if type(p.name) == "string" and #p.name >= 3 then list[#list + 1] = { p.name, slotName(p.slot or "?") } end end end
  end
  table.sort(list, function(a, b) return #a[1] > #b[1] end)
  for _, e in ipairs(list) do e.low = e[1]:lower(); e.pat = ciPat(e[1]); e.to = e[2]:gsub("%%", "%%%%") end
  PRIV.names = list
  return list
end
local function scrub(line)
  if line:find("[Uu][Ss][Ee][Rr][Ss][\\/]") then line = line:gsub("([\\/][Uu][Ss][Ee][Rr][Ss][\\/])[^\\/\r\n\"']+([\\/])", "%1<user>%2") end
  local low
  for _, u in ipairs(userNames()) do
    low = low or line:lower()
    if low:find(u.low, 1, true) then line = line:gsub(u.pat, "%1<user>"); low = nil end
  end
  for _, e in ipairs(steamNames()) do
    low = low or line:lower()
    if low:find(e.low, 1, true) then line = line:gsub(e.pat, e.to); low = nil end
  end
  if line:find("7656119", 1, true) then line = line:gsub("%f[%d]7656119%d%d%d%d%d%d(%d%d%d%d)%f[%D]", "<id..%1>") end
  return line
end
C.scrub = scrub
local function plainReplace(s, from, to)
  local out, i = {}, 1
  while true do
    local a, b = s:find(from, i, true)
    if not a then break end
    out[#out + 1] = s:sub(i, a - 1); out[#out + 1] = to; i = b + 1
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end

local function ue4ssVersion()
  if SESS.ue4ss then return SESS.ue4ss end
  SESS.ue4ss = "not read"
  local f = io.open(MODDIR .. "/../../UE4SS.log", "rb")
  if f then
    local head = f:read(4096) or ""; f:close()
    local v, sha = head:match("UE4SS %- (v[^\r\n]-) %- Git SHA #(%x+)")
    if v then SESS.ue4ss = v .. ", git " .. sha end
  end
  return SESS.ue4ss
end
local function header(name)
  local S = C.s
  local t = string.format("%.3f", now())
  return t .. string.format(" session: Manor Lords Co-op %s, log of %s, run %d started %s (this PC's clock)\n", C.version, name, C.runT, os.date("%Y-%m-%d %H:%M:%S", C.runT))
      .. t .. string.format(" session: role %s, game version %s, UE4SS %s, earlier logs in link\\sessions (newest %d per name), log size cap %s MB%s\n",
           tostring(S and S.role), SESS.gameVer or "read later", ue4ssVersion(), SESS.keep, tostring(C.logCapMB),
           SESS.notMoved == name and " (the last run's log could not be moved: it is above this line)" or "")
end
local KEEPW = { "error", "fail", "warn", "crash", "watchdog", "refus", "fault", "exception", "session:", "bug report" }
local function keepPastCap(line)
  local l = line:lower()
  for _, w in ipairs(KEEPW) do if l:find(w, 1, true) then return true end end
  return false
end

local function logBody(fmt, ...)
  local S = C.s; if not S then return end
  local ok, msg = pcall(string.format, fmt, ...)
  local name = S.name
  if not SESS.names[name] then pcall(rotate, name); SESS.hdr = name end      -- (lane 61) this run's first line of this name
  local line = string.format("%.3f %s\n", now(), ok and msg or fmt)
  local okS, sl = pcall(scrub, line); if okS then line = sl end
  local f = logFile(LINK .. name .. "_log.txt")
  if f then
    if SESS.hdr == name then SESS.hdr = nil; local h = header(name); f:write(h); LOGF.size = LOGF.size + #h end
    if C.early then local e = table.concat(C.early); f:write(e); LOGF.size = LOGF.size + #e; C.early = nil end
    if LOGF.size > C.logCapMB * 1048576 and not keepPastCap(line) then        -- (lane 61) the size cap
      SESS.dropped = (SESS.dropped or 0) + 1
      local t = os.clock()
      if t - (SESS.dropT or -1e9) < 60.0 then return end
      SESS.dropT = t
      line = string.format("%.3f log size cap %s MB reached: %d line(s) left out since the last such line; only warnings, faults and session lines are written\n", now(), tostring(C.logCapMB), SESS.dropped)
      SESS.dropped = 0
    end
    if not f:write(line) then C.logClose()
    else f:flush(); LOGF.size = LOGF.size + #line end
  else
    C.early = C.early or {}
    if #C.early < 300 then C.early[#C.early + 1] = line end
  end
end
-- (lane 61) a fault in the log's own steps (turnover, scrub, cap) never reaches the caller (a module's step)
local function log(fmt, ...) pcall(logBody, fmt, ...) end

local function later(dt, fn) local S = C.s; S.later[#S.later + 1] = { t = os.clock() + dt, fn = fn } end

-- ---- lane 45: what the mod costs, always on (two os.clock reads per step; no garbage). C.cost.step[name] per core step
-- and per module ("<module>" its tick, "<module>:msg" its message handling): n calls, ms in all, longest; the same
-- since the last minute line (wn, wms, wmax). C.cost.tick: the whole mod per frame. Lines and bytes sent and read, the
-- Lua heap and the collector (a tick in which the heap shrank had a collector step). A line "cost:" in the log once
-- a minute; probes read the totals (research/.../lanes/lane_s21_45/probes/x45_cost.lua).
local K = { step = {}, tick = { n = 0, ms = 0, max = 0, wn = 0, wms = 0, wmax = 0 }, over8 = 0, over16 = 0, over50 = 0, wover8 = 0,
            sN = 0, sB = 0, rN = 0, rB = 0, gcN = 0, gcMs = 0, wgcN = 0, kbMax = 0, wT = os.clock() }
C.cost = K
local function kAdd(name, ms)
  local s = K.step[name]
  if not s then s = { n = 0, ms = 0, max = 0, wn = 0, wms = 0, wmax = 0 }; K.step[name] = s end
  s.n = s.n + 1; s.ms = s.ms + ms; if ms > s.max then s.max = ms end
  s.wn = s.wn + 1; s.wms = s.wms + ms; if ms > s.wmax then s.wmax = ms end
  if ms > K.fMax and name ~= "dev" then K.fMax = ms; K.fName = name end     -- this frame's dearest step
end
K.fMax = 0; K.long = {}; K.longI = 0; K.msgName = {}
C.costAdd = kAdd                       -- modules may count their own parts ("scene:read" ...)
-- lane 45: the Lua collector in generational mode (Lua 5.4.7, the mod loader's). Nearly all of the mod's garbage
-- dies young (reflected values, places, strings of one tick: about 7 MB a second in sitting b0); a young collection
-- touches only what is new, where the incremental mode walks the whole heap (25 to 40 MB) again and again.
pcall(collectgarbage, "generational")                   -- (a Lua before 5.4 has no such mode: the call is then left)

-- Squad numbers are per-copy counters too: a squad created during a session gets a different number on each copy.
-- The host announces every new squad; each friend creates it and keeps a translation table (host number <-> local number).
-- (lane 48, round 3) a host number with no tie of its own is this copy's squad of the same number (both copies have
-- it from one save) ONLY when that local squad is not tied to another host squad and was not made here: a squad this
-- copy made (for the host, or the game made with a camp) never answers for a host number it does not carry
-- (t7: the friend's own camp squad got the number of the host's new squad). Such a number gives -1 (no squad).
local function toLocal(h)
  if not h then return h end
  local S = C.s; local l = S.h2l[h]
  if l then return l end
  if S.l2h[h] or (S.madeHere and S.madeHere[h]) then return -1 end
  return h
end
local function toHost(h) return (h and C.s.l2h[h]) or h end

-- ---------------------------------------------------------------- game objects
local function objs()
  local S = C.s
  if not valid(S.eng) then
    -- (lane 59) the world this copy was attached to is gone (or none yet): its lord, squad component and helper go
    -- with it. They were kept until the next world attached, and what runs with no world (the modules' idle steps,
    -- a join line, the host's goodbye) called them with nothing but valid() in between.
    S.p1 = nil; S.sc = nil; S.hp = nil
    S.eng = FindFirstOf("RTSMultiEngineCPP")
    if not valid(S.eng) then S.eng = nil; S.reattach = nil; S.nkOrig = nil; return nil end
    S.sc = FindFirstOf("SquadComponent")
    -- (lane 59) S.sameWorld: C.setRole attached the SAME world again (no load): its objects live on. S.loads counts
    -- the worlds that really are new ones (S.worlds also counts every attach by C.setRole): what a module keeps of a
    -- world (an object, a task record) it stamps with S.loads, and never uses under another number.
    S.sameWorld = S.reattach == true; S.reattach = nil
    if not S.sameWorld then S.loads = (S.loads or 0) + 1; S.nkOrig = nil end
    S.hp = nil; S.pawns = nil; S.pawnsT = 0; S.known = {}; S.sq = {}; S.chase = {}; S.later = {}; S.mir = {}; S.mirT = {}; S.host = {}; S.mine = {}; S.uidIndex = nil; S.h2l = {}; S.l2h = {}; S.madeHere = {}; S.campSq = nil; S.baseDone = false; S.setPaused = nil; S.setSpeed = nil; S.agree = false; S.worldT = os.clock(); S.milSeen = nil; S.mercNames = nil; S.mercGone = nil; S.freshT = nil; S.hireSent = nil; S.rmQ = nil; S.rmDone = nil; S.busyT = nil; S.rsSeen = nil; S.rmByMod = nil; S.raiseSeen = nil; S.raiseSent = nil; S.rallyQ = nil; S.rallyT = nil; S.homeT = nil; S.removing = nil      -- a fresh world: nothing set by the mod yet, so nothing the player could have changed
    S.worlds = S.worlds + 1
    local cf = io.open(LINK .. "dev_crumbs.txt", "rb"); S.crumbN = cf and 3 or 0; if cf then cf:close() end
    log("world %d attached", S.worlds)
  end
  local p1 = S.eng.playerRef
  if not valid(p1) or not valid(S.sc) then return nil end
  S.p1 = p1
  FR.eng = S.eng; FR.p1 = p1                                   -- lane 45: valid for the rest of this tick
  return S.eng, p1, S.sc
end

local function helper()
  local S = C.s
  if valid(S.hp) then return S.hp end
  local p1 = S.p1; local L = p1:K2_GetActorLocation(); local r = p1:K2_GetActorRotation()
  S.hp = p1:GetWorld():SpawnActor(p1:GetClass(), { X = L.X, Y = L.Y, Z = L.Z + 5000.0 }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll })
  C.quietHelper()
  log("helper lord created, its autosave timer stopped")
  return S.hp
end

-- The helper is a second copy of the player's lord object, so it starts its own 600 s autosave timer when created.
-- Left running, it writes the game's autosave ten minutes later (this overwrote a real save twice during development).
-- Stop it at creation and keep checking. On a friend's copy the player's own timer is stopped too: friends never save.
function C.quietHelper()
  local S = C.s; if not S then return end
  local KSL = S.KSL; if not valid(KSL) then KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"); S.KSL = KSL end
  local function stop(pawn, who)
    if valid(pawn) and KSL:K2_IsTimerActiveHandle(pawn, pawn.autosaveHandle) then
      KSL:K2_PauseTimerHandle(pawn, pawn.autosaveHandle); S.stats.autosaveStops = (S.stats.autosaveStops or 0) + 1
      log("autosave timer stopped on %s", who)
    end
  end
  stop(S.hp, "helper")
  if S.role == "friend" then stop(S.p1, "player (friend copy)") end
  -- helpers left behind by an earlier start of the mod in the same world (development reloads)
  if not S.orphanT or os.clock() - S.orphanT > 30.0 then
    S.orphanT = os.clock()
    local me = S.p1:GetAddress()
    for _, pw in ipairs(FindAllOf("MyPawnCPP_BP3_C") or {}) do if valid(pw) and pw:GetAddress() ~= me then stop(pw, "extra lord object") end end
  end
end

local function pawns()
  local S = C.s
  if not S.pawns or os.clock() - S.pawnsT > 3.0 then S.pawns = FindAllOf("PawnCPP") or {}; S.pawnsT = os.clock() end
  -- (lane 55) the list is up to 3 s old: only the lords that are alive in this frame are handed out (every caller
  -- also checks valid() itself; this keeps a new caller from touching a lord freed since the list was taken)
  local t = {}
  for _, pw in ipairs(S.pawns) do if valid(pw) then t[#t + 1] = pw end end
  return t
end

-- A death the host decided, applied on this copy. The game's own combat code marks a soldier "deathInCombat" before he
-- dies; without the mark the game books a family grief entry (static read, registry/native5/report.txt), which
-- would pull approval apart between copies. Tag append and death tried live on one soldier (README session 17).
local function hostKill(u)
  if C.men and C.men.gone then pcall(C.men.gone, u) end   -- (lane 43) out of the native table of held men before he dies
  pcall(function() local t = u.Tags; t[#t + 1] = FName("deathInCombat") end)
  u:just_die()
end

-- every squad handle in the world, and the set commanded by the local player
local function allSquads()
  local S = C.s; local list, mine = {}, {}
  local me = S.p1:GetAddress()
  for _, pw in ipairs(pawns()) do
    if valid(pw) then
      local isMe = pw:GetAddress() == me
      local arr = pw.commandedSquads
      for i = 1, #arr do local h = arr[i].Value; if h and h ~= 0 then list[#list + 1] = h; if isMe then mine[h] = true end end end
    end
  end
  S.mine = mine
  return list
end

-- ---------------------------------------------------------------- squads
local function sqValid(h) return h ~= nil and h ~= 0 and C.s.sc:IsValidSquad({ Value = h }) end

-- Paused or not. The game's own flag (PawnCPP.bIsPlayerPaused) is not enough: a click on a speed button while paused
-- starts time again and leaves the flag set (session 21, read on the host: flag true, speed 1.0, the date moving;
-- the friend followed the flag and stayed paused). Paused = the flag is set AND the speed is 0.
local function isPaused() local S = C.s; return (S.p1.bIsPlayerPaused and (tonumber(S.eng.gameSpeed) or 0) <= 0.001) and true or false end
-- Pause or un-pause with the game's own calls. A flag left set while time runs is cleared first (unPauseGame in that
-- state clears the flag and leaves the speed alone: seen live), so pauseGame then really stops time.
local function setPaused(want)
  local p1 = C.s.p1
  if want then
    if not isPaused() then
      if p1.bIsPlayerPaused then p1:unPauseGame() end
      p1:pauseGame()
    end
  elseif p1.bIsPlayerPaused then p1:unPauseGame() end
end

local function sqState(h)
  local sc = C.s.sc; local s = sc:GetSquad({ Value = h }); local sk = {}
  for i = 1, #s.activeSkills do sk[#sk + 1] = tonumber(un(s.activeSkills[i])) or -1 end
  table.sort(sk)
  return { h = h, n = sc:GetUnitCount({ Value = h }), ctl = s.Control, tgt = s.targetSquad.Value,
           tx = s.TargetLocation.X, ty = s.TargetLocation.Y, tz = s.TargetLocation.Z,
           lx = s.lastSquadTargetPosition.X, ly = s.lastSquadTargetPosition.Y, lz = s.lastSquadTargetPosition.Z,
           push = s.pushStance, behav = s.behaviourStance, sk = sk, skKey = table.concat(sk, "+"),
           cx = s.WeightedCenter.X, cy = s.WeightedCenter.Y, eng = s.isEngaged and true or false,
           rs = tonumber(s.rallyingStatus) or 0, mil = (tonumber(s.squadType) or 0) == 1, merc = (tonumber(s.squadType) or 0) == 2, ret = (tonumber(s.squadType) or 0) == 3 }, s   -- rally status (0 = at home), militia unit
end

local function unitsOf(h)
  local s = C.s.sc:GetSquad({ Value = h }); local t = {}
  for i = 1, #s.unitArr do local u = un(s.unitArr[i]); if valid(u) then t[#t + 1] = u end end
  return t, s
end

-- the lord through which an order for this squad is issued: its own lord for other lords' squads, the helper for ours
local function issuer(s)
  local op = s.ownerPawn
  if valid(op) and op:GetAddress() ~= C.s.p1:GetAddress() then return op end
  return helper()
end

local function commit(h)
  local sc = C.s.sc; if sc:GetUnitCount({ Value = h }) == 0 then return end
  local cur = sc:IsSkillActiveForSquad({ Value = h }, SPREAD)
  sc:SetSkillActive({ Value = h }, SPREAD, not cur, true); sc:SetSkillActive({ Value = h }, SPREAD, cur, true)
end

local function doMove(h, t)
  -- never order a squad that has no men: the game crashes on it (access violation reading 0x318; session 20 on a
  -- friend's copy, and again on the host when a friend's rally also sent a move for a unit still empty there)
  if C.s.sc:GetUnitCount({ Value = h }) == 0 then return end
  local s = C.s.sc:GetSquad({ Value = h }); local c = s.WeightedCenter
  local g = C.s.p1:getCurrentSquadLineProjection({ Value = h })
  local half = math.max(300.0, math.sqrt((g.A.X - g.B.X) ^ 2 + (g.A.Y - g.B.Y) ^ 2) / 2)
  local dx, dy = t.X - c.X, t.Y - c.Y; local len = math.sqrt(dx * dx + dy * dy); if len < 1 then dx, dy, len = 1, 0, 1 end
  local px, py = -dy / len, dx / len
  local a = { X = t.X - px * half, Y = t.Y - py * half, Z = t.Z }; local b = { X = t.X + px * half, Y = t.Y + py * half, Z = t.Z }
  issuer(s):formALineArmy({ { Value = h } }, { A = a, B = b }, FName("None"), { A = a, B = b }); commit(h)
end

-- a move that also pulls the squad out of a fight: halt now, move a moment later
local function moveOrder(h, t)
  local s = C.s.sc:GetSquad({ Value = h })
  if s.isEngaged or s.targetSquad.Value ~= 0 then
    C.s.sc:SetSkillActive({ Value = h }, HALT, true, true)
    later(0.08, function() if sqValid(h) then doMove(h, t) end end)
  else doMove(h, t) end
end

local function attackOrder(h, e)
  if not sqValid(h) or not sqValid(e) then return "gone" end
  local a, s = unitsOf(h); local d = unitsOf(e)
  if #a == 0 or #d == 0 then return "empty" end
  if C.attackNative and C.attackNative(h, e) == "ok" then return "ok" end   -- (lane 37) the right click's own attack (coop_x_army.lua)
  issuer(s):projectAttackFormation(a, d, true); commit(h)
  return "ok"
end

-- ---------------------------------------------------------------- link (files)
-- LINK FILE TURNOVER (lane 33, 2026-11-13). NOT RUN IN THE GAME YET: designed and checked offline only (the Steam DLL's
-- mock test; research/2026-11-10-game-probe/lanes/lane_s21_33/report.txt). The lead runs it on test copies first.
-- A player's file is a chain: <name>.txt, then <name>.2.txt, <name>.3.txt, ... When the file this copy writes is over
-- the limit, the copy makes the next file, writes "<seq> <wallclock> ~NEXT <k>" as the last line of the old one and
-- goes on in the new one. Readers (recv below, the Steam DLL) follow that line; recv never hands it to a module.
-- 30 s after a turnover the files older than the two before the current one are deleted, and <name>.txt becomes the
-- one-line pointer "0 0.000 ~NEXT <oldest file kept>", so a copy that starts reading finds the chain. A reader may so
-- be two whole files behind (8 MB at the default limit, about ten minutes at speed 8 with four friends) and lose nothing.
-- A place in a player's lines (ends[], rewind) is (file - 1) * 2^40 + offset: in the first file, the plain offset.
-- Limit: Coop.linkCut (bytes; 0 = never) if set, else COOP_LINK_CUT_MB from the environment, else 4 MB while the Steam
-- link (DLL 0.2 or later, which follows the chain) hosts or has joined a game; else never (coop-link.ps1 does not follow).
local SEGPOS, CUT_KEEP, CUT_WAIT = 1099511627776, 2, 30.0
local CUT_ENV = tonumber(os.getenv("COOP_LINK_CUT_MB") or "")
local function segFile(who, k) return LINK .. who .. ((k or 1) > 1 and ("." .. k) or "") .. ".txt" end
local function nextMark(line) local k = line:match("^%S+ %S+ ~NEXT ([1-9]%d?%d?%d?%d?%d?)$"); return k and tonumber(k) or nil end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end; return false end
local function fsize(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:seek("end"); f:close(); return s end

-- the chain on disk: the numbered files found by following the "~NEXT" lines from <who>.txt, and the newest file
local function segChain(who)
  local list, k, last = {}, 1, 1
  for _ = 1, 100000 do
    local f, nx = io.open(segFile(who, k), "rb"), nil
    if f then
      last = k; if k > 1 then list[#list + 1] = k end
      local size = f:seek("end"); f:seek("set", math.max(0, size - 120)); local tail = f:read("a") or ""; f:close()
      local ln = tail:match("\n([^\n]*)\n$") or (size <= 120 and tail:match("^([^\n]*)\n$"))
      nx = ln and nextMark((ln:gsub("\r$", "")))
      if not nx or nx <= k then break end
    else
      if k == 1 then break end
      for j = k + 1, k + 64 do if exists(segFile(who, j)) then nx = j; break end end   -- a deleted file: step over it
      if not nx then break end
    end
    k = nx
  end
  return list, last
end

-- a reader that starts at the end of a player's lines (nil when that player has no file yet)
local function readerAtEnd(who)
  local _, k = segChain(who)
  local f = io.open(segFile(who, k), "rb"); if not f then return nil end
  local R = { seg = k, off = f:seek("end"), part = "" }; f:close()
  return R
end

-- this copy starts its own lines afresh: empty <who>.txt first, then delete the numbered files (a reader whose file is
-- gone and that finds no later one then starts again at <who>.txt, as when a file gets shorter)
local function linkReset(S, who)
  local list, last = segChain(who)
  local f = io.open(segFile(who, 1), "wb"); if f then f:close() end
  for _, k in ipairs(list) do os.remove(segFile(who, k)) end
  os.remove(segFile(who, last + 1))                             -- made a moment before a crash, before its "~NEXT" line
  S.outName, S.outSeg, S.cutLow, S.cutT, S.outSize = who, 1, 1, nil, 0
  S.stale = {}; for _, k in ipairs(list) do if exists(segFile(who, k)) then S.stale[#S.stale + 1] = k end end   -- in use: tried again
  S.staleT = os.clock()
end

local function cutLimit(S)
  if S.cutLimT and os.clock() - S.cutLimT < 1.0 then return S.cutLim end
  S.cutLimT = os.clock()
  local v = tonumber(C.linkCut)
  if not v and CUT_ENV then v = math.floor(CUT_ENV * 1048576) end
  if not v then
    v = 0
    local st = rawget(C, "steam")
    if st and st.on and st.status then
      local ok, s = pcall(st.status)
      if ok and s and (s.state == "hosting" or s.state == "joined") and (tonumber(s.info and s.info.dll) or 0) >= 0.2 then v = 4 * 1048576 end
    end
  end
  S.cutLim = v
  return v
end

local function outOpen(S)
  if S.outName ~= S.name then
    -- a new name for this copy's lines (the Steam slot changed it): numbered files of that name are left from an earlier
    -- session, and a reader would follow them: start that chain afresh, as a start does
    if #segChain(S.name) > 0 then linkReset(S, S.name) end
    S.outName, S.outSeg, S.cutLow, S.cutT = S.name, 1, 1, nil
  end
  S.out = io.open(segFile(S.name, S.outSeg), "ab")
  S.outSize = S.out and S.out:seek("end") or 0
end

local function cut(S)
  local k = S.outSeg + 1
  local nf = io.open(segFile(S.name, k), "wb"); if not nf then return end      -- the next file first ...
  nf:close()
  S.seq = S.seq + 1
  S.out:write(string.format("%d %.3f ~NEXT %d\n", S.seq, now(), k)); S.out:close()   -- ... then the line pointing to it
  S.outSeg, S.cutT = k, os.clock()
  S.out = io.open(segFile(S.name, k), "ab"); S.outSize = 0
  S.stats.linkCuts = (S.stats.linkCuts or 0) + 1
  log("link: %s.txt turned over, writing %s.%d.txt from now on (lane 33 turnover, not yet run in the game before this)", S.name, S.name, k)
end

-- 30 s after the last turnover: delete the files older than the two before the current one; <name>.txt becomes the pointer
local function cleanOld(S)
  if (S.cutLow or 1) > S.outSeg - CUT_KEEP - 1 or os.clock() - S.cutT < CUT_WAIT then return end
  local was = S.cutLow or 1; S.cutLow = was
  while S.cutLow <= S.outSeg - CUT_KEEP - 1 do
    if S.cutLow >= 2 then local p = segFile(S.outName, S.cutLow); if exists(p) and not os.remove(p) then break end end
    S.cutLow = S.cutLow + 1
  end
  if S.cutLow ~= was then local f = io.open(segFile(S.outName, 1), "wb"); if f then f:write(string.format("0 0.000 ~NEXT %d\n", S.cutLow)); f:close() end end
end

local function send(line)
  local S = C.s
  if not S.out then outOpen(S) end
  if not S.out then return end
  S.seq = S.seq + 1
  local text = string.format("%d %.3f %s\n", S.seq, now(), line)
  S.out:write(text); S.out:flush(); S.stats.sent = S.stats.sent + 1
  S.outSize = (S.outSize or 0) + #text
  K.sN = K.sN + 1; K.sB = K.sB + #text                       -- lane 45
  local lim = cutLimit(S)
  if lim > 0 and S.outSize >= lim then cut(S) end
  if S.cutT and S.out then cleanOld(S) end
  if S.stale and #S.stale > 0 and os.clock() - (S.staleT or 0) < 10.0 then
    local keep = {}; for _, k in ipairs(S.stale) do local p = segFile(S.outName, k); if k > S.outSeg and exists(p) and not os.remove(p) then keep[#keep + 1] = k end end
    S.stale = keep
  end
end

local recvBody
local function recv(peer)                                      -- lane 45: timed (the link file's read cost)
  local t0 = os.clock()
  -- a player whose file does not exist (the host looks for seven friends by name, every 20 ms) is looked for again
  -- once a second, not at every read (b0: 95 opens a second on the host, 0.46 ms a frame)
  local R0 = C.s.readers[peer]
  if R0 and R0.missT and t0 - R0.missT < 1.0 then return {}, {} end
  local lines, ends = recvBody(peer)
  kAdd("link:read", (os.clock() - t0) * 1000); K.rN = K.rN + #lines
  return lines, ends
end
recvBody = function(peer)
  local S = C.s; local R = S.readers[peer]
  if not R then R = { seg = 1, off = 0, part = "" }; S.readers[peer] = R end
  R.seg = R.seg or 1
  local lines, ends = {}, {}
  for _ = 1, 8 do                                              -- one file, or a few when the chain moves on
    local f = io.open(segFile(peer, R.seg), "rb")
    R.missT = nil
    if not f then
      if R.seg <= 1 then R.missT = os.clock(); break end       -- lane 45: no file of that player (see recv)
      -- this file is gone. A later file exists: this copy was more than two whole files behind (never in normal play)
      local nx; for j = R.seg + 1, R.seg + 64 do if exists(segFile(peer, j)) then nx = j; break end end
      if nx then log("link: %s.%d.txt was deleted before this copy read it to its end; going on with file %d (lines may be lost)", peer, R.seg, nx); R.seg, R.off, R.part, R.head = nx, 0, "", nil
      elseif exists(segFile(peer, 1)) then R.seg, R.off, R.part, R.head = 1, 0, "", nil   -- none: that player started again
      else break end
    else
      local size = f:seek("end")
      -- the file was emptied and written again (that player restarted the game): read it from the start. Size alone does
      -- not show it: a rejoining friend's first line is exactly as long as the first line of the session before, and the
      -- host never saw that hello (first session between two PCs, 2026-11-11). So the first bytes are compared too.
      f:seek("set", 0); local head = f:read(48) or ""
      if size < R.off or (R.head and #R.head > 0 and head:sub(1, #R.head) ~= R.head) then R.off = 0; R.part = ""; R.head = nil end
      if not R.head or #head > #R.head then R.head = head end
      if size == R.off then f:close(); break end
      f:seek("set", R.off); local data = f:read("a"); f:close()
      if not data or #data == 0 then break end
      local start = (R.seg - 1) * SEGPOS + R.off - #R.part       -- where in the chain the first byte of "data" (below) is
      R.off = R.off + #data; K.rB = K.rB + #data
      S.heard = S.heard or {}; S.heard[peer] = os.clock()        -- when this player last sent anything (player list, "left the game")
      data = R.part .. data
      -- ends[i]: the place in the chain right after line i. The join module keeps the place of the host's "save taken
      -- here" line and later reads the lines again from there (a single friend's resync, coop_join.lua).
      local pos, moved = 1, nil
      while true do
        local nl = data:find("\n", pos, true); if not nl then break end
        local line = data:sub(pos, nl - 1):gsub("\r", "")
        pos = nl + 1
        if #line > 0 then
          local k = line:find(" ~NEXT ", 1, true) and nextMark(line)
          if k and k > R.seg then moved = k; break end         -- the writer went on in file k: the rest is read there
          lines[#lines + 1] = line; ends[#lines] = start + nl
        end
      end
      if moved then R.seg, R.off, R.part, R.head = moved, 0, "", nil
      else R.part = data:sub(pos); break end
    end
  end
  return lines, ends
end

-- (join) Read a player's file again from an earlier place. A friend that alone loaded a save the host took while it
-- kept running has missed everything the host sent since that save: the lines from the save's marker to the file's
-- end right now are "replayed" (S.replay), in order, into the fresh world; what comes after them is live again.
-- Returns how many bytes will be read again, or nil when the place is not usable (also when its file was deleted).
local function rewind(peer, off)
  local S = C.s; local R = S.readers[peer]
  if not R or type(off) ~= "number" or off < 0 or off > ((R.seg or 1) - 1) * SEGPOS + R.off then return nil end
  local seg = math.floor(off / SEGPOS) + 1; local o = off - (seg - 1) * SEGPOS     -- (math.floor: an integer for the file name)
  local size = fsize(segFile(peer, seg)); if not size or o > size then return nil end
  local cs = R.seg or 1
  local csize = (cs == seg) and size or fsize(segFile(peer, cs)) or R.off
  local bytes = size - o
  if cs ~= seg then bytes = bytes + csize; for k = seg + 1, cs - 1 do bytes = bytes + (fsize(segFile(peer, k)) or 0) end end
  R.seg, R.off, R.part, R.head = seg, o, "", nil
  S.replay = { peer = peer, from = off, to = (cs - 1) * SEGPOS + csize, n = 0, skipS = 0, own = 0, nak = 0, t = os.clock() }
  return bytes
end
C.link = { send = send, recv = recv, rewind = rewind, segChain = segChain, readerAtEnd = readerAtEnd, segFile = segFile }   -- self-test: tests/linkfiles

-- ---------------------------------------------------------------- friend: watch the local player's orders
local HOOKS = { "InpActEvt_RightMouseButton_K2Node_InputKeyEvent_3", "InpActEvt_RightMouseButton_K2Node_InputKeyEvent_2",
                "InpActEvt_LeftMouseButton_K2Node_InputKeyEvent_1", "InpActEvt_LeftMouseButton_K2Node_InputKeyEvent_0",
                "InpActEvt_squadSprint_K2Node_InputActionEvent_14" }

-- WHO CHANGED THE SPEED (lane 16, 2026-11-12; evidence in research/2026-11-10-game-probe/lanes/lane_s21_16/report.txt).
-- The game changes its own speed and pause for reasons of its own, and the speed watcher below took each of them for
-- the player pressing a speed button. Measured on the plain game, and with a host and a friend:
--   * a hostile squad comes into sight: speed 1 (or 0), by the player's own game option; the notice
--     "enemy_squad_spotted" is added in the same step (the game's code at RVA 4b7aacc..4b7aede);
--   * a quest message arrives: one speed step down (the lord blueprint's decreaseGameSpeed, called by the game);
--   * the camera follows a villager, cinematic mode is switched on or off: speed 1;
--   * the map view: pause, with the pause flag, and the old speed back when it closes;
--   * every full screen of the game (pause menu, quest and letter messages, popups, the development tree, the
--     mercenary screen, the letter writer, the autosave): speed 0 while it is open, and the speed it had BEFORE back
--     when it closes. Seen on two copies: a friend closed the development tree, and the host, which had gone from 4
--     to 8 meanwhile, was put back to 4.
-- SPEED_MINE: the player's own speed controls: the HUD's four buttons, the pause key and the two speed keys.
-- SPEED_GAME: the game's own functions that change speed or pause as a side effect (each measured or read).
-- Both are hooked on a friend's copy only to note the moment; the rule is in watch() below.
local BPL = "/Game/CPP_BP/MyPawnCPP_BP3.MyPawnCPP_BP3_C:"
local HUDT = "/Game/UI/HUD/W_HUD_Timer.W_HUD_Timer_C:BndEvt__W_HUD_Timer_"
local SPEED_MINE = { HUDT .. "TimeStopButton_K2Node_ComponentBoundEvent_1_OnClicked__DelegateSignature",
                     HUDT .. "Time1Button_K2Node_ComponentBoundEvent_0_OnClicked__DelegateSignature",
                     HUDT .. "Time2Button_K2Node_ComponentBoundEvent_2_OnClicked__DelegateSignature",
                     HUDT .. "Time3Button_K2Node_ComponentBoundEvent_3_OnClicked__DelegateSignature",
                     BPL .. "toggleTimePause", BPL .. "InpActEvt_pause_K2Node_InputActionEvent_1",
                     BPL .. "InpActEvt_fastSpeed_K2Node_InputActionEvent_4", BPL .. "InpActEvt_slowSpeed_K2Node_InputActionEvent_3" }
local SPEED_GAME = { BPL .. "setGamePausedInclVamp", BPL .. "storeOrBringBackGameSpeedAndZoomAfterMapMenuToggle", BPL .. "decreaseGameSpeed",
                     BPL .. "setupKillCam", BPL .. "playGameOver", "/Game/UI/HUD/MainUICPP.MainUICPP_C:setCastlePlannerOpen",
                     "/Script/ManorLords.PawnCPP:setCinematicMode", "/Script/ManorLords.PawnCPP:setFollowMode" }

local function ensureHooks()
  if rawget(_G, "__coop_hooks_done") then return end
  local S = C.s
  if os.clock() - S.hookT < 2.0 then return end
  S.hookT = os.clock()
  local okAll = true
  for _, ev in ipairs(HOOKS) do
    _G.__coop_hooked = _G.__coop_hooked or {}
    if not _G.__coop_hooked[ev] then
      local ok = pcall(RegisterHook, "/Game/CPP_BP/MyPawnCPP_BP3.MyPawnCPP_BP3_C:" .. ev, function()
        local S2 = _G.Coop and _G.Coop.s
        if S2 and S2.on then S2.inT = os.clock(); S2.stats.inputEvents = (S2.stats.inputEvents or 0) + 1 end
      end)
      if ok then _G.__coop_hooked[ev] = true else okAll = false end
    end
  end
  -- who changed the speed (see SPEED_MINE and SPEED_GAME above): the callbacks only note the moment
  for _, def in ipairs({ { SPEED_MINE, "spMineT" }, { SPEED_GAME, "spGameT" } }) do
    for _, path in ipairs(def[1]) do
      if not _G.__coop_hooked[path] then
        local field, why = def[2], path:match("([^:%.]+)$")
        local ok = pcall(RegisterHook, path, function()
          local S2 = _G.Coop and _G.Coop.s
          if S2 and S2.on then S2[field] = os.clock(); if field == "spGameT" then S2.spGameWhy = why end end
        end)
        if ok then _G.__coop_hooked[path] = true else okAll = false end
      end
    end
  end
  if okAll then _G.__coop_hooks_done = true; log("input hooks registered") end
end

-- Did this copy's GAME change speed or pause by itself a moment ago? (lane 16; called from watch(), every frame the
-- speed differs and four times a second besides, so that the notice list is always known)
--   * one of the game's own functions of SPEED_GAME ran within 0.6 s (hooks above);
--   * follow mode or cinematic mode was switched within 0.6 s (also by the game's native code, which no hook sees:
--     the castle planner follows a part, a cinematic sequence switches the mode);
--   * the notice "enemy_squad_spotted" was added within the last second. Only the newest entry is read, and only
--     when the list is not empty (a read past the end of a game list grows it: ledger G58).
local function gameChangedSpeed(S, clock)
  if S.spWorld ~= S.worlds then S.spWorld = S.worlds; S.logSig = nil; S.spotT = nil; S.spotSeen = nil; S.followWas = nil; S.cineWas = nil end
  pcall(function()
    local fm, cm = S.p1.followMode and true or false, S.p1.cinematicMode and true or false
    if S.followWas ~= nil and (fm ~= S.followWas or cm ~= S.cineWas) then S.spGameT = clock; S.spGameWhy = "follow or cinematic mode" end
    S.followWas = fm; S.cineWas = cm
    local arr = S.p1.log; local n = #arr
    if n == 0 then S.logSig = ""; return end
    local e = arr[n]; local text = e.LogText:ToString()
    local sig = n .. "|" .. text .. "|" .. tostring(e.Timestamp)
    if sig ~= S.logSig then
      -- (lead, 2026-11-17, lane 60's study) the last four entries, not only the newest: another notice in the same
      -- step (a site finished) hid the spotting twice in s59b, and the friend's own drop to 1 was sent as the player's
      local first = (S.logSig == nil); S.spotSeen = S.spotSeen or {}
      for i = n, math.max(1, n - 3), -1 do
        local ei = arr[i]
        if ei.LogText:ToString() == "enemy_squad_spotted" then
          local k = tostring(ei.Timestamp)
          if not first and not S.spotSeen[k] then S.spotT = clock end      -- the first look in a world: nothing is new
          S.spotSeen[k] = true
        end
      end
      S.logSig = sig
    end
  end)
  if S.spotT and clock - S.spotT < 2.0 then S.spGameWhy = "enemy squad spotted"; return true end
  return S.spGameT ~= nil and clock - S.spGameT < 0.6
end

-- report: inside a mouse input window. btn: just after a press on an army command button (stance or skill): the stance
-- and skill changes are the player's own, also in a fight, but a target that changes in that moment is not his move
-- (lane 4, session 21: with one window for both, a button press now and then sent a move the player never gave).
local function scanOrders(report, btn)
  local S = C.s; local p1 = S.p1
  local arr = p1.commandedSquads
  for i = 1, #arr do
    local h = arr[i].Value
    if sqValid(h) then
      local st = sqState(h); local old = S.known[h]
      -- inside an input window every change is the player's. Outside one (a missed mouse event), a change still counts
      -- as the player's when the squad is under full control and not fighting, i.e. when the game itself would not have made it.
      local quiet = old and not old.eng and not st.eng and old.ctl == 0 and st.ctl == 0
      local recent = S.mirT[h] and os.clock() - S.mirT[h] < 0.6
      -- a unit the mod has just called up for the host (rallyLocal): its new target and its run are not the player's
      -- orders (lane 4, session 21: each host rally came back from the friend as a move and a sprint for that unit)
      if not recent and S.rallyT and S.rallyT[h] and os.clock() - S.rallyT[h] < 3.0 then recent = true end
      -- a squad this copy is taking away (removeSafe halts it, and removeTick halts it again every 3 s): the halt is
      -- the mod's, not the player's (lane 20 F3: it went to the host as "O MOVE" for a squad the host no longer had)
      if not recent and ((S.rmQ and S.rmQ[h]) or (S.rmByMod and S.rmByMod[h] and os.clock() - S.rmByMod[h] < 30.0)) then recent = true end
      if old and not recent and (report or quiet or btn) then
        local moved = far(st.tx, st.ty, old.tx, old.ty, 30) or far(st.lx, st.ly, old.lx, old.ly, 30)
        local sent = false
        -- (lane 38) outside a click, a squad whose target squad has just fled, died or gone gets a new target place
        -- from this copy's GAME (it halts or turns): not the player's order. Lane 38 s3: as the rival's army broke, the
        -- friend sent "O MOVE" for two squads of the player's company and the host moved its own squads by it.
        local gameTurn = false
        if not report and not btn and not C.m38off and old.tgt ~= 0 and st.tgt ~= old.tgt then
          local okG, gone = pcall(function() return not sqValid(old.tgt) or S.sc:GetUnitCount({ Value = old.tgt }) == 0 or S.sc:GetSquad({ Value = old.tgt }).Control == FLEEING end)
          gameTurn = not okG or gone
          if gameTurn then S.stats.gameTurns = (S.stats.gameTurns or 0) + 1 end
        end
        if btn or gameTurn then            -- a button press: no move, attack or stop is read from it
        elseif st.tgt ~= old.tgt and st.tgt ~= 0 then send(string.format("O ATTACK %d %d", toHost(h), toHost(st.tgt))); sent = true
        -- (lane 30, real click) a move to the same spot as the move before an attack leaves the target place unchanged:
        -- it ends the attack and marches off, so it is a move, not a stop. NOT MEASURED: that a halt leaves the target
        -- place within 6 m of the squad, and what an enemy squad vanishing mid-march leaves (it now goes out as MOVE)
        elseif st.tgt == 0 and (moved or (old.tgt ~= 0 and far(st.tx, st.ty, st.cx, st.cy, 600))) then send(string.format("O MOVE %d %.0f %.0f %.0f", toHost(h), st.tx, st.ty, st.tz)); sent = true
        elseif st.tgt ~= old.tgt and st.tgt == 0 then send(string.format("O STOP %d", toHost(h))); sent = true end
        if st.push ~= old.push then send(string.format("O PUSH %d %d", toHost(h), st.push)); sent = true end
        if st.behav ~= old.behav then send(string.format("O BEHAV %d %d", toHost(h), st.behav)); sent = true end
        if st.skKey ~= old.skKey then
          local a, b = {}, {}
          for _, k in ipairs(st.sk) do a[k] = true end; for _, k in ipairs(old.sk) do b[k] = true end
          for k in pairs(a) do if not b[k] and k ~= SPREAD then send(string.format("O SKILL %d %d on", toHost(h), k)); sent = true end end
          -- (lane 38) a sprint that ends with no click of the player was ended by this copy's game (its men's stamina,
          -- measured: lane 38 s1 and the lead's camp fight sent "O SKILL 9 off" that way): not the player's order
          for k in pairs(b) do if not a[k] and k ~= SPREAD and not (k == SPRINT and not report and not btn and not C.m38off) then send(string.format("O SKILL %d %d off", toHost(h), k)); sent = true end end
        end
        if sent then S.localOrderT[h] = os.clock(); if not report then S.stats.lateOrders = (S.stats.lateOrders or 0) + 1 end end
      end
      S.known[h] = st
    end
  end
end

local function watch()
  local S = C.s; local p1 = S.p1; local clock = os.clock()
  local down = p1.RMB_pressed_b or p1.LMB_pressed_b
  if down then S.inT = clock; S.stats.downFrames = (S.stats.downFrames or 0) + 1 end
  if S.inT then
    -- after the button is released, keep reporting changes for 0.6 s: the game sets a move's target a moment later
    if not down and clock - S.inT >= 0.05 then
      scanOrders(true)
      if clock - S.inT >= 0.6 then S.inT = nil end
    end
  elseif S.btnT and clock - S.btnT < 0.6 then scanOrders(false, true)      -- S.btnT: set by the army module's hook on the command buttons
  elseif clock - S.lastScan >= 0.15 then S.lastScan = clock; scanOrders(false) end
  -- A militia unit of this player went from "at home" to "called up" and the mod did not do it: the player rallied it.
  -- Tell the host, which calls up the same unit (its state then comes back to every copy).
  if clock - (S.tRallyScan or 0) >= 0.3 then
    S.tRallyScan = clock; S.rsSeen = S.rsSeen or {}
    -- a militia unit that the host knows has gone from this copy and the mod did not remove it: the player removed it
    -- (army panel, "remove unit"). Ask the host to remove the same unit.
    if S.milSeen then
      for h, hh in pairs(S.milSeen) do
        if not sqValid(h) then
          S.milSeen[h] = nil
          if not (S.rmByMod and S.rmByMod[h]) and not C.hold then
            -- (lane 16) Only when the player pressed for it: the army panel's "remove unit" (either of its two
            -- handlers) or its send-home button (which dismisses a mercenary company), within the last 30 s (the game
            -- takes a squad away up to about 20 s after it is asked to). The army module notes those presses.
            -- A unit that goes away with no such press was removed by this copy's GAME. Measured on the plain game: a
            -- mercenary company that cannot be paid at the month's change routs and is gone a third of a day later.
            -- Read in the game's code: the last fleeing squad of a company is removed when it reaches its retreat
            -- point, and a region that changes hands loses its units. Sent as "this player removed it", the host
            -- dismissed its own unit, which it may have been able to pay or still had standing.
            local pressed = (S.rmInT and clock - S.rmInT < 30.0) or (S.disbandT and clock - S.disbandT < 30.0)
            if pressed then send(string.format("O REMOVE %d", hh)); log("this player removed unit %d: sent to the host", h)
            else S.stats.goneByGame = (S.stats.goneByGame or 0) + 1; log("unit %d (%d on the host) went away here and this player did not remove it: not sent", h, hh) end
          end
        end
      end
    end
    -- Mercenaries hired on this copy (army panel, Hire). The player's game made the company's squads here; the host
    -- has never listed them. The company that just left this copy's offer list is the one that was hired: ask the
    -- host to hire the same company, and give it this copy's squad numbers so the host's new squads are tied to
    -- them (same idea as a raised militia unit). A hire the host does not confirm within 6 s is undone here.
    local okM, names = pcall(function() local t = {}; local a = S.eng.availableMercs; for i = 1, #a do t[a[i].Name:ToString()] = true end; return t end)
    if okM then
      local fresh = {}
      for h in pairs(S.mine) do
        if sqValid(h) and not S.l2h[h] and not (S.seenT and S.seenT[h]) and not (S.hireSent and S.hireSent[h]) and not (S.rmByMod and S.rmByMod[h]) then
          local okT, st = pcall(sqState, h); if okT and st.merc then fresh[#fresh + 1] = h end
        end
      end
      -- which company: the one that left this copy's offer list within the last 5 s. The squads can show up in the
      -- player's list a moment after the offer is gone, so the name is remembered rather than compared in one scan
      -- (session 20: a hire whose squads appeared one scan late was never sent).
      if S.mercNames then for n in pairs(S.mercNames) do if not names[n] then S.mercGone = { name = n, t = clock } end end end
      S.mercNames = names
      if #fresh > 0 and (S.fullSeen or 0) >= 3 then
        S.freshT = S.freshT or clock
        local gone = S.mercGone and clock - S.mercGone.t < 5.0 and S.mercGone.name or nil
        S.hireSent = S.hireSent or {}
        if gone then
          table.sort(fresh)
          for _, h in ipairs(fresh) do S.hireSent[h] = clock end
          send("O HIRE " .. gone .. " " .. table.concat(fresh, ","))
          log("this player hired %s (%d squads): sent to the host", gone, #fresh)
          S.mercGone = nil; S.freshT = nil
        elseif clock - S.freshT > 3.0 then
          -- squads of a company this copy cannot name: nothing to ask the host for; they are undone below
          for _, h in ipairs(fresh) do S.hireSent[h] = clock - 10.0 end
          log("this player has %d new mercenary squads but no company left the offers: undone here", #fresh)
          S.freshT = nil
        end
      else S.freshT = nil end
    end
    if S.hireSent then
      for h, t in pairs(S.hireSent) do
        if not sqValid(h) or S.l2h[h] then S.hireSent[h] = nil
        elseif clock - t > 6.0 then
          S.hireSent[h] = nil
          if C.removeSafe then pcall(C.removeSafe, h, "the host did not hire this company") end
          if not S.hireNote or clock - S.hireNote > 5.0 then S.hireNote = clock; C.notify("info", "The host could not hire that company") end
        end
      end
    end
    for h in pairs(S.mine) do
      if sqValid(h) then
        local ok, st = pcall(sqState, h)
        -- a mercenary squad the host lists: remember it, so that dismissing it here is passed on (below, as for militia)
        -- (lane 20) A company the HOST hired is made here as a plain squad (spawnCompleteUnit, squadType 0, not 2): a
        -- friend's "remove unit" on it took it away here and sent nothing (measured). Every non-militia squad of this
        -- player that this mod made for a host squad counts as such a company.
        if ok and (st.merc or (not st.mil and S.l2h[h])) and S.seenT and S.seenT[h] then S.milSeen = S.milSeen or {}; S.milSeen[h] = toHost(h) end
        if ok and st.mil then
          -- a militia unit of this player that the host has never listed: the player raised it here. Ask the host to raise one.
          -- "Not listed" is read from the host's full lists, never from the clock: the host's state must be flowing
          -- (a full list within the last second) and the unit must be missing from the latest full list, for a second
          -- without a break. Until lane 4 (session 21) the test was "not seen for 1.5 s" and the timer was never
          -- reset: after a resync (same unit numbers, no translation entry) one pause of 1.5 s in the host's state made
          -- the friend "raise" its existing unit again; the host made a second unit and the two copies fell apart.
          local flowing = S.lastFullT and clock - S.lastFullT < 1.0
          local listed = S.seenT and S.seenT[h] and S.lastFullT and S.seenT[h] >= S.lastFullT - 0.3
          if S.l2h[h] or listed then if S.raiseSeen then S.raiseSeen[h] = nil end
          elseif (S.fullSeen or 0) >= 3 and flowing then
            S.raiseSeen = S.raiseSeen or {}; S.raiseSeen[h] = S.raiseSeen[h] or clock
            S.raiseSent = S.raiseSent or {}
            if clock - S.raiseSeen[h] > 1.0 and not S.raiseSent[h] then
              S.raiseSent[h] = clock
              local okT, typ = pcall(function() return S.sc:GetSquad({ Value = h }).unitType:ToString() end)
              if okT then send(string.format("O RAISE %d %s", h, typ)); log("this player raised a %s unit (%d): sent to the host", typ, h) end
            end
          end
          if S.seenT and S.seenT[h] then S.milSeen = S.milSeen or {}; S.milSeen[h] = toHost(h) end      -- the host lists this unit
          local was = S.rsSeen[h]; S.rsSeen[h] = st.rs
          if was == 0 and st.rs ~= 0 and not (S.rallyT and S.rallyT[h] and clock - S.rallyT[h] < 5.0) then
            send(string.format("O RALLY %d %.0f %.0f %.0f", toHost(h), st.tx ~= 0 and st.tx or st.cx, st.ty ~= 0 and st.ty or st.cy, st.tz))
            S.localOrderT[h] = clock; S.stats.ralliesSent = (S.stats.ralliesSent or 0) + 1
          elseif was and was ~= 0 and st.rs == 0 and not (S.homeT and S.homeT[h] and clock - S.homeT[h] < 5.0) then
            -- (lane 16) Only when the player pressed the send-home button within the last 5 s (noted by the army
            -- module's hook on the command buttons; measured on two copies: the unit's status is 0 a third of a
            -- second after the press). The game also sends a unit home by itself: read in its code, a unit that fled
            -- and reaches its retreat point, and a unit whose last man is taken out of it
            -- (SquadComp::RequestDisbandSquad is called from updateFleeingSquad and from RemoveUnitFromSquad). Sent as
            -- the player's order, the host sent its own unit home in the middle of a fight. Without the press nothing
            -- is sent; if the host's unit is still out, the mirror calls this one up again (measured).
            if S.disbandT and clock - S.disbandT < 5.0 then send(string.format("O HOME %d", toHost(h))); S.localOrderT[h] = clock
            else S.stats.homeByGame = (S.stats.homeByGame or 0) + 1; log("unit %d went home here and this player did not send it: not sent", h) end
          end
        end
      end
    end
  end
  -- Anyone may pause, un-pause and change speed. When this copy's pause or speed is not what the mod last set, the
  -- player changed it: send it to the host and stop following the host for a second, until the change comes back.
  --   status: proven on two copies (README sessions 16, 17)
  -- For 10 s after a load the game itself puts the speed back to 1 (seen 4.5 s after a resync, session 17); that is
  -- not the player, so nothing is sent then and the next state line from the host sets the speed again.
  if clock - (S.tSpGame or 0) >= 0.25 then S.tSpGame = clock; gameChangedSpeed(S, clock) end      -- keeps its view of the notice list current
  if S.setPaused ~= nil and clock >= (S.speedHold or 0) then
    local pz = isPaused(); local sp = S.eng.gameSpeed
    local differs = pz ~= S.setPaused or (not pz and math.abs(sp - (S.setSpeed or sp)) > 0.05)
    if not differs then S.agree = true
    -- The same within 3 s after the mod itself made a squad on this copy: the game answers a squad that appears
    -- (bandits of a new camp, raiders, a rival's militia) by putting the speed back to 1. Measured 2026-11-12 with a
    -- host and four friends: every "SPEED 1.00" a friend sent came within a second after "created squad for host"
    -- or "stand-in squad" in its own log, on all four friends at once, and the host passed it on to everybody.
    -- (S.modQuestT: the events module has just started one of the host's quests here; the game answers a new quest
    -- message by going one speed step down: lane 16, measured on the plain game)
    elseif clock - (S.worldT or 0) < 10.0 or clock - (S.modSquadT or -100) < 3.0 or clock - (S.modQuestT or -100) < 3.0 then S.agree = false
    -- Who changed it (lane 16)? The player's own speed control ran within 0.6 s (SPEED_MINE): his, sent below.
    -- Otherwise, when the game itself did something that changes speed or pause (gameChangedSpeed above), it is the
    -- game's: nothing is sent, and the host's next state line puts this copy back to the host's speed and pause
    -- (for a full screen that means: time runs on behind it, as it does for the other players).
    -- A change with neither mark is still sent as before, and logged, so that a cause nobody knows yet shows up.
    elseif not (S.spMineT and clock - S.spMineT < 0.6) and gameChangedSpeed(S, clock) then
      if S.agree then
        S.stats.speedByGame = (S.stats.speedByGame or 0) + 1
        log("speed: this copy's game changed speed or pause by itself (%s; now %.2f, paused %s): not sent, the host's is followed", tostring(S.spGameWhy), sp, tostring(pz))
      end
      S.agree = false
    elseif S.agree then                      -- it agreed before and differs now: the player changed it
      -- only the HUD's buttons give speed 1, 4 or 8; any other speed is never the player's choice and is not sent
      local b = nil; for _, v in ipairs({ 1.0, 4.0, 8.0 }) do if math.abs(sp - v) < 0.05 then b = v end end
      if pz ~= S.setPaused or b then
        if not (S.spMineT and clock - S.spMineT < 0.6) then log("speed: changed here with no speed control of the player and no known cause of the game (now %.2f, paused %s): sent as the player's", sp, tostring(pz)) end
        send(string.format("O SPEED %.2f %d", (pz or not b) and (S.hostSpeed or 1.0) or b, pz and 1 or 0))
        S.speedHold = clock + 1.0; S.setPaused = pz; S.setSpeed = b or S.setSpeed; S.stats.speedSent = (S.stats.speedSent or 0) + 1
      else S.agree = false end
    end
  end
end

-- ---------------------------------------------------------------- host: apply a friend's order
local function applyOrder(w)
  local S = C.s; local sc = S.sc
  local kind, h = w[4], tonumber(w[5])
  -- orders added by the army module (coop_x_army.lua: NAME, WAY). It sees every order first (a new move, attack,
  -- stop or halt ends a chain of waypoints) and answers only for its own kinds.
  if C.armyOrder then local r = C.armyOrder(S, kind, h, w); if r ~= nil then return r end end
  if kind == "RAISE" then          -- O RAISE <the friend's own unit number> <type>: a friend raised a militia unit (army panel, "+")
    local arr = S.p1.commandedSquads; local before = {}
    for i = 1, #arr do before[arr[i].Value] = true end
    S.p1:addMilitiaSquad(S.p1:getClosestOwnedRegion(), FName(w[6]))
    arr = S.p1.commandedSquads
    for i = 1, #arr do local v = arr[i].Value; if v ~= 0 and not before[v] then S.raised = S.raised or {}; S.raised[v] = tostring(S.curPeer) .. ":" .. tostring(w[5]) end end
    S.pawnsT = 0
    return "ok"
  end
  if kind == "HIRE" then            -- O HIRE <company> <the friend's own squad numbers>: a friend hired a mercenary company
    local name, rec = w[5], nil
    local offers = S.eng.availableMercs
    for i = 1, #offers do if offers[i].Name:ToString() == name then rec = offers[i] end end
    if not rec then return "not on offer here" end
    local cost = 0; pcall(function() cost = tonumber(rec.cost) or 0 end)
    if (tonumber(S.p1.silver) or 0) < cost then return "not enough silver" end
    local arr = S.p1.commandedSquads; local before = {}
    for i = 1, #arr do before[arr[i].Value] = true end
    S.eng:hireMercs(rec, S.p1)                       -- the game's own hire: makes the squads, charges the lord, drops the offer
    local theirs = {}; for x in (w[6] or ""):gmatch("%d+") do theirs[#theirs + 1] = x end
    arr = S.p1.commandedSquads; local n = 0
    for i = 1, #arr do
      local v = arr[i].Value
      if v ~= 0 and not before[v] then n = n + 1; if theirs[n] then S.raised = S.raised or {}; S.raised[v] = tostring(S.curPeer) .. ":" .. theirs[n] end end
    end
    S.pawnsT = 0
    return n > 0 and "ok" or "no squads made"
  end
  if kind == "REMOVE" then          -- O REMOVE <unit>: a friend removed a unit (army panel): a militia unit at home with no men out, or a mercenary squad that is not fighting
    if h and sqValid(h) then
      local st = sqState(h)
      if st.mil and st.rs == 0 and sc:GetUnitCount({ Value = h }) == 0 then S.p1:removeSquad({ Value = h }); return "ok" end
      if st.merc and not (C.sqBusy and C.sqBusy(h)) then S.p1:removeSquad({ Value = h }); return "ok" end
    end
    return "refused"
  end
  if kind == "HOME" then            -- O HOME <unit>: a friend sent a militia unit home (disband button)
    if h and sqValid(h) and sqState(h).rs ~= 0 then sc:RequestDisbandSquad({ Value = h }) end
    return "ok"
  end
  if kind == "RALLY" then           -- O RALLY <unit> <x> <y> <z>: a friend called up a militia unit; call up the same unit here
    local x, y, z = tonumber(w[6]), tonumber(w[7]), tonumber(w[8])
    if h and x and y and sqValid(h) and sqState(h).rs == 0 and not C.rallyLocal(h, x, y, z or 0) then
      S.rallyQ = S.rallyQ or {}; S.rallyQ[h] = { x = x, y = y, z = z or 0, t = os.clock() }     -- helper busy: retried in the driver
    end
    return "ok"
  end
  if kind == "SPEED" then           -- O SPEED <speed> <paused 0|1>: any player may pause, un-pause and change speed
    local sp, pz = tonumber(w[5]) or 1.0, w[6] == "1"
    local b = nil; for _, v in ipairs({ 1.0, 4.0, 8.0 }) do if math.abs(sp - v) < 0.05 then b = v end end      -- button speeds only
    setPaused(pz)
    if not pz and b and math.abs(S.eng.gameSpeed - b) > 0.02 then S.p1:setGameSpeed(b) end
    return "ok"
  end
  if not sqValid(h) then return "no such squad" end
  if sc:GetUnitCount({ Value = h }) == 0 then return "empty" end      -- no order of any kind for a squad with no men (crash, see doMove)
  if kind == "MOVE" then S.chase[h] = nil; moveOrder(h, { X = tonumber(w[6]), Y = tonumber(w[7]), Z = tonumber(w[8]) }); return "ok"
  elseif kind == "ATTACK" then local e = tonumber(w[6]); S.chase[h] = { e = e, t = os.clock() }; return attackOrder(h, e)
  elseif kind == "STOP" then S.chase[h] = nil; sc:SetSkillActive({ Value = h }, HALT, true, true); return "ok"
  elseif kind == "PUSH" then sc:SetPushStance({ Value = h }, tonumber(w[6]), false, false); return "ok"
  elseif kind == "BEHAV" then sc:SetBehaviourStance({ Value = h }, tonumber(w[6]), false); return "ok"
  elseif kind == "SKILL" then
    local k = tonumber(w[6]); if k == HALT then S.chase[h] = nil end
    -- Shield wall is switched on only when the host's own game allows it for this squad right now (its button is grey
    -- while the squad charges or has just been engaged). Forced on, the friend's copy drops it again by itself and the
    -- two copies differ (lane 4, session 21). Refused here, the friend's squad follows the host's a second later.
    if k == SHIELDWALL and w[7] == "on" then return tostring(sc:SetSkillActive({ Value = h }, k, true, false)) end
    return tostring(sc:SetSkillActive({ Value = h }, k, w[7] == "on", true))
  end
  return "unknown order"
end

local function hostInbox()
  local S = C.s
  for _, peer in ipairs(S.peers) do
    for _, line in ipairs(recv(peer)) do
      local w = words(line)
      if w[3] == "O" and tonumber(w[2]) and tonumber(w[2]) >= S.startWall - 1 then
        S.curPeer = peer
        local ok, r = pcall(applyOrder, w)
        S.stats.applied = S.stats.applied + 1
        log("APPLIED %s %s %s %s delay_ms=%.0f %s", peer, w[1], w[4], w[5], (now() - tonumber(w[2])) * 1000, ok and tostring(r) or ("ERR " .. tostring(r)))
      elseif w[3] == "BYE" and tonumber(w[2]) and tonumber(w[2]) >= S.startWall - 1 then C.friendLeft(peer, "its goodbye (" .. tostring(w[4]) .. ")", "bye")   -- (lane 51)
      elseif w[3] and tonumber(w[2]) and tonumber(w[2]) >= S.startWall - 1 then C.dispatch(peer, w, line) end
    end
  end
  -- keep chasing: re-send the attack approach until the squads are in contact
  local clock = os.clock()
  for h, c in pairs(S.chase) do
    if clock - c.t >= 1.5 then
      c.t = clock
      if not sqValid(h) or not sqValid(c.e) then S.chase[h] = nil
      else local s = S.sc:GetSquad({ Value = h }); if s.isEngaged then S.chase[h] = nil else attackOrder(h, c.e) end end
    end
  end
end

-- ---------------------------------------------------------------- host: send state
-- A soldier is named by its place in its squad (soldiers sorted by their id), never by the id itself:
-- ids are per-copy counters and differ between copies for anything created during a session.
-- (join, lane 15) That holds while every copy has loaded the same save at the same moment: ids are given anew in a
-- load, in the order of the game's unit list, and that order is not the order of creation (measured: after a load
-- two archers of one squad had lower ids than their squad mates). A friend that loaded ALONE therefore sorts a squad
-- differently from the host, which did not load. For soldiers without a name (mercenaries, brigands) that changes
-- nothing: they are alike. A militia man is a villager with a name and a family, and the wrong man must not die: so
-- each entry also carries the man's own mark (family number and name; "-" when he has no name), the host sends the
-- marks of the dead with their places, and a friend looks for the mark first and for the place second.
local function soldierTok(u)
  local ok, t = pcall(function()
    local n = u.DisplayName:ToString()
    if type(n) ~= "string" or n == "" then return "-" end
    return tostring(u.workerFamilyID) .. "." .. (n:gsub("[^%w]", "_"))
  end)
  return (ok and type(t) == "string") and t or "-"
end
local function aliveList(h)
  local list = {}
  for _, u in ipairs(unitsOf(h)) do list[#list + 1] = { id = u.UniqueID, u = u, tok = soldierTok(u) } end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

local function announce(h, st, again)
  local S = C.s; local s = S.sc:GetSquad({ Value = h }); local op = s.ownerPawn; local kind = "P"
  if valid(op) and op:GetAddress() ~= S.p1:GetAddress() then kind = op.isBandit and "B" or ("A" .. tostring(op:getPawnSetupIndex())) end
  -- (lane 48, round 3) a bandit squad that holds a camp: the camp's place too ("camp=<x dm>,<y dm>,<z cm>", last word), so a friend
  -- makes the camp and takes the game's own squad of it as this one (coop_x_events.lua, E.campAt)
  local campTok = ""
  -- (k1: in whole cm the friend's camp list, keyed by decimetres, rounded 10182.5 to 10183 and took the camp for
  -- another one: it made a second camp and asked for a resync. So the place goes as the camp list's own key, dm.)
  -- (test switch, host console: Coop.m48noCampTok = true sends no camp place, so the friend takes the old path)
  if kind == "B" and not again and not C.m48noCampTok then pcall(function() local cb = s.camp; if valid(cb) then local l = cb:K2_GetActorLocation(); campTok = string.format(" camp=%d,%d,%.0f", math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), l.Z) end end) end
  -- (lane 52, round 3, second helper) a new camp's squad is announced at the mean of its men's own places, not at the
  -- game's centre for it: in a squad's first tick that centre is not where its men are (q6: 2.7 m beside them on the
  -- host, 43 to 1280 m on a friend), and the friend puts its men around the announced place
  local ax, ay = st.cx, st.cy
  if campTok ~= "" and C.m52camp ~= false then      -- (test switch, host console: Coop.m52camp = false)
    pcall(function() local mx, my, k = 0, 0, 0; for _, u in ipairs(unitsOf(h)) do if valid(u) then local q = u.realPos; mx = mx + q.X; my = my + q.Y; k = k + 1 end end; if k > 0 then ax, ay = mx / k, my / k end end)
  end
  send(string.format("N %d %s %s %.0f %.0f %.0f %d %s%s%s", h, s.unitType:ToString(), kind, ax, ay, st.tz, st.n, (S.raised and S.raised[h]) or "-", again and " R" or "", campTok))
  if not again then log("announced new squad %d %s %s", h, s.unitType:ToString(), kind) end
end

-- (join) Every squad of the host once more, marked "R" (again), for a friend that has just loaded a save alone.
-- A squad that was not in that save, or that the load did not bring back (lane 15: a squad under attack at the
-- moment of the save was in no lord's list after the load), is made on that friend the way a new squad is. A copy
-- that already has the squad makes nothing (see N on the friend), so the other friends are not touched.
-- A squad that flees on the host is left out: it is about to go, and a stand-in for it would be a fresh, full squad.
function C.announceAll()
  local S = C.s; if not S or S.role ~= "host" or not S.baseDone then return 0 end
  if not (S.eng and S.sc) then return 0 end       -- (lane 59) the host itself is between two worlds (a friend's READY read with no world): no squad to name
  local n = 0
  for h in pairs(S.sq) do
    if sqValid(h) then
      local ok, st = pcall(sqState, h)
      if ok and st.ctl ~= FLEEING then local okA = pcall(announce, h, st, true); if okA then n = n + 1 end end
    end
  end
  log("join: all %d squads announced again", n)
  return n
end

-- the game clock as one number: whole days plus the fraction of the current day (one day is 40 s at speed 1)
local function gameClock()
  local S = C.s; local v
  pcall(function() v = S.eng.TemporalComponent:getTotalDaysAndHours() end)
  return tonumber(v) or 0
end

-- Paused for the friends: the host's pause, or the host's world standing still behind one of the game's full screens
-- (a "Cold!" message after a raid stopped the host's engine with speed 4 still set; the friend, told "not paused",
-- ran 7 game days ahead in 4 minutes and the copies fell apart: lane 24, sitting 1). The friends then pause with the
-- host and run on when the host's screen is closed.
local function hostStopped()
  local S = C.s
  if isPaused() then return true end
  local stopped = false
  pcall(function()
    local GS = S.GS; if not valid(GS) then GS = StaticFindObject("/Script/Engine.Default__GameplayStatics"); S.GS = GS end
    stopped = GS:IsGamePaused(S.p1) and true or false
  end)
  -- (lane 44) a stop that came with the window's focus loss and no pause control of the player is undone by the focus
  -- module in this frame (coop_focus.lua): it is not told to the friends
  if stopped and C.focus and C.focus.focusStop and C.focus.focusStop(os.clock()) then stopped = false end
  -- (lane 24, round 2) Every friend waits while the host's world stands still; both sides are told why. A sitting
  -- stood still for three hours behind the host's pause menu (opened by the game when the host's window lost focus)
  -- with no word to anybody. The friends get "HOLD 1" at once and again every 30 s (a friend that joins meanwhile),
  -- and "HOLD 0" when it runs again; the host is told how many players its screen holds.
  local clock = os.clock()
  if stopped ~= (S.hostScreenStop or false) or (stopped and clock - (S.holdSaidT or 0) >= 30.0) then
    local changed = stopped ~= (S.hostScreenStop or false)
    S.hostScreenStop = stopped; S.holdSaidT = clock
    if changed then log("speed: the host's world %s behind a game screen", stopped and "stands still" or "runs again") end
    send(stopped and "HOLD 1" or "HOLD 0")
    if stopped then
      local n = 0; for _, p in ipairs(S.peers or {}) do if S.heard and S.heard[p] and clock - S.heard[p] <= 10.0 then n = n + 1 end end   -- players heard from lately
      if n > 0 then C.notify("info", string.format("Your open screen is holding the game for %d player%s", n, n == 1 and "" or "s")) end
    end
  end
  return stopped
end
-- full = true (4 times a second): every squad; finds new squads and squads that are gone.
-- full = false (20 times a second): only squads in action (fighting, marching, or changed in the last 3 s), and only
-- those whose state changed since it was last sent. Battles need the host's state to reach friends as fast as a
-- friend's order reaches the host; a death is sent the moment the head count changes.
local function hostSnapshot(full)
  local S = C.s; local parts = {}; local seen = {}; local clock = os.clock()
  local list
  if full then
    -- a routing squad drops out of its lord's list but still exists: keep following every squad we have seen
    list = allSquads(); local inList = {}
    for _, h in ipairs(list) do inList[h] = true end
    for h in pairs(S.sq) do if not inList[h] then list[#list + 1] = h end end
  else
    list = {}
    for h, K in pairs(S.sq) do if K.hot and clock - K.hot < 3.0 then list[#list + 1] = h end end
    if #list == 0 then return end
  end
  for _, h in ipairs(list) do
    if sqValid(h) then
      seen[h] = true
      local st = sqState(h); local K = S.sq[h]
      if not K then
        K = { n = st.n, list = aliveList(h), hot = clock }; S.sq[h] = K
        if S.baseDone then announce(h, st) end
      elseif st.n ~= K.n then
        local cur = aliveList(h); local has, places = {}, {}
        for _, e in ipairs(cur) do has[e.id] = true end
        -- a man who is no longer in the squad died only if the game says so (SMUnit.dead) or he no longer exists.
        -- Militia men who walk home after "disband" leave the squad alive: reported as deaths, they were killed on
        -- every friend's copy (session 20: a friend's town lost its 13 militia men each time the host sent them home)
        local toks, named = {}, false
        for i, e in ipairs(K.list) do
          if not has[e.id] then
            local alive = false; pcall(function() alive = valid(e.u) and not e.u.dead end)
            if not alive then places[#places + 1] = i; toks[#toks + 1] = e.tok or "-"; if e.tok and e.tok ~= "-" then named = true end
            else S.stats.leftAlive = (S.stats.leftAlive or 0) + 1 end
          end
        end
        K.list = cur; K.n = st.n; K.hot = clock
        -- the marks of the dead follow their places only when one of them has a name (see aliveList)
        if #places > 0 then send(string.format("D %d %s%s", h, table.concat(places, ","), named and (" " .. table.concat(toks, ",")) or "")) end
      end
      K.st = st; K.stT = clock     -- (lane 48) kept for the men module (coop_x_men.lua): its squad states without reads of its own
      local enc = string.format("%d,%d,%d,%d,%.0f,%.0f,%.0f,%d,%d,%s,%.0f,%.0f,%d,%d", h, st.n, st.ctl, st.tgt, st.tx, st.ty, st.tz, st.push, st.behav,
        st.skKey == "" and "-" or st.skKey, st.cx, st.cy, st.eng and 1 or 0, st.rs)
      if enc ~= K.enc then K.hot = clock end            -- it moved, fought, or got an order: watch it closely for 3 s
      -- (lane 38) the full list also carries, per squad (not part of the change test):
      --   15 run   1 when most of its first men run (SMUnit.sprintMode), else 0
      --   16 spd   its men's mean ground speed (SMUnit.realSpeed, x10): a rival's men called up by its lord's own
      --            decision walk to their muster, the same unit called up on a friend by the rally tool runs (s3, s4:
      --            200 m apart); a friend holds its mustering men to this speed
      --   17 face  the mean of its men's SMUnit.dir (degrees). Measured (lane 38 p2, host only): a line A->B given
      --            with formALineArmy leaves the men's dir pointing from A to B (0, 180, 90, 270 for the four ways)
      --   18 len   its men's spread along that direction (dm): the length of its line
      if full then
        local run, spd, face, len = 0, 0, -1, 0
        pcall(function()
          local arr = S.sc:GetSquad({ Value = h }).unitArr; local n = #arr; local r, m, fx, fy, pts = 0, 0, 0, 0, {}
          for i = 1, n do local u = un(arr[i]); if valid(u) then
            m = m + 1; if i <= 8 and u.sprintMode then r = r + 1 end
            spd = spd + (tonumber(u.realSpeed) or 0); local d = u.dir; fx = fx + d.X; fy = fy + d.Y; local q = u.realPos; pts[#pts + 1] = { q.X, q.Y } end end
          if m > 0 then
            if r * 2 > math.min(8, m) then run = 1 end
            spd = spd / m
            local l = math.sqrt(fx * fx + fy * fy)
            if l > 0.01 then
              face = math.floor(math.deg(math.atan(fy, fx)) % 360 + 0.5)
              local ux, uy = fx / l, fy / l; local lo, hi = 1e12, -1e12
              for _, q in ipairs(pts) do local v = q[1] * ux + q[2] * uy; if v < lo then lo = v end; if v > hi then hi = v end end
              len = (hi - lo) / 10
            end
          end
        end)
        parts[#parts + 1] = string.format("%s,%d,%.0f,%d,%.0f", enc, run, spd * 10, face, len)
      elseif enc ~= K.enc then parts[#parts + 1] = enc end
      K.enc = enc
      -- (round 2) another lord's militia: WHO its men are (their marks, family.name, as for deaths) whenever the list
      -- changes: "MT <squad> <mark,mark,...>". A friend calls up its own copy of the unit with the rally tool, whose men
      -- are other villagers from other houses: the muster gathered 45-58 m apart (s10). The friend takes these men.
      if full and st.mil and K.list then
        local okO, other = pcall(function() local op = S.sc:GetSquad({ Value = h }).ownerPawn; return valid(op) and op:GetAddress() ~= S.p1:GetAddress() end)
        if okO and other then
          local t = {}; for _, e in ipairs(K.list) do if e.tok and e.tok ~= "-" then t[#t + 1] = e.tok end end
          table.sort(t); local str = table.concat(t, ",")
          if str ~= K.tokS and str ~= "" then K.tokS = str; send(string.format("MT %d %s", h, str)) end
        end
      end
    end
  end
  if full then
    for h in pairs(S.sq) do if not seen[h] then S.sq[h] = nil; send("G " .. h) end end
    S.baseDone = true
  end
  if full or #parts > 0 then
    local list = table.concat(parts, ";")
    send(string.format("S %.2f %d %.4f %s %s", S.eng.gameSpeed, hostStopped() and 1 or 0, gameClock(), list == "" and "-" or list, full and "F" or "P"))
  end
end

-- ---------------------------------------------------------------- friend: follow the host
local function uidIndex()
  local S = C.s
  if S.uidIndex and os.clock() - S.uidIndexT < 2.0 then return S.uidIndex end
  local idx = {}
  for _, h in ipairs(allSquads()) do if sqValid(h) then for _, u in ipairs(unitsOf(h)) do idx[u.UniqueID] = u end end end
  S.uidIndex = idx; S.uidIndexT = os.clock()
  return idx
end

-- Removing a squad on a friend's copy. The game's own "remove squad" is safe only on a squad that is not fighting:
-- a bandit group removed while its men were setting houses on fire crashed the game in its projectile update (README
-- session 20: access violation at RVA 4dbad42, the thrown torch still pointed at its thrower). Men who set fire to
-- houses show nothing on the squad (not engaged, no target), so there is no reliable "busy" test. Rule: a squad with
-- men is always halted first and removed 4 s later (longer than anything stays in the air), and only if it is not
-- fighting then. One that will not calm down within 8 s (a routing squad, say) loses its men the game's normal way (they die) and is removed
-- when it is empty. An empty squad is removed at once.
local function sqBusy(h)
  local busy = false
  pcall(function()
    local s = C.s.sc:GetSquad({ Value = h })
    busy = (s.isEngaged and true or false) or s.targetSquad.Value ~= 0 or #s.engagedSquads > 0
    if not busy then local b = s.targetBuildingPart; if b and b:IsValid() then busy = true end end
  end)
  return busy
end
local function removeSafe(h, why)
  local S = C.s; local sc = S.sc; local clock = os.clock()
  S.rmQ = S.rmQ or {}; S.busyT = S.busyT or {}; S.rmDone = S.rmDone or {}
  if S.rmQ[h] or not sqValid(h) then return end
  -- The game takes a squad away some seconds after it is asked to (session 21: a refused company stayed in the
  -- player's list for about 20 s and was asked for three times). One request is enough; ask again only after 30 s.
  if S.rmDone[h] and clock - S.rmDone[h] < 30.0 then return end
  S.rmByMod = S.rmByMod or {}; S.rmByMod[h] = clock          -- the watcher must not report this as the player's own removal
  if sc:GetUnitCount({ Value = h }) == 0 then
    sc:RequestRemoveSquad({ Value = h }); S.rmDone[h] = clock; S.stats.removed = (S.stats.removed or 0) + 1
    log("squad %d removed (%s)", h, why)
    return
  end
  S.rmQ[h] = { t = clock, why = why, haltT = clock }
  -- A squad that flees here (the game's own rout, started with the host's) is not halted and its men are never
  -- "let die" (below): they became bodies in the player's region that the host does not have (lane 4, session 21:
  -- 8 fled bandits killed here, approval 46 against the host's 57 three days later through "unburied", then families
  -- and a resync). It is taken away 4 s later with the game's own "remove squad" whatever its fight flags say (a
  -- fleeing squad keeps "engaged" set here; it throws nothing). Tried on a fleeing squad of 4: gone at once, no
  -- bodies, no crash.
  local fleeing = false; pcall(function() fleeing = sc:GetSquad({ Value = h }).Control == FLEEING end)
  if fleeing then log("squad %d is to be removed (%s): it flees here, removed in 4 s without a halt", h, why); return end
  pcall(function() sc:SetSkillActive({ Value = h }, HALT, true, true) end)
  log("squad %d is to be removed (%s): halted, removed in 4 s", h, why)
end
C.removeSafe = removeSafe; C.sqBusy = sqBusy
-- every 0.5 s on a friend's copy: note which squads are busy, and work the removal queue
local function removeTick(clock)
  local S = C.s; local sc = S.sc
  S.busyT = S.busyT or {}
  for _, h in ipairs(allSquads()) do if sqValid(h) and sqBusy(h) then S.busyT[h] = clock end end
  if not S.rmQ then return end
  for h, q in pairs(S.rmQ) do
    if not sqValid(h) then S.rmQ[h] = nil
    else
      local n = sc:GetUnitCount({ Value = h })
      local fleeing = false; pcall(function() fleeing = sc:GetSquad({ Value = h }).Control == FLEEING end)
      if n > 0 and fleeing and clock - q.t < 4.0 then
        -- a fleeing squad: wait the 4 s, then remove it (next branch); never halted, never killed
      elseif n == 0 or (clock - q.t >= 4.0 and (fleeing or clock - (S.busyT[h] or -100) > 4.0)) then
        sc:RequestRemoveSquad({ Value = h }); S.rmQ[h] = nil; S.rmDone = S.rmDone or {}; S.rmDone[h] = clock; S.stats.removed = (S.stats.removed or 0) + 1
        log("squad %d removed (%s, after %.1f s)", h, q.why, clock - q.t)
      elseif clock - q.t > 8.0 and not q.killed then
        q.killed = true
        if C.men and C.men.squadGone then pcall(C.men.squadGone, h) end   -- (lane 43) out of the native table first
        local list = unitsOf(h); for _, u in ipairs(list) do pcall(function() u:just_die() end) end
        log("squad %d would not calm down: its %d men were let die, removed when empty", h, #list)
      elseif clock - q.haltT > 3.0 then q.haltT = clock; pcall(function() sc:SetSkillActive({ Value = h }, HALT, true, true) end) end
    end
  end
end

-- this copy just changed squad h on the host's behalf: do not report that change back as a player order
local function touch(h) local S = C.s; S.known[h] = nil; S.mirT[h] = os.clock() end

-- Call up a militia unit the way the game's own rally button and click do, but on the helper lord, so the player's own
-- selection, building tool and panel are left alone: the helper selects the unit, picks the rally tool
-- (PawnCPP:setPlaceRallyingPoint, building type 53), its placement marker goes on the spot and it asks to "build"; the
-- game's build step then calls its rally routine for the selected units (which has no owner test, lane_u Q4) and leaves
-- the tool. The helper is one slot: while the town module has a placement in flight this waits (returns false).
--   status: the recipe was run on the player's lord (README session 20); on the helper: see README session 20
local function rallyLocal(h, x, y, z)
  local S = C.s
  if C.town and C.town.pend then return false end
  local p = helper()
  if not valid(p) or p.requestBuild then return false end
  local ok, e = pcall(function()
    p.selectedSquads = { { Value = h } }
    p:setPlaceRallyingPoint()
    p.bbox:K2_SetWorldLocationAndRotation({ X = x + 0.0, Y = y + 0.0, Z = (z or 0) + 0.0 }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, false, {}, true)
    p.requestBuild = true
  end)
  S.rallyT = S.rallyT or {}; S.rallyT[h] = os.clock(); S.helperRallyT = os.clock()
  S.stats.rallies = (S.stats.rallies or 0) + 1
  log("rally: unit %d called up at %.0f,%.0f%s", h, x, y, ok and "" or (" FAILED " .. tostring(e)))
  return ok
end
C.rallyLocal = rallyLocal
-- A called-up militia unit of another lord here gets the host's head count (see the mirror): the last men (by id) leave
-- the unit alive, or free recruits of the lord's nearest region join it. Returns the head count afterwards.
function C.milFollow(h, st, H)
  local S = C.s; local sc = S.sc; local moved, why = 0, ""
  local who = {}      -- (lane 52, round 3) the men moved, by mark, in the log line
  if st.n > H.n then
    local list = aliveList(h)
    for i = #list, H.n + 1, -1 do if valid(list[i].u) and pcall(function() list[i].u:removeFromSquad() end) then moved = moved - 1; who[#who + 1] = tostring(list[i].tok) end end
  else
    local okR, recruits = pcall(function() return sc:GetSquad({ Value = h }).ownerPawn:getClosestOwnedRegion():getAllAvailableRecruits(false) end)
    local n = (okR and recruits) and #recruits or 0
    if n == 0 then why = " (no free recruit in the lord's region)" end
    local want = H.n - st.n
    for i = 1, n do
      if moved >= want then break end
      local u = un(recruits[i])
      if valid(u) and pcall(function() u:turnToSoldierJoinSquad({ Value = h }) end) then moved = moved + 1; who[#who + 1] = tostring(soldierTok(u)) end
    end
  end
  local after = sc:GetUnitCount({ Value = h })
  S.stats.milFollow = (S.stats.milFollow or 0) + 1
  if S.stats.milFollow <= 20 then log("militia unit %d of another lord: %d men here, %d on the host: %+d moved (%s), now %d%s", h, st.n, H.n, moved, table.concat(who, ","), after, why) end
  return after
end
-- what the army module (coop_x_army.lua) may use of the order code above
C.armyApi = { sqValid = sqValid, sqState = sqState, unitsOf = unitsOf, aliveList = aliveList, allSquads = allSquads, issuer = issuer, commit = commit,
              doMove = doMove, moveOrder = moveOrder, attackOrder = attackOrder, touch = touch, hostKill = hostKill }

-- (lane 38) a trace of what the mirror does, for the test sampler (lanes/lane_s21_38/probes/samp38.lua): kept only
-- while S.m38tr is a table (the sampler sets it); M.br is the mirror's last branch for the squad
local function mtr(h, what) local t = C.s.m38tr; if t and #t < 400 then t[#t + 1] = tostring(toHost(h)) .. ":" .. what end end

-- ---------------------------------------------------------------- (lane 38) the squad's place on a friend's copy
-- lanes/lane_s21_38/report.txt. Each copy walks its own squads; the host's order reaches a friend about 0.1 to 0.3 s
-- late, each copy's game ends a sprint by its own men's stamina, and each copy finds its own path. Measured (the lead's
-- camp fight; lane 38 sitting s1): a friend's squad 2 to 6 m behind the host's all the way on a march at speed 4, 37 m
-- ahead for 40 s when the host's sprint ended 4 s before the friend's, 29 m to the side on another path around the town.
-- So on a friend, while both squads march:
--   pace   every man's own walking speed (SMUnit.Speed; measured: realSpeed follows it at once, sprint doubles it, it
--          stays) is set to 0.8 to 1.25 times his own so that the squad closes on the place the host's squad has NOW
--          (its last place plus its motion times the line's age): no order, so no stop and no turn on screen.
--   sprint the host's sprint state is followed for every squad (also the player's); a sprint this copy's game ends by
--          itself is not sent to the host as the player's order (coop.lua scanOrders).
--   path   a squad that walks more than 8 m beside the host's track for 2 s is sent to the host's place first (a via),
--          then on to its target: from there its path is the host's.
--   stand  a squad more than 4 m from the host's standing squad (1.5 s within 1 m) is sent to the host's place (at
--          most 3 times to one place); a host squad standing far from an unchanged target (its target fled) counts by
--          its place; a squad with a target follows the host's standing place and does not chase a routing target.
--   also   pace while both rout; an attack the mirror gave counts as the same aim for 8 s; men walk when the host's
--          walk (a rival's muster); the next order goes at once when the host's squad leaves a fight; a target this
--          copy's game changes after its target fled is not sent to the host as the player's order.
-- C.m38off = true switches all of it off (a test's "before").
local PACE_MIN, PACE_MAX, PACE_T = 0.8, 1.25, 2.5     -- pace limits; seconds to close a gap
-- M.paceB: per man (by address) his own Speed and the man himself, so that every man this mirror ever paced gets his
-- own Speed back, also one who left the squad meanwhile (sent home, removeFromSquad)
local function paceSet(S, h, M, f)
  M.paceB = M.paceB or {}
  local okS, s = pcall(function() return S.sc:GetSquad({ Value = h }) end); if not okS then return end
  local arr = s.unitArr; local n = #arr; local seen = {}
  for i = 1, n do
    local u = un(arr[i])
    if valid(u) then
      local k = u:GetAddress(); seen[k] = true
      local e = M.paceB[k]
      if not e then local b = tonumber(u.Speed) or 0; if b > 0 then e = { b = b, u = u }; M.paceB[k] = e end end
      if e then
        u.Speed = e.b * f
        -- the walking animation plays at its own rate whatever Speed says (p2: animSpeedFac 1.0 at 0.8x, 1.0x and
        -- 1.25x; 1.98 at a sprint): the men's feet would slide by the factor. Their animation rate follows it.
        -- (rate = ground speed / his own walking speed: s10 showed the first form, 2.0 whenever sprintMode was set,
        -- playing a sprint's legs on men that walked)
        pcall(function() local rs = tonumber(u.realSpeed) or 0; if rs > 0.5 then local mult = math.max(0.5, math.min(2.5, rs / (e.b * (M.paceF or 1.0)))); u.animSpeedFac = mult * f end end)
      end
    end
  end
  -- a man paced before who is no longer in the squad (sent home, taken out by name) gets his own speed back now
  -- (s11: 11 men kept 16.04 against their 15.625)
  for k, e in pairs(M.paceB) do if not seen[k] then if valid(e.u) then pcall(function() e.u.Speed = e.b end) end; M.paceB[k] = nil end end
  M.paceF = f; M.paceT = os.clock()
end
local function paceOff(S, h, M)
  if M.paceF and M.paceB then
    for k, e in pairs(M.paceB) do if valid(e.u) then pcall(function() e.u.Speed = e.b end) else M.paceB[k] = nil end end
  end
  M.paceF = nil
end
local function segDist(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay; local l2 = dx * dx + dy * dy
  local u = l2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) or 0
  return math.sqrt((px - ax - u * dx) ^ 2 + (py - ay - u * dy) ^ 2)
end
-- the host squad's motion and track, kept per squad from the host's lines (positions in cm, time in wall seconds)
local function hostMotion(M, H)
  local tw = H.wall or now()
  if M.hT and tw > M.hT + 0.02 then
    local dt = tw - M.hT; local vx, vy = (H.cx - M.hx) / dt, (H.cy - M.hy) / dt
    if dt > 2.0 then M.vx, M.vy = 0, 0
    else local a = math.min(1, dt / 0.6); M.vx = (M.vx or vx) + (vx - (M.vx or vx)) * a; M.vy = (M.vy or vy) + (vy - (M.vy or vy)) * a end
  end
  if not M.hT or tw > M.hT + 0.02 then M.hx, M.hy, M.hT = H.cx, H.cy, tw end
  M.trk = M.trk or {}
  local last = M.trk[#M.trk]
  if not last or tw - last.t >= 0.5 then M.trk[#M.trk + 1] = { x = H.cx, y = H.cy, t = tw }; if #M.trk > 14 then table.remove(M.trk, 1) end end
  return tw
end
-- (round 2) the host's squad has stood still: within 1 m over the last 1.5 s of the HOST's own clock (its lines'
-- wall times). s10: under load the host's lines came seconds apart, a motion of 0 was read from the gap, and a
-- marching friend's squad was stopped as if the host's stood ("stale", "place": 58 m behind).
local function hostStill(M, H)
  local t = M.trk; if not t or #t < 2 then return false end
  local now_ = t[#t]; local ok = false
  for i = #t - 1, 1, -1 do
    local q = t[i]
    if math.abs(q.x - now_.x) > 100 or math.abs(q.y - now_.y) > 100 then return false end
    if now_.t - q.t >= 1.5 then ok = true; break end
  end
  return ok and (H.cx - now_.x) ^ 2 + (H.cy - now_.y) ^ 2 < 10000
end
local function trackDist(M, x, y)
  local t = M.trk; if not t or #t < 2 then return 0 end
  local best = 1e12
  for i = 2, #t do best = math.min(best, segDist(x, y, t[i - 1].x, t[i - 1].y, t[i].x, t[i].y)) end
  return best
end
-- pace and path for one squad; returns true while a via move runs. flee = both squads rout (the game's own rout on
-- both copies): pace only, never a via (a move would end the rout here)
local function place38(S, h, M, H, st, clock, flee)
  -- (lane 43) a squad whose men lane 43's table holds (coop_x_men.lua) gets no corrective orders: its men already have
  -- the host's places, and an order would let them go (round 1: 7 000 releases a sitting)
  local MH = C.men and C.men.holds and C.men.holds(h)
  local tw = hostMotion(M, H)
  local lag = math.max(0, math.min(1.0, now() - tw))
  local vx, vy = M.vx or 0, M.vy or 0; local v = math.sqrt(vx * vx + vy * vy)
  local px, py = H.cx + vx * lag, H.cy + vy * lag                      -- where the host's squad is now
  -- the same aim: the same target squad (an attack this mirror gave counts for 8 s: the game sets the target squad
  -- only at contact, lane 34), or the same target place
  local sameAim = flee or (H.tgt ~= 0 and (st.tgt == H.tgt or (M.atkH == H.tgt and clock - (M.atkT or -100) < 8.0)))
                  or (H.tgt == 0 and st.tgt == 0 and not far(st.tx, st.ty, H.tx, H.ty, 500))
  local marching = (flee or (H.ctl == 0 and st.ctl == 0 and not H.eng and not st.eng)) and v > 60
  local via = false
  if M.via then
    if flee or H.tgt ~= 0 or not far(st.cx, st.cy, M.via.x, M.via.y, 500) or clock - M.via.t > 8.0 or not marching then M.via = nil; M.key = nil; M.t = 0; mtr(h, "viaend")
    else via = true end
  -- no via for another lord's militia or retinue: while it musters its centre is the mean of men walking in from
  -- their houses, and a move order there is an order into the call-up (s4, s8: via30, via51 on A2's militia)
  -- (round 2) and never while the host's squad marches on a target squad: a via is a move order, which ends the attack
  -- (with lane 37's native attack the target squad is set at once, and a via then left the friend's militia walking to
  -- an old place for 8 s, 93 m behind: the lead's leadcamp3, trace via10 at 13 s and 35 s). On an attack the pace alone
  -- closes the gap; the game's own attack path is the same on both copies.
  -- (round 3) nor in the last 20 m before the host's squad's target: there the formation wheels into its line and a
  -- via aimed ahead on that motion overshoots (s22m: the company sent 30 m past the host's at its arrival)
  elseif marching and sameAim and not flee and H.tgt == 0 and clock - (M.viaT or -100) > 8.0 and not M.muster and not MH
         and (H.tx == 0 or math.sqrt((H.cx - H.tx) ^ 2 + (H.cy - H.ty) ^ 2) > 2000) then
    local off = trackDist(M, st.cx, st.cy)
    if off > 800 then M.offT = M.offT or clock else M.offT = nil end
    -- (round 2) the 2 s are game time at speed 4: at speed 8 a squad on another path is 22 m off after 2 s of wall
    -- time (s15, through the town), so the wait is 8 s of game time; and the via aims 1 s ahead on the host's motion
    -- (a via to where the host's squad is now left the friend's 26 m behind once it had stopped and turned)
    local gsp = math.max(1.0, tonumber(S.hostSpeed) or 4.0)
    if M.offT and clock - M.offT >= 8.0 / gsp then
      local ax, ay = px + vx * 1.0, py + vy * 1.0
      M.offT = nil; M.viaT = clock; M.via = { x = ax, y = ay, t = clock }; via = true; paceOff(S, h, M)
      touch(h); moveOrder(h, { X = ax, Y = ay, Z = H.tz }); S.stats.via = (S.stats.via or 0) + 1; mtr(h, string.format("via%.0f", off / 100))
    end
  else M.offT = nil end
  if (M.muster or M.musN) and not flee then
    -- (lane 52, round 3) or its men follow the host's men at the native rule's pace (M.musN)
    -- another lord's militia or retinue at its muster (its men spread over 30 m on the host): their speed follows the
    -- host's men's speed (in mirror()), not this pace
  elseif marching and sameAim and not via then
    local a = ((st.cx - px) * vx + (st.cy - py) * vy) / v                -- + = this copy's squad is ahead
    local f = math.max(PACE_MIN, math.min(PACE_MAX, 1.0 - a / (v * PACE_T)))
    -- (round 2) written again every 0.25 s: the animation rate follows the men's ground speed as it changes (s13: 86.8 %
    -- of the friend's moving samples within 10 % of it, the host's 99.3 %, at a write once a second)
    if not M.paceF or math.abs(f - M.paceF) >= 0.03 or clock - (M.paceT or 0) > 0.25 then
      if not M.paceF then mtr(h, string.format("pace%.2f", f)) end
      paceSet(S, h, M, f); S.stats.paceSets = (S.stats.paceSets or 0) + 1
    end
  elseif not via then paceOff(S, h, M) end
  return via
end

-- (round 2) send squad h to stand at the host's place: a line through the place, along the host's facing (the
-- men's dir points from A to B: p2), as long as the host's line; a squad whose last send to this same place left it
-- off by some metres aims that much further (its centre lands behind its line). Plain move when the facing is not known.
local function lineAt(h, x, y, z, face, len)
  local s = C.s.sc:GetSquad({ Value = h })
  local r = math.rad(face); local ux, uy = math.cos(r), math.sin(r); local half = math.max(150.0, (len or 0) / 2)
  local a = { X = x - ux * half, Y = y - uy * half, Z = z }; local b = { X = x + ux * half, Y = y + uy * half, Z = z }
  issuer(s):formALineArmy({ { Value = h } }, { A = a, B = b }, FName("None"), { A = a, B = b }); commit(h)
end
local function sendPlace(S, h, M, H, st, key, clock, what)
  if M.placeNKey == key and M.sendT and clock - M.sendT < 6.0 then return end    -- let the last send settle first
  M.sendT = clock
  local ax, ay = H.cx, H.cy
  if M.placeNKey == key and M.lastSend and st.ctl == 0 then
    local ex, ey = M.lastSend.x - st.cx, M.lastSend.y - st.cy; local el = math.sqrt(ex * ex + ey * ey)
    if el > 600 then ex, ey = ex * 600 / el, ey * 600 / el end
    ax, ay = H.cx + ex, H.cy + ey
  end
  if M.placeNKey ~= key then M.placeNKey = key; M.placeN = 0 end
  M.placeN = M.placeN + 1; M.lastSend = { x = ax, y = ay }; M.t = clock; touch(h)
  if M.face and (M.len or 0) >= 300 and C.s.sc:GetUnitCount({ Value = h }) > 0 then
    local s = C.s.sc:GetSquad({ Value = h }); local face, len = M.face, M.len
    if s.isEngaged or s.targetSquad.Value ~= 0 then
      C.s.sc:SetSkillActive({ Value = h }, HALT, true, true)
      later(0.08, function() if sqValid(h) and C.s.sc:GetUnitCount({ Value = h }) > 0 then lineAt(h, ax, ay, H.tz, face, len) end end)
    else lineAt(h, ax, ay, H.tz, face, len) end
  else moveOrder(h, { X = ax, Y = ay, Z = H.tz }) end
  mtr(h, what)
end
-- this copy's mean facing of squad h's men (degrees) or nil
local function faceOf(h)
  local ok, f = pcall(function()
    local arr = C.s.sc:GetSquad({ Value = h }).unitArr; local fx, fy = 0, 0
    for i = 1, #arr do local u = un(arr[i]); if valid(u) then local d = u.dir; fx = fx + d.X; fy = fy + d.Y end end
    if fx * fx + fy * fy <= 0.01 then return nil end
    return math.deg(math.atan(fy, fx)) % 360
  end)
  return ok and f or nil
end
local function angDiff(a, b) local d = math.abs(a - b) % 360; return math.min(d, 360 - d) end

local function mirror(H)
  local S = C.s; local sc = S.sc; local h = H.h; local clock = os.clock()
  if not sqValid(h) then S.stats.unknown = (S.stats.unknown or 0) + 1; return end
  local M0 = S.mir[h]
  if S.mine[h] and S.localOrderT[h] and clock - S.localOrderT[h] < 2.0 then if M0 then M0.br = "own"; paceOff(S, h, M0) end; return end   -- the player just ordered it: let the host catch up
  if S.mine[h] and (S.inT or (S.btnT and clock - S.btnT < 0.6)) then if M0 then M0.br = "click"; paceOff(S, h, M0) end; return end          -- the player is clicking right now: hands off
  local st = sqState(h); local M = S.mir[h]; if not M then M = { t = 0, pt = 0 }; S.mir[h] = M end
  M.st = st; M.stT = clock      -- (lane 48) kept for the men module's check (coop_x_men.lua): no reads of its own
  local MH = C.men and C.men.holds and C.men.holds(h)    -- (lane 43) its men are held: no corrective orders below
  -- The host's unit is called up and ours is still at home: call ours up at the same spot (a militia unit raised by any
  -- player fills with men only when it is rallied). Ours is called up but the host's is at home again: nothing here yet.
  -- For this player's own units the watcher goes first: the mirror acts only on a state the watcher has already seen
  -- (S.rsSeen), otherwise it would undo the player's own "send home" or "rally" before it was reported to the host
  -- (seen in session 20: a unit sent home on a friend's copy was called up again at once).
  local seenRs = S.rsSeen and S.rsSeen[h]
  -- (lane 24) A rival lord's retinue is called up and sent home like his militia units (seen: the host's rival A2
  -- called up its militia unit and its retinue against raiders; here the militia unit followed, the retinue stayed at
  -- home with 0 men against the host's 5). The player's own retinue: not in the test saves, left as it was.
  local callable = st.mil or (st.ret and not S.mine[h])
  if H.rs and H.rs ~= 0 and st.rs == 0 and callable then
    if S.mine[h] and seenRs ~= 0 then return end
    -- (lane 24) A call-up this copy's game refuses (lane 20 F4: tried every 5 s for minutes, the unit stayed at home)
    -- is tried at most 6 times in a row; then the game's own reason is logged once and the unit is left alone for a
    -- minute (the daily comparison still sees a difference that lasts).
    if M.rallyN and M.rallyN >= 6 then
      if clock - (M.rallyWait or 0) < 60.0 then return end
      M.rallyN = 0
    end
    -- (lane 52, round 3) the first three tries 2 s apart (a call-up that did not take heals in 2 to 4 s; it was 5 s a
    -- try. y1: 20 call-ups of 20 took at the first try, the unit called up 0.3 to 0.5 s after the host's), then 5 s
    if not (S.rallyT and S.rallyT[h] and clock - S.rallyT[h] < (((M.rallyN or 0) < 3) and 2.0 or 5.0)) then
      if (M.rallyN or 0) >= 5 then
        M.rallyN = 6; M.rallyWait = clock
        local why = {}; pcall(function() local r = {}; sc:isSkillAvailableForSquad({ Value = h }, 11, r); for i = 1, #r do why[#why + 1] = un(r[i]):ToString() end end)
        log("rally: unit %d is called up on the host but this copy's game does not take the call-up (%d tries; the game says: %s): left for a minute", h, M.rallyN - 1, #why > 0 and table.concat(why, ",") or "no reason given")
        S.stats.rallyRefused = (S.stats.rallyRefused or 0) + 1
      -- a try counts only when the call-up was really given (rallyLocal returns false while the helper is busy)
      elseif rallyLocal(h, (H.tx ~= 0 and H.tx) or H.cx, (H.ty ~= 0 and H.ty) or H.cy, H.tz) then M.rallyN = (M.rallyN or 0) + 1 end
    end
    return
  end
  if st.rs ~= 0 or H.rs == 0 then M.rallyN = nil end
  if H.rs == 0 and st.rs ~= 0 and st.mil and S.mine[h] and (seenRs == nil or seenRs == 0) then return end
  if H.rs == 0 and st.rs ~= 0 and callable and st.n > 0 and not (S.homeT and S.homeT[h] and clock - S.homeT[h] < 5.0) then
    S.homeT = S.homeT or {}; S.homeT[h] = clock
    pcall(function() sc:RequestDisbandSquad({ Value = h }) end); S.stats.sentHome = (S.stats.sentHome or 0) + 1
    log("rally: unit %d went home on the host: sent home here", h)
    return
  end
  -- A called-up militia unit takes its men from its lord's own villagers, and those are each copy's own: a rival
  -- lord's town differs between copies (lane 24, from the five-copy run: residents 155 against 144, the rival's two
  -- units filled with 95 men on the host against 90 and 82, then a resync). The stand-in below never fits a militia
  -- unit (it is a full template squad: 32 men against the host's 36, made again every 3 s, 47 times on one friend).
  -- So a militia unit follows the host's head count with the game's own calls: a man too many leaves the unit alive
  -- (SMUnit:removeFromSquad, he goes home), a man too few is a free recruit of the lord's region who joins it
  -- (SMUnit:turnToSoldierJoinSquad). Only for other lords' units: the player's villagers are the same people on every
  -- copy, and the player's unit filled alike on both copies in every call-up lane 24 made.
  -- (not in a fight: deaths in a fight are the host's D lines; a count read between a death and its D line is not a
  -- difference to fix, and in lane 24's battle against the rival such fixes left the friend's unit 4 men short for a while)
  -- (round 2) the host named the men (MT): the men here that the host's unit does not have leave it alive
  -- (removeFromSquad), and the host's men that are free here join it (turnToSoldierJoinSquad); then the count rule
  -- below finds nothing left to do. At most 40 changes every 0.5 s (lane 48, round 4; was 8 every 2 s); never in a fight.
  local named = not C.m38off and st.mil and not S.mine[h] and S.hostToks and S.hostToks[h]
  if named and H.rs ~= 0 and st.rs ~= 0 and not st.eng and not H.eng and clock - (M.tokLookT or 0) >= 0.5 then   -- (lane 48, round 4: was 2 s and 8 changes: a muster of 36 took 10-25 s to match)
    M.tokLookT = clock
    local want = S.hostToks[h]; local nWant = 0; for _ in pairs(want) do nWant = nWant + 1 end
    local inSquad = aliveList(h); local here = {}
    for _, e in ipairs(inSquad) do here[e.tok] = "squad" end
    local okR, recruits = pcall(function() return sc:GetSquad({ Value = h }).ownerPawn:getClosestOwnedRegion():getAllAvailableRecruits(false) end)
    local free = {}
    if okR and recruits then local n = #recruits; for i = 1, n do local u = un(recruits[i]); if valid(u) then local tk = soldierTok(u); if tk ~= "-" and not here[tk] then here[tk] = "free"; free[tk] = u end end end end
    -- (lane 52, round 3) a named man who is not in that list: looked for among the recruits "not disbanded" too
    -- (getAllAvailableRecruits(true)). w1, w2 (probes/mus52.lua): the friend's unit stayed 1 or 2 men short of the
    -- host's for the whole muster (29 of 30, 34 and 35 of 36), every missing man was in this second list and in no
    -- other, and the count rule's stand-in for him was taken out again by name every 10 s (milNamed 1 to 6).
    -- (lane 52, round 3, second helper) A man taken from that second list joins the unit as he is: a villager in his
    -- work clothes. turnToSoldierJoinSquad puts him in the unit's list but does not arm him (the game's own call-up
    -- had not reached him yet, and passes him by once he is in the unit). p1, probes/mus52b.lua: 5 of the 6 men taken
    -- that way had att 1, def 0, block 0, meleeTraining 0, no spear and no shield, the animation set "work" (the
    -- others: 4 / 6 / 8, training 1, "combat"), and stood: at the muster's end 4 of them were 5.6 to 28.5 m from
    -- their places for the whole stand while the 25 others were within 0.8 m; that is the unit's centre 2.7 m off
    -- (x1, x2, x5: 2.4, 2.1 and 3.3 m for 60 to 90 s, with 4 or 5 such men each; x3, x4 had 2). So for 30 s after
    -- such a man was taken, every man of the unit who is not in a soldier's animation mode gets what a soldier of
    -- the unit has: his training, the same things in his hands and on his body (the game's own equip), the mode and
    -- the animation set. In p1 a man given these by hand had 4 / 6 / 8 at once and kept the set.
    if M.lateT and clock - M.lateT < 30.0 and C.m52whole ~= false then   -- (test switch, friend console: Coop.m52whole = false)
      local ref
      for _, e in ipairs(inSquad) do
        if valid(e.u) then local okM, md, df = pcall(function() return e.u.animMode, e.u.def end); if okM and md == 1 and (df or 0) > 0 then ref = e.u; break end end
      end
      if ref then
        local okF, rt, rset, rids = pcall(function() local ids = {}; for s = 1, 11 do ids[s] = ref:GetEquippedID(s) end; return ref.meleeTraining, ref.currentAnimset:ToString(), ids end)
        if okF and rids and rset and rset ~= "" then
          for _, e in ipairs(inSquad) do
            if valid(e.u) then
              local okM, md = pcall(function() return e.u.animMode end)
              if okM and md == 0 then
                local n = 0
                local okW, err = pcall(function()
                  local u = e.u
                  u.meleeTraining = rt
                  for s = 1, 11 do local g = rids[s]; if g and g ~= 0 and u:GetEquippedID(s) ~= g then u:equip(g, true, false); n = n + 1 end end
                  u.animMode = 1; u.currentAnimset = FName(rset)
                end)
                S.stats.milWhole = (S.stats.milWhole or 0) + 1
                if (M.wholeSaid or 0) < 20 then M.wholeSaid = (M.wholeSaid or 0) + 1; log("mirror: militia squad %d: %s joined as a villager: armed as the unit's men are (%d things, set %s)%s", h, tostring(e.tok), n, rset, okW and "" or (" FAILED: " .. tostring(err))) end
              end
            end
          end
        end
      end
    end
    local late = {}
    local short = false; for tk in pairs(want) do if not here[tk] then short = true; break end end
    if short and C.m52mil ~= false then   -- (test switch, friend console: Coop.m52mil = false)
      local okR2, rec2 = pcall(function() return sc:GetSquad({ Value = h }).ownerPawn:getClosestOwnedRegion():getAllAvailableRecruits(true) end)
      if okR2 and rec2 then local n = #rec2; for i = 1, n do local u = un(rec2[i]); if valid(u) then local tk = soldierTok(u); if tk ~= "-" and want[tk] and not here[tk] then here[tk] = "free"; free[tk] = u; late[tk] = true; S.stats.milLate = (S.stats.milLate or 0) + 1 end end end end
    end
    local matched = 0; for tk in pairs(want) do if here[tk] then matched = matched + 1 end end
    -- only when this copy has at least three in four of the host's men (in the unit or free): marks that do not
    -- match (other villagers on this copy) would strip the unit and never fill it
    if nWant > 0 and matched * 4 >= nWant * 3 then
      local moved = 0
      local outs, ins = {}, {}      -- (lane 52, round 3) who left and who joined by name, logged (a few lines a call-up)
      for _, e in ipairs(inSquad) do if not want[e.tok] and moved < 40 and valid(e.u) and pcall(function() e.u:removeFromSquad() end) then moved = moved + 1; outs[#outs + 1] = e.tok end end
      for tk in pairs(want) do if moved >= 40 then break end; local u = free[tk]
        if u and valid(u) and pcall(function() u:turnToSoldierJoinSquad({ Value = h }) end) then
          moved = moved + 1; ins[#ins + 1] = (late[tk] and "late:" or "") .. tk
          if late[tk] then M.lateT = clock end
          -- (lane 52, round 3) the men module puts him where the host's man of that mark is, when nobody sees it
          if C.men and C.men.joined then pcall(C.men.joined, S, h, tk, u) end
        end
      end
      if moved > 0 then M.tokT = clock; touch(h); S.stats.milNamed = (S.stats.milNamed or 0) + moved; mtr(h, "named" .. moved)
        if (M.namedSaid or 0) < 40 then M.namedSaid = (M.namedSaid or 0) + 1; log("mirror: militia squad %d by name (host names %d, here %d): out %s; in %s", h, nWant, #inSquad, #outs > 0 and table.concat(outs, ",") or "-", #ins > 0 and table.concat(ins, ",") or "-") end
      end
    elseif not M.tokSaid then
      M.tokSaid = true; log("mirror: militia unit %d of another lord: %d of the host's %d men found here by name: left to the count rule", h, matched, nWant)
    end
    S.stats.milMatched = matched; S.stats.milWanted = nWant
  end
  if st.mil and not S.mine[h] and H.rs ~= 0 and st.rs ~= 0 and st.n ~= H.n and not st.eng and not H.eng and not (named and M.tokT and clock - M.tokT < 10.0) then
    M.milT = M.milT or clock
    if clock - M.milT >= 3.0 and clock - (M.milDo or 0) >= 3.0 then
      M.milDo = clock; touch(h)
      C.milFollow(h, st, H)
    end
  else M.milT = nil end
  -- A unit with no soldiers takes no orders: a move order on an empty militia unit crashed the game (session 20).
  if st.n == 0 then M.br = "empty"; return end
  if S.mine[h] then   -- never act on a change the watcher has not looked at yet: it may be the player's own fresh order
    local k = S.known[h]
    if not k or k.tgt ~= st.tgt or far(k.tx, k.ty, st.tx, st.ty, 30) or k.push ~= st.push or k.skKey ~= st.skKey then
      -- (round 2) a standing squad gets its men's own speed back here too (s20: 13 men kept 0.97 of theirs)
      M.br = "unseen"; if M.paceF and not (st.eng or (M.vx and math.sqrt(M.vx * M.vx + M.vy * M.vy) > 50)) then paceOff(S, h, M) end; return
    end
  end
  local target = { X = H.tx, Y = H.ty, Z = H.tz }
  local where = { X = H.cx, Y = H.cy, Z = H.tz }      -- where the host's squad stands right now
  if H.ctl == FLEEING then
    M.br = "flee"; if not M.routed then mtr(h, "rout") end; M.via = nil
    -- The host's squad routs. With the native piece (coop_patch) the game's own rout is started here, so the squad
    -- really flees (card says so, it runs to its own retreat point). Without it the rout is imitated: stop, then keep
    -- running after the host's squad.
    --   status: imitation proven on two copies (README session 12); native rout: see README session 17
    if not M.routed then
      M.routed = true; M.t = clock; touch(h)
      M.native = false
      if C.patch and C.patch.fn and st.ctl ~= FLEEING then local okN, r = pcall(C.patch.rout, h); M.native = okN and r == true end
      if M.native then S.stats.nativeRouts = (S.stats.nativeRouts or 0) + 1
      else
        sc:SetSkillActive({ Value = h }, HALT, true, true)
        later(0.08, function() if sqValid(h) then doMove(h, where); sc:SetSkillActive({ Value = h }, SPRINT, true, true) end end)
      end
      S.stats.routs = (S.stats.routs or 0) + 1
    elseif not M.native and clock - M.t >= 2.0 and far(st.cx, st.cy, H.cx, H.cy, 600) then M.t = clock; touch(h); doMove(h, where)
    -- (lane 52, round 3) the game's own rout here ended while the host's squad still routs (w1: 8 s early, this copy's
    -- retreat point was nearer): started again, at most once a second, so the squad's state is the host's (its men
    -- keep the host's men's places through the men module meanwhile)
    elseif M.native and st.ctl ~= FLEEING and clock - M.t >= 1.0 and C.patch and C.patch.fn and C.m52rout ~= false then
      M.t = clock; touch(h); local okN, r = pcall(C.patch.rout, h)
      S.stats.reRouts = (S.stats.reRouts or 0) + 1; mtr(h, (okN and r == true) and "rerout" or "reroutfail")
    end
    -- (lane 38) the game's own rout on both copies: the friend's routed squad ran 7 to 12 m behind the host's (s3, the
    -- link's delay at a sprint): its men's pace closes it
    if not C.m38off and M.native and st.ctl == FLEEING then place38(S, h, M, H, st, clock, true) else paceOff(S, h, M) end
    -- the host stays the referee for head counts while the squad routs (session 17: the host's last fleeing bandits
    -- died, this copy kept four of them running for ever because the count rule below was skipped for routing squads)
    if st.n == H.n then M.matched = true; M.nT = nil
    elseif st.n > H.n and M.matched and not st.mil then
      M.nT = M.nT or clock
      if clock - M.nT >= 2.0 then
        local list = aliveList(h)
        for i = #list, H.n + 1, -1 do if valid(list[i].u) then hostKill(list[i].u) end end
        M.nT = nil; S.stats.trimmed = (S.stats.trimmed or 0) + (st.n - H.n)
      end
    end
    return
  end
  -- the host's squad no longer routs: if ours still does (native rout), bring it back the game's own way
  if M.routed and st.ctl == FLEEING and C.patch and C.patch.fn then pcall(C.patch.reform, h) end
  M.routed = false
  -- (lane 32) A bandit camp's squad holds its camp (Control 4, encamped) and takes no move or attack order. On the
  -- host the bandits' own decision lets go of the camp (Control 4 -> 0) when they march out to meet an attacker; on a
  -- friend enemies decide nothing (disableAI), so its brigands stayed in camp while the host's fought 170 m away
  -- (lane 24 R4a). The release is the game's own reformSquad (native REFORM: it sets Control 0); the mirror's orders
  -- below then move the squad where the host's is. At most 3 tries, then a minute's wait (a REFORM that does nothing
  -- is not called every 2 s for ever). lanes/lane_s21_32/report.txt item 1.
  if H.ctl ~= ENCAMPED and st.ctl == ENCAMPED then
    if clock - (M.campT or 0) >= ((M.campN or 0) >= 3 and 60.0 or 2.0) then
      if (M.campN or 0) >= 3 then M.campN = 0 end
      M.campT = clock; M.campN = (M.campN or 0) + 1; touch(h)
      local ok, r, why = pcall(function() return C.patch and C.patch.release and C.patch.release(h) end)
      local now = -1; pcall(function() now = sc:GetSquad({ Value = h }).Control end)
      S.stats.campRelease = (S.stats.campRelease or 0) + 1; mtr(h, "release")
      if S.stats.campRelease <= 20 then log("mirror: squad %d left its camp on the host (Control %d): released here: %s%s, Control now %d", h, H.ctl, ok and tostring(r) or "error ", ok and (why and (" " .. tostring(why)) or "") or tostring(r), now) end
      -- released: the orders below follow in this same tick (sitting s2: the friend's brigands were 30 m behind for 2 s)
      if now ~= ENCAMPED then st = sqState(h) else return end
    else return end
  end
  M.campN = nil
  -- the host is the referee for head counts: if this copy still has more soldiers than the host for 2 s, drop the extra
  -- (only for a squad whose count has matched the host's at least once: a squad that never matched is a different
  --  squad or a different world, and trimming it would kill soldiers for nothing; that needs a reload, not a trim)
  if st.n == H.n then M.matched = true end
  -- The host's squad has clearly more soldiers than ours and it is not the player's own: it was raised or reinforced
  -- on the host (rival lords raise militia; on this copy their decisions are off, so it never happens here).
  -- Stand-in: create a fresh squad of the same type for the same lord where the host's squad stands, point the
  -- host's number at it, and let the head-count rule below trim it to the host's size.
  --   status: not yet run live
  if H.n > st.n + 2 and not S.mine[h] and H.hh and not st.mil and not st.ret then
    M.growT = M.growT or clock
    if clock - M.growT >= 3.0 then
      M.growT = nil
      local s = sc:GetSquad({ Value = h }); local owner = s.ownerPawn; local typ = s.unitType:ToString()
      if valid(owner) and typ ~= "" and typ ~= "None" then
        local lh = S.eng:spawnCompleteUnit(FName(typ), { X = H.cx, Y = H.cy, Z = H.tz }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, owner, 0, 0).Value
        S.modSquadT = os.clock()                             -- (see the speed watcher)
        if lh and lh ~= 0 then
          if S.l2h[h] then S.l2h[h] = nil; removeSafe(h, "replaced by a full squad") end      -- the old one was a stand-in too
          S.h2l[H.hh] = lh; S.l2h[lh] = H.hh; S.mir[lh] = { t = clock, pt = 0, matched = true }; S.pawnsT = 0
          S.stats.standins = (S.stats.standins or 0) + 1
          log("stand-in squad %d (%s) for host squad %d: host has %d soldiers, this copy had %d", lh, typ, H.hh, H.n, st.n)
        end
      end
      return
    end
  else M.growT = nil end
  if st.n > H.n and not M.matched then S.stats.mismatch = (S.stats.mismatch or 0) + 1
  elseif st.n > H.n and not st.mil then
    M.nT = M.nT or clock
    if clock - M.nT >= 2.0 then
      local list = aliveList(h)
      for i = #list, H.n + 1, -1 do if valid(list[i].u) then hostKill(list[i].u) end end
      M.nT = nil; S.stats.trimmed = (S.stats.trimmed or 0) + (st.n - H.n)
    end
  else M.nT = nil; if st.n < H.n then S.stats.short = (S.stats.short or 0) + 1 end end
  -- (lane 38) pace and path while both squads march (see "the squad's place on a friend's copy" above)
  local L38 = not C.m38off
  local via = false
  local key = string.format("%.0f|%.0f", H.tx / 100, H.ty / 100)
  if L38 then
    via = place38(S, h, M, H, st, clock, false)
    if H.run then M.run = H.run end
    if H.spd then M.hspd = H.spd end
    if H.face and H.face >= 0 then
      if not M.face or angDiff(M.face, H.face) > 10 then M.faceT0 = clock end      -- since when the host's facing holds
      M.face = H.face; M.len = H.len
    end
    -- (round 2) another lord's militia or retinue (its muster, and its march): its men's mean ground speed is held
    -- to the host's (16th field) through the same per-man Speed as the pace, instead of the pace by place (a muster's
    -- centre is the mean of men walking in from their houses)
    -- only while it musters (its men spread over 30 m along the host's facing): on the march the pace by place
    -- holds it (s10: the retinue's march went from 1.3 / 1.6 / 4.1 / 5.2 m to 6.9 / 29 / 63 / 67 m with this rule on)
    M.muster = (st.mil or st.ret) and not S.mine[h] and (M.len or 0) > 3000
    -- (lane 52, round 3) while the men module holds this squad's men to the host's men's own places at the native pace
    -- rule's pace (C.men.musters: its factor 1 at the place, more when behind), the squad gets no pace from here:
    -- neither the speed matching below nor the pace by place (place38 looks at M.musN). The speed matching held the
    -- MEAN speed to the host's, so a squad that was behind stayed behind (h2: 9.5 m; the retinue 10 m in k2-k4).
    M.musN = C.men and C.men.musters and C.men.musters(h) or false
    if M.musN then
      if M.paceF then paceOff(S, h, M); M.musT = nil; S.stats.musterNative = (S.stats.musterNative or 0) + 1; mtr(h, "musnative") end
    elseif M.muster and M.hspd and not H.eng and not st.eng and H.ctl == 0 then
      local okF, fs = pcall(function() local arr = sc:GetSquad({ Value = h }).unitArr; local t, m = 0, 0; for i = 1, #arr do local u = un(arr[i]); if valid(u) then t = t + (tonumber(u.realSpeed) or 0); m = m + 1 end end; return m > 0 and t / m or 0 end)
      if okF and fs > 1.0 and M.hspd >= 0 and clock - (M.musT or 0) > 0.5 then
        local f0 = M.paceF or 1.0
        local f = math.max(0.25, math.min(PACE_MAX, f0 * math.max(0.2, M.hspd) / fs))
        if math.abs(f - f0) >= 0.03 then paceSet(S, h, M, f); M.musT = clock; S.stats.musterPace = (S.stats.musterPace or 0) + 1; if not M.musSaid then M.musSaid = true; mtr(h, string.format("muster%.2f", f)) end end
      end
    end
    if (st.mil or st.ret) and not S.mine[h] and (H.eng or st.eng or H.ctl ~= 0) and M.musT then paceOff(S, h, M); M.musT = nil end
    if M.lastKey ~= key then M.lastKey = key; M.keyT = clock end      -- when the host's target place last changed
    -- the host's men walk and these run (no sprint order on either; not in a fight): these walk too
    if M.run == 0 and not H.eng and not st.eng and H.ctl == 0 and clock - (M.runT or 0) > 1.0 then
      local spr = false; for _, k in ipairs(H.sk or {}) do if k == SPRINT then spr = true end end
      if not spr then
        local n = 0
        pcall(function() local arr = sc:GetSquad({ Value = h }).unitArr; for i = 1, #arr do local u = un(arr[i]); if valid(u) and u.sprintMode then u.sprintMode = false; n = n + 1 end end end)
        if n > 0 then M.runT = clock; S.stats.walkSet = (S.stats.walkSet or 0) + 1; mtr(h, "walkmen" .. n) end
      end
    end
    -- and the other way: the host's men run (a charge from far, its men's own sprintMode, no sprint order) and these
    -- walk: these run (s16: the friend's militia walked a 300 m charge the host's ran, 430 m behind at the end)
    if M.run == 1 and not H.eng and not st.eng and H.ctl == 0 and clock - (M.runT or 0) > 1.0 then
      local n = 0
      pcall(function() local arr = sc:GetSquad({ Value = h }).unitArr; for i = 1, #arr do local u = un(arr[i]); if valid(u) and not u.sprintMode and (tonumber(u.realSpeed) or 0) > 0.5 then u.sprintMode = true; n = n + 1 end end end)
      if n > 0 then M.runT = clock; S.stats.runSet = (S.stats.runSet or 0) + 1; mtr(h, "runmen" .. n) end
    end
    -- the branch below changes (the fight or the attack ended on the host): its next order goes at once, not after the
    -- 4 s wait for a repeated target (s4: the friend's company stayed in its fight 4 s after the host's had left it)
    local br = H.eng and "eng" or (H.tgt ~= 0 and "tgt" or "move")
    if M.lastBr and M.lastBr ~= br then M.key = nil; M.t = math.min(M.t or 0, clock - 1.0) end
    M.lastBr = br
  end
  -- (round 2) this copy's squad is still in its own melee while the host's has left its fight (it walks on, or
  -- stands elsewhere) more than 6 m away for 1.5 s (s10: the militia 135 m off for a minute, held by its melee here):
  -- out of the melee, to the host's place
  local outMelee = false
  if L38 and st.eng and not H.eng and H.ctl ~= FLEEING and math.sqrt((st.cx - H.cx) ^ 2 + (st.cy - H.cy) ^ 2) > 800 then M.engOffT = M.engOffT or clock else M.engOffT = nil end
  if M.engOffT and clock - M.engOffT >= 1.5 and clock - M.t >= 3.0 and clock - (M.outT or -100) >= 10.0 and not MH then
    M.t = clock; M.outT = clock; M.engOffT = nil; outMelee = true; touch(h); moveOrder(h, where); S.stats.outMelee = (S.stats.outMelee or 0) + 1; mtr(h, "outmelee")
  end
  if not H.eng then M.engX = nil end
  if via then M.br = "via"
  elseif outMelee then M.br = "outmelee"
  elseif H.eng then                  -- the host's squad is in a fight: stand where it stands, and close in if this copy is not fighting yet
    M.br = "eng"
    -- once this copy's squad is fighting too, leave it alone unless it is far off (a move would pull it out of the fight)
    -- (round 2) both fighting and this copy's squad more than 6 m off the host's for 1.5 s (the host's squad followed
    -- its enemy, s9: the company 60 m away while the friend's stayed in its own melee): it goes where the host's is
    -- (the move takes it out of this copy's melee; nobody dies here anyway: NOKILL) and closes in again below
    -- (round 2) only when the host's squad has MOVED more than 12 m since its fight began (it followed its enemy) and
    -- this copy's is more than 6 m from it; at most once in 10 s. Two copies' melees sit 5-9 m apart by themselves, and
    -- a hold on that alone gave 104 regroup orders in one sitting (s10), a stutter.
    if not M.engX then M.engX, M.engY = H.cx, H.cy end
    local engFar = false
    if L38 and st.eng and math.sqrt((H.cx - M.engX) ^ 2 + (H.cy - M.engY) ^ 2) > 1200 and math.sqrt((st.cx - H.cx) ^ 2 + (st.cy - H.cy) ^ 2) > 600 then
      M.engFarT = M.engFarT or clock; engFar = clock - M.engFarT >= 1.5 and clock - (M.engMoveT or -100) >= 10.0
    else M.engFarT = nil end
    if (engFar or far(st.cx, st.cy, H.cx, H.cy, st.eng and 2000 or 500)) and clock - M.t >= 2.0 and not MH then
      M.t = clock; M.engFarT = nil; touch(h)
      if engFar then M.engMoveT = clock; M.engX, M.engY = H.cx, H.cy end
      if L38 then moveOrder(h, where) else doMove(h, where) end; S.stats.regroup = (S.stats.regroup or 0) + 1; mtr(h, "regroup")
    -- close in only when the host's two squads are in contact (within 8 m): archers that shoot from a distance stay put
    elseif not st.eng and H.tgt ~= 0 and sqValid(H.tgt) and S.host[H.tgt] and not far(H.cx, H.cy, S.host[H.tgt].cx, S.host[H.tgt].cy, 800) and clock - M.t >= 1.5 then M.t = clock; touch(h); if L38 then C.attackAim = { X = H.tx, Y = H.ty } end; attackOrder(h, H.tgt); C.attackAim = nil; M.atkH, M.atkT = H.tgt, clock; S.stats.closein = (S.stats.closein or 0) + 1; mtr(h, "closein") end
  elseif H.tgt ~= 0 then             -- the host's squad is marching on another squad
    M.br = "tgt"
    -- (lane 38) the host's squad stands with a target (archers shooting, or its target routs and the game holds it)
    -- and this copy's is elsewhere: it goes to the host's place, and it does not chase a routing target the host's
    -- does not chase (s6: the friend's archers ran 540 m after the rival's routing retinue, the host's stood)
    local hostStill = L38 and hostStill(M, H)
    local tgtFlees = S.host[H.tgt] and S.host[H.tgt].ctl == FLEEING
    local dist = math.sqrt((st.cx - H.cx) ^ 2 + (st.cy - H.cy) ^ 2)
    -- (round 2) both march on the same target squad and this copy's squad walks more than 4 m beside the host's
    -- track for 2 s (s14: 4-9 m across for a minute, each copy charging another man of the camp): the attack is given
    -- again, aimed at the host's TargetLocation. An attack order re-aims the charge, it does not stop it (the game
    -- itself re-aims every half second). At most once in 5 s.
    local reaim = false
    if L38 and not st.eng and st.tgt == H.tgt and not hostStill then
      if trackDist(M, st.cx, st.cy) > 400 then M.raT = M.raT or clock else M.raT = nil end
      reaim = M.raT ~= nil and clock - M.raT >= 2.0 and clock - (M.reaimT or -100) >= 5.0
    else M.raT = nil end
    if reaim and not MH then
      M.raT = nil; M.reaimT = clock; M.t = clock; touch(h); C.attackAim = { X = H.tx, Y = H.ty }; attackOrder(h, H.tgt); C.attackAim = nil
      S.stats.reaim = (S.stats.reaim or 0) + 1; mtr(h, "reaim")
    elseif hostStill and not MH and not st.eng and dist > (tgtFlees and 400 or 800) and clock - M.t >= 2.0 and clock - (M.tpT or -100) >= (tgtFlees and 2.0 or 10.0) then
      M.t = clock; M.tpT = clock; touch(h); moveOrder(h, where); S.stats.tgtPlace = (S.stats.tgtPlace or 0) + 1; mtr(h, "tgtplace")
    -- (lane 48) not again every 1.5 s at the same target when this copy's squad keeps no target squad after it (a
    -- bandit squad's attack sets only its target place: t3, the bandits' chase of the militia, 14 attacks in 20 s,
    -- each ending their men's run: 10-15 m behind for 11 s); once in 8 s then (as long as sameAim counts that attack)
    elseif st.tgt ~= H.tgt and not st.eng and sqValid(H.tgt) and clock - M.t >= 1.5 and not (hostStill and tgtFlees)
           and not (st.tgt == 0 and M.atkH == H.tgt and clock - (M.atkT or -100) < 8.0) then
      M.t = clock; touch(h); if L38 then C.attackAim = { X = H.tx, Y = H.ty } end; attackOrder(h, H.tgt); C.attackAim = nil; M.atkH, M.atkT = H.tgt, clock; S.stats.attacks = (S.stats.attacks or 0) + 1; mtr(h, "attack")
      -- (lane 38) the attack order ends a sprint here; the host's squad charges at a sprint: sprint again at once (s8:
      -- the friend's brigands walked their charge, sprint and attack taking turns every second, 7 to 11 m behind)
      if L38 then local hs = false; for _, k in ipairs(H.sk or {}) do if k == SPRINT then hs = true end end
        if hs then pcall(function() sc:SetSkillActive({ Value = h }, SPRINT, true, true) end); M.sprT = clock end end
    end
  else
    M.br = "move"
    local tol = S.mine[h] and 500 or 200
    -- (lane 32) The host's squad has stood still for 3 s, this copy's stands or walks more than 15 m from it, and the
    -- two have the same target: the targets agree, the places do not. Seen after a camp fight (sittings s2, s5): the
    -- host's militia halted where the brigands broke (the game halts a squad whose target routs), its TargetLocation
    -- still at the camp; the friend's walked on towards the camp, 105 to 150 m away for minutes. This copy's squad is
    -- sent to the host's place, and is not sent back to that target while the host's stands (M.placeKey).
    -- standing = the host's squad has stayed within 1 m of one place (an anchor) for 3 s; a marching squad moves under
    -- 1 m between two snapshots, so consecutive snapshots are not compared
    if not M.ax or far(M.ax, M.ay, H.cx, H.cy, 100) then M.ax, M.ay, M.aT = H.cx, H.cy, clock end
    -- (lane 38) standing = 1.5 s within 1 m, and a squad more than 4 m off is sent (lane 32: 3 s and 15 m). The lead's
    -- camp fight: the friend's militia chased the routing brigands 22 m while the host's stood; the halt came a second
    -- late and the 15 m rule never brought it back closer than 15 m.
    local hostStands = (not L38 and clock - M.aT >= 3.0) or (L38 and hostStill(M, H))
    local placeTol = L38 and 200 or 1500     -- (round 2) 2 m (round 1: 4 m)
    -- (lane 38) a stale target: the host's squad has stood 1.5 s more than 10 m from a target that has not changed for
    -- 3 s (its target fled or died and the game halted it; s3: the friend's militia walked off towards the camp after
    -- the brigands broke, 10 m in 2 s). Its place counts, not its target.
    -- "stands" here also by its motion (under 0.5 m/s of wall time): the anchor above is kept only in this branch and
    -- starts again when the squad comes out of a fight (s4: the friend's militia walked 12 m towards the camp first)
    local still = L38 and hostStill(M, H)
    -- (round 2) a place, once taken, holds until the host's target changes or its squad clearly walks (over 1 m/s of
    -- wall time): s11, one sample without "stands" let the target rule send the friend's militia 165 m off to the camp
    -- one test (round 2): the host's target counts while it changed in the last 3 s or the host's squad walks (by its
    -- own clock); otherwise its place counts when it stands more than 10 m from that target
    local followTarget = L38 and (clock - (M.keyT or clock) < 3.0 or not still)
    if M.placeKey and (M.placeKey ~= key or (not L38 and not hostStands) or (L38 and followTarget)) then M.placeKey = nil end
    if L38 and not M.placeKey and not followTarget and far(H.cx, H.cy, H.tx, H.ty, 1000) then M.placeKey = key; mtr(h, "stale") end
    local dist = math.sqrt((st.cx - H.cx) ^ 2 + (st.cy - H.cy) ^ 2)
    local off = L38 and dist > placeTol or (not L38 and far(st.cx, st.cy, H.cx, H.cy, placeTol))
    -- (lane 55's "campfollow" for a camp squad made by a plain spawn was tried here and taken out, lane 52 round 3:
    -- on this code the old path's squad is within the rule without it (qb1 2.1 / 2.7 m, qb2 1.0 / 3.1 m) and no
    -- better with it (q1 2.7 / 2.9 m, q2 1.3 / 2.7 m): the held men no longer go back to their formation.)
    if M.placeKey then
      if L38 and st.tgt ~= 0 and not st.eng and clock - M.t >= 0.3 then M.t = clock; touch(h); sc:SetSkillActive({ Value = h }, HALT, true, true); mtr(h, "halt")
      -- (lane 38) at most 3 sends to one place: a squad whose formation cannot come closer than 4 m to the host's centre
      -- (another shape) is not re-formed every 2 s for ever (s6: 127 re-forms of a standing company in 4 minutes)
      elseif not st.eng and not MH and off and clock - M.t >= (L38 and 2.0 or 6.0) and not (L38 and M.placeN and M.placeN >= 3 and M.placeNKey == key and dist < 800) then
        if L38 then sendPlace(S, h, M, H, st, key, clock, "place") else M.t = clock; touch(h); moveOrder(h, where); mtr(h, "place") end
      end
    -- (lane 48) not for a squad whose men lane 43's table holds (they have the host's places; the move would let them
    -- go: c1, the militia standing after the camp fight 9 m from its own target on the host, was sent to that target,
    -- its men let go at the order, 11.5 m off for 3 s). Once the host's squad walks, its lines (MV / MF) end "held".
    elseif not MH and far(st.tx, st.ty, H.tx, H.ty, tol) and clock - M.t >= 1.0 and (M.key ~= key or clock - M.t >= 4.0) then
      M.t = clock; M.key = key; M.aimKey = nil; touch(h); moveOrder(h, target); S.stats.moves = (S.stats.moves or 0) + 1; mtr(h, "move")
    -- (round 3) the move this mirror gave left this copy's target place more than 2 m from the host's (the game puts the
    -- line's centre by its own reckoning; s21m: the company's 2 km march aimed 5.8 m beside the host's, and the two
    -- parallel lines opened to 7 m): once per target, the move again, aimed the error further
    -- (lane 52, round 3, second helper) only while this copy's squad is still more than 10 m from the host's target (on
    -- its way). z4, the end of a rout: the move had brought the friend's militia to 0.4 m from the host's, its target
    -- place still read 6 m off, and this second move sent it 6.8 m past the host's standing squad for a second (5.7 m off
    -- the host's track). Test switch, friend console: Coop.m52aim = false gives the old rule.
    elseif L38 and not MH and M.key == key and M.aimKey ~= key and clock - M.t >= 1.0 and math.sqrt((st.tx - H.tx) ^ 2 + (st.ty - H.ty) ^ 2) > 200
           and (C.m52aim == false or far(st.cx, st.cy, H.tx, H.ty, 1000)) then
      M.aimKey = key; M.t = clock; touch(h)
      moveOrder(h, { X = H.tx + (H.tx - st.tx), Y = H.ty + (H.ty - st.ty), Z = H.tz }); S.stats.aimFix = (S.stats.aimFix or 0) + 1; mtr(h, "aimfix")
    elseif st.tgt ~= 0 and not H.eng and clock - M.t >= (L38 and 0.3 or 1.0) then
      M.t = clock; touch(h); sc:SetSkillActive({ Value = h }, HALT, true, true); mtr(h, "halt")
    -- (lane 38) not for a camp's squad that holds its camp on both copies: its men walk about the camp on each copy
    -- by themselves (2 m median, up to 6 m apart, lane 32 s10a) and it takes no move order anyway
    elseif hostStands and not MH and not st.eng and off and clock - M.t >= (L38 and 2.0 or 4.0) and not (L38 and H.ctl == ENCAMPED and st.ctl == ENCAMPED) and not (L38 and M.placeN and M.placeN >= 3 and M.placeNKey == key and dist < 800) then
      M.placeKey = key; S.stats.standFix = (S.stats.standFix or 0) + 1
      if L38 then sendPlace(S, h, M, H, st, key, clock, "standfix") else M.t = clock; touch(h); moveOrder(h, where); mtr(h, "standfix") end
      if S.stats.standFix <= 10 then log("mirror: squad %d is %.0f m from the host's, which stands still with the same target: sent to the host's place", h, math.sqrt((st.cx - H.cx) ^ 2 + (st.cy - H.cy) ^ 2) / 100) end
    end
    -- (round 2) facing: both stand (1.5 s), within 2 m, not fighting, no target, the host's men in a line (6 m long or
    -- more) whose facing has held for 1.5 s (not a heap after a fight: s11 turned one, 103 degrees) and this copy's
    -- men face more than 15 degrees off: the same send as above (a line along the host's facing, as long as the
    -- host's); two such turns per place at most, apart from the place sends. Round 1's try drew the line across the
    -- facing (90 degrees off) and at the host's width (20 m wide), then re-formed for ever; p2 measured the order.
    if L38 and not MH and (hostStands or still) and M.face and (M.len or 0) >= 600 and M.faceT0 and clock - M.faceT0 >= 1.5 and not st.eng and st.tgt == 0 and H.tgt == 0 and not off
       and H.ctl ~= ENCAMPED and clock - M.t >= 2.0 and not (M.faceNKey == key and (M.faceN or 0) >= 2) then
      if not M.fax or far(M.fax, M.fay, st.cx, st.cy, 100) then M.fax, M.fay, M.faT = st.cx, st.cy, clock end
      if clock - M.faT >= 1.5 then
        local mf = faceOf(h)
        if mf and angDiff(mf, M.face) > 15 then
          if M.faceNKey ~= key then M.faceNKey = key; M.faceN = 0 end
          S.stats.faceFix = (S.stats.faceFix or 0) + 1
          sendPlace(S, h, M, H, st, key, clock, string.format("face%.0f", angDiff(mf, M.face)))
          if M.sendT == clock then M.placeN = M.placeN - 1; M.faceN = M.faceN + 1 end
        end
      end
    end
  end
  if st.push ~= H.push and clock - M.pt > 1.0 then M.pt = clock; touch(h); sc:SetPushStance({ Value = h }, H.push, false, false) end
  -- The host's behaviour stance and lasting skills (shield wall, follow roads, fire at will ...). Until session 21
  -- only the push stance was followed: a squad the host put in shield wall stood open on a friend's screen.
  -- Halt, sprint and spread out are moments the mirror uses itself, not states to copy.
  -- (lane 32) Another lord's squad runs when the host's runs: the brigands that leave their camp sprint on the host
  -- (skill 9), and a friend's walked behind by up to 34 m (sittings s2, s5). The player's own squads keep the rule
  -- below (sprint is the player's moment, sent as his own order).
  -- (lane 38) and the player's own squads too: the host's sprint ended by its men's stamina 4 s before the friend's,
  -- whose militia then stood 37 m ahead for 40 s (the lead's camp fight). The player's own sprint still goes to the
  -- host as his order first (the guards at the top of this function hold the mirror off for 2 s).
  if (L38 or not S.mine[h]) and H.sk and clock - (M.sprT or 0) > 1.0 then
    local hs, ours = false, false
    for _, k in ipairs(H.sk) do if k == SPRINT then hs = true end end
    for _, k in ipairs(st.sk) do if k == SPRINT then ours = true end end
    if hs ~= ours then M.sprT = clock; if S.mine[h] then touch(h) end; pcall(function() sc:SetSkillActive({ Value = h }, SPRINT, hs, true) end); S.stats.sprint = (S.stats.sprint or 0) + 1; mtr(h, hs and "sprint" or "walk") end
  end
  if H.behav and st.behav ~= H.behav and clock - (M.bt or 0) > 1.0 then M.bt = clock; touch(h); pcall(function() sc:SetBehaviourStance({ Value = h }, H.behav, false) end) end
  if H.sk and clock - (M.skT or 0) > 1.0 then
    local want, have, changed = {}, {}, false
    -- Raiding (19) is never set here, and taken off when this copy's squad has it: with it, this copy's raiders
    -- torched buildings by themselves (lane 24: 7 fires and 18 ruins here against the host's 2 and 13). The host's
    -- fires come over as BURN / FIREOUT; the raiders here only walk where the host's walk.
    for _, k in ipairs(H.sk) do if k ~= HALT and k ~= SPRINT and k ~= SPREAD and k ~= RAIDING then want[k] = true end end
    for _, k in ipairs(st.sk) do if k ~= HALT and k ~= SPRINT and k ~= SPREAD then have[k] = true end end
    for k in pairs(want) do
      if not have[k] then
        -- a skill this copy's game does not allow right now (shield wall while its squad is engaged) is not forced:
        -- the game drops it at once, and five such tries in a row stopped the mirror for a minute (lane 4, session
        -- 21). It is set as soon as this copy allows it.
        local okA, av = pcall(function() return sc:isSkillAvailableForSquad({ Value = h }, k, {}) end)
        if okA and av == false then S.stats.skillsWait = (S.stats.skillsWait or 0) + 1
        else pcall(function() sc:SetSkillActive({ Value = h }, k, true, true) end); changed = true end
      end
    end
    for k in pairs(have) do if not want[k] then pcall(function() sc:SetSkillActive({ Value = h }, k, false, true) end); changed = true end end
    if changed then
      M.skT = clock; touch(h); S.stats.skillsSet = (S.stats.skillsSet or 0) + 1
      -- a skill this copy keeps dropping (or keeps) against the host would be set again every second: say so, and
      -- after five tries in a row leave that squad's skills alone for a minute
      M.skN = (M.skN or 0) + 1
      if M.skN <= 5 then log("mirror: squad %d skills set to the host's [%s] (%d)", h, table.concat(H.sk, "+"), M.skN) end
      if M.skN >= 5 then M.skT = clock + 60.0; M.skN = 0; log("mirror: squad %d keeps differing in skills: left alone for a minute", h) end
    else M.skN = 0 end
  end
end

local function friendInbox()
  local S = C.s; local sc = S.sc
  local lines, ends = recv("host")
  for i, line in ipairs(lines) do
    local w = words(line); local kind = w[3]
    S.lineEnd = ends[i]                                -- (join) where this line ends in the host's file as this copy has it
    -- (lane 44) the host's goodbye (BYE) and "loading" (HL) count in every state, also during a join (coop_session.lua)
    if (kind == "BYE" or kind == "HL") and C.session then pcall(C.session.line, S, w) end
    if C.hold and kind ~= "J" then kind = nil end      -- a join or repair is in progress: only join messages count
    -- (join) A single friend's resync: this copy alone loaded a save the host took while it kept running, and is now
    -- reading again what the host sent since that save (rewind above). Those lines are applied in order like live
    -- ones, with three differences:
    --   * state lines (S) are skipped: only the newest squad state counts, and it follows live within a moment;
    --   * a town line of this player's own (the host applied it after the save) is applied here like anybody
    --     else's: the fresh world does not have it. Live, an own line coming back is ignored (coop_town.lua);
    --   * the host's refusal of one of this player's actions is skipped: the fresh world never had that action.
    local rp = S.replay
    if rp then
      if not ends[i] or ends[i] > rp.to then
        log("join: read again %d lines the host sent while this copy loaded (%d state lines skipped, %d own town lines applied, %d refusals skipped) in %.2f s", rp.n, rp.skipS, rp.own, rp.nak, os.clock() - rp.t)
        S.replay = nil
      elseif kind then
        rp.n = rp.n + 1
        if kind == "S" then rp.skipS = rp.skipS + 1; kind = nil
        elseif kind == "T" and w[6] == "NAK" and (w[7] or ""):sub(1, #S.name + 1) == S.name .. ":" then rp.nak = rp.nak + 1; kind = nil
        elseif kind == "T" and w[4] == S.name then w[4] = S.name .. "~"; rp.own = rp.own + 1 end
      end
    end
    if kind == "S" then
      S.stats.states = (S.stats.states or 0) + 1; S.lastStateWall = tonumber(w[2])
      local hs, hp, hclk = tonumber(w[4]), w[5] == "1", tonumber(w[6])
      S.hostSpeed = hs; S.hostPaused = hp
      -- Follow the host's pause and speed, except for a moment after this player changed them (the change is on its
      -- way to the host and comes back with the next state). If this copy's clock is behind the host's (a tutorial page
      -- held it, a slow frame), run a little faster until it has caught up; if ahead, a little slower.
      if S.cfg.followSpeed and os.clock() >= (S.speedHold or 0) then
        -- S.agree: this copy's pause and speed were seen equal to what the mod set. Whenever the mod sets something
        -- new it is false until the game shows it; only a change away from an agreed state is the player's own
        -- (session 17: right after a resync the friend's fresh speed 1 was sent to the host as if the player chose it).
        if hp ~= isPaused() or (not hp and S.p1.bIsPlayerPaused) then setPaused(hp); S.agree = false end
        -- Catching up with the host's clock goes through the engine's time scale, never through the game speed: the
        -- game speed stays exactly the host's button value (1, 4 or 8). First session between two PCs (2026-11-11): a
        -- catch-up speed such as 1.18 or 4.90 made the HUD show "paused" (it knows only the button values), and when
        -- the friend un-paused, that odd speed went to the host as if he had chosen it. Measured: time scale 2 at
        -- game speed 1 runs the game clock 2.04 times as fast, and the game does not touch the time scale itself.
        local dil = 1.0
        if not hp and hclk and hclk > 0 then
          local gap = hclk - gameClock()                                  -- in game days
          if gap > 0.02 then dil = math.min(3.0, 1.0 + gap * 4.0) elseif gap < -0.02 then dil = math.max(0.5, 1.0 + gap * 4.0) end
          S.clockGap = gap
        end
        -- (lane 47, round two) the engine's time scale and its pause are asked of the game at most every 0.25 s (or
        -- at once when the wanted scale changed), not at every state line (20 a second): the game itself changes
        -- neither (only a full screen pauses it; it is then let run at most 0.25 s later than before)
        local dk = math.floor(dil * 50 + 0.5)
        if dk ~= S.dilK or os.clock() - (S.dilT or 0) >= 0.25 then S.dilK = dk; S.dilT = os.clock(); pcall(function()
          local GS = S.GS; if not valid(GS) then GS = StaticFindObject("/Script/Engine.Default__GameplayStatics"); S.GS = GS end
          if math.abs(GS:GetGlobalTimeDilation(S.p1) - dil) > 0.02 then GS:SetGlobalTimeDilation(S.p1, dil) end
          -- (lane 20) The game's full screens pause the engine as well as the speed (setGamePausedInclVamp calls
          -- SetGamePaused; measured). With only the speed put back (above, below), this copy stood still behind the
          -- open screen: a "Cold!" popup that only the friend's game showed held its clock at day 299.000 while the
          -- host ran on to day 305 (lane_s21_20 report). Time runs on behind a full screen, as the speed rule intends.
          if not hp and os.clock() - (S.worldT or 0) > 10.0 and GS:IsGamePaused(S.p1) then
            GS:SetGamePaused(S.p1, false); S.stats.engineUnpaused = (S.stats.engineUnpaused or 0) + 1
            if S.stats.engineUnpaused <= 5 then log("speed: this copy's game had paused itself behind a screen while the host runs: time runs on (%d)", S.stats.engineUnpaused) end
          end
        end) end
        if not hp and math.abs(S.eng.gameSpeed - hs) > 0.02 then S.eng:setGameSpeed(hs); S.agree = false end
        S.setPaused = hp; S.setSpeed = hp and S.setSpeed or hs
      end
      allSquads()
      local clockNow = os.clock(); S.seenT = S.seenT or {}
      if w[8] == "F" then S.fullN = (S.fullN or 0) + 1; S.lastFullT = clockNow end      -- a full list: every squad the host has
      if w[7] and w[7] ~= "-" then for entry in w[7]:gmatch("[^;]+") do
        local f = {}; for x in entry:gmatch("[^,]+") do f[#f + 1] = x end
        local H = { h = toLocal(tonumber(f[1])), hh = tonumber(f[1]), n = tonumber(f[2]), ctl = tonumber(f[3]), tgt = toLocal(tonumber(f[4])), tx = tonumber(f[5]), ty = tonumber(f[6]), tz = tonumber(f[7]),
                    push = tonumber(f[8]), behav = tonumber(f[9]), cx = tonumber(f[11]), cy = tonumber(f[12]), eng = f[13] == "1", rs = tonumber(f[14]), wall = tonumber(w[2]), run = tonumber(f[15]), spd = f[16] and tonumber(f[16]) / 10, face = tonumber(f[17]), len = f[18] and tonumber(f[18]) * 10 }
        H.sk = {}; if f[10] and f[10] ~= "-" then for k in f[10]:gmatch("%d+") do H.sk[#H.sk + 1] = tonumber(k) end end
        if H.h and H.n then
          S.host[H.h] = H; S.seenT[H.h] = clockNow
          -- (lane 47, round two) a squad whose entry is the very text of the last one (nothing changed on the host) is
          -- mirrored again at most every 0.25 s, not at every state line (20 a second; mirror reads the squad's whole
          -- state through the game, about 25 values): a change on the host is mirrored at once as before; a squad of
          -- this copy that drifted from an unchanged host entry is corrected at most 0.25 s later
          local MM = S.mirE or {}; S.mirE = MM; local last = MM[H.h]
          if not (last and last.e == entry and clockNow - last.t < 0.25) then
            if last then last.e = entry; last.t = clockNow else MM[H.h] = { e = entry, t = clockNow } end
            local ok, e = pcall(mirror, H); if not ok then S.nerr = S.nerr + 1; S.lastErr = "mirror: " .. tostring(e) end
          else S.stats.mirrorSame = (S.stats.mirrorSame or 0) + 1 end
        end
      end end
      -- The host's full list is the truth for every squad that is not the player's (bandit groups are rolled by each
      -- copy: session 17). Each time a full list arrives (4 times a second), a squad that is not on it is removed here
      -- at once (the user's rule, session 19). A new squad on the host is announced ("N") in the line before the list
      -- that first holds it, so it is never removed by mistake. The first two lists after a load are skipped.
      --   status: the 8 s and 2 s versions of this rule ran live (README session 19); this immediate form: see README
      if w[8] == "F" and not C.hold then
        if S.fullWorld ~= S.worlds then S.fullWorld = S.worlds; S.fullSeen = 0 end
        S.fullSeen = S.fullSeen + 1
        if S.fullSeen >= 3 then
          for _, h in ipairs(allSquads()) do
            S.removing = S.removing or {}
            if sqValid(h) and not S.mine[h] and S.seenT[h] ~= clockNow and clockNow - (S.removing[h] or -10) > 2.0 and not (S.rmQ and S.rmQ[h]) then
              S.removing[h] = clockNow                     -- the game takes a moment to remove it: ask once
              S.stats.orphans = (S.stats.orphans or 0) + 1
              pcall(removeSafe, h, "exists here but not on the host")
            end
          end
        end
      end
    elseif kind == "D" then       -- D <squad> <places>: the soldiers at these places (sorted by id) died on the host
      local h = toLocal(tonumber(w[4])); local n = 0
      if sqValid(h) then
        local list = aliveList(h); local doomed = {}; local taken = {}
        local toks = {}; if w[6] then for t in w[6]:gmatch("[^,]+") do toks[#toks + 1] = t end end
        local k = 0
        for p in (w[5] or ""):gmatch("%d+") do
          k = k + 1
          local e = nil
          -- a named man (militia) is found by his mark; without a mark, or when nobody here has it, by his place
          local tok = toks[k]
          if tok and tok ~= "-" then for _, x in ipairs(list) do if x.tok == tok and not taken[x] then e = x; S.stats.deathsByName = (S.stats.deathsByName or 0) + 1; break end end end
          if not e then e = list[tonumber(p)]; if e and taken[e] then e = nil end end
          if e and valid(e.u) then taken[e] = true; doomed[#doomed + 1] = e.u end
        end
        for _, u in ipairs(doomed) do hostKill(u); n = n + 1 end
      end
      S.stats.deaths = (S.stats.deaths or 0) + n
    elseif kind == "MT" then      -- MT <host squad> <marks>: the men of another lord's militia unit on the host (round 2)
      local h = toLocal(tonumber(w[4]))
      if h and w[5] then S.hostToks = S.hostToks or {}; local set = {}; for x in w[5]:gmatch("[^,]+") do set[x] = true end; S.hostToks[h] = set end
    elseif kind == "HOLD" then    -- HOLD 1|0: the host's world stands still behind a game screen (the S line says "paused")
      if w[4] == "1" then
        if not S.hostHold or os.clock() - (S.hostHoldSaid or 0) >= 30.0 then C.notify("info", "The host has a game screen open: the game waits"); S.hostHoldSaid = os.clock() end
        S.hostHold = true
      else
        if S.hostHold then C.notify("info", "The host closed the screen: the game runs again") end
        S.hostHold = false
      end
    elseif kind == "G" then
      local h = toLocal(tonumber(w[4])); if C.men and C.men.squadGone then pcall(C.men.squadGone, h) end   -- (lane 43)
      if sqValid(h) then removeSafe(h, "gone on the host") end
    elseif kind == "N" then       -- N <host number> <unit type> <owner> <x> <y> <z> <count>: a squad was created on the host
      local hh = tonumber(w[4])
      -- (join) "R" at the end: the host names every squad again after a friend loaded alone (C.announceAll). A copy
      -- that has the squad makes nothing: the host's number is tied to a local squad, or a local squad carries the
      -- host's own number, is tied to no other host squad and is of the same unit type (both have it from one save).
      local again = false
      if hh and w[12] == "R" then
        local have = S.h2l[hh] ~= nil
        if not have and sqValid(hh) and not S.l2h[hh] then
          local okT, typ = pcall(function() return sc:GetSquad({ Value = hh }).unitType:ToString() end)
          have = okT and typ == w[5]
        end
        if have then hh = nil else again = true end
      end
      if hh and not again and not S.h2l[hh] and w[11] and w[11] ~= "-" then
        local who, mineH = w[11]:match("^([^:]+):(%d+)$"); mineH = tonumber(mineH)
        if who == S.name and mineH and sqValid(mineH) then
          S.h2l[hh] = mineH; S.l2h[mineH] = hh
          log("the unit this player raised (%d) is unit %d on the host", mineH, hh)
        end
      end
      if hh and not S.h2l[hh] then
        local owner = S.p1
        if w[6] == "B" then for _, pw in ipairs(pawns()) do if valid(pw) and pw.isBandit then owner = pw end end
        elseif w[6]:sub(1, 1) == "A" then local pw = S.eng:getPawnBySetupIndex(tonumber(w[6]:sub(2)) or -1); if valid(pw) then owner = pw end end
        local lh, how
        -- The player's own new militia unit (army panel, "+"): on the host it starts empty and fills when rallied. Make
        -- it here the same way, with the game's own call, so it is a real militia unit of this town's families and not
        -- a ready-made stand-in (session 19: the stand-in had 32 soldiers against the host's 0).
        -- The same for a RIVAL lord's new militia unit (2026-11-12, two runs of the test save, day 368: the host's
        -- "spearMilitia A2" had 0 soldiers, the ready-made stand-in here 32, a militia unit is never trimmed, and the
        -- daily comparison asked for a resync: soldiersA2:0/32). Only when that lord's own pawn was found here.
        local milOwner = (w[6] == "P") and S.p1 or ((w[6]:sub(1, 1) == "A" and valid(owner) and owner ~= S.p1) and owner or nil)
        if milOwner and w[5]:find("Militia") and (tonumber(w[10]) or 0) == 0 then
          local before = {}
          local arr = milOwner.commandedSquads; for i = 1, #arr do before[arr[i].Value] = true end
          pcall(function() milOwner:addMilitiaSquad(milOwner:getClosestOwnedRegion(), FName(w[5])) end)
          arr = milOwner.commandedSquads; for i = 1, #arr do local v = arr[i].Value; if v ~= 0 and not before[v] then lh = v; how = "militia unit" end end
        end
        -- (lane 32) An empty squad that is not a militia unit (seen: the player's retinue_tier1 made on the host, 0 men,
        -- when the player won a settled region in battle) is not made here as a full ready-made squad: the stand-in had
        -- 36 men against the host's 0 and the daily comparison asked for a resync (soldiersP 45/81, sitting s6).
        if not lh and (tonumber(w[10]) or 0) == 0 then
          S.emptyN = S.emptyN or {}
          if not S.emptyN[hh] then S.emptyN[hh] = true; log("host squad %d (%s, %s) has no men: nothing made here", hh, w[5], w[6]) end
          lh = -1
        end
        -- (lane 48, round 3) a new camp's brigands: the camp and the game's own squad of it (E.campAt), not a squad
        -- of its own beside the one the camp's making brings (m2, t7: that one stood 0.6-1.4 km away for 4.4 s)
        if not lh and w[6] == "B" and C.events and C.events.campAt then
          local cx, cy, cz; for i = 12, #w do local a, b, c = (w[i] or ""):match("^camp=(%-?%d+),(%-?%d+),(%-?%d+)$"); if a then cx, cy, cz = tonumber(a), tonumber(b), tonumber(c) end end
          if cx then
            local okC, hc, why = pcall(C.events.campAt, S, cx * 10.0, cy * 10.0, cz, tonumber(w[7]), tonumber(w[8]), tonumber(w[9]), owner)   -- the camp at the dm the host's camp list names
            if okC and hc then lh = hc; how = "camp and its squad"; S.campSq = S.campSq or {}; S.campSq[hc] = true; log("%s", tostring(why))
            else log("host squad %d holds a new camp: not made with it here (%s)", hh, tostring(okC and why or hc)) end
          end
        end
        if not lh then
          lh = S.eng:spawnCompleteUnit(FName(w[5]), { X = tonumber(w[7]), Y = tonumber(w[8]), Z = tonumber(w[9]) }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, owner, 0, 0).Value
          how = "squad"
        end
        if lh == -1 or not lh or lh == 0 then
        else
        S.modSquadT = os.clock()                             -- the speed watcher: a speed change right now is the game's answer, not the player's
        S.h2l[hh] = lh; S.l2h[lh] = hh; S.pawnsT = 0; S.stats.created = (S.stats.created or 0) + 1
        S.madeHere = S.madeHere or {}; S.madeHere[lh] = true      -- (lane 48) made by this copy: never a host number's own
        -- (lane 48) the camp's squad was made at the place the game rolled and its men were put at the host's: its
        -- target place goes there too, or they would walk back (the mirror takes over from the host's next state)
        if how == "camp and its squad" then pcall(function() touch(lh); moveOrder(lh, { X = tonumber(w[7]), Y = tonumber(w[8]), Z = tonumber(w[9]) }) end) end
        -- (lane 52, round 3, second helper: holding its men where they were put until the host's first line was tried and
        -- taken out. q9: they still ran 5.8 m towards the place the game had rolled for half a second, held or not; q10:
        -- the move order above let them go again, they were held at the put places once more and stood 7 to 8 m behind
        -- the host's squad for 2.5 s while it walked to its camp)
        -- a squad made from a repeated announcement is an older squad of the host's that may have lost men: its
        -- head count follows the host's from the start (the mirror's rule for a squad that has matched once)
        if again then S.mir[lh] = { t = os.clock(), pt = 0, matched = true }; S.stats.madeAgain = (S.stats.madeAgain or 0) + 1 end
        log("created %s for host %d as local %d (%s, %s)%s", how, hh, lh, w[5], w[6], again and ": this copy did not have it after loading alone" or "")
        end
      end
    elseif kind then C.dispatch("host", w, line) end
  end
end

-- friend's copy never decides a fight: enemy lords' decisions off, nobody can hurt anybody
local function friendUpkeep()
  local S = C.s
  local f = S.eng.drawDebugFlags; local has = false
  for i = 1, #f do if un(f[i]):ToString() == "disableAI" then has = true end end
  if not has then f[#f + 1] = FName("disableAI"); log("enemy decisions switched off") end
  -- With the native piece on, this copy cannot kill in combat at all (arrows included), so the soldiers keep their real
  -- numbers. Without it, the numbers below stop melee deaths only (arrows still kill: README session 16).
  local nat = C.patch and C.patch.fn and C.patch.status and C.patch.status()
  -- (lane 52) the stand-in below writes def and block 10000, and the game's stamina tick (4D8E1D0) takes a sprinting
  -- man's stamina by (1 + 0.065 def + 0.13 block) x 0.0015 a step: such a man has none left within a second of a sprint
  -- and walks the rest of a charge (lane 48's r2: the friend's militia and company 230-250 m behind the host's, which
  -- sprinted). It ran whenever the native NOKILL was not read as "on" at that moment: the first ticks of a world (before
  -- NOKILL ON is sent), a status read between two writes. So with the native piece loaded it runs only when P1 is
  -- really unavailable (another game build), and the men it changed get their own numbers back once P1 is on.
  if nat then
    local p1 = nat.items and nat.items.P1
    if p1 and p1.state == "on" then
      S.nativeNoKill = true; S.p1WaitT = nil
      if S.nkOrig and next(S.nkOrig) then
        local n = 0
        for a, o in pairs(S.nkOrig) do if valid(o.u) then pcall(function() local u = o.u; u.att = o.att; u.rangedAtt = o.ra; u.charge = o.ch; u.armorPierce = o.ap; u.def = o.def; u.block = o.bl end); n = n + 1 end; S.nkOrig[a] = nil end
        log("NOKILL on natively: %d men got their own fight numbers back (the stand-in had set them)", n)
      end
      return
    end
    -- not decided yet (scanning, or NOKILL ON not applied yet): wait for the native piece; but the DLL gone "off"
    -- (internal failures: every patch out) or P1 still not on after 5 s counts as unavailable, so a friend is never
    -- left without either guard
    local stuck = false
    if not (p1 and p1.state == "unavailable") and nat.state ~= "off" then
      S.p1WaitT = S.p1WaitT or os.clock(); stuck = os.clock() - S.p1WaitT > 5.0
      if not stuck then return end
    end
  end
  S.nativeNoKill = false
  S.nkOrig = S.nkOrig or {}
  -- (lane 52, round 2) the attack numbers are 0 always; def and block 10000 only while the squad is engaged. The
  -- stamina tick reads def and block only for a squad that is NOT engaged (a raised squad's sprint: the formula above);
  -- an engaged squad loses stamina at a flat rate (0.001 a step, the Squad's isEngaged +36Bh), and a melee happens only
  -- there. Out of the fight the men have their own def and block again, so a sprint costs what it costs on the host.
  for _, h in ipairs(allSquads()) do
    if sqValid(h) then
      local list = unitsOf(h); local K = S.sq[h]
      local eng = false; pcall(function() eng = S.sc:GetSquad({ Value = h }).isEngaged and true or false end)
      if #list > 0 and (not K or K.n ~= #list or list[1].att ~= 0.0 or K.eng ~= eng) then
        for _, u in ipairs(list) do
          local a = u:GetAddress(); local o = S.nkOrig[a]
          if not o then o = { u = u, att = u.att, ra = u.rangedAtt, ch = u.charge, ap = u.armorPierce, def = u.def, bl = u.block }; S.nkOrig[a] = o end
          u.att = 0.0; u.rangedAtt = 0.0; u.charge = 0.0; u.armorPierce = 0.0
          if eng then u.def = 10000.0; u.block = 10000.0 else u.def = o.def; u.block = o.bl end
        end
        S.sq[h] = { n = #list, eng = eng }; S.stats.nokill = (S.stats.nokill or 0) + 1
      end
    end
  end
end

-- ---------------------------------------------------------------- driver
-- Test switch link/dev_crumbs.txt: in the first three ticks after a world attaches a log line is written BEFORE every
-- step of the tick, so the last line of a dead copy's log names the step it died in (the log is closed after each line).
-- (lane 47, round three) test switch link/dev_trace.txt: every step of every tick is also written over the first line
-- of link/<name>_trace.txt (kept open, flushed): after a close it names the step the copy died in. C.trace(what) lets a
-- module name its own steps the same way.
local TPAD = string.rep(" ", 60) .. "\n"
local function trace(what) local tf = C.traceF; if tf then tf:seek("set", 0); tf:write(what, TPAD); tf:flush() end end
C.trace = trace
local function crumb(S, what) if S.crumbOn then log("crumb: %s", what) end; if C.traceF then trace(what) end end
-- (lane 47, round three) with the trace switch on and Coop.traceHook = { <module> = true } set from the console, every
-- call into the mod loader (a C function) made during that module's tick is written to the trace too: the called
-- function's name and the first line up the stack that lies in the module's own file (and the line that made the
-- call), written when it changes. Test only: it costs several microseconds a call.
local hookMod, hookLast
local function hookFn()
  local i = debug.getinfo(2, "Sn"); if not i or i.what ~= "C" then return end
  local c = debug.getinfo(3, "Sl"); if not c then return end
  local own, olv = c, nil
  for lv = 3, 10 do local x = debug.getinfo(lv, "Sl"); if not x then break end; if x.short_src:find(hookMod, 1, true) then own = x; olv = lv; break end end
  local loc = string.format("%s %s %s:%d <- %s:%d", hookMod, tostring(i.name), c.short_src:match("[^/\\]*$"), c.currentline or -1, own.short_src:match("[^/\\]*$"), own.currentline or -1)
  -- Coop.traceHookLine = <line>: at that line of the module's file, the key of its local "e" (a board entry) as well
  local hl = rawget(C, "traceHookLine")
  if hl and olv and own.currentline == hl then
    local ev
    for k = 1, 40 do local nm, v = debug.getlocal(olv, k); if not nm then break end; if nm == "e" and type(v) == "table" then ev = v end end
    if not ev then local f = debug.getinfo(olv, "f").func; for k = 1, 40 do local nm, v = debug.getupvalue(f, k); if not nm then break end; if nm == "e" and type(v) == "table" then ev = v; break end end end
    if ev then loc = loc .. " e.key=" .. tostring(rawget(ev, "key")) .. " addr=" .. string.format("%X", math.tointeger(rawget(ev, "addr")) or 0) end
  end
  if loc ~= hookLast then hookLast = loc; trace(loc) end
end

-- ---- lane 45: the core's steps timed (C.cost.step "core:<step>"), by wrapping them here once, so the driver below
-- stays as it is. A wrapper passes every argument and every result through.
do
  local function timed(f, name)
    return function(...)
      local t0 = os.clock()
      local a, b, c = f(...)
      kAdd(name, (os.clock() - t0) * 1000)
      return a, b, c
    end
  end
  hostInbox = timed(hostInbox, "core:inbox"); friendInbox = timed(friendInbox, "core:inbox")
  hostSnapshot = timed(hostSnapshot, "core:snapshot"); watch = timed(watch, "core:watch")
  removeTick = timed(removeTick, "core:upkeep"); friendUpkeep = timed(friendUpkeep, "core:upkeep")
  C.costTimed = timed                  -- the end of this file wraps C.scrubClose, C.scrubQuests, C.quietHelper the same way
end
local function body()
  local S = C.s; local clock = os.clock()
if not C.traceF and clock - (S.traceT or -10) > 5.0 then S.traceT = clock; local tf0 = io.open(LINK .. "dev_trace.txt", "rb"); if tf0 then tf0:close(); C.traceF = io.open(LINK .. S.name .. "_trace.txt", "w+b") end end   -- (lane 47, round three: test switch dev_trace.txt)
  if S.role == "idle" then
    -- Not a co-op game (a solo game, or the title screen before anything was chosen): the mod changes nothing. Only the
    -- menu, the Steam link and the native piece keep ticking, so the player can start hosting or accept an invite.
    objs()
    for name, m in pairs(C.modules) do
      if m.idle then local ok, e = pcall(m.idle, S, clock); if not ok then S.nerr = S.nerr + 1; S.lastErr = name .. ".idle: " .. tostring(e); if S.nerr <= 5 then log("error %d in %s.idle: %s", S.nerr, name, tostring(e)) end end end
    end
    return
  end
  if S.role == "friend" then ensureHooks() end
  if not objs() then
    -- no world (main menu, or a level is loading): only join messages matter, e.g. "load this save" for a friend at the menu
    if clock - S.tIn >= 0.05 then
      S.tIn = clock
      local from = S.role == "friend" and { "host" } or S.peers
      for _, peer in ipairs(from) do
        local lines, ends = recv(peer)
        for i, line in ipairs(lines) do local w = words(line); S.lineEnd = ends[i]; if w[3] == "J" then C.dispatch(peer, w, line)
          elseif S.role == "friend" and (w[3] == "BYE" or w[3] == "HL") and C.session then pcall(C.session.line, S, w) end end   -- (lane 44)
      end
    end
    for name, m in pairs(C.modules) do
      if m.idle then local ok, e = pcall(m.idle, S, clock); if not ok then S.nerr = S.nerr + 1; S.lastErr = name .. ".idle: " .. tostring(e); if S.nerr <= 5 then log("error %d in %s.idle: %s", S.nerr, name, tostring(e)) end end end
    end
    return
  end
  S.crumbOn = (S.crumbN or 0) > 0; if S.crumbOn then S.crumbN = S.crumbN - 1 end
  crumb(S, "tick starts, role " .. tostring(S.role))
  -- (lane 59) A world's first tick: EVERY module's onWorld runs first, before anything else of the tick. Before, the
  -- host's lines were read (and handed to the modules' onMessage) ahead of the modules' onWorld, and inside the module
  -- loop one module's tick ran before another module's onWorld: a module could be asked for, or handed, an object it
  -- had kept from the world before. The modules run in no fixed order (pairs over C.modules: it differs from one
  -- start of the game to the next, lane 59 d1 / d2), so which module met which was a matter of the start.
  local fresh = S.worldSeen ~= S.worlds; S.worldSeen = S.worlds
  if fresh then
    for name, m in pairs(C.modules) do
      if m.onWorld then
        crumb(S, name .. ".onWorld")
        local ok, e = pcall(m.onWorld, S)
        if not ok then S.nerr = S.nerr + 1; S.lastErr = name .. ".onWorld: " .. tostring(e); log("error %d in %s.onWorld: %s", S.nerr, name, tostring(e)) end
      end
    end
  end
  if #S.later > 0 then
    local keep = {}
    for _, L in ipairs(S.later) do if clock >= L.t then local ok, e = pcall(L.fn); if not ok then S.nerr = S.nerr + 1; S.lastErr = "later: " .. tostring(e) end else keep[#keep + 1] = L end end
    S.later = keep
  end
  if S.role == "host" then
    if clock - S.tIn >= 0.02 then S.tIn = clock; crumb(S, "hostInbox"); hostInbox() end
    -- a friend's rally that had to wait for the helper (it was placing a building): try again, give up after 5 s
    if S.rallyQ and next(S.rallyQ) then
      for h, q in pairs(S.rallyQ) do
        if clock - q.t > 5.0 or not sqValid(h) or sqState(h).rs ~= 0 or C.rallyLocal(h, q.x, q.y, q.z) then S.rallyQ[h] = nil end
      end
    end
    -- (lane 51) a friend has left the game when it said goodbye (its BYE line: the pause menu's Main Menu or Quit
    -- button), when Steam says it is no longer in the lobby, or after C.leftSilence s with nothing from it (the
    -- friend's own limit for a silent host, coop_session.lua: 30 s). A silence of 10 s is no leave: l51f2 (a friend
    -- copy's game thread stopped 9 s) and l51c2 (5.9 s) were told "left the game" while the friend played on.
    if clock - (S.tGone or 0) >= 1.0 then
      S.tGone = clock; S.gone = S.gone or {}; S.quiet = S.quiet or {}
      local sid = C.steamSlots and C.steamSlots()
      for _, p in ipairs(S.peers) do
        local h = S.heard and S.heard[p]
        if h and not C.hold and not (C.join and C.join.state) then
          local g = clock - h
          local off = sid and sid.seen[p] and not sid.now[p]          -- out of Steam's lobby for 3 s in a row (not one read)
          S.steamOff = S.steamOff or {}; if off then S.steamOff[p] = S.steamOff[p] or clock else S.steamOff[p] = nil end
          if off and clock - S.steamOff[p] >= 3.0 and not S.gone[p] then C.friendLeft(p, "Steam: no longer in the lobby", "steam")
          elseif g > C.leftSilence and not S.gone[p] then C.friendLeft(p, string.format("nothing from it for %.0f s", g), "silence")
          elseif g > 10.0 and not S.quiet[p] and not S.gone[p] then S.quiet[p] = true; log("%s silent for %.0f s: not told as gone (a goodbye, Steam's word or %.0f s)", p, g, C.leftSilence)
          elseif g <= 10.0 and (S.gone[p] or S.quiet[p]) then
            -- back: after a silence, any line; after Steam's word, in the lobby again and a line since; after a
            -- goodbye, a line 20 s or more after it (the goodbye line itself and the last beats come right after)
            local why, gt = S.goneWhy and S.goneWhy[p], S.goneT and S.goneT[p] or 0
            local back = not S.gone[p] or why == "silence" or (why == "steam" and not off and h > gt) or (why == "bye" and h > gt + 20.0)
            if back then
              if S.quiet[p] then log("%s heard again after %.1f s", p, g) end
              if S.gone[p] then log("%s is back (it had left: %s)", p, tostring(why)); C.notify("joined", ((S.display and S.display[p]) or p) .. " is back") end
              S.gone[p] = nil; S.quiet[p] = nil
            end
          end
        end
      end
    end
    -- (lane 28) orders of this copy's player that only the native piece can see (a path, an order against a building):
    -- the army module reads them here, before this tick's snapshot, so that friends get the order before the squad's
    -- new state
    if C.preOrders then crumb(S, "preOrders"); local okP, eP = pcall(C.preOrders, S, clock); if not okP then S.nerr = S.nerr + 1; S.lastErr = "preOrders: " .. tostring(eP) end end
    if clock - (S.tFast or 0) >= 0.05 then
      S.tFast = clock
      -- (lane 47, round two) every squad's state twice a second (was four times); a squad that moved, fought or got an
      -- order in the last 3 s stays at 20 a second. A change of a quiet squad reaches a friend at most 0.5 s after it
      -- happened (was 0.25 s), then the squad is "hot"
      local full = clock - S.tSnap >= 0.5; if full then S.tSnap = clock end
      crumb(S, "hostSnapshot"); hostSnapshot(full)
    end
  elseif S.role == "friend" then
    -- (lane 28) the same on a friend, before the watcher: a path order must not also go to the host as a plain move
    -- (measured: the host took the move and the path in that order and the squad then walked straight)
    if C.preOrders then crumb(S, "preOrders"); local okP, eP = pcall(C.preOrders, S, clock); if not okP then S.nerr = S.nerr + 1; S.lastErr = "preOrders: " .. tostring(eP) end end
    crumb(S, "watch"); watch()
    if clock - S.tUp >= 0.5 then S.tUp = clock; crumb(S, "removeTick"); removeTick(clock); crumb(S, "friendUpkeep"); friendUpkeep() end
    if clock - S.tIn >= 0.02 then S.tIn = clock; crumb(S, "friendInbox"); friendInbox() end
    if clock - (S.tBeat or 0) >= 3.0 then S.tBeat = clock; send("H") end      -- "still here"
    -- The host heard and now silent for 10 s may have left (closed the game, crashed, lost the link): this player is
    -- told, as the host is told of a friend. Found by lane 29: the host's process ended and the friend saw nothing for 30 s.
    -- Not while this copy loads or joins, and not in the first 10 s of a world (the host's lines are read again then).
    -- (lane 44) Whether the host is GONE (and this copy goes back to the main menu) is decided in coop_session.lua:
    -- after the host's goodbye, or after a silence that no pause, load or hitch makes. Nobody plays on alone.
    if clock - (S.tGoneF or 0) >= 1.0 then
      S.tGoneF = clock; S.gone = S.gone or {}
      local h = S.heard and S.heard["host"]
      if h and not C.hold and not (C.join and C.join.state) and clock - (S.worldT or 0) > 10.0 then
        if clock - h > 10.0 and not S.gone.host and not (C.session and C.session.loadT) then   -- (lane 44) not while the host said it loads
          S.gone.host = true; log("the host has been silent for %.0f s: this player is told", clock - h)
          C.notify("left", "The host is not answering. Waiting for the host")
        elseif clock - h <= 10.0 and S.gone.host then
          S.gone.host = nil; log("the host is heard again"); C.notify("joined", "The host is back")
        end
      end
    end
  end
  crumb(S, "scrubClose"); C.scrubClose(S, clock)
  if clock - (S.tQScrub or 0) >= 1.0 then
    S.tQScrub = clock
    local f = io.open(LINK .. "dev_noqscrub.txt", "rb"); S.qscrubOff = f ~= nil; if f then f:close() end
    crumb(S, "scrubQuests"); C.scrubQuests(S)
  end
  if clock - (S.tQuiet or 0) >= 2.0 then S.tQuiet = clock; crumb(S, "quietHelper"); C.quietHelper() end
  -- plug-in modules (town actions, world state, joining): each gets the same tick, on the game thread
  -- (lane 47) the native piece's snapshot tables are read at the start of the frame, before any module
  -- (coop_snap.lua N.frame: the native coop_snap_tick, then its answer): every module of the frame sees this frame's
  -- values; the native piece's own tick (commands) keeps its place among the modules
  local Nsn = rawget(C, "snap"); if Nsn and Nsn.frame then local k0 = os.clock(); pcall(Nsn.frame); kAdd("snap:frame", (os.clock() - k0) * 1000) end
  if fresh and not S.orderSaid then S.orderSaid = true; local o = {}; for name in pairs(C.modules) do o[#o + 1] = name end; log("modules, in the order they run: %s", table.concat(o, " ")) end
  for name, m in pairs(C.modules) do
    -- (lane 35, round six) the mod stopped inside this tick (Coop.stop from the dev channel, which runs in a module's
    -- tick): no other module runs after it. Before, the job board switched the gate on again in the same frame and,
    -- with no tick after the stop, a friend kept the JG byte on and the job list full (acceptance run acc1).
    if not S.on then break end
    if m.tick then
      crumb(S, name .. ".tick")
      local hk = C.traceF and rawget(C, "traceHook") and C.traceHook[name]      -- (lane 47, round three: test switch only)
      if hk then hookMod = type(hk) == "string" and hk or ("coop_x_" .. name); hookLast = nil; debug.sethook(hookFn, "c") end
      local k0 = os.clock(); local ok, e = pcall(m.tick, S, clock); kAdd(name, (os.clock() - k0) * 1000)
      if hk then debug.sethook() end
      if not ok then S.nerr = S.nerr + 1; S.lastErr = name .. ".tick: " .. tostring(e) end
    end
  end
  crumb(S, "tick done")
end

-- ---------------------------------------------------------------- plug-in modules
-- A module is a table with any of: onWorld(S) (a world was loaded: drop cached objects), tick(S, clock) (every frame),
-- onMessage(S, from, kind, words, line) (a link message whose kind the core does not know; return true when handled).
-- Message kinds used by the core: O (order), S (state), D (deaths), G (squad gone), N (new squad). Modules pick other letters.
C.modules = C.modules or {}
function C.register(name, mod) C.modules[name] = mod; return mod end
function C.dispatch(from, w, line)
  for name, m in pairs(C.modules) do
    if m.onMessage then
      local k0 = os.clock()
      local ok, r = pcall(m.onMessage, C.s, from, w[3], w, line)
      local d = os.clock() - k0                                -- lane 45: the module that took the line, or that spent time on it
      if r or d > 0 then local mn = K.msgName[name]; if not mn then mn = name .. ":msg"; K.msgName[name] = mn end; kAdd(mn, d * 1000) end
      if not ok then C.s.nerr = C.s.nerr + 1; C.s.lastErr = name .. ".onMessage: " .. tostring(r) elseif r then return true end
    end
  end
  return false
end
-- what modules may use. S fields: role ("host"/"friend"), name, peers, eng, p1 (the local player's lord), sc, stats, cfg.
-- A building's type for naming it. A building that is on fire, or burnt to a ruin, keeps its place and its object but
-- its type number becomes 75 (debris); the old type stays in typeBeforeChange (lane_f, read in the game's code). Named
-- by GetType alone, a burning building had a different name on the host than on a friend whose copy was not burning.
local function btype(b)
  local t = b:GetType()
  if t == 75 then local ok, o = pcall(function() return b.typeBeforeChange end); if ok and tonumber(o) and o > 0 and o ~= 75 then t = o end end
  return t
end
C.api = { btype = btype, un = un, valid = valid, now = now, far = far, words = words, log = log, later = later, send = send, helper = helper, isPaused = isPaused, setPaused = setPaused,
          toLocal = toLocal, toHost = toHost, pawns = pawns, rewind = rewind }

-- Notices for the player. Modules call C.notify(kind, text); a screen module (the co-op menu) shows them in the game's own
-- style. Without one they are only logged. kind: "syncing" (a resync started: short freeze), "synced" (it finished),
-- "joined" / "left" (a player), "refused" (an action the host could not do was undone here), "info".
C.notices = C.notices or {}
-- (lane 51) a friend has left: told once (its goodbye, Steam, or C.leftSilence s of silence; coop.lua host tick)
function C.friendLeft(p, why, kind)
  local S = C.s; if not S then return end
  S.gone = S.gone or {}; if S.gone[p] then return end
  S.goneWhy = S.goneWhy or {}; S.goneT = S.goneT or {}
  S.gone[p] = true; S.goneWhy[p] = kind or "silence"; S.goneT[p] = os.clock(); log("%s left the game: %s", p, why)
  C.notify("left", ((S.display and S.display[p]) or p) .. " left the game")
end
-- (lane 51) Steam's lobby on the host: which friend slots it holds now, and which it ever held (nil without Steam)
function C.steamSlots()
  local ST = rawget(C, "steam"); if not (ST and ST.on and ST.status) then return nil end
  local ok, st = pcall(ST.status); if not ok or type(st) ~= "table" or st.state ~= "hosting" then return nil end
  local S = C.s; S.steamSeen = S.steamSeen or {}
  local now_ = {}
  for _, q in ipairs(st.players or {}) do if q.slot and q.slot >= 1 then local n = "friend" .. q.slot; now_[n] = true; S.steamSeen[n] = true end end
  return { now = now_, seen = S.steamSeen }
end
function C.notify(kind, text)
  local n = { kind = kind, text = text, t = os.clock() }
  C.notices[#C.notices + 1] = n
  if #C.notices > 50 then table.remove(C.notices, 1) end
  -- (lane 61) the log gets the slot ("friend 1"), never the Steam name the player sees (also a name under 3 letters)
  local lt = tostring(text); local S = C.s
  if S and S.display then for slot, nm in pairs(S.display) do if type(nm) == "string" and nm ~= "" then lt = plainReplace(lt, nm, slotName(slot)) end end end
  log("notice [%s] %s", tostring(kind), lt)
  local show = rawget(C, "onNotice"); if type(show) == "function" then pcall(show, n) end
end

-- CRASH GUARD (first session between two PCs, 2026-11-11; reproduced on two test copies with the same crash address,
-- and with a control run: guard off = crash every time).
-- Every lord pawn has a list of the buildings near it (PawnCPP.closeBuildings). The game's ambient-sound code
-- (PawnCPP::getAmbienceTypeOnPosition, run from the pawn's blueprint) walks that list WITHOUT a null check. For the
-- real player a timer rebuilds the list; for the mod's helper lord nothing does: the game appends every building the
-- helper places and never takes one out. When such a building is removed later (a demolish by anybody, a move), the
-- engine's next clean-up blanks that entry and the helper's next ambient-sound check reads a missing building:
-- access violation at offset 0x3C1.
--   1. the helper's list is kept empty (every frame; the helper needs no ambient sound),
--   2. the local player's list is checked every frame: an entry that is gone or being destroyed is replaced by a
--      living entry of the same list (the game's timer rebuilds the list a moment later),
--   3. C.forget(b) takes one building out of both lists before the mod removes it through the helper.
-- Dev switch for the control run: a file link/dev_noscrub.txt turns all three off.
local function aliveIn(b, addrGone)                             -- (lane 45: a plain function, no closure per entry)
  return b ~= nil and b:IsValid() and not b:IsActorBeingDestroyed() and (addrGone == nil or b:GetAddress() ~= addrGone)
end
local function dropFrom(arr, addrGone)
  local n = #arr; if n == 0 then return 0 end
  local good, bad = nil, nil
  for i = 1, n do
    local b = arr[i]
    local okA, alive = pcall(aliveIn, b, addrGone); alive = okA and alive == true
    if alive then good = good or b else bad = bad or {}; bad[#bad + 1] = i end
  end
  if not bad then return 0 end
  if good then for _, i in ipairs(bad) do arr[i] = good end else arr:Empty() end
  return #bad
end
function C.scrubClose(S, clock)
  if clock - (S.scrubSwT or -10) > 2.0 then
    S.scrubSwT = clock; local f = io.open(LINK .. "dev_noscrub.txt", "rb"); S.scrubOff = f ~= nil; if f then f:close() end
  end
  -- (lane 47) the native piece guards both lists at every tick (coop_snap.h, SNAP GUARD) once it holds this lord and
  -- this helper; until then, and on another game build, the guard below runs as before
  local N = rawget(C, "snap")
  if S.scrubOff then if N and N.guardOff then pcall(N.guardOff) end; return end
  if N and N.guardOn then local okG, on = pcall(N.guardOn, S); if okG and on then return end end
  local h = S.hp
  if valid(h) then
    local ok, n = pcall(function() local arr = h.closeBuildings; local k = #arr; if k > 0 then arr:Empty() end; return k end)
    if ok and n and n > 0 then
      S.stats.helperCloseEmptied = (S.stats.helperCloseEmptied or 0) + n
      if not S.saidHelperClose then S.saidHelperClose = true; log("crash guard: the helper's nearby-buildings list had %d entries and was emptied (said once)", n) end
    elseif not ok and not S.scrubErr then S.scrubErr = true; log("crash guard (helper): %s", tostring(n)) end
  end
  local p = S.p1; if not valid(p) then return end
  local ok, fixed = pcall(function() return dropFrom(p.closeBuildings, nil) end)
  if not ok and not S.scrubErr then S.scrubErr = true; log("crash guard (player): %s", tostring(fixed)) end
  if ok and fixed and fixed > 0 then
    S.stats.closeFixed = (S.stats.closeFixed or 0) + fixed
    log("crash guard: %d entries of the player's nearby-buildings list were gone and were replaced (total so far %d)", fixed, S.stats.closeFixed)
  end
end
-- a building the mod is about to remove through the helper: out of the helper's and the local player's list first
function C.forget(b)
  local S = C.s; if not S or S.scrubOff or not valid(b) then return end
  local a = nil; pcall(function() a = b:GetAddress() end); if not a then return end
  pcall(function() if valid(S.hp) then local arr = S.hp.closeBuildings; if #arr > 0 then arr:Empty() end end end)
  pcall(function() if valid(S.p1) then dropFrom(S.p1.closeBuildings, a) end end)
end

-- CRASH GUARD 2 (2026-11-12; the host of a two-copy run died when a friend asked for a resync; reproduced on a host
-- alone with the same crash address).
-- The game's save (PawnCPP::requestSaveFile) walks the lord's quest lists and reads the place of every entry of
-- Quest.regions WITHOUT a null check (access violation reading 0x1B8 at 0x4b22c63). An entry that is no region
-- kills that copy at its next save (the game's autosave, a player's save, a join, a resync).
-- THE CAUSE WAS THIS MOD: in this scripting layer, READING a game list past its end GROWS the list by empty entries
-- (measured: length 0, after reading [1] length 1, after reading [3] length 3). The events module read regions[1]
-- of every quest each second; the game's offer "raiders_near" has an EMPTY region list (plain game, no mod, day 365
-- of the test save), and that read gave it one empty entry. The read is repaired there (coop_x_events.lua, qregion).
-- RULE FOR EVERY MODULE: never read a game list at an index that is not proven to be within its length right now.
-- This guard stays as a net: every second, and right before the mod itself asks for a save, every lord's quests
-- are looked at; an entry of Quest.regions that is no valid region is replaced by a valid entry of the same list,
-- and a list with no valid entry at all is emptied (what the game itself had).
-- Dev switch for the control run: a file link/dev_noqscrub.txt turns it off.
local QLISTS = { "quests", "proposedQuests", "questOpportunities" }
function C.scrubQuests(S)
  if S.qscrubOff then return 0 end
  local fixed = 0
  for _, p in ipairs(pawns()) do
    if valid(p) then
      for _, l in ipairs(QLISTS) do
        local okL, a = pcall(function() return p[l] end)
        if okL and a then
          for i = 1, #a do
            local okQ, e = pcall(function()
              local rs = a[i].regions; local n = #rs; if n == 0 then return end
              local good, bad
              for j = 1, n do local r = un(rs[j]); if valid(r) then good = good or r else bad = bad or {}; bad[#bad + 1] = j end end
              if not bad then return end
              if good then for _, j in ipairs(bad) do rs[j] = good end else rs:Empty() end
              fixed = fixed + #bad
              local name = "?"; pcall(function() name = a[i].Name:ToString() end)
              log("crash guard: quest %s (%s) had %d region entries that are no region: %s", name, l, #bad, good and "replaced by a valid region" or "the list was emptied")
            end)
            if not okQ and not S.qscrubErr then S.qscrubErr = true; log("crash guard (quests): %s", tostring(e)) end
          end
        end
      end
    end
  end
  if fixed > 0 then S.stats.questRegionsFixed = (S.stats.questRegionsFixed or 0) + fixed end
  return fixed
end

-- (lane 51) The watchdog, always on (one os.clock read and a few stores a frame): a frame gap over 1 s on this copy
-- (the time between two of the mod's ticks) gets one log line "watchdog: frame gap ..." with what ran last on the
-- Lua side: the mod's own tick before the gap (its dearest step, the test console's part, a collector step), the time
-- outside the mod's Lua, the world module's last job, a save requested shortly before, a load / join / hold. The native
-- piece writes its own line for the same gap (coop_patch.log "STALL": its last hook entered and left, the game
-- thread's CPU time and the page faults in the gap): together they say whose time it was.
local WD = { n = 0 }
C.watchdog = WD
local function wdReport(S, t, gap)
  WD.n = WD.n + 1; if gap > (WD.max or 0) then WD.max = gap end
  local Wm = rawget(C, "world"); local job = Wm and Wm.jobs and Wm.jobs[1] and Wm.jobs[1].name or "-"
  local sv = rawget(C, "saveT"); local save = sv and (t - sv < gap + 5.0) and string.format("%.1f s before", t - sv) or "no"
  log("watchdog: frame gap %.2f s (%d this session, longest %.2f s) | the mod's Lua tick before it %.1f ms (dearest step %s %.1f ms, test console %.1f ms, collector step %s) | outside the mod's Lua %.2f s | world job last %s, at the head %s | a save requested: %s | load or join: %s",
    gap, WD.n, WD.max, WD.ms or 0, tostring(WD.fName), WD.fMax or 0, WD.dev or 0, WD.gc and "yes" or "no", t - (WD.te or WD.t), tostring(Wm and Wm.lastJob), job, save,
    (C.hold or (C.join and C.join.state)) and "yes" or "no")
end
function C.tick()
  local S = C.s; if not S or not S.on then WD.t = nil; return end
  if S.busy then return end
  local wt = os.clock()
  if WD.t and wt - WD.t > 1.0 then pcall(wdReport, S, wt, wt - WD.t) end
  WD.t = wt
  S.busy = true; S.ticks = S.ticks + 1
  -- lane 45: the whole mod's tick (without the development channel "dev": test probes, not the mod) and the collector
  local dv = K.step.dev; local dev0 = dv and dv.ms or 0
  local po = rawget(C, "preOrders")                          -- (the army module's step, set from its file: timed here)
  if po and po ~= K.poW then K.poW = C.costTimed(po, "core:preOrders"); C.preOrders = K.poW end
  K.fMax = 0; K.fName = nil
  local kb0, t0 = collectgarbage("count"), os.clock()
  FR.p1 = false; FR.eng = false                              -- (objs checks them again first)
  local ok, e = pcall(body)
  FR.p1 = false; FR.eng = false
  if not ok then S.nerr = S.nerr + 1; S.lastErr = tostring(e); if S.nerr <= 5 then log("tick error %d: %s", S.nerr, tostring(e)) end end
  pcall(C.sessionStep, S)                                    -- (lane 61) "session:" lines (every 2 s at most)
  if SESS.rep then pcall(C.reportStep) end                   -- (lane 61) a bug report the native piece is making
  dv = K.step.dev
  local ms, kb1 = (os.clock() - t0) * 1000 - ((dv and dv.ms or 0) - dev0), collectgarbage("count")
  if ms > 8 then                                             -- a long tick: what it was (a ring of the last 40)
    K.longI = K.longI % 40 + 1
    if kb1 < kb0 then K.over8gc = (K.over8gc or 0) + 1 end
    if C.hold or (C.join and C.join.state) then K.over8join = (K.over8join or 0) + 1 end
    local L = K.long[K.longI]; if not L then L = {}; K.long[K.longI] = L end   -- plain numbers in kept tables: no garbage
    L.t, L.ms, L.name, L.fmax, L.gc, L.join = now(), ms, K.fName, K.fMax, kb1 < kb0, (C.hold or (C.join and C.join.state)) and true or false
  end
  local T = K.tick
  T.n = T.n + 1; T.ms = T.ms + ms; if ms > T.max then T.max = ms end
  T.wn = T.wn + 1; T.wms = T.wms + ms; if ms > T.wmax then T.wmax = ms end
  if ms > 8 then K.over8 = K.over8 + 1; K.wover8 = K.wover8 + 1; if ms > 16 then K.over16 = K.over16 + 1; if ms > 50 then K.over50 = K.over50 + 1 end end end
  if kb1 < kb0 then K.gcN = K.gcN + 1; K.wgcN = K.wgcN + 1; K.gcMs = K.gcMs + ms else K.akb = (K.akb or 0) + (kb1 - kb0) end
  if kb1 > K.kbMax then K.kbMax = kb1 end
  WD.ms, WD.fName, WD.fMax, WD.dev, WD.gc, WD.te = ms, K.fName, K.fMax, (dv and dv.ms or 0) - dev0, kb1 < kb0, os.clock()   -- (lane 51)
  if t0 - K.wT >= 60 then C.costLine(t0) end
  -- lines kept while the link folder was missing: write them as soon as it is there (about once a second)
  if C.early and S.ticks % 60 == 0 and not SESS.hdr then          -- (lane 61) a pending header goes first, with the next line
    local f = logFile(LINK .. S.name .. "_log.txt")            -- (lane 47) the kept handle
    if f then f:write(table.concat(C.early)); C.early = nil; f:flush() end
  end
  S.busy = false
end

-- ---------------------------------------------------------------- (lane 61) session lines and the bug report
local function playersText(S)
  if S.role == "host" then
    local n = 0
    for _, p in ipairs(S.peers or {}) do local h = S.heard and S.heard[p]; if h and os.clock() - h < 10.0 then n = n + 1 end end
    return string.format("%d (the host and %d friend%s)", n + 1, n, n == 1 and "" or "s")
  elseif S.role == "friend" then
    if C.hold then return "joining the host" end
    local h = S.heard and S.heard.host                       -- (when the host last sent anything)
    return (h and os.clock() - h < 10.0) and "the host and this friend (other friends are not counted here)" or "the host not heard for 10 s"
  end
  return "none (not in a co-op game)"
end
local function saveName(S)
  local J = rawget(C, "join")
  if S.role == "friend" and J and J.lastLoaded then return J.lastLoaded .. " (the host's save, as loaded for the join)" end
  if not valid(S.eng) then return "none (no world)" end
  if not valid(SESS.gi) then SESS.gi = FindFirstOf("MLGameInstance") end
  local nm; pcall(function() nm = SESS.gi.savefileToLoad:ToString() end)
  if not nm or nm == "" then return "a new game, or not known" end
  return nm
end
-- every 2 s on the game thread (C.tick): the game's version once, and a "session:" line whenever the role, the players
-- connected or the save changed
function C.sessionStep(S)
  local t = os.clock()
  if t - (SESS.stepT or -10) < 2.0 then return end
  SESS.stepT = t
  if not SESS.gameVer and t - (SESS.verT or -100) > 10.0 then
    SESS.verT = t
    local ok, v = pcall(function() local gi = FindFirstOf("MLGameInstance"); if valid(gi) then SESS.gi = gi; return gi:GetDisplayAppVersion():ToString() end end)
    if ok and type(v) == "string" and v ~= "" then SESS.gameVer = v; log("session: game version %s", v) end
  end
  local p, sv = playersText(S), saveName(S)
  local key = tostring(S.role) .. "|" .. tostring(S.name) .. "|" .. p .. "|" .. sv
  if key ~= SESS.infoKey then SESS.infoKey = key; log("session: role %s (%s), players connected %s, save %s", tostring(S.role), tostring(S.name), p, sv) end
end

-- Coop.report(): the "Make Bug Report" button (coop_ui.lua) calls it. It gathers what a bug report needs, with the
-- native piece (coop_patch.dll, coop_report.h) copying it scrubbed into link\reports\report_<time>.zip and opening that
-- folder in Explorer:
--   this run's log of every name this copy wrote this run, and every log of the run before (newest run only; a run can
--   have an idle and a host part); patch_status.txt, coop_patch.log (and .old), the loader's UE4SS.log; report_info.txt
--   (versions, role, players connected, save, the files, and "Describe the problem here:" for the player).
-- "This copy": the names it wrote this run; on a player's install (a run that started idle: one copy per folder) also
-- every other name's log in the link folder. Logs past C.reportLogCap (12 MB) keep their start and end.
-- Without the native piece (coop.cfg native = off) the files are written scrubbed, without a zip, as
-- link\reports\report_<time>_<file> and nothing is opened. Test switch: link\dev_report_noopen.txt (no Explorer).
local NAMES_ALL = { "idle", "host", "friend1", "friend2", "friend3", "friend4", "friend5", "friend6", "friend7" }
local function reportInfo(S, files, old)
  local P = rawget(C, "patch")
  local st = (P and P.fn and P.status) and P.status() or nil
  local steam = rawget(C, "steam")
  local okS, ss = pcall(function() return steam and steam.on and steam.status and steam.status() or nil end)
  ss = okS and ss or nil
  local L = {
    "Manor Lords Co-op bug report",
    "Made:              " .. os.date("%Y-%m-%d %H:%M:%S") .. " (this PC's clock)",
    "Mod version:       " .. tostring(C.version),
    "Game version:      " .. (SESS.gameVer or "not read"),
    "UE4SS:             " .. ue4ssVersion(),
    "Native piece:      " .. (st and (tostring(st.state) .. ", version " .. tostring(st.text and st.text:match("version (%S+)") or "?")) or "not loaded"),
    "Role:              " .. tostring(S.role) .. " (" .. tostring(S.name) .. ")",
    "Players connected: " .. playersText(S),
    "Save:              " .. saveName(S),
    "This run started:  " .. os.date("%Y-%m-%d %H:%M:%S", C.runT),
    "Steam link:        " .. (ss and (tostring(ss.state) .. (ss.slot and (", slot " .. ss.slot) or "") .. ", " .. #(ss.players or {}) .. " player(s) in the lobby") or "off"),
    "Resyncs and errors: " .. string.format("%d tick error(s) this run", S.nerr or 0),
    (old or 0) > 0 and string.format("Left out:          %d log(s) from before 0.2.2 (they may hold Steam names)", old) or "Left out:          none",
    "",
    "Files in this report:",
    "  report_info.txt  this file",
  }
  for _, e in ipairs(files) do L[#L + 1] = string.format("  %s  %s", e[2], e[4] or "") end
  L[#L + 1] = ""
  L[#L + 1] = "Describe the problem here:"
  L[#L + 1] = "(What happened? What did you expect? What did you do just before? The time on your PC's clock.)"
  L[#L + 1] = ""
  return table.concat(L, "\r\n")
end

function C.reportShow(msg, label)
  C.notify("info", msg)
  local U = rawget(C, "ui"); if U and U.reportNote then pcall(U.reportNote, label or msg) end
end

function C.report(opts)
  opts = opts or {}
  local S = C.s; if not S then return "the mod is not started" end
  local R = SESS.rep
  if R and os.clock() - R.t < 180.0 then return "a bug report is being made: report_" .. R.stamp end
  local stamp = os.date("%Y-%m-%d_%H-%M-%S")
  local files = {}
  local function add(src, dst, cap, note, start) if src and fexists(src) then files[#files + 1] = { src, dst, cap or 0, note, start or 0 } end end
  -- a log's run (its header's) and start; a log without a 0.2.2 header is left out: it may hold Steam names (0.2.1 wrote them)
  local old = 0
  local function at(l) local t, run = logStart(l); return run, t and os.date("%Y-%m-%d %H:%M:%S", math.floor(t)) or "?" end
  local cand, names = {}, {}
  for n in pairs(SESS.names) do cand[n] = "used" end
  if C.startRole == "idle" then for _, n in ipairs(NAMES_ALL) do cand[n] = cand[n] or "other" end end
  for n in pairs(cand) do names[#names + 1] = n end
  table.sort(names)
  local prev = {}
  for _, n in ipairs(names) do
    local cur = LINK .. n .. "_log.txt"
    local l = firstLine(cur)
    if l and cand[n] == "used" then
      local from = SESS.from and SESS.from[n] or 0       -- (an earlier run's lines above, when they could not be moved: left out)
      add(cur, "current_" .. n .. "_log.txt", C.reportLogCap, "this run's log as " .. n .. (from > 0 and " (its own part only)" or ""), from)
    elseif l then local key, when = at(l); if key then prev[#prev + 1] = { cur, key, n .. "_log.txt", when } else old = old + 1 end end
    local idx = io.open(LINK .. "sessions/" .. n .. "_index.txt", "rb")
    if idx then
      local last
      for x in idx:lines() do x = x:gsub("%s+$", ""); if x:match("^[%w_%-]+%.txt$") then last = x end end
      idx:close()
      local pl = last and firstLine(LINK .. "sessions/" .. last)
      if pl then local key, when = at(pl); if key then prev[#prev + 1] = { LINK .. "sessions/" .. last, key, last, when } else old = old + 1 end end
    end
  end
  local best = 0
  for _, e in ipairs(prev) do if e[2] < C.runT and e[2] > best then best = e[2] end end
  for _, e in ipairs(prev) do if best > 0 and e[2] == best then add(e[1], "previous_" .. e[3], C.reportLogCap, "the run before (started " .. e[4] .. ")") end end
  local P = rawget(C, "patch")
  if P and P.statusPath and P.dir then
    add(P.statusPath, "patch_status.txt", 0, "the native piece's status")
    add(P.dir .. "coop_patch.log", "coop_patch.log", 8 * 1048576, "the native piece's log")
    add(P.dir .. "coop_patch.log.old", "coop_patch.log.old", 8 * 1048576, "its log before (it turns over at 256 KB)")
  end
  add(MODDIR .. "/../../UE4SS.log", "UE4SS.log", 8 * 1048576, "the mod loader's log")
  local info = reportInfo(S, files, old)
  local list = {}; for i, e in ipairs(files) do list[i] = e[2] end
  if P and P.fn and P.dir and P.send then
    local ip = P.dir .. "patch_report_info.txt"
    local f = io.open(ip, "wb"); if f then f:write(info); f:close() end
    table.insert(files, 1, { ip, "report_info.txt", 0 })
    local J = { "open " .. ((opts.open == false or fexists(LINK .. "dev_report_noopen.txt")) and "0" or "1"), "zip " .. (opts.zip == false and "0" or "1") }
    PRIV.t = -10
    for _, e in ipairs(steamNames()) do J[#J + 1] = "name " .. (e[1]:gsub("[\t\r\n]", " ")) .. "\t" .. e[2] end
    for _, e in ipairs(files) do J[#J + 1] = "file " .. (e[1]:gsub("/", "\\")) .. "\t" .. e[2] .. "\t" .. string.format("%d\t%d", math.floor(e[3]), math.floor(e[5] or 0)) end
    local jf = io.open(P.dir .. "patch_report_job.txt", "wb")
    if not jf then return "the bug report could not be started (the job file could not be written)" end
    jf:write(table.concat(J, "\n"), "\n"); jf:close()
    SESS.rep = { stamp = stamp, t = os.clock() }
    P.send("REPORT " .. stamp); P.tick()
    log("bug report: report_%s asked, %d files: report_info.txt, %s", stamp, #files, table.concat(list, ", "))
    return "making the bug report: link\\reports\\report_" .. stamp .. ".zip"
  end
  -- no native piece: the files themselves, scrubbed here, without a zip (shorter: Lua reads them whole)
  local dir = LINK .. "reports/"
  local pre = "report_" .. stamp .. "_"
  local o = io.open(dir .. pre .. "report_info.txt", "wb")
  if not o then dir = LINK; o = io.open(dir .. pre .. "report_info.txt", "wb") end
  if not o then return "the bug report could not be written" end
  o:write(scrub(info)); o:close()
  local n = 1
  for _, e in ipairs(files) do
    local f = io.open(e[1], "rb")
    if f then
      local size = f:seek("end") or 0
      local base = math.min(e[5] or 0, size)
      local cap = math.min(e[3] > 0 and e[3] or size, 4 * 1048576)
      local text
      if size - base <= cap then f:seek("set", base); text = f:read("a") or ""
      else
        local head = math.floor(cap / 4)
        f:seek("set", base); local a = f:read(head) or ""
        f:seek("set", size - (cap - head)); local b = (f:read("a") or ""):gsub("^[^\n]*\n", "")
        text = a .. "\r\n... the middle of this file is left out here (the bug report keeps its start and its end) ...\r\n" .. b
      end
      f:close()
      local w = io.open(dir .. pre .. e[2], "wb"); if w then w:write(scrub(text)); w:close(); n = n + 1 end
    end
  end
  log("bug report: report_%s written without the native piece: %d files in link%s", stamp, n, dir == LINK and "" or "\\reports")
  C.reportShow("Bug report saved in the mod's link\\reports folder", "Bug Report Saved (No Zip)")
  return string.format("bug report written without the native piece (no zip): %d files report_%s_* in link%s", n, stamp, dir == LINK and "" or "\\reports")
end

-- every tick (cheap): the native piece's answer to the report
function C.reportStep()
  local R = SESS.rep; if not R then return end
  local t = os.clock()
  if t - (R.chk or 0) < 0.5 then return end
  R.chk = t
  local P = rawget(C, "patch")
  local st = P and P.status and P.status()
  local it = st and st.items and st.items.REPORT
  local why = it and it.why or ""
  local mine = why:find("report_" .. R.stamp, 1, true) ~= nil
  local done = it and mine and (it.state == "done" or it.state == "folder" or it.state == "refused") and it.state or nil
  if not done then
    if t - R.t > 180.0 then SESS.rep = nil; log("bug report: report_%s did not finish within 180 s", R.stamp); C.reportShow("The bug report did not finish", "Bug Report Failed") end
    return
  end
  SESS.rep = nil
  SESS.lastReport = done .. " " .. why
  log("bug report: %s %s", done, why)
  local opened = why:find(" opened", 1, true) ~= nil
  if done == "done" then C.reportShow("Bug report saved: " .. (why:match("^(%S+)") or "") .. (opened and " (its folder is open)" or ""), opened and "Bug Report Saved (Folder Opened)" or "Bug Report Saved")
  elseif done == "folder" then C.reportShow("Bug report saved as a folder: " .. (why:match("^(%S+)") or ""), "Bug Report Saved (Folder)")
  else C.reportShow("The bug report could not be made", "Bug Report Failed") end
end

-- lane 45: the minute line, "cost: <frames> frames: mod <ms a frame> ms a frame, longest <ms> ...", then per step (the
-- twelve dearest of the minute) "<name> <ms a frame>/<longest ms>"; the minute's counters start again
function C.costLine(t)
  local T = K.tick; local fr = math.max(T.wn, 1)
  local list = {}
  for name, s in pairs(K.step) do if s.wn > 0 then list[#list + 1] = name end end
  table.sort(list, function(a, b) return K.step[a].wms > K.step[b].wms end)
  local parts = {}
  for i = 1, math.min(#list, 12) do local s = K.step[list[i]]; parts[#parts + 1] = string.format("%s %.2f/%.0f", list[i], s.wms / fr, s.wmax) end
  log("cost: %d frames in %.0f s: mod %.2f ms a frame, longest %.0f ms, %d over 8 ms; collector in %d ticks; heap %.0f KB | sent %d lines %d B, read %d lines %d B (in all) | %s",
      T.wn, t - K.wT, T.wms / fr, T.wmax, K.wover8, K.wgcN, collectgarbage("count"), K.sN, K.sB, K.rN, K.rB, table.concat(parts, " "))
  for _, s in pairs(K.step) do s.wn = 0; s.wms = 0; s.wmax = 0 end
  T.wn = 0; T.wms = 0; T.wmax = 0; K.wover8 = 0; K.wgcN = 0; K.wT = t
end

function C.stop()
  if C.handle then pcall(CancelDelayedAction, C.handle); C.handle = nil end
  if C.s then C.s.on = false; if C.s.out then pcall(function() C.s.out:close() end); C.s.out = nil end end
  C.logClose()                                                          -- (lane 47) opened again by the next line
  return "stopped"
end

-- role: "host" or "friend"; name: this player's file name; peers: for the host, the friends' names
function C.start(role, name, peers, cfg)
  C.stop()
  if not C.clk then local t0 = os.time(); while os.time() == t0 do end; C.clk = os.time() - os.clock() end   -- one-off, up to 1 s
  C.s = { on = true, role = role, name = name or role, peers = peers or {}, cfg = cfg or { followSpeed = true }, seq = 0, readers = {}, stats = { sent = 0, applied = 0 },
          nerr = 0, lastErr = "", ticks = 0, worlds = 0, later = {}, known = {}, sq = {}, chase = {}, mir = {}, mirT = {}, host = {}, mine = {}, localOrderT = {}, h2l = {}, l2h = {}, baseDone = false,
          lastScan = 0, hookT = -10, tIn = 0, tSnap = 0, tUp = 0, startWall = now() }
  -- Old lines in the other players' link files are history, not messages for this start: skip them. Read from the
  -- beginning, a friend replayed every "load this save" the host had ever sent (session 20: it loaded an old save
  -- first, said "ready" too early, and the host showed a false "left the game"). setRole does the same.
  local others = role == "friend" and { "host" } or (peers or {})
  for _, p in ipairs(others) do C.s.readers[p] = readerAtEnd(p) end      -- (at the end of the newest file of its chain)
  linkReset(C.s, C.s.name)                                              -- this copy's own lines start afresh
  C.logClose()                                                          -- (lane 47) the kept log handle first
  -- (lane 61) the log is no longer emptied here: the first line of this run moves the last run's file to link\sessions
  C.startRole = C.startRole or role                                    -- (a run started "idle" is a player's own install)
  local mode
  if rawget(_G, "EngineTickAvailable") and rawget(_G, "LoopInGameThreadAfterFrames") then C.handle = LoopInGameThreadAfterFrames(1, function() _G.Coop.tick() end); mode = "every frame"
  else C.handle = LoopInGameThreadWithDelay(10, function() _G.Coop.tick() end); mode = "every 10 ms" end
  log("started as %s (%s), driver %s", role, C.s.name, mode)
  return "started as " .. role .. ", driver " .. mode
end

-- Change what this copy is, while the game runs: "idle" (the mod does nothing), "host" (this player started a co-op
-- game), "friend" (this player accepted an invite). Nobody sets a role in a file: the co-op menu and the Steam link
-- call this (README session 19: a fixed "friend" role would block saving in that player's own solo games).
function C.setRole(role, name, peers)
  local S = C.s; if not S then return "not started" end
  if S.out then pcall(function() S.out:close() end); S.out = nil end
  -- a friend's copy may be running a little fast or slow to catch up with the host: back to normal time
  pcall(function() if valid(S.p1) then StaticFindObject("/Script/Engine.Default__GameplayStatics"):SetGlobalTimeDilation(S.p1, 1.0) end end)
  S.role = role; S.name = name or (role == "friend" and "friend1" or "host"); S.peers = peers or {}
  S.reattach = S.reattach or valid(S.eng) or nil   -- (lane 59) a world is attached now: the next attach is this same world (S.sameWorld); kept when C.setRole is called twice before a tick
  S.eng = nil; S.p1 = nil                       -- attach the world again as this role: every module gets onWorld
  S.seq = 0; S.startWall = now(); S.heard = {}; S.gone = {}; S.stats.states = 0; S.readers = {}
  -- start reading every other player's file at its end: what was written before this role began is not for it
  local others = role == "friend" and { "host" } or S.peers
  for _, p in ipairs(others) do S.readers[p] = readerAtEnd(p) end
  linkReset(S, S.name)
  -- a new friend is in some other world (or none): it ignores the host's state until it has loaded the host's save,
  -- and says hello at once so the host starts the join
  C.hold = (role == "friend")
  if C.join then C.join.helloFor = nil; C.join.holdT = (role == "friend") and os.clock() or nil; C.join.loading = nil end
  log("role is now %s (%s)", role, S.name)
  SESS.infoKey = nil                            -- (lane 61) a "session:" line with the role, players and save follows
  if role ~= "friend" and C.patch and C.patch.fn and C.patch.send then pcall(C.patch.send, "ALLOFF") end
  return "role " .. role
end

function C.markInput() if C.s then C.s.inT = os.clock() end end   -- test aid: open an input window without a mouse event

function C.status()
  local S = C.s; if not S then return "not started" end
  local t = {}; for k, v in pairs(S.stats) do t[#t + 1] = k .. "=" .. tostring(v) end; table.sort(t)
  return string.format("%s on=%s ticks=%d worlds=%d errors=%d %s | %s", S.role, tostring(S.on), S.ticks, S.worlds, S.nerr, S.lastErr, table.concat(t, " "))
end

-- lane 45: three more core steps timed (see C.costTimed above the driver)
for _, k in ipairs({ "scrubClose", "scrubQuests", "quietHelper" }) do C[k] = C.costTimed(C[k], "core:" .. k) end

return "coop core " .. C.version .. " loaded"
