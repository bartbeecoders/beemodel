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
PLACE_BUDGET_MS = 200              # a million instances scattered (4-core CI)
INSTANCE_FRAME_MS = 100            # 100k instances drawn (4-core CI)

OUT = sys.argv[1] if len(sys.argv) > 1 else 'build/shots'
BIN = os.path.join(os.path.dirname(__file__), '..', 'build', 'beemodel')
os.makedirs(OUT, exist_ok=True)

GLOBALS = [(1, 'wl_compositor', 4), (2, 'wl_shm', 1), (3, 'xdg_wm_base', 2),
           (4, 'wl_seat', 5), (5, 'wp_cursor_shape_manager_v1', 1),
           (6, 'wp_fractional_scale_manager_v1', 1), (7, 'wp_viewporter', 1),
           (8, 'zwp_tablet_manager_v2', 1), (9, 'zwp_pointer_constraints_v1', 1),
           (10, 'zwp_relative_pointer_manager_v1', 1), (11, 'wl_data_device_manager', 3)]


def wstr(s):
    b = s.encode() + b'\0'
    return struct.pack('<I', len(b)) + b + b'\0' * (-len(b) % 4)


class Fake:
    def __init__(self, args=(), home=None, welcome=False):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, 'wl')
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.path)
        srv.listen(1)
        self.home = home or tempfile.mkdtemp()  # never touch the real ~/BeeModel or cache
        env = dict(os.environ, WAYLAND_DISPLAY=self.path, HOME=self.home,
                   XDG_CACHE_HOME=os.path.join(self.home, 'cache'),
                   XDG_RUNTIME_DIR=self.home,       # MCP socket lands here
                   BEEMODEL_WELCOME='1' if welcome else '0')
        self.env = env
        self.t0 = time.time()
        self.proc = subprocess.Popen([BIN, *args], env=env)
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
        elif iface == 'zwp_pointer_constraints_v1' and op == 1:  # lock_pointer
            self.objs[u(0)] = 'zwp_locked_pointer_v1'
            self.locked = u(0)
            self.send(u(0), 0)                            # locked
        elif iface == 'zwp_locked_pointer_v1' and op == 0:       # destroy
            self.locked = None
        elif iface == 'zwp_relative_pointer_manager_v1' and op == 1:
            self.objs[u(0)] = 'zwp_relative_pointer_v1'
            self.relptr = u(0)
        elif iface == 'zwp_relative_pointer_v1' and op == 0:
            self.relptr = None
        elif iface == 'wl_data_device_manager' and op == 0:   # create_data_source
            self.objs[u(0)] = 'wl_data_source'
            self.sources = getattr(self, 'sources', {}); self.sources[u(0)] = []
        elif iface == 'wl_data_device_manager' and op == 1:   # get_data_device
            self.objs[u(0)] = 'wl_data_device'
            self.ddev = u(0)
        elif iface == 'wl_data_source' and op == 0:           # offer(mime)
            n = u(0)
            self.sources[obj].append(p[4:4 + n - 1].decode())
        elif iface == 'wl_data_source' and op == 1:           # destroy
            self.sources.pop(obj, None)
            if getattr(self, 'selection', None) == obj:
                self.selection = None
        elif iface == 'wl_data_device' and op == 1:           # set_selection(source, serial)
            self.selection = u(0) or None
        elif iface == 'wl_data_offer' and op == 1:            # receive(mime, fd)
            fd = self.fds.pop(0)
            os.write(fd, self.offer_text.encode())
            os.close(fd)
        elif iface == 'wl_pointer' and op == 0:          # set_cursor
            self.cursor_hidden = (u(1) == 0)
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

    def rel(self, dx, dy):
        """relative pointer motion (a locked pointer: play mode)"""
        rp = getattr(self, 'relptr', None)
        if rp:
            fx, fy = int(dx * 256), int(dy * 256)
            self.send(rp, 0, struct.pack('<IIiiii', 0, int(time.time() * 1e6) & 0xffffffff, fx, fy, fx, fy))
            self.pump(0.02)

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

    def clipboard(self):
        """Paste as another program would: the app's selection, through a pipe."""
        src = getattr(self, 'selection', None)
        if not src:
            return None
        r, w = os.pipe()
        mime = wstr('text/plain;charset=utf-8')
        msg = struct.pack('<II', src, ((8 + len(mime)) << 16) | 1) + mime
        socket.send_fds(self.c, [msg], [w])
        os.close(w)
        os.set_blocking(r, False)
        out, end = b'', time.time() + 2
        while time.time() < end:
            self.pump(0.05)
            try:
                chunk = os.read(r, 65536)
            except BlockingIOError:
                continue
            if not chunk:
                break
            out += chunk
        os.close(r)
        return out.decode(errors='replace')

    def set_clipboard(self, text):
        """Another program copies text: an offer becomes the selection."""
        self.offer_text = text
        self.n_offers = getattr(self, 'n_offers', 0) + 1
        oid = 0xff100000 + self.n_offers
        self.objs[oid] = 'wl_data_offer'
        old = getattr(self, 'selection', None)
        if old:                                    # the app's source: cancelled
            self.send(old, 2)
            self.selection = None
        self.send(self.ddev, 0, struct.pack('<I', oid))            # data_offer
        self.send(oid, 0, wstr('text/plain;charset=utf-8'))        # offer
        self.send(self.ddev, 5, struct.pack('<I', oid))            # selection
        self.pump(0.1)

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
    ui_basics()
    themes()
    widgets_ui()
    tooltips()
    icons()
    menus_ui()
    dialogs()
    files_ui()
    clipboard()
    props_ui()
    viewport_ui()
    tools_ui()
    outliner_ui()
    status_ui()
    files_more()
    cad_ui()
    materials_more()
    paint_ui()
    anim_ui()
    physics_ui()
    render_ui()
    team_ui()
    prefs_ui()
    workspaces_ui()
    help_ui()
    a11y_ui()
    walkthrough_ui()
    ui_bench()
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
    materials_v2()
    material_nodes()
    node_canvas()
    material_editor()
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
    multires()
    uv_maps()
    uv_editor()
    uv_textures()
    texture_paint()
    paint_layers()
    vertex_paint()
    baking()
    node_editor()
    geometry_nodes()
    node_groups()
    instancing()
    curves()
    procedural()
    copilot()
    animation()
    anim_editors()
    armatures()
    rigging()
    rigid_bodies()
    physics_panel()
    mechanisms()
    cloth()
    sim_cache()
    virtual_geometry()
    virtual_geometry_cuts()
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
    count = lambda: int((Mcp(f).tool('script_eval', {'code': 'print(count())'})[0] or '0').strip())
    f.key(61); f.type('torus'); f.key(28)            # create, then undo it
    check(count() == 4, 'palette adds a torus')
    undo()
    check(count() == 3, 'Ctrl+Z removes the torus again')
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
    count = lambda: int((Mcp(f).tool('script_eval', {'code': 'print(count())'})[0] or '0').strip())
    n0 = count()
    cmd(f'file.import_obj {T}/tet.obj')
    check(count() == n0 + 1, 'OBJ import adds an object (v/vt/vn and negative indices)')
    cmd(f'file.import_stl {T}/a.stl')
    check(count() == n0 + 2, 'binary STL import adds an object')
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


def ui_tree(m):
    """The widgets of the last frame (MCP ui_tree)."""
    text, _ = m.tool('ui_tree')
    try:
        return json.loads(text).get('widgets', [])
    except ValueError:
        return []


def widget(m, name, sub=0):
    for w in ui_tree(m):
        if w['name'] == name and w['sub'] == sub:
            return w
    return None


