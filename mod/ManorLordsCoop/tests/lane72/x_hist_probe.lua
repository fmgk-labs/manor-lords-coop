-- Lane 72, first-run probe for the HIST native item (READ ONLY: nothing is written). An xdev chunk (coop_dev.lua):
--   copy to <link folder>/xdev_<name>.lua on each copy (host and friend), read xdev_<name>.out a second later.
-- What it settles, by store (the native item's layouts were READ in the game file: lane_s21_72/report.txt section 7):
--   tracker  the entry: reflected members and values; one entry a day per good, at most 366 (append routine 4bb3620)
--   graphs   the save's record of the region history (MLSaveGame.productionLogs: members and the first record), from a
--            save object still in memory if there is one; the subsystem object's address for the native read
--   grid     the drawn texture's size (RT_Fertility), the redraw queue, the switch
local C = _G.Coop; local S = C and C.s
if not (S and S.eng) then return "no world" end
local out = {}
local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
local function try(what, fn) local ok, e = pcall(fn); if not ok then add("%s: ERROR %s", what, tostring(e)) end end
local function kind(p) return p:GetClass():GetFName():ToString() end
local function members(st, depth, pre, t)          -- a struct's members: name:kind@offset, nested to depth
  t = t or {}
  st:ForEachProperty(function(p)
    local n = (pre or "") .. p:GetFName():ToString(); local k = kind(p)
    t[#t + 1] = string.format("%s:%s@%X", n, k, p:GetOffset_Internal())
    if k == "StructProperty" and depth > 0 then members(p:GetStruct(), depth - 1, n .. ".", t) end
    if k == "ArrayProperty" and depth > 0 then
      local inner = p:GetInner()
      if kind(inner) == "StructProperty" then members(inner:GetStruct(), depth - 1, n .. "[].", t) else t[#t + 1] = n .. "[]:" .. kind(inner) end
    end
  end)
  return t
end
local function val(v) if type(v) == "userdata" then local ok, s = pcall(function() return v:ToString() end); if ok then return s end; return "?" end; return tostring(v) end

add("== stats module")
try("probe", function() add("%s", C.stats.probe()) end)

add("== tracker: entries per good (GetEntriesOfItemType) on the first 4 buildings that have any")
try("tracker", function()
  local arr = S.eng.buildingArr; local shown = 0
  for i = 1, #arr do
    if shown >= 4 then break end
    local b = C.api.un(arr[i])
    local c = b.ProductionTrackerComponent
    if c and c:IsValid() then
      local ng = c:GetNumberOfGoodTypesInLog()
      if ng > 0 then
        shown = shown + 1
        local goods = {}
        for k in pairs(c:getGoodsProducedOver(366) or {}) do goods[#goods + 1] = tonumber(k) or k end; table.sort(goods)
        local parts = {}
        for _, g in ipairs(goods) do
          local e = c:GetEntriesOfItemType(g); local n = #e
          local days, order = {}, true
          for j = 1, n do local d = e[j].DayProduced; days[j] = d; if j > 1 and not (d > days[j - 1]) then order = false end end
          parts[#parts + 1] = string.format("good %d: %d entries (cap 366), days %s..%s one a day %s, first amount %s, last amount %s",
            g, n, val(days[1]), val(days[n]), tostring(order), n > 0 and val(e[1].QuantityProduced) or "-", n > 0 and val(e[n].QuantityProduced) or "-")
        end
        add("building %d: %d goods; %s; time list %d, total time %s", i, ng, table.concat(parts, " | "), #c.timeEntries, val(c:GetTotalTime()))
      end
    end
  end
  local st = StaticFindObject("/Script/ManorLords.ProductionTrackerEntry"); if st then add("ProductionTrackerEntry: %s", table.concat(members(st, 1), " ")) end
end)

add("== region history")
try("save struct", function()
  local cls = StaticFindObject("/Script/ManorLords.MLSaveGame")
  cls:ForEachProperty(function(p) if p:GetFName():ToString() == "productionLogs" then add("MLSaveGame.productionLogs: %s", table.concat(members(p:GetInner():GetStruct(), 3, "", {}), " ")) end end)
end)
try("save objects", function()
  local all = FindAllOf("MLSaveGame") or {}
  add("save objects in memory: %d", #all)
  for i, s in ipairs(all) do
    if i > 2 then break end
    local logs = s.productionLogs; add("  save %d: productionLogs %d regions", i, #logs)
    if #logs > 0 then
      local r = logs[1]; local t = {}
      local st = nil
      StaticFindObject("/Script/ManorLords.MLSaveGame"):ForEachProperty(function(p) if p:GetFName():ToString() == "productionLogs" then st = p:GetInner():GetStruct() end end)
      st:ForEachProperty(function(p)
        local n = p:GetFName():ToString(); local k = kind(p); local v = r[n]
        if k == "ArrayProperty" then t[#t + 1] = n .. "=" .. #v .. " records" else t[#t + 1] = n .. "=" .. val(v) end
      end)
      add("  first region record: %s", table.concat(t, " "))
    end
  end
end)
try("subsystem", function()
  local ss = FindFirstOf("ProductionSubsystem")
  add("ProductionSubsystem object: %s at %X (native read: list +38h, count +40h, 20h a region)", ss and ss:IsValid() and "found" or "none", ss and ss:GetAddress() or 0)
end)

add("== fertility grid")
try("grid", function()
  local e = S.eng
  add("enableFertilityGrid %s, redraw queue %d, fertilityUpdateTimer %s", tostring(e.enableFertilityGrid), #e.fertilityGridUpdateRequests, val(e.TemporalComponent.fertilityUpdateTimer))
  local rt = e.RT_Fertility
  if rt and rt:IsValid() then add("RT_Fertility %s x %s (the grid is 1024 x 1024 cells by its loops: cell = x + 1024 y)", val(rt.SizeX), val(rt.SizeY)) end
  add("engine at %X: the native read is the list at +8E0h (count +8E8h, 10h bytes a cell) and its twin at +8F0h", e:GetAddress())
end)
return table.concat(out, "\n")
