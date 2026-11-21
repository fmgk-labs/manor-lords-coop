-- Manor Lords Co-op: town building panels, lane 1 (session 21). Loaded after coop_town.lua; uses its api.
-- Evidence for every action here: research/2026-11-10-game-probe/lanes/lane_s21_1/ (the lane's report, probes, log excerpts)
local C = _G.Coop; local T = C.town; local X = T.api
if not X then return "coop_x_town: the town module's api is missing" end
local A = C.api
local int, enc, dec, valid, un, addrOf = X.int, X.enc, X.dec, X.valid, X.un, X.addrOf

-- ================================================================ FUEL: the fuel reserve of a house (plus / minus)
-- The panel's blueprint writes the building's byte stockFuelFor (measured on the host: 0 -> 1 -> 2 -> 1; nothing was
-- sent). Same pattern as OVERSTOCK: the handler names the building, the field is read a tick later.
local FUEL = "/Game/UI/Inventory/fuelStocks.fuelStocks_C:BndEvt__fuelStocks_"
X.hook(FUEL .. "MinusButton_K2Node_ComponentBoundEvent_6_OnClicked__DelegateSignature", { "FUEL" }, X.seeWidget("FUEL"))
X.hook(FUEL .. "PlusButton_K2Node_ComponentBoundEvent_7_OnClicked__DelegateSignature", { "FUEL" }, X.seeWidget("FUEL"))
X.fieldAction("FUEL", function(b) return tostring(int(b.stockFuelFor)) end,
  function(S, b, v) b.stockFuelFor = int(v); return nil end)

-- ================================================================ THRESH: the farmhouse's threshing spinner (lane 29)
-- The farmhouse panel shows the threshing tab (W_InventoryTab_Threshing_C) under its work-area tab. The spinner's handler
-- writes the building's secondaryPriority itself (StringToInt of the value; measured 0 -> 2 -> 1, nothing else changed,
-- nothing sent: lane_s21_29 out/h1_measures.txt). Same pattern as FUEL, with one guard: the tab's BP_Update shows the
-- value with Spinner:SelectValue, which runs the same handler (counted: every panel show and refresh = one handler call
-- and one BP_Update, a press = one handler call and no BP_Update). The BP_Update hook runs right after the handler's own
-- (both when they return), so a record followed at once by BP_Update is the panel showing its value: dropped.
local THR = X.WI .. "W_InventoryTab_Threshing.W_InventoryTab_Threshing_C:"
T.thrUpd = T.thrUpd or -1
X.hook(THR .. "BP_Update", { "THRESH" }, function(self) T.thrUpd = os.clock(); return nil end)
X.hook(THR .. "BndEvt__Inventory_DefaultSpinner_K2Node_ComponentBoundEvent_14_SpinnerSelectionChanged__DelegateSignature", { "THRESH" },
  function(self)
    local w = self:get(); if not valid(w) then return nil end
    local b = w.building; if not valid(b) then return nil end
    return { k = "THRESH", obj = b, addr = addrOf(b), t0 = os.clock() }
  end)
do
  local d = X.fieldAction("THRESH", function(b) return tostring(int(b.secondaryPriority)) end,
    function(S, b, v) b.secondaryPriority = int(v); return nil end)
  local r0 = d.ready
  d.ready = function(S, rec)
    if rec.t0 and T.thrUpd >= rec.t0 and T.thrUpd - rec.t0 < 0.05 then return nil, "the tab showed its own value (no choice of the player)" end
    return r0(S, rec)
  end
end

-- ================================================================ ERASE: the "erase crops" button of a field
-- The button calls the game's own eraseCrops(erasePlowing) on the field. Relative: pressing twice is two actions.
X.setter("ERASE", "SMBuildingMaster", "eraseCrops", "b", "press", "lane_s21_1", true)

-- ================================================================ TRAINREG: the pack station's destination region
-- The planner's region drop-down calls changeTrainConnectionRegion(uniqueRegionID). The line carries the region's
-- tag (the name every other region action uses), each copy looks up its own id for it; "-" = no destination.
local function regionById(S, id)
  local arr = S.eng.regions
  for i = 1, #arr do
    local r = un(arr[i])
    if valid(r) then local ok, rid = pcall(function() return r:getRegionUniqueID() end); if ok and rid == id then return r end end
  end
  return nil
