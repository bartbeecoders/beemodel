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

OUT = sys.argv[1] if len(sys.argv) > 1 else 'build/shots'
BIN = os.path.join(os.path.dirname(__file__), '..', 'build', 'beemodel')
os.makedirs(OUT, exist_ok=True)

GLOBALS = [(1, 'wl_compositor', 4), (2, 'wl_shm', 1), (3, 'xdg_wm_base', 2),
           (4, 'wl_seat', 5), (5, 'wp_cursor_shape_manager_v1', 1)]


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
        self.proc = subprocess.Popen([BIN], env=env)
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
        self.send(self.ptr(), 2, struct.pack('<Iii', 0, x * 256, y * 256))
        if wait: self.pump(until_frame=True)

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

    def shot(self, name):
        from PIL import Image
        w, h, data = self.frame
        img = Image.frombuffer('RGBX', (w, h), data, 'raw', 'BGRX', 0, 1).convert('RGB')
        path = os.path.join(OUT, name)
        img.save(path)
        print(f'  shot {path} ({w}x{h}, frame #{self.frames}, cursor shape {self.cursor})')


FAILS = []


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
    check(px(f, 600, 700) != 0x2a2e36, 'console pane hidden')
    f.shot('04_console_hidden.png')
    f.click(130, 44); f.click(150, 120)  # toggle it back on
    check(px(f, 600, 700) == 0x2a2e36, 'console pane shown again')
    f.move(212, 300)
    check(f.cursor == 26, 'ew-resize cursor on splitter')
    f.drag(212, 300, 330, 300)           # left splitter
    check(px(f, 300, 450) == 0x2a2e36, 'left pane widened by drag')
    f.drag(1017, 300, 900, 300)          # right splitter
    f.drag(600, 625, 600, 520)           # bottom splitter
    f.shot('05_splitters.png')
    f.drag(600, 300, 700, 340)           # orbit
    f.wheel(-10); f.wheel(-10)           # zoom in
    f.click(1060, 93)                    # outliner: select Camera
    f.shot('06_orbit_zoom.png')
    f.key(17)                            # W: Move tool via the operator keymap
    check(px(f, 150, 125) == 0xf2b134, 'W activates the Move tool')
    f.key(20)                            # T: hide tools pane
    check(px(f, 4, 300) != 0x2a2e36, 'T hides the tools pane')
    f.mods(4); f.key(20); f.mods(0)      # Ctrl+T is not bound: no change
    check(px(f, 4, 300) != 0x2a2e36, 'Ctrl+T does not trigger the T binding')
    f.key(20)
    check(px(f, 4, 300) == 0x2a2e36, 'T shows the tools pane again')
    f.key(16)                            # Q: back to Select
    f.key(34)                            # G: grid off
    f.move(1250, 10)                     # hover close button
    check(px(f, 1240, 3) == 0xe81123, 'close button hover is red')
    f.shot('07_grid_off_close_hover.png')
    f.configure(900, 560); f.pump(0.5, until_frame=True)
    check(f.frame[:2] == (900, 560), 'resize to 900x560 honoured')
    f.shot('08_resized.png')
    f.configure(1600, 900, states=(1, 4)); f.pump(0.5, until_frame=True)
    check(f.frame[:2] == (1600, 900), 'maximized configure honoured')
    f.shot('09_maximized.png')
    f.click(1600 - 23, 16)               # close button
    f.pump(0.5)
    try:
        rc = f.proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        f.proc.kill(); rc = None
    check(rc == 0, f'close button exits cleanly (rc={rc})')
    check(f.frames >= 50, f'frames rendered ({f.frames})')
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nall checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
