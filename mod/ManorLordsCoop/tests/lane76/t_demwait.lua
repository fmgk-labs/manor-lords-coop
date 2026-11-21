-- Desk test (lane 76, task 76e round 3): the host's DEMOLISH line waits until the host's own game has taken the building
-- out of its list (coop_town.lua, DEMOLISH ready, DEM_WAIT). No game. Run from the repository root:
--   py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_demwait.lua mod/ManorLordsCoop/Scripts/
-- The argument is the folder holding coop_town.lua (an older copy's folder shows the old code fail).
local dir = ARG1 or (arg and arg[1]) or "mod/ManorLordsCoop/Scripts/"
if dir:sub(-1) ~= "/" and dir:sub(-1) ~= "\\" then dir = dir .. "/" end
math.tointeger = math.tointeger or function(v) if type(v) == "number" and v == math.floor(v) then return v end; return nil end
table.unpack = table.unpack or unpack
local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end
local NOW = 1000.0
os.clock = function() return NOW end
_G.RegisterHook = function() return 1, 2 end
_G.FName = function(s) return { ToString = function() return s end } end
_G.StaticFindObject = function() return nil end
_G.FindAllOf = function() return {} end

local function build(role)
  local C = {}; _G.Coop = C
  C.register = function() end
  C.api = {
    un = function(x) return x end,
    valid = function(x) return x ~= nil and (type(x) ~= "table" or x.IsValid == nil or x:IsValid()) end,
    far = function() return false end, log = function() end, now = function() return NOW end,
    send = function() end, isPaused = function() return false end, helper = function() return nil end, btype = function() return 0 end,
  }
  local b = { GetAddress = function() return 0x900 end, IsValid = function() return true end }
  C.s = { role = role, on = true, stats = {}, eng = { buildingArr = { b }, roads = {}, regions = {} } }
  assert(loadfile(dir .. "coop_town.lua"))()
  local T = C.town; T.reset()
  return T, C.s, b
end
local function rec(T, b) return { k = "DEMOLISH", obj = b, addr = 0x900, t = T.vt or 0, snap = { t = 3, x = 100, y = 200, z = 0 } } end

-- host: the building still in the host's list: the line waits
local T, S, b = build("host")
local d = T.defs.DEMOLISH
T.vt = 10.0
local r = rec(T, b)
local res = d.ready(S, r)
check(res == "wait", "host: the building still in the host's own list: the line waits (" .. tostring(res) .. ")")
T.vt = 10.3
check(d.ready(S, r) == "wait", "host: still there 0.3 s later: waits")
S.eng.buildingArr = {}                                -- the host's pawn Tick has demolished it
T.vt = 10.35
res = d.ready(S, r)
check(type(res) == "string" and res ~= "wait", "host: gone from the host's list: the line goes (" .. tostring(res) .. ")")
check(d.wait and d.wait > 1.0, "host: the queue's wait is longer than DEM_WAIT (the line is never dropped for waiting)")
-- host: the duplicate check runs once (a second ready call of the same record is not a 'duplicate')
local T2, S2, b2 = build("host")
T2.vt = 5.0; local r2 = rec(T2, b2)
T2.defs.DEMOLISH.ready(S2, r2)
local again = T2.defs.DEMOLISH.ready(S2, r2)
check(again == "wait", "host: the same record asked again is still waiting, not refused as a duplicate (" .. tostring(again) .. ")")
-- a second record of the same building (the second hook) is a duplicate
local r3 = rec(T2, b2); local x3, why3 = T2.defs.DEMOLISH.ready(S2, r3)
check(x3 == nil and why3 == "duplicate", "host: the second hook's record of the same building: duplicate")
-- failure side: the host's game never takes it: the line goes after DEM_WAIT anyway
T2.vt = 6.05
local late = T2.defs.DEMOLISH.ready(S2, r2)
check(type(late) == "string" and late ~= "wait", "host: still there after 1 s: the line goes as before (" .. tostring(late) .. ")")
-- friend: its own demolish line goes at once (the host's game decides; no wait on a friend)
local T4, S4, b4 = build("friend")
T4.vt = 1.0
local f = T4.defs.DEMOLISH.ready(S4, rec(T4, b4))
check(type(f) == "string" and f ~= "wait", "friend: its own line goes at once (" .. tostring(f) .. ")")
-- (round 4) UPGRADE / EXT / ARTISAN on the host: the line waits while the lord's flag of that kind is set (the request
-- not yet carried out by the host's own pump), at most REQ_WAIT s; a friend's line goes at once
local FLAG = { UPGRADE = "upgradeRequestPending", EXT = "extensionChangeRequestPending", ARTISAN = "artisanChangeRequestPending" }
for _, kind in ipairs({ "UPGRADE", "EXT", "ARTISAN" }) do
  local T5, S5, b5 = build("host")
  S5.p1 = { [FLAG[kind]] = true }
  T5.vt = 20.0
  local rq = { k = kind, obj = b5, addr = 0x900, t = 20.0, id = 7, slot = 0, snap = { t = 3, x = 100, y = 200, z = 0 } }
  local d5 = T5.defs[kind]
  check(d5.ready(S5, rq) == "wait", kind .. ", host: the lord's request flag still set: the line waits")
  check(d5.wait and d5.wait > 1.0, kind .. ", host: the queue's wait is longer than REQ_WAIT")
  S5.p1[FLAG[kind]] = false; T5.vt = 20.2
  local r5 = d5.ready(S5, rq)
  check(type(r5) == "string" and r5 ~= "wait", kind .. ", host: the pump carried it out (flag clear): the line goes (" .. tostring(r5) .. ")")
  S5.p1[FLAG[kind]] = true; rq.t = 30.0; T5.vt = 31.05
  r5 = d5.ready(S5, rq)
  check(type(r5) == "string" and r5 ~= "wait", kind .. ", host: still set after 1 s: the line goes as before (" .. tostring(r5) .. ")")
  local T6, S6, b6 = build("friend"); S6.p1 = { [FLAG[kind]] = true }; T6.vt = 1.0
  local r6 = T6.defs[kind].ready(S6, { k = kind, obj = b6, addr = 0x900, t = 1.0, id = 7, slot = 0, snap = { t = 3, x = 100, y = 200, z = 0 } })
  check(type(r6) == "string" and r6 ~= "wait", kind .. ", friend: its own line goes at once (" .. tostring(r6) .. ")")
end
-- (round 5) a request the host's game did NOT carry out (its pump ran: the flag clear; the building unchanged): not
-- sent after REQ_GRACE; one it did carry out (upgradesDone grew) is sent; with the switch off it is sent as before
for _, kind in ipairs({ "UPGRADE", "EXT", "ARTISAN" }) do
  local T7, S7, b7 = build("host")
  b7.upgradesDone = { 2 }; b7.isBeingUpgraded = false; b7.artisanJob = 0; b7.Extensions = { { Type = 0 } }
  S7.p1 = { [FLAG[kind]] = false }
  T7.vt = 40.0
  local rq = { k = kind, obj = b7, addr = 0x900, t = 40.0, id = 7, slot = 0, snap = { t = 3, x = 100, y = 200, z = 0 } }
  rq.pre = T7.reqState and T7.reqState(b7)
  local d7 = T7.defs[kind]
  check(d7.ready(S7, rq) == "wait", kind .. ", host: pump ran, building unchanged: waits its grace first")
  T7.vt = 40.4
  local r7, why7 = d7.ready(S7, rq)
  check(r7 == nil and tostring(why7):find("did not carry it out", 1, true), kind .. ", host: still unchanged after the grace: NOT sent (" .. tostring(why7) .. ")")
  local rq2 = { k = kind, obj = b7, addr = 0x900, t = 41.0, id = 7, slot = 0, snap = { t = 3, x = 100, y = 200, z = 0 }, pre = T7.reqState and T7.reqState(b7) }
  T7.vt = 41.1
  b7.upgradesDone = { 2, kind == "UPGRADE" and 7 or 107 }; b7.isBeingUpgraded = true
  local r8 = d7.ready(S7, rq2)
  check(type(r8) == "string" and r8 ~= "wait", kind .. ", host: the building changed (its game did it): sent (" .. tostring(r8) .. ")")
  local T9, S9, b9 = build("host")
  b9.upgradesDone = { 2 }; b9.isBeingUpgraded = false; b9.artisanJob = 0; b9.Extensions = {}
  S9.p1 = { [FLAG[kind]] = false }; T9.cfg.reqRefuse = false; T9.vt = 50.0
  local rq9 = { k = kind, obj = b9, addr = 0x900, t = 50.0, id = 7, slot = 0, snap = { t = 3, x = 100, y = 200, z = 0 } }
  rq9.pre = T9.reqState and T9.reqState(b9)
  local r9 = T9.defs[kind].ready(S9, rq9)
  check(type(r9) == "string" and r9 ~= "wait", kind .. ", host, switch reqRefuse off: sent as before (" .. tostring(r9) .. ")")
  T9.cfg.reqRefuse = true
end
-- (round 5) two requests in ONE frame, the host's game carried out only the second (the lord holds one request of a
-- kind): the first is not sent, the second is
for _, kind in ipairs({ "EXT", "ARTISAN" }) do
  local Ta, Sa, ba = build("host")
  ba.upgradesDone = { 2 }; ba.isBeingUpgraded = false; ba.artisanJob = 0; ba.Extensions = { { Type = 0 } }
  Sa.p1 = { [FLAG[kind]] = false }; Ta.vt = 60.0
  local r1 = { k = kind, obj = ba, addr = 0x900, t = 60.0, id = 5, slot = 0, snap = { t = 3, x = 100, y = 200, z = 0 } }
  local r2 = { k = kind, obj = ba, addr = 0x900, t = 60.0, id = 4, slot = 0, snap = { t = 3, x = 100, y = 200, z = 0 } }
  r1.pre = Ta.reqState and Ta.reqState(ba); r1.preN = Ta.idCount and Ta.idCount(ba, 105)
  r2.pre = r1.pre; r2.preN = Ta.idCount and Ta.idCount(ba, 104)
  ba.upgradesDone = { 2, 104 }; ba.artisanJob = 4; ba.isBeingUpgraded = true     -- the pump did the second only
  local d = Ta.defs[kind]
  check(d.ready(Sa, r1) == "wait", kind .. ", host, two in a frame: the first (not done) waits its grace")
  check(type(d.ready(Sa, r2)) == "string" and d.ready(Sa, r2) ~= "wait", kind .. ", host, two in a frame: the second (done) is sent")
  Ta.vt = 60.4
  local x1, w1 = d.ready(Sa, r1)
  check(x1 == nil and tostring(w1):find("did not carry it out", 1, true), kind .. ", host, two in a frame: the first is NOT sent (" .. tostring(w1) .. ")")
end
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_demwait failed") end
