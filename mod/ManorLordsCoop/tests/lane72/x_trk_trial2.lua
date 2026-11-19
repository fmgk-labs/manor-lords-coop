-- Lane 72, gate 2, part 2 of 2 (after the load of slot lane72_trial on the same test friend): the log read again
-- (native HIST TRKDUMP), set beside part 1's "after-new" line. Read only. Crumb before each step, as in part 1.
local C = _G.Coop; local S = C and C.s; local P = C and C.patch
local dir = _G.COOP_LINK_DIR or "./"
local function put(file, line) local f = io.open(dir .. file, "a"); if f then f:write(os.date("%H:%M:%S "), line, "\n"); f:close() end end
local function crumb(s) put("lane72_trial_crumbs.txt", "part2 " .. s) end
local function res(s) put("lane72_trial.txt", "part2 " .. s) end
if not (S and S.eng and P and P.fn) then return "no world or no native piece" end
crumb("1 part 1's building key")
local want, wantLog
local f = io.open(dir .. "lane72_trial.txt", "r")
if f then for l in f:lines() do local k, lg = l:match("part1 after%-new building (%S+) yield %S+ log (.*)$"); if k then want, wantLog = k, lg end end; f:close() end
if not want then return "no part 1 result" end
crumb("2 find the building " .. want)
local c
local arr = S.eng.buildingArr
for i = 1, #arr do local x = C.api.un(arr[i]); if C.world.bkey(x) == want then c = x.ProductionTrackerComponent; break end end
if not (c and c:IsValid()) then res("building " .. want .. " not found after the load"); return "not found" end
crumb("3 read the log after the load")
os.remove(P.dir .. "hist_trk_tr9.txt")
P.send(string.format("HIST TRKDUMP tr9 %X", c:GetAddress())); P.tick()
local g = io.open(P.dir .. "hist_trk_tr9.txt", "r"); local now = g and g:read("l") or "NO FILE"; if g then g:close() end
local strip = function(s) return (s:gsub("^%x+ ", "")) end
res(string.format("after-load building %s yield %s log %s", want, tostring(c:GetYieldStatus()), now))
res(strip(now) == strip(wantLog) and "VERDICT: the save keeps the tracker map (both adds survived the load)"
    or "VERDICT: the log after the load differs from the log before the save (compare the two lines)")
crumb("4 done")
return "part 2 done: see lane72_trial.txt"
