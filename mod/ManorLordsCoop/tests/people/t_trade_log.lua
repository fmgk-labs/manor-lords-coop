-- Exercise the real people relay on a history larger than one link message.
-- Run with lane67/luacheck.py run from the repository root.
local function history()
  local a = { Empty = function(self)
    for i = #self, 1, -1 do self[i] = nil end
  end }
  setmetatable(a, { __index = function(_, k)
    if type(k) == "number" then error("read outside trade history at " .. k) end
  end })
  for i = 1, 312 do
    a[i] = {
      fromRegionIndex = (i <= 51 or i > 300) and 2 or 7, toRegionIndex = 255,
      goodType = 3, goodAmt = i, priceTotal = 10, daysTotal = i, isImport = false
    }
  end
  return a
end

local lines = {}
local function copy(role)
  local module
  local core = {
    people = { on = { grow = false, families = false, members = false } },
    register = function(_, m) module = m end,
    api = {
      valid = function(o) return o ~= nil and o.alive == true end,
      un = function(o) return o end, log = function() end,
      send = function(s) if s:match("^V T ") then lines[#lines + 1] = s end end
    }
  }
  _G.Coop = core
  dofile("mod/ManorLordsCoop/Scripts/coop_x_people.lua")
  local s = { role = role, worlds = 1, p1 = { alive = true },
    eng = { alive = true, tradeLog = history(), buildingArr = {}, roads = {} } }
  module.onWorld(s)
  return module, s
end

local host, hs = copy("host")
local friend, fs = copy("friend")
local log = fs.eng.tradeLog
log[312].goodAmt = 1
host.tick(hs, 4)
local total = lines[1] and tonumber(lines[1]:match("^V T (%d+)"))
assert(total == 312, "expected all 312 host records, got " .. tostring(total))
assert(#lines > 1, "fixture must cross a link message boundary")
for i, line in ipairs(lines) do
  local words = { tostring(i), "1.000" }
  for word in line:gmatch("%S+") do words[#words + 1] = word end
  friend.onMessage(fs, "host", "V", words, line)
  friend.tick(fs, 4 + i)
  if i < #lines then assert(#log == 312 and log[312].goodAmt == 1, "partial snapshot changed the log") end
end

assert(#log == 312, "rebuild lost history")
local regionRows = 0
for i = 1, #log do
  local r = log[i]
  assert(r.goodAmt == i and r.daysTotal == i, "wrong record at " .. i)
  if r.fromRegionIndex == 2 then regionRows = regionRows + 1 end
end
assert(regionRows == 63, "regional history was shortened")
print("PASS: 312 records in order, 63 regional rows, " .. #lines .. " parts, no out-of-bounds read")
