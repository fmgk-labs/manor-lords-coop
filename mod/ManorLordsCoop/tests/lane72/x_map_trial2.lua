-- Lane 72, the find-or-add trial, part 2 of 2 (after the load of slot lane72_map): the record of part 1's date read
-- again (by region key: a region's address changes with the load). Read only; crumbs as in part 1.
local C = _G.Coop; local S = C and C.s; local P = C and C.patch
local dir = _G.COOP_LINK_DIR or "./"
local function put(file, line) local f = io.open(dir .. file, "a"); if f then f:write(os.date("%H:%M:%S "), line, "\n"); f:close() end end
local function crumb(s) put("lane72_map_crumbs.txt", "part2 " .. s) end
local function res(s) put("lane72_map.txt", "part2 " .. s) end
if not (S and S.eng and P and P.fn) then return "no world or no native piece" end
crumb("1 part 1's key")
local rk, date, g1, g2
local f = io.open(dir .. "lane72_map.txt", "r")
if f then for l in f:lines() do local a, b, _, c, d = l:match("part1 key (%S+) (%S+) (%S+) (%-?%d+) (%-?%d+)$"); if a then rk, date, g1, g2 = a, b, c, d end end; f:close() end
if not rk then return "no part 1 result" end
crumb("2 find the region " .. rk)
local reg
do local arr = S.eng.regions; for i = 1, #arr do local r = C.api.un(arr[i]); if r and r:IsValid() and C.world.rkey(r) == rk then reg = string.format("%X", r:GetAddress()) end end end
if not reg then res("region not found after the load"); return "no region" end
crumb("3 read the records after the load")
local ss = FindFirstOf("ProductionSubsystem")
local path = P.dir .. "hist_sub_mt9.txt"; os.remove(path)
P.send(string.format("HIST SUBDUMP %X mt9 5", ss:GetAddress())); P.tick()
local h = io.open(path, "r"); local all = h and h:read("a") or ""; if h then h:close() end
local mA0 = all:match("region %d+ " .. reg .. " name[^\n]*\n.-date " .. date:gsub("/", "%%/") .. " .- mA0%[%d+/%d+%]:?(%S*)")
res(string.format("after-load region %s date %s map A0: %s", rk, date, tostring(mA0)))
local ok1 = mA0 and mA0:find("%f[%d%-]" .. g1 .. "=77") ~= nil
local ok2 = mA0 and mA0:find("%f[%d%-]" .. g2 .. "=5") ~= nil
res((ok1 and ok2) and "VERDICT: the save keeps both (the existing good's new amount and the added good)"
    or ("VERDICT: not both kept (existing " .. tostring(ok1) .. ", added " .. tostring(ok2) .. ")"))
crumb("4 done")
return "part 2 done: see lane72_map.txt"
