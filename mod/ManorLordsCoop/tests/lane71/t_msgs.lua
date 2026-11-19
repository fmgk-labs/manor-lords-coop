-- Lane 71 desk test (no game): the friend's handling of Y V (coop_x_fields.lua), HW P and HW C (coop_x_values.lua),
-- run under a real Lua (5.1, through luacheck.py) with a made-up core, world and native piece.
--   py -3 -I luacheck.py run t_msgs.lua            (from this folder)
-- Cases: lines out of order, a field or site that is not here yet, a late line after a load, a building demolished
-- while held, nothing written during a hold (a join or resync).
local SCRIPTS = HERE .. "../../Scripts/"
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end

-- ---------------------------------------------------------------- Lua 5.4 pieces the modules use (5.1 has none)
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
local function f2b(x)                                   -- a float's IEEE-754 single bits
  if x == 0 then return 0 end
  local s = 0; if x < 0 then s = 0x80000000; x = -x end
  local m, e = math.frexp(x)                            -- x = m * 2^e, 0.5 <= m < 1
  e = e + 126
  if e <= 0 then return s + math.floor(x / 2 ^ -149 + 0.5) end
  return s + e * 2 ^ 23 + math.floor((m * 2 - 1) * 2 ^ 23 + 0.5)
end
local function b2f(u)
  local s = u >= 0x80000000 and -1 or 1; if u >= 0x80000000 then u = u - 0x80000000 end
  local e = math.floor(u / 2 ^ 23); local m = u - e * 2 ^ 23
  if e == 0 then return s * m * 2 ^ -149 end
  return s * (1 + m / 2 ^ 23) * 2 ^ (e - 127)
end
string.pack = string.pack or function(fmt, v) return (fmt == "<f" and "F" or "U") .. ":" .. string.format("%.17g", v) end
string.unpack = string.unpack or function(fmt, s)
  local k, v = s:match("^(%a):(.*)$"); v = tonumber(v)
  if fmt == "<I4" then return k == "F" and f2b(v) or v end
  return k == "U" and b2f(v) or v
end
local T = 100.0
os.clock = function() return T end

-- ---------------------------------------------------------------- a made-up game
local BM = {}; BM.__index = BM
function BM:GetAddress() return self.addr end
function BM:K2_GetActorLocation() return { X = self.x, Y = self.y, Z = 0 } end
function BM:GetType() return self.raw or self.t end
local nextAddr = 0x1000
local function building(t, x, y, extra)
  nextAddr = nextAddr + 0x100
  local b = setmetatable({ t = t, x = x, y = y, addr = nextAddr, Region = { alive = true }, field_numSown = 0, field_numUnplowed = 0,
    field_ploughingPerc = 0, field_numReadyToHarvest = 0, fieldWorkersNeeded = 0, fieldOperationMode = 0, forceHarvest = false,
    plannedHarvest_DaysLeft = 0, plannedHarvest_PredictedYield = 0, yield = 0, Data = { constructed = true }, onFire = false }, BM)
  for k, v in pairs(extra or {}) do b[k] = v end
  return b
