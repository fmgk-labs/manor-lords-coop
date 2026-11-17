local p = panel(); if not p then return "no panel" end
local o = {}
local function interesting(cn) return cn:find("Button") or cn:find("Slider") or cn:find("Checkbox") or cn:find("CheckBox") or cn:find("Spinner") or cn:find("Radio") or cn:find("Combo") or cn:find("upgradeWidget") or cn:find("extensionSlot") or cn:find("Entry") or cn:find("Tab") end
local function walk(w, d)
  if d > 18 or #o > 140 or not shown(w) then return end
  local cn = cname(w)
  if interesting(cn) and cn:sub(1, 3) ~= "MD_" and cn ~= "Button" then
    local s = ""; pcall(function() s = " '" .. w:GetText():ToString():sub(1, 24) .. "'" end)
    o[#o + 1] = string.rep(" ", math.min(d, 10)) .. cn .. " " .. w:GetFName():ToString() .. s
  end
  local okN, n = pcall(function() return w:GetChildrenCount() end)
  if okN and type(n) == "number" then for i = 0, n - 1 do local c = w:GetChildAt(i); if c and c:IsValid() then walk(c, d + 1) end end; return end
  local okC, c = pcall(function() return w:GetContent() end)
  if okC and c and c:IsValid() then walk(c, d + 1); return end
  local okT, r = pcall(function() return w.WidgetTree.RootWidget end)
  if okT and r and r:IsValid() and cn:sub(1, 3) ~= "MD_" then walk(r, d + 1) end
end
walk(p, 0)
return table.concat(o, "\n")
