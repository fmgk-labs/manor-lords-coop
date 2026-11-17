-- Manor Lords Co-op: the lord's dealings with other lords (lane module "lord", loaded after the town and realm modules).
--   war and peace          state compare, both directions (message kind L)
--   refuting a claim       the game's own call is seen and replayed (town action REFUTE)
--   letters                the game's own call is seen and replayed (town action LETTER)
--   settling a new region  the game's own call is seen, the host replays it and resyncs everybody (town action SETTLE)
--   how a claim was paid   the game's own layClaim call is seen, so the realm module need not guess "favour or influence"
-- What each of these was measured on and how it was exercised: research/2026-11-10-game-probe/lanes/lane_s21_3/report.md
-- Rule for everything here: the host's lord decides; what rival lords answer or do is rolled per copy, so the host's
-- result is pushed (claims, influence, favour and silver by the realm module; war by this one).

local C = _G.Coop; local A = C.api
local T = C.town; local X = T and T.api
local R = C.realm; local RA = R and R.api
if not (X and RA) then return "coop lord module not loaded (needs the town and realm modules)" end
local valid, un, log = A.valid, A.un, A.log
local P = X.P
C.lord = C.lord or {}
local L = C.lord
L.on = L.on or { war = true, inbox = true }
L.stats = L.stats or { set = 0, is = 0, applied = 0, failed = 0 }
L.claimHow = L.claimHow or {}
local POLL, KEYFRAME, GRACE = 0.5, 30.0, 3.0

local function isLocal(p) return valid(p) and valid(C.s and C.s.p1) and RA.addr(p) == RA.addr(C.s.p1) end
local function regionTag(reg) if valid(reg) then return RA.rkey(reg) end end

-- ================================================================ war and peace
-- Measured (host, console): PawnCPP:declareWar(lord) puts that lord into the player's PawnCPP.enemies and his squads
-- into enemySquads; declarePeace takes them out again. Relations, diplomatic tags, letters and notices do not change.
-- The value is the codes of the rival lords the player is at war with ("A1.A2"), or "none". Bandits are always in
-- the list and have no code here.
local function warSet(S)
  local t = {}
  local a = S.p1.enemies
  for i = 1, #a do
    local e = un(a[i])
    local code = valid(e) and RA.lordCode(S, e)
    if code and code ~= "P" then t[code] = true end
  end
  return t
