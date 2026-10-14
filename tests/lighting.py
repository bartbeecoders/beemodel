#!/usr/bin/env python3
"""The v0.11 lighting tools walkthrough. A floor, a roof over part of it, a
red emissive panel and a mirror ball. Light probes (an irradiance volume, a
reflection probe) are baked by the path tracer and checked against
irradiance traced directly (spherical harmonics within a few percent), for
shadow under the roof and red light bleeding from the panel; they are
undone, saved and opened again. A lightmap is baked (a second UV set per
object, one atlas, denoised, dilated), checked against traced irradiance,
written as PNG and EXR, saved and opened again. The glTF export carries
KHR_lights_punctual, KHR_materials_emissive_strength, KHR_texture_transform
and the lightmap (TEXCOORD_1, an embedded PNG, MOZ_lightmap) and passes the
Khronos glTF validator. In a window, the material preview takes its light
from the probes once they are baked.

    python3 tests/lighting.py build/beemodel [outdir]
"""
import json, os, shutil, struct, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


SCENE = '''
delete("Cube")
add("plane", "Floor", 0, 0, 0)
scale("Floor", 12)
add("cube", "Roof", 0, 2, 0)
scale("Roof", 3, 0.1, 3)
add("cube", "Panel", 7, 1.5, 0)
scale("Panel", 0.1, 1.5, 2)
material("Red")
matset("Red", "base", 0.8, 0.1, 0.1)
matset("Red", "emission", 1, 0.05, 0.05)
matset("Red", "strength", 8)
assign("Panel", "Red")
add("sphere", "Ball", 5, 1, 2)
scale("Ball", 0.6)
material("Mirror")
matset("Mirror", "base", 0.95, 0.95, 0.95)
matset("Mirror", "metallic", 1)
matset("Mirror", "roughness", 0.05)
assign("Ball", "Mirror")
'''

PROBES = SCENE + '''
op("probe.add", "irradiance 0 1 0 9 0.9 9 7 3 7")
op("probe.add", "reflection 5 1.5 0 2.5 1.5 3")
print("added", probe(0), probe(2), probe(3), probe(6), probe(1))
op("probe.bake", "1024")
print("baked", probe(1), probeinfo(1, 1), probeinfo(2, 1), probe(5) > 100000)
fn s(t, w, x, y, z, dx, dy, dz) { print(t, probesample(w, x, y, z, dx, dy, dz, 0, 4096), probesample(w, x, y, z, dx, dy, dz, 1, 4096), probesample(w, x, y, z, dx, dy, dz, 2, 4096)) }
s("open", 0, 0, 0.1, 7.5, 0, 1, 0)
s("open_ref", 2, 0, 0.1, 7.5, 0, 1, 0)
s("under", 0, 0, 0.1, 0, 0, 1, 0)
s("under_ref", 2, 0, 0.1, 0, 0, 1, 0)
s("panel", 0, 6, 1, 0, 1, 0, 0)
s("panel_ref", 2, 6, 1, 0, 1, 0, 0)
s("up", 0, 6, 1, 0, 0, 1, 0)
s("up_ref", 2, 6, 1, 0, 0, 1, 0)
s("refl_to", 1, 5, 1, 0, 1, 0, 0)
s("refl_away", 1, 5, 1, 0, -1, 0, 0)
print("outside", probesample(0, 0, 5, 0, 0, 1, 0, 0) == nil)
op("file.save", "~/BeeModel/probes.bee")
op("file.new")
print("new", probe(0))
op("file.open", "~/BeeModel/probes.bee")
s("reopened", 0, 0, 0.1, 7.5, 0, 1, 0)
'''

LIGHTMAP = SCENE + '''
add("light", "Lamp", 2, 4, 2)
op("lightmap.bake", "256 128")
print("lm", lightmap(0), lightmap(1), lightmap(2), lightmap(4))
fn q(t, x, y, z) { print(t, lmsample("Floor", x, y, z, 0), lmsample("Floor", x, y, z, 1), lmsample("Floor", x, y, z, 2)) }
fn r(t, x, y, z) { print(t, probesample(2, x, y, z, 0, 1, 0, 0, 4096), probesample(2, x, y, z, 0, 1, 0, 1, 4096), probesample(2, x, y, z, 0, 1, 0, 2, 4096)) }
q("open", -6, 0, 7)
r("open_ref", -6, 0, 7)
q("under", 0, 0, 0)
r("under_ref", 0, 0, 0)
q("panel", 6, 0, 0)
r("panel_ref", 6, 0, 0)
print("roof", lmsample("Roof", 0, 2.1, 0, 1) > 0.3)
op("lightmap.save", "~/BeeModel/lightmap.png")
op("lightmap.save", "~/BeeModel/lightmap.exr")
op("file.export_gltf", "~/BeeModel/level.glb")
op("file.export_gltf", "~/BeeModel/level.gltf")
op("file.save", "~/BeeModel/lit.bee")
op("file.new")
print("cleared", lightmap(0))
op("file.open", "~/BeeModel/lit.bee")
q("reopened", -6, 0, 7)
op("file.new")
op("file.import_gltf", "~/BeeModel/level.glb")
print("imported", count())
'''


