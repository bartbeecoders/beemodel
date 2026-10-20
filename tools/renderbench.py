#!/usr/bin/env python3
"""The render benchmark: the four particle demos, path-traced at 960 x 540.

  python3 tools/renderbench.py [build/beemodel] [demo ...]

Each demo is simulated to its frame, then rendered three times at 16
samples (the first render builds the whole scene, the next ones reuse the
object BVHs and the scene kept on the GPU), then ten frames with
render_frames (the next frame is built while the GPU traces one), and ten
more with 64 samples and sample reuse 3 (16 new samples a frame).

  render   the first render: its own time and the wall time (ms)
  build    Hive's scene build and the BVH part of it (ms)
  again    the third render's wall time and build (ms)
  frames   render_frames: a frame (ms, the mean of 10)
  reuse    render_frames, 64 samples, reuse 3: a frame (ms, the mean of 10)
  device   where it rendered: 0 the CPU, 1 the GPU's compute path, 2 RTX

BENCH_SPP=4 renders fewer samples (quicker, for a smoke run). The script
runs in a throwaway HOME; the images go to that HOME and are removed.
An older BeeModel (before v0.23: no render_frames, no gpu(15..)) shows
its renders' times only: compare the render, wall and again columns.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
DEMOS = os.path.join(ROOT, 'Vibecoding', 'demos')
args = sys.argv[1:]
BIN = os.path.abspath(args.pop(0) if args and not args[0].endswith('.bees') and os.sep in args[0] else
                      os.path.join(ROOT, 'build', 'beemodel'))
SCENES = {'rainstorm': 120, 'dam-break': 60, 'leaf-twister': 120, 'fireworks': 90}
PICK = [a.removesuffix('.bees') for a in args] or list(SCENES)
SPP = int(os.environ.get('BENCH_SPP', '16'))

BENCH = '''
for f in 2..{F} {{ frame(f) }}
t0 = clock()
ms = render("{T}/a.png", 960, 540, {S}, 0)
print("BENCH render", ms, clock() - t0, "build", gpu(15), gpu(16), "tris", gpu(17), "spheres", gpu(19), "device", gpu(6) + gpu(23))
render("{T}/b.png", 960, 540, {S}, 0)
t0 = clock()
render("{T}/c.png", 960, 540, {S}, 0)
print("BENCH again", clock() - t0, gpu(15))
t0 = clock()
render_frames("{T}/f", {F}, {F} + 9, 960, 540, {S}, 0)
print("BENCH frames", (clock() - t0) / 10)
op("render.sample_reuse", "3")
t0 = clock()
render_frames("{T}/r", {F} + 10, {F} + 19, 960, 540, {S} * 4, 0)
print("BENCH reuse", (clock() - t0) / 10)
'''


def run(demo, frame):
    tmp = tempfile.mkdtemp(prefix='bee-rbench-')
    try:
        os.makedirs(os.path.join(tmp, 'BeeModel'))
        script = os.path.join(tmp, 'run.bees')
        with open(os.path.join(DEMOS, demo + '.bees')) as f:
            src = f.read()
        with open(script, 'w') as f:
            f.write(src + BENCH.format(F=frame, T=tmp, S=SPP))
        env = dict(os.environ, HOME=tmp, XDG_CACHE_HOME='')
        out = subprocess.run([BIN, '--run', script], cwd=DEMOS, env=env, capture_output=True,
                             text=True, timeout=1800).stdout
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    got = {}
    for line in out.splitlines():
        if line.startswith('BENCH '):
            w = line.split()
            got[w[1]] = [float(x) for x in w[2:] if re.fullmatch(r'-?[0-9.]+', x)]
    return got


def main():
    print(f'{BIN}, 960 x 540, {SPP} samples')
    print(f'{"scene":<13}{"frame":>6}{"render":>8}{"wall":>8}{"build":>7}{"bvh":>6}{"again":>7}'
          f'{"frames":>8}{"reuse":>8}{"device":>7}')
    num = lambda g, k, i, w: f'{g[k][i]:>{w}.0f}' if k in g and len(g[k]) > i else f'{"-":>{w}}'
    for demo in PICK:
        g = run(demo, SCENES.get(demo, 60))
        if 'render' not in g:
            print(f'{demo:<13} failed')
            continue
        print(f'{demo:<13}{SCENES.get(demo, 60):>6}' + num(g, 'render', 0, 8) + num(g, 'render', 1, 8)
              + num(g, 'render', 2, 7) + num(g, 'render', 3, 6) + num(g, 'again', 0, 7) + num(g, 'frames', 0, 8)
              + num(g, 'reuse', 0, 8) + num(g, 'render', 6, 7))


if __name__ == '__main__':
    main()
