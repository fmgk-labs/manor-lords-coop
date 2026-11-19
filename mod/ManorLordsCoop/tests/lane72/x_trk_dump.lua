-- Lane 72: every building's production log through the native read HIST TRKDUMP (read only), with the yield status
-- and the 30-day sum as the game's own functions give them. An xdev chunk; set TAG before it (default "x").
-- One line a building: <bkey> y=<GetYieldStatus> p30=<sum of getGoodsProducedOver(30)> | <good>:<n>:<day>/<amount>,...
-- (GetEntriesOfItemType is not used: through the mod loader it crashed both copies, run l72a.)
local C = _G.Coop; local S = C and C.s; local P = C and C.patch
if not (S and S.eng and P and P.fn) then return "no world or no native piece" end
local tag = rawget(_G, "TAG") or "x"
local un = C.api.un
local by, list = {}, {}
local arr = S.eng.buildingArr
for i = 1, #arr do
  local b = un(arr[i])
  local ok, t = pcall(function() local c = b.ProductionTrackerComponent; if c and c:IsValid() then return c end end)
  if ok and t then
    local a = string.format("%X", t:GetAddress())
    local y, p30 = "?", 0
    pcall(function() y = tostring(t:GetYieldStatus()) end)
    pcall(function() for _, v in pairs(t:getGoodsProducedOver(30) or {}) do local x = v; pcall(function() x = v:get() end); p30 = p30 + (tonumber(x) or 0) end end)
    by[a] = { k = C.world.bkey(b), y = y, p30 = p30 }; list[#list + 1] = a
  end
end
local out = {}
local n = 0
for s = 1, #list, 200 do
  n = n + 1
  local part = {}; for i = s, math.min(#list, s + 199) do part[#part + 1] = list[i] end
  local t = tag .. "_" .. n
  os.remove(P.dir .. "hist_trk_" .. t .. ".txt")
  P.send("HIST TRKDUMP " .. t .. " " .. table.concat(part, ",")); P.tick()
  local f = io.open(P.dir .. "hist_trk_" .. t .. ".txt", "r")
  if not f then out[#out + 1] = "NO FILE hist_trk_" .. t .. ".txt"
  else
    for l in f:lines() do
      local a, rest = l:match("^(%x+) (.*)$")
      local B = a and by[a]
      if B then
        local goods = rest:match("^%d+ | (.*)$") or rest:match("^%d+$") and "" or rest
        if goods ~= "" or B.y ~= "0" then out[#out + 1] = string.format("%s y=%s p30=%d | %s", B.k, B.y, B.p30, goods) end
      elseif l ~= "END" and l ~= "" then out[#out + 1] = "? " .. l end
    end
    f:close()
  end
end
table.sort(out)
local day = "?"; pcall(function() day = tostring(math.floor(S.eng.TemporalComponent.daysTotal)) end)
out[#out + 1] = string.format("day %s trackers %d", day, #list)
return table.concat(out, "\n")
