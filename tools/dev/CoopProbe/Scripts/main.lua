-- CoopProbe: local, file-based analysis REPL. Throwaway study tool, not part of the mod.
-- Reads io/cmd.lua, runs it on the game thread, writes io/out.txt. No network.
-- v2: the poll itself runs on the game thread (LoopInGameThreadWithDelay). The first version polled with
-- LoopAsync + ExecuteInGameThread, which is not thread-safe in this UE4SS build and took part in a crash.
-- the command folder sits beside this script's folder (io, or the name in COOP_IO for a second copy on one PC),
-- wherever this copy of the game is: tests run from separate copies of the game folder
local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local IO = (here:match("^(.*)/Scripts/[^/]*$") or ".") .. "/" .. (os.getenv("COOP_IO") or "io") .. "/"

local function write_result(text)
    local f = io.open(IO .. "out.tmp", "w")
    if not f then return end
    f:write(text)
    f:close()
    os.remove(IO .. "out.txt")
    os.rename(IO .. "out.tmp", IO .. "out.txt")
end

local function run(src)
    local lines = {}
    local env = setmetatable({
        out = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            lines[#lines + 1] = table.concat(parts, "\t")
        end,
    }, { __index = _G, __newindex = _G })
    local chunk, err = load(src, "cmd", "t", env)
    local ok, res
    if chunk then ok, res = pcall(chunk) else ok, res = false, err end
    lines[#lines + 1] = (ok and "OK: " or "ERR: ") .. tostring(res)
    write_result(table.concat(lines, "\n") .. "\n")
end

local function poll()
    local f = io.open(IO .. "cmd.lua", "r")
    if not f then return end
    local src = f:read("a")
    f:close()
    os.remove(IO .. "cmd.lua")
    local ok, err = pcall(run, src)
    if not ok then write_result("ERR(run): " .. tostring(err) .. "\n") end
end

local mode = "game-thread loop"
local ok = false
if LoopInGameThreadWithDelay then ok = pcall(LoopInGameThreadWithDelay, 150, poll) end
if not ok then
    -- fallback: the old, unsafe way, so the console still works on a UE4SS build without the game-thread loop
    mode = "ASYNC FALLBACK (unsafe)"
    local busy = false
    LoopAsync(300, function()
        if busy then return false end
        busy = true
        ExecuteInGameThread(function() pcall(poll); busy = false end)
        return false
    end)
end

print("[CoopProbe] ready, " .. mode .. "\n")
