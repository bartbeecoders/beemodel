#!/usr/bin/env python3
"""The v0.11 exit check for virtualized geometry: tests/billion.bees builds a
landscape of n x n unique terrain tiles (a million triangles each) strewn
with linked copies of 8 million-triangle boulders - a billion source
triangles, every mesh a cluster LOD DAG standing in as a small proxy - and
saves it. This runs it (in an isolated HOME), reopens the file (the DAGs
stay mapped from it, every cut crack-free), then flies over it in a window
(the fake compositor): an overview with the whole billion in view, a low
pass over the ground, a close-up, orbits and zooms - each frame cut to one
pixel of error, culled, drawn. Cluster pages stream in under a budget (made
small part of the way to force evictions). Checks: frame times, the
memory the process ever held (< 8 GB), the pages read and given back.

    python3 tests/billion.py build/beemodel [outdir] [--tiles n] [--frame-ms ms]
"""
import os, shutil, subprocess, sys, tempfile, time

ARGS = [a for a in sys.argv[1:]]
def opt(name, default):
    if name in ARGS:
        i = ARGS.index(name)
        v = ARGS[i + 1]
        del ARGS[i:i + 2]
        return type(default)(v)
    return default
TILES = opt('--tiles', 8)
FRAME_MS = opt('--frame-ms', 50.0)             # interactive: 20 fps or better at the median
BIN = os.path.abspath(ARGS[0] if ARGS else 'build/beemodel')
OUT = ARGS[1] if len(ARGS) > 1 else None
HERE = os.path.dirname(os.path.abspath(__file__))
RSS_KB = 8 * 1024 * 1024                       # 8 GB
BUDGET_MB = 64                                 # the small budget part of the way
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(home, code):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=900)
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


def pct(lat, p):
    return lat[min(len(lat) - 1, int(len(lat) * p))] if lat else 1e9


def window(bee):
    """Open the file in a window and fly: returns the per-stage latencies,
    the statistics seen and the process's peak memory."""
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-bn-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    stat = lambda: [float(x) for x in q('print(' + ', '.join('vgstat(%d)' % k for k in range(16)) + ')').split()]
    f.enter(600, 300)
    f.move(600, 300)
    t = time.time()
    f.key(28); f.type('file.open ' + bee); f.key(28)     # as the user: the console
    while time.time() - t < 60 and q('print(vgeo("Tile0", 0))') != '2':
        f.pump(0.2)
    f.pump(1.0); f.key(1)
    opened = time.time() - t
    res = {'open': opened, 'lat': {}, 'stat': {}}

    def frames(name, act, n):
        lat = []
        for i in range(n):
            f.latencies = []
            f.t_input = time.time()
            act(i)
            f.pump(0.03)
            lat += f.latencies
        res['lat'][name] = sorted(lat)
        res['stat'][name] = stat()

    f.move(615, 340)
    q('view(40, 38, 1150, 0, 20, 0)')                    # the whole landscape
    f.pump(1.0)
    frames('overview', lambda i: f.wheel(10 if i % 2 else -10), 24)
    if OUT:
        f.shot('110_vgeo_billion.png')
    frames('orbit', lambda i: f.drag(560, 400, 620, 395, steps=6), 6)
    for k, (x, z) in enumerate([(-250, -250), (-120, -60), (0, 40), (120, 160), (260, 260)]):
        q('view(%d, 14, 90, %d, 45, %d)' % (30 + 25 * k, x, z))   # low over the ground
        frames('low%d' % k, lambda i: f.drag(600, 380, 640, 380, steps=4), 4)
    if OUT:
        f.shot('111_vgeo_low.png')
    q('op("vgeo.budget", "%d")' % BUDGET_MB)              # a small budget: pages go
    for k, (x, z) in enumerate([(200, -200), (-200, 200), (-300, 0), (300, 0)]):
        q('view(%d, 18, 70, %d, 45, %d)' % (200 - 30 * k, x, z))
        frames('budget%d' % k, lambda i: f.wheel(-10 if i < 3 else 10), 6)
    q('view(70, 10, 12, 30, 40, 30)')                     # a close-up, clusters coloured
    frames('close', lambda i: f.drag(600, 380, 630, 385, steps=4), 4)
    q('op("vgeo.view", "clusters")')
    f.pump(1.0)
    if OUT:
        f.shot('112_vgeo_clusters_close.png')
    res['stat']['end'] = stat()
    st = open('/proc/%d/status' % f.proc.pid).read()
    res['hwm'] = int(st.split('VmHWM:')[1].split()[0])
    res['rss'] = int(st.split('VmRSS:')[1].split()[0])
    f.proc.kill()
    return res


