#!/usr/bin/env python3
"""Ground and landscape (2.0 plan, stage G).

G1: the Ground - Add › Ground once (a second time selects it); a cube made a
rigid body falls and rests on it, a cloth lands on it; the render (F12's
path tracer) has a transparent background, the cube opaque and its shadow
caught on the ground; the Ground is saved and reopened.

G2: the Landscape - a 1025 x 1025 landscape generated and eroded in under
1 s; a layer above the erosion changed in a few ms (from the cache); the
layers' stack (terrace, flatten, hide, remove, the noises); saved and
reopened with the same heights.

G3: sculpt and paint - in sculpt mode on a landscape (the fake compositor,
clicks only): the Ramp tool dragged from a plateau down to the flat lays a
straight slope (undone and redone as one step); Grass and Rock paint
layers are made by painting with them; Auto Paint covers the flat with
grass and the slope with rock, and the render shows both. Every brush by
script (raise, lower, smooth, flatten, noise, erode, ramp, paint).

G4: the heightfield collider - 1000 balls dropped on a 4097 x 4097
mountain roll down it and none goes under its surface; a ball comes to rest
on it; a box slides further on rock than on grass (each paint layer's
friction); cloth lands on it (by its heights, no triangles); the player
walks over it, following the ground, and a cliff taller than a step stops
it.

G5: presets and water - Add > Landscape > Flat, Hills, Mountains, Canyon,
Dunes, Island from the menu (clicks); each has its own shape; the island
brings a Water plane (the water material: transmission, IOR 1.33); a
wooden box dropped in its water floats, a stone one sinks.

G6: heightmaps in and out - a 16-bit PNG heightmap round-trips exactly
(export, import, export: the same samples); a float EXR round-trips the
heights; an 8-bit RGB PNG of another size and a half-float ZIP EXR (as
render.save writes) import (resampled to 2^k + 1); landscape.to_mesh full
gives every sample as a vertex, on the surface within 1e-5; landscape.tiles
splits it into landscapes that world partition streams out and back in
with the same heights.

    python3 tests/landscape.py build/beemodel
"""
import os, subprocess, sys, tempfile, time, zlib, struct

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
FAILS = []
CI = bool(os.environ.get('CI'))
SLOW = 3 if CI else 1


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, timeout=600, home=None):
    home = home or tempfile.mkdtemp(prefix='bee-land-')
    os.makedirs(os.path.join(home, 'BeeModel'), exist_ok=True)
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(r.stdout[-1500:], r.stderr[-1500:])
    return [l.split() for l in r.stdout.splitlines() if l.strip()]


def png_rgba(path):
    """(w, h, colour type, pixels as bytes, 4 or 3 a pixel) of our PNGs."""
    d = open(path, 'rb').read()
    w, h, depth, ctype = struct.unpack('>IIBB', d[16:26])
    i, idat = 8, b''
    while i < len(d):
        n, = struct.unpack('>I', d[i:i + 4])
        if d[i + 4:i + 8] == b'IDAT':
            idat += d[i + 8:i + 8 + n]
        i += 12 + n
    raw = zlib.decompress(idat)
    bpp = 4 if ctype == 6 else 3
    stride = w * bpp
    out, prev, p = bytearray(), bytearray(stride), 0
    for _ in range(h):
        f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line; prev = line
    return w, h, ctype, bytes(out), bpp


