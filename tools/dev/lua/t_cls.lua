local p = panel(); if not p then return "no panel" end
local cnt, order = {}, {}
for _, e in ipairs(under(p, 40)) do
  local cn = cname(e.w)
  if cn:sub(-2) == "_C" and cn:sub(1, 3) ~= "MD_" then if not cnt[cn] then order[#order + 1] = cn end; cnt[cn] = (cnt[cn] or 0) + 1 end
end
local o = {}; for _, cn in ipairs(order) do o[#o + 1] = cn .. " x" .. cnt[cn] end
return table.concat(o, "  ")
