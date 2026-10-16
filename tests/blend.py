#!/usr/bin/env python3
"""The v0.15 Blender files walkthrough.

Import (no Blender needed): the fixtures in tests/fixtures/blend were made
by Blender 5.2 and 4.2 (make.py), saved zstd-compressed; the test also
reads them decompressed and gzip-compressed (as Blender before 3.0 wrote).
Each import is checked against what Blender itself said about the scene
(<fixture>.json): which objects (the excluded collection's not), their
world matrices turned to Y up, the meshes' sizes and vertices, n-gons, the
split by material, the materials' values and image maps (packed and
external), the camera's lens, the lights' colour and power.

In a window (the fake compositor): File > Import offers Blender, and a
.blend dropped on the window comes in as one undo step.

Export (when Blender is on PATH): file.export_blend saves through Blender
in the background; Blender reads the file back with every object, and
BeeModel imports it again. Then a 1-million-triangle .blend imports within
the budget.

    python3 tests/blend.py build/beemodel [outdir]
"""
import gzip, json, math, os, shutil, subprocess, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, 'fixtures', 'blend')
FAILS = []
BIG_BUDGET_S = 2.0 * (2 if os.environ.get('CI') else 1)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(home, code, timeout=120):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
    return r.stdout


# ---- matrices --------------------------------------------------------------------
C = [[1, 0, 0], [0, 0, 1], [0, -1, 0]]                 # Z up -> Y up
CI = [[1, 0, 0], [0, 0, -1], [0, 1, 0]]


def mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(len(b))) for j in range(len(b[0]))] for i in range(len(a))]


def ours(loc, rot, scale):
    """T * Rz Ry Rx * S, as BeeModel builds an object's matrix (3x4)."""
    cx, sx = math.cos(rot[0]), math.sin(rot[0])
    cy, sy = math.cos(rot[1]), math.sin(rot[1])
    cz, sz = math.cos(rot[2]), math.sin(rot[2])
    rx = [[1, 0, 0], [0, cx, -sx], [0, sx, cx]]
    ry = [[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]]
    rz = [[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]]
    r = mul(rz, mul(ry, rx))
    return [[r[i][j] * scale[j] for j in range(3)] + [loc[i]] for i in range(3)]


def expected(w, kind):
    """Blender's world matrix in our axes: C W C^-1 (meshes), C W (cameras
    and lights: their own axes are ours)."""
    r = [row[:3] for row in w[:3]]
    t = [w[i][3] for i in range(3)]
    m = mul(C, r)
    if kind == 'MESH':
        m = mul(m, CI)
    tt = [sum(C[i][k] * t[k] for k in range(3)) for i in range(3)]
    return [m[i] + [tt[i]] for i in range(3)]


def close(a, b, eps=1e-3):
    return all(abs(x - y) <= eps for ra, rb in zip(a, b) for x, y in zip(ra, rb))


# ---- one fixture ---------------------------------------------------------------------
PRINT = '''
n = count()
for i in 0..n { delete(name(0)) }
op("file.import_blend", "%s")
for i in 0..count() {
  o = name(i)
  print("OB", o, get(o, "x"), get(o, "y"), get(o, "z"), get(o, "rx"), get(o, "ry"), get(o, "rz"), get(o, "sx"), get(o, "sy"), get(o, "sz"))
}
fn mesh(o) {
  if exists(o) {
    print("ME", o, verts(o), faces(o), matof(o))
    for v in 0..verts(o) { print("V", o, vpos(o, v, 0), vpos(o, v, 1), vpos(o, v, 2)) }
  }
}
'''


