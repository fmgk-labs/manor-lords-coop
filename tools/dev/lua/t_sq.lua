local sc = FindFirstOf("SquadComponent"); local o = {}
local arr = lord.commandedSquads
for i = 1, #arr do
  local v = arr[i].Value; local s = sc:GetSquad({ Value = v })
  local sk = {}; pcall(function() for j = 1, #s.activeSkills do sk[#sk + 1] = tostring(un(s.activeSkills[j])) end end)
  local push, beh = "?", "?"; pcall(function() push = tostring(s.pushStance) end); pcall(function() beh = tostring(s.behaviourStance) end)
  o[#o + 1] = string.format("%d men %d push %s behav %s skills [%s]", v, sc:GetUnitCount({ Value = v }), push, beh, table.concat(sk, ","))
end
local sel = {}; pcall(function() local x = lord.selectedSquads; for i = 1, #x do sel[#sel + 1] = tostring(x[i].Value) end end)
return table.concat(o, " | ") .. " || selected " .. table.concat(sel, ",")
