#!/usr/bin/env python3
"""The v0.11 world partition walkthrough: tests/world.bees makes a 32 x 32
map of 50 m cells (a piece of ground and three props each: 4096 objects, as
many as a scene holds at once) while partitioned, writing the cells behind
the camera as it goes. This runs it (in an isolated HOME), then flies over
the map in a window (the fake compositor) under a small memory budget:
cells stream in around the camera and out behind it, the unloaded ones
drawn as boxes, a minimap in the corner. On the way it edits: a prop is
carried into a cell far away (not loaded), another is deleted, a new one is
added. Flying away writes those cells; flying back finds the edits; the
scene is saved and opened again (headless) to check the files.

    python3 tests/world.py build/beemodel [outdir] [--frame-ms ms]
"""
import os, shutil, subprocess, sys, tempfile, time

ARGS = list(sys.argv[1:])
def opt(name, default):
    if name in ARGS:
        i = ARGS.index(name)
        v = ARGS[i + 1]
        del ARGS[i:i + 2]
        return type(default)(v)
    return default
FRAME_MS = opt('--frame-ms', 16.7)
BIN = os.path.abspath(ARGS[0] if ARGS else 'build/beemodel')
OUT = ARGS[1] if len(ARGS) > 1 else None
HERE = os.path.dirname(os.path.abspath(__file__))
BUDGET_MB = 8
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
                out[w[0]] = w[1:]
    if r.returncode != 0 or r.stderr.strip():
        print(r.stdout[-2000:], r.stderr[-2000:])
    return out


def window(bee):
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-wp-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    st = lambda: [float(x) for x in q('print(' + ', '.join('world(%d)' % k for k in range(14)) + ')').split()]
    has = lambda name: q('print(get("%s", "x"))' % name)
    def con(c):
        f.key(28); f.type(c); f.key(28); f.pump(1.5); f.key(1)
    f.enter(600, 300)
    f.move(600, 300)
    con('file.open ' + bee)
    q('op("world.budget", "%d")\nop("world.radius", "150")' % BUDGET_MB)
    res = {'lat': [], 'mb': [], 'loaded': []}

    def fly(points, settle=True):
        for (yaw, x, z) in points:
            f.latencies = []
            f.t_input = time.time()
            q('view(%d, 22, 90, %d, 25, %d)' % (yaw, x, z))
            f.pump(0.05)
            res['lat'] += f.latencies
            t = time.time()
            while settle and time.time() - t < 3 and st()[13] > 0:   # cells in reach still coming
                f.latencies = []
                f.pump(0.03)
                res['lat'] += f.latencies
            s = st()
            res['mb'].append(s[3])
            res['loaded'].append(s[2])

    # across the map, then home
    path = [(30 + 7 * k, -700 + 45 * k, -600 + 38 * k) for k in range(30)]
    fly(path)
    fly([(45, 0, 0)])
    if OUT:
        q('view(40, 40, 420, 0, 20, 0)')
        f.pump(1.5)
        f.shot('114_world_cells.png')
        q('view(45, 22, 90, 0, 25, 0)')
        f.pump(1.0)
    s0 = st()
    # edits: one prop carried far (into a cell not loaded), one deleted, one added
    q('move("Prop_16_16_0", 325, 30, 325)\nselect("Prop_16_16_1")\nop("object.delete")\nadd("cube", "Marker", 10, 30, 10)\nscale("Marker", 4)')
    f.pump(0.5)
    s1 = st()
    moved_now = has('Prop_16_16_0')
    fly([(200, 700, -700), (220, 650, -650)])        # far away: the edited cells go out
    s2 = st()
    gone = (has('Marker'), has('Prop_16_16_0'))
    fly([(45, 0, 0)])                               # back home
    back = (has('Marker'), has('Prop_16_16_1'), has('Prop_16_16_2'))
    fly([(45, 325, 325)])                           # where the prop went
    there = has('Prop_16_16_0')
    con('file.save ' + bee)
    st_end = st()
    status = open('/proc/%d/status' % f.proc.pid).read()
    res['hwm'] = int(status.split('VmHWM:')[1].split()[0])
    f.proc.kill()
    res.update(s0=s0, s1=s1, s2=s2, moved_now=moved_now, gone=gone, back=back, there=there, end=st_end)
    return res