def ground():
    print('-- G1: the Ground --')
    tmp = tempfile.mkdtemp(prefix='bee-g1-')
    png = os.path.join(tmp, 'g.png')
    bee = os.path.join(tmp, 'g.bee')
    out = run(f'''
delete("Cube")
n0 = count()
op("create.ground")
op("create.ground")
print("count", n0, count())
add("cube", "Box", 0, 3, 0)
select("Box")
op("rigid.add", "active box")
add("grid", "Sheet", 3, 2, 0)
select("Sheet")
op("cloth.add", "cloth")
frame(120)
print("box", get("Box", "y"))
print("sheet", evpos("Sheet", 0, "y"))
frame(1)
move("Box", 0, 1, 0)
op("file.save", "{bee}")
print("render", render("{png}", 160, 90, 64))
''')
    v = {l[0]: l[1:] for l in out}
    c = v.get('count', ['0', '0'])
    check(int(c[1]) == int(c[0]) + 1, f'Add › Ground twice: one Ground ({c[0]} -> {c[1]} objects)')
    y = float(v.get('box', ['nan'])[0])
    check(abs(y - 1.0) < 0.02, f'a rigid cube falls and rests on the Ground (y {y:.4f}, want 1)')
    s = float(v.get('sheet', ['nan'])[0]) + 2         # (evpos: the object's space)
    check(-0.01 < s < 0.2, f'a cloth lands on the Ground (y {s:.3f})')
    if os.path.exists(png):
        w, h, ctype, px, bpp = png_rgba(png)
        check(ctype == 6, f'the render is RGBA (PNG colour type {ctype})')
        al = [px[i * bpp + 3] for i in range(w * h)] if bpp == 4 else [255] * (w * h)
        clear = sum(1 for a in al if a == 0) / len(al)
        solid = sum(1 for a in al if a == 255) / len(al)
        shadow = sum(1 for a in al if 60 <= a <= 240) / len(al)
        check(clear > 0.1, f'the background is transparent ({clear:.0%} of the film)')
        check(solid > 0.03, f'the cube is opaque ({solid:.0%})')
        check(shadow > 0.01, f'its shadow is caught on the Ground ({shadow:.1%} half-transparent)')
    else:
        check(False, 'the render was written')
    out = run(f'''
op("file.open", "{bee}")
n = count()
op("create.ground")
print("reopen", n, count(), get("Ground", "y"))
''')
    v = {l[0]: l[1:] for l in out}
    r = v.get('reopen', ['0', '-1'])
    check(r[0] == r[1] and int(r[0]) > 0, f'the Ground is saved and reopened as the Ground ({r[0]} -> {r[1]} objects)')


def landscape():
    print('-- G2: the Landscape --')
    tmp = tempfile.mkdtemp(prefix='bee-g2-')
    bee = os.path.join(tmp, 'l.bee')
    P = [(33.3, -41.7), (-80, 60), (0, 0), (99, 99), (-99.9, 12.5)]
    hs = ', '.join(f'height("Landscape", {x}, {z})' for x, z in P)
    out = run(f'''
op("landscape.add", "res 1025")
print("add", landscape("Landscape", 0), landscape("Landscape", 2), landscape("Landscape", 6), landscape("Landscape", 3), landscape("Landscape", 4))
op("landscape.layer", "add terrace steps 6 smooth 0.3")
print("terrace", landscape("Landscape", 6), landscape("Landscape", 2))
op("landscape.layer", "set 2 strength 0.5")
print("strength", landscape("Landscape", 6))
op("landscape.layer", "add flatten height 12 at 0 0 30")
print("flat", height("Landscape", 0, 0), height("Landscape", 5, -5))
op("landscape.layer", "hide 0")
print("hide", landscape("Landscape", 3), landscape("Landscape", 4))
op("landscape.layer", "show 0")
op("landscape.layer", "remove 3")
print("remove", landscape("Landscape", 2), height("Landscape", 0, 0))
{''.join(f'op("landscape.layer", "set 0 noise {k}")\nprint("noise", "{k}", landscape("Landscape", 3), landscape("Landscape", 4))\n' for k in ('ridged', 'billow', 'cells'))}print("h", {hs})
op("file.save", "{bee}")
op("file.open", "{bee}")
print("reopen", landscape("Landscape", 0), landscape("Landscape", 2), {hs})
''')
    v = {}
    for l in out:
        v.setdefault(l[0], []).append(l[1:])
    a = [float(x) for x in v.get('add', [['0'] * 5])[0]]
    check(a[0] == 1025 and a[1] == 2, f'landscape.add: 1025 samples a side, two layers (generate, erode) ({a[:2]})')
    check(a[2] < 1000 * SLOW, f'generated and eroded in {a[2]:.0f} ms (budget {1000 * SLOW} ms)')
    check(a[4] - a[3] > 5, f'hills {a[4] - a[3]:.1f} m high')
    t = [float(x) for x in v.get('terrace', [['1e9', '0']])[0]]
    s = float(v.get('strength', [['1e9']])[0][0])
    check(t[1] == 3 and t[0] < 50 * SLOW and s < 50 * SLOW,
          f'a layer above the erosion added and changed in {t[0]:.0f}, {s:.0f} ms (from the cache)')
    f = [float(x) for x in v.get('flat', [['0', '0']])[0]]
    check(abs(f[0] - 12) < 1e-3 and abs(f[1] - 12) < 1e-3, f'Flatten area: 12 m inside it ({f})')
    h = [float(x) for x in v.get('hide', [['0', '0']])[0]]
    check(h[1] - h[0] < 13, f'the generate layer hidden: next to flat ({h})')
    r = v.get('remove', [['0', '0']])[0]
    check(r[0] == '3' and abs(float(r[1]) - 12) > 1e-3, f'the flatten layer removed ({r})')
    ns = v.get('noise', [])
    check(len(ns) == 3 and all(float(n[2]) - float(n[1]) > 1 for n in ns), f'ridged, billow, cells noise ({ns})')
    h0, h1 = v.get('h', [[]])[0], v.get('reopen', [[]])[0]
    check(h1[:2] == ['1025', '3'] and h1[2:] == h0 and len(h0) == len(P),
          f'saved and reopened: the same heights ({h0} / {h1[2:]})')


