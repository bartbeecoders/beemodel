#!/usr/bin/env python3
"""The optional GPU helper (beemodel-gpu, v0.12): path tracing and the
virtualized-geometry rasterizer offloaded to Vulkan, with automatic fallback
to the CPU paths and the same images.

  * Without the helper, or with BEEMODEL_GPU=off, nothing changes: the CPU
    renders and gpu(0) is 0.
  * The path tracer on the GPU (pt.comp, a port of hive_pt.s with the same
    random streams) against the CPU at 64 samples: the default scene and
    one with metal, glass, clearcoat, an emissive panel, a point light and
    vertex colours; the denoised render (the aux passes) too.
  * The helper dying mid-render (BEEMODEL_GPU_FAIL=2): the render finishes
    on the CPU, and the image is still the CPU's.
  * Shader graphs (v0.13): a textured, bumped, normal-mapped and masked
    scene on the GPU (the ptg kernel) against the CPU; a graph with a node
    pt.comp does not evaluate stays on the CPU.
  * The rasterizer: a window (the fake compositor) showing a mesh drawn
    through its cluster DAG, with the tile stage on the GPU, against the
    same frame on the CPU.
  * Rendered shading (the live viewport, src/live.s): a raycast a frame while
    the view moves, path-traced samples when it is still, the scene going up
    again when it changes (not when only the camera does), the selection
    outline over it, raycast alone with 0 samples, the denoiser, an F12
    render beside it,
    and Material Preview without the helper or when it dies.
  * Particles (v0.22): 100k leaves instanced on particles and tinted balls,
    the GPU's render against the CPU's.

With no usable Vulkan device the GPU checks are skipped (--require fails
instead: CI runs it on llvmpipe with BEEMODEL_GPU=any).

    python3 tests/gpu.py build/beemodel [shots dir] [--require]
"""
import os, subprocess, sys, tempfile, time

ARGS = [a for a in sys.argv[1:] if not a.startswith('--')]
REQUIRE = '--require' in sys.argv
BIN = os.path.abspath(ARGS[0] if ARGS else 'build/beemodel')
OUT = ARGS[1] if len(ARGS) > 1 else None
HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(os.path.dirname(BIN), 'beemodel-gpu')
HOME = tempfile.mkdtemp(prefix='bee-gpu-')
FAILS = []

SCENE = '''delete("Cube")
f = add("plane", "Floor", 0, -1, 0)
scale(f, 6, 1, 6)
m = material("Metal")
matset(m, "base", 0.9, 0.6, 0.3)
matset(m, "metallic", 1)
matset(m, "roughness", 0.25)
s = add("sphere", "Ball", -1.2, 0, 0)
assign(s, m)
g = material("Glass")
matset(g, "transmission", 1)
matset(g, "roughness", 0.05)
matset(g, "ior", 1.5)
t = add("torus", "Ring", 1.2, 0, 0)
assign(t, g)
c = material("Coat")
matset(c, "base", 0.1, 0.3, 0.8)
matset(c, "clearcoat", 1)
matset(c, "coat_roughness", 0.1)
k = add("cube", "Box", 0, 0, -1.5)
assign(k, c)
e = material("Lamp")
matset(e, "emission", 1, 0.8, 0.5)
matset(e, "strength", 5)
p = add("plane", "Panel", 0, 2, 0)
assign(p, e)
add("light", "Bulb", 2, 2, 2)
v = add("sphere", "Painted", 0, 0, 1.5)
vpaint(v, 0, 0, 2.5, 1.2, 1, 0, 0)
'''


