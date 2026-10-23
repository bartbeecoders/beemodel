#!/usr/bin/env python3
"""3D text (stage T).

T1: text.add makes a closed, outward-facing mesh from a TrueType font (or
the built-in block font): letters keep their holes (the Euler
characteristic of an o is 0, of a B -2), accents and rings made of several
parts stay closed, lines stack, alignment and size do what they say, the
text block survives a save and reopen, text.set changes it (and refuses
what it does not understand), reveal shows part of the characters.

T2: fonts by name (text.set font "Noto Serif Bold", through the system's
font folders; an unknown name: the default), a bevel that keeps the mesh
closed; in the fake compositor: Add > Text, Properties > Object > Text (the
body typed with \\n for a new line, the size, a font from the list, a
bevel), Ctrl+Z, Convert to Mesh (the shape kept, the text gone).

T3: text:<name>:reveal and size keyed over the timeline; {frame} in the
body counts; I over a panel value keys it.

T4: text() and text_set() in BeeScript; the stand-in Claude Code adds a
title and, finding it in scene_summary, changes it; Ctrl+Z each step.

    python3 tests/text.py build/beemodel [shots dir]
"""
import os, subprocess, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []

CLEAR = 'n = count()\nfor i in 0..n { delete(name(0)) }\n'


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, home, **env):
    with tempfile.NamedTemporaryFile('w', suffix='.bees', delete=False, encoding='utf-8') as fh:
        fh.write(code)
    try:
        p = subprocess.run([BIN, '--run', fh.name], capture_output=True, text=True, timeout=120,
                           env=dict(os.environ, HOME=home, **env))
    finally:
        os.unlink(fh.name)
    return p.returncode, p.stdout


def lines(out, tag):
    return [l.split()[1:] for l in out.splitlines() if l.startswith(tag + ' ')]


def solid(body, extra=''):
    """BeeScript: add the text, print 'S <body-tag> verts faces manifold boundary volume chi'."""
    return (f'op("text.add", "\'{body}\' {extra}")\n'
            'print("S", verts("Text"), faces("Text"), manifold("Text"), analyze("Text", "boundary"), '
            'volume("Text"), verts("Text") - edges("Text") + faces("Text"))\n'
            'delete("Text")\n')