def import_check(home, path, info, tag):
    names = [o for o, e in info['objects'].items() if e['in_view_layer']]
    code = PRINT % path + ''.join('mesh("%s")\nmesh("%s.001")\n' % (n, n) for n in names
                                  if info['objects'][n]['type'] == 'MESH')
    code += 'print("CAM", get("Cam", "lens"))\n'
    code += 'print("LAMP", get("Lamp", "power"), get("Lamp", "lr"), get("Lamp", "lg"), get("Lamp", "lb"))\n'
    for m in ('Red', 'Gold', 'Glow'):
        code += f'print("MA", "{m}", matget("{m}", "base", 0), matget("{m}", "base", 1), matget("{m}", "base", 2), ' \
                f'matget("{m}", "metallic"), matget("{m}", "roughness"), matget("{m}", "emission", 1), matget("{m}", "strength"))\n'
    code += 'print("TEX", imgsize("checker", 0), imgsize("tiles", 0), nodeinfo("Packed", 0, "socket", 0), nodeinfo("External", 0, "socket", 0))\n'
    out = run(home, code)
    obs, me, verts = {}, {}, {}
    for line in out.splitlines():
        w = line.split()
        if not w:
            continue
        if w[0] == 'OB':
            obs[w[1]] = [float(x) for x in w[2:]]
        elif w[0] == 'ME':
            me[w[1]] = (int(w[2]), int(w[3]), w[4])
        elif w[0] == 'V':
            verts.setdefault(w[1], []).append([float(x) for x in w[2:5]])
        elif w[0] in ('CAM', 'LAMP', 'TEX'):
            me[w[0]] = [float(x) for x in w[1:]]
        elif w[0] == 'MA':
            me['MA' + w[1]] = [float(x) for x in w[2:]]
    want = set(names) | {n + '.001' for n in names if len(set(info['objects'][n].get('material_index', [0]))) > 1}
    check(set(obs) == want,
          f'{tag}: the view layer\'s objects, the excluded collection\'s not, an object per material used '
          f'({sorted(set(obs) ^ want) or len(obs)})')
    bad = []
    for n in names:
        e = info['objects'][n]
        if n not in obs:
            continue
        loc, rot, sc = obs[n][:3], obs[n][3:6], obs[n][6:9]
        if not close(ours(loc, rot, sc), expected(e['matrix'], e['type'])):
            bad.append(n)
    check(not bad, f'{tag}: world matrices (parents, rotation modes) turned to Y up, as Blender has them ({bad})')
    bad = []
    for n in names:
        e = info['objects'][n]
        if e['type'] != 'MESH':
            continue
        parts = [me.get(n), me.get(n + '.001')]
        nv = sum(p[0] for p in parts if p)
        nf = sum(p[1] for p in parts if p)
        if nf != e['faces'] or (len(parts) == 1 or not parts[1]) and nv != e['verts']:
            bad.append((n, nv, nf, e['verts'], e['faces']))
        mats = [p[2] for p in parts if p]
        want_m = [m or 'nil' for m in e['materials']][:len(mats)] or ['nil']
        if mats != want_m:
            bad.append((n, mats, want_m))
    check(not bad, f'{tag}: meshes: vertex and face counts (n-gons kept), materials by slot ({bad})')
    box = verts.get('Box', [])
    want_v = [[v[0], v[2], -v[1]] for v in info['objects']['Box']['first_verts']]
    check(all(any(close([a], [b], 1e-4) for b in box) for a in want_v),
          f'{tag}: vertex positions in object space, Y up ({want_v[:1]} in {len(box)})')
    check(me.get('CAM') == [35.0] and me.get('LAMP') and abs(me['LAMP'][0] - 0.5) < 1e-4
          and close([me['LAMP'][1:]], [[1.0, 0.9, 0.8]], 1e-4),
          f'{tag}: the camera\'s lens, the light\'s power (500 W: 0.5) and colour ({me.get("CAM")}, {me.get("LAMP")})')
    mi = info['materials']
    ok = True
    for m in ('Red', 'Gold', 'Glow'):
        got = me.get('MA' + m)
        b = mi[m]
        exp = b['base'] + [b['metallic'], b['roughness'], b['emission'][1] if m == 'Glow' else got and got[5],
                           b['emission_strength'] if m == 'Glow' else got and got[6]]
        if not got or not close([got], [exp], 1e-4):
            ok = False
            print('   ', m, got, exp)
    check(ok, f'{tag}: Principled BSDF values: base colour, metallic, roughness, emission')
    t = me.get('TEX', [])
    check(t[:2] == [8, 4] and t[2] > 0 and t[3] > 0,
          f'{tag}: Image Texture nodes: a packed image (8 px) and one beside the file (4 px) drive base colour ({t})')
    return obs


