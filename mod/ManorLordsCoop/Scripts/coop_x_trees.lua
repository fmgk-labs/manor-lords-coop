-- Manor Lords Co-op: the items lying on the ground on the host's word (lane 88; plug-in module "trees", message kind
-- "FT", host -> friends only). Loaded by coop_x_fields.lua (its last lines), as coop_x_values.lua. Re-loadable: state
-- in Coop.trees. Evidence: research/2026-11-10-game-probe/lanes/lane_s21_88/report.txt.
--
-- What. Every Resource actor of the world but the carts (lane 74's module draws those): felled trees and their last
-- logs (FallenTreeBP_C), heaps of stone (Resource_Stone_C), berries, fish, mushrooms, and any other Resource class.
-- Why. Each copy's villagers take from them at their own pace: a felled tree is cut up (its amt counts down, then it
-- is gone), a stone heap is mined. Probe p88c (lane 8): a felled tree lies at its standing tree's place on both
-- copies, but the amounts drift and the copy that finishes first loses the tree first: host-only stretches of up to
-- 157 s in both towns, the stone heaps of the rival town 7 s apart. Before this module (lead's run r27cf) the friend
-- kept trees the host had used up: 127 against 54.
-- How. The host tells every item: class, place (decimetres) and amt, whole when a friend asks and every 10 s, else the
-- changes. A friend, every 0.25 s, for each item of its own:
--   * the host has one of the same class within cfg.match: the host's amt is written into it (the game's own field),
--     so it never runs out before the host's;
--   * the host had one there and no longer has it (cfg.goneAfter s after the line without it came): removed (the
--     game's removeResource where the class has it, then the actor destroyed, as the game ends a used-up item);
--   * the host never had one there for cfg.neverAfter s: removed the same way.
-- An item the host has and this copy lacks (a felling that did not happen here) cannot be made by script: counted
-- ("host's items this copy lacks") and logged; see the report.
-- Every handle comes from FindAllOf in the tick it is used and is checked first; nothing is kept past the tick; one
-- removal call per actor (by address).
-- Messages (after the core's "<seq> <wallclock> "):
--   FT S <n> <key>=<amt>;...     every item of the host ("-" for none)       key = <class code>:<x>,<y>[#k] (dm)
--   FT D <key>=<amt>|-;...       the changes since the last line (- = gone)
--   FT A                         (friend -> host) send everything at the next look
--   class code: T felled tree, S stone, B berries, F fish, M mushrooms; any other: the class name
-- Switches (console only): Coop.trees.on.carry (the host sends), .remove (a friend removes), .amount (a friend writes amt).
local C = rawget(_G, "Coop")
if type(C) ~= "table" or type(C.register) ~= "function" or type(C.api) ~= "table" then return "coop_x_trees: load coop.lua first" end
local A = C.api
local valid = A.valid
local T = C.trees or {}
C.trees = T
T.version = "0.2"
T.on = T.on or {}
for k, v in pairs({ carry = true, remove = true, amount = true }) do if T.on[k] == nil then T.on[k] = v end end
T.cfg = T.cfg or {}
for k, v in pairs({ every = 0.25, hostEvery = 0.5, keyEvery = 10.0, siteNear = 2000.0, siteWait = 10.0, match = 200.0, pairMax = 1000.0, goneAfter = 0.5, neverAfter = 20.0, keep = 600.0, logEvery = 60.0, perTick = 4 }) do
  if T.cfg[k] == nil then T.cfg[k] = v end
end
T.stats = T.stats or {}
local function log(fmt, ...) A.log("trees: " .. fmt, ...) end
local function bump(k, n) T.stats[k] = (T.stats[k] or 0) + (n or 1) end
local CODE = { FallenTreeBP_C = "T", Resource_Stone_C = "S", Resource_Berries_C = "B", Resource_Fish_C = "F", Resource_Mushrooms_C = "M" }

-- an item that is in the game: valid and not destroyed (a destroyed actor reads valid until the engine's next garbage
-- collection, up to a minute later: run l88a; run p88a: the reflected bActorIsBeingDestroyed told 7 of 7 apart, the
-- call IsActorBeingDestroyed none)
local function liveItem(r)
  if not valid(r) then return false end
  local ok, d = pcall(function() return r.bActorIsBeingDestroyed end)
  if ok and type(d) == "boolean" then T.canTell = true else T.cantTell = (T.cantTell or 0) + 1 end
  return not (ok and d == true)
end
T.liveTree = liveItem
-- this copy's items: list of { r = handle (this tick only), c = class code, x, y (cm), amt, key }
-- (round 2, l88g: the module cost the host 2.7 to 5 ms a frame) an item's class and place do not change while it lies:
-- they are kept by its address (plain values, no handle; the handle is taken from FindAllOf in each look and checked)
-- and read again only for an address not seen in the last look (a new item, or one at a reused address)
local function items()
  local t, seen = {}, {}
  local known, nextKnown = T.known or {}, {}
  for _, r in ipairs(FindAllOf("Resource") or {}) do
    if liveItem(r) then
      local okA0, ad = pcall(function() return r:GetAddress() end)
      local kn = okA0 and known[ad]
      local okC, cn, ok, l = true, kn and kn.cn, true, kn and kn.l
      if not kn then
        okC, cn = pcall(function() return r:GetClass():GetFName():ToString() end)
        ok, l = pcall(function() local v = r:K2_GetActorLocation(); return { X = v.X, Y = v.Y } end)
      end
      -- (round 3, p88f) a felled tree is NOT kept: read at first sight it is still falling (its place moves) and it stayed
      -- filed under a wrong place: removed as "gone" while the host had it. Felled trees (about 100) are read at every
      -- look; the many berries, fish, mushrooms and stones keep their kept class and place.
      if okA0 and okC and type(cn) == "string" and ok and l and cn ~= "FallenTreeBP_C" then nextKnown[ad] = { cn = cn, l = l } end
      if okC and type(cn) == "string" and not cn:lower():find("cart") then
        if ok and l then
          local okA, amt = pcall(function() return r.amt end)
          local c = CODE[cn] or cn
          local k = string.format("%s:%d,%d", c, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5))
          local base, j = k, 1
          while seen[k] do j = j + 1; k = base .. "#" .. j end
          seen[k] = true
          t[#t + 1] = { r = r, ad = okA0 and ad or nil, c = c, x = l.X, y = l.Y, amt = (okA and type(amt) == "number") and math.floor(amt) or nil, key = k }
        end
      end
    end
  end
  T.known = nextKnown
  return t
end
T.items = items

-- ---------------------------------------------------------------- host
-- (round 7, the l88o crash: the host's game placed a rival site over three felled trees and cleared them; the friend's
-- module destroyed its three 0.16 s later; the people module made the site on the friend 0.6 s after that; the friend
-- crashed 1.5 s later) the host tells an item that went within cfg.siteNear of a building site new since its last two
-- looks as "gone under a site" (=-S); a friend then leaves it for cfg.siteWait s, so its own placement of that site
-- clears it, as the host's did; only after that is it removed as before.
local function newSites(S)
  local cur, list = {}, {}
  pcall(function()
    local arr = S.eng.buildingArr; local n = #arr
    for i = 1, n do
      local b = A.un and A.un(arr[i]) or arr[i]
      if valid(b) then
        local okC, built = pcall(function() return b:IsConstructed() end)
        if okC and built == false then
          local okA, a = pcall(function() return b:GetAddress() end)
          if okA and a then
            cur[a] = true
            if not (T.sites and T.sites[a]) and not (T.sites2 and T.sites2[a]) and T.sites then
              local okL, l = pcall(function() return b:K2_GetActorLocation() end)
              if okL and l then list[#list + 1] = { x = l.X, y = l.Y } end
            end
          end
        end
      end
    end
  end)
  T.sites2 = T.sites; T.sites = cur
  return list
end
local function underSite(k, sites)
  local x, y = k:match(":(%-?%d+),(%-?%d+)"); if not x then return false end
  x, y = tonumber(x) * 10, tonumber(y) * 10
  local r2 = T.cfg.siteNear * T.cfg.siteNear
  for _, s0 in ipairs(sites) do if (s0.x - x) ^ 2 + (s0.y - y) ^ 2 <= r2 then return true end end
  return false
end
local function hostTick(S, clock)
  if not T.on.carry then return end
  local now = {}
  for _, e in ipairs(items()) do now[e.key] = e.amt and tostring(e.amt) or "?" end
  local sites = newSites(S)
  -- the items gone under a new site go out first, as changes, whatever else this look sends
  if T.sentMap and #sites > 0 then
    local sp = {}
    for k in pairs(T.sentMap) do if now[k] == nil and underSite(k, sites) then sp[#sp + 1] = k .. "=-S" end end
    if #sp > 0 then
      table.sort(sp); A.send("FT D " .. table.concat(sp, ";")); bump("sentUnderSite", #sp)
      for _, e in ipairs(sp) do T.sentMap[e:match("^(.-)=")] = nil end
    end
  end
  local whole = T.wantAll or not T.sentMap or clock - (T.sentT or -99) >= T.cfg.keyEvery
  if whole then
    local parts = {}
    for k, a in pairs(now) do parts[#parts + 1] = k .. "=" .. a end
    table.sort(parts)
    A.send(string.format("FT S %d %s", #parts, #parts > 0 and table.concat(parts, ";") or "-")); bump("sentWhole")
    T.sentMap = now; T.sentT = clock; T.wantAll = nil
    return
  end
  local parts = {}
  for k, a in pairs(now) do if T.sentMap[k] ~= a then parts[#parts + 1] = k .. "=" .. a end end
  for k in pairs(T.sentMap) do if now[k] == nil then parts[#parts + 1] = k .. "=-" end end
  if #parts > 0 then table.sort(parts); A.send("FT D " .. table.concat(parts, ";")); bump("sentChanges"); T.sentMap = now end
end

-- ---------------------------------------------------------------- friend
-- the host's items: T.host[key] = { c, x, y, amt, last, goneT }; T.hostNow[key] = true while on the host's list
local function hostItem(k, a, now)
  local c, x, y = k:match("^([^:]+):(%-?%d+),(%-?%d+)")
  if not c then return end
  local h = T.host[k]
  if not h then
    h = { c = c, x = tonumber(x) * 10, y = tonumber(y) * 10 }; T.host[k] = h
    -- the index: class -> cell (cfg.match wide) -> keys
    local cs = T.cfg.match
    local cell = string.format("%d,%d", math.floor(h.x / cs), math.floor(h.y / cs))
    T.grid = T.grid or {}; T.grid[c] = T.grid[c] or {}; T.grid[c][cell] = T.grid[c][cell] or {}
    T.grid[c][cell][k] = true
  end
  h.amt = tonumber(a); h.last = now; h.goneT = nil; h.site = nil
  T.hostNow[k] = true
end
local function onHostLine(w)
  local now = os.clock()
  T.host = T.host or {}
  if w[4] == "S" then
    local cur = {}
    T.hostNow = {}
    if w[6] and w[6] ~= "-" then for k, a in w[6]:gmatch("([^;=]+)=([^;]+)") do hostItem(k, a, now); cur[k] = true end end
    for k, h in pairs(T.host) do if not cur[k] and not h.goneT then h.goneT = now end end
    T.hostWhole = true
  elseif w[4] == "D" and T.hostWhole then
    for k, a in (w[5] or ""):gmatch("([^;=]+)=([^;]+)") do
      if a == "-" or a == "-S" then
        local h = T.host[k]; if h and not h.goneT then h.goneT = now end; T.hostNow[k] = nil
        if h and a == "-S" then h.site = now end                -- (round 7) gone under a new site on the host
      else hostItem(k, a, now) end
    end
  end
  T.hostT = now
  for k, h in pairs(T.host) do
    if now - (h.last or now) > T.cfg.keep then
      T.host[k] = nil; T.hostNow[k] = nil
      local cs = T.cfg.match; local g = T.grid and T.grid[h.c]
      local cell = g and g[string.format("%d,%d", math.floor(h.x / cs), math.floor(h.y / cs))]
      if cell then cell[k] = nil end
    end
  end
end
T.onHostList = onHostLine

-- the host's items of class c within cfg.match of (x, y): the nearest one on the host's list now, else the nearest one
-- the host had
local function hostNear(c, x, y)
  local cur, cd, old, od = nil, nil, nil, nil
  local m2 = T.cfg.match * T.cfg.match
  local g = T.grid and T.grid[c]; if not g then return nil, nil end
  local cs = T.cfg.match; local gx, gy = math.floor(x / cs), math.floor(y / cs)
  for dx = -1, 1 do for dy = -1, 1 do
    local cell = g[string.format("%d,%d", gx + dx, gy + dy)]
    if cell then
      for k in pairs(cell) do
        local h = T.host[k]
        if h then
          local d = (h.x - x) ^ 2 + (h.y - y) ^ 2
          if d <= m2 then
            if T.hostNow[k] then if not cd or d < cd then cur, cd = h, d end
            elseif not od or d < od then old, od = h, d end
          end
        end
      end
    end
  end end
  return cur, old
end

local function removeItem(e)
  local okR = pcall(function() e.r:removeResource() end)              -- the game's own (felled trees have it)
  local okD, err = pcall(function() e.r:K2_DestroyActor() end)
  return okD, err, okR
end

local function busy() return rawget(C, "hold") or (C.join and C.join.state) end
local function friendTick(S, clock)
  if not T.hostNow then
    if clock - (T.askT or -99) >= 5.0 then T.askT = clock; A.send("FT A") end   -- a friend that came later or reloaded
    return
  end
  if busy() then return end
  if os.clock() - (T.hostT or -99) > 3 * T.cfg.keyEvery then return end      -- the host has gone quiet: nothing is judged
  local list = items()
  T.alone = T.alone or {}; T.asked = T.asked or {}
  -- (round 2, p88d) an item of this copy with no host item of its class within cfg.match, and a host item with none of
  -- this copy's there: the same item lying elsewhere (seen after a load: two leftover logs of the friend 0.6 m apart where
  -- the host's lay 5 m apart; the friend's second was then removed as "never had" and the host's stayed host-only for
  -- the whole run). Paired nearest first within cfg.pairMax (same class), this copy's actor is moved to the host's place
  -- (its own height kept); the amount follows at the next look. Before any removal.
  -- (p88e: OFF by default: the 7 moves of that run joined DIFFERENT trees (each copy had felled another tree a few
  -- metres away; a felled tree's standing place is its identity) and the host-only stretches rose 5 -> 14; Coop.trees.on.pair
  -- = true from the console for a test)
  if T.on.pair == true then
    local m2, p2 = T.cfg.match * T.cfg.match, T.cfg.pairMax * T.cfg.pairMax
    local mine = {}
    for _, e in ipairs(list) do if not hostNear(e.c, e.x, e.y) then mine[#mine + 1] = e end end
    if #mine > 0 then
      local theirs = {}
      for k in pairs(T.hostNow) do
        local h = T.host[k]; local has = false
        if h then for _, e in ipairs(list) do if e.c == h.c and (h.x - e.x) ^ 2 + (h.y - e.y) ^ 2 <= m2 then has = true; break end end end
        if h and not has then theirs[#theirs + 1] = h end
      end
      local pairs_ = {}
      for _, e in ipairs(mine) do for hi, h in ipairs(theirs) do
        if h.c == e.c then local d = (h.x - e.x) ^ 2 + (h.y - e.y) ^ 2; if d <= p2 then pairs_[#pairs_ + 1] = { e = e, hi = hi, d = d } end end
      end end
      table.sort(pairs_, function(a, b) return a.d < b.d end)
      local usedE, usedH = {}, {}
      for _, pp in ipairs(pairs_) do
        if not usedE[pp.e] and not usedH[pp.hi] then
          usedE[pp.e] = true; usedH[pp.hi] = true
          local h = theirs[pp.hi]
          local ok = pcall(function()
            local z = pp.e.r:K2_GetActorLocation().Z
            pp.e.r:K2_SetActorLocation({ X = h.x, Y = h.y, Z = z }, false, {}, true)
          end)
          if ok then
            pp.e.x, pp.e.y = h.x, h.y; T.alone[pp.e.key] = nil
            local kn = T.known and pp.e.ad and T.known[pp.e.ad]; if kn then kn.l = { X = h.x, Y = h.y } end   -- the kept place follows
          end
          bump(ok and ("moved_" .. pp.e.c) or "moveFailed")
          log("%s: lay %.1f m from the host's %s,%s, which this copy lacked: moved there%s", pp.e.key, math.sqrt(pp.d) / 100, h.x, h.y, ok and "" or " (FAILED)")
        end
      end
    end
  end
  local seen, removed = {}, 0
  for _, e in ipairs(list) do
    seen[e.key] = true
    local cur, old = hostNear(e.c, e.x, e.y)
    if cur then
      T.alone[e.key] = nil
      -- (run l88f: written both ways, the friend's tree went down to the host's amount and its own villagers then finished it
      -- first: the host's trees the friend lacked rose to 16-24) only UP: this copy's item never runs out before the host's;
      -- one that lasts longer is removed 0.5 s after the host's went
      if T.on.amount and cur.amt and e.amt and cur.amt > e.amt then
        local ok = pcall(function() e.r.amt = cur.amt end)
        bump(ok and ("amt_" .. e.c) or "amtFailed")
      end
    else
      local since = T.alone[e.key]; if not since then since = clock; T.alone[e.key] = since end
      local why
      if old and old.site and clock - old.site < T.cfg.siteWait then why = nil; bump("leftForSite")   -- (round 7) its own placement of the site clears it
      elseif old and old.goneT and clock - old.goneT >= T.cfg.goneAfter then why = "gone"
      elseif not old and clock - since >= T.cfg.neverAfter then why = "never" end
      local ra = (function() local okA, a = pcall(function() return e.r:GetAddress() end); return okA and a or nil end)()
      if why and ra and T.asked[ra] then why = nil end
      -- (never a call on an item this copy cannot tell from a destroyed one: T.canTell)
      if why and T.on.remove and T.canTell and removed < T.cfg.perTick then
        T.asked[ra] = clock
        local ok, err = removeItem(e)
        removed = removed + 1; T.alone[e.key] = nil
        bump(ok and ("removed_" .. why .. "_" .. e.c) or "removeFailed")
        if not ok then T.lastErr = tostring(err) end
        log("%s (amt %s): this copy's, the host %s: removed%s", e.key, tostring(e.amt),
          why == "gone" and string.format("no longer has it (its line without it came %.1f s ago)", clock - old.goneT) or string.format("never had it (%.0f s)", clock - since),
          ok and "" or (" FAILED " .. tostring(err)))
      end
    end
  end
  for k in pairs(T.alone) do if not seen[k] then T.alone[k] = nil end end
  -- the host's items this copy lacks, per class (for the log and the report: they cannot be made here), every 2 s
  if clock - (T.missT or -99) < 2.0 then return end
  T.missT = clock
  local miss = {}
  local m2 = T.cfg.match * T.cfg.match
  for k in pairs(T.hostNow) do
    local h = T.host[k]; local found = false
    if h then
      for _, e in ipairs(list) do if e.c == h.c and (h.x - e.x) ^ 2 + (h.y - e.y) ^ 2 <= m2 then found = true; break end end
      if not found then miss[h.c] = (miss[h.c] or 0) + 1 end
    end
  end
  local p = {}; for c, n in pairs(miss) do p[#p + 1] = c .. "=" .. n end; table.sort(p)
  T.missing = #p > 0 and table.concat(p, ",") or "0"
end

-- ---------------------------------------------------------------- module
local function tick(S, clock)
  if S.role ~= "host" and S.role ~= "friend" then return end
  if not (S.eng and valid(S.eng)) then return end
  if clock - (T.t or -99) < (S.role == "host" and T.cfg.hostEvery or T.cfg.every) then return end
  T.t = clock
  local ok, e = pcall(S.role == "host" and hostTick or friendTick, S, clock)
  if not ok then bump("errors"); T.lastErr = tostring(e) end
  if clock - (T.logT or -99) >= T.cfg.logEvery then T.logT = clock; log("%s", T.status()) end
end
local function onWorld(S)
  T.grid = nil; T.known = nil
  T.host, T.hostNow, T.hostT, T.hostWhole, T.alone, T.sentMap, T.sentT, T.missing, T.asked, T.askT = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
  T.wantAll = true
end
local function onMessage(S, from, kind, w, line)
  if kind ~= "FT" then return false end
  if S.role == "host" then if w[4] == "A" then T.wantAll = true end; return true end
  if S.role ~= "friend" or from ~= "host" then return true end
  if C.stale and C.stale("host", w) then bump("staleLine"); return true end
  if w[4] == "S" or w[4] == "D" then local ok, e = pcall(onHostLine, w); if not ok then bump("errors"); T.lastErr = tostring(e) end end
  return true
end
function T.status()
  local st = {}
  for k, v in pairs(T.stats) do st[#st + 1] = k .. "=" .. tostring(v) end
  table.sort(st)
  return string.format("ground %s carry=%s remove=%s amount=%s host's items this copy lacks=%s err=%s | %s", T.version, tostring(T.on.carry), tostring(T.on.remove),
    tostring(T.on.amount), tostring(T.missing), tostring(T.lastErr), table.concat(st, " "))
end
C.register("trees", { onWorld = onWorld, tick = tick, onMessage = onMessage })
return "coop_x_trees " .. T.version .. " loaded"
