#!/usr/bin/env python3
"""Shatter (2.0 plan, stage S).

S1: cutting a closed mesh into cells - a cube, a torus and a vase (concave,
thin walled; an OBJ made here) cut into 100 cells each: every piece is
closed, the pieces' volumes add up to the original's within 1e-6, and no
piece is a sliver (under 1e-5 of the mean). An open mesh is repaired
first; mesh.separate_loose splits a mesh into its loose parts.

S2: the patterns - a 2 x 1 x 0.2 m wall into 10 x 5 bricks (50 without a
row offset, 52 in a running bond: half bricks at the ends), each a closed
box of the right size, the wall's material on each and the inner colour on
the cut faces; a mortar gap takes its volume; a sphere into 500 balls, all
inside it and none overlapping; a vase into 50 shards around a point:
smaller near it, the volume kept.

S3: every piece a rigid body - a cube held up in the air shattered into
200 shards: 200 active hull bodies, children of the hidden cube, whose
masses add up to the cube's (its volume x the density); played, they fall,
land on the Ground (none below it) and settle (asleep); in the window
(the fake compositor) Ctrl+Z gives the cube back.

S4: glue - a 2 x 1 x 0.2 m wall of 10 x 5 bricks glued (40 kPa: a joint a
shared face, breaking at the strength x its area) stands on the Ground; a
30 kg ball thrown at it at 20 m/s knocks out a hole about its size (a few
bricks around the hit) and the rest stands; at 4 m/s nothing breaks; the
same on 1 and 8 threads. Glue between shards: one joint a shared face.

    python3 tests/shatter.py build/beemodel
"""
import math, os, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
FAILS = []
CI = bool(os.environ.get('CI'))
SLOW = 3 if CI else 1


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, timeout=600, home=None, threads=None):
    home = home or tempfile.mkdtemp(prefix='bee-shat-')
    os.makedirs(os.path.join(home, 'BeeModel'), exist_ok=True)
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    if threads is not None:
        env['BEEMODEL_THREADS'] = str(threads)
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(r.stdout[-1500:], r.stderr[-1500:])
    return [l.split() for l in r.stdout.splitlines() if l.strip()]


def vals(out, tag):
    """The numbers printed after a tag word."""
    for l in out:
        if l and l[0] == tag:
            return [float(x) for x in l[1:]]
    return None


def vase_obj(path, n=48):
    """A closed vase: an outer wall up to a rim, an inner wall down to a
    thick bottom, revolved about Y (counter-clockwise faces seen from
    outside)."""
    prof = [(0, 0), (0.5, 0), (0.7, 0.3), (0.8, 0.8), (0.5, 1.4), (0.35, 1.7), (0.45, 2.0),
            (0.4, 2.0), (0.3, 1.7), (0.45, 1.4), (0.72, 0.8), (0.62, 0.3), (0.42, 0.1), (0, 0.1)]
    vs, fs = [], []
    idx = {}
    for i, (r, y) in enumerate(prof):
        if r == 0:
            idx[i, 0] = len(vs) + 1
            vs.append((0, y, 0))
            continue
        for k in range(n):
            a = 2 * math.pi * k / n
            idx[i, k] = len(vs) + 1
            vs.append((r * math.cos(a), y, -r * math.sin(a)))
    for i in range(len(prof) - 1):
        for k in range(n):
            k2 = (k + 1) % n
            a = idx[i, 0] if prof[i][0] == 0 else idx[i, k]
            b = idx[i, 0] if prof[i][0] == 0 else idx[i, k2]
            c = idx[i + 1, 0] if prof[i + 1][0] == 0 else idx[i + 1, k2]
            d = idx[i + 1, 0] if prof[i + 1][0] == 0 else idx[i + 1, k]
            f = [a, b, c, d]
            f = [x for j, x in enumerate(f) if x not in f[:j]]
            if len(f) >= 3:
                fs.append(f)
    with open(path, 'w') as o:
        for v in vs:
            o.write('v %.6f %.6f %.6f\n' % v)
        for f in fs:
            o.write('f ' + ' '.join(map(str, f)) + '\n')


STATS = 'for k in 0..11 { print("st", k, shinfo(k)) }\n'


def stats(out):
    st = {}
    for l in out:
        if l and l[0] == 'st' and len(l) >= 3:
            st[int(l[1])] = float(l[2])
    return st


def obj_volume(path):
    """The signed volume of an OBJ's faces (fans), for an independent check."""
    vs, vol = [], 0.0
    for l in open(path):
        p = l.split()
        if p and p[0] == 'v':
            vs.append(tuple(map(float, p[1:4])))
        elif p and p[0] == 'f':
            f = [vs[int(x.split('/')[0]) - 1] for x in p[1:]]
            for i in range(1, len(f) - 1):
                a, b, c = f[0], f[i], f[i + 1]
                vol += (a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0])
                        + a[2] * (b[0] * c[1] - b[1] * c[0])) / 6
    return vol


