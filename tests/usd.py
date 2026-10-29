#!/usr/bin/env python3
"""OpenUSD reading (src/usdc.s, usdlayer.s).

- Crate files (.usdc): every spec and field BeeModel reads (file.usd_dump)
  is what tests/usd_ref.py reads - a plain Python crate reader that matches
  OpenUSD's own (checked with pxr). tests/fixtures/usd/types.usdc covers
  inlined, compressed (ints, floats as ints, float tables) and plain arrays,
  halfs, quaternions, matrices, list ops, payloads, variant selections,
  blocked values; more .usdc files can be given on the command line.
- Text files (.usda, src/usda.s): types.usda reads as types.usdc does (the
  crate usdcat makes of it) - every spec and field the same, quaternions
  turned x y z w, floats and halfs rounded as the crate keeps them, list ops
  merged, primChildren / properties / variant children from the paths.
- Damaged crate and text files, and deeply nested text, read without a
  crash.
- Import (file.import_usd, src/usd.s): tests/fixtures/usd/stage composes a
  sublayer, references to text and crate layers, an internal reference to
  a class, a variant that brings in a payload, instanceable prims, an
  inactive prim and a guide; transforms with a pivot (!invert!), rotateXYZ,
  orient, transform, resetXformStack; Z up in centimetres; GeomSubsets
  binding a second material; leftHanded faces; indexed faceVarying UVs. Each
  mesh's faces and world bounding box (from the OBJ export) are OpenUSD's
  (golden.json, from tests/usd_stage_ref.py; checked again when pxr is
  there), and the objects land in a folder named after the file.
- Materials (src/usdmat.s): UsdPreviewSurface values (Paint: colour,
  metallic, roughness, opacity 0.4 -> transmission 0.6, ior) and textures
  (Wood: a base map, metallic / roughness from one map's b and g, the
  UsdTransform2d's 2 x 2 tiling); bound per object (Top: Wood, its subset:
  Paint).
- Physics (src/usdphys.s, tests/fixtures/usd/physics.usda): rigid bodies
  from PhysicsRigidBodyAPI with MassAPI masses (on the body or its mesh),
  approximations (convexHull -> hull, boundingCube -> box), a physics
  material's friction and restitution, kinematic -> passive; a hinge with
  its limits and a driven slider (held) as rigid.joint does them, a
  disabled joint left out. Played 2 s: the crate falls, its lid stays on
  its hinge, the drawer stays on the kinematic shelf.

    python3 tests/usd.py build/beemodel [more.usdc ...]
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import usd_ref                                               # noqa: E402

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
EXTRA = sys.argv[2:]
FIX = os.path.join(HERE, 'fixtures', 'usd')
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def dump(path):
    """BeeModel's reading of a USD file: {(path, field): value text}."""
    out = os.path.join(tempfile.mkdtemp(prefix='bee-usd-'), 'dump.txt')
    r = subprocess.run([BIN, '--eval', 'op("file.usd_dump", "%s %s")' % (path, out)],
                       capture_output=True, text=True, timeout=120)
    dump.rc = r.returncode
    if r.returncode != 0 or not os.path.exists(out):
        return None, (r.stdout + r.stderr).strip()[-300:]
    d = {}
    for line in open(out, errors='replace').read().splitlines():
        f = line.split('\t', 2)
        if len(f) == 3:                 # (damaged files: names with tabs, newlines)
            d[(f[0], f[1])] = f[2]
    return d, ''


def want(path):
    _, specs = usd_ref.read(path)
    d = {}
    for line in usd_ref.dump_lines(specs):
        p, k, v = line.split('\t', 2)
        d[(p, k)] = v
    return d


def same(g, w):
    if g == w:
        return True
    if w == 'LIST0':                    # an empty list: any empty kind
        return g is not None and g.split(' ')[1:2] == ['0']
    if g and w and g[0] == w[0] == 'f':  # float sums: rounding of the last digit
        a, b = g.split(), w.split()
        return a[:3] == b[:3] and all(abs(int(x) - int(y)) <= 2 + abs(int(y)) * 1e-6
                                      for x, y in zip(a[3:], b[3:]))
    return False


def crate(path):
    name = os.path.relpath(path)
    g, err = dump(path)
    if g is None:
        check(False, '%s: read (%s)' % (name, err))
        return
    w = want(path)
    bad = [k for k in w if not same(g.get(k), w[k])]
    extra = [k for k in g if k not in w]
    for k in bad[:5]:
        print('       %s %s\n         got  %s\n         want %s' % (k[0], k[1], (g.get(k) or '')[:120], w[k][:120]))
    check(not bad and not extra, '%s: %d fields as OpenUSD reads them (%d differ, %d extra)'
          % (name, len(w), len(bad), len(extra)))


