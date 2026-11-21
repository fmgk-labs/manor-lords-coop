-- Desk test (lane 64, round 5): valid() never touches a kept handle whose object is freed.
-- Runs WITHOUT the game (Lua 5.1 or 5.4):
--   py -3 -I research/2026-11-10-game-probe/lanes/lane_s21_64/tools/luarun.py <lua51.dll> mod/ManorLordsCoop/tests/lane64/t_gone.lua <an empty folder to use>
-- It loads the real coop.lua (its valid()) and coop_snap.lua (N.gone, N.goneAlive) with stand-ins. The native piece is
-- a stand-in too: its SNAP PROBE answer (snap_probe.txt) is written from a made-up object array. A made-up object
-- counts every look at it (IsValid) and "ends the game" (an error) when it is looked at after it was freed.
-- What it cannot show: the snapshot reader's own marking of an address (it needs Lua 5.4's string.unpack) and the real
-- native answer. Those are a game run's part.
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane64/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_gone.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end
if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout); local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
_G.COOP_LINK_DIR = dir
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.FindFirstOf = function() return { IsValid = function() return false end } end
_G.Coop = nil
dofile(scripts .. "coop.lua")
local C = _G.Coop
C.start("idle", "idle", {}); C.stop()
local r = dofile(scripts .. "coop_snap.lua")
local N = C.snap
check(type(N) == "table" and type(N.goneAlive) == "function" and C.goneAddr == N.gone, "coop_snap.lua loads (" .. tostring(r) .. "); the core's valid() reads its table of addresses")
local valid = C.api.valid

-- the made-up engine: an object array (address -> alive there), and objects that count looks
local array, probes, sent = {}, 0, {}
local function obj(a)
  local o = { looks = 0, freed = false }
  o.GetAddress = function() return a end                      -- the handle's own number: the object is not touched
  o.IsValid = function() o.looks = o.looks + 1; if o.freed then error("a freed object was touched: the game ends here") end; return true end
  array[a] = true
  return o
