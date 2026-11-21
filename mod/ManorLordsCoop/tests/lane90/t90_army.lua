-- Desk test of the army row in the timing proof (lane 90, coop_world.lua proofStock and W.proofQ). TEST TOOL only.
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane90/t90_army.lua mod/ManorLordsCoop/Scripts/coop_world.lua
-- A made-up world: our lord, a rival lord (A1) whose squads come and go, the squad table and the clock are the test's.
-- What it shows:
--   1. the army row Q is read by the stock pass every 0.2 s while a round is slow (without the pass: over 0.6 s apart,
--      the reason two of the lead's three readings were "undecided");
--   2. W.proofQ dates the army in the tick the host's squads changed: a squad the host had for 0.1 s is in the kept
--      reads, and an open watch is told at once;
--   3. the r27int13 day 416 case (a rival army disbanded on the host, the friend 0.6 s behind) is judged settled with
--      the stock pass, and "undecided" without it, as in the lead's run.
local t, rows, sent, mod = 0, {}, {}, nil
os.clock = function() return t end
math.type = math.type or function(n) return n == math.floor(n) and "integer" or "float" end
local function live(o) return type(o) == "table" and o.live == true end
local pawnList = {}
Coop = {
  register = function(_, m) mod = m end, stale = function() return false end,
  api = { valid = live, un = function(o) return o end, now = os.clock, btype = function(b) return b.type end,
    pawns = function() return pawnList end,
    log = function(fmt, ...) rows[#rows + 1] = string.format(fmt, ...) end,
    send = function(line) sent[#sent + 1] = line end }
}
assert(loadfile(ARG1))()
local check
for i = 1, 60 do
  local name, v = debug.getupvalue(mod.onMessage, i)
  if name == "Check" then check = v; break end
end
assert(check and check.proofTick and check.section, "the proof is not in the module")
local pass = 0
local function ok(cond, what) assert(cond, what); pass = pass + 1; print("PASS " .. what) end

local nextAddr = 0x30000
local function obj(o) nextAddr = nextAddr + 16; local a = nextAddr; o.live = true; o.GetAddress = function() return a end; return o end
local lord = obj({ silver = 100, influence = 5, kingsFavour = 0, commandedSquads = {} })
local rival = obj({ commandedSquads = {}, isBandit = false, getPawnSetupIndex = function() return 1 end })
pawnList = { lord, rival }
local squads = {}
local sc = obj({})
function sc:IsValidSquad(k) return squads[k.Value] ~= nil end
function sc:GetSquad(k) return squads[k.Value] end
function sc:GetUnitCount(k) return squads[k.Value].n end
local function addSquad(h, n) squads[h] = { n = n, Control = 0 }; rival.commandedSquads[#rival.commandedSquads + 1] = { Value = h } end
local function dropSquad(h)
  squads[h] = nil
  local keep = {}; for _, e in ipairs(rival.commandedSquads) do if e.Value ~= h then keep[#keep + 1] = e end end
  rival.commandedSquads = keep
end
local store = obj({ type = 6, ownerPawn = lord, lv = 1, onFire = false, sleep = false, Inventory = {}, workers = 1,
  numStoredGeneric = 0, numStoredLarge = 0, numStoredPantry = 0, animals = {}, animalsOnPasture = {}, oxen = {}, activeOxen = 0, Carts = {},
  K2_GetActorLocation = function() return { X = 1000, Y = 2000, Z = 0 } end, GetType = function(self) return self.type end,
  IsConstructed = function() return true end, getNumActiveWorkerFamilies = function(self) return self.workers end,
  getNumResidingFamilies = function() return 0 end })
local region = obj({ ownerPawn = lord, regionUniqueTag = { ToString = function() return "hof" end }, workerFamilies = {},
  regionalWealth = 253, Approval = 50, publicOrder = 60, settlementLevel = 1, residents = {}, corpses = {}, squadsPresent = {},
  getNumHomelessFamilies = function() return 0 end, getNumTotalPopulation = function() return 2 end, getNumFamiliesOfLv = function() return 0 end,
  getStockOfGood = function() return 0 end })
local weather = obj({ Season = 1, month = 3, rainMeter = 0, isDrought = false, isWinter = false, daysWithoutRainVariation = 0 })
local S = { role = "host", worlds = 0, stats = {}, p1 = lord, sc = sc,
  eng = obj({ TemporalComponent = weather, freeMerchants = {}, livestockMerchants = {}, tradeableGoods = { 16 },
    regions = { region }, buildingArr = { store } }) }
local W = Coop.world

local function start(role, stockEvery, t0)
  S.worlds = S.worlds + 1; S.role = role; rows, sent = {}, {}; t = t0
  squads = {}; rival.commandedSquads = {}; S.mir = {}
  W.prepare(S); W.me = lord.GetAddress(); W.day = 41
  W.cfg.proof = true; W.cfg.proofMs = 0                  -- one step a tick: a slow round, as on a loaded copy
  W.cfg.proofStockEvery = stockEvery
end
local function gaps(name, from, to)
  local h = W.wd.proof.hist[name]; local worst, prev = 0, nil
  for i = h.i, h.n do local x = h.t[i]; if x >= from and x <= to then if prev and x - prev > worst then worst = x - prev end; prev = x end end
  return worst
end

-- 1. the stock pass reads the army row every 0.2 s while the rounds are slow
local function slow(stockEvery)
  start("host", stockEvery, 300)
  addSquad(11, 36)
  for i = 1, 60 do t = 300 + i * 0.15; check.tick(S) end
  return gaps("Q", 301, 309), W.wd.proof.stat.maxCycle or 0
end
local on, roundOn = slow(0.2)
local off = slow(0)
ok(roundOn > 0.6 and on <= 0.31 and off > 0.6, string.format("a round of %.2f s: the army row is read every %.2f s with the stock pass (without it %.2f s apart)", roundOn, on, off))
local h = W.wd.proof.hist.Q
ok(h.v[h.n] == "A1=36", "the army row names the rival lord's soldiers (" .. tostring(h.v[h.n]) .. ")")

-- 2. a squad the host had for 0.1 s: dated by the notes of its N and G ticks; an open watch is told at once
start("host", 0.2, 400)
for i = 1, 20 do t = 400 + i * 0.05; check.tick(S) end
mod.onMessage(S, "friend1", "W", { "1", tostring(t), "W", "WATCH", "41", "Q~A1~value" })
check.tick(S)
local n0 = #sent
t = t + 0.03; addSquad(21, 18); ok(W.proofQ("new 21") == true, "the note of the announcement is taken")
local tNew = t
t = t + 0.10; dropSquad(21); W.proofQ("gone 21")
local tGone = t
h = W.wd.proof.hist.Q
local saw18 = false; for i = h.i, h.n do if h.v[i] == "A1=18" and h.t[i] == tNew then saw18 = true end end
ok(saw18 and h.v[h.n] == "" and h.t[h.n] == tGone, "a squad the host had for 0.1 s is in the kept reads at its own moments")
local told = {}
for i = n0 + 1, #sent do local stamp, items = sent[i]:match("^W OBS (%S+) (.+)$"); if stamp then told[#told + 1] = items .. "@" .. stamp end end
ok(#told == 2 and told[1]:find("=18@", 1, true) and told[2]:find("=0@", 1, true), "the open watch is told 18 and then 0 at once (" .. table.concat(told, " ") .. ")")
local logged = table.concat(rows, "\n")
ok(logged:find("army note at", 1, true) and logged:find("(new 21): A1=18", 1, true) and logged:find("(gone 21): none", 1, true), "the host's log names the note and its count")
W.cfg.proof = false
ok(W.proofQ("off") == false, "with the proof off the note does nothing")

-- 3. the r27int13 day 416 case on a friend: the host disbanded 88 men between -0.53 s and -0.17 s (against the
-- friend's sample); the friend took its squads away 0.6 s after its sample; the day's comparison was made 1.8 s after
-- the sample. Host reads as the lead's log has them (W OBS lines of the host's kept reads).
local hostMs = { -2707, -2305, -1811, -1386, -975, -529, -173, 196, 582, 1008, 1338, 1660, 1861, 2138, 2326, 2558, 2793, 3003, 3224, 3391 }
local function friendCase(stockEvery)
  start("friend", stockEvery, 750)
  addSquad(31, 36); addSquad(32, 36); addSquad(33, 16)        -- 88 men of the rival lord here
  mod.onMessage(S, "host", "W", { "1", "740.0", "W", "PROOF", "740.000" })
  local at = 755.335
  for i = 1, 200 do
    t = 750 + i * 0.15 * (5.335 / 30); if t > at then break end; check.tick(S)
  end
  t = at; check.tick(S)
  local lines = {}
  for _, ms in ipairs(hostMs) do local x = at + ms / 1000; lines[#lines + 1] = { x, ms <= -529 and "88" or "0" } end
  -- the friend runs on: its squads go at +0.6 s; the comparison (and the watch) comes at +1.8 s
  local cmp = at + 1.8
  while t < cmp do
    t = t + 0.15
    if t >= at + 0.6 and squads[31] then dropSquad(31); dropSquad(32); dropSquad(33) end
    check.tick(S)
  end
  check.section("416", "Q", { { k = "A1", f = "value", at = at, h = "0", m = "88" } })
  for _, r in ipairs(lines) do
    local stamp = string.format("%.3f", r[1])
    mod.onMessage(S, "host", "W", { "1", stamp, "W", "OBS", stamp, "Q~A1~value=" .. r[2] })
  end
  for _ = 1, 40 do t = t + 0.15; check.tick(S) end
  local all = table.concat(rows, "\n")
  local verdict = all:match("settle 416 Q sample=%d+ settled[^\n]*") or "no verdict"
  local field = all:match("settle%-field 416 Q A1 value [^\n]*") or ""
  return verdict .. " | " .. (field:match("friendMs=[^ ]*") or "")
end
local withPass = friendCase(0.2)
ok(withPass:find("settled=1 past3=0 foreign=0 stale=0 unverified=0", 1, true), "the r27int13 disband with the army row in the stock pass: " .. withPass)
local without = friendCase(0)
ok(without:find("unverified=1", 1, true), "without it, as in the lead's run: " .. without)

print(string.format("RESULT: %d passed, 0 failed", pass))
