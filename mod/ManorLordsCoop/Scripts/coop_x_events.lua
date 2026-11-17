-- Manor Lords Co-op: things the game rolls by itself (plug-in module "events", message kind "E").
-- Each copy's own game starts quests, raids, bandit camps and unrest for itself, so two copies differ unless one
-- decides. The host decides; this module pushes what the host has and carries a friend's answer back.
--
-- Who owns what (lane 5 decisions; evidence in research/2026-11-10-game-probe/lanes/lane_s21_5/report.md):
--   quests     The host owns the lord's three lists (running, offered, opportunities).
--              host -> friends   E Q <running> <offered> <opportunities>      when they change and every 30 s
--                                each a comma list of <name>:<region tag>, "-" = empty
--                                E DID <who> A|R <name>
--                                an answer was given on the host's copy (by the host or, relayed, by <who>)
--              friend -> host    E A <name> (first answer: accept)   E R <name> (second answer: refuse)
--              An offer the host has and a friend lacks is started there with the director's own
--              Director:startQuestFromPreset; an answer is replayed through the copy's own message widgets.
--   camps      The host owns the bandit camps (buildings of type 100 owned by the bandit lord).
--              host -> friends   E K <type@x,y~z>;...   ("-" = none) when the list changes and every 30 s
--              A camp gone on the host is removed on a friend's copy through the town module's own DEMOLISH (the
--              helper lord's demolish list), never with a direct SMBuildingMaster:demolish: see campGone below.
--              A camp the friend lacks: see campMake below.
--   owners     The host owns who holds each region (a rival lord winning a claim, rebels).
--              host -> friends   E O <tag>=<P|B|A<n>|->,...   when it changes and every 30 s
--   people     The host owns who the villagers are (names). host -> friends  E P ...  (see "people" below)
-- Re-loadable (state lives in Coop.events).

local C = rawget(_G, "Coop")
if type(C) ~= "table" or type(C.register) ~= "function" or type(C.api) ~= "table" then return "coop_x_events: load coop.lua first" end
local A = C.api
local un, valid = A.un, A.valid
local E = C.events or {}
C.events = E
E.version = "0.9"
E.on = E.on or {}
local DEFAULT_ON = {
  quests = true,       -- the host's quest lists are pushed and compared
  questStart = true,   -- a quest the host has is started on a friend's copy (Director:startQuestFromPreset)
  answers = true,      -- answers travel friend -> host -> every copy
  camps = true,        -- the host's bandit camps are pushed and compared
  campRemove = true,   -- a camp gone on the host is removed here: the town module's DEMOLISH through the helper lord (lane 12)
  campMake = true,     -- a camp the friend lacks is made here: the engine's own spawnBanditCamp, then moved to the host's place (5 of 5 in sessions 4 to 7)
  campRepair = true,   -- ... and when making or removing fails (or removing is switched off) the friend asks for a resync
  owners = true,       -- the host's region owners are pushed and compared
  ownerSet = true,     -- a region whose owner differs is given to the host's owner here (PawnCPP:finalizeClaim)
  people = true,       -- the host's villagers (name, role, age per family) are pushed and compared
  names = true,        -- a villager whose name differs takes the host's name (SMUnit.DisplayName)
  homes = true,        -- a family lives where it lives on the host (Region:SetFamilyHome)
  deaths = true,       -- a family member the host's family no longer has dies here too (SMUnit:just_die)
  vdeaths = true,      -- a villager who dies on the host is named at once (E PD) and dies here too (lane 24)
}
for k, v in pairs(DEFAULT_ON) do if E.on[k] == nil then E.on[k] = v end end
E.stats = E.stats or {}
E.S = nil                                              -- a hot reload: state is set up again, everything is told and judged again
local LISTS = { "quests", "proposedQuests", "questOpportunities" }
local POLL, KEY, CAMP_EVERY, OWNER_EVERY, PEOPLE_EVERY, CAMP_TYPE = 1.0, 30.0, 3.0, 2.0, 5.0, 100

local function log(fmt, ...) A.log("events: " .. fmt, ...) end
local function bump(k) E.stats[k] = (E.stats[k] or 0) + 1 end
local function enc(s) return (tostring(s):gsub("[^%w]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function dec(s) return (tostring(s):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); if ok then return a end end
local function rkey(r)
  local ok, k = pcall(function() return r.regionUniqueTag:ToString() end)
  if not ok or type(k) ~= "string" or k == "" or k == "None" then return nil end
  return (k:gsub("[^%w_%.]", "_"))
end
local function regionByKey(S, k)
  local arr = S.eng.regions
  for i = 1, #arr do local r = un(arr[i]); if valid(r) and rkey(r) == k then return r end end
end
-- a lord by facts that are the same on every copy (the world module's rule)
local function ownerCode(S, o)
  if not valid(o) then return "-" end
  if addr(o) == addr(S.p1) then return "P" end
  local okB, bandit = pcall(function() return o.isBandit end); if okB and bandit then return "B" end
  local okI, idx = pcall(function() return o:getPawnSetupIndex() end); if okI and type(idx) == "number" then return "A" .. idx end
  return "X"
end
local function pawnByCode(S, code)
  if code == "P" then return S.p1 end
  if code == "B" then for _, pw in ipairs(A.pawns()) do if valid(pw) and pw.isBandit then return pw end end; return nil end
  local i = tonumber((code or ""):match("^A(%-?%d+)$")); if not i then return nil end
  local ok, pw = pcall(function() return S.eng:getPawnBySetupIndex(i) end)
  if ok and valid(pw) then return pw end
end

-- ---------------------------------------------------------------- quests
local function qname(q) local ok, n = pcall(function() return q.Name:ToString() end); return (ok and type(n) == "string" and n ~= "") and n or nil end
local function qregion(q)
  -- NEVER read a game list past its end: in this scripting layer that read GROWS the list by an empty entry (measured
  -- 2026-11-12: length 0, after reading [1] length 1). The game's offer "raiders_near" has no region; this line used
  -- to give it an empty one, and the game's next save died on it (coop.lua, crash guard 2).
  local ok, k = pcall(function() local rs = q.regions; if #rs < 1 then return nil end; local r = un(rs[1]); if valid(r) then return rkey(r) end end)
  return ok and k or nil
end

-- the lord's lists as { list = { { n = name, r = region tag }, ... } } (sorted by name) and as one line
local function readQuests(S)
  local t, parts = {}, {}
  for _, l in ipairs(LISTS) do
    local a = S.p1[l]; local items = {}
    for i = 1, #a do local n = qname(a[i]); if n then items[#items + 1] = { n = n, r = qregion(a[i]) } end end
    table.sort(items, function(x, y) return x.n < y.n end); t[l] = items
    local e = {}; for i, it in ipairs(items) do e[i] = enc(it.n) .. ":" .. (it.r or "") end
    parts[#parts + 1] = #e > 0 and table.concat(e, ",") or "-"
  end
  return t, table.concat(parts, " ")
end

local function findQuest(S, list, name)
  local a = S.p1[list]
  for i = 1, #a do if qname(a[i]) == name then return a[i], i end end
end

local function fresh(S)
  if E.S == S and E.world == S.worlds then return end
  E.S = S; E.world = S.worlds
  E.sentQ = nil; E.tKey = -1e9; E.tPoll = 0; E.hostQ = nil; E.quiet = 0; E.lastDiff = nil; E.tried = {}; E.rows = nil
  E.sentK = nil; E.tKeyK = -1e9; E.tCamp = 0; E.scan = nil; E.hostK = nil; E.campSince = {}; E.campAsked = {}
  E.campGone = {}; E.hostKline = nil; E.listSig = nil; E.tQuick = 0
  E.sentO = nil; E.tKeyO = -1e9; E.tOwner = 0; E.hostO = nil; E.ownSince = {}; E.ownTried = {}
  E.pscan = nil; E.sentP = {}; E.tKeyP = -1e9; E.tPeople = 0; E.hostP = {}; E.lastKind = nil; E.peopleNow = nil
  E.homeT = {}; E.deadSig = {}; E.deadT = {}; E.famSeen = {}
  E.vill = nil; E.tVill = 0; E.pdQ = {}
  log("reset for world %d", S.worlds)
end

local function hostQuests(S, clock)
  local _, line = readQuests(S)
  if line ~= E.sentQ or clock - E.tKey >= KEY then
    if line ~= E.sentQ then log("quests on the host: %s", line); bump("q_sent") end
    E.sentQ = line; E.tKey = clock
    A.send("E Q " .. line)
  end
end

local function index(items) local s = {}; for _, it in ipairs(items) do s[it.n] = it end; return s end

-- the presets the director can start (row names of its quest table); a quest with another name cannot be started by name
local function isPreset(S, name)
  if not E.rows then
    E.rows = {}
    pcall(function()
      local names = {}
      StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary"):GetDataTableRowNames(S.eng.questDirector.DT_Quests, names)
      for i = 1, #names do local n = names[i]; local s; pcall(function() s = n:get():ToString() end); if not s then pcall(function() s = n:ToString() end) end; if s then E.rows[s] = true end end
    end)
  end
  return E.rows[name] == true
end

-- friend: start here what the host has (the director's own function), and say what still differs
local function friendQuests(S, clock)
  local H = E.hostQ; if not H then return end
  if clock < (E.quiet or 0) then return end            -- an answer was just given here: the host's word is on its way
  -- the same quest can be on offer more than once (a second looted camp: two "spoils_of_war"), and an answered
  -- offer stays in the list, so the lists are compared by how often each name is in them
  local function counts(items) local c = {}; for _, it in ipairs(items) do c[it.n] = (c[it.n] or 0) + 1 end; return c end
  local mine = readQuests(S)
  local any = {}
  for _, l in ipairs(LISTS) do for _, it in ipairs(mine[l]) do any[it.n] = true end end
  if E.on.questStart then
    for li, l in ipairs(LISTS) do
      if li <= 2 then
        local offer = l == "proposedQuests"
        local cH, cM = counts(H[l]), counts(mine[l]); local done = {}
        for _, it in ipairs(H[l]) do
          local key = l .. "|" .. it.n
          local tried = E.tried[key] or 0
          -- an offer: as many as the host has. A running quest: once per world, and only if this copy has it nowhere
          -- (a quest this copy already finished is not started again)
          local want = offer and ((cM[it.n] or 0) < cH[it.n] and tried < cH[it.n]) or (not offer and not any[it.n] and tried == 0)
          if want and not done[it.n] and isPreset(S, it.n) then
            done[it.n] = true; E.tried[key] = tried + 1    -- one per second
            local D = S.eng.questDirector
            local reg = (it.r and regionByKey(S, it.r)) or S.p1:getClosestOwnedRegion()
            local ok, r = pcall(function() return D:startQuestFromPreset(FName(it.n), S.p1, {}, reg, offer, -1) end)
            S.modQuestT = os.clock()                             -- the speed watcher (coop.lua): the game answers a new quest message with one speed step down; that is not the player's
            log("quest %s (%s on the host): started here%s", it.n, offer and "offered" or "running", (ok and r) and "" or (" FAILED " .. tostring(r))); bump("q_started")
          end
        end
      end
    end
  end
  local diff = {}
  mine = readQuests(S)
  for _, l in ipairs(LISTS) do
    local a, b = counts(H[l]), counts(mine[l])
    for n, k in pairs(a) do if (b[n] or 0) < k then diff[#diff + 1] = l .. "+" .. n end end
    for n, k in pairs(b) do if (a[n] or 0) < k then diff[#diff + 1] = l .. "-" .. n end end
  end
  table.sort(diff); local d = table.concat(diff, " ")
  if d ~= E.lastDiff then E.lastDiff = d; if d == "" then log("quests equal to the host's") else log("quests differ from the host's: %s", d); bump("q_diff") end end
end

-- ---- answers. The game's own calls on a copy's lord are seen by hooks; E.seen runs for each (on every copy).
--
-- What a click on a quest message does (lane 5 session 2, call trace on both copies): the first answer button calls
-- PawnCPP:acceptQuest(quest), the second PawnCPP:refuseQuest(quest), each with the message's own quest record; the
-- "choices" of a quest are only the two button texts. The offer stays in the list of offers afterwards.
-- Both calls take the quest record by reference, which a script cannot hand over (it arrives empty), and
-- PawnCPP:setChoice is not an answer: it adds a choice text to every quest with that number (seen: all three running
-- quests got it). So an answer is replayed the way the player gives it: through the copy's own message widgets. The
-- scroll under the top bar (questMessageElaborate_C) is opened with its own click handler, and the answer button of
-- the message (MessageFullscreen_C) is pressed with its own handler. The message shows for a moment on that copy.
local SCROLL = "BndEvt__scrollButton_K2Node_ComponentBoundEvent_0_OnButtonReleasedEvent__DelegateSignature"
local BUTTON = { A = "BndEvt__Button_ChoiceA_K2Node_ComponentBoundEvent_1_OnButtonReleasedEvent__DelegateSignature",
                 R = "BndEvt__Button_ChoiceB_K2Node_ComponentBoundEvent_0_OnButtonReleasedEvent__DelegateSignature" }
local VERB = { A = "accept", R = "refuse" }
local function wquest(w) local ok, n = pcall(function() return w.Quest.Name:ToString() end); return ok and n or nil end
local function wshown(w) local ok, v = pcall(function() return w:IsVisible() end); return ok and v == true end

-- press the answer on an open message for this quest; true when one was found
local function pressAnswer(name, verb)
  for _, w in ipairs(FindAllOf("MessageFullscreen_C") or {}) do
    if valid(w) and wshown(w) and wquest(w) == name then
      E.replayT = os.clock() + 1.5
      w[BUTTON[verb]](w)
      return true
    end
  end
  return false
end

-- give the answer on this copy; done(ok, how) is called when it is known (the message needs a moment to open)
local function doAnswer(S, verb, name, done)
  if not BUTTON[verb] then done(false, "unknown answer"); return end
  local ok, hit = pcall(pressAnswer, name, verb)
  if ok and hit then done(true, "message was open"); return end
  local scroll
  for _, w in ipairs(FindAllOf("questMessageElaborate_C") or {}) do
    if valid(w) and wquest(w) == name then
      local pressed = false; pcall(function() pressed = w.Pressed and true or false end)
      if not pressed then scroll = w end
    end
  end
  if not scroll then done(false, "no message for this quest on this copy"); return end
  E.replayT = os.clock() + 3.0
  local okS, eS = pcall(function() scroll[SCROLL](scroll) end)
  if not okS then done(false, "the scroll could not be opened: " .. tostring(eS)); return end
  local tries = 0
  local function try()
    tries = tries + 1
    local okP, hitP = pcall(pressAnswer, name, verb)
    if okP and hitP then done(true, "through the scroll")
    elseif tries < 8 then A.later(0.25, try)
    else done(false, "the message did not open") end
  end
  A.later(0.25, try)
end

function E.seen(fn, self, a1)
  local S = C.s
  if fn ~= "acceptQuest" and fn ~= "refuseQuest" then return end
  if not (S and S.on and E.on.answers) or os.clock() < (E.replayT or 0) or rawget(C, "hold") then return end
  local okL, isLord = pcall(function() return self:get():GetAddress() == S.p1:GetAddress() end)
  if not (okL and isLord) then return end
  local verb = fn == "acceptQuest" and "A" or "R"
  local a = qname(a1:get()); if not a then return end
  bump("q_seen")
  if S.role == "friend" then
    A.send(string.format("E %s %s", verb, enc(a))); E.quiet = os.clock() + 3.0
    log("this player's answer (%s %s): sent to the host", VERB[verb], a)
  elseif S.role == "host" then
    A.send(string.format("E DID host %s %s", verb, enc(a))); E.sentQ = nil
    log("the host's answer (%s %s): told to the friends", VERB[verb], a)
  end
end

local function ensureHooks()
  local G = rawget(_G, "__coop_events_hooks2"); if not G then G = {}; _G.__coop_events_hooks2 = G end
  if G.done or (G.t and os.clock() - G.t < 2.0) then return end
  G.t = os.clock(); local all = true
  for _, fn in ipairs({ "acceptQuest", "refuseQuest" }) do
    if not G[fn] then
      local ok, e = pcall(RegisterHook, "/Script/ManorLords.PawnCPP:" .. fn, function(self, a1, a2)
        local Ev = rawget(_G, "Coop") and _G.Coop.events
        if Ev and Ev.seen then local okH, eH = pcall(Ev.seen, fn, self, a1, a2); if not okH then Ev.lastErr = fn .. ": " .. tostring(eH) end end
      end)
      if ok then G[fn] = true else all = false; G.err = tostring(e) end
    end
  end
  if all then G.done = true; log("answer hooks registered") elseif not G.said then G.said = true; log("answer hooks not registered yet: %s", tostring(G.err)) end
end

-- host: a friend's answer. Run it here, then tell every copy (the sender skips it: it already ran there).
local function hostAnswer(S, from, w)
  local verb = w[4]; if not VERB[verb] then return end
  local a = dec(w[5] or "")
  doAnswer(S, verb, a, function(ok, how)
    log("%s's answer (%s %s): %s here (%s)", tostring(from), VERB[verb], a, ok and "given" or "NOT given", tostring(how))
    bump(ok and "q_answers" or "q_refused")
    if ok then A.send(string.format("E DID %s %s %s", tostring(from), verb, enc(a))) end
    E.sentQ = nil                                      -- and the lists as they are now
  end)
end

local function friendDid(S, w)
  local who, verb = w[5], w[6]; if who == S.name or not VERB[verb] then return end
  local a = dec(w[7] or "")
  doAnswer(S, verb, a, function(ok, how)
    log("answer given on the host by %s (%s %s): %s here (%s)", tostring(who), VERB[verb], a, ok and "given" or "NOT given", tostring(how))
    bump(ok and "q_did" or "q_didFailed")
  end)
end

-- ---------------------------------------------------------------- bandit camps
-- the same name as the world module's: type plus position rounded to 10 cm
local function bkey(b)
  local l = b:K2_GetActorLocation()
  return string.format("%d@%d,%d", A.btype(b), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5)), l.Z
end

-- this copy's camps as { key = { b = building, z = height } }, read a few buildings per tick; done(map) when complete
local function campScan(S, done)
  local st = E.scan
  local arr = S.eng.buildingArr; local n = 0
  if not st then st = { i = 0, map = {}, done = done, n0 = #arr }; E.scan = st end
  while st.i < #arr and n < 30 do
    st.i = st.i + 1; n = n + 1
    local b = un(arr[st.i])
    if valid(b) then
      pcall(function()
        if b:GetType() == CAMP_TYPE and ownerCode(S, b.ownerPawn) == "B" then local k, z = bkey(b); st.map[k] = { b = b, z = z } end
      end)
    end
  end
  if st.i >= #arr then
    -- The list is read over several ticks. When a building left it meanwhile, every later one moved up a place and
    -- one was not looked at: a camp could be missing from this reading (and a friend would take the host's word
    -- for it). So a reading during which the length changed is not used; the list is read again (three times at most).
    if #arr ~= st.n0 and (st.again or 0) < 3 then st.i = 0; st.map = {}; st.n0 = #arr; st.again = (st.again or 0) + 1; return end
    E.scan = nil; st.done(st.map)
  end
end

local function hostCamps(S, clock, map)
  local t = {}
  for k, c in pairs(map) do t[#t + 1] = string.format("%s~%d", k, math.floor(c.z + 0.5)) end
  table.sort(t); local line = #t > 0 and table.concat(t, ";") or "-"     -- ";" between camps: a camp's name holds a comma
  if line ~= E.sentK or clock - E.tKeyK >= KEY then
    if line ~= E.sentK then log("bandit camps on the host: %s", line); bump("k_sent") end
    E.sentK = line; E.tKeyK = clock
    A.send("E K " .. line)
  end
end

-- experiment (item campMake): the game's own spawnBanditCamp puts a camp at a place it rolls; the new camp is then
-- moved to the host's place. Returns true when a camp stands there afterwards.
local function campMake(S, key, z, have)
  local t, x, y = key:match("^(%d+)@(%-?%d+),(%-?%d+)$"); if not t then return false end
  local before = {}; for _, c in pairs(have) do before[addr(c.b)] = true end
  -- (lane 48, round 3) the squad the game makes with the camp is not the host's (that one came by the core's N line):
  -- asked away at once, so it does not stand where the game rolled the camp (k1: 4.3-4.6 s, 0.6-1.4 km off)
  local bl, sqBefore = nil, {}
  pcall(function() for _, pw in ipairs(FindAllOf("PawnCPP") or {}) do local ok, b = pcall(function() return pw.isBandit end); if ok and b then bl = pw end end end)
  pcall(function() local a = bl.commandedSquads; for i = 1, #a do sqBefore[a[i].Value] = true end end)
  S.eng:spawnBanditCamp()
  pcall(function()
    local a = bl.commandedSquads
    for i = 1, #a do
      local v = a[i].Value
      if v ~= 0 and not sqBefore[v] and not (S.l2h and S.l2h[v]) then
        S.madeHere = S.madeHere or {}; S.madeHere[v] = true
        S.sc:RequestRemoveSquad({ Value = v }); log("campMake: the camp's own squad %d asked away at once (the host's squad came by its announcement)", v)
      end
    end
  end)
  local arr = S.eng.buildingArr; local new
  for i = #arr, 1, -1 do
    local b = un(arr[i])
    if valid(b) and not before[addr(b)] and b:GetType() == CAMP_TYPE and ownerCode(S, b.ownerPawn) == "B" then new = b; break end
  end
  if not new then return false, "the game made no camp" end
  new:K2_SetActorLocation({ X = tonumber(x) * 10.0, Y = tonumber(y) * 10.0, Z = (z or 0) + 0.0 }, false, {}, true)
  local k2 = bkey(new)
  return k2 == key, "camp made at " .. k2
end

-- (lane 48, round 3) a camp and ITS squad, made the moment the host announces the camp's brigands (the core's N line
-- for an encamped bandit squad carries the camp's place). spawnBanditCamp makes a camp and a squad of brigands at a
-- place it rolls; campMake above moved only the building, so the squad stood 0.6-1.4 km away until the core took it
-- away 4.4 s later (lane 48 m2, t7: a squad the host never had), beside the squad the N line had made for the host's.
-- Here the building goes to the host's camp place and the game's own squad becomes the host's squad: its men are put
-- at the host's squad's place in the same frame and sent there (the caller ties it to the host's number). Returns the
-- squad's handle, or nil and why.
function E.campAt(S, bx, by, bz, sx, sy, sz, owner)
  local before = {}
  pcall(function() local a = owner.commandedSquads; for i = 1, #a do before[a[i].Value] = true end end)
  local bb = {}
  pcall(function() local arr = S.eng.buildingArr; for i = 1, #arr do local b = un(arr[i]); if valid(b) then bb[addr(b)] = true end end end)
  S.eng:spawnBanditCamp()
  local new
  local arr = S.eng.buildingArr
  for i = #arr, 1, -1 do
    local b = un(arr[i])
    if valid(b) and not bb[addr(b)] and b:GetType() == CAMP_TYPE and ownerCode(S, b.ownerPawn) == "B" then new = b; break end
  end
  if not new then return nil, "the game made no camp" end
  new:K2_SetActorLocation({ X = bx, Y = by, Z = bz }, false, {}, true)
  local key = bkey(new); E.campAsked[key] = true      -- the camp list will find it here: nothing more to make
  local h
  pcall(function() local a = owner.commandedSquads; for i = 1, #a do local v = a[i].Value; if v ~= 0 and not before[v] then h = v end end end)
  if not h or not S.sc:IsValidSquad({ Value = h }) then return nil, "camp made at " .. key .. ", but no new squad of the bandit lord" end
  local n = 0
  pcall(function()
    local ua = S.sc:GetSquad({ Value = h }).unitArr
    for i = 1, #ua do
      local u = un(ua[i])
      if valid(u) then
        local ox, oy = ((i - 1) % 6 - 2.5) * 150, (math.floor((i - 1) / 6) - 1) * 150    -- a small block, 1.5 m apart
        local p = { X = sx + ox, Y = sy + oy, Z = sz }
        u.realPos = p; u:K2_SetActorLocation(p, false, {}, true); n = n + 1
      end
    end
  end)
  -- (lane 48, round 4) the squad's centre too (the game works it out again from its men at its next tick; until then
  -- it still named the place the game rolled: k2, one sample at 576 m)
  -- (lane 55, item 5) round 4 wrote the squad's centre here, but GetSquad hands back the squad record BY VALUE
  -- (docs/nexus/loader_test_2026-11-12.md): the write changed a copy only (k4: a first sample at 188 m again). The
  -- game's own centre names the rolled place until its next squad update. Logged: that centre and the men's mean,
  -- both against the host's place, so a far first sample can be told apart from men not yet placed.
  local cd, md = -1, -1
  pcall(function()
    local s = S.sc:GetSquad({ Value = h }); local c = s.WeightedCenter; cd = math.sqrt((c.X - sx) ^ 2 + (c.Y - sy) ^ 2) / 100
    local ua, mx, my, k = s.unitArr, 0, 0, 0
    for i = 1, #ua do local u = un(ua[i]); if valid(u) then local p = u.realPos; mx = mx + p.X; my = my + p.Y; k = k + 1 end end
    if k > 0 then md = math.sqrt((mx / k - sx) ^ 2 + (my / k - sy) ^ 2) / 100 end
  end)
  return h, string.format("camp made at %s with its squad %d (%d men put at the host's squad's place; the game's centre %.1f m, the men's mean %.1f m from it)", key, h, n, cd, md)
end

-- ---- a camp that is gone on the host (lane 12; research/2026-11-10-game-probe/lanes/lane_s21_12/report.txt)
-- What a camp is (measured on a host alone and on two copies): a building of type 100 of the bandit lord in the
-- engine's lists buildingArr and independentBuildings, with a stock of loot, and ONE squad of brigands that holds on
-- to it (Squad.camp is the building, Squad.Control is 4, encamped). On the host the brigands let go of their camp
-- when they march out to meet an attacker (camp empty, Control 0), hold on to it again when they rout, and the game
-- folds the tents and takes the building out of both lists; the routing squad goes some seconds after its camp.
-- Nothing is left at the place.
-- A friend's brigands never let go (enemies decide nothing on a friend's copy): encamped or routing, in their lord's
-- list or no longer in it, they hold on to the camp until their squad is gone.
-- THE HAZARD (lane 12, session 3, one test host): a camp that is removed while a squad still holds on to it kills
-- the copy at one of the engine's next clean-ups. The squad keeps pointing at the removed building; the crash is in
-- the engine's unit update. It happened with the helper lord's demolish list, so it is not a matter of which
-- demolish is called. (The direct demolish of just-made camps that was switched off here after test hosts had
-- died fits the same picture: reasoned, not run again.) So the order is: the squad first, the camp after it.
-- The removal itself is the town module's own DEMOLISH (the helper lord's demolish list: the path of a player's
-- demolish click, and what lane 11 uses for a rival lord's buildings). Rules:
--   1. the camp must be missing from the host's list at two looks, the second at least 0.4 s after the first;
--   2. never while a squad of this copy still holds on to the camp. A squad the host no longer has is taken away
--      by the core (4 s after the host's word); a holder that is routing here is handed to the core's safe removal
--      by this rule, because the host's word about a routing squad comes some seconds after its camp went;
--   3. never while the helper lord is busy with a player's action;
--   4. refused, or the camp still stands 10 s after it was first seen missing: a resync (item campRepair), once.
-- A direct SMBuildingMaster:demolish on a camp is not used.
-- (2026-11-12, the user asked for it to be faster: the second look came 1 s after the first and the looks 0.5 s
-- apart, which made 1.5 s before the removal was even asked for. Hiding the camp at the first look was tried and
-- is NOT done: SetActorHiddenInGame(true) left the tent, the fire and the tripod on the screen and only took the
-- trodden ground away; pictures in research/2026-11-10-game-probe/lanes/lane_s21_0/camp_hide_test/)
local GONE_LOOK, GONE_LIMIT, GONE_AGAIN = 0.4, 10.0, 0.2

-- does squad h of this copy hold on to the building at address ba? nil when that could not be read
local function holds(S, h, ba)
  local ok, r = pcall(function()
    if not S.sc:IsValidSquad({ Value = h }) then return false end
    local c = un(S.sc:GetSquad({ Value = h }).camp)
    return valid(c) and addr(c) == ba
  end)
  if ok then return r == true end
end

-- The squads of this copy that hold on to a building; nil when that could not be read.
-- Every squad is asked: the ones in the lords' lists AND the squad of every unit, because a routing squad drops out
-- of its lord's list and lives on until its men have left the map (measured: such a squad of 10 brigands, in no
-- lord's list, still held on to its camp). The squad component has no reflected list of its squads.
-- Reading every unit's squad number costs about 12 ms with 560 units, so campGone asks the holders it already
-- knows first and comes here only when it knows none.
local function campSquads(S, b)
  local ba = addr(b); if not ba then return nil end
  local hs, okAll = {}, true
  for _, pw in ipairs(A.pawns()) do
    if valid(pw) then
      local ok = pcall(function()
        local arr = pw.commandedSquads; local n = #arr
        for i = 1, n do local h = arr[i].Value; if h and h ~= 0 then hs[h] = true end end
      end)
      if not ok then okAll = false end
    end
  end
  local ok = pcall(function()
    local arr = S.eng.unitArr; local n = #arr
    for i = 1, n do
      local u = un(arr[i])
      if valid(u) then local h = u.assignedSquadID.Value; if h and h ~= 0 then hs[h] = true end end
    end
  end)
  if not ok then okAll = false end
  local t = {}
  for h in pairs(hs) do
    local r = holds(S, h, ba)
    if r == nil then okAll = false elseif r then t[#t + 1] = h end
  end
  if okAll then return t end
end

-- The join module drops a request that follows another within 30 s (coop_join.lua, requestRepair): the camp is then
-- looked at again until the request can go out (or the reload that is already on its way has taken the camp away).
local function campResync(S, k, st, why)
  local J = C.join
  local can = E.on.campRepair and J and J.requestRepair
  if can and os.clock() - (J.repairT or -100) < 30.0 then
    if not st.saidWait then st.saidWait = true; log("bandit camp %s is gone on the host: %s: a resync was asked for less than 30 s ago, waiting for it", k, why) end
    return
  end
  st.asked = true
  log("bandit camp %s is gone on the host: %s: %s", k, why, can and "asking for a resync" or "no resync is asked for (item campRepair is off)"); bump("k_resync")
  if can then J.requestRepair("bandit camp " .. k .. " gone on the host") end
end

-- one look at a camp this copy has and the host's list lacks; st = { t0 = when it was first seen missing }
local function campGone(S, clock, k, c, st)
  if st.asked then return end
  if not valid(c.b) then return end                    -- (lane 47 round four) the camp list is read over several ticks                          -- a resync was asked for: the reload takes it from here
  local age = clock - st.t0
  if not E.on.campRemove then if age >= GONE_LOOK then campResync(S, k, st, "removing is switched off") end; return end
  local T = rawget(C, "town")
  if st.id then
    local r = T and T.results and T.results[st.id]
    if r ~= nil and r ~= "ok" and r ~= "queued/pending" then campResync(S, k, st, "the removal was refused (" .. tostring(r) .. ")"); return end
  elseif not (T and T.inject and T.results) then st.why = "the town module is not there"
  else
    -- the holders known from the last look are asked first; every squad is looked at only when none of them is left
    local held
    if st.held then
      local ba = addr(c.b); held = {}
      for _, h in ipairs(st.held) do if holds(S, h, ba) ~= false then held[#held + 1] = h end end
      if #held == 0 then held = campSquads(S, c.b) end
    else held = campSquads(S, c.b) end
    st.held = (held and #held > 0) and held or nil
    if not held then st.why = "the squads here could not be read"
    elseif #held > 0 then
      st.why = string.format("%d squad(s) here still hold on to it (%s)", #held, table.concat(held, ","))
      if not st.saidHeld then st.saidHeld = true; log("bandit camp %s is gone on the host; %s: waiting for the core to take them away", k, st.why) end
      -- A holder that is routing here (the game's own rout, started with the host's) is on its way out: on the host
      -- the camp goes some seconds BEFORE the host says that the routing squad is gone. Such a squad is handed to the
      -- core's safe removal now (4 s, no halt), at the first look already, so that the camp does not have to wait
      -- for that word as well.
      st.sent = st.sent or {}
      for _, h in ipairs(held) do
        if not st.sent[h] then
          local fleeing = false; pcall(function() fleeing = S.sc:GetSquad({ Value = h }).Control == 3 end)
          if fleeing and type(rawget(C, "removeSafe")) == "function" then
            st.sent[h] = true; pcall(C.removeSafe, h, "it routs and its camp is gone on the host"); bump("k_squad")
          end
        end
      end
    elseif age < GONE_LOOK then st.why = "seen missing only once so far"   -- nobody holds on to it: the second look removes it
    elseif T.pend or #(T.aq or {}) > 0 then st.why = "the helper lord was busy"
    else
      local l = c.b:K2_GetActorLocation()
      local ok, id = pcall(T.inject, "DEMOLISH", string.format("%d,%.0f,%.0f,%.0f", CAMP_TYPE, l.X, l.Y, l.Z), "events")
      if not ok then campResync(S, k, st, "the town module could not take the removal (" .. tostring(id) .. ")"); return end
      st.id = id; st.why = "the town module's DEMOLISH did not take it away"; bump("k_demolish")
      log("bandit camp %s is gone on the host: removal handed to the town module (%s, %.1f s after it was seen missing)", k, tostring(id), age)
    end
  end
  if age >= GONE_LIMIT then campResync(S, k, st, string.format("it still stands here after %.0f s (%s)", age, tostring(st.why))) end
end

local function friendCamps(S, clock, map)
  local H = E.hostK; if not H then return end
  local G = E.campGone
  for k, c in pairs(map) do
    if not H[k] then
      local st = G[k]; if not st then st = { t0 = clock }; G[k] = st end
      campGone(S, clock, k, c, st)
    elseif G[k] then G[k] = nil end                    -- the host has it (again)
  end
  for k, st in pairs(G) do
    if not map[k] then                                 -- it no longer stands here
      if st.id and not st.asked then log("bandit camp %s is gone on the host: removed here (seen gone %.1f s after it was seen missing)", k, clock - st.t0); bump("k_removed") end
      G[k] = nil
    end
  end
  for _, st in pairs(G) do if not st.asked then E.tCamp = clock - CAMP_EVERY + GONE_AGAIN; break end end   -- a removal is under way: the next look comes sooner
  for k, z in pairs(H) do
    if not map[k] then
      E.campSince["+" .. k] = E.campSince["+" .. k] or clock
      if clock - E.campSince["+" .. k] >= 1.0 and not E.campAsked[k] then      -- (3 s until 2026-11-12)
        E.campAsked[k] = true
        local made, how = false, nil
        if E.on.campMake then local ok, r, m = pcall(campMake, S, k, z, map); made = ok and r; how = ok and m or tostring(r) end
        if made then log("bandit camp %s on the host: %s", k, tostring(how)); bump("k_made")
        else
          log("bandit camp %s on the host is missing here%s", k, how and (" (" .. tostring(how) .. ")") or ""); bump("k_missing")
          if E.on.campRepair and C.join and C.join.requestRepair then C.join.requestRepair("bandit camp " .. k .. " on the host") end
        end
      end
    else E.campSince["+" .. k] = nil end
  end
end

-- ---------------------------------------------------------------- region owners
local function readOwners(S)
  local t, arr = {}, S.eng.regions
  for i = 1, #arr do local r = un(arr[i]); if valid(r) then local k = rkey(r); if k then t[k] = ownerCode(S, r.ownerPawn) end end end
  return t
end

local function hostOwners(S, clock)
  local t = {}; for k, c in pairs(readOwners(S)) do t[#t + 1] = k .. "=" .. c end
  table.sort(t); local line = table.concat(t, ",")
  if line ~= E.sentO or clock - E.tKeyO >= KEY then
    if line ~= E.sentO then log("region owners on the host: %s", line); bump("o_sent") end
    E.sentO = line; E.tKeyO = clock
    A.send("E O " .. (line ~= "" and line or "-"))
  end
end

local function friendOwners(S, clock)
  local H = E.hostO; if not H then return end
  local mine = readOwners(S)
  for k, want in pairs(H) do
    local have = mine[k]
    if have and have ~= want then
      local key = k .. "=" .. want
      E.ownSince[key] = E.ownSince[key] or clock
      if clock - E.ownSince[key] >= 3.0 and not E.ownTried[key] then
        E.ownTried[key] = true
        log("region %s is held by %s on the host, by %s here", k, want, have); bump("o_diff")
        if E.on.ownerSet then
          -- the game's own end of a claim: the lord takes the region (session 2: PawnCPP:finalizeClaim(region, false)
          -- on a friend's copy gave the region to the bandit lord, as on the host). A region nobody holds on the host
          -- cannot be given away by name: the daily comparison (owners) asks for a resync.
          local ok, e = pcall(function()
            local reg, pw = regionByKey(S, k), pawnByCode(S, want)
            if not valid(reg) then error("no such region here") end
            if not valid(pw) then error("no lord " .. want .. " here") end
            pw:finalizeClaim(reg, false)
          end)
          local now = readOwners(S)[k]
          log("region %s given to %s here: %s", k, want, (ok and now == want) and "done" or ("NOT done (" .. tostring(ok and now or e) .. ")")); bump(now == want and "o_set" or "o_failed")
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- people (villager names)
-- A villager's name is rolled when the villager is made (SMUnit:pickRandomName, field SMUnit.DisplayName). A family
-- that arrives after the join, and a new family member, is made on every copy by that copy's own game, so the same
-- person has another name on each copy; the mod's family rules carry where a family lives and works, not who they are.
-- The host's people are pushed and a friend's copy takes the names:
--   E P <region> <families in the region> <first family in this line> <family>;<family>;...
--       family = <home key>|<name>~<role>~<age>|...      (names encoded; "-" = no family in this line)
-- A family is its place in the region's list (the realm module keeps the lists equal), checked by its home; a person
-- is the place in the family. A person whose role differs (son against daughter) is not renamed: counted and logged.
-- does this stored object pointer look like a pointer? (its number only; the object is not touched)
local function ptrOk(o)
  local ok, a = pcall(function() return o:GetAddress() end)
  return ok and type(a) == "number" and a > 0x10000 and a < 0x7FFFFFFFFFFF
end
local function peopleScan(S, done)
  local st = E.pscan
  if not st then
    st = { regs = {}, ri = 1, fi = 0, out = {}, done = done }
    local arr = S.eng.regions; local me = addr(S.p1)
    for i = 1, #arr do
      local r = un(arr[i])
      if valid(r) and valid(r.ownerPawn) and addr(r.ownerPawn) == me then local k = rkey(r); if k then st.regs[#st.regs + 1] = { k = k, r = r } end end
    end
    E.pscan = st
  end
  local n = 0
  while n < 4 do                                       -- four families per tick
    local Rg = st.regs[st.ri]
    if not Rg then E.pscan = nil; st.done(st.out); return end
    st.out[Rg.k] = st.out[Rg.k] or {}
    local fams = valid(Rg.r) and Rg.r.workerFamilies or nil
    if not fams or st.fi >= #fams then st.ri = st.ri + 1; st.fi = 0
    else
      st.fi = st.fi + 1; n = n + 1
      -- Care with a family that is just arriving or just changed (two host crashes in sessions 4 and 5 were inside
      -- the script layer, reading address -1; the cause was not isolated, and this scan was one of the candidates):
      -- a family's people are read only after its number of people has been the same for 8 s, and a person only
      -- when the stored pointer looks like one (checked without touching the object). Until then the family is
      -- marked "wait" and nobody compares it.
      local rec = { home = "-", m = {} }
      pcall(function()
        local F = fams[st.fi]
        local h = F.familyHome; if ptrOk(h) and valid(h) then rec.home = (bkey(h)) end
        local m = F.familyMembers; local count = #m
        local key = Rg.k .. "|" .. st.fi; local seen = E.famSeen[key]
        if not seen or seen.n ~= count then E.famSeen[key] = { n = count, t = os.clock() }; rec.wait = true; return end
        if os.clock() - seen.t < 8.0 then rec.wait = true; return end
        for j = 1, count do
          local raw = m[j]
          local u = ptrOk(raw) and un(raw) or nil
          if u and valid(u) then rec.m[j] = { u = u, n = u.DisplayName:ToString(), role = tonumber(u.assignedUnitRole) or -1, age = tonumber(u.Age) or -1 }
          else rec.m[j] = { n = "", role = -1, age = -1 } end
        end
      end)
      st.out[Rg.k][st.fi] = rec
    end
  end
end

local function hostPeople(S, clock, out)
  local key = clock - E.tKeyP >= KEY; if key then E.tKeyP = clock end
  for rk, fams in pairs(out) do
    local parts = {}
    for i, rec in ipairs(fams) do
      local t = { rec.home }
      if rec.wait then t[2] = "?"                       -- its people are not read yet
      else for _, p in ipairs(rec.m) do t[#t + 1] = string.format("%s~%d~%d", enc(p.n), math.floor(p.role), math.floor(p.age)) end end
      parts[i] = table.concat(t, "|")
    end
    local sig = table.concat(parts, ";")
    if sig ~= E.sentP[rk] or key then
      if sig ~= E.sentP[rk] then bump("p_sent") end
      E.sentP[rk] = sig
      local i = 1
      repeat                                           -- lines under 3000 characters
        local buf, len, first = {}, 0, i
        while i <= #parts and (len == 0 or len + #parts[i] + 1 <= 3000) do buf[#buf + 1] = parts[i]; len = len + #parts[i] + 1; i = i + 1 end
        A.send(string.format("E P %s %d %d %s", rk, #parts, first, #buf > 0 and table.concat(buf, ";") or "-"))
      until i > #parts
    end
  end
end

-- Which of this copy's family members the host's family no longer has: the places (in this copy's list) that are left
-- over when the host's people are found in order, each by role AND name. nil = not every one of the host's people
-- was found, and then nobody is touched: who dies is never decided by the place in the list alone.
local function extrasOf(hm, fm)
  local ex, i = {}, 1
  for j, p in ipairs(fm) do
    local h = hm[i]
    if h and h.role == p.role and h.n ~= "" and h.n == p.n then i = i + 1 else ex[#ex + 1] = j end
  end
  if i == #hm + 1 and #ex > 0 then return ex end
end
local function findBuilding(S, key)
  local arr = S.eng.buildingArr
  for i = 1, #arr do local b = un(arr[i]); if valid(b) then local ok, k = pcall(bkey, b); if ok and k == key then return b end end end
end
local function inSquad(S, u)
  local ok, r = pcall(function() local v = u.assignedSquadID.Value; return v ~= nil and v ~= 0 and S.sc:IsValidSquad({ Value = v }) end)
  return ok and r == true
end

-- Session 3 (brigands set the town on fire): two more things about people differ after a raid, and each asked for a
-- resync. (1) A family whose house burns is homeless on the host long before the house is a ruin on the friend's copy
-- (a friend's fire only ends when the host's does), and after the fire each copy's game re-houses its homeless by
-- itself. The host's home of every family is in the people line, so a friend's copy gives the family the host's home
-- with the game's own Region:SetFamilyHome (no home = homeless). (2) Villagers killed on the host stay alive here.
-- When the host's family is this copy's family minus some people (each of the host's found here by role and name, the
-- family in the same home), for two looks in a row, those people die here too
-- (SMUnit:just_die, the game's own death; not while they stand in a called-up unit).
local function friendPeople(S, clock, out)
  local fixed, kind, same, waiting = 0, 0, 0, 0
  for rk, fams in pairs(out) do
    local H = E.hostP[rk]
    local reg = H and regionByKey(S, rk)
    if H and reg and #fams == (H.n or -1) then         -- the two lists are the same families only when equally long
      for i, rec in ipairs(fams) do
        local h = H.fams[i]
        if not h then waiting = waiting + 1
        else
          local fk = rk .. "|" .. i
          if h.home ~= rec.home then
            if E.on.homes and clock - (E.homeT[fk .. "|" .. h.home] or -100) > 10.0 then
              E.homeT[fk .. "|" .. h.home] = clock
              local ok, e = pcall(function()
                local b = nil
                if h.home ~= "-" then b = findBuilding(S, h.home); if not b then error("no such building here") end end
                reg:SetFamilyHome(i - 1, b, true)       -- the game counts families from 0
              end)
              log("people: %s family %d lives in %s on the host (%s here): %s", rk, i, h.home, rec.home, ok and "moved" or ("NOT moved: " .. tostring(e)))
              bump(ok and "p_home" or "p_homeFailed")
            end
            waiting = waiting + 1; E.deadSig[fk] = nil   -- people are compared only once the family lives where it does on the host
          elseif h.wait or rec.wait then waiting = waiting + 1; E.deadSig[fk] = nil   -- one side has not read its people yet
          elseif #rec.m ~= #h.m and not (#rec.m > #h.m and extrasOf(h.m, rec.m)) then
            waiting = waiting + 1; E.deadSig[fk] = nil   -- another number of people and no clear answer who is missing: left to the daily comparison
          elseif #rec.m > #h.m then
            local extras = extrasOf(h.m, rec.m)
            local sig = table.concat(extras, ",") .. "/" .. #h.m
            if E.deadSig[fk] ~= sig then E.deadSig[fk] = sig; E.deadT[fk] = clock; E.tPeople = clock - PEOPLE_EVERY + 4.0   -- look again in 4 s
            elseif clock - E.deadT[fk] >= 3.5 and E.on.deaths then
              E.deadSig[fk] = nil
              for _, j in ipairs(extras) do
                local p = rec.m[j]
                if p.u and valid(p.u) and not inSquad(S, p.u) then
                  local ok, e = pcall(function() p.u:just_die() end)
                  log("people: %s family %d: %s is dead on the host: dies here%s", rk, i, p.n, ok and "" or (" FAILED " .. tostring(e))); bump("p_died")
                else bump("p_diedSkipped") end
              end
            end
          else
            E.deadSig[fk] = nil
            for j, p in ipairs(rec.m) do
              local hp = h.m[j]
              if hp and p.u and valid(p.u) then
                if hp.role ~= p.role then kind = kind + 1
                elseif hp.n == p.n then same = same + 1
                elseif hp.n ~= "" and E.on.names then
                  local ok, back = pcall(function() p.u.DisplayName = hp.n; return p.u.DisplayName:ToString() end)
                  if ok and back == hp.n then fixed = fixed + 1; bump("p_named"); log("people: %s family %d person %d is %s on the host (was %s here)", rk, i, j, hp.n, p.n)
                  else E.on.names = false; log("people: item names switched off: a name could not be written (%s)", tostring(back)) end
                end
              end
            end
          end
        end
      end
    elseif H then waiting = waiting + #fams end        -- the family lists are not equally long yet (the realm module's rule)
  end
  local sum = string.format("%d equal, %d renamed, %d of another kind, %d families not matched", same, fixed, kind, waiting)
  E.peopleNow = sum
  if kind ~= (E.lastKind or 0) then E.lastKind = kind; log("people: %d differ in kind from the host's (a son here, a daughter there): not renamed", kind); bump("p_kind") end
end

-- ---------------------------------------------------------------- villagers who die (lane 24)
-- A raid on the town (lane 24, sitting 3): brigands killed 5 villagers on the host; on the friend's copy they stayed
-- alive (families 49 people against 54), because the rule above needs the family in the same home on both copies, and
-- burning houses had just made families homeless at different moments. The realm module then asked for a resync.
-- So the host names each villager of the player's town the moment he is dead (his mark: family number and name, the
-- same mark the core uses for militia men, with role and age), and a friend's copy lets the same villager die, the way the core does
-- for a soldier the host lost in a fight (the game's own death, marked "in combat"). A man in a called-up unit is left
-- to the core's death line (D). A mark nobody here has is tried again for 10 s, then dropped.
local function villTok(u)
  local n = u.DisplayName:ToString()
  if type(n) ~= "string" or n == "" then return nil end
  return tostring(u.workerFamilyID) .. "." .. (n:gsub("[^%w]", "_"))
end
local function villagers(S)
  local t = {}; local arr = S.eng.regions; local me = addr(S.p1)
  for i = 1, #arr do
    local r = un(arr[i])
    if valid(r) and valid(r.ownerPawn) and addr(r.ownerPawn) == me then
      local fams = r.workerFamilies
      for f = 1, #fams do
        pcall(function()
          local m = fams[f].familyMembers
          for j = 1, #m do
            local raw = m[j]
            local u = ptrOk(raw) and un(raw) or nil
            if u and valid(u) and not u.dead then local k = villTok(u); if k then t[k] = u end end      -- the living only
          end
        end)
      end
    end
  end
  return t
end
local function hostVillagers(S)
  local now = villagers(S); local old = E.vill; E.vill = now
  if not old then return end
  for k, u in pairs(old) do
    if not now[k] then
      local dead = false; pcall(function() dead = valid(u) and u.dead == true end)
      if dead then
        local role, age, fight = -1, -1, 0; pcall(function() role = tonumber(u.assignedUnitRole) or -1; age = tonumber(u.Age) or -1 end)
        -- killed in a fight (the game's combat code tags him) or another death (age, illness): told, so that a friend's
        -- copy books the same grief or none
        pcall(function() local tg = u.Tags; for i = 1, #tg do if un(tg[i]):ToString() == "deathInCombat" then fight = 1 end end end)
        A.send(string.format("E PD %s %d %d %d", enc(k), math.floor(role), math.floor(age), fight)); bump("pd_sent"); log("people: villager %s died on the host: told", k)
      end
    end
  end
end
local function friendVillagers(S, clock)
  if not next(E.pdQ) then return end
  local now = villagers(S)
  for k, q in pairs(E.pdQ) do
    local u = now[k]
    -- the mark (family number and name) is not proof alone: the same name occurs in several families, and family
    -- numbers can change with a load. Role and age (within a year) must agree too, or nobody dies here.
    if u then
      local okM, same = pcall(function() return (q.role < 0 or tonumber(u.assignedUnitRole) == q.role) and (q.age < 0 or math.abs((tonumber(u.Age) or -99) - q.age) <= 1) end)
      if not (okM and same) then u = nil end
    end
    if u then
      E.pdQ[k] = nil
      -- only a man of a CALLED-UP unit is left to the unit's death line: every militia man keeps his unit's number at
      -- home too (sitting 4: ten villagers at home were skipped that way and stayed alive here)
      local inUnit = false; pcall(function() local v = u.assignedSquadID.Value; inUnit = v ~= nil and v ~= 0 and S.sc:IsValidSquad({ Value = v }) and (tonumber(S.sc:GetSquad({ Value = v }).rallyingStatus) or 0) ~= 0 end)
      if inUnit then bump("pd_inUnit"); log("people: villager %s died on the host; here he stands in a called-up unit: left to the unit's death line", k)
      else
        local ok, e = pcall(function() if q.fight then local tg = u.Tags; tg[#tg + 1] = FName("deathInCombat") end; u:just_die() end)
        bump(ok and "pd_died" or "pd_failed"); log("people: villager %s died on the host%s: dies here%s", k, q.fight and " in a fight" or "", ok and "" or (" FAILED " .. tostring(e)))
      end
    elseif clock - q.t > 10.0 then E.pdQ[k] = nil; bump("pd_notFound"); log("people: villager %s died on the host and is not found here: dropped", k) end
  end
end

-- ---------------------------------------------------------------- development console
-- Two copies on one PC are started with COOP_X_DEV=1 (tools/dev): a file <link>/<name>_x.lua is then run inside the
-- mod's own Lua state and its result written to <name>_x_out.txt (hot reload of this file, switches, status). Without
-- that variable this does nothing.
local DEV = false   -- the development console is not part of shipped code any more (lead, 2026-11-11): test builds use coop_dev.lua
local function devTick(S, clock)
  if not DEV or clock - (E.devT or 0) < 0.2 then return end
  E.devT = clock
  local dir = rawget(_G, "COOP_LINK_DIR"); if not dir then return end
  local path = dir .. S.name .. "_x.lua"
  local f = io.open(path, "r"); if not f then return end
  local src = f:read("a"); f:close(); os.remove(path)
  local chunk, err = load(src, "x", "t")
  local ok, res; if chunk then ok, res = pcall(chunk) else ok, res = false, err end
  local o = io.open(dir .. S.name .. "_x_out.tmp", "w")
  if o then o:write((ok and "OK: " or "ERR: ") .. tostring(res) .. "\n"); o:close(); os.remove(dir .. S.name .. "_x_out.txt"); os.rename(dir .. S.name .. "_x_out.tmp", dir .. S.name .. "_x_out.txt") end
end

-- ---------------------------------------------------------------- plug-in
local function guarded(what, fn, ...)
  local ok, e = pcall(fn, ...)
  if not ok and E.lastErr ~= what .. ": " .. tostring(e) then E.lastErr = what .. ": " .. tostring(e); log("%s", E.lastErr); bump("err") end
end

local M = {}
function M.onWorld(S) fresh(S) end
function M.tick(S, clock)
  fresh(S)
  pcall(devTick, S, clock)
  if rawget(C, "hold") or not valid(S.p1) or not valid(S.eng) then return end
  if S.role ~= "host" and S.role ~= "friend" then return end
  local host = S.role == "host"
  if E.on.answers then ensureHooks() end
  if E.on.camps then
    -- The host, four times a second: when the number of buildings or of independent buildings (the list the camps
    -- stand in) has changed, the camps are read now, so that a friend hears of a camp that went within a second and
    -- not after up to 3 s. (Asking the camp object itself is no use: a camp that has left the list stays a living
    -- object for some time. Measured with such a look: the host's word came 2.6 s after the camp had left the list.)
    if host and not E.scan and clock - (E.tQuick or 0) >= 0.25 then
      E.tQuick = clock
      local okN, sig = pcall(function() return #S.eng.buildingArr .. "/" .. #S.eng.independentBuildings end)
      if okN and sig ~= E.listSig then if E.listSig then E.tCamp = -1e9 end; E.listSig = sig end
    end
    if E.scan then guarded("camps", campScan, S)
    elseif clock - E.tCamp >= CAMP_EVERY then
      E.tCamp = clock
      guarded("camps", campScan, S, function(map) if host then hostCamps(S, os.clock(), map) else friendCamps(S, os.clock(), map) end end)
    end
  end
  if E.on.owners and clock - E.tOwner >= OWNER_EVERY then
    E.tOwner = clock
    guarded("owners", host and hostOwners or friendOwners, S, clock)
  end
  if E.on.people then
    if E.pscan then guarded("people", peopleScan, S)
    elseif clock - E.tPeople >= (host and 3.0 or PEOPLE_EVERY) then   -- the host looks every 3 s, a friend every 5 s and after each line
      E.tPeople = clock
      guarded("people", peopleScan, S, function(out) if host then hostPeople(S, os.clock(), out) else friendPeople(S, os.clock(), out) end end)
    end
  end
  if E.on.vdeaths and clock - E.tVill >= 1.0 then E.tVill = clock; guarded("villagers", host and hostVillagers or friendVillagers, S, clock) end
  if clock - E.tPoll < POLL then return end
  E.tPoll = clock
  if E.on.quests then guarded("quests", host and hostQuests or friendQuests, S, clock) end
end
function M.idle(S, clock) pcall(devTick, S, clock) end
function M.onMessage(S, from, kind, w, line)
  if kind ~= "E" then return false end
  fresh(S)
  if S.role == "friend" and from == "host" then
    local sub = w[4]
    if sub == "Q" then
      local H = {}
      for i, l in ipairs(LISTS) do
        local items = {}; local s = w[4 + i] or "-"
        if s ~= "-" then for n, r in s:gmatch("([^,:]+):([^,]*)") do items[#items + 1] = { n = dec(n), r = r ~= "" and r or nil } end end
        H[l] = items
      end
      E.hostQ = H
    elseif sub == "DID" then
      local ok, e = pcall(friendDid, S, w); if not ok then log("answer from the host failed: %s", tostring(e)) end
    elseif sub == "K" then
      -- only a list in which every entry is a whole camp name is taken (session 2: a list cut at the commas inside
      -- the names made a friend's copy demolish its two real camps)
      local H, good = {}, true
      if w[5] and w[5] ~= "-" then
        for e in w[5]:gmatch("[^;]+") do
          local k, z = e:match("^(%d+@%-?%d+,%-?%d+)~(%-?%d+)$")
          if k then H[k] = tonumber(z) else good = false end
        end
      end
      if good then
        E.hostK = H
        if (w[5] or "-") ~= E.hostKline then E.hostKline = w[5] or "-"; E.tCamp = -1e9 end   -- a changed list: look at this copy's camps now
      else bump("k_badLine"); log("bandit camps: a line from the host could not be read: %s", tostring(w[5])) end
    elseif sub == "O" then
      local H = {}
      for k, c in (w[5] or ""):gmatch("([^,=]+)=([^,]+)") do H[k] = c end
      E.hostO = H
    elseif sub == "PD" then
      if w[5] and E.on.vdeaths then E.pdQ[dec(w[5])] = { t = os.clock(), role = tonumber(w[6]) or -1, age = tonumber(w[7]) or -1, fight = w[8] ~= "0" }; E.tVill = -1e9 end
    elseif sub == "P" then
      local rk, n, first = w[5], tonumber(w[6]), tonumber(w[7])
      if rk and n and first then
        local H = E.hostP[rk]; if not H then H = { fams = {} }; E.hostP[rk] = H end
        H.n = n
        E.tPeople = math.min(E.tPeople or 0, os.clock() - PEOPLE_EVERY + 0.5)   -- compare half a second from now
        for i in pairs(H.fams) do if i > n then H.fams[i] = nil end end
        local i = first
        if w[8] and w[8] ~= "-" then
          for fam in w[8]:gmatch("[^;]+") do
            local rec = { m = {} }; local k = 0
            for part in fam:gmatch("[^|]+") do
              k = k + 1
              if k == 1 then rec.home = part
              elseif part == "?" then rec.wait = true
              else
                local nm, role, age = part:match("^([^~]*)~(%-?%d+)~(%-?%d+)$")
                rec.m[#rec.m + 1] = { n = dec(nm or ""), role = tonumber(role) or -1, age = tonumber(age) or -1 }
              end
            end
            H.fams[i] = rec; i = i + 1
          end
        end
      end
    end
  elseif S.role == "host" and from ~= "host" then
    local ok, e = pcall(hostAnswer, S, from, w)
    if not ok then log("answer from %s failed: %s", tostring(from), tostring(e)) end
  end
  return true
end

function E.status()
  local t = {}; for k, v in pairs(E.stats) do t[#t + 1] = k .. "=" .. tostring(v) end; table.sort(t)
  local on = {}; for k, v in pairs(E.on) do if v then on[#on + 1] = k end end; table.sort(on)
  return string.format("events %s: %s | on: %s | last error %s | last quest difference %s | people: %s", E.version, table.concat(t, " "), table.concat(on, ","), tostring(E.lastErr), tostring(E.lastDiff), tostring(E.peopleNow))
end

C.register("events", M)
return "coop_x_events " .. E.version .. " loaded"
