-- Manor Lords Co-op: native patch switch (plug-in module "patch").
-- On a friend's copy the host decides every death and every rout. This module loads coop_patch.dll (native\coop_patch)
-- and tells it to switch off the friend's own kills (NOKILL, patch P1) and own routs (NOROUT, patch P2). The host's
-- routs and reforms are then replayed here with the game's own functions: Coop.patch.rout(h) / Coop.patch.reform(h).
-- Coop.patch.finish(building) finishes a construction site with the game's own finishConstruction.
-- GOODS (lane 14): on a friend's copy the stock of a building changes only on the host's word; see "GOODS" below
-- and research/2026-11-10-game-probe/lanes/lane_s21_14/report.txt (run live on one and on two copies).
-- On unless coop.cfg has "native = off". Coop.patch.enable() switches it on from the console.
--   status: DLL built and tested without the game (native\coop_patch\README.md); the offline signature check passed
--           against the installed game file
--   status: in the game: not yet run live (probes: native\coop_patch\probes\probe_patch_step1.lua, step2)
-- How it talks to the DLL: the DLL's only export is coop_patch_tick, called here once per frame on the game thread.
-- Commands go into patch_cmd.txt (one per line, appended), the answer comes back in patch_status.txt. Both live in the
-- DLL's folder (here: the mod folder), or "dir=" of coop_patch.cfg, plus a <COOP_NAME> (else <COOP_ROLE>) subfolder
-- when that environment variable is set (two copies on one PC). The rule below is the same as the DLL's.

local C = _G.Coop; local A = C.api
C.patch = C.patch or {}
local P = C.patch

-- ---- paths: <mod folder>/coop_patch.dll, from this file's own path (.../Mods/ManorLordsCoop/Scripts/coop_patch.lua)
local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local scripts = here:match("^(.*)/[^/]*$") or "."
local modDir = scripts:match("^(.*)/[^/]*$") or "."

local function readCfg(path)
  local cfg = {}
  local f = io.open(path, "r"); if not f then return cfg end
  for line in f:lines() do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k and not line:match("^%s*#") then cfg[k:lower()] = v end
  end
  f:close()
  return cfg
end

-- the DLL's folder rule (coop_patch.c resolve_dir): DLL folder, or coop_patch.cfg "dir=" (%VARS% expanded, relative to
-- the DLL folder), then a <COOP_NAME> subfolder (else <COOP_ROLE>) when that environment variable is set
local function ioDirFor(dll)
  local dllDir = dll:match("^(.*)[\\/][^\\/]*$") or "."
  local dir = dllDir .. "\\"
  local v = readCfg(dllDir .. "\\coop_patch.cfg").dir
  if v and v ~= "" then
    v = (v:gsub("%%([^%%]+)%%", function(n) return os.getenv(n) or ("%" .. n .. "%") end)):gsub("/", "\\")
    if v:match("^%a:") or v:match("^\\\\") then dir = v else dir = dllDir .. "\\" .. v end
    if dir:sub(-1) ~= "\\" then dir = dir .. "\\" end
  end
  local name = os.getenv("COOP_NAME")
  if not name or name == "" then name = os.getenv("COOP_ROLE") end
  if name and name ~= "" then dir = dir .. (name:gsub("[^%w_%-]", "_")) .. "\\" end
  return dir
end

local function setDll(path)
  P.dll = path:gsub("/", "\\")
  P.dir = ioDirFor(P.dll)
  P.cmdPath = P.dir .. "patch_cmd.txt"
  P.statusPath = P.dir .. "patch_status.txt"
end
if not P.dll then setDll(modDir .. "/coop_patch.dll") end
if P.wanted == nil then P.wanted = (readCfg(modDir .. "/coop.cfg").native or ""):lower() ~= "off" end   -- on by default (session 18); "native = off" in coop.cfg switches it off
function P.cfgGet(key) return readCfg(modDir .. "/coop.cfg")[key] end      -- (lane 64, round 5) one key of coop.cfg, for another module

-- ---- the DLL
local function log(fmt, ...) if C.s then A.log("patch: " .. fmt, ...) end end

-- (lane 47) the command file stays open: an open, append and close cost 160 us a command (sitting b1, x47_probe.lua
-- "chan"), a write and flush on a kept handle 5 us. The DLL reads it by size; opened again every 5 s.
local CMDF = { f = nil, path = nil, t = -1e9 }
function P.send(line)
  local t = os.clock()
  if not (CMDF.f and CMDF.path == P.cmdPath and t - CMDF.t < 5.0) then
    if CMDF.f then pcall(io.close, CMDF.f) end
    CMDF.f = io.open(P.cmdPath, "ab"); CMDF.path = P.cmdPath; CMDF.t = t
    if not CMDF.f then CMDF.path = nil; return false end
  end
  if not CMDF.f:write(line, "\n") then pcall(io.close, CMDF.f); CMDF.f = nil; CMDF.path = nil; return false end
  CMDF.f:flush()
  return true
end

-- loads the DLL once (it pins itself; it is never unloaded) and runs its first tick: the scan, about 0.2 s, one time
function P.load()
  if P.fn then return true, "already loaded" end
  local fn, err, where = package.loadlib(P.dll, "coop_patch_tick")
  if not fn then
    P.err = tostring(err) .. " (" .. tostring(where) .. ")"
    log("cannot load %s: %s", P.dll, P.err)
    return false, P.err
  end
  P.fn = fn
  local ok, e = pcall(fn)                 -- first tick: scan, status file; old lines in patch_cmd.txt are skipped
  log("loaded %s (first tick %s), files in %s", P.dll, ok and "ok" or tostring(e), P.dir)
  return true, "loaded"
end

function P.tick()                              -- lane 45: the native piece's own time, counted as "native"
  if not P.fn then return end
  local t0 = os.clock(); pcall(P.fn)
  if C.costAdd then C.costAdd("native", (os.clock() - t0) * 1000) end
end

-- console: Coop.patch.enable() or Coop.patch.enable([[C:\path\coop_patch.dll]])
function P.enable(path)
  if path and not P.fn then setDll(path) end
  P.wanted = true
  local ok, msg = P.load()
  return (ok and "patch module on: " or "patch module NOT loaded: ") .. msg .. " (files in " .. P.dir .. ")"
end

-- console: put every patched byte back and stop sending (the DLL stays loaded)
function P.disable()
  if P.fn then P.send("ALLOFF"); P.tick() end
  P.wanted = false; P.ndOn = false                 -- (lane 64) NODEATH went off with ALLOFF: sent again when enabled
  return "patch module off, ALLOFF sent"
end

-- ---- status file, read at most once a second (lane 65: was twice; each read is an open, see coop_steam.lua status)
local MT = { __tostring = function(t) return t.text or ("patch status: " .. tostring(t.state)) end }
function P.status()
  local t = os.clock()
  if P.st and t - (P.stT or -1) < 1.0 then return P.st end
  P.stT = t
  local f = io.open(P.statusPath, "rb")
  -- lane 45: the file read again, but parsed only when its text changed (the parse was 0.4 ms a frame on a friend)
  local text = f and (f:read("a") or "") or nil
  if f then f:close() end
  if text and P.st and P.st.text == text then return P.st end
  local st = setmetatable({ state = "missing", items = {}, calls = {}, goods = {}, rout = false, reform = false, text = "" }, MT)
  if text then
    st.text = text
    local first = true
    for line in st.text:gmatch("[^\r\n]+") do
      local w1, rest = line:match("^(%S+)%s*(.-)%s*$")
      if first then
        first = false; st.state = w1
        if w1 == "ready" then st.stamp, st.size = rest:match("^(%x+)%s+(%x+)"); st.knownBuild = st.stamp == "6836C1BA"
        else st.reason = rest end
      elseif w1 == "ROUT" or w1 == "REFORM" or w1 == "FINISH" or w1 == "BURN" or w1 == "FIREOUT" then
        st[w1:lower()] = rest:match("^available") ~= nil
        if not st[w1:lower()] then st[w1:lower() .. "Why"] = rest:gsub("^unavailable%s*", "") end
      elseif w1 == "calls" then
        for k, v in rest:gmatch("(%w+)=(%d+)") do st.calls[k] = tonumber(v) end
      elseif w1 == "goods" then                  -- the counters of the GOODS switch (frozen, putback, leaks ...)
        for k, v in rest:gmatch("(%w+)=(%d+)") do st.goods[k] = tonumber(v) end
      elseif w1 == "process" then
        st.pid = tonumber(rest:match("^(%d+)"))
      elseif w1 then
        local s, why = rest:match("^(%S+)%s*(.-)$")
        st.items[w1] = { state = s, why = why }
      end
    end
    if st.state == "off" then st.rout = false; st.reform = false; st.finish = false; st.burn = false; st.fireout = false end
  end
  P.st = st
  return st