end
X.hook(X.P .. "SMBuildingMaster:changeTrainConnectionRegion", { "TRAINREG" }, X.seeObj("TRAINREG", "i"))
-- (the id itself differs between copies: the same region was 154019 on the host and 154356 on the friend)
X.def { name = "TRAINREG", status = "console2", ref = "lane_s21_1", argt = "i", abs = true,
  ready = function(S, rec)
    local b = rec.obj; if not valid(b) then return nil, "building gone" end
    if not X.owned(b) then return nil, "not the lord's" end
    local id = int(rec.args[1]); local r = regionById(S, id)
    local key = r and T.rkey(r) or ("#" .. id)
    if T.isEcho("TRAINREG", rec.addr, key) then return nil, "echo" end   -- (lane 81) the same region a replay just set
    return X.bkeyOf(rec.snap) .. " " .. key
  end,
  apply = function(S, job)
    local b = X.findBkey(job.f[1]); if not b then return "retry:building not found" end
    local key = job.f[2] or "-"; local id
    if key:sub(1, 1) == "#" then id = int(key:sub(2))
    else local r = T.findR(key); if not r then return "retry:region not found" end; id = int(r:getRegionUniqueID()) end
    b:changeTrainConnectionRegion(id)
    X.touch(b, T.defs.TRAINREG, key)
    return "ok"
  end }

-- ================================================================ VNAME: renaming a villager (the name box of a person in the People tab)
-- The entry's blueprint writes the unit's DisplayName (measured on the host: 'Hanns' -> 'Lane One'; nothing was
-- sent). A villager is named by region, family number and place in the family, as families are everywhere else in
-- the mod; the last name this copy knew travels too (may be empty) and a mismatch is logged, not refused.
--   VNAME <region> <family> <member> <'new name> <'name before, if known>
local function memberOf(S, u)
  local fid = int(u.workerFamilyID); local ua = addrOf(u)
  local arr = S.eng.regions
  for i = 1, #arr do
    local r = un(arr[i])
    if valid(r) and X.owned(r) then
      local ok, j = pcall(function()
        local wf = r.workerFamilies
        if fid < 0 or fid >= #wf then return nil end
        local m = wf[fid + 1].familyMembers
        for k = 1, #m do if addrOf(un(m[k])) == ua then return k end end
        return nil
      end)
      if ok and j then return r, fid, j end
    end
  end
  return nil
end
-- Measured (two copies): the hooks run when the blueprint has already written the name, and the box's "text changed"
-- handler writes it too, on every key (the first 12 characters). So the old name cannot be read in a hook: a first
-- version that took it there sent nothing for a short new name ("Soak 1": old and new read equal). And a commit also
-- fires when the box only loses focus. Rule now: a commit is sent when typing was seen since the last commit, or when
-- the name differs from the last one this copy sent or wrote for that villager; never when it equals that one. A
-- player who types and then restores the old name sends one line that changes nothing.
T.vnames = T.vnames or {}          -- address -> the last name this copy sent or wrote
T.vtyped = T.vtyped or {}          -- address -> typing seen since the last commit
local UE = "/Game/UI/Inventory/Lists/W_UnitEntry.W_UnitEntry_C:"
X.hook(UE .. "BndEvt__PersonEntry_EditableName_K2Node_ComponentBoundEvent_2_OnEditableTextChangedEvent__DelegateSignature",
  { "VNAME" }, function(self)
    local w = self:get(); if not valid(w) then return nil end
    local u = w.unit; if not valid(u) then return nil end
    local a = addrOf(u); if a then T.vtyped[a] = true end
    return nil
  end)
