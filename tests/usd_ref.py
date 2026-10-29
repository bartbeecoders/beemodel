"""A reference OpenUSD crate (.usdc) reader in plain Python: the algorithm
src/usdc.s ports, and the oracle tests/usd.py compares BeeModel's
file.usd_dump with (it matches OpenUSD's own reading: checked with pxr).

    python3 tests/usd_ref.py file.usdc [specs to print]
"""
import struct, sys

def lz4_block(src, out_max):
    out = bytearray(); i = 0
    while i < len(src):
        tok = src[i]; i += 1
        ln = tok >> 4
        if ln == 15:
            while True:
                b = src[i]; i += 1; ln += b
                if b != 255: break
        out += src[i:i + ln]; i += ln
        if i >= len(src): break
        off = src[i] | (src[i + 1] << 8); i += 2
        ml = tok & 15
        if ml == 15:
            while True:
                b = src[i]; i += 1; ml += b
                if b != 255: break
        ml += 4
        s = len(out) - off
        for k in range(ml): out.append(out[s + k])
    return bytes(out)

def fast_decompress(buf):
    n = buf[0]
    if n == 0: return lz4_block(buf[1:], None)
    out = b''; i = 1
    for _ in range(n):
        sz = struct.unpack_from('<i', buf, i)[0]; i += 4
        out += lz4_block(buf[i:i + sz], None); i += sz
    return out

