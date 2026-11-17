local p = panel(); if not p then return "no panel" end
local w; for _, e in ipairs(under(p, 30)) do if cname(e.w) == CLS and shown(e.w) and not w then w = e.w end end
if not w then return "no " .. CLS end
local o = {}
local ok, e = pcall(function()
  w:GetClass():ForEachProperty(function(pr)
    local n = pr:GetFName():ToString(); local v = "?"
    pcall(function() local x = w[n]; if type(x) ~= "userdata" then v = tostring(x) else v = "<obj>" end end)
    o[#o + 1] = n .. "=" .. v
  end)
end)
return (ok and "" or ("err " .. tostring(e) .. " ")) .. table.concat(o, "  ")
