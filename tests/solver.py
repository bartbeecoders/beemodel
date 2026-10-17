#!/usr/bin/env python3
"""The rigid-body solver (2.0 plan, stage R).

R1: stacks that stand - a tower of 20 boxes and a 10-layer brick pyramid
settle within the first second (a few mm: soft contacts give a little under
the weight above) and then stand still to 10 s; a 1 kg box rests on a
100 kg one and the other way round (substeps, soft contacts, face clipping).

R2: many bodies - 10 800 balls (instances of 12 objects' geometry nodes,
each a body) poured into a box: none get out, 10 s simulated in under 30 s
on 8 threads; 5000 bricks settle at 24 frames a second or better; instance
bodies baked into the cache and played back; the same heap on 1 and 8
threads; files from v0.16 (room for 1024 bodies) still open.

R3: static meshes and planes - balls and boxes dropped into a bowl (a
sphere's mesh) stay in it and come to rest; boxes rest on a staircase's
steps; a box slides down a ramp of many triangles without catching on
their edges (inactive edges: the face's normal); 1000 balls on a terrain
of 100 000 triangles run live; an endless plane catches a box 500 m out.

R4: fast bodies, groups, materials - a 1 cm ball at 100 and 300 m/s and a
tumbling 10 cm box at 60 m/s stop at a 1 cm wall (speculative contacts,
continuous collision); two groups that ignore each other pass through
each other but not the ground; rubber bounces higher than wood.

    python3 tests/solver.py build/beemodel
"""
import os, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


CI = bool(os.environ.get('CI'))
SLOW = 3 if CI else 1                   # (time budgets on shared CI machines)
HERE = os.path.dirname(os.path.abspath(__file__))


def run(code, timeout=900, threads=None):
    home = tempfile.mkdtemp(prefix='bee-solver-')
    os.makedirs(os.path.join(home, 'BeeModel'), exist_ok=True)
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    if threads is not None:
        env['BEEMODEL_THREADS'] = str(threads)
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(r.stdout[-1500:], r.stderr[-1500:])
    return [l.split() for l in r.stdout.splitlines() if l.strip()]


