# Generates BeeScript chunks for the Coca-Cola commercial.
import math, os, random
random.seed(7)
FONT = {
 'C': ["01110","10001","10000","10000","10000","10001","01110"],
 'O': ["01110","10001","10001","10001","10001","10001","01110"],
 'A': ["01110","10001","10001","11111","10001","10001","10001"],
 'L': ["10000","10000","10000","10000","10000","10000","11111"],
 '-': ["00000","00000","00000","11111","00000","00000","00000"],
 'T': ["11111","00100","00100","00100","00100","00100","00100"],
 'S': ["01111","10000","10000","01110","00001","00001","11110"],
 'E': ["11111","10000","10000","11110","10000","10000","11111"],
 'H': ["10001","10001","10001","11111","10001","10001","10001"],
 'F': ["11111","10000","10000","11110","10000","10000","10000"],
 'I': ["11111","00100","00100","00100","00100","00100","11111"],
 'N': ["10001","11001","10101","10011","10001","10001","10001"],
 'G': ["01110","10001","10000","10111","10001","10001","01111"],
 ' ': ["00000"]*7,
}
def pixels(text, cell, cx, top):
    cols = len(text) * 6 - 1
    x0 = cx - cols * cell / 2
    out = []
    for ci, ch in enumerate(text):
        for r, row in enumerate(FONT[ch]):
            for c, bit in enumerate(row):
                if bit == '1':
                    out.append((ci, x0 + (ci * 6 + c + .5) * cell, top - (r + .5) * cell))
    return out

chunks = []
# ---------- 1: stage, materials, bottle ----------
setup = r'''
while count() > 0 { delete(name(0)) }
op("anim.range", "1 240 30")
fn mat(n, r, g, b, rough, metal) {
    m = material(n); matset(m, "base", r, g, b); matset(m, "roughness", rough); matset(m, "metallic", metal); return m
}
fn glow(n, r, g, b, s) { m = material(n); matset(m, "base", r, g, b); matset(m, "emission", r, g, b); matset(m, "strength", s); return m }
mat("Coke Red", 0.80, 0.0, 0.02, 0.25, 0)
glow("Backdrop", 0.55, 0.0, 0.015, 0.9)
mat("Floor", 0.10, 0.0, 0.008, 0.45, 0); matset("Floor", "specular", 0.15)
m = mat("Glass", 0.10, 0.025, 0.008, 0.03, 0); matset(m, "transmission", 0.55); matset(m, "ior", 1.5); matset(m, "clearcoat", 1)
m = mat("Label", 0.85, 0.0, 0.03, 0.35, 0); matset(m, "emission", 0.6, 0, 0.02); matset(m, "strength", 0.6)
mat("Cap", 0.75, 0.02, 0.03, 0.2, 1)
glow("White Glow", 1, 1, 1, 1.6)
glow("Logo", 1, 1, 1, 0)
glow("Tagline", 1, 0.9, 0.85, 0)
m = mat("Bubble", 0.9, 0.8, 0.7, 0.02, 0); matset(m, "transmission", 0.8); matset(m, "emission", 1, 0.85, 0.7); matset(m, "strength", 0.35)
m = mat("Ice", 0.55, 0.75, 0.95, 0.04, 0); matset(m, "transmission", 0.9); matset(m, "ior", 1.31); matset(m, "alpha", 0.6); matset(m, "clearcoat", 1)
glow("Gold Ring", 1, 0.75, 0.3, 0); matset("Gold Ring", "base", 0.05, 0.02, 0.0)

# stage
b = add("plane", "Backdrop", 0, 10, -7); scale(b, 60, 1, 30); rotate(b, 90deg, 0, 0); assign(b, "Backdrop")
f = add("plane", "Floor", 0, 0, 0); scale(f, 60, 1, 30); assign(f, "Floor")
add("light", "Key Light", 4, 7, 5)
add("light", "Rim Light", -5, 5, -3)
select("Key Light", "Rim Light"); op("object.hide")

# bottle: a Georgia-green contour, revolved
s = sketch("Bottle Profile", "XY")
fn bp(x, y) { return point(s, x, y) }
p1 = bp(0, 0); p2 = bp(0.30, 0); p3 = bp(0.36, 0.08); p4 = bp(0.34, 0.40); p5 = bp(0.28, 0.62)
p6 = bp(0.33, 0.86); p7 = bp(0.37, 1.12); p8 = bp(0.36, 1.32); p9 = bp(0.27, 1.62); p10 = bp(0.16, 1.95)
p11 = bp(0.13, 2.18); p12 = bp(0.15, 2.22); p13 = bp(0.15, 2.30); p14 = bp(0, 2.30)
line(s, p1, p2); line(s, p2, p3); line(s, p3, p4); line(s, p4, p5); line(s, p5, p6); line(s, p6, p7); line(s, p7, p8)
line(s, p8, p9); line(s, p9, p10); line(s, p10, p11); line(s, p11, p12); line(s, p12, p13); line(s, p13, p14); line(s, p14, p1)
revolve("Bottle", s, 360deg, "v")
select("Bottle Profile"); op("object.hide")
assign("Bottle", "Glass")
l = add("cylinder", "Label", 0, 1.0, 0); scale(l, 0.355, 0.11, 0.355); assign(l, "Label")
w = add("torus", "Label Wave", 0, 1.0, 0); scale(w, 0.37, 0.25, 0.37); rotate(w, 0.22, 0, 0.12); assign(w, "White Glow")
c = add("cylinder", "Cap", 0, 2.33, 0); scale(c, 0.165, 0.045, 0.165); assign(c, "Cap")
count()
'''
chunks.append(setup)