end

-- (lane 66) the state of item NT (NOTHEFT) on this copy: "on", "off", "unavailable", or "missing" (no native piece, or
-- one older than 0.9.2 that has no such item)
function P.noTheft()
  if not P.fn then return "missing" end
  local it = P.status().items.NT
  return it and tostring(it.state) or "missing"
end

-- (lane 64, round 5) the state of item NM (NOMOURN) on this copy: "on" = this copy's own game no longer takes a day
-- off a home's mourning; "off", "unavailable", or "missing" (no native piece, or one older than 0.9.10)
function P.noMourn()
  if not P.fn then return "missing" end
  local it = P.status().items.NM
  return it and tostring(it.state) or "missing"
end

-- ---- replaying the host's decisions (friend's copy). h = this copy's squad number (A.toLocal of the host's number).
-- TriggerSquadRetreat does not check whether the squad already routs (report native5 answer 5): only when Control ~= 3.
local function squadControl(S, h)
  local ctl, n
  pcall(function() n = S.sc:GetUnitCount({ Value = h }) end)
  pcall(function() ctl = S.sc:GetSquad({ Value = h }).Control end)
  return ctl, n
end

local function addrText(a)
  local i = math.tointeger(a)
  if i then return string.format("%d", i) end
  return string.format("%.0f", a)
end

local function call(kind, h, wantCtl)
  local S = C.s
  if not P.fn then return false, "DLL not loaded" end
  if not (S and A.valid(S.sc)) then return false, "no SquadComponent" end
  local st = P.status()
  if not st[kind:lower()] then return false, kind .. " unavailable (" .. tostring(st[kind:lower() .. "Why"] or st.reason or st.state) .. ")" end
  h = math.tointeger(tonumber(h)); if not h or h == 0 then return false, "bad squad number" end
  local ctl, n = squadControl(S, h)
  if not n or n <= 0 then return false, "squad " .. h .. " has no soldiers here" end
  if wantCtl == 3 and ctl == 3 then return false, "squad " .. h .. " already routs" end
  if wantCtl == 0 and ctl ~= 3 then return false, "squad " .. h .. " does not rout (Control " .. tostring(ctl) .. ")" end
  if wantCtl == 4 and ctl ~= 4 then return false, "squad " .. h .. " does not hold a camp (Control " .. tostring(ctl) .. ")" end
  local addr = S.sc:GetAddress()
  if not addr or addr == 0 then return false, "no SquadComponent address" end
  P.send(string.format("%s %s %d", kind, addrText(addr), h))
  P.tick()                                   -- run it now, in this same game-thread frame
  log("%s %d sent", kind, h)
  return true, "sent"
end

function P.rout(h) return call("ROUT", h, 3) end        -- the squad must not be routing yet
function P.reform(h) return call("REFORM", h, 0) end    -- the squad must be routing (Control == 3)
-- (lane 32) an encamped squad (Control == 4) lets go of its camp with the game's own routine (native UNCAMP, 4d72b60:
-- camp cleared, Control 0), after which it takes move and attack orders again. (reformSquad was tried first: it ran
-- and left Control at 4.) lanes/lane_s21_32/report.txt item 1.
function P.release(h)
  local S = C.s
  if not P.fn then return false, "DLL not loaded" end
  if not (S and A.valid(S.sc)) then return false, "no SquadComponent" end
  h = math.tointeger(tonumber(h)); if not h or h == 0 then return false, "bad squad number" end
  local ctl, n = squadControl(S, h)
  if not n or n <= 0 then return false, "squad " .. h .. " has no soldiers here" end
  if ctl ~= 4 then return false, "squad " .. h .. " does not hold a camp (Control " .. tostring(ctl) .. ")" end
  local r, why = P.ask("UNCAMP", addrText(S.sc:GetAddress()) .. " " .. h)
  if not r then return false, why end
  log("UNCAMP %d sent", h)
  return true, "sent"
end

-- Finish a construction site with the game's own finishConstruction (native, RVA 4d0b370 in 0.8.117): the routine the
-- builder's hammer calls when all goods are delivered and no part needs more work. building = the SMBuildingMaster
-- object. The routine has no "already built" guard at its start (static read, README): a second call repeats its side
-- effects, so a building whose Data.constructed is already true is refused. force = true skips that check (console).
--   status: not yet run live
function P.finish(building, force)
  if not P.fn then return false, "DLL not loaded" end
  if building == nil or not A.valid(building) then return false, "building is nil or not valid" end
  local st = P.status()
  if not st.finish then return false, "FINISH unavailable (" .. tostring(st.finishWhy or st.reason or st.state) .. ")" end
  if not force then
    local ok, built = pcall(function() return building.Data.constructed end)
    if not ok then return false, "cannot read Data.constructed (not a building?)" end
    if built == true then return false, "already constructed" end
  end
  local okA, addr = pcall(function() return building:GetAddress() end)
  if not okA or not addr or addr == 0 then return false, "no building address" end
  P.send("FINISH " .. addrText(addr))
  P.tick()                                   -- run it now, in this same game-thread frame
  log("FINISH %s sent", addrText(addr))
  return true, "sent"
end

-- A burning building on this copy, made to match the host's ending (lane_f Q3; both routines are the game's own):
--   P.burn(b)     burns it down now: progressFire with a huge time step (native, RVA 4d49af0). The routine does not test
--                 "on fire" itself, so this refuses a building that is not burning (and the DLL checks again), and one
--                 whose change to the "debris" type has not landed yet. fireAmt is set to 0.3 first: at or below 0.35 the
--                 routine skips its fire-spread code.
--   P.fireout(b)  puts it out now: extinguishFire (native, RVA 4d4a530); the building becomes an unfinished site.
--   status: mechanism tests pass (native/coop_patch, 95 checks); live: see README session 20
local function fireCall(cmd, flag, building)
  if not P.fn then return false, "DLL not loaded" end
  if building == nil or not A.valid(building) then return false, "building is nil or not valid" end
  local st = P.status()
  if not st[flag] then return false, cmd .. " unavailable (" .. tostring(st[flag .. "Why"] or st.reason or st.state) .. ")" end
  local okF, burning = pcall(function() return building.onFire end)
  if not okF or not burning then return false, "not on fire" end
  local okR, rubble = pcall(function() return building:IsRubble() end)
  if not okR or not rubble then return false, "its change to debris has not landed yet" end
  local okA, addr = pcall(function() return building:GetAddress() end)
  if not okA or not addr or addr == 0 then return false, "no building address" end
  if cmd == "BURN" then pcall(function() building.fireAmt = 0.3 end) end
  P.send(cmd .. " " .. addrText(addr))
  P.tick()                                   -- run it now, in this same game-thread frame
  log("%s %s sent", cmd, addrText(addr))
  return true, "sent"
end
function P.burn(building) return fireCall("BURN", "burn", building) end
function P.fireout(building) return fireCall("FIREOUT", "fireout", building) end

