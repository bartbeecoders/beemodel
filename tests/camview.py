#!/usr/bin/env python3
"""Camera View (view.camera, Numpad 0): the viewport through the scene camera.

- The viewport frames what a render from that camera shows: a cube seen by
  a camera with a 35 mm lens and a roll has the same silhouette in the
  viewport's frame as in render.image at the render settings' size.
- Outside the render's frame the canvas is dimmed.
- An animated camera is followed: keyed to look at the origin from two
  places, the cube stays in the middle of the frame while the view changes,
  and playing the animation keeps changing the picture.
- Leaving it (view.camera 0) gives an orbit view looking the camera's way
  from where it is; a view change (Front View) leaves it too.

    python3 tests/camview.py build/beemodel
"""
import math, os, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
_argv = sys.argv
sys.argv = [sys.argv[0], tempfile.mkdtemp(prefix='bee-camview-')]
import fakewl                                                # noqa: E402
sys.argv = _argv
fakewl.BIN = BIN
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def lum(img):
    import numpy as np
    return np.asarray(img.convert('L')).astype(int)


def bbox(mask, k=20):
    """Columns and rows with more than k set pixels: x0, x1, y0, y1."""
    import numpy as np
    cols = np.nonzero(mask.sum(0) > k)[0]
    rows = np.nonzero(mask.sum(1) > k)[0]
    if not len(cols) or not len(rows):
        return None
    return cols.min(), cols.max(), rows.min(), rows.max()


def frame_of(img):
    """The render's frame in the canvas (4:3 in the canvas's wider shape:
    bars left and right): the bright 1 px edge cv_draw puts round it, found
    along a row, then down its left edge."""
    a = lum(img)
    y = 300
    xs = [x for x in range(216, 1012) if a[y, x] > 100 and a[y, x - 1] < 80 and a[y, x + 1] < 80]
    if len(xs) < 2:
        return None
    ys = [yy for yy in range(80, 625) if a[yy, xs[0]] > 100]
    if not ys:
        return None
    return xs[0], xs[-1], ys[0], ys[-1]


def dimmed(img):
    """The canvas's left side darker than a little way in (the bars)."""
    import numpy as np
    a = lum(img)
    return float(np.median(a[150:550, 220:228])) < 0.7 * float(np.median(a[150:550, 300:308]))


