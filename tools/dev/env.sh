# Shared paths and helpers for tests. Source it:  . tools/dev/env.sh      (set LANE=1..9 first for a parallel lane)
# Tests run from a SEPARATE COPY of the game, never from the real install: the real folder keeps the released zip,
# so the user can host at any time while tests run. Each lane has its own game copy, save profile and window places.
# This PC's paths come from tools/dev/local.env (git-ignored; see local.env.example and README.md "First-time setup").
REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
[ -f "$REPO/tools/dev/env.sh" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
# no local.env: stop here, and stop the script that sourced this file too (never run on with empty paths)
{ [ -f "$REPO/tools/dev/local_env.sh" ] && . "$REPO/tools/dev/local_env.sh"; } || { echo "env.sh: stopped (no paths for this PC)" >&2; case $- in *i*) return 1;; *) exit 1;; esac; }
MAIN="$(cygpath -u "$ML_REPO")"                                                # the main checkout (built native DLLs live here)
LANEF="$REPO/.devrun/lane"
LANE="${LANE:-$(cat "$LANEF" 2>/dev/null || echo 0)}"                          # up.sh remembers the lane of this checkout
# the test copies: $ML_TEST_ROOT/_ml_test (lane 0, the lead's) and $ML_TEST_ROOT/_ml_test_<LANE>
if [ "$LANE" = "0" ]; then TROOT="$(cygpath -u "$ML_TEST_ROOT")/_ml_test"; SUFFIX="Coop"; RESX=960; RESY=540
else TROOT="$(cygpath -u "$ML_TEST_ROOT")/_ml_test_$LANE"; SUFFIX="CoopL$LANE"; RESX=640; RESY=360; fi
TG="$TROOT/ManorLords/Binaries/Win64"                                          # this lane's test copy
SAVES="$(cygpath -u "$LOCALAPPDATA")/ManorLords/Saved_$SUFFIX"       # this lane's save profile (never the real "Saved")
LK="$TG/ue4ss/Mods/ManorLordsCoop/link"
PROBE="$TG/ue4ss/Mods/CoopProbe"
# this lane's run folder: pid files, the start token "gen" and scratch Lua (git-ignored). One per lane, so two runs
# started from the same checkout on different lanes never read, close or free each other's copies (2026-11-17: one
# run's "close the friend" step closed the other run's friend when both used .devrun/friend.pid)
RUN="$REPO/.devrun/lane$LANE"; mkdir -p "$RUN"
DEV="$REPO/tools/dev"
# window places on the right monitor: two per lane, three per row
wx() { echo $(( 1920 + ( (LANE * 2 + $1) % 3 ) * 640 )); }
wy() { echo $(( 30 + ( (LANE * 2 + $1) / 3 ) * 200 )); }

# pids of the copies THIS lane started (never kill by image name: the user may be playing)
pid() { cat "$RUN/$1.pid" 2>/dev/null; }
HP=$(pid host); FP=$(pid friend)

# ---- game slots: all lanes together may run only a few copies at once (memory). Every copy needs a slot; the lanes
# queue first come, first served. The number of slots is in $SLOTS/count (the lead changes it), default 4. The owner
# set it to 4 on 2026-11-13: at most two tests (4 game copies) at once; a test with more copies needs his word.
SLOTS="$(cygpath -u "$ML_SLOTS")"; mkdir -p "$SLOTS/q"                          # shared by every checkout on this PC
nslot() { cat "$SLOTS/count" 2>/dev/null || echo 4; }
myslots() { grep -lF "|$RUN|" "$SLOTS"/s*/who 2>/dev/null; }
freeslots() { for w in $(myslots); do rm -rf "$(dirname "$w")"; done; }
alive() { tasklist //FI "PID eq $1" //NH 2>/dev/null | grep -q " $1 "; }
# a slot whose lane has no living copy for 8 minutes is given back (a helper that stopped without "down")
reclaim() { local w l r p ok d
  for w in $(find "$SLOTS" -maxdepth 2 -name who -mmin +8 2>/dev/null); do
    IFS='|' read -r l r _ < "$w"; ok=0
    for p in $(cat "$r"/*.pid 2>/dev/null | tr -d '\r'); do alive "$p" && ok=1; done
    [ $ok -eq 0 ] && rm -rf "$(dirname "$w")"
  done
  for d in $(find "$SLOTS" -mindepth 1 -maxdepth 1 -name 's[0-9]*' -type d -mmin +8 2>/dev/null); do [ -f "$d/who" ] || rm -rf "$d"; done; }
# take <copies>: waits up to $WAIT seconds (default 240) for that many slots; returns 3 when the PC stays busy
take() { local want=$1 t0=$(date +%s) tk c got i
  tk="$SLOTS/q/$(date +%s)_$LANE"; [ "$LANE" = "0" ] && tk="$SLOTS/q/0000000000_0"; : > "$tk"      # the lead (lane 0) goes first: the user's live session depends on it
  while :; do
    touch "$tk"; find "$SLOTS/q" -type f -mmin +2 -delete 2>/dev/null; reclaim
    # (2026-11-13, the owner: at most two tests, 4 game copies, at once) every held slot counts, also one with a number
    # above the limit that was taken before the limit went down: a start waits until held + wanted fits
    if [ "$(ls "$SLOTS/q" | sort | head -1)" = "$(basename "$tk")" ] && [ $(( $(ls -d "$SLOTS"/s*/ 2>/dev/null | wc -l) + want )) -le $(nslot) ]; then
      got=""; c=0
      for i in $(seq 1 $(nslot)); do
        [ $c -ge $want ] && break
        if mkdir "$SLOTS/s$i" 2>/dev/null; then printf '%s|%s|\n' "$LANE" "$RUN" > "$SLOTS/s$i/who"; got="$got $i"; c=$((c+1)); fi
      done
      [ $c -ge $want ] && { rm -f "$tk"; return 0; }
      for i in $got; do rm -rf "$SLOTS/s$i"; done
    fi
    if [ $(( $(date +%s) - t0 )) -ge ${WAIT:-240} ]; then
      rm -f "$tk"; echo "BUSY: no free game slot after ${WAIT:-240} s (held by lanes: $(cat "$SLOTS"/s*/who 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')). Do desk work and try again, or start up.sh in the background with WAIT=3600"; return 3
    fi
    /usr/bin/sleep 8
  done; }
