-- t3_host_scan.lua  World module self-test 3: what the host would send. READ ONLY. Any state (paused is best). Never saves.
-- Runs the host's region scan, building scan, events poll and the day-change messages (clock, timers, weather,
-- fingerprint) with sending captured: nothing reaches the link.
-- Assumes the probe helper library is prepended and coop.lua + coop_world.lua are loaded and Coop is started.
-- PASS if: every line is under cfg.maxLine characters, no step took more than ~2.5 ms (max step printed), a second
--   region scan right after the first sends nothing (paused: nothing changed), and there is no error.
-- Restores (also after an error): capture off, switches and the host's "last sent" tables as they were.
local C = rawget(_G, "Coop"); if not (C and C.s and C.world) then return "load coop.lua and coop_world.lua and start Coop first" end
local W, S = C.world, C.s
if not W.prepare(S) then return "no lord pawn" end
local saved = { sent = W.sent, bstock = W.on.bstock, weather = W.on.weather, err = W.lastErr, ev = W.ev, merch = W.merch, fires = W.fires, capture = W.capture }
local maxLen, total, pass, again = 0, 0, true, -1

local function body()
  W.sent = { reg = {}, bld = {}, lord = {} }; W.on.bstock = true; W.on.weather = true; W.lastErr = nil
  local function run(tag, which, key)
    W.capture = {}; W.maxStepMs = 0
    local t0 = os.clock(); W.hostScanNow(S, which, key); local ms = (os.clock() - t0) * 1000
    local lines = W.capture; W.capture = nil
    local bytes = 0
    for _, l in ipairs(lines) do bytes = bytes + #l; if #l > maxLen then maxLen = #l end; out("   ", #l, "bytes:", #l > 220 and (l:sub(1, 220) .. " ...") or l) end
    total = total + bytes
    out(tag, #lines, "lines", bytes, "bytes", string.format("total %.1f ms, max step %.2f ms (%s)", ms, W.maxStepMs or 0, tostring(W.maxStepJob)))
    if (W.maxStepMs or 0) > 2.5 then pass = false end
    return #lines
  end
  run("REGIONS + LORD (first scan, full)", "regions")
  again = run("REGIONS again (should be 0 lines)", "regions")
  run("BUILDINGS (storage + construction sites, full)", "bld")
  run("DAY CHANGE (D, T, X, F)", "day")
  W.ev, W.merch = nil, nil
  run("EVENTS baseline (should be 0 lines unless something burns)", "events")
end

local ok, e = pcall(body)
local err = W.lastErr
W.capture = saved.capture; W.sent = saved.sent; W.on.bstock = saved.bstock; W.on.weather = saved.weather
W.ev = saved.ev; W.merch = saved.merch; W.fires = saved.fires; W.lastErr = saved.err
if not ok then out("VERDICT", "FAIL (error: " .. tostring(e) .. ")"); return "error" end
pass = pass and maxLen <= W.cfg.maxLine and again == 0 and err == nil
out("longest line", maxLen, "limit", W.cfg.maxLine, "| all bytes", total, "| module error", tostring(err))
out("VERDICT", pass and "PASS" or "FAIL")
return "ok"
