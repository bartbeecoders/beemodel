#!/usr/bin/env python3
"""Attractors and force fields (2.0 plan, stage A).

A1: force field objects - each type (attractor, gravity zone, wind,
vortex, turbulence, drag) pulls a test point the way its formula says,
within 1%: falloff (none, radius, smooth), the attractor's two laws, a
negative strength, off; the strength keyframed (field:Name:strength);
undo, duplicate and a saved file keep the settings. In the fake
compositor: Add > Force Field > Vortex from the menu, its section in
Properties > Physics, its strength changed there.

A2: fields on everything - a body in a circular orbit round an attractor
(the world's gravity off) keeps its radius within 1% over 10 orbits; a
sheet hung by one edge blows out in a wind field; a field for one
collision group leaves the others alone; a gravity zone lands a body on
a wall.

A3: bodies that attract each other - two 1000 kg bodies marked Attracts
(G 1) orbit their common centre: it stays put, their distance within 1%;
5445 attracting bodies (instances) run at 10 steps a second or better
(the tree and pulls timed: rbinfo(24)); Attracts in Properties > Physics.

A4: walk on a planet - in play mode on a 20 m sphere with an attractor at
its centre (the world's gravity off) the player walks forward: a quarter
round it stands on the side (its up: sideways), half way on the bottom
(up: down), and once round it is back at its start; the logic nodes Set
Strength (a field's strength in play) and Field (the pull at a point).

A5: seeing the fields - Add > Force Field > Tornado from the menu (fake
compositor); View > Force Field Arrows draws its pull on a grid, View >
Force Field Lines streamlines from the selected cube that swirl round the
tornado's axis as they rise; the presets Planet (a sphere, gravity off),
Black Hole, Breeze by BeeScript field().

    python3 tests/fields.py build/beemodel
"""
import math, os, subprocess, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
FAILS = []
CI = bool(os.environ.get('CI'))


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, timeout=600, home=None):
    home = home or tempfile.mkdtemp(prefix='bee-fields-')
    os.makedirs(os.path.join(home, 'BeeModel'), exist_ok=True)
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(r.stdout[-1500:], r.stderr[-1500:])
    return [l.split() for l in r.stdout.splitlines() if l.strip()]


def vals(out, key):
    for l in out:
        if l and l[0] == key:
            try:
                return [float(x) for x in l[1:]]
            except ValueError:
                return l[1:]
    return []


def near(a, b, rel=0.01, eps=1e-4):
    return abs(a - b) <= max(eps, rel * abs(b))


CLOUD = '''
delete("Cube")
delete("Light")
delete("Camera")
op("rigid.world", "gravity 0 0 0 g 0.5")
t = gtree("Cloud")
o = gnode(t, "output")
g = gnode(t, "grid", 100, 32)
s = gnode(t, "sphere", 0.2)
ip = gnode(t, "instance", 0, 0, 0)
glink(t, g, ip, 1)
glink(t, s, ip, 2)
glink(t, ip, o, 1)
for k in 0..5 {
  n = "L" + str(k)
  add("cube", n, k * 0.7, -40 + k * 20, k * 1.3)
  m = modifier(n, "geometry")
  modset(n, m, "tree", t)
  select(n)
  op("rigid.add", "active sphere mass 10 attracts instances")
}
y0 = instpos("L0", 500, 1)
frame(2)
t1 = clock()
frame(26)
t2 = clock()
print("cloud", rbinfo(22), t2 - t1, rbinfo(24), instpos("L0", 500, 1) - y0)
'''


