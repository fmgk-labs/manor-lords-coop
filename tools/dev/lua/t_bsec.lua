local o = {}
for _, b in ipairs(buildings()) do
  if mine(b) then
    local ok, line = pcall(function()
      return string.format("%s %s lv%s w%s r%s%s%s", bkey(b), b:IsConstructed() and "B" or "u", tostring(b.lv), tostring(b:getNumActiveWorkerFamilies()), tostring(b:getNumResidingFamilies()), b.onFire and " F" or "", b.sleep and " S" or "")
    end)
    o[#o + 1] = ok and line or ("ERR " .. tostring(line))
  end
end
table.sort(o)
return table.concat(o, "\n")