def main():
    with tempfile.TemporaryDirectory() as home:
        os.makedirs(os.path.join(home, 'BeeModel'))
        # ---- T1: solids ------------------------------------------------------------
        for label, env in (('TrueType', {}), ('block font', {'BEEMODEL_TEXT_FONT': 'none'})):
            code, out = run(CLEAR + solid('BeeModel') + solid('Hello, 3D text! %&@') + solid('çÅéüñ'), home, **env)
            s = lines(out, 'S')
            ok = code == 0 and len(s) == 3 and all(r[2] == '1' and r[3] == '0' and float(r[4]) > 0 for r in s)
            check(ok, f'{label}: words, punctuation and accented letters make closed, outward meshes ({s})')
        code, out = run(CLEAR + solid('l') + solid('o') + solid('B') + solid('8'), home)
        s = lines(out, 'S')
        if len(s) == 4 and s[0][0] == '8':           # a TrueType font: l is one box
            chi = [int(r[5]) for r in s]
            check(chi == [2, 0, -2, -2], f'holes kept: Euler characteristic of l, o, B, 8 is 2, 0, -2, -2 ({chi})')
        else:
            print('  skip holes (no TrueType font: the block font is used)')
        # ---- lines, alignment, size --------------------------------------------------
        code, out = run(CLEAR + '''op("text.add", "AB")
a = verts("Text")
delete("Text")
op("text.add", "'A\\\\nB'")
print("L", a, verts("Text"), round(centroid("Text", "y") * 100))
delete("Text")
op("text.add", "HH align left")
print("X", round(centroid("Text", "x") * 100))
delete("Text")
op("text.add", "HH align center")
print("X", round(centroid("Text", "x") * 100))
delete("Text")
op("text.add", "HH align right")
print("X", round(centroid("Text", "x") * 100))
delete("Text")
op("text.add", "HH")
v1 = volume("Text")
delete("Text")
op("text.add", "HH size 2")
print("Z", round(volume("Text") / v1 * 100))
''', home)
        L = lines(out, 'L')
        check(code == 0 and L and L[0][0] == L[0][1] and int(L[0][2]) > 0,
              f'\\n starts a line below the first, which goes up: the last line stands on the origin ({L})')
        X = [int(r[0]) for r in lines(out, 'X')]
        check(len(X) == 3 and X[0] > 20 and abs(X[1]) <= 2 and X[2] < -20,
              f'align left / center / right put the text right of, on, left of the origin ({X})')
        Z = lines(out, 'Z')
        check(Z and Z[0] == ['400'], f'size 2 makes the letters twice as large (4x the volume at the same depth) ({Z})')
        # ---- files, text.set ------------------------------------------------------------
        path = os.path.join(home, 't.bee')
        code, out = run(CLEAR + f'''op("text.add", "Hello World size 0.5 depth 0.1")
print("A", verts("Text"), round(volume("Text") * 10000))
op("file.save", "{path}")
op("file.new")
op("file.open", "{path}")
print("A", verts("Text"), round(volume("Text") * 10000))
select("Text")
op("text.set", "bogus 3")
print("B", verts("Text"))
op("text.set", "'Goodbye' size 1")
print("B", verts("Text"))
op("text.set", "body Hi")
print("B", verts("Text"))
''', home)
        A = lines(out, 'A')
        check(code == 0 and len(A) == 2 and A[0] == A[1], f'save and reopen give the same mesh ({A})')
        B = [r[0] for r in lines(out, 'B')]
        check(len(B) == 3 and B[0] == A[0][0] and B[1] != B[0] and B[2] != B[1],
              f'after reopening, text.set changes the text; a word it does not know changes nothing ({B})')
        # ---- reveal -----------------------------------------------------------------------
        code, out = run(CLEAR + '''op("text.add", "abcd")
print("R", verts("Text"), faces("Text"))
select("Text")
op("text.set", "reveal 0")
print("R", verts("Text"), faces("Text"))
op("text.set", "reveal 0.5")
print("R", verts("Text"), faces("Text"))
op("text.set", "reveal 1")
print("R", verts("Text"), faces("Text"))
''', home)
        R = [(int(a), int(b)) for a, b in lines(out, 'R')]
        check(len(R) == 4 and R[1] == (1, 0) and 0 < R[2][0] < R[0][0] and R[3] == R[0],
              f'reveal 0 shows nothing, 0.5 some of the letters, 1 all ({R})')
        # ---- T2: fonts by name, bevel ----------------------------------------------------
        code, out = run(CLEAR + '''op("text.add", "BeeModel")
print("F", verts("Text"))
select("Text")
op("text.set", "font NoSuchFontAtAll")
print("F", verts("Text"))
op("text.set", "bevel 0.02")
print("V", manifold("Text"), analyze("Text", "boundary"), round(volume("Text") * 1000))
op("text.set", "bevel 0")
print("V", manifold("Text"), analyze("Text", "boundary"), round(volume("Text") * 1000))
''', home)
        F = [r[0] for r in lines(out, 'F')]
        check(len(F) == 2 and F[0] == F[1], f'a font name that is not on the system: the default font ({F})')
        V = lines(out, 'V')
        check(len(V) == 2 and V[0][:2] == ['1', '0'] and V[1][:2] == ['1', '0'] and int(V[0][2]) < int(V[1][2]),
              f'a bevel keeps the mesh closed and takes a little off the edges ({V})')
        fonts = sorted({os.path.splitext(n)[0] for _, _, fs in os.walk('/usr/share/fonts')
                        for n in fs if n.lower().endswith('.ttf')})
        alt = next((n for n in fonts if 'serif' in n.lower() and 'bold' in n.lower()), fonts[0] if fonts else None)
        if alt:
            spaced = alt.replace('-', ' ')
            code, out = run(CLEAR + 'op("text.add", "BeeModel")\nprint("N", verts("Text"))\nselect("Text")\n'
                            f'op("text.set", "font \'{spaced}\'")\nprint("N", verts("Text"))\n', home)
            N = [r[0] for r in lines(out, 'N')]
            check(len(N) == 2 and N[0] != N[1], f'a font by its name, spaces for hyphens ({spaced!r}: {N})')
        # ---- T3: keyed values, placeholders --------------------------------------------
        code, out = run(CLEAR + '''op("text.add", "'Typewriter title, letter by letter!' mode pop")
op("anim.key", "text:Text:reveal 1 0 linear")
op("anim.key", "text:Text:reveal 24 1 linear")
frame(1)
print("K", verts("Text"), faces("Text"))
frame(12)
print("K", verts("Text"), faces("Text"))
frame(24)
print("K", verts("Text"), faces("Text"))
print("P", keyed("text:Text:reveal", 12) > 0.4, keyed("text:Text:reveal", 12) < 0.6)
op("text.add", "HH")
h = active()
op("anim.key", "text:" + h + ":size 1 1")
op("anim.key", "text:" + h + ":size 24 2")
frame(24)
v2 = volume(h)
frame(1)
print("S", round(v2 / volume(h) * 10))
op("text.add", "'Frame {frame}, {floor(time)} s {{ok}}' align left")
c = active()
frame(5)
a = verts(c)
frame(6)
b = verts(c)
frame(5)
print("C", a, b, verts(c))
''', home)
        K = [(int(a), int(b)) for a, b in lines(out, 'K')]
        check(len(K) == 3 and K[0] == (1, 0) and 0 < K[1][0] < K[2][0] and K[2][0] > 2 * K[1][0] * 0.6,
              f'text:Text:reveal keyed 0 -> 1 over 24 frames: none, some, all of the letters ({K})')
        S = lines(out, 'S')
        check(S == [['40']], f'text:Text:size keyed 1 -> 2: four times the volume at frame 24 ({S})')
        C = lines(out, 'C')
        check(len(C) == 1 and C[0][0] != C[0][1] and C[0][0] == C[0][2],
              f'{{frame}} in the body: the mesh follows the frame, and back ({C})')
    ui()
    ai()
    print('text: ' + ('all green' if not FAILS else f'{len(FAILS)} failed'))
    sys.exit(1 if FAILS else 0)