def a1():
    print('-- A1: force field objects --')
    out = run('''
delete("Cube")
op("rigid.world", "gravity 0 0 0")
print("g0", force(0, 0, 0))
field("attractor", "A", "strength 20 soft 0.1")
print("attr", force(2, 0, 0, "x"), force(0, 3, 0, "y"), force(1, 1, 1, "z"))
op("field.set", "law linear")
print("lin", force(2, 0, 0, "x"))
op("field.set", "law square strength -20")
print("push", force(2, 0, 0, "x"))
op("field.set", "strength 20 falloff radius radius 3")
print("radius", force(2, 0, 0, "x"), force(4, 0, 0, "x"))
op("field.set", "falloff smooth radius 4")
print("smooth", force(2, 0, 0, "x"))
op("field.set", "off")
print("off", force(2, 0, 0))
delete("A")
field("zone", "Z", "strength 3 size 2")
rotate("Z", 1.5707963, 0, 0)
print("zone", force(0, 1, 0, "y"), force(0, 1, 0, "z"), force(0, 3, 0))
op("field.set", "shape sphere")
print("zsphere", force(1, 1, 1, "z"), force(1.5, 1.5, 0))
delete("Z")
field("wind", "W", "strength 3 gust 0")
rotate("W", 0, 1.5707963, 0)
print("wind", force(5, 1, 2, "x"), force(5, 1, 2, "z"))
delete("W")
field("vortex", "V", "strength 4 lift 1 inflow 2 falloff none")
print("vortex", force(2, 0, 0, "x"), force(2, 0, 0, "y"), force(2, 0, 0, "z"))
delete("V")
field("turbulence", "T", "strength 5 scale 2")
print("turb", force(0.3, 0.7, 1.1), force(0.3, 0.7, 1.1), force(4.3, -0.2, 2.9))
op("field.set", "seed 7")
print("turb7", force(0.3, 0.7, 1.1))
delete("T")
field("drag", "D", "strength 0.5")
print("drag", force(1, 1, 1))
print("types", objtype("D"))
''')
    g0 = vals(out, 'g0')
    check(g0 == [0.0], 'gravity off (rigid.world gravity 0 0 0): nothing pulls (%s)' % g0)
    a = vals(out, 'attr')
    s = 20.0
    def plummer(d, comp):
        q = sum(x * x for x in d) + 0.01
        return -s * comp / q ** 1.5
    want = [plummer((2, 0, 0), 2), plummer((0, 3, 0), 3), plummer((1, 1, 1), 1)]
    check(len(a) == 3 and all(near(x, y) for x, y in zip(a, want)),
          'Attractor: strength / distance squared towards it, softened (%s, want %s)'
          % (a, [round(x, 4) for x in want]))
    lin = vals(out, 'lin')
    check(lin and near(lin[0], -s * 2 / 4.01), 'law linear: strength / distance (%s)' % lin)
    p = vals(out, 'push')
    check(p and near(p[0], -want[0]), 'a negative strength pushes away (%s)' % p)
    r = vals(out, 'radius')
    check(len(r) == 2 and near(r[0], want[0]) and r[1] == 0, 'falloff radius: whole inside, nothing past it (%s)' % r)
    sm = vals(out, 'smooth')
    check(sm and near(sm[0], want[0] * (1 - (2 / 4) ** 2) ** 2), 'falloff smooth: (1 - (d/r)^2)^2 (%s)' % sm)
    check(vals(out, 'off') == [0.0], 'switched off: no pull (%s)' % vals(out, 'off'))
    z = vals(out, 'zone')
    # turned a quarter round X: its -Y points along -Z
    check(len(z) == 3 and near(z[0], 0) and near(z[1], -3) and z[2] == 0,
          'Gravity zone (box): inside, down is its -Y (turned: -Z) at its strength; outside none (%s)' % z)
    zs = vals(out, 'zsphere')
    check(len(zs) == 2 and near(zs[0], -3) and zs[1] == 0, 'a sphere zone: inside its radius only (%s)' % zs)
    w = vals(out, 'wind')
    check(len(w) == 2 and near(w[0], 3 * math.cos(1.5707963), eps=1e-3) and near(w[1], -3),
          'Wind: along its +X (turned a quarter round Y: -Z), at its strength (%s)' % w)
    v = vals(out, 'vortex')
    # at +X round +Y: tangent (Y x X) = -Z, inflow -X, lift +Y
    check(len(v) == 3 and near(v[0], -2) and near(v[1], 1) and near(v[2], -4),
          'Vortex: strength along the tangent, inflow towards the axis, lift along it (%s)' % v)
    t = vals(out, 'turb')
    t7 = vals(out, 'turb7')
    check(len(t) == 3 and t[0] == t[1] and t[0] > 0.2 and t[2] > 0.2 and t[0] != t[2] and t7 and t7[0] != t[0],
          'Turbulence: swirls that differ from place to place and with the seed, the same twice (%s, %s)' % (t, t7))
    check(vals(out, 'drag') == [0.0], 'Drag: nothing on a still thing (%s)' % vals(out, 'drag'))
    check(vals(out, 'types') == [5.0], 'a field is an object of its own type (%s)' % vals(out, 'types'))

    # the turbulence's curl: no divergence (a sum of curls)
    out = run('''
delete("Cube")
op("rigid.world", "gravity 0 0 0")
field("turbulence", "T", "strength 1 scale 1")
e = 0.01
x = 0.37
y = 1.21
z = -0.55
d = (force(x+e, y, z, "x") - force(x-e, y, z, "x")) + (force(x, y+e, z, "y") - force(x, y-e, z, "y")) + (force(x, y, z+e, "z") - force(x, y, z-e, "z"))
print("div", d / (2*e), force(x, y, z))
''')
    dv = vals(out, 'div')
    check(len(dv) == 2 and abs(dv[0]) < 0.05 * dv[1], 'turbulence is curl noise: no divergence (%s)' % dv)

    tmp = tempfile.mkdtemp(prefix='bee-fields-')
    bee = os.path.join(tmp, 'f.bee')
    out = run(f'''
delete("Cube")
op("rigid.world", "gravity 0 0 0")
field("attractor", "A", "strength 10 soft 0.1")
print("one", force(1, 0, 0, "x"))
op("field.set", "strength 30")
print("set", force(1, 0, 0, "x"))
op("object.duplicate")
move(active(), 5, 0, 0)
print("dup", active(), force(2.5, 0, 0, "x"))
op("anim.key", "field:A:strength 1 10 linear")
op("anim.key", "field:A:strength 101 50 linear")
frame(1)
k1 = force(-1, 0, 0, "x")
frame(51)
print("keyed", k1, force(-1, 0, 0, "x"))
op("file.save", "{bee}")
op("file.new")
print("new", force(-1, 0, 0, "x"))
op("file.open", "{bee}")
frame(51)
print("open", force(-1, 0, 0, "x"), objtype("A"))
''')
    one, st = vals(out, 'one'), vals(out, 'set')
    check(one and st and near(st[0], 3 * one[0]), 'field.set strength 30 triples the pull (%s, %s)' % (one, st))
    d = vals(out, 'dup')
    check(len(d) == 2 and d[0] == 'A.001' and abs(float(d[1])) < 1e-3,
          'a duplicate (A.001) keeps its settings: half way between the two, no pull (%s)' % d)
    k = vals(out, 'keyed')
    # at -1: A (keyed) and the duplicate at 5 (strength 30) both pull towards +x
    def at(sa):
        return sa / 1.01 ** 1.5 + 30 * 6 / 36.01 ** 1.5
    check(len(k) == 2 and near(k[0], at(10)) and near(k[1], at(30)),
          'field:A:strength keyed 10 at frame 1, 50 at 101 (linear): the pull follows (%s, want %.3f %.3f)'
          % (k, at(10), at(30)))
    nw, op_ = vals(out, 'new'), vals(out, 'open')
    check(len(nw) == 1 and near(nw[0], 0) and len(op_) == 2 and k and near(op_[0], k[1]) and op_[1] == 5,
          'saved and opened: the fields, their settings and the keyed strength come back (%s, %s)' % (nw, op_))


