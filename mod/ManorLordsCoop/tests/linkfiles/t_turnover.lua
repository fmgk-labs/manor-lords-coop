-- Self-test of the link file turnover in coop.lua (lane 33, 2026-11-13). Runs WITHOUT the game, in plain Lua 5.4:
--     lua54 mod/ManorLordsCoop/tests/linkfiles/t_turnover.lua  [<an empty folder to use>]
-- It loads the real coop.lua with a few stand-ins for the UE4SS functions C.start calls, points the link folder at a
-- folder of its own, and drives coop.lua's own send / recv / rewind (Coop.link). It never touches the game, the mod's
-- real link folder or a save. Without a folder argument it makes one in the system's temp folder and removes it after.
-- STATUS: written 2026-11-13 but NOT RUN: there is no Lua interpreter on the PC it was written on. Its first run is also
-- its syntax check. Do not run it in the game's console: C.start would restart the running mod.
-- (lane 65, 2026-11-17) run with LuaJIT 5.1 through the shim in t_kepthandle.lua's header: all pass.

local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/linkfiles/[^/]*$") or ".") .. "/Scripts/"

local dir = arg and arg[1]
local made = false
if not dir then
  local t = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
  dir = t .. "/coop_link_selftest_" .. tostring(os.time())
  os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul || mkdir -p "' .. dir .. '"')
  made = true
end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end

-- stand-ins for what C.start / C.stop call in the game
_G.COOP_LINK_DIR = dir
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.Coop = nil

