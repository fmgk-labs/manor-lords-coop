-- Lane 87 desk test (no game): the bar's cures (lanes/lane_s21_87/design_cures.txt).
--   py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane87/t_cures.lua
-- 1. cure 1, coop_x_values.lua: the host names, polls and sends a new site or an upgrade in its first tick (from the
--    native table); the gone pass spares it while the sites module's look has not come; an address it could not name
--    is tried again only at the nameEvery cadence. A friend holds an upgrade begun here in the call's tick (V.begun), or
--    in the first tick it turns unfinished; a building new in the game's list in its first tick; the apply loop keeps
--    a hold whose building the table (up to 0.1 s old) does not show as a site yet.
local SCRIPTS = HERE .. "../../Scripts/"
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
local T = 100.0
os.clock = function() return T end
local function has(list, pat) for _, l in ipairs(list) do if l:find(pat, 1, true) then return true end end; return false end
local function count(list, pat) local n = 0; for _, l in ipairs(list) do if l:find(pat, 1, true) then n = n + 1 end end; return n end
local function clear(t) for i = #t, 1, -1 do t[i] = nil end end
local function words(l) local w = {}; for x in l:gmatch("%S+") do w[#w + 1] = x end; return w end
local function valid(o) return type(o) == "table" and not o.dead end
-- Lua 5.1 has no string.pack: the floats the module packs, as their bits (the same stand-in as t_sites.lua)
local function f2b(x)
  if x == 0 then return 0 end
  local m, e = math.frexp(x); e = e + 126
  return e * 2 ^ 23 + math.floor((m * 2 - 1) * 2 ^ 23 + 0.5)
end
string.pack = string.pack or function(fmt, v) return (fmt == "<f" and "F" or "U") .. ":" .. string.format("%.17g", v) end
string.unpack = string.unpack or function(fmt, s)
  local k, v = s:match("^(%a):(.*)$"); v = tonumber(v)
  if fmt == "<I4" then return k == "F" and f2b(v) or v end
  if k == "U" then
    local e = math.floor(v / 2 ^ 23); local m = v - e * 2 ^ 23
    if e == 0 then return m * 2 ^ -149 end
    return (1 + m / 2 ^ 23) * 2 ^ (e - 127)
  end
  return v
end
local io_open = io.open
io.open = function(path, mode)
  local fh, e = io_open(path, mode); if not fh then return nil, e end
  return setmetatable({}, { __index = function(_, k)
    if k == "read" then return function(_, fmt) return fh:read(fmt == "a" and "*a" or fmt) end end
    return function(_, ...) return fh[k](fh, ...) end
  end })
end
local OUT = HERE .. "sitehp_out.txt"
local function pollFile(lines) local f = assert(io_open(OUT, "wb")); f:write(lines); f:close() end
os.remove(OUT)

print("[1. cure 1, coop_x_values.lua: a new site or an upgrade in its first tick]")
do
  local nextAddr = 0x7000
  local BM = {}; BM.__index = BM
  function BM:GetAddress() return self.addr end
  function BM:K2_GetActorLocation() return { X = self.x, Y = self.y, Z = 0 } end
  function BM:GetType() return self.t end
  function BM:IsRubble() return false end
  local function building(t, x, y, built)
    nextAddr = nextAddr + 0x100
    return setmetatable({ t = t, x = x, y = y, addr = nextAddr, Region = {}, Data = { constructed = built and true or false }, onFire = false }, BM)
  end
  local sent, logs, cmds = {}, {}, {}
  local arr = {}
  local S = { role = "host", eng = { buildingArr = arr }, startWall = 1000, ticks = 0 }
  local C = { s = S, modules = {} }
  _G.Coop = C
  function C.register(name, m) C.modules[name] = m; return m end
  function C.stale() return false end
  C.api = { un = function(x) return x end, valid = valid, btype = function(b) return b.t end, now = function() return 2000 end,
            log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function(l) sent[#sent + 1] = l end }
  local function key(b) return string.format("%d@%d,%d", b.t, math.floor(b.x / 10 + 0.5), math.floor(b.y / 10 + 0.5)) end
  C.world = { bkey = key, buildingByKey = function(k) for _, b in ipairs(arr) do if valid(b) and key(b) == k then return b end end end }
  local P = { fn = true, dir = HERE, items = { COLLAPSE = { state = "watch" }, SITEHP = { state = "available", why = "held=0 hx=0 near=0 cap=1024 fills=0" }, MROLL = { state = "watch" } } }
  local ticks = 0
  function P.send(l) cmds[#cmds + 1] = l end
  function P.tick() ticks = ticks + 1 end
  function P.status() return { state = "ready", items = P.items } end
  C.patch = P
  -- the native building table: records of the frame (up to 0.1 s old), each with its object of this tick
  local recs = {}
  local function rec(b, cons) recs[#recs + 1] = { a = b.addr, cons = cons, reg = 0x5000, b = b } end
  local function recOf(a) for _, r in ipairs(recs) do if r.a == a then return r end end end
  C.snap = { buildings = function() return recs end, building = recOf, obj = function(r) return valid(r.b) and r.b or nil end }
  assert(loadfile(SCRIPTS .. "coop_x_values.lua"))()
  local V, M = C.values, C.modules.values
  local function tick(dt) T = T + (dt or 0.6); S.ticks = S.ticks + 1; M.tick(S, T) end
  local old = building(34, 1000, 2000, false); arr[1] = old; rec(old, false)
  C.sites = { prev = { [key(old)] = old } }
  tick(2.1); tick(1.1)                                         -- the look and the watch of the site the list has
  -- a new site appears on the host: in the native table now, in the sites module's list a second later
  local new = building(3, 3000, 2000, false); arr[#arr + 1] = new; rec(new, false)
  pollFile(string.format("%X 3F7A0000\r\n", new.addr))         -- its fraction: 0.9765625
  local ft0, fs0 = V.stats.firstTick or 0, V.stats.firstTickSent or 0
  clear(cmds); clear(sent); tick(0.05)
  local iW, iP = 0, 0
  for i, l in ipairs(cmds) do if l == "SITEHP WATCH " .. new.addr then iW = i elseif l == "SITEHP POLL" and iW > 0 and iP == 0 then iP = i end end
  check(iW > 0 and iP > iW, "host: a new site of the native table is named and polled in its first tick (" .. table.concat(cmds, " | ") .. ")")
  check(has(sent, "HW P " .. key(new) .. "=0.9765625"), "host: ... and its fraction is sent in that tick (" .. tostring(sent[#sent]) .. ")")
  check((V.stats.firstTick or 0) - ft0 == 1 and (V.stats.firstTickSent or 0) - fs0 == 1, "host: counted firstTick +1, firstTickSent +1 (" .. tostring(V.stats.firstTick) .. ", " .. tostring(V.stats.firstTickSent) .. ")")
  clear(cmds); clear(sent); tick(0.05); tick(0.05)
  check(count(cmds, "SITEHP WATCH " .. new.addr) == 0, "host: not named again in the next ticks")
  -- the once-a-second pass: the sites module's list does not have it yet: spared while it is a site of this tick
  clear(sent); tick(1.1)
  check(not has(sent, key(new) .. "=-"), "host: the gone pass spares a key named from the table (the sites module's look has not come)")
  check((V.stats.firstTickSpared or 0) >= 1, "host: counted firstTickSpared")
  C.sites.prev[key(new)] = new
  clear(sent); tick(1.1); tick(1.1); tick(1.1); tick(1.1)
  check(not has(sent, key(new) .. "=-") and V.wT[key(new)] == nil, "host: once the sites module lists it, it is an ordinary key")
  -- spared only 3 s: a key the sites module never lists is gone after that
  local odd = building(18, 6000, 2000, false); arr[#arr + 1] = odd; rec(odd, false)
  pollFile(string.format("%X 3E800000\r\n", odd.addr))
  clear(sent); tick(0.05)
  check(has(sent, "HW P " .. key(odd) .. "=0.25"), "host: another new site sent in its first tick")
  clear(sent); tick(1.1); tick(1.1)
  check(not has(sent, key(odd) .. "=-"), "host: spared for its first 3 s")
  clear(sent); tick(1.1)
  check(has(sent, key(odd) .. "=-"), "host: then gone, as the sites module never listed it (" .. tostring(sent[#sent]) .. ")")
  -- tried again only at the nameEvery cadence (not every tick)
  clear(cmds); tick(0.05); tick(0.05); tick(0.05)
  check(count(cmds, "SITEHP WATCH " .. odd.addr) == 0, "host: an address tried a moment ago is not named again in every tick")
  -- a record that is no site by the building's own word (burning) is not named
  local burn = building(19, 7000, 2000, false); burn.onFire = true; arr[#arr + 1] = burn; rec(burn, false)
  clear(cmds); tick(0.05)
  check(count(cmds, "SITEHP WATCH " .. burn.addr) == 0, "host: a burning building the table shows unfinished is not named")
  -- an upgrade: a finished building's record turns unfinished (its address was dropped at its finish)
  local house = building(3, 9000, 2000, true); arr[#arr + 1] = house; rec(house, true)
  tick(0.05)
  house.Data.constructed = false; recOf(house.addr).cons = false
  pollFile(string.format("%X 3F7A0000\r\n", house.addr))
  clear(cmds); clear(sent); tick(0.05)
  check(count(cmds, "SITEHP WATCH " .. house.addr) == 1 and has(sent, "HW P " .. key(house) .. "=0.9765625"), "host: an upgrade begun (a finished record turned unfinished) is named and sent in its first tick")
  -- off switch
  V.cfg.firstTick = false
  local late = building(4, 11000, 2000, false); arr[#arr + 1] = late; rec(late, false)
  clear(cmds); tick(0.05)
  check(count(cmds, "SITEHP WATCH " .. late.addr) == 0, "host: Coop.values.cfg.firstTick = false: not named from the table")
  V.cfg.firstTick = true
  os.remove(OUT)

  -- ---------------------------------------------------------------- friend
  S.role = "friend"; C.sites = nil
  for i = #arr, 1, -1 do arr[i] = nil end
  for i = #recs, 1, -1 do recs[i] = nil end
  M.onWorld(S)
  local function msg(line) local w = words(line); return M.onMessage(S, "host", w[3], w, line) end
  P.items.SITEHP.why = "held=0 watched=0 writes=0 polls=0 lines=0 gone=0 bad=0 faults=0 hx=0 near=0 cap=1024 fills=0"
  msg("1 1500 HW X 1 1 1")
  for _ = 1, 5 do tick(0.6) end                                -- the look that reads the native piece's line (HOLDX, FILL)
  -- a rival's house upgrade: the host's fraction came first (sent in its first tick on the host)
  local hs = building(3, 9000, 2000, true); arr[#arr + 1] = hs; rec(hs, true)
  tick(0.05)
  msg("2 1501 HW P " .. key(hs) .. "=0.9765625")
  tick(0.05); tick(0.05)
  check(count(cmds, "SITEHP HOLD") == 0, "friend: the host's fraction for a building that is finished here: no hold yet")
  -- the people module's BeginUpgrade turns it unfinished in the call; the table still says finished (0.1 s old)
  hs.Data.constructed = false
  clear(cmds); ticks = 0
  V.begun(hs)
  check(count(cmds, "SITEHP HOLDX " .. hs.addr .. " 3F7A0000") == 1 and ticks >= 1, "friend: V.begun right after the upgrade's call: held in that tick, the native tick at once (" .. table.concat(cmds, " | ") .. ")")
  check((V.stats.begunAtOnce or 0) == 1, "friend: counted begunAtOnce")
  -- the apply loop that follows (HW P again) must not drop it although the table still says finished
  msg("3 1502 HW P " .. key(hs) .. "=0.9765625")
  clear(cmds); tick(0.05)
  check(count(cmds, "SITEHP DROP") == 0, "friend: the apply loop keeps it: the building is a site by its own word (the table is older)")
  -- the call returns before the building turns unfinished: held in the first tick it does
  local hs2 = building(3, 12000, 2000, true); arr[#arr + 1] = hs2; rec(hs2, true)
  tick(0.05)
  msg("4 1503 HW P " .. key(hs2) .. "=0.5")
  clear(cmds); V.begun(hs2)
  check(count(cmds, "SITEHP HOLD") == 0 and V.bq[hs2.addr] ~= nil, "friend: V.begun on a building still finished: kept by its address, no hold yet")
  tick(0.05)
  check(count(cmds, "SITEHP HOLD") == 0, "friend: ... still finished in the next tick: no hold")
  hs2.Data.constructed = false
  clear(cmds); tick(0.05)
  check(count(cmds, "SITEHP HOLDX " .. hs2.addr .. " 3F000000") == 1 and (V.stats.begunLater or 0) == 1, "friend: ... held in the first tick it is a site (begunLater)")
  -- no word of the host yet: begunNoWord after 1.5 s; the hold comes with HW P
  local hs3 = building(3, 14000, 2000, false); arr[#arr + 1] = hs3; rec(hs3, true)
  clear(cmds); V.begun(hs3)
  check(count(cmds, "SITEHP HOLD") == 0, "friend: V.begun with no word of the host: no hold")
  for _ = 1, 3 do tick(0.6) end
  check((V.stats.begunNoWord or 0) == 1 and V.bq[hs3.addr] == nil, "friend: ... counted begunNoWord after 1.5 s")
  msg("5 1504 HW P " .. key(hs3) .. "=0.25"); clear(cmds); tick(0.05)
  check(count(cmds, "SITEHP HOLDX " .. hs3.addr .. " 3E800000") == 1, "friend: ... and held when HW P comes (the table still says finished; the building's own word decides)")
  -- a building that stays finished: begunNever
  local hs4 = building(3, 16000, 2000, true); arr[#arr + 1] = hs4; rec(hs4, true)
  V.begun(hs4); for _ = 1, 3 do tick(0.6) end
  check((V.stats.begunNever or 0) == 1, "friend: a building still finished 1.5 s after V.begun: counted begunNever")
  -- off switch
  V.cfg.begun = false
  local hs5 = building(3, 18000, 2000, false); arr[#arr + 1] = hs5; rec(hs5, true)
  msg("6 1505 HW P " .. key(hs5) .. "=0.75"); tick(0.05)
  clear(cmds); local r5 = V.begun(hs5)
  check(r5 == false and count(cmds, "SITEHP HOLD") == 0, "friend: Coop.values.cfg.begun = false: V.begun does nothing")
  V.cfg.begun = true
  -- a building new in the game's list (a placement), with the host's word here: held in its first tick, before the
  -- table holds it; the apply loop does not drop it
  msg("7 1506 HW P 18@2000,500=0.125")
  tick(0.6)
  local ns = building(18, 20000, 5000, false); arr[#arr + 1] = ns          -- not in the table yet
  local na0 = V.stats.newSiteAtOnce or 0
  clear(cmds); tick(0.05)
  check(count(cmds, "SITEHP HOLDX " .. ns.addr .. " 3E000000") == 1 and (V.stats.newSiteAtOnce or 0) - na0 == 1, "friend: a site new in the game's list is held in its first tick (" .. table.concat(cmds, " | ") .. "; newSiteAtOnce " .. tostring(V.stats.newSiteAtOnce) .. ", holds " .. tostring(V.stats.holds) .. ")")
  clear(cmds); tick(0.6)
  check(count(cmds, "SITEHP DROP " .. ns.addr) == 0, "friend: ... and the apply loop keeps it (held in its first tick; the table does not hold it yet)")
  rec(ns, false)
  clear(cmds); for _ = 1, 4 do tick(0.6) end
  check(count(cmds, "SITEHP DROP " .. ns.addr) == 0, "friend: ... nor later, once the table has it")
  -- a stale handle: a building out of the game's list and the table is never held
  local gone = building(18, 22000, 5000, false)
  msg("8 1507 HW P " .. key(gone) .. "=0.5"); clear(cmds); for _ = 1, 3 do tick(0.6) end
  check(count(cmds, "SITEHP HOLD") == 0 or not has(cmds, tostring(gone.addr)), "friend: a building that is not in the game's list is not held")
end

print("[2. cure 3, coop_x_values.lua: the work fraction of the facts module's entry]")
do
  local nextAddr = 0x9000
  local BM = {}; BM.__index = BM
  function BM:GetAddress() return self.addr end
  function BM:K2_GetActorLocation() return { X = self.x, Y = self.y, Z = 0 } end
  function BM:GetType() return self.t end
  function BM:IsRubble() return false end
  local function building(t, x, y, built)
    nextAddr = nextAddr + 0x100
    return setmetatable({ t = t, x = x, y = y, addr = nextAddr, Region = {}, Data = { constructed = built and true or false }, onFire = false }, BM)
  end
  local sent, cmds = {}, {}
  local arr = {}
  local S = { role = "host", eng = { buildingArr = arr }, startWall = 1000, ticks = 0 }
  local C = { s = S, modules = {} }
  _G.Coop = C
  function C.register(name, m) C.modules[name] = m; return m end
  function C.stale() return false end
  C.api = { un = function(x) return x end, valid = valid, btype = function(b) return b.t end, now = function() return 2000 end,
            log = function() end, send = function(l) sent[#sent + 1] = l end }
  local function key(b) return string.format("%d@%d,%d", b.t, math.floor(b.x / 10 + 0.5), math.floor(b.y / 10 + 0.5)) end
  C.world = { bkey = key, buildingByKey = function(k) for _, b in ipairs(arr) do if valid(b) and key(b) == k then return b end end end }
  local P = { fn = true, dir = HERE, items = { COLLAPSE = { state = "watch" }, SITEHP = { state = "available", why = "held=0 hx=0 near=0 cap=1024 fills=0" }, MROLL = { state = "watch" } } }
  function P.send(l) cmds[#cmds + 1] = l end
  function P.tick() end
  function P.status() return { state = "ready", items = P.items } end
  C.patch = P
  local recs = {}
  local function rec(b, cons) recs[#recs + 1] = { a = b.addr, cons = cons, reg = 0x5000, b = b } end
  local function recOf(a) for _, r in ipairs(recs) do if r.a == a then return r end end end
  C.snap = { buildings = function() return recs end, building = recOf, obj = function(r) return valid(r.b) and r.b or nil end }
  assert(loadfile(SCRIPTS .. "coop_x_values.lua"))()
  local V, M = C.values, C.modules.values
  local function tick(dt) T = T + (dt or 0.6); S.ticks = S.ticks + 1; M.tick(S, T) end
  local site = building(18, 4000, 3000, false); arr[1] = site; rec(site, false)
  local k = key(site)
  C.sites = { prev = { [k] = site } }
  pollFile(string.format("%X 3F000000\r\n", site.addr))
  tick(2.1)                                                    -- named and polled in its first tick (cure 1)
  check(V.w[k] == site.addr, "host: the site is watched")
  -- V.fracNow: the bits of this tick's fraction; one POLL a tick at most
  pollFile(string.format("%X 3F0CCCCD\r\n", site.addr))         -- 0.55 now
  S.ticks = S.ticks + 1; clear(cmds)
  local u1 = V.fracNow(k, site.addr); local u2 = V.fracNow(k, site.addr)
  check(u1 == 0x3F0CCCCD and u2 == u1 and count(cmds, "SITEHP POLL") == 1, "host: V.fracNow gives this tick's fraction's bits; a second ask in the tick polls no more (" .. tostring(u1) .. ")")
  check(V.fracNow(k, site.addr + 1) == nil and V.fracNow("1@1,1", nil) == nil, "host: another address, or a key not watched: nil")
  -- (session l87f) a fraction that moved at the poll: the facts module is told the site's address (its entry goes at once)
  local told = {}
  C.facts = { workSeen = function(a) told[#told + 1] = a end }
  pollFile(string.format("%X 3F19999A\r\n", site.addr))       -- 0.6
  tick(0.6)
  check(#told >= 1 and told[#told] == site.addr, "host: a fraction that moved at the poll: the facts module is told the site's address (" .. tostring(told[#told]) .. ")")
  local nt = #told; tick(0.6)
  check(#told == nt, "host: not again while it stands still")
  C.facts = nil
  -- friend
  S.role = "friend"; C.sites = nil; M.onWorld(S)
  local function msg(line) local w = words(line); return M.onMessage(S, "host", w[3], w, line) end
  msg("1 1500 HW X 1 1 1")
  for _ = 1, 5 do tick(0.6) end
  clear(cmds)
  local r = V.factsHold(k, 0x3F000000)
  check(r == true and count(cmds, "SITEHP HOLDX " .. site.addr .. " 3F000000") == 1 and V.want[k] == 0.5, "friend: V.factsHold holds the entry's fraction at once (" .. table.concat(cmds, " | ") .. ")")
  -- HW P gives way for that key; another key takes HW P as before
  local other = building(18, 6000, 3000, false); arr[#arr + 1] = other; rec(other, false)
  msg("2 1501 HW P " .. k .. "=0.25;" .. key(other) .. "=0.75")
  check(V.want[k] == 0.5 and V.want[key(other)] == 0.75 and (V.stats.fracGaveWay or 0) == 1, "friend: HW P gives way for the key the stock line carries (its fraction not taken); the other key takes it")
  clear(cmds); tick(0.05)
  check(count(cmds, "SITEHP HOLDX " .. site.addr) == 0 and count(cmds, "SITEHP HOLDX " .. other.addr .. " 3F400000") == 1, "friend: the apply loop holds the other key and leaves the stock line's hold as it is")
  -- the site's end by HW P is taken
  msg("3 1502 HW P " .. k .. "=-")
  check(V.want[k] == nil and V.fx[k] == nil, "friend: HW P's '-' (the site's end) is taken")
  -- after the stock line said finished (cn=1: factsEnd) HW P is taken again
  V.factsHold(k, 0x3F000000); V.factsEnd(k)
  msg("4 1503 HW P " .. k .. "=0.25")
  check(V.want[k] == 0.25, "friend: after factsEnd (the stock line's cn=1) HW P is taken again")
  -- after cfg.factsFresh s without a stock line, HW P is taken again (3 s: session l87f)
  V.factsHold(k, 0x3F000000); T = T + 2
  msg("5 1504 HW P " .. k .. "=0.75")
  check(V.want[k] == 0.5, "friend: 2 s after the stock line's last work: HW P still gives way")
  T = T + 1.5
  msg("5 1505 HW P " .. k .. "=0.75")
  check(V.want[k] == 0.75, "friend: no stock line for cfg.factsFresh s (3): HW P is taken again")
  -- (the advisor's review) the window runs out with an HW P fraction kept aside and no new HW P line: taken at once
  V.factsHold(k, 0x3F000000)                                   -- the stock line: 0.5
  msg("5 1506 HW P " .. k .. "=0.875")                         -- gives way, kept aside
  check(V.want[k] == 0.5 and V.hwLast[k] == 0.875, "friend: HW P gives way and is kept aside")
  T = T + 3.2; tick(0.05)
  check(V.want[k] == 0.875 and V.hwLast[k] == nil and (V.stats.factsExpired or 0) >= 1, "friend: 3 s with no stock line: the kept HW P fraction is taken in the next tick (no new HW P line needed)")
  -- (session l87d) the stock line stops carrying a key (its type changed): the HW P fraction that gave way is taken
  V.factsHold(k, 0)                                            -- the stock line's last word: 0
  msg("7 1506 HW P " .. k .. "=1")
  check(V.want[k] == 0 and V.hwLast[k] == 1, "friend: HW P gives way and its fraction (1) is kept aside")
  V.factsEnd(k)
  check(V.want[k] == 1 and V.fx[k] == nil and (V.stats.factsHandBack or 0) >= 1, "friend: the stock line ends the key: HW P's last fraction is taken (1, not the stock line's stale 0)")
  V.factsHold(k, 0); msg("8 1507 HW P " .. k .. "=-")
  check(V.want[k] == nil and V.hwLast[k] == nil, "friend: HW P's '-' forgets a kept fraction too")
  -- off switch
  V.cfg.factsWork = false; clear(cmds)
  check(V.factsHold(k, 0x3F000000) == false and count(cmds, "SITEHP HOLD") == 0, "friend: Coop.values.cfg.factsWork = false: V.factsHold does nothing")
  msg("6 1505 HW P " .. k .. "=0.5")
  check(V.want[k] == 0.5, "friend: ... and HW P is taken")
  V.cfg.factsWork = true
  -- a building that is finished here: no hold
  local fin = building(18, 8000, 3000, true); arr[#arr + 1] = fin; rec(fin, true)
  clear(cmds)
  check(V.factsHold(key(fin), 0x3F000000) == false and count(cmds, "SITEHP HOLD") == 0, "friend: V.factsHold on a building finished here: no hold")
end

print("[3. cure 2's cure, coop_x_values.lua: BARNAN on a friend while the host is heard]")
do
  local cmds = {}
  local S = { role = "friend", eng = { buildingArr = {} }, startWall = 1000, ticks = 0 }
  local C = { s = S, modules = {} }
  _G.Coop = C
  function C.register(name, m) C.modules[name] = m; return m end
  function C.stale() return false end
  C.api = { un = function(x) return x end, valid = valid, btype = function(b) return b.t end, now = function() return 2000 end,
            log = function() end, send = function() end }
  C.world = { bkey = function() return "?" end, buildingByKey = function() end }
  local P = { fn = true, dir = HERE, items = { BARNAN = { state = "off", why = "zeroed=0 faults=0 bad=0" }, SITEHP = { state = "available", why = "hx=0 fills=0" } } }
  function P.send(l) cmds[#cmds + 1] = l; local a, b = l:match("^(%u+) (%u+)$"); if a == "BARNAN" and P.items.BARNAN then P.items.BARNAN.state = (b == "ON") and "on" or "off" end end
  function P.tick() end
  function P.status() return { state = "ready", items = P.items } end
  C.patch = P
  assert(loadfile(SCRIPTS .. "coop_x_values.lua"))()
  local V, M = C.values, C.modules.values
  local function tick(dt) T = T + (dt or 0.6); S.ticks = S.ticks + 1; M.tick(S, T) end
  local function msg(line) local w = words(line); return M.onMessage(S, "host", w[3], w, line) end
  tick(2.1)
  check(count(cmds, "BARNAN ON") == 0, "friend: nothing from the host yet: BARNAN stays off")
  msg("1 1500 HW X 1 1 1"); tick(2.1)
  check(count(cmds, "BARNAN ON") == 1 and V.bnOn == true, "friend: the host heard: BARNAN ON")
  clear(cmds); tick(2.1); tick(2.1)
  check(count(cmds, "BARNAN") == 0, "friend: on once, not again at every look")
  for _ = 1, 16 do tick(2.1) end                                -- the host silent for more than 30 s
  check(count(cmds, "BARNAN OFF") == 1 and V.bnOn == false, "friend: the host silent 30 s: BARNAN OFF")
  msg("2 1600 HW X 1 1 1"); clear(cmds); tick(2.1)
  check(count(cmds, "BARNAN ON") == 1, "friend: heard again: on again")
  V.cfg.barnan = false; clear(cmds); tick(2.1)
  check(count(cmds, "BARNAN OFF") == 1, "friend: Coop.values.cfg.barnan = false: BARNAN OFF")
  V.cfg.barnan = true; tick(2.1)
  clear(cmds); M.idle(S)
  check(count(cmds, "BARNAN OFF") == 1 and V.bnOn == false, "friend: at the menu or while loading (idle): BARNAN OFF")
  S.role = "host"; P.items.BARNAN.state = "off"; clear(cmds); msg("3 1700 HW X 1 1 1"); for _ = 1, 3 do tick(2.1) end
  check(count(cmds, "BARNAN ON") == 0, "host: never on (its own first frames stay the game's)")
end

io.open = io_open
os.remove(OUT)
print(string.format("RESULT: %d passed, %d failed", pass, fail))
