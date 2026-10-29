#!/usr/bin/env python3
"""Online library sources (src/extlib.s) against a stand-in Hugging Face.

A local HTTP server plays huggingface.co for tests/fixtures/usd/hub (three
assets: crate_test_a01 with a .usd root, a thumbnail, files an import does
not need; table_test_b02 with a .usda root, sublayers, references,
textures; noroot_x01 with no USD): the tree API two entries a page (Link
headers to the next), paths-info, recursive listings, resolve/main through a
302 to a "CDN". BEEMODEL_HF_URL points BeeModel at it; HOME is a scratch
folder. Headless, each operation runs to its end.

- lib.source simready: the catalog from every page, each asset's root
  (.usd or .usda, none for noroot_x01), its category, kept in catalog.tsv
  and read back the next time without asking the server.
- lib.get <asset> x y z: only the files an import needs fetched (not
  source_assets/, .mdl, .thumbs/), imported at x y z with its physics
  (the crate) or materials (the table); a second lib.get fetches nothing.
- A file the server fails on: the asset is not placed, the reason logged,
  no crash; once the server works again it comes.
- ~/BeeModel/sources.txt adds a source; lib.source <id> asks for its own
  dataset.
- lib.get of an unknown asset, and with no source shown: refused.

    python3 tests/extlib.py build/beemodel
"""
import http.server, json, os, shutil, subprocess, sys, tempfile, threading, urllib.parse

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
HUB = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixtures', 'usd', 'hub')
FAILS = []
LOG = []                                # (method, path) the server was asked
FAIL_PATHS = set()                      # dataset paths answered with 500


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


class Hub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=b'', ctype='application/json', headers=()):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def repo_rest(self, path, marker):
        # /api/datasets/<owner>/<name>/<marker>...
        p = path.split('/')
        if len(p) < 6 or p[1] != 'api' or p[2] != 'datasets':
            return None, None
        repo = p[3] + '/' + p[4]
        rest = '/'.join(p[5:])
        if not rest.startswith(marker):
            return None, None
        return repo, rest[len(marker):].lstrip('/')

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        LOG.append(('GET', u.path))
        if u.path.startswith('/cdn/'):                     # the "CDN"
            rel = urllib.parse.unquote(u.path[5:])
            if rel in FAIL_PATHS:
                return self.send(500, b'oops', 'text/plain')
            f = os.path.join(HUB, rel)
            if not os.path.isfile(f):
                return self.send(404, b'{}')
            return self.send(200, open(f, 'rb').read(), 'application/octet-stream')
        if '/resolve/main/' in u.path:                     # resolve: a redirect
            rel = u.path.split('/resolve/main/', 1)[1]
            return self.send(302, b'', headers=[('Location', '/cdn/' + rel)])
        repo, rest = self.repo_rest(u.path, 'tree/main')
        if repo is None:
            return self.send(404, b'{}')
        base = os.path.join(HUB, rest)
        if not os.path.isdir(base):
            return self.send(404, b'{"error":"no such path"}')
        if 'recursive' in q:
            items = []
            for root, dirs, files in os.walk(base):
                for d in dirs:
                    items.append({'type': 'directory', 'path': os.path.relpath(os.path.join(root, d), HUB)})
                for fn in files:
                    f = os.path.join(root, fn)
                    items.append({'type': 'file', 'oid': 'x', 'size': os.path.getsize(f),
                                  'path': os.path.relpath(f, HUB)})
        else:
            items = [{'type': 'directory' if os.path.isdir(os.path.join(base, n)) else 'file',
                      'oid': 'x', 'path': os.path.join(rest, n) if rest else n}
                     for n in sorted(os.listdir(base))]
            items.append({'type': 'file', 'oid': 'x', 'size': 9, 'path': '.gitattributes'})
        items.sort(key=lambda i: i['path'])
        start = int(q.get('cursor', ['0'])[0])
        per = 2 if not rest else 3                         # pages: several
        page = items[start:start + per]
        hdr = []
        if start + per < len(items):
            nxt = 'http://%s%s?%scursor=%d' % (self.headers['Host'], u.path,
                                                'recursive=true&' if 'recursive' in q else '', start + per)
            hdr.append(('Link', '<%s>; rel="next"' % nxt))
        self.send(200, json.dumps(page).encode(), headers=hdr)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n).decode()
        LOG.append(('POST', u.path))
        repo, rest = self.repo_rest(u.path, 'paths-info/main')
        if repo is None:
            return self.send(404, b'{}')
        form = urllib.parse.parse_qs(body)
        out = [{'type': 'file', 'oid': 'x', 'size': os.path.getsize(os.path.join(HUB, p)), 'path': p}
               for p in form.get('paths', []) if os.path.isfile(os.path.join(HUB, p))]
        self.send(200, json.dumps(out).encode())


def run(home, code, port):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='', BEEMODEL_HF_URL='http://127.0.0.1:%d' % port)
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout


