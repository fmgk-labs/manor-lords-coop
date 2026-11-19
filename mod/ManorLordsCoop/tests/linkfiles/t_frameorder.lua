-- Desk test of the frame's order (lane 65, round three, 2026-11-17). Runs WITHOUT the game:
--     lua mod/ManorLordsCoop/tests/linkfiles/t_frameorder.lua <an empty folder to use> [<a Scripts folder to test instead>]
-- (Lua 5.4, or LuaJIT / Lua 5.1: the 5.4 forms used are stood in for below.) It loads the real coop.lua and
-- coop_steam.lua with stand-ins for the game and for coop_steam.dll, drives C.tick (the core's driver) as a friend at
-- the main menu, and counts frames:
--   arrival -> handling: the "DLL" writes a host line into host.txt in its tick; in which frame does the mod handle it?
--   making -> leaving:   a module writes a line in its frame; in which frame does the "DLL" (tick or flush) see it?
-- The optional second folder runs the same against another copy of the scripts (the order before lane 65: arrival 1
-- frame late). It never touches the game, a save or the mod's real link folder. Do not run it in the game's console.

local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/linkfiles/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_frameorder.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end
if arg[2] then scripts = arg[2]:gsub("\\", "/"); if scripts:sub(-1) ~= "/" then scripts = scripts .. "/" end end
local strict = arg[2] == nil                        -- the checks hold for this copy's scripts; another copy only reports

if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout)
  local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
  math.tointeger = math.tointeger or function(x) x = tonumber(x); if x and x == math.floor(x) then return x end end
end

local pass, fail = 0, 0
local function check(ok, what) if not strict then print("INFO  " .. what); return end; if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function spit(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function append(p, s) local f = assert(io.open(p, "ab")); f:write(s); f:close() end

-- ---- stand-ins for the game and the mod loader (no world: the main menu)
local function obj(t) t = t or {}; t.IsValid = t.IsValid or function() return true end; return t end
local function str(s) return { ToString = function() return s end } end
local GS = obj({ OpenLevel = function() end, GetCurrentLevelName = function() return str("MainMenu") end,
                 IsGamePaused = function() return false end, SetGamePaused = function() end, SetGlobalTimeDilation = function() end,
                 GetPlayerController = function() return nil end })
_G.StaticFindObject = function(path) if path:find("GameplayStatics", 1, true) then return GS end; return obj({}) end
_G.FindFirstOf = function(cls)
  if cls == "MLGameInstance" then return obj({ savefileToLoad = str(""), GetDisplayAppVersion = function() return str("0.8.117") end }) end
  return obj({ IsValid = function() return false end })
end
_G.FindAllOf = function() return {} end
_G.FName = function(s) return s end
_G.RegisterHook = function() return 1, 2 end
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.COOP_LINK_DIR = dir
_G.Coop = nil

-- ---- the stand-in DLL: its tick "receives" a host line when one is due; its tick and its flush note the first frame
-- in which they see the module's line in this copy's own file
local frame = 0
local due, arrivedAt, sentAt, wantSent = nil, nil, nil, nil
local function seeSent(who)
  if wantSent and not sentAt and (slurp(dir .. "friend1.txt") or ""):find(wantSent, 1, true) then sentAt = frame; return who end
end
local tickN = 0
local function fakeTick()
  tickN = tickN + 1
  if due then append(dir .. "host.txt", due); due = nil; arrivedAt = frame end
  seeSent("tick")
  return 0
end
local function fakeFlush() seeSent("flush"); return 0 end
local open0 = io.open
io.open = function(path, mode)
  local p = tostring(path):gsub("\\", "/")
  if p:match("/coop_steam%.dll$") then return open0(here(), "rb") end
  if p:match("/coop_steam%.cfg$") then return open0(dir .. "coop_steam.cfg", mode) end
  return open0(path, mode)
end
package.loadlib = function(_, sym) if sym == "coop_steam_tick" then return fakeTick elseif sym == "coop_steam_flush" then return fakeFlush end end
spit(dir .. "coop_steam.cfg", "linkdir=" .. dir:gsub("/", "\\"):gsub("\\$", "") .. "\r\n")

dofile(scripts .. "coop.lua")
local C = _G.Coop
C.start("idle", "idle", {})
local r = dofile(scripts .. "coop_steam.lua")
check(type(r) == "string" and r:find("loaded", 1, true) ~= nil, "coop_steam.lua loads with the stand-in DLL: " .. tostring(r))
spit(dir .. "host.txt", "")
C.setRole("friend", "friend1", {})
local S = C.s

-- a module that handles the host's "J TEST" line and writes a line of its own in a given frame
local handledAt, makeAt
C.register("t65", {
  onMessage = function(S2, from, kind, w) if kind == "J" and w[4] == "TEST" and not handledAt then handledAt = frame; return true end end,
  idle = function() if frame == makeAt then C.link.send("X t65 made"); wantSent = "X t65 made" end end,
})
local function tick() frame = frame + 1; S.tIn = -1; C.tick() end   -- (the menu reads every 50 ms: every frame here)
for _ = 1, 5 do tick() end

due = "7 1.000 J TEST arrival\n"
for _ = 1, 5 do tick() end
local dA = handledAt and arrivedAt and handledAt - arrivedAt
check(dA == 0, "a host line the Steam piece wrote in its tick is handled in the same frame (frames: " .. tostring(dA) .. ")")

makeAt = frame + 1
for _ = 1, 5 do tick() end
local dM = sentAt and sentAt - makeAt
check(dM == 0, "a line a module writes leaves in the same frame, through the flush (frames: " .. tostring(dM) .. ")")
check(tickN == frame, "the Steam piece ticks once a frame (" .. tickN .. " ticks in " .. frame .. " frames)")
check(C.modules.steam and C.modules.steam.tick == nil and C.modules.steam.idle == nil, "the Steam piece is no module tick any more (pumped by the driver only: once a frame)")

C.stop()
for _, n in ipairs({ "host.txt", "friend1.txt", "idle_log.txt", "friend1_log.txt", "coop_steam.cfg", "steam_cmd.txt" }) do os.remove(dir .. n) end
print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
