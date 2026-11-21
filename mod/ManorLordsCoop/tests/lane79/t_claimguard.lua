-- Desk test of lane 79's claim guard (coop_realm.lua: R SET _ claim on the host, R NO _ claim on a friend).
-- Runs WITHOUT the game, with made-up lords and regions:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane79/t_claimguard.lua mod/ManorLordsCoop/Scripts/
-- It loads the real coop_realm.lua three times (the host, friend1, friend2, each with its own stand-in Coop) and checks:
--   * enemies present in the target region on the host: no layClaim on the host, one refusal line to the sender,
--     with the game's words; the sender gets one notice, its own claim is undone and its favour / influence are the
--     host's at once; another friend shows nothing and changes nothing;
--   * no enemies: the host lays the claim with the sender's favour flag, no refusal line;
--   * the question is asked with includeEncamped = true;
--   * a region the lord already holds is still refused (no claim, no refusal line);
--   * the question failing: the claim goes through as before, and the failure is logged.
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (arg and arg[1]) or ((here():match("^(.*)/tests/lane79/[^/]*$") or ".") .. "/Scripts/")
if ARG1 then scripts = ARG1 end
if scripts:sub(-1) ~= "/" and scripts:sub(-1) ~= "\\" then scripts = scripts .. "/" end
local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end

local function str(s) return { ToString = function() return s end } end
_G.FName = function(s) return str(s) end
_G.FindAllOf = function() return {} end
_G.RegisterHook = function() end

local nextAddr = 0x1000
local LORDCLASS = { IsValid = function() return true end, GetAddress = function() return 0x77 end }
local OTHERCLASS = { IsValid = function() return true end, GetAddress = function() return 0x78 end }
local function obj(o, cls) nextAddr = nextAddr + 16; local a = nextAddr
  o.GetAddress = function() return a end; o.IsValid = function() return true end; o.GetClass = function() return cls or LORDCLASS end; return o end

