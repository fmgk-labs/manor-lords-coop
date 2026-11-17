local n91, n93 = 0, 0
for _, b in ipairs(buildings()) do if mine(b) then local t = b:GetType(); if t == 91 then n91 = n91 + 1 elseif t == 93 then n93 = n93 + 1 end end end
local m = bType(13, 1); local g = bType(80, 1); local st = bType(72, 1)
local function v(b) if not b then return "-" end; local n = "?"; pcall(function() n = tostring(b:getNumMarketStalls()) end); return (b.allowMarketStalls and "on" or "off") .. "/" .. n end
return string.format("food stalls %d goods stalls %d | market %s granary %s storehouse %s", n91, n93, v(m), v(g), v(st))
