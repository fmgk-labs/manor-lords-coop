-- Desk test of lane 86's visit module (coop_x_visit.lua): the line format, the host's relay, looks, leave, silence,
-- history lines, the switch, and the traffic of 8 walkers. Runs WITHOUT the game:
--     py -3 -I mod/ManorLordsCoop/tests/lane67/luacheck.py run mod/ManorLordsCoop/tests/lane86/t_visit.lua mod/ManorLordsCoop/Scripts/coop_x_visit.lua
-- It loads the real module once per copy (a host and up to 7 friends, each with its own stand-in Coop and a stand-in
-- game: a walker is a table, a body is a table with an address) and passes the lines between them as the link does
-- ("<seq> <time> <line>", the sender's clock, split into words).
local FILE = ARG1 or "mod/ManorLordsCoop/Scripts/coop_x_visit.lua"
local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end
local function words(line) local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end; return w end

_G.FName = function(s) return { name = s } end
_G.FindAllOf = function() return {} end
_G.StaticFindObject = function() return nil end

local T = 1000.0            -- the wall clock of the test
local copies = {}
local nextAddr = 0x1000

local function makeCopy(name, role, skew, peers, wanted)
  local S = { name = name, role = role, on = true, p1 = { live = true }, peers = peers or {}, heard = {}, stats = {}, eng = {} }
  local mod
  local C = { s = S, register = function(n, m) mod = m; return m end }
  local out = {}
  local seq = 0
  C.api = {
    valid = function(o) return type(o) == "table" and o.dead ~= true end,
    un = function(o) return o end,
    now = function() return T + skew end,
    log = function(fmt, ...) out.log = out.log or {}; out.log[#out.log + 1] = string.format(fmt, ...) end,
    send = function(line) seq = seq + 1; out[#out + 1] = string.format("%d %.3f %s", seq, T + skew, line) end,
  }
  _G.Coop = C
  local V0 = { wanted = wanted ~= false, key = "B" }
  C.visit = V0
  local chunk = assert(loadfile(FILE))
  local res = chunk()
  local V = C.visit
  -- the stand-in game
  local g = { walking = false, x = 0, y = 0, z = 0, yaw = 0, v = 0, bodies = {}, looks = {}, keyDown = false }
  local walker = { live = true }
  V.game = {
    pc = function() return { WasInputKeyJustPressed = function() local k = g.keyDown; g.keyDown = false; return k end } end,
    walker = function() if g.walking then return walker end end,
    sample = function() return g.x, g.y, g.z, g.yaw, g.v end,
    mainUI = function() return { visitModeOn = function() g.walking = true end } end,
    busy = function() return g.busy end,
    hostBody = function() return 1 end,
    freeGround = function(_, _, x, y, z) return x, y, z, 0 end,
    applyLook = function(a, look) g.looks[#g.looks + 1] = look; a.look = look; return true end,
    spawnBody = function(_, who, look, x, y, z, label) nextAddr = nextAddr + 16; local b = { live = true, who = who, look = look, x = x, y = y, z = z, label = label, addr = nextAddr }; g.bodies[nextAddr] = b; return nextAddr end,
    actors = function() local t = {}; for ad, b in pairs(g.bodies) do if not b.dead then t[ad] = b end end; return t end,
    destroy = function(a) a.dead = true; g.bodies[a.addr] = nil end,
    camera = function() return nil end,
    steer = function(a, x, y, z) a.x, a.y, a.z = x, y, z; return nil, 0 end,
    label = function() end,
    dilation = function() return 1.0 end,
    holdPace = function() end,
  }
  walker.InpActEvt_unposses_K2Node_InputActionEvent_2 = function() g.walking = false end
  local cp = { name = name, S = S, C = C, V = V, mod = mod, out = out, g = g, res = res, read = 0 }
  copies[name] = cp
  return cp
end

local function tick(cp) _G.Coop = cp.C; if cp.mod and cp.mod.tick then cp.mod.tick(cp.S, os.clock()) end end
-- every line a copy sent since the last call goes to its readers (friend lines to the host, host lines to friends)
local function deliver()
  for _, src in pairs(copies) do
    for i = src.read + 1, #src.out do
      local line = src.out[i]; local w = words(line)
      for _, dst in pairs(copies) do
        if dst ~= src and dst.mod and ((src.S.role == "host") ~= (dst.S.role == "host")) then
          _G.Coop = dst.C
          local from = src.S.role == "host" and "host" or src.name
          if dst.S.role == "host" then dst.S.heard[from] = os.clock() end
          dst.mod.onMessage(dst.S, from, w[3], w, line)
        end
      end
    end
    src.read = #src.out
  end
end
local function run(secs, step)
  step = step or 0.05
  local n = math.floor(secs / step + 0.5)
  for _ = 1, n do
    T = T + step
    for _, cp in pairs(copies) do if cp.S.role == "host" then for _, p in ipairs(cp.S.peers) do if copies[p] and copies[p].mod then cp.S.heard[p] = os.clock() end end end end   -- every friend sends other lines too
    for _, cp in pairs(copies) do tick(cp) end; deliver()
  end
end
local function bodyOf(cp, who) for _, b in pairs(cp.g.bodies) do if b.who == who and not b.dead then return b end end end
local function nBodies(cp) local n = 0; for _, b in pairs(cp.g.bodies) do if not b.dead then n = n + 1 end end; return n end

print("== 1. the line format")
do
  local cp = makeCopy("x", "host", 0, {}); copies = {}
  local V = cp.V
  local e = { who = "friend3", look = 12, on = true, age = 0.042, x = 92600.4, y = -76300.6, z = 3450, yaw = -90, v = 115.2 }
  local s = V.encEntry(e)
  check(s == "friend3,12,42,92600,-76301,3450,270,115", "entry encoded: " .. s)
  local d = V.decEntry(s)
  check(d and d.who == "friend3" and d.look == 12 and d.on and math.abs(d.age - 0.042) < 1e-9 and d.x == 92600 and d.y == -76301 and d.yaw == 270 and d.v == 115, "entry decoded back")
  check(V.encEntry({ who = "host", look = 10, on = false }) == "host,10,-", "a player that does not walk: host,10,-")
  local off = V.decEntry("host,10,-"); check(off and off.on == false and off.look == 10, "not walking decoded")
  check(V.decEntry("friend1,3,1,2,3") == nil, "too few fields: refused")
  check(V.decEntry("fr iend,3,-") == nil and V.decEntry("friend1,x,-") == nil and V.decEntry("friend1,3,1,2,3,4,5,abc") == nil, "bad name, look or number: refused")
  local own = V.encOwn(true, 1.4, -2.6, 3, 365, 7.5)
  check(own == "VW 1 1 -3 3 5 8", "own line encoded: " .. own)
  local o = V.decOwn(words("12 1000.000 " .. own)); check(o and o.on and o.x == 1 and o.y == -3 and o.yaw == 5 and o.v == 8, "own line decoded")
  check(V.decOwn(words("1 1.0 VW 0")).on == false, "VW 0 decoded")
  check(V.decOwn(words("1 1.0 VW 1 1 2")) == nil and V.decOwn(words("1 1.0 VW 7")) == nil, "a broken own line: refused")
  check(not own:find(",") and not s:find(" "), "an entry has no space (one word) and an own line no comma")
end

print("== 2. host relay: friend1 walks, friend2 and the host draw it; the host walks, both friends draw it")
copies = {}
local H = makeCopy("host", "host", 0, { "friend1", "friend2" })
local F1 = makeCopy("friend1", "friend", 0.37, {})      -- its clock 0.37 s ahead of the host's
local F2 = makeCopy("friend2", "friend", -0.21, {})
F1.g.keyDown = true
run(0.1)
check(F1.g.walking, "friend1's key entered visit mode")
F1.g.x, F1.g.y, F1.g.z, F1.g.v = 92300, -76900, 3400, 115
for i = 1, 30 do F1.g.x = F1.g.x + 11.5; run(0.1) end
local W = H.V.W.friend1
check(W and W.on and math.abs(W.x - F1.g.x) <= 12, "the host's table has friend1 walking at its place (by the sender)")
local b2 = bodyOf(F2, "friend1"); local bh = bodyOf(H, "friend1")
check(bh ~= nil and math.abs(bh.x - F1.g.x) < 60, string.format("the host draws friend1 (%.0f cm behind)", bh and F1.g.x - bh.x or -1))
check(b2 ~= nil and math.abs(b2.x - F1.g.x) < 60, string.format("friend2 draws friend1 through the host (%.0f cm behind)", b2 and F1.g.x - b2.x or -1))
check(bodyOf(F1, "friend1") == nil, "friend1 draws no body of its own walker")
check(b2 and b2.label == "friend 1", "the label without a Steam name: 'friend 1'")
-- every VW line from friend1 was relayed under friend1's slot; a VW line names nobody
local vw = 0; for _, l in ipairs(F1.out) do if l:find(" VW ") then vw = vw + 1 end end
check(vw >= 25 and vw <= 35, "friend1 sent about 10 VW lines a second while moving (" .. vw .. " in 3 s)")
H.g.keyDown = true; run(0.1)
H.g.x, H.g.y, H.g.z, H.g.v = 92600, -76300, 3400, 115
for i = 1, 20 do H.g.y = H.g.y + 11.5; run(0.1) end
local hb1, hb2 = bodyOf(F1, "host"), bodyOf(F2, "host")
check(hb1 and hb2 and math.abs(hb1.y - H.g.y) < 60 and math.abs(hb2.y - H.g.y) < 60, "both friends draw the host's walker")
check(hb1 and hb1.look == 10, "the host's body is the save's lord (the lady here): look 10")
check(H.g.looks[1] == nil, "the host's own walker is not re-skinned")
-- standing: 1 line a second
H.g.v = 0; F1.g.v = 0; local n0 = #F1.out; run(5.0)
local n1 = 0; for i = n0 + 1, #F1.out do if F1.out[i]:find(" VW 1 ") then n1 = n1 + 1 end end
check(n1 >= 4 and n1 <= 6, "standing: about 1 VW line a second (" .. n1 .. " in 5 s)")
check(bodyOf(F2, "friend1") ~= nil, "a standing walker's body stays")

print("== 3. looks")
check(F1.V.myLook and F1.V.myLook ~= 10 and F1.V.myLook ~= 0, "friend1 got a look from the host (" .. tostring(F1.V.myLook) .. ")")
check(F1.g.looks[#F1.g.looks] == F1.V.myLook, "friend1's own walker took that look")
check(F2.V.myLook and F2.V.myLook ~= F1.V.myLook, "friend2 got another look (" .. tostring(F2.V.myLook) .. ")")
check(b2 and b2.look == F1.V.myLook, "friend2 draws friend1 with friend1's look")
do
  local seen, dup = {}, false
  for i = 1, 7 do local l = H.V.lookFor("friend" .. i); if seen[l] then dup = true end; seen[l] = true end
  check(not dup, "7 friends: 7 different looks")
  local again = H.V.lookFor("friend3"); check(again == H.V.looks.friend3, "a friend's look is kept for its slot (asked again: the same)")
  local all = true; for l in pairs(seen) do if not (l >= 1 and l <= 4 or l >= 11 and l <= 14) then all = false end end
  check(all, "every friend's look is one of 2 bodies x 4 colours")
end

print("== 4. leave: the body goes on every copy within a second")
F1.g.keyDown = true; run(0.1)
check(not F1.g.walking, "friend1's key left visit mode")
run(0.4)
check(bodyOf(H, "friend1") == nil and bodyOf(F2, "friend1") == nil, "friend1's body is gone on the host and on friend2 within 0.5 s")
check(nBodies(F2) == 1 and bodyOf(F2, "host") ~= nil, "friend2 still draws the host only")
-- the game's own leave (Enter / Escape): the walker is gone without the key
H.g.walking = false; run(0.5)
check(nBodies(F1) == 0 and nBodies(F2) == 0, "the host left the game's way: its body gone on both friends")
check(not H.V.W.host.on, "the host's table says the host does not walk")

print("== 5. silence, history lines, a join")
F2.g.keyDown = true; run(0.1); F2.g.v = 115; F2.g.x = 1000; run(1.0)
check(bodyOf(F1, "friend2") ~= nil, "friend2 walks: friend1 draws it")
F2.mod = nil                                    -- friend2's copy goes silent (its lines stop)
run(10.5)
check(not H.V.W.friend2.on, "the host marks friend2 as not walking after 10 s of silence")
check(bodyOf(H, "friend2") == nil and bodyOf(F1, "friend2") == nil, "its body is removed on the host and on friend1")
-- a line from long ago (the replay after a join's MARK): moves nothing
do
  local w = words(string.format("900 %.3f VH friend5,3,0,5,5,5,0,100", T - 30.0))
  _G.Coop = F1.C; F1.mod.onMessage(F1.S, "host", "VH", w, "")
  run(0.2)
  check(bodyOf(F1, "friend5") == nil, "a VH line 30 s old (a join's replay) makes no body")
  check((F1.S.stats.visit_oldLine or 0) >= 1, "it is counted as an old line")
  F1.S.replay = { n = 0 }
  local w2 = words(string.format("901 %.3f VH friend6,3,0,5,5,5,0,100", T + 0.37))
  _G.Coop = F1.C; F1.mod.onMessage(F1.S, "host", "VH", w2, "")
  F1.S.replay = nil; run(0.2)
  check(bodyOf(F1, "friend6") == nil and (F1.S.stats.visit_replayLine or 0) == 1, "a line read again in a resync's replay (S.replay) makes no body, even with a fresh time")
end
-- a late joiner: a new friend sees a walker from the host's next full list
F2.mod = copies.friend2.mod
H.g.keyDown = true; run(0.1); H.g.v = 115; H.g.x = 5000; run(0.3)
local F3 = makeCopy("friend3", "friend", 0.05, {}); table.insert(H.S.peers, "friend3")
run(1.2)
check(bodyOf(F3, "host") ~= nil, "a copy that joins late draws the host's walker within 1.2 s")

print("== 6. the switch off: nothing registered, no line, no body")
do
  local saved = copies; copies = {}
  local X = makeCopy("host", "host", 0, { "friend1" }, false)
  check(X.mod == nil, "visit = off: the module registers nothing (no tick, no message handler)")
  check(type(X.res) == "string" and X.res:find("off"), "its load line says off: " .. tostring(X.res))
  copies = saved
end

print("== 7. 8 walkers: the host's traffic")
do
  copies = {}
  local peers = {}; for i = 1, 7 do peers[#peers + 1] = "friend" .. i end
  local HH = makeCopy("host", "host", 0, peers)
  local fr = {}
  for i = 1, 7 do fr[i] = makeCopy("friend" .. i, "friend", i * 0.01, {}) end
  for _, cp in pairs(copies) do cp.g.keyDown = true end
  run(0.2)
  for i, cp in ipairs(fr) do cp.g.v = 115; cp.g.x = i * 1000 end
  HH.g.v = 115
  local b0 = 0; for _, l in ipairs(HH.out) do b0 = b0 + #l + 1 end
  local l0 = #HH.out
  for _ = 1, 100 do for _, cp in pairs(copies) do cp.g.x = cp.g.x + 11.5 end; run(0.1) end
  local b1 = 0; for _, l in ipairs(HH.out) do b1 = b1 + #l + 1 end
  local lines = #HH.out - l0
  print(string.format("        host: %d lines, %.1f KB a second for 8 walkers (one combined line per 100 ms, a full list each second)", lines / 10, (b1 - b0) / 10 / 1024))
  check(lines / 10 <= 11.5, "the host sends at most about 11 lines a second with 8 walkers")
  check((b1 - b0) / 10 <= 5 * 1024, "the host sends under 5 KB a second with 8 walkers")
  local all = true
  for _, cp in pairs(copies) do if nBodies(cp) ~= 7 then all = false; print("        " .. cp.name .. " draws " .. nBodies(cp)) end end
  check(all, "every one of the 8 copies draws the 7 others")
end

print("== 7b. a screen open: the key does not enter")
do
  copies = {}
  local HH = makeCopy("host", "host", 0, {})
  HH.g.busy = "the settings screen is open"; HH.g.keyDown = true; run(0.2)
  check(not HH.g.walking and (HH.S.stats.visit_refused or 0) == 1, "with a screen open the key does not enter (counted as refused)")
  HH.g.busy = nil; HH.g.keyDown = true; run(0.2)
  check(HH.g.walking, "with the screen closed it enters")
end

print("== 8. nobody walking: the host's lines")
do
  copies = {}
  local HH = makeCopy("host", "host", 0, { "friend1" })
  local FF = makeCopy("friend1", "friend", 0.1, {})
  run(1.0); local n0 = #HH.out
  run(60.0)
  local n = #HH.out - n0
  check(n <= 7, "nobody walking: the host sends at most one line in 10 s (" .. n .. " in 60 s)")
  check(#FF.out == 0, "nobody walking: a friend sends nothing")
  check(FF.V.myLook ~= nil, "the friend still gets its look (" .. tostring(FF.V.myLook) .. ")")
end

print("== 9. coop.cfg read from the mod folder (visit, visit_key)")
do
  local src = assert(io.open(FILE, "rb")):read("*a")
  local base = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/") .. "/lane86_cfg_" .. tostring(os.time())
  local function try(cfgText)
    os.execute('mkdir "' .. (base .. "/Scripts"):gsub("/", "\\") .. '" 2>nul')
    local f = assert(io.open(base .. "/Scripts/coop_x_visit.lua", "wb")); f:write(src); f:close()
    local c = assert(io.open(base .. "/coop.cfg", "wb")); c:write(cfgText); c:close()
    local C = { s = { name = "host", role = "host", on = true, stats = {} }, register = function() end,
      api = { valid = function() return true end, un = function(o) return o end, now = function() return T end, log = function() end, send = function() end } }
    _G.Coop = C
    assert(loadfile(base .. "/Scripts/coop_x_visit.lua"))()
    return C.visit
  end
  local V1 = try("# nothing set\n")
  check(V1.wanted == true and V1.key == "B", "no lines: on, key B")
  local V2 = try("visit = off\n")
  check(V2.wanted == false, "visit = off: off")
  local V3 = try("visit_key = n\n")
  check(V3.wanted == true and V3.key == "N", "visit_key = n: key N (" .. tostring(V3.key) .. ")")
  local V4 = try("visit_key = F9\nvisit = OFF\n")
  check(V4.key == "B" and V4.wanted == false, "visit_key = F9 (not a letter): B; visit = OFF: off")
  local V5 = try("# visit = off\n#visit_key = K\n")
  check(V5.wanted == true and V5.key == "B", "lines with # are ignored")
  os.remove(base .. "/coop.cfg"); os.remove(base .. "/Scripts/coop_x_visit.lua")
  os.execute('rmdir "' .. (base .. "/Scripts"):gsub("/", "\\") .. '" 2>nul'); os.execute('rmdir "' .. base:gsub("/", "\\") .. '" 2>nul')
end

print("== 10. the screen guard by what is on screen (the lead's real-key fault, 2026-11-20)")
do
  -- stand-in widgets: a class name, own visibility, a parent panel or an outer, user widgets in the viewport or not
  local A0 = 0x5000
  local CLS = { ["/Script/UMG.UserWidget"] = { isClass = true, name = "UserWidget" }, ["/Script/UMG.WidgetSwitcher"] = { isClass = true, name = "WidgetSwitcher" } }
  local engine = { paused = false }
  CLS["/Script/Engine.Default__GameplayStatics"] = { IsGamePaused = function() return engine.paused end }
  local function W(cls, t)
    A0 = A0 + 8; t = t or {}; t.cls = cls; t.a = A0
    t.IsValid = function(self) return not self.dead end
    t.GetAddress = function(self) return self.a end
    t.GetClass = function(self) return { GetFName = function() return { ToString = function() return self.cls end } end } end
    t.IsA = function(self, c) return c ~= nil and ((c.name == "UserWidget" and self.user == true) or (c.name == "WidgetSwitcher" and self.cls == "WidgetSwitcher")) end
    t.IsVisible = function(self) if self.boom then error("touched") end; return self.vis ~= false end
    t.IsInViewport = function(self) return self.inVp == true end
    t.GetParent = function(self) return self.parent end
    t.GetOuter = function(self) return self.outer end
    t.GetActiveWidget = function(self) return self.active end
    t.GetVisibility = function(self) return self.v or 4 end
    return t
  end
  local function tree(owner) return W("WidgetTree", { outer = owner }) end
  -- the HUD: MainUICPP in the viewport; its settings screen (closed) in a canvas
  local hud = W("MainUICPP_C", { user = true, inVp = true })
  local hudRoot = W("CanvasPanel", { outer = tree(hud) })
  local qHud = W("quickSettings_C", { user = true, vis = false, parent = hudRoot })
  -- the pause menu (closed: out of the viewport) holding the settings wrapper, its Border_0, its own settings screen
  local menu = W("mainMenu_widget_C", { user = true, inVp = false })
  local menuRoot = W("CanvasPanel", { outer = tree(menu) })
  local wrap = W("menu_settingsWrapper_C", { user = true, parent = menuRoot })
  local border = W("Border", { outer = tree(wrap) })
  local qMenu = W("quickSettings_C", { user = true, v = 4, parent = border })       -- vis 4: IsVisible true by itself
  -- a class's template: its tree's outer is a class, not a widget
  local qTpl = W("quickSettings_C", { user = true, outer = tree({ IsValid = function() return true end, IsA = function() return false end, GetClass = function() return { GetFName = function() return { ToString = function() return "WidgetBlueprintGeneratedClass" end } end } end }) })
  local list = { qHud, qMenu, qTpl }
  local saveFAO, saveSFO = _G.FindAllOf, _G.StaticFindObject
  _G.FindAllOf = function(n) if n == "quickSettings_C" then return list end; return {} end
  _G.StaticFindObject = function(p) return CLS[p] end
  local C = { s = { name = "host", role = "host", on = true, stats = {} }, register = function() end,
    api = { valid = function(o) return type(o) == "table" and (o.IsValid == nil or o:IsValid()) end, un = function(o) return o end, now = function() return T end, log = function() end, send = function() end } }
  _G.Coop = C
  C.visit = { wanted = true, key = "B" }
  assert(loadfile(FILE))()
  local G = C.visit.realGame
  local pauseMenu = false
  local S = { p1 = { IsValid = function() return true end, isPauseMenuVisible = function() return pauseMenu end } }
  local m = hud
  check(G.onScreen(qMenu) == false, "the pause menu's closed copy (vis 4, IsVisible true) is NOT on screen")
  check(G.busy(S, m) == nil, "after the pause menu closed: nothing refuses (the lead's case: B enters)")
  qHud.vis = true
  check(G.onScreen(qHud) == true and G.busy(S, m) == "the settings screen is open", "the HUD's settings screen open: refused")
  qHud.vis = false
  menu.inVp = true; pauseMenu = true
  check(G.onScreen(qMenu) == true, "the pause menu open with its settings: that copy is on screen")
  check(G.busy(S, m) == "the pause menu is open", "the pause menu open: refused as the pause menu")
  pauseMenu = false
  check(G.busy(S, m) == "the settings screen is open", "its settings on screen without the menu's flag: still refused")
  wrap.vis = false
  check(G.onScreen(qMenu) == false, "a hidden widget on the way: not on screen")
  wrap.vis = nil; menu.inVp = false
  local sw = W("WidgetSwitcher", { parent = menuRoot }); local other = W("Overlay", { parent = sw })
  wrap.parent = sw; sw.active = other; menu.inVp = true
  check(G.onScreen(qMenu) == false, "a switcher showing another branch: not on screen")
  sw.active = wrap
  check(G.onScreen(qMenu) == true, "the switcher showing this branch: on screen")
  wrap.parent = menuRoot; menu.inVp = false
  check(G.onScreen(qTpl) == false, "a class's template copy: not on screen (its tree's outer is a class)")
  border.outer = { IsValid = function() return false end, boom = true }          -- a null handle from GetOuter
  check(G.onScreen(qMenu) == false, "a null handle on the way: false, nothing called on it")
  border.outer = tree(wrap)
  qMenu.parent = { IsValid = function() return false end }                        -- a null handle from GetParent: on to the outer
  qMenu.outer = tree(wrap)
  check(G.onScreen(qMenu) == false, "a null parent: on to the tree's owner (out of the viewport: false)")
  menu.inVp = true; wrap.inVp = true
  check(G.onScreen(qMenu) == true, "a null parent, the owner in the viewport: on screen")
  wrap.inVp = false; qMenu.parent = border
  engine.paused = true
  check(G.busy(S, m) == "a full screen is open", "the engine paused by a full screen: refused")
  engine.paused = false; menu.inVp = false
  hud.v = 1
  check(G.busy(S, m) ~= nil and G.busy(S, m):find("normal state") ~= nil, "the interface collapsed: refused")
  hud.v = nil
  CLS["/Script/UMG.UserWidget"] = nil
  check(G.onScreen(qMenu) == nil, "the UMG class not found: onScreen cannot decide (nil)")
  check(G.busy(S, m) == "the settings screen is open", "and busy falls back to the widget's own flag")
  _G.FindAllOf, _G.StaticFindObject = saveFAO, saveSFO
end

print("== 11. our row in the game's Controls screen (step 8): the game's composition, after the last game row")
do
  local A0 = 0x9000
  local function obj(cls, t) A0 = A0 + 8; t = t or {}; t.cls = cls; t.a = A0
    t.IsValid = function(self) return not self.dead end
    t.GetAddress = function(self) return self.a end
    t.GetClass = function(self) return { GetFName = function() return { ToString = function() return self.cls end } end } end
    t.GetFName = function(self) return { ToString = function() return self.name or self.cls end } end
    t.IsA = function(self, c) return c ~= nil and c.name == "UserWidget" and self.user == true end
    t.GetOuter = function(self) return self.outer end
    return t
  end
  local function text(s) return { ToString = function() return s end } end
  local function slot(v) return { Padding = v.P, Size = v.Z, HorizontalAlignment = v.H, VerticalAlignment = v.V,
    SetPadding = function(self, p) self.Padding = p end, SetSize = function(self, z) self.Size = z end,
    SetHorizontalAlignment = function(self, h) self.HorizontalAlignment = h end, SetVerticalAlignment = function(self, x) self.VerticalAlignment = x end } end
  local function named() local s = obj("NamedSlot"); s.SetContent = function(self, w) self.content = w end; s.GetContent = function(self) return self.content end; return s end
  local function list(nRows, failAdd)
    local L = obj("VerticalBox", { name = "bindings_vb", kids = {} })
    L.GetChildrenCount = function(self) return #self.kids end
    L.GetChildAt = function(self, i) return self.kids[i + 1] end
    L.AddChild = function(self, w) if failAdd then error("refused") end; self.kids[#self.kids + 1] = w; w.Slot = slot({ P = { Left = 0, Top = 0, Right = 0, Bottom = 0 }, Z = { Value = 1, SizeRule = 0 }, H = 0, V = 0 }); return w.Slot end
    L.RemoveChild = function(self, w) for i, k in ipairs(self.kids) do if k == w then table.remove(self.kids, i); w.Slot = nil; return true end end; return false end
    for i = 1, nRows do
      local r = obj("InputRow_C", { Label = text("settings_" .. i), Index = 0, user = true })
      r.Slot = slot({ P = { Left = 0, Top = 0, Right = 0, Bottom = 0 }, Z = { Value = 1, SizeRule = 0 }, H = 0, V = 0 })
      L.kids[#L.kids + 1] = r
    end
    local img = obj("Image", { name = "Image_13" }); img.Slot = slot({ P = { Left = 4, Top = 4, Right = 4, Bottom = 4 }, Z = { Value = 1, SizeRule = 0 }, H = 0, V = 0 })
    L.kids[#L.kids + 1] = img
    return L, img
  end
  local CLS = { ["/Script/UMG.UserWidget"] = { name = "UserWidget" } }
  local made = {}
  CLS["/Game/UI/Settings/InputRow.InputRow_C"] = { name = "row" }
  CLS["/Game/UI/StyledAutoSettings/Input/StyledActionMapping.StyledActionMapping_C"] = { name = "map" }
  CLS["/Script/UMG.Default__WidgetBlueprintLibrary"] = { IsValid = function() return true end, Create = function(_, q, cls, pc)
    local w
    if cls.name == "row" then
      w = obj("InputRow_C", { Index = 7, user = true, Content1 = named(), Content2_1 = named() })
      w.AlternatingRowBorder = { SetVisibility = function(self, v) self.vis = v end }
    else w = obj("StyledActionMapping_C", { user = true }) end
    made[#made + 1] = w; return w end }
  CLS["/Script/Engine.Default__KismetTextLibrary"] = { IsValid = function() return true end, Conv_StringToText = function(_, s) return text(s) end }
  CLS["/Script/Engine.Default__GameplayStatics"] = { IsValid = function() return true end, GetPlayerController = function() return { IsValid = function() return true end } end }
  local hud = obj("MainUICPP_C", { user = true })
  local L1, img = list(31)
  local q1 = obj("quickSettings_C", { user = true, bindings_vb = L1, outer = obj("WidgetTree", { outer = hud }) })
  local tplClass = { IsValid = function() return true end, IsA = function() return false end, GetClass = function() return { GetFName = function() return { ToString = function() return "WidgetBlueprintGeneratedClass" end } end } end }
  local L2 = list(31)
  local q2 = obj("quickSettings_C", { user = true, bindings_vb = L2, outer = obj("WidgetTree", { outer = tplClass }) })
  local L3 = list(4, true)
  local q3 = obj("quickSettings_C", { user = true, bindings_vb = L3, outer = obj("WidgetTree", { outer = hud }) })
  local saveFAO, saveSFO = _G.FindAllOf, _G.StaticFindObject
  _G.FindAllOf = function(n) if n == "quickSettings_C" then return { q1, q2, q3 } end; return {} end
  _G.StaticFindObject = function(p) return CLS[p] end
  _G.FName = function(s) return { name = s, ToString = function() return s end } end
  local logs = {}
  local C = { s = { name = "host", role = "host", on = true, stats = {} }, register = function() end,
    api = { valid = function(o) return type(o) == "table" and (o.IsValid == nil or o:IsValid()) end, un = function(o) return o end, now = function() return T end, log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end, send = function() end } }
  _G.Coop = C
  C.visit = { wanted = true, key = "B" }
  assert(loadfile(FILE))()
  local G = C.visit.realGame
  local S = { p1 = { IsValid = function() return true end } }
  G.rows(S)
  local r, at = G.ourRow(L1)
  check(#L1.kids == 33 and at == 31, "our row after the 31 game rows (" .. tostring(at) .. "), 33 children (" .. #L1.kids .. ")")
  check(L1.kids[33] == img and img.Slot and img.Slot.Padding.Left == 4 and img.Slot.Padding.Bottom == 4, "the divider back last, its padding 4 kept")
  check(r and r.Label:ToString() == "Walk (co-op visit mode)" and r.Index == 0, "the row's label set, Index 0 like the game's rows")
  check(r and r.AlternatingRowBorder.vis == 2, "stripe hidden at an odd place like the game's rows (" .. tostring(r and r.AlternatingRowBorder.vis) .. ")")
  local m1, m2 = r and r.Content1.content, r and r.Content2_1.content
  check(m1 and m1.ActionName.name == "CoopVisit" and m1.MappingGroup == 0, "Content1: the game's key widget for CoopVisit, mapping group 0")
  check(m2 and m2.ActionName.name == "CoopVisit" and m2.MappingGroup == 1, "Content2_1: the same for mapping group 1")
  check(m1 and m1.KeyGroup == nil and m1.IconTags == nil and m1.ActionLabel == nil, "nothing else written on the key widgets (no tag container, no label)")
  check(#L2.kids == 32, "a class's template screen is left alone")
  local n1 = #made
  G.rows(S); G.rows(S)
  check(#L1.kids == 33 and #made == n1 + 1, "later passes add nothing to a list with our row (only the refusing list's second try made one)")
  local tries = 0; for _, l in ipairs(logs) do if l:find("error", 1, true) or l:find("not added", 1, true) then tries = tries + 1 end end
  check(#L3.kids == 5 and tries == 2, "a list that refuses the row: 2 tries, then left alone (" .. tries .. " logged)")
  check(C.visit.rowFails[L1.a] == nil and C.visit.rowsAdded == 1, "a row added is not counted as a refusal (added " .. tostring(C.visit.rowsAdded) .. ")")
  -- a new world (a join or a load): new screens, and a new list may come at an address used before
  C.visit.worldFn(C.s)
  local L4 = list(31); L4.a = L1.a
  q1.bindings_vb = L4
  G.rows(S)
  check(#L4.kids == 33 and G.ourRow(L4) ~= nil, "a new world, a new list at the same address: our row added again")
  _G.FindAllOf, _G.StaticFindObject = saveFAO, saveSFO
end

print("== 13. the walk keys read back from the game's key system (step 8: both columns, None, no answer)")
do
  local IS = { IsValid = function() return true end, ActionMappings = {}, adds = 0 }
  IS.AddActionMapping = function(self, m, rebuild) self.adds = self.adds + 1; self.rebuild = rebuild; self.ActionMappings[#self.ActionMappings + 1] = { ActionName = { ToString = function() return m.ActionName.name end } } end
  local answers = { [0] = "B", [1] = "None" }
  local noAnswer = false
  local IMM = { IsValid = function() return true end, GetPlayerActionMappingStatic = function(_, pc, action, grp)
    if noAnswer then error("no answer") end
    return { Key = { KeyName = { ToString = function() return answers[grp] end } } } end }
  local saveSFO = _G.StaticFindObject
  _G.StaticFindObject = function(p) if p == "/Script/Engine.Default__InputSettings" then return IS elseif p == "/Script/AutoSettingsInput.Default__InputMappingManager" then return IMM end; return nil end
  _G.FName = function(s) return { name = s, ToString = function() return s end } end
  local C = { s = { name = "host", role = "host", on = true, stats = {} }, register = function() end,
    api = { valid = function(o) return type(o) == "table" and (o.IsValid == nil or o:IsValid()) end, un = function(o) return o end, now = function() return T end, log = function() end, send = function() end } }
  _G.Coop = C
  C.visit = { wanted = true, key = "B" }
  assert(loadfile(FILE))()
  local V = C.visit
  local down = nil
  local pc = { WasInputKeyJustPressed = function(_, k) return k.KeyName.name == down end }
  V.game = { pc = function() return pc end }
  local function press(k) down = k; V.akT = nil; local r = V.keyFn(C.s); down = nil; return r end
  local function keys() local t = {}; for _, k in ipairs(V.keyNames or {}) do t[#t + 1] = k.name end; return table.concat(t, "+") end
  check(press("B") == true and keys() == "B", "first key B (coop.cfg's default, answered by the key system): B walks (" .. keys() .. ")")
  check(IS.adds == 1 and IS.rebuild == false, "our action added once, WITHOUT the key-map rebuild")
  noAnswer = true
  check(press("B") == true and keys() == "B", "no answer from the key system: the key stays")
  noAnswer = false; answers = { [0] = "K", [1] = "J" }
  check(press("J") == true and press("K") == true and press("B") == false and keys() == "K+J", "rebound K and a second key J: both walk, B no longer (" .. keys() .. ")")
  answers = { [0] = "None", [1] = "None" }
  check(press("K") == false and press("B") == false and keys() == "", "both keys taken away in the game's screen: no key walks")
  answers = { [0] = "N", [1] = "None" }
  check(press("N") == true and IS.adds == 1, "a new key N: walks; the action is still added only once")
  -- the action add fails (the advisor's case): the plugin answers None for an action it does not know
  local C2 = { s = { name = "host", role = "host", on = true, stats = {} }, register = function() end,
    api = { valid = function(o) return type(o) == "table" and (o.IsValid == nil or o:IsValid()) end, un = function(o) return o end, now = function() return T end, log = function() end, send = function() end } }
  _G.Coop = C2
  C2.visit = { wanted = true, key = "B" }
  local IS2 = { IsValid = function() return true end, ActionMappings = {}, adds = 0 }
  IS2.AddActionMapping = function(self) self.adds = self.adds + 1; error("refused") end
  answers = { [0] = "None", [1] = "None" }
  _G.StaticFindObject = function(p) if p == "/Script/Engine.Default__InputSettings" then return IS2 elseif p == "/Script/AutoSettingsInput.Default__InputMappingManager" then return IMM end; return nil end
  assert(loadfile(FILE))()
  local V2 = C2.visit
  V2.game = { pc = function() return pc end }
  local function press2(k) down = k; V2.akT = nil; local r = V2.keyFn(C2.s); down = nil; return r end
  check(press2("B") == true, "the action add failed and the plugin answers None: the coop.cfg key B still walks")
  for _ = 1, 8 do press2("X") end
  check(IS2.adds == 5, "the add is tried again, 5 times at most (" .. IS2.adds .. ")")
  check(V2.status():find("(coop.cfg)", 1, true) ~= nil, "the status says the key is coop.cfg's")
  answers = { [0] = "M", [1] = "None" }
  check(press2("M") == true and press2("B") == false, "a saved choice the plugin still answers (M) wins even without the action")
  _G.StaticFindObject = saveSFO
end

print("== 15. modifier chords from the profile file (the plugin's prompt captures Ctrl+K; UE4SS cannot read the flags)")
do
  local C = { s = { name = "host", role = "host", on = true, stats = {} }, register = function() end,
    api = { valid = function(o) return type(o) == "table" and (o.IsValid == nil or o:IsValid()) end, un = function(o) return o end, now = function() return T end, log = function() end, send = function() end } }
  _G.Coop = C
  C.visit = { wanted = true, key = "B" }
  local saveSFO = _G.StaticFindObject
  local IS = { IsValid = function() return true end, ActionMappings = {}, AddActionMapping = function(self, m) self.ActionMappings[#self.ActionMappings + 1] = { ActionName = { ToString = function() return m.ActionName.name end } } end }
  local answers = { [0] = "K", [1] = "J" }
  local IMM = { IsValid = function() return true end, GetPlayerActionMappingStatic = function(_, pc, action, grp) return { Key = { KeyName = { ToString = function() return answers[grp] end } } } end }
  _G.StaticFindObject = function(p) if p == "/Script/Engine.Default__InputSettings" then return IS elseif p == "/Script/AutoSettingsInput.Default__InputMappingManager" then return IMM end; return nil end
  _G.FName = function(s) return { name = s, ToString = function() return s end } end
  assert(loadfile(FILE))()
  local V = C.visit
  -- the exact lines the plugin wrote in the game (s8d, s8g)
  local A = '[/Script/AutoSettingsInput.InputMappingManager]\r\nPlayerInputOverrides=(PlayerId="0",BasePresetTag=(TagName=""),bNullBasePreset=False,MappingOverrides=(MappingGroups=((ActionMappings=((ActionName="CoopVisit",bCtrl=True,Key=K),(ActionName="Army",bCtrl=True,Key=V))),(ActionMappings=((ActionName="CoopVisit",Key=J))))),PlayerKeyGroup=(TagName=""))\r\n'
  local o = V.parseOverrides(A)
  check(o[0] and o[0].key == "K" and o[0].ctrl and not o[0].shift and not o[0].alt and not o[0].cmd, "group 0: CoopVisit K with Ctrl only (Army's Ctrl+V is not ours)")
  check(o[1] and o[1].key == "J" and not o[1].ctrl, "group 1: J without modifiers")
  local B = 'PlayerInputOverrides=(PlayerId="0",BasePresetTag=(TagName=""),bNullBasePreset=False,MappingOverrides=(MappingGroups=),PlayerKeyGroup=(TagName=""))\n'
  check(next(V.parseOverrides(B)) == nil, "no overrides: nothing")
  local Cx = 'PlayerInputOverrides=(PlayerId="1",MappingOverrides=(MappingGroups=((ActionMappings=((ActionName="CoopVisit",bShift=True,Key=Q))))))\n' ..
    'PlayerInputOverrides=(PlayerId="0",MappingOverrides=(MappingGroups=((ActionMappings=((ActionName="Army",Key=O))),(ActionMappings=((ActionName="CoopVisit",bShift=True,bAlt=True,Key=L))))))\n'
  local o2 = V.parseOverrides(Cx)
  check(o2[0] == nil and o2[1] and o2[1].key == "L" and o2[1].shift and o2[1].alt and not o2[1].ctrl, "only the local player's line (PlayerId 0); group 1 Shift+Alt+L; group 0 none of ours")
  check(next(V.parseOverrides(nil)) == nil and next(V.parseOverrides("garbage((")) == nil, "no file or a broken line: nothing")
  -- the poll: Ctrl+K needs Ctrl (either side); J needs nothing and fires with Ctrl held too
  local down, held = nil, {}
  local pc = { WasInputKeyJustPressed = function(_, k) return k.KeyName.name == down end, IsInputKeyDown = function(_, k) return held[k.KeyName.name] == true end }
  V.game = { pc = function() return pc end, profileText = function() return A end }
  local function press(k, h) down = k; held = h or {}; V.akT = nil; local r = V.keyFn(C.s); down = nil; held = {}; return r end
  check(press("K") == false, "Ctrl+K bound: K alone does not walk")
  check(press("K", { LeftControl = true }) == true and press("K", { RightControl = true }) == true, "K with the left or the right Ctrl walks")
  check(press("J") == true and press("J", { LeftControl = true }) == true, "J (no modifier) walks, also with Ctrl held (as the engine's own actions)")
  check(V.keyFrom == "Ctrl+K, J", "the key setting read as \"Ctrl+K, J\" (" .. tostring(V.keyFrom) .. ")")
  V.game.profileText = function() return nil end
  check(press("K") == true, "the profile file not readable: no modifiers known, K walks")
  answers = { [0] = "M", [1] = "J" }
  V.game.profileText = function() return A end
  check(press("M") == true, "the file names K for group 0 but the plugin says M: the file's Ctrl is not taken for M")
  _G.StaticFindObject = saveSFO
end

print("== 14. a half-built row comes out again; the title screen's (idle) step adds the row")
do
  local A0 = 0xA000
  local function obj(cls, t) A0 = A0 + 8; t = t or {}; t.cls = cls; t.a = A0
    t.IsValid = function(self) return not self.dead end
    t.GetAddress = function(self) return self.a end
    t.GetClass = function(self) return { GetFName = function() return { ToString = function() return self.cls end } end } end
    t.GetFName = function(self) return { ToString = function() return self.name or self.cls end } end
    t.IsA = function(self, c) return c ~= nil and c.name == "UserWidget" and self.user == true end
    t.GetOuter = function(self) return self.outer end
    return t
  end
  local function text(s) return { ToString = function() return s end } end
  local function slot() return { Padding = { Left = 0, Top = 0, Right = 0, Bottom = 0 }, Size = { Value = 1, SizeRule = 0 }, HorizontalAlignment = 0, VerticalAlignment = 0,
    SetPadding = function() end, SetSize = function() end, SetHorizontalAlignment = function() end, SetVerticalAlignment = function() end } end
  local refuseSlot = false
  local function named(refuse) local s = obj("NamedSlot"); s.SetContent = function(self, w) if refuse and refuseSlot then return end; self.content = w end; s.GetContent = function(self) return self.content end; return s end
  local function list(nRows)
    local L = obj("VerticalBox", { name = "bindings_vb", kids = {} })
    L.GetChildrenCount = function(self) return #self.kids end
    L.GetChildAt = function(self, i) return self.kids[i + 1] end
    L.AddChild = function(self, w) self.kids[#self.kids + 1] = w; w.Slot = slot(); return w.Slot end
    L.RemoveChild = function(self, w) for i, k in ipairs(self.kids) do if k == w then table.remove(self.kids, i); return true end end; return false end
    for i = 1, nRows do local r = obj("InputRow_C", { Label = text("settings_" .. i), Index = 0, user = true }); r.Slot = slot(); r.GetVisibility = function() return 0 end; L.kids[#L.kids + 1] = r end
    local img = obj("Image", { name = "Image_13" }); img.Slot = slot(); L.kids[#L.kids + 1] = img
    return L
  end
  local CLS = { ["/Script/UMG.UserWidget"] = { name = "UserWidget" } }
  CLS["/Game/UI/Settings/InputRow.InputRow_C"] = { name = "row" }
  CLS["/Game/UI/StyledAutoSettings/Input/StyledActionMapping.StyledActionMapping_C"] = { name = "map" }
  CLS["/Script/UMG.Default__WidgetBlueprintLibrary"] = { IsValid = function() return true end, Create = function(_, q, cls, pc)
    if cls.name == "row" then local w = obj("InputRow_C", { Index = 7, user = true, Content1 = named(false), Content2_1 = named(true) }); w.AlternatingRowBorder = { SetVisibility = function() end }; w.SetVisibility = function() end; return w end
    return obj("StyledActionMapping_C", { user = true }) end }
  CLS["/Script/Engine.Default__KismetTextLibrary"] = { IsValid = function() return true end, Conv_StringToText = function(_, s) return text(s) end }
  local gi = obj("MLGameInstance")
  local pcAsked = {}
  CLS["/Script/Engine.Default__GameplayStatics"] = { IsValid = function() return true end, GetPlayerController = function(_, ctx) pcAsked[#pcAsked + 1] = ctx; if ctx == gi then return { IsValid = function() return true end } end; return nil end }
  CLS["/Script/Engine.Default__InputSettings"] = { IsValid = function() return true end, ActionMappings = {}, AddActionMapping = function(self, m) self.ActionMappings[#self.ActionMappings + 1] = { ActionName = { ToString = function() return m.ActionName.name end } } end }
  local menu = obj("mainMenu_widget_C", { user = true })
  local L1 = list(31)
  local q1 = obj("quickSettings_C", { user = true, bindings_vb = L1, outer = obj("WidgetTree", { outer = menu }) })
  local saveFAO, saveSFO = _G.FindAllOf, _G.StaticFindObject
  local saveFFO = _G.FindFirstOf
  _G.FindAllOf = function(n) if n == "quickSettings_C" then return { q1 } end; return {} end
  _G.FindFirstOf = function(n) if n == "MLGameInstance" then return gi end; return nil end
  _G.StaticFindObject = function(p) return CLS[p] end
  _G.FName = function(s) return { name = s, ToString = function() return s end } end
  local reg
  local C = { s = { name = "host", role = "idle", on = false, stats = {} }, register = function(n, m) reg = m; return m end,
    api = { valid = function(o) return type(o) == "table" and (o.IsValid == nil or o:IsValid()) end, un = function(o) return o end, now = function() return T end, log = function() end, send = function() end } }
  _G.Coop = C
  C.visit = { wanted = true, key = "B" }
  assert(loadfile(FILE))()
  refuseSlot = true
  check(reg and type(reg.idle) == "function", "the module has an idle step (title screen, solo game)")
  reg.idle(C.s, 0)
  check(#L1.kids == 32 and not C.visit.realGame.ourRow(L1), "a row whose second key widget did not go in is taken out again")
  check((C.visit.rowFails[L1.a] or 0) == 1, "and counted as a refusal")
  refuseSlot = false
  C.visit.rowT = nil
  reg.idle(C.s, 0)
  check(#L1.kids == 33 and C.visit.realGame.ourRow(L1) ~= nil, "the next idle pass adds it (title screen: no lord pawn, the game instance's player)")
  check(pcAsked[#pcAsked] == gi, "the player controller was asked through the game instance")
  check(#CLS["/Script/Engine.Default__InputSettings"].ActionMappings == 1, "the idle step added our action (the row's key widgets show its key)")
  _G.FindAllOf, _G.StaticFindObject, _G.FindFirstOf = saveFAO, saveSFO, saveFFO
end

print("== 12. the start nudged out of a building or a tight fence (the lead's real-input check 1)")
do
  -- boxes the camera's trace type (1) sees; the ground (type 0) is everywhere at height 0
  local boxes = {}
  local function segHits(x0, y0, x1, y1, b)
    local t0, t1 = 0, 1; local dx, dy = x1 - x0, y1 - y0
    for _, e in ipairs({ { -dx, x0 - b[1] }, { dx, b[2] - x0 }, { -dy, y0 - b[3] }, { dy, b[4] - y0 } }) do
      local p, q = e[1], e[2]
      if p == 0 then if q < 0 then return false end
      else local t = q / p; if p < 0 then if t > t1 then return false elseif t > t0 then t0 = t end else if t < t0 then return false elseif t < t1 then t1 = t end end end
    end
    return true
  end
  local traces = 0
  local KSLfake = { IsValid = function() return true end, LineTraceSingle = function(_, ctx, s, e, ch, _, ignore, _, hit)
    traces = traces + 1
    if ch == 0 then hit.ImpactPoint = { Z = 0 }; return true end
    for _, b in ipairs(boxes) do if segHits(s.X, s.Y, e.X, e.Y, b) then return true end end
    return false end }
  local saveSFO = _G.StaticFindObject
  _G.StaticFindObject = function(p) if p == "/Script/Engine.Default__KismetSystemLibrary" then return KSLfake end; return nil end
  local C = { s = { name = "host", role = "host", on = true, stats = {} }, register = function() end,
    api = { valid = function(o) return type(o) == "table" and (o.IsValid == nil or o:IsValid()) end, un = function(o) return o end, now = function() return T end, log = function() end, send = function() end } }
  _G.Coop = C
  C.visit = { wanted = true, key = "B" }
  assert(loadfile(FILE))()
  local G = C.visit.realGame
  local ctx = {}
  local x, y, z, moved = G.openGround(nil, ctx, 0, 0, 0, {})
  check(moved == 0 and x == 0 and y == 0, "open ground: the walker stays right under the camera")
  boxes = { { 140, 1000, -1000, 1000 } }                       -- one wall 1.4 m away on one side
  x, y, z, moved = G.openGround(nil, ctx, 0, 0, 0, {})
  check(moved == 0, "one wall 1.4 m away: not cramped, stays (" .. tostring(moved) .. ")")
  boxes = { { -500, 500, -500, 500 } }                          -- a 10 m building around the place
  traces = 0
  x, y, z, moved = G.openGround(nil, ctx, 0, 0, 0, {}, 0)
  local outside = math.abs(x) > 500 or math.abs(y) > 500
  check(moved > 0 and outside and not G.viewBlocked(ctx, x, y, z, 0, {}) and G.blockedDirs(ctx, x, y, z, 150, {}) == 0, string.format("inside a 10 m building: moved %d cm to %.0f,%.0f, outside it, the view clear", moved, x, y))
  check(moved <= 1000 and traces < 500, "found within 10 m, " .. traces .. " traces")
  -- the lead's pen: a fence 2.5 m around the place (thin), the camera 3 m behind looking along yaw 22: the line to it
  -- crosses the fence although nothing is within 1.5 m
  boxes = { { -255, -245, -255, 255 }, { 245, 255, -255, 255 }, { -255, 255, -255, -245 }, { -255, 255, 245, 255 } }
  check(G.blockedDirs(ctx, 0, 0, 0, 150, {}) == 0 and G.viewBlocked(ctx, 0, 0, 0, 22, {}), "inside the pen: nothing within 1.5 m, but the head-to-camera line meets the fence")
  x, y, z, moved = G.openGround(nil, ctx, 0, 0, 0, {}, 22)
  check(moved > 0 and not G.viewBlocked(ctx, x, y, z, 22, {}) and G.blockedDirs(ctx, x, y, z, 150, {}) == 0, string.format("inside the pen: moved %d cm to %.0f,%.0f, the view clear", moved, x, y))
  C.visit.cfg.nudge = false
  x, y, z, moved = G.openGround(nil, ctx, 0, 0, 0, {})
  check(moved == 0 and x == 0, "switched off (cfg.nudge = false): stays")
  C.visit.cfg.nudge = true
  boxes = { { -3000, 3000, -3000, 3000 } }                      -- inside something larger than the search: stays
  x, y, z, moved = G.openGround(nil, ctx, 0, 0, 0, {})
  check(moved == 0 and x == 0, "nothing open within 10 m: the place under the camera stays")
  _G.StaticFindObject = saveSFO
end

print(string.format("== %d passed, %d failed", pass, fail))
if fail > 0 then error("desk test failed") end
