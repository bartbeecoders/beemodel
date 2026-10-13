#!/usr/bin/env python3
"""The v0.9 walkthrough: tests/procedural.bees builds a valley from one node
tree (an eroded ridged terrain, scattered rocks, L-system plants), a curve
rail with posts from a second tree, and a meadow of a million instanced
blades from a third; saves it and renders it. This runs it (in an isolated
HOME), checks the numbers and the budgets - a million instances placed in
under 200 ms - and that the .bee file brings the scene back.

    python3 tests/procedural.py build/beemodel [outdir]
"""
import os, shutil, subprocess, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
PLACE_MS = 200.0                   # a million instances placed (exit criterion)
LAND_MS = 3000.0                   # terrain, 200k droplets, scattering (4-core runner)
BUDGET_S = 60.0                    # end to end
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(home, code):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=600)
    out = {}
    for line in r.stdout.splitlines():
        w = line.split()
        if w:
            try:
                out[w[0]] = [float(x) for x in w[1:]]
            except ValueError:
                pass
    if r.returncode != 0 or r.stderr.strip():
        print(r.stdout[-2000:], r.stderr[-2000:])
    return out


def main():
    print('  -- procedural walkthrough --')
    home = tempfile.mkdtemp(prefix='bee-pg-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    t = time.time()
    out = run(home, open(os.path.join(HERE, 'procedural.bees')).read())
    secs = time.time() - t
    land, rail, meadow, rend = (out.get(k, []) for k in ('land', 'bridge', 'meadow', 'rendered'))
    check(len(land) == 3 and land[0] == 40401 and 250 <= land[1] <= 700 and land[2] < LAND_MS,
          f'the valley: a 200 x 200 eroded terrain with {land[1:2]} rocks and plants in {land[2:]} ms (budget {LAND_MS:.0f})')
    check(len(rail) == 4 and rail[0] == 3 and 33 < rail[1] < 36 and rail[2] == 16 and rail[3] == 480,
          f'the rail: a 3-point Bezier swept into a tube with 16 posts along it ({rail})')
    check(len(meadow) == 2 and meadow[0] == 1000000 and meadow[1] < PLACE_MS,
          f'a million blades placed in {meadow[1:]} ms (budget {PLACE_MS:.0f} ms)')
    d = os.path.join(home, 'BeeModel')
    files = ['procedural.bee', 'procedural.png']
    check(all(os.path.exists(os.path.join(d, f)) for f in files) and len(rend) == 1,
          f'saved and rendered in {rend} ms')
    back = run(home, 'op("file.open", "~/BeeModel/procedural.bee")\n'
                     'print("back", instances("Land"), instances("Meadow"), cpoints("Bridge"), instances("Bridge"))\n')
    b = back.get('back', [])
    check(len(b) == 4 and len(land) == 3 and b[0] == land[1] and b[1] == 1000000 and b[2] == 3 and b[3] == 16,
          f'the .bee file brings the trees, the curve and the instances back ({b})')
    check(secs < BUDGET_S, f'the walkthrough runs in {secs:.1f} s (budget {BUDGET_S:.0f} s)')
    if OUT:
        os.makedirs(OUT, exist_ok=True)
        for f in files[1:]:
            if os.path.exists(os.path.join(d, f)):
                shutil.copy(os.path.join(d, f), os.path.join(OUT, f))
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nprocedural walkthrough: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