def graph_scene():
    """A textured, bumped, normal-mapped and masked scene (shader graphs):
    the floor samples an image through its UVs, a noise bumps it and a
    checker sets its roughness; a ball wears a normal map; a one-sided
    panel is cut out by a checker mask."""
    from PIL import Image
    alb = os.path.join(HOME, 'albedo.png')
    im = Image.new('RGB', (64, 64))
    im.putdata([((x * 4) % 256, (y * 4) % 256, ((x ^ y) * 8) % 256) for y in range(64) for x in range(64)])
    im.save(alb)
    nrm = os.path.join(HOME, 'normal.png')
    im = Image.new('RGB', (32, 32))
    im.putdata([(128 + int(60 * ((x % 8) - 3.5) / 3.5), 128 + int(60 * ((y % 8) - 3.5) / 3.5), 230) for y in range(32) for x in range(32)])
    im.save(nrm)
    return f'''delete("Cube")
f = add("plane", "Floor", 0, -1, 0)
scale(f, 6, 1, 6)
unwrap(f)
m = material("Tex")
t = node(m, "texcoord", 3, 3)
i = image("{alb}")
s = node(m, "image", i)
link(m, t, s, 1)
socket(m, "base", s)
n = node(m, "noise", 6, 3, 0.5)
b = node(m, "bump", 0.6, 0.05)
link(m, n, b, 1)
socket(m, "normal", b)
c = node(m, "checker", 4)
nodeset(m, c, 1, 0.2)
nodeset(m, c, 2, 0.7)
socket(m, "roughness", c)
assign(f, m)
g = add("sphere", "Ball", -1, 0, 0)
unwrap(g, "smart")
nm = material("Bumpy")
matset(nm, "base", 0.7, 0.5, 0.3)
j = image("{nrm}")
ns = node(nm, "image", j, 1, 1)
mp = node(nm, "normalmap", 1)
link(nm, ns, mp, 1)
socket(nm, "normal", mp)
assign(g, nm)
p = add("plane", "Leaf", 1, 0.2, 0)
rotate(p, rad(90), 0, 0)
lm = material("Leaf")
matset(lm, "base", 0.2, 0.6, 0.2)
matset(lm, "blend", 1)
matset(lm, "one_sided", 1)
k = node(lm, "checker", 3)
nodeset(lm, k, 1, 0)
nodeset(lm, k, 2, 1)
socket(lm, "mask", k)
assign(p, lm)
add("light", "Bulb", 2, 2, 2)
'''


