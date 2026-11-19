-- Self-test of sweep_walk.lua without the game: a made-up widget tree with the UE4SS methods the walker uses.
--   lua tools/dev/sweep/test_walk.lua        (plain Lua 5.1 or 5.4; prints PASS / FAIL lines, exit code 1 on a failure)
-- Cases: texts, a progress bar, a slider, a check box, an image with brush and tint, a hidden subtree, a widget
-- switcher (only its active page), a dead handle, a read that throws, a list view's shown entries, instance numbers
-- taken off names, sibling numbers, an empty panel, the node limit and the depth limit.
local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"))
local dir = here:match("^(.*/)[^/]*$") or "./"
local W = dofile(dir .. "sweep_walk.lua")

local fails = 0
local function check(c, what) if c then print("PASS  " .. what) else fails = fails + 1; print("FAIL  " .. what) end end

-- a mock widget: cls, name, props; kids = list (a panel), content = one (a content widget), root = a user widget's tree
local function mk(cls, name, t)
  t = t or {}
  local o = { _cls = cls, _name = name, _vis = t.vis or 0, _dead = t.dead, _kids = t.kids, _content = t.content, _root = t.root,
              _text = t.text, Percent = t.percent, _value = t.value, _checked = t.checked, _entries = t.entries, _active = t.active,
              _throw = t.throw }
  if t.brush then o.Brush = { ResourceObject = t.brush } end
  if t.tint then o.ColorAndOpacity = t.tint end
  if t.root then o.WidgetTree = { RootWidget = t.root } end
  function o:IsValid() if self._dead then error("dead object") end; return true end
  function o:GetClass() local c = self._cls; return { GetFullName = function() return "Class /Game/UI/X." .. c end } end
  function o:GetFName() local n = self._name; return { ToString = function() return n end } end
  function o:GetVisibility() return self._vis end
  if t.kids then
    function o:GetChildrenCount() return #self._kids end
    function o:GetChildAt(i) return self._kids[i + 1] end
  end
  if t.active then function o:GetActiveWidget() return self._kids[self._active + 1] end; function o:GetActiveWidgetIndex() return self._active end end
  if t.content then function o:GetContent() return self._content end end
  if t.entries then function o:GetDisplayedEntryWidgets() return self._entries end end
  if t.text then function o:GetText() if self._throw then error("boom") end; local s = self._text; return { ToString = function() return s end } end end
  if t.value then function o:GetValue() return self._value end end
  if t.checked ~= nil then function o:IsChecked() return self._checked end end
  return o
end
local function txt(name, s, extra) extra = extra or {}; extra.text = s; return mk("TextBlock", name, extra) end

local brush = mk("Texture2D", "T_Icon_Maintained")
local page0 = mk("VerticalBox", "Page0", { kids = { txt("TextBlock_7", "old page") } })
local page1 = mk("VerticalBox", "Page1", { kids = { txt("TextBlock_8", "new page") } })
local entryA = mk("W_HumanEntry_C", "W_HumanEntry_C_12", { root = mk("HorizontalBox", "HB", { kids = { txt("Name", "Anna") } }) })
local entryB = mk("W_HumanEntry_C", "W_HumanEntry_C_40", { root = mk("HorizontalBox", "HB", { kids = { txt("Name", "Bero") } }) })
local tree = mk("Inventory_C", "Inventory_C_3", { root = mk("CanvasPanel", "Root", { kids = {
  txt("Title", "Woodcutter's Lodge"),
  txt("TextBlock_1", "Maintained"),
  txt("TextBlock_2", "Fair 100 %"),
  mk("ProgressBar", "Bar", { percent = 0.75 }),
  mk("Slider", "Slider_0", { value = 2 }),
  mk("CheckBox", "Check", { checked = true }),
  mk("Image", "Icon", { brush = brush, tint = { R = 1, G = 0.5, B = 0, A = 1 } }),
  mk("VerticalBox", "Hidden", { vis = 1, kids = { txt("Secret", "not shown") } }),
  mk("WidgetSwitcher", "Switch", { kids = { page0, page1 }, active = 1 }),
  mk("TextBlock", "Dead", { dead = true }),
  txt("Throws", "x", { throw = true }),
  mk("ListView", "List", { entries = { entryA, entryB } }),
  mk("Border", "Frame", { content = txt("Inner", "inside") }),
} }) })

