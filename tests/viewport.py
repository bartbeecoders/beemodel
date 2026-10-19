#!/usr/bin/env python3
"""The viewport's rasterizer and Material Preview with big meshes.

- A 6.3 million-face mesh (a 393 216-face cube arrayed 16 times) does not
  push the objects after it out of the frame: a small cube added after it
  is drawn (the triangle slots were capped at half of a 1 GiB frame arena:
  everything past ~5.6 million input triangles was dropped).
- Material Preview keeps each mesh's corner normals between frames: with a
  127 000-face sphere it costs within a few ms of Solid (it was ~30 ms more,
  the normals made again every frame on one thread), and a vertex moved
  in edit (the mesh changed in place) shades as a fresh start would.

    python3 tests/viewport.py build/beemodel
"""
import os, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
_argv = sys.argv
sys.argv = [sys.argv[0], tempfile.mkdtemp(prefix='bee-viewport-')]
import fakewl                                                # noqa: E402
sys.argv = _argv
fakewl.BIN = BIN
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def session(code_before, code_after=None, settle=2.0):
    """Runs code, takes the viewport's pixels; then code_after and again."""
    f = fakewl.Fake()
    try:
        f.pump(2.0, until_frame=True)
        m = fakewl.Mcp(f)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
        out = [q(code_before)]
        f.pump(settle)
        imgs = [f.image()]
        if code_after:
            out.append(q(code_after))
            f.pump(settle)
            imgs.append(f.image())
        return out, imgs, q
    finally:
        f.proc.kill()


def diff(a, b):
    """Pixels that differ between two frames (PIL images)."""
    if a is None or b is None or a.size != b.size:
        return -1
    from PIL import ImageChops
    d = ImageChops.difference(a.convert('RGB'), b.convert('RGB')).convert('L')
    return sum(d.point(lambda v: 255 if v else 0).histogram()[255:])


def huge():
    print('-- a huge mesh, then a small one --')
    base = '''move("Cube", 0, 3.6, 0)
md = modifier("Cube", "subsurf")
modset("Cube", md, "levels", 6)
modapply("Cube", md)
md = modifier("Cube", "subsurf")
modset("Cube", md, "levels", 2)
modapply("Cube", md)
a = modifier("Cube", "array")
modset("Cube", a, "count", 16)
view(-20, 10, 62, -1, 4.7, -3.5)
print(efaces("Cube"))'''
    out, imgs, _ = session(base, 'add("cube", "Late", 2.5, 1, 0)\nselect("Cube")', settle=4.0)
    box = (615, 355, 700, 425)                              # (the viewport where the cube is)
    n = diff(imgs[0].crop(box), imgs[1].crop(box))
    check(out[0].split()[:1] == ['6291456'] and n > 200,
          'a 6.3 million-face mesh, then a cube added after it: the cube is drawn (%d pixels change)' % n)


SPHERE = '''add("sphere", "S", 3, 1, 0)
md = modifier("S", "subsurf")
modset("S", md, "levels", 4)
modapply("S", md)
'''
EDIT = 'vmove("S", 0, 0, 1.8, 0)\nvmove("S", 1, 0.3, 1.6, 0.2)'


def matprev():
    print('-- Material Preview --')
    sys_frames = '''s = 0
for k in 0..10 { s = s + frametime(k) }
print(s / 10)'''
    f = fakewl.Fake()
    try:
        f.pump(2.0, until_frame=True)
        m = fakewl.Mcp(f)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
        q(SPHERE)
        f.enter(600, 300)
        t = {}
        for mode in ('solid', 'material'):
            q('op("view.shading_%s")' % mode)
            f.pump(1.0)
            for i in range(12):
                q('view(%d, 25, 14, 1, 0.5, 0)' % (20 + i * 3))
                f.pump(0.25)
            t[mode] = float(q(sys_frames).split()[0])
        check(t['material'] < t['solid'] + 12,
              'a 127 000-face sphere: Material Preview %.1f ms a frame, Solid %.1f ms' % (t['material'], t['solid']))
        q('view(40, 25, 9, 3, 1, 0)')
        f.pump(1.0)
        before = f.image()
        q(EDIT)                                             # (the mesh changed in place)
        f.pump(1.5)
        moved = f.image()
    finally:
        f.proc.kill()
    f = fakewl.Fake()                                       # the same edit before any preview
    try:
        f.pump(2.0, until_frame=True)
        m = fakewl.Mcp(f)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
        q(SPHERE + EDIT + '\nop("view.shading_material")\nview(40, 25, 9, 3, 1, 0)')
        f.pump(1.5)
        fresh = f.image()
    finally:
        f.proc.kill()
    box = (415, 200, 815, 500)                              # (the viewport round the sphere)
    d1, d2 = diff(before.crop(box), moved.crop(box)), diff(moved.crop(box), fresh.crop(box))
    check(d1 > 50 and 0 <= d2 < 20,
          'two vertices moved (the mesh changed in place): the shading follows (%d pixels), the same as when '
          'the edit came before any preview (%d differ)' % (d1, d2))


if __name__ == '__main__':
    huge()
    matprev()
    print('FAILS', FAILS)
    sys.exit(1 if FAILS else 0)
