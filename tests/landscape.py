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
    tool = {'ramp': 223, 'grass': 371, 'rock': 341, 'auto': 461}
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


ground()
landscape()
sculpt_paint()
print(f'{len(FAILS)} failed' if FAILS else 'all landscape checks passed')
sys.exit(1 if FAILS else 0)
