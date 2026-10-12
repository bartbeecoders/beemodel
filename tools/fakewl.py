#!/usr/bin/env python3
"""
Dev-only headless test harness for BeeModel (NOT needed to build or run).

A tiny fake Wayland compositor: it serves just enough of wl_compositor, wl_shm,
xdg_wm_base, wl_seat and wp_cursor_shape_manager_v1 for BeeModel, captures every
committed frame from the shared-memory buffer, injects pointer/keyboard input
and writes PNG screenshots. Runs completely isolated from the real desktop.

usage: tools/fakewl.py [outdir]
"""
import mmap, os, select, socket, struct, subprocess, sys, tempfile, time

GOLDEN_DIR = os.path.join(os.path.dirname(__file__), '..', 'tests', 'golden')
GOLDEN = {'01_initial.png', '03_menu_view.png', '17_two_viewports.png',
          '19_editor_type_menu.png', '21_palette_split.png'}
GOLDEN_MODE = os.environ.get('BEEMODEL_GOLDEN', '')        # '', 'check', 'update'
RSS_BUDGET_KB = 16 * 1024          # private (anonymous) memory incl. glyph caches
FIRST_FRAME_BUDGET_MS = 500        # process start -> first committed frame
FRAME_BUDGET_MS = 16.0             # average input -> committed frame while dragging
STRESS_BUDGET_MS = 33.0            # ~300k triangles on a 4-core CI runner

OUT = sys.argv[1] if len(sys.argv) > 1 else 'build/shots'
BIN = os.path.join(os.path.dirname(__file__), '..', 'build', 'beemodel')
os.makedirs(OUT, exist_ok=True)

GLOBALS = [(1, 'wl_compositor', 4), (2, 'wl_shm', 1), (3, 'xdg_wm_base', 2),
           (4, 'wl_seat', 5), (5, 'wp_cursor_shape_manager_v1', 1),
           (6, 'wp_fractional_scale_manager_v1', 1), (7, 'wp_viewporter', 1)]


def wstr(s):
    b = s.encode() + b'\0'
    return struct.pack('<I', len(b)) + b + b'\0' * (-len(b) % 4)