end
local function valid(o) return type(o) == "table" and not o.dead end
local sent, logs, cmds = {}, {}, {}
local S = { role = "friend", eng = { buildingArr = {} }, startWall = 1000 }
local C = {}
_G.Coop = C
C.s = S
C.modules = {}
function C.register(name, m) C.modules[name] = m; return m end
function C.stale(peer, w) return (tonumber(w[2]) or 0) < S.startWall - 1 end     -- (the core's history rule, coop.lua: here by the stamp)
C.api = { un = function(x) return x end, valid = valid, btype = function(b) return b.t end, now = function() return 2000 end,
          log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function(l) sent[#sent + 1] = l end }
local function key(b) return string.format("%d@%d,%d", b.t, math.floor(b.x / 10 + 0.5), math.floor(b.y / 10 + 0.5)) end
C.world = { bkey = key, buildingByKey = function(k)
  for _, b in ipairs(S.eng.buildingArr) do if valid(b) and key(b) == k then return b end end end }
-- the native piece: commands are noted; its status names the two lane 71 items
local P = { fn = true, dir = "", items = { COLLAPSE = { state = "off" }, SITEHP = { state = "available" } } }
function P.send(l) cmds[#cmds + 1] = l; local a, b = l:match("^COLLAPSE (%u+)"); if a == "ON" then P.items.COLLAPSE.state = "on" elseif a == "OFF" then P.items.COLLAPSE.state = "off" end end
function P.tick() end
function P.status() return { state = "ready", items = P.items } end
local function words(l) local w = {}; for x in l:gmatch("%S+") do w[#w + 1] = x end; return w end
local function msg(mod, line) local w = words(line); return C.modules[mod].onMessage(S, "host", w[3], w, line) end
local function tick(dt) T = T + (dt or 0.6); for _, n in ipairs({ "fields", "values" }) do C.modules[n].tick(S, T) end end
local function has(list, pat) for _, l in ipairs(list) do if l:find(pat) then return true end end; return false end
local function clear(t) for i = #t, 1, -1 do t[i] = nil end end

-- load the two modules as the game would (fields loads values from its end); no native piece for the fields module:
-- its friend writes the values itself (the case of a field the native piece does not hold)
C.patch = nil
assert(loadfile(SCRIPTS .. "coop_x_fields.lua"))()
C.patch = P
local F, V = C.fields, C.values
check(C.modules.fields and C.modules.values, "both modules load and register (the values module from the end of the fields module)")
C.modules.fields.onWorld(S); C.modules.values.onWorld(S)

print("[Y V: the field routine's values]")
local fld = building(14, 79920, 41460)                                    -- a grain field: type 14, 0 / 0 here
local k = key(fld)
msg("fields", "1 1500 Y V " .. k .. " 2,1,5,40,0")
check(F.hv[k] ~= nil and (F.stats.adoptMiss or 0) >= 1, "a field that is not here yet: the values are kept, the field looked for (adoptMiss)")
tick(); check(fld.fieldOperationMode == 0, "nothing written while the field is not here")
S.eng.buildingArr[1] = fld
T = T + 2.5; tick()
check(fld.fieldOperationMode == 2 and fld.forceHarvest == true and fld.plannedHarvest_DaysLeft == 5 and fld.plannedHarvest_PredictedYield == 40,
      "once it is here: taken into the index by the host's key and written (mode 2, harvest planned, 5 days, 40)")
fld.fieldOperationMode = 0; fld.forceHarvest = false                      -- this copy's own field routine
tick(); check(fld.fieldOperationMode == 2 and fld.forceHarvest == true, "this copy's own routine is undone at the next pass")
msg("fields", "2 1501 Y V " .. k .. " 3,0,4,40,0"); msg("fields", "3 1502 Y V " .. k .. " 1,0,3,40,0")
tick(); check(fld.fieldOperationMode == 1 and fld.plannedHarvest_DaysLeft == 3, "two lines: the last that arrived is written (the link delivers in order; the module keeps no older value)")
msg("fields", "4 900 Y V " .. k .. " 9,1,9,9,9"); tick()
check(fld.fieldOperationMode == 1 and (F.stats.staleLine or 0) == 1, "a late line from before this copy's load is dropped")
C.hold = true; msg("fields", "5 1503 Y V " .. k .. " 2,1,2,40,0"); fld.fieldOperationMode = 7; tick()
check(fld.fieldOperationMode == 7, "during a join or resync nothing is written")
C.hold = nil; tick(); check(fld.fieldOperationMode == 2, "after it the host's value is written")
fld.Region = nil; fld.fieldOperationMode = 7; tick()
check(fld.fieldOperationMode == 7 and (F.stats.valErr or 0) == 0, "a field demolished (no region): not written, no error")
msg("fields", "6 1504 Y V " .. k .. " 1,2"); check((F.stats.valBad or 0) == 1, "a line with too few values is refused")

print("[HW P: a site's work]")
msg("values", "7 1505 HW X 1 1")
local site = building(4, 50000, 60000, { Data = { constructed = false } }); local sk = key(site)
msg("values", "8 1506 HW P " .. sk .. "=0.5000")
clear(cmds); tick(); check(not has(cmds, "SITEHP HOLD"), "a site that is not here yet: no hold")
S.eng.buildingArr[2] = site
tick(); check(has(cmds, "SITEHP HOLD " .. site.addr .. " 3F000000"), "once it is here: held at the host's fraction (0.5 = 3F000000)")
clear(cmds); tick(); check(not has(cmds, "SITEHP"), "the same fraction again: no command")
msg("values", "9 1507 HW P " .. sk .. "=0.7500"); clear(cmds); tick()
check(has(cmds, "SITEHP HOLD " .. site.addr .. " 3F400000"), "a new fraction (0.75): held again")
msg("values", "10 900 HW P " .. sk .. "=0.1000"); clear(cmds); tick()
check(not has(cmds, "SITEHP HOLD") and (V.stats.staleLine or 0) == 1, "a late line from before this copy's load is dropped")
C.hold = true; msg("values", "11 1508 HW P " .. sk .. "=0.9000"); clear(cmds); tick()
check(has(cmds, "SITEHP FORGET") and not has(cmds, "SITEHP HOLD"), "a join or resync: the holds are dropped, nothing held meanwhile")
C.hold = nil; clear(cmds); tick(); check(has(cmds, "SITEHP HOLD " .. site.addr .. " 3F666666"), "after it the host's newest fraction (0.9) is held")
site.dead = true; clear(cmds); tick()
check(has(cmds, "SITEHP DROP " .. site.addr), "a site demolished while held: dropped")
local site2 = building(4, 51000, 60000, { Data = { constructed = false } }); S.eng.buildingArr[3] = site2
msg("values", "12 1509 HW P " .. key(site2) .. "=0.2500"); tick()
site2.Data.constructed = true; clear(cmds); tick(); check(has(cmds, "SITEHP DROP " .. site2.addr), "a site built here: dropped")
site2.Data.constructed = false; tick(); msg("values", "13 1510 HW P " .. key(site2) .. "=-"); clear(cmds); tick()
check(has(cmds, "SITEHP DROP " .. site2.addr), "the host no longer names it (=-): dropped")

print("[HW C: a collapse]")
T = T + 3; tick(); check(P.items.COLLAPSE.state == "on", "the host heard and able: COLLAPSE ON here")
local mine = building(52, 70000, 80000); local mk = key(mine)
msg("values", "14 1511 HW C " .. mk); clear(cmds); tick()
check(not has(cmds, "COLLAPSE DO"), "a mine that is not here yet: nothing done, kept")
S.eng.buildingArr[4] = mine; clear(cmds); tick()
check(has(cmds, "COLLAPSE DO " .. mine.addr), "once it is here (within the wait): collapsed with the game's routine")
mine.raw = 75; msg("values", "15 1512 HW C " .. mk); clear(cmds); tick()
check(not has(cmds, "COLLAPSE DO") and (V.stats.collapseAlready or 0) == 1, "a line again for a ruin here: nothing done")
local m2 = building(52, 71000, 80000); S.eng.buildingArr[5] = m2
C.hold = true; msg("values", "16 1513 HW C " .. key(m2)); clear(cmds); tick()
check(not has(cmds, "COLLAPSE DO"), "during a join or resync: no collapse done")
C.hold = nil; clear(cmds); tick(); check(has(cmds, "COLLAPSE DO " .. m2.addr), "after it: done")
msg("values", "16b 1514 HW X 1 1")
msg("values", "17 1514 HW C 52@1,1"); T = T + 16; clear(cmds); tick(); tick()
check(not has(cmds, "COLLAPSE DO") and (V.stats.collapseLost or 0) == 1, "a collapse of a building never here: given up after the wait, logged")
msg("values", "18 900 HW C " .. key(m2)); check((V.stats.staleLine or 0) == 2, "a late collapse line from before this copy's load is dropped")
T = T + 40; clear(cmds); tick(); tick(); tick(); tick()
check(P.items.COLLAPSE.state == "off", "nothing from the host for 30 s: COLLAPSE OFF (this copy rolls its own again)")

print("[HW J: an injury on the host; MROLL]")
local notices = {}
_G.FName = function(s) return "FN:" .. s end
local lordP = { addr = 0x77, GetAddress = function(self) return self.addr end,
                addLog = function(self, tag, text, descr, opens, pos, actor) notices[#notices + 1] = { tag = tag, text = text, descr = descr, actor = actor } end }
local rival = { addr = 0x88, GetAddress = function(self) return self.addr end }
S.p1 = lordP
P.items.MROLL = { state = "off" }
local _send = P.send
P.send = function(l) _send(l); local a = l:match("^MROLL (%u+)"); if a == "ON" then P.items.MROLL.state = "on" elseif a == "OFF" then P.items.MROLL.state = "off" end end
msg("values", "19 1520 HW X 1 1 0"); T = T + 3; tick(); check(P.items.MROLL.state == "off", "the host cannot watch its accidents: MROLL stays off here")
msg("values", "20 1521 HW X 1 1 1"); T = T + 3; tick(); check(P.items.MROLL.state == "on", "the host watches its accidents: MROLL ON (the daily roll is the host's here)")
local wk = building(36, 90000, 10000, { ownerPawn = lordP }); local rk = building(36, 91000, 10000, { ownerPawn = rival })
S.eng.buildingArr[6] = wk; S.eng.buildingArr[7] = rk
msg("values", "21 1522 HW J " .. key(wk))
check(#notices == 1 and notices[1].tag == "FN:injury" and notices[1].text == "worker_injured" and notices[1].descr == "worker_injured_descr" and notices[1].actor == wk,
      "an injury at the player's own building: the game's own notice (injury, worker_injured)")
msg("values", "22 1523 HW J " .. key(rk)); check(#notices == 1, "an injury at another lord's building: no notice")
msg("values", "23 1524 HW J 36@1,1"); check(#notices == 1, "an injury at a building not here: no notice, no error")
C.hold = true; msg("values", "24 1525 HW J " .. key(wk)); check(#notices == 1, "during a join or resync: no notice"); C.hold = nil
msg("values", "25 900 HW J " .. key(wk)); check(#notices == 1, "a late line from before this copy's load: no notice")
T = T + 40; tick(); tick(); tick(); tick(); check(P.items.MROLL.state == "off", "nothing from the host for 30 s: MROLL OFF")

print("[FAMROLL: births, families, sickness]")
P.items.FAMROLL = { state = "off" }
local _send2 = P.send
P.send = function(l) _send2(l); local a = l:match("^FAMROLL (%u+)"); if a == "ON" then P.items.FAMROLL.state = "on" elseif a == "OFF" then P.items.FAMROLL.state = "off" end end
msg("values", "26 1530 HW X 1 1 1"); T = T + 3; tick()
check(P.items.FAMROLL.state == "off", "no people module here (nobody would make the host's growth): FAMROLL stays off")
C.people = { on = { grow = true, growRivals = true, families = true, members = true } }
T = T + 3; tick(); check(P.items.FAMROLL.state == "on", "the host heard and the people module makes its growth: FAMROLL ON")
C.hold = true; T = T + 3; tick(); check(P.items.FAMROLL.state == "on", "kept on through a join or resync (the world that comes is the host's)"); C.hold = nil
C.people.on.grow = false; T = T + 3; tick(); check(P.items.FAMROLL.state == "off", "the people module's growth switched off: FAMROLL OFF (this copy grows by itself again)")
C.people.on.grow = true; T = T + 3; tick(); check(P.items.FAMROLL.state == "on", "switched on again: FAMROLL ON")
T = T + 40; tick(); tick(); tick(); tick(); check(P.items.FAMROLL.state == "off", "nothing from the host for 30 s: FAMROLL OFF")
C.modules.values.idle(S); check(P.items.FAMROLL.state == "off", "at the menu: off")

print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("desk test failed") end
