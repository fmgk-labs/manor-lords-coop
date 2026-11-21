-- Desk test of lane 88's mercenary offers (coop_realm.lua mercsStr / mercsApply / pollGlobal with the native MERCCUT,
-- stood in for here by a function that shortens the list).
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane88/t_mercs.lua mod/ManorLordsCoop/Scripts/coop_realm.lua
-- The case of the lead's runs r27m83 and r27cf: a rival lord hired a company on the host (3 offers -> 2); the friend
-- kept 3 for the rest of the session. Now: the friend's first slots take the host's records in the host's order, the
-- list is cut to the host's count at the friend's next look (no 3 s wait: no own hire of this player was on its
-- way), a shorter list is refilled by the game's own refillMercenaries first, and without MERCCUT (another game build)
-- the old rule stands (the host's companies only, sorted) and never asks for a repair.
local pass = 0
local function ok(c, what) assert(c, "FAIL " .. what); pass = pass + 1; print("PASS " .. what) end
local function str(s) return { ToString = function() return s end } end
_G.FName = function(s) return str(s) end
_G.FindAllOf = function() return {} end
_G.RegisterHook = function() end
_G.StaticFindObject = function() return nil end
local t = 0
os.clock = function() return t end

-- a mercenary record as the script layer shows it: a text set from a Lua string reads back with ToString
local function rec(name, cost)
  local d = { cost = cost, colorA = 1, colorB = 2, emblemA = 3, emblemB = 4, arrivesIn = 5, units = { str("merc_inf") }, traits = {} }
  d.Name = str(name)
  return setmetatable({}, { __index = d, __newindex = function(_, k, v) if k == "Name" and type(v) == "string" then v = str(v) end; d[k] = v end })
end
local ENG = 0x50000
local cuts, refills = {}, 0
local function list(...)
  local l = { ... }
  return setmetatable(l, { __index = { GetArrayAddress = function() return ENG + 0xBF0 end } })
end
local function makeS(role, offers)
  local eng = { availableMercs = offers, regions = {}, buildingArr = {} }
  function eng:GetAddress() return ENG end
  function eng:refillMercenaries() refills = refills + 1; local a = self.availableMercs; a[#a + 1] = rec("fresh_" .. refills, 99) end
  local p1 = {}
  function p1:updateMercenayCompanyUI() end
  return { role = role, name = role == "host" and "host" or "friend1", worlds = 1, on = true, p1 = p1, eng = eng, stats = {} }
end
local avail = true
local C = { s = nil }
C.api = { un = function(x) return x end, valid = function(x) return x ~= nil and x ~= false end, log = function(f, ...) print("    " .. string.format(f, ...)) end,
  send = function() end, btype = function() return nil end, now = function() return t end, pawns = function() return {} end }
C.register = function(n, m) C.module = m end
C.patch = {
  mercAvail = function() return avail end,
  mercCut = function(e, l, now, want)
    cuts[#cuts + 1] = { e = e, l = l, now = now, want = want }
    local a = C.s.eng.availableMercs
    assert(#a == now, "the cut was asked with a wrong count")
    for i = #a, want + 1, -1 do a[i] = nil end
    return true
  end }
_G.Coop = C
assert(loadfile(ARG1))()
local M = assert(C.module, "realm did not register")
local R = C.realm
R.on.lords = false; R.on.perk = false; R.on.tax = false; R.on.policy = false; R.on.name = false; R.on.fams = false; R.on.notices = false
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 200 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name then return v end end
  for i = 1, 200 do local n, v = debug.getupvalue(fn, i); if not n then break end; if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end end
end
local mercsStr = assert(upvalue(M.tick, "mercsStr"), "mercsStr not found")
-- the host's list as it came (its count stood for 2 s already unless told otherwise: a cut waits 1.5 s, run l88b)
local function hostSays(v, age)
  R.gHost = R.gHost or {}; R.gHost.mercs = { v = v }
  local n = (v == "0") and 0 or select(2, v:gsub("|", "|")) + 1
  R.mercHostN = n; R.mercHostNT = os.clock() - (age or 2.0)
end
local pollGlobal = assert(upvalue(M.tick, "pollGlobal"), "pollGlobal not found")

-- the host after the rival's hire: two offers, in this order
local H = makeS("host", list(rec("vultures", 300), rec("greencaps", 200)))
local hostV = mercsStr(H, nil, true)
ok(hostV:match("^vultures;") ~= nil, "the host's offers go out in list order (vultures before greencaps)")

-- 1. the friend still holds the hired company (three offers, another order)
local F = makeS("friend", list(rec("greencaps", 200), rec("brigands", 150), rec("vultures", 300)))
C.s = F
hostSays(hostV); R.claimSent = {}; R.claimAck = {}
t = 10.0; pollGlobal(F, t, false)
t = 10.5; pollGlobal(F, t, false)
local a = F.eng.availableMercs
ok(#a == 2 and #cuts == 1 and cuts[1].now == 3 and cuts[1].want == 2 and cuts[1].l == ENG + 0xBF0, "3 offers here, 2 on the host: cut to 2 (MERCCUT 3 -> 2 on the engine's own list)")
ok(mercsStr(F, nil, true) == hostV, "the friend's list equals the host's, in the host's order: " .. mercsStr(F, nil, true):sub(1, 60))
ok((R.stats.failed or 0) == 0 and (R.stats.repairs or 0) == 0, "no failed apply, no repair asked")

-- 2. no wait for a rival's hire: the cut came at the friend's second look (0.5 s), not after 3 s
local F2 = makeS("friend", list(rec("vultures", 300), rec("greencaps", 200), rec("brigands", 150)))
C.s = F2; cuts = {}
hostSays(hostV)
t = 20.0; pollGlobal(F2, t, false)
ok(#F2.eng.availableMercs == 2 and #cuts == 1, "taken in the first look that saw the difference (no 3 s wait)")
-- ... but a company that just left this copy's own list (this player's hire, on its way to the host) keeps the wait
local F3 = makeS("friend", list(rec("vultures", 300)))
F3.mercGone = { name = "greencaps", t = 29.0 }
C.s = F3; refills = 0
hostSays(hostV)
t = 30.0; pollGlobal(F3, t, false); t = 31.0; pollGlobal(F3, t, false)
ok(#F3.eng.availableMercs == 1 and refills == 0, "this player's own hire on its way: nothing changed within 2 s")

-- 3. fewer offers here (the host's game refilled): the game's own refillMercenaries, then the host's records
local F4 = makeS("friend", list(rec("vultures", 300)))
C.s = F4; refills = 0; cuts = {}
hostSays(hostV)
t = 40.0; pollGlobal(F4, t, false)
ok(refills == 1 and #F4.eng.availableMercs == 2 and mercsStr(F4, nil, true) == hostV, "1 offer here, 2 on the host: the game's refill made one, and it took the host's record")

-- 3b. this copy's own game rolls new offers (its month change, run l88a): the host's last list is written back in the
-- next 0.1 s look, not after the 0.5 s look and its 3 s wait
local mercHold = assert(upvalue(M.tick, "mercHold"), "mercHold not found")
local F6 = makeS("friend", list(rec("vultures", 300), rec("greencaps", 200)))
C.s = F6; hostSays(hostV); R.mercT = nil; R.mercTry = nil
t = 60.0; mercHold(F6, t)
ok(mercsStr(F6, nil, true) == hostV, "(equal at the start)")
F6.mercGone = { name = "vultures", t = 60.0 }   -- (coop.lua names a company gone from this list: not a shorter list, so no hire of this player)
F6.eng.availableMercs[1].Name = "brigands"; F6.eng.availableMercs[2].Name = "battle_brothers"; F6.eng.availableMercs[3] = rec("crazy_goose", 50)
t = 60.05; mercHold(F6, t)
ok(mercsStr(F6, nil, true) ~= hostV, "(within 0.1 s of the last look nothing is read)")
t = 60.11; mercHold(F6, t)
local a6 = F6.eng.availableMercs
ok(#a6 == 3 and a6[1].Name:ToString() == "vultures" and a6[2].Name:ToString() == "greencaps", "this copy's own new offers: the host's two records written in the next 0.1 s look; no cut yet (run l88c: its own roll, the host's new list may follow)")
-- (a) the host's list stays 2: the cut comes 2 s after this copy's own change
for i = 1, 25 do t = 60.11 + i * 0.1; mercHold(F6, t) end
ok(mercsStr(F6, nil, true) == hostV and #F6.eng.availableMercs == 2, "... the host's list stayed 2: cut to 2 once this copy's own change is 2 s old")
-- (b) run l88c: this copy's own roll makes 3 and the host's new 3 come 0.2 s later: no cut, the host's 3 taken
F6.eng.availableMercs[1].Name = "brigands"; F6.eng.availableMercs[2].Name = "battle_brothers"; F6.eng.availableMercs[3] = rec("crazy_goose", 50)
t = 63.0; mercHold(F6, t)
-- ... and the host's new list is taken in the first look after it arrives
local H2 = makeS("host", list(rec("huntsmen", 120), rec("brotherhood_of_the_forest", 400), rec("brigands_small", 90)))
hostSays(mercsStr(H2, nil, true))
t = 63.2; mercHold(F6, t)
ok(mercsStr(F6, nil, true) == R.gHost.mercs.v, "the host's new list (3 other companies) is taken in the first look after it came")

-- 4. without MERCCUT (another game build): the old rule (the host's companies only, sorted), no cut, no repair
avail = false
local F5 = makeS("friend", list(rec("greencaps", 200), rec("brigands", 150), rec("vultures", 300)))
C.s = F5; cuts = {}; R.stats.failed = 0; R.stats.repairs = 0
hostSays(hostV)
for i = 0, 8 do t = 50.0 + i * 0.5; pollGlobal(F5, t, false) end
ok(#F5.eng.availableMercs == 3 and #cuts == 0 and (R.stats.failed or 0) == 0 and (R.stats.repairs or 0) == 0,
  "without MERCCUT the list stays 3 long and the host's two companies count as equal: no failed apply, no repair")

-- 5. this player's own hire seen by the 0.1 s look before the core has named the company: the list got shorter at a
-- look, nobody of the mod wrote it: no refill, no write for 5 s (the core sends O HIRE; the host hires the same)
avail = true; R.mercNoCut = nil; R.mercPrevN = nil; R.mercDropT = nil; R.mercT = nil; R.mercTry = nil; refills = 0
local H3 = makeS("host", list(rec("vultures", 300), rec("greencaps", 200), rec("huntsmen", 120)))
local F7 = makeS("friend", list(rec("vultures", 300), rec("greencaps", 200), rec("huntsmen", 120)))
C.s = F7; hostSays(mercsStr(H3, nil, true))
t = 80.0; mercHold(F7, t)
F7.eng.availableMercs[3] = nil                                            -- the player hired huntsmen here
t = 80.11; mercHold(F7, t); t = 80.5; pollGlobal(F7, t, false); t = 81.0; pollGlobal(F7, t, false); t = 82.0; mercHold(F7, t)
ok(#F7.eng.availableMercs == 2 and refills == 0, "the player's own hire (the list 3 -> 2 between two looks): nothing written or refilled within 2 s")
-- 6. a cut that does not take: the old rule from then on, no repair
C.patch.mercCut = function() return true end                               -- (says sent, does nothing)
local F8 = makeS("friend", list(rec("greencaps", 200), rec("brigands", 150), rec("vultures", 300)))
C.s = F8; hostSays(hostV); R.mercPrevN = nil; R.mercDropT = nil; R.stats.repairs = 0
for i = 0, 10 do t = 90.0 + i * 0.5; pollGlobal(F8, t, false) end
ok(R.mercNoCut == true and (R.stats.repairs or 0) == 0, "a cut that did not take: the old rule from then on (the host's companies only), no repair asked")

-- 7. (run l88b) the host's list stands shorter for 0.6 s at its own month roll: no cut (the shorter count must stand
-- 1.5 s), and nothing counted towards a resync
avail = true; R.mercNoCut = nil; R.mercShort = nil; R.stats.repairs = 0; R.stats.failed = 0; cuts = {}
C.patch.mercCut = function(e, l, now, want) cuts[#cuts + 1] = want; local a = C.s.eng.availableMercs; for i = #a, want + 1, -1 do a[i] = nil end; return true end
local three = makeS("host", list(rec("vultures", 300), rec("greencaps", 200), rec("huntsmen", 120)))
local F9 = makeS("friend", list(rec("vultures", 300), rec("greencaps", 200), rec("huntsmen", 120)))
C.s = F9; R.mercPrevN = nil; R.mercDropT = nil; R.mercT = nil; R.mercTry = nil
t = 100.0; hostSays(hostV, 0)                                              -- the host: 2 for a moment
for i = 1, 6 do t = 100.0 + i * 0.1; mercHold(F9, t) end; pollGlobal(F9, t, false)
hostSays(mercsStr(three, nil, true), 0)                                    -- and 3 again 0.6 s later
for i = 1, 20 do t = 100.6 + i * 0.1; mercHold(F9, t); if i % 5 == 0 then pollGlobal(F9, t, false) end end
ok(#cuts == 0 and #F9.eng.availableMercs == 3 and (R.stats.repairs or 0) == 0, "a host list shorter for 0.6 s is not cut to; 3 offers stay; no repair")
-- 8. fewer than the host and the game's refill makes nothing: the host's first records are written, no repair
local F10 = makeS("friend", list(rec("vultures", 300)))
local refillCalls10 = {}
F10.eng.refillMercenaries = function() refillCalls10[#refillCalls10 + 1] = t end
C.s = F10; R.mercRefillFor = nil; R.mercPrevN = nil; R.mercDropT = nil; R.mercT = nil; R.mercTry = nil; R.stats.repairs = 0
hostSays(hostV)
for i = 0, 12 do t = 120.0 + i * 0.5; pollGlobal(F10, t, false); mercHold(F10, t + 0.2) end
ok((R.stats.repairs or 0) == 0 and F10.eng.availableMercs[1].Name:ToString() == "vultures" and R.mercNoCut == nil,
  "1 offer here, 2 on the host, the refill makes none: the first record is the host's, no repair, the cut stays on")
ok(#refillCalls10 == 1, "... and the game's refill is called once for that host list, not at every look (" .. #refillCalls10 .. " calls; run l88c: 263)")
print(string.format("ALL %d PASS", pass))
