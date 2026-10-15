#!/usr/bin/env python3
"""The materials walkthrough (v0.13): one scene that uses every part of the
PBR material system, built the way a user or an agent would, then rendered,
saved, opened again and exchanged.

  * a floor from a PBR texture set (base colour, DirectX normal, roughness,
    AO: found by name), a gold ball from a preset, a procedural wood box
    baked to texture maps;
  * a painted crate material with parameters, two instances of it that
    override them, and a material function shared by two materials;
  * a masked, one-sided leaf;
  * the render, the .bee file (everything back, the same image), glTF out
    and in again with its texture maps.

    python3 tests/materials.py build/beemodel [shots dir]
"""
import json, os, struct, subprocess, sys, tempfile

ARGS = [a for a in sys.argv[1:] if not a.startswith('--')]
BIN = os.path.abspath(ARGS[0] if ARGS else 'build/beemodel')
OUT = ARGS[1] if len(ARGS) > 1 else None
HOME = tempfile.mkdtemp(prefix='bee-mat-')
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code):
    env = dict(os.environ, HOME=HOME, XDG_CACHE_HOME='', BEEMODEL_GPU='off')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=600)
    return r.stdout.strip() + ('\n' + r.stderr.strip() if r.stderr.strip() else '')


def texture_set(d):
    from PIL import Image
    os.makedirs(d, exist_ok=True)
    im = Image.new('RGB', (64, 64))
    im.putdata([((150 + (x // 8 + y // 8) % 2 * 60), 120, 90) for y in range(64) for x in range(64)])
    im.save(os.path.join(d, 'Tiles_BaseColor_1k.png'))
    Image.new('RGB', (64, 64), (128, 128, 255)).save(os.path.join(d, 'Tiles_Normal_DX_1k.png'))
    Image.new('RGB', (64, 64), (140, 140, 140)).save(os.path.join(d, 'Tiles_Roughness_1k.png'))
    Image.new('RGB', (64, 64), (230, 230, 230)).save(os.path.join(d, 'Tiles_AO_1k.png'))


def scene(tex):
    return f'''delete("Cube")
f = add("plane", "Floor", 0, -1, 0)
scale(f, 5, 1, 5)
unwrap(f)
select(f)
op("material.import_textures", "{tex}/Tiles_BaseColor_1k.png")
g = add("sphere", "Ball", -1.6, 0, 0)
select(g)
op("material.preset", "gold")
w = add("cube", "Box", 1.6, -0.2, -1)
scale(w, 0.8, 0.8, 0.8)
unwrap(w, "smart")
select(w)
op("material.preset", "wood")
op("material.bake", "Box 128 apply")
c = material("Crate")
t = node(c, "texcoord", 2, 2)
k = node(c, "checker", 6)
link(c, t, k, 1)
tint = node(c, "vectorparam", "Tint", 0.8, 0.2, 0.1)
x = node(c, "mix", 2)
nodeset(c, x, 1, 1)
link(c, k, x, 2)
link(c, tint, x, 3)
socket(c, "base", x)
wear = node(c, "scalarparam", "Wear", 0.3)
socket(c, "roughness", wear)
a = instance(c, "CrateBlue")
matparam(a, "Tint", 0.1, 0.2, 0.9)
b = instance(c, "CrateGreen")
matparam(b, "Tint", 0.1, 0.7, 0.2)
matparam(b, "Wear", 0.8)
for i in 0..3 {{
 o = add("cube", "Crate" + i, -2 + i * 1.3, -0.6, 2)
 scale(o, 0.4, 0.4, 0.4)
}}
assign("Crate0", c)
assign("Crate1", a)
assign("Crate2", b)
op("material.function_new", "Glow")
gn = node("Glow", "vmath", 9)
link("Glow", 1, gn, 1)
nodeset("Glow", gn, 2, 3)
link("Glow", gn, 2, 1)
for i in 0..2 {{
 em = material("Lamp" + i)
 col = node(em, "color")
 nodeset(em, col, 1, 0.9 - i * 0.6, 0.5, 0.2 + i * 0.6)
 fc = node(em, "fncall", "Glow")
 link(em, col, fc, 1)
 socket(em, "emission", fc)
 l = add("sphere", "Lamp" + i, -0.5 + i, 1.6, 1)
 scale(l, 0.2, 0.2, 0.2)
 assign(l, em)
}}
lf = add("plane", "Leaf", 0.2, 0.2, -2)
rotate(lf, rad(90), 0, 0)
lm = material("Leaf")
matset(lm, "base", 0.2, 0.6, 0.15)
matset(lm, "blend", 1)
matset(lm, "one_sided", 1)
ck = node(lm, "checker", 5)
nodeset(lm, ck, 1, 0)
nodeset(lm, ck, 2, 1)
socket(lm, "mask", ck)
assign(lf, lm)
'''


def main():
    print('  -- materials walkthrough --')
    tex = os.path.join(HOME, 'tiles')
    texture_set(tex)
    base = scene(tex)
    shot = os.path.join(OUT or HOME, 'materials_walkthrough.png')
    bee = os.path.join(HOME, 'walk.bee')
    out = run(base + f'render("{shot}", 320, 180, 32)\nop("file.save", "{bee}")\n'
              'print("floor", matof("Floor"), nodeinfo(matof("Floor"), 0, "count"))\n'
              'print("ball", matof("Ball"), matget(matof("Ball"), "metallic"))\n'
              'print("box", matof("Box"), nodeinfo(matof("Box"), 0, "count"), imgsize("wood_base", 0))\n'
              'print("crates", matparam("CrateBlue", "Tint"), matparam("CrateGreen", "Wear"), matparam("CrateBlue", "Wear"))\n'
              'print("lamps", nodeval("Lamp0", 2, 0, 0, 0, 0), nodeval("Lamp1", 2, 2, 0, 0, 0))')
    v = {l.split()[0]: l.split()[1:] for l in out.splitlines() if l.split()}
    check(v.get('floor', [''])[0] == 'Tiles' and int(v['floor'][1]) >= 6,
          f'a floor from a PBR texture set: its maps found by name ({v.get("floor")})')
    check(v.get('ball') == ['gold', '1'], f'a gold ball from a preset ({v.get("ball")})')
    check(v.get('box') == ['wood', '6', '128'], f'a procedural wood box baked to 128 x 128 maps it now samples ({v.get("box")})')
    check(v.get('crates') == ['0.1', '0.8', '0.3'], f'two instances of a crate material override its parameters ({v.get("crates")})')
    try:
        lamps = [float(x) for x in v.get('lamps', [])]
        ok = abs(lamps[0] - 2.7) < 1e-4 and abs(lamps[1] - 2.4) < 1e-4
    except (ValueError, IndexError):
        ok, lamps = False, v.get('lamps')
    check(ok, f'one material function (x 3) shared by two lamps ({lamps})')
    from PIL import Image
    img = Image.open(shot).convert('RGB') if os.path.exists(shot) else None
    cols = len({tuple(c // 32 for c in p) for p in img.get_flattened_data()}) if img else 0
    check(img is not None and cols > 40, f'the scene renders ({cols} distinct colours)')
    # the file: everything back, the same image
    shot2 = os.path.join(HOME, 'reopened.png')
    run(f'op("file.open", "{bee}")\nrender("{shot2}", 320, 180, 32)')
    same = False
    if img and os.path.exists(shot2):
        b = Image.open(shot2).convert('RGB')
        diff = sum(abs(x - y) for p, q in zip(img.get_flattened_data(), b.get_flattened_data()) for x, y in zip(p, q)) / (3 * 320 * 180)
        same = diff < 0.5
    check(same, 'saved and opened again: the same image')
    # glTF out and in again
    glb = os.path.join(HOME, 'walk.glb')
    run(f'op("file.open", "{bee}")\nop("file.export_gltf", "{glb}")')
    try:
        d = open(glb, 'rb').read()
        n = struct.unpack('<I', d[12:16])[0]
        j = json.loads(d[20:20 + n])
        names = sorted(i.get('name', '') for i in j.get('images', []))
    except (OSError, ValueError, struct.error):
        names = []
    check(any(x.startswith('Tiles') for x in names) and 'wood_base' in names,
          f'glTF: the texture maps go along ({len(names)} images)')
    out = run(f'op("file.new")\nop("file.import_gltf", "{glb}")\nm = matof("Floor")\nprint("in", m, nodeinfo(m, 0, "socket", 0) > 0)')
    check('in Tiles 1' in out.replace('true', '1'), f'and come back as a graph on import ({out.splitlines()[-1:]})')
    print()
    print('materials walkthrough: ' + ('all checks passed' if not FAILS else f'{len(FAILS)} failure(s)'))
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
