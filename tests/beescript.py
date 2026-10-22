#!/usr/bin/env python3
"""BeeScript frozen for 1.x (D1): 50 tasks an AI agent is asked to do.

Each task is the script an agent writes for it, in the forms agents use
(loops, functions, units, text joining, the scene built-ins), with the
answer it must print. Every script runs with `beemodel --eval` against
the default scene in an isolated HOME and must finish without an error
and print exactly the expected last line. The language may grow (new
built-ins) but none of these may change meaning in 1.x: a failure here
is a breaking change.

    python3 tests/beescript.py build/beemodel
"""
import os, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')

# (task, script, expected last line of the output)
TASKS = [
    ('Add a cube named Box at (1, 2, 3).',
     'add("cube", "Box", 1, 2, 3)\nprint(get("Box", "x"), get("Box", "y"), get("Box", "z"))',
     '1 2 3'),
    ('Make a row of ten cubes, 2 m apart.',
     'for i in 0..10 {\n    add("cube", "Step" + i, i * 2m, 0, 0)\n}\nprint(exists("Step9"), get("Step9", "x"))',
     '1 18'),
    ('Place 12 spheres on a ring of radius 6 m.',
     'fn ring(n, r) {\n    for i in 0..n {\n        a = i * 360deg / n\n        add("sphere", "R" + i, cos(a) * r, 1, sin(a) * r)\n    }\n}\nring(12, 6m)\nprint(round(get("R3", "z")), round(get("R6", "x")))',
     '6 -6'),
    ('How many objects are in the scene?',
     'print(count())',
     '3'),
    ('List the names of all objects.',
     'out = ""\nfor i in 0..count() { out = out + name(i) + "," }\nprint(out)',
     'Camera,Light,Cube,'),
    ('Delete the default cube.',
     'delete("Cube")\nprint(exists("Cube"), count())',
     '0 2'),
    ('Rotate the cube 45 degrees about Y.',
     'rotate("Cube", 0, 45deg, 0)\nprint(round(deg(get("Cube", "ry"))))',
     '45'),
    ('Scale the cube to twice its size.',
     'scale("Cube", 2)\nprint(get("Cube", "sx"), get("Cube", "sy"), get("Cube", "sz"))',
     '2 2 2'),
    ('Make the cube 3 m tall, keeping its width.',
     'scale("Cube", 1, 1.5, 1)\nprint(get("Cube", "sy"))',
     '1.5'),
    ('Move the cube up by 50 cm.',
     'move("Cube", get("Cube", "x"), get("Cube", "y") + 50cm, get("Cube", "z"))\nprint(get("Cube", "y"))',
     '1.5'),
    ('Rename the cube to Crate.',
     'n = rename("Cube", "Crate")\nprint(n, exists("Crate"))',
     'Crate 1'),
    ('Select the cube and the light, light active.',
     'select("Cube", "Light")\nprint(issel("Cube"), issel("Camera"), active())',
     '1 0 Light'),
    ('Deselect everything.',
     'select()\nprint(issel("Cube"), active() == nil)',
     '0 1'),
    ('Colour the cube red.',
     'set("Cube", "color", 0xff0000)\nprint(get("Cube", "color") == 16711680)',
     '1'),
    ('Hide the light.',
     'set("Light", "hidden", 1)\nprint(get("Light", "hidden"))',
     '1'),
    ('How many vertices and faces has the cube?',
     'print(verts("Cube"), faces("Cube"))',
     '8 6'),
    ('Is the cube a closed mesh, and what is its volume?',
     'print(manifold("Cube"), round(volume("Cube")))',
     '1 8'),
    ('Add a subdivision surface, level 2, and count the faces after it.',
     'k = modifier("Cube", "subsurf")\nmodset("Cube", k, "levels", 2)\nprint(modcount("Cube"), efaces("Cube"))',
     '1 96'),
    ('Apply the modifier.',
     'k = modifier("Cube", "subsurf")\nmodset("Cube", k, "levels", 1)\nmodapply("Cube", k)\nprint(modcount("Cube"), faces("Cube"))',
     '0 24'),
    ('Drill four holes through a plate.',
     'add("cube", "Plate", 0, 0, 0)\nscale("Plate", 2, 0.2, 2)\nfor i in 0..4 {\n  add("cylinder", "Hole", i - 1.5, 0, 0)\n  scale("Hole", 0.3, 1, 0.3)\n  boolean("Plate", "Hole", "difference")\n}\nprint(manifold("Plate"), exists("Hole"))',
     '1 0'),
    ('Make a gold material and give it to the cube.',
     'm = material("Gold")\nmatset(m, "base", 1, 0.77, 0.34)\nmatset(m, "metallic", 1)\nassign("Cube", m)\nprint(matof("Cube"), matget(m, "metallic"))',
     'Gold 1'),
    ('Make the cube rough plastic using a preset.',
     'select("Cube")\nop("material.preset", "plastic")\nprint(matof("Cube"), matget(matof("Cube"), "metallic"))',
     'plastic 0'),
    ('Parent the cube to an empty-looking sphere.',
     'add("sphere", "Hub", 0, 3, 0)\nop("object.parent_set", "Cube Hub")\nprint(parent("Cube"))',
     'Hub'),
    ('Put the cube and the light in a folder Props.',
     'infolder("Cube", "Props")\ninfolder("Light", "Props")\nprint(infolder("Cube"), folders())',
     'Props 1'),
    ('Add a camera at (0, 2, 10) with a 35 mm lens.',
     'c = add("camera", "Shot", 0, 2, 10)\nset(c, "lens", 35)\nprint(c, get(c, "lens"))',
     'Shot 35'),
    ('Make the light twice as bright.',
     'set("Light", "power", get("Light", "power") * 2)\nprint(get("Light", "power"))',
     '2'),
    ('Stack five boxes, each half as big as the one below.',
     'y = 0\ns = 1\nfor i in 0..5 {\n    b = add("cube", "Tier" + i, 0, y + s, 0)\n    scale(b, s)\n    y += 2 * s\n    s *= 0.5\n}\nprint(get("Tier4", "sx"), get("Tier4", "y"))',
     '0.0625 3.8125'),
    ('Fibonacci: the 20th number.',
     'fn fib(n) {\n    if n < 2 { return n }\n    return fib(n - 1) + fib(n - 2)\n}\nprint(fib(20))',
     '6765'),
    ('Sum the even numbers below 100.',
     's = 0\nfor i in 0..100 {\n    if i % 2 != 0 { continue }\n    s += i\n}\nprint(s)',
     '2450'),
    ('Find the first square above 1000.',
     'i = 0\nwhile 1 {\n    if i * i > 1000 { break }\n    i += 1\n}\nprint(i, i * i)',
     '32 1024'),
    ('Convert 1.5 inches to millimetres.',
     'print(round(1.5 * 25.4mm / 1mm * 10) / 10)',
     '38.1'),
    ('Turn the text "2cm" into metres.',
     'print(num("2cm"), num("abc") == nil)',
     '0.02 1'),
    ('Build a label with a number in it.',
     'n = 7\nprint("Box_" + n + "_v" + 2)',
     'Box_7_v2'),
    ('How long is the name "Spaceship"?',
     'print(len("Spaceship"))',
     '9'),
    ('Clamp a value into 0..1.',
     'fn clamp(x) { return max(0, min(1, x)) }\nprint(clamp(-2), clamp(0.25), clamp(9))',
     '0 0.25 1'),
    ('A repeatable random scatter of 20 rocks.',
     'seed(42)\nfor i in 0..20 { add("sphere", "Rock" + i, rand() * 10, 0, rand() * 10) }\na = get("Rock7", "x")\nseed(42)\nfor i in 0..20 { add("sphere", "Again" + i, rand() * 10, 0, rand() * 10) }\nprint(a == get("Again7", "x"), count())',
     '1 43'),
    ('Is the active object selected? Say yes or no.',
     'select("Cube")\nif issel(active()) { print("yes") } else { print("no") }',
     'yes'),
    ('Grade a value with else if.',
     'fn grade(v) {\n    if v >= 90 { return "A" } else if v >= 75 { return "B" } else { return "C" }\n}\nprint(grade(95) + grade(80) + grade(10))',
     'ABC'),
    ('and / or return an operand.',
     'name = nil\nprint(name or "Untitled", 0 and 5, 3 and 5)',
     'Untitled 0 5'),
    ('Angle of the vector (1, 1) in degrees.',
     'print(deg(atan2(1, 1)))',
     '45'),
    ('A circle\'s area for r = 2 m, two decimals.',
     'print(round(pi * pow(2m, 2) * 100) / 100)',
     '12.57'),
    ('Where is vertex 0 of the cube?',
     'print(vpos("Cube", 0, "x"), vpos("Cube", 0, 1), vpos("Cube", 0, "z"))',
     '-1 -1 -1'),
    ('Move vertex 0 of the cube down by 1 m.',
     'vmove("Cube", 0, -1, -2, -1)\nprint(vpos("Cube", 0, "y"))',
     '-2'),
    ('Extrude the top face of the cube by 1 m in edit mode.',
     'edit("Cube")\nvselect("Cube")\nfor i in 0..verts("Cube") {\n    if vpos("Cube", i, "y") > 0 { vsel("Cube", i, 1) }\n}\nop("mesh.extrude", 1)\nedit()\ntop = -9\nfor i in 0..verts("Cube") { top = max(top, vpos("Cube", i, "y")) }\nprint(verts("Cube"), faces("Cube"), top)',
     '12 10 2'),
    ('Sketch a 40 x 20 rectangle on XZ and pad it 10 mm.',
     's = sketch("Base", "XZ")\nrect(s, 0, 0, 40mm, 20mm)\npad("Part", s, 10mm)\nprint(manifold("Part"), round(volume("Part") * 1e9))',
     '1 8000'),
    ('A parameter drives a value.',
     'param("wall", "2mm")\nprint(round(expr("10*wall + 2mm") * 1000))',
     '22'),
    ('Key the cube\'s x at frames 1 and 11 and read frame 6.',
     'key("Cube:x", 1, 0, "linear")\nkey("Cube:x", 11, 10, "linear")\nprint(keyed("Cube:x", 6))',
     '5'),
    ('Make a pyramid of cubes 4 layers high.',
     'n = 0\nfor layer in 0..4 {\n    w = 4 - layer\n    for i in 0..w {\n        for j in 0..w {\n            add("cube", "P" + n, i * 2 + layer, layer * 2, j * 2 + layer)\n            n += 1\n        }\n    }\n}\nprint(n, count())',
     '30 33'),
    ('Comment the script, and use ; between statements.',
     '# set up\na = 1; b = 2   # two values\nprint(a + b) ; # done',
     '3'),
    ('A long call split over lines.',
     'add("cube", "Wide",\n    1,\n    2,\n    3)\nprint(get("Wide", "z"))',
     '3'),
]


def run(script, home):
    p = subprocess.run([BIN, '--eval', script], capture_output=True, text=True,
                       timeout=60, env=dict(os.environ, HOME=home))
    return p.returncode, (p.stdout + p.stderr).strip()


def main():
    assert len(TASKS) == 50, len(TASKS)
    fails = []
    with tempfile.TemporaryDirectory() as home:
        for k, (task, script, want) in enumerate(TASKS, 1):
            code, out = run(script, home)
            last = out.splitlines()[-1] if out else ''
            ok = code == 0 and 'error' not in out and last == want
            print(('  ok   ' if ok else '  FAIL ') + '%2d %s' % (k, task))
            if not ok:
                print('         exit %d, got %r, want %r' % (code, out[-300:], want))
                fails.append(k)
    print('%d of %d tasks ran' % (len(TASKS) - len(fails), len(TASKS)))
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
