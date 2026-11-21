local madeAt
-- Desk test of the free merchants' inventory (lane 82, 2026-11-19). Runs WITHOUT the game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane82/t_merch82.lua <an empty folder>
-- (Lua 5.4, or Lua 5.1 with the stand-ins below.) It loads the real coop.lua, coop_x_men.lua and coop_x_merch.lua;
-- units are plain tables, the native piece is stood in for, the clock is the test's own.
-- What it shows:
--   A  M.plan alone (the shipped function): the cases of probe P1 and of lanes 64 and 73.
--   B  the whole friend side on a load case, twice: with the module as it was before this lane (the copy
--      old_merch_lane73.lua beside this file, its removal switched ON) and with the module of now. The case: the host
--      has a merchant it made after its own load (no squad there); the friend loaded the save, where that merchant has
--      a squad number, another unit id (a load numbers the units anew) and stands 40 m from the host's. Before: a replacement is made and the merchant
--      from the save is destroyed. Now: he is paired, nothing is made, nothing is destroyed.
--   C  the rule of now in play: a merchant the host has no more goes in two lists and never earlier; never more than
--      the surplus; a stale, replayed, early or cut list does nothing; a merchant made here stays the one of his key.

local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local tdir = here():match("^(.*)/[^/]*$") or "."
local scripts = (here():match("^(.*)/tests/lane82/[^/]*$") or ".") .. "/Scripts/"
local dir = (arg and arg[1]) or ARG1
if not dir then print("give an empty folder: lua t_merch82.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end

if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout)
  local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
  math.tointeger = math.tointeger or function(x) x = tonumber(x); if x and x == math.floor(x) then return x end end
end

_G.COOP_LINK_DIR = dir
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
local T = 900.0
os.clock = function() return T end

local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function words(line) local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end; return w end

-- ---------------------------------------------------------------- a friend's copy of the game, as plain tables
local C, S, men, merch, sentCmds, made, destroyed, nextAddr, nextId
local function mk(addr, id, sq, x, y, role)
  return { IsValid = function() return true end, GetAddress = function() return addr end, realPos = { X = x, Y = y or 2000, Z = 30 }, UniqueID = id,
           K2_SetActorLocation = function() end, assignedSquadID = { Value = sq }, currentUnitRole = role or 6 }
