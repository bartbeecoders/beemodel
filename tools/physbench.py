#!/usr/bin/env python3
"""The rigid body benchmark: the solver tests' big scenes, timed on a few
thread counts.

  python3 tools/physbench.py [build/beemodel] [threads ...]

  heap     1000 boxes tumbling into a heap, 5 s (121 frames)
  pour     10 800 balls poured into a box, 10 s
  bricks   5000 bricks settling: the mean awake frame (ms)
  terrain  1000 balls on a 100 000-triangle terrain: the mean and the
           slowest frame (ms)

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

THREADS = [int(a) for a in args] or sorted({1, 4, 8, os.cpu_count() or 1})
HASH = 'print("hash", rbinfo(16))\n'
SCENES = (
    ('heap', S.HEAP.replace('frame(121)', 't0 = clock()\nframe(121)\nprint("ms", clock() - t0)') + HASH,
     lambda r: f'{float(r["ms"][0]) / 1000:6.2f} s'),
    ('pour', S.POUR + HASH, lambda r: f'{float(r["pour"][1]) / 1000:6.1f} s'),
    ('bricks', S.BRICKS + HASH, lambda r: f'{float(r["bricks"][2]):6.1f} ms'),
    ('terrain', S.TERRAIN + HASH, lambda r: f'{float(r["terrain"][1]):5.1f} / {float(r["terrain"][0]):.0f} ms'),
)


def main():
    print(f'{"scene":8}' + ''.join(f'{str(t) + " thread" + ("s" if t > 1 else ""):>18}' for t in THREADS) + '   hash')
    for name, code, show in SCENES:
        cells, hashes = [], set()
        for t in THREADS:
            r = {x[0]: x[1:] for x in S.run(code, threads=t - 1) if x}
            try:
                cells.append(show(r))
            except (KeyError, IndexError, ValueError):
                cells.append('failed')
            hashes.add(r.get('hash', ['?'])[0])
        same = hashes.pop() if len(hashes) == 1 else 'differs'
        print(f'{name:8}' + ''.join(f'{c:>18}' for c in cells) + f'   {same}', flush=True)


if __name__ == '__main__':
    main()