X.hook(UE .. "BndEvt__LivestockEntry_EditableName_K2Node_ComponentBoundEvent_0_OnEditableTextCommittedEvent__DelegateSignature",
  { "VNAME", "ANAME" }, function(self)
    local w = self:get(); if not valid(w) then return nil end
    local u = w.unit; if not valid(u) then return nil end
    local a = addrOf(u); local typed = a and T.vtyped[a] or false
    if a then T.vtyped[a] = nil end
    -- (lane 27) an animal (it has a building it is kept at, and no family): ANAME below
    local animal = false; pcall(function() animal = int(u.workerFamilyID) < 0 end)
    return { k = animal and "ANAME" or "VNAME", obj = u, addr = a, typed = typed }
  end)
X.def { name = "VNAME", status = "press2", ref = "lane_s21_1",
  ready = function(S, rec)
    local u = rec.obj; if not valid(u) then return nil, "villager gone" end
    local name = u.DisplayName:ToString()
    local known = T.vnames[rec.addr]
    if known == name then return nil, "name unchanged" end
    if not rec.typed and known == nil then return nil, "no typing seen" end
    local r, fid, j = memberOf(S, u)
    if not r then return nil, "not a member of one of the lord's families (animals and soldiers are not carried)" end
    T.vnames[rec.addr] = name
    return string.format("%s %d %d '%s '%s", T.rkey(r), fid, j, enc(name), enc(known or ""))
  end,
  apply = function(S, job)
    local r = T.findR(job.f[1]); if not r then return "retry:region not found" end
    local fid, j = int(job.f[2]), int(job.f[3])
    local name, old = dec((job.f[4] or "'"):sub(2)), dec((job.f[5] or "'"):sub(2))
    local wf = r.workerFamilies
    if fid < 0 or fid >= #wf then return "family " .. fid .. " does not exist here" end
    local m = wf[fid + 1].familyMembers
    if j < 1 or j > #m then return "family " .. fid .. " has no member " .. j .. " here" end
    local u = un(m[j]); if not valid(u) then return "villager gone" end
    local have = u.DisplayName:ToString()
    if old ~= "" and have ~= old and have ~= name then A.log("TOWN VNAME: family %d member %d is called '%s' here, '%s' on the sender's copy", fid, j, have, old) end
    u.DisplayName = name
    if u.DisplayName:ToString() ~= name then return "the name could not be written" end
    local a = addrOf(u); if a then T.vnames[a] = name; T.vtyped[a] = nil end
    return "ok"
  end }

-- ================================================================ ANAME: renaming an animal (lane 27)
-- The same name box (W_LivestockEntry_C, a W_UnitEntry_C) lists animals; its blueprint writes the animal's
-- DisplayName as it does a villager's. An animal has no family (workerFamilyID -1): it is named by the building whose
-- list holds it (SMBuildingMaster.animals: a stable, a house's backyard, the livestock trader; measured: an ox that
-- works at a logging camp has that camp as animalAssignedTo but is listed by its stable) and its place in that list.
-- The count of the list travels too: when the two copies' lists differ in length the place may name another animal,
-- so the line is refused there (logged).
--   ANAME <building> <place> <count> <'new name> <'name before, if known>
local function animalPlace(b, u)
  local arr = b.animals; local n = #arr; local ua = addrOf(u)
  for k = 1, n do if addrOf(un(arr[k])) == ua then return k, n end end
  return nil, n
end
local function animalHome(S, u)
  for _, f in ipairs({ "Home", "animalAssignedTo" }) do
    local ok, b = pcall(function() return u[f] end)
    if ok and valid(b) and X.owned(b) then local okP, j, n = pcall(animalPlace, b, u); if okP and j then return b, j, n end end
  end
  local arr = S.eng.buildingArr
  for i = 1, #arr do
    local b = un(arr[i])
    if valid(b) and X.owned(b) then local okP, j, n = pcall(animalPlace, b, u); if okP and j then return b, j, n end end
  end
  return nil
