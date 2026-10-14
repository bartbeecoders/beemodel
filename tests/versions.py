#!/usr/bin/env python3
"""The v0.11 versioned scenes walkthrough. A saved scene gets a history
beside it: commits, branches, switching; the content-addressed store keeps
unchanged content once. vc.diff lists what differs from a branch; vc.merge
is three-way from the common ancestor - their moves, meshes, materials,
new and deleted objects come in, ours stay, the same property changed on
both sides is a conflict for the merge panel; the merge commit has two
parents. In a window: the diff as ghosts over the scene and side by side,
the merge panel's buttons, undo; and an agent proposing a branch over MCP.

    python3 tests/versions.py build/beemodel [outdir]
"""
import os, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


FLOW = '''
add("sphere", "Ball", 2, 1, 0)
add("cube", "Old", 0, 0.5, -4)
material("Gold")
assign("Ball", "Gold")
op("file.save", "~/BeeModel/v.bee")
op("vc.commit", "first")
op("vc.commit", "again")
print("first", vcinfo(0), vcinfo(1), vcinfo(2), vctext(0), vctext(3))
op("vc.branch", "idea")
op("vc.switch", "idea")
move("Ball", 5, 1, 0)
add("cube", "Box", -3, 0.5, 0)
delete("Old")
vmove("Cube", 0, 2, 2, 2)
material("Red")
matset("Red", "base", 0.9, 0.1, 0.1)
assign("Box", "Red")
op("vc.commit", "on idea")
print("idea", vctext(0), vcinfo(1), vcinfo(2))
op("vc.switch", "main")
print("main", get("Ball", "x"), count(), vpos("Cube", 0, 0))
op("vc.diff", "idea")
print("diff", vcinfo(3), vcinfo(4), vcinfo(5), vcinfo(6))
print("rows", vctext(1, 0))
print("rows", vctext(1, 1))
print("rows", vctext(1, 2))
print("rows", vctext(1, 3))
set("Cube", "y", 3)
op("vc.switch", "idea")
print("refused", vctext(0), get("Cube", "y"))
op("vc.commit", "on main")
op("vc.merge", "idea")
print("merged", get("Ball", "x"), get("Cube", "y"), vpos("Cube", 0, 0), count(), matof("Box"), round(matget("Red", "base", 0) * 10), vcinfo(7), vcinfo(9))
print("old", count())
op("vc.commit", "merge idea")
print("after", vcinfo(1), vcinfo(9), vctext(3))
op("vc.switch", "idea")
set("Cube", "y", 9)
op("vc.commit", "idea moves the cube")
op("vc.switch", "main")
set("Cube", "y", 7)
op("vc.commit", "main moves it too")
op("vc.merge", "idea")
print("conflict", vcinfo(7), vcinfo(8), get("Cube", "y"))
print("conflictrow", vctext(2, 0))
op("vc.commit", "too early")
print("early", vcinfo(9))
op("vc.resolve", "1 theirs")
print("resolved", vcinfo(8), get("Cube", "y"))
op("vc.commit")
print("final", vcinfo(1), vcinfo(9))
'''


def run(home, code):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
    out = {}
    for line in r.stdout.splitlines():
        w = line.split(None, 1)
        if w:
            out.setdefault(w[0], []).append(w[1] if len(w) > 1 else '')
    if r.returncode != 0 or r.stderr.strip():
        print(r.stdout[-2000:], r.stderr[-2000:])
    return out