class Fake:
    def __init__(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, 'wl')
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.path)
        srv.listen(1)
        env = dict(os.environ, WAYLAND_DISPLAY=self.path)
        self.t0 = time.time()
        self.proc = subprocess.Popen([BIN], env=env)
        self.first_frame_ms = None
        self.t_input = None                 # input sent, waiting for its frame
        self.latencies = []
        srv.settimeout(5)
        self.c, _ = srv.accept()
        self.buf, self.fds = b'', []
        self.objs = {1: 'wl_display'}
        self.pools, self.buffers = {}, {}
        self.attached = None
        self.frame = None          # (w, h, bytes)
        self.frames = 0
        self.serial = 100
        self.cursor = None
        self.requests = []
        self.size = (1280, 800)

    # ---- wire -------------------------------------------------------------
    def send(self, obj, op, payload=b''):
        self.c.sendall(struct.pack('<II', obj, ((8 + len(payload)) << 16) | op) + payload)

    def find(self, iface):
        return [k for k, v in self.objs.items() if v == iface]

    def pump(self, timeout=0.3, until_frame=False):
        start_frames = self.frames
        end = time.time() + timeout
        while time.time() < end:
            if until_frame and self.frames > start_frames:
                # drain whatever is left quickly
                end = min(end, time.time() + 0.02)
            r, _, _ = select.select([self.c], [], [], max(0, end - time.time()))
            if not r:
                if self.proc.poll() is not None:
                    return
                continue
            try:
                data, anc, _, _ = socket.recv_fds(self.c, 65536, 16)
            except ConnectionResetError:
                data, anc = b'', []
            if not data:
                return
            self.buf += data
            self.fds += anc
            while len(self.buf) >= 8:
                obj, w = struct.unpack_from('<II', self.buf)
                size, op = w >> 16, w & 0xffff
                if len(self.buf) < size:
                    break
                self.handle(obj, op, self.buf[8:size])
                self.buf = self.buf[size:]

    def handle(self, obj, op, p):
        iface = self.objs.get(obj, '?')
        self.requests.append((iface, op))
        u = lambda i: struct.unpack_from('<I', p, i * 4)[0]
        if iface == 'wl_display':
            if op == 1:                                   # get_registry
                self.objs[u(0)] = 'wl_registry'
                for name, itf, ver in GLOBALS:
                    self.send(u(0), 0, struct.pack('<I', name) + wstr(itf) + struct.pack('<I', ver))
            elif op == 0:                                 # sync
                self.send(u(0), 0, struct.pack('<I', 0))
        elif iface == 'wl_registry' and op == 0:          # bind
            name = u(0)
            n = u(1); pad = (n + 3) & ~3
            itf = p[8:8 + n - 1].decode()
            ver, nid = struct.unpack_from('<II', p, 8 + pad)
            self.objs[nid] = itf
            if itf == 'wl_seat':
                self.send(nid, 0, struct.pack('<I', 3))  # pointer | keyboard
        elif iface == 'wl_compositor' and op == 0:
            self.objs[u(0)] = 'wl_surface'
        elif iface == 'xdg_wm_base' and op == 2:
            self.objs[u(0)] = 'xdg_surface'
        elif iface == 'xdg_surface' and op == 1:
            self.objs[u(0)] = 'xdg_toplevel'
        elif iface == 'wl_seat' and op == 0:
            self.objs[u(0)] = 'wl_pointer'
        elif iface == 'wl_seat' and op == 1:
            self.objs[u(0)] = 'wl_keyboard'
        elif iface == 'wp_cursor_shape_manager_v1' and op == 1:
            self.objs[u(0)] = 'wp_cursor_shape_device_v1'
        elif iface == 'wp_fractional_scale_manager_v1' and op == 1:
            self.objs[u(0)] = 'wp_fractional_scale_v1'
        elif iface == 'wp_viewporter' and op == 1:
            self.objs[u(0)] = 'wp_viewport'
        elif iface == 'wp_viewport' and op == 2:
            self.dest = (u(0), u(1))
        elif iface == 'wp_cursor_shape_device_v1' and op == 1:
            self.cursor = u(1)
        elif iface == 'wl_shm' and op == 0:               # create_pool(id, fd, size)
            fd = self.fds.pop(0)
            self.pools[u(0)] = [fd, mmap.mmap(fd, u(1)), u(1)]
            self.objs[u(0)] = 'wl_shm_pool'
        elif iface == 'wl_shm_pool' and op == 2:          # resize
            pool = self.pools[obj]
            pool[1].close()
            pool[1] = mmap.mmap(pool[0], u(0)); pool[2] = u(0)
        elif iface == 'wl_shm_pool' and op == 0:          # create_buffer
            self.buffers[u(0)] = (obj, u(1), u(2), u(3), u(4))
            self.objs[u(0)] = 'wl_buffer'
        elif iface == 'wl_surface' and op == 1:           # attach
            self.attached = u(0)
        elif iface == 'wl_surface' and op == 3:           # frame
            self.objs[u(0)] = 'wl_callback'
            self.pending_cb = u(0)
        elif iface == 'wl_surface' and op == 6:           # commit
            if self.attached is None:
                self.configure()
                return
            pid, off, w, h, stride = self.buffers[self.attached]
            mem = self.pools[pid][1]
            self.frame = (w, h, bytes(mem[off:off + stride * h]))
            self.frames += 1
            if self.first_frame_ms is None:
                self.first_frame_ms = (time.time() - self.t0) * 1000
            if self.t_input is not None:
                self.latencies.append((time.time() - self.t_input) * 1000)
                self.t_input = None
            self.send(self.attached, 0)                   # release
            self.attached = None
            if getattr(self, 'pending_cb', None):
                self.send(self.pending_cb, 0, struct.pack('<I', int(time.time() * 1000) & 0xffffffff))
                self.pending_cb = None

    def configure(self, w=None, h=None, states=()):
        if w: self.size = (w, h)
        tl = self.find('xdg_toplevel')[0]; xs = self.find('xdg_surface')[0]
        arr = b''.join(struct.pack('<I', s) for s in states)
        self.send(tl, 0, struct.pack('<iiI', self.size[0], self.size[1], len(arr)) + arr)
        self.serial += 1
        self.send(xs, 0, struct.pack('<I', self.serial))

    # ---- input --------------------------------------------------------------
    def ptr(self): return self.find('wl_pointer')[0]
    def surf(self): return self.find('wl_surface')[0]

    def enter(self, x, y):
        self.serial += 1
        self.send(self.ptr(), 0, struct.pack('<IIii', self.serial, self.surf(), x * 256, y * 256))
        self.pump(until_frame=True)

    def move(self, x, y, wait=True):
        self.t_input = time.time()
        self.send(self.ptr(), 2, struct.pack('<Iii', 0, x * 256, y * 256))
        if wait: self.pump(until_frame=True)
        self.t_input = None                 # no change -> no frame: not a sample

    def button(self, pressed, btn=0x110):
        self.serial += 1
        self.send(self.ptr(), 3, struct.pack('<IIII', self.serial, int(time.time() * 1000) & 0xffffffff, btn, int(pressed)))
        self.pump(until_frame=True)

    def click(self, x, y, btn=0x110):
        self.move(x, y); self.button(True, btn); self.button(False, btn)

    def drag(self, x0, y0, x1, y1, steps=8, btn=0x110):
        self.move(x0, y0); self.button(True, btn)
        for i in range(1, steps + 1):
            self.move(x0 + (x1 - x0) * i // steps, y0 + (y1 - y0) * i // steps)
        self.button(False, btn)

    def wheel(self, v):
        self.send(self.ptr(), 4, struct.pack('<IIi', 0, 0, v * 256))
        self.pump(until_frame=True)

    def key(self, code):
        kb = self.find('wl_keyboard')[0]
        for st in (1, 0):
            self.serial += 1
            self.send(kb, 3, struct.pack('<IIII', self.serial, 0, code, st))
        self.pump(until_frame=True)

    def mods(self, depressed):
        kb = self.find('wl_keyboard')[0]
        self.serial += 1
        self.send(kb, 4, struct.pack('<IIIII', self.serial, depressed, 0, 0, 0))

    def keymap(self, path):
        data = open(path, 'rb').read() + b'\0'
        fd = os.memfd_create('keymap')
        os.write(fd, data)
        kb = self.find('wl_keyboard')[0]
        msg = struct.pack('<IIII', kb, (16 << 16) | 0, 1, len(data))
        socket.send_fds(self.c, [msg], [fd])
        os.close(fd)
        self.pump(0.2)

    def repeat_info(self, rate, delay):
        self.send(self.find('wl_keyboard')[0], 5, struct.pack('<ii', rate, delay))

    def keyev(self, code, down):
        self.serial += 1
        self.send(self.find('wl_keyboard')[0], 3, struct.pack('<IIII', self.serial, 0, code, int(down)))

    US = {**{c: k for k, c in enumerate('1234567890', 2)}, **{c: k for k, c in enumerate('qwertyuiop', 16)},
          **{c: k for k, c in enumerate('asdfghjkl', 30)}, **{c: k for k, c in enumerate('zxcvbnm', 44)},
          '.': 52, '-': 12, ' ': 57}

    def type(self, text):
        for ch in text:
            shift = ch == '_' or ch.isupper()
            code = 12 if ch == '_' else self.US[ch.lower()]
            if shift: self.mods(1)
            self.keyev(code, 1); self.keyev(code, 0)
            if shift: self.mods(0)
        self.pump(until_frame=True)

    def scale(self, s120):
        self.send(self.find('wp_fractional_scale_v1')[0], 0, struct.pack('<I', s120))
        self.pump(0.5, until_frame=True)

    def shot(self, name):
        from PIL import Image
        w, h, data = self.frame
        img = Image.frombuffer('RGBX', (w, h), data, 'raw', 'BGRX', 0, 1).convert('RGB')
        path = os.path.join(OUT, name)
        img.save(path)
        print(f'  shot {path} ({w}x{h}, frame #{self.frames}, cursor shape {self.cursor})')
        if GOLDEN_MODE and name in GOLDEN:
            golden(img, name)

    def rss_anon_kb(self):
        for line in open(f'/proc/{self.proc.pid}/status'):
            if line.startswith('RssAnon:'):
                return int(line.split()[1])


FAILS = []


def golden(img, name):
    """Compare a frame with tests/golden/<name> (or rewrite it in update mode)."""
    from PIL import Image, ImageChops
    ref_path = os.path.join(GOLDEN_DIR, name)
    if GOLDEN_MODE == 'update':
        os.makedirs(GOLDEN_DIR, exist_ok=True)
        img.save(ref_path, optimize=True)
        print(f'  golden updated: {ref_path}')
        return
    if not os.path.exists(ref_path):
        check(False, f'golden {name}: reference missing (run with BEEMODEL_GOLDEN=update)')
        return
    ref = Image.open(ref_path).convert('RGB')
    if ref.size != img.size:
        check(False, f'golden {name}: size {img.size} != {ref.size}')
        return
    diff = ImageChops.difference(img, ref)
    bad = sum(1 for px in diff.getdata() if max(px) > 8)
    total = img.size[0] * img.size[1]
    ok = bad <= total // 2000                  # <= 0.05% of the pixels
    if not ok:
        diff.point(lambda v: 255 if v > 8 else 0).save(os.path.join(OUT, 'diff_' + name))
    check(ok, f'golden {name}: {bad} of {total} pixels differ')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def px(f, x, y):
    w, h, data = f.frame
    b, g, r, _ = data[(y * w + x) * 4:(y * w + x) * 4 + 4]
    return (r << 16) | (g << 8) | b


def main():
    f = Fake()
    f.pump(1.0, until_frame=True)
    check(f.frame is not None, 'first frame committed')
    if not f.frame:
        sys.exit(1)
    check(f.frame[:2] == (1280, 800), 'default window size 1280x800')
    check(f.first_frame_ms < FIRST_FRAME_BUDGET_MS,
          f'first frame after {f.first_frame_ms:.0f} ms (budget {FIRST_FRAME_BUDGET_MS} ms)')
    check(px(f, 640, 5) == 0x1b1d22, 'title bar background')
    check(px(f, 13, 15) == 0xf2b134, 'honeycomb logo drawn')
    f.shot('01_initial.png')
    f.enter(640, 400)
    check(f.cursor == 8, 'crosshair cursor over canvas')
    f.click(20, 44)                      # File menu
    check(px(f, 100, 70) != px(f, 700, 70), 'File dropdown visible')
    f.shot('02_menu_file.png')
    f.move(130, 44)                      # slide to "View"
    f.move(150, 96)                      # hover an item
    f.shot('03_menu_view.png')
    f.click(150, 120)                    # View > Console Pane (toggle off)
    check(px(f, 1005, 662) != 0x2a2e36, 'console pane hidden')
    f.shot('04_console_hidden.png')
    f.click(130, 44); f.click(150, 120)  # toggle it back on
    check(px(f, 1005, 662) == 0x2a2e36, 'console pane shown again')
    f.move(212, 300)
    check(f.cursor == 26, 'ew-resize cursor on splitter')
    f.latencies = []
    f.drag(212, 300, 330, 300)           # left splitter
    check(px(f, 300, 450) == 0x2a2e36, 'left pane widened by drag')
    f.drag(1017, 300, 900, 300)          # right splitter
    f.drag(600, 625, 600, 520)           # bottom splitter
    lat = sorted(f.latencies)
    ms = lat[len(lat) // 2] if lat else 0
    check(ms < FRAME_BUDGET_MS, f'input-to-frame latency {ms:.2f} ms median, '
          f'{lat[-1] if lat else 0:.2f} ms worst (budget {FRAME_BUDGET_MS} ms, {len(lat)} frames)')
    kb = f.rss_anon_kb()
    check(kb < RSS_BUDGET_KB, f'private memory {kb} KiB (budget {RSS_BUDGET_KB} KiB)')
    f.shot('05_splitters.png')
    f.drag(600, 300, 700, 340)           # orbit
    f.wheel(-10); f.wheel(-10)           # zoom in
    f.click(1060, 93)                    # outliner: select Camera
    f.shot('06_orbit_zoom.png')
    f.mods(1); f.key(17); f.mods(0)      # Shift+W: Move tool via the operator keymap
    check(px(f, 150, 125) == 0xf2b134, 'Shift+W activates the Move tool')
    f.key(20)                            # T: hide tools pane
    check(px(f, 4, 300) != 0x2a2e36, 'T hides the tools pane')
    f.mods(4); f.key(20); f.mods(0)      # Ctrl+T is not bound: no change
    check(px(f, 4, 300) != 0x2a2e36, 'Ctrl+T does not trigger the T binding')
    f.key(20)
    check(px(f, 4, 300) == 0x2a2e36, 'T shows the tools pane again')
    f.mods(1); f.key(16); f.key(34); f.mods(0)   # Shift+Q: Select, Shift+G: grid off
    f.move(1250, 10)                     # hover close button
    check(px(f, 1240, 3) == 0xe81123, 'close button hover is red')
    f.shot('07_grid_off_close_hover.png')
    f.configure(900, 560); f.pump(0.5, until_frame=True)
    check(f.frame[:2] == (900, 560), 'resize to 900x560 honoured')
    f.shot('08_resized.png')
    f.configure(1600, 900, states=(1, 4)); f.pump(0.5, until_frame=True)
    check(f.frame[:2] == (1600, 900), 'maximized configure honoured')
    f.shot('09_maximized.png')
    f.move(1600 - 23, 16)                # hover close (clicking it is tested in 0.1.0)
    check(px(f, 1600 - 10, 3) == 0xe81123, 'close button hover is red')

    # ---- keyboard: real XKB keymaps, delivered over an fd like Hyprland does
    f.keymap('tests/keymaps/be.xkb')     # Belgian AZERTY
    f.mods(1); f.key(44); f.mods(0)      # Shift + physical QWERTY-Z = label W on AZERTY
    check(px(f, 150, 125) == 0xf2b134, 'AZERTY: Shift + key labelled W selects Move')
    f.mods(1); f.key(16); f.mods(0)      # Shift + physical QWERTY-Q = label A: unbound
    check(px(f, 150, 125) == 0xf2b134, 'AZERTY: Shift + key labelled A does not trigger Shift+Q')
    f.keymap('tests/keymaps/us.xkb')
    f.repeat_info(60, 120)
    f.move(800, 400)
    f.key(28)                            # Enter focuses the command line
    f.shot('10_command_line_focus.png')
    f.type('file.ex')
    f.key(15)                            # Tab completes to file.exit
    f.shot('11_tab_completion.png')
    before = f.frames
    f.keyev(45, 1); f.pump(0.45); f.keyev(45, 0); f.pump(0.1)   # hold X: repeats
    check(f.frames - before >= 3, f'key repeat redraws while held ({f.frames - before} frames)')
    f.mods(4); f.key(30); f.mods(0)      # Ctrl+A selects all
    f.shot('12_select_all.png')
    f.key(14)                            # Backspace clears the selection
    f.type('view.toggle_grid')
    f.key(28)                            # run it
    f.type('nope'); f.key(28)            # unknown command is reported, app lives on
    f.shot('13_console_commands.png')
    # ---- fractional scaling: buffer in physical pixels, viewport = logical
    for s120, name in ((180, '15_scale_150.png'), (240, '16_scale_200.png')):
        f.scale(s120)
        pw, ph = 1600 * s120 // 120, 900 * s120 // 120
        check(f.frame[:2] == (pw, ph), f'scale {s120/120:.2f}: buffer {f.frame[0]}x{f.frame[1]} == {pw}x{ph}')
        check(getattr(f, 'dest', None) == (1600, 900), f'scale {s120/120:.2f}: viewport destination is logical 1600x900')
        check(px(f, pw // 2, 3) == 0x1b1d22, f'scale {s120/120:.2f}: title bar spans the scaled buffer')
        f.shot(name)
    f.click(20, 44)                      # logical input still hits "File" at 200%
    check(px(f, 150 * 2, 70 * 2) == 0x2d313a, 'scale 2.00: File menu opens from logical coordinates')
    f.key(1)                             # Esc closes the menu
    f.scale(120)
    f.key(28)                            # clicking the menu blurred the command line
    check(f.frame[:2] == (1600, 900), 'back to 100%')

    # Unicode via the Belgian layout: AE02 = e-acute, AD11 = dead circumflex
    f.keymap('tests/keymaps/be.xkb')
    f.key(3); f.key(26); f.key(18); f.mods(1); f.key(26); f.mods(0); f.key(18)
    f.shot('14_unicode_dead_keys.png')
    f.mods(4); f.key(16); f.mods(0)      # Ctrl + key labelled A (AZERTY) selects all
    f.key(14)
    f.keymap('tests/keymaps/us.xkb')
    f.type('file.exit'); f.key(28)       # quit through the command line
    f.pump(0.5)
    try:
        rc = f.proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        f.proc.kill(); rc = None
    check(rc == 0, f'typed file.exit quits cleanly (rc={rc})')
    check(f.frames >= 50, f'frames rendered ({f.frames})')
    areas_and_palette()
    transforms()
    undo_redo()
    raster_stress()
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nall checks passed')
    sys.exit(1 if FAILS else 0)


import math


def project(p, yaw=0.7853982, pitch=0.5, dist=18.0, target=(0, 0, 0),
            canvas=(214, 80, 1014, 623)):
    """Mirror of cam_setup + project in viewport.s (default viewport, 100%)."""
    sy, cy, sp, cp = math.sin(yaw), math.cos(yaw), math.sin(pitch), math.cos(pitch)
    right = (cy, 0, -sy); up = (-sp * sy, cp, -sp * cy); fwd = (-cp * sy, -sp, -cp * cy)
    eye = [target[i] - fwd[i] * dist for i in range(3)]
    d = [p[i] - eye[i] for i in range(3)]
    dot = lambda a, b: sum(a[i] * b[i] for i in range(3))
    x0, y0, x1, y1 = canvas
    f = (y1 - y0) * 1.07
    z = dot(d, fwd)
    return (int((x0 + x1) / 2 + f * dot(d, right) / z), int((y0 + y1) / 2 - f * dot(d, up) / z))


def bright(c):
    return ((c >> 16) & 255) + ((c >> 8) & 255) + (c & 255) > 3 * 100


def transforms():
    """G / R / S modal transforms, constraints, numeric input, cancel, gizmo."""
    print('  -- transforms --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(*project((0, 1, 0)))
    view = lambda: [px(f, x, y) for x in range(240, 1000, 7) for y in range(100, 600, 7)]
    c0 = project((0, 1, 0))
    check(bright(px(f, *c0)), 'the default cube is drawn at the origin')
    before = view()
    f.key(34)                            # G: grab
    f.move(c0[0] + 120, c0[1] + 40)
    moved = view()
    f.key(1)                             # Esc: cancel restores exactly
    check(moved != before and view() == before, 'G + move changes the view, Esc restores it exactly')
    f.move(*c0)
    f.key(34); f.key(45); f.type('2'); f.key(28)     # G X 2 Enter
    c2 = project((2, 1, 0))
    check(bright(px(f, *c2)) and not bright(px(f, *project((-0.8, 1, 0)))),
          'G X 2 Enter moves the cube to x = 2')
    f.shot('24_grab_x2.png')
    rot0 = view()
    f.move(*c2)
    f.key(19); f.key(44); f.type('45'); f.key(28)    # R Z 45 Enter
    check(view() != rot0, 'R Z 45 rotates the cube')
    f.key(19); f.key(44); f.type('-45'); f.key(28)   # and back
    corners = [project((2 + sx * 0.85, 1 + sy * 0.85, sz * 0.85))  # inside the 2 m cube only
               for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    lit = lambda: sum(bright(px(f, *c)) for c in corners)
    s0, big = view(), lit()
    f.key(31); f.type('.5'); f.key(28)               # S .5 Enter
    small = lit()
    check(view() != s0 and big >= 6 and small <= big // 2 and bright(px(f, *c2)),
          f'S .5 scales the cube down around its centre ({big} -> {small} lit probes)')
    f.shot('25_rotate_scale.png')
    f.key(34)                            # RMB cancels too
    f.move(c2[0] + 60, c2[1])
    f.button(True, 0x111); f.button(False, 0x111)
    check(bright(px(f, *c2)), 'right click cancels a transform')
    # gizmo: Move tool, drag the X handle
    f.mods(1); f.key(17); f.mods(0)      # Shift+W: Move tool
    f.move(*c2)
    tipx = project((2.6, 1, 0))
    mid = ((c2[0] + tipx[0]) // 2, (c2[1] + tipx[1]) // 2)
    dx, dy = tipx[0] - c2[0], tipx[1] - c2[1]
    n = math.hypot(dx, dy)
    end = (int(mid[0] + dx / n * 100), int(mid[1] + dy / n * 100))
    f.shot('26_move_gizmo.png')
    f.drag(mid[0], mid[1], end[0], end[1], steps=6)
    check(not bright(px(f, *project((1.6, 1, 0)))), 'dragging the gizmo X handle moves the cube along X')
    f.shot('27_gizmo_dragged.png')
    f.proc.kill()


def undo_redo():
    """Ctrl+Z / Ctrl+Shift+Z over transforms, delete and create."""
    print('  -- undo / redo --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    c0, c2 = project((0, 1, 0)), project((2, 1, 0))
    f.enter(*c0)
    ICON = lambda row: px(f, 1037, 94 + 20 * row)
    undo = lambda: (f.mods(4), f.key(44), f.mods(0))
    redo = lambda: (f.mods(5), f.key(44), f.mods(0))
    f.key(34); f.key(45); f.type('2'); f.key(28)     # G X 2
    check(bright(px(f, *c2)) and not bright(px(f, *project((-0.8, 1, 0)))), 'cube moved to x = 2')
    undo()
    check(bright(px(f, *project((-0.8, 1, 0)))) and not bright(px(f, *project((2.8, 1, 0)))),
          'Ctrl+Z puts the cube back at the origin')
    redo()
    check(bright(px(f, *c2)) and not bright(px(f, *project((-0.8, 1, 0)))), 'Ctrl+Shift+Z moves it to x = 2 again')
    f.key(45)                            # X: delete the cube
    check(ICON(2) == 0x2a2e36, 'X deletes the cube')
    undo()
    check(ICON(2) == 0xb4b8c0 and bright(px(f, *c2)), 'Ctrl+Z brings the deleted cube back where it was')
    f.key(61); f.type('torus'); f.key(28)            # create, then undo it
    check(ICON(3) == 0xb4b8c0, 'palette adds a torus')
    undo()
    check(ICON(3) == 0x2a2e36, 'Ctrl+Z removes the torus again')
    f.move(*c2)
    f.key(34); f.move(c2[0] + 80, c2[1]); f.key(1)   # cancelled grab: no step
    undo()                               # undoes the redo'd move instead
    check(bright(px(f, *project((-0.8, 1, 0)))), 'a cancelled transform leaves no undo step')
    f.shot('28_undo.png')
    f.proc.kill()


def raster_stress():
    """~300k triangles (256 toruses + cubes): orbit latency budget."""
    print('  -- rasterizer stress --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    f.key(61); f.type('torus'); f.key(28)
    f.move(600, 300)
    for _ in range(8):                   # select all + duplicate = doubling
        f.key(30); f.key(30)
        f.mods(1); f.key(32); f.mods(0)
    f.key(30)                            # nothing selected
    f.latencies = []
    f.drag(600, 300, 700, 330, steps=12)
    lat = sorted(f.latencies[1:])        # the first frame grows the buffers
    ms = lat[len(lat) // 2] if lat else 1e9
    check(ms < STRESS_BUDGET_MS, f'~300k triangles: orbit frame {ms:.1f} ms median (budget {STRESS_BUDGET_MS} ms)')
    f.shot('23_stress.png')
    f.proc.kill()


def areas_and_palette():
    """Second instance at the default 1280x800 layout: area headers, splits,
    maximize, editor types and the F3 command palette."""
    print('  -- areas & command palette --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    PANE = 0x2a2e36

    # ---- scene: outliner rows (icon colour per type), selection, edit ops
    ICON = lambda row: px(f, 1037, 94 + 20 * row)
    ROWBG = lambda row: px(f, 1025, 86 + 20 * row)
    SEL = 0x6b5420
    check([ICON(r) for r in range(3)] == [0x61afef, 0xe5c07b, 0xb4b8c0],
          'outliner lists the default Camera, Light and Cube')
    check(ROWBG(2) == SEL, 'the default cube starts selected')
    f.click(300, 560)                    # empty viewport: deselect all
    check(ROWBG(2) != SEL, 'clicking empty space deselects')
    f.click(590, 300)                    # click the cube
    check(ROWBG(2) == SEL, 'clicking the cube in the viewport selects it')
    solid = px(f, 600, 330)
    f.key(44)                            # Z: wireframe
    wire = px(f, 600, 330)
    f.key(44)                            # Z: back to solid
    check(solid != wire and px(f, 600, 330) == solid, 'Z toggles solid / wireframe shading')
    f.click(1080, 94)                    # outliner: click Camera row
    check(ROWBG(0) == SEL and ROWBG(2) != SEL, 'outliner click selects the Camera only')
    f.mods(1); f.click(1080, 134); f.mods(0)   # Shift+click Cube: extend
    check(ROWBG(0) == SEL and ROWBG(2) == SEL, 'Shift+click extends the selection')
    f.move(600, 300)
    f.key(45)                            # X deletes Camera and Cube
    check(ICON(0) == 0xe5c07b and ICON(1) == PANE, 'X deletes the selected objects')
    f.key(61); f.type('torus'); f.key(28)      # palette: add a torus
    check(ICON(1) == 0xb4b8c0 and ROWBG(1) == SEL, 'palette create.torus adds a selected torus')
    f.move(600, 300)
    f.mods(1); f.key(32); f.mods(0)      # Shift+D duplicates it
    check(ICON(2) == 0xb4b8c0 and ROWBG(2) == SEL and ROWBG(1) != SEL,
          'Shift+D duplicates; the copy becomes the selection')
    f.key(30)                            # A: something selected -> none
    check(ROWBG(2) != SEL, 'A deselects all')
    f.key(30)                            # A again -> all
    check(all(ROWBG(r) == SEL for r in range(3)), 'A selects all')
    f.shot('22_scene_ops.png')

    check(px(f, 4, 300) == PANE, 'default layout: tools area on the left')
    f.click(194, 68)                     # Tools header: close button
    check(px(f, 4, 300) != PANE, 'area close button removes the tools area')
    f.key(20)                            # T brings it back
    check(px(f, 4, 300) == PANE, 'T re-creates the tools area')
    f.move(600, 300)
    f.click(955, 68)                     # Viewport header: split side by side
    check(px(f, 613, 300) in (0x16181c, 0xf2b134), 'split side by side adds a splitter in the viewport')
    f.drag(400, 300, 470, 330)           # orbit only the left viewport
    f.shot('17_two_viewports.png')
    f.move(800, 300)
    f.mods(4); f.key(57); f.mods(0)      # Ctrl+Space maximizes the hovered area
    check(px(f, 4, 300) != PANE, 'Ctrl+Space maximizes the active area')
    f.shot('18_maximized_area.png')
    f.mods(4); f.key(57); f.mods(0)
    check(px(f, 4, 300) == PANE, 'Ctrl+Space again restores the layout')
    f.click(680, 68)                     # right viewport: editor type menu
    f.shot('19_editor_type_menu.png')
    f.click(700, 140)                    # third entry: Outliner
    f.shot('20_viewport_became_outliner.png')
    f.key(61)                            # F3 opens the command palette
    f.type('spl')
    f.shot('21_palette_split.png')
    f.key(1)                             # Esc closes it
    f.key(61)
    f.type('exit')                       # fuzzy search, Enter runs the best hit
    f.key(28)
    f.pump(0.5)
    try:
        rc = f.proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        f.proc.kill(); rc = None
    check(rc == 0, f'F3 "exit" + Enter quits through the palette (rc={rc})')


if __name__ == '__main__':
    main()