end
local function free(o) o.freed = true; array[o.GetAddress()] = nil end
local answer = "array"                                        -- what the made-up native piece answers
C.patch = { fn = true, dir = dir,
  send = function(line) sent[#sent + 1] = line end,
  tick = function()
    local line = sent[#sent]; local list = line and line:match("^SNAP PROBE (.+)$"); if not list then return end
    probes = probes + 1
    local f = assert(io.open(dir .. "snap_probe.txt", "wb"))
    if answer == "refused" then f:write("refused: not the known game build\r\n"); f:close(); return end
    f:write("uoa 00007FF600000000 objects=0000000000001000 max=1 num=1 maxchunks=1 numchunks=1\r\n")
    for tok in list:gmatch("[^,]+") do
      local a = tonumber(tok:sub(3), 16)
      f:write(string.format("%X flags=00000000 idx=7 class=0000000000002000\r\n", a))
      f:write(string.format("   stride 16: obj=0000000000000001 other w8=0 wC=0 w10=0 w14=0\r\n"))
      f:write(string.format("   stride 24: obj=%016X %s w8=0 wC=0 w10=0 w14=0\r\n", array[a] and a or 0, array[a] and "SAME" or "other"))
      f:write(string.format("   stride 32: obj=0000000000000002 other w8=0 wC=0 w10=0 w14=0\r\n"))
    end
    f:close()
  end }
C.s = C.s or {}; C.s.ticks = 100
local function tick() C.s.ticks = C.s.ticks + 1 end
N.state, N.ustate = "ok", "ok"

-- 1. a handle with no entry: as before
local a1 = obj(0x1B000010)
check(valid(a1) == true and a1.looks == 1 and probes == 0, "no entry for the address: IsValid is asked as before, no native look")

-- 2. it left the game's list (the reader's mark) but is not freed yet (destroyed, waiting for the clean-up)
N.gone[0x1B000010] = 0; tick()
check(valid(a1) == true and a1.looks == 2 and probes == 1, "left the list, still in the object array: one native look, then IsValid as before (true)")
check(valid(a1) == true and probes == 1, "asked again in the same tick: no second native look")
tick(); check(valid(a1) == true and probes == 2, "the next tick: looked at again (it can be freed between two ticks)")

-- 3. the engine's clean-up frees it
free(a1); tick(); local looks0 = a1.looks
local ok, v = pcall(valid, a1)
check(ok and v == false and a1.looks == looks0, "freed: valid() says false and the object was NOT touched (" .. (a1.looks - looks0) .. " looks)")
check(N.gone[0x1B000010] == false, "the address is marked freed for good")
local p0 = probes; tick(); tick()
ok, v = pcall(valid, a1)
check(ok and v == false and a1.looks == looks0 and probes == p0, "later ticks: still false, not touched, and no native look is spent on it")

-- 4. a new object gets the same address and comes into the game's list (the reader takes the entry out)
local a2 = obj(0x1B000010); N.gone[0x1B000010] = nil
check(valid(a2) == true and a2.looks == 1, "the address is an object of the list again: its new handle is valid, as before")

-- 5. two open addresses: one native look carries both; the one that is freed is marked without being asked for
local b1, b2 = obj(0x1B000020), obj(0x1B000030)
N.gone[0x1B000020] = 0; N.gone[0x1B000030] = 2; free(b2); tick(); p0 = probes
check(valid(b1) == true and probes == p0 + 1 and N.gone[0x1B000030] == false, "two open addresses in one native look; the freed one is marked at once")
local l2 = b2.looks; ok, v = pcall(valid, b2)
check(ok and v == false and b2.looks == l2 and probes == p0 + 1, "the freed unit's handle: false, not touched, no further look")

-- 6. nothing to rest on: as before (the made-up object is alive here, so "as before" is true)
local c1 = obj(0x1B000040); N.gone[0x1B000040] = 0; tick(); p0 = probes
N.state = "refused"; check(valid(c1) == true and probes == p0, "the building table is not in use: valid() as before, no native look")
N.state = "ok"; answer = "refused"; tick(); check(valid(c1) == true and N.gone[0x1B000040] == 0, "the native piece refuses the look (another game build): valid() as before, nothing marked")
answer = "array"; local P0 = C.patch; C.patch = nil; tick(); check(valid(c1) == true, "no native piece: valid() as before")
C.patch = P0

-- 7. what valid() answered before this guard for a freed object that IsValid lies about: the control
local d1 = obj(0x1B000050); d1.IsValid = function() d1.looks = d1.looks + 1; return true end   -- the lie (1 time in 19 in a game)
free(d1); tick()
check(valid(d1) == true, "control, no entry (an object of no table): the lie goes through, as before this guard")
N.gone[0x1B000050] = 2; tick(); local l1 = d1.looks
check(valid(d1) == false and d1.looks == l1, "with its entry: false, and IsValid is never asked, so it cannot lie")

-- 9. the slot used again: ANOTHER living object sits at the kept handle's address (the made-up native piece says
-- number 7 for every address; the kept object's number was 9)
local e1 = obj(0x1B000060); N.gone[0x1B000060] = 0; N.goneIdx[0x1B000060] = 9; tick(); local le = e1.looks
check(valid(e1) == false and e1.looks == le and N.gone[0x1B000060] == false, "another object at the address (its number differs): false, not touched; before this guard IsValid said true here")
local e2 = obj(0x1B000070); N.gone[0x1B000070] = 2; N.goneIdx[0x1B000070] = 7; tick()
check(valid(e2) == true, "the same object still at the address (its number is the same): IsValid as before (true)")

-- 10. the switches: with the guard off valid() is exactly as before (the lie goes through again)
N.test.goneOff = true; N.gone[0x1B000050] = 2; l1 = d1.looks
check(valid(d1) == true and d1.looks == l1 + 1, "console switch (Coop.snap.test.goneOff): IsValid is asked and its answer taken, as before 0.2.7")
N.test.goneOff = nil; N.goneOn = false
check(valid(d1) == true, "the player's switch (keptguard = off in coop.cfg): the same")
N.goneOn = nil; C.patch.cfgGet = function(k) return k == "keptguard" and "OFF" or nil end
check(valid(d1) == true and N.goneOn == false, "coop.cfg is read once: keptguard = off switches the guard off")
C.patch.cfgGet = function() return nil end; N.goneOn = nil; tick()
check(valid(d1) == false and N.goneOn == true, "no such line in coop.cfg: the guard is on")

-- 11. no native answer is said once in the log (the fall-back to the old answer)
local said = 0; local log0 = C.api.log
local f1 = obj(0x1B000080); N.gone[0x1B000080] = 0; answer = "refused"; N.goneNoLook = nil
local lf = io.open(dir .. "idle_log.txt", "rb"); local before = lf and #lf:read("*a") or 0; if lf then lf:close() end
tick(); local v1 = valid(f1); tick(); local v2 = valid(f1)
check(v1 == true and v2 == true and N.goneNoLook == true and (N.stats.goneNoLook or 0) >= 2, "no native answer twice: the old answer both times, counted, and the once-only flag is set")
answer = "array"

-- 8. things that are no game objects
check(valid(nil) == false and valid(5) == false and valid({}) == false, "nil, a number and a plain table are not valid, as before")

print(string.format("RESULT: %d passed, %d failed", pass, fail))
return fail == 0