end
X.def { name = "ANAME", status = "see lane_s21_27", ref = "lane_s21_27",
  ready = function(S, rec)
    local u = rec.obj; if not valid(u) then return nil, "animal gone" end
    local name = u.DisplayName:ToString()
    local known = T.vnames[rec.addr]
    if known == name then return nil, "name unchanged" end
    if not rec.typed and known == nil then return nil, "no typing seen" end
    local b, j, n = animalHome(S, u); if not b then return nil, "the animal is in no list of the lord's buildings" end
    T.vnames[rec.addr] = name
    return string.format("%s %d %d '%s '%s", X.bkeyOf(X.bident(b)), j, n, enc(name), enc(known or ""))
  end,
  apply = function(S, job)
    local b = X.findBkey(job.f[1]); if not b then return "retry:building not found" end
    local j, n = int(job.f[2]), int(job.f[3])
    local name, old = dec((job.f[4] or "'"):sub(2)), dec((job.f[5] or "'"):sub(2))
    local arr = b.animals; local have = #arr                  -- read the length first: a read past the end grows a list
    if have ~= n then return string.format("the building keeps %d animals here, %d on the sender's copy: not named", have, n) end
    if j < 1 or j > have then return "no animal " .. j .. " here" end
    local u = un(arr[j]); if not valid(u) then return "animal gone" end
    local cur = u.DisplayName:ToString()
    if old ~= "" and cur ~= old and cur ~= name then A.log("TOWN ANAME: animal %d of %s is called '%s' here, '%s' on the sender's copy", j, job.f[1], cur, old) end
    u.DisplayName = name
    if u.DisplayName:ToString() ~= name then return "the name could not be written" end
    local a = addrOf(u); if a then T.vnames[a] = name; T.vtyped[a] = nil end
    return "ok"
  end }

-- ================================================================ CONTINUE: "continue" on the victory or defeat screen (lane 27)
-- The button's graph (read in the game's blueprint dump) sets the main UI's mode back, un-pauses
-- (setGamePausedInclVamp), sets the game speed and moves the camera to the player's region. Each copy's game decides
-- by itself that the game is won or lost (the screen opens with the game paused); the host's pause rules every copy.
-- So "continue" on any copy goes to the host, which presses its own continue button when its screen shows one; every
-- copy that shows the screen presses its own as well. A copy that shows no such screen does nothing. The other
-- button (game_over_continue_button_1) only leaves to the main menu (OpenLevel): each player's own business.
local MAINUI = "/Game/UI/HUD/MainUICPP.MainUICPP_C:"
local CONT = "BndEvt__MainUICPP_game_over_continue_button_K2Node_ComponentBoundEvent_25_OnButtonReleasedEvent__DelegateSignature"
-- shown = the button and every parent up to the main UI are neither collapsed nor hidden (measured: the button's own
-- flag stays "visible" all game; its panel C_GameSummary is collapsed except while the screen shows)
local function gameOverUI()
  for _, w in ipairs(FindAllOf("MainUICPP_C") or {}) do
    if valid(w) then
      local ok, shown = pcall(function()
        local x = w.game_over_continue_button
        if not valid(x) then return false end
        for _ = 1, 30 do
          local v = x:GetVisibility(); if v == 1 or v == 2 then return false end
          local p = x:GetParent(); if not valid(p) then break end
          x = p
        end
        return true
      end)
      if ok and shown then return w end
    end
  end
  return nil
end
X.hook(MAINUI .. CONT, { "CONTINUE" }, function(self) return { k = "CONTINUE" } end)
X.def { name = "CONTINUE", status = "see lane_s21_27", ref = "lane_s21_27", rel = true,
  ready = function(S, rec) return "-" end,
  apply = function(S, job)
    local w = gameOverUI()
    -- no such screen on this copy (its game did not end, or its player continued already): nothing to press. On the
    -- host that is not refused: the friend's own game already runs on, and the host's speed rules every copy.
    if not w then A.log("TOWN CONTINUE: no victory or defeat screen shown on this copy: nothing pressed"); return "ok" end
    T.quiet(function() w[CONT](w) end)
    return "ok"
  end }