def sculpt_paint():
    print('-- G3: sculpt and paint --')
    import math
    tmp = tempfile.mkdtemp(prefix='bee-g3-')
    argv = sys.argv
    sys.argv = [argv[0], tmp]
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'keymaps', 'us.xkb'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    hs = lambda: [float(x) for x in q('print(height("Landscape", -3, -3), height("Landscape", 0, 0), height("Landscape", 3, 3))').split()]
    f.enter(640, 400)
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.3)
    cmd('delete("Cube")')
    cmd('delete("Camera")')
    cmd('landscape.add flat res 257 size 12')
    cmd('landscape.layer add flatten height 2 at -3 -3 3')
    cmd('object.sculpt_mode')
    f.key(1); f.pump(0.3)
    P = fakewl.project
    rows = {w.get('label'): w for w in fakewl.ui_tree(m) if w['name'] == 'tools.row'}   # (by label:
    tool = {k: rows[l]['y'] + 11 for k, l in (('ramp', 'Ramp'), ('grass', 'Grass'),         #  the shelf
                                                ('rock', 'Rock'), ('auto', 'Auto Paint')) if l in rows}  #  grew in W5)
    f.click(55, tool['ramp']); f.pump(0.2)
    f.drag(*P((-3, 2, -3)), *P((3, 0, 3)), steps=12); f.pump(0.3)
    h = hs()
    check(abs(h[0] - 2) < 0.05 and abs(h[1] - 1) < 0.15 and abs(h[2]) < 0.05,
          f'Ramp dragged from the plateau to the flat: a straight slope (heights {h}, want 2 1 0)')
    f.mods(4); f.key(44); f.mods(0); f.pump(0.3)            # Ctrl+Z
    u = hs()
    f.mods(5); f.key(44); f.mods(0); f.pump(0.3)            # Ctrl+Shift+Z
    r = hs()
    check(abs(u[1]) < 0.05 and abs(r[1] - h[1]) < 1e-4, f'the stroke undone and redone as one step ({u[1]:.3f}, {r[1]:.3f})')
    f.click(55, tool['grass']); f.pump(0.2)
    for p in ((4, 0, -4), (4.5, 0, -3.5)):
        f.click(*P(p)); f.pump(0.1)
    f.click(55, tool['rock']); f.pump(0.2)
    f.click(*P((0, 1, 0))); f.pump(0.1)
    n = q('print(landscape("Landscape", 7))')
    check(n == '2', f'painting with Grass and Rock made their paint layers ({n})')
    f.click(55, tool['auto']); f.pump(0.5)
    f.shot('g3_landscape.png')
    png = os.path.join(tmp, 'g3.png')
    cmd(f'render("{png}", 400, 270, 16)')
    end = time.time() + 30
    while not os.path.exists(png) and time.time() < end:
        f.pump(0.2)
    if os.path.exists(png):
        w, hh, ctype, px, bpp = png_rgba(png)
        green = rock = 0
        sky = px[0:3]                                   # (the top corner: the sky)
        for i in range(w * hh):
            r_, g_, b_ = px[i * bpp], px[i * bpp + 1], px[i * bpp + 2]
            if max(abs(r_ - sky[0]), abs(g_ - sky[1]), abs(b_ - sky[2])) < 12:
                continue
            if g_ > r_ + 10 and g_ > b_ + 10:
                green += 1
            elif max(r_, g_, b_) - min(r_, g_, b_) < 30:  # (grey: rock)
                rock += 1
        check(green / (w * hh) > 0.05, f'the render: grass on the flat ({green / (w * hh):.0%} green)')
        check(rock / (w * hh) > 0.03, f'the render: rock on the slope ({rock / (w * hh):.1%} rock grey)')
    else:
        check(False, 'the render was written')
    f.proc.kill()
    out = run('''
op("landscape.add", "flat res 257 size 100")
op("landscape.brush", "raise 0 0 radius 10 strength 1")
print("raise", height("Landscape", 0, 0), height("Landscape", 11, 0), landscape("Landscape", 2))
op("landscape.brush", "lower 30 30 radius 10 strength 1")
print("lower", height("Landscape", 30, 30))
op("landscape.brush", "flatten 5 0 radius 4 strength 1")
print("flatten", height("Landscape", 5, 0))
op("landscape.brush", "smooth 0 0 radius 10 strength 1")
print("smooth", height("Landscape", 0, 0))
op("landscape.brush", "noise -30 -30 radius 10 strength 1")
print("noise", height("Landscape", -32, -29))
op("landscape.brush", "erode 0 0 radius 12 strength 1")
print("erode", height("Landscape", 0, 0))
op("landscape.brush", "ramp -40 30 to -10 30 radius 5")
op("landscape.brush", "raise -40 30 radius 3 strength 1")
op("landscape.brush", "ramp -40 30 to -10 30 radius 5")
print("ramp", height("Landscape", -40, 30), height("Landscape", -25, 30), height("Landscape", -10, 30))
op("landscape.paint", "add snow")
op("landscape.brush", "snow 0 0 radius 10 strength 1")
print("paint", landscape("Landscape", 7))
''')
    v = {l[0]: [float(x) for x in l[1:]] for l in out}
    a = v.get('raise', [0, 1, 0])
    check(abs(a[0] - 1) < 1e-3 and a[1] == 0 and a[2] == 1, f'raise: 1 m in the middle, nothing past the radius, a Sculpted layer ({a})')
    check(abs(v.get('lower', [0])[0] + 1) < 1e-3, f'lower ({v.get("lower")})')
    check(0 < v.get('smooth', [0])[0] < 1, f'smooth ({v.get("smooth")})')
    check(v.get('noise', [0])[0] != 0, f'noise ({v.get("noise")})')
    e = v.get('erode', [1])[0]
    check(e != v.get('smooth', [0])[0], f'erode ({e})')
    rp = v.get('ramp', [0, 0, 0])
    check(rp[0] > 0.2 and abs(rp[1] - (rp[0] + rp[2]) / 2) < 0.05 * rp[0], f'ramp: half way down in the middle ({rp})')
    check(v.get('paint', [0])[0] == 1, f'paint layers ({v.get("paint")})')


