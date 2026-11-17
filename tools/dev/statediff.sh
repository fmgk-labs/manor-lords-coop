# Value-by-value comparison of the two test copies of this lane (host and friend).
#   [LANE=n] sh tools/dev/statediff.sh [label]
# Pauses the game through the host, lets the friend follow, writes every simple value of the engine, the lord, the
# regions, the families with their members and the buildings on both copies, and prints what differs, grouped by
# property. Full lists: .devrun/lane<N>/state_<label>_host.txt, _friend.txt, _diff.txt ($RUN)
. "$(dirname "$0")/np.sh"
L="${1:-now}"
WAS=$(lua host 'return (lord.bIsPlayerPaused and eng.gameSpeed < 0.01) and "paused" or string.format("%.2f", eng.gameSpeed)' | sed 's/OK: //')
lua host 'lord:pauseGame(); return "paused"' > /dev/null; /usr/bin/sleep 3
H="$RUN/state_${L}_host.txt"; F="$RUN/state_${L}_friend.txt"
printf 'OUT_PATH = [[%s]]\n' "$(cygpath -w "$H")" > "$RUN/_sh.lua"; cat "$DEV/lua/t_state.lua" >> "$RUN/_sh.lua"
printf 'OUT_PATH = [[%s]]\n' "$(cygpath -w "$F")" > "$RUN/_sf.lua"; cat "$DEV/lua/t_state.lua" >> "$RUN/_sf.lua"
echo "host:   $(np "$RUN/_sh.lua" 120 | cut -c1-110)"
echo "friend: $(np2 "$RUN/_sf.lua" 120 | cut -c1-110)"
py - "$H" "$F" "$RUN/state_${L}_diff.txt" <<'PY'
import sys, io, collections
def load(p):
    d = {}
    for line in io.open(p, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        k, _, v = line.partition("=")
        d[k] = v
    return d
h, f = load(sys.argv[1]), load(sys.argv[2])
keys = sorted(set(h) | set(f))
def group(k):
    obj = k.split("|")[0]
    if obj.startswith("Bp "): return "building (player)"
    if obj.startswith("Bo "): return "building (others)"
    if " M" in obj and obj.startswith("R "): return "villager"
    if " F" in obj and obj.startswith("R "): return "family"
    if obj.startswith("R "): return "region"
    return obj.lower()
tot = collections.Counter(); dif = collections.Counter(); byprop = collections.defaultdict(list); only = collections.Counter(); ign = collections.Counter()
# not game facts: the game's own work caches, timer handles, camera and debug values, this copy's own log
IGNORE = ('unitCache_', 'resourceSurplusCache', 'Handle', 'camera_', 'zoomLevel', 'smoothZoomLevel', 'lastZoomLevelProximityCacheUpdate', 'debugLog', 'shouldUpdateDebugLog', 'drawDebugFlags', 'chosenVoiceLineVariation', 'everChangedGameSpeed', 'spatialGridIndex')
def ignored(g, prop): return any(x in prop for x in IGNORE) or (g == 'lord' and prop == 'log')
out = io.open(sys.argv[3], "w", encoding="utf-8")
for k in keys:
    g = group(k); prop = k.split("|", 1)[1] if "|" in k else k
    if k not in h or k not in f:
        only[g] += 1; out.write("ONLY-%s %s=%s\n" % ("HOST" if k in h else "FRIEND", k, h.get(k, f.get(k)))); continue
    if ignored(g, prop):
        if h[k] != f[k]: ign[g] += 1
        continue
    tot[g] += 1
    if h[k] != f[k]:
        dif[g] += 1; byprop[(g, prop)].append((k.split("|")[0], h[k], f[k])); out.write("DIFF %s host=%s friend=%s\n" % (k, h[k], f[k]))
out.close()
print("values compared: " + ", ".join("%s %d" % (g, tot[g]) for g in sorted(tot)))
print("values that differ: " + ", ".join("%s %d" % (g, dif[g]) for g in sorted(tot)) + " | present on one copy only: " + (", ".join("%s %d" % (g, only[g]) for g in sorted(only)) or "0"))
print("left out as not game facts (caches, timers, camera, debug), differing: " + (", ".join("%s %d" % (g, ign[g]) for g in sorted(ign)) or "0"))
print("properties that differ (objects, example host/friend):")
for (g, prop), lst in sorted(byprop.items(), key=lambda x: (x[0][0], -len(x[1]))):
    o, a, b = lst[0]
    print("  %-18s %-34s %4d  e.g. %s: %s / %s" % (g, prop[:34], len(lst), o[:26], a[:18], b[:18]))
PY
# leave the game as it was found
if [ "$WAS" != "paused" ] && [ "${KEEP_PAUSED:-}" != "1" ]; then printf 'lord:unPauseGame(); lord:setGameSpeed(%s); return "running again"
' "$WAS" > "$RUN/_un.lua"; np "$RUN/_un.lua" > /dev/null; fi