def write_hdr(path, w=256, h=128):
    """A Radiance RGBE world: a sky gradient, a dark ground and a small sun."""
    import math
    def rgbe(r, g, b):
        m = max(r, g, b)
        if m < 1e-32:
            return bytes(4)
        e = math.frexp(m)[1]
        f = math.ldexp(1.0, -e) * 256
        return bytes([int(r * f), int(g * f), int(b * f), e + 128])
    out = bytearray(b'#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y %d +X %d\n' % (h, w))
    for y in range(h):
        th = (y + 0.5) / h * math.pi
        for x in range(w):
            sky = max(math.cos(th), 0)
            r, g, b = (0.2 + 0.3 * sky, 0.25 + 0.4 * sky, 0.3 + 0.7 * sky) if th <= math.pi / 2 else (0.15, 0.12, 0.1)
            if (x - 60) ** 2 + (y - 30) ** 2 < 9:
                r, g, b = 500, 450, 380
            out += rgbe(r, g, b)
    open(path, 'wb').write(out)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code, **env):
    e = dict(os.environ, HOME=HOME, XDG_CACHE_HOME='')
    for k in ('BEEMODEL_GPU', 'BEEMODEL_GPU_HELPER', 'BEEMODEL_GPU_FAIL', 'BEEMODEL_GPU_RASTER'):
        e.pop(k, None)
    e.update(env)
    r = subprocess.run([BIN, '--eval', code], env=e, capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
    out = {}
    for line in r.stdout.splitlines():
        w = line.split()
        if w:
            out[w[0]] = w[1:]
    return out


def pixels(img):
    return list(img.get_flattened_data() if hasattr(img, 'get_flattened_data') else img.getdata())


def compare(a, b):
    """(mean absolute difference in levels, share of identical pixels)"""
    from PIL import Image
    pa = pixels(Image.open(a).convert('RGB'))
    pb = pixels(Image.open(b).convert('RGB'))
    if len(pa) != len(pb):
        return 255.0, 0.0
    d = sum(abs(x - y) for p, q in zip(pa, pb) for x, y in zip(p, q))
    return d / (3 * len(pa)), sum(1 for p, q in zip(pa, pb) if p == q) / len(pa)


def render(name, scene, spp, denoise=0, **env):
    path = os.path.join(HOME, name + '.png')
    code = scene + 'op("render.image", "%s 240 180 %d %d")\nprint("gpu", gpu(0), gpu(2), gpu(4))\n' % (
        path, spp, denoise)
    r = run(code, **env)
    return path, [int(float(x)) for x in r.get('gpu', ['-1', '-1', '-1'])]


def main():
    print('  -- GPU helper --')
    # ---- fallbacks ---------------------------------------------------------------
    cpu, g = render('none', '', 16, BEEMODEL_GPU_HELPER='/nonexistent/beemodel-gpu', BEEMODEL_GPU='any')
    check(os.path.exists(cpu) and g[0] == 0, f'no helper: the CPU renders, gpu(0) = 0 ({g})')
    # ---- the BVH built on every thread (H7): the same tree as on one ----------------
    pb = ('emit("Cube", "from volume burst 100000 speed 3 life 100 size 0.02 gravity 0 color 40a0ff")\nframe(4)\n'
          'op("render.device", "cpu")\n')
    imgs = []
    for t in ('0', '3'):
        p = os.path.join(HOME, 'bvh_t%s.png' % t)
        r = run(pb + 'op("render.image", "%s 96 72 2 0")\nprint("bvh", gpu(16), gpu(19))\n' % p, BEEMODEL_THREADS=t)
        imgs.append((p, r.get('bvh')))
    ok = all(os.path.exists(p) for p, _ in imgs) and compare(imgs[0][0], imgs[1][0]) == (0.0, 1.0)
    # ---- objects' BVHs kept between renders (H8): never stale ----------------------
    base = ('op("render.device", "cpu")\nadd("sphere", "S", 2, 1, 0)\nadd("plane", "P", 0, 0, 0)\nscale("P", 6)\n'
            'm = material("Red")\nmatset(m, "base", 0.8, 0.1, 0.1)\nn = material("Gold")\n'
            'matset(n, "base", 0.9, 0.7, 0.2)\nmatset(n, "metallic", 1)\nassign("S", "Red")\n')
    steps = [('moved', 'move("Cube", 1, 0.5, -1)\n'), ('material', 'assign("S", "Gold")\n'),
             ('mesh', 'modifier("S", "subsurf")\n'), ('deleted', 'delete("P")\n')]
    code = base + ''.join('op("render.image", "%s/k%d.png 96 72 2 0")\nprint("warm%d", gpu(20))\n' % (HOME, i, i)
                          for i in range(3))
    done = ''
    for name, step in steps:
        done += step
        code += step + 'op("render.image", "%s/kept_%s.png 96 72 2 0")\nprint("%s", gpu(20))\n' % (HOME, name, name)
    r = run(code)
    hits = [r.get('warm2'), *(r.get(n) for n, _ in steps)]
    same = []
    done = ''
    for i, (name, step) in enumerate(steps):           # (a fresh process, its renders
        done += step                                    #  as many: each one's seed is
        f = os.path.join(HOME, 'fresh_%s.png' % name)   #  the next)
        run(base + done + 'for k in 0..%d { op("render.image", "%s/w.png 8 6 1 0") }\n' % (3 + i, HOME)
            + 'op("render.image", "%s 96 72 2 0")\n' % f)
        same.append(os.path.exists(f) and compare(os.path.join(HOME, 'kept_%s.png' % name), f) == (0.0, 1.0))
    check(hits[0] == ['3'] and all(same), f'objects kept between renders (3 on the third: {hits[0]}; then '
                                           f'{[h[0] if h else None for h in hits[1:]]}): after a move, a material, a '
                                           f'modifier and a deletion, each image is a fresh render\'s ({same})')
    check(ok and imgs[0][1][1] == '100000', f'100k balls: the BVH built on 4 threads gives the image one thread '
                                            f'does (BVH ms on 1 and 4 threads: {imgs[0][1][0]}, {imgs[1][1][0]})')
    if not os.path.exists(HELPER):
        print(f'  skip the GPU checks: {HELPER} was not built (needs cc and libvulkan.so.1)')
        if REQUIRE:
            FAILS.append('the helper was not built')
        return finish()
    off, g = render('off', '', 16, BEEMODEL_GPU='off')
    check(g[0] == 0 and compare(cpu, off)[0] == 0,
          f'BEEMODEL_GPU=off: the helper is never started, the same image ({g})')
    r = run('print("dev", gpu(0), gpu(1))\n', BEEMODEL_GPU='any')
    dev = r.get('dev', ['0', '0'])
    if dev[0] != '1':
        print('  skip the GPU checks: no usable Vulkan device (compute with 64-bit integers)')
        if REQUIRE:
            FAILS.append('no Vulkan device')
        return finish()
    kinds = {'1': 'integrated GPU', '2': 'discrete GPU', '3': 'virtual GPU', '4': 'CPU (llvmpipe)'}
    print(f'  Vulkan device: {kinds.get(dev[1], dev[1])}')
    if dev[1] == '4':
        r = run('print("dev", gpu(0))\n')
        check(r.get('dev') == ['0'], f'a CPU Vulkan device is used only with BEEMODEL_GPU=any ({r.get("dev")})')

    # ---- the path tracer -----------------------------------------------------------
    for name, scene in (('default', ''), ('materials', SCENE)):
        c, gc = render(name + '_cpu', scene, 64, BEEMODEL_GPU='off')
        p, gp = render(name + '_gpu', scene, 64, BEEMODEL_GPU='any')
        mad, same = compare(c, p)
        check(gp[0] == 1 and gp[2] == 64 and gp[1] >= 1 and mad < 0.25 and same > 0.97,
              f'path tracing, {name} scene: all 64 samples on the GPU ({gp[1]} runs), the CPU\'s image '
              f'(mean difference {mad:.4f} levels, {100 * same:.2f}% of pixels identical)')
    gs = graph_scene()                                  # shader graphs (M10)
    c, gc = render('graphs_cpu', gs, 64, BEEMODEL_GPU='off')
    p, gp = render('graphs_gpu', gs, 64, BEEMODEL_GPU='any')
    mad, same = compare(c, p)
    check(gp[0] == 1 and gp[2] == 64 and mad < 0.5 and same > 0.9,
          f'path tracing a textured, bumped, normal-mapped and masked scene (shader graphs) on the GPU: the CPU\'s '
          f'image (mean difference {mad:.4f} levels, {100 * same:.2f}% of pixels identical, {gp[2]} GPU samples)')
    vs = 'm = material("V")\nv = node(m, "voronoi", 5)\nsocket(m, "base", v)\nassign("Cube", m)\n'
    c, _ = render('vor_cpu', vs, 16, BEEMODEL_GPU='off')
    p, gp = render('vor_gpu', vs, 16, BEEMODEL_GPU='any')
    check(gp[2] == 0 and compare(c, p)[0] == 0,
          f'a graph with a node the GPU does not evaluate (Voronoi): the CPU renders it, the same image ({gp})')
    # ---- the render device and why a render is where it is (H1) -----------------
    r = run('op("render.device", "cpu")\nop("render.image", "%s/d1.png 64 48 4 0")\nprint("cpu", gpu(18), gpu(6))\n'
            'op("render.device", "gpu")\nop("render.image", "%s/d2.png 64 48 4 0")\nprint("gpu", gpu(18), gpu(6))\n'
            'print("build", gpu(15), gpu(16), gpu(17))\n'
            'op("render.device", "auto")\nop("create.ground")\nop("render.image", "%s/d3.png 64 48 4 0")\n'
            'print("ground", gpu(18))\n' % (HOME, HOME, HOME), BEEMODEL_GPU='any')
    b = [float(x) for x in r.get('build', ['-1', '-1', '-1'])]
    check(r.get('cpu') == ['1', '0'] and r.get('gpu') == ['0', '1'],
          f'render.device cpu: on the CPU, why 1 ({r.get("cpu")}); gpu: on the GPU, why 0 ({r.get("gpu")})')
    check(len(b) == 3 and b[0] >= b[1] >= 0 and b[2] == 12,
          f'gpu(15..17): the scene build\'s ms, its BVH\'s, its triangles (the cube: 12) ({b})')
    check(r.get('ground') == ['0'], f'a shadow catcher (the Ground) renders on the GPU ({r.get("ground")})')
    gs2 = 'op("create.ground")\nadd("sphere", "S", 2, 1, 0)\n'      # (H2: the film's alpha)
    c, _ = render('catch_cpu', gs2, 64, BEEMODEL_GPU='off')
    p, gp = render('catch_gpu', gs2, 64, BEEMODEL_GPU='any')
    from PIL import Image
    ca = [q[3] for q in pixels(Image.open(c).convert('RGBA'))]
    pa = [q[3] for q in pixels(Image.open(p).convert('RGBA'))]
    amad = sum(abs(x - y) for x, y in zip(ca, pa)) / max(len(ca), 1)
    mad, same = compare(c, p)
    check(gp[2] == 64 and mad < 0.25 and amad < 0.25 and min(pa) == 0 and max(pa) == 255,
          f'a shadow catcher on the GPU: the CPU\'s colour (mean difference {mad:.4f}) and alpha (shadows on a '
          f'clear film, mean difference {amad:.4f})')

    # ---- an HDRI world (H3): a Radiance .hdr with a small, bright sun -------------
    hdr = os.path.join(HOME, 'world.hdr')
    write_hdr(hdr)
    ws = ('sky = image("%s")\nop("world.hdri", sky)\nop("world.rotation", "30")\nop("world.strength", "1.5")\n'
          'add("sphere", "S", 2, 1, 0)\nm = material("Chrome")\nmatset(m, "metallic", 1)\nmatset(m, "roughness", 0.1)\n'
          'assign("S", "Chrome")\nadd("plane", "P", 0, 0, 0)\nscale("P", 6)\n' % hdr)
    c, _ = render('hdri_cpu', ws, 64, BEEMODEL_GPU='off')
    p, gp = render('hdri_gpu', ws, 64, BEEMODEL_GPU='any')
    mad, same = compare(c, p)
    r = run(ws + 'op("render.image", "%s/h.png 32 24 1 0")\nprint("why", gpu(18))\n' % HOME, BEEMODEL_GPU='any')
    check(gp[2] == 64 and r.get('why') == ['0'] and mad < 0.25 and same > 0.97,
          f'an HDRI world on the GPU (its texels, the importance-sampling CDF, MIS): the CPU\'s image (mean '
          f'difference {mad:.4f} levels, {100 * same:.2f}% of pixels identical; why {r.get("why")})')

    # ---- the Vertex Color node (H4): particles glowing in their own colours ---------
    vc = ('m = material("Glow")\nmatset(m, "base", 0, 0, 0)\nc = node(m, "vcolor")\nsocket(m, "emission", c)\n'
          'matset(m, "strength", 4)\nassign("Cube", "Glow")\n'
          'emit("Cube", "from faces burst 3000 speed 2 size 0.06 gravity 0 color ff3020 color_end 20ff80 life 3")\n'
          'frame(30)\n')
    c, _ = render('vcol_cpu', vc, 32, BEEMODEL_GPU='off')
    p, gp = render('vcol_gpu', vc, 32, BEEMODEL_GPU='any')
    mad, same = compare(c, p)
    check(gp[2] == 32 and mad < 0.25 and same > 0.97,
          f'a graph with the Vertex Color node (particles\' colours as emission) on the GPU: the CPU\'s image '
          f'(mean difference {mad:.4f} levels, {100 * same:.2f}% of pixels identical)')

    c, _ = render('den_cpu', SCENE, 32, 1, BEEMODEL_GPU='off')
    p, gp = render('den_gpu', SCENE, 32, 1, BEEMODEL_GPU='any')
    mad, same = compare(c, p)
    check(gp[2] == 32 and mad < 0.5, f'denoised (albedo and normal passes from the GPU): the CPU\'s image '
                                     f'(mean difference {mad:.4f})')

    # ---- particles (v0.22): 100k instanced leaves and tinted balls ----------------
    ps = ('add("plane", "Leaf", 0, -20, 0)\nscale("Leaf", 0.5, 1, 0.3)\nm = material("Green")\n'
          'matset(m, "base", 0.2, 0.7, 0.2)\nassign("Leaf", m)\nadd("sphere", "Tree", 0, 3, 0)\n'
          'emit("Tree", "from volume burst 100000 speed 0.3 gravity 0 life 100 size 0.25 objects Leaf")\n'
          'emit("Cube", "from faces burst 2000 speed 1 life 100 size 0.1 gravity 0 color ff4010")\nframe(5)\n')
    c, _ = render('leaves_cpu', ps, 16, BEEMODEL_GPU='off')
    p, gp = render('leaves_gpu', ps, 16, BEEMODEL_GPU='any')
    mad, same = compare(c, p)
    check(gp[2] == 16 and mad < 0.25 and same > 0.97,
          f'particles: 100k leaves instanced on particles and 2000 tinted balls on the GPU, the CPU\'s image '
          f'(mean difference {mad:.4f} levels, {100 * same:.2f}% of pixels identical)')

    # ---- particles as analytic spheres (H6): a ball is one primitive, no triangles ----
    bs = 'emit("Cube", "from faces burst 2000 speed 1 life 100 size 0.1 gravity 0 color ff4010")\nframe(5)\n'
    r = run(bs + 'op("render.image", "%s/b.png 64 48 4 0")\nprint("prims", gpu(17), gpu(19))\n' % HOME,
            BEEMODEL_GPU='any')
    check(r.get('prims') == ['12', '2000'], f'2000 balls: 2000 spheres, no triangles (the cube\'s 12) '
                                            f'({r.get("prims")})')

    # ---- an empty scene after a full one (the last scene's arrays are gone) ----------
    e1 = os.path.join(HOME, 'empty1.png'); e2 = os.path.join(HOME, 'empty2.png')
    r = run(SCENE + 'op("render.image", "%s 64 48 4 0")\n'
            'n = count()\nfor i in 0..n {\n j = n - 1 - i\n if objtype(name(j)) == 0 { delete(name(j)) }\n}\nm = 0\nfor i in 0..count() {\n if objtype(name(i)) == 0 { m = m + 1 }\n}\nprint("meshes", m)\n'
            'for k in 0..3 { op("render.image", "%s 64 48 4 0") }\n'
            'print("empty", gpu(0))\n' % (e1, e2), BEEMODEL_GPU='any')
    check(r.get('empty') == ['1'] and r.get('meshes') == ['0'] and os.path.exists(e2),
          f'a scene emptied after a render (no meshes left) renders on the GPU, three times ({r.get("meshes")})')

    # ---- the scene kept on the GPU between renders (H9): only what changed goes up --
    gb = base.replace('op("render.device", "cpu")\n', '')
    gsteps = steps[:3] + [('balls', 'emit("Cube", "from faces burst 500 speed 1 life 100 size 0.1 gravity 0 '
                                     'color ff4010")\nframe(3)\n'), steps[3], ('bigger', '')]
    size = lambda name: '128 96' if name == 'bigger' else '96 72'
    code = gb + ''.join('op("render.image", "%s/u%d.png 96 72 2 0")\nprint("up%d", gpu(21), gpu(18))\n'
                        % (HOME, i, i) for i in range(3))
    for name, step in gsteps:
        code += step + 'op("render.image", "%s/gk_%s.png %s 2 0")\nprint("%s", gpu(21), gpu(18))\n' % (
            HOME, name, size(name), name)
    r = run(code, BEEMODEL_GPU='any')
    up = [int(r.get('up%d' % i, ['-1'])[0]) for i in range(3)] + [int(r.get(n, ['-1'])[0]) for n, _ in gsteps]
    where = {r.get(n, ['-', '-'])[1] for n, _ in gsteps} | {r.get('up%d' % i, ['-', '-'])[1] for i in range(3)}
    same = []
    done = ''
    for i, (name, step) in enumerate(gsteps):          # (a fresh process: everything up;
        done += step                                    #  as many renders before it, on
        f = os.path.join(HOME, 'gfresh_%s.png' % name)  #  the CPU, for the seed)
        run(gb + done + 'op("render.device", "cpu")\nfor k in 0..%d { op("render.image", "%s/w.png 8 6 1 0") }\n'
            'op("render.device", "auto")\nop("render.image", "%s %s 2 0")\n' % (3 + i, HOME, f, size(name)),
            BEEMODEL_GPU='any')
        same.append(os.path.exists(f) and compare(os.path.join(HOME, 'gk_%s.png' % name), f) == (0.0, 1.0))
    check(where == {'0'} and all(same) and up[0] > 0 and up[1] <= 8 and up[2] <= 8 and up[3] < up[0] // 2
          and up[4] <= 16, f'the scene stays on the GPU: the same scene again sends {up[1]} and {up[2]} KiB (the '
          f'first {up[0]}), a move {up[3]}, a material {up[4]}; after them, a modifier, 500 balls, a deletion and '
          f'a bigger image ({up[5:]} KiB) each image is a fresh process\'s ({same})')

    # ---- the helper dying ------------------------------------------------------------
    c, _ = render('materials_cpu', SCENE, 64, BEEMODEL_GPU='off')
    p, gp = render('fail', SCENE, 64, BEEMODEL_GPU='any', BEEMODEL_GPU_FAIL='2')
    mad, same = compare(c, p)
    check(os.path.exists(p) and gp[0] == 0 and gp[1] == 1 and gp[2] == 16 and mad < 0.25,
          f'the helper dies at its second run: the render goes on on the CPU ({gp[2]} of 64 samples '
          f'were the GPU\'s), the same image (mean difference {mad:.4f})')

    # ---- the rasterizer -----------------------------------------------------------
    frames = {}
    for mode in ('off', 'any'):
        frames[mode] = window(mode)
    a, b = frames['off'], frames['any']
    if a and b:
        box = (214, 80, 1014, 620)                      # the viewport (the console differs:
        pa = pixels(a[0].crop(box))                     #  it names the device)
        pb = pixels(b[0].crop(box))
        diff = sum(1 for p, q in zip(pa, pb) if p != q)
        share = diff / len(pa)
        check(b[1] > 0 and share < 0.001,
              f'the viewport through a cluster DAG, tiles rasterized on the GPU ({b[1]} batches): the CPU\'s '
              f'frame ({diff} pixels differ)')
    else:
        check(False, 'the window frames')
    live_view()
    prewarm()
    return finish()


BOX = (214, 80, 1014, 620)                              # the viewport


def fake(**env):
    """The fake compositor with BeeModel in it (these GPU variables)."""
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-gpu-shots-')]
    import fakewl
    sys.argv = argv
    keys = ('BEEMODEL_GPU', 'BEEMODEL_GPU_HELPER', 'BEEMODEL_GPU_FAIL')
    saved = {k: os.environ.get(k) for k in keys}
    for k in keys:
        os.environ.pop(k, None)
    os.environ.update(env)
    try:
        f = fakewl.Fake()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    f.pump(1.0, until_frame=True)
    m = fakewl.Mcp(f)
    return f, m, (lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip())


def prewarm():
    """H5: the window starts the helper in the background (and has it make the
    shader graphs' kernel), so a render a few seconds later finds it ready."""
    f, m, q = fake(BEEMODEL_GPU='any')
    try:
        f.pump(6.0)
        r = q('t = clock()\nr = gpu(0)\nprint("ready", r, clock() - t)').split()
        ok = len(r) == 3 and r[1] == '1' and float(r[2]) < 100
        check(ok, f'the window starts the helper meanwhile: ready {r[2:] if len(r) == 3 else r} ms after 6 s '
                  f'(a cold start takes seconds)')
    finally:
        f.proc.kill()


def live_view():
    print('  -- Rendered shading (the live viewport) --')
    f, m, q = fake(BEEMODEL_GPU='any')
    try:
        g = lambda *ks: [int(float(x)) for x in q('print(%s)' % ', '.join('gpu(%d)' % k for k in ks)).split()]
        def settle(want, secs=60):                      # samples in the image (no answer:
            t = time.time()                             #  still busy, the scene going up
            while time.time() - t < secs and (g(8) or [-1])[0] < want:  # to a slow device)
                f.pump(0.2)
            f.pump(0.3)
        q(SCENE + 'view(30, 20, 9, 0, 0, 0)\nop("view.shading_material")')
        f.pump(0.5)
        prev = f.image().crop(BOX)
        q('op("view.rendered_samples", "32")\nop("view.shading_rendered")')
        settle(32, 180)
        st = g(7, 8, 9, 10)
        still = f.image().crop(BOX)
        if OUT:
            f.shot('gpu_live_still.png')
        mad = compare_img(prev, still)
        check(st == [1, 32, 1, 1] and mad > 5,
              f'Rendered: the scene up once, a raycast, then 32 path-traced samples on the GPU ({st}), '
              f'not Material Preview (mean difference {mad:.1f} levels)')
        outl = ((0xe0, 0x86, 0x2a), (0xff, 0xc2, 0x4a))   # selected, active (const.inc)
        sel = sum(1 for p in pixels(still) if any(max(abs(a - b) for a, b in zip(p, c)) < 6 for c in outl))
        check(sel > 50, f'the selection outline is drawn over the render ({sel} pixels)')
        q('view(60, 25, 9, 0, 0, 0)')                   # the camera moves: a raycast
        st = g(7, 9)
        ray = None
        q('op("view.rendered_samples", "0")\nview(61, 25, 9, 0, 0, 0)')
        f.pump(0.5)
        st2 = g(7, 8, 9)
        ray = f.image().crop(BOX)
        if OUT:
            f.shot('gpu_live_raycast.png')
        n0 = f.frames
        f.pump(1.0)
        check(st[0] >= 2 and st[1] == 1 and st2[1] == 0 and st2[2] == 1 and f.frames - n0 <= 1,
              f'the camera moves: raycasts ({st[0]}, then {st2[0]}), the scene not sent again ({st2[2]} '
              f'upload); 0 samples: the raycast alone, and no frames while nothing changes '
              f'({f.frames - n0})')
        q('op("view.rendered_samples", "64")')
        settle(64, 180)
        conv = f.image().crop(BOX)
        mad = compare_img(ray, conv)
        check((g(8) or [0])[0] == 64 and mad < 20,
              f'the raycast looks like the path-traced image at 64 samples (mean difference {mad:.1f} levels)')
        few = {}                                        # denoised, every frame
        for dn in (0, 1):
            q('op("view.rendered_denoise", "%d")\nop("view.rendered_samples", "4")\n'
              'view(62, 25, 9, 0, 0, 0)' % dn)
            q('view(61, 25, 9, 0, 0, 0)')
            settle(4)
            few[dn] = (f.image().crop(BOX), g(13, 14))
        noisy, den = compare_img(few[0][0], conv), compare_img(few[1][0], conv)
        check(few[0][1][0] == 0 and few[1][1][0] == 1 and den < noisy * 0.5,
              f'Rendered denoise: 4 samples denoised on the GPU ({few[1][1][1]} ms) are nearer the 64-sample '
              f'image than 4 noisy ones (mean difference {den:.1f} against {noisy:.1f} levels)')
        q('move("Box", 2, 0, -1.5)')                    # the scene changes: up again
        f.pump(0.5)
        st = g(9)
        moved = f.image().crop(BOX)
        check(st[0] == 2 and compare_img(conv, moved) > 0.5,
              f'an object moves: the scene goes up again ({st[0]} uploads) and the image follows')
        q('op("view.rendered_samples", "64")\nop("anim.range", "1 60 30")\nframe(1)\n'
          'key("Box:y", 1, 0)\nkey("Box:y", 60, 1.5)\nop("anim.play")')
        shown = []                                      # playback: the scene changes every
        for _ in range(30):                             #  other frame; the raycast stays
            f.pump(0.03)                                #  (samples between the raycasts
            shown += g(8)                               #  flickered)
        up = g(9)
        q('op("anim.play")\nunkey("Box:y", 1)\nunkey("Box:y", 60)\nmove("Box", 2, 0, -1.5)')
        settle(64)
        check(len(shown) == 30 and max(shown) == 0 and up[0] > 5 and (g(8) or [0])[0] == 64,
              f'playing an animation: a raycast every frame ({up[0]} uploads, samples shown {max(shown or [-1])}),'
              f' then the samples once it stops ({g(8)})')
        q('op("render.settings", "160 90 512")')
        f.key(88)                                       # F12 meanwhile (its area
        f.pump(0.2)                                     #  narrows the viewport)
        q('view(80, 25, 9, 0, 0, 0)')
        during = g(10, 6, 7)
        f.pump(0.2)
        t = time.time()
        while time.time() - t < 180 and q('print(gpu(4) >= 512)') != '1':
            f.pump(0.2)
        f.pump(0.5)
        after = g(10, 4)
        if OUT:
            f.shot('gpu_live_f12.png')
        check(during[0] == 1 and after[0] == 1 and after[1] >= 512,
              f'an F12 render beside it: the live view goes on at the narrower size while it renders '
              f'(gpu(10), gpu(6): {during[:2]}), the render finishes ({after[1]} GPU samples)')
    finally:
        f.proc.kill()
    for env, what in (({'BEEMODEL_GPU': 'off'}, 'without the helper'),
                      ({'BEEMODEL_GPU': 'any', 'BEEMODEL_GPU_FAIL': '3'}, 'when the helper dies')):
        f, m, q = fake(**env)
        try:
            q(SCENE + 'view(30, 20, 9, 0, 0, 0)\nop("view.shading_material")')
            f.pump(0.5)
            prev = f.image().crop(BOX)
            q('op("view.shading_rendered")')
            for i in range(4):
                q('view(%d, 20, 9, 0, 0, 0)' % (31 + i))
                f.pump(0.3)
            q('view(30, 20, 9, 0, 0, 0)')
            f.pump(0.5)
            st = q('print(gpu(10))')
            mad = compare_img(prev, f.image().crop(BOX))
            if OUT:
                f.shot('gpu_live_%s.png' % ('off' if 'off' in what else 'died'))
            check(st == '0' and mad < 3,
                  f'{what}: Rendered shows Material Preview (gpu(10) {st}, mean difference {mad:.2f} levels '
                  f'but for the line saying so)')
        finally:
            f.proc.kill()


def compare_img(a, b):
    pa, pb = pixels(a), pixels(b)
    return sum(abs(x - y) for p, q in zip(pa, pb) for x, y in zip(p, q)) / (3 * len(pa))


def window(mode):
    """A frame of a mesh drawn through its DAG: (image, raster batches on
    the GPU)"""
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-gpu-shots-')]
    import fakewl
    sys.argv = argv
    saved = {k: os.environ.get(k) for k in ('BEEMODEL_GPU', 'BEEMODEL_GPU_HELPER')}
    os.environ['BEEMODEL_GPU'] = mode
    try:
        f = fakewl.Fake()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    try:
        f.pump(1.0, until_frame=True)
        m = fakewl.Mcp(f)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
        q('delete("Cube")\nadd("sphere", "Ball", 0, 0, 0)\nmodifier("Ball", "subsurf")\n'
          'modset("Ball", 0, "levels", 4)\nmodapply("Ball", 0)\nselect("Ball")\nop("vgeo.build")')
        t = time.time()
        while time.time() - t < 60 and q('print(vgeo("Ball", 0))') != '2':
            f.pump(0.2)
        q('view(30, 20, 6, 0, 0, 0)')
        for _ in range(6):
            f.pump(0.3)
            f.move(600 + _, 300)
        f.pump(1.0)
        n = int(float(q('print(gpu(3))') or 0))
        img = f.image()
        if OUT:
            f.shot('gpu_raster_%s.png' % mode)
        if mode == 'any':                               # F12: the Render area's
            q('op("render.settings", "320 180 512")')    #  progressive render
            n0 = f.frames
            f.key(88)
            t = time.time()
            while time.time() - t < 120 and q('print(gpu(4) >= 512)') != '1':
                f.pump(0.2)
            f.pump(0.5)
            st = [int(float(x)) for x in q('print(gpu(4), gpu(6))').split()]
            check(st[0] >= 512 and st[1] == 1 and f.frames - n0 >= 3,
                  f'the Render area\'s progressive render runs on the GPU: {st[0]} samples in '
                  f'{time.time() - t:.1f} s, the window drawing ({f.frames - n0} frames)')
        return img, n
    finally:
        f.proc.kill()


def finish():
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nGPU helper: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
