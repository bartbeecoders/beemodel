#!/usr/bin/env python3
"""Particles and liquid (2.0 plan, stage P).

P1: the particle system core - a fountain's arc matches the ballistic
curve within 1e-3 (a burst, and particles born between frames at a rate,
each moved on from its own birth); a rate and a lifetime give the
expected count; the faces, volume, vertices and point sources put
particles where they should be; spread keeps velocities in their cone;
drag slows them by 1 / (1 + k dt) a step; a wind field pushes them; the
same particles on 1, 8 and 32 threads; a duplicate and a saved file
keep the systems; 1M particles step in under 10 ms.

P2: drawing and rendering - in the fake compositor 1M points draw in
under 16.7 ms (60 fps); a sprite draws in the start colour when young and
near the end colour when old (a ramp); the same picture on 1 and 32
threads; a render shows the particles (as tinted balls) unless they are
left out of renders. (CPU against GPU: tests/gpu.py.)

    python3 tests/particles.py build/beemodel
"""
import math, os, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
FAILS = []
CI = bool(os.environ.get('CI'))


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, timeout=600, home=None, threads=None):
    home = home or tempfile.mkdtemp(prefix='bee-particles-')
    os.makedirs(os.path.join(home, 'BeeModel'), exist_ok=True)
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    if threads is not None:
        env['BEEMODEL_THREADS'] = str(threads)
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(r.stdout[-1500:], r.stderr[-1500:])
    return [l.split() for l in r.stdout.splitlines() if l.strip()]


def vals(out, key):
    for l in out:
        if l and l[0] == key:
            try:
                return [float(x) for x in l[1:]]
            except ValueError:
                return l[1:]
    return []


def rows(out, key):
    return [[float(x) for x in l[1:]] for l in out if l and l[0] == key]


G = 9.81
FPS = 24.0