# ---------- 2: the bottle's entrance + hero turn ----------
anim = []
A = anim.append
for n in ["Bottle", "Label", "Label Wave", "Cap"]:
    y = {"Bottle": 0, "Label": 1.0, "Label Wave": 1.0, "Cap": 2.33}[n]
    A(f'key("{n}:y", 1, {y-3.2}); key("{n}:y", 40, {y+0.15}); key("{n}:y", 52, {y})')
    A(f'key("{n}:ry", 1, -6.283); key("{n}:ry", 52, 0); key("{n}:ry", 240, 1.2)')
# label wave wobbles
A('key("Label Wave:rz", 52, 0.12); key("Label Wave:rz", 120, -0.12); key("Label Wave:rz", 180, 0.12); key("Label Wave:rz", 240, -0.12)')
# backdrop breathes
A('key("material:Backdrop:strength", 1, 0.15); key("material:Backdrop:strength", 45, 1.1); key("material:Backdrop:strength", 200, 0.9); key("material:Backdrop:strength", 230, 1.4)')
chunks.append("\n".join(anim))

# ---------- 3: bubbles (rising, staggered) ----------
bub = []
for i in range(26):
    n = f"Bubble {i}"
    a = random.uniform(0, 2*math.pi); rad = random.uniform(0.0, 0.22)
    x, z = math.cos(a)*rad, math.sin(a)*rad
    size = random.uniform(0.025, 0.06)
    start = random.randint(50, 150); dur = random.randint(50, 90)
    bub.append(f'b = add("sphere", "{n}", {x:.3f}, -0.5, {z:.3f}); scale(b, {size:.3f}); assign(b, "Bubble")')
    bub.append(f'key("{n}:y", 1, -0.6, "constant"); key("{n}:y", {start}, 0.15, "linear"); key("{n}:y", {start+dur}, 2.0, "linear"); key("{n}:y", {start+dur+1}, -0.6, "constant")')
    bub.append(f'key("{n}:x", {start}, {x:.3f}); key("{n}:x", {start+dur}, {x*0.4 + random.uniform(-.05,.05):.3f})')
chunks.append("\n".join(bub))

# ---------- 4: ice cubes tumbling in + the ribbon swirl ----------
ice = []
spots = [(-1.1, 0.13, 0.7), (1.05, 0.13, 0.6), (-0.6, 0.13, 1.35), (0.7, 0.13, 1.3), (1.5, 0.13, -0.3), (-1.45, 0.13, -0.2)]
for i, (x, y, z) in enumerate(spots):
    n = f"Ice {i}"
    f0 = 58 + i * 6
    ice.append(f'c = add("cube", "{n}", {x}, 6, {z}); scale(c, 0.13); assign(c, "Ice")')
    ice.append(f'key("{n}:y", 1, 7, "constant"); key("{n}:y", {f0}, 7); key("{n}:y", {f0+14}, {y}); key("{n}:y", {f0+19}, {y+0.25}); key("{n}:y", {f0+24}, {y})')
    rx, ry = random.uniform(-3, 3), random.uniform(-3, 3)
    ice.append(f'key("{n}:rx", {f0}, {rx:.2f}); key("{n}:rx", {f0+24}, 0); key("{n}:ry", {f0}, {ry:.2f}); key("{n}:ry", {f0+24}, {random.uniform(-.6,.6):.2f})')
# ribbon: a white swoosh spiral around the bottle
ice.append('rb = curve("empty", "Ribbon")')
ice.append('op("curve.spline", "poly")')
N = 60
for k in range(N + 1):
    t = k / N
    ang = t * 2.4 * 2 * math.pi
    r = 0.65 + 0.35 * math.sin(t * math.pi)
    y = 0.2 + t * 2.4
    ice.append(f'op("curve.point", "{r*math.cos(ang):.3f} {y:.3f} {r*math.sin(ang):.3f}")')
ice.append('op("curve.set", "bevel 0.035"); op("curve.set", "sides 8")')
ice.append('assign("Ribbon", "White Glow")')
ice.append('key("Ribbon:sx", 1, 0.001, "constant"); key("Ribbon:sx", 62, 0.001); key("Ribbon:sx", 92, 1)')
ice.append('key("Ribbon:sz", 1, 0.001, "constant"); key("Ribbon:sz", 62, 0.001); key("Ribbon:sz", 92, 1)')
ice.append('key("Ribbon:sy", 1, 0.001, "constant"); key("Ribbon:sy", 62, 0.001); key("Ribbon:sy", 92, 1)')
ice.append('key("Ribbon:ry", 62, -3.0); key("Ribbon:ry", 92, 0); key("Ribbon:ry", 240, 2.5, "linear")')
chunks.append("\n".join(ice))

