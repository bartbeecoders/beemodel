#!/usr/bin/env python3
"""
Dev-only headless test harness for BeeModel (NOT needed to build or run).

A tiny fake Wayland compositor: it serves just enough of wl_compositor, wl_shm,
xdg_wm_base, wl_seat and wp_cursor_shape_manager_v1 for BeeModel, captures every
committed frame from the shared-memory buffer, injects pointer/keyboard input
and writes PNG screenshots. Runs completely isolated from the real desktop.

usage: tools/fakewl.py [outdir]
"""
import mmap, os, re, select, shutil, socket, struct, subprocess, sys, tempfile, time

GOLDEN_DIR = os.path.join(os.path.dirname(__file__), '..', 'tests', 'golden')
GOLDEN = {'01_initial.png', '03_menu_view.png', '17_two_viewports.png',
          '19_editor_type_menu.png', '21_palette_split.png'}
GOLDEN_MODE = os.environ.get('BEEMODEL_GOLDEN', '')        # '', 'check', 'update'
RSS_BUDGET_KB = 16 * 1024          # private (anonymous) memory incl. glyph caches
FIRST_FRAME_BUDGET_MS = 500        # process start -> first committed frame
FRAME_BUDGET_MS = 16.0             # average input -> committed frame while dragging
STRESS_BUDGET_MS = 33.0            # ~300k triangles on a 4-core CI runner
PREVIEW_BUDGET_MS = 66.0           # the same in material preview (per-pixel PBR)
WALKTHROUGH_BUDGET_S = 20.0        # the hard-surface walkthrough, end to end

OUT = sys.argv[1] if len(sys.argv) > 1 else 'build/shots'
BIN = os.path.join(os.path.dirname(__file__), '..', 'build', 'beemodel')
os.makedirs(OUT, exist_ok=True)

GLOBALS = [(1, 'wl_compositor', 4), (2, 'wl_shm', 1), (3, 'xdg_wm_base', 2),
           (4, 'wl_seat', 5), (5, 'wp_cursor_shape_manager_v1', 1),
           (6, 'wp_fractional_scale_manager_v1', 1), (7, 'wp_viewporter', 1),
           (8, 'zwp_tablet_manager_v2', 1)]


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
        self.home = tempfile.mkdtemp()      # never touch the real ~/BeeModel or cache
        env = dict(os.environ, WAYLAND_DISPLAY=self.path, HOME=self.home,
                   XDG_CACHE_HOME=os.path.join(self.home, 'cache'),
                   XDG_RUNTIME_DIR=self.home)       # MCP socket lands here
        self.env = env
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
        elif iface == 'wp_cursor_shape_manager_v1' and op in (1, 2):
            self.objs[u(0)] = 'wp_cursor_shape_device_v1'
        elif iface == 'zwp_tablet_manager_v2' and op == 0:
            self.objs[u(0)] = 'zwp_tablet_seat_v2'
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

    # ---- a tablet (zwp_tablet_v2): tools on the tablet seat ------------------
    def pen_add(self, eraser=False):
        """A new tool on the tablet seat (a pen, or a pen's eraser end)."""
        seat = self.find('zwp_tablet_seat_v2')[0]
        if not hasattr(self, 'tablet'):
            self.next_srv = 0xff000000
            self.tablet = self.next_srv; self.next_srv += 1
            self.send(seat, 0, struct.pack('<I', self.tablet))          # tablet_added
            self.send(self.tablet, 4)                                    # done
        tool = self.next_srv; self.next_srv += 1
        self.objs[tool] = 'zwp_tablet_tool_v2'
        self.send(seat, 1, struct.pack('<I', tool))                     # tool_added
        self.send(tool, 0, struct.pack('<I', 0x141 if eraser else 0x140))  # type
        self.send(tool, 3, struct.pack('<I', 1))                        # capability: pressure
        self.send(tool, 4)                                               # done
        self.pump(0.05)
        return tool

    def pen_stroke(self, tool, pts, pressure):
        """Into proximity, down at the first point, through the others with this
        pressure (0..1; a list: one a point), up, out. One frame a point."""
        ps = pressure if isinstance(pressure, list) else [pressure] * len(pts)
        frame = lambda: self.send(tool, 18, struct.pack('<I', int(time.time() * 1000) & 0xffffffff))
        self.serial += 1
        self.send(tool, 6, struct.pack('<III', self.serial, self.tablet, self.surf()))  # proximity_in
        for i, ((x, y), p) in enumerate(zip(pts, ps)):
            self.send(tool, 10, struct.pack('<ii', x * 256, y * 256))   # motion
            self.send(tool, 11, struct.pack('<I', int(p * 65535)))      # pressure
            if i == 0:
                self.serial += 1
                self.send(tool, 8, struct.pack('<I', self.serial))      # down
            frame()
            self.pump(until_frame=True)
        self.send(tool, 9); frame()                                      # up
        self.send(tool, 7); frame()                                      # proximity_out
        self.pump(0.2)

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
          '.': 52, '-': 12, ' ': 57, '/': 53, '=': 13, ',': 51, ';': 39, "'": 40, '[': 26, ']': 27}
    US_SHIFT = {'_': 12, '(': 10, ')': 11, '"': 40, '+': 13, '{': 26, '}': 27, '*': 9, '<': 51, '>': 52,
                '#': 4, '%': 6, '!': 2, ':': 39}

    def type(self, text):
        for ch in text:
            shift = ch in self.US_SHIFT or ch.isupper()
            code = self.US_SHIFT[ch] if ch in self.US_SHIFT else self.US[ch.lower()]
            if shift: self.mods(1)
            self.keyev(code, 1); self.keyev(code, 0)
            if shift: self.mods(0)
        self.pump(until_frame=True)

    def scale(self, s120):
        self.send(self.find('wp_fractional_scale_v1')[0], 0, struct.pack('<I', s120))
        self.pump(0.5, until_frame=True)

    def image(self):
        from PIL import Image
        w, h, data = self.frame
        return Image.frombuffer('RGBX', (w, h), data, 'raw', 'BGRX', 0, 1).convert('RGB')

    def shot(self, name):
        w, h, _ = self.frame
        img = self.image()
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
    files()
    mcp()
    edit_mode()
    mesh_ops()
    mesh_tools()
    redo_panel()
    modifiers_ui()
    booleans()
    analysis_repair()
    hardsurface_walkthrough()
    materials_ui()
    scripting()
    beescript_cli()
    modeling_budgets()
    hive_render()
    render_window()
    textures_world()
    shader_graph()
    gltf_mtl()
    product_shot()
    params_units()
    sketcher()
    features()
    measuring()
    sdf_kernel()
    fabrication()
    sculpting()
    tablet()
    dyntopo()
    mcp_conformance()
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


def log_lines(f):
    """Console text is not readable from pixels; ask over MCP instead."""
    m = Mcp(f)
    r = m.call('tools/call', {'name': 'op_edit_undo_history', 'arguments': {}})
    m.s.close()
    t = (r or {}).get('result', {}).get('content', [{}])[0].get('text', '')
    return t.split('\n')


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