def int_decode(data, n, wide):
    if wide: cs, sm, md, lg = 8, 'h', 'i', 'q'
    else: cs, sm, md, lg = 4, 'b', 'h', 'i'
    common = struct.unpack_from('<' + lg, data, 0)[0]
    codes = cs; nb = (n * 2 + 7) // 8; p = codes + nb
    out = []; prev = 0
    for k in range(n):
        c = (data[codes + k // 4] >> ((k % 4) * 2)) & 3
        if c == 0: d = common
        elif c == 1: d = struct.unpack_from('<' + sm, data, p)[0]; p += struct.calcsize(sm)
        elif c == 2: d = struct.unpack_from('<' + md, data, p)[0]; p += struct.calcsize(md)
        else: d = struct.unpack_from('<' + lg, data, p)[0]; p += struct.calcsize(lg)
        prev += d; out.append(prev)
    return out

def half(h):
    return struct.unpack('<e', struct.pack('<H', h))[0]

def i32(x):
    return struct.unpack('<i', struct.pack('<I', x & 0xffffffff))[0]

class R:
    def __init__(s, b, p=0): s.b = b; s.p = p
    def u64(s): v = struct.unpack_from('<Q', s.b, s.p)[0]; s.p += 8; return v
    def i64(s): v = struct.unpack_from('<q', s.b, s.p)[0]; s.p += 8; return v
    def u32(s): v = struct.unpack_from('<I', s.b, s.p)[0]; s.p += 4; return v
    def raw(s, n): v = s.b[s.p:s.p + n]; s.p += n; return v
    def cints(s, n, wide=False):
        sz = s.u64(); d = fast_decompress(s.raw(sz)); return int_decode(d, n, wide)

def read(path):
    b = open(path, 'rb').read()
    assert b[:8] == b'PXR-USDC'
    ver = tuple(b[8:11]); toc = struct.unpack_from('<q', b, 16)[0]
    r = R(b, toc); ns = r.u64(); sec = {}
    for _ in range(ns):
        name = r.raw(16).split(b'\0')[0].decode(); st = r.i64(); sz = r.i64(); sec[name] = st
    r = R(b, sec['TOKENS']); nt = r.u64(); us = r.u64(); cs = r.u64()
    toks = fast_decompress(r.raw(cs))[:us].split(b'\0')[:nt]; toks = [t.decode() for t in toks]
    r = R(b, sec['STRINGS']); n = r.u64(); strs = [r.u32() for _ in range(n)]
    r = R(b, sec['FIELDS']); nf = r.u64(); ftok = r.cints(nf); rsz = r.u64()
    reps = struct.unpack('<%dQ' % nf, fast_decompress(r.raw(rsz))[:nf * 8])
    r = R(b, sec['FIELDSETS']); n = r.u64(); fsets = r.cints(n)
    r = R(b, sec['PATHS']); npaths = r.u64(); nenc = r.u64()
    pidx = r.cints(nenc); etok = r.cints(nenc); jumps = r.cints(nenc)
    paths = [None] * npaths
    def build(parent, cur):
        while True:
            t = cur; cur += 1
            if parent is None: paths[pidx[t]] = '/'; me = '/'
            else:
                k = etok[t]; prop = k < 0; nm = toks[abs(k)]
                if prop: me = parent + '.' + nm
                else: me = parent + nm if nm.startswith('{') or parent[-1] in '/}' else parent + '/' + nm
                paths[pidx[t]] = me
            hc = jumps[t] > 0 or jumps[t] == -1; hs = jumps[t] >= 0
            if hc:
                if hs: build(parent, t + jumps[t])
                parent = me
            if not (hc or hs): return
    build(None, 0)
    r = R(b, sec['SPECS']); n = r.u64()
    sp = r.cints(n); sf = r.cints(n); st = r.cints(n)

    def val(rep):
        ty = (rep >> 48) & 0xff; arr = rep >> 63 & 1; inl = rep >> 62 & 1; comp = rep >> 61 & 1
        pl = rep & ((1 << 48) - 1)
        if inl:
            if ty == 51: return None
            if ty == 1: return bool(pl)
            if ty in (3, 5): return struct.unpack('<i', struct.pack('<I', pl & 0xffffffff))[0]
            if ty in (2, 4, 6, 42, 43, 44): return pl & 0xffffffff
            if ty == 7: return half(pl & 0xffff)
            if ty == 8: return struct.unpack('<f', struct.pack('<I', pl & 0xffffffff))[0]
            if ty == 9: return struct.unpack('<f', struct.pack('<I', pl & 0xffffffff))[0]
            if ty in (11, 12): return toks[pl]
            if ty == 10: return toks[strs[pl]]
            if 19 <= ty <= 30:
                k = (ty - 19) // 4 + 2
                bs = struct.pack('<I', pl & 0xffffffff); return tuple(float(x) for x in struct.unpack('<bbbb', bs)[:k])
            if ty in (13, 14, 15):
                k = ty - 11
                bs = struct.pack('<I', pl & 0xffffffff); d = struct.unpack('<bbbb', bs)
                return tuple(float(d[i // (k + 1)]) if i % (k + 1) == 0 else 0.0 for i in range(k * k))
            if ty in (40, 41, 50, 48): return []
            return ('inl', ty, pl)
        rr = R(b, pl)
        if arr:
            n = rr.u64()
            if ty in (3, 4) and comp: return rr.cints(n)
            if ty in (5, 6) and comp: return [i32(x) for x in rr.cints(n, True)]   # (narrowed, as BeeModel keeps them)
            if ty in (8, 9, 7) and comp:
                code = rr.raw(1)
                if code == b'i': ii = rr.cints(n); return [float(x) for x in ii]
                if code == b't':
                    lsz = rr.u32(); f = {8: 'f', 9: 'd', 7: 'e'}[ty]
                    lut = struct.unpack('<%d%s' % (lsz, f), rr.raw(lsz * struct.calcsize(f)))
                    ix = rr.cints(n); return [lut[x] for x in ix]
            fmt = {3: 'i', 4: 'i', 5: 'q', 6: 'q', 8: 'f', 9: 'd', 7: 'e', 20: '2f', 24: '3f', 28: '4f', 19: '2d',
                   23: '3d', 27: '4d', 17: '4f', 16: '4d', 15: '16d', 14: '9d', 13: '4d', 22: '2i', 26: '3i', 30: '4i',
                   21: '2e', 25: '3e', 29: '4e', 18: '4e', 11: 'I', 12: 'I', 10: 'I', 1: 'B', 2: 'B'}.get(ty)
            if fmt is None: return ('arr', ty, n)
            k = int(fmt[:-1]) if len(fmt) > 1 else 1; f = fmt[-1]
            vals = struct.unpack('<%d%s' % (n * k, f), rr.raw(n * k * struct.calcsize(f)))
            if ty == 11: return [toks[v] for v in vals]
            if ty in (10, 12): return [toks[strs[v]] for v in vals]   # (asset arrays: string numbers)
            if ty in (5, 6): vals = [i32(v) for v in vals]
            if k > 1: return [tuple(vals[i:i + k]) for i in range(0, len(vals), k)]
            return list(vals)
        if ty == 9: return struct.unpack('<d', rr.raw(8))[0]
        if ty == 5: return rr.i64()
        if ty in (19, 23, 27, 16, 15, 14, 13):
            k = {19: 2, 23: 3, 27: 4, 16: 4, 15: 16, 14: 9, 13: 4}[ty]; return struct.unpack('<%dd' % k, rr.raw(8 * k))
        if ty in (20, 24, 28, 17):
            k = {20: 2, 24: 3, 28: 4, 17: 4}[ty]; return struct.unpack('<%df' % k, rr.raw(4 * k))
        if ty in (21, 25, 29, 18):
            k = {21: 2, 25: 3, 29: 4, 18: 4}[ty]; return struct.unpack('<%de' % k, rr.raw(2 * k))
        if ty in (22, 26, 30):
            k = {22: 2, 26: 3, 30: 4}[ty]; return tuple(float(x) for x in struct.unpack('<%di' % k, rr.raw(4 * k)))
        if ty == 41:
            n = rr.u64(); return [toks[rr.u32()] for _ in range(n)]
        if ty == 50:
            n = rr.u64(); return [toks[strs[rr.u32()]] for _ in range(n)]
        if ty == 40:
            n = rr.u64(); return [paths[rr.u32()] for _ in range(n)]
        if ty == 48:
            n = rr.u64(); return list(struct.unpack('<%dd' % n, rr.raw(8 * n)))
        if ty in (32, 34, 35, 55, 33, 36):
            h = rr.raw(1)[0]; out = []
            for bit in (1 << 1, 1 << 2, 1 << 5, 1 << 6, 1 << 3, 1 << 4):
                if h & bit:
                    n = rr.u64()
                    for _ in range(n):
                        if ty == 32: it = toks[rr.u32()]
                        elif ty == 33: it = toks[strs[rr.u32()]]
                        elif ty == 34: it = paths[rr.u32()]
                        elif ty == 36: it = struct.unpack('<i', rr.raw(4))[0]
                        else:
                            a = toks[strs[rr.u32()]]; pp = paths[rr.u32()]; rr.raw(16)
                            if ty == 35:
                                dn = rr.u64()
                                assert dn == 0, 'customData in reference'
                            it = (a, pp)
                        if bit not in (1 << 3, 1 << 4): out.append(it)
            return out
        if ty == 47:
            a = toks[strs[rr.u32()]]; pp = paths[rr.u32()]; return [(a, pp)]
        if ty == 45:
            n = rr.u64(); return sorted((toks[strs[rr.u32()]], toks[strs[rr.u32()]]) for _ in range(n))
        if ty == 31: return 'dict'
        if ty == 46: return 'timesamples'
        return ('ty', ty)

    out = []
    for i in range(n):
        p = paths[sp[i]]; fs = sf[i]; fields = {}
        while fsets[fs] != -1:
            fi = fsets[fs]; fields[toks[ftok[fi]]] = val(reps[fi]); fs += 1
        out.append((p, st[i], fields))
    return ver, out

if __name__ == '__main__':
    ver, specs = read(sys.argv[1])
    print('version', ver, 'specs', len(specs))
    for p, t, f in specs[:int(sys.argv[2]) if len(sys.argv) > 2 else 40]:
        print(p, t, {k: (v if not isinstance(v, list) or len(v) < 6 else (len(v), v[:3])) for k, v in f.items()})

def q(x):
    return str(int(round(float(x) * 10000)))

def dump_lines(specs):
    out = []
    for p, t, f in specs:
        for k, v in f.items():
            out.append('%s\t%s\t%s' % (p, k, fmt(k, v)))
    return out

def fmt(k, v):
    if isinstance(v, str):
        if v in ('dict', 'timesamples'): return 'none'
        return 's ' + v
    if v is None: return 'none'
    if isinstance(v, bool): return 'i %d' % int(v)
    if isinstance(v, int): return 'i %d' % v
    if isinstance(v, float): return 'd ' + q(v)
    if isinstance(v, tuple):
        if v and v[0] in ('inl', 'arr', 'ty'): return 'none'
        return 'v %d %s' % (len(v), ' '.join(q(x) for x in v))
    if isinstance(v, list):
        if not v: return 'LIST0'
        e = v[0]
        if isinstance(e, str): return 'l %d %s' % (len(v), '|'.join(v))
        if isinstance(e, tuple) and len(e) == 2 and isinstance(e[0], str) and (e[1] is None or isinstance(e[1], str)):
            sep = '>' if k in ('references', 'payload') else '='
            return ('r' if sep == '>' else 'm') + ' %d %s' % (len(v), '|'.join('%s%s%s' % (a, sep, b or '') for a, b in v))
        if isinstance(e, float): return 'f %d 1 %s %s' % (len(v), q(sum(v)), q(sum(abs(x) for x in v)))
        if isinstance(e, int): return 'a %d 1 %d %d' % (len(v), sum(v), sum(abs(x) for x in v))
        if isinstance(e, tuple):
            fl = [x for t in v for x in t]
            if all(isinstance(x, int) for x in fl): return 'a %d %d %d %d' % (len(v), len(e), sum(fl), sum(abs(x) for x in fl))
            return 'f %d %d %s %s' % (len(v), len(e), q(sum(fl)), q(sum(abs(x) for x in fl)))
    return 'none'