# down closes the copies whose pid files are in THIS lane's run folder ($RUN), and gives back this lane's slots.
# down also (1) changes the token in $RUN/gen, which makes a start script that is still running stop starting copies,
# and (2) stops every copy that runs from THIS lane's test folder, pid file or not. Why (2026-11-12): a start script
# that was cut off went on in the background and started three more friends under the same names; no pid file knew
# them, they joined the next two runs as doubles, and both runs were worthless. Only a test folder is ever touched:
# the path must hold "_ml_test", so the real install and other lanes' copies are out of reach.
down() { for f in "$RUN"/*.pid; do [ -f "$f" ] && taskkill //PID $(tr -d '\r' < "$f") //F > /dev/null 2>&1; done; rm -f "$RUN"/*.pid
  echo "down_$(date +%s)_$$" > "$RUN/gen"
  case "$TG" in *_ml_test*) powershell -NoProfile -Command "\$e = '$(cygpath -w "$TG/ManorLords-Win64-Shipping.exe")'; Get-CimInstance Win32_Process -Filter \"Name='ManorLords-Win64-Shipping.exe'\" | Where-Object { \$_.ExecutablePath -eq \$e } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" > /dev/null 2>&1;; esac
  freeslots; /usr/bin/sleep 4; }
# copies running from this lane's test folder right now (for a run's own check that it has no doubles)
copies() { powershell -NoProfile -Command "\$e = '$(cygpath -w "$TG/ManorLords-Win64-Shipping.exe")'; @(Get-CimInstance Win32_Process -Filter \"Name='ManorLords-Win64-Shipping.exe'\" | Where-Object { \$_.ExecutablePath -eq \$e }).Count" | tr -d '\r\n '; }

# run a Lua chunk in a copy's test console:  mlx <io folder name> <file> [timeout s]
mlx() {
  local IO="$PROBE/$1"; local T="${3:-20}"; rm -f "$IO/out.txt"
  cp "$2" "$IO/cmd.tmp" && mv "$IO/cmd.tmp" "$IO/cmd.lua"
  local t0=$EPOCHREALTIME                  # (lane 51) each console call's start, end and callers: $RUN/console_calls.txt
  local i=0; while [ ! -f "$IO/out.txt" ]; do i=$((i+1)); if [ "$i" -gt $((T*5)) ]; then echo "$t0 $EPOCHREALTIME $1 TIMEOUT ${FUNCNAME[*]:1:5}" >> "$RUN/console_calls.txt"; echo "TIMEOUT (no answer after ${T}s)"; return 2; fi; /usr/bin/sleep 0.2; done
  echo "$t0 $EPOCHREALTIME $1 ok ${FUNCNAME[*]:1:5}" >> "$RUN/console_calls.txt"
  cat "$IO/out.txt"
}
# with the helper library in front:  np <file> (host)   np2 <file> (friend)   on <host|friend> <file>
np()  { cat "$DEV/lua/lib.lua" "$1" > "$RUN/_np.lua";  mlx io  "$RUN/_np.lua"  "${2:-20}"; }
np2() { cat "$DEV/lua/lib.lua" "$1" > "$RUN/_np2.lua"; mlx io2 "$RUN/_np2.lua" "${2:-20}"; }
on()  { if [ "$1" = "friend" ]; then np2 "$2" "${3:-20}"; else np "$2" "${3:-20}"; fi; }
# one-liner Lua with the library:  lua <host|friend> '<lua code that returns a string>'
lua() { printf '%s\n' "$2" > "$RUN/_lua.lua"; on "$1" "$RUN/_lua.lua" "${3:-15}"; }

# background screenshot of a copy's window (works without focus):  shot <pid> <name.png>  -> $RUN/<name.png>
shot() { powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$DEV/shot.ps1")" -ProcId "$1" -Out "$(cygpath -w "$RUN/$2")" > /dev/null; }

# the last town lines of both logs, and the number of resyncs so far
tsent() { echo "  host log:   $(grep "TOWN sent\|TOWN APPLIED\|TOWN FAILED" "$LK/host_log.txt" | tail -${1:-1} | cut -c16-130 | tr '\n' ';')"; echo "  friend log: $(grep "TOWN sent\|TOWN APPLIED\|TOWN FAILED\|refus" "$LK/friend1_log.txt" | tail -${1:-1} | cut -c16-130 | tr '\n' ';')"; }
repairs() { grep -c "asks for a repair" "$LK/host_log.txt" 2>/dev/null; }
