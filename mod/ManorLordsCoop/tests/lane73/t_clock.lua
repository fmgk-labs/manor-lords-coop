-- Self-test of the host's clock on a friend and of the held merchants (lane 73, 2026-11-18). Runs WITHOUT the game:
--     lua mod/ManorLordsCoop/tests/lane73/t_clock.lua <an empty folder to use>
-- (Lua 5.4, or LuaJIT / Lua 5.1 with the stand-ins below.) It loads the real coop.lua, coop_x_men.lua and
-- coop_x_merch.lua; the native piece is stood in for (its commands are caught), units are plain tables, the clock is
-- the test's own. It never touches the game, a save or the mod's real link folder.
-- What it shows:
--   1  a friend whose PC clock is 0.9 s BEHIND the host's, one 0.9 s AHEAD and one with the same clock get the SAME
--      age for the same host line (Coop.men.lineLag: lane 38's mirror in coop.lua, the merchants, the fields' count),
--      once the host has answered one MQ; "this copy's now() minus the line's clock" gave 0, 1.0 (the cap) and 0.15.
--      Before the first answer the clocks count as equal (the result of before). The three places call the helper.
--   2  the host's " link_ms=" for a friend's order, from the clock difference that friend sent with its MQ.
--   3  the merchants: with a native piece that knows the far-held mark a merchant is SET with ",3" and NOT dropped a
--      line later; put outright he is dropped and set (a fresh GO); gone from the host's full list he is dropped;
--      Coop.m73merch = false and a native piece of before give the SET and DROP of before.

local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane73/[^/]*$") or ".") .. "/Scripts/"
local dir = (arg and arg[1]) or ARG1
if not dir then print("give an empty folder: lua t_clock.lua <folder>"); os.exit(2) end
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
local T = 700.0
local clock0 = os.clock
os.clock = function() return T end

local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function slurp(path) local f = io.open(path, "rb"); if not f then return "" end; local s = f:read("a"); f:close(); return s end
local function words(line) local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end; return w end