def main():
    print('  -- a world in cells --')
    home = tempfile.mkdtemp(prefix='bee-wp-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    t = time.time()
    out = run(home, open(os.path.join(HERE, 'world.bees')).read())
    secs = time.time() - t
    w = out.get('world', [])
    cells = os.path.join(home, 'BeeModel', 'world.cells')
    files = len(os.listdir(cells)) if os.path.isdir(cells) else 0
    size = sum(os.path.getsize(os.path.join(cells, n)) for n in os.listdir(cells)) if files else 0
    main_size = os.path.getsize(os.path.join(home, 'BeeModel', 'world.bee'))
    check(len(w) == 5 and w[0] == 1024 and w[1] == 1024 and files == 1024 and w[3] < 300 and main_size < 200000,
          f'a 32 x 32 map (4096 objects) made while partitioned in {secs:.1f} s: {files} cell files '
          f'({size / 2**20:.0f} MB), the scene file {main_size} bytes, {w[3:4]} objects in memory at the end')
    bee = os.path.join(home, 'BeeModel', 'world.bee')
    r = window(bee)
    lat = sorted(r['lat'])
    med = lat[len(lat) // 2] if lat else 1e9
    p95 = lat[int(len(lat) * 0.95)] if lat else 1e9
    check(max(r['mb']) <= BUDGET_MB and max(r['loaded']) >= 10 and r['s0'][6] > 100 and r['s0'][7] > 50,
          f'flown across: {r["s0"][6]:.0f} cells loaded and {r["s0"][7]:.0f} unloaded on the way, at most '
          f'{max(r["loaded"]):.0f} in memory ({max(r["mb"]):.1f} MB, budget {BUDGET_MB} MB)')
    check(len(lat) > 30 and med < FRAME_MS,
          f'{len(lat)} frames while streaming: {med:.1f} ms at the median, {p95:.1f} ms at the 95th percentile')
    check(r['s1'][8] >= 1 and r['s1'][12] >= 1 and (r['moved_now'] == '325' or r['s1'][5] > r['s0'][5]),
          f'edits: the carried prop pulls its new cell in ({r["s1"][12]:.0f} cell crossed into; past the budget it is '
          f'written and goes again), {r["s1"][8]:.0f} loaded cell changed')
    check(r['gone'][0].startswith('error') and r['gone'][1].startswith('error') and r['s2'][5] > r['s0'][5],
          f'flying away writes them before they unload ({r["s2"][5] - r["s0"][5]:.0f} cells written)')
    check(r['back'][0] == '10' and r['back'][1].startswith('error') and r['back'][2] == '40' and r['there'] == '325',
          f'flying back: the new prop is there, the deleted one is not, the carried one is in its new cell ({r["back"]}, {r["there"]})')
    check(r['hwm'] < 1024 * 1024, f'the process never held more than {r["hwm"] / 1024:.0f} MB')
    back = run(home, 'op("file.open", "~/BeeModel/world.bee")\nprint("open", world(0), world(1), world(2))\n'
                     'view(45, 22, 90, 325, 25, 325)\nop("world.update")\nprint("far", get("Prop_16_16_0", "x"), world(2))\n'
                     'view(45, 22, 90, 0, 25, 0)\nop("world.update")\nprint("home", get("Marker", "x"), get("Prop_16_16_2", "x"))\n')
    check(back.get('open') == [1, 1024, 0] and back.get('far', [0])[0] == 325 and back.get('home') == [10, 40],
          f'saved and opened again: 1024 cells on disk, none loaded until the camera comes; the edits are in their cells '
          f'({back.get("open")}, {back.get("far")}, {back.get("home")})')
    shutil.rmtree(home, ignore_errors=True)
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\na world in cells: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