IGNORED = {'customLayerData', 'subLayerOffsets', 'assetInfo', 'customData',
           'displayGroup', 'displayName'}        # (dictionaries and UI hints: not kept)


def text_vs_crate(usda, usdc):
    a, err = dump(usda)
    if a is None:
        check(False, '%s: read (%s)' % (os.path.relpath(usda), err))
        return
    c, _ = dump(usdc)
    keys = [k for k in c if k[1] not in IGNORED and '[' not in k[0]]
    missing = [k for k in keys if k not in a]
    differ = [k for k in keys if k in a and a[k] != c[k]]
    extra = [k for k in a if k not in c]
    for k in (missing + differ)[:5]:
        print('       %s %s\n         text  %s\n         crate %s' % (k[0], k[1], (a.get(k) or '-')[:100], c[k][:100]))
    check(not missing and not differ and not extra,
          '%s reads as %s: %d fields (%d missing, %d differ, %d extra)'
          % (os.path.basename(usda), os.path.basename(usdc), len(keys), len(missing), len(differ), len(extra)))


def stage_import(root, golden):
    """BeeModel's import of a stage: {object name (no .001): [faces, lo, hi]},
    objects, and their folders."""
    import json
    tmp = tempfile.mkdtemp(prefix='bee-usd-')
    obj = os.path.join(tmp, 'x.obj')
    code = ('n = count()\nfor i in 0..n { delete(name(0)) }\nop("file.import_usd", "%s")\n'
            'op("file.export_obj", "%s")\nfor i in 0..count() { print("OB", name(i), infolder(name(i))) }'
            % (root, obj))
    r = subprocess.run([BIN, '--eval', code], capture_output=True, text=True, timeout=300)
    objs = [l.split()[1:] for l in r.stdout.splitlines() if l.startswith('OB ')]
    got, g = {}, None
    if os.path.exists(obj):
        for line in open(obj):
            if line.startswith('o '):
                g = got.setdefault(line.split()[1].split('.')[0], [0, [1e30] * 3, [-1e30] * 3])
            elif line.startswith('v ') and g:
                w = list(map(float, line.split()[1:4]))
                for i in range(3):
                    g[1][i] = min(g[1][i], w[i])
                    g[2][i] = max(g[2][i], w[i])
            elif line.startswith('f ') and g:
                g[0] += 1
    want = json.load(open(golden))
    bad = [k for k in want if k not in got or got[k][0] != want[k][0]
           or any(abs(a - b) > 1e-4 for a, b in zip(got[k][1] + got[k][2], want[k][1] + want[k][2]))]
    for k in bad[:4]:
        print('       %s\n         got  %s\n         want %s' % (k, got.get(k), want[k]))
    return got, want, bad, objs


def pxr_reads(root):
    """OpenUSD's reading of the stage, when pxr is there (else None)."""
    import json
    env = dict(os.environ, LD_PRELOAD='/usr/lib/libjemalloc.so.2') if os.path.exists('/usr/lib/libjemalloc.so.2') else None
    r = subprocess.run([sys.executable, os.path.join(HERE, 'usd_stage_ref.py'), root],
                       capture_output=True, text=True, env=env)
    return json.loads(r.stdout) if r.returncode == 0 else None


