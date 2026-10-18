#!/usr/bin/env python3
"""Ground and landscape (2.0 plan, stage G).

G1: the Ground - Add › Ground once (a second time selects it); a cube made a
rigid body falls and rests on it, a cloth lands on it; the render (F12's
path tracer) has a transparent background, the cube opaque and its shadow
caught on the ground; the Ground is saved and reopened.

    python3 tests/landscape.py build/beemodel
"""
import os, subprocess, sys, tempfile, zlib, struct

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


ground()
print(f'{len(FAILS)} failed' if FAILS else 'all landscape checks passed')
sys.exit(1 if FAILS else 0)
