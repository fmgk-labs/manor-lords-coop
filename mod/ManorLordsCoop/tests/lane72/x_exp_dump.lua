-- Lane 72, expertise probe (read only): every building's expertise as the game's own GetExpertise gives it, and the
-- native float (HIST EXP), keyed by the building key. An xdev chunk; returns "<bkey> <GetExpertise> <float>" lines.
local C = _G.Coop; local S = C and C.s; local X = C and C.stats
if not (S and X) then return "no world or no stats module" end
local P = C.patch
local idx = X.index and X.index(S)
local out, n = {}, 0
local list = idx and idx.list or {}
for _, k in ipairs(list) do
  local b = X.bObj and X.bObj(S, k)
  if b then
    local ok, c = pcall(function() return b.ExpertiseComponent end)
    if ok and c and c:IsValid() then
      local okG, g = pcall(function() return c:GetExpertise() end)
      if okG and type(g) == "number" and g ~= 0 then n = n + 1; out[#out + 1] = k .. " " .. string.format("%.3f", g) end
    end
  end
end
table.sort(out)
return "artisans " .. n .. " e_put " .. tostring(X.stats and X.stats.e_put) .. " e_err " .. tostring(X.stats and X.stats.e_err) .. "\n" .. table.concat(out, "\n")
