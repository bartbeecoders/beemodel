#!/usr/bin/env python3
"""The v0.11 play mode walkthrough. A small level - a floor, walls, a flight
of stairs up to a platform, a ramp and a slope too steep to walk, a stack of
rigid boxes, a keyed spinner - is played from a script (BeeScript drives
play mode the way the keyboard does): the walker falls onto the floor, is
stopped by the walls, climbs the stairs, walks the ramp but not the steep
slope, jumps; the boxes fall and the spinner turns while it plays. Stopping
discards everything (the scene, the frame), or keeps it as one undo step.
Then in a window (the fake compositor): F5 plays with the mouse captured
(a locked pointer, relative motion), held keys walk, Esc asks, K keeps, D
discards; and over MCP.

    python3 tests/play.py build/beemodel [outdir]
"""
import os, subprocess, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


LEVEL = '''
delete("Cube")
add("plane", "Floor", 0, 0, 0)
scale("Floor", 30)
add("cube", "WallN", 0, 1.5, -12)
scale("WallN", 12, 1.5, 0.2)
add("cube", "WallE", 12, 1.5, 0)
scale("WallE", 0.2, 1.5, 12)
for i in 0..6 {
 s = add("cube", "Stair" + str(i), -6, 0.125 + 0.125 * i, -2 - 0.5 * i)
 scale(s, 1.2, 0.125 + 0.125 * i, 0.25)
}
add("cube", "Platform", -6, 0.75, -6)
scale("Platform", 1.2, 0.75, 1.2)
add("cube", "Ramp", 4, 0, -4)
scale("Ramp", 1.2, 0.1, 3)
rotate("Ramp", 0.3, 0, 0)
add("cube", "Steep", 8, 0, -4)
scale("Steep", 1.2, 0.1, 3)
rotate("Steep", 1.15, 0, 0)
for k in 0..4 {
 b = add("cube", "Box" + str(k), 2 + 0.1 * k, 1 + 1.1 * k, 4)
 scale(b, 0.5)
}
select("Box0", "Box1", "Box2", "Box3")
op("rigid.add", "active box")
select("Floor")
op("rigid.add", "passive box")
add("cube", "Spinner", -3, 1, 5)
key("Spinner:ry", 1, 0, "linear")
key("Spinner:ry", 49, 6.28, "linear")
select()
fn at(t) { print(t, round(playinfo(1) * 100) / 100, round(playinfo(2) * 100) / 100, round(playinfo(3) * 100) / 100, playinfo(4)) }
'''

PLAY = LEVEL + '''
op("file.save", "~/BeeModel/level.bee")
op("play.start", "walk 0 4 0")
print("started", playinfo(0), playinfo(8), playinfo(12))
playstep(1.5)
at("landed")
playlook(0, 0)
playstep(4, 1, 0, 0)
at("wall")
print("sim", round(get("Box3", "y") * 100) / 100, round(playinfo(12)), round(get("Spinner", "ry") * 100) / 100)
op("play.stop")
print("discarded", playinfo(0), round(get("Box3", "y") * 100) / 100, frame(), get("Spinner", "ry"))
op("play.start", "walk -6 1.8 1")
playstep(0.5)
playlook(0, 0)
playstep(1.6, 1, 0, 0)
at("stairs")
op("play.stop")
op("play.start", "walk 4 1.8 0")
playstep(0.5)
playlook(0, 0)
playstep(1.6, 1, 0, 0)
at("ramp")
op("play.stop")
op("play.start", "walk 8 1.8 0")
playstep(0.5)
playlook(0, 0)
playstep(3, 1, 0, 0)
at("steep")
playstep(0.15, 0, 0, 1)
at("jump")
playstep(1)
at("down")
op("play.mode", "fly")
playlook(0, -45)
playstep(1, 1, 0, 0)
at("fly")
op("play.stop")
op("play.start", "walk 0 4 0")
playstep(2)
y = get("Box3", "y")
op("play.stop", "keep")
print("kept", playinfo(0), get("Box3", "y") == y, frame() > 40)
'''


def run(home, code):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
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


