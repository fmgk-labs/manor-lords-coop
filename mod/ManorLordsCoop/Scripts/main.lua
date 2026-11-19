-- Manor Lords Co-op: mod entry point (loaded by UE4SS at game start).
-- It only reads the config, loads the core and its modules, and starts the single driver.
-- No game work happens here: this file runs before any world exists, on the mod loader's start-up thread.

-- this mod's folder, from this file's own path (.../Mods/ManorLordsCoop/Scripts/main.lua)
local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local scripts = here:match("^(.*)/[^/]*$") or "."
local modDir = scripts:match("^(.*)/[^/]*$") or "."

-- config: <mod folder>/coop.cfg, lines "key = value". Nobody has to set a role there: without one the mod starts idle
-- (it changes nothing) and becomes host or friend from the co-op menu or a Steam invite. "role = disabled" switches the
-- mod off completely; "role = host" or "role = friend" force a role (development with two copies on one PC).
local cfg = { role = "idle", name = "", friends = "friend1,friend2,friend3,friend4,friend5,friend6,friend7" }
local f = io.open(modDir .. "/coop.cfg", "r")
if f then
  for line in f:lines() do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k and not line:match("^%s*#") then cfg[k] = v end
  end
  f:close()
end

-- environment variables win over the file (used when two copies of the game run on one PC during development)
cfg.role = os.getenv("COOP_ROLE") or cfg.role
cfg.name = os.getenv("COOP_NAME") or cfg.name
cfg.linkdir = os.getenv("COOP_LINKDIR") or cfg.linkdir

if cfg.role == "off" then cfg.role = "idle" end          -- older config files said "off"
if cfg.role == "disabled" then
  print("[ManorLordsCoop] off (set role = host or role = friend in coop.cfg)\n")
  return
end

local link = (cfg.linkdir and cfg.linkdir ~= "") and cfg.linkdir:gsub("\\", "/") or (modDir .. "/link/")
if link:sub(-1) ~= "/" then link = link .. "/" end
_G.COOP_LINK_DIR = link

local function load(name)
  local chunk, err = loadfile(scripts .. "/" .. name)
  if not chunk then print("[ManorLordsCoop] cannot load " .. name .. ": " .. tostring(err) .. "\n"); return false end
  local ok, res = pcall(chunk)
  if not ok then print("[ManorLordsCoop] error in " .. name .. ": " .. tostring(res) .. "\n"); return false end
  return true
end

-- (lane 62) One co-op copy per install. A second copy of the game started from this install while the first still
-- runs would share the first copy's link folder, logs and Steam status (live: it took the first copy's place with
-- the host and starved it). coop_guard.lua finds a living first process (a lock file the first keeps open); then
-- nothing of the mod is loaded here but coop_second.lua, which only tells the player in the menu. Before the core:
-- nothing has written a file yet. Not for copies with a forced role or name (COOP_ROLE / COOP_NAME: the test harness
-- runs several copies from one test install on purpose), and not with "guard = off" in coop.cfg.
if load("coop_guard.lua") and _G.COOP_GUARD and _G.COOP_GUARD.check then
  local okG, eG = pcall(_G.COOP_GUARD.check, cfg.guard == "off")
  if not okG then print("[ManorLordsCoop] guard: " .. tostring(eG) .. " (the mod starts as usual)\n") end
  if okG and _G.COOP_GUARD.second then
    load("coop_second.lua")
    print("[ManorLordsCoop] Manor Lords is already running with co-op on this PC: the mod is off in this second copy (" .. tostring(_G.COOP_GUARD.state) .. ")\n")
    return
  end
end

if not load("coop.lua") then return end
-- optional modules: present in a full install, absent in a core-only test
-- coop_x_*.lua: actions added per area in their own files (they use the town module's api and load after it)
for _, m in ipairs({ "coop_town.lua", "coop_world.lua", "coop_join.lua", "coop_realm.lua", "coop_patch.lua", "coop_snap.lua", "coop_sites.lua", "coop_ui.lua", "coop_steam.lua", "coop_session.lua", "coop_focus.lua",
                     "coop_x_town.lua", "coop_x_build.lua", "coop_x_lord.lua", "coop_x_army.lua", "coop_x_men.lua", "coop_x_merch.lua", "coop_x_maint.lua", "coop_x_events.lua", "coop_x_people.lua", "coop_x_jobs.lua", "coop_facts.lua", "coop_x_scene.lua", "coop_x_panels.lua", "coop_dev.lua" }) do
  local t = io.open(scripts .. "/" .. m, "r")
  if t then t:close(); load(m) end
end
-- lane 72: the histories and per-copy values on the host's word (production tracker, time pie, expertise, prices,
-- squads' men); after the list above, as it uses coop_world.lua's keys and coop.lua's army functions
do local t = io.open(scripts .. "/coop_x_stats.lua", "r"); if t then t:close(); load("coop_x_stats.lua") end end

local peers = {}
if cfg.role ~= "friend" then for n in cfg.friends:gmatch("[^,%s]+") do peers[#peers + 1] = n end end
_G.COOP_FRIEND_NAMES = peers                                  -- the menu uses these when this copy becomes the host
local name = cfg.role == "host" and "host" or (cfg.role == "idle" and "idle" or (cfg.name ~= "" and cfg.name or "friend1"))
if _G.Coop.join then _G.Coop.join.auto = true end      -- a friend's hello starts a join by itself
local ok, res = pcall(_G.Coop.start, cfg.role, name, peers)
print("[ManorLordsCoop] " .. tostring(res) .. " (link folder " .. link .. ")\n")
