-- Self-test of the men module's LED POINTS (lane 73, 2026-11-17): the host's line and what a friend makes of it.
-- Runs WITHOUT the game:   lua mod/ManorLordsCoop/tests/lane73/t_menlead.lua <an empty folder to use>
-- (Lua 5.4, or LuaJIT / Lua 5.1 with the stand-ins below.) It loads the real coop.lua and coop_x_men.lua. The native
-- piece is stood in for (its answer file men_out.txt is written by the test, its commands are caught); squads and men
-- are plain tables. The clock is the test's own. It never touches the game, a save or the mod's real link folder.
-- What it shows:
--   host    asks the native piece for led points (MEN LEAD 2000); a walking man's entry carries his own place AND
--           the led point and speed ("/lx,ly,lz,v"); with Coop.m73lead = false the entry is the one of before; a man
--           who stopped (" S") is sent at once though he moved under a metre, without a led point.
--   friend  a led entry becomes "MEN SET <man>=<led point>,1,<host's place moved on a quarter second>,<speed>"; the
--           place kept for the rehold is his own place; without the native pace rule, or with Coop.m73lead = false,
--           the entry is used as before (the own place with the catch-up mark); an entry of before parses as before;
--           the link's delay: the host answers a friend's MQ, the friend works out the round trip and the clocks.

local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane73/[^/]*$") or ".") .. "/Scripts/"
local dir = (arg and arg[1]) or ARG1
if not dir then print("give an empty folder: lua t_menlead.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end

if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout)
  local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
  math.tointeger = math.tointeger or function(x) x = tonumber(x); if x and x == math.floor(x) then return x end end
end

_G.COOP_LINK_DIR = dir
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.Coop = nil
local T = 500.0
local clock0 = os.clock
os.clock = function() return T end

local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function fresh(name, text) local f = assert(io.open(dir .. name, "wb")); f:write(text); f:close() end
local function slurp(name) local f = io.open(dir .. name, "rb"); if not f then return "" end; local s = f:read("a"); f:close(); return s end

