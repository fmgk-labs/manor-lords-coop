local p = panel(); if not p then return "no panel" end
local o = {}; local n = 0
for _, e in ipairs(under(p, 30)) do
  if cname(e.w) == "upgradeWidget_C" and shown(e.w) then
    n = n + 1
    local id, pos, en, can, has, cost = "?", "?", "?", "?", "?", "?"
    pcall(function() id = e.w.ID; pos = tostring(e.w.possible); en = tostring(e.w.Enabled) end)
    pcall(function() can = tostring(e.w.building:canUpgrade(id, {})); has = tostring(e.w.building:hasUpgrade(id)); cost = tostring(e.w.building:GetRegionalWealthCostForUpgrade(id)) end)
    o[#o + 1] = string.format("#%d id %s possible %s enabled %s can %s has %s wealth %s", n, tostring(id), pos, en, can, has, cost)
  end
end
return table.concat(o, " | ")
