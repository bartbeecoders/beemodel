#!/usr/bin/env python3
"""Light assemblies (D4): three parts placed by mates, moving through a
mechanism joint.

A base plate, a pin and a wheel start anywhere, turned anyhow. Mates put
the pin upright in the plate's hole (concentric with an axis given in the
plate's own space) standing on its top face (coincident), and the wheel on
the pin (concentric with the pin's top face) 30 cm above the plate
(distance). A revolute joint then turns the wheel about the pin over the
timeline, and it stays on the pin. A mate that names no such face,
object or kind changes nothing.

    python3 tests/assembly.py build/beemodel
"""
import os, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
FAILS = []

SCENE = '''n = count()
for i in 0..n { delete(name(0)) }
b = add("cube", "Base", 0, 0, 0)
scale(b, 2, 0.1, 1)
p = add("cylinder", "Pin", 3, 2, -1)
scale(p, 0.1, 0.5, 0.1)
rotate(p, 0.3, 0.2, 1.1)
w = add("cylinder", "Wheel", -2, 3, 2)
scale(w, 0.6, 0.05, 0.6)
rotate(w, 1.2, 0, 0.4)
fn r(v) { return round(v * 1000) / 1000 }
fn at(o) { return r(get(o, "x")) + " " + r(get(o, "y")) + " " + r(get(o, "z")) }
'''

MATES = '''op("asm.mate", "concentric Pin 33 Base axis 0.5 0 0 0 1 0")
op("asm.mate", "coincident Pin 32 Base 1")
op("asm.mate", "concentric Wheel 33 Pin 33")
op("asm.mate", "distance Wheel 32 Base 1 30cm")
'''


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, home):
    with tempfile.NamedTemporaryFile('w', suffix='.bees', delete=False) as fh:
        fh.write(code)
    try:
        p = subprocess.run([BIN, '--run', fh.name], capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, HOME=home))
    finally:
        os.unlink(fh.name)
    return p.returncode, p.stdout


def last(out):
    lines = [l for l in out.splitlines() if l.strip()]
    return lines[-1].strip() if lines else ''


def main():
    with tempfile.TemporaryDirectory() as home:
        code, out = run(SCENE + MATES + 'print("pin", at("Pin"), r(get("Pin", "rx")), r(get("Pin", "rz")))', home)
        check(code == 0 and last(out) == 'pin 1 0.6 0 0 0',
              f'the pin stands upright in the plate\'s hole, on its top face ({last(out)!r})')
        code, out = run(SCENE + MATES + 'print("wheel", at("Wheel"), r(get("Wheel", "rx")), r(get("Wheel", "rz")))', home)
        check(code == 0 and last(out) == 'wheel 1 0.45 0 0 0',
              f'the wheel sits on the pin, 30 cm above the plate ({last(out)!r})')
        code, out = run(SCENE + MATES + '''ry0 = deg(get("Wheel", "ry"))
op("mech.joint", "revolute Wheel Pin pivot 1 0.45 0 axis 0 1 0 value frame*4.5deg")
frame(10)
print("turned", at("Wheel"), r(joint(1)), r(deg(get("Wheel", "ry")) - ry0))
frame(1)
print("back", at("Wheel"), r(deg(get("Wheel", "ry")) - ry0))''', home)
        lines = [l.strip() for l in out.splitlines() if l.startswith(('turned', 'back'))]
        check(code == 0 and lines == ['turned 1 0.45 0 0.785 45', 'back 1 0.45 0 4.5'],
              f'a revolute joint turns the wheel about the pin over the timeline, on its axis ({lines})')
        code, out = run(SCENE + '''op("asm.mate", "coincident Pin 99 Base 1")
op("asm.mate", "coincident Pin 32 Nothing 1")
op("asm.mate", "glued Pin 32 Base 1")
print("still", at("Pin"))''', home)
        check(code == 0 and last(out) == 'still 3 2 -1',
              f'a mate with no such face, object or kind changes nothing ({last(out)!r})')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
