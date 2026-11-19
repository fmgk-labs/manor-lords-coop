-- Lane 71 desk test (no game): the daily comparison's timing parts (coop_world.lua): a day whose only differences are
-- the families part or a region's wealth is judged once more 2 s later with those parts taken again.
--   py -3 -I luacheck.py run t_fp.lua [path of coop_world.lua, default ../../Scripts/coop_world.lua]
local FILE = ARG1 or (HERE .. "../../Scripts/coop_world.lua")
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
local T = 100.0; os.clock = function() return T end
local logs = {}
local C = { modules = {} }; _G.Coop = C
function C.register(n, m) C.modules[n] = m; return m end
local function valid(o) return type(o) == "table" and not o.dead end
C.api = { un = function(x) return x end, valid = valid, btype = function(b) return b.t end, now = function() return 2000 end,
          log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function() end }
_G.FName = function(s) return s end
local ok, err = pcall(function() assert(loadfile(FILE))() end)
check(ok and C.world ~= nil, "coop_world.lua loads with a made-up core (" .. tostring(err) .. ")")
local W = C.world
W.S = { stats = {}, role = "friend" }; W.miss = 0
local function region(tag, w, ap, po, fams, pop)
  local r = { regionalWealth = w, Approval = ap, publicOrder = po, settlementLevel = 2, workerFamilies = {} }
  for i = 1, fams do r.workerFamilies[i] = {} end
  r.regionUniqueTag = { ToString = function() return tag end }
  function r:getNumHomelessFamilies() return 0 end
  function r:getNumTotalPopulation() return pop end
  function r:getNumFamiliesOfLv(l) return l == 1 and fams or 0 end
  return r
end
local hof = region("hof", 93, 60, 70, 18, 54)
W.regionByKey = function(tag) if tag == "hof" then return hof end end

print("[the timing parts]")
check(W.onlyTiming({ "F" }) and W.onlyTiming({ "wealth@hof:99/93" }) and W.onlyTiming({ "F", "wealth@hof:99/93" }), "families and wealth are timing parts")
check(not W.onlyTiming({ "F", "B" }) and not W.onlyTiming({ "silver:5/1" }) and not W.onlyTiming({}), "anything else, or nothing, is not")
check(W.regNow(nil, "hof:99/60/70") == "hof:93/60/70", "the region part now (wealth / approval / order)")
check(W.famNow(nil, "hof:18/0/54/L2/18,0,0,0") == "hof:18/0/54/L2/18,0,0,0", "the families part now")

print("[a day: host 99, this copy's sample 93]")
local a = { R = "hof:99/60/70", F = "hof:18/0/54/L2/18,0,0,0", B = "x", O = "o", W = "ERR" }
local b = { R = "hof:93/60/70", F = "hof:18/0/54/L2/18,0,0,0", B = "x", O = "o", W = "ERR" }
local bad = W.compareFp(a, b)
check(#bad == 1 and bad[1] == "wealth@hof:99/93", "the compare finds wealth@hof:99/93 (" .. table.concat(bad, " ") .. ")")
W.fp = W.fp or { host = {}, mine = {} }
-- the judge is reached by the core's day change: here through the later list directly (its first look defers)
W.fpLater = { { day = 7, a = a, b = b, t = T + 2.0 } }
hof.regionalWealth = 99                               -- the host's push arrived meanwhile
T = T + 1.0; W.fpLaterStep(W.S); check(#W.fpLater == 1, "not judged before its 2 s")
T = T + 1.5; W.fpLaterStep(W.S)
local said = false; for _, l in ipairs(logs) do if l:find("wealth@hof:99/93 at the sample, the host's 2 s later") then said = true end end
check(#W.fpLater == 0 and said and W.miss == 0, "2 s later: the wealth is the host's: not a difference, nothing counted")
print("[a real difference stays one]")
hof.regionalWealth = 80
W.fpLater = { { day = 8, a = a, b = { R = "hof:80/60/70", F = a.F, B = "x", O = "o", W = "ERR" }, t = T } }
T = T + 0.1; W.fpLaterStep(W.S)
check(W.miss == 1, "2 s later still 99/80: counted as a difference (1 in a row)")
print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("desk test failed") end
