-- Manor Lords Co-op: what the player sees (plug-in module "ui").
-- Everything on screen uses the game's own pieces, so it looks like the game.
--   notices: the game's own event banner (PawnCPP:playEventMessage(type, first line, second line)), top centre, the
--            same one that shows "A New Message". The mod's other modules call Coop.notify(kind, text); this module
--            shows them one at a time.
--   menu:    a "Co-op" button in the game's menu column (the title menu and the pause menu are the same object,
--            mainMenu_widget_C, a column `main_buttons_vb` of W_MainMenuButton_C), placed above Quit Game. It opens a
--            panel made of the same button kind: the players with their state, then Invite Friends (host),
--            Keep a Copy of This Save and Leave Co-op (friend), Make Bug Report (everyone, also at the title screen;
--            lane 61: Coop.report()), Back.
--   status: banner and menu seen live on one copy (README sessions 17, 18; screens/s17-*, s18-*). The menu object only
--           exists while a menu is or has been open; it is never opened from here (OpenPauseMenu from Lua crashed).
--           Only in-place calls on existing widgets are used (Create, AddChild, RemoveChild, SetVisibility,
--           SetButtonText): each was tried separately.

local C = _G.Coop; local A = C.api
C.ui = C.ui or {}
local U = C.ui
U.queue = U.queue or {}
U.title = U.title or "Co-op"
local GAP = 2.5            -- seconds between two banners
local STALE = 30.0         -- a notice older than this is dropped (for example one queued just before a long load)
local COLLAPSED, VISIBLE = 1, 0
local CLICK = "/Game/UI/W_MaterialButton.W_MaterialButton_C:BndEvt__W_MaterialButton_Button_K2Node_ComponentBoundEvent_4_OnButtonClickedEvent__DelegateSignature"

local function valid(o) return A.valid(o) end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); return ok and a or nil end
local function log(fmt, ...) A.log("ui: " .. fmt, ...) end

-- ---------------------------------------------------------------- notices
function U.banner(text, second)
  local S = C.s; if not (S and valid(S.p1)) then return false end
  local ok, e = pcall(function() S.p1:playEventMessage(FName("coop"), tostring(text), tostring(second or U.title)) end)
  if not ok then log("banner failed: %s", tostring(e)) end
  return ok
end

C.onNotice = function(n)
  if not n or not n.text then return end
  -- "synced" replaces a waiting "syncing": after a resync only the result matters
  if n.kind == "synced" then for i = #U.queue, 1, -1 do if U.queue[i].kind == "syncing" then table.remove(U.queue, i) end end end
  U.queue[#U.queue + 1] = n
end

local function noticeTick(clock)
  if #U.queue == 0 then return end
  local n = U.queue[1]
  if clock - n.t > STALE then table.remove(U.queue, 1); return end
  if n.kind ~= "syncing" and clock - (U.last or 0) < GAP then return end   -- "syncing" is shown at once
  table.remove(U.queue, 1)
  if U.banner(n.text) then U.last = clock; U.shown = (U.shown or 0) + 1 end
end

-- ---------------------------------------------------------------- menu
local function context(S) return (S and valid(S.p1)) and S.p1 or FindFirstOf("MLGameInstance") end
local function text(s) return StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):Conv_StringToText(s) end

local function findMenu(clock)
  if valid(U.menu) then return U.menu end
  if clock - (U.menuT or -10) < 1.0 then return nil end
  U.menuT = clock; U.menu = nil
  for _, m in ipairs(FindAllOf("mainMenu_widget_C") or {}) do if valid(m) then U.menu = m end end
  return U.menu
end

local function makeButton(S, column, like, label)
  local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
  local pc = nil; pcall(function() pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(context(S), 0) end)
  local b = WBL:Create(context(S), like:GetClass(), pc)
  if not valid(b) then return nil end
  b:SetButtonText(text(label))
  local slot = column:AddChild(b)
  pcall(function() slot:SetHorizontalAlignment(like.Slot.HorizontalAlignment) end)
  return b
end

