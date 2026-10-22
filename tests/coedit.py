#!/usr/bin/env python3
"""The v0.11 co-editing walkthrough: two users and an AI agent on one scene.
Three BeeModels in the fake compositor: A hosts (co.host), B joins A, C
joins B (no server: C's operations reach A through B); C's MCP tools are an
agent peer (co.agent on). They converge (the same document hash and the
same scene), concurrent edits of one property settle the same way
everywhere (last writer wins by Lamport clock), moves of different vertices
of one mesh merge, undo is per author (A's Ctrl+Z takes back A's move, not
B's; the agent's undo its own), presence (B's selection drawn on A, A
following B's camera). Then a fuzz: hundreds of random edits on all three
at once - moves, renames, materials, hiding, adds, deletes, vertex moves,
new topologies - and the three converge to identical documents (by hash)
and identical scenes.

All three share a session key (D6, co.key): a fourth BeeModel without it,
and a fifth with another one, are refused and get nothing of the scene;
two BeeModels without keys still work together as before.

    python3 tests/coedit.py build/beemodel [outdir] [--rounds N] [--seed S]
"""
import os, random, socket, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('--') else None
ROUNDS = int(sys.argv[sys.argv.index('--rounds') + 1]) if '--rounds' in sys.argv else 300
SEED = int(sys.argv[sys.argv.index('--seed') + 1]) if '--seed' in sys.argv else 151
HERE = os.path.dirname(os.path.abspath(__file__))
KEY = 'correct horse battery'
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


SCENE_SUMMARY = '''
s = ""
for i in 0..count() {
 n = name(i)
 v = 0
 m = "-"
 if objtype(n) == 0 {
  v = everts(n)
  m = str(matof(n))
 }
 s = s + n + " " + str(round(get(n, "x") * 1000)) + " " + str(round(get(n, "y") * 1000)) + " " + str(round(get(n, "z") * 1000)) + " " + str(v) + " " + m + "|"
}
print(s)
'''


