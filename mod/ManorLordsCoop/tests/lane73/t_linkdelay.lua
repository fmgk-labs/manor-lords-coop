-- Self-test of the development build's LINK DELAY switch (lane 73, 2026-11-17). Runs WITHOUT the game:
--     lua mod/ManorLordsCoop/tests/lane73/t_linkdelay.lua <an empty folder to use>
-- (Lua 5.4, or LuaJIT / Lua 5.1: the 5.4 forms used are stood in for below.) It loads the real coop.lua and
-- coop_dev.lua, points the link folder at the folder given, writes a host's link file and reads it with coop.lua's own
-- recv (through the seam C.devLink). The clock is the test's own (os.clock is stood in for), so nothing waits.
-- It never touches the game, a save or the mod's real link folder. Do not run it in the game's console.
-- What it shows: off, a line comes at once; on (1000 ms, bursts of 500), no line comes before 1000 ms, every line
-- comes at a multiple of 500 ms, in the order written, each with its own place in the file (ends[]); a line for the
-- copy's own name wins over "*"; a rewind drops what is held and the lines come once, from the file; the switch
-- taken away lets out what is held at once.

local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane73/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_linkdelay.lua <folder>"); os.exit(2) end
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
_G.Coop = nil
local getenv0 = os.getenv
os.getenv = function(k) if k == "COOP_ROLE" then return "friend" end; return getenv0(k) end   -- coop_dev.lua asks for it
local T = 1000.0                                    -- the test's clock (seconds)
local clock0 = os.clock
os.clock = function() return T end

local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function put(name, text) local f = assert(io.open(dir .. name, "ab")); f:write(text); f:close() end
local function fresh(name, text) local f = assert(io.open(dir .. name, "wb")); f:write(text); f:close() end

dofile(scripts .. "coop.lua")
local C = _G.Coop
C.linkCut = 0
C.start("friend", "friend1", {})
dofile(scripts .. "coop_dev.lua")
check(C.devLink and C.devLink.recv and C.devLink.rewind, "coop_dev.lua loads outside the game and gives the seam C.devLink")
local L = C.link
C.s.readers.host = nil
os.remove(dir .. "dev_linkdelay.txt"); fresh("host.txt", "")

local seq = 0
local function ln(text) seq = seq + 1; return string.format("%d 1.000 %s\n", seq, text) end
local function step(dt) T = T + dt; return L.recv("host") end

-- 1  off: at once
put("host.txt", ln("S a1")); local lines = step(0.02)
check(#lines == 1 and lines[1]:match(" S a1$"), "switch off: a line comes at the next read")

-- 2  on for every copy: 1000 ms, bursts of 500 ms, no jitter
fresh("dev_linkdelay.txt", "# test\n* 1000 500\n")
T = T + 2.1; L.recv("host")                         -- (the file is looked at every 2 s)
local t0 = T
local wrote, got = {}, {}
for i = 1, 60 do                                    -- 60 lines, one every 50 ms
  put("host.txt", ln("S b" .. i)); wrote[i] = T
  local ls, es = step(0.05)
  for k, l in ipairs(ls) do got[#got + 1] = { l, T, es[k] } end
end
for _ = 1, 60 do local ls, es = step(0.05); for k, l in ipairs(ls) do got[#got + 1] = { l, T, es[k] } end end
local order, early, grid, endsOk, lastEnd, worst = #got == 60, false, true, true, -1, 0
for i, g in ipairs(got) do
  if not g[1]:match(" S b" .. i .. "$") then order = false end
  local held = g[2] - (wrote[i] or 0)
  if held < 1.0 - 1e-6 then early = true end
  if held > worst then worst = held end
  local ph = (g[2] / 0.5) % 1; if ph > 0.11 and ph < 0.99 then grid = false end     -- within one read (50 ms) after a burst
  if not g[3] or g[3] <= lastEnd then endsOk = false end; lastEnd = g[3] or lastEnd
end
check(order, "on: 60 lines, each once, in the order written (" .. #got .. ")")
check(not early, "on: no line before its 1000 ms")
check(worst <= 1.0 + 0.5 + 0.06, string.format("on: no line held longer than the delay and one burst (longest %.2f s)", worst))
check(grid, "on: every line comes with a burst (a multiple of 500 ms)")
check(endsOk, "on: each line keeps its own place in the file (ends[] rises)")

-- 3  a line for this copy's own name wins over "*"
fresh("dev_linkdelay.txt", "* 1000 500\nfriend1 200 0\nfriend2 3000 500\n")
T = T + 2.1; L.recv("host")
put("host.txt", ln("S c1")); local a = step(0.02); T = T + 0.15; local b = L.recv("host"); T = T + 0.06; local c = L.recv("host")
check(#a == 0 and #b == 0 and #c == 1, "the line for this copy's name is used (200 ms, no bursts)")

-- 4  a rewind drops what is held; the lines are read again from the file, once
fresh("dev_linkdelay.txt", "* 1000 500\n")
T = T + 2.1; L.recv("host")
local _, e0 = nil, nil
put("host.txt", ln("S d1")); local l1, en1 = step(0.02)
T = T + 2.0; l1, en1 = L.recv("host")
local mark = en1[#en1]                              -- the place after "S d1"
put("host.txt", ln("S d2") .. ln("S d3")); step(0.02)            -- read and held
local bytes = L.rewind("host", mark)
local seen = {}
for _ = 1, 50 do local ls = step(0.05); for _, l in ipairs(ls) do seen[#seen + 1] = l:match(" S (%w+)$") end end
check(bytes and bytes > 0 and #seen == 2 and seen[1] == "d2" and seen[2] == "d3", "after a rewind the held lines are dropped and come once, from the file (" .. table.concat(seen, ",") .. ")")
C.s.replay = nil

-- 5  the switch taken away: what is held comes out at once, then as before
put("host.txt", ln("S e1")); local h = step(0.02)
os.remove(dir .. "dev_linkdelay.txt")
T = T + 2.1; local o = L.recv("host")
put("host.txt", ln("S e2")); local p = step(0.02)
check(#h == 0 and #o == 1 and o[1]:match(" S e1$") and #p == 1 and p[1]:match(" S e2$"), "the switch taken away: the held line at once, the next line at once")

os.clock = clock0; os.getenv = getenv0
pcall(C.stop)
print(string.format("RESULT: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
