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
  C.register("dev", { tick = function(S, clock)
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