def s1(tmp):
    print('S1: cutting a closed mesh into cells')
    vase = os.path.join(tmp, 'vase.obj')
    vase_obj(vase)
    vvol = obj_volume(vase)
    for name, setup in (('cube', 'select("Cube")\n'),
                        ('torus', 'delete("Cube")\nop("create.torus")\n'),
                        ('vase', 'delete("Cube")\nop("file.import_obj", "%s")\n' % vase)):
        out = run(setup + 'op("object.shatter", "count 100 seed 7")\n' + STATS)
        st = stats(out)
        if not st:
            check(False, '%s: shattered' % name)
            continue
        check(st[0] >= 100, '%s: 100 cells give %d pieces (concave cells split into their parts)' % (name, st[0]))
        check(st[5] == 0, '%s: every piece is closed (%d open edges)' % (name, st[5]))
        check(st[9] < 1e-6, '%s: the volumes add up to the original (%.3g, error %.2g)' % (name, st[3], st[9]))
        check(st[10] > 1e-5, '%s: no slivers (smallest piece %.3g of the mean)' % (name, st[10]))
        check(st[6] < 2000 * SLOW, '%s: cut in %.0f ms' % (name, st[6]))
        if name == 'vase':
            check(abs(st[3] - vvol) < 1e-5 * vvol, 'vase: its volume as the OBJ has it (%.6f, %.6f)' % (st[3], vvol))
    # an open mesh is repaired first (a cube with its top gone: filled)
    open_cube = os.path.join(tmp, 'open.obj')
    two = os.path.join(tmp, 'two.obj')
    cube_obj(open_cube, top=False)
    cube_obj(two, offsets=(0, 3))
    out = run('delete("Cube")\nop("file.import_obj", "%s")\nop("object.shatter", "count 10")\n' % open_cube + STATS)
    st = stats(out)
    check(st and st[8] > 0 and st[5] == 0 and st[0] >= 10,
          'an open mesh (%s open edges) is repaired, then cut into closed pieces' % (st and st[8]))
    # separate by loose parts: two cubes in one mesh
    out = run('delete("Cube")\nop("file.import_obj", "%s")\nprint("n0", count())\n'
              'op("mesh.separate_loose")\nprint("n1", count())\n' % two)
    n0, n1 = vals(out, 'n0'), vals(out, 'n1')
    check(n0 and n1 and n1[0] == n0[0] + 1, 'mesh.separate_loose: one object a loose part (%s -> %s)' % (n0, n1))


def cube_obj(path, top=True, offsets=(0,)):
    """Unit cubes side by side along X in one OBJ (top faces left out: an
    open mesh)."""
    faces = [(1, 2, 4, 3), (5, 7, 8, 6), (1, 5, 6, 2), (3, 4, 8, 7), (1, 3, 7, 5), (2, 6, 8, 4)]
    with open(path, 'w') as o:
        for n, dx in enumerate(offsets):
            for i in range(8):
                o.write('v %g %g %g\n' % (dx + (i & 1), (i >> 1) & 1, (i >> 2) & 1))
        for n in range(len(offsets)):
            for k, f in enumerate(faces):
                if not top and k == 3:
                    continue
                o.write('f ' + ' '.join(str(x + 8 * n) for x in f) + '\n')


