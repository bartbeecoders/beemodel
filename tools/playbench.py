#!/usr/bin/env python3
"""The playback benchmark: the demos played in the viewport at 2560 x 1440.

  python3 tools/playbench.py [build/beemodel] [demo ...]

Each demo script is run headless and saved, then opened in the fake
compositor (tools/fakewl.py, a throwaway HOME) at 2560 x 1440, the view
looking through the demo's camera. For Solid, Material Preview and
Rendered it plays the animation for four seconds after the GPU helper has
warmed up, and prints:

  fps      window frames drawn a second (the scene's frames come from the
           clock: a slow frame skips some)
  frames   scene frames played in those four seconds
  ms       a window frame's median time (ui_draw: the step, the drawing)
  max      the slowest of ten sampled frames
  gpu      viewport frames the GPU drew (gpu(27)), liquid frames it solved
           (gpu(33))

BENCH_SECS changes the four seconds, BENCH_W and BENCH_H the size. An
older BeeModel (before v0.24) shows the same columns with its CPU
viewport.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
DEMOS = os.path.join(ROOT, 'Vibecoding', 'demos')
args = sys.argv[1:]
BIN = os.path.abspath(args.pop(0) if args and os.sep in args[0] else os.path.join(ROOT, 'build', 'beemodel'))
PICK = [a.removesuffix('.bees') for a in args] or ['dam-break', 'rainstorm', 'leaf-twister', 'fireworks']
SECS = float(os.environ.get('BENCH_SECS', '4'))
W, H = int(os.environ.get('BENCH_W', '2560')), int(os.environ.get('BENCH_H', '1440'))
SHADINGS = ('solid', 'material', 'rendered')
AIM = '''x = get("Cam", "x")
y = get("Cam", "y")
z = get("Cam", "z")
rx = get("Cam", "rx")
ry = get("Cam", "ry")
d = 8
view(ry * 57.2958, -rx * 57.2958, d, x - d * sin(ry) * cos(rx), y + d * sin(rx), z - d * cos(ry) * cos(rx))
'''

os.environ.setdefault('BEEMODEL_GPU_VIEW', 'on')     # (the fake compositor's default: off)
sys.argv = [sys.argv[0], tempfile.mkdtemp(prefix='bee-pbench-shots-')]
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import fakewl                                           # noqa: E402
fakewl.BIN = BIN


def saved(demo, tmp):
    """The demo built headless, saved as a .bee"""
    bee = os.path.join(tmp, demo + '.bee')
    script = os.path.join(tmp, 'save.bees')
    with open(os.path.join(DEMOS, demo + '.bees')) as f:
        src = f.read()
    with open(script, 'w') as f:
        f.write(src + '\nop("file.save_as", "%s")\n' % bee)
    os.makedirs(os.path.join(tmp, 'BeeModel'), exist_ok=True)
    subprocess.run([BIN, '--run', script], cwd=DEMOS, env=dict(os.environ, HOME=tmp, XDG_CACHE_HOME=''),
                   capture_output=True, timeout=600)
    return bee if os.path.exists(bee) else None


def play(bee, shading):
    f = fakewl.Fake([bee])
    try:
        f.pump(2.0, until_frame=True)
        f.configure(W, H)
        f.pump(1.0)
        m = fakewl.Mcp(f)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
        num = lambda code: [float(x) for x in q('print(%s)' % code).split()]
        q(AIM + 'op("view.shading_%s")' % shading)
        t = time.time()                                 # the helper warm (its kernels)
        while time.time() - t < 30 and (num('gpu(27), gpu(10)') or [0, 0]) == [0, 0]:
            f.pump(0.5)
        f.pump(1.0)
        n0, fr0 = num('frames(), frame()')
        g0 = num('gpu(27), gpu(33)')
        q('op("anim.play")')
        t = time.time()
        f.pump(SECS)
        el = time.time() - t
        n1, fr1 = num('frames(), frame()')
        g1 = num('gpu(27), gpu(33)')
        q('op("anim.play")')
        ft = num(', '.join('frametime(%d)' % k for k in range(5, 45, 4)))
        return ((n1 - n0) / el, fr1 - fr0, sorted(ft)[len(ft) // 2], max(ft), g1[0] - g0[0], g1[1] - g0[1])
    except (ValueError, IndexError, OSError):
        return None
    finally:
        f.proc.kill()


def main():
    print(f'{BIN}, {W} x {H}, {SECS:g} s of playback')
    print(f'{"scene":<14}{"shading":<10}{"fps":>7}{"frames":>8}{"ms":>8}{"max":>8}{"gpu":>12}')
    for demo in PICK:
        tmp = tempfile.mkdtemp(prefix='bee-pbench-')
        try:
            bee = saved(demo, tmp)
            if not bee:
                print(f'{demo:<14}failed to build')
                continue
            for sh in SHADINGS:
                r = play(bee, sh)
                if not r:
                    print(f'{demo:<14}{sh:<10}failed')
                    continue
                print(f'{demo:<14}{sh:<10}{r[0]:>7.1f}{r[1]:>8.0f}{r[2]:>8.1f}{r[3]:>8.1f}'
                      f'{f"{r[4]:.0f} {r[5]:.0f}":>12}', flush=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
