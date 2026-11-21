-- Lane 87 desk test (no game): an upgrade id a rival building has on this copy and not on the host is dropped from
-- this copy's list (coop_x_people.lua friendRival and doDrop; lane 76's diagnosis of lane 83's run A, the house
-- 8@9639,7581: upgradesDone 1 on the host, 2 on the friend for 16 days). Run from the repository root:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane87/t_drop.lua mod/ManorLordsCoop/Scripts/coop_x_people.lua
local module
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end
local logs = {}
_G.Coop = {
  people = { on = { grow = false, families = false, members = false } },
  register = function(_, m) module = m end,
  api = { valid = function(o) return o ~= nil and o.alive == true end, un = function(o) return o end,
          log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function() end },
  events = { hostO = { zwei = "A2" } },
  town = { inject = function() return 1, "queued/pending" end, results = {}, aq = {} },
}
os.clock = function() return 0 end
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
local runJobs = assert(upvalue(module.tick, "runJobs"), "runJobs not found")
local P = Coop.people
local region = { alive = true, regionUniqueTag = { ToString = function() return "zwei" end } }

-- the game's list as the mod loader gives it: a userdata with a length, numbered entries (a read or a write past the
-- end is an error here: the real one grows), Empty, and a write that the loader may refuse
--   refuse = "all"     every write refused (a list type the loader cannot write)
--   refuse = "append"  a write in place works, an append is refused
local reads = { past = 0 }
local function tarray(ids, refuse)
  local store, n = {}, #ids
  for i, v in ipairs(ids) do store[i] = v end
  local u = newproxy(true); local mt = getmetatable(u)
  mt.__len = function() return n end
  mt.__index = function(_, k)
    if k == "Empty" then return function() store = {}; n = 0 end end
    if type(k) == "number" then
      if k < 1 or k > n then reads.past = reads.past + 1; error("read past the end at " .. k) end
      return store[k]
    end
  end
  mt.__newindex = function(_, k, v)
    if refuse == "all" then error("this list cannot be written") end
    if k == n + 1 then
      if refuse == "append" then error("append refused") end
      n = n + 1; store[k] = v
    elseif type(k) == "number" and k >= 1 and k <= n then store[k] = v
    else error("write past the end at " .. tostring(k)) end
  end
  return u
end
local function house(t, pos, ups, refuse)
  local b = { alive = true, Region = region, upgradesDone = tarray(ups, refuse) }
  local u = {}; for i, id in ipairs(ups) do u[i] = id end
  return { key = t .. "@" .. pos, pos = pos, t = t, fn = 1, u = u, us = "", b = b }
