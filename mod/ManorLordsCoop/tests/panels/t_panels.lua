-- Desk test of coop_x_panels.lua (lane 69): which redraws happen, when, and how often. Runs WITHOUT the game, in plain
-- Lua 5.4 or 5.1:   lua54 mod/ManorLordsCoop/tests/panels/t_panels.lua
--   or, with the Lua 5.1 library through Python:  py -I mod/ManorLordsCoop/tests/panels/luacheck.py run mod/ManorLordsCoop/tests/panels/t_panels.lua
--   (compile only: py -I .../luacheck.py compile <files>; copied from lane 67, commit 12af343a)
-- It loads the real coop_x_panels.lua with stand-ins for UE4SS (FindAllOf, RegisterHook), the core (Coop.api, Coop.s,
-- Coop.town) and the game's widgets and buildings, and drives its tick with a clock of its own (os.clock is replaced).
-- Do not run it in the game's console: it replaces _G.Coop.

local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/panels/[^/]*$") or ".") .. "/Scripts/"

local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end

-- ---------------------------------------------------------------- a clock of our own
local NOW = 1000.0
os.clock = function() return NOW end
local function at(t) NOW = t end

-- ---------------------------------------------------------------- stand-ins: objects with addresses
local nextAddr = 0x1000
local function obj(t) t = t or {}; nextAddr = nextAddr + 0x10; t.addr = nextAddr; t.alive = true
  t.GetAddress = function(self) return self.addr end
  t.IsValid = function(self) return self.alive end
  return t end
local regionA, regionB = obj({ name = "A" }), obj({ name = "B" })
local field = obj({ Region = regionA, key = "5,100,100,0" })
local mill = obj({ Region = regionA, key = "20,500,500,0" })
local farm = obj({ Region = regionB, key = "30,900,900,0" })
local byKey = { [field.key] = field, [mill.key] = mill, [farm.key] = farm }
local regions = { hofA = regionA, hofB = regionB }

local REDRAWS = {}                       -- panel name -> count
local captured, comboOpen, typing = false, false, false
local function widget(name, cls, extra)
  local w = obj(extra or {}); w.cname = cls; w.name = name
  w.GetClass = function(self) local c = self.cname; return { GetFName = function() return { ToString = function() return c end } end } end
  w.GetVisibility = function(self) return self.vis or 4 end
  return w
end
local function panel(name, b)
  local slider = widget(name .. ".slider", "Slider", { HasMouseCapture = function() return captured end })
  local combo = widget(name .. ".combo", "ComboBoxString", { IsOpen = function() return comboOpen end })
  local text = widget(name .. ".text", "EditableTextBox", { HasKeyboardFocus = function() return typing end })
  local sb = widget(name .. ".scroll", "ScrollBox", { off = 120.0 })
  sb.GetScrollOffset = function(self) return self.off end
  sb.SetScrollOffset = function(self, v) self.off = v end
  local root = widget(name .. ".root", "CanvasPanel")
  local kids = { slider, combo, text, sb }
  root.GetChildrenCount = function() return #kids end
  root.GetChildAt = function(_, i) return kids[i + 1] end
  local p = widget(name, "Inventory_C", { building = b, WidgetTree = { RootWidget = root }, inViewport = true, sb = sb })
  p.IsInViewport = function(self) return self.inViewport end
  p.GetParent = function() return nil end
  p.OnUpdateRequested = function(self) REDRAWS[self.name] = (REDRAWS[self.name] or 0) + 1; sb.off = 0.0 end   -- a redraw that resets the scroll
  p.UpdateInventory = function(self, t) REDRAWS[self.name] = (REDRAWS[self.name] or 0) + 1 end
  return p
end
local OPEN, DEVOPEN = {}, {}
_G.FindAllOf = function(cls) if cls == "Inventory_C" then return OPEN end; if cls == "developmentPanelTree_C" then return DEVOPEN end; return {} end
_G.RegisterHook = function(path, fn) return 1, 2 end

