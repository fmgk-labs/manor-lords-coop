-- Lane 72, gate 2, part 1 of 2: ONE call of the tracker's own add routine (4bb3620) for a good the log has and ONE
-- for a good it has not, then a save. A TEST FRIEND only (a copy started by the harness, its own save profile).
-- xdev chunk: copy to <link>/xdev_<name>.lua; read xdev_<name>.out. Part 2 (x_trk_trial2.lua) runs after the load.
-- The log is read with the native HIST TRKDUMP (GetEntriesOfItemType through the mod loader crashed both copies, l72a);
-- the calls are HIST TRYADD (it needs COOP_ROLE, set by the harness, and the switch file this script makes and removes).
-- Crash-safe order: a crumb line is written (opened, written, closed) BEFORE each step, so after a crash the last
-- crumb in <link>/lane72_trial_crumbs.txt names the step; every result goes to <link>/lane72_trial.txt the same way.
local C = _G.Coop; local S = C and C.s; local P = C and C.patch
local dir = _G.COOP_LINK_DIR or "./"
local function put(file, line) local f = io.open(dir .. file, "a"); if f then f:write(os.date("%H:%M:%S "), line, "\n"); f:close() end end
local function crumb(s) put("lane72_trial_crumbs.txt", "part1 " .. s) end
local function res(s) put("lane72_trial.txt", "part1 " .. s) end
if not (S and S.eng and P and P.fn) then return "no world or no native piece" end
-- (the game refuses a friend's save: for the save-and-load half the same steps run on the harness's test HOST, with
-- TRIAL_ON_HOST = true set before the chunk; the host is a test copy too, started with COOP_ROLE)
if S.role ~= "friend" and not rawget(_G, "TRIAL_ON_HOST") then return "run this on the test friend only" end
crumb("0 role " .. tostring(S.role))
do local f = io.open(P.dir .. "dev_hist_tryadd.txt", "w"); if f then f:write("lane 72 trial\n"); f:close() end end

crumb("1 find a tracker with goods")
local b, c, key
local arr = S.eng.buildingArr
for i = 1, #arr do
  local x = C.api.un(arr[i])
  local ok, t = pcall(function() local t = x.ProductionTrackerComponent; if t and t:IsValid() and t:GetNumberOfGoodTypesInLog() > 0 then return t end end)
  if ok and t then b, c = x, t; break end
end
if not c then res("no tracker with goods"); return "no tracker with goods" end
key = C.world.bkey(b)
local n = 0
local function dump(tag)
  n = n + 1; local t = "tr" .. n
  os.remove(P.dir .. "hist_trk_" .. t .. ".txt")
  P.send(string.format("HIST TRKDUMP %s %X", t, c:GetAddress())); P.tick()
  local f = io.open(P.dir .. "hist_trk_" .. t .. ".txt", "r"); local l = f and f:read("l") or "NO FILE"; if f then f:close() end
  res(string.format("%s building %s yield %s log %s", tag, key, tostring(c:GetYieldStatus()), l))
  return l
end
crumb("2 read the log before"); local l0 = dump("before")
local have = {}; for g in l0:gmatch("| (%d+):") do have[#have + 1] = tonumber(g) end
local g1 = have[1]
local g2; local tg = S.eng.tradeableGoods
for i = 1, #tg do local v = tg[i]; if type(v) ~= "number" then v = v:get() end; local seen = false; for _, x in ipairs(have) do if x == v then seen = true end end; if not seen then g2 = v; break end end

crumb(string.format("3 TRYADD existing good %s amount 1", tostring(g1)))
P.send(string.format("HIST TRYADD %X %d 1", c:GetAddress(), g1)); P.tick()
crumb("4 read the log after the existing good"); dump("after-existing")

crumb(string.format("5 TRYADD new good %s amount 1", tostring(g2)))
if g2 then P.send(string.format("HIST TRYADD %X %d 1", c:GetAddress(), g2)); P.tick() end
crumb("6 read the log after the new good"); dump("after-new")
os.remove(P.dir .. "dev_hist_tryadd.txt")
do local st = io.open(P.dir .. "patch_status.txt", "r"); if st then for l in st:lines() do if l:find("^HIST") then res("status " .. l) end end; st:close() end end

crumb("7 save to slot lane72_trial")
local ok, r = pcall(function() return S.p1:requestSaveFile("lane72_trial", "lane72_trial") end)
res("save requested: " .. tostring(ok) .. " " .. tostring(r))
crumb("8 done: wait for the save, then load lane72_trial on this copy and run part 2")
return "part 1 done: see lane72_trial.txt"