def main():
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Hub)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    home = tempfile.mkdtemp(prefix='bee-extlib-')
    cache = os.path.join(home, 'BeeModel', 'cache', 'simready')
    try:
        print('-- the catalog --')
        rc, out = run(home, 'op("lib.source", "simready")', port)
        cat = os.path.join(cache, 'catalog.tsv')
        rows = [l.split('\t') for l in open(cat).read().splitlines()] if os.path.exists(cat) else []
        want = [['crate_test_a01', 'crate_test_a01/simready_usd/sm_crate_test_a01_01.usd', 'crate'],
                ['noroot_x01', '', 'noroot'],
                ['table_test_b02', 'table_test_b02/simready_usd/sm_table_test_b02_01.usda', 'table']]
        pages = sum(1 for m, p in LOG if m == 'GET' and p.endswith('/tree/main'))
        check(rc == 0 and sorted(rows) == want and pages >= 2,
              'every page read (%d), each root (.usd / .usda / none) and category (%s)' % (pages, rows))
        check(any(m == 'POST' and 'nvidia/simready-assets/paths-info' in p for m, p in LOG),
              'the roots asked for in one paths-info request')
        LOG.clear()
        rc, out = run(home, 'op("lib.source", "simready")', port)
        check(rc == 0 and not LOG, 'the next time: catalog.tsv read, the server not asked (%d requests)' % len(LOG))

        print('-- placing --')
        LOG.clear()
        code = ('op("lib.source", "simready")\nn0 = count()\nop("lib.get", "crate_test_a01 2 0 -1")\n'
                'for i in n0..count() { o = name(i)\n print("OB", o, get(o, "x"), get(o, "y"), get(o, "z"), rigid(o, "type")) }')
        rc, out = run(home, code, port)
        obs = {l.split()[1]: l.split()[2:] for l in out.splitlines() if l.startswith('OB ')}
        got = sorted(p[5:] for m, p in LOG if p.startswith('/cdn/'))
        check(got == ['crate_test_a01/simready_usd/sm_crate_test_a01_01.usd'],
              'only what an import needs fetched (not source_assets, .mdl, .thumbs): %s' % got)
        box = obs.get('Box')
        check(box is not None and abs(float(box[0]) - 2) < 1e-4 and abs(float(box[1]) - 2) < 1e-4
              and abs(float(box[2]) + 1) < 1e-4 and box[3] == '1' and len(obs) == 4,
              'placed at 2 0 -1 with its bodies (Box at %s; %d objects)' % (box, len(obs)))
        check(os.path.exists(os.path.join(cache, 'assets', 'crate_test_a01', 'simready_usd', 'sm_crate_test_a01_01.usd'))
              and not os.path.exists(os.path.join(cache, 'assets', 'crate_test_a01', 'simready_usd', 'source_assets')),
              'kept in the cache, as in the dataset')
        LOG.clear()
        rc, out = run(home, code, port)
        check(rc == 0 and not any(p.startswith('/cdn/') for m, p in LOG) and 'OB Box' in out,
              'a second lib.get: placed again, nothing fetched')
        LOG.clear()
        code2 = ('op("lib.source", "simready")\nn0 = count()\nop("lib.get", "table_test_b02 0 0 0")\n'
                 'if exists("Top.001") { print("N", count() - n0, matof("Top"), matof("Top.001")) } else { print("N", count() - n0, "none") }')
        rc, out = run(home, code2, port)
        got = sorted(p.split('/')[-1] for m, p in LOG if p.startswith('/cdn/'))
        n = [l.split()[1:] for l in out.splitlines() if l.startswith('N ')]
        check(got == ['check.png', 'legs.usda', 'orm.png', 'over.usda', 'parts.usdc', 'sm_table_test_b02_01.usda']
              and n == [['7', 'Wood', 'Paint']],
              'a .usda root with its sublayers, references and textures: %s, %s' % (got, n))

        print('-- failures --')
        shutil.rmtree(os.path.join(cache, 'assets', 'table_test_b02'))
        FAIL_PATHS.add('table_test_b02/simready_usd/tex/orm.png')
        rc, out = run(home, code2, port)
        n = [l.split()[1:] for l in out.splitlines() if l.startswith('N ')]
        check(rc == 0 and n == [['0', 'none']], 'a file failing: nothing placed, no crash (%s)' % n)
        FAIL_PATHS.clear()
        LOG.clear()
        rc, out = run(home, code2, port)
        got = sorted(p.split('/')[-1] for m, p in LOG if p.startswith('/cdn/'))
        n = [l.split()[1:] for l in out.splitlines() if l.startswith('N ')]
        check(n == [['7', 'Wood', 'Paint']] and got == ['orm.png'],
              'the server back: only the file missing fetched, then placed (%s)' % got)
        rc, out = run(home, 'n0 = count()\nop("lib.get", "crate_test_a01")\nop("lib.source", "simready")\n'
                      'op("lib.get", "no_such_asset")\nprint("N", count() - n0)', port)
        check(rc == 0 and 'N 0' in out, 'lib.get with no source shown, or of no such asset: nothing')

        print('-- more sources --')
        open(os.path.join(home, 'BeeModel', 'sources.txt'), 'w').write(
            '# more datasets in SimReady\'s layout\nsimready more acme/more-assets  Acme Assets\nbogus x y\n')
        LOG.clear()
        rc, out = run(home, 'op("lib.source", "more")', port)
        check(any('acme/more-assets/tree/main' in p for m, p in LOG)
              and os.path.exists(os.path.join(home, 'BeeModel', 'cache', 'more', 'catalog.tsv')),
              'sources.txt adds a source: lib.source more asks for acme/more-assets')
    finally:
        srv.shutdown()
        shutil.rmtree(home, ignore_errors=True)


main()
if FAILS:
    print('extlib: %d failed' % len(FAILS))
    sys.exit(1)
print('extlib: all checks passed')