def collider():
    print('-- G4: the heightfield collider --')
    out = run('''
delete("Cube")
delete("Light")
delete("Camera")
op("landscape.add", "flat res 4097 size 2000")
op("landscape.layer", "add generate noise fbm scale 1.2 height 300 octaves 8 seed 3")
select("Landscape")
op("rigid.add", "passive mesh friction 0.6")
n = 0
for i in 0..32 {
  for j in 0..32 {
    if n < 1000 {
      x = -60 + i * 4
      z = -60 + j * 4
      add("sphere", "B" + n, x, height("Landscape", x, z) + 1.5, z)
      scale("B" + n, 0.5)
      select("B" + n)
      op("rigid.add", "active sphere friction 0.6")
      n = n + 1
    }
  }
}
t1 = clock()
frame(240)
print("sim", clock() - t1, rbinfo(0))
below = 0
above = 0
out = 0
worst = 0
moved = 0
n = 0
for i in 0..32 {
  for j in 0..32 {
    if n < 1000 {
      x = get("B" + n, "x")
      z = get("B" + n, "z")
      dx = x - (-60 + i * 4)
      dz = z - (-60 + j * 4)
      moved = moved + sqrt(dx * dx + dz * dz)
      h = height("Landscape", x, z)
      if h == nil { out = out + 1 } else {
        d = get("B" + n, "y") - 0.5 - h
        if d < worst { worst = d }
        if d < -0.05 { below = below + 1 }
        if d > 0.5 { above = above + 1 }
      }
      n = n + 1
    }
  }
}
print("balls", below, above, out, worst, moved / 1000)
''', timeout=900)
    v = {l[0]: [float(x) for x in l[1:]] for l in out if l[0] in ('sim', 'balls')}
    s = v.get('sim', [1e9, 0])
    b = v.get('balls', [1, 1, 1, -1, 0])
    check(s[1] == 1001, f'1000 balls on a 4097 x 4097 mountain: {s[0] / 1000:.1f} s for 10 s simulated')
    check(b[0] == 0 and b[2] == 0 and b[3] > -0.05,
          f'none under its surface (deepest {b[3] * 1000:.1f} mm; {b[1]:.0f} in the air, {b[2]:.0f} off it)')
    check(b[4] > 1, f'they rolled down it ({b[4]:.1f} m on average)')
    out = run('''
delete("Cube")
op("landscape.add", "res 257 size 60")
op("landscape.layer", "add flatten height 5 at 3 2 6")
select("Landscape")
op("rigid.add", "passive mesh")
add("sphere", "Ball", 3, 30, 2)
scale("Ball", 0.5)
select("Ball")
op("rigid.add", "active sphere")
frame(240)
print("ball", get("Ball", "y") - height("Landscape", get("Ball", "x"), get("Ball", "z")))
''') + run('''
delete("Cube")
op("landscape.add", "flat res 257 size 60")
op("landscape.paint", "add rock")
op("landscape.paint", "add grass friction 2")
op("landscape.brush", "rock -15 0 radius 14 strength 2")
op("landscape.brush", "grass 15 0 radius 14 strength 2")
op("landscape.brush", "rock -15 0 radius 14 strength 2")
op("landscape.brush", "grass 15 0 radius 14 strength 2")
select("Landscape")
op("rigid.add", "passive mesh friction 0.5")
add("cube", "A", -15, 0.6, -10)
scale("A", 0.5)
select("A")
op("rigid.add", "active box friction 0.5 velocity 0 0 6")
add("cube", "C", 15, 0.6, -10)
scale("C", 0.5)
select("C")
op("rigid.add", "active box friction 0.5 velocity 0 0 6")
frame(96)
print("slide", get("A", "z") + 10, get("C", "z") + 10)
''')
    v = {l[0]: [float(x) for x in l[1:]] for l in out}
    d = v.get('ball', [9])[0]
    check(abs(d - 0.5) < 0.02, f'a ball comes to rest on it ({d:.3f} m above the ground, radius 0.5)')
    s = v.get('slide', [0, 0])
    check(s[0] > s[1] * 1.3 and s[1] > 0.5, f'a box slides further on rock than on grass ({s[0]:.2f} m, {s[1]:.2f} m)')
    out = run('''
delete("Cube")
op("landscape.add", "res 257 size 40")
select("Landscape")
op("cloth.add", "collider")
h = height("Landscape", 0, 0)
add("grid", "Sheet", 0, h + 3, 0)
select("Sheet")
op("cloth.add", "cloth")
frame(72)
worst = 99
for v in 0..121 {
  x = evpos("Sheet", v, "x")
  z = evpos("Sheet", v, "z")
  d = evpos("Sheet", v, "y") + h + 3 - height("Landscape", x, z)
  if d < worst { worst = d }
}
print("cloth", worst, clothinfo(6), clothinfo(5))
''') + run('''
delete("Cube")
op("landscape.add", "res 1025 size 200")
op("landscape.layer", "add flatten height 60 at -12 -12 1.5")
h0 = height("Landscape", 0, 0)
op("play.start", "walk 0 " + (h0 + 2) + " 0")
playstep(1.5)
worst = 0
for k in 0..8 {
  playstep(0.5, 1, 0, 0)
  d = playinfo(2) - height("Landscape", playinfo(1), playinfo(3))
  if abs(d) > worst { worst = abs(d) }
}
x = playinfo(1)
playstep(3, 1, 0, 0)
print("walk", worst, x, playinfo(1), playinfo(3), playinfo(2) - h0)
op("play.stop")
''')
    v = {l[0]: [float(x) for x in l[1:]] for l in out}
    c = v.get('cloth', [-1, 1, 0])
    check(-0.005 < c[0] < 0.1 and c[1] == 0 and c[2] > 0,
          f'cloth lands on it by its heights ({c[0] * 1000:.0f} mm above at the lowest, {c[1]:.0f} collider triangles)')
    w = v.get('walk', [9, 0, 0, 0, 99])
    check(w[0] < 0.1, f'the player walks over it, on the ground ({w[0] * 100:.1f} cm at most from it)')
    check(w[2] > -11.5 and w[4] < 5, f'a cliff taller than a step stops it (at x {w[2]:.2f}, z {w[3]:.2f}; feet {w[4]:.2f} m up)')


