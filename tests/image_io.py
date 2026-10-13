#!/usr/bin/env python3
"""Image reader/writer conformance: PNG (every colour type, bit depth, filter,
Adam7, tRNS), JPEG (baseline: 4:4:4, 4:2:2, 4:2:0, grey, restart markers),
Radiance HDR (RLE and flat) and the EXR writer. PNG and HDR must decode
exactly; JPEG within a few levels of Pillow."""
import os, random, struct, subprocess, sys, tempfile, zlib, math

BIN = sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel'
FAILS = []
HOME = tempfile.mkdtemp(prefix='bee-img-')
ENV = dict(os.environ, HOME=HOME, XDG_CACHE_HOME='')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(code):
    r = subprocess.run([BIN, '--eval', code], env=ENV, capture_output=True, text=True, timeout=120)
    return r.stdout


def dump(path, w, h, chans=4):
    """Every pixel of a loaded image, through BeeScript."""
    code = (f'n = image("{path}")\nprint(imgsize(n, 0), imgsize(n, 1))\n'
            f'for y in 0..{h} {{ for x in 0..{w} {{ print(' +
            ', '.join(f'imgpixel(n, x, y, {c})' for c in range(chans)) + ') } }')
    out = run(code).split('\n')
    try:
        size = tuple(int(float(v)) for v in out[0].split())
        px = [tuple(float(v) for v in line.split()) for line in out[1:1 + w * h]]
    except (ValueError, IndexError):
        return None, out[:3]
    return size, px


# ---- PNG ----------------------------------------------------------------------
def png_chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)


