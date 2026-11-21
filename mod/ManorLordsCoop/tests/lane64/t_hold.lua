-- Desk test (lane 64, round 5): the friend's clock waits for the host's (coop.lua clockDil and the hold in friendInbox).
-- Runs WITHOUT the game (Lua 5.1 or 5.4):
--   py -3 -I research/2026-11-10-game-probe/lanes/lane_s21_64/tools/luarun.py <lua51.dll> mod/ManorLordsCoop/tests/lane64/t_hold.lua <an empty folder to use>
-- Part 1 asks the real rule (Coop.clockDil) directly. Part 2 plays a host and a friend in steps of 10 ms: the host
-- sends its clock 20 times a second, the lines take 30 ms, the friend's frame is 30 ms, and the friend's clock runs
-- at the scale the real rule gives; the hold while the host is silent is played here by its own rule (the code of it
-- is in friendInbox, which needs a game): what this shows is the rule, a game run shows the code.
-- The host of part 2 stalls as in sitting gd1 (0.6 s every 1.4 s) and loses game time at each stall.
local function here() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")) end
local scripts = (here():match("^(.*)/tests/lane64/[^/]*$") or ".") .. "/Scripts/"
local dir = arg and arg[1]
if not dir then print("give an empty folder: lua t_hold.lua <folder>"); os.exit(2) end
dir = dir:gsub("\\", "/"); if dir:sub(-1) ~= "/" then dir = dir .. "/" end
if _VERSION == "Lua 5.1" then
  local mt = getmetatable(io.stdout); local read0 = mt.__index.read
  mt.__index.read = function(f, fmt, ...) if fmt == "a" or fmt == "l" or fmt == "n" then fmt = "*" .. fmt end; return read0(f, fmt, ...) end
  table.unpack = table.unpack or unpack
end
local pass, fail = 0, 0
local function check(ok, what) if ok then pass = pass + 1; print("PASS  " .. what) else fail = fail + 1; print("FAIL  " .. what) end end
_G.COOP_LINK_DIR = dir
_G.LoopInGameThreadWithDelay = function() return 1 end
_G.CancelDelayedAction = function() end
_G.FindFirstOf = function() return { IsValid = function() return false end } end
_G.Coop = nil
dofile(scripts .. "coop.lua")
local C = _G.Coop
local rule = C.clockDil
check(type(rule) == "function", "coop.lua loads; the rule is there")
local cfg = {}                                               -- the defaults: 0.4 s behind, stand at 0.02

-- ---- part 1: the rule
for _, sp in ipairs({ 1, 4, 8 }) do
  local dayS = 40 / sp; local lag = 0.4 / dayS
  local d0 = rule(0, sp, false, 0.05, cfg); local dAhead = rule(-0.5, sp, false, 0.05, cfg); local dAt = rule(lag, sp, false, 0.05, cfg)
  local dHalf = rule(lag / 2, sp, false, 0.05, cfg)
  check(d0 == 0.02 and dAhead == 0.02 and math.abs(dAt - 1) < 1e-9 and math.abs(dHalf - 0.5) < 1e-9,
    string.format("speed %d: at or past the host's clock it stands (0.02); 0.4 s behind it runs at 1; half way at 0.5", sp))
  local last, mono, top = 0, true, 0
  for i = -100, 400 do local d = rule(i / 200, sp, false, 0.05, cfg); if d < last - 1e-9 then mono = false end; last = d; if d > top then top = d end end
  check(mono and top <= 3.0, string.format("speed %d: the further behind, the faster, never slower; at most 3 times when not catching up (%.2f)", sp, top))
  local c = rule(2.0, sp, true, 0.05, cfg)
  check(c > 3 and c <= 16 and c * sp <= 64 + 1e-9, string.format("speed %d: 2 days behind after a load: %.1f times (above 3, at most 16, times the speed at most 64)", sp, c))
end
local old = rule(-0.03, 4, false, 0.05, { clockLag = false }); local oldBand = rule(-0.015, 4, false, 0.05, { clockLag = false })
check(math.abs(old - 0.88) < 1e-9 and oldBand == 1.0, "the switch cfg.clockLag = false gives the rule of before (0.03 days AHEAD: 0.88; 0.015 days ahead: 1.0, no pull at all)")

