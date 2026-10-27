#!/usr/bin/env python3
"""Image to 3D (the Hi3D addon), with no GPU and no models: the stand-in
helper (tests/hi3d_standin.py) answers as addons/hi3d/bee_hi3d.py does. In a
window (the fake compositor):

  - without the addon, the console says how to install it;
  - object.from_image runs the helper with the image and the detail (512
    when not given) while the window goes on; the status bar shows how far
    it is; its mesh comes in named after the image, standing on the 3D
    cursor, as one undo step; everything it said is in hi3d.log;
  - object.refine_from_image sends the active mesh (alone, in world space)
    as the rough shape: the refined mesh takes its place and size, the
    original is hidden; an image name with spaces and a detail of 1024;
  - an error is reported with the helper's own words; a helper that dies
    without a word too;
  - one at a time; the status bar chip stops it;
  - Add > Generate and Object have the operators; only the stop is open
    to the AI.

    python3 tests/hi3d.py build/beemodel [outdir]
"""
import json, os, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def main():
    home = tempfile.mkdtemp(prefix='bee-hi3d-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    os.environ.pop('BEEMODEL_HI3D', None)
    for n in ('chair.png', 'my photo.png', 'fail.png', 'crash.png', 'slow.png'):
        with open(os.path.join(home, n), 'wb') as f:
            f.write(b'\x89PNG\r\n\x1a\n')          # (only the helper reads it)
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-hi3d-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    fakewl.BIN = BIN
    f = fakewl.Fake(home=home)
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    cube = fakewl.project((0, 1, 0))
    f.enter(*cube)
    f.move(*cube)
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    num = lambda code: float(q('print(%s)' % code) or 'nan')

    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.key(1); f.pump(0.2)

    def wait_log(text, secs=20):                   # (console lines show as toasts)
        end = time.time() + secs
        while time.time() < end:
            if text in (fakewl.widget(m, 'status.toast') or {}).get('label', ''):
                return True
            f.pump(0.1)
        return False

    def args():
        try:
            return json.load(open(os.path.join(home, 'hi3d-args.json')))
        except (OSError, ValueError):
            return []

    def chip():
        return fakewl.widget(m, 'status.hi3d') is not None

    print('  -- without the addon --')
    cmd(f'object.from_image {home}/chair.png')
    check(wait_log('Image to 3D is an addon: install it with addons/hi3d/install.sh', 5),
          'without the helper, the console says how to install the addon')

    hdir = os.path.join(home, '.local', 'share', 'beemodel', 'hi3d')
    os.makedirs(hdir)
    os.symlink(os.path.join(HERE, 'hi3d_standin.py'), os.path.join(hdir, 'bee-hi3d'))

    print('  -- a model from an image --')
    n0 = num('count()')
    cmd(f'object.from_image {home}/chair.png')
    seen = False
    end = time.time() + 5
    while time.time() < end and not seen:
        f.pump(0.1)
        seen = chip()
    check(seen, 'the status bar shows it at work while the window goes on')
    check(wait_log('Image to 3D made chair'), 'it comes in named after the image')
    a = args()
    check(a[:5] == ['run', '--image', f'{home}/chair.png', '--out', f'{home}/cache/beemodel/hi3d/chair.obj']
          and a[5:] == ['--resolution', '512'],
          f'the helper got the image, a file in ~/.cache/beemodel/hi3d and detail 512 ({a})')
    check(num('count()') == n0 + 1 and num('verts("chair")') == 6 and num('faces("chair")') == 8,
          'the helper\'s mesh is an object of its own')
    ys = [num(f'vpos("chair", {i}, "y")') + num('get("chair", "y")') for i in range(6)]
    check(abs(min(ys)) < 1e-4 and abs(max(ys) - 2) < 1e-4 and abs(num('get("chair", "x")')) < 1e-6,
          f'standing on the 3D cursor, two units tall (y {min(ys):.2f} .. {max(ys):.2f})')
    check(not chip(), 'the chip goes when it is done')
    log = open(os.path.join(home, 'cache', 'beemodel', 'hi3d', 'hi3d.log')).read()
    check('a library warning on stderr' in log and '@bee done' in log, 'hi3d.log keeps all it said')
    m.tool('undo')
    f.pump(0.2)
    check(num('count()') == n0, 'one undo step takes it away')

    print('  -- refining the active mesh --')
    q('select("Cube")')
    cmd(f'object.refine_from_image {home}/my photo.png 1024')
    check(wait_log('Image to 3D made my photo'), 'the refined mesh comes in (an image name with a space)')
    a = args()
    co = a[a.index('--coarse') + 1] if '--coarse' in a else ''
    vs = [ln for ln in open(co)] if co and os.path.exists(co) else []
    vs = [list(map(float, ln.split()[1:4])) for ln in vs if ln.startswith('v ')]
    check(a[a.index('--image') + 1] == f'{home}/my photo.png' and a[a.index('--resolution') + 1] == '1024'
          and len(vs) == 8 and min(v[1] for v in vs) == 0 and max(v[1] for v in vs) == 2,
          f'the helper got the cube alone, in world space, as the rough mesh, and detail 1024 ({len(vs)} vertices)')
    xs = [num(f'vpos("my photo", {i}, "x")') + num('get("my photo", "x")') for i in range(6)]
    ys = [num(f'vpos("my photo", {i}, "y")') + num('get("my photo", "y")') for i in range(6)]
    check(abs(min(xs) + 1) < 1e-4 and abs(max(xs) - 1) < 1e-4 and abs(min(ys)) < 1e-4 and abs(max(ys) - 2) < 1e-4,
          'it takes the rough mesh\'s place and size')
    check(num('get("Cube", "hidden")') == 1 and num('get("my photo", "hidden")') == 0,
          'the rough mesh is hidden, the refined one shown')
    m.tool('undo')
    f.pump(0.2)
    check(num('get("Cube", "hidden")') == 0, 'undo shows the rough mesh again')

    print('  -- when it goes wrong --')
    cmd(f'object.from_image {home}/fail.png')
    check(wait_log('Image to 3D failed: the GPU ran out of memory: try a lower detail or Offload'),
          'an error is reported in the helper\'s words')
    cmd(f'object.from_image {home}/crash.png')
    check(wait_log('Image to 3D failed: the helper ended without a mesh'), 'and a helper that dies without a word')
    cmd(f'object.from_image {home}/missing.png')
    check(wait_log('Image to 3D: cannot read the image', 5), 'an image that is not there')
    cmd('object.from_image')
    check(wait_log('object.from_image <image file> [512 | 1024 | 1536]', 5), 'no image: how to use it')

    print('  -- one at a time, and stopping --')
    n0 = num('count()')
    cmd(f'object.from_image {home}/slow.png')
    w = None
    end = time.time() + 5
    while time.time() < end and not w:
        f.pump(0.1)
        w = fakewl.widget(m, 'status.hi3d')
    cmd(f'object.from_image {home}/chair.png')
    check(wait_log('Image to 3D: one is being made', 5), 'a second one waits for the first')
    w = fakewl.widget(m, 'status.hi3d')
    if w:
        f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
    check(bool(w) and wait_log('Image to 3D: stopped', 10), 'clicking the chip stops it')
    f.pump(0.5)
    check(num('count()') == n0 and not chip(), 'nothing comes in; the chip is gone')

    print('  -- menus and the AI --')
    tools = {t['name'] for t in (m.call('tools/list') or {}).get('result', {}).get('tools', [])}
    check('op_object_from_image_stop' in tools and 'op_object_from_image' not in tools
          and 'op_object_refine_from_image' not in tools,
          'the AI may stop one, not start one (a long GPU job reading files)')
    ok = fakewl.menu_pick(f, m, 'Add', 'Generate', 'Model from Image (Hi3D)...')
    f.pump(0.3)
    check(ok, 'Add > Generate > Model from Image (Hi3D)...')
    f.key(1); f.pump(0.2)
    check(fakewl.menu_pick(f, m, 'Object', 'Refine from Image (Hi3D)...'), 'Object > Refine from Image (Hi3D)...')
    f.key(1); f.pump(0.2)

    f.proc.kill()
    print(f'{len(FAILS)} failed' if FAILS else 'all passed')
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
