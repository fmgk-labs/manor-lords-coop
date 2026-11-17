-- Manor Lords Co-op: the Steam link (plug-in module "steam"). OFF unless coop.cfg has the line   steam = on
-- It loads coop_steam.dll (native code, source and README in native/coop_steam/) with package.loadlib and calls its one
-- function, coop_steam_tick, once per frame from the core's game-thread driver (tick with a world, idle without one).
-- The DLL does the Steam work (lobby, invites, P2P messages) and mirrors the link files host.txt / friend1-7.txt exactly
-- like coop-link.ps1 does, so the rest of the mod does not change. This module only writes its commands and reads its status.
--   status: loading the DLL from Lua: confirmed live (package.loadlib works in this UE4SS); the rest: mock-tested only
--
-- Where the DLL goes: Scripts\coop_steam.dll (preferred: its default link folder, <dll folder>\..\link, is then this mod's
-- own link folder) or the mod folder. A coop_steam.cfg beside the DLL may set linkdir= and savedir= (see the DLL's README).
--
-- Use:  Coop.steam.host()   Coop.steam.invite()   Coop.steam.join(lobbyId)   Coop.steam.leave()   Coop.steam.kick(steamId)
--       Coop.steam.status() -> { state, me, lobby, slot, reason, note, info = {appid=..., overlay=..., relay=...},
--                                players = { { slot, id, state, ping, name }, ... } }      (re-read at most 4 times a second)
--       Coop.steam.setPlayerState(slot, "loading" | "playing" | nil)   game facts the mod knows; status() shows them
-- On a friend's copy the DLL's slot decides the file name: when the status says "slot 2", this module switches the mod's
-- own file to friend2.txt (Coop.steam.followSlot = false turns that off).

local C = rawget(_G, "Coop")
if not C or not C.api then return "coop steam: the core is not loaded" end
local A = C.api

local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local scripts = here:match("^(.*)/[^/]*$") or "."
local modDir = scripts:match("^(.*)/[^/]*$") or "."

local function readKV(path)
  local t = {}
  local f = io.open(path, "r"); if not f then return t end
  for line in f:lines() do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k and not line:match("^%s*#") then t[k:lower()] = v end
  end
  f:close()
  return t
end

-- "F:/a/b/Scripts/../link" -> "F:/a/b/link/"
local function normDir(p)
  p = p:gsub("\\", "/")
  repeat local n; p, n = p:gsub("/[^/]+/%.%./", "/", 1) until n == 0
  p = p:gsub("/[^/]+/%.%.$", "")
  if p:sub(-1) ~= "/" then p = p .. "/" end
  return p
end

local ST = C.steam or {}
C.steam = ST
ST.on = false
if ST.followSlot == nil then ST.followSlot = true end
-- the API exists even when the module is off: every call then answers with the reason (a menu never hits a nil)
local function offAnswer() return "steam link is off: " .. tostring(ST.why) end
ST.host, ST.invite, ST.leave, ST.quit, ST.join, ST.kick = offAnswer, offAnswer, offAnswer, offAnswer, offAnswer, offAnswer
ST.gameState = ST.gameState or {}
function ST.setPlayerState(slot, state) ST.gameState[tonumber(slot) or -1] = state; ST.readT = nil end
function ST.status() return { state = "off", reason = ST.why, players = {}, info = {} } end
function ST.tick() end

-- On by default (session 18): without Steam (game not started through Steam, or another shop's copy) the DLL reports
-- "off <reason>" and does nothing, and the link program (link\) is used instead. "steam = off" in coop.cfg switches it off.
local cfg = readKV(modDir .. "/coop.cfg")
-- COOP_STEAM=off in the environment does the same for one process (development: a second copy of the game on the same
-- PC shares this folder and would overwrite the first copy's Steam status file).
if (os.getenv("COOP_STEAM") or cfg.steam or "on"):lower() == "off" then
  ST.why = "off (switched off in coop.cfg or by COOP_STEAM)"
  return "coop steam module off"
end

-- The DLL reads coop_steam.cfg beside itself once, at its first tick: tell it the mod's link folder and the game's save
-- folder (it sends the host's save to a friend before the "load this save" line, and writes it there on the friend's PC).
local function writeDllCfg(dllDir)
  local link = rawget(_G, "COOP_LINK_DIR")
  local save
  pcall(function() save = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory():ToString() .. "SaveGames" end)
  local lines = {}
  if link and link ~= "" then lines[#lines + 1] = "linkdir=" .. link:gsub("/", "\\"):gsub("\\$", "") end
  if save and save ~= "" then lines[#lines + 1] = "savedir=" .. save:gsub("/", "\\") end
  if #lines == 0 then return end
  local want = table.concat(lines, "\r\n") .. "\r\n"
  local path = dllDir .. "\\coop_steam.cfg"
  local f = io.open(path, "rb"); local have = f and f:read("a"); if f then f:close() end
  if have ~= want then local g = io.open(path, "wb"); if g then g:write(want); g:close() end end
end

-- ---------------------------------------------------------------- load the DLL
local dllPath, fn, err
for _, d in ipairs({ scripts, modDir }) do
  local p = d .. "/coop_steam.dll"
  local f = io.open(p, "rb")
  if f then
    f:close()
    dllPath = p:gsub("/", "\\")
    pcall(writeDllCfg, dllPath:match("^(.*)\\[^\\]*$") or ".")
    fn, err = package.loadlib(dllPath, "coop_steam_tick")
    break
  end
end
if not dllPath then
  ST.why = "coop_steam.dll not found in " .. scripts .. " or " .. modDir
  print("[ManorLordsCoop] steam: " .. ST.why .. "\n")
  return "coop steam module: no DLL"
end
if not fn then
  ST.why = "package.loadlib failed: " .. tostring(err)
  print("[ManorLordsCoop] steam: " .. ST.why .. "\n")
  return "coop steam module: DLL not loaded"
end
ST.fn = fn
ST.dll = dllPath

-- the link folder the DLL uses: linkdir= in coop_steam.cfg beside it, else <dll folder>\..\link (same rule as the DLL)
local dllDir = dllPath:match("^(.*)\\[^\\]*$") or "."
local scfg = readKV(dllDir .. "\\coop_steam.cfg")
ST.link = normDir((scfg.linkdir and scfg.linkdir ~= "") and scfg.linkdir or (dllDir .. "/../link"))
local modLink = rawget(_G, "COOP_LINK_DIR")
if modLink and normDir(modLink):lower() ~= ST.link:lower() then
  ST.warn = "the DLL's link folder (" .. ST.link .. ") is not the mod's link folder (" .. normDir(modLink) .. "): set linkdir in coop_steam.cfg"
  print("[ManorLordsCoop] steam: WARNING " .. ST.warn .. "\n")
end
ST.on = true

-- ---------------------------------------------------------------- commands (held until the DLL has run once: it empties steam_cmd.txt at start)
local pending = {}
local function writeCmd(s)
  local f = io.open(ST.link .. "steam_cmd.txt", "ab"); if not f then return false end
  f:write(s, "\n"); f:close(); return true
end
local function command(s)
  if not ST.on then return "steam link is off: " .. tostring(ST.why) end
  if (ST.ticks or 0) >= 1 then writeCmd(s) else pending[#pending + 1] = s end
  if A.log then pcall(A.log, "steam command %s", s) end
  return "sent " .. s
end
function ST.host() return command("HOST") end
function ST.invite() return command("INVITE") end
function ST.leave() return command("LEAVE") end
function ST.quit() return command("QUIT") end
function ST.join(id) id = tostring(id or ""); if not id:match("^%d+$") then return "a lobby number is needed" end; return command("JOIN " .. id) end
function ST.kick(id) id = tostring(id or ""); if not id:match("^%d+$") then return "a Steam id is needed" end; return command("KICK " .. id) end

-- ---------------------------------------------------------------- status
local function parse(text)
  local s = { players = {}, info = {} }
  local first = true
  for line in text:gmatch("[^\n]+") do
    if first then
      first = false
      local st, me, rest = line:match("^(%S+) (%d+)%s?(.*)$")
      s.state, s.me = st, me
      if st == "off" then s.reason = rest
      elseif st == "hosting" or st == "joining" then s.lobby = rest:match("^(%d+)")
      elseif st == "joined" then local lob, sl = rest:match("^(%d+) slot (%S+)"); s.lobby = lob; s.slot = tonumber(sl) end
    elseif line:sub(1, 5) == "info " then
      for k, v in line:sub(6):gmatch("(%S+) (%S+)") do s.info[k] = v end
    elseif line:sub(1, 5) == "note " then
      s.note = line:sub(6)
    else
      local slot, id, pst, ping, name = line:match("^(%d+) (%d+) (%S+) (%-?%d+) (.*)$")
      if slot then
        slot = tonumber(slot)
        local g = ST.gameState[slot]
        if g and pst == "connected" then pst = g end
        s.players[#s.players + 1] = { slot = slot, id = id, state = pst, ping = tonumber(ping), name = name }
      end
    end
  end
  return s
end

function ST.status()
  local t = os.clock()
  if ST.last and ST.readT and t - ST.readT < 0.25 then return ST.last end
  ST.readT = t
  if not ST.on then ST.last = { state = "off", reason = ST.why, players = {}, info = {} }; return ST.last end
  local f = io.open(ST.link .. "steam_status.txt", "rb")
  if not f then return ST.last or { state = "starting", players = {}, info = {} } end
  local text = f:read("a"); f:close()
  if text and #text > 0 then ST.last = parse(text) end
  return ST.last or { state = "starting", players = {}, info = {} }
end

-- Steam names for the mod's player names: { friend1 = "Anna", ... } on the host (from the status file's player lines)
function ST.names()
  local t = {}
  for _, p in ipairs(ST.status().players or {}) do if p.slot and p.slot >= 1 and p.name and p.name ~= "" then t["friend" .. p.slot] = p.name end end
  return t
end

-- a friend writes to friend<slot>.txt: follow the slot the host gave us
local function followSlot()
  local S = C.s
  if not ST.followSlot or not S or not S.on or S.role ~= "friend" then return end
  local s = ST.status()
  if s.state ~= "joined" or not s.slot then return end
  local want = "friend" .. s.slot
  if S.name ~= want then
    if S.out then pcall(function() S.out:close() end); S.out = nil end
    local old = S.name
    S.name = want
    pcall(A.log, "steam: the host gave this copy slot %d; writing %s.txt from now on (was %s)", s.slot, want, tostring(old))
  end
end

-- ---------------------------------------------------------------- the tick (game thread, from the core's driver)
function ST.tick()
  if not ST.fn then return end
  local ok, e = pcall(ST.fn)
  if not ok then ST.err = tostring(e) end
  ST.ticks = (ST.ticks or 0) + 1
  if #pending > 0 then for _, c in ipairs(pending) do writeCmd(c) end; pending = {} end
  followSlot()
end

local M = {}
function M.tick(S, clock) ST.tick() end
function M.idle(S, clock) ST.tick() end
C.register("steam", M)
return "coop steam module loaded (" .. ST.dll .. ", link " .. ST.link .. ")"