-- ================================================================ field priority (the plus / minus of a field's panel)
-- Like the construction tab's arrows, the field panel writes buildPriority itself and calls nothing (measured on the
-- host: 4 -> 5, nothing sent). Its handler is hooked and the value goes out as the existing PRIO line.
X.hook(X.WI .. "W_Inventory_FieldWidget.W_Inventory_FieldWidget_C:BndEvt__Inventory_fieldPriorityPlusMinus_K2Node_ComponentBoundEvent_1_priorityChanged__DelegateSignature",
  { "PRIO" }, function(self)
    local w = self:get(); if not valid(w) then return nil end
    local b = w.building; if not valid(b) then return nil end
    return { k = "PRIO", obj = b, addr = addrOf(b), late = "buildPriority" }
  end)

C.register("x_town", { onWorld = function() T.vnames = {}; T.vtyped = {} end })

-- ================================================================ a combo box the PANEL fills is not the player choosing
-- FAULT found by lane 16 (2026-11-12, host and friend, nothing pressed): when the trade tab of a trading post or a
-- livestock trader is opened, the tab fills its combo boxes, each combo box runs its "selection changed" handler, and
-- the handler calls Region:changeTradeRule with the value the region already has. Opening the panels of the test town
-- on the friend sent "TRULE hof 15,2" (twice), "TRULE hof 17,0" and "TRULE hof 72,1", and the host applied all four as
-- the friend's actions. With equal copies that changes nothing; when a copy's value differs from the host's (a change
-- still on its way, or drift), opening a panel pushes that copy's value over the host's.
-- The handler's second argument says who selected: ESelectInfo 0 key, 1 navigation, 2 mouse click, 3 "direct" = set
-- by code. Measured: the three calls made on opening the tab all carried 3. The setter's hook runs before the
-- handler's own (the handler is a blueprint function: its hook runs when it RETURNS), so the two are paired by
-- order: every setter record takes the number of the handler call it is inside of (T.comboSeq), and the handler's
-- hook, when that call returns, writes down how the selection was made and moves the number on. A record whose
-- handler call was "direct" is dropped in the tick. A record made outside any combo handler (a replay, another
-- button) has no entry and is sent as before; so is the player's own selection (types 0 to 2), also when the panel
-- refills its other combo boxes in the same instant, because those are other handler calls with other numbers.
-- The pack-train planner's combo boxes (MULE_SELL, MULE_BUY, TRAINREG) are the same widgets. Read and measured by lane 29
-- (coop_test_rich): the goods boxes' handlers act only for SelectionType 2 (a mouse click) and take the value from the
-- box's own selected option; for any other type they call nothing (so a fill by the panel, type 3, sends nothing, and
-- lane 26's presses with type 1 changed nothing). The region box's handler acts for every type but 3.
-- FAULT found by lane 21 (2026-11-12, host and friend, handler run with SelectionType 2 as a click): a choice of the
-- player was not sent at all, and the copy that chose kept a rule nobody else had. Traced (lane_s21_21/out/trace1.txt):
-- the handler calls changeTradeRule, and the combo box is then set again by code INSIDE that handler, which runs the
-- handler a second time (nested, type 3) and calls changeTradeRule once more:
--   changeTradeRule(6, 1); changeTradeRule(6, 1); handler returns type 3 (inner); handler returns type 2 (outer)
-- Both setter records took the same number, and the inner return (3) was written under it: both were dropped. Now the
-- setter calls that share a number are counted (T.comboCnt); the outermost return, the last of them, decides, and the
-- inner repeat is not sent a second time. A setter call outside any handler (nothing returns for it) must not join the
-- next handler call's group: a record made at another moment than the group's opens a new number.
local DIRECT = 3
T.comboSeq = T.comboSeq or 0; T.comboHow = T.comboHow or {}; T.comboCnt = T.comboCnt or {}; T.comboT = T.comboT or {}
local function comboSee(self, a1, a2)
  local okT, ty = pcall(function() return a2:get() end)
  T.comboHow[T.comboSeq] = okT and tonumber(ty) or -1
  T.comboHow[T.comboSeq - 300] = nil                         -- keep the last 300 only
  T.comboSeq = T.comboSeq + 1
  return nil
