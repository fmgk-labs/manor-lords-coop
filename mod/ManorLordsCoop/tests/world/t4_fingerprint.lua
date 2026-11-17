-- t4_fingerprint.lua  World module self-test 4: the drift fingerprint and its comparison. READ ONLY. Never saves.
-- Assumes the probe helper library is prepended and coop.lua + coop_world.lua are loaded and Coop is started.
-- Computes this copy's fingerprint (lane_w W7 sections), prints it, its size and time, then checks the comparison:
--   itself -> no difference; a changed building hash -> "B"; silver +1 -> within tolerance, no difference;
--   a good +5 -> that good is named. Coop.onDrift is never called (nothing goes through the drift counter).
-- PASS if: no section is "ERR", the string is under ~400 bytes, the four comparisons give the expected results.
-- Run it on two copies freshly loaded from the same save and paused: the printed FP strings must be identical
--   (TESTPLAN step 9); a section that differs there holds noise and must be dropped before driftHook is switched on.
--   (Session 14: the lane_w version differed only in O, owners by object name; this module uses P / B / A<setup index>.)
local C = rawget(_G, "Coop"); if not (C and C.s and C.world) then return "load coop.lua and coop_world.lua and start Coop first" end
local W, S = C.world, C.s
if not W.prepare(S) then return "no lord pawn" end
W.maxStepMs = 0
local t0 = os.clock()
local P, s = W.fingerprintNow(S)
local ms = (os.clock() - t0) * 1000
if not P then return "fingerprint job did not finish: " .. tostring(W.lastErr) end
out("FP", s)
out("size", #s, "bytes", string.format("| %.1f ms in total (spread over ticks in play), max step %.2f ms", ms, W.maxStepMs or 0))
local errs = {}
for k, v in pairs(P) do if v == "ERR" then errs[#errs + 1] = k end end
local function copy(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return c end
local function show(t) return #t == 0 and "(none)" or table.concat(t, " ") end
local r1 = W.compareFp(P, copy(P))
local B = copy(P); B.B = "0/0"; local r2 = W.compareFp(P, B)
local N = copy(P); local n = {}; for x in (P.N or ""):gmatch("[^,]+") do n[#n + 1] = tonumber(x) end
if n[1] then n[1] = n[1] + 1 end; N.N = table.concat(n, ","); local r3 = W.compareFp(P, N)
local Sx = copy(P); local g = (P.S or ""):match("^(%d+)=")
if g then Sx.S = P.S:gsub("^(%d+)=(%-?%d+)", function(a, b) return a .. "=" .. (tonumber(b) + 5) end) end
local r4 = W.compareFp(P, Sx)
out("compare with itself:", show(r1))
out("building hash changed:", show(r2))
out("silver +1 (tolerance " .. W.cfg.tol .. "):", show(r3))
out("good " .. tostring(g) .. " +5:", show(r4), W.on.stock and "" or "(stock item off: not compared)")
local pass = #errs == 0 and #s < 400 and #r1 == 0 and #r2 == 1 and r2[1] == "B" and #r3 == 0 and (not g or not W.on.stock or #r4 == 1)
out("sections with ERR", show(errs))
out("VERDICT", pass and "PASS" or "FAIL")
return "ok"
