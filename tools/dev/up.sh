# Build this checkout as a TEST build, install it into this lane's test copy of the game (with the test console), start
# a host and a friend in small muted windows on the right monitor WITHOUT touching the mouse or keyboard, load a save,
# wait for the join.
#   [LANE=n] sh tools/dev/up.sh [save name, default coop_test_1] ["friend env", for example "COOP_TEST_REPAIR=75"]
. "$(dirname "$0")/env.sh"
SAVE="${1:-coop_test_1}"; FENV="${2:-}"
cd "$REPO"
[ -d "$TG" ] || { echo "no test copy at $TG: run  LANE=$LANE sh tools/dev/lane_setup.sh  first"; exit 1; }
down; echo "$LANE" > "$LANEF"                                       # this checkout's lane, for later shells (env.sh)
# this start owns the token until the next "down" (env.sh): a start that lost it starts no further copy
GEN="up_$$_$(date +%s)"; echo "$GEN" > "$RUN/gen"
mine() { [ "$(cat "$RUN/gen" 2>/dev/null)" = "$GEN" ] || { echo "another start or a down took over: this start stops here"; exit 4; }; }
# the native DLLs are build outputs (not in git): a fresh worktree takes them from the main checkout
for d in coop_patch coop_steam; do [ -f "native/$d/out/$d.dll" ] || { mkdir -p "native/$d/out"; cp "$MAIN/native/$d/out/$d.dll" "native/$d/out/"; }; done
# (lead, 2026-11-21) the copied DLL can be old (the main checkout's): the patch DLL must carry this checkout's version, else it is built
VSRC=$(grep -o 'COOP_PATCH_VERSION "[0-9.]*"' native/coop_patch/coop_patch.c | cut -d'"' -f2)
grep -a -q "$VSRC" native/coop_patch/out/coop_patch.dll || { echo "native coop_patch.dll is not $VSRC: building it"; (cd native/coop_patch && cmd //c ".\build.cmd" > /dev/null 2>&1); grep -a -q "$VSRC" native/coop_patch/out/coop_patch.dll || { echo "NATIVE DLL IS NOT $VSRC: stop"; exit 1; }; }
V=$(grep '^C.version = ' mod/ManorLordsCoop/Scripts/coop.lua | cut -d'"' -f2 | head -1)
powershell -NoProfile -ExecutionPolicy Bypass -File tools/package.ps1 -Dist 'dist\test' 2>&1 | head -1
[ -s "dist/test/ManorLordsCoop-$V.zip" ] || { echo "NO ZIP BUILT"; exit 1; }
rm -rf "$TG/ue4ss"; (cd "$TG" && unzip -o -q "$REPO/dist/test/ManorLordsCoop-$V.zip" 2>&1 | grep -v backslashes | head -2)
mkdir -p "$PROBE/Scripts" "$PROBE/io" "$PROBE/io2"; cp "$DEV/CoopProbe/Scripts/main.lua" "$PROBE/Scripts/"
printf 'CoopProbe : 1\n' > "$TG/ue4ss/Mods/mods.txt"; printf '[\n    {\n        "mod_name": "CoopProbe",\n        "mod_enabled": true\n    }\n]\n' > "$TG/ue4ss/Mods/mods.json"
# LOADER_ZIP=<zip>: another build of the mod loader is put over ours, whole (its dwmapi.dll, UE4SS.dll, settings, its own
# mods and its list of them), as a player has it who took the loader from its Nexus page; the test console is added
# to that list. The zip is only unpacked; nothing from it is run by this script.
if [ -n "${LOADER_ZIP:-}" ]; then
  [ -s "$LOADER_ZIP" ] || { echo "LOADER_ZIP not found: $LOADER_ZIP"; exit 1; }
  (cd "$TG" && unzip -o -q "$LOADER_ZIP") || { echo "LOADER_ZIP could not be unpacked"; exit 1; }
  printf '
CoopProbe : 1
' >> "$TG/ue4ss/Mods/mods.txt"
  py -c "import json,io,sys; p=sys.argv[1]; d=json.load(io.open(p,encoding='utf-8-sig')); d=[m for m in d if m.get('mod_name')!='CoopProbe']+[{'mod_name':'CoopProbe','mod_enabled':True}]; json.dump(d,io.open(p,'w',encoding='utf-8'),indent=4)" "$(cygpath -w "$TG/ue4ss/Mods/mods.json")"
  echo "LOADER_ZIP: loader replaced by $(basename "$LOADER_ZIP"); mods.txt: $(grep -c ' : 1' "$TG/ue4ss/Mods/mods.txt") mods on"
fi
# NOMOD=1: the co-op mod is installed but not loaded (a control run of the plain game; the test console still works).
# The waits for the mod's log lines below then run out by themselves (about 4 minutes in all).
[ -n "${NOMOD:-}" ] && rm -f "$TG/ue4ss/Mods/ManorLordsCoop/enabled.txt" && echo "NOMOD: the co-op mod is not loaded in this copy"
# CRUMBS=1: the mod's test switch link/dev_crumbs.txt is set, so each copy's log names every step of its first three
# ticks after a world attaches (to find the step a copy dies in)
[ -n "${CRUMBS:-}" ] && mkdir -p "$TG/ue4ss/Mods/ManorLordsCoop/link" && : > "$TG/ue4ss/Mods/ManorLordsCoop/link/dev_crumbs.txt" && echo "CRUMBS: step lines on"
EXE="$(cygpath -w "$TG/ManorLords-Win64-Shipping.exe")"
# several lanes share this PC with the user's own programs: a copy is started only when enough memory is free
waitmem() { local n=0; while :; do local f=$(powershell -NoProfile -Command "[int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB)"); [ "${f:-0}" -ge 7 ] && return 0; n=$((n+1)); for w in $(myslots); do touch "$w"; done; [ $n -gt 120 ] && { echo "still under 7 GB free after 30 minutes: not starting"; return 1; }; [ $((n % 8)) -eq 1 ] && echo "waiting for memory (${f} GB free, 7 needed)"; /usr/bin/sleep 15; done; }
start() { mine; waitmem || { down; exit 1; }; mine; powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$DEV/start.ps1")" -Exe "$EXE" -Suffix "$SUFFIX" -Role "$1" -Name "$2" -Io "$3" -WinX "$(wx $4)" -WinY "$(wy $4)" -ResX $RESX -ResY $RESY -PidFile "$(cygpath -w "$RUN/$1.pid")" -Extra "$5"; }
take $([ "${ONLY:-}" = "host" ] && echo 1 || echo 2) || exit 3        # one slot per copy; queued with the other lanes
start host host '' 0 ''
n=0; until [ -f "$LK/host_log.txt" ] && grep -q "Co-op button added\|started as host" "$LK/host_log.txt" || [ $n -ge 40 ]; do /usr/bin/sleep 3; n=$((n+1)); done; /usr/bin/sleep 20
cp "$TG/ue4ss/UE4SS.log" "$RUN/UE4SS_host.log"; echo "load errors: $(grep -c "ManorLordsCoop. error in\|ManorLordsCoop. cannot load" "$RUN/UE4SS_host.log")"; grep "ManorLordsCoop. error in\|ManorLordsCoop. cannot load" "$RUN/UE4SS_host.log" | cut -c1-300
printf 'local gi = FindFirstOf("MLGameInstance")\ngi.savefileToLoad = "%s"\nStaticFindObject("/Script/Engine.Default__GameplayStatics"):OpenLevel(gi, FName("Mission01_ROBBER"), true, "")\nreturn "loading %s"\n' "$SAVE" "$SAVE" > "$RUN/_load.lua"
mlx io "$RUN/_load.lua" 30
n=0; until grep -q "world 1 attached" "$LK/host_log.txt" 2>/dev/null || [ $n -ge 40 ]; do /usr/bin/sleep 3; n=$((n+1)); done; /usr/bin/sleep 8
echo "host: $(grep -h "started as\|world .* attached" "$LK/host_log.txt" 2>/dev/null | cut -c16-70 | tr '\n' ';')"
# (lane 81) edge scrolling off in every test copy: the owner's real pointer resting on (or last seen at) a test
# window's edge scrolled that copy's camera to the map's edge (lane_s21_81, the intermittent release-check failure).
# The game keeps the switch in its game instance (MLGameInstance.bEnableEdgeScrolling, set by SetEdgeScrolling); no
# test profile file holds it (rtsSettings.sav has no such key), so it is set at every start, after the copy answers.
printf 'local gi = FindFirstOf("MLGameInstance"); local ok = pcall(function() gi:SetEdgeScrolling(false) end)\nreturn "edge scrolling off: " .. tostring(ok) .. " " .. tostring(gi.bEnableEdgeScrolling)\n' > "$RUN/_edge.lua"
echo "host: $(mlx io "$RUN/_edge.lua" 15 | tail -1)"
[ "${ONLY:-}" = "host" ] && { echo "host only (ONLY=host)"; exit 0; }
start friend friend1 io2 1 "$FENV"
n=0; until grep -q "joined the game" "$LK/host_log.txt" 2>/dev/null || [ $n -ge 50 ]; do /usr/bin/sleep 3; n=$((n+1)); done; /usr/bin/sleep 6
grep -v "TOWN hook" "$LK/host_log.txt" | grep "join:\|notice" | tail -2 | cut -c16-120
# low graphics and a frame cap on both copies, so the lanes leave the PC usable
printf 'local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"); local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(FindFirstOf("RTSMultiEngineCPP").playerRef, 0)
for _, c in ipairs({ "t.MaxFPS 15", "sg.ShadowQuality 0", "sg.FoliageQuality 0", "sg.EffectsQuality 0", "sg.PostProcessQuality 0", "sg.GlobalIlluminationQuality 0", "sg.ReflectionQuality 0", "r.ScreenPercentage 60" }) do ksl:ExecuteConsoleCommand(pc, c, pc) end
return "low graphics"
' > "$RUN/_gfx.lua"
mlx io "$RUN/_gfx.lua" 15 > /dev/null; mlx io2 "$RUN/_gfx.lua" 15 > /dev/null
echo "friend: $(mlx io2 "$RUN/_edge.lua" 15 | tail -1)"            # (lane 81) edge scrolling off, see above
# FRIENDS=n (default 1): more friends on this PC: friend2 ... friendn, test consoles io3 ... (mlx io3 <file>), pid files
# friend2.pid ... Each join makes every copy load the host's save again. One slot per copy; the start waits for memory.
i=2; while [ $i -le ${FRIENDS:-1} ]; do
  mine; take 1 || break
  waitmem || break; mine
  mkdir -p "$PROBE/io$((i+1))"
  powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$DEV/start.ps1")" -Exe "$EXE" -Suffix "$SUFFIX" -Role friend -Name "friend$i" -Io "io$((i+1))" -WinX "$(wx $i)" -WinY "$(wy $i)" -ResX $RESX -ResY $RESY -PidFile "$(cygpath -w "$RUN/friend$i.pid")" -Extra ''
  n=0; until [ "$(grep -c "joined the game" "$LK/host_log.txt" 2>/dev/null)" -ge $i ] || [ $n -ge 70 ]; do /usr/bin/sleep 3; n=$((n+1)); done; /usr/bin/sleep 8
  mlx "io$((i+1))" "$RUN/_gfx.lua" 15 > /dev/null; mlx io "$RUN/_gfx.lua" 15 > /dev/null; mlx io2 "$RUN/_gfx.lua" 15 > /dev/null
  mlx "io$((i+1))" "$RUN/_edge.lua" 15 > /dev/null                 # (lane 81) edge scrolling off
  echo "friend$i: $(grep "joined the game" "$LK/host_log.txt" | tail -1 | cut -c16-90) ($(grep -c "joined the game" "$LK/host_log.txt") joins so far)"
  i=$((i+1))
done
