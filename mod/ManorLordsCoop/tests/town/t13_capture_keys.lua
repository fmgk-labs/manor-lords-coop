-- Desk regression. The game can clear a building before IsValid turns false.
local messages, logs = {}, {}
local function valid(o) return o and o.alive == true end
local lord = { alive = true, GetAddress = function() return 1 end, demolishRequests = {} }
local S = { role = "host", name = "host", on = true, p1 = lord, stats = {} }
Coop = { s = S, register = function() end, api = {
  valid = valid, un = function(o) return o end, btype = function(b) return b.Data.bType end,
  log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end,
  send = function(line) messages[#messages + 1] = line end
} }
math.tointeger = math.tointeger or function(v) if math.floor(v) == v then return v end end
local function param(v) return { get = function() return v end } end
local function building(t, addr)
  local b = { alive = true, Data = { bType = t }, ownerPawn = lord,
    RootComponent = { alive = true, RelativeLocation = {X = 120, Y = -40, Z = 8}, RelativeRotation = {Yaw = 30} } }
  function b:GetAddress() return addr end
  function b:GetFName() return { ToString = function() return "Building" .. addr end } end
  function b:K2_GetActorLocation() return self.RootComponent.RelativeLocation end
  function b:K2_GetActorRotation() return self.RootComponent.RelativeRotation end
  return b
end
local function clear(b)
  b.Data.bType = 0
  b.RootComponent.RelativeLocation = {X = 0, Y = 0, Z = 0}
  b.ownerPawn = nil
end
assert(loadfile(ARG1))()
local T, P = Coop.town, Coop.town.api.P
T.test.pump()
local function expect(action, fields)
  T.test.pump()
  local line = table.remove(messages, 1) or "(missing)"
  assert(line:match("^T host %d+ (.*)$") == action .. " " .. fields, action .. " sent " .. line)
  assert(#messages == 0, "unexpected duplicate")
end
local stable = building(97, 10)
T.addB(stable)
lord.demolishRequests = {stable}
T.onHook(P .. "PawnCPP:deselectBuilding", param(lord), param(stable))
clear(stable)
expect("DEMOLISH", "97,120,-40,8")
assert(not T.addB(stable) and T.bidx[10].t == 97, "cleared actor poisoned its index")

local b = building(72, 11) -- no scan has run for this building yet
T.onHook(P .. "PawnCPP:addUpgradeRequest", param(lord), param({buildingMaster=b, upgradeID=13, slot=1}))
T.onHook(P .. "SMBuildingMaster:SetTargetStock", param(b), param(17), param(20))
clear(b)
T.test.pump()
assert(#messages == 2 and messages[1]:match(" UPGRADE 72,120,%-40,8 13$") and
  messages[2]:match(" TSTOCK 72,120,%-40,8 17,20$"), "request or setter lost its original target")
messages = {}

local fresh = building(18, 12)
lord.hitBuilding = fresh
T.onHook("/Game/CPP_BP/MyPawnCPP_BP3.MyPawnCPP_BP3_C:playBuildEffects", param(lord))
clear(fresh)
expect("BUILD", "18,120.00,-40.00,8.00,30.0")
local bad = "0,0,0,0"
for _, case in ipairs({
  {"DEMOLISH", bad}, {"BUILD", ""}, {"UPGRADE", "- 5"}, {"FERTILIZE", bad .. " 1"},
  {"REASSIGN", "tag 1 " .. bad}, {"MOVE", "3,0,0,0 " .. bad}, {"FAMS", bad .. " - 0"},
  {"TRAINCON", "112,1,2,3 - " .. bad}, {"PLAN", "100,1,2,3 " .. bad}
}) do
  local before = #logs
  T.emitAction(S, case[1], case[2])
  assert(#messages == 0 and #logs > before, case[1] .. " sent an empty key or dropped it silently")
end
T.finish(S, {origin="friend1", n=7, act="TSTOCK", fields=bad .. " 17,20", t=0}, "ok")
assert(#messages == 0, "host forwarded an empty key")
T.emitAction(S, "TRAINCON", "112,5,0,0 - -")
T.emitAction(S, "TRULE", "tag 17,2")
assert(#messages == 2, "cleared train destinations and region tags must still work")
messages = {}

-- a place of exactly 0,0,0 with a type is a cleared actor's place too (a module that adds the type itself)
for _, case in ipairs({ {"DEMOLISH", "113,0,0,0"}, {"DEMOLISH", "113,-0,0,0"}, {"TRAINCON", "112,5,0,0 ? -"}, {"GATE", "- 5,5 1"} }) do
  local before = #logs
  T.emitAction(S, case[1], case[2])
  assert(#messages == 0 and #logs > before, case[1] .. " " .. case[2] .. " was sent")
end

-- the sequence number goes out as a whole number (the game's Lua prints a float as N.0)
T.emitAction(S, "TRULE", "tag 17,2")
assert(messages[1]:match("^T host %d+ TRULE tag 17,2$"), "sequence number format: " .. messages[1])
T.finish(S, {origin="friend1", n="42465012", act="TSTOCK", fields="97,120,-40,8 17,20", t=0}, "ok")
assert(messages[2] == "T friend1 42465012 TSTOCK 97,120,-40,8 17,20", "relay: " .. tostring(messages[2]))
messages = {}

-- a building whose type changed in place after it was indexed: the line carries the live type, the index's place
local grown = building(3, 20)
T.addB(grown)
grown.Data.bType = 4
T.onHook(P .. "SMBuildingMaster:SetTargetStock", param(grown), param(17), param(20))
clear(grown)
expect("TSTOCK", "4,120,-40,8 17,20")

-- type 75 (changing): the type before the change names it
local changing = building(75, 21); changing.typeBeforeChange = 6
T.onHook(P .. "SMBuildingMaster:SetTargetStock", param(changing), param(17), param(20))
expect("TSTOCK", "6,120,-40,8 17,20")

-- not indexed and attached to a parent: no name in the hook; the tick's live read names it (it was dropped before)
local part = building(30, 22)
part.RootComponent.AttachParent = { alive = true }
T.onHook(P .. "SMBuildingMaster:SetTargetStock", param(part), param(17), param(20))
expect("TSTOCK", "30,120,-40,8 17,20")

-- the same, cleared before the tick: nothing usable anywhere, not sent and said so
local lost = building(30, 23)
lost.RootComponent.AttachParent = { alive = true }
T.onHook(P .. "SMBuildingMaster:SetTargetStock", param(lost), param(17), param(20))
clear(lost)
local before = #logs
T.test.pump()
assert(#messages == 0 and #logs > before and logs[#logs]:match("no usable name"), "a nameless building's line: " .. tostring(messages[1]))

-- the modules' namer (X.bident / X.bkeyOf): live when whole, the index when cleared, "-" when neither
local X = T.api
local known = building(52, 24); T.addB(known)
assert(X.bkeyOf(X.bident(known)) == "52,120,-40,8")
clear(known)
assert(X.bkeyOf(X.bident(known)) == "52,120,-40,8", "cleared, indexed: " .. X.bkeyOf(X.bident(known)))
local unknown = building(52, 25); clear(unknown)
assert(X.bident(unknown) == nil and X.bkeyOf(nil) == "-", "cleared, not indexed")
known.alive = false
assert(X.bident(known) == nil, "a dead object has no name")
print("PASS captured demolition, unindexed upgrade, stock and placement; changed type; tick fallback; empty keys suppressed on origin and relay")