local function makeRegion(tag, owner, enemies)
  local r = obj({ regionUniqueTag = str(tag), ownerPawn = owner, enemies = enemies, asked = {} })
  function r:areAnyEnemySquadsPresent(enc)
    self.asked[#self.asked + 1] = enc
    if self.enemies == "error" then error("no such function") end
    return self.enemies == true
  end
  return r
end
local function makeLord(influence, favour)
  local L = obj({ claims = {}, influence = influence, kingsFavour = favour, laid = {} })
  function L:layClaim(reg, fav, x)
    self.laid[#self.laid + 1] = { reg = reg, fav = fav, x = x }
    self.claims[#self.claims + 1] = { Region = reg, DaysLeft = 14, blocked = false, Score = 0.0 }
    if fav then self.kingsFavour = self.kingsFavour - 1 end
  end
  function L:getPawnSetupIndex() return 0 end
  return L
end

local sent = {}
local function makeCoop(role, name, lord, regions)
  local C = { s = { role = role, name = name, worlds = 1, on = true, p1 = lord, eng = { buildingArr = {}, regions = regions } } }
  C.logs = {}; C.notices = {}
  C.api = { un = function(x) return x end, valid = function(x) return x ~= nil and (type(x) ~= "table" or x.IsValid == nil or x:IsValid()) end,
    log = function(f, ...) local l = string.format(f, ...); C.logs[#C.logs + 1] = l; print("    [" .. name .. "] " .. l) end,
    send = function(line) sent[#sent + 1] = { from = name, line = line } end, btype = function() return nil end, now = function() return 0 end,
    pawns = function() return { lord } end }
  C.register = function(n, m) C.module = m end
  C.notify = function(kind, text) C.notices[#C.notices + 1] = { kind = kind, text = text } end
  C.lord = { claimHow = {} }
  C.town = { quiet = function(f) f() end }
  return C
end
local function load(C)
  _G.Coop = C
  local chunk = assert(loadfile(scripts .. "coop_realm.lua"))
  chunk()
  return C.module
end
local function line(C, M, from, text)
  _G.Coop = C
  local w = { "1", "0" }; for x in text:gmatch("%S+") do w[#w + 1] = x end
  return M.onMessage(C.s, from, w[3], w, text)
end
local function deliverFrom(fromName, C, M)
  for _, s in ipairs(sent) do if s.from == fromName then line(C, M, fromName, s.line) end end
end
local function sentBy(name, pat) local n, last = 0, nil; for _, s in ipairs(sent) do if s.from == name and s.line:find(pat) then n = n + 1; last = s.line end end; return n, last end

-- the world: the player's home "hof", rival A2's region "zwei" (raiders there), rival's "gold" (no enemies)
local rival = obj({}, OTHERCLASS)
local function world(lord)
  return { makeRegion("hof", lord, false), makeRegion("zwei", rival, true), makeRegion("gold", rival, false), makeRegion("wald", rival, "error") }
end
local hostLord = makeLord(1000, 1)
local hostRegions = world(hostLord)
local CH = makeCoop("host", "host", hostLord, hostRegions); local MH = load(CH)
local f1Lord = makeLord(1000, 1)
local f1Regions = world(f1Lord); f1Regions[2].enemies = false     -- friend1's copy does not hold the raiders
local CF = makeCoop("friend", "friend1", f1Lord, f1Regions); local MF = load(CF)
local f2Lord = makeLord(1000, 1)
local CG = makeCoop("friend", "friend2", f2Lord, world(f2Lord)); local MG = load(CG)

-- the friends know the host's values (as the host's poll sends them)
for _, C in ipairs({ { CF, MF }, { CG, MG } }) do
  line(C[1], C[2], "host", "R IS _ claims_P 0")
  line(C[1], C[2], "host", "R IS _ lord_P 1000,1")
end

print("[A] enemies present on the host: friend1's claim on zwei by king's favour")
-- friend1 pressed the claim on its own copy (its screen allowed it: no raiders there): the game laid it, favour 1 -> 0
f1Lord:layClaim(f1Regions[2], true, true); CF.lord.claimHow.zwei = { fav = true, t = os.clock() }
sent = {}
line(CH, MH, "friend1", "R SET _ claim zwei:f")
check(#hostLord.laid == 0, "the host did not lay the claim")
check(hostLord.kingsFavour == 1, "the host's favour is untouched (" .. hostLord.kingsFavour .. ")")
check(hostRegions[2].asked[1] == true, "the host asked areAnyEnemySquadsPresent(includeEncamped = true)")
local n, l = sentBy("host", "^R NO _ claim ")
check(n == 1, "one refusal line went out (" .. n .. ")")
check(l and l:find("^R NO _ claim zwei:f friend1 ") ~= nil, "it names the region, the payment and the sender: " .. tostring(l))
local logged = false; for _, x in ipairs(CH.logs) do if x:find("friend1's claim on zwei", 1, true) and x:find("refused", 1, true) then logged = true end end
check(logged, "the host's log says so")
deliverFrom("host", CF, MF); deliverFrom("host", CG, MG)
check(#CF.notices == 1 and CF.notices[1].text == "Can't claim when enemy units are present", "friend1 got one notice in the game's words: " .. tostring(CF.notices[1] and CF.notices[1].text))
check(#f1Lord.claims == 0, "friend1's own claim is undone at once (" .. #f1Lord.claims .. " claims)")
check(f1Lord.kingsFavour == 1 and f1Lord.influence == 1000, "friend1's favour and influence are the host's at once (" .. f1Lord.kingsFavour .. ", " .. f1Lord.influence .. ")")
check(CF.lord.claimHow.zwei == nil, "the claim is no longer this player's to send")
check(#CG.notices == 0, "friend2 shows nothing")
check(#f2Lord.claims == 0 and f2Lord.kingsFavour == 1, "friend2 changed nothing")
-- the friend's poll after the refusal: nothing is sent again
sent = {}
MF.tick(CF.s, 20.0); MF.tick(CF.s, 21.0)
check(sentBy("friend1", "^R SET _ claim ") == 0, "friend1 does not send the claim again")

print("[B] no enemies on the host: friend1's claim on gold by influence")
sent = {}
line(CH, MH, "friend1", "R SET _ claim gold:i")
check(#hostLord.laid == 1 and hostLord.laid[1].reg == hostRegions[3], "the host laid the claim on gold")
check(hostLord.laid[1] and hostLord.laid[1].fav == false, "by influence (favour flag false)")
check(sentBy("host", "^R NO ") == 0, "no refusal line")

print("[C] by king's favour, no enemies: the flag is passed")
hostLord.claims = {}; hostLord.laid = {}
line(CH, MH, "friend1", "R SET _ claim gold:f")
check(hostLord.laid[1] and hostLord.laid[1].fav == true, "by king's favour (favour flag true)")

print("[D] a region the lord already holds: refused as before, no refusal line, the guard not asked")
sent = {}; hostLord.laid = {}
local askedBefore = #hostRegions[1].asked
line(CH, MH, "friend1", "R SET _ claim hof:i")
check(#hostLord.laid == 0, "no claim on the own region")
check(sentBy("host", "^R NO ") == 0, "no refusal line")
check(#hostRegions[1].asked == askedBefore, "the enemies question is not asked for an own region")

print("[E] the question fails: the claim goes through as before, logged")
sent = {}; hostLord.laid = {}; hostLord.claims = {}
line(CH, MH, "friend1", "R SET _ claim wald:i")
check(#hostLord.laid == 1, "the claim on wald is laid")
local said = false; for _, x in ipairs(CH.logs) do if x:find("question failed", 1, true) then said = true end end
check(said, "the failure is in the host's log")

print("[F] the enemies leave: the same claim on zwei is carried out")
sent = {}; hostLord.laid = {}; hostLord.claims = {}; hostRegions[2].enemies = false
line(CH, MH, "friend1", "R SET _ claim zwei:f")
check(#hostLord.laid == 1 and hostLord.laid[1].reg == hostRegions[2] and hostLord.laid[1].fav == true, "the host laid the claim on zwei by favour")
check(sentBy("host", "^R NO ") == 0, "no refusal line")

print("[G] an accepted claim: the host answers; when the host's claim ends (a war takes it) the friend follows in about 1 s")
-- friend1 lays a claim on gold on its copy and the poll sends it
f1Lord.claims = {}; CF.lord.claimHow = {}
for _, C in ipairs({ { CF, MF } }) do line(C[1], C[2], "host", "R IS _ claims_P 0") end
f1Lord:layClaim(f1Regions[3], false, true); CF.lord.claimHow.gold = { fav = false, t = os.clock() }
sent = {}
local T = 100.0
MF.tick(CF.s, T)
check(sentBy("friend1", "^R SET _ claim gold:i") == 1, "friend1 sent its claim on gold")
hostLord.claims = {}; hostLord.laid = {}
deliverFrom("friend1", CH, MH)
local nOk, lOk = sentBy("host", "^R OK _ claim ")
check(nOk == 1 and lOk:find("^R OK _ claim gold:i friend1") ~= nil, "the host answered: " .. tostring(lOk))
deliverFrom("host", CF, MF)
check(CF.lord.claimHow.gold == nil, "friend1: the claim is the host's now")
line(CF, MF, "host", "R IS _ claims_P gold:14:0:0.00")       -- the host's poll: its list holds the claim
MF.tick(CF.s, T + 0.6)
check(#f1Lord.claims == 1, "friend1 keeps the claim while the host has it")
line(CF, MF, "host", "R IS _ claims_P 0")                    -- 2.8 s later the host's claim is gone (war)
MF.tick(CF.s, T + 3.0); MF.tick(CF.s, T + 3.6)
check(#f1Lord.claims == 1, "not at once (the difference is seen first)")
MF.tick(CF.s, T + 4.2)
check(#f1Lord.claims == 0, "taken from the host 1.2 s after the difference was seen (GRACE would be 3 s): " .. #f1Lord.claims)
sent = {}
MF.tick(CF.s, T + 5.0)
check(sentBy("friend1", "^R SET _ claim ") == 0, "and not sent again")

print("[H] a claim still on its way keeps the 3 s grace")
f1Lord.claims = {}; CF.lord.claimHow = {}
f1Lord:layClaim(f1Regions[3], false, true); CF.lord.claimHow.gold = { fav = false, t = os.clock() }
T = 200.0
MF.tick(CF.s, T)                                             -- sends; the host has not answered
MF.tick(CF.s, T + 1.2); MF.tick(CF.s, T + 2.4)
check(#f1Lord.claims == 1, "the claim stays while it is on its way (2.4 s)")

print("[I] the host's \"under attack\" flags: told on change, taken by the friend after 1 s of difference")
for _, r in ipairs(hostRegions) do r.isUnderAttack = false end
for _, r in ipairs(f1Regions) do r.isUnderAttack = false end
hostRegions[2].isUnderAttack = true
sent = {}
MH.tick(CH.s, 300.0)
local nA, lA = sentBy("host", "^R ATK ")
check(nA == 1 and lA:find("zwei=1", 1, true) ~= nil and lA:find("hof=0", 1, true) ~= nil, "the host sent its flags (first: all): " .. tostring(lA))
deliverFrom("host", CF, MF)
sent = {}; MH.tick(CH.s, 300.3)
check(sentBy("host", "^R ATK ") == 0, "nothing again while nothing changes")
f1Regions[2].isUnderAttack = false
MF.tick(CF.s, 300.3)
check(f1Regions[2].isUnderAttack == false, "not at once (the friend's own may come within a second)")
MF.tick(CF.s, 300.6); MF.tick(CF.s, 300.9)
check(f1Regions[2].isUnderAttack == false, "not before 1 s")
MF.tick(CF.s, 301.4)
check(f1Regions[2].isUnderAttack == true, "taken after 1 s of difference")
hostRegions[2].isUnderAttack = false
sent = {}; MH.tick(CH.s, 302.0)
local _, lB = sentBy("host", "^R ATK ")
check(lB == "R ATK zwei=0", "a change: only that region: " .. tostring(lB))
deliverFrom("host", CF, MF)
f1Regions[2].isUnderAttack = false                         -- the friend's own recompute came first
MF.tick(CF.s, 302.3); MF.tick(CF.s, 303.6)
check(f1Regions[2].isUnderAttack == false and (CF.realm.atkN or {}).zwei == 1, "equal again: no further write")
CF.realm.on.attack = false
f1Regions[2].isUnderAttack = true
MF.tick(CF.s, 304.0); MF.tick(CF.s, 305.5)
check(f1Regions[2].isUnderAttack == true, "switch off: nothing is written")

print(string.format("t_claimguard: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_claimguard: " .. fail .. " failed") end
