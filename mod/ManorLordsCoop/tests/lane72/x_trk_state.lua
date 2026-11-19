-- Lane 72: every building's production log and yield status, as the game's own functions give them (read only).
-- An xdev chunk (xd.sh <host|friend> file x_trk_state.lua). One line per building that has a log:
--   <bkey> y=<GetYieldStatus> n=<goods> | <good>:<entries>:<first day>..<last day>:s30=<sum of the last 30 days>:h=<hash> ...
-- and a last line "day <today> buildings <n> yieldStates <list>". Diff the host's and the friend's outputs.
local C = _G.Coop; local S = C and C.s
if not (S and S.eng) then return "no world" end
local function hash(s) local h = 5381; for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end; return string.format("%x", h) end
local today = -1
pcall(function() today = math.floor(S.eng.TemporalComponent.daysTotal) end)
local out, nb = {}, 0
local arr = S.eng.buildingArr
for i = 1, #arr do
  local b = C.api.un(arr[i])
  local ok, line = pcall(function()
    local c = b.ProductionTrackerComponent
    if not (c and c:IsValid()) then return nil end
    local ng = c:GetNumberOfGoodTypesInLog()
    local y = tostring(c:GetYieldStatus())
    if ng == 0 and y == "0" then return nil end
    local parts = {}
    -- the log's goods: the keys of getGoodsProducedOver(366) (GetEntriesOfItemType of a good the log has not
    -- reads through null: it crashed both copies, run l72a)
    local keys = {}; for k in pairs(c:getGoodsProducedOver(366) or {}) do keys[#keys + 1] = tonumber(k) or k end; table.sort(keys)
    for _, g in ipairs(keys) do
      local e = c:GetEntriesOfItemType(g); local n = #e
      if n > 0 then
        local s30, t = 0, {}
        local last = e[n].DayProduced
        for j = 1, n do local d, a = e[j].DayProduced, e[j].QuantityProduced; t[j] = tostring(d) .. "/" .. tostring(a); if d > last - 30 then s30 = s30 + a end end
        parts[#parts + 1] = string.format("%d:%d:%s..%s:s30=%d:h=%s", g, n, tostring(e[1].DayProduced), tostring(last), s30, hash(table.concat(t, ",")))
      end
    end
    return string.format("%s y=%s n=%d | %s", C.world.bkey(b), y, ng, table.concat(parts, " "))
  end)
  if ok and line then nb = nb + 1; out[#out + 1] = line elseif not ok then out[#out + 1] = "ERR " .. tostring(line) end
end
table.sort(out)
out[#out + 1] = string.format("day %d buildings %d", today, nb)
return table.concat(out, "\n")
