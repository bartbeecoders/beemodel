#!/usr/bin/env python3
"""A stand-in for the Hi3D addon's helper (addons/hi3d/bee_hi3d.py), for
tests/hi3d.py: no GPU, no models. It says what the real one says and makes
an octahedron, placed as the real one places its mesh. The image's name
picks what happens: fail* (an error), crash* (exits without a word),
slow* (takes a minute, to be stopped). Its arguments go to
$HOME/hi3d-args.json."""
import json, os, sys, time


def say(*a):
    print('@bee', *a, flush=True)


def main():
    a = sys.argv[1:]
    with open(os.path.join(os.environ['HOME'], 'hi3d-args.json'), 'w') as f:
        json.dump(a, f)
    if a[:1] != ['run']:
        say('ok', 'stand-in')
        return 0
    opt = {a[i]: a[i + 1] for i in range(1, len(a) - 1, 2)}
    name = os.path.basename(opt['--image'])
    print('a library warning on stderr', file=sys.stderr, flush=True)
    say('progress', '0.040', 'Rough shape (TripoSR)')
    if name.startswith('crash'):
        return 3
    if name.startswith('fail'):
        say('error', 'the GPU ran out of memory: try a lower detail or --offload')
        return 1
    for i in range(240 if name.startswith('slow') else 3):
        time.sleep(0.25)
        say('progress', f'{0.12 + 0.8 * (i + 1) / 3 if i < 3 else 0.5:.3f}', f'Detail pass 1/1, step {i + 1}/25')
    if '--coarse' in opt:                           # into the rough mesh's box
        vs = [list(map(float, ln.split()[1:4])) for ln in open(opt['--coarse']) if ln.startswith('v ')]
        lo = [min(v[k] for v in vs) for k in range(3)]
        hi = [max(v[k] for v in vs) for k in range(3)]
        c = [(lo[k] + hi[k]) / 2 for k in range(3)]
        h = max(hi[k] - lo[k] for k in range(3)) / 2
        pts = [(c[0] + h, c[1], c[2]), (c[0] - h, c[1], c[2]), (c[0], c[1] + h, c[2]),
               (c[0], c[1] - h, c[2]), (c[0], c[1], c[2] + h), (c[0], c[1], c[2] - h)]
    else:                                           # standing on y = 0, 2 tall
        pts = [(0.5, 1, 0), (-0.5, 1, 0), (0, 2, 0), (0, 0, 0), (0, 1, 0.5), (0, 1, -0.5)]
    faces = [(1, 3, 5), (3, 2, 5), (2, 4, 5), (4, 1, 5), (3, 1, 6), (2, 3, 6), (4, 2, 6), (1, 4, 6)]
    out = opt['--out']
    with open(out, 'w') as f:
        for p in pts:
            f.write('v %f %f %f\n' % p)
        for t in faces:
            f.write('f %d %d %d\n' % t)
    say('done', out, len(faces))
    return 0


if __name__ == '__main__':
    sys.exit(main())