def window(home):
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-vc-shots-')]
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
    q('add("sphere", "Ball", 2, 1, 0)\nview(30, 25, 14, 0, 0.5, 0)')
    f.click(600, 761)                           # the user saves (the console)
    f.type('file.save ' + os.path.join(f.home, 'w.bee'))
    f.key(28)
    f.pump(0.3)
    f.key(1)                                    # (out of the console)
    m.tool('op_vc_commit', {'arg': 'first'})
    # an agent proposes a branch (MCP only)
    m.tool('op_vc_branch', {'arg': 'agent'})
    m.tool('op_vc_switch', {'arg': 'agent'})
    m.tool('script_eval', {'code': 'move("Ball", 4, 2, 0)\nadd("cube", "Tower", -3, 1.5, 0)\nscale("Tower", 0.5, 1.5, 0.5)\ndelete("Cube")'})
    m.tool('op_vc_commit', {'arg': 'agent: a tower'})
    m.tool('op_vc_switch', {'arg': 'main'})
    res['agent'] = q('print(vctext(0), vcinfo(2), get("Ball", "x"), count())')
    m.tool('op_vc_diff', {'arg': 'agent'})
    f.pump(0.4)
    img = f.image()
    count = lambda im, c, box=(214, 80, 1014, 620): sum(
        1 for y in range(box[1], box[3], 2) for x in range(box[0], box[2], 2)
        if all(abs(im.getpixel((x, y))[i] - c[i]) < 40 for i in range(3)))
    res['overlay'] = (count(img, (0xe0, 0x50, 0x50)), count(img, (0xe0, 0xc0, 0x40)), q('print(vcinfo(3))'))
    if OUT:
        f.shot('125_versions_diff.png')
    m.tool('op_vc_diff', {'arg': 'agent side'})
    f.pump(0.4)
    img = f.image()
    res['side'] = (count(img, (0x8a, 0x8f, 0x99), (614, 80, 1014, 620)), count(img, (0xe0, 0x50, 0x50)))
    if OUT:
        f.shot('126_versions_side.png')
    m.tool('op_vc_diff', {'arg': 'off'})
    # a conflict, the merge panel's buttons
    q('set("Ball", "y", 5)\nop("vc.commit", "main lifts the ball")\nop("vc.merge", "agent")')
    f.pump(0.4)
    res['merge'] = q('print(vcinfo(7), vcinfo(8), get("Ball", "y"), count())')
    img = f.image()
    if OUT:
        f.shot('127_merge_panel.png')
    btn = [(x, y) for y in range(80, 400) for x in range(614, 1014) if img.getpixel((x, y))[:3] == (0x3a, 0x3f, 0x48)]
    if btn:
        y0 = min(p[1] for p in btn)
        row = [p for p in btn if p[1] == y0]
        x1 = max(p[0] for p in row)
        f.click(x1 - 20, y0 + 8)               # the first row's "theirs"
        f.pump(0.3)
    res['clicked'] = q('print(vcinfo(8), get("Ball", "y"))')
    if btn:
        f.click(x1 - 75, y0 + 8)               # "ours": ours again
        f.pump(0.3)
    res['undone'] = q('print(vcinfo(8), get("Ball", "y"))')
    q('op("vc.abort")')
    res['aborted'] = q('print(vcinfo(9), vcinfo(7), get("Ball", "y"), count())')
    q('op("vc.merge", "agent")')
    q('op("vc.resolve", "all theirs")\nop("vc.commit", "merged the agent")')
    res['done'] = q('print(vcinfo(9), vcinfo(1), get("Ball", "y"), count())')
    f.proc.kill()
    return res


def main():
    print('  -- versioned scenes --')
    home = tempfile.mkdtemp(prefix='bee-vc-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    o = run(home, FLOW)
    g = lambda k: (o.get(k) or [''])[0].split()
    check(g('first') == ['1', '1', '1', 'main', 'first'],
          f'vc.commit keeps the scene beside its file; nothing changed: no second commit ({g("first")})')
    check(g('idea') == ['idea', '2', '2'], f'vc.branch, vc.switch, a commit on the branch ({g("idea")})')
    check(g('main')[:2] == ['2', '5'] and g('main')[2] != '2', f'vc.switch main: the scene as main has it ({g("main")})')
    rows = [r.strip() for r in o.get('rows', [])]
    check(g('diff') == ['4', '1', '1', '2'] and '~ Ball: transform' in rows and '- Box' in rows and '+ Old' in rows
          and '~ Cube: mesh 8 v > 8 v' in rows,
          f'vc.diff idea: what differs, by object and property ({g("diff")}, {rows})')
    check(g('refused') == ['main', '3'], f'switching with changes is refused ({g("refused")})')
    mg = g('merged')
    check(mg[:4] == ['5', '3', '2', '5'] and mg[4] == 'Red' and mg[5:] == ['9', '0', '1'],
          f'vc.merge: their move, mesh, new object with its material, deletion; our change kept ({mg})')
    check(g('after') == ['3', '0', 'merge', 'idea'], f'the merge commit ({g("after")})')
    check(g('conflict') == ['1', '1', '7'] and ' '.join(g('conflictrow')) == '1. Cube: transform'
          and g('early') == ['1'], f'the same property on both sides: a conflict, ours meanwhile; no commit yet '
          f'({g("conflict")}, {g("conflictrow")})')
    check(g('resolved') == ['0', '9'] and g('final') == ['5', '0'],
          f'vc.resolve theirs, then the merge commit ({g("resolved")}, {g("final")})')
    store = os.path.join(home, 'BeeModel', 'v.bee.vc')
    nblobs = len(os.listdir(os.path.join(store, 'blobs'))) if os.path.isdir(store) else 0
    ncommits = len(os.listdir(os.path.join(store, 'commits'))) if os.path.isdir(store) else 0
    check(ncommits == 7 and 0 < nblobs < 7 * 6, f'the store: 7 commits, {nblobs} blobs (unchanged content kept once)')
    r = window(home)
    check(r['agent'] == 'main 2 2 4', f'over MCP an agent makes a branch, works on it, commits ({r["agent"]})')
    check(r['overlay'][0] > 20 and r['overlay'][1] > 20 and r['overlay'][2] == '3',
          f'vc.diff draws the other version over the scene: removed red, changed yellow ({r["overlay"]})')
    check(r['side'][0] > 50, f'side by side: the other version beside the scene ({r["side"]})')
    check(r['merge'] == '1 1 5 4', f'a merge with a conflict: the merge panel ({r["merge"]})')
    check(r['clicked'] == '0 2' and r['undone'] == '0 5',
          f'the panel\'s buttons: "theirs" takes their value, "ours" ours again ({r["clicked"]}, {r["undone"]})')
    check(r['aborted'] == '0 0 5 4', f'vc.abort: the scene as before the merge ({r["aborted"]})')
    check(r['done'] == '0 3 2 4', f'merged again, resolved, committed ({r["done"]})')
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nversioned scenes: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
