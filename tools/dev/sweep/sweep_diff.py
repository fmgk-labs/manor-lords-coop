"""Parity sweep (lane 68): compare the host's and a friend's panel dumps (sweep_probe.lua) and print every difference.

    py -I tools/dev/sweep/sweep_diff.py <host dump> <friend dump> [--out diff.tsv] [--ignore patterns.txt]

Pairs the two dumps by panel (a building by its key type@x/10,y/10; HUD, TAB n, REGION tag, DEV, MAP, VIEW class) and,
inside a panel, by tab and widget path. No list of fields: whatever the panels draw is compared.
Prints:
  1. warnings: headers that differ (day, pause, building counts), a copy that was not paused, truncated walks,
     panels that failed to open, aborted sweeps;
  2. coverage: building types of the player and how many of each were swept on both copies; types never swept;
  3. differences grouped by widget (building type + tab + path, sibling numbers kept), most frequent first, with the
     number of panels it differs in and two examples;
  4. per building type: panels compared, panels with a difference, differing widgets.
--out writes one line per difference: panel, tab, path, kind, host value, friend value (a value missing on one copy
is written "<none>").
--ignore: a file of regular expressions, one per line ('#' starts a comment), matched against
"<panel>\t<tab>\t<path>"; a matching difference is counted as ignored, not listed (for named, explained causes only).
--soft: the same form; a matching difference is listed as SOFT (known and accepted by the owner, e.g. a villager's
task label a few seconds out of step) and does not fail the check. tools/dev/sweep/soft.txt is that list.
Exit code 0 when there is no difference that is not ignored, 1 otherwise, 2 on a usage or file error.
"""
import collections
import io
import re
import sys


CANON = {}                                     # lower-case widget path -> the first spelling seen


def load(path):
    head, foot, warns, notes = {}, {}, [], collections.defaultdict(list)
    recs = {}
    order = collections.Counter()
    try:
        fh = io.open(path, encoding="utf-8", errors="replace")
    except OSError as e:
        print("cannot read %s: %s" % (path, e))
        sys.exit(2)
    with fh:
        for raw in fh:
            line = raw.rstrip("\r\n")
            if not line:
                continue
            if line.startswith("#H "):
                head = dict(kv.split("=", 1) for kv in line[3:].split(" ") if "=" in kv)
            elif line.startswith("#END"):
                foot = dict(kv.split("=", 1) for kv in line[5:].split(" ") if "=" in kv)
            elif line.startswith("#WARN") or line.startswith("#ABORT"):
                warns.append(line)
            elif line.startswith("P\t"):
                parts = line.split("\t")
                if len(parts) < 6:
                    warns.append("malformed line: " + line[:120])
                    continue
                _, panel, tab, wpath, kind = parts[:5]
                val = "\t".join(parts[5:])
                if kind == "I":                        # a dynamic material instance is named per copy: MID_x_2147454794
                    val = re.sub(r"^(MID_.*?)_\d+\|", r"\1|", val)
                # a texture made at run time (graph lines) is named per copy too: Texture2D_2147444360
                val = re.sub(r"^(Texture2D)_\d+\|", r"\1|", val)
                # widget names are engine names, which ignore case: each copy keeps the first spelling it met
                # (ItemImage on one, itemImage on the other), so a path takes the first spelling seen for it
                # (the host's, loaded first) and both copies' values meet under one key
                wpath = CANON.setdefault(wpath.lower(), wpath)
                k = (panel, tab, wpath)
                order[k] += 1
                if order[k] > 1:                       # the same path twice in one panel: keep both, numbered
                    k = (panel, tab, wpath + "~" + str(order[k]))
                recs[k] = (kind, val)
            elif line.startswith("E\t"):
                parts = line.split("\t", 2)
                if len(parts) == 3:
                    notes[parts[1]].append(parts[2])
    return {"head": head, "foot": foot, "warns": warns, "notes": notes, "recs": recs}


def btype(panel):
    m = re.match(r"^B (\d+)@", panel)
    return int(m.group(1)) if m else None


def group_key(panel, tab, wpath):
    t = btype(panel)
    where = ("type %d" % t) if t is not None else re.sub(r" .*$", "", panel)
    return "%s | %s | %s" % (where, tab, wpath)


