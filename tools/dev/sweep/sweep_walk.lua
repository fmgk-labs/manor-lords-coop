-- Parity sweep (lane 68): the widget walker. Reads what a panel DRAWS: every shown text, progress bar, slider,
-- check box, spin box, combo box, widget switcher and image (brush name and tint), with a path that names the same
-- widget on every copy. It never calls a widget's own function other than the plain getters listed in READ below,
-- never presses, never writes.
--
-- Loaded by sweep_probe.lua in the game (UE4SS Lua 5.4) and by test_walk.lua without the game (plain Lua 5.1 or 5.4):
-- the code uses nothing that differs between the two (no math.type, no integer division, no goto).
--
-- A record: { path = <string>, kind = <letter>, val = <string> }
--   kind  T text   P progress bar (Percent)   S slider (GetValue)   C check box (IsChecked)   N spin box (GetValue)
--         O combo box (GetSelectedOption)    W widget switcher (active index)   I image (brush resource, tint)
--         X editable text                    ! a note of the walker itself (truncated, too deep, a read failed)
-- path  one step per level, from the root: <class>:<name>#<n>, joined by "/".
--         class  the widget's class name (the part after the last ".")
--         name   its object name with an instance suffix taken off ("W_HumanEntry_C_12" -> "W_HumanEntry_C",
--                "TextBlock_3" -> "TextBlock"): instance numbers are made per copy and per opening
--         n      its place among the siblings of the same class and name (1 = first), so a list of entries keeps
--                the game's order: the same entry on both copies has the same path when the lists are equal
-- Hidden subtrees (visibility Collapsed or Hidden) are not walked: what the player cannot see is not compared.
-- Of a widget switcher only the active child is walked: the other pages hold old values that nobody sees.
-- Limits: opts.maxNodes (default 6000) and opts.maxDepth (default 48). Hitting one writes a "!" record: a dump is
-- never cut silently.

local M = {}

local function ok1(f, ...) local ok, v = pcall(f, ...); if ok then return v end; return nil end

-- an object handle is alive: not nil and IsValid() says so (a dead handle answers false or throws)
function M.alive(o)
  if o == nil then return false end
  local ok, v = pcall(function() return o:IsValid() end)
  return ok and v == true
end

function M.cname(w)
  local full = ok1(function() return w:GetClass():GetFullName() end)
  if type(full) ~= "string" then return "?" end
  return full:match("([^%.]+)$") or full
end

function M.oname(w)
  local n = ok1(function() return w:GetFName():ToString() end)
  if type(n) ~= "string" then return "?" end
  return n
end

-- "W_HumanEntry_C_12" -> "W_HumanEntry_C"; "TextBlock_3" -> "TextBlock"; "Text_Name" stays
function M.strip(n)
  local a = n:gsub("_C_%d+$", "_C")
  if a ~= n then return a end
  return (n:gsub("_%d+$", ""))
end

local function shown(w)
  local v = ok1(function() return w:GetVisibility() end)
  if v == nil then return true end
  return v ~= 1 and v ~= 2          -- ESlateVisibility: 1 Collapsed, 2 Hidden
end

local function clean(s)
  s = tostring(s)
  s = s:gsub("\r", ""):gsub("\n", "\\n"):gsub("\t", " ")
  return s
end

local function num(v)
  if type(v) ~= "number" then return tostring(v) end
  if v ~= v then return "nan" end
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
  local s = string.format("%.3f", v)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  return s
end

local function str(v)                                  -- FText / FString / string -> string
  if type(v) == "string" then return v end
  if v == nil then return nil end
  local s = ok1(function() return v:ToString() end)
  if type(s) == "string" then return s end
  return tostring(v)
end

local function textOf(w) return str(ok1(function() return w:GetText() end)) end

-- the reads, by class name: the first rule whose class matches is used; a widget with no rule gives no value record
-- (its children are walked as usual). Each read is one pcall: a failing read gives "?" and a "!" note, never an error.
local TEXTS = { TextBlock = true, MLTextBlock = true, RichTextBlock = true, MLRichTextBlock = true, MLNumericTextBlock = true }
local EDITS = { EditableText = true, EditableTextBox = true, MultiLineEditableText = true, MultiLineEditableTextBox = true }
local function read(w, cls)
  if TEXTS[cls] then return "T", textOf(w) end
  if EDITS[cls] then return "X", textOf(w) end
  if cls == "ProgressBar" then return "P", num(ok1(function() return w.Percent end)) end
  if cls == "Slider" then return "S", num(ok1(function() return w:GetValue() end)) end
  if cls == "SpinBox" then return "N", num(ok1(function() return w:GetValue() end)) end
  if cls == "CheckBox" then
    local v = ok1(function() return w:IsChecked() end)
    if v == nil then return "C", nil end
    return "C", v and "1" or "0"
  end
  if cls == "ComboBoxString" then return "O", str(ok1(function() return w:GetSelectedOption() end)) end
  if cls == "Image" then
    local res = ok1(function() local r = w.Brush.ResourceObject; if r == nil then return "-" end; if not M.alive(r) then return "-" end; return r:GetFName():ToString() end)
    -- a dynamic material instance is named per copy ("MID_MI_UI_Checkbox_2147454794", first game run): number off
    if type(res) == "string" then res = res:gsub("^(MID_.-)_%d+$", "%1") end
    local tint = ok1(function() local c = w.ColorAndOpacity; return string.format("%.2f,%.2f,%.2f,%.2f", c.R, c.G, c.B, c.A) end)
    if res == nil and tint == nil then return "I", nil end
    return "I", (res or "?") .. "|" .. (tint or "?")
  end
  return nil
