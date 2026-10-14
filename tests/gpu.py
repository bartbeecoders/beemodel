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
  * The rasterizer: a window (the fake compositor) showing a mesh drawn
    through its cluster DAG, with the tile stage on the GPU, against the
    same frame on the CPU.

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
    c, _ = render('den_cpu', SCENE, 32, 1, BEEMODEL_GPU='off')
    p, gp = render('den_gpu', SCENE, 32, 1, BEEMODEL_GPU='any')
    mad, same = compare(c, p)
    check(gp[2] == 32 and mad < 0.5, f'denoised (albedo and normal passes from the GPU): the CPU\'s image '
                                     f'(mean difference {mad:.4f})')

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
    return finish()


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
