-- probe_patch_step2.lua - NOKILL ON: patch P1 (2 bytes in CombatHit) on THIS copy. Undo: probe_patch_step2_off.lua.
-- What it tests: the live write (VirtualProtect + one atomic 8-byte compare-exchange + read back) in the running game.
-- Run step1 first, on the same copy (a FRIEND copy, or a single copy; never the host of a real session).
-- Expected effect: on this copy nobody dies in combat any more: a hit that would kill leaves health at 1.0 (soldiers,
-- animals hit by hunters, villagers attacked by bandits). Damage, hit sounds and reactions stay.
-- CONFIRMED if the status below reads "P1 on" and line 1 is still "ready ...", and the log shows "P1 on at <address>".
-- Live check afterwards (optional): a fight on this copy where soldiers are hit hard but none falls.
-- the DLL of YOUR checkout (the same as in step1): edit the path below, or start the game with COOP_PATCH_DLL set to it
local DLL = os.getenv("COOP_PATCH_DLL") or [[C:\path\to\checkout\native\coop_patch\out\coop_patch.dll]]
if DLL:find([[\path\to\checkout\]], 1, true) then return "set DLL at the top of this probe (or COOP_PATCH_DLL) to your checkout's native\\coop_patch\\out\\coop_patch.dll" end

local function ioDir(dll)
  local dllDir = dll:match("^(.*)[\\/][^\\/]*$")
  local dir = dllDir .. "\\"
  local f = io.open(dllDir .. "\\coop_patch.cfg", "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if k and k:lower() == "dir" and v ~= "" and not line:match("^%s*#") then
        v = (v:gsub("%%([^%%]+)%%", function(n) return os.getenv(n) or ("%" .. n .. "%") end)):gsub("/", "\\")
        dir = (v:match("^%a:") or v:match("^\\\\")) and v or (dllDir .. "\\" .. v)
        if dir:sub(-1) ~= "\\" then dir = dir .. "\\" end
      end
    end
    f:close()
  end
  local name = os.getenv("COOP_NAME")
  if not name or name == "" then name = os.getenv("COOP_ROLE") end
  if name and name ~= "" then dir = dir .. (name:gsub("[^%w_%-]", "_")) .. "\\" end
  return dir
end
local function readAll(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local DIR = ioDir(DLL)

local fn = rawget(_G, "__coop_patch_probe_fn")
if not fn then
  local f, err, where = package.loadlib(DLL, "coop_patch_tick")
  if not f then return "loadlib failed: " .. tostring(err) .. " / " .. tostring(where) end
  fn = f; _G.__coop_patch_probe_fn = f
  out("loaded; first tick (scan) ->", pcall(fn))      -- the first tick skips older lines, so it must come before the command
end

local c = io.open(DIR .. "patch_cmd.txt", "ab"); c:write("NOKILL ON\n"); c:close()
out("tick ->", pcall(fn))

out("---- patch_status.txt")
for line in (readAll(DIR .. "patch_status.txt") or "(missing)"):gmatch("[^\r\n]+") do out(line) end
out("---- last lines of coop_patch.log")
local lines = {}
for line in (readAll(DIR .. "coop_patch.log") or ""):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
for i = math.max(1, #lines - 6), #lines do out(lines[i]) end
return "step2 done: expect 'P1 on'. Undo with probe_patch_step2_off.lua"
