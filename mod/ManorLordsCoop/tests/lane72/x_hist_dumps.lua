-- Lane 72, gate 3 and 4 probe (read only): the native dumps of the region history and the fertility grid of this copy.
-- An xdev chunk; set TAG before it. Writes hist_sub_<TAG>.txt and hist_grid_<TAG>.txt in the native piece's folder
-- and returns them (the grid hashes in full, the region history's newest 5 days).
local C = _G.Coop; local S = C and C.s; local P = C and C.patch
if not (S and S.eng and P and P.fn) then return "no world or no native piece" end
local tag = rawget(_G, "TAG") or "x"
local out = {}
local ss = FindFirstOf("ProductionSubsystem")
if ss and ss:IsValid() then
  P.send(string.format("HIST SUBDUMP %X %s 5", ss:GetAddress(), tag)); P.tick()
  local f = io.open(P.dir .. "hist_sub_" .. tag .. ".txt", "r"); out[#out + 1] = f and f:read("a") or "no sub file"; if f then f:close() end
else out[#out + 1] = "no ProductionSubsystem" end
P.send(string.format("HIST GRIDHASH %X %s 32 %d", S.eng:GetAddress(), tag, rawget(_G, "STEPS") or 255)); P.tick()   -- (STEPS = 0: exact bits)
local g = io.open(P.dir .. "hist_grid_" .. tag .. ".txt", "r"); out[#out + 1] = g and g:read("a") or "no grid file"; if g then g:close() end
return table.concat(out, "\n")
