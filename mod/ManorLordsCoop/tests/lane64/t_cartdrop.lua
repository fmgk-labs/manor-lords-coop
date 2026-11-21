-- Desk test (lane 64, task 64d; lane 74's question): a hidden cart of a friend that the native look calls freed.
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane64/t_cartdrop.lua mod/ManorLordsCoop/Scripts
-- The scene module hides a friend's own cart where a host cart is drawn on its stand (its actor and the meshes it hid,
-- coop_x_scene.lua setOwnShown). A cart the native look calls freed is dropped (cartFreed). Were that answer ever
-- wrong for a LIVING cart, the cart would stay hidden until the next load. So before such a drop the cart is looked
-- for in the game's own list of handcarts (FindAllOf, by address): found = shown again (its actor and exactly the
-- meshes this module hid, by their addresses); not found = gone, nothing touched.
local scripts = assert(ARG1)
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local serial = 0
local function object(t)
  serial = serial + 1; t = t or {}; t.addr = serial
  local function touch(self) if self.freed then error("a freed object was touched") end end
  function t:GetAddress() return self.addr end
  function t:IsValid() touch(self); return not self.gone end
  function t:IsActorBeingDestroyed() touch(self); return false end
  return t
end
local function valid(o) return type(o) == "table" and o.addr ~= nil and not o.freed and o:IsValid() end
local MESHCLS = object()
local all = {}
-- a cart: its root mesh (hidden in game by the game itself) and two meshes the module may hide
local function cart()
  local c = object({ hidden = false })
  local function mesh(hidden)
    local m = object({ bHiddenInGame = hidden })
    function m:SetHiddenInGame(h) if c.freed then error("a freed cart's mesh was touched") end; self.bHiddenInGame = h end
    function m:get() return self end
    return m
  end
  c.root, c.body, c.wheels = mesh(true), mesh(false), mesh(false)
  c.RootComponent = c.root
  function c:SetActorHiddenInGame(h) if self.freed then error("a freed cart was touched") end; self.hidden = h end
  function c:K2_GetComponentsByClass() if self.freed then error("a freed cart was touched") end; return { self.root, self.body, self.wheels } end
  c.bHidden = false
  all[#all + 1] = c
  return c
end
FindAllOf = function(cls) if cls ~= "Resource_Handcart_C" then return {} end; local r = {}; for _, c in ipairs(all) do if not c.freed then r[#r + 1] = c end end; return r end
StaticFindObject = function() return MESHCLS end
NotifyOnNewObject = function() end
local M = {}
Coop = { api = { un = function(x) return x end, valid = valid, log = function() end, send = function() end, now = os.clock, btype = function() return 72 end },
  s = { role = "friend", worlds = 1 }, register = function(k, m) M[k] = m end }
dofile(scripts .. "/coop_x_scene.lua")
local Q = Coop.scene
M.scene.onWorld(Coop.s)
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 250 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name and v ~= nil then return v end end
  for i = 1, 250 do
    local n, v = debug.getupvalue(fn, i); if not n then break end
    if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end
  end
end
local setOwnShown = assert(upvalue(M.scene.tick, "setOwnShown"), "setOwnShown not found")
local showIfAlive = assert(upvalue(M.scene.tick, "showIfAlive"), "showIfAlive not found")
local dropCart = assert(upvalue(M.scene.tick, "dropCart"), "dropCart not found")
-- 1. a live cart hidden by the module
local c = cart(); local a = c:GetAddress(); Q.carts[a] = c
setOwnShown(a, c, false)
check(c.hidden == true and c.body.bHiddenInGame and c.wheels.bHiddenInGame and #(Q.compHidA[a] or {}) == 2, "the module hides its cart: the actor and the two meshes it hid, kept by address (2)")
-- the native look calls it freed although it lives (the case never seen, lane 74's question)
local r = showIfAlive(a); dropCart(a)
check(r == true and c.hidden == false and not c.body.bHiddenInGame and not c.wheels.bHiddenInGame, "a wrong 'freed' answer for a living hidden cart: shown again before the drop (actor and both meshes)")
check(c.root.bHiddenInGame == true, "the root mesh the game itself hides stays hidden")
check((Q.stats.cartFreedShown or 0) == 1 and Q.compHidA[a] == nil and Q.carts[a] == nil, "counted (cartFreedShown 1); the cart is dropped as before")
-- 2. a hidden cart that is really freed: nothing is touched
local f = cart(); local fa = f:GetAddress(); Q.carts[fa] = f
setOwnShown(fa, f, false)
f.freed = true
local ok, r2 = pcall(showIfAlive, fa); dropCart(fa)
check(ok and r2 == false and (Q.stats.cartFreedGone or 0) == 1, "a hidden cart that is really freed: not in the game's list, nothing touched (" .. tostring(ok and r2 or r2) .. ")")
-- 3. a new cart has taken the address of a freed hidden one: its meshes are other objects, left as the game made them
local old = cart(); local oa = old:GetAddress(); Q.carts[oa] = old
setOwnShown(oa, old, false)
old.freed = true
local new = cart(); new.addr = oa; new.body.bHiddenInGame = true          -- a mesh of the new cart the game itself keeps hidden
ok, r2 = pcall(showIfAlive, oa); dropCart(oa)
check(ok and r2 == true and new.body.bHiddenInGame == true, "a new cart at a freed one's address: none of its own meshes is shown (they are not the ones this module hid)")
-- 4. a cart the module never hid: no look at all
local s = cart(); local sa = s:GetAddress(); Q.carts[sa] = s
local before = Q.stats.cartFreedShown or 0
r = showIfAlive(sa); dropCart(sa)
check(r == nil and (Q.stats.cartFreedShown or 0) == before, "a cart this module never hid: no search, nothing to show")
-- 5. shown again the normal way: the address list goes with the handles
local n2 = cart(); local na = n2:GetAddress(); Q.carts[na] = n2
setOwnShown(na, n2, false); setOwnShown(na, n2, true)
check(n2.hidden == false and not n2.body.bHiddenInGame and Q.compHidA[na] == nil, "shown again by the module itself: the actor and meshes shown, the address list cleared")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
return fail == 0