def presets():
    print('-- G5: presets and water --')
    tmp = tempfile.mkdtemp(prefix='bee-g5-')
    argv = sys.argv
    sys.argv = [argv[0], tmp]
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'keymaps', 'us.xkb'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(640, 400)
    q('delete("Cube")')
    shapes = {}
    for label in ('Flat', 'Hills', 'Mountains', 'Canyon', 'Dunes', 'Island'):
        n0 = int(q('print(count())') or 0)
        ok = fakewl.menu_pick(f, m, 'Add', 'Landscape', label)
        f.pump(0.3)
        ok = ok and fakewl.widget(m, 'form.landscape.size') is not None   # (W5: size, samples, seed)
        x, y = fakewl.widget_xy(m, 'dialog.ok')
        f.click(x, y)
        f.pump(0.5)
        n = int(q('print(count())') or 0)
        name = q('print(name(count() - 1))') if label != 'Island' else q('print(name(count() - 2))')
        info = q(f'print(landscape("{name}", 2), landscape("{name}", 3), landscape("{name}", 4))').split()
        shapes[label] = (ok, n - n0, name, info)
        q(f'move("{name}", 0, -500, 0)')                # (out of the next one's way)
    f.shot('g5_presets.png')
    want = {'Flat': 0, 'Hills': 2, 'Mountains': 2, 'Canyon': 3, 'Dunes': 2, 'Island': 2}
    for label, (ok, made, name, info) in shapes.items():
        check(ok and made == (2 if label == 'Island' else 1) and info and int(float(info[0])) == want[label],
              f'Add > Landscape > {label}: {name}, {info[0] if info else "?"} layers, heights {info[1:] if info else "?"}')
    rng = {k: float(v[3][2]) - float(v[3][1]) for k, v in shapes.items() if len(v[3]) == 3}
    check(rng.get('Flat', 1) == 0 and rng.get('Mountains', 0) > rng.get('Hills', 0) > rng.get('Dunes', 99) > 0,
          f'each its own shape: heights over {rng}')
    w = q('print(name(count() - 1), material("Water"))')
    f.proc.kill()
    out = run('''
delete("Cube")
op("landscape.add", "island")
print("water", name(count() - 1), get("Water", "y"), landscape("Landscape", 3), landscape("Landscape", 4))
select("Landscape")
op("rigid.add", "passive mesh")
add("cube", "Wood", 95, 5, 95)
select("Wood")
op("rigid.add", "active box material wood mass 4800")
add("cube", "Stone", -95, 5, -95)
select("Stone")
op("rigid.add", "active box material stone mass 19200")
for f in 1..400 { frame(f) }
print("float", get("Wood", "y"), get("Stone", "y"), height("Landscape", -95, -95))
''')
    v = {l[0]: l[1:] for l in out}
    wa = v.get('water', ['?', '1', '0', '0'])
    check(wa[0] == 'Water' and float(wa[1]) == 0 and float(wa[2]) < -5 < 5 < float(wa[3]),
          f'the island: its Water plane at 0 m, the sea floor at {wa[2]} m, the top {wa[3]} m')
    fl = [float(x) for x in v.get('float', ['-9', '9', '0'])]
    check(-0.4 < fl[0] < 0, f'a wooden box (600 kg/m3) floats, {-fl[0] + 1:.2f} m of its 2 m under water')
    check(fl[2] + 0.8 < fl[1] < fl[2] + 1.2, f'a stone one (2400 kg/m3) sinks to the sea floor ({fl[1]:.2f} m, floor {fl[2]:.2f} m)')