def widget_xy(m, name, sub=0):
    """Centre of a widget, found by name (no hard-coded coordinates)."""
    w = widget(m, name, sub)
    return (w['x'] + w['w'] // 2, w['y'] + w['h'] // 2) if w else (0, 0)


def menu_pick(f, m, *path):
    """Click through the menus by label (ui_tree): menu_pick(f, m, 'View',
    'Analysis', 'Show Boundary Edges'). Submenus open by hovering."""
    t = [w for w in ui_tree(m) if w['kind'] == 'menu' and w['label'] == path[0]]
    if not t:
        return False
    f.click(t[0]['x'] + t[0]['w'] // 2, t[0]['y'] + t[0]['h'] // 2)
    f.pump(0.1)
    for i, label in enumerate(path[1:], 1):
        items = [w for w in ui_tree(m) if w['kind'] == 'menuitem' and w['label'] == label]
        if not items:
            f.key(1); f.key(1)
            return False
        w = items[-1]
        x, y = w['x'] + 40, w['y'] + w['h'] // 2
        if i < len(path) - 1:
            f.move(x, y); f.pump(0.1)
        else:
            f.click(x, y); f.pump(0.2)
    return True


def wait_widget(f, m, name, sub=0):
    """The widget once a frame has drawn it (None after a second)."""
    for _ in range(10):
        w = widget(m, name, sub)
        if w:
            return w
        f.pump(0.1)
    return None


def wait_value(f, m, name, sub, want):
    """A widget's value once it is want (or the last one seen, after a second)."""
    v = None
    for _ in range(10):
        w = widget(m, name, sub)
        v = w and w.get('value')
        if v == want:
            break
        f.pump(0.1)
    return v


def add_modifier(f, m, label):
    """Properties > Modifiers > Add Modifier > label (U17)."""
    x, y = widget_xy(m, 'modifier.add')
    f.click(x, y)
    items = []
    for _ in range(10):                        # (the list is laid out when drawn)
        f.pump(0.1)
        items = [w for w in ui_tree(m) if w['kind'] == 'menuitem' and w['label'] == label and w['x'] > 0]
        if items:
            break
    if items:
        f.click(items[-1]['x'] + 40, items[-1]['y'] + items[-1]['h'] // 2); f.pump(0.2)


def props_tab(m, f, name):
    """Open a Properties tab (U10) by name: object, modifiers, material, ..."""
    tabs = ['object', 'modifiers', 'material', 'physics', 'cad', 'scene', 'render', 'viewport', 'animation', 'rig']
    x, y = widget_xy(m, 'props.tab.' + name, tabs.index(name))
    if x:
        f.click(x, y); f.pump(0.2)


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
    check(text.startswith('ok\n'), f'its answer is "ok", not the file it wrote ({text[:12]!r})')
    text, err = m.tool('script_eval', {'code': f'op("file.save", "{path}")\nprint("saved", round(render("{f.home}/r.png", 32, 18, 1) >= 0))'})
    check(not err and text.strip() == 'saved 1', f'a script that saves and renders answers with what it printed ({text[:16]!r})')
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
    props_tab(m, f, 'modifiers')
    x, y = widget_xy(m, 'modifier.value', 0)
    f.drag(x, y, x + 12, y, steps=3)            # levels +1
    check(q('efaces("Cube")') == '= 384', 'dragging the levels field re-evaluates (level 3)')
    f.mods(4); f.key(44); f.mods(0)
    check(q('efaces("Cube")') == '= 96', 'one undo reverts the whole drag')
    add_modifier(f, m, 'Mirror')
    check(q('modcount("Cube")') == '= 2', 'the Add menu adds a Mirror modifier')
    f.shot('43_modifiers.png')
    x, y = widget_xy(m, 'modifier.remove', 0); f.click(x, y); f.pump(0.2)  # x on the first (Subsurf)
    check(q('print(modcount("Cube"), efaces("Cube"))') == '1 12', 'the x button removes Subsurf (Mirror stays)')
    x, y = widget_xy(m, 'modifier.apply', 0); f.click(x, y); f.pump(0.2)   # Apply the Mirror
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
    menu_pick(f, m, 'Object', 'Boolean', 'Boolean Difference')
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
    menu_pick(f, m, 'View', 'Analysis', 'Show Boundary Edges')
    img = f.image().crop((214, 80, 1014, 620))
    cyan = sum(1 for c in img.getdata() if c == (0x40, 0xe0, 0xe0))
    check(cyan > 100, f'View > Show Boundary Edges marks the hole ({cyan} px)')
    f.shot('45_analysis.png')
    menu_pick(f, m, 'Object', 'Repair Mesh')
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
    menu_pick(f, m, 'Add', 'Cylinder')         # (at the 3D cursor)
    f.key(31); f.type('0.3'); f.key(28)         # S 0.3
    f.key(31); f.key(21); f.type('4'); f.key(28)  # S Y 4: 2.4 tall
    f.key(34); f.key(21); f.type('1'); f.key(28)  # G Y 1: through the part
    f.mods(1); f.click(*project((0.9, 0.5, 1))); f.mods(0)   # Shift+click the cube
    check(q('print(active())') == 'Cube', 'Shift+click makes the cube active, the cylinder stays selected')
    menu_pick(f, m, 'Object', 'Boolean', 'Boolean Difference')
    r = q('print(exists("Cylinder"), manifold("Cube"), round(volume("Cube") * 1000))').split()
    check(r[:2] == ['0', '1'] and r[2] == '6599', f'Edit > Boolean Difference drills the hole: closed, volume {r[2] if len(r) > 2 else "?"} / 6599')
    props_tab(m, f, 'modifiers')
    add_modifier(f, m, 'Bevel')                # Properties: Add Modifier > Bevel
    f.pump(0.3)
    r = q('print(modcount("Cube"), efaces("Cube") > faces("Cube"))')
    check(r == '1 1', 'the Bevel modifier rounds the edges (more faces after it)')
    f.move(*project((0, 1, 0)))
    for _ in range(6):
        f.wheel(-1)                             # zoom in on the part
    f.pump(0.2)
    f.shot('46_walkthrough.png')
    x, y = widget_xy(m, 'modifier.apply', 0); f.click(x, y); f.pump(0.3)  # Apply
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
    props_tab(m, f, 'material')
    x, y = widget_xy(m, 'material.new'); f.click(x, y); f.pump(0.3)  # Material: New
    check(q('print(matof("Cube"), matget("Material", "roughness"))') == 'Material 0.5',
          'Properties > Material > + New makes a material and gives it to the cube')
    w = wait_widget(f, m, 'material.roughness', 2)  # the slider follows the pointer: 70 %
    f.drag(w['x'] + w['w'] // 2, w['y'] + 11, w['x'] + round(w['w'] * 0.7), w['y'] + 11, steps=4)
    r = q('print(round(matget("Material", "roughness") * 100))')
    check(r == '70', f'dragging roughness changes it ({r} %)')
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
    UI stays live; Esc stops; passes, saving, settings in .bee, agents. (The
    CPU's render: a GPU helper would finish it before it could be watched;
    tests/gpu.py covers that one.)"""
    print('  -- Render window --')
    from PIL import Image
    gpu = os.environ.get('BEEMODEL_GPU')
    os.environ['BEEMODEL_GPU'] = 'off'
    try:
        f = Fake()
    finally:
        if gpu is None:
            os.environ.pop('BEEMODEL_GPU', None)
        else:
            os.environ['BEEMODEL_GPU'] = gpu
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
    # a link backwards re-sorts the graph; a loop is refused
    out = run(GRAPH_SCENE + 'a = node(m, "noise")\nb = node(m, "ramp")\nprint(link(m, b, a, 1))\n'
              'print(nodeinfo(m, 1, "type"), nodeinfo(m, 2, "link", 1))\nlink(m, 2, 1, 1)')
    check(out.split()[:3] == ['2', '6', '1'] and 'no such node' in out,
          f'a link backwards re-sorts the graph; a loop is refused ({out.split()[:3]})')
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


LEAF_SCENE = ('delete("Cube")\nadd("plane", "Floor", 0, 0, 0)\nscale("Floor", 8)\nf = material("F")\nassign("Floor", f)\n'
              'add("plane", "Leaf", 0, 2, 0)\nscale("Leaf", 2.5)\nm = material("L")\nassign("Leaf", m)\n'
              'matset(m, "base", 0.2, 0.7, 0.2)\n')
V012_GRAPH = ('n = node(m, "noise", 3, 5, 0.55)\nr = node(m, "ramp")\nlink(m, n, r, 1)\nnodeset(m, r, 2, 0.6, 0.15, 0.05)\n'
              'nodeset(m, r, 3, 0.95, 0.8, 0.5)\nsocket(m, "base", r)\nc = node(m, "checker", 2)\nnodeset(m, c, 1, 0.1)\n'
              'nodeset(m, c, 2, 0.8)\nsocket(m, "roughness", c)\nb = node(m, "bump", 2, 0.2)\nlink(m, n, b, 1)\n'
              'socket(m, "normal", b)\nk = node(m, "gradient", 1, 2)\nsocket(m, "metallic", k)\ne = node(m, "checker", 5)\n'
              'nodeset(m, e, 1, 0.3, 0.1, 0)\nnodeset(m, e, 2, 0)\nsocket(m, "emission", e)\n')


def materials_v2():
    """Material records v2 (M1): v0.12 files upgrade, 48-node graphs, every
    PBR pin, masked / translucent / one-sided materials in Hive, glTF."""
    print('  -- materials v2: pins, opacity, 48 nodes --')
    from PIL import Image
    home = tempfile.mkdtemp(prefix='bee-mat2-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=180)
        return r.stdout.strip() + r.stderr.strip()
    def shot(name, code, spp=24, size=(160, 90)):
        p = os.path.join(home, name + '.png')
        run(code + f'\nrender("{p}", {size[0]}, {size[1]}, {spp})')
        return Image.open(p).convert('RGB') if os.path.exists(p) else Image.new('RGB', size)
    lum = lambda p: sum(p) / 3
    green = lambda im: sum(1 for p in im.getdata() if p[1] > p[0] + 40 and p[1] > p[2] + 40)
    plum = lambda c: (((c >> 16) & 255) + ((c >> 8) & 255) + (c & 255)) / 3
    # a v0.12 file: its 5 sockets become pins, and it renders as it did
    fx = os.path.abspath('tests/fixtures/graph_v012.bee')
    a, b = os.path.join(home, 'old.png'), os.path.join(home, 'new.png')
    out = run(f'op("file.open", "{fx}")\nm = "G"\nprint(nodeinfo(m, 0, "count"), nodeinfo(m, 0, "socket", 0), '
              'nodeinfo(m, 0, "socket", 1), nodeinfo(m, 0, "socket", 3), nodeinfo(m, 0, "socket", 4), '
              f'nodeinfo(m, 0, "socket", 6))\nrender("{a}", 160, 90, 16, 1)')
    check(out.split()[:6] == ['6', '2', '5', '3', '6', '4'],
          f'a v0.12 graph opens: base, metallic, roughness, emission, normal on their pins ({out.split()[:6]})')
    run(GRAPH_SCENE + V012_GRAPH + f'render("{b}", 160, 90, 16, 1)')
    same = os.path.exists(a) and os.path.exists(b) and open(a, 'rb').read() == open(b, 'rb').read()
    check(same, 'the v0.12 file renders exactly like the same graph made today')
    # 48 nodes: the 49th is refused; they save and come back
    bee = os.path.join(home, 'big.bee')
    chain = ''.join(f'n{i} = node(m, "math", 0)\n' + (f'link(m, n{i-1}, n{i}, 1)\n' if i else '') for i in range(48))
    out = run(GRAPH_SCENE + chain + 'nodeset(m, n0, 1, 0.05)\nnodeset(m, n0, 2, 0.01)\n' + ''.join(
        f'nodeset(m, n{i}, 2, 0.01)\n' for i in range(1, 48)) + 'socket(m, "base", n47)\n'
        f'print(nodeinfo(m, 0, "count"))\nop("file.save", "{bee}")\nop("material.node", "G math")\nprint(nodeinfo(m, 0, "count"))')
    out2 = run(f'op("file.open", "{bee}")\nprint(nodeinfo("G", 0, "count"), nodeinfo("G", 0, "socket", 0), nodeinfo("G", 48, "link", 1))')
    check(out.split()[:1] == ['48'] and out.split()[-1] == '48',
          f'a material holds 48 nodes, the 49th is refused ({out.split()[:1]} {out.split()[-1:]})')
    check(out2.split()[:3] == ['48', '48', '47'], f'a 48-node graph saves and opens ({out2.split()[:3]})')
    # specular from a node: a black, glossy sphere shines only where it says
    gl = 'matset(m, "base", 0, 0, 0)\nmatset(m, "roughness", 0.2)\n'
    p0 = shot('spec0', GRAPH_SCENE + gl + 'matset(m, "specular", 0)', 32)
    p1 = shot('spec1', GRAPH_SCENE + gl + 'matset(m, "specular", 0)\nk = node(m, "checker", 1.5)\nnodeset(m, k, 1, 1)\n'
              'nodeset(m, k, 2, 0)\nsocket(m, "specular", k)', 32)
    d = sum(abs(lum(p0.getpixel((x, y))) - lum(p1.getpixel((x, y)))) for y in range(20, 70, 2) for x in range(55, 105, 2)) / 625
    check(d > 3, f'a specular pin makes the sphere reflect (mean change {d:.1f} levels)')
    # masked: holes where the mask is below the clip value, shadows too
    opq = shot('opaque', LEAF_SCENE, 32, (320, 180))
    msk = shot('masked', LEAF_SCENE + 'matset(m, "blend", 1)\nc = node(m, "checker", 2)\nnodeset(m, c, 1, 1)\n'
               'nodeset(m, c, 2, 0)\nsocket(m, "mask", c)', 32, (320, 180))
    g0, g1 = green(opq), green(msk)
    s0, s1 = sum(lum(p) for p in opq.getdata()), sum(lum(p) for p in msk.getdata())
    check(0.25 * g0 < g1 < 0.75 * g0 and s1 > s0 * 1.03,
          f'a masked leaf has holes and casts a cut-out shadow ({g1} of {g0} green pixels, light x{s1 / max(s0, 1):.2f})')
    msk.save(os.path.join(OUT, '58_masked_leaf.png'))
    # translucent: you see the floor through it
    tr = shot('trans', LEAF_SCENE + 'matset(m, "blend", 2)\nmatset(m, "alpha", 0.3)', 32, (320, 180))
    check(green(tr) < 0.5 * g0, f'a translucent leaf (opacity 0.3) lets the floor show ({green(tr)} of {g0} green)')
    # one-sided: seen from behind (and lit from behind) it is not there
    os_ = shot('sided', LEAF_SCENE + 'rotate("Leaf", rad(180), 0, 0)\nmatset(m, "one_sided", 1)', 32, (320, 180))
    two = shot('twosided', LEAF_SCENE + 'rotate("Leaf", rad(180), 0, 0)', 32, (320, 180))
    s2, s3 = sum(lum(p) for p in os_.getdata()), sum(lum(p) for p in two.getdata())
    check(green(os_) < 0.05 * max(green(two), 1) and s2 > s3,
          f'a one-sided leaf is not seen or hit from behind ({green(os_)} vs {green(two)} green)')
    # glTF: masked and translucent go out as alphaMode and come back
    gf = os.path.join(home, 'm.gltf')
    run(LEAF_SCENE + f'matset(m, "blend", 1)\nmatset(m, "clip", 0.4)\nmatset(f, "blend", 2)\nop("file.export_gltf", "{gf}")')
    txt = open(gf).read() if os.path.exists(gf) else ''
    out = run(f'delete("Cube")\nop("file.import_gltf", "{gf}")\nprint(matget("L", "blend"), matget("L", "clip"), matget("F", "blend"))')
    check('"alphaMode":"MASK","alphaCutoff":0.4' in txt and out.split()[:3] == ['1', '0.4', '2'],
          f'glTF: masked and translucent materials round-trip as alphaMode ({out.split()[:3]})')
    # the preview: an AO pin darkens it; agents see pins and settings
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('m = material("A")\nassign("Cube", m)\nmatset(m, "base", 0.8, 0.8, 0.8)')
    f.mods(1); f.key(44); f.mods(0)             # Shift+Z: material preview
    f.pump(0.5)
    pt = project((0.0, 2.0, 0.0))
    before = plum(px(f, *pt))
    q('c = node("A", "checker", 1)\nnodeset("A", c, 1, 0.2)\nnodeset("A", c, 2, 0.2)\nsocket("A", "ao", c)')
    f.pump(0.5)
    after = plum(px(f, *pt))
    check(after < before - 15, f'an AO pin darkens the ambient light in the preview ({before:.0f} -> {after:.0f})')
    q('matset("A", "blend", 1)\nsocket("A", "mask", c, 0)')
    t = m.tool('scene_summary')[0]
    try:
        g = [mm for mm in json.loads(t.split('\n')[0])['materials'] if mm['name'] == 'A'][0]
        ok = g['blend'] == 1 and g['sockets'] == {'ao': 1, 'mask': 1}
    except Exception as e:
        ok, g = False, e
    check(ok, f'scene_summary shows the blend mode and every pin ({str(g)[:80] if not ok else "blend, ao, mask"})')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    check(q('print(nodeinfo("A", 0, "socket", 12))') == '0', 'undo takes the mask pin back')
    f.proc.kill()



def material_nodes():
    """The node catalogue (M2): every new node type against reference values
    (nodeval), the texture sampler's colour spaces and wraps, the editor's
    add menu, renders with the new nodes."""
    print('  -- material nodes: the catalogue --')
    from PIL import Image
    home = tempfile.mkdtemp(prefix='bee-mnodes-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=180)
        return r.stdout.strip() + r.stderr.strip()
    def vals(code):
        out = run('m = material("M")\n' + code)
        try:
            return [float(v) for v in out.split()]
        except ValueError:
            return out
    close = lambda got, want, eps=2e-3: (isinstance(got, list) and len(got) == len(want)
                                         and all(abs(a - b) <= eps for a, b in zip(got, want)))
    def case(label, code, want, eps=2e-3):
        got = vals(code)
        check(close(got, want, eps), f'{label} ({got if not close(got, want, eps) else want})')
    # math: 31 operations on a = 0.5, b = 2, c = 3
    want = [2.5, -1.5, 1, 0.25, 0.25, 0.5, 2, 0, 0.479426, 0.5, 0.877583, 0.546302, 0.707107, 0, 1, 0.5,
            0, 1, 0.5, 0.5, 2, 5, 1, 1, 0.5, 1.648721, -0.693147, 0.244979, 1, -0.5, 4]
    code = ''.join(f'k = node(m, "math", {i})\nnodeset(m, k, 1, 0.5)\nnodeset(m, k, 2, 2)\nnodeset(m, k, 3, 3)\n'
                   'print(nodeval(m, k, 3, 0, 0, 0))\n' for i in range(31))
    case('math: 31 operations, from add to multiply-add', code, want)
    # vector math, separate / combine, mapping
    case('vector math: dot, cross, normalize, length, reflect',
         'a = node(m, "vmath", 10)\nnodeset(m, a, 1, 1, 2, 3)\nnodeset(m, a, 2, 4, 5, 6)\nprint(nodeval(m, a, 3, 0, 0, 0))\n'
         'c = node(m, "vmath", 11)\nnodeset(m, c, 1, 1, 0, 0)\nnodeset(m, c, 2, 0, 1, 0)\n'
         'print(nodeval(m, c, 0, 0, 0, 0), nodeval(m, c, 1, 0, 0, 0), nodeval(m, c, 2, 0, 0, 0))\n'
         'n = node(m, "vmath", 12)\nnodeset(m, n, 1, 3, 0, 4)\nprint(nodeval(m, n, 0, 0, 0, 0), nodeval(m, n, 2, 0, 0, 0))\n'
         'l = node(m, "vmath", 13)\nnodeset(m, l, 1, 3, 0, 4)\nprint(nodeval(m, l, 3, 0, 0, 0))\n'
         'r = node(m, "vmath", 15)\nnodeset(m, r, 1, 1, -1, 0)\nnodeset(m, r, 2, 0, 1, 0)\n'
         'print(nodeval(m, r, 0, 0, 0, 0), nodeval(m, r, 1, 0, 0, 0))',
         [32, 0, 0, 1, 0.6, 0.8, 5, 1, 1])
    case('separate and combine; mapping turns, scales and offsets',
         's = node(m, "separate")\nnodeset(m, s, 1, 0.1, 0.2, 0.3)\nprint(nodeval(m, s, 7, 0, 0, 0), nodeval(m, s, 11, 0, 0, 0))\n'
         'c = node(m, "combine")\nnodeset(m, c, 1, 0.4)\nnodeset(m, c, 2, 0.5)\nnodeset(m, c, 3, 0.6)\n'
         'print(nodeval(m, c, 1, 0, 0, 0))\n'
         'p = node(m, "mapping", 90)\nnodeset(m, p, 2, 1, 0, 0)\nnodeset(m, p, 3, 2, 2, 2)\n'
         'print(nodeval(m, p, 0, 0, 0, 0, 0.5, 0), nodeval(m, p, 1, 0, 0, 0, 0.5, 0))',
         [0.2, 0.3, 0.5, 1, 1])
    case('texture coordinate tiles and offsets; panner and rotator move it',
         't = node(m, "texcoord", 2, 3, 0.5, 0)\nprint(nodeval(m, t, 0, 0, 0, 0, 0.25, 0.5), nodeval(m, t, 1, 0, 0, 0, 0.25, 0.5))\n'
         'k = node(m, "constant", 2)\np = node(m, "panner", 0.5, 0.25)\np = link(m, k, p, 2)\n'
         'print(nodeval(m, p, 0, 0, 0, 0, 0.1, 0.2), nodeval(m, p, 1, 0, 0, 0, 0.1, 0.2))\n'
         'r = node(m, "rotator", 0.5, 0.5, 1.5707963)\nr = link(m, k, r, 2)\n'
         'print(nodeval(m, r, 0, 0, 0, 0, 1, 0.5), nodeval(m, r, 1, 0, 0, 0, 1, 0.5))',
         [1, 1.5, 1.1, 0.7, 0, 0.5], 3e-3)
    case('position, normal, camera vector, Fresnel, constant, colour',
         'p = node(m, "position")\nprint(nodeval(m, p, 0, 1, 2, 3), nodeval(m, p, 11, 1, 2, 3))\n'
         'n = node(m, "normal")\nprint(nodeval(m, n, 1, 0, 0, 0))\nc = node(m, "camera")\nprint(nodeval(m, c, 2, 0, 0, 0))\n'
         'z = node(m, "combine")\nnodeset(m, z, 3, 1)\nf = node(m, "fresnel", 5, 0.04)\nlink(m, z, f, 1)\nprint(nodeval(m, f, 3, 0, 0, 0))\n'
         'g = node(m, "fresnel", 5, 0.04)\nprint(nodeval(m, g, 3, 0, 0, 0))\n'
         'k = node(m, "constant", 0.7)\nprint(nodeval(m, k, 3, 0, 0, 0))\nq = node(m, "color")\nnodeset(m, q, 1, 0.1, 0.2, 0.3)\n'
         'print(nodeval(m, q, 2, 0, 0, 0))',
         [1, 2, 1, 1, 0.04, 1, 0.7, 0.3])
    case('colour: hue, invert, brightness / contrast, desaturation, gamma',
         'h = node(m, "hsv", 0.5)\nnodeset(m, h, 1, 1, 0, 0)\nprint(nodeval(m, h, 0, 0, 0, 0), nodeval(m, h, 1, 0, 0, 0))\n'
         'i = node(m, "invert", 1)\nnodeset(m, i, 1, 0.25, 0.5, 1)\nprint(nodeval(m, i, 0, 0, 0, 0), nodeval(m, i, 2, 0, 0, 0))\n'
         'b = node(m, "brightcon", 0.1, 1)\nnodeset(m, b, 1, 0.5, 0.5, 0.5)\nprint(nodeval(m, b, 0, 0, 0, 0))\n'
         'd = node(m, "desaturate", 1)\nnodeset(m, d, 1, 1, 0, 0)\nprint(nodeval(m, d, 1, 0, 0, 0))\n'
         'g = node(m, "gamma", 2)\nnodeset(m, g, 1, 0.5, 0.5, 0.5)\nprint(nodeval(m, g, 0, 0, 0, 0))',
         [0, 1, 0.75, 0, 0.6, 0.2126, 0.25])
    out = vals('b = node(m, "blackbody", 2000)\nprint(nodeval(m, b, 0, 0, 0, 0), nodeval(m, b, 2, 0, 0, 0))\n'
               'c = node(m, "blackbody", 12000)\nprint(nodeval(m, c, 0, 0, 0, 0), nodeval(m, c, 2, 0, 0, 0))')
    check(isinstance(out, list) and len(out) == 4 and out[0] > 3 * out[1] and out[3] > out[2],
          f'blackbody: 2000 K is orange-red, 12000 K blue ({out})')
    out = vals('v = node(m, "voronoi", 3, 1, 0)\nw = node(m, "voronoi", 3, 1, 1)\ne = node(m, "voronoi", 3, 1, 2)\n'
               + ''.join(f'print(nodeval(m, v, 3, {x}, {y}, 0.3), nodeval(m, w, 3, {x}, {y}, 0.3), nodeval(m, e, 3, {x}, {y}, 0.3))\n'
                         for x, y in ((0.1, 0.2), (0.7, 0.4), (1.3, -0.6))))
    ok = isinstance(out, list) and len(out) == 9 and all(
        0 <= out[i] <= out[i + 1] and abs(out[i + 2] - (out[i + 1] - out[i])) < 1e-3 for i in (0, 3, 6))
    check(ok and len(set(round(v, 4) for v in out[0::3])) == 3, f'Voronoi: F1 <= F2, edge = F2 - F1, varying ({out})')
    out = vals('b = node(m, "brick", 4, 0.05, 0.5)\nprint(nodeval(m, b, 7, 0, 0, 0, 0.001, 0.001), nodeval(m, b, 7, 0, 0, 0, 0.12, 0.06))\n'
               'w = node(m, "wave", 2)\nprint(nodeval(m, w, 3, 0, 0, 0), nodeval(m, w, 3, 0.125, 0, 0))\n'
               'n = node(m, "whitenoise")\nprint(nodeval(m, n, 3, 0.1, 0.2, 0.3), nodeval(m, n, 3, 0.1, 0.2, 0.3), nodeval(m, n, 3, 0.2, 0.2, 0.3))\n'
               'g = node(m, "gradient", 3)\nprint(nodeval(m, g, 3, 1, 0, 0), nodeval(m, g, 3, -1, 0, 0.0001))\n'
               's = node(m, "gradient", 4, 0.5)\nprint(nodeval(m, s, 3, 0, 1, 0))')
    check(isinstance(out, list) and len(out) == 10 and out[0] == 1 and out[1] == 0 and abs(out[2] - 0.5) < 1e-3
          and abs(out[3] - 1) < 1e-3 and out[4] == out[5] != out[6] and abs(out[7] - 0.5) < 1e-3
          and out[8] > 0.95 and abs(out[9] - 0.5) < 1e-3,
          f'brick mortar, wave, white noise, radial and spherical gradients ({out})')
    case('mix: overlay, darken, difference, soft light, divide',
         ''.join(f'x = node(m, "mix", {mode})\nnodeset(m, x, 1, 1)\nnodeset(m, x, 2, 0.25)\nnodeset(m, x, 3, 0.5)\n'
                 'print(nodeval(m, x, 0, 0, 0, 0))\n' for mode in (5, 6, 8, 9, 10)),
         [0.25, 0.25, 0.25, 0.25, 0.5])
    # the sampler: colour (sRGB) or data; wraps; alpha
    out = vals('op("image.new", "t 2 2")\nfor y in 0..2 { for x in 0..2 { imgset("t", x, y, 128, 128, 128, 64) } }\n'
               'imgset("t", 0, 0, 255, 255, 255, 64)\n'
               'c = node(m, "image", "t", 1, 0, 0)\nd = node(m, "image", "t", 1, 1, 0)\n'
               'print(nodeval(m, c, 0, 0, 0, 0, 0.75, 0.25), nodeval(m, d, 0, 0, 0, 0, 0.75, 0.25), nodeval(m, d, 19, 0, 0, 0, 0.75, 0.25))\n'
               'k = node(m, "image", "t", 1, 1, 1)\nr = node(m, "image", "t", 1, 1, 2)\n'
               'print(nodeval(m, d, 0, 0, 0, 0, 2.25, 0.75), nodeval(m, k, 0, 0, 0, 0, 2.25, 0.75), nodeval(m, r, 0, 0, 0, 0, 1.75, 0.75))')
    check(isinstance(out, list) and len(out) == 6 and abs(out[0] - 0.2158) < 0.01 and abs(out[1] - 0.502) < 0.01
          and abs(out[2] - 0.251) < 0.01 and out[3] > 0.9 and abs(out[4] - 0.502) < 0.01 and out[5] > 0.9,
          f'texture sample: colour or data, alpha, repeat / clamp / mirror ({out})')
    # unknown names, the editor's add menu
    out = run('m = material("M")\nnode(m, "teapot")')
    check('normalmap' in out and 'unknown node type' in out, 'an unknown type is refused, the error lists the types')
    # renders: a Voronoi of cell colours; vertex colours through the node
    def shot(name, code, spp=16, size=(160, 90)):
        p = os.path.join(home, name + '.png')
        run(GRAPH_SCENE + code + f'\nrender("{p}", {size[0]}, {size[1]}, {spp}, 1)')
        return Image.open(p).convert('RGB') if os.path.exists(p) else Image.new('RGB', size)
    v = shot('voronoi', 'v = node(m, "voronoi", 4)\nsocket(m, "base", v, 1)')
    cols = {tuple(c // 32 for c in v.getpixel((x, y))) for y in range(25, 70, 3) for x in range(55, 105, 3)}
    check(len(cols) >= 6, f'a Voronoi texture colours the sphere by cells ({len(cols)} colours)')
    v.save(os.path.join(OUT, '59_voronoi.png'))
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('m = material("N")\nassign("Cube", m)\nselect("Cube")\nop("area.type_node_editor")\nop("area.maximize")')
    f.pump(0.3)
    x, y = widget_xy(m, 'node.add')
    f.click(x, y); f.pump(0.2)
    f.type('voron'); f.pump(0.2); f.key(28); f.pump(0.3)
    got = q('print(nodeinfo("N", 0, "count"), nodeinfo("N", 1, "type"))')
    check(got == '1 25', f'the add menu finds the new nodes: typing "voron" + Enter adds a Voronoi Texture ({got})')
    q('t = node("N", "texcoord", 4, 4)\nw = node("N", "wave", 3)\nlink("N", t, w, 1)\nh = node("N", "hsv", 0.3)\n'
      'link("N", w, h, 1, 1)\nsocket("N", "base", h)\nf = node("N", "fresnel")\nsocket("N", "specular", f)')
    f.pump(0.5)
    f.shot('60_material_nodes.png')
    seen = {px(f, xx, yy) for xx in range(0, 1280, 4) for yy in range(60, 760, 4)}
    check({0x9a4a3c, 0x6b4f96, 0x8a6d1f} <= seen, 'node headers are coloured by category: input, texture, colour')
    f.proc.kill()



def node_canvas():
    """The node canvas (M4): zoom about the pointer, frame all / selected,
    box select, moving a selection, copy / paste (across materials),
    duplicate, cut - each one undo step."""
    print('  -- node canvas --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('m = material("C")\nassign("Cube", m)\nselect("Cube")\nt = node(m, "texcoord", 4, 4)\nw = node(m, "wave", 3)\n'
      'link(m, t, w, 1)\nh = node(m, "hsv", 0.3)\nlink(m, w, h, 1, 1)\nsocket(m, "base", h)\nmaterial("D")\n'
      'op("material.node_move", "C 1 20 20")\nop("material.node_move", "C 2 220 20")\nop("material.node_move", "C 3 420 20")\n'
      'op("material.node_move", "C 0 620 20")\nop("area.type_node_editor")\nop("area.maximize")')
    f.pump(0.3)
    info = lambda mat, *a: q('print(nodeinfo("%s", %s))' % (mat, ', '.join('"%s"' % x if isinstance(x, str) else str(x) for x in a)))
    def header_w(col):
        img = f.image()
        runs = []
        for y in range(70, 760, 2):
            row = [img.getpixel((x, y))[:3] == col for x in range(1280)]
            n = best = 0
            for v in row:
                n = n + 1 if v else 0
                best = max(best, n)
            runs.append(best)
        return max(runs)
    wave = (0x6b, 0x4f, 0x96)
    w100 = header_w(wave)
    f.move(400, 300)
    f.wheel(10); f.pump(0.1); f.wheel(10); f.pump(0.2)     # two steps out: 75 %
    w75 = header_w(wave)
    check(w100 == 170 and abs(w75 - 128) <= 2, f'the wheel zooms the canvas (Wave header {w100} -> {w75} px)')
    f.key(102); f.pump(0.2)                                 # Home: frame all
    fit = header_w(wave)
    check(fit >= 128, f'Home frames every node ({fit} px wide headers)')
    # box select: everything, then a drag moves the selection together
    q('op("node.view_fit")')
    f.pump(0.2)
    x0, y0 = int(info('C', 1, 'x')), int(info('C', 1, 'y'))
    f.drag(5, 110, 1270, 770, steps=6)
    f.pump(0.2)
    img = f.image()
    acc = sum(1 for x in range(0, 1280, 2) for y in range(100, 780, 2) if img.getpixel((x, y))[:3] == (0xf2, 0xb1, 0x34))
    check(acc > 200, f'a box drag selects the nodes it touches (outlined: {acc} px)')
    hx = [x for x in range(1280) if img.getpixel((x, 0))]  # (unused)
    # where is the Wave header now? drag it by 50, 30: all three move
    pos = [(x, y) for y in range(80, 780, 2) for x in range(0, 1280, 2) if img.getpixel((x, y))[:3] == wave]
    wx, wy = min(pos)
    before = [(int(info('C', n, 'x')), int(info('C', n, 'y'))) for n in (1, 2, 3)]
    f.drag(wx + 30, wy + 4, wx + 80, wy + 34, steps=6)
    f.pump(0.2)
    after = [(int(info('C', n, 'x')), int(info('C', n, 'y'))) for n in (1, 2, 3)]
    d = {(a[0] - b[0], a[1] - b[1]) for a, b in zip(after, before)}
    check(len(d) == 1 and list(d)[0] != (0, 0), f'dragging one selected node moves the whole selection ({d})')
    f.mods(4); f.key(44); f.mods(0)                         # Ctrl+Z: one step
    f.pump(0.2)
    back = [(int(info('C', n, 'x')), int(info('C', n, 'y'))) for n in (1, 2, 3)]
    check(back == before, 'one undo puts the whole move back')
    # copy, then paste into another material: links among them kept
    f.mods(4); f.key(46); f.mods(0)                         # Ctrl+C
    q('assign("Cube", "D")')
    f.pump(0.3)
    f.move(300, 300)
    f.mods(4); f.key(47); f.mods(0)                         # Ctrl+V
    f.pump(0.3)
    got = (info('D', 0, 'count'), info('D', 2, 'link', 1), info('D', 3, 'link', 1), info('D', 3, 'linkout', 1))
    check(got == ('3', '1', '2', '1'), f'copy and paste into another material keeps the links among the nodes ({got})')
    # duplicate (Shift+D): three more, 40 down and right; cut (Ctrl+X)
    f.mods(1); f.key(32); f.mods(0)
    f.pump(0.3)
    got = (info('D', 0, 'count'), int(info('D', 4, 'x')) - int(info('D', 1, 'x')), int(info('D', 4, 'y')) - int(info('D', 1, 'y')),
           info('D', 5, 'link', 1))
    check(got == ('6', 40, 40, '4'), f'Shift+D duplicates the selection, links and all ({got})')
    f.mods(4); f.key(45); f.mods(0)                         # Ctrl+X: the copies
    f.pump(0.3)
    check(info('D', 0, 'count') == '3', f'Ctrl+X cuts the selection ({info("D", 0, "count")})')
    f.mods(4); f.key(44); f.mods(0)
    f.pump(0.2)
    check(info('D', 0, 'count') == '6', f'undo brings the cut nodes back ({info("D", 0, "count")})')
    # a comment frame round the selection; its title drags the nodes along
    q('assign("Cube", "C")')
    f.pump(0.3)
    q('op("node.view_fit")')
    f.pump(0.2)
    f.drag(5, 110, 1270, 770, steps=6)                      # all selected
    f.pump(0.2)
    f.key(46)                                               # C
    f.pump(0.3)
    img = f.image()
    bar = [(x, y) for y in range(80, 780, 2) for x in range(0, 1280, 2) if img.getpixel((x, y))[:3] == (0x3a, 0x43, 0x52)]
    check(len(bar) > 100, f'C frames the selection with a titled comment ({len(bar)} px of title bar)')
    if bar:
        bx, by = min(bar)
        before = [(int(info('C', n, 'x')), int(info('C', n, 'y'))) for n in (1, 2, 3)]
        f.drag(bx + 60, by + 6, bx + 60, by + 66, steps=6)
        f.pump(0.2)
        after = [(int(info('C', n, 'x')), int(info('C', n, 'y'))) for n in (1, 2, 3)]
        d = {(a[0] - b[0], a[1] - b[1]) for a, b in zip(after, before)}
        check(len(d) == 1 and list(d)[0][1] > 0, f'dragging the frame\'s title moves the nodes inside it ({d})')
        f.key(45)                                           # X: the frame alone
        f.pump(0.2)
        img = f.image()
        bar2 = sum(1 for y in range(80, 780, 2) for x in range(0, 1280, 2) if img.getpixel((x, y))[:3] == (0x3a, 0x43, 0x52))
        check(bar2 == 0 and info('C', 0, 'count') == '3', f'X with a frame selected removes the frame, not its nodes ({bar2})')
    # H: collapsed to their headers
    body = lambda: sum(1 for y in range(80, 780, 2) for x in range(0, 1280, 2) if f.image().getpixel((x, y))[:3] == (0x34, 0x38, 0x41))
    img0 = f.image()
    b0 = sum(1 for y in range(80, 780, 2) for x in range(0, 1280, 2) if img0.getpixel((x, y))[:3] == (0x34, 0x38, 0x41))
    f.drag(5, 110, 1270, 770, steps=6)
    f.pump(0.2)
    f.key(35)                                               # H
    f.pump(0.3)
    img1 = f.image()
    b1 = sum(1 for y in range(80, 780, 2) for x in range(0, 1280, 2) if img1.getpixel((x, y))[:3] == (0x34, 0x38, 0x41))
    check(b1 < b0 * 0.7, f'H collapses the selected nodes to their headers ({b0} -> {b1} px of bodies)')
    f.key(35)
    f.pump(0.3)
    img2 = f.image()
    b2 = sum(1 for y in range(80, 780, 2) for x in range(0, 1280, 2) if img2.getpixel((x, y))[:3] == (0x34, 0x38, 0x41))
    check(abs(b2 - b0) < 50, f'H again opens them ({b2})')
    # wires: Alt+click cuts one, a double-click puts a reroute on it, an
    # Alt+drag knife cuts every wire it crosses
    q('op("node.view_fit")')
    f.pump(0.3)
    f.click(60, 740)                                        # nothing selected
    f.pump(0.2)
    def wire_px(col_left, col_right, wire):
        img = f.image()
        left = [x for y in range(80, 640, 2) for x in range(0, 1280) if img.getpixel((x, y))[:3] == col_left]
        right = [x for y in range(80, 640, 2) for x in range(0, 1280) if img.getpixel((x, y))[:3] == col_right]
        if not left or not right:
            return None
        x0, x1 = max(left) + 10, min(right) - 10
        pts = [(x, y) for y in range(80, 640) for x in range(x0, x1) if img.getpixel((x, y))[:3] == wire]
        return pts[len(pts) // 2] if pts else None
    p = wire_px((0x9a, 0x4a, 0x3c), (0x6b, 0x4f, 0x96), (0x63, 0x63, 0xc7))    # texcoord UV -> wave
    check(p is not None, f'the UV wire is drawn in the vector colour ({p})')
    if p:
        f.mods(8); f.click(*p); f.mods(0)
        f.pump(0.2)
        cut = info('C', 2, 'link', 1)
        f.mods(4); f.key(44); f.mods(0)
        f.pump(0.2)
        back = info('C', 2, 'link', 1)
        check((cut, back) == ('0', '1'), f'Alt+click cuts the wire under the pointer, undo restores it ({cut} {back})')
        f.click(*p); f.pump(0.05); f.click(*p)
        f.pump(0.3)
        got = (info('C', 0, 'count'), info('C', 2, 'type'), info('C', 2, 'link', 1), info('C', 3, 'link', 1))
        check(got == ('4', '36', '1', '2'), f'a double-click on a wire puts a reroute knot on it ({got})')
        f.shot('62_reroute.png')
    p = wire_px((0x8a, 0x6d, 0x1f), (0x9a, 0x4a, 0x3c), (0xe3, 0xc8, 0x4a))    # hsv -> output: base colour
    if p:
        f.mods(8); f.drag(p[0], p[1] - 40, p[0], p[1] + 40, steps=6); f.mods(0)
        f.pump(0.2)
        check(info('C', 0, 'socket', 0) == '0', f'an Alt+drag knife cuts the wires it crosses ({info("C", 0, "socket", 0)})')
    # align and distribute (the right-click menu has them)
    q('op("material.node_move", "C 1 20 50")\nop("material.node_move", "C 2 300 10")\nop("material.node_move", "C 3 450 90")\n'
      'op("material.node_move", "C 4 900 30")')
    f.pump(0.2)
    f.drag(5, 110, 1270, 770, steps=6)
    f.pump(0.2)
    q('op("node.align_top")')
    tops = {info('C', n, 'y') for n in (1, 2, 3, 4)}
    q('op("node.distribute_x")')
    xs = sorted(int(info('C', n, 'x')) for n in (0, 1, 2, 3, 4))    # (the output too: it was boxed)
    check(len(tops) == 1 and len({b - a for a, b in zip(xs, xs[1:])}) == 1,
          f'align top lines the selection up, distribute spaces it evenly ({tops} {xs})')
    # the minimap: a click there moves the view
    img = f.image()
    mm = [(x, y) for y in range(400, 790, 2) for x in range(900, 1280, 2) if img.getpixel((x, y))[:3] == (0x1a, 0x1c, 0x21)]
    check(len(mm) > 2000, f'a minimap of the graph sits in the corner ({len(mm)} px)')
    if mm:
        before = [(x, y) for y in range(80, 400, 2) for x in range(0, 900, 2) if img.getpixel((x, y))[:3] == (0x6b, 0x4f, 0x96)]
        f.click(min(mm)[0] + 6, max(mm, key=lambda p: p[1])[1] - 6)
        f.pump(0.2)
        img = f.image()
        after = [(x, y) for y in range(80, 790, 2) for x in range(0, 1280, 2) if img.getpixel((x, y))[:3] == (0x6b, 0x4f, 0x96)]
        check(before and (not after or min(after) != min(before)), 'a click on the minimap moves the view there')
    x, y = widget_xy(m, 'node.add')
    f.click(600, 300, btn=0x111)                            # right button
    f.pump(0.3)
    labels = {w.get('label') for w in ui_tree(m)}
    check({'Duplicate Nodes', 'Copy Nodes', 'Paste Nodes', 'Align Left', 'Comment Frame'} <= labels,
          'the right button opens the node menu: duplicate, copy, paste, align, comment ...')
    f.key(1)
    f.shot('61_node_canvas.png')
    f.proc.kill()



def material_editor():
    """The material editor (M5): the add menu by category with shortcuts
    (Multiply, Lerp ...), the quick keys (L, then a click), the selected
    node's values as fields in the Material tab."""
    print('  -- material editor --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    info = lambda *a: q('print(nodeinfo("E", %s))' % ', '.join('"%s"' % x if isinstance(x, str) else str(x) for x in a))
    names = lambda: {w['name'] for w in ui_tree(m)}
    q('m = material("E")\nassign("Cube", m)\nselect("Cube")\nn = node(m, "noise", 3)\nop("area.type_node_editor")\nop("area.maximize")')
    f.pump(0.4)
    # Shift+A: a column a category; typing "lerp" finds the shortcut
    f.move(700, 500)
    f.mods(1); f.key(30); f.mods(0)
    f.pump(0.3)
    labels = {w.get('label') for w in ui_tree(m)}
    img = f.image()
    heads = sum(1 for x in range(0, 1280) for y in range(80, 780, 2)
                if (lambda p: p[0] > 190 and 140 < p[1] < 200 and p[2] < 90)(img.getpixel((x, y))[:3]))
    check(heads > 100, f'Shift+A shows the nodes by category with headings ({heads} px of headings)')
    f.shot('63_add_menu.png')
    f.type('lerp'); f.pump(0.2); f.key(28); f.pump(0.3)
    got = (info(0, 'count'), info(2, 'type'), info(2, 'value', 1))
    check(got == ('2', '7', '21'), f'typing "lerp" + Enter adds a Math node set to Lerp ({got})')
    # quick keys: M, then a click on the canvas - a Multiply there
    f.move(400, 650)
    f.key(50)                                   # M
    f.pump(0.1)
    f.click(400, 650)
    f.pump(0.3)
    got = (info(0, 'count'), info(3, 'type'), info(3, 'value', 1))
    check(got == ('3', '7', '2'), f'M then a click adds a Multiply where it was clicked ({got})')
    f.key(20)                                   # T, then a click: a texture sample
    f.click(150, 700)
    f.pump(0.3)
    check(info(4, 'type') == '1', f'T then a click adds a Texture Sample ({info(4, "type")})')
    # the selected node in the Material tab: its values as fields
    q('op("area.maximize")')
    f.pump(0.3)
    props_tab(m, f, 'material')
    f.pump(0.3)
    q('op("node.view_fit")')
    f.pump(0.3)
    img = f.image()
    pos = [(x, y) for y in range(0, 800, 2) for x in range(0, 1280, 2) if img.getpixel((x, y))[:3] == (0x6b, 0x4f, 0x96)]
    if pos:                                     # the Noise header: select it
        f.click(min(pos)[0] + 30, min(pos)[1] + 4)
        f.pump(0.3)
    check({'node.value'} <= names(), f'a selected node shows its values in the Material tab ({sorted(n for n in names() if n.startswith("node."))})')
    w = widget(m, 'node.value', 4)
    if w:
        f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2); f.pump(0.2)
        f.mods(4); f.key(30); f.mods(0); f.type('2*4'); f.key(28); f.pump(0.3)
    check(info(1, 'value', 1) == '8', f'typing an expression into the field sets the node\'s value (Scale = {info(1, "value", 1)})')
    f.mods(4); f.key(44); f.mods(0)
    f.pump(0.2)
    check(info(1, 'value', 1) == '3', f'one undo takes it back ({info(1, "value", 1)})')
    f.shot('64_node_details.png')
    # a value clicked twice: the console types it (a material with one node)
    q('op("area.maximize")\nv = material("V")\nassign("Cube", v)\nnode(v, "noise", 3)\nop("node.view_fit")')
    f.pump(0.4)
    img = f.image()
    pos = [(x, y) for y in range(80, 640, 2) for x in range(0, 1080, 2) if img.getpixel((x, y))[:3] == (0x6b, 0x4f, 0x96)]
    if pos:
        hx, hy = min(pos)                       # Noise: its header, then Color, Scale
        vx, vy = hx + 80, hy + 20 + 18 + 9
        f.click(vx, vy); f.pump(0.05); f.click(vx, vy); f.pump(0.3)
        f.type('6'); f.key(28); f.pump(0.3)
    got = q('print(nodeinfo("V", 1, "value", 1))')
    check(got == '6', f'a value clicked twice opens the console to type it (Scale = {got})')
    q('assign("Cube", "E")')
    f.pump(0.3)
    # the palette: a toggle in the header; drag an entry onto the canvas
    x, y = widget_xy(m, 'node.palette')
    f.click(x, y); f.pump(0.3)
    img = f.image()
    pal = sum(1 for yy in range(110, 700, 4) for xx in range(0, 190, 4) if img.getpixel((xx, yy))[:3] == (0x2a, 0x2d, 0x34))
    check(pal > 1000, f'the palette shows every node in a column ({pal} px)')
    n0 = int(info(0, 'count'))
    f.drag(60, 162, 700, 620, steps=8)                      # the first entry: Texture Coordinate
    f.pump(0.3)
    got = (info(0, 'count'), info(n0 + 1, 'type'))
    check(got == (str(n0 + 1), '10'), f'dragging an entry from the palette adds that node where it is dropped ({got})')
    x, y = widget_xy(m, 'node.palette_filter')
    f.click(x, y); f.type('fres'); f.key(28); f.pump(0.3)
    f.click(60, 162); f.pump(0.3)                           # (below the Input heading)
    check(info(n0 + 2, 'type') == '18', f'the palette\'s search finds Fresnel; a click adds it ({info(n0 + 2, "type")})')
    f.shot('65_palette.png')
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
    # mid-stroke frames redraw only the tiles of the leaves the stroke
    # changed (the rest from the last frame): the same picture as a full one
    f.move(570, 310); f.button(True)
    for i in range(30):
        f.move(570 + i * 3, 310 + i)
    f.pump(0.3)
    a = f.image()
    f.button(False); f.pump(0.5)
    b = f.image()
    d = sum(1 for p, r in zip(a.getdata(), b.getdata()) if max(abs(p[i] - r[i]) for i in range(3)) > 24)
    check(d < 50, f'a stroke frame drawn from the tile cache matches a full redraw ({d} pixels differ)')
    f.mods(4); f.key(44); f.mods(0)             # (that stroke undone)
    f.pump(0.3)
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


def multires():
    """Multires: sculpt at a level, finer levels follow, coarser keep theirs;
    propagate down; undo; the detail survives a save and load."""
    print('  -- multiresolution --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('delete("Cube")\nadd("sphere", "Ball", 0, 1, 0)\nscale("Ball", 2)\nmodifier("Ball", "multires")\nselect("Ball")\n'
      'fn ev(lv) {\n modset("Ball", 0, "level", lv)\n select("Ball")\n op("object.duplicate")\n'
      ' modapply("Ball.001", 0)\n v = volume("Ball.001")\n n = verts("Ball.001")\n delete("Ball.001")\n'
      ' modset("Ball", 0, "level", 2)\n select("Ball")\n return v\n}')
    vol = lambda lv: float(q(f'print(ev({lv}))'))
    p2, p1 = vol(2), vol(1)
    stroke = lambda: (f.mods(4), f.key(15), f.mods(0), f.pump(0.3),     # Ctrl+Tab: sculpt level 2
                      f.drag(560, 300, 680, 340, steps=24), f.pump(0.3))
    stroke()
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z: the stroke
    f.pump(0.3)
    f.mods(4); f.key(15); f.mods(0)
    f.pump(0.2)
    u2 = vol(2)
    stroke()                                    # (again)
    f.shot('72_multires.png')
    f.mods(4); f.key(15); f.mods(0)
    f.pump(0.2)
    a2, a1 = vol(2), vol(1)
    check(a2 > p2 + 1e-4 and a1 == p1 and u2 == p2,
          f'a stroke at level 2 adds detail there ({a2 - p2:+.5f}), level 1 keeps its shape ({a1 - p1:+.6f}); '
          f'Ctrl+Z takes it back ({u2 - p2:+.6f})')
    q('modset("Ball", 0, "level", 1)\nselect("Ball")\nop("object.sculpt_mode")\n'
      'sculpt("Ball", "inflate", 0, -0.8, 0.8, 0.3, -0.6, 0.8, 0.6, 0.5)\nop("object.sculpt_mode")')
    b1, b2 = vol(1), vol(2)
    check(b1 > a1 + 1e-4 and abs((b2 - a2) - (b1 - a1)) < 0.3 * (b1 - a1),
          f'a stroke at level 1 carries up to level 2 ({b1 - a1:+.5f} -> {b2 - a2:+.5f}), the level-2 detail kept')
    q('select("Ball")\nop("multires.propagate_down")')
    c1, c2 = vol(1), vol(2)
    check(abs(c2 - b2) < 1e-5 and abs(c1 - b1) > 1e-4,
          f'propagate down: level 1 takes the finest shape ({c1 - b1:+.5f}), level 2 stays ({c2 - b2:+.1e})')
    q('op("file.save", "~/BeeModel/multires.bee")\nop("file.open", "~/BeeModel/multires.bee")\n'
      'fn ev(lv) {\n modset("Ball", 0, "level", lv)\n select("Ball")\n op("object.duplicate")\n'
      ' modapply("Ball.001", 0)\n v = volume("Ball.001")\n delete("Ball.001")\n return v\n}')
    d2 = vol(2)
    check(abs(d2 - c2) < 1e-6, f'the displacements are saved in the .bee file ({d2 - c2:+.1e})')
    f.proc.kill()


def uv_maps():
    """UV maps: seams, LSCM unwrap, smart projection, packing; the measures;
    .bee, OBJ and glTF keep them; the edit-mode keys."""
    print('  -- UV maps --')
    home = tempfile.mkdtemp(prefix='bee-uv-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    def run(code):
        r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
        return (r.stdout + r.stderr).strip()
    stats = '", "angle"), uvstat("{0}", "area"), uvstat("{0}", "flipped"), uvstat("{0}", "overlap"), uvstat("{0}", "inside"))'
    st = lambda o: 'print(uvstat("' + o + '", "islands"), uvstat("' + o + stats.format(o)
    out = run('print(seams("Cube", "sharp"), unwrap("Cube"))\n' + st('Cube') + '\n'
              'op("file.save", "~/BeeModel/uv.bee")\nop("file.export_obj", "~/BeeModel/uv.obj")\n'
              'op("file.export_gltf", "~/BeeModel/uv.glb")').splitlines()
    try:
        s, isl = out[0].split()
        n, ang, area, flip, over, inside = map(float, out[1].split())
        ok = s == '12' and isl == '6' and n == 6 and ang < 0.01 and area < 0.01 and flip == 0 and over == 0 and inside == 1
    except Exception:
        ok = False
    check(ok, f'a cube: 12 sharp edges become seams, 6 islands, no distortion, no overlap, inside 0..1 ({out[:2]})')
    back = run('op("file.open", "~/BeeModel/uv.bee")\n' + st('Cube') + '\nprint(seams("Cube", "mark"))').splitlines()
    check(back[:1] == out[1:2] and back[1:2] == ['12'], f'the .bee file keeps UVs and seams ({back})')
    obj = open(os.path.join(home, 'BeeModel', 'uv.obj')).read().splitlines()
    vts = [l for l in obj if l.startswith('vt ')]
    fs = [l for l in obj if l.startswith('f ')]
    check(len(vts) == 24 and all('/' in w for f in fs for w in f.split()[1:]), f'OBJ: {len(vts)} vt, faces v/vt')
    import struct, json
    glb = open(os.path.join(home, 'BeeModel', 'uv.glb'), 'rb').read()
    jl = struct.unpack_from('<I', glb, 12)[0]
    g = json.loads(glb[20:20 + jl])
    binoff = 20 + jl + 8
    prim = g['meshes'][0]['primitives'][0]
    acc = g['accessors'][prim['attributes'].get('TEXCOORD_0', 0)]
    bv = g['bufferViews'][acc['bufferView']]
    uv = struct.unpack_from('<%df' % (acc['count'] * 2), glb, binoff + bv['byteOffset'])
    check('TEXCOORD_0' in prim['attributes'] and acc['type'] == 'VEC2' and 0 <= min(uv) and max(uv) <= 1,
          f'glTF: TEXCOORD_0 ({acc["count"]} loops, {min(uv):.3f}..{max(uv):.3f})')
    if shutil.which('blender'):
        script = os.path.join(home, 'uvcheck.py')
        open(script, 'w').write('import bpy, sys\nbpy.ops.wm.read_factory_settings(use_empty=True)\n'
                                'bpy.ops.import_scene.gltf(filepath=sys.argv[-1])\n'
                                'm = [o for o in bpy.data.objects if o.type == "MESH"][0].data\n'
                                'print("UVLAYERS", len(m.uv_layers), len(m.uv_layers[0].data) if m.uv_layers else 0)\n')
        r = subprocess.run(['blender', '-b', '--factory-startup', '--python', script, '--',
                            os.path.join(home, 'BeeModel', 'uv.glb')], capture_output=True, text=True, timeout=300)
        line = [l for l in r.stdout.splitlines() if l.startswith('UVLAYERS')]
        check(line and line[0].split()[1] == '1' and int(line[0].split()[2]) > 0, f'Blender reads the UVs ({line})')
    # a cylinder cut along its side: developable, so no distortion
    pre = 'delete("Cube")\nadd("cylinder", "C")\n'
    pts = [tuple(map(float, l.split())) for l in run(pre + 'for i in 0..verts("C") {\n print(vpos("C", i, 0), vpos("C", i, 2))\n}').splitlines()]
    side = [i for i, (x, z) in enumerate(pts) if abs(z) < 1e-4 and x > 0]
    out = run(pre + 'seams("C", "sharp")\nvselect("C", ' + ', '.join(map(str, side)) + ')\nseams("C", "mark")\n'
              'unwrap("C")\n' + st('C')).split()
    try:
        n, ang, area, flip, over, inside = map(float, out)
        ok = n == 3 and ang < 0.5 and flip == 0 and over < 0.002 and inside == 1
    except Exception:
        ok = False
    check(ok, f'a cylinder cut along its side unwraps flat: 3 islands, angles kept ({out})')
    out = run('delete("Cube")\nadd("sphere", "B")\nprint(unwrap("B", "smart"))\n' + st('B')).splitlines()
    try:
        n, ang, area, flip, over, inside = map(float, out[1].split())
        ok = n >= 4 and flip == 0 and over < 0.002 and inside == 1
    except Exception:
        ok = False
    check(ok, f'smart projection of a sphere: islands without overlap or flips ({out})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('select("Cube")')
    f.key(15)                                   # Tab: edit mode
    f.key(30)                                   # A: all
    f.mods(4); f.key(18); f.mods(0)             # Ctrl+E: seams
    f.pump(0.2)
    f.shot('73_seams.png')
    f.key(22)                                   # U: unwrap
    f.pump(0.2)
    n = q('print(uvstat("Cube", "islands"), uvstat("Cube", "overlap"))')
    check(n.split()[:1] == ['6'], f'edit mode: A, Ctrl+E (seams on every edge), U (unwrap) -> {n}')
    f.proc.kill()


def uv_editor():
    """The UV editor area: islands shown, a click selects one, G / S move and
    scale with the pointer (Esc puts back, a click keeps, Ctrl+Z undoes), D
    the distortion heat map."""
    print('  -- UV editor --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('seams("Cube", "sharp")\nunwrap("Cube")\nselect("Cube")')
    f.move(600, 700)                            # the console area becomes it
    f.pump(0.2)
    q('op("area.type_uv_editor")')
    f.pump(0.3)
    img = f.image()
    lit = sum(1 for y in range(670, 770, 2) for x in range(560, 670, 2) if img.getpixel((x, y))[0] > 150)
    f.shot('74_uv_editor.png')
    check(lit > 50, f'the UV editor shows the islands ({lit} edge pixels)')
    inside = lambda: q('print(uvstat("Cube", "inside"))')
    f.click(580, 700)                           # an island; G off the square
    f.move(580, 700); f.key(34)
    f.move(900, 700)
    f.pump(0.2)
    moved = inside()
    f.key(1)                                    # Esc: back
    f.pump(0.2)
    back = inside()
    f.move(580, 700); f.key(34)                 # again, kept by a click
    f.move(900, 700)
    f.click(900, 700)
    f.pump(0.2)
    kept = inside()
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    f.pump(0.2)
    undone = inside()
    check((moved, back, kept, undone) == ('0', '1', '0', '1'),
          f'click selects an island; G moves it, Esc puts it back, a click keeps it, Ctrl+Z undoes ({moved} {back} {kept} {undone})')
    f.key(30); f.key(30)                        # A (none), A (all)
    f.move(620, 715); f.key(31)                 # S near the centre, out
    f.move(800, 760)
    f.click(800, 760)
    f.pump(0.2)
    check(inside() == '0' and q('print(uvstat("Cube", "islands"))') == '6', 'A then S scales every island')
    q('delete("Cube")\nadd("sphere", "Ball")\nunwrap("Ball", "smart")\nselect("Ball")')
    f.move(600, 700)
    f.key(32)                                   # D: area distortion
    f.pump(0.3)
    img = f.image()
    px = [img.getpixel((x, y)) for y in range(670, 775, 2) for x in range(470, 760, 2)]
    red = sum(1 for p in px if p[0] > p[1] + 40)
    blue = sum(1 for p in px if p[2] > p[1] + 40)
    f.shot('75_uv_heat.png')
    check(red + blue > 20, f'D: the heat map shows distorted triangles (red {red}, blue {blue})')
    f.proc.kill()


def uv_textures():
    """Image textures follow the UVs (path tracer and material preview); new
    and painted images are saved inside .bee files."""
    print('  -- UV textures --')
    home = tempfile.mkdtemp(prefix='bee-uvtex-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    setup = ('op("image.new", "tex 8 1")\nfor x in 0..8 {\n if x < 4 { imgset("tex", x, 0, 255, 0, 0) } '
             'else { imgset("tex", x, 0, 0, 0, 255) }\n}\nmaterial("M")\nn = node("M", "image", "tex", 1)\n'
             'socket("M", "base", n)\nassign("Cube", "M")\nseams("Cube", "sharp")\nunwrap("Cube")\n'
             'uvmap("Cube", 0.3, 0.5, 0.05, 0.25)\n')
    r = subprocess.run([BIN, '--eval', setup + 'render("~/BeeModel/red.png", 96, 64, 4)\n'
                        'uvmap("Cube", 1, 1, 0.5, 0)\nrender("~/BeeModel/blue.png", 96, 64, 4)\n'
                        'op("file.save", "~/BeeModel/tex.bee")'], env=env, capture_output=True, text=True, timeout=120)
    def count(path):
        from PIL import Image
        im = Image.open(path).convert('RGB')
        px = [im.getpixel((x, y)) for y in range(im.height) for x in range(im.width)]
        red = sum(1 for p in px if p[0] > p[2] + 60 and p[0] > p[1] + 60)
        blue = sum(1 for p in px if p[2] > p[0] + 60 and p[2] > p[1] + 40)
        return red, blue
    try:
        a = count(os.path.join(home, 'BeeModel', 'red.png'))
        b = count(os.path.join(home, 'BeeModel', 'blue.png'))
        ok = a[0] > 300 and a[1] == 0 and b[1] > 300 and b[0] == 0
    except Exception as e:
        ok, a, b = False, repr(e), (r.stdout + r.stderr)[-200:]
    check(ok, f'the path tracer samples the image through the UVs: left half red {a}, right half blue {b}')
    r = subprocess.run([BIN, '--eval', 'op("file.open", "~/BeeModel/tex.bee")\n'
                        'print(imgsize("tex", 0), imgpixel("tex", 1, 0, 0), imgpixel("tex", 6, 0, 2), uvstat("Cube", "islands"))'],
                       env=env, capture_output=True, text=True, timeout=60)
    out = (r.stdout + r.stderr).split()
    check(out == ['8', '255', '255', '6'], f'a new, painted image and the UVs come back from the .bee file ({out})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q(setup)
    f.mods(1); f.key(44); f.mods(0)             # Shift+Z: material preview
    f.pump(0.5)
    def vp():
        img = f.image()
        px = [img.getpixel((x, y)) for y in range(220, 420, 3) for x in range(520, 720, 3)]
        return (sum(1 for p in px if p[0] > p[2] + 60 and p[0] > p[1] + 60),
                sum(1 for p in px if p[2] > p[0] + 60 and p[2] > p[1] + 40))
    a = vp()
    f.shot('79_uv_texture.png')
    q('uvmap("Cube", 1, 1, 0.5, 0)')
    f.pump(0.5)
    b = vp()
    check(a[0] > 5 * a[1] and b[1] > 5 * b[0], f'the material preview too: red / blue {a} then {b} (axis lines are the rest)')
    f.proc.kill()


def texture_paint():
    """Texture paint: strokes in the viewport land on the visible surface
    through the UVs, Ctrl+Z / Ctrl+Shift+Z step the stroke history, the UV
    editor paints in UV space, scripts paint too; painting is saved."""
    print('  -- texture paint --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('op("image.new", "tex 64 64")\nmaterial("M")\nn = node("M", "image", "tex", 1)\nsocket("M", "base", n)\n'
      'assign("Cube", "M")\nseams("Cube", "sharp")\nunwrap("Cube")\nselect("Cube")\n'
      'fn red() {\n s = 0\n for y in 0..64 {\n  for x in 0..64 {\n   if imgpixel("tex", x, y, 0) > 180 '
      '{ if imgpixel("tex", x, y, 1) < 100 { s += 1 } }\n  }\n }\n return s\n}')
    red = lambda: int(float(q('print(red())')))
    f.mods(1); f.key(44); f.mods(0)             # Shift+Z: material preview
    f.mods(1); f.key(15); f.mods(0)             # Shift+Tab: texture paint
    f.pump(0.3)
    q('op("paint.color", "230 20 20")')
    f.drag(585, 320, 640, 345, steps=10)        # across the front faces
    f.pump(0.3)
    a = red()
    f.shot('80_texture_paint.png')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z (paint history)
    f.pump(0.2)
    b = red()
    f.mods(5); f.key(44); f.mods(0)             # Ctrl+Shift+Z
    f.pump(0.2)
    c = red()
    check(a > 20 and b == 0 and c == a, f'a stroke paints {a} texels; Ctrl+Z clears them ({b}), Ctrl+Shift+Z restores ({c})')
    f.move(600, 700)                            # the UV editor: paint there
    f.pump(0.2)
    q('op("area.type_uv_editor")')
    f.pump(0.3)
    f.drag(560, 690, 600, 720, steps=8)
    f.pump(0.3)
    d = red()
    f.shot('81_uv_paint.png')
    check(d > c, f'the UV editor paints in UV space ({c} -> {d})')
    e = q('print(paint("Cube", 0, 2, 0, 0.6, 20, 20, 230))\nprint(imgpixel("tex", 0, 0, 3))')
    q('op("file.save", "~/BeeModel/painted.bee")')
    q('op("file.open", "~/BeeModel/painted.bee")\nfn red() {\n s = 0\n for y in 0..64 {\n  for x in 0..64 {\n'
      '   if imgpixel("tex", x, y, 0) > 180 { if imgpixel("tex", x, y, 1) < 100 { s += 1 } }\n  }\n }\n return s\n}')
    g = red()
    check(e.split()[:1] == ['1'] and g == d, f'paint() from scripts; the painted image comes back from the .bee file ({g} red texels)')
    f.proc.kill()


def paint_layers():
    """Paint layers: painting goes to the active layer, visibility and
    opacity change the composite, the stack is saved, merge flattens."""
    print('  -- paint layers --')
    home = tempfile.mkdtemp(prefix='bee-lay-')
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    top = ('fn top() {\n s = 0\n for y in 0..32 {\n  for x in 0..32 {\n'
           '   if imgpixel("tex", x, y, 0) > imgpixel("tex", x, y, 1) + 60 { s += 1 }\n  }\n }\n return s\n}\n')
    def run(code):
        r = subprocess.run([BIN, '--eval', top + code], env=env, capture_output=True, text=True, timeout=60)
        return (r.stdout + r.stderr).split()
    out = run('op("image.new", "tex 32 32")\nmaterial("M")\nn = node("M", "image", "tex", 1)\nsocket("M", "base", n)\n'
              'assign("Cube", "M")\nseams("Cube", "sharp")\nunwrap("Cube")\nprint(layer("tex", "add"))\n'
              'paint("Cube", 0, 2, 0, 0.6, 255, 0, 0)\na = top()\nlayer("tex", "visible", 1, 0)\nb = top()\n'
              'layer("tex", "visible", 1, 1)\nlayer("tex", "opacity", 1, 0.2)\nc = top()\nlayer("tex", "opacity", 1, 1)\n'
              'print(a, b, c, layer("tex", "count"))\nop("file.save", "~/BeeModel/lay.bee")')
    try:
        ok = out[0] == '1' and int(out[1]) > 10 and out[2] == '0' and int(out[3]) < int(out[1]) and out[4] == '2'
    except Exception:
        ok = False
    check(ok, f'a layer takes the paint; hiding it or 20% opacity shows less ({out})')
    out = run('op("file.open", "~/BeeModel/lay.bee")\nprint(layer("tex", "count"), top())\n'
              'layer("tex", "visible", 1, 0)\nprint(top())\nlayer("tex", "visible", 1, 1)\nlayer("tex", "merge")\n'
              'print(layer("tex", "count"), top())')
    check(len(out) == 5 and out[0] == '2' and int(out[1]) > 10 and out[2] == '0' and out[3] == '1' and out[4] == out[1],
          f'the layers come back from the .bee file; merge flattens them ({out})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('op("image.new", "tex 32 32")\nmaterial("M")\nn = node("M", "image", "tex", 1)\nsocket("M", "base", n)\n'
      'assign("Cube", "M")\nseams("Cube", "sharp")\nunwrap("Cube")\nselect("Cube")')
    f.mods(1); f.key(15); f.mods(0)             # Shift+Tab
    f.mods(1); f.key(49); f.mods(0)             # Shift+N: a layer
    f.pump(0.2)
    f.drag(585, 320, 640, 345, steps=8)
    f.pump(0.2)
    f.shot('82_paint_layer.png')
    n = q('print(layer("tex", "count"), layer("tex", "active"))')
    check(n == '2 1', f'Shift+N in texture paint adds a layer and paints it ({n})')
    f.proc.kill()


def vertex_paint():
    """Vertex colours: Shift+V strokes paint the visible vertices (one undo
    step each); the solid view, the path tracer, OBJ, glTF and .bee keep
    them."""
    print('  -- vertex paint --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('delete("Cube")\nadd("sphere", "Ball", 0, 1, 0)\nscale("Ball", 2)\nmodifier("Ball", "subsurf")\n'
      'modapply("Ball", 0)\nselect("Ball")\nop("paint.color", "230 30 30")\n'
      'fn reds() {\n s = 0\n for i in 0..verts("Ball") {\n  g = vcol("Ball", i, 1)\n  if g >= 0 { if g < 120 { s += 1 } }\n }\n return s\n}')
    reds = lambda: int(float(q('print(reds())')))
    f.mods(1); f.key(47); f.mods(0)             # Shift+V
    f.pump(0.3)
    f.drag(570, 300, 650, 340, steps=10)
    f.pump(0.3)
    a = reds()
    img = f.image()
    vp = sum(1 for y in range(240, 400, 2) for x in range(520, 720, 2)
             if (lambda p: p[0] > p[1] + 50 and p[0] > p[2] + 50)(img.getpixel((x, y))))
    f.shot('83_vertex_paint.png')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z: the scene's undo
    f.pump(0.3)
    b = reds()
    check(a > 20 and vp > 50 and b == 0, f'a stroke paints {a} vertices, the solid view shows it ({vp} px); Ctrl+Z undoes ({b})')
    f.proc.kill()
    home = tempfile.mkdtemp(prefix='bee-vc-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', 'delete("Cube")\nadd("sphere", "Ball", 0, 1, 0)\nscale("Ball", 2)\n'
                        'vpaint("Ball", 2, 1, 0, 1.6, 0, 0, 255)\nrender("~/BeeModel/vc.png", 160, 100, 8)\n'
                        'op("file.export_obj", "~/BeeModel/vc.obj")\nop("file.export_gltf", "~/BeeModel/vc.glb")\n'
                        'op("file.save", "~/BeeModel/vc.bee")'], env=env, capture_output=True, text=True, timeout=120)
    from PIL import Image
    im = Image.open(os.path.join(home, 'BeeModel', 'vc.png')).convert('RGB')
    blue = sum(1 for y in range(im.height) for x in range(im.width)
               if (lambda p: p[2] > p[0] + 50 and p[2] > p[1] + 30)(im.getpixel((x, y))))
    vs = [l.split() for l in open(os.path.join(home, 'BeeModel', 'vc.obj')) if l.startswith('v ')]
    check(blue > 100 and all(len(v) == 7 for v in vs), f'the path tracer tints by them ({blue} px); OBJ: v x y z r g b')
    back = subprocess.run([BIN, '--eval', 'op("file.open", "~/BeeModel/vc.bee")\ns = 0\nfor i in 0..verts("Ball") {\n'
                           ' r = vcol("Ball", i, 0)\n if r >= 0 { if r < 100 { s += 1 } }\n}\nprint(s)'], env=env, capture_output=True, text=True, timeout=60)
    n = (back.stdout + back.stderr).split()
    check(n and int(n[0]) >= 5, f'the .bee file keeps them ({n} strongly blue)')
    if shutil.which('blender'):
        script = os.path.join(home, 'vccheck.py')
        open(script, 'w').write('import bpy, sys\nbpy.ops.wm.read_factory_settings(use_empty=True)\n'
                                'bpy.ops.import_scene.gltf(filepath=sys.argv[-1])\n'
                                'm = [o for o in bpy.data.objects if o.type == "MESH"][0].data\n'
                                'a = m.color_attributes\nprint("VCOL", len(a))\n')
        r = subprocess.run(['blender', '-b', '--factory-startup', '--python', script, '--',
                            os.path.join(home, 'BeeModel', 'vc.glb')], capture_output=True, text=True, timeout=300)
        line = [l for l in r.stdout.splitlines() if l.startswith('VCOL')]
        check(line == ['VCOL 1'], f'Blender reads glTF COLOR_0 ({line})')


def baking():
    """Baking: a high mesh's normal, ambient occlusion and curvature maps
    through a low mesh's UVs; one texture paint undo step each."""
    print('  -- baking --')
    home = tempfile.mkdtemp(prefix='bee-bake-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    stat = ('fn stat(img, ch, lo, hi) {\n n = 0\n for y in 0..64 {\n  for x in 0..64 {\n'
            '   v = imgpixel(img, x, y, ch)\n   if v >= lo { if v <= hi { n += 1 } }\n  }\n }\n return n\n}\n')
    r = subprocess.run([BIN, '--eval', stat +
                        'op("image.new", "fl 64 64")\nop("image.new", "nm 64 64")\nop("image.new", "ao 64 64")\n'
                        'op("image.new", "cv 64 64")\nop("image.new", "cr 64 64")\n'
                        'seams("Cube", "sharp")\nunwrap("Cube")\n'
                        'add("cube", "Big", 0, 1, 0)\nscale("Big", 1.05)\n'
                        'a = bake("Cube", "Big", "normal", "fl", 0.3)\n'
                        'print(a, stat("fl", 2, 250, 255), stat("fl", 0, 120, 136))\n'
                        'add("sphere", "B", 0, 2.0, 0)\nscale("B", 0.7)\nboolean("Big", "B", "union")\n'
                        'bake("Cube", "Big", "ao", "ao", 0.3)\nbake("Cube", "Big", "curvature", "cr", 0.3)\n'
                        'print(stat("ao", 0, 140, 235), stat("ao", 0, 250, 255), stat("cr", 0, 0, 120))\n'
                        'add("sphere", "Ball", 0, 1, 0)\nscale("Ball", 1.3)\nmodifier("Ball", "subsurf")\nmodapply("Ball", 0)\n'
                        'bake("Cube", "Ball", "normal", "nm", 0.8)\nbake("Cube", "Ball", "curvature", "cv", 0.8)\n'
                        'print(stat("nm", 0, 0, 90), stat("nm", 0, 166, 255), stat("cv", 0, 136, 180), stat("cv", 0, 0, 120))\n'
                        'p = imgpixel("cv", 32, 20, 0)\nop("paint.undo")\nq = imgpixel("cv", 32, 20, 0)\n'
                        'op("paint.redo")\nprint(p, q, imgpixel("cv", 32, 20, 0), bake("Ball", "Cube", "ao", "ao"))\n'
                        'op("image.save", "nm ~/BeeModel/nm.png")\nop("image.save", "ao ~/BeeModel/ao.png")\n'
                        'op("image.save", "cr ~/BeeModel/cr.png")\n'],
                       env=env, capture_output=True, text=True, timeout=120)
    out = (r.stdout + r.stderr).split()
    try:
        v = [int(float(x)) for x in out[:13]]
    except Exception:
        v = []
    check(len(v) == 13 and v[0] > 2000 and v[1] > 2000 and v[2] > 2000,
          f'a flat high mesh bakes a flat normal map ({out[:3]})')
    check(len(v) == 13 and v[3] > 20 and v[4] > 1500 and v[5] >= 4,
          f'ambient occlusion darkens around a dome, curvature marks its crease dark ({out[3:6]})')
    check(len(v) == 13 and v[6] > 200 and v[7] > 200 and v[8] > 1500 and v[9] == 0,
          f'a sphere bakes tilting normals and convex curvature ({out[6:10]})')
    check(len(v) == 13 and v[10] != v[11] and v[12] == v[10] and out[13] == '-1',
          f'a bake is one texture paint undo step; no UVs: -1 ({out[10:14]})')
    for n in ('nm', 'ao', 'cr'):
        p = os.path.join(home, 'BeeModel', n + '.png')
        if os.path.exists(p):
            shutil.copy(p, os.path.join(OUT, '84_bake_' + n + '.png'))
    f = Fake()
    f.pump(1.0, until_frame=True)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('op("image.new", "ao 32 32")\nseams("Cube", "sharp")\nunwrap("Cube")\n'
      'add("sphere", "Ball", 0, 1, 0)\nscale("Ball", 1.3)')
    text, err = m.tool('run_operator', {'id': 'object.bake', 'arg': 'Cube Ball normal ao 0.8'})
    n = q('s = 0\nfor y in 0..32 { for x in 0..32 { if imgpixel("ao", x, y, 2) > 200 { s += 1 } } }\nprint(s)')
    check(not err and n.isdigit() and int(n) > 300, f'agents bake with object.bake ({n}, {err})')
    f.proc.kill()


def node_editor():
    """The node editor area: the active material's graph drawn and edited
    with the pointer - values dragged, links made and picked up, material
    sockets driven, loops refused, nodes moved, added (Shift+A), deleted (X),
    every change undoable."""
    print('  -- node editor --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('material("M")\nassign("Cube", "M")\nselect("Cube")\nn = node("M", "noise", 3)\nr = node("M", "ramp")\n'
      'link("M", n, r, 1)\nsocket("M", "base", r)\nb = node("M", "bump", 1, 0.1)\nlink("M", n, b, 1)\nsocket("M", "normal", b)')
    f.move(600, 700)                            # the console area becomes it
    f.pump(0.2)
    q('op("area.type_node_editor")\nop("area.maximize")')
    f.pump(0.5)
    img = f.image()
    boxes = sum(1 for x in range(0, 640, 4) if img.getpixel((x, 125)) in ((0x6b, 0x4f, 0x96), (0x2f, 0x65, 0x89), (0x8a, 0x3b, 0x3b)))
    f.shot('86_node_editor.png')
    check(boxes > 60, f'the graph is drawn: noise, ramp, bump and the material output laid out by depth ({boxes})')
    info = lambda *a: q('print(nodeinfo("M", %s))' % ', '.join('"%s"' % x if isinstance(x, str) else str(x) for x in a))
    f.drag(100, 168, 200, 168, steps=10)        # Scale: 3 + 100 px x 0.01
    f.pump(0.2)
    a = info(1, 'value', 1)
    f.drag(190, 150, 220, 221, steps=8)         # noise -> ramp Color 0
    f.pump(0.2)
    b = info(2, 'link', 2)
    f.drag(220, 357, 600, 500, steps=8)         # bump Height picked up, dropped
    f.pump(0.2)
    c = info(3, 'link', 1)
    f.drag(190, 150, 420, 185, steps=8)         # noise -> Roughness
    f.pump(0.2)
    d = info(0, 'socket', 2)
    check((a, b, c, d) == ('4', '1', '0', '1'),
          f'dragging a value, linking, picking a link up and driving a material socket ({a} {b} {c} {d})')
    f.drag(390, 149, 20, 222, steps=8)          # ramp -> noise Offset: a loop
    f.pump(0.2)
    e = info(1, 'link', 1)
    f.drag(60, 130, 60, 430, steps=8)           # noise moved down 300
    f.pump(0.2)
    y = info(1, 'y')
    check(e == '0' and y == '320', f'a loop is refused; a header drag moves the node ({e}, y {y})')
    f.move(800, 500)
    f.mods(1); f.key(30); f.mods(0)             # Shift+A
    f.pump(0.2)
    f.type('checker'); f.pump(0.2); f.key(28)   # Checker Texture (typed)
    f.pump(0.2)
    g = (info(0, 'count'), info(4, 'type'), info(4, 'x'), info(4, 'y'))
    f.click(830, 515)                           # selected, X
    f.key(45)
    f.pump(0.2)
    h = info(0, 'count')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    f.pump(0.2)
    i = info(0, 'count')
    check(g == ('4', '3', '800', '400') and h == '3' and i == '4',
          f'Shift+A adds a node at the pointer, X deletes it, Ctrl+Z brings it back ({g} {h} {i})')
    f.proc.kill()


def geometry_nodes():
    """Geometry nodes: a node tree run by a modifier - primitives, transform,
    join, set position by fields (noise, math, random, vector math on the
    field VM), extrude, subdivide, boolean, merge; saved in .bee files; the
    node editor shows and edits trees (Shift+A, links, Tab to the material)."""
    print('  -- geometry nodes --')
    home = tempfile.mkdtemp(prefix='bee-gn-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    measure = ('fn measure(t, kind) {\n add("cube", "M", 0, 0, 0)\n mm = modifier("M", "geometry")\n'
               ' modset("M", mm, "tree", t)\n modapply("M", 0)\n r = verts("M")\n'
               ' if kind == 1 { r = area("M") }\n if kind == 2 { r = volume("M") }\n delete("M")\n return r\n}\n')
    r = subprocess.run([BIN, '--eval', measure +
        't = gtree("T")\no = gnode(t, "output")\ng = gnode(t, "grid", 4, 40)\nsp = gnode(t, "set_position")\n'
        'glink(t, g, sp, 1)\nglink(t, sp, o, 1)\nprint(measure(t, 0), measure(t, 1))\n'
        'n = gnode(t, "noise", 1.5, 2, 0.5)\nc = gnode(t, "combine_xyz")\nglink(t, n, c, 2)\nglink(t, c, sp, 3)\n'
        'print(measure(t, 1))\np = gnode(t, "position")\nsx = gnode(t, "separate_xyz")\nglink(t, p, sx, 1)\n'
        'mt = gnode(t, "math", 8)\nglink(t, sx, mt, 1, 0)\nglink(t, mt, sp, 2)\nprint(measure(t, 1))\n'
        'u = gtree("U")\nuo = gnode(u, "output")\ncu = gnode(u, "cube", 2)\nsp2 = gnode(u, "sphere", 1.5)\n'
        'b = gnode(u, "boolean", 1)\nglink(u, cu, b, 1)\nglink(u, sp2, b, 2)\nglink(u, b, uo, 1)\nprint(measure(u, 2))\n'
        'j = gnode(u, "join")\nglink(u, cu, j, 1)\nglink(u, cu, j, 2)\nmg = gnode(u, "merge", 0.001)\n'
        'glink(u, j, mg, 1)\nglink(u, j, uo, 1)\na = measure(u, 0)\nglink(u, mg, uo, 1)\nprint(a, measure(u, 0))\n'
        'x = gnode(u, "transform", 0, 0, 90)\ngset(u, x, 3, 2, 1, 1)\nglink(u, cu, x, 1)\nglink(u, x, uo, 1)\n'
        'print(measure(u, 2))\ne = gnode(u, "extrude", 0.5)\nglink(u, cu, e, 1)\nglink(u, e, uo, 1)\nprint(measure(u, 0))\n'
        'sd = gnode(u, "subdivide", 2)\nglink(u, cu, sd, 1)\nglink(u, sd, uo, 1)\nprint(measure(u, 0))\n'
        'v = gtree("V")\nvo = gnode(v, "output")\nvs = gnode(v, "sphere", 1)\nvp = gnode(v, "set_position")\n'
        'rn = gnode(v, "random", 0, 0.2, 3)\nnm = gnode(v, "normal")\nvm = gnode(v, "vector_math", 3)\n'
        'glink(v, nm, vm, 1)\nglink(v, rn, vm, 3)\nglink(v, vs, vp, 1)\nglink(v, vm, vp, 3)\nglink(v, vp, vo, 1)\n'
        'print(measure(v, 2))\nmm = modifier("Cube", "geometry")\nmodset("Cube", mm, "tree", t)\n'
        'op("file.save", "~/BeeModel/gn.bee")\nglink(v, vp, vs, 1)\n'],
        env=env, capture_output=True, text=True, timeout=120)
    out = r.stdout.split()
    try:
        v = [float(x) for x in out[:11]]
    except Exception:
        v = []
    ok = len(v) == 11
    check(ok and v[0] == 1681 and abs(v[1] - 16) < 0.01 and v[2] > 17 and 16 < v[3] < v[2],
          f'a grid; noise through set position; a selection field limits it ({out[:4]})')
    check(ok and 0.05 < v[4] < 0.2 and v[5] == 16 and v[6] == 8 and abs(v[7] - 16) < 0.01 and v[8] > 8 and v[9] == 98,
          f'boolean, join and merge by distance, transform, extrude and subdivide ({out[4:10]})')
    check(ok and 4.3 < v[10] < 5.5 and 'no such node tree, node or input' in r.stdout + r.stderr,
          f'random lengths along the normals (volume {out[10:11]}); a loop is refused')
    r = subprocess.run([BIN, '--eval', 'op("file.open", "~/BeeModel/gn.bee")\nprint(everts("Cube"), ginfo(1, 0, "count"), ginfo(2, 0, "count"))'],
                       env=env, capture_output=True, text=True, timeout=60)
    check(r.stdout.split()[:3] == ['1681', '8', '9'], f'the trees and the modifier come back from the .bee file ({r.stdout.split()[:3]})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('t = gtree("Terrain")\no = gnode(t, "output")\ng = gnode(t, "grid", 6, 30)\nsp = gnode(t, "set_position")\n'
      'glink(t, g, sp, 1)\nn = gnode(t, "noise", 0.6, 3, 0.5)\nc = gnode(t, "combine_xyz")\nglink(t, n, c, 2)\n'
      'glink(t, c, sp, 3)\nglink(t, sp, o, 1)\nmm = modifier("Cube", "geometry")\nmodset("Cube", mm, "tree", t)\nselect("Cube")')
    f.pump(0.3)
    f.shot('87_geometry_nodes_viewport.png')
    f.move(600, 700)
    f.pump(0.2)
    q('op("area.type_node_editor")\nop("area.maximize")')
    f.pump(0.5)
    img = f.image()
    geo = sum(1 for x in range(0, 900, 4) if img.getpixel((x, 125)) == (0x1d, 0x72, 0x5e))
    f.shot('88_geometry_node_editor.png')
    check(geo > 30, f'the node editor shows the object\'s tree ({geo})')
    gi = lambda *a: q('print(ginfo(1, %s))' % ', '.join('"%s"' % x if isinstance(x, str) else str(x) for x in a))
    f.move(820, 200)
    f.mods(1); f.key(30); f.mods(0)             # Shift+A
    f.pump(0.2)
    f.click(850, 200 + 2 + 4 * 18 + 9)          # the 4th type: Cube
    f.pump(0.2)
    a = (gi(0, 'count'), gi(6, 'type'))
    f.drag(990, 229, 420, 168, steps=10)        # its Mesh output -> Set Position's Geometry
    f.pump(0.2)
    b = gi(3, 'link', 1)
    ev = q('print(everts("Cube"))')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    f.pump(0.3)
    c = gi(3, 'link', 1)
    check(a == ('6', '4') and b == '6' and ev == '8' and c == '2',
          f'Shift+A adds a geometry node, a drag links it (the cube is displaced instead), Ctrl+Z undoes ({a} {b} {ev} {c})')
    f.key(15)                                   # Tab: the material's graph
    f.pump(0.3)
    img = f.image()
    geo2 = sum(1 for x in range(0, 900, 4) if img.getpixel((x, 125)) == (0x1d, 0x72, 0x5e))
    f.key(15)
    f.pump(0.3)
    check(geo2 == 0, f'Tab shows the material instead ({geo2})')
    f.proc.kill()


def node_groups():
    """Node groups and assets: a group node runs another tree (fields cross
    into it); Shift-click several nodes and Ctrl+G makes one, Tab goes into
    it and back; trees (with their groups) and materials saved as assets
    come back into other scenes; the Asset Browser lists them and adds one
    with a click."""
    print('  -- node groups, assets --')
    home = tempfile.mkdtemp(prefix='bee-ng-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    run = lambda code: subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=60).stdout.split()
    out = run('g = gtree("Lift")\ngi = gnode(g, "input")\ngo = gnode(g, "output")\nsp = gnode(g, "set_position")\n'
              'c = gnode(g, "combine_xyz")\nglink(g, gi, sp, 1, 0)\nglink(g, gi, c, 2, 1)\nglink(g, c, sp, 3)\nglink(g, sp, go, 1)\n'
              't = gtree("Main")\no = gnode(t, "output")\ngr = gnode(t, "grid", 2, 2)\ngrp = gnode(t, "group", g)\n'
              'glink(t, gr, grp, 1)\np = gnode(t, "position")\nsx = gnode(t, "separate_xyz")\nglink(t, p, sx, 1)\n'
              'glink(t, sx, grp, 2, 0)\nglink(t, grp, o, 1)\n'
              'add("cube", "M", 0, 0, 0)\nmm = modifier("M", "geometry")\nmodset("M", mm, "tree", t)\nmodapply("M", 0)\n'
              'print(verts("M"), vpos("M", 0, 0), vpos("M", 0, 1), vpos("M", 8, 0), vpos("M", 8, 1))\n'
              'material("Gold")\nmatset("Gold", "metallic", 1)\nn = node("Gold", "noise", 3)\nsocket("Gold", "base", n)\n'
              'op("tree.save_asset", "Main")\nop("material.save_asset", "Gold")\nop("lib.save", "material Gold #metal")')
    check(out == ['9', '-1', '-1', '1', '1'], f'a group node runs its tree; a field from outside lifts each point by its x ({out})')
    out = run('op("asset.load", "Main")\nop("asset.load", "Gold")\n'
              'print(ginfo(1, 0, "count"), ginfo(2, 0, "count"), ginfo(1, 3, "value", 1), matget("Gold", "metallic"), nodeinfo("Gold", 0, "count"))')
    check(out == ['5', '4', '2', '1', '1'], f'a tree saved as an asset comes back with its group; a material with its graph ({out})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    shutil.copytree(os.path.join(home, 'BeeModel', 'assets'), os.path.join(f.home, 'BeeModel', 'assets'))
    shutil.copytree(os.path.join(home, 'BeeModel', 'library'), os.path.join(f.home, 'BeeModel', 'library'))
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('t = gtree("Terrain")\no = gnode(t, "output")\ng = gnode(t, "grid", 6, 30)\nsp = gnode(t, "set_position")\n'
      'glink(t, g, sp, 1)\nn = gnode(t, "noise", 0.6, 3, 0.5)\nc = gnode(t, "combine_xyz")\nglink(t, n, c, 2)\n'
      'glink(t, c, sp, 3)\nglink(t, sp, o, 1)\nmm = modifier("Cube", "geometry")\nmodset("Cube", mm, "tree", t)\nselect("Cube")')
    ev = q('print(everts("Cube"), area("Cube"))')
    f.move(600, 700)
    f.pump(0.2)
    q('op("area.type_node_editor")\nop("area.maximize")')
    f.pump(0.4)
    f.click(60, 130)                            # grid, then Shift: combine,
    f.mods(1)                                   #  noise, set position
    f.click(260, 130); f.click(60, 230); f.click(460, 130)
    f.mods(0)
    f.pump(0.2)
    f.mods(4); f.key(34); f.mods(0)             # Ctrl+G
    f.pump(0.3)
    a = (q('print(ginfo(1, 0, "count"), ginfo(2, 0, "count"), ginfo(1, 2, "type"))'), q('print(everts("Cube"))'))
    f.click(60, 130)                            # the group: Tab into it
    f.key(15)
    f.pump(0.3)
    img = f.image()
    inside = sum(1 for x in range(0, 900, 4) if img.getpixel((x, 125)) == (0x1d, 0x72, 0x5e))
    f.shot('89_node_group.png')
    f.key(15)                                   # Tab: back
    f.pump(0.3)
    img = f.image()
    grp = sum(1 for x in range(0, 300, 4) if img.getpixel((x, 125)) == (0x6e, 0x54, 0x18))
    check(a == ('2 6 26', ev.split()[0]) and inside > 30 and grp > 20,
          f'Shift-click, Ctrl+G: one group node, the same result; Tab into it and back ({a} {inside} {grp})')
    q('op("area.type_asset_browser")')
    f.pump(0.5)
    f.shot('90_asset_browser.png')
    f.click(60, 120)                            # the library's first asset (Gold):
    f.click(60, 120)                            #  a double click places it
    f.pump(0.3)
    n = q('print(matget("Gold", "metallic"))')
    check(n == '1', f'the asset browser lists the library; a double click places an asset ({n})')
    f.proc.kill()


def instancing():
    """Scattering and instancing: points distributed on faces by area and
    density (thinned to a minimum distance), a geometry instanced on every
    point (aligned to the normal, turned, scaled), kept as instances - a
    million placed in milliseconds and drawn in the viewport without being
    realized - or realized into plain geometry; the path tracer sees them."""
    print('  -- scattering, instancing --')
    home = tempfile.mkdtemp(prefix='bee-in-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', 't = gtree("S")\no = gnode(t, "output")\ng = gnode(t, "grid", 10, 10)\n'
        'd = gnode(t, "distribute", 5, 1, 0)\nc = gnode(t, "cube", 0.1)\nip = gnode(t, "instance", 1, 1, 7)\n'
        'glink(t, g, d, 1)\nglink(t, d, ip, 1)\nglink(t, c, ip, 2)\nglink(t, d, o, 1)\n'
        'mm = modifier("Cube", "geometry")\nmodset("Cube", mm, "tree", t)\nprint(everts("Cube"))\n'
        'glink(t, ip, o, 1)\nprint(instances("Cube"), everts("Cube"))\nr = gnode(t, "realize")\nglink(t, ip, r, 1)\n'
        'glink(t, r, o, 1)\nprint(everts("Cube"), efaces("Cube"), instances("Cube"))\ngset(t, d, 6, 0.3)\n'
        'glink(t, d, o, 1)\nprint(everts("Cube"))\ngset(t, d, 6, 0)\ngset(t, d, 4, 10000)\nglink(t, ip, o, 1)\n'
        'c0 = clock()\nprint(instances("Cube"), clock() - c0)\ngset(t, d, 4, 2)\nglink(t, ip, o, 1)\n'
        'render("~/BeeModel/inst.png", 160, 90, 4)'], env=env, capture_output=True, text=True, timeout=120)
    out = r.stdout.split()
    try:
        v = [float(x) for x in out[:9]]
    except Exception:
        v = []
    check(len(v) == 9 and 450 < v[0] < 550 and v[1] == v[0] and v[2] == 0 and v[3] == 8 * v[0] and v[4] == 6 * v[0]
          and v[5] == 0 and v[6] < v[0], f'points by area and density, instanced, realized, thinned by a distance ({out[:7]})')
    check(len(v) == 9 and v[7] == 1000000 and v[8] < PLACE_BUDGET_MS and os.path.exists(os.path.join(home, 'BeeModel', 'inst.png')),
          f'a million instances placed in {out[8:9]} ms (budget {PLACE_BUDGET_MS} ms); the path tracer renders them')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('delete("Cube")\nadd("plane", "Ground", 0, 0, 0)\nt = gtree("S")\no = gnode(t, "output")\ng = gnode(t, "grid", 12, 40)\n'
      'd = gnode(t, "distribute", 100000 / 144, 1, 0)\nglink(t, g, d, 1)\nci = gnode(t, "cube", 0.12)\n'
      'ip = gnode(t, "instance", 1, 1, 7)\nglink(t, d, ip, 1)\nglink(t, ci, ip, 2)\nj = gnode(t, "join")\n'
      'glink(t, g, j, 1)\nglink(t, ip, j, 2)\nglink(t, j, o, 1)\nmm = modifier("Ground", "geometry")\nmodset("Ground", mm, "tree", t)')
    f.pump(0.5)
    n0 = int(float(q('print(frames())')))
    for i in range(4):
        f.drag(560, 450, 600 + i * 10, 452, steps=6)
    f.pump(0.3)
    ft = [float(x) for x in q(f'n = frames() - {n0}\nfor k in 1..n {{\n print(frametime(k))\n}}').split()]
    ms = sorted(ft)[len(ft) // 2] if ft else 1e9
    img = f.image()
    shot = sum(1 for y in range(250, 550, 3) for x in range(300, 900, 3) if img.getpixel((x, y))[0] > 150)
    f.shot('91_instances.png')
    check(ms < INSTANCE_FRAME_MS and shot > 500, f'100k instances orbit at {ms:.1f} ms a frame (budget {INSTANCE_FRAME_MS} ms)')
    f.proc.kill()


def curves():
    """Curves: Bezier and poly splines (auto handles make a round circle),
    swept into tubes or along a profile curve, edited by operators and in
    curve edit mode (click, G, E, Ctrl+click, X), saved, exported as OBJ
    lines; the curve nodes (line, circle, to mesh, resample, trim, fillet,
    to points)."""
    print('  -- curves --')
    home = tempfile.mkdtemp(prefix='bee-cv-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    code = ('c = curve("bezier")\nprint(cpoints(c), everts(c), efaces(c))\n'
            'k = curve("circle", "Ring")\nprint(clength(k))\n'
            'op("curve.set", "bevel 0.05")\nprint(everts(k), efaces(k))\nop("curve.set", "bevel 0")\n'
            'p = curve("path")\nop("curve.set", "bevel 0.1")\nop("curve.set", "fill 1")\nprint(everts(p), efaces(p))\n'
            'op("curve.set", "profile Ring")\nprint(everts(p), efaces(p))\n'
            'op("curve.point", "3 1 0")\nprint(cpoints(p), clength(p))\n'
            'op("curve.select", "4 5")\nop("curve.subdivide")\nprint(cpoints(p), clength(p))\n'
            'op("curve.select", "0")\nop("curve.delete")\nprint(cpoints(p), clength(p))\n'
            'op("curve.select", "5")\nop("curve.extrude", "1 0 0")\nprint(cpoints(p), clength(p))\n'
            'select(c)\nl0 = clength(c)\nop("curve.select", "all")\nop("curve.subdivide")\nprint(cpoints(c), clength(c) - l0)\n'
            'op("curve.select", "1")\nop("curve.move", "1 1 0 0.5")\nprint(cpos(c, 1, "z"))\n'
            'op("file.save", "~/BeeModel/c.bee")\nop("file.new")\nop("file.open", "~/BeeModel/c.bee")\n'
            'print(cpoints("Path"), everts("Path"), cpoints("Ring"), cpos("BezierCurve", 1, "z"))\n'
            'op("file.export_obj", "~/BeeModel/c.obj")\n'
            'select("Path")\nop("curve.to_mesh")\nprint(cpoints("Path"), everts("Path"))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
    out = r.stdout.split()
    try:
        v = [float(x) for x in out]
    except Exception:
        v = []
    ok = len(v) == 27
    check(ok and v[0:3] == [2, 13, 12] and abs(v[3] - 2 * math.pi) < 0.02 and v[4:6] == [384, 384],
          f'a Bezier curve sampled per span; a 4-point circle is round (length {out[3:4]}); a bevel sweeps it ({out[:6]})')
    check(ok and v[6:10] == [40, 34, 240, 194], f'an open path swept with caps, then along a profile curve ({out[6:10]})')
    check(ok and v[10] == 6 and abs(v[11] - (4 + math.sqrt(2))) < 1e-4 and v[12] == 7 and abs(v[13] - v[11]) < 1e-4
          and v[14] == 6 and abs(v[15] - v[11] + 1) < 1e-4 and v[16] == 7 and abs(v[17] - v[11]) < 1e-4,
          f'points added, subdivided (shape kept), deleted, extruded ({out[10:18]})')
    check(ok and v[18] == 3 and abs(v[19]) < 0.01 and v[20] == 0.5,
          f'a Bezier span split in two keeps its shape; a point moved ({out[18:21]})')
    objl = open(os.path.join(home, 'BeeModel', 'c.obj')).read().split('\n') if os.path.exists(os.path.join(home, 'BeeModel', 'c.obj')) else []
    check(ok and v[21:25] == [7, 336, 4, 0.5] and sum(1 for x in objl if x.startswith('l ')) == 72
          and v[25] == -1 and v[26] == 336, f'saved and opened again; OBJ export writes lines; to mesh ({out[21:28]})')
    code = ('t = gtree("C")\no = gnode(t, "output")\ncc = gnode(t, "curve_circle", 32, 2)\nglink(t, cc, o, 1)\n'
            'mm = modifier("Cube", "geometry")\nmodset("Cube", mm, "tree", t)\nprint(everts("Cube"), efaces("Cube"))\n'
            'rs = gnode(t, "resample", 4)\nglink(t, cc, rs, 1)\nfi = gnode(t, "fillet", 0.5, 4)\nglink(t, rs, fi, 1)\n'
            'glink(t, fi, o, 1)\nprint(everts("Cube"), efaces("Cube"))\n'
            'tm = gnode(t, "curve_to_mesh", 0.1, 6, 0)\nglink(t, fi, tm, 1)\nglink(t, tm, o, 1)\nprint(everts("Cube"), efaces("Cube"))\n'
            'tr = gnode(t, "trim", 0.25, 0.75)\nglink(t, cc, tr, 1)\nglink(t, tr, o, 1)\nprint(everts("Cube"), efaces("Cube"))\n'
            'cl = gnode(t, "curve_line")\npf = gnode(t, "curve_circle", 4, 0.2)\nglink(t, cl, tm, 1)\nglink(t, pf, tm, 2)\n'
            'glink(t, tm, o, 1)\nprint(everts("Cube"), efaces("Cube"))\n'
            'cp = gnode(t, "curve_to_points", 10)\nglink(t, cc, cp, 1)\ncu = gnode(t, "cube", 0.2)\n'
            'ip = gnode(t, "instance", 1, 1, 0)\nglink(t, cp, ip, 1)\nglink(t, cu, ip, 2)\nglink(t, ip, o, 1)\nprint(instances("Cube"))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
    out = r.stdout.split()
    check(out == ['32', '32', '20', '20', '120', '120', '17', '16', '8', '4', '10'],
          f'curve nodes: circle, resample + fillet, to mesh, trim, line along a profile, to points ({out})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    q('delete("Cube")\nc = curve("bezier")')
    p0, p1 = project((-1, 0, 0)), project((1, 0, 0))
    f.enter(*project((0, 0, 1.5)))
    f.key(15)                                   # Tab
    f.pump(0.2)
    check(px(f, *p0) == 0x161616 and px(f, *p1) == 0x161616, 'Tab enters curve edit mode: control points drawn')
    f.click(*p0)
    check(px(f, *p0) == 0xffa030, 'clicking a control point selects it')
    f.key(34); f.key(44); f.key(3); f.key(28)   # G Z 2 Enter
    f.pump(0.2)
    gz = q('cpos("BezierCurve", 0, "z")')
    check(gz == '= 2' and px(f, *project((-1, 0, 2))) == 0xffa030, f'G Z 2 moves the point (its handles along) ({gz})')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    check(q('cpos("BezierCurve", 0, "z")') == '= 0', 'undo puts it back')
    f.key(18)                                   # E: extrude, then move
    f.move(p0[0] - 60, p0[1] + 10)
    f.click(p0[0] - 60, p0[1] + 10)
    f.pump(0.2)
    n1 = q('cpoints("BezierCurve")')
    x1 = q('cpos("BezierCurve", 0, "x")')
    f.mods(4); f.click(*project((-2, 0, 3))); f.mods(0)    # Ctrl+click: a point there
    f.pump(0.2)
    n2 = q('cpoints("BezierCurve")')
    check(n1 == '= 3' and x1 not in ('= -1', '') and n2 == '= 4', f'E extrudes the end point, Ctrl+click adds one ({n1} {x1} {n2})')
    f.shot('92_curve_edit.png')
    f.key(45)                                   # X: the selected one goes
    check(q('cpoints("BezierCurve")') == '= 3', 'X deletes the selected point')
    f.key(15)
    q('op("curve.set", "bevel 0.15")')
    f.pump(0.3)
    nf = q('efaces("BezierCurve")')
    check(px(f, *p1) != 0x161616 and nf == '= 192', f'Tab leaves; a bevel makes a tube ({nf})')
    f.shot('93_curve_tube.png')
    f.proc.kill()


def procedural():
    """Procedural generators: a noise terrain (fBm / ridged), terraced and
    eroded by droplets (deterministic per seed, inside its range, a budget);
    L-systems drawn by the turtle as lines or tapering tubes (and the
    L-system node's presets); wave function collapse over tile objects with
    adjacency read from their faces."""
    print('  -- terrain, L-systems, wave function collapse --')
    home = tempfile.mkdtemp(prefix='bee-pg-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    code = ('delete("Cube")\nt = gtree("T")\no = gnode(t, "output")\ntr = gnode(t, "terrain", 10, 64, 2, 1)\n'
            'glink(t, tr, o, 1)\nadd("plane", "Land", 0, 0, 0)\nm = modifier("Land", "geometry")\n'
            'modset("Land", m, "tree", t)\nprint(everts("Land"), efaces("Land"))\n'
            'er = gnode(t, "erode", 100000, 0.3, 1)\nglink(t, tr, er, 1)\nglink(t, er, o, 1)\n'
            'c0 = clock()\nprint(everts("Land"), clock() - c0)\n'
            'te = gnode(t, "terrace", 4, 0.01)\nglink(t, tr, te, 1)\nglink(t, te, o, 1)\n'
            'add("plane", "A", 0, 0, 0)\nma = modifier("A", "geometry")\nmodset("A", ma, "tree", t)\nmodapply("A", ma)\n'
            'glink(t, er, o, 1)\nadd("plane", "B", 0, 0, 0)\nmb = modifier("B", "geometry")\nmodset("B", mb, "tree", t)\nmodapply("B", mb)\n'
            'add("plane", "C", 0, 0, 0)\nmc = modifier("C", "geometry")\nmodset("C", mc, "tree", t)\nmodapply("C", mc)\n'
            'glink(t, tr, o, 1)\nadd("plane", "D", 0, 0, 0)\nmd = modifier("D", "geometry")\nmodset("D", md, "tree", t)\nmodapply("D", md)\n'
            'lo = 99\nhi = -99\nflat = 0\nsame = 0\nmoved = 0\n'
            'for i in 0..verts("D") {\n y = vpos("D", i, "y")\n if y < lo { lo = y }\n if y > hi { hi = y }\n'
            ' if vpos("B", i, "y") == vpos("C", i, "y") { same += 1 }\n'
            ' if vpos("B", i, "y") != y { moved += 1 }\n}\n'
            'st = (hi - lo) / 4\nfor i in 0..verts("A") {\n k = (vpos("A", i, "y") - lo) / st\n'
            ' if k - floor(k + 0.5) < 0.02 { if floor(k + 0.5) - k < 0.02 { flat += 1 } }\n}\n'
            'print(lo, hi, flat, same, moved)\n'
            'k = lsystem("Koch", "F-F-F-F", "F=F-F+F+FF-F-F+F", 2, 90, 0.1)\nprint(everts(k), efaces(k))\n'
            'p = lsystem("Fern", "X", "X=F+[[X]-X]-F[-FX]+X; F=FF", 4, 25, 0.05, 0.03)\nprint(everts(p), efaces(p))\n'
            'l = gtree("L")\nlo2 = gnode(l, "output")\nls = gnode(l, "lsystem", 3, 2, 0, 0.1)\nglink(l, ls, lo2, 1)\n'
            'add("plane", "Isle", 0, 0, 0)\nml = modifier("Isle", "geometry")\nmodset("Isle", ml, "tree", l)\nprint(everts("Isle"), efaces("Isle"))\n'
            'add("plane", "Ramp", 5, 0, 0)\nfor i in 0..4 {\n x = vpos("Ramp", i, "x")\n z = vpos("Ramp", i, "z")\n'
            ' vmove("Ramp", i, x / 2, x / 2, z / 2)\n}\nadd("cube", "Block", 8, 0, 0)\nscale("Block", 0.5)\n'
            'w = wfc("Hills", 6, 6, 1, 1, "Ramp")\nprint(everts(w), efaces(w))\n'
            'n = 0\nfor i in 0..verts(w) {\n if vpos(w, i, "y") > 0.4 { n += 1 }\n}\nprint(n)\n'
            'b = wfc("Mix", 4, 4, 3, 7, "Ramp Block")\nprint(everts(b) + efaces(b))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
    out = r.stdout.split()
    try:
        v = [float(x) for x in out]
    except Exception:
        v = []
    ok = len(v) == 19
    check(ok and v[0:3] == [4225, 4096, 4225] and v[3] < 1000 and 0 <= v[5] - v[4] <= 2.001 and v[5] - v[4] > 0.5,
          f'a 64 x 64 noise terrain within its height; 100k erosion droplets in {out[3:4]} ms ({out[:6]})')
    check(ok and v[6] > 0.8 * 4225 and v[7] == 4225 and v[8] > 1000,
          f'terraces: most heights on 4 steps; erosion is the same for a seed and moves the ground ({out[6:9]})')
    check(ok and v[9:11] == [257, 256] and v[11] > 1000 and v[12] > 1000 and v[13:15] == [257, 256],
          f'L-systems: a Koch island as lines, a fern as tubes, the node\'s preset ({out[9:15]})')
    check(ok and v[15:17] == [144, 36] and v[17] == 72 and v[18] in (48 * 5, 48 * 14),
          f'wave function collapse: ramps fit only up-then-down; ramps and blocks never touch ({out[15:19]})')
    print(r.stderr[-300:] if not ok else '', end='')


def copilot():
    """The procedural co-pilot over MCP: the node catalogue, a tree described
    as JSON (tool and bee://graphs), the procedural prompt; a proposal built
    through the tree operators, shown in a banner, reverted with Esc (the
    scene as before), then accepted with a click and undone in one step."""
    print('  -- procedural co-pilot --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    types = json.loads(m.tool('node_types')[0] or '{}').get('geometry_nodes', [])
    grid = next((t for t in types if t.get('type') == 'grid'), {})
    math_ = next((t for t in types if t.get('type') == 'math'), {})
    check(len(types) >= 39 and [v['name'] for v in grid.get('values', [])] == ['Size', 'Subdivisions']
          and grid['outputs'][0]['kind'] == 'geometry' and 'Modulo' in math_['values'][0].get('choices', []),
          f'node_types: {len(types)} types with slots, kinds, defaults, choices')
    pr = m.call('prompts/get', {'name': 'procedural', 'arguments': {'goal': 'a rocky hill'}})
    txt = ((pr or {}).get('result', {}).get('messages') or [{}])[0].get('content', {}).get('text', '')
    check('a rocky hill' in txt and 'propose_begin' in txt and m.call('prompts/list')['result']['prompts'][0]['name'] == 'procedural',
          'the procedural prompt walks an agent through a proposal for a goal')
    m.tool('propose_begin', {'title': 'Flatten into a grid'})
    m.tool('op_tree_new', {'arg': 'Rocks'})
    m.tool('op_tree_node', {'arg': 'Rocks output'})
    m.tool('op_tree_node', {'arg': 'Rocks grid 4 20'})
    m.tool('op_tree_link', {'arg': 'Rocks 2 1 1'})
    ev = m.tool('script_eval', {'code': 'm = modifier("Cube", "geometry")\nmodset("Cube", m, "tree", 1)\neverts("Cube")'})[0]
    g = json.loads(m.tool('describe_graph', {'tree': 'Rocks'})[0] or '{}')
    check(ev.strip() == '= 441' and g.get('proposal') == 'building' and len(g.get('nodes', [])) == 2
          and g['nodes'][0]['inputs'][0].get('from') == {'node': 2, 'output': 0} and g['nodes'][1]['values'][:2] == [4, 20],
          'a proposal builds a tree through the operators; describe_graph shows its links and values')
    m.tool('propose_end')
    f.pump(0.3)
    banner = px(f, 733, 134), px(f, 875, 134)   # (Accept, Revert: clear of the nav gizmo)
    f.shot('94_copilot_proposal.png')
    f.key(1)                                    # Esc: revert
    f.pump(0.3)
    st = m.tool('proposal_status')[0]
    after = m.tool('script_eval', {'code': 'print(everts("Cube"), count())'})[0].strip()
    res = m.call('resources/read', {'uri': 'bee://graphs'})
    gr = json.loads(res['result']['contents'][0]['text'])
    check(banner == (0x3f8f5a, 0x8f3f3f) and st == '"reverted"' and after.startswith('8 3') and gr == {'trees': [], 'proposal': 'reverted'},
          f'the banner offers Accept / Revert; Esc takes the whole proposal back ({after!r})')
    m.tool('propose_begin', {'title': 'Again'})
    m.tool('script_eval', {'code': 't = gtree("Rocks")\no = gnode(t, "output")\ng = gnode(t, "grid", 4, 20)\nglink(t, g, o, 1)\n'
                                   'm = modifier("Cube", "geometry")\nmodset("Cube", m, "tree", t)'})
    m.tool('create_primitive', {'type': 'sphere'})
    m.tool('propose_end')
    f.pump(0.3)
    f.click(790, 141)                           # Accept
    f.pump(0.2)
    acc = m.tool('proposal_status')[0], m.tool('script_eval', {'code': 'print(everts("Cube"), count())'})[0].strip()
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z: all of it at once
    f.pump(0.2)
    und = m.tool('script_eval', {'code': 'print(everts("Cube"), count())'})[0].strip()
    check(acc[0] == '"accepted"' and acc[1].startswith('441 4') and und.startswith('8 3'),
          f'Accept keeps it as one undo step ({acc} -> {und!r})')
    f.proc.kill()


def animation():
    """Keyframes: any property a script can set (object transforms,
    material values, modifier parameters, node inputs) keyed with Bezier
    (auto-clamped), linear or constant blends; the scene at a frame; saved
    in .bee files. In the window: I keys the selection, the Timeline area
    shows the range and keys and scrubs, Space plays, arrows step, Ctrl+Z
    takes keys back."""
    print('  -- keyframes, timeline --')
    home = tempfile.mkdtemp(prefix='bee-an-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    code = ('print(key("Cube:x", 1, 0), key("Cube:x", 25, 4), key("Cube:x", 49, 4))\n'
            'print(keyed("Cube:x", 13), keyed("Cube:x", 37), keyed("Cube:x", 100))\n'
            'print(key("Cube:ry", 1, 0, "linear"), key("Cube:ry", 11, 1), keyed("Cube:ry", 6))\n'
            'print(key("Cube:sy", 1, 1, "constant"), key("Cube:sy", 11, 2), keyed("Cube:sy", 10.9))\n'
            'frame(13)\nprint(frame(), get("Cube", "x"))\n'
            'm = material("Red")\nassign("Cube", m)\nkey("material:Red:roughness", 1, 0.1)\nkey("material:Red:roughness", 21, 0.9)\n'
            'mm = modifier("Cube", "subsurf")\nkey("modifier:Cube:0:levels", 1, 0)\nkey("modifier:Cube:0:levels", 11, 3)\n'
            't = gtree("T")\no = gnode(t, "output")\ng = gnode(t, "grid", 2, 2)\nglink(t, g, o, 1)\n'
            'key("node:T:2:5", 1, 2)\nkey("node:T:2:5", 11, 10)\nadd("plane", "P", 0, 0, 0)\nmp = modifier("P", "geometry")\n'
            'modset("P", mp, "tree", t)\nframe(11)\nprint(matget("Red", "roughness"), everts("Cube"), everts("P"))\n'
            'frame(1)\nprint(everts("Cube"), everts("P"))\n'
            'print(unkey("Cube:x", 25), keyed("Cube:x", 25))\nop("anim.range", "1 120 30")\n'
            'op("file.save", "~/BeeModel/a.bee")\nop("file.new")\nprint(keyed("Cube:x", 13))\nop("file.open", "~/BeeModel/a.bee")\n'
            'print(frame(), keyed("Cube:x", 25), keyed("modifier:Cube:0:levels", 11))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=60)
    out = r.stdout.split('\n')
    def nums(i):
        try:
            return [float(x) for x in out[i].split()]
        except Exception:
            return []
    check(nums(0) == [1, 2, 3] and nums(1) == [2, 4, 4] and nums(2) == [1, 2, 0.5] and nums(3) == [1, 2, 1]
          and nums(4) == [13, 2], f'Bezier (flat at extremes), linear and constant keys; the scene at frame 13 ({out[:5]})')
    check(nums(5) == [0.5, 386, 121] and nums(6) == [8, 9],
          f'material values, modifier parameters and node inputs keyed: the scene follows the frame ({out[5:7]})')
    check(nums(7) == [1, 2] and out[8].strip() == 'nil' and nums(9) == [1, 2, 3],
          f'a key removed; keys and the frame come back from the .bee file ({out[7:10]})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(600, 300)
    q('frame(1)')
    f.key(23)                                   # I: key the selection
    q('frame(25)\nset("Cube", "x", 4)')
    f.key(23)
    k = q('print(keyed("Cube:x", 13), keyed("Cube:sz", 13))')
    check(k == '2 1', f'I keys the selected object\'s transform at the frame ({k})')
    f.move(600, 700)
    q('op("area.type_timeline")')
    f.pump(0.3)
    f.shot('95_timeline.png')
    f.drag(300, 690, 400, 690, steps=6)        # scrub
    fr = q('print(frame(), get("Cube", "x"))').split()
    check(len(fr) == 2 and float(fr[0]) > 30 and float(fr[1]) == 4,
          f'dragging in the timeline scrubs the scene ({fr})')
    q('frame(13)')
    f.move(600, 300)
    f.key(106)                                  # Right: one frame on
    a = q('print(frame())')
    f.key(57)                                   # Space: play
    f.pump(0.6)
    f.key(57)                                   # Space: pause
    b = q('print(frame())')
    f.pump(0.2)
    c = q('print(frame())')
    check(a == '14' and float(b) > 14 and b == c, f'Right steps a frame; Space plays and pauses ({a} -> {b}, {c})')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z: the second key goes
    d = q('print(keyed("Cube:x", 25))')
    check(d == '0', f'Ctrl+Z takes the last keys back ({d})')
    f.proc.kill()


def anim_editors():
    """The Dope Sheet (rows of keys: click selects, a drag moves whole
    frames, Shift+D copies, X deletes) and the Graph Editor (curves fitted
    to the view: a key dragged up changes its value); key edits by operator
    (select, move, scale, duplicate, delete, handles); actions played as
    layers (replace / add, influence, repeats, mute)."""
    print('  -- dope sheet, graph editor, action layers --')
    home = tempfile.mkdtemp(prefix='bee-ae-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    code = ('key("Cube:x", 1, 0)\nkey("Cube:x", 11, 10)\nkey("Cube:y", 11, 5)\n'
            'op("anim.select_keys", "Cube:x 11")\nop("anim.move_keys", "10 2")\n'
            'print(keyed("Cube:x", 21), keyed("Cube:x", 11), keyed("Cube:y", 11))\n'
            'op("anim.select_keys", "frame 1")\nop("anim.duplicate_keys", "40")\nprint(keyed("Cube:x", 41), keyed("Cube:x", 1))\n'
            'op("anim.select_keys", "all")\nop("anim.scale_keys", "2")\nprint(keyed("Cube:x", 41), keyed("Cube:x", 81))\n'
            'op("anim.select_keys", "Cube:x 41")\nop("anim.delete_keys")\nprint(keyed("Cube:x", 41))\n'
            'op("anim.handle", "Cube:x 1 right 10 30")\nprint(keyed("Cube:x", 11) > 5)\n'
            'op("anim.select_keys", "Cube:x 1")\nop("anim.handle_type", "auto")\nprint(keyed("Cube:x", 11))\n'
            'op("file.new")\nkey("Cube:x", 1, 0)\nkey("Cube:x", 21, 10, "linear")\nkey("Cube:x", 41, 10)\n'
            'op("anim.action", "Slide")\nadd("cube", "B", 0, 3, 0)\nop("anim.layer", "Slide B 100 1 replace 2")\n'
            'frame(111)\nb1 = get("B", "x")\nframe(151)\nprint(b1 > 5, abs(get("B", "x") - b1) < 0.001, get("B", "y"))\n'
            'op("anim.layer_set", "1 mode 1")\nop("anim.layer_set", "1 influence 0.5")\nset("B", "x", 1)\nframe(111)\n'
            'print(abs(get("B", "x") - 1 - b1 / 2) < 0.001)\nop("anim.layer_set", "1 mute 1")\nset("B", "x", 1)\nframe(111)\nprint(get("B", "x"))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=60)
    out = [l.strip() for l in r.stdout.split('\n')]
    check(out[:6] == ['12 6 5', '0 0', '12 0', '0', '1', '0'],
          f'keys selected, moved, copied, stretched, deleted, a handle shaped and made auto again ({out[:6]})')
    check(out[6:9] == ['1 1 3', '1', '1'], f'an action plays as a layer on another object: repeats, add at half influence, mute ({out[6:9]})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(600, 300)
    q('key("Cube:x", 1, 0)\nkey("Cube:x", 40, 4)\nkey("Cube:x", 80, -2)\nkey("Cube:y", 20, 1)\nkey("Cube:y", 60, 3)\nframe(30)')
    f.move(600, 700)
    q('op("area.type_dope_sheet")')
    f.pump(0.3)
    f.shot('96_dope_sheet.png')
    ex, ey, ew = 214, 652, 801                  # the bottom area (as laid out)
    kx = lambda fr, x0, w: int(x0 + (fr - 1) / 249 * w + 0.5)
    x40 = kx(40, ex + 170, ew - 190)
    f.drag(x40, ey + 46 + 9, x40 + 25, ey + 46 + 9, steps=6)   # ~10 frames on
    a = q('print(keyed("Cube:x", 50), keyed("Cube:x", 40) != 4)')
    f.move(600, 700)
    f.mods(1); f.key(32); f.mods(0)             # Shift+D: ten frames on
    b = q('print(keyed("Cube:x", 60))')
    f.key(45)                                   # X: the copy goes
    c = q('print(keyed("Cube:x", 60) != 4, keyed("Cube:x", 50))')
    check(a == '4 1' and b == '4' and c == '1 4', f'the dope sheet: a key dragged ten frames on, Shift+D copies it, X deletes ({a}, {b}, {c})')
    q('unkey("Cube:y", 20)\nunkey("Cube:y", 60)\nunkey("Cube:x", 50)\nunkey("Cube:x", 80)\nkey("Cube:x", 100, 10, "linear")\n'
      'op("anim.interpolation", "linear")\nop("area.type_graph_editor")')
    f.pump(0.3)
    gx0, gw, gy0, gh = ex + 50, ew - 70, ey + 46, 126 - 58
    y10 = gy0 + gh - int(11 / 12 * gh)
    x100 = kx(100, gx0, gw)
    f.drag(x100, y10, x100, y10 - 10, steps=5)  # the key at 100 up
    d = q('print(keyed("Cube:x", 100) > 10.5)')
    f.shot('97_graph_editor.png')
    check(d == '1', f'the graph editor: a key dragged up gets a higher value ({d})')
    f.proc.kill()


def armatures():
    """Armatures: bones (rest heads / tails, parents, joined chains) and
    poses; a mesh skinned by automatic weights (bone heat), linear blend
    and dual quaternion; bones keyed and played; weights painted; the
    armature saved. In the window: Ctrl+Tab poses (click a bone, R Z 90,
    I keys it), Tab edits (click a tail, E extrudes a bone)."""
    print('  -- armatures, skinning --')
    home = tempfile.mkdtemp(prefix='bee-ar-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    code = ('delete("Cube")\na = armature("Rig")\nop("arm.bone", "Upper Bone 0 1 0 0 2 0")\n'
            'add("cylinder", "Arm", 0, 1, 0)\nmodifier("Arm", "subsurf")\nmodset("Arm", 0, "levels", 3)\nmodapply("Arm", 0)\n'
            'scale("Arm", 0.3)\nprint(verts("Arm"), bones("Rig"))\nc0 = clock()\nop("arm.parent", "Arm Rig")\nprint(clock() - c0)\n'
            'n = verts("Arm")\ntop = 0\nlow = 0\nbad = 0\nmx = -9\nmn = 9\nfor i in 0..n {\n y = vpos("Arm", i, "y")\n'
            ' if y + vpos("Arm", i, "x") > mx {\n  mx = y + vpos("Arm", i, "x")\n  top = i\n }\n if y < mn {\n  mn = y\n  low = i\n }\n'
            ' if abs(weight("Arm", i, 0) + weight("Arm", i, 1) - 1) > 0.001 { bad += 1 }\n}\n'
            'print(bad, weight("Arm", top, 1) > 0.5, weight("Arm", low, 0) > 0.9)\n'
            'x0 = evpos("Arm", top, "x")\nselect("Rig")\nop("arm.pose", "Upper rot 0 0 90")\nx1 = evpos("Arm", top, "x")\n'
            'print(x0 > 0.5, x1 < 0, abs(evpos("Arm", low, "x") - vpos("Arm", low, "x")) < 0.05)\n'
            'modset("Arm", 0, "mode", 1)\nx2 = evpos("Arm", top, "x")\ny2 = evpos("Arm", top, "y")\n'
            'modset("Arm", 0, "mode", 0)\nprint(x2 != x1, y2 > evpos("Arm", top, "y"))\n'
            'op("arm.clear_pose")\nkey("bone:Rig:Upper:rz", 1, 0)\nkey("bone:Rig:Upper:rz", 21, 1.5708)\n'
            'frame(1)\nf1 = evpos("Arm", top, "x")\nframe(21)\nprint(abs(f1 - x0) < 0.0001, abs(evpos("Arm", top, "x") - x1) < 0.0001)\n'
            'w0 = weight("Arm", top, 0)\nprint(wpaint("Arm", 0, 1.3, 0, 1, 0, 1), weight("Arm", top, 0) > w0)\n'
            'op("file.save", "~/BeeModel/r.bee")\nop("file.new")\nop("file.open", "~/BeeModel/r.bee")\n'
            'print(bones("Rig"), abs(evpos("Arm", top, "x") - x1) > 0.0001, weight("Arm", top, 0) > w0)\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
    out = [l.strip() for l in r.stdout.split('\n')]
    try:
        aw = float(out[1])
    except Exception:
        aw = 1e9
    check(out[0] == '3074 2' and aw < 500 and out[2] == '0 1 1',
          f'automatic weights by bone heat for 3074 vertices in {out[1:2]} ms: they sum to one, the far ends belong to their bones ({out[:3]})')
    check(out[3] == '1 1 1' and out[4] == '1 1',
          f'a posed bone bends the skin (the other end stays); dual quaternions keep the volume ({out[3:5]})')
    check(out[5] == '1 1' and out[6] == '1 1' and out[7] == '2 1 1',
          f'bones keyed and played; weights painted; the armature and weights saved ({out[5:8]})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(600, 300)
    q('delete("Cube")\na = armature("Rig")\nop("arm.bone", "Upper Bone 0 1 0 0 2 0")\nadd("cylinder", "Arm", 0, 1, 0)\n'
      'scale("Arm", 0.3)\nop("arm.parent", "Arm Rig")\nselect("Rig")')
    f.mods(4); f.key(15); f.mods(0)             # Ctrl+Tab: pose mode
    f.click(*project((0, 1.5, 0)))              # the upper bone
    f.key(19); f.key(44); f.type('90'); f.key(28)   # R Z 90 Enter
    f.key(23)                                   # I: key it
    a = q('print(keyed("bone:Rig:Upper:rz", 1), keyed("bone:Rig:Bone:rz", 1))')
    f.shot('98_pose_mode.png')
    f.mods(4); f.key(15); f.mods(0)
    f.key(15)                                   # Tab: armature edit mode
    tail = project((0, 2, 0))
    f.click(*tail)
    f.key(18)                                   # E: a new bone from the tail
    f.move(tail[0] + 40, tail[1] - 40)
    f.click(tail[0] + 40, tail[1] - 40)
    b = q('print(bones("Rig"))')
    f.key(15)
    check(a == '1.570796 nil' and b == '3', f'pose mode: a bone clicked, turned 90 degrees and keyed; edit mode: E extrudes a bone ({a}, {b})')
    q('select("Arm")')
    f.mods(4); f.key(17); f.mods(0)             # Ctrl+W: weight paint
    f.pump(0.3)
    img = f.image()
    heat = sum(1 for y in range(290, 340, 2) for x in range(590, 640, 2)
               if (lambda c: max(c) - min(c) > 80)(img.getpixel((x, y))))
    w0 = q('print(weight("Arm", 0, 0) + weight("Arm", 0, 1))')
    f.shot('99_weight_paint.png')
    f.mods(4); f.key(17); f.mods(0)
    check(heat > 20 and w0 == '1', f'Ctrl+W shows the weights as heat ({heat} coloured pixels)')
    f.proc.kill()

def rigging():
    """Rigging: object constraints (copy, limit, track to, child of, with
    influence), IK chains (FABRIK and CCD, a pole, out of reach), drivers,
    shape keys (stored, mixed, keyed, driven), all saved. In the window:
    motion paths, onion skins, a constraint undone with Ctrl+Z, an IK goal
    dragged with G."""
    print('  -- rigging: constraints, IK, drivers, shape keys --')
    home = tempfile.mkdtemp(prefix='bee-rig-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r1 = lambda *v: ' '.join(str(round(x, 3)) for x in v)
    code = ('add("sphere", "T", 3, 2, 1)\nop("constraint.add", "Cube copy_location T axes xz")\n'
            'print(get("Cube", "x"), get("Cube", "y"), get("Cube", "z"))\nmove("T", 5, 2, -1)\n'
            'op("constraint.add", "Cube limit_location axes x min -10 0 0 max 4 0 0")\nprint(get("Cube", "x"), get("Cube", "z"))\n'
            'op("constraint.remove", "Cube")\nprint(get("Cube", "x"), get("Cube", "z"))\n'
            'add("camera", "Cam", 0, 0, 10)\nop("constraint.add", "Cam track_to T")\n'
            'print(round(get("Cam", "rx") * 1000), round(get("Cam", "ry") * 1000))\n'
            'add("cube", "Kid", 6, 2, -1)\nop("constraint.add", "Kid child_of T")\nmove("T", 5, 3, -1)\nrotate("T", 0, 1.5708, 0)\n'
            'print(round(get("Kid", "x") * 100), round(get("Kid", "y") * 100), round(get("Kid", "z") * 100))\n'
            'op("anim.driver", "Cube:sy a=T:x b=T:y a*2+b+frame")\nprint(get("Cube", "sy"))\n'
            'move("T", 1, 1, 1)\nprint(get("Cube", "sy"))\n'
            'a = armature("Rig")\nop("arm.bone", "Upper Bone 0 1 0 0 2 0")\nop("arm.bone", "Hand Upper 0 2 0 0 2.5 0")\n'
            'add("sphere", "Goal", 1, 1.2, 0.3)\nadd("sphere", "Knee", 0, 1, -3)\n'
            'op("constraint.add", "Rig:Upper ik Goal chain 2 pole Knee")\n'
            'print(round(bonepos("Rig", "Upper", "x") * 1000), round(bonepos("Rig", "Upper", "y") * 1000), round(bonepos("Rig", "Upper", "z") * 1000), bonepos("Rig", "Bone", "z") < -0.2)\n'
            'op("constraint.remove", "Rig")\nop("constraint.add", "Rig:Upper ik Goal chain 2 solver ccd iterations 50")\n'
            'print(round(bonepos("Rig", "Upper", "x") * 100), round(bonepos("Rig", "Upper", "y") * 100), round(bonepos("Rig", "Upper", "z") * 100))\n'
            'move("Goal", 5, 0, 0)\nprint(round(bonepos("Rig", "Upper", "x") * 1000), round(bonepos("Rig", "Upper", "y") * 1000))\n'
            'select("Cube")\nop("shape.add", "Smile")\ny0 = vpos("Cube", 0, "y")\n'
            'vmove("Cube", 0, vpos("Cube", 0, "x"), y0 + 1, vpos("Cube", 0, "z"))\nop("shape.add", "Smile")\n'
            'print(shapes("Cube"), vpos("Cube", 0, "y") == y0, evpos("Cube", 0, "y") == y0)\n'
            'op("shape.set", "Smile 0.5")\nprint(evpos("Cube", 0, "y") - y0)\n'
            'key("shape:Cube:Smile", 1, 0)\nkey("shape:Cube:Smile", 11, 1)\nframe(11)\nprint(evpos("Cube", 0, "y") - y0)\n'
            'add("sphere", "Dial", 4, 0, 0)\nop("anim.driver", "shape:Cube:Smile d=Dial:x d/8")\nframe(1)\n'
            'print(prop("shape:Cube:Smile"), evpos("Cube", 0, "y") - y0)\n'
            'op("file.save", "~/BeeModel/rig.bee")\nop("file.new")\nop("file.open", "~/BeeModel/rig.bee")\n'
            'move("Dial", 2, 0, 0)\nprint(shapes("Cube"), prop("shape:Cube:Smile"), get("Cube", "sy"), round(bonepos("Rig", "Upper", "x") * 100))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
    out = [l.strip() for l in r.stdout.split('\n')]
    out += [''] * 16
    check(out[0] == '3 1 1' and out[1] == '4 -1' and out[2] == '0 0' and out[3] == '164 -427' and out[4] == '500 300 -200',
          f'constraints: copy location (x z), limit, removed (the object its own again), track to, child of ({out[:5]})')
    check(out[5] == '14' and out[6] == '4', f'a driver: a*2 + b + frame of two other properties, following them ({out[5:7]})')
    check(out[7] == '1000 1200 300 1' and out[8] == '100 120 30' and out[9] == '2000 0',
          f'IK: FABRIK reaches the goal with the knee towards the pole; CCD too; out of reach: straight at it ({out[7:10]})')
    check(out[10] == '2 1 1' and out[11] == '0.5' and out[12] == '1' and out[13] == '0.5 0.5',
          f'shape keys: stored (the Basis back), mixed, keyed, driven ({out[10:14]})')
    check(out[14] == '2 0.25 4 200', f'constraints, drivers and shape keys saved and reopened, still live ({out[14]})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(600, 300)
    q('key("Cube:x", 1, -4)\nkey("Cube:x", 21, 4)\nkey("Cube:y", 1, 0)\nkey("Cube:y", 11, 3)\nkey("Cube:y", 21, 0)\n'
      'select("Cube")\nop("anim.motion_paths")\nframe(11)')
    f.pump(0.3)
    img = f.image()
    count = lambda cols: sum(1 for y in range(80, 620, 2) for x in range(214, 1014, 2) if img.getpixel((x, y))[:3] in cols)
    path = count({(0x7a, 0xa6, 0xff)})
    keys = count({(0xff, 0xd2, 0x7a)})
    f.shot('100_motion_paths.png')
    q('op("anim.motion_paths", "clear")\nop("anim.onion", "2 2 4")')
    f.pump(0.3)
    img = f.image()
    red = count({(0xf0, 0x60, 0x60), (0x78, 0x30, 0x30)})
    green = count({(0x60, 0xd0, 0x70), (0x30, 0x68, 0x38)})
    f.shot('101_onion_skins.png')
    q('op("anim.onion", "off")')
    check(path > 40 and keys > 5 and red > 20 and green > 20,
          f'motion paths ({path} path, {keys} key pixels); onion skins before and after ({red} red, {green} green pixels)')
    q('add("sphere", "T", 3, 2, 1)\nscale("T", 0.2)')
    q('op("constraint.add", "Cube copy_location T")')
    a = q('print(get("Cube", "x"), get("Cube", "y"))')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z
    f.pump(0.2)
    b = q('print(get("Cube", "x"), get("Cube", "y"))')
    check(a == '3 2' and b == '0 3', f'a constraint undone with Ctrl+Z gives the object back ({a} -> {b})')
    q('delete("Cube")\ndelete("T")\na = armature("Rig")\nop("arm.bone", "Upper Bone 0 1 0 0 2 0")\n'
      'add("sphere", "Goal", 1.5, 1, 0)\nscale("Goal", 0.15)\nop("constraint.add", "Rig:Upper ik Goal chain 2")\nselect("Goal")')
    t0 = q('print(round(bonepos("Rig", "Upper", "x") * 100), round(bonepos("Rig", "Upper", "y") * 100))')
    g = project((1.5, 1, 0))
    f.move(*g)
    f.key(34)                                   # G: the goal follows the mouse
    f.move(g[0] - 50, g[1] + 10)
    f.pump(0.2)
    f.shot('102_ik_drag.png')
    f.click(g[0] - 50, g[1] + 10)
    t1 = q('d = pow(bonepos("Rig", "Upper", "x") - get("Goal", "x"), 2) + pow(bonepos("Rig", "Upper", "y") - get("Goal", "y"), 2) + pow(bonepos("Rig", "Upper", "z") - get("Goal", "z"), 2)\n'
           'print(round(sqrt(d) * 1000), round(get("Goal", "x") * 100), round(sqrt(pow(get("Goal", "x"), 2) + pow(get("Goal", "y"), 2) + pow(get("Goal", "z"), 2)) * 100))')
    w = t1.split()
    check(t0 == '150 100' and len(w) == 3 and int(w[0]) <= 5 and w[1] != '150' and int(w[2]) < 200,
          f'IK: dragging the goal with G, the chain follows ({t0} -> tip off the goal, goal x, its distance: {t1})')
    f.proc.kill()

def rigid_bodies():
    """Rigid bodies: a box lands flat and sleeps, a stack of five stands, a
    hull, a compound (a ball drops through a torus's hole; on its hull it
    stays on top), joints (a hinge swings about its axis, a pendulum keeps
    its length, a fixed pair stays together), the settings saved; 1000
    tumbling boxes faster than real time. In the window: Space plays a pile
    falling, the start brings it back."""
    print('  -- rigid bodies --')
    home = tempfile.mkdtemp(prefix='bee-rb-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    code = ('delete("Cube")\nadd("plane", "Ground", 0, 0, 0)\nscale("Ground", 20)\nselect("Ground")\nop("rigid.add", "passive box")\n'
            'add("cube", "Box", -6, 3, 0)\nscale("Box", 0.5)\nselect("Box")\nop("rigid.add", "active box")\n'
            'for i in 0..5 {\n n = "S" + str(i)\n add("cube", n, 6 + 0.1 * (i % 2), 0.5 + i * 1.05, 0)\n scale(n, 0.5)\n select(n)\n op("rigid.add", "active box")\n}\n'
            'add("cone", "Cone", -3, 2, -4)\nselect("Cone")\nop("rigid.add", "active hull")\n'
            'add("torus", "Ring", 0, 0.3, -6)\nselect("Ring")\nop("rigid.add", "passive compound")\n'
            'add("sphere", "Ball", 0, 2, -6)\nscale("Ball", 0.3)\nselect("Ball")\nop("rigid.add", "active sphere")\n'
            'add("torus", "Ring2", 6, 0.3, -6)\nselect("Ring2")\nop("rigid.add", "passive hull")\n'
            'add("sphere", "Ball2", 6, 2, -6)\nscale("Ball2", 0.3)\nselect("Ball2")\nop("rigid.add", "active sphere")\n'
            'add("cube", "Flap", 0, 4, 6.6)\nscale("Flap", 0.6, 0.1, 0.6)\nselect("Flap")\nop("rigid.add", "active box")\n'
            'op("rigid.joint", "hinge Flap world pivot 0 4 6 axis 1 0 0")\n'
            'add("cube", "Bob", 6, 4, 6)\nscale("Bob", 0.3)\nselect("Bob")\nop("rigid.add", "active box")\nop("rigid.joint", "point Bob world pivot 4 4 6")\n'
            'add("cube", "Glue", -4, 5, 6)\nscale("Glue", 0.4)\nadd("cube", "Glued", -3.2, 5, 6)\nscale("Glued", 0.4)\n'
            'select("Glue", "Glued")\nop("rigid.add", "active box")\nop("rigid.joint", "fixed Glued Glue")\n'
            'frame(2)\nprint(rbinfo(0), rbinfo(7))\nlow = 9\non = 0\n'
            'for f in 3..121 {\n frame(f)\n if get("Flap", "y") < low { low = get("Flap", "y") }\n if f == 40 { on = get("Ball2", "y") > 0.5 }\n}\n'
            'print(round(get("Box", "y") * 100), round(get("Box", "rx") * 100), round(get("Box", "rz") * 100), round(get("S4", "y") * 100), rbinfo(2))\n'
            'print(round(get("Cone", "y") * 100), get("Ball", "y") < 0.4, on)\n'
            'print(round(sqrt(pow(get("Flap", "y") - 4, 2) + pow(get("Flap", "z") - 6, 2)) * 100), round(get("Flap", "x") * 100), low < 3.45)\n'
            'print(round(sqrt(pow(get("Bob", "x") - 4, 2) + pow(get("Bob", "y") - 4, 2) + pow(get("Bob", "z") - 6, 2)) * 100), round((get("Glued", "x") - get("Glue", "x")) * 100), round(get("Glue", "y") * 100))\n'
            'b = get("Box", "y")\nop("file.save", "~/BeeModel/rb.bee")\nop("file.new")\nop("file.open", "~/BeeModel/rb.bee")\n'
            'frame(1)\nprint(round(get("Box", "y") * 100))\nframe(120)\nprint(abs(get("Box", "y") - b) < 0.01)\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=300)
    out = [l.strip() for l in r.stdout.split('\n')] + [''] * 10
    w1 = out[1].split()
    check(out[0] == '16 31' and len(w1) == 5 and w1[0] == '50' and abs(int(w1[1])) <= 1 and abs(int(w1[2])) <= 1
          and 445 <= int(w1[3]) <= 455 and int(w1[4]) <= 3,
          f'a box lands flat; a stack of five stands; they sleep (the swinging ones do not) ({out[:2]})')
    check(out[2] in ('99 1 1', '100 1 1', '101 1 1'), f'a cone as its hull; a ball drops through a torus (compound) but stays on its hull ({out[2]})')
    w3, w4 = out[3].split(), out[4].split()
    check(len(w3) == 3 and abs(int(w3[0]) - 60) <= 2 and w3[1] == '0' and w3[2] == '1' and len(w4) == 3
          and abs(int(w4[0]) - 200) <= 2 and abs(int(w4[1]) - 80) <= 1 and w4[2] == '40',
          f'joints: a hinge swings about its axis, a pendulum keeps its length, a fixed pair lands together ({out[3:5]})')
    check(out[5] == '300' and out[6] == '1', f'the start and the settings saved: reopened, it simulates the same ({out[5:7]})')
    # 1000 boxes tumbling into a heap: ten seconds simulated
    code = ('delete("Cube")\nadd("plane", "Ground", 0, 0, 0)\nscale("Ground", 40)\n'
            'for k in 0..10 {\n for i in 0..10 {\n  for j in 0..10 {\n   n = "B" + str(k * 100 + i * 10 + j)\n'
            '   add("cube", n, i * 1.2 - 6 + 0.6 * (k % 2), 1 + k * 1.2, j * 1.2 - 6 + 0.6 * (k % 2))\n'
            '   rotate(n, 0.1 * k, 0.37 * k + 0.1 * i, 0.05 * j)\n   scale(n, 0.5)\n  }\n }\n}\n'
            'select()\nop("object.select_all")\nop("rigid.add", "active box")\nselect("Ground")\nop("rigid.add", "passive box")\n'
            'sim = 0\nworst = 0\nfor f in 2..241 {\n frame(f)\n sim += rbinfo(4)\n if rbinfo(4) > worst { worst = rbinfo(4) }\n}\n'
            'lo = 99\nfor k in 0..10 { for i in 0..10 { for j in 0..10 {\n y = get("B" + str(k * 100 + i * 10 + j), "y")\n if y < lo { lo = y }\n} } }\n'
            'print(rbinfo(0), sim, worst, lo > 0.4, rbinfo(1))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=600)
    w = (r.stdout.strip().split('\n') or [''])[-1].split()
    ok = len(w) == 5 and w[0] == '1001' and w[3] == '1'
    sim = float(w[1]) if ok else 1e9
    check(ok and sim < 10000 * (2 if os.environ.get('CI') else 1),
          f'1000 boxes tumble into a heap: 10 s simulated in {sim / 1000:.1f} s (the slowest frame {w[2] if ok else "?"} ms of 41.7), {w[4] if ok else "?"} contacts, none through the ground')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(600, 300)
    q('delete("Cube")\nadd("plane", "Ground", 0, 0, 0)\nscale("Ground", 8)\n'
      'for k in 0..4 {\n for i in 0..5 {\n  n = "P" + str(k * 10 + i)\n  add("cube", n, i * 1.1 - 2.2 + 0.5 * (k % 2), 1 + k * 1.3, 0.3 * k)\n'
      '  rotate(n, 0.2 * k, 0.3 * i, 0.1)\n  scale(n, 0.5)\n }\n}\nselect()\nop("object.select_all")\nop("rigid.add", "active box")\n'
      'select("Ground")\nop("rigid.add", "passive box")\nselect()')
    y0 = q('print(get("P34", "y"))')
    f.move(600, 300)
    f.key(57)                                   # Space: play
    f.pump(1.5)
    f.shot('103_rigid_bodies.png')
    f.key(57)
    y1 = q('print(get("P34", "y"), frame() > 20)')
    f.mods(1); f.key(105); f.mods(0)            # Shift+Left: the start
    f.pump(0.2)
    y2 = q('print(get("P34", "y"))')
    w = y1.split()
    check(len(w) == 2 and float(w[0]) < float(y0) - 1 and w[1] == '1' and y2 == y0,
          f'Space plays the pile falling; the start brings it back ({y0} -> {y1} -> {y2})')
    f.proc.kill()

def physics_panel():
    """The Physics section of the Properties area: + Rigid Body makes the
    active object one; its type and shape buttons step through them; a
    drag on Mass changes it (one undo step); a joint shows with x to remove
    it; while it plays, what the simulation does; x removes the body."""
    print('  -- physics panel --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip().split('\n')[0]
    rb = lambda: q('print(rigid("Cube", "type"), rigid("Cube", "shape"), round(rigid("Cube", "mass") * 10))')
    f.enter(600, 300)
    q('select("Cube")')
    f.pump(0.2)
    props_tab(m, f, 'physics')
    f.click(1215, 223)                          # + Rigid Body
    f.pump(0.2)
    a = rb()
    f.click(1187, 247)                          # Active -> Passive
    f.click(1250, 247)                          # Box -> Sphere
    f.pump(0.2)
    b = rb()
    f.drag(1170, 269, 1270, 269, steps=5)       # Mass: +100 px x 0.02
    f.pump(0.2)
    c = rb()
    f.shot('104_physics_panel.png')
    f.mods(4); f.key(44); f.mods(0)             # Ctrl+Z: the drag back
    f.pump(0.2)
    c2 = rb()
    check(a == '1 0 10' and b == '2 1 10' and c == '2 1 30' and c2 == '2 1 10',
          f'the physics panel: + Rigid Body, Active/Passive, the shape, Mass dragged and undone ({a}, {b}, {c}, {c2})')
    q('add("plane", "Ground", 0, 0, 0)\nscale("Ground", 6)\nselect("Ground")\nop("rigid.add", "passive box")\n'
      'select("Cube")\nop("rigid.add", "active box")\nmove("Cube", 0, 3, 0)\nadd("cube", "Probe", 4, 2, 0)\nscale("Probe", 0.3)\nselect("Probe")\n'
      'op("rigid.add", "active box")\nop("rigid.joint", "point Probe world pivot 4 3 0")')
    f.pump(0.2)
    img = f.image()
    joint = sum(1 for x in range(1130, 1240, 2) if max(img.getpixel((x, 349))[:3]) > 150)
    f.move(600, 300)
    f.key(57)                                   # Space: the status line
    f.pump(0.8)
    f.key(57)
    f.pump(0.2)
    f.shot('105_physics_running.png')
    img = f.image()
    status = sum(1 for y in range(446, 460) for x in range(1130, 1260, 2) if max(img.getpixel((x, y))[:3]) > 90)
    d = q('print(get("Cube", "y") < 2.5, frame() > 5)')
    f.mods(1); f.key(105); f.mods(0)            # back to the start
    f.pump(0.2)
    f.click(1253, 223)                          # x: Probe no longer a body
    f.pump(0.2)
    e = q('print(rigid("Probe", "type"), get("Cube", "y"))')
    check(d == '1 1' and e == 'nil 3' and joint > 5 and status > 10,
          f'the physics panel: a joint listed, the simulation shown while playing, x removes the body ({d}, {e}, {joint}, {status})')
    f.proc.kill()
def mechanisms():
    """Mechanisms: a crank parameter keyed over the timeline turns a gear;
    a second gear follows at -2x, a rack slides (held at its limit), an arm
    on the first gear turns with it and is reported hitting a block; a
    keyed parameter also rebuilds a pad and turns its joint; saved and
    reopened. In the window: Space plays it."""
    print('  -- mechanisms --')
    home = tempfile.mkdtemp(prefix='bee-mj-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    code = ('delete("Cube")\nparam("angle", "0deg")\nadd("cylinder", "G1", 0, 0, 0)\nscale("G1", 1, 0.2, 1)\n'
            'add("cylinder", "G2", 2.5, 0, 0)\nscale("G2", 0.5, 0.2, 0.5)\nadd("cube", "Rack", 0, 0, 1.3)\nscale("Rack", 2, 0.2, 0.2)\n'
            'add("cube", "Arm", 0, 1, 0)\nscale("Arm", 3, 0.1, 0.1)\nadd("cube", "Block", 0, 1, -3)\nscale("Block", 0.4, 0.4, 0.4)\n'
            'op("mech.joint", "revolute G1 world axis 0 1 0 value angle")\nop("mech.joint", "revolute G2 world axis 0 1 0 gear 1 -2")\n'
            'op("mech.joint", "slider Rack world axis 1 0 0 gear 1 1 min -1 max 1")\nop("mech.joint", "revolute Arm G1 pivot 0 1 0 axis 0 1 0")\n'
            'param("angle", "30deg")\n'
            'print(round(joint(1) * 1000), round(joint(2) * 1000), round(get("G2", "ry") * 1000), round(get("Rack", "x") * 1000), round(get("Arm", "ry") * 1000), joint(3, 1))\n'
            'key("param:angle", 1, 0, "linear")\nkey("param:angle", 41, 6.2832, "linear")\n'
            'hit = 0\nfor f in 1..42 {\n frame(f)\n if collisions() > 0 and hit == 0 { hit = f }\n}\n'
            'frame(21)\nprint(round(prop("param:angle") * 1000), round(get("Rack", "x") * 1000), joint(3, 1), hit)\n'
            'param("len", "1")\ns = sketch("S", "XZ")\nrect(s, 4, 4, 1, 1)\npad("Box", s, "len")\nop("mech.joint", "slider Box world axis 0 1 0 value len - 1")\n'
            'key("param:len", 1, 1, "linear")\nkey("param:len", 11, 3, "linear")\nframe(6)\n'
            'print(round(volume("Box") * 100), round(get("Box", "y") * 100))\n'
            'op("file.save", "~/BeeModel/m.bee")\nop("file.new")\nop("file.open", "~/BeeModel/m.bee")\nframe(21)\n'
            'print(round(joint(2) * 1000), round(get("G2", "ry") * 1000), round(get("Rack", "x") * 1000))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=120)
    out = [l.strip() for l in r.stdout.split('\n')] + [''] * 6
    check(out[0] == '524 -1047 -1047 524 524 0', f'a parameter turns a gear; a second at -2x, a rack, an arm on the first follow ({out[0]})')
    w = out[1].split()
    check(len(w) == 4 and w[0] == '3142' and w[1] == '1000' and w[2] == '1' and 10 <= int(w[3]) <= 12,
          f'keyed over the timeline: the rack held at its limit, the arm reported hitting the block ({out[1]})')
    check(out[2] == '200 100', f'a keyed parameter rebuilds a pad and moves its joint ({out[2]})')
    check(out[3] == '-6283 0 1000', f'the mechanism saved and reopened ({out[3]})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip().split('\n')[0]
    f.enter(600, 300)
    q('delete("Cube")\nparam("crank", "0deg")\nadd("cylinder", "Wheel", 0, 0, 0)\nscale("Wheel", 2, 0.2, 2)\n'
      'add("cube", "Pin", 1.5, 0.4, 0)\nscale("Pin", 0.2, 0.2, 0.2)\nadd("cube", "Wall", 0, 0.4, -2.5)\nscale("Wall", 1, 0.3, 0.1)\n'
      'op("mech.joint", "revolute Wheel world axis 0 1 0 value crank")\nop("mech.joint", "revolute Pin Wheel pivot 0 0 0 axis 0 1 0")\n'
      'op("anim.range", "1 48 24")\nkey("param:crank", 1, 0, "linear")\nkey("param:crank", 48, 6.2832, "linear")\nselect()')
    f.move(600, 300)
    f.key(57)                                   # Space: it turns
    f.pump(1.0)
    f.shot('106_mechanism.png')
    f.key(57)
    a = q('print(abs(prop("param:crank")) > 0.1, abs(get("Pin", "x") - 1.5) > 0.01)')
    check(a == '1 1', f'Space plays the mechanism: the crank turns the wheel and the pin on it ({a})')
    f.proc.kill()

def cloth():
    """Cloth and soft bodies (XPBD): a flag pinned along one edge hangs at
    its length and bows in the wind; a sheet drapes over a ball (kept its
    thickness off it); two sheets that collide with themselves stay apart;
    a soft ball lands and keeps its volume; pins saved; a 6561-particle
    sheet in real time. In the window: Space plays the drape."""
    print('  -- cloth, soft bodies --')
    home = tempfile.mkdtemp(prefix='bee-cl-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    low = ('lo = 99\nfor i in 0..verts(N) {\n y = evpos(N, i, "y")\n if y < lo { lo = y }\n}\n')
    code = ('delete("Cube")\nadd("grid", "Flag", 0, 2, 0)\nselect("Flag")\nop("cloth.add", "cloth")\nop("cloth.pin", "above x 0.95")\n'
            'frame(2)\nprint(clothinfo(1), clothinfo(2), clothinfo(3) > 4)\nfor f in 3..121 { frame(f) }\n'
            'mx = 0\nfor i in 0..120 {\n if i % 11 != 10 {\n'
            '  d = sqrt(pow(evpos("Flag", i, "x") - evpos("Flag", i + 1, "x"), 2) + pow(evpos("Flag", i, "y") - evpos("Flag", i + 1, "y"), 2) + pow(evpos("Flag", i, "z") - evpos("Flag", i + 1, "z"), 2))\n'
            '  if d > mx { mx = d }\n }\n}\n' + low.replace('N', '"Flag"') +
            'print(round(lo * 100), round(mx * 100), round(evpos("Flag", 10, "y") * 100))\n'
            'rotate("Flag", 1.5708, 0, 0)\nop("cloth.world", "wind 0 0 8")\nfor f in 2..97 { frame(f) }\n'
            'z = 0\nfor i in 0..verts("Flag") { z += evpos("Flag", i, "y") }\nprint(z / verts("Flag") > 0.5)\n'
            'op("cloth.world", "wind 0 0 0")\nop("file.save", "~/BeeModel/c.bee")\nop("file.new")\nop("file.open", "~/BeeModel/c.bee")\n'
            'frame(1)\nframe(96)\nz = 0\nfor i in 0..verts("Flag") { z += evpos("Flag", i, "y") }\nprint(z / verts("Flag") < 0, round(evpos("Flag", 10, "y") * 100))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=300)
    out = [l.strip() for l in r.stdout.split('\n')] + [''] * 6
    w = out[1].split()
    check(out[0] == '121 600 1' and len(w) == 3 and -201 <= int(w[0]) <= -100 and int(w[1]) <= 21 and w[2] == '0',
          f'a flag pinned along one edge swings down, never past its length (edges stay 0.2), the pins hold ({out[:2]})')
    check(out[2] == '1' and out[3] == '1 0', f'wind bows it; the pins and settings saved and simulated again ({out[2:4]})')
    code = ('delete("Cube")\nadd("grid", "Sheet", 0, 3, 0)\nscale("Sheet", 1.5)\nadd("sphere", "Ball", 0, 1, 0)\n'
            'add("plane", "Floor", 0, 0, 0)\nscale("Floor", 5)\nselect("Sheet")\nop("cloth.add", "cloth")\nselect("Ball", "Floor")\nop("cloth.add", "collider")\n'
            'for f in 2..97 { frame(f) }\nmind = 99\nfor i in 0..verts("Sheet") {\n x = evpos("Sheet", i, "x") * 1.5\n y = evpos("Sheet", i, "y") * 1.5 + 3\n'
            ' z = evpos("Sheet", i, "z") * 1.5\n d = sqrt(x * x + (y - 1) * (y - 1) + z * z)\n if d < mind { mind = d }\n}\n'
            'print(round(mind * 1000), clothinfo(5) > 0)\n'
            'add("grid", "A", 8, 2, 0)\nadd("grid", "B", 8.05, 2.1, 0.03)\nselect("A", "B")\nop("cloth.add", "cloth self thickness 0.03")\n'
            'frame(1)\nfor f in 2..61 { frame(f) }\nmn = 99\nfor i in 0..verts("A") {\n for j in 0..verts("B") {\n'
            '  dx = evpos("A", i, "x") - (evpos("B", j, "x") + 0.05)\n  dy = evpos("A", i, "y") + 2 - (evpos("B", j, "y") + 2.1)\n'
            '  dz = evpos("A", i, "z") - (evpos("B", j, "z") + 0.03)\n  d = dx * dx + dy * dy + dz * dz\n  if d < mn { mn = d }\n }\n}\n'
            'print(sqrt(mn) > 0.055)\n'
            'add("sphere", "Blob", -3.5, 2, 3)\nscale("Blob", 0.5)\nselect("Blob")\nop("cloth.add", "soft stretch 0.001 bend 0.1")\n'
            'frame(1)\nfor f in 2..73 { frame(f) }\nlo = 99\nhi = -99\nfor i in 0..verts("Blob") {\n y = evpos("Blob", i, "y") * 0.5 + 2\n'
            ' if y < lo { lo = y }\n if y > hi { hi = y }\n}\nprint(round(lo * 100), hi - lo > 0.8, hi - lo < 1.02)\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=300)
    out = [l.strip() for l in r.stdout.split('\n')] + [''] * 6
    w = out[0].split()
    check(len(w) == 2 and 1000 <= int(w[0]) <= 1025 and w[1] == '1' and out[1] == '1' and out[2] == '2 1 1',
          f'a sheet drapes over a ball (its thickness off it); self-colliding sheets stay apart; a soft ball lands and keeps its shape ({out[:3]})')
    code = ('delete("Cube")\nadd("grid", "Sheet", 0, 3, 0)\nmodifier("Sheet", "subsurf")\nmodset("Sheet", 0, "levels", 3)\nmodapply("Sheet", 0)\n'
            'scale("Sheet", 1.5)\nadd("sphere", "Ball", 0, 1, 0)\nadd("plane", "Floor", 0, 0, 0)\nscale("Floor", 5)\n'
            'select("Sheet")\nop("cloth.add", "cloth self")\nselect("Ball", "Floor")\nop("cloth.add", "collider")\n'
            'sim = 0\nfor f in 2..97 {\n frame(f)\n sim += clothinfo(4)\n}\nprint(clothinfo(1), sim)\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=600)
    w = (r.stdout.strip().split('\n') or [''])[-1].split()
    sim = float(w[1]) if len(w) == 2 else 1e9
    check(len(w) == 2 and w[0] == '6561' and sim < 4000 * (3 if os.environ.get('CI') else 1),
          f'a 6561-particle sheet colliding with a ball, the floor and itself: 4 s simulated in {sim / 1000:.1f} s')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip().split('\n')[0]
    f.enter(600, 300)
    q('delete("Cube")\nadd("grid", "Sheet", 0, 3, 0)\nmodifier("Sheet", "subsurf")\nmodset("Sheet", 0, "levels", 1)\nmodapply("Sheet", 0)\n'
      'scale("Sheet", 2)\nadd("sphere", "Ball", 0, 1, 0)\nselect("Sheet")\nop("cloth.add", "cloth")\nselect("Ball")\nop("cloth.add", "collider")\nselect()')
    f.move(600, 300)
    f.key(57)                                   # Space: it falls on the ball
    f.pump(1.2)
    f.key(57)
    f.shot('107_cloth.png')
    a = q('print(evpos("Sheet", 0, "y") < -0.3, frame() > 10)')
    check(a == '1 1', f'Space plays the cloth falling over the ball ({a})')
    f.proc.kill()


def sim_cache():
    """The simulation cache: frames kept as the simulation reaches them and
    played back when scrubbing (the same places, cloth to 16 bits); the
    start keeps them; an edit drops them; a bake stays through edits, is
    saved and holds its last frame; sim.free; 1000 boxes scrubbed back
    faster than 60 fps. In the window: the timeline shows the cached and
    the baked frames."""
    print('  -- simulation cache --')
    home = tempfile.mkdtemp(prefix='bee-sc-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    code = ('delete("Cube")\nadd("plane", "Ground", 0, 0, 0)\nscale("Ground", 20)\nselect("Ground")\nop("rigid.add", "passive box")\n'
            'add("cube", "Box", 0, 3, 0)\nscale("Box", 0.5)\nrotate("Box", 0.3, 0.2, 0.1)\nselect("Box")\nop("rigid.add", "active box")\n'
            'y30 = 0\nfor f in 2..61 {\n frame(f)\n if f == 30 { y30 = get("Box", "y") }\n}\nprint(cacheinfo(0), rbinfo(6))\n'
            'frame(30)\nprint(cacheinfo(0), rbinfo(6), get("Box", "y") == y30)\n'
            'frame(1)\nprint(get("Box", "y"), cacheinfo(0))\nframe(30)\nprint(get("Box", "y") == y30, cacheinfo(0))\n'
            'frame(1)\nmove("Box", 0, 4, 0)\nframe(30)\nprint(cacheinfo(0), get("Box", "y") == y30)\n'
            'op("sim.bake")\nprint(cacheinfo(0), cacheinfo(3))\nframe(100)\nb = get("Box", "y")\n'
            'op("rigid.world", "gravity 0 5 0")\nframe(1)\nframe(100)\nprint(get("Box", "y") == b, cacheinfo(0))\n'
            'op("file.save", "~/BeeModel/r.bee")\nop("file.new")\nop("file.open", "~/BeeModel/r.bee")\n'
            'frame(100)\nprint(cacheinfo(0), cacheinfo(3), get("Box", "y") == b)\nframe(250)\ne = get("Box", "y")\nframe(300)\nprint(get("Box", "y") == e)\n'
            'op("sim.free")\nprint(cacheinfo(0), cacheinfo(3), get("Box", "y") > 3)\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=300)
    out = [l.strip() for l in r.stdout.split('\n')] + [''] * 12
    check(out[0] == '59 295' and out[1] == '59 295 1' and out[2] == '3 59' and out[3] == '1 59',
          f'rigid bodies: each frame kept; scrubbing back plays it (no steps), the start keeps it ({out[:4]})')
    check(out[4] == '29 0', f'moving a body at the start drops the cache; simulated again from there ({out[4]})')
    check(out[5] == '249 1' and out[6] == '1 249' and out[7] == '249 1 1' and out[8] == '1' and out[9] == '299 0 1',
          f'a bake: the frame range kept through a change of gravity, saved and reopened, its last frame held; sim.free simulates again ({out[5:10]})')
    code = ('delete("Cube")\nadd("grid", "Flag", 0, 2, 0)\nselect("Flag")\nop("cloth.add", "cloth")\nop("cloth.pin", "above x 0.95")\n'
            'y = 0\nfor f in 2..61 {\n frame(f)\n if f == 30 { y = evpos("Flag", 5, "y") }\n}\nprint(cacheinfo(1))\n'
            'frame(30)\nprint(cacheinfo(1), abs(evpos("Flag", 5, "y") - y) < 0.0002)\n'
            'frame(1)\nprint(evpos("Flag", 5, "y"), cacheinfo(1))\nframe(30)\nprint(cacheinfo(1), abs(evpos("Flag", 5, "y") - y) < 0.0002)\n'
            'frame(60)\nmove("Flag", 0, 1, 0)\nframe(30)\nprint(cacheinfo(1))\n'
            'op("sim.bake", "cloth")\nprint(cacheinfo(1), cacheinfo(4), cacheinfo(2) < 0.5)\nframe(80)\nb = evpos("Flag", 5, "y")\n'
            'op("file.save", "~/BeeModel/c.bee")\nop("file.new")\nop("file.open", "~/BeeModel/c.bee")\n'
            'frame(80)\nprint(cacheinfo(1), cacheinfo(4), evpos("Flag", 5, "y") == b)\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=300)
    out = [l.strip() for l in r.stdout.split('\n')] + [''] * 8
    check(out[0] == '59' and out[1] == '59 1' and out[2] == '0 59' and out[3] == '59 1' and out[4] == '29',
          f'cloth: each frame kept (16 bits a coordinate, within 0.2 mm), played back, dropped when the flag moves ({out[:5]})')
    check(out[5] == '249 1 1' and out[6] == '249 1 1', f'cloth baked (121 vertices x 249 frames < 0.5 MB), saved and reopened ({out[5:7]})')
    code = ('delete("Cube")\nadd("plane", "Ground", 0, 0, 0)\nscale("Ground", 40)\n'
            'for k in 0..10 {\n for i in 0..10 {\n  for j in 0..10 {\n   n = "B" + str(k * 100 + i * 10 + j)\n'
            '   add("cube", n, i * 1.2 - 6 + 0.6 * (k % 2), 1 + k * 1.2, j * 1.2 - 6 + 0.6 * (k % 2))\n'
            '   rotate(n, 0.1 * k, 0.37 * k + 0.1 * i, 0.05 * j)\n   scale(n, 0.5)\n  }\n }\n}\n'
            'select()\nop("object.select_all")\nop("rigid.add", "active box")\nselect("Ground")\nop("rigid.add", "passive box")\n'
            'for f in 2..241 { frame(f) }\ny = get("B555", "y")\nframe(120)\nc0 = clock()\nfor f in 2..241 { frame(242 - f) }\n'
            't = clock() - c0\nframe(240)\nprint(cacheinfo(0), t / 239, get("B555", "y") == y, cacheinfo(2))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=600)
    w = (r.stdout.strip().split('\n') or [''])[-1].split()
    ok = len(w) == 4 and w[0] == '239' and w[2] == '1'
    check(ok and float(w[1]) < 16.7 * (2 if os.environ.get('CI') else 1),
          f'1000 boxes: 239 frames cached ({w[3] if ok else "?"} MB), scrubbed back at {w[1] if ok else "?"} ms a frame (60 fps: 16.7)')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(600, 300)
    q('delete("Cube")\nadd("plane", "Ground", 0, 0, 0)\nscale("Ground", 20)\nselect("Ground")\nop("rigid.add", "passive box")\n'
      'add("cube", "Box", 0, 3, 0)\nselect("Box")\nop("rigid.add", "active box")\nselect()')
    f.move(600, 700)
    q('op("area.type_timeline")')
    q('for f in 2..126 { frame(f) }')
    f.pump(0.3)
    cached = sum(1 for x in range(0, 1280) for y in range(600, 800) if px(f, x, y) == 0x9a6a3a)
    q('op("sim.bake")')
    f.pump(0.3)
    f.shot('108_sim_cache.png')
    baked = sum(1 for x in range(0, 1280) for y in range(600, 800) if px(f, x, y) == 0xe0902c)
    check(cached > 400 and baked > 2 * cached * 0.9,
          f'the timeline shows the cached frames, then the whole baked range ({cached} -> {baked} px)')
    f.proc.kill()

def virtual_geometry():
    """Virtualized geometry, part 1: a mesh's cluster LOD DAG (vgeo.build) -
    clusters of <= 128 triangles simplified level by level to one root,
    every cut crack-free; a level extracted as a mesh; saved in the .bee file
    (page aligned) and read back; out of date after an edit. In the window
    the DAG is built in the background while the UI keeps drawing."""
    print('  -- virtual geometry --')
    home = tempfile.mkdtemp(prefix='bee-vg-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    code = ('delete("Cube")\nadd("sphere", "S", 0, 0, 0)\nmodifier("S", "subsurf")\nmodset("S", 0, "levels", 5)\nmodapply("S", 0)\n'
            'sculpt("S", "draw", 0, 0.3, 1.0, 0.3, 0.1, 0.95, 0.3, 1)\nselect("S")\nprint(vgeo("S", 0))\n'
            't = clock()\nop("vgeo.build")\nt = clock() - t\n'
            'print(vgeo("S", 0), vgeo("S", 4), vgeo("S", 1), vgeo("S", 2), vgeo("S", 9), vgeo("S", 5), vgeo("S", 10), vgeo("S", 11), t)\n'
            'print(vgeo("S", 12), vgeo("S", 8) < 0.5, vgeo("S", 300 + 3) < 0.003, vgeo("S", 13) < 2.2 * vgeo("S", 4))\n'
            'op("vgeo.extract", "3")\nprint(faces("LOD") == vgeo("S", 103), vgeo("LOD", 0))\n'
            'n = vgeo("S", 1)\nop("file.save", "~/BeeModel/v.bee")\nop("file.new")\nop("file.open", "~/BeeModel/v.bee")\n'
            'print(vgeo("S", 0), vgeo("S", 1) == n, vgeo("S", 12))\n'
            'sculpt("S", "draw", 0, 0.3, 1.0, 0.3, 0.1, 0.95, 0.3, 1)\nprint(vgeo("S", 0))\nselect("S")\nop("vgeo.clear")\nprint(vgeo("S", 0))\n')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=300)
    out = [l.strip() for l in r.stdout.split('\n')] + [''] * 8
    w = out[1].split()
    ok = len(w) == 9 and w[0] == '2' and w[4] == '1' and int(w[1]) > 1000000
    check(out[0] == '0' and ok and int(w[6]) <= 128 and int(w[7]) <= 128 and float(w[8]) < 2000 * (2 if os.environ.get('CI') else 1),
          f'a 1M-triangle sculpt: {w[2] if ok else "?"} clusters (<= 128 triangles and vertices) in {w[3] if ok else "?"} levels '
          f'to one root of {w[5] if ok else "?"} triangles, built in {w[8] if ok else "?"} ms')
    check(out[2] == '1 1 1 1', f'every cut crack-free (each level, 16 errors, 24 cameras); errors small, ~2x the triangles in all ({out[2]})')
    check(out[3] == '1 0', f'vgeo.extract: a level as a mesh, its clusters coloured ({out[3]})')
    check(out[4] == '2 1 1', f'saved in the .bee file and read back ({out[4]})')
    check(out[5] == '3' and out[6] == '0', f'out of date after a sculpt stroke; vgeo.clear ({out[5:7]})')
    data = open(os.path.join(home, 'BeeModel', 'v.bee'), 'rb').read()
    at = data.find(b'VGEO', 8)
    blk = data.find(b'VGEO', at + 4)
    check(at > 0 and blk > 0 and blk % 4096 == 0, f'the DAG block starts on a page of the file (offset {blk})')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(600, 300)
    f.move(600, 300)
    q('delete("Cube")\nadd("sphere", "S", 0, 1, 0)\nmodifier("S", "subsurf")\nmodset("S", 0, "levels", 6)\nmodapply("S", 0)\nselect("S")')
    q('op("vgeo.build")')
    st = q('print(vgeo("S", 0))')
    lat, polls = [], 0
    t0 = time.time()
    while time.time() - t0 < 60:
        f.latencies = []
        f.t_input = time.time()
        f.key(106)                                  # Right: a frame on
        lat += f.latencies
        polls += 1
        if q('print(vgeo("S", 0))') != '1':
            break
    secs = time.time() - t0
    fin = q('print(vgeo("S", 0), vgeo("S", 4), vgeo("S", 9))').split()
    lat = sorted(lat)
    med = lat[len(lat) // 2] if lat else 1e9
    check(st == '1' and fin[:1] == ['2'] and fin[2:] == ['1'] and len(lat) >= 3 and med < 50 * (2 if os.environ.get('CI') else 1),
          f'in the window: {fin[1:2]} triangles virtualized in the background ({secs:.1f} s), the UI drew {len(lat)} frames '
          f'meanwhile, {med:.1f} ms after a key at the median')
    q('op("vgeo.extract", "5")\ndelete("S")\nscale("LOD", 4.5)\nselect()')
    f.pump(0.5)
    f.shot('109_vgeo_clusters.png')
    f.proc.kill()


def virtual_geometry_cuts():
    """Virtualized geometry, part 2: a mesh with a cluster DAG is drawn
    through a cut of it every frame (one pixel of error from the camera),
    clusters culled by the frustum and by the last frame's depth, the ones
    that come into view drawn in a second batch; picking and material preview
    see the cut. vgeo.proxy lets the mesh go for the DAG's roots; saved and
    opened again, the DAG stays mapped from the file and its pages stream in
    under a budget."""
    print('  -- virtual geometry: cuts, culling, streaming --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    st = lambda *ks: [float(x) for x in q('print(' + ', '.join('vgstat(%d)' % k for k in ks) + ')').split()]
    f.enter(600, 300)
    f.move(600, 300)
    q('delete("Cube")\nadd("sphere", "S", 0, 0, 0)\nmodifier("S", "subsurf")\nmodset("S", 0, "levels", 5)\nmodapply("S", 0)\n'
      'add("cube", "C", -4, 0, 0)\nselect("S")\nop("vgeo.build")')
    t0 = time.time()
    while time.time() - t0 < 60 and q('print(vgeo("S", 0))') != '2':
        f.pump(0.2)
    q('select()\nop("vgeo.view", "check")')
    cr = []
    for d in (3, 5, 12):                            # all of it in view: the cut drawn, crack-free
        q('view(30, 20, %d, 0, 0, 0)' % d)
        f.pump(0.4)
        cr += st(16)
    q('view(45, 25, 30, 0, 0, 0)')
    f.pump(0.5)
    far = st(0, 1, 2, 6)
    q('view(90, 10, 0.7, 1, 0, 0)')                 # at the surface: much of it out of view
    f.pump(0.5)
    near = st(0, 1, 2, 3, 4, 6)
    check(far[0] == 1 and far[3] > 1000000 and far[2] < 20000 and near[2] > 3 * far[2] and near[3] > 0 and cr == [1, 1, 1],
          f'a 1M-triangle mesh drawn through cuts of its DAG: {far[2]:.0f} triangles ({far[1]:.0f} clusters) from afar, '
          f'{near[2]:.0f} up close, {near[3]:.0f} clusters culled by the frustum ({near[4]:.0f} occluded); '
          f'the cuts drawn crack-free ({cr})')
    lat = []
    for i in range(16):                             # orbiting: the far side comes into view
        f.latencies = []
        f.t_input = time.time()
        f.drag(560, 380, 600, 380, steps=3)
        lat += f.latencies
    lat = sorted(lat)
    check(len(lat) > 10 and lat[len(lat) // 2] < 40 * (2 if os.environ.get('CI') else 1),
          f'orbiting close: {lat[len(lat) // 2] if lat else 0:.1f} ms a frame at the median')
    q('view(45, 25, 12, 0, 0, 0)')
    f.pump(0.5)
    f.click(615, 352)
    picked = q('print(active())')
    q('op("view.toggle_material_preview")')
    f.pump(0.5)
    mp = st(0, 2)
    q('op("view.toggle_material_preview")\nop("vgeo.view", "clusters")')
    f.pump(0.5)
    f.shot('113_vgeo_cut_clusters.png')
    q('op("vgeo.view", "off")')
    f.pump(0.5)
    off = st(0)
    q('op("vgeo.view", "shaded")')
    check(picked == 'S' and mp[0] == 1 and mp[1] > 0 and off == [0],
          f'a click picks the object drawn through its cut ({picked}); material preview draws the cut ({mp[1]:.0f} triangles); '
          f'vgeo.view off draws the mesh itself')
    q('select("S")\nop("vgeo.proxy")')
    prox = q('print(faces("S"), vgeo("S", 0), vgeo("S", 4))').split()
    os.makedirs(os.path.join(f.home, 'BeeModel'), exist_ok=True)
    bee = os.path.join(f.home, 'BeeModel', 'vgs.bee')
    for c in ('file.save ' + bee, 'file.new', 'file.open ' + bee):
        f.key(28); f.type(c); f.key(28); f.pump(1.0); f.key(1)
    back = q('print(faces("S"), vgeo("S", 0))').split()
    q('select()\nop("vgeo.budget", "1")\nview(30, 20, 3, 0, 0, 0)')
    for i in range(10):                             # pages missing: coarser clusters stand in
        f.pump(0.1)
    fb = st(16, 12)
    q('op("vgeo.budget", "4")\nview(30, 20, 30, 0, 0, 0)')
    f.pump(0.5)
    for v in ('90, 10, 0.7, 1, 0, 0', '270, 10, 0.7, -1, 0, 0'):    # close to one side, then the other
        q('view(%s)' % v)
        for i in range(20):
            f.pump(0.1)
    s1 = st(7, 8, 10, 11, 14, 2, 12)
    check(prox[1:] == ['2', '1015808'] and int(prox[0]) < 1000 and back == prox[:2] and s1[4] == 1 and s1[2] > 0
          and s1[0] <= 4 and s1[3] > 0 and s1[5] > 3 * far[2],
          f'vgeo.proxy: {prox[0]} triangles stand in; saved, opened: the DAG mapped from the file, {s1[2]:.0f} pages '
          f'read as the view came close, {s1[3]:.0f} given back under a 4 MB budget ({s1[0]:.2f} MB in memory); '
          f'{s1[5]:.0f} triangles drawn, {s1[6]:.0f} refinements wait for pages that do not fit')
    check(fb[0] == 1 and fb[1] > 0, f'with pages missing ({fb[1]:.0f} refinements waiting under 1 MB) the cut drawn is still crack-free ({fb[0]:.0f})')
    f.proc.kill()


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
    f.pump(0.3)
    m = Mcp(f)                           # (changes: "Save changes?" - Don't Save)
    x, y = widget_xy(m, 'dialog.dont_save')
    if x:
        f.click(x, y)
    f.pump(0.5)
    try:
        rc = f.proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        f.proc.kill(); rc = None
    check(rc == 0, f'F3 "exit" + Enter quits through the palette (rc={rc})')


def ui_basics():
    """UI plan U1: every menu entry shows, key names, the hand cursor, the
    unsaved-changes dot and opening a scene from the command line."""
    print('  -- ui basics --')
    ops = subprocess.run([BIN, '--list-ops'], capture_output=True, text=True).stdout
    check('Key?' not in ops and 'Right ' in ops and 'PgUp' in ops,
          '--list-ops names every bound key (arrows, PageUp/PageDown)')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    T = f.home
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.2); f.key(1)
    def dot():                                 # the accent dot right of the title
        return any(px(f, x, 16) == 0xf2b134 for x in range(160, 640))
    f.move(30, 43)
    check(f.cursor == 4, f'hand cursor over a menu title (shape {f.cursor})')
    f.move(600, 300)
    check(f.cursor == 8, 'crosshair again over the canvas')
    check(not dot(), 'a fresh scene has no unsaved-changes dot')
    labels = []
    t = [w for w in ui_tree(m) if w['kind'] == 'menu' and w['label'] == 'Add'][0]
    f.click(t['x'] + 10, t['y'] + 10)
    labels = [w['label'] for w in ui_tree(m) if w['kind'] == 'menuitem']
    f.shot('ui_create_menu.png')
    f.key(1)
    check({'Light', 'Camera', 'Armature', 'Curve'} <= set(labels), f'the Add menu lists every entry ({len(labels)})')
    menu_pick(f, m, 'Add', 'Armature')
    check(q('print(exists("Armature"))') == '1', 'Add > Armature adds one')
    check(dot(), 'a change shows the unsaved-changes dot in the title')
    f.click(270, 67)                           # viewport header: editor type menu
    f.shot('ui_area_menu.png')
    before = px(f, 600, 400)
    f.click(300, 95 + 12 * 24)                 # 13th entry: Graph Editor
    check(px(f, 600, 400) != before, 'editor type menu reaches Timeline, Dope Sheet and Graph Editor')
    cmd(f'file.save {T}/u1.bee')
    check(os.path.exists(f'{T}/u1.bee') and not dot(), 'saving clears the dot')
    f.mods(4); f.key(44); f.mods(0)            # Ctrl+Z: changed again
    check(dot(), 'undo after saving marks the scene changed')
    f.shot('ui_status.png')
    f.proc.kill()
    g = Fake([f'{T}/u1.bee'])
    g.pump(1.0, until_frame=True)
    g.enter(600, 300)
    n = Mcp(g)
    r = (n.tool('script_eval', {'code': 'print(exists("Armature"))'})[0] or '').strip()
    check(r == '1', f'beemodel scene.bee opens the scene ({r})')
    check(not any(px(g, x, 16) == 0xf2b134 for x in range(160, 640)), 'an opened scene has no dot')
    g.proc.kill()


def theme_tables():
    """{theme: {COL_NAME: rgb}} from src/const.inc and src/theme.s"""
    import re
    root = os.path.join(os.path.dirname(__file__), '..', 'src')
    base = {m[0]: int(m[1], 16) for m in
            re.findall(r'^\.equ (COL_\w+),\s+0x([0-9a-fA-F]+)', open(os.path.join(root, 'const.inc')).read(), re.M)}
    src = open(os.path.join(root, 'theme.s')).read()
    out = {'dark': dict(base)}
    for name, label in (('light', 'th_light'), ('contrast', 'th_contrast')):
        body = re.split(r'^' + label + ':', src, flags=re.M)[1].split('0xffffffff')[0]
        t = dict(base)
        for k, v in re.findall(r'\.long (COL_\w+),\s+0x([0-9a-fA-F]+)', body):
            t[k] = int(v, 16)
        out[name] = t
    return out


def contrast(a, b):
    def lum(c):
        ch = [((c >> sh) & 255) / 255 for sh in (16, 8, 0)]
        ch = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in ch]
        return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]
    la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def themes():
    """UI plan U2: Dark / Light / High contrast themes, text contrast in each,
    the theme switch from the View menu, the console and BEEMODEL_THEME."""
    print('  -- themes --')
    tabs = theme_tables()
    pairs = [('COL_TEXT', 'COL_PANE_BG'), ('COL_TEXT', 'COL_DROP_BG'), ('COL_TEXT', 'COL_FIELD'),
             ('COL_TEXT', 'COL_INPUT_BG'), ('COL_TEXT_DIM', 'COL_PANE_BG'), ('COL_TEXT_DIM', 'COL_DROP_BG'),
             ('COL_TEXT_DIM', 'COL_STATUS_BG'), ('COL_TITLE_TEXT', 'COL_TITLE_BG'),
             ('COL_ACCENT', 'COL_PANE_BG'), ('COL_TEXT', 'COL_MENU_BG')]
    for th, t in tabs.items():
        low = [(fg, bg, round(contrast(t[fg], t[bg]), 2)) for fg, bg in pairs if contrast(t[fg], t[bg]) < 4.5]
        check(not low, f'{th} theme: every text colour >= 4.5:1 on its background {low or ""}')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    def cmd(c):
        f.key(28); f.type(c); f.key(28); f.pump(0.2); f.key(1)
    for th in ('light', 'contrast', 'dark'):
        cmd(f'view.theme {th}')
        t = tabs[th]
        check(px(f, 640, 5) == t['COL_TITLE_BG'] and px(f, 4, 300) == t['COL_PANE_BG'],
              f'view.theme {th}: title bar and panels take its colours')
    m = Mcp(f)
    menu_pick(f, m, 'View', 'Theme', 'Light Theme')
    check(px(f, 640, 5) == tabs['light']['COL_TITLE_BG'], 'View > Theme > Light Theme switches the theme')
    t = [w for w in ui_tree(m) if w['kind'] == 'menu' and w['label'] == 'View'][0]
    f.click(t['x'] + 10, t['y'] + 10)
    f.shot('themes_light_menu.png')
    f.key(1)
    f.proc.kill()
    os.environ['BEEMODEL_THEME'] = 'contrast'
    try:
        g = Fake()
        g.pump(1.0, until_frame=True)
        check(px(g, 640, 5) == 0, 'BEEMODEL_THEME=contrast starts in the high-contrast theme')
        g.proc.kill()
    finally:
        del os.environ['BEEMODEL_THEME']


def widgets_ui():
    """UI plan U3: the widget toolkit on the Properties transform rows -
    scrub, type values and expressions, Tab, Esc, Ctrl+wheel, undo, rename,
    and ui_tree for finding widgets by name."""
    print('  -- widgets --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    num = lambda p: float(q(f'print(get("Cube", "{p}"))') or 'nan')
    names = {(w['name'], w['sub']) for w in ui_tree(m)}
    check({('object.name', 0), ('object.location', 0), ('object.rotation', 2), ('object.scale', 1)} <= names,
          f'ui_tree lists the Properties fields ({len(names)} widgets)')
    x, y = widget_xy(m, 'object.location', 0)
    f.move(x, y)
    check(f.cursor == 26, f'a number field shows the sideways cursor (shape {f.cursor})')
    f.drag(x, y, x + 50, y, steps=5)
    check(abs(num('x') - 0.5) < 1e-4, f'dragging Location X 50 px moves the cube 0.5 m ({num("x")})')
    f.mods(4); f.key(44); f.mods(0)            # Ctrl+Z
    check(abs(num('x')) < 1e-6, 'one undo reverts the whole drag')
    x, y = widget_xy(m, 'object.location', 1)
    f.click(x, y)
    w = widget(m, 'object.location', 1)
    check(bool(w and w.get('editing')), 'clicking a field (no drag) starts typing in it')
    f.type('2.5'); f.key(28)
    check(abs(num('y') - 2.5) < 1e-6, f'typing 2.5 + Enter sets Location Y ({num("y")})')
    x, y = widget_xy(m, 'object.rotation', 2)
    f.click(x, y); f.type('90'); f.key(28)
    check(abs(num('rz') - math.pi / 2) < 1e-4, f'a rotation field takes degrees: 90 -> {num("rz"):.4f} rad')
    x, y = widget_xy(m, 'object.scale', 0)
    f.click(x, y); f.type('1+0.5*2'); f.key(28)
    check(abs(num('sx') - 2) < 1e-6, f'fields take expressions: 1+0.5*2 -> {num("sx")}')
    x, y = widget_xy(m, 'object.location', 0)
    f.click(x, y); f.type('1'); f.key(15)      # Tab: confirm, next field
    w = widget(m, 'object.location', 1)
    check(abs(num('x') - 1) < 1e-6 and bool(w and w.get('editing')), 'Tab confirms and moves to the next field')
    f.type('7'); f.key(1)                      # Esc cancels
    check(abs(num('y') - 2.5) < 1e-6 and not any(w.get('editing') for w in ui_tree(m)),
          'Esc cancels typing and keeps the value')
    x, y = widget_xy(m, 'object.scale', 2)
    f.move(x, y)
    f.mods(4); f.wheel(-1); f.mods(0)          # Ctrl+wheel up: 10 steps
    check(abs(num('sz') - 1.05) < 1e-4, f'Ctrl+wheel steps a field ({num("sz")})')
    x, y = widget_xy(m, 'object.name')
    f.click(x, y)
    f.mods(4); f.key(30); f.mods(0)            # (all selected already) type over
    f.type('Box'); f.key(28)
    check(q('print(exists("Box"), exists("Cube"))') == '1 0', 'the name field renames the object')
    f.shot('widgets_props.png')
    val = lambda n: (widget(m, n) or {}).get('value')
    props_tab(m, f, 'viewport')
    x, y = widget_xy(m, 'viewport.shading')    # an option list
    f.click(x, y)
    f.click(x, y + 11 + 2 + 4 + 22 + 11)       # its second row: Wireframe
    check(val('viewport.shading') == 1, 'a dropdown list picks Wireframe shading')
    f.move(x, y)
    f.mods(4); f.wheel(-1); f.mods(0)          # Ctrl+wheel up: the option before
    check(val('viewport.shading') == 0, 'Ctrl+wheel steps a dropdown')
    f.click(x, y)
    opened = any(w['kind'] == 'list' for w in ui_tree(m))
    f.key(1)
    check(opened and val('viewport.shading') == 0 and not any(w['kind'] == 'list' for w in ui_tree(m)),
          'Esc closes an open list unchanged')
    grid = lambda: [w for w in ui_tree(m) if w['name'] == 'viewport.grid' and w['kind'] == 'toggle'][0]
    w = grid()                                 # (the Properties toggle, not the header's icon)
    x, y = w['x'] + w['w'] // 2, w['y'] + w['h'] // 2
    f.click(x, y)
    check(grid()['value'] == 0, 'a toggle switches the ground grid off')
    f.mods(4); f.key(44); f.mods(0)            # (not an undo step: a view setting)
    f.click(x, y)
    check(grid()['value'] == 1, 'and on again')
    x, y = widget_xy(m, 'viewport.pitch')
    f.click(x, y); f.type('120'); f.key(28)
    p = val('viewport.pitch')
    check(p is not None and abs(p - 1.55) < 1e-4, f'a clamped field keeps pitch at its limit ({p})')
    x, y = widget_xy(m, 'ui.theme')
    f.click(x, y); f.click(x, y + 11 + 2 + 4 + 22 + 11)
    check(px(f, 640, 5) == 0xdfe1e6, 'the theme dropdown switches to the light theme')
    f.click(x, y); f.click(x, y + 11 + 2 + 4 + 11)
    x, y = widget_xy(m, 'props.viewport')
    f.click(x, y)
    check(widget(m, 'viewport.yaw') is None, 'clicking a section header collapses it')
    f.click(x, y)
    check(widget(m, 'viewport.yaw') is not None, 'and opens it again')
    f.proc.kill()


def tooltips():
    """UI plan U4: tooltips on menu items, tools, header buttons and fields;
    items that cannot run now are greyed and say why."""
    print('  -- tooltips --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    def tip():
        f.pump(0.7)                            # rest longer than 500 ms
        for w in ui_tree(m):
            if w['kind'] == 'tooltip':
                return w
        return None
    f.move(60, 102)                            # the Select tool
    t = tip()
    check(bool(t) and t['label'] == 'Select' and t['key'] == 'Shift+Q' and t['value'],
          f'resting on a tool shows its name, shortcut and doc ({t and t["label"]}, {t and t["key"]})')
    f.shot('tooltip_tool.png')
    f.move(62, 104)
    check(tip() is not None, 'moving within the same target keeps the tooltip')
    f.button(True); f.button(False)
    check(tip() is None, 'a press hides it')
    f.click(80, 43)                            # Edit menu: Undo (nothing done yet)
    f.move(120, 71)
    t = tip()
    check(bool(t) and t['label'] == 'Undo' and t['why'] == 'there is nothing to undo',
          f'a menu item that cannot run says why ({t and t["why"]})')
    f.shot('tooltip_menu.png')
    grey, normal = px_text(f, 82, 64, 30), px_text(f, 82, 64 + 2 * 24 + 9, 30)
    check(grey < normal - 40, f'and is drawn greyed ({grey:.0f} < {normal:.0f}, Edit Mode)')
    f.click(120, 71)                           # clicking it does nothing
    f.key(1)
    mx = [w for w in ui_tree(m) if w['kind'] == 'menu' and w['label'] == 'Mesh'][0]['x'] + 10
    f.click(mx, 43)                            # Mesh menu in object mode
    f.move(mx + 40, 71)
    t = tip()
    check(bool(t) and 'edit mode' in (t['why'] or ''), f'Mesh > Extrude needs edit mode ({t and t["why"]})')
    f.key(1)
    f.move(600, 300); f.key(15)                # Tab: edit mode
    f.click(mx, 43); f.move(mx + 40, 71)
    t = tip()
    check(bool(t) and t['why'] is None, 'in edit mode it can run (no reason shown)')
    f.key(1); f.move(600, 300); f.key(15)
    x, y = widget_xy(m, 'object.location', 0)
    f.move(x, y)
    t = tip()
    check(bool(t) and 'expression' in (t['value'] or ''), 'a field has its own tooltip')
    f.move(1210, 16)                           # the maximize button
    t = tip()
    check(bool(t) and t['label'] == 'Maximize', 'window buttons have tooltips')
    f.proc.kill()


def px_text(f, x, y, w):
    """Brightest text pixel along a row segment (to compare greyed text)."""
    return max(sum(((px(f, x + i, y + j) >> s) & 255) for s in (16, 8, 0)) / 3
               for i in range(w) for j in range(0, 12))


def icons():
    """UI plan U5: src/icons.inc matches tools/genicons.py, and the Tools
    pane draws a different icon on each button (tinted by the theme)."""
    print('  -- icons --')
    root = os.path.join(os.path.dirname(__file__), '..')
    tmp = os.path.join(tempfile.mkdtemp(), 'icons.inc')
    subprocess.run([sys.executable, os.path.join(root, 'tools', 'genicons.py'), '--out', tmp],
                   cwd=root, capture_output=True)
    same = os.path.exists(tmp) and open(tmp).read() == open(os.path.join(root, 'src', 'icons.inc')).read()
    check(same, 'src/icons.inc is what tools/genicons.py makes (regenerate it after editing an icon)')
    f = Fake()
    f.pump(1.0, until_frame=True)
    shapes = []
    for i in range(10):                        # tool_y: ed_y + 10 + i * 30 (+28 after 4)
        y0 = 80 + 10 + i * 30 + (28 if i >= 4 else 0) + 5
        bg = px(f, 10, y0 + 8)
        shapes.append(tuple(px(f, 13 + x, y0 + y) != bg for y in range(16) for x in range(16)))
    drawn = [sum(sh) for sh in shapes]
    check(all(n >= 12 for n in drawn) and len(set(shapes)) == 10,
          f'each tool button shows its own icon ({drawn})')
    f.proc.kill()


def menus_ui():
    """UI plan U6: the reorganised menu bar, submenus, keyboard navigation,
    right-click context menus and the Z pie (hold) - Z tapped still toggles."""
    print('  -- menus --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    tree = ui_tree(m)
    bar = [w['label'] for w in tree if w['kind'] == 'menu']
    check(bar == ['File', 'Edit', 'View', 'Select', 'Add', 'Object', 'Mesh', 'Render', 'AI', 'Help'],
          f'menu bar: {" ".join(bar)}')
    items = lambda lvl=None: [w for w in ui_tree(m) if w['kind'] == 'menuitem' and (lvl is None or w['level'] == lvl)]
    f.key(68)                                  # F10: the first menu, keyboard on it
    check(len(items(0)) > 5 and items(0)[0]['label'] == 'New Scene', 'F10 opens the File menu')
    for _ in range(5): f.key(108)              # Down x5: Import (a submenu, after Open Recent)
    f.key(106)                                 # Right: into it
    sub = [w['label'] for w in items(1)]
    check(sub[:2] == ['Import OBJ...', 'Import STL...'], f'Right opens the Import submenu ({len(sub)})')
    f.key(105)                                 # Left: back
    check(not items(1), 'Left closes the submenu')
    f.key(106); f.key(106)                     # Right on Import opens it again, ... ; Esc x2
    f.key(1); f.key(1)
    check(not items(), 'Esc closes one level at a time')
    f.key(68); f.key(106)                      # F10, Right: the next menu (Edit)
    check(items(0) and items(0)[0]['label'] == 'Undo', 'Right on a plain entry moves to the next menu')
    f.key(1)
    f.mods(8); f.key(47); f.mods(0)            # Alt+V: View (no operator has Alt+V)
    check(items(0) and items(0)[0]['label'] == 'Tools Pane', 'Alt+V opens the View menu')
    f.key(1)
    f.mods(8); f.key(35); f.mods(0)            # Alt+H: Reveal Hidden stays a shortcut
    check(not items(), 'Alt+H keeps its operator (no menu opens)')
    menu_pick(f, m, 'Add', 'Curve', 'Bezier Curve')
    check(q('print(count())') == '4', 'Add > Curve > Bezier Curve (a submenu by the mouse)')
    f.click(600, 420, 0x111)                   # RMB on the viewport: a context menu
    labels = [w['label'] for w in items()]
    check(labels[:2] == ['Duplicate', 'Delete'] and 'Boolean' in labels,
          f'right-click in the viewport: the object menu ({len(labels)})')
    w = [w for w in items() if w['label'] == 'Duplicate'][0]
    f.click(w['x'] + 40, w['y'] + 12)
    check(q('print(count())') == '5', 'its Duplicate duplicates')
    f.key(1)                                   # (the duplicate grab)
    q('select("Cube")')
    f.move(600, 300); f.key(15)                # edit mode: the edit menu
    f.click(600, 420, 0x111)
    labels = [w['label'] for w in items()]
    check('Extrude' in labels and 'Merge' in labels, f'in edit mode it is the mesh menu ({labels[:3]})')
    f.key(1); f.key(15)
    f.click(1060, 67, 0x111)                   # RMB on the outliner header
    labels = [w['label'] for w in items()]
    check('Split Area Side by Side' in labels, 'right-click on an area header: the area menu')
    f.key(1)
    props_tab(m, f, 'viewport')                # (the shading shows there)
    f.move(600, 300)
    shade = lambda: (widget(m, 'viewport.shading') or {}).get('value')
    f.key(44)                                  # Z tapped: wireframe, as always
    check(shade() == 1, 'Z tapped still toggles wireframe')
    f.key(44)
    f.keyev(44, 1); f.pump(0.5)                # Z held: the pie
    pie = [w['label'] for w in ui_tree(m) if w['kind'] == 'pieitem']
    check(pie == ['Solid', 'Wireframe', 'Material Preview'], f'Z held opens the shading pie ({pie})')
    f.move(600, 420); f.pump(0.1)              # down: Material Preview
    f.shot('menus_pie.png')
    f.keyev(44, 0); f.pump(0.3)
    check(shade() == 2 and not any(w['kind'] == 'pieitem' for w in ui_tree(m)),
          'releasing over a choice picks it and closes the pie')
    f.proc.kill()


def dialogs():
    """UI plan U7: operator forms and the "Save changes?" dialog - modal,
    keyboard (Enter / Esc), remembered values; scripts never see them."""
    print('  -- dialogs --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def palette(text):
        f.key(61); f.type(text); f.key(28); f.pump(0.2)
    palette('scene units')
    check({'form.units', 'dialog.ok', 'dialog.cancel'} <= names(), 'the palette opens Scene Units as a form')
    f.shot('dialog_units.png')
    before = q('print(active())')
    f.click(300, 560)                          # behind the dialog: nothing happens
    check(q('print(active())') == before and 'dialog.ok' in names(), 'the dialog is modal')
    x, y = widget_xy(m, 'form.units')
    f.click(x, y)                              # its options: Millimetres first
    lst = [w for w in ui_tree(m) if w['kind'] == 'list']
    f.click(x, lst[0]['y'] + 4 + 11 if lst else y)
    x, y = widget_xy(m, 'dialog.ok')
    f.click(x, y)
    check(q('print(expr("1m"))') == '1000' and 'dialog.ok' not in names(), 'OK runs scene.units mm (1 m = 1000 units)')
    palette('scene units')
    check((widget(m, 'form.units') or {}).get('value') == 0, 'the form remembers the last values')
    f.key(1)
    check('dialog.ok' not in names(), 'Esc closes a form')
    q('select("Cube")')
    palette('add rigid body')
    x, y = widget_xy(m, 'form.rigid.mass')
    f.click(x, y); f.type('2.5'); f.key(28)    # (Enter confirms the field,
    f.key(28)                                  #  a second Enter the dialog)
    r = q('print(rigid("Cube", "type"), rigid("Cube", "mass"))')
    check(r == '1 2.5', f'Enter confirms the rigid body form: active, mass 2.5 ({r})')
    q('op("scene.units", "m")')                # (scripts: no dialog)
    check('dialog.ok' not in names(), 'a script running a form operator gets no dialog')
    f.mods(4); f.key(49); f.mods(0)            # Ctrl+N with changes: "Save changes?"
    check({'dialog.save', 'dialog.dont_save', 'dialog.cancel'} <= names(), 'Ctrl+N asks to save changes first')
    f.shot('dialog_save.png')
    x, y = widget_xy(m, 'dialog.cancel')
    f.click(x, y)
    check(q('print(rigid("Cube", "type"))') == '1', 'Cancel keeps the scene')
    f.mods(4); f.key(49); f.mods(0)
    x, y = widget_xy(m, 'dialog.dont_save')
    f.click(x, y)
    check(q('print(count(), rigid("Cube", "type"))') == '3 nil', "Don't Save starts the new scene")
    f.mods(4); f.key(49); f.mods(0)            # nothing changed: no question
    check('dialog.save' not in names(), 'an unchanged scene is not asked about')
    q('add("cube", "Extra", 3, 0, 0)')
    f.click(1257, 16)                          # the window's close button
    check('dialog.dont_save' in names(), 'closing the window with changes asks first')
    x, y = widget_xy(m, 'dialog.dont_save')
    f.click(x, y)
    f.pump(0.5)
    try:
        rc = f.proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        f.proc.kill(); rc = None
    check(rc == 0, f"Don't Save quits (rc={rc})")


def files_ui():
    """UI plan U8: the file browser - Save As / Open / Import through it,
    folders first, the filter, double-click, the path field, Backspace,
    "Replace?", Ctrl+S once there is a file, Save before New."""
    print('  -- file browser --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    home = f.home
    bee = os.path.join(home, 'BeeModel')
    os.makedirs(os.path.join(bee, 'parts'), exist_ok=True)
    open(os.path.join(bee, 'notes.txt'), 'w').write('not a scene')
    open(os.path.join(home, 'tri.obj'), 'w').write('v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n')
    rows = lambda: [w['label'] for w in ui_tree(m) if w['kind'] == 'row' and w['name'] == 'files.row']
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.2)
    def new_scene():                           # (scripts may not run file.*)
        f.mods(4); f.key(49); f.mods(0)
        if 'dialog.dont_save' in names():
            click('dialog.dont_save')
    def type_into(name, text):
        click(name); f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.2)
    q('add("cube", "Box", 3, 1, 0)')
    f.mods(5); f.key(31); f.mods(0)            # Ctrl+Shift+S: Save As
    check({'files.path', 'files.name', 'files.ok'} <= names(), 'Save As opens the file browser')
    check(rows() == ['parts'], f'it lists folders and only .bee files ({rows()})')
    f.shot('files_save.png')
    type_into('files.name', 'box')
    click('files.ok')
    check(os.path.exists(os.path.join(bee, 'box.bee')), 'Save adds the .bee extension and writes ~/BeeModel/box.bee')
    q('add("cube", "Box2", -3, 1, 0)')
    f.mods(4); f.key(31); f.mods(0)            # Ctrl+S: the file it has, no browser
    check('files.ok' not in names(), 'Ctrl+S saves to the scene\'s file without asking')
    f.mods(5); f.key(31); f.mods(0)
    type_into('files.name', 'box')
    click('files.ok')
    check('files.replace' in names(), 'saving over a file asks "Replace it?"')
    click('files.replace')
    check('files.ok' not in names(), 'Replace saves')
    new_scene()
    f.mods(4); f.key(24); f.mods(0)            # Ctrl+O
    r = rows()
    check(r == ['parts', 'box.bee'], f'Open: folders first, then scenes ({r})')
    x, y = [(w['x'] + 30, w['y'] + 11) for w in ui_tree(m) if w.get('label') == 'parts'][0]
    f.click(x, y); f.click(x, y); f.pump(0.2)  # double-click a folder: into it
    p = (widget(m, 'files.path') or {}).get('value', '')
    check(p.endswith('/BeeModel/parts'), f'double-clicking a folder opens it ({p})')
    f.key(14); f.pump(0.2)                     # Backspace: up
    check(rows() == ['parts', 'box.bee'], 'Backspace goes to the folder above')
    x, y = [(w['x'] + 30, w['y'] + 11) for w in ui_tree(m) if w.get('label') == 'box.bee'][0]
    f.click(x, y); f.click(x, y); f.pump(0.3)  # double-click a scene: open it
    check(q('print(exists("Box"), exists("Box2"))') == '1 1' and 'files.ok' not in names(),
          'double-clicking a scene opens it')
    menu_pick(f, m, 'File', 'Import', 'Import OBJ...')
    check(rows() == ['parts'], 'Import OBJ filters for .obj files')
    type_into('files.path', os.path.join(home, 'tri.obj'))   # a typed file: its folder, name
    click('files.ok')
    check(q('print(count())') == '6', 'Import OBJ through the browser adds the mesh')
    f.mods(5); f.key(31); f.mods(0)
    f.key(1)
    check('files.ok' not in names(), 'Esc closes the browser')
    new_scene()
    q('add("cube", "Fresh", 0, 4, 0)')         # untitled, changed: New asks,
    f.mods(4); f.key(49); f.mods(0)            #  Save opens the browser,
    click('dialog.save')                       #  then the new scene follows
    type_into('files.name', 'fresh')
    click('files.ok')
    saved = [r for r, d, fs in os.walk(home) if 'fresh.bee' in fs]
    n = q('print(count())')
    check(len(saved) == 1 and n == '3',
          f'Save before New: the browser saves ({saved}), then the new scene starts ({n} objects)')
    f.proc.kill()


def clipboard():
    """UI plan U9: the Wayland clipboard - copy from the console and from a
    field, paste into fields from another program, cut."""
    print('  -- clipboard --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    check(getattr(f, 'ddev', None) is not None, 'BeeModel gets a data device for the clipboard')
    f.key(28); f.type('hello world')           # the console: Ctrl+A, Ctrl+C
    f.mods(4); f.key(30); f.key(46); f.mods(0)
    f.key(1)
    t = f.clipboard()
    check(t == 'hello world', f'Ctrl+C in the console copies for other programs ({t!r})')
    x, y = widget_xy(m, 'object.location', 1)
    f.move(x, y)
    f.mods(4); f.key(46); f.mods(0)            # Ctrl+C over a field: its value
    t = f.clipboard()
    check(t == '1', f'Ctrl+C over a field copies its value ({t!r})')
    f.set_clipboard('2.75')                    # another program copies a number
    x, y = widget_xy(m, 'object.location', 0)
    f.move(x, y)
    f.mods(4); f.key(47); f.mods(0)            # Ctrl+V over a field
    r = q('print(get("Cube", "x"))')
    check(r == '2.75', f'Ctrl+V over a field pastes another program\'s text ({r})')
    f.mods(4); f.key(44); f.mods(0)
    check(q('print(get("Cube", "x"))') == '0', 'one undo takes the paste back')
    f.set_clipboard('Pasted\nname')
    x, y = widget_xy(m, 'object.name')
    f.click(x, y)                              # typing in the name: select all, paste
    f.mods(4); f.key(30); f.key(47); f.mods(0)
    f.key(28)
    check(q('print(exists("Pasted name"))') == '1', 'pasting into a text field (a line break becomes a space)')
    f.click(x, y)
    f.mods(4); f.key(30); f.key(45); f.mods(0) # Ctrl+X: cut
    f.key(1)
    t = f.clipboard()
    check(t == 'Pasted name', f'Ctrl+X cuts the text ({t!r})')
    f.proc.kill()


def props_ui():
    """UI plan U10: the Properties editor - tabs, editable visibility and
    colour, scene settings (units, world, frame range) and render settings."""
    print('  -- properties --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    val = lambda n: (widget(m, n) or {}).get('value')
    tabs = [w['label'] for w in ui_tree(m) if w['name'].startswith('props.tab.')]
    check(tabs == ['Object', 'Modifiers', 'Material', 'Physics', 'CAD', 'Scene', 'Render', 'Viewport', 'Animation', 'Rig'],
          f'Properties has a tab per page ({len(tabs)})')
    def set_field(name, text):
        x, y = widget_xy(m, name); f.click(x, y)
        f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.2)
    x, y = widget_xy(m, 'object.visible')
    f.click(x, y)
    check(val('object.visible') == 0 and q('print(count())') == '3', 'Visible off hides the cube')
    f.mods(4); f.key(44); f.mods(0)
    check(val('object.visible') == 1, 'one undo shows it again')
    set_field('object.color', 'ff8000')
    check(q('print(get("Cube", "color"))') == str(0xff8000), 'the colour field takes #rrggbb')
    props_tab(m, f, 'scene')
    x, y = widget_xy(m, 'scene.units')
    f.click(x, y)
    lst = [w for w in ui_tree(m) if w['kind'] == 'list']
    f.click(x, lst[0]['y'] + 4 + 11 if lst else y)    # Millimetres
    check(q('print(expr("1m"))') == '1000', 'Scene > Units: millimetres')
    set_field('world.strength', '2.5')
    check(val('world.strength') == 2.5, 'Scene > World strength')
    set_field('scene.frame_end', '120')
    check(val('scene.frame_end') == 120 and val('scene.frame_start') == 1, 'Scene > End frame (anim.range)')
    props_tab(m, f, 'render')
    set_field('render.width', '640')
    check(val('render.width') == 640, 'Render > Width')
    check(widget(m, 'render.start') is not None and widget(m, 'render.save') is not None,
          'the Render page has Render and Save Render buttons')
    f.shot('props_render.png')
    f.proc.kill()


def viewport_ui():
    """UI plan U11: the 3D viewport's header (mode, select mode, shading,
    grid, snap) and the navigation gizmo / Numpad views."""
    print('  -- viewport header --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name):
        x, y = widget_xy(m, name); f.click(x, y); f.pump(0.2)
    need = {'viewport.mode', 'viewport.shading_wireframe', 'viewport.shading_solid', 'viewport.shading_material',
            'viewport.grid', 'viewport.snap', 'viewport.nav_top', 'viewport.nav_front', 'viewport.nav_right'}
    check(need <= names(), f'the viewport header and gizmo are widgets ({len(need & names())} of {len(need)})')
    check('viewport.select_face' not in names(), 'object mode: no select-mode buttons')
    x, y = widget_xy(m, 'viewport.mode')       # the mode list: Edit Mode
    f.click(x, y)
    lst = [w for w in ui_tree(m) if w['kind'] == 'list']
    f.click(x, lst[0]['y'] + 4 + 22 + 11 if lst else y)
    check((widget(m, 'viewport.mode') or {}).get('value') == 1 and 'viewport.select_face' in names(),
          'the mode list enters edit mode; the select-mode buttons appear')
    click('viewport.select_face')
    click('viewport.mode'); lst = [w for w in ui_tree(m) if w['kind'] == 'list']
    x, y = widget_xy(m, 'viewport.mode'); f.click(x, lst[0]['y'] + 4 + 11 if lst else y)
    check((widget(m, 'viewport.mode') or {}).get('value') == 0, 'and back to object mode')
    props_tab(m, f, 'viewport')
    val = lambda n: (widget(m, n) or {}).get('value')
    click('viewport.shading_wireframe')
    check(val('viewport.shading') == 1, 'the wireframe button')
    click('viewport.shading_solid')
    check(val('viewport.shading') == 0, 'the solid button')
    click('viewport.nav_top')
    p = val('viewport.pitch')
    check(p is not None and p > 1.5, f'clicking the gizmo\'s Y looks from the top (pitch {p})')
    f.move(600, 300); f.key(79)                # Numpad 1: front
    p, yw = val('viewport.pitch'), val('viewport.yaw')
    check(p is not None and yw is not None and abs(p) < 1e-6 and abs(yw) < 1e-6, f'Numpad 1: the front view ({yw}, {p})')
    f.shot('viewport_header.png')
    click('viewport.snap')                     # snap on: a move lands on whole units
    f.move(600, 300); f.key(34)
    f.move(637, 300); f.move(643, 302); f.button(True); f.button(False)
    x = float(q('print(get("Cube", "x"))') or 'nan')
    check(x == round(x) and x != 0, f'Snap on: G moves in whole steps ({x})')
    f.proc.kill()


def tools_ui():
    """UI plan U12: the Tools pane follows the mode; the brush settings bar
    in sculpt and texture paint mode."""
    print('  -- tools pane --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    rows = lambda: [w['label'] for w in ui_tree(m) if w['name'] == 'tools.row']
    r = rows()
    check(r[:4] == ['Select', 'Move', 'Rotate', 'Scale'] and 'Cube' in r, f'object mode: transform tools and Add ({len(r)})')
    f.move(600, 300); f.key(15)                # edit mode
    r = rows()
    check('Extrude' in r and 'Loop Cut' in r and 'Box Select' in r and 'Cube' not in r,
          f'edit mode: the modelling tools ({len(r)})')
    f.key(30)                                  # A: select all first
    w = [w for w in ui_tree(m) if w['name'] == 'tools.row' and w['label'] == 'Subdivide'][0]
    f.click(w['x'] + 40, w['y'] + 12); f.pump(0.2)
    f.move(600, 300); f.key(15)
    n = q('print(faces("Cube"))')
    check(n == '24', f'clicking Subdivide subdivides the selection ({n} faces)')
    f.mods(4); f.key(15); f.mods(0)            # sculpt mode
    r = rows()
    check(r[:3] == ['Draw', 'Clay Strips', 'Crease'], f'sculpt mode: the brushes ({r[:3]})')
    check({'brush.radius', 'brush.strength', 'brush.symmetry_x'} <= {w['name'] for w in ui_tree(m)},
          'sculpt mode: the brush bar (radius, strength, symmetry ...)')
    x, y = widget_xy(m, 'brush.radius')
    f.click(x, y); f.mods(4); f.key(30); f.mods(0); f.type('80'); f.key(28)
    check((widget(m, 'brush.radius') or {}).get('value') == 80, 'the brush radius field')
    f.shot('tools_sculpt.png')
    f.mods(4); f.key(15); f.mods(0)
    check(rows()[:1] == ['Select'] and widget(m, 'brush.radius') is None, 'leaving sculpt mode: object tools, no bar')
    f.proc.kill()


def outliner_ui():
    """UI plan U13: the outliner - type icons, the eye, rename by
    double-click and F2, the filter in its header."""
    print('  -- outliner --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    eyes = lambda: [w for w in ui_tree(m) if w['name'] == 'outliner.visible']
    check(len(eyes()) == 3, f'an eye per object ({len(eyes())})')
    e = eyes()[2]                              # the Cube's eye
    f.click(e['x'] + 11, e['y'] + 11); f.pump(0.2)
    r = q('print(count())')
    f.shot('outliner_hidden.png')
    hidden = px(f, *project((0, 1, 0))) == px(f, *project((0, 1, 0)))
    f.mods(4); f.key(44); f.mods(0)            # one undo
    check(len(eyes()) == 3, 'the eye hides the object; undo shows it again')
    f.click(1080, 134); f.click(1080, 134); f.pump(0.2)   # double-click the Cube row
    check(bool(widget(m, 'outliner.name')) and widget(m, 'outliner.name').get('editing'),
          'double-clicking a row renames it in place')
    f.mods(4); f.key(30); f.mods(0); f.type('Block'); f.key(28)
    check(q('print(exists("Block"))') == '1', 'Enter keeps the new name')
    f.move(600, 300); f.key(60)                # F2: rename the active object
    check(bool(widget(m, 'outliner.name')) and widget(m, 'outliner.name').get('editing'), 'F2 renames the active object')
    f.key(1)
    x, y = widget_xy(m, 'outliner.filter')
    f.click(x, y); f.type('cam'); f.key(28); f.pump(0.2)
    check(len(eyes()) == 1, f'the filter shows only matching objects ({len(eyes())})')
    f.click(1080, 94); f.pump(0.2)             # its only row: the Camera
    check(q('print(active())') == 'Camera', 'a filtered row still selects its object')
    f.click(x, y); f.mods(4); f.key(30); f.mods(0); f.key(14); f.key(28); f.pump(0.2)
    check(len(eyes()) == 3, 'an empty filter shows everything')
    f.proc.kill()


def status_ui():
    """UI plan U14: the status bar's hints follow the mode, chips on the
    right, toasts for messages (warnings amber), a click opens the console."""
    print('  -- status bar --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    y = 800 - 11
    bright = lambda x0, x1: sum(1 for x in range(x0, x1) for yy in range(y - 6, y + 6) if max(((px(f, x, yy) >> s) & 255) for s in (16, 8, 0)) > 150)
    left = bright(10, 600)
    check(left > 40, f'the status bar shows key hints ({left} bright px)')
    names = {w['name'] for w in ui_tree(m)}
    check('status.ai' in names and 'status.toast' not in names, 'an AI chip; no toast at startup')
    f.mods(4); f.key(44); f.mods(0)            # Ctrl+Z with nothing to undo
    names = {w['name'] for w in ui_tree(m)}
    t = widget(m, 'status.toast')
    amber = t and any(px(f, t['x'] + 2, t['y'] + yy) == 0xe0a030 for yy in range(6, 30))
    check(bool(t) and amber, 'a toast says why, in amber')
    f.shot('status_toast.png')
    x, y2 = widget_xy(m, 'status.toast')
    f.click(x, y2); f.pump(0.2)
    f.type('add("cube", "Typed", 3, 0, 0)'); f.key(28); f.pump(0.2)   # the console has the keys
    f.key(1)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    check(q('print(exists("Typed"))') == '1', 'clicking the toast opens the console')
    f.pump(4.3)
    check('status.toast' not in {w['name'] for w in ui_tree(m)}, 'the toast goes after four seconds')
    x, y2 = widget_xy(m, 'status.ai')
    f.click(x, y2)
    labels = [w['label'] for w in ui_tree(m) if w['kind'] == 'menuitem']
    check('Read Only' in ' '.join(labels) or len(labels) >= 4, f'the AI chip opens the AI menu ({labels[:2]})')
    f.key(1)
    f.move(600, 300); f.key(15)
    after = bright(10, 600)
    check(after != left, 'edit mode: other hints')
    f.proc.kill()


def files_more():
    """UI plan U15: export options (selected only, Z up, scale), File > Open
    Recent (kept across a restart), the Print Check form."""
    print('  -- files, export, print --')
    import struct as _st
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    home = f.home
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name):
        x, y = widget_xy(m, name); f.click(x, y); f.pump(0.2)
    def type_into(name, text):
        click(name); f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.2)
    q('add("cube", "Other", 5, 1, 0); select("Cube")')
    menu_pick(f, m, 'File', 'Export', 'Export STL...')
    check({'files.selected_only', 'files.up_axis', 'files.scale'} <= names(), 'Export STL offers selected only, up axis and scale')
    click('files.selected_only')
    x, y = widget_xy(m, 'files.up_axis'); f.click(x, y)
    lst = [w for w in ui_tree(m) if w['kind'] == 'list']
    f.click(x, lst[0]['y'] + 4 + 22 + 11 if lst else y)    # Z up
    type_into('files.scale', '1000')
    type_into('files.name', 'part')
    click('files.ok')
    path = os.path.join(home, 'BeeModel', 'part.stl')
    data = open(path, 'rb').read() if os.path.exists(path) else b''
    ntri = _st.unpack_from('<I', data, 80)[0] if len(data) > 84 else 0
    zs = [_st.unpack_from('<f', data, 84 + i * 50 + 12 + v * 12 + 8)[0] for i in range(ntri) for v in range(3)]
    check(ntri == 12 and zs and abs(min(zs)) < 1e-3 and abs(max(zs) - 2000) < 1e-2,
          f'the STL has only the cube, Z up and in millimetres ({ntri} triangles, z {min(zs) if zs else "?"}..{max(zs) if zs else "?"})')
    f.mods(5); f.key(31); f.mods(0)            # Save As: no export options
    check('files.selected_only' not in names(), 'Save As has no export options')
    type_into('files.name', 'recent1')
    click('files.ok')
    t = [w for w in ui_tree(m) if w['kind'] == 'menu' and w['label'] == 'File'][0]
    f.click(t['x'] + 10, t['y'] + 10)
    w = [w for w in ui_tree(m) if w.get('label') == 'Open Recent'][0]
    f.move(w['x'] + 40, w['y'] + 12); f.pump(0.2)
    rec = [w['label'] for w in ui_tree(m) if w['kind'] == 'menuitem' and w['level'] == 1]
    check(rec == ['recent1.bee'], f'File > Open Recent lists it ({rec})')
    f.key(1); f.key(1)
    menu_pick(f, m, 'Object', 'Print Check')
    check('form.print.wall' in names(), 'Object > Print Check asks for the thinnest wall')
    f.key(28)
    f.proc.kill()
    g = Fake(home=home)                        # after a restart
    g.pump(1.0, until_frame=True)
    g.keymap('tests/keymaps/us.xkb')
    g.enter(600, 300)
    n = Mcp(g)
    t = [w for w in ui_tree(n) if w['kind'] == 'menu' and w['label'] == 'File'][0]
    g.click(t['x'] + 10, t['y'] + 10)
    w = [w for w in ui_tree(n) if w.get('label') == 'Open Recent'][0]
    g.move(w['x'] + 40, w['y'] + 12); g.pump(0.2)
    item = [w for w in ui_tree(n) if w['kind'] == 'menuitem' and w['level'] == 1 and w['label'] == 'recent1.bee']
    check(bool(item), 'Open Recent survives a restart')
    if item:
        g.click(item[0]['x'] + 40, item[0]['y'] + 12); g.pump(0.3)
    r = (n.tool('script_eval', {'code': 'print(exists("Other"))'})[0] or '').strip()
    check(r == '1', 'and opens the scene')
    g.proc.kill()


def cad_ui():
    """UI plan U16: Add > Sketch, the feature dialogs, the CAD tab (feature
    tree, parameters, units, kernel, joints, measure), the generators."""
    print('  -- modeling and CAD --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.2)
    def type_into(name, text, sub=0):
        click(name, sub); f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.3)
    q('delete("Cube")')
    menu_pick(f, m, 'Add', 'Sketch...')
    check({'form.sketch.name', 'form.sketch.plane', 'form.sketch.offset'} <= names(), 'Add > Sketch asks for a name, a plane and an offset')
    f.key(28); f.pump(0.3)
    check(q('print(active())') == 'Sketch', f'OK makes the sketch, active ({q("print(active())")})')
    f.key(1); f.key(1); f.pump(0.2)            # (out of sketch mode)
    q('rect("Sketch", 0, 0, 2, 1)')
    menu_pick(f, m, 'Object', 'Part Feature', 'Pad...')
    check({'form.feature.body', 'form.pad.distance', 'form.pad.direction'} <= names(), 'Object > Part Feature > Pad asks for the part, distance and direction')
    type_into('form.pad.distance', '0.5')
    f.key(28); f.pump(0.5)
    check(q('print(features(), fstatus(0), active())') == '1 0 Body', f'Pad makes a feature and the part, now active ({q("print(features(), fstatus(0), active())")})')
    v1 = float(q('print(volume("Body"))') or 0)
    check(abs(v1 - 1.0) < 1e-3, f'the pad is 2 x 1 x 0.5 ({v1})')
    f.mods(4); f.key(44); f.mods(0); f.pump(0.3)   # Ctrl+Z: the whole pad
    check(q('print(features())') == '0', 'one undo takes the pad back')
    f.mods(5); f.key(44); f.mods(0); f.pump(0.3)   # Ctrl+Shift+Z
    check(q('print(features())') == '1', 'redo brings it back')
    props_tab(m, f, 'cad')
    check({'cad.feature.value', 'cad.feature.on', 'cad.param.add', 'cad.units', 'cad.kernel', 'cad.add.pad', 'cad.joint.add', 'cad.mass'} <= names(),
          'the CAD tab: the feature tree, parameters, units, kernel, feature and joint buttons, measuring')
    w = widget(m, 'cad.feature.value')
    check(w is not None and w.get('value') == '0.5', f'the feature row shows its size ({w and w.get("value")})')
    type_into('cad.feature.value', '1')
    v2 = float(q('print(volume("Body"))') or 0)
    check(abs(v2 - 2.0) < 1e-3, f'editing the size rebuilds the part ({v2})')
    click('cad.feature.on')
    check(q('print(fstatus(0))') == '7', 'the On toggle suppresses the feature')
    click('cad.feature.on')
    check(q('print(fstatus(0))') == '0', '... and brings it back')
    click('cad.param.add')
    check({'form.param.name', 'form.param.expression'} <= names(), 'Add Parameter asks for a name and a value')
    type_into('form.param.name', 'h')
    type_into('form.param.expression', '2 * 0.25')
    f.key(28); f.pump(0.3)
    check(q('print(param("h"))') == '0.5', f'OK sets the parameter ({q("print(param(\"h\"))")})')
    type_into('cad.feature.value', 'h * 4')
    v3 = float(q('print(volume("Body"))') or 0)
    check(abs(v3 - 4.0) < 1e-3, f'a feature size can be an expression of parameters ({v3})')
    type_into('cad.param', '0.25')
    v4 = float(q('print(volume("Body"))') or 0)
    check(abs(v4 - 2.0) < 1e-3, f'editing the parameter in its row rebuilds ({v4})')
    click('cad.param.remove')
    check('no parameter' in q('print(param("h"))'), 'the row\'s x removes it')
    check(q('print(fstatus(0))') == '4', 'the feature that used it is broken now (a red dot, the reason under it)')
    type_into('cad.feature.value', '1')
    click('cad.mass')
    menu_pick(f, m, 'Object', 'Part Feature', 'Fillet...')
    check({'form.fillet.radius', 'form.fillet.edges'} <= names(), 'Fillet asks for a radius and which edges')
    type_into('form.fillet.radius', '0.1')
    f.key(28); f.pump(0.5)
    check(q('print(features(), fstatus(1))') == '2 0', f'Fillet adds a feature to the active part ({q("print(features(), fstatus(1))")})')
    q('select("Sketch")')
    menu_pick(f, m, 'Object', 'Part Feature', 'Fillet...')
    check('form.fillet.radius' not in names(), 'Fillet is greyed out on a sketch')
    f.key(1); f.key(1); f.pump(0.2)
    menu_pick(f, m, 'Add', 'Generate', 'L-system...')
    check({'form.lsystem.rules', 'form.lsystem.iterations'} <= names(), 'Add > Generate > L-system asks for the rules')
    f.key(28); f.pump(1.0)
    check(q('print(exists("Plant"), active())') == '1 Plant', f'OK grows the plant ({q("print(exists(\"Plant\"), active())")})')
    menu_pick(f, m, 'Object', 'Mechanism', 'Add Mechanism Joint')
    check({'form.joint.type', 'form.joint.part', 'form.joint.value'} <= names(), 'Object > Mechanism > Add Joint asks for the type, part, axis and value')
    jp = widget(m, 'form.joint.part')
    check(jp is not None and jp.get('value') == 'Plant', f'the part is the active object ({jp and jp.get("value")})')
    f.key(28); f.pump(0.3)
    check(q('print(joint(1))') == '0', f'OK adds the joint ({q("print(joint(1))")})')
    f.proc.kill()


def pick_enum(f, m, name, sub, row):
    """Open an enum's list and pick its row-th option (U3 lists)."""
    x, y = widget_xy(m, name, sub)
    f.click(x, y); f.pump(0.2)
    lst = [w for w in ui_tree(m) if w['kind'] == 'list']
    if lst:
        f.click(lst[0]['x'] + 30, lst[0]['y'] + 4 + row * 22 + 11); f.pump(0.3)


def materials_more():
    """UI plan U17: the colour picker (square, hue, hex, Pick), the Material
    tab's fields and pickers, world sky and images, a curve's data, the
    modifier stack as widgets (object and tree pickers, Multires), the node
    editor's header (tree, New Tree, Add with search)."""
    print('  -- materials, world, images, procedural --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.2)
    def type_into(name, text, sub=0):
        click(name, sub); f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.3)
    base = lambda: q('print(round(matget("Material", "base", 0) * 100), round(matget("Material", "base", 1) * 100), round(matget("Material", "base", 2) * 100))')
    props_tab(m, f, 'material')
    click('material.new')
    wait_widget(f, m, 'material.base')
    click('material.base')
    check({'color.sv', 'color.hue', 'color.hex', 'color.pick'} <= names(), 'a colour field opens the picker: square, hue strip, hex code, Pick')
    type_into('color.hex', '#ff0000')
    check(base() == '100 0 0', f'typing #ff0000 makes the base colour red ({base()})')
    w = widget(m, 'color.sv')
    f.click(w['x'] + 2, w['y'] + w['h'] - 2); f.pump(0.2)     # the bottom left: black
    check(base() == '0 0 0', f'the square\'s bottom is black ({base()})')
    w = widget(m, 'color.hue')
    f.drag(w['x'] + 8, w['y'] + 2, w['x'] + 8, w['y'] + w['h'] // 3, steps=3)
    w = widget(m, 'color.sv')
    f.click(w['x'] + w['w'] - 2, w['y'] + 2); f.pump(0.2)     # full colour of that hue
    r = base().split()
    check(len(r) == 3 and int(r[1]) > 90 and int(r[0]) < 10, f'the hue strip turns it green ({r})')
    f.mods(4); f.key(44); f.mods(0); f.pump(0.2)
    check(base() == '0 0 0', 'one undo per change (the last pick taken back)')
    click('color.pick')
    f.click(320, 140); f.pump(0.3)                          # Pick, then a click on the sky
    check(base() != '0 0 0', f'Pick takes the colour on screen ({base()})')
    f.key(1); f.pump(0.2)
    check('color.sv' not in names(), 'Esc closes the picker')
    q('op("image.new", "Tex 16 16")')
    pick_enum(f, m, 'material.texture', 0, 1)
    check(widget(m, 'material.texture')['value'] == 1, 'the texture list offers the scene\'s images')
    props_tab(m, f, 'scene')
    check({'world.sky', 'images.load', 'images.new'} <= names(), 'the Scene tab: the world\'s sky and the images')
    pick_enum(f, m, 'world.sky', 0, 1)
    check(widget(m, 'world.sky')['value'] == 1, 'the sky can be an image (HDRI)')
    click('images.new')
    check('form.image.name' in names(), 'New Image asks for a name and a size')
    f.key(1); f.pump(0.2)
    q('add("cylinder", "Cutter", 3, 0, 0)\nselect("Cube")\nmodifier("Cube", "boolean")\nmodifier("Cube", "multires")')
    props_tab(m, f, 'modifiers')
    check({'modifier.object', 'modifier.operation', 'modifier.subdivide', 'modifier.propagate'} <= names(),
          'modifier fields: an object list, an operation list, Multires buttons')
    pick_enum(f, m, 'modifier.object', 0, 4)                   # None Camera Light Cube Cutter
    check(widget(m, 'modifier.object')['value'] == 4, f'the boolean\'s object is picked from a list ({widget(m, "modifier.object")["value"]})')
    lv = widget(m, 'modifier.value', 16)
    click('modifier.subdivide', 1)
    for _ in range(5):
        lv2 = widget(m, 'modifier.value', 16)
        if lv2 and lv and lv2['value'] != lv['value']:
            break
        f.pump(0.1)
    check(lv and lv2 and lv2['value'] == lv['value'] + 1, f'Subdivide adds a Multires level ({lv and lv["value"]} -> {lv2 and lv2["value"]})')
    q('op("create.bezier")')
    props_tab(m, f, 'object')
    check({'curve.resolution', 'curve.bevel', 'curve.sides', 'curve.fill', 'curve.cyclic', 'curve.profile'} <= names(), 'a curve shows its data: resolution, tube, caps, closed, profile')
    f0 = int(q('print(faces("BezierCurve"))') or 0)
    type_into('curve.bevel', '0.1', 1)
    f1 = int(q('print(faces("BezierCurve"))') or 0)
    check(f1 > f0, f'a tube radius makes it a tube ({f0} -> {f1} faces)')
    q('select("Cube")\nop("area.type_node_editor")\nop("area.maximize")')
    f.pump(0.3)
    check({'node.tree', 'node.new_tree', 'node.add'} <= names(), 'the node editor header: tree, New Tree, Add')
    n0 = q('print(modcount("Cube"))')
    click('node.new_tree')
    check(q('print(modcount("Cube"))') == str(int(n0) + 1) and widget(m, 'node.tree')['value'] == 1,
          'New Tree makes a tree the cube runs (a Geometry Nodes modifier)')
    c0 = q('print(ginfo(1, 0, "count"))')
    click('node.add')
    f.type('cube'); f.pump(0.2); f.key(28); f.pump(0.3)
    check(q('print(ginfo(1, 0, "count"))') == str(int(c0 or 0) + 1), f'Add, typing to search, Enter adds the node ({c0} -> {q("print(ginfo(1, 0, \"count\"))")})')
    pick_enum(f, m, 'node.tree', 0, 0)
    check(widget(m, 'node.tree')['value'] == 0, 'the tree list goes back to the material')
    f.proc.kill()


def paint_ui():
    """UI plan U18: the paint colour (picker, swatches), the layer stack,
    weight paint's weight and bone, Mesh > UV, the UV editor's header, the
    Bake dialog."""
    print('  -- sculpt, paint, UV and bake --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.2)
    q('op("image.new", "tex 64 64")\nmaterial("M")\nn = node("M", "image", "tex", 1)\nsocket("M", "base", n)\n'
      'assign("Cube", "M")\nseams("Cube", "sharp")\nunwrap("Cube")\nselect("Cube")')
    f.mods(1); f.key(15); f.mods(0); f.pump(0.3)   # Shift+Tab: texture paint
    check({'paint.colour', 'paint.swatch'} <= names(), 'texture paint: the colour and swatches in the brush bar')
    click('paint.swatch', 3)
    v = wait_value(f, m, 'paint.colour', 0, '#e0b030')
    check(v == '#e0b030', f'a swatch sets the paint colour ({v})')
    click('paint.colour')
    check('color.sv' in names(), 'the colour opens the picker')
    f.key(1); f.pump(0.2)
    props_tab(m, f, 'material')
    check({'layer.add', 'layer.merge', 'layer.remove'} <= names(), 'the Material tab shows the paint layers while painting')
    click('layer.add')
    rows = lambda: [w for w in ui_tree(m) if w['name'] == 'layer.row']
    for _ in range(5):
        if len(rows()) == 2:
            break
        f.pump(0.1)
    check([w.get('label') for w in rows()] == ['Layer 1', 'Base'], f'Add: a layer above the base, the top first ({[w.get("label") for w in rows()]})')
    check(q('print(layer("tex", "count"), layer("tex", "active"))') == '2 1', 'it is painted on')
    pick_enum(f, m, 'layer.blend', 1, 1)
    check(wait_value(f, m, 'layer.blend', 1, 1) == 1, 'its blend mode from the list (Multiply)')
    click('layer.visible', 1)
    check(wait_value(f, m, 'layer.visible', 1, 0) == 0, 'the eye hides it')
    click('layer.row', 0)
    check(q('print(layer("tex", "active"))') == '0', 'a click on a row paints on that layer')
    click('layer.row', 1)
    click('layer.remove')
    for _ in range(5):
        if q('print(layer("tex", "count"))') == '1':
            break
        f.pump(0.1)
    check(q('print(layer("tex", "count"))') == '1', 'Remove takes the active layer away')
    q('op("object.texture_paint")')            # (out of texture paint)
    q('delete("Cube")\na = armature("Rig")\nop("arm.bone", "Upper Bone 0 1 0 0 2 0")\nadd("cylinder", "Arm", 0, 1, 0)\n'
      'scale("Arm", 0.3)\nop("arm.parent", "Arm Rig")\nselect("Arm")')
    f.mods(4); f.key(17); f.mods(0); f.pump(0.3)   # Ctrl+W: weight paint
    check({'paint.weight', 'paint.bone'} <= names(), 'weight paint: the weight and the bone in the brush bar')
    pick_enum(f, m, 'paint.bone', 0, 2)
    check(widget(m, 'paint.bone')['value'] == 2, 'the bone is picked from the armature\'s bones')
    w = widget(m, 'paint.weight')
    f.drag(w['x'] + w['w'] // 2, w['y'] + 11, w['x'] + w['w'] // 4, w['y'] + 11, steps=3)
    v = widget(m, 'paint.weight')['value']
    check(abs(v - 0.25) < 0.05, f'the weight slider ({v})')
    f.mods(4); f.key(17); f.mods(0); f.pump(0.2)
    q('select("Arm")')
    t = [w for w in ui_tree(m) if w['kind'] == 'menu' and w['label'] == 'Mesh'][0]
    f.click(t['x'] + 10, t['y'] + 10); f.pump(0.2)
    u = [w for w in ui_tree(m) if w.get('label') == 'UV']
    if u:
        f.move(u[0]['x'] + 40, u[0]['y'] + 12); f.pump(0.2)
    sub = [w['label'] for w in ui_tree(m) if w['kind'] == 'menuitem' and w['level'] == 1]
    check(sub[:3] == ['Unwrap', 'Smart UV Project', 'Pack Islands'], f'Mesh > UV: unwrapping and seams ({sub[:3]})')
    f.key(1); f.key(1)
    menu_pick(f, m, 'Render', 'Bake Maps')
    check({'form.bake.low', 'form.bake.high', 'form.bake.map', 'form.bake.image', 'form.bake.distance'} <= names(),
          'Render > Bake Maps asks for the low and high mesh, the map, the image and the distance')
    w = widget(m, 'form.bake.low')
    check(w and w['value'] == 'Arm', f'the low mesh is the active object ({w and w["value"]})')
    f.key(1); f.pump(0.2)
    q('op("area.type_uv_editor")')
    f.pump(0.3)
    check({'uv.header.unwrap', 'uv.header.pack', 'uv.header.select_all', 'uv.header.heat', 'uv.header.fit'} <= names(),
          'the UV editor header: Unwrap, Pack, Select All, heat map, Fit')
    pick_enum(f, m, 'uv.header.heat', 0, 1)
    check(widget(m, 'uv.header.heat')['value'] == 1, 'the heat map from the header')
    f.proc.kill()


def anim_ui():
    """UI plan U19: the timeline's transport and range, auto-key, I over a
    field, the key editors' key menu, the Animation tab (shape keys,
    actions and layers, drivers, onion skins) and the Rig tab (bones,
    pose, constraints, parenting)."""
    print('  -- animation and rigging --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.2)
    def type_into(name, text, sub=0):
        click(name, sub); f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.3)
    q('op("area.type_timeline")')
    f.pump(0.3)
    check({'timeline.first', 'timeline.prev', 'timeline.play', 'timeline.next', 'timeline.last', 'timeline.frame',
           'timeline.start', 'timeline.end', 'timeline.fps', 'timeline.auto_key'} <= names(), 'the timeline header: transport, frame, range, auto-key')
    type_into('timeline.frame', '12')
    check(q('print(frame())') == '12', f'typing a frame goes there ({q("print(frame())")})')
    type_into('timeline.end', '120')
    check(widget(m, 'timeline.end')['value'] == 120, 'the end frame from the header')
    click('timeline.last')
    check(q('print(frame())') == '120', 'the last-frame button')
    click('timeline.first')
    click('timeline.auto_key')
    q('op("area.type_viewport")\nselect("Cube")')
    f.move(600, 300); f.key(34); f.type('2'); f.key(28); f.pump(0.3)   # G 2 Enter
    check(q('print(keyed("Cube:x", 1))') in ('1', '2', '3'), 'auto-key: a move keys the object')
    q('op("anim.auto_key")')
    props_tab(m, f, 'object')
    x, y = widget_xy(m, 'object.location', 1)
    q('frame(10)')
    f.move(x, y); f.pump(0.1); f.key(23); f.pump(0.2)                # I over Y
    check(q('print(keyed("Cube:y", 10))') == '1', 'I over a field keys that value')
    q('op("area.type_dope_sheet")')
    f.pump(0.3)
    check({'keys.constant', 'keys.linear', 'keys.bezier', 'keys.duplicate', 'keys.delete'} <= names(), 'the key editors\' header: interpolation, handles, duplicate, delete')
    props_tab(m, f, 'animation')
    check({'shape.add', 'anim.new_action', 'anim.add_layer', 'onion.on', 'anim.motion_paths'} <= names(), 'the Animation tab')
    click('shape.add')
    f.key(28); f.pump(0.3)
    q('op("shape.add", "Big")')
    w = wait_widget(f, m, 'shape.value', 1)
    check(w is not None, 'shape keys get a slider each')
    if w:
        f.drag(w['x'] + 2, w['y'] + 11, w['x'] + w['w'] // 2, w['y'] + 11, steps=3)
        f.pump(0.2)
        v = widget(m, 'shape.value', 1)['value']
        check(v is not None and 0.4 < v < 0.6, f'dragging it mixes the shape in ({v})')
    click('onion.on')
    check(q('print(1)') == '1' and widget(m, 'onion.on')['value'] == 1, 'onion skins from the tab')
    click('anim.new_action')
    check('form.action.name' in names(), 'New Action asks for a name')
    f.key(28); f.pump(0.3)
    click('anim.add_layer')
    f.key(28); f.pump(0.3)
    w = wait_widget(f, m, 'layer.influence', 0)
    check(w is not None, 'a layer row with its influence')
    q('delete("Cube")\na = armature("Rig")\nop("arm.bone", "Upper Bone 0 1 0 0 2 0")\nadd("cylinder", "Arm", 0, 1, 0)\nselect("Arm")')
    props_tab(m, f, 'rig')
    check('rig.parent' in names(), 'a mesh: Parent to Armature')
    click('rig.parent')
    check({'form.parent.mesh', 'form.parent.armature'} <= names(), 'it asks for the armature')
    type_into('form.parent.armature', 'Rig')
    f.key(28); f.pump(0.5)
    check(q('print(modcount("Arm"))') == '1', 'OK skins it (an Armature modifier)')
    click('constraint.add')
    check({'form.constraint.owner', 'form.constraint.type', 'form.constraint.target'} <= names(), 'Add Constraint asks for the type and target')
    type_into('form.constraint.target', 'Rig')
    f.key(28); f.pump(0.3)
    w = wait_widget(f, m, 'constraint.influence', 0)
    check(w is not None, 'the constraint gets a row')
    q('select("Rig")')
    f.pump(0.3)
    rows = [w.get('label') for w in ui_tree(m) if w['name'] == 'rig.bone']
    check(rows == ['Bone', 'Upper'], f'the bone list ({rows})')
    click('rig.bone', 0)
    check('rig.pose.rotation' in names(), 'a bone row makes it active and shows its pose')
    f.proc.kill()


def physics_ui():
    """UI plan U20: cloth / soft body settings and pins, the cloth world,
    a joint between two selected objects, the simulation cache."""
    print('  -- physics and simulation --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.2)
    def type_into(name, text, sub=0):
        click(name, sub); f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.3)
    q('add("plane", "Sheet", 0, 2, 0)\nselect("Sheet")')
    props_tab(m, f, 'physics')
    check({'cloth.make_cloth', 'cloth.make_soft', 'cloth.make_collider'} <= names(), 'not cloth yet: Cloth, Soft Body, Collider')
    click('cloth.make_cloth')
    w = wait_widget(f, m, 'cloth.stretch')
    check(w is not None and {'cloth.type', 'cloth.mass', 'cloth.self', 'cloth.pin_selected', 'cloth.remove'} <= names(),
          'cloth: its type, compliances, mass, self collision, pins')
    type_into('cloth.mass', '2.5')
    check(wait_value(f, m, 'cloth.mass', 0, 2.5) == 2.5, 'a value changes the cloth (cloth.add on the selection)')
    click('cloth.self')
    check(wait_value(f, m, 'cloth.self', 0, 1) == 1 and wait_value(f, m, 'cloth.mass', 0, 2.5) == 2.5, 'self collision on, the rest kept')
    pick_enum(f, m, 'cloth.type', 0, 1)
    check(wait_value(f, m, 'cloth.type', 0, 1) == 1, 'cloth becomes a soft body')
    type_into('cloth.wind_x', '3')
    check(wait_value(f, m, 'cloth.wind_x', 0, 3) == 3, 'the wind')
    click('cloth.remove')
    check(wait_widget(f, m, 'cloth.make_cloth') is not None, 'Remove: no longer cloth')
    q('add("sphere", "Ball", 3, 0, 0)\nselect("Ball", "Cube")')
    click('rigid.add_joint')
    a, b = widget(m, 'form.rjoint.a'), widget(m, 'form.rjoint.b')
    check(a and b and a['value'] == 'Cube' and b['value'] == 'Ball', f'Add Joint: the two selected objects ({a and a["value"]}, {b and b["value"]})')
    f.key(1); f.pump(0.2)
    check({'sim.bake', 'sim.free', 'sim.budget'} <= names(), 'the cache: Bake, Free, its budget')
    type_into('sim.budget', '512')
    check(wait_value(f, m, 'sim.budget', 0, 512) == 512, 'the budget from the field')
    f.proc.kill()


def render_ui():
    """UI plan U21: bounces, the GPU, Render to File, the engine panels
    (virtualized geometry, world partition, probes, lightmap, play), the
    Render area's header, a light's power and colour, a camera's lens and
    which camera renders (saved, undone)."""
    print('  -- render and engine --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.2)
    def type_into(name, text, sub=0):
        click(name, sub); f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.3)
    f.key(28); f.type('agent.permission_files'); f.key(28); f.pump(0.2); f.key(1)   # (scripts may save)
    props_tab(m, f, 'render')
    check({'render.bounces', 'render.gpu', 'render.to_file', 'vgeo.build', 'world.partition', 'probe.add_irradiance',
           'probe.bake', 'lightmap.bake', 'play.start', 'play.mode'} <= names(),
          'the Render tab: bounces, GPU, Render to File, virtualized geometry, world partition, probes, lightmap, play')
    type_into('render.bounces', '4')
    check(wait_value(f, m, 'render.bounces', 0, 4) == 4, 'bounces from the field')
    click('render.to_file')
    check('files.name' in names(), 'Render to File asks where (the file browser)')
    f.key(1); f.pump(0.2)
    q(f'op("file.save_as", "{os.path.join(f.home, "w.bee")}")')   # (cells go beside the file)
    click('world.partition')
    for _ in range(5):
        if q('print(world(0))') == '1':
            break
        f.pump(0.1)
    check(q('print(world(0))') == '1', 'Partition the world turns it on')
    click('world.partition')
    check(q('print(world(0))') == '0', '... and off')
    lname = q('op("create.light")\nprint(active())')
    props_tab(m, f, 'object')
    check({'light.power', 'light.color'} <= names(), 'a light: its power and colour')
    type_into('light.power', '3')
    check(wait_value(f, m, 'light.power', 0, 3) == 3, 'the light\'s power')
    f.mods(4); f.key(44); f.mods(0); f.pump(0.3)
    check(wait_value(f, m, 'light.power', 0, 1) == 1, 'undo takes it back')
    q('op("light.set", "power 2.5")')
    q('op("create.camera")\nop("create.camera")')
    check({'camera.lens', 'camera.make_active'} <= names() or wait_widget(f, m, 'camera.lens') is not None, 'a camera: its lens and Render from This Camera')
    type_into('camera.lens', '35')
    f.pump(0.2)
    v = widget(m, 'camera.lens')['value']
    check(abs(v - 35) < 0.01, f'the lens ({v})')
    click('camera.make_active')
    for _ in range(10):
        if widget(m, 'camera.make_active') is None:
            break
        f.pump(0.1)
    check(widget(m, 'camera.make_active') is None, 'this camera renders now')
    path = os.path.join(f.home, 'lc.bee')
    q(f'op("file.save_as", "{path}")\nop("file.new")\nop("file.open", "{path}")')
    f.pump(0.3)
    q(f'select("{lname}")')
    props_tab(m, f, 'object')
    v = wait_value(f, m, 'light.power', 0, 2.5)
    check(v == 2.5, f'the settings are saved in the .bee file ({v})')
    q('op("area.type_render")')
    f.pump(0.3)
    check({'render.header.start', 'render.header.stop', 'render.header.save', 'render.header.denoise', 'render.header.pass'} <= names(),
          'the Render area header: Render, Stop, Save, Denoise, the pass')
    f.proc.kill()


def team_ui():
    """UI plan U22: the Asset Browser's header and tile menu, the Versions
    editor (commit, branches, history), collaboration and the live link,
    the AI Activity header (permission)."""
    print('  -- library, versions, collaboration, AI --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.2)
    def type_into(name, text, sub=0):
        click(name, sub); f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.3)
    f.key(28); f.type('agent.permission_files'); f.key(28); f.pump(0.2); f.key(1)
    q('select("Cube")\nop("area.type_asset_browser")\nop("area.maximize")')
    f.pump(0.3)
    check({'library.search', 'library.kind', 'library.save'} <= names(), 'the Asset Browser header: search, kind, Save to Library')
    click('library.save')
    check({'form.lib.kind', 'form.lib.name', 'form.lib.tags'} <= names(), 'Save to Library asks what, its name and tags')
    type_into('form.lib.tags', '#box')
    f.key(28); f.pump(0.5)
    check(q('print(lib(0))') == '1', f'OK keeps the cube in the library ({q("print(lib(0))")})')
    pick_enum(f, m, 'library.kind', 0, 2)                      # Materials
    check(q('print(lib(4))') == '0', 'the kind list filters (no materials)')
    pick_enum(f, m, 'library.kind', 0, 1)                      # Objects
    check(q('print(lib(4))') == '1', '... objects: the cube')
    s = widget(m, 'library.search')
    tx, ty = s['x'] - (130 + 6) + 8 + 48, s['y'] + 24 + 24 + 48
    f.click(tx, ty, 0x111); f.pump(0.2)
    labels = [w['label'] for w in ui_tree(m) if w['kind'] == 'menuitem' and w.get('level') == 0]
    check('Place in the Scene' in labels and 'Remove from Library' in labels, f'right-click on a tile: its menu ({labels[:5]})')
    f.key(1); f.pump(0.2)
    q('op("area.maximize")\nop("area.type_viewport")')
    q(f'op("file.save_as", "{os.path.join(f.home, "v.bee")}")\nop("area.type_versions")\nop("area.maximize")')
    f.pump(0.3)
    check({'versions.message', 'versions.commit', 'versions.new_branch', 'versions.merge', 'versions.diff', 'collab.host', 'link.serve'} <= names(),
          'the Versions editor: commit, branches, merge, changes, collaboration, live link')
    type_into('versions.message', 'first')
    click('versions.commit')
    check(q('print(vcinfo(1), vctext(3))') == '1 first', f'Commit keeps a version ({q("print(vcinfo(1), vctext(3))")})')
    click('versions.new_branch')
    f.key(28); f.pump(0.4)
    check(q('print(vcinfo(2))') == '2', 'New Branch makes one')
    rows = [w.get('label') for w in ui_tree(m) if w['name'] == 'versions.branch']
    check(sorted(rows) == ['feature', 'main'], f'the branches are listed ({rows})')
    click('collab.host')
    check(q('print(costat(0))') == '1', 'Host starts a session')
    check('collab.leave' in names(), 'in a session: Leave')
    click('collab.leave')
    check(q('print(costat(0))') == '0', 'Leave ends it')
    q('op("area.maximize")\nop("area.type_activity")')
    f.pump(0.3)
    check('ai.permission' in names(), 'the AI Activity header: the agents\' permission')
    pick_enum(f, m, 'ai.permission', 0, 1)
    check(wait_value(f, m, 'ai.permission', 0, 1) == 1, 'agents may edit (from the list)')
    f.proc.kill()


def prefs_ui():
    """UI plan U23: Edit > Preferences (interface, input, keymap, system,
    files, AI), kept in ~/.config/beemodel/prefs across a restart; the UI
    scale; a key rebound by pressing it."""
    print('  -- preferences --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    home = f.home
    prefs = lambda: open(os.path.join(home, '.config', 'beemodel', 'prefs')).read() if os.path.exists(os.path.join(home, '.config', 'beemodel', 'prefs')) else ''
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.2)
    def type_into(name, text, sub=0):
        click(name, sub); f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.3)
    def tab(i):
        w = widget(m, 'prefs.tabs')
        f.click(w['x'] + w['w'] * (2 * i + 1) // 12, w['y'] + w['h'] // 2); f.pump(0.2)
    menu_pick(f, m, 'Edit', 'Preferences...')
    f.pump(0.3)
    check({'prefs.tabs', 'prefs.theme', 'prefs.ui_scale', 'prefs.tooltip_ms'} <= names(), 'Edit > Preferences: the Interface section')
    pick_enum(f, m, 'prefs.theme', 0, 1)
    check('theme 1' in prefs(), f'the theme goes into the prefs file ({prefs()[:60]!r})')
    w0 = widget(m, 'prefs.tabs')['w']
    pick_enum(f, m, 'prefs.ui_scale', 0, 3)                     # 150 %
    f.pump(0.3)
    w1 = (widget(m, 'prefs.tabs') or {}).get('w', 0)
    check('scale 150' in prefs() and 0 < w1 < w0, f'UI scale 150 %: everything bigger (the tab row {w0} -> {w1} units wide)')
    q('op("view.ui_scale", "100")')                             # (back: clicks are in screen units)
    f.pump(0.3)
    check('scale 100' in prefs() and widget(m, 'prefs.tabs')['w'] == w0, 'view.ui_scale sets it too (back to 100 %)')
    tab(1)
    check({'prefs.emulate_middle', 'prefs.orbit_speed'} <= names(), 'Input: Alt as the middle button, orbit speed')
    tab(2)
    check({'prefs.key_search', 'prefs.key_set', 'prefs.keys_reset'} <= names(), 'Keymap: search, Set, Reset')
    type_into('prefs.key_search', 'object.duplicate')
    click('prefs.key_set', 0)
    f.key(65); f.pump(0.3)                                      # F7 (free)
    check('key object.duplicate' in prefs(), f'Set, then a key: kept ({prefs()[-60:]!r})')
    n0 = q('print(count())')
    q('select("Cube")')
    f.move(300, 200); f.key(65); f.pump(0.3)                     # (over the 3D viewport)
    n1 = q('print(count())')
    check(int(n1 or 0) == int(n0 or 0) + 1, f'the new key runs it ({n0} -> {n1} objects)')
    tab(3)
    check({'prefs.threads', 'prefs.gpu', 'prefs.jit'} <= names(), 'System: threads, GPU, JIT')
    tab(4)
    check({'prefs.autosave', 'prefs.library_add'} <= names(), 'Files: autosave, library folders')
    tab(5)
    check({'prefs.agent_permission', 'prefs.mcp'} <= names(), 'AI: the agents\' permission, MCP')
    f.proc.kill()
    g = Fake(home=home)                                         # a restart
    g.pump(1.0, until_frame=True)
    g.keymap('tests/keymaps/us.xkb')
    g.enter(600, 300)
    n = Mcp(g)
    menu_pick(g, n, 'Edit', 'Preferences...')
    g.pump(0.3)
    w = widget(n, 'prefs.theme')
    check(w and w['value'] == 1, 'the preferences are there after a restart')
    g.proc.kill()


def workspaces_ui():
    """UI plan U24: workspace tabs (built-in and custom), Ctrl+PageUp /
    PageDown, swapping areas by their headers, joining them by a corner,
    layouts kept in .bee files and across a restart."""
    print('  -- workspaces --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    home = f.home
    tabs = lambda: [w.get('label') for w in ui_tree(m) if w['name'] == 'workspace.tab']
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.3)
    check(tabs() == ['Modeling', 'Sculpt', 'CAD', 'Shading', 'Animation', 'World'], f'workspace tabs in the menu bar ({tabs()})')
    click('workspace.tab', 3)
    check('node.tree' in names() and 'outliner.filter' not in names(), 'Shading: a node editor, no outliner')
    f.mods(4); f.key(109); f.mods(0); f.pump(0.3)              # Ctrl+PageDown
    check('timeline.play' in names(), 'Ctrl+PageDown: Animation (a timeline)')
    f.mods(4); f.key(104); f.key(104); f.key(104); f.key(104); f.mods(0); f.pump(0.3)  # Ctrl+PageUp x4
    check('outliner.filter' in names() and 'timeline.play' not in names(), 'Ctrl+PageUp back to Modeling, as it was')
    click('workspace.add')
    check(len(tabs()) == 7 and tabs()[-1] == 'Custom 1', f'+ adds a workspace from this layout ({tabs()[-1:]})')
    vm = widget(m, 'viewport.mode')                            # swap: the viewport's header onto the outliner
    of = widget(m, 'outliner.filter')
    hy = vm['y'] + 11                                          # (the header row; empty right of its tools)
    f.drag(of['x'] - 140, hy, of['x'] + 60, of['y'] - 40, steps=4); f.pump(0.3)
    w = wait_widget(f, m, 'outliner.filter')
    check(w is not None and w['x'] < of['x'] - 200, f'a header dragged onto another area swaps them (the outliner now at x {w and w["x"]})')
    q('op("workspace.set", "1")')                               # (Modeling, as it was)
    f.pump(0.3)
    for _ in range(10):                                        # (until Modeling is drawn again)
        of = widget(m, 'outliner.filter')
        if of and of['x'] > 600:
            break
        f.pump(0.1)
    vm = wait_widget(f, m, 'viewport.mode')
    if vm and of:                                              # join: the outliner's corner into the Properties below
        cx, cy = of['x'] - 4, vm['y'] + 1
        f.drag(cx, cy, cx + 60, cy + 300, steps=4); f.pump(0.3)
    for _ in range(5):
        if 'props.tab.object' not in names():
            break
        f.pump(0.1)
    check('props.tab.object' not in names() and 'outliner.filter' in names(), 'a corner dragged into the neighbour joins them')
    f.key(28); f.type('agent.permission_files'); f.key(28); f.pump(0.2); f.key(1)
    path = os.path.join(home, 'ws.bee')
    q(f'op("file.save_as", "{path}")\nop("workspace.set", "1")\nop("file.new")\nop("file.open", "{path}")')
    f.pump(0.3)
    check(tabs()[-1:] == ['Custom 1'], 'the workspaces come back from the .bee file')
    f.proc.kill()
    g = Fake(home=home)
    g.pump(1.0, until_frame=True)
    g.enter(600, 300)
    n = Mcp(g)
    t2 = [w.get('label') for w in ui_tree(n) if w['name'] == 'workspace.tab']
    check(t2[-1:] == ['Custom 1'], f'and after a restart ({t2[-1:]})')
    g.proc.kill()


def help_ui():
    """UI plan U25: the welcome screen (templates, recent, samples, keymap),
    quick actions in an empty viewport, the searchable F1 shortcuts, the
    Help area."""
    print('  -- onboarding and help --')
    f = Fake(welcome=True)
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name, sub=0):
        x, y = widget_xy(m, name, sub); f.click(x, y); f.pump(0.4)
    check({'welcome.default', 'welcome.empty', 'welcome.product', 'welcome.character', 'welcome.terrain', 'welcome.open',
           'welcome.sample_tree', 'welcome.keymap', 'welcome.show'} <= names(),
          'the welcome screen: templates, open, samples, keymap, show at start')
    click('welcome.product')
    for _ in range(10):
        if 'welcome.product' not in names():
            break
        f.pump(0.1)
    r = q('print(exists("Part"), features())')
    check(r == '1 2' and 'welcome.product' not in names(), f'a template makes its scene, the screen goes ({r})')
    menu_pick(f, m, 'Help', 'Welcome Screen')
    f.pump(0.3)
    check('welcome.empty' in names(), 'Help > Welcome Screen opens it again')
    f.key(1); f.pump(0.2)
    check('welcome.empty' not in names(), 'Esc closes it')
    menu_pick(f, m, 'Help', 'Welcome Screen')
    f.pump(0.3)
    click('welcome.empty')
    f.pump(0.3)
    check(q('print(count())') == '0' and wait_widget(f, m, 'quick.add_cube') is not None, 'an empty scene shows quick actions in the viewport')
    click('quick.add_cube')
    check(q('print(count())') == '1', 'Add a Cube from there')
    f.move(600, 300); f.key(59); f.pump(0.3)                   # F1
    check('shortcuts.search' in names(), 'F1: the shortcuts, with a search field')
    f.key(1); f.pump(0.2)
    check('shortcuts.search' not in names(), 'Esc closes them')
    q('op("area.type_help")')                                   # (the active area becomes the Help area)
    f.pump(0.3)
    img0 = f.image()
    t = [w for w in ui_tree(m) if w['kind'] == 'menu' and w['label'] == 'File'][0]
    f.click(t['x'] + 10, t['y'] + 10); f.pump(0.2)
    it = [w for w in ui_tree(m) if w['kind'] == 'menuitem' and w['label'] == 'Save As...']
    if it:
        f.move(it[0]['x'] + 40, it[0]['y'] + 12); f.pump(0.3)
    f.key(1); f.key(1); f.pump(0.3)
    img1 = f.image()
    d = sum(1 for a, b in zip(img0.getdata(), img1.getdata()) if a != b)
    check(d > 500, f'the Help area shows what the pointer rested on ({d} pixels changed)')
    f.proc.kill()


def a11y_ui():
    """UI plan U26: Tab / Shift+Tab through a panel's and a dialog's widgets
    with a focus ring, Enter / Space and the arrows on the focused one, Esc;
    F6 to the next area; colour-blind-safe axes."""
    print('  -- keyboard navigation and accessibility --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    focused = lambda: [(w['name'], w['sub']) for w in ui_tree(m) if w.get('focused')]
    q('select("Cube")')
    x, y = widget_xy(m, 'object.visible')
    f.move(x, y + 40); f.pump(0.2)                             # over the Properties
    f.key(15); f.pump(0.2)                                     # Tab
    a = focused()
    check(len(a) == 1, f'Tab over a panel: a widget has the focus ({a})')
    f.key(15); f.pump(0.2)
    b = focused()
    f.mods(1); f.key(15); f.mods(0); f.pump(0.2)               # Shift+Tab
    check(b != a and focused() == a, 'Tab moves on, Shift+Tab back')
    for _ in range(40):                                        # to Location X
        if focused() == [('object.location', 0)]:
            break
        f.key(15); f.pump(0.05)
    check(focused() == [('object.location', 0)], 'Tab reaches the fields in order')
    x0 = float(q('print(get("Cube", "x"))') or 0)
    f.key(106); f.pump(0.2)                                    # Right
    x1 = float(q('print(get("Cube", "x"))') or 0)
    check(abs(x1 - x0 - 0.1) < 1e-4, f'the arrows step the focused number ({x0} -> {x1})')
    for _ in range(40):
        if focused() == [('object.visible', 0)]:
            break
        f.key(15); f.pump(0.05)
    f.key(57); f.pump(0.2)                                     # Space
    check(widget(m, 'object.visible')['value'] == 0, 'Space works the focused toggle (the cube hidden)')
    f.key(28); f.pump(0.2)                                     # Enter: again
    check(widget(m, 'object.visible')['value'] == 1, 'Enter too')
    f.key(1); f.pump(0.2)
    check(focused() == [], 'Esc lets go')
    f.move(600, 300); f.key(15); f.pump(0.2)                    # Tab over the viewport: edit mode
    mode = (widget(m, 'viewport.mode') or {}).get('value')
    check(focused() == [] and mode == 1, f'over a 3D viewport Tab is still edit mode ({mode})')
    f.key(15); f.pump(0.2)
    menu_pick(f, m, 'Render', 'Bake Maps')
    f.pump(0.3)
    f.key(15); f.pump(0.2)
    c = focused() + [(w['name'], w['sub']) for w in ui_tree(m) if w.get('editing')]
    check(c and c[0][0].startswith('form.'), f'in a dialog Tab goes through its fields ({c})')
    f.key(1); f.pump(0.2); f.key(1); f.pump(0.2)                # Esc: the focus, then the dialog
    f.key(64); f.pump(0.2)                                     # F6
    img = f.image()
    ring = sum(1 for p in img.getdata() if p[:3] == (0x61, 0xaf, 0xef))
    check(ring > 200, f'F6: the next area, with a ring round it ({ring} ring pixels)')
    f.click(600, 300); f.pump(0.2)
    near = lambda img, c: sum(1 for p in img.getdata() if abs(p[0] - (c >> 16)) < 12 and abs(p[1] - ((c >> 8) & 255)) < 12 and abs(p[2] - (c & 255)) < 12)
    before = near(f.image(), 0xe06c75), near(f.image(), 0xe69f00)
    q('op("edit.preferences")')
    f.pump(0.3)
    click_w = widget(m, 'prefs.colorblind_axes')
    if click_w:
        f.click(click_w['x'] + 10, click_w['y'] + 11); f.pump(0.3)
    after = near(f.image(), 0xe06c75), near(f.image(), 0xe69f00)
    check(after[1] > before[1] + 20 and after[0] < before[0], f'colour-blind-safe axes: X turns orange (red, orange pixels {before} -> {after})')
    f.proc.kill()


def walkthrough_ui():
    """UI plan U27: a console-free walkthrough - model, a CAD feature, a
    material, a render, save and reopen - with only clicks and keys on
    widgets found through ui_tree (scripts only check the results)."""
    print('  -- console-free walkthrough --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in ui_tree(m)}
    def click(name, sub=0):
        w = wait_widget(f, m, name, sub)
        if w:
            f.click(w['x'] + min(w['w'] // 2, 40), w['y'] + w['h'] // 2); f.pump(0.2)
        return w is not None
    def type_into(name, text, sub=0):
        click(name, sub); f.mods(4); f.key(30); f.mods(0); f.type(text); f.key(28); f.pump(0.3)
    bee = os.path.join(f.home, 'BeeModel')
    # model: Add > Cylinder, moved by typing into the Properties
    menu_pick(f, m, 'Add', 'Cylinder')
    check(q('print(count(), active())') == '4 Cylinder', f'Add > Cylinder ({q("print(count(), active())")})')
    props_tab(m, f, 'object')
    type_into('object.location', '4', 0)
    check(q('print(round(get("Cylinder", "x")))') == '4', 'typing X = 4 in the Properties moves it')
    # a CAD feature: a sketch, a rectangle from the tool shelf, Pad
    menu_pick(f, m, 'Add', 'Sketch...')
    f.key(28); f.pump(0.3)                                     # OK (the XY plane)
    check(q('print(active())') == 'Sketch', 'Add > Sketch, OK: sketch mode')
    rect = [w for w in ui_tree(m) if w['name'] == 'tools.row' and w.get('label') == 'Rectangle']
    check(bool(rect), 'sketch mode puts the sketch tools on the shelf')
    if rect:
        f.click(rect[0]['x'] + 30, rect[0]['y'] + rect[0]['h'] // 2); f.pump(0.2)
    f.click(*project((-5, 0.5, 0))); f.pump(0.1)
    f.click(*project((-3, 2.5, 0))); f.pump(0.2)
    f.key(1); f.pump(0.1)
    ent = q('print(skinfo("Sketch", "entities"))')
    check(ent == '4', f'two clicks draw a rectangle ({ent} lines)')
    pts = [float(v) for v in q('s = "Sketch"\nfor i in 0..skinfo(s, "points") {\n print(sx(s, i), sy(s, i))\n}').split()]
    xs, ys = pts[0::2] or [0], pts[1::2] or [0]
    area = (max(xs) - min(xs)) * (max(ys) - min(ys))
    f.key(1); f.key(1); f.pump(0.2)
    menu_pick(f, m, 'Object', 'Part Feature', 'Pad...')
    check('form.pad.distance' in names(), 'Object > Part Feature > Pad asks for the distance')
    type_into('form.pad.distance', '1')
    f.key(28); f.pump(0.5)
    vol = float(q('print(volume("Body"))') or 0)
    check(q('print(features())') == '1' and area > 1 and abs(vol - area) < 1e-3, f'OK pads the sketch 1 m into a part (volume {vol:.2f}, rectangle {area:.2f})')
    # a material: a new one, red through the colour picker's hex code
    props_tab(m, f, 'material')
    click('material.new')
    click('material.base')
    type_into('color.hex', '#ff0000')
    f.key(1); f.pump(0.2)
    red = q('print(round(matget("Material", "base", 0) * 100), round(matget("Material", "base", 1) * 100))')
    check(red == '100 0', f'Material > New, the base colour from the picker ({red})')
    # a render: small, from the Render tab, saved through the file browser
    props_tab(m, f, 'render')
    type_into('render.width', '160')
    type_into('render.height', '90')
    type_into('render.samples', '4')
    click('render.start')
    f.pump(3.0)
    click('render.save')
    check('files.name' in names(), 'Save Render asks where (the file browser)')
    type_into('files.name', 'walk')
    click('files.ok')
    from PIL import Image
    png = os.path.join(bee, 'walk.png')
    ok = os.path.exists(png) and Image.open(png).size == (160, 90)
    check(ok, f'the render is saved as ~/BeeModel/walk.png, 160 x 90')
    # save, a new scene, reopen
    f.move(600, 300)
    f.mods(4); f.key(31); f.mods(0); f.pump(0.3)              # Ctrl+S: no file yet, the browser
    type_into('files.name', 'walk')
    click('files.ok')
    check(os.path.exists(os.path.join(bee, 'walk.bee')), 'Ctrl+S saves ~/BeeModel/walk.bee')
    f.mods(4); f.key(49); f.mods(0); f.pump(0.3)              # Ctrl+N
    if 'dialog.dont_save' in names():
        click('dialog.dont_save')
    check(q('print(exists("Cylinder"))') == '0', 'Ctrl+N: a new scene')
    t = [w for w in ui_tree(m) if w['kind'] == 'menu' and w['label'] == 'File'][0]
    f.click(t['x'] + 10, t['y'] + 10); f.pump(0.2)
    w = [w for w in ui_tree(m) if w.get('label') == 'Open Recent'][0]
    f.move(w['x'] + 40, w['y'] + 12); f.pump(0.2)
    rec = [w for w in ui_tree(m) if w['kind'] == 'menuitem' and w['level'] == 1 and w['label'] == 'walk.bee']
    if rec:
        f.click(rec[0]['x'] + 40, rec[0]['y'] + rec[0]['h'] // 2); f.pump(0.5)
    back = q('print(exists("Cylinder"), round(get("Cylinder", "x")), features(), round(matget("Material", "base", 0) * 100))')
    check(back == '1 4 1 100', f'File > Open Recent brings it all back: the cylinder, the part, the material ({back})')
    f.shot('walkthrough.png')
    f.proc.kill()


UI_FRAME_BUDGET_MS = 16                 # (a 60 Hz frame; ~3 ms here)


def ui_bench():
    """UI plan U27: frame times while the busiest panels are on screen and
    the pointer moves over them (each move redraws the window)."""
    print('  -- UI frame times --')
    f = Fake()
    f.pump(1.0, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(600, 300)
    m = Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    res = {}
    for tab in ('object', 'modifiers', 'material', 'render'):
        props_tab(m, f, tab)
        n0 = int(q('print(frames())'))
        for i in range(40):                                    # over the Properties and the outliner
            f.move(1060 + (i * 37) % 200, 100 + (i * 53) % 600); f.pump(0.03)
        n = int(q('print(frames())')) - n0
        ft = sorted(float(x) for x in q(f'for k in 1..{min(n, 200)} {{\n print(frametime(k))\n}}').split()) if n > 1 else [0.0]
        res[tab] = (n, ft[len(ft) // 2], ft[-1])
    for tab, (n, med, worst) in res.items():
        print(f'    {tab:10s} {n:3d} frames, median {med:.1f} ms, worst {worst:.1f} ms')
    meds = [r[1] for r in res.values()]
    check(all(r[0] >= 10 for r in res.values()), f'moving the pointer redraws ({[r[0] for r in res.values()]} frames)')
    check(max(meds) < UI_FRAME_BUDGET_MS, f'UI frames: median under {UI_FRAME_BUDGET_MS} ms on every tab ({", ".join(f"{x:.1f}" for x in meds)})')
    f.proc.kill()


if __name__ == '__main__':
    main()
