-- Desk test: a rival town's market stalls follow the host (lane 76, task 76e round 2; coop_x_people.lua friendRival,
-- THE STALLS FOLLOW THE HOST). Run from the repository root:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane76/t_stalls.lua mod/ManorLordsCoop/Scripts/coop_x_people.lua
-- The lead's run r27m83: two new stalls stood the other way round on the friend for the whole session.
local module
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
_G.Coop = {
  people = { on = { grow = false, families = false, members = false } },
  register = function(_, m) module = m end,
  api = { valid = function(o) return o ~= nil and o.alive == true end, un = function(o) return o end, log = function() end, send = function() end },
  events = { hostO = { zwei = "A2" } },
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
local friendRival = assert(upvalue(module.tick, "friendRival"), "friendRival not found")
local P = Coop.people
local region = { alive = true, regionUniqueTag = { ToString = function() return "zwei" end } }
local function e(t, pos, fn) return { key = t .. "@" .. pos, pos = pos, t = t, fn = fn or 3, u = {}, us = "", b = { alive = true, Region = region } } end
local function jobs() local t = {}; for _, j in ipairs(P.jobs) do t[#t + 1] = j.kind .. " " .. j.key end; table.sort(t); return table.concat(t, ", ") end
local function reset() P.jobs = {}; P.queued = {}; P.since = {}; P.tries = {}; P.said = {}; P.stallHad = {}; P.stallMiss = {}; P.stallOnly = {}
  P.on.rivalRemove = true; P.on.rivalMake = true; P.on.rivalUpgrade = true end
-- the swap of r27m83
reset()
P.hostB = { A2 = { list = { e(91, "9249,7403"), e(93, "9260,7421") } } }
local per = { A2 = { e(93, "9249,7403"), e(91, "9260,7421") } }
friendRival(nil, 100.0, per); friendRival(nil, 100.5, per)
check(jobs() == "remove 91@9260,7421, remove 93@9249,7403", "two stalls the other way round: both of this copy's are removed (" .. jobs() .. ")")
-- then nothing stands there: the host's are made after 10 s, not before
reset(); per = { A2 = {} }
friendRival(nil, 200.0, per); friendRival(nil, 205.0, per)
check(jobs() == "", "a host's stall missing here: not made before 10 s (" .. jobs() .. ")")
friendRival(nil, 210.5, per)
check(jobs() == "make 91@9249,7403, make 93@9260,7421", "a host's stall missing here for 10 s is made (" .. jobs() .. ")")
-- this copy's families put up the same one meanwhile: nothing to do
reset(); friendRival(nil, 300.0, { A2 = {} }); friendRival(nil, 305.0, { A2 = { e(91, "9249,7403"), e(93, "9260,7421") } }); friendRival(nil, 316.0, { A2 = { e(91, "9249,7403"), e(93, "9260,7421") } })
check(jobs() == "", "the same stalls here: nothing made or removed (" .. jobs() .. ")")
-- a stall here where the host has none
reset(); per = { A2 = { e(91, "9249,7403"), e(93, "9260,7421"), e(93, "9300,7500") } }
friendRival(nil, 400.0, per); friendRival(nil, 405.0, per)
check(jobs() == "", "a stall the host lacks: not removed before 10 s")
friendRival(nil, 410.5, per); friendRival(nil, 411.0, per)   -- (then the usual 0.3 s of any removal)
check(jobs() == "remove 93@9300,7500", "a stall the host lacks for 10 s is removed (" .. jobs() .. ")")
-- a host that lists no stall (an older build): this copy's stall is left alone
reset(); P.hostB = { A2 = { list = { e(18, "9000,7000", 5) } } }; per = { A2 = { e(18, "9000,7000", 5), e(93, "9300,7500") } }
friendRival(nil, 500.0, per); friendRival(nil, 520.0, per)
check(jobs() == "", "a host that lists no stall: a stall here is left alone (" .. jobs() .. ")")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_stalls failed") end
