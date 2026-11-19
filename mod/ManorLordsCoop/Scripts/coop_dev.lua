-- Manor Lords Co-op: DEVELOPMENT ONLY. Never shipped: tools/package.ps1 leaves this file out of the zip for players
-- and puts it only into test builds (dist	est).
-- The test console (CoopProbe) is another mod with its own Lua state, so it cannot read the co-op mod's tables or load
-- a changed file into it. When, and only when, the game was started with COOP_ROLE in its environment (the test
-- harness does that), this copy runs the Lua file <link folder>/xdev_<name>.lua once and writes what it returns to
-- xdev_<name>.out (first written for lane 2, session 21: probes/xdev.sh).
local C = _G.Coop; local A = C.api
if os.getenv("COOP_ROLE") and rawget(_G, "COOP_LINK_DIR") then
  local dir = _G.COOP_LINK_DIR
  local D = {}
  C.dev = D
  -- (lane 51) test only: this copy's game thread does nothing else for <s> seconds (a stand-in for the 9 s stall of a
  -- friend copy in l51f2): nothing is read, sent or drawn meanwhile.  xdev chunk: return Coop.dev.freeze(12)
  function D.freeze(s)
    s = tonumber(s) or 10; local t = os.clock()
    while os.clock() - t < s do end
    A.log("dev: the game thread was held for %.1f s (test)", os.clock() - t)
    return string.format("held %.1f s", os.clock() - t)
  end
  -- (lane 73) LINK DELAY SWITCH: this copy under a slow link (tools/dev/README.md, "A slow link and a slow friend").
  -- A file <link folder>/dev_linkdelay.txt, one line per copy: "<name or *> <D ms> [<B ms> [<jitter ms>]]" (a line
  -- for the copy's own name wins over "*"; "#" starts a comment). Every line this copy READS from another copy's link
  -- file is held D ms (plus or minus the jitter) and let out at the next multiple of B ms: late and in bursts, in the
  -- order it was written. The file is looked at every 2 s; taken away: what is held comes out at once, then as before.
  -- It sits on the core's recv (the seam C.devLink in coop.lua): every module gets its lines late, as over a real link.
  local LD = { cfgT = -10, q = {}, rd = {} }
  local function ownLine(S, file, pat)                 -- the line for this copy's name, else the one for "*"
    local f = io.open(dir .. file, "r"); if not f then return nil end
    local star, own
    for line in f:lines() do
      line = line:gsub("#.*$", "")
      local who, rest = line:match(pat)
      if who == tostring(S.name) then own = rest elseif who == "*" then star = star or rest end
    end
    f:close()
    return own or star
  end
  local function ldConfig(S, clock)
    if clock - LD.cfgT < 2.0 then return end
    LD.cfgT = clock
    local rest = ownLine(S, "dev_linkdelay.txt", "^%s*([%w_%*]+)%s+(%d[%d%s]*)")
    local d, b, j
    if rest then d, b, j = rest:match("^(%d+)%s*(%d*)%s*(%d*)"); d, b, j = tonumber(d), tonumber(b) or 0, tonumber(j) or 0 end
    if d and d <= 0 and b <= 0 then d = nil end
    local key = d and (d .. "/" .. b .. "/" .. j) or "off"
    if key ~= LD.key then
      LD.key = key; LD.D, LD.B, LD.J = d and d / 1000, d and b / 1000, d and j / 1000
      if d then A.log("dev: LINK DELAY on for %s: every line read is held %d ms (jitter %d) and let out every %d ms (dev_linkdelay.txt)", tostring(S.name), d, j, b)
      else A.log("dev: LINK DELAY off for %s", tostring(S.name)) end
    end
  end
  C.devLink = {
    recv = function(recv0, peer)
      local S = C.s; local clock = os.clock()
      ldConfig(S, clock)
      local lines, ends = recv0(peer)
      local R = S.readers and S.readers[peer]
      if LD.rd[peer] ~= R then LD.rd[peer] = R; LD.q[peer] = nil end       -- a new reader (a new session): nothing of the old one
      local Q = LD.q[peer]
      local out, oe, k = {}, {}, 0
      if not LD.D then
        if not Q then return lines, ends end                                 -- off, nothing held: straight through
        for i = Q.h, Q.n do k = k + 1; out[k] = Q[i][2]; oe[k] = Q[i][3] end -- switched off: what is held comes out now, then the new lines
        for i, l in ipairs(lines) do k = k + 1; out[k] = l; oe[k] = ends[i] end
        LD.q[peer] = nil
        return out, oe
      end
      if not Q then Q = { h = 1, n = 0, last = 0 }; LD.q[peer] = Q end
      for i, l in ipairs(lines) do
        local due = clock + LD.D + (LD.J > 0 and (math.random() * 2 - 1) * LD.J or 0)
        if LD.B > 0 then due = math.ceil(due / LD.B) * LD.B end              -- out with the next burst
        if due < Q.last then due = Q.last end; Q.last = due                  -- in the order written
        Q.n = Q.n + 1; Q[Q.n] = { due, l, ends[i] }
      end
      while Q.h <= Q.n and Q[Q.h][1] <= clock do
        local e = Q[Q.h]; Q[Q.h] = nil; Q.h = Q.h + 1
        k = k + 1; out[k] = e[2]; oe[k] = e[3]
      end
      local held = Q.n - Q.h + 1
      if held > (S.stats.devHeldMax or 0) then S.stats.devHeldMax = held end
      if held == 0 then LD.q[peer] = { h = 1, n = 0, last = Q.last } end
      return out, oe
    end,
    rewind = function(peer) LD.q[peer] = nil end,
  }
  -- (lane 73) FRAME CAP per copy: <link folder>/dev_fps.txt, lines "<name or *> <frames a second>" (0 = no cap). The
  -- game's own console variable t.MaxFPS, set when the file's word for this copy changes (looked at every 2 s); taken
  -- away after it set one: no cap. (tools/dev/up.sh caps every test copy at 15 at its start: "host 60" lifts the host.)
  local function fpsStep(S, clock)
    if clock - (D.fpsT or -10) < 2.0 then return end
    D.fpsT = clock
    local rest = ownLine(S, "dev_fps.txt", "^%s*([%w_%*]+)%s+(%d+)")
    local want = tonumber(rest)
    if want == nil and D.fpsSet ~= nil then want = 0 end
    if want == nil or want == D.fpsSet then return end
    local ok, e = pcall(function()
      local eng = S.eng; if not (eng and eng:IsValid()) then error("no world") end
      local pr = eng.playerRef; if not (pr and pr:IsValid()) then error("no player") end
      local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
      local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
      if not (gs and gs:IsValid() and ksl and ksl:IsValid()) then error("no engine statics") end
      local pc = gs:GetPlayerController(pr, 0); if not (pc and pc:IsValid()) then error("no player controller") end
      ksl:ExecuteConsoleCommand(pc, "t.MaxFPS " .. want, pc)
    end)
    if ok then D.fpsSet = want; A.log("dev: FRAME CAP for %s: t.MaxFPS %d (dev_fps.txt)", tostring(S.name), want)
    elseif D.fpsErr ~= tostring(e) then D.fpsErr = tostring(e); A.log("dev: frame cap not set yet: %s", tostring(e)) end
  end
  C.register("dev", { tick = function(S, clock)
    pcall(fpsStep, S, clock)
    local XB = C.town and C.town.xbuild
    local step = D.devTick or (XB and XB.devTick)        -- a test's own per-frame step
    if step then local okT, e = pcall(step, S, clock); if not okT then D.devTick = nil; if XB then XB.devTick = nil end; A.log("xdev tick error: %s", tostring(e)) end end
    if clock - (D.devT or 0) < 0.25 then return end
    D.devT = clock
    local base = dir .. "xdev_" .. tostring(S.name)
    local f = io.open(base .. ".lua", "r"); if not f then return end
    local src = f:read("a"); f:close(); os.remove(base .. ".lua")
    local chunk, err = load(src, "xdev", "t", setmetatable({}, { __index = _G, __newindex = _G }))
    local ok, res
    if chunk then ok, res = pcall(chunk) else ok, res = false, err end
    local o = io.open(base .. ".tmp", "w")
    if o then o:write((ok and "OK: " or "ERR: ") .. tostring(res) .. "\n"); o:close(); os.remove(base .. ".out"); os.rename(base .. ".tmp", base .. ".out") end
  end })
end
return "coop_dev loaded (development build)"
