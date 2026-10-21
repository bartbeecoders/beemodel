#!/usr/bin/env python3
"""The v0.10 walkthrough: tests/animation.bees builds a character (an SDF
body skinned to a 12-bone armature, IK legs on keyed feet: a walk cycle), a
gear pair turned by a keyed parameter, 1000 rigid boxes falling into a heap
and a tablecloth draping over a table; bakes 10 s of simulation, saves the
scene and renders three frames. This runs it (in an isolated HOME), checks
the numbers and the budgets, that the .bee file brings the bake back, and
then plays the saved scene in a window (the fake compositor): a frame
stepped in under 16.7 ms (60 fps).

    python3 tests/animation.py build/beemodel [outdir]
"""
import os, shutil, subprocess, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
CI = 2 if os.environ.get('CI') else 1
FRAME_MS = 16.7                    # a played frame (exit criterion: 60 fps)
BAKE_MS = 30000.0                  # 10 s of 1000 boxes, the cloth, the rig (a 4-core runner)
BUDGET_S = 120.0                   # end to end
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(home, code):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=600)
    out = {}
    for line in r.stdout.splitlines():
        w = line.split()
        if w:
            try:
                out[w[0]] = [float(x) for x in w[1:]]
            except ValueError:
                pass
    if r.returncode != 0 or r.stderr.strip():
        print(r.stdout[-2000:], r.stderr[-2000:])
    return out


def window(bee):
    """The saved scene in a window: Right steps a frame (keys, IK, skin, the
    mechanism, the baked bodies and cloth, drawn)."""
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-an-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    os.makedirs(os.path.join(f.home, 'BeeModel'), exist_ok=True)
    shutil.copy(bee, os.path.join(f.home, 'BeeModel', 'animation.bee'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(600, 300)
    f.move(600, 300)
    f.key(28); f.type('file.open ' + os.path.join(f.home, 'BeeModel', 'animation.bee')); f.key(28)   # as the user: the console
    f.pump(1.0); f.key(1)
    q('frame(1)')
    f.pump(0.5)
    f.move(600, 300)
    lat = []
    for _ in range(48):
        f.latencies = []
        f.t_input = time.time()
        f.key(106)                                  # Right: one frame on
        lat += f.latencies
    fr = q('print(frame(), cacheinfo(3), cacheinfo(4))')
    if OUT:
        f.shot('animation_window.png')
    f.proc.kill()
    lat = sorted(lat[1:])
    return fr, lat


def main():
    print('  -- animation walkthrough --')
    home = tempfile.mkdtemp(prefix='bee-an-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    t = time.time()
    out = run(home, open(os.path.join(HERE, 'animation.bees')).read())
    secs = time.time() - t
    ch, walk, mech, sim, scrub, same, played, rend = (out.get(k, []) for k in
        ('character', 'walk', 'mechanism', 'simulated', 'scrub', 'same', 'played', 'rendered'))
    check(len(ch) == 3 and ch[0] > 150000 and ch[1] == 12,
          f'a character: a {ch[:1]}-vertex SDF body skinned to 12 bones by automatic weights ({ch[2:]} ms)')
    check(len(walk) == 3 and walk[0] > 0 and walk[1] < -25 and abs(walk[2] + 30) <= 1,
          f'the walk: IK legs follow the keyed feet, the skin with them (toe z {walk[:2]} cm, shin tip {walk[2:]})')
    check(mech == [314, -628, -400], f'a keyed crank parameter turns the gear, the pinion at -2x, the crank on it ({mech})')
    check(len(sim) == 9 and sim[0] == 1000 and sim[1] == 1681 and sim[2] == 239 and sim[3] == 239 and sim[4] == 2
          and sim[5] < BAKE_MS * CI and sim[6:] == [1, 1, 1],
          f'1000 boxes and a 1681-particle cloth baked over 239 frames in {sim[5:6]} ms; none through the floor, '
          f'the cloth draped below the table top ({sim})')
    check(len(scrub) == 1 and scrub[0] < FRAME_MS * CI and same == [1],
          f'scrubbed back through the bake at {scrub} ms a frame, the same places')
    check(len(played) == 2 and played[0] < FRAME_MS * CI,
          f'a played frame (keys, IK, skin, mechanism, the bake) evaluates in {played[:1]} ms, the slowest {played[1:]}')
    d = os.path.join(home, 'BeeModel')
    files = ['animation.bee', 'animation_1.png', 'animation_120.png', 'animation_240.png']
    check(all(os.path.exists(os.path.join(d, f)) for f in files) and len(rend) == 1,
          f'saved; frames 1, 120 and 240 rendered in {rend} ms')
    back = run(home, 'op("file.open", "~/BeeModel/animation.bee")\nframe(240)\n'
                     'print("back", cacheinfo(0), cacheinfo(1), cacheinfo(3), cacheinfo(4), get("B555", "y") < 2, bones("Rig"))\n')
    b = back.get('back', [])
    check(b == [239, 239, 1, 1, 1, 12], f'the .bee file brings the rig and the bake back ({b})')
    check(secs < BUDGET_S, f'the walkthrough runs in {secs:.1f} s (budget {BUDGET_S:.0f} s)')
    fr, lat = window(os.path.join(d, 'animation.bee'))
    ms = lat[len(lat) // 2] if lat else 1e9
    budget = FRAME_MS * (3 if CI > 1 else 1)        # (GitHub's 20261018 runners take ~35 ms where
    check(fr == '49 1 1' and ms < budget,            #  20261012's took ~25, the same build; 12 ms locally)
          f'in the window, Right steps the scene a frame in {ms:.1f} ms at the median, '
          f'{lat[int(len(lat) * 0.95)] if lat else 0:.1f} ms at the 95th percentile, budget {budget:.1f} ({fr})')
    if OUT:
        os.makedirs(OUT, exist_ok=True)
        for f in files[1:]:
            if os.path.exists(os.path.join(d, f)):
                shutil.copy(os.path.join(d, f), os.path.join(OUT, f))
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nanimation walkthrough: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