end
local function warStr(set) local t = {}; for c in pairs(set) do t[#t + 1] = c end; table.sort(t); return #t == 0 and "none" or table.concat(t, ".") end
local function warParse(s) local t = {}; if s and s ~= "none" then for c in s:gmatch("[^%.]+") do t[c] = true end end; return t end
local function setWar(S, code, on)
  local pw = RA.lords(S)[code]; if not valid(pw) then return false, "no lord " .. tostring(code) end
  if (warSet(S)[code] == true) == on then return true, "already" end
  -- inside the town module's quiet wrapper: the hook below ("this player declared war") must not see the mod's own call
  T.quiet(function() if on then S.p1:declareWar(pw) else S.p1:declarePeace(pw) end end)
  pcall(function() S.p1:updateCommandedAndEnemySquads(false) end)
  return true
end

local function pollWar(S, clock)
  local cur = warSet(S); local s = warStr(cur)
  if S.role == "host" then
    local key = clock - (L.tKey or -1e9) >= KEYFRAME
    if key then L.tKey = clock end
    if L.warKnown ~= s or key then
      if L.warKnown ~= nil and L.warKnown ~= s then log("lord: war list %s -> %s", tostring(L.warKnown), s); L.stats.is = L.stats.is + 1 end
      L.warKnown = s; A.send("L IS war " .. s)
    end
    return
  end
  -- a friend's copy
  if L.warMine == nil then L.warMine = s end
  local H = L.warHost
  if s ~= L.warMine then                                  -- this copy's list changed
    local was = warParse(L.warMine); L.warMine = s
    if H and s ~= H.v and L.letterT and clock - L.letterT < 10.0 then
      H.since = clock                                     -- it came from a letter this player just sent: the host sends the same letter (LETTER below) and declares it there
      log("lord: war list %s after this player's letter: left to the host's copy of the letter", s)
    elseif H and s ~= H.v and ((L.warActT and clock - L.warActT < 5.0) or (L.peaceActT and clock - L.peaceActT < 5.0)) then
      -- not towards the host's list, and the game's own declareWar or declarePeace call on this player's lord, made
      -- through the game's script layer (a button's graph), was seen a moment ago (hooks below): this player's own
      local war, peace = L.warActT and clock - L.warActT < 5.0, L.peaceActT and clock - L.peaceActT < 5.0
      for code in pairs(cur) do if war and not was[code] then A.send("L SET war " .. code .. ":1"); L.stats.set = L.stats.set + 1; log("lord: this player declared war on %s: sent to the host", code) end end
      for code in pairs(was) do if peace and not cur[code] then A.send("L SET war " .. code .. ":0"); L.stats.set = L.stats.set + 1; log("lord: this player made peace with %s: sent to the host", code) end end
      H.since = clock                                     -- give the host a moment before this copy is put back
    elseif H and s ~= H.v then
      -- (lane 16) The list changed and no call of this player was seen: this copy's GAME did it, in its native
      -- code, which the hooks do not see. Read there: a challenge for a region puts the two lords at war
      -- (Engine::initChallenge calls declareWar) and its end makes peace (Engine::finalizeChallenge calls
      -- declarePeace); both run on each copy's own clock. Sent to the host as "this player declared war / made
      -- peace", such a change would start or end a war on the host at the wrong moment. Nothing is sent: the host's
      -- list is taken below, at once. (War and peace by letter are carried by the LETTER action.)
      L.stats.notMine = (L.stats.notMine or 0) + 1
      log("lord: war list %s changed here with no declaration by this player: not sent, the host's list (%s) is taken", s, tostring(H.v))
    end
  end
  if not H then return end
  if s == H.v then H.since = nil; H.fails = 0; return end
  -- the lists differ. After this player's own declaration (H.since set above) the host gets a moment to follow;
  -- otherwise it is the host's news and is taken at once.
  if H.since and clock - H.since < GRACE then return end
  H.since = clock
  local want = warParse(H.v)
  for code in pairs(want) do if not cur[code] then local ok, e = pcall(setWar, S, code, true); log("lord: the host is at war with %s: declared here%s", code, ok and "" or (" FAILED " .. tostring(e))) end end
  for code in pairs(cur) do if not want[code] then local ok, e = pcall(setWar, S, code, false); log("lord: the host is at peace with %s: peace made here%s", code, ok and "" or (" FAILED " .. tostring(e))) end end
  local after = warStr(warSet(S)); L.warMine = after
  if after == H.v then L.stats.applied = L.stats.applied + 1; H.fails = 0
  else
    H.fails = (H.fails or 0) + 1; L.stats.failed = L.stats.failed + 1
    log("lord: the war list did not take the host's value; here %s, host %s", after, H.v)
    if H.fails >= 3 then L.on.war = false; log("lord: war and peace switched off on this copy after 3 failures") end
  end
end

-- The player's own declaration of war or peace: a button's graph calls PawnCPP:declareWar / declarePeace on his
-- lord through the game's script layer, and that is what these hooks see (lane 16; in the blueprint scripts read
-- from a running game the region view's button calls declareWar, and no graph called declarePeace: a graph that
-- was not loaded then is still caught here). The game's own native calls are not seen. The hooks only note the
-- moment; the war list is still carried by state (pollWar above).
X.hook(P .. "PawnCPP:declareWar", { "WARHOW" }, function(self)
  local p = self:get(); if not isLocal(p) then return nil end
  L.warActT = os.clock()
  return nil                                              -- nothing to send from here
end)
X.hook(P .. "PawnCPP:declarePeace", { "WARHOW" }, function(self)
  local p = self:get(); if not isLocal(p) then return nil end
  L.peaceActT = os.clock()
  return nil
end)
X.def { name = "WARHOW", status = "read, not run", ref = "lane_s21_16" }