local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end; return false end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function spit(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end

dofile(scripts .. "coop.lua")
local C = _G.Coop
local L = C.link
check(L and L.send and L.recv and L.rewind, "coop.lua loads outside the game and has Coop.link")

C.linkCut = 2000                                    -- bytes per file: small, so the test turns over often
C.start("host", "host", { "friend1" })
local W = C.s                                       -- the host copy (writer)
local Rd = { name = "friend1", readers = {}, stats = { sent = 0 }, seq = 0 }   -- a friend copy (reader of host)
local function as(S, fn, ...) local keep = C.s; C.s = S; local a, b = fn(...); C.s = keep; return a, b end
local function sendAs(text) as(W, L.send, text) end

-- the reader starts at the end; then 200 lines with a read after every 10: ids once and in order, no "~NEXT" line handed out
Rd.readers.host = as(Rd, L.readerAtEnd, "host")
local got, bad, lastEnd, endsOk, nextSeen = {}, 0, -1, true, false
local function drain()
  local lines, ends = as(Rd, L.recv, "host")
  for i, l in ipairs(lines) do
    if l:find("~NEXT", 1, true) then nextSeen = true end
    local id = tonumber(l:match(" X tov (%d+)$")); if id then got[#got + 1] = id end
    if not ends[i] or ends[i] <= lastEnd then endsOk = false end; lastEnd = ends[i] or lastEnd
  end
  return lines, ends
end
for i = 0, 399 do sendAs("X tov " .. i); if i % 10 == 9 then drain() end end
drain()
local inorder = #got == 400; for i = 1, #got do if got[i] ~= i - 1 then inorder = false end end
check(inorder and not nextSeen, "400 lines over several files: the reader gets each once, in order, and never the ~NEXT line (" .. #got .. ")")
check(endsOk, "the places (ends) only grow, across files")
check(W.outSeg >= 5 and exists(dir .. "host.2.txt") and exists(dir .. "host." .. W.outSeg .. ".txt"), "the writer turned over (now in file " .. tostring(W.outSeg) .. ")")
check(Rd.readers.host.seg == W.outSeg, "the reader is in the writer's file")

-- 30 s after the last turnover (made to look so): old files deleted, host.txt a pointer, a new reader finds the end
C.linkCut = 1e9; W.cutLimT = nil                   -- no turnover on this one line
W.cutT = os.clock() - 31
sendAs("X tov 400")
C.linkCut = 2000; W.cutLimT = nil
local oldest = W.outSeg - 2
check(slurp(dir .. "host.txt") == string.format("0 0.000 ~NEXT %d\n", oldest) and exists(dir .. "host." .. oldest .. ".txt") and not exists(dir .. "host.2.txt"),
      "after 30 s: files older than the two before the current one are gone; host.txt points to the oldest kept (" .. oldest .. ")")
local R2 = as({ readers = {} }, L.readerAtEnd, "host")
check(R2 and R2.seg == W.outSeg, "a copy that starts reading now finds the newest file through host.txt")
got = {}; drain()
check(#got == 1 and got[1] == 400, "the reader goes on after the cleanup")

-- a friend loads alone: the save's MARK place is kept; lines over two more turnovers; read again from the MARK
sendAs("J MARK tov-1")
local lines, ends = drain()
local markAt; for i, l in ipairs(lines) do if l:find("J MARK tov-1", 1, true) then markAt = ends[i] end end
for i = 401, 600 do sendAs("X tov " .. i) end                -- not read meanwhile (the copy is loading)
got = {}; drain()
local back = as(Rd, L.rewind, "host", markAt)
got = {}; drain()
inorder = #got == 200; for i = 1, #got do if got[i] ~= 400 + i then inorder = false end end
check(markAt and back and back > 0 and inorder, "rewind to the MARK across turnovers: the 200 lines after it again, in order (" .. #got .. ")")
check(Rd.replay and Rd.replay.to >= lastEnd, "the replay ends at the newest place read")

-- the host's game starts again: host.txt emptied, numbered files deleted; the reader starts again with the new lines only
-- (lane 65) the reader keeps its file open, and the C runtime's handle does not share delete: the file it is in can
-- only be deleted once the reader let go of it (after READ_IDLE s of quiet, then closed for READ_GAP s); until then
-- the start keeps it in its retry list (S.stale, tried again at each line sent). Both waits are made to look passed.
local segBefore = W.outSeg
C.start("host", "host", { "friend1" })
W = C.s
local held = Rd.readers.host.fh ~= nil
check(slurp(dir .. "host.txt") == "" and (not exists(dir .. "host." .. segBefore .. ".txt") or (held and #W.stale > 0)),
      "a start empties host.txt and deletes host.<k>.txt (or keeps trying while a reader holds the file: " .. tostring(held) .. ")")
for i = 0, 9 do sendAs("X tov " .. i) end
Rd.readers.host.growT = os.clock() - 2; drain()                -- the reader's file was quiet for a second: let go
check(Rd.readers.host.fh == nil, "a quiet file's handle is let go")
Rd.readers.host.waitT = os.clock() - 0.01                      -- READ_GAP passed
sendAs("H")                                                    -- the writer's retry deletes the old file now
check(not exists(dir .. "host." .. segBefore .. ".txt"), "the old numbered file is deleted once the reader let go of it")
got = {}; drain()
inorder = #got == 10; for i = 1, #got do if got[i] ~= i - 1 then inorder = false end end
check(inorder, "a reader in a deleted file starts again at host.txt and gets only the 10 new lines (" .. #got .. ")")

-- the Steam slot changes this copy's name to a name with files left from an earlier session: that chain starts afresh
spit(dir .. "friend2.txt", "5 1.000 X old\n6 1.000 ~NEXT 5\n")
spit(dir .. "friend2.5.txt", "7 1.000 X old five\n")
W.name = "friend2"; if W.out then W.out:close(); W.out = nil end
sendAs("X fresh")
check(not exists(dir .. "friend2.5.txt") and (slurp(dir .. "friend2.txt") or ""):match("^%d+ [%d%.]+ X fresh\n$") ~= nil,
      "a new name with old numbered files: they are deleted and the new lines start in friend2.txt")

-- no limit, no turnover
C.linkCut = 0; W.cutLimT = nil
W.name = "host"; if W.out then W.out:close(); W.out = nil end
local before = W.outSeg
for i = 0, 300 do sendAs("X tov big " .. i) end
check(W.outSeg == before, "limit 0: the file is never cut")

C.stop()
print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
if made then
  for _, n in ipairs({ "host", "friend1", "friend2" }) do
    os.remove(dir .. n .. ".txt"); os.remove(dir .. n .. "_log.txt")
    for k = 2, 400 do os.remove(dir .. n .. "." .. k .. ".txt") end
  end
  os.execute('rmdir "' .. dir:gsub("/", "\\"):gsub("\\$", "") .. '" 2>nul || rmdir "' .. dir .. '"')
end
os.exit(fail == 0 and 0 or 1)