def main():
    print('  -- co-editing --')
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-co-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    port = free_port()
    peers = []

    def inst():
        f = fakewl.Fake()
        f.pump(1.0, until_frame=True)
        f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
        m = fakewl.Mcp(f)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
        peers.append(f)
        return f, m, q

    def pump(n=8):
        for _ in range(n):
            for f in peers:
                f.pump(0.02)

    a, ma, qa = inst()
    b, mb, qb = inst()
    c, mc, qc = inst()
    for q in (qa, qb, qc):
        q('op("co.key", "%s")' % KEY)
    qa('add("sphere", "Ball", 2, 1, 0)\nmaterial("Gold")\nmatset("Gold", "base", 1, 0.8, 0.2)\nassign("Ball", "Gold")\n'
       'op("co.host", "%d")' % port)
    pump(3)
    qb('op("co.join", "127.0.0.1:%d")' % port)
    pump(6)
    port_b = free_port()                        # C joins B (B listens too): no
    qb('op("co.host", "%d")' % port_b)          #  server - C's operations reach
    pump(2)                                     #  A through B
    qc('op("co.join", "127.0.0.1:%d")\nop("co.agent", "on")' % port_b)
    pump(10)
    hashes = lambda: (qa('print(cohash())'), qb('print(cohash())'), qc('print(cohash())'))
    h = hashes()
    sa, sb, sc = qa(SCENE_SUMMARY), qb(SCENE_SUMMARY), qc(SCENE_SUMMARY)
    check(h[0] == h[1] == h[2] and sa == sb == sc and 'Ball' in sa,
          f'joining with the session key: all three have the host\'s scene ({h[0]}, {sa.count("|")} objects)')

    # D6: no key, or another key: refused, nothing of the scene leaks
    conns = qa('print(costat(1))')
    d, md, qd = inst()
    e, me, qe = inst()
    qe('op("co.key", "another pass phrase")')
    qd('op("co.join", "127.0.0.1:%d")' % port)
    qe('op("co.join", "127.0.0.1:%d")' % port)
    pump(10)
    got = (qd('print(count(), costat(1))'), qe('print(count(), costat(1))'), qa('print(costat(1))'))
    check(got[0] == '0 0' and got[1] == '0 0' and got[2] == conns,
          f'a peer without the session key, and one with another key, are refused and get nothing ({got})')
    for f in (d, e):
        f.proc.kill()
        peers.remove(f)
    f2, m2, q2 = inst()                         # no keys on either side: as before
    g2, n2, r2 = inst()
    port_f = free_port()
    q2('add("torus", "Ring", 0, 3, 0)\nop("co.host", "%d")' % port_f)
    pump(3)
    r2('op("co.join", "127.0.0.1:%d")' % port_f)
    pump(8)
    check(r2('print(exists("Ring"), cohash())') == '1 ' + q2('print(cohash())'),
          'without session keys on either side, joining works as before')
    for f in (f2, g2):
        f.proc.kill()
        peers.remove(f)

    # concurrent edits of one property: the same winner everywhere
    qa('set("Ball", "x", 1)')
    qb('set("Ball", "x", 2)')
    qc('set("Ball", "x", 3)')
    pump(10)
    xs = (qa('print(get("Ball", "x"))'), qb('print(get("Ball", "x"))'), qc('print(get("Ball", "x"))'))
    h = hashes()
    check(xs[0] == xs[1] == xs[2] and xs[0] in ('1', '2', '3') and h[0] == h[1] == h[2],
          f'one property set at once on three peers: one value wins everywhere ({xs})')
    # different vertices of one mesh at once: both kept
    qa('vmove("Cube", 0, -2, -2, -2)')
    qb('vmove("Cube", 1, 3, 3, 3)')
    pump(10)
    v = (qc('print(vpos("Cube", 0, 0), vpos("Cube", 1, 0))'), qa('print(vpos("Cube", 0, 0), vpos("Cube", 1, 0))'))
    check(v[0] == v[1] == '-2 3', f'two vertices of one mesh moved at once on two peers: both moves kept ({v})')

    # node graphs: a tree shared, nodes added at once on two peers
    qa('op("logic.new", "Shared")\nop("logic.node", "Shared tick")')
    pump(8)
    qa('op("logic.node", "Shared move")')
    qb('op("logic.node", "Shared rotate")\nop("logic.node", "Shared spawn")')
    pump(10)
    gn = lambda q: q('print(ginfo(1, 0, "count"), ginfo(1, 2, "type"), ginfo(1, 3, "type"), ginfo(1, 4, "type"))')
    g = (gn(qa), gn(qb), gn(qc))
    check(g[0] == g[1] == g[2] and g[0].split()[0] == '4',
          f'a node graph: nodes added to one tree at once on two peers are all kept, in one order ({g})')
    qa('op("tree.node_set", "Shared 2 4 1")')
    qb('op("tree.link", "Shared 1 3 1")\nop("tree.node_delete", "Shared 4")')
    pump(10)
    g = (gn(qa), gn(qb), gn(qc))
    lk = (qa('print(ginfo(1, 3, "link", 1))'), qc('print(ginfo(1, 3, "link", 1))'))
    h = hashes()
    check(g[0] == g[1] == g[2] and g[0].split()[0] == '3' and lk[0] == lk[1] == '1' and h[0] == h[1] == h[2],
          f'... a value, a link and a deletion at once: merged the same everywhere ({g[0]}, link {lk})')

    # undo per author
    qa('move("Ball", 5, 1, 0)')
    pump(4)
    qb('move("Cube", 0, 4, 0)')
    pump(6)
    a.key(1)                                    # (any open field closed)
    a.move(600, 300)
    a.mods(4); a.key(44); a.mods(0)             # A: Ctrl+Z
    pump(10)
    after = (qb('print(get("Ball", "x"), get("Cube", "y"))'), qc('print(get("Ball", "x"), get("Cube", "y"))'))
    check(after[0] == after[1] and after[0].split()[1] == '4' and after[0].split()[0] != '5',
          f'A\'s Ctrl+Z takes back A\'s move only, on every peer (B\'s stays) ({after})')
    a.mods(5); a.key(44); a.mods(0)             # Ctrl+Shift+Z: again
    pump(10)
    redo = qb('print(get("Ball", "x"))')
    check(redo == '5', f'redo: A\'s move again ({redo})')
    mc.tool('op_create_cube')                   # the agent (C's tools) adds,
    pump(8)                                     #  then undoes its own
    n1 = qa('print(count())')
    agent_undo = float(qc('print(costat(8))'))
    mc.tool('op_edit_undo')
    pump(10)
    n2 = qa('print(count())')
    still = qa('print(get("Ball", "x"), get("Cube", "y"))')
    check(agent_undo > 0 and int(n1) == int(n2) + 1 and still == '5 4',
          f'the agent is a peer of its own: its cube appears, its undo takes it back, the users\' edits stay '
          f'({n1} -> {n2}, {still})')

    # presence: B's selection on A, A following B
    qb('select("Ball")\nview(40, 30, 9, 1, 0, 0)')
    pump(10)
    peers_seen = qa('print(costat(3))')
    if OUT:
        a.shot('128_coedit_presence.png')
    img = a.image()
    blue = sum(1 for y in range(80, 620, 2) for x in range(214, 1014, 2)
               if all(abs(img.getpixel((x, y))[i] - (0x4f, 0xa3, 0xff)[i]) < 30 for i in range(3)))
    others = sum(1 for y in range(80, 620, 2) for x in range(214, 1014, 2)
                 if any(all(abs(img.getpixel((x, y))[i] - col[i]) < 30 for i in range(3))
                        for col in ((0xff, 0x7a, 0x45), (0x52, 0xd0, 0x7a), (0xd9, 0x77, 0xff))))
    check(int(peers_seen) >= 3 and blue + others > 40,
          f'presence: A sees the other peers (users and the agent: {peers_seen}), B\'s selection and camera drawn '
          f'({blue + others} pixels)')
    qa('op("co.follow", "1")')
    qb('view(70, 20, 7, 0, 1, 0)')
    pump(10)
    fol = qa('print(round(viewinfo(0)), round(viewinfo(1)), round(viewinfo(2)))')
    check(fol == '70 20 7', f'co.follow: A\'s view on B\'s ({fol})')
    qa('op("co.follow", "off")')

    # fuzz: random edits on all three at once
    rnd = random.Random(SEED)
    qs = [qa, qb, qc]
    ops = 0
    for k in range(ROUNDS):
        q = rnd.choice(qs)
        r = rnd.random()
        i = rnd.randrange(1000)
        x, y, z = (round(rnd.uniform(-6, 6), 2) for _ in range(3))
        pick = 'n = name(%d %% count())\n' % i
        if r < 0.3:
            code = pick + 'move(n, %s, %s, %s)' % (x, y, z)
        elif r < 0.4:
            code = pick + 'rename(n, "F%d")' % rnd.randrange(50)
        elif r < 0.5:
            code = 'material("M%d")\nmatset("M%d", "base", %s, 0.5, 0.5)\n' % (i % 5, i % 5, abs(x) / 6) + \
                   pick + 'assign(n, "M%d")' % (i % 5)
        elif r < 0.55:
            code = pick + 'select(n)\nop("object.hide")'
        elif r < 0.7:
            code = 'add("%s", "N%d", %s, %s, %s)' % (rnd.choice(['cube', 'sphere', 'cylinder']), i, x, y, z)
        elif r < 0.78:
            code = 'if count() > 6 {\n' + pick + 'delete(n)\n}'
        elif r < 0.95:
            code = pick + 'vmove(n, %d, %s, %s, %s)' % (i % 6, x, y, z)
        else:
            code = pick + 'select(n)\nop("object.modifier_add", "subsurf")\nop("object.modifier_apply", "0")'
        q(code)
        ops += 1
        if rnd.random() < 0.25:
            for f in peers:
                f.pump(0.005)
    stable = False
    for _ in range(40):
        pump(4)
        h = hashes()
        if h[0] == h[1] == h[2]:
            pump(4)
            if hashes() == h:
                stable = True
                break
    sa, sb, sc = qa(SCENE_SUMMARY), qb(SCENE_SUMMARY), qc(SCENE_SUMMARY)
    nops = [float(q('print(costat(4))')) for q in qs]
    check(stable and h[0] == h[1] == h[2],
          f'fuzz: {ops} random edits on three peers at once - identical documents by hash ({h[0]}; operations made '
          f'{nops})')
    check(sa == sb == sc, f'... and identical scenes ({sa.count("|")} objects)')
    for f in peers:
        f.proc.kill()
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nco-editing: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
