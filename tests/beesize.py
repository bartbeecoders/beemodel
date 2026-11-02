#!/usr/bin/env python3
"""Smaller .bee files (#442).

- Big chunks (meshes, UVs, ...) are deflated into ZCHK chunks and the file
  says version 2; it opens with the same geometry.
- A texture that came in as a JPEG (a .glb's, a .blend's packed one) is
  saved as that JPEG, byte for byte, not re-encoded as a PNG many times its
  size; painted, it is saved as a PNG again.

    python3 tests/beesize.py build/beemodel
"""
import io, json, math, os, struct, subprocess, sys, tempfile

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def run(home, code):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=300)
    return (r.stdout + r.stderr).strip()


def chunks(path):
    """(tag, inner tag or None, stored bytes, raw bytes, body) of a .bee."""
    d = open(path, 'rb').read()
    out, o = [], 8
    while o + 8 <= len(d):
        tag, n = struct.unpack_from('<4sI', d, o)
        body = d[o + 8:o + 8 + n]
        if tag == b'ZCHK':
            inner, raw = struct.unpack_from('<4sI', body, 0)
            out.append((tag, inner, n, raw, body))
        else:
            out.append((tag, None, n, n, body))
        o += 8 + n
    return d[:8], out


def glb_with_jpeg(path, jpeg):
    """A UV sphere with one base colour texture, the JPEG inside the .glb."""
    pos, uv, idx = [], [], []
    R, C = 24, 48
    for i in range(R + 1):
        for j in range(C + 1):
            th, ph = math.pi * i / R, 2 * math.pi * j / C
            pos.append((math.sin(th) * math.cos(ph), math.cos(th), math.sin(th) * math.sin(ph)))
            uv.append((j / C, i / R))
    for i in range(R):
        for j in range(C):
            a, b = i * (C + 1) + j, (i + 1) * (C + 1) + j
            idx += [a, b, a + 1, a + 1, b, b + 1]
    geo = b''.join(struct.pack('<3f', *p) for p in pos) + b''.join(struct.pack('<2f', *t) for t in uv)
    ib = struct.pack(f'<{len(idx)}H', *idx)
    binb = bytearray(geo + ib)
    while len(binb) % 4:
        binb.append(0)
    views = [{'buffer': 0, 'byteOffset': 0, 'byteLength': 12 * len(pos)},
             {'buffer': 0, 'byteOffset': 12 * len(pos), 'byteLength': 8 * len(uv)},
             {'buffer': 0, 'byteOffset': len(geo), 'byteLength': len(ib)},
             {'buffer': 0, 'byteOffset': len(binb), 'byteLength': len(jpeg)}]
    binb += jpeg
    while len(binb) % 4:
        binb.append(0)
    g = {'asset': {'version': '2.0'}, 'scene': 0, 'scenes': [{'nodes': [0]}], 'nodes': [{'name': 'Globe', 'mesh': 0}],
         'meshes': [{'primitives': [{'attributes': {'POSITION': 0, 'TEXCOORD_0': 1}, 'indices': 2, 'material': 0}]}],
         'materials': [{'name': 'Earth', 'pbrMetallicRoughness': {'baseColorTexture': {'index': 0}}}],
         'textures': [{'source': 0}], 'images': [{'name': 'earth', 'mimeType': 'image/jpeg', 'bufferView': 3}],
         'accessors': [{'bufferView': 0, 'componentType': 5126, 'type': 'VEC3', 'count': len(pos), 'min': [-1, -1, -1], 'max': [1, 1, 1]},
                       {'bufferView': 1, 'componentType': 5126, 'type': 'VEC2', 'count': len(uv)},
                       {'bufferView': 2, 'componentType': 5123, 'type': 'SCALAR', 'count': len(idx)}],
         'bufferViews': views, 'buffers': [{'byteLength': len(binb)}]}
    js = json.dumps(g).encode()
    js += b' ' * ((4 - len(js) % 4) % 4)
    body = struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(binb), 0x004E4942) + bytes(binb)
    open(path, 'wb').write(struct.pack('<III', 0x46546C67, 2, 12 + len(body)) + body)


