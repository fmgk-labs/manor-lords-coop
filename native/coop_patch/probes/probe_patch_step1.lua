-- probe_patch_step1.lua - load coop_patch.dll, let it scan, print its status. WRITES NOTHING into game memory.
-- What it tests: package.loadlib of our own DLL; the in-memory scan of the running game finds every signature exactly
-- once (the offline check of the game FILE already passed: README.md); the status/command files work.
-- Run it on ONE copy with a world loaded (the helper library needs one). Expect a short hitch (~0.2 s) on the first
-- run: the scan. Run with "native = off" in coop.cfg (the default), so the mod does not load a second copy of the DLL.
-- Two copies on one PC: both would use the same files in out\ unless COOP_NAME (or, without it, COOP_ROLE) differs
-- between them (then each gets out\<that name>\). Without either variable, run the probes on one copy only.
-- CONFIRMED if the status printed below reads:
--   ready 6836C1BA 9DFD000
--   P1 off / P2 off / P3a off / P3b off
--   ROUT available / REFORM available
--   calls rout=0 reform=0 failed=0
-- Anything "unavailable" or "off <reason>": copy the output and the log lines; nothing was patched.
-- the DLL of YOUR checkout: edit the path below, or start the game with COOP_PATCH_DLL set to it
local DLL = os.getenv("COOP_PATCH_DLL") or [[C:\path\to\checkout\native\coop_patch\out\coop_patch.dll]]
if DLL:find([[\path\to\checkout\]], 1, true) then return "set DLL at the top of this probe (or COOP_PATCH_DLL) to your checkout's native\\coop_patch\\out\\coop_patch.dll" end

-- same folder rule as the DLL: its folder, or coop_patch.cfg "dir=", plus a <COOP_NAME> (else <COOP_ROLE>) subfolder when set
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
out("dll", DLL)
out("files in", DIR)

local fn = rawget(_G, "__coop_patch_probe_fn")
if not fn then
  local f, err, where = package.loadlib(DLL, "coop_patch_tick")
  if not f then return "loadlib failed: " .. tostring(err) .. " / " .. tostring(where) end
  fn = f; _G.__coop_patch_probe_fn = f
  out("loaded; first tick (scan) ->", pcall(fn))
else
  out("already loaded in this process")
end

local c = io.open(DIR .. "patch_cmd.txt", "ab"); c:write("STATUS\n"); c:close()
out("tick ->", pcall(fn))

out("---- patch_status.txt")
for line in (readAll(DIR .. "patch_status.txt") or "(missing)"):gmatch("[^\r\n]+") do out(line) end
out("---- last lines of coop_patch.log")
local lines = {}
for line in (readAll(DIR .. "coop_patch.log") or ""):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
for i = math.max(1, #lines - 18), #lines do out(lines[i]) end
return "step1 done (read only): expect 'ready 6836C1BA 9DFD000', P1..P3b off, ROUT and REFORM available"
