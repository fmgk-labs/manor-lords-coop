# Parity sweep as one release check (lane 68). Run it in the checkout of the release branch:
#   LANE=n sh tools/dev/sweep/release_check.sh [label] [saves]
#     label  default: the branch name and short commit (rel-0.2.5_12fc53b7)
#     saves  default: "coop_test_field coop_test_1" (each must be in the lane's save profile Saved_CoopL<n>)
# For each save: refuses when a copy of this lane's test folder already runs; up.sh (WAIT=3600 queues for slots);
# 30 s; sweep.sh <label>_<save> "" 1 (every building of the player, every tab, and the screens: each owned region,
# the main tabs, each squad's army panel and unit cards, the development tree with its trade view, the map); down.
# Then one summary: per save the panels compared, values read, HARD differences (fail), SOFT ones (tools/dev/sweep/
# soft.txt: known and accepted), town lines sent during the sweep, resyncs; the differing values by kind of widget.
# Written to $RUN/release_<label>.txt. Exit 0 = PASS (no hard difference, no town line, no resync, every sweep done).
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../np.sh" > /dev/null 2>&1
LBL="${1:-$(git rev-parse --abbrev-ref HEAD | tr '/' '_')_$(git rev-parse --short HEAD)}"
SAVES="${2:-coop_test_field coop_test_1}"
OUT="$RUN/release_${LBL}.txt"
: > "$OUT"
say() { echo "$*" | tee -a "$OUT"; }
num() { local n; n=$(printf '%s' "$1" | tr -cd '0-9\n' | head -1); echo "${n:-0}"; }
FAIL=0
say "RELEASE PARITY CHECK $LBL  build $(git rev-parse --short HEAD)  lane ${LANE:-0}  $(date '+%F %T')"
for s in $SAVES; do
  if [ "$(num "$(copies)")" != "0" ]; then say "$s: a copy of this lane's test folder is running: not started (FAIL)"; FAIL=1; continue; fi
  WAIT=${WAIT:-3600} sh "$DIR/../up.sh" "$s" > "$RUN/release_${LBL}_${s}_up.txt" 2>&1
  /usr/bin/sleep 30
  sh "$DIR/sweep.sh" "${LBL}_${s}" "" 1 > "$RUN/release_${LBL}_${s}_sweep.txt" 2>&1
  down > /dev/null 2>&1
  D="$RUN/sweep_${LBL}_${s}_diff.txt"
  SUM=$(grep "^SUMMARY" "$D" 2>/dev/null)
  TL=$(grep "^town lines sent" "$RUN/release_${LBL}_${s}_sweep.txt")
  TH=$(num "$(echo "$TL" | sed -n 's/.*host \([0-9]*\).*/\1/p')"); TF=$(num "$(echo "$TL" | sed -n 's/.*friend \([0-9]*\);.*/\1/p')"); RS=$(num "$(echo "$TL" | sed -n 's/.*resyncs \([0-9-]*\).*/\1/p')")
  HARD=$(num "$(echo "$SUM" | sed -n 's/.* hard=\([0-9]*\).*/\1/p')"); SOFT=$(num "$(echo "$SUM" | sed -n 's/.* soft=\([0-9]*\).*/\1/p')")
  WARN=$(num "$(echo "$SUM" | sed -n 's/.* warnings=\([0-9]*\).*/\1/p')")
  if [ -z "$SUM" ]; then say "$s: NO RESULT (see $RUN/release_${LBL}_${s}_sweep.txt)"; FAIL=1; continue; fi
  V="PASS"; { [ "$HARD" != 0 ] || [ "$TH" != 0 ] || [ "$TF" != 0 ] || [ "$RS" != 0 ]; } && { V="FAIL"; FAIL=1; }
  say ""
  say "== $s: $V   $SUM   town lines host $TH friend $TF   resyncs $RS   warnings $WARN"
  sed -n '/^BY KIND OF WIDGET/,/^$/p' "$D" | tee -a "$OUT"
  if [ "$HARD" != 0 ]; then
    say "  hard differences (panel | tab | widget | host / friend):"
    awk -F'\t' 'NR>1 && $7=="hard" {p=$3; sub(/.*\//,"",p); printf "    %s | %s | %s | %s / %s\n", $1, $2, p, substr($5,1,60), substr($6,1,60)}' "$RUN/sweep_${LBL}_${s}_diff.tsv" | head -60 | tee -a "$OUT"
  fi
  [ -s "$RUN/sweep_${LBL}_${s}_townlines.txt" ] && { say "  town lines:"; sed 's/^/    /' "$RUN/sweep_${LBL}_${s}_townlines.txt" | tee -a "$OUT"; }
  [ "$WARN" != 0 ] && { say "  warnings:"; sed -n '/^WARNINGS/,/^$/p' "$D" | tail -n +2 | head -20 | tee -a "$OUT"; }
done
say ""
if [ $FAIL = 0 ]; then say "RESULT: PASS"; else say "RESULT: FAIL"; fi
say "full reports: $RUN/sweep_${LBL}_<save>_diff.txt; this summary: $OUT"
exit $FAIL
