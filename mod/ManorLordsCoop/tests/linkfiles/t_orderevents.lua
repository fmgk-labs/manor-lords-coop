-- Self-test (lane 65, 2026-11-17) of coop_patch.lua P.orderEvents, which C.preOrders calls every frame: the handle of
-- patch_events.txt is kept (one open, not one a frame), every event comes once and whole, and above 256 KB the handle
-- is let go so that the DLL (coop_patch.c l28_event) can delete the file and start it again. Runs WITHOUT the game:
--     lua mod/ManorLordsCoop/tests/linkfiles/t_orderevents.lua <an empty folder to use>
-- (Lua 5.4, or LuaJIT / Lua 5.1: the 5.4 forms used are stood in for below.) Never the game.
if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout); local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
end
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local src = (here():match("^(.*)/tests/linkfiles/[^/]*$") or ".") .. "/Scripts/coop_patch.lua"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_orderevents.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end
_G.Coop = { api = { log = function() end }, register = function() end }
local open0 = io.open
dofile(src)
local P = _G.Coop.patch
P.dir = dir
local opens = 0
io.open = function(p, m) if tostring(p):find("patch_events", 1, true) then opens = opens + 1 end; return open0(p, m) end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local path = dir .. "patch_events.txt"
local function ev(s)            -- the DLL's l28_event: above 256 KB the file is deleted first, then appended to
  local f = open0(path, "rb"); local size = f and f:seek("end") or 0; if f then f:close() end
  local deleted = size > 256 * 1024 and os.remove(path) ~= nil
  local g = open0(path, "ab"); g:write(s); g:close()
  return deleted
end
ev("OLD from before\n")
check(#P.orderEvents() == 0, "what was there before the first call is skipped")
local got = {}
for i = 1, 300 do
  if i % 3 == 0 then ev("ORDER " .. i .. "\n") end
  if i % 50 == 0 then ev("PART"); for _, l in ipairs(P.orderEvents()) do got[#got + 1] = l end; ev("IAL " .. i .. "\n") end
  for _, l in ipairs(P.orderEvents()) do got[#got + 1] = l end
end
local want = 0; for i = 1, 300 do if i % 3 == 0 then want = want + 1 end; if i % 50 == 0 then want = want + 1 end end
local ok = #got == want; for _, l in ipairs(got) do if not (l:match("^ORDER %d+$") or l:match("^PARTIAL %d+$")) then ok = false end end
check(ok, "every event once and whole, a line in two parts too (" .. #got .. " of " .. want .. ")")
check(opens == 1, "300 calls, one open (" .. opens .. ")")
local big = string.rep("x", 1000) .. "\n"
for i = 1, 270 do ev(big) end
local n = #P.orderEvents()
check(n == 270 and P.evF == nil, "above 256 KB the handle is let go after the read (" .. n .. ")")
check(ev("AFTER 1\n"), "the DLL deletes the file at its next event")
got = P.orderEvents()
check(#got == 1 and got[1] == "AFTER 1", "the reader reads the new file from its start")
if P.evF then P.evF:close() end
os.remove(path)
print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