def main(argv):
    args = list(argv)
    out_path = ign_path = soft_path = None
    if "--out" in args:
        i = args.index("--out"); out_path = args[i + 1]; del args[i:i + 2]
    if "--ignore" in args:
        i = args.index("--ignore"); ign_path = args[i + 1]; del args[i:i + 2]
    if "--soft" in args:
        i = args.index("--soft"); soft_path = args[i + 1]; del args[i:i + 2]
    if len(args) != 2:
        print(__doc__)
        return 2
    H, F = load(args[0]), load(args[1])

    def patterns(path):
        out = []
        if path:
            for line in io.open(path, encoding="utf-8"):
                line = line.strip()
                if line and not line.startswith("#"):
                    out.append(re.compile(line, re.I))
        return out
    ignores, softs = patterns(ign_path), patterns(soft_path)

    # 1. warnings
    w = []
    for name, D in (("host", H), ("friend", F)):
        if not D["head"]:
            w.append("%s: no header (not a sweep dump, or the sweep did not start)" % name)
        if not D["foot"]:
            w.append("%s: no #END line: the sweep did not finish (stopped, aborted or still running)" % name)
        w.extend("%s: %s" % (name, x) for x in D["warns"])
        if D["head"] and not (D["head"].get("paused") == "true" and _num(D["head"].get("speed")) <= 0.001):
            w.append("%s: not paused at the start (paused=%s speed=%s)" % (name, D["head"].get("paused"), D["head"].get("speed")))
    for k in ("day", "dayfield", "buildings", "mine", "swept", "types", "only", "screens"):
        a, b = H["head"].get(k), F["head"].get(k)
        if a != b:
            w.append("header %s differs: host %s, friend %s" % (k, a, b))
    fails = collections.Counter()
    for name, D in (("host", H), ("friend", F)):
        for panel, lst in D["notes"].items():
            for n in lst:
                if "OPENFAIL" in n or "GONE" in n or "TABFAIL" in n or "PANEL CLOSED" in n or "no HUD" in n:
                    fails[(name, panel, n.split(" ")[0])] += 1
                if "TRUNCATED" in n or "truncated at" in n or "too deep" in n:
                    w.append("%s: %s: %s" % (name, panel, n[:160]))
    for (name, panel, what), c in sorted(fails.items()):
        w.append("%s: %s: %s" % (name, panel, what))

    # pair panels
    hp = collections.defaultdict(dict); fp = collections.defaultdict(dict)
    for (panel, tab, wpath), v in H["recs"].items():
        hp[panel][(tab, wpath)] = v
    for (panel, tab, wpath), v in F["recs"].items():
        fp[panel][(tab, wpath)] = v
    both = sorted(set(hp) & set(fp)); only_h = sorted(set(hp) - set(fp)); only_f = sorted(set(fp) - set(hp))

    diffs = []                                         # (panel, tab, path, kind, host, friend)
    soft = []                                          # the same, matching a --soft pattern (known, accepted by the owner)
    ignored = 0
    for panel in both:
        a, b = hp[panel], fp[panel]
        for key in sorted(set(a) | set(b)):
            va, vb = a.get(key), b.get(key)
            if va == vb:
                continue
            tab, wpath = key
            if any(r.search("%s\t%s\t%s" % (panel, tab, wpath)) for r in ignores):
                ignored += 1
                continue
            kind = (va or vb)[0]
            d = (panel, tab, wpath, kind, va[1] if va else "<none>", vb[1] if vb else "<none>")
            if any(r.search("%s\t%s\t%s" % (panel, tab, wpath)) for r in softs):
                soft.append(d)
            else:
                diffs.append(d)

    # 2. coverage
    def types_of(head):
        t = {}
        for x in (head.get("types") or "").split(","):
            if ":" in x:
                a, b = x.split(":", 1)
                t[int(a)] = int(b)
        return t
    th, tf = types_of(H["head"]), types_of(F["head"])
    swept = collections.Counter(btype(p) for p in both if btype(p) is not None)
    print("PARITY SWEEP  host %s  friend %s" % (args[0], args[1]))
    print("host:   %s" % " ".join("%s=%s" % kv for kv in sorted(H["head"].items()) if kv[0] != "types"))
    print("friend: %s" % " ".join("%s=%s" % kv for kv in sorted(F["head"].items()) if kv[0] != "types"))
    print()
    print("WARNINGS (%d)" % len(w))
    for x in w:
        print("  " + x)
    print()
    print("COVERAGE: panels on both %d, only on the host %d, only on the friend %d" % (len(both), len(only_h), len(only_f)))
    for p in only_h[:40]:
        print("  only host:   " + p)
    for p in only_f[:40]:
        print("  only friend: " + p)
    never = []
    print("  building types of the player (host count / friend count / swept on both):")
    for t in sorted(set(th) | set(tf)):
        print("    type %-4d %3s / %3s / %3d" % (t, th.get(t, 0), tf.get(t, 0), swept.get(t, 0)))
        if swept.get(t, 0) == 0:
            never.append(t)
    print("  types never swept on both copies: %s" % (", ".join(str(t) for t in never) or "none"))
    print("  (a type the town does not have is not tested by this sweep: 0 differences says nothing about it)")
    print()

    # 3. by widget
    groups = collections.defaultdict(list)
    for d in diffs:
        groups[group_key(d[0], d[1], d[2])].append(d)
    print("DIFFERENCES: %d values in %d widgets, %d panels; %d ignored by pattern" % (len(diffs), len(groups), len({d[0] for d in diffs}), ignored))
    for g, lst in sorted(groups.items(), key=lambda kv: (-len({d[0] for d in kv[1]}), kv[0])):
        panels = sorted({d[0] for d in lst})
        ex = "; ".join("%s: %s / %s" % (d[0], d[4][:60], d[5][:60]) for d in lst[:2])
        print("  [%d panels] %s  (kind %s)" % (len(panels), g, lst[0][3]))
        print("      e.g. " + ex)
    print("SOFT (known, accepted; not failing): %d values" % len(soft))
    for d in soft[:30]:
        print("  %s | %s | %s: %s / %s" % (d[0], d[1], d[2].split("/")[-1], d[4][:50], d[5][:50]))
    print()

    # 3b. by kind of widget (the last step of the path without its number), hard and soft
    byk = collections.defaultdict(lambda: [0, 0, set()])
    for lst, i in ((diffs, 0), (soft, 1)):
        for d in lst:
            k = re.sub(r"#\d+(~\d+)?$", "", d[2].split("/")[-1])
            t = btype(d[0])
            byk[k][i] += 1
            byk[k][2].add(("type %d" % t) if t is not None else d[0].split(" ")[0])
    print("BY KIND OF WIDGET: hard / soft values, where")
    for k, (nh, ns, where) in sorted(byk.items(), key=lambda kv: (-kv[1][0], -kv[1][1], kv[0])):
        print("  %-48s %4d / %4d   %s" % (k, nh, ns, ", ".join(sorted(where))))
    print()

    # 4. per building type
    per = collections.defaultdict(lambda: [0, set(), set()])
    for p in both:
        t = btype(p)
        per[t if t is not None else p.split(" ")[0]][0] += 1
    for d in diffs:
        t = btype(d[0])
        k = t if t is not None else d[0].split(" ")[0]
        per[k][1].add(d[0]); per[k][2].add((d[1], d[2]))
    print("PER TYPE: panels compared / panels with a difference / differing widgets")
    for k in sorted(per, key=lambda x: (isinstance(x, str), x)):
        n, ps, ws = per[k]
        print("  %-10s %4d / %4d / %4d" % (("type %d" % k) if isinstance(k, int) else k, n, len(ps), len(ws)))

    if out_path:
        with io.open(out_path, "w", encoding="utf-8") as fo:
            fo.write("panel\ttab\tpath\tkind\thost\tfriend\tclass\n")
            for d in diffs:
                fo.write("\t".join(d) + "\thard\n")
            for d in soft:
                fo.write("\t".join(d) + "\tsoft\n")
    print("SUMMARY panels=%d values_host=%d values_friend=%d hard=%d soft=%d ignored=%d warnings=%d only_host=%d only_friend=%d"
          % (len(both), len(H["recs"]), len(F["recs"]), len(diffs), len(soft), ignored, len(w), len(only_h), len(only_f)))
    return 1 if diffs else 0


def _num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return 1.0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
