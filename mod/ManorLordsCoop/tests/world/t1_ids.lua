-- t1_ids.lua  World module self-test 1: identity helpers. READ ONLY. Any state (paused is best). Never saves.
-- Assumes the probe helper library is prepended (eng, p1, out, un, nm, v3) and that coop.lua and coop_world.lua are
-- loaded and Coop is started (any role).
-- PASS if: every region key is unique and is one word (prints whether it came from regionUniqueTag or the name
--   fallback "n_..."), every key of the lord's buildings is unique, and buildingByKey finds sampled buildings again,
--   also from a key that is 10 cm off (the rounding-edge neighbour search).
-- This is also the first live read of Region.regionUniqueTag (only seen in dumps/Region.txt so far).
local C = rawget(_G, "Coop"); if not (C and C.s and C.world) then return "load coop.lua and coop_world.lua and start Coop first" end
local W, S = C.world, C.s
if not W.prepare(S) then return "no lord pawn" end
local t0 = os.clock()
local seen, dup, n, fallback, spaces = {}, 0, 0, 0, 0
for i = 1, #eng.regions do
  local r = un(eng.regions[i])
  if r:IsValid() then
    n = n + 1
    local k = W.rkey(r)
    if k:sub(1, 2) == "n_" then fallback = fallback + 1 end
    if k:find("%s") then spaces = spaces + 1 end
    if seen[k] then dup = dup + 1 end; seen[k] = true
    local tag = "?"; pcall(function() tag = r.regionUniqueTag:ToString() end)
    local name = "?"; pcall(function() name = r.regionName:ToString() end)
    out("region", i, "key", k, "| tag", tag, "| name", name, "| the lord's", tostring(W.isMine(r.ownerPawn)))
  end
end
local tR = (os.clock() - t0) * 1000
out("REGIONS", n, "duplicate keys", dup, "keys from the name fallback", fallback, "keys with whitespace", spaces, string.format("(%.1f ms)", tR))
t0 = os.clock()
local bseen, bdup, nb, sample = {}, 0, 0, {}
for i = 1, #eng.buildingArr do
  local b = un(eng.buildingArr[i])
  if b:IsValid() and W.isMine(b.ownerPawn) then
    nb = nb + 1
    local k = W.bkey(b)
    if bseen[k] then bdup = bdup + 1; out("   duplicate building key", k) end
    bseen[k] = true
    if #sample < 10 then sample[#sample + 1] = { k = k, b = b } end
  end
end
local tB = (os.clock() - t0) * 1000
out("BUILDINGS of the lord", nb, "duplicate keys", bdup, string.format("(%.1f ms for the scan)", tB))
t0 = os.clock()
W.indexNow(S)
out("index built", string.format("%.1f ms in total (spread over ticks in play)", (os.clock() - t0) * 1000), "max step", string.format("%.2f ms", W.maxStepMs or 0))
local found, near = 0, 0
for _, e in ipairs(sample) do
  local b = W.buildingByKey(e.k)
  if b and b:GetAddress() == e.b:GetAddress() then found = found + 1 end
  local t, x, y = e.k:match("^(%d+)@(%-?%d+),(%-?%d+)$")
  local off = string.format("%s@%d,%d", t, tonumber(x) + 1, tonumber(y))
  local b2 = W.buildingByKey(off)
  if b2 and b2:GetAddress() == e.b:GetAddress() then near = near + 1 end
end
out("lookup by key", found, "/", #sample, "| lookup 10 cm off", near, "/", #sample)
local pass = dup == 0 and spaces == 0 and bdup == 0 and found == #sample and near == #sample
out("VERDICT", pass and "PASS" or "FAIL (see lines above)")
return "ok"
