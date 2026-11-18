-- Lane 67 desk test of coop_x_maint.lua without the game: stub core, native piece, world, buildings.
--   py -3 -I luacheck.py run t_maint_desk.lua         (Lua 5.1 through ctypes; HERE = this folder)
-- Cases: a host line held, a repeat, lines out of order, a building demolished while held, a late line after a
-- load, the host's own lines.
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end

local native, sent, logs, mods = {}, {}, {}, {}
local function valid(o) return o ~= nil and (type(o) ~= "table" or o.alive ~= false) end
local function comp(addr, st, sl, trk)
  return { alive = true, addr = addr, st = st, sl = sl, trk = trk, GetAddress = function(self) return self.addr end, SetSliderValue = function(self, v) self.sl = tostring(v) end }
end
local c1, c2 = comp(0x1000, 3, 1, "21=0"), comp(0x2000, 1, 1, "12+30=8")
local b1 = { alive = true, key = "89@1,2", MaintenanceComponent = c1 }
local b2 = { alive = true, key = "72@5,6", MaintenanceComponent = c2 }
local S = { role = "friend", eng = { alive = true, buildingArr = { b1, b2 } }, p1 = { alive = true }, stats = {} }

local P = { fn = true, dir = "X/", st = { items = { MAINT = { state = "available", why = "held=0" } } } }
function P.status() return P.st end
function P.send(l) for x in (l .. "\n"):gmatch("([^\n]*)\n") do native[#native + 1] = x end end
function P.tick() end
local realOpen = io.open
io.open = function(path, mode)
  if path == "X/maint.txt" then
    local t = {}
    for _, b in ipairs(S.eng.buildingArr) do local c = b.MaintenanceComponent; if c.alive then t[#t + 1] = string.format("%X %d %s %s", c.addr, c.st, tostring(c.sl), c.trk) end end
    t[#t + 1] = "END"
    local txt = table.concat(t, "\r\n") .. "\r\n"
    return { read = function() return txt end, close = function() end }
  end
  return realOpen(path, mode)
end
local W = { bkey = function(b) return b.key end, keyframe = function() return "kf" end }
local C = { register = function(n, m) mods[n] = m end, patch = P, world = W, men = { loadBegins = function() end },
  api = { valid = valid, un = function(x) return x end, send = function(l) sent[#sent + 1] = l end,
          log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end } }
_G.Coop = C
local chunk = assert(loadfile(HERE .. "../../Scripts/coop_x_maint.lua"))
print(chunk())
local M = mods.maint
local clock = 10.0
local function ticks(n, dt) for _ = 1, n do clock = clock + (dt or 0.02); M.tick(S, clock) end end
local function line(wall, full, body) return M.onMessage(S, "host", "MC", { "1", string.format("%.3f", wall), "MC", full, body }) end
local function has(list, s) for _, x in ipairs(list) do if x == s then return true end end; return false end
local function count(list, pat) local n = 0; for _, x in ipairs(list) do if x:find(pat, 1, true) then n = n + 1 end end; return n end

print("[friend]")
ticks(5, 1.1)                                                  -- index, a read pass
line(100, "0", "89@1,2|1|1|21=10;72@5,6|1|1|12+30=8")
check(has(native, "MAINT SET 1000 1 21=10") and has(native, "MAINT SET 2000 1 12+30=8"), "a host line: both buildings set in the native table")
local n0 = count(native, "MAINT SET")
line(101, "0", "89@1,2|1|1|21=10")
check(count(native, "MAINT SET") == n0, "the same values again: nothing sent to the native table")
line(105, "0", "89@1,2|1|1|21=8")
line(103, "0", "89@1,2|1|1|21=9")
check(has(native, "MAINT SET 1000 1 21=8") and not has(native, "MAINT SET 1000 1 21=9") and (S.stats.mcOlder or 0) == 1, "lines out of order: the older entry (host clock 103 after 105) is not used")
c1.alive = false; b1.alive = false
ticks(3, 1.1)
check(has(native, "MAINT DROP 1000") and (S.stats.mcGone or 0) == 1, "a building demolished while held: dropped from the native table after the next read pass")
native = {}
M.onWorld(S)
check(has(native, "MAINT FORGET"), "a load (a new world): the native table is emptied")
c1.alive = true; b1.alive = true; c1.addr = 0x3000
line(104.5, "0", "89@1,2|1|1|21=7")
check(count(native, "MAINT SET") == 0 and (S.stats.mcLate or 0) == 1, "a late line after the load (host clock before the last line of the old world): not used")
line(200, "1", "89@1,2|1|1|21=6;72@5,6|1|1|12+30=8")
ticks(5, 1.1)
check(has(native, "MAINT SET 3000 1 21=6"), "the first line of the new world: set once the new index has the building (new address)")
c1.sl = "1"; line(201, "0", "89@1,2|1|2|21=6"); ticks(8, 1.1)
check(c1.sl == "2" and (S.stats.mcSlider or 0) == 1, "a slider that stayed off the host's for 4 s: the host's is put back")
native = {}; C.hold = true; ticks(1)
check(has(native, "MAINT FORGET"), "the join module holds (a load begins): the native table is emptied"); C.hold = nil

print("[host]")
local SH = { role = "host", eng = S.eng, p1 = S.p1, stats = {} }
M.onWorld(SH); sent = {}
ticks(1); for _ = 1, 6 do clock = clock + 1.1; M.tick(SH, clock) end
check(#sent >= 1 and sent[1]:find("^MC 1 ") and sent[1]:find("89@1,2|3|2|21=0", 1, true) and sent[1]:find("72@5,6|1|1|12+30=8", 1, true), "the host's first line is whole and holds both buildings: " .. tostring(sent[1]))
local ns = #sent; clock = clock + 1.1; M.tick(SH, clock)
check(#sent == ns, "nothing changed: no line")
c2.trk = "12+30=6"; clock = clock + 1.1; M.tick(SH, clock); clock = clock + 0.1; M.tick(SH, clock)
check(sent[#sent] == "MC 0 72@5,6|1|1|12+30=6", "a tracker changed: one line with that building: " .. tostring(sent[#sent]))
c2.alive = false; b2.alive = false; for _ = 1, 3 do clock = clock + 1.1; M.tick(SH, clock) end
check(sent[#sent]:find("72@5,6|!", 1, true) ~= nil, "a building gone: '|!' sent: " .. tostring(sent[#sent]))

print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("desk test failed") end
