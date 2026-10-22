#!/usr/bin/env python3
"""Files from 1.0 open in every later version (D7).

tests/fixtures/compat/v1.0.bee was saved by BeeModel 1.0.0 from SCENE: a
scene with a bit of everything a .bee holds (meshes and an edited vertex,
modifiers, a material, keys, CAD parameters, a sketch and features, an
armature, folders, a landscape, a force field, a mate and a mechanism
joint, a geometry node tree, light and camera settings).
v1.0.txt is what PROBE printed then. Every later version must open the
file and print the same, with only built-ins frozen in 1.x (D1).

    python3 tests/compat.py build/beemodel             # check
    python3 tests/compat.py build/beemodel --update    # 1.0.0 only: write the fixture
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else 'build/beemodel')
FIX = os.path.join(HERE, 'fixtures', 'compat')
FAILS = []

SCENE = r'''seed(7)
move("Cube", 1, 2, 3)
rotate("Cube", 0.1, 0.2, 0.3)
scale("Cube", 1, 2, 1)
set("Cube", "color", 0x3388cc)
vmove("Cube", 0, -1.5, -1, -1)
s = add("sphere", "Ball", -3, 1, 0)
k = modifier(s, "subsurf")
modset(s, k, "levels", 1)
m = material("Gold")
matset(m, "base", 1, 0.77, 0.34)
matset(m, "metallic", 1)
matset(m, "roughness", 0.3)
assign(s, m)
key("Cube:x", 1, 1, "linear")
key("Cube:x", 21, 5, "linear")
param("w", "60mm")
sk = sketch("Base", "XZ")
r = rect(sk, 0, 0, 60mm, 40mm)
pad("Part", sk, "20mm")
fillet("Part", "2mm", "vertical")
a = armature("Rig")
infolder("Ball", "Props")
infolder("Cube", "Props")
op("landscape.add", "hills size 50 res 65")
field("attractor", "Pull")
c = add("cylinder", "Pin", 6, 0, 0)
scale(c, 0.1, 0.5, 0.1)
op("asm.mate", "coincident Pin 32 Part 1")
op("mech.joint", "revolute Pin world axis 0 1 0 value frame*2deg")
t = gtree("Rocks")
g = gnode(t, "grid", 4, 3)
o = gnode(t, "output")
glink(t, g, o, 1)
p = add("plane", "Floor", 0, -1, 0)
k = modifier(p, "geometry")
modset(p, k, "tree", t)
set("Light", "power", 2)
set("Camera", "lens", 35)
'''

PROBE = r'''fn r(v) { return round(v * 1000) / 1000 }
out = "objects " + count()
for i in 0..count() {
    n = name(i)
    out = out + "\n" + n + " t" + objtype(n) + " @" + r(get(n, "x")) + "," + r(get(n, "y")) + "," + r(get(n, "z"))
    out = out + " r" + r(get(n, "rx")) + "," + r(get(n, "ry")) + "," + r(get(n, "rz"))
    out = out + " s" + r(get(n, "sx")) + "," + r(get(n, "sy")) + "," + r(get(n, "sz"))
    out = out + " c" + get(n, "color") + " h" + get(n, "hidden") + " f" + str(infolder(n)) + " p" + str(parent(n))
    if objtype(n) == 0 {
        out = out + " mesh " + verts(n) + "/" + faces(n) + " eval " + everts(n) + "/" + efaces(n) + " mods " + modcount(n) + " mat " + str(matof(n))
    }
}
out = out + "\nvertex0 " + r(vpos("Cube", 0, 0)) + "," + r(vpos("Cube", 0, 1))
out = out + "\nGold " + r(matget("Gold", "base", 0)) + " " + r(matget("Gold", "metallic")) + " " + r(matget("Gold", "roughness"))
out = out + "\nkey " + r(keyed("Cube:x", 11))
out = out + "\nfeatures " + features() + " status " + fstatus(0) + "," + fstatus(1) + " w " + r(param("w"))
out = out + "\nbones " + bones("Rig") + " folders " + folders()
out = out + "\nlight " + r(get("Light", "power")) + " lens " + r(get("Camera", "lens"))
out = out + "\njoint " + r(joint(1))
out = out + "\nfields " + fieldinfo(0)
print(out)
'''


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, home):
    p = subprocess.run([BIN, '--eval', code], capture_output=True, text=True, timeout=120,
                       env=dict(os.environ, HOME=home))
    return p.returncode, p.stdout.strip()


def main():
    bee = os.path.join(FIX, 'v1.0.bee')
    want = os.path.join(FIX, 'v1.0.txt')
    with tempfile.TemporaryDirectory() as home:
        if '--update' in sys.argv:
            version = open(os.path.join(HERE, '..', 'VERSION')).read().strip()
            if version != '1.0.0':
                sys.exit(f'the 1.0 fixture is never rewritten (this is {version}); add a new one beside it instead')
            code, out = run(SCENE + 'op("file.save", "%s")\n' % bee + PROBE, home)
            check(code == 0 and os.path.exists(bee), 'the 1.0 scene saved')
            open(want, 'w').write(out + '\n')
            print(f'  wrote {bee} ({os.path.getsize(bee)} bytes) and v1.0.txt')
        else:
            ref = open(want).read().strip()
            code, out = run('op("file.open", "%s")\n' % bee + PROBE, home)
            diff = [f'{a!r} != {b!r}' for a, b in zip(out.splitlines(), ref.splitlines()) if a != b]
            check(code == 0 and out == ref, 'the file 1.0 saved opens with everything as it was' +
                  (': ' + '; '.join(diff[:4]) if diff else ''))
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