end
local UI = "/Game/UI/Inventory/"
for _, p in ipairs({
  UI .. "targetStockWidget_tradeTarget.targetStockWidget_tradeTarget_C:BndEvt__targetStockWidget_ComboBoxString_78_K2Node_ComponentBoundEvent_6_OnSelectionChangedEvent__DelegateSignature",
  UI .. "packTrainPlanner_connection.packTrainPlanner_connection_C:BndEvt__packTrainPlanner_ComboBoxString_29_K2Node_ComponentBoundEvent_0_OnSelectionChangedEvent__DelegateSignature",
  UI .. "packTrainPlanner_connection.packTrainPlanner_connection_C:BndEvt__packTrainPlanner_ComboBoxString_1_K2Node_ComponentBoundEvent_1_OnSelectionChangedEvent__DelegateSignature",
  UI .. "packTrainPlanner_InterRegion.packTrainPlanner_InterRegion_C:BndEvt__packTrainPlanner_ComboBoxString_29_K2Node_ComponentBoundEvent_0_OnSelectionChangedEvent__DelegateSignature",
  UI .. "packTrainPlanner_InterRegion.packTrainPlanner_InterRegion_C:BndEvt__packTrainPlanner_ComboBoxString_1_K2Node_ComponentBoundEvent_1_OnSelectionChangedEvent__DelegateSignature",
  UI .. "packTrainPlanner_InterRegion.packTrainPlanner_InterRegion_C:BndEvt__packTrainPlanner_InterRegion_ComboBox_region_K2Node_ComponentBoundEvent_2_OnSelectionChangedEvent__DelegateSignature",
}) do X.hook(p, { "TRULE", "MULE_SELL", "MULE_BUY", "TRAINREG" }, comboSee) end
for _, name in ipairs({ "TRULE", "MULE_SELL", "MULE_BUY", "TRAINREG" }) do
  local d = T.defs[name]
  if d and d.ready and not d.x16fill then
    d.x16fill = true
    for _, h in pairs(T.hooks) do
      if #h.defs == 1 and h.defs[1] == name and not h.x16fill then
        h.x16fill = true
        local see0 = h.see
        h.see = function(self, a1, a2, a3, a4)
          local rec = see0(self, a1, a2, a3, a4)
          if rec then
            -- a record made at another moment than the ones already under this number (a call outside any combo
            -- handler, for which no handler returns) closes that number: only calls of one handler call share one
            local now = os.clock()
            if T.comboCnt[T.comboSeq] and now - (T.comboT[T.comboSeq] or now) > 0.05 then T.comboSeq = T.comboSeq + 1 end
            local n = T.comboSeq; rec.cseq = n; T.comboT[n] = now; T.comboT[n - 300] = nil
            T.comboCnt[n] = (T.comboCnt[n] or 0) + 1; T.comboCnt[n - 300] = nil; rec.cnest = T.comboCnt[n]
          end
          return rec
        end
      end
    end
    local ready0 = d.ready
    d.ready = function(S, rec)
      if rec.cseq then
        -- k setter calls made before any handler returned are k nested handler calls (lane 21, below): the handler
        -- calls that return then are inner first, the outermost last. The outermost says who chose.
        local k = T.comboCnt[rec.cseq] or 1
        local how = T.comboHow[rec.cseq + k - 1]
        if how == nil and k > 1 then how = T.comboHow[rec.cseq] end
        if how == DIRECT then return nil, "the panel filled its own combo box (no choice of the player)" end
        if (rec.cnest or 1) > 1 and how ~= nil then return nil, "the panel set its own combo box again inside the player's choice (sent once)" end
      end
      return ready0(S, rec)
    end
  end
end

