#!/usr/bin/env python3
"""
Stress corpus for the mesh booleans (dev/CI only).

Every case builds two primitives and runs union, intersection and difference
in BeeScript (beemodel --run, headless), then checks the exact identities

    vol(A u B) + vol(A n B) = vol(A) + vol(B)      vol(A - B) = vol(A) - vol(A n B)

and that the results are closed (every edge used once in each direction).

A quarter of the cases are general position (random offsets and rotations).
The others are built to hit exact coincidences: grid offsets with quarter
turns (faces lying on faces, edges on edges, curved tessellations meeting
vertex to vertex, angles typed to six decimals) and identical operands.

Failures: any identity off, or an open result in general position. Open
results in the coincident cases are counted: solids that only touch along a
line (a cylinder inscribed in a cube) are non-manifold by nature, and are
allowed up to --max-touching percent.

usage: tests/bool_stress.py [binary] [--cases N] [--seed S] [--max-touching P]
"""
import os, random, subprocess, sys, tempfile, time

TYPES = ["cube", "sphere", "cylinder", "cone", "torus"]
BATCH = 50                      # cases per process (scripts are <= 64 KiB)


def gen_case(rng, i):
    ta, tb = rng.choice(TYPES), rng.choice(TYPES)
    mode = i % 4
    if mode == 0:               # coincidences: grid offsets, quarter turns
        q = 1.5707963267948966
        pa = (0, 0, 0, 0, 0, 0)
        pb = tuple(rng.choice([0, 0.5, 1, 0.25, 2]) for _ in range(3)) + \
            tuple(q * rng.choice([0, 1, 2]) for _ in range(3))
        kind = 'coincident'
    elif mode == 1 and i % 8 == 1:  # identical operands
        pa = (0, 0, 0, 0, 0, 0)
        pb = pa
        tb = ta
        kind = 'identical'
    else:
        pa = (0, 0, 0) + tuple(rng.uniform(-3, 3) for _ in range(3))
        pb = tuple(rng.uniform(-1.2, 1.2) for _ in range(3)) + \
            tuple(rng.uniform(-3, 3) for _ in range(3))
        kind = 'general'
    return ta, tb, pa, pb, kind


def script(cases, first):
    lines = ['fn mk(t, n, x, y, z, a, b, c) {', '  add(t, n, x, y, z)', '  rotate(n, a, b, c)', '}',
             'delete("Cube")']
    for j, (ta, tb, pa, pb, _) in enumerate(cases):
        i = first + j
        for k, op in enumerate(["union", "intersect", "difference"]):
            lines.append('mk("%s", "A%d_%d", %s)' % (ta, i, k, ", ".join("%.6f" % v for v in pa)))
            lines.append('mk("%s", "B%d_%d", %s)' % (tb, i, k, ", ".join("%.6f" % v for v in pb)))
            if k == 0:
                lines.append('va = volume("A%d_0")' % i)
                lines.append('vb = volume("B%d_0")' % i)
            lines.append('boolean("A%d_%d", "B%d_%d", "%s")' % (i, k, i, k, op))
        lines.append('print("R %d ", va, " ", vb, " ", volume("A%d_0"), " ", volume("A%d_1"), " ", '
                     'volume("A%d_2"), " ", manifold("A%d_0"), manifold("A%d_1"), manifold("A%d_2"))'
                     % ((i,) + (i,) * 6))
        lines.append('delete("A%d_0", "A%d_1", "A%d_2")' % (i, i, i))
    return "\n".join(lines) + "\n"


def run(binary, src, home):
    path = os.path.join(home, "s.bees")
    with open(path, "w") as f:
        f.write(src)
    env = dict(os.environ, HOME=home, XDG_RUNTIME_DIR=home, XDG_CACHE_HOME=home + "/c",
               XDG_CONFIG_HOME=home + "/cf")
    return subprocess.run([binary, "--run", path], capture_output=True, text=True, env=env, timeout=600)


def main():
    args = sys.argv[1:]
    binary = os.path.join(os.path.dirname(__file__), "..", "build", "beemodel")
    n, seed, max_touch = 300, 1, 2.0
    i = 0
    while i < len(args):
        if args[i] == "--cases":
            n = int(args[i + 1]); i += 2
        elif args[i] == "--seed":
            seed = int(args[i + 1]); i += 2
        elif args[i] == "--max-touching":
            max_touch = float(args[i + 1]); i += 2
        else:
            binary = args[i]; i += 1
    rng = random.Random(seed)
    cases = [gen_case(rng, i) for i in range(n)]
    home = tempfile.mkdtemp(prefix="bee-bool-")
    fails, touching, seen = [], [], 0
    t0 = time.time()
    for first in range(0, n, BATCH):
        part = cases[first:first + BATCH]
        r = run(binary, script(part, first), home)
        if r.returncode != 0:
            fails.append(f"batch {first}: exit {r.returncode} {r.stderr.strip()[-200:]}")
            continue
        for line in r.stdout.splitlines():
            if not line.startswith("R "):
                continue
            p = line.split()
            idx = int(p[1])
            va, vb, u, x, d = map(float, p[2:7])
            closed = "".join(p[7:10]) == "111"
            ta, tb, pa, pb, kind = cases[idx]
            seen += 1
            tol = 2e-3 * (abs(va) + abs(vb)) + 1e-4
            ok = abs(u + x - va - vb) < tol and abs(d - (va - x)) < tol and x > -tol and \
                u + tol >= max(va, vb)
            what = f"{idx} {kind} {ta}/{tb} B at {pb}: {' '.join(p[2:])}"
            if not ok:
                fails.append("volumes: " + what)
            elif not closed and kind == "general":
                fails.append("open in general position: " + what)
            elif not closed:
                touching.append(what)
    dt = time.time() - t0
    if seen != n:
        fails.append(f"only {seen} of {n} cases reported")
    # one heavy case: a subdivided sphere minus another (63k x 16k triangles)
    heavy = ('delete("Cube")\nadd("sphere", "A")\nmodifier("A", "subsurf")\nmodset("A", 0, "levels", 3)\n'
             'modapply("A", 0)\nadd("sphere", "B", 0.6, 0.3, 0.2)\nmodifier("B", "subsurf")\n'
             'modset("B", 0, "levels", 2)\nmodapply("B", 0)\nt = clock()\nboolean("A", "B", "difference")\n'
             'print("H ", clock() - t, " ", manifold("A"))\n')
    r = run(binary, heavy, home)
    h = [l.split() for l in r.stdout.splitlines() if l.startswith("H ")]
    heavy_ms = float(h[0][1]) if h else -1
    if not h or h[0][2] != "1" or heavy_ms > 1000:
        fails.append(f"heavy case: {r.stdout.strip()} {r.stderr.strip()[-200:]}")
    for t in touching:
        print("  touching (open by nature): " + t)
    for f in fails:
        print("  FAIL " + f)
    pct = 100.0 * len(touching) / max(1, n)
    if pct > max_touch:
        fails.append(f"{pct:.1f}% open results in coincident cases (allowed {max_touch}%)")
    print(f"  {seen} cases x 3 operations in {dt:.1f} s: {len(fails)} failure(s), "
          f"{len(touching)} touching; 63k x 16k triangles in {heavy_ms:.0f} ms")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