def write_exr(path, w, h):
    """A scanline OpenEXR file as the spec has it: half G and R (R: 0 at the
    left to 2 at the right), ZIP compression (16 lines a block: bytes split
    into halves, delta-coded, deflated)."""
    def attr(name, typ, data):
        return name.encode() + b'\0' + typ.encode() + b'\0' + struct.pack('<I', len(data)) + data
    ch = b''.join(n + b'\0' + struct.pack('<iB3xii', 1, 0, 1, 1) for n in (b'G', b'R')) + b'\0'
    box = struct.pack('<iiii', 0, 0, w - 1, h - 1)
    hdr = (struct.pack('<II', 20000630, 2) + attr('channels', 'chlist', ch) + attr('compression', 'compression', b'\3')
           + attr('dataWindow', 'box2i', box) + attr('displayWindow', 'box2i', box) + attr('lineOrder', 'lineOrder', b'\0')
           + attr('pixelAspectRatio', 'float', struct.pack('<f', 1)) + attr('screenWindowCenter', 'v2f', struct.pack('<ff', 0, 0))
           + attr('screenWindowWidth', 'float', struct.pack('<f', 1)) + b'\0')
    import random
    rnd = random.Random(1)
    row_r = struct.pack(f'<{w}e', *[2 * x / (w - 1) for x in range(w)])
    rows_g = [struct.pack(f'<{w}e', *[rnd.random() * 5 for _ in range(w)]) for _ in range(h)]
    blocks = []
    for y0 in range(0, h, 16):
        raw = b''.join(rows_g[y] + row_r for y in range(y0, min(h, y0 + 16)))
        t = bytearray(len(raw))
        half = (len(raw) + 1) // 2
        t[:half], t[half:] = raw[0::2], raw[1::2]
        p = bytearray(t)
        for i in range(1, len(t)):
            p[i] = (t[i] - t[i - 1] + 128) & 255
        blocks.append((y0, zlib.compress(bytes(p))))
    off = len(hdr) + 8 * len(blocks)
    table, data = b'', b''
    for y0, z in blocks:
        table += struct.pack('<Q', off + len(data))
        data += struct.pack('<ii', y0, len(z)) + z
    open(path, 'wb').write(hdr + table + data)


