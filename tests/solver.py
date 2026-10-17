#!/usr/bin/env python3
"""The rigid-body solver (2.0 plan, stage R). Stacks that stand: a tower of
20 boxes and a 10-layer brick pyramid settle within the first second (a few
mm: soft contacts give a little under the weight above) and then stand
still to 10 s; a 1 kg box rests on a 100 kg one and the other way round
(substeps, soft contacts and face clipping, R1).

    python3 tests/solver.py build/beemodel
"""
import os, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, timeout=600):
    home = tempfile.mkdtemp(prefix='bee-solver-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(r.stdout[-1500:], r.stderr[-1500:])
    return [l.split() for l in r.stdout.splitlines() if l.strip()]


GROUND = ('delete("Cube")\ndelete("Light")\ndelete("Camera")\n'
          'add("plane", "Ground", 0, 0, 0)\nscale("Ground", 30)\nselect("Ground")\nop("rigid.add", "passive box")\n')

# every body's place at the start, at 1 s (settled) and at 10 s
SAMPLE = ('fn at(tag) {\n for i in 0..n { print(tag, i, get(b + str(i), "x"), get(b + str(i), "y"), get(b + str(i), "z")) }\n}\n'
          'frame(1)\nat("t0")\nframe(25)\nat("t1")\nframe(241)\nat("t10")\n')

TOWER = GROUND + (
    'for i in 0..20 {\n n = "T" + str(i)\n add("cube", n, 0, 0.25 + i * 0.5, 0)\n scale(n, 0.25)\n select(n)\n op("rigid.add", "active box")\n}\n'
    'n = 20\nb = "T"\n' + SAMPLE)

PYRAMID = GROUND + (
    'k = 0\n'
    'for l in 0..10 {\n'
    ' for j in 0..10 - l {\n'
    '  n = "P" + str(k)\n'
    '  add("cube", n, (j - (9 - l) / 2) * 1.0, 0.25 + l * 0.5, 0)\n'
    '  scale(n, 0.5, 0.25, 0.5)\n  select(n)\n  op("rigid.add", "active box")\n  k += 1\n'
    ' }\n'
    '}\n'
    'n = k\nb = "P"\n' + SAMPLE)

RATIO = GROUND + (
    'add("cube", "Heavy", 0, 0.5, 0)\nscale("Heavy", 0.5)\nselect("Heavy")\nop("rigid.add", "active box mass 100")\n'
    'add("cube", "Light1", 0, 1.1, 0)\nscale("Light1", 0.1)\nselect("Light1")\nop("rigid.add", "active box mass 1")\n'
    'add("cube", "Big", 4, 0.5, 0)\nscale("Big", 0.5)\nselect("Big")\nop("rigid.add", "active box mass 1")\n'
    'add("cube", "Weight", 4, 1.5, 0)\nscale("Weight", 0.5)\nselect("Weight")\nop("rigid.add", "active box mass 100")\n'
    'frame(241)\n'
    'print("ratio", get("Heavy", "y"), get("Light1", "y"), get("Light1", "x"), get("Big", "y"), get("Weight", "y"), get("Weight", "x"))\n')


def drift(rows):
    """(settling: the largest move start -> 1 s, standing: 1 s -> 10 s,
    the largest drop) in mm"""
    at = {}
    for r in rows:
        if len(r) == 5 and r[0] in ('t0', 't1', 't10'):
            at.setdefault(r[0], {})[r[1]] = [float(v) for v in r[2:]]
    if len(at) != 3 or not (len(at['t0']) == len(at['t1']) == len(at['t10'])):
        return None, None, None
    dist = lambda a, b: ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5
    hor = lambda a, b: ((a[0] - b[0]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5
    settle = max(hor(at['t0'][k], at['t1'][k]) for k in at['t0'])
    stand = max(dist(at['t1'][k], at['t10'][k]) for k in at['t0'])
    drop = max(at['t0'][k][1] - at['t10'][k][1] for k in at['t0'])
    return settle * 1000, stand * 1000, drop * 1000


def main():
    print('  -- the solver: stacks --')
    for name, code, n in (('a tower of 20 boxes', TOWER, 20), ('a 10-layer brick pyramid (55 bricks)', PYRAMID, 10)):
        se, st, dr = drift(run(code))
        check(se is not None and st < 1.0 and se < 5.0 and dr < 4.0 * n,
              f'{name} settles (moving {se and round(se, 2)} mm sideways, {dr and round(dr, 1)} mm down) and stands '
              f'still from 1 s to 10 s ({st and round(st, 3)} mm)')
    r = {x[0]: [float(v) for v in x[1:]] for x in run(RATIO) if x}
    v = r.get('ratio', [0] * 6)
    check(abs(v[0] - 0.5) < 0.005 and abs(v[1] - 1.1) < 0.005 and abs(v[2]) < 0.001,
          f'a 1 kg box rests on a 100 kg one (at {round(v[1], 4)} m, 1.1 expected)')
    check(abs(v[3] - 0.5) < 0.01 and abs(v[4] - 1.5) < 0.02 and abs(v[5] - 4) < 0.001,
          f'a 100 kg box rests on a 1 kg one (at {round(v[4], 4)} m, 1.5 expected; soft contacts give a little under '
          f'a heavy load)')
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nthe solver: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