def p1():
    print('-- P1: the particle system core --')
    # a fountain: one burst at frame 1 from the cube's origin (0, 1, 0),
    # then a stream at 60 a second (born between frames)
    out = run('''
delete("Light")
emit("Cube", "from point burst 3 start 1 speed 10 direction 1 2 0 life 100")
for f in 2..40 {
  frame(f)
  print("arc", f, particles(6, 0), particles(7, 0), particles(12, 0))
}
select("Cube")
op("particles.remove", "")
emit("Cube", "from point rate 60 start 1 speed 6 direction 0 1 0 life 100")
frame(30)
for i in 0..particles(0) {
  print("str", particles(15, i), particles(7, i), particles(12, i))
}
''')
    arc = rows(out, 'arc')
    d = math.sqrt(5)
    vx, vy = 10 / d, 20 / d
    worst = 0
    for f, x, y, age in arc:
        t = (f - 1) / FPS
        worst = max(worst, abs(x - vx * t), abs(y - (1 + vy * t - 0.5 * G * t * t)), abs(age - t))
    check(len(arc) == 38 and worst < 1e-3,
          'a fountain burst follows the ballistic curve within 1e-3 over 38 frames (worst %.2g)' % worst)
    st = rows(out, 'str')
    t_now = 30 / FPS
    worst = 0
    for pid, y, age in st:
        tb = 1 / FPS + pid / 60.0
        t = t_now - tb
        worst = max(worst, abs(y - (1 + 6 * t - 0.5 * G * t * t)), abs(age - t))
    want = math.ceil((t_now - 1 / FPS) * 60)
    check(len(st) == want and worst < 1e-3,
          'a stream at 60/s: %d born by frame 30 (want %d), each from its own moment, within 1e-3 (worst %.2g)'
          % (len(st), want, worst))

    out = run('''
delete("Light")
select("Cube")
emit("Cube", "rate 240 life 0.5 speed 1")
frame(48)
print("rate", particles(0))
op("particles.set", "from volume rate 2000 speed 0 gravity 0 life 10")
frame(12)
m = 0
for i in 0..particles(0) {
  a = abs(particles(6, i))
  b = abs(particles(7, i) - 1)
  c = abs(particles(8, i))
  if b > a { a = b }
  if c > a { a = c }
  if a > m { m = a }
}
print("vol", particles(0), m)
op("particles.set", "from faces")
frame(1)
frame(12)
lo = 9
hi = 0
for i in 0..particles(0) {
  a = abs(particles(6, i))
  b = abs(particles(7, i) - 1)
  c = abs(particles(8, i))
  if b > a { a = b }
  if c > a { a = c }
  if a < lo { lo = a }
  if a > hi { hi = a }
}
print("faces", particles(0), lo, hi)
op("particles.set", "from verts")
frame(1)
frame(12)
lo = 9
for i in 0..particles(0) {
  a = abs(abs(particles(6, i)) - 1) + abs(abs(particles(7, i) - 1) - 1) + abs(abs(particles(8, i)) - 1)
  if i == 0 { lo = a }
  if a > lo { lo = a }
}
print("verts", particles(0), lo)
op("particles.set", "from point")
frame(1)
frame(12)
lo = 0
for i in 0..particles(0) {
  a = abs(particles(6, i)) + abs(particles(7, i) - 1) + abs(particles(8, i))
  if a > lo { lo = a }
}
print("point", particles(0), lo)
op("particles.set", "from point speed 5 direction 0 1 0 spread 20 rate 500")
frame(1)
frame(12)
lo = 1
for i in 0..particles(0) {
  vx = particles(9, i)
  vy = particles(10, i)
  vz = particles(11, i)
  c = vy / sqrt(vx*vx + vy*vy + vz*vz)
  if c < lo { lo = c }
}
print("spread", particles(0), lo)
op("particles.set", "spread 0 drag 2 burst 1")
frame(1)
frame(2)
v1 = particles(10, 0)
frame(26)
print("drag", v1, particles(10, 0))
op("particles.set", "drag 0 gravity 1 burst 1 life 0.25")
frame(1)
frame(6)
n1 = particles(0)
frame(7)
frame(8)
print("life", n1, particles(0))
''')
    r = vals(out, 'rate')
    check(r and r[0] == 120, 'rate 240 a second, life 0.5 s: 120 alive (%s)' % r)
    v = vals(out, 'vol')
    want = math.ceil(11 / FPS * 2000)
    check(len(v) == 2 and v[0] == want and v[1] <= 1.0,
          'from the volume: %s particles, all inside the cube (largest |x|, |y|, |z| %.4f)' % (v[:1], v[1] if v else -1))
    f = vals(out, 'faces')
    check(len(f) == 3 and f[1] > 0.9999 and f[2] < 1.0001, 'from the faces: all on the cube\'s surface (%s)' % f)
    vt = vals(out, 'verts')
    check(len(vt) == 2 and vt[1] < 1e-5, 'from the vertices: all at a corner (%s)' % vt)
    pt = vals(out, 'point')
    check(len(pt) == 2 and pt[1] < 1e-6, 'from a point: all at the origin (%s)' % pt)
    sp = vals(out, 'spread')
    check(len(sp) == 2 and sp[0] > 100 and math.cos(math.radians(20)) - 1e-4 <= sp[1] < math.cos(math.radians(15)),
          'spread 20: every velocity within 20 degrees of the direction, some near it (%s)' % sp)
    dr = vals(out, 'drag')
    k = 1 / (1 + 2 / FPS)
    check(len(dr) == 2 and abs(dr[1] - dr[0] * k ** 24) < 1e-3,
          'drag 2: the speed falls by 1 / (1 + k dt) a step (%s, want %.4f)' % (dr, dr[0] * k ** 24 if dr else 0))
    lf = vals(out, 'life')
    check(lf == [1, 0], 'life 0.25 s: there at frame 6, gone by frame 8 (%s)' % lf)

    out = run('''
delete("Light")
op("rigid.world", "gravity 0 0 0")
field("wind", "W", "strength 4 gust 0")
emit("Cube", "from point burst 1 speed 0 life 100")
frame(25)
print("wind", particles(6, 0), particles(9, 0))
''')
    w = vals(out, 'wind')
    t = 24 / FPS
    check(len(w) == 2 and abs(w[0] - 2 * t * t) < 1e-3 and abs(w[1] - 4 * t) < 1e-3,
          'a wind field of 4 m/s2 pushes a particle along +X (%s, want %.3f %.3f)' % (w, 2 * t * t, 4 * t))

    code = '''
delete("Light")
field("turbulence", "T", "strength 6 scale 1")
emit("Cube", "from volume rate 3000 speed 2 spread 40 speed_random 0.5 life 3 life_random 0.5 size_random 0.5 drag 0.3")
frame(30)
s = 0
for i in 0..particles(0) {
  s = s + particles(6, i) * 1.3 + particles(7, i) * 0.7 - particles(8, i) * 1.1 + particles(14, i)
}
print("hash", particles(0), s)
'''
    hs = [vals(run(code, threads=t), 'hash') for t in (1, 8, 32)]
    check(hs[0] and hs[0][0] > 1000 and hs[0] == hs[1] == hs[2],
          'the same particles on 1, 8 and 32 threads (with turbulence, random spread, life, size) (%s)' % hs)

    tmp = tempfile.mkdtemp(prefix='bee-particles-')
    bee = os.path.join(tmp, 'p.bee')
    out = run(f'''
delete("Light")
select("Cube")
op("particles.add", "from point burst 5 speed 3 seed 7 name Spray")
frame(10)
y0 = particles(7, 3)
print("one", particles(0))
op("object.duplicate")
frame(1)
frame(10)
print("dup", particles(0), particles(1))
op("file.save", "{bee}")
op("file.new")
frame(10)
print("new", particles(0))
op("file.open", "{bee}")
frame(10)
print("open", particles(0), particles(1), particles(7, 3) - y0)
''')
    check(vals(out, 'one') == [5], 'particles.add on the active object: a burst of 5 (%s)' % vals(out, 'one'))
    check(vals(out, 'dup') == [10, 2], 'a duplicate has the systems too: 2 systems, 10 particles (%s)' % vals(out, 'dup'))
    o = vals(out, 'open')
    check(vals(out, 'new') == [0] and len(o) == 3 and o[:2] == [10, 2] and abs(o[2]) < 1e-6,
          'saved and opened: the systems come back and give the same particles (%s)' % o)

    out = run('''
delete("Light")
emit("Cube", "from volume burst 1000000 speed 3 spread 30 life 100 drag 0.1")
frame(2)
print("burst", particles(2))
best = 1000
t = 0
for f in 3..23 {
  frame(f)
  t = t + particles(3)
  if particles(3) < best { best = particles(3) }
}
print("bench", particles(0), particles(2), t / 20, best)
''', threads=8)
    b, bu = vals(out, 'bench'), vals(out, 'burst')
    lim = 40 if CI else 10
    check(len(b) == 4 and b[0] == 1000000 and b[2] < lim,
          '1M particles step in under %d ms on 8 threads (mean %.2f ms, best %.2f; the burst was made in %.1f ms)'
          % (lim, b[2] if b else -1, b[3] if b else -1, bu[0] if bu else -1))


