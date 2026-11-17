-- coop_steam probe, STEP 2 (one Steam account): the host half. HOST -> wait for the lobby id -> keep the lobby open for
-- HOLD_SECONDS -> LEAVE. Everything runs on the GAME THREAD (one LoopInGameThreadWithDelay loop, every 50 ms).
-- The invite window is NOT opened unless you set OPEN_INVITE = true (it would appear on your screen; close it without inviting).
-- While the lobby is open, press Shift+Tab twice (open and close the Steam overlay): the log should then show
-- "first callback 331 ..." and "overlay opened" / "overlay closed" - that proves the hand-built callback object works.
--
-- HOW TO RUN: step 1 first (same DLL path, same game session is fine). Send this script once: it starts. Send it again
-- every few seconds: it prints the phase, the status file and the end of the DLL log. It ends by itself after LEAVE.
-- The lobby is invite-only, 4 players, and has the data key mlcoop=1. Nobody is invited, nothing is sent.

local DLL = [[C:\coop_steam_probe\bin\coop_steam.dll]]   -- <== the same path as in step 1
local HOLD_SECONDS = 30
local OPEN_INVITE = false

local out = out or print
_G.__CSP2 = _G.__CSP2 or {}
local P = _G.__CSP2

local function redact(s) return (s:gsub("7656119%d%d%d%d%d%d%d%d%d%d", function(id) return "****" .. id:sub(-4) end)) end
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
local function cmd(s) local f = io.open(P.link .. "steam_cmd.txt", "ab"); if f then f:write(s, "\n"); f:close() end; P.sent[#P.sent + 1] = string.format("%.1f s %s", os.clock() - P.t0, s) end
local function tailLines(s, n)
  local t = {}
  for line in (s or ""):gmatch("[^\n]+") do t[#t + 1] = line end
  local r = {}
  for i = math.max(1, #t - n + 1), #t do r[#r + 1] = t[i] end
  return r
end

-- the whole sequence, one small step per loop call (game thread)
local function step()
  if P.phase == "done" then return end
  local ok, e = pcall(P.tick)
  if not ok then P.err = tostring(e) end
  P.ticks = P.ticks + 1
  local now = os.clock()
  if now - (P.readT or 0) < 0.25 then return end
  P.readT = now
  local st = readFile(P.link .. "steam_status.txt") or ""
  local state = st:match("^(%S+)")
  if P.phase == "start" then
    if state == "off" then P.phase = "done"; P.result = "the DLL is off: " .. tostring(st:match("^off %d+ ([^\n]*)"))
    elseif state == "idle" then cmd("HOST"); P.phase = "creating"; P.tPhase = now end
  elseif P.phase == "creating" then
    if state == "hosting" then
      P.lobby = st:match("^hosting %d+ (%d+)"); P.phase = "hosting"
      P.sent[#P.sent + 1] = string.format("%.1f s lobby created after %.1f s", now - P.t0, now - P.tPhase)
      P.tPhase = now
    elseif state == "idle" and now - P.tPhase > 1 and st:match("\nnote ([^\n]*)") ~= "creating the game's Steam lobby" then
      P.phase = "done"; P.result = "HOST failed: " .. tostring(st:match("\nnote ([^\n]*)"))
    elseif now - P.tPhase > 25 then P.phase = "done"; P.result = "no lobby after 25 s" end
  elseif P.phase == "hosting" then
    if OPEN_INVITE and not P.invited and now - P.tPhase > 2 then cmd("INVITE"); P.invited = true end
    if now - P.tPhase > HOLD_SECONDS then cmd("LEAVE"); P.phase = "leaving"; P.tPhase = now end
  elseif P.phase == "leaving" then
    if state == "idle" and now - P.tPhase > 3 then P.phase = "done"; P.result = "hosted lobby " .. tostring(P.lobby) .. ", then left it" end
    if now - P.tPhase > 10 then P.phase = "done"; P.result = "LEAVE did not bring the state back to idle" end
  end
end

if not P.started then
  local f = io.open(DLL, "rb")
  if not f then return "no file at " .. DLL .. " - set DLL at the top of this script" end
  f:close()
  local fn, err = package.loadlib(DLL, "coop_steam_tick")
  if not fn then return "package.loadlib failed: " .. tostring(err) end
  if not rawget(_G, "LoopInGameThreadWithDelay") then return "this UE4SS has no LoopInGameThreadWithDelay; not starting" end
  -- step 1's ticking (if still running) stops: one driver only
  local P1 = rawget(_G, "__CSP"); if P1 then P1.max = 0 end
  P.tick, P.link, P.t0, P.phase, P.ticks, P.sent, P.started = fn, linkDir(DLL), os.clock(), "start", 0, {}, true
  P.loop = LoopInGameThreadWithDelay(50, function() step() end)
  out("link folder: " .. P.link)
  return string.format("started: HOST, lobby kept %d s, then LEAVE. Send this script again every few seconds.", HOLD_SECONDS)
end

if P.phase == "done" and P.loop then pcall(CancelDelayedAction, P.loop); P.loop = nil end
out(string.format("phase: %s   (%.1f s since start, %d ticks)%s", P.phase, os.clock() - P.t0, P.ticks, P.err and (", Lua error: " .. P.err) or ""))
if P.lobby then out("lobby id: " .. P.lobby) end
if P.phase == "hosting" then out("now: press Shift+Tab to open the Steam overlay, then close it again (callback test)") end
for _, s in ipairs(P.sent) do out("command sent at " .. s) end
out("---- steam_status.txt")
for line in (readFile(P.link .. "steam_status.txt") or "(none)"):gmatch("[^\n]+") do out(redact(line)) end
out("---- last lines of coop_steam.log")
for _, line in ipairs(tailLines(readFile(P.link .. "coop_steam.log"), 30)) do out(redact(line)) end
return P.result or ("running: " .. P.phase)
