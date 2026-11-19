-- Lane 72, the advisor's trial of the game's find-or-add (14489C0) on a region day record's map, part 1 of 2: ONE call
-- for a good the map has and ONE for a good it has not (HIST MAPADD; it needs COOP_ROLE and the switch file this script
-- makes and removes), then a save (a test HOST: set TRIAL_ON_HOST = true; a friend's save is refused by the game).
-- Crash-safe: a crumb line (opened, written, closed) before each step in <link>/lane72_map_crumbs.txt; results in
-- <link>/lane72_map.txt. Part 2 (x_map_trial2.lua) reads the record again after the load.
local C = _G.Coop; local S = C and C.s; local P = C and C.patch
local dir = _G.COOP_LINK_DIR or "./"
local function put(file, line) local f = io.open(dir .. file, "a"); if f then f:write(os.date("%H:%M:%S "), line, "\n"); f:close() end end
local function crumb(s) put("lane72_map_crumbs.txt", "part1 " .. s) end
local function res(s) put("lane72_map.txt", "part1 " .. s) end
if not (S and S.eng and P and P.fn) then return "no world or no native piece" end
if S.role ~= "friend" and not rawget(_G, "TRIAL_ON_HOST") then return "run this on the test friend, or set TRIAL_ON_HOST" end
crumb("0 role " .. tostring(S.role))
local ss = FindFirstOf("ProductionSubsystem"); if not (ss and ss:IsValid()) then res("no subsystem"); return "no subsystem" end
local sa = string.format("%X", ss:GetAddress())
local keys = {}
do local arr = S.eng.regions; for i = 1, #arr do local r = C.api.un(arr[i]); if r and r:IsValid() then keys[string.format("%X", r:GetAddress())] = C.world.rkey(r) end end end
local n = 0
local function dump()
  n = n + 1; local t = "mt" .. n
  local path = P.dir .. "hist_sub_" .. t .. ".txt"; os.remove(path)
  P.send("HIST SUBDUMP " .. sa .. " " .. t .. " 2"); P.tick()
  local f = io.open(path, "r"); local all = f and f:read("a") or ""; if f then f:close() end
  return all
end
crumb("1 read the records before")
local before = dump()
-- the first region with a town's key and a record whose map +A0h holds goods
local reg, date, have
for ra, line in before:gmatch("region %d+ (%x+) name %S+ days %d+\r?\n  day 0 date ([^\r\n]*)") do
  local d, mA0 = line:match("^(%S+) .- mA0%[%d+/%d+%]:?(%S*)")
  if d and mA0 and keys[ra] and (mA0 ~= "" or not reg) then reg, date, have = ra, d, mA0; if mA0 ~= "" then break end end
end
if not reg then res("no region record"); return "no record" end
local g1 = tonumber(have:match("^(%-?%d+)=")) or 1
local g2; for g = 300, 400 do if not have:find("%f[%d]" .. g .. "=") then g2 = g; break end end
res(string.format("region %s (%s) date %s map A0 before: %s", reg, keys[reg], date, have))
do local f = io.open(P.dir .. "dev_hist_mapadd.txt", "w"); if f then f:write("lane 72 trial\n"); f:close() end end
crumb(string.format("2 MAPADD existing good %d amount 77", g1))
P.send(string.format("HIST MAPADD %s %s %s A0 %d 77", sa, reg, date, g1)); P.tick()
crumb(string.format("3 MAPADD new good %d amount 5", g2))
P.send(string.format("HIST MAPADD %s %s %s A0 %d 5", sa, reg, date, g2)); P.tick()
os.remove(P.dir .. "dev_hist_mapadd.txt")
crumb("4 read the records after")
local after = dump()
local mA0 = after:match("region %d+ " .. reg .. " name %S+ days %d+\r?\n  day 0 date " .. date:gsub("/", "%%/") .. " .- mA0%[%d+/%d+%]:?(%S*)")
res(string.format("after region %s date %s map A0: %s", reg, date, tostring(mA0)))
res(string.format("expect %d=77 and %d=5", g1, g2))
do local st = io.open(P.dir .. "coop_patch.log", "r"); if st then for l in st:lines() do if l:find("MAPADD") then res("log " .. l) end end; st:close() end end
crumb("5 save to slot lane72_map")
local ok, r = pcall(function() return S.p1:requestSaveFile("lane72_map", "lane72_map") end)
res("save requested: " .. tostring(ok) .. " " .. tostring(r))
res(string.format("key %s %s %s %d %d", keys[reg], date, reg, g1, g2))
crumb("6 done")
return "part 1 done: see lane72_map.txt"