def main():
    print('-- crate files --')
    crate(os.path.join(FIX, 'types.usdc'))
    for p in EXTRA:
        if p.endswith('.usda'):
            c = os.path.join(tempfile.mkdtemp(prefix='bee-usd-'), 'x.usdc')
            if subprocess.run(['usdcat', p, '-o', c], capture_output=True).returncode == 0:
                text_vs_crate(p, c)
        else:
            crate(p)
    print('-- text files --')
    text_vs_crate(os.path.join(FIX, 'types.usda'), os.path.join(FIX, 'types.usdc'))
    print('-- import --')
    st = os.path.join(FIX, 'stage')
    got, want, bad, objs = stage_import(os.path.join(st, 'root.usda'), os.path.join(st, 'golden.json'))
    check(not bad and set(got) == set(want),
          'the stage: %d meshes with OpenUSD\'s faces and world bounds (%s)' % (len(want), ', '.join(sorted(got))))
    names = [o[0] for o in objs]
    check(len(objs) == 7 and sum(n.split('.')[0] == 'Top' for n in names) == 2
          and sum(n.split('.')[0] == 'Cup' for n in names) == 2,
          'one object a material (Top: its subset apart), one an instance (Cup x2); %d objects' % len(objs))
    check(objs and all(o[1:] == ['root'] for o in objs), 'all in the folder "root"')
    check('Gone' not in got and 'Helper' not in got, 'inactive prims and guides are left out')
    code = ('n = count()\nfor i in 0..n { delete(name(0)) }\nop("file.import_usd", "%s")\n'
            'print("M", matof("Top"), matof("Top.001"))\n'
            'print("P", matget("Paint", "base", 0), matget("Paint", "base", 1), matget("Paint", "base", 2), '
            'matget("Paint", "metallic"), matget("Paint", "roughness"), matget("Paint", "transmission"), matget("Paint", "ior"))\n'
            'print("W", nodeinfo("Wood", 0, "socket", 0), nodeinfo("Wood", 0, "socket", 1), nodeinfo("Wood", 0, "socket", 3), '
            'nodeval("Wood", 1, 0, 0, 0, 0, 0.1, 0.3), nodeval("Wood", 1, 1, 0, 0, 0, 0.1, 0.3))'
            % os.path.join(st, 'root.usda'))
    out = subprocess.run([BIN, '--eval', code], capture_output=True, text=True, timeout=120).stdout
    lines = {l.split()[0]: l.split()[1:] for l in out.splitlines() if l[:2] in ('M ', 'P ', 'W ')}
    check(lines.get('M') == ['Wood', 'Paint'], 'materials bound per object: Top Wood, its subset Paint (%s)' % lines.get('M'))
    p = [float(x) for x in lines.get('P', [])]
    check(len(p) == 7 and all(abs(a - b) < 1e-4 for a, b in zip(p, [0.8, 0.1, 0.1, 1, 0.25, 0.6, 1.45])),
          'Paint: colour, metallic, roughness, transmission (1 - opacity), ior (%s)' % p)
    w = lines.get('W', [])
    check(len(w) == 5 and w[0] != '0' and w[1] != '0' and w[1] == w[2] and w[0] != w[1]
          and abs(float(w[3]) - 0.2) < 1e-4 and abs(float(w[4]) - 0.6) < 1e-4,
          'Wood: a base map, metallic and roughness from one map, tiled 2 x 2 (%s)' % w)
    code = ('n = count()\nfor i in 0..n { delete(name(0)) }\nop("file.import_usd", "%s")\n'
            'for i in 0..count() { o = name(i)\n print("R", o, rigid(o, "type"), rigid(o, "shape"), rigid(o, "mass"), rigid(o, "friction"), rigid(o, "bounce")) }\n'
            'print("T0", get("Box", "y"), get("Lid", "y"), get("Drawer", "x"), get("Drawer", "y"))\n'
            'for f in 1..61 { op("anim.frame", f) }\n'
            'print("T2", get("Box", "y"), get("Lid", "y"), get("Drawer", "x"), get("Drawer", "y"), get("Lid", "x") - get("Box", "x"))'
            % os.path.join(FIX, 'physics.usda'))
    out = subprocess.run([BIN, '--eval', code], capture_output=True, text=True, timeout=120).stdout
    rb = {l.split()[1]: l.split()[2:] for l in out.splitlines() if l.startswith('R ')}
    want_rb = {'Box': ['1', '3', '2', '0.3', '0.6'], 'Lid': ['1', '0', '0.5'], 'Shelf': ['2'], 'Drawer': ['1']}
    check(all(rb.get(k, [])[:len(v)] == v for k, v in want_rb.items()),
          'bodies: Box hull 2 kg friction 0.3 bounce 0.6, Lid box 0.5 kg, Shelf passive, Drawer active (%s)' % rb)
    t = {l.split()[0]: [float(x) for x in l.split()[1:]] for l in out.splitlines() if l[:3] in ('T0 ', 'T2 ')}
    t0, t2 = t.get('T0'), t.get('T2')
    check(t0 and t2 and t2[0] < t0[0] - 5 and abs((t2[1] - t2[0]) - (t0[1] - t0[0])) < 0.05 and abs(t2[4]) < 0.05
          and abs(t2[2] - t0[2]) < 0.02 and abs(t2[3] - t0[3]) < 0.02,
          'played 2 s: the crate falls (y %.1f -> %.1f), the lid stays on its hinge, the drawer on the shelf (%s)'
          % ((t0 or [0])[0], (t2 or [0])[0], t2))
    ref = pxr_reads(os.path.join(st, 'root.usda'))
    if ref is not None:
        same_ = set(ref) == set(want) and all(ref[k][0] == want[k][0] and all(
            abs(a - b) < 1e-9 for a, b in zip(ref[k][1] + ref[k][2], want[k][1] + want[k][2])) for k in ref)
        check(same_, 'golden.json is what OpenUSD (pxr) reads now')
    for p in EXTRA:
        if p.endswith('.usd') and ref is not None:
            r = pxr_reads(p)
            tmpg = os.path.join(tempfile.mkdtemp(prefix='bee-usd-'), 'g.json')
            open(tmpg, 'w').write(__import__('json').dumps(r))
            got, want, bad, objs = stage_import(p, tmpg)
            check(not bad, '%s: %d meshes as OpenUSD composes them' % (os.path.basename(p), len(want)))
    print('-- damaged files --')
    cyc = tempfile.mkdtemp(prefix='bee-usd-')
    mesh = 'def Mesh "M" { int[] faceVertexCounts = [3]\n int[] faceVertexIndices = [0, 1, 2]\n point3f[] points = [(0,0,0), (1,0,0), (0,1,0)] }'
    open(os.path.join(cyc, 'a.usda'), 'w').write('#usda 1.0\n( subLayers = [@./a.usda@, @./b.usda@] )\n'
        'def Xform "A" ( prepend references = @./b.usda@</B> ) { %s }\n' % mesh)
    open(os.path.join(cyc, 'b.usda'), 'w').write('#usda 1.0\n( subLayers = [@./a.usda@] )\n'
        'def Xform "B" ( prepend references = [@./a.usda@</A>, @./missing.usda@, </B>] ) { def Xform "C" ( prepend references = </B> ) {} }\n')
    code = 'op("file.import_usd", "%s")\nprint("N", count())' % os.path.join(cyc, 'a.usda')
    r = subprocess.run([BIN, '--eval', code], capture_output=True, text=True, timeout=60)
    check(r.returncode == 0 and 'N ' in r.stdout,
          'reference and sublayer cycles, a missing file: imported without a hang or crash (rc %d)' % r.returncode)
    g, err = dump(os.path.join(FIX, 'types.usda') + '.missing')
    check(g is None, 'a missing file is not read (%s)' % err[:60])
    bad = os.path.join(tempfile.mkdtemp(prefix='bee-usd-'), 'bad.usdc')
    data = open(os.path.join(FIX, 'types.usdc'), 'rb').read()
    for cut in (90, len(data) // 2, len(data) - 40):
        open(bad, 'wb').write(data[:cut])
        g, err = dump(bad)
        check(dump.rc == 0, 'a crate file cut at %d bytes: no crash (%s)' % (cut, 'read' if g else err[-50:]))
    for k in range(200):                # damaged bytes anywhere
        b = bytearray(data)
        for j in range(4):
            b[(k * 7919 + j * 104729) % (len(b) - 88) + 88] ^= 0x5a + j
        open(bad, 'wb').write(bytes(b))
        g, err = dump(bad)
        if dump.rc != 0:
            break
    check(dump.rc == 0, '200 crate files with damaged bytes: no crash (rc %d at %d)' % (dump.rc, k))
    text = open(os.path.join(FIX, 'types.usda'), 'rb').read()
    bad = bad[:-1] + 'a'
    for k in range(200):
        b = bytearray(text)
        for j in range(3):
            at = (k * 7919 + j * 104729) % len(b)
            if k % 2:
                b[at] = b'(){}[]<>@"=,#\n.-0'[(k + j) % 17]
            else:
                del b[at:at + 1 + (k + j) % 30]
        open(bad, 'wb').write(bytes(b))
        g, err = dump(bad)
        if dump.rc != 0:
            break
    check(dump.rc == 0, '200 text files with damaged bytes: no crash (rc %d at %d)' % (dump.rc, k))
    for name, body in (('a million "("', 'def "A" { float3 x = ' + '(' * 1000000 + '}'),
                       ('100000 nested prims', 'def "A" {' * 100000)):
        open(bad, 'w').write('#usda 1.0\n' + body + '\n')
        g, err = dump(bad)
        check(dump.rc == 0 and g is None, '%s: refused without a crash' % name)


main()
if FAILS:
    print('usd: %d failed' % len(FAILS))
    sys.exit(1)
print('usd: all checks passed')