def heightmaps():
    print('-- G6: heightmaps in and out --')
    from PIL import Image
    tmp = tempfile.mkdtemp(prefix='bee-g6-')
    write_exr(os.path.join(tmp, 'r.exr'), 64, 48)
    im = Image.new('RGB', (300, 200))
    im.putdata([(int(255 * x / 299), y % 256, 0) for y in range(200) for x in range(300)])
    im.save(os.path.join(tmp, 'rgb.png'))
    P = [(12.3, -40), (-30, 25.5), (0, 0), (49, 49)]
    hs = lambda n: ', '.join(f'height("{n}", {x}, {z})' for x, z in P)
    out = run(f'''
delete("Cube")
op("landscape.add", "res 257 size 100")
op("landscape.export", "{tmp}/h1.png")
op("landscape.export", "{tmp}/h1.exr")
print("orig", {hs("Landscape")}, landscape("Landscape", 3), landscape("Landscape", 4))
op("landscape.import", "{tmp}/h1.png size 100 height 100")
select("Landscape.001")
op("landscape.export", "{tmp}/h2.png")
print("png", {hs("Landscape.001")})
op("landscape.import", "{tmp}/h1.exr size 100")
print("exr", landscape("Landscape.002", 0), {hs("Landscape.002")})
op("landscape.import", "{tmp}/rgb.png size 300 height 10")
print("rgb", landscape("Landscape.003", 0), landscape("Landscape.003", 3), landscape("Landscape.003", 4), height("Landscape.003", 149, 0))
op("landscape.import", "{tmp}/r.exr size 64")
print("rexr", landscape("Landscape.004", 0), landscape("Landscape.004", 3), landscape("Landscape.004", 4))
select("Landscape")
n = landscape("Landscape", 0)
a = height("Landscape", -50 + 37 * 100 / 256, -50 + 201 * 100 / 256)
op("landscape.to_mesh", "full")
print("mesh", landscape("Landscape", 0), vpos("Landscape", 201 * n + 37, "y") - a, vpos("Landscape", 201 * n + 37, "x") + 50 - 37 * 100 / 256)
''')
    v = {l[0]: l[1:] for l in out}
    if os.path.exists(f'{tmp}/h1.png') and os.path.exists(f'{tmp}/h2.png'):
        ia, ib = Image.open(f'{tmp}/h1.png'), Image.open(f'{tmp}/h2.png')
        a, b = list(ia.getdata()), list(ib.getdata())
        diff = sum(1 for x, y in zip(a, b) if x != y)
        check(ia.mode.startswith('I') and ia.size == (257, 257) and len(a) == len(b) and diff == 0
              and min(a) == 0 and max(a) == 65535,
              f'a 16-bit PNG heightmap round-trips exactly ({ia.size}, {ia.mode}, {diff} samples differ)')
    else:
        check(False, 'the PNG heightmaps were written')
    o = [float(x) for x in v.get('orig', ['0'] * 6)]
    p = [float(x) for x in v.get('png', ['9'] * 4)]
    tol = (o[5] - o[4]) / 65535
    check(all(abs(p[i] - (o[i] - o[4]) * 100 / (o[5] - o[4])) < 100 / 65535 + 1e-4 for i in range(4)),
          f'imported: the heights to 1/65535 of the range ({p} / {o[:4]})')
    e = v.get('exr', ['0'] + ['9'] * 4)
    check(e[0] == '257' and [float(x) for x in e[1:]] == o[:4], f'a float EXR round-trips the heights ({e[1:]})')
    r = [float(x) for x in v.get('rgb', ['0', '9', '0', '0'])]
    check(r[0] == 513 and abs(r[1]) < 1e-3 and abs(r[2] - 10) < 1e-3 and abs(r[3] - 10) < 0.05,
          f'an 8-bit RGB PNG of 300 x 200: resampled to 513 x 513, 0..10 m ({r})')
    x = [float(x) for x in v.get('rexr', ['0', '9', '0'])]
    check(x[0] == 65 and abs(x[1]) < 0.01 and abs(x[2] - 2) < 0.01,
          f'a half-float ZIP EXR (64 x 48; R 0..2, G noise) imports by its R channel: 65 x 65, {x[1]}..{x[2]} m')
    m = v.get('mesh', ['x', '1', '1'])
    check(m[0] == 'nil' and abs(float(m[1])) < 1e-5 and abs(float(m[2])) < 1e-5,
          f'landscape.to_mesh full: a plain mesh, a sample within 1e-5 of the surface ({m[1]}, {m[2]})')
    out = run(f'''
delete("Cube")
op("landscape.add", "res 1025 size 400")
h = height("Landscape", 30, -40)
op("landscape.tiles", "4")
t = 0
for i in 0..count() {{ if landscape(name(i), 0) != nil {{ t = t + 1 }} }}
print("tiles", t, landscape(name(count() - 1), 0), landscape(name(count() - 1), 1))
op("file.save", "{tmp}/wp.bee")
op("world.partition", "100 150")
view(45, 22, 90, 2000, 25, 2000)
op("world.update")
op("world.update")
far = 0
for i in 0..count() {{ if landscape(name(i), 0) != nil {{ far = far + 1 }} }}
view(45, 22, 90, 0, 25, 0)
for k in 0..20 {{ op("world.update") }}
near = 0
hh = -1
for i in 0..count() {{ if landscape(name(i), 0) != nil {{ near = near + 1
  v = height(name(i), 30, -40)
  if v != nil {{ hh = v }} }} }}
print("stream", far, near, hh - h)
''')
    v = {l[0]: l[1:] for l in out}
    tl = v.get('tiles', ['0', '0', '0'])
    check(tl == ['16', '257', '100'], f'landscape.tiles 4: 16 landscapes of 257 samples, 100 m ({tl})')
    st = v.get('stream', ['9', '0', '9'])
    check(st[0] == '0' and int(st[1]) > 0 and abs(float(st[2])) < 1e-5,
          f'world partition streams the tiles out and back in (far {st[0]}, near {st[1]} loaded; height {st[2]} off)')


ground()
landscape()
sculpt_paint()
collider()
presets()
heightmaps()
print(f'{len(FAILS)} failed' if FAILS else 'all landscape checks passed')
sys.exit(1 if FAILS else 0)
