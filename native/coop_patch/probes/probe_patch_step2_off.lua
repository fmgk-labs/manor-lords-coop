-- probe_patch_step2_off.lua - NOKILL OFF: puts back the 2 original bytes of P1 ("74 1C") on THIS copy.
-- CONFIRMED if the status below reads "P1 off" and the log shows "P1 off at <address>" (or "P1 already off").
-- Closing the game also undoes it (the patch lives only in this process's memory; the game file is never changed).
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
if not fn then return "the DLL is not loaded in this copy (nothing was patched by the probes): run step1 first" end

local c = io.open(DIR .. "patch_cmd.txt", "ab"); c:write("NOKILL OFF\n"); c:close()
out("tick ->", pcall(fn))

out("---- patch_status.txt")
for line in (readAll(DIR .. "patch_status.txt") or "(missing)"):gmatch("[^\r\n]+") do out(line) end
out("---- last lines of coop_patch.log")
local lines = {}
for line in (readAll(DIR .. "coop_patch.log") or ""):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
for i = math.max(1, #lines - 4), #lines do out(lines[i]) end
return "step2_off done: expect 'P1 off'"
