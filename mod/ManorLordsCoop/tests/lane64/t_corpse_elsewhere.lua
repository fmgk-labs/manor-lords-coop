-- Desk test (lane 64, task 64d; research/.../lane_s21_64/design_deathregion.txt): the corpse rule keeps a person's body
-- that the host has unpaired in another region.
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane64/t_corpse_elsewhere.lua mod/ManorLordsCoop/Scripts
-- A friend's corpse rule (coop_x_events.lua friendCorpses) takes out a body the host has not in that region (up to 3 at
-- one look, after 3 s). A person's body is never made again here (only an animal's is), so a body that lies one region
-- over (a fight across a border) was taken out and the units count stayed short. Checked: a true extra still goes;
-- a body the host removed still goes at once; a person the host has unpaired in another region stays; it goes once
-- the host's pair is gone; an animal's body goes as before (its pair is made where the host has it); the switch off
-- gives the rule of before.
local scripts = assert(ARG1)
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local T = 1000.0
os.clock = function() return T end
local logs = {}
local nextA = 0x20000
local function obj(o) nextA = nextA + 16; local a = nextA; o.GetAddress = function() return a end; o.IsValid = function() return not o.gone end; return o end
local function valid(o) return type(o) == "table" and o.GetAddress ~= nil and o:IsValid() end
local M
Coop = { api = { un = function(x) return x end, valid = valid, now = function() return T end, isPaused = function() return false end,
    log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function() end },
  s = { role = "friend", worlds = 1 }, register = function(_, m) M = m end }
dofile(scripts .. "/coop_x_events.lua")
local E = Coop.events
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 250 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name and v ~= nil then return v end end
  for i = 1, 250 do
    local n, v = debug.getupvalue(fn, i); if not n then break end
    if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
  end
end
local friendCorpses
for _, f in pairs(M) do if type(f) == "function" and not friendCorpses then friendCorpses = upvalue(f, "friendCorpses") end end
check(type(friendCorpses) == "function", "friendCorpses found")

local function region(tag) local r = obj({ corpses = {} }); r.regionUniqueTag = { ToString = function() return tag end }; return r end
local sel, wald = region("sel"), region("wald")
local destroyed = {}
local S = { role = "friend", worlds = 1, worldT = 0, stats = {}, eng = obj({ regions = { sel, wald }, unitArr = {} }) }
function S.eng:getDaysTotal() return 400 end
function S.eng:destroyUnit(u)
  destroyed[#destroyed + 1] = u
  for _, r in ipairs({ sel, wald }) do for i = #r.corpses, 1, -1 do if r.corpses[i] == u then table.remove(r.corpses, i) end end end
  u.gone = true
end
local function body(reg, name, role)
  local u = obj({ dead = true, assignedUnitRole = role, DisplayName = { ToString = function() return name end }, realPos = { X = 100, Y = 200, Z = 0 } })
  reg.corpses[#reg.corpses + 1] = u
  return u
end
local function host(tag, list)                                    -- the host's list of a region as the events module holds it
  local l = {}
  for _, x in ipairs(list) do l[#l + 1] = { role = x[2], n = x[1], x = 100, y = 200, days = 1 } end
  E.hostC[tag] = { t = T - 1, n = #l, whole = true, list = l, day = 400 }
end
E.hostC = {}; E.cState = {}; E.pdQ = {}; E.stats = {}
E.on.vdeaths = false                                              -- (no animal body is made in this test: the making is not what is tested)
local function look(dt) T = T + (dt or 0); friendCorpses(S, T) end
local function gone(u) for _, d in ipairs(destroyed) do if d == u then return true end end; return false end

-- 1. a true extra body: the host has it nowhere
local karl = body(sel, "Karl", 5)
host("sel", {}); host("wald", {})
look(0); look(3.5)
check(gone(karl), "a person's body the host has nowhere: taken out after the settle time, as before")

-- 2. a body the host removed: it goes at once
local fritz = body(sel, "Fritz", 5)
host("sel", { { "Fritz", 5 } }); look(0.1)
host("sel", {}); look(0.1)
check(gone(fritz), "a body the host has just removed from this region's list: taken out at once, as before")

-- 3. the same person lying one region over: kept
local hans = body(sel, "Hans", 5)
host("sel", {}); host("wald", { { "Hans", 5 } })
look(0); look(3.5); look(3.5)
check(not gone(hans) and (E.stats.c_elsewhere or 0) >= 1, "a person's body the host has unpaired in another region (wald): kept (c_elsewhere " .. tostring(E.stats.c_elsewhere) .. ")")
local said = false; for _, l in ipairs(logs) do if l:find("unpaired in another region", 1, true) then said = true end end
check(said, "logged: kept, the same person lying elsewhere")
-- 4. two here, one on the host elsewhere: one stays, one goes
local h2 = body(sel, "Hans", 5)
look(0); look(3.5); look(3.5)
local n = (gone(hans) and 1 or 0) + (gone(h2) and 1 or 0)
check(n == 1, "two of that person here, one unpaired on the host: one is kept, the other taken out (" .. n .. " taken out)")
local left = gone(hans) and h2 or hans
-- 5. the host's pair goes (buried): the kept one goes too
host("wald", {})
look(0); look(3.5)
check(gone(left), "the host's body in wald is gone: the kept one is taken out by the rule as before")

-- 6. an animal's body: as before (its pair is made where the host has it, not kept here)
local sheep = body(sel, "Sheep", 10)
host("sel", {}); host("wald", { { "Sheep", 10 } })
look(0); look(3.5)
check(gone(sheep), "an animal's body the host has in another region: taken out as before (an animal's body is made where the host has it)")

-- 7. the switch off: the rule of before
E.on.corpseElsewhere = false
local otto = body(sel, "Otto", 5)
host("sel", {}); host("wald", { { "Otto", 5 } })
look(0); look(3.5)
check(gone(otto), "Coop.events.on.corpseElsewhere = false: taken out as before")
E.on.corpseElsewhere = true
print(string.format("RESULT: %d passed, %d failed", pass, fail))
return fail == 0