-- ---- GOODS: on a friend's copy the stock of a building changes only on the host's word (lane 14)
-- The DLL hooks the two routines the game runs after it changed a building's Inventory (recountStorage and the
-- region's refresh of a building) and puts the amounts back to what the mod last wrote; the friend's villagers go on
-- walking, working and carrying. The mod's own write (SMBuildingMaster:addToInventory, from any module) is
-- recognised by the DLL and remembered: that is the host's word. So are FINISH, BURN and FIREOUT above.
--   P.goodsOn()        true while the switch is on in this copy (read from the status file: the bytes in memory)
--   P.goodsAvail()     true when it could be switched on (the three signatures hold): what a host reads to know
--                      whether to send every building's stock (coop_facts.lua)
--   P.pilegone(b)      the host's pile is gone: empty this copy's pile and let the game remove it
--   coop.cfg "goods = off" keeps it off. Evidence: research/2026-11-10-game-probe/lanes/lane_s21_14/report.txt
if P.goodsWanted == nil then P.goodsWanted = (readCfg(modDir .. "/coop.cfg").goods or ""):lower() ~= "off" end
P.cfg = P.cfg or {}
if P.cfg.auditEvery == nil then P.cfg.auditEvery = 5.0 end      -- seconds between two GOODS AUDIT while the switch is on (0 = never)

function P.goodsOn()
  if not P.fn then return false end
  local it = P.status().items.GOODS
  return it ~= nil and it.state == "on"
end
function P.goodsAvail()
  if not (P.fn and P.wanted and P.goodsWanted) then return false end
  local st = P.status()
  local it = st.items.GOODS
  return st.state == "ready" and it ~= nil and (it.state == "on" or it.state == "off")
end
function P.pilegone(building)
  if not P.fn then return false, "DLL not loaded" end
  if building == nil or not A.valid(building) then return false, "building is nil or not valid" end
  if not P.goodsOn() then return false, "GOODS is not on" end
  local okT, t = pcall(function() return building:GetType() end)
  if not okT or t ~= 88 then return false, "not a pile (type " .. tostring(t) .. ")" end
  local okA, addr = pcall(function() return building:GetAddress() end)
  if not okA or not addr or addr == 0 then return false, "no building address" end
  P.send("PILEGONE " .. addrText(addr))
  P.tick()
  log("PILEGONE %s sent", addrText(addr))
  return true, "sent"
end
-- the switch for this copy, each tick: want = on or off; sent only when it changes (and again every 2 s while the
-- status file says otherwise, so a refused or lost command is seen in the log, not silently assumed)
local function goodsStep(S, want)
  if not P.goodsWanted then want = false end
  local clock = os.clock()
  if want ~= (P.gOn or false) or (want and clock - (P.gT or 0) > 2.0 and not P.goodsOn() and P.goodsAvail()) then
    P.gOn = want; P.gT = clock
    if want then
      local pawn = "0"
      pcall(function() if A.valid(S.p1) then pawn = addrText(S.p1:GetAddress()) end end)
      P.send("GOODS ON " .. pawn)
    else P.send("GOODS OFF") end
    P.tick(); P.stT = nil                      -- run it now and read the status again
    log("%s copy: GOODS %s (status: %s)", tostring(S.role), want and "ON" or "OFF", tostring((P.status().items.GOODS or {}).state))
  end
  if want and P.cfg.auditEvery > 0 and clock - (P.gAudit or 0) >= P.cfg.auditEvery then
    P.gAudit = clock; P.send("GOODS AUDIT")
  end
end

-- ---- TOTALS (lane 22): on a friend's copy a region's totals of goods (the top bar) change only on the host's word
-- The DLL hooks the game's "add a list of goods to a list" routine: a change of the totals of a region the mod has
-- written (TOTALS SET) goes into the DLL's shadow of those totals instead (the game's own bookkeeping). The world
-- module writes the host's totals with P.totalsSet; when the switch goes off the shadow is written back (the recount),
-- so the totals are again this copy's own buildings plus what its people carry.
--   P.totalsOn()     true while the hook is in (read from the status file)
--   P.totalsSet(r, map)   map = { [good] = amount }: the host's totals of region r; returns ok, message
-- On exactly while GOODS is on (the totals are buildings plus hands; without exact buildings the old region rule runs).
-- coop.cfg "totals = off" keeps it off. Evidence: research/2026-11-10-game-probe/lanes/lane_s21_22/report.txt
if P.totalsWanted == nil then P.totalsWanted = (readCfg(modDir .. "/coop.cfg").totals or ""):lower() ~= "off" end
if P.cfg.totalsAuditEvery == nil then P.cfg.totalsAuditEvery = 5.0 end

function P.totalsOn()
  if not P.fn then return false end
  local it = P.status().items.TOTALS
  return it ~= nil and it.state == "on"