def main():
    print('  -- a billion triangles --')
    home = tempfile.mkdtemp(prefix='bee-bn-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    code = open(os.path.join(HERE, 'billion.bees')).read().replace('n = 8 ', 'n = %d ' % TILES, 1)
    t = time.time()
    out = run(home, code)
    secs = time.time() - t
    sc = out.get('scene', [])
    bee = os.path.join(home, 'BeeModel', 'billion.bee')
    size = os.path.getsize(bee) if os.path.exists(bee) else 0
    check(len(sc) == 5 and sc[0] == TILES * TILES and sc[3] >= 1e9,
          f'{sc[3:4]} source triangles: {sc[:1]} unique terrain tiles ({sc[1:2]} triangles), 8 boulders '
          f'and {sc[2:3]} linked copies, built and virtualized in {secs:.0f} s; saved ({size / 2**30:.2f} GB)')
    back = run(home, 'op("file.open", "~/BeeModel/billion.bee")\n'
                     'print("back", vgeo("Tile0", 0), vgeo("Tile0", 4), faces("Tile0"), vgeo("Rock3", 0), vgeo("Rock3", 4), faces("Rock3"))\n'
                     'print("cuts", vgeo("Tile' + str(TILES * TILES - 1) + '", 12), vgeo("Rock5", 12))\n')
    b, c = back.get('back', []), back.get('cuts', [])
    check(len(b) == 6 and b[0] == 2 and b[3] == 2 and b[1] > 1e6 and b[4] > 1e6 and b[2] < 4000 and b[5] < 200,
          f'reopened: each mesh a proxy ({b[2:3]}, {b[5:6]} triangles) for its DAG ({b[1:2]}, {b[4:5]}), mapped from the file')
    check(c == [1, 1], f'every cut of a streamed DAG crack-free (each level, 16 errors, 24 cameras) ({c})')
    r = window(bee)
    allf = sorted(x for v in r['lat'].values() for x in v)
    over = r['stat'].get('overview', [0] * 16)
    end = r['stat'].get('end', [0] * 16)
    med, p95 = pct(allf, 0.5), pct(allf, 0.95)
    check(over[6] >= 1e9 and over[0] >= 900,
          f'in the window: {over[6]:.0f} source triangles in {over[0]:.0f} objects in view, cut to {over[2]:.0f} '
          f'triangles in {over[1]:.0f} clusters (1 pixel of error), {over[13]:.1f} ms for the cuts')
    check(len(allf) > 50 and med < FRAME_MS,
          f'flying over it: {len(allf)} frames, {med:.1f} ms at the median, {p95:.1f} ms at the 95th percentile, '
          f'the slowest {allf[-1] if allf else 0:.1f} ms (overview {pct(r["lat"]["overview"], 0.5):.1f}, '
          f'low {pct(sorted(sum((r["lat"]["low%d" % k] for k in range(5)), [])), 0.5):.1f}, close {pct(r["lat"]["close"], 0.5):.1f})')
    occ = max(s[4] for s in r['stat'].values())
    check(occ > 0 and max(s[3] for s in r['stat'].values()) > 0,
          f'culled: up to {max(s[3] for s in r["stat"].values()):.0f} clusters by the frustum, {occ:.0f} occluded in the last frame\'s depth')
    check(end[10] > 0 and end[11] > 0 and end[7] <= BUDGET_MB and end[8] == BUDGET_MB,
          f'streamed: {end[10]:.0f} pages read from the file, {end[11]:.0f} given back under a {BUDGET_MB} MB budget '
          f'({end[7]:.0f} MB in memory at the end, {end[14]:.0f} streamed DAGs)')
    check(r['hwm'] < RSS_KB, f'the most memory the process held: {r["hwm"] / 1024:.0f} MB (under 8 GB; '
          f'{r["rss"] / 1024:.0f} MB at the end), the file opened in {r["open"]:.1f} s')
    shutil.rmtree(home, ignore_errors=True)
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\na billion triangles: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