end
local function host(t, pos, ups) local u = {}; for i, id in ipairs(ups) do u[i] = id end; return { key = t .. "@" .. pos, pos = pos, t = t, fn = 1, u = u } end
local function jobs() local t = {}; for _, j in ipairs(P.jobs) do t[#t + 1] = j.kind .. " " .. j.key end; table.sort(t); return table.concat(t, ", ") end
local function reset() P.jobs = {}; P.queued = {}; P.since = {}; P.tries = {}; P.said = {}; P.stallHad = {}; P.stallMiss = {}; P.stallOnly = {}; P.cur = nil
  P.on.rivalRemove = true; P.on.rivalMake = true; P.on.rivalUpgrade = true; P.on.rivalDrop = true end
local function list(b) local t = {}; local a = b.upgradesDone; for i = 1, #a do t[i] = a[i] end; return table.concat(t, ".") end
local function stat(k) return P.stats[k] or 0 end
local function logHas(s) for _, l in ipairs(logs) do if l:find(s, 1, true) then return l end end end

print("[the friend's rival house has an upgrade the host's list has not]")
reset()
local m = house(8, "9639,7581", { 101, 2 })
P.hostB = { A2 = { list = { host(8, "9639,7581", { 2 }) } } }
local per = { A2 = { m } }
friendRival(nil, 100.0, per); friendRival(nil, 100.2, per)
check(jobs() == "", "not dropped before the rival rule's usual wait (RIVAL_AFTER 0.3 s) (" .. jobs() .. ")")
friendRival(nil, 100.5, per)
check(jobs() == "drop 8@9639,7581", "0.5 s after: a drop job, within the 3 s of the owner's bar (" .. jobs() .. ")")
check(P.jobs[1] and #P.jobs[1].extra == 1 and P.jobs[1].extra[1] == 101, "the id to drop: 101, the chicken coop")
runJobs(nil, 100.6)
check(list(m.b) == "2", "this copy's list is the host's now (" .. list(m.b) .. ")")
check(#P.jobs == 0 and stat("b_dropped") == 1 and stat("b_dropFailed") == 0, "the job is done: b_dropped 1, b_dropFailed 0")
check(logHas("101 here and not on the host: dropped here") ~= nil, "a log line says so (" .. tostring(logs[#logs]) .. ")")

print("[the order of the rest is kept; only the extra ids go]")
reset()
local m2 = house(8, "9700,7500", { 2, 101, 110 })
P.hostB = { A2 = { list = { host(8, "9700,7500", { 2, 110 }) } } }
per = { A2 = { m2 } }
friendRival(nil, 200.0, per); friendRival(nil, 200.5, per); runJobs(nil, 200.6)
check(list(m2.b) == "2.110", "2.101.110 here, 2.110 on the host: 2.110 here (" .. list(m2.b) .. ")")

print("[an id twice here and once on the host: one goes]")
reset()
local m2b = house(8, "9720,7500", { 2, 101, 101 })
P.hostB = { A2 = { list = { host(8, "9720,7500", { 101, 2 }) } } }
per = { A2 = { m2b } }
friendRival(nil, 250.0, per); friendRival(nil, 250.5, per); runJobs(nil, 250.6)
check(list(m2b.b) == "2.101", "2.101.101 here, 101.2 on the host: 2.101 here (" .. list(m2b.b) .. ")")

print("[nothing dropped while this copy lacks an upgrade the host has (the upgrade first)]")
reset()
local m3 = house(8, "9800,7500", { 101 })
P.hostB = { A2 = { list = { host(8, "9800,7500", { 2 }) } } }
per = { A2 = { m3 } }
friendRival(nil, 300.0, per); friendRival(nil, 300.5, per)
check(not jobs():find("drop", 1, true), "lacks 2 and has 101: an upgrade job, no drop yet (" .. jobs() .. ")")

print("[another type at the same place (a change on its way): no drop]")
reset()
local m4 = house(3, "9900,7500", { 101, 2 })
P.hostB = { A2 = { list = { host(8, "9900,7500", { 2 }) } } }
per = { A2 = { m4 } }
friendRival(nil, 400.0, per); friendRival(nil, 400.5, per)
check(not jobs():find("drop", 1, true), "3@ here, 8@ on the host: no drop (" .. jobs() .. ")")

print("[an id that comes back on the host within the wait: the wait starts again]")
reset()
local m5 = house(8, "9950,7500", { 101, 2 })
local h5 = host(8, "9950,7500", { 2 })
P.hostB = { A2 = { list = { h5 } } }
per = { A2 = { m5 } }
friendRival(nil, 500.0, per)
h5.u = { 101, 2 }; friendRival(nil, 500.1, per)
h5.u = { 2 }; friendRival(nil, 500.2, per); friendRival(nil, 500.4, per)
check(jobs() == "", "the difference broke off at 500.1: no job at 500.4 (" .. jobs() .. ")")
friendRival(nil, 500.6, per)
check(jobs() == "drop 8@9950,7500", "0.4 s after it came again: the drop job (" .. jobs() .. ")")

print("[the list cannot be written: it is left untouched, and the failure is counted]")
reset()
local m7 = house(8, "9960,7500", { 101, 2 }, "all")
local d7 = stat("b_dropped")
P.hostB = { A2 = { list = { host(8, "9960,7500", { 2 }) } } }
per = { A2 = { m7 } }
friendRival(nil, 700.0, per); friendRival(nil, 700.5, per); runJobs(nil, 700.6)
check(list(m7.b) == "101.2", "a refused write: the list still 101.2, not emptied (" .. list(m7.b) .. ")")
check(stat("b_dropFailed") == 1 and stat("b_dropped") == d7, "b_dropFailed 1, b_dropped unchanged (" .. d7 .. ")")
check(logHas("NOT dropped (a write of the first entry to itself was refused") ~= nil, "the log line names the refusal")

print("[a write in place works, an append is refused: the failure is counted and logged]")
reset()
local m8 = house(8, "9970,7500", { 101, 2 }, "append")
P.hostB = { A2 = { list = { host(8, "9970,7500", { 2 }) } } }
per = { A2 = { m8 } }
friendRival(nil, 800.0, per); friendRival(nil, 800.5, per); runJobs(nil, 800.6)
check(stat("b_dropFailed") == 2, "b_dropFailed 2 (" .. list(m8.b) .. " here)")
check(logHas("NOT dropped (the list could not be written") ~= nil, "the log line says what the list reads")

print("[a building gone before the job runs]")
reset()
local m9 = house(8, "9980,7500", { 101, 2 })
P.hostB = { A2 = { list = { host(8, "9980,7500", { 2 }) } } }
per = { A2 = { m9 } }
friendRival(nil, 900.0, per); friendRival(nil, 900.5, per)
m9.b.alive = false; runJobs(nil, 900.6)
check(stat("b_dropFailed") == 3 and #P.jobs == 0, "a gone building: not written, the job ends")

print("[a town job in flight (up to 12 s) and a player's action queued: the drop does not wait for them]")
reset()
local m10 = house(8, "9985,7500", { 101, 2 })
P.hostB = { A2 = { list = { host(8, "9985,7500", { 2 }) } } }
per = { A2 = { m10 } }
friendRival(nil, 950.0, per); friendRival(nil, 950.5, per)
P.cur = { id = 77, t = 950.4, job = { kind = "make", key = "8@1,1", code = "A2" } }; Coop.town.results[77] = nil
Coop.town.pend = true
local d10 = stat("b_dropped")
runJobs(nil, 950.6)
check(list(m10.b) == "2" and stat("b_dropped") == d10 + 1, "dropped at once (" .. list(m10.b) .. ")")
check(P.cur ~= nil and P.cur.id == 77, "the town job in flight is left as it was")
P.cur = nil; Coop.town.pend = nil

print("[the look's list is older than the house's: nothing is written, and it is not counted as a drop]")
reset()
local m11 = house(8, "9988,7500", { 2 })
m11.u = { 101, 2 }                                             -- the scan saw 101; the house's list has lost it since
P.hostB = { A2 = { list = { host(8, "9988,7500", { 2 }) } } }
per = { A2 = { m11 } }
local d11, n11 = stat("b_dropped"), stat("b_dropNone")
friendRival(nil, 980.0, per); friendRival(nil, 980.5, per); runJobs(nil, 980.6)
check(list(m11.b) == "2" and stat("b_dropped") == d11 and stat("b_dropNone") == n11 + 1, "b_dropNone +1, b_dropped unchanged (" .. list(m11.b) .. ")")
check(logHas("8@9988,7500 has upgrade(s) 101 here and not on the host: none to drop") ~= nil, "the log line says none to drop")

print("[the switch off]")
reset(); P.on.rivalDrop = false
local m6 = house(8, "9990,7500", { 101, 2 })
P.hostB = { A2 = { list = { host(8, "9990,7500", { 2 }) } } }
per = { A2 = { m6 } }
friendRival(nil, 600.0, per); friendRival(nil, 611.0, per)
check(jobs() == "", "Coop.people.on.rivalDrop = false: no drop")

check(reads.past == 0, "no read past a list's end (" .. reads.past .. ")")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