def a1_ui():
    print('-- A1: the menu and the panel (fake compositor) --')
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
    argv = sys.argv
    sys.argv = [argv[0], tempfile.mkdtemp(prefix='bee-fields-shots-')]
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    try:
        f.pump(1.0, until_frame=True)
        f.keymap(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'keymaps', 'us.xkb'))
        m = fakewl.Mcp(f)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
        f.enter(600, 300)
        f.move(600, 300)
        fakewl.props_tab(m, f, 'physics')
        ok = fakewl.menu_pick(f, m, 'Add', 'Force Field', 'Vortex')
        f.pump(0.3)
        a = q('print(active(), objtype(active()))').split()
        check(ok and a == ['Vortex', '5'], 'Add > Force Field > Vortex: a vortex field, active (%s)' % a)
        t = fakewl.wait_widget(f, m, 'field.type')
        check(t is not None and t.get('value') == 3, 'Properties > Physics: its Force Field section, Type Vortex (%s)'
              % (t and t.get('value')))
        x, y = fakewl.widget_xy(m, 'field.strength')
        f.click(x, y)
        f.mods(4); f.key(30); f.mods(0); f.type('9'); f.key(28); f.pump(0.3)
        s = q('print(force(2, 0, 0, "z"))').split()
        f.mods(4); f.key(44); f.mods(0); f.pump(0.3)          # Ctrl+Z
        u = q('print(force(2, 0, 0, "z"))').split()
        fall = (1 - (2 / 5) ** 2) ** 2                        # (smooth, radius 5)
        check(len(s) == 1 and near(float(s[0]), -9 * fall) and len(u) == 1 and near(float(u[0]), -5 * fall),
              'its Strength typed in the panel: 9 (the pull at 2 m: %s); Ctrl+Z: back to 5 (%s)' % (s, u))
        lift = fakewl.widget(m, 'field.lift') is not None
        fakewl.pick_enum(f, m, 'field.type', 0, 0)              # Attractor
        f.pump(0.3)
        law = fakewl.wait_widget(f, m, 'field.law')
        check(lift and law is not None and fakewl.widget(m, 'field.lift') is None,
              'the type picked in the panel: an attractor shows its pull law, not the vortex\'s lift')
        x, y = fakewl.widget_xy(m, 'physics.section.world')    # World: gravity off
        f.click(x, y); f.pump(0.3)
        g0 = q('print(force(50, 50, 50, "y"))').split()
        x, y = fakewl.widget_xy(m, 'physics.gravity_on')
        f.click(x, y); f.pump(0.3)
        g1 = q('print(force(50, 50, 50, "y"))').split()
        check(len(g0) == 1 and len(g1) == 1 and abs(float(g0[0]) + 9.81) < 0.01 and abs(float(g1[0])) < 0.01,
              'World > Gravity unticked: no gravity (space), the fields still pull (%s -> %s)'
              % (g0, g1))
        q('add("sphere", "Moon", 30, 0, 0)\nselect("Moon")\nop("rigid.add", "active sphere")')
        f.pump(0.3)
        for name in ('physics.section.world', 'physics.section.field'):
            w = fakewl.widget(m, name)
            if w:
                f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2); f.pump(0.2)
        at = fakewl.wait_widget(f, m, 'rigid.attracts')
        if at:
            f.click(at['x'] + at['w'] // 2, at['y'] + at['h'] // 2); f.pump(0.3)
        n = q('frame(3)\nprint(rbinfo(22))\nframe(1)').split()
        check(at is not None and n[:1] == ['1'], 'Properties > Physics > Attracts the others: the Moon pulls (%s attracting)' % n[:1])
        f.shot('a1_fields.png')
    finally:
        f.proc.kill()


def a2():
    print('-- A2: fields on everything --')
    out = run('''
delete("Cube")
op("rigid.world", "gravity 0 0 0")
field("attractor", "Sun", "strength 1000 soft 0.01")
add("sphere", "Ball", 10, 0, 0)
scale("Ball", 0.2)
select("Ball")
op("rigid.add", "active sphere velocity 0 0 -10")
lo = 100
hi = 0
t = clock()
for f in 2..1510 {
  if f % 5 == 0 {
    frame(f)
    x = get("Ball", "x")
    z = get("Ball", "z")
    r = sqrt(x*x + z*z)
    lo = min(lo, r)
    hi = max(hi, r)
  }
}
print("orbit", lo, hi, clock() - t)
''')
    o = vals(out, 'orbit')
    check(len(o) == 3 and o[0] > 9.9 and o[1] < 10.1,
          'a circular orbit (r 10 m, v 10 m/s, 10 orbits, gravity off): radius %.4f .. %.4f m (%.0f ms)'
          % tuple(o) if len(o) == 3 else 'orbit (%s)' % o)
    xs = {}
    for w in (0, 8):
        out = run(f'''
delete("Cube")
add("grid", "Sheet", 0, 3, 0)
select("Sheet")
op("cloth.add", "cloth")
op("cloth.pin", "below x -0.9")
field("wind", "W", "strength {w} gust 0")
frame(60)
print("x", evpos("Sheet", 10, "x"))
''')
        xs[w] = vals(out, 'x')
    check(xs[0] and xs[8] and xs[8][0] > xs[0][0] + 0.5,
          'a sheet hung by one edge blows out in an 8 m/s wind field (its free corner: x %s -> %s)' % (xs[0], xs[8]))
    out = run('''
delete("Cube")
op("rigid.world", "gravity 0 0 0")
field("wind", "W", "strength 4 gust 0 groups 1")
add("sphere", "A", 0, 0, 0)
select("A")
op("rigid.add", "active sphere")
add("sphere", "B", 0, 0, 5)
select("B")
op("rigid.add", "active sphere")
op("rigid.add", "group 1")
frame(25)
print("grp", get("A", "x"), get("B", "x"))
''')
    g = vals(out, 'grp')
    check(len(g) == 2 and abs(g[0]) < 1e-4 and g[1] > 1,
          'a field for collision group 1: that body is blown away, the other (group 0) stays (%s)' % g)
    out = run('''
delete("Cube")
add("cube", "Wall", 3, 2, 0)
scale("Wall", 0.2, 3, 3)
select("Wall")
op("rigid.add", "passive box")
field("zone", "Z", "strength 9.81 size 10")
rotate("Z", 0, 0, 1.5707963)
add("cube", "Box", 0, 2, 0)
scale("Box", 0.3)
select("Box")
op("rigid.add", "active box")
frame(60)
print("zone", get("Box", "x"), get("Box", "y"))
''')
    z = vals(out, 'zone')
    # turned a quarter round Z: its -Y points along +X, onto the wall
    check(len(z) == 2 and 2.4 < z[0] < 2.6 and abs(z[1] - 2) < 0.1,
          'a gravity zone whose down is +X: the box falls sideways and rests on the wall (x %s, y %s)'
          % tuple(z) if len(z) == 2 else 'zone (%s)' % z)


def a3():
    print('-- A3: bodies that attract each other --')
    out = run('''
delete("Cube")
op("rigid.world", "gravity 0 0 0")
add("sphere", "P", 5, 0, 0)
scale("P", 0.2)
select("P")
op("rigid.add", "active sphere mass 1000 attracts velocity 0 0 -7.0710678")
add("sphere", "Q", -5, 0, 0)
scale("Q", 0.2)
select("Q")
op("rigid.add", "active sphere mass 1000 attracts velocity 0 0 7.0710678")
lo = 100
hi = 0
cm = 0
for f in 2..480 {
  if f % 4 == 0 {
    frame(f)
    dx = get("P", "x") - get("Q", "x")
    dz = get("P", "z") - get("Q", "z")
    d = sqrt(dx*dx + dz*dz)
    lo = min(lo, d)
    hi = max(hi, d)
    c = abs(get("P", "x") + get("Q", "x")) + abs(get("P", "z") + get("Q", "z"))
    cm = max(cm, c)
  }
}
print("pair", lo, hi, cm, rbinfo(22))
''')
    p = vals(out, 'pair')
    check(len(p) == 4 and p[0] > 9.9 and p[1] < 10.1 and p[2] < 1e-3 and p[3] == 2,
          'two bodies that attract orbit their common centre (4.5 orbits): distance %.4f .. %.4f m, the centre '
          'moves %.1e m' % tuple(p[:3]) if len(p) == 4 else 'pair (%s)' % p)
    out = run(CLOUD)
    c = vals(out, 'cloud')
    sps = 120 / (c[1] / 1000) if len(c) == 4 and c[1] > 0 else 0
    check(len(c) == 4 and c[0] >= 5000 and sps >= 10 and c[3] > 0,
          '%d attracting bodies: %.0f steps a second (the tree and pulls %.2f ms a step); the bottom layer rises'
          % (c[0], sps, c[2]) if len(c) == 4 else 'cloud (%s)' % c)


def a4():
    print('-- A4: walk on a planet --')
    planet = '''
delete("Cube")
op("rigid.world", "gravity 0 0 0")
add("sphere", "Planet", 0, 0, 0)
scale("Planet", 20)
field("attractor", "Core", "strength 3924 soft 1")
'''
    st = 'print("%s", playinfo(1), playinfo(2), playinfo(3), playinfo(4), playinfo(16), playinfo(17), playinfo(18))\n'
    out = run(planet + 'op("play.start", "walk 0 21.7 0")\nplaylook(0, 0)\nplaystep(1, 0, 0, 0)\n' + st % 'start'
              + 'playstep(3.927, 1, 0, 0, 1)\n' + st % 'quarter'
              + 'playstep(3.927, 1, 0, 0, 1)\n' + st % 'half'
              + 'playstep(7.854, 1, 0, 0, 1)\n' + st % 'round')
    s, qu, h, r = (vals(out, k) for k in ('start', 'quarter', 'half', 'round'))
    ok = all(len(v) == 7 for v in (s, qu, h, r))
    check(ok and abs(s[1] - 20) < 0.05 and s[3] == 1 and near(s[5], 1),
          'play.start on top of a 20 m planet: it lands and stands, up +Y (%s)' % s)
    check(ok and abs(qu[2] + 20) < 0.5 and abs(qu[1]) < 0.5 and qu[3] == 1 and qu[6] < -0.99,
          'a quarter round (31 m forward): on its side, standing, up along -Z (%s)' % qu)
    check(ok and abs(h[1] + 20) < 0.05 and h[3] == 1 and h[5] < -0.99,
          'half way round: on the bottom, standing, up -Y (%s)' % h)
    d = math.dist(r[:3], s[:3]) if ok else 99
    check(ok and d < 1 and r[3] == 1 and r[5] > 0.99,
          'once round (126 m): back at its start (%.2f m off), up +Y again' % d)
    out = run(planet + '''
op("logic.new", "L")
op("logic.node", "L begin")
op("logic.node", "L set_strength")
op("logic.name", "L 2 4 Core")
op("tree.node_set", "L 2 2 2000")
op("tree.link", "L 1 2 1")
op("logic.node", "L tick")
op("logic.node", "L set_variable 0")
op("logic.node", "L field")
op("tree.node_set", "L 5 1 0 25 0")
op("tree.link", "L 3 4 1")
op("tree.link", "L 5 4 2")
op("logic.node", "L set_variable 1")
op("tree.link", "L 3 6 1")
op("tree.link", "L 5:1 6 2")
op("logic.attach", "L Planet")
b = force(0, 25, 0, "y")
op("play.start", "walk 0 21.7 0")
playstep(0.2, 0, 0, 0)
print("logic", b, force(0, 25, 0, "y"), logicvar("Planet", 0, 1), logicvar("Planet", 1, 0))
op("play.stop", "discard")
print("after", force(0, 25, 0, "y"))
''')
    lg, af = vals(out, 'logic'), vals(out, 'after')
    want = -2000 * 25 / (625 + 1) ** 1.5
    check(len(lg) == 4 and near(lg[1], want) and near(lg[2], want) and near(lg[3], -want) and af and near(af[0], lg[0]),
          'logic: Set Strength makes the Core 2000 in play (the pull at 25 m %s), the Field node reads it (Force y %s, '
          'Size %s); play.stop discard: back (%s)' % tuple((lg + [0] * 4)[1:4] + [af]))


def a5():
    print('-- A5: seeing the fields --')
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
    argv = sys.argv
    sys.argv = [argv[0], tempfile.mkdtemp(prefix='bee-fields-shots-')]
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    try:
        f.pump(1.0, until_frame=True)
        m = fakewl.Mcp(f)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
        f.enter(600, 300)
        f.move(600, 300)
        q('op("rigid.world", "gravity 0 0 0")')                # (the tornado's own pull)
        ok = fakewl.menu_pick(f, m, 'Add', 'Force Field', 'Tornado')
        f.pump(0.3)
        t = q('print(active(), objtype(active()), force(2, 0, 0, "z") < -1, force(2, 0, 0, "y") > 0, force(2, 0, 0, "x") < 0)').split()
        check(ok and t[:5] == ['Tornado', '5', '1', '1', '1'],
              'Add > Force Field > Tornado: a vortex that turns things round it, lifts them and pulls them in (%s)' % t[:5])
        fakewl.menu_pick(f, m, 'View', 'Force Field Arrows')
        f.pump(0.5)
        q('view(30, 35, 22, 0, 0, 0)')
        f.pump(0.5)
        a = q('print(fieldinfo(1), fieldinfo(3))').split()
        f.shot('a5_arrows.png')
        fakewl.menu_pick(f, m, 'View', 'Force Field Arrows')
        fakewl.menu_pick(f, m, 'View', 'Force Field Lines')
        q('move("Cube", 3, 0, 0)\nselect("Cube")')
        f.pump(0.5)
        l = q('print(fieldinfo(1), fieldinfo(2))').split()
        f.shot('a5_lines.png')
        check(len(a) >= 2 and int(a[0]) > 50 and float(a[1]) > 5 and len(l) >= 2 and l[0] == '0' and int(l[1]) > 500,
              'View > Force Field Arrows: %s arrows (the largest pull %s); Arrows off, Lines on: %s segments of '
              'streamlines from the selected cube' % (a[:1], a[1:2], l[1:2]))
        # the streamlines swirl: a point carried along the pull turns round the axis as it rises
        sw = q('''x = 3
y = 0
z = 0
a0 = 0
for i in 0..60 {
  fx = force(x, y, z, "x")
  fy = force(x, y, z, "y")
  fz = force(x, y, z, "z")
  s = sqrt(fx*fx + fy*fy + fz*fz)
  x = x + fx / s * 0.25
  y = y + fy / s * 0.25
  z = z + fz / s * 0.25
}
print(y, sqrt(x*x + z*z), x, z)''').split()
        check(len(sw) >= 4 and float(sw[0]) > 2 and float(sw[1]) < 3 and (float(sw[2]) < 2.5 or abs(float(sw[3])) > 0.5),
              'along a streamline from the cube: up (y %s), in (r %s) and round (x %s, z %s)' % tuple(sw[:4]))
    finally:
        f.proc.kill()
    out = run('''
delete("Cube")
p = field("planet")
print("planet", exists("Planet Core"), count(), objtype("Planet"), get("Planet", "sx"), force(0, 10, 0, "y"), force(0, 30, 0, "y"))
delete("Planet")
delete("Planet Core")
b = field("blackhole", "Hole")
move("Hole", 50, 0, 0)
print("hole", b, force(51, 0, 0, "x"), force(60, 0, 0, "x"))
w = field("breeze")
print("breeze", w, objtype(w))
''')
    pl, h, br = out and [l for l in out if l[0] == 'planet'], [l for l in out if l[0] == 'hole'], [l for l in out if l[0] == 'breeze']
    pl = pl[0] if pl else []
    check(len(pl) == 7 and pl[1] == '1' and pl[2] == '4' and pl[3] == '0' and pl[4] == '10'
          and near(float(pl[5]), -981 * 10 / 101 ** 1.5) and near(float(pl[6]), -981 * 30 / 901 ** 1.5),
          'field("planet"): a 10 m sphere (Planet) and its Planet Core: 9.7 m/s2 at the surface, the world\'s gravity off '
          '(%s)' % pl[1:])
    h = h[0] if h else []
    check(len(h) == 4 and float(h[2]) < -100 and h[3] == '0',
          'field("blackhole"): strong near (%s m/s2 at 1 m), nothing past 8 m (%s)' % tuple(h[2:4]) if len(h) == 4 else 'hole (%s)' % h)
    br = br[0] if br else []
    check(len(br) == 3 and br[1] == 'Breeze' and br[2] == '5', 'field("breeze"): a wind field (%s)' % br[1:])


if __name__ == '__main__':
    a1()
    a1_ui()
    a2()
    a3()
    a4()
    a5()
    print('FAILS', FAILS)
    sys.exit(1 if FAILS else 0)
