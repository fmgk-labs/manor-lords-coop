-- Desk test of lane 79's "rp" line of the wide daily sample (coop_world.lua wideRegion / WIDE "rp").
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane79/t_rp.lua mod/ManorLordsCoop/Scripts/coop_world.lua
-- Checks: the rp fields end with "enemies" and "attack" and hold no squadsPresent; the row holds the game's two
-- answers (areAnyEnemySquadsPresent(true) as 1 / 0, isUnderAttack as 1 / 0) and not the list's length; the list is
-- named in the left-out table with its reason; two copies whose lists differ in length but whose answers are equal
-- give equal rows.
local mod
math.type = math.type or function(n) return n == math.floor(n) and "integer" or "float" end
local function live(o) return type(o) == "table" and o.live == true end
Coop = {
  register = function(_, m) mod = m end, stale = function() return false end,
  api = { valid = live, un = function(o) return o end, now = os.clock, btype = function(b) return b.type end,
    log = function() end, send = function() end }
}
assert(loadfile(ARG1))()
local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("PASS " .. what) else fail = fail + 1; print("FAIL " .. what) end end

-- find a local function of the module by name, through the upvalues of its functions (depth first)
local function findUp(name)
  local seen = {}
  local function walk(f, depth)
    if seen[f] or depth > 6 then return nil end
    seen[f] = true
    for i = 1, 200 do
      local n, v = debug.getupvalue(f, i)
      if not n then break end
      if n == name then return v end
      if type(v) == "function" then local r = walk(v, depth + 1); if r then return r end end
      if type(v) == "table" and n ~= "_ENV" then
        for _, x in pairs(v) do if type(x) == "function" then local r = walk(x, depth + 1); if r then return r end end end
      end
    end
  end
  for _, f in pairs(mod) do if type(f) == "function" then local r = walk(f, 0); if r then return r end end end
  for _, f in pairs(Coop.world or {}) do if type(f) == "function" then local r = walk(f, 0); if r then return r end end end
end
local wideRegion = findUp("wideRegion")
local WIDE_BY = findUp("WIDE_BY")
assert(wideRegion and WIDE_BY, "wideRegion / WIDE_BY not found")

local f = WIDE_BY.rp[2]
check(f[#f - 1] == "enemies" and f[#f] == "attack", "rp ends with enemies, attack: " .. table.concat(f, ","))
local has = false; for _, x in ipairs(f) do if x == "squadsPresent" then has = true end end
check(not has, "rp holds no squadsPresent")
local out = Coop.world.wideLeftOut
check(out and out.rp and type(out.rp.squadsPresent) == "string" and out.rp.squadsPresent ~= "", "the list is named as left out, with its reason")

local nextAddr = 0x30000
local function obj(o) nextAddr = nextAddr + 16; local a = nextAddr; o.live = true; o.GetAddress = function() return a end; return o end
local lord = obj({})
Coop.world.me = lord.GetAddress()
local function region(squads, enemies, attack)
  local r = obj({ ownerPawn = lord, regionUniqueTag = { ToString = function() return "zwei" end }, regionName = { ToString = function() return "Zwei" end },
    workerFamilies = { 1, 2 }, residents = { 1, 2, 3 }, corpses = {}, squadsPresent = squads, isUnderAttack = attack, asked = {},
    getNumHomelessFamilies = function() return 0 end, getNumTotalPopulation = function() return 9 end })
  function r:areAnyEnemySquadsPresent(enc) self.asked[#self.asked + 1] = enc; return enemies end
  return r
end
local function row(r)
  local P = { rp = {}, ro = {} }
  wideRegion(P, r, "rp")
  local k; for key, v in pairs(P.rp) do k = key; P.v = v end
  return P.v, k
end
local hostR = region({ 1, 2, 3, 4, 5 }, true, true)
local h = row(hostR)
check(hostR.asked[1] == true, "asked with includeEncamped = true")
local parts = {}; for v in (h .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = v end
check(#parts == #f, "one value per field (" .. #parts .. " of " .. #f .. "): " .. h)
check(parts[#parts - 1] == "1" and parts[#parts] == "1", "enemies 1, attack 1: " .. h)
local friendR = region({ 1, 2 }, true, true)                      -- the list is shorter on the friend (merchants)
check(row(friendR) == h, "a list of another length with equal answers gives an equal row")
local quiet = region({ 1, 2, 3, 4, 5 }, false, false)
local q = row(quiet); local qp = {}; for v in (q .. "|"):gmatch("([^|]*)|") do qp[#qp + 1] = v end
check(qp[#qp - 1] == "0" and qp[#qp] == "0", "enemies 0, attack 0: " .. q)
check(q ~= h, "a different answer gives a different row")

print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_rp failed") end
