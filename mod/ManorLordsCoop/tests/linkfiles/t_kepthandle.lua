-- Self-test of the kept read handle of the link files (lane 65, 2026-11-17). Runs WITHOUT the game:
--     lua mod/ManorLordsCoop/tests/linkfiles/t_kepthandle.lua <an empty folder to use>
-- (Lua 5.4, or LuaJIT / Lua 5.1: the 5.4 forms used are stood in for below.) It loads the real coop.lua, points the link
-- folder at the folder given, writes a player's file the way the Steam piece does (open, append, close) and reads it
-- with coop.lua's own recv. It never touches the game, a save or the mod's real link folder. Do not run it in the
-- game's console: C.start would restart the running mod.
-- What it shows: a read opens no file while the lines come (counted), a line split over two reads comes once and
-- whole, a file emptied and written again (shorter, or exactly as long) is read from its start, a quiet file's handle
-- is let go (so the writer can delete it), the chain's "~NEXT" line moves the reader and lets go of the old file.

local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/linkfiles/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_kepthandle.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end

if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout)
  local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
end

_G.COOP_LINK_DIR = dir
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.Coop = nil

local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local open0 = io.open
local function put(name, text) local f = assert(open0(dir .. name, "ab")); f:write(text); f:close() end     -- the Steam piece's append
local function fresh(name, text) local f = assert(open0(dir .. name, "wb")); f:write(text); f:close() end   -- emptied and written again

dofile(scripts .. "coop.lua")
local C = _G.Coop
local L = C.link
C.linkCut = 0
C.start("friend", "friend1", {})                   -- (no file of the host yet: its reader starts at the start)
local Rd = C.s
Rd.readers.host = nil
local opens = 0
io.open = function(p, m) if tostring(p):find("host", 1, true) then opens = opens + 1 end; return open0(p, m) end

local seq = 0
local function ln(text) seq = seq + 1; return string.format("%d 1.000 %s\n", seq, text) end
local function read() local lines = L.recv("host"); return lines end

-- 1  lines every "frame": one open at the first read, none after
put("host.txt", ln("S a1"))
local got = read()
for i = 2, 200 do put("host.txt", ln("S a" .. i)); for _, l in ipairs(read()) do got[#got + 1] = l end end
local inorder = #got == 200; for i = 1, #got do if not got[i]:match(" S a" .. i .. "$") then inorder = false end end
check(inorder, "200 lines, read after each: each once, in order (" .. #got .. ")")
check(opens == 1, "the file was opened once for 200 reads (" .. opens .. ")")

-- 2  a line written in two parts: nothing until its newline, then once and whole
local t = ln("S split-line " .. string.rep("z", 80))
put("host.txt", t:sub(1, 30)); local r1 = read()
put("host.txt", t:sub(31)); local r2 = read()
check(#r1 == 0 and #r2 == 1 and r2[1] == t:sub(1, -2), "a line in two parts comes once, whole, after its newline")

-- 3  a quiet file: the handle is let go after READ_IDLE (made to look passed), opened again at the next read
local R = Rd.readers.host
R.growT = os.clock() - 2; read()
check(R.fh == nil, "a quiet file's handle is let go")
check(os.remove(dir .. "host.txt") ~= nil or false, "... and the file can be deleted then")
fresh("host.txt", "")

-- 4  the player started again: its file emptied and written again, shorter; then exactly as long as before
seq = 0; fresh("host.txt", ln("S b1") .. ln("S b2"))
got = read()
check(#got == 2 and got[1]:match("S b1$") and got[2]:match("S b2$"), "a file emptied and written again is read from its start (" .. #got .. ")")
local before = R.off
seq = 0; fresh("host.txt", ln("S c1") .. ln("S c2"))     -- exactly as long: size alone does not show it
check(R.off == before, "(the new file is exactly as long as the one read)")
got = read()
check(#got == 0, "while the handle is held and the size is the same, nothing is read")
R.growT = os.clock() - 2; read()                           -- quiet: let go
got = read()                                               -- opened again: its first bytes differ
check(#got == 2 and got[1]:match("S c1$") and got[2]:match("S c2$"), "a file written again to the same length is read from its start once opened again (" .. #got .. ")")
put("host.txt", ln("S c3")); got = read()
check(#got == 1 and got[1]:match("S c3$"), "and goes on with the next line")

-- 5  the chain moves on: the reader follows "~NEXT", lets go of the old file, which the writer can then delete
fresh("host.2.txt", "")
put("host.txt", ln("~NEXT 2"))
put("host.2.txt", ln("S d1"))
got = read()
check(#got == 1 and got[1]:match("S d1$") and R.seg == 2, "the reader follows the ~NEXT line into host.2.txt")
check(R.fhP and R.fhP:find("host.2.txt", 1, true) ~= nil, "and holds host.2.txt only")
local okDel = os.remove(dir .. "host.txt")
check(okDel ~= nil, "host.txt can be deleted (no handle left on it)")
fresh("host.txt", "0 0.000 ~NEXT 2\n")

-- 6  a quiet numbered file: let go, left closed for READ_GAP, then read again
R.growT = os.clock() - 2; read()
check(R.fh == nil and R.waitT and R.waitT > os.clock(), "a quiet numbered file is let go and left closed for a moment")
put("host.2.txt", ln("S d2"))
got = read()
check(#got == 0, "inside that moment nothing is read")
R.waitT = os.clock() - 0.01
got = read()
check(#got == 1 and got[1]:match("S d2$"), "after it, the line comes")

-- 7  C.stop lets go of every handle
C.stop()
check(R.fh == nil, "C.stop lets go of the kept handle")

for _, n in ipairs({ "host.txt", "host.2.txt", "friend1.txt", "friend1_log.txt" }) do os.remove(dir .. n) end
print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
