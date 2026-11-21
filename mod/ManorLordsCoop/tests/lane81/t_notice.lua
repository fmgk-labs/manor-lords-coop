-- Desk test of lane 81 (0.2.8 item): a player's join, leave or return is told on EVERY copy, once.
--     lua mod/ManorLordsCoop/tests/lane81/t_notice.lua <an empty folder to use>
-- (Lua 5.4, or Lua 5.1.) Loads the real coop.lua and coop_join.lua with stand-ins (after lane 63's desk test), then:
--   1  host: a friend leaves (C.friendLeft): the host's own notice, and ONE line J PN ... left <friend> to the friends;
--      the same friend told again (a second goodbye, Steam's word): nothing more
--   2  host: the join and "is back" paths send J PN joined (J.tellAll), each with its own id
--   3  friend: each J PN line shows one notice with the player's name; the same line read again (a friend that loaded
--      alone reads the host's lines again from the save's mark) shows nothing; a line about this copy itself leaving
--      or coming back is not shown; a join of this copy itself is
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane81/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1] or ARG1
if not dir then print("give an empty folder: lua t_notice.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end
if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout); local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end

local T = 1000.0
os.clock = function() return T end
local function obj(t) t = t or {}; t.IsValid = t.IsValid or function() return true end; return t end
local function str(s) return { ToString = function() return s end } end
local gi = obj({ GetDisplayAppVersion = function() return str("0.8.117") end })
local GS = obj({ OpenLevel = function() end, GetCurrentLevelName = function() return str("MainMenu") end })
_G.StaticFindObject = function(path) if path:find("GameplayStatics", 1, true) then return GS end; return obj({}) end
_G.FindFirstOf = function(cls) if cls == "MLGameInstance" then return gi end; return obj({ IsValid = function() return false end }) end
_G.FindAllOf = function() return {} end
_G.FName = function(s) return s end
_G.RegisterHook = function() return 1, 2 end
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.COOP_LINK_DIR = dir
_G.Coop = nil

dofile(scripts .. "coop.lua")
local C = _G.Coop
C.start("idle", "idle", {})
local S = C.s
check(type(dofile(scripts .. "coop_join.lua")) == "string", "coop_join.lua loads")
local J, A = C.join, C.api
local sent = {}
A.send = function(line) sent[#sent + 1] = line end
local function sentWith(s) local n = 0; for _, l in ipairs(sent) do if l:find(s, 1, true) then n = n + 1 end end; return n end
local function noticesWith(s, kind) local n = 0; for _, x in ipairs(C.notices) do if tostring(x.text):find(s, 1, true) and (not kind or x.kind == kind) then n = n + 1 end end; return n end
local function words(line) local w = { "7", "1000.000" }; for x in line:gmatch("%S+") do w[#w + 1] = x end; return w end

print("1: host, a friend leaves")
S.role = "host"; S.name = "host"; S.display = { friend1 = "Ana Maria" }
C.friendLeft("friend1", "its goodbye (menu)", "bye")
check(noticesWith("Ana Maria left the game", "left") == 1, "the host shows 'Ana Maria left the game' once")
check(sentWith("J PN ") == 1 and sentWith(" left friend1 ") == 1, "one J PN line, kind left, player friend1")
C.friendLeft("friend1", "Steam: no longer in the lobby", "steam")
check(sentWith("J PN ") == 1 and noticesWith("Ana Maria left the game") == 1, "told again (Steam's word): no second line, no second notice")

print("2: host, join and return")
local id1 = J.tellAll("joined", "friend2", "Bo joined the game")
local id2 = J.tellAll("back", "friend1", "Ana Maria is back")
check(id1 and id2 and id1 ~= id2 and sentWith("J PN ") == 3, "each J PN line has its own id (" .. tostring(id1) .. ", " .. tostring(id2) .. ")")
local src = io.open(scripts .. "coop_join.lua", "rb"):read("*a")
local nJ = 0; for _ in src:gmatch('J%.tellAll%("joined"') do nJ = nJ + 1 end
check(nJ == 2 and not src:find('A.send("J NOTE " .. enc(text))\r?\n%s*if C.notify then C.notify("joined"'), "both join paths of coop_join.lua send J PN (not J NOTE)")
local srcC = io.open(scripts .. "coop.lua", "rb"):read("*a")
check(srcC:find('tellAll, "back", p, text', 1, true) ~= nil, "the host's 'is back' path sends J PN too")

print("3: friend, the lines arrive")
local L = {}; for _, l in ipairs(sent) do if l:find("^J PN ") then L[#L + 1] = l end end
C.notices = {}
S.role = "friend"; S.name = "friend2"
for _, l in ipairs(L) do J.pnLine(S, words(l)) end
check(noticesWith("Ana Maria left the game", "left") == 1, "friend2 shows 'Ana Maria left the game' once (the player's name)")
check(noticesWith("Bo joined the game", "joined") == 1, "friend2 shows its own join once")
check(noticesWith("Ana Maria is back", "joined") == 1, "friend2 shows 'Ana Maria is back' once")
local n0 = #C.notices
for _, l in ipairs(L) do J.pnLine(S, words(l)) end
check(#C.notices == n0, "the same lines read again after a load alone: nothing shown twice")
S.name = "friend1"; C.notices = {}
J.pnSeen = {}; J.pnList = {}
for _, l in ipairs(L) do J.pnLine(S, words(l)) end
check(noticesWith("left the game") == 0 and noticesWith("is back") == 0, "friend1 is not told that it itself left or came back")
check(noticesWith("Bo joined the game") == 1, "friend1 sees friend2's join")
check(J.pnLine(S, { "7", "1", "J", "PN", "x.1" }) == "bad", "a short line is ignored")

print("4: a friend's log names the slot, not the Steam name")
do
  S.role = "host"; S.name = "host"; S.display = { friend1 = "Ana Maria", friend2 = "Bo Lund" }
  sent = {}
  J.tellAll("joined", "Bo Lund", "Bo Lund joined the game")        -- a join path holds the display name
  check(sentWith(" joined friend2 ") == 1 and sentWith("Bo%20Lund joined") == 0 and sentWith(" joined Bo") == 0, "the host sends the slot friend2 in the player field")
  S.role = "friend"; S.name = "friend1"; S.display = nil; C.notices = {}
  J.pnSeen = {}; J.pnList = {}
  local logged = {}
  local log0 = A.log; A.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
  for _, l in ipairs(sent) do if l:find("^J PN ") then J.pnLine(S, words(l)) end end
  A.log = log0
  check(noticesWith("Bo Lund joined the game") == 1, "friend1 shows 'Bo Lund joined the game' (the name on screen)")
  check(S.display and S.display.friend2 == "Bo Lund", "friend1 learned friend2's name for the log's scrub")
end

print(string.format("RESULT %d passed, %d failed", pass, fail))
if fail > 0 then error("lane 81 notice desk test: " .. fail .. " failed") end
