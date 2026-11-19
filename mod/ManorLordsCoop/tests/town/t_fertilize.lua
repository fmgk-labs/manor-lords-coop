-- Desk check of the field's fertilize setter (lane 75). Run from the repository root.
-- The hook runs before the game's routine: the field still holds its old value. Only a change is a record.
local A = { valid = function(o) return o and o.alive end, log = function() end }
local C = { api = A, register = function() end, s = { on = true } }
_G.Coop = C
local scripts = "mod/ManorLordsCoop/Scripts/"
dofile(scripts .. "coop_town.lua")
dofile(scripts .. "coop_x_town.lua")
local T = C.town
local b = { alive = true, allow = false, GetAddress = function() return 42 end }
function b:GetAllowFertilization() return self.allow end
local function param(v) return { get = function() return v end } end
local set = "/Script/ManorLords.SMBuildingMaster:SetAllowFertilization"
local function call(v) T.onHook(set, param(b), param(v)); b.allow = v end   -- the hook first, then the game's routine

-- the panel repeats the value the field has: never a record (opening a panel, every frame, a hidden panel)
for _ = 1, 50 do call(false) end
assert(#T.q == 0, "the panel repeating the field's own value sent a line")
-- a press: one record per change, in both directions, also right after another one
for _, checked in ipairs({ true, false, true }) do
  call(checked)
  assert(#T.q == 1 and T.q[1].k == "FERTILIZE" and T.q[1].obj == b and T.q[1].args[1] == checked and T.q[1].addr == nil,
    "a press was not captured once")
  T.q = {}
  for _ = 1, 20 do call(checked) end
  assert(#T.q == 0, "the repeat after a press sent a line")
end
-- the panel's own turn-off (no fallow year left): the value changes, so the other copies must hear it, once
call(false)
assert(#T.q == 1 and T.q[1].args[1] == false, "the panel's own turn-off was not sent"); T.q = {}
call(false); assert(#T.q == 0)
-- a replay runs with T.depth raised: not a record, and the repeats after it are silent
T.depth = T.depth + 1; call(true); T.depth = T.depth - 1   -- what T.quiet and the replay do (table.pack is not in Lua 5.1)
assert(#T.q == 0, "a replay was captured")
for _ = 1, 20 do call(true) end
assert(#T.q == 0, "the repeat after a replay sent a line")
-- both panels open after a replay of "on" on a field that may not fertilize: this copy's panel turns it off, once
call(false); assert(#T.q == 1); T.q = {}
for _ = 1, 20 do call(false) end; assert(#T.q == 0)
-- a dead building is never read
b.alive = false
T.onHook(set, param(b), param(true))
assert(#T.q == 0, "a dead building sent a field action")
-- the checkbox handler is not hooked any more (it calls the setter: one record, not two)
local press = T.api.WI .. "W_Inventory_FieldWidget.W_Inventory_FieldWidget_C:" ..
  "BndEvt__W_Inventory_FieldWidget_checkbox_spreadManure_K2Node_ComponentBoundEvent_10_OnValueChange__DelegateSignature"
assert(T.hooks[press] == nil and T.hooks[set] ~= nil, "the checkbox handler is still hooked")
print("PASS: repeats silent (50 + 60 + 40), each change one record (5), replay silent, dead building silent")
