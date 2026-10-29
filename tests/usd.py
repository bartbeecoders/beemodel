#!/usr/bin/env python3
"""OpenUSD reading (src/usdc.s, usdlayer.s).

- Crate files (.usdc): every spec and field BeeModel reads (file.usd_dump)
  is what tests/usd_ref.py reads - a plain Python crate reader that matches
  OpenUSD's own (checked with pxr). tests/fixtures/usd/types.usdc covers
  inlined, compressed (ints, floats as ints, float tables) and plain arrays,
  halfs, quaternions, matrices, list ops, payloads, variant selections,
  blocked values; more .usdc files can be given on the command line.

    python3 tests/usd.py build/beemodel [more.usdc ...]
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import usd_ref                                               # noqa: E402

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
EXTRA = sys.argv[2:]
FIX = os.path.join(HERE, 'fixtures', 'usd')
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def dump(path):
    """BeeModel's reading of a USD file: {(path, field): value text}."""
    out = os.path.join(tempfile.mkdtemp(prefix='bee-usd-'), 'dump.txt')
    r = subprocess.run([BIN, '--eval', 'op("file.usd_dump", "%s %s")' % (path, out)],
                       capture_output=True, text=True, timeout=120)
    dump.rc = r.returncode
    if r.returncode != 0 or not os.path.exists(out):
        return None, (r.stdout + r.stderr).strip()[-300:]
    d = {}
    for line in open(out, errors='replace').read().splitlines():
        f = line.split('\t', 2)
        if len(f) == 3:                 # (damaged files: names with tabs, newlines)
            d[(f[0], f[1])] = f[2]
    return d, ''


def want(path):
    _, specs = usd_ref.read(path)
    d = {}
    for line in usd_ref.dump_lines(specs):
        p, k, v = line.split('\t', 2)
        d[(p, k)] = v
    return d


def same(g, w):
    if g == w:
        return True
    if w == 'LIST0':                    # an empty list: any empty kind
        return g is not None and g.split(' ')[1:2] == ['0']
    if g and w and g[0] == w[0] == 'f':  # float sums: rounding of the last digit
        a, b = g.split(), w.split()
        return a[:3] == b[:3] and all(abs(int(x) - int(y)) <= 2 + abs(int(y)) * 1e-6
                                      for x, y in zip(a[3:], b[3:]))
    return False


def crate(path):
    name = os.path.relpath(path)
    g, err = dump(path)
    if g is None:
        check(False, '%s: read (%s)' % (name, err))
        return
    w = want(path)
    bad = [k for k in w if not same(g.get(k), w[k])]
    extra = [k for k in g if k not in w]
    for k in bad[:5]:
        print('       %s %s\n         got  %s\n         want %s' % (k[0], k[1], (g.get(k) or '')[:120], w[k][:120]))
    check(not bad and not extra, '%s: %d fields as OpenUSD reads them (%d differ, %d extra)'
          % (name, len(w), len(bad), len(extra)))


def main():
    print('-- crate files --')
    crate(os.path.join(FIX, 'types.usdc'))
    for p in EXTRA:
        crate(p)
    g, err = dump(os.path.join(FIX, 'types.usda') + '.missing')
    check(g is None, 'a missing file is not read (%s)' % err[:60])
    bad = os.path.join(tempfile.mkdtemp(prefix='bee-usd-'), 'bad.usdc')
    data = open(os.path.join(FIX, 'types.usdc'), 'rb').read()
    for cut in (90, len(data) // 2, len(data) - 40):
        open(bad, 'wb').write(data[:cut])
        g, err = dump(bad)
        check(dump.rc == 0, 'a crate file cut at %d bytes: no crash (%s)' % (cut, 'read' if g else err[-50:]))
    for k in range(200):                # damaged bytes anywhere
        b = bytearray(data)
        for j in range(4):
            b[(k * 7919 + j * 104729) % (len(b) - 88) + 88] ^= 0x5a + j
        open(bad, 'wb').write(bytes(b))
        g, err = dump(bad)
        if dump.rc != 0:
            break
    check(dump.rc == 0, '200 crate files with damaged bytes: no crash (rc %d at %d)' % (dump.rc, k))


main()
if FAILS:
    print('usd: %d failed' % len(FAILS))
    sys.exit(1)
print('usd: all checks passed')