def main():
    from PIL import Image
    home = tempfile.mkdtemp(prefix='bee-size-')
    os.makedirs(os.path.join(home, 'BeeModel'), exist_ok=True)

    print('  -- big chunks deflated --')
    a = os.path.join(home, 'BeeModel', 'mesh.bee')
    out = run(home, 'add("sphere", "Ball", 0, 0, 0)\nselect("Ball")\nk = modifier("Ball", "subsurf")\nmodset("Ball", k, "levels", 3)\n'
                    'op("object.modifier_apply")\nedit("Ball")\nop("uv.smart_project")\nedit()\n'
                    f'print("faces", faces("Ball"))\nop("file.save", "{a}")')
    head, cs = chunks(a)
    z = [c for c in cs if c[0] == b'ZCHK']
    stored = sum(c[2] for c in z)
    raw = sum(c[3] for c in z)
    check(head == b'BEEM\x02\x00\x00\x00' and z and {c[1] for c in z} >= {b'MESH'},
          f'the mesh is a ZCHK chunk, the file version 2 ({head[4:5]}, {[c[1] for c in z]})')
    check(raw and stored < raw * 0.8, f'deflated: {raw} bytes -> {stored}')
    check(any(c[0] == b'THMB' for c in cs) is False or cs[0][0] == b'THMB', 'a thumbnail stays first, as it was')
    back = run(home, f'op("file.open", "{a}")\nprint("faces", faces("Ball"), count())')
    f0 = [l for l in out.splitlines() if l.startswith('faces')]
    f1 = [l for l in back.splitlines() if l.startswith('faces')]
    check(f0 and f1 and f0[0].split()[1] == f1[0].split()[1], f'opened: the same mesh ({f0} {f1})')

    print('  -- a JPEG texture stays a JPEG --')
    w = h = 512                                # (a photo-like picture: PNG
    img = Image.new('RGB', (w, h))             #  can't make it small)
    px = img.load()
    import random
    random.seed(3)
    for y in range(h):
        for x in range(w):
            v = int(128 + 60 * math.sin(x * 0.05) * math.cos(y * 0.07) + random.randint(-30, 30))
            px[x, y] = (max(0, min(255, v)), max(0, min(255, v - 20)), max(0, min(255, 255 - v)))
    buf = io.BytesIO()
    img.save(buf, 'JPEG', quality=90)
    jpeg = buf.getvalue()
    glb = os.path.join(home, 'globe.glb')
    glb_with_jpeg(glb, jpeg)
    b = os.path.join(home, 'BeeModel', 'globe.bee')
    out = run(home, f'op("file.import_gltf", "{glb}")\nop("file.save", "{b}")\nprint("n", count())')
    head, cs = chunks(b)
    imgd = [c for c in cs if c[0] == b'IMGD']
    body = imgd[0][4] if imgd else b''
    n = struct.unpack_from('<I', body, 4)[0] if len(body) >= 8 else 0
    kept = body[8:8 + n]
    check(kept == jpeg, f'the .bee holds the JPEG as it was ({n} bytes, the JPEG {len(jpeg)})')
    total = os.path.getsize(b)
    check(total < len(jpeg) + 200000, f'so the file stays small ({total} bytes)')
    c = os.path.join(home, 'BeeModel', 'globe2.bee')
    out = run(home, f'op("file.open", "{b}")\nprint("size", imgsize("earth", 0), imgsize("earth", 1))\nop("file.save", "{c}")')
    check('size 512 512' in out, f'opened: the texture is there ({out[-80:]!r})')
    head, cs = chunks(c)
    body = [x for x in cs if x[0] == b'IMGD'][0][4]
    n = struct.unpack_from('<I', body, 4)[0]
    check(body[8:8 + n] == jpeg, 'saved again: still the same JPEG')
    d = os.path.join(home, 'BeeModel', 'globe3.bee')
    out = run(home, f'op("file.open", "{b}")\nimgset("earth", 10, 10, 255, 0, 0)\nop("file.save", "{d}")')
    head, cs = chunks(d)
    body = [x for x in cs if x[0] == b'IMGD'][0][4]
    n = struct.unpack_from('<I', body, 4)[0]
    check(body[8:12] == b'\x89PNG', 'painted: saved as a PNG (the JPEG is not what it shows any more)')

    print('beesize: %d failed' % len(FAILS) if FAILS else 'beesize: all passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
