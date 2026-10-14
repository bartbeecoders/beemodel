#!/usr/bin/env python3
"""The v0.11 logic graphs walkthrough. A level with logic: a door that opens
when the player comes near (On Overlap -> Play Action), coins that spin and
are picked up (On Tick -> Rotate; On Overlap -> Destroy -> Send Message), a
score that counts them (On Message -> Set Variable; a timer, a branch, Get
Property), E spawning another coin (On Key -> Spawn), a ball pushed when
play begins (Begin Play -> Apply Impulse) and a moving platform the player
rides (On Tick -> Move to Start + sin(Time) x 2). Played from scripts
(saved and opened again, twice to the same result, a message storm kept
within the step budget), then in a window: the node editor shows a logic
graph, Shift+A adds a node, pressing a name value lets the console set it,
F5 and E spawn, and over MCP.

    python3 tests/logic.py build/beemodel [outdir]
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
scale("Floor", 20)
add("cube", "Door", 0, 1.25, -5)
scale("Door", 1, 1.25, 0.1)
key("Door:y", 1, 1.25, "linear")
key("Door:y", 25, 3.6, "linear")
select("Door")
op("anim.action", "DoorOpen")
unkey("Door:y", 1)
unkey("Door:y", 25)
op("logic.new", "DoorLogic")
op("logic.node", "DoorLogic overlap 0 0 1.5")
op("logic.node", "DoorLogic play_action")
op("logic.name", "DoorLogic 2 4 DoorOpen")
op("tree.link", "DoorLogic 1 2 1")
op("logic.attach", "DoorLogic Door")
add("cube", "Coin", 3, 0.5, 0)
scale("Coin", 0.2)
op("logic.new", "CoinLogic")
op("logic.node", "CoinLogic overlap 0 0 0.2")
op("logic.node", "CoinLogic destroy")
op("logic.node", "CoinLogic send")
op("logic.name", "CoinLogic 3 4 picked")
op("tree.link", "CoinLogic 1 2 1")
op("tree.link", "CoinLogic 2 3 1")
op("logic.node", "CoinLogic tick")
op("logic.node", "CoinLogic rotate")
op("tree.node_set", "CoinLogic 5 2 0 1 0")
op("tree.link", "CoinLogic 4 5 1")
op("logic.attach", "CoinLogic Coin")
add("cube", "Score", 0, 5, 5)
scale("Score", 0.2)
op("logic.new", "ScoreLogic")
op("logic.node", "ScoreLogic message")
op("logic.name", "ScoreLogic 1 4 picked")
op("logic.node", "ScoreLogic set_variable 0 1")
op("tree.link", "ScoreLogic 1 2 1")
op("tree.link", "ScoreLogic 1:1 2 2")
op("logic.node", "ScoreLogic timer 0.5 0")
op("logic.node", "ScoreLogic set_variable 1")
op("tree.node_set", "ScoreLogic 4 2 7 7 7")
op("tree.link", "ScoreLogic 3 4 1")
op("logic.node", "ScoreLogic key 18 0")
op("logic.node", "ScoreLogic spawn")
op("logic.name", "ScoreLogic 6 4 Coin")
op("tree.node_set", "ScoreLogic 6 2 3 -5 -2")
op("tree.link", "ScoreLogic 5 6 1")
op("logic.node", "ScoreLogic tick")
op("logic.node", "ScoreLogic branch")
op("logic.node", "ScoreLogic variable 0")
op("logic.node", "ScoreLogic math 8")
op("tree.node_set", "ScoreLogic 10 2 0.5")
op("tree.link", "ScoreLogic 9 10 1")
op("tree.link", "ScoreLogic 10 8 2")
op("tree.link", "ScoreLogic 7 8 1")
op("logic.node", "ScoreLogic set_variable 2")
op("tree.node_set", "ScoreLogic 11 2 1")
op("tree.link", "ScoreLogic 8:0 11 1")
op("logic.node", "ScoreLogic set_variable 3")
op("logic.node", "ScoreLogic get_property")
op("logic.name", "ScoreLogic 13 4 x")
op("logic.name", "ScoreLogic 13 5 Coin")
op("tree.link", "ScoreLogic 13 12 2")
op("tree.link", "ScoreLogic 7 12 1")
op("logic.attach", "ScoreLogic Score")
add("cube", "Ball", -3, 0.5, 3)
scale("Ball", 0.5)
select("Ball")
op("rigid.add", "active box")
select("Floor")
op("rigid.add", "passive box")
op("logic.new", "BallLogic")
op("logic.node", "BallLogic begin")
op("logic.node", "BallLogic impulse")
op("tree.node_set", "BallLogic 2 2 0 0 -4")
op("tree.link", "BallLogic 1 2 1")
op("logic.attach", "BallLogic Ball")
add("cube", "Lift", -4, 0.25, -3)
scale("Lift", 1, 0.25, 1)
op("logic.new", "LiftLogic")
op("logic.node", "LiftLogic tick")
op("logic.node", "LiftLogic move 1")
op("logic.node", "LiftLogic info 4")
op("logic.node", "LiftLogic info 0")
op("logic.node", "LiftLogic math 6")
op("logic.node", "LiftLogic math 17")
op("logic.node", "LiftLogic math 0")
op("tree.link", "LiftLogic 1:0 2 1")
op("tree.link", "LiftLogic 4 5 1")
op("tree.node_set", "LiftLogic 6 1 2 0 0")
op("tree.link", "LiftLogic 5 6 2")
op("tree.link", "LiftLogic 3 7 1")
op("tree.link", "LiftLogic 6 7 2")
op("tree.link", "LiftLogic 7 2 2")
op("logic.attach", "LiftLogic Lift")
select()
fn r(v) { return round(v * 100) / 100 }
'''

PLAY = LEVEL + '''
op("file.save", "~/BeeModel/level.bee")
op("play.start", "walk 3 1.8 3")
playstep(0.6)
print("started", logic(0), logic(1), logicvar("Score", 1), logicvar("Score", 3))
playlook(0, 0)
playstep(1.2, 1, 0, 0)
print("coin", r(playinfo(3)), logicvar("Score", 0), logicvar("Score", 2), logic(4))
playkey(18, 1)
playstep(0.1)
playkey(18, 0)
print("spawned", logic(5), logic(1), get("Coin.001", "x"), get("Coin.001", "z"), r(get("Coin.001", "ry")))
playstep(0.5)
print("spins", r(get("Coin.001", "ry")) > 0.5)
op("play.stop", "keep")
print("kept", logicvar("Score", 0) == nil, frame() > 20)
op("file.open", "~/BeeModel/level.bee")
op("play.start", "walk 0 1.8 0")
playstep(0.5)
playlook(0, 0)
playstep(2, 1, 0, 0)
print("door", r(get("Door", "y")), r(playinfo(3)))
print("ball", r(get("Ball", "z")))
op("play.stop", "discard")
print("discard", get("Door", "y"), get("Ball", "z"))
op("play.start", "walk -4 2.5 -3")
playstep(0.5)
print("lift0", r(get("Lift", "x")), r(playinfo(1)), r(playinfo(2)))
playstep(1.07)
print("lift1", r(get("Lift", "x")), r(playinfo(1)), r(playinfo(2)), playinfo(4))
op("play.stop")
'''

SAME = LEVEL + '''
op("play.start", "walk 2 1.8 4")
playlook(30, 0)
playstep(1.5, 1, 0, 0)
playkey(18, 1)
playstep(1)
playkey(18, 0)
playstep(1, 1, 1, 0)
print("state", get("Ball", "x"), get("Ball", "z"), get("Lift", "x"), get("Coin", "ry"), get("Coin.001", "ry"), playinfo(1), playinfo(3), logic(2), logic(3))
'''

STORM = '''
op("logic.new", "Storm")
op("logic.node", "Storm message")
op("logic.name", "Storm 1 4 ping")
op("logic.node", "Storm send")
op("logic.name", "Storm 2 4 ping")
op("tree.link", "Storm 1 2 1")
op("logic.node", "Storm begin")
op("logic.node", "Storm send")
op("logic.name", "Storm 4 4 ping")
op("tree.link", "Storm 3 4 1")
op("logic.node", "Storm set_variable 0 1")
op("tree.node_set", "Storm 5 2 1")
op("tree.link", "Storm 1 5 1")
'''
for i in range(30):                         # each ping runs 30 more nodes
    STORM += 'op("logic.node", "Storm set_variable 1 1")\nop("tree.link", "Storm 1 %d 1")\n' % (6 + i)
STORM += '''op("logic.attach", "Storm Cube")
op("play.start", "fly 0 3 6")
playstep(0.1)
print("storm", logic(6) > 0, logic(7) <= 4096, logic(7), playinfo(11) > 0.09, logic(4))
op("play.stop")
'''


def run(home, code):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
    out = {}
    for line in r.stdout.splitlines():
        w = line.split()
        if w:
            vals = []
            for x in w[1:]:
                try:
                    vals.append(float(x))
                except ValueError:
                    vals.append(x)
            out[w[0]] = vals
    if r.returncode != 0 or r.stderr.strip():
        print(r.stdout[-2000:], r.stderr[-2000:])
    return out, r.stdout


def window(home):
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-lg-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    res = {}
    f.enter(600, 300)
    f.move(600, 300)
    q(LEVEL + '\nselect("Score")\nview(20, 15, 12, 0, 1.6, 6)')
    f.pump(0.3)
    f.move(600, 700)
    q('op("area.type_node_editor")\nop("area.maximize")\nop("node.view_fit")')
    f.pump(0.5)
    img = f.image()
    cols = {(0x8a, 0x3b, 0x3b): 0, (0x1d, 0x72, 0x5e): 0, (0x2f, 0x65, 0x89): 0}
    for y in range(80, 780, 3):
        for x in range(0, 1280, 3):
            p = img.getpixel((x, y))[:3]
            if p in cols:
                cols[p] += 1
    res['kinds'] = list(cols.values())
    if OUT:
        f.shot('119_logic_graph.png')
    res['n0'] = q('print(ginfo(3, 0, "count"))')  # (ScoreLogic: the third tree)
    f.move(900, 150)
    f.mods(1); f.key(30); f.mods(0)             # Shift+A: the logic types
    f.pump(0.3)
    if OUT:
        f.shot('120_logic_add_menu.png')
    f.click(930, 150 + 2 + 18 + 9)              # the first: Begin Play
    f.pump(0.3)
    res['n1'] = q('print(ginfo(3, 0, "count"), ginfo(3, 14, "type"))')
    # a name value pressed: the console asks for it
    q('select("Door")')
    f.pump(0.3)
    q('op("node.view_fit")')
    f.pump(0.3)
    img = f.image()
    green = [(x, y) for y in range(60, 780) for x in range(0, 1280, 2) if img.getpixel((x, y))[:3] == (0x1d, 0x72, 0x5e)]
    if green:
        gx = min(p[0] for p in green)
        gy = min(p[1] for p in green)
        f.click(gx + 60, gy + 20 + 18 + 9)      # Play Action's Action value
        f.pump(0.3)
        f.type('DoorClose')
        f.key(28)
        f.pump(0.3)
    res['named'] = q('print(ginfo(1, 2, "value", 1))')
    q('op("area.type_viewport")\nop("area.maximize")\nselect()\nview(0, 5, 8, 0, 1.6, 6)')
    f.pump(0.3)
    f.move(600, 300)
    f.key(63)                                   # F5
    f.pump(0.5)
    f.key(18)                                   # E: a coin
    f.pump(0.5)
    res['play'] = q('print(logic(0), logic(5), logic(1))')
    if OUT:
        f.shot('121_logic_play.png')
    f.key(1)                                    # Esc, D
    f.key(32)
    f.pump(0.3)
    res['after'] = q('print(logic(0), playinfo(0))')
    m.tool('op_logic_new', {'arg': 'McpLogic'})
    m.tool('op_logic_node', {'arg': 'McpLogic tick'})
    m.tool('op_logic_node', {'arg': 'McpLogic rotate'})
    m.tool('op_tree_link', {'arg': 'McpLogic 1 2 1'})
    m.tool('op_tree_node_set', {'arg': 'McpLogic 2 2 0 1 0'})
    m.tool('op_logic_attach', {'arg': 'McpLogic Floor'})
    res['mcp'] = q('print(ginfo(6, 0, "count"), ginfo(6, 2, "link", 1))')
    q('op("play.start", "fly 0 3 6")\nplaystep(0.5)')
    res['mcp_run'] = q('print(logic(1), round(get("Floor", "ry") * 10) / 10 != 0)\nop("play.stop")')
    f.proc.kill()
    return res


def main():
    print('  -- logic graphs --')
    home = tempfile.mkdtemp(prefix='bee-lg-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    o, _ = run(home, PLAY)
    g = lambda k: o.get(k, [])
    check(g('started') == [1, 5, 7, 3],
          f'play begins: five graphs run; a timer set a variable, Get Property read the coin ({g("started")})')
    check(g('coin')[:4] == [-1.8, 1, 1, 1] if g('coin') else False,
          f'walking into the coin picks it up: destroyed, a message counts it, a branch follows ({g("coin")})')
    check(g('spawned')[:4] == [1, 6, 3, 3] and g('spins') == [1],
          f'E spawns a coin at the score\'s offset; it runs the coin graph too and spins ({g("spawned")})')
    check(g('kept') == [1, 1], f'play.stop keep: the graphs stop, the changes stay ({g("kept")})')
    check(g('door') and g('door')[0] == 3.6 and g('door')[1] < -6,
          f'the door opens when the player comes near (On Overlap -> Play Action), the player walks through ({g("door")})')
    check(g('ball') and g('ball')[0] < 2.5, f'Begin Play pushed the ball (Apply Impulse): z 3 -> {g("ball")}')
    check(g('discard') == [1.25, 3], f'discarded: the door and the ball as they were ({g("discard")})')
    l0, l1 = g('lift0'), g('lift1')
    check(len(l0) == 3 and len(l1) == 4 and l1[0] == -2 and abs((l1[1] - l0[1]) - (l1[0] - l0[0])) < 0.05
          and l1[2] == 0.5 and l1[3] == 1,
          f'the moving platform slides (Start + sin(Time) x 2) and the player rides it ({l0} -> {l1})')
    a, sa = run(home, SAME)
    b, sb = run(home, SAME)
    check(a.get('state') and a.get('state') == b.get('state'),
          f'deterministic: the same session twice, the same scene ({a.get("state")})')
    s, _ = run(home, STORM)
    check(s.get('storm', [])[:2] == [1, 1] and s['storm'][3] == 1,
          f'sandboxed: a message storm is cut off at the step budget (4096 nodes) and play goes on ({s.get("storm")})')
    r = window(home)
    check(all(c > 20 for c in r['kinds']),
          f'the node editor shows the logic graph: events, actions and data ({r["kinds"]})')
    check(r['n1'].split() == [str(int(r['n0']) + 1), '1'],
          f'Shift+A lists the logic nodes and adds Begin Play ({r["n0"]} -> {r["n1"]})')
    check(r['named'] == '2', f'pressing a name value opens the console with logic.name: typed and set ({r["named"]})')
    check(r['play'] == '1 1 6' and r['after'] == '0 0',
          f'F5 plays the graphs, E spawns, Esc D stops ({r["play"]}, {r["after"]})')
    check(r['mcp'] == '2 1' and r['mcp_run'] == '6 1',
          f'over MCP: op_logic_new, op_logic_node, op_tree_link, op_logic_attach, and it runs ({r["mcp"]}, {r["mcp_run"]})')
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nlogic graphs: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
