#!/usr/bin/env python3
"""The v0.12 B-rep kernel (cad.kernel on): NURBS math, exact solids from
sketches, booleans, fillets, tessellation, and the CAD walkthroughs on it.

  * NURBS: arcs lie on their circles, knot insertion and degree elevation
    leave curves and surfaces where they were, derivatives agree with
    differences, revolved NURBS cylinders and tori lie on their surfaces.
  * Pads and revolves give planes, cylinders, cones, spheres and tori whose
    volumes and areas (integrated exactly over the trimmed faces) match the
    closed forms; every solid is a valid B-rep (each edge used once each way,
    loops closed) and its tessellation is watertight.
  * Booleans: a pocket, holes, a boss on a face (coplanar), a hole drilled
    across a rod (a traced cylinder-cylinder intersection) - against an
    independent numerical integral -, a shell; fillets and chamfers.
  * The enclosure walkthrough builds on the kernel: every feature, both
    parts valid and watertight, close to the mesh replay's volumes, and still
    so after a parameter change; the switch is saved with the file.

    python3 tests/brep.py build/beemodel
"""
import math, os, subprocess, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []
HOME = tempfile.mkdtemp(prefix='bee-brep-')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, timeout=300):
    env = dict(os.environ, HOME=HOME, XDG_CACHE_HOME='')
    path = os.path.join(HOME, 'script.bees')
    with open(path, 'w') as f:
        f.write(code)
    r = subprocess.run([BIN, '--run', path], env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
    return r.stdout.split('\n')


def rows(lines):
    """name -> list of fields (numbers where they parse)"""
    out = {}
    for line in lines:
        f = line.split()
        if not f:
            continue
        vals = []
        for x in f[1:]:
            try:
                vals.append(float(x))
            except ValueError:
                vals.append(x)
        out[f[0]] = vals
    return out


def rel(a, b):
    return abs(a - b) / abs(b)


P = math.pi
KERNEL = 'op("cad.kernel", "on")\ndelete("Cube")\nP = 3.14159265358979\n'
STATS = '"volume", "area", "faces", "valid", "watertight", "kernel"'


def stats(name, tag):
    return 'print("%s", %s)\n' % (tag, ', '.join('brep("%s", %s)' % (name, k) for k in STATS.split(', ')))


def errs(name, tag, volume, area=None):
    """a line printing the relative errors of the volume (and area) against
    these values (BeeScript prints 7 digits: the errors carry the precision)"""
    a = '(brep("%s", "area") - %r) / %r' % (name, area, area) if area else '0'
    return 'print("%s", (brep("%s", "volume") - %r) / %r, %s)\n' % (tag, name, volume, volume, a)


def main():
    print('  -- B-rep kernel --')
    # ---- NURBS --------------------------------------------------------------
    r = rows(run('for k in 0..7 {\n print("n" + str(k), nurbscheck(k))\n}\n'))
    names = ['arcs on their circles', 'knot insertion keeps the curve', 'degree elevation keeps the curve',
             'curve derivatives against differences', 'a NURBS cylinder, knots inserted and degrees raised in u and v',
             'surface derivatives against differences', 'a NURBS torus on the torus']
    for k in range(7):
        e = r.get('n%d' % k, [1])[0]
        tol = 1e-8 if k in (3, 5) else 1e-12
        check(e < tol, f'NURBS: {names[k]} (largest error {e:.2e})')

    # ---- solids from sketches -----------------------------------------------
    code = KERNEL + '''
s = sketch("SBox", "XY")
rect(s, 0, 0, 2, 1)
pad("Box", s, 0.5)
c = sketch("SCyl", "XZ")
circle(c, 10, 0, 1)
pad("Cyl", c, 2)
k = sketch("SCone", "XY")
p0 = point(k, 0, 0)
p1 = point(k, 1, 0)
p2 = point(k, 0, 2)
line(k, p0, p1)
line(k, p1, p2)
line(k, p2, p0)
revolve("Cone", k, 2*P, "v")
t = sketch("STor", "XY")
circle(t, 3, 0, 1)
revolve("Torus", t, 2*P, "v")
q = sketch("SPart", "XY")
circle(q, 3, 0, 1)
revolve("Quarter", q, P/2, "v")
g = sketch("SRing", "XY")
rect(g, -2, -1, 4, 2)
circle(g, 0, 0, 0.5)
pad("Plate", g, 0.3)
'''
    for n in ('Box', 'Cyl', 'Cone', 'Torus', 'Quarter', 'Plate'):
        code += stats(n, n)
    # the sphere: its half disc turned about its straight side (the sketch's v)
    code += '''
hb = sketch("SBall2", "XY")
arc(hb, 0, 0, 1, -P/2, P/2)
line(hb, 0, 1, 0, -1)
revolve("Ball", hb, 2*P, "v")
''' + stats('Ball', 'Ball') + 'print("kinds", brep("Cyl", "cylinders"), brep("Cyl", "planes"), brep("Cone", "cones"), ' \
        'brep("Ball", "spheres"), brep("Torus", "tori"), brep("Plate", "cylinders"))\n'
    want = {'Box': (1.0, 7.0), 'Cyl': (2 * P, 6 * P), 'Cone': (2 * P / 3, None), 'Torus': (6 * P * P, 12 * P * P),
            'Quarter': (6 * P * P / 4, None), 'Plate': (2.4 - P * 0.25 * 0.3, None), 'Ball': (4 * P / 3, 4 * P)}
    for n, (v, a) in want.items():
        code += errs(n, 'e' + n, v, a)
    r = rows(run(code))
    for n, (v, a) in want.items():
        f = r.get(n, [0] * 6)
        e = r.get('e' + n, [1, 1])
        ok = (isinstance(e[0], float) and abs(e[0]) < 1e-9 and abs(e[1]) < 1e-9
              and f[3] == 1 and f[4] == 1 and f[5] == 1)
        check(ok, f'{n}: a valid, watertight B-rep with the exact volume{" and area" if a else ""} '
                  f'(relative errors {e[0]:.1e}, {e[1]:.1e}; {int(f[2]) if isinstance(f[2], float) else f[2]} faces)')
    check(r.get('kinds') == [2, 2, 2, 2, 4, 2],
          f'the surfaces: cylinders, planes, cones, spheres, tori ({r.get("kinds")})')

    # ---- booleans -------------------------------------------------------------
    code = KERNEL + '''
s = sketch("S1", "XY")
rect(s, 0, 0, 4, 2)
pad("Box", s, 1)
k = sketch("Cut", "XY", 1)
rect(k, 1, 0.5, 2, 1)
pocket("Box", k, 0.4)
s2 = sketch("S2", "XY")
rect(s2, 10, 0, 4, 2)
pad("Plate", s2, 0.5)
h = sketch("Drill", "XY", 0.5)
point(h, 12, 1)
hole("Plate", h, 1)
s3 = sketch("S3", "XY")
rect(s3, 20, 0, 4, 2)
pad("Step", s3, 1)
t = sketch("Top", "XY", 1)
rect(t, 21, 0.5, 1, 1)
pad("Step", t, 0.5)
c = sketch("RodS", "XY")
circle(c, 30, 0, 1)
pad("Rod", c, 4)
x = sketch("Cross", "XZ", 0)
point(x, 30, -2)
hole("Rod", x, 0.6)
s4 = sketch("S4", "XY")
rect(s4, 40, -2, 4, 4)
pad("Holes", s4, 0.5)
hs = sketch("Hs", "XY", 0.5)
point(hs, 41, -1)
point(hs, 43, -1)
point(hs, 41, 1)
point(hs, 43, 1)
hole("Holes", hs, 0.5)
b = sketch("S5", "XY")
rect(b, 50, 0, 3, 2)
pd = pad("Cup", b, 2)
shell("Cup", pd, 0.2)
'''
    for n in ('Box', 'Plate', 'Step', 'Rod', 'Holes', 'Cup'):
        code += stats(n, n)
    code += 'print("tess", brep("Rod", "tessvolume"), brep("Rod", "triangles"), efaces("Rod"))\n'
    # the rod: a blind hole (r 0.3, along y at z = 2) from the rod's surface
    # to y = ov (the tool's 2% overshoot past the sketch plane)
    ov = (math.sqrt(4 + 16) * 3 + 1) * 0.02
    xs, ws = leggauss(400)
    hole = 0.0
    for xr, wr in zip(xs, ws):
        rr = (xr + 1) / 2 * 0.3
        for xt, wt in zip(xs, ws):
            x = rr * math.cos((xt + 1) * P)
            hole += wr * wt * 0.15 * P * rr * (ov + math.sqrt(1 - x * x))
    want = {'Box': (8 - 2 * 0.4, 'a pocket'), 'Plate': (4 - P * 0.25 * 0.5, 'a hole (plane and cylinder: exact circles)'),
            'Step': (8.5, 'a boss padded on a face (coplanar faces)'),
            'Rod': (4 * P - hole, 'a hole drilled across a rod (a traced cylinder-cylinder intersection)'),
            'Holes': (8 - 4 * P * 0.0625 * 0.5, 'four holes'), 'Cup': (12 - 2.6 * 1.6 * 1.8, 'a shell')}
    for n, (v, what) in want.items():
        code += errs(n, 'e' + n, v)
    r = rows(run(code))
    for n, (v, what) in want.items():
        f = r.get(n, [0] * 6)
        e = r.get('e' + n, [1])[0]
        tol = 1e-7 if n == 'Rod' else 1e-9
        ok = isinstance(e, float) and abs(e) < tol and f[3] == 1 and f[4] == 1 and f[5] == 1
        check(ok, f'boolean: {what}: valid, watertight, the volume to {tol:g} (relative error {e:.1e})')
    t = r.get('tess', [0, 0, 0])
    check(isinstance(t[0], float) and rel(t[0], 4 * P - hole) < 0.01 and t[1] == t[2] and t[1] > 100,
          f'the tessellation encloses the volume to its chord error and is the object\'s mesh '
          f'({t[0]}, {t[1]} triangles, mesh {t[2]})')

    # ---- fillets, chamfers --------------------------------------------------
    code = KERNEL + '''
s = sketch("BoxS", "XZ")
rect(s, 0, 0, 4, 2)
pad("Box", s, 1)
fillet("Box", 0.3, "vertical")
t = sketch("BoxT", "XZ")
rect(t, 10, 0, 4, 2)
pad("Cham", t, 1)
chamfer("Cham", 0.2, "vertical")
''' + stats('Box', 'Fillet') + stats('Cham', 'Chamfer') + 'print("fk", brep("Box", "cylinders"))\n'
    fv = (('Fillet', 'Box', 8 - 4 * (0.09 - P * 0.09 / 4)), ('Chamfer', 'Cham', 8 - 4 * 0.02))
    for n, o, v in fv:
        code += errs(o, 'e' + n, v)
    r = rows(run(code))
    for n, o, v in fv:
        f = r.get(n, [0] * 6)
        e = r.get('e' + n, [1])[0]
        ok = isinstance(e, float) and abs(e) < 1e-9 and f[3] == 1 and f[4] == 1
        check(ok, f'{n.lower()}: four vertical edges, valid, watertight, exact (relative error {e:.1e}, '
                  f'{int(f[2])} faces)')
    check(r.get('fk') == [4], f'... the fillets are cylinders ({r.get("fk")})')

    # ---- the enclosure walkthrough on the kernel ----------------------------
    enc = open(os.path.join(HERE, 'enclosure.bees')).read()
    enc = enc.replace('op("file.export_3mf", "~/BeeModel/enclosure.3mf")', '').replace(
        'op("file.export_pdf", "~/BeeModel/enclosure.pdf")', '').replace(
        'op("file.export_3mf", "~/BeeModel/enclosure-wide.3mf")', '')
    mesh = rows(run(enc))
    t0 = time.time()
    lines = run('op("cad.kernel", "on")\n' + enc.replace('param("w", "100mm")', stats('Case', 'case80') +
                stats('Lid', 'lid80') + 'param("w", "100mm")') + stats('Case', 'case100') + stats('Lid', 'lid100')
                + 'op("file.save", "~/enclosure.bee")\n')
    dt = time.time() - t0
    r = rows(lines)
    st = [l.split()[1] for l in lines if l.startswith('status ')]
    check(len(st) == 2 and all(set(x) == {'0'} for x in st),
          f'every feature builds, before and after the change ({st})')
    for tag, mv in (('case80', mesh['case'][0]), ('lid80', mesh['case'][3]), ('case100', mesh['wider'][0]),
                    ('lid100', mesh['wider'][2])):
        f = r.get(tag, [0] * 6)
        ok = (f[5] == 1 and f[3] == 1 and f[4] == 1 and isinstance(f[0], float) and rel(f[0], mv) < 0.01)
        check(ok, f'enclosure {tag}: a valid, watertight B-rep within 1% of the mesh replay\'s volume '
                  f'({f[0]} vs {mv}, {f[2]} faces)')
    check(dt < 60, f'the walkthrough builds on the kernel in {dt:.1f} s')
    r = rows(run('op("file.open", "~/enclosure.bee")\n' + stats('Case', 'opened')))
    f = r.get('opened', [0] * 6)
    check(f[5] == 1 and f[3] == 1, f'the switch is saved with the file: opened, the case is a B-rep again ({f})')
    r = rows(run('op("file.open", "~/enclosure.bee")\nop("cad.kernel", "off")\nprint("off", brep("Case", "kernel"), '
                 'round(volume("Case")))\n'))
    check(r.get('off', [1])[0] == 0 and r['off'][1] == mesh['wider'][0],
          f'cad.kernel off: the mesh replay again ({r.get("off")})')

    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nB-rep kernel: all checks passed')
    sys.exit(1 if FAILS else 0)


def leggauss(n):
    """Gauss-Legendre nodes and weights (Newton on the Legendre polynomials)"""
    xs, ws = [], []
    for i in range(1, n + 1):
        x = math.cos(math.pi * (i - 0.25) / (n + 0.5))
        for _ in range(100):
            p0, p1 = 1.0, x
            for k in range(2, n + 1):
                p0, p1 = p1, ((2 * k - 1) * x * p1 - (k - 1) * p0) / k
            dp = n * (x * p1 - p0) / (x * x - 1)
            dx = p1 / dp
            x -= dx
            if abs(dx) < 1e-16:
                break
        xs.append(x)
        ws.append(2 / ((1 - x * x) * dp * dp))
    return xs, ws


if __name__ == '__main__':
    main()