def main():
    from PIL import Image
    f = fakewl.Fake()
    try:
        f.pump(2.0, until_frame=True)
        m = fakewl.Mcp(f)
        f.keymap('tests/keymaps/us.xkb')
        f.key(28); f.type('agent.permission_files'); f.key(28); f.pump(0.2); f.key(1)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()

        print('-- the frame matches a render from the camera --')
        out = os.path.join(f.home, 'cam.png')
        q('''op("view.toggle_grid")
op("render.settings", "800 600 8")
add("camera", "Cam", 6, 3, 6)
set("Cam", "lens", 35)
key("Cam:ry", 1, atan2(6, 6)); key("Cam:rx", 1, -atan2(3, sqrt(72))); key("Cam:rz", 1, 0.3)
op("anim.frame", "1")
select("Cam"); op("camera.set", "active")
op("view.camera", "1")
op("render.image", "%s 800 600 8")''' % out)
        f.pump(2.0)
        img = f.image()
        fr = frame_of(img)
        check(fr is not None and abs((fr[1] - fr[0] + 1) / max(fr[3] - fr[2] + 1, 1) - 4 / 3) < 0.02,
              'the frame has the render\'s shape (4:3): %s' % (fr,))
        if fr and os.path.exists(out):
            v = lum(img.crop((fr[0] + 1, fr[2] + 1, fr[1], fr[3])).resize((800, 600)))
            r = lum(Image.open(out))
            mv, mr = v > 120, r > 175
            mv[:300, 600:] = False              # (the navigation gizmo, over the frame)
            mr[:300, 600:] = False
            bv, br = bbox(mv), bbox(mr)
            ok = bv and br and all(abs(int(p) - int(q_)) <= 4 for p, q_ in zip(bv, br))
            check(ok, 'the cube\'s outline in the viewport %s is the render\'s %s (35 mm, rolled)'
                  % (tuple(map(int, bv or ())), tuple(map(int, br or ()))))
            check(dimmed(img), 'outside the frame the canvas is dimmed')
        else:
            check(False, 'a frame and a render to compare')

        print('-- an animated camera is followed --')
        q('''fn shot(fr, x, y, z) {
    key("Cam:x", fr, x); key("Cam:y", fr, y); key("Cam:z", fr, z)
    key("Cam:ry", fr, atan2(x, z)); key("Cam:rx", fr, -atan2(y, sqrt(x * x + z * z))); key("Cam:rz", fr, 0)
}
set("Cam", "lens", 50)
shot(1, 6, 3, 6)
shot(30, -6, 2, 5)
op("anim.range", "1 30 30")
op("anim.frame", "1")''')
        f.pump(1.5)
        a1 = f.image()
        q('op("anim.frame", "30")')
        f.pump(1.5)
        a2 = f.image()
        import numpy as np
        fr = frame_of(a2)
        cx = (fr[0] + fr[1]) / 2 if fr else 614
        cy = (fr[2] + fr[3]) / 2 if fr else 351
        def mid(img):
            b = bbox(lum(img) > 120, 5)
            return ((b[0] + b[1]) / 2, (b[2] + b[3]) / 2) if b else (0, 0)
        m1, m2 = mid(a1), mid(a2)
        changed = int((np.abs(lum(a1)[90:620, 216:1012] - lum(a2)[90:620, 216:1012]) > 8).sum())
        check(abs(m1[0] - cx) < 40 and abs(m2[0] - cx) < 40 and changed > 20000,
              'frames 1 and 30: the cube stays in the middle (x %.0f, %.0f of %.0f), the view moves (%d pixels)'
              % (m1[0], m2[0], cx, changed))
        q('op("anim.frame", "1")\nop("anim.play")')
        shots = []
        for _ in range(3):
            f.pump(0.35)
            shots.append(lum(f.image())[90:620, 216:1012])
        q('op("anim.play")')
        moving = sum(int((np.abs(shots[i] - shots[i + 1]) > 8).sum()) > 2000 for i in range(2))
        check(moving == 2, 'playing, the picture keeps changing with the camera (%d of 2)' % moving)

        print('-- leaving it --')
        q('op("anim.frame", "30")')
        f.pump(0.5)
        v = q('op("view.camera", "0")\nprint(viewinfo(0), viewinfo(1), viewinfo(3), viewinfo(4), viewinfo(5))').split()
        try:
            yaw, pitch, tx, ty, tz = map(float, v[-5:])
        except ValueError:
            yaw = pitch = tx = ty = tz = 1e9
        want_yaw = math.degrees(math.atan2(-6, 5))
        want_pitch = math.degrees(math.atan2(2, math.hypot(6, 5)))
        # the target: on the line from the camera through the origin
        d = math.hypot(tx + 6, ty - 2, tz - 5)
        along = ((tx + 6) * 6 + (ty - 2) * -2 + (tz - 5) * -5) / max(d * math.hypot(6, 2, 5), 1e-9) if d < 1e8 else 0
        check(abs(yaw - want_yaw) < 0.5 and abs(pitch - want_pitch) < 0.5 and along > 0.999,
              'view.camera 0: the orbit view looks the camera\'s way from it (yaw %.1f, pitch %.1f; want %.1f, %.1f)'
              % (yaw, pitch, want_yaw, want_pitch))
        f.pump(1.0)
        check(not dimmed(f.image()), 'out of Camera View: nothing dimmed')
        q('op("view.camera", "1")\nop("view.align_front")')
        f.pump(1.5)
        y = q('print(viewinfo(0))')
        check(not dimmed(f.image()) and y.split()[-1:] == ['0'],
              'Front View leaves Camera View (yaw %s)' % y)
        check(f.proc.poll() is None, 'BeeModel still runs')
    finally:
        f.proc.kill()


main()
if FAILS:
    print('camera view: %d failed' % len(FAILS))
    sys.exit(1)
print('camera view: all checks passed')