local recs, st = W.walk(tree, {})
local by = {}; for _, r in ipairs(recs) do by[#by + 1] = r.kind .. " " .. r.path .. " = " .. r.val end
local all = table.concat(by, "\n")
local function has(s) return all:find(s, 1, true) ~= nil end
check(has("T Inventory_C:Inventory_C#1/CanvasPanel:Root#1/TextBlock:Title#1 = Woodcutter's Lodge"), "a text and its path (instance number off the root name)")
check(has("TextBlock:TextBlock#1 = Maintained") and has("TextBlock:TextBlock#2 = Fair 100 %"), "two TextBlock_n siblings: same name, numbered 1 and 2")
check(has("P Inventory_C:Inventory_C#1/CanvasPanel:Root#1/ProgressBar:Bar#1 = 0.75"), "a progress bar's Percent")
check(has("S Inventory_C:Inventory_C#1/CanvasPanel:Root#1/Slider:Slider#1 = 2"), "a slider's value")
check(has("C Inventory_C:Inventory_C#1/CanvasPanel:Root#1/CheckBox:Check#1 = 1"), "a check box")
check(has("I Inventory_C:Inventory_C#1/CanvasPanel:Root#1/Image:Icon#1 = T_Icon_Maintained|1.00,0.50,0.00,1.00"), "an image: brush and tint")
check(not has("not shown"), "a hidden subtree is not walked")
check(has("new page") and not has("old page"), "a switcher: only the active page")
check(has("W Inventory_C:Inventory_C#1/CanvasPanel:Root#1/WidgetSwitcher:Switch#1 = 1"), "a switcher's active index is recorded")
check(has("! Inventory_C:Inventory_C#1/CanvasPanel:Root#1 = dead child 9") or has("dead"), "a dead handle is noted, not fatal")
check(has("Throws#1 = read failed (T)"), "a read that throws: noted as failed")
check(has("ListView:List#1/W_HumanEntry_C:W_HumanEntry_C#1/HorizontalBox:HB#1/TextBlock:Name#1 = Anna") and has("W_HumanEntry_C:W_HumanEntry_C#2/HorizontalBox:HB#1/TextBlock:Name#1 = Bero"), "list view entries: in order, instance numbers off")
check(has("Border:Frame#1/TextBlock:Inner#1 = inside"), "a content widget's content")
check(st.failed == 1 and st.truncated == false, "stats: one failed read, not truncated")

local empty = mk("Inventory_C", "Inventory_C_1", { root = mk("CanvasPanel", "Root", { kids = {} }) })
local r2, s2 = W.walk(empty, {})
check(#r2 == 0 and s2.nodes == 2, "an empty panel: no records, two nodes")

local r3, s3 = W.walk(tree, { maxNodes = 5 })
local trunc = false; for _, r in ipairs(r3) do if r.kind == "!" and r.val:find("truncated", 1, true) then trunc = true end end
check(s3.truncated and trunc, "the node limit: a truncated note")

local r4, s4 = W.walk(tree, { maxDepth = 1 })
local deep = false; for _, r in ipairs(r4) do if r.kind == "!" and r.val:find("too deep", 1, true) then deep = true end end
check(deep and s4.deep > 0, "the depth limit: a too-deep note")

local r5, s5 = W.walk(tree, { skip = { ListView = true } })
local listed = false; for _, r in ipairs(r5) do if r.val == "Anna" then listed = true end end
check(not listed and s5.skipped == 1, "a skipped class and its subtree are left out")

local deadRoot = mk("Inventory_C", "X", { dead = true })
local r6 = W.walk(deadRoot, {})
check(#r6 == 1 and r6[1].val == "dead handle", "a dead root: one note")

check(W.strip("W_HumanEntry_C_12") == "W_HumanEntry_C" and W.strip("TextBlock_3") == "TextBlock" and W.strip("Text_Name") == "Text_Name", "names: instance numbers off")

print(fails .. " failed")
if fails > 0 then os.exit(1) end