def ui():
    """T2 in the fake compositor."""
    print('  -- the Text panel --')
    home = tempfile.mkdtemp(prefix='bee-text-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-text-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    fakewl.BIN = BIN
    f = fakewl.Fake(home=home)
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    f.enter(600, 300)
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in fakewl.ui_tree(m)}

    def typed(name, text):                      # a field: click, select all, type, Enter
        x, y = fakewl.widget_xy(m, name)
        f.click(x, y); f.pump(0.2)
        f.mods(4); f.key(30); f.mods(0)
        f.type(text); f.key(28); f.pump(0.4)

    def undo():
        f.move(600, 300); f.pump(0.1)
        f.mods(4); f.key(44); f.mods(0); f.pump(0.4)

    fakewl.menu_pick(f, m, 'Add', 'Text')
    f.pump(0.4)
    a = q('print(active(), verts(active()))').split()
    check(len(a) == 2 and a[0] == 'Text' and int(a[1]) > 8, f'Add > Text: a text object at the cursor ({a})')
    fakewl.props_tab(m, f, 'object')
    want = {'text.body', 'text.font', 'text.size', 'text.depth', 'text.bevel', 'text.align', 'text.spacing',
            'text.line', 'text.slant', 'text.quality', 'text.to_mesh'}
    got = names()
    check(want <= got, 'Properties > Object > Text: body, font, size, depth, bevel, align, spacing, line, '
                       f'slant, quality, Convert to Mesh (missing {sorted(want - got)})')
    vy = 'print(round(volume("Text") * 1000), round(centroid("Text", "y") * 100))'
    v0 = q(vy).split()
    typed('text.body', 'Hi\\nthere')
    v1 = q(vy).split()
    check(len(v1) == 2 and v1 != v0 and int(v1[1]) > int(v0[1]), f'the body typed with \\n: two lines, the first above ({v0} -> {v1})')
    typed('text.size', '2')
    v2 = q('print(round(volume("Text") * 1000))')
    check(len(v1) == 2 and v2.isdigit() and abs(int(v2) - 4 * int(v1[0])) <= 2, f'size 2: four times the volume ({v1[:1]} -> {v2})')
    n0 = q('print(verts("Text"))')
    fakewl.pick_enum(f, m, 'text.font', 0, 1)
    n1 = q('print(verts("Text"))')
    check(n1 != n0, f'another font from the list changes the outlines ({n0} -> {n1})')
    undo()
    n2 = q('print(verts("Text"))')
    check(n2 == n0, f'Ctrl+Z: the font as it was ({n2})')
    typed('text.bevel', '0.02')
    b = q('print(manifold("Text"), analyze("Text", "boundary"))')
    check(b == '1 0', f'a bevel from the panel: still closed ({b})')
    want = {'text.reveal', 'text.mode', 'text.soft', 'text.wave', 'text.wavelength', 'text.phase'}
    got = names()
    check(want <= got, f'letter by letter: reveal, appear, over letters, wave, wavelength, phase (missing {sorted(want - got)})')
    q('frame(1)')
    x, y = fakewl.widget_xy(m, 'text.reveal')
    f.move(x, y); f.pump(0.2)
    f.key(23); f.pump(0.3)                      # I over the value: a key
    k = q('print(keyed("text:Text:reveal", 1))')
    check(k == '1', f'I over Reveal keys text:Text:reveal ({k!r})')
    n3 = q('print(verts("Text"))')
    fakewl.menu_pick(f, m, 'Object', 'Convert Text to Mesh')
    f.pump(0.4)
    n4 = q('print(verts("Text"))')
    check(n4 == n3 and 'text.body' not in names() and 'text.to_mesh' not in names(),
          f'Convert to Mesh: the same mesh, no Text section any more ({n3} -> {n4})')
    undo()
    check('text.body' in names(), 'Ctrl+Z: a text object again')
    f.proc.kill()


