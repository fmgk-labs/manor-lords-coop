-- Lane 87 desk test (no game): NOROLL, a friend's own mercenary month roll held (lanes/lane_s21_87/design_noroll.txt).
--   py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane87/t_noroll.lua
-- 1. coop_realm.lua mercsApply: a friend holding fewer offers than the host grows its list by the game's own roll let
--    through once (P.noRollPass), takes the host's records and cuts what the roll made beyond the host's count, all in
--    one call (one tick); lane 88's hook on the routine is not entered inside that call; without NOROLL the old refill.
-- 2. coop_x_values.lua: NOROLL ON while the host is heard and the realm module follows the host's offers with MERCCUT
--    and NOLOG is on here; OFF when the host is silent, when the switch is off, at the menu.
local SCRIPTS = HERE .. "../../Scripts/"
local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
local t = 0
os.clock = function() return t end
local function str(s) return { ToString = function() return s end } end
_G.FName = function(s) return str(s) end
_G.FindAllOf = function() return {} end
_G.StaticFindObject = function() return nil end
local hooks = {}
_G.RegisterHook = function(name, fn) hooks[name] = fn; return 1, 2 end

-- ================================================================ 1. the realm module
print("[1. coop_realm.lua: a friend's list grows by the game's own roll, let through once]")
do
  local function rec(name, cost)
    local d = { cost = cost, colorA = 1, colorB = 2, emblemA = 3, emblemB = 4, arrivesIn = 5, units = { str("merc_inf") }, traits = {} }
    d.Name = str(name)
    return setmetatable({}, { __index = d, __newindex = function(_, k, v) if k == "Name" and type(v) == "string" then v = str(v) end; d[k] = v end })
  end
  local ENG = 0x50000
  local function list(...) return setmetatable({ ... }, { __index = { GetArrayAddress = function() return ENG + 0xBF0 end } }) end
  local cuts, refills, rolls, passes, passOk = {}, 0, 0, 0, true
  local C = { s = nil }
  local R
  local function makeS(role, offers)
    local eng = { availableMercs = offers, regions = {}, buildingArr = {} }
    function eng:GetAddress() return ENG end
    function eng:refillMercenaries() refills = refills + 1 end              -- the game's: an empty routine in this build
    function eng:rerollMercenaries()                                         -- the game's roll: empties the list, makes three
      rolls = rolls + 1
      local a = self.availableMercs
      for i = #a, 1, -1 do a[i] = nil end
      for i = 1, 3 do a[i] = rec("own_" .. rolls .. "_" .. i, 10 * i) end
      local h = hooks["/Script/ManorLords.RTSMultiEngineCPP:rerollMercenaries"]
      if h then h() end                                                      -- lane 88's hook fires for a call through the script layer
    end
    local p1 = {}
    function p1:updateMercenayCompanyUI() end
    return { role = role, name = role == "host" and "host" or "friend1", worlds = 1, on = true, p1 = p1, eng = eng, stats = {} }
  end
  C.api = { un = function(x) return x end, valid = function(x) return x ~= nil and x ~= false end, log = function(f, ...) print("    " .. string.format(f, ...)) end,
    send = function() end, btype = function() return nil end, now = function() return t end, pawns = function() return {} end }
  C.register = function(n, m) C.module = m end
  C.patch = {
    mercAvail = function() return true end,
    mercCut = function(e, l, now, want)
      cuts[#cuts + 1] = { now = now, want = want, t = t }
      local a = C.s.eng.availableMercs
      assert(#a == now, "the cut was asked with a wrong count")
      for i = #a, want + 1, -1 do a[i] = nil end
      return true
    end,
    noRollPass = function() if passOk then passes = passes + 1; return true end; return false end }
  _G.Coop = C
  assert(loadfile(SCRIPTS .. "coop_realm.lua"))()
  local M = assert(C.module, "realm did not register")
  R = C.realm
  R.on.lords = false; R.on.perk = false; R.on.tax = false; R.on.policy = false; R.on.name = false; R.on.fams = false; R.on.notices = false
  local function upvalue(fn, name, seen)
    seen = seen or {}; if seen[fn] then return end; seen[fn] = true
    for i = 1, 200 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name then return v end end
    for i = 1, 200 do local n, v = debug.getupvalue(fn, i); if not n then break end; if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end end
  end
  local mercsStr = assert(upvalue(M.tick, "mercsStr"), "mercsStr not found")
  local pollGlobal = assert(upvalue(M.tick, "pollGlobal"), "pollGlobal not found")
  -- the host's list as it came, its count changed just now (age 0: a cut by the old rule would wait 1.5 s)
  local function hostSays(v, age)
    R.gHost = R.gHost or {}; R.gHost.mercs = { v = v }
    local n = (v == "0") and 0 or select(2, v:gsub("|", "|")) + 1
    R.mercHostN = n; R.mercHostNT = os.clock() - (age or 0)
  end
  local function reset() cuts, refills, rolls, passes = {}, 0, 0, 0; R.mercRefillFor = nil; R.mercPrevN = nil; R.mercDropT = nil; R.mercT = nil; R.mercTry = nil; R.mercNoCut = nil; R.mercShort = nil; R.stats.mercHold = nil end
  local H2 = makeS("host", list(rec("vultures", 300), rec("greencaps", 200)))
  local host2 = mercsStr(H2, nil, true)
  local H3 = makeS("host", list(rec("vultures", 300), rec("greencaps", 200), rec("huntsmen", 120)))
  local host3 = mercsStr(H3, nil, true)
  -- the realm module's tick once, so that lane 88's hooks are registered (they are made on a friend's tick)
  local F0 = makeS("friend", list(rec("vultures", 300), rec("greencaps", 200)))
  C.s = F0; t = 1.0; pcall(M.tick, F0, t)
  check(hooks["/Script/ManorLords.RTSMultiEngineCPP:rerollMercenaries"] ~= nil, "(lane 88's hook on the roll is registered on a friend)")
  -- A. one offer here, two on the host (after a hire the friend was cut to 1; the host's month roll then made 2 here 3)
  local F = makeS("friend", list(rec("vultures", 300)))
  C.s = F; reset(); hostSays(host2, 0)
  t = 10.0; pollGlobal(F, t, false)
  check(passes == 1 and rolls == 1 and refills == 0, "fewer offers than the host, NOROLL on: one PASS, then the game's own roll (not the empty refill)")
  check(mercsStr(F, nil, true) == host2, "... in the same call: the host's records written over the roll's (" .. mercsStr(F, nil, true):sub(1, 40) .. ")")
  check(#cuts == 1 and cuts[1].now == 3 and cuts[1].want == 2 and cuts[1].t == 10.0, "... and what the roll made beyond the host's count cut at once (3 -> 2; the host's count changed just now: the old rule waits 1.5 s)")
  check((R.stats.mercHold or 0) == 0, "lane 88's hook fired inside the roll and did not enter the offers' hold (no nested write)")
  t = 10.5; pollGlobal(F, t, false); t = 11.0; pollGlobal(F, t, false)
  check(rolls == 1 and passes == 1, "once for that host list: no second roll at the next looks")
  -- B. two here, three on the host: the roll makes three, all take the host's records, nothing to cut
  local Fb = makeS("friend", list(rec("vultures", 300), rec("greencaps", 200)))
  C.s = Fb; reset(); hostSays(host3, 0)
  t = 20.0; pollGlobal(Fb, t, false)
  check(rolls == 1 and #cuts == 0 and mercsStr(Fb, nil, true) == host3, "two here, three on the host: the roll's three take the host's records; nothing cut")
  -- C. NOROLL not on here (or NOLOG off): the refill as before, no roll
  local Fc = makeS("friend", list(rec("vultures", 300)))
  C.s = Fc; reset(); passOk = false; hostSays(host2, 2.0)
  t = 30.0; pollGlobal(Fc, t, false)
  check(rolls == 0 and refills == 1 and passes == 0, "NOROLL not on: the game's refill as before (it makes nothing in this build), no roll")
  check(Fc.eng.availableMercs[1].Name:ToString() == "vultures" and R.mercShort == true, "... the host's first record written, the rest cannot be made here (R.mercShort, as before)")
  passOk = true
  -- C2. a rival's hire on the host (3 offers -> 2), its count new: with NOROLL on here the cut comes in the same call
  -- (the host's two records over slots 1 and 2, then the cut), never the list [B, C, C] for 1.5 s
  C.patch.noRollOn = function() return passOk end
  local Fe = makeS("friend", list(rec("vultures", 300), rec("greencaps", 200), rec("huntsmen", 120)))
  C.s = Fe; reset(); hostSays(host2, 0)
  t = 35.0; pollGlobal(Fe, t, false)
  check(#cuts == 1 and cuts[1].t == 35.0 and mercsStr(Fe, nil, true) == host2 and rolls == 0,
        "NOROLL on: a host list of 2 just after a rival's hire: the host's records and the cut in one call (no 1.5 s wait)")
  passOk = false
  local Ff = makeS("friend", list(rec("vultures", 300), rec("greencaps", 200), rec("huntsmen", 120)))
  C.s = Ff; reset(); hostSays(host2, 0)
  t = 36.0; pollGlobal(Ff, t, false)
  check(#cuts == 0 and #Ff.eng.availableMercs == 3, "NOROLL not on: the old wait (the cut only after the host's count stood 1.5 s)")
  passOk = true
  -- D. as many offers as the host: nothing rolled
  local Fd = makeS("friend", list(rec("brigands", 150), rec("huntsmen", 120)))
  C.s = Fd; reset(); hostSays(host2, 2.0)
  t = 40.0; pollGlobal(Fd, t, false); t = 40.5; pollGlobal(Fd, t, false)
  check(rolls == 0 and passes == 0 and mercsStr(Fd, nil, true) == host2, "as many offers as the host: no roll, the host's records written field by field")
end

-- ================================================================ 2. the values module
print("[2. coop_x_values.lua: NOROLL ON while the host is heard and the offers follow the host's]")
do
  t = 100.0
  local cmds, logs = {}, {}
  local function count(pat) local n = 0; for _, l in ipairs(cmds) do if l:find(pat, 1, true) then n = n + 1 end end; return n end
  local S = { role = "friend", eng = { buildingArr = {} }, startWall = 1000 }
  local C = { s = S, modules = {} }
  _G.Coop = C
  function C.register(name, m) C.modules[name] = m; return m end
  function C.stale() return false end
  C.api = { un = function(x) return x end, valid = function(o) return type(o) == "table" end, btype = function() return 0 end, now = function() return 2000 end,
            log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function() end }
  local items = { NOROLL = { state = "off", why = "blocked=0 passed=0 expired=0 bad=0" } }
  local P = { fn = true, dir = HERE, nlOn = true }
  function P.send(l) cmds[#cmds + 1] = l; if l == "NOROLL ON" then items.NOROLL.state = "on" elseif l == "NOROLL OFF" then items.NOROLL.state = "off" end end
  function P.tick() end
  function P.status() return { state = "ready", items = items } end
  function P.mercAvail() return true end
  C.patch = P
  C.realm = { on = { mercs = true } }
  assert(loadfile(SCRIPTS .. "coop_x_values.lua"))()
  local V, M = C.values, C.modules.values
  local function tick(dt) t = t + (dt or 0.6); M.tick(S, t) end
  local function msg(line) local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end; return M.onMessage(S, "host", w[3], w, line) end
  M.onWorld(S)
  for _ = 1, 5 do tick(0.6) end
  check(count("NOROLL ON") == 0, "the host not heard yet: NOROLL stays off")
  msg("1 1500 HW X 1 1 1"); for _ = 1, 5 do tick(0.6) end
  check(count("NOROLL ON") == 1 and V.nrOn == true, "the host heard, the realm module follows the host's offers, MERCCUT and NOLOG here: NOROLL ON")
  for _ = 1, 10 do tick(0.6) end
  check(count("NOROLL ON") == 1, "... once (not again at every look)")
  for _ = 1, 60 do tick(0.6) end                                     -- 36 s without a word of the host
  check(count("NOROLL OFF") == 1 and items.NOROLL.state == "off", "nothing from the host for 30 s: NOROLL OFF (this copy's game rolls its own again)")
  msg("2 1501 HW X 1 1 1"); for _ = 1, 5 do tick(0.6) end
  check(items.NOROLL.state == "on", "the host heard again: on again")
  C.realm.on.noroll = false; for _ = 1, 5 do tick(0.6) end
  check(items.NOROLL.state == "off", "Coop.realm.on.noroll = false: off")
  C.realm.on.noroll = nil; P.nlOn = false; for _ = 1, 5 do tick(0.6) end
  check(items.NOROLL.state == "off", "NOLOG not on here (the roll's own notice would show): not switched on")
  P.nlOn = true; C.realm.mercNoCut = true; for _ = 1, 5 do tick(0.6) end
  check(items.NOROLL.state == "off", "a cut that did not take (the realm module's old rule): not on (the list could not be made equal)")
  C.realm.mercNoCut = nil; for _ = 1, 5 do tick(0.6) end
  check(items.NOROLL.state == "on", "(on again)")
  local idle = C.modules.values.idle
  idle(S)
  check(items.NOROLL.state == "off" and V.nrOn == false, "at the menu or while loading (the core's idle): NOROLL OFF")
  items.NOROLL = { state = "unavailable", why = "another game build" }; cmds = {}
  msg("3 1502 HW X 1 1 1"); for _ = 1, 5 do tick(0.6) end
  check(count("NOROLL") == 0, "NOROLL unavailable (another build): nothing sent")
end

print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_noroll failed") end
