#!/usr/bin/env python3
# Dev-time helper only (NOT needed to build): draws BeeModel's UI icons from
# the small vector definitions below and writes src/icons.inc - one 16x16
# alpha mask per icon, 4 bits a pixel (two pixels a byte, left pixel in the
# low nibble), plus ICON_* ids. The UI tints a mask with a theme colour
# (shapes.s draw_icon). Run: python3 tools/genicons.py [--preview out.png]
#
# Coordinates are in a 16 x 16 box, y down; shapes:
#   L x0 y0 x1 y1 [w]      line (stroke width w, default 1.5)
#   P x0 y0 x1 y1 ... [w]  polyline        Z ... closed polyline
#   F x0 y0 x1 y1 ...      filled polygon
#   R x y w h              filled rectangle    B x y w h [w]  rectangle outline
#   C cx cy r              filled circle       O cx cy r [w]  ring
#   A cx cy r a0 a1 [w]    arc, degrees, clockwise from 3 o'clock (y down)
#   E cx cy rx ry [a0 a1 [w]]  ellipse outline (or an arc of it)
#   G cx cy rx ry          filled ellipse
#   -<shape>               erase it from what was drawn so far
import math, sys

ICONS = {
    # ---- object types ---------------------------------------------------------
    'mesh':      ['Z 8 1.5 14 5 14 11 8 14.5 2 11 2 5', 'P 2 5 8 8.5 14 5', 'L 8 8.5 8 14.5'],
    'light':     ['C 8 6.5 4', 'R 6 11 4 1.5', 'R 6.5 13 3 1.5'],
    'camera':    ['B 1.5 4.5 9 7', 'F 11 7 14.5 4.5 14.5 11.5 11 9'],
    'curve':     ['P 2 13 3 8 6 4 10 4 13 7 14 3 2', 'C 2 13 1.4', 'C 14 3 1.4'],
    'armature':  ['C 4 12 2.4', 'C 12 4 2.4', 'F 4.5 10 10 4.6 11.4 6 6 11.5'],
    'sketch':    ['B 2 2 12 12 1.2', 'L 5 11 11 5', 'C 5 11 1.3', 'C 11 5 1.3'],
    'empty':     ['L 8 2 8 14', 'L 2 8 14 8', 'L 4 4 12 12 1', 'L 12 4 4 12 1'],
    'group':     ['B 1.5 3.5 9 9', 'B 5.5 1.5 9 9'],
    # ---- primitives -------------------------------------------------------------
    'cube':      ['Z 8 1.5 14 5 14 11 8 14.5 2 11 2 5', 'P 2 5 8 8.5 14 5', 'L 8 8.5 8 14.5'],
    'sphere':    ['O 8 8 6 1.4', 'E 8 8 6 2.2 0 180 1', 'E 8 8 2.4 6 -90 90 1'],
    'cylinder':  ['E 8 4 5.5 2 0 360 1.4', 'L 2.5 4 2.5 12', 'L 13.5 4 13.5 12', 'E 8 12 5.5 2 0 180 1.4'],
    'cone':      ['L 8 1.5 2.5 12', 'L 8 1.5 13.5 12', 'E 8 12 5.5 2 0 180 1.4', 'E 8 12 5.5 2 180 360 0.9'],
    'torus':     ['E 8 8 6.5 4.2 0 360 1.5', 'E 8 7.5 2.6 1.4 0 360 1.3'],
    'plane':     ['Z 1.5 10 6 5 14.5 5 10 10'],
    'grid':      ['B 2 2 12 12 1.2', 'L 6 2 6 14 1', 'L 10 2 10 14 1', 'L 2 6 14 6 1', 'L 2 10 14 10 1'],
    # ---- tools --------------------------------------------------------------------
    'select':    ['F 3 2 3 13 6 10.5 8.5 15 10.5 14 8 9.5 12.5 9.5'],
    'move':      ['L 8 2 8 14', 'L 2 8 14 8', 'F 8 0.8 10.5 3.5 5.5 3.5', 'F 8 15.2 10.5 12.5 5.5 12.5',
                  'F 0.8 8 3.5 5.5 3.5 10.5', 'F 15.2 8 12.5 5.5 12.5 10.5'],
    'rotate':    ['A 8 8 5.5 200 520 1.6', 'F 14.5 3 13.8 8 10 5.5'],
    'scale':     ['B 2 6 8 8 1.4', 'L 7 9 13.5 2.5', 'F 14.5 1.5 14.5 6.5 9.5 1.5'],
    'cursor':    ['O 8 8 4.5 1.4', 'L 8 1 8 5', 'L 8 11 8 15', 'L 1 8 5 8', 'L 11 8 15 8'],
    'measure':   ['F 1 10 10 1 15 6 6 15', '-L 4 9 5.5 10.5 1', '-L 6.5 6.5 8 8 1', '-L 9 4 10.5 5.5 1'],
    'extrude':   ['B 2 9 12 5 1.4', 'L 8 9 8 2', 'F 8 0.8 11 4 5 4'],
    'inset':     ['B 1.5 1.5 13 13 1.3', 'B 5 5 6 6 1.3', 'L 1.5 1.5 5 5 1', 'L 14.5 1.5 11 5 1',
                  'L 1.5 14.5 5 11 1', 'L 14.5 14.5 11 11 1'],
    'bevel':     ['P 2 14 2 7 7 2 14 2', 'L 4 14 4 8.5 1', 'L 8.5 4 14 4 1'],
    'loopcut':   ['B 1.5 3 13 10 1.3', 'L 8 1 8 15 1.6'],
    'knife':     ['F 2 14 11 3 14 2 13 6 4 15', 'L 10 4 12 6 0.8'],
    'brush':     ['F 9 1 15 7 9 11 5 7', 'F 4.5 8 8 11.5 4 15 1 15 1 12'],
    'paint':     ['F 9 1 15 7 9 11 5 7', 'C 3.5 12.5 2.5'],
    'weight':    ['F 4 6 12 6 14.5 14.5 1.5 14.5', 'O 8 3.5 2 1.4'],
    'pose':      ['C 8 3 2', 'L 8 5 8 10', 'L 8 10 5 15', 'L 8 10 11 15', 'L 3 6 13 6'],
    # ---- modes ----------------------------------------------------------------------
    'object':    ['B 2 2 12 12 1.4', 'C 8 8 1.6'],
    'edit':      ['Z 3 3 13 3 13 13 3 13 1', 'C 3 3 1.8', 'C 13 3 1.8', 'C 13 13 1.8', 'C 3 13 1.8'],
    'sculpt':    ['A 8 11 6 180 360 1.6', 'L 2 11 14 11', 'C 8 6 2'],
    # ---- area header ----------------------------------------------------------------
    'close':     ['L 3.5 3.5 12.5 12.5 1.6', 'L 12.5 3.5 3.5 12.5 1.6'],
    'split_h':   ['B 1.5 2.5 13 11 1.3', 'L 8 2.5 8 13.5 1.3'],
    'split_v':   ['B 1.5 2.5 13 11 1.3', 'L 1.5 8 14.5 8 1.3'],
    'maximize':  ['B 1.5 2.5 13 11 1.3', 'R 1.5 2.5 13 3'],
    # ---- visibility, state ----------------------------------------------------------
    'eye':       ['E 8 8 6.8 4.2 0 360 1.4', 'C 8 8 2.3'],
    'eye_off':   ['E 8 8 6.8 4.2 0 360 1.4', 'C 8 8 2.3', '-L 2 14 14 2 3.2', 'L 2.5 13.5 13.5 2.5 1.4'],
    'lock':      ['R 3 7 10 7.5', 'A 8 7 3.3 180 360 1.6', 'L 4.7 7 4.7 5', 'L 11.3 7 11.3 5'],
    'unlock':    ['R 3 7 10 7.5', 'A 11 5 3.3 180 360 1.6'],
    'render_on': ['B 1.5 4.5 9 7', 'F 11 7 14.5 4.5 14.5 11.5 11 9'],
    # ---- shading ----------------------------------------------------------------------
    'wire':      ['O 8 8 6 1.2', 'E 8 8 6 2.2 0 180 1', 'E 8 8 2.4 6 -90 90 1'],
    'solid':     ['C 8 8 6.2'],
    'material':  ['C 8 8 6.2', '-C 6 6 2.3', 'O 8 8 6.2 1'],
    'rendered':  ['C 8 8 6.2', '-A 8 8 4 200 340 1.6'],
    'overlays':  ['O 6 8 4.5 1.4', 'O 10 8 4.5 1.4'],
    # ---- playback -------------------------------------------------------------------
    'play':      ['F 4 2 13 8 4 14'],
    'pause':     ['R 3.5 2.5 3.5 11', 'R 9 2.5 3.5 11'],
    'stop':      ['R 3 3 10 10'],
    'first':     ['R 2.5 2.5 2 11', 'F 13.5 2.5 13.5 13.5 5 8'],
    'last':      ['R 11.5 2.5 2 11', 'F 2.5 2.5 2.5 13.5 11 8'],
    'prev':      ['F 8 2.5 8 13.5 1.5 8', 'F 14.5 2.5 14.5 13.5 8 8'],
    'next':      ['F 8 2.5 8 13.5 14.5 8', 'F 1.5 2.5 1.5 13.5 8 8'],
    'key':       ['F 8 1.5 14.5 8 8 14.5 1.5 8'],
    'key_off':   ['Z 8 2 14 8 8 14 2 8 1.4'],
    'record':    ['C 8 8 5.5'],
    # ---- files ------------------------------------------------------------------------
    'file':      ['Z 3 1.5 10 1.5 13 4.5 13 14.5 3 14.5 1.3', 'P 10 1.5 10 4.5 13 4.5 1'],
    'folder':    ['F 1.5 3 6 3 7.5 4.5 14.5 4.5 14.5 13.5 1.5 13.5'],
    'folder_open': ['F 1.5 3 6 3 7.5 4.5 13 4.5 13 6.5 4 6.5 1.5 13.5', 'F 4.5 7.5 15 7.5 12.5 13.5 1.8 13.5'],
    'image':     ['B 1.5 2.5 13 11 1.3', 'F 2.5 12.5 6.5 7 9.5 10.5 11 9 13.5 12.5', 'C 11 5.5 1.5'],
    'save':      ['Z 2 2 12 2 14 4 14 14 2 14 1.3', 'R 4.5 2 6 4', 'R 4.5 9 7 5'],
    'open':      ['F 1.5 3 6 3 7.5 4.5 14.5 4.5 14.5 13.5 1.5 13.5', '-L 8 12 8 7.5 1.4', '-F 8 5.8 10.5 8.5 5.5 8.5'],
    'import':    ['B 1.5 9 13 5.5 1.3', 'L 8 1 8 10', 'F 8 11.5 11 8 5 8'],
    'export':    ['B 1.5 9 13 5.5 1.3', 'L 8 11 8 3', 'F 8 0.8 11 4.5 5 4.5'],
    # ---- status -----------------------------------------------------------------------
    'info':      ['O 8 8 6.5 1.4', 'R 7.2 7 1.6 5', 'C 8 4.8 1'],
    'warning':   ['F 8 1.5 15 14 1 14', '-R 7.2 5.5 1.6 4.5', '-C 8 11.8 0.95'],
    'error':     ['C 8 8 6.8', '-L 5.2 5.2 10.8 10.8 1.6', '-L 10.8 5.2 5.2 10.8 1.6'],
    'ok':        ['C 8 8 6.8', '-P 4.5 8.2 7 10.7 11.5 5.6 1.7'],
    # ---- misc -------------------------------------------------------------------------
    'search':    ['O 6.5 6.5 4.5 1.6', 'L 9.8 9.8 14 14 2'],
    'plus':      ['L 8 2.5 8 13.5 1.8', 'L 2.5 8 13.5 8 1.8'],
    'minus':     ['L 2.5 8 13.5 8 1.8'],
    'gear':      ['O 8 8 4.5 3', 'L 8 1 8 15 2.6', 'L 1 8 15 8 2.6', 'L 3 3 13 13 2.6', 'L 13 3 3 13 2.6',
                  '-C 8 8 2'],
    'undo':      ['A 8.5 9.5 5 180 450 1.6', 'F 1 9.5 6.5 9.5 3.75 5.5'],
    'redo':      ['A 7.5 9.5 5 90 360 1.6', 'F 15 9.5 9.5 9.5 12.25 5.5'],
    'snap':      ['A 8 7 4.5 180 360 2.4', 'L 3.5 7 3.5 11 2.4', 'L 12.5 7 12.5 11 2.4',
                  'R 2.3 11.5 2.4 2.5', 'R 11.3 11.5 2.4 2.5'],
    'pivot':     ['O 8 8 5.5 1.2', 'C 8 8 1.8', 'L 8 1 8 3.5 1.2', 'L 8 12.5 8 15 1.2'],
    'link':      ['E 5.5 10.5 2.6 3.6 0 360 1.5', 'E 10.5 5.5 2.6 3.6 0 360 1.5'],
    'sparkle':   ['F 8 1 9.5 6.5 15 8 9.5 9.5 8 15 6.5 9.5 1 8 6.5 6.5', 'F 13 1 13.7 2.3 15 3 13.7 3.7 13 5 12.3 3.7 11 3 12.3 2.3'],
    'users':     ['C 5.5 5 2.5', 'A 5.5 14 5 180 360', 'C 11.5 5.5 2', 'A 11.5 13.5 4 200 360 1.4'],
    'branch':    ['C 4.5 3 1.8', 'C 4.5 13 1.8', 'C 11.5 5 1.8', 'L 4.5 4 4.5 12', 'P 11.5 6.5 11.5 8 4.5 11'],
    'library':   ['B 1.5 4 13 10.5 1.3', 'L 1.5 4 4 1.5 1.3', 'L 14.5 4 12 1.5 1.3', 'L 4 1.5 12 1.5 1.3',
                  'R 6 7 4 1.5'],
    'node':      ['B 1.5 2 6 5 1.3', 'B 8.5 9 6 5 1.3', 'P 7.5 4.5 10 4.5 10 9 1.3'],
    'world':     ['O 8 8 6.5 1.3', 'E 8 8 3 6.5 0 360 1', 'L 1.5 8 14.5 8 1'],
    'physics':   ['C 8 4.5 3', 'A 8 14 5 180 360 1.4', 'L 8 7.5 8 10 1'],
    'modifier':  ['L 3 13 10 6 2.2', 'O 11.5 4.5 3 1.6', '-L 11.5 4.5 15 1 1.8'],
    'constraint': ['E 5.5 10.5 2.6 3.6 0 360 1.5', 'E 10.5 5.5 2.6 3.6 0 360 1.5'],
    'scene':     ['F 1 13 6 6 9 10 11 8 15 13'],
    'console':   ['B 1.5 2.5 13 11 1.3', 'P 4 6 6.5 8 4 10 1.3', 'L 8 10.5 12 10.5 1.3'],
    'palette':   ['B 1.5 2.5 13 11 1.3', 'L 4 6 12 6 1.2', 'L 4 9 10 9 1.2', 'L 4 12 8 12 0'],
    'chevron_down':  ['P 4 6 8 10 12 6 1.6'],
    'chevron_right': ['P 6 4 10 8 6 12 1.6'],
    'check':     ['P 3 8.5 6.5 12 13 4.5 1.9'],
    'dot':       ['C 8 8 3'],
}