-- ---------------------------------------------------------------- stand-ins: the core and the town module
local LOG = {}
local lord = obj({})
_G.Coop = {
  register = function(name, m) _G.Coop.modules[name] = m end, modules = {},
  api = { valid = function(o) return o ~= nil and type(o) == "table" and o.IsValid ~= nil and o:IsValid() end,
          log = function(fmt, ...) LOG[#LOG + 1] = string.format(fmt, ...) end },
  s = { on = true, p1 = lord, role = "friend" },
  town = { quiet = function(fn, ...) return fn(...) end,
           findR = function(k) return regions[k] end,
           api = { findBkey = function(k) return byKey[k] end } },
}
local C = _G.Coop
local chunk = assert(loadfile(scripts .. "coop_x_panels.lua"))
print(chunk())
local P = C.panels
local M = C.modules.panels
local function tick() M.tick(C.s, NOW) end
local function count(name) return REDRAWS[name] or 0 end
local function reset() REDRAWS = {}; P.reset(); P.clickT = -100; captured, comboOpen, typing = false, false, false; for k in pairs(lord) do if k:match("^shouldUpdate") then lord[k] = nil end end end

-- ---------------------------------------------------------------- the cases
local pField, pMill, pFarm = panel("field", field), panel("mill", mill), panel("farm", farm)
OPEN = { pField, pMill, pFarm }

reset(); at(1000.0)
P.touched("PRIO", field.key); tick()
check(count("field") == 1 and count("mill") == 0 and count("farm") == 0, "a remote PRIO redraws the panel of that field only, in the next tick")
check(pField.sb.off == 120.0, "the scroll box is put back where it was")

reset(); at(1010.0)
for _ = 1, 5 do P.touched("PRIO", field.key) end; tick(); at(1010.016); tick()
check(count("field") == 1, "five touches in one tick are one redraw")

reset(); at(1020.0)
P.touched("PRIO", field.key); tick()
at(1020.1); P.touched("PRIO", field.key); tick()
check(count("field") == 1, "a touch 0.1 s after a redraw waits (at most one redraw per 0.25 s)")
at(1020.2); tick(); check(count("field") == 1, "still waiting at 0.2 s")
at(1020.26); tick(); check(count("field") == 2, "the waiting redraw runs at 0.25 s (nothing is lost)")
at(1021.0); tick(); check(count("field") == 2, "and only once")

reset(); at(1030.0)
P.localInput(); at(1030.1); P.touched("PRIO", field.key); tick()
check(count("field") == 0, "no redraw within 0.5 s of the local player's press in a panel")
at(1030.45); tick(); check(count("field") == 0, "still none at 0.45 s")
at(1030.51); tick(); check(count("field") == 1, "the redraw runs right after the 0.5 s")

reset(); at(1040.0)
captured = true; P.touched("PRIO", field.key); tick()
at(1041.0); tick(); at(1045.0); tick()
check(count("field") == 0, "no redraw while a control of the panel holds the mouse (slider drag)")
captured = false; at(1045.15); tick()
check(count("field") == 1, "the redraw runs when the control lets go")

reset(); at(1050.0)
comboOpen = true; P.touched("PRIO", field.key); tick(); at(1051.0); tick()
check(count("field") == 0, "no redraw while a drop-down of the panel is open")
comboOpen = false; at(1051.2); tick(); check(count("field") == 1, "redrawn when it closes")

reset(); at(1060.0)
typing = true; P.touched("PRIO", field.key); tick(); at(1061.0); tick()
check(count("field") == 0, "no redraw while a text box of the panel has the keyboard")
typing = false; at(1061.2); tick(); check(count("field") == 1, "redrawn when typing ends")

reset(); at(1070.0)
P.touched("TRULE", "hofA"); tick()
check(count("field") == 1 and count("mill") == 1 and count("farm") == 0, "a region setter redraws every panel of that region and no other")
reset(); at(1071.0)
P.touched("ADDW", mill.key); tick()
check(count("field") == 1 and count("mill") == 1 and count("farm") == 0, "a family change redraws every workplace panel of the building's region")

reset(); at(1080.0)
P.touched("ROAD", "not-a-building"); tick()
check(count("field") == 1 and count("mill") == 1 and count("farm") == 1, "an action whose target is no building or region redraws every open panel")

reset(); at(1090.0)
C.hold = true; P.touched("PRIO", field.key); tick(); C.hold = nil; at(1090.1); tick()
check(count("field") == 0, "nothing is recorded or redrawn while the core holds (join, repair)")
reset(); at(1091.0)
P.touched("PRIO", field.key); C.s.replay = { n = 0 }; tick(); C.s.replay = nil; at(1091.1); tick()
check(count("field") == 0, "a redraw queued before the host's lines are read again is dropped")
reset(); at(1092.0)
C.join = { state = "saving" }; P.touched("PRIO", field.key); tick(); C.join = nil; tick()
check(count("field") == 0, "nothing during a join")

reset(); at(1100.0)
pField.inViewport = false; P.touched("PRIO", field.key); tick(); pField.inViewport = true
check(count("field") == 0, "a closed panel is not redrawn")
reset(); at(1101.0)
captured = true; P.touched("PRIO", field.key); tick(); pField.inViewport = false; captured = false; at(1102.0); tick(); pField.inViewport = true; at(1103.0); tick()
check(count("field") == 0, "a panel closed while its redraw waited is dropped (it fills itself when opened)")

reset(); at(1110.0)
field.alive = false; P.touched("PRIO", field.key); tick(); field.alive = true
check(count("field") == 0, "a building gone: no call on it")

reset(); at(2000.0)
local before = P.n.inv
for i = 1, 7200 do at(2000.0 + i * 0.016); tick() end            -- 7200 frames (2 minutes at 60 frames) with nobody acting
check(P.n.inv == before and count("field") + count("mill") + count("farm") == 0 and next(P.n.flags) == nil, "nobody acting: no redraw and no flag at all")

reset(); at(3000.0)
P.touched("WAR", nil); tick()
check(lord.shouldUpdateStatUI == true and lord.shouldUpdateClaimUI == true and count("field") == 0, "war or peace from another player raises the lord's stat and claim redraw flags, no building panel")
reset(); at(3010.0)
P.touched("O:PUSH", nil); tick()
check(lord.shouldUpdateArmyUI == true and lord.shouldUpdateArmyListUI == nil, "a friend's stance order raises the army flag only")
reset(); at(3020.0)
P.touched("O:SPEED", nil); tick()
check(lord.shouldUpdateArmyUI == nil and lord.shouldUpdateStatUI == nil and count("field") == 0, "a speed order redraws nothing")
reset(); at(3030.0)
P.touched("WAR", nil); tick(); lord.shouldUpdateStatUI = nil
at(3030.1); P.touched("WAR", nil); tick()
check(lord.shouldUpdateStatUI == nil, "a flag is raised at most once per 0.25 s")
at(3030.3); tick(); check(lord.shouldUpdateStatUI == true, "and the waiting one is raised after")
reset(); at(3040.0)
P.localInput(); P.touched("WAR", nil); tick()
check(lord.shouldUpdateStatUI == nil, "no flag within 0.5 s of the local player's press")
at(3040.6); tick(); check(lord.shouldUpdateStatUI == true, "raised right after")

reset(); at(3050.0)
P.cfg.inv = "event"; P.touched("PRIO", field.key); tick(); P.cfg.inv = "request"
check(count("field") == 1, "method 'event' redraws through UpdateInventory")
reset(); at(3060.0)
P.cfg.inv = "flag"; P.touched("PRIO", field.key); tick(); P.cfg.inv = "request"
check(lord.shouldUpdateInventoryUI == true and count("field") == 0, "method 'flag' leaves the redraw to the lord's own tick")
reset(); at(3070.0)
P.cfg.on = false; P.touched("PRIO", field.key); tick(); P.cfg.on = true; at(3070.1); tick()
check(count("field") == 0, "switched off: nothing")

-- the development tree
local tree = panel("tree", nil)
tree.updateContents = function(self) REDRAWS.tree = (REDRAWS.tree or 0) + 1; self.sb.off = 0.0 end
reset(); at(4000.0); DEVOPEN = { tree }
P.touched("R:policy", nil); tick()
check(count("tree") == 1 and lord.shouldUpdateStatUI == true and count("field") == 0, "a policy from another player redraws the open development tree (and the region panel's flag), no building panel")
check(tree.sb.off == 120.0, "the tree's scroll box is put back")
reset(); at(4010.0)
captured = true; P.touched("R:perk", nil); tick(); at(4011.0); tick()
check(count("tree") == 0, "no tree redraw while the player holds a control in it")
captured = false; at(4011.2); tick(); check(count("tree") == 1, "redrawn when he lets go")
reset(); at(4020.0)
P.touched("PRIO", field.key); tick()
check(count("tree") == 0 and count("field") == 1, "a building setter does not redraw the tree")
reset(); at(4030.0)
P.touched("TRULE", "hofA"); tick()
check(count("tree") == 1, "a trade rule redraws the tree (its trade summary)")
reset(); at(4040.0); DEVOPEN = {}
P.touched("R:name", nil); tick(); DEVOPEN = { tree }; at(4041.0); tick()
check(count("tree") == 0, "tree not open: the wish is dropped (it fills itself when it opens)")
reset(); at(4050.0)
for i = 1, 3000 do at(4050.0 + i * 0.016); tick() end
check(count("tree") == 0, "nobody acting: no tree redraw")
reset(); at(4060.0)
P.touched("A:BEHAV", nil); tick()
check(lord.shouldUpdateArmyUI == true and count("tree") == 0, "a player's behaviour stance taken from the host raises the army flag")
DEVOPEN = {}

print(P.status())
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