WORLD = os.environ.get('SOLVER_WORLD', '')      # (other world settings to try)
GROUND = ((f'op("rigid.world", "{WORLD}")\n' if WORLD else '') + 'delete("Cube")\ndelete("Light")\ndelete("Camera")\n'
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


LATTICE = ('t = gtree("Lattice")\no = gnode(t, "output")\ng = gnode(t, "grid", 6, 29)\n'
           's = gnode(t, "sphere", 0.09)\nip = gnode(t, "instance", 0, 0, 0)\n'
           'glink(t, g, ip, 1)\nglink(t, s, ip, 2)\nglink(t, ip, o, 1)\n')

POUR = GROUND.replace('scale("Ground", 30)', 'scale("Ground", 20)') + (
    'w = 3.5\nadd("cube", "W1", -w, 2, 0)\nscale("W1", 0.1, 2, w)\nadd("cube", "W2", w, 2, 0)\nscale("W2", 0.1, 2, w)\n'
    'add("cube", "W3", 0, 2, -w)\nscale("W3", w, 2, 0.1)\nadd("cube", "W4", 0, 2, w)\nscale("W4", w, 2, 0.1)\n'
    'select("W1", "W2", "W3", "W4")\nop("rigid.add", "passive box")\n' + LATTICE +
    'for k in 0..12 {\n n = "L" + str(k)\n add("cube", n, 0.03 * (k % 3), 0.5 + k * 0.22, 0.03 * (k % 2))\n'
    ' m = modifier(n, "geometry")\n modset(n, m, "tree", t)\n select(n)\n op("rigid.add", "active sphere instances")\n}\n'
    'frame(2)\nt0 = clock()\nframe(241)\nprint("pour", rbinfo(0), clock() - t0, rbinfo(14))\n'
    'lo = 99\nout = 0\nfor k in 0..12 { for i in 0..900 {\n n = "L" + str(k)\n y = instpos(n, i, 1)\n'
    ' if y < lo { lo = y }\n if abs(instpos(n, i, 0)) > 3.45 or abs(instpos(n, i, 2)) > 3.45 { out += 1 }\n} }\n'
    'print("inside", lo, out)\n')

BRICKS = GROUND + (
    't = gtree("Bricks")\no = gnode(t, "output")\ng = gnode(t, "grid", 10, 24)\nc = gnode(t, "cube", 0.3)\n'
    'ip = gnode(t, "instance", 0, 0, 0)\nglink(t, g, ip, 1)\nglink(t, c, ip, 2)\nglink(t, ip, o, 1)\n'
    'for k in 0..8 {\n n = "B" + str(k)\n add("cube", n, 0.15 * (k % 2), 0.2 + k * 0.35, 0.15 * (k % 2))\n'
    ' m = modifier(n, "geometry")\n modset(n, m, "tree", t)\n select(n)\n op("rigid.add", "active box instances")\n}\n'
    'frame(2)\nsum = 0\nnf = 0\nfor f in 3..181 {\n frame(f)\n if rbinfo(2) > 4000 {\n  sum += rbinfo(4)\n  nf += 1\n }\n}\n'
    'print("bricks", rbinfo(0), nf, sum / max(nf, 1), rbinfo(2))\n')

CACHE = GROUND + LATTICE.replace('"grid", 6, 29', '"grid", 3, 9') + (
    'add("cube", "Balls", 0, 2, 0)\nm = modifier("Balls", "geometry")\nmodset("Balls", m, "tree", t)\n'
    'select("Balls")\nop("rigid.add", "active sphere instances")\n'
    'frame(40)\na = instpos("Balls", 7, 1)\nb = instpos("Balls", 42, 0)\n'
    'op("sim.bake", "rigid")\nframe(1)\nprint("start", instpos("Balls", 7, 1))\n'
    'frame(40)\nprint("cached", abs(instpos("Balls", 7, 1) - a) < 1e-5, abs(instpos("Balls", 42, 0) - b) < 1e-5, cacheinfo(0) > 0)\n'
    'op("file.save", "~/BeeModel/inst.bee")\nop("file.new")\nop("file.open", "~/BeeModel/inst.bee")\n'
    'frame(40)\nprint("reopened", abs(instpos("Balls", 7, 1) - a) < 1e-5)\n')

OLD = ('op("file.open", "%s")\nprint("old", rigid("B", "mass"), rigid("C", "shape"), keyed("Cube:x", 25), rbinfo(0))\n'
       'frame(30)\nprint("oldsim", round(get("B", "y") * 100), rbinfo(0))\n')

HEAP = ('delete("Cube")\nadd("plane", "Ground", 0, 0, 0)\nscale("Ground", 40)\n'
        'for k in 0..10 {\n for i in 0..10 {\n  for j in 0..10 {\n   n = "B" + str(k * 100 + i * 10 + j)\n'
        '   add("cube", n, i * 1.2 - 6 + 0.6 * (k % 2), 1 + k * 1.2, j * 1.2 - 6 + 0.6 * (k % 2))\n'
        '   rotate(n, 0.1 * k, 0.37 * k + 0.1 * i, 0.05 * j)\n   scale(n, 0.5)\n  }\n }\n}\n'
        'select()\nop("object.select_all")\nop("rigid.add", "active box")\nselect("Ground")\nop("rigid.add", "passive box")\n'
        'frame(121)\nprint("heap", rbinfo(1), get("B555", "x"), get("B555", "y"), get("B555", "z"))\n')


BOWL = ('delete("Cube")\ndelete("Light")\ndelete("Camera")\n'
        'add("sphere", "Bowl", 0, 3, 0)\nscale("Bowl", 3)\nselect("Bowl")\nop("rigid.add", "passive mesh")\n'
        'for i in 0..25 {\n n = "S" + str(i)\n add("sphere", n, (i % 5) * 0.5 - 1, 2 + (i / 5) * 0.45, ((i / 5) % 3) * 0.3 - 0.3)\n'
        ' scale(n, 0.2)\n select(n)\n op("rigid.add", "active sphere")\n}\n'
        'for i in 0..8 {\n n = "B" + str(i)\n add("cube", n, (i % 4) * 0.7 - 1, 4.4, (i / 4) * 0.7 - 0.35)\n'
        ' scale(n, 0.25)\n select(n)\n op("rigid.add", "active box")\n}\n'
        'fn dist(n) { return sqrt(pow(get(n, "x"), 2) + pow(get(n, "y") - 3, 2) + pow(get(n, "z"), 2)) }\n'
        'frame(301)\nfar = 0\nfor i in 0..25 { far = max(far, dist("S" + str(i))) }\n'
        'for i in 0..8 { far = max(far, dist("B" + str(i))) }\nprint("bowl", far, rbinfo(2), rbinfo(7))\n')

STAIRS = ('delete("Cube")\ndelete("Light")\ndelete("Camera")\n'
          't = gtree("Stairs")\no = gnode(t, "output")\nl = gnode(t, "line", 6, 0.6, 0.3, 0)\nc = gnode(t, "cube", 0.6)\n'
          'ip = gnode(t, "instance", 0, 0, 0)\nglink(t, l, ip, 1)\nglink(t, c, ip, 2)\nr = gnode(t, "realize")\n'
          'glink(t, ip, r, 1)\nglink(t, r, o, 1)\nadd("cube", "St", 0, 0.3, 0)\nm = modifier("St", "geometry")\n'
          'modset("St", m, "tree", t)\nscale("St", 1, 1, 4)\nselect("St")\nop("rigid.add", "passive mesh")\n'
          'add("plane", "Floor", 0, 0, 0)\nselect("Floor")\nop("rigid.add", "passive plane")\n'
          'for i in 0..6 {\n n = "B" + str(i)\n add("cube", n, i * 0.6, 2.5 + i * 0.4, (i % 3) * 0.5 - 0.5)\n'
          ' scale(n, 0.2)\n select(n)\n op("rigid.add", "active box")\n}\n'
          'frame(241)\ns = ""\nfor i in 0..6 { s = s + " " + str(round(get("B" + str(i), "y") * 100)) }\n'
          'print("stairs" + s)\nprint("asleep", rbinfo(2))\n')

RAMP = ('delete("Cube")\ndelete("Light")\ndelete("Camera")\n'
        't = gtree("RampT")\no = gnode(t, "output")\ng = gnode(t, "grid", 12, %d)\nglink(t, g, o, 1)\n'
        'add("cube", "Ramp", 0, 0, 0)\nm = modifier("Ramp", "geometry")\nmodset("Ramp", m, "tree", t)\n'
        'rotate("Ramp", rad(15), 0, 0)\nselect("Ramp")\nop("rigid.add", "passive mesh friction 0.05")\n'
        's = sin(rad(15))\ncc = cos(rad(15))\nadd("cube", "B", 0.13, 0.26 * cc + 4 * s, -4 * cc + 0.26 * s)\n'
        'scale("B", 0.25)\nrotate("B", rad(15), 0, 0)\nselect("B")\nop("rigid.add", "active box friction 0.05")\n'
        'up = 0\ntw = 0\nfor f in 2..60 {\n frame(f)\n h = get("B", "y") * cc + get("B", "z") * s\n'
        ' if f > 8 {\n  up = max(up, abs(h - 0.25))\n  tw = max(tw, abs(get("B", "rx") - rad(15)) + abs(get("B", "ry")) + abs(get("B", "rz")))\n }\n}\n'
        'print("ramp", up, tw, get("B", "z"))\n')

TERRAIN = ('delete("Cube")\ndelete("Light")\ndelete("Camera")\n'
           't = gtree("Land")\no = gnode(t, "output")\ng = gnode(t, "terrain", 24, 224, 2, 7)\nglink(t, g, o, 1)\n'
           'add("cube", "Land", 0, 0, 0)\nm = modifier("Land", "geometry")\nmodset("Land", m, "tree", t)\n'
           'select("Land")\nop("rigid.add", "passive mesh")\n'
           'b = gtree("Balls")\nbo = gnode(b, "output")\nbg = gnode(b, "grid", 16, 9)\nbs = gnode(b, "sphere", 0.2)\n'
           'bi = gnode(b, "instance", 0, 0, 0)\nglink(b, bg, bi, 1)\nglink(b, bs, bi, 2)\nglink(b, bi, bo, 1)\n'
           'for k in 0..10 {\n n = "Ba" + str(k)\n add("cube", n, 0.4 * (k % 2), 4 + k * 0.5, 0.3 * (k % 3))\n'
           ' mm = modifier(n, "geometry")\n modset(n, mm, "tree", b)\n select(n)\n op("rigid.add", "active sphere instances")\n}\n'
           'frame(2)\nprint("parts", rbinfo(7))\nworst = 0\nsum = 0\nfor f in 3..73 {\n frame(f)\n sum += rbinfo(4)\n worst = max(worst, rbinfo(4))\n}\n'
           'lo = 99\nfor k in 0..10 { for i in 0..100 {\n n = "Ba" + str(k)\n'
           ' if abs(instpos(n, i, 0)) < 11.5 and abs(instpos(n, i, 2)) < 11.5 { lo = min(lo, instpos(n, i, 1)) }\n} }\n'
           'print("terrain", worst, sum / 70, lo)\n')

PLANE = ('delete("Cube")\nadd("plane", "P", 0, 0, 0)\nselect("P")\nop("rigid.add", "passive plane")\n'
         'add("cube", "F", 500, 2, -300)\nscale("F", 0.5)\nrotate("F", 0.3, 0.2, 0.1)\nselect("F")\nop("rigid.add", "active box")\n'
         'frame(121)\nprint("plane", get("F", "y"), rbinfo(2))\n')


FAST = ('delete("Cube")\nop("rigid.world", "gravity 0 0 0")\n'
        'add("cube", "W1", 5, 1, 0)\nscale("W1", 0.005, 1, 1)\nadd("cube", "W2", 5, 1, 3)\nscale("W2", 0.005, 1, 1)\n'
        'add("cube", "W3", 5, 1, 6)\nscale("W3", 0.005, 1, 1)\nselect("W1", "W2", "W3")\nop("rigid.add", "passive box")\n'
        'add("sphere", "S1", 0, 1, 0)\nscale("S1", 0.005)\nselect("S1")\nop("rigid.add", "active sphere velocity 100 0 0")\n'
        'add("sphere", "S2", 0, 1, 3)\nscale("S2", 0.005)\nselect("S2")\nop("rigid.add", "active sphere velocity 300 0 0")\n'
        'add("cube", "B", 0, 1, 6)\nscale("B", 0.05)\nrotate("B", 0.3, 0.5, 0.2)\nselect("B")\n'
        'op("rigid.add", "active box velocity 60 0 0")\nframe(49)\n'
        'print("fast", get("S1", "x"), get("S2", "x"), get("B", "x"))\n')

GROUPS = ('delete("Cube")\nadd("plane", "G", 0, 0, 0)\nscale("G", 10)\nselect("G")\nop("rigid.add", "passive box")\n'
          'add("cube", "Low", 0, 0.5, 0)\nscale("Low", 0.5)\nselect("Low")\nop("rigid.add", "active box group 1 collide 1")\n'
          'add("cube", "High", 0, 2, 0)\nscale("High", 0.5)\nselect("High")\nop("rigid.add", "active box group 2 collide 1")\n'
          'add("cube", "Third", 3, 0.5, 0)\nscale("Third", 0.5)\nselect("Third")\nop("rigid.add", "active box")\n'
          'add("cube", "Top", 3, 2, 0)\nscale("Top", 0.5)\nselect("Top")\nop("rigid.add", "active box")\n'
          'frame(121)\nprint("groups", round(get("Low", "y") * 100), round(get("High", "y") * 100), round(get("Top", "y") * 100), rigid("High", "group"))\n')

BOUNCE = ('delete("Cube")\nadd("plane", "G", 0, 0, 0)\nscale("G", 10)\nselect("G")\nop("rigid.add", "passive box")\n'
          'add("sphere", "R", 0, 3, 0)\nscale("R", 0.2)\nselect("R")\nop("rigid.add", "active sphere material rubber")\n'
          'add("sphere", "W", 3, 3, 0)\nscale("W", 0.2)\nselect("W")\nop("rigid.add", "active sphere material wood")\n'
          'hr = 0\nhw = 0\nlow = 0\nfor f in 2..60 {\n frame(f)\n if get("R", "y") < 0.3 { low = 1 }\n'
          ' if low == 1 { hr = max(hr, get("R", "y"))\n  hw = max(hw, get("W", "y")) }\n}\n'
          'print("bounce", hr, hw, rigid("R", "bounce"), rigid("W", "friction"))\n')


# two hanging chains of 20 kg links: one whose top joint gives at 900 N (it
# holds 980 N), one whose top holds 2000 N (the others: 1500 N, they hold
# 784 N and less)
JOINTS = GROUND + (
    'fn chain(c, x, top) {\n for i in 0..5 {\n  n = c + str(i)\n  add("cube", n, x, 5 - i * 0.5, 0)\n  scale(n, 0.2)\n'
    '  select(n)\n  op("rigid.add", "active box mass 20")\n }\n'
    ' op("rigid.joint", "point " + c + "0 world pivot " + str(x) + " 5.25 0 break " + str(top))\n'
    ' for i in 0..4 { op("rigid.joint", "point " + c + str(i) + " " + c + str(i + 1) + " pivot " + str(x) + " " + str(4.75 - i * 0.5) + " 0 break 1500") }\n}\n'
    'chain("C", 0, 900)\nchain("H", 3, 2000)\n'
    'add("cube", "Arm", 1, 5, 3)\nscale("Arm", 1, 0.1, 0.1)\nselect("Arm")\nop("rigid.add", "active box mass 10")\n'
    'op("rigid.joint", "hinge Arm world pivot 0 5 3 axis 0 0 1 motor 90 1000")\n'
    'add("cube", "Lim", 1, 5, -3)\nscale("Lim", 1, 0.1, 0.1)\nselect("Lim")\nop("rigid.add", "active box mass 10")\n'
    'op("rigid.joint", "hinge Lim world pivot 0 5 -3 axis 0 0 1 limits -30 30")\n'
    'add("cube", "Sl", 5, 5, 0)\nscale("Sl", 0.3)\nselect("Sl")\nop("rigid.add", "active box mass 5")\n'
    'op("rigid.joint", "slider Sl world axis 0 1 0 limits -1 0.5")\n'
    'add("cube", "Sm", -5, 5, 0)\nscale("Sm", 0.3)\nselect("Sm")\nop("rigid.add", "active box mass 5")\n'
    'op("rigid.joint", "slider Sm world axis 1 0 0 motor 1 100")\n'
    'lim = -9\nfor f in 1..50 {\n frame(f)\n lim = max(lim, abs(get("Lim", "rz")))\n'
    ' if f == 12 { print("chain", rbinfo(15), get("C0", "y"), get("C3", "y") - get("C4", "y")) }\n'
    ' if f == 25 { a0 = get("Arm", "rz")\n s0 = get("Sm", "x") }\n}\n'
    'print("held", rbinfo(15), get("H0", "y"), get("H4", "y"))\n'
    'print("motor", (get("Arm", "rz") - a0) * 57.29578, get("Sm", "x") - s0, get("Sm", "y"))\n'
    'print("limits", lim * 57.29578, get("Lim", "rz") * 57.29578, get("Sl", "y"), get("Sl", "x"))\n')


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
    print('  -- the solver: many bodies --')
    eight = 7 if (os.cpu_count() or 1) >= 8 else None      # (8 threads)
    r = {x[0]: x[1:] for x in run(POUR, threads=eight) if x}
    p, ins = r.get('pour', ['0', '1e9', '1']), r.get('inside', ['-99', '1'])
    ms = float(p[1])
    check(p[0] == '10805' and p[2] == '0' and float(ins[0]) > 0.08 and ins[1] == '0'
          and ms < 30000 * SLOW,
          f'10 800 balls (instances, 12 objects) poured into a box: none get out (lowest {float(ins[0]):.3f} m), '
          f'10 s simulated in {ms / 1000:.1f} s on {"8" if eight else "all the"} threads')
    r = {x[0]: x[1:] for x in run(BRICKS, threads=eight) if x}
    b = r.get('bricks', ['0', '0', '1e9', '1'])
    check(b[0] == '5001' and int(b[1]) > 20 and float(b[2]) < 41.7 * 1.15 * SLOW and b[3] == '0',
          f'5000 bricks settle: {float(b[2]):.1f} ms a frame while they move ({int(b[1])} frames; 41.7 = 24 fps), '
          f'then sleep')
    r = {x[0]: x[1:] for x in run(CACHE) if x}
    check(r.get('start') == ['2'] and r.get('cached') == ['1', '1', '1'] and r.get('reopened') == ['1'],
          f'instance bodies baked: back at the start, played from the cache, saved and opened again ({r})')
    old = os.path.join(HERE, 'fixtures', 'physics', 'anim016.bee')
    r = {x[0]: x[1:] for x in run(OLD % old) if x}
    check(r.get('old', [])[:3] == ['7', '1', '4'] and r.get('oldsim') == ['100', '3'],
          f'a v0.16 file (room for 1024 bodies) opens: bodies, a joint, keys, it simulates ({r})')
    one = {x[0]: x[1:] for x in run(HEAP, threads=0) if x}.get('heap')
    many = {x[0]: x[1:] for x in run(HEAP, threads=eight) if x}.get('heap')
    check(one is not None and one == many, f'1000 boxes: the same heap on one thread and on eight ({one}, {many})')
    print('  -- the solver: meshes and planes --')
    r = {x[0]: x[1:] for x in run(BOWL) if x}
    b = r.get('bowl', ['99', '1', '0'])
    check(float(b[0]) < 2.82 and b[1] == '0' and int(b[2]) > 900,
          f'25 balls and 8 boxes in a bowl (its mesh, {int(b[2]) - 33} triangles): they stay in it (the farthest '
          f'{float(b[0]):.3f} m from the middle: 2.8 inside) and come to rest')
    r = {x[0]: x[1:] for x in run(STAIRS) if x}
    ys = [int(v) for v in r.get('stairs', [])]
    want = [80, 110, 140, 170, 200, 230]
    check(len(ys) == 6 and all(abs(a - b) <= 2 for a, b in zip(ys, want)) and r.get('asleep') == ['0'],
          f'boxes dropped on a staircase (one mesh) rest on its steps ({ys} cm; {want})')
    for n, label in ((1, 'two triangles'), (48, '4608 triangles')):
        r = {x[0]: x[1:] for x in run(RAMP % n) if x}
        up, tw, z = [float(v) for v in r.get('ramp', ['9', '9', '-9'])]
        check(up < 0.005 and tw < 0.05 and z > 1.0,
              f'a box slides down a ramp of {label} without catching on their edges (off the face by '
              f'{up * 1000:.1f} mm at most, turned {tw:.3f} rad)')
    r = {x[0]: x[1:] for x in run(TERRAIN, threads=eight) if x}
    t = [float(v) for v in r.get('terrain', ['1e9', '1e9', '-99'])]
    parts = int(r.get('parts', ['0'])[0])
    check(parts > 100000 and t[0] < 41.7 * SLOW and t[2] > -2.5,
          f'1000 balls on a terrain of {parts - 1000} triangles: live (the slowest frame {t[0]:.0f} ms, '
          f'{t[1]:.1f} on average), none through it')
    r = {x[0]: x[1:] for x in run(PLANE) if x}
    p = r.get('plane', ['0', '1'])
    check(abs(float(p[0]) - 0.5) < 0.01 and p[1] == '0', f'an endless plane catches a box 500 m out ({p})')
    print('  -- the solver: fast bodies, groups, materials --')
    r = {x[0]: x[1:] for x in run(FAST) if x}
    v = [float(x) for x in r.get('fast', ['99', '99', '99'])]
    check(4.9 < v[0] < 4.995 and 4.9 < v[1] < 4.995 and v[2] < 4.995,
          f'a 1 cm ball at 100 and 300 m/s and a turning 10 cm box at 60 m/s stop at a 1 cm wall (x {v}; the wall '
          f'at 4.995)')
    r = {x[0]: x[1:] for x in run(GROUPS) if x}
    g = r.get('groups', [])
    check(g == ['50', '50', '150', '2'],
          f'groups: a box ignoring the one below falls through it to the ground; others stack ({g})')
    r = {x[0]: x[1:] for x in run(BOUNCE) if x}
    b = [float(x) for x in r.get('bounce', ['0', '0', '0', '0'])]
    check(b[0] > 1.0 and b[1] < 0.5 and abs(b[2] - 0.8) < 1e-6 and abs(b[3] - 0.5) < 1e-6,
          f'materials: rubber bounces back to {b[0]:.2f} m, wood to {b[1]:.2f} m (from 3 m)')
    print('  -- the solver: joints --')
    r = {x[0]: [float(v) for v in x[1:]] for x in run(JOINTS) if x}
    c, h = r.get('chain', [0] * 3), r.get('held', [0] * 3)
    check(c[0] == 1 and c[1] < 4.9 and abs(c[2] - 0.5) < 0.01,
          f'a chain pulled past its top joint\'s strength breaks there and falls whole ({c})')
    check(abs(h[1] - 5) < 0.02 and abs(h[2] - 3) < 0.05,
          f'a chain whose joints hold it hangs on (its end at {h[2]:.3f} m; the other\'s broke where it landed: '
          f'{h[0]:.0f} broken)')
    m = r.get('motor', [0] * 3)
    check(abs(m[0] - 90) < 3 and abs(m[1] - 1) < 0.03 and abs(m[2] - 5) < 0.01,
          f'motors: a loaded arm turns at {m[0]:.1f} degrees/s (90), a slider moves {m[1]:.3f} m in 1 s (1)')
    lm = r.get('limits', [99, 0, 0, 0])
    check(lm[0] < 31 and abs(lm[1] + 30) < 0.5 and abs(lm[2] - 4) < 0.01 and abs(lm[3] - 5) < 1e-4,
          f'limits: a hinge swings to {lm[1]:.1f} degrees (no further than {lm[0]:.1f}; -30), a slider drops to '
          f'{lm[2]:.3f} m (4)')
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nthe solver: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
