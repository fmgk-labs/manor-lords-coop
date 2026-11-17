-- coop_steam probe, STEP 1 (one Steam account, nothing visible on screen, nothing sent to anyone).
-- Loads coop_steam.dll, ticks it on the GAME THREAD (LoopInGameThreadWithDelay, every 100 ms, 300 times = 30 s) and
-- shows what the DLL found: Steam initialised, your SteamID (only its last 4 digits are printed), overlay, app id, relay.
--
-- HOW TO RUN
--   1. Copy native\coop_steam\out\coop_steam.dll into a folder of its own OUTSIDE the game folder and outside
--      %LOCALAPPDATA%\ManorLords, for example  C:\coop_steam_probe\bin\coop_steam.dll
--      (the DLL pins itself in memory, so the copy stays locked until the game closes; never use out\ directly).
--      Its files go to <that folder>\..\link  (here C:\coop_steam_probe\link, created by the DLL). Do NOT point it at
--      the link folder a running coop-link.ps1 uses.
--   2. Set DLL below to that path. Start the game THROUGH STEAM. Send this script once: it loads the DLL and starts ticking.
--   3. Send it again after about 5 s (and once more after 30 s if relay still says waiting/attempting): it prints the results.
-- EXPECTED on a Steam start: state "idle", Steam found yes, SteamID present, app id 1363080, overlay 1, relay ok.
-- On a copy started outside Steam: "off ... the game has not started Steam" after 60 s (before that: waiting).

local DLL = [[C:\coop_steam_probe\bin\coop_steam.dll]]   -- <== absolute path of the copied coop_steam.dll

local out = out or print
_G.__CSP = _G.__CSP or {}
local P = _G.__CSP

local function redact(s)
  return (s:gsub("7656119%d%d%d%d%d%d%d%d%d%d", function(id) return "****" .. id:sub(-4) end))
end
local function linkDir(dll)
  local dir = dll:match("^(.*)\\[^\\]*$") or "."
  local link = dir .. "\\..\\link"
  local f = io.open(dir .. "\\coop_steam.cfg", "r")
  if f then
    for line in f:lines() do local v = line:match("^%s*linkdir%s*=%s*(.-)%s*$"); if v and v ~= "" then link = v end end
    f:close()
  end
  link = link:gsub("\\", "/")
  repeat local n; link, n = link:gsub("/[^/]+/%.%./", "/", 1) until n == 0
  if link:sub(-1) ~= "/" then link = link .. "/" end
  return link
end
local function readFile(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function tailLines(s, n)
  local t = {}
  for line in (s or ""):gmatch("[^\n]+") do t[#t + 1] = line end
  local r = {}
  for i = math.max(1, #t - n + 1), #t do r[#r + 1] = t[i] end
  return r
end

-- ---- first run: load and start ticking
if not P.tick then
  local f = io.open(DLL, "rb")
  if not f then return "no file at " .. DLL .. " - set DLL at the top of this script" end
  f:close()
  local fn, err = package.loadlib(DLL, "coop_steam_tick")
  if not fn then return "package.loadlib failed: " .. tostring(err) end
  P.tick, P.n, P.max, P.link, P.t0 = fn, 0, 300, linkDir(DLL), os.clock()
  if not rawget(_G, "LoopInGameThreadWithDelay") then return "this UE4SS has no LoopInGameThreadWithDelay; not ticking (async loops are unsafe here)" end
  P.loop = LoopInGameThreadWithDelay(100, function()
    if P.n >= P.max then return end
    P.n = P.n + 1
    local ok, e = pcall(P.tick)
    if not ok then P.err = tostring(e) end
  end)
  out("DLL loaded: " .. DLL)
  out("link folder: " .. P.link)
  return "ticking on the game thread (every 100 ms, 300 times). Send this script again in about 5 s."
end

-- ---- later runs: show the results
if P.n >= P.max and P.loop then pcall(CancelDelayedAction, P.loop); P.loop = nil end
out(string.format("ticks so far: %d of %d (%.1f s since load)%s", P.n, P.max, os.clock() - P.t0, P.err and (", Lua error: " .. P.err) or ""))
local st = readFile(P.link .. "steam_status.txt")
if not st then return "no steam_status.txt in " .. P.link .. " yet (did the DLL tick? is the folder writable?)" end
out("---- steam_status.txt")
for line in st:gmatch("[^\n]+") do out(redact(line)) end
local state, me = st:match("^(%S+) (%d+)")
local info = {}
local il = st:match("\ninfo ([^\n]*)")
if il then for k, v in il:gmatch("(%S+) (%S+)") do info[k] = v end end
out("---- checks")
out("Steam found and usable:   " .. ((state and state ~= "off") and "yes" or ("NO (" .. tostring(st:match("^off %d+ ([^\n]*)")) .. ")")))
out("my SteamID:               " .. ((me and me ~= "0") and ("present, ****" .. me:sub(-4)) or "missing"))
out("app id:                   " .. tostring(info.appid) .. (info.appid == "1363080" and " (Manor Lords, as expected)" or " (EXPECTED 1363080)"))
out("overlay enabled:          " .. tostring(info.overlay))
out("relay network:            " .. tostring(info.relay) .. ((info.relay == "ok") and "" or "  (send again later; 'waiting'/'attempting' are normal in the first seconds)"))
out("logged on / game build:   " .. tostring(info.loggedon) .. " / " .. tostring(info.build))
out("---- last lines of coop_steam.log")
for _, line in ipairs(tailLines(readFile(P.link .. "coop_steam.log"), 25)) do out(redact(line)) end
return "step 1 read (state " .. tostring(state) .. ")"
