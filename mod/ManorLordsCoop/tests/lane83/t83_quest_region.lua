-- (lane 83) Desk test: the region the friend gives an offer it starts on the host's word (coop_x_events.lua friendQuests).
-- The host's "raiders_near" has NO region (the game's own): the friend's copy must get none (run 22: it got the lord's
-- closest region). A region the host names that this copy cannot find: the closest region, as before.
-- Setup: lane 88's t_quest_offer.lua (lines 10-63), the stand-in director recording the region it was given.
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane83/t83_quest_region.lua mod/ManorLordsCoop/Scripts/coop_x_events.lua
local t, rows, sent = 0, {}, {}
os.clock = function() return t end
local function live(o) return type(o) == "table" and o.live == true end
local function str(s) return { ToString = function() return s end } end
_G.FName = function(s) return str(s) end
_G.FindAllOf = function() return {} end
_G.RegisterHook = function() end
local rowsDT = { "raiders_near", "spoils_of_war", "weapons_delivery" }
_G.StaticFindObject = function() return { GetDataTableRowNames = function(_, _, out) for i, n in ipairs(rowsDT) do out[i] = str(n) end end } end
-- the module loaded twice, a host's copy and a friend's copy, each with its own stand-in Coop (its state is per copy)
local function load(sendTo)
  local m
  _G.Coop = {
    register = function(name, x) m = x end, stale = function() return false end,
    api = { valid = live, un = function(o) return o end, now = os.clock, log = function(fmt, ...) rows[#rows + 1] = string.format(fmt, ...) end,
      send = sendTo, pawns = function() return {} end, later = function() end },
  }
  local r = assert(loadfile(ARG1))()
  assert(m and m.tick, "the module did not register: " .. tostring(r))
  local E = _G.Coop.events
  for k in pairs(E.on) do E.on[k] = false end
  E.on.quests, E.on.questStart, E.on.extraClose = true, true, true
  return m, E
end
local hostMod = load(function(line) sent[#sent + 1] = line end)
local mod, E = load(function() end)
local pass = 0
local function ok(c, what) assert(c, "FAIL " .. what); pass = pass + 1; print("PASS " .. what) end
local function quest(n) return { Name = str(n), regions = {} } end
local function copy(role)
  local p1 = { live = true, quests = {}, proposedQuests = {}, questOpportunities = {} }
  function p1:GetAddress() return 1 end
  function p1:getClosestOwnedRegion() return CLOSEST end
  local started = {}
  local D = { live = true, DT_Quests = {} }
  function D:startQuestFromPreset(name, lord, _, reg, offer) started[#started + 1] = { n = name:ToString(), t = t, reg = reg }; local l = offer and lord.proposedQuests or lord.quests; l[#l + 1] = quest(name:ToString()); return true end
  local eng = { live = true, questDirector = D, regions = {}, buildingArr = {}, independentBuildings = {} }
  return { role = role, worlds = 1, stats = {}, p1 = p1, eng = eng, name = role == "host" and "host" or "friend1", on = true }, started
end
local H = copy("host")
local F, started = copy("friend")
local function words(line) local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end; return w end
-- one frame of both copies at time x: the host's tick, its lines carried to the friend at once, the friend's tick
local function frame(x)
  t = x; local n0 = #sent
  hostMod.tick(H, x)
  for i = n0 + 1, #sent do
    local line = "1 " .. string.format("%.3f", x) .. " " .. sent[i]
    local w = words(line)
    if w[3] == "E" then mod.onMessage(F, "host", "E", w, line) end
  end
  mod.tick(F, x)
end
local function run(from, to) local x = from; while x <= to + 1e-9 do frame(x); x = x + 1 / 15 end end   -- 15 frames a second (up.sh's cap)
CLOSEST = { live = true, regionUniqueTag = str("closest") }
-- 1. the host's game offers raiders_near with no region
run(0, 9.99)
H.p1.proposedQuests[1] = quest("raiders_near")
run(10.0, 13)
local s1 = started[1]
ok(s1 and s1.n == "raiders_near", "the host's raiders_near (no region) is started on the friend")
ok(s1 and s1.reg == nil, "... with no region, as the host's (before: the lord's closest region): " .. tostring(s1 and s1.reg and s1.reg.regionUniqueTag:ToString()))
-- 2. an offer whose host record names a region this copy cannot find: the closest region, as before
local q = quest("weapons_delivery"); q.regions = { { live = true, regionUniqueTag = str("faraway") } }
H.p1.proposedQuests[2] = q
run(t + 1 / 15, t + 3)
local s2 = started[2]
ok(s2 and s2.n == "weapons_delivery", "an offer with a region on the host is started on the friend")
ok(s2 and s2.reg == CLOSEST, "... a region the friend cannot find: the lord's closest region (unchanged)")
-- 3. (the issued day) the host's raiders_near issued on day 365; the friend started its copy on 364 (before its own day
-- change): the friend's record takes the host's day
H.p1.proposedQuests[1].issuedOnDay = 365
for _, q in ipairs(F.p1.proposedQuests) do if q.Name:ToString() == "raiders_near" then q.issuedOnDay = 364 end end
run(t + 1 / 15, t + 2)
local fq; for _, q in ipairs(F.p1.proposedQuests) do if q.Name:ToString() == "raiders_near" then fq = q end end
ok(fq and fq.issuedOnDay == 365, "the friend's raiders_near takes the host's issued day (364 -> " .. tostring(fq and fq.issuedOnDay) .. ")")
local nq = 0; for _, q in ipairs(F.p1.proposedQuests) do if q.Name:ToString() == "raiders_near" then nq = nq + 1 end end
ok(nq == 1, "... and no second offer is started for it")
print("ALL " .. pass .. " PASS")