end
function P.totalsSet(r, map, all, reserved)     -- reserved = true: the list minus what is reserved (TOTALS SETR)
  if not (P.fn and P.tOn) then return false, "TOTALS is not on" end
  local okA, addr = pcall(function() return r:GetAddress() end)
  if not okA or not addr or addr == 0 then return false, "no region address" end
  local ks = {}; for g in pairs(map) do ks[#ks + 1] = g end; table.sort(ks)
  local items = {}; for _, g in ipairs(ks) do items[#items + 1] = string.format("%d=%d", g, math.floor(map[g] + 0.5)) end
  P.send((reserved and "TOTALS SETR " or "TOTALS SET ") .. addrText(addr) .. " " .. (#items > 0 and table.concat(items, ",") or "-") .. (all and " ALL" or ""))
  P.tick()                                   -- now, in this same game-thread frame
  return true, "sent"
end
-- forget = true: drop the shadows without writing them (a new world: the regions are other objects now)
local function totalsStep(S, want, forget)
  if not (P.totalsWanted and P.goodsWanted) then want = false end
  local clock = os.clock()
  if want ~= (P.tOn or false) or (want and clock - (P.tT or 0) > 2.0 and not P.totalsOn()) then
    local avail = P.status().items.TOTALS
    if want and not (avail and (avail.state == "on" or avail.state == "off")) then
      if not P.tSaid then P.tSaid = true; log("TOTALS not used here: %s", tostring(avail and (avail.state .. " " .. tostring(avail.why)) or "not in the status (old DLL)")) end
      P.tOn = false; return
    end
    P.tOn = want; P.tT = clock
    if want then P.tGen = (P.tGen or 0) + 1 end   -- the world module writes every region again after a new ON
    P.send(want and "TOTALS ON" or (forget and "TOTALS FORGET" or "TOTALS OFF"))
    P.tick(); P.stT = nil
    log("%s copy: TOTALS %s (status: %s)", tostring(S.role), want and "ON" or (forget and "FORGET" or "OFF (recount)"), tostring((P.status().items.TOTALS or {}).state))
  end
  if want and P.cfg.totalsAuditEvery > 0 and clock - (P.tAudit or 0) >= P.cfg.totalsAuditEvery then
    P.tAudit = clock; P.send("TOTALS AUDIT")
  end
end

-- ---- lane 42: DIST (a house's market goods on the host's word, coop_patch item DIST). Friend only, with GOODS (exact
-- mode: the host sends every house's list, coop_facts.lua F D). On: the game's own distribution still runs on this copy,
-- and right after it every house the host named gets the host's list back (native/coop_patch/README.md, DIST).
--   P.distOn()                 whether DIST is on (this module switched it on and the DLL says so)
--   P.distSet(addr, list)      the host's list for a house ("<type>:<amount>,..." or "-"); false while DIST is off
--   P.dGen                     changes each time DIST is switched on (a friend hands every house over again)
function P.distOn() return P.dOn == true end
function P.distSet(a, list)
  if not P.dOn or type(a) ~= "number" or type(list) ~= "string" or not list:match("^[%d:,%-]+$") then return false end
  P.send(string.format("DIST SET 0x%X %s", a, list)); return true
end
local function distStep(S, want)
  if want == (P.dOn or false) then return end
  if want then
    local it = P.status().items.DIST
    if not it or (it.state ~= "on" and it.state ~= "off") then
      if not P.dSaid then P.dSaid = true; log("DIST %s: a house's market goods stay this copy's own", it and (tostring(it.state) .. " " .. tostring(it.why)) or "not in the status (old DLL)") end
      return
    end
    P.send("DIST FORGET"); P.send("DIST ON"); P.tick(); P.stT = nil
    local now = P.status().items.DIST
    P.dOn = now ~= nil and now.state == "on"; P.dGen = (P.dGen or 0) + 1
    log("DIST ON: %s", tostring(now and now.state))
  else
    P.dOn = false; P.send("DIST OFF"); P.send("DIST FORGET"); P.tick(); P.stT = nil
    log("DIST OFF (a load, a release or GOODS off): a house's market goods are this copy's own game's again")
  end
end

-- ---- HOLD (lane 31): on a friend's copy the numbers of a region's panel change only on the host's word
-- The DLL hooks seven routines of a region (updateApproval, the public order, the months of food and fuel, the two
-- wealth routines, add and remove a problem) and the monthly wealth store; for a region the mod has named (HOLD SET)
-- they do not run. The world module then writes the host's values: Approval, publicOrder, the months and the wealth
-- through reflection, the factor lists with P.holdRows and the problem list with P.holdProb (the game's own add and
-- remove). HOLD OFF (a release, a load, a role change) rebuilds approval once with the game's own routine.
--   P.holdOn()                   true while the hooks are in (read from the status file)
--   P.holdSet(r)                 hold region r from now on
--   P.holdRows(r, "A"|"O"|"M", text)   a whole list: "type:past:effect:day:exp:count/..." or "-"
--   P.holdProb(r, text)          the problem list: "type:building address:unit address/..." or "-"
-- On while GOODS is (the host's exact mode). coop.cfg "hold = off" keeps it off.
-- Evidence: research/2026-11-10-game-probe/lanes/lane_s21_31/report.txt
if P.holdWanted == nil then P.holdWanted = (readCfg(modDir .. "/coop.cfg").hold or ""):lower() ~= "off" end
function P.holdOn()
  if not P.fn then return false end
  local it = P.status().items.HOLD
  return it ~= nil and it.state == "on"
end
local function regionAddr(r)
  local okA, a = pcall(function() return r:GetAddress() end)
  if okA and a and a ~= 0 then return addrText(a) end
end
function P.holdSet(r)
  if not (P.fn and P.hOn) then return false, "HOLD is not on" end
  local a = regionAddr(r); if not a then return false, "no region address" end
  P.send("HOLD SET " .. a); P.tick()
  return true, "sent"
end
function P.holdRows(r, which, text)
  if not (P.fn and P.hOn) then return false, "HOLD is not on" end
  local a = regionAddr(r); if not a then return false, "no region address" end
  P.send(string.format("HOLD ROWS %s %s %s", a, which, (text ~= nil and text ~= "") and text or "-")); P.tick()
  return true, "sent"
end
function P.holdProb(r, text)
  if not (P.fn and P.hOn) then return false, "HOLD is not on" end
  local a = regionAddr(r); if not a then return false, "no region address" end
  P.send(string.format("HOLD PROB %s %s", a, (text ~= nil and text ~= "") and text or "-")); P.tick()
  return true, "sent"
end
-- forget = true: no recount (a new world: the regions are other objects now)
local function holdStep(S, want, forget)
  if not P.holdWanted then want = false end
  local clock = os.clock()
  if want ~= (P.hOn or false) or (want and clock - (P.hT or 0) > 2.0 and not P.holdOn()) then
    local avail = P.status().items.HOLD
    if want and not (avail and (avail.state == "on" or avail.state == "off")) then
      if not P.hSaid then P.hSaid = true; log("HOLD not used here: %s", tostring(avail and (avail.state .. " " .. tostring(avail.why)) or "not in the status (old DLL)")) end
      P.hOn = false; return
    end
    P.hOn = want; P.hT = clock
    if want then P.hGen = (P.hGen or 0) + 1 end    -- the world module names every region again after a new ON
    P.send(want and "HOLD ON" or (forget and "HOLD FORGET" or "HOLD OFF"))
    P.tick(); P.stT = nil
    log("%s copy: HOLD %s (status: %s)", tostring(S.role), want and "ON" or (forget and "FORGET" or "OFF (recount)"), tostring((P.status().items.HOLD or {}).state))
  end
end

-- ---- lane 19: JOBGATE (site JG, executeTask's test of the engine's job list). Used only on a friend's copy, by the job
-- board (coop_x_jobs.lua), which fills the list after the byte is on and empties it before the byte goes off. Returns
-- ok, message; ok is false when the item is unavailable (another game build: the signature was not found).
function P.jobGate(on)
  if not P.fn then return false, "DLL not loaded" end
  local it = P.status().items.JG
  if not it or (it.state ~= "on" and it.state ~= "off") then return false, "JG " .. (it and (tostring(it.state) .. " " .. tostring(it.why)) or "not in the status (old DLL)") end
  P.send(on and "JOBGATE ON" or "JOBGATE OFF"); P.tick(); P.stT = nil
  local now = P.status().items.JG
  local ok = now ~= nil and now.state == (on and "on" or "off")
  log("JOBGATE %s: JG %s", on and "ON" or "OFF", tostring(now and now.state))
  return ok, "JG " .. tostring(now and now.state)
end

-- ---- lane 23: CHOOSE (the job chooser runs for the villagers named, coop_patch item CHOOSE). Used only on a friend's
-- copy, by the job board, while its gate is on: the villagers whose host task is one the game restarts every work cycle.
--   P.choose(on)        the hook on or off; returns ok, message (ok false when the item is unavailable)
--   P.chooseSet(addrs)  the whole list (a Lua list of addresses as numbers); sent as one command
function P.choose(on)
  if not P.fn then return false, "DLL not loaded" end
  local it = P.status().items.CHOOSE
  if not it or (it.state ~= "on" and it.state ~= "off") then return false, "CHOOSE " .. (it and (tostring(it.state) .. " " .. tostring(it.why)) or "not in the status (old DLL)") end
  P.send(on and "CHOOSE ON" or "CHOOSE OFF"); P.tick(); P.stT = nil
  local now = P.status().items.CHOOSE
  local ok = now ~= nil and now.state == (on and "on" or "off")
  log("CHOOSE %s: %s", on and "ON" or "OFF", tostring(now and now.state))
  return ok, "CHOOSE " .. tostring(now and now.state)
end
function P.chooseSet(addrs)
  if not P.fn then return false end
  local s = {}
  for i = 1, math.min(#addrs, 256) do s[#s + 1] = string.format("%X", addrs[i]) end
  P.send("CHOOSE SET " .. (#s > 0 and table.concat(s, ",") or "-")); P.tick()
  return true
end

-- ---- lane 35: PICK (the job chooser's pick held to the host's task, coop_patch item PICK). Friend only, by the job
-- board, with CHOOSE: for the villagers on a host task the game restarts every cycle (selling, mining, an ox) the
-- chooser may start only that task (type, and for an ox the ox); another pick gets the board's last record instead.
--   P.pick(on)          the two hooks on or off; returns ok, message
--   P.pickSet(list)     the whole list: { { addr, type, targetUnitAddr or 0 }, ... }; sent as one command
function P.pick(on)
  if not P.fn then return false, "DLL not loaded" end
  local it = P.status().items.PICK
  if not it or (it.state ~= "on" and it.state ~= "off") then return false, "PICK " .. (it and (tostring(it.state) .. " " .. tostring(it.why)) or "not in the status (old DLL)") end
  P.send(on and "PICK ON" or "PICK OFF"); P.tick(); P.stT = nil
  local now = P.status().items.PICK
  local ok = now ~= nil and now.state == (on and "on" or "off")
  log("PICK %s: %s", on and "ON" or "OFF", tostring(now and now.state))
  return ok, "PICK " .. tostring(now and now.state)
end
-- (lane 35, round six) objects leaving the game: PICK drops every entry that names one, and never keeps or sets a
-- record naming one again. addrs: a Lua list of addresses.
function P.pickGone(addrs)
  if not P.fn or #addrs == 0 then return false end
  local s = {}
  for i = 1, math.min(#addrs, 64) do s[#s + 1] = string.format("%X", addrs[i]) end
  P.send("PICK GONE " .. table.concat(s, ",")); P.tick()
  return true
end
-- (lane 46) buildings being demolished: GOODS forgets them and never puts stock back into them, repairs or takes them
-- in again; DIST drops them (coop_patch README "GOODS and a demolished building"). Stock put back into a demolished
-- building made the game register it in its region's building sets again (the friend's chooser crash). The DLL also
-- sees the game's demolish itself (signature DEMREF); this is the second net, sent before the game removes it.
function P.goodsGone(addrs)
  if not P.fn or #addrs == 0 or not P.goodsOn() then return false end
  local s = {}
  for i = 1, math.min(#addrs, 32) do s[#s + 1] = string.format("0x%X", addrs[i]) end
  P.send("GOODS GONE " .. table.concat(s, ",")); P.tick()
  return true
end
-- (lane 35, round six) REGSET: a region's two building sets (+5A8h, +5F8h) that the job chooser walks. The game takes a
-- demolished building out of them only through the building's region; on a friend a demolished building can have
-- none, it stays in the set, is freed, and the chooser reads freed memory (the friend's crash in 4d45360).
--   P.regsetClean(regionAddr, alive)  members of both sets that are not in `alive` (a set of building addresses) are
--                                     taken out with the game's own set removal; returns how many were dropped, or nil
function P.regsetClean(ra, alive, dry)   -- dry: count only (test probes), nothing dropped
  if not P.fn then return nil end
  local it = P.status().items.REGSET
  if not it or it.state ~= "available" then return nil end
  P.send(string.format("REGSET LIST %X", ra)); P.tick()
  local f = io.open(P.dir .. "regset.txt", "rb"); if not f then return nil end
  local txt = f:read("a") or ""; f:close()
  if not txt:find("END") then return nil end
  local drop, seen = {}, {}
  for a in txt:gmatch("%+%x+ (%x+)") do local v = tonumber(a, 16); if v and not alive[v] and not seen[v] then seen[v] = true; drop[#drop + 1] = a end end
  if #drop == 0 or dry then return #drop, drop end
  for i = 1, #drop, 64 do P.send(string.format("REGSET DROP %X %s", ra, table.concat(drop, ",", i, math.min(#drop, i + 63)))) end
  P.tick()
  return #drop
end
-- (lane 49, round four) ENDHOLD: a board unit's task ends on the host's word (coop_patch README "ENDHOLD").
--   P.endHold(on)                  the end-task hook in or out; true when on
--   P.endHoldSet(ceilMs, list)     the list, whole: { { unit address, task type, target building address or 0 }, ... }
function P.endHold(on)
  if not P.fn then return false end
  local it = P.status().items.ENDHOLD
  if not it or it.state == "unavailable" then return false end
  P.send(on and "ENDHOLD ON" or "ENDHOLD OFF"); P.tick()
  return true
end
function P.endHoldSet(ceilMs, list)
  if not P.fn then return false end
  local s = {}
  for i = 1, math.min(#list, 110) do local x = list[i]; s[#s + 1] = string.format("%X:%X:%X:%X", x[1], x[2], x[3] or 0, x[4] or 0) end   -- x[4]: the host's start number
  P.send(string.format("ENDHOLD SET %X %s", math.max(1, math.floor(ceilMs)), #s > 0 and table.concat(s, ",") or "-")); P.tick()
  return true
end
-- (lane 74, round 3) OXCART, part of PICK (coop_patch README "PICK"): a friend's ox does not take a timber cart by its
-- own choice. P.pickOxen(addrs): the board's oxen (the whole list; {} = none). P.pickTimber(classAddr): the timber
-- cart's class (0 = unset). Both are only stored by the DLL; an older DLL refuses them (counted as bad, nothing else).
function P.pickOxen(addrs)
  if not P.fn then return false end
  local s = {}
  for i = 1, math.min(#addrs, 64) do s[#s + 1] = string.format("%X", addrs[i]) end
  P.send("PICK OXEN " .. (#s > 0 and table.concat(s, ",") or "-")); P.tick()
  return true
end
function P.pickTimber(classAddr)
  if not P.fn then return false end
  P.send(string.format("PICK TIMBER %X", classAddr or 0)); P.tick()
  return true
end
-- (lane 74, round 7) HANDCART, part of PICK (coop_patch README "PICK"): a friend's villager does not take a hand cart by
-- its own choice. P.pickHandcart(classAddr): the hand cart's class (0 = unset); only stored by the DLL; an older DLL
-- refuses it (counted as bad, nothing else).
function P.pickHandcart(classAddr)
  if not P.fn then return false end
  P.send(string.format("PICK HANDCART %X", classAddr or 0)); P.tick()
  return true
end
function P.pickSet(list)
  if not P.fn then return false end
  local s = {}
  for i = 1, math.min(#list, 256) do local x = list[i]; s[#s + 1] = string.format("%X:%X:%X", x[1], x[2], x[3] or 0) end
  P.send("PICK SET " .. (#s > 0 and table.concat(s, ",") or "-")); P.tick()
  return true
end
-- (lane 49) GUIDE: which villager guides which ox (+330h, not reflected; coop_patch README "GUIDE").
--   P.guideSet(ox, leader, units)   every unit of `units` (addresses) other than the leader that holds the ox lets go,
--                                   then the leader holds it (what the game's own guide assignment writes first)
--   P.guideList(units)              { [address] = its +330h } (test probes)
--   P.guideClear(gone, units)       every unit of `units` holding one of the `gone` addresses lets go
local function guideAvail() if not P.fn then return false end; local it = P.status().items.GUIDE; return it ~= nil and it.state == "available" end
P.guideAvail = guideAvail
local function hexList(t) local s = {}; for i = 1, math.min(#t, 512) do s[#s + 1] = string.format("%X", t[i]) end; return #s > 0 and table.concat(s, ",") or "-" end
function P.guideSet(ox, leader, units)
  if not guideAvail() then return false end
  P.send(string.format("GUIDE SET %X %X %s", ox, leader, hexList(units or {}))); P.tick()
  return true
end
function P.guideClear(gone, units)
  if not guideAvail() or #gone == 0 or #units == 0 then return false end
  P.send(string.format("GUIDE CLEAR %s %s", hexList(gone), hexList(units))); P.tick()
  return true
end
function P.guideList(units)
  if not guideAvail() or #units == 0 then return nil end
  P.send("GUIDE LIST " .. hexList(units)); P.tick()
  local f = io.open(P.dir .. "guide.txt", "rb"); if not f then return nil end
  local txt = f:read("a") or ""; f:close()
  if not txt:find("END") then return nil end
  local r = {}; for u, v in txt:gmatch("(%x+) (%x+)") do r[tonumber(u, 16)] = tonumber(v, 16) end
  return r
end

-- (lane 54) FELL: the tree being felled at a place falls at this copy's villager's next stroke (coop_patch README
-- "FELL": what is left of the tree, a float in a list of the region that is not reflected, is set to 0).
--   P.fell(region, x, y)   region = the address of the felling's target building's region; x, y = the tree's place (cm)
-- Whether the item is available is asked at most every 10 s (the status file is not read at every call).
local fellOk, fellT = false, -100
function P.fell(region, x, y)
  if not P.fn then return false end
  local t = os.clock()
  if t - fellT > 10.0 then fellT = t; local it = P.status().items.FELL; fellOk = it ~= nil and it.state == "available" end
  if not fellOk then return false end
  P.send(string.format("FELL %X %d %d", region, math.floor(x + 0.5), math.floor(y + 0.5))); P.tick()
  return true
end

-- (lane 88) MERCCUT: a friend's list of mercenary offers shortened to the host's length (coop_patch README "MERCCUT";
-- lanes/lane_s21_88/design_mercs.txt). P.mercAvail() says whether the item is there (asked at most every 10 s);
-- P.mercCut(engine, list, now, want) sends the command (engine: the RTSMultiEngineCPP's address; list: the address
-- the script layer gives for engine.availableMercs) and runs the tick, so the cut is done when it returns.
local mercOk, mercT = false, -100
function P.mercAvail()
  if not P.fn then return false end
  local t = os.clock()
  if t - mercT > 10.0 then mercT = t; local it = P.status().items.MERCCUT; mercOk = it ~= nil and it.state == "available" end
  return mercOk
end
function P.mercCut(engine, list, now, want)
  if not P.mercAvail() then return false end
  P.send(string.format("MERCCUT %X %X %d %d", engine, list, now, want)); P.tick()
  return true
end

-- (lane 87) NOROLL: a friend's own mercenary month roll returns at once (coop_patch README "NOROLL";
-- lanes/lane_s21_87/design_noroll.txt). Switched by the values module (coop_x_values.lua, beside MROLL).
-- P.noRollOn() says whether it is on here now (the status file, read at most once a second). P.noRollPass() lets the
-- NEXT call of the game's roll through, once, and runs the tick: the caller makes that call right after it, in the
-- same tick (the realm module, when this copy holds fewer offers than the host). Only while this copy's own notices
-- are dropped (NOLOG): the roll gives its player the notice "mercenaries_available", which a friend takes from the host.
function P.noRollOn()
  if not P.fn then return false end
  local it = P.status().items.NOROLL
  return it ~= nil and it.state == "on"
end
function P.noRollPass()
  if not (P.noRollOn() and P.nlOn == true) then return false end
  P.send("NOROLL PASS"); P.tick()
  return true
end

-- ---- lane 66: NOLOG and the mod's mark
-- P.markLog() is called right before the mod's own PawnCPP:addLog / addLogIfNew (coop_realm.lua's R LOG on a friend):
-- while NOLOG is on, that one call goes into the game's routine. It does nothing when the DLL has no such export.
local markFn, markTried
function P.markLog()
  if not P.fn then return false end
  if not markTried then
    markTried = true
    local fn = package.loadlib(P.dll, "coop_patch_mark")
    if fn then markFn = fn else log("NOLOG: the native piece has no coop_patch_mark (older than 0.9.3): this copy's own notices stay") end
  end
  if markFn then pcall(markFn); return true end
  return false
end
-- on: only while this copy plays in the host's world, and only once the item is there and armed ("off"); then "on" is
-- checked in the status. P.nlOn says whether this copy's own notices are dropped now.
local function nologStep(S, want)
  if not P.fn then P.nlOn = false; return end
  local it = P.status().items.NOLOG
  local state = it and it.state
  if want and state == "off" and P.nlSent ~= "on" and P.markLog() then
    P.nlSent = "on"; P.send("NOLOG ON"); P.tick(); P.stT = nil
    log("friend copy: NOLOG ON sent (this copy's own notices are dropped; the host's come by R LOG)")
  elseif not want and P.nlSent == "on" then
    P.nlSent = "off"; P.send("NOLOG OFF"); P.tick(); P.stT = nil
    log("friend copy: NOLOG OFF (a load or a hold)")
  elseif want and P.nlSent == "on" and state == "off" and os.clock() - (P.nlT or 0) > 10.0 then
    P.nlT = os.clock(); P.nlSent = nil                    -- the host's ALLOFF rule or a role change took it out: ask again
  end
  local now = (P.status().items.NOLOG or {}).state == "on"
  if now ~= (P.nlOn or false) then P.nlOn = now; log("NOLOG is %s on this copy%s", now and "on" or "off", now and "" or ((it and it.state == "unavailable") and (": " .. tostring(it.why)) or "")) end
end

-- ---- plug-in module
local function step(S, inWorld)
  if not P.wanted then return end
  if not P.fn then
    if P.tried then return end
    P.tried = true
    if not P.load() then return end
  end
  P.tick()
  if P.forS ~= S then P.forS = S; P.sentWorld = nil; P.hostOff = nil end
  if S.role == "host" then
    -- the host's copy stays unpatched: ALLOFF at start, and again whenever the status shows an item on (every 2 s)
    -- (test only: Coop.patch.test = { goods = true }, set through the development channel, keeps the GOODS switch
    -- on in a copy that runs alone as host, to see what the game does with it and nothing pushed: lane 14 step 3)
    local keep = P.test and P.test.goods
    local again = false
    if P.hostOff and os.clock() - (P.hostT or 0) > 2.0 then
      P.hostT = os.clock()
      -- (lane 48, round 3) lane 47's SNAP (a read service) and GUARD (the crash guard) are meant to be on on the host:
      -- counted as "on", they made this rule send ALLOFF every 2 s, which took the host's MEN hook (and SNAP) out
      -- each time (sitting n1: MEN HOOK ON, ALLOFF 50 ms later, every 2 s; 53 table empties in a minute)
      for name, it in pairs(P.status().items) do if it.state == "on" and name ~= "SNAP" and name ~= "GUARD" and not (keep and name == "GOODS") then again = true end end
    end
    if not P.hostOff or again then P.hostOff = true; P.hostT = os.clock(); P.send("ALLOFF"); P.gOn = false; P.tOn = false; P.hOn = false; P.ndOn = false; P.tkOn = false; log("host copy: ALLOFF (TOTALS: recount)") end
    if keep then goodsStep(S, inWorld and not C.hold) end
  elseif S.role == "friend" then
    if inWorld and P.sentWorld ~= S.worlds then
      P.sentWorld = S.worlds
      P.send("NOKILL ON"); P.send("NOROUT ON")
      -- NOREGION (the lead, 2026-11-13): a villager's work hit at a building that was taken out of the game a moment
      -- before read through a null region in the game's own code and closed a friend's game twice; with this on,
      -- the two routines leave instead (lanes/lane_s21_0/crash_demolish_site)
      P.send("NOREGION ON")
      -- NOTHEFT (lane 66): the bandits' daily theft is rolled by every copy's own game on the same calendar day, each
      -- with its own random good; on a friend's copy the routine's walk over the bandit squads is jumped over, so a
      -- theft happens only on the host and the events module tells it (E T). A DLL older than 0.9.2 does not know the
      -- command and logs it as unknown: then the friend's own theft and banner stay (the events module logs that).
      P.send("NOTHEFT ON")
      -- NOMOURN (lane 64, round 5): a friend's game no longer takes a day off a home's mourning at its own day change;
      -- the days are the host's alone (the facts module writes each host value as it comes). Before, the friend's own
      -- day step took a day off the value the host's line had already put right: one day less than the host for a
      -- frame after a reload. A DLL older than 0.9.10 does not know the command: the facts module then keeps its
      -- one-day rule (it asks P.noMourn).
      P.send("NOMOURN ON")
      log("friend copy, world %d: NOKILL ON, NOROUT ON, NOREGION ON, NOTHEFT ON, NOMOURN ON", S.worlds)
    end
    -- NOFINISH: on a friend's copy the game does not finish a building by itself; the host says when (the sites module
    -- calls FINISH). Each copy's builders pick their sites in their own order, so without this a friend could finish a
    -- building long before the host (session 20). It is on only while this copy plays in the host's world, and off
    -- while a save is loading, so a load runs exactly as in the unchanged game.
    local want = inWorld and not C.hold
    -- NOLOG (lane 66): this copy's game adds no notice of its own; the host's come by the realm module's R LOG and go in
    -- through the mod's mark (P.markLog, the DLL's coop_patch_mark). Switched on only when the DLL has the item and the
    -- export (0.9.3 and later) and the item reads "off" (scanned, armed to be switched); while a save loads, off. Without
    -- either, nothing is sent and this copy's notices stay its own, as before.
    nologStep(S, want and not (P.test and P.test.nologOff))   -- (test only: Coop.patch.test = { nologOff = true }, the control run of lane 66)
    if want ~= (P.nfOn or false) then
      P.nfOn = want
      P.send(want and "NOFINISH ON" or "NOFINISH OFF")
      log("friend copy: NOFINISH %s", want and "ON" or "OFF")
    end
    -- NODEATH (lane 64): on a friend's copy nobody dies by this copy's own game (hunger and cold, a work accident, a
    -- fire, a collapsing building, the animals' hunger); a death comes on the host's word (the events module's E PD:
    -- the game's own SMUnit:just_die through the reflected function, which the item leaves alone). In battles the same
    -- rule is NOKILL. On while this copy plays in the host's world, off while a save loads and when it is no friend.
    -- (live session of 2026-11-17: a villager starved on two friends' copies and not on the host.)
    -- (test only: Coop.patch.test = { nodeathOff = true } keeps it off on a friend: the control run that must show a
    -- death on the friend alone again)
    local wantND = want and not (P.test and P.test.nodeathOff)
    if wantND ~= (P.ndOn or false) then
      P.ndOn = wantND
      P.send(wantND and "NODEATH ON" or "NODEATH OFF"); P.ndT = os.clock(); P.ndState = nil
      log("friend copy: NODEATH %s%s", wantND and "ON" or "OFF", (want and not wantND) and " (the test switch nodeathOff)" or "")
    end
    if P.ndOn and os.clock() - (P.ndT or 0) > 2.0 then
      P.ndT = os.clock() + 8.0                                    -- looked at every 10 s
      local it = P.status().items.NODEATH
      -- wanted on and found off (an ALLOFF of another module took it out with everything else): on again
      if it and it.state == "off" and (P.ndAgain or 0) < 5 then
        P.ndAgain = (P.ndAgain or 0) + 1; P.send("NODEATH ON"); P.ndT = os.clock(); log("friend copy: NODEATH was off: ON sent again")
      else
        local why = it and tostring(it.why or ""):gsub("%s*refused=%d+", "") or ""
        local s = it and (tostring(it.state) .. " " .. why) or "not in this native piece (an older one)"
        if it and it.state ~= "off" then P.ndAgain = 0 end
        if s ~= P.ndState then
          P.ndState = s
          if it and it.state == "on" then log("NODEATH on: this copy's own game kills nobody (%s)", why)
          else log("NODEATH is NOT fully on: %s. A villager can still die on this copy alone by the causes named 'na' or 'off'", s) end
        end
      end
    end
    -- GOODS: the stock of this copy's buildings changes only on the host's word. On while this copy plays in the
    -- host's world AND the host has said that it sends every building's stock (P.hostExact, set by coop_facts.lua when
    -- the host's "F X 1" arrives: without those values a frozen building would simply be wrong); off while a save
    -- is loading (a load must fill the buildings exactly as in the unchanged game).
    -- (test only: Coop.patch.test = { goodsOff = true } keeps it off on a friend: the control run of lane 14)
    goodsStep(S, want and P.hostExact == true and not (P.test and P.test.goodsOff))
    -- TOTALS (lane 22) follows GOODS: off (with the recount) before a load, at a release, at a role change
    totalsStep(S, P.gOn == true and P.goodsOn() and not (P.test and P.test.totalsOff))
    -- HOLD (lane 31) follows GOODS too: the host's region numbers come in exact mode; off (approval rebuilt by the game)
    -- before a load, at a release, at a role change (test only: Coop.patch.test = { holdOff = true } keeps it off)
    holdStep(S, P.gOn == true and P.goodsOn() and not (P.test and P.test.holdOff))
    -- DIST (lane 42) follows GOODS too: the host's market goods of houses come in exact mode
    distStep(S, P.gOn == true and P.goodsOn() and not (P.test and P.test.distOff))   -- (lane 35: test switch distOff, like goodsOff)
    -- TRK (lane 83, native 0.9.15; the time adds from 0.9.16) follows GOODS too: this copy's own villagers' work no longer goes into a building's
    -- production log (the panel's goods made and yield status); the host's log is carried (coop_x_stats.lua, TRKSET).
    -- TRKHOLD ON every second is the keepalive: without it for 5 s the native piece lets the game's calls through.
    -- Off while a save loads, at a release, when the host goes silent (exact mode left). (test only: Coop.patch.test =
    -- { trkOff = true } keeps it off: the control run)
    do
      local wantTK = P.gOn == true and P.goodsOn() and not (P.test and P.test.trkOff)
      if wantTK and os.clock() - (P.tkT or -1e9) >= 1.0 then P.tkT = os.clock(); P.send("TRKHOLD ON"); if not P.tkOn then P.tkOn = true; log("friend copy: TRKHOLD ON (this copy's own production entries skipped; the host's carried)") end
      elseif not wantTK and P.tkOn then P.tkOn = false; P.send("TRKHOLD OFF"); log("friend copy: TRKHOLD OFF") end
    end
    -- NOREGION (the lead, 2026-11-13): the log says so whenever the native piece turned a null region away (each one
    -- would have closed this copy's game), and once when the item is not available
    if os.clock() - (P.nrT or 0) > 5.0 then
      P.nrT = os.clock()
      local it = P.status().items.NOREGION
      if it then
        local h = tonumber((it.why or ""):match("hits=(%d+)")) or 0
        if it.state ~= P.nrState then P.nrState = it.state; log("NOREGION %s %s", tostring(it.state), it.state == "unavailable" and tostring(it.why) or "") end
        if h > (P.nrHits or 0) then log("NOREGION: %d work hit(s) at a building without a region turned away (%d so far in this game)", h - (P.nrHits or 0), h) end
        P.nrHits = h
      end
    end
  else
    if P.nfOn then P.nfOn = false end
    if P.ndOn then P.ndOn = false; P.send("NODEATH OFF"); log("NODEATH OFF: this copy is no longer a friend") end   -- lane 64
    if P.gOn then P.gOn = false end
    -- neither host nor friend (a copy that left the session): the recount, so its totals are its own game's again
    if P.tOn then P.tOn = false; P.send("TOTALS OFF"); P.tick(); log("TOTALS OFF (recount): this copy is no longer a friend") end
    if P.hOn then P.hOn = false; P.send("HOLD OFF"); P.tick(); log("HOLD OFF (approval rebuilt by the game): this copy is no longer a friend") end
    if P.dOn then distStep(S, false) end                       -- lane 42
  end
end

-- ---- DRAW and ORDER (lane 28): the game's own wall tool and army order routine, run by the DLL
-- (native/coop_patch/README.md, section "DRAW and ORDER"; research/2026-11-10-game-probe/lanes/lane_s21_28/report.txt)
--   P.ask(cmd, rest)                a command that answers: returns the answer without its "R <token> <cmd> " head, or nil, why
--   P.drawAvail() / P.orderAvail() / P.pathAvail()
--   P.wallDraw(pawn, flags, pts)    WALL: pts = { {X=, Y=, Z=}, ... } -> ok, { pts = n taken, blocked = "010", stop = n, road = "hex" } | false, why
--   P.wallGet(road)                 WALLGET -> { kind = { blueprint, roadType, wallType, platformLevel }, ctl = { {X,Y,Z}, ... }, gates = { {X,Y,Z}, ... } } | nil, why
--   P.orderAt(pawn, p, wp, noArrows)   ORDERAT -> ok, answer
--   P.path(pawn, noArrows, pts)        PATH -> ok, answer
--   P.orderEvents()                 the lines the DLL's ORDERHOOK appended to patch_events.txt since the last call
local tokN = 0
function P.ask(cmd, rest)
  if not P.fn then return nil, "DLL not loaded" end
  tokN = tokN + 1
  local tok = string.format("m%d_%d", math.floor(os.clock() * 1000) % 100000000, tokN)
  P.send(cmd .. " " .. tok .. " " .. rest); P.tick()
  local f = io.open(P.dir .. "patch_reply.txt", "rb"); local t = f and f:read("a") or ""; if f then f:close() end
  local pre = "R " .. tok .. " " .. cmd .. " "
  if t:sub(1, #pre) ~= pre then return nil, "no answer from the DLL" end
  t = t:sub(#pre + 1):gsub("[\r\n]+$", "")
  if t:sub(1, 2) ~= "ok" then return nil, t end
  return t:sub(4)
end
local function itemAvail(k) if not P.fn then return false end; local it = P.status().items[k]; return it ~= nil and it.state == "available" end
function P.drawAvail() return itemAvail("DRAW") end
function P.orderAvail() return itemAvail("ORDER") end
function P.pathAvail() return itemAvail("PATH") end
local function encP(pts, fmt)
  local t = {}
  for i, q in ipairs(pts) do t[i] = string.format(fmt or "%.3f,%.3f,%.3f", q.X, q.Y, q.Z) end
  return table.concat(t, "|")
end
local function decP(s)
  local t = {}
  if s and s ~= "-" then for x, y, z in s:gmatch("(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)") do t[#t + 1] = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } end end
  return t
end
local function objAddr(o) local okA, a = pcall(function() return o:GetAddress() end); if okA and a and a ~= 0 then return addrText(a) end end
function P.wallDraw(pawn, flags, pts)
  local a = objAddr(pawn); if not a then return false, "no pawn address" end
  local r, why = P.ask("WALL", string.format("%s %d %s", a, flags, encP(pts)))
  if not r then return false, why end
  local t = { pts = tonumber(r:match("pts=(%-?%d+)")), blocked = r:match("blocked=(%d*)"), stop = tonumber(r:match("stop=(%d+)")), road = r:match("road=(%x+)") }
  return true, t
end
function P.wallGet(road)
  local a = objAddr(road); if not a then return nil, "no road address" end
  local r, why = P.ask("WALLGET", a)
  if not r then return nil, why end
  local k1, k2, k3, k4 = r:match("kind=(%d+),(%d+),(%d+),(%d+)")
  local ctl = r:match(" ctl=%d+ (%S+)"); local gates = r:match(" gates=%d+ (%S+)")
  local g = {}
  if gates and gates ~= "-" then for rec in gates:gmatch("[^|]+") do local q = decP(rec:match("^[^:]+"))[1]; if q then g[#g + 1] = q end end end
  return { kind = { tonumber(k1), tonumber(k2), tonumber(k3), tonumber(k4) }, ctl = decP(ctl), gates = g }
end
-- (lane 32) the place of a wall's gate record i (0-based) set to q: the drawing copy's gate height (only small
-- corrections are taken: x, y within 1.0, z within 5.0 of this copy's own)
function P.gateSet(road, i, q)
  local a = objAddr(road); if not a then return false, "no road address" end
  local r, why = P.ask("GATESET", string.format("%s %d %.4f,%.4f,%.4f", a, i, q.X, q.Y, q.Z))
  if not r then return false, why end
  return true, r
end
-- (lane 53) a placed wall of the castle plan gets these control points the way the game's own drag, alt-click and
-- shift-click change a wall: the points are written and the game's own rebuild of the wall runs (WALLSET). The
-- numbers go out with two decimals, as WALLGET prints them: every copy then holds the very same numbers.
function P.wallSetAvail() return itemAvail("WALLSET") end
function P.wallSet(road, pts)
  local a = objAddr(road); if not a then return false, "no road address" end
  local r, why = P.ask("WALLSET", a .. " " .. encP(pts, "%.2f,%.2f,%.2f"))
  if not r then return false, why end
  return true, r
end
function P.orderAt(pawn, q, wp, noArrows)
  local a = objAddr(pawn); if not a then return false, "no pawn address" end
  local r, why = P.ask("ORDERAT", string.format("%s %.3f,%.3f,%.3f %d %d", a, q.X, q.Y, q.Z, wp and 1 or 0, noArrows and 1 or 0))
  if not r then return false, why end
  return true, r
end
function P.path(pawn, noArrows, pts)
  local a = objAddr(pawn); if not a then return false, "no pawn address" end
  local r, why = P.ask("PATH", string.format("%s %d %s", a, noArrows and 1 or 0, encP(pts, "%.1f,%.1f,%.1f")))
  if not r then return false, why end
  return true, r
end
P.decPoints = decP
-- the hook's lines: read from where the last call stopped; a file that shrank (the DLL starts it again above 256 KB)
-- is read from its start; what was there before this session's first call is skipped (old addresses)
-- (lane 65) called every frame (C.preOrders): the file's handle is kept, a call is a seek (an open after the DLL's
-- write cost about 2 ms on the developer's PC, more on a friend's: core:preOrders 1.1 ms a frame live). The C
-- runtime's handle does not share delete, and the DLL deletes the file above 256 KB (coop_patch.c l28_event): above
-- that size the handle is let go after every read, as before, until the DLL has started the file again.
local EV_CAP = 256 * 1024
function P.orderEvents()
  local path = P.dir .. "patch_events.txt"
  local f = P.evF
  if f and P.evP ~= path then pcall(io.close, f); f = nil; P.evF = nil end
  if not f then
    f = io.open(path, "rb"); if not f then P.evOff = P.evOff or 0; return {} end
    f:setvbuf("no")
  end
  local size = f:seek("end")
  if not size then pcall(io.close, f); P.evF = nil; return {} end
  local keep = size <= EV_CAP
  if keep then P.evF, P.evP = f, path else P.evF = nil end
  local function done() if not keep then f:close() end end
  if P.evOff == nil then P.evOff = size; done(); return {} end
  if size < P.evOff then P.evOff = 0 end
  if size == P.evOff then done(); return {} end
  f:seek("set", P.evOff)
  local text = f:read(size - P.evOff) or ""; done()
  local last = text:match(".*()\n"); if not last then return {} end        -- only whole lines
  P.evOff = P.evOff + last
  local t = {}
  for line in text:sub(1, last):gmatch("[^\r\n]+") do t[#t + 1] = line end
  return t
end
-- ORDERHOOK is wanted on every copy in a world (each player's own path and building orders are read from it). The
-- host's ALLOFF takes it out with everything else, so it is put back when the status shows it idle (checked every 2 s).
local function orderHookStep(S, inWorld)
  if not P.fn then return end
  local t = os.clock()
  if t - (P.ohT or 0) < 2.0 then return end
  P.ohT = t
  local it = P.status().items.ORDERHOOK; if not it then return end
  local want = inWorld and (S.role == "host" or S.role == "friend") and not (P.test and P.test.noOrderHook)
  if want and it.state == "idle" then P.send("ORDERHOOK ON"); log("ORDERHOOK ON (this copy's own path and building orders are read from it)")
  elseif not want and it.state == "hooked" then P.send("ORDERHOOK OFF"); log("ORDERHOOK OFF") end
end

-- (lane 55) a friend in a world: this copy's switches now, not on the next tick (coop_facts.lua calls it when the
-- host's "F X 1" arrives, so GOODS and TOTALS are on before any region pass of the world module runs)
function P.friendNow(S)
  if S and S.role == "friend" and not rawget(C, "hold") and S.worlds then step(S, true) end
end
local M = {}
function M.tick(S, clock) step(S, true); orderHookStep(S, true) end
function M.idle(S, clock) step(S, false); orderHookStep(S, false) end
function M.onWorld(S)
  P.sentWorld = nil
  P.evOff = nil      -- (lane 59) order lines the native hook wrote before or during the load name the old world's objects: skipped, as at a session's start
  -- a new world: what the DLL remembers of the old world's buildings is dropped; the next tick switches GOODS on again
  if P.tOn and P.fn then P.send("TOTALS FORGET"); P.tick(); P.tOn = false end   -- the old world's regions are gone: nothing written
  if P.hOn and P.fn then P.send("HOLD FORGET"); P.tick(); P.hOn = false end     -- (lane 31) the same for the held regions
  if P.gOn and P.fn then P.send("GOODS OFF"); P.tick(); P.gOn = false end
end

-- the mod stopping: put every byte back. Modules get no stop call, so C.stop is wrapped (again after a core reload).
if C.stop ~= P.stopWrap then
  local orig = C.stop
  P.stopWrap = function(...)
    local Pp = rawget(_G, "Coop") and _G.Coop.patch
    if Pp and Pp.fn then pcall(Pp.send, "ALLOFF"); pcall(Pp.fn) end
    return orig(...)
  end
  C.stop = P.stopWrap
end

C.register("patch", M)
return "coop patch module loaded (" .. (P.wanted and "on" or "off: coop.cfg has native = off") .. ")"