def run(home, code):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=300)
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
    return out


def close(a, b, tol):
    return len(a) == 3 and len(b) == 3 and all(abs(x - y) <= tol * max(abs(y), 0.05) for x, y in zip(a, b))


def validator():
    """The Khronos glTF validator (npm gltf-validator), in a temporary
    folder with its own npm cache; None when node / npm are not there."""
    if not shutil.which('node') or not shutil.which('npm'):
        return None
    d = tempfile.mkdtemp(prefix='bee-gv-')
    env = dict(os.environ, npm_config_cache=os.path.join(d, '.npm'))
    r = subprocess.run(['npm', 'install', '--no-audit', '--no-fund', '--prefix', d, 'gltf-validator@2.0.0-dev.3.10'],
                       env=env, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        print(r.stdout[-1000:], r.stderr[-1000:])
        return False
    js = os.path.join(d, 'validate.js')
    with open(js, 'w') as f:
        f.write('''const fs = require('fs');
const v = require(process.argv[2] + '/node_modules/gltf-validator');
const data = new Uint8Array(fs.readFileSync(process.argv[3]));
v.validateBytes(data, {uri: process.argv[3], externalResourceFunction: () => Promise.reject('none')})
  .then((r) => console.log(JSON.stringify(r))).catch((e) => { console.log(JSON.stringify({error: String(e)})); });
''')
    return lambda path: json.loads(subprocess.run(['node', js, d, path], capture_output=True, text=True,
                                                  timeout=120).stdout or '{}')


def window(home):
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-lt-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(600, 300)
    f.move(600, 300)
    q(SCENE + '\nop("probe.add", "irradiance 0 1 0 9 0.9 9 7 3 7")\nop("probe.add", "reflection 5 1.5 0 2.5 1.5 3")\n'
      'op("view.toggle_material_preview")')
    views = {'under': 'view(0, 80, 1.2, 0, 0, 0)', 'open': 'view(0, 80, 1.2, -4, 0, 7)',    # (yaw, pitch,
             'scene': 'view(-20, 8, 10, 1, 0.8, 0)'}                                         #  distance, target)
    shots = {}
    for k in ('before', 'after'):
        if k == 'after':
            m.tool('op_probe_bake', {'arg': '256'})
        for v in ('under', 'open', 'scene'):
            q(views[v])
            f.pump(0.4)
            shots[k, v] = f.image()
            if OUT and v == 'scene':
                f.shot('122_probes_unbaked.png' if k == 'before' else '123_probes_baked.png')
    m.tool('op_probe_add', {'arg': 'reflection 0 0 0 1 1 1'})
    n = q('print(probe(0), probe(1))')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    f.pump(0.3)
    undo = (n, q('print(probe(0), probe(1))'))
    f.proc.kill()
    return shots, undo


def region(img, x0, y0, x1, y1):
    n, s = 0, [0, 0, 0]
    for y in range(y0, y1, 2):
        for x in range(x0, x1, 2):
            p = img.getpixel((x, y))
            for i in range(3):
                s[i] += p[i]
            n += 1
    return [v / n for v in s]


def main():
    print('  -- lighting tools --')
    home = tempfile.mkdtemp(prefix='bee-lt-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    o = run(home, PROBES)
    g = lambda k: o.get(k, [])
    check(g('added') == [2, 1, 1, 147, 0], f'probe.add: an irradiance volume (7 x 3 x 7 points) and a reflection probe ({g("added")})')
    check(g('baked') == [2, 1024, 128, 1], f'probe.bake: both baked by the path tracer (1024 rays a point, 128 a texel) ({g("baked")})')
    check(close(g('open'), g('open_ref'), 0.1) and close(g('under'), g('under_ref'), 0.1)
          and close(g('panel'), g('panel_ref'), 0.06) and close(g('up'), g('up_ref'), 0.06),
          f'the probes\' spherical harmonics match irradiance traced directly ({g("open")} ~ {g("open_ref")}, '
          f'{g("panel")[:1]} ~ {g("panel_ref")[:1]})')
    check(len(g('under')) == 3 and g('under')[2] < 0.92 * g('open')[2],
          f'shade under the roof (blue {g("under")[2:]} < {g("open")[2:]} in the open)')
    check(len(g('panel')) == 3 and g('panel')[0] > 5 * g('panel')[1],
          f'red light from the panel bleeds onto what faces it ({g("panel")})')
    check(len(g('refl_to')) == 3 and g('refl_to')[0] > 4 and g('refl_away')[0] < 1.5,
          f'the reflection probe sees the panel one way, not the other ({g("refl_to")[:1]}, {g("refl_away")[:1]})')
    check(g('outside') == [1], 'outside every volume: nothing (the environment, as before)')
    check(g('new') == [0] and close(g('reopened'), g('open'), 0.001),
          f'saved in the .bee file: baked probes come back ({g("reopened")})')
    o = run(home, LIGHTMAP)
    g = lambda k: o.get(k, [])
    check(len(g('lm')) == 4 and g('lm')[0] == 4 and g('lm')[1] == 256 and g('lm')[2] > 10000,
          f'lightmap.bake: the four meshes in a 256 x 256 atlas ({g("lm")})')
    check(close(g('open'), g('open_ref'), 0.1) and close(g('under'), g('under_ref'), 0.1)
          and close(g('panel'), g('panel_ref'), 0.1),
          f'the lightmap matches irradiance traced directly ({g("open")} ~ {g("open_ref")}; {g("under")} ~ {g("under_ref")})')
    check(len(g('under')) == 3 and g('under')[2] < 0.92 * g('open')[2] and g('panel')[0] > 3 * g('panel')[1],
          f'shadow under the roof, red by the panel ({g("under")}, {g("panel")})')
    check(g('roof') == [1], 'the roof has its own region (its top lit)')
    png = os.path.join(home, 'BeeModel', 'lightmap.png')
    exr = os.path.join(home, 'BeeModel', 'lightmap.exr')
    pngok = exrok = False
    if os.path.exists(png):
        from PIL import Image
        im = Image.open(png).convert('RGB')
        lit = sum(1 for y in range(0, 256, 4) for x in range(0, 256, 4) if sum(im.getpixel((x, y))) > 30)
        pngok = im.size == (256, 256) and lit > 1000
    if os.path.exists(exr):
        with open(exr, 'rb') as fh:
            head = fh.read(4)
        exrok = struct.unpack('<I', head)[0] == 20000630 and os.path.getsize(exr) > 1000
    check(pngok and exrok, f'lightmap.save writes PNG (sRGB) and OpenEXR ({pngok}, {exrok})')
    check(g('cleared') == [0] and g('reopened') == g('open'),
          f'the lightmap is saved in the .bee file ({g("reopened")})')
    glb = os.path.join(home, 'BeeModel', 'level.glb')
    gltf = os.path.join(home, 'BeeModel', 'level.gltf')
    doc = json.load(open(gltf)) if os.path.exists(gltf) else {}
    lights = doc.get('extensions', {}).get('KHR_lights_punctual', {}).get('lights', [])
    lmats = [m for m in doc.get('materials', []) if 'MOZ_lightmap' in m.get('extensions', {})]
    tt = [m['extensions']['MOZ_lightmap'].get('extensions', {}).get('KHR_texture_transform') for m in lmats]
    estr = [m['extensions']['KHR_materials_emissive_strength']['emissiveStrength'] for m in doc.get('materials', [])
            if m.get('name') == 'Red']
    tex1 = [p for me in doc.get('meshes', []) for p in me['primitives'] if 'TEXCOORD_1' in p['attributes']]
    check(len(lights) == 2 and len(lmats) == 4 and all(t and len(t['offset']) == 2 for t in tt)
          and 8 in estr and len(tex1) == 4 and doc.get('images', [{}])[0].get('mimeType') == 'image/png',
          f'glTF: 2 point lights, emissive strength 8, 4 lightmapped materials with their regions, TEXCOORD_1, a PNG '
          f'({len(lights)}, {estr}, {len(lmats)}, {len(tex1)})')
    check(g('imported') and g('imported')[0] >= 5, f'the export imports again ({g("imported")})')
    v = validator()
    if v is None:
        print('  --   glTF validator skipped (no node / npm here)')
    else:
        res = [v(p) if v else {} for p in (glb, gltf)]
        errs = [r.get('issues', {}).get('numErrors', -1) for r in res]
        warns = [r.get('issues', {}).get('numWarnings', -1) for r in res]
        check(v is not False and errs == [0, 0] and warns == [0, 0],
              f'the Khronos glTF validator: no errors, no warnings in the .glb and the .gltf ({errs}, {warns})')
    shots, undo = window(home)
    check(undo == ('3 2', '2 2'), f'probes are undone with the scene (Ctrl+Z: {undo})')
    blue = lambda k, v: region(shots[k, v], 420, 250, 800, 450)[2]
    red = lambda k, v: region(shots[k, v], 420, 250, 800, 450)[0]
    rb = blue('before', 'under') / max(blue('before', 'open'), 1)
    ra = blue('after', 'under') / max(blue('after', 'open'), 1)
    tint = red('after', 'under') - blue('after', 'under')
    check(ra < 0.98 * rb and tint > 3,
          f'the material preview lights the floor from the probes: shade under the roof (blue against the '
          f'open {rb:.2f} -> {ra:.2f}), tinted red by the panel ({tint:.0f})')
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nlighting tools: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
