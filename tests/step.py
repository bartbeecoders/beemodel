#!/usr/bin/env python3
"""The v0.12 STEP (ISO 10303-21) reader and writer: B-rep solids out of the
kernel and back in, by ourselves and through FreeCAD.

  * A scene of planes, cylinders, cones, spheres and tori, each object
    placed, turned and coloured, goes out as an assembly and comes back with
    the same names, placements, colours, volumes and areas (to 1e-9), valid
    and watertight.
  * The enclosure's case (fillets, shell, a hole) goes out as one part and
    comes back exact; units: into a scene in centimetres, and an inch scene
    out to millimetres.
  * Outside: FreeCAD (freecadcmd) where it is installed, else the
    OpenCASCADE bindings (OCP), else skipped. It reads our part and our
    assembly (volumes to 1e-6, the solids where we put them) and writes them
    again, and we read its files back (volumes to 1e-6); its every-face-NURBS
    version of the case also comes back to 1e-6.

    python3 tests/step.py build/beemodel
"""
import math, os, shutil, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []
HOME = tempfile.mkdtemp(prefix='bee-step-')
P = math.pi


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, timeout=300):
    env = dict(os.environ, HOME=HOME, XDG_CACHE_HOME='')
    path = os.path.join(HOME, 'script.bees')
    with open(path, 'w') as f:
        f.write(code)
    r = subprocess.run([BIN, '--run', path], env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
    return r.stdout.split('\n')


def rows(lines):
    out = {}
    for line in lines:
        f = line.split()
        if not f:
            continue
        vals = []
        for x in f[1:]:
            try:
                vals.append(float(x))
            except ValueError:
                vals.append(x)
        out[f[0]] = vals
    return out


def rel(a, b):
    return abs(a - b) / abs(b)


def path(name):
    return os.path.join(HOME, name)


# every solid in the scene: volume, area, faces, valid, watertight, location,
# rotation, colour, centre of mass, name
REPORT = '''
for i in 0..count() {
 n = name(i)
 if objtype(n) == 0 {
  if brep(n, "kernel") == 1 {
   print("N", n)
   print("S", brep(n, "volume"), brep(n, "area"), brep(n, "faces"), brep(n, "valid"), brep(n, "watertight"), get(n, "x"), get(n, "y"), get(n, "z"), get(n, "rx"), get(n, "ry"), get(n, "rz"), get(n, "color"), centroid(n, "x"), centroid(n, "y"), centroid(n, "z"))
  }
 }
}
'''
FIELDS = ('volume', 'area', 'faces', 'valid', 'watertight', 'x', 'y', 'z', 'rx', 'ry', 'rz', 'color', 'cx', 'cy', 'cz')


def solids(lines):
    """name -> its fields (a line with the name, one with the numbers)"""
    out, name = {}, None
    for line in lines:
        f = line.split()
        if f and f[0] == 'N':
            name = line[2:].strip()
        elif len(f) == len(FIELDS) + 1 and f[0] == 'S' and name is not None:
            try:
                out[name] = dict(zip(FIELDS, (float(x) for x in f[1:])))
            except ValueError:
                pass
    return out


def errs(name, volume, area):
    return 'print("e%s", (brep("%s", "volume") - %r) / %r, (brep("%s", "area") - %r) / %r)\n' % (
        name, name, volume, volume, name, area, area)


KINDS = '''op("cad.kernel", "on")
op("scene.units", "mm")
delete("Cube")
P = 3.14159265358979
s = sketch("SBox", "XY")
rect(s, 0, 0, 40, 20)
pad("Box", s, 10)
set("Box", "z", -7)
set("Box", "color", 14492194)
c = sketch("SCyl", "XY")
circle(c, 0, 0, 5)
pad("Pin", c, 30)
set("Pin", "x", 100)
set("Pin", "y", 50)
set("Pin", "rx", 0.5)
set("Pin", "color", 4359668)
k = sketch("SCone", "XY")
p0 = point(k, 0, 0)
p1 = point(k, 10, 0)
p2 = point(k, 0, 20)
line(k, p0, p1)
line(k, p1, p2)
line(k, p2, p0)
revolve("Cone", k, 2*P, "v")
set("Cone", "x", -60)
set("Cone", "rz", 0.3)
t = sketch("STor", "XY")
circle(t, 30, 0, 10)
revolve("Torus", t, 2*P, "v")
set("Torus", "y", -80)
set("Torus", "ry", 1.1)
set("Torus", "color", 16766720)
b = sketch("SBall", "XY")
arc(b, 0, 0, 10, -P/2, P/2)
line(b, 0, 10, 0, -10)
revolve("Ball", b, 2*P, "v")
set("Ball", "x", 50)
set("Ball", "z", 40)
'''
WANT = {'Box': (8000, 2800), 'Pin': (750 * P, 350 * P), 'Cone': (P * 100 * 20 / 3, P * 10 * (10 + math.sqrt(500))),
        'Torus': (6000 * P * P, 1200 * P * P), 'Ball': (4000 * P / 3, 400 * P)}


def external():
    """the outside tool: (command prefix, name), or None"""
    for exe in ('freecadcmd', 'FreeCADCmd'):
        if shutil.which(exe):
            return [exe], 'FreeCAD'
    try:
        import OCP  # noqa: F401
        return [sys.executable], 'OpenCASCADE (OCP)'
    except ImportError:
        return None


def ext(tool, *job):
    out = path('ext.txt')
    if os.path.exists(out):
        os.remove(out)
    env = dict(os.environ, HOME=HOME, STEP_EXT_JOB='\t'.join(job), STEP_EXT_OUT=out)
    if tool[1] == 'FreeCAD':
        # FreeCAD embeds the system's Python: not another one's paths (CI's
        # setup-python sets them)
        for k in ('PYTHONHOME', 'PYTHONPATH', 'LD_LIBRARY_PATH', 'pythonLocation', 'Python_ROOT_DIR',
                  'Python2_ROOT_DIR', 'Python3_ROOT_DIR', 'PKG_CONFIG_PATH'):
            env.pop(k, None)
    r = subprocess.run(tool[0] + [os.path.join(HERE, 'step_ext.py')], env=env, capture_output=True, text=True,
                       timeout=600)
    res = {'solids': [], 'valid': None, 'ok': False, 'text': ''}
    if not os.path.exists(out):
        print(r.stdout[-2000:], r.stderr[-2000:])
        return res
    res['text'] = open(out).read()
    for line in res['text'].split('\n'):
        f = line.split()
        if not f:
            continue
        if f[0] == 'solid':
            res['solids'].append(tuple(float(x) for x in f[1:]))
        elif f[0] == 'valid':
            res['valid'] = f[1] == '1'
        elif f[0] == 'ok':
            res['ok'] = True
        elif f[0] in ('error', 'note', 'tool'):
            print('       (' + line + ')')
    return res


def importing(fname, units='mm'):
    return 'op("scene.units", "%s")\ndelete("Cube")\nop("file.import_step", "%s")\n' % (units, path(fname)) + REPORT


def main():
    print('  -- STEP --')
    # ---- an assembly of every analytic surface, placed and coloured --------
    code = KINDS + 'op("file.export_step", "%s")\n' % path('kinds.step') + REPORT
    for n, (v, a) in WANT.items():
        code += errs(n, v, a)
    lines = run(code)
    made = solids(lines)
    r = rows(lines)
    check(len(made) == 5 and all(abs(r['e' + n][0]) < 1e-9 for n in WANT),
          f'five kernel solids to export ({sorted(made)})')
    text = open(path('kinds.step')).read() if os.path.exists(path('kinds.step')) else ''
    kinds = ['ISO-10303-21;', "FILE_SCHEMA(('AUTOMOTIVE_DESIGN", 'MANIFOLD_SOLID_BREP', 'PLANE(', 'CYLINDRICAL_SURFACE',
             'CONICAL_SURFACE', 'SPHERICAL_SURFACE', 'TOROIDAL_SURFACE', 'NEXT_ASSEMBLY_USAGE_OCCURRENCE',
             'ITEM_DEFINED_TRANSFORMATION', 'COLOUR_RGB', "PRODUCT('Torus'", 'END-ISO-10303-21;']
    missing = [k for k in kinds if k not in text]
    check(not missing, f'the file: Part 21, AP214, the surfaces, an assembly with placements, colours, names '
                       f'({len(text)} bytes{", missing " + str(missing) if missing else ""})')
    lines = run(importing('kinds.step'))
    back = solids(lines)
    check(sorted(back) == sorted(made), f'read back: the same objects ({sorted(back)})')
    for n, m in made.items():
        b = back.get(n)
        if not b:
            continue
        v, a = WANT[n]
        ok = (rel(b['volume'], v) < 1e-6 and rel(b['area'], a) < 1e-6 and b['faces'] == m['faces']
              and b['valid'] == 1 and b['watertight'] == 1)
        check(ok, f'{n}: valid, watertight, {int(b["faces"])} faces, volume and area as written '
                  f'({b["volume"]} vs {v:.7g}, {b["area"]} vs {a:.7g})')
        place = all(abs(b[k] - m[k]) < 1e-4 for k in ('x', 'y', 'z', 'rx', 'ry', 'rz', 'cx', 'cy', 'cz'))
        check(place and b['color'] == m['color'],
              f'{n}: its placement, centre and colour ({b["x"]} {b["y"]} {b["z"]} / {b["rx"]} {b["ry"]} '
              f'{b["rz"]}, colour {int(b["color"])})')
    # the volumes to 1e-9 (BeeScript prints 7 digits: errors carry them)
    code = importing('kinds.step')
    for n, (v, a) in WANT.items():
        code += errs(n, v, a)
    r = rows(run(code))
    e = max(max(abs(x) for x in r.get('e' + n, [1, 1])) for n in WANT)
    check(e < 1e-9, f'... every volume and area to 1e-9 after the round trip (largest error {e:.1e})')

    # ---- one part: the enclosure's case -------------------------------------
    enc = open(os.path.join(HERE, 'enclosure.bees')).read()
    cut = enc.index('# ---- the lid')
    case = 'op("cad.kernel", "on")\n' + enc[:cut] + 'op("file.export_step", "%s")\n' % path('case.step') + REPORT
    case += 'print("eCase", brep("Case", "volume"), brep("Case", "area"))\n'
    r = rows(run(case))
    cv = r.get('eCase', [0, 0])
    cm = solids(run(case)).get('Case')
    lines = run(importing('case.step') + 'print("vCase", brep("Case", "volume"), brep("Case", "area"))\n')
    cb = solids(lines).get('Case')
    vb = rows(lines).get('vCase', [0, 0])
    ok = (cm and cb and cb['valid'] == 1 and cb['watertight'] == 1 and cb['faces'] == cm['faces']
          and isinstance(vb[0], float) and rel(vb[0], cv[0]) < 1e-9 and rel(vb[1], cv[1]) < 1e-9)
    check(ok, f'the enclosure case (one part): back valid, watertight, every face, the same volume and area '
              f'({vb} vs {cv})')
    lines = run(importing('case.step', 'cm') + 'print("vCm", brep("Case", "volume"))\n')
    v = rows(lines).get('vCm', [0])[0]
    check(isinstance(v, float) and rel(v, cv[0] / 1000) < 1e-6,
          f'units: read into a scene in centimetres, {v} cm^3 ({cv[0]} mm^3)')
    lines = run('op("cad.kernel", "on")\nop("scene.units", "in")\ndelete("Cube")\ns = sketch("S", "XY")\n'
                'rect(s, 0, 0, 1, 2)\npad("Inch", s, 3)\nop("file.export_step", "%s")\n' % path('inch.step'))
    text = open(path('inch.step')).read() if os.path.exists(path('inch.step')) else ''
    lines = run(importing('inch.step') + 'print("vIn", brep("Inch", "volume"))\n')
    v = rows(lines).get('vIn', [0])[0]
    check("CONVERSION_BASED_UNIT('INCH'" in text and isinstance(v, float) and rel(v, 6 * 25.4 ** 3) < 1e-9,
          f'units: a 1 x 2 x 3 inch block, in inches in the file, is {v} mm^3 in a millimetre scene')

    # ---- outside: FreeCAD, else OpenCASCADE ---------------------------------
    tool = external()
    if not tool:
        print('  skip outside round trips: neither freecadcmd nor the OCP bindings are installed')
    else:
        print(f'  -- through {tool[1]} --')
        res = ext(tool, 'read', path('case.step'))
        s = res['solids']
        check(res['ok'] and len(s) == 1 and res['valid'] and rel(s[0][0], cv[0]) < 1e-6,
              f'{tool[1]} reads the case: one valid solid, volume {s[0][0] if s else None} '
              f'(ours {cv[0]}, to 1e-6)')
        res = ext(tool, 'read', path('kinds.step'))
        theirs = sorted(res['solids'])
        ours = sorted((m['volume'], m['cx'], m['cy'], m['cz']) for m in made.values())
        ok = res['ok'] and res['valid'] and len(theirs) == 5 and all(
            rel(a[0], b[0]) < 1e-6 and max(abs(a[i] - b[i]) for i in (1, 2, 3)) < 0.01 for a, b in zip(theirs, ours))
        check(ok, f'{tool[1]} reads the assembly: five valid solids, volumes to 1e-6, each where we put it '
                  f'({len(theirs)} solids)')
        # its files back to us
        res = ext(tool, 'copy', path('case.step'), path('case_ext.step'))
        cb = solids(run(importing('case_ext.step'))) if res['ok'] else {}
        b = list(cb.values())
        check(len(b) == 1 and b[0]['valid'] == 1 and b[0]['watertight'] == 1 and rel(b[0]['volume'], cv[0]) < 1e-6,
              f'its case comes back: valid, watertight, volume {b[0]["volume"] if b else None} (to 1e-6)')
        res = ext(tool, 'copy', path('kinds.step'), path('kinds_ext.step'))
        kb = solids(run(importing('kinds_ext.step'))) if res['ok'] else {}
        theirs = sorted((m['volume'], m['cx'], m['cy'], m['cz']) for m in kb.values())
        ok = len(theirs) == 5 and all(m['valid'] == 1 and m['watertight'] == 1 for m in kb.values()) and all(
            rel(a[0], b[0]) < 1e-6 and max(abs(a[i] - b[i]) for i in (1, 2, 3)) < 0.01 for a, b in zip(theirs, ours))
        check(ok, f'its assembly comes back: five valid solids, volumes to 1e-6, where they were ({sorted(kb)})')
        res = ext(tool, 'nurbs', path('case.step'), path('case_nurbs.step'))
        text = open(path('case_nurbs.step')).read() if res['ok'] else ''
        cb = solids(run(importing('case_nurbs.step'))) if res['ok'] else {}
        b = list(cb.values())
        check('B_SPLINE_SURFACE' in text and len(b) == 1 and b[0]['valid'] == 1 and b[0]['watertight'] == 1
              and rel(b[0]['volume'], cv[0]) < 1e-6,
              f'the case with every face a NURBS surface: valid, watertight, volume '
              f'{b[0]["volume"] if b else None} (to 1e-6)')

    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nSTEP: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
