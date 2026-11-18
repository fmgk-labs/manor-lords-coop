-- Manor Lords Co-op: ONE co-op copy per install (lane 62, 2026-11-17).
-- Live finding (a friend's report): a second copy of the game was started on a friend's PC while his first copy was in
-- a session. Both copies run from one install, so they share one mod folder and one link folder: the second copy
-- turned the idle log over, read the first copy's Steam status ("joined"), took the friend's role and said hello to the
-- host a minute later, and its loading starved the first copy.
-- This file is loaded by main.lua BEFORE the core and before anything of the mod writes a file. It answers one
-- question: does another living process of the game already run the co-op mod from this install?
--   _G.COOP_GUARD.second == true   yes: main.lua then loads nothing of the mod but coop_second.lua (one line in the menu)
--   otherwise                      this process is the first; it holds the lock for as long as it lives
-- HOW (Lua here has no process id and no mutex): the lock is the file <mod folder>/coop_run.lock, kept OPEN by the first
-- process for its whole life. Windows does not let a file be deleted while another process has it open this way, and
-- closes it by itself when that process ends, also after a crash. So a second process tries to delete the file:
--   deleted, or not there        nobody alive holds it: this process is the first (it makes the file and keeps it open)
--   cannot be deleted            a living process holds it, IF its heartbeat in the file is fresh (the holder rewrites
--                                the time every few seconds; under STALE seconds old). A file that cannot be deleted
--                                but has no fresh heartbeat (read-only, a scanner's handle, a holder that hangs) is
--                                not believed: the mod then starts as usual, without a lock. Never a false "already
--                                running" from a file that merely exists.
-- A second process writes nothing: its one try to delete either fails (nothing changed) or it is the first.
-- NOT guarded: a copy whose role or name is forced through the environment (COOP_ROLE / COOP_NAME: the test harness,
-- which runs a host and several friends from ONE test install on purpose), and "guard = off" in coop.cfg.
local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local scripts = here:match("^(.*)/[^/]*$") or "."
local modDir = scripts:match("^(.*)/[^/]*$") or "."

local G = { second = false, state = "not checked" }
_G.COOP_GUARD = G
G.path = modDir .. "/coop_run.lock"
G.stale = 300                 -- s: a heartbeat older than this is no living holder (a load can stop the game thread for minutes)
G.started = os.time()

local function readLock()
  local f = io.open(G.path, "rb"); if not f then return nil end
  local s = f:read(400); f:close()
  return s or ""
end

function G.check(off)
  if off then G.state = "off (guard = off in coop.cfg)"; return G end
  if os.getenv("COOP_ROLE") or os.getenv("COOP_NAME") then G.state = "off (the role or the name is forced through the environment: a test copy)"; return G end
  local had = readLock()
  if had ~= nil and not os.remove(G.path) then
    local beat = tonumber(had:match("beat (%d+)"))
    if beat and os.time() - beat < G.stale and os.time() - beat > -60 then
      G.second = true
      G.state = "second: another living process holds " .. G.path .. " (its heartbeat is " .. (os.time() - beat) .. " s old)"
      G.holder = { started = tonumber(had:match("started (%d+)")), pid = tonumber(had:match("pid (%d+)")) }
      return G
    end
    G.state = "unguarded: the lock file cannot be deleted but has no fresh heartbeat (not believed)"
    return G
  end
  local f = io.open(G.path, "wb")
  if not f then G.state = "unguarded: the lock file could not be made"; return G end
  G.f = f
  G.state = "first: this process holds the lock"
  G.beat()
  return G
end

-- the holder's heartbeat (the core calls it every few seconds; with the process id once the native piece told it).
-- One fixed-length record, written over itself.
function G.beat(pid)
  local f = G.f; if not f then return false end
  if pid then G.pid = tonumber(pid) end
  local ok = pcall(function()
    f:seek("set", 0)
    f:write(string.format("Manor Lords Co-op: this install runs in a living process\nbeat %-12d\nstarted %-12d\npid %-10s\n", os.time(), G.started, tostring(G.pid or "?")))
    f:flush()
  end)
  return ok
end

return G
