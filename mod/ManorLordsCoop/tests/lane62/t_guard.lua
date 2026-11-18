-- Desk test of the one-copy guard (lane 62, 2026-11-17): coop_guard.lua, coop_second.lua and their place in main.lua.
-- Runs WITHOUT the game:   lua mod/ManorLordsCoop/tests/lane62/t_guard.lua <an empty folder to use>
-- (Lua 5.4, or LuaJIT / Lua 5.1.) Windows only: the lock rests on Windows refusing to delete a file that is open.
-- Two "processes" are two loads of the guard file here. Windows refuses the delete while a handle is open, in this
-- process as in another, so the first load's open handle stands for a living first process, and closing it for that
-- process ending. (Between two real processes of one test install, in the game's own Lua: game session s3 of lane 62.)
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane62/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_guard.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end
if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout); local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function spit(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function obj(t) t = t or {}; t.IsValid = t.IsValid or function() return true end; return t end

do
  local gdir = dir .. "guardmod/"
  os.execute('mkdir "' .. gdir:gsub("/", "\\") .. 'Scripts" >nul 2>nul')
  spit(gdir .. "Scripts/coop_guard.lua", slurp(scripts .. "coop_guard.lua"))
  local env = {}                                             -- what os.getenv answers in this test
  local getenv0 = os.getenv
  os.getenv = function(k) if k == "COOP_ROLE" or k == "COOP_NAME" then return env[k] end; return getenv0(k) end
  local function process(off) _G.COOP_GUARD = nil; dofile(gdir .. "Scripts/coop_guard.lua"); return _G.COOP_GUARD.check(off) end
  local lock = gdir .. "coop_run.lock"
  local G1 = process()
  local text1 = slurp(lock)
  check(G1.second == false and G1.f ~= nil and G1.state:find("^first") and text1 and text1:find("beat %d+") and text1:find("started %d+"), "the first copy: it takes the lock (<mod folder>/coop_run.lock) with a heartbeat and its start time: " .. tostring(G1.state))
  G1.beat(4242)
  text1 = slurp(lock)
  check(text1:find("pid 4242", 1, true) ~= nil and #text1 < 200, "the heartbeat rewrites one record in place, with the process id once known (" .. #text1 .. " bytes)")
  local G2 = process()
  check(G2.second == true and G2.f == nil and G2.state:find("^second") and G2.holder and G2.holder.pid == 4242, "a second copy while the first lives: second, and it knows the holder's process id")
  check(slurp(lock) == text1, "the second copy changed nothing: the lock file is byte for byte as the first copy wrote it")
  -- the first copy ends (also by a crash: Windows closes its handle)
  G1.f:close(); G1.f = nil
  local G3 = process()
  check(G3.second == false and G3.f ~= nil and G3.state:find("^first"), "after the first copy ended (its handle closed), the next copy is the first again")
  -- a lock file that cannot be deleted but has no fresh heartbeat is not believed
  G3.f:seek("set", 0); G3.f:write(string.format("x\nbeat %-12d\nstarted %-12d\npid %-10s\n", os.time() - 1000, os.time() - 2000, "7")); G3.f:flush()
  local G4 = process()
  check(G4.second == false and G4.f == nil and G4.state:find("^unguarded"), "a lock that is held but whose heartbeat is 1000 s old: not believed, the mod starts as usual (" .. tostring(G4.state) .. ")")
  G3.beat()
  -- the test harness (a forced role or name) and guard = off: never second, the lock is not touched
  local before = slurp(lock)
  env.COOP_ROLE = "friend"
  local G5 = process()
  env.COOP_ROLE = nil; env.COOP_NAME = "friend2"
  local G6 = process()
  env.COOP_NAME = nil
  local G7 = process(true)
  check(G5.second == false and G6.second == false and G7.second == false and G5.state:find("^off") and G6.state:find("^off") and G7.state:find("^off") and slurp(lock) == before,
        "a forced role or name (the test harness: several copies from one test install) and guard = off: not guarded, the lock untouched")
  local G8 = process()
  check(G8.second == true, "(without them the same copy would be second)")
  G3.f:close(); os.remove(lock)
  os.getenv = getenv0
end

do
  -- main.lua: the guard runs before the core, and a second copy loads nothing but coop_second.lua
  local msrc = slurp(scripts .. "main.lua")
  local gAt, sAt, cAt = msrc:find('load("coop_guard.lua")', 1, true), msrc:find('load("coop_second.lua")', 1, true), msrc:find('load("coop.lua")', 1, true)
  check(gAt and sAt and cAt and gAt < sAt and sAt < cAt and msrc:sub(sAt, cAt):find("\n%s+return%s") ~= nil, "main.lua: the guard is asked before the core is loaded; a second copy loads coop_second.lua and returns (source check)")
  local ssrc = slurp(scripts .. "coop_second.lua")
  check(not ssrc:find("io%.open") and not ssrc:find("os%.remove") and not ssrc:find("os%.rename") and not ssrc:find("Coop%.") and not ssrc:find("loadlib"), "coop_second.lua opens no file, loads no DLL and touches nothing of the mod (source check)")
  -- its two rows in the menu, with stand-ins for the menu's widgets
  local added, removed = {}, 0
  local col = obj({ AddChild = function(self, b) added[#added + 1] = b; b.parent = self; return obj({ SetHorizontalAlignment = function() end }) end, RemoveChild = function() removed = removed + 1 end, GetAddress = function() return 99 end })
  local quit = obj({ Slot = { HorizontalAlignment = 2 }, GetParent = function() return col end, GetClass = function() return "W_MainMenuButton_C" end })
  local menu = obj({ menuButton_quit = quit, IsInViewport = function() return true end, RebuildNaviGrid = function() end })
  _G.FindAllOf = function(cls) return cls == "mainMenu_widget_C" and { menu } or {} end
  _G.FindFirstOf = function() return obj({}) end
  _G.StaticFindObject = function(path)
    if path:find("WidgetBlueprintLibrary", 1, true) then return obj({ Create = function() local b = obj({ GetParent = function(self) return self.parent end }); b.SetButtonText = function(self, t) self.text = tostring(t) end; return b end }) end
    if path:find("KismetTextLibrary", 1, true) then return obj({ Conv_StringToText = function(self, s) return s end }) end
    return obj({ GetPlayerController = function() return nil end })
  end
  local loops = 0
  _G.LoopInGameThreadWithDelay = function() loops = loops + 1; return 7 end
  dofile(scripts .. "coop_second.lua")
  _G.COOP_SECOND.tick(); _G.COOP_SECOND.tick()
  check(loops == 1 and #added == 3 and added[1].text == "Manor Lords is already running" and added[2].text == "with co-op on this PC. Close this copy." and added[3] == quit and removed == 1 and _G.COOP_SECOND.err == nil,
        "coop_second.lua: two rows in the menu above Quit Game, once ('" .. tostring(added[1] and added[1].text) .. "' / '" .. tostring(added[2] and added[2].text) .. "')")
end

print(string.format("\nRESULT: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