def main():
    home = tempfile.mkdtemp(prefix='bee-bl-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    print('  -- import --')
    tmp = tempfile.mkdtemp(prefix='bee-blf-')
    for f in ('scene52.blend', 'scene42.blend', 'tiles.png'):
        shutil.copy(os.path.join(FIX, f), tmp)
    plain = os.path.join(tmp, 'plain42.blend')
    raw = subprocess.run(['zstd', '-dcq', os.path.join(FIX, 'scene42.blend')], capture_output=True).stdout
    open(plain, 'wb').write(raw)
    gz = os.path.join(tmp, 'gzip42.blend')
    with gzip.open(gz, 'wb') as fp:
        fp.write(raw)
    info52 = json.load(open(os.path.join(FIX, 'scene52.json')))
    info42 = json.load(open(os.path.join(FIX, 'scene42.json')))
    check(info52['version'].startswith('5.2') and info42['version'].startswith('4.2'),
          f'fixtures from Blender {info52["version"]} and {info42["version"]}')
    import_check(home, os.path.join(tmp, 'scene52.blend'), info52, 'Blender 5.2 (zstd)')
    import_check(home, os.path.join(tmp, 'scene42.blend'), info42, 'Blender 4.2 (zstd)')
    import_check(home, plain, info42, 'Blender 4.2 (plain)')
    import_check(home, gz, info42, 'Blender 4.2 (gzip)')
    junk = os.path.join(tmp, 'junk.blend')
    open(junk, 'wb').write(b'BLENDER-v279RENDjunk' + b'\0' * 64)

    # ---- the window -----------------------------------------------------------------
    print('  -- in the window --')
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-bl-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    os.environ['BEEMODEL_AGENT_PERMISSION'] = 'files'
    import fakewl
    sys.argv = argv
    f = fakewl.Fake(home=home)
    f.pump(1.0, until_frame=True)
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    ok = fakewl.menu_pick(f, m, 'File', 'Import')
    labels = [w.get('label') for w in fakewl.ui_tree(m) if w['kind'] == 'menuitem']
    f.key(1); f.key(1)
    f.pump(0.1)
    check(ok and 'Import Blender...' in labels, 'File > Import offers Blender (.blend)')
    r = m.tool('run_operator', {'id': 'file.import_blend', 'arg': junk})[0]
    check('before Blender 2.80' in r and q('print(count())') == '3',
          f'a file from before 2.80 is refused with a message; nothing changes ({r.splitlines()[-1:]})')
    f.drop_files([os.path.join(tmp, 'scene52.blend')], 640, 360)
    hist = m.tool('op_edit_undo_history')[0]
    check(f.dnd_accepted == 'text/uri-list' and f.dnd_finished and q('print(exists("Box"), exists("Ring"))') == '1 1'
          and hist.count('Import Blender') == 1,
          f'a .blend dropped on the window: taken as files, imported as one undo step ({f.dnd_accepted}, {f.dnd_finished})')
    if OUT:
        f.shot('150_blend_drop.png')
    f.mods(4); f.key(44); f.mods(0)                  # Ctrl+Z
    f.pump(0.3)
    check(q('print(exists("Box"))') == '0', 'Ctrl+Z takes the whole import back')

    # ---- export through Blender -------------------------------------------------------
    print('  -- export --')
    blender = shutil.which('blender')
    q(f'op("file.import_blend", "{os.path.join(tmp, "scene52.blend")}")')
    out = os.path.join(home, 'BeeModel', 'round.blend')
    if not blender:
        r = m.tool('op_file_export_blend', {'arg': out})[0]
        check('needs Blender' in r, 'without Blender, Export Blender says what it needs')
    else:
        t0 = time.time()
        r = m.tool('op_file_export_blend', {'arg': out})[0]
        n0, size = f.frames, -1
        while time.time() - t0 < 120:
            f.drag(300, 400, 360, 380, steps=4)     # (orbiting: the window draws)
            f.pump(0.2)
            if os.path.exists(out) and os.path.getsize(out) == size and size > 0:
                break
            size = os.path.getsize(out) if os.path.exists(out) else -1
        drawn = f.frames - n0
        took = time.time() - t0
        check('saving through Blender' in r and os.path.exists(out) and drawn > 5,
              f'file.export_blend: Blender, in the background, saved it ({took:.1f} s; the window drew {drawn} frames meanwhile)')
        rb = subprocess.run([blender, '-b', '--factory-startup', out, '--python-expr',
                             'import bpy, json; print("JSON" + json.dumps({o.name: [o.type, len(o.data.polygons) '
                             'if o.type == "MESH" else 0, [s.material.name for s in o.material_slots if s.material]] '
                             'for o in bpy.data.objects}))'], capture_output=True, text=True, timeout=120)
        got = {}
        for line in rb.stdout.splitlines():
            if line.startswith('JSON'):
                got = json.loads(line[4:])
        want = {n for n, e in info52['objects'].items() if e['in_view_layer']}
        check(want <= set(got) and got.get('Box', [0, 0])[1] == 6 and got['Box'][2] == ['Red']
              and got.get('Cam', [''])[0] == 'CAMERA' and got.get('Lamp', [''])[0] == 'LIGHT',
              f'Blender opens it: every object, meshes with their faces and materials, the camera and lights '
              f'({sorted(want - set(got))})')
        o2 = run(home, f'n = count()\nfor i in 0..n {{ delete(name(0)) }}\nop("file.import_blend", "{out}")\n'
                       'print("BACK", count(), faces("Box"), matof("Box"), faces("Ring"))')
        back = [w for w in o2.split() if w][o2.split().index('BACK') + 1:] if 'BACK' in o2 else []
        check(back[1:] == ['6', 'Red', '72'], f'and BeeModel reads it back ({back})')
        # a million triangles
        big = os.path.join(tmp, 'big.blend')
        subprocess.run([blender, '-b', '--factory-startup', '--python-expr',
                        'import bpy; bpy.ops.wm.read_factory_settings(use_empty=True); '
                        'bpy.ops.mesh.primitive_grid_add(x_subdivisions=708, y_subdivisions=708, size=10); '
                        f'bpy.ops.wm.save_as_mainfile(filepath="{big}", compress=False)'],
                       capture_output=True, timeout=300)
        o3 = run(home, f'n = count()\nfor i in 0..n {{ delete(name(0)) }}\nt = clock()\n'
                       f'op("file.import_blend", "{big}")\nprint("BIG", faces("Grid"), clock() - t)')
        w = o3.split()
        nb, secs = (int(w[w.index('BIG') + 1]), float(w[w.index('BIG') + 2]) / 1000) if 'BIG' in w else (0, 99)
        check(nb >= 500000 and secs < BIG_BUDGET_S,
              f'a {2 * nb} triangle .blend imports in {secs:.2f} s (budget {BIG_BUDGET_S} s)')
    f.proc.kill()
    print(f'  {len(FAILS)} failed' if FAILS else '  all passed')
    return 1 if FAILS else 0


sys.exit(main())
