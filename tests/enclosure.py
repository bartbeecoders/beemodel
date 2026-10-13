#!/usr/bin/env python3
"""The v0.7 exit check: tests/enclosure.bees designs a printable enclosure from
dimensioned sketches and parameters, changes one parameter, and exports 3MF.
This runs it and checks that every feature built, that the parts are closed,
that the 3MF is valid (zip + model XML always; lib3mf in strict mode when the
module is installed) and - with --slicer, or when PrusaSlicer is installed -
that a slicer slices it into G-code.

    python3 tests/enclosure.py build/beemodel [--require-lib3mf] [--require-slicer]
"""
import os, re, shutil, subprocess, sys, tempfile, time, zipfile
import xml.etree.ElementTree as ET

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('--') else 'build/beemodel')
REQ_LIB = '--require-lib3mf' in sys.argv
REQ_SLICER = '--require-slicer' in sys.argv
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def model_check(path):
    """Our own reading: the three parts, millimetres, closed oriented meshes."""
    z = zipfile.ZipFile(path)
    if z.testzip() is not None:
        return False, 'bad CRC'
    root = ET.fromstring(z.read('3D/3dmodel.model'))
    ns = {'m': 'http://schemas.microsoft.com/3dmanufacturing/core/2015/02'}
    out = []
    for o in root.findall('.//m:object', ns):
        tris = [tuple(int(t.get(k)) for k in ('v1', 'v2', 'v3')) for t in o.findall('.//m:triangle', ns)]
        edges = {}
        for a, b, c in tris:
            for e in ((a, b), (b, c), (c, a)):
                edges[e] = edges.get(e, 0) + 1
        closed = all(n == 1 and edges.get((b, a)) == 1 for (a, b), n in edges.items())
        out.append((o.get('name'), len(tris), closed))
    ok = root.get('unit') == 'millimeter' and len(out) == 2 and all(c for _, _, c in out)
    return ok, out


def lib3mf_check(path):
    import lib3mf
    w = lib3mf.get_wrapper()
    m = w.CreateModel()
    r = m.QueryReader('3mf')
    r.SetStrictModeActive(True)
    r.ReadFromFile(path)
    it = m.GetMeshObjects()
    objs = []
    while it.MoveNext():
        o = it.GetCurrentMeshObject()
        objs.append((o.GetName(), o.GetTriangleCount(), o.IsManifoldAndOriented()))
    return r.GetWarningCount() == 0 and len(objs) == 2 and all(x[2] for x in objs), objs


def slicer():
    for name in ('prusa-slicer', 'PrusaSlicer', 'prusaslicer'):
        p = shutil.which(name)
        if p:
            return p
    return None


def slice_check(exe, path, tmp):
    gcode = os.path.join(tmp, os.path.basename(path) + '.gcode')
    cmd = [exe, '--export-gcode', '--output', gcode, path]
    if not os.environ.get('DISPLAY') and shutil.which('xvfb-run'):
        cmd = ['xvfb-run', '-a'] + cmd
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if r.returncode != 0 or not os.path.exists(gcode):
        return False, (r.stdout + r.stderr)[-300:]
    text = open(gcode, errors='replace').read()
    layers = len(re.findall(r'^;LAYER_CHANGE', text, re.M))
    moves = len(re.findall(r'^G1 ', text, re.M))
    return layers > 50 and moves > 1000, f'{layers} layers, {moves} moves'


def main():
    print('  -- enclosure walkthrough (v0.7 exit check) --')
    home = tempfile.mkdtemp(prefix='bee-encl-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    t0 = time.time()
    r = subprocess.run([BIN, '--run', os.path.join(HERE, 'enclosure.bees')], env=env,
                       capture_output=True, text=True, timeout=300)
    secs = time.time() - t0
    lines = (r.stdout + r.stderr).strip().splitlines()
    print('\n'.join('       ' + l for l in lines))
    out = os.path.join(home, 'BeeModel')
    try:
        first = lines[0].split()
        wide = lines[2].split()
        ok = (r.returncode == 0 and first[2] == '1' and first[5] == '1' and wide[2] == '1' and wide[4] == '1'
              and set(lines[1].split()[1]) == {'0'} and set(lines[3].split()[1]) == {'0'}
              and int(wide[1]) > int(first[1]) and int(wide[3]) > int(first[4]))
    except Exception as e:
        ok, lines = False, [repr(e)] + lines
    check(ok, f'every feature builds, both parts are closed, w 80 -> 100 mm rebuilds bigger ({secs:.2f} s)')
    files = [os.path.join(out, n) for n in ('enclosure.3mf', 'enclosure-wide.3mf')]
    for f in files:
        try:
            ok, info = model_check(f)
        except Exception as e:
            ok, info = False, repr(e)
        check(ok, f'{os.path.basename(f)}: zip, millimetres, two closed oriented meshes ({info})')
    try:
        import lib3mf  # noqa: F401
        have = True
    except ImportError:
        have = False
    if have:
        for f in files:
            try:
                ok, info = lib3mf_check(f)
            except Exception as e:
                ok, info = False, repr(e)
            check(ok, f'lib3mf (strict) reads {os.path.basename(f)}: manifold and oriented ({info})')
    else:
        check(not REQ_LIB, 'lib3mf is not installed' + (' (required)' if REQ_LIB else ' - skipped'))
    exe = slicer()
    if exe:
        tmp = tempfile.mkdtemp(prefix='bee-slice-')
        for f in files:
            ok, info = slice_check(exe, f, tmp)
            check(ok, f'PrusaSlicer slices {os.path.basename(f)} ({info})')
    else:
        check(not REQ_SLICER, 'PrusaSlicer is not installed' + (' (required)' if REQ_SLICER else ' - skipped'))
    pdf = os.path.join(out, 'enclosure.pdf')
    check(os.path.exists(pdf) and open(pdf, 'rb').read(8) == b'%PDF-1.4', 'the drawing is written as PDF')
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nenclosure: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
