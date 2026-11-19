-- Desk test of lane 66's whole notice list after a join or reload (coop_realm.lua: R LOGASK / LOGALL / LOGEND).
-- Runs WITHOUT the game, with made-up lords and lists, on Lua 5.1 / LuaJIT or 5.4:
--     lua mod/ManorLordsCoop/tests/lane66/t_logall.lua
-- It loads the real coop_realm.lua twice (a host's copy and a friend's copy, each with its own stand-in Coop), lets
-- the friend ask, carries the host's lines to the friend, and checks: the friend's list equals the host's (count,
-- words, building, time, day, order); no alert played; one mark per added entry; a list that came incomplete is not
-- applied; nothing is applied while NOLOG is not on; another friend's list is ignored.
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (arg and arg[1]) or ((here():match("^(.*)/tests/lane66/[^/]*$") or ".") .. "/Scripts/")   -- arg[1]: the Scripts folder (when the runner names the chunk by its file name only)
local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end

local function str(s) return { ToString = function() return s end } end
_G.FName = function(s) return str(s) end
_G.FindAllOf = function() return {} end
_G.RegisterHook = function() end

-- a lord with a list; addLog appends (time and day as "now"), removeLogEntry removes every equal entry (text, place)
local function makeLord(now, today)
  local L = { log = {}, DT_Alerts = { alerts = true }, alertsPlayed = 0 }
  function L:GetAddress() return 1 end
  function L:IsValid() return true end
  function L:addLog(tag, text, descr, opens, pos, actor)
    if self.DT_Alerts ~= nil then self.alertsPlayed = self.alertsPlayed + 1 end
    self.log[#self.log + 1] = { Tag = str(tag:ToString()), LogText = str(text), fullDescr = str(descr), opensMenu = opens,
      Location = { X = pos.X, Y = pos.Y, Z = pos.Z }, Timestamp = now(), DayOfTheYear = today, Actor = actor, IsDisplayed = false }
  end
  function L:removeLogEntry(e)
    local t = {}
    for _, x in ipairs(self.log) do
      if not (x.LogText:ToString() == e.LogText:ToString() and x.Location.X == e.Location.X and x.Location.Y == e.Location.Y) then t[#t + 1] = x end
    end
    self.log = t
  end
  function L:updateLogUI() end
  return L
end

local sent = {}
local function makeCoop(role, name, lord, nlOn)
  local C = { s = { role = role, name = name, worlds = 1, on = true, p1 = lord, eng = { buildingArr = {}, regions = {} } } }
  C.api = { un = function(x) return x end, valid = function(x) return x ~= nil end, log = function(f, ...) print("    [" .. role .. "] " .. string.format(f, ...)) end,
    send = function(line) sent[#sent + 1] = { from = role, line = line } end, btype = function() return nil end, now = function() return 0 end }
  C.register = function(n, m) C.module = m end
  C.patch = { nlOn = nlOn, marks = 0 }
  function C.patch.markLog() C.patch.marks = C.patch.marks + 1; return true end
  return C
end
local function load(C)
  _G.Coop = C
  local chunk = assert(loadfile(scripts .. "coop_realm.lua"))
  chunk()
  return C.module
end
-- carry every line one copy sent to the other (the core's words: <seq> <wallclock> <kind> ...)
local function deliver(toS, toM, fromRole)
  local q = sent; sent = {}
  for _, s in ipairs(q) do
    if s.from == fromRole then
      local w = { "1", "0" }
      for x in s.line:gmatch("%S+") do w[#w + 1] = x end
      toM.onMessage(toS, fromRole, w[3], w, s.line)
    else sent[#sent + 1] = s end
  end
end

-- the host: 23 entries, one with a building, made over two days
local hostT = 100.0
local host = makeLord(function() hostT = hostT + 1.5; return hostT end, 120)
for i = 1, 23 do host:addLog(FName(i % 5 == 0 and "death" or "storage"), "notice_" .. i, "descr_" .. i, 0, { X = i * 100.0, Y = -i * 10.0, Z = 3.0 }, nil); host.log[i].DayOfTheYear = 100 + math.floor(i / 12) end
local CH = makeCoop("host", "host", host, false)
local MH = load(CH)

print("[A] a friend that reloaded: its own list holds 3 entries (two from the re-read lines, one its game made)")
local friendT = 5.0
local friend = makeLord(function() friendT = friendT + 0.1; return friendT end, 130)
friend:addLog(FName("storage"), "notice_22", "descr_22", 0, { X = 2200.0, Y = -220.0, Z = 3.0 }, nil)
friend:addLog(FName("storage"), "notice_23", "descr_23", 0, { X = 2300.0, Y = -230.0, Z = 3.0 }, nil)
friend:addLog(FName("enemy"), "enemy_squad_spotted", "x", 0, { X = 1.0, Y = 1.0, Z = 1.0 }, nil)
local CF = makeCoop("friend", "friend1", friend, true)
local MF = load(CF)
friend.alertsPlayed = 0
MF.tick(CF.s, 10.0)                                  -- asks once
local asks = 0; for _, s in ipairs(sent) do if s.line:find("^R LOGASK ") then asks = asks + 1 end end
check(asks == 1, "the friend asked once (" .. asks .. ")")
MF.tick(CF.s, 10.2)
asks = 0; for _, s in ipairs(sent) do if s.line:find("^R LOGASK ") then asks = asks + 1 end end
check(asks == 1, "and not again in the same world")
deliver(CH.s, MH, "friend")
local nAll = 0; for _, s in ipairs(sent) do if s.line:find("^R LOGALL ") then nAll = nAll + 1 end end
check(nAll == 23, "the host sent its 23 entries (" .. nAll .. ")")
deliver(CF.s, MF, "host")
check(#friend.log == 23, "the friend's list holds 23 entries (" .. #friend.log .. ")")
local same = true
for i = 1, 23 do
  local h, f = host.log[i], friend.log[i]
  if not f or f.LogText:ToString() ~= h.LogText:ToString() or f.Tag:ToString() ~= h.Tag:ToString() or f.fullDescr:ToString() ~= h.fullDescr:ToString()
     or math.abs(f.Timestamp - h.Timestamp) > 0.01 or f.DayOfTheYear ~= h.DayOfTheYear or f.Location.X ~= h.Location.X then same = false; print("    differs at " .. i) break end
end
check(same, "every entry equal to the host's in words, place, time, day and order")
check(friend.alertsPlayed == 0, "no alert played while restoring (" .. friend.alertsPlayed .. ")")
check(friend.DT_Alerts ~= nil, "the alert table is back afterwards")
check(CF.patch.marks == 23, "one mark per added entry (" .. CF.patch.marks .. ")")
local disp = true; for _, e in ipairs(friend.log) do if not e.IsDisplayed then disp = false end end
check(disp, "every restored entry marked as displayed")

print("[B] a list that came incomplete is not applied")
local friend2 = makeLord(function() return 1.0 end, 130)
friend2:addLog(FName("x"), "own", "d", 0, { X = 0.0, Y = 0.0, Z = 0.0 }, nil)
local CF2 = makeCoop("friend", "friend2", friend2, true)
local MF2 = load(CF2)
sent = {}
MF2.tick(CF2.s, 10.0)
deliver(CH.s, MH, "friend")
local kept = {}; local dropped = false
for _, s in ipairs(sent) do if s.line:find("^R LOGALL ") and not dropped and s.line:find(" 5 23 ") then dropped = true else kept[#kept + 1] = s end end
sent = kept
deliver(CF2.s, MF2, "host")
check(#friend2.log == 1 and friend2.log[1].LogText:ToString() == "own", "one line missing: the friend's list stays as it was (" .. #friend2.log .. ")")

print("[C] NOLOG not on: nothing is asked")
local friend3 = makeLord(function() return 1.0 end, 130)
local CF3 = makeCoop("friend", "friend3", friend3, false)
local MF3 = load(CF3)
sent = {}
MF3.tick(CF3.s, 10.0)
local asked3 = false; for _, s in ipairs(sent) do if s.line:find("^R LOGASK ") then asked3 = true end end
check(not asked3, "no ask while NOLOG is not on")

print("[D] another friend's list is ignored")
local friend4 = makeLord(function() return 1.0 end, 130)
local CF4 = makeCoop("friend", "friend4", friend4, true)
local MF4 = load(CF4)
sent = {}
MF4.tick(CF4.s, 10.0)                                -- friend4 asks with its own serial
sent = {}
CF.s.worlds = 2                                       -- friend1 reloads and asks again
_G.Coop = CF
MF.tick(CF.s, 20.0)
deliver(CH.s, MH, "friend")
local q = sent
sent = q; deliver(CF4.s, MF4, "host")
check(#friend4.log == 0, "friend4 did not take friend1's list (" .. #friend4.log .. ")")

print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
return fail == 0