end
M.read = read

-- children of a widget, in order: a panel's children, a content widget's content, a list view's shown entries, a user
-- widget's tree root. MD_ navigation wrappers are not entered through their tree (tools/dev/lua/lib.lua does the same).
local function kids(w, cls, notes, path)
  local out = {}
  local n = ok1(function() return w:GetChildrenCount() end)
  if type(n) == "number" then
    if cls == "WidgetSwitcher" then                    -- only the page the player sees
      local a = ok1(function() return w:GetActiveWidget() end)
      if M.alive(a) then out[1] = a end
      return out, true
    end
    for i = 0, n - 1 do
      local c = ok1(function() return w:GetChildAt(i) end)
      if M.alive(c) then out[#out + 1] = c elseif c ~= nil then notes[#notes + 1] = { path = path, kind = "!", val = "dead child " .. i } end
    end
    return out
  end
  local entries = ok1(function() return w:GetDisplayedEntryWidgets() end)   -- ListView / TileView: virtualised entries
  if entries ~= nil then
    local cnt = ok1(function() return #entries end)
    if type(cnt) == "number" then
      for i = 1, cnt do                                -- never past the end (reading past the end grows a game list)
        local e = ok1(function() local x = entries[i]; local g = ok1(function() return x:get() end); if g ~= nil then return g end; return x end)
        if M.alive(e) then out[#out + 1] = e end
      end
      if #out > 0 then return out end
    end
  end
  local c = ok1(function() return w:GetContent() end)
  if M.alive(c) then out[1] = c; return out end
  if cls:sub(1, 3) ~= "MD_" then
    local r = ok1(function() return w.WidgetTree.RootWidget end)
    if M.alive(r) then out[1] = r end
  end
  return out
end

-- walk(root, opts) -> records, stats
--   opts.skip    { [class name] = true }: such a widget and everything under it is left out (counted in stats.skipped)
--   opts.maxNodes, opts.maxDepth
--   opts.prefix  a path to put in front (default: none)
function M.walk(root, opts)
  opts = opts or {}
  local maxN, maxD = opts.maxNodes or 6000, opts.maxDepth or 48
  local skip = opts.skip or {}
  local recs, notes = {}, {}
  local stats = { nodes = 0, skipped = 0, values = 0, failed = 0, truncated = false, deep = 0 }
  local function step(w, path, d)
    if stats.nodes >= maxN then
      if not stats.truncated then stats.truncated = true; notes[#notes + 1] = { path = path, kind = "!", val = "truncated at " .. maxN .. " widgets" } end
      return
    end
    if not M.alive(w) then notes[#notes + 1] = { path = path, kind = "!", val = "dead handle" }; return end
    if not shown(w) then return end
    local cls = M.cname(w)
    if skip[cls] then stats.skipped = stats.skipped + 1; return end
    stats.nodes = stats.nodes + 1
    local k, v = read(w, cls)
    if k then
      if v == nil then stats.failed = stats.failed + 1; notes[#notes + 1] = { path = path, kind = "!", val = "read failed (" .. k .. ")" }
      else stats.values = stats.values + 1; recs[#recs + 1] = { path = path, kind = k, val = clean(v) } end
    end
    if d >= maxD then stats.deep = stats.deep + 1; notes[#notes + 1] = { path = path, kind = "!", val = "too deep (" .. maxD .. ")" }; return end
    local list, switched = kids(w, cls, notes, path)
    if switched then
      local idx = ok1(function() return w:GetActiveWidgetIndex() end)
      recs[#recs + 1] = { path = path, kind = "W", val = num(idx) }
    end
    local seen = {}
    for _, c in ipairs(list) do
      local label = M.cname(c) .. ":" .. M.strip(M.oname(c))
      seen[label] = (seen[label] or 0) + 1
      step(c, path .. "/" .. label .. "#" .. seen[label], d + 1)
    end
  end
  local rl = M.cname(root) .. ":" .. M.strip(M.oname(root)) .. "#1"
  step(root, (opts.prefix and (opts.prefix .. "/") or "") .. rl, 0)
  for _, n in ipairs(notes) do recs[#recs + 1] = n end
  return recs, stats
end

return M