def ai():
    """T4: the AI adds a title and changes it (the stand-in Claude Code, which
    finds the text in scene_summary); each request one undo step."""
    print('  -- text for the AI --')
    home = tempfile.mkdtemp(prefix='bee-text-ai-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    bindir = os.path.join(home, 'bin')
    os.makedirs(bindir)
    for n in ('claude', 'grok'):
        os.symlink(os.path.join(HERE, 'ai_standin.py'), os.path.join(bindir, n))
    os.environ['PATH'] = bindir + ':' + os.environ['PATH']
    import fakewl
    f = fakewl.Fake(home=home)
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    f.enter(600, 300)
    f.move(600, 300)
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()

    def wait_idle(secs=20):
        end = time.time() + secs
        while time.time() < end:
            t = [ln for ln in m.tool('op_ai_transcript')[0].split('\n') if ln.startswith('$ ')]
            if t and 'idle' in t[0]:
                break
            f.pump(0.1)
        f.pump(0.3)

    def send(text):
        x, y = fakewl.widget_xy(m, 'ai.prompt')
        f.click(x, y); f.pump(0.1)
        f.type(text); f.key(28); f.pump(0.2)
        wait_idle()

    def texts():
        return q('n = count()\ns = ""\nfor i in 0..n { if text(name(i)) != nil { s = s + name(i) + "=" + text(name(i)) + ";" } }\nprint(s)')

    f.mods(5); f.key(57); f.mods(0)                 # Ctrl+Shift+Space: the AI workspace
    f.pump(0.4)
    send("add a title 'Hello' above the cube")
    a = texts()
    y = q('print(round(get("Text", "y") * 10))')
    check(a == 'Text=Hello;' and y == '26', f'"add a title \'Hello\' above the cube": one text object, above the cube ({a}, y {y})')
    send("change the title to 'Goodbye'")
    b = texts()
    check(b == 'Text=Goodbye;', f'"change the title to \'Goodbye\'": the AI found it in the scene and changed it ({b})')
    f.move(400, 300); f.pump(0.1)
    f.mods(4); f.key(44); f.mods(0); f.pump(0.4)
    c = texts()
    f.mods(4); f.key(44); f.mods(0); f.pump(0.4)
    d = texts()
    check(c == 'Text=Hello;' and d == '', f'Ctrl+Z undoes each request: Hello, then no text ({c!r}, {d!r})')
    f.proc.kill()


if __name__ == '__main__':
    main()
