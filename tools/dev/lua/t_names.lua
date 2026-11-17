local p = panel(); if not p then return "no panel" end
local o, seen = {}, {}
local function interesting(cn) return cn:find("Button") or cn:find("Slider") or cn:find("Checkbox") or cn:find("Spinner") or cn:find("Combo") or cn:find("upgradeWidget") or cn:find("extensionSlot") or cn:find("Entry") or cn:find("Row") or cn:find("Limit") end
local function walk(w, d)
  if d > 40 or #o > 120 or not shown(w) then return end
  local cn = cname(w); local nm = w:GetFName():ToString()
  if interesting(cn) and cn:sub(1, 3) ~= "MD_" and cn ~= "Button" and nm ~= "Button" and nm ~= "HelpButton" then
    local s = ""; pcall(function() local t = w:GetText():ToString(); if t ~= "" then s = "='" .. t:sub(1, 18) .. "'" end end)
    o[#o + 1] = nm:gsub("_C_%d+$", "_C#") .. "(" .. cn:gsub("^W_", ""):gsub("_C$", "") .. ")" .. s
  end
  local okN, n = pcall(function() return w:GetChildrenCount() end)
  if okN and type(n) == "number" then for i = 0, n - 1 do local c = w:GetChildAt(i); if c and c:IsValid() then walk(c, d + 1) end end; return end
  local okC, c = pcall(function() return w:GetContent() end)
  if okC and c and c:IsValid() then walk(c, d + 1); return end
  local okT, r = pcall(function() return w.WidgetTree.RootWidget end)
  if okT and r and r:IsValid() and cn:sub(1, 3) ~= "MD_" then walk(r, d + 1) end
end
walk(p, 0)
return table.concat(o, "  ")
