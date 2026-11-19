# Lane 70 desk test: coop_x_army.lua's own shape arithmetic under Lua 5.1 (t_shape_desk.lua through luacheck.py)
# against the Python model (research/.../lanes/lane_70/tools/shape_model.py) on drags made by the model of the game's
# routine. The two must give the same answers.   py -3 -I shape_desk.py [drags]
import math, os, random, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "research", "2026-11-10-game-probe", "lanes", "lane_70", "tools")))
import luacheck
import shape_model as SMd

def g(x): return "%.17g" % x

def main():
    drags = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    random.seed(70)
    cases, want = [], []
    for k in range(drags):
        n = random.randint(1, 80); sp = random.choice([95.0, 120.0, 180.0])
        L = random.uniform(250, 5000); th = random.uniform(-math.pi, math.pi)
        P = (random.uniform(-1e5, 1e5), random.uniform(-1e5, 1e5)); Q = (P[0] + L * math.cos(th), P[1] + L * math.sin(th))
        fi, ranks, T, d, A, B = SMd.game(P, Q, n, sp, jitter=True, seed=k)
        seg = random.uniform(0, 6000)
        cases.append("F %s %s" % (g(seg), g(sp))); want.append("F %d" % SMd.filesOf(seg, sp))
        a, b = SMd.centroidOf(n, fi)
        cases.append("C %d %d" % (n, fi)); want.append("C %s %s" % (g(a), g(b)))
        hint = math.atan2(d[1], d[0]) + math.radians(random.uniform(-1, 1))
        hx, hy = math.cos(hint), math.sin(hint)
        r = SMd.dragFrom(n, sp, Q[0], Q[1], T[0], T[1], math.atan2(hy, hx))
        cases.append("D %d %s %s %s %s %s %s %s" % (n, g(sp), g(Q[0]), g(Q[1]), g(T[0]), g(T[1]), g(hx), g(hy)))
        want.append("D nil" if not r else "D %s %s %s %d %s" % (g(r[0][0]), g(r[0][1]), g(r[1]), r[3], r[2]))
        ra = SMd.dragAlong(n, sp, Q[0], Q[1], T[0], T[1], d[0], d[1])
        cases.append("A %d %s %s %s %s %s %s %s" % (n, g(sp), g(Q[0]), g(Q[1]), g(T[0]), g(T[1]), g(d[0]), g(d[1])))
        want.append("A nil" if not ra else "A %s %s %s %d %s" % (g(ra[0][0]), g(ra[0][1]), g(ra[1]), ra[3], ra[2]))
        sp2 = random.choice([95.0, 120.0, 180.0])
        P3, Q3 = SMd.lineForShape({'ax': A[0], 'ay': A[1], 'bx': B[0], 'by': B[1], 'fi': fi, 'sp': sp}, sp2)
        cases.append("S %s %s %s %s %d %s %s" % (g(A[0]), g(A[1]), g(B[0]), g(B[1]), fi, g(sp), g(sp2)))
        want.append("S %s %s %s %s" % (g(P3[0]), g(P3[1]), g(Q3[0]), g(Q3[1])))
        # the measured shape from the men's places (with the game's random offsets): checked by shape, not exactly
        SMd.game(P, Q, n, sp, jitter=False)
        f0 = min((p for p in SMd.LAST_PTS if p[2] == 0), key=lambda p: p[0] * d[0] + p[1] * d[1])   # the front rank's first slot
        SMd.game(P, Q, n, sp, jitter=True, seed=k)
        pts = " ".join("%s %s" % (g(p[0]), g(p[1])) for p in SMd.LAST_PTS)
        cases.append("M %d %s %s %s %s" % (n, g(sp), g(d[0]), g(d[1]), pts))
        want.append(("M~", min(n, fi + 1), ranks, f0[0], f0[1], sp))
    tmp = tempfile.mkdtemp(prefix="lane70_")
    cf, af = os.path.join(tmp, "cases.txt"), os.path.join(tmp, "answers.txt")
    open(cf, "w").write("\n".join(cases) + "\n")
    rc = luacheck.run(os.path.join(HERE, "t_shape_desk.lua"), [cf.replace("\\", "/"), af.replace("\\", "/")])
    if rc: print("FAIL: the Lua test did not run"); return 1
    got = open(af).read().split("\n")[:-1]
    exact = near = bad = 0; kinds = {}
    mok = mbad = 0; merr = []
    for c, w, a in zip(cases, want, got):
        k = c[0]; kinds.setdefault(k, [0, 0, 0])
        if isinstance(w, tuple):
            aa = a.split(); _, files, ranks, ax, ay, sp = w; nn = int(c.split()[1])
            if aa[1] != "nil" and min(nn, int(aa[1]) + 1) == files and int(aa[2]) == ranks and math.hypot(float(aa[3]) - ax, float(aa[4]) - ay) <= 0.25 * sp:
                mok += 1; merr.append(math.hypot(float(aa[3]) - ax, float(aa[4]) - ay))
            else:
                mbad += 1
                if mbad <= 3: print("  MEASURE MISS  n %d: want %d files x %d ranks at %.0f,%.0f; lua %s" % (nn, files, ranks, ax, ay, a))
            continue
        if w == a: exact += 1; kinds[k][0] += 1; continue
        ww, aa = w.split(), a.split()
        ok = len(ww) == len(aa) and all(x == y or (x[0] in "-0123456789" and abs(float(x) - float(y)) <= 1e-9 * max(1.0, abs(float(x)))) for x, y in zip(ww, aa))
        if ok: near += 1; kinds[k][1] += 1
        else:
            bad += 1; kinds[k][2] += 1
            if bad <= 5: print("  DIFFER  case %s\n          python %s\n          lua    %s" % (c, w, a))
    print("drags %d, answers %d (of %d): identical %d, equal to 1e-9 %d, different %d" % (drags, len(got), len(want), exact, near, bad))
    for k, v in sorted(kinds.items()): print("  %s: identical %d, to 1e-9 %d, different %d" % (k, v[0], v[1], v[2]))
    merr.sort()
    print("measured shapes (Lua measureShape on the men's places): right %d, wrong %d; start off by median %.1f cm, largest %.1f cm"
          % (mok, mbad, merr[len(merr) // 2] if merr else -1, merr[-1] if merr else -1))
    for f in (cf, af): os.remove(f)
    os.rmdir(tmp)
    return 1 if bad or mbad or len(got) != len(want) else 0

if __name__ == "__main__":
    sys.exit(main())