end
local function add(u) S.eng.freeMerchants[#S.eng.freeMerchants + 1] = u; S.eng.unitArr[#S.eng.unitArr + 1] = u; return u end
local function addAnimal(u, addr, id) local an = mk(addr, id, 0, u.realPos.X + 100, u.realPos.Y, 15); u.mountActor = an; S.eng.unitArr[#S.eng.unitArr + 1] = an; return an end
local function fresh(merchFile)
  _G.Coop = nil
  dofile(scripts .. "coop.lua")
  C = _G.Coop; C.linkCut = 0
  sentCmds = {}
  C.patch = { fn = function() end, dir = dir, tick = function() end,
              send = function(line) for l in tostring(line):gmatch("[^\n]+") do sentCmds[#sentCmds + 1] = l end end,
              status = function() return { items = { MEN = { state = "hooked" } }, text = "menstat held=0 pace=in raised=0 runoffs=0 rlast=0 lets=0 lead=0 leads=0 fars=0" } end }
  dofile(scripts .. "coop_x_men.lua")
  dofile(merchFile)
  men, merch = C.modules.men, C.modules.merch
  T = T + 20.0
  C.start("friend", "friend1", {})
  S = C.s
  men.onWorld(S); merch.onWorld(S)
  made, destroyed, nextAddr, nextId = {}, {}, 0x9000, 9000
  S.eng = { IsValid = function() return true end, freeMerchants = {}, livestockMerchants = {}, buildingArr = {}, unitArr = {}, spawnMerchants = false }
  -- the game's spawnFreeMerchant as the probes showed it: a merchant without a squad on the list, and his pack animal (role 15, his mountActor)
  function S.eng:spawnFreeMerchant(reg)
    madeAt = madeAt or {}; madeAt[#madeAt + 1] = reg
    local u = mk(nextAddr, nextId, 0, 0, 0); nextAddr = nextAddr + 0x100; nextId = nextId + 1
    add(u); addAnimal(u, nextAddr, nextId); nextAddr = nextAddr + 0x100; nextId = nextId + 1
    made[#made + 1] = u
    return u
  end
  function S.eng:destroyUnit(u)
    destroyed[#destroyed + 1] = u
    u.IsValid = function() return false end
    for _, list in ipairs({ self.freeMerchants, self.livestockMerchants, self.unitArr }) do for i = #list, 1, -1 do if list[i] == u then table.remove(list, i) end end end
  end
  S.p1 = { IsValid = function() return true end, GetAddress = function() return 1 end, Camera = { K2_GetComponentLocation = function() return { X = 9e6, Y = 9e6, Z = 0 } end },
           getClosestOwnedRegion = function() return { IsValid = function() return true end, GetAddress = function() return 0x99 end } end }
  local function bySq(v) for _, u in ipairs(S.eng.freeMerchants) do if u.assignedSquadID.Value == v then return u end end end
  S.sc = { IsValid = function() return true end, IsValidSquad = function(_, t) return bySq(t.Value) ~= nil end, GetUnitCount = function() return 1 end,
           GetSquad = function(_, t) return { squadType = 6, unitArr = { bySq(t.Value) }, TargetLocation = { X = 0, Y = 0 } } end }
  S.worldT = T - 60
  T = T + 3.0; men.tick(S, T)
end
local function line(kind, text, ago) sentCmds = {}; merch.onMessage(S, "host", kind, words("9 " .. string.format("%.3f", C.api.now() - (ago or 0)) .. " " .. kind .. " " .. text)) end
-- the host's lists as the two versions of the module send them, from one description { id, sq, mount, x, y }
local seq = 0
local function fi(hostList, opt)                       -- the module of now: the whole list, FI
  opt = opt or {}
  seq = seq + 1
  local e = {}
  for _, h in ipairs(hostList) do e[#e + 1] = string.format("%d:%d:%d:%d,%d,30", h.id, h.sq, h.mount or 0, h.x, h.y or 2000) .. (h.rg and (":" .. h.rg) or "") end
  T = T + 0.75
  line("FI", string.format("%d %d %d 1 1 %s", opt.world or 1, seq, opt.n or #e, #e > 0 and table.concat(e, ";") or "-"), opt.ago)
end
local function fmNew(hostList)                         -- the module of now: the places, keys "u<id>"
  local e = {}
  for _, h in ipairs(hostList) do e[#e + 1] = string.format("u%d:%d,%d,30:%d,%d,30:0,0", h.id, h.x, h.y or 2000, h.x + 90000, h.y or 2000) end
  line("FM", "1 " .. (#e > 0 and table.concat(e, ";") or "-"))
end
local function fmOld(hostList)                         -- the module of before: a full list, key = squad number, or "u<id>" without a squad
  local e = {}
  for _, h in ipairs(hostList) do e[#e + 1] = string.format("%s:%d,%d,30:%d,%d,30:0,0", h.sq ~= 0 and tostring(h.sq) or ("u" .. h.id), h.x, h.y or 2000, h.x + 90000, h.y or 2000) end
  T = T + 1.6
  line("FM", "1 " .. (#e > 0 and table.concat(e, ";") or "-"))
end
local function has(list, u) for _, x in ipairs(list) do if x == u then return true end end return false end

-- ================================================================ A  the plan alone
fresh(scripts .. "coop_x_merch.lua")
local plan = C.merch.plan
check(type(plan) == "function", "coop_x_merch.lua loads outside the game and has M.plan")
local function H(id, sq, x, y, mount) return { key = "u" .. id, id = id, sq = sq, x = x, y = y or 0, mount = mount or 0 } end
local function L(ref, id, sq, x, y, mount) return { ref = ref, id = id, sq = sq, x = x, y = y or 0, mount = mount or false } end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
do
  -- probe P1, d2: 20 merchants of the save (the same id and squad), 4 the host made after its load (squad 0 on the
  -- host, a squad number on the friend), the friend's 30 m off after its load
  local host, hr = {}, {}
  for i = 1, 20 do host[i] = H(300 + i, 8 + i, i * 50000); hr[i] = L("r" .. i, 300 + i, 8 + i, i * 50000 + 3000) end
  for i = 1, 4 do host[20 + i] = H(509 + 2 * i, 0, -80000, i * 1500); hr[20 + i] = L("n" .. i, 509 + 2 * i, 1523397616 + i, -80000 + 3000, i * 1500) end
  local P = plan(host, hr, {}, { far = true })
  check(P.n.squad == 20 and P.n.order == 4 and #P.make == 0 and #P.left == 0 and P.pair.u511 == "n1" and P.pair.u517 == "n4",
        "a friend's load (probe P1): 20 paired by squad, the 4 without a squad on the host by the order of their ids; nothing to make, nothing left")
  -- lane 64's live case: every merchant of the host's was made after its load (squad 0), the friend has one fewer
  local h2, l2 = {}, {}
  for i = 1, 16 do h2[i] = H(600 + i, 0, i * 40000) end
  for i = 1, 15 do l2[i] = L("r" .. i, 600 + i, 1523397600 + i, i * 40000 + 4000) end
  P = plan(h2, l2, {}, { far = true })
  check(P.n.order == 15 and #P.make == 1 and P.make[1] == "u616" and #P.left == 0,
        "lane 64's live case (every merchant without a squad on the host, this copy one short): 15 paired in the order of their ids, ONE to make, none left to take out")
  -- a load that moved this copy's ids (probe P1, d3: every id one up): the saved squads and the places still pair them
  local l3 = {}
  for i = 1, 20 do l3[i] = L("r" .. i, 301 + i, 8 + i, i * 50000 + 3000) end
  for i = 1, 4 do l3[20 + i] = L("n" .. i, 510 + 2 * i, 1523397616 + i, -80000 + 3000, i * 1500) end
  P = plan(host, l3, {}, { far = true })
  local right = true
  for i = 1, 20 do if P.pair["u" .. (300 + i)] ~= "r" .. i then right = false end end
  for i = 1, 4 do if P.pair["u" .. (509 + 2 * i)] ~= "n" .. i then right = false end end
  check(right and #P.make == 0 and #P.left == 0 and P.n.squad == 20 and P.n.order == 4,
        "this copy's ids all one up: 20 paired by squad and 4 by order, each with the right one; nothing made or left")
  -- the proof run's own lists (out/proof1_r7_before_*): three merchants without a squad on the host, walking in a line
  -- 18 m apart; the friend loaded alone and its ids are 545, 549, 552 for the host's 541, 545, 550 (an EQUAL id, 545,
  -- names the neighbour), each 60 m behind the host's
  local h7 = { H(326, 24, 0), H(541, 0, 500000, 0, 542), H(545, 0, 501800, 0, 546), H(550, 0, 503600, 0, 551) }
  local l7 = { L("a", 330, 24, 0), L("p", 545, 1523397624, 494000, 0, true), L("q", 549, 1523397625, 495800, 0, true), L("r", 552, 1523397626, 497600, 0, true) }
  P = plan(h7, l7, {}, { far = true })
  check(P.pair.u541 == "p" and P.pair.u545 == "q" and P.pair.u550 == "r" and P.n.order == 3 and #P.make == 0 and #P.left == 0,
        "ids moved by a load: the three in a line are paired in the order of their ids, each with his own; the equal id of a neighbour is not taken")
  -- the same, and the host's middle one has no pack animal while the others have: the one here without an animal is his
  local h8 = { H(541, 0, 500000, 0, 542), H(545, 0, 501800, 0, 0), H(550, 0, 503600, 0, 551) }
  local l8 = { L("p", 545, 1, 494000, 0, true), L("q", 549, 2, 495800, 0, false), L("r", 552, 3, 497600, 0, true), L("x", 560, 4, 499400, 0, true) }
  P = plan(h8, l8, {}, { far = true })
  check(P.pair.u545 == "q" and #P.left == 1 and #P.make == 0 and (P.left[1] == "x" or P.left[1] == "p" or P.left[1] == "r") and P.left[1] ~= "q",
        "one more here than on the host, in a line: three paired in order, the one without a pack animal with the host's one without; one WITH an animal is left")
  -- one more here than on the host (the host's merchant left between its save and this copy's load)
  local h4 = {}; for i = 1, 23 do h4[i] = host[i] end
  P = plan(h4, hr, {}, { far = true })
  check(#P.left == 1 and P.left[1] == "n4" and #P.make == 0 and count(P.pair) == 23, "one merchant here that the host has no more: he alone is left, 23 paired, nothing to make")
  -- in play (all paired once): the host has a new merchant, this copy still has one whose host merchant left
  local prior = {}; for i = 1, 23 do prior[h4[i].key] = hr[i].ref end
  local h5 = {}; for i = 1, 22 do h5[i] = h4[i] end; h5[23] = H(900, 0, 500000)
  local l5 = {}; for i = 1, 23 do l5[i] = hr[i] end
  P = plan(h5, l5, prior, {})
  check(P.n.kept == 22 and #P.make == 1 and P.make[1] == "u900" and #P.left == 1 and P.left[1] == "n3",
        "in play: 22 pairs kept; the host's new merchant is to make and the one whose merchant left is left (the surplus rule decides when he goes)")
  P = plan(h5, l5, prior, { far = true })
  check(#P.make == 0 and #P.left == 0 and P.how.u900 == "far", "after a load (far pairing): the two are paired instead: nothing is made while this copy has an unpaired merchant")
  P = plan(h5, l5, prior, { farKeys = { u900 = true } })
  check(#P.make == 0 and #P.left == 0 and P.how.u900 == "far", "a key whose making failed takes the unpaired merchant")
  -- a merchant made here keeps his key, whatever his own unit id is (the same id as another host merchant's)
  local h6 = { H(700, 0, 0), H(9000, 0, 800000) }
  local l6 = { L("made", 9000, 0, 100), L("x", 55, 0, 900000) }
  P = plan(h6, l6, { u700 = "made" }, {})
  check(P.pair.u700 == "made" and P.how.u700 == "kept" and P.make[1] == "u9000" and P.left[1] == "x",
        "a merchant made here for a key stays that key's, though his own unit id is another host merchant's")
  P = plan({}, { L("a", 1, 0, 0), L("b", 2, 0, 0) }, {}, { far = true })
  check(#P.left == 2 and #P.make == 0, "a host without merchants: both of this copy's are left")
  P = plan({ H(1, 0, 0) }, {}, {}, { far = true })
  check(#P.make == 1 and #P.left == 0, "a copy without merchants: the host's one is to make")
end

-- ================================================================ B  the load case, before and now
-- the host: 3 merchants of its save (squads 11, 12, 13) and u511, made after its load (squad 0), with a pack animal.
-- the friend loaded the save: u511 has squad 1523397617 here, unit id 512 (every id one up, probe P1 d3) and stands
-- 40 m from the host's (lane 58: 26 to 43 m after a friend's load).
local hostB = { { id = 319, sq = 11, x = 100000 }, { id = 321, sq = 12, x = 200000 }, { id = 322, sq = 13, x = 300000 }, { id = 511, sq = 0, mount = 512, x = 400000 } }
local function loadCase()
  local t = {}
  t[1] = add(mk(0x5000, 320, 11, 100000 + 4000)); t[2] = add(mk(0x5100, 322, 12, 200000 + 4000)); t[3] = add(mk(0x5200, 323, 13, 300000 + 4000))
  t[4] = add(mk(0x5300, 512, 1523397617, 400000 + 4000)); t.animal = addAnimal(t[4], 0x5400, 513)
  return t
end
fresh(tdir .. "/old_merch_lane73.lua")
C.m58destroy = true                                     -- the removal of before, switched on (lane 73's run 13 had it on)
local saved = loadCase()
for _ = 1, 6 do fmOld(hostB) end
local oldMade, oldKilledSaved, oldKilledAnimal = #made, has(destroyed, saved[4]), has(destroyed, saved.animal)
check(oldMade == 1 and oldKilledSaved and oldKilledAnimal,
      string.format("BEFORE (the module of lane 73, removal on): the load case makes a replacement (%d) and destroys the merchant from the save (%s) and his animal (%s): the fault", oldMade, tostring(oldKilledSaved), tostring(oldKilledAnimal)))

fresh(scripts .. "coop_x_merch.lua")
C.m58destroy = true
saved = loadCase()
for _ = 1, 8 do fi(hostB); fmNew(hostB) end
check(#made == 0 and #destroyed == 0 and C.merch.pairU.u511 == saved[4] and C.merch.steady == true,
      string.format("NOW (removal on): the same load case: made %d, destroyed %d; the merchant from the save is the host's u511", #made, #destroyed))
check(saved[4].realPos.X == 400000, "and he is put at the host's place (the place rule of before, by his pair)")

-- ================================================================ C  the rule in play
-- the host's merchant 321 leaves: this copy's goes at the second list, his animal first, and nobody else
local a2 = addAnimal(saved[2], 0x5500, 400)
local host3 = { hostB[1], hostB[3], hostB[4] }
fi(host3)
check(#destroyed == 0, "the host's merchant left: not taken out at the first list that lacks him")
fi(host3)
check(#destroyed == 2 and destroyed[1] == a2 and destroyed[2] == saved[2], "at the second list (0.75 s later): his pack animal, then he; nobody else")
for _ = 1, 4 do fi(host3) end
check(#destroyed == 2 and #S.eng.freeMerchants == 3, "then nothing more goes: 3 here, 3 on the host")
-- the host makes one: seen in two lists, made once, tied to the key; his animal stays (the host's has one)
local zwei = { IsValid = function() return true end, GetAddress = function() return 0xC2 end, regionUniqueTag = { ToString = function() return "zwei" end } }
S.eng.regions = { { IsValid = function() return true end, GetAddress = function() return 0xC1 end, regionUniqueTag = { ToString = function() return "hof" end } }, zwei }
madeAt = {}
local host4 = { hostB[1], hostB[3], hostB[4], { id = 530, sq = 0, mount = 531, x = 600000, rg = "zwei" } }
fi(host4); check(#made == 0, "the host has a new merchant: not made at the first list")
fi(host4); check(#made == 1 and C.merch.pairU.u530 == made[1] and made[1].realPos.X == 600000 and made[1].mountActor.IsValid(), "made at the second list with spawnFreeMerchant, at the host's place, with his pack animal")
for _ = 1, 5 do fi(host4) end
check(#made == 1 and #destroyed == 2, "and only once; nobody is taken out for it")
check(madeAt[1] == zwei, "(82b) he is made for the region the host's FI line names (zwei), not this player's nearest region (lane 83's audit: tradeRouteMerchants 3/4)")
-- a host merchant without a pack animal: the animal that came with the made one goes again
local host5 = { hostB[1], hostB[3], hostB[4], host4[4], { id = 540, sq = 0, mount = 0, x = 700000 } }
fi(host5); fi(host5)
check(#made == 2 and #destroyed == 3 and destroyed[3].currentUnitRole == 15 and not made[2].mountActor.IsValid(), "a made merchant whose host merchant has no pack animal: the animal the game made with him is taken out again")
-- the host's 530 leaves and 550 comes in the same list: the new one is made first, then the old one goes (never
-- more than the surplus), with the animal he was made with
local nd = #destroyed
local host6 = { hostB[1], hostB[3], hostB[4], host5[5], { id = 550, sq = 0, mount = 551, x = 800000 } }
fi(host6); fi(host6)
check(#made == 3 and #destroyed == nd, "one leaves and one comes in the same list: the new one is made at the second list; the old one is not taken out while this copy has no more than the host")
fi(host6)
check(#destroyed == nd + 2 and destroyed[nd + 2] == made[1], "one list later this copy has one more than the host: the old one goes, his pack animal first")
-- lists that must do nothing: an old one, a cut one, a replayed one, one in a world's first 5 s; removal switched off
nd = #destroyed
local host7 = { hostB[1] }
for _ = 1, 3 do fi(host7, { ago = 3.0 }) end
check(#destroyed == nd, "a list written 3 s ago (the host's clock): nothing is done")
for _ = 1, 3 do fi(host7, { n = 5 }) end
check(#destroyed == nd, "a list with fewer entries than the host says it has (a cut list): nothing is done")
S.replay = { n = 0 }; for _ = 1, 3 do fi(host7) end; S.replay = nil
check(#destroyed == nd, "replayed lists (right after a load): nothing is done")
check(C.merch.EARLY == 1.5 and C.merch.early() == 1.5, "(82b) a friend waits 1.5 s into a world (was 5 s; run w15a)")
local wt = S.worldT; S.worldT = T; C.m82wait = 5.0; for _ = 1, 3 do fi(host7) end; S.worldT = wt; C.m82wait = nil
check(#destroyed == nd, "lists in a world's first seconds (Coop.m82wait = 5 here: 2.25 s of lists): nothing is done")
C.m58destroy = false
for _ = 1, 3 do fi(host7) end
check(#destroyed == nd and S.stats.m58extraNow == 4, "Coop.m58destroy = false: nobody is taken out; 4 are counted as paired with none")
C.m58destroy = true
fi(host7)
check(#destroyed > nd and #S.eng.freeMerchants == 1 and S.eng.freeMerchants[1] == saved[1], "switched on again: the 4 go (each with his animal), the host's one stays")
-- the host loads a save (another world number): every pair is found again, nobody goes
nd = #destroyed
for _ = 1, 3 do fi({ { id = 320, sq = 11, x = 100000 } }, { world = 2 }) end
check(#destroyed == nd and #made == 3 and C.merch.pairU.u320 == saved[1], "the host in another world with other ids: paired again (by squad here), nothing made, nothing taken out")
-- a made merchant the game takes away: made once more, then never again
made = {}
local host8 = { { id = 320, sq = 11, x = 100000 }, { id = 560, sq = 0, mount = 561, x = 900000 } }
fi(host8, { world = 2 }); fi(host8, { world = 2 })
local function vanish(u) for _, list in ipairs({ S.eng.freeMerchants, S.eng.unitArr }) do for i = #list, 1, -1 do if list[i] == u then table.remove(list, i) end end end; u.IsValid = function() return false end end
vanish(made[1]); for _ = 1, 3 do fi(host8, { world = 2 }) end
vanish(made[2]); for _ = 1, 8 do fi(host8, { world = 2 }) end
check(#made == 2 and C.merch.failed.u560 == "twice", "a made merchant the game took away twice is not made a third time")

-- ================================================================ D  who stood where at the save
-- Proof run 2, load 3: five merchants the host made after its load walk in a line 18 m apart (no squad on the host).
-- The host saves, the friend loads alone; 2.5 s after the save the host takes the SECOND of the line out. When the
-- friend acts on its first list (5.6 s after its attach) the host's four have walked 85 m on and the friend's five
-- 25 m. By the lists of that moment alone the last of the line is the one left over (the others pair one up). With
-- the host's list of the save's moment (the first replayed list) and this copy's merchants at its world's first tick
-- each is paired with his own, and the second one goes.
local function lineCase(withSave)
  fresh(scripts .. "coop_x_merch.lua")
  C.m58destroy = true
  local body = {}
  for i = 1, 5 do body[i] = add(mk(0x6000 + i * 0x100, 600 + 2 * i, 1523397600 + i, 500000 - i * 1800)); addAnimal(body[i], 0x7000 + i * 0x100, 601 + 2 * i) end
  local saveList = {}
  for i = 1, 5 do saveList[i] = { id = 510 + 2 * i, sq = 0, mount = 511 + 2 * i, x = 500000 - i * 1800 + 300 } end      -- the host 0.6 s after its save: 3 m on
  if withSave then
    S.replay = { n = 0 }; fi(saveList, { ago = 9.0 }); S.replay = nil       -- replayed: kept, not acted on
    merch.tick(S, T)                                                     -- this copy's merchants as its world began
  end
  for i = 1, 5 do body[i].realPos.X = body[i].realPos.X + 2500 end       -- 5 s of this copy's own walking
  local live = {}
  for i = 1, 5 do if i ~= 2 then live[#live + 1] = { id = 510 + 2 * i, sq = 0, mount = 511 + 2 * i, x = 500000 - i * 1800 + 8500 } end end
  for _ = 1, 4 do fi(live) end
  return body
end
local body = lineCase(false)
check(#destroyed == 2 and destroyed[2] == body[5] and #made == 0, "WITHOUT the save's lists: one goes, with his animal, and nothing is made (the counts are right), but it is the LAST of the line, not the one the host took out")
body = lineCase(true)
check(#destroyed == 2 and destroyed[2] == body[2] and destroyed[1] == body[2].mountActor and #made == 0 and C.merch.pairU.u512 == body[1] and C.merch.pairU.u516 == body[3] and C.merch.pairU.u520 == body[5],
      "WITH the host's list of the save's moment: the SECOND of the line goes (the one the host took out), his animal first; each of the others is paired with his own; nothing is made")
-- ================================================================ E  the default (no switch set)
fresh(scripts .. "coop_x_merch.lua")
check(C.m58destroy == nil, "no switch is set (the default)")
do
  local t = {}
  for i = 1, 3 do t[i] = add(mk(0x8000 + i * 0x100, 700 + i, 40 + i, i * 100000)) end
  local hostE = { { id = 701, sq = 41, x = 100000 }, { id = 702, sq = 42, x = 200000 }, { id = 703, sq = 43, x = 300000 } }
  for _ = 1, 4 do fi(hostE) end
  check(#destroyed == 0 and #made == 0, "the default, the same merchants on both copies: nothing made, nothing taken out")
  local hostE2 = { hostE[1], hostE[3] }
  fi(hostE2); fi(hostE2)
  check(#destroyed == 1 and destroyed[1] == t[2], "the default: a merchant the host has no more is taken out at the second list (removal is ON without a switch)")
  C.m58destroy = false
  fi({ hostE[1] }); fi({ hostE[1] }); fi({ hostE[1] })
  check(#destroyed == 1, "Coop.m58destroy = false switches it off")
  C.m58destroy = nil
end
-- ================================================================ F  the host's side: its list line, and its log
-- The host's own FI line (not one written by this test) is read by a friend: the two sides agree on the format.
local hostLine
do
  _G.Coop = nil
  dofile(scripts .. "coop.lua")
  local HC = _G.Coop; HC.linkCut = 0
  HC.patch = { fn = function() end, dir = dir, tick = function() end, send = function() end, status = function() return { items = {}, text = "" } end }
  dofile(scripts .. "coop_x_men.lua"); dofile(scripts .. "coop_x_merch.lua")
  T = T + 20.0
  HC.start("host", "host", { "friend1" })
  local HS = HC.s
  local hm = HC.modules.merch
  hm.onWorld(HS)
  local function hu(addr, id, sq, x, animalId)
    local u = { IsValid = function() return true end, GetAddress = function() return addr end, realPos = { X = x, Y = 2000, Z = 30 }, UniqueID = id, assignedSquadID = { Value = sq }, currentUnitRole = 6,
                Path = {}, PathPoint = 0, getTargetPos = function() return { X = x + 90000, Y = 2000, Z = 30 } end }
    if animalId then u.mountActor = { IsValid = function() return true end, GetAddress = function() return addr + 1 end, UniqueID = animalId, currentUnitRole = 15 } end
    return u
  end
  local a1, a2 = hu(0x100, 701, 41, 100000), hu(0x200, 511, 0, 200000, 512)
  HS.eng = { IsValid = function() return true end, freeMerchants = { a1, a2 }, livestockMerchants = {}, unitArr = { a1, a2 }, buildingArr = {} }
  HS.p1 = { IsValid = function() return true end, GetAddress = function() return 1 end }
  HS.sc = { IsValid = function() return true end }
  local function sent() local fh = io.open(dir .. "host.txt", "rb"); local t = fh and fh:read("a") or ""; if fh then fh:close() end; return t end
  T = T + 1.0; hm.tick(HS, T)
  for l in sent():gmatch("[^" .. string.char(10) .. "]+") do if l:find(" FI ", 1, true) then hostLine = l end end
  local hw = words(hostLine or "")
  check(hostLine ~= nil and hw[3] == "FI" and hw[6] == "2" and hw[7] == "1" and hw[8] == "1" and hw[9] == "701:41:0:100000,2000,30:-;511:0:512:200000,2000,30:-",
        "host: its whole list goes out as one FI line: world, list number, count 2, part 1 of 1, unit id:squad:pack animal:place (" .. tostring(hostLine and hostLine:match("FI .*$")) .. ")")
  HS.eng.freeMerchants[3] = hu(0x300, 530, 0, 300000); table.remove(HS.eng.freeMerchants, 1)
  T = T + 1.0; hm.tick(HS, T)
  local fh = io.open(dir .. "host_log.txt", "rb"); local hl = fh and fh:read("a") or ""; if fh then fh:close() end
  check(hl:find("merchants: this host's list changed: +u530 -u701 (now 2)", 1, true) ~= nil, "host: a merchant that came and one that left are said in its log in one line")
end
fresh(scripts .. "coop_x_merch.lua")
do
  local t1 = add(mk(0x8100, 701, 41, 100000)); local t2 = add(mk(0x8200, 511, 0, 200000)); addAnimal(t2, 0x8300, 512)
  local hw = words(hostLine)
  local function again() T = T + 0.75; hw[2] = string.format("%.3f", C.api.now()); hw[5] = tostring((tonumber(hw[5]) or 0) + 1); merch.onMessage(S, "host", "FI", hw) end
  again(); again()
  check(C.merch.pairU.u701 == t1 and C.merch.pairU.u511 == t2 and C.merch.steady == true and #made == 0 and #destroyed == 0,
        "friend: the host's own line is read: both merchants paired, nothing made, nothing taken out")
end
-- ================================================================ G  the livestock merchant
-- The game as probe P3 showed it: spawnLivestockMerchant makes a man of role 7 on the engine's list; he lives while
-- he has a task (the stand-in below is taken away by "the game" by hand where a case needs it).
local stable = { IsValid = function() return true end, GetAddress = function() return 0xB00 end, GetType = function() return 97 end, K2_GetActorLocation = function() return { X = 93200, Y = 77600, Z = 0 } end }
local lvMade, spawnAt
local function lvFresh()
  fresh(scripts .. "coop_x_merch.lua")
  lvMade, spawnAt = {}, {}
  S.eng.buildingArr = { stable }
  function S.eng:spawnLivestockMerchant(b)
    local u = mk(nextAddr, nextId, 0, 158322, 101389, 7); nextAddr = nextAddr + 0x100; nextId = nextId + 1
    u.Tasks = {}; u.setTask = function(self, rec) self.Tasks = { rec } end
    self.livestockMerchants[#self.livestockMerchants + 1] = u; self.unitArr[#self.unitArr + 1] = u
    lvMade[#lvMade + 1] = u; spawnAt[#spawnAt + 1] = b
    return u
  end
end
local function fv(text, ago) T = T + 0.5; line("FV", text, ago) end
local function gameTakes(u) for _, list in ipairs({ S.eng.livestockMerchants, S.eng.unitArr }) do for i = #list, 1, -1 do if list[i] == u then table.remove(list, i) end end end; u.IsValid = function() return false end end
local walkA = "523:120000,90000,40:93500,77900,10:-130,-60:97,93200,77600:-"       -- the host's merchant: place, way's end, velocity, building, the animal he leads (none)
lvFresh()
fv(walkA); fv(walkA); fv(walkA)
check(#lvMade == 0, "a host livestock merchant this copy lacks: no stand-in in his first 1.5 s (the short-lived ones of an unpaid order get none)")
fv(walkA)
local st = lvMade[1]
check(#lvMade == 1 and spawnAt[1] == stable and st.realPos.X == 120000 and st.realPos.Y == 90000 and st.Tasks[1] and st.Tasks[1].Type == 17 and st.Tasks[1].TargetLocation.Pos.X == 93500
      and st.Tasks[1].targetBuilding == nil and st.Tasks[1].resourceAmt == 0 and #S.eng.livestockMerchants == 1,
      "after 1.5 s: ONE stand-in, made with spawnLivestockMerchant at the building the host names, put where the host's is (82b: no lead), with a walk (type 17, no building, no goods) to the end of the host's way")
local rec0 = st.Tasks[1]
st.realPos.X = 119900; fv("523:119900,90000,40:93500,77900,10:-130,-60:97,93200,77600:-")
check(#lvMade == 1 and st.Tasks[1] == rec0 and st.realPos.X == 119900, "he walks as the host's does: nothing is done to him")
fv("523:119800,90000,40:95000,78000,10:-130,-60:97,93200,77600:-")
check(st.Tasks[1] ~= rec0 and st.Tasks[1].TargetLocation.Pos.X == 95000, "the host's way has another end: the walk is given again, to the new end")
st.realPos.X = 119000; rec0 = st.Tasks[1]
fv("523:119800,90000,40:95000,78000,10:0,0:97,93200,77600:-")
check(st.realPos.X == 119800 and st.Tasks[1] == rec0, "(82c) 8 m off while his way is being found (a walk, no way yet): put at the host's place, his walk kept")
st.Path = { 1, 2 }; st.PathPoint = 0; st.getTargetPos = function() error("no way to read in this test") end      -- (his way has come)
st.realPos.X = 119000; fv("523:119800,90000,40:95000,78000,10:0,0:97,93200,77600:-")
check(st.realPos.X == 119000 and st.Tasks[1] == rec0, "8 m off within 1.5 s after a walk was given, his way found: left alone (the 2.5 s track rule's grace)")
T = T + 2.0
fv("523:119800,90000,40:95000,78000,10:-100,0:97,93200,77600:-")
check(st.realPos.X == 119800 and st.Tasks[1] ~= rec0, "(82b) still 8 m off the host's track, the second line in a row: put where the host's is (no lead); with no way to keep, a walk is given")
T = T + 2.0; st.realPos.Y = 90000 + 800; rec0 = st.Tasks[1]
fv("523:119750,90000,40:95000,78000,10:-100,0:97,93200,77600:-")
check(st.realPos.Y == 90800 and st.Tasks[1] == rec0, "(82b) 8 m beside the host's track: not put at the first line")
fv("523:119700,90000,40:95000,78000,10:-100,0:97,93200,77600:-")
check(st.realPos.X == 119700 and st.realPos.Y == 90000 and st.Tasks[1] ~= rec0, "(82b) at the second line in a row: put")
st.realPos.X = 119750 - 3000; rec0 = st.Tasks[1]
fv("523:119750,90000,40:95000,78000,10:0,0:97,93200,77600:-")
check(st.realPos.X == 119750 and st.Tasks[1] ~= rec0, "30 m off: put at once, also right after a walk")
-- the game takes the stand-in away (he arrived first): made again only after 2.5 s, while the host's still walks
gameTakes(st)
for _ = 1, 5 do fv("523:119800,90000,40:95000,78000,10:0,0:97,93200,77600:-") end
check(#lvMade == 1, "a stand-in the game took away is not made again in the next 2.5 s")
fv("523:119800,90000,40:95000,78000,10:0,0:97,93200,77600:-")
check(#lvMade == 2 and lvMade[2].realPos.X == 119800, "the host's still walks after that: made again")
-- the host's merchant is gone: the stand-in goes within about a second, by the tick (no further line is needed)
local st2 = lvMade[2]
fv("-")
check(st2.IsValid() and #destroyed == 0, "the host's merchant is gone: his stand-in is not taken out by the first line without him")
T = T + 0.6; merch.tick(S, T)
check(not st2.IsValid() and #destroyed == 1 and destroyed[1] == st2 and #S.eng.livestockMerchants == 0, "1 s after the last line that named him: taken out with destroyUnit (by the tick)")
for _ = 1, 6 do T = T + 0.5; merch.tick(S, T) end
check(#destroyed == 1 and #lvMade == 2, "and nothing more is made or taken out")
-- (82c) the host's lines pause (frame gaps on a loaded PC, session l82f): no line for 3 s keeps the stand-in; 5 s without
-- any line takes him out
lvFresh()
for _ = 1, 4 do fv(walkA) end
local st3 = lvMade[1]
for _ = 1, 6 do T = T + 0.5; merch.tick(S, T) end
check(st3 and st3.IsValid() and #destroyed == 0, "(82c) no line of the host's for 3 s (a pause, not a word that he is gone): his stand-in stays")
fv(walkA); check(#lvMade == 1, "(82c) and when the lines come again he is the same stand-in (none made again)")
for _ = 1, 11 do T = T + 0.5; merch.tick(S, T) end
check(not st3.IsValid(), "(82c) no line at all for 5 s: taken out")
-- (82c) session l82g: the game takes a stand-in off its livestock merchant list while his handle stays valid: he is
-- gone (taken out of the unit list too), and a new one is made 2.5 s later
lvFresh()
for _ = 1, 4 do fv(walkA) end
local st4 = lvMade[1]
for i = #S.eng.livestockMerchants, 1, -1 do if S.eng.livestockMerchants[i] == st4 then table.remove(S.eng.livestockMerchants, i) end end
fv(walkA)
check(not st4.IsValid() and destroyed[#destroyed] == st4 and #lvMade == 1, "(82c) a stand-in off the engine's list (handle still valid): taken as gone, out of the unit list")
for _ = 1, 6 do fv(walkA) end
check(#lvMade == 2 and lvMade[2].IsValid(), "(82c) and made again after 2.5 s while the host's still walks")
-- lines that must do nothing
lvFresh()
S.replay = { n = 0 }; for _ = 1, 6 do fv(walkA) end; S.replay = nil
check(#lvMade == 0, "replayed lines: no stand-in")
local wt = S.worldT; S.worldT = T; for _ = 1, 2 do fv(walkA) end; S.worldT = wt
check(#lvMade == 0, "lines in a world's first 1.5 s: no stand-in")
C.m73lvspawn = false; for _ = 1, 6 do fv(walkA) end; C.m73lvspawn = nil
check(#lvMade == 0, "Coop.m73lvspawn = false: no stand-in")
-- a carried order: this copy's game made its own merchant; he is the host's, keeps his own task, and is only put
lvFresh()
local own = mk(0x7700, 523, 0, 121000, 90000, 7); own.Tasks = { { Type = 61 } }; own.setTask = function(self, rec) self.Tasks = { rec } end
S.eng.livestockMerchants[1] = own; S.eng.unitArr[#S.eng.unitArr + 1] = own
for _ = 1, 6 do fv(walkA) end
check(#lvMade == 0 and C.merch.lv["523"] and C.merch.lv["523"].u == own and own.Tasks[1].Type == 61 and own.realPos.X == 120000,
      "a carried order: this copy's own merchant (10 m from the host's) is the host's: no stand-in, his own task kept, put where the host's is")
fv("-"); for _ = 1, 8 do T = T + 0.5; merch.tick(S, T) end
check(own.IsValid() and #destroyed == 0, "the host's has arrived and is gone: this copy's own is left to his own game (4 s later he is still there)")
for _ = 1, 9 do fv("-"); fv("-"); T = T + 1.0; merch.tick(S, T) end
check(not own.IsValid() and #destroyed == 1, "still there over 10 s after the host's went, with the host saying it has none: taken out")
-- a merchant of this copy alone (no host merchant at all): out after 1.5 s of the host saying none; not when switched off
lvFresh()
local lone = mk(0x7800, 900, 0, 50000, 50000, 7); lone.Tasks = { { Type = 61 } }
S.eng.livestockMerchants[1] = lone; S.eng.unitArr[#S.eng.unitArr + 1] = lone
C.m73lvdestroy = false
for _ = 1, 6 do fv("-") end
check(lone.IsValid(), "Coop.m73lvdestroy = false: a merchant of this copy alone stays")
C.m73lvdestroy = nil
lvFresh()
lone = mk(0x7800, 900, 0, 50000, 50000, 7); lone.Tasks = { { Type = 61 } }
S.eng.livestockMerchants[1] = lone; S.eng.unitArr[#S.eng.unitArr + 1] = lone
fv("-"); check(lone.IsValid(), "a merchant of this copy alone: not taken out at the first line")
for _ = 1, 4 do fv("-") end
check(not lone.IsValid() and destroyed[1] == lone, "after 1.5 s of the host saying it has none: taken out")
-- no word of the host's for 3 s: nothing is judged
lvFresh()
lone = mk(0x7900, 901, 0, 50000, 50000, 7); lone.Tasks = { { Type = 61 } }
S.eng.livestockMerchants[1] = lone; S.eng.unitArr[#S.eng.unitArr + 1] = lone
fv("-"); for _ = 1, 12 do T = T + 0.5; merch.tick(S, T) end
check(not lone.IsValid(), "one line of the host's, then silence: he goes 1.5 s after (the host said it has none)")
lvFresh()
lone = mk(0x7A00, 902, 0, 50000, 50000, 7); lone.Tasks = { { Type = 61 } }
S.eng.livestockMerchants[1] = lone; S.eng.unitArr[#S.eng.unitArr + 1] = lone
for _ = 1, 12 do T = T + 0.5; merch.tick(S, T) end
check(lone.IsValid(), "no line of the host's at all: nobody is taken out")
-- the host's side
do
  _G.Coop = nil
  dofile(scripts .. "coop.lua")
  local HC = _G.Coop; HC.linkCut = 0
  HC.patch = { fn = function() end, dir = dir, tick = function() end, send = function() end, status = function() return { items = {}, text = "" } end }
  dofile(scripts .. "coop_x_men.lua"); dofile(scripts .. "coop_x_merch.lua")
  T = T + 20.0
  HC.start("host", "host", { "friend1" })
  local HS = HC.s; local hm = HC.modules.merch
  hm.onWorld(HS)
  local fhh = io.open(dir .. "host.txt", "wb"); if fhh then fhh:close() end
  local lm = { IsValid = function() return true end, GetAddress = function() return 0x900 end, realPos = { X = 120000, Y = 90000, Z = 40 }, UniqueID = 523, assignedSquadID = { Value = 0 }, currentUnitRole = 7,
               Path = { 1, 2, 3 }, PathPoint = 1, getTargetPos = function() return { X = 93500, Y = 77900, Z = 10 } end, Tasks = { { Type = 61, finalBuilding = stable } } }
  HS.eng = { IsValid = function() return true end, freeMerchants = {}, livestockMerchants = { lm }, unitArr = { lm }, buildingArr = { stable } }
  HS.p1 = { IsValid = function() return true end, GetAddress = function() return 1 end }
  HS.sc = { IsValid = function() return true end }
  local function lines() local fh = io.open(dir .. "host.txt", "rb"); local t = fh and fh:read("a") or ""; if fh then fh:close() end; local l = {}; for x in t:gmatch("[^" .. string.char(10) .. "]+") do if x:find(" FV ", 1, true) then l[#l + 1] = x:match("FV .*$") end end; return l end
  T = T + 1.0; hm.tick(HS, T)
  lm.realPos.X = 119870; lm.realPos.Y = 89940; T = T + 0.5; hm.tick(HS, T)
  local l = lines()
  check(l[1] == "FV 523:120000,90000,40:93500,77900,10:0,0:97,93200,77600:-" and l[2] == "FV 523:119870,89940,40:93500,77900,10:-260,-120:97,93200,77600:-" and lm.PathPoint == 1,
        "host: its livestock merchant goes out every 0.5 s: unit id, place, way's end, velocity, the building his task ends at; his PathPoint is as it was (" .. tostring(l[2]) .. ")")
  HS.eng.livestockMerchants = {}
  T = T + 0.5; hm.tick(HS, T); T = T + 0.5; hm.tick(HS, T); T = T + 0.5; hm.tick(HS, T)
  l = lines()
  check(#l == 3 and l[3] == "FV -", "host: he is gone: said at once, and not again in the next second (then every 2 s)")
  T = T + 1.6; hm.tick(HS, T); l = lines()
  check(#l == 4 and l[4] == "FV -", "host: with none, the line comes every 2 s")
end
-- ================================================================ I  (82b) the stand-in on the host's track, and the animal
do
  local td = C.merch.trackDist
  local trk = { { 100000, 0, 10.0 }, { 99250, 0, 10.5 }, { 98500, 0, 11.0 }, { 97750, 0, 11.5 } }
  check(math.abs(td(trk, 98900, 0, 11.5) - 0) < 1 and math.abs(td(trk, 98900, 300, 11.5) - 300) < 1, "I: trackDist: on the host's way between two lines 0 m; 3 m beside it 3 m")
  check(math.abs(td(trk, 97000, 0, 11.5) - 750) < 1, "I: trackDist: 7.5 m AHEAD of the host's place now is 7.5 m off (a place he has not had)")
  check(td(trk, 100000, 0, 15.0) > 1e8, "I: trackDist: places older than the track's 3.1 s do not count")
end
-- speed 8 (15 m a second): a stand-in 3 m behind the host on his way is where the host was 0.2 s ago: left alone;
-- 6 m behind (a steady lag, lvC1): caught up, his way kept, at most every 3 s
lvFresh()
for _ = 1, 4 do fv("524:150000,90000,40:80000,90000,10:-1500,0:97,93200,77600:-") end
local s8 = lvMade[1]
local P8 = { { 150000, 90000 }, { 140000, 90000 }, { 120000, 90000 }, { 80000, 90000 } }
s8.Path = { 1, 2, 3, 4 }; s8.PathPoint = 1
s8.getTargetPos = function(self) local q = P8[self.PathPoint + 1]; return { X = q[1], Y = q[2], Z = 10 } end
local hx = 150000
local rec8 = s8.Tasks[1]
local puts2 = 0
for _ = 1, 6 do hx = hx - 750; s8.realPos.X = hx + 200; fv(string.format("524:%d,90000,40:80000,90000,10:-1500,0:97,93200,77600:-", hx)); if s8.realPos.X ~= hx + 200 then puts2 = puts2 + 1 end end
check(puts2 == 0 and #lvMade == 1 and s8.Tasks[1] == rec8, "I: speed 8, 2 m behind on the host's way for 3 s of lines: never put, no new walk (82c: the catch-up begins beyond 2.5 m)")
local puts = 0
for _ = 1, 12 do hx = hx - 750; s8.realPos.X = hx + 600; s8.PathPoint = 0; fv(string.format("524:%d,90000,40:80000,90000,10:-1500,0:97,93200,77600:-", hx)); if s8.realPos.X == hx then puts = puts + 1 end end
check(puts == 2 and s8.Tasks[1] == rec8 and s8.PathPoint == 0 or false, "I: 6 m behind on the track for 6 s of lines: caught up twice (two lines, then at most every 3 s), his way kept, no new walk (" .. puts .. " puts)")
hx = hx - 750; s8.realPos.X = hx - 900; s8.PathPoint = 0; fv(string.format("524:%d,90000,40:80000,90000,10:-1500,0:97,93200,77600:-", hx))
check(s8.realPos.X == hx - 900, "I: 9 m AHEAD of the host: not put at the first line")
hx = hx - 750; s8.realPos.X = hx - 900; fv(string.format("524:%d,90000,40:80000,90000,10:-1500,0:97,93200,77600:-", hx))
check(s8.realPos.X == hx and s8.Tasks[1] == rec8 and s8.PathPoint == 2,
      "I: ahead in two lines: put where the host's is, his way KEPT (no new walk), his PathPoint set to the point just ahead of that place (" .. tostring(s8.PathPoint) .. ")")
-- the animal: the host's merchant leads one; this copy's animal made by the facts module IN HIS BUILDING'S REGION, with
-- no home, never one an earlier merchant led, is kept at its place
local regA = { IsValid = function() return true end, GetAddress = function() return 0xAA end }
local regB = { IsValid = function() return true end, GetAddress = function() return 0xBB end }
stable.getRegion = function() return regA end
lvFresh()
local an = mk(0x7D00, 600, 0, 104189, 97373, 15); an.Tasks = {}; an.setTask = function(self, rec) self.Tasks = { rec } end
local other = mk(0x7E00, 601, 0, 104300, 97373, 15); other.Tasks = {}
local elsewhere = mk(0x7F00, 602, 0, 50000, 50000, 15); elsewhere.Tasks = {}
local homed = mk(0x7F80, 603, 0, 104000, 97373, 15); homed.Tasks = {}; homed.animalAssignedTo = stable
S.eng.unitArr[#S.eng.unitArr + 1] = an; S.eng.unitArr[#S.eng.unitArr + 1] = other
C.facts = C.facts or {}; C.facts.made = { { u = other, role = 13, r = regA }, { u = an, role = 15, r = regA }, { u = homed, role = 15, r = regA }, { u = elsewhere, role = 15, r = regB } }
for _ = 1, 5 do fv("525:150000,90000,40:157500,101300,10:-780,0:97,93200,77600:150700,90000,40,15") end
check(lvMade[1] and an.realPos.X == 150700 and an.Tasks[1] and an.Tasks[1].Type == 17 and an.Tasks[1].TargetLocation.Pos.X == 157500 and other.realPos.X == 104300 and elsewhere.realPos.X == 50000 and homed.realPos.X == 104000,
      "I: the host's merchant leads an animal: this copy's animal made by the facts module (role 15, in the region of his building, no home) is put at the host animal's place and given a walk to the end of his way; an animal of another kind, of another region or with a home is not touched")
local recA = an.Tasks[1]
fv("525:149600,90000,40:87800,84300,10:-780,0:97,93200,77600:150300,90000,40,15")
check(an.Tasks[1] ~= recA and an.Tasks[1].TargetLocation.Pos.X == 87800, "I: the host's way has a new end (lvC1: the first end was the trade point, 8 m off): the animal is given a walk to it")
an.realPos.X = 150100; fv("525:149200,90000,40:87800,84300,10:-780,0:97,93200,77600:149900,90000,40,15")
check(an.realPos.X == 150100, "I: the animal walks on the host animal's track (2 m behind it, where it was a moment ago): left alone")
-- (82c) a steady 6 m behind on the track (run lvE1: 12.5 m for the whole walk): caught up, its way kept
local PA = { { 151000, 90000 }, { 149000, 90000 }, { 140000, 90000 } }
an.Path = { 1, 2, 3 }; an.PathPoint = 0; an.getTargetPos = function(self) local q = PA[self.PathPoint + 1]; return { X = q[1], Y = q[2], Z = 10 } end
local recAn = an.Tasks[1]; local hxA, putsA = 149900, 0
for _ = 1, 8 do hxA = hxA - 390; an.realPos.X = hxA + 600; fv(string.format("525:%d,90000,40:87800,84300,10:-780,0:97,93200,77600:%d,90000,40,15", hxA - 700, hxA)); if an.realPos.X == hxA then putsA = putsA + 1 end end
check(putsA >= 2 and putsA <= 4 and an.Tasks[1] == recAn and an.PathPoint == 2, "I: (82c) the animal 6 m behind on its host animal's track: caught up (an animal at most every 1 s: " .. putsA .. " in 4 s), its walk and way kept (PathPoint " .. tostring(an.PathPoint) .. ")")
an.Path = nil; an.getTargetPos = nil
local anX = an.realPos.X
fv("-"); for _ = 1, 4 do T = T + 0.5; merch.tick(S, T) end
check(an.IsValid() and an.realPos.X == anX and not lvMade[1].IsValid(), "I: the host's merchant is gone (delivered): his stand-in goes, the animal stays where it is")
an.realPos.X = 104189
for _ = 1, 5 do fv("527:150000,90000,40:157500,101300,10:-780,0:97,93200,77600:150700,90000,40,15") end
check(an.realPos.X == 104189 and elsewhere.realPos.X == 50000, "I: a second merchant of the same world: the animal the first one led is not taken again (none else fits: nothing is moved)")
lvFresh(); C.m82lvanimal = false; an.realPos.X = 104189; C.facts = C.facts or {}; C.facts.made = { { u = an, role = 15, r = regA } }
for _ = 1, 5 do fv("526:150000,90000,40:87800,84300,10:-780,0:97,93200,77600:150700,90000,40,15") end
check(an.realPos.X == 104189, "I: Coop.m82lvanimal = false: the animal is not touched")
C.m82lvanimal = nil; stable.getRegion = nil
-- (82c) after the delivery: the host names the animal as "A<merchant id>" with its way's end; this copy's animal of that
-- merchant follows it (the merchant gone or not)
lvFresh(); C.facts = C.facts or {}
local an2 = mk(0x7D10, 610, 0, 104189, 97373, 15); an2.Tasks = {}; an2.setTask = function(self, rec) self.Tasks = { rec } end
S.eng.unitArr[#S.eng.unitArr + 1] = an2; stable.getRegion = function() return regA end
C.facts.made = { { u = an2, role = 15, r = regA } }
for _ = 1, 5 do fv("528:150000,90000,40:87800,84300,10:-780,0:97,93200,77600:150700,90000,40,15") end
check(an2.realPos.X == 150700, "I: (82c) the animal is led as before")
fv("-"); for _ = 1, 4 do T = T + 0.5; merch.tick(S, T) end
an2.Tasks = {}
fv("A528:88000,84500,40,15:87000,83000,40")
check(an2.realPos.X == 88000 and an2.Tasks[1] and an2.Tasks[1].TargetLocation.Pos.X == 87000, "I: (82c) the merchant gone, the host names the delivered animal: this copy's is put at its place (15 m off) and walks to the host animal's way's end")
an2.realPos.X = 87900; local recA2 = an2.Tasks[1]
fv("A528:87850,84400,40,15:87000,83000,40")
check(an2.realPos.X == 87900 and an2.Tasks[1] == recA2, "I: (82c) on the host animal's track: left alone, its walk kept")
fv("A528:87700,84300,40,15:86000,82000,40")
check(an2.Tasks[1] ~= recA2 and an2.Tasks[1].TargetLocation.Pos.X == 86000, "I: (82c) the host animal's way has a new end: a new walk to it")
stable.getRegion = nil
-- the host's side: the animal he leads (role 15, first task of type 41, the nearest within 40 m) goes out with him
do
  _G.Coop = nil
  dofile(scripts .. "coop.lua")
  local HC = _G.Coop; HC.linkCut = 0
  HC.patch = { fn = function() end, dir = dir, tick = function() end, send = function() end, status = function() return { items = {}, text = "" } end }
  dofile(scripts .. "coop_x_men.lua"); dofile(scripts .. "coop_x_merch.lua")
  T = T + 20.0
  HC.start("host", "host", { "friend1" })
  local HS = HC.s; local hm = HC.modules.merch
  hm.onWorld(HS)
  local fhh = io.open(dir .. "host.txt", "wb"); if fhh then fhh:close() end
  local lm = { IsValid = function() return true end, GetAddress = function() return 0x900 end, realPos = { X = 150000, Y = 90000, Z = 40 }, UniqueID = 524, assignedSquadID = { Value = 0 }, currentUnitRole = 7,
               Path = { 1, 2, 3 }, PathPoint = 1, getTargetPos = function() return { X = 87800, Y = 84300, Z = 10 } end, Tasks = { { Type = 40 } } }
  local function animal(addr, id, x, ty) return { IsValid = function() return true end, GetAddress = function() return addr end, realPos = { X = x, Y = 90000, Z = 40 }, UniqueID = id, currentUnitRole = 15, Tasks = ty and { { Type = ty } } or {} } end
  local a41 = animal(0x910, 488, 150700, 41); local aIdle = animal(0x920, 489, 150100); local aFar = animal(0x930, 490, 160000, 41)
  HS.eng = { IsValid = function() return true end, freeMerchants = {}, livestockMerchants = { lm }, unitArr = { aIdle, aFar, lm, a41 }, buildingArr = {} }
  HS.p1 = { IsValid = function() return true end, GetAddress = function() return 1 end }
  HS.sc = { IsValid = function() return true end }
  local function lines() local fh = io.open(dir .. "host.txt", "rb"); local t = fh and fh:read("a") or ""; if fh then fh:close() end; local l = {}; for x in t:gmatch("[^" .. string.char(10) .. "]+") do if x:find(" FV ", 1, true) then l[#l + 1] = x:match("FV .*$") end end; return l end
  T = T + 1.0; hm.tick(HS, T)
  local l = lines()
  check(l[1] == "FV 524:150000,90000,40:87800,84300,10:0,0:-:150700,90000,40,15", "I: host: the animal he leads (task 41, within 40 m; not the idle one beside him, not the one 100 m off) is named in his entry (" .. tostring(l[1]) .. ")")
  a41.Tasks = {}; T = T + 0.5; hm.tick(HS, T); l = lines()
  check(l[2] and l[2]:match("^FV 524:[^;]*:%-;A524:150700,90000,40,15:150700,90000,40$") ~= nil, "I: host: the animal has no task of type 41 any more (delivered): not named as led; (82c) named as delivered, A<merchant>, with its way's end (" .. tostring(l[2]) .. ")")
  local nl0 = #l
  for _ = 1, 64 do T = T + 0.5; hm.tick(HS, T) end
  l = lines()
  check(l[#l] and not l[#l]:find("A524", 1, true), "I: host: (82c) a delivered animal that has stood still 30 s is named no more (" .. tostring(l[#l]) .. ")")
  a41.currentUnitRole = 12; a41.Tasks = { { Type = 41 } }; T = T + 2.5; hm.tick(HS, T); l = lines()
  check(l[#l] and l[#l]:sub(-19) == ":150700,90000,40,12", "I: host: an ox (kind 12, a player's order) he leads is named with its kind (" .. tostring(l[#l]) .. ")")
end
-- ================================================================ H  (82b) the minute line compares like with like
-- The session check l82b: the friend's minute line said "livestock merchants 1 / 0 ... DIFFERENT" against the host's
-- count of up to a minute before. Now: this copy's counts of the 3 s from the host's moment.
do
  local fj = C.merch.fnJudge
  local w1 = { t = 100, age = 0.2, h = { [6] = 20, [7] = 1, [15] = 16 }, eq = {}, done = false }
  fj(w1, { [6] = 20, [7] = 0, [15] = 15 }, 100)
  check(not w1.done, "H: the host has a livestock merchant this copy has not yet (his stand-in comes ~2 s later): not judged at the first count")
  fj(w1, { [6] = 20, [7] = 1, [15] = 16 }, 102)
  check(w1.done and w1.verdict == "equal" and w1.c[7] == 1, "H: this copy has him 2 s after the host's moment: equal (inside 3 s)")
  local w2 = { t = 100, age = 0.2, h = { [6] = 20, [7] = 1, [15] = 16 }, eq = {}, done = false }
  for k = 0, 6 do fj(w2, { [6] = 20, [7] = 0, [15] = 16 }, 100 + 0.5 * k) end
  check(w2.done and w2.verdict == "DIFFERENT" and w2.c[7] == 0, "H: still none 3.2 s after the host's moment (3.0 s + the line's 0.2 s): DIFFERENT, with this copy's count")
  local w3 = { t = 100, age = 2.9, h = { [6] = 20, [7] = 0, [15] = 16 }, eq = {}, done = false }
  fj(w3, { [6] = 20, [7] = 1, [15] = 16 }, 100.2)
  check(w3.done and w3.verdict == "DIFFERENT", "H: a line that came 2.9 s late: its window is over 0.1 s after it came")
  local w4 = { t = 100, age = 0, h = { [6] = 20, [7] = 0, [15] = 16 }, eq = {}, done = false }
  fj(w4, { [6] = 19, [7] = 0, [15] = 16 }, 100); fj(w4, { [6] = 20, [7] = 1, [15] = 16 }, 101); fj(w4, { [6] = 20, [7] = 0, [15] = 16 }, 101.5)
  check(w4.done and w4.verdict == "equal", "H: each role equal at some count of the window (not all at the same count): equal")
  -- end to end: the FN line, the tick's counts, the minute line
  lvFresh()
  local m1 = mk(0x7B00, 950, 0, 50000, 50000, 6); S.eng.unitArr[#S.eng.unitArr + 1] = m1
  line("FN", "1 1 0")
  for _ = 1, 3 do T = T + 0.5; merch.tick(S, T) end
  local lv7 = mk(0x7C00, 951, 0, 50000, 50000, 7); lv7.Tasks = { { Type = 17 } }; S.eng.unitArr[#S.eng.unitArr + 1] = lv7
  for _ = 1, 3 do T = T + 0.5; merch.tick(S, T) end
  check(C.merch.fnLast and C.merch.fnLast.verdict == "equal", "H: in the game's flow (FN line, then the tick's counts): equal when this copy has him 1.5 s later")
  C.merch.sayT = -1e9; T = T + 0.5; merch.tick(S, T)
  local lf2 = io.open(dir .. "friend1_log.txt", "rb"); local lg2 = lf2 and lf2:read("a") or ""; if lf2 then lf2:close() end
  local ml = lg2:match("merchants: units here / on the host %(the host's count of [^\n]*") or ""
  check(ml:find("livestock merchants 1 / 1", 1, true) ~= nil and ml:find(": equal;", 1, true) ~= nil, "H: the minute line names the counts of the window and says equal (" .. ml:sub(1, 160) .. ")")
end
local lf = io.open(dir .. "friend1_log.txt", "rb"); local lg = lf and lf:read("a") or ""; if lf then lf:close() end
check(lg:find("the host's merchant u530 had none here (3 here, 4 on the host): made one with spawnFreeMerchant at region zwei (unit id", 1, true) ~= nil
      and lg:find("is paired with none of the host's 3 merchants and this copy has 4: taken out with destroyUnit: ok; his pack animal (unit id 400) taken out first", 1, true) ~= nil
      and lg:find("for the host's u560 was taken away by the game twice: not made again", 1, true) ~= nil
      and lg:find("every merchant of this copy is paired with one of the host's", 1, true) ~= nil,
      "the log names every made and every removed merchant by unit id, with both counts")
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
