#!/usr/bin/env python3
"""Ask AI about the selection (stage Q, v1.1.0), with no network and no
account: the stand-in claude (tests/ai_standin.py, on PATH in the test's
HOME) reads what it is sent and acts on the selection through the MCP
bridge as the real one would. In a window (the fake compositor):

  - Alt+right-click on an object selects it and opens the box at the
    pointer; Esc and a click outside close it; Shift+right-click still
    places the 3D cursor; Ask AI... is first in the viewport's menu;
  - a prompt sent with Enter goes with the selection (each object as
    scene_summary lists it, with its size) and what to keep to; the
    transcript shows the prompt and what it was about; the answer comes
    back as a message; the whole request is one undo step;
  - Only the selection: an AI that also moves (or deletes) the light is
    named in a warning; with the toggle off it is not, and the toggle is
    remembered;
  - edit mode: the selected elements, their centre, the mesh operators;
  - Up brings back the last prompts; a quick button sends at once;
  - the status bar shows the request while it runs, and stops it.

    python3 tests/askai.py build/beemodel [outdir]
"""
import json, os, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def main():
    home = tempfile.mkdtemp(prefix='bee-ask-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    bindir = os.path.join(home, 'bin')
    os.makedirs(bindir)
    for n in ('claude', 'grok'):
        os.symlink(os.path.join(HERE, 'ai_standin.py'), os.path.join(bindir, n))
    os.environ['PATH'] = bindir + ':' + os.environ['PATH']

    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-ask-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    fakewl.BIN = BIN
    f = fakewl.Fake(home=home)
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    cube = fakewl.project((0, 1, 0))
    empty = fakewl.project((-6, 0, 6))
    f.enter(*cube)
    f.move(*cube)

    def names():
        return {w['name'] for w in fakewl.ui_tree(m)}

    def transcript():
        return [ln for ln in m.tool('op_ai_transcript')[0].split('\n') if ln.startswith('$ ')]

    def wait_idle(secs=20):
        end = time.time() + secs
        t = transcript()
        while time.time() < end:
            if t and 'idle' in t[0]:
                break
            f.pump(0.1)
            t = transcript()
        f.pump(0.2)
        return t

    def toast():                                    # the message shown now
        return (fakewl.widget(m, 'status.toast') or {}).get('label', '')

    def alt_rclick(xy):
        f.move(*xy)
        f.mods(8); f.click(xy[0], xy[1], 0x111); f.mods(0)
        f.pump(0.3)

    def sent():                                     # what the last claude run was sent
        a = json.load(open(os.path.join(home, 'claude.runs.json')))[-1]['args']
        return a[a.index('-p') + 1]

    def ask(xy, text):
        alt_rclick(xy)
        f.type(text)
        f.key(28)                                   # Enter
        f.pump(0.2)
        return wait_idle()

    # -- the box
    print('  -- the Ask box --')
    q('select()')
    alt_rclick(cube)
    w = fakewl.widget(m, 'ask.prompt')
    check(w is not None and {'ask.send', 'ask.only_selection', 'ask.bigger', 'ask.material'} <= names(),
          'Alt+right-click opens the box: the prompt, Send, the quick buttons, Only the selection')
    check(w is not None and abs(w['x'] - cube[0]) < 120 and 0 < w['y'] - cube[1] < 90,
          f'it opens at the pointer ({w and (w["x"], w["y"])} for {cube})')
    check(q('print(issel("Cube"), active())') == '1 Cube', 'the object clicked is selected first')
    if OUT:
        f.shot('150_ask_box.png')
    f.key(1)                                        # Esc
    f.pump(0.2)
    check('ask.prompt' not in names(), 'Esc closes it')
    alt_rclick(cube)
    f.click(*empty)
    f.pump(0.2)
    check('ask.prompt' not in names() and q('print(issel("Cube"))') == '1',
          'a click outside closes it (and does nothing else)')
    f.mods(1); f.click(*cube, 0x111); f.mods(0)     # Shift+right-click
    f.pump(0.3)
    cy = q('n = field("attractor")\nprint(round(get(n, "y") * 10))\ndelete(n)')
    check('ask.prompt' not in names() and cy.isdigit() and 10 < int(cy) <= 20,
          f'Shift+right-click still places the 3D cursor (on the cube: a field added goes there, y {cy!r})')
    f.click(*cube, 0x111)                           # the viewport's menu
    f.pump(0.3)
    items = [w for w in fakewl.ui_tree(m) if w['kind'] == 'menuitem']
    check(items and items[0]['label'] == 'Ask AI...', 'Ask AI... is first in the viewport\'s right-click menu')
    if items and items[0]['label'] == 'Ask AI...':
        f.click(items[0]['x'] + 40, items[0]['y'] + items[0]['h'] // 2)
        f.pump(0.3)
    check('ask.prompt' in names(), 'it opens the box')
    f.key(1)
    f.pump(0.2)

    # -- a request about the selection
    print('  -- a request --')
    q('select("Cube")')
    t = ask(cube, 'make it bigger')
    tx = '\n'.join(t)
    said = toast()
    check(q('print(get("Cube", "sx"), get("Cube", "sy"))') == '2 2'
          and q('print(get("Light", "x"))') != '9', 'the AI changed the cube, and nothing else')
    p = sent()
    lines = [json.loads(ln) for ln in p.split('\n') if ln.startswith('{"name":')]
    check(p.startswith('make it bigger\n\n--- What this request is about') and len(lines) == 1
          and lines[0]['name'] == 'Cube' and lines[0]['size'] == [2, 2, 2] and lines[0]['active'] is True,
          'it was sent the prompt, then the selected object as scene_summary lists it, with its size')
    check('Change only the selection' in p and 'one short sentence' in p,
          'and to change only the selection, answering briefly')
    check('$ Y > make it bigger' in tx and '$ N about Cube' in tx and 'Change only' not in tx,
          'the transcript: the prompt as typed, a note of what it was about (not the whole context)')
    check(said == 'AI: Done: make it bigger (Cube).', f'the answer comes back as a message, its first line ({said!r})')
    f.mods(4); f.key(44); f.mods(0)                 # Ctrl+Z
    f.pump(0.3)
    check(q('print(get("Cube", "sx"))') == '1', 'Ctrl+Z takes the whole request back')

    # -- Only the selection
    print('  -- Only the selection --')
    ask(cube, 'stray: make it bigger')
    check(toast() == 'The AI also changed Light (not selected). Ctrl+Z undoes the request.',
          f'an AI that also moves the light is named in a warning ({toast()!r})')
    check('$ N The AI also changed Light' in '\n'.join(transcript()), 'and in the transcript')
    f.mods(4); f.key(44); f.mods(0)
    f.pump(0.3)
    ask(cube, 'delete the light')
    check(toast().startswith('The AI deleted Light (not selected).'), f'a deleted one too ({toast()!r})')
    f.mods(4); f.key(44); f.mods(0)
    f.pump(0.3)
    check(q('print(exists("Light"), get("Light", "x"), get("Cube", "sx"))') == '1 4 1',
          'each request undone in one step')
    alt_rclick(cube)
    x, y = fakewl.widget_xy(m, 'ask.only_selection')
    f.click(x, y)
    f.pump(0.2)
    v = (fakewl.widget(m, 'ask.only_selection') or {}).get('value')
    f.type('stray again')
    f.key(28)
    wait_idle()
    said = toast()
    check(v == 0 and said.startswith('AI: Done') and 'Change only the selection' not in sent(),
          f'with Only the selection off, nothing is said (and the AI is not asked to keep to it): {v} {said!r}')
    prefs = open(os.path.join(home, '.config', 'beemodel', 'prefs')).read()
    check('ai_only_selection 0' in prefs, 'the toggle is remembered')
    f.mods(4); f.key(44); f.mods(0)
    f.pump(0.3)
    alt_rclick(cube)
    f.click(*fakewl.widget_xy(m, 'ask.only_selection'))
    f.key(1)
    f.pump(0.2)

    # -- several objects, nothing selected
    q('add("sphere", "Ball", 3, 1, 0)\nselect("Cube", "Ball")')
    ask(cube, 'make them bigger')
    p = sent()
    lines = [json.loads(ln) for ln in p.split('\n') if ln.startswith('{"name":')]
    check([o['name'] for o in lines] == ['Cube', 'Ball'] or [o['name'] for o in lines] == ['Ball', 'Cube'],
          f'two selected: both are listed, the active one first ({[o["name"] for o in lines]})')
    check('$ N about 2 objects' in '\n'.join(transcript()), 'the note: about 2 objects')
    q('select()')
    alt_rclick(empty)
    f.type('what is here')
    f.key(28)
    wait_idle()
    check('Nothing is selected: the request is about the scene.' in sent()
          and 'Change only' not in sent(), 'nothing selected: it is about the scene')

    # -- history and the quick buttons
    print('  -- recent prompts, quick buttons --')
    alt_rclick(empty)
    f.key(103)                                      # Up
    f.pump(0.2)
    f.key(28)
    wait_idle()
    check(sent().startswith('what is here\n'), 'Up brings back the last prompt')
    alt_rclick(empty)
    f.key(103); f.key(103); f.pump(0.2)
    f.key(28)
    wait_idle()
    check(sent().startswith('make them bigger\n'), 'Up again: the one before')
    q('select("Cube")\nscale("Cube", 1)')
    alt_rclick(cube)
    f.click(*fakewl.widget_xy(m, 'ask.bigger'))
    f.pump(0.2)
    wait_idle()
    check(sent().startswith('Make it 50% bigger.') and q('print(get("Cube", "sx"))') == '2',
          'Bigger sends at once')
    alt_rclick(cube)
    f.click(*fakewl.widget_xy(m, 'ask.material'))
    f.pump(0.2)
    f.type('gold')
    f.key(28)
    wait_idle()
    check(sent().startswith('Change the material to gold\n'), f'Material... starts the prompt; the rest is typed ({sent()[:40]!r})')

    # -- edit mode
    print('  -- edit mode --')
    q('scale("Cube", 1)\nedit("Cube")\nvselect("Cube")\n'
      'for i in 0..verts("Cube") { if vpos("Cube", i, "y") > 0 { vsel("Cube", i, 1) } }')
    alt_rclick(cube)
    f.type('extrude these')
    f.key(28)
    wait_idle()
    p = sent()
    check('Cube is in edit mode (vertex select): 4 vertices selected (1 whole face), their centre at [0,2,0]' in p
          and 'mesh.extrude' in p, 'edit mode: the selected elements, their centre, the mesh operators')
    nv, tx = q('print(verts("Cube"))'), '\n'.join(transcript())
    check(nv == '12' and '$ N about 4 vertices of Cube' in tx,
          f'the AI extruded them (12 vertices: {nv}), about 4 vertices of Cube')
    q('edit()')

    # -- while it works
    print('  -- the status bar --')
    alt_rclick(cube)
    f.type('a slow one')
    f.key(28)
    f.pump(0.5)
    w = fakewl.widget(m, 'status.ai_working')
    check(w is not None and 'ask.prompt' not in names(), 'the box closed; the status bar shows the request')
    if OUT:
        f.shot('151_ask_working.png')
    t0 = time.time()
    if w:
        f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
    t = wait_idle(5)
    check('idle' in t[0] and time.time() - t0 < 2 and fakewl.widget(m, 'status.ai_working') is None,
          'clicking it stops the AI')

    f.proc.kill()
    print('askai: %d failed' % len(FAILS) if FAILS else 'askai: all passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