-- ---- part 2: a host and a friend
-- stall: seconds the host stands every 1.4 s (0 = a host that never stalls); kept: seconds of game time the host's
-- game keeps of a stall (a long frame is capped: 0.4 of 0.6 here, as measured in gd1: about 14 % slow)
local function play(sp, stall, kept, behindDays, newRule)
  local dayS = 40 / sp; local dt = 0.01
  local c = newRule and {} or { clockLag = false }
  local host, friend = 100.0, 100.0 - behindDays
  local lines, heard, dil, catching = {}, 0, 1.0, behindDays > 0.05
  local maxAhead, earlyTurns, turns, settledAt, worstBehindAfter = 0, 0, 0, nil, 0
  local nextLine, nextFrame, held = 0, 0, 0
  local hostDayT = {}
  for step = 0, 12000 do                                      -- 120 s
    local t = step * dt
    local inStall = stall > 0 and (t % 1.4) >= (1.4 - stall)
    local h0 = math.floor(host)
    if not inStall then
      if stall > 0 and (t % 1.4) < dt then host = host + kept / dayS end      -- the first frame after a stall: what the game keeps of it
      host = host + dt / dayS
      if t >= nextLine then nextLine = t + 0.05; lines[#lines + 1] = { at = t + 0.03, clk = host } end
    end
    if math.floor(host) > h0 then hostDayT[math.floor(host)] = t end
    if t >= nextFrame then                                    -- the friend's tick
      nextFrame = t + 0.03
      local got
      while lines[1] and lines[1].at <= t do got = table.remove(lines, 1) end
      if got then heard = t end
      if newRule and t - heard > ((dil > 1.5) and 0.1 or 0.25) and t - heard <= 60 then dil = 0.02; held = held + 1 end      -- the hold (friendInbox)
      if got then
        local gap = got.clk - friend
        local d, off = rule(gap, sp, catching, 0.03, c)
        if catching and (math.abs(off) <= 0.02 or (newRule and off < 0)) then catching = false; d = rule(gap, sp, false, 0.03, c) end
        dil = d
      end
    end
    local f0 = math.floor(friend)
    friend = friend + dil * dt / dayS
    if math.floor(friend) > f0 then
      turns = turns + 1
      if math.floor(friend) > math.floor(host) then earlyTurns = earlyTurns + 1 end      -- a day the host does not have yet
    end
    if friend - host > maxAhead then maxAhead = friend - host end
    if not settledAt and not catching then settledAt = t end
    if settledAt and t > settledAt + 1 and (host - friend) * dayS > worstBehindAfter then worstBehindAfter = (host - friend) * dayS end
  end
  return { ahead = maxAhead * dayS, early = earlyTurns, turns = turns, settled = settledAt, behind = worstBehindAfter, held = held, endBehind = (host - friend) * dayS }
end
for _, sp in ipairs({ 4, 8 }) do
  local o = play(sp, 0.6, 0.4, 0, false)
  check(o.early > 0 and o.ahead > 0.1, string.format("the rule of before, a stalling host, speed %d: the friend's day turns before the host's %d times of %d; it is up to %.2f s ahead (the fault of gd1)", sp, o.early, o.turns, o.ahead))
  local n = play(sp, 0.6, 0.4, 0, true)
  check(n.early == 0 and n.ahead <= 0, string.format("the rule now, the same host, speed %d: 0 of %d day turns before the host's, never ahead (closest %.3f s); at most %.2f s behind", sp, n.turns, -n.ahead, n.behind))
  check(n.behind <= 3.0, string.format("speed %d: at most 3 s behind while the host stalls and comes back (%.2f s)", sp, n.behind))
  local r = play(sp, 0.6, 0.4, 2.0, true)
  check(r.early == 0 and r.ahead <= 0 and r.settled and r.settled <= 10, string.format("speed %d: 2 days behind after a load with the host stalling: at its place after %.1f s, never ahead, 0 early day turns", sp, r.settled or -1))
  local q = play(sp, 0, 0, 0, true)
  check(q.early == 0 and q.ahead <= 0 and q.endBehind >= 0.25 and q.endBehind <= 0.6 and q.held == 0, string.format("speed %d, a host that never stalls: the friend runs %.2f s behind, never held", sp, q.endBehind))
  local l = play(sp, 0, 0, 2.0, true)
  check(l.ahead <= 0 and l.settled and l.settled <= 5, string.format("speed %d: a plain reload (2 days behind, no stall): at its place after %.1f s, never ahead", sp, l.settled or -1))
end
local s1 = play(1, 0.6, 0.4, 0, true)
check(s1.early == 0 and s1.ahead <= 0 and s1.behind <= 3.0, string.format("speed 1, a stalling host: never ahead, at most %.2f s behind", s1.behind))

print(string.format("RESULT: %d passed, %d failed", pass, fail))
return fail == 0