dofile(scripts .. "coop.lua")
local C = _G.Coop
C.linkCut = 0
local sentCmds = {}
local farWord = " fars=0"
C.patch = { fn = function() end, dir = dir, tick = function() end,
            send = function(line) for l in tostring(line):gmatch("[^\n]+") do sentCmds[#sentCmds + 1] = l end end,
            status = function() return { items = { MEN = { state = "hooked" } }, text = "menstat held=0 pace=in raised=0 runoffs=0 rlast=0 lets=0 lead=0 leads=0" .. farWord } end }
dofile(scripts .. "coop_x_men.lua")
dofile(scripts .. "coop_x_merch.lua")
local M, men, merch = C.men, C.modules.men, C.modules.merch
check(M and M.lineLag and M.hostClock and M.linkMs and men and merch, "coop_x_men.lua and coop_x_merch.lua load outside the game")

-- ================================================================ 1  three friends, one host line
local lag, old, early, mage = {}, {}, {}, {}
for _, off in ipairs({ 0.9, 0.0, -0.9 }) do          -- the host's clock minus this friend's: behind, equal, ahead
  T = T + 20.0
  C.start("friend", "friend1", {})
  local S = C.s
  local f = io.open(dir .. "friend1.txt", "wb"); if f then f:close() end
  local function hostStamp(ago) return C.api.now() + off - ago end      -- the host's clock, <ago> s back
  -- before the host answered: the clocks count as equal (as before this lane)
  T = T + 0.05; men.tick(S, T)
  early[#early + 1] = M.lineLag(hostStamp(0.15), 1.0)
  local t0 = tonumber(slurp(dir .. "friend1.txt"):match(" MQ (%d+%.%d+)"))
  T = T + 0.24                                                           -- 0.12 s there, 0.12 s back
  men.onMessage(S, "host", "MQ", { "1", string.format("%.3f", (t0 or 0) + 0.12 + off), "MQ", "friend1", string.format("%.3f", t0 or 0) })
  T = T + 1.0
  local st = hostStamp(0.15)                                             -- a host line written 0.15 s ago
  lag[#lag + 1] = M.lineLag(st, 1.0)
  mage[#mage + 1] = M.lineLag(st, 0.4)
  old[#old + 1] = math.max(0, math.min(1.0, C.api.now() - st))
  if off == 0.9 then
    T = T + 5.0; men.tick(S, T)                                          -- the next question carries the measured difference
    local last; for l in slurp(dir .. "friend1.txt"):gmatch("[^\n]+") do if l:find(" MQ ", 1, true) then last = l end end
    check(last and math.abs((tonumber(last:match(" MQ %S+ (%-?%d+%.%d+)$")) or 99) - 0.9) < 0.005, "friend: its next MQ carries the clock difference it measured (" .. tostring(last and last:match("MQ .*$")) .. ")")
  end
end
local function near(a, b) return math.abs(a - b) < 0.003 end
check(near(lag[1], 0.15) and near(lag[2], 0.15) and near(lag[3], 0.15),
      string.format("a line 0.15 s old: the friend 0.9 s behind, the one with the same clock and the one 0.9 s ahead get the same age (%.3f, %.3f, %.3f)", lag[1], lag[2], lag[3]))
check(near(old[1], 0) and near(old[2], 0.15) and near(old[3], 1.0), string.format("this copy's own clock minus the line's gave %.3f, %.3f and %.3f for them (the fault)", old[1], old[2], old[3]))
check(near(mage[1], 0.15) and near(mage[2], 0.15) and near(mage[3], 0.15), "the merchants' age (held to 0.4 s) is the same for the three too")
check(near(early[1], 0) and near(early[2], 0.15) and near(early[3], 1.0), string.format("before the host's first MQ answer the clocks count as equal: the result of before (%.3f, %.3f, %.3f)", early[1], early[2], early[3]))
check(M.lineLag(nil, 1.0) == 0 and M.lineLag("x", 1.0) == 0 and M.lineLag(C.api.now() + 50, 1.0) == 0 and M.lineLag(C.api.now() - 50, 1.0) == 1.0, "no clock in the line, or one from the future: 0; an old line: the cap")
check(slurp(scripts .. "coop.lua"):find("C.men.lineLag(H.wall, 1.0)", 1, true) ~= nil, "coop.lua: lane 38's mirror asks lineLag for the host line's age")
check(slurp(scripts .. "coop_x_merch.lua"):find("C.men.lineLag(w[2], 0.4)", 1, true) ~= nil, "coop_x_merch.lua asks lineLag")
check(slurp(scripts .. "coop_x_fields.lua"):find("C.men.hostClock()", 1, true) ~= nil, "coop_x_fields.lua counts a line's delay by the host's clock")

-- ================================================================ 2  the host's link_ms
T = T + 20.0
C.start("host", "host", { "friend1" })
local S = C.s
check(M.linkMs("friend1", C.api.now() - 1.0) == "", "host: no clock difference known for a friend: no link_ms")
men.onMessage(S, "friend1", "MQ", { "7", "100.000", "MQ", "4321.500", "0.900" })
local lm = M.linkMs("friend1", C.api.now() - 0.9 - 0.13)
check(lm == " link_ms=130", "host: a friend 0.9 s behind, its order 0.13 s on the way: delay_ms would read 1030, link_ms reads 130 (" .. lm .. ")")
men.onMessage(S, "friend1", "MQ", { "8", "100.000", "MQ", "4326.500" })
check(M.linkMs("friend1", C.api.now()) == "", "host: an MQ without a clock difference (a new PC in that place) forgets the old one")

-- ================================================================ 3  the merchants
T = T + 20.0
C.start("friend", "friend1", {})
S = C.s
men.onWorld(S); merch.onWorld(S)
local unit = { IsValid = function() return true end, GetAddress = function() return 0x5000 end, realPos = { X = 1010, Y = 2000, Z = 30 },
               K2_SetActorLocation = function() end, assignedSquadID = { Value = 77 } }
S.eng = { IsValid = function() return true end, freeMerchants = { unit }, spawnMerchants = false }
S.p1 = { IsValid = function() return true end, GetAddress = function() return 1 end, Camera = { K2_GetComponentLocation = function() return { X = 9e6, Y = 9e6, Z = 0 } end } }
S.sc = { IsValid = function() return true end, IsValidSquad = function() return true end, GetUnitCount = function() return 1 end,
         GetSquad = function() return { squadType = 6, unitArr = { unit }, TargetLocation = { X = 0, Y = 0 } } end }
S.worldT = T - 60
T = T + 3.0; men.tick(S, T)                         -- (the status is read: this native piece knows the far-held mark)
local function fm(text) T = T + 0.25; sentCmds = {}; merch.onMessage(S, "host", "FM", words("9 " .. string.format("%.3f", C.api.now()) .. " FM " .. text)); return table.concat(sentCmds, " | ") end
local got = fm("1 77:1000,2000,30:91000,2000,30:156,0")
check(got == "MEN SET 5000=91000,2000,30,3", "merchant: set with the far-held mark (" .. got .. ")")
got = fm("0 77:1100,2000,30:91000,2000,30:156,0"); unit.realPos.X = 1110
check(got == "", "merchant: NOT dropped a line later; the same end is not set again (" .. got .. ")")
unit.realPos.X = 500
got = fm("0 77:1300,2000,30:91000,2000,30:156,0")
check(got == "MEN DROP 5000 | MEN SET 5000=91000,2000,30,3" and unit.realPos.X > 1290, "merchant 8 m behind and not seen: put, then out of the table and set again (a fresh GO from there) (" .. got .. ")")
got = fm("0 77:1400,2000,30:95000,2000,30:156,0"); unit.realPos.X = 1400
check(got == "MEN SET 5000=95000,2000,30,3", "merchant: the host's new end is set, no drop (" .. got .. ")")
unit.realPos.X = 1500
got = fm("1 77:1500,2000,30:95000,2000,30:156,0")
check(got == "", "merchant: named in the full list: stays (" .. got .. ")")
got = fm("1 -")
check(got == "MEN DROP 5000", "merchant no longer in the host's full list: out of the table (" .. got .. ")")
-- the switch, and a native piece of before
C.m73merch = false
got = fm("1 77:1500,2000,30:95000,2000,30:156,0"); local got2 = fm("0 77:1600,2000,30:95000,2000,30:156,0")
check(got == "MEN SET 5000=95000,2000,30" and got2 == "MEN DROP 5000", "Coop.m73merch = false: the SET and, a line later, the DROP of before (" .. got .. " | " .. got2 .. ")")
C.m73merch = nil; farWord = ""; T = T + 3.0; men.tick(S, T)
unit.realPos.X = 1700
got = fm("0 77:1700,2000,30:99000,2000,30:156,0"); got2 = fm("0 77:1800,2000,30:99000,2000,30:156,0")
check(got == "MEN SET 5000=99000,2000,30" and got2 == "MEN DROP 5000", "a native piece of before (no fars= in its status): the SET and DROP of before (" .. got .. " | " .. got2 .. ")")

-- ================================================================ 4  a villager taken late into a militia unit is armed
-- (Coop.men.armLate, called by the core's mirror): the animation table, the set name and the mode are written
-- together, the table first and the mode last, and only when the soldier's table is the game's own table for the set;
-- else nothing at all is written and the man stays as he is.
_G.FName = function(s) return { ToString = function() return s end, name = s } end
local function obj(addr, live) return { IsValid = function() return live ~= false end, GetAddress = function() return addr end } end
local combatDT, workDT = obj(0xC0, true), obj(0xD0, true)
local function villager()
  local writes, fields, equipped = {}, { animMode = 0, currentAnimsetDT = workDT, meleeTraining = 0 }, {}
  local u = setmetatable({ IsValid = function() return true end, GetAddress = function() return 0x7000 end,
                           GetEquippedID = function(_, s) return equipped[s] or 0 end, equip = function(_, g) writes[#writes + 1] = "equip" .. g; return true end },
                         { __index = fields, __newindex = function(_, k, v) writes[#writes + 1] = k; fields[k] = v end })
  return u, writes, fields
end
local soldier = { IsValid = function() return true end, GetAddress = function() return 0x8000 end, currentAnimsetDT = combatDT }
local engDT = combatDT
S.eng = { IsValid = function() return true end, getAnimsetDataTable = function(_, n) return engDT end }
local rids = { 0, 21, 0, 34 }
local u, wr, fl = villager()
local ok, n, how = M.armLate(S, u, soldier, 1, "combat", rids)
check(ok and n == 2 and table.concat(wr, ",") == "meleeTraining,equip21,equip34,currentAnimsetDT,currentAnimset,animMode" and fl.currentAnimsetDT == combatDT and fl.animMode == 1,
      "armed: training, the soldier's things, then the animation table, the set name and the mode last (" .. table.concat(wr, ",") .. "): " .. tostring(how))
u, wr, fl = villager(); engDT = nil
ok, n, how = M.armLate(S, u, soldier, 1, "combat", rids)
check(not ok and #wr == 0 and fl.animMode == 0 and fl.currentAnimsetDT == workDT, "the game has no table for the set: nothing is written, the man stays as he is (" .. tostring(how) .. ")")
u, wr, fl = villager(); engDT = obj(0xE0, true)
ok, n, how = M.armLate(S, u, soldier, 1, "combat", rids)
check(not ok and #wr == 0, "the soldier's table is not the game's table for the set: nothing is written (" .. tostring(how) .. ")")
u, wr, fl = villager(); engDT = combatDT
ok, n, how = M.armLate(S, u, { IsValid = function() return true end, GetAddress = function() return 0x8000 end, currentAnimsetDT = obj(0xC0, false) }, 1, "combat", rids)
check(not ok and #wr == 0, "the soldier's table is not a live object: nothing is written (" .. tostring(how) .. ")")
ok, n, how = M.armLate(S, u, { IsValid = function() return false end }, 1, "combat", rids)
check(not ok and #wr == 0, "the soldier is gone: nothing is written (" .. tostring(how) .. ")")
C.m73arm = false; u, wr, fl = villager()
ok, n, how = M.armLate(S, u, soldier, 1, "combat", rids)
check(ok and fl.currentAnimsetDT == workDT and fl.animMode == 1, "Coop.m73arm = false (the probe's old way): the mode and the set name, the work table left (" .. tostring(how) .. ")")
C.m73arm = nil
check(slurp(scripts .. "coop.lua"):find("arm(S, e.u, ref, rt, rset, rids)", 1, true) ~= nil and not slurp(scripts .. "coop.lua"):find("u.animMode = 1; u.currentAnimset = FName(rset)", 1, true),
      "coop.lua: the mirror arms through armLate and no longer writes the mode and the set name itself")

-- ================================================================ 5  merchants the host has and this copy lacks, and the other way
T = T + 20.0
C.start("friend", "friend1", {})
S = C.s
men.onWorld(S); merch.onWorld(S)
farWord = " fars=0"
local function mk(addr, sq, x) return { IsValid = function() return true end, GetAddress = function() return addr end, realPos = { X = x, Y = 2000, Z = 30 },
                                       K2_SetActorLocation = function() end, assignedSquadID = { Value = sq }, currentUnitRole = 6 } end
local m77, m95 = mk(0x5000, 77, 1000), mk(0x5100, 95, 90000)
local squads = { [77] = m77, [95] = m95 }
local made, destroyed = {}, {}
local trader = { IsValid = function() return true end, GetType = function() return 79 end, K2_GetActorLocation = function() return { X = 4000, Y = 4000, Z = 0 } end }
S.eng = { IsValid = function() return true end, freeMerchants = { m77, m95 }, livestockMerchants = {}, buildingArr = { trader }, unitArr = { m77, m95 }, spawnMerchants = false }
-- the game's spawnFreeMerchant as the probe showed it: a merchant WITHOUT a squad on the freeMerchants list, and a pack animal (role 15)
local spawnGives, nextAddr = true, 0x5200
function S.eng:spawnFreeMerchant(reg)
  made[#made + 1] = "free"
  if not spawnGives then return nil end
  local u = mk(nextAddr, 0, 0); u.UniqueID = 9000 + #made; nextAddr = nextAddr + 0x100
  local an = mk(nextAddr, 0, 0); an.currentUnitRole = 15; nextAddr = nextAddr + 0x100
  self.freeMerchants[#self.freeMerchants + 1] = u; self.unitArr[#self.unitArr + 1] = u; self.unitArr[#self.unitArr + 1] = an
  return u
end
function S.eng:spawnLivestockMerchant(b) local u = mk(0x5300, 0, 0); u.currentUnitRole = 7; self.livestockMerchants[#self.livestockMerchants + 1] = u; self.unitArr[#self.unitArr + 1] = u; made[#made + 1] = b == trader and "livestock at the trader" or "livestock elsewhere"; return u end
function S.eng:destroyUnit(u)
  destroyed[#destroyed + 1] = u
  for _, list in ipairs({ self.freeMerchants, self.livestockMerchants, self.unitArr }) do for i = #list, 1, -1 do if list[i] == u then table.remove(list, i) end end end
  for k, v in pairs(squads) do if v == u then squads[k] = nil end end
end
S.p1 = { IsValid = function() return true end, GetAddress = function() return 1 end, Camera = { K2_GetComponentLocation = function() return { X = 9e6, Y = 9e6, Z = 0 } end },
         getClosestOwnedRegion = function() return obj(0x99, true) end }
S.sc = { IsValid = function() return true end, IsValidSquad = function(_, t) return squads[t.Value] ~= nil end, GetUnitCount = function() return 1 end,
         GetSquad = function(_, t) return { squadType = 6, unitArr = { squads[t.Value] }, TargetLocation = { X = 0, Y = 0 } } end }
S.worldT = T - 60
T = T + 3.0; men.tick(S, T)
local function line(kind, text) T = T + 0.25; sentCmds = {}; merch.onMessage(S, "host", kind, words("9 " .. string.format("%.3f", C.api.now()) .. " " .. kind .. " " .. text)); return table.concat(sentCmds, " | ") end
local one = "77:1000,2000,30:91000,2000,30:0,0"
local both = one .. ";u500:3000,2000,30:92000,2000,30:0,0"       -- u500: a merchant of the host's without a squad (made after the save)
line("FM", "1 " .. both)
check(#made == 0 and #destroyed == 0, "a host merchant this copy lacks: not made in the first second (and a merchant on this copy only: not taken out at the first full list)")
for _ = 1, 5 do line("FM", "0 " .. both) end
local mm = C.merch.made["u500"]
check(#made == 1 and mm and mm.u.realPos.X == 3000 and mm.animal and mm.animal.currentUnitRole == 15 and mm.animal.realPos.X == 3150,
      "made after 1 s with the game's own spawnFreeMerchant, tied to the host's key, he and his pack animal put at the host's place")
got = line("FM", "0 " .. both)
check(#made == 1 and C.merch.set["5200"] ~= nil and C.merch.set["5200"][1] == 92000, "the made merchant is set to the host's path end, and no second one is made")
-- a merchant here with a squad that the host's full list does not name (95): seen in two full lists, then taken out
T = T + 1.5; line("FM", "1 " .. both)
check(#destroyed == 0, "default: the merchant already on this copy survives a full list after a replacement was made")
C.m58destroy = true
T = T + 1.5; line("FM", "1 " .. both)
check(#destroyed == 1 and destroyed[1] == m95, "a merchant of this copy only, seen in two full lists in a row: taken out with the game's own destroyUnit")
-- the host no longer names u500: after two full lists the made merchant goes, his pack animal first
C.m58destroy = nil
line("FM", "1 " .. one); check(#destroyed == 1, "the host no longer names the made merchant's key: not taken out at the first full list")
T = T + 1.5; got = line("FM", "1 " .. one)
check(#destroyed == 1 and C.merch.made["u500"] == mm, "default: the made merchant and his animal also survive missing lists")
C.m58destroy = true
T = T + 1.5; got = line("FM", "1 " .. one)
check(#destroyed == 3 and destroyed[2] == mm.animal and destroyed[3] == mm.u and C.merch.made["u500"] == nil and got:find("MEN DROP 5200", 1, true) ~= nil,
      "at the second full list: the pack animal, then the merchant, taken out; both out of the native table (" .. got .. ")")
local stray = 0; for _, u in ipairs(S.eng.unitArr) do if u.currentUnitRole == 15 then stray = stray + 1 end end
check(stray == 0 and #S.eng.freeMerchants == 1, "no stray unit is left: no pack animal, one merchant")
-- a make that gives nothing: one try, never again for that key
spawnGives = false; made = {}
local bad = one .. ";u600:3000,2000,30:92000,2000,30:0,0"
for _ = 1, 12 do line("FM", "1 " .. bad) end
check(#made == 1 and C.merch.failed["u600"] == "tried", "spawnFreeMerchant gives nothing: ONE try, then he is left missing (12 more lists, no second try)")
spawnGives = true
-- a merchant made here that the game takes away: said once, not made again
made = {}
local gone = one .. ";u650:3000,2000,30:92000,2000,30:0,0"
for _ = 1, 6 do line("FM", "0 " .. gone) end
local m650 = C.merch.made["u650"]
m650.u.IsValid = function() return false end
for _ = 1, 8 do line("FM", "0 " .. gone) end
check(#made == 1 and C.merch.made["u650"] == nil and C.merch.failed["u650"] == "gone", "a made merchant the game took away is not made again")
-- after a load of the host's save: this copy has the merchant without a squad, with the host's unit id: taken as he is
made = {}
local saved = mk(0x7000, 0, 3000); saved.UniqueID = 700
S.eng.freeMerchants[#S.eng.freeMerchants + 1] = saved; S.eng.unitArr[#S.eng.unitArr + 1] = saved
got = line("FM", "0 " .. one .. ";u700:3000,2000,30:93000,2000,30:0,0")
check(#made == 0 and C.merch.made["u700"] and C.merch.made["u700"].u == saved and got:find("7000=93000,2000,30,3", 1, true) ~= nil, "a merchant of this copy without a squad and with the host's unit id is the one for that key: none is made (" .. got .. ")")
-- (game run 11) after a load the host's merchant without a squad HAS a squad number here: still the one for the key,
-- none is made, and he is not taken out as "on this copy only"
local saved2 = mk(0x7100, 1523397618, 40000); saved2.UniqueID = 710; squads[1523397618] = saved2
S.eng.freeMerchants[#S.eng.freeMerchants + 1] = saved2; S.eng.unitArr[#S.eng.unitArr + 1] = saved2
local l710 = one .. ";u700:3000,2000,30:93000,2000,30:0,0;u710:40000,2000,30:93000,2000,30:0,0"
line("FM", "1 " .. l710); T = T + 1.6; line("FM", "1 " .. l710); T = T + 1.6; line("FM", "1 " .. l710)
local out2 = false; for _, u in ipairs(destroyed) do if u == saved2 then out2 = true end end
check(#made == 0 and C.merch.made["u710"] and C.merch.made["u710"].u == saved2 and not out2, "a merchant here with a squad number the host does not name and the host's unit id is the one for that key: none made, not taken out")
C.m58spawn = false; made = {}
for _ = 1, 8 do line("FM", "1 " .. one .. ";u700:3000,2000,30:93000,2000,30:0,0;u710:40000,2000,30:93000,2000,30:0,0;u800:3000,2000,30:92000,2000,30:0,0") end
check(#made == 0, "Coop.m58spawn = false: none is made")
-- (lane 64's live finding) after a load EVERY merchant of this copy has a number the host's list does not name, and
-- this copy has one merchant FEWER than the host: nobody is taken out, however many lists say so
local base = one .. ";u700:3000,2000,30:93000,2000,30:0,0;u710:40000,2000,30:93000,2000,30:0,0"
local strangers = {}
for i = 1, 3 do local u = mk(0x7200 + i * 0x100, 300 + i, 50000 + i * 1000); strangers[i] = u; S.eng.freeMerchants[#S.eng.freeMerchants + 1] = u; S.eng.unitArr[#S.eng.unitArr + 1] = u end
local hostOnly = ""; for i = 1, 4 do hostOnly = hostOnly .. string.format(";%d:%d,2000,30:93000,2000,30:0,0", 200 + i, 50000 + i * 1000) end
local nd0 = #destroyed
for _ = 1, 4 do T = T + 1.6; line("FM", "1 " .. base .. hostOnly) end
check(#destroyed == nd0 and (S.stats.m73extraHeld or 0) >= 4 and S.stats.m58extraNow == 3,
      "three merchants here that the host's list does not name while the host names more merchants than this copy has: none is taken out (4 full lists), and the count says 3 here only now")
-- the same three with a host that has three fewer: they are this copy's surplus; out after two such lists, not at the first
line("FM", "1 " .. base); check(#destroyed == nd0, "the first list that makes them a surplus: not taken out yet (the 1.5 s start again)")
T = T + 1.6; line("FM", "1 " .. base)
check(#destroyed == nd0 + 3 and S.stats.m58extraNow == 3, "three merchants over the host's count, in two full lists in a row: the three are taken out")
line("FM", "1 " .. base); check(S.stats.m58extraNow == 0, "then none is here only")
-- a full list in two lines (over 3000 characters): the keys of the first line count too
local nd1 = #destroyed
for _ = 1, 3 do T = T + 1.6; line("FM", "0 " .. one); line("FM", "1 u700:3000,2000,30:93000,2000,30:0,0;u710:40000,2000,30:93000,2000,30:0,0") end
check(#destroyed == nd1, "a full list that comes in two lines: a merchant named in the first line is not taken out")
C.m58spawn = nil; C.m73lvspawn = true; made = {}; destroyed = {}
-- the livestock merchant
line("FL", "4100,4100,0:79,4000,4000"); check(#made == 0, "a livestock merchant this copy lacks: not made in the first second")
T = T + 1.0; line("FL", "4100,4100,0:79,4000,4000")
check(#made == 1 and made[1] == "livestock at the trader" and S.eng.livestockMerchants[1].realPos.X == 4100, "made after 1 s with spawnLivestockMerchant at the building the host names, put at the host's place")
line("FL", "4100,4100,0:79,4000,4000"); check(#made == 1, "the same number as the host: nothing more is made")
local nd = #destroyed
line("FL", "-"); check(#destroyed == nd, "the host has none any more: not taken out at the first list")
T = T + 1.5; line("FL", "-")
check(#destroyed == nd + 1 and #S.eng.livestockMerchants == 0, "in two lists in a row: taken out with destroyUnit")
line("FL", "4100,4100,0:12,1,1"); T = T + 1.0; made = {}; line("FL", "4100,4100,0:12,1,1")
check(#made == 0, "the building the host names is not here: none is made (said in the log, tried again after 30 s)")
-- the unit counts each minute
line("FN", "3 1 2")
T = T + 61.0; merch.tick(S, T)
local lg = slurp(dir .. "friend1_log.txt")
check(lg:find("free merchants %d+ / 3, livestock merchants 0 / 1, pack animals %d+ / 2: DIFFERENT") ~= nil, "the minute line compares the unit counts of roles 6, 7 and 15 with the host's")
check(lg:find("the host's merchant u500 had none here: made one", 1, true) ~= nil and lg:find("the host no longer names u500: the merchant made here for it goes", 1, true) ~= nil
      and lg:find("spawnFreeMerchant gave nothing", 1, true) ~= nil and lg:find("for the host's u650 is gone", 1, true) ~= nil, "one log line per made, removed, failed and lost merchant")
-- host: the livestock list and the counts go out
T = T + 20.0
C.start("host", "host", { "friend1" })
S = C.s; merch.onWorld(S)
local lm1 = mk(0x6000, 0, 700); lm1.currentUnitRole = 7; lm1.getWorkplace = function() return trader end
local hm = mk(0x6100, 0, 900); hm.UniqueID = 431; hm.Path = {}; hm.PathPoint = 0; hm.getTargetPos = function() return { X = 5000, Y = 6000, Z = 0 } end
S.eng = { IsValid = function() return true end, freeMerchants = { hm }, livestockMerchants = { lm1 }, unitArr = { lm1, m77, hm }, buildingArr = { trader } }
S.p1 = { IsValid = function() return true end, GetAddress = function() return 1 end }
S.sc = { IsValid = function() return true end }
local fh = io.open(dir .. "host.txt", "wb"); if fh then fh:close() end
T = T + 3.0; merch.tick(S, T)
local ht = slurp(dir .. "host.txt")
check(ht:find(" FL 700,2000,30:79,4000,4000\n", 1, true) ~= nil and ht:find(" FN 2 1 0\n", 1, true) ~= nil, "host: the livestock merchants (place, workplace) with a full list, and the unit counts of roles 6, 7, 15")
check(ht:find(" FM 1 u431:900,2000,30:5000,6000,0:0,0\n", 1, true) ~= nil, "host: a merchant without a squad is sent under the key u<his unit id> (before, he was never sent)")

os.clock = clock0
pcall(C.stop)
print(string.format("RESULT: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
