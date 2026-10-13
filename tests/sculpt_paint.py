#!/usr/bin/env python3
"""The v0.8 walkthrough: tests/sculpt_paint.bees sculpts a creature head,
bakes it into a light mesh's normal / AO / curvature maps, paints it on two
layers, gives a pedestal vertex colours, saves everything and renders it.
This runs it (in an isolated HOME), checks every step's numbers, the maps
written as PNG, and that the .bee file brings the scene back.

    python3 tests/sculpt_paint.py build/beemodel [outdir]
"""
import os, shutil, subprocess, sys, tempfile, time, warnings

warnings.filterwarnings("ignore", category=DeprecationWarning)

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
BUDGET_S = 30.0                    # end to end on a 4-core CI runner
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def png(path):
    try:
        from PIL import Image
    except ImportError:
        return None
    return Image.open(path).convert('RGB')


def main():
    print('  -- sculpt and paint walkthrough --')
    home = tempfile.mkdtemp(prefix='bee-sp-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    t = time.time()
    r = subprocess.run([BIN, '--eval', open(os.path.join(HERE, 'sculpt_paint.bees')).read()],
                       env=env, capture_output=True, text=True, timeout=300)
    secs = time.time() - t
    out = {}
    for line in r.stdout.splitlines():
        w = line.split()
        if w:
            out[w[0]] = [float(x) for x in w[1:]]
    if r.returncode != 0 or r.stderr.strip():
        print(r.stdout[-2000:], r.stderr[-2000:])
    isl, sc, bk, pa, vp = (out.get(k, []) for k in ('islands', 'sculpted', 'baked', 'painted', 'vpaint'))
    check(len(isl) == 1 and isl[0] >= 2 and len(sc) == 3 and sc[0] > 100000 and sc[1] == 1,
          f'the light head unwraps into {isl} islands; ten strokes sculpt the dense one, closed ({sc})')
    check(len(bk) == 4 and bk[0] > 300000 and bk[0] == bk[1] == bk[2],
          f'normal, AO and curvature maps bake {bk[:3]} texels each in {bk[3:]} ms')
    check(len(pa) == 2 and pa[0] == 2 and out.get('coat', [0])[0] > 200 and out.get('moss', [0])[0] > 10,
          f'a base coat and a multiplied moss layer are painted ({out.get("coat")}, {out.get("moss")}, {pa})')
    check(len(vp) == 2 and vp[0] == 12 and vp[1] >= 0, f'the pedestal gets vertex colours ({vp})')
    d = os.path.join(home, 'BeeModel')
    files = ['sculpt_paint.bee', 'sculpt_paint.png', 'head_col.png', 'head_nm.png', 'head_ao.png', 'head_cv.png']
    check(all(os.path.getsize(os.path.join(d, f)) > 1000 for f in files if os.path.exists(os.path.join(d, f)))
          and all(os.path.exists(os.path.join(d, f)) for f in files), 'the .bee file, the maps and the render are written')
    nm, ao, cv, img = (png(os.path.join(d, f)) for f in ('head_nm.png', 'head_ao.png', 'head_cv.png', 'sculpt_paint.png'))
    if nm is not None:
        px = list(nm.resize((128, 128)).getdata())
        blue = sum(1 for p in px if p[2] > 200) / len(px)
        tilt = sum(1 for p in px if p[2] > 150 and (abs(p[0] - 128) > 40 or abs(p[1] - 128) > 40))
        aopx = list(ao.resize((128, 128)).convert('L').getdata())
        cvpx = list(cv.resize((128, 128)).convert('L').getdata())
        lit = sum(1 for p in list(img.resize((240, 135)).getdata()) if abs(p[0] - p[2]) > 10 or p[0] > 180)
        check(blue > 0.4 and tilt > 20 and sum(1 for v in aopx if 60 < v < 200) > 20
              and sum(1 for v in cvpx if v < 90) > 10 and sum(1 for v in cvpx if v > 170) > 10 and lit > 500,
              f'the maps hold the sculpt: normals tilt at {tilt} texels, AO darkens, curvature both ways; '
              f'the render shows the scene')
    r2 = subprocess.run([BIN, '--eval', 'op("file.open", "~/BeeModel/sculpt_paint.bee")\n'
                         'print(imgsize("head_col", 0), layer("head_col", "count"), imgpixel("head_nm", 512, 512, 2), '
                         'matof("Head"), verts("Sculpt"))\ns = 0\nfor i in 0..verts("Pedestal") {\n'
                         ' if vcol("Pedestal", i, 0) > 150 { s += 1 }\n}\nprint(s)'],
                        env=env, capture_output=True, text=True, timeout=60)
    w = r2.stdout.split()
    check(len(w) == 6 and w[0] == '1024' and w[1] == '2' and w[3] == 'Stone' and float(w[4]) == sc[0] and int(w[5]) > 50,
          f'the .bee file brings back the images, the paint layers, the material, the sculpt and the vertex colours ({w})')
    check(secs < BUDGET_S, f'the walkthrough runs in {secs:.1f} s (budget {BUDGET_S:.0f} s)')
    if OUT:
        os.makedirs(OUT, exist_ok=True)
        for f in files[1:]:
            if os.path.exists(os.path.join(d, f)):
                shutil.copy(os.path.join(d, f), os.path.join(OUT, f))
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nsculpt and paint: all checks passed')
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
