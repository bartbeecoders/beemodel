#!/usr/bin/env python3
"""Short viewport screencasts for the website: BeeModel in the fake
compositor, a scene simulated frame by frame, each frame's viewport saved,
ffmpeg joining them into media/video/<name>.mp4.

  python3 BeeModelHome/tools/screencast.py [build/beemodel] [name ...]
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import capture                                              # noqa: E402

OUT = os.path.abspath(os.path.join(HERE, '..', 'media', 'video'))

TORNADO = '''delete("Cube")
op("create.ground")
op("field.add_tornado", "strength 30 lift 18 inflow 6 radius 7")
seed(4)
for i in 0..80 {
  add("cube", "Box" + i, rand() * 10 - 5, 0.3 + rand() * 2, rand() * 10 - 5)
  scale("Box" + i, 0.12 + rand() * 0.18)
  rotate("Box" + i, rand() * 3, rand() * 3, rand() * 3)
  select("Box" + i)
  op("rigid.add", "active box")
}
op("object.select_all")
view(25, 12, 19, 0, 4, 0)
'''

ORBITS = '''delete("Cube")
op("rigid.world", "gravity 0 0 0 g 1")
add("sphere", "Planet", 0, 0, 0)
scale("Planet", 1.5)
select("Planet")
op("rigid.add", "passive sphere mass 4000 attracts")
seed(9)
for i in 0..14 {
  a = rand() * 6.283
  r = 4 + rand() * 6
  v = sqrt(4000 / r)
  add("sphere", "Moon" + i, r * cos(a), rand() * 0.6 - 0.3, r * sin(a))
  scale("Moon" + i, 0.25 + rand() * 0.35)
  select("Moon" + i)
  op("rigid.add", "active sphere mass 2 velocity " + str(-v * sin(a)) + " 0 " + str(v * cos(a)))
}
op("object.select_all")
view(30, 32, 21, 0, 0, 0)
'''

CASTS = {
    # name: (scene, frames, step between frames, settle)
    'tornado': (TORNADO, 150, 1, 0.12),
    'orbits': (ORBITS, 150, 1, 0.12),
}


def cast(name, code, frames, step, settle):
    s = capture.Session()
    tmp = tempfile.mkdtemp(prefix='bee-cast-')
    try:
        s.q(code, timeout=120)
        s.op('view.shading_material')
        s.q('op("area.maximize")')
        s.f.move(capture.SIZE[0] - 5, capture.SIZE[1] - 5)
        s.f.pump(1.0)
        for i in range(frames):
            s.q('f = frame(%d)' % (1 + i * step), timeout=60)
            s.f.pump(settle)
            s.f.image().save(os.path.join(tmp, '%05d.png' % i))
        os.makedirs(OUT, exist_ok=True)
        out = os.path.join(OUT, name + '.mp4')
        subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-framerate', '30', '-i',
                        os.path.join(tmp, '%05d.png'), '-vf', 'crop=1600:920:0:56,scale=1280:-2',
                        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '24', '-movflags', '+faststart',
                        out], check=True)
        print(' ', out, os.path.getsize(out) // 1024, 'KiB', flush=True)
    finally:
        s.close()
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    only = set(a for a in sys.argv[1:] if '/' not in a)
    for name, (code, frames, step, settle) in CASTS.items():
        if only and name not in only:
            continue
        print('--', name, flush=True)
        cast(name, code, frames, step, settle)


if __name__ == '__main__':
    main()