def fake_session(threads=None):
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
    argv = sys.argv
    sys.argv = [argv[0], tempfile.mkdtemp(prefix='bee-particles-shots-')]
    import fakewl
    sys.argv = argv
    fakewl.BIN = BIN
    old = os.environ.get('BEEMODEL_THREADS')
    if threads is not None:
        os.environ['BEEMODEL_THREADS'] = str(threads)
    try:
        f = fakewl.Fake()
    finally:
        if threads is not None:
            if old is None:
                os.environ.pop('BEEMODEL_THREADS', None)
            else:
                os.environ['BEEMODEL_THREADS'] = old
    f.pump(2.0, until_frame=True)
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    return f, q


BOX = (214, 80, 1014, 620)                              # the viewport


def p2():
    print('-- P2: drawing and rendering --')
    f, q = fake_session()
    try:
        q('emit("Cube", "from volume burst 1000000 speed 2 spread 180 life 100 draw points point_px 1 gravity 0")\n'
          'frame(12)')
        f.pump(1.0)
        ms, r = [], []
        for k in range(6):
            f.pump(0.3)
            r = q('print(particles(17), particles(18))').split()
            if len(r) == 2:
                ms.append(float(r[0]))
        lim = 60 if CI else 16.7
        med = sorted(ms)[len(ms) // 2] if ms else -1
        check(ms and r[1] == '1000000' and med < lim,
              '1M points draw in under %.1f ms (60 fps): median %.2f ms, best %.2f' %
              (lim, med, min(ms) if ms else -1))
        q('select("Cube")\nop("particles.remove", "")\ndelete("Cube")\nview(0, 0, 10, 0, 0, 0)\n'
          'add("plane", "E", 0, 0, 0)\n'
          'emit("E", "from point burst 1 speed 0 gravity 0 life 10 size 1 color ff0000 color_end 0000ff")\n'
          'frame(2)')
        f.pump(1.0)
        a = f.image().crop(BOX)
        q('frame(220)')
        f.pump(1.0)
        b = f.image().crop(BOX)
        w, h = a.size
        ca, cb = a.getpixel((w // 2 + 14, h // 2 + 8)), b.getpixel((w // 2 + 14, h // 2 + 8))
        check(ca[0] > 120 and ca[2] < 40 and cb[2] > 120 and cb[0] < 60,
              'a sprite in the middle of the view: red when young (%s), near the end colour (blue) when old (%s)'
              % (ca[:3], cb[:3]))
    finally:
        f.proc.kill()

    imgs = []
    for t in (1, 32):
        f, q = fake_session(threads=t)
        try:
            q('emit("Cube", "from faces burst 200000 speed 2 spread 60 life 100 size 0.05 speed_random 0.5 '
              'color_end 20ff40 life_random 0.5")\nframe(20)')
            f.pump(1.5)
            imgs.append(f.image().crop(BOX))
        finally:
            f.proc.kill()
    check(len(imgs) == 2 and imgs[0].tobytes() == imgs[1].tobytes(),
          'the same sprites, pixel for pixel, on 1 and 32 threads')

    tmp = tempfile.mkdtemp(prefix='bee-particles-')
    a, b = os.path.join(tmp, 'a.png'), os.path.join(tmp, 'b.png')
    run('emit("Cube", "from faces burst 3000 speed 1 life 100 size 0.15 gravity 0 color ff2020")\n'
        'frame(10)\n'
        'op("render.image", "%s 160 120 4 0")\n'
        'select("Cube")\n'
        'op("particles.set", "render off")\n'
        'op("render.image", "%s 160 120 4 0")\n' % (a, b))
    try:
        from PIL import Image
        def reds(path):
            px = Image.open(path).convert('RGB')
            px = px.get_flattened_data() if hasattr(px, 'get_flattened_data') else px.getdata()
            return sum(1 for p in px if p[0] > p[1] + 60 and p[0] > p[2] + 60)
        red, redb = reds(a), reds(b)
    except Exception as e:
        print('  ', e)
        red, redb = -1, -1
    check(red > 200 and redb == 0,
          'a render shows the particles as red balls (%d red pixels), none with render off (%d)' % (red, redb))


if __name__ == '__main__':
    p1()
    p2()
    if FAILS:
        print('%d FAILED' % len(FAILS))
        sys.exit(1)
    print('particles: all ok')
