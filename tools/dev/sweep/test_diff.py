"""Self-test of sweep_diff.py on made-up dumps (no game).   py -I tools/dev/sweep/test_diff.py
Cases: equal dumps; a changed value; a value on one copy only; the same path twice in one panel; a building on one
copy only; lines in another order; a dump without #END; a copy not paused; an ignore pattern; header differences."""
import io
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DIFF = os.path.join(HERE, "sweep_diff.py")
HEAD = "#H role=%s day=40 dayfield=10 paused=true speed=0 buildings=20 mine=3 swept=3 types=89:2,72:1 only= screens=0 ver=1"
END = "#END jobs=4 panels=4 records=9 fails=0 errors=0 seconds=3.0"
BASE = [
    "P\tHUD\t-\tMainUICPP_C:MainUI#1/TextBlock:Silver#1\tT\t120",
    "P\tB 89@100,200\t1:Workers\tInventory_C:Inventory#1/TextBlock:Status#1\tT\tMaintained",
    "P\tB 89@100,200\t1:Workers\tInventory_C:Inventory#1/ProgressBar:Bar#1\tP\t1",
    "P\tB 89@100,200\t2:Maintenance\tInventory_C:Inventory#1/TextBlock:Yield#1\tT\tFair 100 %",
    "P\tB 89@300,400\t1:Workers\tInventory_C:Inventory#1/TextBlock:Status#1\tT\tMaintained",
    "P\tB 72@500,600\t1:Storage\tInventory_C:Inventory#1/W_ItemCounterV2_C:Item#1/TextBlock:N#1\tT\t40",
    "P\tB 72@500,600\t1:Storage\tInventory_C:Inventory#1/W_ItemCounterV2_C:Item#2/TextBlock:N#1\tT\t12",
    "E\tB 72@500,600\tOPENED tabs=1 selected=ok",
]
fails = 0


def run(host, friend, extra=()):
    d = tempfile.mkdtemp(prefix="sweepdiff_")
    ph, pf, po = os.path.join(d, "h.txt"), os.path.join(d, "f.txt"), os.path.join(d, "o.tsv")
    io.open(ph, "w", encoding="utf-8").write("\n".join(host) + "\n")
    io.open(pf, "w", encoding="utf-8").write("\n".join(friend) + "\n")
    args = [sys.executable, "-I", DIFF, ph, pf, "--out", po]
    for x in extra:
        args.append(x if x != "@IGN" else os.path.join(d, "ign.txt"))
    if "@IGN" in extra:
        io.open(os.path.join(d, "ign.txt"), "w", encoding="utf-8").write("# test\nTextBlock:Yield\n")
    r = subprocess.run(args, capture_output=True, text=True)
    tsv = io.open(po, encoding="utf-8").read().splitlines()[1:] if os.path.exists(po) else []
    for p in (ph, pf, po, os.path.join(d, "ign.txt")):
        if os.path.exists(p):
            os.remove(p)
    os.rmdir(d)
    return r.returncode, r.stdout, tsv


def check(cond, what):
    global fails
    print(("PASS  " if cond else "FAIL  ") + what)
    if not cond:
        fails += 1


h = [HEAD % "host"] + BASE + [END]
f = [HEAD % "friend"] + BASE + [END]
rc, out, tsv = run(h, f)
check(rc == 0 and len(tsv) == 0 and "DIFFERENCES: 0 values" in out, "equal dumps: exit 0, no difference")
check("WARNINGS (0)" in out, "equal dumps: no warning")

f2 = [x.replace("Maintained", "Needs Maintenance", 1) if "89@100,200" in x else x for x in f]
f2 = [x.replace("Fair 100 %", "Modest 50 %") for x in f2]
rc, out, tsv = run(h, f2)
check(rc == 1 and len(tsv) == 2, "changed values: two differences")
check(any("Needs Maintenance" in t and "Maintained" in t for t in tsv), "changed value: host and friend values in the tsv")

f3 = [x for x in f if "ProgressBar" not in x]
rc, out, tsv = run(h, f3)
check(len(tsv) == 1 and tsv[0].endswith("\t1\t<none>\thard"), "a value on the host only: friend <none>")

h4 = h[:-1] + ["P\tHUD\t-\tMainUICPP_C:MainUI#1/TextBlock:Silver#1\tT\t5", END]
f4 = f[:-1] + ["P\tHUD\t-\tMainUICPP_C:MainUI#1/TextBlock:Silver#1\tT\t6", END]
rc, out, tsv = run(h4, f4)
check(len(tsv) == 1 and "~2" in tsv[0], "the same path twice: the second is compared as its own value")

f5 = [x for x in f if "89@300,400" not in x]
rc, out, tsv = run(h, f5)
check("only host:   B 89@300,400" in out, "a building on the host only is listed")
check("only friend" not in out, "no building on the friend only")

f6 = [f[0]] + list(reversed(f[1:-1])) + [f[-1]]
rc, out, tsv = run(h, f6)
check(rc == 0 and len(tsv) == 0, "lines in another order: no difference")

rc, out, tsv = run(h, f[:-1])
check("friend: no #END line" in out, "a dump without #END: warned")

f8 = [f[0].replace("paused=true speed=0", "paused=false speed=4")] + f[1:]
rc, out, tsv = run(h, f8)
check("friend: not paused" in out, "a copy not paused: warned")

rc, out, tsv = run(h, f2, ("--ignore", "@IGN"))
check(len(tsv) == 1 and "1 ignored by pattern" in out, "an ignore pattern: the matching difference is counted, not listed")

rc, out, tsv = run(h, f2, ("--soft", "@IGN"))
check(rc == 1 and len(tsv) == 2 and sum(t.endswith("\tsoft") for t in tsv) == 1 and "hard=1 soft=1" in out,
      "a soft pattern: listed as soft, the other stays hard")
check("BY KIND OF WIDGET" in out and "TextBlock:Yield" in out, "the summary by kind of widget")
h11 = h[:-1] + ["P\tB 89@100,200\t1:Workers\tInventory_C:Inventory#1/Border:TaskOverlay#1/MLTextBlock:TaskText#1\tT\tWaiting", END]
f11 = f[:-1] + ["P\tB 89@100,200\t1:Workers\tInventory_C:Inventory#1/Border:TaskOverlay#1/MLTextBlock:TaskText#1\tT\tGoing somewhere", END]
rc, out, tsv = run(h11, f11, ("--soft", os.path.join(HERE, "soft.txt")))
check(rc == 0 and "hard=0 soft=1" in out, "soft.txt: a villager task label is soft, the check passes")

f10 = [f[0].replace("day=40", "day=41")] + f[1:]
rc, out, tsv = run(h, f10)
check("header day differs: host 40, friend 41" in out, "header difference: warned")

rc, out, tsv = run(h, f2)
check("type 89" in out and "PER TYPE" in out, "per type table printed")
check("types never swept on both copies: none" in out, "coverage: every type swept")

print("%d failed" % fails)
sys.exit(1 if fails else 0)
