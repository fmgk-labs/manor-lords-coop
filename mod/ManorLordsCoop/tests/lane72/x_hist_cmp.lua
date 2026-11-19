-- Lane 72, region graphs (read only): this copy's newest 3 day records, keyed by region key and date, one line a map:
-- "<rkey> <d/m/y> <map> <good>=<n>;..." (sorted). Compare the host's and the friend's output with tools.
local C = _G.Coop; local S = C and C.s; local P = C and C.patch
if not (S and S.eng and P and P.fn) then return "no world or no native piece" end
local ss = FindFirstOf("ProductionSubsystem"); if not (ss and ss:IsValid()) then return "no subsystem" end
local keys = {}
local arr = S.eng.regions
for i = 1, #arr do local r = C.api.un(arr[i]); if r and r:IsValid() then keys[string.format("%X", r:GetAddress())] = C.world.rkey(r) end end
local tag = rawget(_G, "TAG") or "hc"
local path = P.dir .. "hist_sub_" .. tag .. ".txt"; os.remove(path)
P.send(string.format("HIST SUBDUMP %X %s %d", ss:GetAddress(), tag, rawget(_G, "DAYS") or 3)); P.tick()   -- (DAYS = 365: the whole history)
local f = io.open(path, "r"); if not f then return "no file" end
local out, cur = {}, nil
for l in f:lines() do
  local ra = l:match("^region %d+ (%x+) name"); if ra then cur = keys[ra] end
  local date, rest = l:match("^%s+day %d+ date (%S+) (.*)$")
  if date and cur then
    for name, items in rest:gmatch("(m%w+)%[%d+/%d+%]:?([^ ]*)") do
      local t = {}; for g, n in items:gmatch("(%-?%d+)=(%-?%d+)") do t[#t + 1] = g .. "=" .. n end; table.sort(t)
      out[#out + 1] = cur .. " " .. date .. " " .. name .. " " .. table.concat(t, ";")
    end
  end
end
f:close()
table.sort(out)
return "day " .. math.floor(S.eng.TemporalComponent.daysTotal) .. "\n" .. table.concat(out, "\n")