def s2(tmp):
    print('S2: bricks, balls, shards')
    wall = ('scale("Cube", 1, 0.5, 0.1)\nmaterial("Brick")\nassign("Cube", "Brick")\n')
    out = run(wall + 'op("object.shatter", "bricks counts 10 5 1 offset 0 inner 0.8 0.3 0.2")\n' + STATS +
              'n = 0\nv = 0\nm = 0\nbx = 0\nfor i in 1..51 { b = "Cube_brick_" + str(i)\n'
              '  n = n + manifold(b)\n  v = v + volume(b)\n'
              '  if matof(b) == "Brick" { m = m + 1 }\n'
              '  if abs(get(b, "x") - (-0.9 + 0.2 * ((i - 1) % 10))) < 1e-4 { bx = bx + 1 } }\n'
              'print("w", n, v * 0.05, m, bx, verts("Cube_brick_12"), vcol("Cube_brick_12", 8, 0))\n')
    st, w = stats(out), vals(out, 'w')
    check(st and st[0] == 50, 'a 2 x 1 x 0.2 wall into 10 x 5 bricks: %s' % (st and st[0]))
    check(w and w[0] == 0 and st[5] == 0, 'every brick closed; with an inner colour the cut faces have '
          'vertices of their own (manifold %s, open edges before %s)' % (w and w[0], st and st[5]))
    check(w and abs(w[1] - 0.4) < 1e-6, 'the bricks hold the wall\'s 0.4 m^3 (%s)' % (w and w[1]))
    check(w and w[2] == 50, 'each brick has the wall\'s material (%s)' % (w and w[2]))
    check(w and w[3] == 50, 'the bricks lie in their rows, 0.2 m apart (%s)' % (w and w[3]))
    check(w and w[4] > 8 and w[5] == 204, 'a middle brick\'s cut faces have the inner colour (%s vertices, red %s)'
          % (w and w[4], w and w[5]))
    out = run(wall + 'op("object.shatter", "bricks counts 10 5 1 gap 0.02")\n' + STATS +
              'n = 0\nfor i in 1..53 { n = n + manifold("Cube_brick_" + str(i)) }\nprint("m", n)\n')
    st, mf = stats(out), vals(out, 'm')
    check(mf and mf[0] == 52, 'without an inner colour every brick is manifold (%s)' % (mf and mf[0]))
    check(st and st[0] == 52, 'a running bond: 52 bricks (half bricks at the ends of every other row): %s'
          % (st and st[0]))
    # gap 0.02 m: each inner joint takes 0.02 x its face
    check(st and 0.3 < st[2] * 0.05 < 0.39 and st[5] == 0, 'a mortar gap takes its volume (%.4f m^3)' % (st and st[2] * 0.05))
    out = run('delete("Cube")\nop("create.sphere")\nop("object.shatter", "balls count 500")\n'
              'for k in 18..21 { print("st", k, shinfo(k)) }\n' + STATS +
              'out = 0\nfor i in 1..51 { b = "Sphere_ball_" + str(i * 10)\n'
              '  x = get(b, "x")\n  y = get(b, "y")\n  z = get(b, "z")\n'
              '  if sqrt(x*x + y*y + z*z) + 0.8 * get(b, "sx") > 1 { out = out + 1 } }\n'
              'print("b", out, count())\n')
    st, b = stats(out), vals(out, 'b')
    check(st and st[0] == 500 and b and b[1] == 503, 'a sphere into 500 balls (%s objects)' % (b and b[1]))
    check(st and st[19] > -1e-5, 'no two balls overlap (least gap %.2g radii)' % (st and st[19]))
    check(st and st[20] < 0.2 + 1e-6 and b and b[0] == 0, 'every ball inside the sphere: none reaches past it by '
          'more than a fifth of its radius (%.3f; %s of 50 checked out)' % (st and st[20], b and b[0]))
    check(st and 0.08 < st[18] < 0.12, 'radius %.4f: a dense packing' % (st and st[18]))
    vase = os.path.join(tmp, 'vase2.obj')
    vase_obj(vase)
    out = run('delete("Cube")\nop("file.import_obj", "%s")\nmaterial("Clay")\nassign("vase2", "Clay")\n'
              'op("object.shatter", "shards count 50 at 0.7 0.8 0 spread 0.4")\n' % vase + STATS +
              'near = 0\nfar = 0\nnn = 0\nnf = 0\nm = 0\n'
              'for i in 1..51 { s = "vase2_shard_" + str(i)\n'
              '  if matof(s) == "Clay" { m = m + 1 }\n'
              '  dx = get(s, "x") - 0.7\n  dy = get(s, "y") - 0.8\n  dz = get(s, "z")\n'
              '  if sqrt(dx*dx + dy*dy + dz*dz) < 0.4 { near = near + volume(s)\n nn = nn + 1 } else { far = far + volume(s)\n nf = nf + 1 } }\n'
              'print("v", nn, near / max(nn, 1), nf, far / max(nf, 1), m)\n')
    st, v = stats(out), vals(out, 'v')
    check(st and st[0] >= 50 and st[5] == 0 and st[9] < 1e-6,
          'a vase into 50 shards around a point: %s pieces, closed, the volume kept' % (st and st[0]))
    check(v and v[0] >= 5 and v[1] < v[3] / 3, 'the shards are smaller near the point (%s near, mean %.5f; far %.5f)'
          % (v and v[0], v and v[1], v and v[3]))
    check(v and v[4] >= 50, 'each shard has the vase\'s material (%s)' % (v and v[4]))


