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
- A placed asset is saved into the local library too (#simready #crate).
- The window (tools/fakewl.py): the Asset Browser on SimReady fetches the
  catalog in the background, a tile's thumbnail when it shows, and a
  double-click on a tile downloads and places the asset; the source button
  in the header goes round the sources; the wheel scrolls.
- SimReady Central (a stand-in GitHub index, BEEMODEL_GH_URL, and datasets
  pinned to commits): lib.source central reads the index's files, takes in
  public datasets under an open licence (not one gated or "other", nor
  nvidia/simready-assets, a source of its own), names a folder another
  dataset has <folder>_<owner>, keeps an asset's latest commit; lib.get
  reads the asset's package (its bill of materials) at that commit: the
  root is the USD its thumbnail shows (else the first USD), only what an
  import needs is fetched. In the window, a tile's thumbnail comes through
  its package.

    python3 tests/extlib.py build/beemodel
"""
import http.server, json, os, shutil, subprocess, sys, tempfile, threading, urllib.parse

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
HUB = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixtures', 'usd', 'hub')
FAILS = []
LOG = []                                # (method, path) the server was asked
FAIL_PATHS = set()                      # dataset paths answered with 500
CENTRAL = None                          # SimReady Central's stand-in datasets
CREPO = 'NVIDIA-Omniverse/simready-central'
REVS = {}                               # (dataset, folder) -> its commit
INDEX = {}                              # dataset -> its index file
INFO = {                                # dataset -> the Hugging Face API's word
    'acme/props': {'gated': False, 'private': False, 'tags': ['format:usd', 'license:cc-by-4.0']},
    'beta/kit': {'gated': False, 'tags': ['license:apache-2.0']},
    'closed/stuff': {'gated': False, 'tags': ['license:other']},
    'locked/stuff': {'gated': 'manual', 'tags': ['license:cc-by-4.0']},
}


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
        return True

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

    def central(self, u):
        # GitHub's API and raw files, the dataset API, resolve/<commit>/
        if u.path == '/repos/%s/git/trees/main' % CREPO:
            tree = [{'path': 'README.md', 'type': 'blob'}, {'path': 'submissions', 'type': 'tree'},
                    {'path': 'submissions/acme', 'type': 'tree'}, {'path': 'submissions/README.md', 'type': 'blob'}]
            tree += [{'path': 'submissions/' + d, 'type': 'blob'} for d in sorted(INDEX)]
            return self.send(200, json.dumps({'sha': 'x', 'tree': tree, 'truncated': False}).encode())
        pre = '/%s/main/submissions/' % CREPO
        if u.path.startswith(pre):
            d = u.path[len(pre):]
            return self.send(200, INDEX[d].encode(), 'text/plain') if d in INDEX else self.send(404, b'404')
        p = u.path.split('/')
        if len(p) == 5 and p[1] == 'api' and p[2] == 'datasets':
            d = p[3] + '/' + p[4]
            return self.send(200, json.dumps(dict(INFO[d], id=d)).encode()) if d in INFO else self.send(404, b'{}')
        if len(p) > 7 and p[1] == 'datasets' and p[4] == 'resolve' and p[5] != 'main':
            d, rev, folder = p[2] + '/' + p[3], p[5], p[6]
            if REVS.get((d, folder)) != rev:
                return self.send(404, b'not at that commit', 'text/plain')
            f = os.path.join(CENTRAL, d, *p[6:])
            return self.send(200, open(f, 'rb').read(), 'application/octet-stream') if os.path.isfile(f) \
                else self.send(404, b'{}')
        return None

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        LOG.append(('GET', u.path))
        if self.central(u):
            return
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


def make_central(root):
    """Three datasets in SimReady's package layout, each asset with its bill of
    materials; the index files pin each asset to a commit."""
    global CENTRAL
    CENTRAL = root
    crate = os.path.join(HUB, 'crate_test_a01', 'simready_usd')
    table = os.path.join(HUB, 'table_test_b02', 'simready_usd')
    png = os.path.join(crate, '.thumbs', '256x256', 'sm_crate_test_a01_01.usd.png')

    def asset(d, folder, rev, files):
        # files: (path in the folder, source file); the bill of materials lists them
        base = os.path.join(root, d, folder)
        items = []
        for rel, src in files:
            os.makedirs(os.path.dirname(os.path.join(base, rel)), exist_ok=True)
            shutil.copyfile(src, os.path.join(base, rel))
            items.append({'relative_path': rel, 'size': os.path.getsize(src), 'hash': {'sha256': 'x'}})
        os.makedirs(os.path.join(base, '.metadata'), exist_ok=True)
        json.dump({'format_version': '1.0', 'items': items},
                  open(os.path.join(base, '.metadata', 'com.nvidia.simready.packaging.bom.json'), 'w'), indent=2)
        REVS[(d, folder)] = rev
        return 'https://huggingface.co/datasets/%s/resolve/%s/%s/com.nvidia.simready.packaging.json\n' % (d, rev, folder)

    usd = os.path.join(crate, 'sm_crate_test_a01_01.usd')
    INDEX['acme/props'] = (
        'https://huggingface.co/datasets/acme/props/resolve/0ld0000/crate/com.nvidia.simready.packaging.json\n'
        + asset('acme/props', 'crate', 'aaaa1111', [
            ('simready_usd/.thumbs/256x256/crate.usd.png', png), ('simready_usd/crate.usd', usd),
            ('simready_usd/OmniPBR.mdl', os.path.join(crate, 'OmniPBR.mdl')),
            ('simready_usd/source_assets/huge.bin', os.path.join(crate, 'source_assets', 'huge.bin'))])
        + '\n# a comment, and a line that is no package\nhello\n'
        + asset('acme/props', 'table_b', 'bbbb2222', [         # legs.usda first: the thumbnail picks the root
            ('simready_usd/legs.usda', os.path.join(table, 'legs.usda')),
            ('simready_usd/over.usda', os.path.join(table, 'over.usda')),
            ('simready_usd/parts.usdc', os.path.join(table, 'parts.usdc')),
            ('simready_usd/sm_table_test_b02_01.usda', os.path.join(table, 'sm_table_test_b02_01.usda')),
            ('simready_usd/tex/check.png', os.path.join(table, 'tex', 'check.png')),
            ('simready_usd/tex/orm.png', os.path.join(table, 'tex', 'orm.png')),
            ('simready_usd/.thumbs/1024x1024/sm_table_test_b02_01.usda.png', png)]))
    INDEX['beta/kit'] = asset('beta/kit', 'crate', 'cccc3333', [   # no thumbnail: the first USD
        ('README.md', os.path.join(HUB, 'noroot_x01', 'stuff', 'readme.txt')),
        ('simready_usd/crate.usd', usd)])
    INDEX['closed/stuff'] = asset('closed/stuff', 'secret', 'dddd4444', [('simready_usd/a.usd', usd)])
    INDEX['locked/stuff'] = asset('locked/stuff', 'secret2', 'eeee5555', [('simready_usd/a.usd', usd)])
    INDEX['nvidia/simready-assets'] = asset('nvidia/simready-assets', 'crate_test_a01', 'ffff6666',
                                            [('simready_usd/a.usd', usd)])


def central(home, port):
    print('-- SimReady Central --')
    cache = os.path.join(home, 'BeeModel', 'cache', 'central')
    cat = os.path.join(cache, 'catalog.tsv')
    rows = lambda: [l.split('\t') for l in open(cat).read().splitlines()] if os.path.exists(cat) else []
    LOG.clear()
    rc, out = run(home, 'op("lib.source", "central")', port)
    got = [(r[0], r[2], r[3], r[4], r[5], r[6]) for r in rows()]
    want = [('crate', 'acme', 'acme/props', 'aaaa1111', 'crate', 'cc-by-4.0'),
            ('table_b', 'acme', 'acme/props', 'bbbb2222', 'table_b', 'cc-by-4.0'),
            ('crate_beta', 'beta', 'beta/kit', 'cccc3333', 'crate', 'apache-2.0')]
    check(rc == 0 and got == want,
          'the index read: open, public datasets; a later commit kept; a folder taken: <folder>_<owner> (%s)' % got)
    asked = [p for m, p in LOG]
    check(sum(p == '/repos/%s/git/trees/main' % CREPO for p in asked) == 1
          and not any('submissions/closed' in p or 'submissions/locked' in p for p in asked)
          and '/api/datasets/locked/stuff' in asked and '/api/datasets/closed/stuff' in asked
          and not any('nvidia/simready-assets' in p for p in asked),
          'left out: a gated dataset, one under "other", nvidia/simready-assets (a source of its own)')
    LOG.clear()
    rc, out = run(home, 'op("lib.source", "central")', port)
    check(rc == 0 and not LOG, 'the next time: catalog.tsv read, the server not asked (%d requests)' % len(LOG))

    def place(asset, xyz='0 0 0'):
        LOG.clear()
        code = ('op("lib.source", "central")\nn = count()\nfor i in 0..n { delete(name(0)) }\n'
                'op("lib.get", "%s %s")\nprint("N", count())\n'
                'for i in 0..count() { o = name(i)\n print("OB", o, get(o, "x"), get(o, "y"), get(o, "z"), rigid(o, "type"), matof(o)) }'
                % (asset, xyz))
        rc, out = run(home, code, port)
        obs = {l.split()[1]: l.split()[2:] for l in out.splitlines() if l.startswith('OB ')}
        fetched = sorted(p.split('/resolve/', 1)[1] for m, p in LOG if '/resolve/' in p)
        return rc, obs, fetched

    rc, obs, fetched = place('crate', '2 0 -1')
    check(fetched == ['aaaa1111/crate/.metadata/com.nvidia.simready.packaging.bom.json',
                      'aaaa1111/crate/simready_usd/crate.usd'],
          'placing: its package at its commit, then only what an import needs (%s)' % fetched)
    box = obs.get('Box')
    check(rc == 0 and box is not None and abs(float(box[0]) - 2) < 1e-4 and abs(float(box[2]) + 1) < 1e-4
          and box[3] == '1' and len(obs) == 4, 'placed at 2 0 -1 with its bodies (Box at %s; %d objects)' % (box, len(obs)))
    r = {x[0]: x for x in rows()}
    check(r.get('crate', [''] * 8)[1] == 'crate/simready_usd/crate.usd'
          and r['crate'][7] == 'simready_usd/.thumbs/256x256/crate.usd.png',
          'its root and thumbnail kept in the catalog (%s)' % r.get('crate'))
    rc, obs, fetched = place('crate', '2 0 -1')
    check(rc == 0 and fetched == [] and 'Box' in obs, 'a second lib.get: placed again, nothing fetched')
    rc, obs, fetched = place('table_b')
    check(rc == 0 and len(obs) == 7 and obs.get('Top', [''] * 5)[4] == 'Wood'
          and 'bbbb2222/table_b/simready_usd/sm_table_test_b02_01.usda' in fetched
          and r.get('table_b') is not None and rows()[1][1] == 'table_b/simready_usd/sm_table_test_b02_01.usda',
          'the root: the USD its thumbnail shows (not the first one), sublayers and textures (%d objects, %s)'
          % (len(obs), rows()[1][1] if len(rows()) > 1 else '-'))
    rc, obs, fetched = place('crate_beta')
    check(rc == 0 and 'Box' in obs and 'cccc3333/crate/simready_usd/crate.usd' in fetched
          and not any('README' in f for f in fetched),
          'no thumbnail: the first USD in simready_usd/, from its own dataset (%s)' % fetched)
    idx = os.path.join(home, 'BeeModel', 'library', 'index.txt')
    lib = open(idx).read() if os.path.exists(idx) else ''
    check('central' in lib and 'acme' in lib, 'placed assets saved into the local library (#central #acme)')

    open(os.path.join(home, 'BeeModel', 'sources.txt'), 'w').write(
        'central mirror acme/index-mirror  A Mirror\n'
        'simready long PalatialSim/palatial-nv-asset-library Long Name\n')
    LOG.clear()
    run(home, 'op("lib.source", "mirror")\nop("lib.source", "long")', port)
    asked = [p for m, p in LOG]
    check('/repos/acme/index-mirror/git/trees/main' in asked
          and '/api/datasets/PalatialSim/palatial-nv-asset-library/tree/main' in asked,
          'sources.txt: a central kind source, and a long dataset name in full')
    os.remove(os.path.join(home, 'BeeModel', 'sources.txt'))


def run(home, code, port):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='', BEEMODEL_HF_URL='http://127.0.0.1:%d' % port,
               BEEMODEL_GH_URL='http://127.0.0.1:%d' % port)
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

        idx = os.path.join(home, 'BeeModel', 'library', 'index.txt')
        lib = open(idx).read() if os.path.exists(idx) else ''
        check('crate_test_a01' in lib and 'simready' in lib and 'crate' in lib,
              'placed assets saved into the local library (#simready #crate)')

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
        os.remove(os.path.join(home, 'BeeModel', 'sources.txt'))
        make_central(os.path.join(home, 'central-hub'))
        central(home, port)
        gui(port)
    finally:
        srv.shutdown()
        shutil.rmtree(home, ignore_errors=True)


def gui(port):
    print('-- the Asset Browser --')
    import time
    os.environ['BEEMODEL_HF_URL'] = 'http://127.0.0.1:%d' % port
    os.environ['BEEMODEL_GH_URL'] = 'http://127.0.0.1:%d' % port
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
    argv = sys.argv
    sys.argv = [sys.argv[0], tempfile.mkdtemp(prefix='bee-extlib-shots-')]
    import fakewl
    sys.argv = argv
    fakewl.BIN = BIN
    f = fakewl.Fake()
    try:
        f.pump(1.0, until_frame=True)
        m = fakewl.Mcp(f)
        q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
        f.enter(600, 700)
        f.move(600, 700)                            # the console area: the browser
        f.pump(0.3)
        q('op("area.type_asset_browser")')
        q('op("lib.source", "simready")')
        thumb = os.path.join(f.home, 'BeeModel', 'cache', 'simready', 'thumbs', 'crate_test_a01.png')
        t0, tile = time.time(), None
        while time.time() - t0 < 20 and tile is None:
            f.pump(0.3)
            img = f.image().convert('RGB')
            px = img.load()
            for y in range(560, img.height, 3):         # the green thumbnail
                for x in range(0, img.width, 3):
                    if px[x, y] == (30, 160, 90):
                        tile = (x, y)
                        break
                if tile:
                    break
        check(os.path.exists(thumb) and tile is not None,
              'the catalog came in the background, the tile showed its thumbnail (at %s)' % (tile,))
        n0 = int(q('print(count())') or 0)
        if tile:
            f.click(tile[0] + 10, tile[1] + 10)
            f.click(tile[0] + 10, tile[1] + 10)
        t0, n = time.time(), n0
        while time.time() - t0 < 20 and n == n0:
            f.pump(0.3)
            n = int(q('print(count())') or n0)
        check(n == n0 + 4 and q('print(rigid("Box", "type"))') == '1',
              'a double-click downloaded and placed it (%d objects, its bodies)' % (n - n0))
        f.wheel(1)
        f.wheel(-1)
        before = q('op("lib.sources")\nprint(1)')
        hdr = (tile[0] + 4, tile[1] - 30) if tile else (20, 600)
        check(f.proc.poll() is None, 'scrolled; BeeModel still runs')
        q('op("lib.source", "central")')
        thumb = os.path.join(f.home, 'BeeModel', 'cache', 'central', 'thumbs', 'crate.png')
        t0 = time.time()
        while time.time() - t0 < 20 and not os.path.exists(thumb):
            f.pump(0.3)
        check(os.path.exists(thumb) and f.proc.poll() is None,
              'SimReady Central in the browser: a tile\'s thumbnail came through its package')
    finally:
        f.proc.kill()


main()
if FAILS:
    print('extlib: %d failed' % len(FAILS))
    sys.exit(1)
print('extlib: all checks passed')
