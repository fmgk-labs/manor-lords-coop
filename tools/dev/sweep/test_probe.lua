-- Desk test of sweep_probe.lua (no game): a made-up engine, lord and building panel with the UE4SS calls the probe uses.
--   lua tools/dev/sweep/test_probe.lua        (plain Lua 5.1 or 5.4)
-- The panel behaves as in the game's first run (lane 71, run e1): it is a child of the main interface, so
-- IsInViewport() is false while it shows; openBuildingTab of building 2 opens nothing until the lord selected it.
local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"))
local dir = here:match("^(.*/)[^/]*$") or "./"
local fails = 0
local function check(c, what) if c then print("PASS  " .. what) else fails = fails + 1; print("FAIL  " .. what) end end

local nextAddr = 0x100000
local function obj(cls, name, t)
  t = t or {}; nextAddr = nextAddr + 0x100
  t._cls, t._name, t._addr, t._vis = cls, name, nextAddr, t._vis or 0
  t.IsValid = function() return true end
  t.GetAddress = function(self) return self._addr end
  t.GetClass = function(self) local c = self._cls; return { GetFullName = function() return "Class /Game/X." .. c end } end
  t.GetFName = function(self) local n = self._name; return { ToString = function() return n end } end
  t.GetVisibility = function(self) return self._vis end
  return t
end
local lord = obj("MyPawnCPP_BP3_C", "Lord", { bIsPlayerPaused = true })
local function bld(t, x, y) return obj("BP_BuildingMaster_C", "B", { ownerPawn = lord, _t = t, _x = x, _y = y,
  GetType = function(self) return self._t end, K2_GetActorLocation = function(self) return { X = self._x, Y = self._y } end }) end
local b1, b2 = bld(89, 1000, 2000), bld(72, 5000, 6000)
local mainUI = obj("MainUICPP_C", "MainUI", { IsInViewport = function() return true end, GetChildrenCount = function() return 1 end })
local text = obj("TextBlock", "TextBlock_4", { GetText = function() return { ToString = function() return "Maintained" end } end })
local root = obj("CanvasPanel", "Root", { GetChildrenCount = function() return 1 end, GetChildAt = function() return text end })
local inv = obj("Inventory_C", "Inventory_C_7", { _vis = 1, WidgetTree = { RootWidget = root },
  IsInViewport = function() return false end, GetParent = function(self) if self._vis == 0 then return mainUI end end })
local silver = obj("TextBlock", "Silver", { GetText = function() return { ToString = function() return "120" end } end })
mainUI.GetChildrenCount = function() return 2 end
mainUI.GetChildAt = function(_, i) if i == 0 then return inv end; return silver end
local selected
lord.deselect_buildings = function() inv._vis = 1; inv.building = nil; selected = nil end
lord.selectBuildingSilent = function(_, b) selected = b end
lord.openBuildingTab = function(_, b) if b == b2 and selected ~= b2 then return end; inv.building = b; inv._vis = 0 end
local eng = obj("MyRTSMultiEngineCPP_BP_C", "Engine", { playerRef = lord, buildingArr = { b1, b2 }, regions = {}, gameSpeed = 0,
  getDaysTotal = function() return 40 end, TemporalComponent = { day = 3 } })
_G.FindFirstOf = function(c) if c == "RTSMultiEngineCPP" then return eng end end
_G.FindAllOf = function(c) if c == "Inventory_C" then return { inv } end; if c == "MainUICPP_C" then return { mainUI } end; return {} end
local loopFn
_G.LoopInGameThreadWithDelay = function(_, f) loopFn = f; return 1 end

local out = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/") .. "/sweep_probe_test.txt"
_G.SW_CMD, _G.SW_DIR, _G.SW_OUT, _G.SW_ONLY, _G.SW_SCREENS = "start", dir, out, "", "0"
local started = dofile(dir .. "sweep_probe.lua")
check(type(started) == "string" and started:find("sweep started: 3 jobs", 1, true) ~= nil, "start: 3 jobs (HUD and 2 buildings): " .. tostring(started))
for _ = 1, 400 do if loopFn() == true then break end end
_G.SW_CMD = "status"
local st = dofile(dir .. "sweep_probe.lua")
check(st:find("^done") ~= nil and st:find("fails=0", 1, true) ~= nil, "done, no failure: " .. st)
local f = io.open(out, "r"); local dump = f:read("*a"); f:close(); os.remove(out)
check(dump:find("P\tB 89@100,200\t1:-\tInventory_C:Inventory_C#1/CanvasPanel:Root#1/TextBlock:TextBlock#1\tT\tMaintained", 1, true) ~= nil, "building 1: the panel (not in the viewport, in a parent) is read")
check(dump:find("E\tB 72@500,600\tRETRY select=true open=true", 1, true) ~= nil, "building 2: opened after the lord selects it")
check(dump:find("P\tB 72@500,600\t1:-", 1, true) ~= nil and dump:find("selected=ok-after-select", 1, true) ~= nil, "building 2: read after the retry")
check(dump:find("#END", 1, true) ~= nil and dump:find("OPENFAIL", 1, true) == nil, "footer, no OPENFAIL")
-- the screens: one owned region, one squad, the main tabs, the development tree, the map
local region = obj("BP_Region_C", "R", { ownerPawn = lord, regionUniqueTag = { ToString = function() return "home" end } })
eng.regions = { region }
lord.commandedSquads = { { Value = 7 }, { Value = 0 } }
local calls = {}
for _, fn in ipairs({ "selectSquad", "deselectSquad", "switchTab", "toggleDevelopmentPanel", "setMapMode", "changeSelectedRegionUI" }) do
  lord[fn] = function() calls[fn] = (calls[fn] or 0) + 1 end
end
loopFn = nil
_G.SW_CMD, _G.SW_SCREENS = "start", "1"
local s2 = dofile(dir .. "sweep_probe.lua")
check(s2:find("sweep started: 15 jobs", 1, true) ~= nil, "screens: HUD, 2 buildings, 1 region, 1 squad, 8 tabs, dev, map = 15 jobs: " .. s2)
for _ = 1, 2000 do if loopFn() == true then break end end
f = io.open(out, "r"); dump = f:read("*a"); f:close(); os.remove(out)
check(dump:find("P\tARMY 7\t-\t", 1, true) ~= nil and dump:find("P\tREGION home\t-\t", 1, true) ~= nil, "screens: the army panel of squad 7 and the region are read")
check(dump:find("P\tDEV\t-\t", 1, true) ~= nil and dump:find("P\tTAB 7\t-\t", 1, true) ~= nil and dump:find("P\tMAP\t-\t", 1, true) ~= nil, "screens: dev tree, tab 7, map read")
check(calls.selectSquad == 1 and calls.deselectSquad == 1 and calls.toggleDevelopmentPanel == 2 and calls.setMapMode == 2 and calls.switchTab == 16,
  "screens: every opener is undone (select / deselect, toggle twice, map on / off, each tab then tab 0)")
check(dump:find("#END", 1, true) ~= nil and dump:find("OPENFAIL", 1, true) == nil and dump:find("step error", 1, true) == nil, "screens: footer, no failure, no step error")

print(fails .. " failed")
if fails > 0 then os.exit(1) end
