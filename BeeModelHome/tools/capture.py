#!/usr/bin/env python3
"""Screenshots for the website, taken from BeeModel itself.

Each shot runs BeeModel in the test suite's fake Wayland compositor
(tools/fakewl.py: no window, no GPU needed), builds a scene with BeeScript
over MCP, arranges the UI and saves the frame to media/shots/<name>.png.

  python3 BeeModelHome/tools/capture.py [build/beemodel] [shot ...]
"""
import os
import re
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
OUT = os.path.join(HERE, '..', 'media', 'shots')
args = sys.argv[1:]
BIN = os.path.abspath(args.pop(0)) if args and not args[0].isidentifier() else os.path.join(ROOT, 'build', 'beemodel')
ONLY = set(args)

sys.path.insert(0, os.path.join(ROOT, 'tools'))
_argv = sys.argv
sys.argv = [sys.argv[0], tempfile.mkdtemp(prefix='bee-site-')]
import fakewl                                               # noqa: E402
sys.argv = _argv
fakewl.BIN = BIN
SIZE = (1600, 1000)


def bees(name, drop=r'render\(|file\.save|file\.export|image\.save|lightmap|op\("lib\.'):
    """A walkthrough scene, without its renders and file writes."""
    text = open(os.path.join(ROOT, 'tests', name)).read()
    return '\n'.join(l for l in text.splitlines() if not re.search(drop, l))


class Session:
    def __init__(self):
        self.f = fakewl.Fake()
        self.f.pump(2.0, until_frame=True)
        self.f.configure(*SIZE)
        self.f.pump(1.0)
        self.m = fakewl.Mcp(self.f)
        self.f.enter(800, 400)
        self.f.move(800, 400)
        self.q('op("view.toggle_console")')          # (more room for the viewport)

    def q(self, code, timeout=30):
        r = self.m.call('tools/call', {'name': 'script_eval', 'arguments': {'code': code}}, timeout=timeout)
        res = (r or {}).get('result', {})
        text = res.get('content', [{}])[0].get('text', '')
        if res.get('isError') or r is None:
            print('  script:', (text or 'timed out')[:200])
        return (text or '').strip()

    def op(self, name, arg=''):
        return self.q('op("%s", "%s")' % (name, arg))

    def menu(self, *path):
        return fakewl.menu_pick(self.f, self.m, *path)

    def click(self, name, sub=0):
        x, y = fakewl.widget_xy(self.m, name, sub)
        if x:
            self.f.click(x, y)
            self.f.pump(0.3)
        return bool(x)

    def tab(self, name):
        fakewl.props_tab(self.m, self.f, name)

    def shot(self, name, settle=1.5):
        self.f.move(SIZE[0] - 5, SIZE[1] - 5)      # (no hover highlight)
        self.f.pump(settle)
        img = self.f.image()
        os.makedirs(OUT, exist_ok=True)
        img.save(os.path.join(OUT, name + '.png'))
        print('  shot', name, img.size, flush=True)

    def close(self):
        self.f.proc.kill()


SHOTS = []


def shot(fn):
    SHOTS.append(fn)
    return fn


@shot
def modeling(s):
    """The studio scene in Material Preview, its material in Properties."""
    s.q(bees('product_shot.bees'))
    s.op('view.shading_material')
    s.q('select("Paint")\nview(18, 14, 11, 0, 1.3, 0)')
    s.tab('material')
    s.shot('modeling')


@shot
def nodes(s):
    """The stone material's node graph (Shading workspace)."""
    s.q(bees('product_shot.bees'))
    s.q('select("Plinth")')
    s.op('workspace.set', 'Shading')
    s.f.pump(1.0)
    s.op('view.shading_material')
    s.q('view(25, 20, 7, 0, 1, 0)')
    s.shot('nodes')