# ---------- 5: COCA-COLA letters fly in ----------
def letters(text, cell, top, z, prefix, mat, f_start, spread, words=False, X=0):
    out = []
    px = pixels(text, cell, X, top)
    depth = cell * 1.1
    if words:
        wid = []; w = 0
        for ch in text:
            if ch == ' ': w += 1
            wid.append(w)
        groups = []
        for wi in range(len(text.split())):
            idx = [i for i in range(len(text)) if wid[i] == wi and text[i] != ' ']
            parts = [[]]; budget = 0
            for i in idx:
                nr = sum(len([r for r in row.replace('0', ' ').split()]) for row in FONT[text[i]])
                if budget + nr > 26: parts.append([]); budget = 0
                parts[-1].append(i); budget += nr
            for p in parts: groups.append((len(groups), "".join(text[i] for i in p), p))
    else:
        groups = []
        for ci, ch in enumerate(text):
            if ch == '-': groups[-1] = (groups[-1][0], groups[-1][1] + ch, groups[-1][2] + [ci])
            else: groups.append((len(groups), ch, [ci]))
    for ci, ch, members in groups:
        pts = [(x, y) for (c, x, y) in px if c in members]
        if not pts: continue
        cx = sum(p[0] for p in pts) / len(pts); cy = top - 3.5 * cell
        n = f"{prefix} {ci+1} {ch}"
        sk = f"{prefix} Sketch {ci+1}"
        out.append(f's = sketch("{sk}", "XY", {-depth/2:.4f})')
        g = cell * 0.08
        rows = {}
        for (x, y) in pts: rows.setdefault(round(y, 5), []).append(x)
        for y, xs in rows.items():
            xs.sort(); run = [xs[0]]
            for x in xs[1:] + [None]:
                if x is not None and abs(x - run[-1] - cell) < 1e-6: run.append(x); continue
                w = (run[-1] - run[0]) + cell - 2*g
                out.append(f'rect(s, {run[0] - cx - cell/2 + g:.4f}, {y - cy - cell/2 + g:.4f}, {w:.4f}, {cell - 2*g:.4f})')
                if x is not None: run = [x]
        out.append(f'pad("{n}", s, {depth:.4f}); select(s); op("object.hide"); assign("{n}", "{mat}")')
        sx, sy, sz = random.uniform(-6, 6), random.uniform(0, 8), random.uniform(2, 7)
        f0 = f_start + ci * spread + random.randint(0, 3)
        f1 = f0 + 26
        out.append(f'key("{n}:x", 1, {sx:.2f}, "constant"); key("{n}:x", {f0}, {sx:.2f}); key("{n}:x", {f1}, {cx:.3f})')
        out.append(f'key("{n}:y", 1, {sy:.2f}, "constant"); key("{n}:y", {f0}, {sy:.2f}); key("{n}:y", {f1}, {cy:.3f})')
        out.append(f'key("{n}:z", 1, {sz:.2f}, "constant"); key("{n}:z", {f0}, {sz:.2f}); key("{n}:z", {f1}, {z})')
        out.append(f'key("{n}:rx", {f0}, {random.uniform(-7,7):.2f}); key("{n}:rx", {f1}, 0); key("{n}:ry", {f0}, {random.uniform(-7,7):.2f}); key("{n}:ry", {f1}, 0)')
        for a in "xyz":
            out.append(f'key("{n}:s{a}", 1, 0.001, "constant"); key("{n}:s{a}", {f0}, 0.001); key("{n}:s{a}", {f0+6}, 1.25); key("{n}:s{a}", {f1}, 1)')
    return out
logo = letters("COCA-COLA", 0.085, 3.85, 0, "Logo", "Logo", 96, 4)
logo.append('key("material:Logo:strength", 95, 0.2); key("material:Logo:strength", 140, 1.4); key("material:Logo:strength", 150, 4); key("material:Logo:strength", 165, 1.6)')
logo.append('key("material:Logo:strength", 210, 1.6); key("material:Logo:strength", 222, 4.5); key("material:Logo:strength", 240, 1.6)')
chunks.append(logo)
tag = letters("TASTE THE FEELING", 0.045, 3.12, 0.05, "Tag", "Tagline", 150, 8, words=True)
tag.append('key("material:Tagline:strength", 149, 0); key("material:Tagline:strength", 175, 1.5); key("material:Tagline:strength", 222, 3); key("material:Tagline:strength", 240, 1.5)')
chunks.append(tag)

# split list chunks under ~55 KB
final = []
for ch in chunks:
    if isinstance(ch, str):
        final.append(ch); continue
    cur = []
    for line in ch:
        cur.append(line)
        if sum(len(l)+1 for l in cur) > 50000:
            final.append("\n".join(cur)); cur = []
    if cur: final.append("\n".join(cur))
final.append('frame(1)\nselect()\nview(0, 6, 9.0, 0, 1.95, 0)\ncount()')
for i, ch in enumerate(final):
    open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", f"chunk{i:02d}.bees"), "w").write(ch)
    print(i, len(ch))
