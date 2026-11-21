-- Desk test of lane 81: a quest whose name is not its preset row's reaches the friend (coop_x_events.lua presetOf).
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane81/t_quest_rows.lua mod/ManorLordsCoop/Scripts/coop_x_events.lua
-- (the harness of lane 88's t_quest_offer.lua; the quest table now has rows whose quest has another name, read with the
-- table's own ForEachRow, as the game's DT_Quests: live 47 rows, 5 such quest names)
local t, rows, sent = 0, {}, {}
os.clock = function() return t end
local function live(o) return type(o) == "table" and o.live == true end
local function str(s) return { ToString = function() return s end } end
_G.FName = function(s) return str(s) end
_G.FindAllOf = function() return {} end
_G.RegisterHook = function() end
local rowsDT = { "raiders_near", "spoils_of_war", "weapons_delivery_complete", "techQuest_21_1", "restoring_the_peace", "restoring_the_peace_storyonly", "msg_knight_intro", "msg_baron_intro" }
local qOf = { raiders_near = "raiders_near", spoils_of_war = "spoils_of_war", weapons_delivery_complete = "weapons_delivery",
  techQuest_21_1 = "develop_leatherworking", restoring_the_peace = "restoring_the_peace", restoring_the_peace_storyonly = "restoring_the_peace", msg_knight_intro = "No_Title", msg_baron_intro = "No_Title" }
DT = { ForEachRow = function(self, fn) for _, n in ipairs(rowsDT) do fn(n, { Name = str(qOf[n]) }) end end }
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
  local D = { live = true, DT_Quests = DT }
  function D:startQuestFromPreset(name, lord, _, _, offer) started[#started + 1] = { n = name:ToString(), t = t }; local l = offer and lord.proposedQuests or lord.quests; l[#l + 1] = quest(qOf[name:ToString()] or name:ToString()); return true end   -- the game names the quest by the row's quest
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
local function run(from, to) local x = from; while x <= to + 1e-9 do frame(x); x = x + 1 / 15 end end   -- 15 frames a second

-- 1. the host's game offers weapons_delivery (its row: weapons_delivery_complete) and runs develop_leatherworking
run(0, 4.99)
H.p1.proposedQuests[1] = quest("weapons_delivery")
H.p1.quests[1] = quest("develop_leatherworking")
run(5.0, 10)
local by = {}; for _, s in ipairs(started) do by[s.n] = (by[s.n] or 0) + 1 end
ok(by.weapons_delivery_complete == 1, "the offer weapons_delivery is started on the friend from the row weapons_delivery_complete, once")
ok(by.techQuest_21_1 == 1, "the running quest develop_leatherworking from the row techQuest_21_1, once")
ok(#F.p1.proposedQuests == 1 and F.p1.proposedQuests[1].Name:ToString() == "weapons_delivery", "the friend's offer list is the host's")
-- 2. a quest with a row of its own name: that row (not the _storyonly one)
H.p1.proposedQuests[2] = quest("restoring_the_peace")
run(t + 1 / 15, t + 5)
by = {}; for _, s in ipairs(started) do by[s.n] = (by[s.n] or 0) + 1 end
ok(by.restoring_the_peace == 1 and by.restoring_the_peace_storyonly == nil, "restoring_the_peace from its own row")
-- 3. a quest name no row makes: not started (as before)
H.p1.proposedQuests[3] = quest("no_such_quest")
local n0 = #started
run(t + 1 / 15, t + 5)
ok(#started == n0, "a quest no row makes is not started")
-- 4. a quest name made by two rows of other names: not guessed, not started
H.p1.proposedQuests[4] = quest("No_Title")
n0 = #started
run(t + 1 / 15, t + 5)
ok(#started == n0, "No_Title (made by msg_knight_intro and msg_baron_intro) is not started (no guess)")
print(string.format("RESULT %d passed, 0 failed", pass))