-- the click hook only notes which of our buttons was pressed; the work happens in the tick
local function ensureHook(clock)
  local H = rawget(_G, "__coop_ui_hook"); if not H then H = {}; _G.__coop_ui_hook = H end
  if H.done or (H.t and clock - H.t < 2.0) then return end
  H.t = clock
  local ok, e = pcall(RegisterHook, CLICK, function(self)
    local Ui = rawget(_G, "Coop") and _G.Coop.ui; if not Ui or not Ui.keys then return end
    local a = 0; pcall(function() a = self:get():GetAddress() end)
    local k = Ui.keys[a]; if k then Ui.clicked = k; Ui.clickT = os.clock() end
  end)
  if ok then H.done = true; log("menu click hook registered")
  elseif not H.said then H.said = true; log("menu click hook not registered yet (tried again every 2 s): %s", tostring(e)) end
end

local function players(S)
  local t = {}
  if not S then return t end
  local J = C.join or {}
  if S.role == "host" then
    t[#t + 1] = "You (host)  -  playing"
    for _, p in ipairs(S.peers or {}) do
      local st = nil                                             -- nobody has this place yet
      if J.expect and J.expect[p] then st = "connecting" end
      if st and (J.state == "loading" or J.state == "waiting") then st = (J.ready and J.ready[p]) and "ready" or "loading the save" end
      local heard = S.heard and S.heard[p]
      if heard and not J.state then st = (os.clock() - heard < 10.0) and "playing" or "disconnected" end
      if st then t[#t + 1] = ((S.display and S.display[p]) or p) .. "  -  " .. st end      -- an empty place shows no line
    end
  else
    local st = "connecting"
    if C.hold then st = "loading the save" elseif (S.stats.states or 0) > 0 then st = (S.lastStateT and os.clock() - S.lastStateT > 10.0) and "host not answering" or "playing" end
    t[#t + 1] = "Host  -  " .. ((S.stats.states or 0) > 0 and "playing" or "waiting")
    t[#t + 1] = "You  -  " .. st
  end
  return t
end

-- Keep a copy of the host's save (friend): the save this copy last loaded for the join is copied under the game's
-- own next free slot name ("saveGame_N"), because the game's Load Game screen lists only its own slot names
-- (autosave, quicksave, saveGame_0..149; read from the running game, README session 20). The friend then finds the
-- copy in the normal Load Game list.
local function keepCopy(S)
  local J = C.join or {}
  local name = J.lastLoaded
  if not name then return false, "No save from the host yet" end
  local dir; pcall(function() dir = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory():ToString() .. "SaveGames/" end)
  if not dir then return false, "Save folder not found" end
  local new
  for n = 0, 149 do
    local f = io.open(dir .. "saveGame_" .. n .. ".sav", "rb")
    if f then f:close() else new = "saveGame_" .. n; break end
  end
  if not new then return false, "No free save slot" end
  local n = 0
  for i, suffix in ipairs({ ".sav", "_descr.sav", ".png", "_coat_0.png", "_coat_1.png", "_coat_2.png", "_coat_3.png" }) do
    local f = io.open(dir .. name .. suffix, "rb")
    if f then
      local data = f:read("a"); f:close()
      -- the Load Game list shows the name stored inside the description file ("coop_join_1"): give the copy a name a
      -- player recognises. Same length (11 characters), so the file's layout does not change.
      if suffix == "_descr.sav" then data = data:gsub("coop_join_%d", "Co-op copy ") end
      local g = io.open(dir .. new .. suffix, "wb"); if g then g:write(data); g:close(); if i <= 2 then n = n + 1 end end
    end
  end
  if n < 2 then return false, "The copy could not be written" end
  return true, "Saved a copy. Find it under Load Game"
end

-- (lane 61) the text of the panel's "Make Bug Report" row: how the report went (the next opening says "Make Bug Report")
function U.reportNote(msg)
  for _, b in ipairs(U.rows or {}) do if valid(b) and (U.keys or {})[addr(b)] == "report" then pcall(function() b:SetButtonText(text(tostring(msg))) end) end end
end

local function closePanel()
  local Pn = U.panel; if not Pn then return end
  for _, s in ipairs(Pn.saved) do if valid(s[1]) then s[1]:SetVisibility(s[2]) end end
  for _, b in ipairs(Pn.rows) do if valid(b) then b:SetVisibility(COLLAPSED) end end
  U.panel = nil
end

local function openPanel(S)
  local m = U.menu; local quit = m.menuButton_quit; local col = quit:GetParent()
  U.rows = U.rows or {}                                      -- our row buttons, reused: text is set each time
  local want = {}
  if S and S.role == "idle" then
    -- not a co-op game. A co-op game is one started from here (title screen): that also settles who the host is.
    if not valid(S.p1) then
      want[#want + 1] = { "hostnew", "Host New Game" }; want[#want + 1] = { "hostsave", "Host From Save" }
      if U.hostNext then want[#want + 1] = { nil, "The next game you start is a co-op game" }; want[#want + 1] = { "hostcancel", "Cancel Hosting" } end
    else
      want[#want + 1] = { nil, "This is a solo game" }; want[#want + 1] = { nil, "Host a co-op game from the title screen" }
    end
  else
    for _, line in ipairs(players(S)) do want[#want + 1] = { nil, line } end
    if S and S.role == "host" then want[#want + 1] = { "invite", "Invite Friends" } end
    if S and S.role == "friend" then want[#want + 1] = { "copy", "Keep a Copy of This Save" }; want[#want + 1] = { "leave", "Leave Co-op" } end
  end
  want[#want + 1] = { "report", "Make Bug Report" }              -- (lane 61) title screen and in-game panel alike: Coop.report()
  want[#want + 1] = { "back", "Back" }
  local saved = {}
  for i = 0, col:GetChildrenCount() - 1 do
    local c = col:GetChildAt(i); local ours = U.keys[addr(c)] ~= nil or U.rowSet and U.rowSet[addr(c)]
    if not ours then saved[#saved + 1] = { c, c:GetVisibility() }; c:SetVisibility(COLLAPSED) end
  end
  if valid(U.btn) then saved[#saved + 1] = { U.btn, U.btn:GetVisibility() }; U.btn:SetVisibility(COLLAPSED) end
  U.rowSet = U.rowSet or {}
  local shown = {}
  for i, w in ipairs(want) do
    local b = U.rows[i]
    if not valid(b) then b = makeButton(S, col, quit, w[2]); U.rows[i] = b; if valid(b) then U.rowSet[addr(b)] = true end end
    if valid(b) then
      b:SetButtonText(text(w[2])); b:SetVisibility(VISIBLE); shown[#shown + 1] = b
      U.keys[addr(b)] = w[1] or "row"
    end
  end
  for i = #want + 1, #U.rows do if valid(U.rows[i]) then U.rows[i]:SetVisibility(COLLAPSED); U.keys[addr(U.rows[i])] = "row" end end
  U.panel = { saved = saved, rows = shown, t = os.clock(), np = #players(S) }
  U.opened = (U.opened or 0) + 1
  log("co-op panel opened (%d rows, %s)", #shown, S and S.role or "?")
end

local function act(S, key)
  if key == "coop" then openPanel(S); return end
  if key == "back" then closePanel(); return end
  if key == "hostnew" or key == "hostsave" then
    -- the next world this player starts (new game or a loaded save) is a co-op game with this player as host.
    -- The game's own New Game / Load Game screens are used as they are: the menu comes back and the player picks one.
    U.hostNext = true; closePanel()
    if valid(U.btn) then U.btn:SetButtonText(text("Co-op (hosting the next game)")) end
    log("host: the next game started on this copy is a co-op game (%s)", key)
    U.openKey = key; U.openT = os.clock()                 -- the game's own screen is opened in a later tick, not inside this click
    return
  end
  if key == "hostcancel" then
    U.hostNext = nil; U.openKey = nil; closePanel()
    if valid(U.btn) then U.btn:SetButtonText(text("Co-op")) end
    log("host: cancelled, the next game is a solo game")
    return
  end
  if key == "invite" then
    -- Steam's own invite window. The lobby (invite only, 8 players) is opened the first time it is needed.
    local st = C.steam and C.steam.on and C.steam.status()
    if not st then C.notify("info", "Steam joining needs the game started through Steam")
    elseif st.state == "off" then C.notify("info", "Steam joining is off: " .. tostring(st.reason or "Steam was not found"))
    elseif st.state == "hosting" then C.steam.invite(); log("invite: Steam's invite window asked for")
    elseif st.state == "idle" or st.state == "starting" then C.steam.host(); U.wantInvite = os.clock(); log("invite: opening the Steam lobby first")
    else C.notify("info", "Not possible while joining another game") end
    return
  end
  if key == "report" then
    -- (lane 61) the bug report: Coop.report() gathers it, the native piece zips it and opens its folder; the row says how it went
    local ok, msg = pcall(function() return C.report and C.report() or "not available" end)
    msg = ok and tostring(msg) or ("failed: " .. tostring(msg))
    log("bug report button: %s", msg)
    if msg:find("^making") then U.reportNote("Making the Bug Report...")
    elseif msg:find("^a bug report is being made") then U.reportNote("A Bug Report Is Being Made")
    elseif msg:find("without the native piece") then U.reportNote("Bug Report Saved (No Zip)")
    else U.reportNote("Bug Report Failed") end
    return
  end
  if key == "copy" then local ok, msg = keepCopy(S); C.notify("info", msg); log("keep a copy: %s", msg); return end
  if key == "leave" then
    -- leave the co-op game: tell Steam, stop the mod on this copy, and go back to the title screen (the world on this
    -- copy is the host's; staying in it alone would be a different game)
    closePanel(); log("leave: this copy goes back to idle")
    if C.steam and C.steam.on then pcall(C.steam.leave) end
    U.viaSteam = nil
    if C.setRole then C.setRole("idle", "idle", {}) else C.stop() end
    if U.titleMap then
      local gi = FindFirstOf("MLGameInstance")
      local ok, e = pcall(function() StaticFindObject("/Script/Engine.Default__GameplayStatics"):OpenLevel(gi, FName(U.titleMap), true, "") end)
      if not ok then log("leave: could not open the title screen: %s", tostring(e)) end
    end
    return
  end
end

-- Who this copy is, decided while the game runs (never from a file):
--   idle  -> host    the player chose "Host New Game" / "Host From Save" at the title screen and a world is now loaded
--   idle  -> friend  the Steam link says this player accepted an invite and the host gave it a place
--   host  -> idle    the hosted world is gone (back at the title screen) and no resync is running
--   friend-> idle    the Steam link is no longer in the host's game (the host ended it, or this player was removed)
local function roleTick(S, clock)
  if not S or not C.setRole then return end
  local inWorld = valid(S.p1) and valid(S.eng)
  if S.role == "friend" then if inWorld then U.frWorld = true; U.frNoT = nil end else U.frWorld = nil; U.frNoT = nil end
  local steam = C.steam and C.steam.on and C.steam.status() or nil
  if S.role == "idle" then
    if U.hostNext and inWorld then
      U.hostNext = nil
      C.setRole("host", "host", rawget(_G, "COOP_FRIEND_NAMES") or { "friend1", "friend2", "friend3", "friend4", "friend5", "friend6", "friend7" }); U.madeHost = true
      if valid(U.btn) then pcall(function() U.btn:SetButtonText(text("Co-op")) end) end
      C.notify("info", "Co-op game started. Invite friends from the menu")
    elseif steam and steam.state == "joined" and steam.slot then
      U.viaSteam = true; C.setRole("friend", "friend" .. steam.slot, {})
    end
  elseif S.role == "host" then
    local J = C.join or {}
    if inWorld or J.state or J.loading then U.noWorldT = nil
    else
      U.noWorldT = U.noWorldT or clock
      if clock - U.noWorldT > 5.0 and U.madeHost then U.noWorldT = nil; U.madeHost = nil; if steam then pcall(C.steam.leave) end; C.setRole("idle", "idle", {}) end
    end
  elseif S.role == "friend" and not inWorld and U.frWorld and not C.hold and not (C.join and C.join.loading) then
    -- this friend had the host's world and is now at the title screen without a load running: the player used the
    -- game's own "Main Menu" (or the level was left some other way). That is leaving the co-op game.
    U.frNoT = U.frNoT or clock
    if clock - U.frNoT > 3.0 then
      U.frNoT = nil; U.frWorld = nil; U.viaSteam = nil
      log("leave: the player went back to the title screen: this copy is idle again")
      if C.steam and C.steam.on then pcall(C.steam.leave) end
      C.setRole("idle", "idle", {})
    end
  elseif S.role == "friend" and U.viaSteam and steam and (steam.state == "idle" or steam.state == "off") then
    -- (lane 44) no longer in the host's Steam lobby (the host closed the game or left, or this player was removed):
    -- the one way out of a co-op game when the host is gone (coop_session.lua: notice, items off, main menu)
    if C.session and C.session.gone then U.viaSteam = nil; C.session.gone(S, "steam", steam.state .. " " .. tostring(steam.note or steam.reason or "")); return end
    U.viaSteam = nil; C.notify("info", "The co-op game ended")
    C.setRole("idle", "idle", {})
    if U.titleMap and inWorld then pcall(function() StaticFindObject("/Script/Engine.Default__GameplayStatics"):OpenLevel(FindFirstOf("MLGameInstance"), FName(U.titleMap), true, "") end) end
  end
end

local function menuTick(S, clock)
  ensureHook(clock)
  U.keys = U.keys or {}
  local okR, eR = pcall(roleTick, S, clock); if not okR then U.lastErr = "role: " .. tostring(eR) end
  -- "Invite Friends" was clicked before a lobby existed: open Steam's invite window as soon as the lobby is there
  if U.wantInvite and C.steam and C.steam.on then
    local st = C.steam.status()
    if st.state == "hosting" then U.wantInvite = nil; C.steam.invite(); log("invite: Steam's invite window asked for")
    elseif clock - U.wantInvite > 10.0 then U.wantInvite = nil; C.notify("info", "Steam did not open a lobby") end
  end
  -- Steam names instead of friend1..3 in notices and in the player list
  if S and S.role == "host" and C.steam and C.steam.on and clock - (U.namesT or 0) > 1.0 then U.namesT = clock; local ok, n = pcall(C.steam.names); if ok then S.display = n end end
  local m = findMenu(clock); if not m then return end
  local shown = false; pcall(function() shown = m:IsInViewport() end)
  if not shown then if U.panel then closePanel() end; return end
  local quit = m.menuButton_quit; if not valid(quit) then return end
  local col = quit:GetParent(); if not valid(col) then return end
  if not valid(U.btn) or addr(U.btn:GetParent()) ~= addr(col) then
    -- (re)build: a new menu object, or the first time. Our button goes in, then Quit is moved below it.
    U.rows = {}; U.rowSet = {}; U.keys = {}; U.panel = nil
    U.btn = makeButton(S, col, quit, "Co-op")
    if not valid(U.btn) then return end
    U.keys[addr(U.btn)] = "coop"
    local al = quit.Slot.HorizontalAlignment
    col:RemoveChild(quit); local slot = col:AddChild(quit); pcall(function() slot:SetHorizontalAlignment(al) end)
    pcall(function() m:RebuildNaviGrid() end)
    U.btnT = clock
    log("Co-op button added to the menu")
  end
  -- "Host New Game" / "Host From Save": run the menu's own handler of its New Game / Load Game button, so the game's own
  -- screens open exactly as after a click on those buttons (lane_u Q1). Title screen only.
  if U.openKey and clock - (U.openT or 0) > 0.15 then
    local k = U.openKey; U.openKey = nil
    if not (S and valid(S.p1)) then
      local ok, e = pcall(function()
        if k == "hostnew" then
          pcall(function() FindFirstOf("MLGameInstance").savefileToLoad = "" end)     -- a new world is one started with no save name
          m:BndEvt__mainMenu_widget_menuButton_newGame_K2Node_ComponentBoundEvent_0_OnClicked__DelegateSignature(m.menuButton_newGame)
        else
          m:BndEvt__mainMenu_widget_menuButton_loadGame_K2Node_ComponentBoundEvent_2_OnClicked__DelegateSignature(m.menuButton_loadGame)
        end
      end)
      log("host: the game's %s screen %s", k == "hostnew" and "New Game" or "Load Game", ok and "was opened" or ("could not be opened: " .. tostring(e)))
    end
  end
  -- A friend's copy never saves, and loading another save would leave the host's game: the pause menu does not offer
  -- either to a friend ("Keep a Copy of This Save" is in the co-op panel). A new menu object after leaving shows them again.
  if S and S.role == "friend" and valid(S.p1) and not U.panel then
    for _, name in ipairs({ "menuButton_saveGame", "menuButton_loadGame" }) do
      local b = m[name]
      if valid(b) and b:GetVisibility() ~= COLLAPSED then b:SetVisibility(COLLAPSED); pcall(function() m:RebuildNaviGrid() end) end
    end
  end
  if U.clicked then local k = U.clicked; U.clicked = nil; local ok, e = pcall(act, S, k); if not ok then log("menu action %s failed: %s", tostring(k), tostring(e)) end end
  -- our button exists but its clicks never arrive: say so once (a click on Co-op that does nothing)
  if valid(U.btn) and not (rawget(_G, "__coop_ui_hook") or {}).done and not U.saidNoHook and clock - (U.btnT or clock) > 10 then
    U.saidNoHook = true; log("the Co-op button is on screen but the click hook is still not registered")
  end

  -- keep the player lines fresh while the panel is open
  if U.panel and clock - U.panel.t > 1.0 and S and S.on and S.role ~= "idle" then
    U.panel.t = clock
    local now = players(S)
    if #now ~= (U.panel.np or #now) then closePanel(); openPanel(S)       -- a player came or went: lay the rows out again
    else for i, line in ipairs(now) do local b = U.rows[i]; if valid(b) then b:SetButtonText(text(line)) end end end
  end
end

-- Mercenary companies on offer. Each copy keeps its own list; it is equal after a join, and a hire by the host, by
-- another player or by a rival lord takes a company off the host's list only (session 21: the friend's hire window
-- still showed it; choosing it was refused and undone). The host tells its list; in a friend's hire window the card
-- of a company the host no longer offers is collapsed. Cards are the game's own (mercenaryCompanyCard_C in the
-- screen's mercenary_companies_HB, in the order of the offer list); nothing is added or re-ordered.
local function mercTick(S, clock)
  if not valid(S.p1) or not valid(S.eng) or C.hold then return end
  if S.role == "host" then
    if clock - (U.mercSendT or 0) < 2.0 then return end
    U.mercSendT = clock
    local ok, list = pcall(function()
      local t = {}; local a = S.eng.availableMercs
      for i = 1, #a do t[#t + 1] = a[i].Name:ToString() end
      table.sort(t); return #t > 0 and table.concat(t, ",") or "-"
    end)
    if ok and (list ~= U.mercSent or clock - (U.mercSentT or 0) > 6.0) then U.mercSent = list; U.mercSentT = clock; A.send("M " .. list) end
    return
  end
  if S.role ~= "friend" or not U.hostMercs or clock - (U.mercT or 0) < 0.2 then return end
  U.mercT = clock
  local screens = U.mercScreens
  local stale = not screens or #screens == 0
  if screens then for _, sc in ipairs(screens) do if not valid(sc) then stale = true end end end
  if stale then
    if clock - (U.mercFindT or -10) < 2.0 then return end
    U.mercFindT = clock; screens = {}
    for _, sc in ipairs(FindAllOf("mercenaryScreen_C") or {}) do if valid(sc) then screens[#screens + 1] = sc end end
    U.mercScreens = screens
  end
  local offers = S.eng.availableMercs
  for _, sc in ipairs(screens) do
    local open = false; pcall(function() open = sc:GetVisibility() ~= COLLAPSED and sc:GetVisibility() ~= 2 end)
    if open then
      local hb = sc.mercenary_companies_HB
      if valid(hb) then
        for i = 0, hb:GetChildrenCount() - 1 do
          local card = hb:GetChildAt(i)
          if valid(card) and card:GetVisibility() ~= COLLAPSED then
            -- the card's place in the row is its place in the offer list (its own `index` field reads 0 while shown)
            -- (a row with more cards than offers: no read past the end of the offer list, which would grow it)
            local okN, name = pcall(function() if i + 1 > #offers then return nil end; return offers[i + 1].Name:ToString() end)
            if okN and name and not U.hostMercs[name] then
              card:SetVisibility(COLLAPSED)
              U.mercHid = (U.mercHid or 0) + 1
              log("hire window: %s is no longer on offer on the host: its card is hidden", name)
            end
          end
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- the host's world held behind a screen (lane 24)
-- While the host has a full screen open, a friend's game stands still and shows the game's own "Game Paused" line;
-- the event banner of a notice is not drawn while the game stands (seen on background screenshots). So the words of
-- that line are changed for as long as the hold lasts, and put back afterwards.
local HOLD_TEXT = "Waiting for the host"         -- short: the line is as wide as "Game Paused" (a longer text was cut off, r6)
local function holdTick(S, clock)
  local want = S.role == "friend" and S.hostHold == true
  if want == (U.holdShown or false) and (not want or clock - (U.holdT or 0) < 2.0) then return end
  U.holdT = clock
  if want then
    if not valid(U.pauseLbl) then
      U.pauseLbl = nil
      for _, w in ipairs(FindAllOf("TextBlock") or {}) do
        local ok, t = pcall(function() return w:GetText():ToString() end)
        if ok and (t == "Game Paused" or t == HOLD_TEXT) then local okV, v = pcall(function() return w:IsVisible() end); if okV and v then U.pauseLbl = w; U.pauseOrig = (t == HOLD_TEXT) and (U.pauseOrig or "Game Paused") or t end end
      end
    end
    if valid(U.pauseLbl) then
      local ok = pcall(function() if U.pauseLbl:GetText():ToString() ~= HOLD_TEXT then U.pauseLbl:SetText(text(HOLD_TEXT)) end end)
      if ok and not U.holdShown then log("the pause line says: %s", HOLD_TEXT) end
      U.holdShown = ok
    end
  else
    if valid(U.pauseLbl) then pcall(function() U.pauseLbl:SetText(text(U.pauseOrig or "Game Paused")) end) end
    U.holdShown = false
  end
end

-- (lane 59) The menu, the Co-op button, the panel's rows and the pause line are widgets of the level they were found
-- in. They were kept for the whole session and called every frame (also while a level loads) with nothing but valid()
-- in between. Now they are dropped whenever the world this copy is attached to changes (a load, the title screen, a
-- new world) and found again; not when C.setRole attaches the SAME world again (the core's S.loads does not move):
-- the menu lives on then, and a second Co-op button would be added to it.
local function worldKey(S)
  local key = (S and S.eng) and ("w" .. tostring(S.loads)) or "none"     -- S.loads: loaded worlds, not C.setRole's attaches
  if key == U.wKey then return end
  U.wKey = key
  U.menu = nil; U.menuT = nil; U.btn = nil; U.rows = {}; U.rowSet = {}; U.keys = {}; U.panel = nil; U.pauseLbl = nil; U.holdShown = false
end
local M = {}
function M.onWorld(S) U.hostMercs = nil; U.mercScreens = nil; U.mercSent = nil; worldKey(S) end
function M.onMessage(S, from, kind, w, line)
  if kind ~= "M" then return false end
  if S.role == "friend" and from == "host" then
    local set = {}; for n in (w[4] or ""):gmatch("[^,]+") do if n ~= "-" then set[n] = true end end
    U.hostMercs = set
  end
  return true
end
function M.tick(S, clock)
  worldKey(S)
  noticeTick(clock)
  local okH, eH = pcall(holdTick, S, clock); if not okH and U.holdErr ~= tostring(eH) then U.holdErr = tostring(eH); log("hold line: %s", tostring(eH)) end
  local okM, eM = pcall(mercTick, S, clock); if not okM and U.mercErr ~= tostring(eM) then U.mercErr = tostring(eM); log("hire window: %s", tostring(eM)) end
  local ok, e = pcall(menuTick, S, clock); if not ok then U.lastErr = tostring(e) end
end
function M.idle(S, clock)                                   -- no world (the title screen), or an idle copy in a solo game
  worldKey(S)
  if S and valid(S.p1) then noticeTick(clock) end
  if not U.titleMap and clock - (U.titleT or 0) > 1.0 then  -- remember the title screen's level name, for "Leave Co-op"
    U.titleT = clock
    pcall(function()
      local gi = FindFirstOf("MLGameInstance"); local n = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetCurrentLevelName(gi, true):ToString()
      if n ~= "" and not FindFirstOf("RTSMultiEngineCPP"):IsValid() then U.titleMap = n; log("title screen level is %s", n) end
    end)
  end
  local ok, e = pcall(menuTick, S, clock); if not ok then U.lastErr = tostring(e) end
end

function U.status() return string.format("ui: %d notices shown, %d waiting, panel opened %d times, button %s, last error %s", U.shown or 0, #U.queue, U.opened or 0, tostring(valid(U.btn)), tostring(U.lastErr)) end

C.register("ui", M)
return "coop ui module loaded"