@shot
def cad(s):
    """The parametric enclosure in the CAD workspace."""
    s.q(bees('enclosure.bees'), timeout=120)
    s.op('workspace.set', 'CAD')
    s.f.pump(1.0)
    s.q('view(35, 30, 260, 40, 15, 25)')
    s.shot('cad', settle=2.5)


@shot
def sculpt(s):
    """The sculpted stone head."""
    s.q(bees('sculpt_paint.bees'), timeout=240)
    s.q('op("object.sculpt_mode")\nop("object.select_all")\nselect("Head")\nop("object.select_all")')
    s.op('view.shading_material')
    s.q('view(25, 12, 4.2, 0, 0.45, 0)')
    s.shot('sculpt', settle=2.5)


@shot
def procedural(s):
    """The procedural valley: geometry nodes, erosion, scattering, L-systems."""
    s.q(bees('procedural.bees'), timeout=300)
    s.op('view.shading_material')
    s.q('view(30, 28, 70, 0, 0, 0)')
    s.shot('procedural', settle=4.0)


@shot
def fields(s):
    """A tornado lifting boxes, its streamlines shown."""
    s.q('''delete("Cube")
op("create.ground")
op("field.add_tornado")
move("Tornado", 0, 0, 0)
seed(4)
for i in 0..60 {
  add("cube", "Box" + i, rand() * 10 - 5, 0.3 + rand() * 4, rand() * 10 - 5)
  scale("Box" + i, 0.15 + rand() * 0.2)
  rotate("Box" + i, rand() * 3, rand() * 3, rand() * 3)
  select("Box" + i)
  op("rigid.add", "active box")
}
add("sphere", "Probe", 3, 0.5, 0)
scale("Probe", 0.4)
select("Probe")
op("view.field_lines")
frame(40)
view(25, 18, 22, 0, 2.5, 0)''', timeout=120)
    s.op('view.shading_material')
    s.tab('physics')
    s.shot('fields', settle=2.5)


@shot
def landscape(s):
    """The island preset: eroded, painted by slope and height, a sea."""
    s.q('''delete("Cube")
op("landscape.add", "island size 200 seed 3")
op("landscape.layer", "set 0 height 62")
op("landscape.paint", "add sand colour 0.78 0.69 0.5")
op("landscape.paint", "add grass colour 0.22 0.42 0.12 friction 0.7")
op("landscape.paint", "add rock colour 0.36 0.33 0.3 friction 0.8")
op("landscape.paint", "add snow colour 0.95 0.95 0.97")
op("landscape.paint_auto")''', timeout=120)
    s.tab('landscape')
    s.op('view.shading_material')
    s.q('op("object.select_all")\nview(35, 24, 230, 0, 0, 0)')
    s.shot('landscape', settle=3.0)


@shot
def animation(s):
    """The animation walkthrough: a walk cycle, gears, a heap, cloth."""
    s.q(bees('animation.bees', drop=r'render\(|file\.save|sim\.bake|frame\('), timeout=300)
    s.op('workspace.set', 'Animation')
    s.f.pump(1.0)
    s.q('frame(60)\nview(30, 15, 14, 0, 1, 0)', timeout=300)
    s.shot('animation', settle=3.0)


@shot
def physics(s):
    """The wrecking ball demo, mid-swing."""
    demo = open(os.path.join(ROOT, 'Vibecoding', 'demos', 'wrecking-ball.bees')).read()
    s.q(demo, timeout=300)
    s.q('frame(70)', timeout=300)
    s.op('view.shading_material')
    s.tab('physics')
    s.shot('physics', settle=3.0)


def main():
    for fn in SHOTS:
        if ONLY and fn.__name__ not in ONLY:
            continue
        print('--', fn.__name__, flush=True)
        t = time.time()
        s = Session()
        try:
            fn(s)
        except Exception as e:                      # (the next shot still runs)
            print('  failed:', e)
        finally:
            s.close()
        print('  %.0f s' % (time.time() - t))


if __name__ == '__main__':
    main()