-- ================================================================ TRAINCON: a pack station's local route (lane 27)
-- The pack-train planner's two buttons (packTrainPlanner_connection_C Button_1 / Button_2) call
-- PawnCPP:changeActiveRTSTool (read in the blueprint dump); the player then clicks a building on the ground and the
-- game's native tool writes SMBuildingMaster.trainConnectionSource / trainConnectionTarget on the station. No
-- reflected function sets them. So: the tool's opening on a station is noted (hook), the station's two fields are
-- compared twice a second, and a change within 60 s of this player's tool on that station is sent; every other copy
-- writes the same two buildings into the fields.
--   TRAINCON <station> <source building or -> <target building or ->
T.trainTool = T.trainTool or {}            -- station address -> clock of this player's tool on it
T.trainSeen = T.trainSeen or {}            -- station address -> "source|target" last seen on this copy
X.hook(X.P .. "PawnCPP:changeActiveRTSTool", { "TRAINCON" }, function(self, a1, a2)
  local p = self:get(); if not X.isLocal(p) then return nil end
  local b = a2 and a2:get()
  if valid(b) then local okT, isB = pcall(function() return b:IsA(StaticFindObject("/Script/ManorLords.SMBuildingMaster")) end); if okT and isB then T.trainTool[addrOf(b)] = os.clock() end end
  return nil
end)
-- (lane 69) the planner's two "clear" buttons (Button_121, Button) set the station's source or target to none in the
-- blueprint (byte code: one object field := None each), with no tool and no game call: before, the change was sent only
-- within 60 s of this player's route tool on that station. A press now counts as this player's tool on its station.
-- The widget's own name for its station is not in the dumps: "building" (as fuelStocks_C and storageFilterGood_C call
-- it) is tried first; when no station is found that way, every pack station gets a 5 s window instead of 60 s.
local PTC = "/Game/UI/Inventory/packTrainPlanner_connection.packTrainPlanner_connection_C:BndEvt__packTrainPlanner_"
local function trainClearSee(self)
  local w = self:get(); if not valid(w) then return nil end
  local b
  for _, k in ipairs({ "building", "Building", "station", "trainStation" }) do
    local okB, x = pcall(function() return w[k] end)
    if okB and valid(x) then b = x; break end
  end
  if b then T.trainTool[addrOf(b)] = os.clock()
  else for _, s in ipairs(T.trainList or {}) do if valid(s) then T.trainTool[addrOf(s)] = os.clock() - 55.0 end end end
  return nil
end
X.hook(PTC .. "Button_121_K2Node_ComponentBoundEvent_2_OnButtonReleasedEvent__DelegateSignature", { "TRAINCON" }, trainClearSee)
X.hook(PTC .. "Button_K2Node_ComponentBoundEvent_3_OnButtonReleasedEvent__DelegateSignature", { "TRAINCON" }, trainClearSee)
-- "-" = no station (not connected); "?" = a station that has no usable name right now (a cleared actor): that line is
-- not sent (lane 76), it must not read as "not connected"
local function bk(b) if not valid(b) then return "-" end; local k = X.bkeyOf(X.bident(b)); return k == "-" and "?" or k end
local function trainPair(b) local s, t; pcall(function() s = b.trainConnectionSource; t = b.trainConnectionTarget end); return bk(s) .. "|" .. bk(t) end
local function trainPoll(S)
  -- the stations are looked up in the building list every 10 s only: the full walk every 0.5 s cost about 9 ms per
  -- second in the soak (lane 27, s7)
  local now = os.clock()
  if not T.trainList or now - (T.trainListT or -100) >= 10.0 then
    T.trainListT = now; T.trainList = {}
    local arr = S.eng.buildingArr
    for i = 1, #arr do local b = un(arr[i]); if valid(b) and b:GetType() == 112 and X.owned(b) then T.trainList[#T.trainList + 1] = b end end
  end
  for _, b in ipairs(T.trainList) do
    if valid(b) then
      local a = addrOf(b); local v = trainPair(b); local was = T.trainSeen[a]
      T.trainSeen[a] = v
      if was and was ~= v then
        local mine = T.trainTool[a] and os.clock() - T.trainTool[a] < 60.0
        -- (lane 81) no 2 s skip after a replay any more: the replay writes the pair it set into T.trainSeen itself, so
        -- its own change is never seen here; a change seen now is this player's tool (it was skipped for 2 s before)
        if mine and T.isOn("TRAINCON") then
          local s, t = v:match("^(.-)|(.*)$")
          T.emitAction(S, "TRAINCON", bk(b) .. " " .. s .. " " .. t)
        end
      end
    end
  end
