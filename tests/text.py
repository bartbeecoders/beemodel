#!/usr/bin/env python3
"""3D text (stage T).

T1: text.add makes a closed, outward-facing mesh from a TrueType font (or
the built-in block font): letters keep their holes (the Euler
characteristic of an o is 0, of a B -2), accents and rings made of several
parts stay closed, lines stack, alignment and size do what they say, the
text block survives a save and reopen, text.set changes it (and refuses
what it does not understand), reveal shows part of the characters.

    python3 tests/text.py build/beemodel
"""
import os, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
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
        check(code == 0 and L and L[0][0] == L[0][1] and int(L[0][2]) < 0,
              f'\\n starts a line below the first: the same glyphs, lower down ({L})')
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
    print('text: ' + ('all green' if not FAILS else f'{len(FAILS)} failed'))
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
