# The lead's guard for the moment the slot limit goes DOWN while tests run (2026-11-13: 6 -> 4, the owner's limit of
# two tests at once). Lanes whose env.sh is older take a slot whenever a number up to the limit is free, without
# counting slots held above the limit. Until those are gone this guard (1) puts a token in front of the queue so
# nobody starts, (2) takes one free slot number up to the limit for every slot still held above it (a placeholder, no
# game copy), then lets the queue go again; (3) gives a placeholder back when a slot above the limit is gone, and ends
# when none is left. So real game copies never exceed the limit once the running tests have shrunk to it.
#   sh tools/dev/slot_guard.sh        (in the background; ends by itself)
. "$(dirname "${BASH_SOURCE[0]:-$0}")/local_env.sh" || exit 1                 # this PC's paths (tools/dev/local.env)
SLOTS="$(cygpath -u "$ML_SLOTS")"; N=$(cat "$SLOTS/count" 2>/dev/null || echo 4)
TK="$SLOTS/q/0000000000"; PH="$SLOTS/guard_placeholders"; mkdir -p "$PH"
above() { n=0; for d in "$SLOTS"/s*/; do [ -d "$d" ] || continue; i=$(basename "$d" | tr -d 's'); [ "$i" -gt "$N" ] 2>/dev/null && n=$((n+1)); done; echo $n; }
mine() { ls "$PH" 2>/dev/null | wc -l; }
: > "$TK"
while :; do
  a=$(above); m=$(mine)
  # give placeholders back that are no longer needed
  while [ "$m" -gt "$a" ]; do f=$(ls "$PH" | head -1); rm -rf "$SLOTS/$f" "$PH/$f"; m=$(mine); done
  [ "$a" -eq 0 ] && break
  # take a free number up to the limit for every slot above it
  i=1; while [ "$m" -lt "$a" ] && [ $i -le "$N" ]; do
    if mkdir "$SLOTS/s$i" 2>/dev/null; then printf 'guard|%s|\n' "$PH" > "$SLOTS/s$i/who"; : > "$PH/s$i"; m=$(mine); fi
    i=$((i+1))
  done
  for f in $(ls "$PH" 2>/dev/null); do touch "$SLOTS/$f/who" 2>/dev/null; done      # never reclaimed as stale
  if [ "$m" -ge "$a" ]; then rm -f "$TK"; else touch "$TK" 2>/dev/null || : > "$TK"; fi
  /usr/bin/sleep 2
done
rm -f "$TK"; rmdir "$PH" 2>/dev/null
echo "slot guard: no slot above the limit of $N is left; ended $(date '+%H:%M:%S')"
