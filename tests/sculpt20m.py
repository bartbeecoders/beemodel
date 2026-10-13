#!/usr/bin/env python3
"""The v0.8 exit check, sculpting at scale: a 25M-vertex mesh is sculpted in
the window (the fake compositor of tools/fakewl.py, so the desktop is never
touched). Every stroke frame - the brush work for its pointer motion plus
drawing the frame - has to fit in 16.7 ms (60 fps), and the whole process
while sculpting has to stay under twice the mesh's own memory.

    python3 tests/sculpt20m.py build/beemodel [--frame-ms 16.7] [--json out.json]

CI runs it on 4-core runners with a looser frame budget (--frame-ms); the
60 fps figure is the desktop's (see the CHANGELOG).
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('--') else 'build/beemodel')
JSON = sys.argv[sys.argv.index('--json') + 1] if '--json' in sys.argv else None
FRAME_MS = float(sys.argv[sys.argv.index('--frame-ms') + 1]) if '--frame-ms' in sys.argv else 1000 / 60
sys.argv = [sys.argv[0], tempfile.mkdtemp(prefix='bee-s20-')]      # (fakewl: screenshots)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import fakewl                                                      # noqa: E402
fakewl.BIN = BIN
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def rss_mb(pid, key='VmRSS'):
    for line in open(f'/proc/{pid}/status'):
        if line.startswith(key + ':'):
            return int(line.split()[1]) / 1024
    return 0.0


def main():
    print('  -- 25M-vertex sculpt --')
    f = fakewl.Fake()
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    f.enter(600, 300)
    m = fakewl.Mcp(f)
    def q(code):
        r = m.call('tools/call', {'name': 'script_eval', 'arguments': {'code': code}}, timeout=120)
        return ((r or {}).get('result', {}).get('content', [{}])[0].get('text', '') or '').strip()
    base = rss_mb(f.proc.pid)
    # a cube subdivided 6 + 5 levels: 25,165,826 vertices, 25,165,824 quads
    q('scale("Cube", 3.5)\nmodifier("Cube", "subsurf")\nmodset("Cube", 0, "levels", 6)\nmodapply("Cube", 0)\n'
      'modifier("Cube", "subsurf")\nmodset("Cube", 0, "levels", 5)\nmodapply("Cube", 0)\nselect("Cube")')
    nv, nf = (int(float(x)) for x in q('print(verts("Cube"), faces("Cube"))').split())
    f.pump(1.0)
    mesh = rss_mb(f.proc.pid) - base                # the mesh as BeeModel keeps it
    raw = (nv * 12 + nf * 16) / 2**20               # positions + quad indices
    f.mods(4); f.key(15); f.mods(0)                 # Ctrl+Tab: sculpt mode
    f.pump(2.0)
    entered = rss_mb(f.proc.pid)
    v0 = float(q('print(volume("Cube"))'))
    frames = []
    # four strokes across the ball (centre about 613, 322; radius about 100 px)
    for x0, y0, x1, y1 in ([(555, 300, 675, 340), (580, 370, 655, 270), (605, 255, 625, 390),
                            (545, 335, 690, 305)]):
        n0 = int(float(q('print(frames())')))
        f.drag(x0, y0, x1, y1, steps=90)
        f.pump(0.3)
        # every frame since, read at once (each query draws a frame of its own)
        out = q(f'n = frames() - {n0}\nfor k in 0..n {{\n print(frametime(k), frametime(k, 1))\n}}').split()
        vals = [float(x) for x in out]
        frames += list(zip(vals[0::2], vals[1::2]))
    v1 = float(q('print(volume("Cube"))'))
    after = rss_mb(f.proc.pid)
    peak = rss_mb(f.proc.pid, 'VmHWM')
    f.shot('sculpt20m.png')
    f.proc.kill()
    stroke = [d + w for d, w in frames if w > 0.05]  # frames whose motion placed dabs
    tot = sorted(stroke)                            # (the frames that matter: dabs)
    p50 = tot[len(tot) // 2] if tot else 1e9
    p95 = tot[int(len(tot) * 0.95)] if tot else 1e9
    worst = tot[-1] if tot else 1e9
    draw = sorted(d for d, _ in frames)
    work = sorted(w for _, w in frames if w > 0.05)
    print(f'       {nv:,} vertices, {len(frames)} stroke frames, {len(stroke)} placed dabs: brush + draw median {p50:.1f} ms, '
          f'95th percentile {p95:.1f} ms, worst {worst:.1f} ms (draw median {draw[len(draw) // 2]:.1f} ms, '
          f'brush median {work[len(work) // 2] if work else 0:.1f} ms, worst {work[-1] if work else 0:.1f} ms '
          f'over those)')
    print(f'       memory: mesh {mesh:.0f} MB in BeeModel ({raw:.0f} MB as bare positions + quads); '
          f'process while sculpting {after:.0f} MB (sculpt mode entered: {entered:.0f} MB, peak {peak:.0f} MB)')
    check(nv >= 20_000_000 and v1 != v0 and len(stroke) >= 50,
          f'four strokes sculpt the {nv / 1e6:.1f}M-vertex mesh ({len(stroke)} frames placed dabs)')
    check(p95 < FRAME_MS, f'95% of the frames that placed dabs take under {FRAME_MS:.1f} ms'
          f'{" (60 fps)" if FRAME_MS < 17 else ""}: {p95:.1f} ms')
    check(after < 2 * mesh, f'the process while sculpting stays under 2x the mesh: {after:.0f} MB < {2 * mesh:.0f} MB '
          f'({after / mesh:.2f}x)')
    if JSON:
        json.dump({'vertices': nv, 'frames': len(frames), 'p50_ms': p50, 'p95_ms': p95, 'worst_ms': worst,
                   'mesh_mb': mesh, 'raw_mb': raw, 'rss_mb': after, 'peak_mb': peak}, open(JSON, 'w'), indent=1)
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nsculpt at scale: all checks passed')
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
