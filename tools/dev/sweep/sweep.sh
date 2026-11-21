# Parity sweep (lane 68): what every panel DRAWS, on the host and on the friend, at one paused moment, compared.
#   [LANE=n] sh tools/dev/sweep/sweep.sh <label> [only] [screens]
#     label    a name for this sweep: the files are $RUN/sweep_<label>_host.txt, _friend.txt, _diff.txt, _diff.tsv
#     only     "" (every building of the player) or a comma list of building types and / or keys (type@x,y): a smoke test
#     screens  1 = also the screens (main tabs, each owned region's panel, the development panel, the map); default 0
# Needs a running host and friend of this lane (tools/dev/up.sh). Pauses the game through the host as
# tools/dev/statediff.sh does, waits 6 s (the friend follows the host's pause; the facts module writes exactly while
# paused), starts the probe on both copies, waits until both are done, then runs the diff. It leaves the game paused.
# Dumps hold every text the panels show, also lord and player names: they stay in $RUN (.devrun, not in git).
. "$(dirname "$0")/../np.sh"
SW="$DEV/sweep"
L="${1:-now}"; ONLY_ARG="${2:-}"; SCR="${3:-0}"
H="$RUN/sweep_${L}_host.txt"; F="$RUN/sweep_${L}_friend.txt"

# what was sent before (a sweep must not send a town action or cause a resync)
# (one number always: grep -c prints "0" AND fails when nothing matches, so "|| echo 0" printed "0" twice: the first
#  in-game run stopped on it, lane 71 run e1)
num() { local n; n=$(printf '%s' "$1" | tr -cd '0-9\n' | head -1); echo "${n:-0}"; }
tcount() { num "$(grep -c "TOWN sent" "$1" 2>/dev/null)"; }
TH0=$(tcount "$LK/host_log.txt"); TF0=$(tcount "$LK/friend1_log.txt"); R0=$(num "$(repairs)")

lua host 'lord:pauseGame(); return "paused"' > /dev/null; /usr/bin/sleep 6
PH=$(lua host 'return (lord.bIsPlayerPaused and eng.gameSpeed < 0.01) and "paused" or ("running " .. tostring(eng.gameSpeed))' | sed 's/OK: //')
PF=$(lua friend 'return (lord.bIsPlayerPaused and eng.gameSpeed < 0.01) and "paused" or ("running " .. tostring(eng.gameSpeed))' | sed 's/OK: //')
echo "host: $PH   friend: $PF"
case "$PH$PF" in *running*|*TIMEOUT*|*ERR*) echo "NOT PAUSED on both copies: no sweep"; exit 3;; esac

# (lane 81) the owner's real pointer, read only: where it is, and whether it is inside a test window of this lane
pointer() { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$SW/pointer.ps1")" -Pids "$(tr -d '\r' < "$RUN/host.pid" 2>/dev/null),$(tr -d '\r' < "$RUN/friend.pid" 2>/dev/null)" 2>&1 | tr -d '\r' | tail -1; }
echo "pointer at the start: $(pointer)"
# (lane 81) both copies' cameras on the host's place before the sweep (a pointer at a window's edge can have
# scrolled one of them to the map's edge): the probe puts its lord there (SW_CAM)
CAM=$(lua host 'local l = lord:K2_GetActorLocation(); return string.format("%.1f,%.1f,%.1f", l.X, l.Y, l.Z)' | sed 's/OK: //' | tr -d '\r')
case "$CAM" in *,*,*) ;; *) CAM="";; esac
echo "camera of both copies: ${CAM:-not read}"
hdr() { # hdr <cmd> <out file> -> $RUN/_sw_<cmd>.lua (the probe with its header)
  { printf 'SW_CMD = "%s"\nSW_DIR = [[%s\\]]\nSW_OUT = [[%s]]\nSW_ONLY = "%s"\nSW_SCREENS = "%s"\nSW_CAM = "%s"\n' "$1" "$(cygpath -w "$SW")" "$(cygpath -w "$2")" "$ONLY_ARG" "$SCR" "$CAM"
    cat "$SW/sweep_probe.lua"; } > "$RUN/_sw_$1_$3.lua"; }
hdr start "$H" h; hdr start "$F" f; hdr status "$H" h; hdr status "$F" f
echo "host:   $(np "$RUN/_sw_start_h.lua" 30 | tail -1 | cut -c1-160)"
echo "friend: $(np2 "$RUN/_sw_start_f.lua" 30 | tail -1 | cut -c1-160)"

t0=$(date +%s)
while :; do
  SH=$(np "$RUN/_sw_status_h.lua" 20 | tail -1); SF=$(np2 "$RUN/_sw_status_f.lua" 20 | tail -1)
  case "$SH" in *": done job"*|*": aborted job"*|*idle*) DH=1;; *) DH=0;; esac   # the first word only: a job's own phase can read "done" too
  case "$SF" in *": done job"*|*": aborted job"*|*idle*) DF=1;; *) DF=0;; esac
  [ $DH = 1 ] && [ $DF = 1 ] && break
  if [ $(( $(date +%s) - t0 )) -gt ${SWEEP_MAX:-1800} ]; then echo "sweep still running after ${SWEEP_MAX:-1800} s: stopping it"; break; fi
  /usr/bin/sleep 5
done
echo "host:   $(echo "$SH" | cut -c1-160)"; echo "friend: $(echo "$SF" | cut -c1-160)"
if [ $DH = 0 ] || [ $DF = 0 ]; then
  printf 'SW_CMD = "stop"\n' > "$RUN/_sw_stop.lua"; cat "$SW/sweep_probe.lua" >> "$RUN/_sw_stop.lua"
  np "$RUN/_sw_stop.lua" 20 > /dev/null; np2 "$RUN/_sw_stop.lua" 20 > /dev/null
fi

TH1=$(tcount "$LK/host_log.txt"); TF1=$(tcount "$LK/friend1_log.txt"); R1=$(num "$(repairs)")
echo "town lines sent during the sweep: host $((TH1 - TH0)), friend $((TF1 - TF0)); resyncs $((R1 - R0)) (all three must be 0)"
# name them (a later up.sh replaces these logs: the first run, 2026-11-18, lost the host's 3 lines that way)
[ $((TH1 - TH0)) -gt 0 ] && grep "TOWN sent" "$LK/host_log.txt" | tail -$((TH1 - TH0)) | cut -c1-220 | tee "$RUN/sweep_${L}_townlines.txt"
[ $((TF1 - TF0)) -gt 0 ] && grep "TOWN sent" "$LK/friend1_log.txt" | tail -$((TF1 - TF0)) | cut -c1-220 | tee -a "$RUN/sweep_${L}_townlines.txt"
py -I "$(cygpath -w "$SW/sweep_diff.py")" "$(cygpath -w "$H")" "$(cygpath -w "$F")" --out "$(cygpath -w "$RUN/sweep_${L}_diff.tsv")" --soft "$(cygpath -w "$SW/soft.txt")" >"$RUN/sweep_${L}_diff.txt"
head -60 "$RUN/sweep_${L}_diff.txt"
echo "full: $RUN/sweep_${L}_diff.txt (report), $RUN/sweep_${L}_diff.tsv (every difference), the two dumps beside them"
