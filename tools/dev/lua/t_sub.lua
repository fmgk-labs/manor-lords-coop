local p = panel(); if not p then return "no panel" end
local root = find(p, SUBNAME) or p
local o = {}
for _, e in ipairs(under(root, 9)) do
  if #o < 90 and shown(e.w) then
    local cn = cname(e.w)
    if cn ~= "Image" and cn ~= "Spacer" and cn ~= "SizeBox" and cn ~= "Overlay" and cn ~= "Border" and cn:sub(1, 3) ~= "MD_" then
      local s = ""; pcall(function() s = " '" .. e.w:GetText():ToString():sub(1, 24) .. "'" end)
      o[#o + 1] = string.rep(" ", e.d) .. cn .. " " .. e.w:GetFName():ToString() .. s
    end
  end
end
return table.concat(o, "\n")