-- ================================================================ how a claim was paid (seen for the realm module)
-- The claim itself is carried by the realm module (a new claim of the player on a friend's copy goes to the host as
-- "R SET _ claim region:f|i"). This hook only notes the "use king's favour" flag of the player's own call.
X.hook(P .. "PawnCPP:layClaim", { "CLAIMHOW" }, function(self, a1, a2)
  local p = self:get(); if not isLocal(p) then return nil end
  local reg = a1 and a1:get(); local fav = a2 and a2:get()
  local tag = regionTag(reg); if not tag then return nil end
  L.claimHow[tag] = { fav = fav == true, t = os.clock() }
  return nil                                              -- nothing to send from here
end)
X.def { name = "CLAIMHOW", status = "see report", ref = "lane_s21_3" }

-- ================================================================ refuting a claim
-- In the game a claim is refuted with a letter (paragraph "claim_refute"): that is carried by LETTER below.
-- The direct call PawnCPP:refuteClaim(Claim, useFavour) cannot be replayed from here: its claim parameter is a
-- reference to a record, and the script layer passes neither a list element nor a table for it (session C: a list
-- element is refused, a table arrives empty and the call does nothing). So a direct refute on a friend's copy is only
-- noted: the host's claim list, pushed by the realm module, then puts that copy back, and the player is told.
-- A direct refute on the host needs nothing: its result reaches the friends with the host's claim list.
X.hook(P .. "PawnCPP:refuteClaim", { "REFUTE" }, function(self, a1, a2)
  local p = self:get(); if not isLocal(p) then return nil end
  local S = C.s
  if S and S.role == "friend" then
    if C.notify then C.notify("refused", "Co-op: only the host can refute a claim directly; send the lord a letter instead") end
    return { k = "_note", msg = "a direct refuteClaim on this copy cannot be replayed on the host: not sent, the host's claim list will put this copy back" }
  end
  return nil
end)
X.def { name = "REFUTE", status = "see report", ref = "lane_s21_3" }

-- ================================================================ starting a challenge for a claimed region (lane 27)
-- The running-claim widget's button (currentClaimingWidget_C, Button) calls RTSMultiEngineCPP:initChallenge(the
-- region's lord, the claimer, the region) through the script layer (read in the game's blueprint dump: "init challenge
-- clicked", getClaimForTheRegion, initChallenge). The game then declares war by itself (lane 16), which the war
-- compare above leaves to the host. Carried like a letter: the player's call is seen, every other copy makes the same
-- call; the host's war list and region owners are pushed as before.
--   CHALLENGE <challenged lord code> <region tag>
-- The widget is for a RIVAL's claim on a region of the player: the graph takes the challenged lord from the region's
-- claim (getClaimForTheRegion) and the player as the challenger. Pressed while the widget showed the player's OWN claim
-- (lane 27, first sitting), the lord challenged himself and the game crashed (access violation reading 0xa50). The mod
-- never sends nor replays that case, nor a challenge of a lord who holds no claim on that region here.
local function claimOn(pw, reg)
  local ok, r = pcall(function()
    local a = pw.claims; local ra = RA.addr(reg)
    for i = 1, #a do if valid(a[i].Region) and RA.addr(a[i].Region) == ra then return true end end
    return false
  end)
  return ok and r
end
local function challengeWhyNot(S, pw, reg)
  if not valid(pw) or not valid(reg) then return "lord or region gone" end
  if RA.addr(pw) == RA.addr(S.p1) then return "the player's own claim: the lord would challenge himself" end
  if not (valid(reg.ownerPawn) and RA.addr(reg.ownerPawn) == RA.addr(S.p1)) then return "the region is not the player's" end
  if not claimOn(pw, reg) then return "that lord holds no claim on the region on this copy" end
  return nil
end
X.hook(P .. "RTSMultiEngineCPP:initChallenge", { "CHALLENGE" }, function(self, a1, a2, a3)
  local by = a2 and a2:get(); if not isLocal(by) then return nil end
  local who = a1 and a1:get(); local reg = a3 and a3:get()
  local why = challengeWhyNot(C.s, who, reg)
  if why then return { k = "_note", msg = "challenge not sent: " .. why } end
  local code = RA.lordCode(C.s, who); local tag = regionTag(reg)
  if not code or code == "P" or not tag then return { k = "_note", msg = "a challenge whose lord or region could not be named: not sent" } end
  return { k = "CHALLENGE", code = code, tag = tag }
end)
X.def { name = "CHALLENGE", status = "press2", ref = "lane_s21_27",
  ready = function(S, rec) return rec.code .. " " .. rec.tag end,
  apply = function(S, job)
    local pw = RA.lords(S)[job.f[1]]; if not valid(pw) then return "no lord " .. tostring(job.f[1]) end
    local reg = RA.regionByKey(S, job.f[2]); if not valid(reg) then return "no region " .. tostring(job.f[2]) end
    local why = challengeWhyNot(S, pw, reg); if why then return "refused: " .. why end
    S.eng:initChallenge(pw, S.p1, reg)
    return "ok"
  end }