end
T.trainPoll = trainPoll
X.def { name = "TRAINCON", status = "see lane_s21_27", ref = "lane_s21_27",
  ready = function(S, rec) return nil, "sent by the poll" end,
  apply = function(S, job)
    local b = X.findBkey(job.f[1]); if not b then return "retry:station not found" end
    local s = job.f[2] ~= "-" and X.findBkey(job.f[2]) or nil
    local t = job.f[3] ~= "-" and X.findBkey(job.f[3]) or nil
    if (job.f[2] ~= "-" and not s) or (job.f[3] ~= "-" and not t) then return "retry:building not found" end
    b.trainConnectionSource = s; b.trainConnectionTarget = t
    X.touch(b); T.trainSeen[addrOf(b)] = trainPair(b)
    return trainPair(b) == (job.f[2] .. "|" .. job.f[3]) and "ok" or "the fields did not take"
  end }

-- ================================================================ per-PC options that change play (lane 27)
-- The game's options live in each PC's game instance (MLGameInstance), not in the save. Read per option:
--   autoIdleJobs        idle families are put to work by the game itself: changes who works where on each copy, so a
--                       friend with another value drifts from the host. CARRIED: the host's value is set in memory on
--                       every friend's copy while it plays (never written to the friend's settings file by the mod).
--   noticeSquadSetting  the game pauses or slows when an enemy squad is seen: speed is the host's (coop.lua's speed
--                       watcher does not send a pause the game makes itself, and the host's state puts it back), so it
--                       only changes the friend's screen for a moment: per PC.
--   snap to roads, day-night cycle, tutorials, edge scrolling, grass, resource icons, zoom: screen and tool only: per PC.
--   triggerQuests       quests are the host's and pushed (coop_x_events.lua): per PC.
--   spoilage            comes from the game setup, which the save carries: the same on every copy after a join.
-- Message: host -> friends "P OPT idle <0|1>" when it changes and every 30 s.
local OPT = { last = nil, t = -100, poll = -100 }
local function gi() return FindFirstOf("MLGameInstance") end
C.register("options", {
  onWorld = function(S) OPT.last = nil; OPT.t = -100; OPT.poll = -100; T.trainSeen = {}; T.trainTool = {}; T.trainList = nil end,
  tick = function(S, clock)
    if C.hold then return end
    -- cost of this module's polls, logged once a minute (lane 27 soak: what the option and route polls cost)
    OPT.c0 = OPT.c0 or clock; OPT.cost = OPT.cost or 0
    if clock - OPT.c0 >= 60.0 then A.log("options: polls took %.2f ms per second (pack routes and options)", OPT.cost * 1000 / (clock - OPT.c0)); OPT.c0 = clock; OPT.cost = 0 end
    local t0 = os.clock()
    if clock - (OPT.trainT or 0) >= 0.5 then OPT.trainT = clock; pcall(trainPoll, S) end      -- TRAINCON above
    if S.role == "host" and clock - OPT.poll >= 1.0 then
      OPT.poll = clock                                    -- read once a second, not every frame
      local g = gi()
      if valid(g) then
        local v = g.autoIdleJobs and "1" or "0"
        if v ~= OPT.last or clock - OPT.t >= 30.0 then
          if OPT.last ~= nil and v ~= OPT.last then A.log("options: the host's auto idle jobs is now %s: sent to the friends", v) end
          OPT.last = v; OPT.t = clock; A.send("P OPT idle " .. v)
        end
      end
    end
    OPT.cost = OPT.cost + (os.clock() - t0)
  end,
  onMessage = function(S, from, kind, w, line)
    if kind ~= "P" then return false end
    if S.role ~= "friend" or from ~= "host" or w[4] ~= "OPT" then return true end
    if w[5] == "idle" and (w[6] == "0" or w[6] == "1") then
      local g = gi(); if not valid(g) then return true end
      local want = w[6] == "1"
      if (g.autoIdleJobs and true or false) ~= want then
        g.autoIdleJobs = want
        A.log("options: auto idle jobs set to the host's (%s) on this copy", w[6])
        if C.notify then C.notify("info", "Co-op: auto idle jobs follows the host's option (" .. (want and "on" or "off") .. ")") end
      end
    end
    return true
  end })

return "coop_x_town loaded"
