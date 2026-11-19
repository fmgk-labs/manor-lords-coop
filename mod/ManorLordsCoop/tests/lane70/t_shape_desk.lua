-- Lane 70 desk test: the shape arithmetic of coop_x_army.lua itself (filesOf, centroidOf, dragFrom, dragAlong,
-- lineForShape), run under Lua 5.1 on cases written by shape_desk.py; the answers go to a file for the comparison.
--   driven by:  py -3 -I shape_desk.py          (ARG1 = cases file, ARG2 = answers file)
local function nop() end
_G.Coop = {
  register = nop,
  api = { valid = function(o) return o ~= nil end, log = nop, send = nop, far = function() return false end, un = function(x) return x end,
          toHost = function(h) return h end, toLocal = function(h) return h end, helper = nop },
  armyApi = {},
}
local chunk, e = loadfile(HERE .. "../../Scripts/coop_x_army.lua")
if not chunk then error(e) end
chunk()
local M = Coop.army
local SM = M.shapeMath
local out = assert(io.open(ARG2, "w"))
local function g(x) if x == nil then return "nil" end; return string.format("%.17g", x) end
local n = 0
for line in io.lines(ARG1) do
  local w = {}; for x in line:gmatch("%S+") do w[#w + 1] = x end
  local k = w[1]
  if k == "F" then                                   -- F seg spread
    out:write(string.format("F %d\n", SM.filesOf(tonumber(w[2]), tonumber(w[3]))))
  elseif k == "C" then                               -- C n fi
    local a, b = SM.centroidOf(tonumber(w[2]), tonumber(w[3])); out:write("C " .. g(a) .. " " .. g(b) .. "\n")
  elseif k == "D" then                               -- D n sp cx cy tx ty hx hy  (hx = "nil": no direction)
    local hx, hy = tonumber(w[8]), tonumber(w[9])
    local P, L, how, fi = M.dragFrom(tonumber(w[2]), tonumber(w[3]), tonumber(w[4]), tonumber(w[5]), tonumber(w[6]), tonumber(w[7]), hx, hy)
    if P then out:write(string.format("D %s %s %s %d %s\n", g(P.X), g(P.Y), g(L), fi, how)) else out:write("D nil\n") end
  elseif k == "A" then                               -- A n sp cx cy tx ty hx hy
    local P, L, how, fi = M.dragAlong(tonumber(w[2]), tonumber(w[3]), tonumber(w[4]), tonumber(w[5]), tonumber(w[6]), tonumber(w[7]), tonumber(w[8]), tonumber(w[9]))
    if P then out:write(string.format("A %s %s %s %d %s\n", g(P.X), g(P.Y), g(L), fi, how)) else out:write("A nil\n") end
  elseif k == "S" then                               -- S ax ay bx by fi sp sp2
    local P, Q = SM.lineForShape({ ax = tonumber(w[2]), ay = tonumber(w[3]), bx = tonumber(w[4]), by = tonumber(w[5]), fi = tonumber(w[6]), sp = tonumber(w[7]), z = 0, mob = false }, tonumber(w[8]))
    out:write(string.format("S %s %s %s %s\n", g(P.X), g(P.Y), g(Q.X), g(Q.Y)))
  elseif k == "M" then                               -- M n sp dx dy  x1 y1 x2 y2 ...  (the men's target places)
    local nn, sp, dx, dy = tonumber(w[2]), tonumber(w[3]), tonumber(w[4]), tonumber(w[5])
    local units, sx, sy = {}, 0, 0
    for i = 1, nn do
      local x, y = tonumber(w[4 + 2 * i]), tonumber(w[5 + 2 * i]); sx = sx + x; sy = sy + y
      units[i] = { meleeTraining = 1.0, dir = { X = dx, Y = dy }, getTargetPos = function() return { X = x, Y = y, Z = 0 } end }
    end
    local sq = { unitArr = units, spread = sp, activeSkills = {}, isEngaged = false, targetSquad = { Value = 0 }, Control = 0, TargetLocation = { X = sx / nn, Y = sy / nn } }   -- the game's target: the places' mean
    local S = { sc = { GetSquad = function() return sq end } }
    local m, why = M.measureShape(S, 1, false)
    if m then out:write(string.format("M %d %d %s %s\n", m.fi, m.ranks, g(m.P.X), g(m.P.Y))) else out:write("M nil " .. tostring(why):gsub("%s", "_") .. "\n") end
  end
  n = n + 1
end
out:close()
print(string.format("t_shape_desk: %d cases answered", n))
