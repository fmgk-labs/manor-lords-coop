-- Lane 87 desk test (no game), step 1: a site's finish is one step, and every site is named again.
--   py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane87/t_sites.lua
-- Three modules, each loaded into a made-up core of its own:
--   1. coop_sites.lua   the host's "built" (B IS) is carried out in the tick it arrives; B.finishNow's rules
--   2. coop_facts.lua   host: cn=0 with the keyframe, cn=1 once with the stock after the finish; friend: its site is
--                       finished before those goods are written
--   3. coop_x_values.lua  a site the native piece dropped is named again (host WATCH, friend HOLD), an address that
--                       is no unfinished building of this tick's list is never named
-- Run p87a (the game): a friend showed HALF a bar at 7 of 7 finishes; the cases below fail on the code before.
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
local nextAddr = 0x1000
local function valid(o) return type(o) == "table" and not o.dead end

-- ================================================================ 1. the sites module
print("[1. coop_sites.lua: the host's word is carried out in the tick it arrives]")
do
  local sent, logs, finished = {}, {}, {}
  local BM = {}; BM.__index = BM
  function BM:GetAddress() return self.addr end
  function BM:K2_GetActorLocation() return { X = self.x, Y = self.y, Z = 0 } end
  function BM:IsRubble() return false end
  function BM:getConstructionProgress() return self.p or 0.5 end
  local function building(t, x, y, built)
    nextAddr = nextAddr + 0x100
    return setmetatable({ t = t, x = x, y = y, addr = nextAddr, Data = { constructed = built and true or false }, onFire = false, sleep = false }, BM)
  end
  local arr = {}
  local S = { role = "friend", worlds = 1, loads = 1, eng = { buildingArr = arr } }
  local C = { s = S, modules = {} }
  _G.Coop = C
  function C.register(name, m) C.modules[name] = m; return m end
  C.api = { un = function(x) return x end, valid = valid, btype = function(b) return b.t end,
            log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function(l) sent[#sent + 1] = l end }
  C.town = { quiet = function(f) f() end }
  local items = { NF1 = { state = "on" }, NF2 = { state = "on" } }
  local order = {}
  C.patch = { fn = true, send = function() end, tick = function() end,
              status = function() return { state = "ready", finish = true, items = items } end,
              finish = function(b) order[#order + 1] = "finish " .. b.addr; finished[#finished + 1] = b; b.Data.constructed = true; return true, "sent" end }
  C.values = { beforeFinish = function(k, a) order[#order + 1] = "fill " .. tostring(k) .. " " .. tostring(a) end }
  assert(loadfile(SCRIPTS .. "coop_sites.lua"))()
  local B, M = C.sites, C.modules.sites
  local function msg(line) local w = words(line); return M.onMessage(S, "host", w[3], w, line) end
  local site = building(18, 1000, 2000, false); arr[1] = site
  local other = building(4, 5000, 2000, false); arr[2] = other
  local sk, ok2 = "18@100,200", "4@500,200"
  msg("1 0 B SITES " .. sk .. ";" .. ok2)
  T = T + 1.1; M.tick(S, T)                                  -- a look: both are sites here, the host lists both
  check(#finished == 0 and B.here[sk] ~= nil, "a site the host lists is not finished")
  -- the host's word arrives 0.2 s after the look: finished in this tick, not at the next look 0.8 s later
  T = T + 0.2; msg("2 0 B IS " .. sk .. "=b"); M.tick(S, T)
  check(#finished == 1 and finished[1] == site, "B IS ...=b: the site is finished in the tick the word arrives (0.2 s after the last look)")
  check(order[1] == "fill " .. sk .. " " .. site.addr and order[2] == "finish " .. site.addr, "the values module is asked to fill the parts and end the hold BEFORE the finish call (" .. tostring(order[1]) .. "; " .. tostring(order[2]) .. ")")
  check(#finished == 1 and other.Data.constructed == false, "the other site is left alone")
  T = T + 0.1; M.tick(S, T); T = T + 1.0; M.tick(S, T)
  check(#finished == 1, "and only once")
  -- the switch off: the old way (the next look)
  B.cfg.atOnce = false
  local s2 = building(18, 3000, 2000, false); arr[3] = s2
  T = T + 1.1; M.tick(S, T)
  T = T + 0.2; msg("3 0 B IS 18@300,200=b"); M.tick(S, T)
  local early = #finished
  T = T + 0.9; M.tick(S, T)
  check(early == 1 and #finished == 2, "cfg.atOnce = false: the word waits for the next look, as before")
  B.cfg.atOnce = true
  -- finishNow (the facts module's word)
  check(B.finishNow(ok2) == "finished" and #finished == 3 and finished[3] == other, "finishNow: a site of the last look is finished")
  check(B.finishNow(ok2) == "not a site now", "finishNow: a building that is finished here: nothing")
  local s3 = building(18, 7000, 2000, false); arr[4] = s3
  check(B.finishNow("18@700,200") == "new here" and #finished == 3, "finishNow: a site newer than the last look is not finished (the caller waits)")
  T = T + 1.1; M.tick(S, T)
  check(B.finishNow("18@700,200") == "finished" and #finished == 4, "finishNow: after the look it is")
  local s4 = building(18, 9000, 2000, false); arr[5] = s4
  T = T + 1.1; M.tick(S, T)
  C.patch.finish = function(b) finished[#finished + 1] = b; return false, "refused" end
  check(B.finishNow("18@900,200") == "could not be finished", "finishNow: the finish call fails: said so")
  check(B.finishNow("18@900,200") == "tried a moment ago", "finishNow: no second try within 10 s")
  C.hold = true
  check(B.finishNow("18@900,200") == "a join or resync", "finishNow: nothing during a join or resync")
  C.hold = nil
  S.role = "host"
  check(B.finishNow("18@900,200") == "not a friend in a world", "finishNow: nothing on a host")
end

-- ================================================================ 2. the facts module
print("[2. coop_facts.lua: finished or not rides in the stock line]")
do
  T = 500.0
  local logs, sent, mod = {}, {}, nil
  local function live(o) return type(o) == "table" and o.live == true end
  _G.Coop = {
    register = function(name, m) if name == "facts" then mod = m end end, stale = function() return false end,
    api = { valid = live, un = function(o) return o end, now = os.clock, isPaused = function() return false end,
      btype = function(b) return b.type end,
      log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function(line) sent[#sent + 1] = line end }
  }
  local C = _G.Coop
  assert(loadfile(SCRIPTS .. "coop_facts.lua"))()
  local F = C.facts
  local function upvalue(fn, name, seen)
    seen = seen or {}; if seen[fn] then return end; seen[fn] = true
    for i = 1, 250 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name and v ~= nil then return v end end
    for i = 1, 250 do
      local n, v = debug.getupvalue(fn, i); if not n then break end
      if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
    end
  end
  local hostPassJob = assert(upvalue(mod.tick, "hostPassJob"), "hostPassJob not found")
  local friendPassJob = assert(upvalue(mod.tick, "friendPassJob"), "friendPassJob not found")
  local onLine = assert(upvalue(mod.onMessage, "onLine"), "onLine not found")
  local na = 0x30000
  local function obj(o) na = na + 16; local a = na; o.live = true; o.GetAddress = function() return a end; return o end
  local lord, region = obj({}), obj({})
  local function building(t, x, y, goods, built)
    local b = obj({ type = t, x = x, y = y, ownerPawn = lord, Region = region, Inventory = {}, onFire = false, Data = { constructed = built ~= false } })
    for g, a in pairs(goods or {}) do b.Inventory[#b.Inventory + 1] = { Type = g, amt = a } end
    function b:GetType() return self.type end
    function b:K2_GetActorLocation() return { X = self.x, Y = self.y, Z = 0 } end
    function b:IsConstructed() return self.Data.constructed end
    function b:isStorageTypeBuilding() return false end
    function b:isResidentialBuilding() return false end
    function b:addToInventory(r)
      for i, x in ipairs(self.Inventory) do
        if x.Type == r.Type then x.amt = x.amt + r.amt; if x.amt == 0 then table.remove(self.Inventory, i) end; return end
      end
      if r.amt ~= 0 then self.Inventory[#self.Inventory + 1] = { Type = r.Type, amt = r.amt } end
    end
    return b
  end
  local function stock(b) local t = {}; for _, x in ipairs(b.Inventory) do t[#t + 1] = x.Type .. "=" .. x.amt end; table.sort(t); return table.concat(t, ",") end
  local arr, S, site, sk
  local function pass1() local st = {}; for _ = 1, 500 do if hostPassJob(st) then return end end end
  local function fpass(quick) local st = { quick = quick }; for _ = 1, 200 do if friendPassJob(st) then return end end end
  local function setup(role)
    arr = {}
    for i = 1, 6 do arr[i] = building(18, 1000 * i, 5000, { [16] = 3 }) end
    site = building(18, 9000, 5000, { [17] = 2 }, false); arr[#arr + 1] = site; sk = "18@900,500"
    S = { role = role, worlds = 1, stats = {}, p1 = lord, eng = obj({ buildingArr = arr }) }
    C.patch = { goodsAvail = function() return true end }
    C.goneB = nil; C.snap = nil; C.sites = nil; C.hold = nil
    F.S = S; F.world = 1; F.me = lord.GetAddress(); F.exact = role == "friend"; F.on.stock = true; F.on.bar = true; F.on.values = false
    F.host = { b = {}, a = {}, m = {} }; F.sent = {}; F.unfin = {}; F.dirty = {}; F.pileGone = {}; F.catchMourning = {}; F.dumpSeen = {}; F.pileWant = {}; F.pileN = #arr
    F.stats = {}; F.t = { miss = -1e9, index = T, piles = T, lineIn = T }; F.jobs = {}; F.refused = {}; F.holds = {}; F.siteSaid = nil
    local list, map = {}, {}
    for _, b in ipairs(arr) do
      local k = string.format("%d@%d,%d", b.type, b.x / 10, b.y / 10)
      local e = { b = b, k = k, t = b.type, x = b.x / 10, y = b.y / 10, dump = false, store = false, res = false }
      list[#list + 1] = e; map[k] = e
    end
    F.idx = { list = list, map = map, store = {}, t = T, n = #arr, dumps = {}, lords = {} }
    F.on.exact = true
    sent = {}; logs = {}
  end
  local function entry(k) for _, l in ipairs(sent) do for ent in l:gsub("^F B ", ""):gmatch("[^;]+") do if ent:sub(1, #k) == k then return ent end end end end
  local function line(body) onLine(S, { "1", "0", "F", "B", body }) end

  -- ---- host
  setup("host"); pass1()
  check(entry(sk) == sk .. "!|17=2,cn=0", "host: an unfinished building's complete entry says cn=0 (" .. tostring(entry(sk)) .. ")")
  check(entry("18@100,500") == "18@100,500!|16=3", "host: a finished building's entry says nothing of it")
  sent = {}; T = T + 1.0; pass1()
  check(#sent == 0, "host: nothing changed, nothing sent")
  site.Inventory[1].amt = 1; T = T + 1.0; pass1()
  check(entry(sk) == sk .. "|17=1", "host: a change of the site's goods alone: no cn again")
  -- the finish: the game takes the goods and marks it finished in one tick
  sent = {}; site.Inventory = {}; site.Data.constructed = true; T = T + 1.0; pass1()
  check(entry(sk) == sk .. "|17=0,cn=1", "host: the pass that sees it finished: the goods after the finish and cn=1 in ONE entry (" .. tostring(entry(sk)) .. ")")
  sent = {}; T = T + 1.0; pass1()
  check(#sent == 0, "host: cn=1 once")
  F.keyframe(); sent = {}; T = T + 1.0; pass1()
  check(entry(sk) == sk .. "!|", "host: a keyframe of the finished building: no cn=1 again (" .. tostring(entry(sk)) .. ")")
  -- a keyframe between "unfinished" and "finished" (a friend joined): the change is still told
  setup("host"); pass1(); F.keyframe()
  sent = {}; site.Inventory = {}; site.Data.constructed = true; T = T + 1.0; pass1()
  check(entry(sk) == sk .. "!|cn=1", "host: finished right after a keyframe: the complete entry still says cn=1 (" .. tostring(entry(sk)) .. ")")
  -- it becomes unfinished again (a fire put out, an upgrade without a new name)
  sent = {}; site.Data.constructed = false; site.Inventory = { { Type = 17, amt = 1 } }
  T = T + 5.0; pass1(); T = T + 1.0; pass1(); T = T + 1.0; pass1(); T = T + 1.0; pass1(); T = T + 1.0; pass1()
  check(entry(sk) ~= nil and entry(sk):find("cn=0", 1, true) ~= nil, "host: unfinished again: cn=0 (within the passes that read 'finished and not burning' again)")
  -- the native building table says it (this frame's record), no reflected read (step 1; with cure 3 switched off:
  -- Coop.facts.on.wq = false)
  for _, wq in ipairs({ false, true }) do
  setup("host"); F.on.wq = wq
  local reads = 0
  local D = site.Data; site.Data = setmetatable({}, { __index = function(_, k) if k == "constructed" then reads = reads + 1 end; return D[k] end })
  site.IsConstructed = function() return D.constructed end      -- (the pass's own "finished and not burning" look is not counted)
  local recs = {}
  for _, b in ipairs(arr) do recs[b.GetAddress()] = { a = b.GetAddress(), cons = b ~= site } end
  C.snap = { buildings = function() return {} end, building = function(a) return recs[a] end }
  pass1()
  if not wq then
    check(entry(sk) == sk .. "!|17=2,cn=0" and reads == 0, "host (on.wq = false): with the native table the record says unfinished (no reflected read of the site: " .. reads .. "; " .. tostring(entry(sk)) .. ")")
  else
    -- (cure 3) a site's goods and finished-or-not come from the building itself in this tick (the table can be older)
    check(entry(sk) == sk .. "!|17=2,cn=0" and reads >= 1, "host (cure 3): a site of the table: finished or not read from the building itself in this tick (" .. reads .. " reads; " .. tostring(entry(sk)) .. ")")
  end
  sent = {}; site.Inventory = {}; D.constructed = true; recs[site.GetAddress()].cons = true; T = T + 1.0; pass1()
  check(entry(sk) == sk .. "|17=0,cn=1" and (wq or reads == 0), "host" .. (wq and " (cure 3)" or " (on.wq = false)") .. ": ... and finished, with the goods of the same pass (" .. tostring(entry(sk)) .. ")")
  C.snap = nil
  end
  F.on.wq = true
  -- the switch off
  setup("host"); F.on.bar = false; pass1()
  check(entry(sk) == sk .. "!|17=2", "host: Coop.facts.on.bar = false: no cn item")
  F.on.bar = true

  -- ---- friend
  local calls, atCall
  local function sitesMod(answer)
    calls = {}; atCall = nil
    C.sites = { finishNow = function(k)
      calls[#calls + 1] = k
      local a = type(answer) == "function" and answer() or answer
      if a == "finished" then atCall = stock(site); site.Data.constructed = true end
      return a
    end }
  end
  setup("friend"); sitesMod("finished")
  line(sk .. "!|17=2,cn=0"); fpass(true)
  check(#calls == 0 and stock(site) == "17=2" and site.Data.constructed == false, "friend: cn=0: the site's goods are written, nothing is finished")
  site.Inventory = { { Type = 17, amt = 2 } }
  line(sk .. "|17=0,cn=1"); fpass(true)
  check(#calls == 1 and calls[1] == sk and atCall == "17=2", "friend: cn=1: the site is finished BEFORE the goods are written (its goods at the finish: " .. tostring(atCall) .. ")")
  check(stock(site) == "" and site.Data.constructed == true and (F.stats.siteFinished or 0) == 1, "friend: then the goods after the finish are written")
  fpass(false)
  check(#calls == 1, "friend: finished once (the next pass does not ask again)")
  -- B IS came first: the building is finished here already
  setup("friend"); sitesMod("not a site now"); site.Data.constructed = true
  line(sk .. "!|17=2,cn=0"); fpass(true); line(sk .. "|17=0,cn=1"); fpass(true)
  check(#calls == 1 and stock(site) == "" and (F.stats.siteAlready or 0) == 1, "friend: already finished here (B IS came first): the goods are written at once")
  -- a site newer than the sites module's last look: its goods wait, then it is finished, then written
  setup("friend")
  local looks = 0
  sitesMod(function() looks = looks + 1; return looks < 3 and "new here" or "finished" end)
  line(sk .. "!|17=2,cn=0"); fpass(true); line(sk .. "|17=0,cn=1")
  fpass(true); local s1 = stock(site); T = T + 0.3; fpass(true); local s2 = stock(site)
  T = T + 0.3; fpass(true)
  check(s1 == "17=2" and s2 == "17=2" and stock(site) == "" and atCall == "17=2" and (F.stats.siteWaits or 0) == 2, "friend: a site newer than the last look: its goods wait (2 looks), then finish, then goods")
  -- ... but not for ever: after 2 s the goods are written (the old way; the sites module's word finishes it)
  setup("friend"); sitesMod("new here")
  line(sk .. "!|17=2,cn=0"); fpass(true); line(sk .. "|17=0,cn=1")
  fpass(true); T = T + 2.1; fpass(true)
  check(stock(site) == "" and site.Data.constructed == false and (F.stats.siteNotFinished or 0) == 1 and #logs >= 1, "friend: no look within 2 s: the goods are written, a log line says so")
  -- the switch off on the friend
  setup("friend"); sitesMod("finished"); F.on.bar = false
  line(sk .. "!|17=2,cn=0"); fpass(true); line(sk .. "|17=0,cn=1"); fpass(true)
  check(#calls == 0 and stock(site) == "", "friend: Coop.facts.on.bar = false: the item is ignored (the goods are written as before)")
  F.on.bar = true
  -- no sites module: the goods are written
  setup("friend"); C.sites = nil
  line(sk .. "!|17=2,cn=0"); fpass(true); line(sk .. "|17=0,cn=1"); fpass(true)
  check(stock(site) == "" and (F.stats.siteNotFinished or 0) == 1, "friend: no sites module: the goods are written")
  -- cn=0 after cn=1 before the pass looked (a new job on the host): no finish
  setup("friend"); sitesMod("finished")
  line(sk .. "!|17=2,cn=0"); fpass(true); line(sk .. "|17=0,cn=1"); line(sk .. "|17=1,cn=0"); fpass(true)
  check(#calls == 0 and stock(site) == "17=1", "friend: the host's building is unfinished again before this copy looked: no finish")
  -- ---- (merge of rel-0.2.7-int3) the same rule through the stock path's fast ends (lane 76, task 76e): the host sends
  -- a building whose native record changed in that tick (hostFast), a friend writes the host's line in the tick it
  -- came (friendFast). Both go through hostOne / evalBuilding, where cn lives: checked here.
  local hostFast, friendFast = upvalue(mod.tick, "hostFast"), upvalue(mod.tick, "friendFast")
  check(hostFast ~= nil and friendFast ~= nil, "the integration branch's fast ends are there (hostFast, friendFast)")
  if hostFast and friendFast then
    local CH
    setup("host"); pass1()
    C.snap = { takeChanged = function() local c = CH; CH = nil; return c end }
    sent = {}; site.Inventory = {}; site.Data.constructed = true; CH = { [site.GetAddress()] = true }
    T = T + 0.02; hostFast(S, T)
    check(entry(sk) == sk .. "|17=0,cn=1", "host, fast end: the finish goes out in the tick its record changed, cn=1 with the goods after it (" .. tostring(entry(sk)) .. ")")
    sent = {}; T = T + 1.0; pass1()
    check(entry(sk) == nil, "host, fast end: the next pass does not send cn=1 again (" .. tostring((entry(sk))) .. ")")
    C.snap = nil
    setup("friend"); sitesMod("finished")
    line(sk .. "!|17=2,cn=0"); friendFast(T)
    check(#calls == 0 and stock(site) == "17=2" and site.Data.constructed == false, "friend, fast end: cn=0: the goods are written, nothing is finished")
    line(sk .. "|17=0,cn=1"); T = T + 0.01; friendFast(T)
    check(#calls == 1 and atCall == "17=2" and stock(site) == "" and site.Data.constructed == true, "friend, fast end: cn=1: finished BEFORE the goods after the finish are written, in the tick the line came (goods at the finish: " .. tostring(atCall) .. ")")
    setup("friend")
    local looks = 0
    sitesMod(function() looks = looks + 1; return looks < 2 and "new here" or "finished" end)
    line(sk .. "!|17=2,cn=0"); friendFast(T); line(sk .. "|17=0,cn=1")
    T = T + 0.01; friendFast(T); local s1 = stock(site)
    T = T + 0.3; friendFast(T)
    check(s1 == "17=2" and stock(site) == "" and atCall == "17=2", "friend, fast end: a site newer than the sites module's last look waits (its goods unwritten), then finish, then goods")
  end
  -- ---- (lane 87, cure 3) a site's work fraction rides in its entry (wq), from the same moment as its goods
  print("[2b. cure 3: the work fraction in the stock line (wq)]")
  local HALF, MORE = 1056964608, 1057803469                     -- the bits of 0.5 and of 0.55
  local fracBits = HALF
  local fracAsked = {}
  local function valuesHost() C.values = { fracNow = function(k, a) fracAsked[#fracAsked + 1] = k; if k == sk and a == site.GetAddress() then return fracBits end end } end
  setup("host"); valuesHost(); fracBits = HALF; pass1()
  check(entry(sk) == sk .. "!|17=2,cn=0,wq=" .. HALF, "host: a site's complete entry carries wq, its work fraction's bits (" .. tostring(entry(sk)) .. ")")
  check(entry("18@100,500") == "18@100,500!|16=3", "host: a finished building's entry carries no wq")
  sent = {}; T = T + 1.0; pass1()
  check(#sent == 0, "host: the same fraction: nothing sent")
  fracBits = MORE; sent = {}; T = T + 1.0; pass1()
  check(entry(sk) == sk .. "|wq=" .. MORE, "host: the work alone moved: the entry carries the new wq (" .. tostring(entry(sk)) .. ")")
  -- the table's stock is up to 0.1 s old: the site's goods come from the building itself in this tick
  setup("host"); valuesHost(); fracBits = HALF
  local recs = {}
  for _, b in ipairs(arr) do recs[b.GetAddress()] = { a = b.GetAddress(), cons = b ~= site, inv = (b == site) and { [17] = 5 } or { [16] = 3 }, invN = 1 } end
  C.snap = { buildings = function() return {} end, building = function(a) return recs[a] end }
  pass1()
  check(entry(sk) == sk .. "!|17=2,cn=0,wq=" .. HALF, "host: a site's goods are read from the building in this tick, not the table's older row (17=5 there): " .. tostring(entry(sk)))
  check(entry("18@100,500") == "18@100,500!|16=3", "host: a finished building's goods still come from the table")
  -- the finish tick, the table still unfinished: cn=1 with the goods after the finish, and no wq
  sent = {}; site.Inventory = {}; site.Data.constructed = true; fracBits = 1065353216; T = T + 1.0; pass1()
  check(entry(sk) == sk .. "|17=0,cn=1", "host: finished in this tick while the table (older) says unfinished: cn=1 with the goods after the finish, no wq (" .. tostring(entry(sk)) .. ")")
  C.snap = nil
  -- (session l87f) the work alone moved: the values module tells (F.workSeen), and the fast step sends the site's entry
  -- with that work in its next tick, not at the pass's end
  if hostFast then
    setup("host"); valuesHost(); fracBits = HALF; pass1()
    C.snap = { takeChanged = function() return nil end }
    fracBits = MORE; sent = {}
    F.workSeen(site.GetAddress())
    T = T + 0.02; hostFast(S, T)
    check(entry(sk) == sk .. "|wq=" .. MORE, "host: the work alone moved: the fast step sends the site's entry with it in that tick (" .. tostring(entry(sk)) .. ")")
    sent = {}; T = T + 0.02; hostFast(S, T)
    check(#sent == 0, "host: once (the fast step's list is emptied)")
    C.snap = nil
  end
  -- the switch off
  setup("host"); valuesHost(); F.on.wq = false; pass1()
  check(entry(sk) == sk .. "!|17=2,cn=0", "host: Coop.facts.on.wq = false: no wq (" .. tostring(entry(sk)) .. ")")
  F.on.wq = true
  -- a site the values module does not watch: no wq, the entry as before
  setup("host"); C.values = { fracNow = function() return nil end }; pass1()
  check(entry(sk) == sk .. "!|17=2,cn=0", "host: no fraction for the site (not watched yet): no wq")
  -- friend: the hold in the tick of the entry's goods write, after the goods
  local holds, ends = {}, {}
  local function valuesFriend() C.values = { factsHold = function(k, u) holds[#holds + 1] = { k = k, u = u, goods = stock(site) }; return true end,
                                               factsEnd = function(k) ends[#ends + 1] = k end } end
  if friendFast then
    setup("friend"); sitesMod("finished"); valuesFriend()
    line(sk .. "!|17=2,cn=0,wq=" .. HALF); friendFast(T)
    check(#holds == 1 and holds[1].k == sk and holds[1].u == HALF and holds[1].goods == "17=2", "friend, fast end: wq held in the tick the line came, after the goods were written (goods at the hold: " .. tostring(holds[1] and holds[1].goods) .. ")")
    line(sk .. "|wq=" .. MORE); T = T + 0.01; friendFast(T)
    check(#holds == 2 and holds[2].u == MORE, "friend, fast end: an entry with only wq: held in its tick")
    T = T + 0.01; friendFast(T)
    check(#holds == 2, "friend, fast end: held once per entry")
    line(sk .. "|17=0,cn=1"); T = T + 0.01; friendFast(T)
    check(#ends == 1 and ends[1] == sk and #holds == 2, "friend: cn=1: the values module is told the site is finished (HW P is taken again), no hold")
    line(sk .. "-")
    check(#ends == 2 and ends[2] == sk, "friend: '<bkey>-' (no longer sent: a type change, gone): the values module is told too")
  end
  setup("friend"); sitesMod("finished"); valuesFriend(); holds = {}
  line(sk .. "!|17=2,cn=0,wq=" .. HALF); fpass(true)
  check(#holds == 1 and holds[1].goods == "17=2", "friend, the pass: wq held in the step that writes the building's goods (goods at the hold: " .. tostring(holds[1] and holds[1].goods) .. ")")
  line(sk .. "|wq=" .. MORE); fpass(true)
  check(#holds == 2 and holds[2].u == MORE, "friend, the pass: an entry with only wq: held at the pass's end")
  setup("friend"); sitesMod("finished"); valuesFriend(); holds = {}; F.on.bar = false
  line(sk .. "!|17=2,cn=0,wq=" .. HALF); fpass(true)
  check(#holds == 0, "friend: Coop.facts.on.bar = false: wq is not held")
  F.on.bar = true
  C.values = nil
end

-- ================================================================ 3. the values module
print("[3. coop_x_values.lua: a site the native piece dropped is named again]")
do
  T = 100.0
  local function f2b(x)
    if x == 0 then return 0 end
    local m, e = math.frexp(x); e = e + 126
    return e * 2 ^ 23 + math.floor((m * 2 - 1) * 2 ^ 23 + 0.5)
  end
  string.pack = string.pack or function(fmt, v) return (fmt == "<f" and "F" or "U") .. ":" .. string.format("%.17g", v) end
  string.unpack = string.unpack or function(fmt, s)
    local k, v = s:match("^(%a):(.*)$"); v = tonumber(v)
    if fmt == "<I4" then return k == "F" and f2b(v) or v end
    if k == "U" then                                         -- bits to the float
      local e = math.floor(v / 2 ^ 23); local m = v - e * 2 ^ 23
      if e == 0 then return m * 2 ^ -149 end
      return (1 + m / 2 ^ 23) * 2 ^ (e - 127)
    end
    return v
  end
  local BM = {}; BM.__index = BM
  function BM:GetAddress() return self.addr end
  function BM:K2_GetActorLocation() return { X = self.x, Y = self.y, Z = 0 } end
  function BM:GetType() return self.t end
  local function building(t, x, y, built)
    nextAddr = nextAddr + 0x100
    return setmetatable({ t = t, x = x, y = y, addr = nextAddr, Region = {}, Data = { constructed = built and true or false }, onFire = false }, BM)
  end
  local sent, logs, cmds = {}, {}, {}
  local arr = {}
  local S = { role = "host", eng = { buildingArr = arr }, startWall = 1000 }
  local C = { s = S, modules = {} }
  _G.Coop = C
  function C.register(name, m) C.modules[name] = m; return m end
  function C.stale() return false end
  C.api = { un = function(x) return x end, valid = valid, btype = function(b) return b.t end, now = function() return 2000 end,
            log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function(l) sent[#sent + 1] = l end }
  local function key(b) return string.format("%d@%d,%d", b.t, math.floor(b.x / 10 + 0.5), math.floor(b.y / 10 + 0.5)) end
  C.world = { bkey = key, buildingByKey = function(k) for _, b in ipairs(arr) do if valid(b) and key(b) == k then return b end end end }
  local P = { fn = true, dir = HERE, items = { COLLAPSE = { state = "watch" }, SITEHP = { state = "available" }, MROLL = { state = "watch" } } }
  function P.send(l) cmds[#cmds + 1] = l end
  function P.tick() end
  function P.status() return { state = "ready", items = P.items } end
  C.patch = P
  assert(loadfile(SCRIPTS .. "coop_x_values.lua"))()
  local V, M = C.values, C.modules.values
  local function tick(dt) T = T + (dt or 0.6); M.tick(S, T) end
  local site = building(34, 1000, 2000, false); arr[1] = site
  local done = building(18, 5000, 2000, true); arr[2] = done
  C.sites = { prev = { [key(site)] = site } }
  -- host
  tick(2.1); tick(1.1)
  check(count(cmds, "SITEHP WATCH " .. site.addr) == 1, "host: a site of the sites module's list is named to the native piece once")
  clear(cmds); tick(1.1); tick(1.1)
  check(count(cmds, "SITEHP WATCH") == 0, "host: not again a second later")
  clear(cmds); for _ = 1, 9 do tick(1.1) end
  check(count(cmds, "SITEHP WATCH " .. site.addr) == 1 and (V.stats.namedAgain or 0) >= 1, "host: named again after 10 s (a site the native piece dropped is watched again)")
  -- an address that is no unfinished building of this tick's list is not named
  local ghost = building(18, 8000, 2000, false)               -- a handle of the sites module's list that is no longer in the game's list
  C.sites.prev[key(ghost)] = ghost
  clear(cmds); for _ = 1, 12 do tick(1.1) end
  check(count(cmds, "SITEHP WATCH " .. ghost.addr) == 0 and count(cmds, "SITEHP WATCH " .. site.addr) >= 1, "host: a building that is not in the game's list in this tick is never named")
  C.sites.prev[key(done)] = done
  clear(cmds); for _ = 1, 12 do tick(1.1) end
  check(count(cmds, "SITEHP WATCH " .. done.addr) == 0, "host: nor one that is finished in this tick")
  -- with the native building table: its record of this frame decides
  local recs = { [site.addr] = { cons = false, reg = 0x5000 } }
  C.snap = { buildings = function() return {} end, building = function(a) return recs[a] end }
  clear(cmds); for _ = 1, 12 do tick(1.1) end
  check(count(cmds, "SITEHP WATCH " .. site.addr) >= 1, "host: with the native table: a record that says unfinished is named")
  recs[site.addr] = nil
  clear(cmds); for _ = 1, 12 do tick(1.1) end
  check(count(cmds, "SITEHP WATCH") == 0, "host: ... and an address the table does not hold is not")
  recs[site.addr] = { cons = false, reg = 0 }
  clear(cmds); for _ = 1, 12 do tick(1.1) end
  check(count(cmds, "SITEHP WATCH") == 0, "host: an unfinished building without a region (a resource spot) is never named (the native piece refuses it)")
  C.snap = nil
  local spot = building(85, 20000, 2000, false); spot.Region = nil; arr[#arr + 1] = spot
  C.sites.prev[key(spot)] = spot
  clear(cmds); for _ = 1, 12 do tick(1.1) end
  check(count(cmds, "SITEHP WATCH " .. spot.addr) == 0, "host: the same without the native table")
  C.sites.prev[key(spot)] = nil
  -- friend
  S.role = "friend"; C.sites = nil
  M.onWorld(S)
  local function msg(line) local w = words(line); return M.onMessage(S, "host", w[3], w, line) end
  msg("1 1500 HW X 1 1 1"); msg("2 1501 HW P " .. key(site) .. "=0.5000")
  clear(cmds); tick(0.6); tick(0.6)
  check(count(cmds, "SITEHP HOLD " .. site.addr .. " 3F000000") == 1, "friend: the host's fraction is held")
  clear(cmds); tick(0.6); tick(0.6)
  check(count(cmds, "SITEHP HOLD") == 0, "friend: the same fraction: no command")
  clear(cmds); for _ = 1, 18 do tick(0.6) end
  check(count(cmds, "SITEHP HOLD " .. site.addr .. " 3F000000") == 1, "friend: the hold is named again after 10 s (a site the native piece dropped is held again)")
  msg("3 1502 HW X 1 1 1"); msg("4 1503 HW P " .. key(ghost) .. "=0.2500")
  clear(cmds); for _ = 1, 4 do tick(0.6) end
  check(count(cmds, "SITEHP HOLD " .. ghost.addr) == 0, "friend: a building that is not in the game's list is not held")
  -- (step 2a) the fraction bit for bit: nine digits on the way, HOLDX when this copy's native piece has it
  print("[3b. the fraction is the host's to the last bit]")
  P.items.SITEHP.why = "held=1 watched=0 writes=0 polls=0 lines=0 gone=0 bad=0 faults=0 hx=0 near=0 cap=1024"
  for _ = 1, 5 do tick(0.6) end                                -- the look that reads the native piece's line
  msg("5 1504 HW X 1 1 1"); msg("6 1505 HW P " .. key(site) .. "=0.300000012")      -- the float 0.3 with nine digits
  clear(cmds); tick(0.6); tick(0.6)
  check(count(cmds, "SITEHP HOLDX " .. site.addr .. " 3E99999A") >= 1 and count(cmds, "SITEHP HOLD ") == 0, "friend: nine digits come back as the float's own bits (0.3 = 3E99999A), held with HOLDX")
  msg("7 1506 HW P " .. key(site) .. "=0.300000042"); clear(cmds); tick(0.6); tick(0.6)
  check(count(cmds, "SITEHP HOLDX " .. site.addr .. " 3E99999B") >= 1, "friend: the next float up (one step, 0.00000003) is another hold: no four-decimal rounding")
  V.cfg.exact = false
  msg("8 1507 HW P " .. key(site) .. "=0.5"); clear(cmds); tick(0.6); tick(0.6)
  check(count(cmds, "SITEHP HOLD " .. site.addr .. " 3F000000") >= 1 and count(cmds, "SITEHP HOLDX") == 0, "friend: Coop.values.cfg.exact = false: the old HOLD")
  V.cfg.exact = true
  P.items.SITEHP.why = "held=1 watched=0 writes=0 polls=0 lines=0 gone=0 bad=0 faults=0"         -- a native piece without HOLDX
  for _ = 1, 5 do tick(0.6) end
  msg("9 1508 HW X 1 1 1"); msg("10 1509 HW P " .. key(site) .. "=0.75"); clear(cmds); tick(0.6); tick(0.6)
  check(count(cmds, "SITEHP HOLD " .. site.addr .. " 3F400000") >= 1 and count(cmds, "SITEHP HOLDX") == 0, "friend: a native piece without HOLDX: the old HOLD")
  -- host: the float itself goes into the line
  -- (the module reads the native piece's file with read("a"), Lua 5.4's form; this desk test runs under 5.1: "*a")
  local io_open = io.open
  io.open = function(path, mode)
    local fh, e = io_open(path, mode); if not fh then return nil, e end
    return setmetatable({}, { __index = function(_, k)
      if k == "read" then return function(_, fmt) return fh:read(fmt == "a" and "*a" or fmt) end end
      return function(_, ...) return fh[k](fh, ...) end
    end })
  end
  S.role = "host"; M.onWorld(S)
  os.remove(HERE .. "sitehp_out.txt")                          -- (a file an interrupted run left)
  C.sites = { prev = { [key(site)] = site } }
  clear(sent); clear(cmds)
  tick(2.1); tick(1.1)                                         -- the look, the watch
  local f = assert(io.open(HERE .. "sitehp_out.txt", "wb")); f:write(string.format("%X 3E99999A\r\n", site.addr)); f:close()
  tick(0.6)
  check(has(sent, "HW P " .. key(site) .. "=0.300000012"), "host: the polled fraction is sent with nine digits (" .. tostring(sent[#sent]) .. ")")
  f = assert(io.open(HERE .. "sitehp_out.txt", "wb")); f:write(string.format("%X 3E99999B\r\n", site.addr)); f:close()
  clear(sent); tick(0.6)
  check(has(sent, "HW P " .. key(site) .. "=0.300000042"), "host: a change of one float step is sent (" .. tostring(sent[#sent]) .. ")")
  -- a building finished since the sites module's last look: its fraction (1) is not sent
  site.Data.constructed = true
  f = assert(io.open(HERE .. "sitehp_out.txt", "wb")); f:write(string.format("%X 3F800000\r\n", site.addr)); f:close()
  clear(sent); tick(0.6)
  check(not has(sent, "HW P " .. key(site)), "host: a building that is finished in this tick: its fraction is not sent (a friend's site would read 1.0 before its finish)")
  -- (run p87d) the native table is up to 0.1 s old: its record still says "unfinished" while the game says finished
  local recs3 = { [site.addr] = { a = site.addr, cons = false, reg = 1, pos = 0 } }
  C.snap = { buildings = function() return {} end, building = function(a) return recs3[a] end,
             obj = function(r) for _, b in ipairs(arr) do if b.addr == r.a then return b end end end }
  f = assert(io.open(HERE .. "sitehp_out.txt", "wb")); f:write(string.format("%X 3F800000\r\n", site.addr)); f:close()
  clear(sent); tick(0.6)
  check(not has(sent, "HW P " .. key(site)), "host: the fraction 1 of a building the native table (up to 0.1 s old) still shows unfinished and the game says finished: not sent")
  site.Data.constructed = false
  f = assert(io.open(HERE .. "sitehp_out.txt", "wb")); f:write(string.format("%X 3F800000\r\n", site.addr)); f:close()
  clear(sent); tick(0.6)
  check(has(sent, "HW P " .. key(site) .. "=1"), "host: the fraction 1 of a site the game says is unfinished (every part full, goods missing) is sent (" .. tostring(sent[#sent]) .. ")")
  C.snap = nil
  site.Data.constructed = false
  -- (run p87e) a site whose type changes while it is a site keeps its object and address under a new key (a rival's
  -- storehouse upgrade, 72 to 99): the old key's end must not take the new key's watch, and the POLL line of that
  -- address is the new key's
  local up = building(72, 15000, 2000, false); arr[#arr + 1] = up
  local k72 = key(up)
  C.sites.prev = { [key(site)] = site, [k72] = up }
  clear(cmds); tick(1.1)                                       -- the old key named (WATCH)
  f = assert(io.open(HERE .. "sitehp_out.txt", "wb")); f:write(string.format("%X 3E800000\r\n", up.addr)); f:close()
  clear(sent); tick(0.6)                                       -- its POLL line: 0.25
  local sentOld = has(sent, "HW P " .. k72 .. "=0.25")
  up.t = 99
  local k99 = key(up)
  C.sites.prev = { [key(site)] = site, [k99] = up }
  clear(cmds); clear(sent); tick(1.1)                          -- no POLL line now: the site stands still at its change
  check(sentOld and count(cmds, "SITEHP DROP " .. up.addr) == 0 and count(cmds, "SITEHP WATCH " .. up.addr) >= 1,
        "host: a site whose type changed (72 to 99, one object): the old key ends and its address is not dropped (the new key names it)")
  check(has(sent, "HW P " .. k72 .. "=-;" .. k99 .. "=0.25"), "host: ... the new key takes the old key's last fraction in the line of the old key's end, with no POLL line (a site standing still) (" .. tostring(sent[#sent]) .. ")")
  f = assert(io.open(HERE .. "sitehp_out.txt", "wb")); f:write(string.format("%X 3E000000\r\n", up.addr)); f:close()
  clear(sent); tick(0.6)
  check(has(sent, "HW P " .. k99 .. "=0.125"), "host: ... and the next POLL line of that address is the new key's: its work is sent (" .. tostring(sent[#sent]) .. ")")
  up.dead = true; C.sites.prev = { [key(site)] = site }; tick(1.1)
  os.remove(HERE .. "sitehp_out.txt")
  io.open = io_open
  -- friend: ahead of a finish the parts are filled and the hold ended (SITEHP FILL)
  S.role = "friend"; C.sites = nil; M.onWorld(S)
  P.items.SITEHP.why = "held=0 watched=0 writes=0 polls=0 lines=0 gone=0 bad=0 faults=0 hx=0 near=0 cap=1024 fills=0"
  msg("20 1520 HW X 1 1 1"); for _ = 1, 5 do tick(0.6) end
  msg("21 1521 HW P " .. key(site) .. "=0.998"); tick(0.05); tick(0.05)
  clear(cmds)
  check(V.beforeFinish(key(site), site.addr) == true and count(cmds, "SITEHP FILL " .. site.addr) == 1 and V.held[key(site)] == nil, "friend: before a finish: SITEHP FILL for the site, and the module no longer counts it held")
  V.cfg.exact = false; clear(cmds)
  check(V.beforeFinish(key(site), site.addr) == false and count(cmds, "SITEHP FILL") == 0, "friend: Coop.values.cfg.exact = false: no FILL (the old way)")
  V.cfg.exact = true
  P.items.SITEHP.why = "held=0 watched=0 writes=0 polls=0 lines=0 gone=0 bad=0 faults=0 hx=0 near=0 cap=1024"
  msg("22 1522 HW P " .. key(site) .. "=0.998"); for _ = 1, 5 do tick(0.6) end; clear(cmds)
  check(V.beforeFinish(key(site), site.addr) == false and count(cmds, "SITEHP FILL") == 0 and V.held[key(site)] == site.addr,
        "friend: a native piece with the exact hold but without FILL (no fills= in its line): none sent, and the hold stays known (so it is dropped after the finish)")
  P.items.SITEHP.why = "held=0 watched=0 writes=0 polls=0 lines=0 gone=0 bad=0 faults=0"
  for _ = 1, 5 do tick(0.6) end; clear(cmds)
  check(V.beforeFinish(key(site), site.addr) == false and count(cmds, "SITEHP FILL") == 0, "friend: a native piece without FILL: none sent")
  -- (run p87e) friend: two keys hold one address (a site whose type changed; the world module's index still finds the
  -- object by its old key for a moment): the old key's end does not drop the hold the new key has on that address
  S.role = "friend"; C.sites = nil; M.onWorld(S)
  P.items.SITEHP.why = "held=0 watched=0 writes=0 polls=0 lines=0 gone=0 bad=0 faults=0 hx=0 near=0 cap=1024 fills=0"
  msg("30 1530 HW X 1 1 1"); for _ = 1, 5 do tick(0.6) end
  local up2 = building(72, 16000, 2000, false); arr[#arr + 1] = up2
  local k72b = key(up2)
  local findByKey = C.world.buildingByKey
  C.world.buildingByKey = function(k) if k == k72b then return up2 end; return findByKey(k) end
  msg("31 1531 HW P " .. k72b .. "=0.5"); tick(0.05); tick(0.05)
  up2.t = 99; local k99b = key(up2)
  msg("32 1532 HW P " .. k99b .. "=0.25"); tick(0.05); tick(0.05)
  local both = V.held[k72b] == up2.addr and V.held[k99b] == up2.addr
  clear(cmds); msg("33 1533 HW P " .. k72b .. "=-"); tick(0.05); tick(0.05)
  check(both and count(cmds, "SITEHP DROP " .. up2.addr) == 0 and V.held[k99b] == up2.addr and V.held[k72b] == nil,
        "friend: the old key of a site whose type changed ends ('=-'): the hold the new key has on that address is not dropped")
  C.world.buildingByKey = findByKey; up2.dead = true
  -- the host's line of a type change: the old key's end and the new key's fraction in one line (see the host above)
  local up3 = building(72, 17000, 2000, false); arr[#arr + 1] = up3
  local k72c = key(up3)
  msg("34 1534 HW P " .. k72c .. "=0.5"); tick(0.05); tick(0.05)
  local heldOld = V.held[k72c] == up3.addr
  up3.t = 99; local k99c = key(up3)
  clear(cmds); msg("35 1535 HW P " .. k72c .. "=-;" .. k99c .. "=0.25"); tick(0.05); tick(0.05)
  check(heldOld and count(cmds, "SITEHP DROP " .. up3.addr) == 0 and V.held[k99c] == up3.addr and V.held[k72c] == nil
        and count(cmds, "SITEHP HOLDX " .. up3.addr .. " 3E800000") == 1,
        "friend: the host's line of a type change (the old key's end, the new key's fraction): the address stays held, at the new key's fraction")
  up3.dead = true
  -- friend: the host's line is carried out in the tick it arrives; a site new in the game's list is held in its tick
  S.role = "friend"; C.sites = nil; M.onWorld(S)
  P.items.SITEHP.why = "held=0 watched=0 writes=0 polls=0 lines=0 gone=0 bad=0 faults=0 hx=0 near=0 cap=1024"
  msg("11 1510 HW X 1 1 1"); for _ = 1, 5 do tick(0.6) end
  clear(cmds); tick(0.05); msg("12 1511 HW P " .. key(site) .. "=0.25"); tick(0.05)
  check(count(cmds, "SITEHP HOLDX " .. site.addr .. " 3E800000") == 1, "friend: the host's fraction is held in the tick after its line (0.05 s), not at the next half second")
  local late = building(18, 30000, 2000, false)
  msg("13 1512 HW P " .. key(late) .. "=0.5"); tick(0.05); tick(0.05)
  local recs2 = { { a = site.addr, cons = false, reg = 1, pos = 0 } }
  C.snap = { buildings = function() return recs2 end, building = function(a) for _, r in ipairs(recs2) do if r.a == a then return r end end end,
             obj = function(r) for _, b in ipairs(arr) do if b.addr == r.a then return b end end end }
  clear(cmds); tick(0.05); tick(0.05)
  check(count(cmds, "SITEHP HOLDX " .. late.addr) == 0, "friend: a site the host names that is not here yet: nothing")
  arr[#arr + 1] = late; recs2[#recs2 + 1] = { a = late.addr, cons = false, reg = 1, pos = #arr - 1 }
  tick(0.05)
  check(count(cmds, "SITEHP HOLDX " .. late.addr .. " 3F000000") == 1, "friend: it comes into the game's list: held in that tick (0.05 s after the last look)")
  C.snap = nil
end

print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_sites failed") end