def window(home):
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-pl-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    info = lambda: [float(x) for x in q('print(' + ', '.join('playinfo(%d)' % k for k in range(16)) + ')').split()]
    res = {}
    f.enter(600, 300)
    f.move(600, 300)
    q(LEVEL.replace('fn at(t)', 'fn at_(t)') + '\nview(20, 15, 12, 0, 1.6, 6)')
    f.pump(0.5)
    f.key(63)                                       # F5
    f.pump(0.3)
    res['start'] = info()
    res['hidden'] = getattr(f, 'cursor_hidden', False)
    f.keyev(17, True)                               # W held for a second
    t0, n0 = time.time(), f.frames
    while time.time() - t0 < 1.0:
        f.pump(0.05)
    f.keyev(17, False)
    res['fps'] = (f.frames - n0) / (time.time() - t0)
    f.pump(0.2)
    res['walked'] = info()
    for _ in range(10):                             # the mouse turns the view
        f.rel(20, 0)
    f.pump(0.2)
    res['turned'] = info()
    if OUT:
        f.shot('117_play_mode.png')
    f.key(1)                                        # Esc: the question
    f.pump(0.3)
    res['asking'] = info()
    if OUT:
        f.shot('118_play_ask.png')
    f.key(37)                                       # K: kept
    f.pump(0.3)
    res['kept'] = (info()[0], q('print(get("Box3", "y") < 4.2, frame() > 20)'))
    f.mods(4); f.key(44); f.mods(0)               # Ctrl+Z
    f.pump(0.3)
    res['undo'] = q('print(round(get("Box3", "y") * 100) / 100)')
    q('frame(1)')                                   # (the playhead is not undone)
    f.key(63)                                       # again: D discards
    f.pump(0.3)
    f.keyev(17, True)
    f.pump(0.6)
    f.keyev(17, False)
    f.key(1)
    f.key(32)
    f.pump(0.3)
    res['discard'] = (info()[0], q('print(round(get("Box3", "y") * 100) / 100, frame())'))
    m.tool('op_play_start', {'arg': 'fly 0 3 6'})   # over MCP
    q('playlook(0, 0)\nplaystep(1, 1, 0, 0)')
    res['mcp'] = info()
    m.tool('op_play_stop', {'arg': 'discard'})
    res['mcp_end'] = info()[0]
    f.proc.kill()
    return res


def main():
    print('  -- play mode --')
    home = tempfile.mkdtemp(prefix='bee-pl-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    o = run(home, PLAY)
    g = lambda k: o.get(k, [])
    check(g('started') == [1, 1, 1] and g('landed')[1:] == [0, 0, 1],
          f'play.start walks from the given eye: it falls onto the floor and stands ({g("landed")})')
    check(g('wall')[2:] == [-11.5, 1],
          f'walking north for 4 s it stops at the wall (its face at z -11.8, the capsule 0.3 wide: {g("wall")})')
    sim = g('sim')
    check(len(sim) == 3 and sim[0] < 4 and sim[1] > 120 and abs(sim[2] - 6.28) < 0.6,
          f'meanwhile the scene runs: the top box fell to {sim[:1]}, the frame went on to {sim[1:2]}, '
          f'the spinner turned ({sim[2:]})')
    check(g('discarded')[:2] == [0, 4.3] and g('discarded')[2] == 1 and g('discarded')[3] == 0,
          f'play.stop discards: the boxes, the frame, the spinner as they were ({g("discarded")})')
    check(g('stairs')[1] > 1.4 and g('stairs')[3] == 1,
          f'up the stairs (0.25 m each) onto the platform at 1.5 m ({g("stairs")})')
    check(g('ramp')[1] > 0.5 and g('steep')[1] < 0.05 and g('steep')[2] > -5,
          f'up the ramp ({g("ramp")[1:2]} m), not the steep slope (stopped at z {g("steep")[2:3]})')
    check(g('jump')[3] == 0 and g('jump')[1] > 0.3 and g('down')[1] < 0.05 and g('down')[3] == 1,
          f'Space jumps ({g("jump")[1:2]} m up after 0.15 s) and it lands ({g("down")})')
    check(g('fly')[1] > 5,
          f'fly mode goes where it looks, through nothing ({g("fly")})')
    check(g('kept') == [0, 1, 1],
          f'play.stop keep: the fallen boxes and the frame stay ({g("kept")})')
    r = window(home)
    s, w, t, a = r['start'], r['walked'], r['turned'], r['asking']
    check(s[0] == 1 and s[13] == 1 and r['hidden'],
          f'F5 plays: the pointer locked, its cursor hidden ({s[0]}, {s[13]}, {r["hidden"]})')
    moved = ((w[1] - s[1]) ** 2 + (w[3] - s[3]) ** 2) ** 0.5
    check(moved > 2.5 and r['fps'] > 15 and w[12] > s[12] + 15,
          f'W held for a second walks {moved:.1f} m at {r["fps"]:.0f} frames a second while the scene plays '
          f'(frame {s[12]:.0f} -> {w[12]:.0f})')
    check(abs((t[9] - w[9]) + 200 * 0.0025 * 57.29578) < 1,
          f'relative mouse motion turns the view ({w[9]:.1f} -> {t[9]:.1f} degrees)')
    check(a[0] == 2 and a[13] == 0 and r['kept'] == (0, '1 1') and r['undo'] == '4.3',
          f'Esc asks (the pointer free), K keeps, Ctrl+Z takes it back ({r["kept"]}, {r["undo"]})')
    check(r['discard'] == (0, '4.3 1'), f'F5, Esc, D: discarded ({r["discard"]})')
    check(r['mcp'][0] == 1 and r['mcp'][8] == 2 and r['mcp'][3] < -1 and r['mcp_end'] == 0,
          f'over MCP: op_play_start fly, playstep, op_play_stop ({r["mcp"][:4]})')
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nplay mode: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