-- ================================================================ letters
-- PawnCPP:sendLetter(recipient, paragraph names) on the player's lord. The host sends the same letter from its lord, so
-- what the letter does (war, peace, a claim, influence spent) happens on the host and reaches every copy with the
-- host's numbers. What the rival lord answers is the host's answer; see the report for what is carried of it.
X.hook(P .. "PawnCPP:sendLetter", { "LETTER" }, function(self, a1, a2)
  local p = self:get(); if not isLocal(p) then return nil end
  local to = a1 and a1:get(); local arr = a2 and a2:get()
  local code = valid(to) and RA.lordCode(C.s, to)
  if not code or code == "P" then return { k = "_note", msg = "a letter to someone who is not a rival lord: not sent" } end
  local paras = {}
  local ok = pcall(function() for i = 1, #arr do paras[#paras + 1] = arr[i]:ToString() end end)
  if not ok or #paras == 0 then return { k = "_note", msg = "a letter whose paragraphs could not be read: not sent" } end
  L.letterT = os.clock()
  return { k = "LETTER", code = code, paras = paras }
end)
X.def { name = "LETTER", status = "see report", ref = "lane_s21_3", rel = true,
  ready = function(S, rec)
    local t = {}; for i, n in ipairs(rec.paras) do t[i] = X.enc(n) end
    return rec.code .. " " .. table.concat(t, ",")
  end,
  apply = function(S, job)
    local pw = RA.lords(S)[job.f[1]]; if not valid(pw) then return "no lord " .. tostring(job.f[1]) end
    local names = {}; for n in (job.f[2] or ""):gmatch("[^,]+") do names[#names + 1] = FName(X.dec(n)) end
    if #names == 0 then return "empty letter" end
    L.letterT = os.clock()
    S.p1:sendLetter(pw, names)
    return "ok"
  end }

-- ---- letters the player receives: the host's inbox is the truth (host -> friends)
-- Rival lords write and answer on the host only (they decide nothing on a friend's copy), so a letter that arrives in
-- the host lord's PawnCPP.InBox is sent on: L LTR <day> <sender code> <paragraphs> <guid>. A friend adds it unless it
-- already holds the same letter. A record cannot be handed to PawnCPP:addToInbox from here (the parameter arrives
-- empty, session C), so the game's call adds an empty letter and its fields are then written in place, which is the
-- way the realm module edits mercenary offers.
local function paraList(e) local t = {}; for j = 1, #e.paras do t[#t + 1] = e.paras[j]:ToString() end; return t end
local function letterSig(e) return string.format("%d|%d|%s", X.int(e.daySent), X.int(e.senderSetupIndex), table.concat(paraList(e), ",")) end
local function inboxPoll(S)
  local a = S.p1.InBox; local n = #a
  if L.inN == nil then L.inN = n; return end                 -- first look in this world: the save holds these
  if n <= L.inN then L.inN = n; return end
  for i = L.inN + 1, n do
    local e = a[i]
    local ok, line = pcall(function()
      local code = valid(e.sender) and RA.lordCode(S, e.sender) or nil
      if not code or code == "P" then return nil end
      local ps = {}; for k, nme in ipairs(paraList(e)) do ps[k] = X.enc(nme) end
      if #ps == 0 then return nil end
      local g = e.Guid
      return string.format("L LTR %d %s %s %d.%d.%d.%d", X.int(e.daySent), code, table.concat(ps, ","), g.A, g.B, g.C, g.D)
    end)
    if ok and line then A.send(line); L.stats.letters = (L.stats.letters or 0) + 1; log("lord: a letter from a rival lord arrived: sent to the friends (%s)", line:sub(7, 90)) end
  end
  L.inN = n
end
local function inboxAdd(S, w)
  local day, code, paras, guid = tonumber(w[5]), w[6], w[7], w[8]
  local pw = code and RA.lords(S)[code]
  if not (day and valid(pw) and paras) then return "bad letter line" end
  local names = {}; for nme in paras:gmatch("[^,]+") do names[#names + 1] = X.dec(nme) end
  local idx = pw:getPawnSetupIndex()
  local sig = string.format("%d|%d|%s", day, idx, table.concat(names, ","))
  local p = S.p1; local a = p.InBox
  for i = 1, #a do if letterSig(a[i]) == sig then return "already here" end end
  local n0 = #a
  p:addToInbox({})
  a = p.InBox
  if #a ~= n0 + 1 then return "the game did not add a letter" end
  local e = a[#a]
  e.daySent = day; e.senderSetupIndex = idx; e.recipientSetupIndex = 0; e.read = false; e.wasOpened = false
  e.sender = pw; e.recipient = p
  local fn = {}; for i, nme in ipairs(names) do fn[i] = FName(nme) end
  e.paras = fn
  if guid then
    local g = {}; for x in guid:gmatch("%-?%d+") do g[#g + 1] = tonumber(x) end
    if #g == 4 then pcall(function() local G = e.Guid; G.A = g[1]; G.B = g[2]; G.C = g[3]; G.D = g[4] end) end
  end
  if letterSig(p.InBox[#p.InBox]) ~= sig then return "the letter's fields did not take" end
  L.inN = #p.InBox
  return "ok"
end

-- ================================================================ settling a new region
-- PawnCPP:settleRegion(region, camp transform, supply level, settlement type, outpost-to region) on the player's lord.
-- The settlers' looks are rolled per copy, so only the host replays it and then every copy reloads the host's world.
local function num(v) return string.format("%.1f", tonumber(v) or 0) end
X.hook(P .. "PawnCPP:settleRegion", { "SETTLE" }, function(self, a1, a2, a3, a4)
  local p = self:get(); if not isLocal(p) then return nil end
  local reg = a1 and a1:get(); local tr = a2 and a2:get()
  local tag = regionTag(reg); if not tag then return nil end
  local rec = { k = "SETTLE", tag = tag, reg = reg, supply = X.int(a3 and a3:get() or 0), stype = X.int(a4 and a4:get() or 0) }
  local ok = pcall(function()
    local t, q = tr.Translation, tr.Rotation
    rec.tr = table.concat({ num(t.X), num(t.Y), num(t.Z), string.format("%.5f", q.X), string.format("%.5f", q.Y), string.format("%.5f", q.Z), string.format("%.5f", q.W) }, ",")
  end)
  if not ok then return { k = "_note", msg = "settleRegion seen but the camp place could not be read: not sent" } end
  return rec
end)
X.def { name = "SETTLE", status = "see report", ref = "lane_s21_3", rel = true,
  ready = function(S, rec)
    local out = "-"; pcall(function() if valid(rec.reg.outpostToRegion) then out = RA.rkey(rec.reg.outpostToRegion) or "-" end end)
    return table.concat({ rec.tag, rec.tr, rec.supply, rec.stype, out }, " ")
  end,
  apply = function(S, job)
    if S.role ~= "host" then return "ok" end                -- friends get the new settlement with the host's world (resync below)
    local reg = RA.regionByKey(S, job.f[1]); if not valid(reg) then return "no region " .. tostring(job.f[1]) end
    if reg.isSettled then return "ok" end
    local n = {}; for x in (job.f[2] or ""):gmatch("[^,]+") do n[#n + 1] = tonumber(x) end
    if #n < 7 then return "bad camp place" end
    local tr = { Translation = { X = n[1], Y = n[2], Z = n[3] }, Rotation = { X = n[4], Y = n[5], Z = n[6], W = n[7] }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    local out = job.f[5] ~= "-" and RA.regionByKey(S, job.f[5]) or nil
    -- no outpost-to region: nil, as the player's own call has it (session C: with the region itself given here the
    -- host's settlement came out as its own outpost, with no families)
    if valid(out) then S.p1:settleRegion(reg, tr, X.int(job.f[3]), X.int(job.f[4]), out)
    else S.p1:settleRegion(reg, tr, X.int(job.f[3]), X.int(job.f[4]), nil) end
    if not reg.isSettled then return "the game did not settle " .. tostring(job.f[1]) end
    if C.join and C.join.requestRepair then C.join.requestRepair("settled " .. tostring(job.f[1])) end
    return "ok"
  end }

-- the host's own settling: its world is the truth, the friends reload it
-- (lane 32) A region that was settled already under another lord and now is the player's (won in battle: the end of a
-- challenge, or a claim the game finalized) is NOT a new settlement: its town, families and buildings are the same
-- on every copy, and only the owner changed. The owner is carried by the events module (E O lines; a friend gives
-- the region to the host's owner with the game's own finalizeClaim); no copy reloads for it (lane 24 R4b: one
-- reload of every copy after a won battle). Only a region settled anew (settleRegion: the settlers are rolled per
-- copy) still makes every copy reload. lanes/lane_s21_32/report.txt item 2.
local function hostSettled(S)
  local n, mine, all = 0, {}, {}
  local arr = S.eng.regions; local me = RA.addr(S.p1)
  for i = 1, #arr do
    local r = un(arr[i])
    if valid(r) and r.isSettled then
      local k = RA.rkey(r)
      if k then all[k] = true end
      if valid(r.ownerPawn) and RA.addr(r.ownerPawn) == me then n = n + 1; if k then mine[k] = true end end
    end
  end
  if L.settled ~= nil and n > L.settled and S.role == "host" then
    local newK, won = {}, {}
    for k in pairs(mine) do
      if not (L.mineSet and L.mineSet[k]) then
        if L.allSet and L.allSet[k] then won[#won + 1] = k else newK[#newK + 1] = k end
      end
    end
    if #won > 0 then
      log("lord: the host now holds the settled region%s %s (it was another lord's): no reload, the owner travels with the E O line", #won == 1 and "" or "s", table.concat(won, ","))
      -- the rival's town was each copy's own until now: who works where differed (sittings s6, s8: 10 of 25 families,
      -- then the daily comparison asked for a resync). Every building's workers of the region are sent twice, 8 s and
      -- 60 s after the change (the friends take the region with finalizeClaim 3 s after the E O line).
      L.famPush = L.famPush or {}
      local clock = os.clock()
      for _, k in ipairs(won) do L.famPush[#L.famPush + 1] = { tag = k, t = clock + 8.0 }; L.famPush[#L.famPush + 1] = { tag = k, t = clock + 60.0 } end
    end
    if #newK > 0 or #won == 0 then
      log("lord: the host settled a region (%d -> %d%s): every copy reloads the host's world", L.settled, n, #newK > 0 and (": " .. table.concat(newK, ",")) or "")
      if C.join and C.join.requestRepair then C.join.requestRepair("host settled a region") end
    end
  end
  L.settled = n; L.mineSet = mine; L.allSet = all
end

-- (lane 32) the host's workers of every building of a region it has won: "L FAMS <building> <family ids> <active>"
local function famPushTick(S)
  if not L.famPush or #L.famPush == 0 or S.role ~= "host" then return end
  local clock = os.clock(); local keep = {}
  for _, job in ipairs(L.famPush) do
    if clock < job.t then keep[#keep + 1] = job
    else
      local reg = RA.regionByKey(S, job.tag); local n = 0
      if valid(reg) then
        local arr = S.eng.buildingArr
        for i = 1, #arr do
          local b = un(arr[i])
          local ok = pcall(function()
            if valid(b) and valid(b.Region) and RA.addr(b.Region) == RA.addr(reg) and X.owned(b) then
              local ids = {}; local a = b.assignedFamilyIDs
              for j = 1, #a do ids[#ids + 1] = math.tointeger(tonumber(un(a[j]))) or 0 end
              table.sort(ids)
              if #ids > 0 or (tonumber(b.numActiveWorkerFamilies) or 0) == 0 then
                A.send(string.format("L FAMS %s %s %d", X.bkeyOf(X.bident(b)), #ids > 0 and table.concat(ids, ",") or "-", tonumber(b.numActiveWorkerFamilies) or 0)); n = n + 1
              end
            end
          end)
        end
      end
      log("lord: the workers of %d buildings of the won region %s sent to the friends", n, job.tag)
    end
  end
  L.famPush = keep
end
L.famPushTick = famPushTick

-- ================================================================ module
local function fresh(S)
  if L.S == S and L.world == S.worlds then return end
  L.S = S; L.world = S.worlds
  L.warKnown = nil; L.warMine = nil; L.warHost = nil; L.tKey = -1e9; L.tPoll = 0; L.settled = nil; L.mineSet = nil; L.allSet = nil; L.claimHow = {}; L.letterT = nil; L.inN = nil; L.warActT = nil; L.peaceActT = nil
end
local M = {}
function M.onWorld(S) fresh(S) end
function M.tick(S, clock)
  fresh(S)
  if C.hold then return end
  if clock - (L.tPoll or 0) < POLL then return end
  L.tPoll = clock
  if L.on.war then local ok, e = pcall(pollWar, S, clock); if not ok then L.lastErr = tostring(e) end end
  local ok2, e2 = pcall(hostSettled, S); if not ok2 then L.lastErr = tostring(e2) end
  local ok4, e4 = pcall(famPushTick, S); if not ok4 then L.lastErr = tostring(e4) end
  if L.on.inbox and S.role == "host" then local ok3, e3 = pcall(inboxPoll, S); if not ok3 then L.lastErr = tostring(e3) end end
end
function M.onMessage(S, from, kind, w, line)
  if kind ~= "L" then return false end
  fresh(S)
  local verb, item, value = w[4], w[5], w[6]
  if verb == "LTR" then
    if S.role == "friend" and L.on.inbox then
      local ok, r = pcall(inboxAdd, S, w)
      if ok and r == "ok" then L.stats.letters = (L.stats.letters or 0) + 1; log("lord: the host received a letter from %s (day %s): added here", tostring(w[6]), tostring(w[5]))
      elseif not (ok and r == "already here") then L.stats.failed = L.stats.failed + 1; log("lord: the host's letter from %s was not added here: %s", tostring(w[6]), tostring(r)) end
    end
    return true
  end
  if verb == "FAMS" then
    -- (lane 32) the host's workers of a building of a region it has won (see famPushTick): taken with the town
    -- module's own fixFamilies (the game's unassignFamily / assignFamily / reassignFamily)
    if S.role == "friend" then
      local ok, r = pcall(function()
        local b = X.findBkey(w[5]); if not b then return "building not found" end
        local ids = {}; if w[6] and w[6] ~= "-" then for x in w[6]:gmatch("[^,]+") do ids[#ids + 1] = math.tointeger(tonumber(x)) end end
        table.sort(ids)
        return T.fixFamilies(b, ids)
      end)
      L.stats.fams = (L.stats.fams or 0) + 1
      if not (ok and r == "ok") then L.stats.famsFailed = (L.stats.famsFailed or 0) + 1; if L.stats.famsFailed <= 10 then log("lord: the host's workers of %s not taken here: %s", tostring(w[5]), tostring(r)) end end
    end
    return true
  end
  if item ~= "war" or not value then return true end
  if S.role == "friend" and verb == "IS" then
    local H = L.warHost; if not H then H = {}; L.warHost = H end
    if H.v ~= value then H.v = value; H.since = nil end
  elseif S.role == "host" and verb == "SET" then
    local code, on = value:match("^(%w+):([01])$")
    if code then
      local ok, done, why = pcall(setWar, S, code, on == "1")
      log("lord: %s %s %s%s", tostring(from), on == "1" and "declares war on" or "makes peace with", code, (ok and done) and (why and (" (" .. why .. ")") or "") or (" FAILED " .. tostring(ok and why or done)))
      L.warKnown = nil                                      -- say what holds now, whatever happened
    end
  end
  return true
end
function L.status()
  local s = L.stats
  return string.format("lord: war %s, sent set %d / is %d, applied %d, failed %d%s", tostring(L.warKnown or L.warMine), s.set, s.is, s.applied, s.failed, L.lastErr and (", last error " .. L.lastErr) or "")
end

C.register("lord", M)
return "coop lord module loaded"