def files():
    """.bee round trip, OBJ / STL export + import, screenshot, autosave."""
    print('  -- files --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(*project((0, 1, 0)))
    T = f.home
    ICON = lambda row: px(f, 1037, 94 + 20 * row)
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.2)
    name = 's1_234567890.bee'                  # every digit: guards the keymap parser
    cmd(f'file.save {T}/{name}')
    data = open(f'{T}/{name}', 'rb').read() if os.path.exists(f'{T}/{name}') else b''
    check(data[:4] == b'BEEM', f'file.save writes a .bee file ({len(data)} bytes, typed digits 0-9)')
    if data[:4] != b'BEEM':
        f.shot('files_save_failed.png')
    f.key(1)                                   # leave the command line
    f.move(*project((0, 1, 0))); f.key(45)     # delete the cube
    check(ICON(2) == 0x2a2e36, 'cube deleted before reopening')
    cmd(f'file.open {T}/{name}')
    check(ICON(2) == 0xb4b8c0 and bright(px(f, *project((0, 1, 0)))), 'file.open restores the saved scene')
    cmd(f'file.export_obj {T}/a.obj')
    obj = open(f'{T}/a.obj').read().split('\n') if os.path.exists(f'{T}/a.obj') else []
    vs = [l for l in obj if l.startswith('v ')]
    fs = [l for l in obj if l.startswith('f ')]
    ys = sorted({float(l.split()[2]) for l in vs})
    check(len(vs) == 8 and len(fs) == 6 and all(len(l.split()) == 5 for l in fs) and ys == [0.0, 2.0],
          'OBJ export: 8 world-space vertices, 6 quads')
    cmd(f'file.export_stl {T}/a.stl')
    stl = open(f'{T}/a.stl', 'rb').read() if os.path.exists(f'{T}/a.stl') else b''
    check(len(stl) == 84 + 50 * 12 and struct.unpack_from('<I', stl, 80)[0] == 12, 'STL export: 12 triangles, binary layout')
    with open(f'{T}/tet.obj', 'w') as o:
        o.write('# tetrahedron\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nvt 0 0\nvn 0 0 1\n'
                'f 1/1/1 3/1/1 2/1/1\nf 1 2 4\nf -4 -1 -2\nf 2 3 4\n')
    cmd(f'file.import_obj {T}/tet.obj')
    check(ICON(3) == 0xb4b8c0, 'OBJ import adds an object (v/vt/vn and negative indices)')
    cmd(f'file.import_stl {T}/a.stl')
    check(ICON(4) == 0xb4b8c0 or ICON(3) == 0xb4b8c0, 'binary STL import adds an object')
    cmd(f'file.export_obj {T}/b.obj')
    blocks = open(f'{T}/b.obj').read().split('\no ')
    welded = [b for b in blocks if b.startswith('a\n')]
    check(welded and sum(1 for l in welded[0].split('\n') if l.startswith('v ')) == 8,
          'STL import welds 36 corners back into 8 vertices')
    with open(f'{T}/tri.stl', 'w') as o:
        o.write('solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\n'
                'vertex 0 1.5e0 0\nendloop\nendfacet\nendsolid t\n')
    cmd(f'file.import_stl {T}/tri.stl')
    cmd(f'file.export_obj {T}/c.obj')
    check('o tri' in open(f'{T}/c.obj').read(), 'ASCII STL import')
    cmd(f'view.screenshot {T}/s.png')
    from PIL import Image
    ok = os.path.exists(f'{T}/s.png') and Image.open(f'{T}/s.png').size == (1280, 800)
    check(ok, 'view.screenshot writes a PNG of the window')
    if ok:
        Image.open(f'{T}/s.png').load()   # decodes: CRC / zlib / adler are valid
        size = os.path.getsize(f'{T}/s.png')
        check(size < 1280 * 800 * 3 // 8, f'screenshot is deflate-compressed ({size // 1024} KiB)')
    open(f'{T}/bad.bee', 'wb').write(b'BEEM\x01\x00\x00\x00MESH\xff\xff\xff\x7f garbage')
    rows = [ICON(r) for r in range(4)]
    cmd(f'file.open {T}/bad.bee')
    check([ICON(r) for r in range(4)] == rows, 'a corrupt .bee is rejected, the scene stays')
    cmd('create.cube')                   # 25 recorded changes -> autosave
    for _ in range(26):
        f.key(28); f.key(103); f.key(28)     # Enter, Up (history), Enter
    auto = os.path.join(T, 'cache', 'beemodel', 'autosave.bee')
    check(os.path.exists(auto) and open(auto, 'rb').read(4) == b'BEEM', 'autosave after 25 changes')
    f.shot('29_files.png')
    f.proc.kill()


import json
import tempfile


class Mcp:
    """Minimal MCP client over BeeModel's unix socket (newline-delimited
    JSON-RPC), pumping the fake compositor while it waits."""
    def __init__(self, fake):
        self.f, self.next_id = fake, 1
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(50):
            try:
                self.s.connect(os.path.join(fake.home, 'beemodel.sock')); break
            except OSError:
                fake.pump(0.1)
        self.s.setblocking(False)
        self.buf = b''

    def send(self, obj):
        self.s.sendall(json.dumps(obj).encode() + b'\n')

    def call(self, method, params=None, timeout=5.0):
        rid = self.next_id; self.next_id += 1
        msg = {'jsonrpc': '2.0', 'id': rid, 'method': method}
        if params is not None: msg['params'] = params
        self.send(msg)
        end = time.time() + timeout
        while time.time() < end:
            self.f.pump(0.02)
            try:
                chunk = self.s.recv(1 << 20)
                if chunk: self.buf += chunk
            except BlockingIOError:
                pass
            while b'\n' in self.buf:
                line, self.buf = self.buf.split(b'\n', 1)
                r = json.loads(line)
                if r.get('id') == rid:
                    return r
        return None

    def tool(self, name, args=None):
        r = self.call('tools/call', {'name': name, 'arguments': args or {}})
        res = (r or {}).get('result', {})
        return res.get('content', [{}])[0].get('text', ''), res.get('isError')


def mcp():
    """MCP server: protocol, tools, resources, errors and the stdio bridge."""
    print('  -- MCP --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.enter(600, 300)
    m = Mcp(f)
    r = m.call('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                              'clientInfo': {'name': 'test', 'version': '1'}})
    res = (r or {}).get('result', {})
    check(res.get('serverInfo', {}).get('name') == 'beemodel' and res.get('protocolVersion') == '2025-06-18',
          'initialize: server info and protocol version')
    m.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})   # no answer expected
    r = m.call('tools/list')
    names = [t['name'] for t in (r or {}).get('result', {}).get('tools', [])]
    check({'scene_summary', 'create_primitive', 'set_transform', 'select', 'delete', 'undo'} <= set(names)
          and 'op_file_save' in names and 'op_file_exit' not in names,
          f'tools/list: curated tools + {len(names)} total, unsafe operators hidden')
    text, err = m.tool('scene_summary')
    objs = json.loads(text.split('\n')[0]).get('objects', []) if text else []
    check([o['name'] for o in objs] == ['Camera', 'Light', 'Cube'] and objs[2]['location'] == [0, 1, 0],
          'scene_summary returns the default scene as JSON')
    text, err = m.tool('create_primitive', {'type': 'sphere', 'name': 'Ball', 'location': [3, 1, 0]})
    f.pump(0.3)
    check(text.startswith('Ball') and not err and bright(px(f, *project((3, 1, 0)))),
          'create_primitive adds "Ball" at (3,1,0) - visible in the viewport')
    text, err = m.tool('set_transform', {'name': 'Ball', 'location': [0, 3, 0], 'scale': [0.5, 0.5, 0.5],
                                         'rotation_deg': [0, 45, 0]})
    objs = json.loads(m.tool('scene_summary')[0].split('\n')[0])['objects']
    ball = [o for o in objs if o['name'] == 'Ball']
    check(ball and ball[0]['location'] == [0, 3, 0] and ball[0]['scale'] == [0.5, 0.5, 0.5]
          and abs(ball[0]['rotation_deg'][1] - 45) < 0.01, 'set_transform moves, rotates and scales')
    m.tool('select', {'names': ['Cube']})
    objs = json.loads(m.tool('scene_summary')[0].split('\n')[0])['objects']
    check([o['name'] for o in objs if o['selected']] == ['Cube'] and [o['name'] for o in objs if o['active']] == ['Cube'],
          'select makes the Cube the selected, active object')
    m.tool('delete', {'names': ['Ball']})
    names = [o['name'] for o in json.loads(m.tool('scene_summary')[0].split('\n')[0])['objects']]
    check('Ball' not in names, 'delete removes Ball')
    m.tool('undo')
    names = [o['name'] for o in json.loads(m.tool('scene_summary')[0].split('\n')[0])['objects']]
    check('Ball' in names, 'undo brings it back')
    path = os.path.join(f.home, 'agent.bee')
    text, err = m.tool('run_operator', {'id': 'file.save', 'arg': path})
    check(err and 'permission denied' in text and not os.path.exists(path),
          'file access needs the "files" permission (default: edit)')
    f.keymap('tests/keymaps/us.xkb')
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.2); f.key(1)
    cmd('agent.permission_files')
    text, err = m.tool('run_operator', {'id': 'file.save', 'arg': path})
    check(os.path.exists(path) and not err, 'after the user allows files, run_operator file.save writes the scene')
    cmd('agent.permission_read')
    text, err = m.tool('create_primitive', {'type': 'cone', 'name': 'Nope'})
    names = [o['name'] for o in json.loads(m.tool('scene_summary')[0].split('\n')[0])['objects']]
    check(err and 'Nope' not in names, 'read-only agents can look but not edit')
    cmd('agent.permission_edit')
    m.tool('create_primitive', {'type': 'cone', 'name': 'Spike', 'location': [-3, 0, 2]})
    m.tool('set_transform', {'name': 'Spike', 'scale': [1, 3, 1]})
    cmd('edit.undo_history')
    hist = [l.strip() for l in log_lines(f)]
    check('Agent: create_primitive' in hist and 'Agent: set_transform' in hist,
          'each agent request is one named undo step')
    cmd('view.toggle_activity')
    f.pump(0.3)
    f.shot('31_ai_activity.png')
    img = f.image()
    btn = [(x, y) for y in range(560, 800, 2) for x in range(600, 1280, 2) if img.getpixel((x, y)) == (0xe5, 0x48, 0x4d)]
    if btn:
        bx = sum(p[0] for p in btn) // len(btn); by = sum(p[1] for p in btn) // len(btn)
        f.click(bx, by); f.pump(0.3)
    o = {o['name']: o for o in json.loads(m.tool('scene_summary')[0].split('\n')[0])['objects']}
    check(btn and 'Spike' in o and o['Spike']['scale'] == [1, 1, 1],
          'AI Activity: one click reverts the last agent change')
    cmd('view.toggle_activity')
    text, err = m.tool('run_operator', {'id': 'file.exit'})
    check(err and f.proc.poll() is None, 'operators that are not agent-safe are refused')
    text, err = m.tool('op_view_toggle_grid')
    check(text.startswith('ok') and not err, 'operators are callable as tools (op_view_toggle_grid)')
    text, err = m.tool('no_such_tool')
    check(err, 'unknown tool reports isError')
    r = m.call('tools/call', {'name': 'viewport_capture', 'arguments': {}})
    content = (r or {}).get('result', {}).get('content', [])
    img = [c for c in content if c.get('type') == 'image']
    ok = len(img) == 1 and img[0].get('mimeType') == 'image/png'
    if ok:
        import base64, io
        from PIL import Image
        data = base64.b64decode(img[0]['data'])
        im = Image.open(io.BytesIO(data)).convert('RGB')
        w, h = im.size
        ok = 300 < w < 1280 and 300 < h < 800 and f'{w} x {h}' in content[0].get('text', '')
        open(os.path.join(OUT, '31_capture.png'), 'wb').write(data)
        print(f'     capture {w}x{h}, {len(data) // 1024} KiB PNG')
    check(ok, 'viewport_capture returns the viewport as a base64 PNG image block')
    r = m.call('tools/call', {'name': 'viewport_capture', 'arguments': {'area': 'window'}})
    img = [c for c in (r or {}).get('result', {}).get('content', []) if c.get('type') == 'image']
    if img:
        from PIL import Image
        import base64, io
        win = Image.open(io.BytesIO(base64.b64decode(img[0]['data']))).convert('RGB')
        f.pump(0.3)
        same = win.tobytes() == f.image().tobytes()
    check(img and win.size == (1280, 800) and same, 'viewport_capture area=window matches the presented frame')
    r = m.call('resources/read', {'uri': 'bee://scene'})
    txt = (r or {}).get('result', {}).get('contents', [{}])[0].get('text', '')
    check('"objects"' in txt, 'resources/read bee://scene')
    r = m.call('no/such/method')
    check((r or {}).get('error', {}).get('code') == -32601, 'unknown method: JSON-RPC error -32601')
    # the stdio bridge, as Claude Code would launch it
    b = subprocess.Popen([BIN, '--mcp-bridge'], env=f.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    b.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': 7, 'method': 'ping'}).encode() + b'\n'); b.stdin.flush()
    line = b''
    end = time.time() + 5
    os.set_blocking(b.stdout.fileno(), False)
    while time.time() < end and not line.endswith(b'\n'):
        f.pump(0.05)
        try:
            line += os.read(b.stdout.fileno(), 65536)
        except BlockingIOError:
            pass
    check(json.loads(line or b'{}').get('id') == 7, '--mcp-bridge relays JSON-RPC over stdio')
    b.stdin.close(); b.wait(timeout=5)
    f.shot('30_mcp.png')
    f.proc.kill()


def edit_mode():
    """Edit mode: select vertices / edges / faces, transform them, undo."""
    print('  -- edit mode --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(*project((0, 1, 0)))
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    corner = project((1, 2, 1))                 # cube vertex 6, facing the camera
    f.key(15)                                   # Tab
    check(px(f, *corner) == 0x0b0c0e, 'Tab enters edit mode: vertex dots are drawn')
    f.click(*corner)
    check(q('selected("Cube")') == '= 1' and q('vsel("Cube", 6)') == '= 1' and px(f, *corner) == 0xffa233,
          'clicking a vertex selects it')
    f.key(34); f.key(45); f.key(3); f.key(28)   # G X 2 Enter
    f.pump(0.2)
    check(q('vpos("Cube", 6, "x")') == '= 3' and q('get("Cube", "x")') == '= 0'
          and px(f, *project((3, 2, 1))) == 0xffa233, 'G X 2 moves the vertex, not the object')
    f.shot('34_edit_vertex.png')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    check(q('vpos("Cube", 6, "x")') == '= 1', 'undo restores the vertex')
    f.key(4)                                    # 3: face mode
    f.click(*project((0.2, 2, -0.3)))           # the top face
    top = q('selected("Cube")'), [q(f'vsel("Cube", {i})') for i in (4, 5, 6, 7)]
    c = px(f, *project((0.3, 2, 0.3)))
    r, g, b = c >> 16, (c >> 8) & 255, c & 255
    check(top == ('= 4', ['= 1'] * 4) and r > g > b, 'face mode: clicking the top face selects it (tinted)')
    f.shot('35_edit_face.png')
    f.key(30)                                   # A: some selected -> none
    n0 = q('selected("Cube")')
    f.key(30)                                   # A: all
    check(n0 == '= 0' and q('selected("Cube")') == '= 8', 'A deselects, then selects everything')
    f.key(2); f.key(30)                         # vertex mode, deselect all
    f.key(48)                                   # B, then drag around the corner
    f.drag(corner[0] - 15, corner[1] - 15, corner[0] + 15, corner[1] + 15)
    check(q('selected("Cube")') == '= 1' and q('vsel("Cube", 6)') == '= 1', 'B box-selects the vertex inside')
    f.key(15)                                   # Tab: back to object mode
    q('delete("Cube"); g = add("grid", "G"); scale(g, 4); edit(g)')
    f.pump(0.3)
    f.mods(8); f.click(*project((1.6, 0, 0))); f.mods(0)   # Alt+click a grid edge on z = 0
    row = q('n = 0\nfor i in 0..verts("G") { if vsel("G", i) { if vpos("G", i, "z") == 0 { n += 1 } } }\nn')
    check(q('selected("G")') == '= 11' and row == '= 11', 'Alt+click selects the whole edge loop (11 vertices)')
    f.shot('36_edit_loop.png')
    f.mods(4); f.key(38); f.mods(0)             # Ctrl+L: everything connected
    check(q('selected("G")') == '= 121', 'Ctrl+L selects linked geometry')
    f.proc.kill()


def mesh_ops():
    """Modeling operators driven from the keyboard (modal) and checked by script."""
    print('  -- mesh operators --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(*project((0, 1, 0)))
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.key(15); f.key(4)                         # Tab, face mode
    f.click(*project((0.2, 2, -0.3)))           # top face
    f.key(18); f.type('1'); f.key(28)           # E 1 Enter: extrude along the normal
    check(q('print(faces("Cube"), volume("Cube"))') == '10 12' and q('vpos("Cube", 8, "y")') in ('= 2', '= 1'),
          'E extrudes the top face and moves it 1 m along its normal')
    f.shot('37_extrude.png')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z: extrude + move is one step
    check(q('print(faces("Cube"), volume("Cube"))') == '6 8', 'one undo removes the whole extrusion')
    f.click(*project((0.2, 2, -0.3)))
    f.key(23); f.type('0.3'); f.key(28)         # I 0.3 Enter
    check(q('print(faces("Cube"), verts("Cube"), selected("Cube"))') == '10 12 4', 'I insets the face (0.3 m)')
    f.key(23); f.key(1)                         # I, then Esc: nothing changes
    check(q('faces("Cube")') == '= 10', 'Esc cancels a modal inset')
    f.mods(4); f.key(44); f.mods(0)             # undo: the inset (Esc left no step)
    check(q('faces("Cube")') == '= 6', 'a cancelled inset leaves no undo step')
    f.click(*project((0.2, 2, -0.3)))
    f.key(45)                                   # X: delete the face
    check(q('print(faces("Cube"), verts("Cube"))') == '5 8', 'X deletes the selected face')
    q('vselect("Cube", 4, 5, 6, 7)')
    f.key(33)                                   # F: fill the hole again
    check(q('print(faces("Cube"), volume("Cube"))') == '6 8', 'F fills the hole (normal outwards)')
    q('vselect("Cube", 0, 1, 2, 3, 4, 5, 6, 7); op("mesh.subdivide")\n'
      'vselect("Cube")\nfor i in 0..verts("Cube") { if vpos("Cube", i, "y") == 1 { vsel("Cube", i, 1) } }')
    f.mods(4); f.key(45); f.mods(0)             # Ctrl+X dissolve the 4 top faces into one
    n = q('faces("Cube")')
    flipped = q('for i in 0..verts("Cube") { vsel("Cube", i, 1) }\nop("mesh.flip_normals"); vselect("Cube")\nvolume("Cube")')
    f.mods(1); f.key(49); f.mods(0)             # Shift+N recalculate (all: nothing selected)
    check(n == '= 21' and float(flipped[2:]) < -7.9 and float(q('volume("Cube")')[2:]) > 7.9,
          f'Ctrl+X dissolves the top faces into one ({n}); Shift+N turns flipped faces outwards')
    f.shot('38_mesh_ops.png')
    f.proc.kill()


def mesh_tools():
    """Loop cut, knife, bevel (modal), the 3D cursor."""
    print('  -- loop cut, knife, bevel, cursor --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(*project((0, 1, 0)))
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.key(15)                                   # Tab
    f.mods(4); f.key(19); f.mods(0)             # Ctrl+R: loop cut tool
    f.move(*project((1, 0.7, 1))); f.pump(0.2)  # hover the front vertical edge
    f.shot('39_loopcut_preview.png')
    f.click(*project((1, 0.7, 1)))
    check(q('print(faces("Cube"), verts("Cube"), volume("Cube"))') == '10 12 8', 'Ctrl+R + click cuts a loop around the cube')
    f.mods(4); f.key(44); f.mods(0)             # undo
    check(q('faces("Cube")') == '= 6', 'undo removes the loop cut')
    f.key(37)                                   # K: knife across the top face
    f.click(*project((-1.3, 2, 0.2))); f.click(*project((1.3, 2, -0.2)))
    f.key(28)
    n = q('faces("Cube")')
    check(n != '= 6' and q('volume("Cube")') == '= 8', f'the knife splits faces ({n}), volume unchanged')
    f.mods(4); f.key(44); f.mods(0)
    q('vselect("Cube", 5, 6)')
    f.mods(4); f.key(48); f.mods(0)             # Ctrl+B 0.2 Enter
    f.type('0.2'); f.key(28)
    check(q('print(verts("Cube"), faces("Cube"), volume("Cube"))') == '10 7 7.96', 'Ctrl+B 0.2 bevels the edge (volume 7.96)')
    f.mods(4); f.key(44); f.mods(0)
    q('vselect("Cube", 5, 6)')
    f.mods(4); f.key(48); f.mods(0)             # Ctrl+B, wheel: 3 segments
    f.wheel(-1); f.wheel(-1)
    f.type('0.3'); f.key(28)
    check(q('print(verts("Cube"), faces("Cube"))') == '14 9', 'the wheel sets bevel segments (3; the end faces take the round)')
    f.shot('40_bevel.png')
    f.key(15)                                   # object mode; Shift+RMB places the cursor
    f.mods(1); f.click(*project((4, 0, 4)), btn=0x111); f.mods(0)
    q('add("cylinder", "Cyl")')
    cyl = [o for o in json.loads(m.tool('scene_summary')[0].split('\n')[0])['objects'] if o['name'] == 'Cyl']
    loc = cyl[0]['location'] if cyl else None
    check(loc is not None and abs(loc[0] - 4) < 0.3 and abs(loc[2] - 4) < 0.3 and abs(loc[1]) < 0.05,
          f'Shift+RMB places the 3D cursor on the ground; new objects appear there {loc}')
    f.shot('41_cursor.png')
    f.proc.kill()


def redo_panel():
    """Adjust the last operation: panel drag, F9, agents; still one undo step."""
    print('  -- redo panel --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(*project((0, 1, 0)))
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.key(15); f.key(4)
    f.click(*project((0.2, 2, -0.3)))           # top face
    f.key(18); f.type('1'); f.key(28)           # E 1 Enter
    f.pump(0.2)
    panel = px(f, 322, 548)
    f.shot('42_redo_panel.png')
    check(q('volume("Cube")') == '= 12' and panel == 0x2d313a, 'after E 1 the redo panel shows the distance')
    text, err = m.tool('run_operator', {'id': 'edit.redo_last', 'arg': '2'})
    check(not err and q('volume("Cube")') == '= 16', 'an agent re-runs it with distance 2 (edit.redo_last)')
    f.drag(470, 577, 570, 577, steps=4)         # +100 px * 0.01 = +1 m
    check(q('volume("Cube")') == '= 20', 'dragging the value re-runs the extrusion (3 m)')
    f.key(67)                                   # F9: values on the command line
    f.key(14); f.type('0.5'); f.key(28)
    check(q('volume("Cube")') == '= 10', 'F9 + a typed value (0.5 m)')
    f.key(1)
    f.mods(4); f.key(44); f.mods(0)             # one undo: the cube again
    check(q('print(volume("Cube"), faces("Cube"))') == '8 6', 'all of it is still one undo step')
    f.proc.kill()


def modifiers_ui():
    """The modifier stack in the properties editor."""
    print('  -- modifiers --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.mods(4); f.key(3); f.mods(0)              # Ctrl+2: subdivision surface
    check(q('print(modcount("Cube"), efaces("Cube"))') == '1 96', 'Ctrl+2 adds a Subsurf modifier (level 2)')
    f.drag(1150, 355, 1162, 355, steps=3)       # levels +1
    check(q('efaces("Cube")') == '= 384', 'dragging the levels field re-evaluates (level 3)')
    f.mods(4); f.key(44); f.mods(0)
    check(q('efaces("Cube")') == '= 96', 'one undo reverts the whole drag')
    f.click(1238, 311); f.pump(0.2)             # + Add -> Mirror
    f.click(1098, 339); f.pump(0.2)
    check(q('modcount("Cube")') == '= 2', 'the Add menu adds a Mirror modifier')
    f.shot('43_modifiers.png')
    f.click(1249, 334); f.pump(0.2)             # x on the first (Subsurf)
    check(q('print(modcount("Cube"), efaces("Cube"))') == '1 12', 'the x button removes Subsurf (Mirror stays)')
    f.click(1214, 334); f.pump(0.2)             # Apply the Mirror
    check(q('print(modcount("Cube"), verts("Cube"), faces("Cube"))') == '0 16 12', 'Apply makes the mirror part of the mesh')
    f.proc.kill()


def booleans():
    """Mesh booleans: the Edit menu operators, one undo step, the modifier."""
    print('  -- booleans --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('add("cube", "Cutter", 1, 1.5, 1); scale("Cutter", 0.6); select("Cutter", "Cube")')
    f.click(70, 44); f.pump(0.2)                # Edit > Boolean Difference
    f.click(140, 258); f.pump(0.3)
    r = q('print(exists("Cutter"), manifold("Cube"), round(volume("Cube") * 1000))').split()
    check(r == ['0', '1', '7604'], f'Edit > Boolean Difference cuts the corner (closed, volume {r[-1] if r else "?"} / 7604)')
    f.shot('44_boolean.png')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    check(q('print(exists("Cutter"), faces("Cube"))') == '1 6', 'one undo brings back both objects')
    q('select("Cutter", "Cube"); modifier("Cube", "boolean")')
    r = q('print(faces("Cube"), efaces("Cube") > 6, manifold("Cube"))')
    check(r == '6 1 1', 'a Boolean modifier takes the other selected mesh, the base stays 6 faces')
    q('move("Cutter", 5, 0, 0)')
    check(q('efaces("Cube")') == '= 6', 'moving its object re-evaluates the modifier')
    q('modset("Cube", 0, "operation", 0); move("Cutter", 1, 1.5, 1)')
    r = q('modapply("Cube", 0); print(manifold("Cube"), round(volume("Cube") * 1000))')
    check(r == '1 9332', f'union through the modifier, applied: closed, volume {r} / 1 9332')
    f.proc.kill()


def analysis_repair():
    """Mesh analysis overlays (View > Show ...) and Edit > Repair Mesh."""
    print('  -- analysis and repair --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('edit("Cube"); op("mesh.select_mode_face"); vselect("Cube", 4, 5, 6, 7); op("mesh.delete"); edit(); select("Cube")')
    check(q('print(analyze("Cube", "boundary"), analyze("Cube", "overhang"), manifold("Cube"))') == '4 1 0',
          'analyze(): the deleted top face leaves 4 boundary edges, the bottom overhangs')
    f.click(130, 44); f.pump(0.2)              # View > Show Boundary Edges
    f.click(200, 435); f.pump(0.3)
    img = f.image().crop((214, 80, 1014, 620))
    cyan = sum(1 for c in img.getdata() if c == (0x40, 0xe0, 0xe0))
    check(cyan > 100, f'View > Show Boundary Edges marks the hole ({cyan} px)')
    f.shot('45_analysis.png')
    f.click(70, 44); f.pump(0.2)               # Edit > Repair Mesh
    f.click(140, 306); f.pump(0.3)
    check(q('print(analyze("Cube", "boundary"), manifold("Cube"), faces("Cube"))') == '0 1 6',
          'Edit > Repair Mesh fills the hole: closed, 6 faces')
    img = f.image().crop((214, 80, 1014, 620))
    cyan = sum(1 for c in img.getdata() if c == (0x40, 0xe0, 0xe0))
    check(cyan == 0, 'no boundary left to mark')
    f.mods(4); f.key(44); f.mods(0)            # Ctrl+Z
    check(q('analyze("Cube", "boundary")') == '= 4', 'one undo brings the hole back')
    r = q('add("sphere", "S", 4, 0, 0); edit("S"); op("mesh.select_all"); op("mesh.flip_normals"); edit()\n'
          'select("S"); a = volume("S"); op("mesh.repair", "0.001"); print(a < 0, volume("S") > 0, manifold("S"))')
    check(r == '1 1 1', 'repair turns an inside-out sphere outward')
    f.proc.kill()


def hardsurface_walkthrough():
    """A small hard-surface part, start to finish, mostly from the keyboard and
    the menus: pocket, through hole (boolean), beveled edges (modifier), a
    closed result that survives save / open and exports."""
    print('  -- hard-surface walkthrough --')
    t0 = time.time()
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(*project((0, 1, 0)))
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.2); f.key(1)
    f.key(15); f.key(4)                         # Tab, face mode
    f.click(*project((0.2, 2, -0.3)))           # the top face
    f.key(23); f.type('0.3'); f.key(28)         # I 0.3: inset
    f.key(18); f.type('-0.5'); f.key(28)        # E -0.5: a pocket
    f.key(15)                                   # object mode
    check(q('print(faces("Cube"), round(volume("Cube") * 100))') == '14 702',
          'inset + extrude down: a 1.4 x 1.4 x 0.5 pocket in the top')
    f.click(181, 44); f.pump(0.2)              # Create > Cylinder (at the 3D cursor)
    f.click(200, 120); f.pump(0.3)
    f.key(31); f.type('0.3'); f.key(28)         # S 0.3
    f.key(31); f.key(21); f.type('4'); f.key(28)  # S Y 4: 2.4 tall
    f.key(34); f.key(21); f.type('1'); f.key(28)  # G Y 1: through the part
    f.mods(1); f.click(*project((0.9, 0.5, 1))); f.mods(0)   # Shift+click the cube
    check(q('print(active())') == 'Cube', 'Shift+click makes the cube active, the cylinder stays selected')
    f.click(70, 44); f.pump(0.2)               # Edit > Boolean Difference
    f.click(140, 258); f.pump(0.3)
    r = q('print(exists("Cylinder"), manifold("Cube"), round(volume("Cube") * 1000))').split()
    check(r[:2] == ['0', '1'] and r[2] == '6599', f'Edit > Boolean Difference drills the hole: closed, volume {r[2] if len(r) > 2 else "?"} / 6599')
    f.click(1238, 311); f.pump(0.2)            # Properties: + Add > Bevel
    f.click(1095, 435); f.pump(0.3)
    r = q('print(modcount("Cube"), efaces("Cube") > faces("Cube"))')
    check(r == '1 1', 'the Bevel modifier rounds the edges (more faces after it)')
    f.move(*project((0, 1, 0)))
    for _ in range(6):
        f.wheel(-1)                             # zoom in on the part
    f.pump(0.2)
    f.shot('46_walkthrough.png')
    f.click(1214, 334); f.pump(0.3)            # Apply
    r = q('print(modcount("Cube"), manifold("Cube"), analyze("Cube", "nonmanifold"), analyze("Cube", "degenerate"))')
    check(r == '0 1 0 0', f'applied: closed, no non-manifold edges, no degenerate faces ({r})')
    path = os.path.join(f.home, 'part.bee')
    stl = os.path.join(f.home, 'part.stl')
    v = q('print(faces("Cube"), round(volume("Cube") * 1000))')
    cmd(f'file.save {path}')
    cmd('file.new')
    cmd(f'file.open {path}')
    check(q('print(faces("Cube"), round(volume("Cube") * 1000))') == v, f'saved and opened again: the same part ({v})')
    q('select("Cube")')
    cmd(f'file.export_stl {stl}')
    tris = int(q('print(faces("Cube"))') or 0)
    size = os.path.getsize(stl) if os.path.exists(stl) else 0
    check(size > 84 and (size - 84) % 50 == 0, f'exported as STL ({(size - 84) // 50 if size else 0} triangles)')
    dt = time.time() - t0
    check(dt < WALKTHROUGH_BUDGET_S, f'the whole walkthrough in {dt:.1f} s (budget {WALKTHROUGH_BUDGET_S} s)')
    f.proc.kill()


def materials_ui():
    """Materials: + New in Properties, dragging a value, undo, the viewport
    colour, files, scripts and agents."""
    print('  -- materials --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    grey = px(f, *project((0.3, 2, 0.3)))
    f.click(1238, 341); f.pump(0.3)             # Material: + New
    check(q('print(matof("Cube"), matget("Material", "roughness"))') == 'Material 0.5',
          'Properties > Material > + New makes a material and gives it to the cube')
    f.drag(1140, 425, 1180, 425, steps=4)       # roughness +40 px
    r = q('matget("Material", "roughness")')
    check(r == '= 0.7', f'dragging roughness changes it ({r})')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    check(q('matget("Material", "roughness")') == '= 0.5', 'one undo reverts the whole drag')
    q('matset("Material", "base", 1, 0.766, 0.336)')
    f.pump(0.3)
    gold = px(f, *project((0.3, 2, 0.3)))
    check(gold != grey and (gold >> 16) > (gold & 0xff) + 40, f'the viewport shows the base colour ({gold:06x}, was {grey:06x})')
    f.shot('47_material.png')
    f.mods(1); f.key(44); f.mods(0)             # Shift+Z: material preview
    f.pump(0.3)
    top, side = px(f, *project((0.3, 2, 0.3))), px(f, *project((1, 1, 0.2)))
    check(top != gold and top != side and (side >> 16) > (side & 0xff),
          f'Shift+Z: material preview lights the material ({top:06x} top, {side:06x} side)')
    f.shot('48_material_preview.png')
    f.mods(1); f.key(44); f.mods(0)             # back to solid
    s = json.loads(m.tool('scene_summary')[0].split('\n')[0])
    cube = [o for o in s['objects'] if o['name'] == 'Cube'][0]
    check(cube.get('material') == 'Material' and s['materials'][0]['base'] == [1, 0.766, 0.336],
          'scene_summary shows the material and its values to agents')
    f.mods(4); f.key(44); f.mods(0)             # undo the colour, then the + New
    f.mods(4); f.key(44); f.mods(0)
    check(q('print(matof("Cube"), count())') == 'nil 3', 'undo removes the material again')
    f.mods(5); f.key(44); f.mods(0)             # Ctrl+Shift+Z twice
    f.mods(5); f.key(44); f.mods(0)
    check(q('print(matof("Cube"), matget("Material", "base", 1))') == 'Material 0.766', 'redo brings it back')
    path = os.path.join(f.home, 'mat.bee')
    q(f'op("file.save", "{path}"); op("file.new"); op("file.open", "{path}")')
    check(q('print(matof("Cube"), matget("Material", "base", 1))') == 'Material 0.766', 'materials are saved and opened')
    f.proc.kill()


def scripting():
    """BeeScript: console REPL, one undo step per run, macros, script_eval."""
    print('  -- BeeScript --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(*project((0, 1, 0)))
    m = Mcp(f)
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.2)
    def names():
        t = m.tool('scene_summary')[0]
        return [o['name'] for o in json.loads(t.split('\n')[0])['objects']] if t else []
    def obj(n):
        t = m.tool('scene_summary')[0]
        return {o['name']: o for o in json.loads(t.split('\n')[0])['objects']}.get(n)
    cmd('x = 3')
    cmd('add("cube", "Tower" + x, 4, 0, 0)')
    f.pump(0.3)
    check('Tower3' in names() and bright(px(f, *project((4, 0, 0)))),
          'console runs BeeScript: variables persist, add() places "Tower3" at (4,0,0)')
    cmd('for i in 0..3 { add("sphere", "B" + i, -4, i * 2, 0) }')
    check({'B0', 'B1', 'B2'} <= set(names()), 'a for loop adds three spheres')
    f.key(1)                                   # leave the command line
    f.mods(4); f.key(44); f.mods(0)            # Ctrl+Z
    n = names()
    check('B0' not in n and 'B2' not in n and 'Tower3' in n, 'the whole script is one undo step')
    f.shot('32_script_console.png')
    # macro: record a created cone and a typed move, replay it in a new scene
    cmd('script.record')
    cmd('create.cone')
    f.key(1)
    f.move(*project((0, 1, 0)))
    f.key(34); f.key(45); f.key(3); f.key(28)  # G X 2 Enter
    cmd('script.record')
    path = os.path.join(f.home, 'BeeModel', 'scripts', 'macro.bees')
    mac = open(path).read() if os.path.exists(path) else ''
    check('op("create.cone")' in mac and 'move("Cone", 2, 0, 0)' in mac,
          f'macro recorded as BeeScript ({mac.count(chr(10))} lines)')
    cmd('file.new')
    check('Cone' not in names(), 'file.new clears the scene')
    cmd('script.run')
    c = obj('Cone')
    check(c is not None and c['location'] == [2, 0, 0], 'script.run replays the macro: Cone at (2,0,0)')
    # agents
    text, err = m.tool('script_eval', {'code': 'for i in 0..4 { add("cube", "M" + i, i * 2, 0, -4) }\nprint(count(), "objects")\ncount()'})
    check(not err and 'objects' in text and '= ' in text and {'M0', 'M3'} <= set(names()),
          f'script_eval runs for an agent: {text.splitlines()[0] if text else ""}')
    m.tool('undo')
    check('M0' not in names() and 'Cone' in names(), 'one undo reverts the agent script')
    text, err = m.tool('script_eval', {'code': 'op("file.exit")'})
    check(err and 'not allowed for agents' in text and f.proc.poll() is None,
          'agent scripts may only run agent-safe operators')
    text, err = m.tool('script_eval', {'code': 'x = (1 +'})
    check(err and text.startswith('error: line 1'), 'script errors come back as isError with the line')
    f.shot('33_script_agent.png')
    f.proc.kill()


def beescript_cli():
    """The language itself, headless: beemodel --eval."""
    print('  -- BeeScript language (--eval) --')
    env = dict(os.environ, HOME=tempfile.mkdtemp(prefix='bee-eval-'), XDG_CACHE_HOME='')
    cases = [
        ('print(1 + 2 * 3, (1 + 2) * 3, 7 % 3, -7 % 3, 10 / 4)', '7 9 1 2 2.5'),
        ('print(2m + 50cm, 10mm, 1km, 180deg / pi, 1e3, 1.5e-2)', '2.5 0.01 1000 1 1000 0.015'),
        ('print(0.1 + 0.2, 1 / 3, 2 / 3, 1e20, 0.00001234, -0.5)', '0.3 0.333333 0.666667 1e20 1.234e-5 -0.5'),
        ('print("a" + 1, "x" == "x", 1 != 1, not nil, 3 > 2 and 2 > 3, 0 or "y")', 'a1 1 0 1 0 y'),
        ('fn fib(n) { if n < 2 { return n }\n return fib(n - 1) + fib(n - 2) }\nprint(fib(20))', '6765'),
        ('s = 0\nfor i in 0..10 { if i == 3 { continue }\n if i == 6 { break }\n s += i }\nprint(s)', '12'),
        ('i = 0; while i < 5 { i += 2 }; print(i)', '6'),
        ('if 0 { print(1) } else if 2 > 1 { print(2) } else { print(3) }', '2'),
        ('print(pow(2, 10), pow(4, 0.5), round(2.5), floor(-0.5), abs(-2), min(3, 1), max(3, 1))', '1024 2 3 -1 2 1 3'),
        ('print(sin(90deg), cos(180deg), atan2(1, 0) / 1deg, sqrt(16), len("four"), num("2.5"))', '1 -1 90 4 4 2.5'),
        ('seed(7); a = rand(); seed(7); print(a == rand(), a >= 0 and a < 1)', '1 1'),
        ('print(count(), name(2), active())', '3 Cube Cube'),
        ('b = add("torus", "T", 1, 2, 3); move(b, 0, 5, 0); print(b, get(b, "y"), count())', 'T 5 4'),
        ('x = 1 + nil', 'error: line 1: + needs two numbers, or a text'),
        ('\n\nprint(y)', 'error: line 3: not defined: y'),
        ('for i in 0..3 {', 'error: line 1: missing }'),
        ('fn f(a) { return a }\nf()', 'error: line 2: wrong number of arguments for f'),
        ('while 1 { }', 'error: line 1: stopped after 500 million steps (endless loop?)'),
    ]
    bad = []
    for code, want in cases:
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=20)
        got = r.stdout.strip()
        if got != want or (r.returncode != 0) != want.startswith('error'):
            bad.append(f'{code!r}: got {got!r} (rc {r.returncode}), want {want!r}')
    for b in bad:
        print('     ' + b)
    check(not bad, f'{len(cases) - len(bad)}/{len(cases)} language cases')
    t0 = time.time()
    r = subprocess.run([BIN, '--eval', 's = 0\nfor i in 0..1000000 { s += i }\nprint(s)'], env=env,
                       capture_output=True, text=True, timeout=20)
    ms = (time.time() - t0) * 1000
    check(r.stdout.strip() == '499999500000' and ms < 1000, f'1M loop iterations in {ms:.0f} ms')


MODELING_BUDGETS_MS = {           # tests/perf_modeling.bees, on a 4-core CI runner
    'subsurf_build': 150.0,         # level 2 over a 127k-face sphere (508k faces)
    'subsurf_update': 30.0,         # the same after a vertex moved (cached topology)
    'analyze': 60.0,                # boundary / non-manifold / ... of 127k faces
    'repair': 400.0,                # mesh.repair on 127k faces
    'boolean': 1000.0,              # 254k triangles minus a slab, closed result
}


def modeling_budgets():
    """Performance budgets of the modeling core (headless, BeeScript timings)."""
    print('  -- modeling performance budgets --')
    env = dict(os.environ, HOME=tempfile.mkdtemp(prefix='bee-perf-'), XDG_CACHE_HOME='')
    path = os.path.join(os.path.dirname(__file__), '..', 'tests', 'perf_modeling.bees')
    r = subprocess.run([BIN, '--run', path], env=env, capture_output=True, text=True, timeout=120)
    got = {}
    for line in r.stdout.splitlines():
        p = line.split()
        if len(p) >= 2 and p[0] in MODELING_BUDGETS_MS:
            got[p[0]] = (float(p[1]), p[2:])
    for name, budget in MODELING_BUDGETS_MS.items():
        ms, extra = got.get(name, (None, []))
        ok = ms is not None and ms < budget and (name != 'boolean' or extra == ['1'])
        check(ok, f'{name}: {ms if ms is None else round(ms, 1)} ms (budget {budget:.0f} ms)')


HIVE_SCENE = (
    'add("plane", "Floor"); scale("Floor", 6)\n'
    'g = material("Gold"); matset(g, "base", 1, 0.766, 0.336); matset(g, "metallic", 1); matset(g, "roughness", 0.25); assign("Cube", g)\n'
    'r = material("Red"); matset(r, "base", 0.8, 0.05, 0.04); matset(r, "roughness", 0.4); matset(r, "clearcoat", 1)\n'
    'add("sphere", "S", 2.5, 1, 0.5); assign("S", r)\n'
    'c = material("Glass"); matset(c, "transmission", 1); matset(c, "roughness", 0.02)\n'
    'add("sphere", "G", -0.5, 0.8, 2.6); scale("G", 0.8); assign("G", c)\n')
HIVE_BUDGET_MS = 8000.0            # 480 x 270 x 64 samples on a 4-core CI runner
DENOISE_GAIN = 0.65                # denoised error / noisy error, 16 samples
DENOISE_BUDGET_MS = 600.0          # denoising 1080p on a 4-core CI runner


def hive_render():
    """The Hive path tracer, headless: a material scene, energy, budgets."""
    print('  -- Hive path tracer --')
    from PIL import Image
    home = tempfile.mkdtemp(prefix='bee-hive-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code, extra=None):
        e = dict(env, **(extra or {}))
        r = subprocess.run([BIN, '--eval', code], env=e, capture_output=True, text=True, timeout=120)
        return r.stdout.strip()
    out = os.path.join(home, 'shot.png')
    ms = run(HIVE_SCENE + f'print(render("{out}", 480, 270, 64))')
    ok = os.path.exists(out) and Image.open(out).size == (480, 270)
    check(ok, f'render() path-traces the scene into a 480 x 270 PNG ({ms} ms)')
    if ok:
        Image.open(out).save(os.path.join(OUT, '49_hive.png'))
    try:
        t = float(ms)
    except ValueError:
        t = 1e9
    check(t < HIVE_BUDGET_MS, f'480 x 270 x 64 samples in {t:.0f} ms (budget {HIVE_BUDGET_MS:.0f} ms)')
    # white furnace: a white diffuse sphere in a uniform sky disappears
    furn = os.path.join(home, 'f.png')
    base = ('delete("Cube"); delete("Light"); m = material("M"); matset(m, "roughness", 1); matset(m, "specular", 0); '
            'add("sphere", "S", 0, 0, 0); scale("S", 2); assign("S", m); ')
    run(base + f'matset(m, "base", 1, 1, 1); render("{furn}", 160, 90, 128)', {'BEEMODEL_HIVE_DEBUG': '3'})
    im = Image.open(furn).convert('RGB')
    c, bg = im.getpixel((80, 45)), im.getpixel((2, 2))
    check(abs(c[0] - bg[0]) <= 2, f'white furnace: the sphere vanishes ({c[0]} vs {bg[0]} around it)')
    run(base + f'matset(m, "base", 0.5, 0.5, 0.5); render("{furn}", 160, 90, 128)', {'BEEMODEL_HIVE_DEBUG': '3'})
    c = Image.open(furn).convert('RGB').getpixel((80, 45))
    check(abs(c[0] - 156) <= 3, f'... and a 50% grey one reflects half (pixel {c[0]}, expected 156)')
    # convergence: the noise falls like 1 / sqrt(samples)
    sds = []
    for n in (4, 64):
        p = os.path.join(home, f'c{n}.png')
        run(f'add("plane", "Floor"); scale("Floor", 6); render("{p}", 160, 90, {n})', {'BEEMODEL_HIVE_DEBUG': '2'})
        g = [v[1] for v in Image.open(p).convert('RGB').crop((0, 75, 40, 90)).getdata()]
        mean = sum(g) / len(g)
        sds.append((sum((v - mean) ** 2 for v in g) / len(g)) ** 0.5)
    check(sds[1] < sds[0] / 2.5, f'noise falls with samples (sd {sds[0]:.1f} at 4, {sds[1]:.1f} at 64)')
    # the denoiser: 16 samples + denoise against a 512-sample reference
    def rmse(a, b):
        a, b = Image.open(a).convert('RGB'), Image.open(b).convert('RGB')
        d = [(p[i] - q[i]) ** 2 for p, q in zip(a.getdata(), b.getdata()) for i in range(3)]
        return (sum(d) / len(d)) ** 0.5
    shots = {}
    for name, spp, dn in (('ref', 512, 0), ('n16', 16, 0), ('d16', 16, 1)):
        shots[name] = os.path.join(home, f'{name}.png')
        ms = run(HIVE_SCENE + f'print(render("{shots[name]}", 160, 90, {spp}, {dn}))')
    en, ed = rmse(shots['n16'], shots['ref']), rmse(shots['d16'], shots['ref'])
    check(ed < en * DENOISE_GAIN, f'denoising 16 samples cuts the error (rmse {en:.1f} -> {ed:.1f}, at most x{DENOISE_GAIN})')
    for name in ('n16', 'd16'):
        Image.open(shots[name]).save(os.path.join(OUT, f'49_hive_{name}.png'))
    ms = [run(f'print(render("{os.path.join(home, "big.png")}", 1920, 1080, 1, {dn}))') for dn in (0, 1)]
    try:
        t = float(ms[1]) - float(ms[0])
    except ValueError:
        t = 1e9
    check(t < DENOISE_BUDGET_MS, f'denoising 1920 x 1080 takes {t:.0f} ms (budget {DENOISE_BUDGET_MS:.0f} ms)')
    # agents: rendering writes a file, so it needs file access
    f = Fake()
    f.pump(1.0, until_frame=True)
    m = Mcp(f)
    text, err = m.tool('script_eval', {'code': f'render("{os.path.join(home, "a.png")}", 32, 18, 1)'})
    check(err and 'permission' in text, 'agents need file access to render')
    f.proc.kill()


RENDER_LATENCY_MS = 60.0           # input -> frame while a render runs (median)


def render_window():
    """The Render window: F12 renders progressively in its own area while the
    UI stays live; Esc stops; passes, saving, settings in .bee, agents."""
    print('  -- Render window --')
    from PIL import Image
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(400, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.2)
    q('op("render.settings", "320 180 100000")')
    pane = px(f, 815, 362)
    f.key(88)                                   # F12
    f.pump(1.0)
    img = px(f, 815, 362)
    check(img != pane and px(f, 700, 200) == 0x2a2e36,
          f'F12 opens a Render area beside the viewport and shows the image ({img:06x})')
    n0 = f.frames
    f.pump(1.0)
    fps = f.frames - n0
    check(fps >= 15, f'the Render area refines continuously ({fps} frames in 1 s)')
    f.latencies = []
    from PIL import ImageChops
    before = f.image().crop((214, 80, 612, 623))
    f.drag(400, 300, 480, 330, steps=10)        # orbit the viewport meanwhile
    lat = sorted(f.latencies)
    med = lat[len(lat) // 2] if lat else 1e9
    moved = ImageChops.difference(before, f.image().crop((214, 80, 612, 623))).getbbox() is not None
    check(med < RENDER_LATENCY_MS and moved,
          f'the viewport stays interactive while rendering (median {med:.0f} ms, budget {RENDER_LATENCY_MS:.0f} ms)')
    f.shot('50_render_window.png')
    f.key(1)                                    # Esc
    f.pump(0.3)
    n0 = f.frames
    f.pump(0.6)
    check(f.frames - n0 <= 1, f'Esc stops the render ({f.frames - n0} frames after)')
    def face_sd():                              # the cube's left face
        g = [v[1] for v in f.image().crop((756, 300, 796, 360)).getdata()]
        mean = sum(g) / len(g)
        return (sum((v - mean) ** 2 for v in g) / len(g)) ** 0.5
    q('op("render.settings", "320 180 8")')
    f.key(88)                                   # a short render: still noisy
    f.pump(1.0)
    den = face_sd()
    cmd('render.denoise')                       # off: the raw samples
    f.pump(0.3)
    raw = face_sd()
    cmd('render.denoise')
    f.pump(0.3)
    check(den < raw * 0.7 and face_sd() == den,
          f'a finished render is denoised (cube face noise sd {raw:.1f} -> {den:.1f}); render.denoise toggles it')
    beauty = px(f, 815, 362)
    cmd('render.pass normal')
    f.pump(0.3)
    nrm = px(f, 815, 362)
    check(nrm != beauty, f'render.pass shows the normal pass ({nrm:06x}, beauty {beauty:06x})')
    out = os.path.join(f.home, 'depth.png')
    cmd(f'render.save {out} depth')
    ok = os.path.exists(out) and Image.open(out).size == (320, 180)
    check(ok, 'render.save writes a pass as PNG at the render size')
    if ok:
        d = Image.open(out).convert('RGB')
        near, sky = d.getpixel((160, 60)), d.getpixel((10, 170))
        check(near[0] > sky[0], f'the depth pass: near is bright, the sky black ({near[0]} vs {sky[0]})')
    path = os.path.join(f.home, 'r.bee')
    q('op("render.settings", "640 360 32")')
    q(f'op("file.save", "{path}"); op("render.settings", "100 100 1"); op("file.open", "{path}")')
    q('op("render.start")')                     # agents may preview renders
    t0 = time.time()
    while time.time() - t0 < 10 and px(f, 815, 68) == 0:
        f.pump(0.2)
    f.pump(2.0)
    f.shot('51_render_done.png')
    text, err = m.tool('script_eval', {'code': f'op("render.save", "{out}")'})
    check(err or 'permission' in (text or ''), 'agents need file access to save a render')
    cmd(f'render.save {out}')
    ok = os.path.exists(out) and Image.open(out).size == (640, 360)
    check(ok, 'render settings are saved in .bee files (640 x 360 after opening)')
    f.proc.kill()


def write_rgbe_hdr(path, w, h, fn):
    """A Radiance .hdr (flat pixels) from fn(theta, phi) -> rgb."""
    out = bytearray(f'#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y {h} +X {w}\n'.encode())
    for y in range(h):
        for x in range(w):
            r, g, b = fn((y + 0.5) / h * math.pi, (x + 0.5) / w * 2 * math.pi)
            m = max(r, g, b)
            if m < 1e-30:
                out += bytes(4); continue
            f, e = math.frexp(m); k = f * 256.0 / m
            out += bytes([int(r * k), int(g * k), int(b * k), e + 128])
    open(path, 'wb').write(out)


def textures_world():
    """Box-projected image textures and an HDRI world: Hive, the material
    preview, files and agents."""
    print('  -- textures and the HDRI world --')
    from PIL import Image
    home = tempfile.mkdtemp(prefix='bee-tex-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        return subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120).stdout.strip()
    chk = os.path.join(home, 'check.png')
    im = Image.new('RGB', (64, 64))
    im.putdata([((230, 30, 30) if ((x // 16) + (y // 16)) % 2 else (240, 240, 240)) for y in range(64) for x in range(64)])
    im.save(chk)
    sky = os.path.join(home, 'sky.hdr')
    sun_t, sun_p = math.radians(35), math.radians(200)
    def fn(t, p):
        if math.hypot(t - sun_t, (p - sun_p) * math.sin(t)) < 0.05: return (120, 110, 100)
        return (0.06, 0.08, 0.14) if t < math.pi / 2 else (0.04, 0.035, 0.03)
    write_rgbe_hdr(sky, 128, 64, fn)
    tex = (f'i = image("{chk}"); m = material("Tex"); assign("Cube", m); op("material.texture", "Tex " + i + " 2")\n')
    a = os.path.join(home, 'tex.png')
    run(tex + f'render("{a}", 320, 180, 16, 1)')
    r = Image.open(a).convert('RGB')
    face = [r.getpixel((x, y)) for y in range(60, 100, 2) for x in range(120, 150, 2)]
    reds = sum(1 for p in face if p[0] > p[1] + 60)
    whites = sum(1 for p in face if abs(p[0] - p[1]) < 30 and p[1] > 120)
    check(reds > 10 and whites > 10, f'Hive renders the box-projected texture ({reds} red and {whites} white samples on a face)')
    r.save(os.path.join(OUT, '52_texture.png'))
    # the HDRI: shadows from its sun, and a white furnace with a flat one
    b = os.path.join(home, 'hdri.png')
    run(f'e = image("{sky}"); op("world.hdri", e); add("plane", "F"); scale("F", 6)\n'
        f'add("sphere", "S", 2.5, 1, 0.5); render("{b}", 320, 180, 32, 1)')
    r = Image.open(b).convert('RGB')
    r.save(os.path.join(OUT, '53_hdri.png'))
    lum = lambda p: sum(p) / 3
    floor = sorted(lum(r.getpixel((x, y))) for y in range(120, 178, 3) for x in range(10, 310, 5))
    check(floor[len(floor) // 10] < floor[-len(floor) // 10] * 0.75,
          f'the HDRI sun casts shadows (floor 10% {floor[len(floor) // 10]:.0f} vs 90% {floor[-len(floor) // 10]:.0f})')
    flat = os.path.join(home, 'flat.hdr')
    write_rgbe_hdr(flat, 32, 16, lambda t, p: (0.5, 0.5, 0.5))
    f2 = os.path.join(home, 'furn.png')
    run(f'e = image("{flat}"); op("world.hdri", e); delete("Cube"); delete("Light"); m = material("M"); '
        f'matset(m, "roughness", 1); matset(m, "specular", 0); add("sphere", "S", 0, 0, 0); scale("S", 2); assign("S", m); '
        f'render("{f2}", 160, 90, 128)')
    im2 = Image.open(f2).convert('RGB')
    c, bg = im2.getpixel((80, 45)), im2.getpixel((2, 2))
    # (base 0.8 by default: the sphere reflects 80%)
    check(abs(c[0] - bg[0]) > 3 and bg[0] == 200, f'a flat HDRI lights like the furnace (background {bg[0]}, sphere {c[0]})')
    run(f'e = image("{flat}"); op("world.hdri", e); delete("Cube"); delete("Light"); m = material("M"); '
        f'matset(m, "roughness", 1); matset(m, "specular", 0); matset(m, "base", 1, 1, 1); add("sphere", "S", 0, 0, 0); '
        f'scale("S", 2); assign("S", m); render("{f2}", 160, 90, 128)')
    im2 = Image.open(f2).convert('RGB')
    c, bg = im2.getpixel((80, 45)), im2.getpixel((2, 2))
    check(abs(c[0] - bg[0]) <= 2, f'white furnace in a flat HDRI: the sphere vanishes ({c[0]} vs {bg[0]})')
    # files: the image paths, the texture and the world come back
    bee = os.path.join(home, 'tex.bee')
    c1, c2 = os.path.join(home, 'c1.png'), os.path.join(home, 'c2.png')
    run(tex + f'e = image("{sky}"); op("world.hdri", e); op("world.strength", 0.7); op("world.rotation", 90)\n'
        f'op("file.save", "{bee}"); render("{c1}", 96, 54, 8)')
    run(f'op("file.open", "{bee}"); render("{c2}", 96, 54, 8)')
    same = os.path.exists(c2) and open(c1, 'rb').read() == open(c2, 'rb').read()
    check(same, 'images, textures and the world are saved in .bee (an identical render after opening)')
    # the material preview and agents (GUI)
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.2)
    cmd(f'op("file.open", "{bee}")')
    f.key(1)                                    # leave the command line
    f.pump(0.3)
    f.mods(1); f.key(44); f.mods(0)             # Shift+Z: material preview
    f.pump(0.5)
    shot = f.image()
    f.shot('54_preview_texture_hdri.png')
    region = [shot.getpixel(project((x / 4, 2.01, z / 4))) for x in range(-3, 4) for z in range(-3, 4)]
    reds = sum(1 for p in region if p[0] > p[1] + 50)
    check(reds >= 3 and len(set(region)) > 5, f'the material preview shows the texture ({reds} red of {len(region)} samples)')
    m = Mcp(f)
    t = m.tool('scene_summary')[0]
    try:
        js = json.loads(t.split('\n')[0])
        ok = (js['world']['hdri'] == 'sky' and abs(js['world']['strength'] - 0.7) < 1e-3 and abs(js['world']['rotation'] - 90) < 0.01
              and {'check', 'sky'} <= set(js['images'])
              and any(mm.get('texture') == 'check' for mm in js['materials']))
    except Exception as e:
        ok, js = False, e
    check(ok, 'scene_summary shows agents the images, textures and the world')
    text, err = m.tool('script_eval', {'code': f'image("{chk}")'})
    check(err and 'permission' in text, 'agents need file access to load images')
    f.proc.kill()


GRAPH_SCENE = (
    'delete("Cube")\nm = material("G")\nadd("sphere", "S", 0, 1, 0)\nscale("S", 2)\nassign("S", m)\n')


def shader_graph():
    """Shader graphs: nodes drive base, roughness, emission and the normal in
    Hive and the preview; files, scripts, undo and agents."""
    print('  -- shader graphs --')
    from PIL import Image
    home = tempfile.mkdtemp(prefix='bee-graph-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
        return r.stdout.strip() + r.stderr.strip()
    def shot(name, code, spp=16, size=(160, 90)):
        p = os.path.join(home, name + '.png')
        run(GRAPH_SCENE + code + f'\nrender("{p}", {size[0]}, {size[1]}, {spp}, 1)')
        return Image.open(p).convert('RGB') if os.path.exists(p) else None
    lum = lambda p: sum(p) / 3
    # a gradient along y (object space): bright on top, dark below
    g = shot('grad', 'n = node(m, "gradient", 1, 2)\nsocket(m, "base", n)')
    top, bottom = lum(g.getpixel((80, 22))), lum(g.getpixel((80, 70)))
    check(top > bottom + 60, f'a gradient node drives the base colour by height ({top:.0f} top, {bottom:.0f} below)')
    # math: a hard threshold of the same gradient
    t = shot('math', 'n = node(m, "gradient", 1, 2)\nk = node(m, "math", 7)\nlink(m, n, k, 1)\nnodeset(m, k, 2, 0.5)\nsocket(m, "base", k)')
    col = [lum(t.getpixel((80, y))) for y in range(15, 80, 3)]
    jumps = sum(1 for a, b in zip(col, col[1:]) if abs(a - b) > 40)
    check(jumps >= 1 and max(col) - min(col) > 100, f'a math node thresholds it (one edge: {jumps} jumps)')
    t.save(os.path.join(OUT, '55_graph_math.png'))
    # noise -> ramp -> base, checker -> roughness, bump -> normal
    rich = ('n = node(m, "noise", 3, 5, 0.55)\nr = node(m, "ramp")\nlink(m, n, r, 1)\nnodeset(m, r, 2, 0.6, 0.15, 0.05)\n'
            'nodeset(m, r, 3, 0.95, 0.8, 0.5)\nsocket(m, "base", r)\nc = node(m, "checker", 2)\nnodeset(m, c, 1, 0.1)\n'
            'nodeset(m, c, 2, 0.8)\nsocket(m, "roughness", c)\n')
    a = shot('rich', rich, 32, (240, 135))
    b = shot('bump', rich + 'b = node(m, "bump", 2, 0.2)\nlink(m, n, b, 1)\nsocket(m, "normal", b)', 32, (240, 135))
    pxs = [a.getpixel((x, y)) for y in range(30, 105, 4) for x in range(80, 160, 4)]
    warm = sum(1 for p in pxs if p[0] > p[2] + 40)
    spread = max(lum(p) for p in pxs) - min(lum(p) for p in pxs)
    check(warm > len(pxs) // 2 and spread > 40, f'noise -> ramp colours the sphere ({warm} of {len(pxs)} warm, spread {spread:.0f})')
    diff = sum(abs(lum(a.getpixel((x, y))) - lum(b.getpixel((x, y)))) for y in range(30, 105, 2) for x in range(80, 160, 2)) / (38 * 40)
    check(diff > 4, f'a bump node tilts the normals (mean change {diff:.1f} levels)')
    b.save(os.path.join(OUT, '56_graph_bump.png'))
    # emission: a checker of light
    e = shot('emit', 'c = node(m, "checker", 3)\nnodeset(m, c, 1, 4, 4, 4)\nnodeset(m, c, 2, 0)\nsocket(m, "emission", c)\n'
                     'matset(m, "base", 0, 0, 0)\nmatset(m, "strength", 1)')
    vals = [lum(e.getpixel((x, y))) for y in range(25, 70, 3) for x in range(55, 105, 3)]
    check(max(vals) > 230 and min(vals) < 60, f'an emission socket makes a pattern of light ({min(vals):.0f}..{max(vals):.0f})')
    # links only go forward; bad types are refused
    out = run(GRAPH_SCENE + 'a = node(m, "noise")\nb = node(m, "ramp")\nlink(m, b, a, 1)')
    check('no such node' in out, 'a link to an earlier node is refused (no loops)')
    out = run(GRAPH_SCENE + 'node(m, "teapot")')
    check('unknown node type' in out, 'an unknown node type is refused')
    # files: the graph comes back
    bee = os.path.join(home, 'g.bee')
    c1, c2 = os.path.join(home, 'c1.png'), os.path.join(home, 'c2.png')
    run(GRAPH_SCENE + rich + f'op("file.save", "{bee}")\nrender("{c1}", 96, 54, 8)')
    run(f'op("file.open", "{bee}")\nrender("{c2}", 96, 54, 8)')
    same = os.path.exists(c2) and open(c1, 'rb').read() == open(c2, 'rb').read()
    check(same, 'shader graphs are saved in .bee (an identical render after opening)')
    # the preview, undo and agents
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('m = material("G")\nassign("Cube", m)\nn = node(m, "gradient", 1, 2)\nr = node(m, "ramp")\nlink(m, n, r, 1)\n'
      'nodeset(m, r, 2, 0.05, 0.1, 0.6)\nnodeset(m, r, 3, 0.9, 0.5, 0.1)\nsocket(m, "base", r)')
    f.mods(1); f.key(44); f.mods(0)             # Shift+Z: material preview
    f.pump(0.5)
    hi, lo = px(f, *project((0.2, 1.9, 1.0))), px(f, *project((0.2, 0.15, 1.0)))
    check((hi >> 16) > (hi & 0xff) + 30 and (lo & 0xff) > (lo >> 16) + 20,
          f'the material preview evaluates the graph (orange above {hi:06x}, blue below {lo:06x})')
    f.shot('57_graph_preview.png')
    t = m.tool('scene_summary')[0]
    try:
        g = [mm for mm in json.loads(t.split('\n')[0])['materials'] if mm['name'] == 'G'][0]
        ok = ([n['type'] for n in g['nodes']] == ['gradient', 'ramp'] and g['nodes'][1]['inputs'][0] == {'link': 1}
              and g['sockets'] == {'base': 2})
    except Exception as e:
        ok, g = False, e
    check(ok, f'scene_summary shows agents the graph ({str(g)[:60] if not ok else "nodes, links, sockets"})')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z: the whole script run
    check(q('print(matof("Cube"))') == 'nil', 'one undo removes the material and its graph (one script run)')
    f.proc.kill()


def gltf_fixture(path, external=False):
    """A small glTF by hand: a parent (TRS) with a child (matrix) holding a
    tetrahedron (u16 indices) and a material with extensions. Returns the
    tetrahedron's expected world-space corners."""
    import base64
    pts = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)]
    idx = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
    data = b''.join(struct.pack('<3f', *p) for p in pts) + struct.pack('<12H', *idx)
    q = (0, math.sin(math.pi / 4), 0, math.cos(math.pi / 4))       # 90 deg about y
    parent_t, parent_s = (1, 2, 3), (2, 2, 2)
    child_m = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.5, 0, 0, 1]   # column-major: translate x 0.5
    def rot_y90(v): return (v[2], v[1], -v[0])
    exp = []
    for p in pts:
        c = (p[0] + 0.5, p[1], p[2])
        s_ = tuple(c[i] * parent_s[i] for i in range(3))
        r = rot_y90(s_)
        exp.append(tuple(r[i] + parent_t[i] for i in range(3)))
    buf = {'byteLength': len(data)}
    if external:
        open(path[:-5] + '.bin', 'wb').write(data)
        buf['uri'] = os.path.basename(path[:-5] + '.bin')
    else:
        buf['uri'] = 'data:application/octet-stream;base64,' + base64.b64encode(data).decode()
    g = {'asset': {'version': '2.0'}, 'scene': 0, 'scenes': [{'nodes': [0]}],
         'nodes': [{'name': 'Rig', 'translation': list(parent_t), 'rotation': list(q), 'scale': list(parent_s), 'children': [1]},
                   {'name': 'Tetra', 'matrix': child_m, 'mesh': 0}],
         'meshes': [{'name': 'tet', 'primitives': [{'attributes': {'POSITION': 0}, 'indices': 1, 'material': 0}]}],
         'materials': [{'name': 'Paint', 'pbrMetallicRoughness': {'baseColorFactor': [0.1, 0.5, 0.9, 1], 'metallicFactor': 0.25,
                        'roughnessFactor': 0.75}, 'emissiveFactor': [0, 0, 0],
                        'extensions': {'KHR_materials_ior': {'ior': 1.6}, 'KHR_materials_clearcoat': {'clearcoatFactor': 0.4}}}],
         'accessors': [{'bufferView': 0, 'componentType': 5126, 'type': 'VEC3', 'count': 4, 'min': [0, 0, 0], 'max': [1, 1, 1]},
                       {'bufferView': 1, 'componentType': 5123, 'type': 'SCALAR', 'count': 12}],
         'bufferViews': [{'buffer': 0, 'byteOffset': 0, 'byteLength': 48}, {'buffer': 0, 'byteOffset': 48, 'byteLength': 24}],
         'buffers': [buf]}
    open(path, 'w').write(json.dumps(g))
    return exp


def gltf_mtl():
    """glTF 2.0 export / import (.glb, .gltf, hierarchies, PBR) and MTL with OBJ."""
    print('  -- glTF and MTL --')
    home = tempfile.mkdtemp(prefix='bee-gltf-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
        return r.stdout.strip()
    # import a hand-made file: hierarchy, TRS + matrix, u16 indices, extensions
    for ext in (False, True):
        p = os.path.join(home, f'fix{int(ext)}.gltf')
        exp = gltf_fixture(p, ext)
        out = run(f'op("file.import_gltf", "{p}")\nn = "Tetra"\nprint(verts(n), faces(n), matof(n))\n'
                  f'for v in 0..verts(n) {{ print(vpos(n, v, 0), vpos(n, v, 1), vpos(n, v, 2)) }}\n'
                  f'print(matget("Paint", "base", 2), matget("Paint", "metallic"), matget("Paint", "roughness"), '
                  f'matget("Paint", "ior"), matget("Paint", "clearcoat"))').splitlines()
        try:
            head = out[0].split()
            got = sorted(tuple(round(float(x), 3) for x in l.split()) for l in out[1:5])
            vals = [float(x) for x in out[5].split()]
            ok = (head == ['4', '4', 'Paint'] and got == sorted(tuple(round(c, 3) for c in e) for e in exp)
                  and all(abs(a - b) < 1e-3 for a, b in zip(vals, [0.9, 0.25, 0.75, 1.6, 0.4])))
        except (IndexError, ValueError):
            ok = False
        check(ok, f'glTF import ({"external .bin" if ext else "data: URI"}): node tree baked, PBR + extensions ({out[:2]})')
    # our export, read back: positions (world, as OBJ export writes them) and materials
    scene = ('m = material("Gold")\nmatset(m, "base", 1, 0.766, 0.336)\nmatset(m, "metallic", 1)\nmatset(m, "roughness", 0.3)\n'
             'matset(m, "emission", 1, 0.5, 0.25)\nmatset(m, "strength", 4)\nmatset(m, "transmission", 0.2)\nassign("Cube", m)\n'
             'add("cone", "Spike", 2, 0.5, -1)\nrotate("Spike", 30, 45, 60)\nscale("Spike", 1, 2, 0.5)\n')
    for kind in ('glb', 'gltf'):
        f = os.path.join(home, f'out.{kind}')
        o = os.path.join(home, f'ref_{kind}.obj')
        run(scene + f'op("file.export_gltf", "{f}")\nop("file.export_obj", "{o}")')
        ref = sorted(tuple(round(float(x), 3) for x in l.split()[1:4]) for l in open(o) if l.startswith('v '))
        out = run(f'delete("Cube")\nop("file.import_gltf", "{f}")\nprint(count(), matget("Gold", "base", 1), matget("Gold", "metallic"), '
                  f'matget("Gold", "roughness"), matget("Gold", "strength"), matget("Gold", "transmission"), matof("Cube"))')
        res = run(f'delete("Cube")\nop("file.import_gltf", "{f}")\n'
                  'for v in 0..verts("Cube") { print(vpos("Cube", v, 0), vpos("Cube", v, 1), vpos("Cube", v, 2)) }\n'
                  'for v in 0..verts("Spike") { print(vpos("Spike", v, 0), vpos("Spike", v, 1), vpos("Spike", v, 2)) }')
        got = sorted(tuple(round(float(x), 3) for x in l.split()) for l in res.splitlines() if l.strip())
        close = len(got) == len(ref) and all(max(abs(a - b) for a, b in zip(g, r)) < 2e-3 for g, r in zip(got, ref))
        vals = out.split()
        mat_ok = vals[1:7] == ['0.766', '1', '0.3', '4', '0.2', 'Gold']
        check(close and mat_ok, f'.{kind} export reads back: {len(got)} world-space corners match, materials too ({vals[1:7]})')
    # an independent reader, when there is one
    import shutil
    if shutil.which('blender'):
        script = os.path.join(home, 'bl.py')
        open(script, 'w').write(
            'import bpy, sys\nbpy.ops.wm.read_factory_settings(use_empty=True)\n'
            'bpy.ops.import_scene.gltf(filepath=sys.argv[-1])\n'
            'print("BL", sorted((o.name, len(o.data.vertices), o.active_material.name if o.active_material else "-") '
            'for o in bpy.context.scene.objects if o.type == "MESH"))\n')
        r = subprocess.run(['blender', '-b', '--factory-startup', '--python', script, '--', os.path.join(home, 'out.glb')],
                           capture_output=True, text=True, timeout=180)
        line = [l for l in r.stdout.splitlines() if l.startswith('BL ')]
        check(line and "('Cube', 8, 'Gold')" in line[0] and "'Spike'" in line[0], f'Blender reads the .glb ({line[0][3:80] if line else r.stderr[-80:]})')
    # MTL with OBJ: values and a map_Kd texture
    from PIL import Image
    tex = os.path.join(home, 'red.png')
    Image.new('RGB', (8, 8), (220, 20, 20)).save(tex)
    o = os.path.join(home, 'm.obj')
    run(scene + f'op("file.export_obj", "{o}")')
    with open(os.path.join(home, 'm.mtl'), 'a') as mf:
        mf.write('\nnewmtl Painted\nKd 0.5 0.5 0.5\nNs 100\nmap_Kd -bm 1 red.png\n')
    with open(o) as of:
        body = of.read().replace('usemtl Gold', 'usemtl Painted', 1)
    open(o, 'w').write(body)
    pic = os.path.join(home, 'mtl.png')
    out = run(f'op("file.new")\ndelete("Cube")\nop("file.import_obj", "{o}")\nn = name(count() - 1)\n'
              f'print(matof(n), matget("Gold", "base", 1), matget("Gold", "roughness"), matget("Gold", "transmission"), '
              f'matget("Painted", "roughness"))\nrender("{pic}", 96, 54, 8)')
    vals = out.split()
    img = Image.open(pic).convert('RGB') if os.path.exists(pic) else None
    red = img and sum(1 for p in img.getdata() if p[0] > p[1] + 80) > 30
    check(vals[:4] == ['Painted', '0.766', '0.3', '0.2'] and abs(float(vals[4]) - math.sqrt(2 / 102)) < 1e-3 and red,
          f'MTL with OBJ: values, Ns -> roughness, usemtl, map_Kd texture ({vals})')


PRODUCT_SHOT_MS = 10000.0          # 1080p, converged, on 32 threads (scaled below)
PRODUCT_RMSE = 4.5                 # 32 samples + denoise vs 512 samples, 240 x 135 (levels)


def product_shot():
    """The v0.6 benchmark: a product shot rendered to convergence (32
    samples + the denoiser) within budget, and the UI responsive while the
    same scene renders at 1080p in the Render area."""
    print('  -- product-shot benchmark --')
    from PIL import Image
    home = tempfile.mkdtemp(prefix='bee-shot-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    scene = open(os.path.join(os.path.dirname(__file__), '..', 'tests', 'product_shot.bees')).read()
    def render(w, h, spp, dn, name):
        p = os.path.join(home, name)
        r = subprocess.run([BIN, '--eval', scene + f'\nprint(render("{p}", {w}, {h}, {spp}, {dn}))'],
                           env=env, capture_output=True, text=True, timeout=600)
        try:
            return p, float(r.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            return p, 1e9
    # converged: close to a 512-sample reference
    ref, _ = render(240, 135, 512, 0, 'ref.png')
    cv, _ = render(240, 135, 32, 1, 'cv.png')
    a, b = Image.open(ref).convert('RGB').tobytes(), Image.open(cv).convert('RGB').tobytes()
    rmse = (sum((x - y) ** 2 for x, y in zip(a, b)) / len(a)) ** 0.5
    check(rmse < PRODUCT_RMSE, f'32 samples + denoise converge (rmse {rmse:.2f} levels against 512 samples, budget {PRODUCT_RMSE})')
    # the time: 1080p on big machines, a quarter of it on small ones
    cpus = os.cpu_count() or 4
    w, h, part = (1920, 1080, 1.0) if cpus >= 16 else (960, 540, 0.25)
    budget = PRODUCT_SHOT_MS * part * 32 / cpus
    p, ms = render(w, h, 32, 1, 'shot.png')
    check(ms < budget, f'product shot {w} x {h}, 32 samples + denoise: {ms:.0f} ms (budget {budget:.0f} ms on {cpus} threads)')
    if os.path.exists(p):
        Image.open(p).save(os.path.join(OUT, '58_product_shot.png'))
    # interactive: the same scene at 1080p in the Render area
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(400, 300)
    m = Mcp(f)
    m.tool('script_eval', {'code': scene})
    m.tool('script_eval', {'code': 'op("render.settings", "1920 1080 32")'})
    f.key(88)                                   # F12
    f.pump(0.5)
    f.latencies = []
    for i in range(3):
        f.drag(400, 300, 440 + 20 * i, 320, steps=8)
    lat = sorted(f.latencies)
    med = lat[len(lat) // 2] if lat else 1e9
    check(med < RENDER_LATENCY_MS, f'orbiting while it renders at 1080p: median {med:.0f} ms per frame (budget {RENDER_LATENCY_MS:.0f})')
    t0 = time.time()                            # finished: the frames stop
    done = None
    while time.time() - t0 < 180:
        n0 = f.frames
        f.pump(1.0)
        if f.frames == n0:
            done = time.time() - t0
            break
    f.shot('59_product_shot_window.png')
    check(done is not None, f'the 1080p render finishes in the window ({done:.0f} s)' if done else 'the 1080p render finishes')
    f.proc.kill()


def params_units():
    """Parameters and expressions with units: values, errors, undo, files,
    the Properties table and agents."""
    print('  -- parameters and units --')
    home = tempfile.mkdtemp(prefix='bee-par-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=60)
        return (r.stdout + r.stderr).strip()
    out = run('op("scene.units", "mm")\nprint(param("wall", "2mm"), param("width", "10*wall + 1cm"), param("angle", "30deg"), '
              'param("s", "sin(angle) * 2"), param("big", "max(width, 3in) / 2"))\n'
              'print(expr("2^10"), expr("sqrt(16) + abs(-3) + floor(2.7) + ceil(2.1) + round(2.5)"), expr("1e3mm"))\n'
              'op("scene.units", "m")\nprint(param("wall"), param("width"), expr("2mm"), expr("1in"))')
    check(out.split('\n') == ['2 30 0.523599 1 38.1', '1024 15 1000', '0.002 0.03 0.002 0.0254'],
          f'expressions: units, parameters, functions; values follow the scene units ({out.splitlines()[:3]})')
    errs = [run('param("a", "1")\nparam("b", "a*2")\nparam("a", "b + 1")'), run('print(expr("1 +"))'),
            run('param("sin", "3")'), run('param("2x", "3")'), run('print(expr("nope * 2"))')]
    want = ['cycle', 'syntax error', 'function or constant', 'a parameter name', 'unknown name']
    check(all(w in e for w, e in zip(want, errs)), f'cycles, syntax errors and bad names are refused ({[e[-30:] for e in errs]})')
    bee = os.path.join(home, 'p.bee')
    run(f'op("scene.units", "mm")\nparam("wall", "2mm")\nparam("width", "10*wall")\nop("file.save", "{bee}")')
    out = run(f'op("file.open", "{bee}")\nprint(param("width"), expr("1cm"))')
    check(out == '20 10', f'parameters and units are saved in .bee ({out})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.2)
    cmd('scene.units mm')
    cmd('param.set wall 2mm')
    cmd('param.set width = 10*wall')
    check(q('print(param("width"))') == '20', 'param.set from the command line (one undo step each)')
    f.key(1)
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    check('no parameter named width' in q('print(param("width"))'), 'Ctrl+Z removes the last parameter')
    f.mods(5); f.key(44); f.mods(0)             # Ctrl+Shift+Z
    check(q('print(param("width"))') == '20', 'Ctrl+Shift+Z brings it back')
    t = m.tool('scene_summary')[0]
    try:
        js = json.loads(t.split('\n')[0])
        ok = js['units'] == 'mm' and [(p['name'], p['expression'], p['value']) for p in js['parameters']] == [
            ('wall', '2mm', 2), ('width', '10*wall', 20)]
    except Exception as e:
        ok, js = False, e
    check(ok, 'scene_summary shows agents the units and the parameters')
    text, err = m.tool('script_eval', {'code': 'op("param.set", "wall 3mm")\nprint(param("width"))'})
    check((text or '').strip() == '30', f'agents change a parameter and dependents follow ({text!r})')
    f.pump(0.3)
    f.shot('60_parameters.png')
    f.proc.kill()


def sketcher():
    """Sketches: the constraint solver (DOF, dimensions driven by parameters,
    conflicts), files, and sketch mode in the viewport."""
    print('  -- sketcher --')
    home = tempfile.mkdtemp(prefix='bee-sk-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=60)
        return (r.stdout + r.stderr).strip()
    out = run('op("scene.units", "mm")\nparam("width", "20mm")\ns = sketch("Base", "XY")\nr = rect(s, 0, 0, 10, 5)\n'
              'a = dof(s)\ncon(s, "fixed", pt(s, r, 0))\nb = dof(s)\ncon(s, "length", r, "width")\nc = dof(s)\n'
              'con(s, "length", r + 1, 8)\nprint(a, b, c, dof(s), conflicts(s), sx(s, pt(s, r + 1, 1)), sy(s, pt(s, r + 1, 1)))\n'
              'param("width", "30mm")\nprint(sx(s, pt(s, r + 1, 1)), dof(s))\n'
              'k = circle(s, 15, 4, 2)\ncon(s, "radius", k, "2mm")\ncon(s, "tangent", r + 2, k)\nprint(sy(s, pt(s, k, 0)), sr(s, k), dof(s))\n'
              'con(s, "length", r + 1, 9)\nprint(conflicts(s))')
    lines = out.splitlines()
    check(lines[:4] == ['4 2 1 0 0 20 8', '30 0', '6 2 1', '2'],
          f'a dimensioned rectangle: DOF 4 > 2 > 1 > 0, a parameter drives it, tangency, conflicts ({lines})')
    out = run('s = sketch("G", "XY")\na = line(s, 0, 0, 4, 1)\nb = line(s, 1, 3, 3, 5)\ncon(s, "fixed", pt(s, a, 0))\n'
              'con(s, "horizontal", a)\ncon(s, "perpendicular", a, b)\ncon(s, "equal", a, b)\ncon(s, "length", a, 4)\n'
              'print(round(sy(s, pt(s, a, 1)) * 1000), round((sx(s, pt(s, b, 1)) - sx(s, pt(s, b, 0))) * 1000), round(abs(sy(s, pt(s, b, 1)) - sy(s, pt(s, b, 0))) * 1000))\n'
              'c = line(s, 0, 0, 3, 3)\ncon(s, "coincident", pt(s, c, 0), pt(s, a, 0))\ncon(s, "angle", a, c, "30deg")\ncon(s, "length", c, 2)\n'
              'print(round(sx(s, pt(s, c, 1)) * 1000), round(sy(s, pt(s, c, 1)) * 1000))\n'
              'p = point(s, 1, 1)\ncon(s, "midpoint", p, a)\nprint(round(sx(s, p) * 1000), round(sy(s, p) * 1000))\n'
              'k = arc(s, 0, 0, 2, 0, "90deg")\ncon(s, "radius", k, 3)\no = pt(s, k, 0)\n'
              'print(round(sqrt(pow(sx(s, pt(s, k, 1)) - sx(s, o), 2) + pow(sy(s, pt(s, k, 1)) - sy(s, o), 2)) * 1000), '
              'round(sqrt(pow(sx(s, pt(s, k, 2)) - sx(s, o), 2) + pow(sy(s, pt(s, k, 2)) - sy(s, o), 2)) * 1000))')
    lines = out.splitlines()
    check(lines == ['0 0 4000', '1732 1000', '2000 0', '3000 3000'],
          f'perpendicular, equal, angle 30deg, midpoint and an arc radius solve exactly ({lines})')
    bee = os.path.join(home, 'sk.bee')
    run(f'op("scene.units", "mm")\nparam("w", "12mm")\ns = sketch("Base", "XZ", 5)\nr = rect(s, 0, 0, 10, 5)\n'
        f'con(s, "length", r, "w")\ncircle(s, 3, 3, 1)\nop("file.save", "{bee}")')
    out = run(f'op("file.open", "{bee}")\ns = "Base"\nprint(skinfo(s, "entities"), skinfo(s, "constraints"), dof(s), '
              f'sx(s, 1) - sx(s, 0))\nparam("w", "15mm")\nprint(sx(s, 1) - sx(s, 0))')
    check(out.splitlines() == ['5 9 6 12', '15'], f'sketches are saved in .bee and stay driven by parameters ({out.splitlines()})')
    # sketch mode
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.2)
    q('delete("Cube")\nparam("width", "7")\ns = sketch("Plate", "XZ")\nselect("Plate")')
    f.key(15)                                   # Tab: sketch mode
    f.pump(0.2)
    P = lambda x, z: project((x, 0, z))
    f.key(38)                                   # L, a closed outline
    for x, z in [(-3, 2), (3, 2), (3, -2), (-3, -2), (-3, 2)]:
        f.click(*P(x, z)); f.pump(0.05)
    f.key(1)                                    # Esc ends the tool
    info = q('s = "Plate"\nprint(skinfo(s, "entities"), skinfo(s, "points"), skinfo(s, "constraints"), dof(s))')
    check(info == '4 4 4 4', f'L draws a closed outline: shared corners, H / V inferred, 4 DOF ({info})')
    f.key(24)                                   # O, a circle
    f.click(*P(0, 0)); f.click(*P(1, 0))
    f.key(1)
    info = q('s = "Plate"\nprint(skinfo(s, "entities"), dof(s))')
    check(info == '5 7', f'O draws a circle (centre, then a point) ({info})')
    f.shot('61_sketch_mode.png')
    f.click(*P(0, 2)); f.pump(0.1)              # the top edge, D, "width"
    f.key(32)
    f.pump(0.2)
    f.type('width'); f.key(28); f.pump(0.3)
    w = q('s = "Plate"\nprint(sx(s, 1) - sx(s, 0), dof(s))')
    cmd('param.set width 9')
    w2 = q('s = "Plate"\nprint(sx(s, 1) - sx(s, 0))')
    check(w == '7 6' and w2 == '9', f'D dimensions the selection with an expression; the parameter drives it ({w}, then {w2})')
    f.key(1)
    corner = q('s = "Plate"\nprint(sx(s, 2), sy(s, 2))').split()
    cx, cz = float(corner[0]), -float(corner[1])      # (XZ: v = -z)
    f.drag(*P(cx, cz), *P(cx + 1, cz - 1), steps=6)
    f.pump(0.2)
    moved = q('s = "Plate"\nprint(sy(s, 2), sx(s, 1) - sx(s, 0))').split()
    check(abs(float(moved[0]) - (-cz + 1)) < 0.2 and moved[1] == '9',
          f'dragging a corner moves it while the dimension holds ({corner} -> {moved})')
    f.click(*P(0, 0.98)); f.pump(0.1)           # the circle, X
    f.key(45)
    n = q('print(skinfo("Plate", "entities"))')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    n2 = q('print(skinfo("Plate", "entities"))')
    check(n == '4' and n2 == '5', f'X deletes the selection; Ctrl+Z brings it back ({n}, {n2})')
    t = m.tool('scene_summary')[0]
    try:
        o = [o for o in json.loads(t.split('\n')[0])['objects'] if o['name'] == 'Plate'][0]
        ok = o['type'] == 'sketch' and o['sketch']['plane'] == 'XZ' and o['sketch']['entities'] == 5
    except Exception as e:
        ok, o = False, e
    check(ok, f'scene_summary shows agents the sketch ({str(o)[:80]})')
    f.key(1); f.key(1); f.key(1)                # Esc until sketch mode ends
    f.pump(0.2)
    f.key(15)                                   # Tab again: back in
    f.pump(0.2)
    f.shot('62_sketch_dimensioned.png')
    f.proc.kill()


def features():
    """The feature tree: pad, pocket, revolve, hole, shell, fillet, chamfer
    and patterns rebuild from parametric sketches; files, undo, agents."""
    print('  -- feature tree --')
    home = tempfile.mkdtemp(prefix='bee-ft-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
        return (r.stdout + r.stderr).strip()
    box = ('op("scene.units", "mm")\nparam("w", "60mm")\nparam("d", "40mm")\nparam("h", "30mm")\nparam("wall", "2mm")\n'
           'delete("Cube")\ns = sketch("Base", "XZ")\nr = rect(s, 0, 0, 60, 40)\ncon(s, "fixed", pt(s, r, 0))\n'
           'con(s, "length", r, "w")\ncon(s, "length", r + 1, "d")\nb = pad("Box", s, "h")\nsh = shell("Box", b, "wall")\n'
           'fr = sketch("Front", "XY")\npoint(fr, 30, 15)\nho = hole("Box", fr, "5mm", "4mm")\n')
    out = run(box + 'print(fstatus(b), fstatus(sh), fstatus(ho), round(volume("Box")), manifold("Box"), features())\n'
              'param("w", "80mm")\nprint(round(volume("Box")), manifold("Box"))\n'
              'fl = fillet("Box", "1mm", "vertical")\nprint(fstatus(fl), round(volume("Box")), manifold("Box"))')
    # 60 x 40 x 30 shelled 2mm (open top) = 15552, a 5mm hole (32-gon) through the 2mm front wall;
    # rounding edges that end in the ring-shaped top face is refused and changes nothing
    check(out.splitlines() == ['0 0 0 15513 1 3', '19353 1', '3 19353 1'],
          f'pad, shell and hole build a box; a parameter rebuilds it; a fillet it cannot make fails cleanly ({out.splitlines()})')
    out = run('q = sketch("P", "XY")\nrect(q, 2, 0, 3, 5)\nv = revolve("Ring", q, "360deg", "v")\n'
              'h = revolve("Half", q, "180deg", "v")\nprint(round(volume("Ring") * 10), manifold("Ring"), round(volume("Half") * 10), manifold("Half"))\n'
              'k = sketch("K", "XZ")\nrect(k, 0, 0, 10, 10)\np = pad("Blk", k, 10)\nf = fillet("Blk", 1, "vertical")\n'
              'print(round(volume("Blk") * 10), manifold("Blk"))\nc = chamfer("Blk", 1, "top")\nprint(manifold("Blk"), fstatus(c))\n'
              'feature(f, 3, 1)\nprint(round(volume("Blk") * 10), manifold("Blk"))')
    # a ring r 2..5, 5 high: pi 21 5 = 329.9 (64 steps: 329.3); the 4-segment fillets take 7.5 off
    # 1000; chamfering the top edges alone takes 4 x 5 - 4 x 1/3 (the corners)
    check(out.splitlines() == ['3293 1 1647 1', '9925 1', '1 0', '9813 1'],
          f'revolve (full and part turns), fillet and chamfer by edge selectors, suppressing a feature ({out.splitlines()})')
    out = run('op("scene.units", "mm")\nparam("dp", "2mm")\nq = sketch("Q", "XZ")\nrect(q, 0, 0, 20, 10)\np = pad("Bar", q, 10)\n'
              'w = sketch("W", "XZ", 10)\ncircle(w, 3, 3, 1)\nk = pocket("Bar", w, "dp")\nl = pattern("Bar", k, 4, "4mm", "x")\n'
              'print(fstatus(l), round(volume("Bar") * 10), manifold("Bar"))\nbad = 0\nfor i in 1..9 {\nparam("dp", str(i * 0.5) + "mm")\n'
              'if fstatus(l) != 0 or manifold("Bar") != 1 { bad = bad + 1 }\n}\nprint(bad)\n'
              'g = sketch("G", "XZ")\ncircle(g, 0, 0, 10)\nd = pad("Disc", g, 2)\nm = sketch("M", "XZ", 2)\ncircle(m, 6, 0, 1)\n'
              'n = pocket("Disc", m, 0, "through")\nc = pattern("Disc", n, 6, 0, "y", "circular")\nprint(fstatus(c), round(volume("Disc")), manifold("Disc"))')
    # four 2mm pockets r 1 (64-gon): 2000 - 4 x 6.27; six through holes in a 2mm disc r 10
    check(out.splitlines() == ['0 19749 1', '0', '0 590 1'],
          f'linear and circular patterns; pockets of every depth keep the body closed ({out.splitlines()})')
    bee = os.path.join(home, 'ft.bee')
    run(box + f'op("file.save", "{bee}")')
    out = run(f'op("file.open", "{bee}")\nprint(features(), round(volume("Box")))\nparam("h", "40mm")\nprint(round(volume("Box")), manifold("Box"))')
    # h 40: 60 x 40 x 40 - 56 x 36 x 38 - the hole = 19392 - 39
    check(out.splitlines() == ['3 15513', '19353 1'], f'features are saved in .bee and rebuild after loading ({out.splitlines()})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('op("scene.units", "cm")\ndelete("Cube")\nparam("w", "6cm")\ns = sketch("Base", "XZ")\nr = rect(s, -3, -2, 6, 4)\n'
      'con(s, "length", r, "w")\npad("Case", s, "3cm")\nselect("Case")')
    q('shell("Case", 0, "2mm")')
    v1 = q('print(round(volume("Case") * 1000))')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z: the shell goes
    f.pump(0.2)
    v0 = q('print(round(volume("Case") * 1000), features())')
    f.mods(5); f.key(44); f.mods(0)             # Ctrl+Shift+Z: back again
    f.pump(0.2)
    v2 = q('print(round(volume("Case") * 1000), features())')
    check(v1 == '15552' and v0 == '72000 1' and v2 == '15552 2',
          f'Ctrl+Z takes a feature back with its geometry, Ctrl+Shift+Z redoes it ({v1}, {v0}, {v2})')
    t = m.tool('scene_summary')[0]
    try:
        fl = json.loads(t.split('\n')[0])['features']
        ok = fl == [{'type': 'Pad', 'body': 'Case', 'status': 'ok'}, {'type': 'Shell', 'body': 'Case', 'status': 'ok'}]
    except Exception as e:
        ok, fl = False, e
    check(ok, f'scene_summary lists the features for agents ({str(fl)[:80]})')
    f.shot('63_features.png')
    f.proc.kill()


def measuring():
    """Mass properties (area, volume, centre, mass from density), face angles,
    object.measure for the console / agents, and the measure tool."""
    print('  -- measuring --')
    home = tempfile.mkdtemp(prefix='bee-ms-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=60)
        return (r.stdout + r.stderr).strip()
    out = run('print(area("Cube"), volume("Cube"), mass("Cube"), centroid("Cube", "x"), centroid("Cube", "y"), '
              'round(deg(fangle("Cube", 0, 1))))\nmove("Cube", 1, 2, 3)\nscale("Cube", 2, 1, 1)\n'
              'print(area("Cube"), centroid("Cube", "x"), centroid("Cube", "y"), centroid("Cube", "z"))')
    # the 2 m cube: 24 m^2, 8 m^3 = 8e6 cm^3 of density 1; scaled x2 in x: 40 m^2, centre at its location
    check(out.splitlines() == ['24 8 8000000 0 1 180', '40 1 2 3'],
          f'area, volume, mass, centre of mass (world space) and face angles ({out.splitlines()})')
    bee = os.path.join(home, 'ms.bee')
    out = run(f'op("scene.units", "mm")\nm = material("PLA")\nmatset(m, "density", 1.24)\nassign("Cube", m)\n'
              f'print(mass("Cube"))\nop("file.save", "{bee}")')
    out2 = run(f'op("file.open", "{bee}")\nprint(mass("Cube"), matget("PLA", "density"))')
    # 2 mm cube of PLA: 8 mm^3 = 0.008 cm^3 x 1.24 g/cm^3
    check(out == '0.00992' and out2 == '0.00992 1.24', f'mass from the material density, kept in .bee ({out}, {out2})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('select("Cube")')
    text, err = m.tool('run_operator', {'id': 'object.measure'})
    check('Cube: volume 8 m^3, area 24 m^2, mass 8000 kg, centre 0, 1, 0 m' in (text or ''),
          f'object.measure reports in scene units ({(text or "").strip()[-90:]})')
    f.mods(1); f.key(50); f.mods(0)             # Shift+M: the measure tool
    f.pump(0.1)
    for p in [(1, 2, 1), (-1, 2, 1)]:
        x, y = project(p)
        f.click(x + 4, y + 3); f.pump(0.1)      # (a little off: snaps to the corner)
    d = q('print(measurement())')
    x, y = project((-1, 2, -1))
    f.click(x, y); f.pump(0.1)
    a = q('print(round(deg(measurement()) * 10))')
    f.shot('64_measure.png')
    check(d == '2' and a == '900', f'the measure tool: two corners 2 m apart, a right angle at the third ({d}, {a})')
    f.key(1); f.pump(0.1)                       # Esc ends it
    check(q('print(measurement())') == 'nil', 'Esc ends the measure tool')
    f.proc.kill()


def sdf_kernel():
    """Signed-distance shapes: primitives, smooth booleans, shells, lattices,
    meshed closed by marching tetrahedra; lattice infill as a feature."""
    print('  -- SDF kernel --')
    home = tempfile.mkdtemp(prefix='bee-sdf-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
        return (r.stdout + r.stderr).strip()
    out = run('s = ssphere(1)\nprint(sdist(s, 0, 0, 0), sdist(s, 2, 0, 0), sdist(sbox(2, 4, 6), 0, 3, 0), '
              'round(sdist(storus(2, 0.5), 2, 0, 0) * 100))\nsmesh("Ball", s, 32)\n'
              'print(round(volume("Ball") * 100), manifold("Ball"))\n'
              'b = sunion(smove(s, 1, 0, 0), sbox(2, 2, 2), 0.3)\nsmesh("Blob", b, 48)\n'
              'r = srot(sbox(2, 1, 1), 0, 0, rad(45))\nsmesh("Rot", r, 48)\n'
              'h = sshell(ssphere(2), 0.2)\nsmesh("Hollow", h, 64)\n'
              'k = ssub(sbox(2, 2, 2), scyl(0.5, 3), 0.1)\nsmesh("Bored", k, 48)\n'
              'print(manifold("Blob"), round(volume("Rot") * 10), manifold("Rot"), round(volume("Hollow")), manifold("Hollow"), manifold("Bored"))')
    # a unit sphere: 4.19 (meshed: a little less); a box 2 rotated 45 deg; a 0.2 shell of r 2: 4 pi 4 0.2 = 10.05;
    # a gyroid wall of 0.15 fills about 3.1 x 0.15 = 46% of its cells
    check(out.splitlines() == ['-1 1 1 -50', '418 1', '1 20 1 10 1 1'],
          f'distances, and closed meshes of blends, transforms, shells and cuts ({out.splitlines()})')
    t0 = time.time()
    out = run('g = sisect(sgyroid(1, 0.15), sbox(4, 4, 4))\nt = clock()\nsmesh("Gyro", g, 96)\n'
              'print(manifold("Gyro"), round(volume("Gyro") / 64 * 100))\n'
              'k = sisect(sgrid(1, 0.2), sbox(4, 4, 4))\nsmesh("Grid", k, 96)\nprint(manifold("Grid"), round(volume("Grid") * 10))\n'
              'smesh("Bad", sgyroid(1, 0.1))')
    lines = out.splitlines()
    check(len(lines) == 3 and lines[0].startswith('1 ') and 30 < int(lines[0].split()[1]) < 60 and lines[1].startswith('1 ')
          and 'unbounded' in lines[2],
          f'gyroid and grid lattices mesh closed; an unbounded shape is refused ({lines}, {time.time() - t0:.1f} s)')
    out = run('op("scene.units", "mm")\nparam("cell", "10mm")\ns = sketch("Base", "XZ")\nrect(s, 0, 0, 60, 40)\n'
              'b = pad("Box", s, "30mm")\nsh = shell("Box", b, "2mm")\nf = infill("Box", sh, "gyroid", "cell", "1mm")\n'
              'v = volume("Box")\nprint(fstatus(f), manifold("Box"), round((v - 15552) / 1000))\n'
              'param("cell", "15mm")\nprint(fstatus(f), manifold("Box"), volume("Box") < v)\n'
              'g = infill("Box", sh, "grid", "10mm", "1.5mm")\nfeature(f, 3, 1)\nprint(fstatus(g), manifold("Box"), round(volume("Box") - 15552))')
    lines = out.splitlines()
    ok = (len(lines) == 3 and lines[0].split()[:2] == ['0', '1'] and 10 <= int(lines[0].split()[2]) <= 25
          and lines[1] == '0 1 1' and lines[2].split()[:2] == ['0', '1'] and 800 < int(lines[2].split()[2]) < 3000)
    check(ok, f'gyroid and grid infill inside a shelled box, driven by a parameter ({lines})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('delete("Cube")\nb = sunion(smove(ssphere(1), 0, 1.6, 0), sbox(2.4, 1.2, 2.4, 0.2), 0.5)\n'
      'c = ssub(b, smove(scyl(0.4, 6), 0, 1, 0))\nsmesh("Blend", c, 96)\nselect("Blend")')
    f.pump(0.3)
    f.shot('65_sdf_blend.png')
    f.proc.kill()


def fabrication():
    """3MF (zip + model XML) for printing, DXF / SVG of sketches, PDF drawings,
    and the printability checks."""
    print('  -- fabrication: 3MF, DXF, SVG, PDF, print check --')
    import zipfile, xml.etree.ElementTree as ET
    home = tempfile.mkdtemp(prefix='bee-fab-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
        return (r.stdout + r.stderr).strip()
    p3, pd, ps, pp = (os.path.join(home, n) for n in ('part.3mf', 'base.dxf', 'base.svg', 'part.pdf'))
    out = run('op("scene.units", "mm")\ndelete("Cube")\ns = sketch("Base", "XZ")\nr = rect(s, 0, 0, 60, 40)\n'
              'arc(s, 30, 20, 8, 0, rad(120))\ncircle(s, 10, 10, 3)\nb = pad("Box", s, "30mm")\nsh = shell("Box", b, "2mm")\n'
              f'op("file.export_3mf", "{p3}")\nselect("Base")\nop("file.export_dxf", "{pd}")\nop("file.export_svg", "{ps}")\n'
              f'select("Box")\nop("file.export_pdf", "{pp}")\nprint(volume("Box"), thinnest("Box"))')
    vol = float(out.split()[0]) if out else 0
    try:
        z = zipfile.ZipFile(p3)
        names = sorted(z.namelist())
        bad = z.testzip()
        ct = z.read('[Content_Types].xml').decode()
        root = ET.fromstring(z.read('3D/3dmodel.model'))
        ns = {'m': 'http://schemas.microsoft.com/3dmanufacturing/core/2015/02'}
        objs = root.findall('.//m:object', ns)
        V = [tuple(float(v.get(k)) for k in 'xyz') for v in objs[0].findall('.//m:vertex', ns)]
        T = [tuple(int(t.get(k)) for k in ('v1', 'v2', 'v3')) for t in objs[0].findall('.//m:triangle', ns)]
        v3 = sum(V[a][0] * (V[b][1] * V[c][2] - V[b][2] * V[c][1]) - V[a][1] * (V[b][0] * V[c][2] - V[b][2] * V[c][0])
                 + V[a][2] * (V[b][0] * V[c][1] - V[b][1] * V[c][0]) for a, b, c in T) / 6
        from collections import Counter
        ec = Counter((a, b) for t in T for a, b in ((t[0], t[1]), (t[1], t[2]), (t[2], t[0])))
        closed = all(ec[(b, a)] == 1 and n == 1 for (a, b), n in ec.items())
        zs = [v[2] for v in V]
        ok = (bad is None and names == ['3D/3dmodel.model', '[Content_Types].xml', '_rels/.rels'] and '3dmodel' in ct
              and root.get('unit') == 'millimeter' and len(objs) == 1 and abs(v3 - vol) < 0.01 * vol and closed
              and abs(min(zs)) < 1e-3 and abs(max(zs) - 30) < 1e-3 and len(root.findall('.//m:item', ns)) == 1)
        info = f'{names}, volume {v3:.0f} vs {vol:.0f}, closed {closed}, z {min(zs):.1f}..{max(zs):.1f}'
    except Exception as e:
        ok, info = False, repr(e)
    check(ok, f'3MF: a valid zip of the three parts, millimetres, Z up, closed, the same volume ({info})')
    try:
        d = open(pd).read().split('\n')
        pairs = list(zip(d[0::2], d[1::2]))
        kinds = [v for c, v in pairs if c.strip() == '0']
        units = [pairs[i + 1][1] for i, (c, v) in enumerate(pairs) if v == '$INSUNITS']
        ok = kinds.count('LINE') == 4 and kinds.count('CIRCLE') == 1 and kinds.count('ARC') == 1 and kinds[-1] == 'EOF' and units == ['4']
        info = f'{kinds.count("LINE")} lines, {kinds.count("CIRCLE")} circle, {kinds.count("ARC")} arc, units {units}'
    except Exception as e:
        ok, info = False, repr(e)
    check(ok, f'DXF of the sketch: entities and millimetre units ({info})')
    try:
        svg = ET.parse(ps).getroot()
        sn = '{http://www.w3.org/2000/svg}'
        cnt = (len(svg.findall(f'.//{sn}line')), len(svg.findall(f'.//{sn}circle')), len(svg.findall(f'.//{sn}path')))
        ok = cnt == (4, 1, 1) and svg.get('width') == '70.000000mm'
        info = f'{cnt}, width {svg.get("width")}'
    except Exception as e:
        ok, info = False, repr(e)
    check(ok, f'SVG of the sketch ({info})')
    try:
        pdf = open(pp, 'rb').read()
        start = int(pdf.rsplit(b'startxref', 1)[1].split()[0])
        rows = pdf[start:].split(b'\n')[3:8]
        offs_ok = all(pdf[int(r[:10]):].startswith(b'%d 0 obj' % (i + 1)) for i, r in enumerate(rows))
        n = re.search(rb'/Length (\d+)', pdf)
        body = pdf[n.end():].split(b'stream\n', 1)[1]
        ok = pdf.startswith(b'%PDF-1.4') and offs_ok and body[int(n.group(1)):].startswith(b'\nendstream') and b'FRONT' in body and b'(60) Tj' in body
        info = f'{len(pdf)} bytes, xref {offs_ok}'
        if ok and shutil.which('pdftoppm'):
            subprocess.run(['pdftoppm', '-png', '-r', '60', '-singlefile', pp, os.path.join(OUT, '67_drawing')], timeout=60)
    except Exception as e:
        ok, info = False, repr(e)
    check(ok, f'PDF drawing: exact xref, views, dimensions ({info})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('op("scene.units", "cm")\ndelete("Cube")\ns = sketch("Base", "XZ")\nr = rect(s, -3, -2, 6, 4)\nb = pad("Case", s, "3cm")\n'
      'sh = shell("Case", b, "0.6mm")\nselect("Case")')
    text, err = m.tool('run_operator', {'id': 'mesh.print_check', 'arg': '1'})
    t = (text or '')
    ok = 'Case: closed, thinnest wall 0.6' in t and 'faces under 1 mm' in t and 'size 60 x 40 x 30 mm' in t
    check(ok, f'mesh.print_check: closed, thinnest wall, size (Z up, mm) ({t.strip()[-120:]})')
    m.tool('run_operator', {'id': 'view.show_thickness', 'arg': '1'})
    f.pump(0.3)
    f.shot('66_thin_walls.png')
    f.proc.kill()


SCULPT_BUDGET_MS = 33.0           # a stroke frame on a 500k-vertex mesh (CI: 4 cores)


def sculpting():
    """Sculpt mode: brushes, mask, symmetry, undo by deltas, drawing and
    stroke speed on a dense mesh."""
    print('  -- sculpting --')
    home = tempfile.mkdtemp(prefix='bee-sc-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
        return (r.stdout + r.stderr).strip()
    ball = 'delete("Cube")\nadd("sphere", "Ball")\nmodifier("Ball", "subsurf")\nmodset("Ball", 0, "levels", 3)\nmodapply("Ball", 0)\n'
    want = {'draw': 1, 'clay strips': 1, 'inflate': 1, 'layer': 1, 'crease': -1, 'flatten': 0, 'pinch': 0, 'smooth': -1}
    code = ball + 'v = volume("Ball")\n'
    for b, sgn in want.items():
        code += f'sculpt("Ball", "{b}", 0, 0.9, 0.3, 0.1, 0.9, 0.3, 0.3, 0.6)\nw = volume("Ball")\nprint("{b}", w - v, manifold("Ball"))\nv = w\n'
    out = run(code)
    got = {}
    for line in out.splitlines():
        *name, d, man = line.split()
        got[' '.join(name)] = (float(d), man)
    ok = len(got) == len(want) and all(got[b][1] == '1' and (abs(got[b][0]) > 1e-5 if sgn == 0 else got[b][0] * sgn > 0)
                                       for b, sgn in want.items())
    # (flatten after the crease fills its groove; pinch only gathers)
    check(ok, f'brushes raise, carve, smooth and keep the mesh closed ({ {k: round(v[0], 4) for k, v in got.items()} })')
    out = run(ball + 'v = volume("Ball")\nop("object.sculpt_mode")\nselect("Ball")\nsculpt("Ball", "mask", 0, 0, 0, 0, 0, 0, 5, 1)\n'
              'sculpt("Ball", "draw", 0, 0.9, 0.3, 0.1, 0.9, 0.3, 0.3, 1)\nprint(volume("Ball") - v)\n'
              'op("sculpt.mask_clear")\nsculpt("Ball", "draw", 0.5, 0.7, 0.3, 0.55, 0.7, 0.3, 0.2, 1)\nd1 = volume("Ball") - v\n'
              'op("sculpt.symmetry_x")\nv = volume("Ball")\nsculpt("Ball", "draw", 0.5, 0.7, -0.3, 0.55, 0.7, -0.3, 0.2, 1)\nd2 = volume("Ball") - v\n'
              'print(round(d2 / d1 * 10))')
    lines = out.splitlines()
    check(len(lines) == 2 and abs(float(lines[0])) < 1e-6 and lines[1] in ('19', '20', '21'),
          f'a full mask holds the surface; X symmetry doubles the stroke ({lines})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('delete("Cube")\nadd("sphere", "Ball", 0, 1, 0)\nscale("Ball", 2)\nmodifier("Ball", "subsurf")\nmodset("Ball", 0, "levels", 5)\n'
      'modapply("Ball", 0)\nselect("Ball")')
    n = q('print(verts("Ball"))')
    v0 = q('print(volume("Ball"))')
    f.mods(4); f.key(15); f.mods(0)             # Ctrl+Tab: sculpt mode
    f.pump(0.5)
    n0 = int(float(q('print(frames())')))
    f.drag(560, 300, 680, 340, steps=24)
    f.pump(0.2)
    # the app's own drawing times (frametime) of the stroke's frames
    ft = [float(x) for x in q('s = str(frames())\nfor k in 0..200 {\n s = s + " " + str(frametime(k))\n}\nprint(s)').split()]
    lat = sorted(ft[2:int(ft[0]) - n0])
    ms = lat[len(lat) // 2] if lat else 1e9
    v1 = q('print(volume("Ball"))')
    check(float(v1) > float(v0) and ms < SCULPT_BUDGET_MS and len(lat) > 10,
          f'a stroke on {n} vertices raises the surface: {len(lat)} frames drawn in {ms:.1f} ms median '
          f'(budget {SCULPT_BUDGET_MS} ms) ({v0} -> {v1})')
    f.shot('68_sculpt.png')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z: by deltas, exact
    f.pump(0.3)
    v2 = q('print(volume("Ball"))')
    f.mods(5); f.key(44); f.mods(0)             # Ctrl+Shift+Z
    f.pump(0.3)
    v3 = q('print(volume("Ball"))')
    check(v2 == v0 and v3 == v1, f'Ctrl+Z puts every vertex back, Ctrl+Shift+Z sculpts it again ({v2}, {v3})')
    f.key(31)                                   # S: the smooth brush
    f.pump(0.1)
    f.drag(600, 300, 640, 320, steps=8)
    f.pump(0.2)
    v4 = q('print(volume("Ball"))')
    f.mods(4); f.key(15); f.mods(0)             # Ctrl+Tab: back
    f.pump(0.2)
    check(float(v4) < float(v3), f'S picks the smooth brush; Ctrl+Tab leaves sculpt mode ({v3} -> {v4})')
    f.proc.kill()


def tablet():
    """A pen through zwp_tablet_v2: pressure scales the brush, the eraser end
    inverts it, the stabilizer holds short wobbles; the mouse still works."""
    print('  -- tablet, pressure, stabilizer --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('delete("Cube")\nadd("sphere", "Ball", 0, 1, 0)\nscale("Ball", 2)\nmodifier("Ball", "subsurf")\nmodset("Ball", 0, "levels", 3)\n'
      'modapply("Ball", 0)\nselect("Ball")')
    f.mods(4); f.key(15); f.mods(0)             # Ctrl+Tab: sculpt mode
    f.pump(0.3)
    pen = f.pen_add()
    path = [(560 + 6 * i, 300 + 2 * i) for i in range(16)]
    vol = lambda: float(q('print(volume("Ball"))'))
    undo = lambda: (f.mods(4), f.key(44), f.mods(0), f.pump(0.2))
    v0 = vol()
    f.pen_stroke(pen, path, 1.0)
    d_full = vol() - v0
    undo()
    f.pen_stroke(pen, path, 0.25)
    d_light = vol() - v0
    undo()
    check(d_full > 0 and 0.1 * d_full < d_light < 0.5 * d_full,
          f'pen pressure scales the strength: full {d_full:.5f}, a quarter {d_light:.5f}')
    f.shot('69_pen.png')
    q('op("sculpt.pressure_curve")\nop("sculpt.pressure_curve")')   # linear -> hard -> soft
    f.pen_stroke(pen, path, 0.25)
    d_soft = vol() - v0
    undo()
    check(d_soft > 1.5 * d_light, f'the soft curve gives a light touch more ({d_soft:.5f})')
    eraser = f.pen_add(eraser=True)
    f.pen_stroke(eraser, path, 1.0)
    d_er = vol() - v0
    undo()
    check(d_er < 0, f'the eraser end inverts the brush ({d_er:.5f})')
    v1 = vol()
    for _ in range(3):                          # Shift+S: 10, 25, 50 px
        f.mods(1); f.key(31); f.mods(0)
    f.click(600, 310)                           # a click: one dab
    f.pump(0.2)
    d_click = vol() - v1
    undo()
    f.drag(600, 310, 630, 320, steps=6)         # within the string: no more
    f.pump(0.2)
    d_short = vol() - v1
    undo()
    f.drag(560, 300, 700, 340, steps=20)        # beyond it: the stroke trails
    f.pump(0.2)
    d_long = vol() - v1
    check(d_short == d_click and d_long > 3 * d_click,
          f'the stabilizer holds a short wobble, follows a long stroke ({d_click:.5f}, {d_short:.5f}, {d_long:.5f})')
    f.shot('70_stabilizer.png')
    f.proc.kill()


def mesh_quality(path):
    """An OBJ's triangles: (open or odd edges, zero-area, smallest angle in
    degrees, edges whose two triangles face apart)."""
    import math
    V, F = [], []
    for line in open(path):
        p = line.split()
        if p and p[0] == 'v':
            V.append(tuple(map(float, p[1:4])))
        elif p and p[0] == 'f':
            F.append(tuple(int(x.split('/')[0]) - 1 for x in p[1:]))
    sub = lambda a, b: [a[i] - b[i] for i in range(3)]
    cross = lambda a, b: [a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]]
    dot = lambda a, b: sum(a[i] * b[i] for i in range(3))
    half, zero, minang, normal = {}, 0, 180.0, {}
    for i, f in enumerate(F):
        a, b, c = (V[j] for j in f)
        n = cross(sub(b, a), sub(c, a))
        ln = math.sqrt(dot(n, n))
        if ln < 1e-12:
            zero += 1
        normal[i] = [x / (ln or 1) for x in n]
        for k in range(3):
            half[(f[k], f[(k + 1) % 3])] = half.get((f[k], f[(k + 1) % 3]), []) + [i]
            p, q, r = V[f[k]], V[f[(k + 1) % 3]], V[f[(k + 2) % 3]]
            u, w = sub(q, p), sub(r, p)
            d = math.sqrt(dot(u, u) * dot(w, w)) or 1
            minang = min(minang, math.degrees(math.acos(max(-1, min(1, dot(u, w) / d)))))
    odd = sum(1 for (a, b), ts in half.items() if len(ts) != 1 or len(half.get((b, a), [])) != 1)
    folds = sum(1 for (a, b), ts in half.items() if a < b and len(ts) == 1 and len(half.get((b, a), [])) == 1
                and dot(normal[ts[0]], normal[half[(b, a)][0]]) < -0.5)
    return odd, zero, minang, folds


def dyntopo():
    """Dynamic topology: strokes split long edges and collapse short ones
    under the brush, keeping a closed, fold-free surface; undo is exact."""
    print('  -- dynamic topology --')
    home = tempfile.mkdtemp(prefix='bee-dyn-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    ball = 'delete("Cube")\nadd("sphere", "Ball")\nselect("Ball")\nop("object.sculpt_mode")\nop("sculpt.dyntopo")\n'
    r = subprocess.run([BIN, '--eval', ball + 'op("sculpt.detail_finer")\nop("sculpt.detail_finer")\n'
                        'sculpt("Ball", "draw", 0, 0.9, 0.4, 0.4, 0.7, 0.5, 0.3, 0.5)\n'
                        'sculpt("Ball", "snake hook", 0.2, 0.95, 0.2, 0.6, 1.4, 0.2, 0.2, 0.5)\n'
                        'print(verts("Ball"), manifold("Ball"))\nop("file.export_obj", "~/BeeModel/dyn.obj")'],
                       env=env, capture_output=True, text=True, timeout=120)
    out = (r.stdout + r.stderr).split()
    try:
        odd, zero, ang, folds = mesh_quality(os.path.join(home, 'BeeModel', 'dyn.obj'))
        ok = int(out[0]) > 1500 and out[1] == '1' and odd == 0 and zero == 0 and ang > 2 and folds == 0
    except Exception as e:
        ok, odd, zero, ang, folds = False, 0, 0, 0, repr(e)
    check(ok, f'a draw and a snake-hook stroke refine 482 vertices to {out[:1]}: closed, no slivers '
              f'(smallest angle {ang:.1f} deg), no folds ({odd} odd edges, {zero} flat, {folds} folds)')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('delete("Cube")\nadd("sphere", "Ball", 0, 1, 0)\nscale("Ball", 3)\nselect("Ball")')
    f.mods(4); f.key(15); f.mods(0)             # Ctrl+Tab, Ctrl+D, Ctrl+[ twice
    f.mods(4); f.key(32); f.mods(0)
    f.mods(4); f.key(26); f.key(26); f.mods(0)
    f.pump(0.3)
    v0 = q('print(verts("Ball"), volume("Ball"))')
    f.drag(560, 320, 680, 370, steps=30)
    f.pump(0.3)
    v1 = q('print(verts("Ball"), manifold("Ball"))').split()
    f.shot('71_dyntopo.png')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z: the mesh before
    f.pump(0.4)
    v2 = q('print(verts("Ball"), volume("Ball"))')
    check(int(v1[0]) > 2 * int(v0.split()[0]) and v1[1] == '1' and v2 == v0,
          f'Ctrl+D: a stroke adds detail under the brush ({v0.split()[0]} -> {v1[0]} vertices, closed); Ctrl+Z restores it')
    f.proc.kill()
    r = subprocess.run([BIN, '--eval', 'delete("Cube")\nadd("sphere", "Ball")\nmodifier("Ball", "subsurf")\n'
                        'modset("Ball", 0, "levels", 2)\nmodapply("Ball", 0)\nselect("Ball")\nop("object.sculpt_mode")\n'
                        'op("sculpt.dyntopo")\nv = verts("Ball")\nfor i in 0..6 {\n op("sculpt.detail_coarser")\n}\n'
                        'sculpt("Ball", "smooth", 0, 1, 0, 0.3, 0.9, 0.3, 0.6, 0.5)\nprint(v, verts("Ball"), manifold("Ball"))'],
                       env=env, capture_output=True, text=True, timeout=120)
    out = (r.stdout + r.stderr).split()
    check(len(out) == 3 and int(out[1]) < int(out[0]) and out[2] == '1',
          f'a coarser detail collapses a dense patch, still closed ({out})')


class Bridge:
    """An MCP client over `beemodel --mcp-bridge` (stdio), like Claude Code."""
    def __init__(self, fake):
        self.f = fake
        self.p = subprocess.Popen([BIN, '--mcp-bridge'], env=fake.env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE)
        os.set_blocking(self.p.stdout.fileno(), False)
        self.buf = b''

    def write(self, data):
        self.p.stdin.write(data); self.p.stdin.flush()

    def read(self, timeout=5.0, want=None):
        """Next message (or the one with id == want); None on timeout."""
        end = time.time() + timeout
        while time.time() < end:
            while b'\n' in self.buf:
                line, self.buf = self.buf.split(b'\n', 1)
                msg = json.loads(line)
                if want is None or msg.get('id') == want:
                    return msg
            self.f.pump(0.02)
            try:
                chunk = os.read(self.p.stdout.fileno(), 1 << 20)
                if chunk: self.buf += chunk
            except BlockingIOError:
                pass
        return None

    def call(self, rid, method, params=None):
        msg = {'jsonrpc': '2.0', 'id': rid, 'method': method}
        if params is not None: msg['params'] = params
        self.write(json.dumps(msg).encode() + b'\n')
        return self.read(want=rid)

    def close(self):
        self.p.stdin.close(); self.p.wait(timeout=5)


def mcp_conformance():
    """MCP / JSON-RPC conformance through the stdio bridge and the socket."""
    print('  -- MCP conformance --')
    import re
    f = Fake()
    f.pump(1.0, until_frame=True)
    b = Bridge(f)
    bad = []
    def expect(cond, what):
        if not cond: bad.append(what)
    r = b.call(1, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                 'clientInfo': {'name': 'conformance', 'version': '1'}})
    res = (r or {}).get('result', {})
    version = open('VERSION').read().strip()
    expect(r and r.get('jsonrpc') == '2.0' and r.get('id') == 1, 'initialize: jsonrpc 2.0 + id')
    expect(res.get('protocolVersion') == '2025-06-18', 'initialize: protocol version echoed')
    expect('tools' in res.get('capabilities', {}) and 'resources' in res.get('capabilities', {}),
           'initialize: tools + resources capabilities')
    expect(res.get('serverInfo') == {'name': 'beemodel', 'version': version}, 'initialize: serverInfo')
    expect(isinstance(res.get('instructions'), str), 'initialize: instructions')
    b.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    r = b.call(2, 'ping')
    expect(r and r.get('id') == 2 and r.get('result') == {}, 'notification: no reply; ping -> {}')
    tools = (b.call(3, 'tools/list') or {}).get('result', {}).get('tools', [])
    names = [t.get('name') for t in tools]
    expect(len(names) == len(set(names)) and len(names) > 20, f'tools/list: {len(names)} unique tools')
    for t in tools:
        sch = t.get('inputSchema', {})
        if not (re.fullmatch(r'[A-Za-z0-9_-]{1,64}', t.get('name', '')) and isinstance(t.get('description'), str)
                and sch.get('type') == 'object' and isinstance(sch.get('properties', {}), dict)
                and set(sch.get('required', [])) <= set(sch.get('properties', {}))):
            bad.append(f'tool schema: {t.get("name")}')
    calls = [('scene_summary', {}), ('create_primitive', {'type': 'cube', 'name': 'Conf'}),
             ('set_transform', {'name': 'Conf', 'location': [1, 2, 3]}), ('select', {'names': ['Conf']}),
             ('viewport_capture', {}), ('script_eval', {'code': 'count()'}), ('run_operator', {'id': 'view.toggle_grid'}),
             ('op_view_toggle_grid', {}), ('delete', {'names': ['Conf']}), ('undo', {}), ('redo', {})]
    rid = 10
    for name, args in calls:
        rid += 1
        r = b.call(rid, 'tools/call', {'name': name, 'arguments': args})
        res = (r or {}).get('result', {})
        content = res.get('content')
        ok = (isinstance(content, list) and content and all(c.get('type') in ('text', 'image') for c in content)
              and all(isinstance(c.get('text'), str) for c in content if c['type'] == 'text')
              and all(c.get('mimeType') == 'image/png' and isinstance(c.get('data'), str) for c in content if c['type'] == 'image')
              and res.get('isError') is False)
        expect(ok, f'tools/call {name}: content shape / isError false')
    r = b.call(30, 'tools/call', {'name': 'no_such_tool', 'arguments': {}})
    expect((r or {}).get('result', {}).get('isError') is True, 'unknown tool: result.isError (not a protocol error)')
    r = b.call(31, 'tools/call', {'name': 'create_primitive', 'arguments': {}})
    expect((r or {}).get('result', {}).get('isError') is True, 'missing required argument: isError')
    r = b.call(32, 'resources/list')
    rs = (r or {}).get('result', {}).get('resources', [])
    expect(rs and all('uri' in x and 'name' in x for x in rs), 'resources/list')
    r = b.call(33, 'resources/read', {'uri': 'bee://scene'})
    c = (r or {}).get('result', {}).get('contents', [{}])[0]
    expect(c.get('uri') == 'bee://scene' and c.get('mimeType') == 'application/json' and json.loads(c.get('text', 'null')),
           'resources/read: uri, mimeType, JSON text')
    expect((b.call(34, 'no/such') or {}).get('error', {}).get('code') == -32601, 'unknown method: -32601')
    for rid in ('abc-1', 9007199254740991, 0, -5):
        r = b.call(rid, 'ping')
        expect(r is not None and r.get('id') == rid and type(r.get('id')) == type(rid), f'id echoed: {rid!r}')
    b.write(b'{"jsonrpc": "2.0", "id": 40, "met')      # one message in two writes
    f.pump(0.2)
    b.write(b'hod": "ping"}\n')
    expect((b.read(want=40) or {}).get('result') == {}, 'a message split across writes')
    b.write(b'{not json\n')
    r = b.read()
    expect(r and r.get('id') is None and r.get('error', {}).get('code') == -32700, 'malformed JSON: -32700, id null')
    b.write(b'[{"jsonrpc":"2.0","id":41,"method":"ping"}]\n')
    r = b.read()
    expect(r and r.get('error', {}).get('code') == -32600, 'batch arrays: -32600 (removed in 2025-06-18)')
    b.write(b'{"jsonrpc":"2.0","id":42}\n')
    r = b.read()
    expect(r and r.get('id') == 42 and r.get('error', {}).get('code') == -32600, 'no method: -32600 with the id')
    b.write(b'{"jsonrpc":"2.0","id":43,"result":{}}\n')
    expect((b.call(44, 'ping') or {}).get('id') == 44, 'responses from the client are ignored')
    big = 'x = 0\n' + ''.join(f'x += {i}\n' for i in range(20000)) + 'x'
    big = big[:64000].rsplit('\n', 1)[0] + '\nx'
    r = b.call(45, 'tools/call', {'name': 'script_eval', 'arguments': {'code': big}})
    expect(r and r['result']['content'][0]['text'].startswith('= '),
           f'large request ({len(json.dumps(big)) // 1024} KiB, {big.count(chr(10))} script lines)')
    r = b.call(46, 'tools/call', {'name': 'create_primitive', 'arguments': {'type': 'cube', 'name': 'Kubus-\u00e9\u2603'}})
    t = (b.call(47, 'tools/call', {'name': 'scene_summary', 'arguments': {}}) or {})['result']['content'][0]['text']
    expect('Kubus-\u00e9\u2603' in [o['name'] for o in json.loads(t.split('\n')[0])['objects']], 'UTF-8 names round-trip')
    # three socket clients at once, requests interleaved
    cs = [Mcp(f) for _ in range(3)]
    for i, c in enumerate(cs):
        c.send({'jsonrpc': '2.0', 'id': 100 + i, 'method': 'ping'})
    got = []
    for i, c in enumerate(cs):
        end = time.time() + 3
        while time.time() < end and b'\n' not in c.buf:
            f.pump(0.02)
            try:
                c.buf += c.s.recv(65536)
            except BlockingIOError:
                pass
        got.append(json.loads(c.buf.split(b'\n')[0]).get('id') if b'\n' in c.buf else None)
    expect(got == [100, 101, 102], f'concurrent clients get their own replies ({got})')
    for c in cs: c.s.close()
    b.close()
    for x in bad:
        print('     ' + x)
    check(not bad and f.proc.poll() is None, f'MCP conformance: {len(bad)} problem(s), server alive')
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
    f.mods(1); f.key(44); f.mods(0)      # Shift+Z: material preview
    f.pump(0.3)
    f.latencies = []
    f.drag(700, 330, 600, 300, steps=12)
    lat = sorted(f.latencies[1:])
    ms = lat[len(lat) // 2] if lat else 1e9
    check(ms < PREVIEW_BUDGET_MS, f'~300k triangles, material preview: orbit frame {ms:.1f} ms median (budget {PREVIEW_BUDGET_MS} ms)')
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
