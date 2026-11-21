-- Desk test of lane 88's rule for the lord's proposed quests (coop_x_events.lua: OWN_OFFERS, E.ownOffer, POLL_HOST,
-- the friend's look in its next tick after a changed "E Q").
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane88/t_quest_offer.lua mod/ManorLordsCoop/Scripts/coop_x_events.lua
-- The case of the lead's runs r27m83 and r27cf (day 365): the host's raid countdown offered "raiders_near"; the friend
-- started it 4.3 s later (a wait of 3 s for every offer, plus a look every second on both copies). Now:
--   * an offer only the host's game makes is started on the friend in its first tick after the host's line;
--   * "spoils_of_war" (every copy's soldiers offer it by themselves) still waits 3 s, as lane 66 made it;
--   * an offer this copy is seen making by itself is learned, and the host's next one of it waits too;
--   * the host looks at its lists every 0.25 s.
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
  function p1:getClosestOwnedRegion() return nil end
  local started = {}
  local D = { live = true, DT_Quests = {} }
  function D:startQuestFromPreset(name, lord, _, _, offer) started[#started + 1] = { n = name:ToString(), t = t }; local l = offer and lord.proposedQuests or lord.quests; l[#l + 1] = quest(name:ToString()); return true end
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

-- 1. both copies equal, then the host's game offers raiders_near at 10.00
run(0, 9.99)
H.p1.proposedQuests[1] = quest("raiders_near")
run(10.0, 16)
local s1 = started[1]
ok(s1 and s1.n == "raiders_near", "the host's raiders_near is started on the friend")
ok(s1 and s1.t - 10.0 < 0.6, string.format("... %.2f s after the host's offer (before: 4.3 s; the bar: 3 s)", s1 and s1.t - 10.0 or -1))
ok(#F.p1.proposedQuests == 1 and #started == 1, "... once")

-- 2. spoils_of_war still waits 3 s (the friend's own soldiers offer it a moment later by themselves)
H.p1.proposedQuests[2] = quest("spoils_of_war")
local t2 = t
run(t + 1 / 15, t + 2.5)
ok(#started == 1, "spoils_of_war is not started within 2.5 s (its own offer may still come here)")
F.p1.proposedQuests[#F.p1.proposedQuests + 1] = quest("spoils_of_war")       -- this copy's soldiers offer it by themselves
run(t + 1 / 15, t2 + 6)
ok(#started == 1 and #F.p1.proposedQuests == 2, "... and when this copy's own offer comes, the mod starts none (no second message)")

-- 3. an offer this copy makes by itself (more here than on the host) is learned: the host's next one waits
F.p1.proposedQuests[#F.p1.proposedQuests + 1] = quest("weapons_delivery")
run(t + 1 / 15, t + 3)
ok(E.ownOffer("weapons_delivery") == true, "an offer this copy made by itself is learned as its own")
ok(E.ownOffer("raiders_near") == false, "... an offer only the host made is not")
H.p1.proposedQuests[#H.p1.proposedQuests + 1] = quest("weapons_delivery")
H.p1.proposedQuests[#H.p1.proposedQuests + 1] = quest("weapons_delivery")
local t3 = t
run(t + 1 / 15, t + 2)
ok(#started == 1, "the host's second weapons_delivery (one more than here) waits: within 2 s nothing started")
run(t + 1 / 15, t3 + 5)
ok(#started == 2 and started[2].n == "weapons_delivery" and started[2].t - t3 >= 3.0, "... and is started after the wait when this copy did not make it")

-- 4. the host looks at its lists every 0.25 s
local n0 = 0; for _, l in ipairs(sent) do if l:match("^E Q ") then n0 = n0 + 1 end end
H.p1.quests[1] = quest("weapons_delivery")
local tq = t; run(t + 1 / 15, t + 0.4)
local firstQ
for i = #sent, 1, -1 do if sent[i]:match("^E Q weapons") then firstQ = true end end
ok(firstQ, "a change of the host's lists goes out within 0.4 s")
print(string.format("ALL %d PASS", pass))