def paeth(a, b, c):
    p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def filt(row, prev, bpp, f):
    out = bytearray()
    for i, x in enumerate(row):
        a = row[i - bpp] if i >= bpp else 0
        b = prev[i] if prev else 0
        c = prev[i - bpp] if prev and i >= bpp else 0
        p = [0, a, b, (a + b) // 2, paeth(a, b, c)][f]
        out.append((x - p) & 255)
    return bytes([f]) + bytes(out)


ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
CHANS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def make_png(w, h, ctype, depth, interlace, trns, rnd):
    ch = CHANS[ctype]
    maxv = (1 << depth) - 1
    npal = min(256, 1 << depth) if ctype == 3 else 0
    pal = [(rnd.randrange(256), rnd.randrange(256), rnd.randrange(256)) for _ in range(npal)]
    palpha = [rnd.randrange(256) for _ in range(npal)]
    # smooth-ish data so every filter matters
    samples = [[[min(maxv, max(0, (x * 7 + y * 3 + c * 11) * maxv // 64 + rnd.randrange(-1, 2) * (maxv // 16)))
                 if ctype != 3 else rnd.randrange(npal)
                 for c in range(ch)] for x in range(w)] for y in range(h)]
    key = None
    if trns and ctype in (0, 2):
        key = tuple(samples[h // 2][w // 2][:ch])
    def to8(v):
        return v >> 8 if depth == 16 else v * 255 // maxv
    exp = []
    for y in range(h):
        for x in range(w):
            s = samples[y][x]
            if ctype == 3:
                r, g, b = pal[s[0]]; a = palpha[s[0]] if trns else 255
            elif ctype in (0, 4):
                r = g = b = to8(s[0]); a = to8(s[1]) if ctype == 4 else 255
                if key is not None and (s[0],) == key: a = 0
            else:
                r, g, b = (to8(v) for v in s[:3]); a = to8(s[3]) if ctype == 6 else 255
                if key is not None and tuple(s[:3]) == key: a = 0
            exp.append((r, g, b, a))
    def pack(row):
        if depth >= 8:
            out = bytearray()
            for px in row:
                for v in px:
                    out += v.to_bytes(depth // 8, 'big')
            return bytes(out)
        bits = ''.join(format(v, f'0{depth}b') for px in row for v in px)
        bits += '0' * (-len(bits) % 8)
        return bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))
    bpp = max(1, ch * depth // 8)
    raw = bytearray()
    passes = ADAM7 if interlace else [(0, 0, 1, 1)]
    for x0, y0, dx, dy in passes:
        prev = None
        for y in range(y0, h, dy):
            row = [samples[y][x] for x in range(x0, w, dx)]
            if not row: break
            data = pack(row)
            raw += filt(data, prev, bpp, rnd.randrange(5))
            prev = data
    out = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, depth, ctype, 0, 0, interlace))
    if ctype == 3:
        out += png_chunk(b'PLTE', b''.join(bytes(p) for p in pal))
        if trns: out += png_chunk(b'tRNS', bytes(palpha))
    elif key is not None:
        out += png_chunk(b'tRNS', b''.join(v.to_bytes(2, 'big') for v in key))
    z = zlib.compress(bytes(raw), rnd.choice([0, 1, 6, 9]))
    for i in range(0, len(z), 97):                   # several IDATs
        out += png_chunk(b'IDAT', z[i:i + 97])
    return out + png_chunk(b'IEND', b''), exp


def png_suite():
    print('  -- PNG --')
    rnd = random.Random(7)
    combos = [(0, d) for d in (1, 2, 4, 8, 16)] + [(2, 8), (2, 16), (3, 1), (3, 2), (3, 4), (3, 8),
              (4, 8), (4, 16), (6, 8), (6, 16)]
    bad = []
    for ctype, depth in combos:
        for interlace in (0, 1):
            trns = ctype in (0, 2, 3) and interlace == 0
            w, h = rnd.randrange(1, 23), rnd.randrange(1, 19)
            data, exp = make_png(w, h, ctype, depth, interlace, trns, rnd)
            p = os.path.join(HOME, f'p{ctype}_{depth}_{interlace}.png')
            open(p, 'wb').write(data)
            size, got = dump(p, w, h)
            ok = size == (w, h) and [tuple(int(v) for v in g) for g in got] == exp
            if not ok:
                bad.append(f'ctype {ctype} depth {depth} interlace {interlace} ({w}x{h}): {size} {got[:2] if got else got}')
    check(not bad, f'{len(combos) * 2} PNG variants decode exactly (all colour types, depths, filters, Adam7, tRNS)'
          + ('' if not bad else ': ' + '; '.join(bad[:3])))
    # a damaged file is refused, not crashed on
    data, _ = make_png(16, 16, 6, 8, 0, False, rnd)
    p = os.path.join(HOME, 'broken.png')
    open(p, 'wb').write(data[:len(data) // 2] + bytes(len(data) // 2))
    out = run(f'print(image("{p}"))')
    check('could not load' in out or 'error' in out, 'a damaged PNG is refused')
    # big + real-world compression (Pillow, adaptive filters)
    from PIL import Image
    im = Image.new('RGB', (640, 480))
    im.putdata([((x * 3) & 255, (y * 5) & 255, (x ^ y) & 255) for y in range(480) for x in range(640)])
    p = os.path.join(HOME, 'big.png'); im.save(p, optimize=True)
    out = os.path.join(HOME, 'big_out.png')
    run(f'n = image("{p}"); op("image.save", n + " {out}")')
    ok = os.path.exists(out) and Image.open(out).convert('RGB').tobytes() == im.tobytes()
    check(ok, 'a 640 x 480 Pillow PNG round-trips through image.save')


# ---- JPEG ---------------------------------------------------------------------
def jpeg_suite():
    print('  -- JPEG --')
    from PIL import Image
    rnd = random.Random(3)
    def picture(w, h):
        im = Image.new('RGB', (w, h))
        im.putdata([(int(128 + 100 * math.sin(x / 9 + y / 23)), (x * 255 // w), (y * 255 // h) ^ ((x // 8) & 1) * 40)
                    for y in range(h) for x in range(w)])
        return im
    cases = [('444', dict(subsampling=0)), ('422', dict(subsampling=1)), ('420', dict(subsampling=2)),
             ('grey', dict()), ('q30', dict(subsampling=2, quality=30)),
             ('restart', dict(subsampling=2, restart_marker_blocks=3)),
             ('restart_rows', dict(subsampling=0, restart_marker_rows=1)),
             ('optimized', dict(subsampling=1, optimize=True))]
    for name, opts in cases:
        w, h = rnd.randrange(17, 90), rnd.randrange(9, 70)
        im = picture(w, h)
        if name == 'grey':
            im = im.convert('L')
        p = os.path.join(HOME, f'{name}.jpg')
        try:
            im.save(p, quality=opts.pop('quality', 90), **opts)
        except (TypeError, ValueError, OSError) as e:
            print(f'  skip {name}: {e}'); continue
        ref = Image.open(p).convert('RGB')
        size, got = dump(p, w, h, 3)
        if size != (w, h):
            check(False, f'JPEG {name} {w}x{h} decodes ({size}, {got})'); continue
        diffs = [abs(int(g[c]) - r[c]) for g, r in zip(got, ref.getdata()) for c in range(3)]
        mean, worst = sum(diffs) / len(diffs), max(diffs)
        check(mean < 1.0 and worst <= 12, f'JPEG {name} {w}x{h} matches Pillow (mean {mean:.2f}, max {worst} levels)')
    p = os.path.join(HOME, 'prog.jpg')
    picture(40, 30).save(p, progressive=True)
    out = run(f'print(image("{p}"))')
    check('could not load' in out, 'a progressive JPEG is refused with a message')
    # a photo-sized file: time
    im = picture(1920, 1080)
    p = os.path.join(HOME, 'big.jpg'); im.save(p, quality=90, subsampling=2)
    import time
    t = time.time(); out = run(f'n = image("{p}"); print(imgsize(n, 0))'); t = (time.time() - t) * 1000
    check(out.strip() == '1920', f'a 1920 x 1080 JPEG loads ({t:.0f} ms with start-up)')


# ---- Radiance HDR and the EXR writer ---------------------------------------------
def rgbe(r, g, b):
    m = max(r, g, b)
    if m < 1e-32:
        return (0, 0, 0, 0)
    f, e = math.frexp(m)
    s = f * 256.0 / m
    return (int(r * s), int(g * s), int(b * s), e + 128)


def write_hdr(path, w, h, px, rle=True, bottom_up=False):
    out = bytearray(b'#?RADIANCE\n# made by a test\nFORMAT=32-bit_rle_rgbe\nEXPOSURE=1.0\n\n')
    out += (f'+Y {h} +X {w}\n' if bottom_up else f'-Y {h} +X {w}\n').encode()
    rows = range(h - 1, -1, -1) if bottom_up else range(h)
    for y in rows:
        line = [px[y * w + x] for x in range(w)]
        if not rle:
            for p in line: out += bytes(p)
            continue
        out += bytes([2, 2, w >> 8, w & 255])
        for c in range(4):
            vals = [p[c] for p in line]
            i = 0
            while i < w:
                run = 1
                while i + run < w and run < 127 and vals[i + run] == vals[i]: run += 1
                if run >= 3:
                    out += bytes([128 + run, vals[i]]); i += run
                else:
                    j = i
                    while j < w and j - i < 128 and not (j + 2 < w and vals[j] == vals[j + 1] == vals[j + 2]): j += 1
                    out += bytes([j - i]) + bytes(vals[i:j]); i = j
    open(path, 'wb').write(out)


def half_to_float(hv):
    s, e, m = hv >> 15, (hv >> 10) & 31, hv & 1023
    v = (m / 1024.0) * 2 ** -14 if e == 0 else (math.inf if e == 31 else (1 + m / 1024.0) * 2 ** (e - 15))
    return -v if s else v


def read_exr(path):
    """A small OpenEXR reader: scanline, HALF channels, NONE or ZIP."""
    d = open(path, 'rb').read()
    assert d[:4] == b'\x76\x2f\x31\x01', 'magic'
    p, attrs = 8, {}
    while d[p] != 0:
        n = d.index(b'\0', p); name = d[p:n].decode(); t = d.index(b'\0', n + 1)
        size = struct.unpack_from('<i', d, t + 1)[0]
        attrs[name] = d[t + 5:t + 5 + size]; p = t + 5 + size
    p += 1
    chans, q = [], 0
    cl = attrs['channels']
    while cl[q] != 0:
        n = cl.index(b'\0', q); chans.append((cl[q:n].decode(), struct.unpack_from('<i', cl, n + 1)[0])); q = n + 17
    comp = attrs['compression'][0]
    x0, y0, x1, y1 = struct.unpack('<4i', attrs['dataWindow'])
    w, h = x1 - x0 + 1, y1 - y0 + 1
    lines = {0: 1, 3: 16}[comp]
    nblocks = (h + lines - 1) // lines
    offs = struct.unpack_from(f'<{nblocks}Q', d, p)
    img = {}
    for o in offs:
        y, size = struct.unpack_from('<ii', d, o)
        data = d[o + 8:o + 8 + size]
        n = min(lines, h - y)
        raw_size = n * w * 2 * len(chans)
        if comp == 3 and size < raw_size:
            t = bytearray(zlib.decompress(data))
            for i in range(1, len(t)): t[i] = (t[i - 1] + t[i] - 128) & 255
            half = (len(t) + 1) // 2
            data = bytearray(len(t)); data[0::2] = t[:half]; data[1::2] = t[half:]
        k = 0
        for yy in range(y, y + n):
            for name, typ in chans:
                assert typ == 1, 'half'
                for x in range(w):
                    img[(name, x, yy)] = half_to_float(struct.unpack_from('<H', data, k)[0]); k += 2
    return w, h, [c for c, _ in chans], img


def hdr_suite():
    print('  -- Radiance HDR, OpenEXR --')
    rnd = random.Random(5)
    for name, w, h, rle, up in (('rle', 37, 11, True, False), ('flat', 6, 5, False, False),
                                ('bottomup', 20, 9, True, True)):
        px = []
        for y in range(h):
            for x in range(w):
                if x < w // 3:   # runs
                    v = (0.5, 0.25, 4.0)
                else:
                    v = (rnd.uniform(0, 50) * (y + 1), rnd.uniform(0, 1), rnd.uniform(0, 0.01))
                px.append(rgbe(*v))
        p = os.path.join(HOME, f'{name}.hdr')
        write_hdr(p, w, h, px, rle, up)
        size, got = dump(p, w, h, 3)
        exp = [tuple(c * 2.0 ** (e - 136) if e else 0.0 for c in (r, g, b)) for r, g, b, e in px]
        ok = size == (w, h) and all(abs(a - b) <= 1e-6 * max(1, abs(b)) for g, x in zip(got, exp) for a, b in zip(g, x))
        check(ok, f'HDR {name} {w}x{h} decodes exactly ({size})')
        if name == 'rle':
            out = os.path.join(HOME, 'hdr.exr')
            run(f'n = image("{p}"); op("image.save", n + " {out}")')
            try:
                ew, eh, chans, img = read_exr(out)
                err = max(abs(img[(c, x, y)] - exp[y * w + x]['RGB'.index(c)]) / max(1e-3, abs(exp[y * w + x]['RGB'.index(c)]))
                          for c in 'RGB' for y in range(h) for x in range(w))
                check((ew, eh) == (w, h) and chans == ['B', 'G', 'R'] and err < 2e-3,
                      f'image.save writes a half-float ZIP EXR (relative error {err:.1e})')
            except Exception as e:
                check(False, f'image.save writes a readable EXR ({e})')


def exr_suite():
    print('  -- EXR from renders --')
    import shutil
    out = os.path.join(HOME, 'r.exr')
    run(f'op("render.settings", "96 54 4"); op("render.start"); op("render.save", "{out} albedo")')
    # (headless: no samples yet, so a black image; still a valid file)
    try:
        w, h, chans, img = read_exr(out)
        check((w, h) == (96, 54) and chans == ['B', 'G', 'R'], 'render.save <path>.exr writes a half-float EXR')
    except Exception as e:
        check(False, f'render.save writes a readable EXR ({e})')
    # a smooth HDR compresses, and OpenEXR itself (when installed) agrees
    w, h = 300, 200
    px = [rgbe(x / 30.0, y / 50.0, 1.0) for y in range(h) for x in range(w)]
    p = os.path.join(HOME, 'smooth.hdr'); write_hdr(p, w, h, px)
    out = os.path.join(HOME, 'smooth.exr')
    run(f'n = image("{p}"); op("image.save", n + " {out}")')
    size = os.path.getsize(out) if os.path.exists(out) else 0
    check(0 < size < w * h * 6 // 2, f'ZIP blocks compress a smooth image ({size} of {w * h * 6} bytes)')
    try:
        _, _, _, img = read_exr(out)
        dec = lambda q: q[0] * 2.0 ** (q[3] - 136) if q[3] else 0.0
        err = max(abs(img[('R', x, y)] - dec(px[y * w + x])) for y in range(0, h, 7) for x in range(0, w, 7))
        check(err < 1e-6, f'the EXR reads back (max error {err:.4f})')
    except Exception as e:
        check(False, f'the compressed EXR reads back ({e})')
    if shutil.which('oiiotool'):
        r = subprocess.run(['oiiotool', out, '--printstats'], capture_output=True, text=True)
        check(r.returncode == 0 and 'FiniteCount: 60000' in r.stdout, 'OpenEXR (oiiotool) reads it too')


if __name__ == '__main__':
    png_suite()
    jpeg_suite()
    hdr_suite()
    exr_suite()
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nall image checks passed')
    sys.exit(1 if FAILS else 0)
