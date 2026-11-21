-- Desk test of lane 88's board fix (coop_x_jobs.lua here(); the l88o crash): a destroyed actor never reaches setTask.
-- Run: py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane88/t_board_dead.lua mod/ManorLordsCoop/Scripts/coop_x_jobs.lua
-- Lane 88's probe p88a: IsActorBeingDestroyed() answered false for every destroyed felled tree; the reflected field
-- bActorIsBeingDestroyed told all of them apart. here() must read the field.
local pass = 0
local function ok(c, what) assert(c, "FAIL " .. what); pass = pass + 1; print("PASS " .. what) end
if not math.tointeger then math.tointeger = function(x) x = tonumber(x); if x and x == math.floor(x) then return x end; return nil end end
table.unpack = table.unpack or unpack
_G.FindAllOf = function() return {} end; _G.RegisterHook = function() end; _G.FName = function(s) return { ToString = function() return s end } end
local mod
local function valid(o) return type(o) == "table" and o._valid == true end
Coop = { s = { role = "friend", worlds = 1 }, api = { valid = valid, un = function(o) return o end, log = function() end, send = function() end, now = os.clock,
  btype = function() return 0 end, pawns = function() return {} end }, register = function(n, m) mod = m end, stale = function() return false end }
assert(loadfile(ARG1))()
local function upvalue(fn, name, seen)
  seen = seen or {}; if seen[fn] then return end; seen[fn] = true
  for i = 1, 300 do local n, v = debug.getupvalue(fn, i); if not n then break end; if n == name then return v end end
  for i = 1, 300 do local n, v = debug.getupvalue(fn, i); if not n then break end; if type(v) == "function" then local r = upvalue(v, name, seen); if r then return r end end end
end
local here = assert(upvalue(mod.onMessage, "here") or upvalue(mod.tick, "here"), "here() not found")
local function tree(destroyed) return { _valid = true, bActorIsBeingDestroyed = destroyed, IsActorBeingDestroyed = function() return false end } end
ok(here(tree(false)) == true, "a felled tree in the game is there")
ok(here(tree(true)) == false, "a destroyed felled tree (the call says false, the field true) is not there: never given to setTask")
print(string.format("ALL %d PASS", pass))
