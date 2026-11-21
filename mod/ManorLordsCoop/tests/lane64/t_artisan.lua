-- Desk test (lane 64, task 64d3): a rival house's artisan change keeps its family at work on a friend.
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane64/t_artisan.lua mod/ManorLordsCoop/Scripts/coop_x_people.lua
-- Sessions l64pin17 and l64pin18: rival A2 changed a house's workshop (upgrade 111 at 8@9605,7353, upgrade 110 at
-- 8@9639,7581). On the host the house kept its family through the conversion (assignedFamilyIDs 1); the people module
-- made the same call here (changeArtisanType), which cleared it: 0 here for 28 to 33 s. The families are now read
-- before the call and given back right after it (the town module's fixFamilies), in the same tick.
-- The made-up building's changeArtisanType clears its families, as the game's did here.
local module
-- (the game's Lua is 5.4; the desk's may be 5.1)
if not math.tointeger then math.tointeger = function(x) x = tonumber(x); if x and x == math.floor(x) then return x end; return nil end end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local fixed = {}
_G.Coop = {
  people = { on = { grow = false, families = false, members = false } },
  register = function(_, m) module = m end,
  api = { valid = function(o) return o ~= nil and o.alive == true end, un = function(o) return o end, log = function() end, send = function() end },
  events = { hostO = { zwei = "A2" } },
  town = {
    quiet = function(fn) return fn() end,
    fixFamilies = function(b, want)
      fixed[#fixed + 1] = table.concat(want, ",")
      local a = {}; for i, v in ipairs(want) do a[i] = v end; b.assignedFamilyIDs = a
      return "ok"
    end,
  },
}
assert(loadfile(ARG1))()
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 250 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name and v ~= nil then return v end end
  for i = 1, 250 do
    local n, v = debug.getupvalue(fn, i); if not n then break end
    if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
  end
end
local doUpgrade = assert(upvalue(module.tick, "doUpgrade"), "doUpgrade not found")
local function house(fams, keep)
  local b = { alive = true, isBeingUpgraded = false, Data = { constructed = true }, Extensions = { 1 }, assignedFamilyIDs = fams, calls = {} }
  function b:changeArtisanType(t) self.calls[#self.calls + 1] = "artisan " .. t; if not keep then self.assignedFamilyIDs = {} end; self.isBeingUpgraded = true end
  function b:ChangeExtension(slot, t) self.calls[#self.calls + 1] = "ext " .. slot .. " " .. t end
  function b:BeginUpgrade(id) self.calls[#self.calls + 1] = "upgrade " .. id end
  return b
end
local S = {}
-- 1. the fault's case: the call clears the house's family; it is given back in the same call
fixed = {}
local b = house({ 5 })
local ok, how = doUpgrade(S, { m = { b = b }, miss = { 111 } })
check(ok == true and b.calls[1] == "artisan 11", "upgrade 111 is the artisan change 11 (" .. tostring(b.calls[1]) .. ")")
check(#fixed == 1 and fixed[1] == "5" and #b.assignedFamilyIDs == 1 and b.assignedFamilyIDs[1] == 5, "the house's family 5 is given back right after the call (fixFamilies with 5): assignedFamilyIDs " .. #b.assignedFamilyIDs)
check(type(how) == "string" and how:find("given back: ok", 1, true) ~= nil, "and the job's line says so: " .. tostring(how))
-- 2. a call that keeps the family: nothing is done
fixed = {}
b = house({ 5 }, true)
ok, how = doUpgrade(S, { m = { b = b }, miss = { 110 } })
check(ok == true and #fixed == 0 and b.assignedFamilyIDs[1] == 5, "a change that kept the family: no fixFamilies (" .. tostring(how) .. ")")
-- 3. a house with no family: nothing to give back
fixed = {}
b = house({})
ok, how = doUpgrade(S, { m = { b = b }, miss = { 110 } })
check(ok == true and #fixed == 0 and #b.assignedFamilyIDs == 0, "a house with no family: no fixFamilies")
-- 4. two families: both back
fixed = {}
b = house({ 7, 3 })
ok, how = doUpgrade(S, { m = { b = b }, miss = { 103 } })
check(#fixed == 1 and fixed[1] == "3,7", "two families (7 and 3): both given back, in rising order (" .. tostring(fixed[1]) .. ")")
-- 5. the other upgrades are not touched: a backyard (ChangeExtension) and a building upgrade (BeginUpgrade)
fixed = {}
b = house({ 5 })
ok, how = doUpgrade(S, { m = { b = b }, miss = { 101 } })
check(ok == true and b.calls[1] == "ext 0 1" and #fixed == 0, "a backyard change (101) is ChangeExtension as before, no fixFamilies")
fixed = {}
b = house({ 5 })
ok, how = doUpgrade(S, { m = { b = b }, miss = { 12 } })
check(ok == true and b.calls[1] == "upgrade 12" and #fixed == 0, "a building upgrade (12) is BeginUpgrade as before, no fixFamilies")
-- 6. a house still being upgraded here waits, as before
b = house({ 5 }); b.isBeingUpgraded = true
ok, how = doUpgrade(S, { m = { b = b }, miss = { 111 } })
check(ok == nil and #b.calls == 0, "a house still under an upgrade here: not now (nil), nothing called")
-- 7. the family not given back (fixFamilies fails): the change stands, the job's line names it
Coop.town.fixFamilies = function() return "still differs: have - want 5" end
b = house({ 5 })
ok, how = doUpgrade(S, { m = { b = b }, miss = { 111 } })
check(ok == true and how:find("still differs", 1, true) ~= nil, "fixFamilies that fails: the change stands and the line says why (" .. tostring(how) .. ")")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
return fail == 0
