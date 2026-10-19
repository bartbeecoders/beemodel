#!/usr/bin/env python3
"""The rigid body benchmark: the solver tests' big scenes, timed on a few
thread counts.

  python3 tools/physbench.py [build/beemodel] [threads ...]

  heap     1000 boxes tumbling into a heap, 5 s (121 frames)
  pour     10 800 balls poured into a box, 10 s
  bricks   5000 bricks settling: the mean awake frame (ms)
  terrain  1000 balls on a 100 000-triangle terrain: the mean and the
           slowest frame (ms)
  mountain 1000 balls rolling down a 4097 x 4097 landscape (a heightfield):
           the mean frame (ms), 10 s; and the landscape generated (ms)
  shatter  a 100 000-triangle vase cut into 500 shards: the whole operator
           and the cut alone (ms); the hash is the pieces made
  nbody    5445 bodies that attract each other (instances, no gravity): a
           step (ms), and the octree and pulls alone
  particles 1M particles in the air (gravity, drag): a step (ms, the mean of 20)
  liquid   a dam break of 200k liquid particles: a frame (ms, the mean of 6),
           and its surface meshed (ms, the last frame)

BENCH_ONLY=nbody,shatter runs just those scenes. The particle scenes' hash
is a sum over some of their particles' places.

Threads are counted as BeeModel counts them: the workers and the UI thread
(1 = no workers). Each scene also prints the hash of every body's state at
its end (rbinfo(16)), the same on any number of threads.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tests'))
args = sys.argv[1:]
BIN = args.pop(0) if args and not args[0].isdigit() else 'build/beemodel'
sys.argv = [sys.argv[0], BIN]
import solver as S                                      # noqa: E402
import shatter as SH                                    # noqa: E402
import fields as FI                                     # noqa: E402
import tempfile                                         # noqa: E402

THREADS = [int(a) for a in args] or sorted({1, 4, 8, os.cpu_count() or 1})
HASH = 'print("hash", rbinfo(16))\n'
MOUNTAIN = ('delete("Cube")\ndelete("Light")\ndelete("Camera")\nt0 = clock()\n'
            'op("landscape.add", "flat res 4097 size 2000")\n'
            'op("landscape.layer", "add generate noise fbm scale 1.2 height 300 octaves 8 seed 3")\n'
            'print("gen", clock() - t0)\nselect("Landscape")\nop("rigid.add", "passive mesh friction 0.6")\n'
            'n = 0\nfor i in 0..32 { for j in 0..32 { if n < 1000 {\n x = -60 + i * 4\n z = -60 + j * 4\n'
            ' add("sphere", "B" + n, x, height("Landscape", x, z) + 1.5, z)\n scale("B" + n, 0.5)\n'
            ' select("B" + n)\n op("rigid.add", "active sphere friction 0.6")\n n = n + 1\n} } }\n'
            't1 = clock()\nframe(240)\nprint("mountain", (clock() - t1) / 240)\n')
VASE = os.path.join(tempfile.mkdtemp(prefix='bee-bench-'), 'vase.obj')
SH.vase_obj(VASE, n=384, split=10)                      # 99 072 triangles
SHATTER = ('delete("Cube")\nop("file.import_obj", "%s")\nop("object.shatter", "count 500 seed 7 nobodies")\n'
           'print("shatter", shinfo(6), shinfo(12))\nprint("hash", shinfo(0))\n' % VASE)
PHASH = ('s = 0\nfor i in 0..1000 {\n k = i * 97\n s = s + particles(6, k) * 1.3 + particles(7, k) - particles(8, k) * 0.7\n}\n'
         'print("hash", s)\n')
PARTICLES = ('delete("Light")\nemit("Cube", "from volume burst 1000000 speed 3 spread 30 life 100 drag 0.1")\n'
             'frame(2)\nt = 0\nfor f in 3..23 {\n frame(f)\n t = t + particles(3)\n}\nprint("parts", t / 20)\n' + PHASH)
LIQUID = ('delete("Light")\nscale("Cube", 0.5, 0.8, 0.5)\nmove("Cube", -1.5, 0.8, 0)\n'
          'emit("Cube", "from fill size 0.02 life 1000 liquid on domain -2 0 -0.5 2 2 0.5 speed 0 surface on")\n'
          'frame(2)\nt = 0\nfor f in 3..9 {\n frame(f)\n t = t + particles(23)\n}\n'
          'print("liquid", t / 6, particles(32, 0))\n' + PHASH)
SCENES = (
    ('heap', S.HEAP.replace('frame(121)', 't0 = clock()\nframe(121)\nprint("ms", clock() - t0)') + HASH,
     lambda r: f'{float(r["ms"][0]) / 1000:6.2f} s'),
    ('pour', S.POUR + HASH, lambda r: f'{float(r["pour"][1]) / 1000:6.1f} s'),
    ('bricks', S.BRICKS + HASH, lambda r: f'{float(r["bricks"][2]):6.1f} ms'),
    ('terrain', S.TERRAIN + HASH, lambda r: f'{float(r["terrain"][1]):5.1f} / {float(r["terrain"][0]):.0f} ms'),
    ('mountain', MOUNTAIN + HASH, lambda r: f'{float(r["mountain"][0]):5.1f} ms ({float(r["gen"][0]):.0f})'),
    ('shatter', SHATTER, lambda r: f'{float(r["shatter"][0]):5.0f} / {float(r["shatter"][1]):.0f} ms'),
    ('nbody', FI.CLOUD + HASH, lambda r: f'{float(r["cloud"][1]) / 120:5.2f} / {float(r["cloud"][2]):.2f} ms'),
    ('particles', PARTICLES, lambda r: f'{float(r["parts"][0]):6.2f} ms'),
    ('liquid', LIQUID, lambda r: f'{float(r["liquid"][0]):5.0f} / {float(r["liquid"][1]):.0f} ms'),
)
ONLY = [s for s in os.environ.get('BENCH_ONLY', '').split(',') if s]


def main():
    print(f'{"scene":9}' + ''.join(f'{str(t) + " thread" + ("s" if t > 1 else ""):>18}' for t in THREADS) + '   hash')
    for name, code, show in SCENES:
        if ONLY and name not in ONLY:
            continue
        cells, hashes = [], set()
        for t in THREADS:
            r = {x[0]: x[1:] for x in S.run(code, threads=t - 1) if x}
            try:
                cells.append(show(r))
            except (KeyError, IndexError, ValueError):
                cells.append('failed')
            hashes.add(r.get('hash', ['?'])[0])
        same = hashes.pop() if len(hashes) == 1 else 'differs'
        print(f'{name:9}' + ''.join(f'{c:>18}' for c in cells) + f'   {same}', flush=True)


if __name__ == '__main__':
    main()
