-- Desk test of the camp try's left-over squad (lane 90, coop_x_events.lua E.campAt / campLeftover). No game runs.
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane90/t90_camp.lua mod/ManorLordsCoop/Scripts/coop_x_events.lua
-- What it shows: when the game's spawnBanditCamp makes its squad but the camp is not in the building list (l83r7c
-- day 361), the one new squad of that try is asked away at once and marked as made here; nothing is asked away when
-- the list could not be read before the try, when two squads are new, when the new squad is tied to a host number,
-- or with the item off; a camp that is found keeps the path of before.
math.tointeger = math.tointeger or function(x) if type(x) == "number" and x == math.floor(x) then return x end end
table.unpack = table.unpack or unpack
local NOW = 1000.0
os.clock = function() return NOW end
local ADDR = 0x40000
local function obj(t) ADDR = ADDR + 16; t.__a = ADDR; t.__valid = true; t.GetAddress = function(self) return self.__a end; return t end
_G.FName = function(s) return s end
_G.FindAllOf = function() return {} end
local LOG = {}
_G.Coop = { register = function() end,
  api = { un = function(x) return x end, valid = function(o) return type(o) == "table" and o.__valid == true end,
          log = function(fmt, ...) LOG[#LOG + 1] = string.format(fmt, ...) end, send = function() end,
          isPaused = function() return false end, btype = function(b) return b.type or 0 end, pawns = function() return {} end } }
assert(loadfile(ARG1))()
local E = _G.Coop.events
assert(type(E.campAt) == "function", "E.campAt is not there")
local pass = 0
local function ok(cond, what) assert(cond, what); pass = pass + 1; print("PASS " .. what) end

local nextH, squads, asked = 600, {}, {}
local function world(o)
  o = o or {}
  squads, asked = {}, {}
  local bandit = obj({ isBandit = true, commandedSquads = { { Value = 501 } } })
  local S = { role = "friend", worlds = 1, stats = {}, l2h = {}, h2l = {} }
  S.p1 = obj({})
  S.sc = obj({ IsValidSquad = function(_, k) return squads[k.Value] ~= nil end, GetSquad = function(_, k) return squads[k.Value] end,
               RequestRemoveSquad = function(_, k) asked[#asked + 1] = k.Value end })
  squads[501] = { unitArr = {} }
  local list = bandit.commandedSquads
  if o.unreadable then         -- the lord's list cannot be read before the try (it can after it)
    bandit.commandedSquads = nil
    setmetatable(bandit, { __index = function(_, k) if k == "commandedSquads" then error("read failed") end end })
  end
  S.eng = obj({ buildingArr = {}, spawnBanditCamp = function(self)
    if o.unreadable then setmetatable(bandit, nil); bandit.commandedSquads = list end
    for _ = 1, (o.squads or 1) do nextH = nextH + 1; squads[nextH] = { unitArr = {}, WeightedCenter = { X = 0, Y = 0 } }; bandit.commandedSquads[#bandit.commandedSquads + 1] = { Value = nextH } end
    if o.tie then S.l2h[nextH] = 77 end
    if o.camp then
      local camp = obj({ type = 100, ownerPawn = bandit, GetType = function(c) return c.type end, K2_GetActorLocation = function() return { X = 1000, Y = 2000, Z = 0 } end, K2_SetActorLocation = function() end })
      self.buildingArr[#self.buildingArr + 1] = camp
    end
  end })
  return S, bandit
end
local function try(o)
  local S, bandit = world(o)
  E.campAsked = E.campAsked or {}      -- (the module sets it up with its camp state)
  if o and o.offSwitch then E.on.campLeftover = false end
  local h, why = E.campAt(S, 1000, 2000, 0, 1000, 2000, 0, bandit)
  E.on.campLeftover = true
  return h, tostring(why), S
end

-- 1. the l83r7c case: a squad and no camp
local h, why, S = try({})
ok(h == nil and #asked == 1 and asked[1] == nextH and S.madeHere and S.madeHere[nextH] and S.rmDone[nextH],
   "no camp after the try: its one new squad is asked away at once and marked made here (" .. why .. ")")
ok(squads[501] and asked[1] ~= 501, "an older squad of the bandit lord is never asked away")
-- 2. two new squads: none
h, why = try({ squads = 2 })
ok(h == nil and #asked == 0 and why:find("none asked away", 1, true), "two new squads after the try: none asked away (" .. why .. ")")
-- 3. tied to a host number
h, why = try({ tie = true })
ok(h == nil and #asked == 0, "a new squad tied to a host number is not asked away (" .. why .. ")")
-- 4. the list could not be read before the try
h, why = try({ unreadable = true })
ok(h == nil and #asked == 0 and why:find("not read before", 1, true), "the list unreadable before the try: nothing asked away (" .. why .. ")")
-- 5. the item off
h, why = try({ offSwitch = true })
ok(h == nil and #asked == 0 and why:find("campLeftover is off", 1, true), "item campLeftover off: the squad is left (" .. why .. ")")
-- 6. a camp that is found: the path of before, its squad becomes the host's squad
h, why = try({ camp = true })
ok(h == nextH and #asked == 0 and why:find("camp made at", 1, true), "a camp that is found keeps the path of before (" .. why .. ")")

print(string.format("RESULT: %d passed, 0 failed", pass))
