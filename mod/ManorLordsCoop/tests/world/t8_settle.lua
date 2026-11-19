-- Desk test. Feed timestamped host observations through the world's message handler.
-- Run with lane67/luacheck.py run and the path to coop_world.lua as the first argument.
local t, rows, sent, mod = 0, {}, {}, nil
os.clock = function() return t end
math.type = math.type or function(n) return n == math.floor(n) and "integer" or "float" end
local function live(o) return type(o) == "table" and o.live == true end
Coop = {
  register = function(_, m) mod = m end, stale = function() return false end,
  api = { valid = live, un = function(o) return o end, now = os.clock,
    log = function(fmt, ...) rows[#rows + 1] = string.format(fmt, ...) end,
    send = function(line) sent[#sent + 1] = line end }
}
assert(loadfile(ARG1))()
-- Exercise the registered module's follow-up step without starting unrelated game jobs.
local check
for i = 1, 30 do
  local name, v = debug.getupvalue(mod.onMessage, i)
  if name == "Check" then check = v; break end
end
assert(check)
local weather = { live = true, rainMeter = 0 }
local S = { role = "friend", worlds = 0, stats = {}, p1 = { live = true, GetAddress = function() return 123456 end },
  eng = { live = true, TemporalComponent = weather } }
local function run(desc, host, friend, want, gap, friendGap)
  S.worlds = S.worlds + 1; rows, sent = {}, {}; t = 10; Coop.world.prepare(S)
  local id = "wx~TIME~rainMeter"
  check.section("42", "wx", { { k = "TIME", f = "rainMeter", at = t, m = tostring(friend(t)) } })
  for i = 0, 32 do
    local stamp = 7 + 0.25 * i
    if not gap or not gap(stamp) then
      mod.onMessage(S, "host", "W", { "1", "10", "W", "OBS", tostring(stamp), id .. "=" .. host(stamp) })
    end
    if stamp >= 10 and not (friendGap and friendGap(stamp)) then
      t = stamp; weather.rainMeter = friend(t); check.tick(S)
    end
  end
  local result = table.concat(rows, "\n")
  assert(sent[1] == "W WATCH 42 " .. id, desc .. ": no request for the differing field")
  assert(result:find(want, 1, true), desc .. "\n" .. result)
  print("PASS " .. desc)
end
run("an intermediate host value is inside the three-second window",
  function(n) return n < 9 and 4 or n < 10.75 and 7 or 9 end,
  function(n) return n < 11 and 4 or n < 13.5 and 7 or 9 end,
  "settled=1 past3=0 foreign=0 stale=0 unverified=0")
run("a value expires three seconds after the host last had it",
  function(n) return n <= 9.75 and 4 or 9 end, function() return 4 end,
  "settled=0 past3=1 foreign=0 stale=1 unverified=0")
run("a foreign value stays on the friend", function() return 4 end, function() return 11 end,
  "settled=0 past3=1 foreign=1 stale=0 unverified=0")
run("a foreign value settles before the recheck", function() return 4 end,
  function(n) return n < 10.5 and 11 or 4 end, "settled=1 past3=0 foreign=1 stale=0 unverified=0")
run("a later host value cannot excuse an earlier friend reading",
  function(n) return n < 11 and 4 or 9 end, function() return 9 end,
  "settled=1 past3=0 foreign=1 stale=0 unverified=0")
run("missing observations fail closed", function() return 4 end, function() return 11 end,
  "unverified=1", function(n) return n >= 10 and n <= 12.75 end)
run("matching endpoints cannot cover an unobserved interval on the friend",
  function() return 4 end, function() return 4 end,
  "settled=0 past3=0 foreign=0 stale=0 unverified=1", nil, function(n) return n > 10 and n < 13 end)
run("the original day and both timestamped follow-up series are auditable",
  function() return 4 end, function() return 11 end,
  "hostMs=-3000:4;-2750:4")
assert(table.concat(rows, "\n"):find("friendMs=0:11;250:11", 1, true))
run("an older matching host value cannot supply the separate endpoint read",
  function() return 4 end, function() return 4 end, "unverified=1", function(n) return n > 10.25 end)

S.worlds = S.worlds + 1; S.role = "host"; t = 20; rows, sent = {}, {}
Coop.world.prepare(S); Coop.world.day = 41; weather.rainMeter = 9
mod.onMessage(S, "friend1", "W", { "1", "20", "W", "WATCH", "42", "wx~TIME~rainMeter" })
check.tick(S)
assert(table.concat(sent, "\n"):find("W OBS 20.000 wx~TIME~rainMeter=9", 1, true),
  "a friend starting the next day first lost its entire watch")
S.role = "friend"
print("PASS the host starts reading an early next-day request on receipt")

S.worlds = S.worlds + 1; t = 25; Coop.world.prepare(S)
-- The actual published weather existed before any watch or day comparison.
-- One host read in the past is enough positive evidence for either checker.
Coop.world.on.weather = false
mod.onMessage(S, "host", "W", { "1", "24.125", "W", "X", "41", "0,0,0,0,0,0,-19,0,0,0" })
for _, item in ipairs({ {"wx", "TIME", "rainMeter"}, {"W", "3", "value"} }) do
  check.section("42", item[1], {{ k=item[2], f=item[3], at=t, h="-20", m="-19" }})
  local w = Coop.world.wd.watches[table.concat(item, "~")]
  assert(w.host[1] and w.host[1].t == 24.125 and w.host[1].v == "-19", "lost an actual host weather word")
end
print("PASS both weather checks use the host's dated weather before the watch opened")

-- A hash is only an invitation to compare the actual rows. Two buildings,
-- two construction goods and a change of owner must get independent watches.
S.worlds = S.worlds + 1; t = 20; rows, sent = {}, {}; Coop.world.prepare(S)
local p, q = "3@1,2", "8@3,4"
local mine = { B = "a/2", C = "b/1", O = "c", at = { rows = { [p] = t, [q] = t }, buildings = t, O = t },
  detail = { B = { [p] = "1|1|3|2|0|0", [q] = "1|1|0|0|0|1" }, C = { [p] = "16:2,17:5" }, O = { town = "A2" } } }
check.fingerprint(42, { B = "x/2", C = "y/1", O = "z" }, mine)
local function details(s, data, count)
  local function message(word, n)
    mod.onMessage(S, "host", "W", { "1", "20", "W", "FPROWS", "42", s, word, n })
  end
  message(data); message("END", tostring(count))
end
details("B", p .. "~1|1|4|2|0|0;" .. q .. "~1|1|0|0|0|0", 2)
details("C", p .. "~16:3,17:4", 1)
details("O", "town~A1", 1)
local watches = Coop.world.wd.watches
for _, id in ipairs({ "B~" .. p .. "~workers", "B~" .. q .. "~sleep", "C~" .. p .. "~g16", "C~" .. p .. "~g17", "O~town~owner" }) do
  assert(watches[id], "missing fingerprint field " .. id)
end
assert(#Coop.world.wd.batches == 3)
print("PASS building, construction and ownership hashes resolve to five differing fields")

S.worlds = S.worlds + 1; t = 30; Coop.world.prepare(S)
local function wxRow(rain)
  local v = {}; for i = 1, 29 do v[i] = "0" end
  v[10] = tostring(rain); return table.concat(v, "|")
end
Coop.world.wd.run = { tag = "42", P = { times = { ["world/"] = 30 }, wx = { TIME = wxRow(2) } } }
t = 30.25
mod.onMessage(S, "host", "W", { "1", "30.25", "W", "PRE", "42", "30.12", "wx~TIME=" .. wxRow(3) })
local watch = assert(Coop.world.wd.watches["wx~TIME~rainMeter"])
assert(watch.friend[1].t == 30 and watch.friend[1].v == "2")
assert(watch.host[1].t == 30.12 and watch.host[1].v == "3")
print("PASS a late host row starts the watch at the original friend reading")

S.worlds = S.worlds + 1; t = 40
Coop.world.prepare(S); Coop.facts = { exact = true }
for name in pairs(Coop.world.on) do Coop.world.on[name] = name == "weather" end
S.eng.getDaysTotal = function() return 101 end
local fields = { "targetRaining", "targetSnowing", "targetCloudiness", "windTarget", "snowTarget", "droughtLevel",
  "rainMeter", "daysWithoutRainVariation", "isDrought", "enableThunderstorm", "Season", "isWinter", "wind",
  "snowLevel", "snowing", "raining", "wetness", "cloudiness", "rainfall", "snowfall", "fogLevel", "month" }
for _, f in ipairs(fields) do weather[f] = 0 end
weather.month = 5
mod.onMessage(S, "host", "W", { "1", "40", "W", "X", "100", "0,1,0,0,0,0,-17,2,0,0,3,1,0,0,0.5,0,0,0,0,0,0,4" })
assert(weather.month == 4, "the friend showed next month before the host")
assert(weather.rainMeter == -17 and weather.Season == 3 and weather.isWinter and weather.snowing == 0.5)
weather.rainMeter = -18; t = 40.25; mod.tick(S, t)
assert(weather.rainMeter == -17, "a friend's own day roll survived the next tick")
weather.rainMeter = 7; t = 44; mod.tick(S, t)
assert(weather.rainMeter == 7, "old weather was applied after the host went silent")
print("PASS exact weather follows the host across the local day boundary and releases on silence")

if ARG2 then
  assert(loadfile(ARG2))()
  local visited = {}
  local function find(fn, target)
    if visited[fn] then return end
    visited[fn] = true
    for i = 1, 100 do
      local name, child = debug.getupvalue(fn, i)
      if not name then break end
      if name == target then return child end
      if type(child) == "function" then local v = find(child, target); if v then return v end end
    end
  end
  local readRec = assert(find(mod.tick, "readRec"))
  local mesh = {live=true, IsValid=function() return true end, GetFullName=function() return "StaticMesh /test.mesh" end}
  local comp = {live=true, RuntimeVirtualTextures={}, StaticMesh=mesh, GetNumMaterials=function() return 0 end}
  local actor = {
    live=true,
    K2_GetActorLocation=function() return {X=94250.02, Y=-82847.58, Z=3059.4} end,
    K2_GetActorRotation=function() return {Pitch=0, Roll=0, Yaw=5} end,
    GetActorScale3D=function() return {X=1, Y=1, Z=1} end
  }
  local origin = {X=93182.25, Y=-83302.49, Z=3012.8}
  Coop.scene.matsOf = {}
  local rec = readRec(actor, comp, origin)
  -- The same XY origin is also available for a replacement without a local building.
  assert(rec.t == "1070:452:46:5", "the offset must reproduce the host's absolute centimetres: " .. rec.t)
  print("PASS scene pieces retain the host's world centimetres at fractional building origins")
end
