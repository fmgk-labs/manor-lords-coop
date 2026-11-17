-- Value-by-value picture of this copy's game state, for comparing two copies (tools/dev/statediff.sh).
-- Walks every reflected property of the engine, the player's lord, every region, every building, every family and its
-- members, and writes one line per simple value:  <object key>|<property>=<value>
-- Simple = number, bool, name, string, enum; an object reference is written as valid / none; an array as its length;
-- a struct is walked one level deep. Positions, rotations and things that are different by nature are left out here
-- and counted separately by the comparison script.
local OUT = OUT_PATH or (os.getenv("TEMP") .. "\\state.txt")
local f = assert(io.open(OUT, "w"))
local n = 0
local SKIP = { ["UberGraphFrame"] = true }
local function cls(p) local ok, c = pcall(function() return p:GetClass():GetFName():ToString() end); return ok and c or "?" end
local function pname(p) local ok, c = pcall(function() return p:GetFName():ToString() end); return ok and c or "?" end
local function fmtnum(v) if v ~= v then return "nan" end; if math.type(v) == "integer" then return tostring(v) end; return string.format("%.3f", v) end

local function value(obj, name, kind, depth)
  local ok, v = pcall(function() return obj[name] end)
  if not ok then return "ERR" end
  if kind == "BoolProperty" then return tostring(v and true or false)
  elseif kind == "IntProperty" or kind == "ByteProperty" or kind == "Int64Property" or kind == "UInt32Property" or kind == "Int8Property" or kind == "Int16Property" or kind == "UInt16Property" or kind == "UInt64Property" or kind == "EnumProperty" then
    return type(v) == "number" and fmtnum(v) or tostring(v)
  elseif kind == "FloatProperty" or kind == "DoubleProperty" then return type(v) == "number" and fmtnum(v) or tostring(v)
  elseif kind == "NameProperty" or kind == "StrProperty" or kind == "TextProperty" then
    local ok2, s = pcall(function() return v:ToString() end); return ok2 and s or tostring(v)
  elseif kind == "ObjectProperty" or kind == "WeakObjectProperty" or kind == "SoftObjectProperty" or kind == "ClassProperty" then
    local ok2, a = pcall(function() return v ~= nil and v:IsValid() end); return (ok2 and a) and "valid" or "none"
  elseif kind == "ArrayProperty" or kind == "SetProperty" or kind == "MapProperty" then
    local ok2, c = pcall(function() return #v end); return ok2 and ("len " .. tostring(c)) or "len ?"
  end
  return nil
end

local function walk(key, obj, struct, depth)
  local okc = pcall(function()
    struct:ForEachProperty(function(p)
      local name = pname(p); if SKIP[name] then return end
      local kind = cls(p)
      if kind == "StructProperty" then
        if depth < 1 then
          local oks, sub = pcall(function() return obj[name] end)
          local okt, st = pcall(function() return p:GetStruct() end)
          if oks and okt and sub ~= nil and st ~= nil then
            pcall(function()
              st:ForEachProperty(function(q)
                local qn, qk = pname(q), cls(q)
                local v = value(sub, qn, qk, depth + 1)
                if v ~= nil then f:write(key, "|", name, ".", qn, "=", v, "\n"); n = n + 1 end
              end)
            end)
          end
        end
      elseif kind ~= "DelegateProperty" and kind ~= "MulticastInlineDelegateProperty" and kind ~= "MulticastDelegateProperty" and kind ~= "InterfaceProperty" then
        local v = value(obj, name, kind, depth)
        if v ~= nil then f:write(key, "|", name, "=", v, "\n"); n = n + 1 end
      end
    end)
  end)
  if not okc then f:write(key, "|WALK=failed\n") end
end
local function walkObj(key, obj)
  local c = obj:GetClass()
  -- the class and its parents up to the game's own base classes (engine base classes are not game state)
  local guard = 0
  while c ~= nil and c:IsValid() and guard < 6 do
    local cn = c:GetFName():ToString()
    if cn == "Actor" or cn == "Object" or cn == "Pawn" or cn == "Character" or cn == "Info" or cn == "ActorComponent" then break end
    walk(key, obj, c, 0)
    local okp, sup = pcall(function() return c:GetSuperStruct() end)
    if not okp then break end
    c = sup; guard = guard + 1
  end
end

local function bk(b) local l = b:K2_GetActorLocation(); local t = "?"; pcall(function() t = tostring(b:GetType()) end); local own = "o"; pcall(function() if mine(b) then own = "p" end end); return string.format("B%s %s@%d,%d", own, t, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5)) end   -- Bp = the player's building, Bo = somebody else's

walkObj("ENGINE", eng)
walkObj("LORD", lord)
pcall(function() walkObj("TIME", eng.TemporalComponent) end)
local ri = 0
for _, r in ipairs(FindAllOf("Region") or {}) do
  local tag = "?"; pcall(function() tag = r.regionTag:ToString() end)
  if tag == "?" or tag == "" then pcall(function() tag = r.regionName:ToString() end) end
  ri = ri + 1
  local key = "R " .. tostring(tag)
  walkObj(key, r)
  local okf, fams = pcall(function() return r.workerFamilies end)
  if okf and fams then
    local st = StaticFindObject("/Script/ManorLords.WorkerFamily")
    for i = 1, #fams do
      local fk = key .. " F" .. i
      walk(fk, fams[i], st, 0)
      pcall(function()
        local m = fams[i].familyMembers
        for j = 1, #m do local u = m[j]; if u ~= nil and u:IsValid() then walkObj(fk .. " M" .. j, u) end end
      end)
    end
  end
end
local seen = {}
for _, b in ipairs(buildings()) do
  local k = bk(b); seen[k] = (seen[k] or 0) + 1; if seen[k] > 1 then k = k .. " #" .. seen[k] end
  walkObj(k, b)
end
f:close()
return "state written: " .. n .. " values, " .. ri .. " regions, " .. #buildings() .. " buildings -> " .. OUT