def s3():
    print('S3: pieces as rigid bodies')
    out = run('op("create.ground")\nmove("Cube", 0, 3, 0)\nselect("Cube")\n'
              'op("object.shatter", "shards count 200 seed 4 density 600")\n' + STATS +
              'for k in 21..23 { print("st", k, shinfo(k)) }\n'
              'h = 0\nm = 0\nfor i in 1..201 { n = "Cube_shard_" + str(i)\n'
              '  h = h + (rigid(n, "type") == 1) * (rigid(n, "shape") == 3)\n  m = m + rigid(n, "mass") }\n'
              'print("b", h, m)\n'
              'frame(1200)\nlow = 100\nfor i in 1..201 { y = get("Cube_shard_" + str(i), "y")\n'
              '  if y < low { low = y } }\nprint("f", rbinfo(0), rbinfo(2), low)\n')
    st, b, fl = stats(out), vals(out, 'b'), vals(out, 'f')
    check(b and b[0] == 200, 'a cube into 200 shards, each an active hull body (%s)' % (b and b[0]))
    check(b and abs(b[1] - 8 * 600) < 1e-2 * 8 * 600 and st and abs(st[21] - 4800) < 1,
          'their masses add up to the cube\'s: 8 m^3 x 600 kg/m^3 (%s kg)' % (b and b[1]))
    check(fl and fl[0] == 201, 'played: 200 bodies and the Ground (the hidden cube is not one): %s' % (fl and fl[0]))
    check(fl and fl[2] > -0.01, 'they land on the Ground, none below it (lowest centre %.3f m)' % (fl and fl[2]))
    check(fl and fl[1] == 0, 'and settle: all asleep after 50 s (%s awake)' % (fl and fl[1]))
    # the window: Ctrl+Z after a shatter
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
    argv = sys.argv
    sys.argv = [argv[0], tempfile.mkdtemp(prefix='bee-shat-shots-')]
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    try:
        f.pump(1.0, until_frame=True)
        f.keymap(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'keymaps', 'us.xkb'))
        m = fakewl.Mcp(f)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
        f.enter(600, 300)
        f.move(600, 300)
        q('select("Cube")')
        f.key(28); f.type('object.shatter shards count 200'); f.key(28); f.pump(0.5); f.key(1)
        n1 = q('print(count())')
        f.mods(4); f.key(44); f.mods(0); f.pump(0.5)          # Ctrl+Z
        n2 = q('print(count())')
        check(n1.split()[:1] == ['203'] and n2 == '3', 'Ctrl+Z gives the cube back: %s objects, then %s' % (n1, n2))
    finally:
        f.proc.kill()


WALL = """op("create.ground")
scale("Cube", 1, 0.5, 0.1)
move("Cube", 0, 0.5, 0)
select("Cube")
op("object.shatter", "bricks counts 10 5 1 glue 40000 density 2000")
n = add("sphere", "Ball", 0.1, 0.45, 1.5)
scale(n, 0.2)
select(n)
op("rigid.add", "active sphere mass 30 velocity 0 0 -%d")
frame(240)
print("h", rbinfo(15), rbinfo(16))
moved = 0
far = 0
for i in 1..53 { b = "Cube_brick_" + str(i)
  frame(1)
  x = get(b, "x")
  y = get(b, "y")
  z = get(b, "z")
  frame(240)
  d = sqrt(pow(get(b, "x") - x, 2) + pow(get(b, "y") - y, 2) + pow(get(b, "z") - z, 2))
  if d > 0.05 { moved = moved + 1
    if sqrt(pow(x - 0.1, 2) + pow(y - 0.45, 2)) > 0.5 { far = far + 1 } } }
print("w", moved, far, shinfo(7))
"""


def s4():
    print('S4: glue')
    out = run(WALL % 20)
    w, h = vals(out, 'w'), vals(out, 'h')
    check(w and w[2] == 127, 'the running bond glued: a joint a shared face (%s: 47 in the rows, 80 between them)'
          % (w and w[2]))
    check(w and 2 <= w[0] <= 8 and w[1] == 0 and h and h[0] > 0,
          'a 30 kg ball at 20 m/s knocks out a hole the size of the ball: %s bricks, none far from the hit '
          '(%s), %s joints broken; the rest stands' % (w and w[0], w and w[1], h and h[0]))
    out = run(WALL % 4)
    w2 = vals(out, 'w')
    check(w2 and w2[0] == 0, 'at 4 m/s the wall stands (%s bricks moved)' % (w2 and w2[0]))
    out8 = run(WALL % 20, threads=7)
    h1 = vals(run(WALL % 20, threads=0), 'h')
    h8 = vals(out8, 'h')
    check(h1 and h8 and h1[1] == h8[1] and h1[0] == h8[0],
          'the same on 1 and 8 threads (hash %s, %s; broken %s, %s)' % (h1 and h1[1], h8 and h8[1], h1 and h1[0], h8 and h8[0]))
    out = run('op("object.shatter", "shards count 100 glue 10000")\n' + STATS)
    st = stats(out)
    check(st and 400 < st[7] < 700, '100 shards glued: %s joints (about 11 neighbours a cell)' % (st and st[7]))


def main():
    tmp = tempfile.mkdtemp(prefix='bee-shat-')
    s1(tmp)
    s2(tmp)
    s3()
    s4()
    if FAILS:
        print('%d failed' % len(FAILS))
        sys.exit(1)
    print('shatter: all passed')


if __name__ == '__main__':
    main()