dofile(scripts .. "coop.lua")
local C = _G.Coop
C.linkCut = 0
-- the native piece: commands caught, the status as the DLL writes it
local sentCmds = {}
local paceWord, leadWord = "in", " lead=0 leads=0"
C.patch = { fn = function() end, dir = dir, tick = function() end,
            send = function(line) for l in tostring(line):gmatch("[^\n]+") do sentCmds[#sentCmds + 1] = l end end,
            status = function() return { items = { MEN = { state = "hooked" } }, text = "menstat held=0 pace=" .. paceWord .. " raised=0 runoffs=0 rlast=0 lets=0" .. leadWord } end }
local function cmdsWith(word) local t = {}; for _, l in ipairs(sentCmds) do if l:find(word, 1, true) then t[#t + 1] = l end end; return t end
-- a man: what the module reads of him
local function man(addr, id, x, y, z)
  return { IsValid = function() return true end, GetAddress = function() return addr end, UniqueID = id, realPos = { X = x, Y = y, Z = z } }
end
local squadNow = { Control = 0, isEngaged = false, WeightedCenter = { X = 0, Y = 0 }, rallyingStatus = 0, squadType = 3,
                   TargetLocation = { X = 99999, Y = 0 }, ownerPawn = { IsValid = function() return false end } }
local sc = { IsValid = function() return true end, GetSquad = function() return squadNow end, GetUnitCount = function() return 2 end }

dofile(scripts .. "coop_x_men.lua")
local M = C.men
local mod = C.modules.men
check(M and mod and mod.tick and mod.onMessage, "coop_x_men.lua loads outside the game")

-- ================================================================ host
C.start("host", "host", { "friend1" })
local S = C.s
S.sc = sc; S.p1 = { IsValid = function() return true end, GetAddress = function() return 1 end }
local A1, A2 = 0x1000, 0x2000
local m1, m2 = man(A1, 11, 1000, 2000, 30), man(A2, 12, 1100, 2000, 30)
local K = { list = { { addr = "1000", id = 11, u = m1 }, { addr = "2000", id = 12, u = m2 } } }
S.sq = { [52] = K }
M.hoffV = 0x4E8                                     -- (the realPos offset: found once a session in the game)
local function hostRound(dt, cx, out)
  T = T + dt
  K.st = { ctl = 0, eng = false, cx = cx, cy = 0, rs = 0 }; K.stT = T
  if out then fresh("men_out.txt", out) end
  mod.tick(S, T)
end
fresh("host.txt", "")
hostRound(0.25, 0)                                  -- the first round: the POLL goes out, nothing is read yet
check(#cmdsWith("MEN LEAD 2000") == 1 and #cmdsWith("MEN HEREAT 4E8") == 1, "host: asks the native piece for led points (MEN LEAD 2000), once")
hostRound(0.25, 0,   "H 1000 1000 2000 30\r\nH 2000 1100 2000 30\r\n")
hostRound(0.25, 100, "H 1000 1040 2000 30 9000 2000 L 1352 2000 30 156 0\r\nH 2000 1140 2000 30 9000 2000 L 1452 2000 30 156 0\r\n")
m1.realPos.X = 1200; m2.realPos.X = 1300
hostRound(0.25, 200, "H 1000 1200 2000 30 9000 2000 L 1512 2004 31 160 0\r\nH 2000 1300 2000 30 9000 2000 L 1612 2000 30 160 0\r\n")
hostRound(0.25, 300, "H 1000 1320 2000 30 9000 2000 L 1640 2000 30 160 0\r\nH 2000 1420 2000 30 9000 2000 L 1700 2000 30 160 1\r\n")
local hostTxt = slurp("host.txt")
local lastMX; for l in hostTxt:gmatch("[^\n]+") do if l:find(" MX ", 1, true) then lastMX = l end end
check(lastMX and lastMX:find("MF/52/2/1:132,200,3/164,200,3,160;2:142,200,3/170,200,3,160", 1, true),
      "host: a walking squad's line carries each man's own place and his led point and speed (" .. tostring(lastMX and lastMX:match("MX (.*)$")) .. ")")
local ledLine = lastMX
-- a man who stopped: sent at once though he moved 30 cm, without a led point
hostRound(0.25, 400, "H 1000 1350 2000 30 S\r\n")
lastMX = nil; for l in slurp("host.txt"):gmatch("[^\n]+") do if l:find(" MX ", 1, true) then lastMX = l end end
check(lastMX and lastMX ~= ledLine and lastMX:find("/52/2/1:135,200,3", 1, true) and not lastMX:find("1:135,200,3/", 1, true),
      "host: a man who stopped is sent where he stands at once, without a led point (" .. tostring(lastMX and lastMX:match("MX (.*)$")) .. ")")
-- a moving man without a led point this round, sent one under 1.5 s ago: not sent his bare place (the friend's man
-- would walk to where the host's man was and stand); once that time is over he is sent it
local stopLine = lastMX
C.m73vlead = false                                   -- (first without the led point along his velocity)
hostRound(0.25, 450, "H 2000 1760 2000 30\r\n")
lastMX = nil; for l in slurp("host.txt"):gmatch("[^\n]+") do if l:find(" MX ", 1, true) then lastMX = l end end
check(lastMX == stopLine, "host: a moving man with no led point this round (he is past his last one), led 0.5 s ago: no bare place is sent")
T = T + 1.5
hostRound(0.25, 900, "H 2000 1770 2000 30\r\n")      -- (the squad's centre moved on: it still walks)
lastMX = nil; for l in slurp("host.txt"):gmatch("[^\n]+") do if l:find(" MX ", 1, true) then lastMX = l end end
check(lastMX ~= stopLine and lastMX:find("/52/2/2:177,200,3", 1, true) and not lastMX:find("2:177,200,3/", 1, true), "host: no led point for 1.5 s: his bare place again, as before (" .. tostring(lastMX and lastMX:match("MX (.*)$")) .. ")")
-- a moving man without a way this round: a led point straight on along his velocity (the bandits' rout in the camp
-- fights: men lines up to 1.6 s apart while the host's men ran on)
C.m73vlead = nil
hostRound(0.25, 1000, "H 1000 1500 2000 30\r\n")
hostRound(0.25, 1100, "H 1000 1620 2000 30\r\n")     -- 1.2 m in a quarter second: 480 cm/s, 2 s of that = 9.6 m ahead
lastMX = nil; for l in slurp("host.txt"):gmatch("[^\n]+") do if l:find(" MX ", 1, true) then lastMX = l end end
check(lastMX and lastMX:find("1:162,200,3/258,200,3,480", 1, true) ~= nil, "host: a moving man with no way this round is led straight on along his velocity (" .. tostring(lastMX and lastMX:match("MX (.*)$")) .. ")")
-- the test switch: no led points
C.m73lead = false
hostRound(0.25, 500, "H 1000 1600 2000 30 9000 2000\r\nH 2000 1700 2000 30 9000 2000\r\n")
hostRound(0.25, 600, "H 1000 1760 2000 30 9000 2000\r\nH 2000 1900 2000 30 9000 2000\r\n")
lastMX = nil; for l in slurp("host.txt"):gmatch("[^\n]+") do if l:find(" MX ", 1, true) then lastMX = l end end
check(#cmdsWith("MEN LEAD 0") == 1 and lastMX and lastMX:find("MF/52/2/1:176,200,3;2:190,200,3", 1, true),
      "host, Coop.m73lead = false: MEN LEAD 0, and the line of before (" .. tostring(lastMX and lastMX:match("MX (.*)$")) .. ")")
C.m73lead = nil
-- a standing squad: a man at rest is sent the place his own game asked for him (his slot), not his own place, which
-- the native piece writes only every metre (lane 70: friend's men 0.35 to 0.58 m off their slots after a line drag)
hostRound(0.25, 600, "1000 1900 2100 30\r\n")        -- man 1 asks for his slot; his own place as last written is 1760,2000
for _ = 1, 8 do hostRound(0.25, 600, "") end           -- the squad stands for 2 s
local standing = {}; for l in slurp("host.txt"):gmatch("[^\n]+") do if l:find(" MX MM/52/", 1, true) then standing[#standing + 1] = l:match("MX (.*)$") end end
local lastStand = standing[#standing] or ""
check(lastStand:find("1:190,210,3", 1, true) ~= nil and not table.concat(standing, " "):find("1:176,200,3", 1, true),
      "host, a standing squad: the man who asked for a slot is sent that slot, never his stale own place (" .. table.concat(standing, " | ") .. ")")
check(lastStand:find("2:190,200,3", 1, true) ~= nil, "host, a standing squad: a man with no asked place near him is sent where he stands (" .. lastStand .. ")")
C.m73slot = false; T = T + 10.5; hostRound(0.25, 600, "")
lastMX = nil; for l in slurp("host.txt"):gmatch("[^\n]+") do if l:find(" MX ", 1, true) then lastMX = l end end
check(lastMX and lastMX:find("1:176,200,3", 1, true) ~= nil, "host, Coop.m73slot = false: his own place, as before (" .. tostring(lastMX and lastMX:match("MX (.*)$")) .. ")")
C.m73slot = nil
-- his exact resting place is known (the native " S"): the slot only when he rests within 40 cm of it
hostRound(0.25, 600, "H 1000 1880 2060 30 S\r\n")
lastMX = nil; for l in slurp("host.txt"):gmatch("[^\n]+") do if l:find(" MX ", 1, true) then lastMX = l end end
check(lastMX and lastMX:find("1:188,206,3", 1, true) ~= nil, "host: a man who rests 45 cm beside his slot is sent where he rests, not the slot (" .. tostring(lastMX and lastMX:match("MX (.*)$")) .. ")")
hostRound(0.25, 600, "H 1000 1895 2095 30 S\r\n")
lastMX = nil; for l in slurp("host.txt"):gmatch("[^\n]+") do if l:find(" MX ", 1, true) then lastMX = l end end
check(lastMX and lastMX:find("1:190,210,3", 1, true) ~= nil, "host: a man who rests 7 cm from his slot is sent the slot (" .. tostring(lastMX and lastMX:match("MX (.*)$")) .. ")")
-- A held line with no final S report. The last POLL is within 2 m of the
-- requested slot, but the host soldier has already stopped 1.41 m away.
local previousArmy = C.army
C.army = { form = { [52] = {} } }
m1.realSpeed = 0
m1.realPos.X, m1.realPos.Y = 1800, 2000
local function lastPlaceOnLine()
  local start = #slurp("host.txt")
  T = T + 10.5
  hostRound(0.25, 600, "H 1000 1830 2020 30\r\n")
  return slurp("host.txt"):sub(start + 1):match("MX MM/52/2/([^\n]+)") or ""
end
local rested = lastPlaceOnLine()
check(rested:find("1:180,200,3", 1, true), "held line: sends the stopped man's live place when the final stop report is missing (" .. rested .. ")")
m1.realSpeed = 150
local walking = lastPlaceOnLine()
check(walking:find("1:190,210,3", 1, true), "held line: a man still walking is given his requested slot (" .. walking .. ")")
C.army = previousArmy
-- the link's delay: the host answers a friend's question
local before = #slurp("host.txt")
mod.onMessage(S, "friend1", "MQ", { "7", "123.000", "MQ", "4321.500" })
check(slurp("host.txt"):sub(before + 1):find(" MQ friend1 4321.500\n", 1, true), "host: answers a friend's MQ with the friend's name and clock")

-- ================================================================ friend
C.start("friend", "friend1", {})
S = C.s
mod.onWorld(S)
S.sc = sc; S.p1 = { IsValid = function() return true end, GetAddress = function() return 1 end }
C.api.toLocal = function(h) return h end
C.armyApi.unitsOf = function() return { m2, m1 } end
sentCmds = {}
T = T + 3.0; mod.tick(S, T)                         -- (the status is read: the pace rule is in)
local function words(line) local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end; return w end
local function friendGets(text) T = T + 0.1; mod.onMessage(S, "host", "MX", words("9 " .. string.format("%.3f", C.api.now()) .. " MX " .. text)); T = T + 0.05; sentCmds = {}; mod.tick(S, T); return cmdsWith("MEN SET")[1] end
local set = friendGets("MF/52/2/1:132,200,3/164,200,3,160;2:142,200,3/170,200,3,160")
check(set == "MEN SET 1000=1640,2000,30,1,1360,2000,160;2000=1700,2000,30,1,1460,2000,160",
      "friend: a led entry: he walks to the led point; the host's place (moved on 0.25 s of his walk) and speed follow (" .. tostring(set) .. ")")
check(M.held["1000"] and M.held["1000"].p == "1320,2000,30,1", "friend: the place kept for the rehold is his own place, not the led point")
set = friendGets("MF/52/2/1:150,200,3;2:160,200,3")
check(set == "MEN SET 1000=1500,2000,30,1;2000=1600,2000,30,1", "friend: an entry of before is used as before (" .. tostring(set) .. ")")
set = friendGets("MM/52/2/1:150,210,3/164,200,3,160")
check(set == "MEN SET 1000=1500,2100,30", "friend: a led point on a place a man asked for (a fight, a camp) is not used (" .. tostring(set) .. ")")
set = friendGets("MF/52/2/1:132,200,3/164,200,3,160x;2:142,200,3")
check(set == "MEN SET 2000=1420,2000,30,1", "friend: an entry with a tail this build does not know is not taken (" .. tostring(set) .. ")")
C.m73lead = false
set = friendGets("MF/52/2/1:132,200,3/164,200,3,160")
check(set == "MEN SET 1000=1320,2000,30,1", "friend, Coop.m73lead = false: the own place with the catch-up mark, as before (" .. tostring(set) .. ")")
C.m73lead = nil
paceWord = "na"; T = T + 3.0; mod.tick(S, T)
set = friendGets("MF/52/2/1:133,200,3/164,200,3,160")
check(set == "MEN SET 1000=1330,2000,30,1", "friend without the native pace rule: the led point is not used (" .. tostring(set) .. ")")
paceWord = "in"; leadWord = ""; T = T + 3.0; mod.tick(S, T)
set = friendGets("MF/52/2/1:134,200,3/164,200,3,160")
check(set == "MEN SET 1000=1340,2000,30,1", "friend with a native piece of before (no lead= in its status): the led point is not used (" .. tostring(set) .. ")")
leadWord = " lead=0 leads=0"; T = T + 3.0; mod.tick(S, T)
-- a led point right at the host's place (his way's end): the place is not moved past it
set = friendGets("MF/52/2/1:164,200,3/164,201,3,160")
check(set == "MEN SET 1000=1640,2010,30,1,1640,2010,160", "friend: the host's place is never moved on past the led point (" .. tostring(set) .. ")")
-- this player's own order for the squad: its men are let go at once, a host line from before the order is not taken,
-- the men are not held again to the host's old places 0.75 s later, the host's first line after the order is taken
S.mine = { [52] = true }; S.localOrderT = { [52] = T }
sentCmds = {}; T = T + 0.11; mod.tick(S, T)
check(#cmdsWith("MEN LET") == 1 and not M.held["1000"], "friend, this player's own order: the squad's men are let go at once")
set = friendGets("MF/52/2/1:166,200,3/190,200,3,160")
check(set == nil and not M.held["1000"], "friend, own order: a host line 0.2 s after it (from before it) is not taken")
T = T + 0.6; sentCmds = {}; mod.tick(S, T)
check(#cmdsWith("MEN SET") == 0, "friend, own order: his men are not held again to the host's old places 0.75 s later")
set = friendGets("MF/52/2/1:170,200,3/196,200,3,160")
check(set and set:find("1000=1960,2000,30,1,", 1, true) and M.held["1000"] ~= nil, "friend, own order: the host's first line after it is taken (" .. tostring(set) .. ")")
S.localOrderT = {}
-- the link's delay: this copy asks every 5 s; the answer gives the round trip and the clocks
local own = slurp("friend1.txt")
local asked = own:match(" MQ (%d+%.%d+)\n")
check(asked ~= nil, "friend: asks the host (MQ <this copy's clock>)")
local t0 = C.api.now(); T = T + 0.24
mod.onMessage(S, "host", "MQ", { "5", string.format("%.3f", t0 + 0.9 + 0.12), "MQ", "friend1", string.format("%.3f", t0) })
check(M.lk and #M.lk.rt == 1 and math.abs(M.lk.rt[1] - 240) < 2 and M.lkOff and math.abs(M.lkOff - 0.9) < 0.005,
      string.format("friend: round trip %.0f ms and the clocks %.3f s apart from the host's answer (240 ms, 0.900 s)", M.lk and M.lk.rt[1] or -1, M.lkOff or -1))
mod.onMessage(S, "host", "MQ", { "6", "1.000", "MQ", "friend2", "1.000" })
check(#M.lk.rt == 1, "friend: an answer for another friend is not taken")

os.clock = clock0
pcall(C.stop)
print(string.format("RESULT: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
