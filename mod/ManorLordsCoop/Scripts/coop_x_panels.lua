-- Manor Lords Co-op: open panels follow another player's change (lane 69, 2026-11-17).
--
-- THE FAULT (seen live): the host set a field's priority; the value reached a friend at once, but the friend, who had
-- that field's panel open, kept seeing the old value until he closed and opened the panel again. The game's panels fill
-- their controls when they open and redraw on the local player's own clicks; in the plain game nobody else changes a
-- value under the player's eyes. The mod writes the remote value into the building and told no panel.
--
-- ONE ENTRY: C.panels.touched(kind, target). Its only callers are the places where A REMOTE PLAYER'S ACTION WAS APPLIED
-- on this copy (listed below). It is never called for the local player's own action (those are never applied here: the
-- town module drops its own lines), and never for background values (stock, totals, upkeep, approval, deaths): those
-- come through coop_facts.lua and the state lines, which do not call it, and the game redraws them itself.
--   callers, caught by a hook on the player's control (the line is a player's click by construction):
--            coop_town.lua T.finish (every town action applied: setters, fields, families, placements, the x_town /
--            x_build / x_lord actions; NOT the lines a module makes itself, e.g. the people module's "people" lines
--            for houses the game builds: 36 an hour in the lead's idle hour, lane_s21_0/long4_five_copies).
--   callers, caught by comparing a value (a player's change, or, rarely, the host's GAME changing it):
--            coop.lua hostInbox (a friend's order applied on the host; the friend's speed watcher can send a speed the
--            game set, lane 16: "O:SPEED" redraws nothing); coop_x_army.lua (the host's squad name / spread out on a
--            friend, a retainer's name, looks or gear); coop_x_lord.lua setWar (the host's war list on a friend also
--            follows a war a challenge started on the host); coop_realm.lua take (perk, tax, policy, region name) and
--            a friend's claim laid on the host. None of these is a background value: each is a rare decision, and none
--            came up in the lead's hour with nobody acting (same logs: 0 realm, war or retinue lines taken).
--   the squad mirror on a friend (coop.lua: push / behaviour stance and skills of every squad, the AI's too, follow
--            the host's state) calls it only for a behaviour stance taken for one of the lord's own squads (S.mine):
--            SetBehaviourStance raises no redraw flag, and only a player sets that stance. The game's own
--            SetPushStance and SetSkillActive raise the army flag themselves, so those are left to the game.
--   kind: the action's name (town actions: "PRIO", "TRULE", ...; "O:<order>", "A:<what>", "R:<item>", "WAR", "RETINUE")
--   target: a building or region key as the line carries it ("type,x,y,z" / region tag), a building object, or nil
--
-- WHICH FUNCTION REDRAWS (read in the game's code and blueprint scripts; evidence in research/.../lanes/lane_s21_69/evidence.txt)
--   The lord (PawnCPP) has one "please redraw" flag per panel family, read and cleared in its own tick, which then
--   broadcasts a delegate the panels are bound to (game code 4b268e2..4b269f7):
--     shouldUpdateInventoryUI  -> OnInventoryUpdateRequested -> MLInventoryScreen::OnUpdateRequested (every building
--                                 panel) -> UpdateInventory(4) -> the panel's "Update Inventory Event": the same redraw the
--                                 panel's own Sleep button and upgrade make (keeps the chosen tab, no sound, no animation)
--     shouldUpdateStatUI       -> OnStatUpdateRequested: region panel (updateRegionDetails), lord panel
--     shouldUpdateArmyUI       -> OnArmyUpdateRequested: army panel, unit grid, unit stat panel, recruit cards
--     shouldUpdateArmyListUI   -> OnArmyListUpdateRequested: army panel's list
--     shouldUpdateClaimUI      -> OnClaimUpdateRequested: challenges / claims
--   The mercenary panel (MLMercenaryPanelWidget) binds its native RebuildMercenaryPanel to OnArmyUpdateRequested and to
--   an engine delegate (its construct, game code 4d75cf0): the army flag redraws it. The development tree is on no flag:
--   its own updateContents is called (tickDev below). The approval breakdown (WBP_Approval_C) redraws on the weather
--   master's OnUpdateDay, once a day, for every player's change as in the plain game: left as it is.
--   The game raises these itself after its own changes (assignFamily, EnableTargetStock, changeSilver, setPolicySigned,
--   SetPushStance, ...), but not after SetPriority and the panel-written fields, and never for a value written by a
--   script. Building panels: by default each open panel that shows the touched building (or a building of the touched
--   region) gets the game's own handler of that flag, MLInventoryScreen:OnUpdateRequested(), called here inside the town
--   module's quiet wrapper, so a control the redraw sets again is never taken for a click of this player. The other
--   families get their flag set; the game's tick does the rest.
--   P.cfg.inv: "request" (default, as above), "event" (UpdateInventory(0), the Sleep button's call), "flag" (the lord's
--   shouldUpdateInventoryUI: every open panel, from the game's tick), "off".
--
-- DO NOT DISTURB THE LOCAL PLAYER: no redraw within 0.5 s of this player's mouse press in a building panel or on an army
-- card (the panels' own OnPreviewMouseButtonDown, hooked: a note only), while any control of the panel holds the mouse
-- (a held button, a dragged slider: UWidget HasMouseCapture), while a drop-down of the panel is open (IsOpen), or while
-- a text box of the panel has the keyboard. The redraw waits and runs right after. At most one redraw per panel (per
-- flag) every 0.25 s; touches in between are one redraw. A conflict (this player edits a value another player changed):
-- the edit is the local player's action and is sent as usual; the host applies the lines in the order they arrive and
-- every copy ends with the host's last value; the panel shows that value at the first redraw after the edit ends.
--
-- SAFETY: nothing here keeps a widget across frames (only numbers: addresses and times); every widget is checked valid
-- before each use; game calls are wrapped in pcall; nothing runs while the core holds for a join or repair (C.hold), a
-- join is busy, or the host's lines are being read again (S.replay); a new world clears everything.
--
-- CONSOLE: Coop.panels.status()   Coop.panels.cfg.inv = "event"   Coop.panels.cfg.on = false   Coop.panels.n (counters)

local C = rawget(_G, "Coop")
if not (C and C.register and C.api) then return "coop_x_panels: load coop.lua first" end
local A = C.api
C.panels = C.panels or {}
local P = C.panels
P.version = "1"
P.cfg = P.cfg or {}
local DEFAULT = {
  on = true,
  inv = "request",       -- how a building panel is redrawn (see the head of this file)
  gap = 0.25,            -- at most one redraw per panel / per flag in this many seconds
  afterClick = 0.5,      -- no redraw this long after the local player's mouse press in a panel
  recheck = 0.1,         -- while a redraw waits, the open panels are looked at again this often (FindAllOf is not free)
  keepScroll = true,     -- put every scroll box of a redrawn panel back where it was
  maxNodes = 1500,       -- widgets looked at per panel for a held control, an open drop-down or a scroll box
  log = true,
}
for k, v in pairs(DEFAULT) do if P.cfg[k] == nil then P.cfg[k] = v end end

local valid = A.valid
local function addrOf(o) if o == nil then return nil end; local ok, a = pcall(function() return o:GetAddress() end); return ok and a or nil end

-- ---------------------------------------------------------------- what each kind of action may change on screen
-- inventory scope: "b" the building named by the target, "r" every panel of that building's (or that) region,
-- "all" every open building panel, false none. flags: the lord's redraw flags to raise. dev: the development tree
-- (developmentPanelTree_C: perk cards, policy cards, region name, trade summary) is redrawn too.
local FLAG = { stat = "shouldUpdateStatUI", army = "shouldUpdateArmyUI", armylist = "shouldUpdateArmyListUI",
               claim = "shouldUpdateClaimUI" }
local KINDS = {
  -- region settings shown in building tabs (trade, limits, taxes) and in the region panel
  PLIM = { inv = "r" }, PUNLIM = { inv = "r" }, CLIM = { inv = "r" }, CUNLIM = { inv = "r" },
  TRULE = { inv = "r", dev = true }, TTARGET = { inv = "r", dev = true }, TPART = { inv = "r", dev = true }, TGLOBAL = { inv = "r", dev = true },
  TAX = { inv = "r", flags = { "stat" }, dev = true }, TROUTE = { inv = "r", flags = { "stat" }, dev = true },
  -- families move between workplaces of one region: every workplace panel of the region
  ADDW = { inv = "r" }, REMW = { inv = "r" }, FAMS = { inv = "r" }, REASSIGN = { inv = "r" },
  -- lord's decisions
  CHALLENGE = { inv = false, flags = { "claim", "stat" } }, SETTLE = { inv = false, flags = { "claim", "stat" } },
  LETTER = { inv = false, flags = { "stat" } }, CONTINUE = { inv = false },
  WAR = { inv = false, flags = { "stat", "claim" } },
  RETHIRE = { inv = "b", flags = { "army", "armylist" } },
  RETINUE = { inv = "b", flags = { "army" } },
  -- region values of the realm module
  ["R:perk"] = { inv = false, flags = { "stat" }, dev = true }, ["R:tax"] = { inv = "all", flags = { "stat" }, dev = true },   -- taxes: the manor's taxes tab too
  ["R:policy"] = { inv = false, flags = { "stat" }, dev = true }, ["R:name"] = { inv = false, flags = { "stat" }, dev = true },
  ["R:claim"] = { inv = false, flags = { "claim", "stat" } },
  -- army orders and the host's word on squads
  ["O:SPEED"] = { inv = false },
  ["O:RAISE"] = { inv = false, flags = { "army", "armylist" } }, ["O:HIRE"] = { inv = false, flags = { "army", "armylist" } },
  ["O:REMOVE"] = { inv = false, flags = { "army", "armylist" } }, ["O:HOME"] = { inv = false, flags = { "army", "armylist" } },
  ["O:RALLY"] = { inv = false, flags = { "army", "armylist" } },
}
local ARMY_DEFAULT = { inv = false, flags = { "army" } }          -- any other "O:" or "A:" kind (stances, skills, names)
local TOWN_DEFAULT = { inv = "b" }                                -- any other town action: its building (else every panel)
local function kindOf(kind)
  local k = KINDS[kind]; if k then return k end
  if type(kind) == "string" and (kind:sub(1, 2) == "O:" or kind:sub(1, 2) == "A:") then return ARMY_DEFAULT end
  return TOWN_DEFAULT
end
P.kindOf = kindOf

-- ---------------------------------------------------------------- the core: pure, testable without the game
-- (tests/panels/t_panels.lua drives it with stand-in probes; the game drives it from tick())
-- decide: may a waiting redraw run now?  "go", or the reason it waits
function P.decide(now, lastRedraw, clickT, busy, cfg)
  cfg = cfg or P.cfg
  if clickT and now - clickT < cfg.afterClick then return "click" end
  if busy then return "busy" end
  if lastRedraw and now - lastRedraw < cfg.gap then return "gap" end
  return "go"
end

function P.reset()
  P.q = { b = {}, r = {}, all = false, t0 = nil }    -- building panels waiting: building and region addresses
  P.want = {}                                          -- panel address -> time the redraw was first wanted
  P.qf = {}                                            -- flag family -> time first wanted
  P.last = {}                                          -- panel address -> time of its last redraw
  P.lastF = {}                                         -- flag family -> time of its last redraw
  P.qd = nil                                           -- the development tree: time a redraw was first wanted
  P.lastD = nil                                        -- the development tree: time of its last redraw
  P.lookD = nil
  P.lookAt = -100                                      -- when to look at the open panels again (while a redraw waits)
  P.waitLog = {}
end
if not P.q then P.reset() end
P.clickT = P.clickT or -100
P.n = P.n or { touched = 0, inv = 0, invAll = 0, flags = {}, waits = {}, dropped = 0, errors = 0 }

-- ---------------------------------------------------------------- the entry
local function held() local S = C.s; return (not S) or (not S.on) or C.hold or S.replay ~= nil or (C.join and C.join.state ~= nil) end

local function resolve(target)
  if target == nil then return nil, nil end
  if type(target) == "string" then
    local T = rawget(C, "town"); if not T then return nil, nil end
    if T.api and T.api.findBkey then
      local okB, b = pcall(T.api.findBkey, target)
      if okB and b and valid(b) then return b, nil end
    end
    if T.findR then
      local okR, r = pcall(T.findR, target)
      if okR and r and valid(r) then return nil, r end
    end
    return nil, nil
  end
  if valid(target) then return target, nil end
  return nil, nil
end

-- A remote player's action was applied on this copy. Records only: the redraw is decided in tick().
function P.touched(kind, target)
  if not P.cfg.on then return end
  if held() then P.n.dropped = P.n.dropped + 1; return end
  P.n.touched = P.n.touched + 1
  local k = kindOf(kind)
  local now = os.clock()
  for _, f in ipairs(k.flags or {}) do if FLAG[f] and not P.qf[f] then P.qf[f] = now end end
  if k.dev and not P.qd then P.qd = now end
  if k.inv then
    local q = P.q
    q.t0 = q.t0 or now
    if k.inv == "all" then q.all = true
    else
      local okR, b, r = pcall(resolve, target)
      if not okR then b, r = nil, nil end
      if b then
        if k.inv == "r" then local okG, rg = pcall(function() return b.Region end); local ra = okG and valid(rg) and addrOf(rg); if ra then q.r[ra] = true end end
        local ba = addrOf(b); if ba then q.b[ba] = true end
      elseif r then
        local ra = addrOf(r); if ra then q.r[ra] = true end
      else
        q.all = true                -- the target is not a building or region here (a placement, a villager): every panel
      end
    end
  end
end

-- the local player pressed a mouse button in a panel (hook callbacks: a note only, no game call)
function P.localInput() P.clickT = os.clock() end

-- ---------------------------------------------------------------- reading the open building panels
local function shown(w)
  local v = 0; pcall(function() v = w:GetVisibility() end)
  return v ~= 1 and v ~= 2                               -- ESlateVisibility 1 Collapsed, 2 Hidden
end
-- every open building panel, as plain numbers plus the widget for use in this frame only
local function openPanels()
  local out = {}
  local ok, list = pcall(FindAllOf, "Inventory_C")
  if not ok or type(list) ~= "table" then return out end
  for i = 1, #list do                                    -- a Lua list made by UE4SS, not a game array
    local w = list[i]
    if valid(w) and shown(w) then
      local okO, open = pcall(function()
        if w:IsInViewport() then return true end
        local p = w:GetParent(); return p ~= nil and p:IsValid()   -- a closed panel was taken off its parent (DestroyInventoryWindow)
      end)
      local okB, b = pcall(function() return w.building end)
      if okO and open and okB and valid(b) then
        local okG, rg = pcall(function() return b.Region end)
        out[#out + 1] = { w = w, a = addrOf(w), ba = addrOf(b), ra = (okG and valid(rg)) and addrOf(rg) or nil }
      end
    end
  end
  return out
end

-- one pass over a panel's widgets: is a control in use, and where are its scroll boxes
local function look(root)
  local res = { busy = nil, scroll = {} }
  local n, maxn = 0, P.cfg.maxNodes
  local function go(w, d)
    if n >= maxn or d > 40 or res.busy then return end
    if not valid(w) then return end
    n = n + 1
    if not shown(w) then return end
    local okN, cname = pcall(function() return w:GetClass():GetFName():ToString() end)
    cname = okN and cname or ""
    local okM, cap = pcall(function() return w:HasMouseCapture() end)
    if okM and cap then res.busy = "held " .. cname; return end
    if cname:find("ComboBox", 1, true) then
      local okC, open = pcall(function() return w:IsOpen() end)
      if okC and open then res.busy = "open " .. cname; return end
    elseif cname:find("EditableText", 1, true) then
      local okK, kf = pcall(function() return w:HasKeyboardFocus() end)
      if okK and kf then res.busy = "typing " .. cname; return end
    elseif cname:find("ScrollBox", 1, true) then
      local okS, off = pcall(function() return w:GetScrollOffset() end)
      if okS and type(off) == "number" then res.scroll[#res.scroll + 1] = { w = w, off = off } end
    end
    local okK, cnt = pcall(function() return w:GetChildrenCount() end)
    if okK and type(cnt) == "number" then
      for i = 0, cnt - 1 do                              -- GetChildAt(0 .. count-1): never past the end
        local okA, c = pcall(function() return w:GetChildAt(i) end)
        if okA and c then go(c, d + 1) end
      end
      return
    end
    local okC, c = pcall(function() return w:GetContent() end)
    if okC and c and valid(c) then go(c, d + 1); return end
    -- (lane 69, game run 2026-11-18) only a blueprint widget ("..._C", not the game's MD_ wrappers) has a widget tree:
    -- asking a plain Image for one ended the game (EXCEPTION_ACCESS_VIOLATION reading 0xffffffffffffffff, two copies)
    if cname:sub(-2) ~= "_C" or cname:sub(1, 3) == "MD_" then return end
    local okT, r = pcall(function() return w.WidgetTree.RootWidget end)
    if okT and r and valid(r) then go(r, d + 1) end
  end
  go(root, 0)
  res.nodes = n
  return res
end

local function quiet(fn)
  local T = rawget(C, "town")
  if T and T.quiet then return pcall(T.quiet, fn) end
  return pcall(fn)
end

local function redrawPanel(S, p, scroll)
  local m = P.cfg.inv
  local ok, e = quiet(function()
    if m == "event" then p.w:UpdateInventory(0) else p.w:OnUpdateRequested() end
  end)
  if P.cfg.keepScroll and scroll then
    for _, s in ipairs(scroll) do
      if valid(s.w) then pcall(function() s.w:SetScrollOffset(s.off) end) end
    end
  end
  if not ok then P.n.errors = P.n.errors + 1; A.log("PANELS redraw of a building panel failed: %s", tostring(e)) end
  return ok
end

local function wait(why)
  P.n.waits[why] = (P.n.waits[why] or 0) + 1
end

-- ---------------------------------------------------------------- tick
local function matches(p, q)
  if q.all then return true end
  if p.ba and q.b[p.ba] then return true end
  if p.ra and q.r[p.ra] then return true end
  return false
end

local function tickInv(S, now)
  local q = P.q
  local queued = q.t0 ~= nil
  if not queued and next(P.want) == nil then return end
  if P.cfg.inv == "off" then P.q = { b = {}, r = {}, all = false }; P.want = {}; return end
  -- the local player is pressing in a panel: nothing to look at yet
  local d0 = P.decide(now, nil, P.clickT, false)
  if d0 ~= "go" then wait(d0); return end
  if not queued and now < P.lookAt then return end
  P.lookAt = now + P.cfg.recheck
  if P.cfg.inv == "flag" then
    -- the game's own flag: every open panel is redrawn by the lord's tick
    if now - (P.lastF.inv or -100) < P.cfg.gap then wait("gap"); return end
    local ok = pcall(function() S.p1.shouldUpdateInventoryUI = true end)
    P.lastF.inv = now; P.q = { b = {}, r = {}, all = false }; P.want = {}
    if ok then P.n.inv = P.n.inv + 1; if P.cfg.log then A.log("PANELS building panels: the lord's redraw flag set (another player's change)") end end
    return
  end
  local panels = openPanels()
  if queued then
    for _, p in ipairs(panels) do if p.a and matches(p, q) and not P.want[p.a] then P.want[p.a] = q.t0 end end
    if q.all then P.n.invAll = P.n.invAll + 1 end
    P.q = { b = {}, r = {}, all = false }
  end
  local open = {}
  for _, p in ipairs(panels) do if p.a then open[p.a] = p end end
  for a, t0 in pairs(P.want) do
    local p = open[a]
    if not p then P.want[a] = nil                       -- closed meanwhile: it fills itself when it opens again
    else
      local lk = look(p.w)
      local d = P.decide(now, P.last[a], P.clickT, lk.busy ~= nil)
      if d == "go" then
        P.want[a] = nil; P.last[a] = now
        if redrawPanel(S, p, lk.scroll) then
          P.n.inv = P.n.inv + 1
          if P.cfg.log then A.log("PANELS building panel redrawn (another player's change, %.0f ms after it, %d widgets looked at)", (now - t0) * 1000, lk.nodes or 0) end
        end
      else
        wait(d)
        -- a redraw held back by the gap is due at a known moment: look again then, not a recheck later
        if d == "gap" then local due = P.last[a] + P.cfg.gap; if due < P.lookAt then P.lookAt = due end end
        if d == "busy" and P.cfg.log and now - (P.waitLog[a] or -100) > 5.0 then P.waitLog[a] = now; A.log("PANELS a redraw waits: the local player is using the panel (%s)", tostring(lk.busy)) end
      end
    end
  end
end

local function tickFlags(S, now)
  if next(P.qf) == nil then return end
  for f, t0 in pairs(P.qf) do
    local d = P.decide(now, P.lastF[f], P.clickT, false)
    if d == "go" then
      P.qf[f] = nil; P.lastF[f] = now
      local ok = pcall(function() S.p1[FLAG[f]] = true end)
      if ok then
        P.n.flags[f] = (P.n.flags[f] or 0) + 1
        if P.cfg.log then A.log("PANELS %s redraw asked of the game (another player's change, %.0f ms after it)", f, (now - t0) * 1000) end
      else P.n.errors = P.n.errors + 1 end
    else wait(d) end
  end
end

-- The development tree (a full screen, one at a time): its own updateContents, the event its region buttons call
-- (byte code @2953: SetRegion of the perk overview, the region's name, the perk overview's updateContents ->
-- updatePerkCardStates, the region stats, updatePolicies -> each policy card's updateSignedAndAvailable, the trade
-- view, the production panel). No sound or animation on that path (playOpenAnimation is separate). It is bound to
-- no flag of the lord: its policy cards redraw only on their own click (shouldUpdatePolicyView -> updatePoliciesEvent).
local DEV = "developmentPanelTree_C"
local function tickDev(S, now)
  if not P.qd then return end
  local d = P.decide(now, P.lastD, P.clickT, false)
  if d ~= "go" then wait(d); return end
  if now < (P.lookD or -100) then return end
  P.lookD = now + P.cfg.recheck
  local ok, list = pcall(FindAllOf, DEV)
  if not ok or type(list) ~= "table" then P.qd = nil; return end
  local open = {}
  for i = 1, #list do
    local w = list[i]
    if valid(w) and shown(w) then
      local okO, isOpen = pcall(function() if w:IsInViewport() then return true end; local p = w:GetParent(); return p ~= nil and p:IsValid() end)
      if okO and isOpen then open[#open + 1] = w end
    end
  end
  if #open == 0 then P.qd = nil; return end            -- not open: it fills itself when it opens
  local looks = {}
  for i, w in ipairs(open) do
    looks[i] = look(w)
    if looks[i].busy then wait("busy"); return end       -- the player is using it: wait, all or nothing
  end
  local t0 = P.qd; P.qd = nil; P.lastD = now
  for i, w in ipairs(open) do
    local okR, e = quiet(function() w:updateContents() end)
    if P.cfg.keepScroll then for _, s in ipairs(looks[i].scroll) do if valid(s.w) then pcall(function() s.w:SetScrollOffset(s.off) end) end end end
    if okR then
      P.n.dev = (P.n.dev or 0) + 1
      if P.cfg.log then A.log("PANELS development tree redrawn (another player's change, %.0f ms after it)", (now - t0) * 1000) end
    else P.n.errors = P.n.errors + 1; A.log("PANELS redraw of the development tree failed: %s", tostring(e)) end
  end
end

-- the panels' own mouse-press functions: hooked for a note of the moment (registered from tick, retried every 2 s)
local PRESS = {
  "/Game/UI/Development_Tree/developmentPanelTree.developmentPanelTree_C:OnMouseButtonDown_0",
  "/Game/ManorLords/UI/Widgets/Widgets_Inventory/Inventory.Inventory_C:OnPreviewMouseButtonDown",
  "/Game/UI/HUD/W_HUD_ArmyUnitCardV2.W_HUD_ArmyUnitCardV2_C:OnPreviewMouseButtonDown",
}
local function ensureHooks()
  if os.clock() - (P.hookT or -10) < 2.0 then return end
  P.hookT = os.clock()
  _G.__coop_panel_hooks = _G.__coop_panel_hooks or {}
  local reg = _G.__coop_panel_hooks
  for _, path in ipairs(PRESS) do
    if not reg[path] then
      local ok, pre, post = pcall(RegisterHook, path, function()
        local Cc = rawget(_G, "Coop"); local Pp = Cc and rawget(Cc, "panels")
        if Pp and Pp.localInput then Pp.localInput() end
      end)
      if ok then reg[path] = { pre, post }; A.log("PANELS hook on %s", path) end
    end
  end
end

local function tick(S, clock)
  if not P.cfg.on then return end
  if held() or not valid(S.p1) then
    if P.q.t0 or next(P.want) or next(P.qf) or P.qd then P.n.dropped = P.n.dropped + 1 end
    P.reset(); return
  end
  ensureHooks()
  local now = os.clock()
  local ok, e = pcall(tickInv, S, now); if not ok then P.n.errors = P.n.errors + 1; P.lastErr = tostring(e) end
  ok, e = pcall(tickFlags, S, now); if not ok then P.n.errors = P.n.errors + 1; P.lastErr = tostring(e) end
  ok, e = pcall(tickDev, S, now); if not ok then P.n.errors = P.n.errors + 1; P.lastErr = tostring(e) end
end

C.register("panels", { onWorld = function(S) P.reset() end, tick = tick })

function P.status()
  local f = {}; for k, v in pairs(P.n.flags) do f[#f + 1] = k .. " " .. v end
  local w = {}; for k, v in pairs(P.n.waits) do w[#w + 1] = k .. " " .. v end
  local nw = 0; for _ in pairs(P.want) do nw = nw + 1 end
  return string.format("panels %s (%s, building panels: %s) | touched %d, building panel redraws %d (every panel %d), development tree %d, flags: %s | waits: %s | waiting %d | dropped while holding %d | errors %d %s",
    P.version, P.cfg.on and "on" or "off", tostring(P.cfg.inv), P.n.touched, P.n.inv, P.n.invAll, P.n.dev or 0, table.concat(f, ", "),
    table.concat(w, ", "), nw, P.n.dropped, P.n.errors, P.lastErr or "")
end

return "coop_x_panels " .. P.version .. " loaded"