N = 16
SS = 8                                  # samples per pixel per axis


def seg_dist(px, py, x0, y0, x1, y1):
    dx, dy = x1 - x0, y1 - y0
    l2 = dx * dx + dy * dy
    t = 0 if l2 == 0 else max(0, min(1, ((px - x0) * dx + (py - y0) * dy) / l2))
    qx, qy = x0 + t * dx, y0 + t * dy
    return math.hypot(px - qx, py - qy)


def in_poly(px, py, pts):
    inside = False
    j = len(pts) - 1
    for i in range(len(pts)):
        xi, yi = pts[i]; xj, yj = pts[j]
        if (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def shape_fn(spec):
    t, *a = spec.split()
    a = [float(v) for v in a]
    if t == 'L':
        x0, y0, x1, y1 = a[:4]; w = a[4] if len(a) > 4 else 1.5
        return lambda x, y: seg_dist(x, y, x0, y0, x1, y1) <= w / 2
    if t in ('P', 'Z'):
        n = len(a) // 2 * 2
        w = 1.5
        if len(a) % 2:
            w = a[-1]; n = len(a) - 1
        pts = [(a[i], a[i + 1]) for i in range(0, n, 2)]
        if t == 'Z': pts.append(pts[0])
        return lambda x, y: any(seg_dist(x, y, *pts[i], *pts[i + 1]) <= w / 2 for i in range(len(pts) - 1))
    if t == 'F':
        pts = [(a[i], a[i + 1]) for i in range(0, len(a), 2)]
        return lambda x, y: in_poly(x, y, pts)
    if t == 'R':
        x0, y0, w, h = a
        return lambda x, y: x0 <= x < x0 + w and y0 <= y < y0 + h
    if t == 'B':
        x0, y0, w, h = a[:4]; s = a[4] if len(a) > 4 else 1.5
        x1, y1 = x0 + w, y0 + h
        segs = [(x0, y0, x1, y0), (x1, y0, x1, y1), (x1, y1, x0, y1), (x0, y1, x0, y0)]
        return lambda x, y: any(seg_dist(x, y, *sg) <= s / 2 for sg in segs)
    if t == 'C':
        cx, cy, r = a
        return lambda x, y: (x - cx) ** 2 + (y - cy) ** 2 <= r * r
    if t == 'O':
        cx, cy, r = a[:3]; w = a[3] if len(a) > 3 else 1.5
        return lambda x, y: abs(math.hypot(x - cx, y - cy) - r) <= w / 2
    if t == 'A':
        cx, cy, r, a0, a1 = a[:5]; w = a[5] if len(a) > 5 else 1.5
        def f(x, y):
            if abs(math.hypot(x - cx, y - cy) - r) > w / 2:
                return False
            ang = math.degrees(math.atan2(y - cy, x - cx)) % 360
            lo = a0 % 360; span = a1 - a0
            if span >= 360: return True
            return (ang - lo) % 360 <= span
        return f
    if t == 'E':
        cx, cy, rx, ry = a[:4]
        a0, a1 = (a[4], a[5]) if len(a) > 5 else (0, 360)
        w = a[6] if len(a) > 6 else 1.5
        def f(x, y):
            nx, ny = (x - cx) / rx, (y - cy) / ry
            if abs(math.hypot(nx, ny) - 1) * min(rx, ry) > w / 2:
                return False
            if a1 - a0 >= 360: return True
            ang = math.degrees(math.atan2(ny, nx)) % 360
            return (ang - a0 % 360) % 360 <= a1 - a0
        return f
    if t == 'G':
        cx, cy, rx, ry = a
        return lambda x, y: ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1
    raise ValueError(spec)


def render(specs):
    ops = []
    for sp in specs:
        erase = sp.startswith('-')
        ops.append((erase, shape_fn(sp[1:] if erase else sp)))
    out = []
    for py in range(N):
        for px in range(N):
            hits = 0
            for sy in range(SS):
                for sx in range(SS):
                    x = px + (sx + 0.5) / SS; y = py + (sy + 0.5) / SS
                    on = False
                    for erase, fn in ops:
                        if fn(x, y): on = not erase
                    hits += on
            out.append(hits / (SS * SS))
    return out


def main():
    names = list(ICONS)
    masks = {n: render(ICONS[n]) for n in names}
    lines = ['# Generated by tools/genicons.py - do not edit; change the icon there.',
             f'# {len(names)} icons, 16 x 16, 4-bit alpha (low nibble = left pixel).',
             '.equ ICON_COUNT, %d' % len(names)]
    for i, n in enumerate(names):
        lines.append('.equ ICON_%s, %d' % (n.upper(), i))
    lines.append('.ifdef ICON_DATA')
    lines.append('.section .rodata')
    lines.append('icon_masks:')
    for n in names:
        m = masks[n]
        q = [min(15, int(v * 15 + 0.5)) for v in m]
        b = [q[i] | (q[i + 1] << 4) for i in range(0, len(q), 2)]
        for r in range(N):
            row = b[r * 8:(r + 1) * 8]
            lines.append('    .byte ' + ','.join('0x%02x' % v for v in row) + ('   # ' + n if r == 0 else ''))
    lines.append('.text')
    lines.append('.endif')
    out = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else 'src/icons.inc'
    open(out, 'w').write('\n'.join(lines) + '\n')
    if '--preview' in sys.argv:
        from PIL import Image
        cols = 12; scale = 4
        rows = (len(names) + cols - 1) // cols
        img = Image.new('RGB', (cols * 20 * scale, rows * 20 * scale), (42, 46, 54))
        for i, n in enumerate(names):
            ox, oy = (i % cols) * 20 + 2, (i // cols) * 20 + 2
            for p, v in enumerate(masks[n]):
                c = int(42 + v * (220 - 42))
                for dy in range(scale):
                    for dx in range(scale):
                        img.putpixel(((ox + p % N) * scale + dx, (oy + p // N) * scale + dy), (c, c, c))
        img.save(sys.argv[sys.argv.index('--preview') + 1])
    print(f'{len(names)} icons -> src/icons.inc ({len(names) * 128} bytes of masks)')


if __name__ == '__main__':
    main()
